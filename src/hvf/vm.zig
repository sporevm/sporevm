//! HVF virtual machine: board assembly and vCPU run loop.
//!
//! Boots the pinned kernel with the SporeVM board (GICv3 via hv_gic,
//! virtio-mmio console/blk/net/vsock/rng, generation MMIO), handles MMIO data
//! aborts, PSCI over HVC, vtimer exits, WFI, and HVF snapshot/resume.
//! Multi-vCPU capture/resume uses manifest v1 with same-HVF private GIC state.

const std = @import("std");
const capture = @import("../capture.zig");
const disk_layer = @import("../disk_layer.zig");
const dirty_ram = @import("../dirty_ram.zig");
const hvf = @import("hvf.zig");
const gic = @import("gic.zig");
const lazy_ram = @import("lazy_ram.zig");
const board = @import("../board.zig");
const boot = @import("../boot.zig");
const generation = @import("../generation.zig");
const guestmem = @import("../guestmem.zig");
const mmio = @import("../virtio/mmio.zig");
const console = @import("../virtio/console.zig");
const blk = @import("../virtio/blk.zig");
const net = @import("../virtio/net.zig");
const rng = @import("../virtio/rng.zig");
const virtio_mem = @import("../virtio/mem.zig");
const vsock = @import("../virtio/vsock.zig");
const platform_contract = @import("../platform.zig");
const spore = @import("../spore.zig");
const topology = @import("../topology.zig");
const snapshot = @import("snapshot.zig");

pub const Config = struct {
    kernel: []const u8,
    ram_size: u64 = 512 * 1024 * 1024,
    vcpus: topology.VcpuCount = 1,
    virtio_mem_region_size: u64 = 0,
    cmdline: []const u8 = "console=hvc0",
    initrd: ?[]const u8 = null,
    console_sink: *const fn ([]const u8) void,
    /// Host fd backing /dev/vda, if any. Immutable rootfs callers pass a
    /// read-only fd; guest write requests fail through the block device.
    disk_fd: ?std.c.fd_t = null,
    /// Full block backend for writable or layered rootfs runs. Takes
    /// precedence over disk_fd.
    disk_backend: ?blk.Backend = null,
    /// Optional active disk head to seal into a portable manifest layer when
    /// a snapshot is taken.
    disk_snapshot: ?disk_layer.SnapshotState = null,
    /// Immutable rootfs artifact metadata for disk-backed snapshots.
    rootfs: ?spore.Rootfs = null,
    /// Requested network capability and policy metadata for snapshots.
    network_manifest: ?spore.Network = null,
    annotations: spore.Annotations = .{},
    sessions: []const spore.Session = &.{},
    /// Poll fd 0 (set non-blocking by the caller) for console input on
    /// guest idle exits.
    poll_stdin: bool = false,
    /// Resume from a spore directory instead of booting the kernel.
    resume_dir: ?[]const u8 = null,
    /// Optional pre-refreshed generation state for product resume attach.
    resume_generation: ?generation.State = null,
    /// Proof-validated same-host RAM backing fd. The fd must refer to the
    /// manifest's optional RAM backing and is mapped MAP_PRIVATE; imported or
    /// unproven spores must leave this null so RAM is materialized through
    /// verified chunks.
    ram_backing_fd: ?std.c.fd_t = null,
    /// Product callers provide their environment so snapshot code can write
    /// local-only RAM backing proofs under the configured runtime root.
    environ_map: ?*const std.process.Environ.Map = null,
    /// Chunk restore strategy for cold/imported HVF resumes. Eager remains the
    /// default; lazy is an explicit development path backed by RAM abort exits
    /// on unmapped guest memory.
    ram_restore_mode: RamRestoreMode = .eager_chunks,
    /// Optional fd that receives one line per lazily materialized chunk.
    lazy_ram_trace_fd: ?std.c.fd_t = null,
    /// Take a spore snapshot after this many milliseconds of run time and
    /// stop. Requires snapshot_dir.
    snapshot_after_ms: ?u64 = null,
    snapshot_dir: ?[]const u8 = null,
    /// Snapshot and stop when the exec probe has observed command completion.
    snapshot_on_probe_complete: bool = false,
    /// Optional host request that asks the run loop to snapshot at the next
    /// settled boundary. A second request aborts the run.
    capture_request: ?*capture.Request = null,
    /// Continue running after a host-requested capture instead of stopping.
    continue_after_capture: bool = false,
    /// Opt-in HVF write-protect dirty tracking. When enabled, guest write
    /// faults identify dirty chunks and snapshots only need a final dirty-tail
    /// flush instead of a full RAM scan.
    dirty_tracking: DirtyTrackingOptions = .{},
    /// Optional minimal host-initiated vsock stream used by benchmark harnesses.
    exec_probe: ?*vsock.HostStream = null,
    exec_probe_timeout_ms: u64 = 30_000,
    exec_probe_completes_run: bool = true,
    exec_probe_failure_fatal: bool = true,
    /// Optional virtio-net frame backend. The default remains closed.
    network: net.Runtime = .{},
    /// Optional monitor control hook for attaching host streams after boot.
    exec_control: ?vsock.Control = null,
};

fn hasFreshCaptureTrigger(config: Config) bool {
    return config.snapshot_after_ms != null or config.snapshot_on_probe_complete or config.capture_request != null;
}

pub const ExitCause = enum { guest_off, guest_reset, snapshotted, probe_complete, monitor_stopped };

pub const DirtyTrackingOptions = struct {
    enabled: bool = false,
    /// 0 disables periodic sealing and measures only the final tail flush.
    epoch_ms: u64 = 250,
};

pub const RamRestoreMode = enum {
    eager_chunks,
    lazy_chunks,
};

