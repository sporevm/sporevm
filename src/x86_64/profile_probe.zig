//! Bounded, host-only evidence probe for the candidate x86-64 KVM profile.
//!
//! This program creates disposable VM and vCPU file descriptors and exercises
//! reset-state get/set/get paths. It deliberately never maps `kvm_run` or
//! invokes `KVM_RUN`, so its output is inventory evidence rather than capture
//! or restore approval.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const kvm = @import("../kvm/x86_64.zig");
const cpu_profile = @import("cpu_profile.zig");

const msr_capacity = 256;
const max_xsave_bytes = 64 * 1024;

const ProbeError = kvm.Error || error{
    ClockMovedBackwards,
    DuplicateCpuidSelector,
    DuplicateMsrIndex,
    MalformedXsaveLayout,
    RequiredProbeCapabilityMissing,
    TscFrequencyChanged,
    XcrsRoundTripMismatch,
    XcrsTooLarge,
    XsaveRoundTripMismatch,
};

const CapabilityValues = struct {
    system: [cpu_profile.capability_audit_inventory.len]usize,
    vm: [cpu_profile.capability_audit_inventory.len]usize,
    vm_check_value: usize,
    feature_msr_value: usize,

    fn vmScoped(self: CapabilityValues) bool {
        return self.vm_check_value != 0;
    }

    fn value(self: CapabilityValues, comptime id: u32) usize {
        inline for (cpu_profile.capability_audit_inventory, 0..) |descriptor, index| {
            if (descriptor.id == id) return if (self.vmScoped()) self.vm[index] else self.system[index];
        }
        @compileError("capability is not present in the x86 profile audit inventory");
    }
};

const XsaveLayout = struct {
    supported_xcr0: u64,
    supported_xss: u64,
    enabled_bytes: u32,
    maximum_bytes: u32,
    component_count: u32,
    supervisor_component_count: u32,
    maximum_component_end: u32,
};

