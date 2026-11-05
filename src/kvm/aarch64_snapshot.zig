//! AArch64 KVM machine-state capture and restore.
//!
//! Converts live KVM state into SporeVM's normalized manifest shape. KVM's
//! userspace VGICv3 ioctls are mapped to the portable architectural GICv3
//! distributor/redistributor offsets stored in the manifest.

const std = @import("std");
const kvm = @import("aarch64.zig");
const board = @import("../aarch64/board.zig");
const gicv3 = @import("../aarch64/gicv3.zig");
const aarch64_topology = @import("../aarch64/topology.zig");
const spore = @import("../spore.zig");
const topology = @import("../topology.zig");

pub const VcpuRef = struct {
    index: topology.VcpuIndex,
    fd: std.c.fd_t,
};

const SavedReg = struct {
    name: []const u8,
    id: u64,
    skip_set: bool = false,
};

const saved_sys_regs = [_]SavedReg{
    .{ .name = "sctlr_el1", .id = kvm.sysReg(3, 0, 1, 0, 0) },
    .{ .name = "cpacr_el1", .id = kvm.sysReg(3, 0, 1, 0, 2) },
    .{ .name = "ttbr0_el1", .id = kvm.sysReg(3, 0, 2, 0, 0) },
    .{ .name = "ttbr1_el1", .id = kvm.sysReg(3, 0, 2, 0, 1) },
    .{ .name = "tcr_el1", .id = kvm.sysReg(3, 0, 2, 0, 2) },
    .{ .name = "spsr_el1", .id = kvm.coreReg(kvm.KVM_REG_ARM_CORE_SPSR_EL1) },
    .{ .name = "elr_el1", .id = kvm.coreReg(kvm.KVM_REG_ARM_CORE_ELR_EL1) },
    .{ .name = "sp_el0", .id = kvm.coreReg(kvm.KVM_REG_ARM_CORE_SP) },
    .{ .name = "sp_el1", .id = kvm.coreReg(kvm.KVM_REG_ARM_CORE_SP_EL1) },
    .{ .name = "afsr0_el1", .id = kvm.sysReg(3, 0, 5, 1, 0) },
    .{ .name = "afsr1_el1", .id = kvm.sysReg(3, 0, 5, 1, 1) },
    .{ .name = "esr_el1", .id = kvm.sysReg(3, 0, 5, 2, 0) },
    .{ .name = "far_el1", .id = kvm.sysReg(3, 0, 6, 0, 0) },
    .{ .name = "par_el1", .id = kvm.sysReg(3, 0, 7, 4, 0) },
    .{ .name = "mair_el1", .id = kvm.sysReg(3, 0, 10, 2, 0) },
    .{ .name = "amair_el1", .id = kvm.sysReg(3, 0, 10, 3, 0) },
    .{ .name = "vbar_el1", .id = kvm.sysReg(3, 0, 12, 0, 0) },
    .{ .name = "contextidr_el1", .id = kvm.sysReg(3, 0, 13, 0, 1) },
    .{ .name = "tpidr_el1", .id = kvm.sysReg(3, 0, 13, 0, 4) },
    .{ .name = "cntkctl_el1", .id = kvm.sysReg(3, 0, 14, 1, 0) },
    .{ .name = "csselr_el1", .id = kvm.sysReg(3, 2, 0, 0, 0) },
    .{ .name = "tpidr_el0", .id = kvm.sysReg(3, 3, 13, 0, 2) },
    .{ .name = "tpidrro_el0", .id = kvm.sysReg(3, 3, 13, 0, 3) },
    .{ .name = "mpidr_el1", .id = kvm.sysReg(3, 0, 0, 0, 5), .skip_set = true },
};

const IccReg = struct {
    name: []const u8,
    instr: u64,
};

