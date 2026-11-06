//! Parent-side `spore-netd` process adapter.
//!
//! The VMM still owns virtio-net queues. This adapter translates the internal
//! Ethernet frame backend into the helper's length-prefixed stdio frame stream.

const std = @import("std");
const TestDir = @import("test_dir.zig").TestDir;
const builtin = @import("builtin");
const Io = std.Io;

const spore_net = @import("spore_net.zig");
const spore_net_policy = @import("spore_net_policy.zig");
const spore_netd = @import("spore_netd.zig");
const spore_netd_tcp = @import("spore_netd_tcp.zig");
const virtio_net = @import("virtio/net.zig");

const ready_timeout_ms = 1_000;
const max_rx_pending = 16;
const max_network_events = 128;
const max_stderr_line_len = 512;

pub const StartError = error{
    NetdSpawnFailed,
    NetdReadyTimedOut,
    NetdReadyFailed,
    NetdThreadFailed,
} || std.mem.Allocator.Error;

pub const NetworkEventKind = enum {
    egress_denied,

    pub fn name(self: NetworkEventKind) []const u8 {
        return switch (self) {
            .egress_denied => "egress_denied",
        };
    }
};

pub const NetworkEvent = struct {
    kind: NetworkEventKind,
    destination_ip: [4]u8,
    destination_port: u16,
    reason: spore_net_policy.Decision,
};

