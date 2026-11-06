//! Manifest-bound chunk-mapped disk index codec.
//!
//! This is the portable restore-authority codec for chunked rootfs and disk
//! state and for the memory index in spore manifests. `spore-disk-index-v2` is
//! the only encoding; earlier kinds fail as too old.

const std = @import("std");
const chunk = @import("chunk.zig");

pub const disk_index_kind = "spore-disk-index-v2";
pub const max_index_bytes: usize = 64 * 1024 * 1024;
pub const digest_prefix = "blake3:";

/// Index kinds written by earlier releases. Readers report them as too old.
const retired_kinds = [_][]const u8{ "rootfs-block-index-v0", "spore-disk-index-v1" };

pub const Error = error{
    BadManifest,
    FormatTooOld,
    OutOfMemory,
};

pub const DiskIndexChunk = struct {
    logical_chunk: u64,
    id: chunk.ChunkId,
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
    zero_ranges: []const DiskIndexZeroRange = &.{},
};

pub const DiskIndexChunkRangeV2 = struct {
    start: u64,
    /// Concatenated lowercase BLAKE3 hex digests, one 32-byte digest per
    /// logical chunk. The common algorithm and prefix live in the index.
    digests: []const u8,
};

/// The encoded index. Memory manifests embed the same fields.
pub const DiskIndexV2 = struct {
    kind: []const u8,
    logical_size: u64,
    chunk_size: u64,
    hash_algorithm: []const u8,
    object_namespace: []const u8,
    chunk_ranges: []const DiskIndexChunkRangeV2 = &.{},
    zero_ranges: []const DiskIndexZeroRange = &.{},
};

/// A decoded index that owns every slice in `value`.
pub const ParsedDiskIndex = struct {
    allocator: std.mem.Allocator,
    value: DiskIndex,

    pub fn deinit(self: ParsedDiskIndex) void {
        self.allocator.free(self.value.hash_algorithm);
        self.allocator.free(self.value.object_namespace);
        self.allocator.free(self.value.chunks);
        self.allocator.free(self.value.zero_ranges);
    }
};

/// Accepts the current kind and reports earlier kinds as too old.
pub fn checkKind(kind: []const u8) Error!void {
    if (std.mem.eql(u8, kind, disk_index_kind)) return;
    for (retired_kinds) |retired| if (std.mem.eql(u8, kind, retired)) return error.FormatTooOld;
    return error.BadManifest;
}

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

    try checkKind(kind.value.kind);
    const result = try parseV2(allocator, bytes);
    errdefer result.deinit();
    try validateDiskIndex(result.value, descriptor);
    try expectCanonical(bytes, result.value);
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