const saved_icc_regs = [_]IccReg{
    .{ .name = "pmr_el1", .instr = kvm.sysRegInstr(3, 0, 4, 6, 0) },
    .{ .name = "bpr0_el1", .instr = kvm.sysRegInstr(3, 0, 12, 8, 3) },
    .{ .name = "ap0r0_el1", .instr = kvm.sysRegInstr(3, 0, 12, 8, 4) },
    .{ .name = "ap1r0_el1", .instr = kvm.sysRegInstr(3, 0, 12, 9, 0) },
    .{ .name = "bpr1_el1", .instr = kvm.sysRegInstr(3, 0, 12, 12, 3) },
    .{ .name = "ctlr_el1", .instr = kvm.sysRegInstr(3, 0, 12, 12, 4) },
    .{ .name = "sre_el1", .instr = kvm.sysRegInstr(3, 0, 12, 12, 5) },
    .{ .name = "igrpen0_el1", .instr = kvm.sysRegInstr(3, 0, 12, 12, 6) },
    .{ .name = "igrpen1_el1", .instr = kvm.sysRegInstr(3, 0, 12, 12, 7) },
};

pub fn hostCounter() u64 {
    return asm volatile ("mrs %[ret], cntvct_el0"
        : [ret] "=r" (-> u64),
    );
}

pub fn hostCounterFreq() u64 {
    return asm volatile ("mrs %[ret], cntfrq_el0"
        : [ret] "=r" (-> u64),
    );
}

pub fn captureVcpuState(allocator: std.mem.Allocator, gic_fd: std.c.fd_t, vcpu: VcpuRef) !spore.VcpuState {
    var state: spore.VcpuState = undefined;
    state.index = vcpu.index;
    state.mpidr = aarch64_topology.mpidrForIndex(vcpu.index);

    for (0..31) |i| {
        state.gprs[i] = try kvm.getOneRegU64(vcpu.fd, kvm.gprReg(@intCast(i)));
    }
    state.pc = try kvm.getOneRegU64(vcpu.fd, kvm.coreReg(kvm.KVM_REG_ARM_CORE_PC));
    state.cpsr = try kvm.getOneRegU64(vcpu.fd, kvm.coreReg(kvm.KVM_REG_ARM_CORE_PSTATE));
    state.fpcr = try kvm.getOneRegU32(vcpu.fd, kvm.coreRegSized(kvm.KVM_REG_ARM_CORE_FPCR, kvm.KVM_REG_SIZE_U32));
    state.fpsr = try kvm.getOneRegU32(vcpu.fd, kvm.coreRegSized(kvm.KVM_REG_ARM_CORE_FPSR, kvm.KVM_REG_SIZE_U32));

    for (0..32) |i| {
        var q: [16]u8 = @splat(0);
        try kvm.getOneReg(vcpu.fd, kvm.coreRegSized(kvm.KVM_REG_ARM_CORE_FP_VREG0 + @as(u64, @intCast(i)) * 4, kvm.KVM_REG_SIZE_U128), &q);
        state.simd[i][0] = std.mem.readInt(u64, q[0..8], .little);
        state.simd[i][1] = std.mem.readInt(u64, q[8..16], .little);
    }

    const regs = try allocator.alloc(spore.SysRegEntry, saved_sys_regs.len);
    for (saved_sys_regs, 0..) |reg, i| {
        regs[i] = .{ .name = reg.name, .value = try kvm.getOneRegU64(vcpu.fd, reg.id) };
    }
    state.sys_regs = regs;

    state.vtimer = .{
        .cntvct = try kvm.getOneRegU64(vcpu.fd, kvm.KVM_REG_ARM_TIMER_CNT),
        .cntv_ctl = try kvm.getOneRegU64(vcpu.fd, kvm.KVM_REG_ARM_TIMER_CTL),
        .cntv_cval = try kvm.getOneRegU64(vcpu.fd, kvm.KVM_REG_ARM_TIMER_CVAL),
    };

    var icc_list: std.ArrayList(spore.SysRegEntry) = .empty;
    defer icc_list.deinit(allocator);
    for (saved_icc_regs) |reg| {
        const attr = cpuSysregAttr(vcpu.index, reg.instr);
        if (try kvm.getDeviceAttrMaybeU64(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_CPU_SYSREGS, attr, "get vgic icc reg")) |value| {
            try icc_list.append(allocator, .{ .name = reg.name, .value = value });
        }
    }
    state.icc_regs = try icc_list.toOwnedSlice(allocator);
    return state;
}

