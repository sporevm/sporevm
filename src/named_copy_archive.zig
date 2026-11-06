//! SPCP1 transfer archive for named `copy-in` and `copy-out`.
//!
//! The host writes copy-in archives for the guest agent. Copy-out archives are
//! produced by the guest, so `extract` treats every byte as hostile: record
//! paths are relative, slash-separated, and free of `.`, `..`, empty, and NUL
//! components; only regular files and directories are created, into a
//! destination that must not exist, each with O_EXCL or mkdirat relative to
//! its parent's fd, which is opened one component at a time with O_NOFOLLOW;
//! guest modes pass through the process umask; and a failed extraction
//! removes the partial destination.

const std = @import("std");
const TestDir = @import("test_dir.zig").TestDir;
const builtin = @import("builtin");
const fuzz_support = @import("fuzz_support.zig");

const Io = std.Io;

const magic = "SPCP1\n\x00\n";
const record_header_len = 16;
/// The longest record path; the guest agent's MAX_COPY_PATH_LEN.
pub const max_path = 512;

/// Largest copy-out archive the host accepts from the guest, so a guest
/// cannot fill the host's temporary directory.
pub const max_archive_bytes: u64 = 4 << 30;

const Kind = enum(u8) {
    file = 'F',
    directory = 'D',
    end = 'E',
};

const Record = struct {
    kind: Kind,
    path: []const u8,
    mode: u32,
    size: u64,
};

/// A private temporary directory holding one transfer archive.
pub const TempArchive = struct {
    allocator: std.mem.Allocator,
    dir: [:0]u8,
    path: []const u8,

    pub fn deinit(self: *TempArchive, io: Io) void {
        Io.Dir.cwd().deleteTree(io, self.dir) catch {};
        self.allocator.free(self.path);
        self.allocator.free(self.dir);
    }
};

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

/// Reserves a private path for an archive the guest will produce.
pub fn createTemp(allocator: std.mem.Allocator) !TempArchive {
    const tmpl = "/tmp/sporevm-copy-XXXXXX";
    const dir = try allocator.dupeSentinel(u8, tmpl, 0);
    errdefer allocator.free(dir);
    if (mkdtemp(dir) == null) return error.IoFailed;
    const path = try std.fmt.allocPrint(allocator, "{s}/payload.spcp", .{std.mem.sliceTo(dir, 0)});
    errdefer allocator.free(path);
    return .{ .allocator = allocator, .dir = dir, .path = path };
}

/// Archives `host_path` into a private temporary file for copy-in.
pub fn createTempFromHostPath(allocator: std.mem.Allocator, io: Io, host_path: []const u8) !TempArchive {
    var archive = try createTemp(allocator);
    errdefer archive.deinit(io);

    var file = try Io.Dir.createFileAbsolute(io, archive.path, .{
        .exclusive = true,
        .permissions = @enumFromInt(0o600),
    });
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var file_writer = file.writerStreaming(io, &buffer);
    write(allocator, io, &file_writer.interface, host_path) catch |err| switch (err) {
        error.WriteFailed => return file_writer.err.?,
        else => |e| return e,
    };
    file_writer.interface.flush() catch return file_writer.err.?;
    return archive;
}

/// Writes the archive for a regular file or a tree of regular files and
/// directories. Symlinks and special files are rejected.
fn write(allocator: std.mem.Allocator, io: Io, w: *Io.Writer, host_path: []const u8) !void {
    try w.writeAll(magic);
    const stat = try Io.Dir.cwd().statFile(io, host_path, .{ .follow_symlinks = false });
    switch (stat.kind) {
        .file => try writeFileRecord(io, w, Io.Dir.cwd(), host_path, "", stat),
        .directory => {
            try writeRecordHeader(w, .directory, "", modeFromStat(stat), 0);
            var dir = try openDirPath(io, host_path, .{ .iterate = true, .follow_symlinks = false });
            defer dir.close(io);
            var walker = try dir.walk(allocator);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                try validatePath(entry.path, false);
                const entry_stat = try entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false });
                switch (entry.kind) {
                    .file => try writeFileRecord(io, w, entry.dir, entry.basename, entry.path, entry_stat),
                    .directory => try writeRecordHeader(w, .directory, entry.path, modeFromStat(entry_stat), 0),
                    else => return error.UnsupportedCopyEntry,
                }
            }
        },
        else => return error.UnsupportedCopyEntry,
    }
    try writeRecordHeader(w, .end, "", 0, 0);
}