pub fn main(init: std.process.Init) !void {
    const kvm_fd = try kvm.openDevKvm();
    defer _ = std.c.close(kvm_fd);
    try kvm.checkApiVersion(kvm_fd);

    var raw_cpuid = try kvm.getSupportedCpuid(kvm_fd);
    try canonicalizeCpuid(&raw_cpuid);
    const raw_layout = try validateXsaveLayout(&raw_cpuid);

    var ordinary_list = kvm.MsrList(msr_capacity){};
    const ordinary_indices = try kvm.getMsrIndexList(kvm_fd, kvm.KVM_GET_MSR_INDEX_LIST, msr_capacity, &ordinary_list, "KVM_GET_MSR_INDEX_LIST");

    if (try kvm.checkExtension(kvm_fd, kvm.KVM_CAP_GET_MSR_FEATURES) == 0) {
        return error.RequiredProbeCapabilityMissing;
    }
    var feature_list = kvm.MsrList(msr_capacity){};
    const feature_indices = try kvm.getMsrIndexList(kvm_fd, kvm.KVM_GET_MSR_FEATURE_INDEX_LIST, msr_capacity, &feature_list, "KVM_GET_MSR_FEATURE_INDEX_LIST");
    var feature_values = kvm.MsrBatch(msr_capacity){};
    try kvm.prepareMsrBatch(msr_capacity, &feature_values, feature_indices);
    const feature_completed = try kvm.ioctl(kvm_fd, kvm.KVM_GET_MSRS, @intFromPtr(&feature_values), "KVM_GET_MSRS features");
    const feature_entries = try kvm.completedMsrEntries(msr_capacity, &feature_values, feature_completed);
    try canonicalizeMsrEntries(feature_entries);

    const vm_fd: std.c.fd_t = @intCast(try kvm.ioctl(kvm_fd, kvm.KVM_CREATE_VM, 0, "KVM_CREATE_VM"));
    defer _ = std.c.close(vm_fd);
    const capabilities = try collectCapabilities(kvm_fd, vm_fd);
    if (capabilities.value(kvm.KVM_CAP_ADJUST_CLOCK) == 0) return error.RequiredProbeCapabilityMissing;

    var clock_before = kvm.ClockData{};
    _ = try kvm.ioctl(vm_fd, kvm.KVM_GET_CLOCK, @intFromPtr(&clock_before), "KVM_GET_CLOCK before");
    _ = try kvm.ioctl(vm_fd, kvm.KVM_SET_CLOCK, @intFromPtr(&clock_before), "KVM_SET_CLOCK reset round trip");
    var clock_after = kvm.ClockData{};
    _ = try kvm.ioctl(vm_fd, kvm.KVM_GET_CLOCK, @intFromPtr(&clock_after), "KVM_GET_CLOCK after");
    try validateClockRoundTrip(clock_before, clock_after);

    if (capabilities.value(kvm.KVM_CAP_VM_TSC_CONTROL) == 0) return error.RequiredProbeCapabilityMissing;
    const vm_tsc_khz_before = try requiredPositiveIoctl(vm_fd, kvm.KVM_GET_TSC_KHZ, 0, "KVM_GET_TSC_KHZ vm before");
    _ = try kvm.ioctl(vm_fd, kvm.KVM_SET_TSC_KHZ, vm_tsc_khz_before, "KVM_SET_TSC_KHZ vm before vCPU creation");
    const vm_tsc_khz_after = try requiredPositiveIoctl(vm_fd, kvm.KVM_GET_TSC_KHZ, 0, "KVM_GET_TSC_KHZ vm after");
    if (vm_tsc_khz_before != vm_tsc_khz_after) return error.TscFrequencyChanged;

    const vcpu_fd: std.c.fd_t = @intCast(try kvm.ioctl(vm_fd, kvm.KVM_CREATE_VCPU, 0, "KVM_CREATE_VCPU"));
    defer _ = std.c.close(vcpu_fd);

    var requested_cpuid = try kvm.normalizeSupportedCpuidTopology(raw_cpuid, 1, 0);
    _ = try kvm.ioctl(vcpu_fd, kvm.KVM_SET_CPUID2, @intFromPtr(&requested_cpuid), "KVM_SET_CPUID2");
    var effective_cpuid = kvm.Cpuid{};
    _ = try kvm.ioctl(vcpu_fd, kvm.KVM_GET_CPUID2, @intFromPtr(&effective_cpuid), "KVM_GET_CPUID2");
    try canonicalizeCpuid(&requested_cpuid);
    try canonicalizeCpuid(&effective_cpuid);
    const requested_layout = try validateXsaveLayout(&requested_cpuid);
    const effective_layout = try validateXsaveLayout(&effective_cpuid);

    const vcpu_tsc_khz_before = try requiredPositiveIoctl(vcpu_fd, kvm.KVM_GET_TSC_KHZ, 0, "KVM_GET_TSC_KHZ vCPU before");
    if (vcpu_tsc_khz_before != vm_tsc_khz_after) return error.TscFrequencyChanged;
    _ = try kvm.ioctl(vcpu_fd, kvm.KVM_SET_TSC_KHZ, vcpu_tsc_khz_before, "KVM_SET_TSC_KHZ vCPU reset round trip");
    const vcpu_tsc_khz_after = try requiredPositiveIoctl(vcpu_fd, kvm.KVM_GET_TSC_KHZ, 0, "KVM_GET_TSC_KHZ vCPU after");
    if (vcpu_tsc_khz_before != vcpu_tsc_khz_after) return error.TscFrequencyChanged;

    var ordinary_values = kvm.MsrBatch(msr_capacity){};
    try kvm.prepareMsrBatch(msr_capacity, &ordinary_values, ordinary_indices);
    const ordinary_completed = try kvm.ioctl(vcpu_fd, kvm.KVM_GET_MSRS, @intFromPtr(&ordinary_values), "KVM_GET_MSRS reset inventory");
    const ordinary_entries = try kvm.completedMsrEntries(msr_capacity, &ordinary_values, ordinary_completed);
    try canonicalizeMsrEntries(ordinary_entries);

    if (capabilities.value(kvm.KVM_CAP_XSAVE) == 0) return error.RequiredProbeCapabilityMissing;
    const xsave2_size = capabilities.value(kvm.KVM_CAP_XSAVE2);
    const uses_xsave2 = xsave2_size != 0;
    const xsave_size = if (uses_xsave2) xsave2_size else @sizeOf(kvm.Xsave);
    try validateKvmXsaveSize(raw_layout, xsave_size);
    try validateKvmXsaveSize(requested_layout, xsave_size);
    try validateKvmXsaveSize(effective_layout, xsave_size);
    var xsave_before_storage: [max_xsave_bytes]u8 align(8) = @splat(0);
    var xsave_after_storage: [max_xsave_bytes]u8 align(8) = @splat(0);
    const xsave_before = try kvm.xsave2Buffer(&xsave_before_storage, xsave_size);
    const xsave_after = try kvm.xsave2Buffer(&xsave_after_storage, xsave_size);
    const get_xsave_request = if (uses_xsave2) kvm.KVM_GET_XSAVE2 else kvm.KVM_GET_XSAVE;
    _ = try kvm.ioctl(vcpu_fd, get_xsave_request, @intFromPtr(xsave_before.ptr), if (uses_xsave2) "KVM_GET_XSAVE2 reset before" else "KVM_GET_XSAVE reset before");
    _ = try kvm.ioctl(vcpu_fd, kvm.KVM_SET_XSAVE, @intFromPtr(xsave_before.ptr), "KVM_SET_XSAVE reset round trip");
    _ = try kvm.ioctl(vcpu_fd, get_xsave_request, @intFromPtr(xsave_after.ptr), if (uses_xsave2) "KVM_GET_XSAVE2 reset after" else "KVM_GET_XSAVE reset after");
    if (!std.mem.eql(u8, xsave_before, xsave_after)) return error.XsaveRoundTripMismatch;

    if (capabilities.value(kvm.KVM_CAP_XCRS) == 0) return error.RequiredProbeCapabilityMissing;
    var xcrs_before = kvm.Xcrs{};
    _ = try kvm.ioctl(vcpu_fd, kvm.KVM_GET_XCRS, @intFromPtr(&xcrs_before), "KVM_GET_XCRS reset before");
    try validateXcrs(&xcrs_before);
    _ = try kvm.ioctl(vcpu_fd, kvm.KVM_SET_XCRS, @intFromPtr(&xcrs_before), "KVM_SET_XCRS reset round trip");
    var xcrs_after = kvm.Xcrs{};
    _ = try kvm.ioctl(vcpu_fd, kvm.KVM_GET_XCRS, @intFromPtr(&xcrs_after), "KVM_GET_XCRS reset after");
    try validateXcrs(&xcrs_after);
    if (!std.mem.eql(u8, std.mem.asBytes(&xcrs_before), std.mem.asBytes(&xcrs_after))) {
        return error.XcrsRoundTripMismatch;
    }

    const host_uts = std.posix.uname();
    const evidence = Evidence{
        .kernel_release = std.mem.sliceTo(&host_uts.release, 0),
        .capabilities = capabilities,
        .raw_cpuid = &raw_cpuid,
        .raw_layout = raw_layout,
        .requested_cpuid = &requested_cpuid,
        .requested_layout = requested_layout,
        .effective_cpuid = &effective_cpuid,
        .effective_layout = effective_layout,
        .feature_entries = feature_entries,
        .feature_msr_get_completed = feature_completed,
        .ordinary_msrs = ordinary_entries,
        .ordinary_msr_get_completed = ordinary_completed,
        .xsave_before = xsave_before,
        .xsave_after = xsave_after,
        .uses_xsave2 = uses_xsave2,
        .xcrs = &xcrs_after,
        .vm_tsc_khz = vm_tsc_khz_after,
        .vcpu_tsc_khz = vcpu_tsc_khz_after,
        .clock_before = clock_before,
        .clock_after = clock_after,
    };
    var ledger: std.Io.Writer.Allocating = .init(init.arena.allocator());
    defer ledger.deinit();
    try writeEvidence(&ledger.writer, evidence);
    const ledger_digest = sha256(ledger.written());
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.writeAll(ledger.written());
    try stdout.print("ledger sha256={s} complete=true\n", .{&ledger_digest});
    try stdout.flush();
}