fn hasRedistributor(redistributors: []const gicv3.RedistributorState, mpidr: aarch64_topology.Mpidr) bool {
    for (redistributors) |redist| {
        if (redist.mpidr == mpidr) return true;
    }
    return false;
}

pub fn applyVcpuState(gic_fd: std.c.fd_t, vcpu: VcpuRef, state: spore.VcpuState) !void {
    for (0..31) |i| {
        try kvm.setOneRegU64(vcpu.fd, kvm.gprReg(@intCast(i)), state.gprs[i]);
    }
    try kvm.setOneRegU64(vcpu.fd, kvm.coreReg(kvm.KVM_REG_ARM_CORE_PC), state.pc);
    try kvm.setOneRegU64(vcpu.fd, kvm.coreReg(kvm.KVM_REG_ARM_CORE_PSTATE), state.cpsr);
    try kvm.setOneRegU32(vcpu.fd, kvm.coreRegSized(kvm.KVM_REG_ARM_CORE_FPCR, kvm.KVM_REG_SIZE_U32), @truncate(state.fpcr));
    try kvm.setOneRegU32(vcpu.fd, kvm.coreRegSized(kvm.KVM_REG_ARM_CORE_FPSR, kvm.KVM_REG_SIZE_U32), @truncate(state.fpsr));

    for (0..32) |i| {
        var q: [16]u8 = @splat(0);
        std.mem.writeInt(u64, q[0..8], state.simd[i][0], .little);
        std.mem.writeInt(u64, q[8..16], state.simd[i][1], .little);
        try kvm.setOneReg(vcpu.fd, kvm.coreRegSized(kvm.KVM_REG_ARM_CORE_FP_VREG0 + @as(u64, @intCast(i)) * 4, kvm.KVM_REG_SIZE_U128), &q);
    }

    for (state.sys_regs) |entry| {
        const saved = findSavedReg(entry.name) orelse {
            std.log.err("unknown KVM sysreg in spore: {s}", .{entry.name});
            return error.PlatformMismatch;
        };
        if (saved.skip_set) continue;
        try kvm.setOneRegU64(vcpu.fd, saved.id, entry.value);
    }

    for (state.icc_regs) |entry| {
        const reg = findIccReg(entry.name) orelse {
            std.log.err("unknown KVM ICC reg in spore: {s}", .{entry.name});
            return error.PlatformMismatch;
        };
        try kvm.setDeviceAttrU64(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_CPU_SYSREGS, cpuSysregAttr(vcpu.index, reg.instr), entry.value, "set vgic icc reg");
    }

    try kvm.setOneRegU64(vcpu.fd, kvm.KVM_REG_ARM_TIMER_CVAL, state.vtimer.cntv_cval);
    try kvm.setOneRegU64(vcpu.fd, kvm.KVM_REG_ARM_TIMER_CTL, state.vtimer.cntv_ctl);
}

fn findSavedReg(name: []const u8) ?SavedReg {
    for (saved_sys_regs) |reg| {
        if (std.mem.eql(u8, name, reg.name)) return reg;
    }
    return null;
}

fn findIccReg(name: []const u8) ?IccReg {
    for (saved_icc_regs) |reg| {
        if (std.mem.eql(u8, name, reg.name)) return reg;
    }
    return null;
}

/// Captures the vGIC in the shape the manifest stores for `vcpu_count` vCPUs.
pub fn captureGicState(allocator: std.mem.Allocator, gic_fd: std.c.fd_t, vcpu_count: usize) !gicv3.State {
    if (vcpu_count == 1) return .{ .kind = .gicv3, .gicv3 = try captureGic(allocator, gic_fd) };
    return .{ .kind = .gicv3_multi, .gicv3_multi = try captureGicMulti(allocator, gic_fd, vcpu_count) };
}

