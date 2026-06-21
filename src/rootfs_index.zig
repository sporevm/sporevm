//! Manifest-bound chunked rootfs index parsing.
//!
//! This is the portable restore-authority parser for chunked immutable rootfs
//! storage. The local `rootfs_cas` spike intentionally remains separate until a
//! later slice attaches this descriptor/index pair to product resume.

const std = @import("std");
const chunk = @import("chunk.zig");
const spore = @import("spore.zig");

pub const rootfs_block_index_kind = "rootfs-block-index-v0";
pub const max_index_bytes: usize = 64 * 1024 * 1024;

pub const RootfsBlockChunk = struct {
    logical_chunk: u64,
    digest: []const u8,
};

pub const RootfsBlockIndex = struct {
    kind: []const u8,
    logical_size: u64,
    chunk_size: u64,
    hash_algorithm: []const u8,
    object_namespace: []const u8,
    chunks: []const RootfsBlockChunk = &.{},
    zero_chunks: []const u64 = &.{},
};

pub fn parseRootfsBlockIndex(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    storage: spore.RootfsStorage,
) spore.Error!std.json.Parsed(RootfsBlockIndex) {
    if (bytes.len == 0 or bytes.len > max_index_bytes) return error.BadManifest;
    try spore.validateRootfsStorageDescriptor(storage);
    try validateIndexDigest(bytes, storage.index_digest);
    const parsed = std.json.parseFromSlice(RootfsBlockIndex, allocator, bytes, .{
        .allocate = .alloc_always,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadManifest,
    };
    errdefer parsed.deinit();
    try validateRootfsBlockIndex(parsed.value, storage);
    return parsed;
}

fn validateRootfsBlockIndex(index: RootfsBlockIndex, storage: spore.RootfsStorage) spore.Error!void {
    try spore.validateRootfsStorageDescriptor(storage);
    if (!std.mem.eql(u8, index.kind, rootfs_block_index_kind)) return error.BadManifest;
    if (index.logical_size != storage.logical_size) return error.BadManifest;
    if (index.chunk_size != storage.chunk_size) return error.BadManifest;
    if (!std.mem.eql(u8, index.hash_algorithm, storage.hash_algorithm)) return error.BadManifest;
    if (!std.mem.eql(u8, index.object_namespace, storage.object_namespace)) return error.BadManifest;

    const chunk_count = try spore.diskClusterCount(index.logical_size, index.chunk_size);
    const covered_chunks = std.math.add(
        u64,
        @as(u64, @intCast(index.chunks.len)),
        @as(u64, @intCast(index.zero_chunks.len)),
    ) catch return error.BadManifest;
    if (covered_chunks != chunk_count) return error.BadManifest;

    var previous_chunk: ?u64 = null;
    for (index.chunks) |entry| {
        if (entry.logical_chunk >= chunk_count) return error.BadManifest;
        if (previous_chunk) |previous| {
            if (entry.logical_chunk <= previous) return error.BadManifest;
        }
        try spore.validateRootfsDigest(entry.digest);
        previous_chunk = entry.logical_chunk;
    }

    var previous_zero: ?u64 = null;
    for (index.zero_chunks) |logical_chunk| {
        if (logical_chunk >= chunk_count) return error.BadManifest;
        if (previous_zero) |previous| {
            if (logical_chunk <= previous) return error.BadManifest;
        }
        previous_zero = logical_chunk;
    }

    var chunk_index: usize = 0;
    var zero_index: usize = 0;
    while (chunk_index < index.chunks.len and zero_index < index.zero_chunks.len) {
        const logical_chunk = index.chunks[chunk_index].logical_chunk;
        const zero_chunk = index.zero_chunks[zero_index];
        if (logical_chunk == zero_chunk) return error.BadManifest;
        if (logical_chunk < zero_chunk) {
            chunk_index += 1;
        } else {
            zero_index += 1;
        }
    }
}

fn validateIndexDigest(bytes: []const u8, digest: []const u8) spore.Error!void {
    const expected_hex = try spore.diskDigestHex(digest);
    const id = chunk.ChunkId.fromContents(bytes);
    const actual_hex = id.toHex();
    if (!std.mem.eql(u8, expected_hex, actual_hex[0..])) return error.BadManifest;
}

pub fn indexDigestAlloc(allocator: std.mem.Allocator, bytes: []const u8) spore.Error![]const u8 {
    const id = chunk.ChunkId.fromContents(bytes);
    const hex = id.toHex();
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ spore.rootfs_digest_prefix, hex[0..] }) catch return error.OutOfMemory;
}

