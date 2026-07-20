//! Linux KVM bindings for the AArch64 backend.
//!
//! This module deliberately mirrors only the small KVM UAPI surface SporeVM
//! needs for bring-up: VM/vCPU creation, one-reg access, userspace VGICv3,
//! guest RAM mapping, MMIO exits, and SPI injection. Constants come from the
//! Linux 6.17 UAPI headers on the aarch64 dev host and are stable KVM ABI.

const std = @import("std");
const linux = std.os.linux;
const common = @import("common.zig");

pub const vm = @import("vm.zig");

pub const Error = common.Error || error{
    ApiVersionMismatch,
    KvmCapabilityMissing,
    UnexpectedExit,
    UnhandledMmio,
};

pub const KVM_API_VERSION = common.KVM_API_VERSION;

pub const KVM_GET_API_VERSION = common.KVM_GET_API_VERSION;
pub const KVM_CREATE_VM = common.KVM_CREATE_VM;
pub const KVM_CHECK_EXTENSION = common.KVM_CHECK_EXTENSION;
pub const KVM_GET_VCPU_MMAP_SIZE = common.KVM_GET_VCPU_MMAP_SIZE;
pub const KVM_CREATE_VCPU = common.KVM_CREATE_VCPU;
pub const KVM_GET_DIRTY_LOG: u32 = 0x4010ae42;
pub const KVM_SET_USER_MEMORY_REGION = common.KVM_SET_USER_MEMORY_REGION;
pub const KVM_RUN = common.KVM_RUN;
pub const KVM_IRQ_LINE = common.KVM_IRQ_LINE;
pub const KVM_GET_ONE_REG: u32 = 0x4010aeab;
pub const KVM_SET_ONE_REG: u32 = 0x4010aeac;
pub const KVM_ARM_VCPU_INIT: u32 = 0x4020aeae;
pub const KVM_ARM_PREFERRED_TARGET: u32 = 0x8020aeaf;
pub const KVM_CREATE_DEVICE: u32 = 0xc00caee0;
pub const KVM_SET_DEVICE_ATTR = common.KVM_SET_DEVICE_ATTR;
pub const KVM_GET_DEVICE_ATTR = common.KVM_GET_DEVICE_ATTR;
pub const KVM_HAS_DEVICE_ATTR = common.KVM_HAS_DEVICE_ATTR;
pub const KVM_ARM_SET_COUNTER_OFFSET: u32 = 0x4010aeb5;

pub const KVM_EXIT_MMIO = common.KVM_EXIT_MMIO;
pub const KVM_EXIT_SHUTDOWN = common.KVM_EXIT_SHUTDOWN;
pub const KVM_EXIT_FAIL_ENTRY = common.KVM_EXIT_FAIL_ENTRY;
pub const KVM_EXIT_INTERNAL_ERROR = common.KVM_EXIT_INTERNAL_ERROR;
pub const KVM_EXIT_SYSTEM_EVENT = common.KVM_EXIT_SYSTEM_EVENT;

pub const KVM_SYSTEM_EVENT_SHUTDOWN = common.KVM_SYSTEM_EVENT_SHUTDOWN;
pub const KVM_SYSTEM_EVENT_RESET = common.KVM_SYSTEM_EVENT_RESET;

pub const KVM_CAP_USER_MEMORY = common.KVM_CAP_USER_MEMORY;
pub const KVM_CAP_ONE_REG: u32 = 70;
pub const KVM_CAP_ARM_PSCI_0_2: u32 = 102;
pub const KVM_CAP_DEVICE_CTRL: u32 = 89;
pub const KVM_CAP_COUNTER_OFFSET: u32 = 227;

pub const KVM_MEM_LOG_DIRTY_PAGES: u32 = 1 << 0;

pub const KVM_DEV_TYPE_ARM_VGIC_V3: u32 = 7;
pub const KVM_DEV_ARM_VGIC_GRP_ADDR: u32 = 0;
pub const KVM_DEV_ARM_VGIC_GRP_DIST_REGS: u32 = 1;
pub const KVM_DEV_ARM_VGIC_GRP_CTRL: u32 = 4;
pub const KVM_DEV_ARM_VGIC_GRP_REDIST_REGS: u32 = 5;
pub const KVM_DEV_ARM_VGIC_GRP_CPU_SYSREGS: u32 = 6;
pub const KVM_DEV_ARM_VGIC_GRP_LEVEL_INFO: u32 = 7;
pub const KVM_DEV_ARM_VGIC_CTRL_INIT: u64 = 0;
pub const KVM_VGIC_V3_ADDR_TYPE_DIST: u64 = 2;
pub const KVM_VGIC_V3_ADDR_TYPE_REDIST: u64 = 3;
pub const KVM_DEV_ARM_VGIC_LINE_LEVEL_INFO_SHIFT: u6 = 10;
pub const VGIC_LEVEL_INFO_LINE_LEVEL: u64 = 0;

pub const KVM_ARM_VCPU_POWER_OFF: u32 = 0;
pub const KVM_ARM_VCPU_PSCI_0_2: u32 = 2;
pub const KVM_ARM_IRQ_TYPE_SHIFT: u5 = 24;
pub const KVM_ARM_IRQ_TYPE_SPI: u32 = 1;

