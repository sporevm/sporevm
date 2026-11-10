const std = @import("std");
const chunk = @import("../chunk.zig");

const Io = std.Io;
const Blake3 = std.crypto.hash.Blake3;
const Sha256 = std.crypto.hash.sha2.Sha256;

const min_rootfs_size_bytes: u64 = 512 << 20;
const min_rootfs_inodes: u64 = 65_536;
const rootfs_inode_headroom: u64 = 4096;
const rootfs_headroom_bytes: u64 = 128 << 20;
const rootfs_align_bytes: u64 = 4 << 20;
pub const rootfs_ext4_block_size: u32 = 4096;
pub const rootfs_ext4_inode_size: u16 = 256;
pub const rootfs_ext4_inodes_per_block: u32 = rootfs_ext4_block_size / @as(u32, rootfs_ext4_inode_size);

pub const Determinism = struct {
    uuid: [36]u8,
    uuid_bytes: [16]u8,
    hash_seed: [36]u8,
    hash_seed_bytes: [16]u8,

    pub fn fromDigest(digest: []const u8) Determinism {
        const uuid = uuidFromDigest("sporevm-rootfs-ext4-uuid", digest);
        const hash_seed = uuidFromDigest("sporevm-rootfs-ext4-hash-seed", digest);
        return .{
            .uuid = uuid.text,
            .uuid_bytes = uuid.bytes,
            .hash_seed = hash_seed.text,
            .hash_seed_bytes = hash_seed.bytes,
        };
    }
};

const DerivedUuid = struct {
    text: [36]u8,
    bytes: [16]u8,
};

pub fn computeImageSize(content_bytes: u64) u64 {
    var target = content_bytes + (content_bytes / 2) + rootfs_headroom_bytes;
    if (target < min_rootfs_size_bytes) target = min_rootfs_size_bytes;
    const remainder = target % rootfs_align_bytes;
    if (remainder == 0) return target;
    return target + (rootfs_align_bytes - remainder);
}

pub fn computeImageInodes(entry_count: u64) u64 {
    const with_headroom = entry_count + (entry_count / 10) + rootfs_inode_headroom;
    const target = @max(min_rootfs_inodes, with_headroom);
    const inodes_per_block: u64 = rootfs_ext4_inodes_per_block;
    const remainder = target % inodes_per_block;
    if (remainder == 0) return target;
    return target + (inodes_per_block - remainder);
}

pub fn ensureParentDir(io: Io, path: []const u8) !void {
    const parent = parentPath(path);
    if (parent.len == 0 or std.mem.eql(u8, parent, "/")) return;
    if (!Io.Dir.path.isAbsolute(parent)) {
        try Io.Dir.cwd().createDirPath(io, parent);
        return;
    }

    var existing = Io.Dir.openDirAbsolute(io, parent, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try ensureParentDir(io, parent);
            Io.Dir.createDirAbsolute(io, parent, .default_dir) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => {},
                else => |e| return e,
            };
            return;
        },
        else => |e| return e,
    };
    existing.close(io);
}

pub fn createEmptyFile(io: Io, path: []const u8, size: u64) !void {
    var file = try createFileAtPath(io, path);
    defer file.close(io);
    if (size > 0) {
        try file.writePositionalAll(io, &[_]u8{0}, size - 1);
    }
}

pub fn blake3File(io: Io, path: []const u8) ![chunk.ChunkId.hex_len]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader_buf: [64 * 1024]u8 = undefined;
    var reader: Io.File.Reader = .initStreaming(file, io, &reader_buf);
    var h = Blake3.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try reader.interface.readSliceShort(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var out: [chunk.ChunkId.len]u8 = undefined;
    h.final(&out);
    return std.fmt.bytesToHex(out, .lower);
}

fn createFileAtPath(io: Io, path: []const u8) !Io.File {
    if (Io.Dir.path.isAbsolute(path)) {
        return Io.Dir.createFileAbsolute(io, path, .{});
    }
    return Io.Dir.cwd().createFile(io, path, .{});
}

pub fn writeFileAtPath(io: Io, path: []const u8, data: []const u8) !void {
    var file = try createFileAtPath(io, path);
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

fn uuidFromDigest(label: []const u8, digest: []const u8) DerivedUuid {
    var h = Sha256.init(.{});
    h.update(label);
    h.update(&[_]u8{0});
    h.update(digest);
    var hash: [Sha256.digest_length]u8 = undefined;
    h.final(&hash);

    const hex = std.fmt.bytesToHex(hash[0..16].*, .lower);
    return .{
        .text = uuidText(hex),
        .bytes = hash[0..16].*,
    };
}

fn uuidText(hex: [32]u8) [36]u8 {
    var out: [36]u8 = undefined;
    @memcpy(out[0..8], hex[0..8]);
    out[8] = '-';
    @memcpy(out[9..13], hex[8..12]);
    out[13] = '-';
    @memcpy(out[14..18], hex[12..16]);
    out[18] = '-';
    @memcpy(out[19..23], hex[16..20]);
    out[23] = '-';
    @memcpy(out[24..36], hex[20..32]);
    return out;
}

fn parentPath(rel: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, rel, '/') orelse return "";
    return rel[0..slash];
}

test "compute rootfs image size keeps minimum and alignment" {
    try std.testing.expectEqual(@as(u64, min_rootfs_size_bytes), computeImageSize(1));
    const size = computeImageSize(900 << 20);
    try std.testing.expectEqual(@as(u64, 0), size % rootfs_align_bytes);
    try std.testing.expect(size > 900 << 20);
}

test "compute rootfs inode count keeps minimum and headroom" {
    try std.testing.expectEqual(@as(u64, min_rootfs_inodes), computeImageInodes(1));
    try std.testing.expectEqual(@as(u64, 114_096), computeImageInodes(100_000));
}

test "compute rootfs inode count aligns for native writer packing" {
    const inode_count = computeImageInodes(100_001);
    try std.testing.expectEqual(@as(u64, 114_112), inode_count);
    try std.testing.expectEqual(@as(u64, 0), inode_count % rootfs_ext4_inodes_per_block);
}
