//! Manifest-bound chunk-mapped disk index parsing.
//!
//! This is the portable restore-authority parser for chunked immutable disk
//! state. U1 routes existing chunked rootfs storage through this parser while
//! later slices move writable disks and memory manifests onto the same shape.

const std = @import("std");
const chunk = @import("chunk.zig");

pub const disk_index_kind = "spore-disk-index-v1";
pub const max_index_bytes: usize = 64 * 1024 * 1024;
pub const digest_prefix = "blake3:";

pub const Error = error{
    BadManifest,
    FormatTooOld,
    OutOfMemory,
};

pub const DiskIndexChunk = struct {
    logical_chunk: u64,
    digest: []const u8,
};

pub const DiskIndex = struct {
    kind: []const u8,
    logical_size: u64,
    chunk_size: u64,
    hash_algorithm: []const u8,
    object_namespace: []const u8,
    chunks: []const DiskIndexChunk = &.{},
    zero_chunks: []const u64 = &.{},
};

pub const Descriptor = struct {
    logical_size: u64,
    chunk_size: u64,
    hash_algorithm: []const u8,
    object_namespace: []const u8,
    index_digest: ?[]const u8 = null,
};

pub fn parseDiskIndex(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    descriptor: Descriptor,
) Error!std.json.Parsed(DiskIndex) {
    if (bytes.len == 0 or bytes.len > max_index_bytes) return error.BadManifest;
    if (descriptor.index_digest) |digest| try validateIndexDigest(bytes, digest);
    const parsed = std.json.parseFromSlice(DiskIndex, allocator, bytes, .{
        .allocate = .alloc_always,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadManifest,
    };
    errdefer parsed.deinit();
    try validateDiskIndex(parsed.value, descriptor);
    return parsed;
}

pub fn validateDiskIndex(index: DiskIndex, descriptor: Descriptor) Error!void {
    if (descriptor.chunk_size == 0) return error.BadManifest;
    if (!std.mem.eql(u8, index.kind, disk_index_kind)) {
        if (std.mem.eql(u8, index.kind, "rootfs-block-index-v0")) return error.FormatTooOld;
        return error.BadManifest;
    }
    if (index.logical_size != descriptor.logical_size) return error.BadManifest;
    if (index.chunk_size != descriptor.chunk_size) return error.BadManifest;
    if (!std.mem.eql(u8, index.hash_algorithm, descriptor.hash_algorithm)) return error.BadManifest;
    if (!std.mem.eql(u8, index.object_namespace, descriptor.object_namespace)) return error.BadManifest;

    const chunk_count = try indexChunkCount(index.logical_size, index.chunk_size);
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
        try validateDigestRef(entry.digest);
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

fn indexChunkCount(logical_size: u64, chunk_size: u64) Error!u64 {
    if (chunk_size == 0) return error.BadManifest;
    return std.math.divCeil(u64, logical_size, chunk_size) catch return error.BadManifest;
}

fn validateDigestRef(digest: []const u8) Error!void {
    if (!std.mem.startsWith(u8, digest, digest_prefix)) return error.BadManifest;
    const hex = digest[digest_prefix.len..];
    if (hex.len != chunk.ChunkId.hex_len) return error.BadManifest;
    _ = chunk.ChunkId.fromHex(hex) catch return error.BadManifest;
}

fn digestHex(digest: []const u8) Error![]const u8 {
    try validateDigestRef(digest);
    return digest[digest_prefix.len..];
}

fn validateIndexDigest(bytes: []const u8, digest: []const u8) Error!void {
    const expected_hex = try digestHex(digest);
    const id = chunk.ChunkId.fromContents(bytes);
    const actual_hex = id.toHex();
    if (!std.mem.eql(u8, expected_hex, actual_hex[0..])) return error.BadManifest;
}

pub fn indexDigestAlloc(allocator: std.mem.Allocator, bytes: []const u8) Error![]const u8 {
    const id = chunk.ChunkId.fromContents(bytes);
    const hex = id.toHex();
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ digest_prefix, hex[0..] }) catch return error.OutOfMemory;
}

