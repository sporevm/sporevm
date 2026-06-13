//! Virtio socket device (virtio spec 1.2 §5.10), minimal closed endpoint.
//!
//! Queue 0 is receive, queue 1 is transmit, queue 2 is event. This first
//! slice gives the guest a real virtio-vsock transport and safely rejects
//! stream connection attempts with RST packets. A host service backend can
//! replace the closed-endpoint policy without changing the transport shape.
//! Packet headers, queue descriptors, and lengths are guest controlled. See
//! SECURITY.md.

const std = @import("std");
const guestmem = @import("../guestmem.zig");
const queue = @import("queue.zig");
const mmio = @import("mmio.zig");

pub const device_id: u32 = 19;

pub const host_cid: u64 = 2;
pub const default_guest_cid: u64 = 3;

const rx_queue = 0;
const tx_queue = 1;
const event_queue = 2;

pub const header_len = 44;

const packet_type_stream: u16 = 1;

const op_request: u16 = 1;
const op_rst: u16 = 3;

const max_pending = 16;

pub const Header = struct {
    src_cid: u64,
    dst_cid: u64,
    src_port: u32,
    dst_port: u32,
    len: u32,
    packet_type: u16,
    op: u16,
    flags: u32 = 0,
    buf_alloc: u32 = 0,
    fwd_cnt: u32 = 0,
};

pub const Config = struct {
    guest_cid: u64 = default_guest_cid,
};

pub const Vsock = struct {
    guest_cid: u64,
    pending: [max_pending]Header = undefined,
    pending_len: usize = 0,

    pub fn init(config: Config) Vsock {
        return .{ .guest_cid = config.guest_cid };
    }

    pub fn device(self: *Vsock) mmio.Device {
        return .{
            .context = self,
            .device_id = device_id,
            .device_features = 0,
            .queue_count = 3,
            .notifyFn = notify,
            .configReadFn = configRead,
        };
    }

    fn configRead(ctx: *anyopaque, offset: u64) u32 {
        const self: *Vsock = @ptrCast(@alignCast(ctx));
        // Config space is the guest CID as a little-endian u64.
        return switch (offset) {
            0 => @truncate(self.guest_cid),
            4 => @truncate(self.guest_cid >> 32),
            else => 0,
        };
    }

    fn notify(ctx: *anyopaque, queue_index: u8, queues: *[mmio.max_queues]queue.VirtQueue, ram: guestmem.GuestRam) bool {
        const self: *Vsock = @ptrCast(@alignCast(ctx));
        return switch (queue_index) {
            tx_queue => self.processTx(queues, ram),
            rx_queue => self.flushRx(&queues[rx_queue], ram),
            event_queue => false,
            else => false,
        };
    }

    fn processTx(self: *Vsock, queues: *[mmio.max_queues]queue.VirtQueue, ram: guestmem.GuestRam) bool {
        const tx = &queues[tx_queue];
        var did_work = false;
        var budget: usize = queue.max_queue_size;
        while (budget > 0) : (budget -= 1) {
            const maybe_chain = tx.popAvail(ram) catch return did_work;
            const chain = maybe_chain orelse break;
            if (parseHeaderFromChain(&chain)) |h| {
                self.rejectIfConnectRequest(h);
            }
            tx.pushUsed(ram, chain.head, 0) catch return did_work;
            did_work = true;
        }
        return self.flushRx(&queues[rx_queue], ram) or did_work;
    }

    fn rejectIfConnectRequest(self: *Vsock, h: Header) void {
        if (h.op != op_request or h.packet_type != packet_type_stream) return;
        if (h.dst_cid != host_cid or h.src_cid != self.guest_cid) return;
        if (self.pending_len >= self.pending.len) return;
        self.pending[self.pending_len] = .{
            .src_cid = h.dst_cid,
            .dst_cid = h.src_cid,
            .src_port = h.dst_port,
            .dst_port = h.src_port,
            .len = 0,
            .packet_type = h.packet_type,
            .op = op_rst,
        };
        self.pending_len += 1;
    }

    fn flushRx(self: *Vsock, rx: *queue.VirtQueue, ram: guestmem.GuestRam) bool {
        var did_work = false;
        while (self.pending_len > 0) {
            const maybe_chain = rx.popAvail(ram) catch return did_work;
            const chain = maybe_chain orelse break;
            const written = writeHeaderToChain(&chain, self.pending[0]) orelse 0;
            rx.pushUsed(ram, chain.head, written) catch return did_work;
            self.dropFirstPending();
            did_work = true;
        }
        return did_work;
    }

    fn dropFirstPending(self: *Vsock) void {
        if (self.pending_len == 0) return;
        var i: usize = 1;
        while (i < self.pending_len) : (i += 1) {
            self.pending[i - 1] = self.pending[i];
        }
        self.pending_len -= 1;
    }
};

