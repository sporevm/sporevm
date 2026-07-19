//! Pure audit contract for the candidate x86 CPU and clock profile.
//!
//! Stage 1.3 freezes the bounded questions that Slice 0b must answer. It does
//! not export a partially populated profile or a caller-asserted host verdict.

const std = @import("std");
const kvm = @import("../kvm/x86_64.zig");
const topology = @import("../topology.zig");

pub const CandidateStatus = enum {
    pending_stage0b,
    approved_same_host,
};

pub const candidate_status: CandidateStatus = .approved_same_host;

pub const CpuidIndexPolicy = enum {
    fixed_zero,
    significant,
};

pub const CpuidDecision = struct {
    function: u32,
    index: u32,
    index_policy: CpuidIndexPolicy,
};

/// Ordered selectors whose fixed values and masks require Slice 0b evidence.
/// Presence here is an audit obligation, not permission to expose the leaf.
/// Unlisted selectors remain excluded unless a reviewed change adds them.
pub const cpuid_decision_inventory = [_]CpuidDecision{
    .{ .function = 0x0000_0000, .index = 0, .index_policy = .fixed_zero },
    .{ .function = 0x0000_0001, .index = 0, .index_policy = .fixed_zero },
    .{ .function = 0x0000_000b, .index = 0, .index_policy = .significant },
    .{ .function = 0x0000_000b, .index = 1, .index_policy = .significant },
    .{ .function = 0x0000_000d, .index = 0, .index_policy = .significant },
    .{ .function = 0x0000_000d, .index = 1, .index_policy = .significant },
    .{ .function = 0x0000_000d, .index = 2, .index_policy = .significant },
    .{ .function = 0x0000_001f, .index = 0, .index_policy = .significant },
    .{ .function = 0x0000_001f, .index = 1, .index_policy = .significant },
    .{ .function = 0x4000_0000, .index = 0, .index_policy = .fixed_zero },
    .{ .function = 0x4000_0001, .index = 0, .index_policy = .fixed_zero },
    .{ .function = 0x8000_0000, .index = 0, .index_policy = .fixed_zero },
    .{ .function = 0x8000_0001, .index = 0, .index_policy = .fixed_zero },
    .{ .function = 0x8000_0007, .index = 0, .index_policy = .fixed_zero },
    .{ .function = 0x8000_0008, .index = 0, .index_policy = .fixed_zero },
};

pub const CpuidRegister = enum {
    eax,
    ebx,
    ecx,
    edx,
};

pub const ForbiddenCpuidBit = struct {
    function: u32,
    index: u32,
    register: CpuidRegister,
    bit: u5,
    name: []const u8,
};

/// SporeVM does not serialize nested-virtualization state.
pub const forbidden_cpuid_bits = [_]ForbiddenCpuidBit{
    .{ .function = 0x0000_0001, .index = 0, .register = .ecx, .bit = 5, .name = "vmx" },
    .{ .function = 0x8000_0001, .index = 0, .register = .ecx, .bit = 2, .name = "svm" },
};

pub const CapabilityAudit = struct {
    id: u32,
    name: []const u8,
};

/// Linux KVM capability IDs whose exact required-value policy belongs to 0b.
pub const capability_audit_inventory = [_]CapabilityAudit{
    .{ .id = 8, .name = "clocksource" },
    .{ .id = 39, .name = "adjust_clock" },
    .{ .id = 55, .name = "xsave" },
    .{ .id = 56, .name = "xcrs" },
    .{ .id = 59, .name = "async_pf" },
    .{ .id = 60, .name = "tsc_control" },
    .{ .id = 61, .name = "get_tsc_khz" },
    .{ .id = 72, .name = "tsc_deadline_timer" },
    .{ .id = 76, .name = "kvmclock_ctrl" },
    .{ .id = 129, .name = "x2apic_api" },
    .{ .id = 183, .name = "async_pf_int" },
    .{ .id = 187, .name = "steal_time" },
    .{ .id = 190, .name = "enforce_pv_feature_cpuid" },
    .{ .id = 208, .name = "xsave2" },
    .{ .id = 214, .name = "vm_tsc_control" },
};

pub const xsave_legacy_and_header_bytes: u32 = 512 + 64;
pub const kvm_legacy_xsave_area_bytes: u32 = 4096;

