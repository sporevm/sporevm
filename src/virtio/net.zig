//! Virtio network device (virtio spec 1.2 §5.1), minimal closed endpoint.
//!
//! Queue 0 is receive and queue 1 is transmit. This first slice exposes a
//! stable MAC address and safely drains guest TX packets; it intentionally
//! does not provide host network connectivity yet. The eventual fd-backed
//! backend can attach behind the same transport without changing the board
//! shape. Queue descriptors and packet lengths are guest controlled. See
//! SECURITY.md.

const std = @import("std");
const guestmem = @import("../guestmem.zig");
const queue = @import("queue.zig");
const mmio = @import("mmio.zig");

pub const device_id: u32 = 1;

const rx_queue = 0;
const tx_queue = 1;

/// VIRTIO_NET_F_MAC: config space contains the device MAC address.
const feature_mac: u64 = 1 << 5;

pub const default_mac: [6]u8 = .{ 0x02, 0x53, 0x50, 0x4f, 0x52, 0x45 }; // locally administered "SPORE"

pub const Config = struct {
    mac: [6]u8 = default_mac,
};

pub const Net = struct {
    mac: [6]u8,
    tx_packets: u64 = 0,
    tx_bytes: u64 = 0,

    pub fn init(config: Config) Net {
        return .{ .mac = config.mac };
    }

    pub fn device(self: *Net) mmio.Device {
        return .{
            .context = self,
            .device_id = device_id,
            .device_features = feature_mac,
            .queue_count = 2,
            .notifyFn = notify,
            .configReadFn = configRead,
        };
    }

    fn configRead(ctx: *anyopaque, offset: u64) u32 {
        const self: *Net = @ptrCast(@alignCast(ctx));
        var out: u32 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const idx = offset + i;
            if (idx < self.mac.len) {
                out |= @as(u32, self.mac[@intCast(idx)]) << @intCast(8 * i);
            }
        }
        return out;
    }

    fn notify(ctx: *anyopaque, queue_index: u8, queues: *[mmio.max_queues]queue.VirtQueue, ram: guestmem.GuestRam) bool {
        const self: *Net = @ptrCast(@alignCast(ctx));
        return switch (queue_index) {
            tx_queue => self.drainTx(&queues[tx_queue], ram),
            rx_queue => false,
            else => false,
        };
    }

    fn drainTx(self: *Net, tx: *queue.VirtQueue, ram: guestmem.GuestRam) bool {
        var did_work = false;
        var budget: usize = queue.max_queue_size;
        while (budget > 0) : (budget -= 1) {
            const maybe_chain = tx.popAvail(ram) catch return did_work;
            const chain = maybe_chain orelse break;
            self.tx_packets +%= 1;
            self.tx_bytes +%= chain.readableLen();
            tx.pushUsed(ram, chain.head, 0) catch return did_work;
            did_work = true;
        }
        return did_work;
    }
};

// --- tests ------------------------------------------------------------------

fn configureQueue(t: *mmio.Transport, qi: u32, desc: u64, avail: u64, used: u64, ram: guestmem.GuestRam) void {
    _ = t.write(0x030, qi, ram);
    _ = t.write(0x038, 8, ram);
    _ = t.write(0x080, @truncate(desc), ram);
    _ = t.write(0x084, @truncate(desc >> 32), ram);
    _ = t.write(0x090, @truncate(avail), ram);
    _ = t.write(0x094, @truncate(avail >> 32), ram);
    _ = t.write(0x0a0, @truncate(used), ram);
    _ = t.write(0x0a4, @truncate(used >> 32), ram);
    _ = t.write(0x044, 1, ram);
}

fn setDesc(ram: guestmem.GuestRam, desc_base: u64, i: u16, addr: u64, len: u32, flags: u16) !void {
    const base = desc_base + 16 * @as(u64, i);
    try ram.write(u64, base, addr);
    try ram.write(u32, base + 8, len);
    try ram.write(u16, base + 12, flags);
    try ram.write(u16, base + 14, 0);
}

fn pushAvail(ram: guestmem.GuestRam, avail_base: u64, qsize: u16, head: u16) !void {
    const idx = try ram.read(u16, avail_base + 2);
    try ram.write(u16, avail_base + 4 + 2 * @as(u64, idx % qsize), head);
    try ram.write(u16, avail_base + 2, idx +% 1);
}

test "identity features and mac config" {
    var dev = Net.init(.{});
    var t = mmio.Transport.init(dev.device());
    try std.testing.expectEqual(device_id, t.read(0x008));
    try std.testing.expectEqual(@as(u32, @truncate(feature_mac)), t.read(0x010));
    try std.testing.expectEqual(@as(u32, 0x4f_50_53_02), t.read(0x100));
    try std.testing.expectEqual(@as(u32, 0x0000_4542), t.read(0x104));
    try std.testing.expectEqual(@as(u32, 0x0000_0045), t.read(0x105));
}

test "tx queue drains packets and returns descriptors used" {
    var dev = Net.init(.{});
    var t = mmio.Transport.init(dev.device());
    var buf: [4096]u8 = [_]u8{0} ** 4096;
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    const tx_desc = 0x000;
    const tx_avail = 0x400;
    const tx_used = 0x800;
    const packet = 0xc00;

    configureQueue(&t, tx_queue, tx_desc, tx_avail, tx_used, ram);
    try setDesc(ram, tx_desc, 0, packet, 64, 0);
    try pushAvail(ram, tx_avail, 8, 0);

    try std.testing.expect(t.write(0x050, tx_queue, ram));
    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, tx_used + 2));
    try std.testing.expectEqual(@as(u32, 0), try ram.read(u32, tx_used + 8));
    try std.testing.expectEqual(@as(u64, 1), dev.tx_packets);
    try std.testing.expectEqual(@as(u64, 64), dev.tx_bytes);
}

fn fuzzNetTx(_: void, s: *std.testing.Smith) !void {
    var dev = Net.init(.{});
    var t = mmio.Transport.init(dev.device());
    var buf: [4096]u8 = [_]u8{0} ** 4096;
    _ = s.slice(&buf);
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };
    t.queues[tx_queue] = .{ .size = 8, .ready = true, .desc_addr = 0x0000, .avail_addr = 0x0400, .used_addr = 0x0800 };
    _ = t.write(0x050, tx_queue, ram);
}

test "fuzz net tx handling" {
    try std.testing.fuzz({}, fuzzNetTx, .{});
}
