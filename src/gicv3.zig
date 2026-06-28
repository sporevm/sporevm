//! Portable GICv3 state used by the spore manifest.
//!
//! This module is deliberately free of hypervisor calls. It defines the
//! architectural distributor/redistributor register subset SporeVM currently
//! captures for a single-vCPU board and validates hostile manifest data before
//! any backend maps it to KVM ioctls or Hypervisor.framework calls.

const std = @import("std");
const board = @import("board.zig");

pub const schema_version: u32 = 0;
pub const multi_schema_version: u32 = 1;
pub const hvf_backend_private_format = "hv_gic_state_v0";

pub const StateKind = enum { gicv3, gicv3_multi, backend_private };
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

pub const MultiLineLevel = struct {
    intid: u32,
    asserted: bool,
    /// Required for SGI/PPI state (INTID 16..31), null for global SPI state.
    mpidr: ?u64 = null,
};

pub const RegSpec = struct {
    offset: u32,
    width_bits: u8,
};

pub const fixed_dist_reg_specs = [_]RegSpec{
    .{ .offset = 0x000, .width_bits = 32 }, // GICD_CTLR
    .{ .offset = 0x084, .width_bits = 32 }, // GICD_IGROUPR1
    .{ .offset = 0x104, .width_bits = 32 }, // GICD_ISENABLER1
    .{ .offset = 0x204, .width_bits = 32 }, // GICD_ISPENDR1
    .{ .offset = 0x304, .width_bits = 32 }, // GICD_ISACTIVER1
    .{ .offset = 0xd04, .width_bits = 32 }, // GICD_IGRPMODR1
};

pub const fixed_redist_reg_specs = [_]RegSpec{
    .{ .offset = 0x0000, .width_bits = 32 }, // GICR_CTLR
    .{ .offset = 0x0014, .width_bits = 32 }, // GICR_WAKER
    .{ .offset = 0x10080, .width_bits = 32 }, // GICR_IGROUPR0
    .{ .offset = 0x10100, .width_bits = 32 }, // GICR_ISENABLER0
    .{ .offset = 0x10200, .width_bits = 32 }, // GICR_ISPENDR0
    .{ .offset = 0x10300, .width_bits = 32 }, // GICR_ISACTIVER0
    .{ .offset = 0x10d00, .width_bits = 32 }, // GICR_IGRPMODR0
};

pub fn appendDistRegSpecs(allocator: std.mem.Allocator, specs: *std.ArrayList(RegSpec)) !void {
    try specs.appendSlice(allocator, &fixed_dist_reg_specs);

    var off: u32 = 0x420; // GICD_IPRIORITYR for INTIDs 32..63.
    while (off < 0x440) : (off += 4) try specs.append(allocator, .{ .offset = off, .width_bits = 32 });

    off = 0xc08; // GICD_ICFGR for INTIDs 32..63.
    while (off < 0xc10) : (off += 4) try specs.append(allocator, .{ .offset = off, .width_bits = 32 });

    var intid: u32 = 32;
    while (intid <= board.generationIntid()) : (intid += 1) {
        try specs.append(allocator, .{ .offset = distRouterOffset(intid), .width_bits = 64 });
    }
}

pub fn appendRedistRegSpecs(allocator: std.mem.Allocator, specs: *std.ArrayList(RegSpec)) !void {
    try specs.appendSlice(allocator, &fixed_redist_reg_specs);

    var off: u32 = 0x10400; // GICR_IPRIORITYR for SGIs/PPIs.
    while (off < 0x10420) : (off += 4) try specs.append(allocator, .{ .offset = off, .width_bits = 32 });

    off = 0x10c00; // GICR_ICFGR for SGIs/PPIs.
    while (off < 0x10c08) : (off += 4) try specs.append(allocator, .{ .offset = off, .width_bits = 32 });
}

pub const GicV3State = struct {
    schema_version: u32 = schema_version,
    dist_regs: []const MmioReg,
    redist_regs: []const MmioReg,
    line_levels: []const LineLevel,
};

pub const RedistributorState = struct {
    mpidr: u64,
    regs: []const MmioReg,
};

pub const GicV3MultiState = struct {
    schema_version: u32 = multi_schema_version,
    dist_regs: []const MmioReg,
    redistributors: []const RedistributorState,
    line_levels: []const MultiLineLevel,
};