fn writeFileRecord(
    io: Io,
    w: *Io.Writer,
    source_dir: Io.Dir,
    source_path: []const u8,
    archive_path: []const u8,
    stat: Io.File.Stat,
) !void {
    if (stat.kind != .file) return error.UnsupportedCopyEntry;
    try writeRecordHeader(w, .file, archive_path, modeFromStat(stat), stat.size);
    const open_options: Io.Dir.OpenFileOptions = .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    };
    var source = if (Io.Dir.path.isAbsolute(source_path))
        try Io.Dir.openFileAbsolute(io, source_path, open_options)
    else
        try source_dir.openFile(io, source_path, open_options);
    defer source.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var source_reader = source.readerStreaming(io, &buffer);
    source_reader.interface.streamExact64(w, stat.size) catch |err| switch (err) {
        error.EndOfStream => return error.ShortRead,
        error.ReadFailed => return source_reader.err.?,
        error.WriteFailed => return error.WriteFailed,
    };
}

fn writeRecordHeader(w: *Io.Writer, kind: Kind, archive_path: []const u8, mode: u32, size: u64) !void {
    if (kind != .end) try validatePath(archive_path, true);
    if (archive_path.len > max_path) return error.NameTooLong;
    var header: [record_header_len]u8 = undefined;
    header[0] = @intFromEnum(kind);
    std.mem.writeInt(u16, header[1..3], @intCast(archive_path.len), .little);
    std.mem.writeInt(u32, header[3..7], mode & 0o777, .little);
    std.mem.writeInt(u64, header[7..15], size, .little);
    header[15] = 0;
    try w.writeAll(&header);
    try w.writeAll(archive_path);
}

/// Extracts the archive file at `archive_path` into the new `host_path`.
pub fn extractFile(allocator: std.mem.Allocator, io: Io, archive_path: []const u8, host_path: []const u8) !void {
    var archive = try Io.Dir.openFileAbsolute(io, archive_path, .{ .mode = .read_only, .allow_directory = false });
    defer archive.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var archive_reader = archive.readerStreaming(io, &buffer);
    extract(allocator, io, &archive_reader.interface, host_path) catch |err| switch (err) {
        error.ReadFailed => return archive_reader.err.?,
        else => |e| return e,
    };
}

/// Extracts a guest-produced archive into `host_path`, which must not exist.
/// The root record becomes `host_path`; on any error the partial destination
/// is removed.
fn extract(allocator: std.mem.Allocator, io: Io, in: *Io.Reader, host_path: []const u8) !void {
    var header: [magic.len]u8 = undefined;
    try readExact(in, &header);
    if (!std.mem.eql(u8, &header, magic)) return error.BadCopyArchive;

    var path_buf: [max_path]u8 = undefined;
    const root = try readRecord(in, &path_buf);
    if (root.path.len != 0) return error.BadCopyArchive;

    var parent = try openDirPath(io, std.fs.path.dirname(host_path) orelse ".", .{});
    defer parent.close(io);
    const base = try allocator.dupeSentinel(u8, std.fs.path.basename(host_path), 0);
    defer allocator.free(base);
    switch (root.kind) {
        .file => {
            const file = try createFileAt(parent.handle, base, root.mode);
            var keep = false;
            defer {
                file.close(io);
                if (!keep) _ = std.c.unlinkat(parent.handle, base, 0);
            }
            try copyFileBytes(io, in, file, root.size);
            if ((try readRecord(in, &path_buf)).kind != .end) return error.BadCopyArchive;
            try expectEof(in);
            keep = true;
        },
        .directory => {
            try makeDirAt(parent.handle, base, root.mode);
            var keep = false;
            defer if (!keep) parent.deleteTree(io, base) catch {};
            const dest = std.c.openat(parent.handle, base, directory_flags);
            if (dest < 0) return error.OpenFailed;
            defer _ = std.c.close(dest);
            var name_buf: [max_path + 1]u8 = undefined;
            while (true) {
                const record = try readRecord(in, &path_buf);
                if (record.kind == .end) break;
                if (record.path.len == 0) return error.BadCopyArchive;
                const entry = try openParentAt(dest, record.path, &name_buf);
                defer if (entry.dir != dest) {
                    _ = std.c.close(entry.dir);
                };
                switch (record.kind) {
                    .file => {
                        const file = try createFileAt(entry.dir, entry.name, record.mode);
                        defer file.close(io);
                        try copyFileBytes(io, in, file, record.size);
                    },
                    .directory => try makeDirAt(entry.dir, entry.name, record.mode),
                    .end => unreachable,
                }
            }
            try expectEof(in);
            keep = true;
        },
        .end => return error.BadCopyArchive,
    }
}

