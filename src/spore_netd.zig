//! Minimal `spore-netd` helper.
//!
//! The helper owns a bounded Ethernet frame stream, ARP replies for the fixed
//! gateway address, narrow DNS proxying, and the first outbound TCP proxy path.

const std = @import("std");
const Ctx = @import("cli.zig").Ctx;
const zmoltcp = @import("zmoltcp");
const Io = std.Io;

const spore_net = @import("spore_net.zig");
const spore_net_policy = @import("spore_net_policy.zig");
const spore_netd_tcp = @import("spore_netd_tcp.zig");

pub const max_frame_len = spore_net.max_frame_len;
pub const frame_header_len = 4;

pub const guest_mac = spore_net.guest_mac;
pub const gateway_mac = spore_net.gateway_mac;
pub const guest_ipv4 = spore_net.guest_ipv4;
pub const gateway_ipv4 = spore_net.gateway_ipv4;

const ethernet_header_len = 14;
const arp_packet_len = 28;
const arp_frame_len = ethernet_header_len + arp_packet_len;
const ipv4_header_min_len = 20;
const udp_header_len = 8;
const dns_header_len = 12;
const dns_type_a: u16 = 1;
const dns_type_aaaa: u16 = 28;
const dns_class_in: u16 = 1;
const ether_type_arp: u16 = 0x0806;
const ether_type_ipv4: u16 = 0x0800;
const arp_hardware_ethernet: u16 = 1;
const arp_op_request: u16 = 1;
const arp_op_reply: u16 = 2;
const udp_protocol: u8 = 17;
const dns_port: u16 = 53;
const ipv4_default_ttl: u8 = 64;
const dns_forward_timeout_ms = 1_000;
const max_dns_payload_len = max_frame_len - ethernet_header_len - ipv4_header_min_len - udp_header_len;

const fallback_dns_ipv4: [4]u8 = .{ 1, 1, 1, 1 };

pub const netd_usage =
    \\Usage:
    \\  spore netd --stdio --policy JSON
    \\
    \\Internal helper for SporeVM-managed networking.
    \\
;

pub const FrameIoError = error{
    EndOfStream,
    FrameTooLarge,
    ShortWrite,
    IoFailed,
};

const Instant = zmoltcp.time.Instant;
const Duration = zmoltcp.time.Duration;

const max_pending_dns = 64;

const PendingDns = struct {
    fd: std.c.fd_t = -1,
    sender_mac: [6]u8 = undefined,
    sender_ipv4: [4]u8 = undefined,
    sender_port: u16 = 0,
    query: [max_dns_payload_len]u8 = undefined,
    query_len: usize = 0,
    question_end: usize = 0,
    deadline: Instant = Instant.ZERO,
    /// Index in the last `fillPollFds` set; null for queries started after it.
    poll_index: ?usize = null,

    fn request(self: *const PendingDns) DnsUdpRequest {
        return .{
            .sender_mac = self.sender_mac,
            .sender_ipv4 = self.sender_ipv4,
            .sender_port = self.sender_port,
            .payload = self.query[0..self.query_len],
            .question_end = self.question_end,
        };
    }

    fn close(self: *PendingDns) void {
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.fd = -1;
        self.poll_index = null;
    }
};

/// Guest DNS handling. Local answers are immediate; forwarded queries each
/// get a connected UDP socket to the host resolver in the netd poll set, so
/// a slow resolver never stalls other guest traffic. A query without a valid
/// answer by its deadline, or arriving while every slot is in use, gets
/// SERVFAIL rather than leaving the guest waiting for a resolver timeout.
const DnsProxy = struct {
    server_ipv4: [4]u8,
    server_port: u16 = dns_port,
    pending: [max_pending_dns]PendingDns = @splat(.{}),

    const Step = union(enum) {
        not_dns,
        reply: []const u8,
        pending,
    };

    fn deinit(self: *DnsProxy) void {
        for (&self.pending) |*pending| pending.close();
    }

    fn receiveFrame(self: *DnsProxy, frame: []const u8, policy: *spore_net_policy.Runtime, now: Instant, out: *[max_frame_len]u8) Step {
        const request = parseDnsUdpRequest(frame) orelse return .not_dns;
        const question = dnsQuestionTypeClass(request.payload, request.question_end) orelse return .not_dns;
        var response_buf: [max_dns_payload_len]u8 = undefined;
        const dns_payload = if (policy.boundServiceForDnsQuery(request.payload, dns_header_len)) |_|
            if (question.qtype == dns_type_a and question.qclass == dns_class_in)
                buildBoundServiceDnsResponse(request.payload, request.question_end, &response_buf)
            else
                buildDnsNoData(request.payload, request.question_end, &response_buf)
        else switch (policy.dnsForwardDecision(request.payload, dns_header_len, question.qtype, question.qclass)) {
            .forward => switch (self.startForward(request, now)) {
                .started => return .pending,
                .full, .failed => buildDnsServfail(request.payload, request.question_end, &response_buf),
            },
            .no_data => buildDnsNoData(request.payload, request.question_end, &response_buf),
            .refuse => buildDnsRefused(request.payload, request.question_end, &response_buf),
        };
        return .{ .reply = buildDnsUdpFrame(request, dns_payload, out) orelse return .not_dns };
    }

    fn startForward(self: *DnsProxy, request: DnsUdpRequest, now: Instant) enum { started, full, failed } {
        const pending = for (&self.pending) |*pending| {
            if (pending.fd < 0) break pending;
        } else return .full;
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.DGRAM, std.c.IPPROTO.UDP);
        if (fd < 0) return .failed;
        var addr = std.c.sockaddr.in{
            .port = std.mem.nativeToBig(u16, self.server_port),
            .addr = @bitCast(self.server_ipv4),
        };
        const sent = if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) == 0)
            std.c.send(fd, request.payload.ptr, request.payload.len, std.c.MSG.DONTWAIT)
        else
            -1;
        if (sent < 0 or @as(usize, @intCast(sent)) != request.payload.len) {
            _ = std.c.close(fd);
            return .failed;
        }
        pending.* = .{
            .fd = fd,
            .sender_mac = request.sender_mac,
            .sender_ipv4 = request.sender_ipv4,
            .sender_port = request.sender_port,
            .query_len = request.payload.len,
            .question_end = request.question_end,
            .deadline = now.add(Duration.fromMillis(dns_forward_timeout_ms)),
        };
        @memcpy(pending.query[0..request.payload.len], request.payload);
        return .started;
    }

    fn fillPollFds(self: *DnsProxy, fds: []std.posix.pollfd) usize {
        var count: usize = 0;
        for (&self.pending) |*pending| {
            pending.poll_index = null;
            if (pending.fd < 0 or count >= fds.len) continue;
            fds[count] = .{ .fd = pending.fd, .events = std.c.POLL.IN, .revents = 0 };
            pending.poll_index = count;
            count += 1;
        }
        return count;
    }

    /// Returns the next guest reply resolved by the poll results in `fds`
    /// (from `fillPollFds`) or by a passed deadline; call until null.
    fn nextReply(self: *DnsProxy, fds: []const std.posix.pollfd, policy: *spore_net_policy.Runtime, now: Instant, out: *[max_frame_len]u8) ?[]const u8 {
        for (&self.pending) |*pending| {
            if (pending.fd < 0) continue;
            const ready = if (pending.poll_index) |index|
                index < fds.len and fds[index].fd == pending.fd and fds[index].revents != 0
            else
                false;
            pending.poll_index = null;
            const request = pending.request();
            var response_buf: [max_dns_payload_len]u8 = undefined;
            if (ready) {
                const n = std.c.recv(pending.fd, &response_buf, response_buf.len, std.c.MSG.DONTWAIT);
                if (n < 0 and std.c.errno(n) == .AGAIN) continue;
                pending.close();
                const response = if (n > 0) response_buf[0..@intCast(n)] else response_buf[0..0];
                if (validDnsResponse(request.payload, response)) {
                    _ = policy.noteDnsResponse(request.payload, response);
                    return buildDnsUdpFrame(request, response, out) orelse continue;
                }
            } else if (now.greaterThanOrEqual(pending.deadline)) {
                pending.close();
            } else continue;
            var servfail_buf: [max_dns_payload_len]u8 = undefined;
            return buildDnsUdpFrame(request, buildDnsServfail(request.payload, request.question_end, &servfail_buf), out) orelse continue;
        }
        return null;
    }

    fn nextPollTimeoutMs(self: *const DnsProxy, now: Instant) i32 {
        var next: ?Instant = null;
        for (&self.pending) |*pending| {
            if (pending.fd < 0) continue;
            if (next == null or pending.deadline.lessThan(next.?)) next = pending.deadline;
        }
        const deadline = next orelse return -1;
        if (!deadline.greaterThanOrEqual(now)) return 0;
        const micros = deadline.diff(now).totalMicros();
        return @intCast(@min(@divTrunc(micros + 999, 1000), dns_forward_timeout_ms));
    }
};

