//! Bounded Intel MultiProcessor Specification 1.4 table generator.
//!
//! The direct-boot x86 kernel has no firmware or ACPI namespace, so it finds
//! vCPUs and the in-kernel IOAPIC through a legacy MP table. The table is
//! generated into caller-owned guest RAM at the fixed board addresses and can
//! be validated byte-for-byte before native boot evidence is accepted.

const std = @import("std");
const topology = @import("../topology.zig");
const board = @import("board.zig");

pub const min_cpu_count: u8 = 2;
pub const max_cpu_count: u8 = @intCast(topology.max_vcpus);

pub const floating_pointer_size: usize = 16;
pub const configuration_header_size: usize = 44;
pub const processor_entry_size: usize = 20;
pub const bus_entry_size: usize = 8;
pub const ioapic_entry_size: usize = 8;
pub const interrupt_entry_size: usize = 8;
pub const local_interrupt_entry_size: usize = 8;
/// KVM's default in-kernel routing connects GSI i to IOAPIC INTIN i, and its
/// PIT pulses GSI 0. Publish the complete ISA IRQ range with that identity
/// wiring. Linux's firmware fallback instead rewires IRQ0 to INTIN2 and skips
/// IRQ2; using that fallback requires replacing KVM's default routing too.
pub const isa_irq_count: usize = 16;
pub const ioapic_id: u8 = max_cpu_count;

const spec_version: u8 = 4;
const local_apic_version: u8 = 0x14;
const cpu_enabled: u8 = 1 << 0;
const cpu_boot_processor: u8 = 1 << 1;
const cpu_signature: u32 = 0x0000_0600;
const cpu_feature_fpu: u32 = 1 << 0;
const cpu_feature_apic: u32 = 1 << 9;
const ioapic_usable: u8 = 1;
const all_local_apics: u8 = 0xff;

const processor_entry_type: u8 = 0;
const bus_entry_type: u8 = 1;
const ioapic_entry_type: u8 = 2;
const interrupt_entry_type: u8 = 3;
const local_interrupt_entry_type: u8 = 4;
const interrupt_type_int: u8 = 0;
const interrupt_type_nmi: u8 = 1;
const interrupt_type_extint: u8 = 3;

const oem_id = "SPOREVM ";
const product_id = "X86BOARD-V0 ";
const isa_bus = "ISA   ";

pub const Error = error{
    InvalidCpuCount,
    DestinationTooSmall,
    TruncatedTable,
    InvalidFloatingPointer,
    InvalidConfigurationTable,
    InvalidChecksum,
    InvalidEntry,
};

pub fn configurationTableSize(cpu_count: u8) Error!usize {
    try validateCpuCount(cpu_count);
    return configuration_header_size +
        @as(usize, cpu_count) * processor_entry_size +
        bus_entry_size +
        ioapic_entry_size +
        isa_irq_count * interrupt_entry_size +
        2 * local_interrupt_entry_size;
}

pub fn tableEnd(cpu_count: u8) Error!usize {
    const config_addr: usize = @intCast(board.mp_config_table_addr);
    return config_addr + try configurationTableSize(cpu_count);
}

