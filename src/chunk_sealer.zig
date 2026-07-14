//! Shared content-addressed chunk sealing.
//!
//! Callers own dirty tracking and manifest shape. This module owns the common
//! operation: classify a chunk as zero or BLAKE3-addressed data, write data
//! chunks only if absent, and verify preexisting objects before reusing them.

const std = @import("std");
const builtin = @import("builtin");
const chunk = @import("chunk.zig");

const testing = if (builtin.is_test) struct {
    var created_dir_syncs: ?*usize = null;
} else struct {};

pub const Error = error{
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

pub const WriteIfMissingResult = enum {
    published,
    reused_existing,
};

pub const PublishTrustedFileResult = enum {
    linked,
    reused_existing,
    copy_required,
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

pub fn writeFileAllIfMissingTimed(
    allocator: std.mem.Allocator,
    path: [:0]const u8,
    data: []const u8,
    work_stats: *WorkStats,
) Error!void {
    _ = try writeFileAllIfMissingTimedResult(allocator, path, data, work_stats);
}

pub fn writeFileAllIfMissingTimedResult(
    allocator: std.mem.Allocator,
    path: [:0]const u8,
    data: []const u8,
    work_stats: *WorkStats,
) Error!WriteIfMissingResult {
    const start = try monotonicNs();
    const result = try writeFileAllIfMissingResult(allocator, path, data);
    work_stats.chunk_write_ns +|= try elapsedMonotonicNs(start);
    return result;
}

pub fn writePathAllIfMissingTimed(
    allocator: std.mem.Allocator,
    path: []const u8,
    data: []const u8,
    work_stats: *WorkStats,
) Error!void {
    _ = try writePathAllIfMissingTimedResult(allocator, path, data, work_stats);
}

pub fn writePathAllIfMissingTimedResult(
    allocator: std.mem.Allocator,
    path: []const u8,
    data: []const u8,
    work_stats: *WorkStats,
) Error!WriteIfMissingResult {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    return try writeFileAllIfMissingTimedResult(allocator, path_z, data, work_stats);
}

pub fn pwriteFileAllTimed(fd: std.c.fd_t, offset: usize, data: []const u8, work_stats: *WorkStats) Error!void {
    const start = try monotonicNs();
    try pwriteFileAll(fd, offset, data);
    work_stats.backing_write_ns +|= try elapsedMonotonicNs(start);
}

/// Publishes an already-verified, read-only CAS object into another CAS root.
/// The caller must fsync the destination directory after batching successful
/// links and before publishing an index that references them.
pub fn publishTrustedFileIfMissing(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    dest_path: []const u8,
    expected_size: usize,
) Error!PublishTrustedFileResult {
    const source_z = try allocator.dupeZ(u8, source_path);
    defer allocator.free(source_z);
    const dest_z = try allocator.dupeZ(u8, dest_path);
    defer allocator.free(dest_z);

    const source_fd = std.c.open(source_z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (source_fd < 0) return error.BadChunk;
    defer _ = std.c.close(source_fd);
    if (try fstatRegularSize(source_fd) != expected_size) return error.BadChunk;

    if (std.c.link(source_z.ptr, dest_z.ptr) == 0) return .linked;
    if (std.c.errno(-1) != .EXIST) return .copy_required;

    const dest_fd = std.c.open(dest_z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (dest_fd < 0) return error.BadChunk;
    defer _ = std.c.close(dest_fd);
    if (try fstatRegularSize(dest_fd) != expected_size) return error.BadChunk;
    return .reused_existing;
}

/// Durable CAS object write: returns only after the object bytes and containing
/// directory entry have been fsynced, so a later index can safely reference it.
pub fn writeFileAllIfMissing(allocator: std.mem.Allocator, path: [:0]const u8, data: []const u8) Error!void {
    _ = try writeFileAllIfMissingResult(allocator, path, data);
}

/// Durable CAS object write with publication status. The final object path is
/// created by hard-linking a fully written and fsynced temp inode, so concurrent
/// writers never expose partially written object bytes at the digest path.
pub fn writeFileAllIfMissingResult(
    allocator: std.mem.Allocator,
    path: [:0]const u8,
    data: []const u8,
) Error!WriteIfMissingResult {
    const existing_fd = std.c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (existing_fd >= 0) {
        _ = std.c.close(existing_fd);
        try verifyExistingFile(path, data);
        try fsyncParentDirPath(allocator, path[0..path.len]);
        return .reused_existing;
    }
    switch (std.c.errno(existing_fd)) {
        .NOENT => {},
        else => return error.IoFailed,
    }

    const parent = std.fs.path.dirname(path[0..path.len]) orelse ".";
    try ensureDirPath(allocator, parent);

    var attempt: u8 = 0;
    while (attempt < 16) : (attempt += 1) {
        const nonce = (try monotonicNs()) ^ @as(u64, @intCast(std.c.getpid())) ^ @as(u64, @intFromPtr(data.ptr)) ^ attempt;
        const temp_path = try std.fmt.allocPrintSentinel(allocator, "{s}.{x}.tmp", .{ path[0..path.len], nonce }, 0);
        defer allocator.free(temp_path);

        const fd = std.c.open(temp_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0o644));
        if (fd < 0) {
            switch (std.c.errno(fd)) {
                .EXIST => continue,
                else => return error.IoFailed,
            }
        }
        defer _ = std.c.close(fd);
        defer _ = std.c.unlink(temp_path.ptr);

        try writeAll(fd, data);
        try fsyncFd(fd);

        const link_rc = std.c.link(temp_path.ptr, path.ptr);
        if (link_rc == 0) {
            try fsyncParentDirPath(allocator, path[0..path.len]);
            return .published;
        }
        switch (std.c.errno(link_rc)) {
            .EXIST => {
                try verifyExistingFile(path, data);
                try fsyncParentDirPath(allocator, path[0..path.len]);
                return .reused_existing;
            },
            else => return error.IoFailed,
        }
    }
    return error.IoFailed;
}

/// Durable index publication: write a temp file, fsync it, rename into place,
/// then fsync the containing directory. Existing matching files are verified
/// and fsynced so old cache entries are upgraded to the same durability bar.
pub fn writeFileAtomicDurable(
    allocator: std.mem.Allocator,
    path: []const u8,
    data: []const u8,
    mode: c_uint,
) Error!void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const existing_fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (existing_fd >= 0) {
        _ = std.c.close(existing_fd);
        try verifyExistingFile(path_z, data);
        try fsyncParentDirPath(allocator, path);
        return;
    }
    switch (std.c.errno(existing_fd)) {
        .NOENT => {},
        else => return error.IoFailed,
    }

    try replaceFileAtomicDurable(allocator, path, data, mode);
}

/// Durable mutable-record publication: write a temp file, fsync it, rename it
/// over any prior regular file, then fsync the containing directory. Use this
/// only for derived cache mappings whose value may legitimately change; CAS
/// objects and indexes must keep using `writeFileAtomicDurable`.
pub fn replaceFileAtomicDurable(
    allocator: std.mem.Allocator,
    path: []const u8,
    data: []const u8,
    mode: c_uint,
) Error!void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const parent = std.fs.path.dirname(path) orelse ".";
    try ensureDirPath(allocator, parent);

    const nonce = (try monotonicNs()) ^ @as(u64, @intCast(std.c.getpid()));
    const temp_path = try std.fmt.allocPrintSentinel(allocator, "{s}.{x}.tmp", .{ path, nonce }, 0);
    defer allocator.free(temp_path);
    defer _ = std.c.unlink(temp_path.ptr);

    const fd = std.c.open(temp_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, mode);
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);

    try writeAll(fd, data);
    if (std.c.fchmod(fd, @intCast(mode)) != 0) return error.IoFailed;
    try fsyncFd(fd);
    if (std.c.rename(temp_path.ptr, path_z.ptr) != 0) return error.IoFailed;
    try fsyncParentDirPath(allocator, path);
}

