//! One-level chunk-mapped disk backend for writable runtime disks.
//!
//! Reads are resolved through an in-memory per-chunk source map. Writes land in
//! a sparse overlay fd and flip the affected chunks to the overlay source. The
//! flat base remains the hot read source in U2; later slices add CAS fault-in
//! sources and durable index snapshotting on top of the same map.

const std = @import("std");
const builtin = @import("builtin");
const block_source = @import("block_source.zig");
const chunk_sealer = @import("chunk_sealer.zig");
const disk_index = @import("disk_index.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const spore = @import("spore.zig");

extern "c" fn mkstemp(template: [*:0]u8) c_int;

pub const Error = error{
    BadClusterSize,
    BadDiskSize,
    OutOfRange,
    ReadOnly,
    ShortRead,
    ShortWrite,
    ResizeFailed,
    FlushFailed,
} || chunk_sealer.Error || spore.Error || block_source.Error || std.mem.Allocator.Error;

const Source = enum(u8) {
    base,
    overlay,
    zero,
};

pub const ForkCloneMethod = enum {
    reflink,
    copy,
};

pub const ForkOptions = struct {
    force_copy: bool = false,
};

pub const ForkedDisk = struct {
    disk: ChunkMappedDisk,
    clone_method: ForkCloneMethod,

    pub fn deinit(self: *ForkedDisk) void {
        if (self.disk.overlay_fd) |fd| {
            _ = std.c.close(fd);
            self.disk.overlay_fd = null;
        }
        self.disk.deinit();
        self.* = undefined;
    }
};

pub const ChunkMappedDisk = struct {
    allocator: std.mem.Allocator,
    base: block_source.FileBlockSource,
    overlay_fd: ?std.c.fd_t,
    size: u64,
    chunk_size: u64,
    sources: []Source,

    pub fn initReadOnly(
        allocator: std.mem.Allocator,
        base: block_source.FileBlockSource,
        size: u64,
        chunk_size: u64,
    ) Error!ChunkMappedDisk {
        return init(allocator, base, null, size, chunk_size);
    }

    pub fn initWritable(
        allocator: std.mem.Allocator,
        base: block_source.FileBlockSource,
        overlay_fd: std.c.fd_t,
        size: u64,
        chunk_size: u64,
    ) Error!ChunkMappedDisk {
        return init(allocator, base, overlay_fd, size, chunk_size);
    }

    fn init(
        allocator: std.mem.Allocator,
        base: block_source.FileBlockSource,
        overlay_fd: ?std.c.fd_t,
        size: u64,
        chunk_size: u64,
    ) Error!ChunkMappedDisk {
        if (size == 0) return error.BadDiskSize;
        if (base.capacityBytes() < size) return error.BadDiskSize;
        if (chunk_size == 0 or chunk_size % 512 != 0 or chunk_size > std.math.maxInt(usize)) {
            return error.BadClusterSize;
        }
        const chunk_count = try computeChunkCount(size, chunk_size);
        if (chunk_count > std.math.maxInt(usize)) return error.BadDiskSize;
        if (overlay_fd) |fd| {
            const overlay_size = std.math.cast(std.c.off_t, size) orelse return error.BadDiskSize;
            if (std.c.ftruncate(fd, overlay_size) != 0) return error.ResizeFailed;
        }
        const sources = try allocator.alloc(Source, @intCast(chunk_count));
        @memset(sources, .base);
        return .{
            .allocator = allocator,
            .base = base,
            .overlay_fd = overlay_fd,
            .size = size,
            .chunk_size = chunk_size,
            .sources = sources,
        };
    }

    pub fn deinit(self: *ChunkMappedDisk) void {
        self.allocator.free(self.sources);
        self.* = undefined;
    }

    pub fn capacityBytes(self: ChunkMappedDisk) u64 {
        return self.size;
    }

    pub fn dirtyChunkCount(self: ChunkMappedDisk) usize {
        var count: usize = 0;
        for (self.sources) |source| {
            if (source == .overlay) count += 1;
        }
        return count;
    }

    pub fn dirtyClusterCount(self: ChunkMappedDisk) usize {
        return self.dirtyChunkCount();
    }

    pub fn chunkSize(self: ChunkMappedDisk) u64 {
        return self.chunk_size;
    }

    pub fn clusterSize(self: ChunkMappedDisk) u64 {
        return self.chunkSize();
    }

    pub fn chunkCount(self: ChunkMappedDisk) usize {
        return self.sources.len;
    }

    pub fn clusterCount(self: ChunkMappedDisk) usize {
        return self.chunkCount();
    }

    pub fn chunkLen(self: ChunkMappedDisk, chunk_index: usize) Error!usize {
        if (chunk_index >= self.sources.len) return error.OutOfRange;
        const start = std.math.mul(u64, chunk_index, self.chunk_size) catch return error.OutOfRange;
        const end = @min(std.math.add(u64, start, self.chunk_size) catch self.size, self.size);
        return std.math.cast(usize, end - start) orelse return error.BadClusterSize;
    }

    pub fn clusterLen(self: ChunkMappedDisk, chunk_index: usize) Error!usize {
        return self.chunkLen(chunk_index);
    }

    pub fn isDirtyChunk(self: ChunkMappedDisk, chunk_index: usize) Error!bool {
        if (chunk_index >= self.sources.len) return error.OutOfRange;
        return self.sources[chunk_index] == .overlay;
    }

    pub fn isDirtyCluster(self: ChunkMappedDisk, chunk_index: usize) Error!bool {
        return self.isDirtyChunk(chunk_index);
    }

    pub fn markZeroChunk(self: *ChunkMappedDisk, chunk_index: usize) Error!void {
        if (chunk_index >= self.sources.len) return error.OutOfRange;
        self.sources[chunk_index] = .zero;
    }

    pub fn readChunk(self: *ChunkMappedDisk, chunk_index: usize, buf: []u8) Error!void {
        const len = try self.chunkLen(chunk_index);
        if (buf.len != len) return error.OutOfRange;
        const offset = std.math.mul(u64, chunk_index, self.chunk_size) catch return error.OutOfRange;
        try self.readAt(buf, offset);
    }

    pub fn readCluster(self: *ChunkMappedDisk, chunk_index: usize, buf: []u8) Error!void {
        try self.readChunk(chunk_index, buf);
    }

    pub fn readAt(self: *ChunkMappedDisk, buf: []u8, offset: u64) Error!void {
        try self.checkRange(buf.len, offset);
        var cursor: usize = 0;
        while (cursor < buf.len) {
            const absolute = offset + cursor;
            const span = try self.spanFor(absolute, buf.len - cursor);
            const target = buf[cursor..][0..span.len];
            switch (self.sources[span.chunk_index]) {
                .base => try self.base.readAt(target, absolute),
                .overlay => try readExact(self.overlay_fd orelse return error.ShortRead, target, absolute),
                .zero => @memset(target, 0),
            }
            cursor += span.len;
        }
    }

    pub fn writeAt(self: *ChunkMappedDisk, buf: []const u8, offset: u64) Error!void {
        const overlay_fd = self.overlay_fd orelse return error.ReadOnly;
        try self.checkRange(buf.len, offset);
        var cursor: usize = 0;
        while (cursor < buf.len) {
            const absolute = offset + cursor;
            const span = try self.spanFor(absolute, buf.len - cursor);
            const full_chunk_write = span.chunk_offset == 0 and span.len == try self.chunkLen(span.chunk_index);
            if (self.sources[span.chunk_index] != .overlay and !full_chunk_write) {
                try self.seedChunk(span.chunk_index, overlay_fd);
            }
            try writeExact(overlay_fd, buf[cursor..][0..span.len], absolute);
            self.sources[span.chunk_index] = .overlay;
            cursor += span.len;
        }
    }

    pub fn flush(self: *ChunkMappedDisk) Error!void {
        if (self.overlay_fd) |fd| {
            if (std.c.fsync(fd) != 0) return error.FlushFailed;
        }
    }

    pub fn fork(self: *ChunkMappedDisk, options: ForkOptions) Error!ForkedDisk {
        const parent_fd = self.overlay_fd orelse return error.ReadOnly;
        const child_sources = try self.allocator.dupe(Source, self.sources);
        errdefer self.allocator.free(child_sources);

        const child_fd = try createTempOverlayFd(self.allocator);
        var fd_owned = true;
        errdefer {
            if (fd_owned) _ = std.c.close(child_fd);
        }

        const clone_method: ForkCloneMethod = if (!options.force_copy and tryCloneOverlay(parent_fd, child_fd))
            .reflink
        else blk: {
            try self.copyOverlayChunks(parent_fd, child_fd);
            break :blk .copy;
        };

        fd_owned = false;
        return .{
            .disk = .{
                .allocator = self.allocator,
                .base = self.base,
                .overlay_fd = child_fd,
                .size = self.size,
                .chunk_size = self.chunk_size,
                .sources = child_sources,
            },
            .clone_method = clone_method,
        };
    }

    pub fn snapshotIndex(self: *ChunkMappedDisk, dir: []const u8, device: spore.RootfsDevice) Error!spore.Disk {
        var chunks: std.ArrayList(disk_index.DiskIndexChunk) = .empty;
        errdefer {
            for (chunks.items) |entry| self.allocator.free(entry.digest);
            chunks.deinit(self.allocator);
        }
        var zero_chunks: std.ArrayList(u64) = .empty;
        errdefer zero_chunks.deinit(self.allocator);

        const object_dir = try objectDir(self.allocator, dir);
        defer self.allocator.free(object_dir);
        try chunk_sealer.ensureDirPath(self.allocator, object_dir);

        const max_chunk_size = std.math.cast(usize, self.chunk_size) orelse return error.BadClusterSize;
        const buf = try self.allocator.alloc(u8, max_chunk_size);
        defer self.allocator.free(buf);
        var work_stats: chunk_sealer.WorkStats = .{};

        for (0..self.chunkCount()) |chunk_index| {
            const len = try self.chunkLen(chunk_index);
            const data = buf[0..len];
            try self.readChunk(chunk_index, data);
            switch (try chunk_sealer.sealBytes(data, &work_stats)) {
                .zero => try zero_chunks.append(self.allocator, @intCast(chunk_index)),
                .data => |id| {
                    const hex = id.toHex();
                    const digest = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ spore.rootfs_digest_prefix, hex[0..] });
                    errdefer self.allocator.free(digest);
                    const object_path = try rootfs_cas.manifestObjectPath(self.allocator, dir, digest);
                    defer self.allocator.free(object_path);
                    try chunk_sealer.writePathAllIfMissingTimed(self.allocator, object_path, data, &work_stats);
                    try chunks.append(self.allocator, .{
                        .logical_chunk = @intCast(chunk_index),
                        .digest = digest,
                    });
                },
            }
        }

        const chunk_slice = try chunks.toOwnedSlice(self.allocator);
        defer {
            for (chunk_slice) |entry| self.allocator.free(entry.digest);
            self.allocator.free(chunk_slice);
        }
        const zero_slice = try zero_chunks.toOwnedSlice(self.allocator);
        defer self.allocator.free(zero_slice);

        const index = disk_index.DiskIndex{
            .kind = disk_index.disk_index_kind,
            .logical_size = self.size,
            .chunk_size = self.chunk_size,
            .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
            .object_namespace = spore.rootfs_storage_object_namespace,
            .chunks = chunk_slice,
            .zero_chunks = zero_slice,
        };
        const index_json = std.json.Stringify.valueAlloc(self.allocator, index, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
        defer self.allocator.free(index_json);
        const index_digest = try disk_index.indexDigestAlloc(self.allocator, index_json);
        errdefer self.allocator.free(index_digest);
        const index_path = try rootfs_cas.manifestIndexPath(self.allocator, dir, index_digest);
        defer self.allocator.free(index_path);
        const index_dir = std.fs.path.dirname(index_path) orelse return error.IoFailed;
        try chunk_sealer.ensureDirPath(self.allocator, index_dir);
        try chunk_sealer.writePathAllIfMissingTimed(self.allocator, index_path, index_json, &work_stats);

        const kind = try self.allocator.dupe(u8, spore.disk_kind_chunk_index);
        errdefer self.allocator.free(kind);
        const cloned_device = try spore.cloneRootfsDevice(self.allocator, device);
        errdefer {
            self.allocator.free(cloned_device.kind);
            self.allocator.free(cloned_device.role);
        }
        const hash_algorithm = try self.allocator.dupe(u8, spore.rootfs_storage_hash_algorithm_blake3);
        errdefer self.allocator.free(hash_algorithm);
        const object_namespace = try self.allocator.dupe(u8, spore.rootfs_storage_object_namespace);
        errdefer self.allocator.free(object_namespace);

        return .{
            .kind = kind,
            .device = cloned_device,
            .size = self.size,
            .base = index_digest,
            .chunk_size = self.chunk_size,
            .hash_algorithm = hash_algorithm,
            .object_namespace = object_namespace,
            .layers = &.{},
        };
    }

    fn checkRange(self: ChunkMappedDisk, len: usize, offset: u64) Error!void {
        const end = std.math.add(u64, offset, len) catch return error.OutOfRange;
        if (end > self.size) return error.OutOfRange;
    }

    fn spanFor(self: ChunkMappedDisk, offset: u64, remaining: usize) Error!Span {
        const chunk_index_u64 = offset / self.chunk_size;
        if (chunk_index_u64 > std.math.maxInt(usize)) return error.OutOfRange;
        const chunk_offset = offset % self.chunk_size;
        const left_in_chunk = self.chunk_size - chunk_offset;
        const len = @min(remaining, std.math.cast(usize, left_in_chunk) orelse return error.BadClusterSize);
        return .{
            .chunk_index = @intCast(chunk_index_u64),
            .chunk_offset = @intCast(chunk_offset),
            .len = len,
        };
    }

    fn seedChunk(self: *ChunkMappedDisk, chunk_index: usize, overlay_fd: std.c.fd_t) Error!void {
        const len = try self.chunkLen(chunk_index);
        const offset = std.math.mul(u64, chunk_index, self.chunk_size) catch return error.OutOfRange;
        const buf = try self.allocator.alloc(u8, len);
        defer self.allocator.free(buf);
        switch (self.sources[chunk_index]) {
            .base => try self.base.readAt(buf, offset),
            .overlay => return,
            .zero => @memset(buf, 0),
        }
        try writeExact(overlay_fd, buf, offset);
    }

    fn copyOverlayChunks(self: *ChunkMappedDisk, parent_fd: std.c.fd_t, child_fd: std.c.fd_t) Error!void {
        const overlay_size = std.math.cast(std.c.off_t, self.size) orelse return error.BadDiskSize;
        if (std.c.ftruncate(child_fd, overlay_size) != 0) return error.ResizeFailed;

        const max_chunk_size = std.math.cast(usize, self.chunk_size) orelse return error.BadClusterSize;
        const buf = try self.allocator.alloc(u8, max_chunk_size);
        defer self.allocator.free(buf);

        for (self.sources, 0..) |source, chunk_index| {
            if (source != .overlay) continue;
            const len = try self.chunkLen(chunk_index);
            const offset = std.math.mul(u64, chunk_index, self.chunk_size) catch return error.OutOfRange;
            const data = buf[0..len];
            try readExact(parent_fd, data, offset);
            try writeExact(child_fd, data, offset);
        }
    }
};

