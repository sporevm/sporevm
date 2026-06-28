//! Read-only block sources for immutable disk bases.
//!
//! A BlockSource is an I/O abstraction, not a trust boundary. Callers are
//! responsible for constructing it only from bytes that have already satisfied
//! the relevant restore authority.

const std = @import("std");
const fd_util = @import("fd.zig");
const rootfs_cas = @import("rootfs_cas.zig");

pub const Error = rootfs_cas.SourceError || error{
    OutOfRange,
    ShortRead,
};

pub const BlockSource = union(enum) {
    file: FileBlockSource,
    cas: *rootfs_cas.CasBlockSource,

    pub fn capacityBytes(self: BlockSource) u64 {
        return switch (self) {
            .file => |source| source.capacityBytes(),
            .cas => |source| source.capacityBytes(),
        };
    }

    pub fn readAt(self: BlockSource, buf: []u8, offset: u64) Error!void {
        return switch (self) {
            .file => |source| source.readAt(buf, offset),
            .cas => |source| source.readAt(buf, offset),
        };
    }
};

pub const FileBlockSource = struct {
    /// Non-owning fd. The runtime that constructs the source owns verification
    /// and fd lifetime.
    fd: std.c.fd_t,
    size: u64,
    trace_path: ?[:0]const u8 = null,

    pub fn init(fd: std.c.fd_t, size: u64) FileBlockSource {
        return .{
            .fd = fd,
            .size = size,
        };
    }

    pub fn initWithTrace(fd: std.c.fd_t, size: u64, trace_path: ?[:0]const u8) FileBlockSource {
        return .{
            .fd = fd,
            .size = size,
            .trace_path = trace_path,
        };
    }

    pub fn source(self: FileBlockSource) BlockSource {
        return .{ .file = self };
    }

    pub fn capacityBytes(self: FileBlockSource) u64 {
        return self.size;
    }

    pub fn readAt(self: FileBlockSource, buf: []u8, offset: u64) Error!void {
        const end = std.math.add(u64, offset, buf.len) catch return error.OutOfRange;
        if (end > self.size) return error.OutOfRange;

        const start_ms = monotonicMs();
        var done: usize = 0;
        while (done < buf.len) {
            const absolute = std.math.add(u64, offset, done) catch return error.OutOfRange;
            const file_offset = std.math.cast(std.c.off_t, absolute) orelse return error.OutOfRange;
            const n = std.c.pread(self.fd, buf.ptr + done, buf.len - done, file_offset);
            if (n <= 0) return error.ShortRead;
            done += @intCast(n);
        }
        if (self.trace_path) |trace_path| {
            appendTraceRead(trace_path, offset, buf.len, monotonicMs() -| start_ms);
        }
    }
};

fn appendTraceRead(path: [:0]const u8, offset: u64, len: usize, elapsed_ms: u64) void {
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c_uint, 0o644));
    if (fd < 0) return;
    defer _ = std.c.close(fd);

    var line_buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(
        &line_buf,
        "{{\"event\":\"block_source_read\",\"source\":\"file\",\"offset\":{d},\"len\":{d},\"elapsed_ms\":{d}}}\n",
        .{ offset, len, elapsed_ms },
    ) catch return;
    fd_util.writeAllBestEffort(fd, line);
}

fn monotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

test "file source reports capacity and reads ranges" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer file.close(io);

    const bytes = [_]u8{ 0x10, 0x11, 0x12, 0x13, 0x14 };
    try file.writeStreamingAll(io, &bytes);

    const source = FileBlockSource.init(file.handle, bytes.len).source();
    try std.testing.expectEqual(@as(u64, bytes.len), source.capacityBytes());

    var readback: [3]u8 = undefined;
    try source.readAt(&readback, 1);
    try std.testing.expectEqualSlices(u8, bytes[1..4], &readback);
}

test "file source range checks against logical size" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer file.close(io);
    try file.writeStreamingAll(io, &([_]u8{0x44} ** 4096));

    const source = FileBlockSource.init(file.handle, 1024).source();
    var buf: [1]u8 = undefined;
    try std.testing.expectError(error.OutOfRange, source.readAt(&buf, 1024));
}
