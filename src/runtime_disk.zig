//! Runtime rootfs and writable disk planner shared by run and resume paths.

const std = @import("std");
const builtin = @import("builtin");

const block_source = @import("block_source.zig");
const chunk_mapped_disk = @import("chunk_mapped_disk.zig");
const Context = @import("context.zig").Context;
const disk_index = @import("disk_index.zig");
const disk_layer = @import("disk_layer.zig");
const fd_util = @import("fd.zig");
const local_paths = @import("local_paths.zig");
const rootfs_mod = @import("rootfs.zig");
const rootfs_cache = @import("rootfs_cache.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const saved_spore_pin = @import("saved_spore_pin.zig");
const runtime_disk_fork = @import("runtime_disk_fork.zig");
const runtime_disk_lease = @import("runtime_disk_lease.zig");
const spore = @import("spore.zig");
const virtio_blk = @import("virtio/blk.zig");

const Io = std.Io;
const rootfs_trace_env = "SPOREVM_ROOTFS_TRACE";
const rootfs_trace_summary_only_env = "SPOREVM_ROOTFS_TRACE_SUMMARY_ONLY";
const rootfs_eager_materialize_env = "SPOREVM_ROOTFS_EAGER_MATERIALIZE_FOR_BENCHMARK";

pub const Options = struct {
    rootfs_path: ?[]const u8 = null,
    rootfs: ?spore.Rootfs = null,
    disk: ?spore.Disk = null,
    spore_dir: ?[]const u8 = null,
    disk_root: ?[]const u8 = null,
    rootfs_grow_target: u64 = 0,
    rootfs_cache_lock: ?*const rootfs_mod.RootfsCacheLock = null,
};

pub const RuntimeDisk = struct {
    allocator: ?std.mem.Allocator = null,
    /// Owned trace fd, opened once from SPOREVM_ROOTFS_TRACE (O_APPEND) so
    /// per-read trace events do not pay an open/close each.
    trace_fd: ?std.c.fd_t = null,
    trace_summary_only: bool = false,
    rootfs_fd: ?std.c.fd_t = null,
    overlay: ?disk_layer.TempOverlay = null,
    chunk_mapped: ?chunk_mapped_disk.ChunkMappedDisk = null,
    base_disk: ?spore.Disk = null,
    runtime_lease: ?runtime_disk_lease.Active = null,

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

    /// Clones the live writable head without sealing a durable disk index.
    /// The VMM remains responsible for pausing vCPUs and draining virtio-blk.
    pub fn exportForkHead(
        self: *RuntimeDisk,
        options: chunk_mapped_disk.ExportForkOptions,
    ) !runtime_disk_fork.Head {
        const disk = if (self.chunk_mapped) |*value| value else return error.ReadOnly;
        return disk.exportForkHead(try self.forkBaseline(), options);
    }

    /// Adopts a claimed head only after this runtime has independently opened
    /// the exact immutable baseline named by the descriptor.
    pub fn adoptForkHead(self: *RuntimeDisk, head: *runtime_disk_fork.Head) !void {
        const disk = if (self.chunk_mapped) |*value| value else return error.ReadOnly;
        const overlay = if (self.overlay) |*value| value else return error.ReadOnly;
        const expected = try self.forkBaseline();
        if (expected.kind != head.descriptor.baseline.kind or !std.mem.eql(u8, expected.identity, head.descriptor.baseline.identity)) return error.BadDescriptor;
        if (disk.overlay_fd != overlay.fd) return error.BadManifest;

        const claimed_fd = head.overlay_fd;
        if (!try sameFilesystem(overlay.fd, claimed_fd)) return error.BadOverlay;
        const replaced_fd = try disk.applyForkDescriptor(head.descriptor, claimed_fd);
        head.overlay_fd = -1;
        overlay.fd = claimed_fd;
        _ = std.c.close(replaced_fd);
    }

    pub fn deinit(self: *RuntimeDisk) void {
        if (self.chunk_mapped) |*disk| disk.deinit();
        if (self.overlay) |*overlay| overlay.deinit();
        if (self.rootfs_fd) |fd| _ = std.c.close(fd);
        if (self.trace_fd) |fd| _ = std.c.close(fd);
        if (self.runtime_lease) |*lease| lease.deinit();
        self.* = .{};
    }

    fn baseSource(self: *RuntimeDisk, size: u64) !block_source.FileBlockSource {
        const fd = self.rootfs_fd orelse return error.BadManifest;
        return block_source.FileBlockSource.initWithTrace(fd, size, if (self.trace_summary_only) null else self.trace_fd);
    }

    fn forkBaseline(self: *RuntimeDisk) !runtime_disk_fork.Baseline {
        const base = self.base_disk orelse return error.ReadOnly;
        return disk_layer.forkBaseline(base);
    }
};

pub fn storageFromSnapshotDisk(allocator: std.mem.Allocator, disk: spore.Disk) !spore.RootfsStorage {
    if (!std.mem.eql(u8, disk.kind, spore.disk_kind_chunk_index)) return error.BadManifest;
    if (disk.layers.len != 0) return error.BadManifest;
    const base = try allocator.dupe(u8, disk.base);
    return .{
        .kind = try allocator.dupe(u8, spore.rootfs_storage_kind_chunked_ext4),
        .device = try spore.cloneRootfsDevice(allocator, disk.device),
        .logical_size = disk.size,
        .chunk_size = disk.chunk_size,
        .hash_algorithm = try allocator.dupe(u8, disk.hash_algorithm),
        .index_digest = base,
        .base_identity = try allocator.dupe(u8, disk.base),
        .object_namespace = try allocator.dupe(u8, disk.object_namespace),
    };
}

pub fn open(context: Context, allocator: std.mem.Allocator, options: Options) !RuntimeDisk {
    var runtime = RuntimeDisk{ .allocator = allocator };
    errdefer runtime.deinit();
    runtime.trace_fd = try openRootfsTraceFd(context, allocator);
    runtime.trace_summary_only = envEnabled(context, rootfs_trace_summary_only_env);
    const trace_open_start_ns = if (runtime.trace_fd != null) monotonicNs() else 0;

    // A durable disk index is a complete baseline authority. Open it directly
    // from its lease root instead of first requiring the original rootfs cache
    // artifact, which may legitimately have been pruned after the save.
    if (options.disk) |disk| {
        const rootfs = options.rootfs orelse return error.BadManifest;
        if (!std.mem.eql(u8, disk.kind, spore.disk_kind_chunk_index)) {
            if (std.mem.eql(u8, disk.kind, spore.disk_kind_cow_block)) return error.FormatTooOld;
            return error.BadManifest;
        }
        if (!spore.rootfsDeviceEql(disk.device, rootfs.device)) return error.BadManifest;
        if (disk.layers.len != 0) return error.BadManifest;
        if (disk.size != spore.effectiveRootfsLogicalSize(rootfs)) return error.BadManifest;
        if (disk.chunk_size != spore.disk_chunk_size) return error.BadManifest;
        if (!std.mem.eql(u8, disk.hash_algorithm, spore.rootfs_storage_hash_algorithm_blake3)) return error.BadManifest;
        if (!std.mem.eql(u8, disk.object_namespace, spore.rootfs_storage_object_namespace)) return error.BadManifest;
        var authority = try resolveSavedDiskRoot(context, allocator, options, disk);
        defer allocator.free(authority.root);
        runtime.runtime_lease = authority.runtime_lease;
        authority.runtime_lease = null;
        const disk_root = authority.root;
        runtime.rootfs_fd = try createSparseTempFd(context, allocator, disk.size);
        const base_source = try runtime.baseSource(disk.size);
        const writable = try openWritable(context, allocator, base_source, disk.size, disk.chunk_size);
        runtime.overlay = writable.overlay;
        runtime.chunk_mapped = writable.disk;
        var parsed = try readDiskIndex(context, allocator, disk_root, diskStorageDescriptor(disk));
        defer parsed.deinit();
        try runtime.chunk_mapped.?.attachCasIndexTraced(disk_root, parsed.value, runtime.trace_fd);
        runtime.base_disk = disk;
        runtime.chunk_mapped.?.setLazyCasRuntimeOpenNs(elapsedNs(trace_open_start_ns));
        return runtime;
    }
    var rootfs_lazy_storage: ?spore.RootfsStorage = null;

    if (options.rootfs) |rootfs| {
        if (rootfs.storage) |storage| {
            try validateRuntimeRootfsStorage(rootfs, storage);
            // The flat digest-addressed ext4 artifact is the only runtime
            // base source on warm paths. When it is not materialized locally
            // (chunk-only pull caches, pruned entries), defer assembly and let
            // the chunk-mapped backend fault verified CAS objects into a sparse
            // base on demand.
            if (options.rootfs_grow_target != 0) {
                rootfs_lazy_storage = storage;
                std.log.debug("runtime disk rootfs base: lazy chunk index {s} with grow target", .{rootfs.artifact.digest});
            } else if (try openCachedFlatRootfs(context, allocator, rootfs, runtime.trace_fd, options.disk_root)) |fd| {
                runtime.rootfs_fd = fd;
                std.log.debug("runtime disk rootfs base: flat artifact {s}", .{rootfs.artifact.digest});
            } else if (forceEagerRootfsMaterialization(context)) {
                try materializeFlatRootfs(context, allocator, rootfs, options.disk_root);
                runtime.rootfs_fd = try openTrustedRootfs(context, allocator, rootfs, runtime.trace_fd, options.disk_root);
                std.log.debug("runtime disk rootfs base: flat artifact {s}", .{rootfs.artifact.digest});
            } else {
                rootfs_lazy_storage = storage;
                std.log.debug("runtime disk rootfs base: lazy chunk index {s}", .{rootfs.artifact.digest});
            }
        } else {
            runtime.rootfs_fd = try openTrustedRootfs(context, allocator, rootfs, runtime.trace_fd, options.disk_root);
        }
    } else {
        runtime.rootfs_fd = try openRootfsDisk(allocator, options.rootfs_path);
    }

    if (runtime.rootfs_fd == null and rootfs_lazy_storage == null) return runtime;

    if (options.rootfs) |rootfs| {
        const base = diskFromRootfs(rootfs);
        if (runtime.rootfs_fd == null) {
            const storage = rootfs_lazy_storage orelse return error.BadManifest;
            const grown_size = try grownRootfsSize(storage.logical_size, storage.chunk_size, options.rootfs_grow_target);
            const cache_root = try baselineRootPath(context, allocator, options.disk_root);
            defer allocator.free(cache_root);
            runtime.runtime_lease = try acquireLazyRootfsLease(context, allocator, cache_root, storage, options.rootfs_cache_lock);
            runtime.rootfs_fd = try createSparseTempFd(context, allocator, grown_size);
            const base_source = try runtime.baseSource(grown_size);
            const writable = try openWritable(context, allocator, base_source, storage.logical_size, storage.chunk_size);
            runtime.overlay = writable.overlay;
            runtime.chunk_mapped = writable.disk;
            var parsed = try readDiskIndex(context, allocator, cache_root, storage);
            defer parsed.deinit();
            try runtime.chunk_mapped.?.attachCasIndexTraced(cache_root, parsed.value, runtime.trace_fd);
            // The sparse fd and verified parent index make every appended byte
            // authoritative zero. Preserve that fact in the source map rather
            // than manufacturing dirty zero payload.
            try runtime.chunk_mapped.?.growKnownZero(grown_size);
            runtime.base_disk = base;
            runtime.base_disk.?.size = grown_size;
            runtime.chunk_mapped.?.setLazyCasRuntimeOpenNs(elapsedNs(trace_open_start_ns));
            return runtime;
        }
        const base_source = try runtime.baseSource(base.size);
        const writable = try openWritable(context, allocator, base_source, base.size, base.chunk_size);
        runtime.overlay = writable.overlay;
        runtime.chunk_mapped = writable.disk;
        if (rootfs.storage) |storage| {
            const cache_root = try baselineRootPath(context, allocator, options.disk_root);
            defer allocator.free(cache_root);
            var parsed = try readDiskIndex(context, allocator, cache_root, storage);
            defer parsed.deinit();
            try runtime.chunk_mapped.?.attachParentIndex(cache_root, parsed.value);
        }
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

const SavedDiskAuthority = struct { root: []const u8, runtime_lease: ?runtime_disk_lease.Active = null };

fn resolveSavedDiskRoot(context: Context, allocator: std.mem.Allocator, options: Options, disk: spore.Disk) !SavedDiskAuthority {
    if (options.disk_root) |root| return .{ .root = try allocator.dupe(u8, root) };
    const spore_dir = options.spore_dir orelse return error.BadManifest;
    if (try saved_spore_pin.hasLocalIndex(context.io, allocator, spore_dir, disk)) {
        return .{ .root = try allocator.dupe(u8, spore_dir) };
    }
    const configured_root = try rootfsCacheRootPath(context, allocator);
    defer allocator.free(configured_root);
    const cache_root = if (std.fs.path.isAbsolute(configured_root))
        try allocator.dupe(u8, configured_root)
    else blk: {
        const cwd = try std.process.currentPathAlloc(context.io, allocator);
        defer allocator.free(cwd);
        break :blk try std.fs.path.resolve(allocator, &.{ cwd, configured_root });
    };
    errdefer allocator.free(cache_root);
    var cache_lock = try rootfs_mod.lockRootfsCacheExclusive(context.io, allocator, cache_root);
    defer cache_lock.deinit();
    const registry = try saved_spore_pin.LockedRegistry.init(allocator, cache_root, &cache_lock);
    var pin = try saved_spore_pin.loadForSporeLocked(context.io, allocator, registry, spore_dir, disk);
    defer pin.deinit();
    const runtime_root = try local_paths.runtimeRootPath(allocator, context.environ_map);
    defer allocator.free(runtime_root);
    const lease = runtime_disk_lease.Lease{
        .store = .rootfs_cache,
        .root = cache_root,
        .baseline_kind = .disk_index,
        .baseline_identity = disk.base,
        .rootfs_storage = try saved_spore_pin.storageForDisk(disk),
    };
    return .{ .root = cache_root, .runtime_lease = try runtime_disk_lease.acquireActive(context.io, allocator, runtime_root, lease) };
}

const WritableDisk = struct {
    overlay: disk_layer.TempOverlay,
    disk: chunk_mapped_disk.ChunkMappedDisk,
};

fn openWritable(
    context: Context,
    allocator: std.mem.Allocator,
    base: block_source.FileBlockSource,
    size: u64,
    chunk_size: u64,
) !WritableDisk {
    const overlay_dir = try local_paths.runtimeOverlayRootPath(allocator, context.environ_map);
    defer allocator.free(overlay_dir);
    var overlay = try disk_layer.createTempOverlayAt(allocator, overlay_dir);
    errdefer overlay.deinit();
    const disk = try chunk_mapped_disk.ChunkMappedDisk.initWritableAt(
        allocator,
        base,
        overlay.fd,
        overlay_dir,
        size,
        chunk_size,
    );
    return .{ .overlay = overlay, .disk = disk };
}

fn sameFilesystem(a: std.c.fd_t, b: std.c.fd_t) !bool {
    return try filesystemDevice(a) == try filesystemDevice(b);
}

fn filesystemDevice(fd: std.c.fd_t) !u64 {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var stat: linux.Statx = undefined;
        const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &stat);
        if (linux.errno(rc) != .SUCCESS) return error.IoFailed;
        return (@as(u64, stat.dev_major) << 32) | stat.dev_minor;
    }
    var stat: std.c.Stat = undefined;
    if (std.c.fstat(fd, &stat) != 0) return error.IoFailed;
    return @intCast(stat.dev);
}

test "filesystem identity distinguishes Linux anonymous backing" {
    var overlay = try disk_layer.createTempOverlay(std.testing.allocator);
    defer overlay.deinit();
    try std.testing.expect(try sameFilesystem(overlay.fd, overlay.fd));

    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const rc = linux.memfd_create("sporevm-filesystem-test", linux.MFD.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.IoFailed;
        const memfd: std.c.fd_t = @intCast(rc);
        defer _ = std.c.close(memfd);
        try std.testing.expect(!try sameFilesystem(overlay.fd, memfd));
    }
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

fn createSparseTempFd(context: Context, allocator: std.mem.Allocator, size: u64) !std.c.fd_t {
    const overlay_dir = try local_paths.runtimeOverlayRootPath(allocator, context.environ_map);
    defer allocator.free(overlay_dir);
    var temp = try disk_layer.createTempOverlayAt(allocator, overlay_dir);
    errdefer temp.deinit();
    const logical_size = std.math.cast(std.c.off_t, size) orelse return error.BadManifest;
    if (std.c.ftruncate(temp.fd, logical_size) != 0) return error.IoFailed;
    const fd = temp.fd;
    temp.fd = -1;
    return fd;
}

fn grownRootfsSize(logical_size: u64, chunk_size: u64, grow_target: u64) !u64 {
    if (grow_target == 0) return logical_size;
    if (grow_target < logical_size) return error.BadManifest;
    const remainder = grow_target % chunk_size;
    if (remainder == 0) return grow_target;
    return std.math.add(u64, grow_target, chunk_size - remainder) catch return error.BadManifest;
}

fn diskFromRootfs(rootfs: spore.Rootfs) spore.Disk {
    if (rootfs.storage) |storage| {
        return .{
            .kind = spore.disk_kind_chunk_index,
            .device = storage.device,
            .size = storage.logical_size,
            .base = storage.index_digest,
            .chunk_size = storage.chunk_size,
            .hash_algorithm = storage.hash_algorithm,
            .object_namespace = storage.object_namespace,
            .layers = &.{},
        };
    }
    return disk_layer.diskFromRootfs(rootfs);
}

fn diskStorageDescriptor(disk: spore.Disk) spore.RootfsStorage {
    return .{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = disk.device,
        .logical_size = disk.size,
        .chunk_size = disk.chunk_size,
        .hash_algorithm = disk.hash_algorithm,
        .index_digest = disk.base,
        .base_identity = disk.base,
        .object_namespace = disk.object_namespace,
    };
}

fn validateRuntimeRootfsStorage(rootfs: spore.Rootfs, storage: spore.RootfsStorage) !void {
    if (!std.mem.eql(u8, rootfs.artifact.format, spore.rootfs_artifact_format_ext4)) return error.BadManifest;
    if (!spore.rootfsDeviceEql(storage.device, rootfs.device)) return error.BadManifest;
    if (storage.logical_size != rootfs.artifact.size) return error.BadManifest;
    if (!std.mem.eql(u8, storage.index_digest, rootfs.artifact.digest)) return error.BadManifest;
    try spore.validateRootfsStorageDescriptor(storage);
}

fn readDiskIndex(
    context: Context,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    storage: spore.RootfsStorage,
) !std.json.Parsed(disk_index.DiskIndex) {
    try spore.validateRootfsStorageDescriptor(storage);
    const index_path = try rootfs_cas.manifestIndexPath(allocator, cache_root, storage.index_digest);
    defer allocator.free(index_path);
    const index_bytes = Io.Dir.cwd().readFileAlloc(context.io, index_path, allocator, .limited(disk_index.max_index_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return error.BadManifest,
        else => |e| return e,
    };
    defer allocator.free(index_bytes);
    return disk_index.parseDiskIndex(allocator, index_bytes, try spore.diskIndexDescriptorForStorage(storage));
}

fn openTrustedRootfs(
    context: Context,
    allocator: std.mem.Allocator,
    rootfs: spore.Rootfs,
    trace_fd: ?std.c.fd_t,
    root_override: ?[]const u8,
) !std.c.fd_t {
    const cache_root = try baselineRootPath(context, allocator, root_override);
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
fn openCachedFlatRootfs(
    context: Context,
    allocator: std.mem.Allocator,
    rootfs: spore.Rootfs,
    trace_fd: ?std.c.fd_t,
    root_override: ?[]const u8,
) !?std.c.fd_t {
    return openTrustedRootfs(context, allocator, rootfs, trace_fd, root_override) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

fn materializeFlatRootfs(context: Context, allocator: std.mem.Allocator, rootfs: spore.Rootfs, root_override: ?[]const u8) !void {
    const cache_root = try baselineRootPath(context, allocator, root_override);
    defer allocator.free(cache_root);
    try rootfs_cas.materializeFlatFromChunks(context.io, allocator, cache_root, rootfs);
}

fn rootfsCacheRootPath(context: Context, allocator: std.mem.Allocator) ![]const u8 {
    return local_paths.rootfsCacheRootPath(allocator, context.environ_map) catch |err| switch (err) {
        error.MissingHome => return error.MissingHome,
        else => |e| return e,
    };
}

fn baselineRootPath(context: Context, allocator: std.mem.Allocator, root_override: ?[]const u8) ![]const u8 {
    if (root_override) |root| return allocator.dupe(u8, root);
    return rootfsCacheRootPath(context, allocator);
}

fn acquireLazyRootfsLease(
    context: Context,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    storage: spore.RootfsStorage,
    rootfs_cache_lock: ?*const rootfs_mod.RootfsCacheLock,
) !?runtime_disk_lease.Active {
    const configured_cache_root = try rootfsCacheRootPath(context, allocator);
    defer allocator.free(configured_cache_root);
    if (!std.mem.eql(u8, configured_cache_root, cache_root)) return null;

    var cache_lock: ?rootfs_mod.RootfsCacheLock = null;
    defer if (cache_lock) |*lock| lock.deinit();
    if (rootfs_cache_lock) |lock| {
        if (!try lock.ensureHeldFor(allocator, cache_root)) return error.RootfsCacheLockNotHeld;
    } else {
        cache_lock = try rootfs_mod.lockRootfsCacheExclusive(context.io, allocator, cache_root);
    }
    if (!try rootfs_cas.storageMarkedComplete(context.io, allocator, cache_root, storage)) return error.BadManifest;

    const runtime_root = try local_paths.runtimeRootPath(allocator, context.environ_map);
    defer allocator.free(runtime_root);
    const lease_root = if (std.fs.path.isAbsolute(cache_root))
        try allocator.dupe(u8, cache_root)
    else blk: {
        const cwd = try std.process.currentPathAlloc(context.io, allocator);
        defer allocator.free(cwd);
        break :blk try std.fs.path.resolve(allocator, &.{ cwd, cache_root });
    };
    defer allocator.free(lease_root);
    return try runtime_disk_lease.acquireActive(context.io, allocator, runtime_root, .{
        .store = .rootfs_cache,
        .root = lease_root,
        .baseline_kind = .disk_index,
        .baseline_identity = storage.index_digest,
        .rootfs_storage = storage,
    });
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

fn forceEagerRootfsMaterialization(context: Context) bool {
    return envEnabled(context, rootfs_eager_materialize_env);
}

fn envEnabled(context: Context, name: []const u8) bool {
    const raw = context.environ_map.get(name) orelse return false;
    if (raw.len == 0) return false;
    if (std.mem.eql(u8, raw, "0")) return false;
    if (std.ascii.eqlIgnoreCase(raw, "false")) return false;
    return true;
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

fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn elapsedNs(start_ns: u64) u64 {
    if (start_ns == 0) return 0;
    return monotonicNs() -| start_ns;
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
    const rootfs_bytes = ("abcd" ** 16384) ++ ("efgh" ** 16384);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = rootfs_bytes });

    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const preload_result = try rootfs_cas.preload(io, arena, cache_root, artifact.digest, spore.disk_chunk_size);
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
        .disk_root = absolute_cache_root,
    });
    defer runtime.deinit();

    try std.testing.expect(runtime.rootfs_fd != null);
    try std.testing.expect(runtime.chunk_mapped != null);
    try std.testing.expect(runtime.chunk_mapped.?.cas_root == null);
    try std.testing.expect(runtime.chunk_mapped.?.parent_root != null);
    try std.testing.expectEqual(@as(usize, @intCast(preload_result.nonzero_chunks)), runtime.chunk_mapped.?.indexDigestCount());
    var readback: [4]u8 = undefined;
    try runtime.chunk_mapped.?.readAt(&readback, 0);
    try std.testing.expectEqualStrings("abcd", &readback);
    try runtime.chunk_mapped.?.readAt(&readback, rootfs_bytes.len - 4);
    try std.testing.expectEqualStrings("efgh", &readback);
    const trace_bytes = try Io.Dir.cwd().readFileAlloc(io, trace_path, arena, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, trace_bytes, "\"event\":\"rootfs_open\"") != null);
}

test "runtime disk exports and adopts a portable fork head" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-runtime-disk-portable-fork-head";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    const rootfs_bytes = ("abcd" ** 16384) ++ ("efgh" ** 16384) ++ ("ijkl" ** 16384);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = rootfs_bytes });
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const absolute_cache_root = try std.fs.path.resolve(arena, &.{cache_root});
    const cwd = try std.process.currentPathAlloc(io, arena);
    const absolute_tmp_root = try std.fs.path.resolve(arena, &.{ cwd, tmp });
    try env.put(local_paths.rootfs_cache_env, absolute_cache_root);
    try env.put("TMPDIR", absolute_tmp_root);
    const context = Context{ .io = io, .environ_map = &env };
    const rootfs = spore.Rootfs{ .device = .{ .mmio_slot = 1 }, .artifact = artifact };

    var parent = try open(context, allocator, .{ .rootfs = rootfs });
    defer parent.deinit();
    var child = try open(context, allocator, .{ .rootfs = rootfs });
    defer child.deinit();
    try std.testing.expectEqualStrings(absolute_tmp_root, parent.chunk_mapped.?.overlay_dir.?);
    try std.testing.expectEqualStrings(absolute_tmp_root, child.chunk_mapped.?.overlay_dir.?);

    const parent_patch = [_]u8{0xA5} ** 97;
    try parent.chunk_mapped.?.writeAt(&parent_patch, spore.disk_chunk_size - 17);
    try parent.chunk_mapped.?.markZeroChunk(2);
    var head = try parent.exportForkHead(.{ .allow_copy = true, .force_copy = true, .quiesced = true });
    defer head.deinit();
    const parent_overlay_fd = parent.overlay.?.fd;
    const replaced_child_fd = child.overlay.?.fd;
    try child.adoptForkHead(&head);
    try std.testing.expectEqual(@as(std.c.fd_t, -1), head.overlay_fd);
    try std.testing.expect(parent.overlay.?.fd == parent_overlay_fd);
    try std.testing.expect(child.overlay.?.fd != replaced_child_fd);
    try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(replaced_child_fd, std.c.F.GETFD, @as(c_int, 0)));

    const parent_bytes = try allocator.alloc(u8, rootfs_bytes.len);
    defer allocator.free(parent_bytes);
    const child_bytes = try allocator.alloc(u8, rootfs_bytes.len);
    defer allocator.free(child_bytes);
    try parent.chunk_mapped.?.readAt(parent_bytes, 0);
    try child.chunk_mapped.?.readAt(child_bytes, 0);
    try std.testing.expectEqualSlices(u8, parent_bytes, child_bytes);

    try parent.chunk_mapped.?.writeAt("parent", 3);
    try child.chunk_mapped.?.writeAt("child", spore.disk_chunk_size + 1024);
    var readback: [6]u8 = undefined;
    try child.chunk_mapped.?.readAt(&readback, 3);
    try std.testing.expectEqualSlices(u8, rootfs_bytes[3..][0..readback.len], &readback);
    try parent.chunk_mapped.?.readAt(readback[0..5], spore.disk_chunk_size + 1024);
    try std.testing.expectEqualSlices(u8, rootfs_bytes[spore.disk_chunk_size + 1024 ..][0..5], readback[0..5]);

    var mismatched = try parent.exportForkHead(.{ .allow_copy = true, .force_copy = true, .quiesced = true });
    defer mismatched.deinit();
    const mutable_identity = @constCast(mismatched.descriptor.baseline.identity);
    mutable_identity[mutable_identity.len - 1] = if (mutable_identity[mutable_identity.len - 1] == 'a') 'b' else 'a';
    try std.testing.expectError(error.BadDescriptor, child.adoptForkHead(&mismatched));
    try std.testing.expect(mismatched.overlay_fd >= 0);
}

