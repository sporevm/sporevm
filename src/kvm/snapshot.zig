//! KVM machine-state capture and restore.
//!
//! Converts live KVM state into SporeVM's normalized manifest shape. KVM's
//! userspace VGICv3 ioctls are mapped to the portable architectural GICv3
//! distributor/redistributor offsets stored in the manifest.

const std = @import("std");
const kvm = @import("kvm.zig");
const board = @import("../board.zig");
const gicv3 = @import("../gicv3.zig");
const spore = @import("../spore.zig");

const mpidr_affinity_vcpu0: u64 = 0;

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

pub fn captureMachine(allocator: std.mem.Allocator, gic_fd: std.c.fd_t, vcpu_fd: std.c.fd_t) !spore.MachineState {
    var state: spore.MachineState = undefined;

    for (0..31) |i| {
        state.gprs[i] = try kvm.getOneRegU64(vcpu_fd, kvm.gprReg(@intCast(i)));
    }
    state.pc = try kvm.getOneRegU64(vcpu_fd, kvm.coreReg(kvm.KVM_REG_ARM_CORE_PC));
    state.cpsr = try kvm.getOneRegU64(vcpu_fd, kvm.coreReg(kvm.KVM_REG_ARM_CORE_PSTATE));
    state.fpcr = try kvm.getOneRegU32(vcpu_fd, kvm.coreRegSized(kvm.KVM_REG_ARM_CORE_FPCR, kvm.KVM_REG_SIZE_U32));
    state.fpsr = try kvm.getOneRegU32(vcpu_fd, kvm.coreRegSized(kvm.KVM_REG_ARM_CORE_FPSR, kvm.KVM_REG_SIZE_U32));

    for (0..32) |i| {
        var q: [16]u8 = @splat(0);
        try kvm.getOneReg(vcpu_fd, kvm.coreRegSized(kvm.KVM_REG_ARM_CORE_FP_VREG0 + @as(u64, @intCast(i)) * 4, kvm.KVM_REG_SIZE_U128), &q);
        state.simd[i][0] = std.mem.readInt(u64, q[0..8], .little);
        state.simd[i][1] = std.mem.readInt(u64, q[8..16], .little);
    }

    const regs = try allocator.alloc(spore.SysRegEntry, saved_sys_regs.len);
    for (saved_sys_regs, 0..) |reg, i| {
        regs[i] = .{ .name = reg.name, .value = try kvm.getOneRegU64(vcpu_fd, reg.id) };
    }
    state.sys_regs = regs;

    state.vtimer = .{
        .cntvct = try kvm.getOneRegU64(vcpu_fd, kvm.KVM_REG_ARM_TIMER_CNT),
        .cntv_ctl = try kvm.getOneRegU64(vcpu_fd, kvm.KVM_REG_ARM_TIMER_CTL),
        .cntv_cval = try kvm.getOneRegU64(vcpu_fd, kvm.KVM_REG_ARM_TIMER_CVAL),
    };

    var icc_list: std.ArrayList(spore.SysRegEntry) = .empty;
    defer icc_list.deinit(allocator);
    for (saved_icc_regs) |reg| {
        const attr = cpuSysregAttr(reg.instr);
        if (try kvm.getDeviceAttrMaybeU64(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_CPU_SYSREGS, attr, "get vgic icc reg")) |value| {
            try icc_list.append(allocator, .{ .name = reg.name, .value = value });
        }
    }
    state.icc_regs = try icc_list.toOwnedSlice(allocator);
    state.gic = .{ .kind = .gicv3, .gicv3 = try captureGic(allocator, gic_fd) };
    return state;
}

