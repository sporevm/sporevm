//! Linux KVM bindings for the aarch64 backend.
//!
//! This module deliberately mirrors only the small KVM UAPI surface SporeVM
//! needs for bring-up: VM/vCPU creation, one-reg access, userspace VGICv3,
//! guest RAM mapping, MMIO exits, and SPI injection. Constants come from the
//! Linux 6.17 UAPI headers on the aarch64 dev host and are stable KVM ABI.

const std = @import("std");
const linux = std.os.linux;

pub const vm = @import("vm.zig");

pub const Error = error{
    ApiVersionMismatch,
    KvmCapabilityMissing,
    KvmIoctlFailed,
    OpenFailed,
    UnexpectedExit,
    UnhandledMmio,
};

pub const KVM_API_VERSION: u32 = 12;

pub const KVM_GET_API_VERSION: u32 = 0xae00;
pub const KVM_CREATE_VM: u32 = 0xae01;
pub const KVM_CHECK_EXTENSION: u32 = 0xae03;
pub const KVM_GET_VCPU_MMAP_SIZE: u32 = 0xae04;
pub const KVM_CREATE_VCPU: u32 = 0xae41;
pub const KVM_SET_USER_MEMORY_REGION: u32 = 0x4020ae46;
pub const KVM_RUN: u32 = 0xae80;
pub const KVM_IRQ_LINE: u32 = 0x4008ae61;
pub const KVM_GET_ONE_REG: u32 = 0x4010aeab;
pub const KVM_SET_ONE_REG: u32 = 0x4010aeac;
pub const KVM_ARM_VCPU_INIT: u32 = 0x4020aeae;
pub const KVM_ARM_PREFERRED_TARGET: u32 = 0x8020aeaf;
pub const KVM_CREATE_DEVICE: u32 = 0xc00caee0;
pub const KVM_SET_DEVICE_ATTR: u32 = 0x4018aee1;
pub const KVM_GET_DEVICE_ATTR: u32 = 0x4018aee2;
pub const KVM_HAS_DEVICE_ATTR: u32 = 0x4018aee3;
pub const KVM_ARM_SET_COUNTER_OFFSET: u32 = 0x4010aeb5;

pub const KVM_EXIT_MMIO: u32 = 6;
pub const KVM_EXIT_SHUTDOWN: u32 = 8;
pub const KVM_EXIT_FAIL_ENTRY: u32 = 9;
pub const KVM_EXIT_INTERNAL_ERROR: u32 = 17;
pub const KVM_EXIT_SYSTEM_EVENT: u32 = 24;

pub const KVM_SYSTEM_EVENT_SHUTDOWN: u32 = 1;
pub const KVM_SYSTEM_EVENT_RESET: u32 = 2;

pub const KVM_CAP_USER_MEMORY: u32 = 3;
pub const KVM_CAP_ONE_REG: u32 = 70;
pub const KVM_CAP_ARM_PSCI_0_2: u32 = 102;
pub const KVM_CAP_DEVICE_CTRL: u32 = 89;
pub const KVM_CAP_COUNTER_OFFSET: u32 = 227;

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

pub const RunLayout = struct {
    pub const immediate_exit: usize = 1;
    pub const exit_reason: usize = 8;
    pub const mmio_phys_addr: usize = 32;
    pub const mmio_data: usize = 40;
    pub const mmio_len: usize = 48;
    pub const mmio_is_write: usize = 52;
    pub const system_event_type: usize = 32;
};

pub const UserspaceMemoryRegion = extern struct {
    slot: u32,
    flags: u32,
    guest_phys_addr: u64,
    memory_size: u64,
    userspace_addr: u64,
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

pub const DeviceAttr = extern struct {
    flags: u32,
    group: u32,
    attr: u64,
    addr: u64,
};

pub const IrqLevel = extern struct {
    irq: u32,
    level: u32,
};

pub const CounterOffset = extern struct {
    counter_offset: u64,
    reserved: u64 = 0,
};

pub fn openDevKvm() Error!std.c.fd_t {
    const path: [:0]const u8 = "/dev/kvm";
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDWR }, @as(c_uint, 0));
    if (fd < 0) return error.OpenFailed;
    return fd;
}