pub fn cli(ctx: *const Ctx, args: []const []const u8) !void {
    const init = ctx.init;
    const config = parseCliArgs(init.arena.allocator(), args);
    var policy = spore_net_policy.Runtime.init(config) catch |err| {
        std.debug.print("spore netd: invalid network policy: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };

    var dns = DnsProxy{
        .server_ipv4 = resolveHostDnsServer(init.io, init.arena.allocator()),
    };
    defer dns.deinit();
    var tcp_gateway: spore_netd_tcp.Gateway = undefined;
    tcp_gateway.init(&policy, config.portForwardSlice()) catch |err| {
        std.debug.print("spore netd: forward setup failed: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    defer tcp_gateway.deinit();
    tcp_gateway.emit_events = true;
    try writeAllFd(2, "ready\n");
    var in_buf: [max_frame_len]u8 = undefined;
    var reply_buf: [max_frame_len]u8 = undefined;
    while (true) {
        const now = tcpNow();
        var fds: [1 + spore_netd_tcp.max_port_forwards + spore_netd_tcp.max_flows + max_pending_dns]std.posix.pollfd = undefined;
        fds[0] = .{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 };
        const tcp_end = 1 + tcp_gateway.fillPollFds(fds[1..]);
        const fd_count = tcp_end + dns.fillPollFds(fds[tcp_end..]);
        const timeout_ms = minPollTimeout(tcp_gateway.nextPollTimeoutMs(now), dns.nextPollTimeoutMs(now));
        _ = std.posix.poll(fds[0..fd_count], timeout_ms) catch return error.IoFailed;

        const after_poll = tcpNow();
        if ((fds[0].revents & (std.c.POLL.ERR | std.c.POLL.NVAL)) != 0) return error.IoFailed;
        if ((fds[0].revents & (std.c.POLL.IN | std.c.POLL.HUP)) != 0) {
            const frame = readFrameFd(0, &in_buf) catch |err| switch (err) {
                error.EndOfStream => return,
                else => |e| return e,
            };
            std.log.debug("spore-netd rx frame len={d}", .{frame.len});
            if (arpReply(frame, &reply_buf)) |reply| {
                try writeFrameFd(1, reply);
            } else switch (dns.receiveFrame(frame, &policy, after_poll, &reply_buf)) {
                .reply => |reply| try writeFrameFd(1, reply),
                .pending => {},
                .not_dns => if (!tcp_gateway.receiveFrame(frame, after_poll)) {
                    std.log.debug("spore-netd dropped unsupported frame len={d}", .{frame.len});
                },
            }
        }

        tcp_gateway.servicePoll(fds[1..tcp_end]);
        while (dns.nextReply(fds[tcp_end..fd_count], &policy, after_poll, &reply_buf)) |reply| {
            try writeFrameFd(1, reply);
        }
        tcp_gateway.service(after_poll);
        try drainTcpGateway(&tcp_gateway);
    }
}

fn minPollTimeout(a: i32, b: i32) i32 {
    if (a < 0) return b;
    if (b < 0) return a;
    return @min(a, b);
}

fn parseCliArgs(allocator: std.mem.Allocator, args: []const []const u8) spore_net_policy.Config {
    var policy: ?spore_net_policy.Config = null;
    var stdio = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--stdio")) {
            stdio = true;
        } else if (std.mem.eql(u8, args[i], "--policy")) {
            const raw = takeValue(args, &i, args[i]);
            policy = spore_net_policy.parseArg(allocator, raw) catch |err| {
                std.debug.print("spore netd: invalid --policy: {s}\n", .{@errorName(err)});
                std.process.exit(2);
            };
        } else {
            std.debug.print("unknown netd argument: {s}\n{s}", .{ args[i], netd_usage });
            std.process.exit(2);
        }
    }
    if (!stdio or policy == null) {
        std.debug.print("{s}", .{netd_usage});
        std.process.exit(2);
    }
    return policy.?;
}

fn takeValue(args: []const []const u8, i: *usize, flag: []const u8) []const u8 {
    if (i.* + 1 >= args.len) {
        std.debug.print("{s} requires a value\n", .{flag});
        std.process.exit(2);
    }
    i.* += 1;
    return args[i.*];
}

fn drainTcpGateway(gateway: *spore_netd_tcp.Gateway) FrameIoError!void {
    while (gateway.dequeueFrame()) |frame| {
        try writeFrameFd(1, frame);
    }
}

fn tcpNow() zmoltcp.time.Instant {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return zmoltcp.time.Instant.ZERO;
    const micros = @as(i64, @intCast(ts.sec)) * 1_000_000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000);
    return zmoltcp.time.Instant.fromMicros(micros);
}

pub fn writeFrameFd(fd: std.c.fd_t, frame: []const u8) FrameIoError!void {
    if (frame.len > max_frame_len) return error.FrameTooLarge;
    var header: [frame_header_len]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @intCast(frame.len), .little);
    try writeAllFd(fd, &header);
    try writeAllFd(fd, frame);
}