const directory_flags: std.c.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true };

const ParentEntry = struct {
    dir: std.c.fd_t,
    name: [*:0]const u8,
};

/// Opens the directory that holds `path`'s last component, walking from
/// `root` one component at a time without following symlinks, so a symlink
/// swapped in for a directory fails the walk instead of redirecting it.
fn openParentAt(root: std.c.fd_t, path: []const u8, buf: *[max_path + 1]u8) !ParentEntry {
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var dir = root;
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, buf[0..path.len], start, '/')) |slash| {
        buf[slash] = 0;
        const next = std.c.openat(dir, buf[start..slash :0].ptr, directory_flags);
        if (dir != root) _ = std.c.close(dir);
        if (next < 0) return error.OpenFailed;
        dir = next;
        start = slash + 1;
    }
    return .{ .dir = dir, .name = buf[start..path.len :0].ptr };
}

/// Creates a new file. The guest mode goes to openat rather than fchmod, so
/// the process umask applies to it as it does for tar and cp.
fn createFileAt(dir: std.c.fd_t, name: [*:0]const u8, mode: u32) !Io.File {
    const flags: std.c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true };
    const fd = std.c.openat(dir, name, flags, @as(c_uint, mode & 0o777));
    if (fd < 0) return error.OpenFailed;
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Creates a new directory, owner-writable so children can land under a
/// read-only guest directory. mkdirat applies the process umask.
fn makeDirAt(dir: std.c.fd_t, name: [*:0]const u8, mode: u32) !void {
    if (std.c.mkdirat(dir, name, @intCast((mode & 0o777) | 0o700)) != 0) return error.CreateDirFailed;
}

fn readRecord(in: *Io.Reader, path_buf: *[max_path]u8) !Record {
    var header: [record_header_len]u8 = undefined;
    try readExact(in, &header);
    const kind: Kind = switch (header[0]) {
        @intFromEnum(Kind.file) => .file,
        @intFromEnum(Kind.directory) => .directory,
        @intFromEnum(Kind.end) => .end,
        else => return error.BadCopyArchive,
    };
    const path_len = std.mem.readInt(u16, header[1..3], .little);
    const mode = std.mem.readInt(u32, header[3..7], .little);
    const size = std.mem.readInt(u64, header[7..15], .little);
    if (header[15] != 0 or path_len > path_buf.len or (mode & ~@as(u32, 0o777)) != 0) return error.BadCopyArchive;
    const path = path_buf[0..path_len];
    try readExact(in, path);
    if (kind == .end) {
        if (path.len != 0 or mode != 0 or size != 0) return error.BadCopyArchive;
    } else {
        try validatePath(path, true);
        if (kind == .directory and size != 0) return error.BadCopyArchive;
    }
    return .{ .kind = kind, .path = path, .mode = mode, .size = size };
}

fn readExact(in: *Io.Reader, buf: []u8) !void {
    in.readSliceAll(buf) catch |err| switch (err) {
        error.EndOfStream => return error.BadCopyArchive,
        error.ReadFailed => return error.ReadFailed,
    };
}

