//! Backend-neutral code for the aarch64 VMM backends (HVF and KVM).
//!
//! Callers describe a run with `Config`; `prepare` validates it once, loads
//! the restore manifest, and resolves vCPU and memory sizes before either
//! backend creates a VM. Both backends share the device set, RAM mapping and
//! restore, transport snapshot helpers, spore writing and machine restore
//! below.

const std = @import("std");
const TestDir = @import("../test_dir.zig").TestDir;
const aarch64_topology = @import("topology.zig");
const board = @import("board.zig");
const capture = @import("../capture.zig");
const deadline = @import("../deadline.zig");
const dirty_ram = @import("../dirty_ram.zig");
const disk_layer = @import("../disk_layer.zig");
const generation = @import("../generation.zig");
const guestmem = @import("../guestmem.zig");
const gicv3 = @import("gicv3.zig");
const local_backing = @import("../local_backing.zig");
const local_paths = @import("../local_paths.zig");
const platform = @import("../platform.zig");
const ram_restore = @import("../ram_restore.zig");
const rootfs_mod = @import("../rootfs.zig");
const runtime_disk_fork_capture = @import("../runtime_disk_fork_capture.zig");
const saved_spore_pin = @import("../saved_spore_pin.zig");
const spore = @import("../spore.zig");
const test_barrier = @import("../test_barrier.zig");
const topology = @import("../topology.zig");
const blk = @import("../virtio/blk.zig");
const console = @import("../virtio/console.zig");
const virtio_mem = @import("../virtio/mem.zig");
const mmio = @import("../virtio/mmio.zig");
const net = @import("../virtio/net.zig");
const queue = @import("../virtio/queue.zig");
const rng = @import("../virtio/rng.zig");
const transport_snapshot = @import("../virtio/transport_snapshot.zig");
const vsock = @import("../virtio/vsock.zig");
const vsock_control = @import("../virtio/vsock_control.zig");
const vsock_stream = @import("../virtio/vsock_stream.zig");

pub const ExitCause = enum { guest_off, guest_reset, snapshotted, probe_complete, monitor_stopped };

/// A guest access to an emulated device register.
pub const Mmio = struct {
    addr: u64,
    size_log2: u2,
    /// The value written, or null for a read.
    write: ?u64,
};

/// Why a backend's `Vcpu.run` returned to its run loop.
pub const Exit = union(enum) {
    /// A device register access. The loop emulates it, then calls
    /// `completeMmio` with the value a read returns.
    mmio: Mmio,
    /// A host-side wake interrupted the guest.
    kicked,
    /// The guest is waiting for an interrupt.
    wfi,
    /// The guest powered off or asked for a reset.
    shutdown: Shutdown,
    /// The backend handled the exit itself; the loop runs its host-side
    /// checks before entering the guest again.
    handled,

    pub const Shutdown = enum {
        off,
        reset,

        pub fn cause(self: Shutdown) ExitCause {
            return switch (self) {
                .off => .guest_off,
                .reset => .guest_reset,
            };
        }
    };
};

pub const max_build_input_disks = 2;

pub const Config = struct {
    /// Blocks and wakes the run's threads.
    io: std.Io,
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

/// virtio-mem's region: guest RAM past the initial size that the guest sees
/// only once the driver plugs it. `vm` provides
/// `mapHotplug(bytes, guest_addr, mapped_bytes, new_bytes)`, which maps the
/// first `new_bytes` of `bytes` when the first `mapped_bytes` already are,
/// and `unmapHotplug(guest_addr, mapped_bytes)`.
pub fn Hotplug(comptime Vm: type) type {
    return struct {
        const Self = @This();

        vm: *const Vm,
        bytes: []align(std.heap.page_size_min) u8,
        guest_addr: u64,
        mapped_bytes: u64 = 0,

        pub fn deinit(self: *Self) void {
            if (self.mapped_bytes != 0) self.vm.unmapHotplug(self.guest_addr, self.mapped_bytes);
        }

        /// The virtio-mem device configuration that plugs into this region.
        pub fn memConfig(self: *Self) virtio_mem.Config {
            return .{
                .addr = self.guest_addr,
                .region_size = @intCast(self.bytes.len),
                .requested_size = 0,
                .plug_context = self,
                .plugFn = plug,
            };
        }

        fn plug(ctx: *anyopaque, requested_size: u64) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mapForGuest(requested_size) catch return false;
            return true;
        }

        fn mapForGuest(self: *Self, bytes: u64) !void {
            if (bytes > self.bytes.len) return error.InvalidVirtioMemRequest;
            if (bytes <= self.mapped_bytes) return;
            try self.vm.mapHotplug(self.bytes, self.guest_addr, self.mapped_bytes, bytes);
            self.mapped_bytes = bytes;
            std.log.debug("virtio-mem mapped hotplug region: addr=0x{x} bytes={d}", .{ self.guest_addr, bytes });
        }
    };
}

/// Emulates a guest access to the generation device or a virtio-mmio
/// transport and returns the value a read sees. Device interrupt lines go
/// through `vm.setSpi(intid, level)`. Accesses outside every device read as
/// zero and drop writes.
pub fn dispatchMmio(
    vm: anytype,
    access: Mmio,
    transports: []mmio.Transport,
    gen_dev: *generation.Device,
    ram: guestmem.GuestRam,
) !u64 {
    const ipa = access.addr;

    if (ipa >= board.generation_base and ipa < board.generation_base + board.generation_size) {
        const offset = ipa - board.generation_base;
        if (access.write) |value| {
            if (gen_dev.write(offset, value, access.size_log2)) {
                try vm.setSpi(board.generationIntid(), false);
            }
            return 0;
        }
        return gen_dev.read(offset, access.size_log2);
    }

    const dev_index = blk: {
        if (ipa < board.virtio_base) break :blk null;
        const idx = (ipa - board.virtio_base) / board.virtio_stride;
        if (idx >= transports.len) break :blk null;
        break :blk idx;
    };
    if (dev_index) |idx| {
        const t = &transports[@intCast(idx)];
        const intid = board.virtioDeviceIntid(@intCast(idx));
        const offset = ipa - board.virtioDeviceBase(@intCast(idx));
        if (access.write) |value| {
            if (t.write(offset, @truncate(value), ram)) try vm.setSpi(intid, true);
            // Interrupt ack lowers the line (covers level semantics too).
            if (offset == 0x064) try vm.setSpi(intid, false);
            return 0;
        }
        return t.read(offset);
    }

    std.log.debug("stray mmio {s} at ipa=0x{x}", .{ if (access.write != null) "write" else "read", ipa });
    return 0;
}

/// Delivers the host-to-guest packets `device` (vsock or net) has queued for
/// the transport at `index` and raises its interrupt if any went in.
/// Returns whether any did.
pub fn flushRx(vm: anytype, device: anytype, transports: []mmio.Transport, index: usize, ram: guestmem.GuestRam) !bool {
    if (!device.flushPendingRx(&transports[index], ram)) return false;
    try vm.setSpi(board.virtioDeviceIntid(@intCast(index)), true);
    return true;
}

/// Raises the generation interrupt a restored generation change left
/// unacknowledged.
pub fn raiseGenerationIrqIfPending(vm: anytype, gen_dev: *const generation.Device) !void {
    if (gen_dev.interrupt_status & generation.irq_generation_changed != 0) {
        try vm.setSpi(board.generationIntid(), true);
    }
}

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
/// chunks are loaded into anonymous RAM. Callers pass the mapping straight
/// from `mapRam`, before anything writes guest RAM: chunk loading skips zero
/// chunks because a fresh anonymous mapping already reads as zero.
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

/// Applies serialized transport state once guest RAM is mapped. Restored
/// queues skip QueueReady, so a ready queue's rings are checked against
/// `ram` here, and a manifest whose rings the device cannot use is refused.
pub fn applyTransports(transports: []mmio.Transport, states: []const spore.TransportState, ram: guestmem.GuestRam) !void {
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
            if (restored.ready) restored.validateRings(ram) catch return error.BadManifest;
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

/// Tracks the guest RAM chunks written since tracking started, so a snapshot
/// seals only those. Host writes into guest RAM (device DMA) arrive through
/// `markGuestWriteCallback`; `Backend` finds the guest's own writes. It holds
/// the backend's state and provides, each taking the tracker:
/// - `start(tracker, allocator)`, once the boot image is in RAM;
/// - `flush(tracker)`, which seals every chunk written since the last flush
///   and runs with `mutex` held;
/// - `stop(tracker)`, on teardown;
/// - `metrics_mode` and `logSnapshotMetrics(tracker, SnapshotMetrics)`.
pub fn DirtyTracker(comptime Backend: type) type {
    return struct {
        const Self = @This();

        sealer: dirty_ram.Sealer,
        backend: Backend,
        tracking_start_ms: u64 = 0,
        io: std.Io,
        mutex: std.Io.Mutex = .init,

        pub const metrics_mode = Backend.metrics_mode;

        pub fn start(allocator: std.mem.Allocator, io: std.Io, options: dirty_ram.Options, backend: Backend) !Self {
            var tracker = Self{ .sealer = try dirty_ram.Sealer.start(allocator, options), .backend = backend, .io = io };
            errdefer tracker.sealer.deinit();
            try Backend.start(&tracker, allocator);
            tracker.tracking_start_ms = deadline.system_clock.nowMs();
            return tracker;
        }

        pub fn deinit(self: *Self) void {
            Backend.stop(self);
            self.sealer.deinit();
        }

        /// Seals the last dirty chunks and completes the RAM backing file.
        pub fn finish(self: *Self) !spore.MemoryManifest {
            const clock = deadline.system_clock;
            const tail_start = clock.nowMs();
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                try Backend.flush(self);
            }
            self.sealer.stats.tail_flush_ms = clock.nowMs() - tail_start;
            self.sealer.finishRates(self.tracking_start_ms, clock.nowMs());
            return try self.sealer.finishBacking();
        }

        /// Logs a single-vCPU snapshot's metrics with the backend's counters.
        pub fn logSnapshotMetrics(self: *const Self, m: SnapshotMetrics) void {
            Backend.logSnapshotMetrics(self, m);
        }

        /// `guestmem.GuestRam.dirty_fn`: the host wrote `len` bytes at `gpa`.
        pub fn markGuestWriteCallback(ctx: *anyopaque, gpa: u64, len: u64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.markGuestWrite(gpa, len);
        }

        fn markGuestWrite(self: *Self, gpa: u64, len: u64) void {
            if (len == 0) return;
            if (gpa < board.ram_base) return;
            const guest_offset = gpa - board.ram_base;
            if (guest_offset >= self.sealer.ram.len) return;
            const start_offset: usize = @intCast(guest_offset);
            const remaining: u64 = @intCast(self.sealer.ram.len - start_offset);
            const capped_len: usize = @intCast(@min(len, remaining));
            if (capped_len == 0) return;

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.sealer.markHostDirtyRange(start_offset, capped_len);
        }
    };
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
        backend ++ " named snapshot publication metrics: cache_lock_wait_ms={d} manifest_write_ms={d} active_lease_handoff_ms={d} lifecycle_spec_ms={d} final_publication_ms={d} source_pause_ms={d}",
        .{
            vsock_control.SnapshotPublishMetrics.nsToMs(metrics.cache_lock_wait_ns),
            vsock_control.SnapshotPublishMetrics.nsToMs(metrics.manifest_write_ns),
            vsock_control.SnapshotPublishMetrics.nsToMs(metrics.active_lease_handoff_ns),
            vsock_control.SnapshotPublishMetrics.nsToMs(metrics.lifecycle_spec_ns),
            vsock_control.SnapshotPublishMetrics.nsToMs(metrics.final_publication_ns),
            vsock_control.SnapshotPublishMetrics.nsToMs(source_pause_ns),
        },
    );
}

/// The parts of a run a snapshot captures besides machine state. They stay
/// the same for the whole run.
pub const SnapshotSource = struct {
    config: *const Config,
    transports: []mmio.Transport,
    gen_dev: *const generation.Device,
    vsock_dev: *const vsock.Vsock,
    /// All guest RAM, including any virtio-mem region.
    ram_bytes: []const u8,
    /// Initial RAM size.
    ram_size: u64,
    /// Present only when the run has virtio-mem, which needs one vCPU.
    memory_device: ?*const virtio_mem.Mem = null,
};

pub const SnapshotTarget = struct {
    dir: []const u8,
    /// `finish` seals the writable disk layer into the spore. A disk fork
    /// only checks that the disk queues are idle and leaves the layer live.
    disk: enum { finish, quiesce_only } = .finish,
    /// Held by a named save that publishes through the rootfs cache.
    rootfs_cache_lock: ?*const rootfs_mod.RootfsCacheLock = null,
};

