//! Frozen `sporevm-x86_64-board-v0` machine constants.
//!
//! Slice 2a promotes the reviewed eight-slot virtio-mmio inventory and
//! generation-device page into the fresh-only KVM runner. Slots may remain
//! unpopulated, but their addresses, roles, and GSIs are product contracts.

const std = @import("std");
const generation = @import("../generation.zig");
const virtio_blk = @import("../virtio/blk.zig");
const virtio_console = @import("../virtio/console.zig");
const virtio_mem = @import("../virtio/mem.zig");
const virtio_net = @import("../virtio/net.zig");
const virtio_rng = @import("../virtio/rng.zig");
const virtio_vsock = @import("../virtio/vsock.zig");

pub const page_size: u64 = 4096;
pub const min_ram_size: u64 = 64 * 1024 * 1024;
pub const max_ram_size: u64 = 2 * 1024 * 1024 * 1024;
pub const board_profile = "sporevm-x86_64-board-v0";
pub const device_model_version: u32 = 1;

pub const gdt_addr: u64 = 0x0000_0500;
pub const zero_page_addr: u64 = 0x0000_7000;
pub const cmdline_addr: u64 = 0x0002_0000;
pub const kernel_addr: u64 = 0x0010_0000;

/// Intel MP 1.4 floating pointer and configuration table placement. The
/// complete maximum-size table must remain below the GDT.
pub const mp_floating_pointer_addr: u64 = 0x0000_0000;
pub const mp_config_table_addr: u64 = 0x0000_0010;
/// The pinned Linux 6.1.155 kernel scans the bottom 1KiB in 16-byte steps for
/// the MP floating pointer. Keep that complete search window reserved in E820.
pub const mp_scan_window_size: u64 = 0x0000_0400;

pub const legacy_hole_start: u64 = 0x0009_fc00;
pub const legacy_hole_end: u64 = 0x0010_0000;

pub const virtio_base: u64 = 0xd000_0000;
pub const virtio_window_size: u64 = 0x200;
pub const virtio_stride: u64 = virtio_window_size;
pub const virtio_first_gsi: u32 = 5;
pub const max_virtio_devices: usize = 8;

pub const generation_base: u64 = virtio_base + virtio_stride * max_virtio_devices;
pub const generation_size: u64 = generation.window_size;
pub const generation_gsi: u32 = virtio_first_gsi + max_virtio_devices;
pub const poweroff_doorbell_offset: u64 = 0x020;
pub const poweroff_command: u32 = 0x4646_4f50; // "POFF", little-endian bytes

pub const GenerationControlAction = enum { none, read_zero, guest_off };

pub fn generationControlAction(offset: u64, len: u32, is_write: bool, value: u64) !GenerationControlAction {
    const end = std.math.add(u64, offset, len) catch return error.InvalidBoardControl;
    const control_end = poweroff_doorbell_offset + @sizeOf(u32);
    if (offset >= control_end or end <= poweroff_doorbell_offset) return .none;
    if (!is_write) return .read_zero;
    if (offset != poweroff_doorbell_offset or len != @sizeOf(u32) or value != poweroff_command) {
        return error.InvalidBoardControl;
    }
    return .guest_off;
}

/// Preserve the Stage 0a.1 console names while Stage 0a.2 exercises the full
/// ordinary eight-transport inventory.
pub const virtio_console_base: u64 = virtio_base;
pub const virtio_console_gsi: u32 = virtio_first_gsi;

pub const VirtioSlot = struct {
    index: u8,
    base: u64,
    size: u64,
    gsi: u32,
};

/// Frozen board-v0 roles, including the cache-to-transient-memory substitution
/// used by the reviewed probe inventory.
pub const ProbeRole = enum {
    console,
    root,
    context,
    build,
    cache,
    transient_memory,
    net,
    vsock,
    rng,
};

pub const ProbeDevice = enum(u32) {
    net = virtio_net.device_id,
    block = virtio_blk.device_id,
    console = virtio_console.device_id,
    rng = virtio_rng.device_id,
    vsock = virtio_vsock.device_id,
    memory = virtio_mem.device_id,
};

pub const ProbeAttachment = struct {
    role: ProbeRole,
    device: ProbeDevice,
    slot: VirtioSlot,
};

pub const virtio_slots = blk: {
    var slots: [max_virtio_devices]VirtioSlot = undefined;
    for (&slots, 0..) |*slot, index| {
        slot.* = .{
            .index = @intCast(index),
            .base = virtio_base + virtio_stride * index,
            .size = virtio_window_size,
            .gsi = virtio_first_gsi + index,
        };
    }
    break :blk slots;
};