pub fn applyMachine(allocator: std.mem.Allocator, vm_fd: std.c.fd_t, gic_fd: std.c.fd_t, vcpu_fd: std.c.fd_t, state: spore.MachineState) !void {
    _ = allocator;
    try applyGic(gic_fd, state.gic);

    for (0..31) |i| {
        try kvm.setOneRegU64(vcpu_fd, kvm.gprReg(@intCast(i)), state.gprs[i]);
    }
    try kvm.setOneRegU64(vcpu_fd, kvm.coreReg(kvm.KVM_REG_ARM_CORE_PC), state.pc);
    try kvm.setOneRegU64(vcpu_fd, kvm.coreReg(kvm.KVM_REG_ARM_CORE_PSTATE), state.cpsr);
    try kvm.setOneRegU32(vcpu_fd, kvm.coreRegSized(kvm.KVM_REG_ARM_CORE_FPCR, kvm.KVM_REG_SIZE_U32), @truncate(state.fpcr));
    try kvm.setOneRegU32(vcpu_fd, kvm.coreRegSized(kvm.KVM_REG_ARM_CORE_FPSR, kvm.KVM_REG_SIZE_U32), @truncate(state.fpsr));

    for (0..32) |i| {
        var q: [16]u8 = @splat(0);
        std.mem.writeInt(u64, q[0..8], state.simd[i][0], .little);
        std.mem.writeInt(u64, q[8..16], state.simd[i][1], .little);
        try kvm.setOneReg(vcpu_fd, kvm.coreRegSized(kvm.KVM_REG_ARM_CORE_FP_VREG0 + @as(u64, @intCast(i)) * 4, kvm.KVM_REG_SIZE_U128), &q);
    }

    for (state.sys_regs) |entry| {
        const saved = findSavedReg(entry.name) orelse {
            std.log.err("unknown KVM sysreg in spore: {s}", .{entry.name});
            return error.PlatformMismatch;
        };
        if (saved.skip_set) continue;
        try kvm.setOneRegU64(vcpu_fd, saved.id, entry.value);
    }

    for (state.icc_regs) |entry| {
        const reg = findIccReg(entry.name) orelse {
            std.log.err("unknown KVM ICC reg in spore: {s}", .{entry.name});
            return error.PlatformMismatch;
        };
        try kvm.setDeviceAttrU64(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_CPU_SYSREGS, cpuSysregAttr(reg.instr), entry.value, "set vgic icc reg");
    }

    // Re-anchor guest virtual time to the saved CNTVCT value.
    try kvm.setCounterOffset(vm_fd, hostCounter() -% state.vtimer.cntvct);
    try kvm.setOneRegU64(vcpu_fd, kvm.KVM_REG_ARM_TIMER_CVAL, state.vtimer.cntv_cval);
    try kvm.setOneRegU64(vcpu_fd, kvm.KVM_REG_ARM_TIMER_CTL, state.vtimer.cntv_ctl);
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

fn captureGic(allocator: std.mem.Allocator, gic_fd: std.c.fd_t) !gicv3.GicV3State {
    var dist_regs: std.ArrayList(gicv3.MmioReg) = .empty;
    defer dist_regs.deinit(allocator);
    var redist_regs: std.ArrayList(gicv3.MmioReg) = .empty;
    defer redist_regs.deinit(allocator);
    var line_levels: std.ArrayList(gicv3.LineLevel) = .empty;
    defer line_levels.deinit(allocator);

    try appendDistRegs(allocator, &dist_regs, gic_fd);
    try appendRedistRegs(allocator, &redist_regs, gic_fd);
    try appendLevelRegs(allocator, &line_levels, gic_fd);

    const state = gicv3.GicV3State{
        .dist_regs = try dist_regs.toOwnedSlice(allocator),
        .redist_regs = try redist_regs.toOwnedSlice(allocator),
        .line_levels = try line_levels.toOwnedSlice(allocator),
    };
    try gicv3.validateGicV3(state);
    return state;
}

fn applyGic(gic_fd: std.c.fd_t, state: gicv3.State) !void {
    try gicv3.validate(state);
    const g = state.gicv3 orelse return error.PlatformMismatch;

    for (g.dist_regs) |reg| try setDistReg(gic_fd, reg);
    for (g.redist_regs) |reg| try setRedistReg(gic_fd, reg);
    for (g.line_levels) |line| try kvm.setDeviceAttrU32(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_LEVEL_INFO, levelAttr(line.intid), @intFromBool(line.asserted), "set vgic line level");
}

fn appendDistRegs(allocator: std.mem.Allocator, regs: *std.ArrayList(gicv3.MmioReg), gic_fd: std.c.fd_t) !void {
    const one_word_offsets = [_]u32{
        0x000, // GICD_CTLR
        0x084, // GICD_IGROUPR1
        0x104, // GICD_ISENABLER1
        0x204, // GICD_ISPENDR1
        0x304, // GICD_ISACTIVER1
        0xd04, // GICD_IGRPMODR1
    };
    for (one_word_offsets) |offset| try appendDistReg32(allocator, regs, gic_fd, offset);

    var off: u32 = 0x420; // GICD_IPRIORITYR for INTIDs 32..63.
    while (off < 0x440) : (off += 4) try appendDistReg32(allocator, regs, gic_fd, off);

    off = 0xc08; // GICD_ICFGR for INTIDs 32..63.
    while (off < 0xc10) : (off += 4) try appendDistReg32(allocator, regs, gic_fd, off);

    var intid: u32 = 32;
    while (intid <= board.generationIntid()) : (intid += 1) {
        try appendDistReg64(allocator, regs, gic_fd, gicv3.distRouterOffset(intid));
    }
}

fn appendRedistRegs(allocator: std.mem.Allocator, regs: *std.ArrayList(gicv3.MmioReg), gic_fd: std.c.fd_t) !void {
    const one_word_offsets = [_]u32{
        0x0000, // GICR_CTLR
        0x0014, // GICR_WAKER
        0x10080, // GICR_IGROUPR0
        0x10100, // GICR_ISENABLER0
        0x10200, // GICR_ISPENDR0
        0x10300, // GICR_ISACTIVER0
        0x10d00, // GICR_IGRPMODR0
    };
    for (one_word_offsets) |offset| try appendRedistReg32(allocator, regs, gic_fd, offset);

    var off: u32 = 0x10400; // GICR_IPRIORITYR for SGIs/PPIs.
    while (off < 0x10420) : (off += 4) try appendRedistReg32(allocator, regs, gic_fd, off);

    off = 0x10c00; // GICR_ICFGR for SGIs/PPIs.
    while (off < 0x10c08) : (off += 4) try appendRedistReg32(allocator, regs, gic_fd, off);
}

fn appendLevelRegs(allocator: std.mem.Allocator, levels: *std.ArrayList(gicv3.LineLevel), gic_fd: std.c.fd_t) !void {
    // KVM exposes line-level state for PPIs and SPIs, not SGIs.
    var intid: u32 = 16;
    while (intid <= board.generationIntid()) : (intid += 1) {
        if (try kvm.getDeviceAttrMaybeU32(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_LEVEL_INFO, levelAttr(intid), "get vgic line level")) |value| {
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

fn appendRedistReg32(allocator: std.mem.Allocator, regs: *std.ArrayList(gicv3.MmioReg), gic_fd: std.c.fd_t, offset: u32) !void {
    if (try kvm.getDeviceAttrMaybeU32(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_REDIST_REGS, redistAttr(offset), "get vgic redist reg")) |value| {
        try regs.append(allocator, .{ .offset = offset, .width_bits = 32, .value = value });
    }
}

fn setDistReg(gic_fd: std.c.fd_t, reg: gicv3.MmioReg) !void {
    switch (reg.width_bits) {
        32 => try kvm.setDeviceAttrU32(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_DIST_REGS, distAttr(reg.offset), @truncate(reg.value), "set vgic dist reg"),
        64 => try kvm.setDeviceAttrU64(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_DIST_REGS, distAttr(reg.offset), reg.value, "set vgic dist reg"),
        else => return error.PlatformMismatch,
    }
}

fn setRedistReg(gic_fd: std.c.fd_t, reg: gicv3.MmioReg) !void {
    switch (reg.width_bits) {
        32 => try kvm.setDeviceAttrU32(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_REDIST_REGS, redistAttr(reg.offset), @truncate(reg.value), "set vgic redist reg"),
        64 => try kvm.setDeviceAttrU64(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_REDIST_REGS, redistAttr(reg.offset), reg.value, "set vgic redist reg"),
        else => return error.PlatformMismatch,
    }
}

fn distAttr(offset: u32) u64 {
    return offset & 0xffff_ffff;
}

fn redistAttr(offset: u32) u64 {
    return (mpidr_affinity_vcpu0 << 32) | (offset & 0xffff_ffff);
}

fn cpuSysregAttr(instr: u64) u64 {
    return (mpidr_affinity_vcpu0 << 32) | (instr & 0xffff);
}

fn levelAttr(intid: u32) u64 {
    return (mpidr_affinity_vcpu0 << 32) |
        (kvm.VGIC_LEVEL_INFO_LINE_LEVEL << kvm.KVM_DEV_ARM_VGIC_LINE_LEVEL_INFO_SHIFT) |
        intid;
}

test "VGIC attr encodings for vCPU0" {
    try std.testing.expectEqual(@as(u64, 0x84), distAttr(0x84));
    try std.testing.expectEqual(@as(u64, 0x6100), distAttr(gicv3.distRouterOffset(32)));
    try std.testing.expectEqual(@as(u64, 0x61c0), distAttr(gicv3.distRouterOffset(56)));
    try std.testing.expectEqual(@as(u64, 0x10080), redistAttr(0x10080));
    try std.testing.expectEqual(@as(u64, 0xc230), cpuSysregAttr(kvm.sysRegInstr(3, 0, 4, 6, 0)));
}