test "runtime disk lazily faults rootfs cas chunks when the flat artifact is missing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-runtime-disk-cas-fallback-missing";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    const trace_path = tmp ++ "/lazy-cas-trace.jsonl";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    const rootfs_bytes = ("abcd" ** 16384) ++ ("efgh" ** 16384);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = rootfs_bytes });

    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const preload_result = try rootfs_cas.preload(io, arena, cache_root, artifact.digest, spore.disk_chunk_size);
    const storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload_result);
    const rootfs_artifact = spore.RootfsArtifactRef{ .digest = storage.index_digest, .size = artifact.size };
    const digest_path = try rootfs_cache.digestPath(arena, cache_root, rootfs_artifact.digest);
    Io.Dir.cwd().deleteFile(io, digest_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    const index_bytes = try Io.Dir.cwd().readFileAlloc(io, preload_result.index_path, arena, .limited(disk_index.max_index_bytes));
    const parsed = try disk_index.parseDiskIndex(arena, index_bytes, try spore.diskIndexDescriptorForStorage(storage));
    defer parsed.deinit();
    const first_chunk_path = try rootfs_cas.manifestObjectPath(arena, cache_root, parsed.value.chunks[0].digest);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const absolute_cache_root = try std.fs.path.resolve(arena, &.{cache_root});
    const unrelated_cache_root = try std.fs.path.resolve(arena, &.{ tmp, "unrelated-cache" });
    try Io.Dir.cwd().createDirPath(io, unrelated_cache_root);
    try env.put(local_paths.rootfs_cache_env, unrelated_cache_root);
    const absolute_trace_path = try std.fs.path.resolve(arena, &.{trace_path});
    try env.put(rootfs_trace_env, absolute_trace_path);
    try env.put(rootfs_trace_summary_only_env, "1");

    const context = Context{ .io = io, .environ_map = &env };

    const rootfs = spore.Rootfs{
        .device = .{ .mmio_slot = 1 },
        .artifact = rootfs_artifact,
        .storage = storage,
    };
    var runtime = try open(context, allocator, .{
        .rootfs = rootfs,
        .disk_root = absolute_cache_root,
    });
    var runtime_open = true;
    defer if (runtime_open) runtime.deinit();

    try std.testing.expect(runtime.rootfs_fd != null);
    try std.testing.expect(runtime.chunk_mapped != null);
    var readback: [4]u8 = undefined;
    try runtime.chunk_mapped.?.readAt(&readback, 0);
    try std.testing.expectEqualStrings("abcd", &readback);
    try Io.Dir.cwd().deleteFile(io, first_chunk_path);
    try runtime.chunk_mapped.?.readAt(&readback, 0);
    try std.testing.expectEqualStrings("abcd", &readback);
    // Non-fault transitions also reduce the remaining lazy working set.
    try runtime.chunk_mapped.?.markZeroChunk(1);
    // Lazy fault-in promotes into the sparse runtime base, not the by-digest
    // materialization cache.
    try std.testing.expect(!try rootfs_cache.regularFileNoSymlink(io, digest_path));

    runtime.deinit();
    runtime_open = false;
    const trace = try Io.Dir.cwd().readFileAlloc(io, trace_path, arena, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"event\":\"block_source_read\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"event\":\"lazy_cas_fault_summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"cas_chunks_initial\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"cas_chunks_remaining\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"fault_attempts\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"fault_errors\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"unique_chunks\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"fault_bytes\":65536") != null);
}

