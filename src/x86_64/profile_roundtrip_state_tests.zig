const std = @import("std");
const state = @import("profile_roundtrip_state.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

fn testVcpu(allocator: std.mem.Allocator, index: usize) !state.VcpuMachineState {
    const cpuid_entries = [_]state.CpuidEntry{
        .{ .function = 0, .index = 0, .flags = 0, .eax = 0xd, .ebx = 1, .ecx = 2, .edx = 3 },
        .{ .function = 0xd, .index = 0, .flags = 1, .eax = 7, .ebx = 832, .ecx = 832, .edx = 0 },
    };
    const cpuid = try allocator.dupe(state.CpuidEntry, cpuid_entries[0 .. cpuid_entries.len - index]);
    errdefer allocator.free(cpuid);
    const xcrs = try allocator.dupe(state.Xcr, &.{.{ .index = 0, .value = 7 }});
    errdefer allocator.free(xcrs);
    const xsave = try allocator.alloc(u8, state.xsave_avx_end);
    errdefer allocator.free(xsave);
    @memset(xsave, 0);
    for (xsave[0..512], 0..) |*byte, byte_index| byte.* = @truncate(byte_index);
    std.mem.writeInt(u64, xsave[512..520], 7, .little);
    for (xsave[state.xsave_legacy_and_header_bytes..], 0..) |*byte, byte_index| byte.* = @truncate(byte_index + 1);
    const msr_entries = [_]state.Msr{
        .{ .index = 0x10, .value = 100 },
        .{ .index = 0x3b, .value = 2 },
    };
    const msrs = try allocator.dupe(state.Msr, msr_entries[0 .. msr_entries.len - index]);
    errdefer allocator.free(msrs);
    var result = state.VcpuMachineState{
        .cpuid = cpuid,
        .gprs = .{ .rax = index + 1, .rip = 0x1234 + index, .rflags = 2 },
        .sregs = .{ .cs = .{ .base = index, .limit = 0xffff, .selector = 8, .type = 11, .present = 1 }, .cr0 = 1, .efer = 0x500 },
        .xcrs = xcrs,
        .xsave = xsave,
        .xstate_bv = 7,
        .xcomp_bv = 0,
        .msrs = msrs,
        .tsc_khz = 3_000_000,
        .tsc_offset = -123 - @as(i64, @intCast(index)),
        .mp_state = 4,
        .lapic = .{
            .id = 0x0100_0000,
            .version = 0x14,
            .tpr = 0x20,
            .svr = 0x1ff,
            .isr = .{ 1, 2, 3, 4, 5, 6, 7, 8 },
            .lvt_timer = 0x20040,
            .initial_count = 1000,
            .current_count = 900,
            .divide_config = 3,
        },
        .events = .{ .interrupt_injected = 1, .interrupt_number = 0x40, .nmi_pending = 1, .flags = 0x01 },
        .debug = .{ .db = .{ 1, 2, 3, 4 }, .dr6 = 0xffff0ff0, .dr7 = 0x400 },
    };
    if (index == 1) {
        result.xsave[17] ^= 0x5a;
        result.mp_state = 5;
        result.lapic = .{ .id = 0x0200_0000, .version = 0x14, .svr = 0x1ff, .irr = .{ 8, 7, 6, 5, 4, 3, 2, 1 } };
        result.events = .{ .sipi_vector = 8, .flags = 0x02 };
        result.debug = .{ .dr6 = 0xffff0ff0, .dr7 = 0x400 };
    }
    return result;
}

fn testState(allocator: std.mem.Allocator) !state.State {
    var vcpus: [state.vcpu_count]state.VcpuMachineState = undefined;
    var initialized: usize = 0;
    errdefer for (vcpus[0..initialized]) |*vcpu| vcpu.deinit(allocator);
    for (&vcpus, 0..) |*vcpu, index| {
        vcpu.* = try testVcpu(allocator, index);
        initialized += 1;
    }
    const ram = try allocator.alloc(u8, 8192);
    errdefer allocator.free(ram);
    @memset(ram, 0xa5);
    var mailbox: [state.mailbox_size]u8 = @splat(0);
    @memcpy(mailbox[0..8], "mailbox!");
    var ioapic = state.Ioapic{ .base_address = 0xfec0_0000, .ioregsel = 7, .id = 2, .irr = 1 };
    ioapic.redirection_table[0] = 0x0001_0000_0000_0020;
    ioapic.redirection_table[23] = 0x0001_0000_0000_0037;
    var pit2 = state.Pit2{ .flags = 1 };
    pit2.channels[0] = .{ .count = 1193, .rw_mode = 3, .mode = 2, .gate = 1, .count_load_time = 777 };
    return .{
        .clock = .{ .clock = 44, .flags = 0x0e, .realtime = 55, .host_tsc = 66 },
        .vcpus = vcpus,
        .pic_master = .{ .irr = 1, .imr = 2, .irq_base = 0x20, .init4 = 1, .elcr_mask = 0xf8 },
        .pic_slave = .{ .isr = 4, .irq_base = 0x28, .auto_eoi = 1, .elcr_mask = 0xde },
        .ioapic = ioapic,
        .pit2 = pit2,
        .mailbox = mailbox,
        .ram = ram,
    };
}

test "normalized profile state has a stable little-endian round trip" {
    const allocator = std.testing.allocator;
    var original = try testState(allocator);
    defer original.deinit(allocator);
    const encoded = try state.encode(allocator, &original);
    defer allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &state.magic, encoded[0..state.magic.len]);
    try std.testing.expectEqual(state.format_version, std.mem.readInt(u32, encoded[state.magic.len..][0..4], .little));
    var decoded = try state.decode(allocator, encoded);
    defer decoded.deinit(allocator);
    try std.testing.expectEqualDeep(original.clock, decoded.clock);
    for (original.vcpus, decoded.vcpus) |expected, actual| {
        try std.testing.expectEqualSlices(state.CpuidEntry, expected.cpuid, actual.cpuid);
        try std.testing.expectEqualDeep(expected.gprs, actual.gprs);
        try std.testing.expectEqualDeep(expected.sregs, actual.sregs);
        try std.testing.expectEqualSlices(state.Xcr, expected.xcrs, actual.xcrs);
        try std.testing.expectEqualSlices(u8, expected.xsave, actual.xsave);
        try std.testing.expectEqual(expected.xstate_bv, actual.xstate_bv);
        try std.testing.expectEqual(expected.xcomp_bv, actual.xcomp_bv);
        try std.testing.expectEqualSlices(state.Msr, expected.msrs, actual.msrs);
        try std.testing.expectEqual(expected.tsc_khz, actual.tsc_khz);
        try std.testing.expectEqual(expected.tsc_offset, actual.tsc_offset);
        try std.testing.expectEqual(expected.mp_state, actual.mp_state);
        try std.testing.expectEqualDeep(expected.lapic, actual.lapic);
        try std.testing.expectEqualDeep(expected.events, actual.events);
        try std.testing.expectEqualDeep(expected.debug, actual.debug);
    }
    try std.testing.expectEqualDeep(original.pic_master, decoded.pic_master);
    try std.testing.expectEqualDeep(original.pic_slave, decoded.pic_slave);
    try std.testing.expectEqualDeep(original.ioapic, decoded.ioapic);
    try std.testing.expectEqualDeep(original.pit2, decoded.pit2);
    try std.testing.expectEqualSlices(u8, &original.mailbox, &decoded.mailbox);
    try std.testing.expectEqualSlices(u8, original.ram, decoded.ram);
}

