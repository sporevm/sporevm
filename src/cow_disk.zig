//! Host-side COW disk backing for writable block devices.
//!
//! This is the local active-head primitive for writable rootfs work. It reads
//! from an immutable base fd until a cluster is dirtied, then serves that whole
//! cluster from a sparse overlay fd. The overlay is not a portable artifact
//! until later sealing code records verified disk-layer objects.

const std = @import("std");

pub const Error = error{
    BadClusterSize,
    BadDiskSize,
    OutOfRange,
    ShortRead,
    ShortWrite,
    ResizeFailed,
    FlushFailed,
} || std.mem.Allocator.Error;

pub const CowDisk = struct {
    allocator: std.mem.Allocator,
    base_fd: std.c.fd_t,
    overlay_fd: std.c.fd_t,
    size: u64,
    cluster_size: u64,
    dirty: []bool,

    pub fn init(
        allocator: std.mem.Allocator,
        base_fd: std.c.fd_t,
        overlay_fd: std.c.fd_t,
        size: u64,
        cluster_size: u64,
    ) Error!CowDisk {
        if (size == 0) return error.BadDiskSize;
        if (cluster_size == 0 or cluster_size % 512 != 0 or cluster_size > std.math.maxInt(usize)) {
            return error.BadClusterSize;
        }
        const cluster_count = try computeClusterCount(size, cluster_size);
        if (cluster_count > std.math.maxInt(usize)) return error.BadDiskSize;
        const overlay_size = std.math.cast(std.c.off_t, size) orelse return error.BadDiskSize;
        if (std.c.ftruncate(overlay_fd, overlay_size) != 0) return error.ResizeFailed;
        const dirty = try allocator.alloc(bool, @intCast(cluster_count));
        @memset(dirty, false);
        return .{
            .allocator = allocator,
            .base_fd = base_fd,
            .overlay_fd = overlay_fd,
            .size = size,
            .cluster_size = cluster_size,
            .dirty = dirty,
        };
    }

    pub fn deinit(self: *CowDisk) void {
        self.allocator.free(self.dirty);
        self.* = undefined;
    }

    pub fn capacityBytes(self: CowDisk) u64 {
        return self.size;
    }

    pub fn dirtyClusterCount(self: CowDisk) usize {
        var count: usize = 0;
        for (self.dirty) |is_dirty| {
            if (is_dirty) count += 1;
        }
        return count;
    }

    pub fn clusterSize(self: CowDisk) u64 {
        return self.cluster_size;
    }

    pub fn clusterCount(self: CowDisk) usize {
        return self.dirty.len;
    }

    pub fn clusterLen(self: CowDisk, cluster_index: usize) Error!usize {
        if (cluster_index >= self.dirty.len) return error.OutOfRange;
        const start = std.math.mul(u64, cluster_index, self.cluster_size) catch return error.OutOfRange;
        const end = @min(std.math.add(u64, start, self.cluster_size) catch self.size, self.size);
        return std.math.cast(usize, end - start) orelse return error.BadClusterSize;
    }

    pub fn isDirtyCluster(self: CowDisk, cluster_index: usize) Error!bool {
        if (cluster_index >= self.dirty.len) return error.OutOfRange;
        return self.dirty[cluster_index];
    }

    pub fn readCluster(self: *CowDisk, cluster_index: usize, buf: []u8) Error!void {
        const len = try self.clusterLen(cluster_index);
        if (buf.len != len) return error.OutOfRange;
        const offset = std.math.mul(u64, cluster_index, self.cluster_size) catch return error.OutOfRange;
        try self.readAt(buf, offset);
    }

    pub fn readAt(self: *CowDisk, buf: []u8, offset: u64) Error!void {
        try self.checkRange(buf.len, offset);
        var cursor: usize = 0;
        while (cursor < buf.len) {
            const absolute = offset + cursor;
            const span = try self.spanFor(absolute, buf.len - cursor);
            const fd = if (self.dirty[span.cluster_index]) self.overlay_fd else self.base_fd;
            try readExact(fd, buf[cursor..][0..span.len], absolute);
            cursor += span.len;
        }
    }

    pub fn writeAt(self: *CowDisk, buf: []const u8, offset: u64) Error!void {
        try self.checkRange(buf.len, offset);
        var cursor: usize = 0;
        while (cursor < buf.len) {
            const absolute = offset + cursor;
            const span = try self.spanFor(absolute, buf.len - cursor);
            if (!self.dirty[span.cluster_index]) {
                try self.seedCluster(span.cluster_index);
            }
            try writeExact(self.overlay_fd, buf[cursor..][0..span.len], absolute);
            self.dirty[span.cluster_index] = true;
            cursor += span.len;
        }
    }

    pub fn flush(self: *CowDisk) Error!void {
        if (std.c.fsync(self.overlay_fd) != 0) return error.FlushFailed;
    }

    fn checkRange(self: CowDisk, len: usize, offset: u64) Error!void {
        const end = std.math.add(u64, offset, len) catch return error.OutOfRange;
        if (end > self.size) return error.OutOfRange;
    }

    fn spanFor(self: CowDisk, offset: u64, remaining: usize) Error!Span {
        const cluster_index_u64 = offset / self.cluster_size;
        if (cluster_index_u64 > std.math.maxInt(usize)) return error.OutOfRange;
        const cluster_offset = offset % self.cluster_size;
        const left_in_cluster = self.cluster_size - cluster_offset;
        const len = @min(remaining, std.math.cast(usize, left_in_cluster) orelse return error.BadClusterSize);
        return .{
            .cluster_index = @intCast(cluster_index_u64),
            .len = len,
        };
    }

    fn seedCluster(self: *CowDisk, cluster_index: usize) Error!void {
        const start = std.math.mul(u64, cluster_index, self.cluster_size) catch return error.OutOfRange;
        const end = @min(std.math.add(u64, start, self.cluster_size) catch self.size, self.size);
        const len = std.math.cast(usize, end - start) orelse return error.BadClusterSize;
        const buf = try self.allocator.alloc(u8, len);
        defer self.allocator.free(buf);
        try readExact(self.base_fd, buf, start);
        try writeExact(self.overlay_fd, buf, start);
    }
};

