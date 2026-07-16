const std = @import("std");
const Io = std.Io;

const chunk_sealer = @import("../chunk_sealer.zig");
const rootfs_mod = @import("../rootfs.zig");
const ext4 = @import("../rootfs/ext4.zig");
const ext4_writer = @import("../rootfs/ext4_writer.zig");

pub const max_mounts_per_run = 8;
pub const max_target_bytes = 512;
pub const default_disk_bytes: u64 = 4 << 30;
const default_inode_count: u32 = 262_144;
const store_rel = "build/cache-mounts-v1";
const disk_name = "shared.ext4";
const cache_key_domain = "spore-build-cache-mount-key-v1";
const mount_digest_domain = "spore-build-cache-mounts-v1";
const ext4_magic: u16 = 0xef53;
const ext4_clean: u16 = 1;
const super_offset: u64 = 1024;
const super_magic_offset: usize = 0x38;
const super_state_offset: usize = 0x3a;

pub const Mount = struct {
    target: []const u8,
    id: []const u8,
    key: []const u8,
};

pub fn resolve(
    allocator: std.mem.Allocator,
    workdir: []const u8,
    resolved_targets: []const []const u8,
) ![]const Mount {
    if (resolved_targets.len > max_mounts_per_run) return error.TooManyRunCacheMounts;
    var mounts = std.array_list.Managed(Mount).init(allocator);
    for (resolved_targets) |resolved_target| {
        // BuildKit derives an omitted cache ID from path.Clean of the target
        // after Dockerfile variable expansion, but before joining a relative
        // target to WORKDIR.
        const id = try cleanPosix(allocator, resolved_target);
        if (std.mem.eql(u8, id, ".") or id.len > max_target_bytes) return error.RunCacheMountTargetUnsupported;
        const target = if (std.fs.path.isAbsolute(resolved_target))
            try cleanPosix(allocator, resolved_target)
        else blk: {
            const joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ workdir, resolved_target });
            break :blk try cleanPosix(allocator, joined);
        };
        if (!std.fs.path.isAbsolute(target) or std.mem.eql(u8, target, "/") or target.len > max_target_bytes) {
            return error.RunCacheMountTargetUnsupported;
        }
        const key = try cacheKey(allocator, id);
        for (mounts.items) |existing| {
            if (pathsOverlap(existing.target, target)) return error.RunCacheMountTargetConflict;
        }
        try mounts.append(.{ .target = target, .id = id, .key = key });
    }
    return mounts.toOwnedSlice();
}

pub fn digest(allocator: std.mem.Allocator, mounts: []const Mount) ![]const u8 {
    if (mounts.len == 0) return allocator.dupe(u8, "");
    var h = std.crypto.hash.Blake3.init(.{});
    hashField(&h, mount_digest_domain);
    hashCount(&h, mounts.len);
    for (mounts) |mount| {
        hashField(&h, "cache");
        hashField(&h, mount.target);
        hashField(&h, mount.id);
        hashField(&h, mount.key);
        hashField(&h, "shared");
    }
    return finishDigest(allocator, &h);
}

fn cacheKey(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    var h = std.crypto.hash.Blake3.init(.{});
    hashField(&h, cache_key_domain);
    hashField(&h, id);
    var bytes: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
    h.final(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return allocator.dupe(u8, &hex);
}

fn cleanPosix(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len == 0 or std.mem.indexOfScalar(u8, raw, 0) != null) {
        return error.RunCacheMountTargetUnsupported;
    }
    return std.fs.path.resolvePosix(allocator, &.{raw});
}

fn pathsOverlap(a: []const u8, b: []const u8) bool {
    return pathContains(a, b) or pathContains(b, a);
}

fn pathContains(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, child)) return true;
    return child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '/';
}

pub const Store = struct {
    lock: rootfs_mod.RootfsCacheLock,
    fd: std.c.fd_t,

    pub fn open(io: Io, allocator: std.mem.Allocator, cache_root: []const u8) !Store {
        return openSized(io, allocator, cache_root, default_disk_bytes, default_inode_count);
    }

    fn openSized(io: Io, allocator: std.mem.Allocator, cache_root: []const u8, image_size: u64, inode_count: u32) !Store {
        const dir = try std.fs.path.join(allocator, &.{ cache_root, store_rel });
        var lock = try rootfs_mod.lockRootfsCacheExclusive(io, allocator, dir);
        errdefer lock.deinit();
        const path = try std.fs.path.join(allocator, &.{ dir, disk_name });
        if (!try validDisk(io, allocator, path, image_size)) {
            Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |other| return other,
            };
            try emitDisk(io, allocator, dir, path, image_size, inode_count);
        }
        const path_z = try allocator.dupeZ(u8, path);
        const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
        if (fd < 0) return error.CacheMountDiskOpenFailed;
        errdefer _ = std.c.close(fd);
        if (!try validOpenDisk(io, fd, image_size)) return error.CacheMountDiskInvalid;
        return .{ .lock = lock, .fd = fd };
    }

    pub fn sync(self: *Store) !void {
        if (self.fd < 0 or std.c.fsync(self.fd) != 0) return error.CacheMountDiskSyncFailed;
    }

    pub fn deinit(self: *Store) void {
        if (self.fd >= 0) {
            _ = std.c.fsync(self.fd);
            _ = std.c.close(self.fd);
            self.fd = -1;
        }
        self.lock.deinit();
    }
};