pub fn ensureDirPath(allocator: std.mem.Allocator, path: []const u8) Error!void {
    if (path.len == 0) return error.IoFailed;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    for (path_z[0..path_z.len], 0..) |byte, i| {
        if (byte != std.fs.path.sep) continue;
        if (i == 0) continue;
        path_z[i] = 0;
        if (try mkdirIfMissing(path_z.ptr)) {
            try fsyncParentDirPath(allocator, path_z[0..i]);
            if (comptime builtin.is_test) {
                if (testing.created_dir_syncs) |count| count.* += 1;
            }
        }
        path_z[i] = std.fs.path.sep;
    }
    if (try mkdirIfMissing(path_z.ptr)) {
        try fsyncParentDirPath(allocator, path_z[0..path_z.len]);
        if (comptime builtin.is_test) {
            if (testing.created_dir_syncs) |count| count.* += 1;
        }
    }
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

fn fsyncFd(fd: std.c.fd_t) Error!void {
    if (std.c.fsync(fd) != 0) return error.IoFailed;
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
    try fsyncFd(fd);
}

pub fn fsyncParentDirPath(allocator: std.mem.Allocator, path: []const u8) Error!void {
    const parent = std.fs.path.dirname(path) orelse ".";
    try fsyncDirPath(allocator, parent);
}

pub fn fsyncDirPath(allocator: std.mem.Allocator, path: []const u8) Error!void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);
    try fsyncFd(fd);
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

