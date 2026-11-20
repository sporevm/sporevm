//! Passive free-page reporting only (virtio 1.2 §5.5). Capacity never changes.
//! The runner parks all vCPUs and drains disk workers before calling process.
//! A report is authority only until its used-ring acknowledgement.
const std = @import("std");
const guestmem = @import("../guestmem.zig");
const mmio = @import("mmio.zig");
const queue = @import("queue.zig");

pub const device_id: u32 = 5;
pub const feature_reporting: u64 = 1 << 5;
pub const reclaim_alignment: u64 = 2 * 1024 * 1024;
// Linux virtio_balloon.c:init_vqs uses array slot 4 for reporting, but leaves
// absent stats/hint names NULL. virtio_mmio.c:vm_find_vqs skips NULL names and
// passes a consecutive queue_idx to vm_setup_vq: the physical queue is 2.
// See docs/memory.md for the managed kernel's source references.
pub const reporting_queue = 2;

pub const Balloon = struct {
    reporting: bool = false,
    returned_bytes: u64 = 0,

    pub fn device(self: *Balloon) mmio.Device {
        return .{
            .context = self,
            .device_id = device_id,
            .device_features = feature_reporting,
            .queue_count = 3,
            .notifyFn = notify,
            .featuresAcceptedFn = accept,
        };
    }

    fn accept(ctx: *anyopaque, features: u64) void {
        const self: *Balloon = @ptrCast(@alignCast(ctx));
        self.reporting = features & feature_reporting != 0;
    }

    fn notify(_: *anyopaque, _: u8, _: *[mmio.max_queues]queue.VirtQueue, _: guestmem.GuestRam) bool {
        // Never replace RAM on a vCPU thread: other vCPUs and disk workers
        // may still hold pointers into the mapping.
        return false;
    }

    pub fn hasPending(self: *const Balloon, transport: *const mmio.Transport, ram: guestmem.GuestRam) bool {
        if (!self.reporting or transport.status & mmio.status_driver_ok == 0) return false;
        const q = &transport.queues[reporting_queue];
        if (!q.ready) return false;
        const available = ram.read(u16, q.avail_addr + 2) catch return false;
        return available != q.last_avail;
    }

    /// Caller holds the device lock with vCPUs and disk workers parked.
    /// reclaim(ctx, gpa, len) must replace the range with private zero RAM,
    /// and synchronize with any background checkpoint sealer. mapped_size
    /// excludes reserved hotplug RAM not yet mapped into the guest.
    pub fn process(self: *Balloon, transport: *mmio.Transport, ram: guestmem.GuestRam, mapped_size: u64, ctx: anytype, comptime reclaim: anytype) !bool {
        if (!self.hasPending(transport, ram)) return false;
        const mapped_ram = guestmem.GuestRam{ .bytes = ram.bytes[0..@intCast(mapped_size)], .base = ram.base };
        const q = &transport.queues[reporting_queue];
        var budget: queue.NotifyBudget = .{};
        var completed = false;
        while (budget.hasRemaining()) {
            const chain = (q.popAvail(ram) catch break) orelse break;
            budget.consume();
            // Validate the whole copied chain before touching any backing.
            // Linux uses device-writable descriptors for page reporting.
            var valid = true;
            for (chain.segments.slice()) |seg| {
                if (!seg.writable) valid = false;
                _ = mapped_ram.slice(seg.addr, seg.data.len) catch {
                    valid = false;
                    continue;
                };
            }
            if (valid) for (chain.segments.slice()) |seg| {
                if (seg.data.len < reclaim_alignment) continue;
                const start = std.mem.alignForward(u64, seg.addr, reclaim_alignment);
                const end = std.mem.alignBackward(u64, seg.addr + seg.data.len, reclaim_alignment);
                if (start >= end) continue;
                try reclaim(ctx, start, end - start);
                self.returned_bytes +|= end - start;
            };
            try q.pushUsed(ram, chain.head, 0);
            completed = true;
        }
        if (completed) transport.interrupt_status |= 1;
        return completed;
    }
};

const TestReturn = struct {
    ram: guestmem.GuestRam,
    bytes: u64 = 0,

    fn reclaim(self: *TestReturn, gpa: u64, len: u64) !void {
        try std.testing.expectEqual(@as(u64, 0), gpa % reclaim_alignment);
        try std.testing.expectEqual(@as(u64, 0), len % reclaim_alignment);
        @memset(try self.ram.slice(gpa, len), 0);
        self.bytes += len;
    }
};