const Span = struct {
    cluster_index: usize,
    len: usize,
};

fn computeClusterCount(size: u64, cluster_size: u64) Error!u64 {
    const rounded = std.math.add(u64, size, cluster_size - 1) catch return error.BadDiskSize;
    return rounded / cluster_size;
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

    var disk = try CowDisk.init(std.testing.allocator, base.handle, overlay.handle, base_bytes.len, 4096);
    defer disk.deinit();

    const patch = [_]u8{0xAA} ** 512;
    try disk.writeAt(&patch, 1024);

    var readback: [4096]u8 = undefined;
    try disk.readAt(&readback, 0);
    try std.testing.expectEqualSlices(u8, base_bytes[0..1024], readback[0..1024]);
    try std.testing.expectEqualSlices(u8, &patch, readback[1024..1536]);
    try std.testing.expectEqualSlices(u8, base_bytes[1536..4096], readback[1536..4096]);
    try std.testing.expectEqual(@as(usize, 1), disk.dirtyClusterCount());
}

test "writes spanning clusters seed and read from overlay" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);

    var base_bytes: [12288]u8 = undefined;
    @memset(&base_bytes, 0x11);
    try base.writeStreamingAll(io, &base_bytes);

    var disk = try CowDisk.init(std.testing.allocator, base.handle, overlay.handle, base_bytes.len, 4096);
    defer disk.deinit();

    const patch = [_]u8{0x44} ** 4096;
    try disk.writeAt(&patch, 3072);

    var readback: [8192]u8 = undefined;
    try disk.readAt(&readback, 2048);
    try std.testing.expectEqualSlices(u8, base_bytes[2048..3072], readback[0..1024]);
    try std.testing.expectEqualSlices(u8, &patch, readback[1024..5120]);
    try std.testing.expectEqualSlices(u8, base_bytes[7168..10240], readback[5120..8192]);
    try std.testing.expectEqual(@as(usize, 2), disk.dirtyClusterCount());
}

test "range and cluster validation fail closed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);
    try base.writeStreamingAll(io, &([_]u8{0} ** 4096));

    try std.testing.expectError(error.BadClusterSize, CowDisk.init(std.testing.allocator, base.handle, overlay.handle, 4096, 1000));
    const oversized = @as(u64, @intCast(std.math.maxInt(std.c.off_t))) + 1;
    try std.testing.expectError(error.BadDiskSize, CowDisk.init(std.testing.allocator, base.handle, overlay.handle, oversized, 4096));

    var disk = try CowDisk.init(std.testing.allocator, base.handle, overlay.handle, 4096, 4096);
    defer disk.deinit();

    var byte: [1]u8 = .{0};
    try std.testing.expectError(error.OutOfRange, disk.readAt(&byte, 4096));
    try std.testing.expectError(error.OutOfRange, disk.writeAt(&byte, 4096));
}

test "failed clean-cluster write does not mark dirty" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    try base.writeStreamingAll(io, &([_]u8{0x11} ** 4096));

    var disk = try CowDisk.init(std.testing.allocator, base.handle, overlay.handle, 4096, 4096);
    defer disk.deinit();
    overlay.close(io);

    var patch = [_]u8{0x22} ** 512;
    try std.testing.expectError(error.ShortWrite, disk.writeAt(&patch, 0));
    try std.testing.expectEqual(@as(usize, 0), disk.dirtyClusterCount());
}
