//! Shared guest-platform compatibility checks and host introspection.

const std = @import("std");
const builtin = @import("builtin");
const board = @import("board.zig");
const local_paths = @import("local_paths.zig");
const spore = @import("spore.zig");

pub const arch = "aarch64";
pub const host_info_schema = "spore.host-info.v1";
pub const host_info_schema_version: u32 = 1;
pub const default_gic_dist_base: u64 = 0x0800_0000;
pub const default_gic_redist_base: u64 = 0x0802_0000;

pub const HostInfo = struct {
    schema: []const u8 = host_info_schema,
    schema_version: u32 = host_info_schema_version,
    host_class: []const u8,
    platform: PlatformFacts,
    backends: [2]BackendAvailability,
    cache_roots: CacheRoots,
};

pub const PlatformFacts = struct {
    os: []const u8,
    arch: []const u8,
    cpu_profile: []const u8,
    device_model_version: u32,
    ram_base: u64,
    gic_dist_base: u64,
    gic_redist_base: u64,
    counter_frequency_source: []const u8,
    counter_frequency_hz: u64,
};

pub const BackendAvailability = struct {
    name: []const u8,
    supported: bool,
    available: bool,
    reason: []const u8,
};

pub const CacheRoots = struct {
    kernels: PathFact,
    rootfs: PathFact,
    bundles: PathFact,
    runtime: PathFact,
};

pub const PathFact = struct {
    path: ?[]const u8,
    resolved: bool,
    source: []const u8,
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

pub fn hostInfo(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !HostInfo {
    const kernels = try cacheRootFact(allocator, environ, .kernels);
    errdefer freePathFact(allocator, kernels);
    const rootfs = try cacheRootFact(allocator, environ, .rootfs);
    errdefer freePathFact(allocator, rootfs);
    const bundles = try cacheRootFact(allocator, environ, .bundles);
    errdefer freePathFact(allocator, bundles);
    const runtime = try runtimeRootFact(allocator, environ);
    errdefer freePathFact(allocator, runtime);

    return .{
        .host_class = hostClass(),
        .platform = .{
            .os = @tagName(builtin.os.tag),
            .arch = @tagName(builtin.cpu.arch),
            .cpu_profile = board.cpu_profile,
            .device_model_version = board.device_model_version,
            .ram_base = board.ram_base,
            .gic_dist_base = default_gic_dist_base,
            .gic_redist_base = default_gic_redist_base,
            .counter_frequency_source = "cntfrq_el0",
            .counter_frequency_hz = try hostCounterFrequencyHz(),
        },
        .backends = .{ hvfAvailability(), kvmAvailability() },
        .cache_roots = .{
            .kernels = kernels,
            .rootfs = rootfs,
            .bundles = bundles,
            .runtime = runtime,
        },
    };
}

pub fn deinitHostInfo(allocator: std.mem.Allocator, info: HostInfo) void {
    freePathFact(allocator, info.cache_roots.kernels);
    freePathFact(allocator, info.cache_roots.rootfs);
    freePathFact(allocator, info.cache_roots.bundles);
    freePathFact(allocator, info.cache_roots.runtime);
}

fn freePathFact(allocator: std.mem.Allocator, fact: PathFact) void {
    if (fact.path) |path| allocator.free(path);
}

fn hostClass() []const u8 {
    if (comptime builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) return "macos-aarch64-hvf";
    if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .aarch64) return "linux-aarch64-kvm";
    return "unsupported";
}

fn hvfAvailability() BackendAvailability {
    if (comptime builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) {
        return .{
            .name = "hvf",
            .supported = true,
            .available = true,
            .reason = "supported_host",
        };
    }
    return .{
        .name = "hvf",
        .supported = false,
        .available = false,
        .reason = "unsupported_os_or_arch",
    };
}

fn kvmAvailability() BackendAvailability {
    if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .aarch64) {
        const available = std.c.access("/dev/kvm", 0) == 0;
        return .{
            .name = "kvm",
            .supported = true,
            .available = available,
            .reason = if (available) "available" else "missing_dev_kvm",
        };
    }
    return .{
        .name = "kvm",
        .supported = false,
        .available = false,
        .reason = "unsupported_os_or_arch",
    };
}

fn cacheRootFact(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    kind: local_paths.CacheKind,
) !PathFact {
    const path = local_paths.cacheRootPath(allocator, environ, kind) catch |err| switch (err) {
        error.MissingHome => return .{ .path = null, .resolved = false, .source = "missing_home" },
        else => |e| return e,
    };
    return .{ .path = path, .resolved = true, .source = "environment" };
}

fn runtimeRootFact(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !PathFact {
    const path = local_paths.runtimeRootPath(allocator, environ) catch |err| switch (err) {
        error.InvalidRuntimeDir => return .{ .path = null, .resolved = false, .source = "invalid_runtime_dir" },
        else => |e| return e,
    };
    return .{ .path = path, .resolved = true, .source = "environment" };
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
        .memory = .{ .logical_size = 1, .chunk_size = spore.chunk_size, .zero_chunks = &.{0} },
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

test "host info exposes schema and cache roots" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("XDG_CACHE_HOME", "/tmp/sporevm-cache");
    try env.put("XDG_RUNTIME_DIR", "/tmp/sporevm-runtime");

    const info = try hostInfo(allocator, &env);
    defer deinitHostInfo(allocator, info);

    try std.testing.expectEqualStrings(host_info_schema, info.schema);
    try std.testing.expectEqual(host_info_schema_version, info.schema_version);
    try std.testing.expect(info.backends.len >= 2);
    try std.testing.expectEqualStrings("/tmp/sporevm-cache/sporevm/kernels", info.cache_roots.kernels.path.?);
    try std.testing.expectEqualStrings("/tmp/sporevm-cache/sporevm/rootfs", info.cache_roots.rootfs.path.?);
    try std.testing.expectEqualStrings("/tmp/sporevm-cache/sporevm/bundles", info.cache_roots.bundles.path.?);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/sporevm", info.cache_roots.runtime.path.?);
}
