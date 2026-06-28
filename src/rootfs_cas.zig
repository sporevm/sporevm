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

pub const Stats = struct {
    chunk_accesses: u64 = 0,
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
    object_opens: u64 = 0,
    bytes_hashed: u64 = 0,
    zero_fills: u64 = 0,
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

pub const CasBlockSource = struct {
    allocator: std.mem.Allocator,
    index: LoadedIndex,
    object_dir: []const u8,
    verified: []?[]u8,
    trace_path: ?[:0]const u8 = null,
    stats: Stats = .{},

    pub fn openManifest(
        allocator: std.mem.Allocator,
        cache_root: []const u8,
        rootfs: spore.Rootfs,
        trace_path: ?[:0]const u8,
    ) !CasBlockSource {
        const storage = rootfs.storage orelse return error.BadManifest;
        if (!std.mem.eql(u8, rootfs.artifact.format, spore.rootfs_artifact_format_ext4)) return error.BadManifest;
        if (!spore.rootfsDeviceEql(storage.device, rootfs.device)) return error.BadManifest;
        if (storage.logical_size != rootfs.artifact.size) return error.BadManifest;
        const path = try manifestIndexPath(allocator, cache_root, storage.index_digest);
        defer allocator.free(path);
        const start_ms = monotonicMs();
        const index = try loadManifestIndex(allocator, path, storage);
        if (trace_path) |trace| appendIndexOpenTrace(trace, storage, index, monotonicMs() -| start_ms);
        errdefer {
            var mutable_index = index;
            mutable_index.deinit(allocator);
        }
        const object_dir = try objectDir(allocator, cache_root);
        errdefer allocator.free(object_dir);
        const verified = try allocator.alloc(?[]u8, index.chunk_ids.len);
        @memset(verified, null);
        return .{
            .allocator = allocator,
            .index = index,
            .object_dir = object_dir,
            .verified = verified,
            .trace_path = trace_path,
        };
    }

    pub fn deinit(self: *CasBlockSource) void {
        self.appendStatsTrace();
        for (self.verified) |maybe_data| {
            if (maybe_data) |data| self.allocator.free(data);
        }
        self.allocator.free(self.verified);
        self.allocator.free(self.object_dir);
        self.index.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn capacityBytes(self: CasBlockSource) u64 {
        return self.index.size();
    }

    pub fn readAt(self: *CasBlockSource, buf: []u8, offset: u64) SourceError!void {
        const end = std.math.add(u64, offset, buf.len) catch return error.OutOfRange;
        if (end > self.index.size()) return error.OutOfRange;

        const start_ms = monotonicMs();
        var cursor: usize = 0;
        while (cursor < buf.len) {
            const absolute = offset + cursor;
            const chunk_index_u64 = absolute / self.index.chunkSize();
            if (chunk_index_u64 > std.math.maxInt(usize)) return error.OutOfRange;
            const chunk_index: usize = @intCast(chunk_index_u64);
            const chunk_offset = absolute % self.index.chunkSize();
            const chunk_len = try self.chunkLen(chunk_index);
            const span_len = @min(buf.len - cursor, chunk_len - @as(usize, @intCast(chunk_offset)));
            const target = buf[cursor..][0..span_len];
            self.stats.chunk_accesses += 1;
            if (self.index.chunk_ids[chunk_index]) |_| {
                const data = try self.verifiedChunk(chunk_index);
                @memcpy(target, data[@intCast(chunk_offset)..][0..span_len]);
            } else {
                @memset(target, 0);
                self.stats.zero_fills += 1;
            }
            cursor += span_len;
        }
        if (self.trace_path) |path| {
            appendTraceRead(path, offset, buf.len, monotonicMs() -| start_ms);
        }
    }

    fn verifiedChunk(self: *CasBlockSource, chunk_index: usize) SourceError![]const u8 {
        if (self.verified[chunk_index]) |data| {
            self.stats.cache_hits += 1;
            return data;
        }
        const id = self.index.chunk_ids[chunk_index] orelse return error.MissingChunk;
        const len = try self.chunkLen(chunk_index);
        const path = try objectPathForDir(self.allocator, self.object_dir, id);
        defer self.allocator.free(path);
        self.stats.cache_misses += 1;
        self.stats.object_opens += 1;
        const data = try readFileExact(self.allocator, path, len);
        errdefer self.allocator.free(data);
        self.stats.bytes_hashed += data.len;
        if (!id.matches(data)) return error.BadChunk;
        self.verified[chunk_index] = data;
        return data;
    }

    fn chunkLen(self: CasBlockSource, chunk_index: usize) SourceError!usize {
        const start = std.math.mul(u64, @as(u64, @intCast(chunk_index)), self.index.chunkSize()) catch return error.OutOfRange;
        const len = @min(self.index.chunkSize(), self.index.size() - start);
        return std.math.cast(usize, len) orelse error.OutOfRange;
    }

    fn appendStatsTrace(self: CasBlockSource) void {
        const trace_path = self.trace_path orelse return;
        const fd = std.c.open(trace_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c_uint, 0o644));
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        var line_buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(
            &line_buf,
            "{{\"event\":\"rootfs_cas_stats\",\"chunk_size\":{d},\"chunk_accesses\":{d},\"cache_hits\":{d},\"cache_misses\":{d},\"object_opens\":{d},\"bytes_hashed\":{d},\"zero_fills\":{d}}}\n",
            .{
                self.index.chunkSize(),
                self.stats.chunk_accesses,
                self.stats.cache_hits,
                self.stats.cache_misses,
                self.stats.object_opens,
                self.stats.bytes_hashed,
                self.stats.zero_fills,
            },
        ) catch return;
        writeAll(fd, line) catch {};
    }
};

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
    const fd = try rootfs_cache.openVerifiedFromCache(io, allocator, cache_root, rootfs);
    const source_verify_ms = monotonicMs() -| source_verify_start_ms;
    defer _ = std.c.close(fd);

    const object_dir_path = try objectDir(allocator, cache_root);
    defer allocator.free(object_dir_path);
    try ensureDirPath(io, object_dir_path);

    const chunk_count_u64 = try chunkCount(stat.size, chunk_size);
    if (chunk_count_u64 > std.math.maxInt(usize)) return error.BadManifest;
    const chunk_count: usize = @intCast(chunk_count_u64);
    var manifest_chunks: std.ArrayList(rootfs_index.RootfsBlockChunk) = .empty;
    defer {
        for (manifest_chunks.items) |entry| allocator.free(entry.digest);
        manifest_chunks.deinit(allocator);
    }
    var manifest_zero_chunks: std.ArrayList(u64) = .empty;
    defer manifest_zero_chunks.deinit(allocator);

    var zero_chunks: usize = 0;
    var nonzero_chunks: usize = 0;
    var objects_written: usize = 0;
    var object_bytes_written: u64 = 0;
    var object_check_ms: u64 = 0;
    var object_write_ms: u64 = 0;
    const read_buf = try allocator.alloc(u8, @intCast(chunk_size));
    defer allocator.free(read_buf);

    const chunk_scan_start_ms = monotonicMs();
    for (0..chunk_count) |i| {
        const start = std.math.mul(u64, @as(u64, @intCast(i)), chunk_size) catch return error.BadManifest;
        const len = @min(chunk_size, stat.size - start);
        const len_usize = std.math.cast(usize, len) orelse return error.BadManifest;
        const data = read_buf[0..len_usize];
        try preadExact(fd, data, start);
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
        const object_path = try objectPathForDir(allocator, object_dir_path, id);
        defer allocator.free(object_path);
        const object_check_start_ms = monotonicMs();
        const object_exists = try objectMatches(allocator, object_path, id, data.len);
        object_check_ms += monotonicMs() -| object_check_start_ms;
        if (!object_exists) {
            try removeStaleObject(io, object_path);
            const object_write_start_ms = monotonicMs();
            try writeFileAtomic(io, allocator, object_path, data);
            object_write_ms += monotonicMs() -| object_write_start_ms;
            objects_written += 1;
            object_bytes_written += data.len;
        }
        nonzero_chunks += 1;
    }
    const chunk_scan_ms = monotonicMs() -| chunk_scan_start_ms;

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

fn objectMatches(allocator: std.mem.Allocator, path: []const u8, id: chunk.ChunkId, expected_size: usize) !bool {
    const data = readFileExact(allocator, path, expected_size) catch |err| switch (err) {
        error.MissingChunk, error.BadChunk, error.ShortRead => return false,
        else => |e| return e,
    };
    defer allocator.free(data);
    return id.matches(data);
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

fn appendTraceRead(path: [:0]const u8, offset: u64, len: usize, elapsed_ms: u64) void {
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c_uint, 0o644));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    var line_buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(
        &line_buf,
        "{{\"event\":\"block_source_read\",\"source\":\"cas\",\"offset\":{d},\"len\":{d},\"elapsed_ms\":{d}}}\n",
        .{ offset, len, elapsed_ms },
    ) catch return;
    writeAll(fd, line) catch {};
}