fn collectCapabilities(kvm_fd: std.c.fd_t, vm_fd: std.c.fd_t) !CapabilityValues {
    const vm_check_value = try kvm.checkExtension(kvm_fd, kvm.KVM_CAP_CHECK_EXTENSION_VM);
    var values = CapabilityValues{
        .system = @splat(0),
        .vm = @splat(0),
        .vm_check_value = vm_check_value,
        .feature_msr_value = try kvm.checkExtension(kvm_fd, kvm.KVM_CAP_GET_MSR_FEATURES),
    };
    for (cpu_profile.capability_audit_inventory, 0..) |descriptor, index| {
        values.system[index] = try kvm.checkExtension(kvm_fd, descriptor.id);
        values.vm[index] = if (values.vmScoped())
            try kvm.ioctl(vm_fd, kvm.KVM_CHECK_EXTENSION, descriptor.id, "KVM_CHECK_EXTENSION vm")
        else
            values.system[index];
    }
    return values;
}

fn canonicalizeCpuid(cpuid: *kvm.Cpuid) ProbeError!void {
    const count = std.math.cast(usize, cpuid.nent) orelse return error.CpuidTooLarge;
    if (count > cpuid.entries.len) return error.CpuidTooLarge;
    std.mem.sort(kvm.CpuidEntry, cpuid.entries[0..count], {}, cpuidEntryLessThan);
    for (cpuid.entries[0..count], 0..) |entry, index| {
        if (index == 0) continue;
        const previous = cpuid.entries[index - 1];
        if (previous.function == entry.function and previous.index == entry.index) {
            return error.DuplicateCpuidSelector;
        }
    }
}

