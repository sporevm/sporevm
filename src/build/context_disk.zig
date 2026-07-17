const std = @import("std");
const Io = std.Io;
const Blake3 = std.crypto.hash.Blake3;

const build_context = @import("context.zig");
const chunk_sealer = @import("../chunk_sealer.zig");
const ext4 = @import("../rootfs/ext4.zig");
const ext4_writer = @import("../rootfs/ext4_writer.zig");
const rootfs_cas = @import("../rootfs_cas.zig");
const tar = @import("../rootfs/tar.zig");

const context_disk_dir = "build/context-disks";
const complete_stamp_contents_v1 = "spore-build-context-disk-complete-v1\n";
const complete_stamp_contents_v2 = "spore-build-context-disk-complete-v2-mtime\n";

pub const Diagnostic = struct {
    entries: u64 = 0,
    bytes: u64 = 0,
    image_size: u64 = 0,
    emitted: bool = false,
    reused: bool = false,
    emit_ns: u64 = 0,
    digest: []const u8 = "",
    path: []const u8 = "",
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    entries: std.array_list.Managed(build_context.CopyResolvedEntry),
    copy_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
            .entries = std.array_list.Managed(build_context.CopyResolvedEntry).init(allocator),
        };
    }

    pub fn addCapturedCopy(self: *Builder, entries: []const build_context.CopyResolvedEntry) ![]const u8 {
        const prefix = try std.fmt.allocPrint(self.allocator, "s{d}", .{self.copy_count});
        self.copy_count += 1;
        try self.entries.append(.{
            .rel = prefix,
            .kind = .directory,
            .mode = 0o755,
        });
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.rel, ".")) continue;
            if (entry.kind == .file) {
                const has_snapshot = entry.snapshot_path.len != 0;
                const has_inline = entry.inline_data != null;
                if (has_snapshot == has_inline) return error.InvalidCopySourceBacking;
                if (entry.inline_data) |data| if (data.len != entry.size) return error.InvalidCopySourceBacking;
            }
            var disk_entry = entry;
            disk_entry.rel = try std.fs.path.join(self.allocator, &.{ prefix, entry.rel });
            try self.entries.append(disk_entry);
        }
        return prefix;
    }

    pub fn hasEntries(self: Builder) bool {
        return self.entries.items.len != 0;
    }

    pub fn emitOrReuse(
        self: *Builder,
        io: Io,
        cache_root: []const u8,
        diagnostic: *Diagnostic,
    ) !?[]const u8 {
        if (self.entries.items.len == 0) return null;
        std.mem.sort(build_context.CopyResolvedEntry, self.entries.items, {}, entryLessThan);

        var content_bytes: u64 = 0;
        for (self.entries.items) |entry| {
            if (entry.kind == .file) content_bytes = try std.math.add(u64, content_bytes, entry.size);
        }
        const image_size = ext4.computeImageSize(content_bytes);
        const inode_count_u64 = ext4.computeImageInodes(@intCast(self.entries.items.len + 1));
        if (inode_count_u64 > std.math.maxInt(u32)) return error.ContextDiskTooManyEntries;
        const inode_count: u32 = @intCast(inode_count_u64);
        const disk_digest = try self.diskDigest(self.allocator);
        const stamp_contents = self.completeStampContents();
        const dir = try std.fs.path.join(self.allocator, &.{ cache_root, context_disk_dir });
        try chunk_sealer.ensureDirPath(self.allocator, dir);
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.ext4", .{ dir, disk_digest });
        const stamp_path = try completeStampPath(self.allocator, path);

        diagnostic.entries = self.entries.items.len;
        diagnostic.bytes = content_bytes;
        diagnostic.image_size = image_size;
        diagnostic.digest = disk_digest;
        diagnostic.path = path;

        if (try reusableDisk(self.allocator, io, path, stamp_path, image_size, stamp_contents)) {
            diagnostic.reused = true;
            return path;
        }

        Io.Dir.cwd().deleteFile(io, stamp_path) catch {};
        const start = monotonicNs() catch 0;
        const temp = try std.fmt.allocPrint(self.allocator, "{s}.{d}.tmp", .{ path, std.c.getpid() });
        Io.Dir.cwd().deleteFile(io, temp) catch {};
        defer Io.Dir.cwd().deleteFile(io, temp) catch {};

        const ext4_entries = try self.ext4Entries();
        _ = try ext4_writer.emit(self.allocator, io, temp, ext4_entries, .{
            .image_size = image_size,
            .inode_count = inode_count,
            .determinism = ext4.Determinism.fromDigest(disk_digest),
            .cas_cache_root = cache_root,
            .cas_chunk_size = rootfs_cas.default_chunk_size,
        });
        try chmodReadOnly(self.allocator, temp);
        try renameReplace(self.allocator, temp, path);
        try chunk_sealer.writeFileAtomicDurable(self.allocator, stamp_path, stamp_contents, 0o444);
        diagnostic.emit_ns = elapsedNs(start);
        diagnostic.emitted = true;
        return path;
    }

    fn diskDigest(self: Builder, allocator: std.mem.Allocator) ![]const u8 {
        var h = Blake3.init(.{});
        const includes_mtime = self.includesCapturedMtime();
        hashField(&h, if (includes_mtime) "spore-build-context-disk-v2-mtime" else "spore-build-context-disk-v1");
        for (self.entries.items) |entry| {
            hashField(&h, entry.rel);
            hashField(&h, @tagName(entry.kind));
            var mode_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &mode_buf, entry.mode, .little);
            hashField(&h, &mode_buf);
            var size_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &size_buf, entry.size, .little);
            hashField(&h, &size_buf);
            switch (entry.kind) {
                .file => hashField(&h, entry.content_digest),
                .directory => hashField(&h, ""),
                .sym_link => hashField(&h, entry.symlink_target),
                else => return error.UnsupportedCopySourceType,
            }
            if (includes_mtime) {
                if (entry.captured_mtime) |mtime| {
                    hashField(&h, "mtime-present");
                    var seconds_buf: [8]u8 = undefined;
                    std.mem.writeInt(i64, &seconds_buf, mtime.seconds, .little);
                    hashField(&h, &seconds_buf);
                    var nanoseconds_buf: [4]u8 = undefined;
                    std.mem.writeInt(u32, &nanoseconds_buf, mtime.nanoseconds, .little);
                    hashField(&h, &nanoseconds_buf);
                } else {
                    hashField(&h, "mtime-absent");
                }
            }
        }
        var raw: [Blake3.digest_length]u8 = undefined;
        h.final(&raw);
        const hex = std.fmt.bytesToHex(raw, .lower);
        return std.fmt.allocPrint(allocator, "blake3:{s}", .{&hex});
    }

    fn includesCapturedMtime(self: Builder) bool {
        for (self.entries.items) |entry| if (entry.captured_mtime != null) return true;
        return false;
    }

    fn completeStampContents(self: Builder) []const u8 {
        return if (self.includesCapturedMtime()) complete_stamp_contents_v2 else complete_stamp_contents_v1;
    }

    fn ext4Entries(self: Builder) ![]const ext4_writer.Entry {
        var out = std.array_list.Managed(ext4_writer.Entry).init(self.allocator);
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.rel, ".")) continue;
            switch (entry.kind) {
                .directory => try out.append(.{
                    .path = entry.rel,
                    .kind = .directory,
                    .mode = @intCast(entry.mode),
                    .uid = 0,
                    .gid = 0,
                }),
                .file => {
                    if (entry.inline_data) |data| {
                        try out.append(.{
                            .path = entry.rel,
                            .kind = .{ .file = data },
                            .mode = @intCast(entry.mode),
                            .uid = 0,
                            .gid = 0,
                            .mtime = ext4Mtime(entry.captured_mtime),
                        });
                    } else {
                        if (entry.snapshot_path.len == 0) return error.CopySourceNotSnapshotted;
                        const source_path = try self.allocator.dupe(u8, entry.snapshot_path);
                        try out.append(.{
                            .path = entry.rel,
                            .kind = .{ .file_source = .{ .file = tar.FileSlice{
                                .path = source_path,
                                .offset = entry.snapshot_offset,
                                .size = entry.size,
                            } } },
                            .mode = @intCast(entry.mode),
                            .uid = 0,
                            .gid = 0,
                            .mtime = ext4Mtime(entry.captured_mtime),
                        });
                    }
                },
                .sym_link => try out.append(.{
                    .path = entry.rel,
                    .kind = .{ .symlink = entry.symlink_target },
                    .mode = @intCast(entry.mode),
                    .uid = 0,
                    .gid = 0,
                }),
                else => return error.UnsupportedCopySourceType,
            }
        }
        return out.toOwnedSlice();
    }
};

