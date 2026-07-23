//! User-visible ownership classification for saved spore directories.

const std = @import("std");
const builtin = @import("builtin");

const rootfs_cas = @import("rootfs_cas.zig");
const saved_spore_pin = @import("saved_spore_pin.zig");
const spore = @import("spore.zig");

pub const machine_local_pinned = "machine-local-pinned";
pub const portable_self_contained = "portable-self-contained";
pub const batch_relative = "batch-relative";

pub fn classify(allocator: std.mem.Allocator, spore_dir: []const u8, disk: ?spore.Disk) ![]const u8 {
    const pin_reference = try regularPathExists(allocator, try std.fs.path.join(allocator, &.{ spore_dir, saved_spore_pin.reference_file }));
    if (pin_reference and disk == null) return error.BadManifest;
    if (try hasBatchRelativeChunks(allocator, spore_dir)) return batch_relative;
    if (pin_reference) return machine_local_pinned;
    if (disk) |value| {
        const storage = try saved_spore_pin.storageForDisk(value);
        const index_path = try rootfs_cas.manifestIndexPath(allocator, spore_dir, storage.index_digest);
        if (!try regularPathExists(allocator, index_path)) return error.BadManifest;
    }
    return portable_self_contained;
}

fn hasBatchRelativeChunks(allocator: std.mem.Allocator, spore_dir: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ spore_dir, "chunks" });
    defer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (!try pathHasKindNoFollow(path_z, .sym_link)) return false;
    var target: [64]u8 = undefined;
    const len = std.c.readlink(path_z.ptr, &target, target.len);
    if (len < 0) return error.IoFailed;
    if (!std.mem.eql(u8, target[0..@intCast(len)], "../shared-chunks")) return error.BadManifest;
    return true;
}

fn regularPathExists(allocator: std.mem.Allocator, owned_path: []const u8) !bool {
    defer allocator.free(owned_path);
    const path_z = try allocator.dupeZ(u8, owned_path);
    defer allocator.free(path_z);
    return pathHasKindNoFollow(path_z, .file);
}

fn pathHasKindNoFollow(path: [:0]const u8, expected: std.Io.File.Kind) !bool {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var stat: linux.Statx = undefined;
        const rc = linux.statx(std.c.AT.FDCWD, path, std.c.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true }, &stat);
        const result = linux.errno(rc);
        if (result != .SUCCESS) return switch (result) {
            .NOENT, .NOTDIR => false,
            else => error.IoFailed,
        };
        if (!stat.mask.TYPE or !stat.mask.MODE) return error.IoFailed;
        const matches = switch (expected) {
            .sym_link => linux.S.ISLNK(stat.mode),
            .file => linux.S.ISREG(stat.mode),
            else => unreachable,
        };
        if (!matches and expected == .file) return error.BadManifest;
        return matches;
    } else {
        var stat: std.c.Stat = undefined;
        const rc = std.c.fstatat(std.c.AT.FDCWD, path, &stat, std.c.AT.SYMLINK_NOFOLLOW);
        if (rc != 0) return switch (std.c.errno(rc)) {
            .NOENT, .NOTDIR => false,
            else => error.IoFailed,
        };
        const matches = switch (expected) {
            .sym_link => std.c.S.ISLNK(stat.mode),
            .file => std.c.S.ISREG(stat.mode),
            else => unreachable,
        };
        if (!matches and expected == .file) return error.BadManifest;
        return matches;
    }
}