pub const stage0a2_ordinary_inventory = blk: {
    const roles = [_]ProbeRole{ .console, .root, .context, .build, .cache, .net, .vsock, .rng };
    const devices = [_]ProbeDevice{ .console, .block, .block, .block, .block, .net, .vsock, .rng };
    var attachments: [max_virtio_devices]ProbeAttachment = undefined;
    for (&attachments, 0..) |*attachment, index| {
        attachment.* = .{ .role = roles[index], .device = devices[index], .slot = virtio_slots[index] };
    }
    break :blk attachments;
};

fn ordinarySlot(comptime role: ProbeRole) VirtioSlot {
    inline for (stage0a2_ordinary_inventory) |attachment| {
        if (attachment.role == role) return attachment.slot;
    }
    @compileError("role is not present in the ordinary x86 board inventory");
}

pub const console_slot = ordinarySlot(.console);
pub const disk_slots = [_]VirtioSlot{
    ordinarySlot(.root),
    ordinarySlot(.context),
    ordinarySlot(.build),
    ordinarySlot(.cache),
};
pub const net_slot = ordinarySlot(.net);
pub const vsock_slot = ordinarySlot(.vsock);
pub const rng_slot = ordinarySlot(.rng);

/// The transient-memory probe keeps the same eight-slot board and replaces the
/// optional cache attachment at slot 4 with virtio-mem.
pub const stage0a2_transient_memory_inventory = blk: {
    const roles = [_]ProbeRole{ .console, .root, .context, .build, .transient_memory, .net, .vsock, .rng };
    const devices = [_]ProbeDevice{ .console, .block, .block, .block, .memory, .net, .vsock, .rng };
    var attachments: [max_virtio_devices]ProbeAttachment = undefined;
    for (&attachments, 0..) |*attachment, index| {
        attachment.* = .{ .role = roles[index], .device = devices[index], .slot = virtio_slots[index] };
    }
    break :blk attachments;
};

/// Each descriptor is substantially shorter than 64 bytes. Keeping the
/// capacity derived from the slot count gives callers one fixed stack bound.
pub const max_virtio_command_line_len: usize = max_virtio_devices * 64;

pub const local_apic_base: u64 = 0xfee0_0000;
pub const local_apic_size: u64 = 0x0010_0000;
pub const ioapic_base: u64 = 0xfec0_0000;
pub const ioapic_size: u64 = 0x0010_0000;

/// KVM requires the identity-map page and Intel's three-page TSS region below
/// 4GiB and outside every RAM slot and MMIO range.
pub const identity_map_addr: u64 = 0xfffb_c000;
pub const tss_addr: u64 = 0xfffb_d000;
pub const tss_size: u64 = 3 * page_size;

pub const Error = error{
    InvalidRamSize,
    InvalidVirtioSlot,
    InvalidDeviceInventory,
    CommandLineBufferTooSmall,
    BoardRangeOverlap,
    BoardRangeOverflow,
    InvalidBoardControl,
};

pub const Range = struct {
    start: u64,
    size: u64,

    pub fn end(self: Range) Error!u64 {
        return std.math.add(u64, self.start, self.size) catch error.BoardRangeOverflow;
    }
};

pub fn validateRamSize(size: u64) Error!void {
    if (size < min_ram_size or size > max_ram_size or size % page_size != 0) {
        return error.InvalidRamSize;
    }
}

pub fn virtioSlot(index: usize) Error!VirtioSlot {
    if (index >= virtio_slots.len) return error.InvalidVirtioSlot;
    return virtio_slots[index];
}

/// Format all eight Linux virtio-mmio command-line descriptors. Linux probes
/// every reserved window; an unpopulated transport reports device ID zero.
pub fn formatVirtioCommandLine(buffer: []u8) Error![]const u8 {
    var used: usize = 0;
    for (virtio_slots, 0..) |slot, index| {
        const fragment = std.fmt.bufPrint(buffer[used..], "{s}virtio_mmio.device={d}@0x{x}:{d}", .{
            if (index == 0) "" else " ",
            slot.size,
            slot.base,
            slot.gsi,
        }) catch return error.CommandLineBufferTooSmall;
        used += fragment.len;
    }
    return buffer[0..used];
}

