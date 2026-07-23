//! Durable removal for saved spores with pinned or portable disk authority.

const std = @import("std");
const builtin = @import("builtin");

const aarch64_topology = @import("aarch64/topology.zig");
const chunk_sealer = @import("chunk_sealer.zig");
const Context = @import("context.zig").Context;
const disk_index = @import("disk_index.zig");
const gicv3 = @import("aarch64/gicv3.zig");
const local_paths = @import("local_paths.zig");
const manifest_test_support = @import("manifest_test_support.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const rootfs_mod = @import("rootfs.zig");
const resource = @import("resource.zig");
const runtime_disk_lease = @import("runtime_disk_lease.zig");
const saved_spore_pin = @import("saved_spore_pin.zig");
const saved_spore_ownership = @import("saved_spore_ownership.zig");
const spore = @import("spore.zig");
const topology = @import("topology.zig");

const Io = std.Io;

pub const Result = struct {
    schema: []const u8 = "spore.saved.remove.result.v1",
    schema_version: u32 = 1,
    resource_type: resource.Type = .checkpoint,
    action: []const u8 = "removed_spore",
    spore_dir: []const u8,
    ownership: []const u8 = saved_spore_ownership.portable_self_contained,
    /// Empty when the removed spore had no durable disk pin.
    pin_id: []const u8,
    pin_removed: bool = false,
};

pub fn deinit(allocator: std.mem.Allocator, result: Result) void {
    allocator.free(result.spore_dir);
    allocator.free(result.pin_id);
}

pub fn remove(context: Context, allocator: std.mem.Allocator, raw_dir: []const u8) !Result {
    const dir = try resolveExistingSporeDir(allocator, context.io, raw_dir);
    errdefer allocator.free(dir);
    try validateManifestPath(context.io, allocator, dir);
    var manifest = spore.loadManifest(allocator, dir) catch |err| switch (err) {
        error.BadManifest => null,
        else => |e| return e,
    };
    defer if (manifest) |*parsed| parsed.deinit();
    var manifest_v1: ?std.json.Parsed(spore.ManifestV1) = null;
    defer if (manifest_v1) |*parsed| parsed.deinit();
    if (manifest == null) manifest_v1 = try spore.loadManifestV1(allocator, dir);
    const disk = if (manifest) |parsed| parsed.value.disk else manifest_v1.?.value.disk;
    if (disk == null) {
        const ownership = try saved_spore_ownership.classify(allocator, dir, disk);
        try rejectDisklessPinReference(context.io, allocator, dir);
        const id = try allocator.alloc(u8, 0);
        errdefer allocator.free(id);
        try deleteAndSyncParent(context.io, allocator, dir);
        return .{ .spore_dir = dir, .ownership = ownership, .pin_id = id };
    }

    const local_authority = try localAuthorityState(context.io, allocator, dir, disk.?);
    const pin_reference = try pinReferencePresent(context.io, allocator, dir);
    if (local_authority == .verified and pin_reference) return error.BadManifest;

    // Pack/unpack and pull materialize a complete descriptor-bound CAS inside
    // the spore. It is safe to remove only while no live runtime owns that
    // directory as its lazy disk baseline.
    if (local_authority == .verified) {
        const ownership = try saved_spore_ownership.classify(allocator, dir, disk);
        const runtime_root = try local_paths.runtimeRootPath(allocator, context.environ_map);
        defer allocator.free(runtime_root);
        var lease_lock = try runtime_disk_lease.lockRegistry(context.io, allocator, runtime_root);
        defer lease_lock.deinit();
        if (try runtime_disk_lease.savedSporeActiveLocked(
            context.io,
            allocator,
            runtime_root,
            dir,
            &lease_lock,
        )) return error.SavedSporeInUse;
        const id = try allocator.alloc(u8, 0);
        errdefer allocator.free(id);
        try deleteAndSyncParent(context.io, allocator, dir);
        return .{ .spore_dir = dir, .ownership = ownership, .pin_id = id };
    }

    const cache_root = try local_paths.rootfsCacheRootPath(allocator, context.environ_map);
    defer allocator.free(cache_root);
    var lock = try rootfs_mod.lockRootfsCacheExclusive(context.io, allocator, cache_root);
    defer lock.deinit();
    const registry = try saved_spore_pin.LockedRegistry.init(allocator, cache_root, &lock);
    var pin = try saved_spore_pin.loadForSporeLocked(context.io, allocator, registry, dir, disk.?);
    defer pin.deinit();
    if (!saved_spore_pin.isExclusive(pin.value)) return error.LegacySharedPinRemovalRefused;
    const ownership = try saved_spore_ownership.classify(allocator, dir, disk);
    const id = try allocator.dupe(u8, pin.value.id);
    errdefer allocator.free(id);
    try deleteAndSyncParent(context.io, allocator, dir);
    try saved_spore_pin.remove(context.io, allocator, registry, id);
    return .{ .spore_dir = dir, .ownership = ownership, .pin_id = id, .pin_removed = true };
}

fn resolveExistingSporeDir(allocator: std.mem.Allocator, io: Io, raw: []const u8) ![]const u8 {
    const path = try std.fs.path.resolve(allocator, &.{raw});
    defer allocator.free(path);
    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .directory) return error.InvalidSporeDir;
    var real_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const real_len = try Io.Dir.cwd().realPathFile(io, path, &real_buf);
    return allocator.dupe(u8, real_buf[0..real_len]);
}

