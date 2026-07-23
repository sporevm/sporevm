//! Manifest-bound chunk-mapped disk index parsing.
//!
//! This is the portable restore-authority parser for chunked immutable disk
//! state. U1 routes existing chunked rootfs storage through this parser while
//! later slices move writable disks and memory manifests onto the same shape.

const std = @import("std");
const chunk = @import("chunk.zig");

pub const disk_index_kind_v1 = "spore-disk-index-v1";
pub const disk_index_kind = "spore-disk-index-v2";
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

pub const DiskIndexZeroRange = struct {
    start: u64,
    count: u64,
};

pub const DiskIndex = struct {
    kind: []const u8,
    logical_size: u64,
    chunk_size: u64,
    hash_algorithm: []const u8,
    object_namespace: []const u8,
    chunks: []const DiskIndexChunk = &.{},
    zero_chunks: []const u64 = &.{},
    zero_ranges: []const DiskIndexZeroRange = &.{},
};

const DiskIndexChunkRangeV2 = struct {
    start: u64,
    /// Concatenated lowercase BLAKE3 hex digests, one 32-byte digest per
    /// logical chunk. The common algorithm and prefix live in the index.
    digests: []const u8,
};

const DiskIndexV2 = struct {
    kind: []const u8,
    logical_size: u64,
    chunk_size: u64,
    hash_algorithm: []const u8,
    object_namespace: []const u8,
    chunk_ranges: []const DiskIndexChunkRangeV2 = &.{},
    zero_ranges: []const DiskIndexZeroRange = &.{},
};

const ParsedBacking = union(enum) {
    v1: std.json.Parsed(DiskIndex),
    v2: struct {
        parsed: std.json.Parsed(DiskIndexV2),
        chunks: []DiskIndexChunk,
        digest_refs: []u8,
    },
};

pub const ParsedDiskIndex = struct {
    allocator: std.mem.Allocator,
    value: DiskIndex,
    backing: ParsedBacking,

    pub fn deinit(self: ParsedDiskIndex) void {
        switch (self.backing) {
            .v1 => |parsed| parsed.deinit(),
            .v2 => |parsed| {
                if (parsed.chunks.len != 0) self.allocator.free(parsed.chunks);
                if (parsed.digest_refs.len != 0) self.allocator.free(parsed.digest_refs);
                parsed.parsed.deinit();
            },
        }
    }
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
) Error!ParsedDiskIndex {
    if (bytes.len == 0 or bytes.len > max_index_bytes) return error.BadManifest;
    if (descriptor.index_digest) |digest| try validateIndexDigest(bytes, digest);

    const Kind = struct { kind: []const u8 };
    const kind = std.json.parseFromSlice(Kind, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = true,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadManifest,
    };
    defer kind.deinit();

    const result = if (std.mem.eql(u8, kind.value.kind, disk_index_kind_v1))
        try parseV1(allocator, bytes)
    else if (std.mem.eql(u8, kind.value.kind, disk_index_kind))
        try parseV2(allocator, bytes)
    else if (std.mem.eql(u8, kind.value.kind, "rootfs-block-index-v0"))
        return error.FormatTooOld
    else
        return error.BadManifest;
    errdefer result.deinit();
    try validateDiskIndex(result.value, descriptor);
    const canonical_bytes = switch (result.backing) {
        .v1 => try stringifyV1CanonicalAlloc(allocator, result.value),
        .v2 => |backing| try stringifyBoundedAlloc(allocator, backing.parsed.value),
    };
    defer allocator.free(canonical_bytes);
    if (!std.mem.eql(u8, bytes, canonical_bytes)) return error.BadManifest;
    return result;
}