/// Phase timings and sizes for a `<backend> snapshot metrics` line.
pub const SnapshotMetrics = struct {
    ram_mib: u64,
    chunks: usize,
    nonzero_chunks: usize,
    machine_ms: u64,
    devices_ms: u64,
    generation_ms: u64,
    memory_ms: u64,
    disk_ms: u64,
    manifest_ms: u64,
    total_ms: u64,
};

/// Writes a spore of the stopped guest to `target.dir` and logs
/// `<backend> snapshot metrics`. Every vCPU must be stopped: device feature
/// selection is guest-mutable MMIO state, so validating it while a vCPU runs
/// would race a reset or DRIVER_FEATURES write.
///
/// Machine state comes from each `vcpu.capture(vm, arena)` and
/// `vm.captureGic(arena, vcpus)`; the platform block is the board contract.
/// `dirty_tracker` is an optional pointer to the backend's tracker, which
/// provides `finish()`, `metrics_mode` and `logSnapshotMetrics(SnapshotMetrics)`;
/// without one, RAM is scanned in full.
pub fn writeSnapshot(
    allocator: std.mem.Allocator,
    comptime backend: []const u8,
    vm: anytype,
    vcpus: anytype,
    dirty_tracker: anytype,
    source: SnapshotSource,
    target: SnapshotTarget,
) !void {
    const config = source.config;
    const dir = target.dir;
    try transport_snapshot.validateFullSnapshotDevices(source.transports, source.vsock_dev);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var pin_threaded = std.Io.Threaded.init(allocator, .{});
    defer pin_threaded.deinit();
    const pin_io = pin_threaded.io();
    const clock = deadline.system_clock;

    const total_start = clock.nowMs();
    const machine = try captureMachine(arena, vm, vcpus);
    const machine_ms = clock.nowMs() - total_start;
    const devices_start = clock.nowMs();
    const devices = try captureTransports(arena, source.transports);
    const devices_ms = clock.nowMs() - devices_start;
    var disk_quiesced = false;
    if (config.disk_snapshot) |disk_state| {
        if (!try spore.diskQueuesQuiescent(disk_state.base.device, devices)) {
            std.log.err("cannot snapshot writable rootfs-backed VM while virtio-blk has pending requests", .{});
            return error.DeviceStatePending;
        }
        disk_quiesced = true;
    } else if (config.rootfs) |rootfs_artifact| {
        if (!try spore.rootfsQueuesQuiescent(rootfs_artifact, devices)) {
            std.log.err("cannot snapshot rootfs-backed VM while virtio-blk has pending requests", .{});
            return error.DeviceStatePending;
        }
    }
    const generation_start = clock.nowMs();
    const gen_state = try source.gen_dev.capture(arena);
    const generation_ms = clock.nowMs() - generation_start;
    // Fetch a store image's missing objects before sealing the disk, so a
    // failed download leaves nothing written and does not hold the cache
    // lock. A disk fork keeps the layer live, so it fetches nothing.
    if (target.disk == .finish) if (config.disk_snapshot) |disk_state| try disk_state.fetchFromStore();
    const memory_start = clock.nowMs();
    const memory = if (dirty_tracker) |tracker|
        try tracker.finish()
    else
        try spore.saveMemoryWithBacking(arena, dir, source.ram_bytes);
    const memory_ms = clock.nowMs() - memory_start;
    const memory_state = if (source.memory_device) |device| try device.captureState(arena, source.ram_size) else null;
    if (config.environ_map) |environ| {
        try local_backing.writeLocalMemoryBackingProof(arena, environ, dir, memory, source.ram_bytes.len);
    }
    const disk_snapshot = if (target.disk == .finish) config.disk_snapshot else null;
    var owned_cache_lock: ?rootfs_mod.RootfsCacheLock = null;
    defer if (owned_cache_lock) |*lock| lock.deinit();
    const disk_root = if (disk_snapshot != null and config.environ_map != null) blk: {
        const cache_root = try local_paths.rootfsCacheRootPath(arena, config.environ_map.?);
        if (target.rootfs_cache_lock) |lock| {
            if (!try lock.ensureHeldFor(arena, cache_root)) return error.RootfsCacheLockNotHeld;
        } else owned_cache_lock = try rootfs_mod.lockRootfsCacheExclusive(pin_io, arena, cache_root);
        break :blk cache_root;
    } else dir;
    const disk_start = clock.nowMs();
    const disk_manifest = if (disk_snapshot) |disk_state| try disk_state.finish(arena, disk_root, disk_quiesced) else null;
    const disk_ms = clock.nowMs() - disk_start;
    const manifest_start = clock.nowMs();
    const saved_manifest = spore.Manifest{
        .platform = platform.contract(@intCast(vcpus.len), source.ram_size, try platform.hostCounterFrequencyHz()),
        .machine = machine,
        .devices = devices,
        .generation = gen_state,
        .annotations = config.annotations,
        .rootfs = config.rootfs,
        .disk = disk_manifest,
        .network = config.network_manifest,
        .sessions = config.sessions,
        .memory_state = memory_state,
        .memory = memory,
    };
    if (disk_manifest) |disk| {
        if (config.environ_map != null) {
            const registry = try saved_spore_pin.LockedRegistry.init(arena, disk_root, target.rootfs_cache_lock orelse &owned_cache_lock.?);
            try saved_spore_pin.publishManifest(pin_io, arena, registry, dir, disk, saved_manifest);
        } else try spore.saveManifest(arena, dir, saved_manifest);
    } else try spore.saveManifest(arena, dir, saved_manifest);
    const manifest_ms = clock.nowMs() - manifest_start;
    const total_ms = clock.nowMs() - total_start;
    const memory_plan = try spore.validateMemoryForRam(memory, source.ram_bytes.len);
    const metrics = SnapshotMetrics{
        .ram_mib = source.ram_size / 1024 / 1024,
        .chunks = memory_plan.chunk_count,
        .nonzero_chunks = memory_plan.nonzero_chunk_count,
        .machine_ms = machine_ms,
        .devices_ms = devices_ms,
        .generation_ms = generation_ms,
        .memory_ms = memory_ms,
        .disk_ms = disk_ms,
        .manifest_ms = manifest_ms,
        .total_ms = total_ms,
    };
    if (vcpus.len > 1) {
        std.log.info(
            backend ++ " snapshot metrics: version=1 vcpus={d} mode={s} ram_mib={d} chunks={d} nonzero_chunks={d} machine_ms={d} devices_ms={d} generation_ms={d} memory_ms={d} disk_ms={d} manifest_ms={d} snapshot_total_ms={d}",
            .{
                vcpus.len,
                if (dirty_tracker) |tracker| @TypeOf(tracker.*).metrics_mode else "full-scan",
                metrics.ram_mib,
                metrics.chunks,
                metrics.nonzero_chunks,
                metrics.machine_ms,
                metrics.devices_ms,
                metrics.generation_ms,
                metrics.memory_ms,
                metrics.disk_ms,
                metrics.manifest_ms,
                metrics.total_ms,
            },
        );
    } else if (dirty_tracker) |tracker| {
        tracker.logSnapshotMetrics(metrics);
    } else {
        std.log.info(
            backend ++ " snapshot metrics: mode=full-scan ram_mib={d} chunks={d} nonzero_chunks={d} machine_ms={d} devices_ms={d} generation_ms={d} memory_ms={d} disk_ms={d} manifest_ms={d} snapshot_pause_ms={d} snapshot_total_ms={d}",
            .{
                metrics.ram_mib,
                metrics.chunks,
                metrics.nonzero_chunks,
                metrics.machine_ms,
                metrics.devices_ms,
                metrics.generation_ms,
                metrics.memory_ms,
                metrics.disk_ms,
                metrics.manifest_ms,
                metrics.total_ms,
                metrics.total_ms,
            },
        );
    }
    std.log.info("spore written to {s}", .{dir});
}

/// Writes the RAM half of a disk fork with `writeSnapshot`, then hands the
/// fork batch to the control. `pause_started_ns` is when the source stopped.
pub fn captureDiskFork(
    allocator: std.mem.Allocator,
    comptime backend: []const u8,
    vm: anytype,
    vcpus: anytype,
    dirty_tracker: anytype,
    source: SnapshotSource,
    fork: vsock_control.DiskForkAction,
    control: vsock_control.Control,
    pause_started_ns: u64,
) !void {
    const disk = source.config.disk_snapshot orelse return error.BadManifest;
    try writeSnapshot(allocator, backend, vm, vcpus, dirty_tracker, source, .{ .dir = fork.dir, .disk = .quiesce_only });
    const ram_capture_ns = runtime_disk_fork_capture.elapsedSince(pause_started_ns);
    var batch = try runtime_disk_fork_capture.prepare(allocator, disk, fork.count, .{
        .allow_copy = fork.allow_copy,
        .force_copy = fork.force_copy,
    });
    defer batch.deinit();
    batch.pause_started_ns = pause_started_ns;
    batch.ram_capture_ns = ram_capture_ns;
    try control.completeDiskFork(&batch);
}

/// One vCPU saves the `single` machine shape, more save `multi` with every
/// vCPU timer moved onto vCPU 0's counter.
fn captureMachine(arena: std.mem.Allocator, vm: anytype, vcpus: anytype) !spore.Machine {
    const states = try arena.alloc(spore.VcpuState, vcpus.len);
    for (vcpus, states) |*vcpu, *state| state.* = try vcpu.capture(vm, arena);
    const gic = try vm.captureGic(arena, vcpus.len);
    try gicv3.validate(gic);
    if (states.len == 1) {
        const s = states[0];
        return .{ .single = .{
            .gprs = s.gprs,
            .pc = s.pc,
            .cpsr = s.cpsr,
            .fpcr = s.fpcr,
            .fpsr = s.fpsr,
            .simd = s.simd,
            .sys_regs = s.sys_regs,
            .icc_regs = s.icc_regs,
            .vtimer = s.vtimer,
            .gic = gic,
        } };
    }
    shareVcpuCounter(states, states[0].vtimer.cntvct);
    return .{ .multi = .{ .vcpus = states, .gic = gic } };
}

/// Restores machine state from a manifest: the GIC, then one guest counter
/// for the whole VM (vCPU 0's), then each vCPU with its timer moved onto that
/// counter. `vm` provides `applyGic(allocator, vcpus, state)` and
/// `setCounter(guest_cntvct)`; each vCPU provides `apply(vm, state)`.
pub fn restoreMachine(allocator: std.mem.Allocator, vm: anytype, vcpus: anytype, machine: spore.Machine) !void {
    const states = try restoreVm(allocator, vm, vcpus, machine);
    defer allocator.free(states);
    for (vcpus, states) |*vcpu, state| try vcpu.apply(vm, state);
}

/// The once-per-VM half of `restoreMachine`: checks `machine` against
/// `vcpus`, applies the GIC and sets the guest counter. Returns each vCPU's
/// state on that counter, for its `apply`; the caller frees it.
fn restoreVm(allocator: std.mem.Allocator, vm: anytype, vcpus: anytype, machine: spore.Machine) ![]spore.VcpuState {
    var single: [1]spore.VcpuState = undefined;
    const saved: []const spore.VcpuState, const gic: gicv3.State = switch (machine) {
        .single => |m| blk: {
            single[0] = .{
                .index = 0,
                .mpidr = aarch64_topology.mpidrForIndex(0),
                .gprs = m.gprs,
                .pc = m.pc,
                .cpsr = m.cpsr,
                .fpcr = m.fpcr,
                .fpsr = m.fpsr,
                .simd = m.simd,
                .sys_regs = m.sys_regs,
                .icc_regs = m.icc_regs,
                .vtimer = m.vtimer,
            };
            break :blk .{ &single, m.gic };
        },
        .multi => |m| .{ m.vcpus, m.gic },
    };
    if (saved.len != vcpus.len) return error.PlatformMismatch;
    for (saved, 0..) |state, index| {
        if (state.index != index or state.mpidr != aarch64_topology.mpidrForIndex(state.index)) return error.PlatformMismatch;
    }
    const states = try allocator.dupe(spore.VcpuState, saved);
    errdefer allocator.free(states);
    try vm.applyGic(allocator, vcpus, gic);
    const guest_cntvct = saved[0].vtimer.cntvct;
    try vm.setCounter(guest_cntvct);
    shareVcpuCounter(states, guest_cntvct);
    return states;
}

/// Puts every vCPU timer on one guest counter value, as KVM and HVF give the
/// whole VM one counter offset.
fn shareVcpuCounter(states: []spore.VcpuState, guest_cntvct: u64) void {
    for (states) |*state| moveVtimer(&state.vtimer, guest_cntvct);
}