fn validateManifestPath(io: Io, allocator: std.mem.Allocator, dir: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, "manifest.json" });
    defer allocator.free(path);
    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.BadManifest;
}

fn rejectDisklessPinReference(io: Io, allocator: std.mem.Allocator, dir: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, saved_spore_pin.reference_file });
    defer allocator.free(path);
    _ = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    return error.BadManifest;
}

const LocalAuthorityState = enum { absent, verified };

fn localAuthorityState(io: Io, allocator: std.mem.Allocator, dir: []const u8, disk: spore.Disk) !LocalAuthorityState {
    const storage = try saved_spore_pin.storageForDisk(disk);
    const index_path = try rootfs_cas.manifestIndexPath(allocator, dir, storage.index_digest);
    defer allocator.free(index_path);
    const stat = Io.Dir.cwd().statFile(io, index_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => |e| return e,
    };
    if (stat.kind != .file) return error.BadManifest;
    verifyLocalAuthority(allocator, dir, storage) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadManifest,
    };
    return .verified;
}

fn verifyLocalAuthority(allocator: std.mem.Allocator, dir: []const u8, storage: spore.RootfsStorage) !void {
    const index_path = try rootfs_cas.manifestIndexPath(allocator, dir, storage.index_digest);
    defer allocator.free(index_path);
    const index_bytes = try rootfs_cas.readVerifiedStorageIndexPath(allocator, index_path, storage);
    defer allocator.free(index_bytes);
    var parsed = try disk_index.parseDiskIndex(allocator, index_bytes, try spore.diskIndexDescriptorForStorage(storage));
    defer parsed.deinit();
    for (parsed.value.chunks) |entry| {
        const object_path = try rootfs_cas.manifestObjectPath(allocator, dir, entry.digest);
        defer allocator.free(object_path);
        const object = try rootfs_cas.readVerifiedChunkPath(
            allocator,
            object_path,
            entry.digest,
            try rootfs_cas.storageChunkLen(storage, entry.logical_chunk),
        );
        allocator.free(object);
    }
}

fn pinReferencePresent(io: Io, allocator: std.mem.Allocator, dir: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ dir, saved_spore_pin.reference_file });
    defer allocator.free(path);
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    if (stat.kind != .file) return error.BadManifest;
    return true;
}

const RemoveFault = enum { none, before_delete, before_parent_sync };
const testing = if (builtin.is_test) struct {
    var fault: RemoveFault = .none;
} else struct {};

