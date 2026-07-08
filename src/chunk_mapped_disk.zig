//! One-level chunk-mapped disk backend for writable runtime disks.
//!
//! Reads are resolved through an in-memory per-chunk source map. Writes land in
//! a sparse overlay fd and flip the affected chunks to the overlay source. The
//! flat base remains the hot read source in U2; later slices add CAS fault-in
//! sources and durable index snapshotting on top of the same map.

const std = @import("std");
const block_source = @import("block_source.zig");

pub const Error = error{
    BadClusterSize,
    BadDiskSize,
    OutOfRange,
    ReadOnly,
    ShortRead,
    ShortWrite,
    ResizeFailed,
    FlushFailed,
} || block_source.Error || std.mem.Allocator.Error;

const Source = enum(u8) {
    base,
    overlay,
    zero,
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