pub const KVM_REG_ARM64: u64 = 0x6000_0000_0000_0000;
pub const KVM_REG_SIZE_U32: u64 = 0x0020_0000_0000_0000;
pub const KVM_REG_SIZE_U64: u64 = 0x0030_0000_0000_0000;
pub const KVM_REG_SIZE_U128: u64 = 0x0040_0000_0000_0000;
pub const KVM_REG_ARM_CORE: u64 = 0x0010_0000;
pub const KVM_REG_ARM64_SYSREG: u64 = 0x0013_0000;
pub const KVM_REG_ARM_CORE_SP: u64 = 0x3e;
pub const KVM_REG_ARM_CORE_PC: u64 = 0x40;
pub const KVM_REG_ARM_CORE_PSTATE: u64 = 0x42;
pub const KVM_REG_ARM_CORE_SP_EL1: u64 = 0x44;
pub const KVM_REG_ARM_CORE_ELR_EL1: u64 = 0x46;
pub const KVM_REG_ARM_CORE_SPSR_EL1: u64 = 0x48;
pub const KVM_REG_ARM_CORE_FP_VREG0: u64 = 0x54;
pub const KVM_REG_ARM_CORE_FPSR: u64 = 0xd4;
pub const KVM_REG_ARM_CORE_FPCR: u64 = 0xd5;

pub const KVM_REG_ARM_TIMER_CTL: u64 = 0x6030_0000_0013_df19;
pub const KVM_REG_ARM_TIMER_CVAL: u64 = 0x6030_0000_0013_df02;
pub const KVM_REG_ARM_TIMER_CNT: u64 = 0x6030_0000_0013_df1a;

pub const RunLayout = common.RunLayout;

pub const UserspaceMemoryRegion = common.UserspaceMemoryRegion;

pub const DirtyLog = extern struct {
    slot: u32,
    padding1: u32 = 0,
    dirty_bitmap: u64,
};

pub const VcpuInit = extern struct {
    target: u32,
    features: [7]u32,
};

pub const OneReg = extern struct {
    id: u64,
    addr: u64,
};

pub const CreateDevice = extern struct {
    type: u32,
    fd: u32,
    flags: u32,
};

pub const DeviceAttr = common.DeviceAttr;

pub const IrqLevel = common.IrqLevel;

pub const CounterOffset = extern struct {
    counter_offset: u64,
    reserved: u64 = 0,
};

pub fn openDevKvm() Error!std.c.fd_t {
    return common.openDevKvm(.{ .close_on_exec = false });
}

pub fn ioctl(fd: std.c.fd_t, request: u32, arg: usize, op: []const u8) Error!usize {
    return common.ioctl(fd, request, arg, op);
}

pub fn checkExtension(kvm_fd: std.c.fd_t, cap: u32) Error!u64 {
    return @intCast(try ioctl(kvm_fd, KVM_CHECK_EXTENSION, cap, "KVM_CHECK_EXTENSION"));
}

pub fn requireExtension(kvm_fd: std.c.fd_t, cap: u32, name: []const u8) Error!void {
    const supported = try checkExtension(kvm_fd, cap);
    if (supported == 0) {
        std.log.err("required KVM capability missing: {s} ({d})", .{ name, cap });
        return error.KvmCapabilityMissing;
    }
}

pub fn checkApiVersion(kvm_fd: std.c.fd_t) Error!void {
    const version = try ioctl(kvm_fd, KVM_GET_API_VERSION, 0, "KVM_GET_API_VERSION");
    if (version != KVM_API_VERSION) {
        std.log.err("unsupported KVM API version: got {d}, want {d}", .{ version, KVM_API_VERSION });
        return error.ApiVersionMismatch;
    }
}

pub fn coreReg(offset: u64) u64 {
    return KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM_CORE | offset;
}

pub fn coreRegSized(offset: u64, size: u64) u64 {
    return KVM_REG_ARM64 | size | KVM_REG_ARM_CORE | offset;
}

pub fn gprReg(index: u5) u64 {
    return coreReg(@as(u64, index) * 2);
}

pub fn sysReg(op0: u64, op1: u64, crn: u64, crm: u64, op2: u64) u64 {
    return KVM_REG_ARM64 |
        KVM_REG_SIZE_U64 |
        KVM_REG_ARM64_SYSREG |
        ((op0 & 0x3) << 14) |
        ((op1 & 0x7) << 11) |
        ((crn & 0xf) << 7) |
        ((crm & 0xf) << 3) |
        (op2 & 0x7);
}

pub fn sysRegInstr(op0: u64, op1: u64, crn: u64, crm: u64, op2: u64) u64 {
    return ((op0 & 0x3) << 14) |
        ((op1 & 0x7) << 11) |
        ((crn & 0xf) << 7) |
        ((crm & 0xf) << 3) |
        (op2 & 0x7);
}