const Span = struct {
    chunk_index: usize,
    chunk_offset: usize,
    len: usize,
};

fn computeChunkCount(size: u64, chunk_size: u64) Error!u64 {
    return std.math.divCeil(u64, size, chunk_size) catch return error.BadDiskSize;
}

fn readExact(fd: std.c.fd_t, buf: []u8, offset: u64) Error!void {
    var done: usize = 0;
    while (done < buf.len) {
        const absolute = std.math.add(u64, offset, done) catch return error.OutOfRange;
        const file_offset = std.math.cast(std.c.off_t, absolute) orelse return error.OutOfRange;
        const n = std.c.pread(fd, buf.ptr + done, buf.len - done, file_offset);
        if (n <= 0) return error.ShortRead;
        done += @intCast(n);
    }
}

fn writeExact(fd: std.c.fd_t, buf: []const u8, offset: u64) Error!void {
    var done: usize = 0;
    while (done < buf.len) {
        const absolute = std.math.add(u64, offset, done) catch return error.OutOfRange;
        const file_offset = std.math.cast(std.c.off_t, absolute) orelse return error.OutOfRange;
        const n = std.c.pwrite(fd, buf.ptr + done, buf.len - done, file_offset);
        if (n <= 0) return error.ShortWrite;
        done += @intCast(n);
    }
}

