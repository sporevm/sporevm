//! Public resource vocabulary shared by inspection and lifecycle results.

const saved_spore_ownership = @import("saved_spore_ownership.zig");

pub const Type = enum {
    live_vm,
    checkpoint,
    image,
    bundle,
};

pub const Portability = enum {
    host_local,
    portable,
    batch_relative,
};

pub fn portabilityForOwnership(ownership: []const u8) Portability {
    if (std.mem.eql(u8, ownership, saved_spore_ownership.machine_local_pinned)) return .host_local;
    if (std.mem.eql(u8, ownership, saved_spore_ownership.batch_relative)) return .batch_relative;
    return .portable;
}

const std = @import("std");

test "saved-spore ownership maps to public portability" {
    try std.testing.expectEqual(Portability.host_local, portabilityForOwnership(saved_spore_ownership.machine_local_pinned));
    try std.testing.expectEqual(Portability.portable, portabilityForOwnership(saved_spore_ownership.portable_self_contained));
    try std.testing.expectEqual(Portability.batch_relative, portabilityForOwnership(saved_spore_ownership.batch_relative));
}
