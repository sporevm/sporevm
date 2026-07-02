//! Runtime rootfs and writable disk planner shared by run and resume paths.

const std = @import("std");

const block_source = @import("block_source.zig");
const Context = @import("context.zig").Context;
const cow_disk = @import("cow_disk.zig");
const disk_layer = @import("disk_layer.zig");
const fd_util = @import("fd.zig");
const local_paths = @import("local_paths.zig");
const rootfs_cache = @import("rootfs_cache.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const spore = @import("spore.zig");
const virtio_blk = @import("virtio/blk.zig");

const Io = std.Io;
const rootfs_trace_env = "SPOREVM_ROOTFS_TRACE";

pub const Options = struct {
    rootfs_path: ?[]const u8 = null,
    rootfs: ?spore.Rootfs = null,
    disk: ?spore.Disk = null,
    spore_dir: ?[]const u8 = null,
};

pub const RuntimeDisk = struct {
    allocator: ?std.mem.Allocator = null,
    trace_path: ?[:0]const u8 = null,
    rootfs_fd: ?std.c.fd_t = null,
    cas_rootfs: ?*rootfs_cas.CasBlockSource = null,
    overlay: ?disk_layer.TempOverlay = null,
    cow: ?cow_disk.CowDisk = null,
    layered_cow: ?disk_layer.LayeredCowDisk = null,
    base_disk: ?spore.Disk = null,

    pub fn backend(self: *RuntimeDisk) ?virtio_blk.Backend {
        if (self.layered_cow) |*disk| return .{ .layered_cow = disk };
        if (self.cow) |*disk| return .{ .cow = disk };
        if (self.rootfs_fd) |fd| return .{ .file = fd };
        return null;
    }

    pub fn snapshot(self: *RuntimeDisk) ?disk_layer.SnapshotState {
        const base = self.base_disk orelse return null;
        if (self.layered_cow) |*disk| return .{ .base = base, .active = .{ .layered_cow = disk } };
        if (self.cow) |*disk| return .{ .base = base, .active = .{ .cow = disk } };
        return null;
    }

    pub fn deinit(self: *RuntimeDisk) void {
        if (self.layered_cow) |*disk| disk.deinit();
        if (self.cow) |*disk| disk.deinit();
        if (self.overlay) |*overlay| overlay.deinit();
        if (self.rootfs_fd) |fd| _ = std.c.close(fd);
        if (self.cas_rootfs) |source| {
            source.deinit();
            if (self.allocator) |alloc| alloc.destroy(source);
        }
        if (self.trace_path) |path| {
            if (self.allocator) |alloc| alloc.free(path);
        }
        self.* = .{};
    }

    fn baseSource(self: *RuntimeDisk, size: u64) !block_source.BlockSource {
        if (self.cas_rootfs) |source| return .{ .cas = source };
        const fd = self.rootfs_fd orelse return error.BadManifest;
        return block_source.FileBlockSource.initWithTrace(fd, size, self.trace_path).source();
    }
};

pub fn open(context: Context, allocator: std.mem.Allocator, options: Options) !RuntimeDisk {
    var runtime = RuntimeDisk{ .allocator = allocator };
    errdefer runtime.deinit();
    runtime.trace_path = try rootfsTracePath(context, allocator);

    if (options.rootfs) |rootfs| {
        if (rootfs.storage != null) {
            // Prefer the flat digest-addressed ext4 artifact when the local
            // cache has it: it serves guest reads with plain preads instead
            // of per-chunk object opens, which dominates resume-to-first-
            // command time. The chunked CAS source remains the fallback for
            // spores whose flat artifact was never materialized locally,
            // such as chunk-only pulls.
            if (try openCachedFlatRootfs(context, allocator, rootfs, runtime.trace_path)) |fd| {
                runtime.rootfs_fd = fd;
                std.log.debug("runtime disk rootfs base: flat artifact {s}", .{rootfs.artifact.digest});
            } else {
                runtime.cas_rootfs = try openManifestCasRootfs(context, allocator, rootfs, runtime.trace_path);
                std.log.debug("runtime disk rootfs base: cas chunks {s}", .{rootfs.artifact.digest});
            }
        } else {
            runtime.rootfs_fd = try openTrustedRootfs(context, allocator, rootfs, runtime.trace_path);
        }
    } else {
        runtime.rootfs_fd = try openRootfsDisk(allocator, options.rootfs_path);
    }

    if (runtime.rootfs_fd == null and runtime.cas_rootfs == null) return runtime;

    if (options.disk) |disk| {
        const rootfs = options.rootfs orelse return error.BadManifest;
        const spore_dir = options.spore_dir orelse return error.BadManifest;
        if (disk.size != spore.effectiveRootfsLogicalSize(rootfs) or
            !std.mem.eql(u8, disk.base, spore.effectiveRootfsBaseIdentity(rootfs))) return error.BadManifest;
        const base_source = try runtime.baseSource(disk.size);
        runtime.overlay = try disk_layer.createTempOverlay(allocator);
        if (disk.layers.len == 0) {
            runtime.cow = try cow_disk.CowDisk.init(allocator, base_source, runtime.overlay.?.fd, disk.size, disk_layer.default_cluster_size);
            runtime.base_disk = disk;
        } else {
            const layers = try disk_layer.loadLayerChain(allocator, spore_dir, disk);
            errdefer disk_layer.freeLayerChain(allocator, layers);
            runtime.layered_cow = try disk_layer.LayeredCowDisk.init(allocator, spore_dir, base_source, runtime.overlay.?.fd, disk, layers);
            runtime.base_disk = disk;
        }
        return runtime;
    }

    if (options.rootfs) |rootfs| {
        runtime.overlay = try disk_layer.createTempOverlay(allocator);
        const base = disk_layer.diskFromRootfs(rootfs);
        const base_source = try runtime.baseSource(base.size);
        runtime.cow = try cow_disk.CowDisk.init(allocator, base_source, runtime.overlay.?.fd, base.size, disk_layer.default_cluster_size);
        runtime.base_disk = base;
        return runtime;
    }

    return runtime;
}

fn openRootfsDisk(allocator: std.mem.Allocator, rootfs_path: ?[]const u8) !?std.c.fd_t {
    const path = rootfs_path orelse return null;
    const pathz = try allocator.dupeZ(u8, path);
    defer allocator.free(pathz);
    const fd = std.c.open(pathz, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return error.RootFSOpenFailed;
    return fd;
}

fn openTrustedRootfs(context: Context, allocator: std.mem.Allocator, rootfs: spore.Rootfs, trace_path: ?[:0]const u8) !std.c.fd_t {
    const cache_root = try rootfsCacheRootPath(context, allocator);
    defer allocator.free(cache_root);
    const start_ms = monotonicMs();
    const fd = try rootfs_cache.openTrustedFromCache(context.io, allocator, cache_root, rootfs);
    if (trace_path) |path| {
        appendRootfsTrace(allocator, path, rootfs, monotonicMs() -| start_ms) catch {};
    }
    return fd;
}

/// Best-effort open of the flat digest-addressed artifact for a chunked
/// rootfs. Returns null when the artifact is not usable so callers can fall
/// back to the fully verified CAS chunk source instead of failing the run.
fn openCachedFlatRootfs(context: Context, allocator: std.mem.Allocator, rootfs: spore.Rootfs, trace_path: ?[:0]const u8) !?std.c.fd_t {
    return openTrustedRootfs(context, allocator, rootfs, trace_path) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

fn openManifestCasRootfs(
    context: Context,
    allocator: std.mem.Allocator,
    rootfs: spore.Rootfs,
    trace_path: ?[:0]const u8,
) !*rootfs_cas.CasBlockSource {
    const cache_root = try rootfsCacheRootPath(context, allocator);
    defer allocator.free(cache_root);
    const source = try allocator.create(rootfs_cas.CasBlockSource);
    errdefer allocator.destroy(source);
    source.* = try rootfs_cas.CasBlockSource.openManifest(allocator, cache_root, rootfs, trace_path);
    return source;
}

fn rootfsCacheRootPath(context: Context, allocator: std.mem.Allocator) ![]const u8 {
    return local_paths.rootfsCacheRootPath(allocator, context.environ_map) catch |err| switch (err) {
        error.MissingHome => return error.MissingHome,
        else => |e| return e,
    };
}

fn rootfsTracePath(context: Context, allocator: std.mem.Allocator) !?[:0]const u8 {
    const path = context.environ_map.get(rootfs_trace_env) orelse return null;
    if (path.len == 0) return null;
    return try allocator.dupeZ(u8, path);
}

fn appendRootfsTrace(
    allocator: std.mem.Allocator,
    path: [:0]const u8,
    rootfs: spore.Rootfs,
    elapsed_ms: u64,
) !void {
    const line = try std.fmt.allocPrint(
        allocator,
        "{{\"event\":\"rootfs_open\",\"digest\":\"{s}\",\"size\":{d},\"elapsed_ms\":{d}}}\n",
        .{ rootfs.artifact.digest, rootfs.artifact.size, elapsed_ms },
    );
    defer allocator.free(line);
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c_uint, 0o644));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    fd_util.writeAllBestEffort(fd, line);
}

fn monotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

test "runtime disk owns trace path without a rootfs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-runtime-disk-no-rootfs-trace";
    const trace_path = tmp ++ "/rootfs-trace.jsonl";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const absolute_trace_path = try std.fs.path.resolve(arena, &.{trace_path});
    try env.put(rootfs_trace_env, absolute_trace_path);

    const context = Context{ .io = io, .environ_map = &env };
    var runtime = try open(context, allocator, .{});
    defer runtime.deinit();
    try std.testing.expect(runtime.backend() == null);
}