pub const MsrAudit = struct {
    index: u32,
    name: []const u8,
};

/// Inclusion records an audit obligation, not a required/default disposition.
pub const msr_audit_inventory = [_]MsrAudit{
    .{ .index = 0x0000_0010, .name = "MSR_IA32_TSC" },
    .{ .index = 0x0000_0011, .name = "MSR_KVM_WALL_CLOCK" },
    .{ .index = 0x0000_0012, .name = "MSR_KVM_SYSTEM_TIME" },
    .{ .index = 0x0000_003b, .name = "MSR_IA32_TSC_ADJUST" },
    .{ .index = 0x0000_06e0, .name = "MSR_IA32_TSC_DEADLINE" },
    .{ .index = 0x4b56_4d00, .name = "MSR_KVM_WALL_CLOCK_NEW" },
    .{ .index = 0x4b56_4d01, .name = "MSR_KVM_SYSTEM_TIME_NEW" },
    .{ .index = 0x4b56_4d02, .name = "MSR_KVM_ASYNC_PF_EN" },
    .{ .index = 0x4b56_4d03, .name = "MSR_KVM_STEAL_TIME" },
    .{ .index = 0x4b56_4d04, .name = "MSR_KVM_PV_EOI_EN" },
    .{ .index = 0x4b56_4d05, .name = "MSR_KVM_POLL_CONTROL" },
    .{ .index = 0x4b56_4d06, .name = "MSR_KVM_ASYNC_PF_INT" },
    .{ .index = 0x4b56_4d07, .name = "MSR_KVM_ASYNC_PF_ACK" },
};

pub const Stage0b2MsrDisposition = enum {
    required,
    optional_if_advertised,
    excluded,
};

pub const MsrRestoreOrder = enum(u8) {
    kernel = 0,
    paravirtual = 1,
    tsc_adjust = 2,
    tsc = 3,
    excluded = 4,
};

pub const Stage0b2Msr = struct {
    index: u32,
    name: []const u8,
    disposition: Stage0b2MsrDisposition,
    order: MsrRestoreOrder,
};

/// Provisional, evidence-only restore list for the single-runnable-vCPU
/// Stage 0b.2 harness. This is deliberately not the candidate profile: Stage
/// 0b.3 owns the final required/default/excluded classification.
pub const stage0b2_msr_inventory = [_]Stage0b2Msr{
    .{ .index = 0x0000_0174, .name = "MSR_IA32_SYSENTER_CS", .disposition = .required, .order = .kernel },
    .{ .index = 0x0000_0175, .name = "MSR_IA32_SYSENTER_ESP", .disposition = .required, .order = .kernel },
    .{ .index = 0x0000_0176, .name = "MSR_IA32_SYSENTER_EIP", .disposition = .required, .order = .kernel },
    .{ .index = 0x0000_01a0, .name = "MSR_IA32_MISC_ENABLE", .disposition = .required, .order = .kernel },
    .{ .index = 0x0000_0277, .name = "MSR_IA32_CR_PAT", .disposition = .required, .order = .kernel },
    .{ .index = 0xc000_0081, .name = "MSR_STAR", .disposition = .required, .order = .kernel },
    .{ .index = 0xc000_0082, .name = "MSR_LSTAR", .disposition = .required, .order = .kernel },
    .{ .index = 0xc000_0083, .name = "MSR_CSTAR", .disposition = .required, .order = .kernel },
    .{ .index = 0xc000_0084, .name = "MSR_SYSCALL_MASK", .disposition = .required, .order = .kernel },
    .{ .index = 0xc000_0102, .name = "MSR_KERNEL_GS_BASE", .disposition = .required, .order = .kernel },
    .{ .index = 0xc000_0103, .name = "MSR_TSC_AUX", .disposition = .required, .order = .kernel },
    .{ .index = 0x4b56_4d00, .name = "MSR_KVM_WALL_CLOCK_NEW", .disposition = .optional_if_advertised, .order = .paravirtual },
    .{ .index = 0x4b56_4d01, .name = "MSR_KVM_SYSTEM_TIME_NEW", .disposition = .optional_if_advertised, .order = .paravirtual },
    .{ .index = 0x4b56_4d02, .name = "MSR_KVM_ASYNC_PF_EN", .disposition = .optional_if_advertised, .order = .paravirtual },
    .{ .index = 0x4b56_4d03, .name = "MSR_KVM_STEAL_TIME", .disposition = .optional_if_advertised, .order = .paravirtual },
    .{ .index = 0x4b56_4d04, .name = "MSR_KVM_PV_EOI_EN", .disposition = .optional_if_advertised, .order = .paravirtual },
    .{ .index = 0x4b56_4d05, .name = "MSR_KVM_POLL_CONTROL", .disposition = .optional_if_advertised, .order = .paravirtual },
    .{ .index = 0x4b56_4d06, .name = "MSR_KVM_ASYNC_PF_INT", .disposition = .optional_if_advertised, .order = .paravirtual },
    .{ .index = 0x4b56_4d07, .name = "MSR_KVM_ASYNC_PF_ACK", .disposition = .optional_if_advertised, .order = .paravirtual },
    .{ .index = 0x0000_003b, .name = "MSR_IA32_TSC_ADJUST", .disposition = .required, .order = .tsc_adjust },
    .{ .index = 0x0000_0010, .name = "MSR_IA32_TSC", .disposition = .required, .order = .tsc },
    .{ .index = 0x0000_0011, .name = "MSR_KVM_WALL_CLOCK", .disposition = .excluded, .order = .excluded },
    .{ .index = 0x0000_0012, .name = "MSR_KVM_SYSTEM_TIME", .disposition = .excluded, .order = .excluded },
    .{ .index = 0x0000_06e0, .name = "MSR_IA32_TSC_DEADLINE", .disposition = .excluded, .order = .excluded },
};