fn parseV2(allocator: std.mem.Allocator, bytes: []const u8) Error!ParsedDiskIndex {
    // Strings stay slices of `bytes`, so the packed digests are never copied;
    // only the decoded chunk ids outlive this function.
    const encoded = std.json.parseFromSlice(DiskIndexV2, allocator, bytes, .{
        .allocate = .alloc_if_needed,
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadManifest,
    };
    defer encoded.deinit();

    const chunks = try decodeChunkRanges(allocator, encoded.value);
    errdefer allocator.free(chunks);
    const zero_ranges = try allocator.dupe(DiskIndexZeroRange, encoded.value.zero_ranges);
    errdefer allocator.free(zero_ranges);
    const hash_algorithm = try allocator.dupe(u8, encoded.value.hash_algorithm);
    errdefer allocator.free(hash_algorithm);
    return .{ .allocator = allocator, .value = .{
        .kind = disk_index_kind,
        .logical_size = encoded.value.logical_size,
        .chunk_size = encoded.value.chunk_size,
        .hash_algorithm = hash_algorithm,
        .object_namespace = try allocator.dupe(u8, encoded.value.object_namespace),
        .chunks = chunks,
        .zero_ranges = zero_ranges,
    } };
}

/// Validates the encoded ranges and expands the packed digests into one
/// chunk id per nonzero chunk. Digests must be lowercase hex.
pub fn decodeChunkRanges(allocator: std.mem.Allocator, index: DiskIndexV2) Error![]DiskIndexChunk {
    try validateV2Shape(index);

    var nonzero_count: u64 = 0;
    for (index.chunk_ranges) |range| {
        nonzero_count = std.math.add(u64, nonzero_count, range.digests.len / chunk.ChunkId.hex_len) catch return error.BadManifest;
    }
    const chunk_len = std.math.cast(usize, nonzero_count) orelse return error.BadManifest;
    const chunks = try allocator.alloc(DiskIndexChunk, chunk_len);
    errdefer allocator.free(chunks);

    var entry_index: usize = 0;
    for (index.chunk_ranges) |range| {
        const count = range.digests.len / chunk.ChunkId.hex_len;
        for (0..count) |offset| {
            chunks[entry_index] = .{
                .logical_chunk = std.math.add(u64, range.start, offset) catch return error.BadManifest,
                .id = idFromLowerHex(range.digests[offset * chunk.ChunkId.hex_len ..][0..chunk.ChunkId.hex_len]) orelse return error.BadManifest,
            };
            entry_index += 1;
        }
    }
    return chunks;
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
    try checkKind(index.kind);

    const chunk_count = try indexChunkCount(index.logical_size, index.chunk_size);
    var zero_count: u64 = 0;
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
        previous_chunk = entry.logical_chunk;
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
    var count: u64 = 0;
    for (index.zero_ranges) |range| count = std.math.add(u64, count, range.count) catch return error.BadManifest;
    return count;
}

pub fn isZeroChunk(index: DiskIndex, logical_chunk: u64) bool {
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

/// Records a zero chunk, extending the last range when contiguous. Callers
/// append in ascending logical-chunk order.
pub fn appendZeroChunk(allocator: std.mem.Allocator, ranges: *std.ArrayList(DiskIndexZeroRange), logical_chunk: u64) error{OutOfMemory}!void {
    if (ranges.items.len != 0) {
        const last = &ranges.items[ranges.items.len - 1];
        if (last.start + last.count == logical_chunk) {
            last.count += 1;
            return;
        }
    }
    try ranges.append(allocator, .{ .start = logical_chunk, .count = 1 });
}

/// Decodes one packed digest in a single pass, so a dense index costs one
/// table lookup per hex digit rather than a separate check and parse.
fn idFromLowerHex(hex: *const [chunk.ChunkId.hex_len]u8) ?chunk.ChunkId {
    var id: chunk.ChunkId = undefined;
    var invalid: u8 = 0;
    for (&id.bytes, 0..) |*byte, i| {
        const high = lower_hex_values[hex[2 * i]];
        const low = lower_hex_values[hex[2 * i + 1]];
        invalid |= high | low;
        byte.* = (high << 4) | (low & 0x0f);
    }
    if (invalid > 0x0f) return null;
    return id;
}

/// Maps each lowercase hex digit to its value and every other byte to 0xff.
const lower_hex_values: [256]u8 = values: {
    var values = [_]u8{0xff} ** 256;
    for ("0123456789abcdef", 0..) |digit, value| values[digit] = value;
    break :values values;
};

fn validateIndexDigest(bytes: []const u8, digest: []const u8) Error!void {
    if (!std.mem.startsWith(u8, digest, digest_prefix)) return error.BadManifest;
    const actual_hex = chunk.ChunkId.fromContents(bytes).toHex();
    if (!std.mem.eql(u8, digest[digest_prefix.len..], &actual_hex)) return error.BadManifest;
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
    try checkKind(index.kind);
    return stringifyBoundedAlloc(allocator, Encoder{ .index = index });
}

const Encoder = struct {
    index: DiskIndex,

    pub fn jsonStringify(self: Encoder, jws: *std.json.Stringify) std.json.Stringify.Error!void {
        try jws.beginObject();
        try writeFields(jws, self.index);
        try jws.endObject();
    }
};

const json_options: std.json.Stringify.Options = .{
    .whitespace = .indent_2,
    .emit_null_optional_fields = false,
};

/// Fails unless encoding `index` reproduces `bytes` exactly. The encoding is
/// compared as it is written, so it is never held in memory.
fn expectCanonical(bytes: []const u8, index: DiskIndex) Error!void {
    var buffer: [4096]u8 = undefined;
    var matcher: MatchingWriter = .{ .expected = bytes, .writer = .{
        .buffer = &buffer,
        .vtable = &.{ .drain = MatchingWriter.drain },
    } };
    std.json.Stringify.value(Encoder{ .index = index }, json_options, &matcher.writer) catch return error.BadManifest;
    matcher.writer.flush() catch return error.BadManifest;
    if (matcher.matched != bytes.len) return error.BadManifest;
}

/// A writer that fails as soon as its output stops matching `expected`.
const MatchingWriter = struct {
    expected: []const u8,
    matched: usize = 0,
    writer: std.Io.Writer,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *MatchingWriter = @alignCast(@fieldParentPtr("writer", w));
        try self.match(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            try self.match(slice);
            n += slice.len;
        }
        for (0..splat) |_| try self.match(data[data.len - 1]);
        return n + splat * data[data.len - 1].len;
    }

    fn match(self: *MatchingWriter, bytes: []const u8) std.Io.Writer.Error!void {
        const rest = self.expected[self.matched..];
        if (bytes.len > rest.len or !std.mem.eql(u8, bytes, rest[0..bytes.len])) return error.WriteFailed;
        self.matched += bytes.len;
    }
};

/// Writes the encoded index fields into an open JSON object, packing each run
/// of contiguous nonzero chunks into one `chunk_ranges` entry. Memory
/// manifests embed these fields.
pub fn writeFields(jws: *std.json.Stringify, index: DiskIndex) std.json.Stringify.Error!void {
    try jws.objectField("kind");
    try jws.write(index.kind);
    try jws.objectField("logical_size");
    try jws.write(index.logical_size);
    try jws.objectField("chunk_size");
    try jws.write(index.chunk_size);
    try jws.objectField("hash_algorithm");
    try jws.write(index.hash_algorithm);
    try jws.objectField("object_namespace");
    try jws.write(index.object_namespace);
    try jws.objectField("chunk_ranges");
    try jws.beginArray();
    var start_index: usize = 0;
    while (start_index < index.chunks.len) {
        var end_index = start_index + 1;
        while (end_index < index.chunks.len and index.chunks[end_index].logical_chunk == index.chunks[end_index - 1].logical_chunk +% 1) : (end_index += 1) {}
        try jws.beginObject();
        try jws.objectField("start");
        try jws.write(index.chunks[start_index].logical_chunk);
        try jws.objectField("digests");
        // Lowercase hex needs no escaping, so the packed string is streamed
        // rather than allocated.
        try jws.beginWriteRaw();
        try jws.writer.writeByte('"');
        for (index.chunks[start_index..end_index]) |entry| {
            const hex = entry.id.toHex();
            try jws.writer.writeAll(&hex);
        }
        try jws.writer.writeByte('"');
        jws.endWriteRaw();
        try jws.endObject();
        start_index = end_index;
    }
    try jws.endArray();
    try jws.objectField("zero_ranges");
    try jws.write(index.zero_ranges);
}

fn stringifyBoundedAlloc(allocator: std.mem.Allocator, value: anytype) Error![]u8 {
    const bytes = std.json.Stringify.valueAlloc(allocator, value, json_options) catch return error.OutOfMemory;
    errdefer allocator.free(bytes);
    if (bytes.len == 0 or bytes.len > max_index_bytes) return error.BadManifest;
    return bytes;
}

fn digestBytesAlloc(allocator: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    const id = chunk.ChunkId.fromContents(bytes);
    const hex = id.toHex();
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ digest_prefix, hex[0..] }) catch return error.OutOfMemory;
}