test "runtime disk rejects corrupt rootfs before constructing file block source" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-runtime-disk-corrupt-rootfs";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });

    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const digest_path = try rootfs_cache.digestPath(arena, cache_root, artifact.digest);
    try Io.Dir.cwd().deleteFile(io, digest_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = digest_path, .data = "tampered" });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const absolute_cache_root = try std.fs.path.resolve(arena, &.{cache_root});
    try env.put(local_paths.rootfs_cache_env, absolute_cache_root);
    const trace_path = tmp ++ "/rootfs-trace.jsonl";
    const absolute_trace_path = try std.fs.path.resolve(arena, &.{trace_path});
    try env.put(rootfs_trace_env, absolute_trace_path);

    const context = Context{ .io = io, .environ_map = &env };

    const rootfs = spore.Rootfs{ .device = .{ .mmio_slot = 1 }, .artifact = artifact };
    try std.testing.expectError(error.RootFSDigestMismatch, open(context, arena, .{
        .rootfs = rootfs,
    }));
}

test "runtime disk prefers flat cached artifact over rootfs cas chunks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-runtime-disk-flat-over-cas";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    const rootfs_bytes = ("abcd" ** 1024) ++ ("efgh" ** 1024);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = rootfs_bytes });

    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const preload_result = try rootfs_cas.preload(io, arena, cache_root, artifact.digest, 4096);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const absolute_cache_root = try std.fs.path.resolve(arena, &.{cache_root});
    try env.put(local_paths.rootfs_cache_env, absolute_cache_root);
    const trace_path = tmp ++ "/rootfs-trace.jsonl";
    const absolute_trace_path = try std.fs.path.resolve(arena, &.{trace_path});
    try env.put(rootfs_trace_env, absolute_trace_path);

    const context = Context{ .io = io, .environ_map = &env };

    const rootfs = spore.Rootfs{
        .device = .{ .mmio_slot = 1 },
        .artifact = artifact,
        .storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload_result),
    };
    var runtime = try open(context, allocator, .{
        .rootfs = rootfs,
    });
    defer runtime.deinit();

    try std.testing.expect(runtime.rootfs_fd != null);
    try std.testing.expect(runtime.cas_rootfs == null);
    try std.testing.expect(runtime.cow != null);
    var readback: [4]u8 = undefined;
    try runtime.cow.?.readAt(&readback, 0);
    try std.testing.expectEqualStrings("abcd", &readback);
    try runtime.cow.?.readAt(&readback, rootfs_bytes.len - 4);
    try std.testing.expectEqualStrings("efgh", &readback);
    const trace_bytes = try Io.Dir.cwd().readFileAlloc(io, trace_path, arena, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, trace_bytes, "\"event\":\"rootfs_open\"") != null);
}

