//! Process-boundary recovery proof for durable saved-disk authority.
//!
//! The build runs only the test below in a dedicated Zig test binary. Its
//! parent re-execs that exact binary with a private environment selector; the
//! child exits from test-only hooks inside production transactions, before
//! defer cleanup can rewrite the crash-left filesystem state.

const std = @import("std");

const bundle = @import("bundle.zig");
const chunk = @import("chunk.zig");
const Context = @import("context.zig").Context;
const disk_index = @import("disk_index.zig");
const lifecycle = @import("lifecycle.zig");
const local_paths = @import("local_paths.zig");
const manifest_test_support = @import("manifest_test_support.zig");
const monitor = @import("monitor.zig");
const rootfs = @import("rootfs.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const runtime_disk_lease = @import("runtime_disk_lease.zig");
const saved_spore_fork = @import("saved_spore_fork.zig");
const saved_spore_pin = @import("saved_spore_pin.zig");
const spore = @import("spore.zig");
const system = @import("system.zig");

const mode_env = "SPOREVM_DURABLE_CRASH_MODE";
const root_env = "SPOREVM_DURABLE_CRASH_ROOT";

test "durable process-boundary release proof" {
    const mode = getenv(mode_env);
    const root = getenv(root_env);
    if (mode != null or root != null) {
        if (mode == null or root == null) return error.BadManifest;
        try crashChild(mode.?, root.?);
        return error.TestUnexpectedResult;
    }

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const parent_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(parent_root);

    const pin_modes = [_][]const u8{
        "pin-staged-manifest",
        "pin-complete-stamp",
        "pin-record",
        "pin-reference-rename",
        "pin-manifest-rename",
        "pin-directory-sync",
    };
    for (pin_modes) |crash_mode| {
        const root_path = try std.fs.path.join(allocator, &.{ parent_root, crash_mode });
        defer allocator.free(root_path);
        try spawnCrashChild(allocator, io, crash_mode, root_path, 86);
        try recoverPinPublication(allocator, io, crash_mode, root_path);
    }

    const fork_modes = [_][]const u8{
        "fork-before-batch-rename",
        "fork-batch-rename",
        "fork-parent-sync",
    };
    for (fork_modes) |crash_mode| {
        const root_path = try std.fs.path.join(allocator, &.{ parent_root, crash_mode });
        defer allocator.free(root_path);
        try spawnCrashChild(allocator, io, crash_mode, root_path, 87);
        try recoverForkPublication(allocator, io, crash_mode, root_path);
    }

    const handoff_modes = [_][]const u8{ "handoff-active-lease", "handoff-source-spec" };
    for (handoff_modes) |crash_mode| {
        const root_path = try std.fs.path.join(allocator, &.{ parent_root, crash_mode });
        defer allocator.free(root_path);
        try spawnCrashChild(allocator, io, crash_mode, root_path, 88);
        try recoverSourceLeaseHandoff(allocator, io, crash_mode, root_path);
    }
}

fn crashChild(mode: []const u8, root_path: []const u8) !void {
    const allocator = std.heap.smp_allocator;
    const io = std.testing.io;
    try std.Io.Dir.cwd().createDirPath(io, root_path);
    if (std.mem.startsWith(u8, mode, "pin-")) return crashPinPublication(allocator, io, mode, root_path);
    if (std.mem.startsWith(u8, mode, "fork-")) return crashForkPublication(allocator, io, mode, root_path);
    if (std.mem.startsWith(u8, mode, "handoff-")) return crashSourceLeaseHandoff(allocator, io, mode, root_path);
    return error.BadManifest;
}

fn crashPinPublication(allocator: std.mem.Allocator, io: std.Io, mode: []const u8, root_path: []const u8) !void {
    const cache_root = try std.fs.path.join(allocator, &.{ root_path, "cache" });
    const save_dir = try std.fs.path.join(allocator, &.{ root_path, "saved.spore" });
    const fixture = try manifest_test_support.diskFixture(allocator, io, cache_root, save_dir, 0x81, false);
    saved_spore_pin.testing.publish_fault = .{ .crash_after = if (std.mem.eql(u8, mode, "pin-staged-manifest"))
        .staged_manifest
    else if (std.mem.eql(u8, mode, "pin-complete-stamp"))
        .complete_stamp
    else if (std.mem.eql(u8, mode, "pin-record"))
        .pin_record
    else if (std.mem.eql(u8, mode, "pin-reference-rename"))
        .reference_rename
    else if (std.mem.eql(u8, mode, "pin-manifest-rename"))
        .manifest_rename
    else if (std.mem.eql(u8, mode, "pin-directory-sync"))
        .directory_sync
    else
        return error.BadManifest };
    var lock = try rootfs.lockRootfsCacheExclusive(io, allocator, cache_root);
    defer lock.deinit();
    const registry = try saved_spore_pin.LockedRegistry.init(allocator, cache_root, &lock);
    try saved_spore_pin.publishManifest(io, allocator, registry, save_dir, fixture.disk, fixture.manifest);
}

fn recoverPinPublication(allocator: std.mem.Allocator, io: std.Io, mode: []const u8, root_path: []const u8) !void {
    const cache_root = try std.fs.path.join(allocator, &.{ root_path, "cache" });
    defer allocator.free(cache_root);
    const runtime_root = try std.fs.path.join(allocator, &.{ root_path, "runtime" });
    defer allocator.free(runtime_root);
    const save_dir = try std.fs.path.join(allocator, &.{ root_path, "saved.spore" });
    defer allocator.free(save_dir);
    const visible = std.mem.eql(u8, mode, "pin-manifest-rename") or std.mem.eql(u8, mode, "pin-directory-sync");
    const pinned = visible or std.mem.eql(u8, mode, "pin-record") or std.mem.eql(u8, mode, "pin-reference-rename");
    const manifest_path = try std.fs.path.join(allocator, &.{ save_dir, "manifest.json" });
    defer allocator.free(manifest_path);
    if (!visible) {
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, manifest_path, .{ .follow_symlinks = false }));
    }
    const listings = try saved_spore_pin.list(io, allocator, cache_root);
    defer saved_spore_pin.deinitListings(allocator, listings);
    try std.testing.expectEqual(@as(usize, if (pinned) 1 else 0), listings.len);
    const gc_result = try system.gc(allocator, io, .{ .cache_root = cache_root, .runtime_root = runtime_root, .dry_run = false });
    defer system.deinitRootfsGcResult(allocator, gc_result);
    const prune_result = try system.prune(allocator, io, .{
        .cache_root = cache_root,
        .runtime_root = runtime_root,
        .dry_run = false,
        .include_rootfs_chunks = true,
        .max_bytes = 0,
        .rootfs_only = true,
    }, std.Io.Clock.real.now(io).nanoseconds);
    defer system.deinitRootfsPruneResult(allocator, prune_result);
    if (!pinned) return;
    var expected_bytes: [512]u8 = undefined;
    @memset(&expected_bytes, 0x81);
    const object_id = chunk.ChunkId.fromContents(&expected_bytes);
    const object_hex = object_id.toHex();
    const object_digest = try std.fmt.allocPrint(allocator, "{s}{s}", .{ spore.rootfs_digest_prefix, object_hex[0..] });
    defer allocator.free(object_digest);
    const object_path = try rootfs_cas.manifestObjectPath(allocator, cache_root, object_digest);
    defer allocator.free(object_path);
    const bytes = try rootfs_cas.readVerifiedChunkPath(allocator, object_path, object_digest, expected_bytes.len);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &expected_bytes, bytes);
    if (visible) {
        var manifest = try spore.loadManifest(allocator, save_dir);
        defer manifest.deinit();
        {
            var lock = try rootfs.lockRootfsCacheExclusive(io, allocator, cache_root);
            defer lock.deinit();
            const registry = try saved_spore_pin.LockedRegistry.init(allocator, cache_root, &lock);
            var record = try saved_spore_pin.loadForSporeLocked(io, allocator, registry, save_dir, manifest.value.disk.?);
            record.deinit();
        }
        const bundle_dir = try std.fs.path.join(allocator, &.{ root_path, "visible.bundle" });
        defer allocator.free(bundle_dir);
        const unpacked_dir = try std.fs.path.join(allocator, &.{ root_path, "visible-unpacked.spore" });
        defer allocator.free(unpacked_dir);
        const unpack_cache = try std.fs.path.join(allocator, &.{ root_path, "unpack-cache" });
        defer allocator.free(unpack_cache);
        const pack_result = try bundle.pack(allocator, .{
            .io = io,
            .spore_dir = save_dir,
            .out_dir = bundle_dir,
            .rootfs_cache_dir = cache_root,
            .runtime_root = runtime_root,
        });
        const unpack_result = try bundle.unpack(allocator, .{
            .io = io,
            .bundle_dir = bundle_dir,
            .out_dir = unpacked_dir,
            .rootfs_cache_dir = unpack_cache,
        });
        try std.testing.expectEqualStrings(pack_result.bundle_digest, unpack_result.bundle_digest);
        const unpacked_object = try rootfs_cas.manifestObjectPath(allocator, unpacked_dir, object_digest);
        defer allocator.free(unpacked_object);
        const unpacked_bytes = try rootfs_cas.readVerifiedChunkPath(allocator, unpacked_object, object_digest, expected_bytes.len);
        defer allocator.free(unpacked_bytes);
        try std.testing.expectEqualSlices(u8, &expected_bytes, unpacked_bytes);
        var env = std.process.Environ.Map.init(allocator);
        defer env.deinit();
        try env.put(local_paths.rootfs_cache_env, cache_root);
        try env.put(local_paths.runtime_dir_env, runtime_root);
        const removed = try lifecycle.removeSavedSpore(Context{ .io = io, .environ_map = &env }, allocator, save_dir);
        lifecycle.deinitRemovedSavedSpore(allocator, removed);
        const post_remove_gc = try system.gc(allocator, io, .{ .cache_root = cache_root, .runtime_root = runtime_root, .dry_run = false });
        defer system.deinitRootfsGcResult(allocator, post_remove_gc);
        const post_remove_prune = try system.prune(allocator, io, .{
            .cache_root = cache_root,
            .runtime_root = runtime_root,
            .dry_run = false,
            .include_rootfs_chunks = true,
            .max_bytes = 0,
            .rootfs_only = true,
        }, std.Io.Clock.real.now(io).nanoseconds);
        defer system.deinitRootfsPruneResult(allocator, post_remove_prune);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, object_path, .{ .follow_symlinks = false }));
    }
}