pub fn readFrameFd(fd: std.c.fd_t, out: *[max_frame_len]u8) FrameIoError![]const u8 {
    var header: [frame_header_len]u8 = undefined;
    try readExactFd(fd, &header);
    const len = try decodeFrameLen(header[0..frame_header_len]);
    try readExactFd(fd, out[0..len]);
    return out[0..len];
}

pub fn arpReply(frame: []const u8, out: *[max_frame_len]u8) ?[]const u8 {
    const request = parseArpRequest(frame) orelse return null;
    const reply = out[0..arp_frame_len];
    @memcpy(reply[0..6], &request.sender_mac);
    @memcpy(reply[6..12], &gateway_mac);
    std.mem.writeInt(u16, reply[12..14], ether_type_arp, .big);

    std.mem.writeInt(u16, reply[14..16], arp_hardware_ethernet, .big);
    std.mem.writeInt(u16, reply[16..18], ether_type_ipv4, .big);
    reply[18] = 6;
    reply[19] = 4;
    std.mem.writeInt(u16, reply[20..22], arp_op_reply, .big);
    @memcpy(reply[22..28], &gateway_mac);
    @memcpy(reply[28..32], &gateway_ipv4);
    @memcpy(reply[32..38], &request.sender_mac);
    @memcpy(reply[38..42], &request.sender_ipv4);
    return reply;
}

const DnsUdpRequest = struct {
    sender_mac: [6]u8,
    sender_ipv4: [4]u8,
    sender_port: u16,
    payload: []const u8,
    question_end: usize,
};

const DnsQuestion = struct {
    qtype: u16,
    qclass: u16,
};

fn dnsQuestionTypeClass(query: []const u8, question_end: usize) ?DnsQuestion {
    if (question_end < dns_header_len + 4 or question_end > query.len) return null;
    return .{
        .qtype = std.mem.readInt(u16, query[question_end - 4 ..][0..2], .big),
        .qclass = std.mem.readInt(u16, query[question_end - 2 ..][0..2], .big),
    };
}

fn buildBoundServiceDnsResponse(query: []const u8, question_end: usize, out: *[max_dns_payload_len]u8) []const u8 {
    const answer_len = 2 + 2 + 2 + 4 + 2 + 4;
    const len = question_end + answer_len;
    if (len > out.len) return buildDnsServfail(query, question_end, out);
    @memcpy(out[0..question_end], query[0..question_end]);
    var flags = std.mem.readInt(u16, query[2..4], .big);
    flags &= 0x0100;
    flags |= 0x8000 | 0x0080;
    std.mem.writeInt(u16, out[2..4], flags, .big);
    std.mem.writeInt(u16, out[4..6], 1, .big);
    std.mem.writeInt(u16, out[6..8], 1, .big);
    std.mem.writeInt(u16, out[8..10], 0, .big);
    std.mem.writeInt(u16, out[10..12], 0, .big);
    var pos = question_end;
    out[pos] = 0xc0;
    out[pos + 1] = dns_header_len;
    pos += 2;
    std.mem.writeInt(u16, out[pos..][0..2], 1, .big);
    pos += 2;
    std.mem.writeInt(u16, out[pos..][0..2], 1, .big);
    pos += 2;
    std.mem.writeInt(u32, out[pos..][0..4], 60, .big);
    pos += 4;
    std.mem.writeInt(u16, out[pos..][0..2], 4, .big);
    pos += 2;
    @memcpy(out[pos..][0..4], &gateway_ipv4);
    pos += 4;
    return out[0..pos];
}

fn parseDnsUdpRequest(frame: []const u8) ?DnsUdpRequest {
    if (frame.len < ethernet_header_len + ipv4_header_min_len + udp_header_len + dns_header_len) return null;
    if (!std.mem.eql(u8, frame[0..6], &gateway_mac)) return null;
    if (std.mem.readInt(u16, frame[12..14], .big) != ether_type_ipv4) return null;

    const ip = frame[ethernet_header_len..];
    const version_ihl = ip[0];
    if (version_ihl >> 4 != 4) return null;
    const ip_header_len: usize = @as(usize, version_ihl & 0x0f) * 4;
    if (ip_header_len < ipv4_header_min_len) return null;
    if (ip.len < ip_header_len + udp_header_len) return null;

    const total_len = std.mem.readInt(u16, ip[2..4], .big);
    if (total_len < ip_header_len + udp_header_len) return null;
    if (total_len > ip.len) return null;
    const packet = ip[0..total_len];
    const ip_header = packet[0..ip_header_len];
    if (ipv4Checksum(ip_header) != 0) return null;
    const flags_fragment = std.mem.readInt(u16, ip[6..8], .big);
    if ((flags_fragment & 0x3fff) != 0) return null;
    if (ip[9] != udp_protocol) return null;
    if (!std.mem.eql(u8, ip[12..16], &guest_ipv4)) return null;
    if (!std.mem.eql(u8, ip[16..20], &gateway_ipv4)) return null;

    const udp = packet[ip_header_len..];
    const sender_port = std.mem.readInt(u16, udp[0..2], .big);
    if (std.mem.readInt(u16, udp[2..4], .big) != dns_port) return null;
    const udp_len = std.mem.readInt(u16, udp[4..6], .big);
    if (udp_len < udp_header_len) return null;
    if (udp_len > udp.len) return null;
    const dns_payload = udp[udp_header_len..udp_len];
    const question_end = validateDnsQuery(dns_payload) orelse return null;

    var sender_mac: [6]u8 = undefined;
    var sender_ipv4: [4]u8 = undefined;
    @memcpy(&sender_mac, frame[6..12]);
    @memcpy(&sender_ipv4, ip[12..16]);
    return .{
        .sender_mac = sender_mac,
        .sender_ipv4 = sender_ipv4,
        .sender_port = sender_port,
        .payload = dns_payload,
        .question_end = question_end,
    };
}

fn validateDnsQuery(packet: []const u8) ?usize {
    if (packet.len < dns_header_len) return null;
    const flags = std.mem.readInt(u16, packet[2..4], .big);
    if ((flags & 0x8000) != 0) return null;
    const qdcount = std.mem.readInt(u16, packet[4..6], .big);
    if (qdcount != 1) return null;
    const name_end = spore_net.skipDnsName(packet, dns_header_len) orelse return null;
    if (name_end + 4 > packet.len) return null;
    return name_end + 4;
}

fn validDnsResponse(query: []const u8, response: []const u8) bool {
    if (query.len < dns_header_len or response.len < dns_header_len) return false;
    if (!std.mem.eql(u8, query[0..2], response[0..2])) return false;
    const flags = std.mem.readInt(u16, response[2..4], .big);
    return (flags & 0x8000) != 0;
}

fn buildDnsServfail(query: []const u8, question_end: usize, out: *[max_dns_payload_len]u8) []const u8 {
    return buildDnsEmptyResponse(query, question_end, out, 2);
}

