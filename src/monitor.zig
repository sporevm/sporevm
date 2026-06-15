//! Per-VM monitor process and local control protocol.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

const lifecycle = @import("lifecycle.zig");
const run = @import("run.zig");
const vsock = @import("virtio/vsock.zig");

const max_control_request = 4096;
const max_control_response = 128 * 1024;
const default_backend = "auto";

const monitor_usage =
    \\Usage:
    \\  spore monitor NAME [options]
    \\
    \\Options:
    \\  --backend auto|hvf|kvm  Backend to run (default: auto)
    \\  --kernel Image          Kernel Image path
    \\  --initrd root.cpio      Initrd path
    \\  --rootfs rootfs.ext4    Resolved rootfs image path
    \\  --image REF             Original OCI image ref for metadata
    \\  --memory-mib N          Guest memory in MiB (default: 1024)
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
    memory_mib: u64 = 1024,
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    console_log_path: ?[]const u8 = null,
};

const RequestState = enum {
    idle,
    pending_exec,
    active_exec,
    done,
    stop_requested,
};

pub fn cli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    _ = stdout;
    if (args.len == 1 and (std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "help"))) {
        var out_buffer: [1024]u8 = undefined;
        var out_writer: Io.File.Writer = .init(.stdout(), init.io, &out_buffer);
        try out_writer.interface.writeAll(monitor_usage);
        try out_writer.interface.flush();
        return;
    }

    const allocator = init.arena.allocator();
    const opts = try parseMonitorArgs(args);
    if (!lifecycle.monitorBackendSupported(opts.backend.name())) {
        std.debug.print("spore monitor: monitor mode currently supports only HVF on Apple Silicon\n", .{});
        std.process.exit(2);
    }
    if (opts.image_ref != null and opts.rootfs_path == null) {
        std.debug.print("spore monitor: --image is metadata only; pass a resolved --rootfs path\n", .{});
        std.process.exit(2);
    }
    const paths = try lifecycle.pathsFor(allocator, init.environ_map, opts.name);
    const kernel_path = opts.kernel_path orelse try run.resolveDefaultKernelPath(init, allocator);
    const initrd_path = opts.initrd_path orelse try run.resolveDefaultInitrdPath(init, allocator);

    try lifecycle.writeSpec(allocator, init.io, paths, .{
        .name = opts.name,
        .backend = opts.backend.name(),
        .kernel_path = kernel_path,
        .initrd_path = initrd_path,
        .rootfs_path = opts.rootfs_path,
        .image_ref = opts.image_ref,
        .memory_mib = opts.memory_mib,
        .vcpus = opts.vcpus,
        .guest_port = opts.guest_port,
        .timeout_ms = opts.timeout_ms,
        .console_log_path = opts.console_log_path,
    });
    try lifecycle.writePid(allocator, init.io, paths, currentPid());

    var server = try ExecServer.init(allocator, init.io, paths.control_socket_path, opts.guest_port, opts.timeout_ms);
    const thread = try std.Thread.spawn(.{}, controlThreadMain, .{&server});

    try lifecycle.writeReady(allocator, init.io, paths, .{
        .pid = currentPid(),
        .control_socket_path = paths.control_socket_path,
        .console_log_path = paths.console_log_path,
    });

    try run.openConsoleLog(opts.console_log_path);
    defer run.closeConsoleLog();

    const result = run.executeMonitor(init, allocator, .{
        .backend = opts.backend,
        .kernel_path = kernel_path,
        .initrd_path = initrd_path,
        .rootfs_path = opts.rootfs_path,
        .command = &.{"/bin/true"},
        .memory_mib = opts.memory_mib,
        .vcpus = opts.vcpus,
        .guest_port = opts.guest_port,
        .timeout_ms = opts.timeout_ms,
        .console_log_path = opts.console_log_path,
    }, server.control());
    if (result) |_| {
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
    active_stream: vsock.HostStream = undefined,
    active_stream_valid: bool = false,
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
            .pending_exec => {
                self.active_stream = try vsock.HostStream.init(self.guest_port, self.request[0..self.request_len]);
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
                    try self.storeExecResultLocked(self.active_stream.outputSlice());
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
            .pending_exec, .active_exec => {
                self.storeErrorLocked(message) catch {
                    self.response_len = 0;
                };
                self.state = .done;
                self.cond.broadcast(self.io);
            },
            else => {},
        }
    }

    fn storeExecResultLocked(self: *ExecServer, exit_frame: []const u8) !void {
        const payload = struct {
            type: []const u8 = "exec_result",
            exit_frame: []const u8,
        }{ .exit_frame = exit_frame };
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
};

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
    if (!std.mem.eql(u8, parsed.value.type, "exec")) {
        try writeControlError(server.io, stream, "unknown control request");
        return false;
    }
    const argv = parsed.value.argv orelse {
        try writeControlError(server.io, stream, "exec request missing argv");
        return false;
    };
    const request = run.execRequest(server.allocator, argv) catch {
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
        } else if (std.mem.eql(u8, args[i], "--memory-mib")) {
            opts.memory_mib = try parsePositive(u64, args[i], takeValue(args, &i, args[i]));
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