const digest_a = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const id_b: chunk.ChunkId = .{ .bytes = @splat(0xbb) };
const id_c: chunk.ChunkId = .{ .bytes = @splat(0xcc) };

fn testDescriptor(index_digest: []const u8) Descriptor {
    return .{
        .logical_size = 8192,
        .chunk_size = 4096,
        .hash_algorithm = "blake3",
        .index_digest = index_digest,
        .object_namespace = "rootfs/blake3",
    };
}

const zero_chunk_0 = [_]DiskIndexZeroRange{.{ .start = 0, .count = 1 }};
const zero_chunk_1 = [_]DiskIndexZeroRange{.{ .start = 1, .count = 1 }};

fn testIndex(kind: []const u8, chunks: []const DiskIndexChunk, zero_ranges: []const DiskIndexZeroRange) DiskIndex {
    return .{
        .kind = kind,
        .logical_size = 8192,
        .chunk_size = 4096,
        .hash_algorithm = "blake3",
        .object_namespace = "rootfs/blake3",
        .chunks = chunks,
        .zero_ranges = zero_ranges,
    };
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
        testIndex(disk_index_kind, &.{.{ .logical_chunk = 0, .id = id_b }}, &zero_chunk_1),
    );
    return .{
        .descriptor = testDescriptor(encoded.digest),
        .bytes = encoded.bytes,
    };
}