fn expectEof(in: *Io.Reader) !void {
    _ = in.peekByte() catch |err| switch (err) {
        error.EndOfStream => return,
        error.ReadFailed => return error.ReadFailed,
    };
    return error.BadCopyArchive;
}

fn copyFileBytes(io: Io, in: *Io.Reader, file: Io.File, size: u64) !void {
    var buf: [64 * 1024]u8 = undefined;
    var remaining = size;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, buf.len));
        try readExact(in, buf[0..want]);
        try file.writeStreamingAll(io, buf[0..want]);
        remaining -= want;
    }
}

fn validatePath(path: []const u8, allow_root: bool) !void {
    if (path.len == 0) {
        if (allow_root) return;
        return error.BadCopyArchivePath;
    }
    if (path.len > max_path or path[0] == '/' or path[path.len - 1] == '/') return error.BadCopyArchivePath;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0) return error.BadCopyArchivePath;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.BadCopyArchivePath;
        if (std.mem.indexOfScalar(u8, part, 0) != null) return error.BadCopyArchivePath;
    }
}

/// Creates a new private file without following a final symlink.
pub fn openHostFileCreate(allocator: std.mem.Allocator, path: []const u8) !std.c.fd_t {
    const pathz = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(pathz);
    const fd = std.c.open(pathz, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0o600));
    if (fd < 0) return error.OpenFailed;
    return fd;
}

fn modeFromStat(stat: Io.File.Stat) u32 {
    return @intCast(@intFromEnum(stat.permissions) & 0o777);
}

fn openDirPath(io: Io, path: []const u8, flags: Io.Dir.OpenOptions) !Io.Dir {
    if (Io.Dir.path.isAbsolute(path)) return Io.Dir.openDirAbsolute(io, path, flags);
    return Io.Dir.cwd().openDir(io, path, flags);
}

test "copy archive paths reject traversal" {
    try validatePath("", true);
    try validatePath("dir/file.txt", false);
    try validatePath("one-two/three_four", false);

    try std.testing.expectError(error.BadCopyArchivePath, validatePath("", false));
    try std.testing.expectError(error.BadCopyArchivePath, validatePath("/absolute", true));
    try std.testing.expectError(error.BadCopyArchivePath, validatePath("dir/", true));
    try std.testing.expectError(error.BadCopyArchivePath, validatePath("dir//file", true));
    try std.testing.expectError(error.BadCopyArchivePath, validatePath(".", true));
    try std.testing.expectError(error.BadCopyArchivePath, validatePath("dir/..", true));
    try std.testing.expectError(error.BadCopyArchivePath, validatePath("dir/./file", true));
    try std.testing.expectError(error.BadCopyArchivePath, validatePath("dir\x00/file", true));
}

test "copy archive extraction writes children under read-only directories" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.writeAll(magic);
    try writeRecordHeader(&w, .directory, "", 0o555, 0);
    try writeRecordHeader(&w, .file, "child.txt", 0o644, 8);
    try w.writeAll("readonly");
    try writeRecordHeader(&w, .end, "", 0, 0);

    var tmp = try TestDir.init();
    defer tmp.deinit();
    const allocator = std.testing.allocator;
    const out = try tmp.path("out");
    var in: Io.Reader = .fixed(w.buffered());
    try extract(allocator, std.testing.io, &in, out);

    const data = try tmp.dir.readFileAlloc(std.testing.io, "out/child.txt", allocator, .limited(32));
    defer allocator.free(data);
    try std.testing.expectEqualStrings("readonly", data);
}

