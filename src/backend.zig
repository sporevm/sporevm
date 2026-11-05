//! Compile-time backend selection and internal product-runner availability.
//!
//! Resolution is a pure function of the requested backend and a `Host`.
//! `Host.probe` is the only code here that touches the host; command entry
//! points call it once and pass the result in.

const std = @import("std");
const builtin = @import("builtin");
const architecture = @import("architecture.zig");
const x86_cpu_profile = @import("x86_64/cpu_profile.zig");
const x86_product_preflight = @import("x86_64/product_preflight.zig");
const x86_kvm = @import("kvm/x86_64.zig");

pub const Backend = enum {
    auto,
    hvf,
    kvm,

    pub fn parse(raw: []const u8) ?Backend {
        if (std.mem.eql(u8, raw, "auto")) return .auto;
        if (std.mem.eql(u8, raw, "hvf")) return .hvf;
        if (std.mem.eql(u8, raw, "kvm")) return .kvm;
        return null;
    }

    pub fn name(self: Backend) []const u8 {
        return @tagName(self);
    }

    pub fn supportedOnHost(self: Backend) bool {
        return productSupportedOn(self, builtin.os.tag, builtin.cpu.arch);
    }

    /// Resolve for the build target without probing the host. Code below the
    /// command entry points uses this for policy checks; resume and capture
    /// paths need no probe because x86 rejects them by policy.
    pub fn resolveForHost(self: Backend) error{UnsupportedBackend}!Backend {
        return resolveProductFor(self, builtin.os.tag, builtin.cpu.arch);
    }
};

pub const Error = error{
    UnsupportedBackend,
    MissingKvmDevice,
    KvmOpenFailed,
    ApiVersionMismatch,
    KvmCapabilityMissing,
    KvmProbeFailed,
};

pub const MissingCapability = struct {
    name: []const u8,
    id: u32,
};

pub const ApiVersion = struct {
    got: usize,
    want: usize,
};

pub const UnavailableReason = union(enum) {
    unsupported_host,
    missing_dev_kvm,
    kvm_open_failed,
    api_version_mismatch: ApiVersion,
    missing_capability: MissingCapability,
    kvm_probe_failed,

    pub fn toError(self: UnavailableReason) Error {
        return switch (self) {
            .unsupported_host => error.UnsupportedBackend,
            .missing_dev_kvm => error.MissingKvmDevice,
            .kvm_open_failed => error.KvmOpenFailed,
            .api_version_mismatch => error.ApiVersionMismatch,
            .missing_capability => error.KvmCapabilityMissing,
            .kvm_probe_failed => error.KvmProbeFailed,
        };
    }
};

pub const Unavailable = struct {
    selected: ?Backend,
    reason: UnavailableReason,
};

pub const Availability = union(enum) {
    available: Backend,
    unavailable: Unavailable,
};

fn unavailable(selected: ?Backend, reason: UnavailableReason) Availability {
    return .{ .unavailable = .{ .selected = selected, .reason = reason } };
}

/// The OS, architecture, and probed hypervisor facts that availability
/// depends on. The defaults describe the build target with every probed
/// capability present.
pub const Host = struct {
    os: std.Target.Os.Tag = builtin.os.tag,
    arch: std.Target.Cpu.Arch = builtin.cpu.arch,
    /// Why Linux/x86_64 KVM cannot run the product, or null when it can.
    x86_kvm_unavailable: ?UnavailableReason = null,

    /// Probe the running host. Only Linux/x86_64 reads `/dev/kvm`.
    pub fn probe() Host {
        if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
            return .{ .x86_kvm_unavailable = inspectX86Kvm() };
        }
        return .{};
    }
};

pub fn availability(requested: Backend, host: Host) Availability {
    const selected = resolveBindingFor(requested, host.os, host.arch) catch return unavailable(null, .unsupported_host);
    if (!bindingSupportedOn(selected, host.os, host.arch)) return unavailable(selected, .unsupported_host);
    if (selected == .kvm and host.arch == .x86_64) {
        if (host.x86_kvm_unavailable) |reason| return unavailable(.kvm, reason);
    }
    return .{ .available = selected };
}

/// Resolve the requested backend before any artifact, disk, or VM work.
/// Command entry points that start a fresh VM call this once with
/// `Host.probe()`, so Linux/x86_64 reaches the reviewed KVM probe before
/// product setup. Code below them resolves with `Backend.resolveForHost`.
/// Slice 3a makes only the fresh, fixed-memory runner public;
/// feature-specific gates remain in the run and lifecycle entry points.
pub fn requireProductRunner(requested: Backend, host: Host) Error!Backend {
    return switch (availability(requested, host)) {
        .available => |selected| selected,
        .unavailable => |result| result.reason.toError(),
    };
}

fn productSupportedOn(backend: Backend, os: std.Target.Os.Tag, zig_arch: std.Target.Cpu.Arch) bool {
    return bindingSupportedOn(backend, os, zig_arch);
}

