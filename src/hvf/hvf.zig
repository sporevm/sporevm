//! Hand-written Hypervisor.framework bindings (aarch64 macOS).
//!
//! Derived from the MacOSX SDK headers
//! (`Hypervisor.framework/Headers/hv_vm.h`, `hv_vcpu.h`, `hv_vcpu_types.h`,
//! `hv_vm_types.h`). We own these bindings deliberately: the surface SporeVM
//! uses is small, and the declarations double as documentation of exactly
//! which hypervisor facilities we depend on.
//!
//! Callers must run in a binary signed with the
//! `com.apple.security.hypervisor` entitlement (see `spore.entitlements`).

const std = @import("std");
const builtin = @import("builtin");

pub const vm = if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)
    @import("vm.zig")
else
    struct {};

pub const ReturnCode = i32; // hv_return_t
pub const success: ReturnCode = 0; // HV_SUCCESS

pub const VcpuHandle = u64; // hv_vcpu_t
pub const Ipa = u64; // hv_ipa_t

pub const MemoryFlags = packed struct(u64) {
    read: bool = false,
    write: bool = false,
    exec: bool = false,
    _reserved: u61 = 0,

    pub const rwx: MemoryFlags = .{ .read = true, .write = true, .exec = true };
    pub const rx: MemoryFlags = .{ .read = true, .exec = true };
};

/// hv_reg_t (OS_ENUM, u32). X0..X30 are 0..30, then PC, FPCR, FPSR, CPSR.
pub const Reg = enum(u32) {
    x0 = 0,
    x1 = 1,
    x2 = 2,
    x3 = 3,
    x4 = 4,
    x5 = 5,
    x6 = 6,
    x7 = 7,
    x8 = 8,
    x9 = 9,
    x10 = 10,
    x11 = 11,
    x12 = 12,
    x13 = 13,
    x14 = 14,
    x15 = 15,
    x16 = 16,
    x17 = 17,
    x18 = 18,
    x19 = 19,
    x20 = 20,
    x21 = 21,
    x22 = 22,
    x23 = 23,
    x24 = 24,
    x25 = 25,
    x26 = 26,
    x27 = 27,
    x28 = 28,
    x29 = 29, // FP
    x30 = 30, // LR
    pc = 31,
    fpcr = 32,
    fpsr = 33,
    cpsr = 34,
};

/// hv_exit_reason_t (OS_ENUM, u32).
pub const ExitReason = enum(u32) {
    canceled = 0,
    exception = 1,
    vtimer_activated = 2,
    unknown = 3,
    _,
};

pub const ExitException = extern struct {
    syndrome: u64, // ESR_ELx
    virtual_address: u64, // FAR_ELx
    physical_address: Ipa,

    /// Exception class: ESR_ELx[31:26].
    pub fn exceptionClass(self: ExitException) u6 {
        return @truncate(self.syndrome >> 26);
    }
};

pub const VcpuExit = extern struct {
    reason: ExitReason,
    exception: ExitException,
};

// Exception classes we care about during bring-up.
pub const ec_hvc: u6 = 0x16;
pub const ec_smc: u6 = 0x17;
pub const ec_brk: u6 = 0x3c;
pub const ec_data_abort: u6 = 0x24;

pub extern "c" fn hv_vm_create(config: ?*anyopaque) ReturnCode;
pub extern "c" fn hv_vm_destroy() ReturnCode;
pub extern "c" fn hv_vm_map(addr: *anyopaque, ipa: Ipa, size: usize, flags: MemoryFlags) ReturnCode;
pub extern "c" fn hv_vm_unmap(ipa: Ipa, size: usize) ReturnCode;
pub extern "c" fn hv_vcpu_create(vcpu: *VcpuHandle, exit: **VcpuExit, config: ?*anyopaque) ReturnCode;
pub extern "c" fn hv_vcpu_destroy(vcpu: VcpuHandle) ReturnCode;
pub extern "c" fn hv_vcpu_run(vcpu: VcpuHandle) ReturnCode;
pub extern "c" fn hv_vcpu_get_reg(vcpu: VcpuHandle, reg: Reg, value: *u64) ReturnCode;
pub extern "c" fn hv_vcpu_set_reg(vcpu: VcpuHandle, reg: Reg, value: u64) ReturnCode;
pub extern "c" fn hv_vcpu_set_trap_debug_exceptions(vcpu: VcpuHandle, value: bool) ReturnCode;
pub extern "c" fn hv_vcpu_set_vtimer_mask(vcpu: VcpuHandle, vtimer_is_masked: bool) ReturnCode;
pub extern "c" fn hv_vcpu_get_sys_reg(vcpu: VcpuHandle, reg: SysReg, value: *u64) ReturnCode;
pub extern "c" fn hv_vcpu_set_sys_reg(vcpu: VcpuHandle, reg: SysReg, value: u64) ReturnCode;