/// Restores the vGIC. A multi-vCPU state needs a redistributor for each vCPU.
pub fn applyGicState(vm_fd: std.c.fd_t, gic_fd: std.c.fd_t, vcpu_count: usize, state: gicv3.State) !void {
    if (vcpu_count == 1) return applyGic(vm_fd, gic_fd, state);
    try validateGicForVcpus(vcpu_count, state);
    try applyGicMulti(vm_fd, gic_fd, state);
}

fn validateGicForVcpus(vcpu_count: usize, state: gicv3.State) !void {
    try gicv3.validate(state);
    const g = state.gicv3_multi orelse return error.PlatformMismatch;
    if (g.redistributors.len != vcpu_count) return error.PlatformMismatch;
    for (0..vcpu_count) |index| {
        if (!hasRedistributor(g.redistributors, aarch64_topology.mpidrForIndex(@intCast(index)))) return error.PlatformMismatch;
    }
}

fn captureGic(allocator: std.mem.Allocator, gic_fd: std.c.fd_t) !gicv3.GicV3State {
    var dist_regs: std.ArrayList(gicv3.MmioReg) = .empty;
    defer dist_regs.deinit(allocator);
    var redist_regs: std.ArrayList(gicv3.MmioReg) = .empty;
    defer redist_regs.deinit(allocator);
    var line_levels: std.ArrayList(gicv3.LineLevel) = .empty;
    defer line_levels.deinit(allocator);

    try appendDistRegs(allocator, &dist_regs, gic_fd);
    try appendRedistRegs(allocator, &redist_regs, gic_fd, 0);
    try appendLevelRegs(allocator, &line_levels, gic_fd);

    const state = gicv3.GicV3State{
        .dist_regs = try dist_regs.toOwnedSlice(allocator),
        .redist_regs = try redist_regs.toOwnedSlice(allocator),
        .line_levels = try line_levels.toOwnedSlice(allocator),
    };
    try gicv3.validateGicV3(state);
    return state;
}

fn captureGicMulti(allocator: std.mem.Allocator, gic_fd: std.c.fd_t, vcpu_count: usize) !gicv3.GicV3MultiState {
    var dist_regs: std.ArrayList(gicv3.MmioReg) = .empty;
    defer dist_regs.deinit(allocator);
    var line_levels: std.ArrayList(gicv3.MultiLineLevel) = .empty;
    defer line_levels.deinit(allocator);
    const redistributors = try allocator.alloc(gicv3.RedistributorState, vcpu_count);

    try appendDistRegs(allocator, &dist_regs, gic_fd);
    for (redistributors, 0..) |*redist, index| {
        var regs: std.ArrayList(gicv3.MmioReg) = .empty;
        defer regs.deinit(allocator);
        try appendRedistRegs(allocator, &regs, gic_fd, kvmMpidrAffinityForIndex(@intCast(index)));
        redist.* = .{
            .mpidr = aarch64_topology.mpidrForIndex(@intCast(index)),
            .regs = try regs.toOwnedSlice(allocator),
        };
    }
    try appendLevelRegsMulti(allocator, &line_levels, gic_fd, vcpu_count);

    const state = gicv3.GicV3MultiState{
        .dist_regs = try dist_regs.toOwnedSlice(allocator),
        .redistributors = redistributors,
        .line_levels = try line_levels.toOwnedSlice(allocator),
    };
    try gicv3.validateGicV3Multi(state);
    return state;
}

fn applyGic(vm_fd: std.c.fd_t, gic_fd: std.c.fd_t, state: gicv3.State) !void {
    try gicv3.validate(state);
    const g = state.gicv3 orelse return error.PlatformMismatch;

    for (g.dist_regs) |reg| try setDistReg(gic_fd, reg);
    for (g.redist_regs) |reg| try setRedistReg(gic_fd, 0, reg);
    for (g.line_levels) |line| {
        if (shouldReplayLineLevel(line)) try kvm.setIrq(vm_fd, line.intid, true);
    }
}