fn parseHeaderFromChain(chain: *const queue.Chain) ?Header {
    var buf: [header_len]u8 = undefined;
    if (!copyReadablePrefix(chain, &buf)) return null;
    return parseHeader(&buf);
}

fn copyReadablePrefix(chain: *const queue.Chain, out: []u8) bool {
    var copied: usize = 0;
    for (chain.segments.slice()) |seg| {
        if (seg.writable) continue;
        const n = @min(seg.data.len, out.len - copied);
        @memcpy(out[copied..][0..n], seg.data[0..n]);
        copied += n;
        if (copied == out.len) return true;
    }
    return false;
}

fn writeHeaderToChain(chain: *const queue.Chain, h: Header) ?u32 {
    var buf: [header_len]u8 = undefined;
    writeHeader(&buf, h);
    var copied: usize = 0;
    for (chain.segments.slice()) |seg| {
        if (!seg.writable) continue;
        const n = @min(seg.data.len, buf.len - copied);
        @memcpy(seg.data[0..n], buf[copied..][0..n]);
        copied += n;
        if (copied == buf.len) return header_len;
    }
    return null;
}

fn parseHeader(buf: *const [header_len]u8) Header {
    return .{
        .src_cid = std.mem.readInt(u64, buf[0..8], .little),
        .dst_cid = std.mem.readInt(u64, buf[8..16], .little),
        .src_port = std.mem.readInt(u32, buf[16..20], .little),
        .dst_port = std.mem.readInt(u32, buf[20..24], .little),
        .len = std.mem.readInt(u32, buf[24..28], .little),
        .packet_type = std.mem.readInt(u16, buf[28..30], .little),
        .op = std.mem.readInt(u16, buf[30..32], .little),
        .flags = std.mem.readInt(u32, buf[32..36], .little),
        .buf_alloc = std.mem.readInt(u32, buf[36..40], .little),
        .fwd_cnt = std.mem.readInt(u32, buf[40..44], .little),
    };
}

fn writeHeader(buf: *[header_len]u8, h: Header) void {
    std.mem.writeInt(u64, buf[0..8], h.src_cid, .little);
    std.mem.writeInt(u64, buf[8..16], h.dst_cid, .little);
    std.mem.writeInt(u32, buf[16..20], h.src_port, .little);
    std.mem.writeInt(u32, buf[20..24], h.dst_port, .little);
    std.mem.writeInt(u32, buf[24..28], h.len, .little);
    std.mem.writeInt(u16, buf[28..30], h.packet_type, .little);
    std.mem.writeInt(u16, buf[30..32], h.op, .little);
    std.mem.writeInt(u32, buf[32..36], h.flags, .little);
    std.mem.writeInt(u32, buf[36..40], h.buf_alloc, .little);
    std.mem.writeInt(u32, buf[40..44], h.fwd_cnt, .little);
}

// --- tests ------------------------------------------------------------------

fn configureQueue(t: *mmio.Transport, qi: u32, desc: u64, avail: u64, used: u64, ram: guestmem.GuestRam) void {
    _ = t.write(0x030, qi, ram);
    _ = t.write(0x038, 8, ram);
    _ = t.write(0x080, @truncate(desc), ram);
    _ = t.write(0x084, @truncate(desc >> 32), ram);
    _ = t.write(0x090, @truncate(avail), ram);
    _ = t.write(0x094, @truncate(avail >> 32), ram);
    _ = t.write(0x0a0, @truncate(used), ram);
    _ = t.write(0x0a4, @truncate(used >> 32), ram);
    _ = t.write(0x044, 1, ram);
}

