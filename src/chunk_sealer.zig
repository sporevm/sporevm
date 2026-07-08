//! Shared content-addressed chunk sealing.
//!
//! Callers own dirty tracking and manifest shape. This module owns the common
//! operation: classify a chunk as zero or BLAKE3-addressed data, write data
//! chunks only if absent, and verify preexisting objects before reusing them.

const std = @import("std");
const builtin = @import("builtin");
const chunk = @import("chunk.zig");

pub const Error = error{
    AlreadyExists,
    BadChunk,
    ClockFailed,
    IoFailed,
    OutOfMemory,
};

pub const WorkStats = struct {
    sealed_chunks: u64 = 0,
    zero_scan_ns: u64 = 0,
    hash_ns: u64 = 0,
    chunk_write_ns: u64 = 0,
    backing_write_ns: u64 = 0,
    cpu_ns: u64 = 0,

    pub fn add(self: *WorkStats, other: WorkStats) void {
        self.sealed_chunks +|= other.sealed_chunks;
        self.zero_scan_ns +|= other.zero_scan_ns;
        self.hash_ns +|= other.hash_ns;
        self.chunk_write_ns +|= other.chunk_write_ns;
        self.backing_write_ns +|= other.backing_write_ns;
        self.cpu_ns +|= other.cpu_ns;
    }
};

pub const SealResult = union(enum) {
    zero,
    data: chunk.ChunkId,
};

pub fn sealBytes(data: []const u8, work_stats: *WorkStats) Error!SealResult {
    const zero_scan_start = try monotonicNs();
    const is_zero = std.mem.allEqual(u8, data, 0);
    work_stats.zero_scan_ns +|= try elapsedMonotonicNs(zero_scan_start);
    if (is_zero) return .zero;

    const hash_start = try monotonicNs();
    const id = chunk.ChunkId.fromContents(data);
    work_stats.hash_ns +|= try elapsedMonotonicNs(hash_start);
    return .{ .data = id };
}

pub fn writeFileAllIfMissingTimed(path: [:0]const u8, data: []const u8, work_stats: *WorkStats) Error!void {
    const start = try monotonicNs();
    try writeFileAllIfMissing(path, data);
    work_stats.chunk_write_ns +|= try elapsedMonotonicNs(start);
}

pub fn writePathAllIfMissingTimed(
    allocator: std.mem.Allocator,
    path: []const u8,
    data: []const u8,
    work_stats: *WorkStats,
) Error!void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    try writeFileAllIfMissingTimed(path_z, data, work_stats);
}

pub fn pwriteFileAllTimed(fd: std.c.fd_t, offset: usize, data: []const u8, work_stats: *WorkStats) Error!void {
    const start = try monotonicNs();
    try pwriteFileAll(fd, offset, data);
    work_stats.backing_write_ns +|= try elapsedMonotonicNs(start);
}

pub fn writeFileAllIfMissing(path: [:0]const u8, data: []const u8) Error!void {
    const fd = createNewFile(path, 0o644) catch |err| switch (err) {
        error.AlreadyExists => {
            try verifyExistingFile(path, data);
            return;
        },
        else => |e| return e,
    };
    defer _ = std.c.close(fd);
    try writeAll(fd, data);
}

pub fn createNewFile(path: [:0]const u8, mode: c_uint) Error!std.c.fd_t {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, mode);
    if (fd < 0) {
        return switch (std.c.errno(fd)) {
            .EXIST => error.AlreadyExists,
            else => error.IoFailed,
        };
    }
    return fd;
}

pub fn ensureDirPath(allocator: std.mem.Allocator, path: []const u8) Error!void {
    if (path.len == 0) return error.IoFailed;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    for (path_z[0..path_z.len], 0..) |byte, i| {
        if (byte != std.fs.path.sep) continue;
        if (i == 0) continue;
        path_z[i] = 0;
        try mkdirIfMissing(path_z.ptr);
        path_z[i] = std.fs.path.sep;
    }
    try mkdirIfMissing(path_z.ptr);
}

pub fn pwriteFileAll(fd: std.c.fd_t, offset: usize, data: []const u8) Error!void {
    var done: usize = 0;
    while (done < data.len) {
        const n = std.c.pwrite(fd, data.ptr + done, data.len - done, @intCast(offset + done));
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
}

fn writeAll(fd: std.c.fd_t, data: []const u8) Error!void {
    var done: usize = 0;
    while (done < data.len) {
        const n = std.c.write(fd, data.ptr + done, data.len - done);
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
}

fn verifyExistingFile(path: [:0]const u8, expected: []const u8) Error!void {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.BadChunk;
    defer _ = std.c.close(fd);

    const size = try fstatRegularSize(fd);
    if (size != expected.len) return error.BadChunk;

    var buf: [8192]u8 = undefined;
    var done: usize = 0;
    while (done < expected.len) {
        const len = @min(buf.len, expected.len - done);
        const offset = std.math.cast(std.c.off_t, done) orelse return error.BadChunk;
        const n = std.c.pread(fd, buf[0..len].ptr, len, offset);
        if (n <= 0) return error.BadChunk;
        const read_len: usize = @intCast(n);
        if (!std.mem.eql(u8, buf[0..read_len], expected[done..][0..read_len])) return error.BadChunk;
        done += read_len;
    }
}

fn fstatRegularSize(fd: std.c.fd_t) Error!usize {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var statx_buf: linux.Statx = undefined;
        const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{
            .TYPE = true,
            .MODE = true,
            .SIZE = true,
        }, &statx_buf);
        if (linux.errno(rc) != .SUCCESS) return error.IoFailed;
        if (!linux.S.ISREG(statx_buf.mode)) return error.BadChunk;
        return std.math.cast(usize, statx_buf.size) orelse error.BadChunk;
    } else {
        var stat: std.c.Stat = undefined;
        if (std.c.fstat(fd, &stat) != 0) return error.IoFailed;
        if (!std.c.S.ISREG(stat.mode)) return error.BadChunk;
        if (stat.size < 0) return error.IoFailed;
        return std.math.cast(usize, stat.size) orelse error.BadChunk;
    }
}

fn mkdirIfMissing(path: [*:0]const u8) Error!void {
    if (std.c.mkdir(path, 0o755) == 0) return;
    switch (std.c.errno(-1)) {
        .EXIST => return,
        else => return error.IoFailed,
    }
}

fn monotonicNs() Error!u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return error.ClockFailed;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn elapsedMonotonicNs(start_ns: u64) Error!u64 {
    const end_ns = try monotonicNs();
    if (end_ns <= start_ns) return 0;
    return end_ns - start_ns;
}

test "seals zero and data chunks" {
    var stats: WorkStats = .{};
    var zero = [_]u8{0} ** 64;
    try std.testing.expectEqual(SealResult.zero, try sealBytes(&zero, &stats));

    zero[0] = 1;
    const sealed = try sealBytes(&zero, &stats);
    switch (sealed) {
        .zero => return error.TestUnexpectedResult,
        .data => |id| try std.testing.expect(id.matches(&zero)),
    }
}

test "write-if-missing verifies existing data" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/chunk", .{tmp.sub_path[0..]});
    defer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    try writeFileAllIfMissing(path_z, "abc");
    try writeFileAllIfMissing(path_z, "abc");
    try std.testing.expectError(error.BadChunk, writeFileAllIfMissing(path_z, "def"));
}