pub fn parseSelfDescribedDiskIndex(allocator: std.mem.Allocator, bytes: []const u8) Error!ParsedDiskIndex {
    if (bytes.len == 0 or bytes.len > max_index_bytes) return error.BadManifest;
    const Header = struct {
        logical_size: u64,
        chunk_size: u64,
        hash_algorithm: []const u8,
        object_namespace: []const u8,
    };
    const header = std.json.parseFromSlice(Header, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = true,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadManifest,
    };
    defer header.deinit();
    return parseDiskIndex(allocator, bytes, .{
        .logical_size = header.value.logical_size,
        .chunk_size = header.value.chunk_size,
        .hash_algorithm = header.value.hash_algorithm,
        .object_namespace = header.value.object_namespace,
    });
}

fn parseV1(allocator: std.mem.Allocator, bytes: []const u8) Error!ParsedDiskIndex {
    const parsed = std.json.parseFromSlice(DiskIndex, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadManifest,
    };
    errdefer parsed.deinit();
    if (parsed.value.zero_ranges.len != 0) return error.BadManifest;
    return .{ .allocator = allocator, .value = parsed.value, .backing = .{ .v1 = parsed } };
}

fn parseV2(allocator: std.mem.Allocator, bytes: []const u8) Error!ParsedDiskIndex {
    const parsed = std.json.parseFromSlice(DiskIndexV2, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadManifest,
    };
    errdefer parsed.deinit();
    try validateV2Shape(parsed.value);

    var nonzero_count: u64 = 0;
    for (parsed.value.chunk_ranges) |range| {
        nonzero_count = std.math.add(u64, nonzero_count, range.digests.len / chunk.ChunkId.hex_len) catch return error.BadManifest;
    }
    const chunk_len = std.math.cast(usize, nonzero_count) orelse return error.BadManifest;
    const digest_ref_bytes = std.math.mul(usize, chunk_len, digest_prefix.len + chunk.ChunkId.hex_len) catch return error.BadManifest;
    const chunks = try allocator.alloc(DiskIndexChunk, chunk_len);
    errdefer if (chunks.len != 0) allocator.free(chunks);
    const digest_refs = try allocator.alloc(u8, digest_ref_bytes);
    errdefer if (digest_refs.len != 0) allocator.free(digest_refs);

    var entry_index: usize = 0;
    for (parsed.value.chunk_ranges) |range| {
        const count = range.digests.len / chunk.ChunkId.hex_len;
        for (0..count) |offset| {
            const ref_start = entry_index * (digest_prefix.len + chunk.ChunkId.hex_len);
            const digest_ref = digest_refs[ref_start..][0 .. digest_prefix.len + chunk.ChunkId.hex_len];
            @memcpy(digest_ref[0..digest_prefix.len], digest_prefix);
            @memcpy(digest_ref[digest_prefix.len..], range.digests[offset * chunk.ChunkId.hex_len ..][0..chunk.ChunkId.hex_len]);
            chunks[entry_index] = .{
                .logical_chunk = std.math.add(u64, range.start, offset) catch return error.BadManifest,
                .digest = digest_ref,
            };
            entry_index += 1;
        }
    }

    return .{
        .allocator = allocator,
        .value = .{
            .kind = parsed.value.kind,
            .logical_size = parsed.value.logical_size,
            .chunk_size = parsed.value.chunk_size,
            .hash_algorithm = parsed.value.hash_algorithm,
            .object_namespace = parsed.value.object_namespace,
            .chunks = chunks,
            .zero_ranges = parsed.value.zero_ranges,
        },
        .backing = .{ .v2 = .{ .parsed = parsed, .chunks = chunks, .digest_refs = digest_refs } },
    };
}

pub fn validateDiskIndex(index: DiskIndex, descriptor: Descriptor) Error!void {
    if (descriptor.chunk_size == 0) return error.BadManifest;
    if (index.logical_size != descriptor.logical_size) return error.BadManifest;
    if (index.chunk_size != descriptor.chunk_size) return error.BadManifest;
    if (!std.mem.eql(u8, index.hash_algorithm, descriptor.hash_algorithm)) return error.BadManifest;
    if (!std.mem.eql(u8, index.object_namespace, descriptor.object_namespace)) return error.BadManifest;
    try validateIndexShape(index);
}

