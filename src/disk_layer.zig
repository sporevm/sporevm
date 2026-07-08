//! Runtime writable disk snapshot glue.
//!
//! The legacy disk-layer parser and layered COW backend have been removed from
//! the runtime path. This module keeps the small shared pieces still used while
//! rootfs-backed runs use the chunk-mapped backend. The old disk kind appears
//! only as an internal clean exact-rootfs sentinel and is never accepted from a
//! persisted manifest.

const std = @import("std");
const chunk_mapped_disk = @import("chunk_mapped_disk.zig");
const spore = @import("spore.zig");

extern "c" fn mkstemp(template: [*:0]u8) c_int;

pub const Error = spore.Error || chunk_mapped_disk.Error || error{
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
};

pub const SnapshotState = struct {
    base: spore.Disk,
    active: ActiveHead,

    /// Finish a writable disk snapshot after the VMM has paused the guest and
    /// verified the matching virtio-blk queues have no pending requests.
    pub fn finish(self: SnapshotState, allocator: std.mem.Allocator, dir: []const u8, quiesced: bool) Error!?spore.Disk {
        std.debug.assert(quiesced);
        if (self.active.dirtyClusterCount() == 0) {
            if (std.mem.eql(u8, self.base.kind, spore.disk_kind_chunk_index)) return try cloneDisk(allocator, self.base);
            return null;
        }
        return switch (self.active) {
            .chunk_mapped => |disk| try disk.snapshotIndex(dir, self.base.device, quiesced),
        };
    }
};

pub fn createTempOverlay(allocator: std.mem.Allocator) Error!TempOverlay {
    const template = try allocator.dupeZ(u8, "/tmp/sporevm-disk-head-XXXXXX");
    defer allocator.free(template);
    const fd = mkstemp(template.ptr);
    if (fd < 0) return error.IoFailed;
    _ = std.c.unlink(template.ptr);
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

    const base_source = @import("block_source.zig").FileBlockSource.init(base.handle, bytes.len);
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