/// Write the complete MP table into a zero-based guest RAM slice. Returns the
/// first byte after the table; bytes from there through the GDT are untouched.
pub fn write(memory: []u8, cpu_count: u8) Error!usize {
    const table_len = try configurationTableSize(cpu_count);
    const floating_addr: usize = @intCast(board.mp_floating_pointer_addr);
    const config_addr: usize = @intCast(board.mp_config_table_addr);
    const end = config_addr + table_len;
    if (memory.len < end) return error.DestinationTooSmall;

    @memset(memory[floating_addr..end], 0);

    const floating = memory[floating_addr..][0..floating_pointer_size];
    @memcpy(floating[0..4], "_MP_");
    writeInt(u32, floating, 4, @intCast(board.mp_config_table_addr));
    floating[8] = 1; // length in 16-byte paragraphs
    floating[9] = spec_version;
    floating[10] = checksumByte(floating);

    const table = memory[config_addr..][0..table_len];
    @memcpy(table[0..4], "PCMP");
    writeInt(u16, table, 4, @intCast(table_len));
    table[6] = spec_version;
    @memcpy(table[8..16], oem_id);
    @memcpy(table[16..28], product_id);
    writeInt(u16, table, 34, entryCount(cpu_count));
    writeInt(u32, table, 36, @intCast(board.local_apic_base));

    var offset: usize = configuration_header_size;
    var cpu_id: u8 = 0;
    while (cpu_id < cpu_count) : (cpu_id += 1) {
        const entry = table[offset..][0..processor_entry_size];
        entry[0] = processor_entry_type;
        entry[1] = cpu_id;
        entry[2] = local_apic_version;
        entry[3] = cpu_enabled | if (cpu_id == 0) cpu_boot_processor else 0;
        writeInt(u32, entry, 4, cpu_signature);
        writeInt(u32, entry, 8, cpu_feature_fpu | cpu_feature_apic);
        offset += processor_entry_size;
    }

    {
        const entry = table[offset..][0..bus_entry_size];
        entry[0] = bus_entry_type;
        entry[1] = 0;
        @memcpy(entry[2..8], isa_bus);
        offset += bus_entry_size;
    }

    {
        const entry = table[offset..][0..ioapic_entry_size];
        entry[0] = ioapic_entry_type;
        entry[1] = ioapic_id;
        entry[2] = local_apic_version;
        entry[3] = ioapic_usable;
        writeInt(u32, entry, 4, @intCast(board.ioapic_base));
        offset += ioapic_entry_size;
    }

    var irq: u8 = 0;
    while (irq < isa_irq_count) : (irq += 1) {
        const entry = table[offset..][0..interrupt_entry_size];
        entry[0] = interrupt_entry_type;
        entry[1] = interrupt_type_int;
        writeInt(u16, entry, 2, 0); // conforming polarity and trigger mode
        entry[4] = 0; // ISA bus
        entry[5] = irq;
        entry[6] = ioapic_id;
        entry[7] = irq;
        offset += interrupt_entry_size;
    }

    {
        const entry = table[offset..][0..local_interrupt_entry_size];
        entry[0] = local_interrupt_entry_type;
        entry[1] = interrupt_type_extint;
        writeInt(u16, entry, 2, 0);
        entry[4] = 0;
        entry[5] = 0;
        entry[6] = 0;
        entry[7] = 0;
        offset += local_interrupt_entry_size;
    }

    {
        const entry = table[offset..][0..local_interrupt_entry_size];
        entry[0] = local_interrupt_entry_type;
        entry[1] = interrupt_type_nmi;
        writeInt(u16, entry, 2, 0);
        entry[4] = 0;
        entry[5] = 0;
        entry[6] = all_local_apics;
        entry[7] = 1;
        offset += local_interrupt_entry_size;
    }

    std.debug.assert(offset == table.len);
    table[7] = checksumByte(table);
    return end;
}

