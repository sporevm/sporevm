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

pub fn skipDnsName(packet: []const u8, start: usize) ?usize {
    var offset = start;
    var end: ?usize = null;
    var jumps: usize = 0;
    var name_len: usize = 0;
    while (true) {
        if (offset >= packet.len) return null;
        const len = packet[offset];
        if ((len & 0xc0) == 0xc0) {
            if (offset + 1 >= packet.len) return null;
            const pointer = (@as(usize, len & 0x3f) << 8) | packet[offset + 1];
            if (pointer >= packet.len) return null;
            if (end == null) end = offset + 2;
            jumps += 1;
            if (jumps > 16) return null;
            offset = pointer;
            continue;
        }
        if ((len & 0xc0) != 0) return null;
        offset += 1;
        if (len == 0) return end orelse offset;
        if (len > 63) return null;
        name_len += @as(usize, len) + 1;
        if (name_len > 255) return null;
        if (offset + len > packet.len) return null;
        offset += len;
    }
}

test "parse IPv4 text" {
    try std.testing.expectEqual(@as([4]u8, .{ 192, 0, 2, 1 }), parseIpv4("192.0.2.1").?);
    try std.testing.expect(parseIpv4("192.0.2") == null);
    try std.testing.expect(parseIpv4("192.0.2.1.5") == null);
    try std.testing.expect(parseIpv4("192..2.1") == null);
    try std.testing.expect(parseIpv4("192.0.2.256") == null);
}

test "skip DNS name handles direct and compressed names" {
    const packet = [_]u8{
        7, 'e', 'x', 'a', 'm', 'p',  'l',  'e',
        3, 'c', 'o', 'm', 0,   0xc0, 0x00,
    };

    try std.testing.expectEqual(@as(?usize, 13), skipDnsName(&packet, 0));
    try std.testing.expectEqual(@as(?usize, 15), skipDnsName(&packet, 13));
}

test "skip DNS name rejects pointer loops and overlong names" {
    const loop_packet = [_]u8{ 0xc0, 0x00 };
    try std.testing.expect(skipDnsName(&loop_packet, 0) == null);

    var overlong: [257]u8 = undefined;
    var i: usize = 0;
    while (i < 128) : (i += 1) {
        overlong[i * 2] = 1;
        overlong[i * 2 + 1] = 'a';
    }
    overlong[256] = 0;
    try std.testing.expect(skipDnsName(&overlong, 0) == null);
}
