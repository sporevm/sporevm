const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const rootfs_cas = @import("../rootfs_cas.zig");
const rootfs_mod = @import("../rootfs.zig");
const run_mod = @import("../run.zig");
const runtime_disk = @import("../runtime_disk.zig");
const spore = @import("../spore.zig");
const step_cache = @import("step_cache.zig");
const vsock = @import("../virtio/vsock.zig");

const guest_port: u32 = 10700;
const step_timeout_ms: u64 = 30 * 60 * 1000;
const max_captured_output = 64 * 1024;
// Provisional build-VM default; make this a `spore build` option when larger
// workloads such as `bundle install`-style RUN steps need more memory.
const build_vm_memory_bytes: u64 = 2 * 1024 * 1024 * 1024;
const max_guest_request_len = 8191;
pub const max_run_command_len = 64 * 1024;
const max_guest_envc = 64;
const max_guest_env_len = 255;
const max_guest_working_dir_len = 255;
pub const max_copy_entries = 65536;
pub const max_copy_entry_path_len = 512;
const resize_command = "resize2fs /dev/vda";

pub const Diagnostic = struct {
    instruction: ?[]const u8 = null,
    instruction_line: usize = 0,
    exit_code: ?i32 = null,
    output: []const u8 = "",
    boot_count: usize = 0,
    executed_steps: usize = 0,
    resize_count: usize = 0,
    max_checkpoint_control_ms: u64 = 0,
};

pub const RunStep = struct {
    line: usize = 0,
    canonical_instruction: []const u8,
    command: []const u8,
    env: []const []const u8,
    env_digest: []const u8,
    workdir: []const u8,
    network_mode: step_cache.NetworkMode,
};

pub const CopySourceKind = enum {
    directory,
    file,
    sym_link,
};

pub const CopyRequest = struct {
    source: []const u8,
    dest: []const u8,
    source_kind: CopySourceKind,
    dest_is_dir: bool,
    entry_count: usize,
};

pub const CopyStep = struct {
    line: usize = 0,
    canonical_instruction: []const u8,
    input_digest: []const u8,
    env_digest: []const u8,
    workdir: []const u8,
    requests: []const CopyRequest,
};

pub const WorkdirStep = struct {
    line: usize = 0,
    canonical_instruction: []const u8,
    target: []const u8,
    env_digest: []const u8,
    workdir: []const u8,
};

pub const Step = union(enum) {
    run: RunStep,
    copy: CopyStep,
    workdir: WorkdirStep,

    fn canonicalInstruction(self: Step) []const u8 {
        return switch (self) {
            .run => |step| step.canonical_instruction,
            .copy => |step| step.canonical_instruction,
            .workdir => |step| step.canonical_instruction,
        };
    }

    fn line(self: Step) usize {
        return switch (self) {
            .run => |step| step.line,
            .copy => |step| step.line,
            .workdir => |step| step.line,
        };
    }
};

pub const Options = struct {
    platform: rootfs_mod.Platform,
    cache_root: []const u8,
    base_storage: spore.RootfsStorage,
    steps: []const Step,
    disk_grow_target: u64 = 0,
    context_disk_path: ?[]const u8 = null,
    output: ?*Io.Writer = null,
    diagnostic: ?*Diagnostic = null,
};

pub fn cacheInputForStep(platform: rootfs_mod.Platform, parent_index_digest: []const u8, step: Step, disk_grow_target: u64) step_cache.StepInput {
    return switch (step) {
        .run => |run| .{
            .platform = platform,
            .parent_index_digest = parent_index_digest,
            .canonical_instruction = run.canonical_instruction,
            .disk_grow_target = disk_grow_target,
            .operation = .{ .run = .{
                .env_digest = run.env_digest,
                .workdir = run.workdir,
                .network_mode = run.network_mode,
            } },
        },
        .copy => |copy| .{
            .platform = platform,
            .parent_index_digest = parent_index_digest,
            .canonical_instruction = copy.canonical_instruction,
            .disk_grow_target = disk_grow_target,
            .operation = .{ .copy = .{
                .input_digest = copy.input_digest,
                .env_digest = copy.env_digest,
                .workdir = copy.workdir,
            } },
        },
        .workdir => |workdir| .{
            .platform = platform,
            .parent_index_digest = parent_index_digest,
            .canonical_instruction = workdir.canonical_instruction,
            .disk_grow_target = disk_grow_target,
            .operation = .{ .workdir = .{
                .target = workdir.target,
                .env_digest = workdir.env_digest,
                .workdir = workdir.workdir,
            } },
        },
    };
}

