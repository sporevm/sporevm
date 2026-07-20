//! Guest CPU topology helpers.
//!
//! This module is the shared contract for user-requested vCPU counts and
//! architecture-neutral vCPU indices.

const std = @import("std");

pub const VcpuCount = u32;
pub const VcpuIndex = u32;

/// First product ceiling while backend and manifest support lands in slices.
pub const max_vcpus: VcpuCount = 8;

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
