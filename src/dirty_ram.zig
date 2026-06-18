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
    seal_zero_scan_ns: u64 = 0,
    seal_hash_ns: u64 = 0,
    seal_chunk_write_ns: u64 = 0,
    seal_backing_write_ns: u64 = 0,
    seal_parallel_flush_count: u64 = 0,
    seal_parallel_workers_max: u64 = 0,
    tail_flush_ms: u64 = 0,
    finish_fchmod_ms: u64 = 0,
    finish_close_ms: u64 = 0,
    finish_close_deferred: u64 = 0,
    finish_rename_ms: u64 = 0,
    tracking_ms: u64 = 0,
    dirty_chunks_per_sec: u64 = 0,
    sealed_chunks_per_sec: u64 = 0,

    pub fn sealZeroScanMs(self: *const Stats) u64 {
        return nsToMs(self.seal_zero_scan_ns);
    }

    pub fn sealHashMs(self: *const Stats) u64 {
        return nsToMs(self.seal_hash_ns);
    }

    pub fn sealChunkWriteMs(self: *const Stats) u64 {
        return nsToMs(self.seal_chunk_write_ns);
    }

    pub fn sealBackingWriteMs(self: *const Stats) u64 {
        return nsToMs(self.seal_backing_write_ns);
    }
};

const SealWorkStats = struct {
    sealed_chunks: u64 = 0,
    zero_scan_ns: u64 = 0,
    hash_ns: u64 = 0,
    chunk_write_ns: u64 = 0,
    backing_write_ns: u64 = 0,
    cpu_ns: u64 = 0,

    fn add(self: *SealWorkStats, other: SealWorkStats) void {
        self.sealed_chunks +|= other.sealed_chunks;
        self.zero_scan_ns +|= other.zero_scan_ns;
        self.hash_ns +|= other.hash_ns;
        self.chunk_write_ns +|= other.chunk_write_ns;
        self.backing_write_ns +|= other.backing_write_ns;
        self.cpu_ns +|= other.cpu_ns;
    }
};

const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

