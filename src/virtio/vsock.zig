//! Virtio socket device (virtio spec 1.2 §5.10).
//!
//! Queue 0 is receive, queue 1 is transmit, queue 2 is event. The endpoint is
//! deliberately small: guest-initiated host connections are refused, and the
//! host attaches at most one host-initiated stream (`vsock_stream.zig`) to a
//! guest listener.
//! Packet headers, queue descriptors, payload lengths, and rings are guest
//! controlled. See SECURITY.md.

const std = @import("std");
const guestmem = @import("../guestmem.zig");
const queue = @import("queue.zig");
const mmio = @import("mmio.zig");
const spore_stream = @import("../spore_stream.zig");
const vsock_stream = @import("vsock_stream.zig");
const HostStream = vsock_stream.HostStream;

pub const device_id: u32 = 19;

pub const host_cid: u64 = 2;
pub const default_guest_cid: u64 = 3;

const rx_queue = 0;
const tx_queue = 1;
const event_queue = 2;

pub const header_len = 44;

const packet_type_stream: u16 = 1;

const op_request: u16 = 1;
const op_response: u16 = 2;
const op_rst: u16 = 3;
const op_shutdown: u16 = 4;
const op_rw: u16 = 5;
const op_credit_update: u16 = 6;
const op_credit_request: u16 = 7;

const max_pending = 16;
/// Largest packet payload the device queues for the guest.
pub const max_payload = 8192;
/// Largest guest packet payload the device accepts: Linux's
/// VIRTIO_VSOCK_MAX_PKT_BUF_SIZE, so one large guest write is one packet.
const max_tx_payload = 64 * 1024;
pub const host_stream_credit = 64 * 1024;

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

const Packet = struct {
    header: Header,
    data: [max_payload]u8 = @splat(0),
    data_len: usize = 0,
};

