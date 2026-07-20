//! Shared guest-platform compatibility checks and host introspection.

const std = @import("std");
const builtin = @import("builtin");
const architecture = @import("architecture.zig");
const backend_mod = @import("backend.zig");
const board = @import("aarch64/board.zig");
const local_paths = @import("local_paths.zig");
const spore = @import("spore.zig");
const x86_board = @import("x86_64/board.zig");
const x86_cpu_profile = @import("x86_64/cpu_profile.zig");
const x86_kvm = @import("kvm/x86_64.zig");

pub const machine_arch = "aarch64";
pub const host_info_schema = "spore.host-info.v2";
pub const host_info_schema_version: u32 = 2;
pub const host_info_v3_schema = "spore.host-info.v3";
pub const host_info_v3_schema_version: u32 = 3;
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
    arch: architecture.Architecture,
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

/// Architecture-discriminated host facts. The union tag is intentionally part
/// of the JSON shape, so an ARM consumer never has to interpret zero-valued x86
/// fields (or vice versa) as "not applicable".
pub const HostInfoV3 = struct {
    schema: []const u8 = host_info_v3_schema,
    schema_version: u32 = host_info_v3_schema_version,
    host_class: []const u8,
    architecture: []const u8,
    platform: PlatformFactsV3,
    backends: [2]BackendAvailability,
    cache_roots: CacheRoots,
};

pub const PlatformFactsV3 = union(enum) {
    arm64: Aarch64PlatformFacts,
    amd64: X86PlatformFacts,
};

pub const Aarch64PlatformFacts = struct {
    os: []const u8,
    cpu_profile: []const u8,
    device_model_version: u32,
    ram_base: u64,
    interrupt_controller: Aarch64InterruptController,
    counter: Aarch64Counter,
};

pub const Aarch64InterruptController = struct {
    kind: []const u8 = "gicv3",
    distributor_base: u64,
    redistributor_base: u64,
};

pub const Aarch64Counter = struct {
    source: []const u8 = "cntfrq_el0",
    frequency_hz: u64,
};

pub const X86PlatformFacts = struct {
    os: []const u8,
    board_profile: []const u8 = x86_board.board_profile,
    cpu_profile: []const u8 = x86_cpu_profile.profile_name,
    cpu_profile_status: []const u8 = @tagName(x86_cpu_profile.candidate_status),
    device_model_version: u32 = x86_board.device_model_version,
    ram: X86RamFacts = .{},
    interrupt_controller: X86InterruptController = .{},
    virtio_mmio: X86VirtioMmio = .{},
    generation: X86Generation = .{},
    kvm_capabilities: [x86_cpu_profile.required_capabilities.len]KvmCapabilityFact,
};

pub const X86RamFacts = struct {
    base: u64 = 0,
    minimum_bytes: u64 = x86_board.min_ram_size,
    maximum_low_bytes: u64 = x86_board.max_ram_size,
    identity_map_address: u64 = x86_board.identity_map_addr,
    tss_address: u64 = x86_board.tss_addr,
    tss_size: u64 = x86_board.tss_size,
};

pub const X86InterruptController = struct {
    kind: []const u8 = "kvm_irqchip",
    local_apic_base: u64 = x86_board.local_apic_base,
    ioapic_base: u64 = x86_board.ioapic_base,
    pit: []const u8 = "kvm_pit2",
};

pub const X86VirtioMmio = struct {
    base: u64 = x86_board.virtio_base,
    window_size: u64 = x86_board.virtio_window_size,
    slot_count: usize = x86_board.max_virtio_devices,
    first_gsi: u32 = x86_board.virtio_first_gsi,
};

pub const X86Generation = struct {
    base: u64 = x86_board.generation_base,
    size: u64 = x86_board.generation_size,
    gsi: u32 = x86_board.generation_gsi,
    poweroff_doorbell_offset: u64 = x86_board.poweroff_doorbell_offset,
    poweroff_command: u32 = x86_board.poweroff_command,
};