/// Moves one vCPU timer onto `guest_cntvct` without changing its deadline
/// relative to the counter. Modular arithmetic keeps enabled, masked and
/// already expired timers correct across counter wrap.
fn moveVtimer(vtimer: *spore.VtimerState, guest_cntvct: u64) void {
    const delta = guest_cntvct -% vtimer.cntvct;
    vtimer.cntv_cval +%= delta;
    vtimer.cntvct = guest_cntvct;
}

/// Runs a VM: each vCPU on its own thread, while the calling thread serves
/// the control, the probe, capture requests, virtio-mem growth and
/// snapshots. Each virtio-blk device's requests run on a worker thread of its
/// own, so a slow read (an object fetched from an image store) stalls neither
/// the vCPU that notified nor any other device.
///
/// `Vm` provides `name`, `spi_needs_kick` (whether a vCPU must be kicked to
/// see a raised interrupt) and what the device and snapshot code above use.
/// `Vcpu` provides `kick()`, callable from any thread, and, on its own
/// thread: `threadStart()`, `threadExit()`, `handleCommands()` (true if it
/// served a request from another vCPU), `run(vm, vcpus)`,
/// `completeMmio(value)`, `capture(vm, arena)` and `apply(vm, state)`.
/// `Tracker` is the backend's `DirtyTracker` type.
///
/// One pause protocol stops the guest. The main thread kicks every vCPU and
/// waits until each thread has parked; then each thread in turn does an
/// action on its own vCPU (capture its state, or apply a restored one), and
/// waits until resumed. KVM refuses VGIC register access while any other vCPU
/// is in an ioctl, hence one at a time and only once all have parked.
/// Threads start paused, so the backend can boot or restore the vCPUs before
/// `run`. A pause also waits until every virtio-blk worker has served every
/// notify and returned every request, so a saved queue has nothing in flight
/// and a restored one needs no kick.
///
/// Nobody spins or polls on a fixed tick: the main thread futex-waits on
/// `events` and the vCPU threads, when parked or idle, on `vcpu_events`. A
/// waiter loads the counter, checks its state, then waits for the counter to
/// move; whoever changes that state bumps the counter afterwards.
pub fn Threaded(comptime Vm: type, comptime Vcpu: type, comptime Tracker: type) type {
    return struct {
        const Self = @This();

        vm: *Vm,
        vcpus: []Vcpu,
        devices: *Devices,
        ram: guestmem.GuestRam,
        config: *const Config,
        dirty_tracker: ?*Tracker = null,
        slots: []Slot = &.{},
        /// What each vCPU captured, or will apply, at a pause.
        states: []Captured = &.{},
        blk_workers: []BlkWorker = &.{},
        /// Serializes device emulation between the vCPU threads, the
        /// virtio-blk workers and the main thread.
        device_lock: std.Io.Mutex = .init,
        /// Held by a vCPU thread while it does a pause action.
        action_lock: std.Io.Mutex = .init,
        stop: std.atomic.Value(bool) = .init(false),
        result_lock: std.Io.Mutex = .init,
        result_value: ?Result = null,
        pause: Pause = .{},
        /// Bumped when the main thread has something to look at: a vCPU
        /// thread started or acknowledged a pause, the run ended, a control,
        /// capture or network wake, or the guest wrote to the vsock device.
        events: std.atomic.Value(u32) = .init(0),
        /// Bumped when the vCPU threads have something to look at: a pause,
        /// resume or stop, or a kick.
        vcpu_events: std.atomic.Value(u32) = .init(0),

        /// How long the main thread waits without an event. Its checks with
        /// no event of their own (control timeouts and stats, the probe
        /// deadline) run at least this often.
        const main_wait_ms = 10;
        /// How long a parked or idle vCPU thread waits without an event:
        /// 200 µs with one vCPU, 1 ms with more, as the backends' loops did.
        /// The guest timer, HVF GIC and CPU_ON requests from other vCPUs and
        /// interrupts that vCPU threads raise for an idle HVF vCPU do not
        /// end the wait.
        fn vcpuWaitNs(self: *const Self) i64 {
            return if (self.vcpus.len == 1) 200 * std.time.ns_per_us else std.time.ns_per_ms;
        }
        /// How long a capture lets the guest run on for every vCPU to leave
        /// its interrupt handler before it gives up.
        const capture_settle_ms = 1000;

        const Result = union(enum) { exit: ExitCause, err: anyerror };

        const Pause = struct {
            active: std.atomic.Value(bool) = .init(true),
            /// Each request gets the next sequence number; a vCPU thread
            /// acknowledges it once it has done `action`.
            seq: std.atomic.Value(u32) = .init(0),
            action: std.atomic.Value(Action) = .init(.none),
        };

        const Action = enum(u8) { none, capture, apply };

        const Slot = struct {
            thread: ?std.Thread = null,
            started: std.atomic.Value(bool) = .init(false),
            start_error: ?anyerror = null,
            acked: std.atomic.Value(u32) = .init(0),
            /// Holds this vCPU's captured state until the next capture.
            arena: std.heap.ArenaAllocator,
        };

        /// Serves one virtio-blk device's queue. `device_lock` guards
        /// `shared`, `seen` and `stopping`.
        const BlkWorker = struct {
            /// The device's transport slot.
            index: usize,
            shared: blk.Worker,
            /// The notifies served so far.
            seen: u32 = 0,
            stopping: bool = false,
            thread: ?std.Thread = null,
        };

        /// Starts one thread per vCPU and returns once each has started its
        /// vCPU. The threads stay paused until `run`. Call `deinit` even if
        /// this fails.
        pub fn start(self: *Self, allocator: std.mem.Allocator) !void {
            self.slots = try allocator.alloc(Slot, self.vcpus.len);
            for (self.slots) |*slot| slot.* = .{ .arena = .init(std.heap.page_allocator) };
            self.states = try allocator.alloc(Captured, self.vcpus.len);
            try self.startBlkWorkers(allocator);
            for (self.slots, 0..) |*slot, index| {
                slot.thread = try std.Thread.spawn(.{}, threadMain, .{ self, index });
            }
            // The vCPU threads flush network RX and check for gateway
            // failure, so a network wake kicks them.
            self.config.network.setWake(.{ .context = self, .wakeFn = kickAllFromNetwork });
            if (self.config.exec_control) |control| control.setWake(.{ .context = self, .wakeFn = notifyMainFromControl });
            if (self.config.captureRequest()) |request| request.setWake(notifyMainFromSignal, self);
            for (self.slots) |*slot| {
                while (true) {
                    const seen = self.events.load(.acquire);
                    if (slot.started.load(.acquire)) break;
                    if (self.stopped()) return self.stopError();
                    try self.waitMain(seen);
                }
                if (slot.start_error) |err| return err;
            }
        }

        /// Stops and joins every vCPU thread.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.config.network.clearWake();
            if (self.config.captureRequest()) |request| request.clearWake();
            // The control outlives the run, so its later wakes must not
            // reach this one.
            if (self.config.exec_control) |control| control.setWake(.{ .context = self, .wakeFn = ignoreWake });
            self.stop.store(true, .release);
            self.kickAll();
            for (self.slots) |*slot| {
                if (slot.thread) |thread| thread.join();
                slot.arena.deinit();
            }
            // After the vCPU threads: one may be in a queue reset that waits
            // for its worker.
            self.stopBlkWorkers();
            allocator.free(self.slots);
            allocator.free(self.states);
            allocator.free(self.blk_workers);
        }

        fn startBlkWorkers(self: *Self, allocator: std.mem.Allocator) !void {
            const transports = self.devices.transports();
            var count: usize = 0;
            for (transports) |t| count += @intFromBool(t.dev.device_id == blk.device_id);
            self.blk_workers = try allocator.alloc(BlkWorker, count);
            var next: usize = 0;
            for (transports, 0..) |t, index| {
                if (t.dev.device_id != blk.device_id) continue;
                self.blk_workers[next] = .{ .index = index, .shared = .{ .io = self.config.io, .lock = &self.device_lock } };
                next += 1;
            }
            for (self.blk_workers) |*worker| {
                self.blkDevice(worker).worker = &worker.shared;
                worker.thread = try std.Thread.spawn(.{}, blkWorkerMain, .{ self, worker });
            }
        }

        fn stopBlkWorkers(self: *Self) void {
            {
                self.device_lock.lockUncancelable(self.config.io);
                defer self.device_lock.unlock(self.config.io);
                for (self.blk_workers) |*worker| {
                    worker.stopping = true;
                    worker.shared.changed.broadcast(self.config.io);
                }
            }
            for (self.blk_workers) |*worker| {
                if (worker.thread) |thread| thread.join();
                self.blkDevice(worker).worker = null;
            }
        }

        fn blkDevice(self: *Self, worker: *const BlkWorker) *blk.Blk {
            return @ptrCast(@alignCast(self.devices.transports()[worker.index].dev.context));
        }

        /// Serves a virtio-blk queue in batches of at most one notify
        /// budget. Requests come off the queue and go back with the device
        /// lock held, but run without it; the interrupt goes up once per
        /// batch.
        fn blkWorkerMain(self: *Self, worker: *BlkWorker) void {
            const io = self.config.io;
            const transport = &self.devices.transports()[worker.index];
            const device = self.blkDevice(worker);
            const q = &transport.queues[0];
            self.device_lock.lockUncancelable(io);
            defer self.device_lock.unlock(io);
            while (true) {
                while (!worker.stopping and worker.seen == worker.shared.kicks) {
                    worker.shared.changed.waitUncancelable(io, &self.device_lock);
                }
                if (worker.stopping) return;
                worker.seen = worker.shared.kicks;
                var returned = false;
                var budget: queue.NotifyBudget = .{};
                while (budget.hasRemaining()) {
                    const chain = (q.popAvail(self.ram) catch break) orelse break;
                    budget.consume();
                    worker.shared.busy = true;
                    self.device_lock.unlock(io);
                    const written = device.handleRequest(&chain);
                    self.device_lock.lockUncancelable(io);
                    worker.shared.busy = false;
                    chain.markWritableDirty(self.ram);
                    q.pushUsed(self.ram, chain.head, written) catch break;
                    returned = true;
                }
                worker.shared.changed.broadcast(io);
                if (!transport.signalUsedBuffers(returned)) continue;
                self.vm.setSpi(board.virtioDeviceIntid(@intCast(worker.index)), true) catch |err| {
                    self.finish(.{ .err = err });
                    continue;
                };
                if (Vm.spi_needs_kick) self.kickAll();
            }
        }

        /// Waits until each virtio-blk worker has served every notify and
        /// returned every request it took. Bounded once the vCPUs are
        /// parked, since only they notify.
        fn drainBlkWorkers(self: *Self) void {
            const io = self.config.io;
            self.device_lock.lockUncancelable(io);
            defer self.device_lock.unlock(io);
            for (self.blk_workers) |*worker| {
                while (worker.shared.busy or worker.seen != worker.shared.kicks) {
                    worker.shared.changed.waitUncancelable(io, &self.device_lock);
                }
            }
        }

        /// Restores `machine`: the GIC and counter here, then each vCPU
        /// thread applies its own state. Call between `start` and `run`.
        pub fn restore(self: *Self, allocator: std.mem.Allocator, machine: spore.Machine) !void {
            const states = try restoreVm(allocator, self.vm, self.vcpus, machine);
            defer allocator.free(states);
            for (self.states, states) |*captured, state| captured.state = state;
            try self.pauseAll(.apply);
        }

        /// Makes every vCPU thread look again: a vCPU in the guest exits,
        /// and a parked or idle thread wakes.
        pub fn kickAll(self: *Self) void {
            self.wakeVcpuThreads();
            for (self.vcpus) |*vcpu| vcpu.kick();
        }

        /// Wakes the parked or idle vCPU threads.
        fn wakeVcpuThreads(self: *Self) void {
            _ = self.vcpu_events.fetchAdd(1, .release);
            self.config.io.futexWake(u32, &self.vcpu_events.raw, std.math.maxInt(u32));
        }

        fn kickAllFromNetwork(context: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context orelse return));
            self.kickAll();
        }

        /// Makes the main thread look again. Async-signal-safe: an atomic
        /// add and a futex wake.
        fn notifyMain(self: *Self) void {
            _ = self.events.fetchAdd(1, .release);
            self.config.io.futexWake(u32, &self.events.raw, 1);
        }

        fn notifyMainFromControl(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.notifyMain();
        }

        fn ignoreWake(_: *anyopaque) void {}

        /// Runs in the capture signal handler.
        fn notifyMainFromSignal(context: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(context orelse return));
            self.notifyMain();
        }

        /// Waits until `events` moves past `seen`, at most `main_wait_ms`.
        fn waitMain(self: *Self, seen: u32) !void {
            try self.config.io.futexWaitTimeout(u32, &self.events.raw, seen, .{ .duration = .{
                .raw = .fromMilliseconds(main_wait_ms),
                .clock = .awake,
            } });
        }

        /// Waits until `vcpu_events` moves past `seen`, at most
        /// `vcpuWaitNs`.
        fn waitVcpu(self: *Self, seen: u32) void {
            self.config.io.futexWaitTimeout(u32, &self.vcpu_events.raw, seen, .{ .duration = .{
                .raw = .fromNanoseconds(self.vcpuWaitNs()),
                .clock = .awake,
            } }) catch {};
        }

        fn stopped(self: *const Self) bool {
            return self.stop.load(.acquire);
        }

        /// Records how the run ends and stops every vCPU. The first result
        /// wins.
        fn finish(self: *Self, outcome: Result) void {
            {
                self.result_lock.lockUncancelable(self.config.io);
                defer self.result_lock.unlock(self.config.io);
                if (self.result_value == null) self.result_value = outcome;
                self.stop.store(true, .release);
            }
            self.notifyMain();
            self.kickAll();
        }

        fn result(self: *Self) ?Result {
            self.result_lock.lockUncancelable(self.config.io);
            defer self.result_lock.unlock(self.config.io);
            return self.result_value;
        }

        /// Why a stopped run cannot go on: its error, or `CaptureAborted`
        /// when it ended without one.
        fn stopError(self: *Self) anyerror {
            return switch (self.result() orelse return error.CaptureAborted) {
                .err => |err| err,
                .exit => error.CaptureAborted,
            };
        }

        /// Parks every vCPU thread and drains the virtio-blk workers, then
        /// has each thread do `action` on its own vCPU.
        fn pauseAll(self: *Self, action: Action) !void {
            try self.park();
            if (action != .none) try self.pauseFor(action);
            if (action == .capture) try self.settleInterrupts();
        }

        /// Parks every vCPU thread, then waits for the virtio-blk workers,
        /// so no request is in flight while the vCPUs stay parked.
        fn park(self: *Self) !void {
            try self.pauseFor(.none);
            self.drainBlkWorkers();
        }

        /// Captures again, letting the guest run in between, until no vCPU
        /// stopped inside an interrupt handler. Hypervisor.framework does
        /// not restore an interrupt the guest acknowledged but has not
        /// completed: the restored guest's EOI aborts the process with
        /// "Handle no active virtual interrupt". KVM would restore it, but
        /// both backends save by the same rule.
        fn settleInterrupts(self: *Self) !void {
            const give_up_ms = deadline.system_clock.nowMs() + capture_settle_ms;
            while (anyInInterruptHandler(self.states)) {
                if (deadline.system_clock.nowMs() >= give_up_ms) return error.InterruptStillActive;
                self.resumeAll();
                try self.waitMain(self.events.load(.acquire));
                try self.park();
                try self.pauseFor(.capture);
            }
        }

        fn pauseFor(self: *Self, action: Action) !void {
            if (action == .capture) {
                for (self.slots) |*slot| _ = slot.arena.reset(.retain_capacity);
            }
            self.pause.action.store(action, .monotonic);
            const seq = self.pause.seq.fetchAdd(1, .release) + 1;
            self.pause.active.store(true, .release);
            self.kickAll();
            for (self.slots) |*slot| {
                while (true) {
                    const seen = self.events.load(.acquire);
                    if (slot.acked.load(.acquire) == seq) break;
                    if (self.stopped()) return self.stopError();
                    try self.waitMain(seen);
                }
            }
        }

        fn resumeAll(self: *Self) void {
            self.pause.active.store(false, .release);
            self.wakeVcpuThreads();
        }

        fn threadMain(self: *Self, index: usize) void {
            const vcpu = &self.vcpus[index];
            const slot = &self.slots[index];
            vcpu.threadStart() catch |err| {
                slot.start_error = err;
                slot.started.store(true, .release);
                self.finish(.{ .err = err });
                return;
            };
            defer vcpu.threadExit();
            slot.started.store(true, .release);
            self.notifyMain();
            self.vcpuLoop(vcpu, slot, &self.states[index]) catch |err| self.finish(.{ .err = err });
        }

        fn vcpuLoop(self: *Self, vcpu: *Vcpu, slot: *Slot, captured: *Captured) !void {
            const io = self.config.io;
            const transports = self.devices.transports();
            const vsock_base = board.virtioDeviceBase(@intCast(self.devices.vsock_index));
            while (true) {
                const seen = self.vcpu_events.load(.acquire);
                if (self.stopped()) return;
                // Served even while paused: a running vCPU may be waiting on
                // this one before it can see the pause.
                if (vcpu.handleCommands()) continue;
                if (self.pause.active.load(.acquire)) {
                    const seq = self.pause.seq.load(.acquire);
                    if (slot.acked.load(.monotonic) != seq) {
                        const action = self.pause.action.load(.monotonic);
                        if (action != .none) {
                            self.action_lock.lockUncancelable(io);
                            defer self.action_lock.unlock(io);
                            switch (action) {
                                .none => unreachable,
                                .capture => captured.state = try vcpu.capture(self.vm, slot.arena.allocator()),
                                .apply => try vcpu.apply(self.vm, captured.state),
                            }
                        }
                        slot.acked.store(seq, .release);
                        self.notifyMain();
                    }
                    self.waitVcpu(seen);
                    continue;
                }
                if (self.config.network.failed()) return error.NetworkGatewayFailed;
                if (self.config.network.consumeWake()) {
                    self.device_lock.lockUncancelable(io);
                    defer self.device_lock.unlock(io);
                    _ = try flushRx(self.vm, &self.devices.net, transports, self.devices.net_index, self.ram);
                    continue;
                }
                const exit = try vcpu.run(self.vm, self.vcpus);
                if (self.stopped()) return;
                switch (exit) {
                    .mmio => |access| {
                        const value = value: {
                            self.device_lock.lockUncancelable(io);
                            defer self.device_lock.unlock(io);
                            break :value try dispatchMmio(self.vm, access, transports, &self.devices.gen, self.ram);
                        };
                        try vcpu.completeMmio(value);
                        // A vsock write can move the probe or a control's
                        // stream along.
                        if (access.write != null and access.addr -% vsock_base < board.virtio_stride) self.notifyMain();
                    },
                    .wfi => self.waitVcpu(seen),
                    .shutdown => |kind| self.finish(.{ .exit = kind.cause() }),
                    .handled, .kicked => {},
                }
            }
        }

        /// Lets the guest run and serves the control, the probe, capture
        /// requests and virtio-mem growth until the run ends.
        pub fn run(self: *Self, allocator: std.mem.Allocator, source: SnapshotSource) !ExitCause {
            const config = self.config;
            var probe_done = false;
            var captured_request = false;
            var pressure_seen: u32 = 0;
            self.resumeAll();
            while (true) {
                const seen = self.events.load(.acquire);
                if (self.result()) |outcome| {
                    return switch (outcome) {
                        .exit => |cause| cause,
                        .err => |err| err,
                    };
                }
                if (config.network.failed()) {
                    self.finish(.{ .err = error.NetworkGatewayFailed });
                    continue;
                }
                if (config.probe != null and !probe_done) {
                    // Packets the probe queued that no guest notification
                    // delivered.
                    self.deliverVsock() catch |err| {
                        self.finish(.{ .err = err });
                        continue;
                    };
                }
                self.growMemoryOnPressure(&pressure_seen) catch |err| {
                    self.finish(.{ .err = err });
                    continue;
                };
                if (config.exec_control) |control| {
                    control.reportStats(monitorStats(if (self.dirty_tracker) |tracker| &tracker.sealer else null));
                    const action = self.pollControl(control) catch |err| {
                        self.finish(.{ .err = err });
                        continue;
                    };
                    switch (action) {
                        .keep_running => {},
                        .stop => self.finish(.{ .exit = .monitor_stopped }),
                        .snapshot => |request| if (request.continue_after) {
                            self.snapshotAndContinue(allocator, source, control, request) catch |err| self.finish(.{ .err = err });
                        } else {
                            self.snapshotAndStop(allocator, source, request.dir, null);
                        },
                        .rootfs_snapshot => |request| self.rootfsSnapshot(allocator, control, request.dir) catch |err| self.finish(.{ .err = err }),
                        .disk_fork => |request| self.diskFork(allocator, source, control, request) catch |err| control.failDiskFork(err),
                    }
                    if (self.stopped()) continue;
                }
                if (config.probe) |exec_probe| {
                    const probe = exec_probe.stream;
                    if (!probe_done) {
                        if (probe.state == .failed) {
                            self.finish(.{ .err = error.VsockProbeFailed });
                            continue;
                        }
                        if (probe.state == .complete) {
                            const observed_ms = probe.elapsedMs();
                            std.log.debug(Vm.name ++ " probe completion timing: observed_ms={d} return_ms={d}", .{ observed_ms, probe.elapsedMs() });
                            if (exec_probe.on_complete == .stop) {
                                if (config.probeCaptureDir()) |dir| {
                                    self.snapshotAndStop(allocator, source, dir, null);
                                } else {
                                    self.finish(.{ .exit = .probe_complete });
                                }
                                continue;
                            }
                            // A detached stream stays attached until the
                            // control replaces or resets it.
                            probe_done = true;
                        }
                        if (!probe_done and probe.state != .idle and probe.elapsedMs() > exec_probe.timeout_ms) {
                            self.finish(.{ .err = error.VsockProbeTimedOut });
                            continue;
                        }
                    }
                }
                if (config.captureRequest()) |request_capture| {
                    if (request_capture.isAbortRequested()) {
                        self.finish(.{ .err = error.CaptureAborted });
                        continue;
                    }
                    if (request_capture.isRequested() and !captured_request) {
                        if (config.continueAfterCapture()) {
                            self.snapshotOnce(allocator, source, config.capture.?.dir, request_capture) catch |err| {
                                self.finish(.{ .err = err });
                                continue;
                            };
                            self.resumeAll();
                            captured_request = true;
                        } else {
                            self.snapshotAndStop(allocator, source, config.capture.?.dir, request_capture);
                        }
                        continue;
                    }
                }
                try self.waitMain(seen);
            }
        }

        /// Polls the control and, unless it asked for something else,
        /// delivers the host-to-guest vsock packets it queued.
        fn pollControl(self: *Self, control: vsock_control.Control) !vsock_control.ControlAction {
            const action = action: {
                self.device_lock.lockUncancelable(self.config.io);
                defer self.device_lock.unlock(self.config.io);
                break :action try control.poll(&self.devices.vsock);
            };
            if (action == .keep_running) try self.deliverVsock();
            return action;
        }

        /// Delivers the host-to-guest vsock packets that are waiting for
        /// guest buffers.
        fn deliverVsock(self: *Self) !void {
            const delivered = delivered: {
                self.device_lock.lockUncancelable(self.config.io);
                defer self.device_lock.unlock(self.config.io);
                break :delivered try flushRx(self.vm, &self.devices.vsock, self.devices.transports(), self.devices.vsock_index, self.ram);
            };
            if (delivered and Vm.spi_needs_kick) self.kickAll();
        }

        /// Asks the guest to plug more virtio-mem when the probe stream
        /// reports new memory pressure. `seen` is the pressure count already
        /// answered.
        fn growMemoryOnPressure(self: *Self, seen: *u32) !void {
            const index = self.devices.mem_index orelse return;
            const probe = self.config.probeStream() orelse return;
            {
                self.device_lock.lockUncancelable(self.config.io);
                defer self.device_lock.unlock(self.config.io);
                const events = probe.memory_pressure_count -| seen.*;
                if (events == 0 or probe.state != .connected) return;
                seen.* = probe.memory_pressure_count;
                const mem = &self.devices.mem;
                try mem.setRequestedSize(virtio_mem.requestedSizeAfterPressure(mem.requested_size, mem.region_size, events));
                _ = self.devices.transports()[index].raiseConfigChange();
                try self.vm.setSpi(board.virtioDeviceIntid(@intCast(index)), true);
                std.log.debug("virtio-mem requested hotplug size: bytes={d} pressure_count={d}", .{ mem.requested_size, seen.* });
            }
            if (Vm.spi_needs_kick) self.kickAll();
        }

        /// Writes a spore from the states the paused vCPUs captured.
        fn writeSpore(self: *Self, allocator: std.mem.Allocator, source: SnapshotSource, target: SnapshotTarget) !void {
            try writeSnapshot(allocator, Vm.name, self.vm, self.states, self.dirty_tracker, source, target);
        }

        /// Writes a spore and ends the run, as `snapshotted` unless that
        /// fails.
        fn snapshotAndStop(self: *Self, allocator: std.mem.Allocator, source: SnapshotSource, dir: []const u8, request_capture: ?*capture.Request) void {
            self.snapshotOnce(allocator, source, dir, request_capture) catch |err| self.finish(.{ .err = err });
            self.finish(.{ .exit = .snapshotted });
        }

        fn snapshotOnce(self: *Self, allocator: std.mem.Allocator, source: SnapshotSource, dir: []const u8, request_capture: ?*capture.Request) !void {
            try self.pauseAll(.capture);
            try self.writeSpore(allocator, source, .{ .dir = dir });
            if (request_capture) |request| {
                request.markCompleted();
                if (request.isAbortRequested()) return error.CaptureAborted;
            }
        }

        fn snapshotAndContinue(
            self: *Self,
            allocator: std.mem.Allocator,
            source: SnapshotSource,
            control: vsock_control.Control,
            request: vsock_control.SnapshotAction,
        ) !void {
            const config = self.config;
            var preparation = if (request.publish_dir != null)
                (try control.prepareSnapshot()) orelse return
            else
                null;
            defer if (preparation) |*owned| owned.deinit();
            var prepared_root = if (request.publish_dir) |publish_dir|
                if (config.disk_snapshot) |disk_state| try disk_state.prepareSnapshotRoot(publish_dir) else null
            else
                null;
            defer if (prepared_root) |*root| root.deinit();
            try self.pauseAll(.capture);
            const source_pause_started_ns = runtime_disk_fork_capture.monotonicNs();
            try self.writeSpore(allocator, source, .{
                .dir = request.dir,
                .rootfs_cache_lock = if (preparation) |*owned| owned.cacheLock() else null,
            });
            const completed_dir = if (request.publish_dir) |publish_dir| blk: {
                const publish_metrics = try control.publishSnapshot(&preparation.?, request.dir, publish_dir);
                if (prepared_root) |*root| try config.disk_snapshot.?.commitSnapshotRoot(request.dir, root, if (config.environ_map != null) .shared_no_rebind else .local_rebind);
                logNamedSnapshotPublication(Vm.name, publish_metrics, source_pause_started_ns);
                break :blk publish_dir;
            } else request.dir;
            self.resumeAll();
            try control.completeSnapshot(completed_dir);
        }

        fn rootfsSnapshot(self: *Self, allocator: std.mem.Allocator, control: vsock_control.Control, dir: []const u8) !void {
            try self.pauseAll(.none);
            const disk_manifest = try takeRootfsSnapshot(allocator, dir, self.devices.transports(), self.config.disk_snapshot);
            self.resumeAll();
            try control.completeRootfsSnapshot(disk_manifest);
        }

        fn diskFork(self: *Self, allocator: std.mem.Allocator, source: SnapshotSource, control: vsock_control.Control, fork: vsock_control.DiskForkAction) !void {
            const pause_started_ns = runtime_disk_fork_capture.monotonicNs();
            defer self.resumeAll();
            try self.pauseAll(.capture);
            try captureDiskFork(allocator, Vm.name, self.vm, self.states, self.dirty_tracker, source, fork, control, pause_started_ns);
        }
    };
}

