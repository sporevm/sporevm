//! Virtio block device (virtio spec 1.2 §5.2), minimal.
//!
//! One request queue. Supports IN (read), OUT (write), FLUSH (no-op for the
//! memory backend, fsync for files), and GET_ID. Request framing, sectors,
//! and lengths are guest controlled and validated. See SECURITY.md.

const std = @import("std");
const builtin = @import("builtin");
const block_source = @import("../block_source.zig");
const chunk_mapped_disk = @import("../chunk_mapped_disk.zig");
const disk_index = @import("../disk_index.zig");
const disk_layer = @import("../disk_layer.zig");
const guestmem = @import("../guestmem.zig");
const rootfs_cache = @import("../rootfs_cache.zig");
const rootfs_cas = @import("../rootfs_cas.zig");
const spore = @import("../spore.zig");
const queue = @import("queue.zig");
const mmio = @import("mmio.zig");

const Io = std.Io;

pub const device_id: u32 = 2;
pub const sector_size = 512;

const req_in: u32 = 0; // device writes data to guest
const req_out: u32 = 1; // device reads data from guest
const req_flush: u32 = 4;
const req_get_id: u32 = 8;
const req_write_zeroes: u32 = 13;

pub const feature_write_zeroes: u64 = 1 << 14;
pub const max_write_zeroes_sectors: u32 = (4 * 1024 * 1024) / sector_size;
pub const write_zeroes_flag_unmap: u32 = 0x1;

const status_ok: u8 = 0;
const status_ioerr: u8 = 1;
const status_unsupp: u8 = 2;

pub const Backend = union(enum) {
    /// Host file descriptor. Read-only fds are valid for immutable rootfs
    /// attachments; guest write requests then return an I/O error.
    file: std.c.fd_t,
    /// One-level chunk map over a flat base and optional sparse writable head.
    chunk_mapped: *chunk_mapped_disk.ChunkMappedDisk,
    /// In-memory disk, used by tests.
    memory: []u8,

    fn capacityBytes(self: Backend) u64 {
        switch (self) {
            .file => |fd| {
                return seekFileSize(fd) orelse 0;
            },
            .chunk_mapped => |disk| return disk.capacityBytes(),
            .memory => |m| return m.len,
        }
    }

    fn readAt(self: Backend, buf: []u8, offset: u64) bool {
        switch (self) {
            .file => |fd| {
                var done: usize = 0;
                while (done < buf.len) {
                    const n = std.c.pread(fd, buf.ptr + done, buf.len - done, @intCast(offset + done));
                    if (n <= 0) return false;
                    done += @intCast(n);
                }
                return true;
            },
            .chunk_mapped => |disk| {
                disk.readAt(buf, offset) catch |err| {
                    std.log.debug("virtio-blk chunk-mapped read failed: error={s} offset={d} len={d}", .{ @errorName(err), offset, buf.len });
                    return false;
                };
                return true;
            },
            .memory => |m| {
                if (offset + buf.len > m.len) return false;
                @memcpy(buf, m[@intCast(offset)..][0..buf.len]);
                return true;
            },
        }
    }

    fn prefaultCasRange(self: Backend, len: usize, offset: u64) bool {
        switch (self) {
            .chunk_mapped => |disk| disk.prefaultCasRange(len, offset) catch return false,
            .file, .memory => {},
        }
        return true;
    }

    fn writeAt(self: Backend, buf: []const u8, offset: u64) bool {
        switch (self) {
            .file => |fd| {
                var done: usize = 0;
                while (done < buf.len) {
                    const n = std.c.pwrite(fd, buf.ptr + done, buf.len - done, @intCast(offset + done));
                    if (n <= 0) return false;
                    done += @intCast(n);
                }
                return true;
            },
            .chunk_mapped => |disk| {
                disk.writeAt(buf, offset) catch |err| {
                    std.log.debug("virtio-blk chunk-mapped write failed: error={s} offset={d} len={d}", .{ @errorName(err), offset, buf.len });
                    return false;
                };
                return true;
            },
            .memory => |m| {
                if (offset + buf.len > m.len) return false;
                @memcpy(m[@intCast(offset)..][0..buf.len], buf);
                return true;
            },
        }
    }

    fn canZeroRange(self: Backend) bool {
        return switch (self) {
            .file => false,
            .chunk_mapped => |disk| disk.isWritable(),
            .memory => true,
        };
    }

    fn zeroRange(self: Backend, offset: u64, len: u64) bool {
        switch (self) {
            .file => return false,
            .chunk_mapped => |disk| {
                disk.zeroRange(offset, len) catch {
                    // This entrypoint is reached only after the complete
                    // guest request has been validated. A backend error may
                    // follow a partial host write, so permanently prevent
                    // this mutable head from being snapshotted or published.
                    disk.poison();
                    return false;
                };
                return true;
            },
            .memory => |m| {
                const end = std.math.add(u64, offset, len) catch return false;
                if (end > m.len) return false;
                const start_index = std.math.cast(usize, offset) orelse return false;
                const end_index = std.math.cast(usize, end) orelse return false;
                @memset(m[start_index..end_index], 0);
                return true;
            },
        }
    }

    fn poisonValidatedMutationFailure(self: Backend) void {
        switch (self) {
            .chunk_mapped => |disk| disk.poison(),
            .file, .memory => {},
        }
    }

    fn flush(self: Backend) bool {
        switch (self) {
            .file => |fd| return std.c.fsync(fd) == 0,
            .chunk_mapped => |disk| {
                disk.flush() catch |err| {
                    std.log.debug("virtio-blk chunk-mapped flush failed: error={s}", .{@errorName(err)});
                    return false;
                };
                return true;
            },
            .memory => return true,
        }
    }
};

fn seekFileSize(fd: std.c.fd_t) ?u64 {
    const cur = std.c.lseek(fd, 0, std.c.SEEK.CUR);
    if (cur < 0) return null;
    const end = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (end < 0) return null;
    if (std.c.lseek(fd, cur, std.c.SEEK.SET) < 0) return null;
    return @intCast(end);
}

pub const Options = struct {
    /// Reject ordinary guest writes before they reach any backend, including
    /// writable in-memory test backends, while preserving the frozen feature
    /// surface used by existing immutable product attachments.
    read_only: bool = false,
    /// Advertise and serve VIRTIO_BLK_F_WRITE_ZEROES. This is reserved for
    /// writable growth sessions; ordinary attachments keep the frozen
    /// feature surface by using the default.
    write_zeroes: bool = false,
    /// Experiment-only negative control: advertise and negotiate the feature,
    /// validate canonical requests, then return UNSUPP before mutation.
    force_write_zeroes_unsupported: bool = false,
    /// Experiment-only fail-closed control. The request passes every guest
    /// validation, then the mutable head is poisoned and returns IOERR.
    force_write_zeroes_backend_failure: bool = false,
    /// Unit-test-only ordinary-write failure point. Runtime callers never set
    /// this; it proves a later descriptor failure poisons an already-mutated
    /// chunk-mapped head.
    test_fail_out_after_segments: if (builtin.is_test) ?usize else void = if (builtin.is_test) null else {},
    stats: ?*Stats = null,
};

pub const Stats = struct {
    accepted_features: std.atomic.Value(u64) = .init(0),
    write_zeroes_requests: std.atomic.Value(u64) = .init(0),
    write_zeroes_bytes: std.atomic.Value(u64) = .init(0),
    write_zeroes_unmap_requests: std.atomic.Value(u64) = .init(0),
    write_zeroes_ok: std.atomic.Value(u64) = .init(0),
    write_zeroes_errors: std.atomic.Value(u64) = .init(0),
    write_zeroes_backend_failures: std.atomic.Value(u64) = .init(0),
    write_zeroes_unsupported: std.atomic.Value(u64) = .init(0),
    out_requests: std.atomic.Value(u64) = .init(0),
    out_bytes: std.atomic.Value(u64) = .init(0),
    out_all_zero_requests: std.atomic.Value(u64) = .init(0),
    out_all_zero_bytes: std.atomic.Value(u64) = .init(0),

    pub const Snapshot = struct {
        accepted_features: u64,
        write_zeroes_requests: u64,
        write_zeroes_bytes: u64,
        write_zeroes_unmap_requests: u64,
        write_zeroes_ok: u64,
        write_zeroes_errors: u64,
        write_zeroes_backend_failures: u64,
        write_zeroes_unsupported: u64,
        out_requests: u64,
        out_bytes: u64,
        out_all_zero_requests: u64,
        out_all_zero_bytes: u64,
    };

    pub fn snapshot(self: *const Stats) Snapshot {
        return .{
            .accepted_features = self.accepted_features.load(.monotonic),
            .write_zeroes_requests = self.write_zeroes_requests.load(.monotonic),
            .write_zeroes_bytes = self.write_zeroes_bytes.load(.monotonic),
            .write_zeroes_unmap_requests = self.write_zeroes_unmap_requests.load(.monotonic),
            .write_zeroes_ok = self.write_zeroes_ok.load(.monotonic),
            .write_zeroes_errors = self.write_zeroes_errors.load(.monotonic),
            .write_zeroes_backend_failures = self.write_zeroes_backend_failures.load(.acquire),
            .write_zeroes_unsupported = self.write_zeroes_unsupported.load(.monotonic),
            .out_requests = self.out_requests.load(.monotonic),
            .out_bytes = self.out_bytes.load(.monotonic),
            .out_all_zero_requests = self.out_all_zero_requests.load(.monotonic),
            .out_all_zero_bytes = self.out_all_zero_bytes.load(.monotonic),
        };
    }
};