fn buildDnsRefused(query: []const u8, question_end: usize, out: *[max_dns_payload_len]u8) []const u8 {
    return buildDnsEmptyResponse(query, question_end, out, 5);
}

fn buildDnsNoData(query: []const u8, question_end: usize, out: *[max_dns_payload_len]u8) []const u8 {
    return buildDnsEmptyResponse(query, question_end, out, 0);
}

fn buildDnsEmptyResponse(query: []const u8, question_end: usize, out: *[max_dns_payload_len]u8, rcode: u16) []const u8 {
    const len = @min(question_end, out.len);
    @memcpy(out[0..len], query[0..len]);
    var flags = std.mem.readInt(u16, query[2..4], .big);
    flags &= 0x0100;
    flags |= 0x8000 | 0x0080 | (rcode & 0x000f);
    std.mem.writeInt(u16, out[2..4], flags, .big);
    std.mem.writeInt(u16, out[4..6], 1, .big);
    std.mem.writeInt(u16, out[6..8], 0, .big);
    std.mem.writeInt(u16, out[8..10], 0, .big);
    std.mem.writeInt(u16, out[10..12], 0, .big);
    return out[0..len];
}

fn buildDnsUdpFrame(request: DnsUdpRequest, dns_payload: []const u8, out: *[max_frame_len]u8) ?[]const u8 {
    const ip_total_len = ipv4_header_min_len + udp_header_len + dns_payload.len;
    const frame_len = ethernet_header_len + ip_total_len;
    if (frame_len > out.len) return null;
    const frame = out[0..frame_len];

    @memcpy(frame[0..6], &request.sender_mac);
    @memcpy(frame[6..12], &gateway_mac);
    std.mem.writeInt(u16, frame[12..14], ether_type_ipv4, .big);

    const ip = frame[ethernet_header_len..][0..ipv4_header_min_len];
    ip[0] = 0x45;
    ip[1] = 0;
    std.mem.writeInt(u16, ip[2..4], @intCast(ip_total_len), .big);
    std.mem.writeInt(u16, ip[4..6], 0, .big);
    std.mem.writeInt(u16, ip[6..8], 0, .big);
    ip[8] = ipv4_default_ttl;
    ip[9] = udp_protocol;
    std.mem.writeInt(u16, ip[10..12], 0, .big);
    @memcpy(ip[12..16], &gateway_ipv4);
    @memcpy(ip[16..20], &request.sender_ipv4);
    std.mem.writeInt(u16, ip[10..12], ipv4Checksum(ip), .big);

    const udp = frame[ethernet_header_len + ipv4_header_min_len ..][0 .. udp_header_len + dns_payload.len];
    std.mem.writeInt(u16, udp[0..2], dns_port, .big);
    std.mem.writeInt(u16, udp[2..4], request.sender_port, .big);
    std.mem.writeInt(u16, udp[4..6], @intCast(udp.len), .big);
    std.mem.writeInt(u16, udp[6..8], 0, .big);
    @memcpy(udp[udp_header_len..], dns_payload);
    return frame;
}

fn ipv4Checksum(header: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < header.len) : (i += 2) {
        sum += std.mem.readInt(u16, header[i..][0..2], .big);
    }
    if (i < header.len) sum += @as(u32, header[i]) << 8;
    while ((sum >> 16) != 0) {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    return @as(u16, @truncate(~sum));
}

const ArpRequest = struct {
    sender_mac: [6]u8,
    sender_ipv4: [4]u8,
};

fn parseArpRequest(frame: []const u8) ?ArpRequest {
    if (frame.len < arp_frame_len) return null;
    if (std.mem.readInt(u16, frame[12..14], .big) != ether_type_arp) return null;
    const arp = frame[ethernet_header_len..][0..arp_packet_len];
    if (std.mem.readInt(u16, arp[0..2], .big) != arp_hardware_ethernet) return null;
    if (std.mem.readInt(u16, arp[2..4], .big) != ether_type_ipv4) return null;
    if (arp[4] != 6 or arp[5] != 4) return null;
    if (std.mem.readInt(u16, arp[6..8], .big) != arp_op_request) return null;
    if (!std.mem.eql(u8, arp[24..28], &gateway_ipv4)) return null;

    var sender_mac: [6]u8 = undefined;
    var sender_ipv4: [4]u8 = undefined;
    @memcpy(&sender_mac, arp[8..14]);
    @memcpy(&sender_ipv4, arp[14..18]);
    return .{ .sender_mac = sender_mac, .sender_ipv4 = sender_ipv4 };
}

fn decodeFrameLen(header: *const [frame_header_len]u8) FrameIoError!usize {
    const len = std.mem.readInt(u32, header, .little);
    if (len > max_frame_len) return error.FrameTooLarge;
    return @intCast(len);
}

fn readExactFd(fd: std.c.fd_t, out: []u8) FrameIoError!void {
    var remaining = out;
    while (remaining.len > 0) {
        const n = std.posix.read(fd, remaining) catch return error.IoFailed;
        if (n == 0) return error.EndOfStream;
        remaining = remaining[n..];
    }
}

fn writeAllFd(fd: std.c.fd_t, bytes: []const u8) FrameIoError!void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(fd, remaining.ptr, remaining.len);
        if (n < 0) return error.IoFailed;
        if (n == 0) return error.ShortWrite;
        remaining = remaining[@intCast(n)..];
    }
}

fn resolveHostDnsServer(io: Io, allocator: std.mem.Allocator) [4]u8 {
    const resolv = std.Io.Dir.cwd().readFileAlloc(io, "/etc/resolv.conf", allocator, .limited(64 * 1024)) catch return fallback_dns_ipv4;
    defer allocator.free(resolv);
    return parseNameserver(resolv) orelse fallback_dns_ipv4;
}

fn parseNameserver(resolv: []const u8) ?[4]u8 {
    var lines = std.mem.splitScalar(u8, resolv, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "nameserver")) continue;
        if (line.len == "nameserver".len or (line["nameserver".len] != ' ' and line["nameserver".len] != '\t')) continue;
        const rest = std.mem.trim(u8, line["nameserver".len..], " \t");
        const end = std.mem.indexOfAny(u8, rest, " \t#") orelse rest.len;
        if (spore_net.parseIpv4(rest[0..end])) |ip| return ip;
    }
    return null;
}

fn testArpRequest(sender_mac: [6]u8, sender_ipv4: [4]u8, target_ipv4: [4]u8) [arp_frame_len]u8 {
    var frame: [arp_frame_len]u8 = undefined;
    frame[0..6].* = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    @memcpy(frame[6..12], &sender_mac);
    std.mem.writeInt(u16, frame[12..14], ether_type_arp, .big);
    std.mem.writeInt(u16, frame[14..16], arp_hardware_ethernet, .big);
    std.mem.writeInt(u16, frame[16..18], ether_type_ipv4, .big);
    frame[18] = 6;
    frame[19] = 4;
    std.mem.writeInt(u16, frame[20..22], arp_op_request, .big);
    @memcpy(frame[22..28], &sender_mac);
    @memcpy(frame[28..32], &sender_ipv4);
    frame[32..38].* = .{ 0, 0, 0, 0, 0, 0 };
    @memcpy(frame[38..42], &target_ipv4);
    return frame;
}