fn validateIndexShape(index: DiskIndex) Error!void {
    if (index.chunk_size == 0) return error.BadManifest;
    const is_v1 = std.mem.eql(u8, index.kind, disk_index_kind_v1);
    const is_v2 = std.mem.eql(u8, index.kind, disk_index_kind);
    if (!is_v1 and !is_v2) {
        if (std.mem.eql(u8, index.kind, "rootfs-block-index-v0")) return error.FormatTooOld;
        return error.BadManifest;
    }
    if (is_v1 and index.zero_ranges.len != 0) return error.BadManifest;
    if (index.zero_chunks.len != 0 and index.zero_ranges.len != 0) return error.BadManifest;

    const chunk_count = try indexChunkCount(index.logical_size, index.chunk_size);
    var zero_count: u64 = @intCast(index.zero_chunks.len);
    for (index.zero_ranges) |range| {
        zero_count = std.math.add(u64, zero_count, range.count) catch return error.BadManifest;
    }
    const covered_chunks = std.math.add(u64, @as(u64, @intCast(index.chunks.len)), zero_count) catch return error.BadManifest;
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

    var previous_zero_end: ?u64 = null;
    for (index.zero_ranges) |range| {
        if (range.count == 0 or range.start >= chunk_count) return error.BadManifest;
        const end = std.math.add(u64, range.start, range.count) catch return error.BadManifest;
        if (end > chunk_count) return error.BadManifest;
        if (previous_zero_end) |previous| {
            if (range.start <= previous) return error.BadManifest;
        }
        previous_zero_end = end;
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

    if (index.zero_ranges.len != 0) {
        var nonzero_index: usize = 0;
        var range_index: usize = 0;
        var next: u64 = 0;
        while (nonzero_index < index.chunks.len or range_index < index.zero_ranges.len) {
            if (range_index == index.zero_ranges.len or
                (nonzero_index < index.chunks.len and index.chunks[nonzero_index].logical_chunk < index.zero_ranges[range_index].start))
            {
                if (index.chunks[nonzero_index].logical_chunk != next) return error.BadManifest;
                next += 1;
                nonzero_index += 1;
            } else {
                const range = index.zero_ranges[range_index];
                if (range.start != next) return error.BadManifest;
                next = std.math.add(u64, next, range.count) catch return error.BadManifest;
                range_index += 1;
            }
        }
        if (next != chunk_count) return error.BadManifest;
    }
}

fn validateV2Shape(index: DiskIndexV2) Error!void {
    if (!std.mem.eql(u8, index.kind, disk_index_kind)) return error.BadManifest;
    if (index.chunk_size == 0) return error.BadManifest;
    const chunk_count = try indexChunkCount(index.logical_size, index.chunk_size);

    var previous_nonzero_end: ?u64 = null;
    for (index.chunk_ranges) |range| {
        if (range.digests.len == 0 or range.digests.len % chunk.ChunkId.hex_len != 0) return error.BadManifest;
        const count: u64 = @intCast(range.digests.len / chunk.ChunkId.hex_len);
        const end = std.math.add(u64, range.start, count) catch return error.BadManifest;
        if (range.start >= chunk_count or end > chunk_count) return error.BadManifest;
        if (previous_nonzero_end) |previous| if (range.start <= previous) return error.BadManifest;
        for (range.digests) |byte| if (!isLowerHex(byte)) return error.BadManifest;
        previous_nonzero_end = end;
    }

    var previous_zero_end: ?u64 = null;
    for (index.zero_ranges) |range| {
        if (range.count == 0 or range.start >= chunk_count) return error.BadManifest;
        const end = std.math.add(u64, range.start, range.count) catch return error.BadManifest;
        if (end > chunk_count) return error.BadManifest;
        if (previous_zero_end) |previous| if (range.start <= previous) return error.BadManifest;
        previous_zero_end = end;
    }
}

fn indexChunkCount(logical_size: u64, chunk_size: u64) Error!u64 {
    if (chunk_size == 0) return error.BadManifest;
    return std.math.divCeil(u64, logical_size, chunk_size) catch return error.BadManifest;
}

pub fn zeroChunkCount(index: DiskIndex) Error!u64 {
    var count: u64 = @intCast(index.zero_chunks.len);
    for (index.zero_ranges) |range| count = std.math.add(u64, count, range.count) catch return error.BadManifest;
    return count;
}

pub fn isZeroChunk(index: DiskIndex, logical_chunk: u64) bool {
    if (index.zero_ranges.len != 0) {
        var low: usize = 0;
        var high = index.zero_ranges.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const range = index.zero_ranges[mid];
            if (logical_chunk < range.start) {
                high = mid;
            } else {
                const end = std.math.add(u64, range.start, range.count) catch return false;
                if (logical_chunk < end) return true;
                low = mid + 1;
            }
        }
        return false;
    }
    const Order = struct {
        fn compare(target: u64, item: u64) std.math.Order {
            return std.math.order(target, item);
        }
    };
    return std.sort.binarySearch(u64, index.zero_chunks, logical_chunk, Order.compare) != null;
}