fn crashForkPublication(allocator: std.mem.Allocator, io: std.Io, mode: []const u8, root_path: []const u8) !void {
    const cache_root = try std.fs.path.join(allocator, &.{ root_path, "cache" });
    const runtime_root = try std.fs.path.join(allocator, &.{ root_path, "runtime" });
    const parent_dir = try std.fs.path.join(allocator, &.{ root_path, "parent.spore" });
    const children_dir = try std.fs.path.join(allocator, &.{ root_path, "children" });
    const fixture = try manifest_test_support.diskFixture(allocator, io, cache_root, parent_dir, 0x82, false);
    var lock = try rootfs.lockRootfsCacheExclusive(io, allocator, cache_root);
    const registry = try saved_spore_pin.LockedRegistry.init(allocator, cache_root, &lock);
    try saved_spore_pin.publishManifest(io, allocator, registry, parent_dir, fixture.disk, fixture.manifest);
    lock.deinit();
    var env = std.process.Environ.Map.init(allocator);
    try env.put(local_paths.rootfs_cache_env, cache_root);
    try env.put(local_paths.runtime_dir_env, runtime_root);
    saved_spore_fork.testing.fault = .{ .crash_after = if (std.mem.eql(u8, mode, "fork-before-batch-rename"))
        .before_batch_rename
    else if (std.mem.eql(u8, mode, "fork-batch-rename"))
        .batch_rename
    else if (std.mem.eql(u8, mode, "fork-parent-sync"))
        .parent_sync
    else
        return error.BadManifest };
    _ = try saved_spore_fork.execute(Context{ .io = io, .environ_map = &env }, allocator, .{ .parent_dir = parent_dir, .out_dir = children_dir, .count = 2 });
}