fn applyGicMulti(vm_fd: std.c.fd_t, gic_fd: std.c.fd_t, state: gicv3.State) !void {
    try gicv3.validate(state);
    const g = state.gicv3_multi orelse return error.PlatformMismatch;

    for (g.dist_regs) |reg| try setDistReg(gic_fd, reg);
    for (g.redistributors) |redist| {
        const affinity = kvmMpidrAffinityForManifest(redist.mpidr);
        for (redist.regs) |reg| try setRedistReg(gic_fd, affinity, reg);
    }
    for (g.line_levels) |line| {
        if (shouldReplayMultiLineLevel(line)) try kvm.setIrq(vm_fd, line.intid, true);
    }
}

fn shouldReplayLineLevel(line: gicv3.LineLevel) bool {
    // Fresh VGIC state starts with external lines deasserted, so false levels
    // do not need replay. PPIs are private to a vCPU and are restored through
    // vCPU/timer state for the current single-vCPU contract. The generation
    // SPI is raised from generation.Device state after machine restore so the
    // MMIO device and GIC line stay in sync.
    return line.asserted and line.intid >= 32 and line.intid != board.generationIntid();
}

fn shouldReplayMultiLineLevel(line: gicv3.MultiLineLevel) bool {
    return line.asserted and line.intid >= 32 and line.intid != board.generationIntid();
}

fn appendDistRegs(allocator: std.mem.Allocator, regs: *std.ArrayList(gicv3.MmioReg), gic_fd: std.c.fd_t) !void {
    var specs: std.ArrayList(gicv3.RegSpec) = .empty;
    defer specs.deinit(allocator);
    try gicv3.appendDistRegSpecs(allocator, &specs);

    for (specs.items) |spec| {
        switch (spec.width_bits) {
            32 => try appendDistReg32(allocator, regs, gic_fd, spec.offset),
            64 => try appendDistReg64(allocator, regs, gic_fd, spec.offset),
            else => unreachable,
        }
    }
}

fn appendRedistRegs(allocator: std.mem.Allocator, regs: *std.ArrayList(gicv3.MmioReg), gic_fd: std.c.fd_t, affinity: u64) !void {
    var specs: std.ArrayList(gicv3.RegSpec) = .empty;
    defer specs.deinit(allocator);
    try gicv3.appendRedistRegSpecs(allocator, &specs);

    for (specs.items) |spec| {
        switch (spec.width_bits) {
            32 => try appendRedistReg32(allocator, regs, gic_fd, affinity, spec.offset),
            64 => try appendRedistReg64(allocator, regs, gic_fd, affinity, spec.offset),
            else => unreachable,
        }
    }
}

fn appendLevelRegs(allocator: std.mem.Allocator, levels: *std.ArrayList(gicv3.LineLevel), gic_fd: std.c.fd_t) !void {
    // KVM exposes line-level state for PPIs and SPIs, not SGIs.
    var intid: u32 = 16;
    while (intid <= board.generationIntid()) : (intid += 1) {
        if (try kvm.getDeviceAttrMaybeU32(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_LEVEL_INFO, levelAttr(0, intid), "get vgic line level")) |value| {
            try levels.append(allocator, .{ .intid = intid, .asserted = value != 0 });
        }
    }
}

