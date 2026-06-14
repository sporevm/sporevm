//! HVF lazy RAM materialization using unmapped guest-memory exits.
//!
//! On resume, the backend may leave guest RAM unmapped in Hypervisor.framework.
//! An instruction/data-abort exit inside the guest RAM window then materializes
//! the matching verified spore memory chunk into the VMM-owned host mapping and
//! maps that chunk into HVF. This is intentionally single-vCPU and synchronous
//! with the run loop; readahead and richer pager error propagation are later
//! work.

const std = @import("std");
const board = @import("../board.zig");
const guestmem = @import("../guestmem.zig");
const hvf = @import("hvf.zig");
const snapshot = @import("snapshot.zig");
const spore = @import("../spore.zig");
const virtqueue = @import("../virtio/queue.zig");

const desc_size: usize = 16;
const flag_next: u16 = 1;
const flag_indirect: u16 = 4;

pub const Options = struct {
    dir: []const u8,
    manifest: spore.MemoryManifest,
    ram: []align(std.heap.page_size_min) u8,
    trace_fd: ?std.c.fd_t = null,
};

pub const Pager = struct {
    allocator: std.mem.Allocator,
    dir: []const u8,
    manifest: spore.MemoryManifest,
    ram: []align(std.heap.page_size_min) u8,
    mapped: []bool,
    trace_fd: ?std.c.fd_t,
    start_ms: u64,

    pub fn start(allocator: std.mem.Allocator, options: Options) !Pager {
        try validateMapping(options.ram);
        _ = try spore.validateMemoryForRam(options.manifest, options.ram.len);

        const mapped = try allocator.alloc(bool, options.manifest.chunks.len);
        errdefer allocator.free(mapped);
        @memset(mapped, false);

        std.log.info("hvf lazy RAM pager armed: bytes={d} chunks={d}", .{ options.ram.len, options.manifest.chunks.len });
        return .{
            .allocator = allocator,
            .dir = options.dir,
            .manifest = options.manifest,
            .ram = options.ram,
            .mapped = mapped,
            .trace_fd = options.trace_fd,
            .start_ms = monotonicMs(),
        };
    }

    pub fn deinit(self: *Pager) void {
        for (self.mapped, 0..) |is_mapped, index| {
            if (!is_mapped) continue;
            const range = spore.memoryChunkRange(self.manifest, self.ram.len, index) catch continue;
            _ = hvf.hv_vm_unmap(board.ram_base + range.start, range.end - range.start);
        }
        self.allocator.free(self.mapped);
    }

    pub fn isRamFault(self: *const Pager, ipa: hvf.Ipa) bool {
        const ram_end = board.ram_base + @as(u64, @intCast(self.ram.len));
        return ipa >= board.ram_base and ipa < ram_end;
    }

    pub fn materializeFault(self: *Pager, ipa: hvf.Ipa) !void {
        if (!self.isRamFault(ipa)) return error.BadManifest;
        const offset: usize = @intCast(ipa - board.ram_base);
        const index = offset / spore.chunk_size;
        try self.materializeIndex(index, true);
    }

    pub fn materializeGuestRange(self: *Pager, guest_addr: u64, len: usize) !void {
        if (len == 0) return;
        if (guest_addr < board.ram_base) return error.BadManifest;
        const start_u64 = guest_addr - board.ram_base;
        if (start_u64 > self.ram.len) return error.BadManifest;
        const range_start: usize = @intCast(start_u64);
        if (len > self.ram.len - range_start) return error.BadManifest;

        var index = range_start / spore.chunk_size;
        const last = (range_start + len - 1) / spore.chunk_size;
        while (index <= last) : (index += 1) {
            try self.materializeIndex(index, false);
        }
    }

    /// Materialize all RAM the VMM may touch while servicing currently pending
    /// descriptor chains. Unlike KVM/userfaultfd, host-side HVF device
    /// emulation reads and writes the VMM-owned mapping directly, so it must
    /// pull those chunks through the pager before calling device code.
    pub fn materializeVirtQueue(self: *Pager, q: virtqueue.VirtQueue) !void {
        if (!q.ready or q.size == 0) return;
        if (q.size > virtqueue.max_queue_size) return error.BadManifest;

        const qsz: usize = q.size;
        try self.materializeGuestRange(q.desc_addr, qsz * desc_size);
        try self.materializeGuestRange(q.avail_addr, 6 + qsz * 2);
        try self.materializeGuestRange(q.used_addr, 6 + qsz * 8);

        const ram = guestmem.GuestRam{ .bytes = self.ram, .base = board.ram_base };
        const avail_idx = ram.read(u16, q.avail_addr + 2) catch return error.BadManifest;
        var cur = q.last_avail;
        var budget: usize = virtqueue.max_queue_size;
        while (cur != avail_idx) {
            if (budget == 0) return error.BadManifest;
            const slot = cur % q.size;
            const head = ram.read(u16, q.avail_addr + 4 + 2 * @as(u64, slot)) catch return error.BadManifest;
            try self.materializeDescriptorChain(ram, q, head);
            cur +%= 1;
            budget -= 1;
        }
    }

    fn materializeIndex(self: *Pager, index: usize, trace: bool) !void {
        if (index >= self.mapped.len) return error.BadManifest;
        if (self.mapped[index]) return;

        const range = try spore.memoryChunkRange(self.manifest, self.ram.len, index);
        const len = range.end - range.start;
        if (len == 0 or len % std.heap.page_size_min != 0) return error.BadManifest;

        const chunk = self.ram[range.start..range.end];
        if (self.manifest.chunks[index] == null) {
            @memset(chunk, 0);
        } else {
            try spore.loadMemoryChunk(self.allocator, self.dir, self.manifest, self.ram.len, index, chunk);
        }

        try hvf.check(
            hvf.hv_vm_map(chunk.ptr, board.ram_base + range.start, chunk.len, hvf.MemoryFlags.rwx),
            "hvf lazy RAM map chunk",
        );
        self.mapped[index] = true;
        if (trace) try writeTrace(self, index, range, len);
    }

    fn materializeDescriptorChain(self: *Pager, ram: guestmem.GuestRam, q: virtqueue.VirtQueue, head: u16) !void {
        var idx = head;
        var hops: usize = 0;
        while (true) {
            if (idx >= q.size) return error.BadManifest;
            if (hops >= virtqueue.max_chain_len) return error.BadManifest;
            hops += 1;

            const base = try checkedAdd(q.desc_addr, @as(u64, desc_size) * @as(u64, idx));
            const addr = ram.read(u64, base) catch return error.BadManifest;
            const len = ram.read(u32, base + 8) catch return error.BadManifest;
            const flags = ram.read(u16, base + 12) catch return error.BadManifest;
            const next = ram.read(u16, base + 14) catch return error.BadManifest;

            if (flags & flag_indirect != 0) return error.BadManifest;
            try self.materializeGuestRange(addr, @intCast(len));

            if (flags & flag_next == 0) break;
            idx = next;
        }
    }
};