test "runtime disk falls back to rootfs cas chunks when flat artifact is missing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-runtime-disk-cas-fallback-missing";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    const rootfs_bytes = ("abcd" ** 1024) ++ ("efgh" ** 1024);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = rootfs_bytes });

    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const preload_result = try rootfs_cas.preload(io, arena, cache_root, artifact.digest, 4096);
    const digest_path = try rootfs_cache.digestPath(arena, cache_root, artifact.digest);
    try Io.Dir.cwd().deleteFile(io, digest_path);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const absolute_cache_root = try std.fs.path.resolve(arena, &.{cache_root});
    try env.put(local_paths.rootfs_cache_env, absolute_cache_root);

    const context = Context{ .io = io, .environ_map = &env };

    const rootfs = spore.Rootfs{
        .device = .{ .mmio_slot = 1 },
        .artifact = artifact,
        .storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload_result),
    };
    var runtime = try open(context, allocator, .{
        .rootfs = rootfs,
    });
    defer runtime.deinit();

    try std.testing.expect(runtime.rootfs_fd == null);
    try std.testing.expect(runtime.cas_rootfs != null);
    try std.testing.expect(runtime.cow != null);
    var readback: [4]u8 = undefined;
    try runtime.cow.?.readAt(&readback, 0);
    try std.testing.expectEqualStrings("abcd", &readback);
    try std.testing.expectEqual(@as(u64, 1), runtime.cas_rootfs.?.stats.cache_misses);
    try runtime.cow.?.readAt(&readback, 0);
    try std.testing.expectEqual(@as(u64, 1), runtime.cas_rootfs.?.stats.cache_hits);
}