const digest_a = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const digest_b = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const digest_c = "blake3:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

fn testStorage(index_digest: []const u8) spore.RootfsStorage {
    return .{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = .{ .mmio_slot = 0 },
        .logical_size = 8192,
        .chunk_size = 4096,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .index_digest = index_digest,
        .base_identity = index_digest,
        .object_namespace = spore.rootfs_storage_object_namespace,
    };
}

fn testIndex(chunks: []const RootfsBlockChunk, zero_chunks: []const u64) RootfsBlockIndex {
    return .{
        .kind = rootfs_block_index_kind,
        .logical_size = 8192,
        .chunk_size = 4096,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .object_namespace = spore.rootfs_storage_object_namespace,
        .chunks = chunks,
        .zero_chunks = zero_chunks,
    };
}

fn validIndexJson() []const u8 {
    return
    \\{"kind":"rootfs-block-index-v0","logical_size":8192,"chunk_size":4096,"hash_algorithm":"blake3","object_namespace":"rootfs/blake3","chunks":[{"logical_chunk":0,"digest":"blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}],"zero_chunks":[1]}
    ;
}

fn storageAndIndexJson(allocator: std.mem.Allocator) !struct {
    storage: spore.RootfsStorage,
    bytes: []const u8,
} {
    const bytes = try allocator.dupe(u8, validIndexJson());
    const digest = try indexDigestAlloc(allocator, bytes);
    return .{
        .storage = testStorage(digest),
        .bytes = bytes,
    };
}

test "manifest-bound rootfs block index validates descriptor digest and canonical coverage" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fixture = try storageAndIndexJson(arena);
    const parsed = try parseRootfsBlockIndex(arena, fixture.bytes, fixture.storage);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.chunks.len);
    try std.testing.expectEqual(@as(u64, 0), parsed.value.chunks[0].logical_chunk);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.zero_chunks.len);
    try std.testing.expectEqual(@as(u64, 1), parsed.value.zero_chunks[0]);
}

