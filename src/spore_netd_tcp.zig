//! TCP relay adapter for `spore-netd`.
//!
//! `zmoltcp` owns the guest-facing Ethernet/IPv4/TCP state machine. This module
//! owns the SporeVM policy floor, bounded flow pool, host sockets, and the
//! bridge between guest TCP payloads and nonblocking host `connect()` sockets.

const std = @import("std");
const zmoltcp = @import("zmoltcp");

const spore_net = @import("spore_net.zig");

const stack_mod = zmoltcp.stack;
const tcp_socket = zmoltcp.socket.tcp;
const ethernet = zmoltcp.wire.ethernet;
const ipv4 = zmoltcp.wire.ipv4;
const tcp_wire = zmoltcp.wire.tcp;
const time = zmoltcp.time;

const Instant = time.Instant;
const Duration = time.Duration;

pub const max_flows = 8;
pub const flow_buffer_len = 8 * 1024;
pub const tcp_rx_buffer_len = 16 * 1024;
pub const tcp_tx_buffer_len = 16 * 1024;
pub const output_queue_len = 32;
pub const connect_timeout_ms = 10_000;
pub const flow_idle_timeout_ms = 120_000;

const TcpSock = tcp_socket.Socket(ipv4, 4);
const Device = stack_mod.LoopbackDevice(output_queue_len);
const ForwardRequest = tcp_socket.ForwardRequest(ipv4);
const Forwarder = tcp_socket.Forwarder(ipv4, TcpSock, Gateway);
const Sockets = struct {
    tcp4_sockets: []*TcpSock,
    tcp4_forwarder: *Forwarder,
};
const TcpStack = stack_mod.Stack(Device, Sockets);

pub const Stats = struct {
    accepted: usize = 0,
    denied: usize = 0,
    connect_attempts: usize = 0,
    connect_failed: usize = 0,
    flow_limit_drops: usize = 0,
    output_drops: usize = 0,
};

const HostState = enum {
    none,
    connecting,
    connected,
    failed,
};

const ByteBuffer = struct {
    data: [flow_buffer_len]u8 = undefined,
    start: usize = 0,
    len: usize = 0,

    fn reset(self: *ByteBuffer) void {
        self.start = 0;
        self.len = 0;
    }

    fn readable(self: *const ByteBuffer) []const u8 {
        return self.data[self.start..][0..self.len];
    }

    fn writable(self: *ByteBuffer) []u8 {
        self.compact();
        return self.data[self.start + self.len ..];
    }

    fn commit(self: *ByteBuffer, len: usize) void {
        std.debug.assert(self.start + self.len + len <= self.data.len);
        self.len += len;
    }

    fn consume(self: *ByteBuffer, len: usize) void {
        std.debug.assert(len <= self.len);
        self.start += len;
        self.len -= len;
        if (self.len == 0) self.start = 0;
    }

    fn freeLen(self: *ByteBuffer) usize {
        return self.writable().len;
    }

    fn compact(self: *ByteBuffer) void {
        if (self.start == 0) return;
        if (self.len > 0) std.mem.copyForwards(u8, self.data[0..self.len], self.data[self.start..][0..self.len]);
        self.start = 0;
    }
};