/// Whether any captured vCPU stopped between acknowledging an interrupt and
/// completing it: its CPU interface still holds an active priority.
fn anyInInterruptHandler(states: []const Captured) bool {
    for (states) |captured| {
        for (captured.state.icc_regs) |reg| {
            const active_priority = std.mem.eql(u8, reg.name, "ap0r0_el1") or std.mem.eql(u8, reg.name, "ap1r0_el1");
            if (active_priority and reg.value != 0) return true;
        }
    }
    return false;
}

/// A vCPU state its own thread captured, in the shape `writeSnapshot` reads
/// vCPUs.
const Captured = struct {
    state: spore.VcpuState,

    pub fn capture(self: *Captured, _: anytype, _: std.mem.Allocator) !spore.VcpuState {
        return self.state;
    }
};

fn testConsoleSink(_: []const u8) void {}

fn testBoot(overrides: struct {
    vcpus: topology.VcpuCount = 1,
    virtio_mem_region_size: u64 = 0,
}) Config {
    return .{
        .io = std.testing.io,
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
    var tmp = try TestDir.init();
    defer tmp.deinit();
    const dir = tmp.root;

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

const TestSpi = struct {
    intid: ?u32 = null,
    level: bool = false,

    pub fn setSpi(self: *TestSpi, intid: u32, level: bool) !void {
        self.intid = intid;
        self.level = level;
    }
};

test "device MMIO reaches each virtio window and its interrupt line" {
    var con = console.Console{ .sink = testConsoleSink };
    var rng_dev = rng.Rng{};
    var transports = [_]mmio.Transport{ mmio.Transport.init(con.device()), mmio.Transport.init(rng_dev.device()) };
    var gen_dev = generation.Device{};
    const ram = guestmem.GuestRam{ .bytes = &.{}, .base = board.ram_base };
    var spi = TestSpi{};

    const rng_base = board.virtioDeviceBase(1);
    try std.testing.expectEqual(@as(u64, rng.device_id), try dispatchMmio(&spi, .{ .addr = rng_base + 0x008, .size_log2 = 2, .write = null }, &transports, &gen_dev, ram));
    try std.testing.expectEqual(@as(?u32, null), spi.intid);
    // The interrupt ack lowers that device's line.
    _ = try dispatchMmio(&spi, .{ .addr = rng_base + 0x064, .size_log2 = 2, .write = 1 }, &transports, &gen_dev, ram);
    try std.testing.expectEqual(@as(?u32, board.virtioDeviceIntid(1)), spi.intid);
    try std.testing.expect(!spi.level);

    // Slots past the last device read as zero and raise nothing.
    spi = .{};
    try std.testing.expectEqual(@as(u64, 0), try dispatchMmio(&spi, .{ .addr = board.virtioDeviceBase(2), .size_log2 = 2, .write = null }, &transports, &gen_dev, ram));
    _ = try dispatchMmio(&spi, .{ .addr = board.virtioDeviceBase(2) + 0x064, .size_log2 = 2, .write = 1 }, &transports, &gen_dev, ram);
    try std.testing.expectEqual(@as(?u32, null), spi.intid);
}

const TestDirtyBackend = struct {
    flushes: u32 = 0,

    pub const metrics_mode = "test";

    pub fn start(_: *DirtyTracker(TestDirtyBackend), _: std.mem.Allocator) !void {}

    pub fn stop(_: *DirtyTracker(TestDirtyBackend)) void {}

    pub fn flush(tracker: *DirtyTracker(TestDirtyBackend)) !void {
        tracker.backend.flushes += 1;
        _ = try tracker.sealer.flushMarked(.{});
    }

    pub fn logSnapshotMetrics(_: *const DirtyTracker(TestDirtyBackend), _: SnapshotMetrics) void {}
};

test "dirty tracker marks host writes inside guest RAM and seals them at finish" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = try TestDir.init();
    defer tmp.deinit();
    const dir = tmp.root;
    const ram = try arena.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), 2 * spore.chunk_size);
    @memset(ram, 0);

    const Tracker = DirtyTracker(TestDirtyBackend);
    var tracker = try Tracker.start(arena, std.testing.io, .{ .dir = dir, .ram = ram, .seed_ranges = &.{} }, .{});
    defer tracker.deinit();
    Tracker.markGuestWriteCallback(&tracker, board.ram_base - 1, 1);
    Tracker.markGuestWriteCallback(&tracker, board.ram_base + ram.len, 1);
    try std.testing.expectEqual(@as(usize, 0), tracker.sealer.dirtyChunksPending());
    // A write that runs past the end of RAM marks only what is inside.
    Tracker.markGuestWriteCallback(&tracker, board.ram_base + spore.chunk_size, 4 * spore.chunk_size);
    try std.testing.expectEqual(@as(usize, 1), tracker.sealer.dirtyChunksPending());
    Tracker.markGuestWriteCallback(&tracker, board.ram_base + spore.chunk_size - 1, 2);
    try std.testing.expectEqual(@as(usize, 2), tracker.sealer.dirtyChunksPending());

    const memory = try tracker.finish();
    try std.testing.expectEqual(@as(u32, 1), tracker.backend.flushes);
    try std.testing.expectEqual(@as(usize, 0), tracker.sealer.dirtyChunksPending());
    try std.testing.expectEqual(@as(usize, 2), (try spore.validateMemoryForRam(memory, ram.len)).chunk_count);
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

    try std.testing.expectError(error.BadManifest, applyTransports(&transports, &states, .{ .bytes = &.{}, .base = 0 }));
    try std.testing.expectEqual(@as(u64, 0), transports[0].driver_features);
}

