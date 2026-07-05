//! Shared host-side stream helpers for `spore run --from` and `spore attach`.

const std = @import("std");

const spore = @import("spore.zig");
const spore_stream = @import("spore_stream.zig");
const vsock = @import("virtio/vsock.zig");

const max_guest_request_len = 8191;

pub const RunStdinControl = struct {
    stream: *vsock.HostStream,
    terminal: bool,
    forward_input: bool,
    resize_fd: std.c.fd_t,
    thread: ?std.Thread = null,
    stop_pipe: [2]std.c.fd_t = .{ -1, -1 },
    stop: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    resize_count: std.atomic.Value(u32) = .init(0),
    resize_seen: u32 = 0,
    wake_context_addr: std.atomic.Value(usize) = .init(0),
    wake_fn_addr: std.atomic.Value(usize) = .init(0),
    resize_registration: ?TerminalResizeRegistration = null,
    raw_terminal: ?RawTerminal = null,

    pub fn init(stream: *vsock.HostStream, terminal: bool, forward_input: bool, resize_fd: std.c.fd_t) RunStdinControl {
        return .{
            .stream = stream,
            .terminal = terminal,
            .forward_input = forward_input,
            .resize_fd = resize_fd,
        };
    }

    pub fn start(self: *RunStdinControl, raw_terminal: bool) !void {
        errdefer self.deinit();
        if (raw_terminal) self.raw_terminal = try RawTerminal.enable();
        if (self.terminal) {
            self.resize_registration = TerminalResizeRegistration.install(self);
            self.notifyResize();
        }
        if (self.forward_input) {
            if (std.c.pipe(&self.stop_pipe) != 0) return error.StdinPumpStartFailed;
            self.thread = try std.Thread.spawn(.{}, stdinThreadMain, .{self});
        }
    }

    pub fn deinit(self: *RunStdinControl) void {
        self.stop.store(true, .release);
        if (self.stop_pipe[1] >= 0) {
            const byte = [_]u8{1};
            _ = std.c.write(self.stop_pipe[1], &byte, byte.len);
        }
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.resize_registration) |*registration| {
            registration.deinit();
            self.resize_registration = null;
        }
        if (self.raw_terminal) |*raw| {
            raw.deinit();
            self.raw_terminal = null;
        }
        self.closeStopPipe();
    }

    pub fn control(self: *RunStdinControl) vsock.Control {
        return .{
            .context = self,
            .pollFn = pollThunk,
            .setWakeFn = setWakeThunk,
            .completeSnapshotFn = completeSnapshotThunk,
            .reportStatsFn = reportStatsThunk,
        };
    }

    fn closeStopPipe(self: *RunStdinControl) void {
        if (self.stop_pipe[0] >= 0) {
            _ = std.c.close(self.stop_pipe[0]);
            self.stop_pipe[0] = -1;
        }
        if (self.stop_pipe[1] >= 0) {
            _ = std.c.close(self.stop_pipe[1]);
            self.stop_pipe[1] = -1;
        }
    }

    fn stdinThreadMain(self: *RunStdinControl) void {
        var buf: [4096]u8 = undefined;
        while (!self.stop.load(.acquire)) {
            var fds = [_]std.posix.pollfd{
                .{ .fd = 0, .events = std.c.POLL.IN | std.c.POLL.HUP | std.c.POLL.ERR, .revents = 0 },
                .{ .fd = self.stop_pipe[0], .events = std.c.POLL.IN, .revents = 0 },
            };
            const ready = std.posix.poll(&fds, -1) catch {
                self.markFailed();
                return;
            };
            if (ready == 0) continue;
            if ((fds[1].revents & std.c.POLL.IN) != 0 or self.stop.load(.acquire)) return;
            if ((fds[0].revents & (std.c.POLL.ERR | std.c.POLL.NVAL)) != 0) {
                self.markFailed();
                return;
            }
            if ((fds[0].revents & (std.c.POLL.IN | std.c.POLL.HUP)) == 0) continue;
            const n = std.c.read(0, &buf, buf.len);
            if (n < 0) {
                switch (std.c.errno(n)) {
                    .INTR => continue,
                    else => {
                        self.markFailed();
                        return;
                    },
                }
            }
            if (n == 0) {
                const queued = if (self.terminal)
                    self.stream.enqueueTerminalCloseBlocking(&self.stop)
                else
                    self.stream.enqueueStdinCloseBlocking(&self.stop);
                _ = queued catch {
                    self.markFailed();
                    return;
                };
                self.wakeBackend();
                return;
            }
            const bytes = buf[0..@intCast(n)];
            const queued = (if (self.terminal)
                self.stream.enqueueTerminalDataBlocking(bytes, &self.stop)
            else
                self.stream.enqueueStdinDataBlocking(bytes, &self.stop)) catch {
                self.markFailed();
                return;
            };
            if (!queued) return;
            self.wakeBackend();
        }
    }

    fn markFailed(self: *RunStdinControl) void {
        self.failed.store(true, .release);
        self.wakeBackend();
    }

    fn notifyResize(self: *RunStdinControl) void {
        _ = self.resize_count.fetchAdd(1, .acq_rel);
        self.wakeBackend();
    }

    fn wakeBackend(self: *RunStdinControl) void {
        const wake_fn_addr = self.wake_fn_addr.load(.acquire);
        if (wake_fn_addr == 0) return;
        const wake_context_addr = self.wake_context_addr.load(.acquire);
        const wake = vsock.Wake{
            .context = @ptrFromInt(wake_context_addr),
            .wakeFn = @ptrFromInt(wake_fn_addr),
        };
        wake.wake();
    }

    fn poll(self: *RunStdinControl, dev: *vsock.Vsock) !vsock.ControlAction {
        if (self.failed.load(.acquire)) self.stream.fail();
        if (self.terminal) {
            const count = self.resize_count.load(.acquire);
            if (count != self.resize_seen) {
                self.resize_seen = count;
                const resize = terminalSizeOrDefault(self.resize_fd);
                _ = try self.stream.enqueueResizeBlocking(resize, &self.stop);
            }
        }
        _ = try dev.flushHostStreamOutbound();
        return .keep_running;
    }

    fn setWake(self: *RunStdinControl, wake: vsock.Wake) void {
        self.wake_context_addr.store(@intFromPtr(wake.context), .release);
        self.wake_fn_addr.store(@intFromPtr(wake.wakeFn), .release);
    }

    fn completeSnapshot(_: *RunStdinControl, _: []const u8) !void {}

    fn reportStats(_: *RunStdinControl, _: vsock.ControlStats) void {}

    fn pollThunk(context: *anyopaque, dev: *vsock.Vsock) !vsock.ControlAction {
        const self: *RunStdinControl = @ptrCast(@alignCast(context));
        return self.poll(dev);
    }

    fn setWakeThunk(context: *anyopaque, wake: vsock.Wake) void {
        const self: *RunStdinControl = @ptrCast(@alignCast(context));
        self.setWake(wake);
    }

    fn completeSnapshotThunk(context: *anyopaque, dir: []const u8) !void {
        const self: *RunStdinControl = @ptrCast(@alignCast(context));
        try self.completeSnapshot(dir);
    }

    fn reportStatsThunk(context: *anyopaque, stats: vsock.ControlStats) void {
        const self: *RunStdinControl = @ptrCast(@alignCast(context));
        self.reportStats(stats);
    }
};

