//! HVF virtual machine: board assembly and vCPU run loop.
//!
//! Boots the pinned kernel with the SporeVM board (GICv3 via hv_gic,
//! virtio-mmio console/blk/net/vsock/rng, generation MMIO), handles MMIO data
//! aborts, PSCI over HVC, vtimer exits, WFI, and HVF snapshot/resume.
//! Multi-vCPU capture/resume uses `machine.multi` with same-HVF private GIC state.

const std = @import("std");
const aarch64_topology = @import("../aarch64/topology.zig");
const capture = @import("../capture.zig");
const dirty_ram = @import("../dirty_ram.zig");
const runtime_disk_fork_capture = @import("../runtime_disk_fork_capture.zig");
const hvf = @import("hvf.zig");
const gic = @import("gic.zig");
const board = @import("../aarch64/board.zig");
const boot = @import("../aarch64/boot.zig");
const gicv3 = @import("../aarch64/gicv3.zig");
const guestmem = @import("../guestmem.zig");
const net = @import("../virtio/net.zig");
const virtio_mem = @import("../virtio/mem.zig");
const vsock = @import("../virtio/vsock.zig");
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

    // The board fixes the GIC layout; the framework sizes and aligns it.
    // Created before any vCPU.
    const gic_start = monotonicMs();
    var dist_size: usize = 0;
    var dist_align: usize = 0;
    var redist_size: usize = 0;
    var redist_align: usize = 0;
    try hvf.check(hvf.hv_gic_get_distributor_size(&dist_size), "gic dist size");
    try hvf.check(hvf.hv_gic_get_distributor_base_alignment(&dist_align), "gic dist align");
    try hvf.check(hvf.hv_gic_get_redistributor_region_size(&redist_size), "gic redist size");
    try hvf.check(hvf.hv_gic_get_redistributor_base_alignment(&redist_align), "gic redist align");

    const dist_base = board.gic_dist_base;
    const redist_base = board.gic_redist_base;
    if (dist_size != board.gic_dist_size or dist_base % dist_align != 0 or redist_base % redist_align != 0) {
        std.log.err("HVF GIC cannot use the board layout: distributor size=0x{x} align=0x{x} redistributor align=0x{x}", .{ dist_size, dist_align, redist_align });
        return error.UnsupportedHost;
    }

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
    var vm: Vm = .{};
    var hotplug: ?vmm.Hotplug(Vm) = if (prepared.virtio_mem_region_size > 0) .{
        .vm = &vm,
        .bytes = @alignCast(ram_bytes[initial_ram_len..]),
        .guest_addr = board.ram_base + prepared.ram_size,
    } else null;
    defer if (hotplug) |*region| region.deinit();

    const devices_start = monotonicMs();
    var devices: vmm.Devices = undefined;
    devices.init(config, if (hotplug) |*region| region.memConfig() else null);
    defer devices.net.shutdown();
    const transports = devices.transports();
    const net_dev = &devices.net;
    const vsock_dev = &devices.vsock;
    const mem_dev = &devices.mem;
    const gen_dev = &devices.gen;
    const net_transport_index = devices.net_index;
    const vsock_transport_index = devices.vsock_index;
    const mem_transport_index = devices.mem_index;
    const devices_ms = monotonicMs() - devices_start;

    if (prepared.vcpus != 1) {
        return runMultiVcpu(allocator, .{
            .vm = &vm,
            .prepared = &prepared,
            .restore_stats = &restore_stats,
            .devices = &devices,
            .ram = ram,
            .ram_bytes = ram_bytes,
            .ram_file_backed = ram_mapping.file_backed,
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
    try requireBoardRedistributors(.{ .base = vcpu_redist_base, .size = redist_stride }, redist_stride, 1);

    std.log.debug(
        "gic: dist=0x{x}+0x{x} redist(vcpu0)=0x{x}+0x{x} (region 0x{x}+0x{x})",
        .{ dist_base, dist_size, vcpu_redist_base, redist_stride, redist_base, redist_size },
    );
    const vcpu_ms = monotonicMs() - vcpu_start;
    vm.gic_windows = .{
        .dist_base = dist_base,
        .dist_size = dist_size,
        .redist_base = vcpu_redist_base,
        .redist_size = redist_stride,
    };
    const vcpus = (&primary)[0..1];

    var boot_ms: u64 = 0;
    if (prepared.manifest) |parsed| {
        const restore = config.start.restore;
        // Restore: memory, device, GIC, and vCPU state from the spore.
        const m = parsed.value;
        try platform_contract.checkManifest(m, platform_contract.contract(1, prepared.ram_size, snapshot.hostCounterFreq()), transports.len);
        try vmm.restoreMemory(allocator, restore, m.memory, ram_bytes, ram_mapping.file_backed, &restore_stats);
        const state_start = monotonicMs();
        if (m.memory_state) |state| try mem_dev.restoreState(state);
        try vmm.applyTransports(transports, m.devices, ram);
        try gen_dev.restore(allocator, restore.generation orelse m.generation);
        if (restore.generation == null) try spore.refreshResumeParams(allocator, gen_dev);
        try vmm.restoreMachine(allocator, &vm, vcpus, m.machine);
        try vmm.raiseGenerationIrqIfPending(&vm, gen_dev);
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
            .gic = try board.gicLayout(prepared.vcpus),
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
            }, .{});
            if (dirty_tracker) |*tracker| {
                ram.dirty_context = tracker;
                ram.dirty_fn = DirtyTracker.markGuestWriteCallback;
            }
        }
        boot_ms = monotonicMs() - boot_start;
    }

    const tracker_ref: ?*DirtyTracker = if (dirty_tracker) |*tracker| tracker else null;
    vm.dirty_tracker = tracker_ref;
    const snapshot_source = vmm.SnapshotSource{
        .config = config,
        .transports = transports,
        .gen_dev = gen_dev,
        .vsock_dev = vsock_dev,
        .ram_bytes = ram_bytes,
        .ram_size = prepared.ram_size,
        .memory_device = if (mem_transport_index != null) mem_dev else null,
    };
    const start_ms = monotonicMs();
    vmm.emitRestoreMetrics("hvf", &prepared, &restore_stats, start_ms);
    var attach_probe_ms: u64 = 0;
    if (config.probe) |probe| {
        if (probe.start == .immediate) {
            const attach_probe_start = monotonicMs();
            try vsock_dev.attachHostStream(probe.stream);
            probe.stream.markStarted();
            _ = try vmm.flushRx(&vm, vsock_dev, transports, vsock_transport_index, ram);
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
            _ = try vmm.flushRx(&vm, vsock_dev, transports, vsock_transport_index, ram);
        }
        if (mem_transport_index != null) {
            if (config.probeStream()) |probe| {
                const new_pressure_events = probe.memory_pressure_count -| handled_memory_pressure_count;
                if (new_pressure_events > 0 and probe.state == .connected) {
                    const idx = mem_transport_index.?;
                    requested_hotplug_size = virtio_mem.requestedSizeAfterPressure(requested_hotplug_size, @intCast(hotplug.?.bytes.len), new_pressure_events);
                    handled_memory_pressure_count = probe.memory_pressure_count;
                    try mem_dev.setRequestedSize(@intCast(requested_hotplug_size));
                    _ = transports[idx].raiseConfigChange();
                    try vm.setSpi(board.virtioDeviceIntid(@intCast(idx)), true);
                    std.log.debug("virtio-mem requested hotplug size: bytes={d} pressure_count={d}", .{ requested_hotplug_size, handled_memory_pressure_count });
                }
            }
        }
        if (config.network.failed()) return error.NetworkGatewayFailed;
        if (config.network.consumeWake()) {
            _ = try vmm.flushRx(&vm, net_dev, transports, net_transport_index, ram);
            continue;
        }
        if (config.exec_control) |control| {
            control.reportStats(vmm.monitorStats(if (tracker_ref) |tracker| &tracker.sealer else null));
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
                    try vmm.writeSnapshot(allocator, "hvf", &vm, vcpus, tracker_ref, snapshot_source, .{
                        .dir = request.dir,
                        .rootfs_cache_lock = if (preparation) |*owned| owned.cacheLock() else null,
                    });
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
                    const pause_started_ns = runtime_disk_fork_capture.monotonicNs();
                    vmm.captureDiskFork(allocator, "hvf", &vm, vcpus, tracker_ref, snapshot_source, request, control, pause_started_ns) catch |err| control.failDiskFork(err);
                },
            }
            _ = try vmm.flushRx(&vm, vsock_dev, transports, vsock_transport_index, ram);
        }
        if (config.captureRequest()) |request_capture| {
            if (request_capture.isAbortRequested()) return error.CaptureAborted;
            if (request_capture.isRequested() and !did_capture_request) {
                try vmm.writeSnapshot(allocator, "hvf", &vm, vcpus, tracker_ref, snapshot_source, .{ .dir = config.capture.?.dir });
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
                            try vmm.writeSnapshot(allocator, "hvf", &vm, vcpus, tracker_ref, snapshot_source, .{ .dir = dir });
                            return .snapshotted;
                        }
                        return .probe_complete;
                    }
                    // A detached stream stays attached until the control
                    // replaces or resets it.
                    exec_probe_done = true;
                }
                if (!exec_probe_done and probe.state != .idle and probe.elapsedMs() > exec_probe.timeout_ms) return error.VsockProbeTimedOut;
            }
        }
        if (prepared.restoring() and config.probe != null and !logged_first_vcpu_entry) {
            logged_first_vcpu_entry = true;
            std.log.debug("hvf exec probe timing: first_vcpu_entry_ms={d}", .{monotonicMs() -| start_ms});
        }
        const run_exit = try primary.run(&vm, vcpus);
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
            .mmio => |access| try primary.completeMmio(try vmm.dispatchMmio(&vm, access, transports, gen_dev, ram)),
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
                    _ = try vmm.flushRx(&vm, net_dev, transports, net_transport_index, ram);
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