pub const profile_name = "sporevm-x86_64-v0";
pub const vendor_id = "GenuineIntel";
pub const guest_tsc_khz: u64 = 3_000_000;
pub const xcr0: u64 = 0x7;
pub const architectural_xsave_bytes: u32 = 832;
pub const kvm_xsave_min_bytes: u32 = 4096;
pub const kvm_xsave_max_bytes: u32 = 64 * 1024;
pub const capture_clock_flags: u32 = kvm.KVM_CLOCK_TSC_STABLE | kvm.KVM_CLOCK_REALTIME | kvm.KVM_CLOCK_HOST_TSC;
pub const restore_clock_flags: u32 = kvm.KVM_CLOCK_REALTIME;

pub const CandidateMsr = struct {
    index: u32,
    name: []const u8,
    order: MsrRestoreOrder,
};

/// The complete v0 MSR state. Paravirtual features omitted here are hidden in
/// CPUID rather than conditionally serialized.
pub const candidate_msrs = [_]CandidateMsr{
    .{ .index = 0x0000_0174, .name = "MSR_IA32_SYSENTER_CS", .order = .kernel },
    .{ .index = 0x0000_0175, .name = "MSR_IA32_SYSENTER_ESP", .order = .kernel },
    .{ .index = 0x0000_0176, .name = "MSR_IA32_SYSENTER_EIP", .order = .kernel },
    .{ .index = 0x0000_01a0, .name = "MSR_IA32_MISC_ENABLE", .order = .kernel },
    .{ .index = 0x0000_0277, .name = "MSR_IA32_CR_PAT", .order = .kernel },
    .{ .index = 0xc000_0081, .name = "MSR_STAR", .order = .kernel },
    .{ .index = 0xc000_0082, .name = "MSR_LSTAR", .order = .kernel },
    .{ .index = 0xc000_0083, .name = "MSR_CSTAR", .order = .kernel },
    .{ .index = 0xc000_0084, .name = "MSR_SYSCALL_MASK", .order = .kernel },
    .{ .index = 0xc000_0102, .name = "MSR_KERNEL_GS_BASE", .order = .kernel },
    .{ .index = 0xc000_0103, .name = "MSR_TSC_AUX", .order = .kernel },
    .{ .index = 0x4b56_4d00, .name = "MSR_KVM_WALL_CLOCK_NEW", .order = .paravirtual },
    .{ .index = 0x4b56_4d01, .name = "MSR_KVM_SYSTEM_TIME_NEW", .order = .paravirtual },
    .{ .index = 0x0000_003b, .name = "MSR_IA32_TSC_ADJUST", .order = .tsc_adjust },
    .{ .index = 0x0000_0010, .name = "MSR_IA32_TSC", .order = .tsc },
};