const RestoreStats = struct {
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

const RamMapping = struct {
    bytes: []align(std.heap.page_size_min) u8,
    file_backed: bool,

    fn deinit(self: RamMapping) void {
        std.posix.munmap(self.bytes);
    }
};

const HotplugMapping = struct {
    bytes: []align(std.heap.page_size_min) u8,
    guest_addr: u64,
    mapped_bytes: u64 = 0,

    fn init(size: u64, guest_addr: u64) !HotplugMapping {
        return .{
            .bytes = (try mapAnonymousRam(size)).bytes,
            .guest_addr = guest_addr,
        };
    }

    fn deinit(self: *HotplugMapping) void {
        if (self.mapped_bytes != 0) _ = hvf.hv_vm_unmap(self.guest_addr, self.mapped_bytes);
        std.posix.munmap(self.bytes);
    }

    fn mapForGuest(self: *HotplugMapping, bytes: u64) !void {
        if (bytes > self.bytes.len) return error.InvalidVirtioMemRequest;
        if (bytes <= self.mapped_bytes) return;
        const offset: usize = @intCast(self.mapped_bytes);
        const len: usize = @intCast(bytes - self.mapped_bytes);
        try hvf.check(
            hvf.hv_vm_map(self.bytes[offset..][0..len].ptr, self.guest_addr + self.mapped_bytes, len, hvf.MemoryFlags.rwx),
            "hv_vm_map virtio-mem",
        );
        self.mapped_bytes = bytes;
        std.log.debug("virtio-mem mapped hotplug region: addr=0x{x} bytes={d}", .{ self.guest_addr, bytes });
    }

    fn plug(ctx: *anyopaque, requested_size: u64) bool {
        const self: *HotplugMapping = @ptrCast(@alignCast(ctx));
        self.mapForGuest(requested_size) catch return false;
        return true;
    }
};

const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

// PSCI v1.x (ARM DEN 0022) function ids and return codes.
const psci_version: u32 = 0x8400_0000;
const psci_cpu_off: u32 = 0x8400_0002;
const psci_cpu_on_32: u32 = 0x8400_0003;
const psci_cpu_on_64: u32 = 0xc400_0003;
const psci_migrate_info_type: u32 = 0x8400_0006;
const psci_system_off: u32 = 0x8400_0008;
const psci_system_reset: u32 = 0x8400_0009;
const psci_features: u32 = 0x8400_000a;
const psci_ret_not_supported: u64 = @bitCast(@as(i64, -1));
const psci_ret_invalid_params: u64 = @bitCast(@as(i64, -2));
const psci_ret_already_on: u64 = @bitCast(@as(i64, -4));

const ec_wfx: u6 = 0x01;
const ec_sysreg: u6 = 0x18;

pub fn run(allocator: std.mem.Allocator, input_config: Config) !ExitCause {
    var config = input_config;
    const setup_start = monotonicMs();
    try topology.validateVcpuCount(config.vcpus);
    if (config.vcpus != 1 and (config.dirty_tracking.enabled or config.virtio_mem_region_size != 0 or config.continue_after_capture)) {
        return error.UnsupportedVcpuCount;
    }
    const hv_vm_create_start = setup_start;
    try hvf.check(hvf.hv_vm_create(null), "hv_vm_create");
    const hv_vm_create_ms = monotonicMs() - hv_vm_create_start;
    defer _ = hvf.hv_vm_destroy();

    var resume_parsed: ?std.json.Parsed(spore.Manifest) = null;
    defer if (resume_parsed) |*parsed| parsed.deinit();
    var resume_v1_parsed: ?std.json.Parsed(spore.ManifestV1) = null;
    defer if (resume_v1_parsed) |*parsed| parsed.deinit();
    var lazy_pager: ?lazy_ram.Pager = null;
    var dirty_tracker: ?DirtyTracker = null;
    var restore_stats: ?RestoreStats = null;
    if (config.dirty_tracking.enabled and (config.resume_dir != null or config.snapshot_dir == null or !hasFreshCaptureTrigger(config))) {
        return error.BadManifest;
    }
    if (config.ram_backing_fd != null and config.ram_restore_mode == .lazy_chunks) return error.BadManifest;
    if (config.resume_dir) |spore_dir| {
        const manifest_start = monotonicMs();
        if (config.vcpus == 1) {
            resume_parsed = spore.loadManifest(allocator, spore_dir) catch |err| switch (err) {
                error.BadManifest => null,
                else => |e| return e,
            };
            if (resume_parsed == null) {
                resume_v1_parsed = try spore.loadManifestV1(allocator, spore_dir);
                config.vcpus = resume_v1_parsed.?.value.platform.vcpu_count;
            }
        } else {
            resume_v1_parsed = try spore.loadManifestV1(allocator, spore_dir);
            if (resume_v1_parsed.?.value.platform.vcpu_count != config.vcpus) return error.PlatformMismatch;
        }
        restore_stats = .{
            .start_ms = manifest_start,
            .manifest_ms = monotonicMs() - manifest_start,
        };
    }
    try topology.validateVcpuCount(config.vcpus);
    if (config.vcpus != 1 and (config.dirty_tracking.enabled or config.virtio_mem_region_size != 0 or config.continue_after_capture)) {
        return error.UnsupportedVcpuCount;
    }

    // GIC layout from runtime parameters; created before any vCPU.
    const gic_start = monotonicMs();
    var dist_size: usize = 0;
    var dist_align: usize = 0;
    var redist_size: usize = 0;
    var redist_align: usize = 0;
    try hvf.check(hvf.hv_gic_get_distributor_size(&dist_size), "gic dist size");
    try hvf.check(hvf.hv_gic_get_distributor_base_alignment(&dist_align), "gic dist align");
    try hvf.check(hvf.hv_gic_get_redistributor_region_size(&redist_size), "gic redist size");
    try hvf.check(hvf.hv_gic_get_redistributor_base_alignment(&redist_align), "gic redist align");

    const default_dist_base: u64 = std.mem.alignForward(u64, 0x0800_0000, dist_align);
    const default_redist_base: u64 = std.mem.alignForward(u64, default_dist_base + dist_size, redist_align);
    const dist_base: u64 = if (resume_parsed) |parsed| parsed.value.platform.gic_dist_base else if (resume_v1_parsed) |parsed| parsed.value.platform.gic_dist_base else default_dist_base;
    const redist_base: u64 = if (resume_parsed) |parsed| parsed.value.platform.gic_redist_base else if (resume_v1_parsed) |parsed| parsed.value.platform.gic_redist_base else default_redist_base;
    if (dist_base % dist_align != 0 or redist_base % redist_align != 0) return error.PlatformMismatch;

    const gic_config = hvf.hv_gic_config_create();
    defer hvf.os_release(gic_config);
    try hvf.check(hvf.hv_gic_config_set_distributor_base(gic_config, dist_base), "gic set dist base");
    try hvf.check(hvf.hv_gic_config_set_redistributor_base(gic_config, redist_base), "gic set redist base");
    try hvf.check(hvf.hv_gic_create(gic_config), "hv_gic_create");
    const gic_ms = monotonicMs() - gic_start;

    // Guest RAM. Eager and proof-gated local backing resumes map the whole
    // range up front; lazy chunk resumes leave it unmapped in HVF and
    // materialize chunks from instruction/data-abort exits in the run loop.
    const map_ram_start = monotonicMs();
    const resume_memory: ?spore.MemoryManifest = if (resume_parsed) |parsed| parsed.value.memory else if (resume_v1_parsed) |parsed| parsed.value.memory else null;
    const ram_mapping = try mapRam(config, resume_memory);
    const map_ram_ms = monotonicMs() - map_ram_start;
    if (restore_stats) |*stats| stats.map_ram_ms = map_ram_ms;
    defer ram_mapping.deinit();
    defer if (lazy_pager) |*pager| pager.deinit();
    const ram_bytes = ram_mapping.bytes;
    var ram_mapped_at_start = false;
    var hv_map_ram_ms: u64 = 0;
    if (shouldMapRamAtStart(config, ram_mapping)) {
        const hv_map_ram_start = monotonicMs();
        try hvf.check(
            hvf.hv_vm_map(ram_bytes.ptr, board.ram_base, ram_bytes.len, hvf.MemoryFlags.rwx),
            "hv_vm_map ram",
        );
        hv_map_ram_ms = monotonicMs() - hv_map_ram_start;
        ram_mapped_at_start = true;
    }
    defer {
        if (ram_mapped_at_start) _ = hvf.hv_vm_unmap(board.ram_base, ram_bytes.len);
    }
    defer if (dirty_tracker) |*tracker| tracker.deinit();
    var ram = guestmem.GuestRam{ .bytes = ram_bytes, .base = board.ram_base };
    var hotplug_mapping: ?HotplugMapping = if (config.virtio_mem_region_size > 0)
        try HotplugMapping.init(config.virtio_mem_region_size, board.ram_base + config.ram_size)
    else
        null;
    defer if (hotplug_mapping) |*mapping| mapping.deinit();

    // Devices: console is virtio-mmio slot 0, disk (if any) follows, then net, vsock, rng.
    // The generation device is a separate fixed MMIO window after the reserved virtio range.
    const devices_start = monotonicMs();
    var con = console.Console{ .sink = config.console_sink };
    var blk_dev: blk.Blk = undefined;
    var net_dev = net.Net.init(.{ .backend = config.network.backend });
    defer net_dev.shutdown();
    var rng_dev = rng.Rng{};
    var vsock_dev = vsock.Vsock.init(.{});
    var mem_dev: virtio_mem.Mem = undefined;
    var gen_dev = generation.Device{};
    var transports_buf: [6]mmio.Transport = undefined;
    transports_buf[0] = mmio.Transport.init(con.device());
    var transport_count: usize = 1;
    const disk_backend: ?blk.Backend = if (config.disk_backend) |backend| backend else if (config.disk_fd) |fd| .{ .file = fd } else null;
    if (disk_backend) |backend| {
        blk_dev = blk.Blk.init(backend);
        transports_buf[1] = mmio.Transport.init(blk_dev.device());
        transport_count = 2;
    }
    const net_transport_index = transport_count;
    transports_buf[transport_count] = mmio.Transport.init(net_dev.device());
    transport_count += 1;
    const vsock_transport_index = transport_count;
    transports_buf[transport_count] = mmio.Transport.init(vsock_dev.device());
    transport_count += 1;
    transports_buf[transport_count] = mmio.Transport.init(rng_dev.device());
    transport_count += 1;
    var mem_transport_index: ?usize = null;
    if (hotplug_mapping) |*mapping| {
        mem_dev = virtio_mem.Mem.init(.{
            .addr = mapping.guest_addr,
            .region_size = @intCast(mapping.bytes.len),
            .requested_size = 0,
            .plug_context = mapping,
            .plugFn = HotplugMapping.plug,
        });
        mem_transport_index = transport_count;
        transports_buf[transport_count] = mmio.Transport.init(mem_dev.device());
        transport_count += 1;
    }
    const transports = transports_buf[0..transport_count];
    const devices_ms = monotonicMs() - devices_start;

    if (config.vcpus != 1) {
        return runFreshMultiVcpu(allocator, .{
            .config = &config,
            .resume_manifest = if (resume_v1_parsed) |*parsed| &parsed.value else null,
            .restore_stats = &restore_stats,
            .transports = transports,
            .transports_buf = &transports_buf,
            .gen_dev = &gen_dev,
            .ram = ram,
            .ram_bytes = ram_bytes,
            .ram_file_backed = ram_mapping.file_backed,
            .net_dev = &net_dev,
            .vsock_dev = &vsock_dev,
            .net_transport_index = net_transport_index,
            .vsock_transport_index = vsock_transport_index,
            .rootfs = config.rootfs,
            .disk_snapshot = config.disk_snapshot,
            .network_manifest = config.network_manifest,
            .annotations = config.annotations,
            .environ_map = config.environ_map,
            .dist_base = dist_base,
            .dist_size = dist_size,
            .redist_region_base = redist_base,
            .redist_region_size = redist_size,
            .setup_start = setup_start,
            .hv_vm_create_ms = hv_vm_create_ms,
            .gic_ms = gic_ms,
            .map_ram_ms = map_ram_ms,
            .hv_map_ram_ms = hv_map_ram_ms,
            .devices_ms = devices_ms,
        });
    }

    // vCPU. Created before the DTB because the framework assigns the
    // redistributor frame from the vCPU's MPIDR affinity.
    const vcpu_start = monotonicMs();
    var vcpu: hvf.VcpuHandle = undefined;
    var exit: *hvf.VcpuExit = undefined;
    try hvf.check(hvf.hv_vcpu_create(&vcpu, &exit, null), "hv_vcpu_create");
    defer _ = hvf.hv_vcpu_destroy(vcpu);
    if (config.capture_request) |request_capture| {
        request_capture.setWake(wakeCaptureVcpu, &vcpu);
    }
    defer if (config.capture_request) |request_capture| request_capture.clearWake();
    if (config.exec_control) |control| {
        control.setWake(.{ .context = &vcpu, .wakeFn = wakeVcpu });
    }
    config.network.setWake(.{ .context = &vcpu, .wakeFn = wakeNetworkVcpu });
    defer config.network.clearWake();

    try hvf.check(hvf.hv_vcpu_set_sys_reg(vcpu, .mpidr_el1, topology.mpidrForIndex(0)), "set mpidr");
    var vcpu_redist_base: hvf.Ipa = 0;
    try hvf.check(hvf.hv_gic_get_redistributor_base(vcpu, &vcpu_redist_base), "gic redist base for vcpu");
    var redist_stride: usize = 0;
    try hvf.check(hvf.hv_gic_get_redistributor_size(&redist_stride), "gic redist stride");

    std.log.debug(
        "gic: dist=0x{x}+0x{x} redist(vcpu0)=0x{x}+0x{x} (region 0x{x}+0x{x})",
        .{ dist_base, dist_size, vcpu_redist_base, redist_stride, redist_base, redist_size },
    );
    const vcpu_ms = monotonicMs() - vcpu_start;

    var boot_ms: u64 = 0;
    if (config.resume_dir) |spore_dir| {
        if (resume_v1_parsed != null) return error.UnsupportedVcpuCount;
        // Restore: memory, device, GIC, and vCPU state from the spore.
        const m = resume_parsed.?.value;
        const host_counter_frequency_hz = snapshot.hostCounterFreq();
        try platform_contract.checkManifest(m, .{
            .ram_size = config.ram_size,
            .gic_dist_base = dist_base,
            .gic_redist_base = vcpu_redist_base,
            .counter_frequency_hz = host_counter_frequency_hz,
            .device_count = transports.len,
        });
        const memory_plan = try spore.validateMemoryForRam(m.memory, ram_bytes.len);
        if (restore_stats) |*stats| {
            stats.chunk_count = memory_plan.chunk_count;
            stats.nonzero_chunk_count = memory_plan.nonzero_chunk_count;
        }
        if (ram_mapping.file_backed) {
            if (restore_stats) |*stats| stats.mode = "local_backing";
        } else switch (config.ram_restore_mode) {
            .eager_chunks => {
                if (restore_stats) |*stats| stats.mode = "eager_chunks";
                const memory_start = monotonicMs();
                try spore.loadMemory(allocator, spore_dir, m.memory, ram_bytes);
                if (restore_stats) |*stats| stats.memory_ms = monotonicMs() - memory_start;
            },
            .lazy_chunks => {
                if (restore_stats) |*stats| stats.mode = "lazy_chunks";
                const memory_start = monotonicMs();
                lazy_pager = try lazy_ram.Pager.start(allocator, .{
                    .dir = spore_dir,
                    .manifest = m.memory,
                    .ram = ram_bytes,
                    .trace_fd = config.lazy_ram_trace_fd,
                });
                if (restore_stats) |*stats| stats.memory_ms = monotonicMs() - memory_start;
            },
        }
        const state_start = monotonicMs();
        try applyTransports(transports, m.devices);
        if (lazy_pager) |*pager| try materializeAllTransportQueues(pager, transports);
        try gen_dev.restore(allocator, config.resume_generation orelse m.generation);
        if (config.resume_generation == null) try spore.refreshResumeParams(allocator, &gen_dev);
        try snapshot.applyMachine(allocator, vcpu, m.machine);
        try raiseGenerationIrqIfPending(&gen_dev);
        if (restore_stats) |*stats| stats.state_ms = monotonicMs() - state_start;
    } else {
        // Fresh boot: DTB + kernel. Backend support is currently gated to one
        // vCPU, but DTB construction consumes the shared topology contract.
        const boot_start = monotonicMs();
        const initrd_range = if (config.initrd) |initrd| try boot.planInitrd(ram_bytes.len, board.ram_base, config.kernel, initrd.len) else null;
        const dtb = try board.buildDtb(allocator, .{
            .ram_size = config.ram_size,
            .cpu_count = config.vcpus,
            .gic = .{
                .distributor_base = dist_base,
                .distributor_size = dist_size,
                .redistributor_base = vcpu_redist_base,
                .redistributor_size = try board.redistributorRegionSize(@intCast(redist_stride), config.vcpus),
            },
            .virtio_count = @intCast(transports.len),
            .bootargs = config.cmdline,
            .initrd = if (initrd_range) |r| .{ .start = r.start, .end = r.end } else null,
        });
        defer allocator.free(dtb);
        const layout = try boot.load(ram_bytes, board.ram_base, config.kernel, config.initrd, dtb);
        var seed_ranges_buf: [3]dirty_ram.ChunkRange = undefined;
        for (layout.populatedRanges(), 0..) |range, i| {
            seed_ranges_buf[i] = .{ .start = range.start, .end = range.end };
        }
        const seed_ranges = seed_ranges_buf[0..layout.populated_range_count];

        try hvf.check(hvf.hv_vcpu_set_reg(vcpu, .cpsr, 0x3c5), "set cpsr"); // EL1h, DAIF masked
        try hvf.check(hvf.hv_vcpu_set_reg(vcpu, .pc, layout.entry), "set pc");
        try hvf.check(hvf.hv_vcpu_set_reg(vcpu, .x0, layout.dtb), "set x0");

        if (config.dirty_tracking.enabled) {
            dirty_tracker = try DirtyTracker.start(allocator, .{
                .dir = config.snapshot_dir.?,
                .ram = ram_bytes,
                .seed_ranges = seed_ranges,
                .epoch_ms = config.dirty_tracking.epoch_ms,
            });
            if (dirty_tracker) |*tracker| {
                ram.dirty_context = tracker;
                ram.dirty_fn = DirtyTracker.markGuestWriteCallback;
                try tracker.startWorker();
            }
        }
        boot_ms = monotonicMs() - boot_start;
    }

    const counter_start = snapshot.hostCounter();
    const counter_freq = snapshot.hostCounterFreq();
    const start_ms = monotonicMs();
    if (restore_stats) |*stats| {
        stats.pre_run_ms = start_ms - stats.start_ms;
        std.log.info(
            "hvf restore metrics: mode={s} ram_mib={d} chunks={d} nonzero_chunks={d} manifest_ms={d} map_ram_ms={d} memory_ms={d} state_ms={d} pre_run_ms={d}",
            .{
                stats.mode,
                config.ram_size / 1024 / 1024,
                stats.chunk_count,
                stats.nonzero_chunk_count,
                stats.manifest_ms,
                stats.map_ram_ms,
                stats.memory_ms,
                stats.state_ms,
                stats.pre_run_ms,
            },
        );
    }
    var attach_probe_ms: u64 = 0;
    if (config.exec_probe) |probe| {
        const attach_probe_start = monotonicMs();
        try vsock_dev.attachHostStream(probe);
        probe.markStarted();
        const pager: ?*lazy_ram.Pager = if (lazy_pager) |*p| p else null;
        try flushVsockRx(&vsock_dev, &transports_buf[vsock_transport_index], ram, pager, @intCast(vsock_transport_index));
        attach_probe_ms = monotonicMs() - attach_probe_start;
    }
    if (config.resume_dir == null) {
        std.log.debug(
            "hvf cold setup timing: total_ms={d} hv_vm_create_ms={d} gic_ms={d} mmap_ram_ms={d} hv_map_ram_ms={d} devices_ms={d} vcpu_ms={d} boot_ms={d} attach_probe_ms={d} ram_mib={d}",
            .{
                start_ms - setup_start,
                hv_vm_create_ms,
                gic_ms,
                map_ram_ms,
                hv_map_ram_ms,
                devices_ms,
                vcpu_ms,
                boot_ms,
                attach_probe_ms,
                config.ram_size / 1024 / 1024,
            },
        );
    }
    var exec_probe_done = false;
    var handled_memory_pressure_count: u32 = 0;
    var requested_hotplug_size: u64 = 0;
    var logged_first_vcpu_entry = false;
    var logged_first_guest_exit = false;

    // Run loop.
    var did_capture_request = false;
    while (true) {
        if (config.exec_probe != null and !exec_probe_done) {
            const pager: ?*lazy_ram.Pager = if (lazy_pager) |*p| p else null;
            try flushVsockRx(&vsock_dev, &transports_buf[vsock_transport_index], ram, pager, @intCast(vsock_transport_index));
        }
        if (mem_transport_index != null) {
            if (config.exec_probe) |probe| {
                const new_pressure_events = probe.memory_pressure_count -| handled_memory_pressure_count;
                if (new_pressure_events > 0 and probe.state == .connected) {
                    const idx = mem_transport_index.?;
                    const mapping = if (hotplug_mapping) |*m| m else unreachable;
                    requested_hotplug_size = virtio_mem.requestedSizeAfterPressure(requested_hotplug_size, @intCast(mapping.bytes.len), new_pressure_events);
                    handled_memory_pressure_count = probe.memory_pressure_count;
                    try mem_dev.setRequestedSize(@intCast(requested_hotplug_size));
                    _ = transports_buf[idx].raiseConfigChange();
                    try hvf.check(hvf.hv_gic_set_spi(board.virtioDeviceIntid(@intCast(idx)), true), "raise virtio-mem config spi");
                    std.log.debug("virtio-mem requested hotplug size: bytes={d} pressure_count={d}", .{ requested_hotplug_size, handled_memory_pressure_count });
                }
            }
        }
        if (config.network.failed()) return error.NetworkGatewayFailed;
        if (config.network.consumeWake()) {
            const pager: ?*lazy_ram.Pager = if (lazy_pager) |*p| p else null;
            try flushNetworkRxHvf(&net_dev, &transports_buf[net_transport_index], ram, pager, net_transport_index);
            continue;
        }
        if (config.exec_control) |control| {
            control.reportStats(monitorStatsFromDirtyTracker(if (dirty_tracker) |*tracker| tracker else null));
            switch (try control.poll(&vsock_dev)) {
                .keep_running => {},
                .stop => return .monitor_stopped,
                .snapshot => |request| {
                    try takeSnapshot(allocator, request.dir, vcpu, transports, &gen_dev, ram_bytes, .{
                        .dist_base = dist_base,
                        .redist_base = vcpu_redist_base,
                        .ram_size = config.ram_size,
                    }, config.rootfs, config.disk_snapshot, config.network_manifest, config.annotations, config.sessions, if (dirty_tracker) |*tracker| tracker else null, config.environ_map);
                    if (!request.continue_after) return .snapshotted;
                    try control.completeSnapshot(request.dir);
                },
            }
            const pager: ?*lazy_ram.Pager = if (lazy_pager) |*p| p else null;
            try flushVsockRx(&vsock_dev, &transports_buf[vsock_transport_index], ram, pager, @intCast(vsock_transport_index));
        }
        if (config.capture_request) |request_capture| {
            if (request_capture.isAbortRequested()) return error.CaptureAborted;
            if (request_capture.isRequested() and !did_capture_request) {
                const dir = config.snapshot_dir orelse return error.HvCallFailed;
                try takeSnapshot(allocator, dir, vcpu, transports, &gen_dev, ram_bytes, .{
                    .dist_base = dist_base,
                    .redist_base = vcpu_redist_base,
                    .ram_size = config.ram_size,
                }, config.rootfs, config.disk_snapshot, config.network_manifest, config.annotations, config.sessions, if (dirty_tracker) |*tracker| tracker else null, config.environ_map);
                request_capture.markCompleted();
                if (request_capture.isAbortRequested()) return error.CaptureAborted;
                if (config.continue_after_capture) {
                    did_capture_request = true;
                    continue;
                }
                return .snapshotted;
            }
        }
        if (config.exec_probe) |probe| {
            if (!exec_probe_done) {
                if (probe.state == .failed) {
                    if (config.exec_probe_failure_fatal) return error.VsockProbeFailed;
                    vsock_dev.host_stream = null;
                    exec_probe_done = true;
                }
                if (probe.state == .complete) {
                    if (config.exec_probe_completes_run) {
                        if (config.snapshot_on_probe_complete) {
                            const dir = config.snapshot_dir orelse return error.HvCallFailed;
                            try takeSnapshot(allocator, dir, vcpu, transports, &gen_dev, ram_bytes, .{
                                .dist_base = dist_base,
                                .redist_base = vcpu_redist_base,
                                .ram_size = config.ram_size,
                            }, config.rootfs, config.disk_snapshot, config.network_manifest, config.annotations, config.sessions, if (dirty_tracker) |*tracker| tracker else null, config.environ_map);
                            return .snapshotted;
                        }
                        return .probe_complete;
                    }
                    vsock_dev.host_stream = null;
                    exec_probe_done = true;
                }
                if (!exec_probe_done and probe.elapsedMs() > config.exec_probe_timeout_ms) {
                    if (config.exec_probe_failure_fatal) return error.VsockProbeTimedOut;
                    vsock_dev.host_stream = null;
                    exec_probe_done = true;
                }
            }
        }
        if (config.snapshot_after_ms) |after_ms| {
            const elapsed_ms = (snapshot.hostCounter() - counter_start) * 1000 / counter_freq;
            if (elapsed_ms >= after_ms) {
                const dir = config.snapshot_dir orelse return error.HvCallFailed;
                try takeSnapshot(allocator, dir, vcpu, transports, &gen_dev, ram_bytes, .{
                    .dist_base = dist_base,
                    .redist_base = vcpu_redist_base,
                    .ram_size = config.ram_size,
                }, config.rootfs, config.disk_snapshot, config.network_manifest, config.annotations, config.sessions, if (dirty_tracker) |*tracker| tracker else null, config.environ_map);
                return .snapshotted;
            }
        }
        if (config.resume_dir != null and config.exec_probe != null and !logged_first_vcpu_entry) {
            logged_first_vcpu_entry = true;
            std.log.debug("hvf exec probe timing: first_vcpu_entry_ms={d}", .{monotonicMs() -| start_ms});
        }
        try hvf.check(hvf.hv_vcpu_run(vcpu), "hv_vcpu_run");
        if (config.exec_probe != null and !exec_probe_done and exit.reason != .canceled) {
            if (config.resume_dir != null and !logged_first_guest_exit) {
                logged_first_guest_exit = true;
                std.log.debug(
                    "hvf exec probe timing: first_guest_exit_ms={d} reason={}",
                    .{ monotonicMs() -| start_ms, exit.reason },
                );
            }
        }
        switch (exit.reason) {
            .exception => {
                const ec = exit.exception.exceptionClass();
                switch (ec) {
                    hvf.ec_instruction_abort => {
                        if (lazy_pager) |*pager| {
                            if (pager.isRamFault(exit.exception.physical_address)) {
                                try pager.materializeFault(exit.exception.physical_address);
                                continue;
                            }
                        }
                        std.log.err(
                            "unhandled instruction abort syndrome=0x{x} va=0x{x} ipa=0x{x}",
                            .{ exit.exception.syndrome, exit.exception.virtual_address, exit.exception.physical_address },
                        );
                        return error.UnhandledGuestException;
                    },
                    hvf.ec_data_abort => {
                        if (lazy_pager) |*pager| {
                            if (pager.isRamFault(exit.exception.physical_address)) {
                                try pager.materializeFault(exit.exception.physical_address);
                                continue;
                            }
                        }
                        if (dirty_tracker) |*tracker| {
                            if (try tracker.handleWriteFault(exit.exception.syndrome, exit.exception.physical_address)) {
                                continue;
                            }
                        }
                        try handleMmio(vcpu, exit, transports, &gen_dev, ram, if (lazy_pager) |*pager| pager else null, .{
                            .dist_base = dist_base,
                            .dist_size = dist_size,
                            .redist_base = vcpu_redist_base,
                            .redist_size = redist_stride,
                        }, null);
                    },
                    hvf.ec_hvc => {
                        if (try handlePsci(vcpu)) |cause| return cause;
                    },
                    hvf.ec_smc => {
                        // Treat SMC like HVC but advance PC (trapped SMC
                        // returns to the same instruction).
                        const cause = try handlePsci(vcpu);
                        try advancePc(vcpu);
                        if (cause) |c| return c;
                    },
                    ec_wfx => {
                        // WFI/WFE: nothing better to do single-threaded yet;
                        // poll input, yield briefly, let the vtimer wake us.
                        try advancePc(vcpu);
                        if (config.poll_stdin) {
                            if (lazy_pager) |*pager| try materializeTransportQueues(pager, &transports[0]);
                            try drainStdin(&con, &transports[0], ram);
                        }
                        var ts = std.c.timespec{ .sec = 0, .nsec = 200 * std.time.ns_per_us };
                        _ = std.c.nanosleep(&ts, null);
                    },
                    ec_sysreg => {
                        // Unhandled sysreg access: RAZ/WI. ISS bit 0 is
                        // direction (1 = read).
                        const iss: u32 = @truncate(exit.exception.syndrome & 0x1ff_ffff);
                        if (iss & 1 != 0) {
                            const rt: hvf.Reg = @enumFromInt(@as(u32, @truncate((iss >> 5) & 0x1f)));
                            if (@intFromEnum(rt) < 31) {
                                try hvf.check(hvf.hv_vcpu_set_reg(vcpu, rt, 0), "sysreg raz");
                            }
                        }
                        try advancePc(vcpu);
                    },
                    else => {
                        std.log.err(
                            "unhandled exception class 0x{x} syndrome=0x{x} va=0x{x} ipa=0x{x}",
                            .{ ec, exit.exception.syndrome, exit.exception.virtual_address, exit.exception.physical_address },
                        );
                        return error.UnhandledGuestException;
                    },
                }
            },
            .vtimer_activated => {
                // With hv_gic the timer PPI is delivered by the GIC; unmask
                // so subsequent timer exits can fire.
                try hvf.check(hvf.hv_vcpu_set_vtimer_mask(vcpu, false), "vtimer unmask");
                if (config.poll_stdin) {
                    if (lazy_pager) |*pager| try materializeTransportQueues(pager, &transports[0]);
                    try drainStdin(&con, &transports[0], ram);
                }
            },
            .canceled => {
                if (config.capture_request) |request_capture| {
                    if (request_capture.isAbortRequested()) return error.CaptureAborted;
                    if (request_capture.isRequested()) continue;
                }
                if (config.exec_probe != null and !exec_probe_done) continue;
                if (config.network.failed()) continue;
                if (config.network.consumeWake()) {
                    const pager: ?*lazy_ram.Pager = if (lazy_pager) |*p| p else null;
                    try flushNetworkRxHvf(&net_dev, &transports_buf[net_transport_index], ram, pager, net_transport_index);
                    continue;
                }
                if (config.exec_control != null) continue;
                return error.VcpuCanceled;
            },
            else => {
                std.log.err("unhandled exit reason {}", .{exit.reason});
                return error.UnhandledExit;
            },
        }
    }
}

const hvf_vcpu_state_off: u8 = 0;
const hvf_vcpu_state_running: u8 = 1;

const HvfVcpuStartCommand = struct {
    entry: u64,
    arg0: u64,
};

const HvfVcpuGicReadCommand = struct {
    region: gic.Region,
    offset: u64,
    size_log2: u2,
};

const HvfVcpuGicWriteCommand = struct {
    region: gic.Region,
    offset: u64,
    value: u64,
};

const HvfVcpuCaptureCommand = struct {
    allocator: std.mem.Allocator,
    out: *spore.VcpuState,
};

const HvfVcpuApplyCommand = struct {
    state: spore.VcpuState,
};

const HvfVcpuCommand = union(enum) {
    start: HvfVcpuStartCommand,
    gic_read: HvfVcpuGicReadCommand,
    gic_write: HvfVcpuGicWriteCommand,
    capture: *HvfVcpuCaptureCommand,
    apply: *const HvfVcpuApplyCommand,
};

const HvfVcpuCommandResult = union(enum) {
    ok,
    value: u64,
    err: anyerror,
};

const HvfVcpuCommandSlot = struct {
    const State = enum { idle, pending, running, complete };

    lock: SpinLock = .{},
    state: State = .idle,
    command: HvfVcpuCommand = undefined,
    result: HvfVcpuCommandResult = .ok,

    fn submit(self: *HvfVcpuCommandSlot, target: *HvfVcpu, command: HvfVcpuCommand) !?u64 {
        while (true) {
            if (!target.ready.load(.acquire)) return error.VcpuCanceled;
            self.lock.lock();
            if (self.state == .idle) {
                self.command = command;
                self.result = .ok;
                self.state = .pending;
                self.lock.unlock();
                target.wake();
                break;
            }
            self.lock.unlock();
            sleepMs(1);
        }

        while (true) {
            if (!target.ready.load(.acquire)) return error.VcpuCanceled;
            self.lock.lock();
            if (self.state == .complete) {
                const result = self.result;
                self.state = .idle;
                self.lock.unlock();
                return switch (result) {
                    .ok => null,
                    .value => |value| value,
                    .err => |err| err,
                };
            }
            self.lock.unlock();
            sleepMs(1);
        }
    }

    fn take(self: *HvfVcpuCommandSlot) ?HvfVcpuCommand {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.state != .pending) return null;
        self.state = .running;
        return self.command;
    }

    fn finish(self: *HvfVcpuCommandSlot, result: HvfVcpuCommandResult) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.result = result;
        self.state = .complete;
    }
};