fn testQueue(transport: *mmio.Transport, ram: guestmem.GuestRam, addr: u64, len: u32, flags: u16) !void {
    try transport.applyRestoredFeatureState(mmio.status_features_ok | mmio.status_driver_ok, mmio.f_version_1 | feature_reporting);
    transport.queues[reporting_queue] = .{ .size = 8, .ready = true, .desc_addr = ram.base, .avail_addr = ram.base + 0x400, .used_addr = ram.base + 0x800 };
    try ram.write(u64, ram.base, addr);
    try ram.write(u32, ram.base + 8, len);
    try ram.write(u16, ram.base + 12, flags);
    try ram.write(u16, ram.base + 14, 1);
    try ram.write(u16, ram.base + 0x402, 1);
    try ram.write(u16, ram.base + 0x404, 0);
}

test "reports return only complete aligned pages and expire at acknowledgement" {
    const bytes = try std.testing.allocator.alloc(u8, 4 * reclaim_alignment);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0xa7);
    const ram = guestmem.GuestRam{ .bytes = bytes, .base = 0 };
    var device: Balloon = .{};
    var transport = mmio.Transport.init(device.device());
    var returned = TestReturn{ .ram = ram };
    // Covers [2 MiB - 4 KiB, 6 MiB + 4 KiB). Rounding outward
    // would corrupt both guards; rejecting partial ends would miss 4 MiB.
    try testQueue(&transport, ram, reclaim_alignment - 4096, 2 * reclaim_alignment + 8192, 2);
    try std.testing.expect(!(transport.write(0x050, reporting_queue, ram)));
    try std.testing.expectEqual(@as(u8, 0xa7), bytes[reclaim_alignment]);
    try std.testing.expect(try device.process(&transport, ram, ram.bytes.len, &returned, TestReturn.reclaim));
    try std.testing.expectEqual(@as(u64, 2 * reclaim_alignment), returned.bytes);
    try std.testing.expect(std.mem.allEqual(u8, bytes[reclaim_alignment .. 3 * reclaim_alignment], 0));
    try std.testing.expectEqual(@as(u8, 0xa7), bytes[reclaim_alignment - 1]);
    try std.testing.expectEqual(@as(u8, 0xa7), bytes[3 * reclaim_alignment]);
    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, 0x802));
    bytes[reclaim_alignment] = 0x51;
    try std.testing.expect(!try device.process(&transport, ram, ram.bytes.len, &returned, TestReturn.reclaim));
    try std.testing.expectEqual(@as(u8, 0x51), bytes[reclaim_alignment]);
    _ = transport.write(0x070, 0, ram);
    try std.testing.expect(!device.reporting);
}

test "mixed direction and malformed trailing descriptors cannot partially reclaim" {
    const bytes = try std.testing.allocator.alloc(u8, 2 * reclaim_alignment);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0x6b);
    const ram = guestmem.GuestRam{ .bytes = bytes, .base = 0 };
    var device: Balloon = .{};
    var transport = mmio.Transport.init(device.device());
    var returned = TestReturn{ .ram = ram };
    try testQueue(&transport, ram, reclaim_alignment, reclaim_alignment, 3);
    try ram.write(u64, 16, reclaim_alignment);
    try ram.write(u32, 24, 4096);
    try ram.write(u16, 28, 0); // readable tail invalidates the entire chain
    _ = try device.process(&transport, ram, ram.bytes.len, &returned, TestReturn.reclaim);
    try std.testing.expectEqual(@as(u64, 0), returned.bytes);
    try std.testing.expect(std.mem.allEqual(u8, bytes[reclaim_alignment..], 0x6b));
    try testQueue(&transport, ram, reclaim_alignment, reclaim_alignment, 3);
    try ram.write(u64, 16, std.math.maxInt(u64));
    try ram.write(u16, 28, 2); // out-of-bounds tail fails parsing
    _ = try device.process(&transport, ram, ram.bytes.len, &returned, TestReturn.reclaim);
    try std.testing.expectEqual(@as(u64, 0), returned.bytes);
}