test "build-owned cache lock permits lazy runtime disk open" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-runtime-disk-build-cache-lock";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    const rootfs_bytes = ("abcd" ** 16384) ++ ("efgh" ** 16384);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = rootfs_bytes });

    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const preload_result = try rootfs_cas.preload(io, arena, cache_root, artifact.digest, spore.disk_chunk_size);
    const storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload_result);
    const rootfs = spore.Rootfs{
        .device = .{ .mmio_slot = 1 },
        .artifact = .{ .digest = storage.index_digest, .size = artifact.size },
        .storage = storage,
    };

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const cwd = try std.process.currentPathAlloc(io, arena);
    const absolute_tmp = try std.fs.path.resolve(arena, &.{ cwd, tmp });
    const absolute_cache_root = try std.fs.path.resolve(arena, &.{ cwd, cache_root });
    const runtime_root = try std.fs.path.join(arena, &.{ absolute_tmp, "runtime" });
    try env.put(local_paths.rootfs_cache_env, absolute_cache_root);
    try env.put(local_paths.runtime_dir_env, runtime_root);
    try env.put("TMPDIR", absolute_tmp);
    const context = Context{ .io = io, .environ_map = &env };

    var cache_lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, absolute_cache_root);
    defer cache_lock.deinit();
    var runtime = try open(context, allocator, .{
        .rootfs = rootfs,
        .rootfs_grow_target = storage.logical_size + storage.chunk_size,
        .rootfs_cache_lock = &cache_lock,
    });
    defer runtime.deinit();

    try std.testing.expect(runtime.chunk_mapped != null);
    try std.testing.expect(runtime.runtime_lease != null);
    try std.testing.expectError(error.LockBusy, rootfs_mod.tryLockRootfsCacheExclusive(io, arena, absolute_cache_root));

    const cache_alias = try std.fs.path.join(arena, &.{ absolute_tmp, "cache-alias" });
    try Io.Dir.cwd().symLink(io, absolute_cache_root, cache_alias, .{});
    try std.testing.expect(try cache_lock.ensureHeldFor(arena, cache_alias));

    const wrong_cache_root = try std.fs.path.join(arena, &.{ absolute_tmp, "wrong-cache" });
    try Io.Dir.cwd().createDirPath(io, wrong_cache_root);
    try env.put(local_paths.rootfs_cache_env, wrong_cache_root);
    try std.testing.expectError(error.RootfsCacheLockNotHeld, acquireLazyRootfsLease(context, allocator, wrong_cache_root, storage, &cache_lock));
    try env.put(local_paths.rootfs_cache_env, absolute_cache_root);

    var stale_cache_lock = cache_lock;
    runtime.deinit();
    cache_lock.deinit();
    try std.testing.expectError(error.RootfsCacheLockNotHeld, open(context, allocator, .{
        .rootfs = rootfs,
        .rootfs_grow_target = storage.logical_size + storage.chunk_size,
        .rootfs_cache_lock = &cache_lock,
    }));
    try std.testing.expectError(error.RootfsCacheLockNotHeld, open(context, allocator, .{
        .rootfs = rootfs,
        .rootfs_grow_target = storage.logical_size + storage.chunk_size,
        .rootfs_cache_lock = &stale_cache_lock,
    }));
}

