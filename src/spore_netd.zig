//! Minimal `spore-netd` helper.
//!
//! The helper owns a bounded Ethernet frame stream, ARP replies for the fixed
//! gateway address, narrow DNS proxying, and the first outbound TCP proxy path.

const std = @import("std");
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

const netd_usage = "usage: spore netd --stdio [--allow-cidr CIDR] [--allow-host HOST] [--allow-host-port HOST:PORT] [--bind-service NAME=unix:/path.sock] [--bound-unix-service NAME HOST PORT PATH]\n";

pub const FrameIoError = error{
    EndOfStream,
    FrameTooLarge,
    ShortWrite,
    IoFailed,
};

const DnsForwardError = error{DnsForwardFailed};

const DnsForwarder = struct {
    context: ?*anyopaque,
    forwardFn: *const fn (?*anyopaque, []const u8, *[max_dns_payload_len]u8) DnsForwardError![]const u8,

    fn forward(self: DnsForwarder, query: []const u8, out: *[max_dns_payload_len]u8) DnsForwardError![]const u8 {
        return self.forwardFn(self.context, query, out);
    }
};

const HostDnsForwarder = struct {
    server_ipv4: [4]u8,

    fn forwarder(self: *HostDnsForwarder) DnsForwarder {
        return .{ .context = self, .forwardFn = forward };
    }

    fn forward(ctx: ?*anyopaque, query: []const u8, out: *[max_dns_payload_len]u8) DnsForwardError![]const u8 {
        const self: *HostDnsForwarder = @ptrCast(@alignCast(ctx.?));
        return self.forwardToHost(query, out);
    }

    fn forwardToHost(self: *HostDnsForwarder, query: []const u8, out: *[max_dns_payload_len]u8) DnsForwardError![]const u8 {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.DGRAM, std.c.IPPROTO.UDP);
        if (fd < 0) return error.DnsForwardFailed;
        defer _ = std.c.close(fd);

        var addr = std.c.sockaddr.in{
            .port = std.mem.nativeToBig(u16, dns_port),
            .addr = @bitCast(self.server_ipv4),
        };
        const sockaddr: *const std.c.sockaddr = @ptrCast(&addr);
        if (std.c.connect(fd, sockaddr, @sizeOf(std.c.sockaddr.in)) != 0) return error.DnsForwardFailed;
        const sent = std.c.send(fd, query.ptr, query.len, 0);
        if (sent < 0) return error.DnsForwardFailed;
        if (@as(usize, @intCast(sent)) != query.len) return error.DnsForwardFailed;

        var fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.c.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&fds, dns_forward_timeout_ms) catch return error.DnsForwardFailed;
        if (ready == 0) return error.DnsForwardFailed;
        if ((fds[0].revents & (std.c.POLL.ERR | std.c.POLL.NVAL)) != 0) return error.DnsForwardFailed;

        const n = std.c.recv(fd, out[0..].ptr, out.len, 0);
        if (n <= 0) return error.DnsForwardFailed;
        return out[0..@intCast(n)];
    }
};

