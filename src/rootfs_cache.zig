//! Digest-addressed immutable rootfs cache helpers.
//!
//! Rootfs artifacts are content addressed by the BLAKE3 digest recorded in the
//! spore manifest. Callers may copy bytes from different sources, but the cache
//! path is valid only after the bytes have been verified against that manifest
//! digest and size.
//!
//! The cache contract is verify-at-install, trust-at-open: every write into
//! the cache verifies the bytes against the expected digest before publishing
//! them (`installExpectedPath*`, `cacheByDigestPath*`, `copyVerifiedPath`),
//! entries are installed read-only, and product open paths
//! (`openTrustedFromCache`) do not re-hash them. The cache lives in the same
//! host trust domain as the spore binary and kernel cache; see SECURITY.md.
//! `openVerifiedFromCache` remains for boundaries that must prove cache
//! contents to a third party, such as metadata-only bundle materialization.

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

pub const InstallResult = struct {
    cache_hit: bool,
    bytes_fetched: u64,
};

/// Opens a digest-addressed cache entry without re-hashing its contents.
///
/// Cache entries are verified against the manifest digest when they are
/// installed and are immutable (read-only, atomically published) afterwards,
/// so opens trust that install-time verification. This still fails closed on
/// symlinked or non-regular entries and on size mismatch, which catch cache
/// management bugs and truncation without a full BLAKE3 pass on every resume.
pub fn openTrustedFromCache(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    rootfs: spore.Rootfs,
) !std.c.fd_t {
    const path = try digestPath(allocator, cache_root, rootfs.artifact.digest);
    defer allocator.free(path);
    if (!try regularFileNoSymlink(io, path)) return error.RootFSDigestCacheMiss;
    const pathz = try allocator.dupeZ(u8, path);
    defer allocator.free(pathz);
    const fd = std.c.open(pathz, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.RootFSDigestCacheMiss;
    errdefer _ = std.c.close(fd);
    const file = Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    const stat = file.stat(io) catch return error.RootFSDigestCacheMiss;
    if (stat.kind != .file) return error.RootFSDigestCacheMiss;
    if (stat.size != rootfs.artifact.size) return error.RootFSDigestMismatch;
    return fd;
}

pub fn openVerifiedFromCache(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    rootfs: spore.Rootfs,
) !std.c.fd_t {
    const path = try digestPath(allocator, cache_root, rootfs.artifact.digest);
    defer allocator.free(path);
    if (!try regularFileNoSymlink(io, path)) return error.RootFSDigestCacheMiss;
    const pathz = try allocator.dupeZ(u8, path);
    defer allocator.free(pathz);
    const fd = std.c.open(pathz, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.RootFSDigestCacheMiss;
    errdefer _ = std.c.close(fd);
    if (!try fdIsRegularFile(io, fd)) return error.RootFSDigestCacheMiss;

    const actual = try hashFd(io, allocator, fd);
    if (actual.size != rootfs.artifact.size) return error.RootFSDigestMismatch;
    if (!std.mem.eql(u8, actual.digest, rootfs.artifact.digest)) return error.RootFSDigestMismatch;
    if (std.c.lseek(fd, 0, std.c.SEEK.SET) < 0) return error.RootFSOpenFailed;
    return fd;
}

/// Installs by hardlink when possible. Because opens trust install-time
/// verification, hardlink sources must be cache-internal immutable files
/// (for example the image-keyed materialized ext4); a hardlink to a
/// caller-owned path would let later edits alias the cache entry. Use
/// `cacheByDigestPathCopy` for any user-supplied path.
pub fn cacheByDigestPath(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    rootfs_path: []const u8,
) !spore.RootfsArtifactRef {
    return cacheByDigestPathWithOptions(io, allocator, cache_root, rootfs_path, .{
        .source_must_not_be_symlink = false,
        .allow_hardlink = true,
    });
}

pub fn cacheByDigestPathCopy(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    rootfs_path: []const u8,
) !spore.RootfsArtifactRef {
    return cacheByDigestPathWithOptions(io, allocator, cache_root, rootfs_path, .{
        .source_must_not_be_symlink = false,
        .allow_hardlink = false,
    });
}

fn cacheByDigestPathWithOptions(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    rootfs_path: []const u8,
    copy_options: CopyOptions,
) !spore.RootfsArtifactRef {
    const source = try hashPath(io, allocator, rootfs_path);
    const artifact = spore.RootfsArtifactRef{
        .digest = source.digest,
        .size = source.size,
    };
    _ = try installExpectedPathAfterSourceVerified(io, allocator, cache_root, rootfs_path, artifact, copy_options);
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
    _ = try installExpectedPathWithResult(io, allocator, cache_root, source_path, artifact, copy_options);
}

pub fn installExpectedPathWithResult(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    source_path: []const u8,
    artifact: spore.RootfsArtifactRef,
    copy_options: CopyOptions,
) !InstallResult {
    try verifyPath(io, allocator, source_path, artifact, copy_options.source_must_not_be_symlink);
    return installExpectedPathAfterSourceVerified(io, allocator, cache_root, source_path, artifact, copy_options);
}

pub fn installExpectedPathAfterSourceVerified(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    source_path: []const u8,
    artifact: spore.RootfsArtifactRef,
    copy_options: CopyOptions,
) !InstallResult {
    const digest_path = try digestPath(allocator, cache_root, artifact.digest);
    defer allocator.free(digest_path);
    const digest_dir = std.fs.path.dirname(digest_path) orelse return error.RootFSOpenFailed;
    try ensureDirPath(io, digest_dir);

    if (try pathExistsNoSymlink(io, digest_path)) {
        if (!try regularFileNoSymlink(io, digest_path)) return error.RootFSDigestMismatch;
        try chmodReadOnly(allocator, digest_path);
        if (!std.mem.eql(u8, artifact.format, spore.rootfs_artifact_format_ext4)) return error.RootFSDigestMismatch;
        const rootfs = spore.Rootfs{ .device = .{ .mmio_slot = 1 }, .artifact = artifact };
        const fd = openTrustedFromCache(io, allocator, cache_root, rootfs) catch |err| switch (err) {
            error.RootFSDigestCacheMiss => return error.RootFSDigestMismatch,
            else => |e| return e,
        };
        _ = std.c.close(fd);
        return .{ .cache_hit = true, .bytes_fetched = 0 };
    } else {
        try copyVerifiedPathAfterSourceVerified(io, allocator, source_path, digest_path, artifact, copy_options);
    }
    return .{ .cache_hit = false, .bytes_fetched = artifact.size };
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
    try copyVerifiedPathAfterSourceVerified(io, allocator, source_path, dest_path, artifact, options);
}

/// Copy from a source that is already in the local cache trust domain.
///
/// This skips the source BLAKE3 pass but still verifies the published
/// destination bytes against `artifact`. Use this only for cache-internal
/// immutable sources, not for caller-owned paths or peer/bundle inputs.
pub fn copyTrustedPath(
    io: Io,
    allocator: std.mem.Allocator,
    source_path: []const u8,
    dest_path: []const u8,
    artifact: spore.RootfsArtifactRef,
) !void {
    if (!try regularFileNoSymlink(io, source_path)) return error.RootFSOpenFailed;
    try copyVerifiedPathAfterSourceVerified(io, allocator, source_path, dest_path, artifact, .{
        .source_must_not_be_symlink = true,
        .allow_hardlink = false,
    });
}

fn copyVerifiedPathAfterSourceVerified(
    io: Io,
    allocator: std.mem.Allocator,
    source_path: []const u8,
    dest_path: []const u8,
    artifact: spore.RootfsArtifactRef,
    options: CopyOptions,
) !void {
    if (options.allow_hardlink and try hardlinkVerifiedPath(io, allocator, source_path, dest_path, artifact)) return;

    var temp_nonce_bytes: [8]u8 = undefined;
    io.random(&temp_nonce_bytes);
    const temp_nonce = std.mem.readInt(u64, &temp_nonce_bytes, .little);
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.{x}.tmp", .{ dest_path, temp_nonce });
    defer allocator.free(temp_path);
    defer Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const source_z = try allocator.dupeZ(u8, source_path);
    defer allocator.free(source_z);
    const temp_z = try allocator.dupeZ(u8, temp_path);
    defer allocator.free(temp_z);
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
    try renamePath(io, temp_path, dest_path);
    errdefer Io.Dir.cwd().deleteFile(io, dest_path) catch {};
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
    defer allocator.free(actual.digest);
    if (actual.size != artifact.size) return error.RootFSDigestMismatch;
    if (!std.mem.eql(u8, actual.digest, artifact.digest)) return error.RootFSDigestMismatch;
}

pub fn hashPath(io: Io, allocator: std.mem.Allocator, path: []const u8) !RootfsHash {
    const pathz = try allocator.dupeZ(u8, path);
    defer allocator.free(pathz);
    const fd = std.c.open(pathz, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return error.RootFSOpenFailed;
    defer _ = std.c.close(fd);
    return hashFd(io, allocator, fd);
}

pub fn digestPath(allocator: std.mem.Allocator, cache_root: []const u8, digest: []const u8) ![]const u8 {
    try spore.validateRootfsDigest(digest);
    const hex = digest[spore.rootfs_digest_prefix.len..];
    const file_name = try std.fmt.allocPrint(allocator, "{s}.ext4", .{hex});
    defer allocator.free(file_name);
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
    defer allocator.free(source_z);
    const dest_z = try allocator.dupeZ(u8, dest_path);
    defer allocator.free(dest_z);
    if (std.c.link(source_z, dest_z) != 0) return false;
    errdefer Io.Dir.cwd().deleteFile(io, dest_path) catch {};
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
    defer allocator.free(pathz);
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
    const stat = try Io.Dir.cwd().statFile(io, digest_path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o444), @as(u32, @intCast(@intFromEnum(stat.permissions) & 0o777)));

    try Io.Dir.cwd().deleteFile(io, digest_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = digest_path, .data = "tampered" });
    try std.testing.expectError(error.RootFSDigestMismatch, openVerifiedFromCache(io, arena, cache_root, rootfs));
}

test "trusted open accepts installed entry and fails closed on size and shape" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-cache-trusted-open";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });

    const artifact = try cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const rootfs = spore.Rootfs{ .device = .{ .mmio_slot = 1 }, .artifact = artifact };

    const fd = try openTrustedFromCache(io, arena, cache_root, rootfs);
    var readback: [12]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 12), std.c.pread(fd, &readback, readback.len, 0));
    try std.testing.expectEqualStrings("rootfs bytes", &readback);
    _ = std.c.close(fd);

    // Size mismatch fails closed.
    const digest_path = try digestPath(arena, cache_root, artifact.digest);
    try Io.Dir.cwd().deleteFile(io, digest_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = digest_path, .data = "short" });
    try std.testing.expectError(error.RootFSDigestMismatch, openTrustedFromCache(io, arena, cache_root, rootfs));

    // Missing entry is a cache miss.
    try Io.Dir.cwd().deleteFile(io, digest_path);
    try std.testing.expectError(error.RootFSDigestCacheMiss, openTrustedFromCache(io, arena, cache_root, rootfs));

    // Symlinked entry is rejected even when it points at matching bytes.
    const digest_z = try arena.dupeZ(u8, digest_path);
    const rootfs_z = try arena.dupeZ(u8, rootfs_path);
    if (std.c.symlink(rootfs_z, digest_z) != 0) return error.SkipZigTest;
    try std.testing.expectError(error.RootFSDigestCacheMiss, openTrustedFromCache(io, arena, cache_root, rootfs));
}