fn appendLevelRegsMulti(allocator: std.mem.Allocator, levels: *std.ArrayList(gicv3.MultiLineLevel), gic_fd: std.c.fd_t, vcpu_count: usize) !void {
    // KVM exposes line-level state for PPIs and SPIs, not SGIs.
    var intid: u32 = 16;
    while (intid <= board.generationIntid()) : (intid += 1) {
        if (intid < 32) {
            for (0..vcpu_count) |i| {
                const index: topology.VcpuIndex = @intCast(i);
                if (try kvm.getDeviceAttrMaybeU32(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_LEVEL_INFO, levelAttr(kvmMpidrAffinityForIndex(index), intid), "get vgic ppi line level")) |value| {
                    try levels.append(allocator, .{ .intid = intid, .asserted = value != 0, .mpidr = aarch64_topology.mpidrForIndex(index) });
                }
            }
        } else if (try kvm.getDeviceAttrMaybeU32(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_LEVEL_INFO, levelAttr(0, intid), "get vgic spi line level")) |value| {
            try levels.append(allocator, .{ .intid = intid, .asserted = value != 0 });
        }
    }
}

fn appendDistReg32(allocator: std.mem.Allocator, regs: *std.ArrayList(gicv3.MmioReg), gic_fd: std.c.fd_t, offset: u32) !void {
    if (try kvm.getDeviceAttrMaybeU32(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_DIST_REGS, distAttr(offset), "get vgic dist reg")) |value| {
        try regs.append(allocator, .{ .offset = offset, .width_bits = 32, .value = value });
    }
}

fn appendDistReg64(allocator: std.mem.Allocator, regs: *std.ArrayList(gicv3.MmioReg), gic_fd: std.c.fd_t, offset: u32) !void {
    if (try kvm.getDeviceAttrMaybeU64(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_DIST_REGS, distAttr(offset), "get vgic dist reg")) |value| {
        try regs.append(allocator, .{ .offset = offset, .width_bits = 64, .value = value });
    }
}

fn appendRedistReg32(allocator: std.mem.Allocator, regs: *std.ArrayList(gicv3.MmioReg), gic_fd: std.c.fd_t, affinity: u64, offset: u32) !void {
    if (try kvm.getDeviceAttrMaybeU32(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_REDIST_REGS, redistAttr(affinity, offset), "get vgic redist reg")) |value| {
        try regs.append(allocator, .{ .offset = offset, .width_bits = 32, .value = value });
    }
}

fn appendRedistReg64(allocator: std.mem.Allocator, regs: *std.ArrayList(gicv3.MmioReg), gic_fd: std.c.fd_t, affinity: u64, offset: u32) !void {
    if (try kvm.getDeviceAttrMaybeU64(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_REDIST_REGS, redistAttr(affinity, offset), "get vgic redist reg")) |value| {
        try regs.append(allocator, .{ .offset = offset, .width_bits = 64, .value = value });
    }
}

fn setDistReg(gic_fd: std.c.fd_t, reg: gicv3.MmioReg) !void {
    switch (reg.width_bits) {
        32 => try kvm.setDeviceAttrU32(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_DIST_REGS, distAttr(reg.offset), @truncate(reg.value), "set vgic dist reg"),
        64 => try kvm.setDeviceAttrU64(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_DIST_REGS, distAttr(reg.offset), reg.value, "set vgic dist reg"),
        else => return error.PlatformMismatch,
    }
}

fn setRedistReg(gic_fd: std.c.fd_t, affinity: u64, reg: gicv3.MmioReg) !void {
    switch (reg.width_bits) {
        32 => try kvm.setDeviceAttrU32(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_REDIST_REGS, redistAttr(affinity, reg.offset), @truncate(reg.value), "set vgic redist reg"),
        64 => try kvm.setDeviceAttrU64(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_REDIST_REGS, redistAttr(affinity, reg.offset), reg.value, "set vgic redist reg"),
        else => return error.PlatformMismatch,
    }
}

fn distAttr(offset: u32) u64 {
    return offset & 0xffff_ffff;
}

fn redistAttr(affinity: u64, offset: u32) u64 {
    return (affinity << 32) | (offset & 0xffff_ffff);
}

fn cpuSysregAttr(index: topology.VcpuIndex, instr: u64) u64 {
    return (kvmMpidrAffinityForIndex(index) << 32) | (instr & 0xffff);
}