test "state validation rejects noncanonical inventories and machine state" {
    const allocator = std.testing.allocator;
    var value = try testState(allocator);
    defer value.deinit(allocator);
    value.vcpus[0].cpuid[1] = value.vcpus[0].cpuid[0];
    try std.testing.expectError(error.DuplicateOrUnorderedCpuid, value.validate());
    value.vcpus[0].cpuid[1].function = 0xd;
    value.vcpus[0].xstate_bv = 1 << 9;
    try std.testing.expectError(error.InvalidXstate, value.validate());
    value.vcpus[0].xstate_bv = 7;
    value.vcpus[0].xcomp_bv = 1 << 63;
    try std.testing.expectError(error.InvalidXstate, value.validate());
    value.vcpus[0].xcomp_bv = 0;
    value.vcpus[0].xsave[512] = 1;
    try std.testing.expectError(error.InvalidXstate, value.validate());
    value.vcpus[0].xsave[512] = 7;
    value.vcpus[0].xsave[528] = 1;
    try std.testing.expectError(error.InvalidXstate, value.validate());
    value.vcpus[0].xsave[528] = 0;
    value.vcpus[0].events.nmi_pending = 2;
    try std.testing.expectError(error.InvalidBoolean, value.validate());
    value.vcpus[0].events.nmi_pending = 0;
    value.vcpus[0].debug.flags = 1;
    try std.testing.expectError(error.InvalidDebugFlags, value.validate());
    value.vcpus[0].debug.flags = 0;
    value.vcpus[0].events.flags = 1 << 6;
    try std.testing.expectError(error.InvalidEventFlags, value.validate());
}