test "trusted open trusts install-time verification for same-size entries" {
    // Pin the trust-at-open contract: a same-size content change to an
    // installed cache entry is NOT detected at open time. Integrity is
    // enforced when bytes enter the cache, not on every resume; SECURITY.md
    // documents the cache as host-local trusted state.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-cache-trusted-open-same-size";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });

    const artifact = try cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const rootfs = spore.Rootfs{ .device = .{ .mmio_slot = 1 }, .artifact = artifact };

    const digest_path = try digestPath(arena, cache_root, artifact.digest);
    try Io.Dir.cwd().deleteFile(io, digest_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = digest_path, .data = "ROOTFS BYTES" });

    const fd = try openTrustedFromCache(io, arena, cache_root, rootfs);
    _ = std.c.close(fd);
    try std.testing.expectError(error.RootFSDigestMismatch, openVerifiedFromCache(io, arena, cache_root, rootfs));
}

test "install trusts existing same-size digest cache hits" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-cache-install-existing-trusted";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });

    const artifact = try cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const rootfs = spore.Rootfs{ .device = .{ .mmio_slot = 1 }, .artifact = artifact };
    const digest_path = try digestPath(arena, cache_root, artifact.digest);
    try Io.Dir.cwd().deleteFile(io, digest_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = digest_path, .data = "ROOTFS BYTES" });

    const result = try installExpectedPathWithResult(io, arena, cache_root, rootfs_path, artifact, .{
        .source_must_not_be_symlink = false,
        .allow_hardlink = false,
    });
    try std.testing.expect(result.cache_hit);
    try std.testing.expectEqual(@as(u64, 0), result.bytes_fetched);

    const fd = try openTrustedFromCache(io, arena, cache_root, rootfs);
    _ = std.c.close(fd);
    try std.testing.expectError(error.RootFSDigestMismatch, openVerifiedFromCache(io, arena, cache_root, rootfs));
}

