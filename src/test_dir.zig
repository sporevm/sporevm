//! Temporary directories for tests that need path strings.

const std = @import("std");

/// A `std.testing.tmpDir` that also hands out path strings. Each one is a
/// fresh, randomly named directory, so test runs sharing a checkout never
/// share files, and `deinit` deletes it.
pub const TestDir = struct {
    tmp: std.testing.TmpDir,
    /// The open directory.
    dir: std.Io.Dir,
    arena: std.heap.ArenaAllocator,
    /// The directory's path relative to the working directory. Staying
    /// relative keeps Unix socket paths under it within the 104-byte macOS
    /// limit.
    root: [:0]const u8,

    pub fn init() !TestDir {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const root = try std.fs.path.joinZ(arena.allocator(), &.{ ".zig-cache", "tmp", &tmp.sub_path });
        return .{ .tmp = tmp, .dir = tmp.dir, .arena = arena, .root = root };
    }

    pub fn deinit(self: *TestDir) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }

    /// The path of `sub` inside the directory, valid until `deinit`.
    pub fn path(self: *TestDir, sub: []const u8) ![:0]const u8 {
        return std.fs.path.joinZ(self.arena.allocator(), &.{ self.root, sub });
    }
};

test "test dirs are distinct and removed on deinit" {
    const io = std.testing.io;
    var a = try TestDir.init();
    var b = try TestDir.init();
    defer b.deinit();
    try std.testing.expect(!std.mem.eql(u8, a.root, b.root));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try a.path("file"), .data = "x" });
    var buf: [1]u8 = undefined;
    try std.testing.expectEqualStrings("x", try a.dir.readFile(io, "file", &buf));
    const root = try std.testing.allocator.dupe(u8, a.root);
    defer std.testing.allocator.free(root);
    a.deinit();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, root, .{}));
}