const digest_a = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const digest_b = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const digest_c = "blake3:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

fn testDescriptor(index_digest: []const u8) Descriptor {
    return .{
        .logical_size = 8192,
        .chunk_size = 4096,
        .hash_algorithm = "blake3",
        .index_digest = index_digest,
        .object_namespace = "rootfs/blake3",
    };
}

fn testIndex(kind: []const u8, chunks: []const DiskIndexChunk, zero_chunks: []const u64) DiskIndex {
    return .{
        .kind = kind,
        .logical_size = 8192,
        .chunk_size = 4096,
        .hash_algorithm = "blake3",
        .object_namespace = "rootfs/blake3",
        .chunks = chunks,
        .zero_chunks = zero_chunks,
    };
}

fn validIndexJson() []const u8 {
    return
    \\{"kind":"spore-disk-index-v1","logical_size":8192,"chunk_size":4096,"hash_algorithm":"blake3","object_namespace":"rootfs/blake3","chunks":[{"logical_chunk":0,"digest":"blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}],"zero_chunks":[1]}
    ;
}

fn storageAndIndexJson(allocator: std.mem.Allocator) !struct {
    descriptor: Descriptor,
    bytes: []const u8,
} {
    const bytes = try allocator.dupe(u8, validIndexJson());
    const digest = try indexDigestAlloc(allocator, bytes);
    return .{
        .descriptor = testDescriptor(digest),
        .bytes = bytes,
    };
}

test "manifest-bound disk index validates descriptor digest and canonical coverage" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fixture = try storageAndIndexJson(arena);
    const parsed = try parseDiskIndex(arena, fixture.bytes, fixture.descriptor);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.chunks.len);
    try std.testing.expectEqual(@as(u64, 0), parsed.value.chunks[0].logical_chunk);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.zero_chunks.len);
    try std.testing.expectEqual(@as(u64, 1), parsed.value.zero_chunks[0]);
}

