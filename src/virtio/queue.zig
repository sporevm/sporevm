//! Virtio split virtqueue (virtio spec 1.2 §2.7), device side.
//!
//! Parses descriptor chains out of guest memory. Everything read here is
//! attacker controlled: descriptor indices, addresses, lengths, and ring
//! indices are all validated, chain walks are loop-bounded, and all guest
//! memory access goes through `guestmem.GuestRam`. See SECURITY.md.

const std = @import("std");
const guestmem = @import("../guestmem.zig");

pub const max_queue_size = 256;
/// Upper bound on descriptors in one chain. Bounds device-side buffering;
/// raise deliberately if a future device needs more.
pub const max_chain_len = 64;

pub const Error = error{
    QueueNotReady,
    BadDescriptorIndex,
    ChainTooLong,
    OutOfBounds,
};

const desc_size = 16;
const flag_next: u16 = 1;
const flag_write: u16 = 2;
const flag_indirect: u16 = 4;

pub const Segment = struct {
    /// Host view of the descriptor's buffer.
    data: []u8,
    /// Guest-physical start of `data`. Used to mark VMM-originated writes
    /// dirty for snapshot paths that rely on hypervisor dirty logs.
    addr: u64 = 0,
    /// Device-writable (VIRTQ_DESC_F_WRITE) or device-readable.
    writable: bool,
};

/// Fixed-capacity segment list (std.BoundedArray was removed in Zig 0.16).
pub const Segments = struct {
    items: [max_chain_len]Segment = undefined,
    len: usize = 0,

    pub fn append(self: *Segments, seg: Segment) error{Overflow}!void {
        if (self.len >= max_chain_len) return error.Overflow;
        self.items[self.len] = seg;
        self.len += 1;
    }

    pub fn slice(self: *const Segments) []const Segment {
        return self.items[0..self.len];
    }

    pub fn get(self: *const Segments, i: usize) Segment {
        return self.items[i];
    }
};

pub const Chain = struct {
    head: u16,
    segments: Segments,

    pub fn readableLen(self: *const Chain) usize {
        var n: usize = 0;
        for (self.segments.slice()) |seg| {
            if (!seg.writable) n += seg.data.len;
        }
        return n;
    }

    pub fn copyReadableRange(self: *const Chain, skip: usize, out: []u8) bool {
        if (out.len == 0) return true;
        var skipped: usize = 0;
        var copied: usize = 0;
        for (self.segments.slice()) |seg| {
            if (seg.writable) continue;
            if (skipped + seg.data.len <= skip) {
                skipped += seg.data.len;
                continue;
            }
            const offset = if (skip > skipped) skip - skipped else 0;
            const readable = seg.data[offset..];
            const n = @min(readable.len, out.len - copied);
            @memcpy(out[copied..][0..n], readable[0..n]);
            copied += n;
            if (copied == out.len) return true;
            skipped += seg.data.len;
        }
        return false;
    }

    pub fn markWritableDirty(self: *const Chain, ram: guestmem.GuestRam) void {
        for (self.segments.slice()) |seg| {
            if (!seg.writable) continue;
            ram.markDirty(seg.addr, @intCast(seg.data.len));
        }
    }
};

pub const VirtQueue = struct {
    /// Queue size negotiated by the driver. 0 until configured.
    size: u16 = 0,
    ready: bool = false,
    desc_addr: u64 = 0,
    avail_addr: u64 = 0,
    used_addr: u64 = 0,
    last_avail: u16 = 0,
    used_idx: u16 = 0,

    pub fn reset(self: *VirtQueue) void {
        self.* = .{};
    }

    /// Pop the next available descriptor chain, or null when the ring is
    /// empty. The returned segments alias guest RAM directly.
    pub fn popAvail(self: *VirtQueue, ram: guestmem.GuestRam) Error!?Chain {
        if (!self.ready or self.size == 0) return error.QueueNotReady;

        const avail_idx = ram.read(u16, self.avail_addr + 2) catch return error.OutOfBounds;
        if (avail_idx == self.last_avail) return null;

        const slot = self.last_avail % self.size;
        const head = ram.read(u16, self.avail_addr + 4 + 2 * @as(u64, slot)) catch return error.OutOfBounds;
        self.last_avail +%= 1;

        var chain = Chain{ .head = head, .segments = .{} };
        var idx = head;
        var hops: usize = 0;
        while (true) {
            if (idx >= self.size) return error.BadDescriptorIndex;
            if (hops >= max_chain_len) return error.ChainTooLong;
            hops += 1;

            const base = self.desc_addr + desc_size * @as(u64, idx);
            const addr = ram.read(u64, base) catch return error.OutOfBounds;
            const len = ram.read(u32, base + 8) catch return error.OutOfBounds;
            const flags = ram.read(u16, base + 12) catch return error.OutOfBounds;
            const next = ram.read(u16, base + 14) catch return error.OutOfBounds;

            // Indirect descriptors are not offered as a feature; reject.
            if (flags & flag_indirect != 0) return error.BadDescriptorIndex;

            const data = ram.slice(addr, len) catch return error.OutOfBounds;
            chain.segments.append(.{
                .data = data,
                .addr = addr,
                .writable = flags & flag_write != 0,
            }) catch return error.ChainTooLong;

            if (flags & flag_next == 0) break;
            idx = next;
        }
        return chain;
    }

    /// Return a completed chain to the used ring. `written` is the number of
    /// bytes the device wrote into device-writable segments.
    pub fn pushUsed(self: *VirtQueue, ram: guestmem.GuestRam, head: u16, written: u32) Error!void {
        if (!self.ready or self.size == 0) return error.QueueNotReady;
        const slot = self.used_idx % self.size;
        const elem = self.used_addr + 4 + 8 * @as(u64, slot);
        ram.write(u32, elem, head) catch return error.OutOfBounds;
        ram.write(u32, elem + 4, written) catch return error.OutOfBounds;
        self.used_idx +%= 1;
        ram.write(u16, self.used_addr + 2, self.used_idx) catch return error.OutOfBounds;
    }
};

