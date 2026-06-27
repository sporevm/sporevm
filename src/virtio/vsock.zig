//! Virtio socket device (virtio spec 1.2 §5.10).
//!
//! Queue 0 is receive, queue 1 is transmit, queue 2 is event. This first
//! product slice keeps the endpoint deliberately small: the default behavior
//! still rejects guest-initiated host connections, while benchmark harnesses can
//! attach one host-initiated stream to a guest listener.
//! Packet headers, queue descriptors, payload lengths, and rings are guest
//! controlled. See SECURITY.md.

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
const op_response: u16 = 2;
const op_rst: u16 = 3;
const op_shutdown: u16 = 4;
const op_rw: u16 = 5;
const op_credit_update: u16 = 6;
const op_credit_request: u16 = 7;

const max_pending = 16;
const max_payload = 8192;
const host_stream_credit = 64 * 1024;
const max_frame_header = 128;
const max_frame_payload = 64 * 1024;
const default_host_port: u32 = 49152;
const dynamic_host_port_first: u32 = 49154;
const dynamic_host_port_count: u32 = 65535 - dynamic_host_port_first + 1;

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
    data: [max_payload]u8 = [_]u8{0} ** max_payload,
    data_len: usize = 0,
};

pub const HostStreamState = enum {
    idle,
    connecting,
    connected,
    complete,
    failed,
};

pub const HostStreamOutput = enum {
    stdout,
    stderr,
};

pub const HostStreamOutputSink = *const fn (context: ?*anyopaque, output: HostStreamOutput, bytes: []const u8) void;

pub const HostStreamLifecycle = enum {
    ready,
};

pub const HostStreamLifecycleSink = *const fn (context: ?*anyopaque, event: HostStreamLifecycle) void;

