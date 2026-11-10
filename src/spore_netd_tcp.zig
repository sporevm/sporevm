//! TCP relay adapter for `spore-netd`.
//!
//! `zmoltcp` owns the guest-facing Ethernet/IPv4/TCP state machine. This module
//! owns the SporeVM policy floor, bounded flow pool, host sockets, and the
//! bridge between guest TCP payloads and nonblocking host `connect()` sockets.

const std = @import("std");
const zmoltcp = @import("zmoltcp");

const fuzz_support = @import("fuzz_support.zig");
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

// Shared by outbound TCP, bound services, and host port forwards. Keep the
// bounded buffers off the helper's stack as the pool grows.
pub const max_flows = 256;
pub const max_port_forwards = spore_net_policy.max_port_forwards;
pub const flow_buffer_len = 8 * 1024;
pub const tcp_rx_buffer_len = 16 * 1024;
pub const tcp_tx_buffer_len = 16 * 1024;
pub const output_queue_len = 64;
pub const connect_timeout_ms = 10_000;
pub const flow_idle_timeout_ms = 120_000;
const first_forward_local_port: u16 = 49152;
const last_forward_local_port: u16 = 60999;

const TcpSock = tcp_socket.Socket(ipv4, 4);
// netd polls once for an incoming frame and once for host I/O before draining
// output. Bound each burst so neither poll advances TCP past a dropped frame.
const Device = struct {
    rx: OutputQueue = .{},
    tx: OutputQueue = .{},

    pub fn capabilities() zmoltcp.iface.DeviceCapabilities {
        return .{ .max_burst_size = output_queue_len / 2 - 1 };
    }

    pub fn init() Device {
        return .{};
    }

    pub fn enqueueRx(self: *Device, frame: []const u8) void {
        const queued = self.rx.push(frame);
        std.debug.assert(queued);
    }

    pub fn receive(self: *Device) ?[]const u8 {
        return self.rx.pop();
    }

    pub fn transmit(self: *Device, frame: []const u8) void {
        const queued = self.tx.push(frame);
        std.debug.assert(queued);
    }

    pub fn dequeueTx(self: *Device) ?[]const u8 {
        return self.tx.pop();
    }
};
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

const FlowState = enum {
    free,
    connecting,
    connected,
    /// The host socket failed to open or connect; aborted on next service.
    failed,
    /// The host socket is closed; the slot is reaped once the guest socket is.
    closed,
};