fn testDnsQuery(id: u16, qname: []const u8, out: *[512]u8) []const u8 {
    std.mem.writeInt(u16, out[0..2], id, .big);
    std.mem.writeInt(u16, out[2..4], 0x0100, .big);
    std.mem.writeInt(u16, out[4..6], 1, .big);
    std.mem.writeInt(u16, out[6..8], 0, .big);
    std.mem.writeInt(u16, out[8..10], 0, .big);
    std.mem.writeInt(u16, out[10..12], 0, .big);
    var len: usize = dns_header_len;
    var labels = std.mem.splitScalar(u8, qname, '.');
    while (labels.next()) |label| {
        out[len] = @intCast(label.len);
        len += 1;
        @memcpy(out[len..][0..label.len], label);
        len += label.len;
    }
    out[len] = 0;
    len += 1;
    std.mem.writeInt(u16, out[len..][0..2], 1, .big);
    len += 2;
    std.mem.writeInt(u16, out[len..][0..2], 1, .big);
    len += 2;
    return out[0..len];
}

fn testDnsResponse(query: []const u8, out: *[512]u8) []const u8 {
    @memcpy(out[0..query.len], query);
    std.mem.writeInt(u16, out[2..4], 0x8180, .big);
    std.mem.writeInt(u16, out[6..8], 0, .big);
    std.mem.writeInt(u16, out[8..10], 0, .big);
    std.mem.writeInt(u16, out[10..12], 0, .big);
    return out[0..query.len];
}

fn testDnsFrame(dns_payload: []const u8, out: *[max_frame_len]u8) []const u8 {
    const sender_mac: [6]u8 = .{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee };
    const sender_port: u16 = 40000;
    const ip_total_len = ipv4_header_min_len + udp_header_len + dns_payload.len;
    const frame_len = ethernet_header_len + ip_total_len;
    const frame = out[0..frame_len];

    @memcpy(frame[0..6], &gateway_mac);
    @memcpy(frame[6..12], &sender_mac);
    std.mem.writeInt(u16, frame[12..14], ether_type_ipv4, .big);

    const ip = frame[ethernet_header_len..][0..ipv4_header_min_len];
    ip[0] = 0x45;
    ip[1] = 0;
    std.mem.writeInt(u16, ip[2..4], @intCast(ip_total_len), .big);
    std.mem.writeInt(u16, ip[4..6], 0, .big);
    std.mem.writeInt(u16, ip[6..8], 0, .big);
    ip[8] = ipv4_default_ttl;
    ip[9] = udp_protocol;
    std.mem.writeInt(u16, ip[10..12], 0, .big);
    @memcpy(ip[12..16], &guest_ipv4);
    @memcpy(ip[16..20], &gateway_ipv4);
    std.mem.writeInt(u16, ip[10..12], ipv4Checksum(ip), .big);

    const udp = frame[ethernet_header_len + ipv4_header_min_len ..][0 .. udp_header_len + dns_payload.len];
    std.mem.writeInt(u16, udp[0..2], sender_port, .big);
    std.mem.writeInt(u16, udp[2..4], dns_port, .big);
    std.mem.writeInt(u16, udp[4..6], @intCast(udp.len), .big);
    std.mem.writeInt(u16, udp[6..8], 0, .big);
    @memcpy(udp[udp_header_len..], dns_payload);
    return frame;
}

fn expectDnsRcode(reply: []const u8, expected: u16) !void {
    const udp = reply[ethernet_header_len + ipv4_header_min_len ..];
    const dns = udp[udp_header_len..];
    const flags = std.mem.readInt(u16, dns[2..4], .big);
    try std.testing.expect((flags & 0x8000) != 0);
    try std.testing.expectEqual(expected, flags & 0x000f);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, dns[4..6], .big));
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, dns[6..8], .big));
}

test "spore-netd answers ARP for the gateway" {
    const sender_mac: [6]u8 = .{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee };
    const sender_ip: [4]u8 = .{ 100, 96, 0, 2 };
    const request = testArpRequest(sender_mac, sender_ip, gateway_ipv4);

    var out: [max_frame_len]u8 = undefined;
    const reply = arpReply(&request, &out).?;

    try std.testing.expectEqual(@as(usize, arp_frame_len), reply.len);
    try std.testing.expectEqualSlices(u8, &sender_mac, reply[0..6]);
    try std.testing.expectEqualSlices(u8, &gateway_mac, reply[6..12]);
    try std.testing.expectEqual(@as(u16, ether_type_arp), std.mem.readInt(u16, reply[12..14], .big));
    try std.testing.expectEqual(@as(u16, arp_op_reply), std.mem.readInt(u16, reply[20..22], .big));
    try std.testing.expectEqualSlices(u8, &gateway_mac, reply[22..28]);
    try std.testing.expectEqualSlices(u8, &gateway_ipv4, reply[28..32]);
    try std.testing.expectEqualSlices(u8, &sender_mac, reply[32..38]);
    try std.testing.expectEqualSlices(u8, &sender_ip, reply[38..42]);
}

test "spore-netd drops malformed and non-gateway ARP frames" {
    var out: [max_frame_len]u8 = undefined;
    try std.testing.expect(arpReply("short", &out) == null);

    const sender_mac: [6]u8 = .{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee };
    const sender_ip: [4]u8 = .{ 100, 96, 0, 2 };
    const other_ip: [4]u8 = .{ 100, 96, 0, 3 };
    const request = testArpRequest(sender_mac, sender_ip, other_ip);
    try std.testing.expect(arpReply(&request, &out) == null);
}

/// A UDP socket on 127.0.0.1 standing in for the host resolver.
const TestResolver = struct {
    fd: std.c.fd_t,
    port: u16,

    fn open() !TestResolver {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.DGRAM, std.c.IPPROTO.UDP);
        if (fd < 0) return error.TestUnexpectedResult;
        errdefer _ = std.c.close(fd);
        var addr = std.c.sockaddr.in{ .port = 0, .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) return error.TestUnexpectedResult;
        var addr_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
        if (std.c.getsockname(fd, @ptrCast(&addr), &addr_len) != 0) return error.TestUnexpectedResult;
        return .{ .fd = fd, .port = std.mem.bigToNative(u16, addr.port) };
    }

    fn close(self: *TestResolver) void {
        _ = std.c.close(self.fd);
    }

    fn proxy(self: *const TestResolver) DnsProxy {
        return .{ .server_ipv4 = .{ 127, 0, 0, 1 }, .server_port = self.port };
    }

    fn receive(self: *TestResolver, out: *[512]u8, from: *std.c.sockaddr.in) ![]const u8 {
        var fds = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.c.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, 1_000) != 1) return error.TestUnexpectedResult;
        var from_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
        const n = std.c.recvfrom(self.fd, out, out.len, 0, @ptrCast(from), &from_len);
        if (n <= 0) return error.TestUnexpectedResult;
        return out[0..@intCast(n)];
    }

    fn reply(self: *TestResolver, to: *const std.c.sockaddr.in, bytes: []const u8) !void {
        const n = std.c.sendto(self.fd, bytes.ptr, bytes.len, 0, @ptrCast(to), @sizeOf(std.c.sockaddr.in));
        if (n != bytes.len) return error.TestUnexpectedResult;
    }
};