pub fn ioctl(fd: std.c.fd_t, request: u32, arg: usize, op: []const u8) Error!usize {
    const rc = linux.ioctl(fd, request, arg);
    switch (linux.errno(rc)) {
        .SUCCESS => return rc,
        else => |err| {
            std.log.err("{s}: KVM ioctl 0x{x} failed: {s}", .{ op, request, @tagName(err) });
            return error.KvmIoctlFailed;
        },
    }
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
    var irq = IrqLevel{ .irq = (KVM_ARM_IRQ_TYPE_SPI << KVM_ARM_IRQ_TYPE_SHIFT) | intid, .level = @intFromBool(level) };
    _ = try ioctl(vm_fd, KVM_IRQ_LINE, @intFromPtr(&irq), "KVM_IRQ_LINE");
}

pub fn hasDeviceAttr(fd: std.c.fd_t, group: u32, attr_id: u64) bool {
    var attr = DeviceAttr{ .flags = 0, .group = group, .attr = attr_id, .addr = 0 };
    const rc = linux.ioctl(fd, KVM_HAS_DEVICE_ATTR, @intFromPtr(&attr));
    return linux.errno(rc) == .SUCCESS;
}

pub fn getDeviceAttr(fd: std.c.fd_t, group: u32, attr_id: u64, value: *anyopaque, op: []const u8) Error!void {
    var attr = DeviceAttr{ .flags = 0, .group = group, .attr = attr_id, .addr = @intFromPtr(value) };
    _ = try ioctl(fd, KVM_GET_DEVICE_ATTR, @intFromPtr(&attr), op);
}

pub fn setDeviceAttr(fd: std.c.fd_t, group: u32, attr_id: u64, value: *const anyopaque, op: []const u8) Error!void {
    var attr = DeviceAttr{ .flags = 0, .group = group, .attr = attr_id, .addr = @intFromPtr(value) };
    _ = try ioctl(fd, KVM_SET_DEVICE_ATTR, @intFromPtr(&attr), op);
}

pub fn getDeviceAttrU32(fd: std.c.fd_t, group: u32, attr_id: u64, op: []const u8) Error!u32 {
    var value: u32 = 0;
    try getDeviceAttr(fd, group, attr_id, &value, op);
    return value;
}

pub fn getDeviceAttrMaybeU32(fd: std.c.fd_t, group: u32, attr_id: u64, op: []const u8) Error!?u32 {
    var value: u32 = 0;
    var attr = DeviceAttr{ .flags = 0, .group = group, .attr = attr_id, .addr = @intFromPtr(&value) };
    const rc = linux.ioctl(fd, KVM_GET_DEVICE_ATTR, @intFromPtr(&attr));
    switch (linux.errno(rc)) {
        .SUCCESS => return value,
        .INVAL => return null,
        else => |err| {
            std.log.err("{s}: KVM ioctl 0x{x} failed: {s}", .{ op, KVM_GET_DEVICE_ATTR, @tagName(err) });
            return error.KvmIoctlFailed;
        },
    }
}

pub fn setDeviceAttrU32(fd: std.c.fd_t, group: u32, attr_id: u64, value: u32, op: []const u8) Error!void {
    var v = value;
    try setDeviceAttr(fd, group, attr_id, &v, op);
}

pub fn getDeviceAttrU64(fd: std.c.fd_t, group: u32, attr_id: u64, op: []const u8) Error!u64 {
    var value: u64 = 0;
    try getDeviceAttr(fd, group, attr_id, &value, op);
    return value;
}

pub fn getDeviceAttrMaybeU64(fd: std.c.fd_t, group: u32, attr_id: u64, op: []const u8) Error!?u64 {
    var value: u64 = 0;
    var attr = DeviceAttr{ .flags = 0, .group = group, .attr = attr_id, .addr = @intFromPtr(&value) };
    const rc = linux.ioctl(fd, KVM_GET_DEVICE_ATTR, @intFromPtr(&attr));
    switch (linux.errno(rc)) {
        .SUCCESS => return value,
        .INVAL => return null,
        else => |err| {
            std.log.err("{s}: KVM ioctl 0x{x} failed: {s}", .{ op, KVM_GET_DEVICE_ATTR, @tagName(err) });
            return error.KvmIoctlFailed;
        },
    }
}

pub fn setDeviceAttrU64(fd: std.c.fd_t, group: u32, attr_id: u64, value: u64, op: []const u8) Error!void {
    var v = value;
    try setDeviceAttr(fd, group, attr_id, &v, op);
}

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