fn appendIndexOpenTrace(
    path: [:0]const u8,
    storage: spore.RootfsStorage,
    index: LoadedIndex,
    elapsed_ms: u64,
) void {
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c_uint, 0o644));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    var line_buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(
        &line_buf,
        "{{\"event\":\"rootfs_cas_index_open\",\"index_digest\":\"{s}\",\"logical_size\":{d},\"chunk_size\":{d},\"chunk_count\":{d},\"index_bytes\":{d},\"elapsed_ms\":{d}}}\n",
        .{ storage.index_digest, index.logical_size, index.chunkSize(), index.chunk_ids.len, index.index_bytes, elapsed_ms },
    ) catch return;
    writeAll(fd, line) catch {};
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

test "preload builds an index and cached source verifies chunks once" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-cas-source";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    const bytes = "abcd" ++ ("\x00" ** 4096) ++ "efgh";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = bytes });
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const preload_result = try preload(io, arena, cache_root, artifact.digest, 4096);
    try std.testing.expect(std.mem.startsWith(u8, preload_result.index_digest, spore.rootfs_digest_prefix));

    const trace_path = tmp ++ "/cas-trace.jsonl";
    const trace_path_z = try arena.dupeZ(u8, trace_path);
    var source = try CasBlockSource.openManifest(allocator, cache_root, .{
        .device = .{ .mmio_slot = 1 },
        .artifact = artifact,
        .storage = storageDescriptor(.{ .mmio_slot = 1 }, preload_result),
    }, trace_path_z);
    defer source.deinit();

    var readback: [4]u8 = undefined;
    try source.readAt(&readback, 0);
    try source.readAt(&readback, 0);
    try std.testing.expectEqualStrings("abcd", &readback);
    try std.testing.expectEqual(@as(u64, 2), source.stats.chunk_accesses);
    try std.testing.expectEqual(@as(u64, 1), source.stats.cache_misses);
    try std.testing.expectEqual(@as(u64, 1), source.stats.cache_hits);

    try source.readAt(&readback, 4100);
    try std.testing.expectEqualStrings("efgh", &readback);

    const trace_bytes = try Io.Dir.cwd().readFileAlloc(io, trace_path, arena, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, trace_bytes, "\"event\":\"rootfs_cas_index_open\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace_bytes, "\"index_digest\":\"") != null);
}

