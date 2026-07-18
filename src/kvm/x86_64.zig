//! Minimal Linux KVM UAPI used by the host-only x86-64 boot harness.
//!
//! Product KVM boundaries remain aarch64-only until Slice 1. This module owns
//! only the x86 bring-up ioctls and the bounded KVM_EXIT_IO decoder.

const std = @import("std");
const linux = std.os.linux;

pub const KVM_API_VERSION: u32 = 12;
pub const KVM_GET_API_VERSION: u32 = 0xae00;
pub const KVM_CREATE_VM: u32 = 0xae01;
pub const KVM_GET_SUPPORTED_CPUID: u32 = 0xc008ae05;
pub const KVM_CHECK_EXTENSION: u32 = 0xae03;
pub const KVM_GET_VCPU_MMAP_SIZE: u32 = 0xae04;
pub const KVM_CREATE_VCPU: u32 = 0xae41;
pub const KVM_SET_USER_MEMORY_REGION: u32 = 0x4020ae46;
pub const KVM_SET_TSS_ADDR: u32 = 0xae47;
pub const KVM_SET_IDENTITY_MAP_ADDR: u32 = 0x4008ae48;
pub const KVM_CREATE_IRQCHIP: u32 = 0xae60;
pub const KVM_IRQ_LINE: u32 = 0x4008ae61;
pub const KVM_CREATE_PIT2: u32 = 0x4040ae77;
pub const KVM_RUN: u32 = 0xae80;
pub const KVM_GET_SREGS: u32 = 0x8138ae83;
pub const KVM_SET_REGS: u32 = 0x4090ae82;
pub const KVM_SET_SREGS: u32 = 0x4138ae84;
pub const KVM_SET_CPUID2: u32 = 0x4008ae90;

pub const KVM_EXIT_IO: u32 = 2;
pub const KVM_EXIT_HLT: u32 = 5;
pub const KVM_EXIT_MMIO: u32 = 6;
pub const KVM_EXIT_SHUTDOWN: u32 = 8;
pub const KVM_EXIT_FAIL_ENTRY: u32 = 9;
pub const KVM_EXIT_INTERNAL_ERROR: u32 = 17;
pub const KVM_EXIT_SYSTEM_EVENT: u32 = 24;
pub const KVM_SYSTEM_EVENT_SHUTDOWN: u32 = 1;
pub const KVM_SYSTEM_EVENT_RESET: u32 = 2;

pub const KVM_CAP_IRQCHIP: u32 = 0;
pub const KVM_CAP_USER_MEMORY: u32 = 3;
pub const KVM_CAP_SET_TSS_ADDR: u32 = 4;
pub const KVM_CAP_PIT2: u32 = 33;
pub const KVM_CAP_SET_IDENTITY_MAP_ADDR: u32 = 37;

pub const max_cpuid_entries: usize = 256;
pub const max_io_payload: usize = 4096;

pub const Error = error{
    ApiVersionMismatch,
    KvmCapabilityMissing,
    KvmIoctlFailed,
    OpenFailed,
    CpuidTooLarge,
};

pub const IoDecodeError = error{
    IoRunTooSmall,
    InvalidIoDirection,
    InvalidIoWidth,
    InvalidIoCount,
    IoPayloadTooLarge,
    IoDataOutOfBounds,
};

pub const RunLayout = struct {
    pub const exit_reason: usize = 8;
    pub const io_direction: usize = 32;
    pub const io_size: usize = 33;
    pub const io_port: usize = 34;
    pub const io_count: usize = 36;
    pub const io_data_offset: usize = 40;
    pub const io_envelope_end: usize = 48;
    pub const mmio_phys_addr: usize = 32;
    pub const mmio_data: usize = 40;
    pub const mmio_len: usize = 48;
    pub const mmio_is_write: usize = 52;
    pub const mmio_end: usize = 53;
    pub const system_event_type: usize = 32;
};

pub const IoDirection = enum(u8) { read = 0, write = 1 };

pub const IoExit = struct {
    direction: IoDirection,
    width: u8,
    port: u16,
    count: u32,
    data: []u8,
};