fn deleteAndSyncParent(io: Io, allocator: std.mem.Allocator, dir: []const u8) !void {
    if (comptime builtin.is_test) if (testing.fault == .before_delete) return error.IoFailed;
    try Io.Dir.cwd().deleteTree(io, dir);
    if (comptime builtin.is_test) if (testing.fault == .before_parent_sync) return error.IoFailed;
    try chunk_sealer.fsyncDirPath(allocator, std.fs.path.dirname(dir) orelse ".");
}

fn saveDisklessManifestV1(allocator: std.mem.Allocator, dir: []const u8) !void {
    var vcpus = [_]spore.VcpuState{ testVcpu(0), testVcpu(1) };
    const redists = [_]gicv3.RedistributorState{
        .{ .mpidr = vcpus[0].mpidr, .regs = &.{} },
        .{ .mpidr = vcpus[1].mpidr, .regs = &.{} },
    };
    try spore.saveManifestV1(allocator, dir, .{
        .platform = .{
            .cpu_profile = "sporevm-aarch64-v0",
            .device_model_version = 4,
            .vcpu_count = 2,
            .ram_base = 0x8000_0000,
            .ram_size = 1,
            .gic_dist_base = 0x0800_0000,
            .gic_redist_base = 0x0802_0000,
            .gic_redist_stride = 0x2_0000,
            .counter_frequency_hz = 24_000_000,
        },
        .machine = .{
            .vcpus = &vcpus,
            .gic = .{ .kind = .gicv3_multi, .gicv3_multi = .{
                .dist_regs = &.{},
                .redistributors = &redists,
                .line_levels = &.{},
            } },
        },
        .devices = &.{},
        .generation = .{ .generation = 0, .interrupt_status = 0, .params_b64 = "" },
        .memory = .{ .logical_size = 1, .chunk_size = spore.chunk_size, .zero_chunks = &.{0} },
    });
}

fn testVcpu(index: topology.VcpuIndex) spore.VcpuState {
    return .{
        .index = index,
        .mpidr = aarch64_topology.mpidrForIndex(index),
        .gprs = [_]u64{0} ** 31,
        .pc = 0,
        .cpsr = 0,
        .fpcr = 0,
        .fpsr = 0,
        .simd = [_][2]u64{.{ 0, 0 }} ** 32,
        .sys_regs = &.{},
        .icc_regs = &.{},
        .vtimer = .{ .cntvct = 0, .cntv_ctl = 0, .cntv_cval = 0 },
    };
}

test "saved-spore removal supports diskless current and multi-vcpu manifests" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    const current_dir = try std.fs.path.join(allocator, &.{ root, "current.spore" });
    defer allocator.free(current_dir);
    try Io.Dir.cwd().createDirPath(io, current_dir);
    try spore.saveManifest(allocator, current_dir, manifest_test_support.manifest(.{}));
    const current = try remove(.{ .io = io, .environ_map = &env }, allocator, current_dir);
    defer deinit(allocator, current);
    try std.testing.expectEqualStrings(current_dir, current.spore_dir);
    try std.testing.expectEqual(@as(usize, 0), current.pin_id.len);
    try std.testing.expect(!current.pin_removed);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, current_dir, .{ .follow_symlinks = false }));
    try std.testing.expectError(error.FileNotFound, remove(.{ .io = io, .environ_map = &env }, allocator, current_dir));

    const v1_dir = try std.fs.path.join(allocator, &.{ root, "multi.spore" });
    defer allocator.free(v1_dir);
    try Io.Dir.cwd().createDirPath(io, v1_dir);
    try saveDisklessManifestV1(allocator, v1_dir);
    const v1 = try remove(.{ .io = io, .environ_map = &env }, allocator, v1_dir);
    defer deinit(allocator, v1);
    try std.testing.expectEqual(@as(usize, 0), v1.pin_id.len);
    try std.testing.expect(!v1.pin_removed);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, v1_dir, .{ .follow_symlinks = false }));
}