const Flow = struct {
    in_use: bool = false,
    fd: std.c.fd_t = -1,
    state: HostState = .none,
    request: ForwardRequest = undefined,
    sock: TcpSock = undefined,
    rx_storage: [tcp_rx_buffer_len]u8 = undefined,
    tx_storage: [tcp_tx_buffer_len]u8 = undefined,
    to_host: ByteBuffer = .{},
    to_guest: ByteBuffer = .{},
    guest_fin: bool = false,
    host_eof: bool = false,
    host_write_shutdown: bool = false,
    connect_deadline: Instant = Instant.ZERO,
    idle_deadline: Instant = Instant.ZERO,
    poll_revents: i16 = 0,

    fn init(self: *Flow) void {
        self.closeFd();
        self.* = .{};
        self.fd = -1;
        self.initSocket();
    }

    fn initSocket(self: *Flow) void {
        self.sock = TcpSock.init(&self.rx_storage, &self.tx_storage);
        self.sock.ack_delay = null;
        self.sock.setTimeout(Duration.fromMillis(flow_idle_timeout_ms));
    }

    fn start(self: *Flow, request: ForwardRequest, now: Instant) void {
        self.closeFd();
        self.in_use = true;
        self.state = .none;
        self.request = request;
        self.to_host.reset();
        self.to_guest.reset();
        self.guest_fin = false;
        self.host_eof = false;
        self.host_write_shutdown = false;
        self.poll_revents = 0;
        self.connect_deadline = now.add(Duration.fromMillis(connect_timeout_ms));
        self.idle_deadline = now.add(Duration.fromMillis(flow_idle_timeout_ms));
        self.initSocket();
    }

    fn closeFd(self: *Flow) void {
        if (self.fd >= 0) {
            _ = std.c.close(self.fd);
            self.fd = -1;
        }
    }

    fn refreshIdle(self: *Flow, now: Instant) void {
        self.idle_deadline = now.add(Duration.fromMillis(flow_idle_timeout_ms));
    }
};

const OutputQueue = struct {
    frames: [output_queue_len][spore_net.max_frame_len]u8 = undefined,
    lens: [output_queue_len]usize = .{0} ** output_queue_len,
    head: usize = 0,
    count: usize = 0,

    fn reset(self: *OutputQueue) void {
        self.head = 0;
        self.count = 0;
    }

    fn push(self: *OutputQueue, frame: []const u8) bool {
        if (self.count >= output_queue_len or frame.len > spore_net.max_frame_len) return false;
        const idx = (self.head + self.count) % output_queue_len;
        @memcpy(self.frames[idx][0..frame.len], frame);
        self.lens[idx] = frame.len;
        self.count += 1;
        return true;
    }

    fn pop(self: *OutputQueue) ?[]const u8 {
        if (self.count == 0) return null;
        const idx = self.head;
        const len = self.lens[idx];
        self.head = (self.head + 1) % output_queue_len;
        self.count -= 1;
        return self.frames[idx][0..len];
    }
};

