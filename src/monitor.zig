//! Per-VM monitor process and local control protocol.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

const lifecycle = @import("lifecycle.zig");
const memory_config = @import("memory.zig");
const monitor_jail = @import("monitor_jail.zig");
const net_gateway = @import("net_gateway.zig");
const run = @import("run.zig");
const vsock = @import("virtio/vsock.zig");

const max_control_request = 4096;
const max_control_response = 128 * 1024;
const max_exec_output = 16 * 1024;
const max_suspend_path = 4096;
const default_backend = "auto";

const monitor_usage =
    \\Usage:
    \\  spore monitor NAME [options]
    \\
    \\Options:
    \\  --backend auto|hvf|kvm  Backend to run (default: auto)
    \\  --kernel Image          Kernel Image path
    \\  --initrd root.cpio      Initrd path (default: embedded minimal exec initrd)
    \\  --rootfs rootfs.ext4    Resolved rootfs image path
    \\  --image REF             Original OCI image ref for metadata
    \\  --resume DIR            Resume from a spore directory
    \\  --net                   Experimental SporeVM-managed networking
    \\  --allow-cidr CIDR       With --net, restrict public egress to this CIDR
    \\  --allow-host HOST       With --net, restrict public egress to DNS A answers for this host
    \\  --memory VALUE          Guest memory: auto, 512mb, 2gb, ... (default: auto = 16GiB)
    \\  --guest-port N          Guest vsock listen port (default: 10700)
    \\  --timeout-ms N          Exec timeout in milliseconds (default: 30000)
    \\  --console-log PATH      Write guest console output to PATH
    \\  -h, --help              Show this help
    \\
;

const MonitorOptions = struct {
    name: []const u8,
    backend: run.Backend = .auto,
    kernel_path: ?[]const u8 = null,
    initrd_path: ?[]const u8 = null,
    rootfs_path: ?[]const u8 = null,
    image_ref: ?[]const u8 = null,
    resume_dir: ?[]const u8 = null,
    network: run.NetworkMode = .disabled,
    network_policy: run.NetworkPolicy = .{},
    memory: memory_config.Config = .{},
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    console_log_path: ?[]const u8 = null,
};

const RequestState = enum {
    idle,
    pending_exec,
    active_exec,
    pending_suspend,
    active_suspend,
    pending_snapshot,
    active_snapshot,
    done,
    stop_requested,
};

