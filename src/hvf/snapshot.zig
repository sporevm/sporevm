//! HVF machine-state capture and restore.
//!
//! Converts between live HVF vCPU/GIC state and the normalized architectural
//! `spore.MachineState`. Nothing hypervisor-specific leaks into the manifest:
//! registers are stored by architectural name, and the GIC blob is the only
//! opaque field (consumed by the same backend until cross-hypervisor GIC
//! normalization lands in slice 4).

const std = @import("std");
const hvf = @import("hvf.zig");
const spore = @import("../spore.zig");

/// EL1 context registers captured into the spore, by architectural name.
/// Order is part of the v0 format only insofar as names must round-trip.
const saved_sys_regs = [_]hvf.SysReg{
    .sctlr_el1,
    .cpacr_el1,
    .ttbr0_el1,
    .ttbr1_el1,
    .tcr_el1,
    .spsr_el1,
    .elr_el1,
    .sp_el0,
    .sp_el1,
    .afsr0_el1,
    .afsr1_el1,
    .esr_el1,
    .far_el1,
    .par_el1,
    .mair_el1,
    .amair_el1,
    .vbar_el1,
    .contextidr_el1,
    .tpidr_el1,
    .cntkctl_el1,
    .csselr_el1,
    .tpidr_el0,
    .tpidrro_el0,
    .mpidr_el1,
};

/// Read the host's virtual counter (CNTVCT_EL0); the guest's virtual time is
/// this minus the vtimer offset.
pub fn hostCounter() u64 {
    return asm volatile ("mrs %[ret], cntvct_el0"
        : [ret] "=r" (-> u64),
    );
}

/// Counter frequency in Hz (CNTFRQ_EL0; 24MHz on Apple Silicon).
pub fn hostCounterFreq() u64 {
    return asm volatile ("mrs %[ret], cntfrq_el0"
        : [ret] "=r" (-> u64),
    );
}

pub fn captureMachine(allocator: std.mem.Allocator, vcpu: hvf.VcpuHandle) !spore.MachineState {
    var state: spore.MachineState = undefined;

    for (0..31) |i| {
        try hvf.check(hvf.hv_vcpu_get_reg(vcpu, @enumFromInt(@as(u32, @intCast(i))), &state.gprs[i]), "get gpr");
    }
    try hvf.check(hvf.hv_vcpu_get_reg(vcpu, .pc, &state.pc), "get pc");
    try hvf.check(hvf.hv_vcpu_get_reg(vcpu, .cpsr, &state.cpsr), "get cpsr");
    try hvf.check(hvf.hv_vcpu_get_reg(vcpu, .fpcr, &state.fpcr), "get fpcr");
    try hvf.check(hvf.hv_vcpu_get_reg(vcpu, .fpsr, &state.fpsr), "get fpsr");

    for (0..32) |i| {
        var q: hvf.SimdReg = undefined;
        try hvf.check(hvf.hv_vcpu_get_simd_fp_reg(vcpu, @intCast(i), &q), "get simd");
        state.simd[i][0] = std.mem.readInt(u64, q.bytes[0..8], .little);
        state.simd[i][1] = std.mem.readInt(u64, q.bytes[8..16], .little);
    }

    const regs = try allocator.alloc(spore.SysRegEntry, saved_sys_regs.len);
    for (saved_sys_regs, 0..) |reg, i| {
        var value: u64 = undefined;
        try hvf.check(hvf.hv_vcpu_get_sys_reg(vcpu, reg, &value), "get sysreg");
        regs[i] = .{ .name = @tagName(reg), .value = value };
    }
    state.sys_regs = regs;

    // Virtual timer: normalize to the guest's virtual counter value.
    var voff: u64 = 0;
    try hvf.check(hvf.hv_vcpu_get_vtimer_offset(vcpu, &voff), "get vtimer offset");
    var cntv_ctl: u64 = 0;
    var cntv_cval: u64 = 0;
    try hvf.check(hvf.hv_vcpu_get_sys_reg(vcpu, .cntv_ctl_el0, &cntv_ctl), "get cntv_ctl");
    try hvf.check(hvf.hv_vcpu_get_sys_reg(vcpu, .cntv_cval_el0, &cntv_cval), "get cntv_cval");
    state.vtimer = .{
        .cntvct = hostCounter() -% voff,
        .cntv_ctl = cntv_ctl,
        .cntv_cval = cntv_cval,
    };

    const icc_save = [_]hvf.IccReg{
        .pmr_el1,
        .bpr0_el1,
        .ap0r0_el1,
        .ap1r0_el1,
        .bpr1_el1,
        .ctlr_el1,
        .sre_el1,
        .igrpen0_el1,
        .igrpen1_el1,
    };
    const icc = try allocator.alloc(spore.SysRegEntry, icc_save.len);
    for (icc_save, 0..) |reg, i| {
        var value: u64 = 0;
        try hvf.check(hvf.hv_gic_get_icc_reg(vcpu, reg, &value), "get icc reg");
        icc[i] = .{ .name = @tagName(reg), .value = value };
    }
    state.icc_regs = icc;

    state.gic_state_b64 = try captureGic(allocator);
    return state;
}

