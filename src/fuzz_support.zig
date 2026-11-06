//! Helpers for `std.testing.fuzz` targets.

const std = @import("std");

/// Returns `bytes` encoded for a target whose first input is one
/// `Smith.slice` call. `Smith.slice` reads a little-endian u32 length before
/// the bytes, so a raw seed would decode as a shifted, truncated slice.
pub fn sliceSeed(comptime bytes: []const u8) []const u8 {
    const seed = comptime seed: {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, bytes.len, .little);
        break :seed len ++ bytes[0..bytes.len].*;
    };
    return &seed;
}

var tmp_dirs_created = std.atomic.Value(u32).init(0);

/// `std.testing.tmpDir` for fuzz targets. It names the directory from
/// `std.testing.io`'s randomness, which the fuzz runner never seeds, so
/// every run and every parallel fuzz instance would share one path. These
/// names come from the process id and a per-process counter instead.
pub fn tmpDir(opts: std.Io.Dir.OpenOptions) std.testing.TmpDir {
    const io = std.testing.io;
    var sub_path: @FieldType(std.testing.TmpDir, "sub_path") = undefined;
    const pid: u32 = @intCast(std.c.getpid());
    _ = std.fmt.bufPrint(&sub_path, "{x:0>8}{x:0>8}", .{ pid, tmp_dirs_created.fetchAdd(1, .monotonic) }) catch unreachable;

    const cwd = std.Io.Dir.cwd();
    var cache_dir = cwd.createDirPathOpen(io, ".zig-cache", .{}) catch
        @panic("unable to make and open .zig-cache");
    defer cache_dir.close(io);
    const parent_dir = cache_dir.createDirPathOpen(io, "tmp", .{}) catch
        @panic("unable to make and open .zig-cache/tmp");
    // A crashed process with the same id may have left this path behind.
    parent_dir.deleteTree(io, &sub_path) catch {};
    const dir = parent_dir.createDirPathOpen(io, &sub_path, .{ .open_options = opts }) catch
        @panic("unable to make and open the fuzz tmp dir");
    return .{ .dir = dir, .parent_dir = parent_dir, .sub_path = sub_path };
}

test "slice seeds decode to their bytes" {
    const bytes = "seed bytes";
    var smith: std.testing.Smith = .{ .in = sliceSeed(bytes) };
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(bytes, buf[0..smith.slice(&buf)]);
}