test "v2 disk index canonical encoding has stable bytes and digest" {
    const allocator = std.testing.allocator;
    const encoded = try encodeCanonicalAlloc(
        allocator,
        testIndex(disk_index_kind, &.{.{ .logical_chunk = 0, .id = id_b }}, &zero_chunk_1),
    );
    defer encoded.deinit(allocator);

    try std.testing.expectEqualStrings(validV2IndexJson(), encoded.bytes);
    try std.testing.expectEqualStrings("blake3:69fefbc2cd610a7d0d66ffe56978513273fbd38fb0ad905c1c9e40c04c86bcf0", encoded.digest);
}

test "disk index fixtures decode and re-encode to the same bytes" {
    const allocator = std.testing.allocator;
    const fixtures = [_][]const u8{
        "test/image/rootfs-index.json",
        "test/image/worker-conformance/targets/linux-amd64/rootfs-index.json",
        "test/image/worker-conformance/targets/linux-arm64/rootfs-index.json",
    };
    for (fixtures) |path| {
        const file = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_index_bytes));
        defer allocator.free(file);
        const bytes = std.mem.trimEnd(u8, file, "\n");
        const parsed = try parseSelfDescribedDiskIndex(allocator, bytes);
        defer parsed.deinit();
        const encoded = try encodeCanonicalAlloc(allocator, parsed.value);
        defer encoded.deinit(allocator);
        try std.testing.expectEqualStrings(bytes, encoded.bytes);
        const expected_digest = try digestBytesAlloc(allocator, bytes);
        defer allocator.free(expected_digest);
        try std.testing.expectEqualStrings(expected_digest, encoded.digest);
    }
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
    try std.testing.expect(parsed.value.chunks[0].id.eql(id_b));
    try std.testing.expectEqual(@as(usize, 1), parsed.value.zero_ranges.len);
    try std.testing.expectEqual(DiskIndexZeroRange{ .start = 1, .count = 1 }, parsed.value.zero_ranges[0]);
}

