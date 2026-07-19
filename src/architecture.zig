//! Product and backend architecture vocabulary.
//!
//! Product-facing values use OCI names. Backend names stay confined to the
//! runtime-selection boundary where they describe machine implementations.

const std = @import("std");

pub const Architecture = enum {
    arm64,
    amd64,

    pub fn parse(raw: []const u8) !Architecture {
        if (std.mem.eql(u8, raw, "arm64")) return .arm64;
        if (std.mem.eql(u8, raw, "amd64")) return .amd64;
        return error.UnsupportedArchitecture;
    }

    pub fn name(self: Architecture) []const u8 {
        return @tagName(self);
    }
};

pub const BackendArchitecture = enum {
    aarch64,
    x86_64,
};

/// Select the machine/backend architecture for one OCI architecture.
/// Keep this switch exhaustive so product callers never translate aliases.
pub fn selectBackend(product: Architecture) BackendArchitecture {
    return switch (product) {
        .arm64 => .aarch64,
        .amd64 => .x86_64,
    };
}

/// Translate Zig's toolchain spelling at the host/build boundary.
pub fn fromTarget(target: std.Target.Cpu.Arch) ?Architecture {
    return switch (target) {
        .aarch64 => .arm64,
        .x86_64 => .amd64,
        else => null,
    };
}

test "product architectures use only OCI names" {
    try std.testing.expectEqual(Architecture.arm64, try Architecture.parse("arm64"));
    try std.testing.expectEqual(Architecture.amd64, try Architecture.parse("amd64"));
    try std.testing.expectEqualStrings("arm64", Architecture.arm64.name());
    try std.testing.expectEqualStrings("amd64", Architecture.amd64.name());
    try std.testing.expectError(error.UnsupportedArchitecture, Architecture.parse("aarch64"));
    try std.testing.expectError(error.UnsupportedArchitecture, Architecture.parse("x86_64"));
}

test "backend selection maps both OCI architectures exhaustively" {
    try std.testing.expectEqual(BackendArchitecture.aarch64, selectBackend(.arm64));
    try std.testing.expectEqual(BackendArchitecture.x86_64, selectBackend(.amd64));
    try std.testing.expectEqual(Architecture.arm64, fromTarget(.aarch64).?);
    try std.testing.expectEqual(Architecture.amd64, fromTarget(.x86_64).?);
}