pub const Blk = struct {
    backend: Backend,
    capacity_sectors: u64,
    options: Options = .{},
    accepted_features: u64 = 0,

    pub fn init(backend: Backend) Blk {
        return initWithOptions(backend, .{});
    }

    /// Context and cross-stage build inputs are immutable authority. Keep
    /// their feature surface frozen even when the writable root disk opts in
    /// to transient growth features.
    pub fn initImmutableSource(backend: Backend) Blk {
        return initWithOptions(backend, .{ .read_only = true });
    }

    pub fn initWithOptions(backend: Backend, options: Options) Blk {
        return .{
            .backend = backend,
            .capacity_sectors = backend.capacityBytes() / sector_size,
            .options = options,
        };
    }

    pub fn device(self: *Blk) mmio.Device {
        return .{
            .context = self,
            .device_id = device_id,
            .device_features = if (self.options.write_zeroes) feature_write_zeroes else 0,
            .queue_count = 1,
            .notifyFn = notify,
            .configReadFn = configRead,
            .featuresAcceptedFn = featuresAccepted,
        };
    }

    fn featuresAccepted(ctx: *anyopaque, accepted_features: u64) void {
        const self: *Blk = @ptrCast(@alignCast(ctx));
        self.accepted_features = accepted_features;
        if (self.options.stats) |stats| {
            stats.accepted_features.store(accepted_features, .monotonic);
        }
    }

    fn configRead(ctx: *anyopaque, offset: u64) u32 {
        const self: *Blk = @ptrCast(@alignCast(ctx));
        // Config space starts with capacity in sectors as u64 LE.
        return switch (offset) {
            0 => @truncate(self.capacity_sectors),
            4 => @truncate(self.capacity_sectors >> 32),
            48 => if (self.options.write_zeroes) max_write_zeroes_sectors else 0,
            52 => if (self.options.write_zeroes) 1 else 0,
            56 => if (self.options.write_zeroes) 1 else 0,
            else => 0,
        };
    }

    fn notify(ctx: *anyopaque, queue_index: u8, queues: *[mmio.max_queues]queue.VirtQueue, ram: guestmem.GuestRam) bool {
        const self: *Blk = @ptrCast(@alignCast(ctx));
        if (queue_index != 0) return false;
        const q = &queues[0];

        var did_work = false;
        var budget: queue.NotifyBudget = .{};
        while (budget.hasRemaining()) {
            const maybe_chain = q.popAvail(ram) catch return did_work;
            const chain = maybe_chain orelse break;
            budget.consume();
            const written = self.handleRequest(&chain);
            chain.markWritableDirty(ram);
            q.pushUsed(ram, chain.head, written) catch return did_work;
            did_work = true;
        }
        return did_work;
    }

    /// Execute one request chain; returns bytes written into writable
    /// segments (including the status byte).
    fn handleRequest(self: *Blk, chain: *const queue.Chain) u32 {
        const segs = chain.segments.slice();
        // Canonical framing: readable 16-byte header first, writable 1-byte
        // status last. Anything else is malformed; we still try to set the
        // status byte if one exists.
        if (segs.len < 2) return 0;
        const header = segs[0];
        const status = segs[segs.len - 1];
        if (header.writable or header.data.len < 16) return failStatus(status);
        if (!status.writable or status.data.len < 1) return 0;

        const req_type = std.mem.readInt(u32, header.data[0..4], .little);
        const sector = std.mem.readInt(u64, header.data[8..16], .little);
        const data = segs[1 .. segs.len - 1];

        switch (req_type) {
            req_in, req_out => {
                const want_writable = req_type == req_in;
                if (!want_writable and self.options.read_only) return failStatus(status);
                const capacity_bytes = self.capacity_sectors * sector_size;
                const request_offset = std.math.mul(u64, sector, sector_size) catch return failStatus(status);
                var offset = request_offset;
                var moved: u32 = 0;
                // Validate the complete descriptor set before any payload
                // buffer or backend disk bytes are changed.
                for (data) |seg| {
                    if (seg.writable != want_writable) return failStatus(status);
                    if (seg.data.len % sector_size != 0) return failStatus(status);
                    const seg_len = std.math.cast(u64, seg.data.len) orelse return failStatus(status);
                    const end = std.math.add(u64, offset, seg_len) catch return failStatus(status);
                    if (end > capacity_bytes) return failStatus(status);
                    offset = end;
                    if (want_writable) {
                        const written = std.math.cast(u32, seg.data.len) orelse return failStatus(status);
                        if (written > std.math.maxInt(u32) - 1 - moved) return failStatus(status);
                        moved += written;
                    }
                }

                if (!want_writable) {
                    if (self.options.stats) |stats| {
                        const total_len = offset - request_offset;
                        _ = stats.out_requests.fetchAdd(1, .monotonic);
                        _ = stats.out_bytes.fetchAdd(total_len, .monotonic);
                        var all_zero = total_len != 0;
                        for (data) |seg| {
                            if (!std.mem.allEqual(u8, seg.data, 0)) {
                                all_zero = false;
                                break;
                            }
                        }
                        if (all_zero) {
                            _ = stats.out_all_zero_requests.fetchAdd(1, .monotonic);
                            _ = stats.out_all_zero_bytes.fetchAdd(total_len, .monotonic);
                        }
                    }
                }

                if (want_writable) {
                    const total_len = std.math.cast(usize, offset - request_offset) orelse return failStatus(status);
                    // Each readAt prefaults its own slice for direct callers;
                    // this request-wide pass is still required so a later
                    // descriptor cannot fail after an earlier one was copied.
                    if (!self.backend.prefaultCasRange(total_len, request_offset)) return failStatus(status);
                }

                offset = request_offset;
                for (data, 0..) |seg, segment_index| {
                    const injected_out_failure = if (builtin.is_test)
                        !want_writable and self.options.test_fail_out_after_segments == segment_index
                    else
                        false;
                    const ok = if (injected_out_failure)
                        false
                    else if (want_writable)
                        self.backend.readAt(seg.data, offset)
                    else
                        self.backend.writeAt(seg.data, offset);
                    if (!ok) {
                        // The full guest request has already passed validation.
                        // An ordinary write can fail after an earlier descriptor
                        // or a short host write changed bytes, so its head can no
                        // longer be published safely.
                        if (!want_writable) self.backend.poisonValidatedMutationFailure();
                        return failStatus(status);
                    }
                    offset += seg.data.len;
                }
                return okStatus(status, moved);
            },
            req_flush => {
                if (!self.backend.flush()) return failStatus(status);
                status.data[0] = status_ok;
                return 1;
            },
            req_get_id => {
                var moved: u32 = 0;
                const id = "sporevm-blk0";
                for (data) |seg| {
                    if (!seg.writable) return failStatus(status);
                    const written = std.math.cast(u32, seg.data.len) orelse return failStatus(status);
                    if (written > std.math.maxInt(u32) - 1 - moved) return failStatus(status);
                    moved += written;
                    @memset(seg.data, 0);
                    const n = @min(seg.data.len, id.len);
                    @memcpy(seg.data[0..n], id[0..n]);
                }
                return okStatus(status, moved);
            },
            req_write_zeroes => return self.handleWriteZeroes(segs, header, status),
            else => {
                status.data[0] = status_unsupp;
                return 1;
            },
        }
    }

    fn handleWriteZeroes(self: *Blk, segs: []const queue.Segment, header: queue.Segment, status: queue.Segment) u32 {
        var request_number: u64 = 0;
        if (self.options.stats) |stats| {
            request_number = stats.write_zeroes_requests.fetchAdd(1, .monotonic) + 1;
        }

        if (!self.options.write_zeroes or self.accepted_features & feature_write_zeroes == 0) {
            if (self.options.stats) |stats| {
                _ = stats.write_zeroes_unsupported.fetchAdd(1, .monotonic);
            }
            return unsupportedStatus(status);
        }

        // Linux emits one range per request. Keeping this profile to exactly
        // one canonical range bounds validation and ensures no earlier range
        // can mutate the backend before a later range fails.
        if (segs.len != 3 or header.data.len != 16 or status.data.len != 1) {
            self.logWriteZeroesReject("shape", @intCast(segs.len), @intCast(header.data.len), @intCast(status.data.len));
            return self.writeZeroesError(status);
        }
        // Linux retains the historical `ioprio` interpretation of bytes 4..8
        // even for modern virtio. Treat it as a bounded ignored hint; the
        // command-level sector field itself is unused and must be zero.
        if (!std.mem.allEqual(u8, header.data[8..16], 0)) {
            self.logWriteZeroesReject("header-sector", @intCast(segs.len), @intCast(header.data.len), @intCast(status.data.len));
            return self.writeZeroesError(status);
        }

        const range = segs[1];
        if (range.writable or range.data.len != 16) {
            self.logWriteZeroesReject("range-shape", @intCast(segs.len), @intCast(range.data.len), @intFromBool(range.writable));
            return self.writeZeroesError(status);
        }
        const range_sector = std.mem.readInt(u64, range.data[0..8], .little);
        const num_sectors = std.mem.readInt(u32, range.data[8..12], .little);
        const flags = std.mem.readInt(u32, range.data[12..16], .little);
        if (request_number == 1) {
            std.log.debug(
                "virtio-blk WRITE_ZEROES observed: ioprio={d} header_sector={d} range_sector={d} num_sectors={d} flags=0x{x}",
                .{
                    std.mem.readInt(u32, header.data[4..8], .little),
                    std.mem.readInt(u64, header.data[8..16], .little),
                    range_sector,
                    num_sectors,
                    flags,
                },
            );
        }
        if (num_sectors == 0 or num_sectors > max_write_zeroes_sectors) {
            self.logWriteZeroesReject("sector-count", num_sectors, max_write_zeroes_sectors, 0);
            return self.writeZeroesError(status);
        }
        if (flags & ~write_zeroes_flag_unmap != 0) {
            self.logWriteZeroesReject("flags", flags, write_zeroes_flag_unmap, 0);
            return self.writeZeroesError(status);
        }

        const offset = std.math.mul(u64, range_sector, sector_size) catch {
            self.logWriteZeroesReject("offset-overflow", range_sector, sector_size, 0);
            return self.writeZeroesError(status);
        };
        const len = std.math.mul(u64, num_sectors, sector_size) catch {
            self.logWriteZeroesReject("length-overflow", num_sectors, sector_size, 0);
            return self.writeZeroesError(status);
        };
        const end = std.math.add(u64, offset, len) catch {
            self.logWriteZeroesReject("end-overflow", offset, len, 0);
            return self.writeZeroesError(status);
        };
        const capacity_bytes = std.math.mul(u64, self.capacity_sectors, sector_size) catch {
            self.logWriteZeroesReject("capacity-overflow", self.capacity_sectors, sector_size, 0);
            return self.writeZeroesError(status);
        };
        if (end > capacity_bytes or !self.backend.canZeroRange()) {
            self.logWriteZeroesReject("range", end, capacity_bytes, @intFromBool(self.backend.canZeroRange()));
            return self.writeZeroesError(status);
        }

        if (self.options.stats) |stats| {
            _ = stats.write_zeroes_bytes.fetchAdd(len, .monotonic);
            if (flags & write_zeroes_flag_unmap != 0) {
                _ = stats.write_zeroes_unmap_requests.fetchAdd(1, .monotonic);
            }
        }
        if (self.options.force_write_zeroes_unsupported) {
            if (self.options.stats) |stats| {
                _ = stats.write_zeroes_unsupported.fetchAdd(1, .monotonic);
            }
            return unsupportedStatus(status);
        }
        if (self.options.force_write_zeroes_backend_failure) {
            self.backend.poisonValidatedMutationFailure();
            if (self.options.stats) |stats| {
                _ = stats.write_zeroes_backend_failures.fetchAdd(1, .release);
            }
            return self.writeZeroesError(status);
        }

        // All guest-controlled arithmetic, framing, flags, capacity, and
        // backend writability have been validated before this mutation.
        if (!self.backend.zeroRange(offset, len)) {
            if (self.options.stats) |stats| {
                _ = stats.write_zeroes_backend_failures.fetchAdd(1, .release);
            }
            return self.writeZeroesError(status);
        }
        if (self.options.stats) |stats| {
            _ = stats.write_zeroes_ok.fetchAdd(1, .monotonic);
        }
        status.data[0] = status_ok;
        return 1;
    }

    fn writeZeroesError(self: *Blk, status: queue.Segment) u32 {
        if (self.options.stats) |stats| {
            _ = stats.write_zeroes_errors.fetchAdd(1, .monotonic);
        }
        return failStatus(status);
    }

    fn logWriteZeroesReject(self: *Blk, reason: []const u8, a: u64, b: u64, c: u64) void {
        const stats = self.options.stats orelse return;
        if (stats.write_zeroes_errors.load(.monotonic) != 0) return;
        std.log.debug("virtio-blk WRITE_ZEROES rejected: reason={s} a={d} b={d} c={d}", .{ reason, a, b, c });
    }
};

