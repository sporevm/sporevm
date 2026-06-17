//! Shared dirty RAM sealing for backend dirty trackers.
//!
//! Backends own how dirty memory is detected. This module owns the common
//! result: turning dirty RAM chunks into verified spore chunk refs and a
//! same-host RAM backing file.

const std = @import("std");
const chunk = @import("chunk.zig");
const spore = @import("spore.zig");

pub const Stats = struct {
    seed_ms: u64 = 0,
    seed_chunks: usize = 0,
    seed_nonzero_chunks: usize = 0,
    dirty_chunks_total: u64 = 0,
    dirty_chunks_tail: u64 = 0,
    host_dirty_ranges_total: u64 = 0,
    host_dirty_chunks_total: u64 = 0,
    sealed_chunks_total: u64 = 0,
    seal_ms: u64 = 0,
    seal_cpu_ms: u64 = 0,
    tail_flush_ms: u64 = 0,
    finish_fchmod_ms: u64 = 0,
    finish_close_ms: u64 = 0,
    finish_close_deferred: u64 = 0,
    finish_rename_ms: u64 = 0,
    tracking_ms: u64 = 0,
    dirty_chunks_per_sec: u64 = 0,
    sealed_chunks_per_sec: u64 = 0,
};

pub const Options = struct {
    dir: []const u8,
    ram: []const u8,
};

pub const ChunkRange = struct {
    start: usize,
    end: usize,
};

pub const FlushOptions = struct {
    tail: bool,
    stop: ?*const std.atomic.Value(bool) = null,
    record_cpu: bool = false,
    before_seal: ?*const fn (*anyopaque, usize) anyerror!void = null,
    before_seal_ctx: ?*anyopaque = null,
};