fn validateDigestRef(digest: []const u8) Error!void {
    if (!std.mem.startsWith(u8, digest, digest_prefix)) return error.BadManifest;
    const hex = digest[digest_prefix.len..];
    if (hex.len != chunk.ChunkId.hex_len) return error.BadManifest;
    for (hex) |byte| {
        if (isLowerHex(byte)) continue;
        return error.BadManifest;
    }
    _ = chunk.ChunkId.fromHex(hex) catch return error.BadManifest;
}

fn isLowerHex(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f');
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

pub const EncodedIndex = struct {
    /// Both slices are owned. Call deinit unless digest ownership is moved to
    /// a longer-lived result, in which case free bytes and retain digest.
    bytes: []u8,
    digest: []u8,

    pub fn deinit(self: EncodedIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.digest);
    }
};

/// Encodes the one accepted byte representation of a disk index and names it
/// by the BLAKE3 digest of those exact bytes.
pub fn encodeCanonicalAlloc(allocator: std.mem.Allocator, index: DiskIndex) Error!EncodedIndex {
    const bytes = try canonicalBytesAlloc(allocator, index);
    errdefer allocator.free(bytes);
    return .{
        .bytes = bytes,
        .digest = try digestBytesAlloc(allocator, bytes),
    };
}

fn canonicalBytesAlloc(allocator: std.mem.Allocator, index: DiskIndex) Error![]u8 {
    try validateIndexShape(index);
    return stringifyCanonicalAlloc(allocator, index);
}

fn stringifyCanonicalAlloc(allocator: std.mem.Allocator, index: DiskIndex) Error![]u8 {
    if (std.mem.eql(u8, index.kind, disk_index_kind_v1)) return stringifyV1CanonicalAlloc(allocator, index);
    if (!std.mem.eql(u8, index.kind, disk_index_kind)) return error.BadManifest;
    return stringifyV2CanonicalAlloc(allocator, index);
}

const DiskIndexV1 = struct {
    kind: []const u8,
    logical_size: u64,
    chunk_size: u64,
    hash_algorithm: []const u8,
    object_namespace: []const u8,
    chunks: []const DiskIndexChunk,
    zero_chunks: []const u64,
};

fn stringifyV1CanonicalAlloc(allocator: std.mem.Allocator, index: DiskIndex) Error![]u8 {
    const value = DiskIndexV1{
        .kind = index.kind,
        .logical_size = index.logical_size,
        .chunk_size = index.chunk_size,
        .hash_algorithm = index.hash_algorithm,
        .object_namespace = index.object_namespace,
        .chunks = index.chunks,
        .zero_chunks = index.zero_chunks,
    };
    return stringifyBoundedAlloc(allocator, value);
}

