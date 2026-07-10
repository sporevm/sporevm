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
};

pub const SnapshotState = struct {
    base: spore.Disk,
    active: ActiveHead,

    /// Finish a writable disk snapshot after the VMM has paused the guest and
    /// verified the matching virtio-blk queues have no pending requests.
    pub fn finish(self: SnapshotState, _: std.mem.Allocator, dir: []const u8, quiesced: bool) Error!?spore.Disk {
        std.debug.assert(quiesced);
        if (self.active.dirtyClusterCount() == 0) {
            if (std.mem.eql(u8, self.base.kind, spore.disk_kind_cow_block) and !self.active.hasPublishedSnapshot()) return null;
        }
        const start_ms = try monotonicMs();
        const dirty_chunks = self.active.dirtyClusterCount();
        var stats: chunk_mapped_disk.SnapshotStats = .{};
        const result = switch (self.active) {
            .chunk_mapped => |disk| try disk.snapshotIndexWithStats(dir, self.base.device, quiesced, &stats),
        };
        std.log.info(
            "disk snapshot metrics: logical_mib={d} chunks={d} dirty_chunks={d} full_scan={} sealed_chunks={d} parent_chunks_reused={d} parent_objects_linked={d} parent_objects_reused={d} parent_objects_copied={d} parent_object_mib={d} zero_scan_ms={d} hash_ms={d} object_write_ms={d} total_ms={d}",
            .{
                result.size / 1024 / 1024,
                std.math.divCeil(u64, result.size, result.chunk_size) catch 0,
                dirty_chunks,
                stats.full_scan,
                stats.work.sealed_chunks,
                stats.parent_chunks_reused,
                stats.parent_objects_linked,
                stats.parent_objects_reused,
                stats.parent_objects_copied,
                stats.parent_object_bytes / 1024 / 1024,
                stats.work.zero_scan_ns / std.time.ns_per_ms,
                stats.work.hash_ns / std.time.ns_per_ms,
                stats.work.chunk_write_ns / std.time.ns_per_ms,
                (try monotonicMs()) -| start_ms,
            },
        );
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

fn monotonicMs() Error!u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return error.IoFailed;
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
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
