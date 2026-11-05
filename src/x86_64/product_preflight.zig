//! The one check of whether this KVM host can provide the approved x86
//! profile. Command entry points run it before any download or disk work, and
//! the fresh runner runs it again before it creates the real VM.

const std = @import("std");
const kvm = @import("../kvm/x86_64.zig");
const cpu_profile = @import("cpu_profile.zig");

const msr_capacity = 256;

/// Fail with `error.IncompatibleCpuProfile`, logging which host fact differs,
/// unless the host matches the approved profile. Other errors mean the probe
/// itself failed.
pub fn require(kvm_fd: std.c.fd_t, requested_vcpus: u8) !void {
    if (try incompatibility(kvm_fd, requested_vcpus)) |failure| {
        std.log.warn("x86 KVM host does not match CPU profile {s}: {f}", .{ cpu_profile.profile_name, failure });
        return error.IncompatibleCpuProfile;
    }
}

/// Judge the host-wide facts before the probe VM, so a host without TSC
/// control reports the missing capability rather than a failed ioctl.
fn incompatibility(kvm_fd: std.c.fd_t, requested_vcpus: u8) !?cpu_profile.Incompatibility {
    var capabilities: [cpu_profile.required_capabilities.len]cpu_profile.CapabilityFact = undefined;
    for (cpu_profile.required_capabilities, &capabilities) |required, *fact| {
        const value = try kvm.checkExtension(kvm_fd, required.id);
        fact.* = .{ .id = required.id, .value = std.math.cast(u32, value) orelse return error.CapabilityValueTooLarge };
    }
    const supported_cpuid = try kvm.getSupportedCpuid(kvm_fd);
    var msr_list: kvm.MsrList(msr_capacity) = .{};
    var facts = cpu_profile.HostFacts{
        .api_version = std.math.cast(u32, try kvm.ioctl(kvm_fd, kvm.KVM_GET_API_VERSION, 0, "KVM_GET_API_VERSION")) orelse return error.ApiVersionMismatch,
        .vendor = cpuVendor(&supported_cpuid),
        .max_vcpus = std.math.cast(u32, try kvm.checkExtension(kvm_fd, kvm.KVM_CAP_NR_VCPUS)) orelse return error.VcpuCapacityTooLarge,
        .capabilities = &capabilities,
        .msr_indices = try kvm.getMsrIndexList(kvm_fd, kvm.KVM_GET_MSR_INDEX_LIST, msr_capacity, &msr_list, "KVM_GET_MSR_INDEX_LIST"),
        .supported_cpuid = supported_cpuid.entries[0..supported_cpuid.nent],
        .xsave_bytes = try kvm.xsaveSize(kvm_fd),
        .tsc_khz = cpu_profile.guest_tsc_khz,
        .has_tsc_offset = true,
    };
    if (cpu_profile.compatibility(facts, requested_vcpus)) |failure| return failure;

    const vm_fd: std.c.fd_t = @intCast(try kvm.ioctl(kvm_fd, kvm.KVM_CREATE_VM, 0, "KVM_CREATE_VM profile check"));
    defer _ = std.c.close(vm_fd);
    _ = try kvm.ioctl(vm_fd, kvm.KVM_SET_TSC_KHZ, cpu_profile.guest_tsc_khz, "KVM_SET_TSC_KHZ profile check");
    const vcpu_fd: std.c.fd_t = @intCast(try kvm.ioctl(vm_fd, kvm.KVM_CREATE_VCPU, 0, "KVM_CREATE_VCPU profile check"));
    defer _ = std.c.close(vcpu_fd);
    facts.tsc_khz = try kvm.ioctl(vcpu_fd, kvm.KVM_GET_TSC_KHZ, 0, "KVM_GET_TSC_KHZ profile check");
    facts.has_tsc_offset = try kvm.hasTscOffset(vcpu_fd);
    return cpu_profile.compatibility(facts, requested_vcpus);
}

fn cpuVendor(cpuid: *const kvm.Cpuid) [12]u8 {
    var vendor: [12]u8 = @splat(0);
    for (cpuid.entries[0..cpuid.nent]) |entry| {
        if (entry.function != 0 or entry.index != 0) continue;
        std.mem.writeInt(u32, vendor[0..4], entry.ebx, .little);
        std.mem.writeInt(u32, vendor[4..8], entry.edx, .little);
        std.mem.writeInt(u32, vendor[8..12], entry.ecx, .little);
        break;
    }
    return vendor;
}
