const std = @import("std");
const chunk = @import("../chunk.zig");
const ownership = @import("ownership.zig");

const Io = std.Io;
const Blake3 = std.crypto.hash.Blake3;
const Sha256 = std.crypto.hash.sha2.Sha256;

const min_rootfs_size_bytes: u64 = 512 << 20;
const min_rootfs_inodes: u64 = 65_536;
const rootfs_inode_headroom: u64 = 4096;
const rootfs_headroom_bytes: u64 = 128 << 20;
const rootfs_align_bytes: u64 = 4 << 20;
const ext4_superblock_offset: u64 = 1024;
const ext4_superblock_size: usize = 1024;
const ext4_feature_sparse_super: u32 = 0x0001;
const deterministic_epoch: Io.Timestamp = .{ .nanoseconds = 0 };

pub const Determinism = struct {
    uuid: [36]u8,
    uuid_bytes: [16]u8,
    hash_seed: [36]u8,

    pub fn fromDigest(digest: []const u8) Determinism {
        const uuid = uuidFromDigest("sporevm-rootfs-ext4-uuid", digest);
        return .{
            .uuid = uuid.text,
            .uuid_bytes = uuid.bytes,
            .hash_seed = uuidFromDigest("sporevm-rootfs-ext4-hash-seed", digest).text,
        };
    }
};

const DerivedUuid = struct {
    text: [36]u8,
    bytes: [16]u8,
};

pub fn dirContentSize(io: Io, dir: Io.Dir) !u64 {
    var total: u64 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                var child = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer child.close(io);
                total += try dirContentSize(io, child);
            },
            .file => {
                const stat = try dir.statFile(io, entry.name, .{});
                total += stat.size;
            },
            else => {},
        }
    }
    return total;
}

pub fn dirEntryCount(io: Io, dir: Io.Dir) !u64 {
    var total: u64 = 1; // Include the directory itself.
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        total += 1;
        if (entry.kind == .directory) {
            var child = try dir.openDir(io, entry.name, .{ .iterate = true });
            defer child.close(io);
            total += try dirEntryCount(io, child) - 1;
        }
    }
    return total;
}

pub fn computeImageSize(content_bytes: u64) u64 {
    var target = content_bytes + (content_bytes / 2) + rootfs_headroom_bytes;
    if (target < min_rootfs_size_bytes) target = min_rootfs_size_bytes;
    const remainder = target % rootfs_align_bytes;
    if (remainder == 0) return target;
    return target + (rootfs_align_bytes - remainder);
}