pub const Process = struct {
    child: std.process.Child = undefined,
    to_child_fd: std.c.fd_t = -1,
    from_child_fd: std.c.fd_t = -1,
    stderr_fd: std.c.fd_t = -1,
    stdout_thread: ?std.Thread = null,
    stderr_thread: ?std.Thread = null,
    wait_thread: ?std.Thread = null,
    failed: std.atomic.Value(bool) = .init(false),
    shutdown_requested: std.atomic.Value(bool) = .init(false),
    wake_pending: std.atomic.Value(bool) = .init(false),
    wake_lock: SpinLock = .{},
    wake: virtio_net.Wake = .{},
    rx_lock: SpinLock = .{},
    network_event_lock: SpinLock = .{},
    link_closed: bool = false,
    rx_head: usize = 0,
    rx_count: usize = 0,
    rx_lens: [max_rx_pending]usize = @splat(0),
    rx_bufs: [max_rx_pending][virtio_net.max_frame_len]u8 = undefined,
    network_event_head: usize = 0,
    network_event_count: usize = 0,
    network_events: [max_network_events]NetworkEvent = undefined,

    pub fn start(
        self: *Process,
        io: Io,
        allocator: std.mem.Allocator,
        spore_executable: []const u8,
        debug: bool,
        policy: spore_net_policy.Config,
    ) StartError!void {
        self.* = .{};
        ignoreSigpipe();
        var argv = std.array_list.Managed([]const u8).init(allocator);
        defer argv.deinit();
        argv.append(spore_executable) catch return error.OutOfMemory;
        if (debug) argv.append("--debug") catch return error.OutOfMemory;
        argv.append("netd") catch return error.OutOfMemory;
        argv.append("--stdio") catch return error.OutOfMemory;
        argv.append("--policy") catch return error.OutOfMemory;
        const policy_arg = spore_net_policy.encodeArgAlloc(allocator, &policy) catch return error.OutOfMemory;
        defer allocator.free(policy_arg);
        argv.append(policy_arg) catch return error.OutOfMemory;
        const child = std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch return error.NetdSpawnFailed;

        self.child = child;
        self.to_child_fd = child.stdin.?.handle;
        self.from_child_fd = child.stdout.?.handle;
        self.stderr_fd = child.stderr.?.handle;
        self.child.stdin = null;
        self.child.stdout = null;
        self.child.stderr = null;

        waitReady(self.stderr_fd) catch |err| {
            self.child.kill(io);
            closeIfOpen(&self.to_child_fd);
            closeIfOpen(&self.from_child_fd);
            closeIfOpen(&self.stderr_fd);
            return switch (err) {
                error.NetdReadyTimedOut => error.NetdReadyTimedOut,
                else => error.NetdReadyFailed,
            };
        };

        self.stdout_thread = std.Thread.spawn(.{}, readStdout, .{self}) catch {
            self.child.kill(io);
            closeIfOpen(&self.to_child_fd);
            closeIfOpen(&self.from_child_fd);
            closeIfOpen(&self.stderr_fd);
            return error.NetdThreadFailed;
        };
        self.stderr_thread = std.Thread.spawn(.{}, drainStderr, .{self}) catch {
            self.child.kill(io);
            if (self.stdout_thread) |thread| thread.join();
            closeIfOpen(&self.to_child_fd);
            closeIfOpen(&self.from_child_fd);
            closeIfOpen(&self.stderr_fd);
            return error.NetdThreadFailed;
        };
        self.wait_thread = std.Thread.spawn(.{}, waitChild, .{ self, io }) catch {
            self.child.kill(io);
            if (self.stdout_thread) |thread| thread.join();
            if (self.stderr_thread) |thread| thread.join();
            closeIfOpen(&self.to_child_fd);
            closeIfOpen(&self.from_child_fd);
            return error.NetdThreadFailed;
        };
    }

    pub fn runtime(self: *Process) virtio_net.Runtime {
        return .{
            .backend = self.backend(),
            .context = self,
            .failedFn = failedRuntime,
            .setWakeFn = setWake,
            .clearWakeFn = clearWake,
            .consumeWakeFn = consumeWake,
        };
    }

    pub fn deinit(self: *Process) void {
        self.shutdown();
        if (self.stdout_thread) |thread| {
            thread.join();
            self.stdout_thread = null;
        }
        if (self.stderr_thread) |thread| {
            thread.join();
            self.stderr_thread = null;
        }
        if (self.wait_thread) |thread| {
            thread.join();
            self.wait_thread = null;
        }
    }

    pub fn hasFailed(self: *const Process) bool {
        return self.failed.load(.acquire);
    }

    pub fn popNetworkEvent(self: *Process) ?NetworkEvent {
        self.network_event_lock.lock();
        defer self.network_event_lock.unlock();
        if (self.network_event_count == 0) return null;
        const event = self.network_events[self.network_event_head];
        self.network_event_head = (self.network_event_head + 1) % max_network_events;
        self.network_event_count -= 1;
        return event;
    }

    fn backend(self: *Process) virtio_net.Backend {
        return .{
            .context = self,
            .transmitFn = transmit,
            .peekRxFn = peekRx,
            .consumeRxFn = consumeRx,
            .resetFn = reset,
            .shutdownFn = shutdownBackend,
        };
    }

    fn shutdown(self: *Process) void {
        if (self.link_closed) return;
        self.shutdown_requested.store(true, .release);
        closeIfOpen(&self.to_child_fd);
        self.link_closed = true;
    }

    fn markFailed(self: *Process) void {
        self.failed.store(true, .release);
        self.wakeGuest();
    }

    /// Wakes under `wake_lock`, so once `clearWake` returns no wake into
    /// the finished run is still in flight.
    fn wakeGuest(self: *Process) void {
        self.wake_lock.lock();
        defer self.wake_lock.unlock();
        self.wake.wake();
    }

    fn transmit(ctx: ?*anyopaque, frame: []const u8) void {
        const self: *Process = @ptrCast(@alignCast(ctx.?));
        if (self.hasFailed() or self.link_closed) return;
        logTxFrame(frame);
        spore_netd.writeFrameFd(self.to_child_fd, frame) catch {
            self.markFailed();
            return;
        };
    }

    fn peekRx(ctx: ?*anyopaque) ?[]const u8 {
        const self: *Process = @ptrCast(@alignCast(ctx.?));
        self.rx_lock.lock();
        defer self.rx_lock.unlock();
        if (self.rx_count == 0) return null;
        return self.rx_bufs[self.rx_head][0..self.rx_lens[self.rx_head]];
    }

    fn consumeRx(ctx: ?*anyopaque) void {
        const self: *Process = @ptrCast(@alignCast(ctx.?));
        self.rx_lock.lock();
        defer self.rx_lock.unlock();
        if (self.rx_count == 0) return;
        self.rx_lens[self.rx_head] = 0;
        self.rx_head = (self.rx_head + 1) % max_rx_pending;
        self.rx_count -= 1;
    }

    fn reset(ctx: ?*anyopaque) void {
        const self: *Process = @ptrCast(@alignCast(ctx.?));
        self.rx_lock.lock();
        defer self.rx_lock.unlock();
        self.rx_head = 0;
        self.rx_count = 0;
        @memset(&self.rx_lens, 0);
    }

    fn shutdownBackend(ctx: ?*anyopaque) void {
        const self: *Process = @ptrCast(@alignCast(ctx.?));
        self.shutdown();
    }

    fn failedRuntime(ctx: ?*anyopaque) bool {
        const self: *Process = @ptrCast(@alignCast(ctx.?));
        return self.hasFailed();
    }

    fn consumeWake(ctx: ?*anyopaque) bool {
        const self: *Process = @ptrCast(@alignCast(ctx.?));
        return self.wake_pending.swap(false, .acq_rel);
    }

    fn setWake(ctx: ?*anyopaque, wake: virtio_net.Wake) void {
        const self: *Process = @ptrCast(@alignCast(ctx.?));
        self.wake_lock.lock();
        defer self.wake_lock.unlock();
        self.wake = wake;
    }

    fn clearWake(ctx: ?*anyopaque) void {
        const self: *Process = @ptrCast(@alignCast(ctx.?));
        self.wake_lock.lock();
        defer self.wake_lock.unlock();
        self.wake = .{};
    }

    fn enqueueRxFrame(self: *Process, frame: []const u8) bool {
        self.rx_lock.lock();
        defer self.rx_lock.unlock();
        if (self.rx_count >= max_rx_pending) return false;
        const tail = (self.rx_head + self.rx_count) % max_rx_pending;
        @memcpy(self.rx_bufs[tail][0..frame.len], frame);
        self.rx_lens[tail] = frame.len;
        self.rx_count += 1;
        self.wake_pending.store(true, .release);
        return true;
    }

    fn enqueueNetworkEvent(self: *Process, event: NetworkEvent) bool {
        self.network_event_lock.lock();
        defer self.network_event_lock.unlock();
        if (self.network_event_count >= max_network_events) return false;
        const tail = (self.network_event_head + self.network_event_count) % max_network_events;
        self.network_events[tail] = event;
        self.network_event_count += 1;
        return true;
    }
};

