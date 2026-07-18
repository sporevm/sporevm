//! Minimal Linux KVM UAPI used by the host-only x86-64 boot harness.
//!
//! Product KVM boundaries remain aarch64-only until Slice 1. This module owns
//! only the x86 bring-up ioctls and the bounded KVM_EXIT_IO decoder.

const std = @import("std");
const linux = std.os.linux;
const common = @import("common.zig");
const topology = @import("../topology.zig");

pub const KVM_API_VERSION = common.KVM_API_VERSION;
pub const KVM_GET_API_VERSION = common.KVM_GET_API_VERSION;
pub const KVM_CREATE_VM = common.KVM_CREATE_VM;
pub const KVM_GET_SUPPORTED_CPUID: u32 = 0xc008ae05;
pub const KVM_CHECK_EXTENSION = common.KVM_CHECK_EXTENSION;
pub const KVM_GET_VCPU_MMAP_SIZE = common.KVM_GET_VCPU_MMAP_SIZE;
pub const KVM_CREATE_VCPU = common.KVM_CREATE_VCPU;
pub const KVM_SET_USER_MEMORY_REGION = common.KVM_SET_USER_MEMORY_REGION;
pub const KVM_SET_TSS_ADDR: u32 = 0xae47;
pub const KVM_SET_IDENTITY_MAP_ADDR: u32 = 0x4008ae48;
pub const KVM_CREATE_IRQCHIP: u32 = 0xae60;
pub const KVM_IRQ_LINE = common.KVM_IRQ_LINE;
pub const KVM_CREATE_PIT2: u32 = 0x4040ae77;
pub const KVM_RUN = common.KVM_RUN;
pub const KVM_GET_SREGS: u32 = 0x8138ae83;
pub const KVM_SET_REGS: u32 = 0x4090ae82;
pub const KVM_SET_SREGS: u32 = 0x4138ae84;
pub const KVM_SET_CPUID2: u32 = 0x4008ae90;
pub const KVM_GET_MP_STATE: u32 = 0x8004ae98;

pub const KVM_EXIT_IO: u32 = 2;
pub const KVM_EXIT_HLT: u32 = 5;
pub const KVM_EXIT_MMIO = common.KVM_EXIT_MMIO;
pub const KVM_EXIT_SHUTDOWN = common.KVM_EXIT_SHUTDOWN;
pub const KVM_EXIT_FAIL_ENTRY = common.KVM_EXIT_FAIL_ENTRY;
pub const KVM_EXIT_INTERNAL_ERROR = common.KVM_EXIT_INTERNAL_ERROR;
pub const KVM_EXIT_SYSTEM_EVENT = common.KVM_EXIT_SYSTEM_EVENT;
pub const KVM_SYSTEM_EVENT_SHUTDOWN = common.KVM_SYSTEM_EVENT_SHUTDOWN;
pub const KVM_SYSTEM_EVENT_RESET = common.KVM_SYSTEM_EVENT_RESET;

pub const KVM_CAP_IRQCHIP: u32 = 0;
pub const KVM_CAP_USER_MEMORY = common.KVM_CAP_USER_MEMORY;
pub const KVM_CAP_SET_TSS_ADDR: u32 = 4;
pub const KVM_CAP_EXT_CPUID: u32 = 7;
pub const KVM_CAP_NR_VCPUS: u32 = 9;
pub const KVM_CAP_MP_STATE: u32 = 14;
pub const KVM_CAP_PIT2: u32 = 33;
pub const KVM_CAP_SET_IDENTITY_MAP_ADDR: u32 = 37;
pub const KVM_CAP_IMMEDIATE_EXIT: u32 = 136;

pub const KVM_CPUID_FLAG_SIGNIFCANT_INDEX: u32 = 1 << 0;

pub const KVM_MP_STATE_RUNNABLE: u32 = 0;
pub const KVM_MP_STATE_UNINITIALIZED: u32 = 1;
pub const KVM_MP_STATE_INIT_RECEIVED: u32 = 2;
pub const KVM_MP_STATE_HALTED: u32 = 3;
pub const KVM_MP_STATE_SIPI_RECEIVED: u32 = 4;