pub const Gateway = struct {
    device: Device = Device.init(),
    flows: [max_flows]Flow = undefined,
    sock_ptrs: [max_flows]*TcpSock = undefined,
    forwarder: Forwarder = undefined,
    stack: TcpStack = undefined,
    output: OutputQueue = .{},
    current_now: Instant = Instant.ZERO,
    stats: Stats = .{},

    pub fn init(self: *Gateway) void {
        self.device = Device.init();
        self.output.reset();
        self.current_now = Instant.ZERO;
        self.stats = .{};
        for (&self.flows, 0..) |*flow, i| {
            flow.init();
            self.sock_ptrs[i] = &flow.sock;
        }
        self.forwarder = Forwarder.init(self, offer);
        self.stack = TcpStack.init(spore_net.gateway_mac, .{
            .tcp4_sockets = &self.sock_ptrs,
            .tcp4_forwarder = &self.forwarder,
        });
        self.stack.iface.v4.addIpAddr(.{ .address = spore_net.gateway_ipv4, .prefix_len = 30 });
    }

    pub fn receiveFrame(self: *Gateway, frame: []const u8, now: Instant) bool {
        if (!isGuestTcpFrame(frame)) return false;
        self.current_now = now;
        self.device.enqueueRx(frame);
        self.pollStack(now);
        return true;
    }

    pub fn service(self: *Gateway, now: Instant) void {
        self.current_now = now;
        for (&self.flows) |*flow| {
            self.serviceFlow(flow, now);
        }
        self.pollStack(now);
        for (&self.flows) |*flow| {
            self.reapFlow(flow);
        }
    }

    pub fn fillPollFds(self: *Gateway, fds: []std.posix.pollfd) usize {
        var count: usize = 0;
        for (&self.flows) |*flow| {
            if (!flow.in_use or flow.fd < 0) continue;
            var events: i16 = 0;
            if (flow.state == .connecting or flow.to_host.len > 0) events |= std.c.POLL.OUT;
            if (flow.state == .connected and !flow.host_eof and flow.to_guest.freeLen() > 0) events |= std.c.POLL.IN;
            if (events == 0) events = std.c.POLL.IN;
            if (count >= fds.len) break;
            fds[count] = .{ .fd = flow.fd, .events = events, .revents = 0 };
            count += 1;
        }
        return count;
    }

    pub fn servicePoll(self: *Gateway, fds: []const std.posix.pollfd) void {
        var count: usize = 0;
        for (&self.flows) |*flow| {
            flow.poll_revents = 0;
            if (!flow.in_use or flow.fd < 0) continue;
            if (count >= fds.len) break;
            flow.poll_revents = fds[count].revents;
            count += 1;
        }
    }

    pub fn nextPollTimeoutMs(self: *const Gateway, now: Instant) i32 {
        var next: ?Instant = null;
        if (self.stack.pollAt()) |at| next = minInstant(next, at);
        for (&self.flows) |*flow| {
            if (!flow.in_use) continue;
            next = minInstant(next, flow.idle_deadline);
            if (flow.state == .connecting) next = minInstant(next, flow.connect_deadline);
        }
        const deadline = next orelse return -1;
        if (!deadline.greaterThanOrEqual(now)) return 0;
        const micros = deadline.diff(now).totalMicros();
        if (micros <= 0) return 0;
        const ms = @divTrunc(micros + 999, 1000);
        return @intCast(@min(ms, 1_000));
    }

    pub fn dequeueFrame(self: *Gateway) ?[]const u8 {
        return self.output.pop();
    }

    fn offer(self: *Gateway, request: ForwardRequest) ?*TcpSock {
        if (!allowRequest(request)) {
            self.stats.denied += 1;
            return null;
        }

        const flow = self.freeFlow() orelse {
            self.stats.flow_limit_drops += 1;
            return null;
        };
        flow.start(request, self.current_now);

        self.stats.connect_attempts += 1;
        switch (openHostSocket(request.local.addr, request.local.port)) {
            .connected => |fd| {
                flow.fd = fd;
                flow.state = .connected;
                self.stats.accepted += 1;
            },
            .connecting => |fd| {
                flow.fd = fd;
                flow.state = .connecting;
                self.stats.accepted += 1;
            },
            .failed => {
                flow.state = .failed;
                self.stats.connect_failed += 1;
            },
        }
        return &flow.sock;
    }

    fn freeFlow(self: *Gateway) ?*Flow {
        for (&self.flows) |*flow| {
            if (!flow.in_use) return flow;
        }
        return null;
    }

    fn serviceFlow(self: *Gateway, flow: *Flow, now: Instant) void {
        if (!flow.in_use) return;
        if (now.greaterThanOrEqual(flow.idle_deadline)) {
            self.abortFlow(flow);
            return;
        }

        if (flow.state == .failed) {
            self.abortFlow(flow);
            return;
        }

        if (flow.state == .connecting) {
            const ready = (flow.poll_revents & (std.c.POLL.OUT | std.c.POLL.ERR | std.c.POLL.HUP)) != 0;
            if (ready) {
                if (hostConnectSucceeded(flow.fd)) {
                    flow.state = .connected;
                    flow.refreshIdle(now);
                } else {
                    flow.state = .failed;
                    self.stats.connect_failed += 1;
                    self.abortFlow(flow);
                    return;
                }
            } else if (now.greaterThanOrEqual(flow.connect_deadline)) {
                flow.state = .failed;
                self.stats.connect_failed += 1;
                self.abortFlow(flow);
                return;
            }
        }

        if (flow.state != .connected) return;

        self.drainGuestToHost(flow, now);
        self.flushHostWrite(flow, now);
        self.readHost(flow, now);
        self.drainHostToGuest(flow, now);

        if (flow.guest_fin and flow.to_host.len == 0 and !flow.host_write_shutdown and flow.fd >= 0) {
            _ = std.c.shutdown(flow.fd, std.c.SHUT.WR);
            flow.host_write_shutdown = true;
        }
        if (flow.host_eof and flow.to_guest.len == 0) {
            flow.closeFd();
            flow.state = .none;
            flow.sock.close();
        }
    }

    fn drainGuestToHost(_: *Gateway, flow: *Flow, now: Instant) void {
        while (flow.to_host.freeLen() > 0) {
            const writable = flow.to_host.writable();
            const n = flow.sock.recvSlice(writable) catch |err| switch (err) {
                error.Finished => {
                    flow.guest_fin = true;
                    break;
                },
                error.InvalidState => break,
            };
            if (n == 0) break;
            flow.to_host.commit(n);
            flow.refreshIdle(now);
        }
    }

    fn flushHostWrite(self: *Gateway, flow: *Flow, now: Instant) void {
        while (flow.fd >= 0 and flow.to_host.len > 0) {
            const n = hostSend(flow.fd, flow.to_host.readable()) catch |err| switch (err) {
                error.WouldBlock => break,
                error.HostIoFailed => {
                    self.abortFlow(flow);
                    return;
                },
            };
            if (n == 0) break;
            flow.to_host.consume(n);
            flow.refreshIdle(now);
        }
    }

    fn readHost(self: *Gateway, flow: *Flow, now: Instant) void {
        const can_read = (flow.poll_revents & (std.c.POLL.IN | std.c.POLL.ERR | std.c.POLL.HUP)) != 0;
        if (!can_read or flow.fd < 0 or flow.host_eof) return;
        while (flow.to_guest.freeLen() > 0) {
            const writable = flow.to_guest.writable();
            const result = hostRecv(flow.fd, writable) catch {
                self.abortFlow(flow);
                return;
            };
            switch (result) {
                .would_block => break,
                .closed => {
                    flow.host_eof = true;
                    break;
                },
                .read => |n| {
                    flow.to_guest.commit(n);
                    flow.refreshIdle(now);
                },
            }
        }
    }

    fn drainHostToGuest(self: *Gateway, flow: *Flow, now: Instant) void {
        while (flow.to_guest.len > 0 and flow.sock.canSend()) {
            const n = flow.sock.sendSlice(flow.to_guest.readable()) catch {
                self.abortFlow(flow);
                return;
            };
            if (n == 0) break;
            flow.to_guest.consume(n);
            flow.refreshIdle(now);
        }
    }

    fn abortFlow(_: *Gateway, flow: *Flow) void {
        flow.closeFd();
        flow.state = .none;
        flow.host_eof = true;
        flow.to_host.reset();
        flow.to_guest.reset();
        flow.sock.abort();
    }

    fn reapFlow(_: *Gateway, flow: *Flow) void {
        if (!flow.in_use) return;
        if (flow.fd >= 0) return;
        if (flow.sock.getState() != .closed) return;
        if (flow.sock.localEndpoint() != null) return;
        if (flow.to_host.len != 0 or flow.to_guest.len != 0) return;
        flow.init();
    }

    fn pollStack(self: *Gateway, now: Instant) void {
        _ = self.stack.poll(now, &self.device);
        while (self.device.dequeueTx()) |frame| {
            if (!self.output.push(frame)) self.stats.output_drops += 1;
        }
    }
};

