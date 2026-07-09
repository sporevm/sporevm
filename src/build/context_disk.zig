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
    index: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
            .entries = std.array_list.Managed(build_context.CopyResolvedEntry).init(allocator),
        };
    }

    pub fn addResolvedEntries(self: *Builder, entries: []const build_context.CopyResolvedEntry) !void {
        for (entries) |entry| {
            if (self.index.contains(entry.rel)) continue;
            try self.index.put(self.allocator, entry.rel, {});
            try self.entries.append(entry);
        }
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
        const dir = try std.fs.path.join(self.allocator, &.{ cache_root, context_disk_dir });
        try chunk_sealer.ensureDirPath(self.allocator, dir);
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.ext4", .{ dir, disk_digest });

        diagnostic.entries = self.entries.items.len;
        diagnostic.bytes = content_bytes;
        diagnostic.image_size = image_size;
        diagnostic.digest = disk_digest;
        diagnostic.path = path;

        if (try reusableDisk(io, path, image_size)) {
            diagnostic.reused = true;
            return path;
        }

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
        diagnostic.emit_ns = elapsedNs(start);
        diagnostic.emitted = true;
        return path;
    }

    fn diskDigest(self: Builder, allocator: std.mem.Allocator) ![]const u8 {
        var h = Blake3.init(.{});
        hashField(&h, "spore-build-context-disk-v1");
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
        }
        var raw: [Blake3.digest_length]u8 = undefined;
        h.final(&raw);
        const hex = std.fmt.bytesToHex(raw, .lower);
        return std.fmt.allocPrint(allocator, "blake3:{s}", .{&hex});
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
                    const source_path = try self.allocator.dupe(u8, entry.source_path);
                    try out.append(.{
                        .path = entry.rel,
                        .kind = .{ .file_source = .{ .file = tar.FileSlice{
                            .path = source_path,
                            .offset = 0,
                            .size = entry.size,
                        } } },
                        .mode = @intCast(entry.mode),
                        .uid = 0,
                        .gid = 0,
                    });
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

fn reusableDisk(io: Io, path: []const u8, expected_size: u64) !bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return stat.kind == .file and stat.size == expected_size;
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