test "manifest-bound rootfs block index rejects digest and descriptor mismatches" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fixture = try storageAndIndexJson(arena);
    try std.testing.expectError(error.BadManifest, parseRootfsBlockIndex(arena, fixture.bytes, testStorage(digest_a)));

    var wrong_size = fixture.storage;
    wrong_size.logical_size = 4096;
    try std.testing.expectError(error.BadManifest, parseRootfsBlockIndex(arena, fixture.bytes, wrong_size));

    var wrong_chunk_size = fixture.storage;
    wrong_chunk_size.chunk_size = 8192;
    try std.testing.expectError(error.BadManifest, parseRootfsBlockIndex(arena, fixture.bytes, wrong_chunk_size));

    var wrong_algorithm = fixture.storage;
    wrong_algorithm.hash_algorithm = "sha256";
    try std.testing.expectError(error.BadManifest, parseRootfsBlockIndex(arena, fixture.bytes, wrong_algorithm));

    var wrong_namespace = fixture.storage;
    wrong_namespace.object_namespace = "../rootfs";
    try std.testing.expectError(error.BadManifest, parseRootfsBlockIndex(arena, fixture.bytes, wrong_namespace));

    const missing_kind =
        \\{"logical_size":8192,"chunk_size":4096,"hash_algorithm":"blake3","object_namespace":"rootfs/blake3","chunks":[{"logical_chunk":0,"digest":"blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}],"zero_chunks":[1]}
    ;
    const missing_kind_digest = try indexDigestAlloc(arena, missing_kind);
    try std.testing.expectError(error.BadManifest, parseRootfsBlockIndex(arena, missing_kind, testStorage(missing_kind_digest)));

    const storage = testStorage(digest_a);
    var wrong_kind = testIndex(&.{.{ .logical_chunk = 0, .digest = digest_b }}, &.{1});
    wrong_kind.kind = "unknown-rootfs-index-v0";
    try std.testing.expectError(error.BadManifest, validateRootfsBlockIndex(wrong_kind, storage));

    var wrong_index_algorithm = testIndex(&.{.{ .logical_chunk = 0, .digest = digest_b }}, &.{1});
    wrong_index_algorithm.hash_algorithm = "sha256";
    try std.testing.expectError(error.BadManifest, validateRootfsBlockIndex(wrong_index_algorithm, storage));

    var wrong_index_namespace = testIndex(&.{.{ .logical_chunk = 0, .digest = digest_b }}, &.{1});
    wrong_index_namespace.object_namespace = "../rootfs";
    try std.testing.expectError(error.BadManifest, validateRootfsBlockIndex(wrong_index_namespace, storage));
}

test "manifest-bound rootfs block index rejects non-canonical chunk tables" {
    try std.testing.expectError(error.BadManifest, validateRootfsBlockIndex(testIndex(
        &.{
            .{ .logical_chunk = 0, .digest = digest_b },
            .{ .logical_chunk = 0, .digest = digest_c },
        },
        &.{},
    ), testStorage(digest_a)));

    try std.testing.expectError(error.BadManifest, validateRootfsBlockIndex(testIndex(
        &.{
            .{ .logical_chunk = 1, .digest = digest_b },
            .{ .logical_chunk = 0, .digest = digest_c },
        },
        &.{},
    ), testStorage(digest_a)));

    try std.testing.expectError(error.BadManifest, validateRootfsBlockIndex(
        testIndex(&.{.{ .logical_chunk = 2, .digest = digest_b }}, &.{0}),
        testStorage(digest_a),
    ));

    try std.testing.expectError(error.BadManifest, validateRootfsBlockIndex(
        testIndex(&.{.{ .logical_chunk = 0, .digest = digest_b }}, &.{0}),
        testStorage(digest_a),
    ));

    try std.testing.expectError(error.BadManifest, validateRootfsBlockIndex(
        testIndex(&.{.{ .logical_chunk = 0, .digest = "sha256:bbbb" }}, &.{1}),
        testStorage(digest_a),
    ));

    try std.testing.expectError(error.BadManifest, validateRootfsBlockIndex(
        testIndex(&.{.{ .logical_chunk = 0, .digest = digest_b }}, &.{}),
        testStorage(digest_a),
    ));
}

fn fuzzRootfsBlockIndexParse(_: void, s: *std.testing.Smith) !void {
    // Rootfs block indexes may arrive from registries, bundles, or peers. They
    // must either fail closed or validate to a descriptor-bound, canonical map.
    var buf: [4096]u8 = undefined;
    const len = s.slice(&buf);
    const digest = try indexDigestAlloc(std.testing.allocator, buf[0..len]);
    defer std.testing.allocator.free(digest);
    const storage = spore.RootfsStorage{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = .{ .mmio_slot = 0 },
        .logical_size = 4096,
        .chunk_size = 4096,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .index_digest = digest,
        .base_identity = digest,
        .object_namespace = spore.rootfs_storage_object_namespace,
    };
    const parsed = parseRootfsBlockIndex(std.testing.allocator, buf[0..len], storage) catch return;
    parsed.deinit();
}

test "fuzz manifest-bound rootfs block index parser" {
    try std.testing.fuzz({}, fuzzRootfsBlockIndexParse, .{});
}