const RequestTarget = union(enum) {
    tcp,
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
    fd: std.c.fd_t = -1,
    state: FlowState = .free,
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
    /// Index of this flow's entry in the last `fillPollFds` set. Cleared
    /// whenever the fd closes, so a flow restarted in the same slot, or opened
    /// after the poll set was built, cannot take another fd's revents.
    poll_index: ?usize = null,

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
        self.state = .failed;
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
            self.state = .free;
            return false;
        };
        return true;
    }

    fn closeFd(self: *Flow) void {
        self.poll_index = null;
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
    lens: [output_queue_len]usize = @splat(0),
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
    flows: []Flow = undefined,
    port_forwards: [max_port_forwards]PortForward = @splat(.{}),
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
    /// Set by `offer` when policy or capacity rejects the SYN being processed.
    syn_rejected: bool = false,

    pub fn init(self: *Gateway, policy: *spore_net_policy.Runtime, port_forwards: []const spore_net_policy.PortForwardConfig) !void {
        self.device = Device.init();
        self.policy = policy;
        self.port_forwards = @splat(.{});
        self.port_forward_count = 0;
        self.output.reset();
        self.current_now = Instant.ZERO;
        self.next_forward_local_port = first_forward_local_port;
        self.stats = .{};
        self.emit_events = false;
        self.syn_rejected = false;
        self.flows = try std.heap.page_allocator.alloc(Flow, max_flows);
        for (self.flows, 0..) |*flow, i| {
            flow.* = .{};
            flow.initSocket();
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
        for (self.flows) |*flow| {
            flow.closeFd();
        }
        std.heap.page_allocator.free(self.flows);
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
        self.syn_rejected = false;
        self.device.enqueueRx(frame);
        self.pollStack(now);
        if (self.syn_rejected) {
            var reset_buf: [spore_net.max_frame_len]u8 = undefined;
            if (buildSynReset(frame, &reset_buf)) |reset| {
                if (!self.output.push(reset)) self.stats.output_drops += 1;
            }
        }
        return true;
    }

    pub fn service(self: *Gateway, now: Instant) void {
        self.current_now = now;
        if (self.port_forward_count != 0) {
            self.stack.iface.neighbor_cache.fill(spore_net.guest_ipv4, spore_net.guest_mac, now);
        }
        self.acceptPortForwards(now);
        for (self.flows) |*flow| {
            self.serviceFlow(flow, now);
        }
        self.pollStack(now);
        for (self.flows) |*flow| {
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
        for (self.flows) |*flow| {
            flow.poll_index = null;
            if (flow.fd < 0) continue;
            var events: i16 = 0;
            if (flow.state == .connecting or flow.to_host.len > 0) events |= std.c.POLL.OUT;
            if (flow.state == .connected and !flow.host_eof and flow.to_guest.freeLen() > 0) events |= std.c.POLL.IN;
            // Nothing to write and no room for host bytes (or host EOF): a
            // readable socket would wake every poll until the guest catches
            // up, so leave it out until there is something to do.
            if (events == 0) continue;
            if (count >= fds.len) break;
            fds[count] = .{ .fd = flow.fd, .events = events, .revents = 0 };
            flow.poll_index = count;
            count += 1;
        }
        return count;
    }

    /// Applies poll results from the set built by `fillPollFds`. Guest frames
    /// handled in between may open or restart flows, so flows are matched by
    /// their recorded entry rather than by position.
    pub fn servicePoll(self: *Gateway, fds: []const std.posix.pollfd) void {
        var count: usize = 0;
        for (self.port_forwards[0..self.port_forward_count]) |*forward| {
            forward.poll_revents = 0;
            if (forward.fd < 0) continue;
            if (count >= fds.len) break;
            forward.poll_revents = fds[count].revents;
            count += 1;
        }
        for (self.flows) |*flow| {
            flow.poll_revents = 0;
            const index = flow.poll_index orelse continue;
            flow.poll_index = null;
            if (index < fds.len and fds[index].fd == flow.fd) flow.poll_revents = fds[index].revents;
        }
    }

    pub fn nextPollTimeoutMs(self: *const Gateway, now: Instant) i32 {
        var next: ?Instant = null;
        if (self.stack.pollAt()) |at| next = minInstant(next, at);
        for (self.flows) |*flow| {
            if (flow.state == .free) continue;
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
            self.syn_rejected = true;
            return null;
        };

        const flow = self.freeFlow() orelse {
            self.stats.flow_limit_drops += 1;
            self.syn_rejected = true;
            return null;
        };
        flow.start(request, self.current_now);

        self.stats.connect_attempts += 1;
        const open_result = switch (target) {
            .tcp => openHostSocket(request.local.addr, request.local.port),
            .bound_unix => |bound| openUnixSocket(bound.unix_path),
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
        if (decision == .allow) return .tcp;
        if (self.emit_events) {
            var line: [max_denied_event_len]u8 = undefined;
            std.debug.print("{s}\n", .{deniedEventLine(&line, request.local.addr, request.local.port, decision)});
        }
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
        for (self.flows) |*flow| {
            if (flow.state == .free) return flow;
        }
        return null;
    }

    fn serviceFlow(self: *Gateway, flow: *Flow, now: Instant) void {
        if (flow.state == .free) return;
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
            flow.state = .closed;
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
            // The host has finished sending, so FIN the guest, but keep the
            // host socket until the guest's remaining bytes have reached it.
            flow.sock.close();
            if (flow.host_write_shutdown) {
                flow.closeFd();
                flow.state = .closed;
            }
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
        flow.state = .closed;
        flow.host_eof = true;
        flow.to_host.reset();
        flow.to_guest.reset();
        flow.sock.abort();
    }

    fn reapFlow(_: *Gateway, flow: *Flow) void {
        if (flow.state == .free) return;
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

/// The `spore-netd` stderr line for a denied guest connection. The parent
/// parses it back with this type into a run `network` event.
pub const DeniedEvent = struct {
    event: []const u8 = "egress_denied",
    ip: []const u8,
    port: u16,
    reason: []const u8,
};

pub const max_denied_event_len = 128;

pub fn deniedEventLine(out: *[max_denied_event_len]u8, addr: ipv4.Address, port: u16, decision: spore_net_policy.Decision) []const u8 {
    var ip_buf: [15]u8 = undefined;
    const ip = std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ addr[0], addr[1], addr[2], addr[3] }) catch unreachable;
    var writer = std.Io.Writer.fixed(out);
    std.json.Stringify.value(DeniedEvent{ .ip = ip, .port = port, .reason = decision.name() }, .{}, &writer) catch unreachable;
    return writer.buffered();
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

/// Builds the RST|ACK answering a denied guest SYN (RFC 9293 3.10.7.1), so
/// the guest connection fails at once instead of retrying the SYN until it
/// times out. Only called for frames the stack accepted as a valid SYN.
fn buildSynReset(syn_frame: []const u8, out: *[spore_net.max_frame_len]u8) ?[]const u8 {
    const eth = ethernet.parse(syn_frame) catch return null;
    const ip_data = ethernet.payload(syn_frame) catch return null;
    const ip_repr = ipv4.parse(ip_data) catch return null;
    const segment = ipv4.payloadSlice(ip_data) catch return null;
    const syn = tcp_socket.TcpRepr.fromWireBytes(segment) orelse return null;
    const reset = tcp_socket.rstReply(syn).toWireRepr();
    const tcp_len = tcp_wire.emit(reset, out[ethernet.HEADER_LEN + ipv4.HEADER_LEN ..]) catch return null;
    _ = ethernet.emit(.{
        .dst_addr = eth.src_addr,
        .src_addr = spore_net.gateway_mac,
        .ethertype = .ipv4,
    }, out[0..ethernet.HEADER_LEN]) catch return null;
    _ = ipv4.emit(.{
        .version = 4,
        .ihl = 5,
        .dscp_ecn = 0,
        .total_length = @intCast(ipv4.HEADER_LEN + tcp_len),
        .identification = 0,
        .dont_fragment = true,
        .more_fragments = false,
        .fragment_offset = 0,
        .ttl = 64,
        .protocol = .tcp,
        .checksum = 0,
        .src_addr = ip_repr.dst_addr,
        .dst_addr = ip_repr.src_addr,
    }, out[ethernet.HEADER_LEN..][0..ipv4.HEADER_LEN]) catch return null;
    const tcp = out[ethernet.HEADER_LEN + ipv4.HEADER_LEN ..][0..tcp_len];
    std.mem.writeInt(u16, tcp[16..18], tcp_wire.computeChecksum(ip_repr.dst_addr, ip_repr.src_addr, tcp), .big);
    return out[0 .. ethernet.HEADER_LEN + ipv4.HEADER_LEN + tcp_len];
}

fn minInstant(current: ?Instant, candidate: Instant) Instant {
    if (current) |value| return if (candidate.lessThan(value)) candidate else value;
    return candidate;
}

fn buildTcpSynFrame(dst_addr: ipv4.Address, dst_port: u16, out: *[spore_net.max_frame_len]u8) []const u8 {
    return buildTcpSynFrameFrom(49152, dst_addr, dst_port, out);
}

fn buildTcpSynFrameFrom(src_port: u16, dst_addr: ipv4.Address, dst_port: u16, out: *[spore_net.max_frame_len]u8) []const u8 {
    const tcp_len = tcp_wire.emit(.{
        .src_port = src_port,
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

fn expectSynReset(frame: []const u8, dst_addr: ipv4.Address, dst_port: u16) !void {
    const eth = try ethernet.parse(frame);
    try std.testing.expectEqualSlices(u8, &spore_net.guest_mac, &eth.dst_addr);
    try std.testing.expectEqualSlices(u8, &spore_net.gateway_mac, &eth.src_addr);
    const ip_data = try ethernet.payload(frame);
    try std.testing.expect(ipv4.verifyChecksum(ip_data[0..ipv4.HEADER_LEN]));
    const ip_repr = try ipv4.parse(ip_data);
    try std.testing.expectEqualSlices(u8, &dst_addr, &ip_repr.src_addr);
    try std.testing.expectEqualSlices(u8, &spore_net.guest_ipv4, &ip_repr.dst_addr);
    const segment = try ipv4.payloadSlice(ip_data);
    try std.testing.expect(tcp_wire.verifyChecksum(ip_repr.src_addr, ip_repr.dst_addr, segment));
    const reset = try tcp_wire.parse(segment);
    try std.testing.expect(reset.flags.rst and reset.flags.ack and !reset.flags.syn);
    try std.testing.expectEqual(dst_port, reset.src_port);
    try std.testing.expectEqual(@as(u16, 49152), reset.dst_port);
    // buildTcpSynFrame sends seq 1000; the SYN consumes one sequence number.
    try std.testing.expectEqual(@as(u32, 1001), reset.ack_number);
}

const GuestSockets = struct { tcp4_sockets: []*TcpSock };
const GuestStack = stack_mod.Stack(Device, GuestSockets);

/// A guest-side zmoltcp stack wired to a `Gateway` through its frame
/// interface, for tests that need a real guest TCP peer.
const TestGuest = struct {
    device: Device,
    sock: TcpSock,
    sock_ptrs: [1]*TcpSock,
    stack: GuestStack,
    rx_storage: [tcp_rx_buffer_len]u8,
    tx_storage: [tcp_tx_buffer_len]u8,

    fn init(self: *TestGuest, now: Instant) void {
        self.device = Device.init();
        self.sock = TcpSock.init(&self.rx_storage, &self.tx_storage);
        self.sock.ack_delay = null;
        self.sock_ptrs = .{&self.sock};
        self.stack = GuestStack.init(spore_net.guest_mac, .{ .tcp4_sockets = &self.sock_ptrs });
        self.stack.iface.v4.addIpAddr(.{ .address = spore_net.guest_ipv4, .prefix_len = 30 });
        _ = self.stack.iface.v4.routes.add(zmoltcp.iface.Route.newDefaultGateway(spore_net.gateway_ipv4));
        self.stack.iface.neighbor_cache.fill(spore_net.gateway_ipv4, spore_net.gateway_mac, now);
    }

    /// Moves frames between the guest and the gateway until both are idle.
    fn exchange(self: *TestGuest, gateway: *Gateway, now: Instant) void {
        var rounds: usize = 0;
        while (rounds < 32) : (rounds += 1) {
            _ = self.stack.poll(now, &self.device);
            var moved = false;
            while (self.device.dequeueTx()) |frame| {
                _ = gateway.receiveFrame(frame, now);
                moved = true;
            }
            gateway.service(now);
            while (gateway.dequeueFrame()) |frame| {
                self.device.enqueueRx(frame);
                moved = true;
            }
            if (!moved) return;
        }
    }

    fn deliverAll(guests: []TestGuest, gateway: *Gateway) !void {
        while (gateway.dequeueFrame()) |frame| {
            const ip_data = frame[ethernet.HEADER_LEN..];
            const segment = try ipv4.payloadSlice(ip_data);
            const header = try tcp_wire.parse(segment);
            const index = header.dst_port - 49152;
            try std.testing.expect(index < guests.len);
            guests[index].device.enqueueRx(frame);
        }
    }
};

/// One iteration of the netd host side: poll host sockets, then service.
fn pollHost(gateway: *Gateway, now: Instant) !void {
    var fds: [max_port_forwards + max_flows]std.posix.pollfd = undefined;
    const count = gateway.fillPollFds(&fds);
    _ = try std.posix.poll(fds[0..count], 1_000);
    gateway.servicePoll(fds[0..count]);
    gateway.service(now);
}

fn listenUnix(path: [:0]const u8) !std.c.fd_t {
    _ = std.c.unlink(path.ptr);
    const listener = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (listener < 0) return error.TestUnexpectedResult;
    errdefer _ = std.c.close(listener);
    var sockaddr = std.mem.zeroInit(std.c.sockaddr.un, .{});
    sockaddr.family = std.c.AF.UNIX;
    @memcpy(sockaddr.path[0..path.len], path);
    if (std.c.bind(listener, @ptrCast(&sockaddr), @sizeOf(std.c.sockaddr.un)) != 0) return error.TestUnexpectedResult;
    if (std.c.listen(listener, 4) != 0) return error.TestUnexpectedResult;
    return listener;
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
    var policy = try spore_net_policy.Runtime.init(.{ .egress = .unrestricted });
    var gateway: Gateway = undefined;
    try gateway.init(&policy, &.{});
    defer gateway.deinit();

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
        try expectSynReset(gateway.dequeueFrame() orelse return error.TestUnexpectedResult, addr, 80);
        try std.testing.expectEqual(@as(?[]const u8, null), gateway.dequeueFrame());
    }

    try std.testing.expectEqual(blocked.len, gateway.stats.denied);
    try std.testing.expectEqual(@as(usize, 0), gateway.stats.connect_attempts);
}

test "spore-netd TCP resets a guest connection to a denied destination" {
    var policy = try spore_net_policy.Runtime.init(.{ .egress = .deny_all });
    var gateway: Gateway = undefined;
    try gateway.init(&policy, &.{});
    defer gateway.deinit();
    var guest: TestGuest = undefined;
    guest.init(Instant.fromMillis(1));

    try guest.sock.connect(.{ 93, 184, 216, 34 }, 443, spore_net.guest_ipv4, 49152);
    guest.exchange(&gateway, Instant.fromMillis(1));

    try std.testing.expectEqual(@as(usize, 1), gateway.stats.denied);
    try std.testing.expectEqual(tcp_socket.State.closed, guest.sock.getState());
}

test "spore-netd TCP admits parallel SYNs and resets excess connections" {
    var config = spore_net_policy.Config{ .egress = .unrestricted };
    try config.addBoundUnixService("metadata", "metadata.spore.internal", 80, "/tmp/sporevm-netd-missing-full-table.sock");
    var policy = try spore_net_policy.Runtime.init(config);
    var gateway: Gateway = undefined;
    try gateway.init(&policy, &.{});
    defer gateway.deinit();

    // Each SYN takes a flow slot; without a service pass none is reaped.
    var frame_buf: [spore_net.max_frame_len]u8 = undefined;
    var port: u16 = 0;
    while (port < max_flows) : (port += 1) {
        try std.testing.expect(gateway.receiveFrame(buildTcpSynFrameFrom(49152 + port, spore_net.gateway_ipv4, 80, &frame_buf), Instant.fromMillis(1)));
        while (gateway.dequeueFrame()) |_| {}
    }
    // A package manager's parallel fetches must not hit the old eight-flow cap.
    try std.testing.expect(gateway.stats.connect_attempts >= 64);
    try std.testing.expectEqual(@as(usize, 0), gateway.stats.flow_limit_drops);

    var guest: TestGuest = undefined;
    guest.init(Instant.fromMillis(1));
    try guest.sock.connect(spore_net.gateway_ipv4, 80, spore_net.guest_ipv4, 49152 + max_flows);
    guest.exchange(&gateway, Instant.fromMillis(1));
    try std.testing.expectEqual(@as(usize, 1), gateway.stats.flow_limit_drops);
    try std.testing.expectEqual(@as(usize, 0), gateway.stats.denied);
    try std.testing.expectEqual(tcp_socket.State.closed, guest.sock.getState());
}

test "spore-netd TCP routes bound service SYNs before gateway hard-floor denial" {
    var config = spore_net_policy.Config{ .egress = .unrestricted };
    try config.addBoundUnixService("metadata", "metadata.spore.internal", 80, "/tmp/sporevm-netd-missing-bound-service.sock");
    var policy = try spore_net_policy.Runtime.init(config);
    var gateway: Gateway = undefined;
    try gateway.init(&policy, &.{});
    defer gateway.deinit();

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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var config = spore_net_policy.Config{ .egress = .unrestricted };
    try config.addBindService(allocator, "metadata=unix:/tmp/metadata.sock");
    try std.testing.expectError(error.DuplicateBoundService, config.addBindService(allocator, "metadata:8080=unix:/tmp/metadata-2.sock"));
    try std.testing.expectError(error.DuplicateBoundService, config.addBindService(allocator, "cache=unix:/tmp/cache.sock"));
    try config.addBindService(allocator, "cache:8080=unix:/tmp/cache.sock");

    var policy = try spore_net_policy.Runtime.init(config);
    var gateway: Gateway = undefined;
    try gateway.init(&policy, &.{});
    defer gateway.deinit();

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
    const path_z = try std.fmt.bufPrintSentinel(&path_buf, "/tmp/sporevm-netd-unix-test-{d}.sock", .{std.c.getpid()}, 0);
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

test "spore-netd TCP applies poll results only to the flow that was polled" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/tmp/sporevm-netd-poll-test-{d}.sock", .{std.c.getpid()}, 0);
    const listener = try listenUnix(path);
    defer _ = std.c.close(listener);
    defer _ = std.c.unlink(path.ptr);

    var config = spore_net_policy.Config{ .egress = .unrestricted };
    try config.addBoundUnixService("first", "first.spore.internal", 80, path);
    try config.addBoundUnixService("second", "second.spore.internal", 8080, path);
    try config.addBoundUnixService("missing", "missing.spore.internal", 81, "/tmp/sporevm-netd-missing-poll-service.sock");
    var policy = try spore_net_policy.Runtime.init(config);
    var gateway: Gateway = undefined;
    try gateway.init(&policy, &.{});
    defer gateway.deinit();
    var guest: TestGuest = undefined;
    guest.init(Instant.fromMillis(1));

    // A failed flow takes the first slot and is reaped, leaving the guest's
    // connection in a later slot with a free slot before it.
    var frame_buf: [spore_net.max_frame_len]u8 = undefined;
    try std.testing.expect(gateway.receiveFrame(buildTcpSynFrame(spore_net.gateway_ipv4, 81, &frame_buf), Instant.fromMillis(1)));
    try guest.sock.connect(spore_net.gateway_ipv4, 80, spore_net.guest_ipv4, 49153);
    guest.exchange(&gateway, Instant.fromMillis(1));
    try std.testing.expectEqual(tcp_socket.State.established, guest.sock.getState());
    const host_peer = std.c.accept(listener, null, null);
    try std.testing.expect(host_peer >= 0);
    defer _ = std.c.close(host_peer);
    try std.testing.expectEqual(@as(isize, 1), std.c.send(host_peer, "x", 1, 0));

    var fds: [max_port_forwards + max_flows]std.posix.pollfd = undefined;
    const count = gateway.fillPollFds(&fds);
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(fds[0..count], 1_000));

    // A guest SYN handled between building and servicing the poll set opens
    // a new flow in the free slot ahead of the polled one.
    try std.testing.expect(gateway.receiveFrame(buildTcpSynFrame(spore_net.gateway_ipv4, 8080, &frame_buf), Instant.fromMillis(2)));
    gateway.servicePoll(fds[0..count]);
    guest.exchange(&gateway, Instant.fromMillis(2));

    // The polled flow read the host byte and relayed it to the guest.
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try guest.sock.recvSlice(&byte));
    try std.testing.expectEqualStrings("x", &byte);
}

test "spore-netd TCP delivers guest bytes sent after host EOF" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/tmp/sporevm-netd-eof-test-{d}.sock", .{std.c.getpid()}, 0);
    const listener = try listenUnix(path);
    defer _ = std.c.close(listener);
    defer _ = std.c.unlink(path.ptr);

    var config = spore_net_policy.Config{ .egress = .unrestricted };
    try config.addBoundUnixService("svc", "svc.spore.internal", 80, path);
    var policy = try spore_net_policy.Runtime.init(config);
    var gateway: Gateway = undefined;
    try gateway.init(&policy, &.{});
    defer gateway.deinit();
    var guest: TestGuest = undefined;
    guest.init(Instant.fromMillis(1));

    try guest.sock.connect(spore_net.gateway_ipv4, 80, spore_net.guest_ipv4, 49153);
    guest.exchange(&gateway, Instant.fromMillis(1));
    try std.testing.expectEqual(tcp_socket.State.established, guest.sock.getState());
    const host_peer = std.c.accept(listener, null, null);
    try std.testing.expect(host_peer >= 0);
    defer _ = std.c.close(host_peer);

    // The host half-closes before the guest has sent anything; the guest
    // sees the FIN but can still send.
    try std.testing.expectEqual(@as(c_int, 0), std.c.shutdown(host_peer, std.c.SHUT.WR));
    try pollHost(&gateway, Instant.fromMillis(2));
    guest.exchange(&gateway, Instant.fromMillis(2));
    try std.testing.expectEqual(tcp_socket.State.close_wait, guest.sock.getState());

    try std.testing.expectEqual(@as(usize, 4), try guest.sock.sendSlice("ping"));
    guest.exchange(&gateway, Instant.fromMillis(3));
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 4), std.c.recv(host_peer, &buf, buf.len, std.c.MSG.DONTWAIT));
    try std.testing.expectEqualStrings("ping", buf[0..4]);

    // Once the guest closes too, the gateway closes the host socket.
    guest.sock.close();
    guest.exchange(&gateway, Instant.fromMillis(4));
    try std.testing.expectEqual(@as(isize, 0), std.c.recv(host_peer, &buf, buf.len, std.c.MSG.DONTWAIT));
}

test "spore-netd TCP stops polling a host socket while the guest cannot take more" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/tmp/sporevm-netd-backpressure-test-{d}.sock", .{std.c.getpid()}, 0);
    const listener = try listenUnix(path);
    defer _ = std.c.close(listener);
    defer _ = std.c.unlink(path.ptr);

    var config = spore_net_policy.Config{ .egress = .unrestricted };
    try config.addBoundUnixService("svc", "svc.spore.internal", 80, path);
    var policy = try spore_net_policy.Runtime.init(config);
    var gateway: Gateway = undefined;
    try gateway.init(&policy, &.{});
    defer gateway.deinit();
    var guest: TestGuest = undefined;
    guest.init(Instant.fromMillis(1));

    try guest.sock.connect(spore_net.gateway_ipv4, 80, spore_net.guest_ipv4, 49153);
    guest.exchange(&gateway, Instant.fromMillis(1));
    try std.testing.expectEqual(tcp_socket.State.established, guest.sock.getState());
    const host_peer = std.c.accept(listener, null, null);
    try std.testing.expect(host_peer >= 0);
    defer _ = std.c.close(host_peer);

    // The host keeps writing while the guest reads nothing, until the guest
    // window and every gateway buffer are full and the host fd leaves the
    // poll set even though it still has bytes to read.
    try std.testing.expect(setNonBlocking(host_peer));
    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 'x');
    var written: usize = 0;
    var fds: [max_port_forwards + max_flows]std.posix.pollfd = undefined;
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        while (written < 1024 * 1024) {
            const n = std.c.send(host_peer, &chunk, chunk.len, 0);
            if (n <= 0) break;
            written += @intCast(n);
        }
        const count = gateway.fillPollFds(&fds);
        if (count == 0) break;
        _ = try std.posix.poll(fds[0..count], 1_000);
        gateway.servicePoll(fds[0..count]);
        guest.exchange(&gateway, Instant.fromMillis(2));
    }
    try std.testing.expect(rounds < 64);

    // Once the guest reads, the gateway forwards what it has buffered.
    var drained: [tcp_rx_buffer_len]u8 = undefined;
    try std.testing.expect(try guest.sock.recvSlice(&drained) > 0);
    guest.exchange(&gateway, Instant.fromMillis(3));
    try std.testing.expect(try guest.sock.recvSlice(&drained) > 0);
}

