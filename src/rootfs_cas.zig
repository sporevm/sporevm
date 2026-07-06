//! Chunked rootfs cache and block source.
//!
//! Runtime restore uses the manifest-bound rootfs block index selected by
//! `rootfs.storage`.

const std = @import("std");
const builtin = @import("builtin");
const chunk = @import("chunk.zig");
const rootfs_cache = @import("rootfs_cache.zig");
const rootfs_index = @import("rootfs_index.zig");
const spore = @import("spore.zig");

const Io = std.Io;
const Blake3 = std.crypto.hash.Blake3;

pub const default_chunk_size: u64 = 64 * 1024;
pub const max_index_bytes: usize = 64 * 1024 * 1024;

pub const SourceError = error{
    OutOfRange,
    ShortRead,
    MissingChunk,
    BadChunk,
    IoFailed,
    OutOfMemory,
};

pub const PreloadResult = struct {
    index_path: []const u8,
    index_digest: []const u8,
    rootfs_digest: []const u8,
    rootfs_size: u64,
    chunk_size: u64,
    chunk_count: usize,
    zero_chunks: usize,
    nonzero_chunks: usize,
    objects_written: usize,
    object_bytes_written: u64,
    index_bytes: usize,
    source_verify_ms: u64 = 0,
    chunk_scan_ms: u64 = 0,
    object_check_ms: u64 = 0,
    object_write_ms: u64 = 0,
    index_build_ms: u64 = 0,
    index_write_ms: u64 = 0,
};

pub const InstallResult = struct {
    cache_hit: bool,
    bytes_fetched: u64,
};

const LoadedIndex = struct {
    chunk_ids: []?chunk.ChunkId,
    logical_size: u64,
    chunk_size: u64,
    index_bytes: usize,

    fn deinit(self: *LoadedIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.chunk_ids);
        self.* = undefined;
    }

    fn size(self: LoadedIndex) u64 {
        return self.logical_size;
    }

    fn chunkSize(self: LoadedIndex) u64 {
        return self.chunk_size;
    }
};