test "saved-spore removal supports portable disk-backed manifests without a pin" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const cache_root = try std.fs.path.join(arena, &.{ root, "cache" });
    const portable_dir = try std.fs.path.join(arena, &.{ root, "portable.spore" });
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_root);

    const portable = try manifest_test_support.diskFixture(arena, io, cache_root, portable_dir, 0x41, true);
    try spore.saveManifest(arena, portable_dir, portable.manifest);
    const removed = try remove(.{ .io = io, .environ_map = &env }, allocator, portable_dir);
    defer deinit(allocator, removed);
    try std.testing.expectEqualStrings(portable_dir, removed.spore_dir);
    try std.testing.expectEqual(@as(usize, 0), removed.pin_id.len);
    try std.testing.expect(!removed.pin_removed);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, portable_dir, .{ .follow_symlinks = false }));

    // Removing portable-local authority must not mutate the shared cache.
    const cache_index = try rootfs_cas.manifestIndexPath(arena, cache_root, portable.storage.index_digest);
    const cache_stat = try Io.Dir.cwd().statFile(io, cache_index, .{ .follow_symlinks = false });
    try std.testing.expectEqual(Io.File.Kind.file, cache_stat.kind);
    const pins = try saved_spore_pin.list(io, allocator, cache_root);
    defer saved_spore_pin.deinitListings(allocator, pins);
    try std.testing.expectEqual(@as(usize, 0), pins.len);
}

test "portable saved-spore removal refuses a live authority after descriptor replacement" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const cache_root = try std.fs.path.join(arena, &.{ root, "cache" });
    const runtime_root = try std.fs.path.join(arena, &.{ root, "runtime" });
    const portable_dir = try std.fs.path.join(arena, &.{ root, "portable-active.spore" });
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_root);
    try env.put(local_paths.runtime_dir_env, runtime_root);

    const original = try manifest_test_support.diskFixture(arena, io, cache_root, portable_dir, 0x43, true);
    try spore.saveManifest(arena, portable_dir, original.manifest);
    var active = try runtime_disk_lease.acquireActive(
        io,
        allocator,
        runtime_root,
        try runtime_disk_lease.fromSavedDisk(portable_dir, original.disk),
    );

    // A live lazy runtime still owns the original descriptor even if another
    // valid portable authority replaces the manifest under the same root.
    const replacement = try manifest_test_support.diskFixture(arena, io, cache_root, portable_dir, 0x53, true);
    try std.testing.expect(!std.mem.eql(u8, original.storage.index_digest, replacement.storage.index_digest));
    try spore.saveManifest(arena, portable_dir, replacement.manifest);
    try std.testing.expectError(
        error.SavedSporeInUse,
        remove(.{ .io = io, .environ_map = &env }, allocator, portable_dir),
    );
    _ = try Io.Dir.cwd().statFile(io, portable_dir, .{ .follow_symlinks = false });
    active.deinit();

    const removed = try remove(.{ .io = io, .environ_map = &env }, allocator, portable_dir);
    defer deinit(allocator, removed);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, portable_dir, .{ .follow_symlinks = false }));
}

