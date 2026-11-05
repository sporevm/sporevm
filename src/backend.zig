//! Compile-time backend selection and internal product-runner availability.
//!
//! Resolution is a pure function of the requested backend and a `Host`.
//! `Host.probe` is the only code here that touches the host; command entry
//! points call it once and pass the result in.

const std = @import("std");
const builtin = @import("builtin");
const architecture = @import("architecture.zig");
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
    IncompatibleCpuProfile,
    KvmProbeFailed,
};

pub const UnavailableReason = union(enum) {
    unsupported_host,
    missing_dev_kvm,
    kvm_open_failed,
    incompatible_cpu_profile,
    kvm_probe_failed,

    pub fn toError(self: UnavailableReason) Error {
        return switch (self) {
            .unsupported_host => error.UnsupportedBackend,
            .missing_dev_kvm => error.MissingKvmDevice,
            .kvm_open_failed => error.KvmOpenFailed,
            .incompatible_cpu_profile => error.IncompatibleCpuProfile,
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
/// Only the fresh, fixed-memory x86 runner is public; feature-specific gates
/// remain in the run and lifecycle entry points.
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

fn inspectX86Kvm() ?UnavailableReason {
    if (std.c.access("/dev/kvm", 0) != 0) return .missing_dev_kvm;
    const fd = x86_kvm.openDevKvm() catch return .kvm_open_failed;
    defer _ = std.c.close(fd);
    x86_product_preflight.require(fd, 1) catch |err| return switch (err) {
        error.IncompatibleCpuProfile => .incompatible_cpu_profile,
        else => .kvm_probe_failed,
    };
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
    try std.testing.expectEqual(error.IncompatibleCpuProfile, @as(UnavailableReason, .incompatible_cpu_profile).toError());
    try std.testing.expectEqual(error.KvmProbeFailed, @as(UnavailableReason, .kvm_probe_failed).toError());
}
