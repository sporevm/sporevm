//! Portable GICv3 state used by the spore manifest.
//!
//! This module is deliberately free of hypervisor calls. It defines the
//! architectural distributor/redistributor register subset SporeVM currently
//! captures for a single-vCPU board and validates hostile manifest data before
//! any backend maps it to KVM ioctls or Hypervisor.framework calls.

const std = @import("std");
const board = @import("board.zig");

pub const schema_version: u32 = 0;
pub const hvf_backend_private_format = "hv_gic_state_v0";

pub const StateKind = enum { gicv3, backend_private };
pub const BackendKind = enum { hvf };

pub const MmioReg = struct {
    /// Architectural register offset within the distributor or redistributor frame.
    offset: u32,
    width_bits: u8,
    value: u64,
};

pub const LineLevel = struct {
    intid: u32,
    asserted: bool,
};

pub const GicV3State = struct {
    schema_version: u32 = schema_version,
    dist_regs: []const MmioReg,
    redist_regs: []const MmioReg,
    line_levels: []const LineLevel,
};

pub const BackendPrivateState = struct {
    backend: BackendKind,
    format: []const u8,
    data_b64: []const u8,
};

pub const State = struct {
    kind: StateKind,
    gicv3: ?GicV3State = null,
    backend_private: ?BackendPrivateState = null,
};

pub fn validate(state: State) !void {
    switch (state.kind) {
        .gicv3 => {
            if (state.backend_private != null) return error.PlatformMismatch;
            const g = state.gicv3 orelse return error.PlatformMismatch;
            try validateGicV3(g);
        },
        .backend_private => {
            if (state.gicv3 != null) return error.PlatformMismatch;
            const private = state.backend_private orelse return error.PlatformMismatch;
            try validateBackendPrivate(private);
        },
    }
}

pub fn validateBackendPrivate(private: BackendPrivateState) !void {
    switch (private.backend) {
        .hvf => {
            if (!std.mem.eql(u8, private.format, hvf_backend_private_format)) return error.PlatformMismatch;
        },
    }
    if (private.data_b64.len == 0) return error.PlatformMismatch;
    _ = std.base64.standard.Decoder.calcSizeForSlice(private.data_b64) catch return error.PlatformMismatch;
}

pub fn validateGicV3(state: GicV3State) !void {
    if (state.schema_version != schema_version) return error.PlatformMismatch;
    try validateRegs(state.dist_regs, .distributor);
    try validateRegs(state.redist_regs, .redistributor);
    try validateLineLevels(state.line_levels);
}

const Region = enum { distributor, redistributor };

fn validateRegs(regs: []const MmioReg, region: Region) !void {
    for (regs, 0..) |reg, i| {
        const expected_width = expectedWidth(region, reg.offset) orelse return error.PlatformMismatch;
        if (reg.width_bits != expected_width) return error.PlatformMismatch;
        for (regs[0..i]) |prev| {
            if (prev.offset == reg.offset) return error.PlatformMismatch;
        }
    }
}

fn validateLineLevels(levels: []const LineLevel) !void {
    for (levels, 0..) |level, i| {
        if (level.intid < 16 or level.intid > board.generationIntid()) return error.PlatformMismatch;
        for (levels[0..i]) |prev| {
            if (prev.intid == level.intid) return error.PlatformMismatch;
        }
    }
}

fn expectedWidth(region: Region, offset: u32) ?u8 {
    return switch (region) {
        .distributor => expectedDistWidth(offset),
        .redistributor => expectedRedistWidth(offset),
    };
}