/// One netd loop iteration for the proxy alone: poll its sockets, then take
/// the next resolved reply.
fn pollDnsProxy(proxy: *DnsProxy, policy: *spore_net_policy.Runtime, now: Instant, out: *[max_frame_len]u8) !?[]const u8 {
    var fds: [max_pending_dns]std.posix.pollfd = undefined;
    const count = proxy.fillPollFds(&fds);
    _ = try std.posix.poll(fds[0..count], 1_000);
    return proxy.nextReply(fds[0..count], policy, now, out);
}

fn dnsQueryStep(proxy: *DnsProxy, policy: *spore_net_policy.Runtime, query: []const u8, out: *[max_frame_len]u8) DnsProxy.Step {
    var frame_buf: [max_frame_len]u8 = undefined;
    return proxy.receiveFrame(testDnsFrame(query, &frame_buf), policy, Instant.ZERO, out);
}

fn expectDnsReplyId(reply: []const u8, id: u16) !void {
    const dns = reply[ethernet_header_len + ipv4_header_min_len + udp_header_len ..];
    try std.testing.expectEqual(id, std.mem.readInt(u16, dns[0..2], .big));
}

test "spore-netd proxies bounded UDP DNS queries" {
    var resolver = try TestResolver.open();
    defer resolver.close();
    var proxy = resolver.proxy();
    defer proxy.deinit();
    var policy = try spore_net_policy.Runtime.init(.{ .egress = .unrestricted });

    var query_buf: [512]u8 = undefined;
    const query = testDnsQuery(0x1234, "example.com", &query_buf);
    var frame_buf: [max_frame_len]u8 = undefined;
    const frame = testDnsFrame(query, &frame_buf);
    var out: [max_frame_len]u8 = undefined;
    try std.testing.expect(proxy.receiveFrame(frame, &policy, Instant.ZERO, &out) == .pending);

    var forwarded_buf: [512]u8 = undefined;
    var from: std.c.sockaddr.in = undefined;
    try std.testing.expectEqualSlices(u8, query, try resolver.receive(&forwarded_buf, &from));
    var response_buf: [512]u8 = undefined;
    const response = testDnsResponse(query, &response_buf);
    try resolver.reply(&from, response);

    const reply = (try pollDnsProxy(&proxy, &policy, Instant.fromMillis(10), &out)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, frame[6..12], reply[0..6]);
    try std.testing.expectEqualSlices(u8, &gateway_mac, reply[6..12]);
    try std.testing.expectEqual(@as(u16, ether_type_ipv4), std.mem.readInt(u16, reply[12..14], .big));
    const ip = reply[ethernet_header_len..][0..ipv4_header_min_len];
    try std.testing.expectEqual(@as(u16, 0), ipv4Checksum(ip));
    try std.testing.expectEqualSlices(u8, &gateway_ipv4, ip[12..16]);
    try std.testing.expectEqualSlices(u8, &guest_ipv4, ip[16..20]);
    const udp = reply[ethernet_header_len + ipv4_header_min_len ..];
    try std.testing.expectEqual(@as(u16, dns_port), std.mem.readInt(u16, udp[0..2], .big));
    try std.testing.expectEqual(@as(u16, 40000), std.mem.readInt(u16, udp[2..4], .big));
    try std.testing.expectEqualSlices(u8, response, udp[udp_header_len .. udp_header_len + response.len]);
}

test "spore-netd does not wait on the resolver and times out unanswered DNS" {
    var resolver = try TestResolver.open();
    defer resolver.close();
    var proxy = resolver.proxy();
    defer proxy.deinit();
    var policy = try spore_net_policy.Runtime.init(.{ .egress = .unrestricted });
    var out: [max_frame_len]u8 = undefined;

    // Both queries are in flight at once; neither call waits for an answer.
    var first_buf: [512]u8 = undefined;
    const first = testDnsQuery(0x1111, "example.com", &first_buf);
    var second_buf: [512]u8 = undefined;
    const second = testDnsQuery(0x2222, "example.org", &second_buf);
    try std.testing.expect(dnsQueryStep(&proxy, &policy, first, &out) == .pending);
    try std.testing.expect(dnsQueryStep(&proxy, &policy, second, &out) == .pending);

    var forwarded_buf: [512]u8 = undefined;
    var first_from: std.c.sockaddr.in = undefined;
    var second_from: std.c.sockaddr.in = undefined;
    _ = try resolver.receive(&forwarded_buf, &first_from);
    _ = try resolver.receive(&forwarded_buf, &second_from);

    // Answering only the second query resolves it alone.
    var response_buf: [512]u8 = undefined;
    try resolver.reply(&second_from, testDnsResponse(second, &response_buf));
    try expectDnsReplyId((try pollDnsProxy(&proxy, &policy, Instant.fromMillis(10), &out)) orelse return error.TestUnexpectedResult, 0x2222);
    try std.testing.expectEqual(@as(?[]const u8, null), proxy.nextReply(&.{}, &policy, Instant.fromMillis(10), &out));
    try std.testing.expectEqual(@as(i32, dns_forward_timeout_ms - 10), proxy.nextPollTimeoutMs(Instant.fromMillis(10)));

    // The first query gets SERVFAIL at its deadline.
    try std.testing.expectEqual(@as(?[]const u8, null), proxy.nextReply(&.{}, &policy, Instant.fromMillis(dns_forward_timeout_ms - 1), &out));
    const servfail = proxy.nextReply(&.{}, &policy, Instant.fromMillis(dns_forward_timeout_ms), &out) orelse return error.TestUnexpectedResult;
    try expectDnsReplyId(servfail, 0x1111);
    try expectDnsRcode(servfail, 2);
    try std.testing.expectEqual(@as(i32, -1), proxy.nextPollTimeoutMs(Instant.fromMillis(dns_forward_timeout_ms)));
}