pub const CapabilityRequirement = struct {
    id: u32,
    name: []const u8,
    minimum: u32 = 1,
    required_bits: u32 = 0,
};

pub const required_capabilities = [_]CapabilityRequirement{
    .{ .id = kvm.KVM_CAP_IRQCHIP, .name = "irqchip" },
    .{ .id = kvm.KVM_CAP_USER_MEMORY, .name = "user_memory" },
    .{ .id = kvm.KVM_CAP_SET_TSS_ADDR, .name = "set_tss_addr" },
    .{ .id = kvm.KVM_CAP_EXT_CPUID, .name = "ext_cpuid" },
    .{ .id = kvm.KVM_CAP_MP_STATE, .name = "mp_state" },
    .{ .id = kvm.KVM_CAP_PIT2, .name = "pit2" },
    .{ .id = kvm.KVM_CAP_PIT_STATE2, .name = "pit_state2" },
    .{ .id = kvm.KVM_CAP_SET_IDENTITY_MAP_ADDR, .name = "set_identity_map_addr" },
    .{ .id = kvm.KVM_CAP_ADJUST_CLOCK, .name = "adjust_clock", .required_bits = capture_clock_flags },
    .{ .id = kvm.KVM_CAP_VCPU_EVENTS, .name = "vcpu_events" },
    .{ .id = kvm.KVM_CAP_DEBUGREGS, .name = "debugregs" },
    .{ .id = kvm.KVM_CAP_ENABLE_CAP_VM, .name = "enable_cap_vm" },
    .{ .id = kvm.KVM_CAP_XSAVE, .name = "xsave" },
    .{ .id = kvm.KVM_CAP_XCRS, .name = "xcrs" },
    .{ .id = kvm.KVM_CAP_TSC_CONTROL, .name = "tsc_control" },
    .{ .id = kvm.KVM_CAP_GET_TSC_KHZ, .name = "get_tsc_khz" },
    .{ .id = kvm.KVM_CAP_KVMCLOCK_CTRL, .name = "kvmclock_ctrl" },
    .{ .id = kvm.KVM_CAP_IMMEDIATE_EXIT, .name = "immediate_exit" },
    .{ .id = kvm.KVM_CAP_EXCEPTION_PAYLOAD, .name = "exception_payload" },
    .{ .id = kvm.KVM_CAP_ENFORCE_PV_FEATURE_CPUID, .name = "enforce_pv_feature_cpuid" },
    .{ .id = kvm.KVM_CAP_VM_TSC_CONTROL, .name = "vm_tsc_control" },
};

pub const CapabilityFact = struct { id: u32, value: u32 };

pub const HostFacts = struct {
    api_version: u32,
    vendor: [12]u8,
    max_vcpus: u32,
    capabilities: []const CapabilityFact,
    msr_indices: []const u32,
    supported_cpuid: []const kvm.CpuidEntry,
    xsave_bytes: u32,
    tsc_khz: u64,
    has_tsc_offset: bool,
};

pub const Incompatibility = union(enum) {
    api_version: u32,
    vendor,
    vcpu_capacity: u32,
    missing_capability: u32,
    capability_value: u32,
    missing_msr: u32,
    unsupported_cpuid: struct { function: u32, index: u32 },
    xsave_size: u32,
    tsc_frequency: u64,
    tsc_offset,
};