pub fn getOneReg(vcpu_fd: std.c.fd_t, id: u64, value: *anyopaque) Error!void {
    var reg = OneReg{ .id = id, .addr = @intFromPtr(value) };
    _ = try ioctl(vcpu_fd, KVM_GET_ONE_REG, @intFromPtr(&reg), "KVM_GET_ONE_REG");
}

pub fn setOneReg(vcpu_fd: std.c.fd_t, id: u64, value: *const anyopaque) Error!void {
    var reg = OneReg{ .id = id, .addr = @intFromPtr(value) };
    _ = try ioctl(vcpu_fd, KVM_SET_ONE_REG, @intFromPtr(&reg), "KVM_SET_ONE_REG");
}

pub fn getOneRegU64(vcpu_fd: std.c.fd_t, id: u64) Error!u64 {
    var value: u64 = 0;
    try getOneReg(vcpu_fd, id, &value);
    return value;
}

pub fn setOneRegU64(vcpu_fd: std.c.fd_t, id: u64, value: u64) Error!void {
    var v = value;
    try setOneReg(vcpu_fd, id, &v);
}

pub fn getOneRegU32(vcpu_fd: std.c.fd_t, id: u64) Error!u32 {
    var value: u32 = 0;
    try getOneReg(vcpu_fd, id, &value);
    return value;
}

pub fn setOneRegU32(vcpu_fd: std.c.fd_t, id: u64, value: u32) Error!void {
    var v = value;
    try setOneReg(vcpu_fd, id, &v);
}

pub fn setIrq(vm_fd: std.c.fd_t, intid: u32, level: bool) Error!void {
    return common.setIrqLine(vm_fd, (KVM_ARM_IRQ_TYPE_SPI << KVM_ARM_IRQ_TYPE_SHIFT) | intid, level);
}

pub const setDeviceAttr = common.setDeviceAttr;
pub const getDeviceAttrMaybeU32 = common.getDeviceAttrMaybeU32;
pub const setDeviceAttrU32 = common.setDeviceAttrU32;
pub const getDeviceAttrMaybeU64 = common.getDeviceAttrMaybeU64;
pub const setDeviceAttrU64 = common.setDeviceAttrU64;

pub fn setCounterOffset(vm_fd: std.c.fd_t, counter_offset: u64) Error!void {
    var offset = CounterOffset{ .counter_offset = counter_offset };
    _ = try ioctl(vm_fd, KVM_ARM_SET_COUNTER_OFFSET, @intFromPtr(&offset), "KVM_ARM_SET_COUNTER_OFFSET");
}

pub fn completePendingExit(vcpu_fd: std.c.fd_t, run: []u8) Error!void {
    run[RunLayout.immediate_exit] = 1;
    defer run[RunLayout.immediate_exit] = 0;

    const rc = linux.ioctl(vcpu_fd, KVM_RUN, 0);
    switch (linux.errno(rc)) {
        .SUCCESS, .INTR => {},
        else => |err| {
            std.log.err("KVM_RUN immediate_exit failed: {s}", .{@tagName(err)});
            return error.KvmIoctlFailed;
        },
    }
}

pub const RunResult = enum { completed, interrupted };

pub fn runVcpu(vcpu_fd: std.c.fd_t) Error!RunResult {
    const rc = linux.ioctl(vcpu_fd, KVM_RUN, 0);
    switch (linux.errno(rc)) {
        .SUCCESS => return .completed,
        .INTR => return .interrupted,
        else => |err| {
            std.log.err("KVM_RUN failed: {s}", .{@tagName(err)});
            return error.KvmIoctlFailed;
        },
    }
}

pub fn exitReason(run: []u8) u32 {
    return std.mem.readInt(u32, run[RunLayout.exit_reason..][0..4], .native);
}

pub fn systemEventType(run: []u8) u32 {
    return std.mem.readInt(u32, run[RunLayout.system_event_type..][0..4], .native);
}

pub const MmioExit = struct {
    phys_addr: u64,
    data: *[8]u8,
    len: u32,
    is_write: bool,
};

pub fn mmioExit(run: []u8) MmioExit {
    return .{
        .phys_addr = std.mem.readInt(u64, run[RunLayout.mmio_phys_addr..][0..8], .native),
        .data = run[RunLayout.mmio_data..][0..8],
        .len = std.mem.readInt(u32, run[RunLayout.mmio_len..][0..4], .native),
        .is_write = run[RunLayout.mmio_is_write] != 0,
    };
}

test "aarch64 KVM register id helpers match UAPI constants" {
    try std.testing.expectEqual(@as(u64, 0x6030_0000_0013_c080), sysReg(3, 0, 1, 0, 0)); // SCTLR_EL1
    try std.testing.expectEqual(@as(u64, 0x6030_0000_0013_c684), sysReg(3, 0, 13, 0, 4)); // TPIDR_EL1
    try std.testing.expectEqual(@as(u64, 0x6030_0000_0013_de82), sysReg(3, 3, 13, 0, 2)); // TPIDR_EL0
    try std.testing.expectEqual(@as(u64, 0x6040_0000_0010_0054), coreRegSized(KVM_REG_ARM_CORE_FP_VREG0, KVM_REG_SIZE_U128));
}