test "transport restore refuses ready queues whose rings leave guest RAM" {
    var storage: [blk.sector_size]u8 = undefined;
    var block = blk.Blk.initWithOptions(.{ .memory = &storage }, .{});
    var transports = [_]mmio.Transport{mmio.Transport.init(block.device())};
    var guest_bytes: [4096]u8 = undefined;
    const ram = guestmem.GuestRam{ .bytes = &guest_bytes, .base = board.ram_base };
    var queues = [_]spore.QueueState{.{
        .size = 8,
        .ready = true,
        .desc_addr = board.ram_base,
        .avail_addr = board.ram_base + 0x400,
        .used_addr = board.ram_base + 0x800,
        .last_avail = 0,
        .used_idx = 0,
    }};
    const states = [_]spore.TransportState{.{
        .device_id = blk.device_id,
        .status = mmio.status_features_ok | mmio.status_driver_ok,
        .device_features_sel = 0,
        .driver_features_sel = 0,
        .driver_features = 0,
        .queue_sel = 0,
        .interrupt_status = 0,
        .queues = &queues,
    }};
    try applyTransports(&transports, &states, ram);
    try std.testing.expect(transports[0].queues[0].ready);

    transports[0].reset();
    queues[0].used_addr = board.ram_base + guest_bytes.len;
    try std.testing.expectError(error.BadManifest, applyTransports(&transports, &states, ram));
    try std.testing.expect(!transports[0].queues[0].ready);
}

test "vtimers move onto one counter without changing deadlines" {
    const Case = struct {
        saved_counter: u64,
        saved_cval: u64,
        guest_counter: u64,
        ctl: u64,
    };
    const cases = [_]Case{
        .{ .saved_counter = 100, .saved_cval = 130, .guest_counter = 140, .ctl = 1 },
        .{ .saved_counter = 140, .saved_cval = 130, .guest_counter = 100, .ctl = 3 },
        .{ .saved_counter = std.math.maxInt(u64) - 4, .saved_cval = 3, .guest_counter = 6, .ctl = 0 },
    };
    for (cases) |case| {
        var timer = spore.VtimerState{ .cntvct = case.saved_counter, .cntv_ctl = case.ctl, .cntv_cval = case.saved_cval };
        const deadline_delta = timer.cntv_cval -% timer.cntvct;
        moveVtimer(&timer, case.guest_counter);
        try std.testing.expectEqual(case.guest_counter, timer.cntvct);
        try std.testing.expectEqual(deadline_delta, timer.cntv_cval -% timer.cntvct);
        try std.testing.expectEqual(case.ctl, timer.cntv_ctl);
    }
}

const test_gic = gicv3.State{
    .kind = .backend_private,
    .backend_private = .{ .backend = .hvf, .format = gicv3.hvf_backend_private_format, .data_b64 = "AA==" },
};

fn testVcpuState(index: topology.VcpuIndex, vtimer: spore.VtimerState) spore.VcpuState {
    return .{
        .index = index,
        .mpidr = aarch64_topology.mpidrForIndex(index),
        .gprs = [_]u64{0} ** 31,
        .pc = 0x1000 + @as(u64, index),
        .cpsr = 0,
        .fpcr = 0,
        .fpsr = 0,
        .simd = [_][2]u64{.{ 0, 0 }} ** 32,
        .sys_regs = &.{},
        .icc_regs = &.{},
        .vtimer = vtimer,
    };
}

/// Records the order `restoreMachine` drives a backend in.
const TestVm = struct {
    gic_applied: bool = false,
    counter: ?u64 = null,

    pub fn captureGic(_: *const TestVm, _: std.mem.Allocator, _: usize) !gicv3.State {
        return test_gic;
    }

    pub fn applyGic(self: *TestVm, _: std.mem.Allocator, _: []TestVcpu, _: gicv3.State) !void {
        self.gic_applied = true;
    }

    pub fn setCounter(self: *TestVm, guest_cntvct: u64) !void {
        try std.testing.expect(self.gic_applied);
        self.counter = guest_cntvct;
    }
};

const TestVcpu = struct {
    live: spore.VcpuState,
    applied: ?spore.VcpuState = null,

    pub fn capture(self: *TestVcpu, _: *TestVm, _: std.mem.Allocator) !spore.VcpuState {
        return self.live;
    }

    pub fn apply(self: *TestVcpu, vm: *const TestVm, state: spore.VcpuState) !void {
        try std.testing.expect(vm.counter != null);
        self.applied = state;
    }
};