fn recoverForkPublication(allocator: std.mem.Allocator, io: std.Io, mode: []const u8, root_path: []const u8) !void {
    const cache_root = try std.fs.path.join(allocator, &.{ root_path, "cache" });
    defer allocator.free(cache_root);
    const runtime_root = try std.fs.path.join(allocator, &.{ root_path, "runtime" });
    defer allocator.free(runtime_root);
    const parent_dir = try std.fs.path.join(allocator, &.{ root_path, "parent.spore" });
    defer allocator.free(parent_dir);
    const children_dir = try std.fs.path.join(allocator, &.{ root_path, "children" });
    defer allocator.free(children_dir);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_root);
    try env.put(local_paths.runtime_dir_env, runtime_root);
    const removed = try lifecycle.removeSavedSpore(Context{ .io = io, .environ_map = &env }, allocator, parent_dir);
    lifecycle.deinitRemovedSavedSpore(allocator, removed);
    const gc_result = try system.gc(allocator, io, .{ .cache_root = cache_root, .runtime_root = runtime_root, .dry_run = false });
    defer system.deinitRootfsGcResult(allocator, gc_result);
    const prune_result = try system.prune(allocator, io, .{
        .cache_root = cache_root,
        .runtime_root = runtime_root,
        .dry_run = false,
        .include_rootfs_chunks = true,
        .max_bytes = 0,
        .rootfs_only = true,
    }, std.Io.Clock.real.now(io).nanoseconds);
    defer system.deinitRootfsPruneResult(allocator, prune_result);
    const visible = !std.mem.eql(u8, mode, "fork-before-batch-rename");
    if (!visible) {
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, children_dir, .{ .follow_symlinks = false }));
        return;
    }
    for (0..2) |index| {
        const child = try std.fmt.allocPrint(allocator, "{s}/{d:0>6}", .{ children_dir, index });
        defer allocator.free(child);
        var manifest = try spore.loadManifest(allocator, child);
        defer manifest.deinit();
        {
            var lock = try rootfs.lockRootfsCacheExclusive(io, allocator, cache_root);
            defer lock.deinit();
            const registry = try saved_spore_pin.LockedRegistry.init(allocator, cache_root, &lock);
            var record = try saved_spore_pin.loadForSporeLocked(io, allocator, registry, child, manifest.value.disk.?);
            record.deinit();
        }
        const disk = manifest.value.disk orelse return error.BadManifest;
        const storage = try saved_spore_pin.storageForDisk(disk);
        const index_path = try rootfs_cas.manifestIndexPath(allocator, cache_root, storage.index_digest);
        defer allocator.free(index_path);
        const index_bytes = try rootfs_cas.readVerifiedStorageIndexPath(allocator, index_path, storage);
        defer allocator.free(index_bytes);
        var parsed = try disk_index.parseDiskIndex(allocator, index_bytes, try spore.diskIndexDescriptorForStorage(storage));
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 1), parsed.value.chunks.len);
        const object_path = try rootfs_cas.manifestObjectPath(allocator, cache_root, parsed.value.chunks[0].digest);
        defer allocator.free(object_path);
        const bytes = try rootfs_cas.readVerifiedChunkPath(allocator, object_path, parsed.value.chunks[0].digest, 512);
        defer allocator.free(bytes);
        var expected: [512]u8 = undefined;
        @memset(&expected, 0x82);
        try std.testing.expectEqualSlices(u8, &expected, bytes);
    }
    const nested_dir = try std.fs.path.join(allocator, &.{ root_path, "nested" });
    defer allocator.free(nested_dir);
    const first_child = try std.fs.path.join(allocator, &.{ children_dir, "000000" });
    defer allocator.free(first_child);
    _ = try saved_spore_fork.execute(Context{ .io = io, .environ_map = &env }, allocator, .{ .parent_dir = first_child, .out_dir = nested_dir, .count = 1 });
    for (0..2) |index| {
        const child = try std.fmt.allocPrint(allocator, "{s}/{d:0>6}", .{ children_dir, index });
        defer allocator.free(child);
        const removed_child = try lifecycle.removeSavedSpore(Context{ .io = io, .environ_map = &env }, allocator, child);
        lifecycle.deinitRemovedSavedSpore(allocator, removed_child);
    }
}

