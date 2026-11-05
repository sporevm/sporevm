//! Backend-neutral configuration for the aarch64 VMM backends (HVF and KVM).
//!
//! Callers describe a run with `Config`; `prepare` validates it once, loads
//! the restore manifest, and resolves vCPU and memory sizes before either
//! backend creates a VM.

const std = @import("std");
const board = @import("board.zig");
const capture = @import("../capture.zig");
const disk_layer = @import("../disk_layer.zig");
const generation = @import("../generation.zig");
const ram_restore = @import("../ram_restore.zig");
const spore = @import("../spore.zig");
const topology = @import("../topology.zig");
const blk = @import("../virtio/blk.zig");
const net = @import("../virtio/net.zig");
const vsock = @import("../virtio/vsock.zig");

pub const ExitCause = enum { guest_off, guest_reset, snapshotted, probe_complete, monitor_stopped };

pub const max_build_input_disks = 2;

pub const Config = struct {
    start: Start,
    /// On restore, 1 means "use the manifest's count"; any other count must
    /// match the manifest.
    vcpus: topology.VcpuCount = 1,
    console_sink: *const fn ([]const u8) void,
    /// Block backend for /dev/vda, if any.
    disk_backend: ?blk.Backend = null,
    /// Ephemeral feature profile for the root disk. The default remains the
    /// portable, resumable virtio-blk surface.
    root_blk_options: blk.Options = .{},
    /// Optional read-only build context disk. When present with a rootfs disk,
    /// Linux enumerates it as the second virtio-blk device.
    context_disk_fd: ?std.c.fd_t = null,
    /// Bounded immutable build inputs, enumerated after the context disk.
    build_input_disk_backends: []const blk.Backend = &.{},
    /// Transient writable build cache volume. Never captured in a manifest.
    build_cache_disk_backend: ?blk.Backend = null,
    /// Optional active disk head to seal into a portable manifest layer when
    /// a snapshot is taken.
    disk_snapshot: ?disk_layer.SnapshotState = null,
    /// Immutable rootfs artifact metadata for disk-backed snapshots.
    rootfs: ?spore.Rootfs = null,
    /// Requested network capability and policy metadata for snapshots.
    network_manifest: ?spore.Network = null,
    annotations: spore.Annotations = .{},
    sessions: []const spore.Session = &.{},
    /// Product callers provide their environment so snapshot code can write
    /// local-only RAM backing proofs under the configured runtime root.
    environ_map: ?*const std.process.Environ.Map = null,
    /// Host-initiated vsock stream that runs the guest command.
    probe: ?Probe = null,
    capture: ?capture.Capture = null,
    /// Optional virtio-net frame backend. The default remains closed.
    network: net.Runtime = .{},
    /// Optional monitor control hook for attaching host streams after boot.
    exec_control: ?vsock.Control = null,

    pub fn probeStream(self: Config) ?*vsock.HostStream {
        return if (self.probe) |probe| probe.stream else null;
    }

    pub fn captureRequest(self: Config) ?*capture.Request {
        const value = self.capture orelse return null;
        return switch (value.trigger) {
            .probe_complete => null,
            .request => |request| request.req,
        };
    }

    /// Where to capture when the probe completes, if the run captures then.
    pub fn probeCaptureDir(self: Config) ?[]const u8 {
        const value = self.capture orelse return null;
        return if (value.trigger == .probe_complete) value.dir else null;
    }

    /// Where the dirty-tracked capture seals RAM, if the run tracks dirty RAM.
    pub fn dirtyTrackingDir(self: Config) ?[]const u8 {
        const value = self.capture orelse return null;
        return if (value.dirty_tracking) value.dir else null;
    }

    /// Whether the run keeps going after a host-requested capture.
    pub fn continueAfterCapture(self: Config) bool {
        const value = self.capture orelse return false;
        return switch (value.trigger) {
            .probe_complete => false,
            .request => |request| request.then == .keep_running,
        };
    }
};

pub const Start = union(enum) {
    boot: Boot,
    restore: Restore,

    pub const Boot = struct {
        kernel: []const u8,
        cmdline: []const u8 = "console=hvc0",
        initrd: ?[]const u8 = null,
        ram_size: u64 = 512 * 1024 * 1024,
        virtio_mem_region_size: u64 = 0,
    };

    pub const Restore = struct {
        dir: []const u8,
        /// Resolved RAM source. Product callers proof-validate local backing
        /// before selecting it; imported or unproven spores select verified
        /// chunks instead.
        ram: ram_restore.Strategy,
        /// Optional pre-refreshed generation state for product resume attach.
        generation: ?generation.State = null,
    };
};

pub const Probe = struct {
    stream: *vsock.HostStream,
    timeout_ms: u64 = 30_000,
    start: vsock.HostStreamStart = .immediate,
    on_complete: OnComplete = .stop,

    pub const OnComplete = enum {
        /// The run ends when the command completes.
        stop,
        /// The stream detaches and the guest keeps running.
        detach,
    };
};