test "copy archive extraction applies the process umask to guest modes" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.writeAll(magic);
    try writeRecordHeader(&w, .directory, "", 0o777, 0);
    try writeRecordHeader(&w, .file, "file", 0o666, 1);
    try w.writeAll("x");
    try writeRecordHeader(&w, .directory, "dir", 0o777, 0);
    try writeRecordHeader(&w, .end, "", 0, 0);

    var tmp = try TestDir.init();
    defer tmp.deinit();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const out = try tmp.path("out");
    const old_umask = std.c.umask(0o027);
    defer _ = std.c.umask(old_umask);
    var in: Io.Reader = .fixed(w.buffered());
    try extract(allocator, io, &in, out);

    const Expected = struct { path: []const u8, mode: u32 };
    for ([_]Expected{
        .{ .path = "out", .mode = 0o750 },
        .{ .path = "out/file", .mode = 0o640 },
        .{ .path = "out/dir", .mode = 0o750 },
    }) |expected| {
        const stat = try tmp.dir.statFile(io, expected.path, .{ .follow_symlinks = false });
        try std.testing.expectEqual(expected.mode, modeFromStat(stat));
    }
}

/// Serves `before`, then replaces `out/sub` under `dir` with a symlink to
/// `outside`, then serves `after`.
const SwapReader = struct {
    interface: Io.Reader,
    dir: Io.Dir,
    before: []const u8,
    after: []const u8,
    swapped: bool = false,

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *SwapReader = @alignCast(@fieldParentPtr("interface", r));
        const io = std.testing.io;
        if (self.before.len == 0 and !self.swapped) {
            self.dir.rename("out/sub", self.dir, "out/moved", io) catch return error.ReadFailed;
            self.dir.symLink(io, "../outside", "out/sub", .{}) catch return error.ReadFailed;
            self.swapped = true;
        }
        const part = if (self.before.len != 0) &self.before else &self.after;
        if (part.len == 0) return error.EndOfStream;
        const n = try w.write(limit.sliceConst(part.*));
        part.* = part.*[n..];
        return n;
    }
};

test "copy archive extraction does not follow a directory swapped for a symlink" {
    var before_buf: [128]u8 = undefined;
    var before: Io.Writer = .fixed(&before_buf);
    try before.writeAll(magic);
    try writeRecordHeader(&before, .directory, "", 0o755, 0);
    try writeRecordHeader(&before, .directory, "sub", 0o755, 0);
    var after_buf: [128]u8 = undefined;
    var after: Io.Writer = .fixed(&after_buf);
    try writeRecordHeader(&after, .file, "sub/x", 0o644, 1);
    try after.writeAll("x");
    try writeRecordHeader(&after, .end, "", 0, 0);

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try tmp.dir.createDir(io, "outside", .default_dir);
    const out = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "out" });
    defer allocator.free(out);

    var read_buf: [64]u8 = undefined;
    var reader: SwapReader = .{
        .interface = .{ .vtable = &.{ .stream = SwapReader.stream }, .buffer = &read_buf, .seek = 0, .end = 0 },
        .dir = tmp.dir,
        .before = before.buffered(),
        .after = after.buffered(),
    };
    try std.testing.expectError(error.OpenFailed, extract(allocator, io, &reader.interface, out));
    try std.testing.expect(reader.swapped);

    var outside = try tmp.dir.openDir(io, "outside", .{ .iterate = true });
    defer outside.close(io);
    var it = outside.iterate();
    try std.testing.expectEqual(null, try it.next(io));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "out", .{ .follow_symlinks = false }));
}

/// Extracts `input` into `<tmp>/guard/out` and checks that nothing appears
/// anywhere else under `<tmp>`, that a failure leaves no destination, and that
/// a success creates only regular files and directories holding no more bytes
/// than the input carried. Returns whether extraction succeeded.
fn expectContainedExtraction(input: []const u8) !bool {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = fuzz_support.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "guard", .default_dir);
    const out = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "guard", "out" });
    defer allocator.free(out);

    var in: Io.Reader = .fixed(input);
    const extracted = if (extract(allocator, io, &in, out)) true else |_| false;

    var walker = try tmp.dir.walk(allocator);
    defer walker.deinit();
    var created = false;
    var file_bytes: u64 = 0;
    while (try walker.next(io)) |entry| {
        if (std.mem.eql(u8, entry.path, "guard")) continue;
        if (!std.mem.eql(u8, entry.path, "guard" ++ std.fs.path.sep_str ++ "out") and
            !std.mem.startsWith(u8, entry.path, "guard" ++ std.fs.path.sep_str ++ "out" ++ std.fs.path.sep_str))
        {
            std.debug.print("extraction escaped its destination: {s}\n", .{entry.path});
            return error.TestUnexpectedResult;
        }
        created = true;
        switch (entry.kind) {
            .file => file_bytes += (try entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false })).size,
            .directory => {},
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expectEqual(extracted, created);
    try std.testing.expect(file_bytes <= input.len);
    return extracted;
}

