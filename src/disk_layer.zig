//! Runtime writable disk snapshot glue.
//!
//! The legacy disk-layer parser and layered COW backend have been removed from
//! the runtime path. This module keeps the small shared pieces still used while
//! rootfs-backed runs use the chunk-mapped backend. The old disk kind appears
//! only as an internal clean exact-rootfs sentinel and is never accepted from a
//! persisted manifest.

const std = @import("std");
const block_source = @import("block_source.zig");
const chunk_mapped_disk = @import("chunk_mapped_disk.zig");
const fd_util = @import("fd.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const runtime_disk_fork = @import("runtime_disk_fork.zig");
const spore = @import("spore.zig");

extern "c" fn mkstemp(template: [*:0]u8) c_int;

pub const Error = spore.Error || chunk_mapped_disk.Error || runtime_disk_fork.Error || error{
    ShortRead,
    ShortWrite,
};

pub const TempOverlay = struct {
    fd: std.c.fd_t,

    pub fn deinit(self: *TempOverlay) void {
        if (self.fd >= 0) {
            _ = std.c.close(self.fd);
            self.fd = -1;
        }
    }
};

pub const ActiveHead = union(enum) {
    chunk_mapped: *chunk_mapped_disk.ChunkMappedDisk,

    pub fn dirtyClusterCount(self: ActiveHead) usize {
        return switch (self) {
            .chunk_mapped => |disk| disk.dirtyClusterCount(),
        };
    }

    pub fn hasPublishedSnapshot(self: ActiveHead) bool {
        return switch (self) {
            .chunk_mapped => |disk| disk.hasPublishedSnapshot(),
        };
    }

    pub fn ensurePublishable(self: ActiveHead) Error!void {
        switch (self) {
            .chunk_mapped => |disk| if (disk.isPoisoned()) return error.Poisoned,
        }
    }
};

const DiskSnapshotMetrics = struct {
    logical_bytes: u64,
    chunks: u64,
    dirty_chunks: usize,
    non_dirty_chunks: u64,
    full_scan: bool,
    sealed_candidate_chunks: usize,
    sealed_chunks: u64,
    clean_zero_chunks_reused: usize,
    dirty_zero_chunks_recorded: usize,
    parent_chunks_reused: usize,
    parent: chunk_mapped_disk.ParentPublicationStats,
    zero_scan_us: u64,
    hash_us: u64,
    object_write_us: u64,
    index_bytes: u64,
    index_encode_us: u64,
    index_publish_us: u64,
    total_us: u64,
};

fn formatDiskSnapshotMetrics(buf: []u8, metrics: DiskSnapshotMetrics) std.fmt.BufPrintError![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "disk snapshot metrics: schema=2 logical_bytes={d} chunks={d} dirty_chunks={d} non_dirty_chunks={d} full_scan={} sealed_candidate_chunks={d} sealed_chunks={d} clean_zero_chunks_reused={d} dirty_zero_chunks_recorded={d} parent_chunks_reused={d} parent_referenced_bytes={d} parent_objects_linked={d} parent_objects_reused={d} parent_objects_copied={d} parent_object_bytes={d} parent_link_bytes={d} parent_reuse_bytes={d} parent_copy_bytes={d} parent_link_us={d} parent_reuse_us={d} parent_copy_us={d} parent_sync_us={d} zero_scan_us={d} hash_us={d} object_write_us={d} index_bytes={d} index_encode_us={d} index_publish_us={d} total_us={d}",
        .{
            metrics.logical_bytes,
            metrics.chunks,
            metrics.dirty_chunks,
            metrics.non_dirty_chunks,
            metrics.full_scan,
            metrics.sealed_candidate_chunks,
            metrics.sealed_chunks,
            metrics.clean_zero_chunks_reused,
            metrics.dirty_zero_chunks_recorded,
            metrics.parent_chunks_reused,
            metrics.parent.referenced_bytes,
            metrics.parent.linked.objects,
            metrics.parent.reused.objects,
            metrics.parent.copied.objects,
            metrics.parent.object_bytes,
            metrics.parent.linked.bytes,
            metrics.parent.reused.bytes,
            metrics.parent.copied.bytes,
            metrics.parent.linked.ns / std.time.ns_per_us,
            metrics.parent.reused.ns / std.time.ns_per_us,
            metrics.parent.copied.ns / std.time.ns_per_us,
            metrics.parent.sync_ns / std.time.ns_per_us,
            metrics.zero_scan_us,
            metrics.hash_us,
            metrics.object_write_us,
            metrics.index_bytes,
            metrics.index_encode_us,
            metrics.index_publish_us,
            metrics.total_us,
        },
    );
}

