const std = @import("std");

const chunk = @import("chunk.zig");
const chunk_sealer = @import("chunk_sealer.zig");
const disk_index = @import("disk_index.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const spore = @import("spore.zig");

pub fn manifest(annotations: spore.Annotations) spore.Manifest {
    return .{
        .annotations = annotations,
        .platform = .{
            .cpu_profile = "sporevm-aarch64-v0",
            .device_model_version = 4,
            .ram_base = 0x8000_0000,
            .ram_size = 1,
            .gic_dist_base = 0x0800_0000,
            .gic_redist_base = 0x0801_0000,
            .counter_frequency_hz = 24_000_000,
        },
        .machine = .{
            .gprs = [_]u64{0} ** 31,
            .pc = 0,
            .cpsr = 0,
            .fpcr = 0,
            .fpsr = 0,
            .simd = [_][2]u64{.{ 0, 0 }} ** 32,
            .sys_regs = &.{},
            .icc_regs = &.{},
            .vtimer = .{ .cntvct = 0, .cntv_ctl = 0, .cntv_cval = 0 },
            .gic = .{
                .kind = .gicv3,
                .gicv3 = .{
                    .dist_regs = &.{},
                    .redist_regs = &.{},
                    .line_levels = &.{},
                },
            },
        },
        .devices = &.{},
        .generation = .{ .generation = 0, .interrupt_status = 0, .params_b64 = "" },
        .sessions = &sessions,
        .memory = .{ .logical_size = 1, .chunk_size = spore.chunk_size, .zero_chunks = &.{0} },
    };
}

const sessions = [_]spore.Session{.{
    .id = spore.default_session_id,
    .streams = .{
        .stdout = false,
        .stderr = false,
        .terminal = true,
    },
}};

pub const DiskFixture = struct {
    manifest: spore.Manifest,
    disk: spore.Disk,
    storage: spore.RootfsStorage,
    object_digest: []const u8,
    object_bytes: []const u8,
};

/// Writes one descriptor-bound disk index and object into `cache_root`, then
/// returns a minimal manifest that names them. Tests can ask for a local CAS
/// copy to model a portable/unpacked saved spore without duplicating the
/// canonical fixture shape in every lifecycle module.
pub fn diskFixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_root: []const u8,
    spore_dir: []const u8,
    seed: u8,
    include_local_cas: bool,
) !DiskFixture {
    try std.Io.Dir.cwd().createDirPath(io, spore_dir);
    const object_bytes = try allocator.alloc(u8, 512);
    @memset(object_bytes, seed);
    const object_id = chunk.ChunkId.fromContents(object_bytes);
    const object_hex = object_id.toHex();
    const object_digest = try std.fmt.allocPrint(allocator, "{s}{s}", .{ spore.rootfs_digest_prefix, object_hex[0..] });
    const chunks = try allocator.alloc(disk_index.DiskIndexChunk, 1);
    chunks[0] = .{ .logical_chunk = 0, .digest = object_digest };
    const encoded = try disk_index.encodeCanonicalAlloc(allocator, .{
        .kind = disk_index.disk_index_kind,
        .logical_size = object_bytes.len,
        .chunk_size = spore.disk_chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .object_namespace = spore.rootfs_storage_object_namespace,
        .chunks = chunks,
    });
    const storage = spore.RootfsStorage{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = .{ .mmio_slot = 1 },
        .logical_size = object_bytes.len,
        .chunk_size = spore.disk_chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .index_digest = encoded.digest,
        .base_identity = encoded.digest,
        .object_namespace = spore.rootfs_storage_object_namespace,
    };
    const disk = spore.Disk{
        .kind = spore.disk_kind_chunk_index,
        .device = storage.device,
        .size = storage.logical_size,
        .base = storage.index_digest,
        .chunk_size = storage.chunk_size,
        .hash_algorithm = storage.hash_algorithm,
        .object_namespace = storage.object_namespace,
        .layers = &.{},
    };
    const cache_object = try rootfs_cas.manifestObjectPath(allocator, cache_root, object_digest);
    try chunk_sealer.ensureDirPath(allocator, std.fs.path.dirname(cache_object).?);
    try chunk_sealer.writeFileAtomicDurable(allocator, cache_object, object_bytes, 0o444);
    const cache_index = try rootfs_cas.manifestIndexPath(allocator, cache_root, encoded.digest);
    try chunk_sealer.ensureDirPath(allocator, std.fs.path.dirname(cache_index).?);
    try chunk_sealer.writeFileAtomicDurable(allocator, cache_index, encoded.bytes, 0o444);
    if (include_local_cas) {
        const local_object = try rootfs_cas.manifestObjectPath(allocator, spore_dir, object_digest);
        try chunk_sealer.ensureDirPath(allocator, std.fs.path.dirname(local_object).?);
        try chunk_sealer.writeFileAtomicDurable(allocator, local_object, object_bytes, 0o444);
        const local_index = try rootfs_cas.manifestIndexPath(allocator, spore_dir, encoded.digest);
        try chunk_sealer.ensureDirPath(allocator, std.fs.path.dirname(local_index).?);
        try chunk_sealer.writeFileAtomicDurable(allocator, local_index, encoded.bytes, 0o444);
    }

    var result_manifest = manifest(.{});
    const devices = try allocator.alloc(spore.TransportState, 2);
    devices[0] = .{ .device_id = 3, .status = 0, .device_features_sel = 0, .driver_features_sel = 0, .driver_features = 0, .queue_sel = 0, .interrupt_status = 0, .queues = &.{} };
    devices[1] = .{ .device_id = spore.rootfs_virtio_blk_device_id, .status = 0, .device_features_sel = 0, .driver_features_sel = 0, .driver_features = 0, .queue_sel = 0, .interrupt_status = 0, .queues = &.{} };
    result_manifest.devices = devices;
    result_manifest.rootfs = .{
        .device = storage.device,
        .artifact = .{ .digest = storage.index_digest, .size = storage.logical_size },
        .storage = storage,
    };
    result_manifest.disk = disk;
    return .{
        .manifest = result_manifest,
        .disk = disk,
        .storage = storage,
        .object_digest = object_digest,
        .object_bytes = object_bytes,
    };
}
