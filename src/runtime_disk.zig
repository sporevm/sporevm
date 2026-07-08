//! Runtime rootfs and writable disk planner shared by run and resume paths.

const std = @import("std");

const block_source = @import("block_source.zig");
const chunk = @import("chunk.zig");
const chunk_mapped_disk = @import("chunk_mapped_disk.zig");
const Context = @import("context.zig").Context;
const disk_index = @import("disk_index.zig");
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
    /// Owned trace fd, opened once from SPOREVM_ROOTFS_TRACE (O_APPEND) so
    /// per-read trace events do not pay an open/close each.
    trace_fd: ?std.c.fd_t = null,
    rootfs_fd: ?std.c.fd_t = null,
    overlay: ?disk_layer.TempOverlay = null,
    chunk_mapped: ?chunk_mapped_disk.ChunkMappedDisk = null,
    base_disk: ?spore.Disk = null,

    pub fn backend(self: *RuntimeDisk) ?virtio_blk.Backend {
        if (self.chunk_mapped) |*disk| return .{ .chunk_mapped = disk };
        if (self.rootfs_fd) |fd| return .{ .file = fd };
        return null;
    }

    pub fn snapshot(self: *RuntimeDisk) ?disk_layer.SnapshotState {
        const base = self.base_disk orelse return null;
        if (self.chunk_mapped) |*disk| return .{ .base = base, .active = .{ .chunk_mapped = disk } };
        return null;
    }

    pub fn deinit(self: *RuntimeDisk) void {
        if (self.chunk_mapped) |*disk| disk.deinit();
        if (self.overlay) |*overlay| overlay.deinit();
        if (self.rootfs_fd) |fd| _ = std.c.close(fd);
        if (self.trace_fd) |fd| _ = std.c.close(fd);
        self.* = .{};
    }

    fn baseSource(self: *RuntimeDisk, size: u64) !block_source.FileBlockSource {
        const fd = self.rootfs_fd orelse return error.BadManifest;
        return block_source.FileBlockSource.initWithTrace(fd, size, self.trace_fd);
    }
};