pub const SnapshotState = struct {
    base: spore.Disk,
    active: ActiveHead,

    /// Finish a writable disk snapshot after the VMM has paused the guest and
    /// verified the matching virtio-blk queues have no pending requests.
    pub fn finish(self: SnapshotState, _: std.mem.Allocator, dir: []const u8, quiesced: bool) Error!?spore.Disk {
        std.debug.assert(quiesced);
        try self.active.ensurePublishable();
        if (self.active.dirtyClusterCount() == 0) {
            if (std.mem.eql(u8, self.base.kind, spore.disk_kind_cow_block) and !self.active.hasPublishedSnapshot()) return null;
        }
        const start_ns = try monotonicNs();
        const dirty_chunks = self.active.dirtyClusterCount();
        var stats: chunk_mapped_disk.SnapshotStats = .{};
        const result = switch (self.active) {
            .chunk_mapped => |disk| try disk.snapshotIndexWithStats(dir, self.base.device, quiesced, &stats),
        };
        const chunks = std.math.divCeil(u64, result.size, result.chunk_size) catch 0;
        var metrics_buf: [2048]u8 = undefined;
        const metrics = formatDiskSnapshotMetrics(&metrics_buf, .{
            .logical_bytes = result.size,
            .chunks = chunks,
            .dirty_chunks = dirty_chunks,
            .non_dirty_chunks = chunks -| dirty_chunks,
            .full_scan = stats.full_scan,
            .sealed_candidate_chunks = stats.sealed_candidate_chunks,
            .sealed_chunks = stats.work.sealed_chunks,
            .clean_zero_chunks_reused = stats.clean_zero_chunks_reused,
            .dirty_zero_chunks_recorded = stats.dirty_zero_chunks_recorded,
            .parent_chunks_reused = stats.parent_chunks_reused,
            .parent = stats.parent,
            .zero_scan_us = stats.work.zero_scan_ns / std.time.ns_per_us,
            .hash_us = stats.work.hash_ns / std.time.ns_per_us,
            .object_write_us = stats.work.chunk_write_ns / std.time.ns_per_us,
            .index_bytes = stats.index_bytes,
            .index_encode_us = stats.index_encode_ns / std.time.ns_per_us,
            .index_publish_us = stats.index_publish_ns / std.time.ns_per_us,
            .total_us = ((try monotonicNs()) -| start_ns) / std.time.ns_per_us,
        }) catch return error.ShortWrite;
        std.log.info("{s}", .{metrics});
        return result;
    }

    pub fn prepareSnapshotRoot(self: SnapshotState, root: []const u8) Error!chunk_mapped_disk.PreparedSnapshotRoot {
        return switch (self.active) {
            .chunk_mapped => |disk| disk.prepareSnapshotRoot(root),
        };
    }

    pub fn commitSnapshotRoot(
        self: SnapshotState,
        expected_root: []const u8,
        prepared: *chunk_mapped_disk.PreparedSnapshotRoot,
    ) Error!void {
        return switch (self.active) {
            .chunk_mapped => |disk| disk.commitSnapshotRoot(expected_root, prepared),
        };
    }

    /// Clones the live writable head without sealing a durable disk index.
    /// The backend must keep every vCPU paused and validate the virtio-blk
    /// queue against `base` before calling this method.
    pub fn exportForkHead(
        self: SnapshotState,
        options: chunk_mapped_disk.ExportForkOptions,
    ) Error!runtime_disk_fork.Head {
        const baseline = try forkBaseline(self.base);
        return switch (self.active) {
            .chunk_mapped => |disk| disk.exportForkHead(baseline, options),
        };
    }
};