/// Assemble the flat digest-addressed ext4 artifact from locally installed
/// chunk objects and publish it into the by-digest cache. Chunks are
/// BLAKE3-verified against the (digest-verified) index as they are read, the
/// assembled bytes are hashed and must equal `rootfs.artifact.digest` before
/// publication, and the publish is an atomic rename. The artifact digest and
/// the chunk index are separate authorities in the manifest; an inconsistent
/// pairing fails closed here instead of poisoning the digest cache or serving
/// different bytes depending on cache state. Rename-over publication also
/// self-heals a corrupt or truncated existing cache entry.
pub fn materializeFlatFromChunks(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    rootfs: spore.Rootfs,
) !void {
    const storage = rootfs.storage orelse return error.BadManifest;
    if (!std.mem.eql(u8, rootfs.artifact.format, spore.rootfs_artifact_format_ext4)) return error.BadManifest;
    if (!spore.rootfsDeviceEql(storage.device, rootfs.device)) return error.BadManifest;
    if (storage.logical_size != rootfs.artifact.size) return error.BadManifest;

    // Already materialized and shaped correctly: nothing to do.
    if (rootfs_cache.openTrustedFromCache(io, allocator, cache_root, rootfs)) |fd| {
        _ = std.c.close(fd);
        return;
    } else |_| {}

    const index_path = try manifestIndexPath(allocator, cache_root, storage.index_digest);
    defer allocator.free(index_path);
    var index = try loadManifestIndex(allocator, index_path, storage);
    defer index.deinit(allocator);

    const object_dir_path = try objectDir(allocator, cache_root);
    defer allocator.free(object_dir_path);

    const dest_path = try rootfs_cache.digestPath(allocator, cache_root, rootfs.artifact.digest);
    defer allocator.free(dest_path);
    const dest_dir = std.fs.path.dirname(dest_path) orelse return error.IoFailed;
    try ensureDirPath(io, dest_dir);

    var nonce_bytes: [8]u8 = undefined;
    io.random(&nonce_bytes);
    const nonce = std.mem.readInt(u64, &nonce_bytes, .little);
    const temp_path = try std.fmt.allocPrintSentinel(allocator, "{s}.{x}.assemble.tmp", .{ dest_path, nonce }, 0);
    defer allocator.free(temp_path);
    defer _ = std.c.unlink(temp_path.ptr);

    const temp_fd = std.c.open(temp_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(c_uint, 0o444));
    if (temp_fd < 0) return error.IoFailed;
    defer _ = std.c.close(temp_fd);

    const chunk_size = std.math.cast(usize, storage.chunk_size) orelse return error.BadManifest;
    const logical_len = std.math.cast(std.c.off_t, storage.logical_size) orelse return error.BadManifest;
    // Sparse output: size the file up front and write only data chunks, so
    // zero chunks stay holes on disk instead of 512MiB of zero writes.
    if (std.c.ftruncate(temp_fd, logical_len) != 0) return error.IoFailed;
    const zero_buf = try allocator.alloc(u8, chunk_size);
    defer allocator.free(zero_buf);
    @memset(zero_buf, 0);
    var hasher = Blake3.init(.{});
    for (index.chunk_ids, 0..) |maybe_id, i| {
        const len = try storageChunkLen(storage, @intCast(i));
        if (maybe_id) |id| {
            const object_path = try objectPathForDir(allocator, object_dir_path, id);
            defer allocator.free(object_path);
            const object = readFileExact(allocator, object_path, len) catch |err| switch (err) {
                error.ShortRead, error.OutOfRange, error.IoFailed => return error.MissingChunk,
                else => |e| return e,
            };
            defer allocator.free(object);
            if (!id.matches(object)) return error.BadChunk;
            hasher.update(object);
            try pwriteAll(temp_fd, object, @as(u64, @intCast(i)) * storage.chunk_size);
        } else {
            hasher.update(zero_buf[0..len]);
        }
    }

    var digest: [Blake3.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const expected_hex = rootfs.artifact.digest[spore.rootfs_digest_prefix.len..];
    if (!std.mem.eql(u8, &hex, expected_hex)) return error.RootFSDigestMismatch;

    if (std.c.fchmod(temp_fd, 0o444) != 0) return error.IoFailed;
    const dest_z = try allocator.dupeZ(u8, dest_path);
    defer allocator.free(dest_z);
    if (std.c.rename(temp_path.ptr, dest_z.ptr) != 0) return error.IoFailed;
    std.log.debug("materialized flat rootfs artifact from chunks: digest={s} size={d}", .{ rootfs.artifact.digest, rootfs.artifact.size });
}

pub fn preload(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    rootfs_digest: []const u8,
    chunk_size: u64,
) !PreloadResult {
    if (chunk_size == 0 or chunk_size % 512 != 0 or chunk_size > std.math.maxInt(usize)) return error.BadManifest;
    const digest_path = try rootfs_cache.digestPath(allocator, cache_root, rootfs_digest);
    defer allocator.free(digest_path);
    if (!try rootfs_cache.regularFileNoSymlink(io, digest_path)) return error.RootFSDigestCacheMiss;
    const stat = try Io.Dir.cwd().statFile(io, digest_path, .{ .follow_symlinks = false });
    const rootfs = spore.Rootfs{
        .device = .{ .mmio_slot = 1 },
        .artifact = .{
            .digest = rootfs_digest,
            .size = stat.size,
            .format = spore.rootfs_artifact_format_ext4,
        },
    };
    const source_verify_start_ms = monotonicMs();
    const fd = try rootfs_cache.openTrustedFromCache(io, allocator, cache_root, rootfs);
    defer _ = std.c.close(fd);

    const object_dir_path = try objectDir(allocator, cache_root);
    defer allocator.free(object_dir_path);
    try ensureDirPath(io, object_dir_path);

    const chunk_count_u64 = try chunkCount(stat.size, chunk_size);
    if (chunk_count_u64 > std.math.maxInt(usize)) return error.BadManifest;
    const chunk_count: usize = @intCast(chunk_count_u64);
    var manifest_chunks: std.ArrayList(rootfs_index.RootfsBlockChunk) = .empty;
    try manifest_chunks.ensureTotalCapacity(allocator, chunk_count);
    defer {
        for (manifest_chunks.items) |entry| allocator.free(entry.digest);
        manifest_chunks.deinit(allocator);
    }
    var manifest_zero_chunks: std.ArrayList(u64) = .empty;
    try manifest_zero_chunks.ensureTotalCapacity(allocator, chunk_count);
    defer manifest_zero_chunks.deinit(allocator);

    var zero_chunks: usize = 0;
    var nonzero_chunks: usize = 0;
    var objects_written: usize = 0;
    var object_bytes_written: u64 = 0;
    var object_check_ms: u64 = 0;
    var object_write_ms: u64 = 0;
    const MissingObject = struct {
        logical_chunk: u64,
        id: chunk.ChunkId,
    };
    var missing_objects: std.ArrayList(MissingObject) = .empty;
    defer missing_objects.deinit(allocator);
    const read_buf = try allocator.alloc(u8, @intCast(chunk_size));
    defer allocator.free(read_buf);
    const object_buf = try allocator.alloc(u8, @intCast(chunk_size));
    defer allocator.free(object_buf);
    const zero_buf = try allocator.alloc(u8, @intCast(chunk_size));
    defer allocator.free(zero_buf);
    @memset(zero_buf, 0);

    var source_hasher = Blake3.init(.{});
    var sparse_scan: SparseScanState = .{};
    const chunk_scan_start_ms = monotonicMs();
    for (0..chunk_count) |i| {
        const start = std.math.mul(u64, @as(u64, @intCast(i)), chunk_size) catch return error.BadManifest;
        const len = @min(chunk_size, stat.size - start);
        const len_usize = std.math.cast(usize, len) orelse return error.BadManifest;
        if (chunkIsSparseHole(fd, &sparse_scan, start, len, stat.size)) {
            source_hasher.update(zero_buf[0..len_usize]);
            zero_chunks += 1;
            try manifest_zero_chunks.append(allocator, @intCast(i));
            continue;
        }
        const data = read_buf[0..len_usize];
        try preadExact(fd, data, start);
        source_hasher.update(data);
        if (isZero(data)) {
            zero_chunks += 1;
            try manifest_zero_chunks.append(allocator, @intCast(i));
            continue;
        }
        const id = chunk.ChunkId.fromContents(data);
        const hex = id.toHex();
        const digest_ref = try std.fmt.allocPrint(allocator, "{s}{s}", .{ spore.rootfs_digest_prefix, hex[0..] });
        try manifest_chunks.append(allocator, .{
            .logical_chunk = @intCast(i),
            .digest = digest_ref,
        });
        const object_path = try objectPathZForDir(allocator, object_dir_path, id);
        defer allocator.free(object_path);
        const object_check_start_ms = monotonicMs();
        const object_exists = try objectEqualsDataZ(object_path, data, object_buf[0..data.len]);
        object_check_ms += monotonicMs() -| object_check_start_ms;
        if (!object_exists) {
            try missing_objects.append(allocator, .{
                .logical_chunk = @intCast(i),
                .id = id,
            });
        }
        nonzero_chunks += 1;
    }
    const chunk_scan_ms = monotonicMs() -| chunk_scan_start_ms;
    var source_digest: [Blake3.digest_length]u8 = undefined;
    source_hasher.final(&source_digest);
    const source_hex = std.fmt.bytesToHex(source_digest, .lower);
    const expected_source_hex = rootfs_digest[spore.rootfs_digest_prefix.len..];
    if (!std.mem.eql(u8, &source_hex, expected_source_hex)) return error.RootFSDigestMismatch;
    const source_verify_ms = monotonicMs() -| source_verify_start_ms;

    for (missing_objects.items) |missing| {
        const start = std.math.mul(u64, missing.logical_chunk, chunk_size) catch return error.BadManifest;
        const len = @min(chunk_size, stat.size - start);
        const len_usize = std.math.cast(usize, len) orelse return error.BadManifest;
        const data = read_buf[0..len_usize];
        try preadExact(fd, data, start);
        if (!missing.id.matches(data)) return error.BadChunk;
        const object_path = try objectPathForDir(allocator, object_dir_path, missing.id);
        defer allocator.free(object_path);
        try removeStaleObject(io, object_path);
        const object_write_start_ms = monotonicMs();
        try writeFileAtomic(io, allocator, object_path, data);
        object_write_ms += monotonicMs() -| object_write_start_ms;
        objects_written += 1;
        object_bytes_written += data.len;
    }

    const index_build_start_ms = monotonicMs();
    const manifest_index = rootfs_index.RootfsBlockIndex{
        .kind = rootfs_index.rootfs_block_index_kind,
        .logical_size = stat.size,
        .chunk_size = chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .object_namespace = spore.rootfs_storage_object_namespace,
        .chunks = manifest_chunks.items,
        .zero_chunks = manifest_zero_chunks.items,
    };
    const manifest_json = try std.json.Stringify.valueAlloc(allocator, manifest_index, .{ .whitespace = .indent_2 });
    defer allocator.free(manifest_json);
    const index_digest = try rootfs_index.indexDigestAlloc(allocator, manifest_json);
    const index_build_ms = monotonicMs() -| index_build_start_ms;
    errdefer allocator.free(index_digest);
    const manifest_path = try manifestIndexPath(allocator, cache_root, index_digest);
    errdefer allocator.free(manifest_path);
    const manifest_dir = std.fs.path.dirname(manifest_path) orelse return error.BadManifest;
    try ensureDirPath(io, manifest_dir);
    const index_write_start_ms = monotonicMs();
    try writeFileAtomic(io, allocator, manifest_path, manifest_json);
    const index_write_ms = monotonicMs() -| index_write_start_ms;
    return .{
        .index_path = manifest_path,
        .index_digest = index_digest,
        .rootfs_digest = rootfs_digest,
        .rootfs_size = stat.size,
        .chunk_size = chunk_size,
        .chunk_count = chunk_count,
        .zero_chunks = zero_chunks,
        .nonzero_chunks = nonzero_chunks,
        .objects_written = objects_written,
        .object_bytes_written = object_bytes_written,
        .index_bytes = manifest_json.len,
        .source_verify_ms = source_verify_ms,
        .chunk_scan_ms = chunk_scan_ms,
        .object_check_ms = object_check_ms,
        .object_write_ms = object_write_ms,
        .index_build_ms = index_build_ms,
        .index_write_ms = index_write_ms,
    };
}

pub fn storageComplete(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    storage: spore.RootfsStorage,
) !bool {
    const index_path = try manifestIndexPath(allocator, cache_root, storage.index_digest);
    defer allocator.free(index_path);
    if (!try rootfs_cache.regularFileNoSymlink(io, index_path)) return false;

    const bytes = readFileAll(allocator, index_path, rootfs_index.max_index_bytes) catch |err| switch (err) {
        error.MissingChunk, error.BadChunk, error.ShortRead => return false,
        else => |e| return e,
    };
    defer allocator.free(bytes);
    var parsed = rootfs_index.parseRootfsBlockIndex(allocator, bytes, storage) catch |err| switch (err) {
        error.BadManifest => return false,
        else => |e| return e,
    };
    defer parsed.deinit();

    for (parsed.value.chunks) |entry| {
        const path = try manifestObjectPath(allocator, cache_root, entry.digest);
        defer allocator.free(path);
        if (!try rootfs_cache.regularFileNoSymlink(io, path)) return false;
        const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return false,
            else => |e| return e,
        };
        const expected_size = try storageChunkLen(storage, entry.logical_chunk);
        if (stat.size != @as(u64, @intCast(expected_size))) return false;
    }
    return true;
}

pub fn readVerifiedStorageIndexPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    storage: spore.RootfsStorage,
) ![]u8 {
    const bytes = try readFileAll(allocator, path, rootfs_index.max_index_bytes);
    errdefer allocator.free(bytes);
    var parsed = try rootfs_index.parseRootfsBlockIndex(allocator, bytes, storage);
    parsed.deinit();
    return bytes;
}

pub fn readVerifiedChunkPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    digest: []const u8,
    expected_size: usize,
) ![]u8 {
    const data = try readFileExact(allocator, path, expected_size);
    errdefer allocator.free(data);
    try verifyDigestBytes(digest, data);
    return data;
}

pub fn installStorageIndexPath(
    allocator: std.mem.Allocator,
    io: Io,
    cache_path: []const u8,
    data: []const u8,
    storage: spore.RootfsStorage,
) !InstallResult {
    const cache_parent = std.fs.path.dirname(cache_path) orelse return error.IoFailed;
    try ensureDirPath(io, cache_parent);
    if (try pathExistsNoSymlink(io, cache_path)) {
        const existing = try readVerifiedStorageIndexPath(allocator, cache_path, storage);
        allocator.free(existing);
        return .{ .cache_hit = true, .bytes_fetched = 0 };
    }
    var parsed = try rootfs_index.parseRootfsBlockIndex(allocator, data, storage);
    parsed.deinit();
    try writeFileAtomic(io, allocator, cache_path, data);
    const installed = try readVerifiedStorageIndexPath(allocator, cache_path, storage);
    defer allocator.free(installed);
    return .{ .cache_hit = false, .bytes_fetched = @intCast(data.len) };
}