fn createTempOverlayFd(allocator: std.mem.Allocator) Error!std.c.fd_t {
    const template = try allocator.dupeZ(u8, "/tmp/sporevm-disk-fork-XXXXXX");
    defer allocator.free(template);
    const fd = mkstemp(template.ptr);
    if (fd < 0) return error.IoFailed;
    _ = std.c.unlink(template.ptr);
    return fd;
}

fn tryCloneOverlay(parent_fd: std.c.fd_t, child_fd: std.c.fd_t) bool {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const request = linux.IOCTL.IOW(0x94, 9, c_int);
        return linux.errno(linux.ioctl(child_fd, request, @as(usize, @intCast(parent_fd)))) == .SUCCESS;
    }
    return false;
}

fn objectDir(allocator: std.mem.Allocator, dir: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/cas/rootfs/blake3/objects", .{dir}) catch return error.OutOfMemory;
}

test "partial write preserves untouched bytes from base" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);

    var base_bytes: [8192]u8 = undefined;
    for (&base_bytes, 0..) |*byte, i| byte.* = @truncate(i);
    try base.writeStreamingAll(io, &base_bytes);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try ChunkMappedDisk.initWritable(std.testing.allocator, base_source, overlay.handle, base_bytes.len, 4096);
    defer disk.deinit();

    const patch = [_]u8{0xAA} ** 512;
    try disk.writeAt(&patch, 1024);

    var readback: [4096]u8 = undefined;
    try disk.readAt(&readback, 0);
    try std.testing.expectEqualSlices(u8, base_bytes[0..1024], readback[0..1024]);
    try std.testing.expectEqualSlices(u8, &patch, readback[1024..1536]);
    try std.testing.expectEqualSlices(u8, base_bytes[1536..4096], readback[1536..4096]);
    try std.testing.expectEqual(@as(usize, 1), disk.dirtyChunkCount());
}