pub const BackendPrivateState = struct {
    backend: BackendKind,
    format: []const u8,
    data_b64: []const u8,
};

pub const State = struct {
    kind: StateKind,
    gicv3: ?GicV3State = null,
    gicv3_multi: ?GicV3MultiState = null,
    backend_private: ?BackendPrivateState = null,
};

pub fn validate(state: State) !void {
    switch (state.kind) {
        .gicv3 => {
            if (state.gicv3_multi != null) return error.PlatformMismatch;
            if (state.backend_private != null) return error.PlatformMismatch;
            const g = state.gicv3 orelse return error.PlatformMismatch;
            try validateGicV3(g);
        },
        .gicv3_multi => {
            if (state.gicv3 != null) return error.PlatformMismatch;
            if (state.backend_private != null) return error.PlatformMismatch;
            const g = state.gicv3_multi orelse return error.PlatformMismatch;
            try validateGicV3Multi(g);
        },
        .backend_private => {
            if (state.gicv3 != null) return error.PlatformMismatch;
            if (state.gicv3_multi != null) return error.PlatformMismatch;
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

pub fn validateGicV3Multi(state: GicV3MultiState) !void {
    if (state.schema_version != multi_schema_version) return error.PlatformMismatch;
    if (state.redistributors.len == 0) return error.PlatformMismatch;
    try validateRegs(state.dist_regs, .distributor);
    for (state.redistributors, 0..) |redist, i| {
        if (redist.mpidr == 0) return error.PlatformMismatch;
        for (state.redistributors[0..i]) |prev| {
            if (prev.mpidr == redist.mpidr) return error.PlatformMismatch;
        }
        try validateRegs(redist.regs, .redistributor);
    }
    try validateMultiLineLevels(state.line_levels, state.redistributors);
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

fn validateMultiLineLevels(levels: []const MultiLineLevel, redistributors: []const RedistributorState) !void {
    for (levels, 0..) |level, i| {
        if (level.intid < 16 or level.intid > board.generationIntid()) return error.PlatformMismatch;
        if (level.intid < 32) {
            const mpidr = level.mpidr orelse return error.PlatformMismatch;
            if (!hasRedistributor(redistributors, mpidr)) return error.PlatformMismatch;
        } else if (level.mpidr != null) {
            return error.PlatformMismatch;
        }
        for (levels[0..i]) |prev| {
            if (prev.intid == level.intid and std.meta.eql(prev.mpidr, level.mpidr)) return error.PlatformMismatch;
        }
    }
}

fn hasRedistributor(redistributors: []const RedistributorState, mpidr: u64) bool {
    for (redistributors) |redist| {
        if (redist.mpidr == mpidr) return true;
    }
    return false;
}

fn expectedWidth(region: Region, offset: u32) ?u8 {
    return switch (region) {
        .distributor => expectedDistWidth(offset),
        .redistributor => expectedRedistWidth(offset),
    };
}

fn expectedDistWidth(offset: u32) ?u8 {
    for (fixed_dist_reg_specs) |spec| {
        if (offset == spec.offset) return spec.width_bits;
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
    for (fixed_redist_reg_specs) |spec| {
        if (offset == spec.offset) return spec.width_bits;
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

test "register specs match validation schema" {
    const allocator = std.testing.allocator;
    var dist: std.ArrayList(RegSpec) = .empty;
    defer dist.deinit(allocator);
    var redist: std.ArrayList(RegSpec) = .empty;
    defer redist.deinit(allocator);

    try appendDistRegSpecs(allocator, &dist);
    try appendRedistRegSpecs(allocator, &redist);

    try std.testing.expect(dist.items.len > fixed_dist_reg_specs.len);
    try std.testing.expect(redist.items.len > fixed_redist_reg_specs.len);
    for (dist.items) |spec| try std.testing.expectEqual(spec.width_bits, expectedDistWidth(spec.offset).?);
    for (redist.items) |spec| try std.testing.expectEqual(spec.width_bits, expectedRedistWidth(spec.offset).?);
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

test "validates portable multi-vCPU GICv3 state" {
    var dist = [_]MmioReg{.{ .offset = distRouterOffset(32), .width_bits = 64, .value = 0 }};
    var redist_regs = [_]MmioReg{.{ .offset = 0x10080, .width_bits = 32, .value = 0 }};
    var redists = [_]RedistributorState{
        .{ .mpidr = 0x8000_0000, .regs = &redist_regs },
        .{ .mpidr = 0x8000_0001, .regs = &redist_regs },
    };
    var lines = [_]MultiLineLevel{
        .{ .intid = 16, .asserted = false, .mpidr = 0x8000_0001 },
        .{ .intid = board.generationIntid(), .asserted = true },
    };
    try validate(.{ .kind = .gicv3_multi, .gicv3_multi = .{ .dist_regs = &dist, .redistributors = &redists, .line_levels = &lines } });
}

test "rejects invalid multi-vCPU GICv3 state" {
    var duplicate_redists = [_]RedistributorState{
        .{ .mpidr = 0x8000_0000, .regs = &.{} },
        .{ .mpidr = 0x8000_0000, .regs = &.{} },
    };
    try std.testing.expectError(error.PlatformMismatch, validate(.{ .kind = .gicv3_multi, .gicv3_multi = .{ .dist_regs = &.{}, .redistributors = &duplicate_redists, .line_levels = &.{} } }));

    var bad_offset_regs = [_]MmioReg{.{ .offset = 0xffff, .width_bits = 32, .value = 0 }};
    var bad_redists = [_]RedistributorState{.{ .mpidr = 0x8000_0000, .regs = &bad_offset_regs }};
    try std.testing.expectError(error.PlatformMismatch, validate(.{ .kind = .gicv3_multi, .gicv3_multi = .{ .dist_regs = &.{}, .redistributors = &bad_redists, .line_levels = &.{} } }));

    var redists = [_]RedistributorState{.{ .mpidr = 0x8000_0000, .regs = &.{} }};

    var ppi_without_owner = [_]MultiLineLevel{.{ .intid = 16, .asserted = true }};
    try std.testing.expectError(error.PlatformMismatch, validate(.{ .kind = .gicv3_multi, .gicv3_multi = .{ .dist_regs = &.{}, .redistributors = &redists, .line_levels = &ppi_without_owner } }));

    var ppi_unknown_owner = [_]MultiLineLevel{.{ .intid = 16, .asserted = true, .mpidr = 0x8000_0001 }};
    try std.testing.expectError(error.PlatformMismatch, validate(.{ .kind = .gicv3_multi, .gicv3_multi = .{ .dist_regs = &.{}, .redistributors = &redists, .line_levels = &ppi_unknown_owner } }));

    var spi_with_owner = [_]MultiLineLevel{.{ .intid = 32, .asserted = true, .mpidr = 0x8000_0000 }};
    try std.testing.expectError(error.PlatformMismatch, validate(.{ .kind = .gicv3_multi, .gicv3_multi = .{ .dist_regs = &.{}, .redistributors = &redists, .line_levels = &spi_with_owner } }));

    var duplicate_lines = [_]MultiLineLevel{
        .{ .intid = 16, .asserted = true, .mpidr = 0x8000_0000 },
        .{ .intid = 16, .asserted = false, .mpidr = 0x8000_0000 },
    };
    try std.testing.expectError(error.PlatformMismatch, validate(.{ .kind = .gicv3_multi, .gicv3_multi = .{ .dist_regs = &.{}, .redistributors = &redists, .line_levels = &duplicate_lines } }));
}

fn fuzzGicV3Multi(_: void, s: *std.testing.Smith) !void {
    // Multi-vCPU GIC state is manifest input. Validation must reject hostile
    // register offsets and ownership shapes without panics or unbounded work.
    var dist = [_]MmioReg{.{ .offset = s.value(u32), .width_bits = s.value(u8), .value = s.value(u64) }};
    var redist_regs = [_]MmioReg{.{ .offset = s.value(u32), .width_bits = s.value(u8), .value = s.value(u64) }};
    var redists = [_]RedistributorState{.{ .mpidr = s.value(u64), .regs = &redist_regs }};
    var lines = [_]MultiLineLevel{.{
        .intid = s.value(u32),
        .asserted = (s.value(u8) & 1) != 0,
        .mpidr = if ((s.value(u8) & 1) != 0) redists[0].mpidr else null,
    }};
    _ = validate(.{ .kind = .gicv3_multi, .gicv3_multi = .{ .dist_regs = &dist, .redistributors = &redists, .line_levels = &lines } }) catch return;
}

test "fuzz multi-vCPU GICv3 validation" {
    try std.testing.fuzz({}, fuzzGicV3Multi, .{});
}