fn cpuidEntryLessThan(_: void, left: kvm.CpuidEntry, right: kvm.CpuidEntry) bool {
    if (left.function != right.function) return left.function < right.function;
    if (left.index != right.index) return left.index < right.index;
    if (left.flags != right.flags) return left.flags < right.flags;
    if (left.eax != right.eax) return left.eax < right.eax;
    if (left.ebx != right.ebx) return left.ebx < right.ebx;
    if (left.ecx != right.ecx) return left.ecx < right.ecx;
    return left.edx < right.edx;
}

fn canonicalizeMsrEntries(entries: []kvm.MsrEntry) ProbeError!void {
    std.mem.sort(kvm.MsrEntry, entries, {}, msrEntryLessThan);
    for (entries, 0..) |entry, index| {
        if (index > 0 and entries[index - 1].index == entry.index) return error.DuplicateMsrIndex;
    }
}

fn msrEntryLessThan(_: void, left: kvm.MsrEntry, right: kvm.MsrEntry) bool {
    return left.index < right.index;
}

fn validateXsaveLayout(cpuid: *const kvm.Cpuid) ProbeError!XsaveLayout {
    const count = std.math.cast(usize, cpuid.nent) orelse return error.CpuidTooLarge;
    if (count > cpuid.entries.len) return error.CpuidTooLarge;
    var base: ?kvm.CpuidEntry = null;
    var features: ?kvm.CpuidEntry = null;
    var component_count: u32 = 0;
    var supervisor_component_count: u32 = 0;
    var maximum_component_end: u32 = 0;
    var component_ranges: [64]struct { start: u32, end: u32 } = undefined;
    var range_count: usize = 0;
    for (cpuid.entries[0..count]) |entry| {
        if (entry.function != 0x0000_000d) continue;
        if (entry.index == 0) {
            if (base != null) return error.DuplicateCpuidSelector;
            base = entry;
        } else if (entry.index == 1) {
            if (features != null) return error.DuplicateCpuidSelector;
            features = entry;
        }
    }
    const leaf = base orelse return error.MalformedXsaveLayout;
    const supported_xss = if (features) |entry| (@as(u64, entry.edx) << 32) | entry.ecx else 0;
    for (cpuid.entries[0..count]) |entry| {
        if (entry.function != 0x0000_000d or entry.index < 2 or entry.eax == 0) continue;
        if (entry.index >= 64) return error.MalformedXsaveLayout;
        component_count += 1;
        if (entry.ecx & 1 != 0) {
            if (supported_xss & (@as(u64, 1) << @intCast(entry.index)) == 0) return error.MalformedXsaveLayout;
            supervisor_component_count += 1;
            continue;
        }
        if (range_count == component_ranges.len) return error.MalformedXsaveLayout;
        const end = std.math.add(u32, entry.ebx, entry.eax) catch return error.MalformedXsaveLayout;
        if (entry.ebx < cpu_profile.xsave_legacy_and_header_bytes) return error.MalformedXsaveLayout;
        for (component_ranges[0..range_count]) |range| {
            if (entry.ebx < range.end and end > range.start) return error.MalformedXsaveLayout;
        }
        component_ranges[range_count] = .{ .start = entry.ebx, .end = end };
        range_count += 1;
        maximum_component_end = @max(maximum_component_end, end);
    }
    if (leaf.ebx < cpu_profile.xsave_legacy_and_header_bytes or
        leaf.ecx < leaf.ebx or maximum_component_end > leaf.ecx)
    {
        return error.MalformedXsaveLayout;
    }
    return .{
        .supported_xcr0 = (@as(u64, leaf.edx) << 32) | leaf.eax,
        .supported_xss = supported_xss,
        .enabled_bytes = leaf.ebx,
        .maximum_bytes = leaf.ecx,
        .component_count = component_count,
        .supervisor_component_count = supervisor_component_count,
        .maximum_component_end = maximum_component_end,
    };
}