const OpenResult = union(enum) {
    connected: std.c.fd_t,
    connecting: std.c.fd_t,
    failed,
};

fn openHostSocket(addr: ipv4.Address, port: u16) OpenResult {
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, std.c.IPPROTO.TCP);
    if (fd < 0) return .failed;
    if (!setNonBlocking(fd)) {
        _ = std.c.close(fd);
        return .failed;
    }

    var sockaddr = std.c.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(addr),
    };
    const rc = std.c.connect(fd, @ptrCast(&sockaddr), @sizeOf(std.c.sockaddr.in));
    if (rc == 0) return .{ .connected = fd };
    switch (std.c.errno(rc)) {
        .INPROGRESS, .AGAIN => return .{ .connecting = fd },
        else => {
            _ = std.c.close(fd);
            return .failed;
        },
    }
}

fn setNonBlocking(fd: std.c.fd_t) bool {
    const fl = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    if (fl < 0) return false;
    return std.c.fcntl(fd, std.c.F.SETFL, fl | @as(c_int, 1 << @bitOffsetOf(std.c.O, "NONBLOCK"))) == 0;
}

fn hostConnectSucceeded(fd: std.c.fd_t) bool {
    var err: c_int = 0;
    var len: std.c.socklen_t = @sizeOf(c_int);
    const rc = std.c.getsockopt(fd, std.c.SOL.SOCKET, std.c.SO.ERROR, &err, &len);
    return rc == 0 and err == 0;
}