test "decoder rejects corruption truncation trailing bytes and declared length mismatch" {
    const allocator = std.testing.allocator;
    var value = try testState(allocator);
    defer value.deinit(allocator);
    const good = try state.encode(allocator, &value);
    defer allocator.free(good);

    var corrupt = try allocator.dupe(u8, good);
    defer allocator.free(corrupt);
    corrupt[state.magic.len + 32] ^= 1;
    try std.testing.expectError(error.BadChecksum, state.decode(allocator, corrupt));
    try std.testing.expectError(error.Truncated, state.decode(allocator, good[0 .. Sha256.digest_length - 1]));

    const trailing = try allocator.alloc(u8, good.len + 1);
    defer allocator.free(trailing);
    @memcpy(trailing[0..good.len], good);
    trailing[good.len] = 0;
    try std.testing.expectError(error.BadChecksum, state.decode(allocator, trailing));

    var wrong_length = try allocator.dupe(u8, good);
    defer allocator.free(wrong_length);
    std.mem.writeInt(u64, wrong_length[state.magic.len + 8 ..][0..8], wrong_length.len + 1, .little);
    Sha256.hash(wrong_length[0 .. wrong_length.len - Sha256.digest_length], wrong_length[wrong_length.len - Sha256.digest_length ..][0..Sha256.digest_length], .{});
    try std.testing.expectError(error.NonCanonicalLength, state.decode(allocator, wrong_length));

    var wrong_vcpu_count = try allocator.dupe(u8, good);
    defer allocator.free(wrong_vcpu_count);
    const vcpu_count_offset = state.magic.len + 4 + 4 + 8 + 4;
    std.mem.writeInt(u32, wrong_vcpu_count[vcpu_count_offset..][0..4], state.vcpu_count - 1, .little);
    Sha256.hash(wrong_vcpu_count[0 .. wrong_vcpu_count.len - Sha256.digest_length], wrong_vcpu_count[wrong_vcpu_count.len - Sha256.digest_length ..][0..Sha256.digest_length], .{});
    try std.testing.expectError(error.InvalidVcpuCount, state.decode(allocator, wrong_vcpu_count));

    var wrong_inventory = try allocator.dupe(u8, good);
    defer allocator.free(wrong_inventory);
    const first_cpuid_count_offset = vcpu_count_offset + 4;
    const old_cpuid_count = std.mem.readInt(u32, wrong_inventory[first_cpuid_count_offset..][0..4], .little);
    std.mem.writeInt(u32, wrong_inventory[first_cpuid_count_offset..][0..4], old_cpuid_count + 1, .little);
    Sha256.hash(wrong_inventory[0 .. wrong_inventory.len - Sha256.digest_length], wrong_inventory[wrong_inventory.len - Sha256.digest_length ..][0..Sha256.digest_length], .{});
    try std.testing.expectError(error.NonCanonicalLength, state.decode(allocator, wrong_inventory));

    var invalid_clock = try allocator.dupe(u8, good);
    defer allocator.free(invalid_clock);
    const clock_flags_offset = vcpu_count_offset + 4 + state.vcpu_count * 5 * 4 + 8;
    std.mem.writeInt(u32, invalid_clock[clock_flags_offset..][0..4], 0x10, .little);
    Sha256.hash(invalid_clock[0 .. invalid_clock.len - Sha256.digest_length], invalid_clock[invalid_clock.len - Sha256.digest_length ..][0..Sha256.digest_length], .{});
    try std.testing.expectError(error.InvalidClockFlags, state.decode(allocator, invalid_clock));
}

fn fuzzStateDecoder(_: void, smith: *std.testing.Smith) !void {
    var arbitrary: [16 * 1024]u8 = undefined;
    const arbitrary_len = smith.slice(&arbitrary);
    consumeFuzzState(arbitrary[0..arbitrary_len]);
    var seed = try testState(std.testing.allocator);
    defer seed.deinit(std.testing.allocator);
    const encoded = try state.encode(std.testing.allocator, &seed);
    defer std.testing.allocator.free(encoded);
    var mutations: [64]u8 = undefined;
    const mutation_count = smith.slice(&mutations);
    const payload_len = encoded.len - Sha256.digest_length;
    for (mutations[0..mutation_count]) |byte| encoded[@as(usize, smith.value(u16)) % payload_len] ^= byte;
    Sha256.hash(encoded[0..payload_len], encoded[payload_len..][0..Sha256.digest_length], .{});
    consumeFuzzState(encoded);
}

fn consumeFuzzState(bytes: []const u8) void {
    if (state.decode(std.testing.allocator, bytes)) |decoded_value| {
        var decoded = decoded_value;
        decoded.deinit(std.testing.allocator);
    } else |_| {}
}

test "fuzz normalized profile state decoder" {
    try std.testing.fuzz({}, fuzzStateDecoder, .{});
}
