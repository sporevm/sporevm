//! TCP relay adapter for `spore-netd`.
//!
//! `zmoltcp` owns the guest-facing Ethernet/IPv4/TCP state machine. This module
//! owns the SporeVM policy floor, bounded flow pool, host sockets, and the
//! bridge between guest TCP payloads and nonblocking host `connect()` sockets.

const std = @import("std");
const builtin = @import("builtin");
const zmoltcp = @import("zmoltcp");

const spore_net = @import("spore_net.zig");
const spore_net_policy = @import("spore_net_policy.zig");

const stack_mod = zmoltcp.stack;
const tcp_socket = zmoltcp.socket.tcp;
const ethernet = zmoltcp.wire.ethernet;
const ipv4 = zmoltcp.wire.ipv4;
const tcp_wire = zmoltcp.wire.tcp;
const time = zmoltcp.time;

const Instant = time.Instant;
const Duration = time.Duration;

// Keep the guest-visible gateway IP unassigned so the TCP forwarder can own it.
// The /31 makes .3 a usable internal route source instead of the guest /30's
// broadcast address.
const tcp_stack_ipv4: ipv4.Address = .{ 100, 96, 0, 3 };
const tcp_stack_prefix_len: u8 = 31;

pub const max_flows = 8;
pub const max_port_forwards = spore_net_policy.max_port_forwards;
pub const flow_buffer_len = 8 * 1024;
pub const tcp_rx_buffer_len = 16 * 1024;
pub const tcp_tx_buffer_len = 16 * 1024;
pub const output_queue_len = 32;
pub const connect_timeout_ms = 10_000;
pub const flow_idle_timeout_ms = 120_000;
const first_forward_local_port: u16 = 49152;
const last_forward_local_port: u16 = 60999;

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