const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

fn waitReady(fd: std.c.fd_t) error{ NetdReadyTimedOut, NetdReadyFailed }!void {
    var line: [64]u8 = undefined;
    var len: usize = 0;
    while (len < line.len) {
        var fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.c.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&fds, ready_timeout_ms) catch return error.NetdReadyFailed;
        if (ready == 0) return error.NetdReadyTimedOut;
        if ((fds[0].revents & (std.c.POLL.ERR | std.c.POLL.NVAL)) != 0) return error.NetdReadyFailed;

        var byte: [1]u8 = undefined;
        const n = std.posix.read(fd, &byte) catch return error.NetdReadyFailed;
        if (n == 0) return error.NetdReadyFailed;
        if (byte[0] == '\n') {
            if (std.mem.eql(u8, line[0..len], "ready")) return;
            len = 0;
            continue;
        }
        line[len] = byte[0];
        len += 1;
    }
    return error.NetdReadyFailed;
}

fn logTxFrame(frame: []const u8) void {
    if (frame.len < 14) {
        std.log.debug("spore-net gateway tx frame len={d}", .{frame.len});
        return;
    }
    const ether_type = std.mem.readInt(u16, frame[12..14], .big);
    if (ether_type != 0x0806 or frame.len < 42) {
        std.log.debug("spore-net gateway tx frame len={d} ether_type=0x{x}", .{ frame.len, ether_type });
        return;
    }
    std.log.debug(
        "spore-net gateway tx arp len={d} op={d} sender={d}.{d}.{d}.{d} target={d}.{d}.{d}.{d}",
        .{
            frame.len,
            std.mem.readInt(u16, frame[20..22], .big),
            frame[28],
            frame[29],
            frame[30],
            frame[31],
            frame[38],
            frame[39],
            frame[40],
            frame[41],
        },
    );
}

