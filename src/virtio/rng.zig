//! Virtio entropy device (virtio spec 1.2 §5.4), minimal.
//!
//! One request queue. The guest posts writable buffers and the device fills
//! them with host entropy. Descriptor contents and lengths are guest
//! controlled and remain bounded by `queue.VirtQueue`. See SECURITY.md.

const std = @import("std");
const builtin = @import("builtin");
const guestmem = @import("../guestmem.zig");
const queue = @import("queue.zig");
const mmio = @import("mmio.zig");

pub const device_id: u32 = 4;

const request_queue = 0;

pub const Rng = struct {
    fillFn: *const fn ([]u8) void = osFill,

    pub fn device(self: *Rng) mmio.Device {
        return .{
            .context = self,
            .device_id = device_id,
            .device_features = 0,
            .queue_count = 1,
            .notifyFn = notify,
        };
    }

    fn osFill(buf: []u8) void {
        if (buf.len == 0) return;
        switch (builtin.os.tag) {
            .macos,
            .ios,
            .tvos,
            .watchos,
            .visionos,
            .driverkit,
            .freebsd,
            .openbsd,
            .netbsd,
            .dragonfly,
            .illumos,
            => std.c.arc4random_buf(buf.ptr, buf.len),
            .linux => fillLinux(buf),
            else => @panic("no supported host entropy source"),
        }
    }

    fn notify(ctx: *anyopaque, queue_index: u8, queues: *[mmio.max_queues]queue.VirtQueue, ram: guestmem.GuestRam) bool {
        const self: *Rng = @ptrCast(@alignCast(ctx));
        if (queue_index != request_queue) return false;
        const q = &queues[request_queue];

        var did_work = false;
        while (true) {
            const maybe_chain = q.popAvail(ram) catch return did_work;
            const chain = maybe_chain orelse break;
            const written = self.handleChain(&chain);
            q.pushUsed(ram, chain.head, written) catch return did_work;
            did_work = true;
        }
        return did_work;
    }

    fn handleChain(self: *Rng, chain: *const queue.Chain) u32 {
        var written: u32 = 0;
        for (chain.segments.slice()) |seg| {
            if (!seg.writable) continue;
            self.fillFn(seg.data);
            saturatingAddLen(&written, seg.data.len);
        }
        return written;
    }
};

fn fillLinux(buf: []u8) void {
    var done: usize = 0;
    while (done < buf.len) {
        const tail = buf[done..];
        const rc = std.os.linux.getrandom(tail.ptr, tail.len, 0);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) @panic("host entropy unavailable");
                done += n;
            },
            .INTR => continue,
            else => @panic("host entropy unavailable"),
        }
    }
}

fn saturatingAddLen(total: *u32, len: usize) void {
    const remaining: usize = @intCast(std.math.maxInt(u32) - total.*);
    total.* += @intCast(@min(len, remaining));
}

// --- tests ------------------------------------------------------------------

fn testFill(buf: []u8) void {
    @memset(buf, 0xA5);
}

fn makeChain(segs: []const queue.Segment) queue.Chain {
    var chain = queue.Chain{ .head = 0, .segments = .{} };
    for (segs) |s| chain.segments.append(s) catch unreachable;
    return chain;
}

test "fills writable descriptors only" {
    var rng = Rng{ .fillFn = testFill };
    var readable: [4]u8 = .{ 1, 2, 3, 4 };
    var out_a: [3]u8 = [_]u8{0} ** 3;
    var out_b: [5]u8 = [_]u8{0} ** 5;

    const chain = makeChain(&.{
        .{ .data = &readable, .writable = false },
        .{ .data = &out_a, .writable = true },
        .{ .data = &out_b, .writable = true },
    });

    try std.testing.expectEqual(@as(u32, 8), rng.handleChain(&chain));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &readable);
    try std.testing.expect(std.mem.allEqual(u8, &out_a, 0xA5));
    try std.testing.expect(std.mem.allEqual(u8, &out_b, 0xA5));
}

test "queue notification returns entropy buffer used" {
    var rng = Rng{ .fillFn = testFill };
    var t = mmio.Transport.init(rng.device());

    var buf: [4096]u8 = [_]u8{0} ** 4096;
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    _ = t.write(0x030, request_queue, ram);
    _ = t.write(0x038, 8, ram);
    _ = t.write(0x080, 0x000, ram); // desc at 0x0
    _ = t.write(0x090, 0x400, ram); // avail at 0x400
    _ = t.write(0x0a0, 0x800, ram); // used at 0x800
    _ = t.write(0x044, 1, ram);

    const data_addr = 0xc00;
    const data_len = 16;
    const flag_write: u16 = 2;
    try ram.write(u64, 0, data_addr);
    try ram.write(u32, 8, data_len);
    try ram.write(u16, 12, flag_write);
    try ram.write(u16, 0x400 + 4, 0); // avail.ring[0] = 0
    try ram.write(u16, 0x400 + 2, 1); // avail.idx = 1

    try std.testing.expect(t.write(0x050, request_queue, ram));
    try std.testing.expect(std.mem.allEqual(u8, buf[data_addr..][0..data_len], 0xA5));
    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, 0x800 + 2));
    try std.testing.expectEqual(@as(u32, data_len), try ram.read(u32, 0x800 + 8));
}

fn fuzzRngQueue(_: void, s: *std.testing.Smith) !void {
    // RNG has no device-specific request header, but queue descriptors and
    // lengths are guest controlled. Notification must never crash or write
    // outside the guest RAM window.
    var rng = Rng{ .fillFn = testFill };
    var t = mmio.Transport.init(rng.device());

    var buf: [4096]u8 = [_]u8{0} ** 4096;
    _ = s.slice(&buf);
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    t.queues[request_queue] = .{ .size = 8, .ready = true, .desc_addr = 0x000, .avail_addr = 0x400, .used_addr = 0x800 };
    ram.write(u16, 0x400 + 2, s.value(u8) % 4) catch {};

    _ = t.write(0x050, request_queue, ram);
}

test "fuzz rng queue handling" {
    try std.testing.fuzz({}, fuzzRngQueue, .{});
}