test "chunk mapped disk matches byte model across partial writes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);

    var base_bytes: [2048 + 137]u8 = undefined;
    for (&base_bytes, 0..) |*byte, i| byte.* = @truncate((i * 31) + 7);
    var model = base_bytes;
    try base.writeStreamingAll(io, &base_bytes);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try ChunkMappedDisk.initWritable(std.testing.allocator, base_source, overlay.handle, base_bytes.len, 512);
    defer disk.deinit();

    const patch_a = [_]u8{0xAA} ** 13;
    const patch_b = [_]u8{0xBB} ** 700;
    const patch_c = [_]u8{0xCC} ** 37;
    const writes = [_]struct {
        offset: usize,
        data: []const u8,
    }{
        .{ .offset = 3, .data = &patch_a },
        .{ .offset = 500, .data = &patch_b },
        .{ .offset = base_bytes.len - patch_c.len, .data = &patch_c },
    };

    var dirty_model = [_]bool{false} ** 5;
    for (writes) |write| {
        try disk.writeAt(write.data, write.offset);
        @memcpy(model[write.offset..][0..write.data.len], write.data);

        const first = write.offset / 512;
        const last = (write.offset + write.data.len - 1) / 512;
        for (first..last + 1) |i| dirty_model[i] = true;
    }

    for (dirty_model, 0..) |is_dirty, i| {
        try std.testing.expectEqual(is_dirty, try disk.isDirtyChunk(i));
    }

    const read_lengths = [_]usize{ 0, 1, 7, 255, 512, 513, 900 };
    var readback: [900]u8 = undefined;
    var offset: usize = 0;
    while (offset < model.len) : (offset += 127) {
        for (read_lengths) |len| {
            if (offset + len > model.len) continue;
            try disk.readAt(readback[0..len], offset);
            try std.testing.expectEqualSlices(u8, model[offset..][0..len], readback[0..len]);
        }
    }
}

