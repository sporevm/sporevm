//! Per-VM monitor process and local control protocol.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

const lifecycle = @import("lifecycle.zig");
const memory_config = @import("memory.zig");
const monitor_jail = @import("monitor_jail.zig");
const net_gateway = @import("net_gateway.zig");
const run = @import("run.zig");
const spore = @import("spore.zig");
const spore_net_policy = @import("spore_net_policy.zig");
const spore_stream = @import("spore_stream.zig");
const topology = @import("topology.zig");
const version = @import("version.zig");
const vsock = @import("virtio/vsock.zig");

const max_control_request = 4096;
const max_control_response = 128 * 1024;
const max_exec_output = 16 * 1024;
const max_suspend_path = 4096;
const stats_write_interval_ms = 250;

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
    \\  --allow-host-port HOST:PORT
    \\                          With --net, allow only DNS-learned HOST on PORT
    \\  --bound-unix-service NAME HOST PORT PATH
    \\                          With --net, expose a host Unix socket as HOST:PORT
    \\  --forward 127.0.0.1:HOST_PORT:GUEST_PORT
    \\                          With --net, forward host loopback TCP to a guest port
    \\  --memory VALUE          Guest memory: auto, 512mb, 2gb, ... (default: auto = 16GiB)
    \\  --vcpus N               Guest vCPU count (1-8; backend-dependent)
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
    vcpus: topology.VcpuCount = 1,
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
    topology.validateVcpuCount(opts.vcpus) catch {
        std.debug.print("spore monitor: unsupported vCPU count\n", .{});
        std.process.exit(2);
    };
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
    const spec_annotations = if (existing_spec) |spec| spec.value.annotations else spore.Annotations{};
    const spec_sessions = if (existing_spec) |spec|
        if (spec.value.sessions.len != 0) spec.value.sessions else sessionHandlesForResume(allocator, opts.resume_dir)
    else
        sessionHandlesForResume(allocator, opts.resume_dir);
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
        .network = try run.manifestNetworkFromOptions(allocator, opts.network, &opts.network_policy),
        .annotations = spec_annotations,
        .sessions = spec_sessions,
        .image_ref = opts.image_ref,
        .resume_dir = opts.resume_dir,
        .memory = opts.memory,
        .vcpus = opts.vcpus,
        .guest_port = opts.guest_port,
        .timeout_ms = opts.timeout_ms,
        .console_log_path = opts.console_log_path,
    });
    try lifecycle.writePid(allocator, init.io, paths, currentPid());

    var server = try ExecServer.init(allocator, init.io, paths.control_socket_path, paths.monitor_stats_path, opts.guest_port, opts.timeout_ms);
    if (gateway_active) server.network_events = &gateway;
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
        .resume_sessions = spec_sessions,
        .annotations = spec_annotations,
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
    stats_path: []const u8,
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
    active_stream_protocol: vsock.HostStreamProtocol = .legacy_text,
    active_streaming_exec: bool = false,
    streaming_client_fd: std.c.fd_t = -1,
    streaming_stdout_offset: u64 = 0,
    streaming_stderr_offset: u64 = 0,
    streaming_terminal_offset: u64 = 0,
    streaming_write_failed: bool = false,
    stdout_capture: [max_exec_output]u8 = undefined,
    stdout_capture_len: usize = 0,
    stdout_truncated: bool = false,
    stderr_capture: [max_exec_output]u8 = undefined,
    stderr_capture_len: usize = 0,
    stderr_truncated: bool = false,
    network_events: ?*net_gateway.Process = null,
    next_session_id: u64 = 1,
    next_host_port: u32 = 49152,
    wake: ?vsock.Wake = null,
    stats_written: bool = false,
    stats_written_value: vsock.ControlStats = .{},
    stats_write_ms: u64 = 0,
    closed: std.atomic.Value(bool) = .init(false),

    fn init(allocator: std.mem.Allocator, io: Io, socket_path: []const u8, stats_path: []const u8, guest_port: u32, timeout_ms: u64) !ExecServer {
        Io.Dir.cwd().deleteFile(io, socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
        const address = try net.UnixAddress.init(socket_path);
        return .{
            .allocator = allocator,
            .io = io,
            .socket_path = socket_path,
            .stats_path = stats_path,
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
            .reportStatsFn = reportStatsThunk,
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
                self.active_stream = try vsock.HostStream.initWithProtocol(self.guest_port, self.request[0..self.request_len], self.active_stream_protocol);
                self.resetExecCapture();
                if (self.active_streaming_exec) {
                    self.resetStreamingOffsets();
                    self.active_stream.setOutputSink(self, streamOutputThunk);
                } else {
                    self.active_stream.setOutputSink(self, captureOutputThunk);
                }
                self.active_stream.host_port = self.next_host_port;
                self.next_host_port +%= 1;
                if (self.next_host_port < 49152) self.next_host_port = 49152;
                try dev.attachHostStream(&self.active_stream);
                self.active_stream.markStarted();
                self.active_stream_valid = true;
                self.state = .active_exec;
                self.cond.broadcast(self.io);
            },
            .active_exec => {},
        }

        if (self.state == .active_exec and self.active_stream_valid) {
            if (self.streaming_write_failed) self.active_stream.fail();
            _ = try dev.flushHostStreamOutbound();
            switch (self.active_stream.state) {
                .failed => {
                    if (self.active_streaming_exec) {
                        self.sendStreamingErrorLocked("guest vsock stream failed");
                    } else {
                        try self.storeErrorLocked("guest vsock stream failed");
                    }
                    self.state = .done;
                    self.cond.broadcast(self.io);
                },
                .complete => {
                    const exit_code = self.active_stream.exit_code orelse {
                        if (self.active_streaming_exec) {
                            self.sendStreamingErrorLocked("guest exec missing exit code");
                        } else {
                            try self.storeErrorLocked("guest exec missing exit code");
                        }
                        self.state = .done;
                        self.cond.broadcast(self.io);
                        return .keep_running;
                    };
                    if (self.active_streaming_exec) {
                        self.sendStreamingExitLocked(exit_code);
                    } else {
                        try self.storeExecResultLocked(exit_code);
                    }
                    self.state = .done;
                    self.cond.broadcast(self.io);
                },
                else => {
                    if (self.active_stream.elapsedMs() > self.timeout_ms) {
                        if (self.active_streaming_exec) {
                            self.sendStreamingErrorLocked("guest exec timed out");
                        } else {
                            try self.storeErrorLocked("guest exec timed out");
                        }
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
        while (self.state == .done) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        if (self.state != .idle) return error.ControlBusy;
        @memcpy(self.request[0..request.len], request);
        self.request_len = request.len;
        self.response_len = 0;
        self.active_stream_protocol = .legacy_text;
        self.active_streaming_exec = false;
        self.streaming_client_fd = -1;
        if (self.network_events) |events| events.clearEvents();
        self.state = .pending_exec;
        if (self.wake) |wake| wake.wake();
        self.cond.broadcast(self.io);
        while (self.state != .done) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        self.state = .idle;
        return self.response[0..self.response_len];
    }

    fn submitStreamingExec(self: *ExecServer, request: []const u8, client_fd: std.c.fd_t) !void {
        if (request.len > self.request.len) return error.ControlRequestTooLarge;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.state == .done) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        if (self.state != .idle) return error.ControlBusy;
        @memcpy(self.request[0..request.len], request);
        self.request_len = request.len;
        self.response_len = 0;
        self.active_stream_protocol = .spore_stream_v1;
        self.active_streaming_exec = true;
        self.streaming_client_fd = client_fd;
        self.streaming_write_failed = false;
        if (self.network_events) |events| events.clearEvents();
        self.state = .pending_exec;
        if (self.wake) |wake| wake.wake();
        self.cond.broadcast(self.io);
        while (self.state == .pending_exec) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
    }

    fn finishStreamingExec(self: *ExecServer) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.state != .done and self.state != .idle) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        self.active_streaming_exec = false;
        self.streaming_client_fd = -1;
        if (self.state == .done) {
            self.state = .idle;
            self.cond.broadcast(self.io);
        }
    }

    fn streamingDone(self: *ExecServer) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state == .done or self.state == .idle;
    }

    fn execRequest(self: *ExecServer, argv: []const []const u8) ![]const u8 {
        var id_buf: [64]u8 = undefined;
        const session_id = try std.fmt.bufPrint(&id_buf, "lifecycle-{d}", .{self.next_session_id});
        self.next_session_id +%= 1;
        if (self.next_session_id == 0) self.next_session_id = 1;
        return run.execRequestWithSession(self.allocator, argv, session_id);
    }

    fn interactiveExecRequest(self: *ExecServer, argv: []const []const u8, interactive: bool, tty: bool, terminal_name: []const u8, terminal_size: spore_stream.Resize) ![]const u8 {
        var id_buf: [64]u8 = undefined;
        const session_id = try std.fmt.bufPrint(&id_buf, "lifecycle-{d}", .{self.next_session_id});
        self.next_session_id +%= 1;
        if (self.next_session_id == 0) self.next_session_id = 1;
        return run.interactiveExecRequestWithSession(self.allocator, argv, session_id, .{
            .interactive = interactive,
            .tty = tty,
            .terminal_name = terminal_name,
            .terminal_size = terminal_size,
        });
    }

    fn detachedExecRequest(self: *ExecServer, argv: []const []const u8) ![]const u8 {
        var id_buf: [64]u8 = undefined;
        const session_id = try std.fmt.bufPrint(&id_buf, "lifecycle-{d}", .{self.next_session_id});
        self.next_session_id +%= 1;
        if (self.next_session_id == 0) self.next_session_id = 1;
        return run.detachedExecRequestWithSession(self.allocator, argv, session_id);
    }

    fn copyRequest(self: *ExecServer, request_type: []const u8, path: []const u8) ![]const u8 {
        var id_buf: [64]u8 = undefined;
        const session_id = try std.fmt.bufPrint(&id_buf, "lifecycle-{d}", .{self.next_session_id});
        self.next_session_id +%= 1;
        if (self.next_session_id == 0) self.next_session_id = 1;
        const payload = struct {
            type: []const u8,
            session_id: []const u8,
            path: []const u8,
        }{
            .type = request_type,
            .session_id = session_id,
            .path = path,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, payload, .{});
        defer self.allocator.free(json);
        return std.fmt.allocPrint(self.allocator, "{s}\n", .{json});
    }

    fn resetExecCapture(self: *ExecServer) void {
        self.stdout_capture_len = 0;
        self.stdout_truncated = false;
        self.stderr_capture_len = 0;
        self.stderr_truncated = false;
    }

    fn resetStreamingOffsets(self: *ExecServer) void {
        self.streaming_stdout_offset = 0;
        self.streaming_stderr_offset = 0;
        self.streaming_terminal_offset = 0;
        self.streaming_write_failed = false;
    }

    fn captureOutput(self: *ExecServer, output: vsock.HostStreamOutput, bytes: []const u8) void {
        const capture = switch (output) {
            .stdout => &self.stdout_capture,
            .stderr => &self.stderr_capture,
            .terminal => &self.stdout_capture,
        };
        const len = switch (output) {
            .stdout => &self.stdout_capture_len,
            .stderr => &self.stderr_capture_len,
            .terminal => &self.stdout_capture_len,
        };
        const truncated = switch (output) {
            .stdout => &self.stdout_truncated,
            .stderr => &self.stderr_truncated,
            .terminal => &self.stdout_truncated,
        };
        const available = capture.len - len.*;
        const n = @min(bytes.len, available);
        if (n > 0) {
            @memcpy(capture[len.*..][0..n], bytes[0..n]);
            len.* += n;
        }
        if (n < bytes.len) truncated.* = true;
    }

    fn streamOutput(self: *ExecServer, output: vsock.HostStreamOutput, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const fd = self.streaming_client_fd;
        if (fd < 0 or self.streaming_write_failed) return;
        const stream_id: spore_stream.StreamId = switch (output) {
            .stdout => .stdout,
            .stderr => .stderr,
            .terminal => .terminal,
        };
        const offset = switch (output) {
            .stdout => self.streaming_stdout_offset,
            .stderr => self.streaming_stderr_offset,
            .terminal => self.streaming_terminal_offset,
        };
        if (writeSpioDataFd(fd, stream_id, offset, bytes) != 0) {
            self.streaming_write_failed = true;
            if (self.wake) |wake| wake.wake();
            return;
        }
        const len: u64 = @intCast(bytes.len);
        switch (output) {
            .stdout => self.streaming_stdout_offset += len,
            .stderr => self.streaming_stderr_offset += len,
            .terminal => self.streaming_terminal_offset += len,
        }
    }

    fn sendStreamingExitLocked(self: *ExecServer, exit_code: i32) void {
        if (self.streaming_client_fd < 0 or self.streaming_write_failed) return;
        const code: u32 = if (exit_code < 0) 1 else @intCast(@min(exit_code, 255));
        var payload: [4]u8 = undefined;
        spore_stream.writeExitPayload(&payload, code);
        if (writeSpioFrameFd(self.streaming_client_fd, .exit, .control, 0, &payload) != 0) {
            self.streaming_write_failed = true;
        }
    }

    fn sendStreamingErrorLocked(self: *ExecServer, message: []const u8) void {
        if (self.streaming_client_fd < 0 or self.streaming_write_failed) return;
        const payload = if (message.len > spore_stream.max_payload_len) message[0..spore_stream.max_payload_len] else message;
        if (writeSpioFrameFd(self.streaming_client_fd, .err, .control, 0, payload) != 0) {
            self.streaming_write_failed = true;
        }
    }

    fn enqueueStreamingInput(self: *ExecServer, stream_id: spore_stream.StreamId, bytes: []const u8) !void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.state != .active_exec or !self.active_streaming_exec or !self.active_stream_valid) return error.ControlStreamClosed;
        }
        var stop = std.atomic.Value(bool).init(false);
        const queued = switch (stream_id) {
            .stdin => try self.active_stream.enqueueStdinDataBlocking(bytes, &stop),
            .terminal => try self.active_stream.enqueueTerminalDataBlocking(bytes, &stop),
            else => return error.InvalidControlStream,
        };
        if (!queued) return error.ControlStreamClosed;
        if (self.wake) |wake| wake.wake();
    }

    fn enqueueStreamingClose(self: *ExecServer, stream_id: spore_stream.StreamId) !void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.state != .active_exec or !self.active_streaming_exec or !self.active_stream_valid) return error.ControlStreamClosed;
        }
        var stop = std.atomic.Value(bool).init(false);
        const queued = switch (stream_id) {
            .stdin => try self.active_stream.enqueueStdinCloseBlocking(&stop),
            .terminal => try self.active_stream.enqueueTerminalCloseBlocking(&stop),
            else => return error.InvalidControlStream,
        };
        if (!queued) return error.ControlStreamClosed;
        if (self.wake) |wake| wake.wake();
    }

    fn enqueueStreamingResize(self: *ExecServer, resize: spore_stream.Resize) !void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.state != .active_exec or !self.active_streaming_exec or !self.active_stream_valid) return error.ControlStreamClosed;
        }
        var stop = std.atomic.Value(bool).init(false);
        if (!try self.active_stream.enqueueResizeBlocking(resize, &stop)) return error.ControlStreamClosed;
        if (self.wake) |wake| wake.wake();
    }

    fn submitSuspend(self: *ExecServer, out_dir: []const u8) ![]const u8 {
        if (out_dir.len == 0 or out_dir.len > self.suspend_dir.len) return error.InvalidSuspendDir;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.state == .done) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
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
        while (self.state == .done) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
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

    fn reportStats(self: *ExecServer, stats: vsock.ControlStats) void {
        if (self.stats_written and std.meta.eql(stats, self.stats_written_value)) return;
        const now = lifecycle.monotonicMs();
        const first_write = self.stats_write_ms == 0;
        const clean_tail = (stats.dirty_chunks_pending orelse 0) == 0;
        if (!first_write and !clean_tail and now -| self.stats_write_ms < stats_write_interval_ms) return;
        lifecycle.writeMonitorStatsPath(self.allocator, self.io, self.stats_path, .{
            .chunks_nonzero = stats.chunks_nonzero,
            .dirty_chunks_pending = stats.dirty_chunks_pending,
        }) catch return;
        self.stats_written = true;
        self.stats_written_value = stats;
        self.stats_write_ms = now;
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
        const network_events_jsonl = if (self.network_events) |events|
            try events.drainEventJsonl(self.allocator)
        else
            try self.allocator.dupe(u8, "");
        defer self.allocator.free(network_events_jsonl);
        const network_events_jsonl_b64 = try base64Alloc(self.allocator, network_events_jsonl);
        defer self.allocator.free(network_events_jsonl_b64);
        const payload = struct {
            type: []const u8 = "exec_result",
            exit_code: i32,
            stdout_b64: []const u8,
            stderr_b64: []const u8,
            network_events_jsonl_b64: []const u8,
            stdout_truncated: bool,
            stderr_truncated: bool,
        }{
            .exit_code = exit_code,
            .stdout_b64 = stdout_b64,
            .stderr_b64 = stderr_b64,
            .network_events_jsonl_b64 = network_events_jsonl_b64,
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

    fn reportStatsThunk(context: *anyopaque, stats: vsock.ControlStats) void {
        const self: *ExecServer = @ptrCast(@alignCast(context));
        self.reportStats(stats);
    }

    fn captureOutputThunk(context: ?*anyopaque, output: vsock.HostStreamOutput, bytes: []const u8) void {
        const self: *ExecServer = @ptrCast(@alignCast(context.?));
        self.captureOutput(output, bytes);
    }

    fn streamOutputThunk(context: ?*anyopaque, output: vsock.HostStreamOutput, bytes: []const u8) void {
        const self: *ExecServer = @ptrCast(@alignCast(context.?));
        self.streamOutput(output, bytes);
    }
};

fn base64Alloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(out, bytes);
    return out;
}