pub const Vsock = struct {
    guest_cid: u64,
    pending: [max_pending]Packet = undefined,
    pending_len: usize = 0,
    host_stream: ?*HostStream = null,

    pub fn init(config: Config) Vsock {
        return .{ .guest_cid = config.guest_cid };
    }

    pub fn attachHostStream(self: *Vsock, stream: *HostStream) !void {
        std.log.debug(
            "vsock host stream attach: host_port={d} guest_port={d} pending_before={d}",
            .{ stream.host_port, stream.guest_port, self.pending_len },
        );
        self.host_stream = stream;
        stream.markAttached();
        try self.enqueueHostConnectRequest(stream);
    }

    /// Detach the current host stream and tell the guest the connection is
    /// gone. Without the reset, a guest blocked writing stream data waits
    /// forever for credit on a connection the host has abandoned, wedging
    /// the guest agent and every subsequent exec.
    pub fn resetHostStream(self: *Vsock) void {
        const stream = self.host_stream orelse return;
        const old_state = stream.state;
        const pending_before = self.pending_len;
        self.host_stream = null;
        // The monitor owns only one host stream at a time, so a stream boundary
        // deliberately drops the whole pending queue. That includes packets
        // for this stream and RSTs queued for unknown or abandoned guest tuples;
        // none may cross into the successor attach. A normally completed stream
        // does not need an explicit reset packet.
        self.pending_len = 0;
        if (old_state == .complete) {
            std.log.debug(
                "vsock host stream reset: host_port={d} state={s} pending_before={d} pending_after=0 rst=false",
                .{ stream.host_port, @tagName(old_state), pending_before },
            );
            return;
        }
        self.enqueuePacket(.{
            .src_cid = host_cid,
            .dst_cid = self.guest_cid,
            .src_port = stream.host_port,
            .dst_port = stream.guest_port,
            .len = 0,
            .packet_type = packet_type_stream,
            .op = op_rst,
            .buf_alloc = host_stream_credit,
            .fwd_cnt = stream.received_bytes,
        }, "") catch {};
        std.log.debug(
            "vsock host stream reset: host_port={d} state={s} pending_before={d} pending_after={d} rst=true",
            .{ stream.host_port, @tagName(old_state), pending_before, self.pending_len },
        );
    }

    /// Delivers pending host packets the guest did not notify for. Returns
    /// true when the caller must raise the transport's interrupt line.
    pub fn flushPendingRx(self: *Vsock, transport: *mmio.Transport, ram: guestmem.GuestRam) bool {
        var budget: queue.NotifyBudget = .{};
        return transport.signalUsedBuffers(self.flushRx(&transport.queues[rx_queue], ram, &budget));
    }

    fn enqueueHostConnectRequest(self: *Vsock, stream: *HostStream) !void {
        try self.enqueuePacket(.{
            .src_cid = host_cid,
            .dst_cid = self.guest_cid,
            .src_port = stream.host_port,
            .dst_port = stream.guest_port,
            .len = 0,
            .packet_type = packet_type_stream,
            .op = op_request,
            .buf_alloc = host_stream_credit,
            .fwd_cnt = stream.received_bytes,
        }, "");
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
        var budget: queue.NotifyBudget = .{};
        return switch (queue_index) {
            tx_queue => self.processTx(queues, ram, &budget),
            rx_queue => self.flushRx(&queues[rx_queue], ram, &budget),
            event_queue => false,
            else => false,
        };
    }

    fn processTx(self: *Vsock, queues: *[mmio.max_queues]queue.VirtQueue, ram: guestmem.GuestRam, budget: *queue.NotifyBudget) bool {
        const tx = &queues[tx_queue];
        var did_work = false;
        while (budget.hasRemaining()) {
            const maybe_chain = tx.popAvail(ram) catch return did_work;
            const chain = maybe_chain orelse break;
            budget.consume();
            if (parseTxHeader(&chain)) |header| self.handleGuestPacket(header, &chain);
            tx.pushUsed(ram, chain.head, 0) catch return did_work;
            did_work = true;
        }
        // Guest packets may have grown the credit window; move deferred
        // outbound frames before delivering pending receive packets.
        if (self.host_stream) |stream| {
            _ = self.flushHostStreamOutboundFor(stream) catch stream.fail();
        }
        return self.flushRx(&queues[rx_queue], ram, budget) or did_work;
    }

    fn handleGuestPacket(self: *Vsock, h: Header, chain: *const queue.Chain) void {
        if (h.packet_type != packet_type_stream) return;

        if (self.host_stream) |stream| {
            const matches_host_stream =
                h.src_cid == self.guest_cid and
                h.dst_cid == host_cid and
                h.src_port == stream.guest_port and
                h.dst_port == stream.host_port;
            if (matches_host_stream) {
                self.handleHostStreamPacket(stream, h, chain);
                return;
            }
        }

        if (h.dst_cid != host_cid or h.src_cid != self.guest_cid) return;
        // Connection requests are refused, and packets for unknown or
        // abandoned connections are reset (virtio 1.2 §5.10.6.6) so guests
        // blocked on a stale stream unblock instead of waiting forever.
        // Never answer a reset with a reset.
        if (h.op == op_rst) return;
        self.enqueuePacket(.{
            .src_cid = h.dst_cid,
            .dst_cid = h.src_cid,
            .src_port = h.dst_port,
            .dst_port = h.src_port,
            .len = 0,
            .packet_type = h.packet_type,
            .op = op_rst,
        }, "") catch {};
    }

    fn handleHostStreamPacket(self: *Vsock, stream: *HostStream, h: Header, chain: *const queue.Chain) void {
        // Every guest packet carries the guest's current receive window.
        stream.peer_buf_alloc = h.buf_alloc;
        stream.peer_fwd_cnt = h.fwd_cnt;
        switch (h.op) {
            op_response => {
                if (stream.state == .connecting) {
                    stream.markConnected();
                    _ = self.flushHostStreamOutboundFor(stream) catch stream.fail();
                }
            },
            op_rw => {
                // Copy the payload out of guest memory a piece at a time;
                // parseTxHeader checked the chain holds all of it.
                var piece: [max_payload]u8 = undefined;
                var done: usize = 0;
                while (done < h.len) {
                    const n = @min(piece.len, h.len - done);
                    if (!chain.copyReadableRange(header_len + done, piece[0..n])) break;
                    stream.appendOutput(piece[0..n]);
                    done += n;
                }
            },
            op_credit_request => self.enqueueHostPacket(stream, op_credit_update, "") catch stream.fail(),
            op_credit_update => {},
            op_shutdown => {},
            op_rst => {
                if (stream.state == .connecting) {
                    self.enqueueHostConnectRequest(stream) catch stream.fail();
                } else {
                    stream.fail();
                }
            },
            else => {},
        }
        // Volunteer a credit update on any guest activity so an update
        // skipped while the pending queue was full is retried.
        self.maybeUpdateCredit(stream);
    }

    fn enqueueHostPacket(self: *Vsock, stream: *HostStream, op: u16, payload: []const u8) !void {
        try self.enqueuePacket(.{
            .src_cid = host_cid,
            .dst_cid = self.guest_cid,
            .src_port = stream.host_port,
            .dst_port = stream.guest_port,
            .len = @intCast(payload.len),
            .packet_type = packet_type_stream,
            .op = op,
            .buf_alloc = host_stream_credit,
            .fwd_cnt = stream.received_bytes,
        }, payload);
        stream.credit_fwd_cnt_sent = stream.received_bytes;
        const inc: u32 = if (payload.len > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(payload.len);
        stream.sent_bytes +%= inc;
    }

    /// Send a credit update once the guest has consumed enough of the
    /// advertised window that it risks stalling. The guest driver blocks
    /// without requesting credit when its window fills, so the host must
    /// volunteer updates as it consumes stream data.
    fn maybeUpdateCredit(self: *Vsock, stream: *HostStream) void {
        if (stream.state != .connected) return;
        const consumed = stream.received_bytes -% stream.credit_fwd_cnt_sent;
        if (consumed < host_stream_credit / 2) return;
        self.enqueueHostPacket(stream, op_credit_update, "") catch {};
    }

    pub fn flushHostStreamOutbound(self: *Vsock) !bool {
        const stream = self.host_stream orelse return false;
        return self.flushHostStreamOutboundFor(stream);
    }

    fn flushHostStreamOutboundFor(self: *Vsock, stream: *HostStream) !bool {
        if (stream.state != .connected) return false;
        var did_work = false;
        if (!stream.request_sent) {
            if (stream.request_len > stream.txWindowFree()) return did_work;
            if (self.pending_len >= self.pending.len) return did_work;
            try self.enqueueHostPacket(stream, op_rw, stream.request[0..stream.request_len]);
            stream.request_sent = true;
            did_work = true;
        }
        while (self.pending_len < self.pending.len) {
            var payload_buf: [max_payload]u8 = undefined;
            const payload = stream.dequeueOutboundWithin(&payload_buf, stream.txWindowFree()) orelse break;
            try self.enqueueHostPacket(stream, op_rw, payload);
            did_work = true;
        }
        return did_work;
    }

    fn enqueuePacket(self: *Vsock, header: Header, payload: []const u8) !void {
        if (payload.len > max_payload) return error.PacketTooLarge;
        if (self.pending_len >= self.pending.len) return error.PendingFull;
        var packet = Packet{ .header = header, .data_len = payload.len };
        packet.header.len = @intCast(payload.len);
        if (payload.len > 0) @memcpy(packet.data[0..payload.len], payload);
        self.pending[self.pending_len] = packet;
        self.pending_len += 1;
    }

    fn flushRx(self: *Vsock, rx: *queue.VirtQueue, ram: guestmem.GuestRam, budget: *queue.NotifyBudget) bool {
        var did_work = false;
        while (self.pending_len > 0 and budget.hasRemaining()) {
            const maybe_chain = rx.popAvail(ram) catch return did_work;
            const chain = maybe_chain orelse break;
            budget.consume();
            const packet = &self.pending[0];
            const capacity = chainWritableCapacity(&chain);
            // Stream data (op_rw) carries no per-packet boundaries, so a
            // payload larger than the guest buffer is legally delivered as
            // multiple smaller packets. Other packets must fit whole, and a
            // split fragment must make at least one byte of progress.
            const take = @min(packet.data_len, capacity -| header_len);
            const deliverable = capacity >= header_len and
                (take == packet.data_len or (packet.header.op == op_rw and take > 0));
            if (!deliverable) {
                // The guest posted a buffer too small for this packet.
                // Consume the undersized buffer but keep the packet pending;
                // dropping it would corrupt the stream. Progress is bounded
                // by the guest's available ring.
                chain.markWritableDirty(ram);
                rx.pushUsed(ram, chain.head, 0) catch return did_work;
                did_work = true;
                continue;
            }
            var fragment_header = packet.header;
            fragment_header.len = @intCast(take);
            const written = writePacketToChain(&chain, fragment_header, packet.data[0..take]) orelse {
                // Capacity was verified above, so this is unreachable; if it
                // ever fires, keep the packet pending rather than dropping
                // stream data.
                chain.markWritableDirty(ram);
                rx.pushUsed(ram, chain.head, 0) catch return did_work;
                did_work = true;
                continue;
            };
            chain.markWritableDirty(ram);
            rx.pushUsed(ram, chain.head, written) catch return did_work;
            if (take < packet.data_len) {
                const rest = packet.data_len - take;
                std.mem.copyForwards(u8, packet.data[0..rest], packet.data[take..packet.data_len]);
                packet.data_len = rest;
                packet.header.len = @intCast(rest);
            } else {
                self.recordHostDelivery(packet.header);
                self.dropFirstPending();
            }
            did_work = true;
        }
        return did_work;
    }

    fn recordHostDelivery(self: *Vsock, h: Header) void {
        const stream = self.host_stream orelse return;
        if (h.src_cid != host_cid or h.dst_cid != self.guest_cid) return;
        if (h.src_port != stream.host_port or h.dst_port != stream.guest_port) return;
        switch (h.op) {
            op_request => stream.markConnectRequestDelivered(),
            op_rw => stream.markRequestDelivered(),
            else => {},
        }
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

fn chainWritableCapacity(chain: *const queue.Chain) usize {
    var n: usize = 0;
    for (chain.segments.slice()) |seg| {
        if (seg.writable) n += seg.data.len;
    }
    return n;
}

/// The header of a guest packet whose chain holds its whole payload.
fn parseTxHeader(chain: *const queue.Chain) ?Header {
    var buf: [header_len]u8 = undefined;
    if (!chain.copyReadableRange(0, &buf)) return null;
    const header = parseHeader(&buf);
    if (header.len > max_tx_payload or chain.readableLen() - header_len < header.len) return null;
    return header;
}

fn writePacketToChain(chain: *const queue.Chain, h: Header, payload: []const u8) ?u32 {
    var buf: [header_len]u8 = undefined;
    writeHeader(&buf, h);
    var copied: usize = 0;
    const total = header_len + payload.len;
    for (chain.segments.slice()) |seg| {
        if (!seg.writable) continue;
        var written_to_seg: usize = 0;
        if (copied < header_len) {
            const n = @min(seg.data.len, header_len - copied);
            @memcpy(seg.data[0..n], buf[copied..][0..n]);
            copied += n;
            written_to_seg += n;
        }
        if (copied >= header_len and copied < total and written_to_seg < seg.data.len) {
            const payload_off = copied - header_len;
            const n = @min(seg.data.len - written_to_seg, payload.len - payload_off);
            @memcpy(seg.data[written_to_seg..][0..n], payload[payload_off..][0..n]);
            copied += n;
        }
        if (copied == total) return @intCast(total);
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
    var buf: [16 * 1024]u8 = @splat(0);
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

test "host stream connects, sends request, and parses streamed frames" {
    var dev = Vsock.init(.{ .guest_cid = default_guest_cid });
    var t = mmio.Transport.init(dev.device());
    var buf: [32 * 1024]u8 = @splat(0);
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    const rx_desc = 0x000;
    const rx_avail = 0x400;
    const rx_used = 0x800;
    const tx_desc = 0x1000;
    const tx_avail = 0x1400;
    const tx_used = 0x1800;
    const rx_buf_request = 0x2000;
    const rx_buf_retry = 0x2200;
    const rx_buf_payload = 0x2400;
    const tx_buf_rst = 0x2600;
    const tx_buf_response = 0x2800;
    const tx_buf_stdout = 0x2a00;
    const tx_buf_stderr = 0x2c00;
    const tx_buf_exit = 0x2e00;

    configureQueue(&t, rx_queue, rx_desc, rx_avail, rx_used, ram);
    configureQueue(&t, tx_queue, tx_desc, tx_avail, tx_used, ram);

    const request = "{\"type\":\"ready\"}\n";
    var stream = try HostStream.init(10700, request);
    var capture = vsock_stream.StreamCapture{};
    stream.setOutputSink(&capture, vsock_stream.captureSink);
    stream.setLifecycleSink(&capture, vsock_stream.lifecycleSink);
    try dev.attachHostStream(&stream);

    try setDesc(ram, rx_desc, 0, rx_buf_request, header_len, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 0);
    try std.testing.expect(t.write(0x050, rx_queue, ram));
    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, rx_used + 2));

    const connect = parseHeader(buf[rx_buf_request..][0..header_len]);
    try std.testing.expectEqual(host_cid, connect.src_cid);
    try std.testing.expectEqual(default_guest_cid, connect.dst_cid);
    try std.testing.expectEqual(vsock_stream.default_host_port, connect.src_port);
    try std.testing.expectEqual(@as(u32, 10700), connect.dst_port);
    try std.testing.expectEqual(op_request, connect.op);

    try setDesc(ram, rx_desc, 1, rx_buf_retry, header_len, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 1);

    var rst: [header_len]u8 = undefined;
    writeHeader(&rst, .{
        .src_cid = default_guest_cid,
        .dst_cid = host_cid,
        .src_port = 10700,
        .dst_port = vsock_stream.default_host_port,
        .len = 0,
        .packet_type = packet_type_stream,
        .op = op_rst,
    });
    @memcpy(buf[tx_buf_rst..][0..header_len], &rst);
    try setDesc(ram, tx_desc, 0, tx_buf_rst, header_len, 0);
    try pushAvail(ram, tx_avail, 8, 0);
    try std.testing.expect(t.write(0x050, tx_queue, ram));
    try std.testing.expectEqual(vsock_stream.HostStreamState.connecting, stream.state);
    try std.testing.expectEqual(@as(u16, 2), try ram.read(u16, rx_used + 2));

    const retry = parseHeader(buf[rx_buf_retry..][0..header_len]);
    try std.testing.expectEqual(op_request, retry.op);
    try std.testing.expectEqual(host_cid, retry.src_cid);
    try std.testing.expectEqual(default_guest_cid, retry.dst_cid);

    try setDesc(ram, rx_desc, 2, rx_buf_payload, @intCast(header_len + request.len), 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 2);

    var response: [header_len]u8 = undefined;
    writeHeader(&response, .{
        .src_cid = default_guest_cid,
        .dst_cid = host_cid,
        .src_port = 10700,
        .dst_port = vsock_stream.default_host_port,
        .len = 0,
        .packet_type = packet_type_stream,
        .op = op_response,
        .buf_alloc = 64 * 1024,
    });
    @memcpy(buf[tx_buf_response..][0..header_len], &response);
    try setDesc(ram, tx_desc, 1, tx_buf_response, header_len, 0);
    try pushAvail(ram, tx_avail, 8, 1);
    try std.testing.expect(t.write(0x050, tx_queue, ram));
    try std.testing.expectEqual(vsock_stream.HostStreamState.connected, stream.state);
    try std.testing.expectEqual(@as(usize, 1), capture.ready_count);
    try std.testing.expectEqual(@as(u16, 3), try ram.read(u16, rx_used + 2));

    const delivered = parseHeader(buf[rx_buf_payload..][0..header_len]);
    try std.testing.expectEqual(op_rw, delivered.op);
    try std.testing.expectEqual(@as(u32, @intCast(request.len)), delivered.len);
    try std.testing.expectEqualStrings(request, buf[rx_buf_payload + header_len ..][0..request.len]);

    var stdout_frame_buf: [spore_stream.max_frame_len]u8 = undefined;
    const stdout_frame = try spore_stream.writeFrame(&stdout_frame_buf, .{ .frame_type = .data, .stream_id = .stdout }, "hello\n");
    var stdout_rw: [header_len]u8 = undefined;
    writeHeader(&stdout_rw, .{
        .src_cid = default_guest_cid,
        .dst_cid = host_cid,
        .src_port = 10700,
        .dst_port = vsock_stream.default_host_port,
        .len = @intCast(stdout_frame.len),
        .packet_type = packet_type_stream,
        .op = op_rw,
    });
    @memcpy(buf[tx_buf_stdout..][0..header_len], &stdout_rw);
    @memcpy(buf[tx_buf_stdout + header_len ..][0..stdout_frame.len], stdout_frame);
    try setDesc(ram, tx_desc, 2, tx_buf_stdout, @intCast(header_len + stdout_frame.len), 0);
    try pushAvail(ram, tx_avail, 8, 2);
    try std.testing.expect(t.write(0x050, tx_queue, ram));

    var stderr_frame_buf: [spore_stream.max_frame_len]u8 = undefined;
    const stderr_frame = try spore_stream.writeFrame(&stderr_frame_buf, .{ .frame_type = .data, .stream_id = .stderr }, "err\n");
    var stderr_rw: [header_len]u8 = undefined;
    writeHeader(&stderr_rw, .{
        .src_cid = default_guest_cid,
        .dst_cid = host_cid,
        .src_port = 10700,
        .dst_port = vsock_stream.default_host_port,
        .len = @intCast(stderr_frame.len),
        .packet_type = packet_type_stream,
        .op = op_rw,
    });
    @memcpy(buf[tx_buf_stderr..][0..header_len], &stderr_rw);
    @memcpy(buf[tx_buf_stderr + header_len ..][0..stderr_frame.len], stderr_frame);
    try setDesc(ram, tx_desc, 3, tx_buf_stderr, @intCast(header_len + stderr_frame.len), 0);
    try pushAvail(ram, tx_avail, 8, 3);
    try std.testing.expect(t.write(0x050, tx_queue, ram));

    var exit_payload: [4]u8 = undefined;
    spore_stream.writeExitPayload(&exit_payload, 7);
    var exit_frame_buf: [spore_stream.max_frame_len]u8 = undefined;
    const exit_frame = try spore_stream.writeFrame(&exit_frame_buf, .{ .frame_type = .exit, .stream_id = .control }, &exit_payload);
    var rw: [header_len]u8 = undefined;
    writeHeader(&rw, .{
        .src_cid = default_guest_cid,
        .dst_cid = host_cid,
        .src_port = 10700,
        .dst_port = vsock_stream.default_host_port,
        .len = @intCast(exit_frame.len),
        .packet_type = packet_type_stream,
        .op = op_rw,
    });
    @memcpy(buf[tx_buf_exit..][0..header_len], &rw);
    @memcpy(buf[tx_buf_exit + header_len ..][0..exit_frame.len], exit_frame);
    try setDesc(ram, tx_desc, 4, tx_buf_exit, @intCast(header_len + exit_frame.len), 0);
    try pushAvail(ram, tx_avail, 8, 4);
    try std.testing.expect(t.write(0x050, tx_queue, ram));

    try std.testing.expectEqual(vsock_stream.HostStreamState.complete, stream.state);
    try std.testing.expectEqual(@as(i32, 7), stream.exit_code.?);
    try std.testing.expectEqualStrings("hello\n", capture.stdout[0..capture.stdout_len]);
    try std.testing.expectEqualStrings("err\n", capture.stderr[0..capture.stderr_len]);
}

test "rx delivery splits stream data across small guest buffers" {
    var dev = Vsock.init(.{ .guest_cid = default_guest_cid });
    var t = mmio.Transport.init(dev.device());
    var buf: [32 * 1024]u8 = @splat(0);
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    const rx_desc = 0x000;
    const rx_avail = 0x400;
    const rx_used = 0x800;
    const rx_bufs = 0x2000;
    // Each guest receive buffer only has room for the packet header plus 100
    // payload bytes, mirroring guests whose receive buffers are smaller than
    // one full host frame.
    const rx_buf_len: u32 = header_len + 100;

    configureQueue(&t, rx_queue, rx_desc, rx_avail, rx_used, ram);

    var stream = try HostStream.init(10700, "{}\n");
    stream.state = .connected;
    dev.host_stream = &stream;

    var payload: [250]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);
    try dev.enqueueHostPacket(&stream, op_rw, &payload);

    var i: u16 = 0;
    while (i < 3) : (i += 1) {
        try setDesc(ram, rx_desc, i, rx_bufs + @as(u64, i) * 0x200, rx_buf_len, 2); // VIRTQ_DESC_F_WRITE
        try pushAvail(ram, rx_avail, 8, i);
    }
    try std.testing.expect(t.write(0x050, rx_queue, ram));

    // All three buffers hold one op_rw fragment each; nothing is dropped.
    try std.testing.expectEqual(@as(u16, 3), try ram.read(u16, rx_used + 2));

    var received: [250]u8 = undefined;
    var received_len: usize = 0;
    i = 0;
    while (i < 3) : (i += 1) {
        const base = rx_bufs + @as(u64, i) * 0x200;
        const fragment = parseHeader(buf[base..][0..header_len]);
        try std.testing.expectEqual(op_rw, fragment.op);
        try std.testing.expectEqual(host_cid, fragment.src_cid);
        try std.testing.expectEqual(default_guest_cid, fragment.dst_cid);
        const fragment_len: usize = @intCast(fragment.len);
        try std.testing.expect(fragment_len > 0);
        try std.testing.expect(received_len + fragment_len <= payload.len);
        @memcpy(received[received_len..][0..fragment_len], buf[base + header_len ..][0..fragment_len]);
        received_len += fragment_len;
    }
    try std.testing.expectEqual(payload.len, received_len);
    try std.testing.expectEqualSlices(u8, &payload, &received);
    try std.testing.expectEqual(@as(usize, 0), dev.pending_len);
}

test "rx delivery makes no empty fragments for header-only guest buffers" {
    var dev = Vsock.init(.{ .guest_cid = default_guest_cid });
    var t = mmio.Transport.init(dev.device());
    var buf: [32 * 1024]u8 = @splat(0);
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    const rx_desc = 0x000;
    const rx_avail = 0x400;
    const rx_used = 0x800;
    const rx_buf_tiny = 0x2000;
    const rx_buf_ok = 0x2200;

    configureQueue(&t, rx_queue, rx_desc, rx_avail, rx_used, ram);

    var stream = try HostStream.init(10700, "{}\n");
    stream.state = .connected;
    dev.host_stream = &stream;

    try dev.enqueueHostPacket(&stream, op_rw, "hello");

    // A buffer holding exactly the packet header would only fit an empty
    // fragment; the packet must stay pending until a useful buffer arrives.
    try setDesc(ram, rx_desc, 0, rx_buf_tiny, header_len, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 0);
    try setDesc(ram, rx_desc, 1, rx_buf_ok, header_len + 5, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 1);
    try std.testing.expect(t.write(0x050, rx_queue, ram));

    try std.testing.expectEqual(@as(u16, 2), try ram.read(u16, rx_used + 2));
    const delivered = parseHeader(buf[rx_buf_ok..][0..header_len]);
    try std.testing.expectEqual(op_rw, delivered.op);
    try std.testing.expectEqual(@as(u32, 5), delivered.len);
    try std.testing.expectEqualStrings("hello", buf[rx_buf_ok + header_len ..][0..5]);
    try std.testing.expectEqual(@as(usize, 0), dev.pending_len);
}

test "rx delivery keeps packets pending when a guest buffer cannot hold the header" {
    var dev = Vsock.init(.{ .guest_cid = default_guest_cid });
    var t = mmio.Transport.init(dev.device());
    var buf: [32 * 1024]u8 = @splat(0);
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    const rx_desc = 0x000;
    const rx_avail = 0x400;
    const rx_used = 0x800;
    const rx_buf_small = 0x2000;
    const rx_buf_ok = 0x2200;

    configureQueue(&t, rx_queue, rx_desc, rx_avail, rx_used, ram);

    var stream = try HostStream.init(10700, "{}\n");
    stream.state = .connected;
    dev.host_stream = &stream;

    try dev.enqueueHostPacket(&stream, op_rw, "hello");

    // First buffer cannot even hold the 44-byte packet header; the packet must
    // survive and land in the next adequate buffer.
    try setDesc(ram, rx_desc, 0, rx_buf_small, header_len - 1, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 0);
    try setDesc(ram, rx_desc, 1, rx_buf_ok, header_len + 5, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 1);
    try std.testing.expect(t.write(0x050, rx_queue, ram));

    try std.testing.expectEqual(@as(u16, 2), try ram.read(u16, rx_used + 2));
    const delivered = parseHeader(buf[rx_buf_ok..][0..header_len]);
    try std.testing.expectEqual(op_rw, delivered.op);
    try std.testing.expectEqual(@as(u32, 5), delivered.len);
    try std.testing.expectEqualStrings("hello", buf[rx_buf_ok + header_len ..][0..5]);
    try std.testing.expectEqual(@as(usize, 0), dev.pending_len);
}

test "host proactively updates credit while consuming guest stream data" {
    var dev = Vsock.init(.{ .guest_cid = default_guest_cid });
    var t = mmio.Transport.init(dev.device());
    var buf = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(buf);
    @memset(buf, 0);
    const ram = guestmem.GuestRam{ .bytes = buf, .base = 0 };

    const rx_desc = 0x000;
    const rx_avail = 0x400;
    const rx_used = 0x800;
    const tx_desc = 0x1000;
    const tx_avail = 0x1400;
    const tx_used = 0x1800;
    const rx_buf = 0x2000;
    const tx_buf = 0x2200;

    configureQueue(&t, rx_queue, rx_desc, rx_avail, rx_used, ram);
    configureQueue(&t, tx_queue, tx_desc, tx_avail, tx_used, ram);

    var stream = try HostStream.init(10700, "{}\n");
    stream.state = .connected;
    dev.host_stream = &stream;

    // Each packet is one whole SPIO stdout frame the parser consumes.
    var payload: [4096]u8 = undefined;
    const frame_data_len = payload.len - spore_stream.header_len;
    @memset(payload[spore_stream.header_len..], 'x');

    // The guest sends half the advertised credit without the host ever writing
    // back; the host must volunteer a credit update or the guest stalls.
    var header: [header_len]u8 = undefined;
    var sent: usize = 0;
    var head: u16 = 0;
    while (sent < host_stream_credit / 2) : (head += 1) {
        spore_stream.writeHeader(payload[0..spore_stream.header_len], .{
            .frame_type = .data,
            .stream_id = .stdout,
            .offset = head * frame_data_len,
            .payload_len = frame_data_len,
        });
        writeHeader(&header, .{
            .src_cid = default_guest_cid,
            .dst_cid = host_cid,
            .src_port = 10700,
            .dst_port = vsock_stream.default_host_port,
            .len = payload.len,
            .packet_type = packet_type_stream,
            .op = op_rw,
        });
        @memcpy(buf[tx_buf..][0..header_len], &header);
        @memcpy(buf[tx_buf + header_len ..][0..payload.len], &payload);
        try setDesc(ram, tx_desc, head % 8, tx_buf, header_len + payload.len, 0);
        try pushAvail(ram, tx_avail, 8, head % 8);
        try std.testing.expect(t.write(0x050, tx_queue, ram));
        sent += payload.len;
    }
    try std.testing.expectEqual(vsock_stream.HostStreamState.connected, stream.state);

    try setDesc(ram, rx_desc, 0, rx_buf, header_len, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 0);
    try std.testing.expect(t.write(0x050, rx_queue, ram));

    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, rx_used + 2));
    const update = parseHeader(buf[rx_buf..][0..header_len]);
    try std.testing.expectEqual(op_credit_update, update.op);
    try std.testing.expectEqual(@as(u32, host_stream_credit), update.buf_alloc);
    try std.testing.expectEqual(@as(u32, host_stream_credit / 2), update.fwd_cnt);
}