fn stringifyV2CanonicalAlloc(allocator: std.mem.Allocator, index: DiskIndex) Error![]u8 {
    const range_count = countChunkRanges(index.chunks);
    const chunk_ranges = try allocator.alloc(DiskIndexChunkRangeV2, range_count);
    defer if (chunk_ranges.len != 0) allocator.free(chunk_ranges);
    var digest_blobs: std.ArrayList([]u8) = .empty;
    defer {
        for (digest_blobs.items) |blob| allocator.free(blob);
        digest_blobs.deinit(allocator);
    }

    var range_index: usize = 0;
    var start_index: usize = 0;
    while (start_index < index.chunks.len) {
        var end_index = start_index + 1;
        while (end_index < index.chunks.len and index.chunks[end_index].logical_chunk == index.chunks[end_index - 1].logical_chunk + 1) : (end_index += 1) {}
        const digest_count = end_index - start_index;
        const blob = try allocator.alloc(u8, std.math.mul(usize, digest_count, chunk.ChunkId.hex_len) catch return error.BadManifest);
        errdefer allocator.free(blob);
        for (index.chunks[start_index..end_index], 0..) |entry, i| {
            const hex = try digestHex(entry.digest);
            @memcpy(blob[i * chunk.ChunkId.hex_len ..][0..chunk.ChunkId.hex_len], hex);
        }
        try digest_blobs.append(allocator, blob);
        chunk_ranges[range_index] = .{ .start = index.chunks[start_index].logical_chunk, .digests = blob };
        range_index += 1;
        start_index = end_index;
    }

    const owned_zero_ranges = if (index.zero_ranges.len != 0)
        null
    else
        try rangesFromZeroChunks(allocator, index.zero_chunks);
    defer if (owned_zero_ranges) |ranges| if (ranges.len != 0) allocator.free(ranges);
    const zero_ranges = owned_zero_ranges orelse index.zero_ranges;
    const value = DiskIndexV2{
        .kind = index.kind,
        .logical_size = index.logical_size,
        .chunk_size = index.chunk_size,
        .hash_algorithm = index.hash_algorithm,
        .object_namespace = index.object_namespace,
        .chunk_ranges = chunk_ranges,
        .zero_ranges = zero_ranges,
    };
    return stringifyBoundedAlloc(allocator, value);
}

fn stringifyBoundedAlloc(allocator: std.mem.Allocator, value: anytype) Error![]u8 {
    const bytes = std.json.Stringify.valueAlloc(allocator, value, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    }) catch return error.OutOfMemory;
    errdefer allocator.free(bytes);
    if (bytes.len == 0 or bytes.len > max_index_bytes) return error.BadManifest;
    return bytes;
}

fn countChunkRanges(chunks: []const DiskIndexChunk) usize {
    if (chunks.len == 0) return 0;
    var count: usize = 1;
    for (chunks[1..], 1..) |entry, i| if (entry.logical_chunk != chunks[i - 1].logical_chunk + 1) {
        count += 1;
    };
    return count;
}

fn rangesFromZeroChunks(allocator: std.mem.Allocator, chunks: []const u64) Error![]DiskIndexZeroRange {
    if (chunks.len == 0) return &.{};
    var range_count: usize = 1;
    for (chunks[1..], 1..) |logical_chunk, i| if (logical_chunk != chunks[i - 1] + 1) {
        range_count += 1;
    };
    const ranges = try allocator.alloc(DiskIndexZeroRange, range_count);
    var range_index: usize = 0;
    var start_index: usize = 0;
    while (start_index < chunks.len) {
        var end_index = start_index + 1;
        while (end_index < chunks.len and chunks[end_index] == chunks[end_index - 1] + 1) : (end_index += 1) {}
        ranges[range_index] = .{ .start = chunks[start_index], .count = @intCast(end_index - start_index) };
        range_index += 1;
        start_index = end_index;
    }
    return ranges;
}