const HvfVcpu = struct {
    index: topology.VcpuIndex = 0,
    handle: hvf.VcpuHandle = 0,
    exit: *hvf.VcpuExit = undefined,
    redist_base: u64 = 0,
    created: bool = false,
    ready: std.atomic.Value(bool) = .init(false),
    creation_error: ?anyerror = null,
    thread: ?std.Thread = null,
    run_state: std.atomic.Value(u8) = .init(hvf_vcpu_state_off),
    snapshot_paused: std.atomic.Value(bool) = .init(false),
    command_slot: HvfVcpuCommandSlot = .{},

    fn initEmpty(self: *HvfVcpu, index: topology.VcpuIndex) void {
        self.* = .{ .index = index };
    }

    fn createOnOwnerThread(self: *HvfVcpu) !void {
        try hvf.check(hvf.hv_vcpu_create(&self.handle, &self.exit, null), "hv_vcpu_create");
        self.created = true;
        try hvf.check(hvf.hv_vcpu_set_sys_reg(self.handle, .mpidr_el1, topology.mpidrForIndex(self.index)), "set mpidr");
        try hvf.check(hvf.hv_gic_get_redistributor_base(self.handle, &self.redist_base), "gic redist base for vcpu");
    }

    fn destroyOnOwnerThread(self: *HvfVcpu) void {
        if (self.created) {
            _ = hvf.hv_vcpu_destroy(self.handle);
            self.created = false;
        }
        self.ready.store(false, .release);
    }

    fn setRunning(self: *HvfVcpu) void {
        self.run_state.store(hvf_vcpu_state_running, .release);
    }

    fn park(self: *HvfVcpu) void {
        self.run_state.store(hvf_vcpu_state_off, .release);
    }

    fn isRunning(self: *const HvfVcpu) bool {
        return self.run_state.load(.acquire) == hvf_vcpu_state_running;
    }

    fn startAt(self: *HvfVcpu, entry: u64, context_id: u64) !void {
        try hvf.check(hvf.hv_vcpu_set_reg(self.handle, .cpsr, 0x3c5), "psci set cpsr");
        try hvf.check(hvf.hv_vcpu_set_reg(self.handle, .pc, entry), "psci set pc");
        try hvf.check(hvf.hv_vcpu_set_reg(self.handle, .x0, context_id), "psci set x0");
        self.setRunning();
    }

    fn submit(self: *HvfVcpu, command: HvfVcpuCommand) !?u64 {
        return self.command_slot.submit(self, command);
    }

    fn wake(self: *const HvfVcpu) void {
        if (!self.ready.load(.acquire)) return;
        var handles = [_]hvf.VcpuHandle{self.handle};
        _ = hvf.hv_vcpus_exit(&handles, handles.len);
    }
};

const HvfRedistributorWindow = struct {
    base: u64,
    size: u64,
};

