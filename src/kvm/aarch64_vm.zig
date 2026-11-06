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
const rootfs_mod = @import("../rootfs.zig");
const dirty_ram = @import("../dirty_ram.zig");
const runtime_disk_fork_capture = @import("../runtime_disk_fork_capture.zig");
const kvm = @import("aarch64.zig");
const snapshot = @import("aarch64_snapshot.zig");
const board = @import("../aarch64/board.zig");
const boot = @import("../aarch64/boot.zig");
const gicv3 = @import("../aarch64/gicv3.zig");
const generation = @import("../generation.zig");
const guestmem = @import("../guestmem.zig");
const mmio = @import("../virtio/mmio.zig");
const net = @import("../virtio/net.zig");
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

    const map_ram_start = try monotonicMs();
    const ram_mapping = try vmm.mapRam(&prepared);
    if (restore_stats) |*stats| stats.map_ram_ms = (try monotonicMs()) - map_ram_start;
    defer ram_mapping.deinit();
    const ram_bytes = ram_mapping.bytes;
    var ram = guestmem.GuestRam{ .bytes = ram_bytes, .base = board.ram_base };
    const initial_ram_len: usize = @intCast(prepared.ram_size);

    var vm = try Vm.create(.{
        .ram = ram_bytes[0..initial_ram_len],
        .dirty_tracking = config.dirtyTrackingDir() != null,
        .counter_offset = prepared.restoring() or config.capture != null,
    });
    defer vm.deinit();

    var hotplug: ?vmm.Hotplug(Vm) = if (prepared.virtio_mem_region_size > 0) .{
        .vm = &vm,
        .bytes = @alignCast(ram_bytes[initial_ram_len..]),
        .guest_addr = board.ram_base + prepared.ram_size,
    } else null;
    defer if (hotplug) |*region| region.deinit();

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

    const vcpu_count: usize = @intCast(prepared.vcpus);
    var vcpus = try allocator.alloc(Vcpu, vcpu_count);
    for (vcpus) |*vcpu| vcpu.* = .{};
    defer {
        for (vcpus) |*vcpu| vcpu.deinit();
        allocator.free(vcpus);
    }
    for (vcpus, 0..) |*vcpu, index| {
        try vcpu.create(&vm, @intCast(index), !prepared.restoring() and index != 0);
    }
    const primary_vcpu = &vcpus[0];
    const vcpu_fd = primary_vcpu.fd;
    try vm.initGic();

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
        try vmm.applyTransports(transports, m.devices, ram);
        try gen_dev.restore(allocator, restore.generation orelse m.generation);
        if (restore.generation == null) try spore.refreshResumeParams(allocator, gen_dev);
        try vmm.restoreMachine(allocator, &vm, vcpus, m.machine);
        try vmm.raiseGenerationIrqIfPending(&vm, gen_dev);
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
            .dir = dir,
            .ram = ram_bytes,
            .seed_ranges = boot_seed_ranges,
        }, .{ .vm_fd = vm.fd, .slot = 0 });
        if (dirty_tracker) |*tracker| {
            ram.dirty_context = tracker;
            ram.dirty_fn = DirtyTracker.markGuestWriteCallback;
        }
    }

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
            _ = try vmm.flushRx(&vm, vsock_dev, transports, vsock_transport_index, ram);
        }
    }
    if (prepared.vcpus != 1) {
        return runFreshMultiVcpu(allocator, .{
            .vm = &vm,
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
            .disk_snapshot = config.disk_snapshot,
            .dirty_tracker = if (dirty_tracker) |*tracker| tracker else null,
            .environ_map = config.environ_map,
        });
    }
    const tracker_ref: ?*DirtyTracker = if (dirty_tracker) |*tracker| tracker else null;
    const snapshot_source = vmm.SnapshotSource{
        .config = config,
        .transports = transports,
        .gen_dev = gen_dev,
        .vsock_dev = vsock_dev,
        .ram_bytes = ram_bytes,
        .ram_size = prepared.ram_size,
        .memory_device = if (mem_transport_index != null) mem_dev else null,
    };
    var exec_probe_done = false;
    var handled_memory_pressure_count: u32 = 0;
    var requested_hotplug_size: u64 = if (mem_transport_index != null) mem_dev.requested_size else 0;
    var did_capture_request = false;
    while (true) {
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
        if (config.exec_control) |control| {
            control.reportStats(vmm.monitorStats(if (tracker_ref) |tracker| &tracker.sealer else null));
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
                    try vmm.writeSnapshot(allocator, "kvm", &vm, vcpus, tracker_ref, snapshot_source, .{
                        .dir = request.dir,
                        .rootfs_cache_lock = if (preparation) |*owned| owned.cacheLock() else null,
                    });
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
                    const pause_started_ns = runtime_disk_fork_capture.monotonicNs();
                    vmm.captureDiskFork(allocator, "kvm", &vm, vcpus, tracker_ref, snapshot_source, request, control, pause_started_ns) catch |err| control.failDiskFork(err);
                },
            }
            _ = try vmm.flushRx(&vm, vsock_dev, transports, vsock_transport_index, ram);
        }
        if (config.captureRequest()) |request_capture| {
            if (request_capture.isAbortRequested()) return error.CaptureAborted;
            if (request_capture.isRequested() and !did_capture_request) {
                try vmm.writeSnapshot(allocator, "kvm", &vm, vcpus, tracker_ref, snapshot_source, .{ .dir = config.capture.?.dir });
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
                    std.log.debug(
                        "kvm probe completion timing: observed_ms={d} return_ms={d}",
                        .{ observed_ms, probe.elapsedMs() },
                    );
                    if (exec_probe.on_complete == .stop) {
                        if (config.probeCaptureDir()) |dir| {
                            try vmm.writeSnapshot(allocator, "kvm", &vm, vcpus, tracker_ref, snapshot_source, .{ .dir = dir });
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

        switch (try primary_vcpu.run()) {
            .mmio => |access| primary_vcpu.completeMmio(try vmm.dispatchMmio(&vm, access, transports, gen_dev, ram)),
            .shutdown => |kind| return kind.cause(),
            .kicked => {
                if (config.captureRequest()) |request_capture| {
                    if (request_capture.isRequested() or request_capture.isAbortRequested()) continue;
                }
                if (config.network.failed()) continue;
                if (config.network.consumeWake()) {
                    _ = try vmm.flushRx(&vm, net_dev, transports, net_transport_index, ram);
                }
            },
            .wfi, .handled => unreachable,
        }
    }
}

const kvm_run_wake_signal = posix.SIG.URG;

const Vcpu = struct {
    index: topology.VcpuIndex = 0,
    fd: std.c.fd_t = -1,
    run_bytes: []align(std.heap.page_size_min) u8 = undefined,
    run_mapped: bool = false,
    wake: KvmRunWake = undefined,
    thread: ?std.Thread = null,
    snapshot_paused: std.atomic.Value(bool) = .init(false),
    /// KVM applies a completed MMIO access only on the next KVM_RUN.
    pending_mmio: bool = false,

    /// Creates the vCPU. A parked vCPU starts powered off until PSCI CPU_ON.
    fn create(self: *Vcpu, vm: *const Vm, index: topology.VcpuIndex, parked: bool) !void {
        const fd: std.c.fd_t = @intCast(try kvm.ioctl(vm.fd, kvm.KVM_CREATE_VCPU, @intCast(index), "KVM_CREATE_VCPU"));
        errdefer closeFd(fd);
        const run_bytes = try std.posix.mmap(
            null,
            vm.run_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer std.posix.munmap(run_bytes);
        try initVcpu(vm.fd, fd, parked);
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

    /// Enters the guest once. KVM applies a pending MMIO access on entry,
    /// whether or not the run is then interrupted.
    fn run(self: *Vcpu) !vmm.Exit {
        const run_result = try kvm.runVcpu(self.fd);
        self.pending_mmio = false;
        if (kvmPostRunAction(run_result, self.run_bytes[kvm.RunLayout.immediate_exit] != 0) == .handle_async_wake) {
            clearImmediateExit(self.run_bytes);
            return .kicked;
        }
        switch (kvm.exitReason(self.run_bytes)) {
            kvm.KVM_EXIT_MMIO => {
                const exit = kvm.mmioExit(self.run_bytes);
                const size_log2 = sizeLog2(exit.len) orelse return error.UnhandledMmio;
                return .{ .mmio = .{
                    .addr = exit.phys_addr,
                    .size_log2 = size_log2,
                    .write = if (exit.is_write) readData(exit.data, exit.len) else null,
                } };
            },
            kvm.KVM_EXIT_SYSTEM_EVENT => return switch (kvm.systemEventType(self.run_bytes)) {
                kvm.KVM_SYSTEM_EVENT_SHUTDOWN => .{ .shutdown = .off },
                kvm.KVM_SYSTEM_EVENT_RESET => .{ .shutdown = .reset },
                else => error.UnexpectedExit,
            },
            kvm.KVM_EXIT_SHUTDOWN => return .{ .shutdown = .off },
            kvm.KVM_EXIT_FAIL_ENTRY, kvm.KVM_EXIT_INTERNAL_ERROR => return error.UnexpectedExit,
            else => |reason| {
                std.log.err("unhandled KVM exit reason {d} on vcpu {d}", .{ reason, self.index });
                return error.UnexpectedExit;
            },
        }
    }

    /// Finishes the last `.mmio` exit; a read returns `value` to the guest.
    /// KVM applies it on the next KVM_RUN.
    fn completeMmio(self: *Vcpu, value: u64) void {
        const exit = kvm.mmioExit(self.run_bytes);
        if (!exit.is_write) writeData(exit.data, exit.len, value);
        self.pending_mmio = true;
    }

    /// Applies a completed MMIO access now, so a capture sees the register
    /// value and PC the guest would see next.
    fn applyPendingMmio(self: *Vcpu) !void {
        if (!self.pending_mmio) return;
        try kvm.completePendingExit(self.fd, self.run_bytes);
        self.pending_mmio = false;
    }

    /// Captures the stopped vCPU as the guest would see it on its next entry,
    /// so a completed MMIO access is applied first.
    pub fn capture(self: *Vcpu, vm: *const Vm, arena: std.mem.Allocator) !spore.VcpuState {
        try self.applyPendingMmio();
        return snapshot.captureVcpuState(arena, @intCast(vm.gic.fd), .{ .index = self.index, .fd = self.fd });
    }

    pub fn apply(self: *Vcpu, vm: *const Vm, state: spore.VcpuState) !void {
        try snapshot.applyVcpuState(@intCast(vm.gic.fd), .{ .index = self.index, .fd = self.fd }, state);
    }

    /// Interrupts KVM_RUN from another thread or a signal handler.
    fn kick(self: *Vcpu) void {
        self.wake.wakeRun();
    }

    fn deinit(self: *Vcpu) void {
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
    vcpus: []Vcpu,

    fn wakeAll(self: *KvmRunWakeSet) void {
        for (self.vcpus) |*vcpu| vcpu.kick();
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
    vm: *const Vm,
    vcpus: []Vcpu,
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
    disk_snapshot: ?disk_layer.SnapshotState,
    dirty_tracker: ?*DirtyTracker,
    environ_map: ?*const std.process.Environ.Map,

    fn snapshotSource(self: MultiKvmRunOptions) vmm.SnapshotSource {
        return .{
            .config = self.config,
            .transports = self.transports,
            .gen_dev = self.gen_dev,
            .vsock_dev = self.vsock_dev,
            .ram_bytes = self.ram_bytes,
            .ram_size = self.ram_size,
        };
    }
};

const MultiKvmThreadContext = struct {
    vm: *const Vm,
    vcpu: *Vcpu,
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
            .vm = options.vm,
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
                    try vmm.writeSnapshot(allocator, "kvm", options.vm, options.vcpus, options.dirty_tracker, options.snapshotSource(), .{ .dir = snapshot_dir });
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
                .keep_running => _ = vmm.flushRx(
                    options.vm,
                    options.vsock_dev,
                    options.transports,
                    options.vsock_transport_index,
                    options.ram,
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
    try vmm.writeSnapshot(allocator, "kvm", options.vm, options.vcpus, options.dirty_tracker, options.snapshotSource(), .{
        .dir = snapshot_dir,
        .rootfs_cache_lock = rootfs_cache_lock,
    });
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

fn joinKvmVcpuThreads(vcpus: []Vcpu) void {
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
    while (!ctx.state.stopped()) {
        if (ctx.state.snapshotRequested()) {
            if (!applyPendingMmioBeforeSnapshot(ctx)) return;
            ctx.vcpu.snapshot_paused.store(true, .release);
            sleepMs(1);
            continue;
        }
        ctx.vcpu.snapshot_paused.store(false, .release);
        const exit = ctx.vcpu.run() catch |err| {
            ctx.state.finish(.{ .err = err });
            return;
        };
        switch (exit) {
            .kicked => {
                if (ctx.state.snapshotRequested()) {
                    if (!applyPendingMmioBeforeSnapshot(ctx)) return;
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
                    _ = vmm.flushRx(ctx.vm, ctx.net_dev, ctx.transports, ctx.net_transport_index, ctx.ram) catch |err| {
                        ctx.device_lock.unlock();
                        ctx.state.finish(.{ .err = err });
                        return;
                    };
                }
                ctx.device_lock.unlock();
            },
            .mmio => |access| {
                ctx.device_lock.lock();
                const value = vmm.dispatchMmio(ctx.vm, access, ctx.transports, ctx.gen_dev, ctx.ram) catch |err| {
                    ctx.device_lock.unlock();
                    ctx.state.finish(.{ .err = err });
                    return;
                };
                ctx.device_lock.unlock();
                ctx.vcpu.completeMmio(value);
                if (ctx.state.stopped()) {
                    ctx.vcpu.applyPendingMmio() catch |err| {
                        ctx.state.finish(.{ .err = err });
                    };
                    return;
                }
            },
            .shutdown => |kind| ctx.state.finish(.{ .exit = kind.cause() }),
            .wfi, .handled => unreachable,
        }
    }
}

fn applyPendingMmioBeforeSnapshot(ctx: *MultiKvmThreadContext) bool {
    ctx.vcpu.applyPendingMmio() catch |err| {
        ctx.state.finish(.{ .err = err });
        return false;
    };
    return true;
}

fn pauseKvmVcpusForSnapshot(vcpus: []Vcpu, state: *MultiKvmRunState, wake_set: *KvmRunWakeSet) !void {
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

const DirtyTracker = vmm.DirtyTracker(DirtyLog);

/// KVM finds guest writes in the RAM memslot's dirty-page log, read once at
/// start to drop the baseline and again at every flush.
const DirtyLog = struct {
    vm_fd: std.c.fd_t,
    slot: u32,
    bitmap: []usize = &.{},
    stats: Stats = .{},

    const Stats = struct {
        dirty_pages_total: u64 = 0,
        get_dirty_log_ms: u64 = 0,
        get_dirty_log_cpu_ms: u64 = 0,
    };

    pub const metrics_mode = "dirty-log";

    pub fn start(tracker: *DirtyTracker, allocator: std.mem.Allocator) !void {
        const page_count = (tracker.sealer.ram.len + std.heap.page_size_min - 1) / std.heap.page_size_min;
        const bitmap_word_count = (page_count + @bitSizeOf(usize) - 1) / @bitSizeOf(usize);
        tracker.backend.bitmap = try allocator.alloc(usize, bitmap_word_count);

        // Some kernels conservatively mark a logging memslot dirty at
        // creation. Drop that baseline after the host has loaded the kernel,
        // initrd, and DTB so the capture-time flush covers guest writes only.
        _ = try collect(tracker);
        tracker.backend.stats = .{};
        tracker.sealer.resetStatsAfterBaseline();

        std.log.info(
            "kvm dirty tracking started: mode=dirty-log ram_mib={d} chunks={d} seed_nonzero_chunks={d} seed_ms={d}",
            .{ tracker.sealer.ram.len / 1024 / 1024, tracker.sealer.chunkCount(), tracker.sealer.stats.seed_nonzero_chunks, tracker.sealer.stats.seed_ms },
        );
    }

    pub fn stop(_: *DirtyTracker) void {}

    pub fn flush(tracker: *DirtyTracker) !void {
        const dirty_pages = try collect(tracker);
        if (dirty_pages == 0 and !tracker.sealer.hasDirtyChunks()) return;
        _ = try tracker.sealer.flushMarked(.{ .record_cpu = true });
    }

    /// Logs a single-vCPU snapshot's metrics with the dirty-log counters.
    pub fn logSnapshotMetrics(tracker: *const DirtyTracker, m: vmm.SnapshotMetrics) void {
        const stats = tracker.backend.stats;
        const ram_stats = tracker.sealer.stats;
        var metrics_head_buf: [2048]u8 = undefined;
        var metrics_tail_buf: [3072]u8 = undefined;
        const metrics_head = std.fmt.bufPrint(
            &metrics_head_buf,
            "kvm snapshot metrics: mode=dirty-log ram_mib={d} chunks={d} nonzero_chunks={d} machine_ms={d} devices_ms={d} generation_ms={d} memory_ms={d} disk_ms={d} manifest_ms={d} snapshot_pause_ms={d} snapshot_total_ms={d} dirty_pages_total={d} dirty_chunks_total={d} host_dirty_ranges_total={d} host_dirty_chunks_total={d} sealed_chunks_total={d} seed_ms={d} seed_chunks={d} seed_nonzero_chunks={d} tail_flush_ms={d}",
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
                ratePerSec(stats.dirty_pages_total, ram_stats.tracking_ms),
                ram_stats.sealed_chunks_per_sec,
            },
        ) catch "";
        std.log.info("{s}{s}", .{ metrics_head, metrics_tail });
    }

    fn collect(tracker: *DirtyTracker) !u64 {
        const self = &tracker.backend;
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
        const page_count = (tracker.sealer.ram.len + std.heap.page_size_min - 1) / std.heap.page_size_min;
        for (self.bitmap, 0..) |word, word_index| {
            var bits = word;
            while (bits != 0) {
                const bit_index: usize = @ctz(bits);
                const page_index = word_index * @bitSizeOf(usize) + bit_index;
                if (page_index >= page_count) break;
                const chunk_index = (page_index * std.heap.page_size_min) / spore.chunk_size;
                tracker.sealer.markCollectedChunkDirty(chunk_index);
                dirty_pages += 1;
                bits &= bits - 1;
            }
        }
        self.stats.dirty_pages_total += dirty_pages;
        return dirty_pages;
    }
};

fn captureMultiKvmDiskFork(
    allocator: std.mem.Allocator,
    options: MultiKvmRunOptions,
    state: *MultiKvmRunState,
    request: vsock_control.DiskForkAction,
    control: vsock_control.Control,
) !void {
    const pause_started_ns = runtime_disk_fork_capture.monotonicNs();
    try pauseKvmVcpusForSnapshot(options.vcpus, state, options.wake_set);
    defer state.clearSnapshot();
    try vmm.captureDiskFork(allocator, "kvm", options.vm, options.vcpus, options.dirty_tracker, options.snapshotSource(), request, control, pause_started_ns);
}

fn closeFd(fd: std.c.fd_t) void {
    _ = std.c.close(fd);
}

/// The KVM VM: the /dev/kvm and VM fds, guest RAM slot 0, the vGICv3 device,
/// and the SIGURG handler that lets a kick interrupt KVM_RUN.
const Vm = struct {
    kvm_fd: std.c.fd_t,
    fd: std.c.fd_t,
    gic: kvm.CreateDevice,
    gic_layout: vmm.GicLayout = .{ .dist_base = gic_dist_base, .redist_base = gic_redist_base, .redist_stride = gic_redist_size },
    run_size: usize,
    wake_signal: KvmRunWakeSignal,

    const Options = struct {
        /// Initial guest RAM, mapped at board.ram_base as slot 0.
        ram: []u8,
        dirty_tracking: bool,
        /// Restores and captures set the guest counter offset.
        counter_offset: bool,
    };

    fn create(options: Options) !Vm {
        const kvm_fd = try kvm.openDevKvm();
        errdefer closeFd(kvm_fd);
        try kvm.checkApiVersion(kvm_fd);
        try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_USER_MEMORY, "KVM_CAP_USER_MEMORY");
        try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_ONE_REG, "KVM_CAP_ONE_REG");
        try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_ARM_PSCI_0_2, "KVM_CAP_ARM_PSCI_0_2");
        try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_DEVICE_CTRL, "KVM_CAP_DEVICE_CTRL");
        if (options.counter_offset) {
            try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_COUNTER_OFFSET, "KVM_CAP_COUNTER_OFFSET");
        }

        const vm_fd: std.c.fd_t = @intCast(try kvm.ioctl(kvm_fd, kvm.KVM_CREATE_VM, 0, "KVM_CREATE_VM"));
        errdefer closeFd(vm_fd);
        var region = kvm.UserspaceMemoryRegion{
            .slot = 0,
            .flags = if (options.dirty_tracking) kvm.KVM_MEM_LOG_DIRTY_PAGES else 0,
            .guest_phys_addr = board.ram_base,
            .memory_size = options.ram.len,
            .userspace_addr = @intFromPtr(options.ram.ptr),
        };
        _ = try kvm.ioctl(vm_fd, kvm.KVM_SET_USER_MEMORY_REGION, @intFromPtr(&region), "KVM_SET_USER_MEMORY_REGION");

        const gic = try createGic(vm_fd);
        errdefer closeFd(@intCast(gic.fd));
        const run_size = try kvm.ioctl(kvm_fd, kvm.KVM_GET_VCPU_MMAP_SIZE, 0, "KVM_GET_VCPU_MMAP_SIZE");
        return .{
            .kvm_fd = kvm_fd,
            .fd = vm_fd,
            .gic = gic,
            .run_size = run_size,
            .wake_signal = KvmRunWakeSignal.install(),
        };
    }

    fn deinit(self: *Vm) void {
        self.wake_signal.deinit();
        closeFd(@intCast(self.gic.fd));
        closeFd(self.fd);
        closeFd(self.kvm_fd);
    }

    /// Initializes the vGIC. KVM requires every vCPU to exist first.
    fn initGic(self: *Vm) !void {
        var unused: u64 = 0;
        try kvm.setDeviceAttr(@intCast(self.gic.fd), kvm.KVM_DEV_ARM_VGIC_GRP_CTRL, kvm.KVM_DEV_ARM_VGIC_CTRL_INIT, &unused, "vgic init");
    }

    pub fn captureGic(self: *const Vm, arena: std.mem.Allocator, vcpus: []const Vcpu) !gicv3.State {
        return snapshot.captureGicState(arena, @intCast(self.gic.fd), vcpus.len);
    }

    pub fn applyGic(self: *const Vm, _: std.mem.Allocator, vcpus: []const Vcpu, state: gicv3.State) !void {
        try snapshot.applyGicState(self.fd, @intCast(self.gic.fd), vcpus.len, state);
    }

    /// Sets the guest counter for every vCPU; KVM's offset is VM-wide.
    pub fn setCounter(self: *const Vm, guest_cntvct: u64) !void {
        try kvm.setCounterOffset(self.fd, snapshot.hostCounter() -% guest_cntvct);
    }

    pub fn setSpi(self: *const Vm, intid: u32, level: bool) !void {
        try kvm.setIrq(self.fd, intid, level);
    }

    /// A memslot cannot grow, so the virtio-mem slot is deleted and added
    /// back at the new size. If that fails, the old size goes back so the
    /// memory the guest already plugged stays mapped.
    pub fn mapHotplug(self: *const Vm, bytes: []u8, guest_addr: u64, mapped_bytes: u64, new_bytes: u64) !void {
        if (mapped_bytes != 0) try self.setHotplugSlot(guest_addr, 0, 0);
        self.setHotplugSlot(guest_addr, new_bytes, @intFromPtr(bytes.ptr)) catch |err| {
            if (mapped_bytes != 0) self.setHotplugSlot(guest_addr, mapped_bytes, @intFromPtr(bytes.ptr)) catch {};
            return err;
        };
    }

    pub fn unmapHotplug(self: *const Vm, guest_addr: u64, _: u64) void {
        self.setHotplugSlot(guest_addr, 0, 0) catch |err| std.log.warn("failed to unmap virtio-mem hotplug region: {}", .{err});
    }

    fn setHotplugSlot(self: *const Vm, guest_addr: u64, size: u64, userspace_addr: u64) !void {
        var region = kvm.UserspaceMemoryRegion{
            .slot = 1,
            .flags = 0,
            .guest_phys_addr = guest_addr,
            .memory_size = size,
            .userspace_addr = userspace_addr,
        };
        _ = try kvm.ioctl(self.fd, kvm.KVM_SET_USER_MEMORY_REGION, @intFromPtr(&region), "KVM_SET_USER_MEMORY_REGION");
    }
};

fn createGic(vm_fd: std.c.fd_t) !kvm.CreateDevice {
    var dev = kvm.CreateDevice{ .type = kvm.KVM_DEV_TYPE_ARM_VGIC_V3, .fd = 0, .flags = 0 };
    _ = try kvm.ioctl(vm_fd, kvm.KVM_CREATE_DEVICE, @intFromPtr(&dev), "KVM_CREATE_DEVICE vgicv3");
    var dist = gic_dist_base;
    var redist = gic_redist_base;
    try kvm.setDeviceAttr(@intCast(dev.fd), kvm.KVM_DEV_ARM_VGIC_GRP_ADDR, kvm.KVM_VGIC_V3_ADDR_TYPE_DIST, &dist, "vgic dist addr");
    try kvm.setDeviceAttr(@intCast(dev.fd), kvm.KVM_DEV_ARM_VGIC_GRP_ADDR, kvm.KVM_VGIC_V3_ADDR_TYPE_REDIST, &redist, "vgic redist addr");
    return dev;
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
