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
// Provisional build-VM default; make this a `spore build` option when larger
// workloads such as `bundle install`-style RUN steps need more memory.
const build_vm_memory_bytes: u64 = 2 * 1024 * 1024 * 1024;
const max_guest_request_len = 8191;
const max_guest_arg_len = 255;
const max_guest_envc = 64;
const max_guest_env_len = 255;
const max_guest_working_dir_len = 255;
pub const max_copy_entries = 65536;
pub const max_copy_entry_path_len = 512;
pub const max_copy_entry_content_len: u64 = 1024 * 1024 * 1024;
const copy_entry_header_len = 17;
const resize_command = "resize2fs /dev/vda";

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

pub const CopyEntryKind = enum(u8) {
    directory = 'D',
    file = 'F',
    sym_link = 'L',
};

pub const CopyEntry = struct {
    kind: CopyEntryKind,
    path: []const u8,
    mode: u32,
    content: []const u8 = "",
};

pub const CopyStep = struct {
    canonical_instruction: []const u8,
    dest: []const u8,
    input_digest: []const u8,
    env_digest: []const u8,
    workdir: []const u8,
    entries: []const CopyEntry,
};

pub const Step = union(enum) {
    run: RunStep,
    copy: CopyStep,

    fn canonicalInstruction(self: Step) []const u8 {
        return switch (self) {
            .run => |step| step.canonical_instruction,
            .copy => |step| step.canonical_instruction,
        };
    }
};

pub const Options = struct {
    platform: rootfs_mod.Platform,
    cache_root: []const u8,
    base_storage: spore.RootfsStorage,
    steps: []const Step,
    network_enabled: bool,
    disk_grow_target: u64 = 0,
    output: ?*Io.Writer = null,
    diagnostic: ?*Diagnostic = null,
};

pub fn cacheInputForStep(platform: rootfs_mod.Platform, parent_index_digest: []const u8, step: Step, disk_grow_target: u64) step_cache.StepInput {
    return switch (step) {
        .run => |run| .{
            .platform = platform,
            .parent_index_digest = parent_index_digest,
            .instruction_kind = "RUN",
            .canonical_instruction = run.canonical_instruction,
            .disk_grow_target = disk_grow_target,
            .env_digest = run.env_digest,
            .workdir = run.workdir,
        },
        .copy => |copy| .{
            .platform = platform,
            .parent_index_digest = parent_index_digest,
            .instruction_kind = "COPY",
            .canonical_instruction = copy.canonical_instruction,
            .disk_grow_target = disk_grow_target,
            .input_digest = copy.input_digest,
            .env_digest = copy.env_digest,
            .workdir = copy.workdir,
        },
    };
}