test "copy-only digest cache does not chmod source rootfs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-cache-copy-source-perms";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });
    try Io.Dir.cwd().setFilePermissions(io, rootfs_path, @enumFromInt(0o644), .{});

    const artifact = try cacheByDigestPathCopy(io, arena, cache_root, rootfs_path);
    const source_stat = try Io.Dir.cwd().statFile(io, rootfs_path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o644), @as(u32, @intCast(@intFromEnum(source_stat.permissions) & 0o777)));

    const digest_path = try digestPath(arena, cache_root, artifact.digest);
    const cache_stat = try Io.Dir.cwd().statFile(io, digest_path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o444), @as(u32, @intCast(@intFromEnum(cache_stat.permissions) & 0o777)));
}

test "trusted rootfs copy verifies destination bytes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-cache-trusted-copy";
    const expected_path = tmp ++ "/expected.ext4";
    const source_path = tmp ++ "/source.ext4";
    const dest_path = tmp ++ "/dest.ext4";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = expected_path, .data = "expected rootfs bytes" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = "tampered rootfs bytes" });

    const expected = try hashPath(io, arena, expected_path);
    const artifact = spore.RootfsArtifactRef{
        .digest = expected.digest,
        .size = expected.size,
    };
    try std.testing.expectError(error.RootFSDigestMismatch, copyTrustedPath(io, arena, source_path, dest_path, artifact));
    try std.testing.expect(!try pathExistsNoSymlink(io, dest_path));

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = "expected rootfs bytes" });
    try copyTrustedPath(io, arena, source_path, dest_path, artifact);
    try verifyPath(io, arena, dest_path, artifact, true);
}

test "install after source verification cleans up bad installed bytes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-cache-preverified-cleanup";
    const expected_path = tmp ++ "/expected.ext4";
    const source_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = expected_path, .data = "expected rootfs bytes" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = "tampered rootfs bytes" });

    const expected = try hashPath(io, arena, expected_path);
    const artifact = spore.RootfsArtifactRef{
        .digest = expected.digest,
        .size = expected.size,
    };
    try std.testing.expectError(error.RootFSDigestMismatch, installExpectedPathAfterSourceVerified(io, arena, cache_root, source_path, artifact, .{
        .source_must_not_be_symlink = false,
        .allow_hardlink = true,
    }));

    const digest_path = try digestPath(arena, cache_root, artifact.digest);
    try std.testing.expect(!try pathExistsNoSymlink(io, digest_path));
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