test "snapshots refuse queued host vsock packets before writing anything" {
    var tmp = try TestDir.init();
    defer tmp.deinit();
    const dir = try tmp.path("spore");

    const config = testBoot(.{});
    var vsock_dev = vsock.Vsock.init(.{});
    var gen_dev = generation.Device{};
    var stream = try vsock_stream.HostStream.init(10700, "{}\n");
    try vsock_dev.attachHostStream(&stream);
    try std.testing.expect(vsock_dev.pending_len != 0);

    var vm = TestVm{};
    var one = [_]TestVcpu{.{ .live = testVcpuState(0, .{ .cntvct = 100, .cntv_ctl = 0, .cntv_cval = 0 }) }};
    const ram: [std.heap.page_size_min]u8 = @splat(0);
    try std.testing.expectError(error.DeviceStatePending, writeSnapshot(
        std.testing.allocator,
        "test",
        &vm,
        @as([]TestVcpu, &one),
        @as(?*DirtyTracker(TestDirtyBackend), null),
        .{ .config = &config, .transports = &.{}, .gen_dev = &gen_dev, .vsock_dev = &vsock_dev, .ram_bytes = &ram, .ram_size = ram.len },
        .{ .dir = dir },
    ));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "spore", .{}));
}

test "one vCPU captures the single shape and more share vCPU 0's counter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var vm = TestVm{};
    var one = [_]TestVcpu{.{ .live = testVcpuState(0, .{ .cntvct = 100, .cntv_ctl = 1, .cntv_cval = 130 }) }};
    const single = try captureMachine(arena_state.allocator(), &vm, @as([]TestVcpu, &one));
    try std.testing.expectEqual(@as(u64, 100), single.single.vtimer.cntvct);
    try std.testing.expectEqual(@as(u64, 0x1000), single.single.pc);

    var two = [_]TestVcpu{
        .{ .live = testVcpuState(0, .{ .cntvct = 100, .cntv_ctl = 1, .cntv_cval = 130 }) },
        .{ .live = testVcpuState(1, .{ .cntvct = 140, .cntv_ctl = 3, .cntv_cval = 120 }) },
    };
    const multi = (try captureMachine(arena_state.allocator(), &vm, @as([]TestVcpu, &two))).multi;
    try std.testing.expectEqual(@as(usize, 2), multi.vcpus.len);
    try std.testing.expectEqual(@as(u64, 100), multi.vcpus[0].vtimer.cntvct);
    try std.testing.expectEqual(@as(u64, 100), multi.vcpus[1].vtimer.cntvct);
    try std.testing.expectEqual(@as(u64, 120) -% 140, multi.vcpus[1].vtimer.cntv_cval -% multi.vcpus[1].vtimer.cntvct);
    try std.testing.expectEqual(@as(u64, 3), multi.vcpus[1].vtimer.cntv_ctl);
}

test "restore applies the GIC, then one counter, then each vCPU on it" {
    var vm = TestVm{};
    var saved = [_]spore.VcpuState{
        testVcpuState(0, .{ .cntvct = 100, .cntv_ctl = 1, .cntv_cval = 130 }),
        testVcpuState(1, .{ .cntvct = 140, .cntv_ctl = 3, .cntv_cval = 120 }),
    };
    var vcpus = [_]TestVcpu{ .{ .live = undefined }, .{ .live = undefined } };
    try restoreMachine(std.testing.allocator, &vm, @as([]TestVcpu, &vcpus), .{ .multi = .{ .vcpus = &saved, .gic = test_gic } });
    try std.testing.expectEqual(@as(?u64, 100), vm.counter);
    for (vcpus, saved) |vcpu, state| {
        const applied = vcpu.applied.?;
        try std.testing.expectEqual(state.pc, applied.pc);
        try std.testing.expectEqual(@as(u64, 100), applied.vtimer.cntvct);
        try std.testing.expectEqual(state.vtimer.cntv_cval -% state.vtimer.cntvct, applied.vtimer.cntv_cval -% applied.vtimer.cntvct);
    }

    var single_vm = TestVm{};
    var one = [_]TestVcpu{.{ .live = undefined }};
    const s = saved[0];
    try restoreMachine(std.testing.allocator, &single_vm, @as([]TestVcpu, &one), .{ .single = .{
        .gprs = s.gprs,
        .pc = s.pc,
        .cpsr = s.cpsr,
        .fpcr = s.fpcr,
        .fpsr = s.fpsr,
        .simd = s.simd,
        .sys_regs = s.sys_regs,
        .icc_regs = s.icc_regs,
        .vtimer = s.vtimer,
        .gic = test_gic,
    } });
    try std.testing.expectEqual(@as(?u64, 100), single_vm.counter);
    try std.testing.expectEqual(@as(topology.VcpuIndex, 0), one[0].applied.?.index);
    try std.testing.expectEqual(aarch64_topology.mpidrForIndex(0), one[0].applied.?.mpidr);
}

test "restore rejects vCPU state that does not match the VM before touching it" {
    var saved = [_]spore.VcpuState{
        testVcpuState(0, .{ .cntvct = 100, .cntv_ctl = 0, .cntv_cval = 0 }),
        testVcpuState(1, .{ .cntvct = 100, .cntv_ctl = 0, .cntv_cval = 0 }),
    };
    const machine = spore.Machine{ .multi = .{ .vcpus = &saved, .gic = test_gic } };

    var vm = TestVm{};
    var three = [_]TestVcpu{ .{ .live = undefined }, .{ .live = undefined }, .{ .live = undefined } };
    try std.testing.expectError(error.PlatformMismatch, restoreMachine(std.testing.allocator, &vm, @as([]TestVcpu, &three), machine));

    saved[1].index = 0;
    var two = [_]TestVcpu{ .{ .live = undefined }, .{ .live = undefined } };
    try std.testing.expectError(error.PlatformMismatch, restoreMachine(std.testing.allocator, &vm, @as([]TestVcpu, &two), machine));

    saved[1] = testVcpuState(1, saved[1].vtimer);
    saved[1].mpidr = aarch64_topology.mpidrForIndex(2);
    try std.testing.expectError(error.PlatformMismatch, restoreMachine(std.testing.allocator, &vm, @as([]TestVcpu, &two), machine));
    try std.testing.expect(!vm.gic_applied);
}

const ThreadTestVm = struct {
    pub const name = "test";
    pub const spi_needs_kick = true;

    counter: ?u64 = null,
    /// Interrupts raised.
    raises: std.atomic.Value(u32) = .init(0),
    /// The last vCPU shuts the guest down once this is set.
    shutdown: std.atomic.Value(bool) = .init(false),
    /// Raising this interrupt sets `shutdown`.
    shutdown_intid: ?u32 = null,
    /// Capturing a vCPU sets `shutdown`.
    shutdown_on_capture: bool = false,

    pub fn setSpi(self: *ThreadTestVm, intid: u32, level: bool) !void {
        if (level) _ = self.raises.fetchAdd(1, .monotonic);
        if (self.shutdown_intid) |shutdown_intid| {
            if (level and intid == shutdown_intid) self.shutdown.store(true, .release);
        }
    }

    pub fn captureGic(_: *const ThreadTestVm, _: std.mem.Allocator, _: usize) !gicv3.State {
        return test_gic;
    }

    pub fn applyGic(_: *ThreadTestVm, _: std.mem.Allocator, _: []ThreadTestVcpu, _: gicv3.State) !void {}

    pub fn setCounter(self: *ThreadTestVm, guest_cntvct: u64) !void {
        self.counter = guest_cntvct;
    }
};

/// Records which thread captured and applied it, and how often it was kicked.
const ThreadTestVcpu = struct {
    index: topology.VcpuIndex,
    live: spore.VcpuState,
    owner: ?std.Thread.Id = null,
    on_owner: bool = true,
    applied: ?spore.VcpuState = null,
    kicks: std.atomic.Value(u32) = .init(0),
    /// Guest runs left before this vCPU completes the interrupt it is
    /// handling; until then its CPU interface holds an active priority.
    handler_runs: std.atomic.Value(u32) = .init(0),
    /// A register write the guest makes as it completes that interrupt.
    write_after_handler: ?Mmio = null,

    var in_handler_icc = [_]spore.SysRegEntry{.{ .name = "ap1r0_el1", .value = 0x10_0000 }};

    pub fn threadStart(self: *ThreadTestVcpu) !void {
        self.owner = std.Thread.getCurrentId();
    }

    pub fn threadExit(_: *ThreadTestVcpu) void {}

    pub fn handleCommands(_: *ThreadTestVcpu) bool {
        return false;
    }

    pub fn run(self: *ThreadTestVcpu, vm: *const ThreadTestVm, all: []ThreadTestVcpu) !Exit {
        if (self.handler_runs.load(.acquire) > 0 and self.handler_runs.fetchSub(1, .acq_rel) == 1) {
            if (self.write_after_handler) |access| {
                self.write_after_handler = null;
                return .{ .mmio = access };
            }
        }
        if (self.index == all.len - 1 and vm.shutdown.load(.acquire)) return .{ .shutdown = .off };
        return .wfi;
    }

    pub fn completeMmio(_: *ThreadTestVcpu, _: u64) !void {}

    pub fn capture(self: *ThreadTestVcpu, vm: *ThreadTestVm, _: std.mem.Allocator) !spore.VcpuState {
        self.checkOwner();
        if (vm.shutdown_on_capture) vm.shutdown.store(true, .release);
        var state = self.live;
        if (self.handler_runs.load(.acquire) > 0) state.icc_regs = &in_handler_icc;
        return state;
    }

    pub fn apply(self: *ThreadTestVcpu, _: *const ThreadTestVm, state: spore.VcpuState) !void {
        self.checkOwner();
        self.applied = state;
    }

    pub fn kick(self: *ThreadTestVcpu) void {
        _ = self.kicks.fetchAdd(1, .monotonic);
    }

    fn checkOwner(self: *ThreadTestVcpu) void {
        if (self.owner != std.Thread.getCurrentId()) self.on_owner = false;
    }
};

test "threaded vCPUs restore and capture themselves on their own threads" {
    const allocator = std.testing.allocator;
    var config = testBoot(.{ .vcpus = 2 });
    var devices: Devices = undefined;
    devices.init(&config, null);
    defer devices.net.shutdown();
    var vm = ThreadTestVm{};
    var vcpus = [_]ThreadTestVcpu{
        .{ .index = 0, .live = testVcpuState(0, .{ .cntvct = 500, .cntv_ctl = 1, .cntv_cval = 530 }) },
        .{ .index = 1, .live = testVcpuState(1, .{ .cntvct = 503, .cntv_ctl = 1, .cntv_cval = 540 }) },
    };
    var threaded: Threaded(ThreadTestVm, ThreadTestVcpu, DirtyTracker(TestDirtyBackend)) = .{
        .vm = &vm,
        .vcpus = &vcpus,
        .devices = &devices,
        .ram = .{ .bytes = &.{}, .base = board.ram_base },
        .config = &config,
    };
    defer threaded.deinit(allocator);
    try threaded.start(allocator);

    var saved = [_]spore.VcpuState{
        testVcpuState(0, .{ .cntvct = 100, .cntv_ctl = 1, .cntv_cval = 130 }),
        testVcpuState(1, .{ .cntvct = 104, .cntv_ctl = 1, .cntv_cval = 150 }),
    };
    try threaded.restore(allocator, .{ .multi = .{ .vcpus = &saved, .gic = test_gic } });
    try std.testing.expectEqual(@as(?u64, 100), vm.counter);
    try std.testing.expectEqual(@as(u64, 146), vcpus[1].applied.?.vtimer.cntv_cval);

    // A pause leaves each vCPU's own capture for the snapshot writer.
    try threaded.pauseAll(.capture);
    try std.testing.expectEqual(@as(u64, 500), threaded.states[0].state.vtimer.cntvct);
    try std.testing.expectEqual(@as(u64, 0x1001), threaded.states[1].state.pc);
    for (vcpus) |vcpu| try std.testing.expect(vcpu.on_owner);

    vm.shutdown.store(true, .release);
    try std.testing.expectEqual(ExitCause.guest_off, try threaded.run(allocator, .{
        .config = &config,
        .transports = devices.transports(),
        .gen_dev = &devices.gen,
        .vsock_dev = &devices.vsock,
        .ram_bytes = &.{},
        .ram_size = 0,
    }));
}