pub const Sealer = struct {
    allocator: std.mem.Allocator,
    dir: []const u8,
    ram: []const u8,
    refs: []?[]const u8,
    dirty_chunks: []bool,
    backing_fd: std.c.fd_t,
    backing_tmp_path: [:0]const u8,
    backing_final_path: [:0]const u8,
    finished: bool = false,
    stats: Stats = .{},

    pub fn start(allocator: std.mem.Allocator, options: Options) !Sealer {
        if (options.ram.len == 0) return error.BadManifest;
        if (options.ram.len % std.heap.page_size_min != 0) return error.BadManifest;
        if (spore.chunk_size % std.heap.page_size_min != 0) return error.BadManifest;

        const chunk_count = (options.ram.len + spore.chunk_size - 1) / spore.chunk_size;
        const dir_z = try pathZ(allocator, "{s}", .{options.dir});
        const chunks_dir = try pathZ(allocator, "{s}/chunks", .{options.dir});
        try ensureDir(dir_z);
        try ensureDir(chunks_dir);

        const backing_tmp_path = try pathZ(allocator, "{s}/{s}.tmp", .{ options.dir, spore.ram_backing_path });
        const backing_final_path = try pathZ(allocator, "{s}/{s}", .{ options.dir, spore.ram_backing_path });
        const backing_fd = std.c.open(backing_tmp_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
        if (backing_fd < 0) return error.IoFailed;
        errdefer _ = std.c.close(backing_fd);
        if (std.c.ftruncate(backing_fd, @intCast(options.ram.len)) != 0) return error.IoFailed;

        var sealer = Sealer{
            .allocator = allocator,
            .dir = options.dir,
            .ram = options.ram,
            .refs = try allocator.alloc(?[]const u8, chunk_count),
            .dirty_chunks = try allocator.alloc(bool, chunk_count),
            .backing_fd = backing_fd,
            .backing_tmp_path = backing_tmp_path,
            .backing_final_path = backing_final_path,
        };
        @memset(sealer.refs, null);
        @memset(sealer.dirty_chunks, false);

        const seed_start = try monotonicMs();
        for (sealer.refs, 0..) |_, i| {
            const nonzero = try sealer.sealChunk(i, false);
            sealer.stats.seed_chunks += 1;
            if (nonzero) sealer.stats.seed_nonzero_chunks += 1;
        }
        sealer.stats.seed_ms = (try monotonicMs()) - seed_start;
        return sealer;
    }

    pub fn deinit(self: *Sealer) void {
        if (self.backing_fd >= 0) {
            _ = std.c.close(self.backing_fd);
            self.backing_fd = -1;
        }
        if (!self.finished) {
            _ = std.c.unlink(self.backing_tmp_path.ptr);
        }
    }

    pub fn chunkCount(self: *const Sealer) usize {
        return self.refs.len;
    }

    pub fn chunkRange(self: *const Sealer, index: usize) ChunkRange {
        const chunk_start = index * spore.chunk_size;
        return .{ .start = chunk_start, .end = @min(chunk_start + spore.chunk_size, self.ram.len) };
    }

    pub fn markCollectedChunkDirty(self: *Sealer, index: usize) void {
        self.dirty_chunks[index] = true;
    }

    pub fn markHostDirtyRange(self: *Sealer, offset: usize, len: usize) void {
        if (len == 0) return;
        const first_chunk = offset / spore.chunk_size;
        const last_byte = offset + len - 1;
        const last_chunk = last_byte / spore.chunk_size;

        self.stats.host_dirty_ranges_total += 1;
        var chunk_index = first_chunk;
        while (chunk_index <= last_chunk) : (chunk_index += 1) {
            if (!self.dirty_chunks[chunk_index]) {
                self.stats.host_dirty_chunks_total += 1;
            }
            self.dirty_chunks[chunk_index] = true;
        }
    }

    pub fn hasDirtyChunks(self: *const Sealer) bool {
        for (self.dirty_chunks) |is_dirty| {
            if (is_dirty) return true;
        }
        return false;
    }

    pub fn flushMarked(self: *Sealer, options: FlushOptions) !u64 {
        if (!self.hasDirtyChunks()) return 0;

        var dirty_chunks_this_flush: u64 = 0;
        const seal_start = try monotonicMs();
        const seal_cpu_start = if (options.record_cpu) threadCpuNs() else 0;
        for (self.dirty_chunks, 0..) |is_dirty, i| {
            if (!options.tail) {
                if (options.stop) |stop| {
                    if (stop.load(.acquire)) break;
                }
            }
            if (!is_dirty) continue;
            self.dirty_chunks[i] = false;
            dirty_chunks_this_flush += 1;
            if (options.before_seal) |before_seal| {
                try before_seal(options.before_seal_ctx orelse return error.BadManifest, i);
            }
            _ = try self.sealChunk(i, true);
        }
        self.stats.seal_ms += (try monotonicMs()) - seal_start;
        if (options.record_cpu) self.stats.seal_cpu_ms += elapsedCpuMs(seal_cpu_start);
        self.stats.dirty_chunks_total += dirty_chunks_this_flush;
        if (options.tail) self.stats.dirty_chunks_tail += dirty_chunks_this_flush;
        return dirty_chunks_this_flush;
    }

    pub fn resetStatsAfterBaseline(self: *Sealer) void {
        self.stats.dirty_chunks_total = 0;
        self.stats.dirty_chunks_tail = 0;
        self.stats.host_dirty_ranges_total = 0;
        self.stats.host_dirty_chunks_total = 0;
        self.stats.sealed_chunks_total = 0;
        self.stats.seal_ms = 0;
        self.stats.seal_cpu_ms = 0;
        self.stats.tail_flush_ms = 0;
        self.stats.finish_fchmod_ms = 0;
        self.stats.finish_close_ms = 0;
        self.stats.finish_close_deferred = 0;
        self.stats.finish_rename_ms = 0;
        self.stats.tracking_ms = 0;
        self.stats.dirty_chunks_per_sec = 0;
        self.stats.sealed_chunks_per_sec = 0;
        @memset(self.dirty_chunks, false);
    }

    pub fn finishRates(self: *Sealer, tracking_start_ms: u64, now_ms: u64) void {
        if (now_ms <= tracking_start_ms) return;
        const tracking_ms = now_ms - tracking_start_ms;
        self.stats.tracking_ms = tracking_ms;
        self.stats.dirty_chunks_per_sec = ratePerSec(self.stats.dirty_chunks_total, tracking_ms);
        self.stats.sealed_chunks_per_sec = ratePerSec(self.stats.sealed_chunks_total, tracking_ms);
    }

    pub fn finishBacking(self: *Sealer) !spore.MemoryManifest {
        const fchmod_start = try monotonicMs();
        const fchmod_rc = std.c.fchmod(self.backing_fd, 0o444);
        self.stats.finish_fchmod_ms = (try monotonicMs()) - fchmod_start;
        if (fchmod_rc != 0) return error.IoFailed;

        const rename_start = try monotonicMs();
        const rename_rc = std.c.rename(self.backing_tmp_path.ptr, self.backing_final_path.ptr);
        self.stats.finish_rename_ms = (try monotonicMs()) - rename_start;
        if (rename_rc != 0) return error.IoFailed;

        const close_fd = self.backing_fd;
        if (closeBackingFdDeferred(close_fd)) {
            self.stats.finish_close_deferred = 1;
            self.backing_fd = -1;
        } else {
            const close_start = try monotonicMs();
            _ = std.c.close(close_fd);
            self.stats.finish_close_ms = (try monotonicMs()) - close_start;
            self.backing_fd = -1;
        }
        self.finished = true;

        return .{
            .chunk_size = spore.chunk_size,
            .chunks = self.refs,
            .backing = .{ .path = spore.ram_backing_path, .size = self.ram.len },
        };
    }

    fn sealChunk(self: *Sealer, index: usize, count_dirty_seal: bool) !bool {
        const range = self.chunkRange(index);
        const data = self.ram[range.start..range.end];

        if (std.mem.allEqual(u8, data, 0)) {
            if (self.refs[index] != null) {
                self.refs[index] = null;
                try pwriteFileAll(self.backing_fd, range.start, data);
                if (count_dirty_seal) self.stats.sealed_chunks_total += 1;
            }
            return false;
        }

        const id = chunk.ChunkId.fromContents(data);
        const hex = id.toHex();
        const existing = self.refs[index];
        if (existing == null or !std.mem.eql(u8, existing.?, &hex)) {
            const ref = try self.allocator.dupe(u8, &hex);
            self.refs[index] = ref;
            const chunk_path = try pathZ(self.allocator, "{s}/chunks/{s}", .{ self.dir, ref });
            if (std.c.access(chunk_path, 0) != 0) {
                try writeFileAll(chunk_path, data);
            }
        }
        try pwriteFileAll(self.backing_fd, range.start, data);
        if (count_dirty_seal) self.stats.sealed_chunks_total += 1;
        return true;
    }
};

fn closeBackingFdDeferred(fd: std.c.fd_t) bool {
    const thread = std.Thread.spawn(.{}, closeBackingFdThread, .{fd}) catch return false;
    thread.detach();
    return true;
}

fn closeBackingFdThread(fd: std.c.fd_t) void {
    _ = std.c.close(fd);
}

fn writeFileAll(path: [:0]const u8, data: []const u8) !void {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);
    var done: usize = 0;
    while (done < data.len) {
        const n = std.c.write(fd, data.ptr + done, data.len - done);
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
}

fn pwriteFileAll(fd: std.c.fd_t, offset: usize, data: []const u8) !void {
    var done: usize = 0;
    while (done < data.len) {
        const n = std.c.pwrite(fd, data.ptr + done, data.len - done, @intCast(offset + done));
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
}

fn ensureDir(path: [:0]const u8) !void {
    if (std.c.mkdir(path, 0o755) != 0) {
        if (std.c.access(path, 0) != 0) return error.IoFailed;
    }
}

fn pathZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(allocator, fmt, args, 0) catch error.OutOfMemory;
}

fn monotonicMs() !u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return error.ClockFailed;
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn threadCpuNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.THREAD_CPUTIME_ID, &ts) != 0) return 0;
    const seconds: u64 = @intCast(ts.sec);
    const nanos: u64 = @intCast(ts.nsec);
    return seconds * std.time.ns_per_s + nanos;
}