pub fn computeImageInodes(entry_count: u64) u64 {
    const with_headroom = entry_count + (entry_count / 10) + rootfs_inode_headroom;
    return @max(min_rootfs_inodes, with_headroom);
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

pub fn normalizeHostTreeTimestamps(allocator: std.mem.Allocator, io: Io, root: Io.Dir, root_path: []const u8) !void {
    try normalizeDirChildrenTimestamps(allocator, io, root);
    try Io.Dir.cwd().setTimestamps(io, root_path, .{
        .follow_symlinks = false,
        .access_timestamp = .{ .new = deterministic_epoch },
        .modify_timestamp = .{ .new = deterministic_epoch },
    });
}

pub fn runMkfs(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    mkfs: []const u8,
    rootfs_dir: []const u8,
    output: []const u8,
    determinism: Determinism,
    inode_count: u64,
) !void {
    const inode_count_arg = try std.fmt.allocPrint(allocator, "{d}", .{inode_count});
    defer allocator.free(inode_count_arg);
    const feature_options = try mkfsFeatureOptions(allocator, try mkfsSupportsOrphanFile(init, allocator, mkfs));
    defer allocator.free(feature_options);
    const extended_options = try std.fmt.allocPrint(
        allocator,
        "lazy_itable_init=0,lazy_journal_init=0,hash_seed={s}",
        .{determinism.hash_seed[0..]},
    );
    defer allocator.free(extended_options);
    const result = try std.process.run(allocator, init.io, .{
        .argv = &.{
            mkfs,
            "-q",
            "-F",
            "-N",
            inode_count_arg,
            "-O",
            feature_options,
            "-U",
            determinism.uuid[0..],
            "-E",
            extended_options,
            "-d",
            rootfs_dir,
            output,
        },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.MkfsFailed;
}

fn mkfsFeatureOptions(allocator: std.mem.Allocator, supports_orphan_file: bool) ![]u8 {
    const base = "^has_journal,^metadata_csum,^metadata_csum_seed";
    if (!supports_orphan_file) return allocator.dupe(u8, base);
    return std.fmt.allocPrint(allocator, "{s},^orphan_file", .{base});
}

fn mkfsSupportsOrphanFile(init: std.process.Init, allocator: std.mem.Allocator, mkfs: []const u8) !bool {
    const result = std.process.run(allocator, init.io, .{
        .argv = &.{ mkfs, "-V" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }
    if (e2fsprogsSupportsOrphanFileVersion(result.stdout)) |supported| return supported;
    if (e2fsprogsSupportsOrphanFileVersion(result.stderr)) |supported| return supported;
    return false;
}

fn e2fsprogsSupportsOrphanFileVersion(bytes: []const u8) ?bool {
    var tokens = std.mem.tokenizeAny(u8, bytes, " \t\r\n()");
    while (tokens.next()) |token| {
        const version = parseDottedVersion(token) catch continue;
        if (version.major != 1) return version.major > 1;
        if (version.minor != 47) return version.minor > 47;
        return true;
    }
    return null;
}

const DottedVersion = struct {
    major: u64,
    minor: u64,
    patch: u64,
};

fn parseDottedVersion(token: []const u8) !DottedVersion {
    var parts = std.mem.splitScalar(u8, token, '.');
    const major_raw = parts.next() orelse return error.BadVersion;
    const minor_raw = parts.next() orelse return error.BadVersion;
    const patch_raw = parts.next() orelse "0";
    if (parts.next() != null) return error.BadVersion;
    return .{
        .major = try parseVersionPart(major_raw),
        .minor = try parseVersionPart(minor_raw),
        .patch = try parseVersionPart(patch_raw),
    };
}

fn parseVersionPart(raw: []const u8) !u64 {
    if (raw.len == 0) return error.BadVersion;
    for (raw) |c| if (!std.ascii.isDigit(c)) return error.BadVersion;
    return std.fmt.parseInt(u64, raw, 10) catch return error.BadVersion;
}

pub fn runDebugfsFinalize(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    debugfs: []const u8,
    output: []const u8,
    script_path: []const u8,
    owners: *ownership.Map,
    determinism: Determinism,
) !void {
    var script: Io.Writer.Allocating = .init(allocator);
    defer script.deinit();

    try script.writer.writeAll(
        \\set_super_value mkfs_time 0
        \\set_super_value wtime 0
        \\set_super_value mtime 0
        \\set_super_value lastcheck 0
        \\set_super_value kbytes_written 0
        \\
    );
    for (1..12) |inode| {
        try writeDebugfsInodeTimestampFields(&script.writer, inode);
    }

    var it = owners.iterator();
    while (it.next()) |entry| {
        const rel = entry.key_ptr.*;
        const owner = entry.value_ptr.*;

        try script.writer.writeAll("set_inode_field ");
        try writeDebugfsPath(&script.writer, rel);
        try script.writer.print(" uid {d}\n", .{owner.uid});

        try script.writer.writeAll("set_inode_field ");
        try writeDebugfsPath(&script.writer, rel);
        try script.writer.print(" gid {d}\n", .{owner.gid});

        try writeDebugfsPathTimestampFields(&script.writer, rel);
    }
    try writeFileAtPath(init.io, script_path, script.written());

    const stderr_path = try std.fmt.allocPrint(allocator, "{s}.stderr", .{script_path});
    defer allocator.free(stderr_path);
    var stderr_file = try createFileAtPath(init.io, stderr_path);
    defer stderr_file.close(init.io);

    var child = try std.process.spawn(init.io, .{
        .argv = &.{ debugfs, "-w", "-f", script_path, output },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .{ .file = stderr_file },
    });
    defer child.kill(init.io);
    const term = try child.wait(init.io);
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return error.DebugfsFailed;
    try checkDebugfsStderr(allocator, init.io, stderr_path);
    try normalizeSuperblockTimestamps(allocator, init.io, output, determinism.uuid_bytes);
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

fn normalizeDirChildrenTimestamps(allocator: std.mem.Allocator, io: Io, dir: Io.Dir) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const name = try allocator.dupe(u8, entry.name);
        defer allocator.free(name);
        if (entry.kind == .directory) {
            var child = try dir.openDir(io, name, .{ .iterate = true, .follow_symlinks = false });
            defer child.close(io);
            try normalizeDirChildrenTimestamps(allocator, io, child);
        }
        try dir.setTimestamps(io, name, .{
            .follow_symlinks = false,
            .access_timestamp = .{ .new = deterministic_epoch },
            .modify_timestamp = .{ .new = deterministic_epoch },
        });
    }
}

fn normalizeSuperblockTimestamps(allocator: std.mem.Allocator, io: Io, path: []const u8, uuid: [16]u8) !void {
    _ = allocator;
    var file = if (Io.Dir.path.isAbsolute(path))
        try Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write })
    else
        try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);

    const stat = try file.stat(io);
    var primary: [ext4_superblock_size]u8 = undefined;
    const read = try file.readPositionalAll(io, &primary, ext4_superblock_offset);
    if (read != primary.len or !isExt4Superblock(&primary, uuid)) return error.BadExt4Image;
    const layout = try ext4Layout(&primary);

    try zeroSuperblockTimestampFields(file, io, ext4_superblock_offset);

    var group: u64 = 1;
    while (group < layout.group_count) : (group += 1) {
        if (layout.sparse_super and !isSparseSuperGroup(group)) continue;
        const superblock_offset = (layout.first_data_block + group * layout.blocks_per_group) * layout.block_size;
        if (superblock_offset + ext4_superblock_size > stat.size) continue;
        if (!try ext4SuperblockAt(file, io, superblock_offset, uuid)) continue;
        try zeroSuperblockTimestampFields(file, io, superblock_offset);
    }
}

const Ext4Layout = struct {
    block_size: u64,
    blocks_count: u64,
    first_data_block: u64,
    blocks_per_group: u64,
    group_count: u64,
    sparse_super: bool,
};

fn ext4Layout(superblock: *const [ext4_superblock_size]u8) !Ext4Layout {
    const blocks_count_lo = std.mem.readInt(u32, superblock[0x04..0x08], .little);
    const blocks_count_hi = std.mem.readInt(u32, superblock[0x150..0x154], .little);
    const blocks_count = (@as(u64, blocks_count_hi) << 32) | blocks_count_lo;
    const first_data_block = std.mem.readInt(u32, superblock[0x14..0x18], .little);
    const log_block_size = std.mem.readInt(u32, superblock[0x18..0x1c], .little);
    if (log_block_size > 16) return error.BadExt4Image;
    const block_size = @as(u64, 1024) << @intCast(log_block_size);
    const blocks_per_group = std.mem.readInt(u32, superblock[0x20..0x24], .little);
    if (blocks_per_group == 0 or blocks_count <= first_data_block) return error.BadExt4Image;
    const data_blocks = blocks_count - first_data_block;
    const group_count = (data_blocks + blocks_per_group - 1) / blocks_per_group;
    const ro_compat = std.mem.readInt(u32, superblock[0x64..0x68], .little);
    return .{
        .block_size = block_size,
        .blocks_count = blocks_count,
        .first_data_block = first_data_block,
        .blocks_per_group = blocks_per_group,
        .group_count = group_count,
        .sparse_super = (ro_compat & ext4_feature_sparse_super) != 0,
    };
}

fn ext4SuperblockAt(file: Io.File, io: Io, offset: u64, uuid: [16]u8) !bool {
    var block: [ext4_superblock_size]u8 = undefined;
    const read = try file.readPositionalAll(io, &block, offset);
    if (read != block.len) return false;
    return isExt4Superblock(&block, uuid);
}

fn isExt4Superblock(block: *const [ext4_superblock_size]u8, uuid: [16]u8) bool {
    if (block[0x38] != 0x53 or block[0x39] != 0xef) return false;
    return std.mem.eql(u8, block[0x68..0x78], &uuid);
}

fn isSparseSuperGroup(group: u64) bool {
    return group == 0 or group == 1 or isPowerOf(group, 3) or isPowerOf(group, 5) or isPowerOf(group, 7);
}

fn isPowerOf(value: u64, base: u64) bool {
    if (value == 0) return false;
    var n = value;
    while (n % base == 0) n /= base;
    return n == 1;
}

fn zeroSuperblockTimestampFields(file: Io.File, io: Io, superblock_offset: u64) !void {
    try zeroFileRange(file, io, superblock_offset + 0x2c, 4); // s_mtime
    try zeroFileRange(file, io, superblock_offset + 0x30, 4); // s_wtime
    try zeroFileRange(file, io, superblock_offset + 0x40, 4); // s_lastcheck
    try zeroFileRange(file, io, superblock_offset + 0x108, 4); // s_mkfs_time
    try zeroFileRange(file, io, superblock_offset + 0x240, 8); // s_kbytes_written
}

fn zeroFileRange(file: Io.File, io: Io, offset: u64, len: usize) !void {
    var zeros = [_]u8{0} ** 8;
    try file.writePositionalAll(io, zeros[0..len], offset);
}

fn checkDebugfsStderr(allocator: std.mem.Allocator, io: Io, path: []const u8) !void {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > 1024 * 1024) return error.DebugfsFailed;
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(bytes);
    const read = try file.readPositionalAll(io, bytes, 0);
    if (read != bytes.len) return error.DebugfsFailed;

    try checkDebugfsStderrBytes(bytes);
}