pub const KvmCapabilityFact = struct {
    name: []const u8,
    id: u32,
    minimum: u32,
    required_bits: u32,
    value: ?u32,
    satisfied: bool,
};

/// Pure input to the v3 renderer. Offline tools and tests can render either
/// architecture without executing an architecture-specific instruction or
/// opening `/dev/kvm`.
pub const HostInfoV3Snapshot = struct {
    os: []const u8,
    architecture: architecture.Architecture,
    host_class: []const u8,
    aarch64_counter_frequency_hz: u64 = 0,
    x86_kvm_capabilities: [x86_cpu_profile.required_capabilities.len]KvmCapabilityFact = emptyX86KvmCapabilities(),
    backends: [2]BackendAvailability,
};

pub const Expected = struct {
    arch: []const u8 = machine_arch,
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
    if (!supportsHostInfoV2(builtin.cpu.arch)) return error.UnsupportedArchitecture;
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
            .arch = architecture.fromTarget(builtin.cpu.arch) orelse return error.UnsupportedHost,
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

pub fn supportsHostInfoV2(zig_arch: std.Target.Cpu.Arch) bool {
    return zig_arch == .aarch64;
}

/// Return the versioned host-info contract on either supported architecture.
/// Architecture-specific probing is confined to snapshot construction; JSON
/// rendering and fixture inspection use `hostInfoV3FromSnapshot` directly.
pub fn hostInfoV3(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !HostInfoV3 {
    const snapshot = try currentHostInfoV3Snapshot();
    return hostInfoV3FromSnapshot(allocator, environ, snapshot);
}

pub fn hostInfoV3FromSnapshot(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    snapshot: HostInfoV3Snapshot,
) !HostInfoV3 {
    const kernels = try cacheRootFact(allocator, environ, .kernels);
    errdefer freePathFact(allocator, kernels);
    const rootfs = try cacheRootFact(allocator, environ, .rootfs);
    errdefer freePathFact(allocator, rootfs);
    const bundles = try cacheRootFact(allocator, environ, .bundles);
    errdefer freePathFact(allocator, bundles);
    const runtime = try runtimeRootFact(allocator, environ);
    errdefer freePathFact(allocator, runtime);

    return .{
        .host_class = snapshot.host_class,
        .architecture = @tagName(snapshot.architecture),
        .platform = platformFactsV3(snapshot),
        .backends = snapshot.backends,
        .cache_roots = .{
            .kernels = kernels,
            .rootfs = rootfs,
            .bundles = bundles,
            .runtime = runtime,
        },
    };
}

fn platformFactsV3(snapshot: HostInfoV3Snapshot) PlatformFactsV3 {
    return switch (snapshot.architecture) {
        .arm64 => .{ .arm64 = .{
            .os = snapshot.os,
            .cpu_profile = board.cpu_profile,
            .device_model_version = board.device_model_version,
            .ram_base = board.ram_base,
            .interrupt_controller = .{
                .distributor_base = default_gic_dist_base,
                .redistributor_base = default_gic_redist_base,
            },
            .counter = .{ .frequency_hz = snapshot.aarch64_counter_frequency_hz },
        } },
        .amd64 => .{ .amd64 = .{
            .os = snapshot.os,
            .kvm_capabilities = snapshot.x86_kvm_capabilities,
        } },
    };
}

pub fn deinitHostInfoV3(allocator: std.mem.Allocator, info: HostInfoV3) void {
    freePathFact(allocator, info.cache_roots.kernels);
    freePathFact(allocator, info.cache_roots.rootfs);
    freePathFact(allocator, info.cache_roots.bundles);
    freePathFact(allocator, info.cache_roots.runtime);
}

fn currentHostInfoV3Snapshot() !HostInfoV3Snapshot {
    if (comptime builtin.cpu.arch == .aarch64) {
        return .{
            .os = @tagName(builtin.os.tag),
            .architecture = .arm64,
            .host_class = hostClass(),
            .aarch64_counter_frequency_hz = try hostCounterFrequencyHz(),
            .backends = .{ hvfAvailability(), kvmAvailability() },
        };
    }
    if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
        const capabilities = collectX86KvmCapabilities();
        return .{
            .os = @tagName(builtin.os.tag),
            .architecture = .amd64,
            .host_class = "linux-amd64-kvm",
            .x86_kvm_capabilities = capabilities,
            .backends = .{ unsupportedBackend("hvf"), x86KvmAvailability(capabilities) },
        };
    }
    return error.UnsupportedArchitecture;
}

fn emptyX86KvmCapabilities() [x86_cpu_profile.required_capabilities.len]KvmCapabilityFact {
    var facts: [x86_cpu_profile.required_capabilities.len]KvmCapabilityFact = undefined;
    for (x86_cpu_profile.required_capabilities, &facts) |requirement, *fact| {
        fact.* = .{
            .name = requirement.name,
            .id = requirement.id,
            .minimum = requirement.minimum,
            .required_bits = requirement.required_bits,
            .value = null,
            .satisfied = false,
        };
    }
    return facts;
}

fn collectX86KvmCapabilities() [x86_cpu_profile.required_capabilities.len]KvmCapabilityFact {
    var facts = emptyX86KvmCapabilities();
    if (std.c.access("/dev/kvm", 0) != 0) return facts;
    const fd = x86_kvm.openDevKvm() catch return facts;
    defer _ = std.c.close(fd);
    for (&facts) |*fact| {
        const value = x86_kvm.checkExtension(fd, fact.id) catch continue;
        const bounded = std.math.cast(u32, value) orelse continue;
        fact.value = bounded;
        fact.satisfied = bounded >= fact.minimum and bounded & fact.required_bits == fact.required_bits;
    }
    return facts;
}

fn unsupportedBackend(name: []const u8) BackendAvailability {
    return .{ .name = name, .supported = false, .available = false, .reason = "unsupported_os_or_arch" };
}

fn x86KvmAvailability(capabilities: [x86_cpu_profile.required_capabilities.len]KvmCapabilityFact) BackendAvailability {
    _ = capabilities;
    const availability = backend_mod.availability(.kvm);
    return switch (availability) {
        .available => .{ .name = "kvm", .supported = true, .available = true, .reason = "available" },
        .unavailable => |result| .{
            .name = "kvm",
            .supported = result.reason != .unsupported_host,
            .available = false,
            .reason = unavailableReasonName(result.reason),
        },
    };
}

fn unavailableReasonName(reason: backend_mod.UnavailableReason) []const u8 {
    return switch (reason) {
        .unsupported_host => "unsupported_os_or_arch",
        .missing_dev_kvm => "missing_dev_kvm",
        .kvm_open_failed => "kvm_open_failed",
        .api_version_mismatch => "api_version_mismatch",
        .missing_capability => "kvm_capability_missing",
        .kvm_probe_failed => "kvm_probe_failed",
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
    if (comptime builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) return "macos-arm64-hvf";
    if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .aarch64) return "linux-arm64-kvm";
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
    try std.testing.expectEqual(architecture.Architecture.arm64, info.platform.arch);
    try std.testing.expect(std.mem.indexOf(u8, info.host_class, "aarch64") == null);
    try std.testing.expect(std.mem.indexOf(u8, info.host_class, "arm64") != null);
    try std.testing.expect(info.backends.len >= 2);
    try std.testing.expectEqualStrings("/tmp/sporevm-cache/sporevm/kernels", info.cache_roots.kernels.path.?);
    try std.testing.expectEqualStrings("/tmp/sporevm-cache/sporevm/rootfs", info.cache_roots.rootfs.path.?);
    try std.testing.expectEqualStrings("/tmp/sporevm-cache/sporevm/bundles", info.cache_roots.bundles.path.?);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/sporevm", info.cache_roots.runtime.path.?);
}

test "v3 offline renderer discriminates ARM and x86 without host probing" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("XDG_CACHE_HOME", "/tmp/sporevm-cache");
    try env.put("XDG_RUNTIME_DIR", "/tmp/sporevm-runtime");

    const unavailable_hvf = unsupportedBackend("hvf");
    const available_hvf = BackendAvailability{ .name = "hvf", .supported = true, .available = true, .reason = "supported_host" };
    const unavailable_kvm = unsupportedBackend("kvm");
    const available_kvm = BackendAvailability{ .name = "kvm", .supported = true, .available = true, .reason = "available" };

    const arm = try hostInfoV3FromSnapshot(allocator, &env, .{
        .os = "macos",
        .architecture = .arm64,
        .host_class = "macos-arm64-hvf",
        .aarch64_counter_frequency_hz = 24_000_000,
        .backends = .{ available_hvf, unavailable_kvm },
    });
    defer deinitHostInfoV3(allocator, arm);
    try std.testing.expectEqualStrings(host_info_v3_schema, arm.schema);
    try std.testing.expectEqualStrings("arm64", arm.architecture);
    try std.testing.expectEqual(@as(u64, 24_000_000), arm.platform.arm64.counter.frequency_hz);

    var capabilities = emptyX86KvmCapabilities();
    for (&capabilities) |*capability| {
        capability.value = @max(capability.minimum, capability.required_bits);
        capability.satisfied = true;
    }
    const x86 = try hostInfoV3FromSnapshot(allocator, &env, .{
        .os = "linux",
        .architecture = .amd64,
        .host_class = "linux-amd64-kvm",
        .x86_kvm_capabilities = capabilities,
        .backends = .{ unavailable_hvf, available_kvm },
    });
    defer deinitHostInfoV3(allocator, x86);
    try std.testing.expectEqualStrings("amd64", x86.architecture);
    try std.testing.expectEqualStrings(x86_board.board_profile, x86.platform.amd64.board_profile);
    try std.testing.expectEqualStrings(x86_cpu_profile.profile_name, x86.platform.amd64.cpu_profile);
    try std.testing.expectEqualStrings("approved_same_host", x86.platform.amd64.cpu_profile_status);
    try std.testing.expectEqualStrings("available", x86.backends[1].reason);
    for (x86.platform.amd64.kvm_capabilities) |capability| try std.testing.expect(capability.satisfied);

    const arm_json = try std.json.Stringify.valueAlloc(allocator, arm, .{});
    defer allocator.free(arm_json);
    const x86_json = try std.json.Stringify.valueAlloc(allocator, x86, .{});
    defer allocator.free(x86_json);
    try std.testing.expectEqualStrings(
        "{\"schema\":\"spore.host-info.v3\",\"schema_version\":3,\"host_class\":\"macos-arm64-hvf\",\"architecture\":\"arm64\",\"platform\":{\"arm64\":{\"os\":\"macos\",\"cpu_profile\":\"sporevm-aarch64-v0\",\"device_model_version\":4,\"ram_base\":2147483648,\"interrupt_controller\":{\"kind\":\"gicv3\",\"distributor_base\":134217728,\"redistributor_base\":134348800},\"counter\":{\"source\":\"cntfrq_el0\",\"frequency_hz\":24000000}}}," ++
            "\"backends\":[{\"name\":\"hvf\",\"supported\":true,\"available\":true,\"reason\":\"supported_host\"},{\"name\":\"kvm\",\"supported\":false,\"available\":false,\"reason\":\"unsupported_os_or_arch\"}]," ++
            "\"cache_roots\":{\"kernels\":{\"path\":\"/tmp/sporevm-cache/sporevm/kernels\",\"resolved\":true,\"source\":\"environment\"},\"rootfs\":{\"path\":\"/tmp/sporevm-cache/sporevm/rootfs\",\"resolved\":true,\"source\":\"environment\"},\"bundles\":{\"path\":\"/tmp/sporevm-cache/sporevm/bundles\",\"resolved\":true,\"source\":\"environment\"},\"runtime\":{\"path\":\"/tmp/sporevm-runtime/sporevm\",\"resolved\":true,\"source\":\"environment\"}}}",
        arm_json,
    );
    try std.testing.expectEqualStrings(
        "{\"schema\":\"spore.host-info.v3\",\"schema_version\":3,\"host_class\":\"linux-amd64-kvm\",\"architecture\":\"amd64\",\"platform\":{\"amd64\":{\"os\":\"linux\",\"board_profile\":\"sporevm-x86_64-board-v0\",\"cpu_profile\":\"sporevm-x86_64-v0\",\"cpu_profile_status\":\"approved_same_host\",\"device_model_version\":1," ++
            "\"ram\":{\"base\":0,\"minimum_bytes\":67108864,\"maximum_low_bytes\":2147483648,\"identity_map_address\":4294688768,\"tss_address\":4294692864,\"tss_size\":12288}," ++
            "\"interrupt_controller\":{\"kind\":\"kvm_irqchip\",\"local_apic_base\":4276092928,\"ioapic_base\":4273995776,\"pit\":\"kvm_pit2\"}," ++
            "\"virtio_mmio\":{\"base\":3489660928,\"window_size\":512,\"slot_count\":8,\"first_gsi\":5},\"generation\":{\"base\":3489665024,\"size\":4096,\"gsi\":13,\"poweroff_doorbell_offset\":32,\"poweroff_command\":1179012944}," ++
            "\"kvm_capabilities\":[{\"name\":\"irqchip\",\"id\":0,\"minimum\":1,\"required_bits\":0,\"value\":1,\"satisfied\":true},{\"name\":\"user_memory\",\"id\":3,\"minimum\":1,\"required_bits\":0,\"value\":1,\"satisfied\":true},{\"name\":\"set_tss_addr\",\"id\":4,\"minimum\":1,\"required_bits\":0,\"value\":1,\"satisfied\":true},{\"name\":\"ext_cpuid\",\"id\":7,\"minimum\":1,\"required_bits\":0,\"value\":1,\"satisfied\":true},{\"name\":\"mp_state\",\"id\":14,\"minimum\":1,\"required_bits\":0,\"value\":1,\"satisfied\":true},{\"name\":\"pit2\",\"id\":33,\"minimum\":1,\"required_bits\":0,\"value\":1,\"satisfied\":true},{\"name\":\"pit_state2\",\"id\":35,\"minimum\":1,\"required_bits\":0,\"value\":1,\"satisfied\":true},{\"name\":\"set_identity_map_addr\",\"id\":37,\"minimum\":1,\"required_bits\":0,\"value\":1,\"satisfied\":true},{\"name\":\"adjust_clock\",\"id\":39,\"minimum\":1,\"required_bits\":14,\"value\":14,\"satisfied\":true},{\"name\":\"vcpu_events\",\"id\":41,\"minimum\":1,\"required_bits\":0,\"value\":1,\"satisfied\":true},{\"name\":\"debugregs\",\"id\":50,\"minimum\":1,\"required_bits\":0,\"value\":1,\"satisfied\":true},{\"name\":\"enable_cap_vm\",\"id\":98,\"minimum\":1,\"required_bits\":0,\"value\":1,\"satisfied\":true},{\"name\":\"xsave\",\"id\":55,\"minimum\":1,\"required_bits\":0,\"value\":1,\"satisfied\":true},{\"name\":\"xcrs\",\"id\":56,\"minimum\":1,\"required_bits\":0,\"value\":1,\"satisfied\":true},{\"name\":\"tsc_control\",\"id\":60,\"minimum\":1,\"required_bits\":0,\"value\":1,\"satisfied\":true},{\"name\":\"get_tsc_khz\",\"id\":61,\"minimum\":1,\"required_bits\":0,\"value\":1,\"satisfied\":true},{\"name\":\"kvmclock_ctrl\",\"id\":76,\"minimum\":1,\"required_bits\":0,\"value\":1,\"satisfied\":true},{\"name\":\"immediate_exit\",\"id\":136,\"minimum\":1,\"required_bits\":0,\"value\":1,\"satisfied\":true},{\"name\":\"exception_payload\",\"id\":164,\"minimum\":1,\"required_bits\":0,\"value\":1,\"satisfied\":true},{\"name\":\"enforce_pv_feature_cpuid\",\"id\":190,\"minimum\":1,\"required_bits\":0,\"value\":1,\"satisfied\":true},{\"name\":\"vm_tsc_control\",\"id\":214,\"minimum\":1,\"required_bits\":0,\"value\":1,\"satisfied\":true}]}}" ++
            ",\"backends\":[{\"name\":\"hvf\",\"supported\":false,\"available\":false,\"reason\":\"unsupported_os_or_arch\"},{\"name\":\"kvm\",\"supported\":true,\"available\":true,\"reason\":\"available\"}]," ++
            "\"cache_roots\":{\"kernels\":{\"path\":\"/tmp/sporevm-cache/sporevm/kernels\",\"resolved\":true,\"source\":\"environment\"},\"rootfs\":{\"path\":\"/tmp/sporevm-cache/sporevm/rootfs\",\"resolved\":true,\"source\":\"environment\"},\"bundles\":{\"path\":\"/tmp/sporevm-cache/sporevm/bundles\",\"resolved\":true,\"source\":\"environment\"},\"runtime\":{\"path\":\"/tmp/sporevm-runtime/sporevm\",\"resolved\":true,\"source\":\"environment\"}}}",
        x86_json,
    );
}