pub fn cli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    const start_ms = lifecycle.monotonicMs();
    _ = stdout;
    if (args.len == 1 and (std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "help"))) {
        var out_buffer: [1024]u8 = undefined;
        var out_writer: Io.File.Writer = .init(.stdout(), init.io, &out_buffer);
        try out_writer.interface.writeAll(monitor_usage);
        try out_writer.interface.flush();
        return;
    }

    const allocator = init.arena.allocator();
    if (monitor_jail.wantsSmoke(init.environ_map)) {
        try monitor_jail.applyForMonitor(init.environ_map);
        try monitor_jail.smokeDeniedExec(init.io);
        return;
    }

    const opts = try parseMonitorArgs(args);
    const parsed_ms = lifecycle.monotonicMs();
    if (!lifecycle.monitorBackendSupported(opts.backend.name())) {
        std.debug.print("spore monitor: monitor mode requires HVF on Apple Silicon or KVM on Linux/aarch64\n", .{});
        std.process.exit(2);
    }
    if (opts.image_ref != null and opts.rootfs_path == null) {
        std.debug.print("spore monitor: --image is metadata only; pass a resolved --rootfs path\n", .{});
        std.process.exit(2);
    }
    if (opts.resume_dir != null and opts.rootfs_path != null) {
        std.debug.print("spore monitor: direct --resume with --rootfs is not supported; use lifecycle metadata for disk-backed named resume\n", .{});
        std.process.exit(2);
    }
    const full_args = try init.minimal.args.toSlice(allocator);
    var gateway: net_gateway.Process = undefined;
    var gateway_active = false;
    if (opts.network == .spore) {
        try gateway.start(init.io, allocator, full_args[0], false, opts.network_policy);
        gateway_active = true;
    }
    defer if (gateway_active) gateway.deinit();
    try monitor_jail.applyForMonitor(init.environ_map);
    const paths = try lifecycle.pathsFor(allocator, init.environ_map, opts.name);
    const paths_ms = lifecycle.monotonicMs();
    var existing_spec = lifecycle.readSpec(allocator, init.io, paths) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
    defer if (existing_spec) |*spec| spec.deinit();
    const spec_rootfs = if (existing_spec) |spec| spec.value.rootfs else null;
    const spec_disk = if (existing_spec) |spec| spec.value.disk else null;
    const kernel_path = opts.kernel_path orelse run.resolveDefaultKernelPath(init, allocator) catch |err| {
        std.debug.print("spore monitor: kernel setup failed: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    const initrd_path = run.resolveConfiguredInitrdPath(init, opts.initrd_path) catch |err| {
        std.debug.print("spore monitor: initrd setup failed: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    const assets_ms = lifecycle.monotonicMs();

    try lifecycle.writeSpec(allocator, init.io, paths, .{
        .name = opts.name,
        .backend = opts.backend.name(),
        .kernel_path = kernel_path,
        .initrd_path = initrd_path,
        .rootfs_path = opts.rootfs_path,
        .rootfs = spec_rootfs,
        .disk = spec_disk,
        .network = run.manifestNetworkFromOptions(opts.network, &opts.network_policy),
        .image_ref = opts.image_ref,
        .resume_dir = opts.resume_dir,
        .memory = opts.memory,
        .vcpus = opts.vcpus,
        .guest_port = opts.guest_port,
        .timeout_ms = opts.timeout_ms,
        .console_log_path = opts.console_log_path,
    });
    try lifecycle.writePid(allocator, init.io, paths, currentPid());

    var server = try ExecServer.init(allocator, init.io, paths.control_socket_path, opts.guest_port, opts.timeout_ms);
    const thread = try std.Thread.spawn(.{}, controlThreadMain, .{&server});
    const metadata_ms = lifecycle.monotonicMs();

    lifecycle.writeMonitorTiming(allocator, init.io, paths, .{
        .parse_ms = parsed_ms - start_ms,
        .paths_ms = paths_ms - parsed_ms,
        .asset_resolve_ms = assets_ms - paths_ms,
        .metadata_ms = metadata_ms - assets_ms,
        .ready_after_start_ms = metadata_ms - start_ms,
    }) catch {};

    try lifecycle.writeReady(allocator, init.io, paths, .{
        .pid = currentPid(),
        .control_socket_path = paths.control_socket_path,
        .console_log_path = paths.console_log_path,
    });

    try run.openConsoleLog(opts.console_log_path);
    defer run.closeConsoleLog();

    const result = run.executeMonitor(.{ .io = init.io, .environ_map = init.environ_map }, allocator, .{
        .backend = opts.backend,
        .kernel_path = kernel_path,
        .initrd_path = initrd_path,
        .rootfs_path = opts.rootfs_path,
        .rootfs = spec_rootfs,
        .disk = spec_disk,
        .resume_dir = opts.resume_dir,
        .command = &.{"/bin/true"},
        .memory = opts.memory,
        .vcpus = opts.vcpus,
        .guest_port = opts.guest_port,
        .timeout_ms = opts.timeout_ms,
        .console_log_path = opts.console_log_path,
        .network = opts.network,
        .network_policy = opts.network_policy,
        .network_runtime = if (gateway_active) gateway.runtime() else null,
        .spore_executable = full_args[0],
    }, server.control());
    if (result) |monitor_result| {
        switch (monitor_result.exit) {
            .stopped => {},
            .snapshotted => try server.completeSuspend(),
        }
        server.deinit();
        thread.join();
    } else |err| {
        server.failOutstanding("monitor backend stopped");
        server.deinit();
        thread.join();
        return err;
    }
}

const ExecServer = struct {
    allocator: std.mem.Allocator,
    io: Io,
    socket_path: []const u8,
    guest_port: u32,
    timeout_ms: u64,
    server: net.Server,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    state: RequestState = .idle,
    request: [max_control_request]u8 = undefined,
    request_len: usize = 0,
    response: [max_control_response]u8 = undefined,
    response_len: usize = 0,
    suspend_dir: [max_suspend_path]u8 = undefined,
    suspend_dir_len: usize = 0,
    active_stream: vsock.HostStream = undefined,
    active_stream_valid: bool = false,
    stdout_capture: [max_exec_output]u8 = undefined,
    stdout_capture_len: usize = 0,
    stdout_truncated: bool = false,
    stderr_capture: [max_exec_output]u8 = undefined,
    stderr_capture_len: usize = 0,
    stderr_truncated: bool = false,
    next_session_id: u64 = 1,
    next_host_port: u32 = 49152,
    wake: ?vsock.Wake = null,
    closed: std.atomic.Value(bool) = .init(false),

    fn init(allocator: std.mem.Allocator, io: Io, socket_path: []const u8, guest_port: u32, timeout_ms: u64) !ExecServer {
        Io.Dir.cwd().deleteFile(io, socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
        const address = try net.UnixAddress.init(socket_path);
        return .{
            .allocator = allocator,
            .io = io,
            .socket_path = socket_path,
            .guest_port = guest_port,
            .timeout_ms = timeout_ms,
            .server = try address.listen(io, .{ .kernel_backlog = 8 }),
        };
    }

    fn deinit(self: *ExecServer) void {
        self.closed.store(true, .release);
        self.server.deinit(self.io);
        Io.Dir.cwd().deleteFile(self.io, self.socket_path) catch {};
    }

    fn isClosed(self: *ExecServer) bool {
        return self.closed.load(.acquire);
    }

    fn control(self: *ExecServer) vsock.Control {
        return .{
            .context = self,
            .pollFn = pollThunk,
            .setWakeFn = setWakeThunk,
            .completeSnapshotFn = completeSnapshotThunk,
        };
    }

    fn setWake(self: *ExecServer, wake: vsock.Wake) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.wake = wake;
    }

    fn poll(self: *ExecServer, dev: *vsock.Vsock) !vsock.ControlAction {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        switch (self.state) {
            .idle, .done => return .keep_running,
            .stop_requested => return .stop,
            .pending_suspend => {
                self.state = .active_suspend;
                return .{ .snapshot = .{ .dir = self.suspend_dir[0..self.suspend_dir_len] } };
            },
            .active_suspend => return .keep_running,
            .pending_snapshot => {
                self.state = .active_snapshot;
                return .{ .snapshot = .{
                    .dir = self.suspend_dir[0..self.suspend_dir_len],
                    .continue_after = true,
                } };
            },
            .active_snapshot => return .keep_running,
            .pending_exec => {
                self.active_stream = try vsock.HostStream.init(self.guest_port, self.request[0..self.request_len]);
                self.resetExecCapture();
                self.active_stream.setOutputSink(self, captureOutputThunk);
                self.active_stream.host_port = self.next_host_port;
                self.next_host_port +%= 1;
                if (self.next_host_port < 49152) self.next_host_port = 49152;
                try dev.attachHostStream(&self.active_stream);
                self.active_stream.markStarted();
                self.active_stream_valid = true;
                self.state = .active_exec;
            },
            .active_exec => {},
        }

        if (self.state == .active_exec and self.active_stream_valid) {
            switch (self.active_stream.state) {
                .failed => {
                    try self.storeErrorLocked("guest vsock stream failed");
                    self.state = .done;
                    self.cond.broadcast(self.io);
                },
                .complete => {
                    const exit_code = self.active_stream.exit_code orelse {
                        try self.storeErrorLocked("guest exec missing exit code");
                        self.state = .done;
                        self.cond.broadcast(self.io);
                        return .keep_running;
                    };
                    try self.storeExecResultLocked(exit_code);
                    self.state = .done;
                    self.cond.broadcast(self.io);
                },
                else => {
                    if (self.active_stream.elapsedMs() > self.timeout_ms) {
                        try self.storeErrorLocked("guest exec timed out");
                        self.state = .done;
                        self.cond.broadcast(self.io);
                    }
                },
            }
        }
        return .keep_running;
    }

    fn submitExec(self: *ExecServer, request: []const u8) ![]const u8 {
        if (request.len > self.request.len) return error.ControlRequestTooLarge;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state != .idle) return error.ControlBusy;
        @memcpy(self.request[0..request.len], request);
        self.request_len = request.len;
        self.response_len = 0;
        self.state = .pending_exec;
        if (self.wake) |wake| wake.wake();
        self.cond.broadcast(self.io);
        while (self.state != .done) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        self.state = .idle;
        return self.response[0..self.response_len];
    }

    fn execRequest(self: *ExecServer, argv: []const []const u8) ![]const u8 {
        var id_buf: [64]u8 = undefined;
        const session_id = try std.fmt.bufPrint(&id_buf, "lifecycle-{d}", .{self.next_session_id});
        self.next_session_id +%= 1;
        if (self.next_session_id == 0) self.next_session_id = 1;
        return run.execRequestWithSession(self.allocator, argv, session_id);
    }

    fn resetExecCapture(self: *ExecServer) void {
        self.stdout_capture_len = 0;
        self.stdout_truncated = false;
        self.stderr_capture_len = 0;
        self.stderr_truncated = false;
    }

    fn captureOutput(self: *ExecServer, output: vsock.HostStreamOutput, bytes: []const u8) void {
        const capture = switch (output) {
            .stdout => &self.stdout_capture,
            .stderr => &self.stderr_capture,
        };
        const len = switch (output) {
            .stdout => &self.stdout_capture_len,
            .stderr => &self.stderr_capture_len,
        };
        const truncated = switch (output) {
            .stdout => &self.stdout_truncated,
            .stderr => &self.stderr_truncated,
        };
        const available = capture.len - len.*;
        const n = @min(bytes.len, available);
        if (n > 0) {
            @memcpy(capture[len.*..][0..n], bytes[0..n]);
            len.* += n;
        }
        if (n < bytes.len) truncated.* = true;
    }

    fn submitSuspend(self: *ExecServer, out_dir: []const u8) ![]const u8 {
        if (out_dir.len == 0 or out_dir.len > self.suspend_dir.len) return error.InvalidSuspendDir;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state != .idle) return error.ControlBusy;
        @memcpy(self.suspend_dir[0..out_dir.len], out_dir);
        self.suspend_dir_len = out_dir.len;
        self.response_len = 0;
        self.state = .pending_suspend;
        if (self.wake) |wake| wake.wake();
        self.cond.broadcast(self.io);
        while (self.state != .done) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        return self.response[0..self.response_len];
    }

    fn submitSnapshot(self: *ExecServer, out_dir: []const u8) ![]const u8 {
        if (out_dir.len == 0 or out_dir.len > self.suspend_dir.len) return error.InvalidSuspendDir;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state != .idle) return error.ControlBusy;
        @memcpy(self.suspend_dir[0..out_dir.len], out_dir);
        self.suspend_dir_len = out_dir.len;
        self.response_len = 0;
        self.state = .pending_snapshot;
        if (self.wake) |wake| wake.wake();
        self.cond.broadcast(self.io);
        while (self.state != .done) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        self.state = .idle;
        return self.response[0..self.response_len];
    }

    fn completeSuspend(self: *ExecServer) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        switch (self.state) {
            .pending_suspend, .active_suspend => {
                try self.storeSuspendResultLocked(self.suspend_dir[0..self.suspend_dir_len]);
                self.state = .done;
                self.cond.broadcast(self.io);
            },
            else => {},
        }
    }

    fn completeSnapshot(self: *ExecServer, dir: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        switch (self.state) {
            .pending_snapshot, .active_snapshot => {
                try self.storeSnapshotResultLocked(dir);
                self.state = .done;
                self.cond.broadcast(self.io);
            },
            else => {},
        }
    }

    fn requestStop(self: *ExecServer) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.state = .stop_requested;
        if (self.wake) |wake| wake.wake();
        self.cond.broadcast(self.io);
    }

    fn failOutstanding(self: *ExecServer, message: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        switch (self.state) {
            .pending_exec, .active_exec, .pending_suspend, .active_suspend, .pending_snapshot, .active_snapshot => {
                self.storeErrorLocked(message) catch {
                    self.response_len = 0;
                };
                self.state = .done;
                self.cond.broadcast(self.io);
            },
            else => {},
        }
    }

    fn storeExecResultLocked(self: *ExecServer, exit_code: i32) !void {
        const stdout_b64 = try base64Alloc(self.allocator, self.stdout_capture[0..self.stdout_capture_len]);
        defer self.allocator.free(stdout_b64);
        const stderr_b64 = try base64Alloc(self.allocator, self.stderr_capture[0..self.stderr_capture_len]);
        defer self.allocator.free(stderr_b64);
        const payload = struct {
            type: []const u8 = "exec_result",
            exit_code: i32,
            stdout_b64: []const u8,
            stderr_b64: []const u8,
            stdout_truncated: bool,
            stderr_truncated: bool,
        }{
            .exit_code = exit_code,
            .stdout_b64 = stdout_b64,
            .stderr_b64 = stderr_b64,
            .stdout_truncated = self.stdout_truncated,
            .stderr_truncated = self.stderr_truncated,
        };
        try self.storeJsonLocked(payload);
    }

    fn storeSuspendResultLocked(self: *ExecServer, out_dir: []const u8) !void {
        const payload = struct {
            type: []const u8 = "suspended",
            out_dir: []const u8,
        }{ .out_dir = out_dir };
        try self.storeJsonLocked(payload);
    }

    fn storeSnapshotResultLocked(self: *ExecServer, out_dir: []const u8) !void {
        const payload = struct {
            type: []const u8 = "snapshotted",
            out_dir: []const u8,
        }{ .out_dir = out_dir };
        try self.storeJsonLocked(payload);
    }

    fn storeErrorLocked(self: *ExecServer, message: []const u8) !void {
        const payload = struct {
            type: []const u8 = "error",
            message: []const u8,
        }{ .message = message };
        try self.storeJsonLocked(payload);
    }

    fn storeJsonLocked(self: *ExecServer, payload: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(self.allocator, payload, .{});
        defer self.allocator.free(json);
        if (json.len + 1 > self.response.len) return error.ControlResponseTooLarge;
        @memcpy(self.response[0..json.len], json);
        self.response[json.len] = '\n';
        self.response_len = json.len + 1;
    }

    fn pollThunk(context: *anyopaque, dev: *vsock.Vsock) !vsock.ControlAction {
        const self: *ExecServer = @ptrCast(@alignCast(context));
        return self.poll(dev);
    }

    fn setWakeThunk(context: *anyopaque, wake: vsock.Wake) void {
        const self: *ExecServer = @ptrCast(@alignCast(context));
        self.setWake(wake);
    }

    fn completeSnapshotThunk(context: *anyopaque, dir: []const u8) !void {
        const self: *ExecServer = @ptrCast(@alignCast(context));
        try self.completeSnapshot(dir);
    }

    fn captureOutputThunk(context: ?*anyopaque, output: vsock.HostStreamOutput, bytes: []const u8) void {
        const self: *ExecServer = @ptrCast(@alignCast(context.?));
        self.captureOutput(output, bytes);
    }
};

