//! Virtio split virtqueue (virtio spec 1.2 §2.7), device side.
//!
//! Parses descriptor chains out of guest memory. Everything read here is
//! attacker controlled: descriptor indices, addresses, lengths, and ring
//! indices are all validated, chain walks are loop-bounded, and all guest
//! memory access goes through `guestmem.GuestRam`. See SECURITY.md.

const std = @import("std");
const guestmem = @import("../guestmem.zig");

pub const max_queue_size = 256;
/// Maximum descriptor chains a device notification may consume before
/// returning to the VMM loop.
pub const max_notify_chains = max_queue_size;
/// Upper bound on descriptors in one chain. Bounds device-side buffering;
/// raise deliberately if a future device needs more.
pub const max_chain_len = 64;

pub const Error = error{
    QueueNotReady,
    InvalidQueueSize,
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

pub const NotifyBudget = struct {
    remaining: usize = max_notify_chains,

    pub fn hasRemaining(self: *const NotifyBudget) bool {
        return self.remaining != 0;
    }

    pub fn consume(self: *NotifyBudget) void {
        std.debug.assert(self.remaining != 0);
        self.remaining -= 1;
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

    pub fn validateLayout(self: *const VirtQueue) Error!void {
        if (self.size > max_queue_size) return error.InvalidQueueSize;
        if (!self.ready or self.size == 0) return;

        const qsz: u64 = self.size;
        _ = try checkedAdd(self.desc_addr, try checkedMul(desc_size, qsz));
        _ = try checkedAdd(self.avail_addr, try checkedAdd(4, try checkedMul(2, qsz)));
        _ = try checkedAdd(self.used_addr, try checkedAdd(4, try checkedMul(8, qsz)));
    }

    /// Pop the next available descriptor chain, or null when the ring is
    /// empty. The returned segments alias guest RAM directly.
    pub fn popAvail(self: *VirtQueue, ram: guestmem.GuestRam) Error!?Chain {
        if (!self.ready or self.size == 0) return error.QueueNotReady;
        try self.validateLayout();

        const avail_idx = ram.read(u16, try availIdxAddr(self.avail_addr)) catch return error.OutOfBounds;
        if (avail_idx == self.last_avail) return null;

        const slot = self.last_avail % self.size;
        const head = ram.read(u16, try availRingAddr(self.avail_addr, slot)) catch return error.OutOfBounds;
        self.last_avail +%= 1;

        var chain = Chain{ .head = head, .segments = .{} };
        var idx = head;
        var hops: usize = 0;
        while (true) {
            if (idx >= self.size) return error.BadDescriptorIndex;
            if (hops >= max_chain_len) return error.ChainTooLong;
            hops += 1;

            const base = try descAddr(self.desc_addr, idx);
            const addr = ram.read(u64, base) catch return error.OutOfBounds;
            const len = ram.read(u32, try descFieldAddr(base, 8)) catch return error.OutOfBounds;
            const flags = ram.read(u16, try descFieldAddr(base, 12)) catch return error.OutOfBounds;
            const next = ram.read(u16, try descFieldAddr(base, 14)) catch return error.OutOfBounds;

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
        try self.validateLayout();

        const slot = self.used_idx % self.size;
        const elem = try usedRingAddr(self.used_addr, slot);
        ram.write(u32, elem, head) catch return error.OutOfBounds;
        ram.write(u32, try checkedAdd(elem, 4), written) catch return error.OutOfBounds;
        self.used_idx +%= 1;
        ram.write(u16, try usedIdxAddr(self.used_addr), self.used_idx) catch return error.OutOfBounds;
    }
};

pub fn availIdxAddr(avail_addr: u64) Error!u64 {
    return checkedAdd(avail_addr, 2);
}

pub fn availRingAddr(avail_addr: u64, slot: u16) Error!u64 {
    return ringAddr(avail_addr, 4, 2, slot);
}

pub fn descAddr(desc_addr: u64, idx: u16) Error!u64 {
    return ringAddr(desc_addr, 0, desc_size, idx);
}

pub fn descFieldAddr(desc_base: u64, offset: u64) Error!u64 {
    return checkedAdd(desc_base, offset);
}

pub fn usedIdxAddr(used_addr: u64) Error!u64 {
    return checkedAdd(used_addr, 2);
}

pub fn usedRingAddr(used_addr: u64, slot: u16) Error!u64 {
    return ringAddr(used_addr, 4, 8, slot);
}

fn ringAddr(base: u64, header: u64, elem_size: u64, slot: u16) Error!u64 {
    const elem_off = try checkedMul(elem_size, slot);
    const offset = try checkedAdd(header, elem_off);
    return checkedAdd(base, offset);
}

fn checkedAdd(a: u64, b: u64) Error!u64 {
    return std.math.add(u64, a, b) catch error.OutOfBounds;
}

fn checkedMul(a: u64, b: u64) Error!u64 {
    return std.math.mul(u64, a, b) catch error.OutOfBounds;
}

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

test "notify budget caps per-notification chain work" {
    var budget = NotifyBudget{ .remaining = 2 };
    try std.testing.expect(budget.hasRemaining());
    budget.consume();
    try std.testing.expect(budget.hasRemaining());
    budget.consume();
    try std.testing.expect(!budget.hasRemaining());
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

test "overflowing queue ring addresses fail closed" {
    var avail = TestRing.init(8);
    avail.q.avail_addr = std.math.maxInt(u64);
    try std.testing.expectError(error.OutOfBounds, avail.q.popAvail(avail.ram()));

    var desc = TestRing.init(8);
    desc.q.desc_addr = std.math.maxInt(u64);
    try std.testing.expectError(error.OutOfBounds, desc.q.popAvail(desc.ram()));

    var used = TestRing.init(8);
    used.q.used_addr = std.math.maxInt(u64);
    try std.testing.expectError(error.OutOfBounds, used.q.pushUsed(used.ram(), 0, 0));
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