fn hvfRedistributorWindow(vcpus: []const HvfVcpu, stride: u64) !HvfRedistributorWindow {
    if (vcpus.len == 0 or stride == 0) return error.UnsupportedVcpuCount;
    var base = vcpus[0].redist_base;
    for (vcpus[1..]) |vcpu_entry| {
        base = @min(base, vcpu_entry.redist_base);
    }

    var max_frame: u64 = 0;
    for (vcpus, 0..) |vcpu_entry, i| {
        const rel = vcpu_entry.redist_base -| base;
        if (rel % stride != 0) {
            std.log.err("unsupported HVF GIC redistributor layout: vcpu={d} base=0x{x} min=0x{x} stride=0x{x}", .{ i, vcpu_entry.redist_base, base, stride });
            return error.UnsupportedVcpuCount;
        }
        const frame = rel / stride;
        for (vcpus[0..i]) |prev| {
            if (prev.redist_base == vcpu_entry.redist_base) {
                std.log.err("duplicate HVF GIC redistributor frame: vcpu={d} base=0x{x}", .{ i, vcpu_entry.redist_base });
                return error.UnsupportedVcpuCount;
            }
        }
        max_frame = @max(max_frame, frame);
    }
    const frame_count = std.math.add(u64, max_frame, 1) catch return error.UnsupportedVcpuCount;
    const size = std.math.mul(u64, frame_count, stride) catch return error.UnsupportedVcpuCount;
    return .{ .base = base, .size = size };
}

const HvfVcpuWakeSet = struct {
    vcpus: []const HvfVcpu,

    fn wakeAll(self: *HvfVcpuWakeSet) void {
        var handles: [topology.max_vcpus]hvf.VcpuHandle = undefined;
        var count: usize = 0;
        for (self.vcpus) |vcpu_entry| {
            if (!vcpu_entry.ready.load(.acquire)) continue;
            handles[count] = vcpu_entry.handle;
            count += 1;
        }
        if (count != 0) _ = hvf.hv_vcpus_exit(handles[0..count].ptr, @intCast(count));
    }
};

const MultiHvfResult = union(enum) {
    exit: ExitCause,
    err: anyerror,
};

const MultiHvfRunState = struct {
    mutex: SpinLock = .{},
    stop: std.atomic.Value(bool) = .init(false),
    snapshot_requested: std.atomic.Value(bool) = .init(false),
    result_value: ?MultiHvfResult = null,

    fn stopped(self: *MultiHvfRunState) bool {
        return self.stop.load(.acquire);
    }

    fn requestSnapshot(self: *MultiHvfRunState) void {
        self.snapshot_requested.store(true, .release);
    }

    fn snapshotRequested(self: *MultiHvfRunState) bool {
        return self.snapshot_requested.load(.acquire);
    }

    fn clearSnapshot(self: *MultiHvfRunState) void {
        self.snapshot_requested.store(false, .release);
    }

    fn finish(self: *MultiHvfRunState, new_result: MultiHvfResult) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.result_value == null) self.result_value = new_result;
        self.stop.store(true, .release);
    }

    fn result(self: *MultiHvfRunState) ?MultiHvfResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.result_value;
    }
};

const MultiHvfRunOptions = struct {
    config: *const Config,
    resume_manifest: ?*const spore.ManifestV1,
    restore_stats: *?RestoreStats,
    transports: []mmio.Transport,
    transports_buf: *[6]mmio.Transport,
    gen_dev: *generation.Device,
    ram: guestmem.GuestRam,
    ram_bytes: []align(std.heap.page_size_min) u8,
    ram_file_backed: bool,
    net_dev: *net.Net,
    vsock_dev: *vsock.Vsock,
    net_transport_index: usize,
    vsock_transport_index: usize,
    rootfs: ?spore.Rootfs,
    disk_snapshot: ?disk_layer.SnapshotState,
    network_manifest: ?spore.Network,
    annotations: spore.Annotations,
    environ_map: ?*const std.process.Environ.Map,
    dist_base: u64,
    dist_size: u64,
    redist_region_base: u64,
    redist_region_size: u64,
    setup_start: u64,
    hv_vm_create_ms: u64,
    gic_ms: u64,
    map_ram_ms: u64,
    hv_map_ram_ms: u64,
    devices_ms: u64,
};

const MultiHvfThreadContext = struct {
    vcpu: *HvfVcpu,
    vcpus: []HvfVcpu,
    wake_set: *HvfVcpuWakeSet,
    state: *MultiHvfRunState,
    device_lock: *SpinLock,
    network: net.Runtime,
    transports: []mmio.Transport,
    gen_dev: *generation.Device,
    ram: guestmem.GuestRam,
    net_dev: *net.Net,
    net_transport_index: usize,
    gic_windows: GicWindows,
};

fn runFreshMultiVcpu(allocator: std.mem.Allocator, options: MultiHvfRunOptions) !ExitCause {
    const vcpu_count: usize = @intCast(options.config.vcpus);
    var vcpus = try allocator.alloc(HvfVcpu, vcpu_count);
    defer allocator.free(vcpus);
    for (vcpus, 0..) |*vcpu, index| vcpu.initEmpty(@intCast(index));

    var state = MultiHvfRunState{};
    var device_lock = SpinLock{};
    var exec_probe_done = false;
    var wake_set = HvfVcpuWakeSet{ .vcpus = vcpus };
    options.config.network.setWake(.{ .context = &wake_set, .wakeFn = wakeNetworkVcpuSet });
    defer options.config.network.clearWake();
    if (options.config.exec_control) |control| {
        control.setWake(.{ .context = &wake_set, .wakeFn = wakeVcpuSet });
    }
    if (options.config.capture_request) |request_capture| {
        request_capture.setWake(wakeCaptureVcpuSet, &wake_set);
    }
    defer if (options.config.capture_request) |request_capture| request_capture.clearWake();

    const contexts = try allocator.alloc(MultiHvfThreadContext, vcpus.len);
    defer allocator.free(contexts);
    defer joinHvfVcpuThreads(vcpus, &wake_set);
    errdefer {
        state.finish(.{ .err = error.HvfThreadStartFailed });
        wake_set.wakeAll();
    }

    for (vcpus, contexts) |*vcpu_entry, *ctx| {
        ctx.* = .{
            .vcpu = vcpu_entry,
            .vcpus = vcpus,
            .wake_set = &wake_set,
            .state = &state,
            .device_lock = &device_lock,
            .network = options.config.network,
            .transports = options.transports,
            .gen_dev = options.gen_dev,
            .ram = options.ram,
            .net_dev = options.net_dev,
            .net_transport_index = options.net_transport_index,
            .gic_windows = .{
                .dist_base = options.dist_base,
                .dist_size = options.dist_size,
                .redist_base = 0,
                .redist_size = 0,
            },
        };
        vcpu_entry.thread = try std.Thread.spawn(.{}, hvfVcpuThreadMain, .{ctx});
    }

    try waitHvfVcpusReady(vcpus, &state);

    const vcpu_start = monotonicMs();
    var redist_stride: usize = 0;
    try hvf.check(hvf.hv_gic_get_redistributor_size(&redist_stride), "gic redist stride");
    const redist_window = try hvfRedistributorWindow(vcpus, @intCast(redist_stride));
    if (redist_window.size > options.redist_region_size) return error.UnsupportedVcpuCount;
    const vcpu_ms = monotonicMs() - vcpu_start;
    const gic_windows = GicWindows{
        .dist_base = options.dist_base,
        .dist_size = options.dist_size,
        .redist_base = redist_window.base,
        .redist_size = redist_window.size,
        .redist_stride = @intCast(redist_stride),
        .redist_vcpus = vcpus,
    };
    for (contexts) |*ctx| ctx.gic_windows = gic_windows;
    std.log.debug(
        "gic: dist=0x{x}+0x{x} redist=0x{x}+0x{x} stride=0x{x} count={d} (region 0x{x}+0x{x})",
        .{ options.dist_base, options.dist_size, redist_window.base, redist_window.size, redist_stride, vcpus.len, options.redist_region_base, options.redist_region_size },
    );

    var boot_ms: u64 = 0;
    if (options.resume_manifest) |manifest| {
        const restore_start = monotonicMs();
        try checkHvfManifestV1(manifest.*, options.config.*, options.transports.len, snapshot.hostCounterFreq(), options.dist_base, redist_window.base, @intCast(redist_stride));
        try restoreMemory(allocator, options.config.*, manifest.memory, options.ram_bytes, options.ram_file_backed, null, options.restore_stats);
        const state_start = monotonicMs();
        try applyTransports(options.transports, manifest.devices);
        try options.gen_dev.restore(allocator, options.config.resume_generation orelse manifest.generation);
        if (options.config.resume_generation == null) try spore.refreshResumeParams(allocator, options.gen_dev);
        try snapshot.applyGicState(allocator, vcpus[0].handle, manifest.machine.gic);
        try applyHvfVcpuStates(vcpus, manifest.machine);
        for (vcpus) |*vcpu| vcpu.setRunning();
        try raiseGenerationIrqIfPending(options.gen_dev);
        if (options.restore_stats.*) |*stats| stats.state_ms = monotonicMs() - state_start;
        boot_ms = monotonicMs() - restore_start;
    } else {
        const boot_start = monotonicMs();
        const initrd_range = if (options.config.initrd) |initrd| try boot.planInitrd(options.ram.bytes.len, board.ram_base, options.config.kernel, initrd.len) else null;
        const dtb = try board.buildDtb(allocator, .{
            .ram_size = options.config.ram_size,
            .cpu_count = options.config.vcpus,
            .gic = .{
                .distributor_base = options.dist_base,
                .distributor_size = options.dist_size,
                .redistributor_base = redist_window.base,
                .redistributor_size = redist_window.size,
            },
            .virtio_count = @intCast(options.transports.len),
            .bootargs = options.config.cmdline,
            .initrd = if (initrd_range) |r| .{ .start = r.start, .end = r.end } else null,
        });
        defer allocator.free(dtb);
        const layout = try boot.load(options.ram.bytes, board.ram_base, options.config.kernel, options.config.initrd, dtb);
        _ = try vcpus[0].submit(.{ .start = .{ .entry = layout.entry, .arg0 = layout.dtb } });
        boot_ms = monotonicMs() - boot_start;
    }

    var attach_probe_ms: u64 = 0;
    if (options.config.exec_probe) |probe| {
        const attach_probe_start = monotonicMs();
        try options.vsock_dev.attachHostStream(probe);
        probe.markStarted();
        try flushVsockRx(options.vsock_dev, &options.transports_buf[options.vsock_transport_index], options.ram, null, @intCast(options.vsock_transport_index));
        attach_probe_ms = monotonicMs() - attach_probe_start;
    }
    const start_ms = monotonicMs();
    std.log.debug(
        "hvf cold setup timing: total_ms={d} hv_vm_create_ms={d} gic_ms={d} mmap_ram_ms={d} hv_map_ram_ms={d} devices_ms={d} vcpu_ms={d} boot_ms={d} attach_probe_ms={d} ram_mib={d}",
        .{
            start_ms - options.setup_start,
            options.hv_vm_create_ms,
            options.gic_ms,
            options.map_ram_ms,
            options.hv_map_ram_ms,
            options.devices_ms,
            vcpu_ms,
            boot_ms,
            attach_probe_ms,
            options.config.ram_size / 1024 / 1024,
        },
    );

    while (true) {
        if (state.result()) |result| {
            wake_set.wakeAll();
            return finishMultiHvfResult(result);
        }
        if (options.config.network.failed()) {
            state.finish(.{ .err = error.NetworkGatewayFailed });
            continue;
        }
        if (options.config.exec_control) |control| {
            control.reportStats(monitorStatsFromDirtyTracker(null));
            device_lock.lock();
            const action = control.poll(options.vsock_dev) catch |err| {
                device_lock.unlock();
                state.finish(.{ .err = err });
                continue;
            };
            switch (action) {
                .keep_running => flushVsockRx(
                    options.vsock_dev,
                    &options.transports_buf[options.vsock_transport_index],
                    options.ram,
                    null,
                    @intCast(options.vsock_transport_index),
                ) catch |err| {
                    device_lock.unlock();
                    state.finish(.{ .err = err });
                    continue;
                },
                else => {},
            }
            device_lock.unlock();
            switch (action) {
                .keep_running => {},
                .stop => {
                    state.finish(.{ .exit = .monitor_stopped });
                    continue;
                },
                .snapshot => |request| {
                    if (request.continue_after) {
                        takeSnapshotV1(
                            allocator,
                            request.dir,
                            vcpus,
                            &state,
                            &wake_set,
                            options.transports,
                            options.gen_dev,
                            options.vsock_dev,
                            options.ram_bytes,
                            .{ .dist_base = options.dist_base, .redist_base = redist_window.base, .redist_stride = @intCast(redist_stride), .ram_size = options.config.ram_size },
                            options.rootfs,
                            options.disk_snapshot,
                            options.network_manifest,
                            options.annotations,
                            options.config.sessions,
                            options.environ_map,
                        ) catch |err| {
                            state.clearSnapshot();
                            state.finish(.{ .err = err });
                            continue;
                        };
                        state.clearSnapshot();
                        control.completeSnapshot(request.dir) catch |err| {
                            state.finish(.{ .err = err });
                            continue;
                        };
                        continue;
                    }
                    return snapshotMultiHvfAndStop(allocator, options, vcpus, &state, &wake_set, redist_window.base, @intCast(redist_stride), request.dir, null);
                },
            }
        }
        if (options.config.exec_probe) |probe| {
            if (!exec_probe_done) {
                if (probe.state == .failed) {
                    if (options.config.exec_probe_failure_fatal) {
                        state.finish(.{ .err = error.VsockProbeFailed });
                        continue;
                    }
                    exec_probe_done = true;
                }
                if (probe.state == .complete) {
                    std.log.debug("hvf multi-vcpu probe completion timing: observed_ms={d}", .{probe.elapsedMs()});
                    if (options.config.exec_probe_completes_run) {
                        if (options.config.snapshot_on_probe_complete) {
                            return snapshotMultiHvfAndStop(allocator, options, vcpus, &state, &wake_set, redist_window.base, @intCast(redist_stride), null, null);
                        }
                        state.finish(.{ .exit = .probe_complete });
                        continue;
                    }
                    exec_probe_done = true;
                }
                if (!exec_probe_done and probe.elapsedMs() > options.config.exec_probe_timeout_ms) {
                    if (options.config.exec_probe_failure_fatal) {
                        state.finish(.{ .err = error.VsockProbeTimedOut });
                        continue;
                    }
                    exec_probe_done = true;
                }
            }
        }
        if (options.config.capture_request) |request_capture| {
            if (request_capture.isAbortRequested()) {
                state.finish(.{ .err = error.CaptureAborted });
                continue;
            }
            if (request_capture.isRequested()) {
                return snapshotMultiHvfAndStop(allocator, options, vcpus, &state, &wake_set, redist_window.base, @intCast(redist_stride), null, request_capture);
            }
        }
        if (options.config.snapshot_after_ms) |after_ms| {
            if (monotonicMs() -| start_ms >= after_ms) {
                return snapshotMultiHvfAndStop(allocator, options, vcpus, &state, &wake_set, redist_window.base, @intCast(redist_stride), null, null);
            }
        }
        sleepMs(1);
    }
}