pub fn compatibility(facts: HostFacts, requested_vcpus: topology.VcpuCount) ?Incompatibility {
    topology.validateVcpuCount(requested_vcpus) catch return .{ .vcpu_capacity = requested_vcpus };
    if (facts.api_version != kvm.KVM_API_VERSION) return .{ .api_version = facts.api_version };
    if (!std.mem.eql(u8, &facts.vendor, vendor_id)) return .vendor;
    if (facts.max_vcpus < requested_vcpus) return .{ .vcpu_capacity = facts.max_vcpus };
    for (required_capabilities) |required| {
        const value = capabilityValue(facts.capabilities, required.id) orelse return .{ .missing_capability = required.id };
        if (value < required.minimum or value & required.required_bits != required.required_bits) return .{ .capability_value = required.id };
    }
    for (candidate_msrs) |required| {
        if (std.mem.indexOfScalar(u32, facts.msr_indices, required.index) == null) return .{ .missing_msr = required.index };
    }
    const requested_cpuid = candidateCpuid(requested_vcpus, 0) catch return .{ .vcpu_capacity = requested_vcpus };
    for (requested_cpuid.entries[0..requested_cpuid.nent]) |requested| {
        if (!cpuidFeatureLeaf(requested.function)) continue;
        const supported = findCpuid(facts.supported_cpuid, requested.function, requested.index) orelse
            return .{ .unsupported_cpuid = .{ .function = requested.function, .index = requested.index } };
        if (!cpuidFeaturesSupported(requested, supported)) {
            return .{ .unsupported_cpuid = .{ .function = requested.function, .index = requested.index } };
        }
    }
    if (facts.xsave_bytes < kvm_xsave_min_bytes or facts.xsave_bytes > kvm_xsave_max_bytes) return .{ .xsave_size = facts.xsave_bytes };
    if (facts.tsc_khz != guest_tsc_khz) return .{ .tsc_frequency = facts.tsc_khz };
    if (!facts.has_tsc_offset) return .tsc_offset;
    return null;
}

fn cpuidFeatureLeaf(function: u32) bool {
    return function == 1 or function == 7 or function == 0x4000_0001 or function == 0x8000_0001 or function == 0x8000_0007;
}

fn cpuidFeaturesSupported(requested: kvm.CpuidEntry, supported: kvm.CpuidEntry) bool {
    const subset = struct {
        fn of(wanted: u32, available: u32) bool {
            return wanted & ~available == 0;
        }
    }.of;
    return switch (requested.function) {
        // EAX is the CPU signature and EBX contains topology/cache-line
        // values. EDX.HTT is synthesized with the requested topology and
        // ECX.OSXSAVE is guest-CR4-dependent, so KVM deliberately
        // omits it from KVM_GET_SUPPORTED_CPUID even though KVM_SET_CPUID2
        // accepts it and updates the visible bit with CR4.OSXSAVE.
        1 => subset(requested.ecx & ~@as(u32, 1 << 27), supported.ecx) and
            subset(requested.edx & ~@as(u32, 1 << 28), supported.edx),
        // Leaf 7 EAX is the maximum subleaf; EBX, ECX, and EDX are features.
        7 => subset(requested.ebx, supported.ebx) and subset(requested.ecx, supported.ecx) and subset(requested.edx, supported.edx),
        0x4000_0001 => subset(requested.eax, supported.eax) and subset(requested.ebx, supported.ebx) and
            subset(requested.ecx, supported.ecx) and subset(requested.edx, supported.edx),
        0x8000_0001 => subset(requested.ecx, supported.ecx) and subset(requested.edx, supported.edx),
        0x8000_0007 => subset(requested.edx, supported.edx),
        else => unreachable,
    };
}

fn findCpuid(entries: []const kvm.CpuidEntry, function: u32, index: u32) ?kvm.CpuidEntry {
    for (entries) |entry| if (entry.function == function and entry.index == index) return entry;
    return null;
}

fn capabilityValue(facts: []const CapabilityFact, id: u32) ?u32 {
    for (facts) |fact| if (fact.id == id) return fact.value;
    return null;
}

const leaf1_ecx: u32 = (1 << 0) | (1 << 1) | (1 << 9) | (1 << 12) | (1 << 13) |
    (1 << 17) | (1 << 19) | (1 << 20) | (1 << 22) | (1 << 23) | (1 << 25) |
    (1 << 26) | (1 << 27) | (1 << 28) | (1 << 29) | (1 << 30) | (1 << 31);
const leaf1_edx: u32 = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) |
    (1 << 5) | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 11) |
    (1 << 13) | (1 << 15) | (1 << 16) | (1 << 17) |
    (1 << 19) | (1 << 23) | (1 << 24) | (1 << 25) | (1 << 26);

