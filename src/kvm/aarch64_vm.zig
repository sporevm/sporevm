//! KVM virtual machine: AArch64 Linux bring-up path.
//!
//! This is the first KVM slice: a single-vCPU VM using the shared SporeVM
//! board, DTB builder, virtio-mmio devices, and generation MMIO device. KVM
//! owns GICv3 and PSCI emulation; userspace handles only device MMIO exits and
//! forwards virtio/generation interrupts into the VGIC.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const capture = @import("../capture.zig");
const disk_layer = @import("../disk_layer.zig");
const local_paths = @import("../local_paths.zig");
const rootfs_mod = @import("../rootfs.zig");
const saved_spore_pin = @import("../saved_spore_pin.zig");
const dirty_ram = @import("../dirty_ram.zig");
const runtime_disk_fork_capture = @import("../runtime_disk_fork_capture.zig");
const kvm = @import("aarch64.zig");
const snapshot = @import("aarch64_snapshot.zig");
const board = @import("../aarch64/board.zig");
const boot = @import("../aarch64/boot.zig");
const generation = @import("../generation.zig");
const guestmem = @import("../guestmem.zig");
const mmio = @import("../virtio/mmio.zig");
const blk = @import("../virtio/blk.zig");
const net = @import("../virtio/net.zig");
const transport_snapshot = @import("../virtio/transport_snapshot.zig");
const virtio_mem = @import("../virtio/mem.zig");
const platform = @import("../platform.zig");
const spore = @import("../spore.zig");
const topology = @import("../topology.zig");
const vsock = @import("../virtio/vsock.zig");
const vsock_control = @import("../virtio/vsock_control.zig");
const vmm = @import("../aarch64/vmm.zig");

const ExitCause = vmm.ExitCause;

const KvmPostRunAction = enum { dispatch_exit, handle_async_wake };

fn kvmPostRunAction(result: kvm.RunResult, immediate_exit: bool) KvmPostRunAction {
    // KVM_RUN returning success publishes an authoritative exit_reason. A
    // racing immediate_exit must be handled on the next entry, after userspace
    // has completed this exit.
    _ = immediate_exit;
    return if (result == .completed) .dispatch_exit else .handle_async_wake;
}

test "completed KVM exit wins a racing network wake" {
    try std.testing.expectEqual(KvmPostRunAction.dispatch_exit, kvmPostRunAction(.completed, true));
    try std.testing.expectEqual(KvmPostRunAction.handle_async_wake, kvmPostRunAction(.interrupted, true));
}

const gic_dist_base: u64 = 0x0800_0000;
const gic_dist_size: u64 = 0x0001_0000;
const gic_redist_base: u64 = 0x0802_0000;
const gic_redist_size: u64 = 0x0002_0000;

const HotplugMapping = struct {
    bytes: []align(std.heap.page_size_min) u8,
    guest_addr: u64,
    vm_fd: std.c.fd_t,
    mapped_bytes: u64 = 0,

    fn init(bytes: []align(std.heap.page_size_min) u8, guest_addr: u64, vm_fd: std.c.fd_t) HotplugMapping {
        return .{
            .bytes = bytes,
            .guest_addr = guest_addr,
            .vm_fd = vm_fd,
        };
    }

    fn deinit(self: *HotplugMapping) void {
        self.unmapFromGuest() catch |err| std.log.warn("failed to unmap virtio-mem hotplug region: {}", .{err});
    }

    fn unmapFromGuest(self: *HotplugMapping) !void {
        if (self.mapped_bytes == 0) return;
        var region = kvm.UserspaceMemoryRegion{
            .slot = 1,
            .flags = 0,
            .guest_phys_addr = self.guest_addr,
            .memory_size = 0,
            .userspace_addr = 0,
        };
        _ = try kvm.ioctl(self.vm_fd, kvm.KVM_SET_USER_MEMORY_REGION, @intFromPtr(&region), "KVM_SET_USER_MEMORY_REGION");
        self.mapped_bytes = 0;
    }

    fn mapForGuest(self: *HotplugMapping, bytes: u64) !void {
        if (bytes > self.bytes.len) return error.InvalidVirtioMemRequest;
        if (bytes <= self.mapped_bytes) return;
        try self.unmapFromGuest();
        var region = kvm.UserspaceMemoryRegion{
            .slot = 1,
            .flags = 0,
            .guest_phys_addr = self.guest_addr,
            .memory_size = bytes,
            .userspace_addr = @intFromPtr(self.bytes.ptr),
        };
        _ = try kvm.ioctl(self.vm_fd, kvm.KVM_SET_USER_MEMORY_REGION, @intFromPtr(&region), "KVM_SET_USER_MEMORY_REGION");
        self.mapped_bytes = bytes;
        std.log.debug("virtio-mem mapped hotplug region: addr=0x{x} bytes={d}", .{ self.guest_addr, bytes });
    }

    fn plug(ctx: *anyopaque, requested_size: u64) bool {
        const self: *HotplugMapping = @ptrCast(@alignCast(ctx));
        self.mapForGuest(requested_size) catch return false;
        return true;
    }
};

