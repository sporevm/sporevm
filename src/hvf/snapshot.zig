//! HVF machine-state capture and restore.
//!
//! Converts between live HVF vCPU/GIC state and the normalized architectural
//! `spore.MachineState`. Registers are stored by architectural name. HVF's
//! GIC state remains a tagged backend-private blob until the HVF GICv3 mapping
//! lands in the cross-hypervisor slice.

const std = @import("std");
const hvf = @import("hvf.zig");
const board = @import("../board.zig");
const gicv3 = @import("../gicv3.zig");
const spore = @import("../spore.zig");
const topology = @import("../topology.zig");

pub const VcpuRef = struct {
    index: topology.VcpuIndex,
    handle: hvf.VcpuHandle,
};

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
    const vcpu_state = try captureVcpuState(allocator, .{ .index = 0, .handle = vcpu });
    return .{
        .gprs = vcpu_state.gprs,
        .pc = vcpu_state.pc,
        .cpsr = vcpu_state.cpsr,
        .fpcr = vcpu_state.fpcr,
        .fpsr = vcpu_state.fpsr,
        .simd = vcpu_state.simd,
        .sys_regs = vcpu_state.sys_regs,
        .icc_regs = vcpu_state.icc_regs,
        .vtimer = vcpu_state.vtimer,
        .gic = try captureGicState(allocator),
    };
}

pub fn captureMachineV1(allocator: std.mem.Allocator, vcpus: []spore.VcpuState) !spore.MachineStateV1 {
    if (vcpus.len == 0 or vcpus.len > topology.max_vcpus) return error.PlatformMismatch;
    const machine = spore.MachineStateV1{
        .vcpus = vcpus,
        .gic = try captureGicState(allocator),
    };
    try gicv3.validate(machine.gic);
    return machine;
}

pub fn captureVcpuState(allocator: std.mem.Allocator, vcpu: VcpuRef) !spore.VcpuState {
    var state: spore.VcpuState = undefined;
    state.index = vcpu.index;
    state.mpidr = topology.mpidrForIndex(vcpu.index);

    for (0..31) |i| {
        try hvf.check(hvf.hv_vcpu_get_reg(vcpu.handle, @enumFromInt(@as(u32, @intCast(i))), &state.gprs[i]), "get gpr");
    }
    try hvf.check(hvf.hv_vcpu_get_reg(vcpu.handle, .pc, &state.pc), "get pc");
    try hvf.check(hvf.hv_vcpu_get_reg(vcpu.handle, .cpsr, &state.cpsr), "get cpsr");
    try hvf.check(hvf.hv_vcpu_get_reg(vcpu.handle, .fpcr, &state.fpcr), "get fpcr");
    try hvf.check(hvf.hv_vcpu_get_reg(vcpu.handle, .fpsr, &state.fpsr), "get fpsr");

    for (0..32) |i| {
        var q: hvf.SimdReg = undefined;
        try hvf.check(hvf.hv_vcpu_get_simd_fp_reg(vcpu.handle, @intCast(i), &q), "get simd");
        state.simd[i][0] = std.mem.readInt(u64, q.bytes[0..8], .little);
        state.simd[i][1] = std.mem.readInt(u64, q.bytes[8..16], .little);
    }

    const regs = try allocator.alloc(spore.SysRegEntry, saved_sys_regs.len);
    for (saved_sys_regs, 0..) |reg, i| {
        var value: u64 = undefined;
        try hvf.check(hvf.hv_vcpu_get_sys_reg(vcpu.handle, reg, &value), "get sysreg");
        regs[i] = .{ .name = @tagName(reg), .value = value };
    }
    state.sys_regs = regs;

    // Virtual timer: normalize to the guest's virtual counter value.
    var voff: u64 = 0;
    try hvf.check(hvf.hv_vcpu_get_vtimer_offset(vcpu.handle, &voff), "get vtimer offset");
    var cntv_ctl: u64 = 0;
    var cntv_cval: u64 = 0;
    try hvf.check(hvf.hv_vcpu_get_sys_reg(vcpu.handle, .cntv_ctl_el0, &cntv_ctl), "get cntv_ctl");
    try hvf.check(hvf.hv_vcpu_get_sys_reg(vcpu.handle, .cntv_cval_el0, &cntv_cval), "get cntv_cval");
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
        try hvf.check(hvf.hv_gic_get_icc_reg(vcpu.handle, reg, &value), "get icc reg");
        icc[i] = .{ .name = @tagName(reg), .value = value };
    }
    state.icc_regs = icc;

    return state;
}

