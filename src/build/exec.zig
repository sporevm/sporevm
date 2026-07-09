const std = @import("std");
const Io = std.Io;

const rootfs_cas = @import("../rootfs_cas.zig");
const rootfs_mod = @import("../rootfs.zig");
const run_mod = @import("../run.zig");
const spore = @import("../spore.zig");
const step_cache = @import("step_cache.zig");
const vsock = @import("../virtio/vsock.zig");

const guest_port: u32 = 10700;
const step_timeout_ms: u64 = 30 * 60 * 1000;
const max_captured_output = 64 * 1024;
const max_guest_request_len = 8191;
const max_guest_arg_len = 255;
const max_guest_envc = 64;
const max_guest_env_len = 255;
const max_guest_working_dir_len = 255;

pub const Diagnostic = struct {
    instruction: ?[]const u8 = null,
    exit_code: ?i32 = null,
    output: []const u8 = "",
    boot_count: usize = 0,
    executed_steps: usize = 0,
};

pub const RunStep = struct {
    canonical_instruction: []const u8,
    command: []const u8,
    env: []const []const u8,
    env_digest: []const u8,
    workdir: []const u8,
};

pub const Options = struct {
    platform: rootfs_mod.Platform,
    cache_root: []const u8,
    base_storage: spore.RootfsStorage,
    steps: []const RunStep,
    network_enabled: bool,
    output: ?*Io.Writer = null,
    diagnostic: ?*Diagnostic = null,
};

const Phase = enum {
    start_run,
    active_run,
    start_freeze,
    active_freeze,
    snapshot,
    start_thaw,
    active_thaw,
    done,
    failed,
};

const ActiveStream = enum {
    run,
    freeze,
    thaw,
};

pub fn runSession(init: std.process.Init, allocator: std.mem.Allocator, options: Options) !spore.RootfsStorage {
    if (options.steps.len == 0) return spore.cloneRootfsStorage(allocator, options.base_storage);
    if (options.diagnostic) |diag| diag.* = .{};

    var control = try BuildControl.init(init.io, allocator, options);
    defer control.deinit();

    const rootfs = try rootfsFromStorage(allocator, options.base_storage);
    const kernel_path = try run_mod.resolveDefaultKernelPath(init, allocator);
    const initrd_path = try run_mod.resolveConfiguredInitrdPath(init, null);
    _ = try run_mod.executeMonitor(.{ .io = init.io, .environ_map = init.environ_map }, allocator, .{
        .kernel_path = kernel_path,
        .initrd_path = initrd_path,
        .rootfs = rootfs,
        .command = &.{},
        .memory = .{ .policy = .explicit, .bytes = 2 * 1024 * 1024 * 1024 },
        .network = if (options.network_enabled) .spore else .disabled,
        .timeout_ms = step_timeout_ms,
    }, control.control());

    if (control.failed_exit_code) |exit_code| {
        if (options.diagnostic) |diag| {
            diag.instruction = control.failed_instruction;
            diag.exit_code = exit_code;
            diag.output = try control.capture.toOwnedSlice();
            diag.boot_count = 1;
            diag.executed_steps = control.executed_steps;
        }
        return error.BuildRunFailed;
    }
    if (control.failure) |err| return err;
    if (control.phase != .done) return error.BuildGuestProtocolFailed;
    if (options.diagnostic) |diag| {
        diag.boot_count = 1;
        diag.executed_steps = control.executed_steps;
    }
    return try spore.cloneRootfsStorage(allocator, control.current_storage);
}

