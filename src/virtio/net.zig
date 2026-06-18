//! Virtio network device (virtio spec 1.2 §5.1), minimal frame endpoint.
//!
//! Queue 0 is receive and queue 1 is transmit. The default backend is still
//! closed, but the device now translates virtio-net buffers into complete
//! Ethernet frames for an internal backend. Queue descriptors, virtio-net
//! headers, and packet lengths are guest controlled. See SECURITY.md.

const std = @import("std");
const guestmem = @import("../guestmem.zig");
const queue = @import("queue.zig");
const mmio = @import("mmio.zig");

pub const device_id: u32 = 1;

const rx_queue = 0;
const tx_queue = 1;

/// VIRTIO_NET_F_MAC: config space contains the device MAC address.
const feature_mac: u64 = 1 << 5;
/// Linux uses the mergeable-RX-buffer layout size for virtio-net headers even
/// when the mergeable feature is not negotiated.
pub const header_len = 12;
pub const max_frame_len = 1514;

pub const default_mac: [6]u8 = .{ 0x02, 0x53, 0x50, 0x4f, 0x52, 0x45 }; // locally administered "SPORE"

pub const Config = struct {
    mac: [6]u8 = default_mac,
    backend: Backend = .{},
};

pub const Runtime = struct {
    backend: Backend = .{},
    context: ?*anyopaque = null,
    failedFn: *const fn (?*anyopaque) bool = healthy,
    setWakeFn: *const fn (?*anyopaque, Wake) void = ignoreWake,
    clearWakeFn: *const fn (?*anyopaque) void = ignoreClearWake,
    consumeWakeFn: *const fn (?*anyopaque) bool = noWake,

    pub fn failed(self: Runtime) bool {
        return self.failedFn(self.context);
    }

    pub fn setWake(self: Runtime, wake: Wake) void {
        self.setWakeFn(self.context, wake);
    }

    pub fn clearWake(self: Runtime) void {
        self.clearWakeFn(self.context);
    }

    pub fn consumeWake(self: Runtime) bool {
        return self.consumeWakeFn(self.context);
    }
};

pub const Wake = struct {
    context: ?*anyopaque = null,
    wakeFn: *const fn (?*anyopaque) void = noopWake,

    pub fn wake(self: Wake) void {
        self.wakeFn(self.context);
    }
};

pub const Backend = struct {
    context: ?*anyopaque = null,
    /// Receives one complete Ethernet frame. The frame slice is only valid for
    /// the duration of the call.
    transmitFn: *const fn (?*anyopaque, []const u8) void = dropTx,
    /// Returns the next pending Ethernet frame, if any. Non-null slices must
    /// remain stable until the matching `consumeRxFn` call.
    peekRxFn: *const fn (?*anyopaque) ?[]const u8 = noRx,
    /// Drops the frame currently returned by `peekRxFn`.
    consumeRxFn: *const fn (?*anyopaque) void = noop,
    resetFn: *const fn (?*anyopaque) void = noop,
    shutdownFn: *const fn (?*anyopaque) void = noop,

    pub fn transmit(self: Backend, frame: []const u8) void {
        self.transmitFn(self.context, frame);
    }

    pub fn peekRx(self: Backend) ?[]const u8 {
        return self.peekRxFn(self.context);
    }

    pub fn consumeRx(self: Backend) void {
        self.consumeRxFn(self.context);
    }

    pub fn reset(self: Backend) void {
        self.resetFn(self.context);
    }

    pub fn shutdown(self: Backend) void {
        self.shutdownFn(self.context);
    }
};