test "zero chunks seed partial overlay writes from zeroes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);

    const base_bytes = [_]u8{0x11} ** 1024;
    try base.writeStreamingAll(io, &base_bytes);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try ChunkMappedDisk.initWritable(std.testing.allocator, base_source, overlay.handle, base_bytes.len, 512);
    defer disk.deinit();
    try disk.markZeroChunk(1);

    const patch = [_]u8{0x7B} ** 4;
    try disk.writeAt(&patch, 512 + 10);

    var readback: [512]u8 = undefined;
    try disk.readAt(&readback, 512);
    try std.testing.expect(std.mem.allEqual(u8, readback[0..10], 0));
    try std.testing.expectEqualSlices(u8, &patch, readback[10..14]);
    try std.testing.expect(std.mem.allEqual(u8, readback[14..], 0));
}

test "snapshot writes disk index and chunk objects" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const spore_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/spore", .{tmp.sub_path[0..]});
    defer allocator.free(spore_dir);
    try std.Io.Dir.cwd().createDirPath(io, spore_dir);

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);

    const base_bytes = [_]u8{0} ** 1024;
    try base.writeStreamingAll(io, &base_bytes);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try ChunkMappedDisk.initWritable(allocator, base_source, overlay.handle, base_bytes.len, 512);
    defer disk.deinit();

    const patch = [_]u8{0x5A} ** 16;
    try disk.writeAt(&patch, 600);

    const manifest_disk = try disk.snapshotIndex(spore_dir, .{ .mmio_slot = 1 });
    defer {
        allocator.free(manifest_disk.kind);
        allocator.free(manifest_disk.device.kind);
        allocator.free(manifest_disk.device.role);
        allocator.free(manifest_disk.base);
        allocator.free(manifest_disk.hash_algorithm);
        allocator.free(manifest_disk.object_namespace);
    }

    try std.testing.expectEqualStrings(spore.disk_kind_chunk_index, manifest_disk.kind);
    try std.testing.expectEqual(@as(u64, 512), manifest_disk.chunk_size);
    try std.testing.expectEqual(@as(usize, 0), manifest_disk.layers.len);

    const index_path = try rootfs_cas.manifestIndexPath(allocator, spore_dir, manifest_disk.base);
    defer allocator.free(index_path);
    const index_bytes = try std.Io.Dir.cwd().readFileAlloc(io, index_path, allocator, .limited(disk_index.max_index_bytes));
    defer allocator.free(index_bytes);
    const storage = spore.RootfsStorage{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = manifest_disk.device,
        .logical_size = manifest_disk.size,
        .chunk_size = manifest_disk.chunk_size,
        .hash_algorithm = manifest_disk.hash_algorithm,
        .index_digest = manifest_disk.base,
        .base_identity = manifest_disk.base,
        .object_namespace = manifest_disk.object_namespace,
    };
    const parsed = try disk_index.parseDiskIndex(allocator, index_bytes, try spore.diskIndexDescriptorForStorage(storage));
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.chunks.len);
    try std.testing.expectEqual(@as(u64, 1), parsed.value.chunks[0].logical_chunk);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.zero_chunks.len);
    try std.testing.expectEqual(@as(u64, 0), parsed.value.zero_chunks[0]);

    const object_path = try rootfs_cas.manifestObjectPath(allocator, spore_dir, parsed.value.chunks[0].digest);
    defer allocator.free(object_path);
    try std.Io.Dir.cwd().access(io, object_path, .{ .read = true });
}