pub fn validateDeviceInventory() Error!void {
    if (virtio_slots.len != max_virtio_devices) return error.InvalidDeviceInventory;
    if (generation_base != virtio_base + virtio_stride * max_virtio_devices or
        generation_size != page_size or
        generation_gsi != virtio_first_gsi + max_virtio_devices)
    {
        return error.InvalidDeviceInventory;
    }

    for (virtio_slots, 0..) |slot, index| {
        if (slot.index != index or
            slot.base != virtio_base + virtio_stride * index or
            slot.size != virtio_window_size or
            slot.gsi != virtio_first_gsi + index)
        {
            return error.InvalidDeviceInventory;
        }
        const slot_end = try (Range{ .start = slot.base, .size = slot.size }).end();
        if (slot_end > generation_base or slot.gsi == generation_gsi) {
            return error.InvalidDeviceInventory;
        }
        for (virtio_slots[index + 1 ..]) |other| {
            const other_end = try (Range{ .start = other.base, .size = other.size }).end();
            if ((slot.base < other_end and other.base < slot_end) or slot.gsi == other.gsi) {
                return error.InvalidDeviceInventory;
            }
        }
    }
}

/// Accept only the two exact Stage 0a.2 inventories. Roles, device kinds, slot
/// addresses, and GSIs all belong to the board contract.
pub fn validateProbeInventory(inventory: *const [max_virtio_devices]ProbeAttachment) Error!void {
    if (probeInventoriesEqual(inventory, &stage0a2_ordinary_inventory) or
        probeInventoriesEqual(inventory, &stage0a2_transient_memory_inventory))
    {
        return;
    }
    return error.InvalidDeviceInventory;
}

fn probeInventoriesEqual(
    actual: *const [max_virtio_devices]ProbeAttachment,
    expected: *const [max_virtio_devices]ProbeAttachment,
) bool {
    for (actual, expected) |actual_attachment, expected_attachment| {
        if (actual_attachment.role != expected_attachment.role or
            actual_attachment.device != expected_attachment.device or
            actual_attachment.slot.index != expected_attachment.slot.index or
            actual_attachment.slot.base != expected_attachment.slot.base or
            actual_attachment.slot.size != expected_attachment.slot.size or
            actual_attachment.slot.gsi != expected_attachment.slot.gsi)
        {
            return false;
        }
    }
    return true;
}

pub fn validateLayout(ram_size: u64) Error!void {
    try validateRamSize(ram_size);
    try validateDeviceInventory();
    const ranges = [_]Range{
        .{ .start = 0, .size = ram_size },
        .{ .start = virtio_base, .size = virtio_stride * max_virtio_devices },
        .{ .start = generation_base, .size = generation_size },
        .{ .start = ioapic_base, .size = ioapic_size },
        .{ .start = local_apic_base, .size = local_apic_size },
        .{ .start = identity_map_addr, .size = page_size },
        .{ .start = tss_addr, .size = tss_size },
    };

    for (ranges, 0..) |range, i| {
        const range_end = try range.end();
        for (ranges[i + 1 ..]) |other| {
            const other_end = try other.end();
            if (range.start < other_end and other.start < range_end) {
                return error.BoardRangeOverlap;
            }
        }
    }
}

test "frozen board keeps low RAM, device windows, and KVM holes disjoint" {
    try validateLayout(max_ram_size);
    try std.testing.expect(identity_map_addr + page_size == tss_addr);
    try std.testing.expect(tss_addr + tss_size <= std.math.maxInt(u32));
    try std.testing.expect(mp_config_table_addr < gdt_addr);
}

test "frozen board rejects unaligned and oversized RAM" {
    try std.testing.expectError(error.InvalidRamSize, validateLayout(min_ram_size - page_size));
    try std.testing.expectError(error.InvalidRamSize, validateLayout(max_ram_size + page_size));
    try std.testing.expectError(error.InvalidRamSize, validateLayout(min_ram_size + 1));
}

test "complete virtio and generation inventory is bounded and collision-free" {
    try validateDeviceInventory();
    try std.testing.expectEqual(@as(usize, 8), virtio_slots.len);
    try std.testing.expectEqual(@as(u64, 0xd000_0000), (try virtioSlot(0)).base);
    try std.testing.expectEqual(@as(u64, 0xd000_0e00), (try virtioSlot(7)).base);
    try std.testing.expectEqual(@as(u32, 5), (try virtioSlot(0)).gsi);
    try std.testing.expectEqual(@as(u32, 12), (try virtioSlot(7)).gsi);
    try std.testing.expectEqual(@as(u64, 0xd000_1000), generation_base);
    try std.testing.expectEqual(@as(u32, 13), generation_gsi);
    try std.testing.expectError(error.InvalidVirtioSlot, virtioSlot(max_virtio_devices));
}