fn resolveProductFor(backend: Backend, os: std.Target.Os.Tag, zig_arch: std.Target.Cpu.Arch) error{UnsupportedBackend}!Backend {
    const selected = try resolveBindingFor(backend, os, zig_arch);
    if (!productSupportedOn(selected, os, zig_arch)) return error.UnsupportedBackend;
    return selected;
}

fn bindingSupportedOn(backend: Backend, os: std.Target.Os.Tag, zig_arch: std.Target.Cpu.Arch) bool {
    const arch = architecture.fromTarget(zig_arch) orelse return false;
    return switch (backend) {
        .auto => bindingSupportedOn(.hvf, os, zig_arch) or bindingSupportedOn(.kvm, os, zig_arch),
        .hvf => os == .macos and arch == .arm64,
        .kvm => os == .linux,
    };
}

fn resolveBindingFor(backend: Backend, os: std.Target.Os.Tag, zig_arch: std.Target.Cpu.Arch) error{UnsupportedBackend}!Backend {
    if (backend != .auto) return backend;
    if (bindingSupportedOn(.hvf, os, zig_arch)) return .hvf;
    if (bindingSupportedOn(.kvm, os, zig_arch)) return .kvm;
    return error.UnsupportedBackend;
}

pub const X86ProbeSnapshot = struct {
    dev_kvm_present: bool = true,
    open_succeeded: bool = true,
    api_version: ?usize = null,
    capability_values: [x86_cpu_profile.required_capabilities.len]?usize = @splat(null),

    pub fn supported() X86ProbeSnapshot {
        var snapshot = X86ProbeSnapshot{ .api_version = x86_kvm.KVM_API_VERSION };
        for (x86_cpu_profile.required_capabilities, &snapshot.capability_values) |requirement, *value| {
            value.* = @max(requirement.minimum, requirement.required_bits);
        }
        return snapshot;
    }
};

pub fn classifyX86Probe(snapshot: X86ProbeSnapshot) ?UnavailableReason {
    if (!snapshot.dev_kvm_present) return .missing_dev_kvm;
    if (!snapshot.open_succeeded) return .kvm_open_failed;
    const api_version = snapshot.api_version orelse return .kvm_probe_failed;
    if (api_version != x86_kvm.KVM_API_VERSION) {
        return .{ .api_version_mismatch = .{ .got = api_version, .want = x86_kvm.KVM_API_VERSION } };
    }
    for (x86_cpu_profile.required_capabilities, snapshot.capability_values) |descriptor, value| {
        const capability = value orelse return .kvm_probe_failed;
        if (capability < descriptor.minimum or (descriptor.required_bits != 0 and capability & descriptor.required_bits != descriptor.required_bits)) {
            return .{ .missing_capability = .{ .name = descriptor.name, .id = descriptor.id } };
        }
    }
    return null;
}

fn inspectX86Kvm() ?UnavailableReason {
    var snapshot = X86ProbeSnapshot{};
    if (std.c.access("/dev/kvm", 0) != 0) {
        snapshot.dev_kvm_present = false;
        return classifyX86Probe(snapshot);
    }
    const fd = x86_kvm.openDevKvm() catch {
        snapshot.open_succeeded = false;
        return classifyX86Probe(snapshot);
    };
    defer _ = std.c.close(fd);

    snapshot.api_version = x86_kvm.ioctl(fd, x86_kvm.KVM_GET_API_VERSION, 0, "KVM_GET_API_VERSION") catch null;
    if (snapshot.api_version == null or snapshot.api_version.? != x86_kvm.KVM_API_VERSION) {
        return classifyX86Probe(snapshot);
    }
    for (x86_cpu_profile.required_capabilities, 0..) |descriptor, index| {
        snapshot.capability_values[index] = x86_kvm.checkExtension(fd, descriptor.id) catch null;
        if (snapshot.capability_values[index] == null or snapshot.capability_values[index].? == 0) {
            return classifyX86Probe(snapshot);
        }
    }
    if (classifyX86Probe(snapshot)) |reason| return reason;
    x86_product_preflight.requireCompatible(fd, 1) catch return .kvm_probe_failed;
    return null;
}