/// hv_sys_reg_t (u16). Values are the architectural system register
/// encodings; only the registers SporeVM touches are listed.
pub const SysReg = enum(u16) {
    midr_el1 = 0xc000,
    mpidr_el1 = 0xc005,
    sctlr_el1 = 0xc080,
    cpacr_el1 = 0xc082,
    ttbr0_el1 = 0xc100,
    ttbr1_el1 = 0xc101,
    tcr_el1 = 0xc102,
    spsr_el1 = 0xc200,
    elr_el1 = 0xc201,
    sp_el0 = 0xc208,
    afsr0_el1 = 0xc288,
    afsr1_el1 = 0xc289,
    esr_el1 = 0xc290,
    far_el1 = 0xc300,
    par_el1 = 0xc3a0,
    mair_el1 = 0xc510,
    amair_el1 = 0xc518,
    vbar_el1 = 0xc600,
    contextidr_el1 = 0xc681,
    tpidr_el1 = 0xc684,
    cntkctl_el1 = 0xc708,
    csselr_el1 = 0xd000,
    tpidr_el0 = 0xde82,
    tpidrro_el0 = 0xde83,
    cntv_ctl_el0 = 0xdf19,
    cntv_cval_el0 = 0xdf1a,
    sp_el1 = 0xe208,
    _,
};

/// 16-byte SIMD&FP register value (hv_simd_fp_uchar16_t).
pub const SimdReg = extern struct {
    bytes: [16]u8 align(16),
};

pub extern "c" fn hv_vcpu_get_simd_fp_reg(vcpu: VcpuHandle, reg: u32, value: *SimdReg) ReturnCode;
pub extern "c" fn hv_vcpu_set_simd_fp_reg(vcpu: VcpuHandle, reg: u32, value: SimdReg) ReturnCode;
pub extern "c" fn hv_vcpu_get_vtimer_offset(vcpu: VcpuHandle, offset: *u64) ReturnCode;
pub extern "c" fn hv_vcpu_set_vtimer_offset(vcpu: VcpuHandle, offset: u64) ReturnCode;

/// hv_gic_icc_reg_t (u16): per-vCPU GIC CPU-interface system registers.
/// These are not part of the hv_gic state blob and must be saved/restored
/// individually.
pub const IccReg = enum(u16) {
    pmr_el1 = 0xc230,
    bpr0_el1 = 0xc643,
    ap0r0_el1 = 0xc644,
    ap1r0_el1 = 0xc648,
    bpr1_el1 = 0xc663,
    ctlr_el1 = 0xc664,
    sre_el1 = 0xc665,
    igrpen0_el1 = 0xc666,
    igrpen1_el1 = 0xc667,
    _,
};

pub extern "c" fn hv_gic_get_icc_reg(vcpu: VcpuHandle, reg: IccReg, value: *u64) ReturnCode;
pub extern "c" fn hv_gic_set_icc_reg(vcpu: VcpuHandle, reg: IccReg, value: u64) ReturnCode;

// GIC state save/restore (macOS 15+).
pub extern "c" fn hv_gic_state_create() ?*anyopaque;
pub extern "c" fn hv_gic_state_get_size(state: *anyopaque, size: *usize) ReturnCode;
pub extern "c" fn hv_gic_state_get_data(state: *anyopaque, data: [*]u8) ReturnCode;
pub extern "c" fn hv_gic_set_state(data: [*]const u8, size: usize) ReturnCode;
pub extern "c" fn hv_vcpus_exit(vcpus: [*]VcpuHandle, vcpu_count: u32) ReturnCode;

// GICv3 (macOS 15+). hv_gic_create must run after hv_vm_create and before
// any hv_vcpu_create. State save/restore (hv_gic_state_*) lands with the
// snapshot slice.
pub extern "c" fn hv_gic_config_create() *anyopaque;
pub extern "c" fn hv_gic_config_set_distributor_base(config: *anyopaque, base: Ipa) ReturnCode;
pub extern "c" fn hv_gic_config_set_redistributor_base(config: *anyopaque, base: Ipa) ReturnCode;
pub extern "c" fn hv_gic_create(config: *anyopaque) ReturnCode;
pub extern "c" fn hv_gic_set_spi(intid: u32, level: bool) ReturnCode;
pub extern "c" fn hv_gic_get_distributor_size(size: *usize) ReturnCode;
pub extern "c" fn hv_gic_get_distributor_base_alignment(alignment: *usize) ReturnCode;
pub extern "c" fn hv_gic_get_redistributor_region_size(size: *usize) ReturnCode;
pub extern "c" fn hv_gic_get_redistributor_base_alignment(alignment: *usize) ReturnCode;
pub extern "c" fn hv_gic_get_spi_interrupt_range(intid_base: *u32, intid_count: *u32) ReturnCode;
pub extern "c" fn hv_gic_get_redistributor_size(size: *usize) ReturnCode;
pub extern "c" fn hv_gic_get_redistributor_base(vcpu: VcpuHandle, base: *Ipa) ReturnCode;

/// Release an os_object (e.g. the value from hv_gic_config_create).
pub extern "c" fn os_release(object: *anyopaque) void;

pub const Error = error{HvCallFailed};

/// Convert an hv_return_t into a Zig error, logging the raw code.
pub fn check(ret: ReturnCode, what: []const u8) Error!void {
    if (ret != success) {
        std.log.err("{s} failed: hv_return_t=0x{x}", .{ what, @as(u32, @bitCast(ret)) });
        return error.HvCallFailed;
    }
}

test "memory flags ABI matches HV_MEMORY_* bit positions" {
    try std.testing.expectEqual(@as(u64, 0b111), @as(u64, @bitCast(MemoryFlags.rwx)));
    try std.testing.expectEqual(@as(u64, 0b101), @as(u64, @bitCast(MemoryFlags.rx)));
}

test "exception class extraction" {
    const exc = ExitException{
        .syndrome = @as(u64, 0x16) << 26,
        .virtual_address = 0,
        .physical_address = 0,
    };
    try std.testing.expectEqual(ec_hvc, exc.exceptionClass());
}