pub const Options = struct {
    dir: []const u8,
    ram: []const u8,
    seed_ranges: ?[]const ChunkRange = null,
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
    alloc_mutex: SpinLock = .{},
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
        var backing_fd_owned = true;
        errdefer if (backing_fd_owned) {
            _ = std.c.close(backing_fd);
            _ = std.c.unlink(backing_tmp_path.ptr);
        };
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
        backing_fd_owned = false;
        errdefer sealer.deinit();
        @memset(sealer.refs, null);
        @memset(sealer.dirty_chunks, false);

        try sealer.seedInitial(options.seed_ranges);
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
        var dirty_indices = try self.collectDirtyIndices(options);
        defer dirty_indices.deinit(self.allocator);
        if (dirty_indices.items.len == 0) return 0;

        const dirty_chunks_this_flush: u64 = @intCast(dirty_indices.items.len);
        const seal_start = try monotonicMs();
        const seal_cpu_start = if (options.record_cpu) threadCpuNs() else 0;
        var work_stats: SealWorkStats = .{};

        if (self.shouldParallelFlush(options, dirty_indices.items.len)) {
            work_stats = try self.flushIndicesParallel(dirty_indices.items, options.record_cpu);
        } else {
            try self.flushIndicesSerial(dirty_indices.items, options, &work_stats);
        }

        self.stats.seal_ms += (try monotonicMs()) - seal_start;
        if (options.record_cpu) {
            if (work_stats.cpu_ns != 0) {
                self.stats.seal_cpu_ms +|= nsToMs(work_stats.cpu_ns);
            } else {
                self.stats.seal_cpu_ms +|= elapsedCpuMs(seal_cpu_start);
            }
        }
        self.recordSealWork(work_stats);
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
        self.stats.seal_zero_scan_ns = 0;
        self.stats.seal_hash_ns = 0;
        self.stats.seal_chunk_write_ns = 0;
        self.stats.seal_backing_write_ns = 0;
        self.stats.seal_parallel_flush_count = 0;
        self.stats.seal_parallel_workers_max = 0;
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

    fn collectDirtyIndices(self: *Sealer, options: FlushOptions) !std.ArrayList(usize) {
        var dirty_indices: std.ArrayList(usize) = .empty;
        errdefer dirty_indices.deinit(self.allocator);

        for (self.dirty_chunks, 0..) |is_dirty, i| {
            if (!options.tail) {
                if (options.stop) |stop| {
                    if (stop.load(.acquire)) break;
                }
            }
            if (!is_dirty) continue;
            try dirty_indices.append(self.allocator, i);
        }
        return dirty_indices;
    }

    fn shouldParallelFlush(self: *const Sealer, options: FlushOptions, dirty_count: usize) bool {
        _ = self;
        if (!options.tail) return false;
        if (options.before_seal != null) return false;
        return dirty_count >= 4 and parallelWorkerCount(dirty_count) > 1;
    }

    fn flushIndicesSerial(self: *Sealer, indices: []const usize, options: FlushOptions, work_stats: *SealWorkStats) !void {
        for (indices) |i| {
            self.dirty_chunks[i] = false;
            if (options.before_seal) |before_seal| {
                before_seal(options.before_seal_ctx orelse return error.BadManifest, i) catch |err| {
                    self.dirty_chunks[i] = true;
                    return err;
                };
            }
            _ = self.sealChunk(i, true, work_stats) catch |err| {
                self.dirty_chunks[i] = true;
                return err;
            };
        }
    }

    fn flushIndicesParallel(self: *Sealer, indices: []const usize, record_cpu: bool) !SealWorkStats {
        const worker_count = parallelWorkerCount(indices.len);
        var threads = try self.allocator.alloc(std.Thread, worker_count);
        defer self.allocator.free(threads);
        const worker_stats = try self.allocator.alloc(SealWorkStats, worker_count);
        defer self.allocator.free(worker_stats);
        const worker_errors = try self.allocator.alloc(?anyerror, worker_count);
        defer self.allocator.free(worker_errors);
        @memset(worker_stats, .{});
        @memset(worker_errors, null);

        var context = ParallelSealContext{
            .sealer = self,
            .indices = indices,
            .record_cpu = record_cpu,
            .worker_stats = worker_stats,
            .worker_errors = worker_errors,
        };

        var started: usize = 0;
        while (started < worker_count) : (started += 1) {
            threads[started] = std.Thread.spawn(.{}, parallelSealWorker, .{ &context, started }) catch |err| {
                context.failed.store(true, .release);
                var join_index: usize = 0;
                while (join_index < started) : (join_index += 1) threads[join_index].join();
                return err;
            };
        }
        self.stats.seal_parallel_flush_count +|= 1;
        self.stats.seal_parallel_workers_max = @max(self.stats.seal_parallel_workers_max, worker_count);

        for (threads) |thread| thread.join();
        for (worker_errors) |maybe_err| {
            if (maybe_err) |err| return err;
        }

        var out: SealWorkStats = .{};
        for (worker_stats) |stats| out.add(stats);
        return out;
    }

    fn recordSealWork(self: *Sealer, work_stats: SealWorkStats) void {
        self.stats.sealed_chunks_total +|= work_stats.sealed_chunks;
        self.stats.seal_zero_scan_ns +|= work_stats.zero_scan_ns;
        self.stats.seal_hash_ns +|= work_stats.hash_ns;
        self.stats.seal_chunk_write_ns +|= work_stats.chunk_write_ns;
        self.stats.seal_backing_write_ns +|= work_stats.backing_write_ns;
    }

    fn sealChunk(self: *Sealer, index: usize, count_dirty_seal: bool, work_stats: *SealWorkStats) !bool {
        const range = self.chunkRange(index);
        const data = self.ram[range.start..range.end];

        const zero_scan_start = try monotonicNs();
        const is_zero = std.mem.allEqual(u8, data, 0);
        work_stats.zero_scan_ns +|= try elapsedMonotonicNs(zero_scan_start);

        if (is_zero) {
            if (self.refs[index] != null) {
                const backing_write_start = try monotonicNs();
                try pwriteFileAll(self.backing_fd, range.start, data);
                work_stats.backing_write_ns +|= try elapsedMonotonicNs(backing_write_start);
                self.refs[index] = null;
                if (count_dirty_seal) work_stats.sealed_chunks += 1;
            }
            return false;
        }

        const hash_start = try monotonicNs();
        const id = chunk.ChunkId.fromContents(data);
        work_stats.hash_ns +|= try elapsedMonotonicNs(hash_start);
        const hex = id.toHex();
        const existing = self.refs[index];
        if (existing == null or !std.mem.eql(u8, existing.?, &hex)) {
            const ref, const chunk_path = try self.allocChunkRefAndPath(&hex);
            const chunk_write_start = try monotonicNs();
            try writeFileAllIfMissing(chunk_path, data);
            work_stats.chunk_write_ns +|= try elapsedMonotonicNs(chunk_write_start);
            self.refs[index] = ref;
        }
        const backing_write_start = try monotonicNs();
        try pwriteFileAll(self.backing_fd, range.start, data);
        work_stats.backing_write_ns +|= try elapsedMonotonicNs(backing_write_start);
        if (count_dirty_seal) work_stats.sealed_chunks += 1;
        return true;
    }

    fn seedInitial(self: *Sealer, maybe_ranges: ?[]const ChunkRange) !void {
        const seed_start = try monotonicMs();
        if (maybe_ranges) |ranges| {
            var seeded = try self.allocator.alloc(bool, self.refs.len);
            defer self.allocator.free(seeded);
            @memset(seeded, false);

            for (ranges) |range| {
                if (range.start > range.end or range.end > self.ram.len) return error.BadManifest;
                if (range.start == range.end) continue;
                const first_chunk = range.start / spore.chunk_size;
                const last_chunk = (range.end - 1) / spore.chunk_size;
                var chunk_index = first_chunk;
                while (chunk_index <= last_chunk) : (chunk_index += 1) {
                    if (seeded[chunk_index]) continue;
                    seeded[chunk_index] = true;
                    try self.seedChunk(chunk_index);
                }
            }
        } else {
            for (self.refs, 0..) |_, i| try self.seedChunk(i);
        }
        self.stats.seed_ms = (try monotonicMs()) - seed_start;
    }

    fn seedChunk(self: *Sealer, index: usize) !void {
        var work_stats: SealWorkStats = .{};
        const nonzero = try self.sealChunk(index, false, &work_stats);
        self.stats.seed_chunks += 1;
        if (nonzero) self.stats.seed_nonzero_chunks += 1;
    }

    fn allocChunkRefAndPath(self: *Sealer, hex: *const [chunk.ChunkId.hex_len]u8) !struct { []const u8, [:0]const u8 } {
        self.alloc_mutex.lock();
        defer self.alloc_mutex.unlock();
        const ref = try self.allocator.dupe(u8, hex);
        const chunk_path = try pathZ(self.allocator, "{s}/chunks/{s}", .{ self.dir, ref });
        return .{ ref, chunk_path };
    }
};

