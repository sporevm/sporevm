//! Packs: store files that each hold a run of the objects a disk index names,
//! so a reader fills a cold cache with a few large ranged reads instead of one
//! read per object. A store with 64 KiB objects costs a reader about 50 ms of
//! S3 time to first byte per object, however small the object is.
//!
//! A pack is a function of the index alone, so a reader needs no descriptor
//! file: it derives each pack's name and each member's offset from the index
//! it already verified. Walking the index's chunks in logical order, a pack
//! ends after a chunk whose digest ends in a zero byte, about one chunk in
//! 256, or before a chunk that would take it past `max_pack_bytes`. A chunk
//! already in the pack is not added again. The pack's file holds its members'
//! bytes end to end, and its name is the BLAKE3 digest of `name_domain`
//! followed by its members' 32-byte digests.
//!
//! Boundaries depend only on the chunks themselves, so two indexes that share
//! a run of chunks share the packs inside it: a checkpoint's disk reuses most
//! of its image's packs, and a push uploads only the packs that changed.
//!
//! Pack bytes are untrusted like every store byte. A reader checks each member
//! against its own digest and reads the store's `objects/` file when a pack is
//! missing or wrong.

const std = @import("std");
const chunk = @import("chunk.zig");
const disk_index = @import("disk_index.zig");

const Blake3 = std.crypto.hash.Blake3;

/// A pack holds at most this much, which bounds what a writer assembles in
/// memory. A chunk larger than this is a pack of its own.
pub const max_pack_bytes: u64 = 64 * 1024 * 1024;

/// Prefixes the member digests a pack's name hashes. A different layout of
/// pack bytes needs a different domain, so it never reads as this one.
const name_domain = "spore-pack-v1\n";

pub const Member = struct {
    id: chunk.ChunkId,
    /// Where the member's bytes start in the pack file.
    offset: u64,
    len: usize,
};

pub const Pack = struct {
    name: [chunk.ChunkId.hex_len]u8,
    members: []const Member,

    pub fn len(self: Pack) u64 {
        const last = self.members[self.members.len - 1];
        return last.offset + last.len;
    }
};

/// The store path of the pack `name`.
pub fn pathAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "packs/blake3/{s}", .{name});
}

/// The packs of an index with `chunks`, in order. `logical_size` and
/// `chunk_size` are the index's. Allocates into `arena`.
pub fn packsAlloc(
    arena: std.mem.Allocator,
    logical_size: u64,
    chunk_size: u64,
    chunks: []const disk_index.DiskIndexChunk,
) ![]const Pack {
    var packs: std.ArrayList(Pack) = .empty;
    var open: Open = .{};
    for (chunks) |entry| {
        if (open.ids.contains(entry.id)) continue;
        const start = std.math.mul(u64, entry.logical_chunk, chunk_size) catch return error.BadManifest;
        if (start >= logical_size) return error.BadManifest;
        const len = std.math.cast(usize, @min(chunk_size, logical_size - start)) orelse return error.BadManifest;
        if (open.members.items.len != 0 and open.bytes + len > max_pack_bytes) try packs.append(arena, try open.close(arena));
        try open.ids.put(arena, entry.id, {});
        try open.members.append(arena, .{ .id = entry.id, .offset = open.bytes, .len = len });
        open.bytes += len;
        if (entry.id.bytes[chunk.ChunkId.len - 1] == 0) try packs.append(arena, try open.close(arena));
    }
    if (open.members.items.len != 0) try packs.append(arena, try open.close(arena));
    return packs.items;
}

/// The pack being filled.
const Open = struct {
    members: std.ArrayList(Member) = .empty,
    ids: std.AutoHashMapUnmanaged(chunk.ChunkId, void) = .empty,
    bytes: u64 = 0,

    fn close(self: *Open, arena: std.mem.Allocator) !Pack {
        var hasher = Blake3.init(.{});
        hasher.update(name_domain);
        for (self.members.items) |member| hasher.update(&member.id.bytes);
        var digest: [chunk.ChunkId.len]u8 = undefined;
        hasher.final(&digest);
        const pack: Pack = .{ .name = std.fmt.bytesToHex(digest, .lower), .members = try arena.dupe(Member, self.members.items) };
        self.members.clearRetainingCapacity();
        self.ids.clearRetainingCapacity();
        self.bytes = 0;
        return pack;
    }
};

fn testId(first: u8, last: u8) chunk.ChunkId {
    var id: chunk.ChunkId = .{ .bytes = @splat(0x55) };
    id.bytes[0] = first;
    id.bytes[chunk.ChunkId.len - 1] = last;
    return id;
}

fn testChunks(arena: std.mem.Allocator, ids: []const chunk.ChunkId) ![]const disk_index.DiskIndexChunk {
    const chunks = try arena.alloc(disk_index.DiskIndexChunk, ids.len);
    for (chunks, ids, 0..) |*entry, id, i| entry.* = .{ .logical_chunk = i, .id = id };
    return chunks;
}

test "a pack ends at a boundary chunk, holds a repeated chunk once and keeps its name when earlier chunks change" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = testId(1, 7);
    const b = testId(2, 7);
    const end = testId(3, 0);
    const c = testId(4, 7);
    // The last chunk of the disk, 100 bytes.
    const tail = testId(5, 7);

    const packs = try packsAlloc(arena, 6 * 4096 + 100, 4096, try testChunks(arena, &.{ a, b, a, end, c, a, tail }));
    try std.testing.expectEqual(2, packs.len);
    try std.testing.expectEqualSlices(Member, &.{
        .{ .id = a, .offset = 0, .len = 4096 },
        .{ .id = b, .offset = 4096, .len = 4096 },
        .{ .id = end, .offset = 8192, .len = 4096 },
    }, packs[0].members);
    try std.testing.expectEqual(3 * 4096, packs[0].len());
    // `a` is in the first pack too: a pack holds every chunk of its own run.
    const second = [_]Member{
        .{ .id = c, .offset = 0, .len = 4096 },
        .{ .id = a, .offset = 4096, .len = 4096 },
        .{ .id = tail, .offset = 8192, .len = 100 },
    };
    try std.testing.expectEqualSlices(Member, &second, packs[1].members);

    // BLAKE3 of "spore-pack-v1\n" and the three member digests, from the
    // reference implementation. A different name orphans stored packs.
    try std.testing.expectEqualStrings("384a017b9f08438fcae65713e6641277dc6ee326428bdea8c939520e9e732140", &packs[0].name);

    const changed = try packsAlloc(arena, 4 * 4096 + 100, 4096, try testChunks(arena, &.{ b, end, c, a, tail }));
    try std.testing.expectEqual(2, changed.len);
    try std.testing.expect(!std.mem.eql(u8, &packs[0].name, &changed[0].name));
    try std.testing.expectEqualStrings(&packs[1].name, &changed[1].name);
    try std.testing.expectEqualSlices(Member, &second, changed[1].members);
}

test "a pack closes before the chunk that would take it past the size limit" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const chunk_size = max_pack_bytes / 2 + 1;
    const packs = try packsAlloc(arena, 3 * chunk_size, chunk_size, try testChunks(arena, &.{ testId(1, 7), testId(2, 7), testId(3, 7) }));
    try std.testing.expectEqual(3, packs.len);
    for (packs) |pack| try std.testing.expectEqual(chunk_size, pack.len());
}