pub fn candidateCpuid(vcpu_count: topology.VcpuCount, vcpu_index: topology.VcpuIndex) !kvm.Cpuid {
    var result = kvm.Cpuid{ .nent = 12 };
    result.entries[0] = .{ .function = 0, .eax = 0x0d, .ebx = 0x756e_6547, .ecx = 0x6c65_746e, .edx = 0x4965_6e69 };
    result.entries[1] = .{ .function = 1, .eax = 0x0005_0657, .ebx = 0x0000_0800, .ecx = leaf1_ecx, .edx = leaf1_edx };
    result.entries[2] = .{ .function = 7, .flags = kvm.KVM_CPUID_FLAG_SIGNIFCANT_INDEX, .ebx = 1 << 1 };
    result.entries[3] = .{ .function = 0x0b, .flags = kvm.KVM_CPUID_FLAG_SIGNIFCANT_INDEX };
    result.entries[4] = .{ .function = 0x0d, .flags = kvm.KVM_CPUID_FLAG_SIGNIFCANT_INDEX, .eax = @intCast(xcr0), .ebx = architectural_xsave_bytes, .ecx = architectural_xsave_bytes };
    result.entries[5] = .{ .function = 0x0d, .index = 2, .flags = kvm.KVM_CPUID_FLAG_SIGNIFCANT_INDEX, .eax = 256, .ebx = 576 };
    result.entries[6] = .{ .function = 0x4000_0000, .eax = 0x4000_0001, .ebx = 0x4b4d_564b, .ecx = 0x564b_4d56, .edx = 0x0000_004d };
    result.entries[7] = .{ .function = 0x4000_0001, .eax = (1 << 3) | (1 << 24) };
    result.entries[8] = .{ .function = 0x8000_0000, .eax = 0x8000_0008 };
    result.entries[9] = .{ .function = 0x8000_0001, .ecx = (1 << 0) | (1 << 5) | (1 << 8), .edx = (1 << 11) | (1 << 20) | (1 << 26) | (1 << 27) | (1 << 29) };
    result.entries[10] = .{ .function = 0x8000_0007, .edx = 1 << 8 };
    result.entries[11] = .{ .function = 0x8000_0008, .eax = 0x002e_302e };
    return kvm.normalizeSupportedCpuidTopology(result, vcpu_count, vcpu_index);
}

pub const ClockDecision = enum {
    guest_tsc_khz,
    required_capabilities,
    accepted_kvm_clock_flags,
    pause_semantics,
    reanchor_mode,
    restore_constraints,
    monotonicity_tolerance,
};

pub const clock_decision_inventory = std.enums.values(ClockDecision);

test "candidate is atomically approved after same-host Slice 0b proof" {
    try std.testing.expectEqual(CandidateStatus.approved_same_host, candidate_status);
}

test "CPUID decision inventory is bounded ordered and explicit" {
    try std.testing.expect(cpuid_decision_inventory.len <= 256);
    for (cpuid_decision_inventory, 0..) |decision, index| {
        if (index > 0) {
            const previous = cpuid_decision_inventory[index - 1];
            const previous_key = (@as(u64, previous.function) << 32) | previous.index;
            const key = (@as(u64, decision.function) << 32) | decision.index;
            try std.testing.expect(previous_key < key);
        }
        const indexed = decision.function == 0x0000_000b or
            decision.function == 0x0000_000d or
            decision.function == 0x0000_001f;
        try std.testing.expectEqual(indexed, decision.index_policy == .significant);
    }
    try std.testing.expectEqualDeep(ForbiddenCpuidBit{
        .function = 0x0000_0001,
        .index = 0,
        .register = .ecx,
        .bit = 5,
        .name = "vmx",
    }, forbidden_cpuid_bits[0]);
    try std.testing.expectEqualDeep(ForbiddenCpuidBit{
        .function = 0x8000_0001,
        .index = 0,
        .register = .ecx,
        .bit = 2,
        .name = "svm",
    }, forbidden_cpuid_bits[1]);
}

test "profile capability audit inventory uses stable Linux KVM IDs" {
    const expected_ids = [_]u32{ 8, 39, 55, 56, 59, 60, 61, 72, 76, 129, 183, 187, 190, 208, 214 };
    for (capability_audit_inventory, expected_ids, 0..) |entry, expected_id, index| {
        try std.testing.expectEqual(expected_id, entry.id);
        try std.testing.expect(entry.name.len != 0);
        if (index > 0) try std.testing.expect(capability_audit_inventory[index - 1].id < entry.id);
    }
}

test "XSAVE audit bounds separate legacy and XSAVE2 storage" {
    try std.testing.expectEqual(@as(u32, 576), xsave_legacy_and_header_bytes);
    try std.testing.expectEqual(@as(u32, 4096), kvm_legacy_xsave_area_bytes);
}