const Phase = enum {
    start_resize,
    active_resize,
    start_run,
    start_copy_request,
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
    resize,
    run,
    copy,
    workdir,
    freeze,
    thaw,
};

/// Runs all uncached build steps in one build VM session.
///
/// Allocation ownership follows the build path's arena-per-invocation contract:
/// session ids, request buffers, step keys, storage clones, and current_storage
/// replacements live until the caller resets its arena. Do not call this with a
/// long-lived general-purpose allocator.
pub fn runSession(init: std.process.Init, allocator: std.mem.Allocator, options: Options) !spore.RootfsStorage {
    if (options.steps.len == 0) return spore.cloneRootfsStorage(allocator, options.base_storage);
    if (options.diagnostic) |diag| {
        diag.* = .{};
        diag.resize_count = @intFromBool(options.disk_grow_target != 0);
    }
    const network_mode = try networkModeForSteps(options.steps);

    var control = try BuildControl.init(init.io, allocator, options);
    defer control.deinit();

    const rootfs = try rootfsFromStorage(allocator, options.base_storage);
    const kernel_path = try run_mod.resolveDefaultKernelPath(init, allocator);
    const initrd_path = try run_mod.resolveConfiguredInitrdPath(init, null);
    _ = try run_mod.executeMonitor(.{ .io = init.io, .environ_map = init.environ_map }, allocator, .{
        .kernel_path = kernel_path,
        .initrd_path = initrd_path,
        .rootfs = rootfs,
        .rootfs_grow_target = options.disk_grow_target,
        .context_disk_path = options.context_disk_path,
        .command = &.{},
        .memory = .{ .policy = .explicit, .bytes = build_vm_memory_bytes },
        .network = if (network_mode == .spore) .spore else .disabled,
        .timeout_ms = step_timeout_ms,
    }, control.control());

    if (control.failed_exit_code) |exit_code| {
        if (options.diagnostic) |diag| {
            diag.instruction = control.failed_instruction;
            diag.instruction_line = control.failed_instruction_line;
            diag.exit_code = exit_code;
            diag.output = try control.capture.toOwnedSlice();
            diag.boot_count = 1;
            diag.executed_steps = control.executed_steps;
            diag.max_checkpoint_control_ms = control.max_checkpoint_control_ms;
        }
        return error.BuildRunFailed;
    }
    if (control.failure) |err| return err;
    if (control.phase != .done) return error.BuildGuestProtocolFailed;
    if (options.diagnostic) |diag| {
        diag.boot_count = 1;
        diag.executed_steps = control.executed_steps;
        diag.max_checkpoint_control_ms = control.max_checkpoint_control_ms;
    }
    return try spore.cloneRootfsStorage(allocator, control.current_storage);
}

fn networkModeForSteps(steps: []const Step) !step_cache.NetworkMode {
    var mode: ?step_cache.NetworkMode = null;
    for (steps) |step| switch (step) {
        .run => |run| {
            if (mode) |existing| {
                if (existing != run.network_mode) return error.BuildNetworkModeMismatch;
            } else {
                mode = run.network_mode;
            }
        },
        .copy, .workdir => {},
    };
    return mode orelse .none;
}

