//! Virtio block device (virtio spec 1.2 §5.2), minimal.
//!
//! One request queue. Supports IN (read), OUT (write), FLUSH (no-op for the
//! memory backend, fsync for files), and GET_ID. Request framing, sectors,
//! and lengths are guest controlled and validated. See SECURITY.md.

const std = @import("std");
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
                disk.readAt(buf, offset) catch return false;
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
                disk.writeAt(buf, offset) catch return false;
                return true;
            },
            .memory => |m| {
                if (offset + buf.len > m.len) return false;
                @memcpy(m[@intCast(offset)..][0..buf.len], buf);
                return true;
            },
        }
    }

    fn flush(self: Backend) bool {
        switch (self) {
            .file => |fd| return std.c.fsync(fd) == 0,
            .chunk_mapped => |disk| {
                disk.flush() catch return false;
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

pub const Blk = struct {
    backend: Backend,
    capacity_sectors: u64,

    pub fn init(backend: Backend) Blk {
        return .{
            .backend = backend,
            .capacity_sectors = backend.capacityBytes() / sector_size,
        };
    }

    pub fn device(self: *Blk) mmio.Device {
        return .{
            .context = self,
            .device_id = device_id,
            .device_features = 0,
            .queue_count = 1,
            .notifyFn = notify,
            .configReadFn = configRead,
        };
    }

    fn configRead(ctx: *anyopaque, offset: u64) u32 {
        const self: *Blk = @ptrCast(@alignCast(ctx));
        // Config space starts with capacity in sectors as u64 LE.
        return switch (offset) {
            0 => @truncate(self.capacity_sectors),
            4 => @truncate(self.capacity_sectors >> 32),
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

                if (want_writable) {
                    const total_len = std.math.cast(usize, offset - request_offset) orelse return failStatus(status);
                    // Each readAt prefaults its own slice for direct callers;
                    // this request-wide pass is still required so a later
                    // descriptor cannot fail after an earlier one was copied.
                    if (!self.backend.prefaultCasRange(total_len, request_offset)) return failStatus(status);
                }

                offset = request_offset;
                for (data) |seg| {
                    const ok = if (want_writable)
                        self.backend.readAt(seg.data, offset)
                    else
                        self.backend.writeAt(seg.data, offset);
                    if (!ok) return failStatus(status);
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
            else => {
                status.data[0] = status_unsupp;
                return 1;
            },
        }
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

// --- tests ------------------------------------------------------------------

fn makeChain(segs: []const queue.Segment) queue.Chain {
    var chain = queue.Chain{ .head = 0, .segments = .{} };
    for (segs) |s| chain.segments.append(s) catch unreachable;
    return chain;
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
    var blk = Blk.init(.{ .memory = &disk });

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

    _ = blk.handleRequest(&chain);
}

test "fuzz block request handling" {
    try std.testing.fuzz({}, fuzzBlkRequest, .{});
}

test "config space reports capacity in sectors" {
    var disk = [_]u8{0} ** (8 * sector_size);
    var blk = Blk.init(.{ .memory = &disk });
    try std.testing.expectEqual(@as(u32, 8), Blk.configRead(&blk, 0));
    try std.testing.expectEqual(@as(u32, 0), Blk.configRead(&blk, 4));
}