fn okStatus(status: queue.Segment, moved: u32) u32 {
    const written = std.math.add(u32, moved, 1) catch return failStatus(status);
    status.data[0] = status_ok;
    return written;
}

fn failStatus(status: queue.Segment) u32 {
    if (status.writable and status.data.len >= 1) {
        status.data[0] = status_ioerr;
        return 1;
    }
    return 0;
}

fn unsupportedStatus(status: queue.Segment) u32 {
    if (status.writable and status.data.len >= 1) {
        status.data[0] = status_unsupp;
        return 1;
    }
    return 0;
}

// --- tests ------------------------------------------------------------------

fn makeChain(segs: []const queue.Segment) queue.Chain {
    var chain = queue.Chain{ .head = 0, .segments = .{} };
    for (segs) |s| chain.segments.append(s) catch unreachable;
    return chain;
}

fn setWriteZeroesRequest(header: []u8, range: []u8, sector: u64, num_sectors: u32, flags: u32) void {
    std.debug.assert(header.len == 16 and range.len == 16);
    @memset(header, 0);
    @memset(range, 0);
    std.mem.writeInt(u32, header[0..4], req_write_zeroes, .little);
    std.mem.writeInt(u64, range[0..8], sector, .little);
    std.mem.writeInt(u32, range[8..12], num_sectors, .little);
    std.mem.writeInt(u32, range[12..16], flags, .little);
}

fn acceptWriteZeroes(blk: *Blk) void {
    Blk.featuresAccepted(blk, feature_write_zeroes);
}

const TestNotifyResult = struct {
    did_work: bool,
    status: u8,
    used_idx: u16,
    used_head: u32,
    used_len: u32,
};

const TestBlkQueue = struct {
    buf: [4096]u8 = [_]u8{0} ** 4096,
    queues: [mmio.max_queues]queue.VirtQueue,

    const desc_base: u64 = 0;
    const avail_base: u64 = 0x400;
    const used_base: u64 = 0x800;
    const header_base: u64 = 0xc00;
    const data_base: u64 = 0xd00;
    const status_base: u64 = 0xf40;
    const desc_size: u64 = 16;
    const flag_next: u16 = 1;
    const flag_write: u16 = 2;

    fn init() TestBlkQueue {
        var queues = [_]queue.VirtQueue{.{}} ** mmio.max_queues;
        queues[0] = .{
            .size = 8,
            .ready = true,
            .desc_addr = desc_base,
            .avail_addr = avail_base,
            .used_addr = used_base,
        };
        return .{ .queues = queues };
    }

    fn ram(self: *TestBlkQueue) guestmem.GuestRam {
        return .{ .bytes = &self.buf, .base = 0 };
    }

    fn setDesc(self: *TestBlkQueue, i: u16, addr: u64, len: u32, flags: u16, next_desc: u16) void {
        const r = self.ram();
        const base = desc_base + desc_size * @as(u64, i);
        r.write(u64, base, addr) catch unreachable;
        r.write(u32, base + 8, len) catch unreachable;
        r.write(u16, base + 12, flags) catch unreachable;
        r.write(u16, base + 14, next_desc) catch unreachable;
    }

    fn pushAvail(self: *TestBlkQueue, head: u16) void {
        const r = self.ram();
        const idx = r.read(u16, avail_base + 2) catch unreachable;
        r.write(u16, avail_base + 4 + 2 * @as(u64, idx % self.queues[0].size), head) catch unreachable;
        r.write(u16, avail_base + 2, idx +% 1) catch unreachable;
    }

    fn submitRead(self: *TestBlkQueue, blk: *Blk, sector: u64, fill: u8, out: *[sector_size]u8) !TestNotifyResult {
        const header_start: usize = @intCast(header_base);
        const data_start: usize = @intCast(data_base);
        const status_start: usize = @intCast(status_base);
        @memset(self.buf[header_start..][0..16], 0);
        @memset(self.buf[data_start..][0..sector_size], fill);
        self.buf[status_start] = 0xff;

        const r = self.ram();
        try r.write(u32, header_base, req_in);
        try r.write(u64, header_base + 8, sector);
        self.setDesc(0, header_base, 16, flag_next, 1);
        self.setDesc(1, data_base, sector_size, flag_next | flag_write, 2);
        self.setDesc(2, status_base, 1, flag_write, 0);

        const used_slot = self.queues[0].used_idx % self.queues[0].size;
        self.pushAvail(0);
        const did_work = Blk.notify(blk, 0, &self.queues, self.ram());
        @memcpy(out, self.buf[data_start..][0..sector_size]);
        const used_elem = used_base + 4 + 8 * @as(u64, used_slot);
        return .{
            .did_work = did_work,
            .status = try r.read(u8, status_base),
            .used_idx = try r.read(u16, used_base + 2),
            .used_head = try r.read(u32, used_elem),
            .used_len = try r.read(u32, used_elem + 4),
        };
    }
};