pub fn open(context: Context, allocator: std.mem.Allocator, options: Options) !RuntimeDisk {
    var runtime = RuntimeDisk{ .allocator = allocator };
    errdefer runtime.deinit();
    runtime.trace_fd = try openRootfsTraceFd(context, allocator);

    if (options.rootfs) |rootfs| {
        if (rootfs.storage != null) {
            // The flat digest-addressed ext4 artifact is the only runtime
            // base source. When it is not materialized locally (chunk-only
            // pull caches, pruned or corrupt entries), assemble it once from
            // the locally installed verified chunks; missing chunks or an
            // artifact-digest mismatch fail the run closed.
            if (try openCachedFlatRootfs(context, allocator, rootfs, runtime.trace_fd)) |fd| {
                runtime.rootfs_fd = fd;
                std.log.debug("runtime disk rootfs base: flat artifact {s}", .{rootfs.artifact.digest});
            } else {
                const materialize_start = monotonicMs();
                try materializeFlatRootfs(context, allocator, rootfs);
                runtime.rootfs_fd = try openTrustedRootfs(context, allocator, rootfs, runtime.trace_fd);
                std.log.debug("runtime disk rootfs base: assembled flat artifact {s} elapsed_ms={d}", .{ rootfs.artifact.digest, monotonicMs() -| materialize_start });
            }
        } else {
            runtime.rootfs_fd = try openTrustedRootfs(context, allocator, rootfs, runtime.trace_fd);
        }
    } else {
        runtime.rootfs_fd = try openRootfsDisk(allocator, options.rootfs_path);
    }

    if (runtime.rootfs_fd == null) return runtime;

    if (options.disk) |disk| {
        const rootfs = options.rootfs orelse return error.BadManifest;
        const spore_dir = options.spore_dir orelse return error.BadManifest;
        const is_chunk_index = std.mem.eql(u8, disk.kind, spore.disk_kind_chunk_index);
        const is_cow_block = std.mem.eql(u8, disk.kind, spore.disk_kind_cow_block);
        if (!is_chunk_index and !is_cow_block) return error.BadManifest;
        if (!spore.rootfsDeviceEql(disk.device, rootfs.device)) return error.BadManifest;
        if (is_chunk_index and disk.layers.len != 0) return error.BadManifest;
        if (disk.size != spore.effectiveRootfsLogicalSize(rootfs) or
            (is_cow_block and
                !std.mem.eql(u8, disk.base, spore.effectiveRootfsBaseIdentity(rootfs)))) return error.BadManifest;
        if (is_chunk_index) {
            if (runtime.rootfs_fd) |fd| {
                _ = std.c.close(fd);
                runtime.rootfs_fd = null;
            }
            runtime.rootfs_fd = try materializeDiskIndexToTemp(context, allocator, spore_dir, disk);
            runtime.overlay = try disk_layer.createTempOverlay(allocator);
            const base_source = try runtime.baseSource(disk.size);
            runtime.chunk_mapped = try chunk_mapped_disk.ChunkMappedDisk.initWritable(allocator, base_source, runtime.overlay.?.fd, disk.size, disk.chunk_size);
            runtime.base_disk = disk;
            return runtime;
        }
        const base_source = try runtime.baseSource(disk.size);
        runtime.overlay = try disk_layer.createTempOverlay(allocator);
        if (disk.layers.len != 0) return error.BadManifest;
        runtime.chunk_mapped = try chunk_mapped_disk.ChunkMappedDisk.initWritable(allocator, base_source, runtime.overlay.?.fd, disk.size, rootfs_cas.default_chunk_size);
        runtime.base_disk = disk;
        return runtime;
    }

    if (options.rootfs) |rootfs| {
        runtime.overlay = try disk_layer.createTempOverlay(allocator);
        const base = disk_layer.diskFromRootfs(rootfs);
        const base_source = try runtime.baseSource(base.size);
        runtime.chunk_mapped = try chunk_mapped_disk.ChunkMappedDisk.initWritable(allocator, base_source, runtime.overlay.?.fd, base.size, rootfs_cas.default_chunk_size);
        runtime.base_disk = base;
        return runtime;
    }

    if (runtime.rootfs_fd) |fd| {
        const size = try fdSize(fd);
        const base_source = try runtime.baseSource(size);
        runtime.chunk_mapped = try chunk_mapped_disk.ChunkMappedDisk.initReadOnly(allocator, base_source, size, rootfs_cas.default_chunk_size);
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

fn fdSize(fd: std.c.fd_t) !u64 {
    const cur = std.c.lseek(fd, 0, std.c.SEEK.CUR);
    if (cur < 0) return error.BadManifest;
    const end = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (end < 0) return error.BadManifest;
    if (std.c.lseek(fd, cur, std.c.SEEK.SET) < 0) return error.BadManifest;
    if (end == 0) return error.BadManifest;
    return @intCast(end);
}

fn materializeDiskIndexToTemp(context: Context, allocator: std.mem.Allocator, spore_dir: []const u8, disk: spore.Disk) !std.c.fd_t {
    const storage = spore.RootfsStorage{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = disk.device,
        .logical_size = disk.size,
        .chunk_size = disk.chunk_size,
        .hash_algorithm = disk.hash_algorithm,
        .index_digest = disk.base,
        .base_identity = disk.base,
        .object_namespace = disk.object_namespace,
    };
    try spore.validateRootfsStorageDescriptor(storage);

    var temp = try disk_layer.createTempOverlay(allocator);
    errdefer temp.deinit();
    const logical_size = std.math.cast(std.c.off_t, disk.size) orelse return error.BadManifest;
    if (std.c.ftruncate(temp.fd, logical_size) != 0) return error.IoFailed;

    const index_path = try rootfs_cas.manifestIndexPath(allocator, spore_dir, disk.base);
    defer allocator.free(index_path);
    const index_bytes = Io.Dir.cwd().readFileAlloc(context.io, index_path, allocator, .limited(disk_index.max_index_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return error.BadManifest,
        else => |e| return e,
    };
    defer allocator.free(index_bytes);
    const parsed = try disk_index.parseDiskIndex(allocator, index_bytes, storage);
    defer parsed.deinit();

    for (parsed.value.chunks) |entry| {
        const object_path = try rootfs_cas.manifestObjectPath(allocator, spore_dir, entry.digest);
        defer allocator.free(object_path);
        const len = try rootfs_cas.storageChunkLen(storage, entry.logical_chunk);
        const limit = std.math.add(usize, len, 1) catch return error.BadManifest;
        const object = Io.Dir.cwd().readFileAlloc(context.io, object_path, allocator, .limited(limit)) catch |err| switch (err) {
            error.FileNotFound, error.StreamTooLong => return error.BadManifest,
            else => |e| return e,
        };
        defer allocator.free(object);
        if (object.len != len) return error.BadManifest;
        const hex = try spore.diskDigestHex(entry.digest);
        const id = chunk.ChunkId.fromHex(hex) catch return error.BadManifest;
        if (!id.matches(object)) return error.BadManifest;
        const offset = std.math.mul(u64, entry.logical_chunk, storage.chunk_size) catch return error.BadManifest;
        try pwriteAll(temp.fd, object, offset);
    }

    const fd = temp.fd;
    temp.fd = -1;
    return fd;
}

fn pwriteAll(fd: std.c.fd_t, bytes: []const u8, offset: u64) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const absolute = std.math.add(u64, offset, done) catch return error.BadManifest;
        const file_offset = std.math.cast(std.c.off_t, absolute) orelse return error.BadManifest;
        const n = std.c.pwrite(fd, bytes.ptr + done, bytes.len - done, file_offset);
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
}

fn openTrustedRootfs(context: Context, allocator: std.mem.Allocator, rootfs: spore.Rootfs, trace_fd: ?std.c.fd_t) !std.c.fd_t {
    const cache_root = try rootfsCacheRootPath(context, allocator);
    defer allocator.free(cache_root);
    const start_ms = monotonicMs();
    const fd = try rootfs_cache.openTrustedFromCache(context.io, allocator, cache_root, rootfs);
    if (trace_fd) |trace| {
        appendRootfsTrace(allocator, trace, rootfs, monotonicMs() -| start_ms) catch {};
    }
    return fd;
}

/// Best-effort open of the flat digest-addressed artifact for a chunked
/// rootfs. Returns null when the artifact is not usable so callers can fall
/// back to the fully verified CAS chunk source instead of failing the run.
fn openCachedFlatRootfs(context: Context, allocator: std.mem.Allocator, rootfs: spore.Rootfs, trace_fd: ?std.c.fd_t) !?std.c.fd_t {
    return openTrustedRootfs(context, allocator, rootfs, trace_fd) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

fn materializeFlatRootfs(context: Context, allocator: std.mem.Allocator, rootfs: spore.Rootfs) !void {
    const cache_root = try rootfsCacheRootPath(context, allocator);
    defer allocator.free(cache_root);
    try rootfs_cas.materializeFlatFromChunks(context.io, allocator, cache_root, rootfs);
}

fn rootfsCacheRootPath(context: Context, allocator: std.mem.Allocator) ![]const u8 {
    return local_paths.rootfsCacheRootPath(allocator, context.environ_map) catch |err| switch (err) {
        error.MissingHome => return error.MissingHome,
        else => |e| return e,
    };
}

fn openRootfsTraceFd(context: Context, allocator: std.mem.Allocator) !?std.c.fd_t {
    const path = context.environ_map.get(rootfs_trace_env) orelse return null;
    if (path.len == 0) return null;
    const pathz = try allocator.dupeZ(u8, path);
    defer allocator.free(pathz);
    const fd = std.c.open(pathz, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c_uint, 0o644));
    if (fd < 0) return null;
    return fd;
}

fn appendRootfsTrace(
    allocator: std.mem.Allocator,
    fd: std.c.fd_t,
    rootfs: spore.Rootfs,
    elapsed_ms: u64,
) !void {
    const line = try std.fmt.allocPrint(
        allocator,
        "{{\"event\":\"rootfs_open\",\"digest\":\"{s}\",\"size\":{d},\"elapsed_ms\":{d}}}\n",
        .{ rootfs.artifact.digest, rootfs.artifact.size, elapsed_ms },
    );
    defer allocator.free(line);
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
    Io.Dir.cwd().deleteFile(io, digest_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
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
    const storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload_result);
    const rootfs_artifact = spore.RootfsArtifactRef{ .digest = storage.index_digest, .size = artifact.size };
    _ = try rootfs_cache.installTrustedMaterializationByHardlink(io, arena, cache_root, rootfs_path, rootfs_artifact.digest, rootfs_artifact.size);

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
        .artifact = rootfs_artifact,
        .storage = storage,
    };
    var runtime = try open(context, allocator, .{
        .rootfs = rootfs,
    });
    defer runtime.deinit();

    try std.testing.expect(runtime.rootfs_fd != null);
    try std.testing.expect(runtime.chunk_mapped != null);
    var readback: [4]u8 = undefined;
    try runtime.chunk_mapped.?.readAt(&readback, 0);
    try std.testing.expectEqualStrings("abcd", &readback);
    try runtime.chunk_mapped.?.readAt(&readback, rootfs_bytes.len - 4);
    try std.testing.expectEqualStrings("efgh", &readback);
    const trace_bytes = try Io.Dir.cwd().readFileAlloc(io, trace_path, arena, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, trace_bytes, "\"event\":\"rootfs_open\"") != null);
}