fn finishMultiHvfResult(result: MultiHvfResult) !ExitCause {
    return switch (result) {
        .exit => |cause| cause,
        .err => |err| err,
    };
}

fn snapshotMultiHvfAndStop(
    allocator: std.mem.Allocator,
    options: MultiHvfRunOptions,
    vcpus: []HvfVcpu,
    state: *MultiHvfRunState,
    wake_set: *HvfVcpuWakeSet,
    redist_base: u64,
    redist_stride: u64,
    snapshot_dir_override: ?[]const u8,
    request_capture: ?*capture.Request,
) !ExitCause {
    const snapshot_dir = snapshot_dir_override orelse options.config.snapshot_dir orelse {
        state.finish(.{ .err = error.HvCallFailed });
        return error.HvCallFailed;
    };
    takeSnapshotV1(
        allocator,
        snapshot_dir,
        vcpus,
        state,
        wake_set,
        options.transports,
        options.gen_dev,
        options.vsock_dev,
        options.ram_bytes,
        .{ .dist_base = options.dist_base, .redist_base = redist_base, .redist_stride = redist_stride, .ram_size = options.config.ram_size },
        options.rootfs,
        options.disk_snapshot,
        options.network_manifest,
        options.annotations,
        options.config.sessions,
        options.environ_map,
    ) catch |err| {
        if (state.result()) |result| return finishMultiHvfResult(result);
        state.finish(.{ .err = err });
        return err;
    };
    if (request_capture) |request| {
        request.markCompleted();
        if (request.isAbortRequested()) {
            state.finish(.{ .err = error.CaptureAborted });
            return error.CaptureAborted;
        }
    }
    state.finish(.{ .exit = .snapshotted });
    return .snapshotted;
}

fn waitHvfVcpusReady(vcpus: []HvfVcpu, state: *MultiHvfRunState) !void {
    while (true) {
        if (state.result()) |result| switch (result) {
            .err => |err| return err,
            .exit => return error.UnexpectedExit,
        };
        var ready_count: usize = 0;
        for (vcpus) |*vcpu| {
            if (!vcpu.ready.load(.acquire)) break;
            if (vcpu.creation_error) |err| return err;
            ready_count += 1;
        }
        if (ready_count == vcpus.len) return;
        sleepMs(1);
    }
}

fn joinHvfVcpuThreads(vcpus: []HvfVcpu, wake_set: *HvfVcpuWakeSet) void {
    wake_set.wakeAll();
    for (vcpus) |*vcpu_entry| {
        if (vcpu_entry.thread) |thread| {
            thread.join();
            vcpu_entry.thread = null;
        }
    }
}

fn pauseHvfVcpusForSnapshot(vcpus: []HvfVcpu, state: *MultiHvfRunState, wake_set: *HvfVcpuWakeSet) !void {
    for (vcpus) |*vcpu| vcpu.snapshot_paused.store(false, .release);
    state.requestSnapshot();
    wake_set.wakeAll();
    while (true) {
        if (state.result() != null) return error.CaptureAborted;
        var paused_count: usize = 0;
        for (vcpus) |*vcpu| {
            if (!vcpu.snapshot_paused.load(.acquire)) break;
            paused_count += 1;
        }
        if (paused_count == vcpus.len) return;
        sleepMs(1);
    }
}

fn captureHvfVcpuStates(allocator: std.mem.Allocator, vcpus: []HvfVcpu) ![]spore.VcpuState {
    const states = try allocator.alloc(spore.VcpuState, vcpus.len);
    for (vcpus, states) |*vcpu, *out| {
        var command = HvfVcpuCaptureCommand{ .allocator = allocator, .out = out };
        _ = try vcpu.submit(.{ .capture = &command });
    }
    return states;
}

fn applyHvfVcpuStates(vcpus: []HvfVcpu, machine: spore.MachineStateV1) !void {
    if (machine.vcpus.len != vcpus.len) return error.PlatformMismatch;
    for (machine.vcpus, 0..) |vcpu_state, i| {
        if (vcpu_state.index != vcpus[i].index) return error.PlatformMismatch;
        var command = HvfVcpuApplyCommand{ .state = vcpu_state };
        _ = try vcpus[i].submit(.{ .apply = &command });
    }
}

const MultiHvfPsciAction = union(enum) {
    none,
    exit: ExitCause,
    park_current,
};

const MultiHvfPsciContext = struct {
    current: *HvfVcpu,
    vcpus: []HvfVcpu,
    wake_set: *HvfVcpuWakeSet,
};

fn hvfVcpuThreadMain(ctx: *MultiHvfThreadContext) void {
    ctx.vcpu.createOnOwnerThread() catch |err| {
        ctx.vcpu.creation_error = err;
        ctx.vcpu.ready.store(true, .release);
        ctx.state.finish(.{ .err = err });
        return;
    };
    ctx.vcpu.ready.store(true, .release);
    defer ctx.vcpu.destroyOnOwnerThread();

    while (!ctx.state.stopped()) {
        if (ctx.vcpu.command_slot.take()) |command| {
            processHvfVcpuCommand(ctx.vcpu, command);
            continue;
        }
        if (ctx.state.snapshotRequested()) {
            ctx.vcpu.snapshot_paused.store(true, .release);
            sleepMs(1);
            continue;
        }
        ctx.vcpu.snapshot_paused.store(false, .release);
        if (!ctx.vcpu.isRunning()) {
            sleepMs(1);
            continue;
        }
        hvf.check(hvf.hv_vcpu_run(ctx.vcpu.handle), "hv_vcpu_run") catch |err| {
            ctx.state.finish(.{ .err = err });
            return;
        };
        if (ctx.state.stopped()) continue;

        if (ctx.network.failed()) {
            ctx.state.finish(.{ .err = error.NetworkGatewayFailed });
            continue;
        }
        var flushed_network = false;
        ctx.device_lock.lock();
        if (ctx.network.consumeWake()) {
            flushNetworkRxHvf(ctx.net_dev, &ctx.transports[ctx.net_transport_index], ctx.ram, null, ctx.net_transport_index) catch |err| {
                ctx.device_lock.unlock();
                ctx.state.finish(.{ .err = err });
                return;
            };
            flushed_network = true;
        }
        ctx.device_lock.unlock();
        if (flushed_network) continue;

        switch (ctx.vcpu.exit.reason) {
            .exception => {
                const ec = ctx.vcpu.exit.exception.exceptionClass();
                switch (ec) {
                    hvf.ec_instruction_abort => {
                        std.log.err(
                            "unhandled instruction abort on vcpu {d}: syndrome=0x{x} va=0x{x} ipa=0x{x}",
                            .{ ctx.vcpu.index, ctx.vcpu.exit.exception.syndrome, ctx.vcpu.exit.exception.virtual_address, ctx.vcpu.exit.exception.physical_address },
                        );
                        ctx.state.finish(.{ .err = error.UnhandledGuestException });
                    },
                    hvf.ec_data_abort => {
                        ctx.device_lock.lock();
                        handleMmio(ctx.vcpu.handle, ctx.vcpu.exit, ctx.transports, ctx.gen_dev, ctx.ram, null, ctx.gic_windows, ctx.vcpu) catch |err| {
                            ctx.device_lock.unlock();
                            ctx.state.finish(.{ .err = err });
                            return;
                        };
                        ctx.device_lock.unlock();
                    },
                    hvf.ec_hvc => {
                        var psci_context = MultiHvfPsciContext{
                            .current = ctx.vcpu,
                            .vcpus = ctx.vcpus,
                            .wake_set = ctx.wake_set,
                        };
                        const action = handlePsciMulti(&psci_context) catch |err| {
                            ctx.state.finish(.{ .err = err });
                            return;
                        };
                        applyMultiHvfPsciAction(ctx, action);
                    },
                    hvf.ec_smc => {
                        var psci_context = MultiHvfPsciContext{
                            .current = ctx.vcpu,
                            .vcpus = ctx.vcpus,
                            .wake_set = ctx.wake_set,
                        };
                        const action = handlePsciMulti(&psci_context) catch |err| {
                            ctx.state.finish(.{ .err = err });
                            return;
                        };
                        advancePc(ctx.vcpu.handle) catch |err| {
                            ctx.state.finish(.{ .err = err });
                            return;
                        };
                        applyMultiHvfPsciAction(ctx, action);
                    },
                    ec_wfx => {
                        advancePc(ctx.vcpu.handle) catch |err| {
                            ctx.state.finish(.{ .err = err });
                            return;
                        };
                        sleepMs(1);
                    },
                    ec_sysreg => {
                        handleUnknownSysreg(ctx.vcpu.handle, ctx.vcpu.exit) catch |err| {
                            ctx.state.finish(.{ .err = err });
                            return;
                        };
                    },
                    else => {
                        std.log.err(
                            "unhandled exception class 0x{x} on vcpu {d}: syndrome=0x{x} va=0x{x} ipa=0x{x}",
                            .{ ec, ctx.vcpu.index, ctx.vcpu.exit.exception.syndrome, ctx.vcpu.exit.exception.virtual_address, ctx.vcpu.exit.exception.physical_address },
                        );
                        ctx.state.finish(.{ .err = error.UnhandledGuestException });
                    },
                }
            },
            .vtimer_activated => {
                hvf.check(hvf.hv_vcpu_set_vtimer_mask(ctx.vcpu.handle, false), "vtimer unmask") catch |err| {
                    ctx.state.finish(.{ .err = err });
                    return;
                };
            },
            .canceled => continue,
            else => {
                std.log.err("unhandled HVF exit reason {} on vcpu {d}", .{ ctx.vcpu.exit.reason, ctx.vcpu.index });
                ctx.state.finish(.{ .err = error.UnhandledExit });
            },
        }
    }
}

fn processHvfVcpuCommand(vcpu: *HvfVcpu, command: HvfVcpuCommand) void {
    const result: HvfVcpuCommandResult = switch (command) {
        .start => |start| blk: {
            vcpu.startAt(start.entry, start.arg0) catch |err| break :blk .{ .err = err };
            break :blk .ok;
        },
        .gic_read => |read| .{ .value = gic.mmioRead(read.region, vcpu.handle, read.offset, read.size_log2) },
        .gic_write => |write| blk: {
            gic.mmioWrite(write.region, vcpu.handle, write.offset, write.value);
            break :blk .ok;
        },
        .capture => |capture_cmd| blk: {
            capture_cmd.out.* = snapshot.captureVcpuState(capture_cmd.allocator, .{ .index = vcpu.index, .handle = vcpu.handle }) catch |err| break :blk .{ .err = err };
            break :blk .ok;
        },
        .apply => |apply_cmd| blk: {
            snapshot.applyVcpuState(vcpu.handle, apply_cmd.state) catch |err| break :blk .{ .err = err };
            break :blk .ok;
        },
    };
    vcpu.command_slot.finish(result);
}

fn applyMultiHvfPsciAction(ctx: *MultiHvfThreadContext, action: MultiHvfPsciAction) void {
    switch (action) {
        .none => {},
        .exit => |cause| ctx.state.finish(.{ .exit = cause }),
        .park_current => {},
    }
}

fn handlePsciMulti(ctx: *MultiHvfPsciContext) !MultiHvfPsciAction {
    var x0: u64 = undefined;
    try hvf.check(hvf.hv_vcpu_get_reg(ctx.current.handle, .x0, &x0), "psci get x0");
    const fid: u32 = @truncate(x0);
    const ret: u64 = switch (fid) {
        psci_version => 0x0001_0001,
        psci_migrate_info_type => 2,
        psci_system_off => return .{ .exit = .guest_off },
        psci_system_reset => return .{ .exit = .guest_reset },
        psci_features => blk: {
            var x1: u64 = undefined;
            try hvf.check(hvf.hv_vcpu_get_reg(ctx.current.handle, .x1, &x1), "psci get x1");
            const queried: u32 = @truncate(x1);
            break :blk switch (queried) {
                psci_version, psci_cpu_off, psci_cpu_on_32, psci_cpu_on_64, psci_system_off, psci_system_reset, psci_features => 0,
                else => psci_ret_not_supported,
            };
        },
        psci_cpu_off => {
            ctx.current.park();
            return .park_current;
        },
        psci_cpu_on_32, psci_cpu_on_64 => blk: {
            var target_mpidr: u64 = undefined;
            var entry: u64 = undefined;
            var context_id: u64 = undefined;
            try hvf.check(hvf.hv_vcpu_get_reg(ctx.current.handle, .x1, &target_mpidr), "psci get target");
            try hvf.check(hvf.hv_vcpu_get_reg(ctx.current.handle, .x2, &entry), "psci get entry");
            try hvf.check(hvf.hv_vcpu_get_reg(ctx.current.handle, .x3, &context_id), "psci get context");
            break :blk try psciCpuOn(ctx, target_mpidr, entry, context_id);
        },
        else => psci_ret_not_supported,
    };
    try hvf.check(hvf.hv_vcpu_set_reg(ctx.current.handle, .x0, ret), "psci set x0");
    return .none;
}

fn psciCpuOn(ctx: *MultiHvfPsciContext, target_mpidr: u64, entry: u64, context_id: u64) !u64 {
    const target_index = psciTargetIndex(ctx.vcpus.len, target_mpidr) orelse return psci_ret_invalid_params;
    const target = &ctx.vcpus[target_index];
    if (target.isRunning()) return psci_ret_already_on;
    _ = try target.submit(.{ .start = .{ .entry = entry, .arg0 = context_id } });
    ctx.wake_set.wakeAll();
    return 0;
}

fn psciTargetIndex(vcpu_count: usize, target_mpidr: u64) ?usize {
    if (((target_mpidr >> 32) & 0xff) != 0) return null;
    const affinity = target_mpidr & 0x00ff_ffff;
    if (affinity >= vcpu_count) return null;
    return @intCast(affinity);
}

fn handleUnknownSysreg(vcpu: hvf.VcpuHandle, exit: *hvf.VcpuExit) !void {
    const iss: u32 = @truncate(exit.exception.syndrome & 0x1ff_ffff);
    if (iss & 1 != 0) {
        const rt: hvf.Reg = @enumFromInt(@as(u32, @truncate((iss >> 5) & 0x1f)));
        if (@intFromEnum(rt) < 31) {
            try hvf.check(hvf.hv_vcpu_set_reg(vcpu, rt, 0), "sysreg raz");
        }
    }
    try advancePc(vcpu);
}

