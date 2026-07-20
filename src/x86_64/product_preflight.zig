//! Non-destructive host preflight for the approved x86 product profile.

const std = @import("std");
const kvm = @import("../kvm/x86_64.zig");
const cpu_profile = @import("cpu_profile.zig");
const host_evidence = @import("host_evidence.zig");

const msr_capacity = 256;

pub const HostProfile = struct {
    capabilities: host_evidence.Capabilities,
    profile_capabilities: [cpu_profile.required_capabilities.len]cpu_profile.CapabilityFact,
    supported_cpuid: kvm.Cpuid,
    cpuid_evidence: host_evidence.CpuidEvidence,
    msr_list: kvm.MsrList(msr_capacity),
    xsave_bytes: u32,

    pub fn capabilityAvailable(self: *const HostProfile, id: u32) bool {
        for (self.profile_capabilities) |fact| if (fact.id == id) return fact.value != 0;
        return false;
    }

    pub fn facts(self: *const HostProfile, tsc_khz: u64, has_tsc_offset: bool) !cpu_profile.HostFacts {
        return .{
            .api_version = kvm.KVM_API_VERSION,
            .vendor = self.cpuid_evidence.vendor,
            .max_vcpus = std.math.cast(u32, self.capabilities.nrVcpus()) orelse return error.VcpuCapacityTooLarge,
            .capabilities = &self.profile_capabilities,
            .msr_indices = try kvm.msrIndices(msr_capacity, &self.msr_list),
            .supported_cpuid = self.supported_cpuid.entries[0..self.supported_cpuid.nent],
            .xsave_bytes = self.xsave_bytes,
            .tsc_khz = tsc_khz,
            .has_tsc_offset = has_tsc_offset,
        };
    }
};

pub fn collectHostProfile(kvm_fd: std.c.fd_t) !HostProfile {
    var result: HostProfile = undefined;
    for (cpu_profile.required_capabilities, &result.profile_capabilities) |required, *fact| {
        const value = try kvm.checkExtension(kvm_fd, required.id);
        fact.* = .{ .id = required.id, .value = std.math.cast(u32, value) orelse return error.CapabilityValueTooLarge };
    }
    result.capabilities = try host_evidence.collectCapabilities(kvm_fd);
    result.supported_cpuid = try kvm.getSupportedCpuid(kvm_fd);
    result.cpuid_evidence = try host_evidence.collectCpuid(&result.supported_cpuid);
    result.msr_list = .{};
    _ = try kvm.getMsrIndexList(
        kvm_fd,
        kvm.KVM_GET_MSR_INDEX_LIST,
        msr_capacity,
        &result.msr_list,
        "KVM_GET_MSR_INDEX_LIST product profile",
    );
    result.xsave_bytes = try kvm.xsaveSize(kvm_fd);
    return result;
}

/// Prove the complete approved profile before product setup downloads or
/// mutates anything. The fresh runner repeats these checks when it constructs
/// the real VM, keeping this preflight an ordering guarantee rather than the
/// only security boundary.
pub fn requireCompatible(kvm_fd: std.c.fd_t, requested_vcpus: u8) !void {
    const profile = try collectHostProfile(kvm_fd);

    const vm_fd: std.c.fd_t = @intCast(try kvm.ioctl(kvm_fd, kvm.KVM_CREATE_VM, 0, "KVM_CREATE_VM product preflight"));
    defer _ = std.c.close(vm_fd);
    _ = try kvm.ioctl(vm_fd, kvm.KVM_SET_TSC_KHZ, cpu_profile.guest_tsc_khz, "KVM_SET_TSC_KHZ product preflight");
    const vcpu_fd: std.c.fd_t = @intCast(try kvm.ioctl(vm_fd, kvm.KVM_CREATE_VCPU, 0, "KVM_CREATE_VCPU product preflight"));
    defer _ = std.c.close(vcpu_fd);

    const facts = try profile.facts(
        try kvm.ioctl(vcpu_fd, kvm.KVM_GET_TSC_KHZ, 0, "KVM_GET_TSC_KHZ product preflight"),
        try kvm.hasTscOffset(vcpu_fd),
    );
    if (cpu_profile.compatibility(facts, requested_vcpus) != null) return error.IncompatibleCpuProfile;
}