const RawTerminal = struct {
    saved: std.c.termios,
    active: bool = true,

    fn enable() !RawTerminal {
        var current: std.c.termios = undefined;
        if (std.c.tcgetattr(0, &current) != 0) return error.TerminalRawModeFailed;
        var raw = current;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.oflag.OPOST = false;
        if (std.c.tcsetattr(0, .NOW, &raw) != 0) return error.TerminalRawModeFailed;
        return .{ .saved = current };
    }

    fn deinit(self: *RawTerminal) void {
        if (!self.active) return;
        var saved = self.saved;
        _ = std.c.tcsetattr(0, .NOW, &saved);
        self.active = false;
    }
};

var active_terminal_resize: ?*RunStdinControl = null;

const TerminalResizeRegistration = struct {
    old_action: std.posix.Sigaction,
    active: bool = true,

    fn install(control: *RunStdinControl) TerminalResizeRegistration {
        active_terminal_resize = control;
        var old_action: std.posix.Sigaction = undefined;
        const action = std.posix.Sigaction{
            .handler = .{ .sigaction = handleTerminalResize },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.SIGINFO,
        };
        std.posix.sigaction(.WINCH, &action, &old_action);
        return .{ .old_action = old_action };
    }

    fn deinit(self: *TerminalResizeRegistration) void {
        if (!self.active) return;
        std.posix.sigaction(.WINCH, &self.old_action, null);
        if (active_terminal_resize != null) active_terminal_resize = null;
        self.active = false;
    }
};