test "a threaded capture lets a vCPU finish the interrupt it is handling" {
    // Every VM runs on `Threaded`, so a 1-vCPU save can stop its vCPU
    // mid-handler too.
    for ([_]topology.VcpuCount{ 1, 2 }) |count| {
        const allocator = std.testing.allocator;
        var config = testBoot(.{ .vcpus = count });
        var devices: Devices = undefined;
        devices.init(&config, null);
        defer devices.net.shutdown();
        var vm = ThreadTestVm{};
        var vcpus = [_]ThreadTestVcpu{
            .{ .index = 0, .live = testVcpuState(0, .{ .cntvct = 500, .cntv_ctl = 1, .cntv_cval = 530 }), .handler_runs = .init(3) },
            .{ .index = 1, .live = testVcpuState(1, .{ .cntvct = 500, .cntv_ctl = 1, .cntv_cval = 540 }) },
        };
        var threaded: Threaded(ThreadTestVm, ThreadTestVcpu, DirtyTracker(TestDirtyBackend)) = .{
            .vm = &vm,
            .vcpus = vcpus[0..count],
            .devices = &devices,
            .ram = .{ .bytes = &.{}, .base = board.ram_base },
            .config = &config,
        };
        defer threaded.deinit(allocator);
        try threaded.start(allocator);

        // vCPU 0 stopped mid-handler; the capture resumes the guest until
        // it completes the interrupt, then keeps that later state.
        try threaded.pauseAll(.capture);
        try std.testing.expectEqual(@as(u32, 0), vcpus[0].handler_runs.load(.acquire));
        for (threaded.states) |captured| try std.testing.expectEqual(@as(usize, 0), captured.state.icc_regs.len);
    }
}

/// Gives the guest's vsock RX queue one buffer in `ram`, which holds 0x2000
/// bytes from `board.ram_base`. Returns the address of the used ring.
fn testVsockRxBuffer(devices: *Devices, ram: guestmem.GuestRam) !u64 {
    const desc = board.ram_base;
    const avail = board.ram_base + 0x400;
    const used = board.ram_base + 0x800;
    const rx = &devices.transports()[devices.vsock_index];
    _ = rx.write(0x030, 0, ram);
    _ = rx.write(0x038, 8, ram);
    inline for (.{ .{ 0x080, desc }, .{ 0x090, avail }, .{ 0x0a0, used } }) |reg| {
        _ = rx.write(reg[0], @truncate(reg[1]), ram);
        _ = rx.write(reg[0] + 4, @truncate(reg[1] >> 32), ram);
    }
    try std.testing.expect(!rx.write(0x044, 1, ram));
    try ram.write(u64, desc, board.ram_base + 0x1000);
    try ram.write(u32, desc + 8, 0x100);
    try ram.write(u16, desc + 12, 2); // VIRTQ_DESC_F_WRITE
    try ram.write(u16, avail + 4, 0);
    try ram.write(u16, avail + 2, 1);
    return used;
}

/// Attaches a host stream when asked to, as a monitor does to start an exec,
/// which queues the stream's connect request for the guest.
const AttachTestControl = struct {
    stream: vsock_stream.HostStream,
    attach: bool = false,

    fn control(self: *AttachTestControl) vsock_control.Control {
        return .{
            .context = self,
            .pollFn = poll,
            .setWakeFn = setWake,
            .completeSnapshotFn = completeSnapshot,
            .completeRootfsSnapshotFn = completeRootfsSnapshot,
            .reportStatsFn = reportStats,
        };
    }

    fn poll(context: *anyopaque, dev: *vsock.Vsock) !vsock_control.ControlAction {
        const self: *AttachTestControl = @ptrCast(@alignCast(context));
        if (self.attach) try dev.attachHostStream(&self.stream);
        self.attach = false;
        return .keep_running;
    }

    fn setWake(_: *anyopaque, _: vsock_control.Wake) void {}
    fn completeSnapshot(_: *anyopaque, _: []const u8) !void {}
    fn completeRootfsSnapshot(_: *anyopaque, _: ?spore.Disk) !void {}
    fn reportStats(_: *anyopaque, _: vsock_control.ControlStats) void {}
};

test "threaded control delivery kicks every vCPU once per delivered batch" {
    var config = testBoot(.{ .vcpus = 2 });
    var devices: Devices = undefined;
    devices.init(&config, null);
    defer devices.net.shutdown();

    var bytes = [_]u8{0} ** 0x2000;
    const ram = guestmem.GuestRam{ .bytes = &bytes, .base = board.ram_base };
    const used = try testVsockRxBuffer(&devices, ram);

    var vm = ThreadTestVm{};
    var vcpus = [_]ThreadTestVcpu{ .{ .index = 0, .live = undefined }, .{ .index = 1, .live = undefined } };
    var threaded: Threaded(ThreadTestVm, ThreadTestVcpu, DirtyTracker(TestDirtyBackend)) = .{
        .vm = &vm,
        .vcpus = &vcpus,
        .devices = &devices,
        .ram = ram,
        .config = &config,
    };
    var test_control = AttachTestControl{ .stream = try vsock_stream.HostStream.init(1024, "exec") };
    const control = test_control.control();

    // Nothing queued: the vCPUs keep running undisturbed.
    try std.testing.expect(try threaded.pollControl(control) == .keep_running);
    for (&vcpus) |*vcpu| try std.testing.expectEqual(@as(u32, 0), vcpu.kicks.load(.monotonic));

    // A delivered packet kicks each vCPU once so it sees the interrupt.
    test_control.attach = true;
    try std.testing.expect(try threaded.pollControl(control) == .keep_running);
    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, used + 2));
    for (&vcpus) |*vcpu| try std.testing.expectEqual(@as(u32, 1), vcpu.kicks.load(.monotonic));

    try std.testing.expect(try threaded.pollControl(control) == .keep_running);
    for (&vcpus) |*vcpu| try std.testing.expectEqual(@as(u32, 1), vcpu.kicks.load(.monotonic));
}

test "a snapshot fetches a store image's missing objects first, and a disk fork fetches none" {
    const image_store = @import("../image_store.zig");
    const runtime_disk = @import("../runtime_disk.zig");
    var fixture: image_store.TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const store = try fixture.path("store");
    _ = try fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/1", .{store}));
    const cache = try fixture.path("consumer-cache");
    try fixture.env.put(local_paths.rootfs_cache_env, cache);
    const ref = try std.fmt.allocPrint(allocator, "file://{s}/1", .{store});
    const local = try image_store.resolve(io, allocator, cache, ref, .{}, &fixture.env);
    var storage = local.storage;
    storage.device = .{ .mmio_slot = 1 };
    var runtime = try runtime_disk.open(.{ .io = io, .environ_map = &fixture.env }, std.testing.allocator, .{ .rootfs = .{
        .device = storage.device,
        .artifact = .{ .digest = storage.index_digest, .size = storage.logical_size, .format = spore.rootfs_artifact_format_ext4 },
        .storage = storage,
        .source = .{ .requested_ref = ref, .resolved_image_ref = ref, .image_manifest_digest = local.identity, .platform = "linux/arm64", .builder_version = rootfs_mod.builder_version },
    } });
    defer runtime.deinit();
    const fetcher = runtime.fetcher.?;

    // The store lost every object, so fetching the image must fail.
    try std.Io.Dir.cwd().deleteTree(io, try std.fs.path.join(allocator, &.{ store, "objects" }));
    var storages: [2][blk.sector_size]u8 = undefined;
    var blocks = [_]blk.Blk{ blk.Blk.initWithOptions(.{ .memory = &storages[0] }, .{}), blk.Blk.initWithOptions(.{ .memory = &storages[1] }, .{}) };
    var transports = [_]mmio.Transport{ mmio.Transport.init(blocks[0].device()), mmio.Transport.init(blocks[1].device()) };
    const gen_dev = generation.Device{};
    const vsock_dev = vsock.Vsock.init(.{ .guest_cid = vsock.default_guest_cid });
    const ram = try allocator.alloc(u8, spore.chunk_size);
    @memset(ram, 0);
    var config = testBoot(.{});
    config.disk_snapshot = runtime.snapshot();
    const source = SnapshotSource{ .config = &config, .transports = &transports, .gen_dev = &gen_dev, .vsock_dev = &vsock_dev, .ram_bytes = ram, .ram_size = ram.len };
    var vm = TestVm{};
    var vcpus = [_]TestVcpu{.{ .live = testVcpuState(0, .{ .cntvct = 1, .cntv_ctl = 0, .cntv_cval = 0 }) }};
    const NoTracker = struct {
        const metrics_mode = "full-scan";
        fn finish(_: *@This()) !spore.MemoryManifest {
            unreachable;
        }
        fn logSnapshotMetrics(_: *@This(), _: SnapshotMetrics) void {}
    };

    // A disk fork leaves the layer live and reads from the store later, so
    // it fetches nothing and goes on to write memory. (Its manifest then
    // needs the host counter frequency, which only an arm64 host has.)
    const fork_dir = try fixture.path("fork");
    writeSnapshot(std.testing.allocator, "test", &vm, @as([]TestVcpu, &vcpus), @as(?*NoTracker, null), source, .{ .dir = fork_dir, .disk = .quiesce_only }) catch |err| {
        try std.testing.expect(err != error.ImageStoreIncomplete);
    };
    try std.Io.Dir.cwd().access(io, try std.fs.path.join(allocator, &.{ fork_dir, "chunks" }), .{});
    try std.testing.expectEqual(@as(u64, 0), fetcher.stats.fetches);
    try std.testing.expectEqual(@as(u64, 0), fetcher.stats.errors);

    // A snapshot fetches first and fails before it writes anything.
    const save_dir = try fixture.path("save");
    try std.testing.expectError(error.ImageStoreIncomplete, writeSnapshot(std.testing.allocator, "test", &vm, @as([]TestVcpu, &vcpus), @as(?*NoTracker, null), source, .{ .dir = save_dir }));
    try std.testing.expect(fetcher.stats.errors != 0);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, save_dir, .{}));
}

fn testRunSource(config: *const Config, devices: *Devices, ram_bytes: []const u8) SnapshotSource {
    return .{
        .config = config,
        .transports = devices.transports(),
        .gen_dev = &devices.gen,
        .vsock_dev = &devices.vsock,
        .ram_bytes = ram_bytes,
        .ram_size = ram_bytes.len,
        .memory_device = if (devices.mem_index != null) &devices.mem else null,
    };
}

test "threaded run delivers a running probe's queued packets without a guest notification" {
    const allocator = std.testing.allocator;
    var config = testBoot(.{});
    var devices: Devices = undefined;
    devices.init(&config, null);
    defer devices.net.shutdown();
    var bytes = [_]u8{0} ** 0x2000;
    const ram = guestmem.GuestRam{ .bytes = &bytes, .base = board.ram_base };
    const used = try testVsockRxBuffer(&devices, ram);
    var stream = try vsock_stream.HostStream.init(1024, "exec");
    try devices.vsock.attachHostStream(&stream);
    // A run that never delivers ends when the probe times out.
    config.probe = .{ .stream = &stream, .timeout_ms = 5_000, .on_complete = .detach };

    // The guest shuts down when the vsock interrupt arrives.
    var vm = ThreadTestVm{ .shutdown_intid = board.virtioDeviceIntid(@intCast(devices.vsock_index)) };
    var vcpus = [_]ThreadTestVcpu{.{ .index = 0, .live = undefined }};
    var threaded: Threaded(ThreadTestVm, ThreadTestVcpu, DirtyTracker(TestDirtyBackend)) = .{
        .vm = &vm,
        .vcpus = &vcpus,
        .devices = &devices,
        .ram = ram,
        .config = &config,
    };
    defer threaded.deinit(allocator);
    try threaded.start(allocator);
    try std.testing.expectEqual(ExitCause.guest_off, try threaded.run(allocator, testRunSource(&config, &devices, &bytes)));
    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, used + 2));
}

test "threaded run grows virtio-mem when the probe reports memory pressure" {
    const allocator = std.testing.allocator;
    var config = testBoot(.{});
    var stream = try vsock_stream.HostStream.init(1024, "exec");
    stream.state = .connected;
    stream.memory_pressure_count = 2;
    // A run that never grows ends when the probe times out.
    config.probe = .{ .stream = &stream, .timeout_ms = 5_000, .on_complete = .detach };
    const region_size = 4 * 1024 * 1024 * 1024;
    var devices: Devices = undefined;
    devices.init(&config, .{ .addr = board.ram_base + config.start.boot.ram_size, .region_size = region_size, .requested_size = 0 });
    defer devices.net.shutdown();

    // The guest shuts down when the virtio-mem config change arrives.
    var vm = ThreadTestVm{ .shutdown_intid = board.virtioDeviceIntid(@intCast(devices.mem_index.?)) };
    var vcpus = [_]ThreadTestVcpu{.{ .index = 0, .live = undefined }};
    var threaded: Threaded(ThreadTestVm, ThreadTestVcpu, DirtyTracker(TestDirtyBackend)) = .{
        .vm = &vm,
        .vcpus = &vcpus,
        .devices = &devices,
        .ram = .{ .bytes = &.{}, .base = board.ram_base },
        .config = &config,
    };
    defer threaded.deinit(allocator);
    try threaded.start(allocator);
    try std.testing.expectEqual(ExitCause.guest_off, try threaded.run(allocator, testRunSource(&config, &devices, &.{})));
    try std.testing.expectEqual(virtio_mem.requestedSizeAfterPressure(0, region_size, 2), devices.mem.requested_size);
}

