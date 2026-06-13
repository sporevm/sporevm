//! Bounds-checked guest memory access.
//!
//! Every guest-physical address that reaches device emulation is attacker
//! controlled. All access to guest RAM goes through this module so the
//! bounds checks live in exactly one place. See SECURITY.md.

const std = @import("std");

pub const Error = error{OutOfBounds};

pub const GuestRam = struct {
    /// Host mapping of the contiguous guest RAM region.
    bytes: []u8,
    /// Guest-physical base address of that region.
    base: u64,

    /// Translate a guest-physical range into a host slice, or fail.
    pub fn slice(self: GuestRam, gpa: u64, len: u64) Error![]u8 {
        if (len == 0) return self.bytes[0..0];
        if (gpa < self.base) return error.OutOfBounds;
        const off = gpa - self.base;
        if (off >= self.bytes.len) return error.OutOfBounds;
        if (len > self.bytes.len - off) return error.OutOfBounds;
        return self.bytes[@intCast(off)..@intCast(off + len)];
    }

    /// Read a little-endian integer from guest memory (unaligned safe).
    pub fn read(self: GuestRam, comptime T: type, gpa: u64) Error!T {
        const s = try self.slice(gpa, @sizeOf(T));
        return std.mem.readInt(T, s[0..@sizeOf(T)], .little);
    }

    /// Write a little-endian integer into guest memory (unaligned safe).
    pub fn write(self: GuestRam, comptime T: type, gpa: u64, value: T) Error!void {
        const s = try self.slice(gpa, @sizeOf(T));
        std.mem.writeInt(T, s[0..@sizeOf(T)], value, .little);
    }
};

test "slice bounds" {
    var buf: [64]u8 = undefined;
    const ram = GuestRam{ .bytes = &buf, .base = 0x1000 };
    _ = try ram.slice(0x1000, 64);
    _ = try ram.slice(0x103f, 1);
    try std.testing.expectError(error.OutOfBounds, ram.slice(0xfff, 1));
    try std.testing.expectError(error.OutOfBounds, ram.slice(0x1040, 1));
    try std.testing.expectError(error.OutOfBounds, ram.slice(0x1000, 65));
    try std.testing.expectError(error.OutOfBounds, ram.slice(0x103f, 2));
    // Overflow attempts.
    try std.testing.expectError(error.OutOfBounds, ram.slice(std.math.maxInt(u64), 2));
    try std.testing.expectError(error.OutOfBounds, ram.slice(0x1000, std.math.maxInt(u64)));
}

test "typed read/write round-trip" {
    var buf = [_]u8{0} ** 16;
    const ram = GuestRam{ .bytes = &buf, .base = 0 };
    try ram.write(u32, 1, 0xdeadbeef); // deliberately unaligned
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), try ram.read(u32, 1));
    try std.testing.expectError(error.OutOfBounds, ram.read(u64, 9));
}