pub const max_cpuid_entries: usize = 256;
pub const max_io_payload: usize = 4096;

pub const Error = common.Error || error{
    ApiVersionMismatch,
    KvmCapabilityMissing,
    CpuidTooLarge,
    UnsupportedVcpuCount,
    InvalidVcpuIndex,
    CpuidTopologyMissing,
    MalformedCpuidTopology,
    KvmRunTooSmall,
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
    pub const immediate_exit = common.RunLayout.immediate_exit;
    pub const exit_reason = common.RunLayout.exit_reason;
    pub const io_direction: usize = 32;
    pub const io_size: usize = 33;
    pub const io_port: usize = 34;
    pub const io_count: usize = 36;
    pub const io_data_offset: usize = 40;
    pub const io_envelope_end: usize = 48;
    pub const mmio_phys_addr = common.RunLayout.mmio_phys_addr;
    pub const mmio_data = common.RunLayout.mmio_data;
    pub const mmio_len = common.RunLayout.mmio_len;
    pub const mmio_is_write = common.RunLayout.mmio_is_write;
    pub const mmio_end: usize = 53;
    pub const system_event_type = common.RunLayout.system_event_type;
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

pub const UserspaceMemoryRegion = common.UserspaceMemoryRegion;

pub const IrqLevel = common.IrqLevel;

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

pub const MpState = extern struct {
    mp_state: u32,
};

pub fn openDevKvm() Error!std.c.fd_t {
    return common.openDevKvm(.{ .close_on_exec = true });
}

pub fn ioctl(fd: std.c.fd_t, request: u32, arg: usize, op: []const u8) Error!usize {
    return common.ioctl(fd, request, arg, op);
}

pub fn checkApiVersion(kvm_fd: std.c.fd_t) Error!void {
    if (try ioctl(kvm_fd, KVM_GET_API_VERSION, 0, "KVM_GET_API_VERSION") != KVM_API_VERSION) {
        return error.ApiVersionMismatch;
    }
}

pub fn requireExtension(kvm_fd: std.c.fd_t, capability: u32, name: []const u8) Error!void {
    if (try checkExtension(kvm_fd, capability) == 0) {
        std.log.err("required KVM capability missing: {s} ({d})", .{ name, capability });
        return error.KvmCapabilityMissing;
    }
}

pub fn checkExtension(kvm_fd: std.c.fd_t, capability: u32) Error!usize {
    return ioctl(kvm_fd, KVM_CHECK_EXTENSION, capability, "KVM_CHECK_EXTENSION");
}

pub fn getSupportedCpuid(kvm_fd: std.c.fd_t) Error!Cpuid {
    var cpuid = Cpuid{};
    _ = try ioctl(kvm_fd, KVM_GET_SUPPORTED_CPUID, @intFromPtr(&cpuid), "KVM_GET_SUPPORTED_CPUID");
    if (cpuid.nent > max_cpuid_entries) return error.CpuidTooLarge;
    return cpuid;
}

/// Derive a per-vCPU topology from KVM's supported CPUID table without
/// constraining its feature bits. KVM deliberately returns topology leaves
/// without subleaf 1; adding that subleaf is what makes leaf 0xB/0x1F valid.
/// The later product CPU profile remains responsible for the feature allowlist.
pub fn normalizeSupportedCpuidTopology(
    supported: Cpuid,
    vcpu_count: topology.VcpuCount,
    vcpu_index: topology.VcpuIndex,
) Error!Cpuid {
    try topology.validateVcpuCount(vcpu_count);
    if (vcpu_index >= vcpu_count) return error.InvalidVcpuIndex;

    var result = supported;
    const entry_count = std.math.cast(usize, result.nent) orelse return error.CpuidTooLarge;
    if (entry_count > result.entries.len) return error.CpuidTooLarge;

    const basic_index = try uniqueCpuidEntry(&result, 0);
    const leaf1_index = try uniqueCpuidEntry(&result, 1);
    const basic = if (basic_index) |index| &result.entries[index] else return error.CpuidTopologyMissing;
    const leaf1 = if (leaf1_index) |index| &result.entries[index] else return error.CpuidTopologyMissing;
    if (basic.index != 0 or basic.flags != 0 or leaf1.index != 0 or leaf1.flags != 0) {
        return error.MalformedCpuidTopology;
    }

    const count: u32 = vcpu_count;
    const apic_id: u32 = vcpu_index;
    leaf1.ebx = (leaf1.ebx & 0x0000_ffff) |
        ((count & 0xff) << 16) |
        ((apic_id & 0xff) << 24);
    if (vcpu_count > 1) {
        leaf1.edx |= 1 << 28; // HTT: more than one logical CPU in the package.
    } else {
        leaf1.edx &= ~@as(u32, 1 << 28);
    }

    const maximum_basic_function = basic.eax;
    var topology_leaf_count: u8 = 0;
    inline for ([_]u32{ 0x0b, 0x1f }) |function| {
        const advertised = maximum_basic_function >= function;
        const present = hasCpuidFunction(&result, function);
        if (present and !advertised) return error.MalformedCpuidTopology;
        if (present) {
            try normalizeTopologyLeaf(&result, function, vcpu_count, vcpu_index);
            topology_leaf_count += 1;
        }
    }
    if (topology_leaf_count == 0) return error.CpuidTopologyMissing;
    return result;
}

fn uniqueCpuidEntry(cpuid: *const Cpuid, function: u32) Error!?usize {
    const count = std.math.cast(usize, cpuid.nent) orelse return error.CpuidTooLarge;
    if (count > cpuid.entries.len) return error.CpuidTooLarge;

    var found: ?usize = null;
    for (cpuid.entries[0..count], 0..) |entry, index| {
        if (entry.function != function) continue;
        if (found != null) return error.MalformedCpuidTopology;
        found = index;
    }
    return found;
}

fn hasCpuidFunction(cpuid: *const Cpuid, function: u32) bool {
    const count: usize = @intCast(cpuid.nent);
    for (cpuid.entries[0..count]) |entry| {
        if (entry.function == function) return true;
    }
    return false;
}

fn normalizeTopologyLeaf(
    cpuid: *Cpuid,
    function: u32,
    vcpu_count: topology.VcpuCount,
    vcpu_index: topology.VcpuIndex,
) Error!void {
    var count = std.math.cast(usize, cpuid.nent) orelse return error.CpuidTooLarge;
    if (count > cpuid.entries.len) return error.CpuidTooLarge;

    var topology_entries: usize = 0;
    var maximum_index: u32 = 0;
    var has_index_zero = false;
    var has_index_one = false;
    for (cpuid.entries[0..count], 0..) |entry, index| {
        if (entry.function != function) continue;
        if (entry.flags != KVM_CPUID_FLAG_SIGNIFCANT_INDEX or entry.index > std.math.maxInt(u8)) {
            return error.MalformedCpuidTopology;
        }
        for (cpuid.entries[0..index]) |previous| {
            if (previous.function == function and previous.index == entry.index) {
                return error.MalformedCpuidTopology;
            }
        }
        topology_entries += 1;
        maximum_index = @max(maximum_index, entry.index);
        has_index_zero = has_index_zero or entry.index == 0;
        has_index_one = has_index_one or entry.index == 1;
    }
    if (!has_index_zero or topology_entries != @as(usize, @intCast(maximum_index)) + 1) {
        return error.MalformedCpuidTopology;
    }

    // KVM_GET_SUPPORTED_CPUID intentionally emits only index 0 for these
    // leaves. A valid topology is indicated by the presence of index 1.
    if (!has_index_one) {
        if (topology_entries != 1 or count == cpuid.entries.len) return error.CpuidTooLarge;
        cpuid.entries[count] = .{
            .function = function,
            .index = 1,
            .flags = KVM_CPUID_FLAG_SIGNIFCANT_INDEX,
        };
        count += 1;
        cpuid.nent = @intCast(count);
    }

    const package_shift = topologyShift(vcpu_count);
    for (cpuid.entries[0..count]) |*entry| {
        if (entry.function != function) continue;
        switch (entry.index) {
            0 => {
                entry.eax = 0; // One hardware thread per core.
                entry.ebx = 1;
                entry.ecx = 1 << 8; // Level 0, SMT type.
                entry.edx = vcpu_index;
            },
            1 => {
                entry.eax = package_shift;
                entry.ebx = vcpu_count;
                entry.ecx = (2 << 8) | 1; // Level 1, core type.
                entry.edx = vcpu_index;
            },
            else => {
                entry.eax = 0;
                entry.ebx = 0;
                entry.ecx = entry.index;
                entry.edx = vcpu_index;
            },
        }
    }
}

fn topologyShift(vcpu_count: topology.VcpuCount) u32 {
    var remaining = vcpu_count - 1;
    var shift: u32 = 0;
    while (remaining != 0) : (remaining >>= 1) shift += 1;
    return shift;
}

pub fn getMpState(vcpu_fd: std.c.fd_t) Error!MpState {
    var state = MpState{ .mp_state = KVM_MP_STATE_RUNNABLE };
    _ = try ioctl(vcpu_fd, KVM_GET_MP_STATE, @intFromPtr(&state), "KVM_GET_MP_STATE");
    return state;
}

pub fn setIrq(vm_fd: std.c.fd_t, gsi: u32, level: bool) Error!void {
    return common.setIrqLine(vm_fd, gsi, level);
}

pub const RunResult = enum {
    completed,
    interrupted,
    /// An x86 AP remains non-runnable until the BSP sends INIT/SIPI. KVM
    /// reports that reset state as EAGAIN rather than blocking KVM_RUN.
    not_runnable,
};

fn immediateExitFlag(run: []u8) Error!*std.atomic.Value(u8) {
    if (run.len <= RunLayout.immediate_exit) return error.KvmRunTooSmall;
    return @ptrCast(&run[RunLayout.immediate_exit]);
}

/// Request that the next KVM_RUN entry return with EINTR. The mapped byte is
/// shared by the vCPU and coordinator threads, so every userspace access must
/// remain atomic even though the Linux UAPI exposes it as a plain u8.
pub fn requestImmediateExit(run: []u8) Error!void {
    (try immediateExitFlag(run)).store(1, .release);
}

pub fn consumeImmediateExit(run: []u8) Error!bool {
    return (try immediateExitFlag(run)).swap(0, .acq_rel) != 0;
}

/// Complete the current PIO/MMIO exit without allowing the vCPU to execute the
/// next guest instruction. KVM requires one re-entry after userspace fills a
/// read response, even when another thread has already requested an exit.
pub fn completePendingExit(vcpu_fd: std.c.fd_t, run: []u8) Error!void {
    try requestImmediateExit(run);
    defer _ = consumeImmediateExit(run) catch {};

    const rc = linux.ioctl(vcpu_fd, KVM_RUN, 0);
    switch (linux.errno(rc)) {
        .SUCCESS, .INTR => {},
        else => |err| {
            std.log.err("KVM_RUN immediate_exit failed: {s}", .{@tagName(err)});
            return error.KvmIoctlFailed;
        },
    }
}

pub fn runVcpu(vcpu_fd: std.c.fd_t) Error!RunResult {
    const rc = linux.ioctl(vcpu_fd, KVM_RUN, 0);
    switch (linux.errno(rc)) {
        .SUCCESS => return .completed,
        .INTR => return .interrupted,
        .AGAIN => return .not_runnable,
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
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(MpState));
    try std.testing.expectEqual(@as(u32, 0x8004_ae98), KVM_GET_MP_STATE);
    try std.testing.expectEqual(@as(u32, 136), KVM_CAP_IMMEDIATE_EXIT);
    try std.testing.expectEqual(@as(usize, 1), RunLayout.immediate_exit);
}

fn makeTopologyCpuid() Cpuid {
    var cpuid = Cpuid{ .nent = 4 };
    cpuid.entries[0] = .{ .function = 0, .eax = 0x1f };
    cpuid.entries[1] = .{ .function = 1, .ebx = 0x0000_1234, .edx = 1 << 28 };
    cpuid.entries[2] = .{ .function = 0x0b, .flags = KVM_CPUID_FLAG_SIGNIFCANT_INDEX };
    cpuid.entries[3] = .{ .function = 0x1f, .flags = KVM_CPUID_FLAG_SIGNIFCANT_INDEX };
    return cpuid;
}

fn testCpuidEntry(cpuid: *const Cpuid, function: u32, index: u32) *const CpuidEntry {
    for (cpuid.entries[0..@intCast(cpuid.nent)]) |*entry| {
        if (entry.function == function and entry.index == index) return entry;
    }
    unreachable;
}

test "supported CPUID topology normalizes one two and eight vCPUs" {
    const supported = makeTopologyCpuid();
    for ([_]topology.VcpuCount{ 1, 2, 8 }) |vcpu_count| {
        var vcpu_index: topology.VcpuIndex = 0;
        while (vcpu_index < vcpu_count) : (vcpu_index += 1) {
            const cpuid = try normalizeSupportedCpuidTopology(supported, vcpu_count, vcpu_index);
            try std.testing.expectEqual(@as(u32, 6), cpuid.nent);

            const leaf1 = testCpuidEntry(&cpuid, 1, 0);
            try std.testing.expectEqual(@as(u32, 0x1234), leaf1.ebx & 0xffff);
            try std.testing.expectEqual(vcpu_count, (leaf1.ebx >> 16) & 0xff);
            try std.testing.expectEqual(vcpu_index, leaf1.ebx >> 24);
            try std.testing.expectEqual(vcpu_count > 1, leaf1.edx & (1 << 28) != 0);

            inline for ([_]u32{ 0x0b, 0x1f }) |function| {
                const smt = testCpuidEntry(&cpuid, function, 0);
                try std.testing.expectEqual(@as(u32, 0), smt.eax);
                try std.testing.expectEqual(@as(u32, 1), smt.ebx);
                try std.testing.expectEqual(@as(u32, 1), (smt.ecx >> 8) & 0xff);
                try std.testing.expectEqual(vcpu_index, smt.edx);

                const core = testCpuidEntry(&cpuid, function, 1);
                try std.testing.expectEqual(topologyShift(vcpu_count), core.eax);
                try std.testing.expectEqual(vcpu_count, core.ebx);
                try std.testing.expectEqual(@as(u32, 2), (core.ecx >> 8) & 0xff);
                try std.testing.expectEqual(vcpu_index, core.edx);
            }
        }
    }
}

test "supported CPUID topology rejects malformed and insufficient tables" {
    var cpuid = makeTopologyCpuid();
    try std.testing.expectError(error.UnsupportedVcpuCount, normalizeSupportedCpuidTopology(cpuid, 0, 0));
    try std.testing.expectError(error.InvalidVcpuIndex, normalizeSupportedCpuidTopology(cpuid, 2, 2));

    cpuid.nent = 2;
    try std.testing.expectError(error.CpuidTopologyMissing, normalizeSupportedCpuidTopology(cpuid, 2, 0));

    cpuid = makeTopologyCpuid();
    cpuid.entries[2].flags = 0;
    try std.testing.expectError(error.MalformedCpuidTopology, normalizeSupportedCpuidTopology(cpuid, 2, 0));

    cpuid = makeTopologyCpuid();
    cpuid.entries[3].function = 0x0b;
    cpuid.entries[3].index = 2;
    try std.testing.expectError(error.MalformedCpuidTopology, normalizeSupportedCpuidTopology(cpuid, 2, 0));
}

test "complete pending exit rejects an absent kvm_run header" {
    var run: [1]u8 = .{0};
    try std.testing.expectError(error.KvmRunTooSmall, completePendingExit(-1, &run));
}

test "immediate exit requests use one atomic consume" {
    var run: [RunLayout.mmio_end]u8 = @splat(0);
    try std.testing.expect(!(try consumeImmediateExit(&run)));
    try requestImmediateExit(&run);
    try std.testing.expect(try consumeImmediateExit(&run));
    try std.testing.expect(!(try consumeImmediateExit(&run)));
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