// --- test helpers -----------------------------------------------------------

const TestRing = struct {
    buf: [4096]u8 = [_]u8{0} ** 4096,
    q: VirtQueue,

    const desc_base: u64 = 0;
    const avail_base: u64 = 0x400;
    const used_base: u64 = 0x800;
    const data_base: u64 = 0xc00;

    fn init(size: u16) TestRing {
        return .{ .q = .{
            .size = size,
            .ready = true,
            .desc_addr = desc_base,
            .avail_addr = avail_base,
            .used_addr = used_base,
        } };
    }

    fn ram(self: *TestRing) guestmem.GuestRam {
        return .{ .bytes = &self.buf, .base = 0 };
    }

    fn setDesc(self: *TestRing, i: u16, addr: u64, len: u32, flags: u16, next: u16) void {
        const r = self.ram();
        const base = desc_base + desc_size * @as(u64, i);
        r.write(u64, base, addr) catch unreachable;
        r.write(u32, base + 8, len) catch unreachable;
        r.write(u16, base + 12, flags) catch unreachable;
        r.write(u16, base + 14, next) catch unreachable;
    }

    fn pushAvail(self: *TestRing, head: u16) void {
        const r = self.ram();
        const idx = r.read(u16, avail_base + 2) catch unreachable;
        r.write(u16, avail_base + 4 + 2 * @as(u64, idx % self.q.size), head) catch unreachable;
        r.write(u16, avail_base + 2, idx +% 1) catch unreachable;
    }
};

const DirtyProbe = struct {
    ranges: [8]Range = undefined,
    len: usize = 0,

    const Range = struct { gpa: u64, len: u64 };

    fn mark(ctx: *anyopaque, gpa: u64, len: u64) void {
        const self: *DirtyProbe = @ptrCast(@alignCast(ctx));
        if (self.len < self.ranges.len) {
            self.ranges[self.len] = .{ .gpa = gpa, .len = len };
        }
        self.len += 1;
    }

    fn saw(self: *const DirtyProbe, gpa: u64, len: u64) bool {
        const n = @min(self.len, self.ranges.len);
        for (self.ranges[0..n]) |r| {
            if (r.gpa == gpa and r.len == len) return true;
        }
        return false;
    }
};

test "pop single descriptor chain" {
    var t = TestRing.init(8);
    t.setDesc(0, TestRing.data_base, 4, 0, 0);
    t.buf[TestRing.data_base..][0..4].* = "ping".*;
    t.pushAvail(0);

    const chain = (try t.q.popAvail(t.ram())).?;
    try std.testing.expectEqual(@as(u16, 0), chain.head);
    try std.testing.expectEqual(@as(usize, 1), chain.segments.len);
    try std.testing.expectEqualStrings("ping", chain.segments.get(0).data);
    try std.testing.expect(!chain.segments.get(0).writable);

    // Ring now empty.
    try std.testing.expectEqual(@as(?Chain, null), try t.q.popAvail(t.ram()));
}

test "chained descriptors preserve order and flags" {
    var t = TestRing.init(8);
    t.setDesc(2, TestRing.data_base, 2, flag_next, 5);
    t.setDesc(5, TestRing.data_base + 2, 3, flag_write, 0);
    t.pushAvail(2);

    const chain = (try t.q.popAvail(t.ram())).?;
    try std.testing.expectEqual(@as(usize, 2), chain.segments.len);
    try std.testing.expect(!chain.segments.get(0).writable);
    try std.testing.expect(chain.segments.get(1).writable);
    try std.testing.expectEqual(@as(usize, 2), chain.readableLen());
}