test "unmapped elastic tails invalidate whole reports but are acknowledged" {
    const bytes = try std.testing.allocator.alloc(u8, 4 * reclaim_alignment);
    defer std.testing.allocator.free(bytes);
    const ram = guestmem.GuestRam{ .bytes = bytes, .base = 0 };
    const Case = struct { start: u64, size: u32, mapped: u64, returned: u64, mixed: bool = false };
    const cases = [_]Case{
        .{ .start = 2 * reclaim_alignment, .size = reclaim_alignment, .mapped = 2 * reclaim_alignment, .returned = 0 },
        .{ .start = 2 * reclaim_alignment, .size = reclaim_alignment, .mapped = 3 * reclaim_alignment, .returned = reclaim_alignment },
        .{ .start = 3 * reclaim_alignment, .size = reclaim_alignment, .mapped = 3 * reclaim_alignment, .returned = 0 },
        .{ .start = 2 * reclaim_alignment, .size = 2 * reclaim_alignment, .mapped = 3 * reclaim_alignment, .returned = 0 },
        .{ .start = reclaim_alignment, .size = reclaim_alignment, .mapped = 3 * reclaim_alignment, .returned = 0, .mixed = true },
    };
    for (cases) |case| {
        @memset(bytes, 0x6b);
        var device: Balloon = .{};
        var transport = mmio.Transport.init(device.device());
        var returned = TestReturn{ .ram = ram };
        try testQueue(&transport, ram, case.start, case.size, if (case.mixed) 3 else 2);
        if (case.mixed) {
            try ram.write(u64, 16, 3 * reclaim_alignment);
            try ram.write(u32, 24, reclaim_alignment);
            try ram.write(u16, 28, 2);
        }
        try std.testing.expect(try device.process(&transport, ram, case.mapped, &returned, TestReturn.reclaim));
        try std.testing.expectEqual(case.returned, returned.bytes);
        try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, 0x802));
        try std.testing.expect(!device.hasPending(&transport, ram));
        if (case.returned == 0) try std.testing.expect(std.mem.allEqual(u8, bytes[reclaim_alignment..], 0x6b));
    }
}

fn fuzzReports(_: void, smith: *std.testing.Smith) !void {
    const bytes = try std.testing.allocator.alloc(u8, 4 * reclaim_alignment);
    defer std.testing.allocator.free(bytes);
    @memset(bytes[0..4096], 0);
    const ram = guestmem.GuestRam{ .bytes = bytes, .base = 0 };
    var device: Balloon = .{};
    var transport = mmio.Transport.init(device.device());
    const addr = smith.value(u64);
    const len = smith.value(u32);
    const flags = smith.value(u16) & ~@as(u16, 1);
    // Alternate raw hostile addresses with in-bounds, large reports so
    // fuzzing exercises successful reclaim as well as parser rejection.
    const start = if (smith.value(bool)) addr % reclaim_alignment + reclaim_alignment else addr;
    const size: u32 = if (smith.value(bool)) @intCast(len % (2 * reclaim_alignment) + reclaim_alignment) else len;
    const mapped_size = @as(u64, smith.value(u8) % 5) * reclaim_alignment;
    try testQueue(&transport, ram, start, size, flags);
    const Probe = struct {
        start: u64,
        size: u64,
        flags: u16,
        bytes: u64 = 0,
        fn reclaim(self: *@This(), gpa: u64, count: u64) !void {
            try std.testing.expectEqual(@as(u16, 2), self.flags & 7);
            try std.testing.expect(gpa >= self.start and count <= self.size and gpa - self.start <= self.size - count);
            try std.testing.expectEqual(@as(u64, 0), (gpa | count) % reclaim_alignment);
            self.bytes += count;
        }
    };
    var probe = Probe{ .start = start, .size = size, .flags = flags };
    _ = try device.process(&transport, ram, mapped_size, &probe, Probe.reclaim);
    // Independent oracle: enumerate RAM blocks, rather than duplicating
    // the implementation's inward-rounding calculation.
    var expected: u64 = 0;
    if (start < mapped_size and size <= mapped_size - start and flags & 6 == 2) {
        for (0..4) |block| {
            const gpa = block * reclaim_alignment;
            if (start <= gpa and size >= reclaim_alignment and gpa - start <= size - reclaim_alignment) expected += reclaim_alignment;
        }
    }
    try std.testing.expectEqual(expected, probe.bytes);
}

test "fuzz free-page reports" {
    const aligned = std.mem.toBytes([_]u64{ reclaim_alignment, reclaim_alignment, 2, 0, 0, 4 });
    const unaligned = std.mem.toBytes([_]u64{ reclaim_alignment - 4096, 2 * reclaim_alignment + 8192, 2, 0, 0, 4 });
    const overflow = std.mem.toBytes([_]u64{ std.math.maxInt(u64), std.math.maxInt(u32), 2, 0, 0, 4 });
    const indirect = std.mem.toBytes([_]u64{ reclaim_alignment, reclaim_alignment, 6, 0, 0, 4 });
    const unmapped = std.mem.toBytes([_]u64{ 2 * reclaim_alignment, reclaim_alignment, 2, 0, 0, 2 });
    const boundary = std.mem.toBytes([_]u64{ 2 * reclaim_alignment, reclaim_alignment, 2, 0, 0, 3 });
    try std.testing.fuzz({}, fuzzReports, .{ .corpus = &.{ &aligned, &unaligned, &overflow, &indirect, &unmapped, &boundary } });
}