const BuildControl = struct {
    io: Io,
    allocator: std.mem.Allocator,
    platform: rootfs_mod.Platform,
    cache_root: []const u8,
    steps: []const RunStep,
    network_enabled: bool,
    output: ?*Io.Writer,
    current_storage: spore.RootfsStorage,
    step_index: usize = 0,
    phase: Phase = .start_run,
    active_stream: ActiveStream = .run,
    stream: vsock.HostStream = undefined,
    stream_valid: bool = false,
    active_input: ?step_cache.StepInput = null,
    active_step_key: []const u8 = "",
    capture: std.array_list.Managed(u8),
    output_failed: bool = false,
    executed_steps: usize = 0,
    failed_instruction: ?[]const u8 = null,
    failed_exit_code: ?i32 = null,
    failure: ?anyerror = null,

    fn init(io: Io, allocator: std.mem.Allocator, options: Options) !BuildControl {
        return .{
            .io = io,
            .allocator = allocator,
            .platform = options.platform,
            .cache_root = options.cache_root,
            .steps = options.steps,
            .network_enabled = options.network_enabled,
            .output = options.output,
            .current_storage = try spore.cloneRootfsStorage(allocator, options.base_storage),
            .capture = std.array_list.Managed(u8).init(allocator),
        };
    }

    fn deinit(self: *BuildControl) void {
        self.capture.deinit();
    }

    fn control(self: *BuildControl) vsock.Control {
        return .{
            .context = self,
            .pollFn = pollThunk,
            .setWakeFn = setWakeThunk,
            .completeSnapshotFn = completeSnapshotThunk,
            .completeRootfsSnapshotFn = completeRootfsSnapshotThunk,
            .reportStatsFn = reportStatsThunk,
        };
    }

    fn poll(self: *BuildControl, dev: *vsock.Vsock) !vsock.ControlAction {
        switch (self.phase) {
            .start_run => {
                try self.startRun(dev);
                return .keep_running;
            },
            .active_run => return try self.pollActiveStream(dev),
            .start_freeze => {
                try self.startSimpleControl(dev, .freeze);
                return .keep_running;
            },
            .active_freeze => return try self.pollActiveStream(dev),
            .snapshot => return .{ .rootfs_snapshot = .{ .dir = self.cache_root } },
            .start_thaw => {
                try self.startSimpleControl(dev, .thaw);
                return .keep_running;
            },
            .active_thaw => return try self.pollActiveStream(dev),
            .done, .failed => return .stop,
        }
    }

    fn startRun(self: *BuildControl, dev: *vsock.Vsock) !void {
        const step = self.steps[self.step_index];
        self.executed_steps += 1;
        const input = step_cache.StepInput{
            .platform = self.platform,
            .parent_index_digest = self.current_storage.index_digest,
            .instruction_kind = "RUN",
            .canonical_instruction = step.canonical_instruction,
            .env_digest = step.env_digest,
            .workdir = step.workdir,
        };
        self.active_input = input;
        self.active_step_key = try step_cache.stepKey(self.allocator, input);
        const session_id = try std.fmt.allocPrint(self.allocator, "spore-build-{d}", .{self.step_index + 1});
        const request = try runRequest(self.allocator, session_id, step.command, step.env, step.workdir, self.io);
        try self.startStream(dev, request, .spore_stream_v1, .run);
        self.phase = .active_run;
    }

    fn startSimpleControl(self: *BuildControl, dev: *vsock.Vsock, kind: ActiveStream) !void {
        const request = switch (kind) {
            .freeze => try simpleRequest(self.allocator, "fsfreeze-v1", "spore-build-freeze"),
            .thaw => try simpleRequest(self.allocator, "fsthaw-v1", "spore-build-thaw"),
            .run => unreachable,
        };
        try self.startStream(dev, request, .spore_stream_v1, kind);
        self.phase = switch (kind) {
            .freeze => .active_freeze,
            .thaw => .active_thaw,
            .run => unreachable,
        };
    }

    fn startStream(self: *BuildControl, dev: *vsock.Vsock, request: []const u8, protocol: vsock.HostStreamProtocol, kind: ActiveStream) !void {
        self.stream = try vsock.HostStream.initWithProtocol(guest_port, request, protocol);
        self.stream.host_port = vsock.HostStream.deriveHostPort(request);
        self.active_stream = kind;
        if (kind == .run) self.stream.setOutputSink(self, outputSink);
        if (kind == .run and protocol == .spore_stream_v1) {
            var stop = std.atomic.Value(bool).init(false);
            _ = try self.stream.enqueueStdinCloseBlocking(&stop);
        }
        try dev.attachHostStream(&self.stream);
        self.stream.markStarted();
        self.stream_valid = true;
        _ = try dev.flushHostStreamOutbound();
    }

    fn pollActiveStream(self: *BuildControl, dev: *vsock.Vsock) !vsock.ControlAction {
        if (!self.stream_valid) return .keep_running;
        _ = try dev.flushHostStreamOutbound();
        switch (self.stream.state) {
            .complete => {
                const exit_code = self.stream.exit_code orelse return error.BadRunExitFrame;
                dev.resetHostStream();
                self.stream_valid = false;
                try self.finishActiveStream(exit_code);
            },
            .failed => {
                dev.resetHostStream();
                self.stream_valid = false;
                self.failure = error.BuildGuestProtocolFailed;
                self.phase = .failed;
            },
            else => {
                if (self.stream.elapsedMs() > step_timeout_ms) {
                    dev.resetHostStream();
                    self.stream_valid = false;
                    self.failure = error.BuildGuestTimedOut;
                    self.phase = .failed;
                }
            },
        }
        return .keep_running;
    }

    fn finishActiveStream(self: *BuildControl, exit_code: i32) !void {
        switch (self.active_stream) {
            .run => {
                if (exit_code != 0) {
                    self.failed_instruction = self.steps[self.step_index].canonical_instruction;
                    self.failed_exit_code = exit_code;
                    self.phase = .failed;
                    return;
                }
                self.phase = .start_freeze;
            },
            .freeze => {
                if (exit_code != 0) {
                    self.failure = error.BuildGuestFreezeFailed;
                    self.phase = .failed;
                    return;
                }
                self.phase = .snapshot;
            },
            .thaw => {
                if (exit_code != 0) {
                    self.failure = error.BuildGuestThawFailed;
                    self.phase = .failed;
                    return;
                }
                self.step_index += 1;
                self.active_input = null;
                self.active_step_key = "";
                self.capture.clearRetainingCapacity();
                self.phase = if (self.step_index >= self.steps.len) .done else .start_run;
            },
        }
    }

    fn completeRootfsSnapshot(self: *BuildControl, maybe_disk: ?spore.Disk) !void {
        if (self.phase != .snapshot) return;
        const disk = maybe_disk orelse return error.BadManifest;
        const storage = try storageFromDisk(self.allocator, disk);
        // A zero-dirty RUN can intentionally yield child digest == parent
        // digest; the step key still proves which instruction/env was run.
        try rootfs_cas.markStorageComplete(self.io, self.allocator, self.cache_root, storage.index_digest);
        const input = self.active_input orelse return error.BadManifest;
        _ = try step_cache.writeRecord(self.io, self.allocator, self.cache_root, input, self.active_step_key, storage);
        self.current_storage = storage;
        self.phase = .start_thaw;
    }

    fn setWake(_: *BuildControl, _: vsock.Wake) void {}

    fn completeSnapshot(_: *BuildControl, _: []const u8) !void {}

    fn reportStats(_: *BuildControl, _: vsock.ControlStats) void {}

    fn appendOutput(self: *BuildControl, bytes: []const u8) void {
        if (self.output) |writer| {
            writer.writeAll(bytes) catch {
                self.output_failed = true;
            };
            writer.flush() catch {
                self.output_failed = true;
            };
        }
        const remaining = max_captured_output -| self.capture.items.len;
        const take = @min(remaining, bytes.len);
        if (take != 0) self.capture.appendSlice(bytes[0..take]) catch {};
    }

    fn outputSink(context: ?*anyopaque, _: vsock.HostStreamOutput, bytes: []const u8) void {
        const self: *BuildControl = @ptrCast(@alignCast(context.?));
        self.appendOutput(bytes);
    }

    fn pollThunk(context: *anyopaque, dev: *vsock.Vsock) !vsock.ControlAction {
        const self: *BuildControl = @ptrCast(@alignCast(context));
        return self.poll(dev);
    }

    fn setWakeThunk(context: *anyopaque, wake: vsock.Wake) void {
        const self: *BuildControl = @ptrCast(@alignCast(context));
        self.setWake(wake);
    }

    fn completeSnapshotThunk(context: *anyopaque, dir: []const u8) !void {
        const self: *BuildControl = @ptrCast(@alignCast(context));
        try self.completeSnapshot(dir);
    }

    fn completeRootfsSnapshotThunk(context: *anyopaque, disk: ?spore.Disk) !void {
        const self: *BuildControl = @ptrCast(@alignCast(context));
        try self.completeRootfsSnapshot(disk);
    }

    fn reportStatsThunk(context: *anyopaque, stats: vsock.ControlStats) void {
        const self: *BuildControl = @ptrCast(@alignCast(context));
        self.reportStats(stats);
    }
};

