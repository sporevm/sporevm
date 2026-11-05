//! HVF virtual machine: board assembly and vCPU run loop.
//!
//! Boots the pinned kernel with the SporeVM board (GICv3 via hv_gic,
//! virtio-mmio console/blk/net/vsock/rng, generation MMIO), handles MMIO data
//! aborts, PSCI over HVC, vtimer exits, WFI, and HVF snapshot/resume.
//! Multi-vCPU capture/resume uses `machine.multi` with same-HVF private GIC state.

const std = @import("std");
const aarch64_topology = @import("../aarch64/topology.zig");
const capture = @import("../capture.zig");
const disk_layer = @import("../disk_layer.zig");
const local_paths = @import("../local_paths.zig");
const rootfs_mod = @import("../rootfs.zig");
const saved_spore_pin = @import("../saved_spore_pin.zig");
const dirty_ram = @import("../dirty_ram.zig");
const runtime_disk_fork_capture = @import("../runtime_disk_fork_capture.zig");
const hvf = @import("hvf.zig");
const gic = @import("gic.zig");
const board = @import("../aarch64/board.zig");
const boot = @import("../aarch64/boot.zig");
const generation = @import("../generation.zig");
const guestmem = @import("../guestmem.zig");
const mmio = @import("../virtio/mmio.zig");
const blk = @import("../virtio/blk.zig");
const net = @import("../virtio/net.zig");
const transport_snapshot = @import("../virtio/transport_snapshot.zig");
const virtio_mem = @import("../virtio/mem.zig");
const vsock = @import("../virtio/vsock.zig");
const vsock_control = @import("../virtio/vsock_control.zig");
const platform_contract = @import("../platform.zig");
const spore = @import("../spore.zig");
const topology = @import("../topology.zig");
const vmm = @import("../aarch64/vmm.zig");
const snapshot = @import("snapshot.zig");

const ExitCause = vmm.ExitCause;

const HvfPostRunAction = enum { dispatch_exit, resume_before_run };

fn hvfPostRunAction(reason: hvf.ExitReason) HvfPostRunAction {
    // Async wakes surface as canceled. Every other return carries completed
    // guest work that must be dispatched before the next pre-run wake flush.
    return if (reason == .canceled) .resume_before_run else .dispatch_exit;
}

