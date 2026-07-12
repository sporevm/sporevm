//! Durable offline fork transaction for saved spores.

const std = @import("std");
const builtin = @import("builtin");

const chunk = @import("chunk.zig");
const chunk_sealer = @import("chunk_sealer.zig");
const context_mod = @import("context.zig");
const disk_index = @import("disk_index.zig");
const local_paths = @import("local_paths.zig");
const manifest_test_support = @import("manifest_test_support.zig");
const rootfs_mod = @import("rootfs.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const runtime_disk_lease = @import("runtime_disk_lease.zig");
const runtime_disk_mod = @import("runtime_disk.zig");
const runtime_disk_fork_capture = @import("runtime_disk_fork_capture.zig");
const saved_spore_pin = @import("saved_spore_pin.zig");
const spore = @import("spore.zig");
const system = @import("system.zig");

const Context = context_mod.Context;

pub const Options = struct {
    parent_dir: []const u8,
    out_dir: []const u8,
    count: usize,
};

pub const Result = struct {
    count: usize,
    parent_generation: u64,
    first_generation: u64,
    last_generation: u64,
    pin_publish_ms: ?u64 = null,
    pin_lock_wait_ms: ?u64 = null,
};

const LoadedManifest = union(enum) {
    current: std.json.Parsed(spore.Manifest),
    v1: std.json.Parsed(spore.ManifestV1),

    fn load(allocator: std.mem.Allocator, spore_dir: []const u8) !LoadedManifest {
        const current = spore.loadManifest(allocator, spore_dir) catch |err| switch (err) {
            error.BadManifest => return .{ .v1 = try spore.loadManifestV1(allocator, spore_dir) },
            else => |e| return e,
        };
        return .{ .current = current };
    }

    fn disk(self: LoadedManifest) ?spore.Disk {
        return switch (self) {
            .current => |parsed| parsed.value.disk,
            .v1 => |parsed| parsed.value.disk,
        };
    }

    fn deinit(self: *LoadedManifest) void {
        switch (self.*) {
            inline else => |*parsed| parsed.deinit(),
        }
    }
};

const CrashBoundary = enum { none, before_batch_rename, batch_rename, parent_sync };

const TestFault = struct {
    fail_before_child: ?usize = null,
    fail_before_registry_sync: bool = false,
    fail_before_batch_rename: bool = false,
    fail_before_portable_sync: ?usize = null,
    portable_sync_count: usize = 0,
    crash_after: CrashBoundary = .none,
};

pub const testing = if (builtin.is_test) struct {
    pub var fault: TestFault = .{};
} else struct {};

fn crashAfterBoundary(boundary: CrashBoundary) void {
    if (comptime builtin.is_test) if (testing.fault.crash_after == boundary) std.process.exit(87);
}

pub fn execute(context: Context, allocator: std.mem.Allocator, options: Options) !Result {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent_manifest = try LoadedManifest.load(arena, options.parent_dir);
    defer parent_manifest.deinit();
    const disk = parent_manifest.disk();
    var disk_root: ?[]const u8 = null;
    var parent_pin_id: ?[]const u8 = null;
    var validated_storage: ?spore.RootfsStorage = null;
    if (disk) |value| {
        const cache_root = try local_paths.rootfsCacheRootPath(arena, context.environ_map);
        var phase_one_lock = try rootfs_mod.lockRootfsCacheExclusive(context.io, arena, cache_root);
        defer phase_one_lock.deinit();
        const phase_one_registry = try saved_spore_pin.LockedRegistry.init(arena, cache_root, &phase_one_lock);
        if (saved_spore_pin.loadForSporeLocked(context.io, arena, phase_one_registry, options.parent_dir, value)) |pin_value| {
            var pin = pin_value;
            defer pin.deinit();
            disk_root = cache_root;
            parent_pin_id = try arena.dupe(u8, pin.value.id);
            validated_storage = try saved_spore_pin.storageForDisk(value);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }
    }
    const fork_out = if (disk != null) blk: {
        var nonce: [8]u8 = undefined;
        context.io.random(&nonce);
        break :blk try std.fmt.allocPrint(arena, "{s}.pin-stage-{x}", .{ options.out_dir, std.mem.readInt(u64, &nonce, .little) });
    } else options.out_dir;
    var cleanup_stage = disk != null;
    defer if (cleanup_stage) std.Io.Dir.cwd().deleteTree(context.io, fork_out) catch {};
    const result = try spore.fork(arena, .{
        .parent_dir = options.parent_dir,
        .out_dir = fork_out,
        .count = options.count,
        .environ_map = context.environ_map,
        .disk_root = disk_root,
    });
    if (disk_root == null) if (disk) |portable_disk| {
        try materializeForkDiskStore(context.io, arena, allocator, options.parent_dir, fork_out, portable_disk, options.count);
        if (comptime builtin.is_test) if (testing.fault.fail_before_batch_rename) return error.InjectedFailure;
        crashAfterBoundary(.before_batch_rename);
        try std.Io.Dir.rename(std.Io.Dir.cwd(), fork_out, std.Io.Dir.cwd(), options.out_dir, context.io);
        crashAfterBoundary(.batch_rename);
        try chunk_sealer.fsyncDirPath(arena, std.fs.path.dirname(options.out_dir) orelse ".");
        crashAfterBoundary(.parent_sync);
        cleanup_stage = false;
    };
    var prepared_pins: ?[]saved_spore_pin.PreparedPin = null;
    if (disk_root != null) {
        prepared_pins = try arena.alloc(saved_spore_pin.PreparedPin, options.count);
        // Phase two must leave complete durable child manifests before phase
        // three can publish their pins. References are synced while the batch
        // is hidden, outside the short global-cache critical section.
        for (0..options.count) |index| {
            const child = try std.fmt.allocPrint(arena, "{s}/{d:0>6}", .{ fork_out, index });
            const manifest_path = try std.fs.path.join(arena, &.{ child, "manifest.json" });
            const bytes = try std.Io.Dir.cwd().readFileAlloc(context.io, manifest_path, allocator, .limited(saved_spore_pin.max_manifest_bytes + 1));
            defer allocator.free(bytes);
            if (bytes.len > saved_spore_pin.max_manifest_bytes) return error.StreamTooLong;
            try chunk_sealer.replaceFileAtomicDurable(arena, manifest_path, bytes, 0o644);
            var child_manifest = try LoadedManifest.load(arena, child);
            defer child_manifest.deinit();
            const child_disk = child_manifest.disk() orelse return error.BadManifest;
            prepared_pins.?[index] = try saved_spore_pin.prepareValidatedReference(
                context.io,
                arena,
                child,
                child_disk,
                validated_storage.?,
            );
        }
        try chunk_sealer.fsyncDirPath(arena, fork_out);
    }
    var pin_publish_ms: ?u64 = null;
    var pin_lock_wait_ms: ?u64 = null;
    if (disk != null and disk_root != null) {
        const wait_started = runtime_disk_fork_capture.monotonicNs();
        var publish_lock = try rootfs_mod.lockRootfsCacheExclusive(context.io, arena, disk_root.?);
        defer publish_lock.deinit();
        const publish_registry = try saved_spore_pin.LockedRegistry.init(arena, disk_root.?, &publish_lock);
        const lock_started = runtime_disk_fork_capture.monotonicNs();
        pin_lock_wait_ms = (lock_started -| wait_started) / std.time.ns_per_ms;
        var current = try saved_spore_pin.loadForSporeLocked(context.io, arena, publish_registry, options.parent_dir, disk.?);
        defer current.deinit();
        if (!std.mem.eql(u8, current.value.id, parent_pin_id.?)) return error.BadManifest;
        try saved_spore_pin.ensureRegistryDurable(arena, publish_registry);
        for (0..options.count) |index| {
            if (comptime builtin.is_test) if (testing.fault.fail_before_child == index) return error.InjectedFailure;
            try saved_spore_pin.publishPreparedRecord(arena, publish_registry, validated_storage.?, prepared_pins.?[index]);
        }
        if (comptime builtin.is_test) if (testing.fault.fail_before_registry_sync) return error.InjectedFailure;
        try saved_spore_pin.syncPreparedRecords(arena, publish_registry);
        if (comptime builtin.is_test) if (testing.fault.fail_before_batch_rename) return error.InjectedFailure;
        crashAfterBoundary(.before_batch_rename);
        try std.Io.Dir.rename(std.Io.Dir.cwd(), fork_out, std.Io.Dir.cwd(), options.out_dir, context.io);
        crashAfterBoundary(.batch_rename);
        try chunk_sealer.fsyncDirPath(arena, std.fs.path.dirname(options.out_dir) orelse ".");
        crashAfterBoundary(.parent_sync);
        cleanup_stage = false;
        const lock_finished = runtime_disk_fork_capture.monotonicNs();
        pin_publish_ms = (lock_finished -| lock_started) / std.time.ns_per_ms;
    }
    return .{
        .count = result.count,
        .parent_generation = result.parent_generation,
        .first_generation = result.first_generation,
        .last_generation = result.last_generation,
        .pin_publish_ms = pin_publish_ms,
        .pin_lock_wait_ms = pin_lock_wait_ms,
    };
}

fn materializeForkDiskStore(
    io: std.Io,
    path_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    parent_dir: []const u8,
    batch_dir: []const u8,
    disk: spore.Disk,
    child_count: usize,
) !void {
    const storage = try saved_spore_pin.storageForDisk(disk);
    const source_index = try rootfs_cas.manifestIndexPath(path_allocator, parent_dir, storage.index_digest);
    const index_bytes = try rootfs_cas.readVerifiedStorageIndexPath(scratch_allocator, source_index, storage);
    defer scratch_allocator.free(index_bytes);
    var parsed = try disk_index.parseDiskIndex(scratch_allocator, index_bytes, try spore.diskIndexDescriptorForStorage(storage));
    defer parsed.deinit();

    const shared_root = try std.fs.path.join(path_allocator, &.{ batch_dir, "shared-disk" });
    const dest_index = try rootfs_cas.manifestIndexPath(path_allocator, shared_root, storage.index_digest);
    try chunk_sealer.ensureDirPath(path_allocator, std.fs.path.dirname(dest_index).?);
    try chunk_sealer.writeFileAtomicDurable(path_allocator, dest_index, index_bytes, 0o444);
    const cas_root = try std.fs.path.join(path_allocator, &.{ shared_root, "cas" });
    const rootfs_root = try std.fs.path.join(path_allocator, &.{ cas_root, "rootfs" });
    const blake3_root = try std.fs.path.join(path_allocator, &.{ rootfs_root, "blake3" });
    const objects_root = try std.fs.path.join(path_allocator, &.{ blake3_root, "objects" });
    try chunk_sealer.ensureDirPath(path_allocator, objects_root);
    var seen = std.StringHashMap(void).init(path_allocator);
    defer seen.deinit();
    for (parsed.value.chunks) |entry| {
        if (seen.contains(entry.digest)) continue;
        try seen.put(entry.digest, {});
        const expected_size = try rootfs_cas.storageChunkLen(storage, entry.logical_chunk);
        const source_object = try rootfs_cas.manifestObjectPath(path_allocator, parent_dir, entry.digest);
        const source_bytes = try rootfs_cas.readVerifiedChunkPath(scratch_allocator, source_object, entry.digest, expected_size);
        defer scratch_allocator.free(source_bytes);
        const dest_object = try rootfs_cas.manifestObjectPath(path_allocator, shared_root, entry.digest);
        const dest_parent = std.fs.path.dirname(dest_object) orelse return error.BadManifest;
        try chunk_sealer.ensureDirPath(path_allocator, dest_parent);
        if (comptime builtin.is_test) if (testing.fault.fail_before_portable_sync == testing.fault.portable_sync_count) return error.InjectedFailure;
        switch (try chunk_sealer.publishTrustedFileIfMissing(path_allocator, source_object, dest_object, expected_size)) {
            .copy_required => try chunk_sealer.writeFileAtomicDurable(path_allocator, dest_object, source_bytes, 0o444),
            .linked, .reused_existing => try chunk_sealer.fsyncDirPath(path_allocator, dest_parent),
        }
        if (comptime builtin.is_test) testing.fault.portable_sync_count += 1;
        const dest_bytes = try rootfs_cas.readVerifiedChunkPath(scratch_allocator, dest_object, entry.digest, expected_size);
        scratch_allocator.free(dest_bytes);
    }
    // The shared CAS hierarchy is new in this hidden batch. Sync bottom-up so
    // every newly created directory entry is durable before children can see
    // the batch after its final rename.
    const durable_parents = [_][]const u8{ objects_root, blake3_root, rootfs_root, cas_root, shared_root };
    for (durable_parents) |path| {
        if (comptime builtin.is_test) if (testing.fault.fail_before_portable_sync == testing.fault.portable_sync_count) return error.InjectedFailure;
        try chunk_sealer.fsyncDirPath(path_allocator, path);
        if (comptime builtin.is_test) testing.fault.portable_sync_count += 1;
    }
    for (0..child_count) |index| {
        const child = try std.fmt.allocPrint(path_allocator, "{s}/{d:0>6}", .{ batch_dir, index });
        const cas_link = try std.fs.path.join(path_allocator, &.{ child, "cas" });
        try std.Io.Dir.cwd().deleteFile(io, cas_link);
        try std.Io.Dir.cwd().symLink(io, "../shared-disk/cas", cas_link, .{});
        try chunk_sealer.fsyncDirPath(path_allocator, child);
    }
    try chunk_sealer.fsyncDirPath(path_allocator, batch_dir);
}

test "pinned offline fork owns duplicate RAM chunks and independent child disk pins" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const cache = try std.fs.path.join(arena, &.{ root, "cache" });
    const runtime_root = try std.fs.path.join(arena, &.{ root, "runtime" });
    const parent = try std.fs.path.join(arena, &.{ root, "parent.spore" });
    const children = try std.fs.path.join(arena, &.{ root, "children" });
    const nested = try std.fs.path.join(arena, &.{ root, "nested" });
    try std.Io.Dir.cwd().createDirPath(io, parent);

    const ram = try arena.alloc(u8, 2 * spore.chunk_size);
    @memset(ram, 0x5a);
    const memory = try spore.saveMemoryWithBacking(arena, parent, ram);
    try std.testing.expectEqual(@as(usize, 2), memory.chunks.len);
    try std.testing.expectEqualStrings(memory.chunks[0].digest, memory.chunks[1].digest);

    const disk_payload = try arena.alloc(u8, 512);
    @memset(disk_payload, 0x6b);
    const disk_chunk_id = chunk.ChunkId.fromContents(disk_payload);
    const disk_chunk_hex = disk_chunk_id.toHex();
    const disk_chunk_digest = try std.fmt.allocPrint(arena, "{s}{s}", .{ spore.rootfs_digest_prefix, disk_chunk_hex[0..] });
    const disk_chunks = [_]disk_index.DiskIndexChunk{.{ .logical_chunk = 0, .digest = disk_chunk_digest }};
    const disk_index_value = disk_index.DiskIndex{
        .kind = disk_index.disk_index_kind,
        .logical_size = @intCast(disk_payload.len),
        .chunk_size = spore.disk_chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .object_namespace = spore.rootfs_storage_object_namespace,
        .chunks = &disk_chunks,
    };
    const encoded = try disk_index.encodeCanonicalAlloc(arena, disk_index_value);
    const index_path = try rootfs_cas.manifestIndexPath(arena, cache, encoded.digest);
    try chunk_sealer.ensureDirPath(arena, std.fs.path.dirname(index_path).?);
    try chunk_sealer.writeFileAtomicDurable(arena, index_path, encoded.bytes, 0o444);
    const storage = spore.RootfsStorage{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = .{ .mmio_slot = 1 },
        .logical_size = @intCast(disk_payload.len),
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
    var manifest = manifest_test_support.manifest(.{});
    manifest.platform.ram_size = ram.len;
    manifest.memory = memory;
    var devices = [_]spore.TransportState{
        .{ .device_id = 3, .status = 0, .device_features_sel = 0, .driver_features_sel = 0, .driver_features = 0, .queue_sel = 0, .interrupt_status = 0, .queues = &.{} },
        .{ .device_id = spore.rootfs_virtio_blk_device_id, .status = 0, .device_features_sel = 0, .driver_features_sel = 0, .driver_features = 0, .queue_sel = 0, .interrupt_status = 0, .queues = &.{} },
    };
    manifest.devices = &devices;
    manifest.rootfs = .{ .device = storage.device, .artifact = .{ .digest = storage.index_digest, .size = storage.logical_size }, .storage = storage };
    manifest.disk = disk;
    try spore.saveManifest(arena, parent, manifest);
    const parent_index_path = try rootfs_cas.manifestIndexPath(arena, parent, encoded.digest);
    try chunk_sealer.ensureDirPath(arena, std.fs.path.dirname(parent_index_path).?);
    try chunk_sealer.writeFileAtomicDurable(arena, parent_index_path, encoded.bytes, 0o444);
    const parent_object_path = try rootfs_cas.manifestObjectPath(arena, parent, disk_chunk_digest);
    try chunk_sealer.ensureDirPath(arena, std.fs.path.dirname(parent_object_path).?);
    try chunk_sealer.writeFileAtomicDurable(arena, parent_object_path, disk_payload, 0o444);
    const cache_object_path = try rootfs_cas.manifestObjectPath(arena, cache, disk_chunk_digest);
    try chunk_sealer.ensureDirPath(arena, std.fs.path.dirname(cache_object_path).?);
    try chunk_sealer.writeFileAtomicDurable(arena, cache_object_path, disk_payload, 0o444);
    const verified_local_object = try rootfs_cas.readVerifiedChunkPath(allocator, parent_object_path, disk_chunk_digest, disk_payload.len);
    defer allocator.free(verified_local_object);
    try std.testing.expectEqualSlices(u8, disk_payload, verified_local_object);
    const verified_cache_object = try rootfs_cas.readVerifiedChunkPath(allocator, cache_object_path, disk_chunk_digest, disk_payload.len);
    defer allocator.free(verified_cache_object);
    try std.testing.expectEqualSlices(u8, disk_payload, verified_cache_object);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache);
    try env.put(local_paths.runtime_dir_env, runtime_root);
    try spore.writeLocalMemoryBackingProof(arena, &env, parent, memory, ram.len);
    const context = Context{ .io = io, .environ_map = &env };

    // A portable/local-CAS fork stays hidden until every new CAS directory
    // entry has been synced bottom-up. Failure at any boundary leaves no
    // visible batch; the final rename is a separate injected boundary.
    defer testing.fault = .{};
    for (0..6) |sync_index| {
        const failed_portable = try std.fmt.allocPrint(arena, "{s}/portable-sync-{d}", .{ root, sync_index });
        testing.fault = .{ .fail_before_portable_sync = sync_index };
        try std.testing.expectError(error.InjectedFailure, execute(context, allocator, .{
            .parent_dir = parent,
            .out_dir = failed_portable,
            .count = 1,
        }));
        try std.testing.expectEqual(sync_index, testing.fault.portable_sync_count);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, failed_portable, .{ .follow_symlinks = false }));
    }
    const failed_portable_rename = try std.fs.path.join(arena, &.{ root, "portable-rename" });
    testing.fault = .{ .fail_before_batch_rename = true };
    try std.testing.expectError(error.InjectedFailure, execute(context, allocator, .{
        .parent_dir = parent,
        .out_dir = failed_portable_rename,
        .count = 1,
    }));
    try std.testing.expectEqual(@as(usize, 6), testing.fault.portable_sync_count);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, failed_portable_rename, .{ .follow_symlinks = false }));
    testing.fault = .{};

    var parent_lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, cache);
    defer parent_lock.deinit();
    const parent_registry = try saved_spore_pin.LockedRegistry.init(arena, cache, &parent_lock);
    const parent_pin = try saved_spore_pin.create(io, arena, parent_registry, parent, disk);
    const parent_manifest_path = try std.fs.path.join(arena, &.{ parent, "manifest.json" });
    const parent_ref_path = try std.fs.path.join(arena, &.{ parent, saved_spore_pin.reference_file });
    const parent_record_path = try std.fmt.allocPrint(arena, "{s}/{s}/{s}.json", .{ cache, saved_spore_pin.dir_name, parent_pin });
    const manifest_before_fault = try std.Io.Dir.cwd().readFileAlloc(io, parent_manifest_path, allocator, .limited(saved_spore_pin.max_manifest_bytes));
    defer allocator.free(manifest_before_fault);
    const ref_before_fault = try std.Io.Dir.cwd().readFileAlloc(io, parent_ref_path, allocator, .limited(saved_spore_pin.max_record_bytes));
    defer allocator.free(ref_before_fault);
    const record_before_fault = try std.Io.Dir.cwd().readFileAlloc(io, parent_record_path, allocator, .limited(saved_spore_pin.max_record_bytes));
    defer allocator.free(record_before_fault);
    var replacement_manifest = manifest;
    replacement_manifest.generation.generation += 1;
    saved_spore_pin.testing.publish_fault = .{ .fail_before_complete_stamp = true };
    defer saved_spore_pin.testing.publish_fault = .{};
    try std.testing.expectError(error.InjectedFailure, saved_spore_pin.publishManifest(io, arena, parent_registry, parent, disk, replacement_manifest));
    saved_spore_pin.testing.publish_fault = .{};
    const manifest_after_fault = try std.Io.Dir.cwd().readFileAlloc(io, parent_manifest_path, allocator, .limited(saved_spore_pin.max_manifest_bytes));
    defer allocator.free(manifest_after_fault);
    const ref_after_fault = try std.Io.Dir.cwd().readFileAlloc(io, parent_ref_path, allocator, .limited(saved_spore_pin.max_record_bytes));
    defer allocator.free(ref_after_fault);
    const record_after_fault = try std.Io.Dir.cwd().readFileAlloc(io, parent_record_path, allocator, .limited(saved_spore_pin.max_record_bytes));
    defer allocator.free(record_after_fault);
    try std.testing.expectEqualSlices(u8, manifest_before_fault, manifest_after_fault);
    try std.testing.expectEqualSlices(u8, ref_before_fault, ref_after_fault);
    try std.testing.expectEqualSlices(u8, record_before_fault, record_after_fault);
    const pins_after_fault = try saved_spore_pin.list(io, arena, cache);
    try std.testing.expectEqual(@as(usize, 1), pins_after_fault.len);
    const failed_stamp_path = try rootfs_cas.storageCompleteStampPath(arena, cache, encoded.digest);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, failed_stamp_path, .{ .follow_symlinks = false }));
    const active_leases_path = try std.fs.path.join(arena, &.{ runtime_root, runtime_disk_lease.active_dir_name });
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, active_leases_path, .{ .follow_symlinks = false }));
    parent_lock.deinit();

    const forked = try execute(context, allocator, .{ .parent_dir = parent, .out_dir = children, .count = 2 });
    try std.testing.expect(forked.pin_lock_wait_ms != null);
    try std.testing.expect(forked.pin_publish_ms != null);
    const moved_children = try std.fs.path.join(arena, &.{ root, "moved-children" });
    try std.Io.Dir.renameAbsolute(children, moved_children, io);
    try chunk_sealer.fsyncDirPath(arena, root);
    const moved_first_child = try std.fmt.allocPrint(arena, "{s}/000000", .{moved_children});
    var child_ids: [2][]const u8 = undefined;
    for (0..2) |index| {
        const child = try std.fmt.allocPrint(arena, "{s}/{d:0>6}", .{ moved_children, index });
        var parsed = try spore.loadManifest(arena, child);
        defer parsed.deinit();
        try std.testing.expectEqualStrings(encoded.digest, parsed.value.disk.?.base);
        const child_cas = try std.fs.path.join(arena, &.{ child, "cas" });
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, child_cas, .{ .follow_symlinks = false }));
        var lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, cache);
        defer lock.deinit();
        const registry = try saved_spore_pin.LockedRegistry.init(arena, cache, &lock);
        var pin = try saved_spore_pin.loadForSporeLocked(io, arena, registry, child, parsed.value.disk.?);
        child_ids[index] = try arena.dupe(u8, pin.value.id);
        pin.deinit();
        lock.deinit();
    }
    try std.testing.expect(!std.mem.eql(u8, child_ids[0], child_ids[1]));

    try std.Io.Dir.cwd().deleteTree(io, parent);
    var remove_lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, cache);
    defer remove_lock.deinit();
    const remove_registry = try saved_spore_pin.LockedRegistry.init(arena, cache, &remove_lock);
    try saved_spore_pin.remove(io, arena, remove_registry, parent_pin);
    remove_lock.deinit();
    const prune_result = try system.prune(allocator, io, .{
        .cache_root = cache,
        .runtime_root = runtime_root,
        .dry_run = false,
        .include_rootfs_chunks = true,
        .max_bytes = 0,
    }, std.Io.Clock.real.now(io).nanoseconds);
    defer system.deinitRootfsPruneResult(allocator, prune_result);
    try std.testing.expectEqual(@as(usize, 0), prune_result.deleted_count);
    const gc_result = try system.gc(allocator, io, .{ .cache_root = cache, .runtime_root = runtime_root, .dry_run = false });
    defer system.deinitRootfsGcResult(allocator, gc_result);
    try std.testing.expectEqual(@as(usize, 0), gc_result.deleted_count);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, parent_object_path, .{ .follow_symlinks = false }));
    const verified_rooted_object = try rootfs_cas.readVerifiedChunkPath(allocator, cache_object_path, disk_chunk_digest, disk_payload.len);
    defer allocator.free(verified_rooted_object);
    try std.testing.expectEqualSlices(u8, disk_payload, verified_rooted_object);

    for (0..2) |index| {
        const child = try std.fmt.allocPrint(arena, "{s}/{d:0>6}", .{ moved_children, index });
        var parsed = try spore.loadManifest(arena, child);
        defer parsed.deinit();
        try std.testing.expect(parsed.value.memory.backing != null);
        const backing_plan = try spore.openProvenLocalMemoryBacking(arena, &env, child, parsed.value.memory, ram.len);
        try std.testing.expectEqual(spore.LocalBackingRestoreSource.local_backing, backing_plan.source);
        try std.testing.expectEqual(spore.LocalBackingRestoreReason.proof_valid, backing_plan.reason);
        defer if (backing_plan.fd) |fd| {
            _ = std.c.close(fd);
        };
        const restored = try arena.alloc(u8, ram.len);
        try spore.loadMemory(arena, child, parsed.value.memory, restored);
        try std.testing.expectEqualSlices(u8, ram, restored);
        var runtime_disk = try runtime_disk_mod.open(context, allocator, .{
            .rootfs = parsed.value.rootfs.?,
            .disk = parsed.value.disk.?,
            .spore_dir = child,
        });
        defer runtime_disk.deinit();
        var disk_byte = [_]u8{0xaa};
        try runtime_disk.chunk_mapped.?.readAt(&disk_byte, 0);
        try std.testing.expectEqual(disk_payload[0], disk_byte[0]);
        try runtime_disk.chunk_mapped.?.writeAt(&.{0x7b}, 0);
        try runtime_disk.chunk_mapped.?.readAt(&disk_byte, 0);
        try std.testing.expectEqual(@as(u8, 0x7b), disk_byte[0]);
    }
    _ = try execute(context, allocator, .{ .parent_dir = moved_first_child, .out_dir = nested, .count = 1 });

    // A pin failure never exposes a partial batch. Pins already published for
    // hidden children are safe orphans and remain explicitly reclaimable.
    const failed_batch = try std.fs.path.join(arena, &.{ root, "failed-children" });
    testing.fault.fail_before_child = 1;
    try std.testing.expectError(error.InjectedFailure, execute(context, allocator, .{
        .parent_dir = moved_first_child,
        .out_dir = failed_batch,
        .count = 2,
    }));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, failed_batch, .{ .follow_symlinks = false }));
    testing.fault = .{};
    var orphan_lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, cache);
    const pins_after_failed_batch = try saved_spore_pin.list(io, arena, cache);
    try std.testing.expect(pins_after_failed_batch.len >= 4);
    orphan_lock.deinit();
    const failed_sync_batch = try std.fs.path.join(arena, &.{ root, "failed-sync-children" });
    testing.fault.fail_before_registry_sync = true;
    try std.testing.expectError(error.InjectedFailure, execute(context, allocator, .{
        .parent_dir = moved_first_child,
        .out_dir = failed_sync_batch,
        .count = 1,
    }));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, failed_sync_batch, .{ .follow_symlinks = false }));
    testing.fault = .{ .fail_before_batch_rename = true };
    const failed_rename_batch = try std.fs.path.join(arena, &.{ root, "failed-rename-children" });
    try std.testing.expectError(error.InjectedFailure, execute(context, allocator, .{
        .parent_dir = moved_first_child,
        .out_dir = failed_rename_batch,
        .count = 1,
    }));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, failed_rename_batch, .{ .follow_symlinks = false }));
    testing.fault = .{};

    // A process-owned active lease protects unread lazy disk data after every
    // visible save and pin has been removed.
    var active_manifest = try spore.loadManifest(arena, moved_first_child);
    defer active_manifest.deinit();
    var active_runtime = try runtime_disk_mod.open(context, allocator, .{
        .rootfs = active_manifest.value.rootfs.?,
        .disk = active_manifest.value.disk.?,
        .spore_dir = moved_first_child,
    });
    defer active_runtime.deinit();
    try std.Io.Dir.cwd().deleteTree(io, moved_children);
    try std.Io.Dir.cwd().deleteTree(io, nested);
    var unpin_lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, cache);
    defer unpin_lock.deinit();
    const unpin_registry = try saved_spore_pin.LockedRegistry.init(arena, cache, &unpin_lock);
    const remaining_pins = try saved_spore_pin.list(io, arena, cache);
    for (remaining_pins) |entry| try saved_spore_pin.remove(io, arena, unpin_registry, entry.id);
    unpin_lock.deinit();
    const leased_gc = try system.gc(allocator, io, .{ .cache_root = cache, .runtime_root = runtime_root, .dry_run = false });
    defer system.deinitRootfsGcResult(allocator, leased_gc);
    try std.testing.expectEqual(@as(usize, 0), leased_gc.deleted_count);
    var unread = [_]u8{0xaa};
    try active_runtime.chunk_mapped.?.readAt(&unread, 0);
    try std.testing.expectEqual(disk_payload[0], unread[0]);
}