/// Rules that differ between backends.
pub const Rules = struct {
    multi_vcpu_dirty_tracking: bool,
};

pub const Prepared = struct {
    config: Config,
    /// Resolved from the manifest on restore.
    vcpus: topology.VcpuCount,
    ram_size: u64,
    virtio_mem_region_size: u64,
    /// Loaded on restore.
    manifest: ?std.json.Parsed(spore.Manifest) = null,

    pub fn deinit(self: *Prepared) void {
        if (self.manifest) |parsed| parsed.deinit();
        self.manifest = null;
    }

    pub fn restoring(self: Prepared) bool {
        return self.config.start == .restore;
    }

    /// Boots start from fresh RAM.
    pub fn ramRestore(self: Prepared) ram_restore.Strategy {
        return switch (self.config.start) {
            .boot => .fresh,
            .restore => |restore| restore.ram,
        };
    }

    pub fn memory(self: Prepared) ?spore.MemoryManifest {
        const parsed = self.manifest orelse return null;
        return parsed.value.memory;
    }
};

/// Validates `config`, loads the restore manifest, and resolves vCPU and
/// memory sizes. Every rejected combination fails here, before any VM exists.
pub fn prepare(allocator: std.mem.Allocator, config: Config, rules: Rules) !Prepared {
    try topology.validateVcpuCount(config.vcpus);
    if (config.probe) |probe| {
        if (probe.start == .control and config.exec_control == null) return error.DeferredExecProbeRequiresControl;
    }
    if (config.capture) |value| {
        switch (value.trigger) {
            .probe_complete => {
                // Only a probe that stops the run on completion reaches the capture.
                const probe = config.probe orelse return error.CaptureNeverTriggered;
                if (probe.on_complete != .stop) return error.CaptureNeverTriggered;
            },
            .request => {},
        }
        // Dirty tracking starts at boot, so it cannot cover restored RAM.
        if (value.dirty_tracking and config.start == .restore) return error.BadManifest;
    }
    if (config.build_input_disk_backends.len > max_build_input_disks) return error.TooManyBuildInputDisks;

    var prepared: Prepared = switch (config.start) {
        .boot => |boot| .{
            .config = config,
            .vcpus = config.vcpus,
            .ram_size = boot.ram_size,
            .virtio_mem_region_size = boot.virtio_mem_region_size,
        },
        .restore => |restore| try loadRestore(allocator, config, restore),
    };
    errdefer prepared.deinit();

    try topology.validateVcpuCount(prepared.vcpus);
    if (prepared.vcpus != 1 and (prepared.virtio_mem_region_size != 0 or config.continueAfterCapture())) return error.UnsupportedVcpuCount;
    if (config.dirtyTrackingDir() != null) {
        if (prepared.virtio_mem_region_size != 0) return error.BadManifest;
        if (prepared.vcpus != 1 and !rules.multi_vcpu_dirty_tracking) return error.UnsupportedVcpuCount;
    }
    // Console, net, vsock and rng are always present.
    const device_count = @as(usize, 4) + @intFromBool(config.disk_backend != null) + @intFromBool(config.context_disk_fd != null) +
        config.build_input_disk_backends.len + @intFromBool(config.build_cache_disk_backend != null) +
        @intFromBool(prepared.virtio_mem_region_size != 0);
    if (device_count > board.max_virtio_devices) return error.TooManyVirtioDevices;
    return prepared;
}

fn loadRestore(allocator: std.mem.Allocator, config: Config, restore: Start.Restore) !Prepared {
    if (restore.ram == .fresh) return error.BadManifest;
    var prepared: Prepared = .{ .config = config, .vcpus = config.vcpus, .ram_size = 0, .virtio_mem_region_size = 0 };
    errdefer prepared.deinit();
    prepared.manifest = try spore.loadManifest(allocator, restore.dir);
    const manifest = prepared.manifest.?.value;
    // One requested vCPU means "whatever the spore saved".
    if (config.vcpus == 1) {
        prepared.vcpus = manifest.platform.vcpu_count;
    } else if (manifest.platform.vcpu_count != config.vcpus) return error.PlatformMismatch;
    const restored_memory = try spore.memoryConfig(manifest.platform.ram_size, manifest.memory_state);
    prepared.ram_size = restored_memory.initial_bytes;
    prepared.virtio_mem_region_size = restored_memory.maximum_bytes - restored_memory.initial_bytes;
    return prepared;
}

fn testConsoleSink(_: []const u8) void {}

fn testBoot(overrides: struct {
    vcpus: topology.VcpuCount = 1,
    virtio_mem_region_size: u64 = 0,
}) Config {
    return .{
        .start = .{ .boot = .{ .kernel = "", .virtio_mem_region_size = overrides.virtio_mem_region_size } },
        .vcpus = overrides.vcpus,
        .console_sink = testConsoleSink,
    };
}