const HotplugMapping = struct {
    bytes: []align(std.heap.page_size_min) u8,
    guest_addr: u64,
    mapped_bytes: u64 = 0,

    fn init(bytes: []align(std.heap.page_size_min) u8, guest_addr: u64) HotplugMapping {
        return .{
            .bytes = bytes,
            .guest_addr = guest_addr,
        };
    }

    fn deinit(self: *HotplugMapping) void {
        if (self.mapped_bytes != 0) _ = hvf.hv_vm_unmap(self.guest_addr, self.mapped_bytes);
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

pub fn run(allocator: std.mem.Allocator, input: vmm.Config) !ExitCause {
    const setup_start = monotonicMs();
    var prepared = try vmm.prepare(allocator, input, .{ .multi_vcpu_dirty_tracking = false });
    defer prepared.deinit();
    const config = &prepared.config;
    var restore_stats: ?vmm.RestoreStats = if (prepared.restoring()) .{
        .start_ms = setup_start,
        .manifest_ms = monotonicMs() - setup_start,
    } else null;
    var dirty_tracker: ?DirtyTracker = null;
    const hv_vm_create_start = monotonicMs();
    try hvf.check(hvf.hv_vm_create(null), "hv_vm_create");
    const hv_vm_create_ms = monotonicMs() - hv_vm_create_start;
    defer _ = hvf.hv_vm_destroy();
    // HVF restore metrics have always excluded hv_vm_create from pre_run_ms.
    if (restore_stats) |*stats| stats.start_ms += hv_vm_create_ms;

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
    const dist_base: u64, const redist_base: u64 = if (prepared.manifest) |parsed|
        .{ parsed.value.platform.gic_dist_base, parsed.value.platform.gic_redist_base }
    else
        .{ default_dist_base, default_redist_base };
    if (dist_base % dist_align != 0 or redist_base % redist_align != 0) return error.PlatformMismatch;

    const gic_config = hvf.hv_gic_config_create();
    defer hvf.os_release(gic_config);
    try hvf.check(hvf.hv_gic_config_set_distributor_base(gic_config, dist_base), "gic set dist base");
    try hvf.check(hvf.hv_gic_config_set_redistributor_base(gic_config, redist_base), "gic set redist base");
    try hvf.check(hvf.hv_gic_create(gic_config), "hv_gic_create");
    const gic_ms = monotonicMs() - gic_start;

    // Guest RAM. Fresh boots, eager chunk resumes, and proof-gated local
    // backing resumes all map the whole initial range up front.
    const map_ram_start = monotonicMs();
    const ram_mapping = try vmm.mapRam(&prepared);
    const map_ram_ms = monotonicMs() - map_ram_start;
    if (restore_stats) |*stats| stats.map_ram_ms = map_ram_ms;
    defer ram_mapping.deinit();
    const ram_bytes = ram_mapping.bytes;
    const initial_ram_len: usize = @intCast(prepared.ram_size);
    const hv_map_ram_start = monotonicMs();
    try hvf.check(
        hvf.hv_vm_map(ram_bytes.ptr, board.ram_base, initial_ram_len, hvf.MemoryFlags.rwx),
        "hv_vm_map ram",
    );
    const hv_map_ram_ms = monotonicMs() - hv_map_ram_start;
    defer _ = hvf.hv_vm_unmap(board.ram_base, initial_ram_len);
    defer if (dirty_tracker) |*tracker| tracker.deinit();
    var ram = guestmem.GuestRam{ .bytes = ram_bytes, .base = board.ram_base };
    var hotplug_mapping: ?HotplugMapping = if (prepared.virtio_mem_region_size > 0)
        HotplugMapping.init(@alignCast(ram_bytes[initial_ram_len..]), board.ram_base + prepared.ram_size)
    else
        null;
    defer if (hotplug_mapping) |*mapping| mapping.deinit();

    const devices_start = monotonicMs();
    var devices: vmm.Devices = undefined;
    devices.init(config, if (hotplug_mapping) |*mapping| .{
        .addr = mapping.guest_addr,
        .region_size = @intCast(mapping.bytes.len),
        .requested_size = 0,
        .plug_context = mapping,
        .plugFn = HotplugMapping.plug,
    } else null);
    defer devices.net.shutdown();
    const transports = devices.transports();
    const transports_buf = &devices.transports_buf;
    const net_dev = &devices.net;
    const vsock_dev = &devices.vsock;
    const mem_dev = &devices.mem;
    const gen_dev = &devices.gen;
    const net_transport_index = devices.net_index;
    const vsock_transport_index = devices.vsock_index;
    const mem_transport_index = devices.mem_index;
    const devices_ms = monotonicMs() - devices_start;

    if (prepared.vcpus != 1) {
        return runFreshMultiVcpu(allocator, .{
            .prepared = &prepared,
            .restore_stats = &restore_stats,
            .transports = transports,
            .transports_buf = transports_buf,
            .gen_dev = gen_dev,
            .ram = ram,
            .ram_bytes = ram_bytes,
            .ram_file_backed = ram_mapping.file_backed,
            .net_dev = net_dev,
            .vsock_dev = vsock_dev,
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
    var primary: Vcpu = .{};
    defer primary.destroyOnOwnerThread();
    try primary.createOnOwnerThread();
    const vcpu = primary.handle;
    var capture_wake: capture.WakeThread = .{};
    if (config.captureRequest()) |request_capture| {
        try capture_wake.start(request_capture, wakeCaptureVcpu, &primary.handle);
    }
    defer if (config.captureRequest()) |request_capture| capture_wake.stop(request_capture);
    if (config.exec_control) |control| {
        control.setWake(.{ .context = &primary.handle, .wakeFn = wakeVcpu });
    }
    config.network.setWake(.{ .context = &primary.handle, .wakeFn = wakeNetworkVcpu });
    defer config.network.clearWake();

    const vcpu_redist_base = primary.redist_base;
    var redist_stride: usize = 0;
    try hvf.check(hvf.hv_gic_get_redistributor_size(&redist_stride), "gic redist stride");

    std.log.debug(
        "gic: dist=0x{x}+0x{x} redist(vcpu0)=0x{x}+0x{x} (region 0x{x}+0x{x})",
        .{ dist_base, dist_size, vcpu_redist_base, redist_stride, redist_base, redist_size },
    );
    const vcpu_ms = monotonicMs() - vcpu_start;

    var boot_ms: u64 = 0;
    if (prepared.manifest) |parsed| {
        const restore = config.start.restore;
        // Restore: memory, device, GIC, and vCPU state from the spore.
        const m = parsed.value;
        const machine = switch (m.machine) {
            .single => |single| single,
            .multi => return error.UnsupportedVcpuCount,
        };
        try platform_contract.checkManifest(m, .{
            .vcpu_count = 1,
            .ram_size = prepared.ram_size,
            .gic_dist_base = dist_base,
            .gic_redist_base = vcpu_redist_base,
            .gic_redist_stride = redist_stride,
            .counter_frequency_hz = snapshot.hostCounterFreq(),
            .device_count = transports.len,
        });
        try vmm.restoreMemory(allocator, restore, m.memory, ram_bytes, ram_mapping.file_backed, &restore_stats);
        const state_start = monotonicMs();
        if (m.memory_state) |state| try mem_dev.restoreState(state);
        try vmm.applyTransports(transports, m.devices);
        try gen_dev.restore(allocator, restore.generation orelse m.generation);
        if (restore.generation == null) try spore.refreshResumeParams(allocator, gen_dev);
        try snapshot.applyMachine(allocator, vcpu, machine);
        try raiseGenerationIrqIfPending(gen_dev);
        if (restore_stats) |*stats| stats.state_ms = monotonicMs() - state_start;
    } else {
        const fresh = config.start.boot;
        // Fresh boot: DTB + kernel. Backend support is currently gated to one
        // vCPU, but DTB construction consumes the shared topology contract.
        const boot_start = monotonicMs();
        const boot_ram = ram_bytes[0..initial_ram_len];
        const initrd_range = if (fresh.initrd) |initrd| try boot.planInitrd(boot_ram.len, board.ram_base, fresh.kernel, initrd.len) else null;
        const dtb = try board.buildDtb(allocator, .{
            .ram_size = prepared.ram_size,
            .cpu_count = prepared.vcpus,
            .gic = .{
                .distributor_base = dist_base,
                .distributor_size = dist_size,
                .redistributor_base = vcpu_redist_base,
                .redistributor_size = try board.redistributorRegionSize(@intCast(redist_stride), prepared.vcpus),
            },
            .virtio_count = @intCast(transports.len),
            .bootargs = fresh.cmdline,
            .initrd = if (initrd_range) |r| .{ .start = r.start, .end = r.end } else null,
        });
        defer allocator.free(dtb);
        const layout = try boot.load(boot_ram, board.ram_base, fresh.kernel, fresh.initrd, dtb);
        var seed_ranges_buf: [3]dirty_ram.ChunkRange = undefined;
        for (layout.populatedRanges(), 0..) |range, i| {
            seed_ranges_buf[i] = .{ .start = range.start, .end = range.end };
        }
        const seed_ranges = seed_ranges_buf[0..layout.populated_range_count];

        try hvf.check(hvf.hv_vcpu_set_reg(vcpu, .cpsr, 0x3c5), "set cpsr"); // EL1h, DAIF masked
        try hvf.check(hvf.hv_vcpu_set_reg(vcpu, .pc, layout.entry), "set pc");
        try hvf.check(hvf.hv_vcpu_set_reg(vcpu, .x0, layout.dtb), "set x0");

        if (config.dirtyTrackingDir()) |dir| {
            dirty_tracker = try DirtyTracker.start(allocator, .{
                .dir = dir,
                .ram = ram_bytes,
                .seed_ranges = seed_ranges,
            });
            if (dirty_tracker) |*tracker| {
                ram.dirty_context = tracker;
                ram.dirty_fn = DirtyTracker.markGuestWriteCallback;
            }
        }
        boot_ms = monotonicMs() - boot_start;
    }

    const start_ms = monotonicMs();
    vmm.emitRestoreMetrics("hvf", &prepared, &restore_stats, start_ms);
    var attach_probe_ms: u64 = 0;
    if (config.probe) |probe| {
        if (probe.start == .immediate) {
            const attach_probe_start = monotonicMs();
            try vsock_dev.attachHostStream(probe.stream);
            probe.stream.markStarted();
            _ = try flushVsockRx(vsock_dev, &transports_buf[vsock_transport_index], ram, @intCast(vsock_transport_index));
            attach_probe_ms = monotonicMs() - attach_probe_start;
        }
    }
    if (!prepared.restoring()) {
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
                prepared.ram_size / 1024 / 1024,
            },
        );
    }
    var exec_probe_done = false;
    var handled_memory_pressure_count: u32 = 0;
    var requested_hotplug_size: u64 = if (mem_transport_index != null) mem_dev.requested_size else 0;
    var logged_first_vcpu_entry = false;
    var logged_first_guest_exit = false;

    // Run loop.
    var did_capture_request = false;
    while (true) {
        if (config.probe != null and !exec_probe_done) {
            _ = try flushVsockRx(vsock_dev, &transports_buf[vsock_transport_index], ram, @intCast(vsock_transport_index));
        }
        if (mem_transport_index != null) {
            if (config.probeStream()) |probe| {
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
            try flushNetworkRxHvf(net_dev, &transports_buf[net_transport_index], ram, net_transport_index);
            continue;
        }
        if (config.exec_control) |control| {
            control.reportStats(vmm.monitorStats(if (dirty_tracker) |*tracker| &tracker.sealer else null));
            switch (try control.poll(vsock_dev)) {
                .keep_running => {},
                .stop => return .monitor_stopped,
                .snapshot => |request| snapshot_action: {
                    var preparation = if (request.publish_dir != null)
                        (try control.prepareSnapshot()) orelse break :snapshot_action
                    else
                        null;
                    defer if (preparation) |*owned| owned.deinit();
                    var prepared_root = if (request.publish_dir) |publish_dir|
                        if (config.disk_snapshot) |disk_state| try disk_state.prepareSnapshotRoot(publish_dir) else null
                    else
                        null;
                    defer if (prepared_root) |*root| root.deinit();
                    const source_pause_started_ns = runtime_disk_fork_capture.monotonicNs();
                    try takeSnapshot(allocator, request.dir, vcpu, transports, gen_dev, vsock_dev, ram_bytes, .{
                        .dist_base = dist_base,
                        .redist_base = vcpu_redist_base,
                        .redist_stride = @intCast(redist_stride),
                        .ram_size = prepared.ram_size,
                        .memory_device = if (mem_transport_index != null) mem_dev else null,
                    }, config.rootfs, config.disk_snapshot, null, config.network_manifest, config.annotations, config.sessions, if (dirty_tracker) |*tracker| tracker else null, config.environ_map, if (preparation) |*owned| owned.cacheLock() else null);
                    if (!request.continue_after) return .snapshotted;
                    const completed_dir = if (request.publish_dir) |publish_dir| blk: {
                        const publish_metrics = try control.publishSnapshot(&preparation.?, request.dir, publish_dir);
                        if (prepared_root) |*root| try config.disk_snapshot.?.commitSnapshotRoot(request.dir, root, if (config.environ_map != null) .shared_no_rebind else .local_rebind);
                        vmm.logNamedSnapshotPublication("hvf", publish_metrics, source_pause_started_ns);
                        break :blk publish_dir;
                    } else request.dir;
                    try control.completeSnapshot(completed_dir);
                },
                .rootfs_snapshot => |request| {
                    const disk_manifest = try vmm.takeRootfsSnapshot(allocator, request.dir, transports, config.disk_snapshot);
                    try control.completeRootfsSnapshot(disk_manifest);
                },
                .disk_fork => |request| {
                    captureSingleHvfDiskFork(
                        allocator,
                        request,
                        control,
                        vcpu,
                        transports,
                        gen_dev,
                        vsock_dev,
                        ram_bytes,
                        .{
                            .dist_base = dist_base,
                            .redist_base = vcpu_redist_base,
                            .redist_stride = @intCast(redist_stride),
                            .ram_size = prepared.ram_size,
                            .memory_device = if (mem_transport_index != null) mem_dev else null,
                        },
                        config,
                        if (dirty_tracker) |*tracker| tracker else null,
                    ) catch |err| control.failDiskFork(err);
                },
            }
            _ = try flushVsockRx(vsock_dev, &transports_buf[vsock_transport_index], ram, @intCast(vsock_transport_index));
        }
        if (config.captureRequest()) |request_capture| {
            if (request_capture.isAbortRequested()) return error.CaptureAborted;
            if (request_capture.isRequested() and !did_capture_request) {
                try takeSnapshot(allocator, config.capture.?.dir, vcpu, transports, gen_dev, vsock_dev, ram_bytes, .{
                    .dist_base = dist_base,
                    .redist_base = vcpu_redist_base,
                    .redist_stride = @intCast(redist_stride),
                    .ram_size = prepared.ram_size,
                    .memory_device = if (mem_transport_index != null) mem_dev else null,
                }, config.rootfs, config.disk_snapshot, null, config.network_manifest, config.annotations, config.sessions, if (dirty_tracker) |*tracker| tracker else null, config.environ_map, null);
                request_capture.markCompleted();
                if (request_capture.isAbortRequested()) return error.CaptureAborted;
                if (config.continueAfterCapture()) {
                    did_capture_request = true;
                    continue;
                }
                return .snapshotted;
            }
        }
        if (config.probe) |exec_probe| {
            const probe = exec_probe.stream;
            if (!exec_probe_done) {
                if (probe.state == .failed) return error.VsockProbeFailed;
                if (probe.state == .complete) {
                    if (exec_probe.on_complete == .stop) {
                        if (config.probeCaptureDir()) |dir| {
                            try takeSnapshot(allocator, dir, vcpu, transports, gen_dev, vsock_dev, ram_bytes, .{
                                .dist_base = dist_base,
                                .redist_base = vcpu_redist_base,
                                .redist_stride = @intCast(redist_stride),
                                .ram_size = prepared.ram_size,
                                .memory_device = if (mem_transport_index != null) mem_dev else null,
                            }, config.rootfs, config.disk_snapshot, null, config.network_manifest, config.annotations, config.sessions, if (dirty_tracker) |*tracker| tracker else null, config.environ_map, null);
                            return .snapshotted;
                        }
                        return .probe_complete;
                    }
                    vsock_dev.host_stream = null;
                    exec_probe_done = true;
                }
                if (!exec_probe_done and probe.state != .idle and probe.elapsedMs() > exec_probe.timeout_ms) return error.VsockProbeTimedOut;
            }
        }
        if (prepared.restoring() and config.probe != null and !logged_first_vcpu_entry) {
            logged_first_vcpu_entry = true;
            std.log.debug("hvf exec probe timing: first_vcpu_entry_ms={d}", .{monotonicMs() -| start_ms});
        }
        const run_exit = try primary.run(.{
            .all = (&primary)[0..1],
            .gic_windows = .{
                .dist_base = dist_base,
                .dist_size = dist_size,
                .redist_base = vcpu_redist_base,
                .redist_size = redist_stride,
            },
            .dirty_tracker = if (dirty_tracker) |*tracker| tracker else null,
        });
        if (config.probe != null and !exec_probe_done and run_exit != .kicked) {
            if (prepared.restoring() and !logged_first_guest_exit) {
                logged_first_guest_exit = true;
                std.log.debug(
                    "hvf exec probe timing: first_guest_exit_ms={d} reason={}",
                    .{ monotonicMs() -| start_ms, primary.exit.reason },
                );
            }
        }
        switch (run_exit) {
            .mmio => |access| try primary.completeMmio(try handleDeviceMmio(access, transports, gen_dev, ram)),
            .wfi => {
                // Nothing better to do single-threaded yet; yield briefly and
                // let the vtimer wake us.
                var ts = std.c.timespec{ .sec = 0, .nsec = 200 * std.time.ns_per_us };
                _ = std.c.nanosleep(&ts, null);
            },
            .shutdown => |kind| return kind.cause(),
            .handled => {},
            .kicked => {
                if (config.captureRequest()) |request_capture| {
                    if (request_capture.isAbortRequested()) return error.CaptureAborted;
                    if (request_capture.isRequested()) continue;
                }
                if (config.probe != null and !exec_probe_done) continue;
                if (config.network.failed()) continue;
                if (config.network.consumeWake()) {
                    try flushNetworkRxHvf(net_dev, &transports_buf[net_transport_index], ram, net_transport_index);
                    continue;
                }
                if (config.exec_control != null) continue;
                return error.VcpuCanceled;
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
    shared_vtimer_offset: u64,
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

    lock: vmm.SpinLock = .{},
    state: State = .idle,
    command: HvfVcpuCommand = undefined,
    result: HvfVcpuCommandResult = .ok,

    fn submit(self: *HvfVcpuCommandSlot, target: *Vcpu, command: HvfVcpuCommand) !?u64 {
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

const Vcpu = struct {
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
    /// The device access the last `.mmio` exit reported.
    mmio_access: MmioAccess = undefined,
    /// HVF accepts vCPU calls only on the thread that created the vCPU.
    owner_thread: std.Thread.Id = undefined,

    const RunContext = struct {
        /// Every vCPU, for PSCI CPU_ON and redistributor forwarding. The
        /// inline single-vCPU loop passes just its own.
        all: []Vcpu,
        gic_windows: GicWindows,
        dirty_tracker: ?*DirtyTracker = null,
    };

    fn initEmpty(self: *Vcpu, index: topology.VcpuIndex) void {
        self.* = .{ .index = index };
    }

    fn createOnOwnerThread(self: *Vcpu) !void {
        try hvf.check(hvf.hv_vcpu_create(&self.handle, &self.exit, null), "hv_vcpu_create");
        self.created = true;
        self.owner_thread = std.Thread.getCurrentId();
        try hvf.check(hvf.hv_vcpu_set_sys_reg(self.handle, .mpidr_el1, aarch64_topology.mpidrForIndex(self.index)), "set mpidr");
        try hvf.check(hvf.hv_gic_get_redistributor_base(self.handle, &self.redist_base), "gic redist base for vcpu");
    }

    fn destroyOnOwnerThread(self: *Vcpu) void {
        if (self.created) {
            self.assertOwnerThread();
            _ = hvf.hv_vcpu_destroy(self.handle);
            self.created = false;
        }
        self.ready.store(false, .release);
    }

    fn setRunning(self: *Vcpu) void {
        self.run_state.store(hvf_vcpu_state_running, .release);
    }

    fn park(self: *Vcpu) void {
        self.run_state.store(hvf_vcpu_state_off, .release);
    }

    fn isRunning(self: *const Vcpu) bool {
        return self.run_state.load(.acquire) == hvf_vcpu_state_running;
    }

    fn startAt(self: *Vcpu, entry: u64, context_id: u64) !void {
        self.assertOwnerThread();
        try hvf.check(hvf.hv_vcpu_set_reg(self.handle, .cpsr, 0x3c5), "psci set cpsr");
        try hvf.check(hvf.hv_vcpu_set_reg(self.handle, .pc, entry), "psci set pc");
        try hvf.check(hvf.hv_vcpu_set_reg(self.handle, .x0, context_id), "psci set x0");
        self.setRunning();
    }

    fn assertOwnerThread(self: *const Vcpu) void {
        std.debug.assert(std.Thread.getCurrentId() == self.owner_thread);
    }

    fn submit(self: *Vcpu, command: HvfVcpuCommand) !?u64 {
        return self.command_slot.submit(self, command);
    }

    fn wake(self: *const Vcpu) void {
        if (!self.ready.load(.acquire)) return;
        var handles = [_]hvf.VcpuHandle{self.handle};
        _ = hvf.hv_vcpus_exit(&handles, handles.len);
    }

    /// Runs the guest once. The vtimer, unknown sysregs, PSCI, GIC MMIO and
    /// dirty-tracking write faults are handled here; device MMIO is returned
    /// to the loop and finished with `completeMmio`.
    fn run(self: *Vcpu, ctx: RunContext) !vmm.Exit {
        self.assertOwnerThread();
        try hvf.check(hvf.hv_vcpu_run(self.handle), "hv_vcpu_run");
        const exit = self.exit;
        if (hvfPostRunAction(exit.reason) == .resume_before_run) return .kicked;
        switch (exit.reason) {
            .exception => {
                const ec = exit.exception.exceptionClass();
                switch (ec) {
                    hvf.ec_instruction_abort => {
                        std.log.err(
                            "unhandled instruction abort on vcpu {d}: syndrome=0x{x} va=0x{x} ipa=0x{x}",
                            .{ self.index, exit.exception.syndrome, exit.exception.virtual_address, exit.exception.physical_address },
                        );
                        return error.UnhandledGuestException;
                    },
                    hvf.ec_data_abort => {
                        if (ctx.dirty_tracker) |tracker| {
                            if (try tracker.handleWriteFault(exit.exception.syndrome, exit.exception.physical_address)) return .handled;
                        }
                        const access = try decodeMmioAccess(exit);
                        // Redistributor MMIO can forward to another vCPU and wait
                        // for completion, so it stays out of the loop's device lock.
                        if (try handleGicMmioAccess(self.handle, access, ctx.gic_windows, self)) return .handled;
                        var value: ?u64 = null;
                        if (access.is_write) {
                            value = 0;
                            if (access.srt < 31) {
                                try hvf.check(hvf.hv_vcpu_get_reg(self.handle, @enumFromInt(@as(u32, access.srt)), &value.?), "mmio read xt");
                            }
                        }
                        self.mmio_access = access;
                        return .{ .mmio = .{ .addr = access.ipa, .size_log2 = access.sas, .write = value } };
                    },
                    hvf.ec_hvc => return self.psci(ctx.all),
                    hvf.ec_smc => {
                        // Treat SMC like HVC but advance PC (trapped SMC
                        // returns to the same instruction).
                        const result = try self.psci(ctx.all);
                        try advancePc(self.handle);
                        return result;
                    },
                    ec_wfx => {
                        try advancePc(self.handle);
                        return .wfi;
                    },
                    ec_sysreg => {
                        try handleUnknownSysreg(self.handle, exit);
                        return .handled;
                    },
                    else => {
                        std.log.err(
                            "unhandled exception class 0x{x} on vcpu {d}: syndrome=0x{x} va=0x{x} ipa=0x{x}",
                            .{ ec, self.index, exit.exception.syndrome, exit.exception.virtual_address, exit.exception.physical_address },
                        );
                        return error.UnhandledGuestException;
                    },
                }
            },
            .vtimer_activated => {
                // With hv_gic the timer PPI is delivered by the GIC; unmask
                // so subsequent timer exits can fire.
                try hvf.check(hvf.hv_vcpu_set_vtimer_mask(self.handle, false), "vtimer unmask");
                return .handled;
            },
            .canceled => unreachable,
            else => {
                std.log.err("unhandled HVF exit reason {} on vcpu {d}", .{ exit.reason, self.index });
                return error.UnhandledExit;
            },
        }
    }

    /// Finishes the last `.mmio` exit: a read loads `value`, masked to the
    /// access size, into the target register; then the guest moves past the
    /// faulting instruction.
    fn completeMmio(self: *Vcpu, value: u64) !void {
        self.assertOwnerThread();
        const access = self.mmio_access;
        if (!access.is_write and access.srt < 31) {
            const masked: u64 = switch (access.sas) {
                0 => value & 0xff,
                1 => value & 0xffff,
                2 => value & 0xffff_ffff,
                3 => value,
            };
            try hvf.check(hvf.hv_vcpu_set_reg(self.handle, @enumFromInt(@as(u32, access.srt)), masked), "mmio write xt");
        }
        try advancePc(self.handle);
    }

    /// Handles a PSCI call (w0 = function id). CPU_ON and CPU_OFF exist only
    /// when the VM has more than one vCPU.
    fn psci(self: *Vcpu, all: []Vcpu) !vmm.Exit {
        self.assertOwnerThread();
        var x0: u64 = undefined;
        try hvf.check(hvf.hv_vcpu_get_reg(self.handle, .x0, &x0), "psci get x0");
        const fid: u32 = @truncate(x0);
        const multi = all.len > 1;
        const ret: u64 = switch (fid) {
            psci_version => 0x0001_0001, // PSCI 1.1
            psci_migrate_info_type => 2, // trusted OS not present
            psci_system_off => return .{ .shutdown = .off },
            psci_system_reset => return .{ .shutdown = .reset },
            psci_features => blk: {
                var x1: u64 = undefined;
                try hvf.check(hvf.hv_vcpu_get_reg(self.handle, .x1, &x1), "psci get x1");
                const queried: u32 = @truncate(x1);
                break :blk switch (queried) {
                    psci_version, psci_system_off, psci_system_reset, psci_features => 0,
                    psci_cpu_off, psci_cpu_on_32, psci_cpu_on_64 => if (multi) 0 else psci_ret_not_supported,
                    else => psci_ret_not_supported,
                };
            },
            psci_cpu_off => blk: {
                if (!multi) break :blk psci_ret_not_supported;
                self.park();
                return .handled;
            },
            psci_cpu_on_32, psci_cpu_on_64 => blk: {
                if (!multi) break :blk psci_ret_not_supported;
                var target_mpidr: u64 = undefined;
                var entry: u64 = undefined;
                var context_id: u64 = undefined;
                try hvf.check(hvf.hv_vcpu_get_reg(self.handle, .x1, &target_mpidr), "psci get target");
                try hvf.check(hvf.hv_vcpu_get_reg(self.handle, .x2, &entry), "psci get entry");
                try hvf.check(hvf.hv_vcpu_get_reg(self.handle, .x3, &context_id), "psci get context");
                break :blk try psciCpuOn(all, target_mpidr, entry, context_id);
            },
            else => psci_ret_not_supported,
        };
        try hvf.check(hvf.hv_vcpu_set_reg(self.handle, .x0, ret), "psci set x0");
        return .handled;
    }
};

const HvfRedistributorWindow = struct {
    base: u64,
    size: u64,
};

fn hvfRedistributorWindow(vcpus: []const Vcpu, stride: u64) !HvfRedistributorWindow {
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
    vcpus: []const Vcpu,

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
    mutex: vmm.SpinLock = .{},
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
    prepared: *const vmm.Prepared,
    restore_stats: *?vmm.RestoreStats,
    transports: []mmio.Transport,
    transports_buf: *[board.max_virtio_devices]mmio.Transport,
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
    vcpu: *Vcpu,
    vcpus: []Vcpu,
    state: *MultiHvfRunState,
    device_lock: *vmm.SpinLock,
    network: net.Runtime,
    transports: []mmio.Transport,
    gen_dev: *generation.Device,
    ram: guestmem.GuestRam,
    net_dev: *net.Net,
    net_transport_index: usize,
    gic_windows: GicWindows,
};

fn runFreshMultiVcpu(allocator: std.mem.Allocator, options: MultiHvfRunOptions) !ExitCause {
    const config = &options.prepared.config;
    const vcpu_count: usize = @intCast(options.prepared.vcpus);
    var vcpus = try allocator.alloc(Vcpu, vcpu_count);
    defer allocator.free(vcpus);
    for (vcpus, 0..) |*vcpu, index| vcpu.initEmpty(@intCast(index));

    var state = MultiHvfRunState{};
    var device_lock = vmm.SpinLock{};
    var exec_probe_done = false;
    var wake_set = HvfVcpuWakeSet{ .vcpus = vcpus };
    config.network.setWake(.{ .context = &wake_set, .wakeFn = wakeNetworkVcpuSet });
    defer config.network.clearWake();
    if (config.exec_control) |control| {
        control.setWake(.{ .context = &wake_set, .wakeFn = wakeVcpuSet });
    }
    var capture_wake: capture.WakeThread = .{};
    if (config.captureRequest()) |request_capture| {
        try capture_wake.start(request_capture, wakeCaptureVcpuSet, &wake_set);
    }
    defer if (config.captureRequest()) |request_capture| capture_wake.stop(request_capture);

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
            .state = &state,
            .device_lock = &device_lock,
            .network = config.network,
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
    if (options.prepared.manifest) |parsed| {
        const restore = config.start.restore;
        const manifest = &parsed.value;
        const restore_start = monotonicMs();
        const machine = switch (manifest.machine) {
            .multi => |multi| multi,
            .single => return error.PlatformMismatch,
        };
        try platform_contract.checkManifest(manifest.*, .{
            .vcpu_count = options.prepared.vcpus,
            .ram_size = options.prepared.ram_size,
            .gic_dist_base = options.dist_base,
            .gic_redist_base = redist_window.base,
            .gic_redist_stride = @intCast(redist_stride),
            .counter_frequency_hz = snapshot.hostCounterFreq(),
            .device_count = options.transports.len,
        });
        // HVF restores only its own private GIC blob.
        if (machine.gic.kind != .backend_private) return error.PlatformMismatch;
        try vmm.restoreMemory(allocator, restore, manifest.memory, options.ram_bytes, options.ram_file_backed, options.restore_stats);
        const state_start = monotonicMs();
        try vmm.applyTransports(options.transports, manifest.devices);
        try options.gen_dev.restore(allocator, restore.generation orelse manifest.generation);
        if (restore.generation == null) try spore.refreshResumeParams(allocator, options.gen_dev);
        try snapshot.applyGicState(allocator, vcpus[0].handle, machine.gic);
        try applyHvfVcpuStates(vcpus, machine);
        for (vcpus) |*vcpu| vcpu.setRunning();
        try raiseGenerationIrqIfPending(options.gen_dev);
        if (options.restore_stats.*) |*stats| stats.state_ms = monotonicMs() - state_start;
        boot_ms = monotonicMs() - restore_start;
    } else {
        const fresh = config.start.boot;
        const boot_start = monotonicMs();
        const initrd_range = if (fresh.initrd) |initrd| try boot.planInitrd(options.ram.bytes.len, board.ram_base, fresh.kernel, initrd.len) else null;
        const dtb = try board.buildDtb(allocator, .{
            .ram_size = options.prepared.ram_size,
            .cpu_count = options.prepared.vcpus,
            .gic = .{
                .distributor_base = options.dist_base,
                .distributor_size = options.dist_size,
                .redistributor_base = redist_window.base,
                .redistributor_size = redist_window.size,
            },
            .virtio_count = @intCast(options.transports.len),
            .bootargs = fresh.cmdline,
            .initrd = if (initrd_range) |r| .{ .start = r.start, .end = r.end } else null,
        });
        defer allocator.free(dtb);
        const layout = try boot.load(options.ram.bytes, board.ram_base, fresh.kernel, fresh.initrd, dtb);
        _ = try vcpus[0].submit(.{ .start = .{ .entry = layout.entry, .arg0 = layout.dtb } });
        boot_ms = monotonicMs() - boot_start;
    }

    vmm.emitRestoreMetrics("hvf", options.prepared, options.restore_stats, monotonicMs());

    var attach_probe_ms: u64 = 0;
    if (config.probe) |probe| {
        if (probe.start == .immediate) {
            const attach_probe_start = monotonicMs();
            try options.vsock_dev.attachHostStream(probe.stream);
            probe.stream.markStarted();
            wakeAfterVsockRxDelivery(
                try flushVsockRx(options.vsock_dev, &options.transports_buf[options.vsock_transport_index], options.ram, @intCast(options.vsock_transport_index)),
                .{ .context = &wake_set, .wakeFn = wakeVcpuSet },
            );
            attach_probe_ms = monotonicMs() - attach_probe_start;
        }
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
            options.prepared.ram_size / 1024 / 1024,
        },
    );

    while (true) {
        if (state.result()) |result| {
            wake_set.wakeAll();
            return finishMultiHvfResult(result);
        }
        if (config.network.failed()) {
            state.finish(.{ .err = error.NetworkGatewayFailed });
            continue;
        }
        if (config.exec_control) |control| {
            control.reportStats(vmm.monitorStats(null));
            device_lock.lock();
            const action = control.poll(options.vsock_dev) catch |err| {
                device_lock.unlock();
                state.finish(.{ .err = err });
                continue;
            };
            var vsock_rx_delivered = false;
            switch (action) {
                .keep_running => vsock_rx_delivered = flushVsockRx(
                    options.vsock_dev,
                    &options.transports_buf[options.vsock_transport_index],
                    options.ram,
                    @intCast(options.vsock_transport_index),
                ) catch |err| {
                    device_lock.unlock();
                    state.finish(.{ .err = err });
                    continue;
                },
                else => {},
            }
            device_lock.unlock();
            wakeAfterVsockRxDelivery(
                vsock_rx_delivered,
                .{ .context = &wake_set, .wakeFn = wakeVcpuSet },
            );
            switch (action) {
                .keep_running => {},
                .stop => {
                    state.finish(.{ .exit = .monitor_stopped });
                    continue;
                },
                .snapshot => |request| snapshot_action: {
                    if (request.continue_after) {
                        var preparation = if (request.publish_dir != null)
                            (control.prepareSnapshot() catch |err| {
                                state.finish(.{ .err = err });
                                break :snapshot_action;
                            }) orelse break :snapshot_action
                        else
                            null;
                        defer if (preparation) |*owned| owned.deinit();
                        var prepared_root = if (request.publish_dir) |publish_dir|
                            if (options.disk_snapshot) |disk_state| try disk_state.prepareSnapshotRoot(publish_dir) else null
                        else
                            null;
                        defer if (prepared_root) |*root| root.deinit();
                        var source_pause_started_ns: u64 = 0;
                        takeSnapshotMulti(
                            allocator,
                            request.dir,
                            vcpus,
                            &state,
                            &wake_set,
                            options.transports,
                            options.gen_dev,
                            options.vsock_dev,
                            options.ram_bytes,
                            .{ .dist_base = options.dist_base, .redist_base = redist_window.base, .redist_stride = @intCast(redist_stride), .ram_size = options.prepared.ram_size },
                            options.rootfs,
                            options.disk_snapshot,
                            null,
                            options.network_manifest,
                            options.annotations,
                            config.sessions,
                            options.environ_map,
                            &source_pause_started_ns,
                            if (preparation) |*owned| owned.cacheLock() else null,
                        ) catch |err| {
                            state.clearSnapshot();
                            state.finish(.{ .err = err });
                            continue;
                        };
                        const completed_dir = if (request.publish_dir) |publish_dir| blk: {
                            const publish_metrics = control.publishSnapshot(&preparation.?, request.dir, publish_dir) catch |err| {
                                state.clearSnapshot();
                                state.finish(.{ .err = err });
                                continue;
                            };
                            if (prepared_root) |*root| options.disk_snapshot.?.commitSnapshotRoot(request.dir, root, if (options.environ_map != null) .shared_no_rebind else .local_rebind) catch |err| {
                                state.clearSnapshot();
                                state.finish(.{ .err = err });
                                continue;
                            };
                            vmm.logNamedSnapshotPublication("hvf", publish_metrics, source_pause_started_ns);
                            break :blk publish_dir;
                        } else request.dir;
                        state.clearSnapshot();
                        control.completeSnapshot(completed_dir) catch |err| {
                            state.finish(.{ .err = err });
                            continue;
                        };
                        continue;
                    }
                    return snapshotMultiHvfAndStop(allocator, options, vcpus, &state, &wake_set, redist_window.base, @intCast(redist_stride), request.dir, null);
                },
                .rootfs_snapshot => |request| {
                    const disk_manifest = takeRootfsSnapshotMulti(
                        allocator,
                        request.dir,
                        vcpus,
                        &state,
                        &wake_set,
                        options.transports,
                        options.disk_snapshot,
                    ) catch |err| {
                        state.clearSnapshot();
                        state.finish(.{ .err = err });
                        continue;
                    };
                    state.clearSnapshot();
                    control.completeRootfsSnapshot(disk_manifest) catch |err| {
                        state.finish(.{ .err = err });
                        continue;
                    };
                    continue;
                },
                .disk_fork => |request| {
                    captureMultiHvfDiskFork(
                        allocator,
                        options,
                        vcpus,
                        &state,
                        &wake_set,
                        redist_window.base,
                        @intCast(redist_stride),
                        request,
                        control,
                    ) catch |err| control.failDiskFork(err);
                    continue;
                },
            }
        }
        if (config.probe) |exec_probe| {
            const probe = exec_probe.stream;
            if (!exec_probe_done) {
                if (probe.state == .failed) {
                    state.finish(.{ .err = error.VsockProbeFailed });
                    continue;
                }
                if (probe.state == .complete) {
                    std.log.debug("hvf multi-vcpu probe completion timing: observed_ms={d}", .{probe.elapsedMs()});
                    if (exec_probe.on_complete == .stop) {
                        if (config.probeCaptureDir()) |dir| {
                            return snapshotMultiHvfAndStop(allocator, options, vcpus, &state, &wake_set, redist_window.base, @intCast(redist_stride), dir, null);
                        }
                        state.finish(.{ .exit = .probe_complete });
                        continue;
                    }
                    exec_probe_done = true;
                }
                if (!exec_probe_done and probe.state != .idle and probe.elapsedMs() > exec_probe.timeout_ms) {
                    state.finish(.{ .err = error.VsockProbeTimedOut });
                    continue;
                }
            }
        }
        if (config.captureRequest()) |request_capture| {
            if (request_capture.isAbortRequested()) {
                state.finish(.{ .err = error.CaptureAborted });
                continue;
            }
            if (request_capture.isRequested()) {
                return snapshotMultiHvfAndStop(allocator, options, vcpus, &state, &wake_set, redist_window.base, @intCast(redist_stride), config.capture.?.dir, request_capture);
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
    vcpus: []Vcpu,
    state: *MultiHvfRunState,
    wake_set: *HvfVcpuWakeSet,
    redist_base: u64,
    redist_stride: u64,
    snapshot_dir: []const u8,
    request_capture: ?*capture.Request,
) !ExitCause {
    takeSnapshotMulti(
        allocator,
        snapshot_dir,
        vcpus,
        state,
        wake_set,
        options.transports,
        options.gen_dev,
        options.vsock_dev,
        options.ram_bytes,
        .{ .dist_base = options.dist_base, .redist_base = redist_base, .redist_stride = redist_stride, .ram_size = options.prepared.ram_size },
        options.rootfs,
        options.disk_snapshot,
        null,
        options.network_manifest,
        options.annotations,
        options.prepared.config.sessions,
        options.environ_map,
        null,
        null,
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

fn waitHvfVcpusReady(vcpus: []Vcpu, state: *MultiHvfRunState) !void {
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

fn joinHvfVcpuThreads(vcpus: []Vcpu, wake_set: *HvfVcpuWakeSet) void {
    wake_set.wakeAll();
    for (vcpus) |*vcpu_entry| {
        if (vcpu_entry.thread) |thread| {
            thread.join();
            vcpu_entry.thread = null;
        }
    }
}

fn pauseHvfVcpusForSnapshot(vcpus: []Vcpu, state: *MultiHvfRunState, wake_set: *HvfVcpuWakeSet) !void {
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

fn captureHvfVcpuStates(allocator: std.mem.Allocator, vcpus: []Vcpu) ![]spore.VcpuState {
    const states = try allocator.alloc(spore.VcpuState, vcpus.len);
    for (vcpus, states) |*vcpu, *out| {
        var command = HvfVcpuCaptureCommand{ .allocator = allocator, .out = out };
        _ = try vcpu.submit(.{ .capture = &command });
    }
    normalizeHvfVtimerCounters(states);
    return states;
}

fn applyHvfVcpuStates(vcpus: []Vcpu, machine: spore.MachineStateMulti) !void {
    if (machine.vcpus.len != vcpus.len) return error.PlatformMismatch;
    const timer_plan = try planHvfVtimerRestore(machine.vcpus, snapshot.hostCounter());
    for (machine.vcpus, 0..) |vcpu_state, i| {
        if (vcpu_state.index != vcpus[i].index) return error.PlatformMismatch;
        var normalized_state = vcpu_state;
        snapshot.canonicalizeVtimer(&normalized_state.vtimer, timer_plan.canonical_cntvct);
        var command = HvfVcpuApplyCommand{ .state = normalized_state, .shared_vtimer_offset = timer_plan.shared_offset };
        _ = try vcpus[i].submit(.{ .apply = &command });
    }
}

const HvfVtimerRestorePlan = struct {
    canonical_cntvct: u64,
    shared_offset: u64,
};

fn planHvfVtimerRestore(states: []const spore.VcpuState, host_counter: u64) !HvfVtimerRestorePlan {
    if (states.len == 0) return error.PlatformMismatch;
    const canonical_cntvct = states[0].vtimer.cntvct;
    return .{
        .canonical_cntvct = canonical_cntvct,
        .shared_offset = snapshot.vtimerOffset(host_counter, canonical_cntvct),
    };
}

fn normalizeHvfVtimerCounters(states: []spore.VcpuState) void {
    if (states.len == 0) return;
    const canonical_cntvct = states[0].vtimer.cntvct;
    for (states) |*state| snapshot.canonicalizeVtimer(&state.vtimer, canonical_cntvct);
}

test "multi-vcpu HVF timer normalization uses one counter authority" {
    var states: [2]spore.VcpuState = undefined;
    states[0].vtimer = .{ .cntvct = 100, .cntv_ctl = 1, .cntv_cval = 130 };
    states[1].vtimer = .{ .cntvct = 140, .cntv_ctl = 3, .cntv_cval = 120 };
    const secondary_delta = states[1].vtimer.cntv_cval -% states[1].vtimer.cntvct;
    normalizeHvfVtimerCounters(&states);
    try std.testing.expectEqual(@as(u64, 100), states[0].vtimer.cntvct);
    try std.testing.expectEqual(@as(u64, 100), states[1].vtimer.cntvct);
    try std.testing.expectEqual(secondary_delta, states[1].vtimer.cntv_cval -% states[1].vtimer.cntvct);
    try std.testing.expectEqual(@as(u64, 3), states[1].vtimer.cntv_ctl);

    const plan = try planHvfVtimerRestore(&states, 175);
    try std.testing.expectEqual(@as(u64, 100), plan.canonical_cntvct);
    try std.testing.expectEqual(@as(u64, 75), plan.shared_offset);
    for (states) |state| {
        var normalized = state;
        snapshot.canonicalizeVtimer(&normalized.vtimer, plan.canonical_cntvct);
        try std.testing.expectEqual(plan.canonical_cntvct, normalized.vtimer.cntvct);
        try std.testing.expectEqual(plan.shared_offset, snapshot.vtimerOffset(175, normalized.vtimer.cntvct));
    }
}

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
        if (ctx.network.failed()) {
            ctx.state.finish(.{ .err = error.NetworkGatewayFailed });
            continue;
        }
        var flushed_network = false;
        ctx.device_lock.lock();
        if (ctx.network.consumeWake()) {
            flushNetworkRxHvf(ctx.net_dev, &ctx.transports[ctx.net_transport_index], ctx.ram, ctx.net_transport_index) catch |err| {
                ctx.device_lock.unlock();
                ctx.state.finish(.{ .err = err });
                return;
            };
            flushed_network = true;
        }
        ctx.device_lock.unlock();
        if (flushed_network) continue;
        const run_exit = ctx.vcpu.run(.{ .all = ctx.vcpus, .gic_windows = ctx.gic_windows }) catch |err| {
            ctx.state.finish(.{ .err = err });
            return;
        };
        if (ctx.state.stopped()) continue;
        switch (run_exit) {
            .mmio => |access| {
                ctx.device_lock.lock();
                const value = handleDeviceMmio(access, ctx.transports, ctx.gen_dev, ctx.ram) catch |err| {
                    ctx.device_lock.unlock();
                    ctx.state.finish(.{ .err = err });
                    return;
                };
                ctx.device_lock.unlock();
                ctx.vcpu.completeMmio(value) catch |err| {
                    ctx.state.finish(.{ .err = err });
                    return;
                };
            },
            .wfi => sleepMs(1),
            .shutdown => |kind| ctx.state.finish(.{ .exit = kind.cause() }),
            .handled, .kicked => {},
        }
    }
}

fn processHvfVcpuCommand(vcpu: *Vcpu, command: HvfVcpuCommand) void {
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
            snapshot.applyVcpuStateWithOffset(vcpu.handle, apply_cmd.state, apply_cmd.shared_vtimer_offset) catch |err| break :blk .{ .err = err };
            break :blk .ok;
        },
    };
    vcpu.command_slot.finish(result);
}

fn psciCpuOn(all: []Vcpu, target_mpidr: u64, entry: u64, context_id: u64) !u64 {
    const target_index = psciTargetIndex(all.len, target_mpidr) orelse return psci_ret_invalid_params;
    const target = &all[target_index];
    if (target.isRunning()) return psci_ret_already_on;
    _ = try target.submit(.{ .start = .{ .entry = entry, .arg0 = context_id } });
    var wake_set = HvfVcpuWakeSet{ .vcpus = all };
    wake_set.wakeAll();
    return 0;
}

fn psciTargetIndex(vcpu_count: usize, target_mpidr: u64) ?usize {
    if (((target_mpidr >> 32) & 0xff) != 0) return null;
    const affinity = target_mpidr & 0x00ff_ffff;
    if (affinity >= vcpu_count) return null;
    return @intCast(affinity);
}

/// Unhandled sysreg access: RAZ/WI. ISS bit 0 is direction (1 = read).
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

const DirtyTracker = struct {
    sealer: dirty_ram.Sealer,
    writable_chunks: []bool,
    tracking_start_ms: u64 = 0,
    mutex: vmm.SpinLock = .{},
    stats: DirtyStats = .{},

    const Options = struct {
        dir: []const u8,
        ram: []const u8,
        seed_ranges: ?[]const dirty_ram.ChunkRange = null,
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
        };
        @memset(tracker.writable_chunks, false);

        const protect_start = monotonicMs();
        try tracker.protectAll(hvf.MemoryFlags.rx);
        tracker.stats.seed_protect_ms = monotonicMs() - protect_start;
        tracker.tracking_start_ms = monotonicMs();

        std.log.info(
            "hvf dirty tracking started: mode=write-protect ram_mib={d} chunks={d} seed_nonzero_chunks={d} seed_ms={d} seed_protect_ms={d}",
            .{ options.ram.len / 1024 / 1024, tracker.sealer.chunkCount(), tracker.sealer.stats.seed_nonzero_chunks, tracker.sealer.stats.seed_ms, tracker.stats.seed_protect_ms },
        );
        return tracker;
    }

    fn deinit(self: *DirtyTracker) void {
        if (!self.sealer.finished) {
            _ = self.protectAll(hvf.MemoryFlags.rwx) catch {};
        }
        self.sealer.deinit();
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
        const tail_start = monotonicMs();
        try self.flushDirty();
        self.sealer.stats.tail_flush_ms = monotonicMs() - tail_start;
        self.sealer.finishRates(self.tracking_start_ms, monotonicMs());

        // Successful dirty-tracked snapshots are one-shot captures. Re-protecting
        // every chunk here makes suspend scale with configured RAM even when the
        // dirty tail is empty; unfinished teardown still restores permissions.
        return try self.sealer.finishBacking();
    }

    fn flushDirty(self: *DirtyTracker) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.sealer.hasDirtyChunks()) return;
        _ = try self.sealer.flushMarked(.{
            .before_seal = protectDirtyChunkForSeal,
            .before_seal_ctx = self,
        });
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

const SnapshotPlatform = struct {
    dist_base: u64,
    redist_base: u64,
    redist_stride: u64,
    ram_size: u64,
    memory_device: ?*const virtio_mem.Mem = null,
};

fn captureSingleHvfDiskFork(
    allocator: std.mem.Allocator,
    request: vsock_control.DiskForkAction,
    control: vsock_control.Control,
    vcpu: hvf.VcpuHandle,
    transports: []mmio.Transport,
    gen_dev: *const generation.Device,
    vsock_dev: *const vsock.Vsock,
    ram_bytes: []const u8,
    platform: SnapshotPlatform,
    config: *const vmm.Config,
    dirty_tracker: ?*DirtyTracker,
) !void {
    const disk = config.disk_snapshot orelse return error.BadManifest;
    const pause_started_ns = runtime_disk_fork_capture.monotonicNs();
    try takeSnapshot(
        allocator,
        request.dir,
        vcpu,
        transports,
        gen_dev,
        vsock_dev,
        ram_bytes,
        platform,
        config.rootfs,
        null,
        disk,
        config.network_manifest,
        config.annotations,
        config.sessions,
        dirty_tracker,
        config.environ_map,
        null,
    );
    const ram_capture_ns = runtime_disk_fork_capture.elapsedSince(pause_started_ns);
    var batch = try runtime_disk_fork_capture.prepare(allocator, disk, request.count, .{
        .allow_copy = request.allow_copy,
        .force_copy = request.force_copy,
    });
    defer batch.deinit();
    batch.pause_started_ns = pause_started_ns;
    batch.ram_capture_ns = ram_capture_ns;
    try control.completeDiskFork(&batch);
}

fn takeSnapshot(
    allocator: std.mem.Allocator,
    dir: []const u8,
    vcpu: hvf.VcpuHandle,
    transports: []mmio.Transport,
    gen_dev: *const generation.Device,
    vsock_dev: *const vsock.Vsock,
    ram_bytes: []const u8,
    platform: SnapshotPlatform,
    rootfs: ?spore.Rootfs,
    disk_snapshot: ?disk_layer.SnapshotState,
    quiescence_disk: ?disk_layer.SnapshotState,
    network_manifest: ?spore.Network,
    annotations: spore.Annotations,
    sessions: []const spore.Session,
    dirty_tracker: ?*DirtyTracker,
    environ_map: ?*const std.process.Environ.Map,
    rootfs_cache_lock: ?*const rootfs_mod.RootfsCacheLock,
) !void {
    try transport_snapshot.validateFullSnapshotDevices(transports, vsock_dev);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var pin_threaded = std.Io.Threaded.init(allocator, .{});
    defer pin_threaded.deinit();
    const pin_io = pin_threaded.io();

    const total_start = monotonicMs();
    const machine_start = total_start;
    const machine = try snapshot.captureMachine(arena, vcpu);
    const machine_ms = monotonicMs() - machine_start;
    const devices_start = monotonicMs();
    const devices = try vmm.captureTransports(arena, transports);
    const devices_ms = monotonicMs() - devices_start;
    var disk_quiesced = false;
    if (disk_snapshot orelse quiescence_disk) |disk_state| {
        if (!try spore.diskQueuesQuiescent(disk_state.base.device, devices)) {
            std.log.err("cannot snapshot writable rootfs-backed VM while virtio-blk has pending requests", .{});
            return error.DeviceStatePending;
        }
        disk_quiesced = true;
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
    const memory_state = if (platform.memory_device) |device| try device.captureState(arena, platform.ram_size) else null;
    if (environ_map) |environ| {
        try spore.writeLocalMemoryBackingProof(arena, environ, dir, memory, ram_bytes.len);
    }
    var owned_cache_lock: ?rootfs_mod.RootfsCacheLock = null;
    defer if (owned_cache_lock) |*lock| lock.deinit();
    const disk_root = if (disk_snapshot != null and environ_map != null) blk: {
        const cache_root = try local_paths.rootfsCacheRootPath(arena, environ_map.?);
        if (rootfs_cache_lock) |lock| {
            if (!try lock.ensureHeldFor(arena, cache_root)) return error.RootfsCacheLockNotHeld;
        } else owned_cache_lock = try rootfs_mod.lockRootfsCacheExclusive(pin_io, arena, cache_root);
        break :blk cache_root;
    } else dir;
    const disk_start = monotonicMs();
    const disk_manifest = if (disk_snapshot) |disk_state| try disk_state.finish(arena, disk_root, disk_quiesced) else null;
    const disk_ms = monotonicMs() - disk_start;
    const manifest_start = monotonicMs();
    const saved_manifest = spore.Manifest{
        .platform = .{
            .cpu_profile = board.cpu_profile,
            .device_model_version = board.device_model_version,
            .vcpu_count = 1,
            .ram_base = board.ram_base,
            .ram_size = platform.ram_size,
            .gic_dist_base = platform.dist_base,
            .gic_redist_base = platform.redist_base,
            .gic_redist_stride = platform.redist_stride,
            .counter_frequency_hz = snapshot.hostCounterFreq(),
        },
        .machine = .{ .single = machine },
        .devices = devices,
        .generation = gen_state,
        .annotations = annotations,
        .rootfs = rootfs,
        .disk = disk_manifest,
        .network = network_manifest,
        .sessions = sessions,
        .memory_state = memory_state,
        .memory = memory,
    };
    if (disk_manifest) |disk| {
        if (environ_map != null) {
            const registry = try saved_spore_pin.LockedRegistry.init(arena, disk_root, rootfs_cache_lock orelse &owned_cache_lock.?);
            try saved_spore_pin.publishManifest(pin_io, arena, registry, dir, disk, saved_manifest);
        } else try spore.saveManifest(arena, dir, saved_manifest);
    } else try spore.saveManifest(arena, dir, saved_manifest);
    const manifest_ms = monotonicMs() - manifest_start;
    const snapshot_total_ms = monotonicMs() - total_start;
    const memory_plan = try spore.validateMemoryForRam(memory, ram_bytes.len);
    if (dirty_tracker) |tracker| {
        const stats = tracker.stats;
        const ram_stats = tracker.sealer.stats;
        var metrics_head_buf: [2048]u8 = undefined;
        var metrics_tail_buf: [3072]u8 = undefined;
        const metrics_head = std.fmt.bufPrint(
            &metrics_head_buf,
            "hvf snapshot metrics: mode=write-protect ram_mib={d} chunks={d} nonzero_chunks={d} machine_ms={d} devices_ms={d} generation_ms={d} memory_ms={d} disk_ms={d} manifest_ms={d} snapshot_pause_ms={d} snapshot_total_ms={d} write_fault_count={d} dirty_chunks_total={d} host_dirty_ranges_total={d} host_dirty_chunks_total={d} sealed_chunks_total={d} seed_ms={d} seed_chunks={d} seed_nonzero_chunks={d} seed_protect_ms={d} tail_flush_ms={d}",
            .{
                platform.ram_size / 1024 / 1024,
                memory_plan.chunk_count,
                memory_plan.nonzero_chunk_count,
                machine_ms,
                devices_ms,
                generation_ms,
                memory_ms,
                disk_ms,
                manifest_ms,
                snapshot_total_ms,
                snapshot_total_ms,
                stats.write_fault_count,
                ram_stats.dirty_chunks_total,
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
            " seal_ms={d} protect_ms={d} seal_zero_scan_ms={d} seal_hash_ms={d} seal_chunk_write_ms={d} seal_backing_write_ms={d} seal_parallel_flush_count={d} seal_parallel_workers_max={d} finish_fchmod_ms={d} finish_close_ms={d} finish_close_deferred={d} finish_rename_ms={d} tracking_ms={d} dirty_chunks_per_sec={d} sealed_chunks_per_sec={d}",
            .{
                ram_stats.seal_ms,
                stats.protect_ms,
                ram_stats.sealZeroScanMs(),
                ram_stats.sealHashMs(),
                ram_stats.sealChunkWriteMs(),
                ram_stats.sealBackingWriteMs(),
                ram_stats.seal_parallel_flush_count,
                ram_stats.seal_parallel_workers_max,
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
            "hvf snapshot metrics: mode=full-scan ram_mib={d} chunks={d} nonzero_chunks={d} machine_ms={d} devices_ms={d} generation_ms={d} memory_ms={d} disk_ms={d} manifest_ms={d} snapshot_pause_ms={d} snapshot_total_ms={d}",
            .{
                platform.ram_size / 1024 / 1024,
                memory_plan.chunk_count,
                memory_plan.nonzero_chunk_count,
                machine_ms,
                devices_ms,
                generation_ms,
                memory_ms,
                disk_ms,
                manifest_ms,
                snapshot_total_ms,
                snapshot_total_ms,
            },
        );
    }
    std.log.info("spore written to {s}", .{dir});
}

fn takeRootfsSnapshotMulti(
    allocator: std.mem.Allocator,
    dir: []const u8,
    vcpus: []Vcpu,
    state: *MultiHvfRunState,
    wake_set: *HvfVcpuWakeSet,
    transports: []mmio.Transport,
    disk_snapshot: ?disk_layer.SnapshotState,
) !?spore.Disk {
    try pauseHvfVcpusForSnapshot(vcpus, state, wake_set);
    return try vmm.takeRootfsSnapshot(allocator, dir, transports, disk_snapshot);
}

fn takeSnapshotMulti(
    allocator: std.mem.Allocator,
    dir: []const u8,
    vcpus: []Vcpu,
    state: *MultiHvfRunState,
    wake_set: *HvfVcpuWakeSet,
    transports: []mmio.Transport,
    gen_dev: *const generation.Device,
    vsock_dev: *const vsock.Vsock,
    ram_bytes: []const u8,
    platform: SnapshotPlatform,
    rootfs: ?spore.Rootfs,
    disk_snapshot: ?disk_layer.SnapshotState,
    quiescence_disk: ?disk_layer.SnapshotState,
    network_manifest: ?spore.Network,
    annotations: spore.Annotations,
    sessions: []const spore.Session,
    environ_map: ?*const std.process.Environ.Map,
    pause_started_ns_out: ?*u64,
    rootfs_cache_lock: ?*const rootfs_mod.RootfsCacheLock,
) !void {
    try pauseHvfVcpusForSnapshot(vcpus, state, wake_set);
    if (pause_started_ns_out) |out| out.* = runtime_disk_fork_capture.monotonicNs();
    // Feature selection is guest-mutable MMIO state. Validate it only after
    // every vCPU has stopped, immediately before transport capture, so a guest
    // cannot race validation with a reset or DRIVER_FEATURES write.
    try transport_snapshot.validateFullSnapshotDevices(transports, vsock_dev);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var pin_threaded = std.Io.Threaded.init(allocator, .{});
    defer pin_threaded.deinit();
    const pin_io = pin_threaded.io();

    const total_start = monotonicMs();
    const machine_start = total_start;
    const vcpu_states = try captureHvfVcpuStates(arena, vcpus);
    const machine = try snapshot.captureMachineMulti(arena, vcpu_states);
    const machine_ms = monotonicMs() - machine_start;
    const devices_start = monotonicMs();
    const devices = try vmm.captureTransports(arena, transports);
    const devices_ms = monotonicMs() - devices_start;
    var disk_quiesced = false;
    if (disk_snapshot orelse quiescence_disk) |disk_state| {
        if (!try spore.diskQueuesQuiescent(disk_state.base.device, devices)) {
            std.log.err("cannot snapshot writable rootfs-backed VM while virtio-blk has pending requests", .{});
            return error.DeviceStatePending;
        }
        disk_quiesced = true;
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
        try spore.writeLocalMemoryBackingProof(arena, environ, dir, memory, platform.ram_size);
    }
    var owned_cache_lock: ?rootfs_mod.RootfsCacheLock = null;
    defer if (owned_cache_lock) |*lock| lock.deinit();
    const disk_root = if (disk_snapshot != null and environ_map != null) blk: {
        const cache_root = try local_paths.rootfsCacheRootPath(arena, environ_map.?);
        if (rootfs_cache_lock) |lock| {
            if (!try lock.ensureHeldFor(arena, cache_root)) return error.RootfsCacheLockNotHeld;
        } else owned_cache_lock = try rootfs_mod.lockRootfsCacheExclusive(pin_io, arena, cache_root);
        break :blk cache_root;
    } else dir;
    const disk_start = monotonicMs();
    const disk_manifest = if (disk_snapshot) |disk_state| try disk_state.finish(arena, disk_root, disk_quiesced) else null;
    const disk_ms = monotonicMs() - disk_start;
    const manifest_start = monotonicMs();
    const saved_manifest = spore.Manifest{
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
        .machine = .{ .multi = machine },
        .devices = devices,
        .generation = gen_state,
        .annotations = annotations,
        .rootfs = rootfs,
        .disk = disk_manifest,
        .network = network_manifest,
        .sessions = sessions,
        .memory = memory,
    };
    if (disk_manifest) |disk| {
        if (environ_map != null) {
            const registry = try saved_spore_pin.LockedRegistry.init(arena, disk_root, rootfs_cache_lock orelse &owned_cache_lock.?);
            try saved_spore_pin.publishManifest(pin_io, arena, registry, dir, disk, saved_manifest);
        } else try spore.saveManifest(arena, dir, saved_manifest);
    } else try spore.saveManifest(arena, dir, saved_manifest);
    const manifest_ms = monotonicMs() - manifest_start;
    const snapshot_total_ms = monotonicMs() - total_start;
    const memory_plan = try spore.validateMemoryForRam(memory, ram_bytes.len);
    std.log.info(
        "hvf snapshot metrics: version=1 vcpus={d} mode=full-scan ram_mib={d} chunks={d} nonzero_chunks={d} machine_ms={d} devices_ms={d} generation_ms={d} memory_ms={d} disk_ms={d} manifest_ms={d} snapshot_total_ms={d}",
        .{
            vcpus.len,
            platform.ram_size / 1024 / 1024,
            memory_plan.chunk_count,
            memory_plan.nonzero_chunk_count,
            machine_ms,
            devices_ms,
            generation_ms,
            memory_ms,
            disk_ms,
            manifest_ms,
            snapshot_total_ms,
        },
    );
    std.log.info("spore written to {s}", .{dir});
}

fn captureMultiHvfDiskFork(
    allocator: std.mem.Allocator,
    options: MultiHvfRunOptions,
    vcpus: []Vcpu,
    state: *MultiHvfRunState,
    wake_set: *HvfVcpuWakeSet,
    redist_base: u64,
    redist_stride: u64,
    request: vsock_control.DiskForkAction,
    control: vsock_control.Control,
) !void {
    const disk = options.disk_snapshot orelse return error.BadManifest;
    const pause_started_ns = runtime_disk_fork_capture.monotonicNs();
    defer state.clearSnapshot();
    try takeSnapshotMulti(
        allocator,
        request.dir,
        vcpus,
        state,
        wake_set,
        options.transports,
        options.gen_dev,
        options.vsock_dev,
        options.ram_bytes,
        .{
            .dist_base = options.dist_base,
            .redist_base = redist_base,
            .redist_stride = redist_stride,
            .ram_size = options.prepared.ram_size,
        },
        options.rootfs,
        null,
        disk,
        options.network_manifest,
        options.annotations,
        options.prepared.config.sessions,
        options.environ_map,
        null,
        null,
    );
    const ram_capture_ns = runtime_disk_fork_capture.elapsedSince(pause_started_ns);
    var batch = try runtime_disk_fork_capture.prepare(allocator, disk, request.count, .{
        .allow_copy = request.allow_copy,
        .force_copy = request.force_copy,
    });
    defer batch.deinit();
    batch.pause_started_ns = pause_started_ns;
    batch.ram_capture_ns = ram_capture_ns;
    try control.completeDiskFork(&batch);
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
    transport_index: u32,
) !bool {
    if (vsock_dev.flushPendingRx(transport, ram)) {
        try hvf.check(hvf.hv_gic_set_spi(board.virtioDeviceIntid(transport_index), true), "raise vsock spi");
        return true;
    }
    return false;
}

fn wakeAfterVsockRxDelivery(delivered: bool, wake: vsock_control.Wake) void {
    if (delivered) wake.wake();
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
    transport_index: usize,
) !void {
    if (net_dev.flushPendingRx(transport, ram)) {
        try hvf.check(hvf.hv_gic_set_spi(board.virtioDeviceIntid(@intCast(transport_index)), true), "raise net spi");
    }
}

fn advancePc(vcpu: hvf.VcpuHandle) !void {
    var pc: u64 = undefined;
    try hvf.check(hvf.hv_vcpu_get_reg(vcpu, .pc, &pc), "get pc");
    try hvf.check(hvf.hv_vcpu_set_reg(vcpu, .pc, pc + 4), "set pc");
}

const GicWindows = struct {
    dist_base: u64,
    dist_size: u64,
    redist_base: u64,
    redist_size: u64,
    redist_stride: u64 = 0,
    redist_vcpus: ?[]Vcpu = null,
};

const GicMmioTarget = struct {
    region: gic.Region,
    offset: u64,
    vcpu: hvf.VcpuHandle,
    owner: ?*Vcpu = null,
};

const MmioAccess = struct {
    sas: u2,
    srt: u5,
    is_write: bool,
    ipa: u64,
};

/// Decodes a data-abort exit into an MMIO access. ESR ISS layout per Arm
/// ARM D17.2.37.
fn decodeMmioAccess(exit: *const hvf.VcpuExit) !MmioAccess {
    const syndrome = exit.exception.syndrome;
    const isv = syndrome & (1 << 24) != 0;
    if (!isv) {
        std.log.err("data abort without ISV at ipa=0x{x}", .{exit.exception.physical_address});
        return error.UnhandledMmio;
    }
    return .{
        .sas = @truncate(syndrome >> 22),
        .srt = @truncate(syndrome >> 16),
        .is_write = syndrome & (1 << 6) != 0,
        .ipa = exit.exception.physical_address,
    };
}

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

fn redistributorOwner(vcpus: []Vcpu, frame_base: u64) ?*Vcpu {
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

fn gicTargetOwnerForCommand(current_owner: ?*Vcpu, target: GicMmioTarget) ?*Vcpu {
    if (target.region != .redistributor) return null;
    const current = current_owner orelse return null;
    const owner = target.owner orelse return null;
    if (owner.index == current.index) return null;
    return owner;
}

fn readGicMmioTarget(current_owner: ?*Vcpu, target: GicMmioTarget, size_log2: u2) !u64 {
    if (gicTargetOwnerForCommand(current_owner, target)) |owner| {
        return (try owner.submit(.{ .gic_read = .{ .region = target.region, .offset = target.offset, .size_log2 = size_log2 } })) orelse 0;
    }
    return gic.mmioRead(target.region, target.vcpu, target.offset, size_log2);
}

fn writeGicMmioTarget(current_owner: ?*Vcpu, target: GicMmioTarget, value: u64) !void {
    if (gicTargetOwnerForCommand(current_owner, target)) |owner| {
        _ = try owner.submit(.{ .gic_write = .{ .region = target.region, .offset = target.offset, .value = value } });
        return;
    }
    gic.mmioWrite(target.region, target.vcpu, target.offset, value);
}

fn handleGicMmioAccess(
    vcpu: hvf.VcpuHandle,
    access: MmioAccess,
    gic_windows: GicWindows,
    current_owner: ?*Vcpu,
) !bool {
    const g = (try gicMmioTarget(vcpu, access.ipa, gic_windows)) orelse return false;
    if (access.is_write) {
        var value: u64 = 0;
        if (access.srt < 31) {
            try hvf.check(hvf.hv_vcpu_get_reg(vcpu, @enumFromInt(@as(u32, access.srt)), &value), "gic read xt");
        }
        try writeGicMmioTarget(current_owner, g, value);
    } else if (access.srt < 31) {
        const value = try readGicMmioTarget(current_owner, g, access.sas);
        const masked: u64 = switch (access.sas) {
            0 => value & 0xff,
            1 => value & 0xffff,
            2 => value & 0xffff_ffff,
            3 => value,
        };
        try hvf.check(hvf.hv_vcpu_set_reg(vcpu, @enumFromInt(@as(u32, access.srt)), masked), "gic write xt");
    }
    try advancePc(vcpu);
    return true;
}

fn dataAbortExitForTest(ipa: u64, sas: u2, srt: u5, is_write: bool) hvf.VcpuExit {
    var syndrome = (@as(u64, @intCast(hvf.ec_data_abort)) << 26) |
        (@as(u64, 1) << 24) |
        (@as(u64, @intCast(sas)) << 22) |
        (@as(u64, @intCast(srt)) << 16);
    if (is_write) syndrome |= @as(u64, 1) << 6;
    return .{
        .reason = .exception,
        .exception = .{
            .syndrome = syndrome,
            .virtual_address = ipa,
            .physical_address = ipa,
        },
    };
}

test "psci target index accepts normalized mpidr affinity" {
    try std.testing.expectEqual(@as(?usize, 1), psciTargetIndex(2, 1));
    try std.testing.expectEqual(@as(?usize, 1), psciTargetIndex(2, aarch64_topology.mpidrForIndex(1)));
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
    var vcpus = [_]Vcpu{
        .{ .redist_base = 0x0803_0000 },
        .{ .redist_base = 0x0801_0000 },
    };
    const window = try hvfRedistributorWindow(&vcpus, 0x2_0000);
    try std.testing.expectEqual(@as(u64, 0x0801_0000), window.base);
    try std.testing.expectEqual(@as(u64, 0x4_0000), window.size);
}

test "multi-vcpu network wake preserves completed HVF MMIO exit" {
    var exit = dataAbortExitForTest(board.virtio_base + 0x050, 2, 3, true);
    try std.testing.expectEqual(hvf.ec_data_abort, exit.exception.exceptionClass());
    try std.testing.expectEqual(HvfPostRunAction.dispatch_exit, hvfPostRunAction(exit.reason));
    const access = try decodeMmioAccess(&exit);
    try std.testing.expect(access.is_write);
    try std.testing.expectEqual(board.virtio_base + 0x050, access.ipa);

    // A canceled return has no completed guest exit; its still-pending network
    // wake is consumed by the pre-run flush on the next iteration.
    try std.testing.expectEqual(HvfPostRunAction.resume_before_run, hvfPostRunAction(.canceled));
}

const TestVsockWakeCounter = struct {
    count: usize = 0,

    fn wake(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.count += 1;
    }
};

test "multi-vcpu vsock delivery wakes once per delivered batch" {
    var counter = TestVsockWakeCounter{};
    const wake = vsock_control.Wake{ .context = &counter, .wakeFn = TestVsockWakeCounter.wake };

    wakeAfterVsockRxDelivery(false, wake);
    try std.testing.expectEqual(@as(usize, 0), counter.count);

    wakeAfterVsockRxDelivery(true, wake);
    try std.testing.expectEqual(@as(usize, 1), counter.count);
    wakeAfterVsockRxDelivery(true, wake);
    try std.testing.expectEqual(@as(usize, 2), counter.count);
}

test "gic data-abort classification routes remote redistributor before device lock" {
    var vcpus = [_]Vcpu{
        .{ .index = 0, .handle = 11, .redist_base = 0x0802_0000 },
        .{ .index = 1, .handle = 22, .redist_base = 0x0804_0000 },
    };
    var exit = dataAbortExitForTest(0x0802_0000 + 0x2_0000 + 0xc, 2, 3, false);
    const access = try decodeMmioAccess(&exit);
    try std.testing.expectEqual(@as(u2, 2), access.sas);
    try std.testing.expectEqual(@as(u5, 3), access.srt);
    try std.testing.expect(!access.is_write);

    const target = (try gicMmioTarget(11, access.ipa, .{
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
    try std.testing.expectEqual(@as(topology.VcpuIndex, 1), target.owner.?.index);
}

/// Emulates a generation, virtio-mmio or stray device register access and
/// returns the value a read sees.
fn handleDeviceMmio(
    access: vmm.Mmio,
    transports: []mmio.Transport,
    gen_dev: *generation.Device,
    ram: guestmem.GuestRam,
) !u64 {
    const ipa = access.addr;

    if (ipa >= board.generation_base and ipa < board.generation_base + board.generation_size) {
        const offset = ipa - board.generation_base;
        if (access.write) |value| {
            if (gen_dev.write(offset, value, access.size_log2)) {
                try hvf.check(hvf.hv_gic_set_spi(board.generationIntid(), false), "generation lower spi");
            }
            return 0;
        }
        return gen_dev.read(offset, access.size_log2);
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
        if (access.write) |value| {
            const raised = t.write(offset, @truncate(value), ram);
            if (raised) {
                try hvf.check(hvf.hv_gic_set_spi(board.virtioDeviceIntid(@intCast(idx)), true), "raise spi");
            }
            // Interrupt ack lowers the line (covers level semantics too).
            if (offset == 0x064) {
                try hvf.check(hvf.hv_gic_set_spi(board.virtioDeviceIntid(@intCast(idx)), false), "lower spi");
            }
            return 0;
        }
        return t.read(offset);
    }

    // Unknown MMIO: reads as zero, writes ignored. Loud once per boot
    // would be better; log at debug to keep bring-up output readable.
    std.log.debug("stray mmio {s} at ipa=0x{x}", .{ if (access.write != null) "write" else "read", ipa });
    return 0;
}