/// Decode one guest-controlled KVM_EXIT_IO envelope. Port policy remains at the
/// caller so Stage 0a.3 can freeze its finite table without weakening bounds.
pub fn decodeIoExit(run: []u8) IoDecodeError!IoExit {
    if (run.len < RunLayout.io_envelope_end) return error.IoRunTooSmall;

    const direction = std.enums.fromInt(IoDirection, run[RunLayout.io_direction]) orelse return error.InvalidIoDirection;
    const width = run[RunLayout.io_size];
    if (width != 1 and width != 2 and width != 4) return error.InvalidIoWidth;

    const port = std.mem.readInt(u16, run[RunLayout.io_port..][0..2], .native);

    const count = std.mem.readInt(u32, run[RunLayout.io_count..][0..4], .native);
    if (count == 0) return error.InvalidIoCount;
    const payload_len = std.math.mul(usize, width, count) catch return error.IoPayloadTooLarge;
    if (payload_len > max_io_payload) return error.IoPayloadTooLarge;

    const data_offset_u64 = std.mem.readInt(u64, run[RunLayout.io_data_offset..][0..8], .native);
    const data_offset = std.math.cast(usize, data_offset_u64) orelse return error.IoDataOutOfBounds;
    const data_end = std.math.add(usize, data_offset, payload_len) catch return error.IoDataOutOfBounds;
    if (data_offset < RunLayout.io_envelope_end or data_end > run.len) return error.IoDataOutOfBounds;

    return .{
        .direction = direction,
        .width = width,
        .port = port,
        .count = count,
        .data = run[data_offset..data_end],
    };
}

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

pub const PitConfig = extern struct {
    flags: u32 = 0,
    padding: [15]u32 = @splat(0),
};

pub const Regs = extern struct {
    rax: u64 = 0,
    rbx: u64 = 0,
    rcx: u64 = 0,
    rdx: u64 = 0,
    rsi: u64 = 0,
    rdi: u64 = 0,
    rsp: u64 = 0,
    rbp: u64 = 0,
    r8: u64 = 0,
    r9: u64 = 0,
    r10: u64 = 0,
    r11: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
    rip: u64 = 0,
    rflags: u64 = 0,
};

pub const Segment = extern struct {
    base: u64 = 0,
    limit: u32 = 0,
    selector: u16 = 0,
    type: u8 = 0,
    present: u8 = 0,
    dpl: u8 = 0,
    db: u8 = 0,
    s: u8 = 0,
    l: u8 = 0,
    g: u8 = 0,
    avl: u8 = 0,
    unusable: u8 = 0,
    padding: u8 = 0,
};

pub const Dtable = extern struct {
    base: u64 = 0,
    limit: u16 = 0,
    padding: [3]u16 = @splat(0),
};

pub const Sregs = extern struct {
    cs: Segment,
    ds: Segment,
    es: Segment,
    fs: Segment,
    gs: Segment,
    ss: Segment,
    tr: Segment,
    ldt: Segment,
    gdt: Dtable,
    idt: Dtable,
    cr0: u64,
    cr2: u64,
    cr3: u64,
    cr4: u64,
    cr8: u64,
    efer: u64,
    apic_base: u64,
    interrupt_bitmap: [4]u64,
};

pub const CpuidEntry = extern struct {
    function: u32 = 0,
    index: u32 = 0,
    flags: u32 = 0,
    eax: u32 = 0,
    ebx: u32 = 0,
    ecx: u32 = 0,
    edx: u32 = 0,
    padding: [3]u32 = @splat(0),
};

pub const Cpuid = extern struct {
    nent: u32 = max_cpuid_entries,
    padding: u32 = 0,
    entries: [max_cpuid_entries]CpuidEntry = @splat(.{}),
};

pub fn openDevKvm() Error!std.c.fd_t {
    const path: [:0]const u8 = "/dev/kvm";
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, @as(c_uint, 0));
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

pub fn checkApiVersion(kvm_fd: std.c.fd_t) Error!void {
    if (try ioctl(kvm_fd, KVM_GET_API_VERSION, 0, "KVM_GET_API_VERSION") != KVM_API_VERSION) {
        return error.ApiVersionMismatch;
    }
}

pub fn requireExtension(kvm_fd: std.c.fd_t, capability: u32, name: []const u8) Error!void {
    if (try ioctl(kvm_fd, KVM_CHECK_EXTENSION, capability, "KVM_CHECK_EXTENSION") == 0) {
        std.log.err("required KVM capability missing: {s} ({d})", .{ name, capability });
        return error.KvmCapabilityMissing;
    }
}