fn base64Alloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(out, bytes);
    return out;
}

fn controlThreadMain(server: *ExecServer) void {
    while (true) {
        var stream = server.server.accept(server.io) catch {
            if (server.isClosed()) return;
            continue;
        };
        const stop = handleControlClient(server, stream) catch false;
        stream.close(server.io);
        if (stop) return;
    }
}

fn handleControlClient(server: *ExecServer, stream: net.Stream) !bool {
    var read_buffer: [max_control_request]u8 = undefined;
    var reader = stream.reader(server.io, &read_buffer);
    const line = try reader.interface.takeDelimiterExclusive('\n');
    var parsed = std.json.parseFromSlice(ControlRequest, server.allocator, line, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch {
        try writeControlError(server.io, stream, "bad control request");
        return false;
    };
    defer parsed.deinit();

    if (std.mem.eql(u8, parsed.value.type, "shutdown")) {
        server.requestStop();
        try writeControlOk(server.io, stream);
        return true;
    }
    if (std.mem.eql(u8, parsed.value.type, "suspend")) {
        const out_dir = parsed.value.out_dir orelse {
            try writeControlError(server.io, stream, "suspend request missing out_dir");
            return false;
        };
        const response = server.submitSuspend(out_dir) catch {
            try writeControlError(server.io, stream, "monitor busy");
            return false;
        };
        try writeAll(server.io, stream, response);
        return true;
    }
    if (std.mem.eql(u8, parsed.value.type, "snapshot")) {
        const out_dir = parsed.value.out_dir orelse {
            try writeControlError(server.io, stream, "snapshot request missing out_dir");
            return false;
        };
        const continue_after = parsed.value.@"continue" orelse false;
        if (!continue_after) {
            try writeControlError(server.io, stream, "snapshot request must set continue=true");
            return false;
        }
        const response = server.submitSnapshot(out_dir) catch {
            try writeControlError(server.io, stream, "monitor busy");
            return false;
        };
        try writeAll(server.io, stream, response);
        return false;
    }
    if (!std.mem.eql(u8, parsed.value.type, "exec")) {
        try writeControlError(server.io, stream, "unknown control request");
        return false;
    }
    const argv = parsed.value.argv orelse {
        try writeControlError(server.io, stream, "exec request missing argv");
        return false;
    };
    const request = server.execRequest(argv) catch {
        try writeControlError(server.io, stream, "invalid argv");
        return false;
    };
    defer server.allocator.free(request);
    const response = server.submitExec(request) catch {
        try writeControlError(server.io, stream, "monitor busy");
        return false;
    };
    try writeAll(server.io, stream, response);
    return false;
}

const ControlRequest = struct {
    type: []const u8,
    argv: ?[]const []const u8 = null,
    out_dir: ?[]const u8 = null,
    @"continue": ?bool = null,
};

fn writeControlOk(io: Io, stream: net.Stream) !void {
    try writeAll(io, stream, "{\"type\":\"ok\"}\n");
}

fn writeControlError(io: Io, stream: net.Stream, message: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const payload = struct {
        type: []const u8 = "error",
        message: []const u8,
    }{ .message = message };
    const json = try std.json.Stringify.valueAlloc(fixed.allocator(), payload, .{});
    try writeAll(io, stream, json);
    try writeAll(io, stream, "\n");
}

fn writeAll(io: Io, stream: net.Stream, bytes: []const u8) !void {
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn parseMonitorArgs(args: []const []const u8) !MonitorOptions {
    if (args.len == 0) usageExit();
    var opts = MonitorOptions{ .name = args[0] };
    try lifecycle.validateName(opts.name);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--backend")) {
            opts.backend = run.Backend.parse(takeValue(args, &i, args[i])) orelse {
                std.debug.print("--backend must be auto, hvf, or kvm\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--kernel")) {
            opts.kernel_path = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--initrd")) {
            opts.initrd_path = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--rootfs")) {
            opts.rootfs_path = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--image")) {
            opts.image_ref = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--resume")) {
            opts.resume_dir = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--net")) {
            opts.network = .spore;
        } else if (std.mem.eql(u8, args[i], "--allow-cidr")) {
            const raw = takeValue(args, &i, args[i]);
            opts.network_policy.addAllowCidr(raw) catch |err| {
                std.debug.print("spore monitor: invalid --allow-cidr {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--allow-host")) {
            const raw = takeValue(args, &i, args[i]);
            opts.network_policy.addAllowHost(raw) catch |err| {
                std.debug.print("spore monitor: invalid --allow-host {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--memory")) {
            opts.memory = memory_config.parseCliOrExit("spore monitor", takeValue(args, &i, args[i]));
        } else if (std.mem.eql(u8, args[i], "--memory-mib")) {
            memory_config.rejectMemoryMiBFlag("spore monitor");
        } else if (std.mem.eql(u8, args[i], "--vcpus")) {
            opts.vcpus = try parsePositive(u32, args[i], takeValue(args, &i, args[i]));
        } else if (std.mem.eql(u8, args[i], "--guest-port")) {
            opts.guest_port = try parsePositive(u32, args[i], takeValue(args, &i, args[i]));
        } else if (std.mem.eql(u8, args[i], "--timeout-ms")) {
            opts.timeout_ms = try parsePositive(u64, args[i], takeValue(args, &i, args[i]));
        } else if (std.mem.eql(u8, args[i], "--console-log")) {
            opts.console_log_path = takeValue(args, &i, args[i]);
        } else {
            std.debug.print("unknown monitor argument: {s}\n\n{s}", .{ args[i], monitor_usage });
            std.process.exit(2);
        }
    }
    if (opts.network == .disabled and opts.network_policy.hasRules()) {
        std.debug.print("spore monitor: --allow-cidr and --allow-host require --net\n", .{});
        std.process.exit(2);
    }
    return opts;
}

fn usageExit() noreturn {
    std.debug.print("{s}", .{monitor_usage});
    std.process.exit(2);
}

fn takeValue(args: []const []const u8, i: *usize, flag: []const u8) []const u8 {
    if (i.* + 1 >= args.len) {
        std.debug.print("{s} requires a value\n", .{flag});
        std.process.exit(2);
    }
    i.* += 1;
    return args[i.*];
}

fn parsePositive(comptime T: type, name: []const u8, raw: []const u8) !T {
    const parsed = std.fmt.parseInt(T, raw, 10) catch {
        std.debug.print("{s} must be a positive integer\n", .{name});
        std.process.exit(2);
    };
    if (parsed == 0) {
        std.debug.print("{s} must be a positive integer\n", .{name});
        std.process.exit(2);
    }
    return parsed;
}

fn currentPid() i64 {
    if (comptime @import("builtin").os.tag == .windows) return 1;
    return @intCast(std.c.getpid());
}

test "monitor parser accepts network allow policy" {
    const opts = try parseMonitorArgs(&.{
        "bench-1",
        "--net",
        "--allow-cidr",
        "93.184.216.34/32",
        "--allow-host",
        "example.com",
    });

    try std.testing.expectEqual(run.NetworkMode.spore, opts.network);
    try std.testing.expectEqual(@as(usize, 1), opts.network_policy.allow_cidr_count);
    try std.testing.expectEqualStrings("93.184.216.34/32", opts.network_policy.allow_cidrs[0]);
    try std.testing.expectEqual(@as(usize, 1), opts.network_policy.allow_host_count);
    try std.testing.expectEqualStrings("example.com", opts.network_policy.allow_hosts[0]);
}