const RequestTarget = union(enum) {
    tcp: ?[]const u8,
    bound_unix: *const spore_net_policy.BoundServiceConfig,
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

    fn startPortForward(self: *Flow, host_fd: std.c.fd_t, guest_port: u16, local_port: u16, now: Instant) bool {
        self.closeFd();
        self.in_use = true;
        self.state = .connected;
        self.fd = host_fd;
        self.to_host.reset();
        self.to_guest.reset();
        self.guest_fin = false;
        self.host_eof = false;
        self.host_write_shutdown = false;
        self.poll_revents = 0;
        self.connect_deadline = now.add(Duration.fromMillis(connect_timeout_ms));
        self.idle_deadline = now.add(Duration.fromMillis(flow_idle_timeout_ms));
        self.initSocket();
        self.sock.connect(spore_net.guest_ipv4, guest_port, spore_net.gateway_ipv4, local_port) catch {
            self.closeFd();
            self.in_use = false;
            return false;
        };
        return true;
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

const PortForward = struct {
    fd: std.c.fd_t = -1,
    guest_port: u16 = 0,
    poll_revents: i16 = 0,

    fn close(self: *PortForward) void {
        if (self.fd >= 0) {
            _ = std.c.close(self.fd);
            self.fd = -1;
        }
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
    port_forwards: [max_port_forwards]PortForward = [_]PortForward{.{}} ** max_port_forwards,
    port_forward_count: usize = 0,
    sock_ptrs: [max_flows]*TcpSock = undefined,
    forwarder: Forwarder = undefined,
    stack: TcpStack = undefined,
    policy: *spore_net_policy.Runtime = undefined,
    output: OutputQueue = .{},
    current_now: Instant = Instant.ZERO,
    next_forward_local_port: u16 = first_forward_local_port,
    stats: Stats = .{},
    emit_events: bool = false,

    pub fn init(self: *Gateway, policy: *spore_net_policy.Runtime, port_forwards: []const spore_net_policy.PortForwardConfig) !void {
        self.device = Device.init();
        self.policy = policy;
        self.port_forwards = [_]PortForward{.{}} ** max_port_forwards;
        self.port_forward_count = 0;
        self.output.reset();
        self.current_now = Instant.ZERO;
        self.next_forward_local_port = first_forward_local_port;
        self.stats = .{};
        self.emit_events = false;
        for (&self.flows, 0..) |*flow, i| {
            flow.init();
            self.sock_ptrs[i] = &flow.sock;
        }
        self.forwarder = Forwarder.init(self, offer);
        self.stack = TcpStack.init(spore_net.gateway_mac, .{
            .tcp4_sockets = &self.sock_ptrs,
            .tcp4_forwarder = &self.forwarder,
        });
        self.stack.iface.v4.addIpAddr(.{ .address = tcp_stack_ipv4, .prefix_len = tcp_stack_prefix_len });
        errdefer self.deinit();
        for (port_forwards) |forward| {
            try self.addPortForward(forward);
        }
    }

    pub fn deinit(self: *Gateway) void {
        for (self.port_forwards[0..self.port_forward_count]) |*forward| {
            forward.close();
        }
        self.port_forward_count = 0;
        for (&self.flows) |*flow| {
            flow.closeFd();
        }
    }

    fn addPortForward(self: *Gateway, config: spore_net_policy.PortForwardConfig) !void {
        if (config.host_port == 0 or config.guest_port == 0) return error.InvalidPortForward;
        if (self.port_forward_count >= max_port_forwards) return error.PortForwardListenFailed;
        const fd = try openLoopbackListener(config.host_port);
        self.port_forwards[self.port_forward_count] = .{
            .fd = fd,
            .guest_port = config.guest_port,
        };
        self.port_forward_count += 1;
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
        if (self.port_forward_count != 0) {
            self.stack.iface.neighbor_cache.fill(spore_net.guest_ipv4, spore_net.guest_mac, now);
        }
        self.acceptPortForwards(now);
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
        for (self.port_forwards[0..self.port_forward_count]) |*forward| {
            if (forward.fd < 0 or count >= fds.len) continue;
            fds[count] = .{ .fd = forward.fd, .events = std.c.POLL.IN, .revents = 0 };
            count += 1;
        }
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
        for (self.port_forwards[0..self.port_forward_count]) |*forward| {
            forward.poll_revents = 0;
            if (forward.fd < 0) continue;
            if (count >= fds.len) break;
            forward.poll_revents = fds[count].revents;
            count += 1;
        }
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

    fn acceptPortForwards(self: *Gateway, now: Instant) void {
        for (self.port_forwards[0..self.port_forward_count]) |*forward| {
            if ((forward.poll_revents & (std.c.POLL.IN | std.c.POLL.ERR | std.c.POLL.HUP)) == 0) continue;
            accept_loop: while (true) {
                const fd = std.c.accept(forward.fd, null, null);
                if (fd < 0) {
                    switch (std.c.errno(fd)) {
                        .INTR => continue,
                        .AGAIN => break :accept_loop,
                        else => break :accept_loop,
                    }
                }
                if (!setNonBlocking(fd)) {
                    _ = std.c.close(fd);
                    continue;
                }
                const flow = self.freeFlow() orelse {
                    self.stats.flow_limit_drops += 1;
                    _ = std.c.close(fd);
                    break :accept_loop;
                };
                if (!flow.startPortForward(fd, forward.guest_port, self.nextForwardLocalPort(), now)) {
                    self.stats.connect_failed += 1;
                    continue;
                }
                self.stats.accepted += 1;
            }
        }
    }

    fn nextForwardLocalPort(self: *Gateway) u16 {
        const port = self.next_forward_local_port;
        self.next_forward_local_port = if (port >= last_forward_local_port) first_forward_local_port else port + 1;
        return port;
    }

    fn offer(self: *Gateway, request: ForwardRequest) ?*TcpSock {
        const target = self.targetForRequest(request) orelse {
            self.stats.denied += 1;
            return null;
        };

        const flow = self.freeFlow() orelse {
            self.stats.flow_limit_drops += 1;
            return null;
        };
        flow.start(request, self.current_now);

        self.stats.connect_attempts += 1;
        const open_result = switch (target) {
            .tcp => |host| blk: {
                emitNetworkDecision("allow", host, request.local.addr, request.local.port, "policy");
                break :blk openHostSocket(request.local.addr, request.local.port);
            },
            .bound_unix => |bound| blk: {
                const host: ?[]const u8 = if (bound.guest_host.len == 0) null else bound.guest_host;
                emitNetworkDecision("allow", host, request.local.addr, request.local.port, bound.name);
                break :blk openUnixSocket(bound.unix_path);
            },
        };
        switch (open_result) {
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

    fn targetForRequest(self: *Gateway, request: ForwardRequest) ?RequestTarget {
        if (!std.mem.eql(u8, &request.remote.addr, &spore_net.guest_ipv4)) return null;
        if (request.local.port == 0 or request.remote.port == 0) return null;
        if (std.mem.eql(u8, &request.local.addr, &spore_net.gateway_ipv4)) {
            if (self.policy.boundServiceForPort(request.local.port)) |bound| return .{ .bound_unix = bound };
        }
        const decision = self.policy.decideIpv4Port(request.local.addr, request.local.port);
        const host = self.policy.hostForIpv4Port(request.local.addr, request.local.port);
        if (decision == .allow) return .{ .tcp = host };
        if (self.emit_events) emitDeniedEgressEvent(request.local.addr, request.local.port, decision);
        emitNetworkDecision("deny", host, request.local.addr, request.local.port, decision.name());
        std.log.debug(
            "spore-netd denied egress reason={s} dst={d}.{d}.{d}.{d}:{d}",
            .{
                decision.name(),
                request.local.addr[0],
                request.local.addr[1],
                request.local.addr[2],
                request.local.addr[3],
                request.local.port,
            },
        );
        return null;
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

        if (flow.sock.getState() == .syn_sent and now.greaterThanOrEqual(flow.connect_deadline)) {
            self.abortFlow(flow);
            return;
        }
        if (flow.sock.getState() == .closed and flow.to_host.len == 0) {
            flow.closeFd();
            flow.host_eof = true;
            return;
        }

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

fn emitNetworkDecision(action: []const u8, host: ?[]const u8, addr: ipv4.Address, port: u16, reason: []const u8) void {
    if (builtin.is_test) return;
    if (host) |value| {
        std.debug.print(
            "{{\"event\":\"network_decision\",\"action\":\"{s}\",\"host\":\"{s}\",\"ip\":\"{d}.{d}.{d}.{d}\",\"port\":{d},\"reason_code\":\"{s}\"}}\n",
            .{ action, value, addr[0], addr[1], addr[2], addr[3], port, reason },
        );
    } else {
        std.debug.print(
            "{{\"event\":\"network_decision\",\"action\":\"{s}\",\"host\":null,\"ip\":\"{d}.{d}.{d}.{d}\",\"port\":{d},\"reason_code\":\"{s}\"}}\n",
            .{ action, addr[0], addr[1], addr[2], addr[3], port, reason },
        );
    }
}

const OpenResult = union(enum) {
    connected: std.c.fd_t,
    connecting: std.c.fd_t,
    failed,
};

fn openLoopbackListener(port: u16) error{PortForwardListenFailed}!std.c.fd_t {
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, std.c.IPPROTO.TCP);
    if (fd < 0) return error.PortForwardListenFailed;
    errdefer _ = std.c.close(fd);

    var reuse: c_int = 1;
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &reuse, @sizeOf(c_int));
    if (!setNonBlocking(fd)) return error.PortForwardListenFailed;

    var sockaddr = std.c.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
    };
    if (std.c.bind(fd, @ptrCast(&sockaddr), @sizeOf(std.c.sockaddr.in)) != 0) return error.PortForwardListenFailed;
    if (std.c.listen(fd, 16) != 0) return error.PortForwardListenFailed;
    return fd;
}

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

fn openUnixSocket(path: []const u8) OpenResult {
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (fd < 0) return .failed;
    if (!setNonBlocking(fd)) {
        _ = std.c.close(fd);
        return .failed;
    }

    var sockaddr = std.mem.zeroes(std.c.sockaddr.un);
    sockaddr.family = std.c.AF.UNIX;
    if (@hasField(std.c.sockaddr.un, "len")) sockaddr.len = @sizeOf(std.c.sockaddr.un);
    if (path.len >= sockaddr.path.len) {
        _ = std.c.close(fd);
        return .failed;
    }
    @memcpy(sockaddr.path[0..path.len], path);
    const rc = std.c.connect(fd, @ptrCast(&sockaddr), @sizeOf(std.c.sockaddr.un));
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

pub fn isBlockedDestination(addr: ipv4.Address) bool {
    if (spore_net_policy.isHardFloorBlocked(addr)) return true;
    if (std.mem.eql(u8, &addr, &spore_net.guest_ipv4)) return true;
    if (std.mem.eql(u8, &addr, &spore_net.gateway_ipv4)) return true;
    return false;
}

fn emitDeniedEgressEvent(addr: ipv4.Address, port: u16, reason: spore_net_policy.Decision) void {
    std.debug.print(
        "spore-net-event egress_denied {d}.{d}.{d}.{d} {d} {s}\n",
        .{ addr[0], addr[1], addr[2], addr[3], port, reason.name() },
    );
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

    const tcp = out[ethernet.HEADER_LEN + ipv4.HEADER_LEN ..][0..tcp_len];
    const tcp_checksum = tcp_wire.computeChecksum(spore_net.guest_ipv4, dst_addr, tcp);
    tcp[16] = @truncate(tcp_checksum >> 8);
    tcp[17] = @truncate(tcp_checksum & 0xFF);

    return out[0 .. ethernet.HEADER_LEN + ipv4.HEADER_LEN + tcp_len];
}

fn testForwardRequest(dst_addr: ipv4.Address, dst_port: u16) ForwardRequest {
    return .{
        .local = .{ .addr = dst_addr, .port = dst_port },
        .remote = .{ .addr = spore_net.guest_ipv4, .port = 49152 },
    };
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
    var policy = try spore_net_policy.Runtime.init(.{});
    var gateway: Gateway = undefined;
    try gateway.init(&policy, &.{});

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

test "spore-netd TCP routes bound service SYNs before gateway hard-floor denial" {
    var config = spore_net_policy.Config{};
    try config.addBindService("metadata=unix:/tmp/sporevm-netd-missing-bound-service.sock");
    var policy = try spore_net_policy.Runtime.init(config);
    var gateway: Gateway = undefined;
    try gateway.init(&policy, &.{});

    var frame_buf: [spore_net.max_frame_len]u8 = undefined;
    const service_syn = buildTcpSynFrame(spore_net.gateway_ipv4, 80, &frame_buf);
    const now = Instant.fromMillis(1);
    try std.testing.expect(gateway.receiveFrame(service_syn, now));
    gateway.service(now);

    try std.testing.expectEqual(@as(usize, 0), gateway.stats.denied);
    try std.testing.expectEqual(@as(usize, 1), gateway.stats.connect_attempts);
    try std.testing.expectEqual(@as(usize, 1), gateway.stats.connect_failed);

    const denied_syn = buildTcpSynFrame(spore_net.gateway_ipv4, 81, &frame_buf);
    const later = Instant.fromMillis(2);
    try std.testing.expect(gateway.receiveFrame(denied_syn, later));
    gateway.service(later);

    try std.testing.expectEqual(@as(usize, 1), gateway.stats.denied);
    try std.testing.expectEqual(@as(usize, 1), gateway.stats.connect_attempts);
}

test "spore-netd TCP routes two bound services independently and rejects duplicates" {
    var config = spore_net_policy.Config{};
    try config.addBindService("metadata=unix:/tmp/metadata.sock");
    try std.testing.expectError(error.DuplicateBoundService, config.addBindService("metadata:8080=unix:/tmp/metadata-2.sock"));
    try std.testing.expectError(error.DuplicateBoundService, config.addBindService("cache=unix:/tmp/cache.sock"));
    try config.addBindService("cache:8080=unix:/tmp/cache.sock");

    var policy = try spore_net_policy.Runtime.init(config);
    var gateway: Gateway = undefined;
    try gateway.init(&policy, &.{});

    const metadata = gateway.targetForRequest(testForwardRequest(spore_net.gateway_ipv4, 80)) orelse return error.TestUnexpectedResult;
    switch (metadata) {
        .bound_unix => |bound| {
            try std.testing.expectEqualStrings("metadata", bound.name);
            try std.testing.expectEqualStrings("/tmp/metadata.sock", bound.unix_path);
        },
        .tcp => return error.TestUnexpectedResult,
    }

    const cache = gateway.targetForRequest(testForwardRequest(spore_net.gateway_ipv4, 8080)) orelse return error.TestUnexpectedResult;
    switch (cache) {
        .bound_unix => |bound| {
            try std.testing.expectEqualStrings("cache", bound.name);
            try std.testing.expectEqualStrings("/tmp/cache.sock", bound.unix_path);
        },
        .tcp => return error.TestUnexpectedResult,
    }
}

test "spore-netd TCP opens bound Unix stream sockets" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "/tmp/sporevm-netd-unix-test-{d}.sock", .{std.c.getpid()});
    const path = path_z[0..path_z.len];
    _ = std.c.unlink(path_z.ptr);
    defer _ = std.c.unlink(path_z.ptr);

    const listener = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    try std.testing.expect(listener >= 0);
    defer _ = std.c.close(listener);

    var sockaddr = std.mem.zeroInit(std.c.sockaddr.un, .{});
    sockaddr.family = std.c.AF.UNIX;
    @memcpy(sockaddr.path[0..path.len], path);
    try std.testing.expectEqual(@as(c_int, 0), std.c.bind(listener, @ptrCast(&sockaddr), @sizeOf(std.c.sockaddr.un)));
    try std.testing.expectEqual(@as(c_int, 0), std.c.listen(listener, 1));

    const opened = openUnixSocket(path);
    const client = switch (opened) {
        .connected, .connecting => |fd| fd,
        .failed => return error.TestUnexpectedResult,
    };
    defer _ = std.c.close(client);

    const accepted = std.c.accept(listener, null, null);
    try std.testing.expect(accepted >= 0);
    defer _ = std.c.close(accepted);

    try std.testing.expectEqual(@as(usize, 4), try hostSend(client, "ping"));
    var buf: [4]u8 = undefined;
    const n = std.c.recv(accepted, &buf, buf.len, 0);
    try std.testing.expectEqual(@as(isize, 4), n);
    try std.testing.expectEqualStrings("ping", &buf);
}

test "spore-netd TCP enforces exact learned host ports" {
    var config = spore_net_policy.Config{};
    try config.addExactHostPorts("github.com", &.{443});
    var policy = try spore_net_policy.Runtime.init(config);

    var query_buf: [512]u8 = undefined;
    const query = spore_net_policy.testDnsQuery(0x1234, "github.com", &query_buf);
    var response_buf: [512]u8 = undefined;
    const response = spore_net_policy.testDnsResponse(query, "*", &.{.{ 203, 0, 113, 10 }}, &response_buf);
    try std.testing.expectEqual(@as(usize, 1), policy.noteDnsResponse(query, response));

    var gateway: Gateway = undefined;
    try gateway.init(&policy, &.{});
    try std.testing.expect(gateway.targetForRequest(testForwardRequest(.{ 203, 0, 113, 10 }, 443)) != null);
    try std.testing.expect(gateway.targetForRequest(testForwardRequest(.{ 203, 0, 113, 10 }, 80)) == null);
}

test "spore-netd TCP routes configured bound service ports to Unix sockets" {
    var config = spore_net_policy.Config{};
    try config.addBoundUnixService("cleanroom-gateway", "gateway.cleanroom.internal", 8170, "/tmp/missing-cleanroom.sock");
    var policy = try spore_net_policy.Runtime.init(config);
    var gateway: Gateway = undefined;
    try gateway.init(&policy, &.{});

    const target = gateway.targetForRequest(testForwardRequest(spore_net.gateway_ipv4, 8170)) orelse return error.TestUnexpectedResult;
    switch (target) {
        .bound_unix => |service| try std.testing.expectEqualStrings("cleanroom-gateway", service.name),
        .tcp => return error.TestUnexpectedResult,
    }
    try std.testing.expect(gateway.targetForRequest(testForwardRequest(spore_net.gateway_ipv4, 8171)) == null);
}

fn fuzzGuestTcpFrameClassifier(_: void, s: *std.testing.Smith) !void {
    var bytes: [spore_net.max_frame_len]u8 = undefined;
    const len = @min(s.slice(&bytes), bytes.len);
    _ = isGuestTcpFrame(bytes[0..len]);
}

test "fuzz spore-netd TCP Ethernet and IPv4 frame classification" {
    try std.testing.fuzz({}, fuzzGuestTcpFrameClassifier, .{});
}