pub const Net = struct {
    mac: [6]u8,
    backend: Backend,
    tx_packets: u64 = 0,
    tx_bytes: u64 = 0,

    pub fn init(config: Config) Net {
        return .{ .mac = config.mac, .backend = config.backend };
    }

    pub fn device(self: *Net) mmio.Device {
        return .{
            .context = self,
            .device_id = device_id,
            .device_features = feature_mac,
            .queue_count = 2,
            .notifyFn = notify,
            .configReadFn = configRead,
            .resetFn = resetDevice,
        };
    }

    pub fn shutdown(self: *Net) void {
        self.backend.shutdown();
    }

    pub fn flushPendingRx(self: *Net, queues: *[mmio.max_queues]queue.VirtQueue, ram: guestmem.GuestRam) bool {
        return self.flushRx(&queues[rx_queue], ram);
    }

    fn configRead(ctx: *anyopaque, offset: u64) u32 {
        const self: *Net = @ptrCast(@alignCast(ctx));
        var out: u32 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const idx = offset + i;
            if (idx < self.mac.len) {
                out |= @as(u32, self.mac[@intCast(idx)]) << @intCast(8 * i);
            }
        }
        return out;
    }

    fn notify(ctx: *anyopaque, queue_index: u8, queues: *[mmio.max_queues]queue.VirtQueue, ram: guestmem.GuestRam) bool {
        const self: *Net = @ptrCast(@alignCast(ctx));
        return switch (queue_index) {
            tx_queue => blk: {
                const did_tx = self.drainTx(&queues[tx_queue], ram);
                break :blk self.flushRx(&queues[rx_queue], ram) or did_tx;
            },
            rx_queue => self.flushRx(&queues[rx_queue], ram),
            else => false,
        };
    }

    fn drainTx(self: *Net, tx: *queue.VirtQueue, ram: guestmem.GuestRam) bool {
        var did_work = false;
        var budget: usize = queue.max_queue_size;
        while (budget > 0) : (budget -= 1) {
            const maybe_chain = tx.popAvail(ram) catch return did_work;
            const chain = maybe_chain orelse break;
            var frame_buf: [max_frame_len]u8 = undefined;
            if (txFrameFromChain(&chain, &frame_buf)) |frame| {
                self.backend.transmit(frame);
                self.tx_packets +%= 1;
                self.tx_bytes +%= frame.len;
            }
            tx.pushUsed(ram, chain.head, 0) catch return did_work;
            did_work = true;
        }
        return did_work;
    }

    fn flushRx(self: *Net, rx: *queue.VirtQueue, ram: guestmem.GuestRam) bool {
        var did_work = false;
        var budget: usize = queue.max_queue_size;
        while (budget > 0) : (budget -= 1) {
            const frame = self.backend.peekRx() orelse break;
            if (frame.len == 0 or frame.len > max_frame_len) {
                self.backend.consumeRx();
                continue;
            }

            const maybe_chain = rx.popAvail(ram) catch return did_work;
            const chain = maybe_chain orelse break;
            const written = writeRxFrameToChain(&chain, frame) orelse 0;
            if (written > 0) {
                chain.markWritableDirty(ram);
            }
            rx.pushUsed(ram, chain.head, written) catch return did_work;
            if (written > 0) self.backend.consumeRx();
            did_work = true;
        }
        return did_work;
    }

    fn resetDevice(ctx: *anyopaque) void {
        const self: *Net = @ptrCast(@alignCast(ctx));
        self.backend.reset();
    }
};

fn dropTx(_: ?*anyopaque, _: []const u8) void {}
fn noRx(_: ?*anyopaque) ?[]const u8 {
    return null;
}
fn noop(_: ?*anyopaque) void {}
fn healthy(_: ?*anyopaque) bool {
    return false;
}
fn noopWake(_: ?*anyopaque) void {}
fn ignoreWake(_: ?*anyopaque, _: Wake) void {}
fn ignoreClearWake(_: ?*anyopaque) void {}
fn noWake(_: ?*anyopaque) bool {
    return false;
}

