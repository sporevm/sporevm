//! SporeVM-side contract checks for the pinned `zmoltcp` gateway API.
//!
//! The actual TCP proxy adapter lands in the next slice. This module keeps the
//! dependency import wired into the SporeVM build and verifies the generic
//! forwarder surface that `spore-netd` will use.

const std = @import("std");
const zmoltcp = @import("zmoltcp");

pub const ipv4 = zmoltcp.wire.ipv4;
pub const tcp = zmoltcp.socket.tcp;

pub const TcpForwardRequest = tcp.ForwardRequest(ipv4);

pub fn TcpForwarder(comptime TcpSock: type, comptime Context: type) type {
    return tcp.Forwarder(ipv4, TcpSock, Context);
}

test "zmoltcp exposes caller-owned IPv4 TCP forwarder contract" {
    const TcpSock = tcp.Socket(ipv4, 4);
    const Request = TcpForwardRequest;
    const Policy = struct {
        sock: *TcpSock,
        accept: bool = false,
        requested: ?Request = null,

        fn offer(self: *@This(), request: Request) ?*TcpSock {
            self.requested = request;
            if (!self.accept) return null;
            return self.sock;
        }
    };

    var rx_buf: [256]u8 = .{0} ** 256;
    var tx_buf: [256]u8 = .{0} ** 256;
    var sock = TcpSock.init(&rx_buf, &tx_buf);
    var policy = Policy{ .sock = &sock };
    var forwarder = TcpForwarder(TcpSock, Policy).init(&policy, Policy.offer);

    const request = Request{
        .local = .{ .addr = .{ 93, 184, 216, 34 }, .port = 80 },
        .remote = .{ .addr = .{ 100, 96, 0, 2 }, .port = 49152 },
    };

    try std.testing.expect(forwarder.offer(request) == null);
    try std.testing.expectEqual(request.local.addr, policy.requested.?.local.addr);
    try std.testing.expectEqual(request.local.port, policy.requested.?.local.port);
    try std.testing.expectEqual(request.remote.addr, policy.requested.?.remote.addr);
    try std.testing.expectEqual(request.remote.port, policy.requested.?.remote.port);
    try std.testing.expectEqual(tcp.State.closed, sock.getState());

    policy.accept = true;
    const accepted = forwarder.offer(request) orelse return error.ExpectedForwardSocket;
    try std.testing.expect(accepted == &sock);
}
