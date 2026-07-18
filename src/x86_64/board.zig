//! Provisional x86-64 board constants for the host-only KVM boot harness.
//!
//! Stage 0a.1 deliberately exposes one low RAM region and one virtio-console.
//! Later Slice 0a stages must prove and freeze the complete device topology
//! before these addresses become a product contract.

const std = @import("std");

pub const page_size: u64 = 4096;
pub const min_ram_size: u64 = 64 * 1024 * 1024;
pub const max_ram_size: u64 = 2 * 1024 * 1024 * 1024;

pub const gdt_addr: u64 = 0x0000_0500;
pub const zero_page_addr: u64 = 0x0000_7000;
pub const cmdline_addr: u64 = 0x0002_0000;
pub const kernel_addr: u64 = 0x0010_0000;

pub const legacy_hole_start: u64 = 0x0009_fc00;
pub const legacy_hole_end: u64 = 0x0010_0000;

pub const virtio_console_base: u64 = 0xd000_0000;
pub const virtio_window_size: u64 = 0x200;
pub const virtio_console_gsi: u32 = 5;

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
    BoardRangeOverlap,
    BoardRangeOverflow,
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

pub fn validateLayout(ram_size: u64) Error!void {
    try validateRamSize(ram_size);
    const ranges = [_]Range{
        .{ .start = 0, .size = ram_size },
        .{ .start = virtio_console_base, .size = virtio_window_size },
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

test "provisional board keeps low RAM and KVM holes disjoint" {
    try validateLayout(max_ram_size);
    try std.testing.expect(identity_map_addr + page_size == tss_addr);
    try std.testing.expect(tss_addr + tss_size <= std.math.maxInt(u32));
}

test "provisional board rejects unaligned and oversized RAM" {
    try std.testing.expectError(error.InvalidRamSize, validateLayout(min_ram_size - page_size));
    try std.testing.expectError(error.InvalidRamSize, validateLayout(max_ram_size + page_size));
    try std.testing.expectError(error.InvalidRamSize, validateLayout(min_ram_size + 1));
}