test "copy readable range spans readable descriptors and skips writable descriptors" {
    var first = [_]u8{ 'a', 'b' };
    var writable = [_]u8{ 'x', 'x' };
    var second = [_]u8{ 'c', 'd', 'e' };
    var chain = Chain{ .head = 0, .segments = .{} };
    try chain.segments.append(.{ .data = &first, .writable = false });
    try chain.segments.append(.{ .data = &writable, .writable = true });
    try chain.segments.append(.{ .data = &second, .writable = false });

    var out: [4]u8 = undefined;
    try std.testing.expect(chain.copyReadableRange(1, &out));
    try std.testing.expectEqualStrings("bcde", &out);
    try std.testing.expect(!chain.copyReadableRange(5, out[0..1]));
}

test "descriptor loop is bounded" {
    var t = TestRing.init(8);
    t.setDesc(0, TestRing.data_base, 1, flag_next, 1);
    t.setDesc(1, TestRing.data_base, 1, flag_next, 0); // 0 -> 1 -> 0 -> ...
    t.pushAvail(0);
    try std.testing.expectError(error.ChainTooLong, t.q.popAvail(t.ram()));
}

test "hostile descriptor fields are rejected" {
    // Descriptor index out of range.
    var t = TestRing.init(8);
    t.setDesc(0, TestRing.data_base, 1, flag_next, 200);
    t.pushAvail(0);
    try std.testing.expectError(error.BadDescriptorIndex, t.q.popAvail(t.ram()));

    // Buffer escaping guest RAM.
    var t2 = TestRing.init(8);
    t2.setDesc(0, 0xffff_0000, 16, 0, 0);
    t2.pushAvail(0);
    try std.testing.expectError(error.OutOfBounds, t2.q.popAvail(t2.ram()));

    // Length overflowing the region.
    var t3 = TestRing.init(8);
    t3.setDesc(0, TestRing.data_base, 0xffff_ffff, 0, 0);
    t3.pushAvail(0);
    try std.testing.expectError(error.OutOfBounds, t3.q.popAvail(t3.ram()));

    // Indirect flag rejected (feature not offered).
    var t4 = TestRing.init(8);
    t4.setDesc(0, TestRing.data_base, 16, flag_indirect, 0);
    t4.pushAvail(0);
    try std.testing.expectError(error.BadDescriptorIndex, t4.q.popAvail(t4.ram()));
}

test "used ring round-trip" {
    var t = TestRing.init(8);
    t.setDesc(3, TestRing.data_base, 4, flag_write, 0);
    t.pushAvail(3);
    const chain = (try t.q.popAvail(t.ram())).?;
    try t.q.pushUsed(t.ram(), chain.head, 4);

    const r = t.ram();
    try std.testing.expectEqual(@as(u16, 1), try r.read(u16, TestRing.used_base + 2));
    try std.testing.expectEqual(@as(u32, 3), try r.read(u32, TestRing.used_base + 4));
    try std.testing.expectEqual(@as(u32, 4), try r.read(u32, TestRing.used_base + 8));
}

test "VMM writes can mark descriptor buffers and used ring dirty" {
    var t = TestRing.init(8);
    t.setDesc(3, TestRing.data_base, 4, flag_write, 0);
    t.pushAvail(3);
    const chain = (try t.q.popAvail(t.ram())).?;

    var probe = DirtyProbe{};
    const ram = guestmem.GuestRam{ .bytes = &t.buf, .base = 0, .dirty_context = &probe, .dirty_fn = DirtyProbe.mark };
    chain.markWritableDirty(ram);
    try t.q.pushUsed(ram, chain.head, 4);

    try std.testing.expect(probe.saw(TestRing.data_base, 4));
    try std.testing.expect(probe.saw(TestRing.used_base + 4, 4));
    try std.testing.expect(probe.saw(TestRing.used_base + 8, 4));
    try std.testing.expect(probe.saw(TestRing.used_base + 2, 2));
}

test "not-ready queue is rejected" {
    var t = TestRing.init(8);
    t.q.ready = false;
    try std.testing.expectError(error.QueueNotReady, t.q.popAvail(t.ram()));
}

fn fuzzPop(_: void, s: *std.testing.Smith) !void {
    // Treat fuzz input as raw guest memory: rings and descriptors are fully
    // attacker controlled. popAvail must never crash, hang, or touch memory
    // outside the provided region.
    var buf: [4096]u8 = [_]u8{0} ** 4096;
    _ = s.slice(&buf);
    var q = VirtQueue{
        .size = 8,
        .ready = true,
        .desc_addr = 0,
        .avail_addr = 0x400,
        .used_addr = 0x800,
    };
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };
    var budget: usize = 32;
    while (budget > 0) : (budget -= 1) {
        const chain = q.popAvail(ram) catch break;
        if (chain == null) break;
    }
}

test "fuzz virtqueue parsing" {
    try std.testing.fuzz({}, fuzzPop, .{});
}