pub fn installChunkPath(
    allocator: std.mem.Allocator,
    io: Io,
    cache_path: []const u8,
    data: []const u8,
    digest: []const u8,
    expected_size: usize,
) !InstallResult {
    const cache_parent = std.fs.path.dirname(cache_path) orelse return error.IoFailed;
    try ensureDirPath(io, cache_parent);
    if (try pathExistsNoSymlink(io, cache_path)) {
        const existing = try readVerifiedChunkPath(allocator, cache_path, digest, expected_size);
        allocator.free(existing);
        return .{ .cache_hit = true, .bytes_fetched = 0 };
    }
    if (data.len != expected_size) return error.BadChunk;
    try verifyDigestBytes(digest, data);
    try writeFileAtomic(io, allocator, cache_path, data);
    const installed = try readVerifiedChunkPath(allocator, cache_path, digest, expected_size);
    defer allocator.free(installed);
    return .{ .cache_hit = false, .bytes_fetched = @intCast(data.len) };
}

pub fn manifestIndexPath(allocator: std.mem.Allocator, cache_root: []const u8, index_digest: []const u8) ![]const u8 {
    const hex = try rootfsDigestHex(index_digest);
    return std.fmt.allocPrint(allocator, "{s}/cas/rootfs/blake3/indexes/{s}.json", .{ cache_root, hex });
}

