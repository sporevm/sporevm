//! Non-destructive host preflight for the approved x86 product profile.

const std = @import("std");
const kvm = @import("../kvm/x86_64.zig");
const cpu_profile = @import("cpu_profile.zig");
const host_evidence = @import("host_evidence.zig");

const msr_capacity = 256;

/// Prove the complete approved profile before product setup downloads or
/// mutates anything. The fresh runner repeats these checks when it constructs
/// the real VM, keeping this preflight an ordering guarantee rather than the
/// only security boundary.
pub fn requireCompatible(kvm_fd: std.c.fd_t, requested_vcpus: u8) !void {
    var profile_capabilities: [cpu_profile.required_capabilities.len]cpu_profile.CapabilityFact = undefined;
    for (cpu_profile.required_capabilities, &profile_capabilities) |required, *fact| {
        const value = try kvm.checkExtension(kvm_fd, required.id);
        fact.* = .{ .id = required.id, .value = std.math.cast(u32, value) orelse return error.CapabilityValueTooLarge };
    }

    const capabilities = try host_evidence.collectCapabilities(kvm_fd);
    const supported_cpuid = try kvm.getSupportedCpuid(kvm_fd);
    const cpuid_evidence = try host_evidence.collectCpuid(&supported_cpuid);
    var msr_list = kvm.MsrList(msr_capacity){};
    const msr_indices = try kvm.getMsrIndexList(kvm_fd, kvm.KVM_GET_MSR_INDEX_LIST, msr_capacity, &msr_list, "KVM_GET_MSR_INDEX_LIST product preflight");
    const xsave2_bytes = try kvm.checkExtension(kvm_fd, kvm.KVM_CAP_XSAVE2);
    const xsave_bytes = if (xsave2_bytes == 0)
        @as(u32, @sizeOf(kvm.Xsave))
    else
        std.math.cast(u32, xsave2_bytes) orelse return error.XsaveSizeTooLarge;

    const vm_fd: std.c.fd_t = @intCast(try kvm.ioctl(kvm_fd, kvm.KVM_CREATE_VM, 0, "KVM_CREATE_VM product preflight"));
    defer _ = std.c.close(vm_fd);
    _ = try kvm.ioctl(vm_fd, kvm.KVM_SET_TSC_KHZ, cpu_profile.guest_tsc_khz, "KVM_SET_TSC_KHZ product preflight");
    const vcpu_fd: std.c.fd_t = @intCast(try kvm.ioctl(vm_fd, kvm.KVM_CREATE_VCPU, 0, "KVM_CREATE_VCPU product preflight"));
    defer _ = std.c.close(vcpu_fd);

    const facts = cpu_profile.HostFacts{
        .api_version = kvm.KVM_API_VERSION,
        .vendor = cpuid_evidence.vendor,
        .max_vcpus = std.math.cast(u32, capabilities.nrVcpus()) orelse return error.VcpuCapacityTooLarge,
        .capabilities = &profile_capabilities,
        .msr_indices = msr_indices,
        .supported_cpuid = supported_cpuid.entries[0..supported_cpuid.nent],
        .xsave_bytes = xsave_bytes,
        .tsc_khz = try kvm.ioctl(vcpu_fd, kvm.KVM_GET_TSC_KHZ, 0, "KVM_GET_TSC_KHZ product preflight"),
        .has_tsc_offset = try kvm.hasTscOffset(vcpu_fd),
    };
    if (cpu_profile.compatibility(facts, requested_vcpus) != null) return error.IncompatibleCpuProfile;
}