fn reusableDisk(allocator: std.mem.Allocator, io: Io, path: []const u8, stamp_path: []const u8, expected_size: u64, expected_stamp: []const u8) !bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    if (stat.kind != .file or stat.size != expected_size) return false;
    const stamp_stat = Io.Dir.cwd().statFile(io, stamp_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    if (stamp_stat.kind != .file or stamp_stat.size != expected_stamp.len) return false;
    const stamp = Io.Dir.cwd().readFileAlloc(io, stamp_path, allocator, .limited(expected_stamp.len + 1)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return false,
        else => |e| return e,
    };
    defer allocator.free(stamp);
    return std.mem.eql(u8, stamp, expected_stamp);
}

fn ext4Mtime(value: ?build_context.CapturedMtime) ?ext4_writer.Mtime {
    const mtime = value orelse return null;
    return .{ .seconds = mtime.seconds, .nanoseconds = mtime.nanoseconds };
}

fn completeStampPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.complete", .{path});
}

fn chmodReadOnly(allocator: std.mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (std.c.chmod(path_z.ptr, 0o444) != 0) return error.ContextDiskPublishFailed;
}

fn renameReplace(allocator: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    const from_z = try allocator.dupeZ(u8, from);
    defer allocator.free(from_z);
    const to_z = try allocator.dupeZ(u8, to);
    defer allocator.free(to_z);
    if (std.c.rename(from_z.ptr, to_z.ptr) != 0) return error.ContextDiskPublishFailed;
}