test "a guest packet reaches the host stream only when its chain holds its whole payload of at most 64 KiB" {
    // Linux puts the header and the payload in separate descriptors.
    const cases = [_]struct { len: u32, payload_desc_len: u32, delivered: bool }{
        .{ .len = max_tx_payload, .payload_desc_len = max_tx_payload, .delivered = true },
        .{ .len = max_tx_payload + 1, .payload_desc_len = max_tx_payload + 1, .delivered = false },
        .{ .len = max_tx_payload, .payload_desc_len = max_tx_payload - 1, .delivered = false },
    };
    const buf = try std.testing.allocator.alloc(u8, 160 * 1024);
    defer std.testing.allocator.free(buf);
    const ram = guestmem.GuestRam{ .bytes = buf, .base = 0 };
    const tx_desc = 0x1000;
    const tx_avail = 0x1400;
    const tx_used = 0x1800;
    const header_buf = 0x2000;
    const payload_buf = 0x3000;

    for (cases) |case| {
        @memset(buf, 0);
        var dev = Vsock.init(.{ .guest_cid = default_guest_cid });
        var t = mmio.Transport.init(dev.device());
        configureQueue(&t, rx_queue, 0x000, 0x400, 0x800, ram);
        configureQueue(&t, tx_queue, tx_desc, tx_avail, tx_used, ram);
        var stream = try HostStream.init(10700, "{}\n");
        stream.state = .connected;
        dev.host_stream = &stream;

        // 64 KiB of stdout frames, as the guest agent writes them at once.
        const payload = buf[payload_buf..][0..max_tx_payload];
        var frame_start: usize = 0;
        var data_len: u64 = 0;
        while (frame_start < payload.len) {
            const len = @min(spore_stream.max_payload_len, payload.len - frame_start - spore_stream.header_len);
            spore_stream.writeHeader(payload[frame_start..][0..spore_stream.header_len], .{
                .frame_type = .data,
                .stream_id = .stdout,
                .offset = data_len,
                .payload_len = @intCast(len),
            });
            @memset(payload[frame_start + spore_stream.header_len ..][0..len], 'x');
            frame_start += spore_stream.header_len + len;
            data_len += len;
        }
        writeHeader(buf[header_buf..][0..header_len], .{
            .src_cid = default_guest_cid,
            .dst_cid = host_cid,
            .src_port = 10700,
            .dst_port = vsock_stream.default_host_port,
            .len = case.len,
            .packet_type = packet_type_stream,
            .op = op_rw,
        });
        try setDesc(ram, tx_desc, 0, header_buf, header_len, 1); // VIRTQ_DESC_F_NEXT
        try ram.write(u16, tx_desc + 14, 1);
        try setDesc(ram, tx_desc, 1, payload_buf, case.payload_desc_len, 0);
        try pushAvail(ram, tx_avail, 8, 0);
        try std.testing.expect(t.write(0x050, tx_queue, ram));

        // The device returns the chain either way, and never delivers part
        // of a packet.
        try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, tx_used + 2));
        try std.testing.expectEqual(vsock_stream.HostStreamState.connected, stream.state);
        try std.testing.expectEqual(if (case.delivered) data_len else 0, stream.stdout_offset);
        try std.testing.expectEqual(if (case.delivered) case.len else 0, stream.received_bytes);
    }
}

