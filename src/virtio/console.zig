//! Virtio console device (virtio spec 1.2 §5.3), minimal single-port.
//!
//! Queue 0 is receive (guest input, unused for now: buffers stay queued),
//! queue 1 is transmit (guest output, forwarded to the host sink).

const std = @import("std");
const guestmem = @import("../guestmem.zig");
const queue = @import("queue.zig");
const mmio = @import("mmio.zig");

pub const device_id: u32 = 3;
const rx_queue = 0;
const tx_queue = 1;

pub const Console = struct {
    /// Host sink for guest output. Kept as a function pointer so the device
    /// is testable and the harness can route to stdout.
    sink: *const fn ([]const u8) void,

    pub fn device(self: *Console) mmio.Device {
        return .{
            .context = self,
            .device_id = device_id,
            .device_features = 0,
            .queue_count = 2,
            .notifyFn = notify,
        };
    }

    /// Push host input into the guest's receive queue. Returns the number of
    /// bytes consumed (0 when the guest has no buffers posted); the caller
    /// raises the device interrupt when non-zero and marks interrupt status.
    pub fn feed(self: *Console, t: *mmio.Transport, ram: guestmem.GuestRam, bytes: []const u8) usize {
        _ = self;
        const q = &t.queues[rx_queue];
        var consumed: usize = 0;
        while (consumed < bytes.len) {
            const maybe_chain = q.popAvail(ram) catch return consumed;
            const chain = maybe_chain orelse break;
            var written: u32 = 0;
            for (chain.segments.slice()) |seg| {
                if (!seg.writable or consumed >= bytes.len) continue;
                const n = @min(seg.data.len, bytes.len - consumed);
                @memcpy(seg.data[0..n], bytes[consumed..][0..n]);
                consumed += n;
                written += @intCast(n);
            }
            q.pushUsed(ram, chain.head, written) catch return consumed;
            if (written > 0) t.interrupt_status |= 1;
        }
        return consumed;
    }

    fn notify(ctx: *anyopaque, queue_index: u8, q: *queue.VirtQueue, ram: guestmem.GuestRam) bool {
        const self: *Console = @ptrCast(@alignCast(ctx));
        if (queue_index != tx_queue) return false;

        var did_work = false;
        while (true) {
            const maybe_chain = q.popAvail(ram) catch {
                // Hostile ring state: stop processing, never crash.
                return did_work;
            };
            const chain = maybe_chain orelse break;
            for (chain.segments.slice()) |seg| {
                if (!seg.writable) self.sink(seg.data);
            }
            q.pushUsed(ram, chain.head, 0) catch return did_work;
            did_work = true;
        }
        return did_work;
    }
};

// --- tests ------------------------------------------------------------------

const TestOutput = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    fn appendSlice(self: *TestOutput, bytes: []const u8) void {
        const n = @min(bytes.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], bytes[0..n]);
        self.len += n;
    }

    fn slice(self: *const TestOutput) []const u8 {
        return self.buf[0..self.len];
    }
};

var test_output: TestOutput = .{};

fn testSink(bytes: []const u8) void {
    test_output.appendSlice(bytes);
}

test "tx chains reach the sink and are returned used" {
    test_output = .{};
    var con = Console{ .sink = testSink };
    var t = mmio.Transport.init(con.device());

    var buf: [4096]u8 = [_]u8{0} ** 4096;
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    // Configure tx queue (index 1) via transport registers.
    _ = t.write(0x030, 1, ram);
    _ = t.write(0x038, 8, ram);
    _ = t.write(0x080, 0x000, ram); // desc at 0x0
    _ = t.write(0x090, 0x400, ram); // avail at 0x400
    _ = t.write(0x0a0, 0x800, ram); // used at 0x800
    _ = t.write(0x044, 1, ram);

    // One readable descriptor containing "hello\n".
    const msg = "hello\n";
    @memcpy(buf[0xc00 .. 0xc00 + msg.len], msg);
    ram.write(u64, 0, 0xc00) catch unreachable;
    ram.write(u32, 8, msg.len) catch unreachable;
    ram.write(u16, 12, 0) catch unreachable;
    ram.write(u16, 0x400 + 4, 0) catch unreachable; // avail.ring[0] = 0
    ram.write(u16, 0x400 + 2, 1) catch unreachable; // avail.idx = 1

    const raised = t.write(0x050, tx_queue, ram);
    try std.testing.expect(raised);
    try std.testing.expectEqualStrings(msg, test_output.slice());
    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, 0x800 + 2));
}

test "rx notify is inert" {
    test_output = .{};
    var con = Console{ .sink = testSink };
    var t = mmio.Transport.init(con.device());
    var buf: [256]u8 = [_]u8{0} ** 256;
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };
    _ = t.write(0x030, 0, ram);
    _ = t.write(0x038, 4, ram);
    _ = t.write(0x044, 1, ram);
    try std.testing.expect(!t.write(0x050, 0, ram));
    try std.testing.expectEqual(@as(usize, 0), test_output.len);
}