test "runtime disk benchmark env eagerly materializes missing flat rootfs from cas" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-runtime-disk-eager-benchmark-env";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    const rootfs_bytes = ("abcd" ** 16384) ++ ("efgh" ** 16384);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = rootfs_bytes });

    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const preload_result = try rootfs_cas.preload(io, arena, cache_root, artifact.digest, spore.disk_chunk_size);
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
    try env.put(rootfs_eager_materialize_env, "1");
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
    try std.testing.expect(runtime.chunk_mapped.?.cas_root == null);
    try std.testing.expect(try rootfs_cache.regularFileNoSymlink(io, digest_path));
    var readback: [4]u8 = undefined;
    try runtime.chunk_mapped.?.readAt(&readback, spore.disk_chunk_size);
    try std.testing.expectEqualStrings("efgh", &readback);
}

test "runtime disk ignores wrong-sized flat cache entries and lazily faults cas chunks" {
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
    const preload_result = try rootfs_cas.preload(io, arena, cache_root, artifact.digest, spore.disk_chunk_size);
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
    const stale = try Io.Dir.cwd().readFileAlloc(io, digest_path, arena, .limited(1 << 20));
    try std.testing.expectEqualStrings("truncated", stale);
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
    const preload_result = try rootfs_cas.preload(io, arena, cache_root, artifact.digest, spore.disk_chunk_size);
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
    try std.testing.expectError(error.BadManifest, open(context, allocator, .{
        .rootfs = rootfs,
    }));
}