test "write zeroes feature and config are opt in and negotiation is resettable" {
    var disk = [_]u8{0} ** (8 * sector_size);
    var ordinary = Blk.init(.{ .memory = &disk });
    const ordinary_device = ordinary.device();
    try std.testing.expectEqual(@as(u64, 0), ordinary_device.device_features & feature_write_zeroes);
    try std.testing.expectEqual(@as(u32, 0), Blk.configRead(&ordinary, 48));
    try std.testing.expectEqual(@as(u32, 0), Blk.configRead(&ordinary, 52));
    try std.testing.expectEqual(@as(u32, 0), Blk.configRead(&ordinary, 56));

    var stats: Stats = .{};
    var growth = Blk.initWithOptions(.{ .memory = &disk }, .{ .write_zeroes = true, .stats = &stats });
    var transport = mmio.Transport.init(growth.device());
    try std.testing.expectEqual(feature_write_zeroes, transport.dev.device_features & feature_write_zeroes);
    try std.testing.expectEqual(max_write_zeroes_sectors, Blk.configRead(&growth, 48));
    try std.testing.expectEqual(@as(u32, 1), Blk.configRead(&growth, 52));
    try std.testing.expectEqual(@as(u32, 1), Blk.configRead(&growth, 56));

    var ram_bytes: [1]u8 = .{0};
    const ram: guestmem.GuestRam = .{ .bytes = &ram_bytes, .base = 0 };
    _ = transport.write(0x020, @truncate(feature_write_zeroes), ram);
    _ = transport.write(0x070, mmio.status_features_ok, ram);
    try std.testing.expectEqual(feature_write_zeroes, growth.accepted_features & feature_write_zeroes);
    try std.testing.expectEqual(feature_write_zeroes, stats.snapshot().accepted_features & feature_write_zeroes);

    _ = transport.write(0x070, 0, ram);
    try std.testing.expectEqual(@as(u64, 0), growth.accepted_features);
    try std.testing.expectEqual(@as(u64, 0), stats.snapshot().accepted_features);
}

test "immutable build input rejects WRITE_ZEROES negotiation without mutation" {
    var disk = [_]u8{0x5a} ** (4 * sector_size);
    var source = Blk.initImmutableSource(.{ .memory = &disk });
    var transport = mmio.Transport.init(source.device());
    try std.testing.expectEqual(@as(u64, 0), transport.dev.device_features & feature_write_zeroes);

    var ram_bytes: [1]u8 = .{0};
    const ram: guestmem.GuestRam = .{ .bytes = &ram_bytes, .base = 0 };
    _ = transport.write(0x020, @truncate(feature_write_zeroes), ram);
    _ = transport.write(0x070, mmio.status_features_ok, ram);
    try std.testing.expectEqual(@as(u32, 0), transport.read(0x070) & mmio.status_features_ok);
    try std.testing.expectEqual(@as(u64, 0), source.accepted_features);
    try std.testing.expect(std.mem.allEqual(u8, &disk, 0x5a));
}

test "immutable memory source rejects ordinary OUT without mutation" {
    var disk = [_]u8{0x5a} ** (2 * sector_size);
    var source = Blk.initImmutableSource(.{ .memory = &disk });
    var header = [_]u8{0} ** 16;
    std.mem.writeInt(u32, header[0..4], req_out, .little);
    std.mem.writeInt(u64, header[8..16], 0, .little);
    var attempted = [_]u8{0xa5} ** sector_size;
    var status: [1]u8 = .{0xff};
    const chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &attempted, .writable = false },
        .{ .data = &status, .writable = true },
    });
    try std.testing.expectEqual(@as(u32, 1), source.handleRequest(&chain));
    try std.testing.expectEqual(status_ioerr, status[0]);
    try std.testing.expect(std.mem.allEqual(u8, &disk, 0x5a));
}

test "immutable build input rejects ordinary OUT on a product-style read-only fd" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-virtio-blk-immutable-source-fd";
    const path = tmp ++ "/source.img";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    const canonical = [_]u8{0x5a} ** (2 * sector_size);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &canonical });
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);

    var source = Blk.initImmutableSource(.{ .file = fd });
    var header = [_]u8{0} ** 16;
    std.mem.writeInt(u32, header[0..4], req_out, .little);
    std.mem.writeInt(u64, header[8..16], 0, .little);
    var attempted = [_]u8{0xa5} ** sector_size;
    var status: [1]u8 = .{0xff};
    const chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &attempted, .writable = false },
        .{ .data = &status, .writable = true },
    });
    try std.testing.expectEqual(@as(u32, 1), source.handleRequest(&chain));
    try std.testing.expectEqual(status_ioerr, status[0]);
    const actual = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(canonical.len + 1));
    defer allocator.free(actual);
    try std.testing.expectEqualSlices(u8, &canonical, actual);
}

test "write zeroes requires negotiated feature without mutating memory" {
    var disk = [_]u8{0x5a} ** (4 * sector_size);
    var stats: Stats = .{};
    var blk = Blk.initWithOptions(.{ .memory = &disk }, .{ .write_zeroes = true, .stats = &stats });

    var header: [16]u8 = undefined;
    var range: [16]u8 = undefined;
    setWriteZeroesRequest(&header, &range, 1, 1, write_zeroes_flag_unmap);
    var status: [1]u8 = .{0xff};
    const chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &range, .writable = false },
        .{ .data = &status, .writable = true },
    });

    try std.testing.expectEqual(@as(u32, 1), blk.handleRequest(&chain));
    try std.testing.expectEqual(status_unsupp, status[0]);
    try std.testing.expect(std.mem.allEqual(u8, &disk, 0x5a));
    const snapshot = stats.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.write_zeroes_requests);
    try std.testing.expectEqual(@as(u64, 1), snapshot.write_zeroes_unsupported);
    try std.testing.expectEqual(@as(u64, 0), snapshot.write_zeroes_errors);
    try std.testing.expectEqual(@as(u64, 0), snapshot.write_zeroes_bytes);
}

test "write zeroes handles bounded memory ranges and records stats" {
    var disk = [_]u8{0x5a} ** (6 * sector_size);
    var stats: Stats = .{};
    var blk = Blk.initWithOptions(.{ .memory = &disk }, .{ .write_zeroes = true, .stats = &stats });
    acceptWriteZeroes(&blk);

    var header: [16]u8 = undefined;
    var range: [16]u8 = undefined;
    var status: [1]u8 = .{0xff};
    setWriteZeroesRequest(&header, &range, 1, 1, 0);
    std.mem.writeInt(u32, header[4..8], 7, .little); // historical Linux ioprio hint
    var chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &range, .writable = false },
        .{ .data = &status, .writable = true },
    });
    try std.testing.expectEqual(@as(u32, 1), blk.handleRequest(&chain));
    try std.testing.expectEqual(status_ok, status[0]);
    try std.testing.expect(std.mem.allEqual(u8, disk[0..sector_size], 0x5a));
    try std.testing.expect(std.mem.allEqual(u8, disk[sector_size .. 2 * sector_size], 0));
    try std.testing.expect(std.mem.allEqual(u8, disk[2 * sector_size ..], 0x5a));

    status[0] = 0xff;
    setWriteZeroesRequest(&header, &range, 4, 2, write_zeroes_flag_unmap);
    chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &range, .writable = false },
        .{ .data = &status, .writable = true },
    });
    try std.testing.expectEqual(@as(u32, 1), blk.handleRequest(&chain));
    try std.testing.expectEqual(status_ok, status[0]);
    try std.testing.expect(std.mem.allEqual(u8, disk[3 * sector_size .. 4 * sector_size], 0x5a));
    try std.testing.expect(std.mem.allEqual(u8, disk[4 * sector_size ..], 0));

    const snapshot = stats.snapshot();
    try std.testing.expectEqual(@as(u64, 2), snapshot.write_zeroes_requests);
    try std.testing.expectEqual(@as(u64, 3 * sector_size), snapshot.write_zeroes_bytes);
    try std.testing.expectEqual(@as(u64, 1), snapshot.write_zeroes_unmap_requests);
    try std.testing.expectEqual(@as(u64, 2), snapshot.write_zeroes_ok);
    try std.testing.expectEqual(@as(u64, 0), snapshot.write_zeroes_errors);
}