const HostRead = union(enum) {
    read: usize,
    closed,
    would_block,
};

fn hostRecv(fd: std.c.fd_t, buf: []u8) error{HostIoFailed}!HostRead {
    const n = std.c.recv(fd, buf.ptr, buf.len, 0);
    if (n > 0) return .{ .read = @intCast(n) };
    if (n == 0) return .closed;
    return switch (std.c.errno(n)) {
        .AGAIN, .INTR => .would_block,
        else => error.HostIoFailed,
    };
}

fn hostSend(fd: std.c.fd_t, bytes: []const u8) error{ WouldBlock, HostIoFailed }!usize {
    const n = std.c.send(fd, bytes.ptr, bytes.len, 0);
    if (n > 0) return @intCast(n);
    if (n == 0) return 0;
    return switch (std.c.errno(n)) {
        .AGAIN, .INTR => error.WouldBlock,
        else => error.HostIoFailed,
    };
}

fn allowRequest(request: ForwardRequest) bool {
    if (!std.mem.eql(u8, &request.remote.addr, &spore_net.guest_ipv4)) return false;
    if (request.local.port == 0 or request.remote.port == 0) return false;
    return !isBlockedDestination(request.local.addr);
}

pub fn isBlockedDestination(addr: ipv4.Address) bool {
    if (addr[0] == 0) return true;
    if (addr[0] == 10) return true;
    if (addr[0] == 127) return true;
    if (addr[0] == 169 and addr[1] == 254) return true;
    if (addr[0] == 172 and (addr[1] & 0xf0) == 16) return true;
    if (addr[0] == 192 and addr[1] == 168) return true;
    if (addr[0] == 100 and (addr[1] & 0xc0) == 64) return true;
    if (addr[0] == 192 and addr[1] == 0 and addr[2] == 0) return true;
    if (addr[0] == 198 and (addr[1] == 18 or addr[1] == 19)) return true;
    if (addr[0] >= 224) return true;
    if (std.mem.eql(u8, &addr, &spore_net.guest_ipv4)) return true;
    if (std.mem.eql(u8, &addr, &spore_net.gateway_ipv4)) return true;
    return false;
}

fn isGuestTcpFrame(frame: []const u8) bool {
    if (frame.len < ethernet.HEADER_LEN + ipv4.HEADER_LEN + tcp_wire.HEADER_LEN) return false;
    const eth = ethernet.parse(frame) catch return false;
    if (!std.mem.eql(u8, &eth.dst_addr, &spore_net.gateway_mac)) return false;
    if (!std.mem.eql(u8, &eth.src_addr, &spore_net.guest_mac)) return false;
    if (eth.ethertype != .ipv4) return false;
    const ip_data = ethernet.payload(frame) catch return false;
    const ip_repr = ipv4.parse(ip_data) catch return false;
    if (ip_repr.protocol != .tcp) return false;
    if (!std.mem.eql(u8, &ip_repr.src_addr, &spore_net.guest_ipv4)) return false;
    return true;
}

fn minInstant(current: ?Instant, candidate: Instant) Instant {
    if (current) |value| return if (candidate.lessThan(value)) candidate else value;
    return candidate;
}