fn txFrameFromChain(chain: *const queue.Chain, out: *[max_frame_len]u8) ?[]const u8 {
    const total = chain.readableLen();
    if (total <= header_len) return null;
    const frame_len = total - header_len;
    if (frame_len > max_frame_len) return null;
    if (!copyReadableRange(chain, header_len, out[0..frame_len])) return null;
    return out[0..frame_len];
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

fn writeRxFrameToChain(chain: *const queue.Chain, frame: []const u8) ?u32 {
    if (frame.len == 0 or frame.len > max_frame_len) return null;
    const total = header_len + frame.len;
    if (writableLen(chain) < total) return null;

    var copied: usize = 0;
    for (chain.segments.slice()) |seg| {
        if (!seg.writable) continue;
        var seg_written: usize = 0;
        while (seg_written < seg.data.len and copied < total) {
            if (copied < header_len) {
                const n = @min(seg.data.len - seg_written, header_len - copied);
                @memset(seg.data[seg_written..][0..n], 0);
                seg_written += n;
                copied += n;
            } else {
                const frame_offset = copied - header_len;
                const n = @min(seg.data.len - seg_written, frame.len - frame_offset);
                @memcpy(seg.data[seg_written..][0..n], frame[frame_offset..][0..n]);
                seg_written += n;
                copied += n;
            }
        }
        if (copied == total) return @intCast(total);
    }
    return null;
}

fn writableLen(chain: *const queue.Chain) usize {
    var n: usize = 0;
    for (chain.segments.slice()) |seg| {
        if (seg.writable) n += seg.data.len;
    }
    return n;
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
    try setDescNext(ram, desc_base, i, addr, len, flags, 0);
}

fn setDescNext(ram: guestmem.GuestRam, desc_base: u64, i: u16, addr: u64, len: u32, flags: u16, next: u16) !void {
    const base = desc_base + 16 * @as(u64, i);
    try ram.write(u64, base, addr);
    try ram.write(u32, base + 8, len);
    try ram.write(u16, base + 12, flags);
    try ram.write(u16, base + 14, next);
}

fn pushAvail(ram: guestmem.GuestRam, avail_base: u64, qsize: u16, head: u16) !void {
    const idx = try ram.read(u16, avail_base + 2);
    try ram.write(u16, avail_base + 4 + 2 * @as(u64, idx % qsize), head);
    try ram.write(u16, avail_base + 2, idx +% 1);
}

const TestBackend = struct {
    tx_buf: [max_frame_len]u8 = undefined,
    tx_len: usize = 0,
    tx_count: usize = 0,

    rx_buf: [max_frame_len]u8 = undefined,
    rx_len: usize = 0,
    rx_pending: bool = false,
    rx_consumed: usize = 0,

    resets: usize = 0,
    shutdowns: usize = 0,

    fn backend(self: *TestBackend) Backend {
        return .{
            .context = self,
            .transmitFn = transmit,
            .peekRxFn = peekRx,
            .consumeRxFn = consumeRx,
            .resetFn = reset,
            .shutdownFn = shutdown,
        };
    }

    fn queueRx(self: *TestBackend, frame: []const u8) void {
        std.debug.assert(frame.len <= max_frame_len);
        @memcpy(self.rx_buf[0..frame.len], frame);
        self.rx_len = frame.len;
        self.rx_pending = true;
    }

    fn txFrame(self: *const TestBackend) []const u8 {
        return self.tx_buf[0..self.tx_len];
    }

    fn transmit(ctx: ?*anyopaque, frame: []const u8) void {
        const self: *TestBackend = @ptrCast(@alignCast(ctx.?));
        const n = @min(frame.len, self.tx_buf.len);
        @memcpy(self.tx_buf[0..n], frame[0..n]);
        self.tx_len = n;
        self.tx_count += 1;
    }

    fn peekRx(ctx: ?*anyopaque) ?[]const u8 {
        const self: *TestBackend = @ptrCast(@alignCast(ctx.?));
        if (!self.rx_pending) return null;
        return self.rx_buf[0..self.rx_len];
    }

    fn consumeRx(ctx: ?*anyopaque) void {
        const self: *TestBackend = @ptrCast(@alignCast(ctx.?));
        self.rx_pending = false;
        self.rx_consumed += 1;
    }

    fn reset(ctx: ?*anyopaque) void {
        const self: *TestBackend = @ptrCast(@alignCast(ctx.?));
        self.resets += 1;
    }

    fn shutdown(ctx: ?*anyopaque) void {
        const self: *TestBackend = @ptrCast(@alignCast(ctx.?));
        self.shutdowns += 1;
    }
};

test "identity features and mac config" {
    var dev = Net.init(.{});
    var t = mmio.Transport.init(dev.device());
    try std.testing.expectEqual(device_id, t.read(0x008));
    try std.testing.expectEqual(@as(u32, @truncate(feature_mac)), t.read(0x010));
    try std.testing.expectEqual(@as(u32, 0x4f_50_53_02), t.read(0x100));
    try std.testing.expectEqual(@as(u32, 0x0000_4552), t.read(0x104));
    try std.testing.expectEqual(@as(u32, 0x0000_0045), t.read(0x105));
}

test "tx queue drains packets and returns descriptors used" {
    var backend = TestBackend{};
    var dev = Net.init(.{ .backend = backend.backend() });
    var t = mmio.Transport.init(dev.device());
    var buf: [8192]u8 = [_]u8{0} ** 8192;
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    const tx_desc = 0x000;
    const tx_avail = 0x400;
    const tx_used = 0x800;
    const packet = 0xc00;
    const frame = "ethernet-frame";

    configureQueue(&t, tx_queue, tx_desc, tx_avail, tx_used, ram);
    @memset(buf[packet..][0..header_len], 0);
    @memcpy(buf[packet + header_len ..][0..frame.len], frame);
    try setDesc(ram, tx_desc, 0, packet, header_len + frame.len, 0);
    try pushAvail(ram, tx_avail, 8, 0);

    try std.testing.expect(t.write(0x050, tx_queue, ram));
    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, tx_used + 2));
    try std.testing.expectEqual(@as(u32, 0), try ram.read(u32, tx_used + 8));
    try std.testing.expectEqual(@as(u64, 1), dev.tx_packets);
    try std.testing.expectEqual(@as(u64, frame.len), dev.tx_bytes);
    try std.testing.expectEqual(@as(usize, 1), backend.tx_count);
    try std.testing.expectEqualStrings(frame, backend.txFrame());
}

