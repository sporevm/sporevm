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
const dirty_ram = @import("../dirty_ram.zig");
const runtime_disk_fork_capture = @import("../runtime_disk_fork_capture.zig");
const kvm = @import("aarch64.zig");
const snapshot = @import("aarch64_snapshot.zig");
const board = @import("../aarch64/board.zig");
const boot = @import("../aarch64/boot.zig");
const gicv3 = @import("../aarch64/gicv3.zig");
const guestmem = @import("../guestmem.zig");
const net = @import("../virtio/net.zig");
const virtio_mem = @import("../virtio/mem.zig");
const platform = @import("../platform.zig");
const spore = @import("../spore.zig");
const spore_fork = @import("../spore_fork.zig");
const topology = @import("../topology.zig");
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
        try platform.checkManifest(m, platform.contract(prepared.vcpus, prepared.ram_size, snapshot.hostCounterFreq()), transports.len);
        try vmm.restoreMemory(allocator, restore, m.memory, ram_bytes, ram_mapping.file_backed, &restore_stats);
        const state_start = try monotonicMs();
        if (m.memory_state) |state| try mem_dev.restoreState(state);
        try vmm.applyTransports(transports, m.devices, ram);
        try gen_dev.restore(allocator, restore.generation orelse m.generation);
        if (restore.generation == null) try spore_fork.refreshResumeParams(allocator, gen_dev);
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
            .gic = try board.gicLayout(prepared.vcpus),
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
        dirty_tracker = try DirtyTracker.start(allocator, config.io, .{
            .dir = dir,
            .ram = ram_bytes,
            .seed_ranges = boot_seed_ranges,
        }, .{ .vm_fd = vm.fd, .slot = 0 });
        if (dirty_tracker) |*tracker| {
            ram.dirty_context = tracker;
            ram.dirty_fn = DirtyTracker.markGuestWriteCallback;
        }
    }

    // More than one vCPU runs on `vmm.Threaded`, which sets its own wakes.
    if (prepared.vcpus == 1) {
        primary_vcpu.wake.thread_id = linux.gettid();
        if (config.captureRequest()) |request_capture| {
            request_capture.setWake(wakeKvmRun, &primary_vcpu.wake);
        }
        if (config.exec_control) |control| {
            control.setWake(.{ .context = &primary_vcpu.wake, .wakeFn = wakeControlKvmRun });
        }
        config.network.setWake(.{ .context = &primary_vcpu.wake, .wakeFn = wakeNetworkKvmRun });
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
    if (prepared.vcpus != 1) {
        var threaded: vmm.Threaded(Vm, Vcpu, DirtyTracker) = .{
            .vm = &vm,
            .vcpus = vcpus,
            .devices = &devices,
            .ram = ram,
            .config = config,
            .dirty_tracker = tracker_ref,
        };
        defer threaded.deinit(allocator);
        try threaded.start(allocator);
        return threaded.run(allocator, snapshot_source);
    }
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
                    // A detached stream stays attached until the control
                    // replaces or resets it.
                    exec_probe_done = true;
                }
                if (!exec_probe_done and probe.state != .idle and probe.elapsedMs() > exec_probe.timeout_ms) return error.VsockProbeTimedOut;
            }
        }

        switch (try primary_vcpu.run(&vm, vcpus)) {
            .mmio => |access| try primary_vcpu.completeMmio(try vmm.dispatchMmio(&vm, access, transports, gen_dev, ram)),
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

    /// Makes `kick` interrupt the calling thread, which runs this vCPU.
    pub fn threadStart(self: *Vcpu) !void {
        self.wake.thread_id = linux.gettid();
    }

    pub fn threadExit(_: *Vcpu) void {}

    /// KVM emulates PSCI and the GIC in the kernel, so no vCPU serves
    /// another's requests.
    pub fn handleCommands(_: *Vcpu) bool {
        return false;
    }

    /// Enters the guest once. KVM applies a pending MMIO access on entry,
    /// whether or not the run is then interrupted.
    pub fn run(self: *Vcpu, _: *const Vm, _: []Vcpu) !vmm.Exit {
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
    pub fn completeMmio(self: *Vcpu, value: u64) !void {
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
    pub fn kick(self: *Vcpu) void {
        self.wake.wakeRun();
    }

    fn deinit(self: *Vcpu) void {
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

fn wakeNetworkKvmRun(context: ?*anyopaque) void {
    const wake: *KvmRunWake = @ptrCast(@alignCast(context orelse return));
    wake.wakeRun();
}

fn wakeControlKvmRun(context: *anyopaque) void {
    const wake: *KvmRunWake = @ptrCast(@alignCast(context));
    wake.wakeRun();
}

fn handleKvmRunWakeSignal(_: posix.SIG, _: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    // Empty handler: the signal exists only to interrupt KVM_RUN after
    // `immediate_exit` is set by a helper thread.
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

fn closeFd(fd: std.c.fd_t) void {
    _ = std.c.close(fd);
}

/// The KVM VM: the /dev/kvm and VM fds, guest RAM slot 0, the vGICv3 device,
/// and the SIGURG handler that lets a kick interrupt KVM_RUN.
const Vm = struct {
    kvm_fd: std.c.fd_t,
    fd: std.c.fd_t,
    gic: kvm.CreateDevice,
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

    pub const name = "kvm";
    /// The in-kernel VGIC delivers a raised SPI to a running vCPU.
    pub const spi_needs_kick = false;

    pub fn captureGic(self: *const Vm, arena: std.mem.Allocator, vcpu_count: usize) !gicv3.State {
        return snapshot.captureGicState(arena, @intCast(self.gic.fd), vcpu_count);
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
    var dist = board.gic_dist_base;
    var redist = board.gic_redist_base;
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