pub fn forkBaseline(base: spore.Disk) Error!runtime_disk_fork.Baseline {
    const kind: runtime_disk_fork.BaselineKind = if (std.mem.eql(u8, base.kind, spore.disk_kind_chunk_index))
        .disk_index
    else if (std.mem.eql(u8, base.kind, spore.disk_kind_cow_block))
        .rootfs
    else
        return error.BadManifest;
    try spore.validateDiskDigest(base.base);
    return .{ .kind = kind, .identity = base.base };
}

fn monotonicNs() Error!u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return error.IoFailed;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

test "disk snapshot schema-2 metric matches parser golden record" {
    var buf: [2048]u8 = undefined;
    const actual = try formatDiskSnapshotMetrics(&buf, .{
        .logical_bytes = 262144,
        .chunks = 4,
        .dirty_chunks = 2,
        .non_dirty_chunks = 2,
        .full_scan = false,
        .sealed_candidate_chunks = 1,
        .sealed_chunks = 1,
        .clean_zero_chunks_reused = 1,
        .dirty_zero_chunks_recorded = 1,
        .parent_chunks_reused = 1,
        .parent = .{
            .referenced_bytes = 65536,
            .object_bytes = 65536,
            .linked = .{ .objects = 1, .bytes = 65536, .ns = 11 * std.time.ns_per_us },
            .sync_ns = 13 * std.time.ns_per_us,
        },
        .zero_scan_us = 1,
        .hash_us = 2,
        .object_write_us = 3,
        .index_bytes = 100,
        .index_encode_us = 4,
        .index_publish_us = 5,
        .total_us = 51,
    });
    const golden = std.mem.trimEnd(u8, @embedFile("testdata/disk-snapshot-metrics-v2.txt"), "\n");
    try std.testing.expectEqualStrings(golden, actual);
}

pub fn createTempOverlay(allocator: std.mem.Allocator) Error!TempOverlay {
    return createTempOverlayAt(allocator, chunk_mapped_disk.runtime_overlay_dir);
}

pub fn createTempOverlayAt(allocator: std.mem.Allocator, dir: []const u8) Error!TempOverlay {
    if (dir.len == 0) return error.BadOverlay;
    const template = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/sporevm-disk-head-XXXXXX",
        .{std.mem.trimEnd(u8, dir, "/")},
        0,
    );
    defer allocator.free(template);
    const fd = mkstemp(template.ptr);
    if (fd < 0) return error.IoFailed;
    errdefer _ = std.c.close(fd);
    if (std.c.unlink(template.ptr) != 0) return error.IoFailed;
    try fd_util.setCloseOnExec(fd);
    return .{ .fd = fd };
}

pub fn diskFromRootfs(rootfs: spore.Rootfs) spore.Disk {
    return .{
        .kind = spore.disk_kind_cow_block,
        .device = rootfs.device,
        .size = spore.effectiveRootfsLogicalSize(rootfs),
        .base = spore.effectiveRootfsBaseIdentity(rootfs),
        .layers = &.{},
    };
}

pub fn cloneDisk(allocator: std.mem.Allocator, disk: spore.Disk) Error!spore.Disk {
    const kind = try allocator.dupe(u8, disk.kind);
    errdefer allocator.free(kind);
    const device = try spore.cloneRootfsDevice(allocator, disk.device);
    errdefer {
        allocator.free(device.kind);
        allocator.free(device.role);
    }
    const base = try allocator.dupe(u8, disk.base);
    errdefer allocator.free(base);
    const hash_algorithm = try allocator.dupe(u8, disk.hash_algorithm);
    errdefer allocator.free(hash_algorithm);
    const object_namespace = try allocator.dupe(u8, disk.object_namespace);
    errdefer allocator.free(object_namespace);

    const layers = try allocator.alloc([]const u8, disk.layers.len);
    var initialized: usize = 0;
    errdefer {
        for (layers[0..initialized]) |layer| allocator.free(layer);
        allocator.free(layers);
    }
    for (disk.layers, 0..) |layer_ref, i| {
        layers[i] = try allocator.dupe(u8, layer_ref);
        initialized += 1;
    }

    return .{
        .kind = kind,
        .device = device,
        .size = disk.size,
        .base = base,
        .chunk_size = disk.chunk_size,
        .hash_algorithm = hash_algorithm,
        .object_namespace = object_namespace,
        .layers = layers,
    };
}