fn digestBytesAlloc(allocator: std.mem.Allocator, bytes: []const u8) Error![]u8 {
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
    \\{
    \\  "kind": "spore-disk-index-v1",
    \\  "logical_size": 8192,
    \\  "chunk_size": 4096,
    \\  "hash_algorithm": "blake3",
    \\  "object_namespace": "rootfs/blake3",
    \\  "chunks": [
    \\    {
    \\      "logical_chunk": 0,
    \\      "digest": "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    \\    }
    \\  ],
    \\  "zero_chunks": [
    \\    1
    \\  ]
    \\}
    ;
}

fn validV2IndexJson() []const u8 {
    return
    \\{
    \\  "kind": "spore-disk-index-v2",
    \\  "logical_size": 8192,
    \\  "chunk_size": 4096,
    \\  "hash_algorithm": "blake3",
    \\  "object_namespace": "rootfs/blake3",
    \\  "chunk_ranges": [
    \\    {
    \\      "start": 0,
    \\      "digests": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    \\    }
    \\  ],
    \\  "zero_ranges": [
    \\    {
    \\      "start": 1,
    \\      "count": 1
    \\    }
    \\  ]
    \\}
    ;
}

fn storageAndIndexJson(allocator: std.mem.Allocator) !struct {
    descriptor: Descriptor,
    bytes: []const u8,
} {
    const encoded = try encodeCanonicalAlloc(
        allocator,
        testIndex(disk_index_kind, &.{.{ .logical_chunk = 0, .digest = digest_b }}, &.{1}),
    );
    return .{
        .descriptor = testDescriptor(encoded.digest),
        .bytes = encoded.bytes,
    };
}

test "disk index canonical encoding has stable bytes and digest" {
    const allocator = std.testing.allocator;
    const encoded = try encodeCanonicalAlloc(
        allocator,
        testIndex(disk_index_kind_v1, &.{.{ .logical_chunk = 0, .digest = digest_b }}, &.{1}),
    );
    defer encoded.deinit(allocator);

    try std.testing.expectEqualStrings(validIndexJson(), encoded.bytes);
    try std.testing.expectEqualStrings("blake3:84ed6c06aee56c98b84a1eeaa122dbb91642feeeca02675ef5765043ccad19ac", encoded.digest);
}

test "v2 disk index canonical encoding has stable bytes and digest" {
    const allocator = std.testing.allocator;
    const encoded = try encodeCanonicalAlloc(
        allocator,
        testIndex(disk_index_kind, &.{.{ .logical_chunk = 0, .digest = digest_b }}, &.{1}),
    );
    defer encoded.deinit(allocator);

    try std.testing.expectEqualStrings(validV2IndexJson(), encoded.bytes);
    try std.testing.expectEqualStrings("blake3:69fefbc2cd610a7d0d66ffe56978513273fbd38fb0ad905c1c9e40c04c86bcf0", encoded.digest);
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
    try std.testing.expectEqual(@as(usize, 0), parsed.value.zero_chunks.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.zero_ranges.len);
    try std.testing.expectEqual(DiskIndexZeroRange{ .start = 1, .count = 1 }, parsed.value.zero_ranges[0]);
}

test "manifest-bound disk index rejects the legacy rootfs kind" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const legacy =
        \\{"kind":"rootfs-block-index-v0","logical_size":8192,"chunk_size":4096,"hash_algorithm":"blake3","object_namespace":"rootfs/blake3","chunks":[{"logical_chunk":0,"digest":"blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}],"zero_chunks":[1]}
    ;
    const digest = try digestBytesAlloc(arena, legacy);
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
    const missing_kind_digest = try digestBytesAlloc(arena, missing_kind);
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

test "manifest-bound disk index rejects non-canonical byte encodings" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const compact =
        \\{"kind":"spore-disk-index-v1","logical_size":8192,"chunk_size":4096,"hash_algorithm":"blake3","object_namespace":"rootfs/blake3","chunks":[{"logical_chunk":0,"digest":"blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}],"zero_chunks":[1]}
    ;
    const reordered =
        \\{"logical_size":8192,"kind":"spore-disk-index-v1","chunk_size":4096,"hash_algorithm":"blake3","object_namespace":"rootfs/blake3","chunks":[{"logical_chunk":0,"digest":"blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}],"zero_chunks":[1]}
    ;
    for (&[_][]const u8{ compact, reordered }) |bytes| {
        const digest = try digestBytesAlloc(arena, bytes);
        try std.testing.expectError(error.BadManifest, parseDiskIndex(arena, bytes, testDescriptor(digest)));
    }

    const uppercase_digest =
        \\{
        \\  "kind": "spore-disk-index-v1",
        \\  "logical_size": 8192,
        \\  "chunk_size": 4096,
        \\  "hash_algorithm": "blake3",
        \\  "object_namespace": "rootfs/blake3",
        \\  "chunks": [
        \\    {
        \\      "logical_chunk": 0,
        \\      "digest": "blake3:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
        \\    }
        \\  ],
        \\  "zero_chunks": [
        \\    1
        \\  ]
        \\}
    ;
    const uppercase_digest_hash = try digestBytesAlloc(arena, uppercase_digest);
    try std.testing.expectError(error.BadManifest, parseDiskIndex(arena, uppercase_digest, testDescriptor(uppercase_digest_hash)));
}

test "v1 disk indexes remain readable without changing their identity" {
    const allocator = std.testing.allocator;
    const encoded = try encodeCanonicalAlloc(
        allocator,
        testIndex(disk_index_kind_v1, &.{.{ .logical_chunk = 0, .digest = digest_b }}, &.{1}),
    );
    defer encoded.deinit(allocator);

    const parsed = try parseDiskIndex(allocator, encoded.bytes, testDescriptor(encoded.digest));
    defer parsed.deinit();
    try std.testing.expectEqualStrings(disk_index_kind_v1, parsed.value.kind);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.chunks.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.zero_chunks.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.zero_ranges.len);
}

test "v2 disk index rejects malformed and out-of-bounds ranges" {
    const descriptor = testDescriptor(digest_a);
    const one_zero = [_]DiskIndexZeroRange{.{ .start = 1, .count = 1 }};

    var index = testIndex(disk_index_kind, &.{.{ .logical_chunk = 0, .digest = digest_b }}, &.{});
    index.zero_ranges = &one_zero;
    try validateDiskIndex(index, descriptor);

    const zero_count = [_]DiskIndexZeroRange{.{ .start = 1, .count = 0 }};
    index.zero_ranges = &zero_count;
    try std.testing.expectError(error.BadManifest, validateDiskIndex(index, descriptor));

    const zero_out_of_bounds = [_]DiskIndexZeroRange{.{ .start = 1, .count = 2 }};
    index.zero_ranges = &zero_out_of_bounds;
    try std.testing.expectError(error.BadManifest, validateDiskIndex(index, descriptor));

    const zero_overlap = [_]DiskIndexZeroRange{.{ .start = 0, .count = 1 }};
    index.zero_ranges = &zero_overlap;
    try std.testing.expectError(error.BadManifest, validateDiskIndex(index, descriptor));

    const zero_gap = [_]DiskIndexZeroRange{.{ .start = 2, .count = 1 }};
    index.zero_ranges = &zero_gap;
    try std.testing.expectError(error.BadManifest, validateDiskIndex(index, descriptor));

    try std.testing.expectError(error.BadManifest, validateV2Shape(.{
        .kind = disk_index_kind,
        .logical_size = 8192,
        .chunk_size = 4096,
        .hash_algorithm = "blake3",
        .object_namespace = "rootfs/blake3",
        .chunk_ranges = &.{.{ .start = 0, .digests = "abc" }},
        .zero_ranges = &one_zero,
    }));
    try std.testing.expectError(error.BadManifest, validateV2Shape(.{
        .kind = disk_index_kind,
        .logical_size = 8192,
        .chunk_size = 4096,
        .hash_algorithm = "blake3",
        .object_namespace = "rootfs/blake3",
        .chunk_ranges = &.{.{ .start = std.math.maxInt(u64), .digests = digest_b[digest_prefix.len..] }},
        .zero_ranges = &one_zero,
    }));
}

test "v2 compact ranges encode a dense 32 GiB disk below the bounded index limit" {
    const allocator = std.testing.allocator;
    const chunk_size: u64 = 64 * 1024;
    const logical_size: u64 = 32 * 1024 * 1024 * 1024;
    const chunk_count = logical_size / chunk_size;
    const zero_tail = [_]DiskIndexZeroRange{.{ .start = 1, .count = chunk_count - 1 }};
    const encoded = try encodeCanonicalAlloc(allocator, .{
        .kind = disk_index_kind,
        .logical_size = logical_size,
        .chunk_size = chunk_size,
        .hash_algorithm = "blake3",
        .object_namespace = "rootfs/blake3",
        .chunks = &.{.{ .logical_chunk = 0, .digest = digest_b }},
        .zero_ranges = &zero_tail,
    });
    defer encoded.deinit(allocator);
    // This one-chunk index carries the same 32 GiB geometry plus a zero-range
    // object that a dense index omits, so replacing its one digest with the
    // complete unescaped hex blob is a conservative exact-size bound.
    const fixed_bytes = encoded.bytes.len - chunk.ChunkId.hex_len;
    const dense_bytes = try std.math.add(
        u64,
        fixed_bytes,
        try std.math.mul(u64, chunk_count, chunk.ChunkId.hex_len),
    );
    try std.testing.expect(dense_bytes < max_index_bytes);
    try std.testing.expect(std.mem.indexOf(u8, encoded.bytes, "\"start\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded.bytes, "\"logical_chunk\"") == null);
}

fn fuzzDiskIndexParse(_: void, s: *std.testing.Smith) !void {
    // Disk indexes may arrive from registries, bundles, or peers. They
    // must either fail closed or validate to a descriptor-bound, canonical map.
    var buf: [4096]u8 = undefined;
    const len = s.slice(&buf);
    const digest = try digestBytesAlloc(std.testing.allocator, buf[0..len]);
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

fn fuzzV2DiskIndexParse(_: void, s: *std.testing.Smith) !void {
    // Start close to a valid v2 document so mutations exercise range and
    // canonical validation instead of stopping at the JSON tokenizer.
    const allocator = std.testing.allocator;
    const encoded = try encodeCanonicalAlloc(
        allocator,
        testIndex(disk_index_kind, &.{.{ .logical_chunk = 0, .digest = digest_b }}, &.{1}),
    );
    defer encoded.deinit(allocator);
    const mutation_count = s.valueRangeAtMost(u8, 0, 4);
    for (0..mutation_count) |_| encoded.bytes[s.index(encoded.bytes.len)] = s.value(u8);
    const len = s.valueRangeAtMost(u32, 1, @intCast(encoded.bytes.len));
    const input = encoded.bytes[0..len];
    const digest = try digestBytesAlloc(allocator, input);
    defer allocator.free(digest);
    const parsed = parseDiskIndex(allocator, input, testDescriptor(digest)) catch return;
    parsed.deinit();
}

test "fuzz v2 ranged disk index decoder" {
    try std.testing.fuzz({}, fuzzV2DiskIndexParse, .{});
}