fn mkdirIfMissing(path: [*:0]const u8) Error!bool {
    if (std.c.mkdir(path, 0o755) == 0) return true;
    switch (std.c.errno(-1)) {
        .EXIST => return false,
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

pub fn parallelWorkerCount(item_count: usize) usize {
    if (item_count == 0) return 0;
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return @min(@min(cpu_count, 8), item_count);
}

pub fn ParallelWork(
    comptime Context: type,
    comptime workFn: fn (*Context, usize, *WorkStats) anyerror!void,
) type {
    return struct {
        const Self = @This();

        context: *Context,
        item_count: usize,
        record_cpu: bool,
        next_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        worker_stats: []WorkStats,
        worker_errors: []?anyerror,

        pub fn run(
            allocator: std.mem.Allocator,
            context: *Context,
            item_count: usize,
            requested_workers: usize,
            record_cpu: bool,
        ) !WorkStats {
            const worker_count = @min(requested_workers, item_count);
            if (worker_count == 0) return .{};

            var threads = try allocator.alloc(std.Thread, worker_count);
            defer allocator.free(threads);
            const worker_stats = try allocator.alloc(WorkStats, worker_count);
            defer allocator.free(worker_stats);
            const worker_errors = try allocator.alloc(?anyerror, worker_count);
            defer allocator.free(worker_errors);
            @memset(worker_stats, .{});
            @memset(worker_errors, null);

            var queue = Self{
                .context = context,
                .item_count = item_count,
                .record_cpu = record_cpu,
                .worker_stats = worker_stats,
                .worker_errors = worker_errors,
            };

            var started: usize = 0;
            while (started < worker_count) : (started += 1) {
                threads[started] = std.Thread.spawn(.{}, worker, .{ &queue, started }) catch |err| {
                    queue.failed.store(true, .release);
                    var join_index: usize = 0;
                    while (join_index < started) : (join_index += 1) threads[join_index].join();
                    return err;
                };
            }

            for (threads) |thread| thread.join();
            for (worker_errors) |maybe_err| {
                if (maybe_err) |err| return err;
            }

            var out: WorkStats = .{};
            for (worker_stats) |stats| out.add(stats);
            return out;
        }

        fn worker(queue: *Self, worker_index: usize) void {
            var work_stats: WorkStats = .{};
            const cpu_start = if (queue.record_cpu) threadCpuNs() else 0;
            defer {
                if (queue.record_cpu) work_stats.cpu_ns = elapsedCpuNs(cpu_start);
                queue.worker_stats[worker_index] = work_stats;
            }

            while (!queue.failed.load(.acquire)) {
                const item_index = queue.next_index.fetchAdd(1, .monotonic);
                if (item_index >= queue.item_count) break;
                workFn(queue.context, item_index, &work_stats) catch |err| {
                    queue.worker_errors[worker_index] = err;
                    queue.failed.store(true, .release);
                    break;
                };
            }
        }
    };
}

pub fn nsToMs(ns: u64) u64 {
    return ns / std.time.ns_per_ms;
}

pub fn elapsedCpuMs(start_ns: u64) u64 {
    return nsToMs(elapsedCpuNs(start_ns));
}

pub fn elapsedCpuNs(start_ns: u64) u64 {
    if (start_ns == 0) return 0;
    const end_ns = threadCpuNs();
    if (end_ns <= start_ns) return 0;
    return end_ns - start_ns;
}

pub fn threadCpuNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.THREAD_CPUTIME_ID, &ts) != 0) return 0;
    const seconds: u64 = @intCast(ts.sec);
    const nanos: u64 = @intCast(ts.nsec);
    return seconds * std.time.ns_per_s + nanos;
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

    try writeFileAllIfMissing(allocator, path_z, "abc");
    try writeFileAllIfMissing(allocator, path_z, "abc");
    try std.testing.expectError(error.BadChunk, writeFileAllIfMissing(allocator, path_z, "def"));
}

