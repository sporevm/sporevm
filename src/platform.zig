//! Shared guest-platform compatibility checks and host introspection.

const std = @import("std");
const builtin = @import("builtin");
const board = @import("board.zig");
const spore = @import("spore.zig");

pub const arch = "aarch64";

pub const HostInfo = struct {
    arch: []const u8,
    cpu_profile: []const u8,
    device_model_version: u32,
    counter_frequency_source: []const u8,
    counter_frequency_hz: u64,
};

pub const Expected = struct {
    arch: []const u8 = arch,
    cpu_profile: []const u8 = board.cpu_profile,
    device_model_version: u32 = board.device_model_version,
    ram_base: u64 = board.ram_base,
    ram_size: u64,
    gic_dist_base: u64,
    gic_redist_base: u64,
    counter_frequency_hz: u64,
    device_count: usize,
};

pub fn hostInfo() !HostInfo {
    return .{
        .arch = arch,
        .cpu_profile = board.cpu_profile,
        .device_model_version = board.device_model_version,
        .counter_frequency_source = "cntfrq_el0",
        .counter_frequency_hz = try hostCounterFrequencyHz(),
    };
}

pub fn hostCounterFrequencyHz() !u64 {
    if (comptime builtin.cpu.arch != .aarch64) return error.UnsupportedHost;
    return asm volatile ("mrs %[ret], cntfrq_el0"
        : [ret] "=r" (-> u64),
    );
}

pub fn checkManifest(manifest: spore.Manifest, expected: Expected) !void {
    if (manifest.version != spore.format_version) {
        std.log.err("platform mismatch: spore version={d} expected={d}", .{ manifest.version, spore.format_version });
        return error.PlatformMismatch;
    }
    if (!std.mem.eql(u8, manifest.platform.arch, expected.arch)) {
        std.log.err("platform mismatch: arch={s} expected={s}", .{ manifest.platform.arch, expected.arch });
        return error.PlatformMismatch;
    }
    if (!std.mem.eql(u8, manifest.platform.cpu_profile, expected.cpu_profile)) {
        std.log.err("platform mismatch: cpu_profile={s} expected={s}", .{ manifest.platform.cpu_profile, expected.cpu_profile });
        return error.PlatformMismatch;
    }
    if (manifest.platform.device_model_version != expected.device_model_version) {
        std.log.err("platform mismatch: device_model_version={d} expected={d}", .{ manifest.platform.device_model_version, expected.device_model_version });
        return error.PlatformMismatch;
    }
    if (manifest.platform.ram_base != expected.ram_base) {
        std.log.err("platform mismatch: ram_base=0x{x} expected=0x{x}", .{ manifest.platform.ram_base, expected.ram_base });
        return error.PlatformMismatch;
    }
    if (manifest.platform.ram_size != expected.ram_size) {
        std.log.err("platform mismatch: ram_size={d} expected={d}", .{ manifest.platform.ram_size, expected.ram_size });
        return error.PlatformMismatch;
    }
    if (manifest.platform.gic_dist_base != expected.gic_dist_base) {
        std.log.err("platform mismatch: gic_dist_base=0x{x} expected=0x{x}", .{ manifest.platform.gic_dist_base, expected.gic_dist_base });
        return error.PlatformMismatch;
    }
    if (manifest.platform.gic_redist_base != expected.gic_redist_base) {
        std.log.err("platform mismatch: gic_redist_base=0x{x} expected=0x{x}", .{ manifest.platform.gic_redist_base, expected.gic_redist_base });
        return error.PlatformMismatch;
    }
    if (manifest.platform.counter_frequency_hz != expected.counter_frequency_hz) {
        std.log.err(
            "platform mismatch: counter_frequency_hz={d} expected={d}; cross-frequency architected timer restore unsupported",
            .{ manifest.platform.counter_frequency_hz, expected.counter_frequency_hz },
        );
        return error.PlatformMismatch;
    }
    if (manifest.devices.len != expected.device_count) {
        std.log.err("platform mismatch: device_count={d} expected={d}", .{ manifest.devices.len, expected.device_count });
        return error.PlatformMismatch;
    }
}

test "manifest platform check accepts exact match" {
    const manifest = spore.Manifest{
        .platform = .{
            .cpu_profile = board.cpu_profile,
            .device_model_version = board.device_model_version,
            .ram_base = board.ram_base,
            .ram_size = 512 * 1024 * 1024,
            .gic_dist_base = 0x0800_0000,
            .gic_redist_base = 0x0802_0000,
            .counter_frequency_hz = 24_000_000,
        },
        .machine = .{
            .gprs = [_]u64{0} ** 31,
            .pc = 0,
            .cpsr = 0,
            .fpcr = 0,
            .fpsr = 0,
            .simd = [_][2]u64{.{ 0, 0 }} ** 32,
            .sys_regs = &.{},
            .icc_regs = &.{},
            .vtimer = .{ .cntvct = 0, .cntv_ctl = 0, .cntv_cval = 0 },
            .gic = .{
                .kind = .backend_private,
                .backend_private = .{
                    .backend = .hvf,
                    .format = "test",
                    .data_b64 = "",
                },
            },
        },
        .devices = &.{},
        .generation = .{ .generation = 0, .interrupt_status = 0, .params_b64 = "" },
        .memory = .{ .chunk_size = spore.chunk_size, .chunks = &.{} },
    };
    const expected = Expected{
        .ram_size = manifest.platform.ram_size,
        .gic_dist_base = manifest.platform.gic_dist_base,
        .gic_redist_base = manifest.platform.gic_redist_base,
        .counter_frequency_hz = manifest.platform.counter_frequency_hz,
        .device_count = 0,
    };
    try checkManifest(manifest, expected);
}
