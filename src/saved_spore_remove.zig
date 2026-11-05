//! Checked deletion of saved spore directories.
//!
//! Removal deletes only the directory. A machine-local pin is released by
//! `spore cache gc`: once the save is gone its cache-side ownership anchor has
//! one link, so GC reclaims the pin and any storage no other root references.

const std = @import("std");
const builtin = @import("builtin");

const chunk_sealer = @import("chunk_sealer.zig");
const Context = @import("context.zig").Context;
const local_paths = @import("local_paths.zig");
const manifest_test_support = @import("manifest_test_support.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const rootfs_mod = @import("rootfs.zig");
const resource = @import("resource.zig");
const runtime_disk_lease = @import("runtime_disk_lease.zig");
const saved_spore_pin = @import("saved_spore_pin.zig");
const spore = @import("spore.zig");
const system = @import("system.zig");

const Io = std.Io;

pub const Result = struct {
    schema: []const u8 = "spore.saved.remove.result.v2",
    schema_version: u32 = 2,
    resource_type: resource.Type = .checkpoint,
    action: []const u8 = "removed_spore",
    spore_dir: []const u8,
};

pub fn deinit(allocator: std.mem.Allocator, result: Result) void {
    allocator.free(result.spore_dir);
}

pub fn remove(context: Context, allocator: std.mem.Allocator, raw_dir: []const u8) !Result {
    const dir = try resolveExistingSporeDir(allocator, context.io, raw_dir);
    errdefer allocator.free(dir);
    try requireManifest(context.io, allocator, dir);
    const runtime_root = try local_paths.runtimeRootPath(allocator, context.environ_map);
    defer allocator.free(runtime_root);
    // Restores publish saved-spore leases under this lock, so holding it
    // through deletion keeps a lazy disk reader from adopting the directory.
    var lease_lock = try runtime_disk_lease.lockRegistry(context.io, allocator, runtime_root);
    defer lease_lock.deinit();
    if (try runtime_disk_lease.savedSporeActiveLocked(context.io, allocator, runtime_root, dir, &lease_lock))
        return error.SavedSporeInUse;
    try Io.Dir.cwd().deleteTree(context.io, dir);
    try chunk_sealer.fsyncDirPath(allocator, std.fs.path.dirname(dir) orelse ".");
    return .{ .spore_dir = dir };
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

fn requireManifest(io: Io, allocator: std.mem.Allocator, dir: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, "manifest.json" });
    defer allocator.free(path);
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| return switch (err) {
        error.FileNotFound => error.InvalidSporeDir,
        else => err,
    };
    if (stat.kind != .file) return error.BadManifest;
    // Other tools also write `manifest.json`, so only a spore manifest proves
    // the directory is a save. Parsing never reads the save's storage, so a
    // save with corrupt objects stays removable.
    if (spore.loadManifestPath(allocator, path)) |parsed| {
        parsed.deinit();
    } else |err| switch (err) {
        error.FormatTooOld => {},
        else => |e| return e,
    }
}