test "cas source reads match byte model across chunk boundaries" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-cas-model";
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
    var source = try CasBlockSource.openManifest(allocator, cache_root, .{
        .device = .{ .mmio_slot = 1 },
        .artifact = artifact,
        .storage = storageDescriptor(.{ .mmio_slot = 1 }, preload_result),
    }, null);
    defer source.deinit();

    const read_lengths = [_]usize{ 0, 1, 17, 511, 512, 513, 900 };
    var readback: [900]u8 = undefined;
    var offset: usize = 0;
    while (offset < model.len) : (offset += 137) {
        for (read_lengths) |len| {
            if (offset + len > model.len) continue;
            try source.readAt(readback[0..len], offset);
            try std.testing.expectEqualSlices(u8, model[offset..][0..len], readback[0..len]);
        }
    }
}

test "cas source rejects corrupt chunk objects" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-cas-corrupt";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "abcd" });
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const preload_result = try preload(io, arena, cache_root, artifact.digest, 4096);

    var source = try CasBlockSource.openManifest(allocator, cache_root, .{
        .device = .{ .mmio_slot = 1 },
        .artifact = artifact,
        .storage = storageDescriptor(.{ .mmio_slot = 1 }, preload_result),
    }, null);
    defer source.deinit();

    const id = chunk.ChunkId.fromContents("abcd");
    const object_dir_path = try objectDir(arena, cache_root);
    const object_path = try objectPathForDir(arena, object_dir_path, id);
    try Io.Dir.cwd().deleteFile(io, object_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = object_path, .data = "wxyz" });

    var readback: [4]u8 = undefined;
    try std.testing.expectError(error.BadChunk, source.readAt(&readback, 0));
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

    var source = try CasBlockSource.openManifest(allocator, cache_root, .{
        .device = .{ .mmio_slot = 1 },
        .artifact = artifact,
        .storage = storageDescriptor(.{ .mmio_slot = 1 }, repaired),
    }, null);
    defer source.deinit();

    var readback: [4]u8 = undefined;
    try source.readAt(&readback, 0);
    try std.testing.expectEqualStrings("abcd", &readback);
}
