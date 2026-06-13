//! SporeVM generation MMIO device.
//!
//! This is a tiny, backend-neutral platform device used by the later fork
//! protocol. It exposes a monotonically increasing generation counter, a
//! read-only resume-parameters page, and one level interrupt bit that remains
//! pending until the guest acknowledges it. The first slice wires the device
//! into the board inertly: generation zero, empty params, no interrupt.

const std = @import("std");

pub const magic: u32 = 0x4e47_5053; // "SPGN", little-endian MMIO word
pub const version: u32 = 1;

pub const window_size: u64 = 0x1000;
pub const params_offset: u64 = 0x100;
pub const params_size: usize = window_size - params_offset;

const version_offset: u64 = 0x004;
const params_offset_offset: u64 = 0x008;
const params_size_offset: u64 = 0x00c;
const irq_status_offset: u64 = 0x010;
const irq_ack_offset: u64 = 0x014;
const generation_offset: u64 = 0x018;

pub const irq_generation_changed: u32 = 1;

pub const Error = error{
    BadState,
    OutOfMemory,
};

pub const State = struct {
    generation: u64,
    interrupt_status: u32,
    /// Base64-encoded params bytes with trailing zeroes elided.
    params_b64: []const u8,
};

pub const Device = struct {
    generation: u64 = 0,
    interrupt_status: u32 = 0,
    params: [params_size]u8 = [_]u8{0} ** params_size,

    pub fn read(self: *const Device, offset: u64, size_log2: u2) u64 {
        const size = @as(usize, 1) << size_log2;
        var out: u64 = 0;
        var i: usize = 0;
        while (i < size) : (i += 1) {
            out |= @as(u64, self.readByte(offset + i)) << @intCast(8 * i);
        }
        return out;
    }

    /// Apply a guest write. Returns true when the interrupt line should be
    /// lowered after clearing the pending bit.
    pub fn write(self: *Device, offset: u64, value: u64, size_log2: u2) bool {
        _ = size_log2;
        if (offset != irq_ack_offset) return false;
        const was_pending = self.interrupt_status & irq_generation_changed != 0;
        self.interrupt_status &= ~@as(u32, @truncate(value));
        return was_pending and self.interrupt_status & irq_generation_changed == 0;
    }

    /// Future fork/resume hook. This first slice does not call it from the VM
    /// lifecycle yet, but tests lock the interrupt semantics before the guest
    /// driver exists.
    pub fn setResume(self: *Device, generation: u64, params: []const u8) Error!bool {
        if (params.len > params_size) return error.BadState;

        var next_params: [params_size]u8 = [_]u8{0} ** params_size;
        @memcpy(next_params[0..params.len], params);

        const changed = self.generation != generation or !std.mem.eql(u8, &self.params, &next_params);
        self.generation = generation;
        self.params = next_params;
        if (changed) self.interrupt_status |= irq_generation_changed;
        return changed;
    }

    pub fn capture(self: *const Device, allocator: std.mem.Allocator) Error!State {
        var end = self.params.len;
        while (end > 0 and self.params[end - 1] == 0) : (end -= 1) {}

        const enc = std.base64.standard.Encoder;
        const out = allocator.alloc(u8, enc.calcSize(end)) catch return error.OutOfMemory;
        _ = enc.encode(out, self.params[0..end]);
        return .{
            .generation = self.generation,
            .interrupt_status = self.interrupt_status,
            .params_b64 = out,
        };
    }

    pub fn restore(self: *Device, allocator: std.mem.Allocator, state: State) Error!void {
        if (state.interrupt_status & ~irq_generation_changed != 0) return error.BadState;
        const dec = std.base64.standard.Decoder;
        const decoded_size = dec.calcSizeForSlice(state.params_b64) catch return error.BadState;
        if (decoded_size > params_size) return error.BadState;
        const decoded = allocator.alloc(u8, decoded_size) catch return error.OutOfMemory;
        defer allocator.free(decoded);
        dec.decode(decoded, state.params_b64) catch return error.BadState;

        self.generation = state.generation;
        self.interrupt_status = state.interrupt_status;
        @memset(&self.params, 0);
        @memcpy(self.params[0..decoded.len], decoded);
    }

    fn readByte(self: *const Device, offset: u64) u8 {
        if (offset < 4) return intByte(u32, magic, offset);
        if (offset >= version_offset and offset < version_offset + 4) return intByte(u32, version, offset - version_offset);
        if (offset >= params_offset_offset and offset < params_offset_offset + 4) return intByte(u32, params_offset, offset - params_offset_offset);
        if (offset >= params_size_offset and offset < params_size_offset + 4) return intByte(u32, params_size, offset - params_size_offset);
        if (offset >= irq_status_offset and offset < irq_status_offset + 4) return intByte(u32, self.interrupt_status, offset - irq_status_offset);
        if (offset >= generation_offset and offset < generation_offset + 8) return intByte(u64, self.generation, offset - generation_offset);
        if (offset >= params_offset and offset < window_size) return self.params[@intCast(offset - params_offset)];
        return 0;
    }
};