/// Strictly validate the fixed board table and its ordered base entries.
pub fn validate(memory: []const u8, expected_cpu_count: u8) Error!void {
    const expected_table_len = try configurationTableSize(expected_cpu_count);
    const floating_addr: usize = @intCast(board.mp_floating_pointer_addr);
    const config_addr: usize = @intCast(board.mp_config_table_addr);
    const end = config_addr + expected_table_len;
    if (memory.len < end) return error.TruncatedTable;

    const floating = memory[floating_addr..][0..floating_pointer_size];
    if (!std.mem.eql(u8, floating[0..4], "_MP_") or
        readInt(u32, floating, 4) != board.mp_config_table_addr or
        floating[8] != 1 or
        floating[9] != spec_version or
        !allZero(floating[11..16]))
    {
        return error.InvalidFloatingPointer;
    }
    if (byteSum(floating) != 0) return error.InvalidChecksum;

    const table = memory[config_addr..][0..expected_table_len];
    if (!std.mem.eql(u8, table[0..4], "PCMP") or
        readInt(u16, table, 4) != expected_table_len or
        table[6] != spec_version or
        !std.mem.eql(u8, table[8..16], oem_id) or
        !std.mem.eql(u8, table[16..28], product_id) or
        !allZero(table[28..34]) or
        readInt(u16, table, 34) != entryCount(expected_cpu_count) or
        readInt(u32, table, 36) != board.local_apic_base or
        !allZero(table[40..44]))
    {
        return error.InvalidConfigurationTable;
    }
    if (byteSum(table) != 0) return error.InvalidChecksum;

    var offset: usize = configuration_header_size;
    var cpu_id: u8 = 0;
    while (cpu_id < expected_cpu_count) : (cpu_id += 1) {
        const entry = table[offset..][0..processor_entry_size];
        const expected_flags = cpu_enabled | if (cpu_id == 0) cpu_boot_processor else 0;
        if (entry[0] != processor_entry_type or
            entry[1] != cpu_id or
            entry[2] != local_apic_version or
            entry[3] != expected_flags or
            readInt(u32, entry, 4) != cpu_signature or
            readInt(u32, entry, 8) != cpu_feature_fpu | cpu_feature_apic or
            !allZero(entry[12..20]))
        {
            return error.InvalidEntry;
        }
        offset += processor_entry_size;
    }

    {
        const entry = table[offset..][0..bus_entry_size];
        if (entry[0] != bus_entry_type or entry[1] != 0 or !std.mem.eql(u8, entry[2..8], isa_bus)) {
            return error.InvalidEntry;
        }
        offset += bus_entry_size;
    }

    {
        const entry = table[offset..][0..ioapic_entry_size];
        if (entry[0] != ioapic_entry_type or
            entry[1] != ioapic_id or
            entry[2] != local_apic_version or
            entry[3] != ioapic_usable or
            readInt(u32, entry, 4) != board.ioapic_base)
        {
            return error.InvalidEntry;
        }
        offset += ioapic_entry_size;
    }

    var irq: u8 = 0;
    while (irq < isa_irq_count) : (irq += 1) {
        const entry = table[offset..][0..interrupt_entry_size];
        if (entry[0] != interrupt_entry_type or
            entry[1] != interrupt_type_int or
            readInt(u16, entry, 2) != 0 or
            entry[4] != 0 or
            entry[5] != irq or
            entry[6] != ioapic_id or
            entry[7] != irq)
        {
            return error.InvalidEntry;
        }
        offset += interrupt_entry_size;
    }

    const extint = table[offset..][0..local_interrupt_entry_size];
    if (extint[0] != local_interrupt_entry_type or
        extint[1] != interrupt_type_extint or
        readInt(u16, extint, 2) != 0 or
        !allZero(extint[4..8]))
    {
        return error.InvalidEntry;
    }
    offset += local_interrupt_entry_size;

    const nmi = table[offset..][0..local_interrupt_entry_size];
    if (nmi[0] != local_interrupt_entry_type or
        nmi[1] != interrupt_type_nmi or
        readInt(u16, nmi, 2) != 0 or
        nmi[4] != 0 or
        nmi[5] != 0 or
        nmi[6] != all_local_apics or
        nmi[7] != 1)
    {
        return error.InvalidEntry;
    }
    offset += local_interrupt_entry_size;
    if (offset != table.len) return error.InvalidConfigurationTable;
}

fn validateCpuCount(cpu_count: u8) Error!void {
    if (cpu_count < min_cpu_count or cpu_count > max_cpu_count) return error.InvalidCpuCount;
}

fn entryCount(cpu_count: u8) u16 {
    return @as(u16, cpu_count) + 1 + 1 + @as(u16, isa_irq_count) + 2;
}

fn byteSum(bytes: []const u8) u8 {
    var sum: u8 = 0;
    for (bytes) |byte| sum +%= byte;
    return sum;
}