test "x86 board poweroff doorbell is exact fail closed and stateless" {
    try std.testing.expectEqual(GenerationControlAction.guest_off, try generationControlAction(poweroff_doorbell_offset, 4, true, poweroff_command));
    try std.testing.expectEqual(GenerationControlAction.none, try generationControlAction(0x014, 4, true, 1));
    try std.testing.expectEqual(GenerationControlAction.read_zero, try generationControlAction(poweroff_doorbell_offset, 4, false, 0));
    try std.testing.expectEqual(GenerationControlAction.read_zero, try generationControlAction(poweroff_doorbell_offset, 8, false, 0));

    try std.testing.expectError(error.InvalidBoardControl, generationControlAction(poweroff_doorbell_offset, 1, true, poweroff_command));
    try std.testing.expectError(error.InvalidBoardControl, generationControlAction(poweroff_doorbell_offset, 2, true, poweroff_command));
    try std.testing.expectError(error.InvalidBoardControl, generationControlAction(poweroff_doorbell_offset, 8, true, poweroff_command));
    try std.testing.expectError(error.InvalidBoardControl, generationControlAction(poweroff_doorbell_offset, 4, true, poweroff_command ^ 1));
    try std.testing.expectError(error.InvalidBoardControl, generationControlAction(poweroff_doorbell_offset - 4, 8, true, poweroff_command));
}

fn fuzzGenerationControl(_: void, smith: *std.testing.Smith) !void {
    const offset = smith.value(u64);
    const len = smith.value(u32);
    const is_write = smith.value(bool);
    const value = smith.value(u64);
    const action = generationControlAction(offset, len, is_write, value) catch return;
    if (action == .guest_off) {
        try std.testing.expectEqual(poweroff_doorbell_offset, offset);
        try std.testing.expectEqual(@as(u32, @sizeOf(u32)), len);
        try std.testing.expect(is_write);
        try std.testing.expectEqual(@as(u64, poweroff_command), value);
    }
    if (len == 8) try std.testing.expect(action != .guest_off);
}

test "fuzz x86 generation control never launders a poweroff" {
    try std.testing.fuzz({}, fuzzGenerationControl, .{});
}

test "maximum virtio command line describes every reserved slot exactly once" {
    var buffer: [max_virtio_command_line_len]u8 = undefined;
    const command_line = try formatVirtioCommandLine(&buffer);
    try std.testing.expect(command_line.len < buffer.len);
    try std.testing.expectEqual(@as(usize, max_virtio_devices), std.mem.count(u8, command_line, "virtio_mmio.device="));
    try std.testing.expect(std.mem.startsWith(u8, command_line, "virtio_mmio.device=512@0xd0000000:5"));
    try std.testing.expect(std.mem.endsWith(u8, command_line, "virtio_mmio.device=512@0xd0000e00:12"));

    var too_small: [1]u8 = undefined;
    try std.testing.expectError(error.CommandLineBufferTooSmall, formatVirtioCommandLine(&too_small));
}

test "ordinary probe inventory locks current role address GSI and device multiset" {
    const expected_roles = [_]ProbeRole{ .console, .root, .context, .build, .cache, .net, .vsock, .rng };
    const expected_ids = [_]u32{ 3, 2, 2, 2, 2, 1, 19, 4 };
    for (stage0a2_ordinary_inventory, 0..) |attachment, index| {
        try std.testing.expectEqual(expected_roles[index], attachment.role);
        try std.testing.expectEqual(expected_ids[index], @intFromEnum(attachment.device));
        try std.testing.expectEqual(virtio_base + virtio_stride * index, attachment.slot.base);
        try std.testing.expectEqual(virtio_first_gsi + index, attachment.slot.gsi);
    }
    try validateProbeInventory(&stage0a2_ordinary_inventory);
}

test "transient virtio-mem inventory replaces cache at slot four exactly" {
    const expected_roles = [_]ProbeRole{ .console, .root, .context, .build, .transient_memory, .net, .vsock, .rng };
    const expected_ids = [_]u32{ 3, 2, 2, 2, 24, 1, 19, 4 };
    for (stage0a2_transient_memory_inventory, 0..) |attachment, index| {
        try std.testing.expectEqual(expected_roles[index], attachment.role);
        try std.testing.expectEqual(expected_ids[index], @intFromEnum(attachment.device));
        try std.testing.expectEqual(virtio_slots[index], attachment.slot);
    }
    try validateProbeInventory(&stage0a2_transient_memory_inventory);

    var wrong_role = stage0a2_transient_memory_inventory;
    wrong_role[4].role = .cache;
    try std.testing.expectError(error.InvalidDeviceInventory, validateProbeInventory(&wrong_role));

    var wrong_slot = stage0a2_transient_memory_inventory;
    wrong_slot[4].slot = virtio_slots[5];
    try std.testing.expectError(error.InvalidDeviceInventory, validateProbeInventory(&wrong_slot));

    var unexpected_memory = stage0a2_ordinary_inventory;
    unexpected_memory[4].device = .memory;
    try std.testing.expectError(error.InvalidDeviceInventory, validateProbeInventory(&unexpected_memory));
}