fn validDisk(io: Io, allocator: std.mem.Allocator, path: []const u8, image_size: u64) !bool {
    const path_z = try allocator.dupeZ(u8, path);
    const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return switch (std.c.errno(-1)) {
        .NOENT => false,
        else => error.CacheMountDiskOpenFailed,
    };
    defer _ = std.c.close(fd);
    return validOpenDisk(io, fd, image_size);
}

fn validOpenDisk(io: Io, fd: std.c.fd_t, image_size: u64) !bool {
    const file = Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    const stat = file.stat(io) catch return false;
    if (stat.kind != .file or stat.size != image_size) return false;
    var super: [1024]u8 = undefined;
    const n = std.c.pread(fd, &super, super.len, @intCast(super_offset));
    if (n != super.len) return false;
    return std.mem.readInt(u16, super[super_magic_offset..][0..2], .little) == ext4_magic and
        std.mem.readInt(u16, super[super_state_offset..][0..2], .little) == ext4_clean;
}

fn emitDisk(io: Io, allocator: std.mem.Allocator, dir: []const u8, path: []const u8, image_size: u64, inode_count: u32) !void {
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const temp = try std.fmt.allocPrint(allocator, "{s}/.{s}.{d}.{x}.tmp", .{ dir, disk_name, std.c.getpid(), std.mem.readInt(u64, &nonce, .little) });
    defer Io.Dir.cwd().deleteFile(io, temp) catch {};
    _ = try ext4_writer.emit(allocator, io, temp, &.{}, .{
        .image_size = image_size,
        .inode_count = inode_count,
        .determinism = ext4.Determinism.fromDigest("spore-build-cache-mount-disk-v1"),
    });
    const temp_z = try allocator.dupeZ(u8, temp);
    const fd = std.c.open(temp_z.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.CacheMountDiskOpenFailed;
    defer _ = std.c.close(fd);
    if (std.c.fchmod(fd, 0o600) != 0 or std.c.fsync(fd) != 0) return error.CacheMountDiskSyncFailed;
    try Io.Dir.renameAbsolute(temp, path, io);
    try chunk_sealer.fsyncDirPath(allocator, dir);
}

fn hashCount(h: *std.crypto.hash.Blake3, count: usize) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, count, .little);
    h.update(&bytes);
}

fn hashField(h: *std.crypto.hash.Blake3, bytes: []const u8) void {
    hashCount(h, bytes.len);
    h.update(bytes);
}

fn finishDigest(allocator: std.mem.Allocator, h: *std.crypto.hash.Blake3) ![]const u8 {
    var bytes: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
    h.final(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return std.fmt.allocPrint(allocator, "blake3:{s}", .{&hex});
}

test "default cache ids follow BuildKit path.Clean semantics" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const mounts = try resolve(arena_state.allocator(), "/work", &.{ "/cache/../cache-a", "relative", "../sibling" });
    try std.testing.expectEqualStrings("/cache-a", mounts[0].id);
    try std.testing.expectEqualStrings("/cache-a", mounts[0].target);
    try std.testing.expectEqualStrings("relative", mounts[1].id);
    try std.testing.expectEqualStrings("/work/relative", mounts[1].target);
    try std.testing.expectEqualStrings("../sibling", mounts[2].id);
    try std.testing.expectEqualStrings("/sibling", mounts[2].target);
}

test "normalized target aliases share default identity and storage key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const aliases = [_][]const u8{ "/cache//pkg", "/cache/./pkg/", "/cache/tmp/../pkg" };
    var expected_key: ?[]const u8 = null;
    var expected_digest: ?[]const u8 = null;
    for (aliases) |alias| {
        const mounts = try resolve(allocator, "/", &.{alias});
        try std.testing.expectEqualStrings("/cache/pkg", mounts[0].id);
        try std.testing.expectEqualStrings("/cache/pkg", mounts[0].target);
        if (expected_key) |key| try std.testing.expectEqualStrings(key, mounts[0].key) else expected_key = mounts[0].key;
        const mount_digest = try digest(allocator, mounts);
        if (expected_digest) |value| try std.testing.expectEqualStrings(value, mount_digest) else expected_digest = mount_digest;
    }
}

test "cache mounts reject duplicate and nested destinations" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    try std.testing.expectError(error.RunCacheMountTargetConflict, resolve(allocator, "/", &.{ "/a", "/a" }));
    try std.testing.expectError(error.RunCacheMountTargetConflict, resolve(allocator, "/", &.{ "/a", "/a/b" }));
    try std.testing.expectError(error.RunCacheMountTargetUnsupported, resolve(allocator, "/", &.{"/"}));
}

test "cache store recreates a host-visible unclean aggregate" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const relative_root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const root = try Io.Dir.cwd().realPathFileAlloc(io, relative_root, allocator);
    const image_size: u64 = 64 << 20;

    var initial = try Store.openSized(io, allocator, root, image_size, 4096);
    initial.deinit();
    const path = try std.fs.path.join(allocator, &.{ root, store_rel, disk_name });
    const path_z = try allocator.dupeZ(u8, path);
    const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.CacheMountDiskOpenFailed;
    const dirty = [_]u8{ 0, 0 };
    if (std.c.pwrite(fd, &dirty, dirty.len, @intCast(super_offset + super_state_offset)) != dirty.len) {
        _ = std.c.close(fd);
        return error.CacheMountDiskSyncFailed;
    }
    _ = std.c.close(fd);

    var reopened = try Store.openSized(io, allocator, root, image_size, 4096);
    defer reopened.deinit();
    try std.testing.expect(try validOpenDisk(io, reopened.fd, image_size));
}