pub fn manifestObjectPath(allocator: std.mem.Allocator, cache_root: []const u8, object_digest: []const u8) ![]const u8 {
    const hex = try rootfsDigestHex(object_digest);
    const id = chunk.ChunkId.fromHex(hex) catch return error.BadManifest;
    const dir = try objectDir(allocator, cache_root);
    defer allocator.free(dir);
    return objectPathForDir(allocator, dir, id);
}

pub fn storageDescriptor(device: spore.RootfsDevice, result: PreloadResult) spore.RootfsStorage {
    return .{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = device,
        .logical_size = result.rootfs_size,
        .chunk_size = result.chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .index_digest = result.index_digest,
        .base_identity = result.index_digest,
        .object_namespace = spore.rootfs_storage_object_namespace,
    };
}

fn objectDir(allocator: std.mem.Allocator, cache_root: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/cas/rootfs/blake3/objects", .{cache_root});
}

fn objectPathForDir(allocator: std.mem.Allocator, dir: []const u8, id: chunk.ChunkId) ![]const u8 {
    const hex = id.toHex();
    return std.fmt.allocPrint(allocator, "{s}/{s}.chunk", .{ dir, &hex });
}

fn objectPathZForDir(allocator: std.mem.Allocator, dir: []const u8, id: chunk.ChunkId) ![:0]const u8 {
    const hex = id.toHex();
    return std.fmt.allocPrintSentinel(allocator, "{s}/{s}.chunk", .{ dir, &hex }, 0);
}

fn loadManifestIndex(
    allocator: std.mem.Allocator,
    path: []const u8,
    storage: spore.RootfsStorage,
) !LoadedIndex {
    const bytes = try readFileAll(allocator, path, max_index_bytes);
    defer allocator.free(bytes);
    var parsed = try rootfs_index.parseRootfsBlockIndex(allocator, bytes, storage);
    errdefer parsed.deinit();
    const expected_chunks = try chunkCount(storage.logical_size, storage.chunk_size);
    if (expected_chunks > std.math.maxInt(usize)) return error.BadManifest;
    var ids = try allocator.alloc(?chunk.ChunkId, @intCast(expected_chunks));
    errdefer allocator.free(ids);
    @memset(ids, null);
    for (parsed.value.chunks) |entry| {
        const hex = try spore.diskDigestHex(entry.digest);
        const logical_chunk: usize = @intCast(entry.logical_chunk);
        ids[logical_chunk] = chunk.ChunkId.fromHex(hex) catch return error.BadManifest;
    }
    parsed.deinit();
    return .{
        .chunk_ids = ids,
        .logical_size = storage.logical_size,
        .chunk_size = storage.chunk_size,
        .index_bytes = bytes.len,
    };
}

fn rootfsDigestHex(digest: []const u8) ![]const u8 {
    try spore.validateRootfsDigest(digest);
    return digest[spore.rootfs_digest_prefix.len..];
}

fn chunkCount(size: u64, chunk_size: u64) !u64 {
    if (chunk_size == 0) return error.BadManifest;
    if (size == 0) return 0;
    return (try std.math.add(u64, size, chunk_size - 1)) / chunk_size;
}

pub fn storageChunkLen(storage: spore.RootfsStorage, logical_chunk: u64) !usize {
    const start = std.math.mul(u64, logical_chunk, storage.chunk_size) catch return error.BadManifest;
    if (start >= storage.logical_size) return error.BadManifest;
    const len = @min(storage.chunk_size, storage.logical_size - start);
    return std.math.cast(usize, len) orelse error.BadManifest;
}

fn isZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