fn crashSourceLeaseHandoff(allocator: std.mem.Allocator, io: std.Io, mode: []const u8, root_path: []const u8) !void {
    const cache_root = try std.fs.path.join(allocator, &.{ root_path, "cache" });
    const runtime_root = try std.fs.path.join(allocator, &.{ root_path, "runtime" });
    const old_dir = try std.fs.path.join(allocator, &.{ root_path, "old" });
    const new_dir = try std.fs.path.join(allocator, &.{ root_path, "new" });
    const old_fixture = try manifest_test_support.diskFixture(allocator, io, cache_root, old_dir, 0x83, false);
    const new_fixture = try manifest_test_support.diskFixture(allocator, io, cache_root, new_dir, 0x84, false);
    try rootfs_cas.markStorageComplete(io, allocator, cache_root, old_fixture.storage.index_digest);
    try rootfs_cas.markStorageComplete(io, allocator, cache_root, new_fixture.storage.index_digest);
    const paths = try lifecycle.pathsFromRoot(allocator, runtime_root, "source");
    const old_lease = leaseFor(cache_root, old_fixture.storage);
    const new_lease = leaseFor(cache_root, new_fixture.storage);
    try lifecycle.writeSpec(allocator, io, paths, .{ .name = "source", .disk = old_fixture.disk, .disk_baseline_lease = old_lease });
    var active: ?runtime_disk_lease.Active = try runtime_disk_lease.acquireActive(io, allocator, runtime_root, old_lease);
    monitor.testing.snapshot_lease_handoff_fault = .{ .crash_after = if (std.mem.eql(u8, mode, "handoff-active-lease"))
        .active_lease
    else if (std.mem.eql(u8, mode, "handoff-source-spec"))
        .source_spec
    else
        return error.BadManifest };
    try monitor.testing.persistSourceDiskLeaseHandoffForCrashProof(io, allocator, runtime_root, paths, new_fixture.disk, new_lease, &active);
}