test "spore-netd answers excess DNS queries with SERVFAIL and recovers capacity" {
    var resolver = try TestResolver.open();
    defer resolver.close();
    var proxy = resolver.proxy();
    defer proxy.deinit();
    var policy = try spore_net_policy.Runtime.init(.{ .egress = .unrestricted });
    var out: [max_frame_len]u8 = undefined;
    var query_buf: [512]u8 = undefined;

    var id: u16 = 0;
    while (id < max_pending_dns) : (id += 1) {
        try std.testing.expect(dnsQueryStep(&proxy, &policy, testDnsQuery(id, "example.com", &query_buf), &out) == .pending);
    }
    const overflow = testDnsQuery(max_pending_dns, "example.com", &query_buf);
    const reply = switch (dnsQueryStep(&proxy, &policy, overflow, &out)) {
        .reply => |frame| frame,
        else => return error.TestUnexpectedResult,
    };
    try expectDnsReplyId(reply, max_pending_dns);
    try expectDnsRcode(reply, 2);

    // Once an earlier query has its answer, the guest's retry is forwarded.
    var forwarded_buf: [512]u8 = undefined;
    var from: std.c.sockaddr.in = undefined;
    const first = try resolver.receive(&forwarded_buf, &from);
    var response_buf: [512]u8 = undefined;
    try resolver.reply(&from, testDnsResponse(first, &response_buf));
    _ = (try pollDnsProxy(&proxy, &policy, Instant.fromMillis(10), &out)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(dnsQueryStep(&proxy, &policy, overflow, &out) == .pending);
}

test "spore-netd resolves bound services to the gateway" {
    var query_buf: [512]u8 = undefined;
    const query = testDnsQuery(0x4545, "metadata.spore.internal", &query_buf);
    var proxy = DnsProxy{ .server_ipv4 = .{ 127, 0, 0, 1 } };
    defer proxy.deinit();
    var config = spore_net_policy.Config{ .egress = .unrestricted };
    try config.addBoundUnixService("metadata", "metadata.spore.internal", 80, "/tmp/metadata.sock");
    var policy = try spore_net_policy.Runtime.init(config);

    var out: [max_frame_len]u8 = undefined;
    const reply = dnsQueryStep(&proxy, &policy, query, &out).reply;

    const udp = reply[ethernet_header_len + ipv4_header_min_len ..];
    const dns = udp[udp_header_len..];
    try std.testing.expectEqual(@as(u16, 0x4545), std.mem.readInt(u16, dns[0..2], .big));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, dns[6..8], .big));
    try std.testing.expectEqual(@as(u16, 0xc00c), std.mem.readInt(u16, dns[query.len..][0..2], .big));
    try std.testing.expectEqualSlices(u8, &gateway_ipv4, dns[query.len + 12 ..][0..4]);
}

test "spore-netd returns empty NOERROR for bound service AAAA queries" {
    var query_buf: [512]u8 = undefined;
    const query = testDnsQuery(0x4646, "metadata.spore.internal", &query_buf);
    std.mem.writeInt(u16, query_buf[query.len - 4 ..][0..2], dns_type_aaaa, .big);
    var proxy = DnsProxy{ .server_ipv4 = .{ 127, 0, 0, 1 } };
    defer proxy.deinit();
    var config = spore_net_policy.Config{ .egress = .unrestricted };
    try config.addBoundUnixService("metadata", "metadata.spore.internal", 80, "/tmp/metadata.sock");
    var policy = try spore_net_policy.Runtime.init(config);

    var out: [max_frame_len]u8 = undefined;
    const reply = dnsQueryStep(&proxy, &policy, query, &out).reply;

    const udp = reply[ethernet_header_len + ipv4_header_min_len ..];
    const dns = udp[udp_header_len..];
    try std.testing.expectEqual(@as(u16, 0x4646), std.mem.readInt(u16, dns[0..2], .big));
    try expectDnsRcode(reply, 0);
    try std.testing.expectEqual(query.len, dns.len);
}

test "spore-netd forwards ordinary DNS when a bound service exists" {
    var resolver = try TestResolver.open();
    defer resolver.close();
    var proxy = resolver.proxy();
    defer proxy.deinit();
    var config = spore_net_policy.Config{ .egress = .unrestricted };
    try config.addBoundUnixService("metadata", "metadata.spore.internal", 80, "/tmp/metadata.sock");
    var policy = try spore_net_policy.Runtime.init(config);

    var query_buf: [512]u8 = undefined;
    var out: [max_frame_len]u8 = undefined;
    try std.testing.expect(dnsQueryStep(&proxy, &policy, testDnsQuery(0x7878, "example.com", &query_buf), &out) == .pending);
}

test "spore-netd allow-host policy forwards only matching DNS names" {
    var resolver = try TestResolver.open();
    defer resolver.close();
    var proxy = resolver.proxy();
    defer proxy.deinit();
    var config = spore_net_policy.Config{ .egress = .deny_all };
    try config.addAllowHost("example.com");
    var policy = try spore_net_policy.Runtime.init(config);
    var out: [max_frame_len]u8 = undefined;

    var allowed_buf: [512]u8 = undefined;
    try std.testing.expect(dnsQueryStep(&proxy, &policy, testDnsQuery(0x9191, "example.com", &allowed_buf), &out) == .pending);

    var aaaa_buf: [512]u8 = undefined;
    const aaaa_query = testDnsQuery(0x9392, "example.com", &aaaa_buf);
    std.mem.writeInt(u16, aaaa_buf[aaaa_query.len - 4 ..][0..2], dns_type_aaaa, .big);
    try expectDnsRcode(dnsQueryStep(&proxy, &policy, aaaa_query, &out).reply, 0);

    var denied_buf: [512]u8 = undefined;
    try expectDnsRcode(dnsQueryStep(&proxy, &policy, testDnsQuery(0x9292, "leak.attacker.example", &denied_buf), &out).reply, 5);
}

test "spore-netd exact host-port policy forwards only matching DNS names" {
    var resolver = try TestResolver.open();
    defer resolver.close();
    var proxy = resolver.proxy();
    defer proxy.deinit();
    var config = spore_net_policy.Config{ .egress = .deny_all };
    try config.addExactHostPorts("github.com", &.{443});
    var policy = try spore_net_policy.Runtime.init(config);
    var out: [max_frame_len]u8 = undefined;

    var allowed_buf: [512]u8 = undefined;
    try std.testing.expect(dnsQueryStep(&proxy, &policy, testDnsQuery(0x9393, "github.com", &allowed_buf), &out) == .pending);
    var denied_buf: [512]u8 = undefined;
    try expectDnsRcode(dnsQueryStep(&proxy, &policy, testDnsQuery(0x9494, "api.github.com", &denied_buf), &out).reply, 5);
}

test "spore-netd restricted policies refuse DNS names that cannot open egress" {
    var proxy = DnsProxy{ .server_ipv4 = .{ 127, 0, 0, 1 } };
    defer proxy.deinit();
    var query_buf: [512]u8 = undefined;
    const query = testDnsQuery(0x9595, "example.com", &query_buf);
    var out: [max_frame_len]u8 = undefined;

    var deny_policy = try spore_net_policy.Runtime.init(.{ .egress = .deny_all });
    try expectDnsRcode(dnsQueryStep(&proxy, &deny_policy, query, &out).reply, 5);

    var cidr_config = spore_net_policy.Config{ .egress = .deny_all };
    try cidr_config.addAllowCidr("93.184.216.0/24");
    var cidr_policy = try spore_net_policy.Runtime.init(cidr_config);
    try expectDnsRcode(dnsQueryStep(&proxy, &cidr_policy, query, &out).reply, 5);
}

