//! Backend-neutral code for the aarch64 VMM backends (HVF and KVM).
//!
//! Callers describe a run with `Config`; `prepare` validates it once, loads
//! the restore manifest, and resolves vCPU and memory sizes before either
//! backend creates a VM. Both backends share the device set, RAM mapping and
//! restore, and transport snapshot helpers below.

const std = @import("std");
const aarch64_topology = @import("topology.zig");
const board = @import("board.zig");
const capture = @import("../capture.zig");
const deadline = @import("../deadline.zig");
const dirty_ram = @import("../dirty_ram.zig");
const disk_layer = @import("../disk_layer.zig");
const generation = @import("../generation.zig");
const gicv3 = @import("gicv3.zig");
const ram_restore = @import("../ram_restore.zig");
const runtime_disk_fork_capture = @import("../runtime_disk_fork_capture.zig");
const spore = @import("../spore.zig");
const topology = @import("../topology.zig");
const blk = @import("../virtio/blk.zig");
const console = @import("../virtio/console.zig");
const virtio_mem = @import("../virtio/mem.zig");
const mmio = @import("../virtio/mmio.zig");
const net = @import("../virtio/net.zig");
const rng = @import("../virtio/rng.zig");
const vsock = @import("../virtio/vsock.zig");
const vsock_control = @import("../virtio/vsock_control.zig");
const vsock_stream = @import("../virtio/vsock_stream.zig");

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
    exec_control: ?vsock_control.Control = null,

    pub fn probeStream(self: Config) ?*vsock_stream.HostStream {
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
    stream: *vsock_stream.HostStream,
    timeout_ms: u64 = 30_000,
    start: vsock_stream.HostStreamStart = .immediate,
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

/// The virtio-mmio devices in slot order: console, the rootfs disk (if any),
/// the build context, immutable input disks, the transient build cache disk,
/// net, vsock, rng, then virtio-mem when RAM can grow. The generation device
/// is a separate fixed MMIO window after the reserved virtio range.
pub const Devices = struct {
    con: console.Console,
    blk: blk.Blk,
    context_blk: blk.Blk,
    build_input_blks: [max_build_input_disks]blk.Blk,
    build_cache_blk: blk.Blk,
    net: net.Net,
    rng: rng.Rng,
    vsock: vsock.Vsock,
    mem: virtio_mem.Mem,
    gen: generation.Device,
    transports_buf: [board.max_virtio_devices]mmio.Transport,
    transport_count: usize,
    net_index: usize,
    vsock_index: usize,
    mem_index: ?usize,

    /// Initializes in place because each transport points at its device.
    /// `prepare` has already checked that the devices fit the board.
    pub fn init(self: *Devices, config: *const Config, hotplug: ?virtio_mem.Config) void {
        self.con = .{ .sink = config.console_sink };
        self.net = net.Net.init(.{ .backend = config.network.backend });
        self.rng = .{};
        self.vsock = vsock.Vsock.init(.{});
        self.gen = .{};
        self.transports_buf[0] = mmio.Transport.init(self.con.device());
        self.transport_count = 1;
        if (config.disk_backend) |backend| {
            self.blk = blk.Blk.initWithOptions(backend, config.root_blk_options);
            self.add(self.blk.device());
        }
        if (config.context_disk_fd) |fd| {
            self.context_blk = blk.Blk.initImmutableSource(.{ .file = fd });
            self.add(self.context_blk.device());
        }
        for (config.build_input_disk_backends, 0..) |backend, index| {
            self.build_input_blks[index] = blk.Blk.initImmutableSource(backend);
            self.add(self.build_input_blks[index].device());
        }
        if (config.build_cache_disk_backend) |backend| {
            self.build_cache_blk = blk.Blk.init(backend);
            self.add(self.build_cache_blk.device());
        }
        self.net_index = self.transport_count;
        self.add(self.net.device());
        self.vsock_index = self.transport_count;
        self.add(self.vsock.device());
        self.add(self.rng.device());
        self.mem_index = null;
        if (hotplug) |mem_config| {
            self.mem = virtio_mem.Mem.init(mem_config);
            self.mem_index = self.transport_count;
            self.add(self.mem.device());
        }
    }

    fn add(self: *Devices, device: mmio.Device) void {
        self.transports_buf[self.transport_count] = mmio.Transport.init(device);
        self.transport_count += 1;
    }

    pub fn transports(self: *Devices) []mmio.Transport {
        return self.transports_buf[0..self.transport_count];
    }
};

pub const RamMapping = struct {
    bytes: []align(std.heap.page_size_min) u8,
    file_backed: bool,

    pub fn deinit(self: RamMapping) void {
        std.posix.munmap(self.bytes);
    }
};

/// Maps initial plus hotpluggable RAM: proof-gated local backing maps the
/// spore's RAM file privately; everything else starts anonymous.
pub fn mapRam(prepared: *const Prepared) !RamMapping {
    const maximum_size = std.math.add(u64, prepared.ram_size, prepared.virtio_mem_region_size) catch return error.BadManifest;
    return switch (prepared.ramRestore()) {
        .local_backing => |fd| blk: {
            const memory = prepared.memory() orelse return error.BadManifest;
            const backing = memory.backing orelse return error.BadManifest;
            try spore.validateMemoryBacking(backing, maximum_size);
            break :blk try mapFileBackedRamFd(fd, maximum_size);
        },
        .fresh, .eager_chunks => mapAnonymousRam(maximum_size),
    };
}

fn mapAnonymousRam(size: u64) !RamMapping {
    const bytes = try std.posix.mmap(
        null,
        @intCast(size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    return .{ .bytes = bytes, .file_backed = false };
}

fn mapFileBackedRamFd(fd: std.c.fd_t, size: u64) !RamMapping {
    const actual_size = try fileSize(fd);
    if (actual_size != size) return error.BadManifest;

    const bytes = try std.posix.mmap(
        null,
        @intCast(size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    );
    std.log.info("mapped RAM from file backing fd: size={d} mode=MAP_PRIVATE", .{size});
    return .{ .bytes = bytes, .file_backed = true };
}

fn fileSize(fd: std.c.fd_t) !u64 {
    const cur = std.c.lseek(fd, 0, std.c.SEEK.CUR);
    if (cur < 0) return error.IoFailed;
    const end = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (end < 0) return error.IoFailed;
    if (std.c.lseek(fd, cur, std.c.SEEK.SET) < 0) return error.IoFailed;
    return @intCast(end);
}

pub const RestoreStats = struct {
    start_ms: u64,
    manifest_ms: u64 = 0,
    map_ram_ms: u64 = 0,
    memory_ms: u64 = 0,
    state_ms: u64 = 0,
    pre_run_ms: u64 = 0,
    mode: []const u8 = "none",
    chunk_count: usize = 0,
    nonzero_chunk_count: usize = 0,
};

/// Fills guest RAM from the spore. Local backing is already mapped; verified
/// chunks are loaded into anonymous RAM.
pub fn restoreMemory(
    allocator: std.mem.Allocator,
    restore: Start.Restore,
    memory: spore.MemoryManifest,
    ram_bytes: []u8,
    file_backed: bool,
    restore_stats: *?RestoreStats,
) !void {
    const memory_plan = try spore.validateMemoryForRam(memory, ram_bytes.len);
    if (restore_stats.*) |*stats| {
        stats.chunk_count = memory_plan.chunk_count;
        stats.nonzero_chunk_count = memory_plan.nonzero_chunk_count;
    }
    switch (restore.ram) {
        .fresh => return error.BadManifest,
        .local_backing => {
            if (!file_backed) return error.BadManifest;
            if (restore_stats.*) |*stats| stats.mode = "local_backing";
        },
        .eager_chunks => {
            if (file_backed) return error.BadManifest;
            if (restore_stats.*) |*stats| stats.mode = "eager_chunks";
            const memory_start = deadline.system_clock.nowMs();
            try spore.loadMemory(allocator, restore.dir, memory, ram_bytes);
            if (restore_stats.*) |*stats| stats.memory_ms = deadline.system_clock.nowMs() - memory_start;
        },
    }
}

/// Logs `{backend} restore metrics: ...` and hands the timings to the probe.
pub fn emitRestoreMetrics(comptime backend: []const u8, prepared: *const Prepared, restore_stats: *?RestoreStats, start_ms: u64) void {
    if (restore_stats.*) |*stats| {
        var buffer: [512]u8 = undefined;
        const message = formatRestoreMetrics(backend, &buffer, prepared.ram_size, stats, start_ms);
        if (prepared.config.probeStream()) |probe| probe.setBackendRestoreMetrics(stats.memory_ms, stats.state_ms, stats.pre_run_ms);
        std.log.info("{s}", .{message});
    }
}

fn formatRestoreMetrics(comptime backend: []const u8, buffer: []u8, ram_size: u64, stats: *RestoreStats, start_ms: u64) []const u8 {
    stats.pre_run_ms = start_ms - stats.start_ms;
    return std.fmt.bufPrint(
        buffer,
        backend ++ " restore metrics: mode={s} ram_mib={d} chunks={d} nonzero_chunks={d} manifest_ms={d} map_ram_ms={d} memory_ms={d} state_ms={d} pre_run_ms={d}",
        .{
            stats.mode,
            ram_size / 1024 / 1024,
            stats.chunk_count,
            stats.nonzero_chunk_count,
            stats.manifest_ms,
            stats.map_ram_ms,
            stats.memory_ms,
            stats.state_ms,
            stats.pre_run_ms,
        },
    ) catch unreachable;
}

pub fn captureTransports(allocator: std.mem.Allocator, transports: []mmio.Transport) ![]spore.TransportState {
    const out = try allocator.alloc(spore.TransportState, transports.len);
    for (transports, 0..) |*t, i| {
        const queues = try allocator.alloc(spore.QueueState, t.dev.queue_count);
        for (queues, 0..) |*qs, qi| {
            const q = t.queues[qi];
            qs.* = .{
                .size = q.size,
                .ready = q.ready,
                .desc_addr = q.desc_addr,
                .avail_addr = q.avail_addr,
                .used_addr = q.used_addr,
                .last_avail = q.last_avail,
                .used_idx = q.used_idx,
            };
        }
        out[i] = .{
            .device_id = t.dev.device_id,
            .status = t.status,
            .device_features_sel = t.device_features_sel,
            .driver_features_sel = t.driver_features_sel,
            .driver_features = t.driver_features,
            .queue_sel = t.queue_sel,
            .interrupt_status = t.interrupt_status,
            .queues = queues,
        };
    }
    return out;
}

pub fn applyTransports(transports: []mmio.Transport, states: []const spore.TransportState) !void {
    if (states.len != transports.len) return error.PlatformMismatch;
    for (transports, states) |*t, s| {
        if (t.dev.device_id != s.device_id) return error.PlatformMismatch;
        if (s.queues.len != t.dev.queue_count) return error.PlatformMismatch;
        t.applyRestoredFeatureState(s.status, s.driver_features) catch return error.BadManifest;
        t.device_features_sel = s.device_features_sel;
        t.driver_features_sel = s.driver_features_sel;
        t.queue_sel = s.queue_sel;
        t.interrupt_status = s.interrupt_status;
        for (s.queues, 0..) |qs, qi| {
            const restored: @TypeOf(t.queues[qi]) = .{
                .size = qs.size,
                .ready = qs.ready,
                .desc_addr = qs.desc_addr,
                .avail_addr = qs.avail_addr,
                .used_addr = qs.used_addr,
                .last_avail = qs.last_avail,
                .used_idx = qs.used_idx,
            };
            restored.validateLayout() catch return error.BadManifest;
            t.queues[qi] = restored;
        }
    }
}

/// Seals the writable rootfs head into `dir` once virtio-blk has no requests
/// in flight.
pub fn takeRootfsSnapshot(
    allocator: std.mem.Allocator,
    dir: []const u8,
    transports: []mmio.Transport,
    disk_snapshot: ?disk_layer.SnapshotState,
) !?spore.Disk {
    const disk_state = disk_snapshot orelse return error.BadManifest;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const devices = try captureTransports(arena, transports);
    if (!try spore.diskQueuesQuiescent(disk_state.base.device, devices)) {
        std.log.err("cannot snapshot writable rootfs-backed VM while virtio-blk has pending requests", .{});
        return error.DeviceStatePending;
    }
    return try disk_state.finish(allocator, dir, true);
}

pub fn monitorStats(sealer: ?*const dirty_ram.Sealer) vsock_control.ControlStats {
    var result = vsock_control.ControlStats{};
    if (sealer) |active| {
        result.chunks_nonzero = @intCast(active.nonzeroChunkCount());
        result.dirty_chunks_pending = @intCast(active.dirtyChunksPending());
    }
    return result;
}

pub fn logNamedSnapshotPublication(comptime backend: []const u8, metrics: vsock_control.SnapshotPublishMetrics, pause_started_ns: u64) void {
    const source_pause_ns = runtime_disk_fork_capture.elapsedSince(pause_started_ns);
    std.log.info(
        backend ++ " named snapshot publication metrics: cache_lock_wait_ms={d} manifest_pin_authorization_ms={d} active_lease_handoff_ms={d} lifecycle_spec_ms={d} final_publication_ms={d} source_pause_ms={d}",
        .{
            vsock_control.SnapshotPublishMetrics.nsToMs(metrics.cache_lock_wait_ns),
            vsock_control.SnapshotPublishMetrics.nsToMs(metrics.manifest_pin_authorization_ns),
            vsock_control.SnapshotPublishMetrics.nsToMs(metrics.active_lease_handoff_ns),
            vsock_control.SnapshotPublishMetrics.nsToMs(metrics.lifecycle_spec_ns),
            vsock_control.SnapshotPublishMetrics.nsToMs(metrics.final_publication_ns),
            vsock_control.SnapshotPublishMetrics.nsToMs(source_pause_ns),
        },
    );
}

pub const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

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
    var stream: vsock_stream.HostStream = undefined;
    var config = testBoot(.{});
    config.probe = .{ .stream = &stream, .start = .control };
    try expectRejected(error.DeferredExecProbeRequiresControl, config, test_rules);
}

test "prepare rejects a probe-completion capture that can never fire" {
    var stream: vsock_stream.HostStream = undefined;
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

test "prepare resolves vCPUs and RAM from a multi-vCPU restore manifest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});

    var vcpu_states: [2]spore.VcpuState = undefined;
    var redistributors: [2]gicv3.RedistributorState = undefined;
    for (&vcpu_states, &redistributors, 0..) |*state, *redistributor, index| {
        const mpidr = aarch64_topology.mpidrForIndex(@intCast(index));
        state.* = .{
            .index = @intCast(index),
            .mpidr = mpidr,
            .gprs = [_]u64{0} ** 31,
            .pc = 0,
            .cpsr = 0,
            .fpcr = 0,
            .fpsr = 0,
            .simd = [_][2]u64{.{ 0, 0 }} ** 32,
            .sys_regs = &.{},
            .icc_regs = &.{},
            .vtimer = .{ .cntvct = 0, .cntv_ctl = 0, .cntv_cval = 0 },
        };
        redistributor.* = .{ .mpidr = mpidr, .regs = &.{} };
    }
    try spore.saveManifest(arena, dir, .{
        .platform = .{
            .cpu_profile = board.cpu_profile,
            .device_model_version = board.device_model_version,
            .vcpu_count = 2,
            .ram_base = board.ram_base,
            .ram_size = spore.chunk_size,
            .gic_dist_base = 0x0800_0000,
            .gic_redist_base = 0x0802_0000,
            .gic_redist_stride = 0x2_0000,
            .counter_frequency_hz = 24_000_000,
        },
        .machine = .{ .multi = .{
            .vcpus = &vcpu_states,
            .gic = .{ .kind = .gicv3_multi, .gicv3_multi = .{ .dist_regs = &.{}, .redistributors = &redistributors, .line_levels = &.{} } },
        } },
        .devices = &.{},
        .generation = .{ .generation = 1, .interrupt_status = 0, .params_b64 = "" },
        .memory = .{ .logical_size = spore.chunk_size, .chunk_size = spore.chunk_size, .zero_ranges = &.{.{ .start = 0, .count = 1 }} },
    });

    // One vCPU means "use the manifest's count": the manifest supplies two
    // vCPUs and its RAM size.
    var config = testBoot(.{});
    config.start = .{ .restore = .{ .dir = dir, .ram = .eager_chunks } };
    var resolved = try prepare(std.testing.allocator, config, test_rules);
    defer resolved.deinit();
    try std.testing.expect(resolved.manifest != null);
    try std.testing.expectEqual(@as(topology.VcpuCount, 2), resolved.vcpus);
    try std.testing.expectEqual(@as(u64, spore.chunk_size), resolved.ram_size);
    try std.testing.expectEqual(@as(u64, 0), resolved.virtio_mem_region_size);

    config.vcpus = 2;
    var matching = try prepare(std.testing.allocator, config, test_rules);
    defer matching.deinit();
    try std.testing.expectEqual(@as(topology.VcpuCount, 2), matching.vcpus);

    config.vcpus = 3;
    try expectRejected(error.PlatformMismatch, config, test_rules);
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

    // Console, net, vsock, rng, four disks and virtio-mem: one over the board's eight.
    config = testBoot(.{ .virtio_mem_region_size = 1024 * 1024 * 1024 });
    config.disk_backend = .{ .file = -1 };
    config.context_disk_fd = -1;
    config.build_input_disk_backends = backends[0..1];
    config.build_cache_disk_backend = .{ .file = -1 };
    try expectRejected(error.TooManyVirtioDevices, config, test_rules);

    config.start.boot.virtio_mem_region_size = 0;
    var prepared = try prepare(std.testing.allocator, config, test_rules);
    prepared.deinit();
}

test "devices take virtio slots in the order the guest enumerates them" {
    var storage: [blk.sector_size]u8 = undefined;
    var config = testBoot(.{});
    config.disk_backend = .{ .memory = &storage };
    var devices: Devices = undefined;
    devices.init(&config, .{ .addr = board.ram_base, .region_size = 128 * 1024 * 1024, .requested_size = 0 });
    defer devices.net.shutdown();

    const expected = [_]u32{ console.device_id, blk.device_id, net.device_id, vsock.device_id, rng.device_id, virtio_mem.device_id };
    try std.testing.expectEqual(expected.len, devices.transports().len);
    for (devices.transports(), expected) |transport, device_id| try std.testing.expectEqual(device_id, transport.dev.device_id);
    try std.testing.expectEqual(@as(usize, 2), devices.net_index);
    try std.testing.expectEqual(@as(usize, 3), devices.vsock_index);
    try std.testing.expectEqual(@as(?usize, 5), devices.mem_index);
}

test "restore metrics include source, RAM size, and backend timings" {
    var stats = RestoreStats{
        .start_ms = 100,
        .manifest_ms = 1,
        .map_ram_ms = 2,
        .memory_ms = 3,
        .state_ms = 4,
        .mode = "local_backing",
        .chunk_count = 5,
        .nonzero_chunk_count = 6,
    };
    var buffer: [512]u8 = undefined;
    const line = formatRestoreMetrics("hvf", &buffer, 1024 * 1024 * 1024, &stats, 110);
    try std.testing.expectEqualStrings(
        "hvf restore metrics: mode=local_backing ram_mib=1024 chunks=5 nonzero_chunks=6 manifest_ms=1 map_ram_ms=2 memory_ms=3 state_ms=4 pre_run_ms=10",
        line,
    );
}

test "file-backed RAM mappings isolate parent and siblings" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backing = try tmp.dir.createFile(io, "ram.backing", .{ .read = true });
    defer backing.close(io);
    const size: u64 = std.heap.page_size_min;
    if (std.c.ftruncate(backing.handle, @intCast(size)) != 0) return error.IoFailed;
    try backing.writePositionalAll(io, &[_]u8{0x42}, 0);

    const parent = try mapFileBackedRamFd(backing.handle, size);
    defer parent.deinit();
    const first = try mapFileBackedRamFd(backing.handle, size);
    defer first.deinit();
    const second = try mapFileBackedRamFd(backing.handle, size);
    defer second.deinit();
    parent.bytes[0] = 0x11;
    try std.testing.expectEqual(@as(u8, 0x42), first.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x42), second.bytes[0]);
    first.bytes[0] = 0x22;
    second.bytes[0] = 0x33;
    try std.testing.expectEqual(@as(u8, 0x11), parent.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x22), first.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x33), second.bytes[0]);
    var stored: [1]u8 = undefined;
    try std.testing.expectEqual(stored.len, try backing.readPositionalAll(io, &stored, 0));
    try std.testing.expectEqual(@as(u8, 0x42), stored[0]);
}

test "transport restore rejects unoffered block features" {
    var storage: [blk.sector_size]u8 = undefined;
    var block = blk.Blk.initWithOptions(.{ .memory = &storage }, .{});
    var transports = [_]mmio.Transport{mmio.Transport.init(block.device())};
    var queues = [_]spore.QueueState{.{
        .size = 0,
        .ready = false,
        .desc_addr = 0,
        .avail_addr = 0,
        .used_addr = 0,
        .last_avail = 0,
        .used_idx = 0,
    }};
    const states = [_]spore.TransportState{.{
        .device_id = blk.device_id,
        .status = mmio.status_features_ok,
        .device_features_sel = 0,
        .driver_features_sel = 0,
        .driver_features = blk.feature_write_zeroes,
        .queue_sel = 0,
        .interrupt_status = 0,
        .queues = &queues,
    }};

    try std.testing.expectError(error.BadManifest, applyTransports(&transports, &states));
    try std.testing.expectEqual(@as(u64, 0), transports[0].driver_features);
}