fn recoverSourceLeaseHandoff(allocator: std.mem.Allocator, io: std.Io, mode: []const u8, root_path: []const u8) !void {
    const cache_root = try std.fs.path.join(allocator, &.{ root_path, "cache" });
    defer allocator.free(cache_root);
    const runtime_root = try std.fs.path.join(allocator, &.{ root_path, "runtime" });
    defer allocator.free(runtime_root);
    const expected_seed: u8 = if (std.mem.eql(u8, mode, "handoff-source-spec")) 0x84 else 0x83;
    const paths = try lifecycle.pathsFromRoot(allocator, runtime_root, "source");
    defer paths.deinit(allocator);
    var spec = try lifecycle.readSpec(allocator, io, paths);
    defer spec.deinit();
    const lease = spec.value.disk_baseline_lease orelse return error.BadManifest;
    var restarted = try runtime_disk_lease.acquireActive(io, allocator, runtime_root, lease);
    defer restarted.deinit();
    const index_path = try rootfs_cas.manifestIndexPath(allocator, cache_root, lease.baseline_identity);
    defer allocator.free(index_path);
    const index_bytes = try rootfs_cas.readVerifiedStorageIndexPath(allocator, index_path, lease.rootfs_storage.?);
    defer allocator.free(index_bytes);
    var parsed = try disk_index.parseDiskIndex(allocator, index_bytes, try spore.diskIndexDescriptorForStorage(lease.rootfs_storage.?));
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.chunks.len);
    const object_digest = parsed.value.chunks[0].digest;
    const gc_result = try system.gc(allocator, io, .{ .cache_root = cache_root, .runtime_root = runtime_root, .dry_run = false });
    defer system.deinitRootfsGcResult(allocator, gc_result);
    const prune_result = try system.prune(allocator, io, .{
        .cache_root = cache_root,
        .runtime_root = runtime_root,
        .dry_run = false,
        .include_rootfs_chunks = true,
        .max_bytes = 0,
        .rootfs_only = true,
    }, std.Io.Clock.real.now(io).nanoseconds);
    defer system.deinitRootfsPruneResult(allocator, prune_result);
    const object_path = try rootfs_cas.manifestObjectPath(allocator, cache_root, object_digest);
    defer allocator.free(object_path);
    const bytes = try rootfs_cas.readVerifiedChunkPath(allocator, object_path, object_digest, 512);
    defer allocator.free(bytes);
    var expected_bytes: [512]u8 = undefined;
    @memset(&expected_bytes, expected_seed);
    try std.testing.expectEqualSlices(u8, &expected_bytes, bytes);
}

fn leaseFor(cache_root: []const u8, storage: spore.RootfsStorage) runtime_disk_lease.Lease {
    return .{
        .store = .rootfs_cache,
        .root = cache_root,
        .baseline_kind = .disk_index,
        .baseline_identity = storage.index_digest,
        .rootfs_storage = storage,
    };
}

fn spawnCrashChild(allocator: std.mem.Allocator, io: std.Io, mode: []const u8, root_path: []const u8, expected_exit: u8) !void {
    const executable = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(executable);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(mode_env, mode);
    try env.put(root_env, root_path);
    var child = try std.process.spawn(io, .{ .argv = &.{executable}, .environ_map = &env });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| try std.testing.expectEqual(expected_exit, code),
        else => return error.TestUnexpectedResult,
    }
}

fn getenv(comptime name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}