pub fn applyMachine(allocator: std.mem.Allocator, vcpu: hvf.VcpuHandle, state: spore.MachineState) !void {
    // GIC state first: must be applied before the vCPU runs.
    try applyGic(allocator, state.gic_state_b64);

    for (0..31) |i| {
        try hvf.check(hvf.hv_vcpu_set_reg(vcpu, @enumFromInt(@as(u32, @intCast(i))), state.gprs[i]), "set gpr");
    }
    try hvf.check(hvf.hv_vcpu_set_reg(vcpu, .pc, state.pc), "set pc");
    try hvf.check(hvf.hv_vcpu_set_reg(vcpu, .cpsr, state.cpsr), "set cpsr");
    try hvf.check(hvf.hv_vcpu_set_reg(vcpu, .fpcr, state.fpcr), "set fpcr");
    try hvf.check(hvf.hv_vcpu_set_reg(vcpu, .fpsr, state.fpsr), "set fpsr");

    for (0..32) |i| {
        var q: hvf.SimdReg = undefined;
        std.mem.writeInt(u64, q.bytes[0..8], state.simd[i][0], .little);
        std.mem.writeInt(u64, q.bytes[8..16], state.simd[i][1], .little);
        try hvf.check(hvf.hv_vcpu_set_simd_fp_reg(vcpu, @intCast(i), q), "set simd");
    }

    for (state.sys_regs) |entry| {
        const reg = std.meta.stringToEnum(hvf.SysReg, entry.name) orelse {
            std.log.err("unknown sysreg in spore: {s}", .{entry.name});
            return error.PlatformMismatch;
        };
        if (reg == .mpidr_el1) continue; // set during vCPU bring-up
        try hvf.check(hvf.hv_vcpu_set_sys_reg(vcpu, reg, entry.value), "set sysreg");
    }

    for (state.icc_regs) |entry| {
        const reg = std.meta.stringToEnum(hvf.IccReg, entry.name) orelse {
            std.log.err("unknown icc reg in spore: {s}", .{entry.name});
            return error.PlatformMismatch;
        };
        try hvf.check(hvf.hv_gic_set_icc_reg(vcpu, reg, entry.value), "set icc reg");
    }

    // Re-anchor the virtual counter: guest time continues from the snapshot.
    const new_offset = hostCounter() -% state.vtimer.cntvct;
    try hvf.check(hvf.hv_vcpu_set_vtimer_offset(vcpu, new_offset), "set vtimer offset");
    try hvf.check(hvf.hv_vcpu_set_sys_reg(vcpu, .cntv_cval_el0, state.vtimer.cntv_cval), "set cntv_cval");
    try hvf.check(hvf.hv_vcpu_set_sys_reg(vcpu, .cntv_ctl_el0, state.vtimer.cntv_ctl), "set cntv_ctl");
    try hvf.check(hvf.hv_vcpu_set_vtimer_mask(vcpu, false), "vtimer unmask");
}

fn captureGic(allocator: std.mem.Allocator) ![]const u8 {
    const state = hvf.hv_gic_state_create() orelse return error.HvCallFailed;
    defer hvf.os_release(state);
    var size: usize = 0;
    try hvf.check(hvf.hv_gic_state_get_size(state, &size), "gic state size");
    const raw = try allocator.alloc(u8, size);
    defer allocator.free(raw);
    try hvf.check(hvf.hv_gic_state_get_data(state, raw.ptr), "gic state data");

    const enc = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(raw.len));
    _ = enc.encode(out, raw);
    return out;
}

fn applyGic(allocator: std.mem.Allocator, b64: []const u8) !void {
    const dec = std.base64.standard.Decoder;
    const size = dec.calcSizeForSlice(b64) catch return error.PlatformMismatch;
    const raw = try allocator.alloc(u8, size);
    defer allocator.free(raw);
    dec.decode(raw, b64) catch return error.PlatformMismatch;
    try hvf.check(hvf.hv_gic_set_state(raw.ptr, raw.len), "hv_gic_set_state");
}