fn intByte(comptime T: type, value: T, byte_index: u64) u8 {
    return @truncate(value >> @intCast(8 * byte_index));
}

test "identity registers and empty defaults" {
    var dev = Device{};
    try std.testing.expectEqual(magic, dev.read(0x000, 2));
    try std.testing.expectEqual(version, dev.read(0x004, 2));
    try std.testing.expectEqual(@as(u64, params_offset), dev.read(0x008, 2));
    try std.testing.expectEqual(@as(u64, params_size), dev.read(0x00c, 2));
    try std.testing.expectEqual(@as(u64, 0), dev.read(0x010, 2));
    try std.testing.expectEqual(@as(u64, 0), dev.read(0x018, 3));
    try std.testing.expectEqual(@as(u64, 0), dev.read(params_offset, 2));
}

test "generation reads support low and high words" {
    var dev = Device{ .generation = 0x1122_3344_5566_7788 };
    try std.testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), dev.read(0x018, 3));
    try std.testing.expectEqual(@as(u64, 0x5566_7788), dev.read(0x018, 2));
    try std.testing.expectEqual(@as(u64, 0x1122_3344), dev.read(0x01c, 2));
}

test "resume update raises interrupt and ack clears it" {
    var dev = Device{};
    try std.testing.expect(try dev.setResume(7, "abc"));
    try std.testing.expectEqual(@as(u64, 7), dev.read(0x018, 3));
    try std.testing.expectEqual(@as(u64, irq_generation_changed), dev.read(0x010, 2));
    try std.testing.expectEqual(@as(u64, 'a'), dev.read(params_offset, 0));
    try std.testing.expect(dev.write(0x014, irq_generation_changed, 2));
    try std.testing.expectEqual(@as(u32, 0), dev.interrupt_status);
    try std.testing.expect(!try dev.setResume(7, "abc"));
}

test "state capture trims params and restore fails closed" {
    const allocator = std.testing.allocator;
    var dev = Device{};
    try std.testing.expect(try dev.setResume(9, "params"));
    const state = try dev.capture(allocator);
    defer allocator.free(state.params_b64);
    try std.testing.expectEqual(@as(u64, 9), state.generation);
    try std.testing.expectEqual(@as(u32, irq_generation_changed), state.interrupt_status);
    try std.testing.expect(state.params_b64.len < params_size);

    var restored = Device{};
    try restored.restore(allocator, state);
    try std.testing.expectEqual(@as(u64, 9), restored.generation);
    try std.testing.expectEqualSlices(u8, "params", restored.params[0..6]);

    try std.testing.expectError(error.BadState, restored.restore(allocator, .{
        .generation = 0,
        .interrupt_status = 0xff,
        .params_b64 = "",
    }));

    const too_large = try allocator.alloc(u8, params_size + 1);
    defer allocator.free(too_large);
    @memset(too_large, 0xa5);
    const enc = std.base64.standard.Encoder;
    const oversized_b64 = try allocator.alloc(u8, enc.calcSize(too_large.len));
    defer allocator.free(oversized_b64);
    _ = enc.encode(oversized_b64, too_large);
    try std.testing.expectError(error.BadState, restored.restore(allocator, .{
        .generation = 0,
        .interrupt_status = 0,
        .params_b64 = oversized_b64,
    }));
}

fn fuzzMmio(_: void, s: *std.testing.Smith) !void {
    var dev = Device{};
    var budget: usize = 64;
    while (budget > 0) : (budget -= 1) {
        const offset = s.value(u16) % (window_size + 16);
        const size_log2: u2 = @truncate(s.value(u8));
        if (s.value(u8) & 1 == 0) {
            _ = dev.read(offset, size_log2);
        } else {
            _ = dev.write(offset, s.value(u64), size_log2);
        }
    }
}

test "fuzz generation mmio" {
    try std.testing.fuzz({}, fuzzMmio, .{});
}