fn levelAttr(affinity: u64, intid: u32) u64 {
    return (affinity << 32) |
        (kvm.VGIC_LEVEL_INFO_LINE_LEVEL << kvm.KVM_DEV_ARM_VGIC_LINE_LEVEL_INFO_SHIFT) |
        intid;
}

fn kvmMpidrAffinityForIndex(index: topology.VcpuIndex) u64 {
    return index;
}

fn kvmMpidrAffinityForManifest(mpidr: aarch64_topology.Mpidr) u64 {
    return mpidr & 0x00ff_ffff;
}

test "VGIC attr encodings for vCPU0" {
    try std.testing.expectEqual(@as(u64, 0x84), distAttr(0x84));
    try std.testing.expectEqual(@as(u64, 0x6100), distAttr(gicv3.distRouterOffset(32)));
    try std.testing.expectEqual(@as(u64, 0x61c0), distAttr(gicv3.distRouterOffset(56)));
    try std.testing.expectEqual(@as(u64, 0x10080), redistAttr(0, 0x10080));
    try std.testing.expectEqual(@as(u64, 0xc230), cpuSysregAttr(0, kvm.sysRegInstr(3, 0, 4, 6, 0)));
    try std.testing.expectEqual(@as(u64, 0x1_0001_0080), redistAttr(1, 0x10080));
    try std.testing.expectEqual(@as(u64, 0x1_0000_c230), cpuSysregAttr(1, kvm.sysRegInstr(3, 0, 4, 6, 0)));
}

test "KVM line replay skips default and generation lines" {
    try std.testing.expect(!shouldReplayLineLevel(.{ .intid = 16, .asserted = false }));
    try std.testing.expect(!shouldReplayLineLevel(.{ .intid = 27, .asserted = true }));
    try std.testing.expect(!shouldReplayLineLevel(.{ .intid = board.generationIntid(), .asserted = true }));
    try std.testing.expect(shouldReplayLineLevel(.{ .intid = board.virtioDeviceIntid(0), .asserted = true }));
}

test "KVM multi line replay skips private and generation lines" {
    try std.testing.expect(!shouldReplayMultiLineLevel(.{ .intid = 16, .asserted = false, .mpidr = aarch64_topology.mpidrForIndex(0) }));
    try std.testing.expect(!shouldReplayMultiLineLevel(.{ .intid = 27, .asserted = true, .mpidr = aarch64_topology.mpidrForIndex(1) }));
    try std.testing.expect(!shouldReplayMultiLineLevel(.{ .intid = board.generationIntid(), .asserted = true }));
    try std.testing.expect(shouldReplayMultiLineLevel(.{ .intid = board.virtioDeviceIntid(0), .asserted = true }));
}

test "KVM multi-vCPU GIC restore needs a redistributor for each vCPU" {
    var redists = [_]gicv3.RedistributorState{
        .{ .mpidr = aarch64_topology.mpidrForIndex(0), .regs = &.{} },
        .{ .mpidr = aarch64_topology.mpidrForIndex(1), .regs = &.{} },
    };
    const both = gicv3.State{
        .kind = .gicv3_multi,
        .gicv3_multi = .{ .dist_regs = &.{}, .redistributors = &redists, .line_levels = &.{} },
    };
    try validateGicForVcpus(2, both);
    try std.testing.expectError(error.PlatformMismatch, validateGicForVcpus(3, both));

    var duplicate = [_]gicv3.RedistributorState{ redists[0], redists[0] };
    try std.testing.expectError(error.PlatformMismatch, validateGicForVcpus(2, .{
        .kind = .gicv3_multi,
        .gicv3_multi = .{ .dist_regs = &.{}, .redistributors = &duplicate, .line_levels = &.{} },
    }));

    try std.testing.expectError(error.PlatformMismatch, validateGicForVcpus(2, .{
        .kind = .backend_private,
        .backend_private = .{
            .backend = .hvf,
            .format = gicv3.hvf_backend_private_format,
            .data_b64 = "AA==",
        },
    }));
}