fn validateKvmXsaveSize(layout: XsaveLayout, kvm_size: usize) ProbeError!void {
    if (layout.maximum_bytes > kvm_size or layout.maximum_component_end > kvm_size) {
        return error.MalformedXsaveLayout;
    }
}

fn validateXcrs(xcrs: *const kvm.Xcrs) ProbeError!void {
    const count = std.math.cast(usize, xcrs.nr_xcrs) orelse return error.XcrsTooLarge;
    if (count > xcrs.xcrs.len) return error.XcrsTooLarge;
    for (xcrs.xcrs[0..count], 0..) |entry, index| {
        if (entry.reserved != 0) return error.XcrsTooLarge;
        if (index > 0 and xcrs.xcrs[index - 1].xcr >= entry.xcr) return error.XcrsTooLarge;
    }
}

fn validateClockRoundTrip(before: kvm.ClockData, after: kvm.ClockData) ProbeError!void {
    if (after.clock < before.clock) return error.ClockMovedBackwards;
    if (before.flags & kvm.KVM_CLOCK_REALTIME != 0 and after.realtime < before.realtime) {
        return error.ClockMovedBackwards;
    }
    if (before.flags & kvm.KVM_CLOCK_HOST_TSC != 0 and after.host_tsc < before.host_tsc) {
        return error.ClockMovedBackwards;
    }
}

fn requiredPositiveIoctl(fd: std.c.fd_t, request: u32, arg: usize, op: []const u8) !usize {
    const value = try kvm.ioctl(fd, request, arg, op);
    if (value == 0) return error.RequiredProbeCapabilityMissing;
    return value;
}

const Evidence = struct {
    kernel_release: []const u8,
    capabilities: CapabilityValues,
    raw_cpuid: *const kvm.Cpuid,
    raw_layout: XsaveLayout,
    requested_cpuid: *const kvm.Cpuid,
    requested_layout: XsaveLayout,
    effective_cpuid: *const kvm.Cpuid,
    effective_layout: XsaveLayout,
    feature_entries: []const kvm.MsrEntry,
    feature_msr_get_completed: usize,
    ordinary_msrs: []const kvm.MsrEntry,
    ordinary_msr_get_completed: usize,
    xsave_before: []const u8,
    xsave_after: []const u8,
    uses_xsave2: bool,
    xcrs: *const kvm.Xcrs,
    vm_tsc_khz: usize,
    vcpu_tsc_khz: usize,
    clock_before: kvm.ClockData,
    clock_after: kvm.ClockData,
};