test "disk index reports retired kinds as too old" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const legacy =
        \\{"kind":"rootfs-block-index-v0","logical_size":8192,"chunk_size":4096,"hash_algorithm":"blake3","object_namespace":"rootfs/blake3","chunks":[{"logical_chunk":0,"digest":"blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}],"zero_chunks":[1]}
    ;
    // Canonical bytes written by the removed v1 encoder.
    const v1 =
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
    for (&[_][]const u8{ legacy, v1 }) |bytes| {
        const digest = try digestBytesAlloc(arena, bytes);
        try std.testing.expectError(error.FormatTooOld, parseDiskIndex(arena, bytes, testDescriptor(digest)));
        try std.testing.expectError(error.FormatTooOld, parseSelfDescribedDiskIndex(arena, bytes));
    }

    const v1_index = testIndex("spore-disk-index-v1", &.{.{ .logical_chunk = 0, .id = id_b }}, &zero_chunk_1);
    try std.testing.expectError(error.FormatTooOld, validateDiskIndex(v1_index, testDescriptor(digest_a)));
    try std.testing.expectError(error.FormatTooOld, encodeCanonicalAlloc(arena, v1_index));
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
    var wrong_kind = testIndex(disk_index_kind, &.{.{ .logical_chunk = 0, .id = id_b }}, &zero_chunk_1);
    wrong_kind.kind = "unknown-rootfs-index-v0";
    try std.testing.expectError(error.BadManifest, validateDiskIndex(wrong_kind, descriptor));

    var wrong_index_algorithm = testIndex(disk_index_kind, &.{.{ .logical_chunk = 0, .id = id_b }}, &zero_chunk_1);
    wrong_index_algorithm.hash_algorithm = "sha256";
    try std.testing.expectError(error.BadManifest, validateDiskIndex(wrong_index_algorithm, descriptor));

    var wrong_index_namespace = testIndex(disk_index_kind, &.{.{ .logical_chunk = 0, .id = id_b }}, &zero_chunk_1);
    wrong_index_namespace.object_namespace = "../rootfs";
    try std.testing.expectError(error.BadManifest, validateDiskIndex(wrong_index_namespace, descriptor));
}

test "manifest-bound disk index rejects non-canonical chunk tables" {
    try std.testing.expectError(error.BadManifest, validateDiskIndex(testIndex(
        disk_index_kind,
        &.{
            .{ .logical_chunk = 0, .id = id_b },
            .{ .logical_chunk = 0, .id = id_c },
        },
        &.{},
    ), testDescriptor(digest_a)));

    try std.testing.expectError(error.BadManifest, validateDiskIndex(testIndex(
        disk_index_kind,
        &.{
            .{ .logical_chunk = 1, .id = id_b },
            .{ .logical_chunk = 0, .id = id_c },
        },
        &.{},
    ), testDescriptor(digest_a)));

    try std.testing.expectError(error.BadManifest, validateDiskIndex(
        testIndex(disk_index_kind, &.{.{ .logical_chunk = 2, .id = id_b }}, &zero_chunk_0),
        testDescriptor(digest_a),
    ));

    try std.testing.expectError(error.BadManifest, validateDiskIndex(
        testIndex(disk_index_kind, &.{.{ .logical_chunk = 0, .id = id_b }}, &zero_chunk_0),
        testDescriptor(digest_a),
    ));

    try std.testing.expectError(error.BadManifest, validateDiskIndex(
        testIndex(disk_index_kind, &.{.{ .logical_chunk = 0, .id = id_b }}, &.{}),
        testDescriptor(digest_a),
    ));
}

test "manifest-bound disk index rejects non-canonical byte encodings" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const compact =
        \\{"kind":"spore-disk-index-v2","logical_size":8192,"chunk_size":4096,"hash_algorithm":"blake3","object_namespace":"rootfs/blake3","chunk_ranges":[{"start":0,"digests":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}],"zero_ranges":[{"start":1,"count":1}]}
    ;
    const reordered =
        \\{"logical_size":8192,"kind":"spore-disk-index-v2","chunk_size":4096,"hash_algorithm":"blake3","object_namespace":"rootfs/blake3","chunk_ranges":[{"start":0,"digests":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}],"zero_ranges":[{"start":1,"count":1}]}
    ;
    const uppercase_digest = try std.mem.replaceOwned(u8, arena, validV2IndexJson(), "bbbb", "BBBB");
    for (&[_][]const u8{ compact, reordered, uppercase_digest }) |bytes| {
        const digest = try digestBytesAlloc(arena, bytes);
        try std.testing.expectError(error.BadManifest, parseDiskIndex(arena, bytes, testDescriptor(digest)));
    }
}

test "v2 disk index rejects malformed and out-of-bounds ranges" {
    const descriptor = testDescriptor(digest_a);
    const one_zero = [_]DiskIndexZeroRange{.{ .start = 1, .count = 1 }};

    var index = testIndex(disk_index_kind, &.{.{ .logical_chunk = 0, .id = id_b }}, &.{});
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
        .chunk_ranges = &.{.{ .start = std.math.maxInt(u64), .digests = &id_b.toHex() }},
        .zero_ranges = &one_zero,
    }));
}

test "chunk range digests must be lowercase hex" {
    // Memory manifests decode their index through decodeChunkRanges alone,
    // without the canonical re-encoding check, so the decoder enforces case.
    const allocator = std.testing.allocator;
    const lower = id_b.toHex() ++ id_c.toHex();
    var encoded: DiskIndexV2 = .{
        .kind = disk_index_kind,
        .logical_size = 8192,
        .chunk_size = 4096,
        .hash_algorithm = "blake3",
        .object_namespace = "rootfs/blake3",
        .chunk_ranges = &.{.{ .start = 0, .digests = &lower }},
    };
    const chunks = try decodeChunkRanges(allocator, encoded);
    defer allocator.free(chunks);
    try std.testing.expectEqual(@as(usize, 2), chunks.len);
    try std.testing.expect(chunks[0].id.eql(id_b) and chunks[1].id.eql(id_c));
    try std.testing.expectEqual(@as(u64, 1), chunks[1].logical_chunk);

    for ([_]u8{ 'B', 'g', '/', ':', '`', 0, 0xff }) |bad| {
        for ([_]usize{ 0, 63, 64, 127 }) |position| {
            var digests = lower;
            digests[position] = bad;
            encoded.chunk_ranges = &.{.{ .start = 0, .digests = &digests }};
            try std.testing.expectError(error.BadManifest, decodeChunkRanges(allocator, encoded));
        }
    }
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
        testIndex(disk_index_kind, &.{.{ .logical_chunk = 0, .id = id_b }}, &zero_chunk_1),
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
