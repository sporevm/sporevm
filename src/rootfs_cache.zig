//! Digest-addressed immutable rootfs cache helpers.
//!
//! Rootfs artifacts are content addressed by the BLAKE3 digest recorded in the
//! spore manifest. Callers may copy bytes from different sources, but the cache
//! path is valid only after the bytes have been verified against that manifest
//! digest and size.

const std = @import("std");
const spore = @import("spore.zig");

const Blake3 = std.crypto.hash.Blake3;
const Io = std.Io;

pub const RootfsHash = struct {
    digest: []const u8,
    size: u64,
};

pub const CopyOptions = struct {
    source_must_not_be_symlink: bool = true,
    allow_hardlink: bool = false,
};

pub fn openVerifiedFromCache(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    rootfs: spore.Rootfs,
) !std.c.fd_t {
    const path = try digestPath(allocator, cache_root, rootfs.artifact.digest);
    if (!try regularFileNoSymlink(io, path)) return error.RootFSDigestCacheMiss;
    const pathz = try allocator.dupeZ(u8, path);
    const fd = std.c.open(pathz, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return error.RootFSDigestCacheMiss;
    errdefer _ = std.c.close(fd);
    if (!try fdIsRegularFile(io, fd)) return error.RootFSDigestCacheMiss;

    const actual = try hashFd(io, allocator, fd);
    if (actual.size != rootfs.artifact.size) return error.RootFSDigestMismatch;
    if (!std.mem.eql(u8, actual.digest, rootfs.artifact.digest)) return error.RootFSDigestMismatch;
    if (std.c.lseek(fd, 0, std.c.SEEK.SET) < 0) return error.RootFSOpenFailed;
    return fd;
}

pub fn cacheByDigestPath(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    rootfs_path: []const u8,
) !spore.RootfsArtifactRef {
    const source = try hashPath(io, allocator, rootfs_path);
    const artifact = spore.RootfsArtifactRef{
        .digest = source.digest,
        .size = source.size,
    };
    try installExpectedPath(io, allocator, cache_root, rootfs_path, artifact, .{
        .source_must_not_be_symlink = false,
        .allow_hardlink = true,
    });
    return artifact;
}

pub fn installExpectedPath(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    source_path: []const u8,
    artifact: spore.RootfsArtifactRef,
    copy_options: CopyOptions,
) !void {
    const digest_path = try digestPath(allocator, cache_root, artifact.digest);
    const digest_dir = std.fs.path.dirname(digest_path) orelse return error.RootFSOpenFailed;
    try ensureDirPath(io, digest_dir);
    try verifyPath(io, allocator, source_path, artifact, copy_options.source_must_not_be_symlink);

    if (try pathExistsNoSymlink(io, digest_path)) {
        if (!try regularFileNoSymlink(io, digest_path)) return error.RootFSDigestMismatch;
        try chmodReadOnly(allocator, digest_path);
    } else {
        try copyVerifiedPath(io, allocator, source_path, digest_path, artifact, copy_options);
    }
    try verifyPath(io, allocator, digest_path, artifact, true);
}

pub fn copyVerifiedPath(
    io: Io,
    allocator: std.mem.Allocator,
    source_path: []const u8,
    dest_path: []const u8,
    artifact: spore.RootfsArtifactRef,
    options: CopyOptions,
) !void {
    try verifyPath(io, allocator, source_path, artifact, options.source_must_not_be_symlink);
    if (options.allow_hardlink and try hardlinkVerifiedPath(io, allocator, source_path, dest_path, artifact)) return;

    var temp_nonce_bytes: [8]u8 = undefined;
    io.random(&temp_nonce_bytes);
    const temp_nonce = std.mem.readInt(u64, &temp_nonce_bytes, .little);
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.{x}.tmp", .{ dest_path, temp_nonce });
    defer Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const source_z = try allocator.dupeZ(u8, source_path);
    const temp_z = try allocator.dupeZ(u8, temp_path);
    const source_fd = std.c.open(source_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (source_fd < 0) return error.RootFSOpenFailed;
    defer _ = std.c.close(source_fd);
    if (!try fdIsRegularFile(io, source_fd)) return error.RootFSOpenFailed;

    const dest_fd = std.c.open(temp_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(c_uint, 0o444));
    if (dest_fd < 0) return error.RootFSOpenFailed;
    defer _ = std.c.close(dest_fd);

    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(source_fd, &buf, buf.len);
        if (n < 0) return error.RootFSOpenFailed;
        if (n == 0) break;
        var done: usize = 0;
        const read_len: usize = @intCast(n);
        while (done < read_len) {
            const written = std.c.write(dest_fd, buf[done..].ptr, read_len - done);
            if (written <= 0) return error.RootFSOpenFailed;
            done += @intCast(written);
        }
    }
    if (std.c.fchmod(dest_fd, 0o444) != 0) return error.RootFSOpenFailed;
    try verifyPath(io, allocator, temp_path, artifact, true);
    try renamePath(io, temp_path, dest_path);
    try verifyPath(io, allocator, dest_path, artifact, true);
}

pub fn verifyPath(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    artifact: spore.RootfsArtifactRef,
    must_not_be_symlink: bool,
) !void {
    if (must_not_be_symlink and !try regularFileNoSymlink(io, path)) return error.RootFSDigestMismatch;
    if (!std.mem.eql(u8, artifact.format, spore.rootfs_artifact_format_ext4)) return error.RootFSDigestMismatch;
    const actual = try hashPath(io, allocator, path);
    if (actual.size != artifact.size) return error.RootFSDigestMismatch;
    if (!std.mem.eql(u8, actual.digest, artifact.digest)) return error.RootFSDigestMismatch;
}

pub fn hashPath(io: Io, allocator: std.mem.Allocator, path: []const u8) !RootfsHash {
    const pathz = try allocator.dupeZ(u8, path);
    const fd = std.c.open(pathz, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return error.RootFSOpenFailed;
    defer _ = std.c.close(fd);
    return hashFd(io, allocator, fd);
}

pub fn digestPath(allocator: std.mem.Allocator, cache_root: []const u8, digest: []const u8) ![]const u8 {
    try spore.validateRootfsDigest(digest);
    const hex = digest[spore.rootfs_digest_prefix.len..];
    const file_name = try std.fmt.allocPrint(allocator, "{s}.ext4", .{hex});
    return std.fs.path.join(allocator, &.{ cache_root, "by-digest", "blake3", file_name });
}

pub fn regularFileNoSymlink(io: Io, path: []const u8) !bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return false,
        else => |e| return e,
    };
    return stat.kind == .file;
}