fn runRequest(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    command: []const u8,
    env: []const []const u8,
    workdir: []const u8,
    io: Io,
) ![]const u8 {
    if (command.len > max_guest_arg_len) return error.RunCommandTooLong;
    if (workdir.len == 0 or workdir.len > max_guest_working_dir_len) return error.RunWorkingDirUnsupported;
    if (env.len > max_guest_envc) return error.RunEnvCountUnsupported;
    for (env) |entry| if (entry.len > max_guest_env_len) return error.RunEnvTooLong;
    const now: u64 = @intCast(Io.Clock.real.now(io).nanoseconds);
    const argv = [_][]const u8{ "/bin/sh", "-c", command };
    const payload = struct {
        type: []const u8 = "start-v1",
        session_id: []const u8,
        resume_time_unix_ns: u64,
        argv: []const []const u8,
        env: []const []const u8,
        working_dir: []const u8,
        stdio: []const u8 = "pipe",
        term: []const u8 = "xterm",
        terminal_rows: u16 = 24,
        terminal_cols: u16 = 80,
        memory_pressure: bool = false,
        closed_env: bool = true,
    }{
        .session_id = session_id,
        .resume_time_unix_ns = now,
        .argv = argv[0..],
        .env = env,
        .working_dir = workdir,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

fn simpleRequest(allocator: std.mem.Allocator, request_type: []const u8, session_id: []const u8) ![]const u8 {
    const payload = struct {
        type: []const u8,
        session_id: []const u8,
    }{
        .type = request_type,
        .session_id = session_id,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

fn rootfsFromStorage(allocator: std.mem.Allocator, storage: spore.RootfsStorage) !spore.Rootfs {
    return .{
        .device = try spore.cloneRootfsDevice(allocator, storage.device),
        .artifact = .{
            .digest = try allocator.dupe(u8, storage.index_digest),
            .size = storage.logical_size,
            .format = try allocator.dupe(u8, spore.rootfs_artifact_format_ext4),
        },
        .storage = try spore.cloneRootfsStorage(allocator, storage),
    };
}

fn storageFromDisk(allocator: std.mem.Allocator, disk: spore.Disk) !spore.RootfsStorage {
    if (!std.mem.eql(u8, disk.kind, spore.disk_kind_chunk_index)) return error.BadManifest;
    if (disk.layers.len != 0) return error.BadManifest;
    const base = try allocator.dupe(u8, disk.base);
    return .{
        .kind = try allocator.dupe(u8, spore.rootfs_storage_kind_chunked_ext4),
        .device = try spore.cloneRootfsDevice(allocator, disk.device),
        .logical_size = disk.size,
        .chunk_size = disk.chunk_size,
        .hash_algorithm = try allocator.dupe(u8, disk.hash_algorithm),
        .index_digest = base,
        .base_identity = try allocator.dupe(u8, disk.base),
        .object_namespace = try allocator.dupe(u8, disk.object_namespace),
    };
}

fn fuzzSimpleRequest(_: void, s: *std.testing.Smith) !void {
    var buf: [64]u8 = undefined;
    const len = s.slice(&buf);
    const request = simpleRequest(std.testing.allocator, buf[0..len], "session") catch return;
    defer std.testing.allocator.free(request);
    try std.testing.expect(request.len <= max_guest_request_len);
}

test "build fsfreeze request stays bounded" {
    const request = try simpleRequest(std.testing.allocator, "fsfreeze-v1", "spore-build-freeze");
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.endsWith(u8, request, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, request, "\"fsfreeze-v1\"") != null);
}

test "build run request uses spore stream v1 start" {
    const request = try runRequest(std.testing.allocator, "spore-build-1", "echo ok", &.{"PATH=/usr/bin"}, "/work", std.testing.io);
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.endsWith(u8, request, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, request, "\"start-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"stdio\":\"pipe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"/bin/sh\",\"-c\",\"echo ok\"") != null);
}

test "build run request rejects guest parser overflow" {
    const command = "x" ** (max_guest_arg_len + 1);
    try std.testing.expectError(error.RunCommandTooLong, runRequest(std.testing.allocator, "spore-build-1", command, &.{}, "/", std.testing.io));
    const workdir = "/" ** (max_guest_working_dir_len + 1);
    try std.testing.expectError(error.RunWorkingDirUnsupported, runRequest(std.testing.allocator, "spore-build-1", "true", &.{}, workdir, std.testing.io));
}

test "fuzz build control request framing" {
    try std.testing.fuzz({}, fuzzSimpleRequest, .{});
}