fn writeEvidence(writer: *std.Io.Writer, evidence: Evidence) !void {
    try writer.print("sporevm kvm-profile-probe: version=1 arch=x86_64 no_kvm_run=true cpuid_context=setter_only_no_irqchip candidate_status={s}\n", .{@tagName(cpu_profile.candidate_status)});
    try writer.print("host kernel_release={s} kvm_api={d}\n", .{ evidence.kernel_release, kvm.KVM_API_VERSION });
    try writer.print("capability-extra id={d} name=check_extension_vm system={d} vm_measured={}\n", .{ kvm.KVM_CAP_CHECK_EXTENSION_VM, evidence.capabilities.vm_check_value, evidence.capabilities.vmScoped() });
    try writer.print("capability-extra id={d} name=get_msr_features system={d}\n", .{ kvm.KVM_CAP_GET_MSR_FEATURES, evidence.capabilities.feature_msr_value });
    for (cpu_profile.capability_audit_inventory, evidence.capabilities.system, evidence.capabilities.vm) |descriptor, system_value, vm_value| {
        if (evidence.capabilities.vmScoped()) {
            try writer.print("capability id={d} name={s} system={d} vm={d}\n", .{ descriptor.id, descriptor.name, system_value, vm_value });
        } else {
            try writer.print("capability id={d} name={s} system={d} vm=unavailable\n", .{ descriptor.id, descriptor.name, system_value });
        }
    }
    try writeCpuid(writer, "raw", evidence.raw_cpuid, evidence.raw_layout);
    try writeCpuid(writer, "requested", evidence.requested_cpuid, evidence.requested_layout);
    try writeCpuid(writer, "effective", evidence.effective_cpuid, evidence.effective_layout);
    try writer.print("msr-feature count={d} completed_get={d} order=canonical\n", .{
        evidence.feature_entries.len,
        evidence.feature_msr_get_completed,
    });
    for (evidence.feature_entries) |entry| {
        try writer.print("msr-feature index=0x{x:0>8} value=0x{x:0>16}\n", .{ entry.index, entry.data });
    }
    for (evidence.ordinary_msrs) |entry| {
        try writer.print("msr-inventory index=0x{x:0>8} value=0x{x:0>16}\n", .{ entry.index, entry.data });
    }
    try writer.print("msr-inventory count={d} completed_get={d} order=canonical write_round_trip=not_attempted context=no_irqchip\n", .{
        evidence.ordinary_msrs.len,
        evidence.ordinary_msr_get_completed,
    });
    const xsave_before_digest = sha256(evidence.xsave_before);
    const xsave_after_digest = sha256(evidence.xsave_after);
    try writer.print("xsave mode={s} size={d} before_sha256={s} after_sha256={s} equal=true\n", .{ if (evidence.uses_xsave2) "xsave2" else "legacy", evidence.xsave_before.len, &xsave_before_digest, &xsave_after_digest });
    try writer.print("xcrs count={d} flags=0x{x}\n", .{ evidence.xcrs.nr_xcrs, evidence.xcrs.flags });
    for (evidence.xcrs.xcrs[0..evidence.xcrs.nr_xcrs]) |entry| {
        try writer.print("xcr index={d} value=0x{x}\n", .{ entry.xcr, entry.value });
    }
    try writer.print("tsc vm_khz={d} vcpu_khz={d} vm_set_get_equal=true vcpu_inherited=true vcpu_set_get_equal=true\n", .{ evidence.vm_tsc_khz, evidence.vcpu_tsc_khz });
    try writer.print("clock before={d} after={d} flags_before=0x{x} flags_after=0x{x} realtime_before={d} realtime_after={d} host_tsc_before={d} host_tsc_after={d} nondecreasing=true\n", .{
        evidence.clock_before.clock,
        evidence.clock_after.clock,
        evidence.clock_before.flags,
        evidence.clock_after.flags,
        evidence.clock_before.realtime,
        evidence.clock_after.realtime,
        evidence.clock_before.host_tsc,
        evidence.clock_after.host_tsc,
    });
    try writer.writeAll("result reset_inventory=pass profile_approved=false\n");
}