fn handleTerminalResize(_: std.posix.SIG, _: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    if (active_terminal_resize) |control| control.notifyResize();
}

pub fn terminalName(environ: *const std.process.Environ.Map) []const u8 {
    return environ.get("TERM") orelse "xterm";
}

fn ioctlRequest(comptime request: anytype) c_int {
    const raw: u32 = @truncate(@as(usize, request));
    return @bitCast(raw);
}

pub fn terminalSizeOrDefault(fd: std.c.fd_t) spore_stream.Resize {
    var size: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    if (std.c.ioctl(fd, ioctlRequest(std.posix.T.IOCGWINSZ), &size) == 0 and size.row > 0 and size.col > 0) {
        return .{ .rows = size.row, .cols = size.col };
    }
    return .{ .rows = 24, .cols = 80 };
}

pub fn terminalSizeFd() std.c.fd_t {
    return if (std.c.isatty(1) != 0) 1 else if (std.c.isatty(0) != 0) 0 else 1;
}

pub fn attachRequest(allocator: std.mem.Allocator, session_id: []const u8) ![]const u8 {
    return attachRequestWithGeneration(allocator, session_id, null);
}

pub fn attachRequestWithGeneration(allocator: std.mem.Allocator, session_id: []const u8, generation_params: ?[]const u8) ![]const u8 {
    if (generation_params) |params| {
        const payload = struct {
            type: []const u8 = "attach",
            session_id: []const u8,
            stdout_offset: u64 = 0,
            stderr_offset: u64 = 0,
            params_json: []const u8,
        }{ .session_id = session_id, .params_json = params };
        const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
        defer allocator.free(json);
        if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
        return std.fmt.allocPrint(allocator, "{s}\n", .{json});
    }
    const payload = struct {
        type: []const u8 = "attach",
        session_id: []const u8,
        stdout_offset: u64 = 0,
        stderr_offset: u64 = 0,
    }{ .session_id = session_id };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

pub const AttachV1Options = struct {
    session_id: []const u8 = spore.default_session_id,
    interactive: bool = false,
    tty: bool = false,
    terminal_name: []const u8 = "xterm",
    terminal_size: spore_stream.Resize = .{ .rows = 24, .cols = 80 },
    generation_params: ?[]const u8 = null,
};

pub fn attachV1Request(allocator: std.mem.Allocator, options: AttachV1Options) ![]const u8 {
    const payload = struct {
        type: []const u8 = "attach-v1",
        session_id: []const u8,
        stdout_offset: u64 = 0,
        stderr_offset: u64 = 0,
        stdio: []const u8,
        interactive: bool,
        term: []const u8,
        terminal_rows: u16,
        terminal_cols: u16,
        params_json: []const u8,
    }{
        .session_id = options.session_id,
        .stdio = if (options.tty) "tty" else "pipe",
        .interactive = options.interactive,
        .term = options.terminal_name,
        .terminal_rows = options.terminal_size.rows,
        .terminal_cols = options.terminal_size.cols,
        .params_json = options.generation_params orelse "",
    };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

test "attach request targets default session" {
    const request = try attachRequest(std.testing.allocator, spore.default_session_id);
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings("{\"type\":\"attach\",\"session_id\":\"default\",\"stdout_offset\":0,\"stderr_offset\":0}\n", request);
}

test "attach request can target recorded session id" {
    const request = try attachRequest(std.testing.allocator, "run-1234");
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings("{\"type\":\"attach\",\"session_id\":\"run-1234\",\"stdout_offset\":0,\"stderr_offset\":0}\n", request);
}

test "interactive attach request uses v1 pipe stdio" {
    const request = try attachV1Request(std.testing.allocator, .{ .interactive = true });
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"type\":\"attach-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"stdio\":\"pipe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"interactive\":true") != null);
}

test "tty attach request uses v1 terminal metadata" {
    const request = try attachV1Request(std.testing.allocator, .{
        .interactive = true,
        .tty = true,
        .terminal_name = "xterm-256color",
        .terminal_size = .{ .rows = 40, .cols = 120 },
    });
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"type\":\"attach-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"stdio\":\"tty\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"term\":\"xterm-256color\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"terminal_rows\":40") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"terminal_cols\":120") != null);
}