test "forced unsupported write zeroes is a non-mutating fallback control" {
    var disk = [_]u8{0x5a} ** (4 * sector_size);
    var stats: Stats = .{};
    var blk = Blk.initWithOptions(.{ .memory = &disk }, .{
        .write_zeroes = true,
        .force_write_zeroes_unsupported = true,
        .stats = &stats,
    });
    acceptWriteZeroes(&blk);

    var header: [16]u8 = undefined;
    var range: [16]u8 = undefined;
    setWriteZeroesRequest(&header, &range, 1, 1, write_zeroes_flag_unmap);
    var status: [1]u8 = .{0xff};
    const chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &range, .writable = false },
        .{ .data = &status, .writable = true },
    });

    try std.testing.expectEqual(@as(u32, 1), blk.handleRequest(&chain));
    try std.testing.expectEqual(status_unsupp, status[0]);
    try std.testing.expect(std.mem.allEqual(u8, &disk, 0x5a));
    const snapshot = stats.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.write_zeroes_requests);
    try std.testing.expectEqual(@as(u64, sector_size), snapshot.write_zeroes_bytes);
    try std.testing.expectEqual(@as(u64, 1), snapshot.write_zeroes_unmap_requests);
    try std.testing.expectEqual(@as(u64, 1), snapshot.write_zeroes_unsupported);
    try std.testing.expectEqual(@as(u64, 0), snapshot.write_zeroes_errors);
    try std.testing.expectEqual(@as(u64, 0), snapshot.write_zeroes_ok);
}

test "forced backend failure is distinguished from structural rejection" {
    var disk = [_]u8{0x5a} ** (2 * sector_size);
    var stats: Stats = .{};
    var blk = Blk.initWithOptions(.{ .memory = &disk }, .{
        .write_zeroes = true,
        .force_write_zeroes_backend_failure = true,
        .stats = &stats,
    });
    acceptWriteZeroes(&blk);

    var header: [16]u8 = undefined;
    var range: [16]u8 = undefined;
    setWriteZeroesRequest(&header, &range, 0, 1, write_zeroes_flag_unmap);
    var status: [1]u8 = .{0xff};
    const chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &range, .writable = false },
        .{ .data = &status, .writable = true },
    });
    try std.testing.expectEqual(@as(u32, 1), blk.handleRequest(&chain));
    try std.testing.expectEqual(status_ioerr, status[0]);
    try std.testing.expect(std.mem.allEqual(u8, &disk, 0x5a));
    const snapshot = stats.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.write_zeroes_backend_failures);
    try std.testing.expectEqual(@as(u64, 1), snapshot.write_zeroes_errors);
    try std.testing.expectEqual(@as(u64, 0), snapshot.write_zeroes_ok);
}

test "OUT telemetry detects block-layer all-zero fallback only when enabled" {
    var disk = [_]u8{0x11} ** (2 * sector_size);
    var stats: Stats = .{};
    var blk = Blk.initWithOptions(.{ .memory = &disk }, .{ .stats = &stats });
    var header: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u32, header[0..4], req_out, .little);
    var zero_data: [sector_size]u8 = [_]u8{0} ** sector_size;
    var status: [1]u8 = .{0xff};
    var chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &zero_data, .writable = false },
        .{ .data = &status, .writable = true },
    });
    _ = blk.handleRequest(&chain);
    try std.testing.expectEqual(status_ok, status[0]);

    std.mem.writeInt(u64, header[8..16], 1, .little);
    var nonzero_data: [sector_size]u8 = [_]u8{0x22} ** sector_size;
    status[0] = 0xff;
    chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &nonzero_data, .writable = false },
        .{ .data = &status, .writable = true },
    });
    _ = blk.handleRequest(&chain);
    try std.testing.expectEqual(status_ok, status[0]);

    const snapshot = stats.snapshot();
    try std.testing.expectEqual(@as(u64, 2), snapshot.out_requests);
    try std.testing.expectEqual(@as(u64, 2 * sector_size), snapshot.out_bytes);
    try std.testing.expectEqual(@as(u64, 1), snapshot.out_all_zero_requests);
    try std.testing.expectEqual(@as(u64, sector_size), snapshot.out_all_zero_bytes);
}

test "malformed write zeroes requests fail before changing memory" {
    const Malformation = enum {
        extra_segment,
        short_header,
        writable_range,
        short_range,
        long_status,
        header_sector,
        zero_sectors,
        excessive_sectors,
        unknown_flags,
        overflowing_sector,
        out_of_range,
    };
    const cases = [_]Malformation{
        .extra_segment,
        .short_header,
        .writable_range,
        .short_range,
        .long_status,
        .header_sector,
        .zero_sectors,
        .excessive_sectors,
        .unknown_flags,
        .overflowing_sector,
        .out_of_range,
    };

    for (cases) |malformation| {
        var disk = [_]u8{0x5a} ** (4 * sector_size);
        var blk = Blk.initWithOptions(.{ .memory = &disk }, .{ .write_zeroes = true });
        acceptWriteZeroes(&blk);
        var header_buf: [17]u8 = [_]u8{0} ** 17;
        var range_buf: [16]u8 = [_]u8{0} ** 16;
        var status_buf: [2]u8 = .{ 0xff, 0xff };
        var extra: [1]u8 = .{0};
        var header: []u8 = header_buf[0..16];
        var range: []u8 = &range_buf;
        var status: []u8 = status_buf[0..1];
        var range_writable = false;
        setWriteZeroesRequest(header_buf[0..16], &range_buf, 1, 1, 0);

        switch (malformation) {
            .extra_segment => {},
            .short_header => header = header_buf[0..15],
            .writable_range => range_writable = true,
            .short_range => range = range_buf[0..15],
            .long_status => status = &status_buf,
            .header_sector => std.mem.writeInt(u64, header_buf[8..16], 1, .little),
            .zero_sectors => std.mem.writeInt(u32, range_buf[8..12], 0, .little),
            .excessive_sectors => std.mem.writeInt(u32, range_buf[8..12], max_write_zeroes_sectors + 1, .little),
            .unknown_flags => std.mem.writeInt(u32, range_buf[12..16], 0x2, .little),
            .overflowing_sector => std.mem.writeInt(u64, range_buf[0..8], std.math.maxInt(u64), .little),
            .out_of_range => std.mem.writeInt(u64, range_buf[0..8], 4, .little),
        }

        var chain = queue.Chain{ .head = 0, .segments = .{} };
        try chain.segments.append(.{ .data = header, .writable = false });
        try chain.segments.append(.{ .data = range, .writable = range_writable });
        if (malformation == .extra_segment) {
            try chain.segments.append(.{ .data = &extra, .writable = false });
        }
        try chain.segments.append(.{ .data = status, .writable = true });

        try std.testing.expectEqual(@as(u32, 1), blk.handleRequest(&chain));
        try std.testing.expectEqual(status_ioerr, status_buf[0]);
        try std.testing.expect(std.mem.allEqual(u8, &disk, 0x5a));
    }
}