fn monotonicMs() u64 {
    const freq = snapshot.hostCounterFreq();
    if (freq == 0) return 0;
    return snapshot.hostCounter() * std.time.ms_per_s / freq;
}

fn sleepMs(ms: u64) void {
    var ts = std.c.timespec{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast((ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);
}

fn wakeCaptureVcpu(context: ?*anyopaque) callconv(.c) void {
    const vcpu_ptr: *hvf.VcpuHandle = @ptrCast(@alignCast(context orelse return));
    var vcpus = [_]hvf.VcpuHandle{vcpu_ptr.*};
    _ = hvf.hv_vcpus_exit(&vcpus, vcpus.len);
}

fn wakeCaptureVcpuSet(context: ?*anyopaque) callconv(.c) void {
    const wake_set: *HvfVcpuWakeSet = @ptrCast(@alignCast(context orelse return));
    wake_set.wakeAll();
}

fn shouldMapRamAtStart(config: Config, ram_mapping: RamMapping) bool {
    if (config.resume_dir == null) return true;
    if (ram_mapping.file_backed) return true;
    return config.ram_restore_mode != .lazy_chunks;
}

fn mapRam(config: Config, manifest_memory: ?spore.MemoryManifest) !RamMapping {
    if (config.ram_backing_fd) |fd| {
        const memory = manifest_memory orelse return error.BadManifest;
        const backing = memory.backing orelse return error.BadManifest;
        try spore.validateMemoryBacking(backing, config.ram_size);
        return mapFileBackedRamFd(fd, config.ram_size);
    }
    return mapAnonymousRam(config.ram_size);
}

fn restoreMemory(
    allocator: std.mem.Allocator,
    config: Config,
    memory: spore.MemoryManifest,
    ram_bytes: []align(std.heap.page_size_min) u8,
    file_backed: bool,
    lazy_pager: ?*?lazy_ram.Pager,
    restore_stats: *?RestoreStats,
) !void {
    const memory_plan = try spore.validateMemoryForRam(memory, ram_bytes.len);
    if (restore_stats.*) |*stats| {
        stats.chunk_count = memory_plan.chunk_count;
        stats.nonzero_chunk_count = memory_plan.nonzero_chunk_count;
    }
    if (file_backed) {
        if (restore_stats.*) |*stats| stats.mode = "local_backing";
        return;
    }
    switch (config.ram_restore_mode) {
        .eager_chunks => {
            if (restore_stats.*) |*stats| stats.mode = "eager_chunks";
            const memory_start = monotonicMs();
            try spore.loadMemory(allocator, config.resume_dir.?, memory, ram_bytes);
            if (restore_stats.*) |*stats| stats.memory_ms = monotonicMs() - memory_start;
        },
        .lazy_chunks => {
            const pager_slot = lazy_pager orelse return error.UnsupportedVcpuCount;
            if (restore_stats.*) |*stats| stats.mode = "lazy_chunks";
            const memory_start = monotonicMs();
            pager_slot.* = try lazy_ram.Pager.start(allocator, .{
                .dir = config.resume_dir.?,
                .manifest = memory,
                .ram = ram_bytes,
                .trace_fd = config.lazy_ram_trace_fd,
            });
            if (restore_stats.*) |*stats| stats.memory_ms = monotonicMs() - memory_start;
        },
    }
}

fn checkHvfManifestV1(manifest: spore.ManifestV1, config: Config, device_count: usize, host_counter_frequency_hz: u64, dist_base: u64, redist_base: u64, redist_stride: u64) !void {
    if (manifest.version != spore.format_version_v1) return error.PlatformMismatch;
    if (!std.mem.eql(u8, manifest.platform.arch, platform_contract.arch)) return error.PlatformMismatch;
    if (!std.mem.eql(u8, manifest.platform.cpu_profile, board.cpu_profile)) return error.PlatformMismatch;
    if (manifest.platform.device_model_version != board.device_model_version) return error.PlatformMismatch;
    if (manifest.platform.vcpu_count != config.vcpus) return error.PlatformMismatch;
    if (manifest.platform.ram_base != board.ram_base) return error.PlatformMismatch;
    if (manifest.platform.ram_size != config.ram_size) return error.PlatformMismatch;
    if (manifest.platform.gic_dist_base != dist_base) return error.PlatformMismatch;
    if (manifest.platform.gic_redist_base != redist_base) return error.PlatformMismatch;
    if (manifest.platform.gic_redist_stride != redist_stride) return error.PlatformMismatch;
    if (manifest.platform.counter_frequency_hz != host_counter_frequency_hz) return error.PlatformMismatch;
    if (manifest.devices.len != device_count) return error.PlatformMismatch;
    if (manifest.machine.gic.kind != .backend_private) return error.PlatformMismatch;
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

const DirtyTracker = struct {
    sealer: dirty_ram.Sealer,
    writable_chunks: []bool,
    core: dirty_ram.TrackerCore,
    mutex: SpinLock = .{},
    stats: DirtyStats = .{},

    const Options = struct {
        dir: []const u8,
        ram: []const u8,
        seed_ranges: ?[]const dirty_ram.ChunkRange = null,
        epoch_ms: u64,
    };

    const DirtyStats = struct {
        write_fault_count: u64 = 0,
        seed_protect_ms: u64 = 0,
        protect_ms: u64 = 0,
    };

    fn start(allocator: std.mem.Allocator, options: Options) !DirtyTracker {
        if (options.ram.len == 0) return error.BadManifest;
        if (options.ram.len % std.heap.page_size_min != 0) return error.BadManifest;
        if (spore.chunk_size % std.heap.page_size_min != 0) return error.BadManifest;

        var sealer = try dirty_ram.Sealer.start(allocator, .{
            .dir = options.dir,
            .ram = options.ram,
            .seed_ranges = options.seed_ranges,
        });
        errdefer sealer.deinit();

        var tracker = DirtyTracker{
            .sealer = sealer,
            .writable_chunks = try allocator.alloc(bool, sealer.chunkCount()),
            .core = dirty_ram.TrackerCore.init(options.epoch_ms),
        };
        @memset(tracker.writable_chunks, false);

        const protect_start = monotonicMs();
        try tracker.protectAll(hvf.MemoryFlags.rx);
        tracker.stats.seed_protect_ms = monotonicMs() - protect_start;
        tracker.core.tracking_start_ms = monotonicMs();

        std.log.info(
            "hvf dirty tracking started: mode=write-protect ram_mib={d} chunks={d} seed_nonzero_chunks={d} seed_ms={d} seed_protect_ms={d} epoch_ms={d}",
            .{ options.ram.len / 1024 / 1024, tracker.sealer.chunkCount(), tracker.sealer.stats.seed_nonzero_chunks, tracker.sealer.stats.seed_ms, tracker.stats.seed_protect_ms, options.epoch_ms },
        );
        return tracker;
    }

    fn deinit(self: *DirtyTracker) void {
        self.stopWorker();
        if (!self.sealer.finished) {
            _ = self.protectAll(hvf.MemoryFlags.rwx) catch {};
        }
        self.sealer.deinit();
    }

    fn startWorker(self: *DirtyTracker) !void {
        if (!self.core.shouldStartWorker()) return;
        self.core.worker_thread = try std.Thread.spawn(.{}, dirtyWorker, .{self});
        std.log.info("hvf dirty tracking worker started: epoch_ms={d}", .{self.core.epoch_ms});
    }

    fn stopWorker(self: *DirtyTracker) void {
        if (self.core.worker_thread) |thread| {
            const join_start = monotonicMs();
            self.core.stop.store(true, .release);
            thread.join();
            self.core.worker_thread = null;
            self.core.stats.worker_join_ms += monotonicMs() - join_start;
        }
    }

    fn dirtyWorker(self: *DirtyTracker) void {
        var next_deadline = monotonicMs() +| self.core.epoch_ms;
        while (true) {
            const now = monotonicMs();
            const wait_ms = if (next_deadline > now) next_deadline - now else 0;
            if (self.waitForStop(wait_ms)) return;
            const epoch_start = monotonicMs();
            self.flushDirty(false) catch {
                self.markWorkerFailed();
                return;
            };
            const epoch_end = monotonicMs();
            self.recordWorkerEpochTiming(epoch_start, epoch_end, next_deadline);
            next_deadline = epoch_start +| self.core.epoch_ms;
        }
    }

    fn waitForStop(self: *DirtyTracker, wait_ms: u64) bool {
        var slept_ms: u64 = 0;
        while (slept_ms < wait_ms) {
            if (self.core.stop.load(.acquire)) return true;
            const remaining = wait_ms - slept_ms;
            const slice_ms = @min(remaining, 10);
            sleepMs(slice_ms);
            slept_ms += slice_ms;
        }
        return self.core.stop.load(.acquire);
    }

    fn markWorkerFailed(self: *DirtyTracker) void {
        self.mutex.lock();
        self.core.markWorkerFailed();
        self.mutex.unlock();
    }

    fn recordWorkerEpochTiming(self: *DirtyTracker, epoch_start: u64, epoch_end: u64, deadline_ms: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.core.recordWorkerEpochTiming(epoch_start, epoch_end, deadline_ms);
    }

    fn handleWriteFault(self: *DirtyTracker, syndrome: u64, ipa: u64) !bool {
        const is_write = syndrome & (1 << 6) != 0;
        if (!is_write) return false;
        if (ipa < board.ram_base) return false;
        const guest_offset = ipa - board.ram_base;
        if (guest_offset >= self.sealer.ram.len) return false;
        const chunk_index: usize = @intCast(guest_offset / spore.chunk_size);

        self.mutex.lock();
        defer self.mutex.unlock();
        self.stats.write_fault_count += 1;
        self.sealer.markCollectedChunkDirty(chunk_index);
        if (!self.writable_chunks[chunk_index]) {
            const protect_start = monotonicMs();
            try self.protectChunk(chunk_index, hvf.MemoryFlags.rwx);
            self.stats.protect_ms += monotonicMs() - protect_start;
            self.writable_chunks[chunk_index] = true;
        }
        return true;
    }

    fn finish(self: *DirtyTracker) !spore.MemoryManifest {
        const worker_stop_start = monotonicMs();
        self.stopWorker();
        self.core.stats.finish_worker_stop_ms = monotonicMs() - worker_stop_start;
        if (self.core.worker_failed) return error.HvfDirtyWorkerFailed;

        const tail_start = monotonicMs();
        try self.flushDirty(true);
        self.sealer.stats.tail_flush_ms = monotonicMs() - tail_start;
        self.sealer.finishRates(self.core.tracking_start_ms, monotonicMs());

        // Successful dirty-tracked snapshots are one-shot captures. Re-protecting
        // every chunk here makes suspend scale with configured RAM even when the
        // dirty tail is empty; unfinished teardown still restores permissions.
        return try self.sealer.finishBacking();
    }

    fn flushDirty(self: *DirtyTracker, tail: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.sealer.hasDirtyChunks()) return;
        _ = try self.sealer.flushMarked(.{
            .tail = tail,
            .stop = &self.core.stop,
            .before_seal = protectDirtyChunkForSeal,
            .before_seal_ctx = self,
        });
        if (!tail) self.core.stats.dirty_epoch_count += 1;
    }

    fn protectDirtyChunkForSeal(ctx: *anyopaque, index: usize) !void {
        const self: *DirtyTracker = @ptrCast(@alignCast(ctx));
        if (self.writable_chunks[index]) {
            const protect_start = monotonicMs();
            try self.protectChunk(index, hvf.MemoryFlags.rx);
            self.stats.protect_ms += monotonicMs() - protect_start;
            self.writable_chunks[index] = false;
        }
    }

    fn markGuestWriteCallback(ctx: *anyopaque, gpa: u64, len: u64) void {
        const self: *DirtyTracker = @ptrCast(@alignCast(ctx));
        self.markGuestWrite(gpa, len);
    }

    fn markGuestWrite(self: *DirtyTracker, gpa: u64, len: u64) void {
        if (len == 0) return;
        if (gpa < board.ram_base) return;
        const guest_offset = gpa - board.ram_base;
        if (guest_offset >= self.sealer.ram.len) return;
        const start_offset: usize = @intCast(guest_offset);
        const remaining: u64 = @intCast(self.sealer.ram.len - start_offset);
        const capped_len: usize = @intCast(@min(len, remaining));
        if (capped_len == 0) return;

        self.mutex.lock();
        defer self.mutex.unlock();
        self.sealer.markHostDirtyRange(start_offset, capped_len);
    }

    fn protectAll(self: *DirtyTracker, flags: hvf.MemoryFlags) !void {
        var i: usize = 0;
        while (i < self.sealer.chunkCount()) : (i += 1) {
            try self.protectChunk(i, flags);
            self.writable_chunks[i] = flags.write;
        }
    }

    fn protectChunk(self: *DirtyTracker, index: usize, flags: hvf.MemoryFlags) !void {
        const range = self.sealer.chunkRange(index);
        try hvf.check(
            hvf.hv_vm_protect(board.ram_base + range.start, range.end - range.start, flags),
            "hv_vm_protect dirty chunk",
        );
    }
};

fn monitorStatsFromDirtyTracker(tracker: ?*DirtyTracker) vsock.ControlStats {
    const active = tracker orelse return .{};
    return .{
        .chunks_nonzero = @intCast(active.sealer.nonzeroChunkCount()),
        .dirty_chunks_pending = @intCast(active.sealer.dirtyChunksPending()),
    };
}

fn materializeAllTransportQueues(pager: *lazy_ram.Pager, transports: []mmio.Transport) !void {
    for (transports) |*transport| {
        try materializeTransportQueues(pager, transport);
    }
}

fn materializeTransportQueues(pager: *lazy_ram.Pager, transport: *const mmio.Transport) !void {
    for (transport.queues[0..transport.dev.queue_count]) |queue| {
        try pager.materializeVirtQueue(queue);
    }
}

fn maybeMaterializeTransportQueues(pager: ?*lazy_ram.Pager, transport: *const mmio.Transport) !void {
    if (pager) |p| try materializeTransportQueues(p, transport);
}

const SnapshotPlatform = struct {
    dist_base: u64,
    redist_base: u64,
    redist_stride: u64 = 0,
    ram_size: u64,
};

fn takeSnapshot(
    allocator: std.mem.Allocator,
    dir: []const u8,
    vcpu: hvf.VcpuHandle,
    transports: []mmio.Transport,
    gen_dev: *const generation.Device,
    ram_bytes: []const u8,
    platform: SnapshotPlatform,
    rootfs: ?spore.Rootfs,
    disk_snapshot: ?disk_layer.SnapshotState,
    network_manifest: ?spore.Network,
    annotations: spore.Annotations,
    sessions: []const spore.Session,
    dirty_tracker: ?*DirtyTracker,
    environ_map: ?*const std.process.Environ.Map,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const total_start = monotonicMs();
    const machine_start = total_start;
    const machine = try snapshot.captureMachine(arena, vcpu);
    const machine_ms = monotonicMs() - machine_start;
    const devices_start = monotonicMs();
    const devices = try captureTransports(arena, transports);
    const devices_ms = monotonicMs() - devices_start;
    if (disk_snapshot) |disk_state| {
        if (!try spore.diskQueuesQuiescent(disk_state.base, devices)) {
            std.log.err("cannot snapshot writable rootfs-backed VM while virtio-blk has pending requests", .{});
            return error.DeviceStatePending;
        }
    } else if (rootfs) |rootfs_artifact| {
        if (!try spore.rootfsQueuesQuiescent(rootfs_artifact, devices)) {
            std.log.err("cannot snapshot rootfs-backed VM while virtio-blk has pending requests", .{});
            return error.DeviceStatePending;
        }
    }
    const generation_start = monotonicMs();
    const gen_state = try gen_dev.capture(arena);
    const generation_ms = monotonicMs() - generation_start;
    const memory_start = monotonicMs();
    const memory = if (dirty_tracker) |tracker|
        try tracker.finish()
    else
        try spore.saveMemoryWithBacking(arena, dir, ram_bytes);
    const memory_ms = monotonicMs() - memory_start;
    if (environ_map) |environ| {
        spore.writeLocalMemoryBackingProof(arena, environ, dir, memory, platform.ram_size) catch |err| {
            std.log.debug("local RAM backing proof unavailable: {s}", .{@errorName(err)});
        };
    }
    const disk_manifest = if (disk_snapshot) |disk_state| try disk_state.finish(arena, dir) else null;
    const manifest_start = monotonicMs();
    try spore.saveManifest(arena, dir, .{
        .platform = .{
            .cpu_profile = board.cpu_profile,
            .device_model_version = board.device_model_version,
            .ram_base = board.ram_base,
            .ram_size = platform.ram_size,
            .gic_dist_base = platform.dist_base,
            .gic_redist_base = platform.redist_base,
            .counter_frequency_hz = snapshot.hostCounterFreq(),
        },
        .machine = machine,
        .devices = devices,
        .generation = gen_state,
        .annotations = annotations,
        .rootfs = rootfs,
        .disk = disk_manifest,
        .network = network_manifest,
        .sessions = sessions,
        .memory = memory,
    });
    const manifest_ms = monotonicMs() - manifest_start;
    const snapshot_total_ms = monotonicMs() - total_start;
    const memory_plan = try spore.validateMemoryForRam(memory, ram_bytes.len);
    if (dirty_tracker) |tracker| {
        const stats = tracker.stats;
        const core_stats = tracker.core.stats;
        const ram_stats = tracker.sealer.stats;
        var metrics_head_buf: [2048]u8 = undefined;
        var metrics_tail_buf: [3072]u8 = undefined;
        const metrics_head = std.fmt.bufPrint(
            &metrics_head_buf,
            "hvf snapshot metrics: mode=write-protect ram_mib={d} chunks={d} nonzero_chunks={d} machine_ms={d} devices_ms={d} generation_ms={d} memory_ms={d} manifest_ms={d} snapshot_pause_ms={d} snapshot_total_ms={d} dirty_epoch_ms={d} dirty_epoch_count={d} write_fault_count={d} dirty_chunks_total={d} dirty_chunks_tail={d} host_dirty_ranges_total={d} host_dirty_chunks_total={d} sealed_chunks_total={d} seed_ms={d} seed_chunks={d} seed_nonzero_chunks={d} seed_protect_ms={d} tail_flush_ms={d}",
            .{
                platform.ram_size / 1024 / 1024,
                memory_plan.chunk_count,
                memory_plan.nonzero_chunk_count,
                machine_ms,
                devices_ms,
                generation_ms,
                memory_ms,
                manifest_ms,
                snapshot_total_ms,
                snapshot_total_ms,
                core_stats.dirty_epoch_ms,
                core_stats.dirty_epoch_count,
                stats.write_fault_count,
                ram_stats.dirty_chunks_total,
                ram_stats.dirty_chunks_tail,
                ram_stats.host_dirty_ranges_total,
                ram_stats.host_dirty_chunks_total,
                ram_stats.sealed_chunks_total,
                ram_stats.seed_ms,
                ram_stats.seed_chunks,
                ram_stats.seed_nonzero_chunks,
                stats.seed_protect_ms,
                ram_stats.tail_flush_ms,
            },
        ) catch "hvf snapshot metrics: formatting_failed=1";
        const metrics_tail = std.fmt.bufPrint(
            &metrics_tail_buf,
            " seal_ms={d} protect_ms={d} seal_zero_scan_ms={d} seal_hash_ms={d} seal_chunk_write_ms={d} seal_backing_write_ms={d} seal_parallel_flush_count={d} seal_parallel_workers_max={d} worker_epoch_max_ms={d} worker_cadence_lag_max_ms={d} worker_cadence_lag_total_ms={d} worker_epoch_overrun_count={d} worker_epoch_overrun_ms={d} worker_join_ms={d} finish_worker_stop_ms={d} finish_fchmod_ms={d} finish_close_ms={d} finish_close_deferred={d} finish_rename_ms={d} tracking_ms={d} dirty_chunks_per_sec={d} sealed_chunks_per_sec={d}",
            .{
                ram_stats.seal_ms,
                stats.protect_ms,
                ram_stats.sealZeroScanMs(),
                ram_stats.sealHashMs(),
                ram_stats.sealChunkWriteMs(),
                ram_stats.sealBackingWriteMs(),
                ram_stats.seal_parallel_flush_count,
                ram_stats.seal_parallel_workers_max,
                core_stats.worker_epoch_max_ms,
                core_stats.worker_cadence_lag_max_ms,
                core_stats.worker_cadence_lag_total_ms,
                core_stats.worker_epoch_overrun_count,
                core_stats.worker_epoch_overrun_ms,
                core_stats.worker_join_ms,
                core_stats.finish_worker_stop_ms,
                ram_stats.finish_fchmod_ms,
                ram_stats.finish_close_ms,
                ram_stats.finish_close_deferred,
                ram_stats.finish_rename_ms,
                ram_stats.tracking_ms,
                ram_stats.dirty_chunks_per_sec,
                ram_stats.sealed_chunks_per_sec,
            },
        ) catch "";
        std.log.info("{s}{s}", .{ metrics_head, metrics_tail });
    } else {
        std.log.info(
            "hvf snapshot metrics: mode=full-scan ram_mib={d} chunks={d} nonzero_chunks={d} machine_ms={d} devices_ms={d} generation_ms={d} memory_ms={d} manifest_ms={d} snapshot_pause_ms={d} snapshot_total_ms={d}",
            .{
                platform.ram_size / 1024 / 1024,
                memory_plan.chunk_count,
                memory_plan.nonzero_chunk_count,
                machine_ms,
                devices_ms,
                generation_ms,
                memory_ms,
                manifest_ms,
                snapshot_total_ms,
                snapshot_total_ms,
            },
        );
    }
    std.log.info("spore written to {s}", .{dir});
}

fn takeSnapshotV1(
    allocator: std.mem.Allocator,
    dir: []const u8,
    vcpus: []HvfVcpu,
    state: *MultiHvfRunState,
    wake_set: *HvfVcpuWakeSet,
    transports: []mmio.Transport,
    gen_dev: *const generation.Device,
    vsock_dev: *const vsock.Vsock,
    ram_bytes: []const u8,
    platform: SnapshotPlatform,
    rootfs: ?spore.Rootfs,
    disk_snapshot: ?disk_layer.SnapshotState,
    network_manifest: ?spore.Network,
    annotations: spore.Annotations,
    sessions: []const spore.Session,
    environ_map: ?*const std.process.Environ.Map,
) !void {
    if (vsock_dev.pending_len != 0) {
        std.log.err("cannot snapshot while virtio-vsock has pending packets", .{});
        return error.DeviceStatePending;
    }
    try pauseHvfVcpusForSnapshot(vcpus, state, wake_set);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const total_start = monotonicMs();
    const machine_start = total_start;
    const vcpu_states = try captureHvfVcpuStates(arena, vcpus);
    const machine = try snapshot.captureMachineV1(arena, vcpu_states);
    const machine_ms = monotonicMs() - machine_start;
    const devices_start = monotonicMs();
    const devices = try captureTransports(arena, transports);
    const devices_ms = monotonicMs() - devices_start;
    if (disk_snapshot) |disk_state| {
        if (!try spore.diskQueuesQuiescent(disk_state.base, devices)) {
            std.log.err("cannot snapshot writable rootfs-backed VM while virtio-blk has pending requests", .{});
            return error.DeviceStatePending;
        }
    } else if (rootfs) |rootfs_artifact| {
        if (!try spore.rootfsQueuesQuiescent(rootfs_artifact, devices)) {
            std.log.err("cannot snapshot rootfs-backed VM while virtio-blk has pending requests", .{});
            return error.DeviceStatePending;
        }
    }
    const generation_start = monotonicMs();
    const gen_state = try gen_dev.capture(arena);
    const generation_ms = monotonicMs() - generation_start;
    const memory_start = monotonicMs();
    const memory = try spore.saveMemoryWithBacking(arena, dir, ram_bytes);
    const memory_ms = monotonicMs() - memory_start;
    if (environ_map) |environ| {
        spore.writeLocalMemoryBackingProof(arena, environ, dir, memory, platform.ram_size) catch |err| {
            std.log.debug("local RAM backing proof unavailable: {s}", .{@errorName(err)});
        };
    }
    const disk_manifest = if (disk_snapshot) |disk_state| try disk_state.finish(arena, dir) else null;
    const manifest_start = monotonicMs();
    try spore.saveManifestV1(arena, dir, .{
        .platform = .{
            .cpu_profile = board.cpu_profile,
            .device_model_version = board.device_model_version,
            .vcpu_count = @intCast(vcpus.len),
            .ram_base = board.ram_base,
            .ram_size = platform.ram_size,
            .gic_dist_base = platform.dist_base,
            .gic_redist_base = platform.redist_base,
            .gic_redist_stride = platform.redist_stride,
            .counter_frequency_hz = snapshot.hostCounterFreq(),
        },
        .machine = machine,
        .devices = devices,
        .generation = gen_state,
        .annotations = annotations,
        .rootfs = rootfs,
        .disk = disk_manifest,
        .network = network_manifest,
        .sessions = sessions,
        .memory = memory,
    });
    const manifest_ms = monotonicMs() - manifest_start;
    const snapshot_total_ms = monotonicMs() - total_start;
    const memory_plan = try spore.validateMemoryForRam(memory, ram_bytes.len);
    std.log.info(
        "hvf snapshot metrics: version=1 vcpus={d} mode=full-scan ram_mib={d} chunks={d} nonzero_chunks={d} machine_ms={d} devices_ms={d} generation_ms={d} memory_ms={d} manifest_ms={d} snapshot_total_ms={d}",
        .{
            vcpus.len,
            platform.ram_size / 1024 / 1024,
            memory_plan.chunk_count,
            memory_plan.nonzero_chunk_count,
            machine_ms,
            devices_ms,
            generation_ms,
            memory_ms,
            manifest_ms,
            snapshot_total_ms,
        },
    );
    std.log.info("spore written to {s}", .{dir});
}

fn captureTransports(allocator: std.mem.Allocator, transports: []mmio.Transport) ![]spore.TransportState {
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

fn applyTransports(transports: []mmio.Transport, states: []const spore.TransportState) !void {
    if (states.len != transports.len) return error.PlatformMismatch;
    for (transports, states) |*t, s| {
        if (t.dev.device_id != s.device_id) return error.PlatformMismatch;
        if (s.queues.len != t.dev.queue_count) return error.PlatformMismatch;
        t.status = s.status;
        t.device_features_sel = s.device_features_sel;
        t.driver_features_sel = s.driver_features_sel;
        t.driver_features = s.driver_features;
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

fn raiseGenerationIrqIfPending(gen_dev: *const generation.Device) !void {
    if (gen_dev.interrupt_status & generation.irq_generation_changed != 0) {
        try hvf.check(hvf.hv_gic_set_spi(board.generationIntid(), true), "generation raise spi");
    }
}

fn wakeVcpu(context: *anyopaque) void {
    const vcpu: *hvf.VcpuHandle = @ptrCast(@alignCast(context));
    _ = hvf.hv_vcpus_exit(@ptrCast(vcpu), 1);
}

fn wakeVcpuSet(context: *anyopaque) void {
    const wake_set: *HvfVcpuWakeSet = @ptrCast(@alignCast(context));
    wake_set.wakeAll();
}

fn flushVsockRx(
    vsock_dev: *vsock.Vsock,
    transport: *mmio.Transport,
    ram: guestmem.GuestRam,
    lazy_pager: ?*lazy_ram.Pager,
    transport_index: u32,
) !void {
    try maybeMaterializeTransportQueues(lazy_pager, transport);
    if (vsock_dev.flushPendingRx(&transport.queues, ram)) {
        transport.interrupt_status |= 1;
        try hvf.check(hvf.hv_gic_set_spi(board.virtioDeviceIntid(transport_index), true), "raise vsock spi");
    }
}

fn wakeNetworkVcpu(context: ?*anyopaque) void {
    const vcpu: *hvf.VcpuHandle = @ptrCast(@alignCast(context orelse return));
    _ = hvf.hv_vcpus_exit(@ptrCast(vcpu), 1);
}

fn wakeNetworkVcpuSet(context: ?*anyopaque) void {
    const wake_set: *HvfVcpuWakeSet = @ptrCast(@alignCast(context orelse return));
    wake_set.wakeAll();
}

fn flushNetworkRxHvf(
    net_dev: *net.Net,
    transport: *mmio.Transport,
    ram: guestmem.GuestRam,
    lazy_pager: ?*lazy_ram.Pager,
    transport_index: usize,
) !void {
    try maybeMaterializeTransportQueues(lazy_pager, transport);
    if (net_dev.flushPendingRx(&transport.queues, ram)) {
        transport.interrupt_status |= 1;
        try hvf.check(hvf.hv_gic_set_spi(board.virtioDeviceIntid(@intCast(transport_index)), true), "raise net spi");
    }
}

/// Drain pending bytes from non-blocking stdin into the console rx queue.
fn drainStdin(con: *console.Console, t: *mmio.Transport, ram: guestmem.GuestRam) !void {
    var buf: [256]u8 = undefined;
    while (true) {
        const n = std.c.read(0, &buf, buf.len);
        if (n <= 0) return;
        const fed = con.feed(t, ram, buf[0..@intCast(n)]);
        if (fed > 0) {
            try hvf.check(hvf.hv_gic_set_spi(board.virtioDeviceIntid(0), true), "console rx spi");
        }
        if (n < buf.len) return;
    }
}

fn advancePc(vcpu: hvf.VcpuHandle) !void {
    var pc: u64 = undefined;
    try hvf.check(hvf.hv_vcpu_get_reg(vcpu, .pc, &pc), "get pc");
    try hvf.check(hvf.hv_vcpu_set_reg(vcpu, .pc, pc + 4), "set pc");
}

/// Handle a PSCI call (w0 = function id). Returns an exit cause for
/// SYSTEM_OFF / SYSTEM_RESET, null to continue running.
fn handlePsci(vcpu: hvf.VcpuHandle) !?ExitCause {
    var x0: u64 = undefined;
    try hvf.check(hvf.hv_vcpu_get_reg(vcpu, .x0, &x0), "psci get x0");
    const fid: u32 = @truncate(x0);
    const ret: u64 = switch (fid) {
        psci_version => 0x0001_0001, // PSCI 1.1
        psci_migrate_info_type => 2, // trusted OS not present
        psci_system_off => return .guest_off,
        psci_system_reset => return .guest_reset,
        psci_features => blk: {
            var x1: u64 = undefined;
            try hvf.check(hvf.hv_vcpu_get_reg(vcpu, .x1, &x1), "psci get x1");
            const queried: u32 = @truncate(x1);
            break :blk switch (queried) {
                psci_version, psci_system_off, psci_system_reset, psci_features => 0,
                else => psci_ret_not_supported,
            };
        },
        psci_cpu_off, psci_cpu_on_32, psci_cpu_on_64 => psci_ret_not_supported,
        else => psci_ret_not_supported,
    };
    try hvf.check(hvf.hv_vcpu_set_reg(vcpu, .x0, ret), "psci set x0");
    return null;
}

const GicWindows = struct {
    dist_base: u64,
    dist_size: u64,
    redist_base: u64,
    redist_size: u64,
    redist_stride: u64 = 0,
    redist_vcpus: ?[]HvfVcpu = null,
};

const GicMmioTarget = struct {
    region: gic.Region,
    offset: u64,
    vcpu: hvf.VcpuHandle,
    owner: ?*HvfVcpu = null,
};

const RedistributorFrame = struct {
    index: usize,
    offset: u64,
};

fn redistributorFrame(offset: u64, stride: u64, count: usize) ?RedistributorFrame {
    if (stride == 0) return null;
    const index = offset / stride;
    if (index >= count) return null;
    return .{ .index = @intCast(index), .offset = offset % stride };
}

fn redistributorOwner(vcpus: []HvfVcpu, frame_base: u64) ?*HvfVcpu {
    for (vcpus) |*vcpu| {
        if (vcpu.redist_base == frame_base) return vcpu;
    }
    return null;
}

fn gicMmioTarget(current_vcpu: hvf.VcpuHandle, ipa: u64, windows: GicWindows) !?GicMmioTarget {
    if (ipa >= windows.dist_base and ipa < windows.dist_base + windows.dist_size) {
        return .{ .region = .distributor, .offset = ipa - windows.dist_base, .vcpu = current_vcpu };
    }
    if (ipa < windows.redist_base or ipa >= windows.redist_base + windows.redist_size) return null;

    const offset = ipa - windows.redist_base;
    if (windows.redist_vcpus) |vcpus| {
        const frame_count = windows.redist_size / windows.redist_stride;
        const frame = redistributorFrame(offset, windows.redist_stride, @intCast(frame_count)) orelse return error.UnhandledMmio;
        const frame_base = windows.redist_base + @as(u64, @intCast(frame.index)) * windows.redist_stride;
        const owner = redistributorOwner(vcpus, frame_base) orelse return error.UnhandledMmio;
        return .{ .region = .redistributor, .offset = frame.offset, .vcpu = owner.handle, .owner = owner };
    }
    return .{ .region = .redistributor, .offset = offset, .vcpu = current_vcpu };
}

fn gicTargetOwnerForCommand(current_owner: ?*HvfVcpu, target: GicMmioTarget) ?*HvfVcpu {
    if (target.region != .redistributor) return null;
    const current = current_owner orelse return null;
    const owner = target.owner orelse return null;
    if (owner.index == current.index) return null;
    return owner;
}

fn readGicMmioTarget(current_owner: ?*HvfVcpu, target: GicMmioTarget, size_log2: u2) !u64 {
    if (gicTargetOwnerForCommand(current_owner, target)) |owner| {
        return (try owner.submit(.{ .gic_read = .{ .region = target.region, .offset = target.offset, .size_log2 = size_log2 } })) orelse 0;
    }
    return gic.mmioRead(target.region, target.vcpu, target.offset, size_log2);
}

fn writeGicMmioTarget(current_owner: ?*HvfVcpu, target: GicMmioTarget, value: u64) !void {
    if (gicTargetOwnerForCommand(current_owner, target)) |owner| {
        _ = try owner.submit(.{ .gic_write = .{ .region = target.region, .offset = target.offset, .value = value } });
        return;
    }
    gic.mmioWrite(target.region, target.vcpu, target.offset, value);
}

test "psci target index accepts normalized mpidr affinity" {
    try std.testing.expectEqual(@as(?usize, 1), psciTargetIndex(2, 1));
    try std.testing.expectEqual(@as(?usize, 1), psciTargetIndex(2, topology.mpidrForIndex(1)));
    try std.testing.expectEqual(@as(?usize, null), psciTargetIndex(2, 2));
    try std.testing.expectEqual(@as(?usize, null), psciTargetIndex(2, 1 << 32));
}

test "redistributor frame helper maps offsets by stride" {
    const frame = redistributorFrame(0x2_0000 + 0xc, 0x2_0000, 2).?;
    try std.testing.expectEqual(@as(usize, 1), frame.index);
    try std.testing.expectEqual(@as(u64, 0xc), frame.offset);
    try std.testing.expectEqual(@as(?RedistributorFrame, null), redistributorFrame(0x4_0000, 0x2_0000, 2));
    try std.testing.expectEqual(@as(?RedistributorFrame, null), redistributorFrame(0, 0, 2));
}

test "HVF redistributor window accepts unordered frames" {
    var vcpus = [_]HvfVcpu{
        .{ .redist_base = 0x0803_0000 },
        .{ .redist_base = 0x0801_0000 },
    };
    const window = try hvfRedistributorWindow(&vcpus, 0x2_0000);
    try std.testing.expectEqual(@as(u64, 0x0801_0000), window.base);
    try std.testing.expectEqual(@as(u64, 0x4_0000), window.size);
}

test "gic target routes redistributor frame to matching hvf vcpu" {
    var vcpus = [_]HvfVcpu{
        .{ .handle = 11, .redist_base = 0x0802_0000 },
        .{ .handle = 22, .redist_base = 0x0804_0000 },
    };
    const target = (try gicMmioTarget(11, 0x0802_0000 + 0x2_0000 + 0xc, .{
        .dist_base = 0x0800_0000,
        .dist_size = 0x1_0000,
        .redist_base = 0x0802_0000,
        .redist_size = 0x4_0000,
        .redist_stride = 0x2_0000,
        .redist_vcpus = vcpus[0..],
    })).?;
    try std.testing.expectEqual(gic.Region.redistributor, target.region);
    try std.testing.expectEqual(@as(u64, 0xc), target.offset);
    try std.testing.expectEqual(@as(hvf.VcpuHandle, 22), target.vcpu);
}

test "vsock rx flush materializes lazy transport queues before delivery" {
    var refs = [_]?[]const u8{null};
    var ram_bytes: [spore.chunk_size]u8 align(std.heap.page_size_min) = undefined;
    @memset(&ram_bytes, 0);
    var mapped = [_]bool{false};
    var pager = lazy_ram.Pager{
        .allocator = std.testing.allocator,
        .dir = ".",
        .manifest = .{ .chunk_size = spore.chunk_size, .chunks = &refs },
        .ram = ram_bytes[0..],
        .mapped = &mapped,
        .trace_fd = null,
        .start_ms = 0,
    };
    const ram = guestmem.GuestRam{ .bytes = ram_bytes[0..], .base = board.ram_base };
    var vsock_dev = vsock.Vsock.init(.{});
    var transport = mmio.Transport.init(vsock_dev.device());

    transport.queues[0] = .{
        .ready = true,
        .size = 1,
        .desc_addr = std.math.maxInt(u64),
    };

    try std.testing.expectError(
        error.BadManifest,
        flushVsockRx(&vsock_dev, &transport, ram, &pager, 0),
    );
}

/// Decode a data-abort exit into an MMIO access and dispatch it to the
/// GIC frames or virtio-mmio windows. ESR ISS layout per Arm ARM D17.2.37.
fn handleMmio(
    vcpu: hvf.VcpuHandle,
    exit: *hvf.VcpuExit,
    transports: []mmio.Transport,
    gen_dev: *generation.Device,
    ram: guestmem.GuestRam,
    lazy_pager: ?*lazy_ram.Pager,
    gic_windows: GicWindows,
    current_owner: ?*HvfVcpu,
) !void {
    const syndrome = exit.exception.syndrome;
    const isv = syndrome & (1 << 24) != 0;
    if (!isv) {
        std.log.err("data abort without ISV at ipa=0x{x}", .{exit.exception.physical_address});
        return error.UnhandledMmio;
    }
    const sas: u2 = @truncate(syndrome >> 22); // access size = 1 << sas
    const srt: u5 = @truncate(syndrome >> 16); // register transfer number
    const is_write = syndrome & (1 << 6) != 0;
    const ipa = exit.exception.physical_address;

    // GIC distributor / redistributor frames.
    if (try gicMmioTarget(vcpu, ipa, gic_windows)) |g| {
        if (is_write) {
            var value: u64 = 0;
            if (srt < 31) {
                try hvf.check(hvf.hv_vcpu_get_reg(vcpu, @enumFromInt(@as(u32, srt)), &value), "gic read xt");
            }
            try writeGicMmioTarget(current_owner, g, value);
        } else if (srt < 31) {
            const value = try readGicMmioTarget(current_owner, g, sas);
            const masked: u64 = switch (sas) {
                0 => value & 0xff,
                1 => value & 0xffff,
                2 => value & 0xffff_ffff,
                3 => value,
            };
            try hvf.check(hvf.hv_vcpu_set_reg(vcpu, @enumFromInt(@as(u32, srt)), masked), "gic write xt");
        }
        try advancePc(vcpu);
        return;
    }

    if (ipa >= board.generation_base and ipa < board.generation_base + board.generation_size) {
        const offset = ipa - board.generation_base;
        if (is_write) {
            var value: u64 = 0;
            if (srt < 31) {
                try hvf.check(hvf.hv_vcpu_get_reg(vcpu, @enumFromInt(@as(u32, srt)), &value), "generation read xt");
            }
            if (gen_dev.write(offset, value, sas)) {
                try hvf.check(hvf.hv_gic_set_spi(board.generationIntid(), false), "generation lower spi");
            }
        } else if (srt < 31) {
            const value = gen_dev.read(offset, sas);
            const masked: u64 = switch (sas) {
                0 => value & 0xff,
                1 => value & 0xffff,
                2 => value & 0xffff_ffff,
                3 => value,
            };
            try hvf.check(hvf.hv_vcpu_set_reg(vcpu, @enumFromInt(@as(u32, srt)), masked), "generation write xt");
        }
        try advancePc(vcpu);
        return;
    }

    // Locate the virtio window.
    const dev_index = blk: {
        if (ipa < board.virtio_base) break :blk null;
        const idx = (ipa - board.virtio_base) / board.virtio_stride;
        if (idx >= transports.len) break :blk null;
        break :blk idx;
    };

    if (dev_index) |idx| {
        const t = &transports[@intCast(idx)];
        const offset = ipa - board.virtioDeviceBase(@intCast(idx));
        if (is_write) {
            var value: u64 = 0;
            if (srt < 31) {
                try hvf.check(hvf.hv_vcpu_get_reg(vcpu, @enumFromInt(@as(u32, srt)), &value), "mmio read xt");
            }
            if (offset == 0x050) try maybeMaterializeTransportQueues(lazy_pager, t);
            const raised = t.write(offset, @truncate(value), ram);
            if (raised) {
                try hvf.check(hvf.hv_gic_set_spi(board.virtioDeviceIntid(@intCast(idx)), true), "raise spi");
            }
            // Interrupt ack lowers the line (covers level semantics too).
            if (offset == 0x064) {
                try hvf.check(hvf.hv_gic_set_spi(board.virtioDeviceIntid(@intCast(idx)), false), "lower spi");
            }
        } else {
            const value = t.read(offset);
            if (srt < 31) {
                const masked: u64 = switch (sas) {
                    0 => value & 0xff,
                    1 => value & 0xffff,
                    else => value,
                };
                try hvf.check(hvf.hv_vcpu_set_reg(vcpu, @enumFromInt(@as(u32, srt)), masked), "mmio write xt");
            }
        }
    } else {
        // Unknown MMIO: reads as zero, writes ignored. Loud once per boot
        // would be better; log at debug to keep bring-up output readable.
        std.log.debug("stray mmio {s} at ipa=0x{x}", .{ if (is_write) "write" else "read", ipa });
        if (!is_write and srt < 31) {
            try hvf.check(hvf.hv_vcpu_set_reg(vcpu, @enumFromInt(@as(u32, srt)), 0), "stray read");
        }
    }

    try advancePc(vcpu);
}