test "runtime disk lazy rootfs validates storage against artifact" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-runtime-disk-lazy-storage-mismatch";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    Io.Dir.cwd().deleteTree(io, tmp) catch {};
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });

    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const preload_result = try rootfs_cas.preload(io, arena, cache_root, artifact.digest, spore.disk_chunk_size);
    const storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload_result);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const absolute_cache_root = try std.fs.path.resolve(arena, &.{cache_root});
    try env.put(local_paths.rootfs_cache_env, absolute_cache_root);
    const context = Context{ .io = io, .environ_map = &env };

    const rootfs = spore.Rootfs{
        .device = .{ .mmio_slot = 1 },
        .artifact = .{ .digest = storage.index_digest, .size = artifact.size + 1 },
        .storage = storage,
    };
    try std.testing.expectError(error.BadManifest, open(context, allocator, .{
        .rootfs = rootfs,
    }));
}

test "runtime disk reports missing cas object on first read of that chunk" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-runtime-disk-lazy-cas-missing-object";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    const trace_path = tmp ++ "/lazy-cas-trace.jsonl";
    Io.Dir.cwd().deleteTree(io, tmp) catch {};
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    const rootfs_bytes = ("abcd" ** 16384) ++ ("efgh" ** 16384);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = rootfs_bytes });

    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const preload_result = try rootfs_cas.preload(io, arena, cache_root, artifact.digest, spore.disk_chunk_size);
    const storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload_result);
    const rootfs_artifact = spore.RootfsArtifactRef{ .digest = storage.index_digest, .size = artifact.size };
    const digest_path = try rootfs_cache.digestPath(arena, cache_root, rootfs_artifact.digest);
    Io.Dir.cwd().deleteFile(io, digest_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };

    const index_bytes = try Io.Dir.cwd().readFileAlloc(io, preload_result.index_path, arena, .limited(disk_index.max_index_bytes));
    const parsed = try disk_index.parseDiskIndex(arena, index_bytes, try spore.diskIndexDescriptorForStorage(storage));
    defer parsed.deinit();
    const second_chunk_path = try rootfs_cas.manifestObjectPath(arena, cache_root, parsed.value.chunks[1].digest);
    try Io.Dir.cwd().deleteFile(io, second_chunk_path);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const absolute_cache_root = try std.fs.path.resolve(arena, &.{cache_root});
    try env.put(local_paths.rootfs_cache_env, absolute_cache_root);
    const absolute_trace_path = try std.fs.path.resolve(arena, &.{trace_path});
    try env.put(rootfs_trace_env, absolute_trace_path);
    try env.put(rootfs_trace_summary_only_env, "1");
    const context = Context{ .io = io, .environ_map = &env };

    const rootfs = spore.Rootfs{
        .device = .{ .mmio_slot = 1 },
        .artifact = rootfs_artifact,
        .storage = storage,
    };
    var runtime = try open(context, allocator, .{
        .rootfs = rootfs,
    });
    var runtime_open = true;
    defer if (runtime_open) runtime.deinit();

    var readback: [4]u8 = undefined;
    try runtime.chunk_mapped.?.readAt(&readback, 0);
    try std.testing.expectEqualStrings("abcd", &readback);
    const failed_read = try arena.alloc(u8, 2 * spore.disk_chunk_size);
    @memset(failed_read, 0xaa);
    try std.testing.expectError(error.MissingChunk, runtime.chunk_mapped.?.readAt(failed_read, 0));
    try std.testing.expect(std.mem.allEqual(u8, failed_read, 0xaa));

    runtime.deinit();
    runtime_open = false;
    const trace = try Io.Dir.cwd().readFileAlloc(io, trace_path, arena, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"fault_attempts\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"fault_errors\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"unique_chunks\":1") != null);
}