const TestHost = struct {
    arena: std.mem.Allocator,
    io: Io,
    root: []const u8,
    cache_root: []const u8,
    runtime_root: []const u8,
    env: std.process.Environ.Map,

    fn init(arena: std.mem.Allocator, io: Io, root: []const u8) !TestHost {
        var host = TestHost{
            .arena = arena,
            .io = io,
            .root = root,
            .cache_root = try std.fs.path.join(arena, &.{ root, "cache" }),
            .runtime_root = try std.fs.path.join(arena, &.{ root, "runtime" }),
            .env = std.process.Environ.Map.init(arena),
        };
        try host.env.put(local_paths.rootfs_cache_env, host.cache_root);
        try host.env.put(local_paths.runtime_dir_env, host.runtime_root);
        return host;
    }

    fn path(self: *TestHost, name: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena, &.{ self.root, name });
    }

    fn context(self: *TestHost) Context {
        return .{ .io = self.io, .environ_map = &self.env };
    }

    fn rm(self: *TestHost, dir: []const u8) !void {
        deinit(std.testing.allocator, try remove(self.context(), std.testing.allocator, dir));
    }

    /// Saves a machine-local spore whose disk storage lives only in the cache.
    fn savePinned(self: *TestHost, dir: []const u8, seed: u8) !manifest_test_support.DiskFixture {
        const fixture = try manifest_test_support.diskFixture(self.arena, self.io, self.cache_root, dir, seed, false);
        var lock = try rootfs_mod.lockRootfsCacheExclusive(self.io, self.arena, self.cache_root);
        defer lock.deinit();
        const registry = try saved_spore_pin.LockedRegistry.init(self.arena, self.cache_root, &lock);
        try saved_spore_pin.publishManifest(self.io, self.arena, registry, dir, fixture.disk, fixture.manifest);
        return fixture;
    }

    fn gc(self: *TestHost) !void {
        const result = try system.gc(std.testing.allocator, self.io, .{ .cache_root = self.cache_root, .runtime_root = self.runtime_root, .dry_run = false });
        system.deinitRootfsGcResult(std.testing.allocator, result);
    }

    fn storageKept(self: *TestHost, fixture: manifest_test_support.DiskFixture) !bool {
        const index = try exists(self.io, try rootfs_cas.manifestIndexPath(self.arena, self.cache_root, fixture.storage.index_digest));
        const object = try exists(self.io, try rootfs_cas.manifestObjectPath(self.arena, self.cache_root, fixture.object_digest));
        try std.testing.expectEqual(index, object);
        return index;
    }

    fn restorable(self: *TestHost, dir: []const u8, fixture: manifest_test_support.DiskFixture) !bool {
        var lock = try rootfs_mod.lockRootfsCacheExclusive(self.io, self.arena, self.cache_root);
        defer lock.deinit();
        const registry = try saved_spore_pin.LockedRegistry.init(self.arena, self.cache_root, &lock);
        var record = saved_spore_pin.loadForSporeLocked(self.io, self.arena, registry, dir, fixture.disk) catch |err| switch (err) {
            error.SavedSporeOwnershipConflict => return false,
            else => |e| return e,
        };
        record.deinit();
        return true;
    }

    /// Mirrors `cp -r` (`.copy`) and `cp -al` (`.hard_link`) of a flat save.
    fn copySave(self: *TestHost, source: []const u8, destination: []const u8, mode: enum { copy, hard_link }) !void {
        try Io.Dir.cwd().createDirPath(self.io, destination);
        var dir = try Io.Dir.cwd().openDir(self.io, source, .{ .iterate = true });
        defer dir.close(self.io);
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) return error.TestUnexpectedResult;
            const from = try std.fs.path.join(self.arena, &.{ source, entry.name });
            const to = try std.fs.path.join(self.arena, &.{ destination, entry.name });
            switch (mode) {
                .copy => try Io.Dir.copyFileAbsolute(from, to, self.io, .{}),
                .hard_link => try Io.Dir.cwd().hardLink(from, Io.Dir.cwd(), to, self.io, .{}),
            }
        }
    }
};