test "threaded capture request can keep the guest running" {
    // A spore records the host counter frequency, which only aarch64 hosts have.
    _ = platform.hostCounterFrequencyHz() catch return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/spore", .{tmp.sub_path[0..]});

    var request = capture.Request{};
    var config = testBoot(.{});
    config.capture = .{ .dir = dir, .trigger = .{ .request = .{ .req = &request, .then = .keep_running } } };
    var devices: Devices = undefined;
    devices.init(&config, null);
    defer devices.net.shutdown();
    var ram: [std.heap.page_size_min]u8 align(std.heap.page_size_min) = @splat(0);

    // The guest shuts down once captured, so a run that stopped at the
    // capture would end as `snapshotted` instead.
    var vm = ThreadTestVm{ .shutdown_on_capture = true };
    var vcpus = [_]ThreadTestVcpu{.{ .index = 0, .live = testVcpuState(0, .{ .cntvct = 100, .cntv_ctl = 0, .cntv_cval = 0 }) }};
    var threaded: Threaded(ThreadTestVm, ThreadTestVcpu, DirtyTracker(TestDirtyBackend)) = .{
        .vm = &vm,
        .vcpus = &vcpus,
        .devices = &devices,
        .ram = .{ .bytes = &ram, .base = board.ram_base },
        .config = &config,
    };
    defer threaded.deinit(allocator);
    try threaded.start(allocator);
    request.request();
    try std.testing.expectEqual(ExitCause.guest_off, try threaded.run(allocator, testRunSource(&config, &devices, &ram)));
    try std.testing.expect(request.isCompleted());
    try tmp.dir.access(std.testing.io, "spore/manifest.json", .{});
}

/// A guest's virtio-blk read of sector 1 into one 512-byte buffer, queued
/// and not yet notified, in `ram`, which holds 0x2000 bytes from
/// `board.ram_base`.
const TestBlkRead = struct {
    const desc = board.ram_base;
    const avail = board.ram_base + 0x400;
    const used = board.ram_base + 0x800;
    const header = board.ram_base + 0x1000;
    const data = board.ram_base + 0x1200;
    const status = board.ram_base + 0x1400;

    fn queue(t: *mmio.Transport, ram: guestmem.GuestRam) !void {
        _ = t.write(0x030, 0, ram);
        _ = t.write(0x038, 8, ram);
        inline for (.{ .{ 0x080, desc }, .{ 0x090, avail }, .{ 0x0a0, used } }) |reg| {
            _ = t.write(reg[0], @truncate(reg[1]), ram);
            _ = t.write(reg[0] + 4, @truncate(reg[1] >> 32), ram);
        }
        try std.testing.expect(!t.write(0x044, 1, ram));
        try ram.write(u32, header, 0); // VIRTIO_BLK_T_IN
        try ram.write(u64, header + 8, 1);
        inline for (.{ .{ header, 16, 0 }, .{ data, blk.sector_size, 2 }, .{ status, 1, 2 } }, 0..) |segment, index| {
            const entry = desc + 16 * index;
            try ram.write(u64, entry, segment[0]);
            try ram.write(u32, entry + 8, segment[1]);
            // VIRTQ_DESC_F_NEXT on all but the status byte.
            try ram.write(u16, entry + 12, segment[2] | @as(u16, if (index < 2) 1 else 0));
            try ram.write(u16, entry + 14, index + 1);
        }
        try ram.write(u16, avail + 4, 0);
        try ram.write(u16, avail + 2, 1);
        try ram.write(u8, status, 0xff);
    }

    fn usedIdx(ram: guestmem.GuestRam) !u16 {
        return ram.read(u16, used + 2);
    }

    /// Checks the read returned sector 1 of `disk` with an OK status.
    fn expectDone(ram: guestmem.GuestRam, disk: []const u8) !void {
        try std.testing.expectEqual(@as(u16, 1), try usedIdx(ram));
        try std.testing.expectEqual(@as(u32, blk.sector_size + 1), try ram.read(u32, used + 8));
        try std.testing.expectEqual(@as(u8, 0), try ram.read(u8, status));
        try std.testing.expectEqualSlices(u8, disk[blk.sector_size..][0..blk.sector_size], try ram.slice(data, blk.sector_size));
    }
};

const BlkTestThreaded = Threaded(ThreadTestVm, ThreadTestVcpu, DirtyTracker(TestDirtyBackend));

/// A 2-vCPU VM on `Threaded` whose root disk holds `disk`, with
/// `TestBlkRead` queued. The read stops at `read_barrier` before it touches
/// the disk.
const BlkTestRig = struct {
    /// The root disk's transport, after the console.
    const index = 1;

    disk: [2 * blk.sector_size]u8,
    read_barrier: test_barrier.Barrier = .{},
    /// What a thread `spawn` starts may block on.
    blockers: [1]*test_barrier.Barrier,
    config: Config,
    devices: Devices,
    bytes: [0x2000]u8 = @splat(0),
    vm: ThreadTestVm = .{},
    vcpus: [2]ThreadTestVcpu,
    threaded: BlkTestThreaded,

    /// Initializes in place, since the VM points into the rig. Call
    /// `deinit` even if this fails.
    fn start(rig: *BlkTestRig) !void {
        for (&rig.disk, 0..) |*byte, offset| byte.* = @truncate(offset *% 7);
        rig.read_barrier = .{};
        rig.blockers = .{&rig.read_barrier};
        rig.config = testBoot(.{ .vcpus = 2 });
        rig.config.disk_backend = .{ .memory = &rig.disk };
        rig.config.root_blk_options = .{ .test_read_barrier = &rig.read_barrier };
        rig.devices.init(&rig.config, null);
        rig.bytes = @splat(0);
        rig.vm = .{};
        rig.vcpus = .{
            .{ .index = 0, .live = testVcpuState(0, .{ .cntvct = 500, .cntv_ctl = 1, .cntv_cval = 530 }) },
            .{ .index = 1, .live = testVcpuState(1, .{ .cntvct = 500, .cntv_ctl = 1, .cntv_cval = 540 }) },
        };
        rig.threaded = .{ .vm = &rig.vm, .vcpus = &rig.vcpus, .devices = &rig.devices, .ram = rig.ram(), .config = &rig.config };
        try TestBlkRead.queue(&rig.devices.transports()[index], rig.ram());
        try rig.threaded.start(std.testing.allocator);
    }

    fn deinit(rig: *BlkTestRig) void {
        rig.threaded.deinit(std.testing.allocator);
        rig.devices.net.shutdown();
    }

    fn ram(rig: *BlkTestRig) guestmem.GuestRam {
        return .{ .bytes = &rig.bytes, .base = board.ram_base };
    }

    /// Writes `value` to the root disk's register at `offset`, as a vCPU's
    /// MMIO exit does.
    fn mmioWrite(rig: *BlkTestRig, offset: u64, value: u32) void {
        rig.threaded.device_lock.lockUncancelable(rig.config.io);
        defer rig.threaded.device_lock.unlock(rig.config.io);
        _ = dispatchMmio(&rig.vm, .{
            .addr = board.virtioDeviceBase(index) + offset,
            .size_log2 = 2,
            .write = value,
        }, rig.devices.transports(), &rig.devices.gen, rig.ram()) catch unreachable;
    }

    fn notify(rig: *BlkTestRig) void {
        rig.mmioWrite(0x050, 0);
    }

    fn reset(rig: *BlkTestRig) void {
        rig.mmioWrite(0x070, 0);
    }

    fn pause(rig: *BlkTestRig) void {
        rig.threaded.pauseAll(.none) catch unreachable;
    }

    fn capture(rig: *BlkTestRig) void {
        rig.threaded.pauseAll(.capture) catch unreachable;
    }

    /// Runs `func(rig)` on its own thread. The guard releases `read_barrier`
    /// before it joins the thread, so a failed test cannot leave it blocked.
    fn spawn(rig: *BlkTestRig, call: *TestCall, func: *const fn (*BlkTestRig) void) !test_barrier.ThreadGuard {
        const thread = try std.Thread.spawn(.{}, TestCall.run, .{ call, rig, func });
        return .{ .io = rig.config.io, .thread = thread, .barriers = &rig.blockers };
    }
};

/// Records when a call on another thread returns.
const TestCall = struct {
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *TestCall, rig: *BlkTestRig, func: *const fn (*BlkTestRig) void) void {
        func(rig);
        self.done.store(true, .release);
    }

    /// Whether it has returned after waiting a while.
    fn returnedSoon(self: *TestCall) bool {
        const ts = std.c.timespec{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
        return self.done.load(.acquire);
    }
};

test "a virtio-blk read runs on its worker, off the notifying vCPU and the device lock" {
    const io = std.testing.io;
    var rig: BlkTestRig = undefined;
    defer rig.deinit();
    try rig.start();

    var notify: TestCall = .{};
    var notifier = try rig.spawn(&notify, BlkTestRig.notify);
    defer notifier.deinit();
    rig.read_barrier.waitReached(io);
    // The read is under way. The vCPU that notified holds no lock, so other
    // vCPUs and devices go on.
    try std.testing.expect(rig.threaded.device_lock.tryLock());
    rig.threaded.device_lock.unlock(io);
    notifier.join();
    try std.testing.expectEqual(@as(u16, 0), try TestBlkRead.usedIdx(rig.ram()));
    try std.testing.expectEqual(@as(u32, 0), rig.vm.raises.load(.monotonic));

    rig.read_barrier.release(io);
    rig.threaded.drainBlkWorkers();
    try TestBlkRead.expectDone(rig.ram(), &rig.disk);
    try std.testing.expectEqual(@as(u32, 1), rig.vm.raises.load(.monotonic));
    // An idle vCPU sees the interrupt only once kicked.
    for (&rig.vcpus) |*vcpu| try std.testing.expectEqual(@as(u32, 1), vcpu.kicks.load(.monotonic));
}

test "a pause and a queue reset wait for the virtio-blk request in flight" {
    const io = std.testing.io;
    var rig: BlkTestRig = undefined;
    defer rig.deinit();
    try rig.start();
    rig.threaded.resumeAll();

    var notify: TestCall = .{};
    var notifier = try rig.spawn(&notify, BlkTestRig.notify);
    defer notifier.deinit();
    rig.read_barrier.waitReached(io);
    var pause: TestCall = .{};
    var pauser = try rig.spawn(&pause, BlkTestRig.pause);
    defer pauser.deinit();
    var reset: TestCall = .{};
    var resetter = try rig.spawn(&reset, BlkTestRig.reset);
    defer resetter.deinit();
    try std.testing.expect(!pause.returnedSoon());
    try std.testing.expect(!reset.returnedSoon());

    rig.read_barrier.release(io);
    notifier.join();
    pauser.join();
    resetter.join();
    // The request finished before the reset cleared the queue.
    try TestBlkRead.expectDone(rig.ram(), &rig.disk);
    try std.testing.expect(!rig.devices.transports()[BlkTestRig.index].queues[0].ready);
}

test "a capture that waits out an interrupt handler also waits for the disk request the guest makes meanwhile" {
    const io = std.testing.io;
    var rig: BlkTestRig = undefined;
    defer rig.deinit();
    try rig.start();
    // vCPU 0 is in an interrupt handler, and as it completes it the guest
    // notifies the disk. The vCPU threads are parked until the capture lets
    // the guest run on.
    rig.vcpus[0].handler_runs = .init(1);
    rig.vcpus[0].write_after_handler = .{ .addr = board.virtioDeviceBase(BlkTestRig.index) + 0x050, .size_log2 = 2, .write = 0 };

    var capture_call: TestCall = .{};
    var capturer = try rig.spawn(&capture_call, BlkTestRig.capture);
    defer capturer.deinit();
    rig.read_barrier.waitReached(io);
    try std.testing.expect(!capture_call.returnedSoon());

    rig.read_barrier.release(io);
    capturer.join();
    try TestBlkRead.expectDone(rig.ram(), &rig.disk);
    for (rig.threaded.states) |captured| try std.testing.expectEqual(@as(usize, 0), captured.state.icc_regs.len);
}
