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

pub const KVM_DEV_TYPE_ARM_VGIC_V3: u32 = 7;
pub const KVM_DEV_ARM_VGIC_GRP_ADDR: u32 = 0;
pub const KVM_DEV_ARM_VGIC_GRP_CTRL: u32 = 4;
pub const KVM_DEV_ARM_VGIC_CTRL_INIT: u64 = 0;
pub const KVM_VGIC_V3_ADDR_TYPE_DIST: u64 = 2;
pub const KVM_VGIC_V3_ADDR_TYPE_REDIST: u64 = 3;

pub const KVM_ARM_VCPU_PSCI_0_2: u32 = 2;
pub const KVM_ARM_IRQ_TYPE_SHIFT: u5 = 24;
pub const KVM_ARM_IRQ_TYPE_SPI: u32 = 1;

pub const KVM_REG_ARM64: u64 = 0x6000_0000_0000_0000;
pub const KVM_REG_SIZE_U64: u64 = 0x0030_0000_0000_0000;
pub const KVM_REG_ARM_CORE: u64 = 0x0010_0000;
pub const KVM_REG_ARM_CORE_PC: u64 = 0x40;
pub const KVM_REG_ARM_CORE_PSTATE: u64 = 0x42;

pub const RunLayout = struct {
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

pub fn gprReg(index: u5) u64 {
    return coreReg(@as(u64, index) * 2);
}

pub fn setOneReg(vcpu_fd: std.c.fd_t, id: u64, value: *u64) Error!void {
    var reg = OneReg{ .id = id, .addr = @intFromPtr(value) };
    _ = try ioctl(vcpu_fd, KVM_SET_ONE_REG, @intFromPtr(&reg), "KVM_SET_ONE_REG");
}

pub fn setIrq(vm_fd: std.c.fd_t, intid: u32, level: bool) Error!void {
    var irq = IrqLevel{ .irq = (KVM_ARM_IRQ_TYPE_SPI << KVM_ARM_IRQ_TYPE_SHIFT) | intid, .level = @intFromBool(level) };
    _ = try ioctl(vm_fd, KVM_IRQ_LINE, @intFromPtr(&irq), "KVM_IRQ_LINE");
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