test "portable saved-spore removal verifies local authority before deletion" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const cache_root = try std.fs.path.join(arena, &.{ root, "cache" });
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_root);

    const corrupt_dir = try std.fs.path.join(arena, &.{ root, "corrupt.spore" });
    const corrupt = try manifest_test_support.diskFixture(arena, io, cache_root, corrupt_dir, 0x44, true);
    try spore.saveManifest(arena, corrupt_dir, corrupt.manifest);
    const corrupt_index = try rootfs_cas.manifestIndexPath(arena, corrupt_dir, corrupt.storage.index_digest);
    try Io.Dir.cwd().deleteFile(io, corrupt_index);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = corrupt_index, .data = "corrupt" });
    try std.testing.expectError(error.BadManifest, remove(.{ .io = io, .environ_map = &env }, allocator, corrupt_dir));
    _ = try Io.Dir.cwd().statFile(io, corrupt_dir, .{ .follow_symlinks = false });

    const symlink_dir = try std.fs.path.join(arena, &.{ root, "symlink.spore" });
    const symlinked = try manifest_test_support.diskFixture(arena, io, cache_root, symlink_dir, 0x45, true);
    try spore.saveManifest(arena, symlink_dir, symlinked.manifest);
    const symlink_index = try rootfs_cas.manifestIndexPath(arena, symlink_dir, symlinked.storage.index_digest);
    try Io.Dir.cwd().deleteFile(io, symlink_index);
    const target = try std.fs.path.join(arena, &.{ root, "index-target" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = "not an index" });
    try Io.Dir.cwd().symLink(io, target, symlink_index, .{});
    try std.testing.expectError(error.BadManifest, remove(.{ .io = io, .environ_map = &env }, allocator, symlink_dir));
    _ = try Io.Dir.cwd().statFile(io, symlink_dir, .{ .follow_symlinks = false });

    const corrupt_object_dir = try std.fs.path.join(arena, &.{ root, "corrupt-object.spore" });
    const corrupt_object = try manifest_test_support.diskFixture(arena, io, cache_root, corrupt_object_dir, 0x48, true);
    try spore.saveManifest(arena, corrupt_object_dir, corrupt_object.manifest);
    const corrupt_object_path = try rootfs_cas.manifestObjectPath(arena, corrupt_object_dir, corrupt_object.object_digest);
    const corrupt_object_bytes = try Io.Dir.cwd().readFileAlloc(io, corrupt_object_path, arena, .limited(rootfs_cas.default_chunk_size));
    corrupt_object_bytes[0] ^= 0xff;
    try Io.Dir.cwd().deleteFile(io, corrupt_object_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = corrupt_object_path, .data = corrupt_object_bytes });
    try std.testing.expectError(error.BadManifest, remove(.{ .io = io, .environ_map = &env }, allocator, corrupt_object_dir));
    _ = try Io.Dir.cwd().statFile(io, corrupt_object_dir, .{ .follow_symlinks = false });

    const partial_dir = try std.fs.path.join(arena, &.{ root, "partial.spore" });
    const partial = try manifest_test_support.diskFixture(arena, io, cache_root, partial_dir, 0x46, true);
    try spore.saveManifest(arena, partial_dir, partial.manifest);
    const partial_object = try rootfs_cas.manifestObjectPath(arena, partial_dir, partial.object_digest);
    try Io.Dir.cwd().deleteFile(io, partial_object);
    try std.testing.expectError(error.BadManifest, remove(.{ .io = io, .environ_map = &env }, allocator, partial_dir));
    _ = try Io.Dir.cwd().statFile(io, partial_dir, .{ .follow_symlinks = false });

    const pinned_dir = try std.fs.path.join(arena, &.{ root, "pinned-stray.spore" });
    const pinned = try manifest_test_support.diskFixture(arena, io, cache_root, pinned_dir, 0x47, false);
    var pin_id: []const u8 = undefined;
    {
        var lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, cache_root);
        defer lock.deinit();
        const registry = try saved_spore_pin.LockedRegistry.init(arena, cache_root, &lock);
        try saved_spore_pin.publishManifest(io, arena, registry, pinned_dir, pinned.disk, pinned.manifest);
        var record = try saved_spore_pin.loadForSporeLocked(io, arena, registry, pinned_dir, pinned.disk);
        defer record.deinit();
        pin_id = try arena.dupe(u8, record.value.id);
    }
    const stray_index = try rootfs_cas.manifestIndexPath(arena, pinned_dir, pinned.storage.index_digest);
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(stray_index).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = stray_index, .data = "stray" });
    try std.testing.expectError(error.BadManifest, remove(.{ .io = io, .environ_map = &env }, allocator, pinned_dir));
    _ = try Io.Dir.cwd().statFile(io, pinned_dir, .{ .follow_symlinks = false });
    var record = try saved_spore_pin.loadRecord(io, allocator, cache_root, pin_id);
    record.deinit();
}

