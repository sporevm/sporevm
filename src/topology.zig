//! Guest CPU topology helpers.
//!
//! This module is the shared contract for user-requested vCPU counts and the
//! normalized aarch64 CPU identity SporeVM exposes to guest and manifest code.

const std = @import("std");

pub const VcpuCount = u32;
pub const VcpuIndex = u32;
pub const Mpidr = u64;

/// First product ceiling while backend and manifest support lands in slices.
pub const max_vcpus: VcpuCount = 8;
pub const boot_mpidr_res1: Mpidr = 0x8000_0000;

pub fn validateVcpuCount(count: VcpuCount) !void {
    if (count == 0 or count > max_vcpus) return error.UnsupportedVcpuCount;
}

pub fn requireSingleVcpu(count: VcpuCount) !void {
    try validateVcpuCount(count);
    if (count != 1) return error.UnsupportedVcpuCount;
}

pub fn parseVcpuCount(raw: []const u8) !VcpuCount {
    const count = std.fmt.parseInt(VcpuCount, raw, 10) catch return error.InvalidVcpuCount;
    if (count == 0) return error.InvalidVcpuCount;
    try validateVcpuCount(count);
    return count;
}

pub fn mpidrForIndex(index: VcpuIndex) Mpidr {
    return boot_mpidr_res1 | @as(Mpidr, index);
}

test "validates vcpu count cap" {
    try validateVcpuCount(1);
    try validateVcpuCount(max_vcpus);
    try std.testing.expectError(error.UnsupportedVcpuCount, validateVcpuCount(0));
    try std.testing.expectError(error.UnsupportedVcpuCount, validateVcpuCount(max_vcpus + 1));
    try std.testing.expectError(error.UnsupportedVcpuCount, requireSingleVcpu(2));
}

test "parses vcpu counts" {
    try std.testing.expectEqual(@as(VcpuCount, 2), try parseVcpuCount("2"));
    try std.testing.expectError(error.InvalidVcpuCount, parseVcpuCount("0"));
    try std.testing.expectError(error.InvalidVcpuCount, parseVcpuCount("many"));
    try std.testing.expectError(error.UnsupportedVcpuCount, parseVcpuCount("9"));
}

test "maps vcpu index to normalized mpidr" {
    try std.testing.expectEqual(@as(Mpidr, 0x8000_0000), mpidrForIndex(0));
    try std.testing.expectEqual(@as(Mpidr, 0x8000_0001), mpidrForIndex(1));
}