fn readStdout(self: *Process) void {
    var buf: [virtio_net.max_frame_len]u8 = undefined;
    while (true) {
        const frame = spore_netd.readFrameFd(self.from_child_fd, &buf) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                self.markFailed();
                break;
            },
        };
        std.log.debug("spore-net gateway rx frame len={d}", .{frame.len});
        if (self.enqueueRxFrame(frame)) {
            self.wakeGuest();
        } else {
            std.log.debug("spore-net gateway dropped rx frame len={d}: rx queue full", .{frame.len});
        }
    }
    if (!self.shutdown_requested.load(.acquire)) self.markFailed();
    closeIfOpen(&self.from_child_fd);
}

fn drainStderr(self: *Process) void {
    var buf: [256]u8 = undefined;
    var line_buf: [max_stderr_line_len]u8 = undefined;
    var line_len: usize = 0;
    while (true) {
        const n = std.posix.read(self.stderr_fd, &buf) catch break;
        if (n == 0) break;
        for (buf[0..n]) |byte| {
            if (byte == '\n') {
                handleStderrLine(self, line_buf[0..line_len]);
                line_len = 0;
            } else if (line_len < line_buf.len) {
                line_buf[line_len] = byte;
                line_len += 1;
            } else {
                line_len = 0;
            }
        }
    }
    if (line_len != 0) handleStderrLine(self, line_buf[0..line_len]);
    closeIfOpen(&self.stderr_fd);
}

fn handleStderrLine(self: *Process, line: []const u8) void {
    if (parseNetworkEventLine(line)) |event| {
        if (!self.enqueueNetworkEvent(event)) {
            std.log.debug("spore-net gateway dropped network event: queue full", .{});
        }
        return;
    }
    if (line.len != 0) std.log.debug("spore-netd stderr: {s}", .{line});
}

fn parseNetworkEventLine(line: []const u8) ?NetworkEvent {
    if (!std.mem.startsWith(u8, line, "{")) return null;
    var buf: [max_stderr_line_len]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const event = std.json.parseFromSliceLeaky(spore_netd_tcp.DeniedEvent, fba.allocator(), line, .{}) catch return null;
    if (!std.mem.eql(u8, event.event, "egress_denied")) return null;
    const destination_ip = spore_net.parseIpv4(event.ip) orelse return null;
    const reason: spore_net_policy.Decision = if (std.mem.eql(u8, event.reason, spore_net_policy.Decision.deny_hard_floor.name()))
        .deny_hard_floor
    else if (std.mem.eql(u8, event.reason, spore_net_policy.Decision.deny_not_allowed.name()))
        .deny_not_allowed
    else
        return null;

    return .{
        .kind = .egress_denied,
        .destination_ip = destination_ip,
        .destination_port = event.port,
        .reason = reason,
    };
}

fn waitChild(self: *Process, io: Io) void {
    const term = self.child.wait(io) catch {
        self.markFailed();
        return;
    };
    if (!self.shutdown_requested.load(.acquire)) {
        std.log.err("spore-netd exited during run: {}", .{term});
        self.markFailed();
    }
}

fn closeIfOpen(fd: *std.c.fd_t) void {
    if (fd.* >= 0) {
        _ = std.c.close(fd.*);
        fd.* = -1;
    }
}

