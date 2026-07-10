//! Shared ownership state for one quiesced runtime disk-fork batch.

const std = @import("std");

const block_source = @import("block_source.zig");
const chunk_mapped_disk = @import("chunk_mapped_disk.zig");
const disk_layer = @import("disk_layer.zig");
const runtime_disk_claim = @import("runtime_disk_claim.zig");
const runtime_disk_fork = @import("runtime_disk_fork.zig");
const spore = @import("spore.zig");

pub const Options = struct {
    allow_copy: bool = false,
    force_copy: bool = false,
};

pub const Batch = struct {
    allocator: std.mem.Allocator,
    heads: []?runtime_disk_fork.Head,
    pause_started_ns: u64,
    ram_capture_ns: u64,
    prepare_ns: u64,
    copied_bytes: u64,

    pub fn deinit(self: *Batch) void {
        for (self.heads) |*head| {
            if (head.*) |*owned| owned.deinit();
            head.* = null;
        }
        self.allocator.free(self.heads);
        self.* = undefined;
    }
};

/// Prepares every child head while the caller retains the backend's paused
/// epoch. On failure, every already-created fd and descriptor is closed.
pub fn prepare(
    allocator: std.mem.Allocator,
    disk: disk_layer.SnapshotState,
    count: usize,
    options: Options,
) !Batch {
    try validateCount(count);
    const heads = try allocator.alloc(?runtime_disk_fork.Head, count);
    @memset(heads, null);
    var batch = Batch{
        .allocator = allocator,
        .heads = heads,
        .pause_started_ns = 0,
        .ram_capture_ns = 0,
        .prepare_ns = 0,
        .copied_bytes = 0,
    };
    errdefer batch.deinit();

    for (batch.heads) |*head| {
        head.* = try disk.exportForkHead(.{
            .quiesced = true,
            .allow_copy = options.allow_copy,
            .force_copy = options.force_copy,
        });
        batch.prepare_ns = std.math.add(u64, batch.prepare_ns, head.*.?.stats.prepare_ns) catch std.math.maxInt(u64);
        batch.copied_bytes = std.math.add(u64, batch.copied_bytes, head.*.?.stats.copied_bytes) catch std.math.maxInt(u64);
    }
    return batch;
}

fn validateCount(count: usize) !void {
    if (count == 0 or count > runtime_disk_claim.max_children_per_batch) return error.InvalidForkCount;
}

pub fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const seconds = std.math.mul(u64, @intCast(ts.sec), std.time.ns_per_s) catch return std.math.maxInt(u64);
    return std.math.add(u64, seconds, @intCast(ts.nsec)) catch std.math.maxInt(u64);
}

pub fn elapsedSince(start_ns: u64) u64 {
    if (start_ns == 0) return 0;
    return monotonicNs() -| start_ns;
}

test "batch rejects counts outside the product bound" {
    try std.testing.expectError(error.InvalidForkCount, validateCount(0));
    try std.testing.expectError(
        error.InvalidForkCount,
        validateCount(runtime_disk_claim.max_children_per_batch + 1),
    );
}

test "batch owns every cloned head until registration moves it" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    if (std.c.ftruncate(base.handle, spore.disk_chunk_size) != 0) return error.IoFailed;

    var overlay = try disk_layer.createTempOverlay(allocator);
    defer overlay.deinit();
    var disk = try chunk_mapped_disk.ChunkMappedDisk.initWritable(
        allocator,
        block_source.FileBlockSource.init(base.handle, spore.disk_chunk_size),
        overlay.fd,
        spore.disk_chunk_size,
        spore.disk_chunk_size,
    );
    defer disk.deinit();
    const patch = [_]u8{0xa5} ** 16;
    try disk.writeAt(&patch, 8);
    var batch = try prepare(allocator, .{
        .base = .{
            .kind = spore.disk_kind_cow_block,
            .device = .{ .mmio_slot = 1 },
            .size = spore.disk_chunk_size,
            .base = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .chunk_size = spore.disk_chunk_size,
        },
        .active = .{ .chunk_mapped = &disk },
    }, 2, .{ .allow_copy = true, .force_copy = true });
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 2), batch.heads.len);
    try std.testing.expect(batch.heads[0] != null and batch.heads[1] != null);
    try std.testing.expect(batch.heads[0].?.overlay_fd != batch.heads[1].?.overlay_fd);
    try std.testing.expectEqual(runtime_disk_fork.CloneMethod.copy, batch.heads[0].?.descriptor.clone_method);
}