const SparseScanState = struct {
    supported: bool = sparseSeekSupported(),
    have_extent: bool = false,
    data_start: u64 = 0,
    data_end: u64 = 0,
};

fn sparseSeekSupported() bool {
    return switch (builtin.os.tag) {
        .linux, .macos => true,
        else => false,
    };
}

fn chunkIsSparseHole(fd: std.c.fd_t, state: *SparseScanState, start: u64, len: u64, file_size: u64) bool {
    if (!state.supported) return false;
    if (len == 0) return true;
    const chunk_end = std.math.add(u64, start, len) catch return false;
    if (!state.have_extent or start >= state.data_end) {
        const extent = nextSparseDataExtent(fd, start, file_size) orelse {
            state.supported = false;
            return false;
        };
        state.have_extent = true;
        state.data_start = extent.start;
        state.data_end = extent.end;
    }
    return chunk_end <= state.data_start;
}

const SparseDataExtent = struct {
    start: u64,
    end: u64,
};

fn nextSparseDataExtent(fd: std.c.fd_t, start: u64, file_size: u64) ?SparseDataExtent {
    if (!sparseSeekSupported()) return null;
    const seek_data: c_int = if (builtin.os.tag == .macos) 4 else 3;
    const seek_hole: c_int = if (builtin.os.tag == .macos) 3 else 4;
    const offset = std.math.cast(std.c.off_t, start) orelse return null;
    const data_start = std.c.lseek(fd, offset, seek_data);
    if (data_start < 0) return null;
    var data_end = std.c.lseek(fd, data_start, seek_hole);
    if (data_end < 0) data_end = std.math.cast(std.c.off_t, file_size) orelse return null;
    if (data_end <= data_start) return null;
    return .{
        .start = @intCast(data_start),
        .end = @intCast(data_end),
    };
}

fn preadExact(fd: std.c.fd_t, buf: []u8, offset: u64) SourceError!void {
    var done: usize = 0;
    while (done < buf.len) {
        const absolute = std.math.add(u64, offset, done) catch return error.OutOfRange;
        const file_offset = std.math.cast(std.c.off_t, absolute) orelse return error.OutOfRange;
        const n = std.c.pread(fd, buf.ptr + done, buf.len - done, file_offset);
        if (n <= 0) return error.ShortRead;
        done += @intCast(n);
    }
}

fn readFileExact(allocator: std.mem.Allocator, path: []const u8, expected_size: usize) SourceError![]u8 {
    const data = try readFileAll(allocator, path, expected_size);
    errdefer allocator.free(data);
    if (data.len != expected_size) return error.BadChunk;
    return data;
}

fn readFileAll(allocator: std.mem.Allocator, path: []const u8, max: usize) SourceError![]u8 {
    const pathz = try allocator.dupeZ(u8, path);
    defer allocator.free(pathz);
    const fd = std.c.open(pathz, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.MissingChunk;
    defer _ = std.c.close(fd);
    const size = try fstatRegularSize(fd);
    if (size > max) return error.BadChunk;
    const data = try allocator.alloc(u8, size);
    errdefer allocator.free(data);
    try preadExact(fd, data, 0);
    return data;
}

fn fstatRegularSize(fd: std.c.fd_t) SourceError!usize {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var statx_buf: linux.Statx = undefined;
        const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{
            .TYPE = true,
            .MODE = true,
            .SIZE = true,
        }, &statx_buf);
        if (linux.errno(rc) != .SUCCESS) return error.IoFailed;
        if (!linux.S.ISREG(statx_buf.mode)) return error.MissingChunk;
        return std.math.cast(usize, statx_buf.size) orelse error.IoFailed;
    } else {
        var stat: std.c.Stat = undefined;
        if (std.c.fstat(fd, &stat) != 0) return error.IoFailed;
        if (!std.c.S.ISREG(stat.mode)) return error.MissingChunk;
        if (stat.size < 0) return error.IoFailed;
        return std.math.cast(usize, stat.size) orelse error.IoFailed;
    }
}

fn pathExistsNoSymlink(io: Io, path: []const u8) !bool {
    _ = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return false,
        else => |e| return e,
    };
    return true;
}

fn objectEqualsDataZ(path: [:0]const u8, expected: []const u8, buf: []u8) !bool {
    if (buf.len != expected.len) return error.IoFailed;
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    const size = fstatRegularSize(fd) catch |err| switch (err) {
        error.MissingChunk, error.BadChunk, error.ShortRead => return false,
        else => |e| return e,
    };
    if (size != expected.len) return false;
    preadExact(fd, buf, 0) catch |err| switch (err) {
        error.ShortRead, error.OutOfRange, error.IoFailed => return false,
        else => |e| return e,
    };
    return std.mem.eql(u8, expected, buf);
}