fn nsToMs(ns: u64) u64 {
    return ns / std.time.ns_per_ms;
}

fn elapsedCpuMs(start_ns: u64) u64 {
    if (start_ns == 0) return 0;
    const end_ns = threadCpuNs();
    if (end_ns <= start_ns) return 0;
    return nsToMs(end_ns - start_ns);
}

fn ratePerSec(count: u64, elapsed_ms: u64) u64 {
    if (elapsed_ms == 0) return 0;
    return count * std.time.ms_per_s / elapsed_ms;
}

// --- tests ------------------------------------------------------------------

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

fn testDir(allocator: std.mem.Allocator) ![]const u8 {
    const tmpl = "/tmp/sporevm-dirty-ram-test-XXXXXX";
    const buf = try allocator.dupeZ(u8, tmpl);
    if (mkdtemp(buf) == null) return error.IoFailed;
    return buf;
}

fn readFileAllForTest(allocator: std.mem.Allocator, path: [:0]const u8, max: usize) ![]u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);

    const cur = std.c.lseek(fd, 0, std.c.SEEK.CUR);
    if (cur < 0) return error.IoFailed;
    const end = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (end < 0) return error.IoFailed;
    if (std.c.lseek(fd, cur, std.c.SEEK.SET) < 0) return error.IoFailed;
    const size: usize = @intCast(end);
    if (size > max) return error.BadManifest;

    const buf = try allocator.alloc(u8, size);
    var done: usize = 0;
    while (done < size) {
        const n = std.c.read(fd, buf.ptr + done, size - done);
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
    return buf;
}