const ConcurrentWriteContext = struct {
    path: [:0]const u8,
    data: []const u8,
    errors: []?anyerror,
};

fn concurrentWriteWorker(context: *ConcurrentWriteContext, worker_index: usize) void {
    writeFileAllIfMissing(std.heap.page_allocator, context.path, context.data) catch |err| {
        context.errors[worker_index] = err;
    };
}

test "write-if-missing handles same-digest races" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/chunk", .{tmp.sub_path[0..]});
    defer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const worker_count = @max(parallelWorkerCount(8), @as(usize, 2));
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    const errors = try allocator.alloc(?anyerror, worker_count);
    defer allocator.free(errors);
    @memset(errors, null);
    const data = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(data);
    for (data, 0..) |*byte, i| byte.* = @truncate((i * 17) ^ (i >> 5));

    var context = ConcurrentWriteContext{
        .path = path_z,
        .data = data,
        .errors = errors,
    };
    for (threads, 0..) |*thread, i| thread.* = try std.Thread.spawn(.{}, concurrentWriteWorker, .{ &context, i });
    for (threads) |thread| thread.join();
    for (errors) |maybe_err| {
        if (maybe_err) |err| return err;
    }
    try verifyExistingFile(path_z, data);
}

test "durable atomic publish verifies existing data" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/index.json", .{tmp.sub_path[0..]});
    defer allocator.free(path);

    try writeFileAtomicDurable(allocator, path, "abc", 0o444);
    try writeFileAtomicDurable(allocator, path, "abc", 0o444);
    try std.testing.expectError(error.BadChunk, writeFileAtomicDurable(allocator, path, "def", 0o444));
}

test "durable atomic replace updates existing data" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/record.json", .{tmp.sub_path[0..]});
    defer allocator.free(path);

    try replaceFileAtomicDurable(allocator, path, "first", 0o444);
    try replaceFileAtomicDurable(allocator, path, "second", 0o444);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(64));
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("second", bytes);
}

test "ensure directory path durably syncs each newly created ancestor" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/a/b/c", .{tmp.sub_path[0..]});
    defer allocator.free(path);

    var sync_count: usize = 0;
    testing.created_dir_syncs = &sync_count;
    defer testing.created_dir_syncs = null;
    try ensureDirPath(allocator, path);
    try std.testing.expectEqual(@as(usize, 3), sync_count);
}
