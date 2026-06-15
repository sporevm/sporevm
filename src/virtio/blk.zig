//! Virtio block device (virtio spec 1.2 §5.2), minimal.
//!
//! One request queue. Supports IN (read), OUT (write), FLUSH (no-op for the
//! memory backend, fsync for files), and GET_ID. Request framing, sectors,
//! and lengths are guest controlled and validated. See SECURITY.md.

const std = @import("std");
const guestmem = @import("../guestmem.zig");
const queue = @import("queue.zig");
const mmio = @import("mmio.zig");

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
    /// In-memory disk, used by tests.
    memory: []u8,

    fn capacityBytes(self: Backend) u64 {
        switch (self) {
            .file => |fd| {
                return seekFileSize(fd) orelse 0;
            },
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
            .memory => |m| {
                if (offset + buf.len > m.len) return false;
                @memcpy(buf, m[@intCast(offset)..][0..buf.len]);
                return true;
            },
        }
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
            .memory => |m| {
                if (offset + buf.len > m.len) return false;
                @memcpy(m[@intCast(offset)..][0..buf.len], buf);
                return true;
            },
        }
    }

    fn flush(self: Backend) void {
        switch (self) {
            .file => |fd| _ = std.c.fsync(fd),
            .memory => {},
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
        while (true) {
            const maybe_chain = q.popAvail(ram) catch return did_work;
            const chain = maybe_chain orelse break;
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
                var offset = std.math.mul(u64, sector, sector_size) catch return failStatus(status);
                var moved: u32 = 0;
                for (data) |seg| {
                    if (seg.writable != want_writable) return failStatus(status);
                    if (seg.data.len % sector_size != 0) return failStatus(status);
                    const seg_len = std.math.cast(u64, seg.data.len) orelse return failStatus(status);
                    const end = std.math.add(u64, offset, seg_len) catch return failStatus(status);
                    if (end > capacity_bytes) return failStatus(status);
                    const ok = if (want_writable)
                        self.backend.readAt(seg.data, offset)
                    else
                        self.backend.writeAt(seg.data, offset);
                    if (!ok) return failStatus(status);
                    offset = end;
                    if (want_writable) {
                        const written = std.math.cast(u32, seg.data.len) orelse return failStatus(status);
                        moved = std.math.add(u32, moved, written) catch return failStatus(status);
                    }
                }
                status.data[0] = status_ok;
                return moved + 1;
            },
            req_flush => {
                self.backend.flush();
                status.data[0] = status_ok;
                return 1;
            },
            req_get_id => {
                var moved: u32 = 0;
                const id = "sporevm-blk0";
                for (data) |seg| {
                    if (!seg.writable) return failStatus(status);
                    @memset(seg.data, 0);
                    const n = @min(seg.data.len, id.len);
                    @memcpy(seg.data[0..n], id[0..n]);
                    const written = std.math.cast(u32, seg.data.len) orelse return failStatus(status);
                    moved = std.math.add(u32, moved, written) catch return failStatus(status);
                }
                status.data[0] = status_ok;
                return moved + 1;
            },
            else => {
                status.data[0] = status_unsupp;
                return 1;
            },
        }
    }
};

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