fn expectedDistWidth(offset: u32) ?u8 {
    switch (offset) {
        0x000, // GICD_CTLR
        0x084, // GICD_IGROUPR1
        0x104, // GICD_ISENABLER1
        0x204, // GICD_ISPENDR1
        0x304, // GICD_ISACTIVER1
        0xd04, // GICD_IGRPMODR1
        => return 32,
        else => {},
    }

    if (offset >= 0x420 and offset < 0x440 and offset % 4 == 0) return 32; // GICD_IPRIORITYR 32..63
    if (offset >= 0xc08 and offset < 0xc10 and offset % 4 == 0) return 32; // GICD_ICFGR 32..63

    var intid: u32 = 32;
    while (intid <= board.generationIntid()) : (intid += 1) {
        if (offset == distRouterOffset(intid)) return 64;
    }
    return null;
}

fn expectedRedistWidth(offset: u32) ?u8 {
    switch (offset) {
        0x0000, // GICR_CTLR
        0x0014, // GICR_WAKER
        0x10080, // GICR_IGROUPR0
        0x10100, // GICR_ISENABLER0
        0x10200, // GICR_ISPENDR0
        0x10300, // GICR_ISACTIVER0
        0x10d00, // GICR_IGRPMODR0
        => return 32,
        else => {},
    }

    if (offset >= 0x10400 and offset < 0x10420 and offset % 4 == 0) return 32; // GICR_IPRIORITYR SGI/PPI
    if (offset >= 0x10c00 and offset < 0x10c08 and offset % 4 == 0) return 32; // GICR_ICFGR SGI/PPI
    return null;
}

pub fn distRouterOffset(intid: u32) u32 {
    return 0x6000 + intid * 8;
}

test "validates portable GICv3 subset" {
    var dist = [_]MmioReg{
        .{ .offset = 0x000, .width_bits = 32, .value = 1 },
        .{ .offset = distRouterOffset(32), .width_bits = 64, .value = 0 },
        .{ .offset = distRouterOffset(board.generationIntid()), .width_bits = 64, .value = 0 },
    };
    var redist = [_]MmioReg{
        .{ .offset = 0x10080, .width_bits = 32, .value = 0 },
    };
    var lines = [_]LineLevel{
        .{ .intid = 16, .asserted = false },
        .{ .intid = board.generationIntid(), .asserted = true },
    };
    try validate(.{ .kind = .gicv3, .gicv3 = .{ .dist_regs = &dist, .redist_regs = &redist, .line_levels = &lines } });
}

test "rejects invalid GICv3 state" {
    var bad_width = [_]MmioReg{.{ .offset = 0x000, .width_bits = 64, .value = 0 }};
    try std.testing.expectError(error.PlatformMismatch, validate(.{ .kind = .gicv3, .gicv3 = .{ .dist_regs = &bad_width, .redist_regs = &.{}, .line_levels = &.{} } }));

    var duplicate = [_]MmioReg{
        .{ .offset = 0x084, .width_bits = 32, .value = 0 },
        .{ .offset = 0x084, .width_bits = 32, .value = 0 },
    };
    try std.testing.expectError(error.PlatformMismatch, validate(.{ .kind = .gicv3, .gicv3 = .{ .dist_regs = &duplicate, .redist_regs = &.{}, .line_levels = &.{} } }));

    var sgi_line = [_]LineLevel{.{ .intid = 15, .asserted = false }};
    try std.testing.expectError(error.PlatformMismatch, validate(.{ .kind = .gicv3, .gicv3 = .{ .dist_regs = &.{}, .redist_regs = &.{}, .line_levels = &sgi_line } }));

    try std.testing.expectError(error.PlatformMismatch, validate(.{ .kind = .gicv3, .backend_private = .{ .backend = .hvf, .format = hvf_backend_private_format, .data_b64 = "AAAA" } }));
    try std.testing.expectError(error.PlatformMismatch, validate(.{ .kind = .backend_private, .backend_private = .{ .backend = .hvf, .format = "other", .data_b64 = "AAAA" } }));
    try std.testing.expectError(error.PlatformMismatch, validate(.{ .kind = .backend_private, .backend_private = .{ .backend = .hvf, .format = hvf_backend_private_format, .data_b64 = "not base64" } }));
}