test "runtime disk assembles the flat artifact from chunks when it is missing" {
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
    const storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload_result);
    const rootfs_artifact = spore.RootfsArtifactRef{ .digest = storage.index_digest, .size = artifact.size };
    const digest_path = try rootfs_cache.digestPath(arena, cache_root, rootfs_artifact.digest);
    Io.Dir.cwd().deleteFile(io, digest_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const absolute_cache_root = try std.fs.path.resolve(arena, &.{cache_root});
    try env.put(local_paths.rootfs_cache_env, absolute_cache_root);

    const context = Context{ .io = io, .environ_map = &env };

    const rootfs = spore.Rootfs{
        .device = .{ .mmio_slot = 1 },
        .artifact = rootfs_artifact,
        .storage = storage,
    };
    var runtime = try open(context, allocator, .{
        .rootfs = rootfs,
    });
    defer runtime.deinit();

    try std.testing.expect(runtime.rootfs_fd != null);
    try std.testing.expect(runtime.chunk_mapped != null);
    var readback: [4]u8 = undefined;
    try runtime.chunk_mapped.?.readAt(&readback, 0);
    try std.testing.expectEqualStrings("abcd", &readback);
    // The assembled flat artifact is republished into the by-digest cache.
    try std.testing.expect(try rootfs_cache.regularFileNoSymlink(io, digest_path));
}