test "host defers stream data until the guest advertises credit" {
    var dev = Vsock.init(.{ .guest_cid = default_guest_cid });
    var t = mmio.Transport.init(dev.device());
    var buf: [32 * 1024]u8 = @splat(0);
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    const rx_desc = 0x000;
    const rx_avail = 0x400;
    const rx_used = 0x800;
    const tx_desc = 0x1000;
    const tx_avail = 0x1400;
    const tx_used = 0x1800;
    const rx_buf = 0x2000;
    const rx_buf_second = 0x2400;
    const tx_buf = 0x2800;

    configureQueue(&t, rx_queue, rx_desc, rx_avail, rx_used, ram);
    configureQueue(&t, tx_queue, tx_desc, tx_avail, tx_used, ram);

    var stream = try HostStream.init(10700, "{}\n");
    stream.state = .connected;
    stream.request_sent = true;
    // The guest has advertised only 8 bytes of receive buffer.
    stream.peer_buf_alloc = 8;
    dev.host_stream = &stream;

    var stop = std.atomic.Value(bool).init(false);
    try std.testing.expect(try stream.enqueueStdinDataBlocking("hello", &stop));

    try setDesc(ram, rx_desc, 0, rx_buf, 0x200, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 0);
    _ = t.write(0x050, rx_queue, ram);
    _ = try dev.flushHostStreamOutbound();
    _ = t.write(0x050, rx_queue, ram);

    // The stdin frame exceeds the guest's window, so nothing may be sent yet.
    try std.testing.expectEqual(@as(u16, 0), try ram.read(u16, rx_used + 2));

    // The guest consumes its buffer and advertises a realistic window.
    var credit: [header_len]u8 = undefined;
    writeHeader(&credit, .{
        .src_cid = default_guest_cid,
        .dst_cid = host_cid,
        .src_port = 10700,
        .dst_port = vsock_stream.default_host_port,
        .len = 0,
        .packet_type = packet_type_stream,
        .op = op_credit_update,
        .buf_alloc = 64 * 1024,
        .fwd_cnt = 0,
    });
    @memcpy(buf[tx_buf..][0..header_len], &credit);
    try setDesc(ram, tx_desc, 0, tx_buf, header_len, 0);
    try pushAvail(ram, tx_avail, 8, 0);
    try setDesc(ram, rx_desc, 1, rx_buf_second, 0x200, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 1);
    try std.testing.expect(t.write(0x050, tx_queue, ram));

    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, rx_used + 2));
    const delivered = parseHeader(buf[rx_buf..][0..header_len]);
    try std.testing.expectEqual(op_rw, delivered.op);
    const frame_len = spore_stream.header_len + 5;
    try std.testing.expectEqual(@as(u32, frame_len), delivered.len);
    try std.testing.expectEqualStrings("hello", buf[rx_buf + header_len + spore_stream.header_len ..][0..5]);
}

