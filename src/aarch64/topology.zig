//! AArch64 vCPU identity helpers.

const std = @import("std");
const topology = @import("../topology.zig");

pub const Mpidr = u64;
pub const boot_mpidr_res1: Mpidr = 0x8000_0000;

pub fn mpidrForIndex(index: topology.VcpuIndex) Mpidr {
    return boot_mpidr_res1 | @as(Mpidr, index);
}

test "maps vcpu index to normalized MPIDR" {
    try std.testing.expectEqual(@as(Mpidr, 0x8000_0000), mpidrForIndex(0));
    try std.testing.expectEqual(@as(Mpidr, 0x8000_0001), mpidrForIndex(1));
}