fn writeCpuid(writer: *std.Io.Writer, label: []const u8, cpuid: *const kvm.Cpuid, layout: XsaveLayout) !void {
    try writer.print("cpuid-set kind={s} order=canonical count={d}\n", .{ label, cpuid.nent });
    for (cpuid.entries[0..cpuid.nent]) |entry| {
        try writeCpuidEntry(writer, label, entry);
    }
    try writer.print("xsave-layout kind={s} supported_xcr0=0x{x} supported_xss=0x{x} enabled_bytes={d} maximum_bytes={d} components={d} supervisor_components={d} maximum_component_end={d}\n", .{
        label,
        layout.supported_xcr0,
        layout.supported_xss,
        layout.enabled_bytes,
        layout.maximum_bytes,
        layout.component_count,
        layout.supervisor_component_count,
        layout.maximum_component_end,
    });
}

fn writeCpuidEntry(writer: *std.Io.Writer, label: []const u8, entry: kvm.CpuidEntry) !void {
    try writer.print("cpuid kind={s} function=0x{x:0>8} index=0x{x:0>8} flags=0x{x:0>8} eax=0x{x:0>8} ebx=0x{x:0>8} ecx=0x{x:0>8} edx=0x{x:0>8}\n", .{
        label,
        entry.function,
        entry.index,
        entry.flags,
        entry.eax,
        entry.ebx,
        entry.ecx,
        entry.edx,
    });
}

fn sha256(bytes: []const u8) [Sha256.digest_length * 2]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "profile probe canonicalizes bounded CPUID and rejects duplicate selectors" {
    var cpuid = kvm.Cpuid{ .nent = 3 };
    cpuid.entries[0] = .{ .function = 0xd, .index = 2, .eax = 0x100, .ebx = 0x240 };
    cpuid.entries[1] = .{ .function = 0xd, .index = 0, .eax = 7, .ebx = 0x340, .ecx = 0x340 };
    cpuid.entries[2] = .{ .function = 1 };
    try canonicalizeCpuid(&cpuid);
    try std.testing.expectEqual(@as(u32, 1), cpuid.entries[0].function);
    try std.testing.expectEqual(@as(u32, 0), cpuid.entries[1].index);
    try std.testing.expectEqual(@as(u32, 2), cpuid.entries[2].index);
    const layout = try validateXsaveLayout(&cpuid);
    try std.testing.expectEqual(@as(u64, 7), layout.supported_xcr0);
    try std.testing.expectEqual(@as(u32, 0x340), layout.maximum_component_end);

    cpuid.entries[2] = cpuid.entries[1];
    try std.testing.expectError(error.DuplicateCpuidSelector, canonicalizeCpuid(&cpuid));
}

test "profile probe rejects malformed leaf D bounds" {
    var cpuid = kvm.Cpuid{ .nent = 2 };
    cpuid.entries[0] = .{ .function = 0xd, .index = 0, .eax = 7, .ebx = 576, .ecx = 700 };
    cpuid.entries[1] = .{ .function = 0xd, .index = 2, .eax = 200, .ebx = 600 };
    try std.testing.expectError(error.MalformedXsaveLayout, validateXsaveLayout(&cpuid));

    cpuid.entries[0].ecx = 1024;
    cpuid.entries[1] = .{ .function = 0xd, .index = 2, .eax = 128, .ebx = 512 };
    try std.testing.expectError(error.MalformedXsaveLayout, validateXsaveLayout(&cpuid));

    cpuid.nent = 3;
    cpuid.entries[1] = .{ .function = 0xd, .index = 2, .eax = 128, .ebx = 576 };
    cpuid.entries[2] = .{ .function = 0xd, .index = 3, .eax = 64, .ebx = 640 };
    try std.testing.expectError(error.MalformedXsaveLayout, validateXsaveLayout(&cpuid));

    cpuid.entries[2].ebx = 704;
    const layout = try validateXsaveLayout(&cpuid);
    try std.testing.expectError(error.MalformedXsaveLayout, validateKvmXsaveSize(layout, 1023));
    try validateKvmXsaveSize(layout, 1024);

    var supervisor_cpuid = kvm.Cpuid{ .nent = 3 };
    supervisor_cpuid.entries[0] = .{ .function = 0xd, .index = 0, .eax = 7, .ebx = 576, .ecx = 576 };
    supervisor_cpuid.entries[1] = .{ .function = 0xd, .index = 1, .ecx = 1 << 11 };
    supervisor_cpuid.entries[2] = .{ .function = 0xd, .index = 11, .eax = 64, .ebx = 0, .ecx = 1 };
    const supervisor_layout = try validateXsaveLayout(&supervisor_cpuid);
    try std.testing.expectEqual(@as(u64, 1 << 11), supervisor_layout.supported_xss);
    try std.testing.expectEqual(@as(u32, 1), supervisor_layout.supervisor_component_count);
    supervisor_cpuid.entries[1].ecx = 0;
    try std.testing.expectError(error.MalformedXsaveLayout, validateXsaveLayout(&supervisor_cpuid));
}