/// Session state is arena-owned; see `runSession` for the allocator lifetime
/// contract. Fields that are replaced during checkpointing are intentionally not
/// individually freed.
const BuildControl = struct {
    io: Io,
    allocator: std.mem.Allocator,
    platform: rootfs_mod.Platform,
    cache_root: []const u8,
    steps: []const Step,
    output: ?*Io.Writer,
    current_storage: spore.RootfsStorage,
    disk_grow_target: u64 = 0,
    step_index: usize = 0,
    phase: Phase = .start_run,
    active_stream: ActiveStream = .run,
    stream: vsock.HostStream = undefined,
    stream_valid: bool = false,
    stream_sequence: u64 = 0,
    active_input: ?step_cache.StepInput = null,
    active_step_key: []const u8 = "",
    active_stdin_payload: []const u8 = "",
    active_stdin_offset: usize = 0,
    active_stdin_close_sent: bool = true,
    active_copy_request_index: usize = 0,
    capture: std.array_list.Managed(u8),
    executed_steps: usize = 0,
    failed_instruction: ?[]const u8 = null,
    failed_instruction_line: usize = 0,
    failed_exit_code: ?i32 = null,
    failure: ?anyerror = null,
    max_checkpoint_control_ms: u64 = 0,

    fn init(io: Io, allocator: std.mem.Allocator, options: Options) !BuildControl {
        return .{
            .io = io,
            .allocator = allocator,
            .platform = options.platform,
            .cache_root = options.cache_root,
            .steps = options.steps,
            .output = options.output,
            .current_storage = try spore.cloneRootfsStorage(allocator, options.base_storage),
            .disk_grow_target = options.disk_grow_target,
            .phase = if (options.disk_grow_target == 0) .start_run else .start_resize,
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
            .start_resize => {
                try self.startResize(dev);
                return .keep_running;
            },
            .active_resize => return try self.pollActiveStream(dev),
            .start_run => {
                try self.startStep(dev);
                return .keep_running;
            },
            .start_copy_request => {
                try self.startCopyRequest(dev);
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

    fn startResize(self: *BuildControl, dev: *vsock.Vsock) !void {
        const request = try runRequest(self.allocator, "spore-build-resize", resize_command, &.{}, "/", self.io);
        try self.startStream(dev, request, .spore_stream_v1, .resize, resize_command);
        self.phase = .active_resize;
    }

    fn startStep(self: *BuildControl, dev: *vsock.Vsock) !void {
        const step = self.steps[self.step_index];
        self.executed_steps += 1;
        const input = self.stepInput(step);
        self.active_input = input;
        self.active_step_key = try step_cache.stepKey(self.allocator, input);
        const session_id = try std.fmt.allocPrint(self.allocator, "spore-build-{d}", .{self.step_index + 1});
        switch (step) {
            .run => |run| {
                const request = try runRequest(self.allocator, session_id, run.command, run.env, run.workdir, self.io);
                try self.startStream(dev, request, .spore_stream_v1, .run, run.command);
            },
            .copy => |copy| {
                if (copy.requests.len == 0) return error.CopyEntryCountUnsupported;
                self.active_copy_request_index = 0;
                try self.startCopyRequest(dev);
            },
            .workdir => |workdir| {
                const request = try workdirRequest(self.allocator, session_id, workdir.target);
                try self.startStream(dev, request, .spore_stream_v1, .workdir, "");
            },
        }
        self.phase = .active_run;
    }

    fn startCopyRequest(self: *BuildControl, dev: *vsock.Vsock) !void {
        const copy = switch (self.steps[self.step_index]) {
            .copy => |copy| copy,
            .run, .workdir => return error.BadManifest,
        };
        if (self.active_copy_request_index >= copy.requests.len) return error.BadManifest;
        const session_id = try std.fmt.allocPrint(self.allocator, "spore-build-{d}-{d}", .{ self.step_index + 1, self.active_copy_request_index + 1 });
        const request = try copyRequest(self.allocator, session_id, copy.requests[self.active_copy_request_index]);
        try self.startStream(dev, request, .spore_stream_v1, .copy, "");
        self.phase = .active_run;
    }

    fn stepInput(self: BuildControl, step: Step) step_cache.StepInput {
        const disk_grow_target = if (self.step_index == 0) self.disk_grow_target else 0;
        return cacheInputForStep(self.platform, self.current_storage.index_digest, step, disk_grow_target);
    }

    fn startSimpleControl(self: *BuildControl, dev: *vsock.Vsock, kind: ActiveStream) !void {
        const session_id = try checkpointSessionId(self.allocator, kind, self.step_index);
        const request = switch (kind) {
            .freeze => try run_mod.simpleControlRequest(self.allocator, "fsfreeze-v1", session_id),
            .thaw => try run_mod.simpleControlRequest(self.allocator, "fsthaw-v1", session_id),
            .resize, .run, .copy, .workdir => unreachable,
        };
        try self.startStream(dev, request, .spore_stream_v1, kind, "");
        self.phase = switch (kind) {
            .freeze => .active_freeze,
            .thaw => .active_thaw,
            .resize, .run, .copy, .workdir => unreachable,
        };
    }

    fn startStream(self: *BuildControl, dev: *vsock.Vsock, request: []const u8, protocol: vsock.HostStreamProtocol, kind: ActiveStream, stdin_payload: []const u8) !void {
        self.stream = try vsock.HostStream.initWithProtocol(guest_port, request, protocol);
        self.stream.host_port = vsock.HostStream.hostPortForSequence(self.stream_sequence);
        self.stream_sequence +%= 1;
        self.active_stream = kind;
        if (kind == .run or kind == .copy or kind == .workdir or kind == .resize) self.stream.setOutputSink(self, outputSink);
        self.active_stdin_payload = stdin_payload;
        self.active_stdin_offset = 0;
        self.active_stdin_close_sent = !(kind == .run or kind == .resize);
        try dev.attachHostStream(&self.stream);
        self.stream.markStarted();
        self.stream_valid = true;
        try self.pumpActiveStdin();
        _ = try dev.flushHostStreamOutbound();
    }

    fn pollActiveStream(self: *BuildControl, dev: *vsock.Vsock) !vsock.ControlAction {
        if (!self.stream_valid) return .keep_running;
        try self.pumpActiveStdin();
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
            .resize => {
                if (exit_code != 0) {
                    self.failure = error.BuildGuestResizeFailed;
                    self.phase = .failed;
                    return;
                }
                self.capture.clearRetainingCapacity();
                self.phase = .start_run;
            },
            .run, .copy, .workdir => {
                if (exit_code != 0) {
                    self.failed_instruction = self.steps[self.step_index].canonicalInstruction();
                    self.failed_instruction_line = self.steps[self.step_index].line();
                    self.failed_exit_code = exit_code;
                    self.phase = .failed;
                    return;
                }
                if (self.active_stream == .copy) {
                    const copy = switch (self.steps[self.step_index]) {
                        .copy => |copy| copy,
                        .run, .workdir => return error.BadManifest,
                    };
                    self.active_copy_request_index += 1;
                    if (self.active_copy_request_index < copy.requests.len) {
                        self.capture.clearRetainingCapacity();
                        self.phase = .start_copy_request;
                        return;
                    }
                }
                self.phase = .start_freeze;
            },
            .freeze => {
                self.max_checkpoint_control_ms = @max(self.max_checkpoint_control_ms, self.stream.elapsedMs());
                if (exit_code != 0) {
                    self.failure = error.BuildGuestFreezeFailed;
                    self.phase = .failed;
                    return;
                }
                self.phase = .snapshot;
            },
            .thaw => {
                self.max_checkpoint_control_ms = @max(self.max_checkpoint_control_ms, self.stream.elapsedMs());
                if (exit_code != 0) {
                    self.failure = error.BuildGuestThawFailed;
                    self.phase = .failed;
                    return;
                }
                self.step_index += 1;
                self.active_input = null;
                self.active_step_key = "";
                self.active_stdin_payload = "";
                self.active_stdin_offset = 0;
                self.active_stdin_close_sent = true;
                self.active_copy_request_index = 0;
                self.capture.clearRetainingCapacity();
                self.phase = if (self.step_index >= self.steps.len) .done else .start_run;
            },
        }
    }

    fn pumpActiveStdin(self: *BuildControl) !void {
        if (self.active_stdin_close_sent) return;
        while (self.active_stdin_offset < self.active_stdin_payload.len) {
            const written = try self.stream.enqueueStdinDataNonblocking(self.active_stdin_payload[self.active_stdin_offset..]);
            if (written == 0) return;
            self.active_stdin_offset += written;
        }
        self.active_stdin_close_sent = try self.stream.enqueueStdinCloseNonblocking();
    }

    fn completeRootfsSnapshot(self: *BuildControl, maybe_disk: ?spore.Disk) !void {
        if (self.phase != .snapshot) return;
        const disk = maybe_disk orelse return error.BadManifest;
        const storage = try runtime_disk.storageFromSnapshotDisk(self.allocator, disk);
        // A zero-dirty RUN/COPY/WORKDIR can intentionally yield child digest ==
        // parent digest; the step key still proves which instruction inputs ran.
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
            writer.writeAll(bytes) catch {};
            writer.flush() catch {};
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

fn checkpointSessionId(allocator: std.mem.Allocator, kind: ActiveStream, step_index: usize) ![]const u8 {
    const name = switch (kind) {
        .freeze => "freeze",
        .thaw => "thaw",
        .resize, .run, .copy, .workdir => unreachable,
    };
    return std.fmt.allocPrint(allocator, "spore-build-{s}-{d}", .{ name, step_index + 1 });
}

fn runRequest(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    command: []const u8,
    env: []const []const u8,
    workdir: []const u8,
    io: Io,
) ![]const u8 {
    if (command.len > max_run_command_len) return error.RunCommandTooLong;
    if (workdir.len == 0 or workdir.len > max_guest_working_dir_len) return error.RunWorkingDirUnsupported;
    if (env.len > max_guest_envc) return error.RunEnvCountUnsupported;
    for (env) |entry| if (entry.len > max_guest_env_len) return error.RunEnvTooLong;
    const now: u64 = @intCast(Io.Clock.real.now(io).nanoseconds);
    const payload = struct {
        type: []const u8 = "spore-build-run-v1",
        session_id: []const u8,
        resume_time_unix_ns: u64,
        command_len: usize,
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
        .command_len = command.len,
        .env = env,
        .working_dir = workdir,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

fn copyRequest(allocator: std.mem.Allocator, session_id: []const u8, request: CopyRequest) ![]const u8 {
    try validateCopyRequest(request);
    const payload = struct {
        type: []const u8 = "spore-build-copy-v2",
        session_id: []const u8,
        source: []const u8,
        dest: []const u8,
        source_kind: []const u8,
        dest_is_dir: bool,
        entry_count: usize,
    }{
        .session_id = session_id,
        .source = request.source,
        .dest = request.dest,
        .source_kind = @tagName(request.source_kind),
        .dest_is_dir = request.dest_is_dir,
        .entry_count = request.entry_count,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

fn workdirRequest(allocator: std.mem.Allocator, session_id: []const u8, target: []const u8) ![]const u8 {
    if (target.len == 0 or target.len > max_guest_working_dir_len or !std.fs.path.isAbsolute(target)) return error.RunWorkingDirUnsupported;
    const payload = struct {
        type: []const u8 = "spore-build-workdir-v1",
        session_id: []const u8,
        working_dir: []const u8,
    }{
        .session_id = session_id,
        .working_dir = target,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

fn validateCopyRequest(request: CopyRequest) !void {
    if (request.source.len == 0 or request.source.len > max_copy_entry_path_len) return error.CopySourceNotFound;
    if (std.fs.path.isAbsolute(request.source)) return error.CopySourceEscapesContext;
    if (!std.mem.eql(u8, request.source, ".")) {
        var source_it = std.mem.splitScalar(u8, request.source, '/');
        while (source_it.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.CopySourceEscapesContext;
        }
    }
    if (request.dest.len == 0 or request.dest.len > max_copy_entry_path_len) return error.CopyDestinationUnsupported;
    if (!std.fs.path.isAbsolute(request.dest)) return error.CopyDestinationUnsupported;
    if (std.mem.endsWith(u8, request.dest, "/")) return error.CopyDestinationUnsupported;
    var it = std.mem.splitScalar(u8, request.dest[1..], '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.CopyDestinationUnsupported;
    }
    if (request.entry_count == 0 or request.entry_count > max_copy_entries) return error.CopyEntryCountUnsupported;
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

fn fuzzSimpleRequest(_: void, s: *std.testing.Smith) !void {
    var buf: [64]u8 = undefined;
    const len = s.slice(&buf);
    const request = run_mod.simpleControlRequest(std.testing.allocator, buf[0..len], "session") catch return;
    defer std.testing.allocator.free(request);
    try std.testing.expect(request.len <= max_guest_request_len);
}

fn fuzzCopyRequest(_: void, s: *std.testing.Smith) !void {
    var path_buf: [64]u8 = undefined;
    const raw_len = s.slice(&path_buf);
    for (path_buf[0..raw_len]) |*byte| {
        if (byte.* == 0 or byte.* == '/') byte.* = 'x';
    }
    const name = if (raw_len == 0) "x" else path_buf[0..raw_len];
    var path_storage: [80]u8 = undefined;
    const dest = std.fmt.bufPrint(&path_storage, "/{s}", .{name}) catch return;
    const request = copyRequest(std.testing.allocator, "spore-build-1", .{
        .source = name,
        .dest = dest,
        .source_kind = .file,
        .dest_is_dir = false,
        .entry_count = 1,
    }) catch return;
    defer std.testing.allocator.free(request);
    try std.testing.expect(request.len <= max_guest_request_len);
    if (comptime guest_agent_fuzz_supported) {
        _ = spore_agent_fuzz_build_request(request.ptr, request.len, path_buf[0..0].ptr, 0);
    }
}

const guest_agent_fuzz_supported = builtin.os.tag == .linux and builtin.cpu.arch == .aarch64;
const guest_agent_fuzz_invalid: c_int = 0;
const guest_agent_fuzz_run_request: c_int = 1;
const guest_agent_fuzz_copy_request: c_int = 2;
const guest_agent_fuzz_run_complete: c_int = 3;
const guest_agent_fuzz_workdir_request: c_int = 4;

extern fn spore_agent_fuzz_build_request(request: [*]const u8, request_len: usize, stream: [*]const u8, stream_len: usize) c_int;
extern fn spore_agent_fuzz_proc_stat(stat: [*]const u8, stat_len: usize) c_int;

fn fuzzGuestBuildRequest(_: void, s: *std.testing.Smith) !void {
    if (comptime guest_agent_fuzz_supported) {
        var fuzz_bytes: [128]u8 = undefined;
        const fuzz_len = s.slice(&fuzz_bytes);
        const mode = if (fuzz_len == 0) 0 else fuzz_bytes[0] % 7;
        const command = if (fuzz_len <= 1) "x" else fuzz_bytes[1..fuzz_len];
        var stream: [256]u8 = undefined;
        var stream_len: usize = 0;

        if (mode == 4) {
            const request = copyRequest(std.testing.allocator, "spore-build-fuzz", .{
                .source = "input",
                .dest = "/output",
                .source_kind = .file,
                .dest_is_dir = false,
                .entry_count = 1,
            }) catch return;
            defer std.testing.allocator.free(request);
            _ = spore_agent_fuzz_build_request(request.ptr, request.len, stream[0..0].ptr, 0);
            return;
        }

        if (mode == 2) {
            const request = "{\"type\":\"spore-build-run-v1\",\"command_len\":65537}\n";
            _ = spore_agent_fuzz_build_request(request.ptr, request.len, stream[0..0].ptr, 0);
            return;
        }

        if (mode == 5) {
            const request = if (fuzz_len <= 1) fuzz_bytes[0..0] else fuzz_bytes[1..fuzz_len];
            _ = spore_agent_fuzz_build_request(request.ptr, request.len, stream[0..0].ptr, 0);
            return;
        }

        if (mode == 6) {
            const request = workdirRequest(std.testing.allocator, "spore-build-fuzz", "/work") catch return;
            defer std.testing.allocator.free(request);
            _ = spore_agent_fuzz_build_request(request.ptr, request.len, stream[0..0].ptr, 0);
            return;
        }

        const request = runRequest(std.testing.allocator, "spore-build-fuzz", command, &.{}, "/", std.testing.io) catch return;
        defer std.testing.allocator.free(request);
        appendTestSpioFrame(&stream, &stream_len, 1, if (mode == 1) 1 else 0, command);
        if (mode != 3) appendTestSpioFrame(&stream, &stream_len, 2, command.len, "");
        _ = spore_agent_fuzz_build_request(request.ptr, request.len, stream[0..stream_len].ptr, stream_len);
    }
}

fn fuzzGuestProcStat(_: void, s: *std.testing.Smith) !void {
    if (comptime guest_agent_fuzz_supported) {
        var bytes: [256]u8 = undefined;
        const len = s.slice(&bytes);
        _ = spore_agent_fuzz_proc_stat(bytes[0..len].ptr, len);
    }
}

fn appendTestSpioFrame(out: []u8, cursor: *usize, frame_type: u8, offset: u64, payload: []const u8) void {
    var header: [24]u8 = @splat(0);
    @memcpy(header[0..4], "SPIO");
    header[4] = 1;
    header[5] = frame_type;
    std.mem.writeInt(u32, header[8..12], 1, .little);
    std.mem.writeInt(u64, header[12..20], offset, .little);
    std.mem.writeInt(u32, header[20..24], @intCast(payload.len), .little);
    std.debug.assert(cursor.* + header.len + payload.len <= out.len);
    @memcpy(out[cursor.*..][0..header.len], &header);
    cursor.* += header.len;
    @memcpy(out[cursor.*..][0..payload.len], payload);
    cursor.* += payload.len;
}

test "build fsfreeze request stays bounded" {
    const request = try run_mod.simpleControlRequest(std.testing.allocator, "fsfreeze-v1", "spore-build-freeze-1");
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.endsWith(u8, request, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, request, "\"fsfreeze-v1\"") != null);
}

test "checkpoint controls use step-specific vsock identities" {
    const allocator = std.testing.allocator;
    const freeze_one = try checkpointSessionId(allocator, .freeze, 0);
    defer allocator.free(freeze_one);
    const freeze_two = try checkpointSessionId(allocator, .freeze, 1);
    defer allocator.free(freeze_two);
    const thaw_one = try checkpointSessionId(allocator, .thaw, 0);
    defer allocator.free(thaw_one);
    const thaw_two = try checkpointSessionId(allocator, .thaw, 1);
    defer allocator.free(thaw_two);

    try std.testing.expectEqualStrings("spore-build-freeze-1", freeze_one);
    try std.testing.expectEqualStrings("spore-build-thaw-2", thaw_two);
}

test "build session network mode derives from RUN steps" {
    const copy = Step{ .copy = .{
        .canonical_instruction = "COPY . /app",
        .input_digest = "blake3:copy",
        .env_digest = "blake3:env",
        .workdir = "/",
        .requests = &.{},
    } };
    const spore_run = Step{ .run = .{
        .canonical_instruction = "RUN fetch",
        .command = "fetch",
        .env = &.{},
        .env_digest = "blake3:env",
        .workdir = "/",
        .network_mode = .spore,
    } };
    var none_run = spore_run;
    none_run.run.network_mode = .none;

    try std.testing.expectEqual(step_cache.NetworkMode.none, try networkModeForSteps(&.{copy}));
    try std.testing.expectEqual(step_cache.NetworkMode.spore, try networkModeForSteps(&.{ copy, spore_run }));
    try std.testing.expectError(error.BuildNetworkModeMismatch, networkModeForSteps(&.{ spore_run, none_run }));
}

test "build copy request names context disk source" {
    const request = try copyRequest(std.testing.allocator, "spore-build-1", .{
        .source = "src",
        .dest = "/work",
        .source_kind = .directory,
        .dest_is_dir = true,
        .entry_count = 2,
    });
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.endsWith(u8, request, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, request, "\"spore-build-copy-v2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"source\":\"src\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"dest\":\"/work\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"source_kind\":\"directory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"entry_count\":2") != null);
}

test "build workdir request names an absolute target" {
    const request = try workdirRequest(std.testing.allocator, "spore-build-1", "/work/app");
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"spore-build-workdir-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"working_dir\":\"/work/app\"") != null);
    try std.testing.expectError(error.RunWorkingDirUnsupported, workdirRequest(std.testing.allocator, "spore-build-1", "relative"));
}

test "build copy request rejects path escapes" {
    try std.testing.expectError(error.CopySourceEscapesContext, copyRequest(std.testing.allocator, "spore-build-1", .{
        .source = "../secret",
        .dest = "/app/secret",
        .source_kind = .file,
        .dest_is_dir = false,
        .entry_count = 1,
    }));
    try std.testing.expectError(error.CopyDestinationUnsupported, copyRequest(std.testing.allocator, "spore-build-1", .{
        .source = "file",
        .dest = "/app/../secret",
        .source_kind = .file,
        .dest_is_dir = false,
        .entry_count = 1,
    }));
}

test "build copy request accepts exact path bound" {
    const allocator = std.testing.allocator;
    const path = try allocator.alloc(u8, max_copy_entry_path_len);
    defer allocator.free(path);
    path[0] = '/';
    @memset(path[1..], 'a');

    const request = try copyRequest(allocator, "spore-build-1", .{
        .source = "file",
        .dest = path,
        .source_kind = .file,
        .dest_is_dir = false,
        .entry_count = 1,
    });
    defer allocator.free(request);

    const too_long = try allocator.alloc(u8, max_copy_entry_path_len + 1);
    defer allocator.free(too_long);
    too_long[0] = '/';
    @memset(too_long[1..], 'b');
    try std.testing.expectError(error.CopyDestinationUnsupported, copyRequest(allocator, "spore-build-1", .{
        .source = "file",
        .dest = too_long,
        .source_kind = .file,
        .dest_is_dir = false,
        .entry_count = 1,
    }));
}

test "build run request uses spore stream v1 start" {
    const request = try runRequest(std.testing.allocator, "spore-build-1", "echo ok", &.{"PATH=/usr/bin"}, "/work", std.testing.io);
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.endsWith(u8, request, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, request, "\"spore-build-run-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"stdio\":\"pipe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"command_len\":7") != null);
}

test "build run request accepts multi-kib command and rejects configured bound" {
    const multi_kib = "x" ** 4096;
    const request = try runRequest(std.testing.allocator, "spore-build-1", multi_kib, &.{}, "/", std.testing.io);
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"command_len\":4096") != null);
    const command = "x" ** (max_run_command_len + 1);
    try std.testing.expectError(error.RunCommandTooLong, runRequest(std.testing.allocator, "spore-build-1", command, &.{}, "/", std.testing.io));
    const workdir = "/" ** (max_guest_working_dir_len + 1);
    try std.testing.expectError(error.RunWorkingDirUnsupported, runRequest(std.testing.allocator, "spore-build-1", "true", &.{}, workdir, std.testing.io));
}

test "guest build request parser rejects malformed RUN framing and accepts build controls" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;

    const run_request = try runRequest(std.testing.allocator, "spore-build-1", "abc", &.{}, "/", std.testing.io);
    defer std.testing.allocator.free(run_request);
    var stream: [128]u8 = undefined;
    var stream_len: usize = 0;
    appendTestSpioFrame(&stream, &stream_len, 1, 0, "abc");
    appendTestSpioFrame(&stream, &stream_len, 2, 3, "");
    try std.testing.expectEqual(guest_agent_fuzz_run_complete, spore_agent_fuzz_build_request(run_request.ptr, run_request.len, stream[0..stream_len].ptr, stream_len));

    stream_len = 0;
    appendTestSpioFrame(&stream, &stream_len, 1, 1, "abc");
    appendTestSpioFrame(&stream, &stream_len, 2, 3, "");
    try std.testing.expectEqual(guest_agent_fuzz_run_request, spore_agent_fuzz_build_request(run_request.ptr, run_request.len, stream[0..stream_len].ptr, stream_len));

    stream_len = 0;
    appendTestSpioFrame(&stream, &stream_len, 1, 0, "abc");
    try std.testing.expectEqual(guest_agent_fuzz_run_request, spore_agent_fuzz_build_request(run_request.ptr, run_request.len, stream[0..stream_len].ptr, stream_len));

    const over_limit = "{\"type\":\"spore-build-run-v1\",\"command_len\":65537}\n";
    try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(over_limit.ptr, over_limit.len, stream[0..0].ptr, 0));

    const copy_request = try copyRequest(std.testing.allocator, "spore-build-1", .{
        .source = "input",
        .dest = "/output",
        .source_kind = .file,
        .dest_is_dir = false,
        .entry_count = 1,
    });
    defer std.testing.allocator.free(copy_request);
    try std.testing.expectEqual(guest_agent_fuzz_copy_request, spore_agent_fuzz_build_request(copy_request.ptr, copy_request.len, stream[0..0].ptr, 0));

    const workdir_request = try workdirRequest(std.testing.allocator, "spore-build-1", "/work");
    defer std.testing.allocator.free(workdir_request);
    try std.testing.expectEqual(guest_agent_fuzz_workdir_request, spore_agent_fuzz_build_request(workdir_request.ptr, workdir_request.len, stream[0..0].ptr, 0));
}

test "guest proc stat parser identifies kernel threads with adversarial task names" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;

    const user = "123 (user) S 1 2 3 4 5 0 0 0\n";
    try std.testing.expectEqual(@as(c_int, 0), spore_agent_fuzz_proc_stat(user.ptr, user.len));
    const kernel = "2 (name ) with spaces) S 0 0 0 0 0 2097152 0 0\n";
    try std.testing.expectEqual(@as(c_int, 1), spore_agent_fuzz_proc_stat(kernel.ptr, kernel.len));
    const malformed = "2 (unterminated S 0 0 0";
    try std.testing.expectEqual(@as(c_int, -1), spore_agent_fuzz_proc_stat(malformed.ptr, malformed.len));
}

test "fuzz build control request framing" {
    try std.testing.fuzz({}, fuzzSimpleRequest, .{});
    try std.testing.fuzz({}, fuzzCopyRequest, .{});
    try std.testing.fuzz({}, fuzzGuestBuildRequest, .{});
    try std.testing.fuzz({}, fuzzGuestProcStat, .{});
}