fn writeSpioDataFd(fd: std.c.fd_t, stream_id: spore_stream.StreamId, offset: u64, bytes: []const u8) c_int {
    var remaining = bytes;
    var frame_offset = offset;
    while (remaining.len > 0) {
        const take = @min(remaining.len, spore_stream.max_payload_len);
        if (writeSpioFrameFd(fd, .data, stream_id, frame_offset, remaining[0..take]) != 0) return -1;
        frame_offset += @intCast(take);
        remaining = remaining[take..];
    }
    return 0;
}

fn writeSpioFrameFd(fd: std.c.fd_t, frame_type: spore_stream.FrameType, stream_id: spore_stream.StreamId, offset: u64, payload: []const u8) c_int {
    var frame_buf: [spore_stream.max_frame_len]u8 = undefined;
    const frame = spore_stream.writeFrame(&frame_buf, .{
        .frame_type = frame_type,
        .stream_id = stream_id,
        .offset = offset,
    }, payload) catch return -1;
    return writeFdAll(fd, frame);
}

fn writeFdAll(fd: std.c.fd_t, bytes: []const u8) c_int {
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.write(fd, rest.ptr, rest.len);
        if (n < 0) {
            switch (std.c.errno(n)) {
                .INTR => continue,
                else => return -1,
            }
        }
        if (n == 0) return -1;
        rest = rest[@intCast(n)..];
    }
    return 0;
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
    const line = readControlLineFd(stream.socket.handle, &read_buffer) catch {
        try writeControlError(server.io, stream, "bad control request");
        return false;
    };
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
    if (std.mem.eql(u8, parsed.value.type, "hello")) {
        const payload = struct {
            type: []const u8 = "hello",
            version: []const u8 = version.string,
        }{};
        try writeControlJson(server.allocator, server.io, stream, payload);
        return false;
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
    if (std.mem.eql(u8, parsed.value.type, "exec-stream-v1")) {
        const argv = parsed.value.argv orelse {
            try writeStreamingControlError(stream.socket.handle, "command request missing argv");
            return false;
        };
        const stdio = parsed.value.stdio orelse {
            try writeStreamingControlError(stream.socket.handle, "stream request missing stdio");
            return false;
        };
        const tty = std.mem.eql(u8, stdio, "tty");
        if (!tty and !std.mem.eql(u8, stdio, "pipe")) {
            try writeStreamingControlError(stream.socket.handle, "unsupported stream stdio");
            return false;
        }
        const interactive = parsed.value.interactive orelse false;
        if (!interactive and !tty) {
            try writeStreamingControlError(stream.socket.handle, "stream request is not interactive");
            return false;
        }
        const terminal_size = spore_stream.Resize{
            .rows = parsed.value.terminal_rows orelse 24,
            .cols = parsed.value.terminal_cols orelse 80,
        };
        const terminal_name = parsed.value.term orelse "xterm";
        const request = server.interactiveExecRequest(argv, interactive, tty, terminal_name, terminal_size) catch {
            try writeStreamingControlError(stream.socket.handle, "invalid argv");
            return false;
        };
        defer server.allocator.free(request);
        server.submitStreamingExec(request, stream.socket.handle) catch {
            try writeStreamingControlError(stream.socket.handle, "monitor busy");
            return false;
        };
        defer server.finishStreamingExec();
        proxyStreamingInput(server, stream.socket.handle, if (tty) .terminal else .stdin) catch {};
        return false;
    }
    if (std.mem.eql(u8, parsed.value.type, "copy-in-v1") or std.mem.eql(u8, parsed.value.type, "copy-out-v1")) {
        const path = parsed.value.path orelse {
            try writeStreamingControlError(stream.socket.handle, "copy request missing path");
            return false;
        };
        const request = server.copyRequest(parsed.value.type, path) catch {
            try writeStreamingControlError(stream.socket.handle, "invalid copy request");
            return false;
        };
        defer server.allocator.free(request);
        server.submitStreamingExec(request, stream.socket.handle) catch {
            try writeStreamingControlError(stream.socket.handle, "monitor busy");
            return false;
        };
        defer server.finishStreamingExec();
        if (std.mem.eql(u8, parsed.value.type, "copy-in-v1")) {
            proxyStreamingInput(server, stream.socket.handle, .stdin) catch {};
        }
        return false;
    }
    const detached = std.mem.eql(u8, parsed.value.type, "start");
    if (!detached and !std.mem.eql(u8, parsed.value.type, "exec")) {
        try writeControlError(server.io, stream, "unknown control request");
        return false;
    }
    const argv = parsed.value.argv orelse {
        try writeControlError(server.io, stream, "command request missing argv");
        return false;
    };
    const request = if (detached)
        server.detachedExecRequest(argv) catch {
            try writeControlError(server.io, stream, "invalid argv");
            return false;
        }
    else
        server.execRequest(argv) catch {
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

fn readControlLineFd(fd: std.c.fd_t, buffer: []u8) ![]const u8 {
    var len: usize = 0;
    while (len < buffer.len) {
        var byte: [1]u8 = undefined;
        const n = std.c.read(fd, &byte, 1);
        if (n < 0) {
            switch (std.c.errno(n)) {
                .INTR => continue,
                else => return error.ControlStreamClosed,
            }
        }
        if (n == 0) return error.ControlStreamClosed;
        if (byte[0] == '\n') return buffer[0..len];
        buffer[len] = byte[0];
        len += 1;
    }
    return error.ControlRequestTooLarge;
}

const ControlRequest = struct {
    type: []const u8,
    argv: ?[]const []const u8 = null,
    out_dir: ?[]const u8 = null,
    path: ?[]const u8 = null,
    @"continue": ?bool = null,
    stdio: ?[]const u8 = null,
    interactive: ?bool = null,
    term: ?[]const u8 = null,
    terminal_rows: ?u16 = null,
    terminal_cols: ?u16 = null,
};

fn writeStreamingControlError(fd: std.c.fd_t, message: []const u8) !void {
    const payload = if (message.len > spore_stream.max_payload_len) message[0..spore_stream.max_payload_len] else message;
    if (writeSpioFrameFd(fd, .err, .control, 0, payload) != 0) return error.MonitorUnavailable;
}

fn proxyStreamingInput(server: *ExecServer, fd: std.c.fd_t, input_stream: spore_stream.StreamId) !void {
    var parser = LocalSpioInputParser{};
    var input_closed = false;
    while (true) {
        if (server.streamingDone()) return;
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.c.POLL.IN | std.c.POLL.HUP | std.c.POLL.ERR, .revents = 0 }};
        const ready = std.posix.poll(&fds, 50) catch return;
        if (ready == 0) continue;
        if ((fds[0].revents & std.c.POLL.IN) != 0) {
            const action = parser.read(fd) catch {
                if (!input_closed) {
                    _ = server.enqueueStreamingClose(input_stream) catch {};
                    input_closed = true;
                }
                return;
            };
            switch (action) {
                .none => {},
                .data => |data| {
                    if (data.stream_id != input_stream) {
                        _ = server.enqueueStreamingClose(input_stream) catch {};
                        return error.BadControlStreamFrame;
                    }
                    try server.enqueueStreamingInput(data.stream_id, data.bytes);
                },
                .close => |stream_id| {
                    if (stream_id != input_stream) {
                        _ = server.enqueueStreamingClose(input_stream) catch {};
                        return error.BadControlStreamFrame;
                    }
                    try server.enqueueStreamingClose(stream_id);
                    input_closed = true;
                },
                .resize => |resize| {
                    if (input_stream != .terminal) {
                        _ = server.enqueueStreamingClose(input_stream) catch {};
                        return error.BadControlStreamFrame;
                    }
                    try server.enqueueStreamingResize(resize);
                },
            }
        }
        if ((fds[0].revents & (std.c.POLL.HUP | std.c.POLL.ERR | std.c.POLL.NVAL)) != 0) {
            if (!input_closed) {
                _ = server.enqueueStreamingClose(input_stream) catch {};
                input_closed = true;
            }
        }
    }
}