test "profile probe canonicalizes completed MSR inventory" {
    var entries = [_]kvm.MsrEntry{
        .{ .index = 0x3b, .data = 3 },
        .{ .index = 0x10, .data = 1 },
        .{ .index = 0x11, .data = 2 },
    };
    try canonicalizeMsrEntries(&entries);
    try std.testing.expectEqual(@as(u32, 0x10), entries[0].index);
    try std.testing.expectEqual(@as(u64, 1), entries[0].data);
    try std.testing.expectEqual(@as(u32, 0x3b), entries[2].index);
    entries[2].index = entries[1].index;
    try std.testing.expectError(error.DuplicateMsrIndex, canonicalizeMsrEntries(&entries));
}

test "profile probe validates reset clock and XCR bounds" {
    try validateClockRoundTrip(.{ .clock = 100 }, .{ .clock = 101 });
    try std.testing.expectError(error.ClockMovedBackwards, validateClockRoundTrip(.{ .clock = 100 }, .{ .clock = 99 }));
    try std.testing.expectError(
        error.ClockMovedBackwards,
        validateClockRoundTrip(
            .{ .clock = 100, .flags = kvm.KVM_CLOCK_REALTIME, .realtime = 1000 },
            .{ .clock = 101, .flags = kvm.KVM_CLOCK_REALTIME, .realtime = 999 },
        ),
    );
    try std.testing.expectError(
        error.ClockMovedBackwards,
        validateClockRoundTrip(
            .{ .clock = 100, .flags = kvm.KVM_CLOCK_HOST_TSC, .host_tsc = 1000 },
            .{ .clock = 101, .flags = kvm.KVM_CLOCK_HOST_TSC, .host_tsc = 999 },
        ),
    );

    var xcrs = kvm.Xcrs{ .nr_xcrs = 1 };
    xcrs.xcrs[0] = .{ .xcr = 0, .value = 1 };
    try validateXcrs(&xcrs);
    xcrs.nr_xcrs = kvm.max_xcrs + 1;
    try std.testing.expectError(error.XcrsTooLarge, validateXcrs(&xcrs));
    xcrs.nr_xcrs = 1;
    xcrs.xcrs[0].reserved = 1;
    try std.testing.expectError(error.XcrsTooLarge, validateXcrs(&xcrs));
    xcrs.nr_xcrs = 2;
    xcrs.xcrs[0] = .{ .xcr = 1, .value = 1 };
    xcrs.xcrs[1] = .{ .xcr = 0, .value = 1 };
    try std.testing.expectError(error.XcrsTooLarge, validateXcrs(&xcrs));
    xcrs.xcrs[1].xcr = 1;
    try std.testing.expectError(error.XcrsTooLarge, validateXcrs(&xcrs));
}

test "profile probe CPUID evidence format is exact" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeCpuidEntry(&writer, "raw", .{
        .function = 0x0d,
        .index = 2,
        .flags = 1,
        .eax = 0x100,
        .ebx = 0x240,
        .ecx = 0,
        .edx = 0,
    });
    try std.testing.expectEqualStrings(
        "cpuid kind=raw function=0x0000000d index=0x00000002 flags=0x00000001 eax=0x00000100 ebx=0x00000240 ecx=0x00000000 edx=0x00000000\n",
        writer.buffered(),
    );
}