test "MSR audit inventory is ordered unique and named" {
    for (msr_audit_inventory, 0..) |entry, index| {
        try std.testing.expect(entry.name.len != 0);
        if (index > 0) try std.testing.expect(msr_audit_inventory[index - 1].index < entry.index);
    }
}

test "Stage 0b.2 MSR restore inventory is bounded and explicitly ordered" {
    try std.testing.expect(stage0b2_msr_inventory.len <= 32);
    for (stage0b2_msr_inventory, 0..) |entry, index| {
        try std.testing.expect(entry.name.len != 0);
        if (index > 0) {
            try std.testing.expect(@intFromEnum(stage0b2_msr_inventory[index - 1].order) <= @intFromEnum(entry.order));
        }
        for (stage0b2_msr_inventory[0..index]) |previous| {
            try std.testing.expect(previous.index != entry.index);
        }
    }
    try std.testing.expectEqual(Stage0b2MsrDisposition.excluded, stage0b2_msr_inventory[stage0b2_msr_inventory.len - 1].disposition);
}

test "clock decisions remain explicit and unresolved" {
    try std.testing.expectEqual(@as(usize, 7), clock_decision_inventory.len);
    try std.testing.expectEqual(ClockDecision.guest_tsc_khz, clock_decision_inventory[0]);
    try std.testing.expectEqual(ClockDecision.monotonicity_tolerance, clock_decision_inventory[6]);
}

test "candidate profile is narrow ordered and derived from Stage 0b.2 evidence" {
    try std.testing.expectEqualStrings("sporevm-x86_64-v0", profile_name);
    try std.testing.expectEqual(@as(u64, 7), xcr0);
    try std.testing.expectEqual(@as(u32, 832), architectural_xsave_bytes);
    try std.testing.expectEqual(@as(u64, 3_000_000), guest_tsc_khz);
    try std.testing.expectEqual(@as(usize, 15), candidate_msrs.len);
    for (candidate_msrs, 0..) |entry, index| {
        if (index > 0) try std.testing.expect(@intFromEnum(candidate_msrs[index - 1].order) <= @intFromEnum(entry.order));
        var found = false;
        for (stage0b2_msr_inventory) |evidence| {
            if (evidence.index == entry.index and evidence.disposition != .excluded) found = true;
        }
        try std.testing.expect(found);
        for (candidate_msrs[0..index]) |previous| try std.testing.expect(previous.index != entry.index);
    }
    for ([_]u32{ 0x11, 0x12, 0x6e0, 0x4b56_4d02, 0x4b56_4d03, 0x4b56_4d04, 0x4b56_4d05, 0x4b56_4d06, 0x4b56_4d07 }) |excluded| {
        for (candidate_msrs) |entry| try std.testing.expect(entry.index != excluded);
    }
}

test "candidate CPUID is exact xAPIC x87 SSE AVX topology" {
    for ([_]topology.VcpuCount{ 1, 2, topology.max_vcpus }) |vcpu_count| {
        var index: topology.VcpuIndex = 0;
        while (index < vcpu_count) : (index += 1) {
            const cpuid = try candidateCpuid(vcpu_count, index);
            try std.testing.expectEqual(@as(u32, 13), cpuid.nent);
            var saw_leaf1 = false;
            var saw_xsave = false;
            var saw_ymm = false;
            for (cpuid.entries[0..cpuid.nent]) |entry| {
                if (entry.function == 1) {
                    saw_leaf1 = true;
                    try std.testing.expectEqual(@as(u32, 0), entry.ecx & ((1 << 5) | (1 << 21) | (1 << 24)));
                    try std.testing.expectEqual(@as(u32, 0), entry.edx & ((1 << 7) | (1 << 12) | (1 << 14)));
                    try std.testing.expectEqual(vcpu_count, (entry.ebx >> 16) & 0xff);
                    try std.testing.expectEqual(index, entry.ebx >> 24);
                } else if (entry.function == 7) {
                    try std.testing.expectEqual(@as(u32, 1 << 1), entry.ebx);
                    try std.testing.expectEqual(@as(u32, 0), entry.ecx | entry.edx);
                } else if (entry.function == 0x0d and entry.index == 0) {
                    saw_xsave = true;
                    try std.testing.expectEqual(@as(u32, 7), entry.eax);
                    try std.testing.expectEqual(@as(u32, 832), entry.ebx);
                    try std.testing.expectEqual(@as(u32, 832), entry.ecx);
                } else if (entry.function == 0x0d and entry.index == 2) {
                    saw_ymm = true;
                    try std.testing.expectEqual(@as(u32, 256), entry.eax);
                    try std.testing.expectEqual(@as(u32, 576), entry.ebx);
                } else if (entry.function == 0x4000_0001) {
                    try std.testing.expectEqual(@as(u32, (1 << 3) | (1 << 24)), entry.eax);
                } else if (entry.function == 0x8000_0001) {
                    try std.testing.expectEqual(@as(u32, 0), entry.ecx & (1 << 2));
                }
            }
            try std.testing.expect(saw_leaf1 and saw_xsave and saw_ymm);
        }
    }
}