fn verifyDigestBytes(digest: []const u8, data: []const u8) !void {
    const hex = try rootfsDigestHex(digest);
    const id = chunk.ChunkId.fromHex(hex) catch return error.BadManifest;
    if (!id.matches(data)) return error.BadChunk;
}

fn removeStaleObject(io: Io, path: []const u8) !void {
    Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
}

fn writeFileAtomic(io: Io, allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    var temp_nonce_bytes: [8]u8 = undefined;
    io.random(&temp_nonce_bytes);
    const temp_nonce = std.mem.readInt(u64, &temp_nonce_bytes, .little);
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.{x}.tmp", .{ path, temp_nonce });
    defer allocator.free(temp_path);
    defer Io.Dir.cwd().deleteFile(io, temp_path) catch {};
    const temp_z = try allocator.dupeZ(u8, temp_path);
    defer allocator.free(temp_z);
    const fd = std.c.open(temp_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(c_uint, 0o444));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);
    try writeAll(fd, data);
    if (std.c.fchmod(fd, 0o444) != 0) return error.IoFailed;
    if (!Io.Dir.path.isAbsolute(path)) {
        try Io.Dir.rename(Io.Dir.cwd(), temp_path, Io.Dir.cwd(), path, io);
    } else {
        try Io.Dir.renameAbsolute(temp_path, path, io);
    }
}

fn ensureDirPath(io: Io, path: []const u8) !void {
    if (!Io.Dir.path.isAbsolute(path)) {
        try Io.Dir.cwd().createDirPath(io, path);
        return;
    }
    var existing = Io.Dir.openDirAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (std.fs.path.dirname(path)) |parent| {
                if (parent.len > 0 and !std.mem.eql(u8, parent, path)) try ensureDirPath(io, parent);
            }
            Io.Dir.createDirAbsolute(io, path, .default_dir) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => {},
                else => |e| return e,
            };
            return;
        },
        else => |e| return e,
    };
    existing.close(io);
}

fn pwriteAll(fd: std.c.fd_t, bytes: []const u8, offset: u64) SourceError!void {
    var done: usize = 0;
    while (done < bytes.len) {
        const absolute = std.math.add(u64, offset, done) catch return error.OutOfRange;
        const file_offset = std.math.cast(std.c.off_t, absolute) orelse return error.OutOfRange;
        const n = std.c.pwrite(fd, bytes.ptr + done, bytes.len - done, file_offset);
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
}

fn writeAll(fd: std.c.fd_t, bytes: []const u8) SourceError!void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(fd, remaining.ptr, remaining.len);
        if (n <= 0) return error.IoFailed;
        remaining = remaining[@intCast(n)..];
    }
}

fn monotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}
test "materialize assembles the flat artifact from verified chunks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-cas-materialize";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    const bytes = "abcd" ++ ("\x00" ** 4096) ++ "efgh";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = bytes });
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const preload_result = try preload(io, arena, cache_root, artifact.digest, 4096);
    const rootfs = spore.Rootfs{
        .device = .{ .mmio_slot = 1 },
        .artifact = artifact,
        .storage = storageDescriptor(.{ .mmio_slot = 1 }, preload_result),
    };

    // Remove the flat entry so materialize actually assembles from chunks.
    const digest_path = try rootfs_cache.digestPath(arena, cache_root, artifact.digest);
    try Io.Dir.cwd().deleteFile(io, digest_path);

    try materializeFlatFromChunks(io, allocator, cache_root, rootfs);
    const assembled = try Io.Dir.cwd().readFileAlloc(io, digest_path, arena, .limited(1 << 20));
    try std.testing.expectEqualSlices(u8, bytes, assembled);
    const stat = try Io.Dir.cwd().statFile(io, digest_path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o444), @as(u32, @intCast(@intFromEnum(stat.permissions) & 0o777)));

    // Idempotent: a second call with a valid entry present is a no-op.
    try materializeFlatFromChunks(io, allocator, cache_root, rootfs);
}