test "spore-netd TCP delivers concurrent reply bursts without retransmission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/tmp/sporevm-netd-burst-{s}.sock", .{tmp.sub_path}, 0);
    const listener = try listenUnix(path);
    defer _ = std.c.close(listener);
    defer _ = std.c.unlink(path.ptr);

    var config = spore_net_policy.Config{ .egress = .unrestricted };
    try config.addBoundUnixService("svc", "svc.spore.internal", 80, path);
    var policy = try spore_net_policy.Runtime.init(config);
    var gateway: Gateway = undefined;
    try gateway.init(&policy, &.{});
    defer gateway.deinit();

    var guests: [8]TestGuest = undefined;
    var peers: [8]std.c.fd_t = @splat(-1);
    defer for (peers) |fd| {
        if (fd >= 0) _ = std.c.close(fd);
    };
    for (&guests, 0..) |*guest, i| {
        guest.init(Instant.fromMillis(1));
        try guest.sock.connect(spore_net.gateway_ipv4, 80, spore_net.guest_ipv4, @intCast(49152 + i));
        guest.exchange(&gateway, Instant.fromMillis(1));
        try std.testing.expectEqual(tcp_socket.State.established, guest.sock.getState());
        peers[i] = std.c.accept(listener, null, null);
        try std.testing.expect(peers[i] >= 0);
    }

    // Two host I/O passes with eight 16 KiB replies exceed even the enlarged
    // frame queue without a burst limit. Fixed time rules out retransmission.
    var chunk: [16384]u8 = undefined;
    for (peers, 0..) |fd, i| {
        // macOS defaults to an 8 KiB Unix send buffer. Queue the whole reply
        // before the gateway reads, and fail rather than block on a short write.
        const send_buffer: c_int = chunk.len;
        try std.testing.expectEqual(@as(c_int, 0), std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.SNDBUF, &send_buffer, @sizeOf(c_int)));
        try std.testing.expect(setNonBlocking(fd));
        @memset(&chunk, @intCast('A' + i));
        try std.testing.expectEqual(@as(isize, chunk.len), std.c.send(fd, &chunk, chunk.len, 0));
    }
    const now = Instant.fromMillis(2);
    try pollHost(&gateway, now);
    try pollHost(&gateway, now);
    var received: [8]usize = @splat(0);
    for (0..16) |_| {
        try TestGuest.deliverAll(&guests, &gateway);
        for (&guests, 0..) |*guest, i| {
            _ = guest.stack.poll(now, &guest.device);
            const n = try guest.sock.recvSlice(&chunk);
            for (chunk[0..n]) |byte| try std.testing.expectEqual(@as(u8, @intCast('A' + i)), byte);
            received[i] += n;
            while (guest.device.dequeueTx()) |frame| {
                try std.testing.expect(gateway.receiveFrame(frame, now));
                try TestGuest.deliverAll(&guests, &gateway);
            }
        }
        gateway.service(now);
    }
    for (received) |count| try std.testing.expectEqual(@as(usize, chunk.len), count);
    try std.testing.expectEqual(@as(usize, 0), gateway.stats.output_drops);
}