pub fn getSupportedCpuid(kvm_fd: std.c.fd_t) Error!Cpuid {
    var cpuid = Cpuid{};
    _ = try ioctl(kvm_fd, KVM_GET_SUPPORTED_CPUID, @intFromPtr(&cpuid), "KVM_GET_SUPPORTED_CPUID");
    if (cpuid.nent > max_cpuid_entries) return error.CpuidTooLarge;
    return cpuid;
}

pub fn setIrq(vm_fd: std.c.fd_t, gsi: u32, level: bool) Error!void {
    var irq = IrqLevel{ .irq = gsi, .level = @intFromBool(level) };
    _ = try ioctl(vm_fd, KVM_IRQ_LINE, @intFromPtr(&irq), "KVM_IRQ_LINE");
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

pub fn exitReason(run: []const u8) u32 {
    return std.mem.readInt(u32, run[RunLayout.exit_reason..][0..4], .native);
}

fn makeIoRun(run: []u8, direction: u8, width: u8, port: u16, count: u32, data_offset: u64) void {
    @memset(run, 0);
    run[RunLayout.io_direction] = direction;
    run[RunLayout.io_size] = width;
    std.mem.writeInt(u16, run[RunLayout.io_port..][0..2], port, .native);
    std.mem.writeInt(u32, run[RunLayout.io_count..][0..4], count, .native);
    std.mem.writeInt(u64, run[RunLayout.io_data_offset..][0..8], data_offset, .native);
}

test "x86 KVM UAPI layouts match Linux" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(UserspaceMemoryRegion));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(IrqLevel));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(PitConfig));
    try std.testing.expectEqual(@as(usize, 144), @sizeOf(Regs));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Segment));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Dtable));
    try std.testing.expectEqual(@as(usize, 312), @sizeOf(Sregs));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(CpuidEntry));
}

test "KVM_EXIT_IO decoder accepts one bounded envelope" {
    var run: [4096]u8 = undefined;
    makeIoRun(&run, @intFromEnum(IoDirection.write), 4, 0x80, 2, 64);
    const decoded = try decodeIoExit(&run);
    try std.testing.expectEqual(IoDirection.write, decoded.direction);
    try std.testing.expectEqual(@as(u8, 4), decoded.width);
    try std.testing.expectEqual(@as(u16, 0x80), decoded.port);
    try std.testing.expectEqual(@as(u32, 2), decoded.count);
    try std.testing.expectEqual(@as(usize, 8), decoded.data.len);
}

test "KVM_EXIT_IO decoder rejects every malformed envelope field" {
    var run: [4096]u8 = undefined;
    makeIoRun(&run, 2, 1, 0x80, 1, 64);
    try std.testing.expectError(error.InvalidIoDirection, decodeIoExit(&run));
    makeIoRun(&run, 1, 3, 0x80, 1, 64);
    try std.testing.expectError(error.InvalidIoWidth, decodeIoExit(&run));
    makeIoRun(&run, 1, 1, 0x80, 0, 64);
    try std.testing.expectError(error.InvalidIoCount, decodeIoExit(&run));
    makeIoRun(&run, 1, 4, 0x80, max_io_payload / 4 + 1, 64);
    try std.testing.expectError(error.IoPayloadTooLarge, decodeIoExit(&run));
    makeIoRun(&run, 1, 1, 0x80, 1, std.math.maxInt(u64));
    try std.testing.expectError(error.IoDataOutOfBounds, decodeIoExit(&run));
    makeIoRun(&run, 1, 4, 0x80, 2, run.len - 4);
    try std.testing.expectError(error.IoDataOutOfBounds, decodeIoExit(&run));
    try std.testing.expectError(error.IoRunTooSmall, decodeIoExit(run[0 .. RunLayout.io_envelope_end - 1]));
}

fn fuzzIoExit(_: void, smith: *std.testing.Smith) !void {
    var run: [8192]u8 = undefined;
    const len = smith.slice(&run);
    const decoded = decodeIoExit(run[0..len]) catch return;
    try std.testing.expect(decoded.width == 1 or decoded.width == 2 or decoded.width == 4);
    try std.testing.expect(decoded.count > 0);
    try std.testing.expect(decoded.data.len <= max_io_payload);
    try std.testing.expect(@intFromPtr(decoded.data.ptr) >= @intFromPtr(run[0..len].ptr));
    try std.testing.expect(@intFromPtr(decoded.data.ptr) + decoded.data.len <= @intFromPtr(run[0..len].ptr) + len);
}

test "fuzz KVM_EXIT_IO envelope decoder" {
    try std.testing.fuzz({}, fuzzIoExit, .{});
}