test "completed host stream reset drops stale packets before next attach" {
    var dev = Vsock.init(.{ .guest_cid = default_guest_cid });
    var completed = try HostStream.init(10700, "first\n");
    completed.host_port = HostStream.hostPortForSequence(0x1234);
    completed.state = .complete;
    dev.host_stream = &completed;
    try dev.enqueueHostPacket(&completed, op_credit_update, "");
    try std.testing.expectEqual(@as(usize, 1), dev.pending_len);

    dev.resetHostStream();
    try std.testing.expect(dev.host_stream == null);
    try std.testing.expectEqual(@as(usize, 0), dev.pending_len);

    var next = try HostStream.init(10700, "second\n");
    next.host_port = HostStream.hostPortForSequence(0x1235);
    try dev.attachHostStream(&next);
    try std.testing.expectEqual(@as(usize, 1), dev.pending_len);
    try std.testing.expectEqual(op_request, dev.pending[0].header.op);
    try std.testing.expectEqual(next.host_port, dev.pending[0].header.src_port);
    try std.testing.expect(next.host_port != completed.host_port);
}

fn fuzzVsockTx(_: void, s: *std.testing.Smith) !void {
    var dev = Vsock.init(.{});
    var t = mmio.Transport.init(dev.device());
    var buf: [4096]u8 = @splat(0);
    _ = s.slice(&buf);
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };
    t.queues[rx_queue] = .{ .size = 8, .ready = true, .desc_addr = 0x1000, .avail_addr = 0x1200, .used_addr = 0x1400 };
    t.queues[tx_queue] = .{ .size = 8, .ready = true, .desc_addr = 0x0000, .avail_addr = 0x0400, .used_addr = 0x0800 };

    // Packets addressed to the host stream feed its frame parser.
    var stream = HostStream.init(10700, "{}\n") catch return;
    stream.state = .connected;
    dev.host_stream = &stream;
    _ = t.write(0x050, tx_queue, ram);
}