fn entryLessThan(_: void, a: build_context.CopyResolvedEntry, b: build_context.CopyResolvedEntry) bool {
    return std.mem.lessThan(u8, a.rel, b.rel);
}

fn hashField(h: *Blake3, bytes: []const u8) void {
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, bytes.len, .little);
    h.update(&len_buf);
    h.update(bytes);
}

fn monotonicNs() !u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return error.ClockFailed;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn elapsedNs(start_ns: u64) u64 {
    if (start_ns == 0) return 0;
    const end_ns = monotonicNs() catch return 0;
    if (end_ns <= start_ns) return 0;
    return end_ns - start_ns;
}

test "mtime context disk requires a v2 complete stamp before reuse" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = "zig-cache/test-build-context-disk-complete-stamp";
    const cache_root = root ++ "/cache";
    const context_root = root ++ "/context";
    const source_path = context_root ++ "/source.txt";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, cache_root);
    try Io.Dir.cwd().createDirPath(io, context_root);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = "context disk source" });

    var ignore_diag: build_context.IgnoreDiagnostic = .{};
    const context = try build_context.load(arena, io, context_root, &ignore_diag);
    const resolution = try build_context.resolveCopySources(arena, io, context, &.{"source.txt"});
    var snapshot = try build_context.CopySnapshot.init(arena, io, cache_root);
    defer snapshot.deinit(io);
    const captured = try build_context.captureCopyResolutionWithOptions(arena, io, context, resolution, .{ .capture_mtime = true }, &snapshot);

    var builder = Builder.init(arena);
    _ = try builder.addCapturedCopy(captured);
    try snapshot.seal(io);
    try Io.Dir.cwd().deleteFile(io, source_path);
    const image_size = ext4.computeImageSize("context disk source".len);
    const disk_digest = try builder.diskDigest(arena);
    const disk_dir = try std.fs.path.join(arena, &.{ cache_root, context_disk_dir });
    try chunk_sealer.ensureDirPath(arena, disk_dir);
    const disk_path = try std.fmt.allocPrint(arena, "{s}/{s}.ext4", .{ disk_dir, disk_digest });

    var corrupt = try Io.Dir.cwd().createFile(io, disk_path, .{});
    try corrupt.setLength(io, image_size);
    corrupt.close(io);

    var emitted: Diagnostic = .{};
    _ = try builder.emitOrReuse(io, cache_root, &emitted);
    try std.testing.expect(emitted.emitted);
    try std.testing.expect(!emitted.reused);

    var reused: Diagnostic = .{};
    _ = try builder.emitOrReuse(io, cache_root, &reused);
    try std.testing.expect(reused.reused);
    try std.testing.expect(!reused.emitted);
}