test "saved-spore removal keeps unpinned disk manifests without local authority" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const cache_root = try std.fs.path.join(arena, &.{ root, "cache" });
    const unpinned_dir = try std.fs.path.join(arena, &.{ root, "unpinned.spore" });
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_root);

    const unpinned = try manifest_test_support.diskFixture(arena, io, cache_root, unpinned_dir, 0x42, false);
    try spore.saveManifest(arena, unpinned_dir, unpinned.manifest);
    try std.testing.expectError(error.FileNotFound, remove(.{ .io = io, .environ_map = &env }, allocator, unpinned_dir));
    const dir_stat = try Io.Dir.cwd().statFile(io, unpinned_dir, .{ .follow_symlinks = false });
    try std.testing.expectEqual(Io.File.Kind.directory, dir_stat.kind);
}

test "saved-spore removal rejects malformed and symlinked diskless inputs" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    const malformed = try std.fs.path.join(allocator, &.{ root, "malformed.spore" });
    defer allocator.free(malformed);
    try Io.Dir.cwd().createDirPath(io, malformed);
    const malformed_manifest = try std.fs.path.join(allocator, &.{ malformed, "manifest.json" });
    defer allocator.free(malformed_manifest);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = malformed_manifest, .data = "{}" });
    try std.testing.expectError(error.BadManifest, remove(.{ .io = io, .environ_map = &env }, allocator, malformed));
    _ = try Io.Dir.cwd().statFile(io, malformed, .{ .follow_symlinks = false });

    const pinned_diskless = try std.fs.path.join(allocator, &.{ root, "pinned-diskless.spore" });
    defer allocator.free(pinned_diskless);
    try Io.Dir.cwd().createDirPath(io, pinned_diskless);
    try spore.saveManifest(allocator, pinned_diskless, manifest_test_support.manifest(.{}));
    const stale_ref = try std.fs.path.join(allocator, &.{ pinned_diskless, saved_spore_pin.reference_file });
    defer allocator.free(stale_ref);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = stale_ref, .data = "stale" });
    try std.testing.expectError(error.BadManifest, remove(.{ .io = io, .environ_map = &env }, allocator, pinned_diskless));
    _ = try Io.Dir.cwd().statFile(io, pinned_diskless, .{ .follow_symlinks = false });

    const target = try std.fs.path.join(allocator, &.{ root, "manifest-target.json" });
    defer allocator.free(target);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = "{}" });
    const linked_manifest_dir = try std.fs.path.join(allocator, &.{ root, "linked-manifest.spore" });
    defer allocator.free(linked_manifest_dir);
    try Io.Dir.cwd().createDirPath(io, linked_manifest_dir);
    const linked_manifest = try std.fs.path.join(allocator, &.{ linked_manifest_dir, "manifest.json" });
    defer allocator.free(linked_manifest);
    try Io.Dir.cwd().symLink(io, target, linked_manifest, .{});
    try std.testing.expectError(error.BadManifest, remove(.{ .io = io, .environ_map = &env }, allocator, linked_manifest_dir));

    const victim = try std.fs.path.join(allocator, &.{ root, "victim.spore" });
    defer allocator.free(victim);
    try Io.Dir.cwd().createDirPath(io, victim);
    try spore.saveManifest(allocator, victim, manifest_test_support.manifest(.{}));
    const linked_dir = try std.fs.path.join(allocator, &.{ root, "linked.spore" });
    defer allocator.free(linked_dir);
    try Io.Dir.cwd().symLink(io, victim, linked_dir, .{});
    try std.testing.expectError(error.InvalidSporeDir, remove(.{ .io = io, .environ_map = &env }, allocator, linked_dir));
    _ = try Io.Dir.cwd().statFile(io, victim, .{ .follow_symlinks = false });
}