test "fuzz vsock tx handling" {
    try std.testing.fuzz({}, fuzzVsockTx, .{});
}

fn fuzzVsockRxDelivery(_: void, s: *std.testing.Smith) !void {
    var dev = Vsock.init(.{});
    var t = mmio.Transport.init(dev.device());
    var buf: [8192]u8 = @splat(0);
    _ = s.slice(&buf);
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };
    t.queues[rx_queue] = .{ .size = 8, .ready = true, .desc_addr = 0x1000, .avail_addr = 0x1200, .used_addr = 0x1400 };
    t.queues[tx_queue] = .{ .size = 8, .ready = true, .desc_addr = 0x0000, .avail_addr = 0x0400, .used_addr = 0x0800 };

    var stream = HostStream.init(10700, "{}\n") catch return;
    stream.state = .connected;
    dev.host_stream = &stream;

    var payload: [max_payload]u8 = undefined;
    const payload_len: usize = s.valueRangeAtMost(u16, 0, max_payload);
    @memset(payload[0..payload_len], 0xa5);
    dev.enqueueHostPacket(&stream, op_rw, payload[0..payload_len]) catch return;

    // Guest-controlled descriptor layouts drive the RX split path.
    _ = t.write(0x050, rx_queue, ram);
    _ = t.write(0x050, rx_queue, ram);
}

test "fuzz vsock rx delivery splitting" {
    try std.testing.fuzz({}, fuzzVsockRxDelivery, .{});
}