fn exists(io: Io, path: []const u8) !bool {
    _ = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

test "saved-spore removal deletes spore checkpoints without reading their storage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var host = try TestHost.init(arena_state.allocator(), io, try tmp.dir.realPathFileAlloc(io, ".", arena_state.allocator()));

    const diskless = try host.path("diskless.spore");
    try Io.Dir.cwd().createDirPath(io, diskless);
    try spore.saveManifest(host.arena, diskless, manifest_test_support.manifest(.{}));
    const removed = try remove(host.context(), std.testing.allocator, diskless);
    defer deinit(std.testing.allocator, removed);
    try std.testing.expectEqualStrings(diskless, removed.spore_dir);
    try std.testing.expect(!try exists(io, diskless));
    try std.testing.expectError(error.FileNotFound, host.rm(diskless));

    // Saves from older releases no longer load but are still spores.
    const legacy = try host.path("legacy.spore");
    try Io.Dir.cwd().createDirPath(io, legacy);
    var legacy_manifest = manifest_test_support.manifest(.{});
    legacy_manifest.version = spore.format_version - 1;
    const legacy_json = try std.json.Stringify.valueAlloc(host.arena, legacy_manifest, .{});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(host.arena, &.{ legacy, "manifest.json" }), .data = legacy_json });
    try host.rm(legacy);
    try std.testing.expect(!try exists(io, legacy));

    // Saves with corrupt storage are exactly the ones users most need to
    // delete, so removal never reads the CAS.
    const corrupt = try host.path("corrupt.spore");
    const fixture = try manifest_test_support.diskFixture(host.arena, io, host.cache_root, corrupt, 0x41, true);
    try spore.saveManifest(host.arena, corrupt, fixture.manifest);
    try Io.Dir.cwd().deleteFile(io, try rootfs_cas.manifestObjectPath(host.arena, corrupt, fixture.object_digest));
    try host.rm(corrupt);
    try std.testing.expect(!try exists(io, corrupt));
    try std.testing.expect(try host.storageKept(fixture));
}

test "saved-spore removal refuses directories that are not spores and live saved-spore leases" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var host = try TestHost.init(arena_state.allocator(), io, try tmp.dir.realPathFileAlloc(io, ".", arena_state.allocator()));

    const plain = try host.path("plain");
    try Io.Dir.cwd().createDirPath(io, plain);
    try std.testing.expectError(error.InvalidSporeDir, host.rm(plain));
    // Browser extensions, PWAs, and many other projects have a manifest.json.
    const extension = try host.path("extension");
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(host.arena, &.{ extension, ".git" }));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(host.arena, &.{ extension, "manifest.json" }), .data = "{\"manifest_version\":3,\"name\":\"ext\"}" });
    try std.testing.expectError(error.BadManifest, host.rm(extension));
    // A save whose manifest no longer parses is indistinguishable from any
    // other directory; users delete it with `rm -rf` and let GC reclaim it.
    const damaged = try host.path("damaged.spore");
    try Io.Dir.cwd().createDirPath(io, damaged);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(host.arena, &.{ damaged, "manifest.json" }), .data = "{" });
    try std.testing.expectError(error.BadManifest, host.rm(damaged));
    const linked_manifest = try host.path("linked-manifest.spore");
    try Io.Dir.cwd().createDirPath(io, linked_manifest);
    try Io.Dir.cwd().symLink(io, try host.path("elsewhere.json"), try std.fs.path.join(host.arena, &.{ linked_manifest, "manifest.json" }), .{});
    try std.testing.expectError(error.BadManifest, host.rm(linked_manifest));
    const portable = try host.path("portable.spore");
    const fixture = try manifest_test_support.diskFixture(host.arena, io, host.cache_root, portable, 0x43, true);
    try spore.saveManifest(host.arena, portable, fixture.manifest);
    const linked_dir = try host.path("linked.spore");
    try Io.Dir.cwd().symLink(io, portable, linked_dir, .{});
    try std.testing.expectError(error.InvalidSporeDir, host.rm(linked_dir));
    for ([_][]const u8{ plain, extension, damaged, linked_manifest }) |dir| try std.testing.expect(try exists(io, dir));
    try std.testing.expect(try exists(io, try std.fs.path.join(host.arena, &.{ extension, ".git" })));

    var active = try runtime_disk_lease.acquireActive(io, std.testing.allocator, host.runtime_root, try runtime_disk_lease.fromSavedDisk(portable, fixture.disk));
    try std.testing.expectError(error.SavedSporeInUse, host.rm(portable));
    try std.testing.expect(try exists(io, portable));
    active.deinit();
    try host.rm(portable);
    try std.testing.expect(!try exists(io, portable));
}