test "runtime disk reassembles the flat artifact when the cached entry is the wrong size" {
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
    const storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload_result);
    const rootfs_artifact = spore.RootfsArtifactRef{ .digest = storage.index_digest, .size = artifact.size };
    const digest_path = try rootfs_cache.digestPath(arena, cache_root, rootfs_artifact.digest);
    Io.Dir.cwd().deleteFile(io, digest_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = digest_path, .data = "truncated" });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const absolute_cache_root = try std.fs.path.resolve(arena, &.{cache_root});
    try env.put(local_paths.rootfs_cache_env, absolute_cache_root);

    const context = Context{ .io = io, .environ_map = &env };

    const rootfs = spore.Rootfs{
        .device = .{ .mmio_slot = 1 },
        .artifact = rootfs_artifact,
        .storage = storage,
    };
    var runtime = try open(context, allocator, .{
        .rootfs = rootfs,
    });
    defer runtime.deinit();

    try std.testing.expect(runtime.rootfs_fd != null);
    try std.testing.expect(runtime.chunk_mapped != null);
    var readback: [4]u8 = undefined;
    try runtime.chunk_mapped.?.readAt(&readback, 0);
    try std.testing.expectEqualStrings("abcd", &readback);
    // Rename-over publication self-healed the corrupt cache entry.
    const healed = try Io.Dir.cwd().readFileAlloc(io, digest_path, arena, .limited(1 << 20));
    try std.testing.expectEqual(rootfs_bytes.len, healed.len);
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
    const storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload_result);
    const rootfs_artifact = spore.RootfsArtifactRef{ .digest = storage.index_digest, .size = artifact.size };
    const index_path = try rootfs_cas.manifestIndexPath(arena, cache_root, preload_result.index_digest);
    try Io.Dir.cwd().deleteFile(io, index_path);
    // Remove the flat artifact too: with it present, a missing chunk index is
    // survivable because the flat artifact is preferred as the base source.
    const digest_path = try rootfs_cache.digestPath(arena, cache_root, rootfs_artifact.digest);
    Io.Dir.cwd().deleteFile(io, digest_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const absolute_cache_root = try std.fs.path.resolve(arena, &.{cache_root});
    try env.put(local_paths.rootfs_cache_env, absolute_cache_root);

    const context = Context{ .io = io, .environ_map = &env };

    const rootfs = spore.Rootfs{
        .device = .{ .mmio_slot = 1 },
        .artifact = rootfs_artifact,
        .storage = storage,
    };
    try std.testing.expectError(error.MissingChunk, open(context, allocator, .{
        .rootfs = rootfs,
    }));
}