pub fn run(allocator: std.mem.Allocator, input: vmm.Config) !ExitCause {
    const manifest_start = try monotonicMs();
    var prepared = try vmm.prepare(allocator, input, .{ .multi_vcpu_dirty_tracking = true });
    defer prepared.deinit();
    const config = &prepared.config;
    var restore_stats: ?vmm.RestoreStats = if (prepared.restoring()) .{
        .start_ms = manifest_start,
        .manifest_ms = (try monotonicMs()) - manifest_start,
    } else null;
    var dirty_tracker: ?DirtyTracker = null;
    defer if (dirty_tracker) |*tracker| tracker.deinit();
    var boot_seed_ranges_buf: [3]dirty_ram.ChunkRange = undefined;
    var boot_seed_ranges: ?[]const dirty_ram.ChunkRange = null;

    const kvm_fd = try kvm.openDevKvm();
    defer closeFd(kvm_fd);
    try kvm.checkApiVersion(kvm_fd);
    try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_USER_MEMORY, "KVM_CAP_USER_MEMORY");
    try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_ONE_REG, "KVM_CAP_ONE_REG");
    try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_ARM_PSCI_0_2, "KVM_CAP_ARM_PSCI_0_2");
    try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_DEVICE_CTRL, "KVM_CAP_DEVICE_CTRL");
    if (prepared.restoring() or config.capture != null) {
        try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_COUNTER_OFFSET, "KVM_CAP_COUNTER_OFFSET");
    }

    const vm_fd: std.c.fd_t = @intCast(try kvm.ioctl(kvm_fd, kvm.KVM_CREATE_VM, 0, "KVM_CREATE_VM"));
    defer closeFd(vm_fd);

    const map_ram_start = try monotonicMs();
    const ram_mapping = try vmm.mapRam(&prepared);
    if (restore_stats) |*stats| stats.map_ram_ms = (try monotonicMs()) - map_ram_start;
    defer ram_mapping.deinit();
    const ram_bytes = ram_mapping.bytes;
    var ram = guestmem.GuestRam{ .bytes = ram_bytes, .base = board.ram_base };
    const initial_ram_len: usize = @intCast(prepared.ram_size);
    var hotplug_mapping: ?HotplugMapping = if (prepared.virtio_mem_region_size > 0)
        HotplugMapping.init(@alignCast(ram_bytes[initial_ram_len..]), board.ram_base + prepared.ram_size, vm_fd)
    else
        null;
    defer if (hotplug_mapping) |*mapping| mapping.deinit();

    var region = kvm.UserspaceMemoryRegion{
        .slot = 0,
        .flags = if (config.dirtyTrackingDir() != null) kvm.KVM_MEM_LOG_DIRTY_PAGES else 0,
        .guest_phys_addr = board.ram_base,
        .memory_size = prepared.ram_size,
        .userspace_addr = @intFromPtr(ram_bytes.ptr),
    };
    _ = try kvm.ioctl(vm_fd, kvm.KVM_SET_USER_MEMORY_REGION, @intFromPtr(&region), "KVM_SET_USER_MEMORY_REGION");

    const gic_dev = try createGic(vm_fd);
    defer if (gic_dev.fd != 0) closeFd(@intCast(gic_dev.fd));

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

    const run_size = try kvm.ioctl(kvm_fd, kvm.KVM_GET_VCPU_MMAP_SIZE, 0, "KVM_GET_VCPU_MMAP_SIZE");
    const vcpu_count: usize = @intCast(prepared.vcpus);
    var vcpus = try allocator.alloc(KvmVcpu, vcpu_count);
    for (vcpus) |*vcpu| vcpu.* = .{};
    defer {
        for (vcpus) |*vcpu| vcpu.deinit();
        allocator.free(vcpus);
    }
    for (vcpus, 0..) |*vcpu, index| {
        try vcpu.init(vm_fd, run_size, @intCast(index));
        try initVcpu(vm_fd, vcpu.fd, !prepared.restoring() and index != 0);
    }
    const primary_vcpu = &vcpus[0];
    const vcpu_fd = primary_vcpu.fd;
    try initGic(gic_dev.fd);

    if (prepared.manifest) |parsed| {
        const restore = config.start.restore;
        const m = parsed.value;
        try platform.checkManifest(m, .{
            .vcpu_count = prepared.vcpus,
            .ram_size = prepared.ram_size,
            .gic_dist_base = gic_dist_base,
            .gic_redist_base = gic_redist_base,
            .gic_redist_stride = gic_redist_size,
            .counter_frequency_hz = snapshot.hostCounterFreq(),
            .device_count = transports.len,
        });
        try vmm.restoreMemory(allocator, restore, m.memory, ram_bytes, ram_mapping.file_backed, &restore_stats);
        const state_start = try monotonicMs();
        if (m.memory_state) |state| try mem_dev.restoreState(state);
        try vmm.applyTransports(transports, m.devices);
        try gen_dev.restore(allocator, restore.generation orelse m.generation);
        if (restore.generation == null) try spore.refreshResumeParams(allocator, gen_dev);
        switch (m.machine) {
            .single => |machine| try snapshot.applyMachine(allocator, vm_fd, @intCast(gic_dev.fd), vcpu_fd, machine),
            .multi => |machine| {
                var vcpu_refs_buf: [topology.max_vcpus]snapshot.VcpuRef = undefined;
                const vcpu_refs = kvmVcpuRefs(&vcpu_refs_buf, vcpus);
                try snapshot.applyMachineMulti(allocator, vm_fd, @intCast(gic_dev.fd), vcpu_refs, machine);
            },
        }
        try raiseGenerationIrqIfPending(vm_fd, gen_dev);
        if (restore_stats) |*stats| stats.state_ms = (try monotonicMs()) - state_start;
    } else {
        const fresh = config.start.boot;
        const boot_ram = ram_bytes[0..initial_ram_len];
        const initrd_range = if (fresh.initrd) |initrd| try boot.planInitrd(boot_ram.len, board.ram_base, fresh.kernel, initrd.len) else null;
        const dtb = try board.buildDtb(allocator, .{
            .ram_size = prepared.ram_size,
            .cpu_count = prepared.vcpus,
            .gic = .{
                .distributor_base = gic_dist_base,
                .distributor_size = gic_dist_size,
                .redistributor_base = gic_redist_base,
                .redistributor_size = try board.redistributorRegionSize(gic_redist_size, prepared.vcpus),
            },
            .virtio_count = @intCast(transports.len),
            .bootargs = fresh.cmdline,
            .initrd = if (initrd_range) |r| .{ .start = r.start, .end = r.end } else null,
        });
        defer allocator.free(dtb);
        const layout = try boot.load(boot_ram, board.ram_base, fresh.kernel, fresh.initrd, dtb);
        for (layout.populatedRanges(), 0..) |range, i| {
            boot_seed_ranges_buf[i] = .{ .start = range.start, .end = range.end };
        }
        boot_seed_ranges = boot_seed_ranges_buf[0..layout.populated_range_count];

        try kvm.setOneRegU64(vcpu_fd, kvm.coreReg(kvm.KVM_REG_ARM_CORE_PSTATE), 0x3c5); // EL1h, DAIF masked.
        try kvm.setOneRegU64(vcpu_fd, kvm.coreReg(kvm.KVM_REG_ARM_CORE_PC), layout.entry);
        try kvm.setOneRegU64(vcpu_fd, kvm.gprReg(0), layout.dtb);
    }

    if (config.dirtyTrackingDir()) |dir| {
        dirty_tracker = try DirtyTracker.start(allocator, .{
            .vm_fd = vm_fd,
            .slot = 0,
            .dir = dir,
            .ram = ram_bytes,
            .seed_ranges = boot_seed_ranges,
        });
        if (dirty_tracker) |*tracker| {
            ram.dirty_context = tracker;
            ram.dirty_fn = DirtyTracker.markGuestWriteCallback;
        }
    }

    var run_wake_signal = KvmRunWakeSignal.install();
    defer run_wake_signal.deinit();
    const run_bytes = primary_vcpu.run_bytes;
    primary_vcpu.wake.thread_id = linux.gettid();
    var multi_wake = KvmRunWakeSet{ .vcpus = vcpus };
    if (prepared.vcpus == 1) {
        if (config.captureRequest()) |request_capture| {
            request_capture.setWake(wakeKvmRun, &primary_vcpu.wake);
        }
        if (config.exec_control) |control| {
            control.setWake(.{ .context = &primary_vcpu.wake, .wakeFn = wakeControlKvmRun });
        }
        config.network.setWake(.{ .context = &primary_vcpu.wake, .wakeFn = wakeNetworkKvmRun });
    } else {
        if (config.captureRequest()) |request_capture| {
            request_capture.setWake(wakeKvmRunSet, &multi_wake);
        }
        if (config.exec_control) |control| {
            control.setWake(.{ .context = &multi_wake, .wakeFn = wakeControlKvmRunSet });
        }
        config.network.setWake(.{ .context = &multi_wake, .wakeFn = wakeNetworkKvmRunSet });
    }
    defer config.network.clearWake();
    defer if (config.captureRequest()) |request_capture| request_capture.clearWake();

    const start_ms = try monotonicMs();
    vmm.emitRestoreMetrics("kvm", &prepared, &restore_stats, start_ms);
    if (config.probe) |probe| {
        if (probe.start == .immediate) {
            probe.stream.markStarted();
            try vsock_dev.attachHostStream(probe.stream);
            try flushVsockRxKvm(vm_fd, vsock_dev, &transports_buf[vsock_transport_index], ram, vsock_transport_index);
        }
    }
    if (prepared.vcpus != 1) {
        return runFreshMultiVcpu(allocator, .{
            .vm_fd = vm_fd,
            .gic_fd = @intCast(gic_dev.fd),
            .vcpus = vcpus,
            .wake_set = &multi_wake,
            .config = config,
            .transports = transports,
            .gen_dev = gen_dev,
            .vsock_dev = vsock_dev,
            .ram = ram,
            .ram_bytes = ram_bytes,
            .ram_size = prepared.ram_size,
            .net_dev = net_dev,
            .net_transport_index = net_transport_index,
            .vsock_transport_index = vsock_transport_index,
            .rootfs = config.rootfs,
            .disk_snapshot = config.disk_snapshot,
            .network_manifest = config.network_manifest,
            .annotations = config.annotations,
            .dirty_tracker = if (dirty_tracker) |*tracker| tracker else null,
            .environ_map = config.environ_map,
        });
    }
    var exec_probe_done = false;
    var handled_memory_pressure_count: u32 = 0;
    var requested_hotplug_size: u64 = if (mem_transport_index != null) mem_dev.requested_size else 0;
    var pending_kvm_completion = false;
    var did_capture_request = false;
    while (true) {
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
                    try kvm.setIrq(vm_fd, board.virtioDeviceIntid(@intCast(idx)), true);
                    std.log.debug("virtio-mem requested hotplug size: bytes={d} pressure_count={d}", .{ requested_hotplug_size, handled_memory_pressure_count });
                }
            }
        }
        if (config.network.failed()) return error.NetworkGatewayFailed;
        if (config.exec_control) |control| {
            if (pending_kvm_completion) {
                try kvm.completePendingExit(vcpu_fd, run_bytes);
                pending_kvm_completion = false;
            }
            control.reportStats(vmm.monitorStats(if (dirty_tracker) |*tracker| &tracker.sealer else null));
            switch (try control.poll(vsock_dev)) {
                .keep_running => {},
                .stop => return .monitor_stopped,
                .snapshot => |request| snapshot: {
                    var preparation = if (request.publish_dir != null)
                        (try control.prepareSnapshot()) orelse break :snapshot
                    else
                        null;
                    defer if (preparation) |*owned| owned.deinit();
                    var prepared_root = if (request.publish_dir) |publish_dir|
                        if (config.disk_snapshot) |disk_state| try disk_state.prepareSnapshotRoot(publish_dir) else null
                    else
                        null;
                    defer if (prepared_root) |*root| root.deinit();
                    const source_pause_started_ns = runtime_disk_fork_capture.monotonicNs();
                    try takeSnapshot(allocator, request.dir, @intCast(gic_dev.fd), vcpu_fd, transports, gen_dev, vsock_dev, ram_bytes, prepared.ram_size, if (mem_transport_index != null) mem_dev else null, config.rootfs, config.disk_snapshot, null, config.network_manifest, config.annotations, config.sessions, if (dirty_tracker) |*tracker| tracker else null, config.environ_map, if (preparation) |*owned| owned.cacheLock() else null);
                    if (!request.continue_after) return .snapshotted;
                    const completed_dir = if (request.publish_dir) |publish_dir| blk: {
                        const publish_metrics = try control.publishSnapshot(&preparation.?, request.dir, publish_dir);
                        if (prepared_root) |*root| try config.disk_snapshot.?.commitSnapshotRoot(request.dir, root, if (config.environ_map != null) .shared_no_rebind else .local_rebind);
                        vmm.logNamedSnapshotPublication("kvm", publish_metrics, source_pause_started_ns);
                        break :blk publish_dir;
                    } else request.dir;
                    try control.completeSnapshot(completed_dir);
                },
                .rootfs_snapshot => |request| {
                    const disk_manifest = try vmm.takeRootfsSnapshot(allocator, request.dir, transports, config.disk_snapshot);
                    try control.completeRootfsSnapshot(disk_manifest);
                },
                .disk_fork => |request| {
                    captureSingleKvmDiskFork(
                        allocator,
                        request,
                        control,
                        @intCast(gic_dev.fd),
                        vcpu_fd,
                        transports,
                        gen_dev,
                        vsock_dev,
                        ram_bytes,
                        &prepared,
                        if (mem_transport_index != null) mem_dev else null,
                        if (dirty_tracker) |*tracker| tracker else null,
                    ) catch |err| control.failDiskFork(err);
                },
            }
            try flushVsockRxKvm(vm_fd, vsock_dev, &transports_buf[vsock_transport_index], ram, vsock_transport_index);
        }
        if (config.captureRequest()) |request_capture| {
            if (request_capture.isAbortRequested()) return error.CaptureAborted;
            if (request_capture.isRequested() and !did_capture_request) {
                if (pending_kvm_completion) {
                    try kvm.completePendingExit(vcpu_fd, run_bytes);
                    pending_kvm_completion = false;
                }
                try takeSnapshot(allocator, config.capture.?.dir, @intCast(gic_dev.fd), vcpu_fd, transports, gen_dev, vsock_dev, ram_bytes, prepared.ram_size, if (mem_transport_index != null) mem_dev else null, config.rootfs, config.disk_snapshot, null, config.network_manifest, config.annotations, config.sessions, if (dirty_tracker) |*tracker| tracker else null, config.environ_map, null);
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
                    const observed_ms = probe.elapsedMs();
                    var pending_completion_ms: u64 = 0;
                    if (pending_kvm_completion) {
                        const completion_start = try monotonicMs();
                        try kvm.completePendingExit(vcpu_fd, run_bytes);
                        pending_completion_ms = (try monotonicMs()) -| completion_start;
                        pending_kvm_completion = false;
                    }
                    std.log.debug(
                        "kvm probe completion timing: observed_ms={d} pending_completion_ms={d} return_ms={d}",
                        .{ observed_ms, pending_completion_ms, probe.elapsedMs() },
                    );
                    if (exec_probe.on_complete == .stop) {
                        if (config.probeCaptureDir()) |dir| {
                            try takeSnapshot(allocator, dir, @intCast(gic_dev.fd), vcpu_fd, transports, gen_dev, vsock_dev, ram_bytes, prepared.ram_size, if (mem_transport_index != null) mem_dev else null, config.rootfs, config.disk_snapshot, null, config.network_manifest, config.annotations, config.sessions, if (dirty_tracker) |*tracker| tracker else null, config.environ_map, null);
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

        const run_result = try kvm.runVcpu(vcpu_fd);
        // KVM completes a prior userspace MMIO operation before checking
        // immediate_exit or pending signals, so either return completes it.
        pending_kvm_completion = false;
        switch (kvmPostRunAction(run_result, run_bytes[kvm.RunLayout.immediate_exit] != 0)) {
            .dispatch_exit => {},
            .handle_async_wake => {
                clearImmediateExit(run_bytes);
                if (config.captureRequest()) |request_capture| {
                    if (request_capture.isRequested() or request_capture.isAbortRequested()) continue;
                }
                if (config.network.failed()) continue;
                if (config.network.consumeWake()) {
                    try flushNetworkRxKvm(vm_fd, net_dev, &transports_buf[net_transport_index], ram, net_transport_index);
                }
                continue;
            },
        }
        switch (kvm.exitReason(run_bytes)) {
            kvm.KVM_EXIT_MMIO => {
                try handleMmio(vm_fd, run_bytes, transports, gen_dev, ram);
                pending_kvm_completion = true;
            },
            kvm.KVM_EXIT_SYSTEM_EVENT => switch (kvm.systemEventType(run_bytes)) {
                kvm.KVM_SYSTEM_EVENT_SHUTDOWN => return .guest_off,
                kvm.KVM_SYSTEM_EVENT_RESET => return .guest_reset,
                else => return error.UnexpectedExit,
            },
            kvm.KVM_EXIT_SHUTDOWN => return .guest_off,
            kvm.KVM_EXIT_FAIL_ENTRY, kvm.KVM_EXIT_INTERNAL_ERROR => return error.UnexpectedExit,
            else => |reason| {
                std.log.err("unhandled KVM exit reason {d}", .{reason});
                return error.UnexpectedExit;
            },
        }
    }
}

const kvm_run_wake_signal = posix.SIG.URG;

const KvmVcpu = struct {
    index: topology.VcpuIndex = 0,
    fd: std.c.fd_t = -1,
    run_bytes: []align(std.heap.page_size_min) u8 = undefined,
    run_mapped: bool = false,
    wake: KvmRunWake = undefined,
    thread: ?std.Thread = null,
    snapshot_paused: std.atomic.Value(bool) = .init(false),

    fn init(self: *KvmVcpu, vm_fd: std.c.fd_t, run_size: usize, index: topology.VcpuIndex) !void {
        const fd: std.c.fd_t = @intCast(try kvm.ioctl(vm_fd, kvm.KVM_CREATE_VCPU, @intCast(index), "KVM_CREATE_VCPU"));
        errdefer closeFd(fd);
        const run_bytes = try std.posix.mmap(
            null,
            run_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        self.* = .{
            .index = index,
            .fd = fd,
            .run_bytes = run_bytes,
            .run_mapped = true,
            .wake = .{
                .run = run_bytes,
                .process_id = linux.getpid(),
                .thread_id = 0,
            },
        };
    }

    fn deinit(self: *KvmVcpu) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.run_mapped) {
            std.posix.munmap(self.run_bytes);
            self.run_mapped = false;
        }
        if (self.fd >= 0) {
            closeFd(self.fd);
            self.fd = -1;
        }
    }
};

const KvmRunWake = struct {
    run: []u8,
    process_id: linux.pid_t,
    thread_id: linux.pid_t,

    fn wakeRun(self: *KvmRunWake) void {
        self.run[kvm.RunLayout.immediate_exit] = 1;
        _ = linux.tgkill(self.process_id, self.thread_id, kvm_run_wake_signal);
    }
};

const KvmRunWakeSet = struct {
    vcpus: []KvmVcpu,

    fn wakeAll(self: *KvmRunWakeSet) void {
        for (self.vcpus) |*vcpu| vcpu.wake.wakeRun();
    }
};

const KvmRunWakeSignal = struct {
    old_action: posix.Sigaction,
    active: bool = false,

    fn install() KvmRunWakeSignal {
        var old_action: posix.Sigaction = undefined;
        const action = posix.Sigaction{
            .handler = .{ .sigaction = handleKvmRunWakeSignal },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.SIGINFO,
        };
        posix.sigaction(kvm_run_wake_signal, &action, &old_action);
        return .{ .old_action = old_action, .active = true };
    }

    fn deinit(self: *KvmRunWakeSignal) void {
        if (!self.active) return;
        posix.sigaction(kvm_run_wake_signal, &self.old_action, null);
        self.active = false;
    }
};

fn wakeKvmRun(context: ?*anyopaque) callconv(.c) void {
    const wake: *KvmRunWake = @ptrCast(@alignCast(context orelse return));
    wake.run[kvm.RunLayout.immediate_exit] = 1;
}

fn wakeKvmRunSet(context: ?*anyopaque) callconv(.c) void {
    const wake_set: *KvmRunWakeSet = @ptrCast(@alignCast(context orelse return));
    wake_set.wakeAll();
}

fn wakeNetworkKvmRun(context: ?*anyopaque) void {
    const wake: *KvmRunWake = @ptrCast(@alignCast(context orelse return));
    wake.wakeRun();
}

fn wakeNetworkKvmRunSet(context: ?*anyopaque) void {
    const wake_set: *KvmRunWakeSet = @ptrCast(@alignCast(context orelse return));
    wake_set.wakeAll();
}

fn wakeControlKvmRun(context: *anyopaque) void {
    const wake: *KvmRunWake = @ptrCast(@alignCast(context));
    wake.wakeRun();
}

fn wakeControlKvmRunSet(context: *anyopaque) void {
    const wake_set: *KvmRunWakeSet = @ptrCast(@alignCast(context));
    wake_set.wakeAll();
}

fn handleKvmRunWakeSignal(_: posix.SIG, _: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    // Empty handler: the signal exists only to interrupt KVM_RUN after
    // `immediate_exit` is set by a helper thread.
}

const MultiKvmResult = union(enum) {
    exit: ExitCause,
    snapshot: []const u8,
    err: anyerror,
};

const MultiKvmRunState = struct {
    mutex: vmm.SpinLock = .{},
    stop: std.atomic.Value(bool) = .init(false),
    snapshot_requested: std.atomic.Value(bool) = .init(false),
    result_value: ?MultiKvmResult = null,

    fn stopped(self: *MultiKvmRunState) bool {
        return self.stop.load(.acquire);
    }

    fn requestSnapshot(self: *MultiKvmRunState) void {
        self.snapshot_requested.store(true, .release);
    }

    fn snapshotRequested(self: *MultiKvmRunState) bool {
        return self.snapshot_requested.load(.acquire);
    }

    fn clearSnapshot(self: *MultiKvmRunState) void {
        self.snapshot_requested.store(false, .release);
    }

    fn finish(self: *MultiKvmRunState, new_result: MultiKvmResult) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.result_value == null) self.result_value = new_result;
        self.stop.store(true, .release);
    }

    fn result(self: *MultiKvmRunState) ?MultiKvmResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.result_value;
    }
};

