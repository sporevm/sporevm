//! Content-addressed chunk identities.
//!
//! Every blob in a spore — memory chunks, disk chunks, machine-state blobs —
//! is addressed by the BLAKE3 hash of its contents. Chunk ids are the unit of
//! deduplication, verification, and exchange: a chunk received from any
//! source (local CAS, peer, registry) MUST be verified against its id before
//! use. See SECURITY.md.

const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;

/// A content-addressed chunk identity: the BLAKE3-256 digest of the chunk
/// bytes. Stable across hosts, platforms, and spore format versions.
pub const ChunkId = struct {
    pub const len = Blake3.digest_length; // 32 bytes
    pub const hex_len = len * 2;

    bytes: [len]u8,

    /// Compute the id of a chunk's contents.
    pub fn fromContents(contents: []const u8) ChunkId {
        var id: ChunkId = undefined;
        Blake3.hash(contents, &id.bytes, .{});
        return id;
    }

    /// Verify that `contents` matches this id. Constant-time comparison is
    /// not required (ids are not secrets), but verification before use is.
    pub fn matches(self: ChunkId, contents: []const u8) bool {
        const actual = fromContents(contents);
        return std.mem.eql(u8, &self.bytes, &actual.bytes);
    }

    /// Lowercase hex encoding, used in manifests and CAS paths.
    pub fn toHex(self: ChunkId) [hex_len]u8 {
        return std.fmt.bytesToHex(self.bytes, .lower);
    }

    /// Parse a lowercase or uppercase hex id, as found in manifests.
    pub fn fromHex(hex: []const u8) error{InvalidChunkId}!ChunkId {
        if (hex.len != hex_len) return error.InvalidChunkId;
        var id: ChunkId = undefined;
        _ = std.fmt.hexToBytes(&id.bytes, hex) catch return error.InvalidChunkId;
        return id;
    }

    pub fn eql(self: ChunkId, other: ChunkId) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

test "identical contents produce identical ids" {
    const a = ChunkId.fromContents("the same bytes");
    const b = ChunkId.fromContents("the same bytes");
    try std.testing.expect(a.eql(b));
}

test "different contents produce different ids" {
    const a = ChunkId.fromContents("some bytes");
    const b = ChunkId.fromContents("other bytes");
    try std.testing.expect(!a.eql(b));
}

test "hex round-trip" {
    const id = ChunkId.fromContents("round trip me");
    const hex = id.toHex();
    try std.testing.expectEqual(@as(usize, ChunkId.hex_len), hex.len);
    const parsed = try ChunkId.fromHex(&hex);
    try std.testing.expect(id.eql(parsed));
}

test "fromHex rejects malformed input" {
    try std.testing.expectError(error.InvalidChunkId, ChunkId.fromHex("abc"));
    const not_hex = "zz" ** 32;
    try std.testing.expectError(error.InvalidChunkId, ChunkId.fromHex(not_hex));
}

test "verification detects corruption" {
    const id = ChunkId.fromContents("pristine chunk");
    try std.testing.expect(id.matches("pristine chunk"));
    try std.testing.expect(!id.matches("tampered chunk"));
}