fn checksumByte(bytes: []const u8) u8 {
    return 0 -% byteSum(bytes);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn readInt(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

fn writeInt(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

test "maximum MP table is bounded below the GDT" {
    try std.testing.expectEqual(@as(u8, 8), max_cpu_count);
    try std.testing.expectEqual(@as(usize, 16), isa_irq_count);
    try std.testing.expectEqual(@as(usize, 364), try configurationTableSize(max_cpu_count));
    try std.testing.expectEqual(@as(usize, 380), try tableEnd(max_cpu_count));
    try std.testing.expect(try tableEnd(max_cpu_count) <= board.gdt_addr);
    try std.testing.expect(board.virtio_slots[board.virtio_slots.len - 1].gsi < isa_irq_count);
    try std.testing.expect(board.generation_gsi < isa_irq_count);
}

test "MP table describes two enabled CPUs with one BSP" {
    var memory: [@intCast(board.gdt_addr)]u8 = @splat(0xa5);
    const end = try write(&memory, 2);
    try validate(memory[0..end], 2);

    const floating = memory[0..floating_pointer_size];
    try std.testing.expectEqual(@as(u8, 0), byteSum(floating));
    try std.testing.expectEqual(@as(u32, board.mp_config_table_addr), readInt(u32, floating, 4));

    const config_addr: usize = @intCast(board.mp_config_table_addr);
    const table = memory[config_addr..end];
    try std.testing.expectEqual(@as(u8, 0), byteSum(table));
    try std.testing.expectEqual(@as(u16, 22), readInt(u16, table, 34));

    const cpu0 = table[configuration_header_size..][0..processor_entry_size];
    const cpu1 = table[configuration_header_size + processor_entry_size ..][0..processor_entry_size];
    try std.testing.expectEqual(@as(u8, 0), cpu0[1]);
    try std.testing.expectEqual(@as(u8, cpu_enabled | cpu_boot_processor), cpu0[3]);
    try std.testing.expectEqual(@as(u8, 1), cpu1[1]);
    try std.testing.expectEqual(@as(u8, cpu_enabled), cpu1[3]);
    try std.testing.expectEqual(@as(u8, 0xa5), memory[end]);
}

test "maximum MP table uses stable APIC IDs and complete KVM ISA routing" {
    var memory: [@intCast(board.gdt_addr)]u8 = undefined;
    const end = try write(&memory, max_cpu_count);
    try validate(memory[0..end], max_cpu_count);

    const config_addr: usize = @intCast(board.mp_config_table_addr);
    const table = memory[config_addr..end];
    var offset = configuration_header_size;
    for (0..max_cpu_count) |cpu_index| {
        const entry = table[offset..][0..processor_entry_size];
        try std.testing.expectEqual(@as(u8, @intCast(cpu_index)), entry[1]);
        try std.testing.expectEqual(cpu_index == 0, entry[3] & cpu_boot_processor != 0);
        offset += processor_entry_size;
    }
    offset += bus_entry_size;
    const ioapic = table[offset..][0..ioapic_entry_size];
    try std.testing.expectEqual(ioapic_id, ioapic[1]);
    try std.testing.expectEqual(@as(u32, board.ioapic_base), readInt(u32, ioapic, 4));
    offset += ioapic_entry_size;
    const pit_route = table[offset..][0..interrupt_entry_size];
    try std.testing.expectEqual(@as(u8, 0), pit_route[5]);
    try std.testing.expectEqual(@as(u8, 0), pit_route[7]);
    for (0..isa_irq_count) |irq_index| {
        const entry = table[offset..][0..interrupt_entry_size];
        try std.testing.expectEqual(@as(u8, @intCast(irq_index)), entry[5]);
        try std.testing.expectEqual(ioapic_id, entry[6]);
        try std.testing.expectEqual(@as(u8, @intCast(irq_index)), entry[7]);
        offset += interrupt_entry_size;
    }
    try std.testing.expectEqual(local_interrupt_entry_type, table[offset]);
}

test "MP generator and validator fail closed on bad counts, bounds, and bytes" {
    var memory: [@intCast(board.gdt_addr)]u8 = undefined;
    try std.testing.expectError(error.InvalidCpuCount, write(&memory, min_cpu_count - 1));
    try std.testing.expectError(error.InvalidCpuCount, write(&memory, max_cpu_count + 1));

    const end = try tableEnd(2);
    try std.testing.expectError(error.DestinationTooSmall, write(memory[0 .. end - 1], 2));
    _ = try write(&memory, 2);
    try std.testing.expectError(error.TruncatedTable, validate(memory[0 .. end - 1], 2));

    memory[10] +%= 1;
    try std.testing.expectError(error.InvalidChecksum, validate(&memory, 2));
    _ = try write(&memory, 2);

    const config_addr: usize = @intCast(board.mp_config_table_addr);
    memory[config_addr + configuration_header_size + 1] = 7;
    const table_len = try configurationTableSize(2);
    const table = memory[config_addr..][0..table_len];
    table[7] = 0;
    table[7] = checksumByte(table);
    try std.testing.expectError(error.InvalidEntry, validate(&memory, 2));
}
