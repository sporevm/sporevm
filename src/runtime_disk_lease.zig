//! Durable authority record for a live runtime disk-fork baseline.

const std = @import("std");

const runtime_disk_fork = @import("runtime_disk_fork.zig");
const spore = @import("spore.zig");

pub const schema = "spore.disk-baseline-lease.v1";

pub const Store = enum {
    rootfs_cache,
    saved_spore,
};

pub const Lease = struct {
    schema: []const u8 = schema,
    store: Store,
    /// Absolute root that owns the immutable baseline named below.
    root: []const u8,
    baseline_kind: runtime_disk_fork.BaselineKind,
    baseline_identity: []const u8,
    /// CAS descriptor needed to keep a cache-backed disk index and all of its
    /// objects rooted even after the source monitor and fork batch disappear.
    rootfs_storage: ?spore.RootfsStorage = null,

    pub fn validate(self: Lease) !void {
        if (!std.mem.eql(u8, self.schema, schema)) return error.BadManifest;
        if (self.root.len == 0 or !std.fs.path.isAbsolute(self.root)) return error.BadManifest;
        try spore.validateDiskDigest(self.baseline_identity);
        switch (self.store) {
            .rootfs_cache => switch (self.baseline_kind) {
                .rootfs => if (self.rootfs_storage != null) return error.BadManifest,
                .disk_index => {
                    const storage = self.rootfs_storage orelse return error.BadManifest;
                    try spore.validateRootfsStorageDescriptor(storage);
                    if (!std.mem.eql(u8, storage.index_digest, self.baseline_identity)) return error.BadManifest;
                },
            },
            .saved_spore => {
                if (self.baseline_kind != .disk_index or self.rootfs_storage != null) return error.BadManifest;
            },
        }
    }
};

test "disk baseline lease binds its authority and storage descriptor" {
    const storage = spore.RootfsStorage{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = .{ .mmio_slot = 1 },
        .logical_size = spore.disk_chunk_size,
        .chunk_size = spore.disk_chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .index_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .base_identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .object_namespace = spore.rootfs_storage_object_namespace,
    };
    try (Lease{
        .store = .rootfs_cache,
        .root = "/cache",
        .baseline_kind = .disk_index,
        .baseline_identity = storage.index_digest,
        .rootfs_storage = storage,
    }).validate();
    try std.testing.expectError(error.BadManifest, (Lease{
        .store = .rootfs_cache,
        .root = "relative",
        .baseline_kind = .rootfs,
        .baseline_identity = storage.index_digest,
    }).validate());
}