const ParallelSealContext = struct {
    sealer: *Sealer,
    indices: []const usize,
    record_cpu: bool,
    next_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker_stats: []SealWorkStats,
    worker_errors: []?anyerror,
};

fn parallelSealWorker(context: *ParallelSealContext, worker_index: usize) void {
    var work_stats: SealWorkStats = .{};
    const cpu_start = if (context.record_cpu) threadCpuNs() else 0;
    defer {
        if (context.record_cpu) work_stats.cpu_ns = elapsedCpuNs(cpu_start);
        context.worker_stats[worker_index] = work_stats;
    }

    while (!context.failed.load(.acquire)) {
        const next = context.next_index.fetchAdd(1, .monotonic);
        if (next >= context.indices.len) break;
        const chunk_index = context.indices[next];
        context.sealer.dirty_chunks[chunk_index] = false;
        _ = context.sealer.sealChunk(chunk_index, true, &work_stats) catch |err| {
            context.sealer.dirty_chunks[chunk_index] = true;
            context.worker_errors[worker_index] = err;
            context.failed.store(true, .release);
            break;
        };
    }
}

fn parallelWorkerCount(dirty_count: usize) usize {
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return @min(@min(cpu_count, 8), dirty_count);
}

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

fn writeFileAllIfMissing(path: [:0]const u8, data: []const u8) !void {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(c_uint, 0o644));
    if (fd < 0) {
        if (std.c.errno(fd) == .EXIST) return;
        return error.IoFailed;
    }
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

fn monotonicNs() !u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return error.ClockFailed;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn elapsedMonotonicNs(start_ns: u64) !u64 {
    const end_ns = try monotonicNs();
    if (end_ns <= start_ns) return 0;
    return end_ns - start_ns;
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
    return nsToMs(elapsedCpuNs(start_ns));
}

fn elapsedCpuNs(start_ns: u64) u64 {
    if (start_ns == 0) return 0;
    const end_ns = threadCpuNs();
    if (end_ns <= start_ns) return 0;
    return end_ns - start_ns;
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

test "dirty RAM sealer can seed only known populated ranges" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    const ram = try arena.alloc(u8, 3 * spore.chunk_size);
    @memset(ram, 0);
    ram[0] = 0x11;
    ram[2 * spore.chunk_size] = 0x22;

    const seed_ranges = [_]ChunkRange{.{ .start = 0, .end = 1 }};
    var sealer = try Sealer.start(arena, .{ .dir = dir, .ram = ram, .seed_ranges = &seed_ranges });
    defer sealer.deinit();

    try std.testing.expectEqual(@as(usize, 3), sealer.chunkCount());
    try std.testing.expectEqual(@as(usize, 1), sealer.stats.seed_chunks);
    try std.testing.expectEqual(@as(usize, 1), sealer.stats.seed_nonzero_chunks);
    try std.testing.expect(sealer.refs[0] != null);
    try std.testing.expect(sealer.refs[1] == null);
    try std.testing.expect(sealer.refs[2] == null);

    const manifest = try sealer.finishBacking();
    const plan = try spore.validateMemoryForRam(manifest, ram.len);
    try std.testing.expectEqual(@as(usize, 3), plan.chunk_count);
    try std.testing.expectEqual(@as(usize, 1), plan.nonzero_chunk_count);

    const backing_path = try pathZ(arena, "{s}/{s}", .{ dir, spore.ram_backing_path });
    const backing = try readFileAllForTest(arena, backing_path, ram.len);
    try std.testing.expectEqual(@as(u8, 0x11), backing[0]);
    try std.testing.expectEqual(@as(u8, 0), backing[2 * spore.chunk_size]);
}