const LocalSpioInputAction = union(enum) {
    none,
    data: struct {
        stream_id: spore_stream.StreamId,
        bytes: []const u8,
    },
    close: spore_stream.StreamId,
    resize: spore_stream.Resize,
};

const LocalSpioInputParser = struct {
    stdin_offset: u64 = 0,
    terminal_offset: u64 = 0,
    payload: [spore_stream.max_payload_len]u8 = undefined,

    fn read(self: *LocalSpioInputParser, fd: std.c.fd_t) !LocalSpioInputAction {
        var header_buf: [spore_stream.header_len]u8 = undefined;
        try readFdExact(fd, &header_buf);
        const header = try spore_stream.readHeader(&header_buf);
        if (header.flags != 0) return error.BadControlStreamFrame;
        if (header.payload_len > self.payload.len) return error.BadControlStreamFrame;
        const payload = self.payload[0..header.payload_len];
        if (payload.len > 0) try readFdExact(fd, payload);
        switch (header.frame_type) {
            .data => {
                if (header.stream_id != .stdin and header.stream_id != .terminal) return error.BadControlStreamFrame;
                const expected = switch (header.stream_id) {
                    .stdin => self.stdin_offset,
                    .terminal => self.terminal_offset,
                    else => unreachable,
                };
                if (header.offset != expected) return error.BadControlStreamFrame;
                const len: u64 = @intCast(payload.len);
                switch (header.stream_id) {
                    .stdin => self.stdin_offset += len,
                    .terminal => self.terminal_offset += len,
                    else => unreachable,
                }
                return .{ .data = .{ .stream_id = header.stream_id, .bytes = payload } };
            },
            .close => {
                if ((header.stream_id != .stdin and header.stream_id != .terminal) or payload.len != 0) return error.BadControlStreamFrame;
                const expected = switch (header.stream_id) {
                    .stdin => self.stdin_offset,
                    .terminal => self.terminal_offset,
                    else => unreachable,
                };
                if (header.offset != expected) return error.BadControlStreamFrame;
                return .{ .close = header.stream_id };
            },
            .resize => {
                if (header.stream_id != .terminal or header.offset != 0) return error.BadControlStreamFrame;
                const resize = try spore_stream.readResizePayload(payload);
                if (resize.rows == 0 or resize.cols == 0) return error.BadControlStreamFrame;
                return .{ .resize = resize };
            },
            else => return error.BadControlStreamFrame,
        }
    }
};

