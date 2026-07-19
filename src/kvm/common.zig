//! Architecture-neutral Linux KVM UAPI literals and ABI layouts.
//!
//! This module contains only the raw surface shared by the architecture
//! facades. Guest state, exit interpretation, and architecture policy stay in
//! `kvm.zig` and `x86_64.zig`.

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{
    KvmIoctlFailed,
    OpenFailed,
};

pub const KVM_API_VERSION: u32 = 12;

pub const KVM_GET_API_VERSION: u32 = 0xae00;
pub const KVM_CREATE_VM: u32 = 0xae01;
pub const KVM_CHECK_EXTENSION: u32 = 0xae03;
pub const KVM_GET_VCPU_MMAP_SIZE: u32 = 0xae04;
pub const KVM_CREATE_VCPU: u32 = 0xae41;
pub const KVM_SET_USER_MEMORY_REGION: u32 = 0x4020ae46;
pub const KVM_IRQ_LINE: u32 = 0x4008ae61;
pub const KVM_RUN: u32 = 0xae80;
pub const KVM_SET_DEVICE_ATTR: u32 = 0x4018aee1;
pub const KVM_GET_DEVICE_ATTR: u32 = 0x4018aee2;
pub const KVM_HAS_DEVICE_ATTR: u32 = 0x4018aee3;

pub const KVM_EXIT_MMIO: u32 = 6;
pub const KVM_EXIT_SHUTDOWN: u32 = 8;
pub const KVM_EXIT_FAIL_ENTRY: u32 = 9;
pub const KVM_EXIT_INTERNAL_ERROR: u32 = 17;
pub const KVM_EXIT_SYSTEM_EVENT: u32 = 24;

pub const KVM_SYSTEM_EVENT_SHUTDOWN: u32 = 1;
pub const KVM_SYSTEM_EVENT_RESET: u32 = 2;

pub const KVM_CAP_USER_MEMORY: u32 = 3;

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

pub const IrqLevel = extern struct {
    irq: u32,
    level: u32,
};

pub const DeviceAttr = extern struct {
    flags: u32,
    group: u32,
    attr: u64,
    addr: u64,
};

pub const OpenOptions = struct {
    close_on_exec: bool,
};