fn checkDebugfsStderrBytes(bytes: []const u8) !void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "debugfs ")) continue;
        return error.DebugfsFailed;
    }
}

pub fn writeFileAtPath(io: Io, path: []const u8, data: []const u8) !void {
    var file = try createFileAtPath(io, path);
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

fn writeDebugfsPath(writer: *Io.Writer, rel: []const u8) !void {
    try writer.writeByte('"');
    try writer.writeByte('/');
    for (rel) |c| {
        switch (c) {
            0, '\n', '\r' => return error.UnsupportedDebugfsPath,
            '"', '\\' => {
                try writer.writeByte('\\');
                try writer.writeByte(c);
            },
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

fn writeDebugfsInodeTimestampFields(writer: *Io.Writer, inode: usize) !void {
    const fields = [_][]const u8{ "atime", "ctime", "mtime", "crtime", "atime_extra", "ctime_extra", "mtime_extra", "crtime_extra" };
    for (fields) |field| {
        try writer.print("set_inode_field <{d}> {s} 0\n", .{ inode, field });
    }
}

fn writeDebugfsPathTimestampFields(writer: *Io.Writer, rel: []const u8) !void {
    const fields = [_][]const u8{ "atime", "ctime", "mtime", "crtime", "atime_extra", "ctime_extra", "mtime_extra", "crtime_extra" };
    for (fields) |field| {
        try writer.writeAll("set_inode_field ");
        try writeDebugfsPath(writer, rel);
        try writer.print(" {s} 0\n", .{field});
    }
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

test "directory entry count includes directories and files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a/b");
    try tmp.dir.writeFile(io, .{ .sub_path = "a/b/file", .data = "data" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top", .data = "" });

    try std.testing.expectEqual(@as(u64, 5), try dirEntryCount(io, tmp.dir));
}

test "mkfs feature options omit orphan_file when unsupported" {
    const allocator = std.testing.allocator;
    const unsupported = try mkfsFeatureOptions(allocator, false);
    defer allocator.free(unsupported);
    try std.testing.expectEqualStrings("^has_journal,^metadata_csum,^metadata_csum_seed", unsupported);

    const supported = try mkfsFeatureOptions(allocator, true);
    defer allocator.free(supported);
    try std.testing.expectEqualStrings("^has_journal,^metadata_csum,^metadata_csum_seed,^orphan_file", supported);
}

test "e2fsprogs orphan_file support is version gated" {
    try std.testing.expectEqual(false, e2fsprogsSupportsOrphanFileVersion("mke2fs 1.46.5 (30-Dec-2021)").?);
    try std.testing.expectEqual(true, e2fsprogsSupportsOrphanFileVersion("mke2fs 1.47.0 (5-Feb-2023)").?);
    try std.testing.expectEqual(true, e2fsprogsSupportsOrphanFileVersion("mke2fs 1.47.3 (8-Jul-2025)").?);
    try std.testing.expect(e2fsprogsSupportsOrphanFileVersion("not a version") == null);
}

test "deterministic ext4 identity derives stable UUIDs from digest" {
    const determinism = Determinism.fromDigest("sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
    try std.testing.expectEqual(@as(usize, 36), determinism.uuid.len);
    try std.testing.expectEqual(@as(usize, 36), determinism.hash_seed.len);
    try std.testing.expectEqual(@as(u8, '-'), determinism.uuid[8]);
    try std.testing.expectEqual(@as(u8, '-'), determinism.uuid[13]);
    try std.testing.expect(!std.mem.eql(u8, determinism.uuid[0..], determinism.hash_seed[0..]));
    try std.testing.expectEqualSlices(
        u8,
        determinism.uuid[0..],
        Determinism.fromDigest("sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef").uuid[0..],
    );
}

test "debugfs stderr checker accepts banner and rejects diagnostics" {
    try checkDebugfsStderrBytes("debugfs 1.47.3 (8-Jul-2025)\n");
    try std.testing.expectError(
        error.DebugfsFailed,
        checkDebugfsStderrBytes("debugfs 1.47.3 (8-Jul-2025)\n/nope: File not found by ext2_lookup\n"),
    );
}

test "superblock timestamp normalization ignores matching file data" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "zig-cache/test-rootfs-superblock-normalize.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    try createEmptyFile(io, path, 16 * 1024);
    var file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);

    const uuid = [_]u8{0xaa} ** 16;
    var primary = [_]u8{0} ** ext4_superblock_size;
    primary[0x38] = 0x53;
    primary[0x39] = 0xef;
    @memcpy(primary[0x68..0x78], &uuid);
    std.mem.writeInt(u32, primary[0x04..0x08], 16, .little); // s_blocks_count_lo
    std.mem.writeInt(u32, primary[0x14..0x18], 1, .little); // s_first_data_block
    std.mem.writeInt(u32, primary[0x18..0x1c], 0, .little); // 1024-byte blocks
    std.mem.writeInt(u32, primary[0x20..0x24], 8192, .little); // s_blocks_per_group
    std.mem.writeInt(u32, primary[0x2c..0x30], 1, .little);
    std.mem.writeInt(u32, primary[0x30..0x34], 2, .little);
    std.mem.writeInt(u32, primary[0x40..0x44], 3, .little);
    std.mem.writeInt(u32, primary[0x108..0x10c], 4, .little);
    std.mem.writeInt(u64, primary[0x240..0x248], 5, .little);
    try file.writePositionalAll(io, &primary, ext4_superblock_offset);

    var data = primary;
    std.mem.writeInt(u32, data[0x2c..0x30], 0x11111111, .little);
    std.mem.writeInt(u32, data[0x30..0x34], 0x22222222, .little);
    try file.writePositionalAll(io, &data, 4096);

    try normalizeSuperblockTimestamps(allocator, io, path, uuid);

    var primary_after: [ext4_superblock_size]u8 = undefined;
    var data_after: [ext4_superblock_size]u8 = undefined;
    try std.testing.expectEqual(primary_after.len, try file.readPositionalAll(io, &primary_after, ext4_superblock_offset));
    try std.testing.expectEqual(data_after.len, try file.readPositionalAll(io, &data_after, 4096));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, primary_after[0x2c..0x30], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, primary_after[0x30..0x34], .little));
    try std.testing.expectEqual(@as(u32, 0x11111111), std.mem.readInt(u32, data_after[0x2c..0x30], .little));
    try std.testing.expectEqual(@as(u32, 0x22222222), std.mem.readInt(u32, data_after[0x30..0x34], .little));
}