test "manifest-bound disk index rejects the legacy rootfs kind" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const legacy =
        \\{"kind":"rootfs-block-index-v0","logical_size":8192,"chunk_size":4096,"hash_algorithm":"blake3","object_namespace":"rootfs/blake3","chunks":[{"logical_chunk":0,"digest":"blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}],"zero_chunks":[1]}
    ;
    const digest = try indexDigestAlloc(arena, legacy);
    try std.testing.expectError(error.FormatTooOld, parseDiskIndex(arena, legacy, testDescriptor(digest)));
}

test "manifest-bound disk index rejects digest and descriptor mismatches" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fixture = try storageAndIndexJson(arena);
    try std.testing.expectError(error.BadManifest, parseDiskIndex(arena, fixture.bytes, testDescriptor(digest_a)));

    var wrong_size = fixture.descriptor;
    wrong_size.logical_size = 4096;
    try std.testing.expectError(error.BadManifest, parseDiskIndex(arena, fixture.bytes, wrong_size));

    var wrong_chunk_size = fixture.descriptor;
    wrong_chunk_size.chunk_size = 8192;
    try std.testing.expectError(error.BadManifest, parseDiskIndex(arena, fixture.bytes, wrong_chunk_size));

    var wrong_algorithm = fixture.descriptor;
    wrong_algorithm.hash_algorithm = "sha256";
    try std.testing.expectError(error.BadManifest, parseDiskIndex(arena, fixture.bytes, wrong_algorithm));

    var wrong_namespace = fixture.descriptor;
    wrong_namespace.object_namespace = "../rootfs";
    try std.testing.expectError(error.BadManifest, parseDiskIndex(arena, fixture.bytes, wrong_namespace));

    const missing_kind =
        \\{"logical_size":8192,"chunk_size":4096,"hash_algorithm":"blake3","object_namespace":"rootfs/blake3","chunks":[{"logical_chunk":0,"digest":"blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}],"zero_chunks":[1]}
    ;
    const missing_kind_digest = try indexDigestAlloc(arena, missing_kind);
    try std.testing.expectError(error.BadManifest, parseDiskIndex(arena, missing_kind, testDescriptor(missing_kind_digest)));

    const descriptor = testDescriptor(digest_a);
    var wrong_kind = testIndex(disk_index_kind, &.{.{ .logical_chunk = 0, .digest = digest_b }}, &.{1});
    wrong_kind.kind = "unknown-rootfs-index-v0";
    try std.testing.expectError(error.BadManifest, validateDiskIndex(wrong_kind, descriptor));

    var wrong_index_algorithm = testIndex(disk_index_kind, &.{.{ .logical_chunk = 0, .digest = digest_b }}, &.{1});
    wrong_index_algorithm.hash_algorithm = "sha256";
    try std.testing.expectError(error.BadManifest, validateDiskIndex(wrong_index_algorithm, descriptor));

    var wrong_index_namespace = testIndex(disk_index_kind, &.{.{ .logical_chunk = 0, .digest = digest_b }}, &.{1});
    wrong_index_namespace.object_namespace = "../rootfs";
    try std.testing.expectError(error.BadManifest, validateDiskIndex(wrong_index_namespace, descriptor));
}

test "manifest-bound disk index rejects non-canonical chunk tables" {
    try std.testing.expectError(error.BadManifest, validateDiskIndex(testIndex(
        disk_index_kind,
        &.{
            .{ .logical_chunk = 0, .digest = digest_b },
            .{ .logical_chunk = 0, .digest = digest_c },
        },
        &.{},
    ), testDescriptor(digest_a)));

    try std.testing.expectError(error.BadManifest, validateDiskIndex(testIndex(
        disk_index_kind,
        &.{
            .{ .logical_chunk = 1, .digest = digest_b },
            .{ .logical_chunk = 0, .digest = digest_c },
        },
        &.{},
    ), testDescriptor(digest_a)));

    try std.testing.expectError(error.BadManifest, validateDiskIndex(
        testIndex(disk_index_kind, &.{.{ .logical_chunk = 2, .digest = digest_b }}, &.{0}),
        testDescriptor(digest_a),
    ));

    try std.testing.expectError(error.BadManifest, validateDiskIndex(
        testIndex(disk_index_kind, &.{.{ .logical_chunk = 0, .digest = digest_b }}, &.{0}),
        testDescriptor(digest_a),
    ));

    try std.testing.expectError(error.BadManifest, validateDiskIndex(
        testIndex(disk_index_kind, &.{.{ .logical_chunk = 0, .digest = "sha256:bbbb" }}, &.{1}),
        testDescriptor(digest_a),
    ));

    try std.testing.expectError(error.BadManifest, validateDiskIndex(
        testIndex(disk_index_kind, &.{.{ .logical_chunk = 0, .digest = digest_b }}, &.{}),
        testDescriptor(digest_a),
    ));
}

fn fuzzDiskIndexParse(_: void, s: *std.testing.Smith) !void {
    // Disk indexes may arrive from registries, bundles, or peers. They
    // must either fail closed or validate to a descriptor-bound, canonical map.
    var buf: [4096]u8 = undefined;
    const len = s.slice(&buf);
    const digest = try indexDigestAlloc(std.testing.allocator, buf[0..len]);
    defer std.testing.allocator.free(digest);
    const descriptor = Descriptor{
        .logical_size = 4096,
        .chunk_size = 4096,
        .hash_algorithm = "blake3",
        .index_digest = digest,
        .object_namespace = "rootfs/blake3",
    };
    const parsed = parseDiskIndex(std.testing.allocator, buf[0..len], descriptor) catch return;
    parsed.deinit();
}

test "fuzz manifest-bound disk index parser" {
    try std.testing.fuzz({}, fuzzDiskIndexParse, .{});
}
