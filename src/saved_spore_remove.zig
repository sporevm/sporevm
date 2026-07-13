//! Durable removal for machine-local saved spores.

const std = @import("std");
const builtin = @import("builtin");

const chunk_sealer = @import("chunk_sealer.zig");
const Context = @import("context.zig").Context;
const gicv3 = @import("gicv3.zig");
const local_paths = @import("local_paths.zig");
const manifest_test_support = @import("manifest_test_support.zig");
const rootfs_mod = @import("rootfs.zig");
const saved_spore_pin = @import("saved_spore_pin.zig");
const spore = @import("spore.zig");
const topology = @import("topology.zig");

const Io = std.Io;

pub const Result = struct {
    action: []const u8 = "removed_spore",
    spore_dir: []const u8,
    /// Empty when the removed spore had no writable disk and therefore no pin.
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
        try rejectDisklessPinReference(context.io, allocator, dir);
        const id = try allocator.alloc(u8, 0);
        errdefer allocator.free(id);
        try deleteAndSyncParent(context.io, allocator, dir);
        return .{ .spore_dir = dir, .pin_id = id };
    }

    const cache_root = try local_paths.rootfsCacheRootPath(allocator, context.environ_map);
    defer allocator.free(cache_root);
    var lock = try rootfs_mod.lockRootfsCacheExclusive(context.io, allocator, cache_root);
    defer lock.deinit();
    const registry = try saved_spore_pin.LockedRegistry.init(allocator, cache_root, &lock);
    var pin = try saved_spore_pin.loadForSporeLocked(context.io, allocator, registry, dir, disk.?);
    defer pin.deinit();
    const id = try allocator.dupe(u8, pin.value.id);
    errdefer allocator.free(id);
    try deleteAndSyncParent(context.io, allocator, dir);
    try saved_spore_pin.remove(context.io, allocator, registry, id);
    return .{ .spore_dir = dir, .pin_id = id, .pin_removed = true };
}

fn resolveExistingSporeDir(allocator: std.mem.Allocator, io: Io, raw: []const u8) ![]const u8 {
    const path = try std.fs.path.resolve(allocator, &.{raw});
    errdefer allocator.free(path);
    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .directory) return error.InvalidSporeDir;
    return path;
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
        .mpidr = topology.mpidrForIndex(index),
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
    second_record.deinit();

    testing.fault = .none;
    const removed = try remove(.{ .io = io, .environ_map = &env }, allocator, before_delete);
    defer deinit(allocator, removed);
    try std.testing.expect(removed.pin_removed);
    try std.testing.expectEqualStrings(first_id, removed.pin_id);
    try std.testing.expectError(error.FileNotFound, saved_spore_pin.loadRecord(io, allocator, cache_root, first_id));
}