pub fn pathExistsNoSymlink(io: Io, path: []const u8) !bool {
    _ = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return false,
        else => |e| return e,
    };
    return true;
}

fn hardlinkVerifiedPath(
    io: Io,
    allocator: std.mem.Allocator,
    source_path: []const u8,
    dest_path: []const u8,
    artifact: spore.RootfsArtifactRef,
) !bool {
    const source_z = try allocator.dupeZ(u8, source_path);
    const dest_z = try allocator.dupeZ(u8, dest_path);
    if (std.c.link(source_z, dest_z) != 0) return false;
    if (std.c.chmod(dest_z, 0o444) != 0) return error.RootFSOpenFailed;
    try verifyPath(io, allocator, dest_path, artifact, true);
    return true;
}

fn hashFd(io: Io, allocator: std.mem.Allocator, fd: std.c.fd_t) !RootfsHash {
    if (!try fdIsRegularFile(io, fd)) return error.RootFSOpenFailed;
    if (std.c.lseek(fd, 0, std.c.SEEK.SET) < 0) return error.RootFSOpenFailed;
    var h = Blake3.init(.{});
    var size: u64 = 0;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) return error.RootFSOpenFailed;
        if (n == 0) break;
        const read_len: usize = @intCast(n);
        h.update(buf[0..read_len]);
        size += @intCast(read_len);
    }
    var digest: [Blake3.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const digest_text = try std.fmt.allocPrint(allocator, "{s}{s}", .{ spore.rootfs_digest_prefix, &hex });
    return .{ .digest = digest_text, .size = size };
}

fn fdIsRegularFile(io: Io, fd: std.c.fd_t) !bool {
    const file = Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    const stat = file.stat(io) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.Streaming => return false,
        else => |e| return e,
    };
    return stat.kind == .file;
}

fn chmodReadOnly(allocator: std.mem.Allocator, path: []const u8) !void {
    const pathz = try allocator.dupeZ(u8, path);
    if (std.c.chmod(pathz, 0o444) != 0) return error.RootFSOpenFailed;
}

fn renamePath(io: Io, old_path: []const u8, new_path: []const u8) !void {
    const old_absolute = Io.Dir.path.isAbsolute(old_path);
    const new_absolute = Io.Dir.path.isAbsolute(new_path);
    if (old_absolute != new_absolute) return error.BadPathName;
    if (old_absolute) {
        try Io.Dir.renameAbsolute(old_path, new_path, io);
    } else {
        try Io.Dir.rename(Io.Dir.cwd(), old_path, Io.Dir.cwd(), new_path, io);
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

test "digest cache installs rootfs bytes atomically and verifies final content" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-cache-install";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });

    const artifact = try cacheByDigestPath(io, arena, cache_root, rootfs_path);
    try std.testing.expect(std.mem.startsWith(u8, artifact.digest, spore.rootfs_digest_prefix));
    try std.testing.expectEqual(@as(u64, "rootfs bytes".len), artifact.size);

    const rootfs = spore.Rootfs{ .device = .{ .mmio_slot = 1 }, .artifact = artifact };
    const fd = try openVerifiedFromCache(io, arena, cache_root, rootfs);
    _ = std.c.close(fd);

    const digest_path = try digestPath(arena, cache_root, artifact.digest);
    const digest_z = try arena.dupeZ(u8, digest_path);
    const write_fd = std.c.open(digest_z, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (write_fd >= 0) {
        _ = std.c.close(write_fd);
        return error.TestExpectedError;
    }

    try Io.Dir.cwd().deleteFile(io, digest_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = digest_path, .data = "tampered" });
    try std.testing.expectError(error.RootFSDigestMismatch, openVerifiedFromCache(io, arena, cache_root, rootfs));
}

test "digest cache rejects unsafe existing paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-cache-symlink";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });

    const artifact = try cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const digest_path = try digestPath(arena, cache_root, artifact.digest);
    try Io.Dir.cwd().deleteFile(io, digest_path);
    const digest_z = try arena.dupeZ(u8, digest_path);
    const rootfs_z = try arena.dupeZ(u8, rootfs_path);
    if (std.c.symlink(rootfs_z, digest_z) != 0) return error.SkipZigTest;

    try std.testing.expectError(error.RootFSDigestMismatch, installExpectedPath(io, arena, cache_root, rootfs_path, artifact, .{}));
}

test "rootfs hashing rejects non-file descriptors" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-cache-fd-regular";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);

    const tmp_z = try allocator.dupeZ(u8, tmp);
    defer allocator.free(tmp_z);
    const fd = std.c.open(tmp_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return error.SkipZigTest;
    defer _ = std.c.close(fd);
    try std.testing.expectError(error.RootFSOpenFailed, hashFd(io, allocator, fd));
}