const HvfVcpuCommand = union(enum) {
    start: HvfVcpuStartCommand,
    gic_read: HvfVcpuGicReadCommand,
    gic_write: HvfVcpuGicWriteCommand,
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
                target.kick();
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

/// What the shared core needs from the HVF VM: the GIC windows a vCPU
/// emulates, the guest counter offset every vCPU shares, interrupt lines and
/// the virtio-mem mapping. HVF has one VM per process, so most calls need no
/// handle.
const Vm = struct {
    /// Set once the vCPUs exist.
    gic_windows: GicWindows = undefined,
    /// Host counter minus guest counter; a restore sets it on every vCPU.
    vtimer_offset: u64 = 0,
    dirty_tracker: ?*DirtyTracker = null,

    pub const name = "hvf";
    /// `hv_gic_set_spi` does not interrupt a running vCPU.
    pub const spi_needs_kick = true;

    pub fn setSpi(_: *const Vm, intid: u32, level: bool) !void {
        try hvf.check(hvf.hv_gic_set_spi(intid, level), "hv_gic_set_spi");
    }

    /// Maps only the newly plugged tail.
    pub fn mapHotplug(_: *const Vm, bytes: []u8, guest_addr: u64, mapped_bytes: u64, new_bytes: u64) !void {
        const offset: usize = @intCast(mapped_bytes);
        const len: usize = @intCast(new_bytes - mapped_bytes);
        try hvf.check(
            hvf.hv_vm_map(bytes[offset..][0..len].ptr, guest_addr + mapped_bytes, len, hvf.MemoryFlags.rwx),
            "hv_vm_map virtio-mem",
        );
    }

    pub fn unmapHotplug(_: *const Vm, guest_addr: u64, mapped_bytes: u64) void {
        _ = hvf.hv_vm_unmap(guest_addr, mapped_bytes);
    }

    pub fn captureGic(_: *const Vm, arena: std.mem.Allocator, _: usize) !gicv3.State {
        return snapshot.captureGicState(arena);
    }

    pub fn applyGic(_: *const Vm, allocator: std.mem.Allocator, vcpus: []const Vcpu, state: gicv3.State) !void {
        try snapshot.applyGicState(allocator, vcpus[0].handle, state);
    }

    pub fn setCounter(self: *Vm, guest_cntvct: u64) !void {
        self.vtimer_offset = snapshot.hostCounter() -% guest_cntvct;
    }
};

const Vcpu = struct {
    index: topology.VcpuIndex = 0,
    handle: hvf.VcpuHandle = 0,
    exit: *hvf.VcpuExit = undefined,
    redist_base: u64 = 0,
    created: bool = false,
    ready: std.atomic.Value(bool) = .init(false),
    run_state: std.atomic.Value(u8) = .init(hvf_vcpu_state_off),
    command_slot: HvfVcpuCommandSlot = .{},
    /// The device access the last `.mmio` exit reported.
    mmio_access: MmioAccess = undefined,
    /// HVF accepts vCPU calls only on the thread that created the vCPU.
    owner_thread: std.Thread.Id = undefined,

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

    /// Creates the vCPU on the thread that will own it.
    pub fn threadStart(self: *Vcpu) !void {
        errdefer self.destroyOnOwnerThread();
        try self.createOnOwnerThread();
        self.ready.store(true, .release);
    }

    pub fn threadExit(self: *Vcpu) void {
        self.destroyOnOwnerThread();
    }

    /// Serves one start or GIC request another thread submitted; returns
    /// whether there was one.
    pub fn handleCommands(self: *Vcpu) bool {
        const command = self.command_slot.take() orelse return false;
        processHvfVcpuCommand(self, command);
        return true;
    }

    /// Captures the stopped vCPU.
    pub fn capture(self: *Vcpu, _: *const Vm, arena: std.mem.Allocator) !spore.VcpuState {
        self.assertOwnerThread();
        return snapshot.captureVcpuState(arena, .{ .index = self.index, .handle = self.handle });
    }

    /// Restores the vCPU on the VM's shared counter; it then runs.
    pub fn apply(self: *Vcpu, vm: *const Vm, state: spore.VcpuState) !void {
        self.assertOwnerThread();
        try snapshot.applyVcpuState(self.handle, state, vm.vtimer_offset);
        self.setRunning();
    }

    pub fn kick(self: *const Vcpu) void {
        if (!self.ready.load(.acquire)) return;
        var handles = [_]hvf.VcpuHandle{self.handle};
        _ = hvf.hv_vcpus_exit(&handles, handles.len);
    }

    /// Runs the guest once. The vtimer, unknown sysregs, PSCI, GIC MMIO and
    /// dirty-tracking write faults are handled here; device MMIO is returned
    /// to the loop and finished with `completeMmio`. `all` is every vCPU, for
    /// PSCI CPU_ON and redistributor forwarding. A vCPU that PSCI has turned
    /// off returns `.wfi`.
    pub fn run(self: *Vcpu, vm: *const Vm, all: []Vcpu) !vmm.Exit {
        self.assertOwnerThread();
        if (all.len > 1 and !self.isRunning()) return .wfi;
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
                        if (vm.dirty_tracker) |tracker| {
                            if (try WriteProtect.handleWriteFault(tracker, exit.exception.syndrome, exit.exception.physical_address)) return .handled;
                        }
                        const access = try decodeMmioAccess(exit);
                        // Redistributor MMIO can forward to another vCPU and wait
                        // for completion, so it stays out of the loop's device lock.
                        if (try handleGicMmioAccess(self.handle, access, vm.gic_windows, self)) return .handled;
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
                    hvf.ec_hvc => return self.psci(all),
                    hvf.ec_smc => {
                        // Treat SMC like HVC but advance PC (trapped SMC
                        // returns to the same instruction).
                        const result = try self.psci(all);
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
    pub fn completeMmio(self: *Vcpu, value: u64) !void {
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

/// The framework assigns each vCPU's redistributor frames from its MPIDR;
/// they must land where the board says they are.
fn requireBoardRedistributors(window: HvfRedistributorWindow, stride: u64, vcpu_count: topology.VcpuCount) !void {
    const board_size = try board.redistributorRegionSize(board.gic_redist_stride, vcpu_count);
    if (window.base == board.gic_redist_base and window.size == board_size and stride == board.gic_redist_stride) return;
    std.log.err(
        "HVF placed the GIC redistributors at 0x{x}+0x{x} stride=0x{x}; the board needs 0x{x}+0x{x} stride=0x{x}",
        .{ window.base, window.size, stride, board.gic_redist_base, board_size, board.gic_redist_stride },
    );
    return error.UnsupportedHost;
}

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

const Threaded = vmm.Threaded(Vm, Vcpu, DirtyTracker);

const MultiHvfRunOptions = struct {
    vm: *Vm,
    prepared: *const vmm.Prepared,
    restore_stats: *?vmm.RestoreStats,
    devices: *vmm.Devices,
    ram: guestmem.GuestRam,
    ram_bytes: []align(std.heap.page_size_min) u8,
    ram_file_backed: bool,
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

/// Runs a VM with more than one vCPU on the shared threaded loop. HVF
/// creates each vCPU on its own thread, so the GIC layout, boot and restore
/// wait for the threads.
fn runMultiVcpu(allocator: std.mem.Allocator, options: MultiHvfRunOptions) !ExitCause {
    const config = &options.prepared.config;
    const vm = options.vm;
    const devices = options.devices;
    const transports = devices.transports();
    const vcpus = try allocator.alloc(Vcpu, options.prepared.vcpus);
    defer allocator.free(vcpus);
    for (vcpus, 0..) |*vcpu, index| vcpu.* = .{ .index = @intCast(index) };

    var threaded: Threaded = .{ .vm = vm, .vcpus = vcpus, .devices = devices, .ram = options.ram, .config = config };
    defer threaded.deinit(allocator);
    try threaded.start(allocator);

    const vcpu_start = monotonicMs();
    var redist_stride: usize = 0;
    try hvf.check(hvf.hv_gic_get_redistributor_size(&redist_stride), "gic redist stride");
    const redist_window = try hvfRedistributorWindow(vcpus, @intCast(redist_stride));
    if (redist_window.size > options.redist_region_size) return error.UnsupportedVcpuCount;
    try requireBoardRedistributors(redist_window, redist_stride, @intCast(vcpus.len));
    const vcpu_ms = monotonicMs() - vcpu_start;
    vm.gic_windows = .{
        .dist_base = options.dist_base,
        .dist_size = options.dist_size,
        .redist_base = redist_window.base,
        .redist_size = redist_window.size,
        .redist_stride = @intCast(redist_stride),
        .redist_vcpus = vcpus,
    };
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
        try platform_contract.checkManifest(manifest.*, platform_contract.contract(options.prepared.vcpus, options.prepared.ram_size, snapshot.hostCounterFreq()), transports.len);
        // HVF restores only its own private GIC blob.
        if (machine.gic.kind != .backend_private) return error.PlatformMismatch;
        try vmm.restoreMemory(allocator, restore, manifest.memory, options.ram_bytes, options.ram_file_backed, options.restore_stats);
        const state_start = monotonicMs();
        try vmm.applyTransports(transports, manifest.devices, options.ram);
        try devices.gen.restore(allocator, restore.generation orelse manifest.generation);
        if (restore.generation == null) try spore.refreshResumeParams(allocator, &devices.gen);
        try threaded.restore(allocator, manifest.machine);
        try vmm.raiseGenerationIrqIfPending(vm, &devices.gen);
        if (options.restore_stats.*) |*stats| stats.state_ms = monotonicMs() - state_start;
        boot_ms = monotonicMs() - restore_start;
    } else {
        const fresh = config.start.boot;
        const boot_start = monotonicMs();
        const initrd_range = if (fresh.initrd) |initrd| try boot.planInitrd(options.ram.bytes.len, board.ram_base, fresh.kernel, initrd.len) else null;
        const dtb = try board.buildDtb(allocator, .{
            .ram_size = options.prepared.ram_size,
            .cpu_count = options.prepared.vcpus,
            .gic = try board.gicLayout(options.prepared.vcpus),
            .virtio_count = @intCast(transports.len),
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
            try devices.vsock.attachHostStream(probe.stream);
            probe.stream.markStarted();
            if (try vmm.flushRx(vm, &devices.vsock, transports, devices.vsock_index, options.ram)) threaded.kickAll();
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

    return threaded.run(allocator, .{
        .config = config,
        .transports = transports,
        .gen_dev = &devices.gen,
        .vsock_dev = &devices.vsock,
        .ram_bytes = options.ram_bytes,
        .ram_size = options.prepared.ram_size,
    });
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
    };
    vcpu.command_slot.finish(result);
}

fn psciCpuOn(all: []Vcpu, target_mpidr: u64, entry: u64, context_id: u64) !u64 {
    const target_index = psciTargetIndex(all.len, target_mpidr) orelse return psci_ret_invalid_params;
    const target = &all[target_index];
    if (target.isRunning()) return psci_ret_already_on;
    _ = try target.submit(.{ .start = .{ .entry = entry, .arg0 = context_id } });
    for (all) |*vcpu| vcpu.kick();
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

const DirtyTracker = vmm.DirtyTracker(WriteProtect);

/// HVF has no dirty log, so tracking write-protects guest RAM: the first
/// guest write to a chunk faults, marks it dirty and makes it writable, and
/// sealing the chunk protects it again.
const WriteProtect = struct {
    writable_chunks: []bool = &.{},
    stats: Stats = .{},

    const Stats = struct {
        write_fault_count: u64 = 0,
        seed_protect_ms: u64 = 0,
        protect_ms: u64 = 0,
    };

    pub const metrics_mode = "write-protect";

    pub fn start(tracker: *DirtyTracker, allocator: std.mem.Allocator) !void {
        const self = &tracker.backend;
        self.writable_chunks = try allocator.alloc(bool, tracker.sealer.chunkCount());
        @memset(self.writable_chunks, false);

        const protect_start = monotonicMs();
        try protectAll(tracker, hvf.MemoryFlags.rx);
        self.stats.seed_protect_ms = monotonicMs() - protect_start;

        std.log.info(
            "hvf dirty tracking started: mode=write-protect ram_mib={d} chunks={d} seed_nonzero_chunks={d} seed_ms={d} seed_protect_ms={d}",
            .{ tracker.sealer.ram.len / 1024 / 1024, tracker.sealer.chunkCount(), tracker.sealer.stats.seed_nonzero_chunks, tracker.sealer.stats.seed_ms, self.stats.seed_protect_ms },
        );
    }

    /// Successful dirty-tracked snapshots are one-shot captures, so a
    /// finished tracker leaves its chunks protected: re-protecting every
    /// chunk would make suspend scale with configured RAM even when the dirty
    /// tail is empty. Unfinished teardown still restores permissions.
    pub fn stop(tracker: *DirtyTracker) void {
        if (!tracker.sealer.finished) {
            _ = protectAll(tracker, hvf.MemoryFlags.rwx) catch {};
        }
    }

    pub fn flush(tracker: *DirtyTracker) !void {
        if (!tracker.sealer.hasDirtyChunks()) return;
        _ = try tracker.sealer.flushMarked(.{
            .before_seal = protectDirtyChunkForSeal,
            .before_seal_ctx = tracker,
        });
    }

    /// Handles a data abort on the vCPU thread. Returns whether it was a
    /// guest write to a tracked chunk, which is then dirty and writable.
    fn handleWriteFault(tracker: *DirtyTracker, syndrome: u64, ipa: u64) !bool {
        const is_write = syndrome & (1 << 6) != 0;
        if (!is_write) return false;
        if (ipa < board.ram_base) return false;
        const guest_offset = ipa - board.ram_base;
        if (guest_offset >= tracker.sealer.ram.len) return false;
        const chunk_index: usize = @intCast(guest_offset / spore.chunk_size);

        const self = &tracker.backend;
        tracker.mutex.lock();
        defer tracker.mutex.unlock();
        self.stats.write_fault_count += 1;
        tracker.sealer.markCollectedChunkDirty(chunk_index);
        if (!self.writable_chunks[chunk_index]) {
            const protect_start = monotonicMs();
            try protectChunk(tracker, chunk_index, hvf.MemoryFlags.rwx);
            self.stats.protect_ms += monotonicMs() - protect_start;
            self.writable_chunks[chunk_index] = true;
        }
        return true;
    }

    /// Logs a single-vCPU snapshot's metrics with the write-protect counters.
    pub fn logSnapshotMetrics(tracker: *const DirtyTracker, m: vmm.SnapshotMetrics) void {
        const stats = tracker.backend.stats;
        const ram_stats = tracker.sealer.stats;
        var metrics_head_buf: [2048]u8 = undefined;
        var metrics_tail_buf: [3072]u8 = undefined;
        const metrics_head = std.fmt.bufPrint(
            &metrics_head_buf,
            "hvf snapshot metrics: mode=write-protect ram_mib={d} chunks={d} nonzero_chunks={d} machine_ms={d} devices_ms={d} generation_ms={d} memory_ms={d} disk_ms={d} manifest_ms={d} snapshot_pause_ms={d} snapshot_total_ms={d} write_fault_count={d} dirty_chunks_total={d} host_dirty_ranges_total={d} host_dirty_chunks_total={d} sealed_chunks_total={d} seed_ms={d} seed_chunks={d} seed_nonzero_chunks={d} seed_protect_ms={d} tail_flush_ms={d}",
            .{
                m.ram_mib,
                m.chunks,
                m.nonzero_chunks,
                m.machine_ms,
                m.devices_ms,
                m.generation_ms,
                m.memory_ms,
                m.disk_ms,
                m.manifest_ms,
                m.total_ms,
                m.total_ms,
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
    }

    fn protectDirtyChunkForSeal(ctx: *anyopaque, index: usize) !void {
        const tracker: *DirtyTracker = @ptrCast(@alignCast(ctx));
        const self = &tracker.backend;
        if (self.writable_chunks[index]) {
            const protect_start = monotonicMs();
            try protectChunk(tracker, index, hvf.MemoryFlags.rx);
            self.stats.protect_ms += monotonicMs() - protect_start;
            self.writable_chunks[index] = false;
        }
    }

    fn protectAll(tracker: *DirtyTracker, flags: hvf.MemoryFlags) !void {
        var i: usize = 0;
        while (i < tracker.sealer.chunkCount()) : (i += 1) {
            try protectChunk(tracker, i, flags);
            tracker.backend.writable_chunks[i] = flags.write;
        }
    }

    fn protectChunk(tracker: *const DirtyTracker, index: usize, flags: hvf.MemoryFlags) !void {
        const range = tracker.sealer.chunkRange(index);
        try hvf.check(
            hvf.hv_vm_protect(board.ram_base + range.start, range.end - range.start, flags),
            "hv_vm_protect dirty chunk",
        );
    }
};

fn wakeVcpu(context: *anyopaque) void {
    const vcpu: *hvf.VcpuHandle = @ptrCast(@alignCast(context));
    _ = hvf.hv_vcpus_exit(@ptrCast(vcpu), 1);
}

fn wakeNetworkVcpu(context: ?*anyopaque) void {
    const vcpu: *hvf.VcpuHandle = @ptrCast(@alignCast(context orelse return));
    _ = hvf.hv_vcpus_exit(@ptrCast(vcpu), 1);
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