test "saved-spore removal faults preserve diskless visibility boundaries" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    defer testing.fault = .none;

    const before_delete = try std.fs.path.join(allocator, &.{ root, "before-delete.spore" });
    defer allocator.free(before_delete);
    try Io.Dir.cwd().createDirPath(io, before_delete);
    try spore.saveManifest(allocator, before_delete, manifest_test_support.manifest(.{}));
    testing.fault = .before_delete;
    try std.testing.expectError(error.IoFailed, remove(.{ .io = io, .environ_map = &env }, allocator, before_delete));
    _ = try Io.Dir.cwd().statFile(io, before_delete, .{ .follow_symlinks = false });

    const before_sync = try std.fs.path.join(allocator, &.{ root, "before-sync.spore" });
    defer allocator.free(before_sync);
    try Io.Dir.cwd().createDirPath(io, before_sync);
    try spore.saveManifest(allocator, before_sync, manifest_test_support.manifest(.{}));
    testing.fault = .before_parent_sync;
    try std.testing.expectError(error.IoFailed, remove(.{ .io = io, .environ_map = &env }, allocator, before_sync));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, before_sync, .{ .follow_symlinks = false }));
}

test "saved-spore removal preserves disk pin ordering across delete and sync faults" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const cache_root = try std.fs.path.join(arena, &.{ root, "cache" });
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_root);
    defer testing.fault = .none;

    const before_delete = try std.fs.path.join(arena, &.{ root, "disk-before-delete.spore" });
    const first = try manifest_test_support.diskFixture(arena, io, cache_root, before_delete, 0x31, false);
    var first_id: []const u8 = undefined;
    {
        var lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, cache_root);
        defer lock.deinit();
        const registry = try saved_spore_pin.LockedRegistry.init(arena, cache_root, &lock);
        try saved_spore_pin.publishManifest(io, arena, registry, before_delete, first.disk, first.manifest);
        var pin = try saved_spore_pin.loadForSporeLocked(io, arena, registry, before_delete, first.disk);
        defer pin.deinit();
        first_id = try arena.dupe(u8, pin.value.id);
    }
    testing.fault = .before_delete;
    try std.testing.expectError(error.IoFailed, remove(.{ .io = io, .environ_map = &env }, allocator, before_delete));
    _ = try Io.Dir.cwd().statFile(io, before_delete, .{ .follow_symlinks = false });
    var first_record = try saved_spore_pin.loadRecord(io, allocator, cache_root, first_id);
    try std.testing.expectEqual(saved_spore_pin.OwnerState.exclusive, try saved_spore_pin.ownerState(arena, cache_root, first_id, first_record.value));
    first_record.deinit();

    const before_sync = try std.fs.path.join(arena, &.{ root, "disk-before-sync.spore" });
    const second = try manifest_test_support.diskFixture(arena, io, cache_root, before_sync, 0x32, false);
    var second_id: []const u8 = undefined;
    {
        var lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, cache_root);
        defer lock.deinit();
        const registry = try saved_spore_pin.LockedRegistry.init(arena, cache_root, &lock);
        try saved_spore_pin.publishManifest(io, arena, registry, before_sync, second.disk, second.manifest);
        var pin = try saved_spore_pin.loadForSporeLocked(io, arena, registry, before_sync, second.disk);
        defer pin.deinit();
        second_id = try arena.dupe(u8, pin.value.id);
    }
    testing.fault = .before_parent_sync;
    try std.testing.expectError(error.IoFailed, remove(.{ .io = io, .environ_map = &env }, allocator, before_sync));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, before_sync, .{ .follow_symlinks = false }));
    var second_record = try saved_spore_pin.loadRecord(io, allocator, cache_root, second_id);
    try std.testing.expectEqual(saved_spore_pin.OwnerState.orphaned, try saved_spore_pin.ownerState(arena, cache_root, second_id, second_record.value));
    second_record.deinit();

    testing.fault = .none;
    const removed = try remove(.{ .io = io, .environ_map = &env }, allocator, before_delete);
    defer deinit(allocator, removed);
    try std.testing.expect(removed.pin_removed);
    try std.testing.expectEqualStrings(first_id, removed.pin_id);
    try std.testing.expectError(error.FileNotFound, saved_spore_pin.loadRecord(io, allocator, cache_root, first_id));
}