test "runtime disk rejects unknown disk kinds" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-runtime-disk-unknown-kind";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    const spore_dir = tmp ++ "/saved.spore";
    Io.Dir.cwd().deleteTree(io, tmp) catch {};
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, spore_dir);

    const rootfs_bytes = "abcd" ** 1024;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = rootfs_bytes });
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const absolute_cache_root = try std.fs.path.resolve(arena, &.{cache_root});
    try env.put(local_paths.rootfs_cache_env, absolute_cache_root);
    const context = Context{ .io = io, .environ_map = &env };
    const rootfs = spore.Rootfs{ .device = .{ .mmio_slot = 1 }, .artifact = artifact };
    const disk = spore.Disk{
        .kind = "not-a-disk-kind",
        .device = rootfs.device,
        .size = rootfs_bytes.len,
        .base = artifact.digest,
    };

    try std.testing.expectError(error.BadManifest, open(context, allocator, .{
        .rootfs = rootfs,
        .disk = disk,
        .spore_dir = spore_dir,
    }));
}

test "runtime disk restores chunk-index disk manifests" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-runtime-disk-chunk-index-restore";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    const spore_dir = tmp ++ "/saved.spore";
    Io.Dir.cwd().deleteTree(io, tmp) catch {};
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, spore_dir);

    const rootfs_bytes = ("abcd" ** 1024) ++ ("efgh" ** 1024);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = rootfs_bytes });
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);

    const base_fd = std.c.open(try arena.dupeZ(u8, rootfs_path), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (base_fd < 0) return error.IoFailed;
    defer _ = std.c.close(base_fd);
    var overlay = try disk_layer.createTempOverlay(arena);
    defer overlay.deinit();

    const rootfs = spore.Rootfs{ .device = .{ .mmio_slot = 1 }, .artifact = artifact };
    const base_source = block_source.FileBlockSource.init(base_fd, rootfs_bytes.len);
    var source_disk = try chunk_mapped_disk.ChunkMappedDisk.initWritable(allocator, base_source, overlay.fd, rootfs_bytes.len, rootfs_cas.default_chunk_size);
    defer source_disk.deinit();

    const patch = "chunk-index restore";
    try source_disk.writeAt(patch, 4096 + 32);
    const saved_disk = try source_disk.snapshotIndex(spore_dir, rootfs.device);
    defer {
        allocator.free(saved_disk.kind);
        allocator.free(saved_disk.device.kind);
        allocator.free(saved_disk.device.role);
        allocator.free(saved_disk.base);
        allocator.free(saved_disk.hash_algorithm);
        allocator.free(saved_disk.object_namespace);
    }

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const absolute_cache_root = try std.fs.path.resolve(arena, &.{cache_root});
    try env.put(local_paths.rootfs_cache_env, absolute_cache_root);
    const context = Context{ .io = io, .environ_map = &env };

    var runtime = try open(context, allocator, .{
        .rootfs = rootfs,
        .disk = saved_disk,
        .spore_dir = spore_dir,
    });
    defer runtime.deinit();

    try std.testing.expect(runtime.chunk_mapped != null);
    var readback: [patch.len]u8 = undefined;
    try runtime.chunk_mapped.?.readAt(&readback, 4096 + 32);
    try std.testing.expectEqualStrings(patch, &readback);
}