test "public product readiness includes probed x86 KVM" {
    try std.testing.expect(bindingSupportedOn(.hvf, .macos, .aarch64));
    try std.testing.expect(!bindingSupportedOn(.kvm, .macos, .aarch64));
    try std.testing.expect(bindingSupportedOn(.kvm, .linux, .aarch64));
    try std.testing.expect(bindingSupportedOn(.kvm, .linux, .x86_64));
    try std.testing.expect(!bindingSupportedOn(.auto, .linux, .riscv64));

    try std.testing.expect(productSupportedOn(.hvf, .macos, .aarch64));
    try std.testing.expect(productSupportedOn(.kvm, .linux, .aarch64));
    try std.testing.expect(productSupportedOn(.auto, .linux, .x86_64));
    try std.testing.expect(productSupportedOn(.kvm, .linux, .x86_64));

    try std.testing.expectEqual(Backend.hvf, try resolveProductFor(.auto, .macos, .aarch64));
    try std.testing.expectEqual(Backend.kvm, try resolveProductFor(.auto, .linux, .aarch64));
    try std.testing.expectEqual(Backend.kvm, try resolveProductFor(.auto, .linux, .x86_64));
    try std.testing.expectEqual(Backend.kvm, try resolveProductFor(.kvm, .linux, .x86_64));
    try std.testing.expectError(error.UnsupportedBackend, resolveProductFor(.hvf, .linux, .aarch64));
    try std.testing.expectError(error.UnsupportedBackend, resolveProductFor(.kvm, .macos, .aarch64));

    try std.testing.expectEqual(Backend.hvf, try resolveBindingFor(.auto, .macos, .aarch64));
    try std.testing.expectEqual(Backend.kvm, try resolveBindingFor(.auto, .linux, .aarch64));
    try std.testing.expectEqual(Backend.kvm, try resolveBindingFor(.auto, .linux, .x86_64));
    try std.testing.expectError(error.UnsupportedBackend, resolveBindingFor(.auto, .macos, .x86_64));

    if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
        try std.testing.expect(Backend.auto.supportedOnHost());
        try std.testing.expect(Backend.kvm.supportedOnHost());
        try std.testing.expectEqual(Backend.kvm, try Backend.auto.resolveForHost());
        try std.testing.expectEqual(Backend.kvm, try Backend.kvm.resolveForHost());
    }
}

test "x86 KVM probe reasons fail closed in stable order" {
    try std.testing.expectEqual(UnavailableReason.missing_dev_kvm, classifyX86Probe(.{ .dev_kvm_present = false }).?);
    try std.testing.expectEqual(UnavailableReason.kvm_open_failed, classifyX86Probe(.{ .open_succeeded = false }).?);
    try std.testing.expectEqual(UnavailableReason.kvm_probe_failed, classifyX86Probe(.{ .api_version = null }).?);

    const api_mismatch = classifyX86Probe(.{ .api_version = 11 }).?;
    try std.testing.expectEqual(ApiVersion{ .got = 11, .want = 12 }, api_mismatch.api_version_mismatch);

    for (x86_cpu_profile.required_capabilities, 0..) |descriptor, index| {
        var snapshot = X86ProbeSnapshot.supported();
        snapshot.capability_values[index] = 0;
        const reason = classifyX86Probe(snapshot).?;
        try std.testing.expectEqual(descriptor.id, reason.missing_capability.id);
        try std.testing.expectEqualStrings(descriptor.name, reason.missing_capability.name);

        snapshot.capability_values[index] = null;
        try std.testing.expectEqual(UnavailableReason.kvm_probe_failed, classifyX86Probe(snapshot).?);
    }

    try std.testing.expectEqual(@as(?UnavailableReason, null), classifyX86Probe(X86ProbeSnapshot.supported()));
}

test "product runner resolution depends only on the request and host facts" {
    const x86_linux = Host{ .os = .linux, .arch = .x86_64 };
    const arm_linux = Host{ .os = .linux, .arch = .aarch64 };
    try std.testing.expectEqual(Backend.kvm, try requireProductRunner(.auto, x86_linux));
    try std.testing.expectEqual(Backend.kvm, try requireProductRunner(.auto, arm_linux));
    try std.testing.expectEqual(Backend.hvf, try requireProductRunner(.auto, .{ .os = .macos, .arch = .aarch64 }));
    try std.testing.expectError(error.UnsupportedBackend, requireProductRunner(.hvf, x86_linux));
    try std.testing.expectError(error.UnsupportedBackend, requireProductRunner(.auto, .{ .os = .macos, .arch = .x86_64 }));

    var x86_without_kvm = x86_linux;
    x86_without_kvm.x86_kvm_unavailable = .missing_dev_kvm;
    try std.testing.expectError(error.MissingKvmDevice, requireProductRunner(.auto, x86_without_kvm));
    try std.testing.expectError(error.MissingKvmDevice, requireProductRunner(.kvm, x86_without_kvm));
    try std.testing.expectEqual(Unavailable{ .selected = .kvm, .reason = .missing_dev_kvm }, availability(.kvm, x86_without_kvm).unavailable);

    var arm_with_x86_fact = arm_linux;
    arm_with_x86_fact.x86_kvm_unavailable = .missing_dev_kvm;
    try std.testing.expectEqual(Backend.kvm, try requireProductRunner(.auto, arm_with_x86_fact));
}

test "availability reasons map to explicit product errors" {
    try std.testing.expectEqual(error.UnsupportedBackend, @as(UnavailableReason, .unsupported_host).toError());
    try std.testing.expectEqual(error.MissingKvmDevice, @as(UnavailableReason, .missing_dev_kvm).toError());
    try std.testing.expectEqual(error.KvmOpenFailed, @as(UnavailableReason, .kvm_open_failed).toError());
    try std.testing.expectEqual(error.ApiVersionMismatch, (UnavailableReason{ .api_version_mismatch = .{ .got = 11, .want = 12 } }).toError());
    try std.testing.expectEqual(error.KvmCapabilityMissing, (UnavailableReason{ .missing_capability = .{ .name = "irqchip", .id = 0 } }).toError());
    try std.testing.expectEqual(error.KvmProbeFailed, @as(UnavailableReason, .kvm_probe_failed).toError());
}