test "spore-netd TCP enforces exact learned host ports" {
    var config = spore_net_policy.Config{ .egress = .deny_all };
    try config.addExactHostPorts("github.com", &.{443});
    var policy = try spore_net_policy.Runtime.init(config);

    var query_buf: [512]u8 = undefined;
    const query = spore_net_policy.testDnsQuery(0x1234, "github.com", &query_buf);
    var response_buf: [512]u8 = undefined;
    const response = spore_net_policy.testDnsResponse(query, "*", &.{.{ 203, 0, 113, 10 }}, &response_buf);
    try std.testing.expectEqual(@as(usize, 1), policy.noteDnsResponse(query, response));

    var gateway: Gateway = undefined;
    try gateway.init(&policy, &.{});
    defer gateway.deinit();
    try std.testing.expect(gateway.targetForRequest(testForwardRequest(.{ 203, 0, 113, 10 }, 443)) != null);
    try std.testing.expect(gateway.targetForRequest(testForwardRequest(.{ 203, 0, 113, 10 }, 80)) == null);
}

test "spore-netd TCP routes configured bound service ports to Unix sockets" {
    var config = spore_net_policy.Config{ .egress = .unrestricted };
    try config.addBoundUnixService("cleanroom-gateway", "gateway.cleanroom.internal", 8170, "/tmp/missing-cleanroom.sock");
    var policy = try spore_net_policy.Runtime.init(config);
    var gateway: Gateway = undefined;
    try gateway.init(&policy, &.{});
    defer gateway.deinit();

    const target = gateway.targetForRequest(testForwardRequest(spore_net.gateway_ipv4, 8170)) orelse return error.TestUnexpectedResult;
    switch (target) {
        .bound_unix => |service| try std.testing.expectEqualStrings("cleanroom-gateway", service.name),
        .tcp => return error.TestUnexpectedResult,
    }
    try std.testing.expect(gateway.targetForRequest(testForwardRequest(spore_net.gateway_ipv4, 8171)) == null);
}