test "read only disk rejects writes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);

    const base_bytes = [_]u8{0x11} ** 512;
    try base.writeStreamingAll(io, &base_bytes);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try ChunkMappedDisk.initReadOnly(std.testing.allocator, base_source, base_bytes.len, 512);
    defer disk.deinit();

    const patch = [_]u8{0x22} ** 4;
    try std.testing.expectError(error.ReadOnly, disk.writeAt(&patch, 0));

    var readback: [512]u8 = undefined;
    try disk.readAt(&readback, 0);
    try std.testing.expectEqualSlices(u8, &base_bytes, &readback);
}

test "read only disk rejects fork" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);

    const base_bytes = [_]u8{0x11} ** 512;
    try base.writeStreamingAll(io, &base_bytes);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try ChunkMappedDisk.initReadOnly(std.testing.allocator, base_source, base_bytes.len, 512);
    defer disk.deinit();

    try std.testing.expectError(error.ReadOnly, disk.fork(.{}));
}

test "forced-copy fork isolates parent and child overlays" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);

    var base_bytes: [1536]u8 = undefined;
    for (&base_bytes, 0..) |*byte, i| byte.* = @truncate((i * 17) + 3);
    var parent_model = base_bytes;
    var child_model = base_bytes;
    try base.writeStreamingAll(io, &base_bytes);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try ChunkMappedDisk.initWritable(std.testing.allocator, base_source, overlay.handle, base_bytes.len, 512);
    defer disk.deinit();

    const first_parent_patch = [_]u8{0xA1} ** 48;
    try disk.writeAt(&first_parent_patch, 480);
    @memcpy(parent_model[480..][0..first_parent_patch.len], &first_parent_patch);
    @memcpy(child_model[480..][0..first_parent_patch.len], &first_parent_patch);

    var child = try disk.fork(.{ .force_copy = true });
    defer child.deinit();

    try std.testing.expectEqual(ForkCloneMethod.copy, child.clone_method);
    try std.testing.expectEqual(disk.chunkCount(), child.disk.chunkCount());
    try std.testing.expectEqual(disk.dirtyChunkCount(), child.disk.dirtyChunkCount());

    var readback: [1536]u8 = undefined;
    try child.disk.readAt(&readback, 0);
    try std.testing.expectEqualSlices(u8, &child_model, &readback);

    const second_parent_patch = [_]u8{0xB2} ** 32;
    try disk.writeAt(&second_parent_patch, 32);
    @memcpy(parent_model[32..][0..second_parent_patch.len], &second_parent_patch);

    try child.disk.readAt(&readback, 0);
    try std.testing.expectEqualSlices(u8, &child_model, &readback);

    const child_patch = [_]u8{0xC3} ** 40;
    try child.disk.writeAt(&child_patch, 512 + 24);
    @memcpy(child_model[512 + 24 ..][0..child_patch.len], &child_patch);

    try disk.readAt(&readback, 0);
    try std.testing.expectEqualSlices(u8, &parent_model, &readback);
    try child.disk.readAt(&readback, 0);
    try std.testing.expectEqualSlices(u8, &child_model, &readback);
}