test "snapshot returns null for a clean exact-rootfs sentinel disk" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);
    const bytes = [_]u8{0x42} ** 4096;
    try base.writeStreamingAll(io, &bytes);

    const base_source = block_source.FileBlockSource.init(base.handle, bytes.len);
    var disk = try chunk_mapped_disk.ChunkMappedDisk.initWritable(allocator, base_source, overlay.handle, bytes.len, 512);
    defer disk.deinit();

    const base_disk = spore.Disk{
        .kind = spore.disk_kind_cow_block,
        .device = .{ .mmio_slot = 1 },
        .size = bytes.len,
        .base = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
    const snapshot = try (SnapshotState{
        .base = base_disk,
        .active = .{ .chunk_mapped = &disk },
    }).finish(allocator, ".", true);
    try std.testing.expect(snapshot == null);

    disk.poison();
    try std.testing.expectError(error.Poisoned, (SnapshotState{
        .base = base_disk,
        .active = .{ .chunk_mapped = &disk },
    }).finish(allocator, ".", true));
}

test "clean chunk-index save publishes its index" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out_dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/saved.spore", .{tmp.sub_path[0..]});
    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    const bytes = [_]u8{0x62} ** 512;
    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    try base.writeStreamingAll(io, &bytes);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);
    const base_source = block_source.FileBlockSource.init(base.handle, bytes.len);
    var disk = try chunk_mapped_disk.ChunkMappedDisk.initWritable(arena, base_source, overlay.handle, bytes.len, 512);
    defer disk.deinit();

    const stale_identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const saved = (try (SnapshotState{
        .base = .{
            .kind = spore.disk_kind_chunk_index,
            .device = .{ .mmio_slot = 1 },
            .size = bytes.len,
            .base = stale_identity,
            .chunk_size = 512,
        },
        .active = .{ .chunk_mapped = &disk },
    }).finish(arena, out_dir, true)) orelse return error.BadManifest;
    try std.testing.expect(!std.mem.eql(u8, stale_identity, saved.base));

    const index_path = try rootfs_cas.manifestIndexPath(arena, out_dir, saved.base);
    try std.Io.Dir.cwd().access(io, index_path, .{ .read = true });
}

test "clean save after dirty cow snapshot keeps current identity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const first_dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/first.spore", .{tmp.sub_path[0..]});
    const second_dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/second.spore", .{tmp.sub_path[0..]});
    try std.Io.Dir.cwd().createDirPath(io, first_dir);
    try std.Io.Dir.cwd().createDirPath(io, second_dir);
    const bytes = [_]u8{0x73} ** 512;
    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    try base.writeStreamingAll(io, &bytes);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);
    const base_source = block_source.FileBlockSource.init(base.handle, bytes.len);
    var disk = try chunk_mapped_disk.ChunkMappedDisk.initWritable(arena, base_source, overlay.handle, bytes.len, 512);
    defer disk.deinit();

    const patch = [_]u8{0x84} ** 37;
    try disk.writeAt(&patch, 101);
    const state = SnapshotState{
        .base = .{
            .kind = spore.disk_kind_cow_block,
            .device = .{ .mmio_slot = 1 },
            .size = bytes.len,
            .base = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        },
        .active = .{ .chunk_mapped = &disk },
    };
    const first = (try state.finish(arena, first_dir, true)) orelse return error.BadManifest;
    try std.testing.expectEqual(@as(usize, 0), disk.dirtyChunkCount());
    const second = (try state.finish(arena, second_dir, true)) orelse return error.BadManifest;
    try std.testing.expectEqualStrings(first.base, second.base);
    const second_index = try rootfs_cas.manifestIndexPath(arena, second_dir, second.base);
    try std.Io.Dir.cwd().access(io, second_index, .{ .read = true });
}