test "v2 schema remains the OCI-named ARM-shaped contract" {
    try std.testing.expectEqualStrings("spore.host-info.v2", host_info_schema);
    try std.testing.expectEqual(@as(u32, 2), host_info_schema_version);
    const info = HostInfo{
        .host_class = "linux-arm64-kvm",
        .platform = .{
            .os = "linux",
            .arch = .arm64,
            .cpu_profile = "sporevm-aarch64-v0",
            .device_model_version = 4,
            .ram_base = 0x8000_0000,
            .gic_dist_base = default_gic_dist_base,
            .gic_redist_base = default_gic_redist_base,
            .counter_frequency_source = "cntfrq_el0",
            .counter_frequency_hz = 24_000_000,
        },
        .backends = .{
            .{ .name = "hvf", .supported = false, .available = false, .reason = "unsupported_os_or_arch" },
            .{ .name = "kvm", .supported = true, .available = true, .reason = "available" },
        },
        .cache_roots = .{
            .kernels = .{ .path = null, .resolved = false, .source = "missing_home" },
            .rootfs = .{ .path = null, .resolved = false, .source = "missing_home" },
            .bundles = .{ .path = null, .resolved = false, .source = "missing_home" },
            .runtime = .{ .path = null, .resolved = false, .source = "invalid_runtime_dir" },
        },
    };
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, info, .{});
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"schema\":\"spore.host-info.v2\",\"schema_version\":2,\"host_class\":\"linux-arm64-kvm\",\"platform\":{\"os\":\"linux\",\"arch\":\"arm64\",\"cpu_profile\":\"sporevm-aarch64-v0\",\"device_model_version\":4,\"ram_base\":2147483648,\"gic_dist_base\":134217728,\"gic_redist_base\":134348800,\"counter_frequency_source\":\"cntfrq_el0\",\"counter_frequency_hz\":24000000},\"backends\":[{\"name\":\"hvf\",\"supported\":false,\"available\":false,\"reason\":\"unsupported_os_or_arch\"},{\"name\":\"kvm\",\"supported\":true,\"available\":true,\"reason\":\"available\"}],\"cache_roots\":{\"kernels\":{\"path\":null,\"resolved\":false,\"source\":\"missing_home\"},\"rootfs\":{\"path\":null,\"resolved\":false,\"source\":\"missing_home\"},\"bundles\":{\"path\":null,\"resolved\":false,\"source\":\"missing_home\"},\"runtime\":{\"path\":null,\"resolved\":false,\"source\":\"invalid_runtime_dir\"}}}",
        json,
    );
}

test "v2 host info is explicitly ARM only" {
    try std.testing.expect(supportsHostInfoV2(.aarch64));
    try std.testing.expect(!supportsHostInfoV2(.x86_64));
    try std.testing.expect(!supportsHostInfoV2(.riscv64));
}