fn buildTcpSynFrame(dst_addr: ipv4.Address, dst_port: u16, out: *[spore_net.max_frame_len]u8) []const u8 {
    const tcp_len = tcp_wire.emit(.{
        .src_port = 49152,
        .dst_port = dst_port,
        .seq_number = 1000,
        .ack_number = 0,
        .data_offset = 5,
        .flags = .{ .syn = true },
        .window_size = 1024,
        .checksum = 0,
        .urgent_pointer = 0,
    }, out[ethernet.HEADER_LEN + ipv4.HEADER_LEN ..]) catch unreachable;

    _ = ethernet.emit(.{
        .dst_addr = spore_net.gateway_mac,
        .src_addr = spore_net.guest_mac,
        .ethertype = .ipv4,
    }, out[0..ethernet.HEADER_LEN]) catch unreachable;

    _ = ipv4.emit(.{
        .version = 4,
        .ihl = 5,
        .dscp_ecn = 0,
        .total_length = @intCast(ipv4.HEADER_LEN + tcp_len),
        .identification = 0,
        .dont_fragment = false,
        .more_fragments = false,
        .fragment_offset = 0,
        .ttl = 64,
        .protocol = .tcp,
        .checksum = 0,
        .src_addr = spore_net.guest_ipv4,
        .dst_addr = dst_addr,
    }, out[ethernet.HEADER_LEN..][0..ipv4.HEADER_LEN]) catch unreachable;

    return out[0 .. ethernet.HEADER_LEN + ipv4.HEADER_LEN + tcp_len];
}

test "spore-netd TCP policy blocks host and control-plane destinations" {
    try std.testing.expect(isBlockedDestination(.{ 0, 1, 2, 3 }));
    try std.testing.expect(isBlockedDestination(.{ 10, 0, 0, 1 }));
    try std.testing.expect(isBlockedDestination(.{ 127, 0, 0, 1 }));
    try std.testing.expect(isBlockedDestination(.{ 169, 254, 169, 254 }));
    try std.testing.expect(isBlockedDestination(.{ 172, 16, 0, 1 }));
    try std.testing.expect(isBlockedDestination(.{ 172, 31, 255, 254 }));
    try std.testing.expect(isBlockedDestination(.{ 192, 168, 1, 1 }));
    try std.testing.expect(isBlockedDestination(.{ 100, 96, 0, 1 }));
    try std.testing.expect(isBlockedDestination(.{ 224, 0, 0, 1 }));
    try std.testing.expect(!isBlockedDestination(.{ 93, 184, 216, 34 }));
}

test "spore-netd TCP denies blocked SYN before host socket open" {
    var gateway: Gateway = undefined;
    gateway.init();

    const blocked = [_]ipv4.Address{
        .{ 169, 254, 169, 254 },
        .{ 127, 0, 0, 1 },
        .{ 10, 0, 0, 1 },
        .{ 172, 16, 0, 1 },
        .{ 192, 168, 1, 1 },
    };

    for (blocked, 0..) |addr, i| {
        var frame_buf: [spore_net.max_frame_len]u8 = undefined;
        const frame = buildTcpSynFrame(addr, 80, &frame_buf);
        const now = Instant.fromMillis(@intCast(i));
        try std.testing.expect(gateway.receiveFrame(frame, now));
        gateway.service(now);
    }

    try std.testing.expectEqual(blocked.len, gateway.stats.denied);
    try std.testing.expectEqual(@as(usize, 0), gateway.stats.connect_attempts);
    try std.testing.expectEqual(@as(?[]const u8, null), gateway.dequeueFrame());
}

fn fuzzGuestTcpFrameClassifier(_: void, s: *std.testing.Smith) !void {
    var bytes: [spore_net.max_frame_len]u8 = undefined;
    const len = @min(s.slice(&bytes), bytes.len);
    _ = isGuestTcpFrame(bytes[0..len]);
}

test "fuzz spore-netd TCP Ethernet and IPv4 frame classification" {
    try std.testing.fuzz({}, fuzzGuestTcpFrameClassifier, .{});
}