test "saved-spore removal refuses an ordinary copied pin reference" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const cache_root = try std.fs.path.join(arena, &.{ root, "cache" });
    const original = try std.fs.path.join(arena, &.{ root, "original.spore" });
    const copied = try std.fs.path.join(arena, &.{ root, "copied.spore" });
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_root);
    const fixture = try manifest_test_support.diskFixture(arena, io, cache_root, original, 0x61, false);
    var pin_id: []const u8 = undefined;
    {
        var lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, cache_root);
        defer lock.deinit();
        const registry = try saved_spore_pin.LockedRegistry.init(arena, cache_root, &lock);
        try saved_spore_pin.publishManifest(io, arena, registry, original, fixture.disk, fixture.manifest);
        var pin = try saved_spore_pin.loadForSporeLocked(io, arena, registry, original, fixture.disk);
        defer pin.deinit();
        pin_id = try arena.dupe(u8, pin.value.id);
    }
    try Io.Dir.cwd().createDirPath(io, copied);
    inline for (.{ "manifest.json", saved_spore_pin.reference_file }) |name| {
        const source = try std.fs.path.join(arena, &.{ original, name });
        const destination = try std.fs.path.join(arena, &.{ copied, name });
        const bytes = try Io.Dir.cwd().readFileAlloc(io, source, arena, .limited(saved_spore_pin.max_manifest_bytes + 1));
        try chunk_sealer.writeFileAtomicDurable(arena, destination, bytes, 0o600);
    }

    try std.testing.expectError(error.SavedSporeOwnershipConflict, remove(.{ .io = io, .environ_map = &env }, allocator, copied));
    _ = try Io.Dir.cwd().statFile(io, original, .{ .follow_symlinks = false });
    _ = try Io.Dir.cwd().statFile(io, copied, .{ .follow_symlinks = false });
    var record = try saved_spore_pin.loadRecord(io, allocator, cache_root, pin_id);
    record.deinit();
}

test "saved-spore removal refuses legacy pins with unknowable duplicate references" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const cache_root = try std.fs.path.join(arena, &.{ root, "cache" });
    const saved = try std.fs.path.join(arena, &.{ root, "legacy.spore" });
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_root);
    const fixture = try manifest_test_support.diskFixture(arena, io, cache_root, saved, 0x62, false);
    var pin_id: []const u8 = undefined;
    {
        var lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, cache_root);
        defer lock.deinit();
        const registry = try saved_spore_pin.LockedRegistry.init(arena, cache_root, &lock);
        try saved_spore_pin.publishManifest(io, arena, registry, saved, fixture.disk, fixture.manifest);
        var current = try saved_spore_pin.loadForSporeLocked(io, arena, registry, saved, fixture.disk);
        defer current.deinit();
        pin_id = try arena.dupe(u8, current.value.id);
        const record_path = try saved_spore_pin.recordPath(arena, cache_root, pin_id);
        const legacy_record = try std.json.Stringify.valueAlloc(arena, saved_spore_pin.Record{
            .schema = saved_spore_pin.legacy_schema,
            .id = current.value.id,
            .manifest_sha256 = current.value.manifest_sha256,
            .storage = current.value.storage,
        }, .{ .whitespace = .indent_2 });
        try chunk_sealer.replaceFileAtomicDurable(arena, record_path, legacy_record, 0o600);
        const ref_path = try std.fs.path.join(arena, &.{ saved, saved_spore_pin.reference_file });
        const legacy_ref = try std.json.Stringify.valueAlloc(arena, saved_spore_pin.Reference{
            .schema = saved_spore_pin.legacy_reference_schema,
            .id = current.value.id,
        }, .{ .whitespace = .indent_2 });
        try chunk_sealer.replaceFileAtomicDurable(arena, ref_path, legacy_ref, 0o600);
    }

    try std.testing.expectError(error.LegacySharedPinRemovalRefused, remove(.{ .io = io, .environ_map = &env }, allocator, saved));
    _ = try Io.Dir.cwd().statFile(io, saved, .{ .follow_symlinks = false });
    var record = try saved_spore_pin.loadRecord(io, allocator, cache_root, pin_id);
    record.deinit();
}
