//! GICv3 MMIO forwarding for hv_gic (macOS 15+).
//!
//! Apple's in-kernel GIC delivers interrupts and implements the ICC system
//! register interface, but memory-mapped distributor/redistributor accesses
//! trap to userspace. The hv_gic_{get,set}_{distributor,redistributor}_reg
//! APIs are keyed by register *offset* (the enum values in hv_gic_types.h are
//! the architectural offsets), so forwarding is mechanical. Offsets the
//! framework does not know are RAZ/WI — notably GICR_WAKER, where
//! reads-as-zero conveniently reports "awake".

const std = @import("std");
const hvf = @import("hvf.zig");
const gicv3 = @import("../aarch64/gicv3.zig");

extern "c" fn hv_gic_get_distributor_reg(reg: u16, value: *u64) hvf.ReturnCode;
extern "c" fn hv_gic_set_distributor_reg(reg: u16, value: u64) hvf.ReturnCode;
extern "c" fn hv_gic_get_redistributor_reg(vcpu: hvf.VcpuHandle, reg: u32, value: *u64) hvf.ReturnCode;
extern "c" fn hv_gic_set_redistributor_reg(vcpu: hvf.VcpuHandle, reg: u32, value: u64) hvf.ReturnCode;

pub const Region = enum { distributor, redistributor };

pub const StrictAccessError = error{UnsupportedGicRegister};

/// Strict snapshot/probe read path. Unlike `mmioRead`, unsupported offsets are
/// errors because callers are trying to prove whether a portable state mapping
/// is complete.
pub fn readRegStrict(region: Region, vcpu: hvf.VcpuHandle, spec: gicv3.RegSpec) StrictAccessError!gicv3.MmioReg {
    var value: u64 = 0;
    const ret = switch (region) {
        .distributor => hv_gic_get_distributor_reg(@intCast(spec.offset & 0xffff), &value),
        .redistributor => hv_gic_get_redistributor_reg(vcpu, spec.offset, &value),
    };
    if (ret != hvf.success) return error.UnsupportedGicRegister;
    if (spec.width_bits == 32) value &= 0xffff_ffff;
    return .{ .offset = spec.offset, .width_bits = spec.width_bits, .value = value };
}

/// Strict snapshot/probe write path. This is not used by guest MMIO emulation;
/// it exists so future portable restore code can fail closed on unsupported
/// HVF GIC offsets instead of silently dropping state.
pub fn writeRegStrict(region: Region, vcpu: hvf.VcpuHandle, reg: gicv3.MmioReg) StrictAccessError!void {
    const ret = switch (region) {
        .distributor => hv_gic_set_distributor_reg(@intCast(reg.offset & 0xffff), reg.value),
        .redistributor => hv_gic_set_redistributor_reg(vcpu, reg.offset, reg.value),
    };
    if (ret != hvf.success) return error.UnsupportedGicRegister;
}

/// Service a trapped read from a GIC frame. Unknown registers read as zero.
pub fn mmioRead(region: Region, vcpu: hvf.VcpuHandle, offset: u64, size_log2: u2) u64 {
    // 32-bit reads of the high half of a 64-bit register (e.g. GICR_TYPER at
    // +0xc) are forwarded as a 64-bit read of the aligned base.
    const wide_high_half = size_log2 == 2 and isUpperHalfOf64(region, offset);
    const base_offset = if (wide_high_half) offset - 4 else offset;

    var value: u64 = 0;
    const ret = switch (region) {
        .distributor => hv_gic_get_distributor_reg(@intCast(base_offset & 0xffff), &value),
        .redistributor => hv_gic_get_redistributor_reg(vcpu, @intCast(base_offset & 0x1_ffff), &value),
    };
    if (ret != hvf.success) {
        std.log.debug("gic {s} read of unsupported offset 0x{x} -> 0 (hv_return_t=0x{x})", .{ @tagName(region), offset, @as(u32, @bitCast(ret)) });
        return 0;
    }
    if (wide_high_half) return value >> 32;
    return value;
}

/// Service a trapped write to a GIC frame. Unknown registers are ignored.
pub fn mmioWrite(region: Region, vcpu: hvf.VcpuHandle, offset: u64, value: u64) void {
    const ret = switch (region) {
        .distributor => hv_gic_set_distributor_reg(@intCast(offset & 0xffff), value),
        .redistributor => hv_gic_set_redistributor_reg(vcpu, @intCast(offset & 0x1_ffff), value),
    };
    if (ret != hvf.success) {
        std.log.debug("gic {s} write of unsupported offset 0x{x} (value 0x{x}) ignored", .{ @tagName(region), offset, value });
    }
}

/// 64-bit GIC registers whose upper word the guest may read with a 32-bit
/// access: GICR_TYPER (+0x8) and GICD_IROUTER<n> (0x6100..0x7fe0).
fn isUpperHalfOf64(region: Region, offset: u64) bool {
    return switch (region) {
        .redistributor => offset == 0xc,
        .distributor => offset >= 0x6104 and offset < 0x8000 and (offset & 7) == 4,
    };
}

test "upper-half detection" {
    try std.testing.expect(isUpperHalfOf64(.redistributor, 0xc));
    try std.testing.expect(!isUpperHalfOf64(.redistributor, 0x8));
    try std.testing.expect(isUpperHalfOf64(.distributor, 0x6104));
    try std.testing.expect(!isUpperHalfOf64(.distributor, 0x6100));
}