test "runtime disk lazy rootfs survives promoted chunk eviction and rejects corrupt unread chunks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-runtime-disk-lazy-cas-promoted-and-corrupt";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    Io.Dir.cwd().deleteTree(io, tmp) catch {};
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    const rootfs_bytes = ("abcd" ** 16384) ++ ("efgh" ** 16384) ++ ("ijkl" ** 16384);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = rootfs_bytes });

    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const preload_result = try rootfs_cas.preload(io, arena, cache_root, artifact.digest, spore.disk_chunk_size);
    const storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload_result);
    const rootfs_artifact = spore.RootfsArtifactRef{ .digest = storage.index_digest, .size = artifact.size };
    const digest_path = try rootfs_cache.digestPath(arena, cache_root, rootfs_artifact.digest);
    Io.Dir.cwd().deleteFile(io, digest_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };

    const index_bytes = try Io.Dir.cwd().readFileAlloc(io, preload_result.index_path, arena, .limited(disk_index.max_index_bytes));
    const parsed = try disk_index.parseDiskIndex(arena, index_bytes, try spore.diskIndexDescriptorForStorage(storage));
    defer parsed.deinit();
    const first_chunk_path = try rootfs_cas.manifestObjectPath(arena, cache_root, parsed.value.chunks[0].digest);
    const third_chunk_path = try rootfs_cas.manifestObjectPath(arena, cache_root, parsed.value.chunks[2].digest);

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

    try Io.Dir.cwd().deleteFile(io, first_chunk_path);
    const corrupt_chunk = try arena.alloc(u8, spore.disk_chunk_size);
    @memset(corrupt_chunk, 0xee);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = third_chunk_path, .data = corrupt_chunk });

    @memset(&readback, 0);
    try runtime.chunk_mapped.?.readAt(&readback, 0);
    try std.testing.expectEqualStrings("abcd", &readback);

    try runtime.chunk_mapped.?.readAt(&readback, spore.disk_chunk_size);
    try std.testing.expectEqualStrings("efgh", &readback);

    const failed_read = try arena.alloc(u8, 2 * spore.disk_chunk_size);
    @memset(failed_read, 0xaa);
    try std.testing.expectError(error.BadChunk, runtime.chunk_mapped.?.readAt(failed_read, spore.disk_chunk_size));
    try std.testing.expect(std.mem.allEqual(u8, failed_read, 0xaa));
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
    const saved_disk = try source_disk.snapshotIndex(cache_root, rootfs.device, true);
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
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = spore_dir ++ "/manifest.json", .data = "manifest" });
    var pin_lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, absolute_cache_root);
    defer pin_lock.deinit();
    const pin_registry = try saved_spore_pin.LockedRegistry.init(arena, absolute_cache_root, &pin_lock);
    const pin_id = try saved_spore_pin.create(io, arena, pin_registry, spore_dir, saved_disk);
    pin_lock.deinit();
    const storage = try saved_spore_pin.storageForDisk(saved_disk);
    const global_index_path = try rootfs_cas.manifestIndexPath(arena, absolute_cache_root, storage.index_digest);
    const index_bytes = try Io.Dir.cwd().readFileAlloc(io, global_index_path, arena, .limited(disk_index.max_index_bytes));
    var local_index = try disk_index.parseDiskIndex(arena, index_bytes, try spore.diskIndexDescriptorForStorage(storage));
    defer local_index.deinit();
    const local_index_path = try rootfs_cas.manifestIndexPath(arena, spore_dir, storage.index_digest);
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(local_index_path).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = local_index_path, .data = index_bytes });
    for (local_index.value.chunks) |entry| {
        const source_object = try rootfs_cas.manifestObjectPath(arena, absolute_cache_root, entry.digest);
        const object_bytes = try Io.Dir.cwd().readFileAlloc(io, source_object, arena, .limited(rootfs_cas.default_chunk_size));
        const local_object = try rootfs_cas.manifestObjectPath(arena, spore_dir, entry.digest);
        try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(local_object).?);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = local_object, .data = object_bytes });
    }
    // Leave the host-private ref stale. Runtime open must prefer the complete
    // local CAS and must not consult the missing global pin.
    var remove_lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, absolute_cache_root);
    defer remove_lock.deinit();
    const remove_registry = try saved_spore_pin.LockedRegistry.init(arena, absolute_cache_root, &remove_lock);
    try saved_spore_pin.remove(io, arena, remove_registry, pin_id);
    remove_lock.deinit();
    const moved_dir = tmp ++ "/moved.spore";
    try Io.Dir.rename(Io.Dir.cwd(), spore_dir, Io.Dir.cwd(), moved_dir, io);

    var runtime = try open(context, allocator, .{
        .rootfs = rootfs,
        .disk = saved_disk,
        .spore_dir = moved_dir,
    });

    try std.testing.expect(runtime.chunk_mapped != null);
    var readback: [patch.len]u8 = undefined;
    try runtime.chunk_mapped.?.readAt(&readback, 4096 + 32);
    try std.testing.expectEqualStrings(patch, &readback);

    runtime.deinit();
    const missing = try rootfs_cas.manifestObjectPath(arena, moved_dir, local_index.value.chunks[0].digest);
    try Io.Dir.cwd().deleteFile(io, missing);
    var missing_runtime = try open(context, allocator, .{ .rootfs = rootfs, .disk = saved_disk, .spore_dir = moved_dir });
    defer missing_runtime.deinit();
    var missing_byte: [1]u8 = undefined;
    try std.testing.expectError(error.MissingChunk, missing_runtime.chunk_mapped.?.readAt(&missing_byte, local_index.value.chunks[0].logical_chunk * storage.chunk_size));
}