fn checkedAdd(a: u64, b: u64) !u64 {
    if (std.math.maxInt(u64) - a < b) return error.BadManifest;
    return a + b;
}

fn validateMapping(ram: []const u8) !void {
    const page_size = std.heap.page_size_min;
    if (ram.len == 0) return error.BadManifest;
    if (@intFromPtr(ram.ptr) % page_size != 0) return error.BadManifest;
    if (ram.len % page_size != 0) return error.BadManifest;
    if (spore.chunk_size % page_size != 0) return error.BadManifest;
}

fn writeTrace(pager: *const Pager, index: usize, range: spore.MemoryChunkRange, len: usize) !void {
    const fd = pager.trace_fd orelse return;
    const now = monotonicMs();
    const fault_ms = if (now >= pager.start_ms) now - pager.start_ms else 0;
    const nonzero: u1 = if (pager.manifest.chunks[index] == null) 0 else 1;
    var buf: [192]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "fault_ms={d} chunk_index={d} guest_offset={d} len={d} nonzero={d}\n", .{
        fault_ms,
        index,
        range.start,
        len,
        nonzero,
    });
    try writeAll(fd, line);
}

fn writeAll(fd: std.c.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const tail = bytes[written..];
        const rc = std.c.write(fd, tail.ptr, tail.len);
        if (rc < 0) return error.IoFailed;
        if (rc == 0) return error.IoFailed;
        written += @intCast(rc);
    }
}

fn monotonicMs() u64 {
    const freq = snapshot.hostCounterFreq();
    if (freq == 0) return 0;
    return snapshot.hostCounter() * std.time.ms_per_s / freq;
}

test "ram fault detection uses guest RAM window" {
    var refs = [_]?[]const u8{null} ** 2;
    var ram: [spore.chunk_size * 2]u8 align(std.heap.page_size_min) = undefined;
    @memset(&ram, 0);
    var mapped = [_]bool{false} ** 2;
    const pager = Pager{
        .allocator = std.testing.allocator,
        .dir = ".",
        .manifest = .{ .chunk_size = spore.chunk_size, .chunks = &refs },
        .ram = ram[0..],
        .mapped = &mapped,
        .trace_fd = null,
        .start_ms = 0,
    };
    try std.testing.expect(pager.isRamFault(board.ram_base));
    try std.testing.expect(pager.isRamFault(board.ram_base + spore.chunk_size));
    try std.testing.expect(!pager.isRamFault(board.ram_base - 1));
    try std.testing.expect(!pager.isRamFault(board.ram_base + ram.len));
}

test "guest range maps to chunk indexes" {
    var refs = [_]?[]const u8{null} ** 3;
    var ram: [spore.chunk_size * 3]u8 align(std.heap.page_size_min) = undefined;
    @memset(&ram, 0);
    var mapped = [_]bool{false} ** 3;
    var pager = Pager{
        .allocator = std.testing.allocator,
        .dir = ".",
        .manifest = .{ .chunk_size = spore.chunk_size, .chunks = &refs },
        .ram = ram[0..],
        .mapped = &mapped,
        .trace_fd = null,
        .start_ms = 0,
    };

    // Mark chunks as already mapped so this test exercises range validation
    // without calling Hypervisor.framework.
    @memset(&mapped, true);
    try pager.materializeGuestRange(board.ram_base + spore.chunk_size - 16, 32);
    try std.testing.expectError(error.BadManifest, pager.materializeGuestRange(board.ram_base - 4, 8));
    try std.testing.expectError(error.BadManifest, pager.materializeGuestRange(board.ram_base + ram.len - 4, 8));
}