pub fn openDevKvm(options: OpenOptions) Error!std.c.fd_t {
    const path: [:0]const u8 = "/dev/kvm";
    const fd = std.c.open(path.ptr, openFlags(options), @as(c_uint, 0));
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

pub fn setIrqLine(vm_fd: std.c.fd_t, irq: u32, level: bool) Error!void {
    var irq_level = IrqLevel{ .irq = irq, .level = @intFromBool(level) };
    _ = try ioctl(vm_fd, KVM_IRQ_LINE, @intFromPtr(&irq_level), "KVM_IRQ_LINE");
}

pub fn hasDeviceAttr(fd: std.c.fd_t, group: u32, attr_id: u64, op: []const u8) Error!bool {
    var attr = DeviceAttr{ .flags = 0, .group = group, .attr = attr_id, .addr = 0 };
    const rc = linux.ioctl(fd, KVM_HAS_DEVICE_ATTR, @intFromPtr(&attr));
    return switch (linux.errno(rc)) {
        .SUCCESS => true,
        .NOENT, .INVAL, .NXIO => false,
        else => |err| {
            std.log.err("{s}: KVM ioctl 0x{x} failed: {s}", .{ op, KVM_HAS_DEVICE_ATTR, @tagName(err) });
            return error.KvmIoctlFailed;
        },
    };
}

pub fn setDeviceAttr(fd: std.c.fd_t, group: u32, attr_id: u64, value: *const anyopaque, op: []const u8) Error!void {
    var attr = DeviceAttr{ .flags = 0, .group = group, .attr = attr_id, .addr = @intFromPtr(value) };
    _ = try ioctl(fd, KVM_SET_DEVICE_ATTR, @intFromPtr(&attr), op);
}

fn getDeviceAttrMaybe(comptime T: type, fd: std.c.fd_t, group: u32, attr_id: u64, op: []const u8) Error!?T {
    var value: T = 0;
    var attr = DeviceAttr{ .flags = 0, .group = group, .attr = attr_id, .addr = @intFromPtr(&value) };
    const rc = linux.ioctl(fd, KVM_GET_DEVICE_ATTR, @intFromPtr(&attr));
    return switch (linux.errno(rc)) {
        .SUCCESS => value,
        .INVAL => null,
        else => |err| {
            std.log.err("{s}: KVM ioctl 0x{x} failed: {s}", .{ op, KVM_GET_DEVICE_ATTR, @tagName(err) });
            return error.KvmIoctlFailed;
        },
    };
}

pub fn getDeviceAttrMaybeU32(fd: std.c.fd_t, group: u32, attr_id: u64, op: []const u8) Error!?u32 {
    return getDeviceAttrMaybe(u32, fd, group, attr_id, op);
}

pub fn setDeviceAttrU32(fd: std.c.fd_t, group: u32, attr_id: u64, value: u32, op: []const u8) Error!void {
    var mutable_value = value;
    return setDeviceAttr(fd, group, attr_id, &mutable_value, op);
}

pub fn getDeviceAttrMaybeU64(fd: std.c.fd_t, group: u32, attr_id: u64, op: []const u8) Error!?u64 {
    return getDeviceAttrMaybe(u64, fd, group, attr_id, op);
}

pub fn getDeviceAttrU64(fd: std.c.fd_t, group: u32, attr_id: u64, op: []const u8) Error!u64 {
    var value: u64 = 0;
    var attr = DeviceAttr{ .flags = 0, .group = group, .attr = attr_id, .addr = @intFromPtr(&value) };
    _ = try ioctl(fd, KVM_GET_DEVICE_ATTR, @intFromPtr(&attr), op);
    return value;
}

pub fn setDeviceAttrU64(fd: std.c.fd_t, group: u32, attr_id: u64, value: u64, op: []const u8) Error!void {
    var mutable_value = value;
    return setDeviceAttr(fd, group, attr_id, &mutable_value, op);
}

fn openFlags(options: OpenOptions) std.c.O {
    return .{
        .ACCMODE = .RDWR,
        .CLOEXEC = options.close_on_exec,
    };
}

test "common KVM UAPI values" {
    try std.testing.expectEqual(@as(u32, 12), KVM_API_VERSION);
    try std.testing.expectEqual(@as(u32, 0xae00), KVM_GET_API_VERSION);
    try std.testing.expectEqual(@as(u32, 0xae01), KVM_CREATE_VM);
    try std.testing.expectEqual(@as(u32, 0xae03), KVM_CHECK_EXTENSION);
    try std.testing.expectEqual(@as(u32, 0xae04), KVM_GET_VCPU_MMAP_SIZE);
    try std.testing.expectEqual(@as(u32, 0xae41), KVM_CREATE_VCPU);
    try std.testing.expectEqual(@as(u32, 0x4020ae46), KVM_SET_USER_MEMORY_REGION);
    try std.testing.expectEqual(@as(u32, 0x4008ae61), KVM_IRQ_LINE);
    try std.testing.expectEqual(@as(u32, 0xae80), KVM_RUN);
    try std.testing.expectEqual(@as(u32, 0x4018aee1), KVM_SET_DEVICE_ATTR);
    try std.testing.expectEqual(@as(u32, 0x4018aee2), KVM_GET_DEVICE_ATTR);
    try std.testing.expectEqual(@as(u32, 0x4018aee3), KVM_HAS_DEVICE_ATTR);
    try std.testing.expectEqual(@as(usize, 1), RunLayout.immediate_exit);
    try std.testing.expectEqual(@as(usize, 8), RunLayout.exit_reason);
    try std.testing.expectEqual(@as(usize, 32), RunLayout.mmio_phys_addr);
    try std.testing.expectEqual(@as(usize, 40), RunLayout.mmio_data);
    try std.testing.expectEqual(@as(usize, 48), RunLayout.mmio_len);
    try std.testing.expectEqual(@as(usize, 52), RunLayout.mmio_is_write);
    try std.testing.expectEqual(@as(usize, 32), RunLayout.system_event_type);
}

test "common KVM ABI layouts" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(UserspaceMemoryRegion));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(UserspaceMemoryRegion));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(UserspaceMemoryRegion, "slot"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(UserspaceMemoryRegion, "flags"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(UserspaceMemoryRegion, "guest_phys_addr"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(UserspaceMemoryRegion, "memory_size"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(UserspaceMemoryRegion, "userspace_addr"));

    try std.testing.expectEqual(@as(usize, 8), @sizeOf(IrqLevel));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(IrqLevel));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(IrqLevel, "irq"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(IrqLevel, "level"));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(DeviceAttr));
}

test "open options preserve close-on-exec choice" {
    try std.testing.expect(!openFlags(.{ .close_on_exec = false }).CLOEXEC);
    try std.testing.expect(openFlags(.{ .close_on_exec = true }).CLOEXEC);
}
