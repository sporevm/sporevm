//! Strict decoder for the Stage 0b.2 guest-owned profile mailbox.

const std = @import("std");

pub const page_size: usize = 4096;
pub const message_size: usize = 512;
pub const mailbox_gpa: u64 = 0xcfff_f000;
pub const generation_gpa: u64 = 0xd000_1000;
pub const capture_doorbell_offset: u64 = 0x028;
pub const capture_command: u32 = 0x5450_4143;
pub const restored_doorbell_offset: u64 = 0x02c;
pub const restored_command: u32 = 0x5254_5352;
pub const magic: u32 = 0x3150_5258;
pub const version: u16 = 1;
pub const cpuid_count: usize = 5;
pub const expected_x87 = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0x80, 0xff, 0x3f, 0, 0, 0, 0, 0, 0 };
pub const expected_xmm = [16]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
pub const expected_ymm = [32]u8{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f };

pub const Phase = enum(u32) {
    capture_ready = 1,
    restored_ready = 2,
};

pub const Clock = struct {
    seconds: i64,
    nanoseconds: u32,

    pub fn before(left: Clock, right: Clock) bool {
        return left.seconds < right.seconds or
            (left.seconds == right.seconds and left.nanoseconds < right.nanoseconds);
    }
};

pub const Cpuid = struct {
    function: u32,
    index: u32,
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

pub const Message = struct {
    phase: Phase,
    nonce: u64,
    xcr0: u64,
    capture_tsc: u64,
    restored_tsc: u64,
    capture_clocks: [3]Clock,
    restored_clocks: [3]Clock,
    cpuid: [cpuid_count]Cpuid,
    expected_x87: [16]u8,
    observed_x87: [16]u8,
    expected_xmm: [16]u8,
    observed_xmm: [16]u8,
    expected_ymm: [32]u8,
    observed_ymm: [32]u8,
};

pub const Error = error{
    BadChecksum,
    BadCpuidSelectors,
    BadHeader,
    BadNonce,
    BadPhase,
    BadReservedBytes,
    InvalidAvxContract,
    InvalidClock,
    StateMismatch,
    TimeMovedBackwards,
};

const selectors = [_][2]u32{
    .{ 0, 0 },
    .{ 1, 0 },
    .{ 7, 0 },
    .{ 0x0d, 0 },
    .{ 0x0d, 1 },
};

pub fn decode(page: *const [page_size]u8, expected_phase: Phase, expected_nonce: u64) Error!Message {
    const bytes = page[0..message_size];
    if (read(u32, bytes, 0) != magic or
        read(u16, bytes, 4) != version or
        read(u16, bytes, 6) != 64 or
        read(u32, bytes, 8) != message_size or
        read(u32, bytes, 20) != cpuid_count)
    {
        return error.BadHeader;
    }
    const phase = std.enums.fromInt(Phase, read(u32, bytes, 12)) orelse return error.BadPhase;
    if (phase != expected_phase) return error.BadPhase;
    if (read(u32, bytes, 16) != 1) return error.InvalidAvxContract;
    const nonce = read(u64, bytes, 24);
    if (nonce != expected_nonce) return error.BadNonce;
    const xcr0 = read(u64, bytes, 32);
    if (xcr0 != 0x7) return error.InvalidAvxContract;
    if (checksum(bytes) != read(u64, bytes, 56)) return error.BadChecksum;

    var message = Message{
        .phase = phase,
        .nonce = nonce,
        .xcr0 = xcr0,
        .capture_tsc = read(u64, bytes, 40),
        .restored_tsc = read(u64, bytes, 48),
        .capture_clocks = undefined,
        .restored_clocks = undefined,
        .cpuid = undefined,
        .expected_x87 = bytes[280..296].*,
        .observed_x87 = bytes[296..312].*,
        .expected_xmm = bytes[312..328].*,
        .observed_xmm = bytes[328..344].*,
        .expected_ymm = bytes[344..376].*,
        .observed_ymm = bytes[376..408].*,
    };
    for (&message.capture_clocks, 0..) |*clock, index| clock.* = try decodeClock(bytes, 64 + index * 16);
    for (&message.restored_clocks, 0..) |*clock, index| clock.* = try decodeClock(bytes, 112 + index * 16);
    for (&message.cpuid, selectors, 0..) |*entry, selector, index| {
        const offset = 160 + index * 24;
        entry.* = .{
            .function = read(u32, bytes, offset),
            .index = read(u32, bytes, offset + 4),
            .eax = read(u32, bytes, offset + 8),
            .ebx = read(u32, bytes, offset + 12),
            .ecx = read(u32, bytes, offset + 16),
            .edx = read(u32, bytes, offset + 20),
        };
        if (entry.function != selector[0] or entry.index != selector[1]) return error.BadCpuidSelectors;
    }
    if (!allZero(bytes[408..]) or !allZero(page[message_size..])) return error.BadReservedBytes;
    if (!std.mem.eql(u8, &message.expected_x87, &expected_x87) or
        !std.mem.eql(u8, &message.expected_xmm, &expected_xmm) or
        !std.mem.eql(u8, &message.expected_ymm, &expected_ymm)) return error.StateMismatch;
    return message;
}

pub fn validateRestored(capture: Message, restored: Message) Error!void {
    if (capture.phase != .capture_ready or restored.phase != .restored_ready or
        capture.nonce != restored.nonce or capture.xcr0 != restored.xcr0 or
        !cpuidEqual(capture.cpuid, restored.cpuid) or
        !std.mem.eql(u8, &capture.expected_x87, &restored.expected_x87) or
        !std.mem.eql(u8, &capture.expected_xmm, &restored.expected_xmm) or
        !std.mem.eql(u8, &capture.expected_ymm, &restored.expected_ymm))
    {
        return error.StateMismatch;
    }
    if (restored.restored_tsc < capture.capture_tsc or
        restored.restored_clocks[0].before(capture.capture_clocks[0]) or
        restored.restored_clocks[1].before(capture.capture_clocks[1]))
    {
        return error.TimeMovedBackwards;
    }
    if (!std.mem.eql(u8, &restored.expected_x87, &restored.observed_x87) or
        !std.mem.eql(u8, &restored.expected_xmm, &restored.observed_xmm) or
        !std.mem.eql(u8, &restored.expected_ymm, &restored.observed_ymm))
    {
        return error.StateMismatch;
    }
}

fn cpuidEqual(left: [cpuid_count]Cpuid, right: [cpuid_count]Cpuid) bool {
    for (left, right) |a, b| if (!std.meta.eql(a, b)) return false;
    return true;
}

fn decodeClock(bytes: []const u8, offset: usize) Error!Clock {
    if (read(u32, bytes, offset + 12) != 0) return error.BadReservedBytes;
    const value = Clock{ .seconds = @bitCast(read(u64, bytes, offset)), .nanoseconds = read(u32, bytes, offset + 8) };
    if (value.seconds < 0 or value.nanoseconds >= std.time.ns_per_s) return error.InvalidClock;
    return value;
}

fn checksum(bytes: []const u8) u64 {
    var hash: u64 = 14_695_981_039_346_656_037;
    for (bytes, 0..) |byte, index| {
        hash ^= if (index >= 56 and index < 64) 0 else byte;
        hash *%= 1_099_511_628_211;
    }
    return hash;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn read(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

fn testCapturePage(nonce: u64) [page_size]u8 {
    var page: [page_size]u8 = @splat(0);
    std.mem.writeInt(u32, page[0..4], magic, .little);
    std.mem.writeInt(u16, page[4..6], version, .little);
    std.mem.writeInt(u16, page[6..8], 64, .little);
    std.mem.writeInt(u32, page[8..12], message_size, .little);
    std.mem.writeInt(u32, page[12..16], @intFromEnum(Phase.capture_ready), .little);
    std.mem.writeInt(u32, page[16..20], 1, .little);
    std.mem.writeInt(u32, page[20..24], cpuid_count, .little);
    std.mem.writeInt(u64, page[24..32], nonce, .little);
    std.mem.writeInt(u64, page[32..40], 7, .little);
    for (0..6) |index| std.mem.writeInt(u64, page[64 + index * 16 ..][0..8], 1, .little);
    for (selectors, 0..) |selector, index| {
        std.mem.writeInt(u32, page[160 + index * 24 ..][0..4], selector[0], .little);
        std.mem.writeInt(u32, page[164 + index * 24 ..][0..4], selector[1], .little);
    }
    @memcpy(page[280..296], &expected_x87);
    @memcpy(page[312..328], &expected_xmm);
    @memcpy(page[344..376], &expected_ymm);
    std.mem.writeInt(u64, page[56..64], checksum(page[0..message_size]), .little);
    return page;
}

test "mailbox decoder accepts the exact capture contract" {
    var page = testCapturePage(7);
    const decoded = try decode(&page, .capture_ready, 7);
    try std.testing.expectEqual(@as(u64, 7), decoded.xcr0);
    page[408] = 1;
    try std.testing.expectError(error.BadChecksum, decode(&page, .capture_ready, 7));
}

fn fuzzMailboxDecoder(_: void, smith: *std.testing.Smith) !void {
    var page: [page_size]u8 = @splat(0);
    const filled = smith.slice(&page);
    @memset(page[filled..], 0);
    _ = decode(&page, .capture_ready, smith.value(u32)) catch {};

    const nonce = smith.value(u64);
    var structured = testCapturePage(nonce);
    var mutations: [64]u8 = undefined;
    const mutation_count = smith.slice(&mutations);
    for (mutations[0..mutation_count]) |byte| {
        const offset = @as(usize, smith.value(u16)) % structured.len;
        structured[offset] ^= byte;
    }
    std.mem.writeInt(u64, structured[56..64], checksum(structured[0..message_size]), .little);
    _ = decode(&structured, .capture_ready, nonce) catch {};
}

test "fuzz profile mailbox decoder" {
    try std.testing.fuzz({}, fuzzMailboxDecoder, .{});
}