test "write zeroes uses chunk mapped full and partial zero ranges" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "zero-base.img", .{ .read = true });
    defer base.close(io);
    var overlay = try tmp.dir.createFile(io, "zero-overlay.img", .{ .read = true });
    defer overlay.close(io);
    var base_bytes = [_]u8{0x7b} ** (4 * sector_size);
    try base.writeStreamingAll(io, &base_bytes);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try chunk_mapped_disk.ChunkMappedDisk.initWritable(
        std.testing.allocator,
        base_source,
        overlay.handle,
        base_bytes.len,
        2 * sector_size,
    );
    defer disk.deinit();
    var stats = Stats{};
    var blk = Blk.initWithOptions(.{ .chunk_mapped = &disk }, .{ .write_zeroes = true, .stats = &stats });
    acceptWriteZeroes(&blk);

    var header: [16]u8 = undefined;
    var range: [16]u8 = undefined;
    var status: [1]u8 = .{0xff};
    setWriteZeroesRequest(&header, &range, 1, 1, write_zeroes_flag_unmap);
    var chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &range, .writable = false },
        .{ .data = &status, .writable = true },
    });
    _ = blk.handleRequest(&chain);
    try std.testing.expectEqual(status_ok, status[0]);

    status[0] = 0xff;
    setWriteZeroesRequest(&header, &range, 2, 2, write_zeroes_flag_unmap);
    chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &range, .writable = false },
        .{ .data = &status, .writable = true },
    });
    _ = blk.handleRequest(&chain);
    try std.testing.expectEqual(status_ok, status[0]);

    var visible: [4 * sector_size]u8 = undefined;
    try disk.readAt(&visible, 0);
    try std.testing.expect(std.mem.allEqual(u8, visible[0..sector_size], 0x7b));
    try std.testing.expect(std.mem.allEqual(u8, visible[sector_size..], 0));
    try std.testing.expectEqual(@as(usize, 2), disk.dirtyClusterCount());

    var unchanged_base: [4 * sector_size]u8 = undefined;
    const read = try base.readPositionalAll(io, &unchanged_base, 0);
    try std.testing.expectEqual(unchanged_base.len, read);
    try std.testing.expectEqualSlices(u8, &base_bytes, &unchanged_base);
}

test "validated write zeroes backend failure poisons the mutable head" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "poison-base.img", .{ .read = true });
    defer base.close(io);
    var overlay = try tmp.dir.createFile(io, "poison-overlay.img", .{ .read = true });
    const overlay_fd = overlay.handle;
    const base_bytes = [_]u8{0x7b} ** (2 * sector_size);
    try base.writeStreamingAll(io, &base_bytes);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try chunk_mapped_disk.ChunkMappedDisk.initWritable(
        std.testing.allocator,
        base_source,
        overlay_fd,
        base_bytes.len,
        2 * sector_size,
    );
    defer disk.deinit();
    var stats = Stats{};
    var blk = Blk.initWithOptions(.{ .chunk_mapped = &disk }, .{ .write_zeroes = true, .stats = &stats });
    acceptWriteZeroes(&blk);

    // Keep the logical writable profile while forcing the validated backend
    // mutation to fail at pwrite. A partial chunk is required because a full
    // chunk can be represented as zero metadata without touching the fd.
    overlay.close(io);

    var header: [16]u8 = undefined;
    var range: [16]u8 = undefined;
    var status: [1]u8 = .{0xff};
    setWriteZeroesRequest(&header, &range, 0, 1, write_zeroes_flag_unmap);
    const chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &range, .writable = false },
        .{ .data = &status, .writable = true },
    });
    try std.testing.expectEqual(@as(u32, 1), blk.handleRequest(&chain));
    try std.testing.expectEqual(status_ioerr, status[0]);
    try std.testing.expect(disk.isPoisoned());
    const stats_snapshot = stats.snapshot();
    try std.testing.expectEqual(@as(u64, 1), stats_snapshot.write_zeroes_backend_failures);
    try std.testing.expectEqual(@as(u64, 1), stats_snapshot.write_zeroes_errors);
    try std.testing.expectError(
        error.Poisoned,
        disk.snapshotIndex("unused-poisoned-snapshot", .{ .mmio_slot = 1 }, true),
    );
    try std.testing.expectError(error.Poisoned, disk.fork(.{ .quiesced = true }));
}

test "validated ordinary write failure poisons a partially mutated head" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_bytes = [_]u8{0x7b} ** (2 * sector_size);
    var base = try tmp.dir.createFile(io, "out-poison-base.img", .{ .read = true });
    defer base.close(io);
    try base.writeStreamingAll(io, &base_bytes);
    var overlay = try tmp.dir.createFile(io, "out-poison-overlay.img", .{ .read = true });
    defer overlay.close(io);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try chunk_mapped_disk.ChunkMappedDisk.initWritable(
        std.testing.allocator,
        base_source,
        overlay.handle,
        base_bytes.len,
        sector_size,
    );
    defer disk.deinit();
    var blk = Blk.initWithOptions(.{ .chunk_mapped = &disk }, .{
        .test_fail_out_after_segments = 1,
    });

    var header: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u32, header[0..4], req_out, .little);
    var first = [_]u8{0xa1} ** sector_size;
    var second = [_]u8{0xb2} ** sector_size;
    var status: [1]u8 = .{0xff};
    const chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &first, .writable = false },
        .{ .data = &second, .writable = false },
        .{ .data = &status, .writable = true },
    });

    try std.testing.expectEqual(@as(u32, 1), blk.handleRequest(&chain));
    try std.testing.expectEqual(status_ioerr, status[0]);
    try std.testing.expect(disk.isPoisoned());

    var visible: [2 * sector_size]u8 = undefined;
    try disk.readAt(&visible, 0);
    try std.testing.expectEqualSlices(u8, &first, visible[0..sector_size]);
    try std.testing.expectEqualSlices(u8, base_bytes[sector_size..], visible[sector_size..]);

    try std.testing.expectError(
        error.Poisoned,
        disk.snapshotIndex("unused-out-poisoned-snapshot", .{ .mmio_slot = 1 }, true),
    );
    try std.testing.expectError(error.Poisoned, disk.fork(.{ .quiesced = true }));
    try std.testing.expectError(
        error.Poisoned,
        disk.exportForkHead(
            .{
                .kind = .rootfs,
                .identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            },
            .{ .quiesced = true },
        ),
    );
}

test "read request returns sector data" {
    var disk = [_]u8{0} ** (4 * sector_size);
    disk[sector_size] = 0xAB; // first byte of sector 1
    var blk = Blk.init(.{ .memory = &disk });

    var header: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u32, header[0..4], req_in, .little);
    std.mem.writeInt(u64, header[8..16], 1, .little);
    var data: [sector_size]u8 = undefined;
    var status: [1]u8 = .{0xff};

    const chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &data, .writable = true },
        .{ .data = &status, .writable = true },
    });
    const written = blk.handleRequest(&chain);
    try std.testing.expectEqual(@as(u32, sector_size + 1), written);
    try std.testing.expectEqual(status_ok, status[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), data[0]);
}

test "read request validates every descriptor before changing guest buffers" {
    var disk = [_]u8{0x5a} ** (2 * sector_size);
    var blk = Blk.init(.{ .memory = &disk });

    var header: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u32, header[0..4], req_in, .little);
    var first: [sector_size]u8 = [_]u8{0xaa} ** sector_size;
    var malformed: [1]u8 = .{0xaa};
    var status: [1]u8 = .{0xff};

    const chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &first, .writable = true },
        .{ .data = &malformed, .writable = true },
        .{ .data = &status, .writable = true },
    });
    const written = blk.handleRequest(&chain);
    try std.testing.expectEqual(@as(u32, 1), written);
    try std.testing.expectEqual(status_ioerr, status[0]);
    try std.testing.expect(std.mem.allEqual(u8, &first, 0xaa));
    try std.testing.expectEqual(@as(u8, 0xaa), malformed[0]);
}

test "write request validates every descriptor before changing backend bytes" {
    var disk = [_]u8{0x11} ** (2 * sector_size);
    var blk = Blk.init(.{ .memory = &disk });

    var header: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u32, header[0..4], req_out, .little);
    var first: [sector_size]u8 = [_]u8{0x5a} ** sector_size;
    var malformed: [1]u8 = .{0x5a};
    var status: [1]u8 = .{0xff};

    const chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &first, .writable = false },
        .{ .data = &malformed, .writable = false },
        .{ .data = &status, .writable = true },
    });
    const written = blk.handleRequest(&chain);
    try std.testing.expectEqual(@as(u32, 1), written);
    try std.testing.expectEqual(status_ioerr, status[0]);
    try std.testing.expect(std.mem.allEqual(u8, &disk, 0x11));
}