test "tx queue drops malformed virtio net headers and oversized frames" {
    var backend = TestBackend{};
    var dev = Net.init(.{ .backend = backend.backend() });
    var t = mmio.Transport.init(dev.device());
    var buf: [8192]u8 = [_]u8{0} ** 8192;
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    const tx_desc = 0x000;
    const tx_avail = 0x400;
    const tx_used = 0x800;
    const packet = 0xc00;

    configureQueue(&t, tx_queue, tx_desc, tx_avail, tx_used, ram);
    try setDesc(ram, tx_desc, 0, packet, header_len - 1, 0);
    try pushAvail(ram, tx_avail, 8, 0);
    try std.testing.expect(t.write(0x050, tx_queue, ram));
    try std.testing.expectEqual(@as(usize, 0), backend.tx_count);
    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, tx_used + 2));

    try setDesc(ram, tx_desc, 1, packet, header_len + max_frame_len + 1, 0);
    try pushAvail(ram, tx_avail, 8, 1);
    try std.testing.expect(t.write(0x050, tx_queue, ram));
    try std.testing.expectEqual(@as(usize, 0), backend.tx_count);
    try std.testing.expectEqual(@as(u16, 2), try ram.read(u16, tx_used + 2));
}

test "rx queue injects pending backend frame with virtio net header" {
    var backend = TestBackend{};
    const frame = "reply-frame";
    backend.queueRx(frame);

    var dev = Net.init(.{ .backend = backend.backend() });
    var t = mmio.Transport.init(dev.device());
    var buf: [4096]u8 = [_]u8{0} ** 4096;
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    const rx_desc = 0x000;
    const rx_avail = 0x400;
    const rx_used = 0x800;
    const packet = 0xc00;

    configureQueue(&t, rx_queue, rx_desc, rx_avail, rx_used, ram);
    try setDesc(ram, rx_desc, 0, packet, header_len + frame.len, 2);
    try pushAvail(ram, rx_avail, 8, 0);

    try std.testing.expect(t.write(0x050, rx_queue, ram));
    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, rx_used + 2));
    try std.testing.expectEqual(@as(u32, header_len + frame.len), try ram.read(u32, rx_used + 8));
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** header_len, buf[packet..][0..header_len]);
    try std.testing.expectEqualStrings(frame, buf[packet + header_len ..][0..frame.len]);
    try std.testing.expect(!backend.rx_pending);
    try std.testing.expectEqual(@as(usize, 1), backend.rx_consumed);
}

test "net device exposes explicit pending rx flush for async backends" {
    var backend = TestBackend{};
    const frame = "async-reply";
    backend.queueRx(frame);

    var dev = Net.init(.{ .backend = backend.backend() });
    var t = mmio.Transport.init(dev.device());
    var buf: [4096]u8 = [_]u8{0} ** 4096;
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    const rx_desc = 0x000;
    const rx_avail = 0x400;
    const rx_used = 0x800;
    const packet = 0xc00;

    configureQueue(&t, rx_queue, rx_desc, rx_avail, rx_used, ram);
    try setDesc(ram, rx_desc, 0, packet, header_len + frame.len, 2);
    try pushAvail(ram, rx_avail, 8, 0);

    try std.testing.expect(dev.flushPendingRx(&t.queues, ram));
    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, rx_used + 2));
    try std.testing.expectEqual(@as(u32, header_len + frame.len), try ram.read(u32, rx_used + 8));
    try std.testing.expectEqualStrings(frame, buf[packet + header_len ..][0..frame.len]);
    try std.testing.expect(!backend.rx_pending);
    try std.testing.expectEqual(@as(usize, 1), backend.rx_consumed);
}

