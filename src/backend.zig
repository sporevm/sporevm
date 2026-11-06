//! Backend selection and the host probe.
//!
//! `resolve` is a pure function of the requested backend, OS and
//! architecture. `Host.probe` is the only code here that touches the host:
//! commands that start a fresh VM probe once, `select` against the result
//! and pass the selected backend down, and host-info renders the same result.

const std = @import("std");
const builtin = @import("builtin");
const x86_product_preflight = @import("x86_64/product_preflight.zig");
const kvm_common = @import("kvm/common.zig");

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

    /// Resolve for the build target without probing the host.
    pub fn resolveForHost(self: Backend) error{UnsupportedBackend}!Backend {
        return resolve(self, builtin.os.tag, builtin.cpu.arch);
    }
};

/// The backend `requested` names on `os`/`arch`: HVF on macOS arm64, KVM on
/// Linux arm64 and x86_64, and `auto` prefers HVF.
pub fn resolve(requested: Backend, os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) error{UnsupportedBackend}!Backend {
    const hvf = os == .macos and arch == .aarch64;
    const kvm = os == .linux and (arch == .aarch64 or arch == .x86_64);
    return switch (requested) {
        .auto => if (hvf) .hvf else if (kvm) .kvm else error.UnsupportedBackend,
        .hvf => if (hvf) .hvf else error.UnsupportedBackend,
        .kvm => if (kvm) .kvm else error.UnsupportedBackend,
    };
}

pub const Error = error{
    UnsupportedBackend,
    MissingKvmDevice,
    KvmOpenFailed,
    IncompatibleCpuProfile,
    KvmProbeFailed,
};

pub const UnavailableReason = enum {
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

pub const Availability = union(enum) {
    available: Backend,
    unavailable: UnavailableReason,
};

/// The OS, architecture, and probed hypervisor facts that availability
/// depends on. The defaults describe the build target with every probed
/// capability present.
pub const Host = struct {
    os: std.Target.Os.Tag = builtin.os.tag,
    arch: std.Target.Cpu.Arch = builtin.cpu.arch,
    /// Why KVM cannot run the product here, or null when it can.
    kvm_unavailable: ?UnavailableReason = null,

    /// Probe the running host. Only Linux opens `/dev/kvm`; on x86_64 the
    /// probe also checks the approved CPU profile with a throwaway VM.
    pub fn probe() Host {
        if (comptime builtin.os.tag == .linux) return .{ .kvm_unavailable = probeKvm() };
        return .{};
    }
};

pub fn availability(requested: Backend, host: Host) Availability {
    const selected = resolve(requested, host.os, host.arch) catch return .{ .unavailable = .unsupported_host };
    if (selected == .kvm) if (host.kvm_unavailable) |reason| return .{ .unavailable = reason };
    return .{ .available = selected };
}

/// Resolve `requested` and require the probed host to provide it. Commands
/// that start a fresh VM call this once with `Host.probe()` before any
/// artifact, disk, or VM work, then pass the selected backend down.
pub fn select(requested: Backend, host: Host) Error!Backend {
    return switch (availability(requested, host)) {
        .available => |selected| selected,
        .unavailable => |reason| reason.toError(),
    };
}

fn probeKvm() ?UnavailableReason {
    if (std.c.access("/dev/kvm", 0) != 0) return .missing_dev_kvm;
    const fd = kvm_common.openDevKvm(.{ .close_on_exec = true }) catch return .kvm_open_failed;
    defer _ = std.c.close(fd);
    if (comptime builtin.cpu.arch == .x86_64) {
        x86_product_preflight.require(fd, 1) catch |err| return switch (err) {
            error.IncompatibleCpuProfile => .incompatible_cpu_profile,
            else => .kvm_probe_failed,
        };
    }
    return null;
}

test "resolve maps each request to a backend from the OS and architecture alone" {
    const Case = struct { Backend, std.Target.Os.Tag, std.Target.Cpu.Arch, ?Backend };
    const cases = [_]Case{
        .{ .auto, .macos, .aarch64, .hvf },
        .{ .hvf, .macos, .aarch64, .hvf },
        .{ .kvm, .macos, .aarch64, null },
        .{ .auto, .linux, .aarch64, .kvm },
        .{ .hvf, .linux, .aarch64, null },
        .{ .kvm, .linux, .aarch64, .kvm },
        .{ .auto, .linux, .x86_64, .kvm },
        .{ .hvf, .linux, .x86_64, null },
        .{ .kvm, .linux, .x86_64, .kvm },
        .{ .auto, .macos, .x86_64, null },
        .{ .hvf, .macos, .x86_64, null },
        .{ .auto, .linux, .riscv64, null },
        .{ .kvm, .linux, .riscv64, null },
        .{ .auto, .windows, .x86_64, null },
    };
    for (cases) |case| {
        const requested, const os, const arch, const expected = case;
        if (expected) |backend| {
            try std.testing.expectEqual(backend, try resolve(requested, os, arch));
        } else {
            try std.testing.expectError(error.UnsupportedBackend, resolve(requested, os, arch));
        }
    }
}

test "select reports the probed KVM fact only when KVM is selected" {
    const x86_linux = Host{ .os = .linux, .arch = .x86_64 };
    const arm_linux = Host{ .os = .linux, .arch = .aarch64 };
    const arm_macos = Host{ .os = .macos, .arch = .aarch64 };
    try std.testing.expectEqual(Backend.kvm, try select(.auto, x86_linux));
    try std.testing.expectEqual(Backend.kvm, try select(.auto, arm_linux));
    try std.testing.expectEqual(Backend.hvf, try select(.auto, arm_macos));
    try std.testing.expectError(error.UnsupportedBackend, select(.hvf, x86_linux));
    try std.testing.expectError(error.UnsupportedBackend, select(.auto, .{ .os = .macos, .arch = .x86_64 }));

    for ([_]Host{ x86_linux, arm_linux }) |linux| {
        var without_kvm = linux;
        without_kvm.kvm_unavailable = .missing_dev_kvm;
        try std.testing.expectError(error.MissingKvmDevice, select(.auto, without_kvm));
        try std.testing.expectError(error.MissingKvmDevice, select(.kvm, without_kvm));
        // A missing backend outranks the probe: HVF is not on Linux at all.
        try std.testing.expectError(error.UnsupportedBackend, select(.hvf, without_kvm));
    }

    var macos_with_kvm_fact = arm_macos;
    macos_with_kvm_fact.kvm_unavailable = .missing_dev_kvm;
    try std.testing.expectEqual(Backend.hvf, try select(.auto, macos_with_kvm_fact));
}

test "availability reasons map to explicit product errors" {
    try std.testing.expectEqual(error.UnsupportedBackend, UnavailableReason.unsupported_host.toError());
    try std.testing.expectEqual(error.MissingKvmDevice, UnavailableReason.missing_dev_kvm.toError());
    try std.testing.expectEqual(error.KvmOpenFailed, UnavailableReason.kvm_open_failed.toError());
    try std.testing.expectEqual(error.IncompatibleCpuProfile, UnavailableReason.incompatible_cpu_profile.toError());
    try std.testing.expectEqual(error.KvmProbeFailed, UnavailableReason.kvm_probe_failed.toError());
}