fn setDesc(ram: guestmem.GuestRam, desc_base: u64, i: u16, addr: u64, len: u32, flags: u16) !void {
    const base = desc_base + 16 * @as(u64, i);
    try ram.write(u64, base, addr);
    try ram.write(u32, base + 8, len);
    try ram.write(u16, base + 12, flags);
    try ram.write(u16, base + 14, 0);
}

fn pushAvail(ram: guestmem.GuestRam, avail_base: u64, qsize: u16, head: u16) !void {
    const idx = try ram.read(u16, avail_base + 2);
    try ram.write(u16, avail_base + 4 + 2 * @as(u64, idx % qsize), head);
    try ram.write(u16, avail_base + 2, idx +% 1);
}

test "config reports guest cid" {
    var dev = Vsock.init(.{ .guest_cid = 42 });
    var t = mmio.Transport.init(dev.device());
    try std.testing.expectEqual(device_id, t.read(0x008));
    try std.testing.expectEqual(@as(u32, 42), t.read(0x100));
    try std.testing.expectEqual(@as(u32, 0), t.read(0x104));
}

test "stream connect request is answered with rst" {
    var dev = Vsock.init(.{ .guest_cid = default_guest_cid });
    var t = mmio.Transport.init(dev.device());
    var buf: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    const rx_desc = 0x000;
    const rx_avail = 0x400;
    const rx_used = 0x800;
    const tx_desc = 0x1000;
    const tx_avail = 0x1400;
    const tx_used = 0x1800;
    const rx_buf = 0x2000;
    const tx_buf = 0x2100;

    configureQueue(&t, rx_queue, rx_desc, rx_avail, rx_used, ram);
    configureQueue(&t, tx_queue, tx_desc, tx_avail, tx_used, ram);

    try setDesc(ram, rx_desc, 0, rx_buf, header_len, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 0);

    var request: [header_len]u8 = undefined;
    writeHeader(&request, .{
        .src_cid = default_guest_cid,
        .dst_cid = host_cid,
        .src_port = 1024,
        .dst_port = 80,
        .len = 0,
        .packet_type = packet_type_stream,
        .op = op_request,
    });
    @memcpy(buf[tx_buf..][0..header_len], &request);
    try setDesc(ram, tx_desc, 0, tx_buf, header_len, 0);
    try pushAvail(ram, tx_avail, 8, 0);

    try std.testing.expect(t.write(0x050, tx_queue, ram));
    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, tx_used + 2));
    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, rx_used + 2));
    try std.testing.expectEqual(@as(u32, header_len), try ram.read(u32, rx_used + 8));

    const response = parseHeader(buf[rx_buf..][0..header_len]);
    try std.testing.expectEqual(host_cid, response.src_cid);
    try std.testing.expectEqual(default_guest_cid, response.dst_cid);
    try std.testing.expectEqual(@as(u32, 80), response.src_port);
    try std.testing.expectEqual(@as(u32, 1024), response.dst_port);
    try std.testing.expectEqual(packet_type_stream, response.packet_type);
    try std.testing.expectEqual(op_rst, response.op);
    try std.testing.expectEqual(@as(u32, 0), response.len);
}

fn fuzzVsockTx(_: void, s: *std.testing.Smith) !void {
    var dev = Vsock.init(.{});
    var t = mmio.Transport.init(dev.device());
    var buf: [4096]u8 = [_]u8{0} ** 4096;
    _ = s.slice(&buf);
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };
    t.queues[rx_queue] = .{ .size = 8, .ready = true, .desc_addr = 0x1000, .avail_addr = 0x1200, .used_addr = 0x1400 };
    t.queues[tx_queue] = .{ .size = 8, .ready = true, .desc_addr = 0x0000, .avail_addr = 0x0400, .used_addr = 0x0800 };
    _ = t.write(0x050, tx_queue, ram);
}

test "fuzz vsock tx handling" {
    try std.testing.fuzz({}, fuzzVsockTx, .{});
}