test "write request persists and out-of-range is io error" {
    var disk = [_]u8{0} ** (2 * sector_size);
    var blk = Blk.init(.{ .memory = &disk });

    var header: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u32, header[0..4], req_out, .little);
    std.mem.writeInt(u64, header[8..16], 0, .little);
    var data: [sector_size]u8 = [_]u8{0x5A} ** sector_size;
    var status: [1]u8 = .{0xff};

    var chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &data, .writable = false },
        .{ .data = &status, .writable = true },
    });
    _ = blk.handleRequest(&chain);
    try std.testing.expectEqual(status_ok, status[0]);
    try std.testing.expectEqual(@as(u8, 0x5A), disk[0]);

    // Sector beyond capacity.
    std.mem.writeInt(u64, header[8..16], 99, .little);
    chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &data, .writable = false },
        .{ .data = &status, .writable = true },
    });
    _ = blk.handleRequest(&chain);
    try std.testing.expectEqual(status_ioerr, status[0]);
}

test "chunk mapped backend serves dirty writes without mutating base" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);

    var base_bytes = [_]u8{0x11} ** (2 * sector_size);
    try base.writeStreamingAll(io, &base_bytes);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try chunk_mapped_disk.ChunkMappedDisk.initWritable(std.testing.allocator, base_source, overlay.handle, base_bytes.len, sector_size);
    defer disk.deinit();
    var blk = Blk.init(.{ .chunk_mapped = &disk });

    var header: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u32, header[0..4], req_out, .little);
    std.mem.writeInt(u64, header[8..16], 1, .little);
    var write_data: [sector_size]u8 = [_]u8{0x5A} ** sector_size;
    var status: [1]u8 = .{0xff};

    var chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &write_data, .writable = false },
        .{ .data = &status, .writable = true },
    });
    _ = blk.handleRequest(&chain);
    try std.testing.expectEqual(status_ok, status[0]);

    var read_data: [sector_size]u8 = undefined;
    @memset(&read_data, 0);
    status[0] = 0xff;
    std.mem.writeInt(u32, header[0..4], req_in, .little);
    chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &read_data, .writable = true },
        .{ .data = &status, .writable = true },
    });
    const written = blk.handleRequest(&chain);
    try std.testing.expectEqual(@as(u32, sector_size + 1), written);
    try std.testing.expectEqual(status_ok, status[0]);
    try std.testing.expectEqualSlices(u8, &write_data, &read_data);
    try std.testing.expectEqual(@as(usize, 1), disk.dirtyClusterCount());

    var base_check: [sector_size]u8 = undefined;
    const read = try base.readPositionalAll(io, &base_check, sector_size);
    try std.testing.expectEqual(base_check.len, read);
    try std.testing.expectEqualSlices(u8, base_bytes[sector_size..], &base_check);
}

const LazyFaultKind = enum {
    missing,
    corrupt_same_size,
};

fn expectLazyFaultInFailureViaVirtio(kind: LazyFaultKind) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = switch (kind) {
        .missing => "zig-cache/test-blk-lazy-cas-missing-object",
        .corrupt_same_size => "zig-cache/test-blk-lazy-cas-corrupt-object",
    };
    const rootfs_path = try std.fmt.allocPrint(arena, "{s}/source.ext4", .{tmp});
    const cache_root = try std.fmt.allocPrint(arena, "{s}/cache", .{tmp});
    Io.Dir.cwd().deleteTree(io, tmp) catch {};
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    const rootfs_bytes = ("abcd" ** 16384) ++ ("efgh" ** 16384) ++ ("ijkl" ** 16384);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = rootfs_bytes });

    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const preload_result = try rootfs_cas.preload(io, arena, cache_root, artifact.digest, spore.disk_chunk_size);
    const storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload_result);
    const index_bytes = try Io.Dir.cwd().readFileAlloc(io, preload_result.index_path, arena, .limited(disk_index.max_index_bytes));
    var parsed = try disk_index.parseDiskIndex(arena, index_bytes, try spore.diskIndexDescriptorForStorage(storage));
    defer parsed.deinit();
    const bad_chunk: usize = switch (kind) {
        .missing => 1,
        .corrupt_same_size => 2,
    };
    const bad_object_path = try rootfs_cas.manifestObjectPath(arena, cache_root, parsed.value.chunks[bad_chunk].digest);

    var base = try disk_layer.createTempOverlay(arena);
    defer base.deinit();
    var overlay = try disk_layer.createTempOverlay(arena);
    defer overlay.deinit();
    const logical_size = std.math.cast(std.c.off_t, artifact.size) orelse return error.BadManifest;
    if (std.c.ftruncate(base.fd, logical_size) != 0) return error.IoFailed;

    const base_source = block_source.FileBlockSource.init(base.fd, artifact.size);
    var disk = try chunk_mapped_disk.ChunkMappedDisk.initWritable(allocator, base_source, overlay.fd, artifact.size, spore.disk_chunk_size);
    defer disk.deinit();
    try disk.attachCasIndex(cache_root, parsed.value);
    var blk = Blk.init(.{ .chunk_mapped = &disk });
    var ring = TestBlkQueue.init();

    var data: [sector_size]u8 = undefined;
    const promoted = try ring.submitRead(&blk, 0, 0x00, &data);
    try std.testing.expect(promoted.did_work);
    try std.testing.expectEqual(status_ok, promoted.status);
    try std.testing.expectEqual(@as(u16, 1), promoted.used_idx);
    try std.testing.expectEqual(@as(u32, 0), promoted.used_head);
    try std.testing.expectEqual(@as(u32, sector_size + 1), promoted.used_len);
    try std.testing.expectEqualStrings("abcd", data[0..4]);

    switch (kind) {
        .missing => try Io.Dir.cwd().deleteFile(io, bad_object_path),
        .corrupt_same_size => {
            try Io.Dir.cwd().deleteFile(io, bad_object_path);
            const corrupt = try arena.alloc(u8, @intCast(spore.disk_chunk_size));
            @memset(corrupt, 0xee);
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = bad_object_path, .data = corrupt });
        },
    }

    const bad_sector = @as(u64, @intCast(bad_chunk)) * (spore.disk_chunk_size / sector_size);
    const prefix_sector = @as(u64, @intCast(bad_chunk - 1)) * (spore.disk_chunk_size / sector_size);
    var header: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u32, header[0..4], req_in, .little);
    std.mem.writeInt(u64, header[8..16], prefix_sector, .little);
    var healthy_prefix: [spore.disk_chunk_size]u8 = [_]u8{0xaa} ** spore.disk_chunk_size;
    var failing_suffix: [spore.disk_chunk_size]u8 = [_]u8{0xaa} ** spore.disk_chunk_size;
    var status: [1]u8 = .{0xff};
    const multi_chunk = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &healthy_prefix, .writable = true },
        .{ .data = &failing_suffix, .writable = true },
        .{ .data = &status, .writable = true },
    });
    const multi_chunk_written = blk.handleRequest(&multi_chunk);
    try std.testing.expectEqual(@as(u32, 1), multi_chunk_written);
    try std.testing.expectEqual(status_ioerr, status[0]);
    try std.testing.expect(std.mem.allEqual(u8, &healthy_prefix, 0xaa));
    try std.testing.expect(std.mem.allEqual(u8, &failing_suffix, 0xaa));

    const failed = try ring.submitRead(&blk, bad_sector, 0xaa, &data);
    try std.testing.expect(failed.did_work);
    try std.testing.expectEqual(status_ioerr, failed.status);
    try std.testing.expectEqual(@as(u16, 2), failed.used_idx);
    try std.testing.expectEqual(@as(u32, 0), failed.used_head);
    try std.testing.expectEqual(@as(u32, 1), failed.used_len);
    try std.testing.expect(std.mem.allEqual(u8, &data, 0xaa));

    const recovered = try ring.submitRead(&blk, 0, 0x00, &data);
    try std.testing.expect(recovered.did_work);
    try std.testing.expectEqual(status_ok, recovered.status);
    try std.testing.expectEqual(@as(u16, 3), recovered.used_idx);
    try std.testing.expectEqual(@as(u32, 0), recovered.used_head);
    try std.testing.expectEqual(@as(u32, sector_size + 1), recovered.used_len);
    try std.testing.expectEqualStrings("abcd", data[0..4]);
}

test "lazy chunk mapped missing cas object completes virtio-blk request with ioerr" {
    try expectLazyFaultInFailureViaVirtio(.missing);
}

test "lazy chunk mapped corrupt cas object completes virtio-blk request with ioerr" {
    try expectLazyFaultInFailureViaVirtio(.corrupt_same_size);
}

test "flush request reports backend failure" {
    var blk = Blk{
        .backend = .{ .file = -1 },
        .capacity_sectors = 0,
    };

    var header: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u32, header[0..4], req_flush, .little);
    var status: [1]u8 = .{0xff};

    const chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &status, .writable = true },
    });
    const written = blk.handleRequest(&chain);
    try std.testing.expectEqual(@as(u32, 1), written);
    try std.testing.expectEqual(status_ioerr, status[0]);
}