test "context disk isolates each COPY in its own transport namespace" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var builder = Builder.init(arena);
    const first = try builder.addCapturedCopy(&.{
        .{ .rel = "dir", .kind = .directory, .mode = 0o755 },
        .{ .rel = "dir/a.txt", .kind = .file, .mode = 0o644, .size = 1, .content_digest = "blake3:a", .snapshot_path = "snapshot", .snapshot_offset = 0 },
    });
    const second = try builder.addCapturedCopy(&.{
        .{ .rel = "dir", .kind = .directory, .mode = 0o755 },
        .{ .rel = "dir/b.txt", .kind = .file, .mode = 0o644, .size = 1, .content_digest = "blake3:b", .snapshot_path = "snapshot", .snapshot_offset = 1 },
    });

    try std.testing.expectEqualStrings("s0", first);
    try std.testing.expectEqualStrings("s1", second);
    try std.testing.expectEqual(@as(usize, 6), builder.entries.items.len);
    try std.testing.expectEqualStrings("s0/dir/a.txt", builder.entries.items[2].rel);
    try std.testing.expectEqualStrings("s1/dir/b.txt", builder.entries.items[5].rel);
}

test "captured mtime selects v2 transport identity without changing v1" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var legacy = Builder.init(arena);
    _ = try legacy.addCapturedCopy(&.{.{
        .rel = "input",
        .kind = .file,
        .mode = 0o644,
        .size = 5,
        .content_digest = "blake3:content",
        .inline_data = "input",
    }});
    const legacy_digest = try legacy.diskDigest(arena);
    try std.testing.expectEqualStrings(
        "blake3:8c791019ccaf9623df73a70089feb675cbf8f0b2ec706433451d22e50854463a",
        legacy_digest,
    );
    try std.testing.expectEqualStrings(complete_stamp_contents_v1, legacy.completeStampContents());

    var first = Builder.init(arena);
    _ = try first.addCapturedCopy(&.{.{
        .rel = "input",
        .kind = .file,
        .mode = 0o644,
        .size = 5,
        .content_digest = "blake3:content",
        .inline_data = "input",
        .captured_mtime = .{ .seconds = 1_700_000_000, .nanoseconds = 123_456_789 },
    }});
    const first_digest = try first.diskDigest(arena);
    try std.testing.expectEqualStrings(complete_stamp_contents_v2, first.completeStampContents());
    try std.testing.expect(!std.mem.eql(u8, legacy_digest, first_digest));
    const first_entries = try first.ext4Entries();
    try std.testing.expectEqual(ext4_writer.Mtime{
        .seconds = 1_700_000_000,
        .nanoseconds = 123_456_789,
    }, first_entries[1].mtime.?);

    var changed = Builder.init(arena);
    _ = try changed.addCapturedCopy(&.{.{
        .rel = "input",
        .kind = .file,
        .mode = 0o644,
        .size = 5,
        .content_digest = "blake3:content",
        .inline_data = "input",
        .captured_mtime = .{ .seconds = 1_700_000_001, .nanoseconds = 123_456_789 },
    }});
    try std.testing.expect(!std.mem.eql(u8, first_digest, try changed.diskDigest(arena)));
}
