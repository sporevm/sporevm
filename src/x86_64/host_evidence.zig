//! Bounded host capability and CPUID evidence for x86 KVM bring-up.

const std = @import("std");
const kvm = @import("../kvm/x86_64.zig");

pub const CapabilityDescriptor = struct {
    name: []const u8,
    id: u32,
};

pub const required_capabilities = [_]CapabilityDescriptor{
    .{ .name = "user_memory", .id = kvm.KVM_CAP_USER_MEMORY },
    .{ .name = "irqchip", .id = kvm.KVM_CAP_IRQCHIP },
    .{ .name = "set_tss_addr", .id = kvm.KVM_CAP_SET_TSS_ADDR },
    .{ .name = "identity_map", .id = kvm.KVM_CAP_SET_IDENTITY_MAP_ADDR },
    .{ .name = "pit2", .id = kvm.KVM_CAP_PIT2 },
    .{ .name = "ext_cpuid", .id = kvm.KVM_CAP_EXT_CPUID },
    .{ .name = "mp_state", .id = kvm.KVM_CAP_MP_STATE },
    .{ .name = "immediate_exit", .id = kvm.KVM_CAP_IMMEDIATE_EXIT },
    .{ .name = "nr_vcpus", .id = kvm.KVM_CAP_NR_VCPUS },
};

const nr_vcpus_index = required_capabilities.len - 1;

pub const Capabilities = struct {
    api_version: usize,
    values: [required_capabilities.len]usize,

    pub fn nrVcpus(self: Capabilities) usize {
        return self.values[nr_vcpus_index];
    }
};

pub fn collectCapabilities(kvm_fd: std.c.fd_t) !Capabilities {
    const api_version = try kvm.ioctl(kvm_fd, kvm.KVM_GET_API_VERSION, 0, "KVM_GET_API_VERSION");
    if (api_version != kvm.KVM_API_VERSION) return error.ApiVersionMismatch;

    var result = Capabilities{ .api_version = api_version, .values = @splat(0) };
    for (required_capabilities, 0..) |descriptor, index| {
        result.values[index] = try kvm.checkExtension(kvm_fd, descriptor.id);
        if (result.values[index] == 0) {
            std.log.err("required KVM capability missing: {s} ({d})", .{ descriptor.name, descriptor.id });
            return error.KvmCapabilityMissing;
        }
    }
    return result;
}

pub fn formatCapabilities(buffer: []u8, capabilities: Capabilities) ![]const u8 {
    var used: usize = 0;
    const prefix = try std.fmt.bufPrint(buffer, "capabilities api={d}", .{capabilities.api_version});
    used += prefix.len;
    for (required_capabilities, capabilities.values) |descriptor, value| {
        const field = try std.fmt.bufPrint(buffer[used..], " {s}={d}", .{ descriptor.name, value });
        used += field.len;
    }
    return buffer[0..used];
}

pub const CpuidEvidence = struct {
    nent: u32,
    vendor: [12]u8,
    leaf_1: bool,
    leaf_0b: bool,
    leaf_1f: bool,
    x2apic: bool,
};

pub fn collectCpuid(cpuid: *const kvm.Cpuid) !CpuidEvidence {
    const count = std.math.cast(usize, cpuid.nent) orelse return error.CpuidTooLarge;
    if (count > cpuid.entries.len) return error.CpuidTooLarge;

    var leaf0: ?kvm.CpuidEntry = null;
    var leaf1: ?kvm.CpuidEntry = null;
    var leaf_0b = false;
    var leaf_1f = false;
    for (cpuid.entries[0..count]) |entry| {
        switch (entry.function) {
            0 => if (entry.index == 0) {
                if (leaf0 != null) return error.MalformedCpuidTopology;
                leaf0 = entry;
            },
            1 => if (entry.index == 0) {
                if (leaf1 != null) return error.MalformedCpuidTopology;
                leaf1 = entry;
            },
            0x0b => leaf_0b = true,
            0x1f => leaf_1f = true,
            else => {},
        }
    }

    const basic = leaf0 orelse return error.CpuidTopologyMissing;
    const features = leaf1 orelse return error.CpuidTopologyMissing;
    if (basic.flags != 0 or features.flags != 0 or basic.eax < 1) return error.MalformedCpuidEvidence;
    var vendor: [12]u8 = undefined;
    std.mem.writeInt(u32, vendor[0..4], basic.ebx, .little);
    std.mem.writeInt(u32, vendor[4..8], basic.edx, .little);
    std.mem.writeInt(u32, vendor[8..12], basic.ecx, .little);
    for (vendor) |byte| {
        if (byte < 0x20 or byte > 0x7e) return error.MalformedCpuidEvidence;
    }
    return .{
        .nent = cpuid.nent,
        .vendor = vendor,
        .leaf_1 = true,
        .leaf_0b = leaf_0b,
        .leaf_1f = leaf_1f,
        .x2apic = features.ecx & (1 << 21) != 0,
    };
}

pub fn formatCpuid(buffer: []u8, evidence: CpuidEvidence) ![]const u8 {
    return std.fmt.bufPrint(buffer, "cpuid nent={d} vendor={s} leaf_1={} leaf_0b={} leaf_1f={} x2apic={}", .{
        evidence.nent,
        &evidence.vendor,
        evidence.leaf_1,
        evidence.leaf_0b,
        evidence.leaf_1f,
        evidence.x2apic,
    });
}

test "required capability descriptors define stable evidence order" {
    const expected_names = [_][]const u8{
        "user_memory",
        "irqchip",
        "set_tss_addr",
        "identity_map",
        "pit2",
        "ext_cpuid",
        "mp_state",
        "immediate_exit",
        "nr_vcpus",
    };
    for (required_capabilities, expected_names) |descriptor, expected| {
        try std.testing.expectEqualStrings(expected, descriptor.name);
    }

    var values: [required_capabilities.len]usize = @splat(1);
    values[nr_vcpus_index] = 96;
    const capabilities = Capabilities{ .api_version = 12, .values = values };
    try std.testing.expectEqual(@as(usize, 96), capabilities.nrVcpus());
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "capabilities api=12 user_memory=1 irqchip=1 set_tss_addr=1 identity_map=1 pit2=1 ext_cpuid=1 mp_state=1 immediate_exit=1 nr_vcpus=96",
        try formatCapabilities(&buffer, capabilities),
    );
}

test "CPUID evidence formats raw vendor and required topology facts" {
    var cpuid = kvm.Cpuid{ .nent = 4 };
    cpuid.entries[0] = .{ .function = 0, .eax = 0x1f, .ebx = 0x756e6547, .edx = 0x49656e69, .ecx = 0x6c65746e };
    cpuid.entries[1] = .{ .function = 1, .ecx = 1 << 21 };
    cpuid.entries[2] = .{ .function = 0x0b };
    cpuid.entries[3] = .{ .function = 0x1f };
    const evidence = try collectCpuid(&cpuid);
    var buffer: [160]u8 = undefined;
    try std.testing.expectEqualStrings(
        "cpuid nent=4 vendor=GenuineIntel leaf_1=true leaf_0b=true leaf_1f=true x2apic=true",
        try formatCpuid(&buffer, evidence),
    );

    cpuid.entries[0].ebx = 0;
    try std.testing.expectError(error.MalformedCpuidEvidence, collectCpuid(&cpuid));
    cpuid.entries[0].ebx = 0x756e6547;
    cpuid.nent = 1;
    try std.testing.expectError(error.CpuidTopologyMissing, collectCpuid(&cpuid));
}