test "dirty RAM sealer seeds zero-elided chunks and finalizes backing" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    const ram = try arena.alloc(u8, 2 * spore.chunk_size + std.heap.page_size_min);
    @memset(ram, 0);
    ram[0] = 0x11;
    ram[ram.len - 1] = 0xEE;

    var sealer = try Sealer.start(arena, .{ .dir = dir, .ram = ram });
    defer sealer.deinit();

    try std.testing.expectEqual(@as(usize, 3), sealer.chunkCount());
    try std.testing.expectEqual(@as(usize, 3), sealer.stats.seed_chunks);
    try std.testing.expectEqual(@as(usize, 2), sealer.stats.seed_nonzero_chunks);
    try std.testing.expect(sealer.refs[0] != null);
    try std.testing.expect(sealer.refs[1] == null);
    try std.testing.expect(sealer.refs[2] != null);
    try std.testing.expectEqual(@as(u64, 0), sealer.stats.dirty_chunks_total);

    const manifest = try sealer.finishBacking();
    const plan = try spore.validateMemoryForRam(manifest, ram.len);
    try std.testing.expectEqual(@as(usize, 3), plan.chunk_count);
    try std.testing.expectEqual(@as(usize, 2), plan.nonzero_chunk_count);
    try std.testing.expect(manifest.backing != null);

    const backing_path = try pathZ(arena, "{s}/{s}", .{ dir, spore.ram_backing_path });
    const backing = try readFileAllForTest(arena, backing_path, ram.len);
    try std.testing.expectEqualSlices(u8, ram, backing);

    const chunk_path = try pathZ(arena, "{s}/chunks/{s}", .{ dir, manifest.chunks[0].? });
    try std.testing.expectEqual(@as(c_int, 0), std.c.access(chunk_path, 0));
}

test "dirty RAM sealer tracks dirty ranges tail counts and zero transitions" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    const ram = try arena.alloc(u8, 2 * spore.chunk_size);
    @memset(ram, 0);

    var sealer = try Sealer.start(arena, .{ .dir = dir, .ram = ram });
    defer sealer.deinit();
    sealer.resetStatsAfterBaseline();

    ram[0] = 0x44;
    sealer.markHostDirtyRange(0, 1);
    try std.testing.expectEqual(@as(u64, 1), sealer.stats.host_dirty_ranges_total);
    try std.testing.expectEqual(@as(u64, 1), sealer.stats.host_dirty_chunks_total);

    const flushed = try sealer.flushMarked(.{ .tail = false });
    try std.testing.expectEqual(@as(u64, 1), flushed);
    try std.testing.expectEqual(@as(u64, 1), sealer.stats.dirty_chunks_total);
    try std.testing.expectEqual(@as(u64, 0), sealer.stats.dirty_chunks_tail);
    try std.testing.expectEqual(@as(u64, 1), sealer.stats.sealed_chunks_total);
    try std.testing.expect(sealer.refs[0] != null);

    ram[0] = 0;
    sealer.markCollectedChunkDirty(0);
    const tail_flushed = try sealer.flushMarked(.{ .tail = true });
    try std.testing.expectEqual(@as(u64, 1), tail_flushed);
    try std.testing.expectEqual(@as(u64, 2), sealer.stats.dirty_chunks_total);
    try std.testing.expectEqual(@as(u64, 1), sealer.stats.dirty_chunks_tail);
    try std.testing.expectEqual(@as(u64, 2), sealer.stats.sealed_chunks_total);
    try std.testing.expect(sealer.refs[0] == null);

    _ = try sealer.finishBacking();
    const backing_path = try pathZ(arena, "{s}/{s}", .{ dir, spore.ram_backing_path });
    const backing = try readFileAllForTest(arena, backing_path, ram.len);
    try std.testing.expect(std.mem.allEqual(u8, backing, 0));
}

test "dirty RAM sealer leaves stopped non-tail work for tail flush" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    const ram = try arena.alloc(u8, 2 * spore.chunk_size);
    @memset(ram, 0);

    var sealer = try Sealer.start(arena, .{ .dir = dir, .ram = ram });
    defer sealer.deinit();
    sealer.resetStatsAfterBaseline();

    ram[0] = 0xAA;
    ram[spore.chunk_size] = 0xBB;
    sealer.markHostDirtyRange(0, spore.chunk_size + 1);

    var stop = std.atomic.Value(bool).init(true);
    const flushed = try sealer.flushMarked(.{ .tail = false, .stop = &stop });
    try std.testing.expectEqual(@as(u64, 0), flushed);
    try std.testing.expect(sealer.hasDirtyChunks());

    const tail_flushed = try sealer.flushMarked(.{ .tail = true, .stop = &stop });
    try std.testing.expectEqual(@as(u64, 2), tail_flushed);
    try std.testing.expectEqual(@as(u64, 2), sealer.stats.dirty_chunks_total);
    try std.testing.expectEqual(@as(u64, 2), sealer.stats.dirty_chunks_tail);
    try std.testing.expect(!sealer.hasDirtyChunks());
}