test "spore-netd answers bound service DNS locally" {
    var query_buf: [512]u8 = undefined;
    const query = testDnsQuery(0x1234, "gateway.cleanroom.internal", &query_buf);
    var proxy = DnsProxy{ .server_ipv4 = .{ 127, 0, 0, 1 } };
    defer proxy.deinit();
    var config = spore_net_policy.Config{ .egress = .unrestricted };
    try config.addBoundUnixService("cleanroom-gateway", "gateway.cleanroom.internal", 8170, "/tmp/gateway.sock");
    var policy = try spore_net_policy.Runtime.init(config);

    var out: [max_frame_len]u8 = undefined;
    const reply = dnsQueryStep(&proxy, &policy, query, &out).reply;

    const udp = reply[ethernet_header_len + ipv4_header_min_len ..];
    const dns = udp[udp_header_len..];
    try std.testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, dns[0..2], .big));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, dns[6..8], .big));
    try std.testing.expectEqualSlices(u8, &gateway_ipv4, dns[query.len + 12 ..][0..4]);
}

test "spore-netd drops malformed DNS compression and bad IPv4 checksums" {
    var query_buf: [512]u8 = undefined;
    const query = query_buf[0..18];
    std.mem.writeInt(u16, query[0..2], 0x1111, .big);
    std.mem.writeInt(u16, query[2..4], 0x0100, .big);
    std.mem.writeInt(u16, query[4..6], 1, .big);
    std.mem.writeInt(u16, query[6..8], 0, .big);
    std.mem.writeInt(u16, query[8..10], 0, .big);
    std.mem.writeInt(u16, query[10..12], 0, .big);
    query[12] = 0xc0;
    query[13] = 0x0c;
    std.mem.writeInt(u16, query[14..16], 1, .big);
    std.mem.writeInt(u16, query[16..18], 1, .big);

    var proxy = DnsProxy{ .server_ipv4 = .{ 127, 0, 0, 1 } };
    defer proxy.deinit();
    var policy = try spore_net_policy.Runtime.init(.{ .egress = .unrestricted });
    var out: [max_frame_len]u8 = undefined;
    try std.testing.expect(dnsQueryStep(&proxy, &policy, query, &out) == .not_dns);

    var good_query_buf: [512]u8 = undefined;
    const good_query = testDnsQuery(0x2222, "example.com", &good_query_buf);
    var frame_buf: [max_frame_len]u8 = undefined;
    const bad_frame = testDnsFrame(good_query, &frame_buf);
    frame_buf[ethernet_header_len + 8] ^= 1;
    try std.testing.expect(proxy.receiveFrame(bad_frame, &policy, Instant.ZERO, &out) == .not_dns);
}

test "spore-netd parses host resolver nameserver lines" {
    const parsed = parseNameserver(
        \\# generated
        \\nameserver 192.0.2.53
        \\nameserver 203.0.113.9
    ).?;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 192, 0, 2, 53 }, &parsed);
    try std.testing.expect(parseNameserver("nameserver ::1\n") == null);
}

test "spore-netd frame stream round trips bounded frames" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    try writeFrameFd(fds[1], "frame");
    var out: [max_frame_len]u8 = undefined;
    const frame = try readFrameFd(fds[0], &out);
    try std.testing.expectEqualStrings("frame", frame);
}

test "spore-netd frame stream rejects oversized frames before payload read" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var header: [frame_header_len]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], max_frame_len + 1, .little);
    try writeAllFd(fds[1], &header);

    var out: [max_frame_len]u8 = undefined;
    try std.testing.expectError(error.FrameTooLarge, readFrameFd(fds[0], &out));
}

fn fuzzFrameStreamAndArp(_: void, s: *std.testing.Smith) !void {
    var bytes: [frame_header_len + max_frame_len]u8 = undefined;
    const len = @min(s.slice(&bytes), bytes.len);
    var out: [max_frame_len]u8 = undefined;
    var config = spore_net_policy.Config{ .egress = .unrestricted };
    try config.addBoundUnixService("metadata", "metadata.spore.internal", 80, "/tmp/metadata.sock");
    var policy = try spore_net_policy.Runtime.init(config);
    var open_policy = try spore_net_policy.Runtime.init(.{ .egress = .unrestricted });
    // Forwarded queries go to the loopback discard port; nothing answers,
    // and the deadline below turns them into SERVFAIL replies.
    var proxy = DnsProxy{ .server_ipv4 = .{ 127, 0, 0, 1 }, .server_port = 9 };
    defer proxy.deinit();

    _ = arpReply(bytes[0..len], &out);
    _ = proxy.receiveFrame(bytes[0..len], &open_policy, Instant.ZERO, &out);
    _ = proxy.receiveFrame(bytes[0..len], &policy, Instant.ZERO, &out);

    var query_buf: [512]u8 = undefined;
    const query = testDnsQuery(0x4545, "metadata.spore.internal", &query_buf);
    var frame_buf: [max_frame_len]u8 = undefined;
    const service_frame = testDnsFrame(query, &frame_buf);
    _ = proxy.receiveFrame(service_frame, &policy, Instant.ZERO, &out);

    var aaaa_query_buf: [512]u8 = undefined;
    const aaaa_query = testDnsQuery(0x4646, "metadata.spore.internal", &aaaa_query_buf);
    std.mem.writeInt(u16, aaaa_query_buf[aaaa_query.len - 4 ..][0..2], dns_type_aaaa, .big);
    var aaaa_frame_buf: [max_frame_len]u8 = undefined;
    const aaaa_service_frame = testDnsFrame(aaaa_query, &aaaa_frame_buf);
    _ = proxy.receiveFrame(aaaa_service_frame, &policy, Instant.ZERO, &out);

    var mutated_buf: [max_frame_len]u8 = undefined;
    @memcpy(mutated_buf[0..service_frame.len], service_frame);
    for (bytes[0..@min(len, service_frame.len)], 0..) |byte, i| {
        mutated_buf[i] ^= byte;
    }
    _ = proxy.receiveFrame(mutated_buf[0..service_frame.len], &policy, Instant.ZERO, &out);

    if (len >= frame_header_len) frame: {
        const frame_len = decodeFrameLen(bytes[0..frame_header_len]) catch break :frame;
        if (frame_header_len + frame_len > len) break :frame;
        _ = arpReply(bytes[frame_header_len..][0..frame_len], &out);
        _ = proxy.receiveFrame(bytes[frame_header_len..][0..frame_len], &open_policy, Instant.ZERO, &out);
        _ = proxy.receiveFrame(bytes[frame_header_len..][0..frame_len], &policy, Instant.ZERO, &out);
    }

    const deadline = Instant.fromMillis(dns_forward_timeout_ms);
    while (proxy.nextReply(&.{}, &open_policy, deadline, &out)) |_| {}
}

test "fuzz spore-netd frame stream, ARP, IPv4, UDP, and DNS handling" {
    try std.testing.fuzz({}, fuzzFrameStreamAndArp, .{});
}