const MultiKvmRunOptions = struct {
    vm_fd: std.c.fd_t,
    gic_fd: std.c.fd_t,
    vcpus: []KvmVcpu,
    wake_set: *KvmRunWakeSet,
    config: *const vmm.Config,
    transports: []mmio.Transport,
    gen_dev: *generation.Device,
    vsock_dev: *vsock.Vsock,
    ram: guestmem.GuestRam,
    ram_bytes: []const u8,
    ram_size: u64,
    net_dev: *net.Net,
    net_transport_index: usize,
    vsock_transport_index: usize,
    rootfs: ?spore.Rootfs,
    disk_snapshot: ?disk_layer.SnapshotState,
    network_manifest: ?spore.Network,
    annotations: spore.Annotations,
    dirty_tracker: ?*DirtyTracker,
    environ_map: ?*const std.process.Environ.Map,
};

const MultiKvmThreadContext = struct {
    vm_fd: std.c.fd_t,
    vcpu: *KvmVcpu,
    state: *MultiKvmRunState,
    device_lock: *vmm.SpinLock,
    network: net.Runtime,
    transports: []mmio.Transport,
    gen_dev: *generation.Device,
    ram: guestmem.GuestRam,
    net_dev: *net.Net,
    net_transport_index: usize,
};

fn runFreshMultiVcpu(allocator: std.mem.Allocator, options: MultiKvmRunOptions) !ExitCause {
    var state = MultiKvmRunState{};
    var device_lock = vmm.SpinLock{};
    const contexts = try allocator.alloc(MultiKvmThreadContext, options.vcpus.len);
    defer allocator.free(contexts);
    defer joinKvmVcpuThreads(options.vcpus);
    errdefer {
        state.finish(.{ .err = error.KvmThreadStartFailed });
        options.wake_set.wakeAll();
    }

    for (options.vcpus, contexts) |*vcpu, *ctx| {
        ctx.* = .{
            .vm_fd = options.vm_fd,
            .vcpu = vcpu,
            .state = &state,
            .device_lock = &device_lock,
            .network = options.config.network,
            .transports = options.transports,
            .gen_dev = options.gen_dev,
            .ram = options.ram,
            .net_dev = options.net_dev,
            .net_transport_index = options.net_transport_index,
        };
        vcpu.thread = try std.Thread.spawn(.{}, kvmVcpuThreadMain, .{ctx});
    }

    var exec_probe_done = false;
    while (true) {
        if (state.result()) |result| {
            options.wake_set.wakeAll();
            switch (result) {
                .snapshot => |snapshot_dir| {
                    joinKvmVcpuThreads(options.vcpus);
                    try takeSnapshotMulti(
                        allocator,
                        snapshot_dir,
                        options.gic_fd,
                        options.vcpus,
                        options.transports,
                        options.gen_dev,
                        options.vsock_dev,
                        options.ram_bytes,
                        options.ram_size,
                        options.rootfs,
                        options.disk_snapshot,
                        null,
                        options.network_manifest,
                        options.annotations,
                        options.config.sessions,
                        options.dirty_tracker,
                        options.environ_map,
                        null,
                    );
                    if (options.config.captureRequest()) |request_capture| {
                        request_capture.markCompleted();
                        if (request_capture.isAbortRequested()) return error.CaptureAborted;
                    }
                    return .snapshotted;
                },
                else => return finishMultiKvmResult(result),
            }
        }
        if (options.config.network.failed()) {
            state.finish(.{ .err = error.NetworkGatewayFailed });
            continue;
        }
        if (options.config.exec_control) |control| {
            control.reportStats(vmm.monitorStats(if (options.dirty_tracker) |tracker| &tracker.sealer else null));
            device_lock.lock();
            const action = control.poll(options.vsock_dev) catch |err| {
                device_lock.unlock();
                state.finish(.{ .err = err });
                continue;
            };
            switch (action) {
                .keep_running => flushVsockRxKvm(
                    options.vm_fd,
                    options.vsock_dev,
                    &options.transports[options.vsock_transport_index],
                    options.ram,
                    options.vsock_transport_index,
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
                .snapshot => |request| snapshot: {
                    if (request.continue_after) {
                        var preparation = if (request.publish_dir != null)
                            (control.prepareSnapshot() catch |err| {
                                state.finish(.{ .err = err });
                                break :snapshot;
                            }) orelse break :snapshot
                        else
                            null;
                        defer if (preparation) |*owned| owned.deinit();
                        var prepared_root = if (request.publish_dir) |publish_dir|
                            if (options.disk_snapshot) |disk_state| try disk_state.prepareSnapshotRoot(publish_dir) else null
                        else
                            null;
                        defer if (prepared_root) |*root| root.deinit();
                        const source_pause_started_ns = snapshotMultiKvmAndContinue(
                            allocator,
                            options,
                            &state,
                            request.dir,
                            if (preparation) |*owned| owned.cacheLock() else null,
                        ) catch |err| {
                            state.finish(.{ .err = err });
                            continue;
                        };
                        const completed_dir = if (request.publish_dir) |publish_dir| blk: {
                            const publish_metrics = control.publishSnapshot(&preparation.?, request.dir, publish_dir) catch |err| {
                                state.finish(.{ .err = err });
                                continue;
                            };
                            if (prepared_root) |*root| options.disk_snapshot.?.commitSnapshotRoot(request.dir, root, if (options.environ_map != null) .shared_no_rebind else .local_rebind) catch |err| {
                                state.finish(.{ .err = err });
                                continue;
                            };
                            vmm.logNamedSnapshotPublication("kvm", publish_metrics, source_pause_started_ns);
                            break :blk publish_dir;
                        } else request.dir;
                        state.clearSnapshot();
                        control.completeSnapshot(completed_dir) catch |err| {
                            state.finish(.{ .err = err });
                            continue;
                        };
                        continue;
                    }
                    state.finish(.{ .snapshot = request.dir });
                    continue;
                },
                .rootfs_snapshot => |request| {
                    const disk_manifest = takeRootfsSnapshotMulti(
                        allocator,
                        options,
                        &state,
                        request.dir,
                    ) catch |err| {
                        state.finish(.{ .err = err });
                        continue;
                    };
                    control.completeRootfsSnapshot(disk_manifest) catch |err| {
                        state.finish(.{ .err = err });
                        continue;
                    };
                    continue;
                },
                .disk_fork => |request| {
                    captureMultiKvmDiskFork(allocator, options, &state, request, control) catch |err| control.failDiskFork(err);
                    continue;
                },
            }
        }
        if (options.config.probe) |exec_probe| {
            const probe = exec_probe.stream;
            if (!exec_probe_done) {
                if (probe.state == .failed) {
                    state.finish(.{ .err = error.VsockProbeFailed });
                    continue;
                }
                if (probe.state == .complete) {
                    std.log.debug("kvm multi-vcpu probe completion timing: observed_ms={d}", .{probe.elapsedMs()});
                    if (exec_probe.on_complete == .stop) {
                        if (options.config.probeCaptureDir()) |dir| {
                            state.finish(.{ .snapshot = dir });
                            continue;
                        }
                        state.finish(.{ .exit = .probe_complete });
                        continue;
                    }
                    options.vsock_dev.host_stream = null;
                    exec_probe_done = true;
                }
                if (!exec_probe_done and probe.state != .idle and probe.elapsedMs() > exec_probe.timeout_ms) {
                    state.finish(.{ .err = error.VsockProbeTimedOut });
                    continue;
                }
            }
        }
        if (options.config.captureRequest()) |request_capture| {
            if (request_capture.isAbortRequested()) {
                state.finish(.{ .err = error.CaptureAborted });
                continue;
            }
            if (request_capture.isRequested()) {
                state.finish(.{ .snapshot = options.config.capture.?.dir });
                continue;
            }
        }
        sleepMs(1);
    }
}

fn snapshotMultiKvmAndContinue(
    allocator: std.mem.Allocator,
    options: MultiKvmRunOptions,
    state: *MultiKvmRunState,
    snapshot_dir: []const u8,
    rootfs_cache_lock: ?*const rootfs_mod.RootfsCacheLock,
) !u64 {
    try pauseKvmVcpusForSnapshot(options.vcpus, state, options.wake_set);
    const source_pause_started_ns = runtime_disk_fork_capture.monotonicNs();
    errdefer state.clearSnapshot();
    try takeSnapshotMulti(
        allocator,
        snapshot_dir,
        options.gic_fd,
        options.vcpus,
        options.transports,
        options.gen_dev,
        options.vsock_dev,
        options.ram_bytes,
        options.ram_size,
        options.rootfs,
        options.disk_snapshot,
        null,
        options.network_manifest,
        options.annotations,
        options.config.sessions,
        options.dirty_tracker,
        options.environ_map,
        rootfs_cache_lock,
    );
    return source_pause_started_ns;
}

fn takeRootfsSnapshotMulti(
    allocator: std.mem.Allocator,
    options: MultiKvmRunOptions,
    state: *MultiKvmRunState,
    dir: []const u8,
) !?spore.Disk {
    try pauseKvmVcpusForSnapshot(options.vcpus, state, options.wake_set);
    errdefer state.clearSnapshot();
    const disk_manifest = try vmm.takeRootfsSnapshot(allocator, dir, options.transports, options.disk_snapshot);
    state.clearSnapshot();
    return disk_manifest;
}

fn finishMultiKvmResult(result: MultiKvmResult) !ExitCause {
    return switch (result) {
        .exit => |cause| cause,
        .snapshot => .snapshotted,
        .err => |err| err,
    };
}

fn joinKvmVcpuThreads(vcpus: []KvmVcpu) void {
    for (vcpus) |*vcpu| {
        if (vcpu.thread) |thread| {
            vcpu.wake.wakeRun();
            thread.join();
            vcpu.thread = null;
        }
    }
}

fn kvmVcpuThreadMain(ctx: *MultiKvmThreadContext) void {
    ctx.vcpu.wake.thread_id = linux.gettid();
    var pending_kvm_completion = false;
    while (!ctx.state.stopped()) {
        if (ctx.state.snapshotRequested()) {
            if (!completePendingKvmExitBeforeSnapshot(ctx, &pending_kvm_completion)) return;
            ctx.vcpu.snapshot_paused.store(true, .release);
            sleepMs(1);
            continue;
        }
        ctx.vcpu.snapshot_paused.store(false, .release);
        const run_result = kvm.runVcpu(ctx.vcpu.fd) catch |err| {
            ctx.state.finish(.{ .err = err });
            return;
        };
        // KVM completes a prior userspace MMIO operation before checking
        // immediate_exit or pending signals, so either return completes it.
        pending_kvm_completion = false;
        const post_run_action = kvmPostRunAction(run_result, ctx.vcpu.run_bytes[kvm.RunLayout.immediate_exit] != 0);
        if (post_run_action == .handle_async_wake) {
            clearImmediateExit(ctx.vcpu.run_bytes);
            if (ctx.state.snapshotRequested()) {
                if (!completePendingKvmExitBeforeSnapshot(ctx, &pending_kvm_completion)) return;
                ctx.vcpu.snapshot_paused.store(true, .release);
                continue;
            }
            if (ctx.state.stopped()) continue;
            if (ctx.network.failed()) {
                ctx.state.finish(.{ .err = error.NetworkGatewayFailed });
                continue;
            }
            ctx.device_lock.lock();
            if (ctx.network.consumeWake()) {
                flushNetworkRxKvm(ctx.vm_fd, ctx.net_dev, &ctx.transports[ctx.net_transport_index], ctx.ram, ctx.net_transport_index) catch |err| {
                    ctx.device_lock.unlock();
                    ctx.state.finish(.{ .err = err });
                    return;
                };
            }
            ctx.device_lock.unlock();
            continue;
        }

        switch (kvm.exitReason(ctx.vcpu.run_bytes)) {
            kvm.KVM_EXIT_MMIO => {
                ctx.device_lock.lock();
                handleMmio(ctx.vm_fd, ctx.vcpu.run_bytes, ctx.transports, ctx.gen_dev, ctx.ram) catch |err| {
                    ctx.device_lock.unlock();
                    ctx.state.finish(.{ .err = err });
                    return;
                };
                ctx.device_lock.unlock();
                pending_kvm_completion = true;
                if (ctx.state.stopped()) {
                    kvm.completePendingExit(ctx.vcpu.fd, ctx.vcpu.run_bytes) catch |err| {
                        ctx.state.finish(.{ .err = err });
                    };
                    pending_kvm_completion = false;
                    return;
                }
            },
            kvm.KVM_EXIT_SYSTEM_EVENT => switch (kvm.systemEventType(ctx.vcpu.run_bytes)) {
                kvm.KVM_SYSTEM_EVENT_SHUTDOWN => ctx.state.finish(.{ .exit = .guest_off }),
                kvm.KVM_SYSTEM_EVENT_RESET => ctx.state.finish(.{ .exit = .guest_reset }),
                else => ctx.state.finish(.{ .err = error.UnexpectedExit }),
            },
            kvm.KVM_EXIT_SHUTDOWN => ctx.state.finish(.{ .exit = .guest_off }),
            kvm.KVM_EXIT_FAIL_ENTRY, kvm.KVM_EXIT_INTERNAL_ERROR => ctx.state.finish(.{ .err = error.UnexpectedExit }),
            else => |reason| {
                std.log.err("unhandled KVM exit reason {d} on vcpu {d}", .{ reason, ctx.vcpu.index });
                ctx.state.finish(.{ .err = error.UnexpectedExit });
            },
        }
    }
}

fn completePendingKvmExitBeforeSnapshot(ctx: *MultiKvmThreadContext, pending_kvm_completion: *bool) bool {
    if (!pending_kvm_completion.*) return true;
    kvm.completePendingExit(ctx.vcpu.fd, ctx.vcpu.run_bytes) catch |err| {
        ctx.state.finish(.{ .err = err });
        return false;
    };
    pending_kvm_completion.* = false;
    return true;
}

fn pauseKvmVcpusForSnapshot(vcpus: []KvmVcpu, state: *MultiKvmRunState, wake_set: *KvmRunWakeSet) !void {
    for (vcpus) |*vcpu| vcpu.snapshot_paused.store(false, .release);
    state.requestSnapshot();
    wake_set.wakeAll();
    while (true) {
        if (state.stopped()) return error.CaptureAborted;
        var paused_count: usize = 0;
        for (vcpus) |*vcpu| {
            if (!vcpu.snapshot_paused.load(.acquire)) break;
            paused_count += 1;
        }
        if (paused_count == vcpus.len) return;
        sleepMs(1);
    }
}

fn flushVsockRxKvm(
    vm_fd: std.c.fd_t,
    vsock_dev: *vsock.Vsock,
    transport: *mmio.Transport,
    ram: guestmem.GuestRam,
    transport_index: usize,
) !void {
    if (vsock_dev.flushPendingRx(transport, ram)) {
        try kvm.setIrq(vm_fd, board.virtioDeviceIntid(@intCast(transport_index)), true);
    }
}

fn flushNetworkRxKvm(
    vm_fd: std.c.fd_t,
    net_dev: *net.Net,
    transport: *mmio.Transport,
    ram: guestmem.GuestRam,
    transport_index: usize,
) !void {
    if (net_dev.flushPendingRx(transport, ram)) {
        try kvm.setIrq(vm_fd, board.virtioDeviceIntid(@intCast(transport_index)), true);
    }
}

/// A wake sets `immediate_exit` so the next KVM_RUN returns at once; clear it
/// once the wake has been seen so the following entry runs the guest.
fn clearImmediateExit(run_bytes: []u8) void {
    run_bytes[kvm.RunLayout.immediate_exit] = 0;
}

fn monotonicMs() !u64 {
    var ts: std.os.linux.timespec = undefined;
    const rc = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        else => |err| {
            std.log.err("clock_gettime(CLOCK_MONOTONIC) failed: {s}", .{@tagName(err)});
            return error.ClockFailed;
        },
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn sleepMs(ms: u64) void {
    var ts = std.c.timespec{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast((ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);
}

fn threadCpuNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    const rc = std.os.linux.clock_gettime(.THREAD_CPUTIME_ID, &ts);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        else => return 0,
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn nsToMs(ns: u64) u64 {
    return ns / std.time.ns_per_ms;
}

fn elapsedCpuMs(start_ns: u64) u64 {
    const end_ns = threadCpuNs();
    if (end_ns <= start_ns) return 0;
    return nsToMs(end_ns - start_ns);
}

fn ratePerSec(count: u64, elapsed_ms: u64) u64 {
    if (elapsed_ms == 0) return 0;
    return count * std.time.ms_per_s / elapsed_ms;
}

fn kvmVcpuRefs(buf: *[topology.max_vcpus]snapshot.VcpuRef, vcpus: []const KvmVcpu) []const snapshot.VcpuRef {
    for (vcpus, 0..) |vcpu, i| {
        buf[i] = .{ .index = vcpu.index, .fd = vcpu.fd };
    }
    return buf[0..vcpus.len];
}

const DirtyTracker = struct {
    sealer: dirty_ram.Sealer,
    vm_fd: std.c.fd_t,
    slot: u32,
    bitmap: []usize,
    tracking_start_ms: u64 = 0,
    mutex: vmm.SpinLock = .{},
    stats: DirtyStats = .{},

    const Options = struct {
        vm_fd: std.c.fd_t,
        slot: u32,
        dir: []const u8,
        ram: []const u8,
        seed_ranges: ?[]const dirty_ram.ChunkRange = null,
    };

    const DirtyStats = struct {
        dirty_pages_total: u64 = 0,
        get_dirty_log_ms: u64 = 0,
        get_dirty_log_cpu_ms: u64 = 0,
        dirty_pages_per_sec: u64 = 0,
    };

    fn start(allocator: std.mem.Allocator, options: Options) !DirtyTracker {
        if (options.ram.len == 0) return error.BadManifest;
        if (options.ram.len % std.heap.page_size_min != 0) return error.BadManifest;
        if (spore.chunk_size % std.heap.page_size_min != 0) return error.BadManifest;

        const page_count = (options.ram.len + std.heap.page_size_min - 1) / std.heap.page_size_min;
        const bitmap_word_count = (page_count + @bitSizeOf(usize) - 1) / @bitSizeOf(usize);
        var sealer = try dirty_ram.Sealer.start(allocator, .{
            .dir = options.dir,
            .ram = options.ram,
            .seed_ranges = options.seed_ranges,
        });
        errdefer sealer.deinit();

        var tracker = DirtyTracker{
            .sealer = sealer,
            .vm_fd = options.vm_fd,
            .slot = options.slot,
            .bitmap = try allocator.alloc(usize, bitmap_word_count),
        };

        // Some kernels conservatively mark a logging memslot dirty at
        // creation. Drop that baseline after the host has loaded the kernel,
        // initrd, and DTB so the capture-time flush covers guest writes only.
        _ = try tracker.collectDirtyLog();
        tracker.resetDirtyStatsAfterBaseline();
        tracker.tracking_start_ms = try monotonicMs();

        std.log.info(
            "kvm dirty tracking started: mode=dirty-log ram_mib={d} chunks={d} seed_nonzero_chunks={d} seed_ms={d}",
            .{ options.ram.len / 1024 / 1024, tracker.sealer.chunkCount(), tracker.sealer.stats.seed_nonzero_chunks, tracker.sealer.stats.seed_ms },
        );
        return tracker;
    }

    fn deinit(self: *DirtyTracker) void {
        self.sealer.deinit();
    }

    fn finish(self: *DirtyTracker) !spore.MemoryManifest {
        const tail_start = try monotonicMs();
        try self.flushDirty();
        self.sealer.stats.tail_flush_ms = (try monotonicMs()) - tail_start;
        const now_ms = try monotonicMs();
        self.sealer.finishRates(self.tracking_start_ms, now_ms);
        self.stats.dirty_pages_per_sec = ratePerSec(self.stats.dirty_pages_total, self.sealer.stats.tracking_ms);
        return try self.sealer.finishBacking();
    }

    fn flushDirty(self: *DirtyTracker) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const dirty_pages = try self.collectDirtyLog();
        if (dirty_pages == 0 and !self.sealer.hasDirtyChunks()) return;
        _ = try self.sealer.flushMarked(.{ .record_cpu = true });
    }

    fn collectDirtyLog(self: *DirtyTracker) !u64 {
        @memset(self.bitmap, 0);
        var log = kvm.DirtyLog{
            .slot = self.slot,
            .dirty_bitmap = @intFromPtr(self.bitmap.ptr),
        };
        const log_start = try monotonicMs();
        const log_cpu_start = threadCpuNs();
        _ = try kvm.ioctl(self.vm_fd, kvm.KVM_GET_DIRTY_LOG, @intFromPtr(&log), "KVM_GET_DIRTY_LOG");
        self.stats.get_dirty_log_ms += (try monotonicMs()) - log_start;
        self.stats.get_dirty_log_cpu_ms += elapsedCpuMs(log_cpu_start);

        var dirty_pages: u64 = 0;
        const page_count = (self.sealer.ram.len + std.heap.page_size_min - 1) / std.heap.page_size_min;
        for (self.bitmap, 0..) |word, word_index| {
            var bits = word;
            while (bits != 0) {
                const bit_index: usize = @ctz(bits);
                const page_index = word_index * @bitSizeOf(usize) + bit_index;
                if (page_index >= page_count) break;
                const chunk_index = (page_index * std.heap.page_size_min) / spore.chunk_size;
                self.sealer.markCollectedChunkDirty(chunk_index);
                dirty_pages += 1;
                bits &= bits - 1;
            }
        }
        self.stats.dirty_pages_total += dirty_pages;
        return dirty_pages;
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

    fn resetDirtyStatsAfterBaseline(self: *DirtyTracker) void {
        self.stats.dirty_pages_total = 0;
        self.stats.get_dirty_log_ms = 0;
        self.stats.get_dirty_log_cpu_ms = 0;
        self.stats.dirty_pages_per_sec = 0;
        self.sealer.resetStatsAfterBaseline();
        @memset(self.bitmap, 0);
    }
};

fn captureSingleKvmDiskFork(
    allocator: std.mem.Allocator,
    request: vsock_control.DiskForkAction,
    control: vsock_control.Control,
    gic_fd: std.c.fd_t,
    vcpu_fd: std.c.fd_t,
    transports: []mmio.Transport,
    gen_dev: *const generation.Device,
    vsock_dev: *const vsock.Vsock,
    ram_bytes: []const u8,
    prepared: *const vmm.Prepared,
    memory_device: ?*const virtio_mem.Mem,
    dirty_tracker: ?*DirtyTracker,
) !void {
    const config = &prepared.config;
    const disk = config.disk_snapshot orelse return error.BadManifest;
    const pause_started_ns = runtime_disk_fork_capture.monotonicNs();
    try takeSnapshot(
        allocator,
        request.dir,
        gic_fd,
        vcpu_fd,
        transports,
        gen_dev,
        vsock_dev,
        ram_bytes,
        prepared.ram_size,
        memory_device,
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
    gic_fd: std.c.fd_t,
    vcpu_fd: std.c.fd_t,
    transports: []mmio.Transport,
    gen_dev: *const generation.Device,
    vsock_dev: *const vsock.Vsock,
    ram_bytes: []const u8,
    ram_size: u64,
    memory_device: ?*const virtio_mem.Mem,
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

    const total_start = try monotonicMs();
    const machine_start = total_start;
    const machine = try snapshot.captureMachine(arena, gic_fd, vcpu_fd);
    const machine_ms = (try monotonicMs()) - machine_start;
    const devices_start = try monotonicMs();
    const devices = try vmm.captureTransports(arena, transports);
    const devices_ms = (try monotonicMs()) - devices_start;
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
    const generation_start = try monotonicMs();
    const gen_state = try gen_dev.capture(arena);
    const generation_ms = (try monotonicMs()) - generation_start;
    const memory_start = try monotonicMs();
    const memory = if (dirty_tracker) |tracker|
        try tracker.finish()
    else
        try spore.saveMemoryWithBacking(arena, dir, ram_bytes);
    const memory_ms = (try monotonicMs()) - memory_start;
    const memory_state = if (memory_device) |device| try device.captureState(arena, ram_size) else null;
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
    const disk_start = try monotonicMs();
    const disk_manifest = if (disk_snapshot) |disk_state| try disk_state.finish(arena, disk_root, disk_quiesced) else null;
    const disk_ms = (try monotonicMs()) - disk_start;
    const manifest_start = try monotonicMs();
    const saved_manifest = spore.Manifest{
        .platform = .{
            .cpu_profile = board.cpu_profile,
            .device_model_version = board.device_model_version,
            .vcpu_count = 1,
            .ram_base = board.ram_base,
            .ram_size = ram_size,
            .gic_dist_base = gic_dist_base,
            .gic_redist_base = gic_redist_base,
            .gic_redist_stride = gic_redist_size,
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
    const manifest_ms = (try monotonicMs()) - manifest_start;
    const snapshot_total_ms = (try monotonicMs()) - total_start;

    const memory_plan = try spore.validateMemoryForRam(memory, ram_bytes.len);
    if (dirty_tracker) |tracker| {
        const stats = tracker.stats;
        const ram_stats = tracker.sealer.stats;
        var metrics_head_buf: [2048]u8 = undefined;
        var metrics_tail_buf: [3072]u8 = undefined;
        const metrics_head = std.fmt.bufPrint(
            &metrics_head_buf,
            "kvm snapshot metrics: mode=dirty-log ram_mib={d} chunks={d} nonzero_chunks={d} machine_ms={d} devices_ms={d} generation_ms={d} memory_ms={d} disk_ms={d} manifest_ms={d} snapshot_pause_ms={d} snapshot_total_ms={d} dirty_pages_total={d} dirty_chunks_total={d} host_dirty_ranges_total={d} host_dirty_chunks_total={d} sealed_chunks_total={d} seed_ms={d} seed_chunks={d} seed_nonzero_chunks={d} tail_flush_ms={d}",
            .{
                ram_size / 1024 / 1024,
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
                stats.dirty_pages_total,
                ram_stats.dirty_chunks_total,
                ram_stats.host_dirty_ranges_total,
                ram_stats.host_dirty_chunks_total,
                ram_stats.sealed_chunks_total,
                ram_stats.seed_ms,
                ram_stats.seed_chunks,
                ram_stats.seed_nonzero_chunks,
                ram_stats.tail_flush_ms,
            },
        ) catch "kvm snapshot metrics: formatting_failed=1";
        const metrics_tail = std.fmt.bufPrint(
            &metrics_tail_buf,
            " get_dirty_log_ms={d} get_dirty_log_cpu_ms={d} seal_ms={d} seal_cpu_ms={d} seal_zero_scan_ms={d} seal_hash_ms={d} seal_chunk_write_ms={d} seal_backing_write_ms={d} seal_parallel_flush_count={d} seal_parallel_workers_max={d} finish_fchmod_ms={d} finish_close_ms={d} finish_close_deferred={d} finish_rename_ms={d} tracking_ms={d} dirty_pages_per_sec={d} sealed_chunks_per_sec={d}",
            .{
                stats.get_dirty_log_ms,
                stats.get_dirty_log_cpu_ms,
                ram_stats.seal_ms,
                ram_stats.seal_cpu_ms,
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
                stats.dirty_pages_per_sec,
                ram_stats.sealed_chunks_per_sec,
            },
        ) catch "";
        std.log.info("{s}{s}", .{ metrics_head, metrics_tail });
    } else {
        std.log.info(
            "kvm snapshot metrics: mode=full-scan ram_mib={d} chunks={d} nonzero_chunks={d} machine_ms={d} devices_ms={d} generation_ms={d} memory_ms={d} disk_ms={d} manifest_ms={d} snapshot_pause_ms={d} snapshot_total_ms={d}",
            .{
                ram_size / 1024 / 1024,
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

fn takeSnapshotMulti(
    allocator: std.mem.Allocator,
    dir: []const u8,
    gic_fd: std.c.fd_t,
    vcpus: []KvmVcpu,
    transports: []mmio.Transport,
    gen_dev: *const generation.Device,
    vsock_dev: *const vsock.Vsock,
    ram_bytes: []const u8,
    ram_size: u64,
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

    const total_start = try monotonicMs();
    const machine_start = total_start;
    var vcpu_refs_buf: [topology.max_vcpus]snapshot.VcpuRef = undefined;
    const vcpu_refs = kvmVcpuRefs(&vcpu_refs_buf, vcpus);
    const machine = try snapshot.captureMachineMulti(arena, gic_fd, vcpu_refs);
    const machine_ms = (try monotonicMs()) - machine_start;
    const devices_start = try monotonicMs();
    const devices = try vmm.captureTransports(arena, transports);
    const devices_ms = (try monotonicMs()) - devices_start;
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
    const generation_start = try monotonicMs();
    const gen_state = try gen_dev.capture(arena);
    const generation_ms = (try monotonicMs()) - generation_start;
    const memory_start = try monotonicMs();
    const memory = if (dirty_tracker) |tracker|
        try tracker.finish()
    else
        try spore.saveMemoryWithBacking(arena, dir, ram_bytes);
    const memory_ms = (try monotonicMs()) - memory_start;
    if (environ_map) |environ| {
        try spore.writeLocalMemoryBackingProof(arena, environ, dir, memory, ram_size);
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
    const disk_start = try monotonicMs();
    const disk_manifest = if (disk_snapshot) |disk_state| try disk_state.finish(arena, disk_root, disk_quiesced) else null;
    const disk_ms = (try monotonicMs()) - disk_start;
    const manifest_start = try monotonicMs();
    const saved_manifest = spore.Manifest{
        .platform = .{
            .cpu_profile = board.cpu_profile,
            .device_model_version = board.device_model_version,
            .vcpu_count = @intCast(vcpus.len),
            .ram_base = board.ram_base,
            .ram_size = ram_size,
            .gic_dist_base = gic_dist_base,
            .gic_redist_base = gic_redist_base,
            .gic_redist_stride = gic_redist_size,
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
    const manifest_ms = (try monotonicMs()) - manifest_start;
    const snapshot_total_ms = (try monotonicMs()) - total_start;
    const memory_plan = try spore.validateMemoryForRam(memory, ram_bytes.len);
    std.log.info(
        "kvm snapshot metrics: version=1 vcpus={d} mode={s} ram_mib={d} chunks={d} nonzero_chunks={d} machine_ms={d} devices_ms={d} generation_ms={d} memory_ms={d} disk_ms={d} manifest_ms={d} snapshot_total_ms={d}",
        .{
            vcpus.len,
            if (dirty_tracker != null) "dirty-log" else "full-scan",
            ram_size / 1024 / 1024,
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

fn captureMultiKvmDiskFork(
    allocator: std.mem.Allocator,
    options: MultiKvmRunOptions,
    state: *MultiKvmRunState,
    request: vsock_control.DiskForkAction,
    control: vsock_control.Control,
) !void {
    const disk = options.disk_snapshot orelse return error.BadManifest;
    const pause_started_ns = runtime_disk_fork_capture.monotonicNs();
    try pauseKvmVcpusForSnapshot(options.vcpus, state, options.wake_set);
    defer state.clearSnapshot();
    try takeSnapshotMulti(
        allocator,
        request.dir,
        options.gic_fd,
        options.vcpus,
        options.transports,
        options.gen_dev,
        options.vsock_dev,
        options.ram_bytes,
        options.ram_size,
        options.rootfs,
        null,
        disk,
        options.network_manifest,
        options.annotations,
        options.config.sessions,
        options.dirty_tracker,
        options.environ_map,
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

fn raiseGenerationIrqIfPending(vm_fd: std.c.fd_t, gen_dev: *const generation.Device) !void {
    if (gen_dev.interrupt_status & generation.irq_generation_changed != 0) {
        try kvm.setIrq(vm_fd, board.generationIntid(), true);
    }
}

fn closeFd(fd: std.c.fd_t) void {
    _ = std.c.close(fd);
}

fn createGic(vm_fd: std.c.fd_t) !kvm.CreateDevice {
    var dev = kvm.CreateDevice{ .type = kvm.KVM_DEV_TYPE_ARM_VGIC_V3, .fd = 0, .flags = 0 };
    _ = try kvm.ioctl(vm_fd, kvm.KVM_CREATE_DEVICE, @intFromPtr(&dev), "KVM_CREATE_DEVICE vgicv3");
    var dist = gic_dist_base;
    var redist = gic_redist_base;
    try kvm.setDeviceAttr(@intCast(dev.fd), kvm.KVM_DEV_ARM_VGIC_GRP_ADDR, kvm.KVM_VGIC_V3_ADDR_TYPE_DIST, &dist, "vgic dist addr");
    try kvm.setDeviceAttr(@intCast(dev.fd), kvm.KVM_DEV_ARM_VGIC_GRP_ADDR, kvm.KVM_VGIC_V3_ADDR_TYPE_REDIST, &redist, "vgic redist addr");
    return dev;
}

fn initGic(gic_fd: u32) !void {
    var unused: u64 = 0;
    try kvm.setDeviceAttr(@intCast(gic_fd), kvm.KVM_DEV_ARM_VGIC_GRP_CTRL, kvm.KVM_DEV_ARM_VGIC_CTRL_INIT, &unused, "vgic init");
}

fn initVcpu(vm_fd: std.c.fd_t, vcpu_fd: std.c.fd_t, power_off: bool) !void {
    var init = kvm.VcpuInit{ .target = 0, .features = @splat(0) };
    _ = try kvm.ioctl(vm_fd, kvm.KVM_ARM_PREFERRED_TARGET, @intFromPtr(&init), "KVM_ARM_PREFERRED_TARGET");
    setFeature(&init, kvm.KVM_ARM_VCPU_PSCI_0_2);
    if (power_off) setFeature(&init, kvm.KVM_ARM_VCPU_POWER_OFF);
    _ = try kvm.ioctl(vcpu_fd, kvm.KVM_ARM_VCPU_INIT, @intFromPtr(&init), "KVM_ARM_VCPU_INIT");
    try maskPortableCpuFeatures(vcpu_fd);
}

fn setFeature(init: *kvm.VcpuInit, feature: u32) void {
    init.features[feature / 32] |= @as(u32, 1) << @intCast(feature % 32);
}

fn maskPortableCpuFeatures(vcpu_fd: std.c.fd_t) !void {
    // KVM exposes the host CPU's RNDR feature on Graviton. Linux then patches
    // in RNDRRS_EL0 (`MRS S3_3_C2_C4_1`) for entropy, but HVF does not expose
    // that register to guests. Until the full CPU-profile contract lands, keep
    // KVM at the common denominator by hiding ID_AA64ISAR0_EL1.RNDR.
    const id_aa64isar0_el1 = kvm.sysReg(3, 0, 0, 6, 0);
    const rndr_mask: u64 = @as(u64, 0xf) << 60;
    const isar0 = try kvm.getOneRegU64(vcpu_fd, id_aa64isar0_el1);
    const masked = isar0 & ~rndr_mask;
    if (masked != isar0) {
        std.log.debug("masking KVM ID_AA64ISAR0_EL1.RNDR for portability: 0x{x} -> 0x{x}", .{ isar0, masked });
        try kvm.setOneRegU64(vcpu_fd, id_aa64isar0_el1, masked);
    }
}

fn handleMmio(
    vm_fd: std.c.fd_t,
    run_bytes: []u8,
    transports: []mmio.Transport,
    gen_dev: *generation.Device,
    ram: guestmem.GuestRam,
) !void {
    const exit = kvm.mmioExit(run_bytes);
    const size_log2 = sizeLog2(exit.len) orelse return error.UnhandledMmio;
    const ipa = exit.phys_addr;

    if (ipa >= board.generation_base and ipa < board.generation_base + board.generation_size) {
        const offset = ipa - board.generation_base;
        if (exit.is_write) {
            if (gen_dev.write(offset, readData(exit.data, exit.len), size_log2)) {
                try kvm.setIrq(vm_fd, board.generationIntid(), false);
            }
        } else {
            writeData(exit.data, exit.len, gen_dev.read(offset, size_log2));
        }
        return;
    }

    const dev_index = blk: {
        if (ipa < board.virtio_base) break :blk null;
        const idx = (ipa - board.virtio_base) / board.virtio_stride;
        if (idx >= transports.len) break :blk null;
        break :blk idx;
    };
    if (dev_index) |idx| {
        const t = &transports[@intCast(idx)];
        const offset = ipa - board.virtioDeviceBase(@intCast(idx));
        if (exit.is_write) {
            const raised = t.write(offset, @truncate(readData(exit.data, exit.len)), ram);
            if (raised) try kvm.setIrq(vm_fd, board.virtioDeviceIntid(@intCast(idx)), true);
            if (offset == 0x064) try kvm.setIrq(vm_fd, board.virtioDeviceIntid(@intCast(idx)), false);
        } else {
            writeData(exit.data, exit.len, t.read(offset));
        }
        return;
    }

    std.log.debug("stray KVM MMIO {s} at ipa=0x{x}", .{ if (exit.is_write) "write" else "read", ipa });
    if (!exit.is_write) writeData(exit.data, exit.len, 0);
}

fn sizeLog2(len: u32) ?u2 {
    return switch (len) {
        1 => 0,
        2 => 1,
        4 => 2,
        8 => 3,
        else => null,
    };
}

fn readData(data: *const [8]u8, len: u32) u64 {
    var tmp: [8]u8 = @splat(0);
    @memcpy(tmp[0..@intCast(len)], data[0..@intCast(len)]);
    return std.mem.readInt(u64, &tmp, .little);
}

fn writeData(data: *[8]u8, len: u32, value: u64) void {
    var tmp: [8]u8 = @splat(0);
    std.mem.writeInt(u64, &tmp, value, .little);
    @memcpy(data[0..@intCast(len)], tmp[0..@intCast(len)]);
}