test "sequential forks keep a flat chunk map" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);

    var base_bytes: [2048]u8 = undefined;
    for (&base_bytes, 0..) |*byte, i| byte.* = @truncate((i * 29) + 11);
    var parent_model = base_bytes;
    var final_model = base_bytes;
    try base.writeStreamingAll(io, &base_bytes);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try ChunkMappedDisk.initWritable(std.testing.allocator, base_source, overlay.handle, base_bytes.len, 512);
    defer disk.deinit();

    const parent_patch = [_]u8{0xD4} ** 64;
    try disk.writeAt(&parent_patch, 700);
    @memcpy(parent_model[700..][0..parent_patch.len], &parent_patch);
    @memcpy(final_model[700..][0..parent_patch.len], &parent_patch);

    var forks: [32]ForkedDisk = undefined;
    var initialized: usize = 0;
    defer {
        var i = initialized;
        while (i > 0) {
            i -= 1;
            forks[i].deinit();
        }
    }

    var current: *ChunkMappedDisk = &disk;
    while (initialized < forks.len) {
        forks[initialized] = try current.fork(.{ .force_copy = true });
        initialized += 1;
        const forked = &forks[initialized - 1];
        try std.testing.expectEqual(ForkCloneMethod.copy, forked.clone_method);
        try std.testing.expectEqual(disk.chunkCount(), forked.disk.chunkCount());
        try std.testing.expectEqual(@as(usize, 1), forked.disk.dirtyChunkCount());
        current = &forked.disk;
    }

    var readback: [2048]u8 = undefined;
    try current.readAt(&readback, 0);
    try std.testing.expectEqualSlices(u8, &final_model, &readback);

    const final_patch = [_]u8{0xE5} ** 96;
    try current.writeAt(&final_patch, 1200);
    @memcpy(final_model[1200..][0..final_patch.len], &final_patch);

    try current.readAt(&readback, 0);
    try std.testing.expectEqualSlices(u8, &final_model, &readback);
    try disk.readAt(&readback, 0);
    try std.testing.expectEqualSlices(u8, &parent_model, &readback);
}