/// Builds checksum-correct guest TCP frames from fuzz input, so the stack
/// does not drop them before they reach the gateway's policy and flows.
/// Each frame takes a 21-byte header (flags, destination selector and
/// address, ports, sequence and acknowledgment numbers, window, payload
/// length) followed by its payload.
fn fuzzGatewayReceiveFrame(_: void, s: *std.testing.Smith) !void {
    var config = spore_net_policy.Config{ .egress = .deny_all };
    try config.addBoundUnixService("metadata", "metadata.spore.internal", 80, "/tmp/sporevm-netd-fuzz-missing.sock");
    var policy = try spore_net_policy.Runtime.init(config);
    var gateway: Gateway = undefined;
    try gateway.init(&policy, &.{});
    defer gateway.deinit();

    var input: [4096]u8 = undefined;
    const len = @min(s.slice(&input), input.len);
    const header_len = 21;
    var offset: usize = 0;
    var now_ms: i64 = 0;
    while (offset + header_len <= len) {
        const header = input[offset..][0..header_len];
        offset += header_len;
        const payload_len = @min(header[20], len - offset);
        const payload = input[offset..][0..payload_len];
        offset += payload_len;

        const dst_addr: ipv4.Address = if ((header[1] & 1) != 0) spore_net.gateway_ipv4 else header[2..6].*;
        var frame_buf: [spore_net.max_frame_len]u8 = undefined;
        const tcp_start = ethernet.HEADER_LEN + ipv4.HEADER_LEN;
        const tcp_header_len = tcp_wire.emit(.{
            .src_port = std.mem.readInt(u16, header[8..10], .big),
            .dst_port = std.mem.readInt(u16, header[6..8], .big),
            .seq_number = std.mem.readInt(u32, header[10..14], .big),
            .ack_number = std.mem.readInt(u32, header[14..18], .big),
            .data_offset = 5,
            .flags = .{
                .fin = (header[0] & 0x01) != 0,
                .syn = (header[0] & 0x02) != 0,
                .rst = (header[0] & 0x04) != 0,
                .psh = (header[0] & 0x08) != 0,
                .ack = (header[0] & 0x10) != 0,
                .urg = (header[0] & 0x20) != 0,
            },
            .window_size = std.mem.readInt(u16, header[18..20], .big),
            .checksum = 0,
            .urgent_pointer = 0,
        }, frame_buf[tcp_start..]) catch unreachable;
        @memcpy(frame_buf[tcp_start + tcp_header_len ..][0..payload.len], payload);
        const tcp_len = tcp_header_len + payload.len;
        _ = ethernet.emit(.{
            .dst_addr = spore_net.gateway_mac,
            .src_addr = spore_net.guest_mac,
            .ethertype = .ipv4,
        }, frame_buf[0..ethernet.HEADER_LEN]) catch unreachable;
        _ = ipv4.emit(.{
            .version = 4,
            .ihl = 5,
            .dscp_ecn = 0,
            .total_length = @intCast(ipv4.HEADER_LEN + tcp_len),
            .identification = 0,
            .dont_fragment = true,
            .more_fragments = false,
            .fragment_offset = 0,
            .ttl = 64,
            .protocol = .tcp,
            .checksum = 0,
            .src_addr = spore_net.guest_ipv4,
            .dst_addr = dst_addr,
        }, frame_buf[ethernet.HEADER_LEN..][0..ipv4.HEADER_LEN]) catch unreachable;
        const tcp = frame_buf[tcp_start..][0..tcp_len];
        std.mem.writeInt(u16, tcp[16..18], tcp_wire.computeChecksum(spore_net.guest_ipv4, dst_addr, tcp), .big);

        const now = Instant.fromMillis(now_ms);
        _ = gateway.receiveFrame(frame_buf[0 .. tcp_start + tcp_len], now);
        gateway.service(now);
        while (gateway.dequeueFrame()) |_| {}
        now_ms += 50;
    }
}