test "copy archive extraction fails closed on hostile records" {
    const Case = struct { path: []const u8, kind: Kind = .file, size: u64 = 1, payload: []const u8 = "x", trailer: []const u8 = "" };
    const cases = [_]Case{
        .{ .path = "../escape" },
        .{ .path = "/tmp/escape" },
        .{ .path = "a/../../escape" },
        .{ .path = "a/b" },
        .{ .path = "x", .size = 4, .payload = "ab" },
        .{ .path = "x", .trailer = "trailing" },
    };
    for (cases) |case| {
        var buf: [256]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        try w.writeAll(magic);
        try writeRecordHeader(&w, .directory, "", 0o755, 0);
        // Hand-written header: writeRecordHeader would refuse the bad paths.
        var header: [record_header_len]u8 = @splat(0);
        header[0] = @intFromEnum(case.kind);
        std.mem.writeInt(u16, header[1..3], @intCast(case.path.len), .little);
        std.mem.writeInt(u32, header[3..7], 0o644, .little);
        std.mem.writeInt(u64, header[7..15], case.size, .little);
        try w.writeAll(&header);
        try w.writeAll(case.path);
        try w.writeAll(case.payload);
        try writeRecordHeader(&w, .end, "", 0, 0);
        try w.writeAll(case.trailer);
        try std.testing.expect(!try expectContainedExtraction(w.buffered()));
    }

    // A duplicate entry must not replace the first one.
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.writeAll(magic);
    try writeRecordHeader(&w, .directory, "", 0o755, 0);
    for (0..2) |_| {
        try writeRecordHeader(&w, .file, "dup", 0o644, 1);
        try w.writeAll("x");
    }
    try writeRecordHeader(&w, .end, "", 0, 0);
    try std.testing.expect(!try expectContainedExtraction(w.buffered()));
}

const FuzzSeed = struct {
    bytes: [1024]u8,
    len: usize,
};

fn fuzzExtract(seed: FuzzSeed, s: *std.testing.Smith) !void {
    var bytes = seed.bytes;
    const input = bytes[0..seed.len];
    const mutations = s.valueRangeAtMost(u8, 0, 4);
    for (0..mutations) |_| input[s.index(input.len)] = s.value(u8);
    const cut = s.valueRangeAtMost(u32, 0, @intCast(input.len));
    const extracted = try expectContainedExtraction(input[0 .. input.len - cut]);
    // The unmutated seed is a real archive and must extract.
    if (mutations == 0 and cut == 0) try std.testing.expect(extracted);
}

test "fuzz copy archive extraction" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Seed with a real archive of a small tree so mutations reach record
    // parsing and file creation rather than stopping at the magic.
    var seed: FuzzSeed = .{ .bytes = undefined, .len = 0 };
    {
        var tree = fuzz_support.tmpDir(.{});
        defer tree.cleanup();
        try tree.dir.createDir(io, "src", @enumFromInt(0o750));
        try tree.dir.createDir(io, "src/sub", @enumFromInt(0o700));
        try tree.dir.createDir(io, "src/sub/empty", @enumFromInt(0o755));
        try tree.dir.writeFile(io, .{ .sub_path = "src/a.txt", .data = "alpha\n" });
        try tree.dir.writeFile(io, .{ .sub_path = "src/sub/b.bin", .data = "\x00\x01\x02bravo" });
        const src = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tree.sub_path, "src" });
        defer allocator.free(src);

        var w: Io.Writer = .fixed(&seed.bytes);
        try write(allocator, io, &w, src);
        seed.len = w.end;
    }

    try std.testing.fuzz(seed, fuzzExtract, .{});
}