fn ignoreSigpipe() void {
    const action = std.posix.Sigaction{
        .handler = .{ .handler = std.c.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.PIPE, &action, null);
}

test "spore-net gateway spawns netd with policy arguments" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var root_dir = try TestDir.init();
    defer root_dir.deinit();
    const root = root_dir.root;

    const script_path = try std.fs.path.resolve(allocator, &.{ root, "netd-env.sh" });
    defer allocator.free(script_path);
    const out_path = try std.fs.path.resolve(allocator, &.{ root, "env.txt" });
    defer allocator.free(out_path);
    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\nprintf '%s\\n%s\\n%s\\n%s\\n' \"$1\" \"$2\" \"$3\" \"$4\" > {s}\nprintf 'ready\\n' >&2\ncat >/dev/null\n",
        .{out_path},
    );
    defer allocator.free(script);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = script });
    try Io.Dir.cwd().setFilePermissions(io, script_path, @enumFromInt(0o755), .{});

    var process: Process = undefined;
    try process.start(io, allocator, script_path, false, .{ .egress = .deny_all });
    defer process.deinit();

    const observed = try Io.Dir.cwd().readFileAlloc(io, out_path, allocator, .limited(4096));
    defer allocator.free(observed);
    var lines = std.mem.splitScalar(u8, observed, '\n');
    try std.testing.expectEqualStrings("netd", lines.next().?);
    try std.testing.expectEqualStrings("--stdio", lines.next().?);
    try std.testing.expectEqualStrings("--policy", lines.next().?);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const policy = try spore_net_policy.parseArg(arena.allocator(), lines.next().?);
    try std.testing.expect(policy.egress == .allowlist);
    try std.testing.expectEqual(@as(usize, 0), policy.allowCidrSlice().len + policy.allowHostSlice().len + policy.exactRuleSlice().len);
}

test "spore-net gateway buffers multiple rx frames" {
    var process = Process{};
    try std.testing.expect(process.enqueueRxFrame("arp-reply"));
    try std.testing.expect(process.enqueueRxFrame("dns-reply"));
    try std.testing.expect(process.runtime().consumeWake());

    const backend = process.backend();
    try std.testing.expectEqualStrings("arp-reply", backend.peekRx().?);
    backend.consumeRx();
    try std.testing.expectEqualStrings("dns-reply", backend.peekRx().?);
    backend.consumeRx();
    try std.testing.expect(backend.peekRx() == null);
}

test "spore-net gateway wake finishes before clearWake returns" {
    const Run = struct {
        started: std.atomic.Value(bool) = .init(false),
        retired: std.atomic.Value(bool) = .init(false),
        woken_after_retire: std.atomic.Value(bool) = .init(false),

        fn wake(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.started.store(true, .release);
            // Leave the run time to clear the wake while this call is in
            // flight.
            const ts = std.c.timespec{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
            if (self.retired.load(.acquire)) self.woken_after_retire.store(true, .release);
        }
    };

    var process = Process{};
    var target: Run = .{};
    process.runtime().setWake(.{ .context = &target, .wakeFn = Run.wake });
    const thread = try std.Thread.spawn(.{}, Process.wakeGuest, .{&process});
    while (!target.started.load(.acquire)) std.Thread.yield() catch {};
    process.runtime().clearWake();
    target.retired.store(true, .release);
    thread.join();

    try std.testing.expect(!target.woken_after_retire.load(.acquire));
}

test "spore-net gateway drops rx frames only after queue capacity" {
    var process = Process{};
    var i: usize = 0;
    while (i < max_rx_pending) : (i += 1) {
        try std.testing.expect(process.enqueueRxFrame("frame"));
    }
    try std.testing.expect(!process.enqueueRxFrame("overflow"));
}

test "spore-net gateway queues denied egress events from netd stderr" {
    var process = Process{};
    var line: [spore_netd_tcp.max_denied_event_len]u8 = undefined;
    handleStderrLine(&process, spore_netd_tcp.deniedEventLine(&line, .{ 169, 254, 169, 254 }, 80, .deny_hard_floor));
    handleStderrLine(&process, "debug noise");
    handleStderrLine(&process, "{\"event\":\"egress_denied\",\"ip\":\"169.254.169.254\",\"port\":80,\"reason\":\"allow\"}");
    handleStderrLine(&process, "{\"event\":\"egress_denied\",\"ip\":\"169.254.169.254\",\"port\":80,\"reason\":\"hard-floor\",\"extra\":1}");

    const event = process.popNetworkEvent() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(NetworkEventKind.egress_denied, event.kind);
    try std.testing.expectEqualSlices(u8, &.{ 169, 254, 169, 254 }, &event.destination_ip);
    try std.testing.expectEqual(@as(u16, 80), event.destination_port);
    try std.testing.expectEqual(spore_net_policy.Decision.deny_hard_floor, event.reason);
    try std.testing.expect(process.popNetworkEvent() == null);
}