fn readFdExact(fd: std.c.fd_t, buf: []u8) !void {
    var rest = buf;
    while (rest.len > 0) {
        const n = std.c.read(fd, rest.ptr, rest.len);
        if (n < 0) {
            switch (std.c.errno(n)) {
                .INTR => continue,
                else => return error.ControlStreamClosed,
            }
        }
        if (n == 0) return error.ControlStreamClosed;
        rest = rest[@intCast(n)..];
    }
}

fn writeControlOk(io: Io, stream: net.Stream) !void {
    try writeAll(io, stream, "{\"type\":\"ok\"}\n");
}

fn writeControlJson(allocator: std.mem.Allocator, io: Io, stream: net.Stream, payload: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    try writeAll(io, stream, json);
    try writeAll(io, stream, "\n");
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

fn sessionHandlesForResume(allocator: std.mem.Allocator, maybe_resume_dir: ?[]const u8) []const spore.Session {
    const resume_dir = maybe_resume_dir orelse return &.{};
    if (spore.loadManifest(allocator, resume_dir)) |manifest| {
        return manifest.value.sessions;
    } else |err| switch (err) {
        error.BadManifest => {},
        else => return &.{},
    }
    if (spore.loadManifestV1(allocator, resume_dir)) |manifest| {
        return manifest.value.sessions;
    } else |_| {
        return &.{};
    }
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
        } else if (std.mem.eql(u8, args[i], "--allow-host-port")) {
            const raw = takeValue(args, &i, args[i]);
            const parsed = spore_net_policy.parseHostPort(raw) catch |err| {
                std.debug.print("spore monitor: invalid --allow-host-port {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            };
            opts.network_policy.addExactHostPorts(parsed.host, &.{parsed.port}) catch |err| {
                std.debug.print("spore monitor: invalid --allow-host-port {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--bound-unix-service")) {
            const flag = args[i];
            const name = takeValue(args, &i, flag);
            const guest_host = takeValue(args, &i, flag);
            const guest_port_raw = takeValue(args, &i, flag);
            const unix_path = takeValue(args, &i, flag);
            const guest_port = std.fmt.parseUnsigned(u16, guest_port_raw, 10) catch {
                std.debug.print("spore monitor: invalid --bound-unix-service port {s}\n", .{guest_port_raw});
                std.process.exit(2);
            };
            opts.network_policy.addBoundUnixService(name, guest_host, guest_port, unix_path) catch |err| {
                std.debug.print("spore monitor: invalid --bound-unix-service {s}: {s}\n", .{ name, @errorName(err) });
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--forward")) {
            const raw = takeValue(args, &i, args[i]);
            opts.network_policy.addPortForward(raw) catch |err| {
                std.debug.print("spore monitor: invalid --forward {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--memory")) {
            opts.memory = memory_config.parseCliOrExit("spore monitor", takeValue(args, &i, args[i]));
        } else if (std.mem.eql(u8, args[i], "--memory-mib")) {
            memory_config.rejectMemoryMiBFlag("spore monitor");
        } else if (std.mem.eql(u8, args[i], "--vcpus")) {
            opts.vcpus = run.parseVcpuCountOrExit(args[i], takeValue(args, &i, args[i]));
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
        std.debug.print("spore monitor: network flags require --net\n", .{});
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
        "--forward",
        "127.0.0.1:8080:80",
    });

    try std.testing.expectEqual(run.NetworkMode.spore, opts.network);
    try std.testing.expectEqual(@as(usize, 1), opts.network_policy.allow_cidr_count);
    try std.testing.expectEqualStrings("93.184.216.34/32", opts.network_policy.allow_cidrs[0]);
    try std.testing.expectEqual(@as(usize, 1), opts.network_policy.allow_host_count);
    try std.testing.expectEqualStrings("example.com", opts.network_policy.allow_hosts[0]);
    try std.testing.expectEqual(@as(usize, 1), opts.network_policy.port_forward_count);
    try std.testing.expectEqual(@as(u16, 8080), opts.network_policy.port_forwards[0].host_port);
    try std.testing.expectEqual(@as(u16, 80), opts.network_policy.port_forwards[0].guest_port);
}

test "monitor parser accepts bounded vcpu count" {
    const opts = try parseMonitorArgs(&.{ "bench-1", "--vcpus", "2" });
    try std.testing.expectEqual(@as(topology.VcpuCount, 2), opts.vcpus);
}