pub const HostStream = struct {
    guest_port: u32,
    host_port: u32 = default_host_port,
    request: [max_payload]u8 = [_]u8{0} ** max_payload,
    request_len: usize = 0,
    state: HostStreamState = .idle,
    started_at_ms: u64 = 0,
    start_ms: ?u64 = null,
    attach_ms: ?u64 = null,
    connect_request_delivered_ms: ?u64 = null,
    connect_ms: ?u64 = null,
    request_delivered_ms: ?u64 = null,
    memory_ready_ms: ?u64 = null,
    first_output_ms: ?u64 = null,
    response_ms: ?u64 = null,
    guest_timing_ms: ?u64 = null,
    received_bytes: u32 = 0,
    sent_bytes: u32 = 0,
    exit_code: ?i32 = null,
    header_buf: [max_frame_header]u8 = undefined,
    header_len: usize = 0,
    payload_output: ?HostStreamOutput = null,
    payload_remaining: usize = 0,
    stdout_offset: u64 = 0,
    stderr_offset: u64 = 0,
    output_sink: ?HostStreamOutputSink = null,
    output_sink_context: ?*anyopaque = null,
    lifecycle_sink: ?HostStreamLifecycleSink = null,
    lifecycle_sink_context: ?*anyopaque = null,

    pub fn init(guest_port: u32, request: []const u8) !HostStream {
        if (request.len > max_payload) return error.RequestTooLarge;
        var stream = HostStream{ .guest_port = guest_port };
        @memcpy(stream.request[0..request.len], request);
        stream.request_len = request.len;
        stream.started_at_ms = monotonicMs();
        stream.state = .connecting;
        return stream;
    }

    pub fn deriveHostPort(request: []const u8) u32 {
        return dynamic_host_port_first + @as(u32, @intCast(std.hash.Wyhash.hash(0, request) % dynamic_host_port_count));
    }

    pub fn markStarted(self: *HostStream) void {
        self.started_at_ms = monotonicMs();
        self.start_ms = self.elapsedMs();
    }

    fn markAttached(self: *HostStream) void {
        if (self.attach_ms == null) self.attach_ms = self.elapsedMs();
    }

    fn markConnectRequestDelivered(self: *HostStream) void {
        if (self.connect_request_delivered_ms == null) self.connect_request_delivered_ms = self.elapsedMs();
    }

    fn markRequestDelivered(self: *HostStream) void {
        if (self.request_delivered_ms == null) self.request_delivered_ms = self.elapsedMs();
    }

    pub fn setOutputSink(self: *HostStream, context: ?*anyopaque, sink: HostStreamOutputSink) void {
        self.output_sink_context = context;
        self.output_sink = sink;
    }

    pub fn setLifecycleSink(self: *HostStream, context: ?*anyopaque, sink: HostStreamLifecycleSink) void {
        self.lifecycle_sink_context = context;
        self.lifecycle_sink = sink;
    }

    pub fn elapsedMs(self: *const HostStream) u64 {
        const now = monotonicMs();
        if (now < self.started_at_ms) return 0;
        return now - self.started_at_ms;
    }

    fn markConnected(self: *HostStream) void {
        if (self.connect_ms == null) self.connect_ms = self.elapsedMs();
        self.state = .connected;
        if (self.lifecycle_sink) |sink| sink(self.lifecycle_sink_context, .ready);
    }

    fn appendOutput(self: *HostStream, data: []const u8) void {
        const inc: u32 = if (data.len > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(data.len);
        self.received_bytes +|= inc;

        var rest = data;
        while (rest.len > 0 and self.state != .failed and self.state != .complete) {
            if (self.payload_output) |output| {
                const take = @min(rest.len, self.payload_remaining);
                self.emitOutput(output, rest[0..take]);
                self.payload_remaining -= take;
                rest = rest[take..];
                if (self.payload_remaining == 0) self.payload_output = null;
                continue;
            }

            if (std.mem.indexOfScalar(u8, rest, '\n')) |newline| {
                if (self.header_len + newline > self.header_buf.len) {
                    self.fail();
                    return;
                }
                @memcpy(self.header_buf[self.header_len..][0..newline], rest[0..newline]);
                self.header_len += newline;
                const line = self.header_buf[0..self.header_len];
                self.header_len = 0;
                self.handleFrameHeader(line);
                rest = rest[newline + 1 ..];
            } else {
                if (self.header_len + rest.len > self.header_buf.len) {
                    self.fail();
                    return;
                }
                @memcpy(self.header_buf[self.header_len..][0..rest.len], rest);
                self.header_len += rest.len;
                return;
            }
        }
    }

    fn handleFrameHeader(self: *HostStream, line: []const u8) void {
        var fields = std.mem.splitScalar(u8, line, ' ');
        const kind = fields.next() orelse {
            self.fail();
            return;
        };
        if (std.mem.eql(u8, kind, "stdout") or std.mem.eql(u8, kind, "stderr")) {
            const offset_raw = fields.next() orelse {
                self.fail();
                return;
            };
            const len_raw = fields.next() orelse {
                self.fail();
                return;
            };
            if (fields.next() != null) {
                self.fail();
                return;
            }
            const offset = std.fmt.parseInt(u64, offset_raw, 10) catch {
                self.fail();
                return;
            };
            const len = std.fmt.parseInt(usize, len_raw, 10) catch {
                self.fail();
                return;
            };
            if (len > max_frame_payload) {
                self.fail();
                return;
            }
            const output: HostStreamOutput = if (std.mem.eql(u8, kind, "stdout")) .stdout else .stderr;
            const expected = switch (output) {
                .stdout => self.stdout_offset,
                .stderr => self.stderr_offset,
            };
            if (offset != expected) {
                self.fail();
                return;
            }
            self.payload_output = output;
            self.payload_remaining = len;
            if (len == 0) self.payload_output = null;
            return;
        }
        if (std.mem.eql(u8, kind, "exit")) {
            const code_raw = fields.next() orelse {
                self.fail();
                return;
            };
            if (fields.next() != null) {
                self.fail();
                return;
            }
            const code = std.fmt.parseInt(i32, code_raw, 10) catch {
                self.fail();
                return;
            };
            if (code < 0 or code > 255) {
                self.fail();
                return;
            }
            self.exit_code = code;
            if (self.response_ms == null) self.response_ms = self.elapsedMs();
            self.state = .complete;
            return;
        }
        if (std.mem.eql(u8, kind, "timing")) {
            if (self.guest_timing_ms == null) self.guest_timing_ms = self.elapsedMs();
            std.log.debug("vsock host stream guest timing: {s}", .{line});
            return;
        }
        if (std.mem.eql(u8, kind, "memory-ready")) {
            if (self.memory_ready_ms == null) self.memory_ready_ms = self.elapsedMs();
            return;
        }
        self.fail();
    }

    fn emitOutput(self: *HostStream, output: HostStreamOutput, data: []const u8) void {
        if (data.len == 0) return;
        if (self.first_output_ms == null) self.first_output_ms = self.elapsedMs();
        if (self.output_sink) |sink| sink(self.output_sink_context, output, data);
        const len: u64 = @intCast(data.len);
        switch (output) {
            .stdout => self.stdout_offset += len,
            .stderr => self.stderr_offset += len,
        }
    }

    fn fail(self: *HostStream) void {
        self.state = .failed;
        if (self.response_ms == null) self.response_ms = self.elapsedMs();
    }
};

pub const ControlAction = union(enum) {
    keep_running,
    stop,
    snapshot: SnapshotAction,
};

pub const SnapshotAction = struct {
    dir: []const u8,
    continue_after: bool = false,
};

pub const Wake = struct {
    context: *anyopaque,
    wakeFn: *const fn (context: *anyopaque) void,

    pub fn wake(self: Wake) void {
        self.wakeFn(self.context);
    }
};

pub const Control = struct {
    context: *anyopaque,
    pollFn: *const fn (context: *anyopaque, dev: *Vsock) anyerror!ControlAction,
    setWakeFn: *const fn (context: *anyopaque, wake: Wake) void,
    completeSnapshotFn: *const fn (context: *anyopaque, dir: []const u8) anyerror!void,

    pub fn poll(self: Control, dev: *Vsock) !ControlAction {
        return self.pollFn(self.context, dev);
    }

    pub fn setWake(self: Control, wake: Wake) void {
        self.setWakeFn(self.context, wake);
    }

    pub fn completeSnapshot(self: Control, dir: []const u8) !void {
        try self.completeSnapshotFn(self.context, dir);
    }
};

fn monotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

pub const Vsock = struct {
    guest_cid: u64,
    pending: [max_pending]Packet = undefined,
    pending_len: usize = 0,
    host_stream: ?*HostStream = null,

    pub fn init(config: Config) Vsock {
        return .{ .guest_cid = config.guest_cid };
    }

    pub fn attachHostStream(self: *Vsock, stream: *HostStream) !void {
        self.host_stream = stream;
        stream.markAttached();
        try self.enqueueHostConnectRequest(stream);
    }

    pub fn flushPendingRx(self: *Vsock, queues: *[mmio.max_queues]queue.VirtQueue, ram: guestmem.GuestRam) bool {
        return self.flushRx(&queues[rx_queue], ram);
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
            if (parsePacketFromChain(&chain)) |packet| {
                self.handleGuestPacket(packet.header, packet.data[0..packet.data_len]);
            }
            tx.pushUsed(ram, chain.head, 0) catch return did_work;
            did_work = true;
        }
        return self.flushRx(&queues[rx_queue], ram) or did_work;
    }

    fn handleGuestPacket(self: *Vsock, h: Header, payload: []const u8) void {
        if (h.packet_type != packet_type_stream) return;

        if (self.host_stream) |stream| {
            const matches_host_stream =
                h.src_cid == self.guest_cid and
                h.dst_cid == host_cid and
                h.src_port == stream.guest_port and
                h.dst_port == stream.host_port;
            if (matches_host_stream) {
                self.handleHostStreamPacket(stream, h, payload);
                return;
            }
        }

        if (h.op != op_request or h.packet_type != packet_type_stream) return;
        if (h.dst_cid != host_cid or h.src_cid != self.guest_cid) return;
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

    fn handleHostStreamPacket(self: *Vsock, stream: *HostStream, h: Header, payload: []const u8) void {
        switch (h.op) {
            op_response => {
                if (stream.state == .connecting) {
                    stream.markConnected();
                    self.enqueueHostPacket(stream, op_rw, stream.request[0..stream.request_len]) catch stream.fail();
                }
            },
            op_rw => {
                stream.appendOutput(payload);
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
        const inc: u32 = if (payload.len > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(payload.len);
        stream.sent_bytes +|= inc;
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

    fn flushRx(self: *Vsock, rx: *queue.VirtQueue, ram: guestmem.GuestRam) bool {
        var did_work = false;
        while (self.pending_len > 0) {
            const maybe_chain = rx.popAvail(ram) catch return did_work;
            const chain = maybe_chain orelse break;
            const packet = self.pending[0];
            const written = writePacketToChain(&chain, packet.header, packet.data[0..packet.data_len]) orelse 0;
            chain.markWritableDirty(ram);
            rx.pushUsed(ram, chain.head, written) catch return did_work;
            self.recordHostDelivery(packet.header);
            self.dropFirstPending();
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

fn parsePacketFromChain(chain: *const queue.Chain) ?Packet {
    var buf: [header_len]u8 = undefined;
    if (!copyReadablePrefix(chain, &buf)) return null;
    const header = parseHeader(&buf);
    if (header.len > max_payload) return null;
    const data_len: usize = @intCast(header.len);
    var packet = Packet{ .header = header, .data_len = data_len };
    if (data_len > 0 and !copyReadableRange(chain, header_len, packet.data[0..data_len])) return null;
    return packet;
}

fn copyReadablePrefix(chain: *const queue.Chain, out: []u8) bool {
    return copyReadableRange(chain, 0, out);
}

fn copyReadableRange(chain: *const queue.Chain, skip: usize, out: []u8) bool {
    if (out.len == 0) return true;
    var skipped: usize = 0;
    var copied: usize = 0;
    for (chain.segments.slice()) |seg| {
        if (seg.writable) continue;
        if (skipped + seg.data.len <= skip) {
            skipped += seg.data.len;
            continue;
        }
        const offset = if (skip > skipped) skip - skipped else 0;
        const readable = seg.data[offset..];
        const n = @min(readable.len, out.len - copied);
        @memcpy(out[copied..][0..n], readable[0..n]);
        copied += n;
        if (copied == out.len) return true;
        skipped += seg.data.len;
    }
    return false;
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

const StreamCapture = struct {
    stdout: [64]u8 = [_]u8{0} ** 64,
    stderr: [64]u8 = [_]u8{0} ** 64,
    stdout_len: usize = 0,
    stderr_len: usize = 0,
    ready_count: usize = 0,
};

fn captureSink(context: ?*anyopaque, output: HostStreamOutput, bytes: []const u8) void {
    const capture: *StreamCapture = @ptrCast(@alignCast(context.?));
    switch (output) {
        .stdout => {
            const n = @min(bytes.len, capture.stdout.len - capture.stdout_len);
            if (n > 0) {
                @memcpy(capture.stdout[capture.stdout_len..][0..n], bytes[0..n]);
                capture.stdout_len += n;
            }
        },
        .stderr => {
            const n = @min(bytes.len, capture.stderr.len - capture.stderr_len);
            if (n > 0) {
                @memcpy(capture.stderr[capture.stderr_len..][0..n], bytes[0..n]);
                capture.stderr_len += n;
            }
        },
    }
}

fn lifecycleSink(context: ?*anyopaque, event: HostStreamLifecycle) void {
    const capture: *StreamCapture = @ptrCast(@alignCast(context.?));
    switch (event) {
        .ready => capture.ready_count += 1,
    }
}

test "host stream connects, sends request, and parses streamed frames" {
    var dev = Vsock.init(.{ .guest_cid = default_guest_cid });
    var t = mmio.Transport.init(dev.device());
    var buf: [32 * 1024]u8 = [_]u8{0} ** (32 * 1024);
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

    const request = "{\"command\":[\"/bin/true\"],\"closed_env\":true}\n";
    var stream = try HostStream.init(10700, request);
    var capture = StreamCapture{};
    stream.setOutputSink(&capture, captureSink);
    stream.setLifecycleSink(&capture, lifecycleSink);
    try dev.attachHostStream(&stream);

    try setDesc(ram, rx_desc, 0, rx_buf_request, header_len, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 0);
    try std.testing.expect(t.write(0x050, rx_queue, ram));
    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, rx_used + 2));

    const connect = parseHeader(buf[rx_buf_request..][0..header_len]);
    try std.testing.expectEqual(host_cid, connect.src_cid);
    try std.testing.expectEqual(default_guest_cid, connect.dst_cid);
    try std.testing.expectEqual(default_host_port, connect.src_port);
    try std.testing.expectEqual(@as(u32, 10700), connect.dst_port);
    try std.testing.expectEqual(op_request, connect.op);

    try setDesc(ram, rx_desc, 1, rx_buf_retry, header_len, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 1);

    var rst: [header_len]u8 = undefined;
    writeHeader(&rst, .{
        .src_cid = default_guest_cid,
        .dst_cid = host_cid,
        .src_port = 10700,
        .dst_port = default_host_port,
        .len = 0,
        .packet_type = packet_type_stream,
        .op = op_rst,
    });
    @memcpy(buf[tx_buf_rst..][0..header_len], &rst);
    try setDesc(ram, tx_desc, 0, tx_buf_rst, header_len, 0);
    try pushAvail(ram, tx_avail, 8, 0);
    try std.testing.expect(t.write(0x050, tx_queue, ram));
    try std.testing.expectEqual(HostStreamState.connecting, stream.state);
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
        .dst_port = default_host_port,
        .len = 0,
        .packet_type = packet_type_stream,
        .op = op_response,
    });
    @memcpy(buf[tx_buf_response..][0..header_len], &response);
    try setDesc(ram, tx_desc, 1, tx_buf_response, header_len, 0);
    try pushAvail(ram, tx_avail, 8, 1);
    try std.testing.expect(t.write(0x050, tx_queue, ram));
    try std.testing.expectEqual(HostStreamState.connected, stream.state);
    try std.testing.expectEqual(@as(usize, 1), capture.ready_count);
    try std.testing.expectEqual(@as(u16, 3), try ram.read(u16, rx_used + 2));

    const delivered = parseHeader(buf[rx_buf_payload..][0..header_len]);
    try std.testing.expectEqual(op_rw, delivered.op);
    try std.testing.expectEqual(@as(u32, @intCast(request.len)), delivered.len);
    try std.testing.expectEqualStrings(request, buf[rx_buf_payload + header_len ..][0..request.len]);

    const stdout_frame = "stdout 0 6\nhello\n";
    var stdout_rw: [header_len]u8 = undefined;
    writeHeader(&stdout_rw, .{
        .src_cid = default_guest_cid,
        .dst_cid = host_cid,
        .src_port = 10700,
        .dst_port = default_host_port,
        .len = @intCast(stdout_frame.len),
        .packet_type = packet_type_stream,
        .op = op_rw,
    });
    @memcpy(buf[tx_buf_stdout..][0..header_len], &stdout_rw);
    @memcpy(buf[tx_buf_stdout + header_len ..][0..stdout_frame.len], stdout_frame);
    try setDesc(ram, tx_desc, 2, tx_buf_stdout, @intCast(header_len + stdout_frame.len), 0);
    try pushAvail(ram, tx_avail, 8, 2);
    try std.testing.expect(t.write(0x050, tx_queue, ram));

    const stderr_frame = "stderr 0 4\nerr\n";
    var stderr_rw: [header_len]u8 = undefined;
    writeHeader(&stderr_rw, .{
        .src_cid = default_guest_cid,
        .dst_cid = host_cid,
        .src_port = 10700,
        .dst_port = default_host_port,
        .len = @intCast(stderr_frame.len),
        .packet_type = packet_type_stream,
        .op = op_rw,
    });
    @memcpy(buf[tx_buf_stderr..][0..header_len], &stderr_rw);
    @memcpy(buf[tx_buf_stderr + header_len ..][0..stderr_frame.len], stderr_frame);
    try setDesc(ram, tx_desc, 3, tx_buf_stderr, @intCast(header_len + stderr_frame.len), 0);
    try pushAvail(ram, tx_avail, 8, 3);
    try std.testing.expect(t.write(0x050, tx_queue, ram));

    const exit_frame = "exit 7\n";
    var rw: [header_len]u8 = undefined;
    writeHeader(&rw, .{
        .src_cid = default_guest_cid,
        .dst_cid = host_cid,
        .src_port = 10700,
        .dst_port = default_host_port,
        .len = @intCast(exit_frame.len),
        .packet_type = packet_type_stream,
        .op = op_rw,
    });
    @memcpy(buf[tx_buf_exit..][0..header_len], &rw);
    @memcpy(buf[tx_buf_exit + header_len ..][0..exit_frame.len], exit_frame);
    try setDesc(ram, tx_desc, 4, tx_buf_exit, @intCast(header_len + exit_frame.len), 0);
    try pushAvail(ram, tx_avail, 8, 4);
    try std.testing.expect(t.write(0x050, tx_queue, ram));

    try std.testing.expectEqual(HostStreamState.complete, stream.state);
    try std.testing.expectEqual(@as(i32, 7), stream.exit_code.?);
    try std.testing.expectEqualStrings("hello\n", capture.stdout[0..capture.stdout_len]);
    try std.testing.expectEqualStrings("err\n", capture.stderr[0..capture.stderr_len]);
}

test "request-derived host ports are stable dynamic ports" {
    const first = HostStream.deriveHostPort("{\"session_id\":\"run-a\"}\n");
    const again = HostStream.deriveHostPort("{\"session_id\":\"run-a\"}\n");
    const second = HostStream.deriveHostPort("{\"session_id\":\"run-b\"}\n");

    try std.testing.expect(first >= dynamic_host_port_first);
    try std.testing.expect(first < dynamic_host_port_first + dynamic_host_port_count);
    try std.testing.expectEqual(first, again);
    try std.testing.expect(first != second);
}

test "host stream frame parser handles split frames" {
    var stream = try HostStream.init(10700, "{}\n");
    var capture = StreamCapture{};
    stream.state = .connected;
    stream.setOutputSink(&capture, captureSink);

    stream.appendOutput("stdout 0 11\nhello");
    try std.testing.expectEqual(HostStreamState.connected, stream.state);
    stream.appendOutput(" worldstderr 0 4\n");
    stream.appendOutput("err\nmemory-ready\nexit 3\n");

    try std.testing.expectEqual(HostStreamState.complete, stream.state);
    try std.testing.expectEqual(@as(i32, 3), stream.exit_code.?);
    try std.testing.expect(stream.memory_ready_ms != null);
    try std.testing.expectEqualStrings("hello world", capture.stdout[0..capture.stdout_len]);
    try std.testing.expectEqualStrings("err\n", capture.stderr[0..capture.stderr_len]);
}

test "host stream frame parser is independent of two-part packetization" {
    const frames = "stdout 0 5\nhello" ++
        "stderr 0 4\nwarn" ++
        "exit 9\n";

    var split: usize = 0;
    while (split <= frames.len) : (split += 1) {
        var stream = try HostStream.init(10700, "{}\n");
        var capture = StreamCapture{};
        stream.state = .connected;
        stream.setOutputSink(&capture, captureSink);

        stream.appendOutput(frames[0..split]);
        stream.appendOutput(frames[split..]);

        try std.testing.expectEqual(HostStreamState.complete, stream.state);
        try std.testing.expectEqual(@as(i32, 9), stream.exit_code.?);
        try std.testing.expectEqualStrings("hello", capture.stdout[0..capture.stdout_len]);
        try std.testing.expectEqualStrings("warn", capture.stderr[0..capture.stderr_len]);
    }
}

test "host stream frame parser rejects offset mismatch" {
    var stream = try HostStream.init(10700, "{}\n");
    stream.state = .connected;

    stream.appendOutput("stdout 1 1\nx");

    try std.testing.expectEqual(HostStreamState.failed, stream.state);
}

test "host stream frame parser rejects oversized payloads" {
    var stream = try HostStream.init(10700, "{}\n");
    stream.state = .connected;

    stream.appendOutput("stderr 0 65537\n");

    try std.testing.expectEqual(HostStreamState.failed, stream.state);
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

fn fuzzHostStreamFrames(_: void, s: *std.testing.Smith) !void {
    var stream = try HostStream.init(10700, "{}\n");
    stream.state = .connected;
    var buf: [4096]u8 = undefined;
    const len = s.slice(&buf);
    stream.appendOutput(buf[0..len]);
}

test "fuzz host stream frame parsing" {
    try std.testing.fuzz({}, fuzzHostStreamFrames, .{});
}
