//! Fixed first-version SporeVM-managed network constants.

const virtio_net = @import("virtio/net.zig");

pub const max_frame_len = virtio_net.max_frame_len;

pub const guest_mac = virtio_net.default_mac;
pub const gateway_mac: [6]u8 = .{ 0x02, 0x53, 0x50, 0x4f, 0x52, 0x01 };

pub const guest_ipv4: [4]u8 = .{ 100, 96, 0, 2 };
pub const gateway_ipv4: [4]u8 = .{ 100, 96, 0, 1 };