test "malformed framing and unknown types are safe" {
    var disk = [_]u8{0} ** sector_size;
    var blk = Blk.init(.{ .memory = &disk });

    // Header too short.
    var short: [4]u8 = .{ 0, 0, 0, 0 };
    var status: [1]u8 = .{0xff};
    var chain = makeChain(&.{
        .{ .data = &short, .writable = false },
        .{ .data = &status, .writable = true },
    });
    _ = blk.handleRequest(&chain);
    try std.testing.expectEqual(status_ioerr, status[0]);

    // Unknown request type.
    var header: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u32, header[0..4], 0x77, .little);
    status[0] = 0xff;
    chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &status, .writable = true },
    });
    _ = blk.handleRequest(&chain);
    try std.testing.expectEqual(status_unsupp, status[0]);
}

test "huge sector fails closed" {
    var disk = [_]u8{0} ** sector_size;
    var blk = Blk.init(.{ .memory = &disk });

    var header: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u32, header[0..4], req_in, .little);
    std.mem.writeInt(u64, header[8..16], std.math.maxInt(u64), .little);
    var data: [sector_size]u8 = undefined;
    var status: [1]u8 = .{0xff};

    const chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = &data, .writable = true },
        .{ .data = &status, .writable = true },
    });
    _ = blk.handleRequest(&chain);
    try std.testing.expectEqual(status_ioerr, status[0]);
}

test "GET_ID rejects max u32 writable byte count" {
    var disk = [_]u8{0} ** sector_size;
    var blk = Blk.init(.{ .memory = &disk });

    var header: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u32, header[0..4], req_get_id, .little);
    var scratch: [1]u8 = .{0xaa};
    const huge_data = scratch[0..].ptr[0..std.math.maxInt(u32)];
    var status: [1]u8 = .{0xff};

    const chain = makeChain(&.{
        .{ .data = &header, .writable = false },
        .{ .data = huge_data, .writable = true },
        .{ .data = &status, .writable = true },
    });
    const written = blk.handleRequest(&chain);
    try std.testing.expectEqual(@as(u32, 1), written);
    try std.testing.expectEqual(status_ioerr, status[0]);
    try std.testing.expectEqual(@as(u8, 0xaa), scratch[0]);
}

fn fuzzBlkRequest(_: void, s: *std.testing.Smith) !void {
    // Request headers, segment writability, lengths, and data are guest
    // controlled. The block parser must fail closed rather than crash or walk
    // outside its backend.
    var disk = [_]u8{0} ** (4 * sector_size);
    var blk = Blk.initWithOptions(.{ .memory = &disk }, .{ .write_zeroes = true });
    acceptWriteZeroes(&blk);

    var seg_bufs: [6][1024]u8 = undefined;
    for (&seg_bufs) |*buf| {
        @memset(buf, 0);
        _ = s.slice(buf);
    }

    var chain = queue.Chain{ .head = 0, .segments = .{} };
    const segment_count: usize = @intCast(s.value(u8) % (seg_bufs.len + 1));
    var i: usize = 0;
    while (i < segment_count) : (i += 1) {
        const len: usize = @intCast(s.value(u16) % (seg_bufs[i].len + 1));
        chain.segments.append(.{
            .data = seg_bufs[i][0..len],
            .writable = (s.value(u8) & 1) != 0,
        }) catch unreachable;
    }

    // Exercise the new attacker-controlled range parser frequently instead
    // of relying on a random u32 to happen to equal request type 13.
    if (segment_count > 0 and chain.segments.slice()[0].data.len >= 4 and s.value(u8) & 1 != 0) {
        std.mem.writeInt(u32, chain.segments.slice()[0].data[0..4], req_write_zeroes, .little);
    }

    _ = blk.handleRequest(&chain);
}

test "fuzz block request handling" {
    try std.testing.fuzz({}, fuzzBlkRequest, .{});
}

fn fuzzWriteZeroesSemantics(_: void, s: *std.testing.Smith) !void {
    const disk_sectors = 16;
    var disk: [disk_sectors * sector_size]u8 = undefined;
    s.bytes(&disk);
    const before = disk;

    // Start from a canonical, in-range request so successful cases are common,
    // then inject exactly one independently known rejection condition.
    const range_sector: u64 = s.value(u8) % disk_sectors;
    const remaining: u32 = disk_sectors - @as(u32, @intCast(range_sector));
    const num_sectors: u32 = 1 + @as(u32, s.value(u8)) % remaining;
    var header_buf: [17]u8 = [_]u8{0} ** 17;
    var range_buf: [16]u8 = [_]u8{0} ** 16;
    var status_buf: [2]u8 = .{ 0xff, 0xff };
    var extra_buf: [1]u8 = .{0};
    setWriteZeroesRequest(header_buf[0..16], &range_buf, range_sector, num_sectors, s.value(u8) & write_zeroes_flag_unmap);

    const Fault = enum(u8) {
        none,
        unnegotiated,
        forced_unsupported,
        short_header,
        long_header,
        writable_header,
        random_ioprio,
        header_sector,
        short_range,
        writable_range,
        zero_sectors,
        excessive_sectors,
        unknown_flags,
        overflowing_sector,
        out_of_range,
        long_status,
        readonly_status,
        extra_segment,
    };
    const fault: Fault = @enumFromInt(s.value(u8) % (@intFromEnum(Fault.extra_segment) + 1));
    var header: []u8 = header_buf[0..16];
    var range: []u8 = &range_buf;
    var status: []u8 = status_buf[0..1];
    var header_writable = false;
    var range_writable = false;
    var status_writable = true;
    switch (fault) {
        .none, .unnegotiated, .forced_unsupported, .extra_segment => {},
        .short_header => header = header_buf[0..15],
        .long_header => header = &header_buf,
        .writable_header => header_writable = true,
        .random_ioprio => std.mem.writeInt(u32, header_buf[4..8], s.value(u32), .little),
        .header_sector => std.mem.writeInt(u64, header_buf[8..16], 1, .little),
        .short_range => range = range_buf[0..15],
        .writable_range => range_writable = true,
        .zero_sectors => std.mem.writeInt(u32, range_buf[8..12], 0, .little),
        .excessive_sectors => std.mem.writeInt(u32, range_buf[8..12], max_write_zeroes_sectors + 1, .little),
        .unknown_flags => std.mem.writeInt(u32, range_buf[12..16], 0x2, .little),
        .overflowing_sector => std.mem.writeInt(u64, range_buf[0..8], std.math.maxInt(u64), .little),
        .out_of_range => std.mem.writeInt(u64, range_buf[0..8], disk_sectors, .little),
        .long_status => status = &status_buf,
        .readonly_status => status_writable = false,
    }

    var blk = Blk.initWithOptions(.{ .memory = &disk }, .{
        .write_zeroes = true,
        .force_write_zeroes_unsupported = fault == .forced_unsupported,
    });
    if (fault != .unnegotiated) acceptWriteZeroes(&blk);
    var chain = queue.Chain{ .head = 0, .segments = .{} };
    chain.segments.append(.{ .data = header, .writable = header_writable }) catch unreachable;
    chain.segments.append(.{ .data = range, .writable = range_writable }) catch unreachable;
    if (fault == .extra_segment) {
        chain.segments.append(.{ .data = &extra_buf, .writable = false }) catch unreachable;
    }
    chain.segments.append(.{ .data = status, .writable = status_writable }) catch unreachable;
    _ = blk.handleRequest(&chain);

    if (fault == .none or fault == .random_ioprio) {
        try std.testing.expectEqual(status_ok, status_buf[0]);
        const zero_start: usize = @intCast(range_sector * sector_size);
        const zero_len: usize = @intCast(@as(u64, num_sectors) * sector_size);
        try std.testing.expectEqualSlices(u8, before[0..zero_start], disk[0..zero_start]);
        try std.testing.expect(std.mem.allEqual(u8, disk[zero_start..][0..zero_len], 0));
        try std.testing.expectEqualSlices(u8, before[zero_start + zero_len ..], disk[zero_start + zero_len ..]);
    } else {
        try std.testing.expect(status_buf[0] != status_ok);
        try std.testing.expectEqualSlices(u8, &before, &disk);
    }
}

test "fuzz write zeroes state transitions" {
    try std.testing.fuzz({}, fuzzWriteZeroesSemantics, .{});
}

test "config space reports capacity in sectors" {
    var disk = [_]u8{0} ** (8 * sector_size);
    var blk = Blk.init(.{ .memory = &disk });
    try std.testing.expectEqual(@as(u32, 8), Blk.configRead(&blk, 0));
    try std.testing.expectEqual(@as(u32, 0), Blk.configRead(&blk, 4));
}