test "cache gc releases storage only after every saved spore referencing it is gone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var host = try TestHost.init(arena_state.allocator(), io, try tmp.dir.realPathFileAlloc(io, ".", arena_state.allocator()));

    const spore_rm = try host.path("spore-rm.spore");
    const rm_rf = try host.path("rm-rf.spore");
    const moved_from = try host.path("moved-from.spore");
    const moved_to = try host.path("moved-to.spore");
    const copied_from = try host.path("copied-from.spore");
    const copied_to = try host.path("copied-to.spore");
    const linked_from = try host.path("linked-from.spore");
    const linked_to = try host.path("linked-to.spore");
    const removed_storage = try host.savePinned(spore_rm, 0x51);
    const rm_rf_storage = try host.savePinned(rm_rf, 0x52);
    const moved_storage = try host.savePinned(moved_from, 0x53);
    const copied_storage = try host.savePinned(copied_from, 0x54);
    const linked_storage = try host.savePinned(linked_from, 0x55);

    try host.rm(spore_rm);
    try Io.Dir.cwd().deleteTree(io, rm_rf);
    try Io.Dir.renameAbsolute(moved_from, moved_to, io);
    try host.copySave(copied_from, copied_to, .copy);
    try host.copySave(linked_from, linked_to, .hard_link);
    try host.gc();
    try std.testing.expect(!try host.storageKept(removed_storage));
    try std.testing.expect(!try host.storageKept(rm_rf_storage));
    try std.testing.expect(try host.storageKept(moved_storage));
    try std.testing.expect(try host.restorable(moved_to, moved_storage));
    try std.testing.expect(try host.storageKept(copied_storage));
    try std.testing.expect(try host.restorable(copied_from, copied_storage));
    try std.testing.expect(!try host.restorable(copied_to, copied_storage));
    // Duplicate hard links make both copies ambiguous, but never collectable.
    try std.testing.expect(try host.storageKept(linked_storage));
    try std.testing.expect(!try host.restorable(linked_from, linked_storage));

    try host.rm(linked_from);
    try host.gc();
    try std.testing.expect(try host.storageKept(linked_storage));
    try std.testing.expect(try host.restorable(linked_to, linked_storage));

    // A plain copy never owned the pin, so it does not keep storage alive once
    // the original is removed.
    try host.rm(copied_from);
    try host.rm(moved_to);
    try Io.Dir.cwd().deleteTree(io, linked_to);
    try host.gc();
    try std.testing.expect(!try host.storageKept(copied_storage));
    try std.testing.expect(!try host.storageKept(moved_storage));
    try std.testing.expect(!try host.storageKept(linked_storage));
    const pins = try saved_spore_pin.list(io, std.testing.allocator, host.cache_root);
    defer saved_spore_pin.deinitListings(std.testing.allocator, pins);
    try std.testing.expectEqual(@as(usize, 0), pins.len);
}

test "cache gc keeps a removed save's storage while a restore lease is live" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var host = try TestHost.init(arena_state.allocator(), io, try tmp.dir.realPathFileAlloc(io, ".", arena_state.allocator()));

    const saved = try host.path("restored.spore");
    const fixture = try host.savePinned(saved, 0x61);
    var active = try runtime_disk_lease.acquireActive(io, std.testing.allocator, host.runtime_root, .{
        .store = .rootfs_cache,
        .root = host.cache_root,
        .baseline_kind = .disk_index,
        .baseline_identity = fixture.disk.base,
        .rootfs_storage = fixture.storage,
    });
    try host.rm(saved);
    try host.gc();
    try std.testing.expect(try host.storageKept(fixture));
    active.deinit();
    try host.gc();
    try std.testing.expect(!try host.storageKept(fixture));
}