test "runtime disk falls back to rootfs cas chunks when flat artifact size mismatches" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-runtime-disk-cas-fallback-size";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    const rootfs_bytes = ("abcd" ** 1024) ++ ("efgh" ** 1024);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = rootfs_bytes });

    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const preload_result = try rootfs_cas.preload(io, arena, cache_root, artifact.digest, 4096);
    const digest_path = try rootfs_cache.digestPath(arena, cache_root, artifact.digest);
    try Io.Dir.cwd().deleteFile(io, digest_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = digest_path, .data = "truncated" });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const absolute_cache_root = try std.fs.path.resolve(arena, &.{cache_root});
    try env.put(local_paths.rootfs_cache_env, absolute_cache_root);

    const context = Context{ .io = io, .environ_map = &env };

    const rootfs = spore.Rootfs{
        .device = .{ .mmio_slot = 1 },
        .artifact = artifact,
        .storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload_result),
    };
    var runtime = try open(context, allocator, .{
        .rootfs = rootfs,
    });
    defer runtime.deinit();

    try std.testing.expect(runtime.rootfs_fd == null);
    try std.testing.expect(runtime.cas_rootfs != null);
    try std.testing.expect(runtime.cow != null);
    var readback: [4]u8 = undefined;
    try runtime.cow.?.readAt(&readback, 0);
    try std.testing.expectEqualStrings("abcd", &readback);
}

test "runtime disk manifest rootfs cas fails closed without index" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-runtime-disk-manifest-rootfs-cas-missing";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });

    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const preload_result = try rootfs_cas.preload(io, arena, cache_root, artifact.digest, 4096);
    const index_path = try rootfs_cas.manifestIndexPath(arena, cache_root, preload_result.index_digest);
    try Io.Dir.cwd().deleteFile(io, index_path);
    // Remove the flat artifact too: with it present, a missing chunk index is
    // survivable because the flat artifact is preferred as the base source.
    const digest_path = try rootfs_cache.digestPath(arena, cache_root, artifact.digest);
    try Io.Dir.cwd().deleteFile(io, digest_path);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const absolute_cache_root = try std.fs.path.resolve(arena, &.{cache_root});
    try env.put(local_paths.rootfs_cache_env, absolute_cache_root);

    const context = Context{ .io = io, .environ_map = &env };

    const rootfs = spore.Rootfs{
        .device = .{ .mmio_slot = 1 },
        .artifact = artifact,
        .storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload_result),
    };
    try std.testing.expectError(error.MissingChunk, open(context, allocator, .{
        .rootfs = rootfs,
    }));
}