test "fuzz spore-netd TCP gateway guest frames" {
    // A SYN to the bound service, its ACK with data, then a denied SYN.
    try std.testing.fuzz({}, fuzzGatewayReceiveFrame, .{ .corpus = &.{
        fuzz_support.sliceSeed("\x02\x01\x00\x00\x00\x00\x00\x50\xc0\x00\x00\x00\x03\xe8\x00\x00\x00\x00\x04\x00\x00" ++
            "\x18\x01\x00\x00\x00\x00\x00\x50\xc0\x00\x00\x00\x03\xe9\x00\x00\x00\x01\x04\x00\x04ping" ++
            "\x02\x00\x5d\xb8\xd8\x22\x01\xbb\xc0\x01\x00\x00\x07\xd0\x00\x00\x00\x00\x04\x00\x00"),
    } });
}

fn fuzzGuestTcpFrameClassifier(_: void, s: *std.testing.Smith) !void {
    var bytes: [spore_net.max_frame_len]u8 = undefined;
    const len = @min(s.slice(&bytes), bytes.len);
    _ = isGuestTcpFrame(bytes[0..len]);
}

test "fuzz spore-netd TCP Ethernet and IPv4 frame classification" {
    try std.testing.fuzz({}, fuzzGuestTcpFrameClassifier, .{});
}