test "candidate compatibility returns typed first failures" {
    var capabilities: [required_capabilities.len]CapabilityFact = undefined;
    for (required_capabilities, &capabilities) |required, *fact| fact.* = .{
        .id = required.id,
        .value = @max(required.minimum, required.required_bits),
    };
    var msrs: [candidate_msrs.len]u32 = undefined;
    for (candidate_msrs, &msrs) |required, *index| index.* = required.index;
    var facts = HostFacts{
        .api_version = kvm.KVM_API_VERSION,
        .vendor = vendor_id.*,
        .max_vcpus = topology.max_vcpus,
        .capabilities = &capabilities,
        .msr_indices = &msrs,
        .supported_cpuid = undefined,
        .xsave_bytes = 4096,
        .tsc_khz = guest_tsc_khz,
        .has_tsc_offset = true,
    };
    const supported = try candidateCpuid(2, 0);
    facts.supported_cpuid = supported.entries[0..supported.nent];
    try std.testing.expectEqual(@as(?Incompatibility, null), compatibility(facts, 2));
    var host_shaped = supported;
    for (host_shaped.entries[0..host_shaped.nent]) |*entry| {
        if (entry.function == 1) {
            entry.eax = 0;
            entry.ebx = 0;
            entry.ecx &= ~@as(u32, 1 << 27);
            entry.edx &= ~@as(u32, 1 << 28);
        }
        if (entry.function == 7) entry.eax = 0;
    }
    facts.supported_cpuid = host_shaped.entries[0..host_shaped.nent];
    try std.testing.expectEqual(@as(?Incompatibility, null), compatibility(facts, 2));
    facts.supported_cpuid = supported.entries[0..supported.nent];
    facts.api_version = 11;
    try std.testing.expectEqual(@as(u32, 11), compatibility(facts, 2).?.api_version);
    facts.api_version = kvm.KVM_API_VERSION;
    facts.vendor[0] = 'A';
    try std.testing.expect(compatibility(facts, 2).? == .vendor);
    facts.vendor = vendor_id.*;
    capabilities[0].value = 0;
    try std.testing.expectEqual(required_capabilities[0].id, compatibility(facts, 2).?.capability_value);
    capabilities[0].value = 1;
    msrs[0] = 0xffff_ffff;
    try std.testing.expectEqual(candidate_msrs[0].index, compatibility(facts, 2).?.missing_msr);
    msrs[0] = candidate_msrs[0].index;
    var insufficient = supported;
    for (insufficient.entries[0..insufficient.nent]) |*entry| {
        if (entry.function == 1) entry.ecx &= ~@as(u32, 1 << 28);
    }
    facts.supported_cpuid = insufficient.entries[0..insufficient.nent];
    const cpuid_failure = compatibility(facts, 2).?.unsupported_cpuid;
    try std.testing.expectEqual(@as(u32, 1), cpuid_failure.function);
    facts.supported_cpuid = supported.entries[0..supported.nent];
    facts.xsave_bytes = 832;
    try std.testing.expectEqual(@as(u32, 832), compatibility(facts, 2).?.xsave_size);
    facts.xsave_bytes = 4096;
    facts.tsc_khz = 2_500_000;
    try std.testing.expectEqual(@as(u64, 2_500_000), compatibility(facts, 2).?.tsc_frequency);
    facts.tsc_khz = guest_tsc_khz;
    facts.has_tsc_offset = false;
    try std.testing.expect(compatibility(facts, 2).? == .tsc_offset);
}