pub fn applyMachine(allocator: std.mem.Allocator, vcpu: hvf.VcpuHandle, state: spore.MachineState) !void {
    // GIC state first: must be applied before the vCPU runs.
    try applyGicState(allocator, vcpu, state.gic);
    try applyVcpuState(vcpu, .{
        .index = 0,
        .mpidr = topology.mpidrForIndex(0),
        .gprs = state.gprs,
        .pc = state.pc,
        .cpsr = state.cpsr,
        .fpcr = state.fpcr,
        .fpsr = state.fpsr,
        .simd = state.simd,
        .sys_regs = state.sys_regs,
        .icc_regs = state.icc_regs,
        .vtimer = state.vtimer,
    });
}

pub fn applyVcpuState(vcpu: hvf.VcpuHandle, state: spore.VcpuState) !void {
    if (state.mpidr != topology.mpidrForIndex(state.index)) return error.PlatformMismatch;

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

fn captureGicState(allocator: std.mem.Allocator) !gicv3.State {
    return .{
        .kind = .backend_private,
        .backend_private = .{
            .backend = .hvf,
            .format = gicv3.hvf_backend_private_format,
            .data_b64 = try captureGic(allocator),
        },
    };
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

pub fn applyGicState(allocator: std.mem.Allocator, vcpu: hvf.VcpuHandle, state: gicv3.State) !void {
    try gicv3.validate(state);
    if (state.kind == .gicv3) {
        return applyPortableGic(vcpu, state.gicv3.?);
    }

    const private = state.backend_private orelse return error.PlatformMismatch;
    if (private.backend != .hvf or !std.mem.eql(u8, private.format, gicv3.hvf_backend_private_format)) {
        return error.PlatformMismatch;
    }

    const dec = std.base64.standard.Decoder;
    const size = dec.calcSizeForSlice(private.data_b64) catch return error.PlatformMismatch;
    const raw = try allocator.alloc(u8, size);
    defer allocator.free(raw);
    dec.decode(raw, private.data_b64) catch return error.PlatformMismatch;
    try hvf.check(hvf.hv_gic_set_state(raw.ptr, raw.len), "hv_gic_set_state");
}

fn applyPortableGic(vcpu: hvf.VcpuHandle, state: gicv3.GicV3State) !void {
    for (state.dist_regs) |reg| try writePortableReg(.distributor, vcpu, reg);
    for (state.redist_regs) |reg| try writePortableReg(.redistributor, vcpu, reg);
    for (state.line_levels) |line| {
        if (line.intid < board.spi_base_intid) {
            if (line.asserted) {
                std.log.err("HVF cannot restore asserted PPI line level for INTID {d}", .{line.intid});
                return error.PlatformMismatch;
            }
            continue;
        }
        try hvf.check(hvf.hv_gic_set_spi(line.intid, line.asserted), "hv_gic_set_spi restore line");
    }
}

fn writePortableReg(region: hvf.gic.Region, vcpu: hvf.VcpuHandle, reg: gicv3.MmioReg) !void {
    hvf.gic.writeRegStrict(region, vcpu, reg) catch {
        if (canSkipUnsupportedPortableReg(region, reg)) return;
        std.log.err("HVF does not support portable GICv3 {s} write offset=0x{x} width={d}", .{ @tagName(region), reg.offset, reg.width_bits });
        return error.PlatformMismatch;
    };
}

fn canSkipUnsupportedPortableReg(region: hvf.gic.Region, reg: gicv3.MmioReg) bool {
    return switch (region) {
        // Hypervisor.framework does not expose group-modifier registers, but
        // SporeVM's current single-vCPU board keeps them at reset value.
        .distributor => reg.offset == 0xd04 and reg.value == 0, // GICD_IGRPMODR1
        .redistributor => switch (reg.offset) {
            // GICR_CTLR: this board has no ITS/LPIs. KVM may report
            // implementation status bits, but EnableLPIs must remain clear.
            0x0000 => reg.value & 0x1 == 0,
            0x0014, // GICR_WAKER; HVF's guest-MMIO path treats this as RAZ/WI.
            0x10d00, // GICR_IGRPMODR0
            => reg.value == 0,
            else => false,
        },
    };
}