test "dirty RAM sealer deduplicates overlapping seed ranges" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    const ram = try arena.alloc(u8, 3 * spore.chunk_size);
    @memset(ram, 0);
    ram[0] = 0x11;
    ram[spore.chunk_size] = 0x22;
    ram[2 * spore.chunk_size] = 0x33;

    const seed_ranges = [_]ChunkRange{
        .{ .start = 1, .end = spore.chunk_size + 1 },
        .{ .start = spore.chunk_size, .end = 2 * spore.chunk_size },
    };
    var sealer = try Sealer.start(arena, .{ .dir = dir, .ram = ram, .seed_ranges = &seed_ranges });
    defer sealer.deinit();

    try std.testing.expectEqual(@as(usize, 2), sealer.stats.seed_chunks);
    try std.testing.expectEqual(@as(usize, 2), sealer.stats.seed_nonzero_chunks);
    try std.testing.expect(sealer.refs[0] != null);
    try std.testing.expect(sealer.refs[1] != null);
    try std.testing.expect(sealer.refs[2] == null);
}

test "dirty RAM sealer rejects seed ranges outside RAM" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    const ram = try arena.alloc(u8, spore.chunk_size);
    @memset(ram, 0);

    const seed_ranges = [_]ChunkRange{.{ .start = 0, .end = ram.len + 1 }};
    try std.testing.expectError(error.BadManifest, Sealer.start(arena, .{ .dir = dir, .ram = ram, .seed_ranges = &seed_ranges }));

    const tmp_path = try pathZ(arena, "{s}/{s}.tmp", .{ dir, spore.ram_backing_path });
    try std.testing.expect(std.c.access(tmp_path, 0) != 0);
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

test "dirty RAM sealer preserves refs when zero backing write fails" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    const ram = try arena.alloc(u8, spore.chunk_size);
    @memset(ram, 0);
    ram[0] = 0x77;

    var sealer = try Sealer.start(arena, .{ .dir = dir, .ram = ram });
    defer sealer.deinit();
    const old_ref = sealer.refs[0].?;
    sealer.resetStatsAfterBaseline();

    ram[0] = 0;
    sealer.markCollectedChunkDirty(0);
    _ = std.c.close(sealer.backing_fd);
    sealer.backing_fd = -1;

    try std.testing.expectError(error.IoFailed, sealer.flushMarked(.{ .tail = true }));
    try std.testing.expect(sealer.refs[0] != null);
    try std.testing.expectEqualSlices(u8, old_ref, sealer.refs[0].?);
    try std.testing.expect(sealer.hasDirtyChunks());
}

test "dirty RAM sealer can flush a dirty tail in parallel" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    const ram = try arena.alloc(u8, 8 * spore.chunk_size);
    @memset(ram, 0);

    var sealer = try Sealer.start(arena, .{ .dir = dir, .ram = ram });
    defer sealer.deinit();
    sealer.resetStatsAfterBaseline();

    for (0..8) |i| {
        ram[i * spore.chunk_size] = @intCast(0x20 + i);
        sealer.markCollectedChunkDirty(i);
    }

    const tail_flushed = try sealer.flushMarked(.{ .tail = true, .record_cpu = true });
    try std.testing.expectEqual(@as(u64, 8), tail_flushed);
    try std.testing.expectEqual(@as(u64, 8), sealer.stats.dirty_chunks_total);
    try std.testing.expectEqual(@as(u64, 8), sealer.stats.dirty_chunks_tail);
    try std.testing.expectEqual(@as(u64, 8), sealer.stats.sealed_chunks_total);
    try std.testing.expect(!sealer.hasDirtyChunks());

    const expected_workers = parallelWorkerCount(8);
    if (expected_workers > 1) {
        try std.testing.expectEqual(@as(u64, 1), sealer.stats.seal_parallel_flush_count);
        try std.testing.expectEqual(@as(u64, @intCast(expected_workers)), sealer.stats.seal_parallel_workers_max);
    }

    _ = try sealer.finishBacking();
    const backing_path = try pathZ(arena, "{s}/{s}", .{ dir, spore.ram_backing_path });
    const backing = try readFileAllForTest(arena, backing_path, ram.len);
    try std.testing.expectEqualSlices(u8, ram, backing);
}
