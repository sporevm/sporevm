//! Fixed first-version SporeVM-managed network constants.

const std = @import("std");

const virtio_net = @import("virtio/net.zig");

pub const max_frame_len = virtio_net.max_frame_len;

pub const guest_mac = virtio_net.default_mac;
pub const gateway_mac: [6]u8 = .{ 0x02, 0x53, 0x50, 0x4f, 0x52, 0x01 };

pub const guest_ipv4: [4]u8 = .{ 100, 96, 0, 2 };
pub const gateway_ipv4: [4]u8 = .{ 100, 96, 0, 1 };

pub fn parseIpv4(raw: []const u8) ?[4]u8 {
    var ip: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, raw, '.');
    var i: usize = 0;
    while (parts.next()) |part| {
        if (i >= ip.len or part.len == 0) return null;
        ip[i] = std.fmt.parseUnsigned(u8, part, 10) catch return null;
        i += 1;
    }
    if (i != ip.len) return null;
    return ip;
}

test "parse IPv4 text" {
    try std.testing.expectEqual(@as([4]u8, .{ 192, 0, 2, 1 }), parseIpv4("192.0.2.1").?);
    try std.testing.expect(parseIpv4("192.0.2") == null);
    try std.testing.expect(parseIpv4("192.0.2.1.5") == null);
    try std.testing.expect(parseIpv4("192..2.1") == null);
    try std.testing.expect(parseIpv4("192.0.2.256") == null);
}