const Phase = enum {
    start_resize,
    active_resize,
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
    resize,
    run,
    copy,
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
        .rootfs_grow_target = options.disk_grow_target,
        .command = &.{},
        .memory = .{ .policy = .explicit, .bytes = build_vm_memory_bytes },
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
    active_input: ?step_cache.StepInput = null,
    active_step_key: []const u8 = "",
    active_stdin_payload: []const u8 = "",
    active_stdin_offset: usize = 0,
    active_stdin_close_sent: bool = true,
    capture: std.array_list.Managed(u8),
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
        try self.startStream(dev, request, .spore_stream_v1, .resize, "");
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
                try self.startStream(dev, request, .spore_stream_v1, .run, "");
            },
            .copy => |copy| {
                const request = try copyRequest(self.allocator, session_id, copy.dest, copy.entries.len);
                const payload = try encodeCopyPayload(self.allocator, copy.entries);
                try self.startStream(dev, request, .spore_stream_v1, .copy, payload);
            },
        }
        self.phase = .active_run;
    }

    fn stepInput(self: BuildControl, step: Step) step_cache.StepInput {
        const disk_grow_target = if (self.step_index == 0) self.disk_grow_target else 0;
        return cacheInputForStep(self.platform, self.current_storage.index_digest, step, disk_grow_target);
    }

    fn startSimpleControl(self: *BuildControl, dev: *vsock.Vsock, kind: ActiveStream) !void {
        const request = switch (kind) {
            .freeze => try simpleRequest(self.allocator, "fsfreeze-v1", "spore-build-freeze"),
            .thaw => try simpleRequest(self.allocator, "fsthaw-v1", "spore-build-thaw"),
            .resize, .run, .copy => unreachable,
        };
        try self.startStream(dev, request, .spore_stream_v1, kind, "");
        self.phase = switch (kind) {
            .freeze => .active_freeze,
            .thaw => .active_thaw,
            .resize, .run, .copy => unreachable,
        };
    }

    fn startStream(self: *BuildControl, dev: *vsock.Vsock, request: []const u8, protocol: vsock.HostStreamProtocol, kind: ActiveStream, stdin_payload: []const u8) !void {
        self.stream = try vsock.HostStream.initWithProtocol(guest_port, request, protocol);
        self.stream.host_port = vsock.HostStream.deriveHostPort(request);
        self.active_stream = kind;
        if (kind == .run or kind == .copy or kind == .resize) self.stream.setOutputSink(self, outputSink);
        self.active_stdin_payload = stdin_payload;
        self.active_stdin_offset = 0;
        self.active_stdin_close_sent = !(kind == .run or kind == .copy or kind == .resize);
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
            .run, .copy => {
                if (exit_code != 0) {
                    self.failed_instruction = self.steps[self.step_index].canonicalInstruction();
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
                self.active_stdin_payload = "";
                self.active_stdin_offset = 0;
                self.active_stdin_close_sent = true;
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
        const storage = try storageFromDisk(self.allocator, disk);
        // A zero-dirty RUN/COPY can intentionally yield child digest == parent
        // digest; the step key still proves which instruction/env/input ran.
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

fn copyRequest(allocator: std.mem.Allocator, session_id: []const u8, dest: []const u8, entry_count: usize) ![]const u8 {
    if (dest.len == 0 or dest.len > max_copy_entry_path_len) return error.CopyDestinationUnsupported;
    if (entry_count > max_copy_entries) return error.CopyEntryCountUnsupported;
    const payload = struct {
        type: []const u8 = "spore-copy-v1",
        session_id: []const u8,
        dest: []const u8,
        entry_count: usize,
    }{
        .session_id = session_id,
        .dest = dest,
        .entry_count = entry_count,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

pub fn encodeCopyPayload(allocator: std.mem.Allocator, entries: []const CopyEntry) ![]const u8 {
    if (entries.len > max_copy_entries) return error.CopyEntryCountUnsupported;
    var total: usize = 0;
    for (entries) |entry| {
        try validateCopyEntry(entry);
        total = std.math.add(usize, total, copy_entry_header_len) catch return error.CopyPayloadTooLarge;
        total = std.math.add(usize, total, entry.path.len) catch return error.CopyPayloadTooLarge;
        total = std.math.add(usize, total, entry.content.len) catch return error.CopyPayloadTooLarge;
    }
    const payload = try allocator.alloc(u8, total);
    var offset: usize = 0;
    for (entries) |entry| {
        payload[offset] = @intFromEnum(entry.kind);
        std.mem.writeInt(u32, payload[offset + 1 ..][0..4], entry.mode, .little);
        std.mem.writeInt(u32, payload[offset + 5 ..][0..4], @intCast(entry.path.len), .little);
        std.mem.writeInt(u64, payload[offset + 9 ..][0..8], @intCast(entry.content.len), .little);
        offset += copy_entry_header_len;
        @memcpy(payload[offset..][0..entry.path.len], entry.path);
        offset += entry.path.len;
        @memcpy(payload[offset..][0..entry.content.len], entry.content);
        offset += entry.content.len;
    }
    return payload;
}

fn validateCopyEntry(entry: CopyEntry) !void {
    if (entry.path.len == 0 or entry.path.len > max_copy_entry_path_len) return error.CopyDestinationUnsupported;
    if (!std.fs.path.isAbsolute(entry.path)) return error.CopyDestinationUnsupported;
    if (std.mem.endsWith(u8, entry.path, "/")) return error.CopyDestinationUnsupported;
    var it = std.mem.splitScalar(u8, entry.path[1..], '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.CopyDestinationUnsupported;
    }
    if (entry.content.len > max_copy_entry_content_len) return error.CopyPayloadTooLarge;
    switch (entry.kind) {
        .directory => {
            if (entry.content.len != 0) return error.CopyPayloadTooLarge;
        },
        .file => {},
        .sym_link => {
            if (entry.content.len > max_copy_entry_path_len) return error.CopyPayloadTooLarge;
        },
    }
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

fn fuzzCopyPayload(_: void, s: *std.testing.Smith) !void {
    var path_buf: [64]u8 = undefined;
    const raw_len = s.slice(&path_buf);
    for (path_buf[0..raw_len]) |*byte| {
        if (byte.* == 0 or byte.* == '/') byte.* = 'x';
    }
    const name = if (raw_len == 0) "x" else path_buf[0..raw_len];
    var path_storage: [80]u8 = undefined;
    const path = std.fmt.bufPrint(&path_storage, "/{s}", .{name}) catch return;
    var content_buf: [128]u8 = undefined;
    const content_len = s.slice(&content_buf);
    const payload = encodeCopyPayload(std.testing.allocator, &.{.{
        .kind = .file,
        .path = path,
        .mode = 0o644,
        .content = content_buf[0..content_len],
    }}) catch return;
    defer std.testing.allocator.free(payload);
    try std.testing.expect(payload.len == copy_entry_header_len + path.len + content_len);
}

test "build fsfreeze request stays bounded" {
    const request = try simpleRequest(std.testing.allocator, "fsfreeze-v1", "spore-build-freeze");
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.endsWith(u8, request, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, request, "\"fsfreeze-v1\"") != null);
}

test "build copy request uses spore copy v1" {
    const request = try copyRequest(std.testing.allocator, "spore-build-1", "/work", 2);
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.endsWith(u8, request, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, request, "\"spore-copy-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"dest\":\"/work\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"entry_count\":2") != null);
}

test "build copy payload encodes bounded entries" {
    const payload = try encodeCopyPayload(std.testing.allocator, &.{
        .{ .kind = .directory, .path = "/app", .mode = 0o755 },
        .{ .kind = .file, .path = "/app/file", .mode = 0o640, .content = "data" },
        .{ .kind = .sym_link, .path = "/app/link", .mode = 0o777, .content = "file" },
    });
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqual(@as(usize, (copy_entry_header_len * 3) + "/app".len + "/app/file".len + 4 + "/app/link".len + 4), payload.len);
    try std.testing.expectEqual(@as(u8, 'D'), payload[0]);
    try std.testing.expectEqual(@as(u32, 0o755), std.mem.readInt(u32, payload[1..5], .little));
    try std.testing.expectEqual(@as(u32, "/app".len), std.mem.readInt(u32, payload[5..9], .little));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, payload[9..17], .little));
}

test "build copy payload rejects path escapes" {
    try std.testing.expectError(error.CopyDestinationUnsupported, encodeCopyPayload(std.testing.allocator, &.{.{
        .kind = .file,
        .path = "/app/../secret",
        .mode = 0o644,
        .content = "x",
    }}));
    try std.testing.expectError(error.CopyDestinationUnsupported, encodeCopyPayload(std.testing.allocator, &.{.{
        .kind = .file,
        .path = "relative",
        .mode = 0o644,
        .content = "x",
    }}));
}

test "build copy payload accepts exact path bound" {
    const allocator = std.testing.allocator;
    const path = try allocator.alloc(u8, max_copy_entry_path_len);
    defer allocator.free(path);
    path[0] = '/';
    @memset(path[1..], 'a');

    const payload = try encodeCopyPayload(allocator, &.{.{
        .kind = .file,
        .path = path,
        .mode = 0o644,
        .content = "x",
    }});
    defer allocator.free(payload);

    const request = try copyRequest(allocator, "spore-build-1", path, 1);
    defer allocator.free(request);

    const too_long = try allocator.alloc(u8, max_copy_entry_path_len + 1);
    defer allocator.free(too_long);
    too_long[0] = '/';
    @memset(too_long[1..], 'b');
    try std.testing.expectError(error.CopyDestinationUnsupported, encodeCopyPayload(allocator, &.{.{
        .kind = .file,
        .path = too_long,
        .mode = 0o644,
        .content = "x",
    }}));
    try std.testing.expectError(error.CopyDestinationUnsupported, copyRequest(allocator, "spore-build-1", too_long, 1));
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
    try std.testing.fuzz({}, fuzzCopyPayload, .{});
}
