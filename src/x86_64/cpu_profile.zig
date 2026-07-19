//! Pure audit contract for the candidate x86 CPU and clock profile.
//!
//! Stage 1.3 freezes the bounded questions that Slice 0b must answer. It does
//! not export a partially populated profile or a caller-asserted host verdict.

const std = @import("std");

pub const CandidateStatus = enum {
    pending_stage0b,
};

pub const candidate_status: CandidateStatus = .pending_stage0b;

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

pub const Stage0b2MsrOrder = enum(u8) {
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
    order: Stage0b2MsrOrder,
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

test "candidate is atomically pending Slice 0b" {
    try std.testing.expectEqual(CandidateStatus.pending_stage0b, candidate_status);
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