test "tx notify also flushes pending rx frames" {
    var backend = TestBackend{};
    const tx_frame = "guest-frame";
    const rx_frame = "host-frame";
    backend.queueRx(rx_frame);

    var dev = Net.init(.{ .backend = backend.backend() });
    var t = mmio.Transport.init(dev.device());
    var buf: [4096]u8 = [_]u8{0} ** 4096;
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    const tx_desc = 0x000;
    const tx_avail = 0x400;
    const tx_used = 0x800;
    const tx_packet = 0xc00;
    const rx_desc = 0x100;
    const rx_avail = 0x500;
    const rx_used = 0x900;
    const rx_packet = 0xd00;

    configureQueue(&t, tx_queue, tx_desc, tx_avail, tx_used, ram);
    configureQueue(&t, rx_queue, rx_desc, rx_avail, rx_used, ram);

    @memset(buf[tx_packet..][0..header_len], 0);
    @memcpy(buf[tx_packet + header_len ..][0..tx_frame.len], tx_frame);
    try setDesc(ram, tx_desc, 0, tx_packet, header_len + tx_frame.len, 0);
    try pushAvail(ram, tx_avail, 8, 0);

    try setDesc(ram, rx_desc, 0, rx_packet, header_len + rx_frame.len, 2);
    try pushAvail(ram, rx_avail, 8, 0);

    try std.testing.expect(t.write(0x050, tx_queue, ram));
    try std.testing.expectEqualStrings(tx_frame, backend.txFrame());
    try std.testing.expect(!backend.rx_pending);
    try std.testing.expectEqualStrings(rx_frame, buf[rx_packet + header_len ..][0..rx_frame.len]);
    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, tx_used + 2));
    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, rx_used + 2));
}

test "rx queue preserves pending frame when buffers are absent or too small" {
    var backend = TestBackend{};
    const frame = "queued-frame";
    backend.queueRx(frame);

    var dev = Net.init(.{ .backend = backend.backend() });
    var t = mmio.Transport.init(dev.device());
    var buf: [4096]u8 = [_]u8{0} ** 4096;
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    const rx_desc = 0x000;
    const rx_avail = 0x400;
    const rx_used = 0x800;
    const packet = 0xc00;

    configureQueue(&t, rx_queue, rx_desc, rx_avail, rx_used, ram);
    try std.testing.expect(!t.write(0x050, rx_queue, ram));
    try std.testing.expect(backend.rx_pending);
    try std.testing.expectEqual(@as(u16, 0), try ram.read(u16, rx_used + 2));

    try setDesc(ram, rx_desc, 0, packet, header_len + frame.len - 1, 2);
    try pushAvail(ram, rx_avail, 8, 0);
    try std.testing.expect(t.write(0x050, rx_queue, ram));
    try std.testing.expect(backend.rx_pending);
    try std.testing.expectEqual(@as(usize, 0), backend.rx_consumed);
    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, rx_used + 2));
    try std.testing.expectEqual(@as(u32, 0), try ram.read(u32, rx_used + 8));

    try setDesc(ram, rx_desc, 1, packet + 0x100, header_len + frame.len, 2);
    try pushAvail(ram, rx_avail, 8, 1);
    try std.testing.expect(t.write(0x050, rx_queue, ram));
    try std.testing.expect(!backend.rx_pending);
    try std.testing.expectEqual(@as(usize, 1), backend.rx_consumed);
    try std.testing.expectEqual(@as(u16, 2), try ram.read(u16, rx_used + 2));
}

test "net backend reset and shutdown hooks run explicitly" {
    var backend = TestBackend{};
    var dev = Net.init(.{ .backend = backend.backend() });
    var t = mmio.Transport.init(dev.device());
    var buf: [16]u8 = [_]u8{0} ** 16;
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    _ = t.write(0x070, 0, ram);
    try std.testing.expectEqual(@as(usize, 1), backend.resets);

    dev.shutdown();
    try std.testing.expectEqual(@as(usize, 1), backend.shutdowns);
}

fn fuzzNetTx(_: void, s: *std.testing.Smith) !void {
    var backend = TestBackend{};
    var dev = Net.init(.{ .backend = backend.backend() });
    var t = mmio.Transport.init(dev.device());
    var buf: [4096]u8 = [_]u8{0} ** 4096;
    _ = s.slice(&buf);
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };
    var rx_frame: [max_frame_len]u8 = undefined;
    const rx_len = @min(s.slice(&rx_frame), max_frame_len);
    if (rx_len > 0) backend.queueRx(rx_frame[0..rx_len]);

    t.queues[rx_queue] = .{ .size = 8, .ready = true, .desc_addr = 0x1000, .avail_addr = 0x1200, .used_addr = 0x1400 };
    t.queues[tx_queue] = .{ .size = 8, .ready = true, .desc_addr = 0x0000, .avail_addr = 0x0400, .used_addr = 0x0800 };
    ram.write(u16, 0x1200 + 2, s.value(u8) % 4) catch {};
    ram.write(u16, 0x0400 + 2, s.value(u8) % 4) catch {};
    _ = t.write(0x050, rx_queue, ram);
    _ = t.write(0x050, tx_queue, ram);
    dev.shutdown();
}

test "fuzz net tx handling" {
    try std.testing.fuzz({}, fuzzNetTx, .{});
}