const test_rules = Rules{ .multi_vcpu_dirty_tracking = false };

fn expectRejected(expected: anyerror, config: Config, rules: Rules) !void {
    try std.testing.expectError(expected, prepare(std.testing.allocator, config, rules));
}

test "prepare resolves a fresh boot from its own sizes" {
    var config = testBoot(.{ .vcpus = 2 });
    config.start.boot.ram_size = 1024 * 1024 * 1024;
    var prepared = try prepare(std.testing.allocator, config, test_rules);
    defer prepared.deinit();
    try std.testing.expectEqual(@as(topology.VcpuCount, 2), prepared.vcpus);
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024), prepared.ram_size);
    try std.testing.expectEqual(@as(u64, 0), prepared.virtio_mem_region_size);
    try std.testing.expect(!prepared.restoring());
    try std.testing.expect(prepared.ramRestore() == .fresh);
}

test "prepare rejects an unsupported vCPU count" {
    try expectRejected(error.UnsupportedVcpuCount, testBoot(.{ .vcpus = 0 }), test_rules);
    try expectRejected(error.UnsupportedVcpuCount, testBoot(.{ .vcpus = topology.max_vcpus + 1 }), test_rules);
}

test "prepare rejects a deferred probe without a control" {
    var stream: vsock.HostStream = undefined;
    var config = testBoot(.{});
    config.probe = .{ .stream = &stream, .start = .control };
    try expectRejected(error.DeferredExecProbeRequiresControl, config, test_rules);
}

test "prepare rejects a probe-completion capture that can never fire" {
    var stream: vsock.HostStream = undefined;
    var config = testBoot(.{});
    config.capture = .{ .dir = "out.spore", .trigger = .probe_complete };
    try expectRejected(error.CaptureNeverTriggered, config, test_rules);

    // A probe that detaches on completion keeps running and never captures.
    config.probe = .{ .stream = &stream, .on_complete = .detach };
    try expectRejected(error.CaptureNeverTriggered, config, test_rules);

    config.probe.?.on_complete = .stop;
    var prepared = try prepare(std.testing.allocator, config, test_rules);
    prepared.deinit();
}

test "prepare rejects a restore without a RAM source" {
    var config = testBoot(.{});
    config.start = .{ .restore = .{ .dir = "missing.spore", .ram = .fresh } };
    try expectRejected(error.BadManifest, config, test_rules);
}

test "prepare rejects dirty tracking on restore" {
    var request: capture.Request = .{};
    var config = testBoot(.{});
    config.start = .{ .restore = .{ .dir = "missing.spore", .ram = .eager_chunks } };
    config.capture = .{ .dir = "out.spore", .trigger = .{ .request = .{ .req = &request, .then = .stop } }, .dirty_tracking = true };
    try expectRejected(error.BadManifest, config, test_rules);
}

test "prepare rejects virtio-mem and continued capture with more than one vCPU" {
    try expectRejected(error.UnsupportedVcpuCount, testBoot(.{ .vcpus = 2, .virtio_mem_region_size = 1024 * 1024 * 1024 }), test_rules);

    var request: capture.Request = .{};
    var config = testBoot(.{ .vcpus = 2 });
    config.capture = .{ .dir = "out.spore", .trigger = .{ .request = .{ .req = &request, .then = .keep_running } } };
    try expectRejected(error.UnsupportedVcpuCount, config, test_rules);
}

test "prepare limits dirty tracking to backends and sizes that support it" {
    var request: capture.Request = .{};
    const dirty = capture.Capture{ .dir = "out.spore", .trigger = .{ .request = .{ .req = &request, .then = .stop } }, .dirty_tracking = true };

    var elastic = testBoot(.{ .virtio_mem_region_size = 1024 * 1024 * 1024 });
    elastic.capture = dirty;
    try expectRejected(error.BadManifest, elastic, test_rules);

    var multi = testBoot(.{ .vcpus = 2 });
    multi.capture = dirty;
    try expectRejected(error.UnsupportedVcpuCount, multi, .{ .multi_vcpu_dirty_tracking = false });
    var prepared = try prepare(std.testing.allocator, multi, .{ .multi_vcpu_dirty_tracking = true });
    prepared.deinit();
}

test "prepare rejects more disks than the board has virtio slots" {
    const backends = [_]blk.Backend{ .{ .file = -1 }, .{ .file = -1 }, .{ .file = -1 } };
    var config = testBoot(.{});
    config.build_input_disk_backends = &backends;
    try expectRejected(error.TooManyBuildInputDisks, config, test_rules);

    config = testBoot(.{ .virtio_mem_region_size = 1024 * 1024 * 1024 });
    config.disk_backend = .{ .file = -1 };
    config.context_disk_fd = -1;
    config.build_input_disk_backends = backends[0..2];
    config.build_cache_disk_backend = .{ .file = -1 };
    try expectRejected(error.TooManyVirtioDevices, config, test_rules);
}