test "materialize reproduces exact bytes across chunk boundaries and zero chunks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-cas-materialize-model";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);

    var model: [3 * 512 + 73]u8 = undefined;
    for (model[0..512], 0..) |*byte, i| byte.* = @truncate((i * 17) + 3);
    @memset(model[512..1024], 0);
    for (model[1024..], 0..) |*byte, i| byte.* = @truncate((i * 29) + 11);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = &model });

    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const preload_result = try preload(io, arena, cache_root, artifact.digest, 512);
    const rootfs = spore.Rootfs{
        .device = .{ .mmio_slot = 1 },
        .artifact = artifact,
        .storage = storageDescriptor(.{ .mmio_slot = 1 }, preload_result),
    };
    const digest_path = try rootfs_cache.digestPath(arena, cache_root, artifact.digest);
    try Io.Dir.cwd().deleteFile(io, digest_path);

    try materializeFlatFromChunks(io, allocator, cache_root, rootfs);
    const assembled = try Io.Dir.cwd().readFileAlloc(io, digest_path, arena, .limited(1 << 20));
    try std.testing.expectEqualSlices(u8, &model, assembled);
}

test "materialize fails closed on corrupt chunk objects without publishing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-cas-materialize-corrupt";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "abcd" });
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const preload_result = try preload(io, arena, cache_root, artifact.digest, 4096);
    const rootfs = spore.Rootfs{
        .device = .{ .mmio_slot = 1 },
        .artifact = artifact,
        .storage = storageDescriptor(.{ .mmio_slot = 1 }, preload_result),
    };
    const digest_path = try rootfs_cache.digestPath(arena, cache_root, artifact.digest);
    try Io.Dir.cwd().deleteFile(io, digest_path);

    const id = chunk.ChunkId.fromContents("abcd");
    const object_dir_path = try objectDir(arena, cache_root);
    const object_path = try objectPathForDir(arena, object_dir_path, id);
    try Io.Dir.cwd().deleteFile(io, object_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = object_path, .data = "wxyz" });

    try std.testing.expectError(error.BadChunk, materializeFlatFromChunks(io, allocator, cache_root, rootfs));
    try std.testing.expect(!try rootfs_cache.pathExistsNoSymlink(io, digest_path));
}

test "materialize fails closed when assembled bytes mismatch the artifact digest" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-cas-materialize-mismatch";
    const a_path = tmp ++ "/a.ext4";
    const b_path = tmp ++ "/b.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = a_path, .data = "aaaa" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = b_path, .data = "bbbb" });

    const a_artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, a_path);
    const b_artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, b_path);
    const a_preload = try preload(io, arena, cache_root, a_artifact.digest, 4096);

    // Manifest pairing B's artifact digest with A's chunk index: the artifact
    // digest and the chunk index are separate authorities, and an
    // inconsistent pairing must fail instead of publishing A-bytes under B's
    // name or silently serving different bytes depending on cache state.
    const inconsistent = spore.Rootfs{
        .device = .{ .mmio_slot = 1 },
        .artifact = b_artifact,
        .storage = storageDescriptor(.{ .mmio_slot = 1 }, a_preload),
    };
    const b_digest_path = try rootfs_cache.digestPath(arena, cache_root, b_artifact.digest);
    try Io.Dir.cwd().deleteFile(io, b_digest_path);

    try std.testing.expectError(error.RootFSDigestMismatch, materializeFlatFromChunks(io, allocator, cache_root, inconsistent));
    try std.testing.expect(!try rootfs_cache.pathExistsNoSymlink(io, b_digest_path));
}

test "preload repairs corrupt existing chunk objects" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-cas-repair";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "abcd" });
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    _ = try preload(io, arena, cache_root, artifact.digest, 4096);

    const id = chunk.ChunkId.fromContents("abcd");
    const object_dir_path = try objectDir(arena, cache_root);
    const object_path = try objectPathForDir(arena, object_dir_path, id);
    try Io.Dir.cwd().deleteFile(io, object_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = object_path, .data = "wxyz" });

    const repaired = try preload(io, arena, cache_root, artifact.digest, 4096);
    try std.testing.expectEqual(@as(usize, 1), repaired.objects_written);

    const rootfs = spore.Rootfs{
        .device = .{ .mmio_slot = 1 },
        .artifact = artifact,
        .storage = storageDescriptor(.{ .mmio_slot = 1 }, repaired),
    };
    const digest_path = try rootfs_cache.digestPath(arena, cache_root, artifact.digest);
    try Io.Dir.cwd().deleteFile(io, digest_path);
    try materializeFlatFromChunks(io, allocator, cache_root, rootfs);
    const assembled = try Io.Dir.cwd().readFileAlloc(io, digest_path, arena, .limited(4096));
    try std.testing.expectEqualStrings("abcd", assembled);
}