pub fn cli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (wantsHelp(args)) {
        try stdout.writeAll(netd_usage);
        return;
    }
    const opts = parseCliArgs(args);
    var policy = spore_net_policy.Runtime.init(opts.policy) catch |err| {
        std.debug.print("spore netd: invalid network policy: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };

    var host_dns = HostDnsForwarder{
        .server_ipv4 = resolveHostDnsServer(init.io, init.arena.allocator()),
    };
    const dns_forwarder = host_dns.forwarder();
    var tcp_gateway: spore_netd_tcp.Gateway = undefined;
    tcp_gateway.init(&policy);
    tcp_gateway.emit_events = true;
    const bound_services = opts.policy.boundServiceSlice();

    try writeAllFd(2, "ready\n");
    var in_buf: [max_frame_len]u8 = undefined;
    var reply_buf: [max_frame_len]u8 = undefined;
    while (true) {
        const now = tcpNow();
        var fds: [1 + spore_netd_tcp.max_flows]std.posix.pollfd = undefined;
        fds[0] = .{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 };
        const host_fd_count = tcp_gateway.fillPollFds(fds[1..]);
        const poll_fds = fds[0 .. 1 + host_fd_count];
        const timeout_ms = tcp_gateway.nextPollTimeoutMs(now);
        _ = std.posix.poll(poll_fds, timeout_ms) catch return error.IoFailed;

        const after_poll = tcpNow();
        if ((fds[0].revents & (std.c.POLL.ERR | std.c.POLL.NVAL)) != 0) return error.IoFailed;
        if ((fds[0].revents & (std.c.POLL.IN | std.c.POLL.HUP)) != 0) {
            const frame = readFrameFd(0, &in_buf) catch |err| switch (err) {
                error.EndOfStream => return,
                else => |e| return e,
            };
            std.log.debug("spore-netd rx frame len={d}", .{frame.len});
            if (frameReply(frame, &reply_buf, dns_forwarder, &policy, if (bound_services.len == 1) bound_services[0] else null)) |reply| {
                try writeFrameFd(1, reply);
            } else if (!tcp_gateway.receiveFrame(frame, after_poll)) {
                std.log.debug("spore-netd dropped unsupported frame len={d}", .{frame.len});
            }
        }

        tcp_gateway.servicePoll(fds[1 .. 1 + host_fd_count]);
        tcp_gateway.service(after_poll);
        try drainTcpGateway(&tcp_gateway);
    }
}

const CliOptions = struct {
    policy: spore_net_policy.Config = .{},
};

fn parseCliArgs(args: []const []const u8) CliOptions {
    var opts = CliOptions{};
    var stdio = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--stdio")) {
            stdio = true;
        } else if (std.mem.eql(u8, args[i], "--allow-cidr")) {
            const raw = takeValue(args, &i, args[i]);
            opts.policy.addAllowCidr(raw) catch |err| {
                std.debug.print("spore netd: invalid --allow-cidr {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--allow-host")) {
            const raw = takeValue(args, &i, args[i]);
            opts.policy.addAllowHost(raw) catch |err| {
                std.debug.print("spore netd: invalid --allow-host {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--bind-service")) {
            const raw = takeValue(args, &i, args[i]);
            opts.policy.addBindService(raw) catch |err| {
                std.debug.print("spore netd: invalid --bind-service {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--allow-host-port")) {
            const raw = takeValue(args, &i, args[i]);
            const parsed = spore_net_policy.parseHostPort(raw) catch |err| {
                std.debug.print("spore netd: invalid --allow-host-port {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            };
            opts.policy.addExactHostPorts(parsed.host, &.{parsed.port}) catch |err| {
                std.debug.print("spore netd: invalid --allow-host-port {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--bound-unix-service")) {
            const flag = args[i];
            const name = takeValue(args, &i, flag);
            const guest_host = takeValue(args, &i, flag);
            const guest_port_raw = takeValue(args, &i, flag);
            const unix_path = takeValue(args, &i, flag);
            const guest_port = std.fmt.parseUnsigned(u16, guest_port_raw, 10) catch {
                std.debug.print("spore netd: invalid --bound-unix-service port {s}\n", .{guest_port_raw});
                std.process.exit(2);
            };
            opts.policy.addBoundUnixService(name, guest_host, guest_port, unix_path) catch |err| {
                std.debug.print("spore netd: invalid --bound-unix-service {s}: {s}\n", .{ name, @errorName(err) });
                std.process.exit(2);
            };
        } else {
            std.debug.print("unknown netd argument: {s}\n{s}", .{ args[i], netd_usage });
            std.process.exit(2);
        }
    }
    if (!stdio) {
        std.debug.print("{s}", .{netd_usage});
        std.process.exit(2);
    }
    if (opts.policy.bound_service_count > 1) {
        std.debug.print("spore netd: --bind-service supports exactly one service for now\n", .{});
        std.process.exit(2);
    }
    return opts;
}

fn wantsHelp(args: []const []const u8) bool {
    return args.len == 1 and
        (std.mem.eql(u8, args[0], "help") or
            std.mem.eql(u8, args[0], "-h") or
            std.mem.eql(u8, args[0], "--help"));
}

test "netd cli help accepts standard help spellings" {
    try std.testing.expect(wantsHelp(&.{"--help"}));
    try std.testing.expect(wantsHelp(&.{"-h"}));
    try std.testing.expect(wantsHelp(&.{"help"}));
    try std.testing.expect(!wantsHelp(&.{}));
    try std.testing.expect(!wantsHelp(&.{ "--help", "extra" }));
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

fn frameReply(frame: []const u8, out: *[max_frame_len]u8, dns_forwarder: DnsForwarder, policy: ?*spore_net_policy.Runtime, bound_service: ?spore_net_policy.BoundServiceConfig) ?[]const u8 {
    if (arpReply(frame, out)) |reply| return reply;
    return dnsReply(frame, out, dns_forwarder, policy, bound_service);
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

fn dnsReply(frame: []const u8, out: *[max_frame_len]u8, dns_forwarder: DnsForwarder, policy: ?*spore_net_policy.Runtime, bound_service: ?spore_net_policy.BoundServiceConfig) ?[]const u8 {
    const request = parseDnsUdpRequest(frame) orelse return null;

    var local_response_buf: [max_dns_payload_len]u8 = undefined;
    if (boundServiceDnsResponse(request.payload, request.question_end, bound_service, &local_response_buf)) |response| {
        return buildDnsUdpFrame(request, response, out);
    }

    var forward_buf: [max_dns_payload_len]u8 = undefined;
    var response_buf: [max_dns_payload_len]u8 = undefined;
    if (policy) |policy_runtime| {
        if (policy_runtime.boundServiceForDnsQuery(request.payload, dns_header_len)) |_| {
            const dns_payload = if (dnsQuestionIsAIn(request.payload, request.question_end))
                buildBoundServiceDnsResponse(request.payload, request.question_end, &response_buf)
            else
                buildDnsServfail(request.payload, request.question_end, &response_buf);
            return buildDnsUdpFrame(request, dns_payload, out);
        }
    }
    const forwarded = dns_forwarder.forward(request.payload, &forward_buf) catch null;
    const dns_payload = if (forwarded) |response| valid: {
        if (!validDnsResponse(request.payload, response)) break :valid buildDnsServfail(request.payload, request.question_end, &response_buf);
        if (policy) |policy_runtime| _ = policy_runtime.noteDnsResponse(request.payload, response);
        break :valid response;
    } else buildDnsServfail(request.payload, request.question_end, &response_buf);

    return buildDnsUdpFrame(request, dns_payload, out);
}

fn boundServiceDnsResponse(packet: []const u8, question_end: usize, bound_service: ?spore_net_policy.BoundServiceConfig, out: *[max_dns_payload_len]u8) ?[]const u8 {
    const service = bound_service orelse return null;
    const matched = if (service.guest_host.len != 0)
        dnsNameMatchesHost(packet, dns_header_len, service.guest_host)
    else
        dnsNameMatchesBoundService(packet, dns_header_len, service.name);
    if (!matched) return null;
    return if (dnsQuestionIsAIn(packet, question_end))
        buildBoundServiceDnsResponse(packet, question_end, out)
    else
        buildDnsServfail(packet, question_end, out);
}

fn dnsNameMatchesBoundService(packet: []const u8, start: usize, service_name: []const u8) bool {
    var offset = start;
    if (!dnsLabelEquals(packet, &offset, service_name)) return false;
    if (!dnsLabelEquals(packet, &offset, "spore")) return false;
    if (!dnsLabelEquals(packet, &offset, "internal")) return false;
    return offset < packet.len and packet[offset] == 0;
}

fn dnsNameMatchesHost(packet: []const u8, start: usize, host: []const u8) bool {
    var offset = start;
    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| {
        if (!dnsLabelEquals(packet, &offset, label)) return false;
    }
    return offset < packet.len and packet[offset] == 0;
}

fn dnsLabelEquals(packet: []const u8, offset: *usize, expected: []const u8) bool {
    if (offset.* >= packet.len) return false;
    const len = packet[offset.*];
    if ((len & 0xc0) != 0 or len != expected.len) return false;
    offset.* += 1;
    if (offset.* + len > packet.len) return false;
    defer offset.* += len;
    return std.ascii.eqlIgnoreCase(packet[offset.*..][0..len], expected);
}

fn buildDnsNoAnswer(query: []const u8, question_end: usize, out: *[max_dns_payload_len]u8) []const u8 {
    @memcpy(out[0..question_end], query[0..question_end]);
    std.mem.writeInt(u16, out[2..4], 0x8180, .big);
    std.mem.writeInt(u16, out[4..6], 1, .big);
    std.mem.writeInt(u16, out[6..8], 0, .big);
    std.mem.writeInt(u16, out[8..10], 0, .big);
    std.mem.writeInt(u16, out[10..12], 0, .big);
    return out[0..question_end];
}

fn dnsQuestionIsAIn(query: []const u8, question_end: usize) bool {
    if (question_end < dns_header_len + 4 or question_end > query.len) return false;
    return std.mem.readInt(u16, query[question_end - 4 ..][0..2], .big) == 1 and
        std.mem.readInt(u16, query[question_end - 2 ..][0..2], .big) == 1;
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
    const len = @min(question_end, out.len);
    @memcpy(out[0..len], query[0..len]);
    var flags = std.mem.readInt(u16, query[2..4], .big);
    flags &= 0x0100;
    flags |= 0x8000 | 0x0080 | 0x0002;
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

const TestDnsForwarder = struct {
    response: []const u8 = "",
    fail: bool = false,
    query_len: usize = 0,
    query_id: u16 = 0,

    fn forwarder(self: *TestDnsForwarder) DnsForwarder {
        return .{ .context = self, .forwardFn = forward };
    }

    fn forward(ctx: ?*anyopaque, query: []const u8, out: *[max_dns_payload_len]u8) DnsForwardError![]const u8 {
        const self: *TestDnsForwarder = @ptrCast(@alignCast(ctx.?));
        self.query_len = query.len;
        if (query.len >= 2) self.query_id = std.mem.readInt(u16, query[0..2], .big);
        if (self.fail or self.response.len > out.len) return error.DnsForwardFailed;
        @memcpy(out[0..self.response.len], self.response);
        return out[0..self.response.len];
    }
};

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

test "spore-netd proxies bounded UDP DNS queries" {
    var query_buf: [512]u8 = undefined;
    const query = testDnsQuery(0x1234, "example.com", &query_buf);
    var response_buf: [512]u8 = undefined;
    const response = testDnsResponse(query, &response_buf);
    var frame_buf: [max_frame_len]u8 = undefined;
    const frame = testDnsFrame(query, &frame_buf);
    var forwarder = TestDnsForwarder{ .response = response };

    var out: [max_frame_len]u8 = undefined;
    const reply = frameReply(frame, &out, forwarder.forwarder(), null, null).?;

    try std.testing.expectEqual(query.len, forwarder.query_len);
    try std.testing.expectEqual(@as(u16, 0x1234), forwarder.query_id);
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

test "spore-netd resolves bound services to the gateway" {
    var query_buf: [512]u8 = undefined;
    const query = testDnsQuery(0x4545, "metadata.spore.internal", &query_buf);
    var frame_buf: [max_frame_len]u8 = undefined;
    const frame = testDnsFrame(query, &frame_buf);
    var forwarder = TestDnsForwarder{ .fail = true };
    const service = spore_net_policy.BoundServiceConfig{
        .declaration = "metadata=unix:/tmp/metadata.sock",
        .name = "metadata",
        .guest_port = 80,
        .unix_path = "/tmp/metadata.sock",
    };

    var out: [max_frame_len]u8 = undefined;
    const reply = frameReply(frame, &out, forwarder.forwarder(), null, service).?;
    try std.testing.expectEqual(@as(usize, 0), forwarder.query_len);

    const udp = reply[ethernet_header_len + ipv4_header_min_len ..];
    const dns = udp[udp_header_len..];
    try std.testing.expectEqual(@as(u16, 0x4545), std.mem.readInt(u16, dns[0..2], .big));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, dns[6..8], .big));
    try std.testing.expectEqual(@as(u16, 0xc00c), std.mem.readInt(u16, dns[query.len..][0..2], .big));
    try std.testing.expectEqualSlices(u8, &gateway_ipv4, dns[query.len + 12 ..][0..4]);
}

test "spore-netd forwards ordinary DNS when a bound service exists" {
    var query_buf: [512]u8 = undefined;
    const query = testDnsQuery(0x7878, "example.com", &query_buf);
    var response_buf: [512]u8 = undefined;
    const response = testDnsResponse(query, &response_buf);
    var frame_buf: [max_frame_len]u8 = undefined;
    const frame = testDnsFrame(query, &frame_buf);
    var forwarder = TestDnsForwarder{ .response = response };
    const service = spore_net_policy.BoundServiceConfig{
        .declaration = "metadata=unix:/tmp/metadata.sock",
        .name = "metadata",
        .guest_port = 80,
        .unix_path = "/tmp/metadata.sock",
    };

    var out: [max_frame_len]u8 = undefined;
    _ = frameReply(frame, &out, forwarder.forwarder(), null, service).?;
    try std.testing.expectEqual(query.len, forwarder.query_len);
}

test "spore-netd returns DNS SERVFAIL when host forwarding fails" {
    var query_buf: [512]u8 = undefined;
    const query = testDnsQuery(0xbeef, "example.com", &query_buf);
    var frame_buf: [max_frame_len]u8 = undefined;
    const frame = testDnsFrame(query, &frame_buf);
    var forwarder = TestDnsForwarder{ .fail = true };

    var out: [max_frame_len]u8 = undefined;
    const reply = frameReply(frame, &out, forwarder.forwarder(), null, null).?;
    const udp = reply[ethernet_header_len + ipv4_header_min_len ..];
    const dns = udp[udp_header_len..];

    try std.testing.expectEqual(@as(u16, 0xbeef), std.mem.readInt(u16, dns[0..2], .big));
    const flags = std.mem.readInt(u16, dns[2..4], .big);
    try std.testing.expect((flags & 0x8000) != 0);
    try std.testing.expectEqual(@as(u16, 2), flags & 0x000f);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, dns[4..6], .big));
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, dns[6..8], .big));
}

test "spore-netd answers bound service DNS locally" {
    var query_buf: [512]u8 = undefined;
    const query = testDnsQuery(0x1234, "gateway.cleanroom.internal", &query_buf);
    var frame_buf: [max_frame_len]u8 = undefined;
    const frame = testDnsFrame(query, &frame_buf);
    var forwarder = TestDnsForwarder{ .fail = true };
    var config = spore_net_policy.Config{};
    try config.addBoundUnixService("cleanroom-gateway", "gateway.cleanroom.internal", 8170, "/tmp/gateway.sock");
    var policy = try spore_net_policy.Runtime.init(config);

    var out: [max_frame_len]u8 = undefined;
    const reply = frameReply(frame, &out, forwarder.forwarder(), &policy, null).?;
    try std.testing.expectEqual(@as(usize, 0), forwarder.query_len);

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

    var frame_buf: [max_frame_len]u8 = undefined;
    const frame = testDnsFrame(query, &frame_buf);
    var forwarder = TestDnsForwarder{};
    var out: [max_frame_len]u8 = undefined;
    try std.testing.expect(frameReply(frame, &out, forwarder.forwarder(), null, null) == null);

    var good_query_buf: [512]u8 = undefined;
    const good_query = testDnsQuery(0x2222, "example.com", &good_query_buf);
    const bad_frame = testDnsFrame(good_query, &frame_buf);
    frame_buf[ethernet_header_len + 8] ^= 1;
    try std.testing.expect(frameReply(bad_frame, &out, forwarder.forwarder(), null, null) == null);
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

test "spore-netd cli parser accepts network policy rules" {
    const opts = parseCliArgs(&.{
        "--stdio",
        "--allow-cidr",
        "93.184.216.34/32",
        "--allow-host",
        "example.com",
        "--allow-host-port",
        "github.com:443",
        "--bound-unix-service",
        "cleanroom-gateway",
        "gateway.cleanroom.internal",
        "8170",
        "/tmp/gateway.sock",
    });
    try std.testing.expectEqual(@as(usize, 1), opts.policy.allow_cidr_count);
    try std.testing.expectEqualStrings("93.184.216.34/32", opts.policy.allow_cidrs[0]);
    try std.testing.expectEqual(@as(usize, 1), opts.policy.allow_host_count);
    try std.testing.expectEqualStrings("example.com", opts.policy.allow_hosts[0]);
    try std.testing.expectEqual(@as(usize, 1), opts.policy.exact_rule_count);
    try std.testing.expectEqualStrings("github.com", opts.policy.exact_rules[0].host);
    try std.testing.expectEqual(@as(u16, 443), opts.policy.exact_rules[0].ports[0]);
    try std.testing.expectEqual(@as(usize, 1), opts.policy.bound_service_count);
    try std.testing.expectEqualStrings("cleanroom-gateway", opts.policy.bound_services[0].name);
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
    var forwarder = TestDnsForwarder{ .fail = true };
    const bound_service = spore_net_policy.BoundServiceConfig{
        .declaration = "metadata=unix:/tmp/metadata.sock",
        .name = "metadata",
        .guest_port = 80,
        .unix_path = "/tmp/metadata.sock",
    };

    _ = arpReply(bytes[0..len], &out);
    _ = frameReply(bytes[0..len], &out, forwarder.forwarder(), null, null);
    _ = frameReply(bytes[0..len], &out, forwarder.forwarder(), null, bound_service);

    var query_buf: [512]u8 = undefined;
    const query = testDnsQuery(0x4545, "metadata.spore.internal", &query_buf);
    var frame_buf: [max_frame_len]u8 = undefined;
    const service_frame = testDnsFrame(query, &frame_buf);
    _ = frameReply(service_frame, &out, forwarder.forwarder(), null, bound_service);

    var mutated_buf: [max_frame_len]u8 = undefined;
    @memcpy(mutated_buf[0..service_frame.len], service_frame);
    for (bytes[0..@min(len, service_frame.len)], 0..) |byte, i| {
        mutated_buf[i] ^= byte;
    }
    _ = frameReply(mutated_buf[0..service_frame.len], &out, forwarder.forwarder(), null, bound_service);

    if (len < frame_header_len) return;
    const frame_len = decodeFrameLen(bytes[0..frame_header_len]) catch return;
    if (frame_header_len + frame_len > len) return;
    _ = arpReply(bytes[frame_header_len..][0..frame_len], &out);
    _ = frameReply(bytes[frame_header_len..][0..frame_len], &out, forwarder.forwarder(), null, null);
    _ = frameReply(bytes[frame_header_len..][0..frame_len], &out, forwarder.forwarder(), null, bound_service);
}

test "fuzz spore-netd frame stream, ARP, IPv4, UDP, and DNS handling" {
    try std.testing.fuzz({}, fuzzFrameStreamAndArp, .{});
}
