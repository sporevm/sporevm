//! KVM virtual machine: aarch64 Linux bring-up path.
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
const dirty_ram = @import("../dirty_ram.zig");
const kvm = @import("kvm.zig");
const lazy_ram = @import("lazy_ram.zig");
const snapshot = @import("snapshot.zig");
const board = @import("../board.zig");
const boot = @import("../boot.zig");
const generation = @import("../generation.zig");
const guestmem = @import("../guestmem.zig");
const mmio = @import("../virtio/mmio.zig");
const console = @import("../virtio/console.zig");
const blk = @import("../virtio/blk.zig");
const net = @import("../virtio/net.zig");
const rng = @import("../virtio/rng.zig");
const platform = @import("../platform.zig");
const spore = @import("../spore.zig");
const vsock = @import("../virtio/vsock.zig");

pub const Config = struct {
    kernel: []const u8,
    ram_size: u64 = 512 * 1024 * 1024,
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
    /// Resume from a spore directory instead of booting the kernel.
    resume_dir: ?[]const u8 = null,
    /// Optional pre-refreshed generation state for product resume attach.
    resume_generation: ?generation.State = null,
    /// Proof-validated or harness-supplied same-host RAM backing fd. The fd
    /// must refer to the manifest's optional RAM backing and is mapped
    /// MAP_PRIVATE; imported or unproven spores must leave this null so RAM is
    /// materialized through verified chunks.
    ram_backing_fd: ?std.c.fd_t = null,
    /// Product callers provide their environment so snapshot code can write
    /// local-only RAM backing proofs under the configured runtime root.
    environ_map: ?*const std.process.Environ.Map = null,
    /// Chunk restore strategy for cold/imported KVM resumes. Eager remains the
    /// default; lazy is an explicit development path backed by userfaultfd.
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
    /// Opt-in KVM dirty-log capture path for Slice 7 measurement. When
    /// enabled, guest writes are collected in epochs and snapshot only needs a
    /// final dirty-log tail flush instead of a full RAM scan.
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

pub const DirtyTrackingOptions = struct {
    enabled: bool = false,
    /// 0 disables periodic collection and measures only the final tail flush.
    epoch_ms: u64 = 250,
};

pub const RamRestoreMode = enum {
    eager_chunks,
    lazy_chunks,
};

pub const ExitCause = enum { guest_off, guest_reset, snapshotted, probe_complete, monitor_stopped };

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

const gic_dist_base: u64 = 0x0800_0000;
const gic_dist_size: u64 = 0x0001_0000;
const gic_redist_base: u64 = 0x0802_0000;
const gic_redist_size: u64 = 0x0002_0000;

const RamMapping = struct {
    bytes: []align(std.heap.page_size_min) u8,
    file_backed: bool,

    fn deinit(self: RamMapping) void {
        std.posix.munmap(self.bytes);
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

pub fn run(allocator: std.mem.Allocator, config: Config) !ExitCause {
    var resume_parsed: ?std.json.Parsed(spore.Manifest) = null;
    defer if (resume_parsed) |*parsed| parsed.deinit();
    var lazy_pager: ?lazy_ram.Pager = null;
    var dirty_tracker: ?DirtyTracker = null;
    defer if (dirty_tracker) |*tracker| tracker.deinit();
    var restore_stats: ?RestoreStats = null;
    var boot_seed_ranges_buf: [3]dirty_ram.ChunkRange = undefined;
    var boot_seed_ranges: ?[]const dirty_ram.ChunkRange = null;

    if (config.resume_dir) |spore_dir| {
        const manifest_start = try monotonicMs();
        resume_parsed = try spore.loadManifest(allocator, spore_dir);
        restore_stats = .{
            .start_ms = manifest_start,
            .manifest_ms = (try monotonicMs()) - manifest_start,
        };
    }

    const kvm_fd = try kvm.openDevKvm();
    defer closeFd(kvm_fd);
    try kvm.checkApiVersion(kvm_fd);
    try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_USER_MEMORY, "KVM_CAP_USER_MEMORY");
    try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_ONE_REG, "KVM_CAP_ONE_REG");
    try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_ARM_PSCI_0_2, "KVM_CAP_ARM_PSCI_0_2");
    try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_DEVICE_CTRL, "KVM_CAP_DEVICE_CTRL");
    if (config.resume_dir != null or config.snapshot_after_ms != null or config.snapshot_on_probe_complete or config.capture_request != null) {
        try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_COUNTER_OFFSET, "KVM_CAP_COUNTER_OFFSET");
    }

    const vm_fd: std.c.fd_t = @intCast(try kvm.ioctl(kvm_fd, kvm.KVM_CREATE_VM, 0, "KVM_CREATE_VM"));
    defer closeFd(vm_fd);

    const map_ram_start = try monotonicMs();
    const ram_mapping = try mapRam(allocator, config, if (resume_parsed) |parsed| parsed.value else null);
    if (restore_stats) |*stats| stats.map_ram_ms = (try monotonicMs()) - map_ram_start;
    defer ram_mapping.deinit();
    defer if (lazy_pager) |*pager| pager.deinit();
    const ram_bytes = ram_mapping.bytes;
    var ram = guestmem.GuestRam{ .bytes = ram_bytes, .base = board.ram_base };

    var region = kvm.UserspaceMemoryRegion{
        .slot = 0,
        .flags = if (config.dirty_tracking.enabled) kvm.KVM_MEM_LOG_DIRTY_PAGES else 0,
        .guest_phys_addr = board.ram_base,
        .memory_size = config.ram_size,
        .userspace_addr = @intFromPtr(ram_bytes.ptr),
    };
    _ = try kvm.ioctl(vm_fd, kvm.KVM_SET_USER_MEMORY_REGION, @intFromPtr(&region), "KVM_SET_USER_MEMORY_REGION");

    const gic_dev = try createGic(vm_fd);
    defer if (gic_dev.fd != 0) closeFd(@intCast(gic_dev.fd));

    var con = console.Console{ .sink = config.console_sink };
    var blk_dev: blk.Blk = undefined;
    var net_dev = net.Net.init(.{ .backend = config.network.backend });
    defer net_dev.shutdown();
    var rng_dev = rng.Rng{};
    var vsock_dev = vsock.Vsock.init(.{});
    var gen_dev = generation.Device{};
    var transports_buf: [5]mmio.Transport = undefined;
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
    const transports = transports_buf[0..transport_count];

    const vcpu_fd: std.c.fd_t = @intCast(try kvm.ioctl(vm_fd, kvm.KVM_CREATE_VCPU, 0, "KVM_CREATE_VCPU"));
    defer closeFd(vcpu_fd);
    try initVcpu(vm_fd, vcpu_fd);
    try initGic(gic_dev.fd);

    if (config.resume_dir) |spore_dir| {
        _ = spore_dir;
        const m = resume_parsed.?.value;
        const host_counter_frequency_hz = snapshot.hostCounterFreq();
        try platform.checkManifest(m, .{
            .ram_size = config.ram_size,
            .gic_dist_base = gic_dist_base,
            .gic_redist_base = gic_redist_base,
            .counter_frequency_hz = host_counter_frequency_hz,
            .device_count = transports.len,
        });
        // The file-backed path is only enabled for trusted same-host forks.
        // Otherwise RAM is materialized through verified chunks.
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
                const memory_start = try monotonicMs();
                try spore.loadMemory(allocator, config.resume_dir.?, m.memory, ram_bytes);
                if (restore_stats) |*stats| stats.memory_ms = (try monotonicMs()) - memory_start;
            },
            .lazy_chunks => {
                if (restore_stats) |*stats| stats.mode = "lazy_chunks";
                const memory_start = try monotonicMs();
                lazy_pager = try lazy_ram.Pager.start(.{
                    .dir = config.resume_dir.?,
                    .manifest = m.memory,
                    .ram = ram_bytes,
                    .trace_fd = config.lazy_ram_trace_fd,
                });
                if (restore_stats) |*stats| stats.memory_ms = (try monotonicMs()) - memory_start;
            },
        }
        const state_start = try monotonicMs();
        try applyTransports(transports, m.devices);
        try gen_dev.restore(allocator, config.resume_generation orelse m.generation);
        if (config.resume_generation == null) try spore.refreshResumeParams(allocator, &gen_dev);
        try snapshot.applyMachine(allocator, vm_fd, @intCast(gic_dev.fd), vcpu_fd, m.machine);
        try raiseGenerationIrqIfPending(vm_fd, &gen_dev);
        if (restore_stats) |*stats| stats.state_ms = (try monotonicMs()) - state_start;
    } else {
        const initrd_range = if (config.initrd) |initrd| try boot.planInitrd(ram_bytes.len, board.ram_base, config.kernel, initrd.len) else null;
        const dtb = try board.buildDtb(allocator, .{
            .ram_size = config.ram_size,
            .cpu_count = 1,
            .gic = .{
                .distributor_base = gic_dist_base,
                .distributor_size = gic_dist_size,
                .redistributor_base = gic_redist_base,
                .redistributor_size = gic_redist_size,
            },
            .virtio_count = @intCast(transports.len),
            .bootargs = config.cmdline,
            .initrd = if (initrd_range) |r| .{ .start = r.start, .end = r.end } else null,
        });
        defer allocator.free(dtb);
        const layout = try boot.load(ram_bytes, board.ram_base, config.kernel, config.initrd, dtb);
        for (layout.populatedRanges(), 0..) |range, i| {
            boot_seed_ranges_buf[i] = .{ .start = range.start, .end = range.end };
        }
        boot_seed_ranges = boot_seed_ranges_buf[0..layout.populated_range_count];

        try kvm.setOneRegU64(vcpu_fd, kvm.coreReg(kvm.KVM_REG_ARM_CORE_PSTATE), 0x3c5); // EL1h, DAIF masked.
        try kvm.setOneRegU64(vcpu_fd, kvm.coreReg(kvm.KVM_REG_ARM_CORE_PC), layout.entry);
        try kvm.setOneRegU64(vcpu_fd, kvm.gprReg(0), layout.dtb);
    }

    if (config.dirty_tracking.enabled) {
        const dir = config.snapshot_dir orelse return error.KvmIoctlFailed;
        dirty_tracker = try DirtyTracker.start(allocator, .{
            .vm_fd = vm_fd,
            .slot = 0,
            .dir = dir,
            .ram = ram_bytes,
            .seed_ranges = boot_seed_ranges,
            .epoch_ms = config.dirty_tracking.epoch_ms,
        });
        if (dirty_tracker) |*tracker| {
            ram.dirty_context = tracker;
            ram.dirty_fn = DirtyTracker.markGuestWriteCallback;
            try tracker.startWorker();
        }
    }

    const run_size = try kvm.ioctl(kvm_fd, kvm.KVM_GET_VCPU_MMAP_SIZE, 0, "KVM_GET_VCPU_MMAP_SIZE");
    const run_bytes = try std.posix.mmap(
        null,
        run_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        vcpu_fd,
        0,
    );
    defer std.posix.munmap(run_bytes);
    var run_wake_signal = KvmRunWakeSignal.install();
    defer run_wake_signal.deinit();
    var run_wake = KvmRunWake{
        .run = run_bytes,
        .process_id = linux.getpid(),
        .thread_id = linux.gettid(),
    };
    if (config.capture_request) |request_capture| {
        request_capture.setWake(wakeKvmRun, &run_wake);
    }
    if (config.exec_control) |control| {
        control.setWake(.{ .context = &run_wake, .wakeFn = wakeControlKvmRun });
    }
    config.network.setWake(.{ .context = &run_wake, .wakeFn = wakeNetworkKvmRun });
    defer config.network.clearWake();
    defer if (config.capture_request) |request_capture| request_capture.clearWake();

    const start_ms = try monotonicMs();
    if (restore_stats) |*stats| {
        stats.pre_run_ms = start_ms - stats.start_ms;
        std.log.info(
            "kvm restore metrics: mode={s} ram_mib={d} chunks={d} nonzero_chunks={d} manifest_ms={d} map_ram_ms={d} memory_ms={d} state_ms={d} pre_run_ms={d}",
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
    if (config.exec_probe) |probe| {
        probe.markStarted();
        try vsock_dev.attachHostStream(probe);
        try flushVsockRxKvm(vm_fd, &vsock_dev, &transports_buf[vsock_transport_index], ram, vsock_transport_index);
    }
    var exec_probe_done = false;
    var pending_kvm_completion = false;
    var did_capture_request = false;
    while (true) {
        if (config.network.failed()) return error.NetworkGatewayFailed;
        if (config.exec_control) |control| {
            if (pending_kvm_completion) {
                try kvm.completePendingExit(vcpu_fd, run_bytes);
                pending_kvm_completion = false;
            }
            switch (try control.poll(&vsock_dev)) {
                .keep_running => {},
                .stop => return .monitor_stopped,
                .snapshot => |request| {
                    try takeSnapshot(allocator, request.dir, @intCast(gic_dev.fd), vcpu_fd, transports, &gen_dev, &vsock_dev, ram_bytes, config.ram_size, config.rootfs, config.disk_snapshot, config.network_manifest, config.annotations, if (dirty_tracker) |*tracker| tracker else null, config.environ_map);
                    if (!request.continue_after) return .snapshotted;
                    try control.completeSnapshot(request.dir);
                },
            }
            try flushVsockRxKvm(vm_fd, &vsock_dev, &transports_buf[vsock_transport_index], ram, vsock_transport_index);
        }
        if (config.capture_request) |request_capture| {
            if (request_capture.isAbortRequested()) return error.CaptureAborted;
            if (request_capture.isRequested() and !did_capture_request) {
                if (pending_kvm_completion) {
                    try kvm.completePendingExit(vcpu_fd, run_bytes);
                    pending_kvm_completion = false;
                }
                const dir = config.snapshot_dir orelse return error.KvmIoctlFailed;
                try takeSnapshot(allocator, dir, @intCast(gic_dev.fd), vcpu_fd, transports, &gen_dev, &vsock_dev, ram_bytes, config.ram_size, config.rootfs, config.disk_snapshot, config.network_manifest, config.annotations, if (dirty_tracker) |*tracker| tracker else null, config.environ_map);
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
                    if (pending_kvm_completion) {
                        try kvm.completePendingExit(vcpu_fd, run_bytes);
                        pending_kvm_completion = false;
                    }
                    vsock_dev.host_stream = null;
                    exec_probe_done = true;
                }
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
                    if (config.exec_probe_completes_run) {
                        if (config.snapshot_on_probe_complete) {
                            const dir = config.snapshot_dir orelse return error.KvmIoctlFailed;
                            try takeSnapshot(allocator, dir, @intCast(gic_dev.fd), vcpu_fd, transports, &gen_dev, &vsock_dev, ram_bytes, config.ram_size, config.rootfs, config.disk_snapshot, config.network_manifest, config.annotations, if (dirty_tracker) |*tracker| tracker else null, config.environ_map);
                            return .snapshotted;
                        }
                        return .probe_complete;
                    }
                    vsock_dev.host_stream = null;
                    exec_probe_done = true;
                }
                if (!exec_probe_done and probe.elapsedMs() > config.exec_probe_timeout_ms) {
                    if (config.exec_probe_failure_fatal) return error.VsockProbeTimedOut;
                    if (pending_kvm_completion) {
                        try kvm.completePendingExit(vcpu_fd, run_bytes);
                        pending_kvm_completion = false;
                    }
                    vsock_dev.host_stream = null;
                    exec_probe_done = true;
                }
            }
        }
        if (config.snapshot_after_ms) |after_ms| {
            const elapsed_ms = (try monotonicMs()) - start_ms;
            if (elapsed_ms >= after_ms) {
                if (pending_kvm_completion) {
                    try kvm.completePendingExit(vcpu_fd, run_bytes);
                    pending_kvm_completion = false;
                }
                const dir = config.snapshot_dir orelse return error.KvmIoctlFailed;
                try takeSnapshot(allocator, dir, @intCast(gic_dev.fd), vcpu_fd, transports, &gen_dev, &vsock_dev, ram_bytes, config.ram_size, config.rootfs, config.disk_snapshot, config.network_manifest, config.annotations, if (dirty_tracker) |*tracker| tracker else null, config.environ_map);
                return .snapshotted;
            }
        }

        switch (try kvm.runVcpu(vcpu_fd)) {
            .completed => {
                const stopped_for_wake = run_bytes[kvm.RunLayout.immediate_exit] != 0;
                if (consumeCaptureWake(config.capture_request, run_bytes)) continue;
                if (config.network.failed()) continue;
                if (config.network.consumeWake()) {
                    try flushNetworkRxKvm(vm_fd, &net_dev, &transports_buf[net_transport_index], ram, net_transport_index);
                    if (stopped_for_wake) continue;
                }
                if (stopped_for_wake and config.exec_control != null) continue;
                pending_kvm_completion = false;
            },
            .interrupted => {
                const stopped_for_wake = run_bytes[kvm.RunLayout.immediate_exit] != 0;
                _ = consumeCaptureWake(config.capture_request, run_bytes);
                if (config.capture_request) |request_capture| {
                    if (request_capture.isRequested() or request_capture.isAbortRequested()) continue;
                }
                if (config.network.failed()) continue;
                if (config.network.consumeWake()) {
                    try flushNetworkRxKvm(vm_fd, &net_dev, &transports_buf[net_transport_index], ram, net_transport_index);
                    continue;
                }
                if (stopped_for_wake and config.exec_control != null) continue;
                continue;
            },
        }
        switch (kvm.exitReason(run_bytes)) {
            kvm.KVM_EXIT_MMIO => {
                try handleMmio(vm_fd, run_bytes, transports, &gen_dev, ram);
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

fn flushVsockRxKvm(
    vm_fd: std.c.fd_t,
    vsock_dev: *vsock.Vsock,
    transport: *mmio.Transport,
    ram: guestmem.GuestRam,
    transport_index: usize,
) !void {
    if (vsock_dev.flushPendingRx(&transport.queues, ram)) {
        transport.interrupt_status |= 1;
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
    if (net_dev.flushPendingRx(&transport.queues, ram)) {
        transport.interrupt_status |= 1;
        try kvm.setIrq(vm_fd, board.virtioDeviceIntid(@intCast(transport_index)), true);
    }
}

fn consumeCaptureWake(capture_request: ?*capture.Request, run_bytes: []u8) bool {
    if (run_bytes[kvm.RunLayout.immediate_exit] == 0) return false;
    run_bytes[kvm.RunLayout.immediate_exit] = 0;
    if (capture_request) |request_capture| {
        return request_capture.isRequested() or request_capture.isAbortRequested();
    }
    return false;
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

fn mapRam(allocator: std.mem.Allocator, config: Config, manifest: ?spore.Manifest) !RamMapping {
    _ = allocator;
    if (config.ram_backing_fd) |fd| {
        const m = manifest orelse return error.BadManifest;
        const backing = m.memory.backing orelse return error.BadManifest;
        try spore.validateMemoryBacking(backing, config.ram_size);
        return mapFileBackedRamFd(fd, config.ram_size);
    }
    return mapAnonymousRam(config.ram_size);
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
    vm_fd: std.c.fd_t,
    slot: u32,
    bitmap: []usize,
    epoch_ms: u64,
    mutex: SpinLock = .{},
    stop: std.atomic.Value(bool) = .init(false),
    worker_thread: ?std.Thread = null,
    stop_read_fd: std.c.fd_t = -1,
    stop_write_fd: std.c.fd_t = -1,
    worker_failed: bool = false,
    tracking_start_ms: u64 = 0,
    stats: DirtyStats = .{},

    const Options = struct {
        vm_fd: std.c.fd_t,
        slot: u32,
        dir: []const u8,
        ram: []const u8,
        seed_ranges: ?[]const dirty_ram.ChunkRange = null,
        epoch_ms: u64,
    };

    const DirtyStats = struct {
        dirty_epoch_ms: u64 = 0,
        dirty_epoch_count: u64 = 0,
        dirty_pages_total: u64 = 0,
        dirty_pages_tail: u64 = 0,
        get_dirty_log_ms: u64 = 0,
        get_dirty_log_cpu_ms: u64 = 0,
        worker_epoch_max_ms: u64 = 0,
        worker_cadence_lag_max_ms: u64 = 0,
        worker_cadence_lag_total_ms: u64 = 0,
        worker_epoch_overrun_count: u64 = 0,
        worker_epoch_overrun_ms: u64 = 0,
        worker_join_ms: u64 = 0,
        finish_worker_stop_ms: u64 = 0,
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
            .epoch_ms = options.epoch_ms,
        };
        tracker.stats.dirty_epoch_ms = options.epoch_ms;

        // Some kernels conservatively mark a logging memslot dirty at
        // creation. Drop that baseline after the host has loaded the kernel,
        // initrd, and DTB so subsequent epochs measure guest writes only.
        _ = try tracker.collectDirtyLog(false);
        tracker.resetDirtyStatsAfterBaseline();
        tracker.tracking_start_ms = try monotonicMs();

        std.log.info(
            "kvm dirty tracking started: mode=dirty-log ram_mib={d} chunks={d} seed_nonzero_chunks={d} seed_ms={d} epoch_ms={d}",
            .{ options.ram.len / 1024 / 1024, tracker.sealer.chunkCount(), tracker.sealer.stats.seed_nonzero_chunks, tracker.sealer.stats.seed_ms, options.epoch_ms },
        );
        return tracker;
    }

    fn deinit(self: *DirtyTracker) void {
        self.stopWorker();
        self.sealer.deinit();
    }

    fn startWorker(self: *DirtyTracker) !void {
        if (self.epoch_ms == 0) return;
        var stop_pipe: [2]std.c.fd_t = undefined;
        try linuxCall(linux.pipe2(&stop_pipe, .{ .CLOEXEC = true }));
        errdefer closeFd(stop_pipe[0]);
        errdefer closeFd(stop_pipe[1]);
        self.stop_read_fd = stop_pipe[0];
        self.stop_write_fd = stop_pipe[1];
        errdefer {
            closeFd(self.stop_read_fd);
            closeFd(self.stop_write_fd);
            self.stop_read_fd = -1;
            self.stop_write_fd = -1;
        }
        self.worker_thread = try std.Thread.spawn(.{}, dirtyWorker, .{self});
        std.log.info("kvm dirty tracking worker started: epoch_ms={d}", .{self.epoch_ms});
    }

    fn stopWorker(self: *DirtyTracker) void {
        if (self.worker_thread) |thread| {
            const join_start = monotonicMs() catch 0;
            self.stop.store(true, .release);
            var byte: [1]u8 = .{1};
            if (self.stop_write_fd >= 0) _ = linux.write(self.stop_write_fd, &byte, byte.len);
            thread.join();
            self.worker_thread = null;
            const join_end = monotonicMs() catch join_start;
            self.stats.worker_join_ms += join_end - join_start;
        }
        if (self.stop_read_fd >= 0) {
            closeFd(self.stop_read_fd);
            self.stop_read_fd = -1;
        }
        if (self.stop_write_fd >= 0) {
            closeFd(self.stop_write_fd);
            self.stop_write_fd = -1;
        }
    }

    fn dirtyWorker(self: *DirtyTracker) void {
        var next_deadline = (monotonicMs() catch 0) +| self.epoch_ms;
        while (true) {
            if (self.stop.load(.acquire)) return;
            const now = monotonicMs() catch 0;
            const wait_ms = if (next_deadline > now) next_deadline - now else 0;
            const timeout_ms: i32 = if (wait_ms > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(wait_ms);
            var fds = [_]linux.pollfd{.{ .fd = self.stop_read_fd, .events = linux.POLL.IN, .revents = 0 }};
            const rc = linux.poll(&fds, fds.len, timeout_ms);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => {
                    self.markWorkerFailed();
                    return;
                },
            }
            if (rc > 0 and fds[0].revents != 0) return;
            if (self.stop.load(.acquire)) return;
            const epoch_start = monotonicMs() catch 0;
            self.flushDirty(false) catch {
                self.markWorkerFailed();
                return;
            };
            const epoch_end = monotonicMs() catch epoch_start;
            self.recordWorkerEpochTiming(epoch_start, epoch_end, next_deadline);
            next_deadline = epoch_start +| self.epoch_ms;
        }
    }

    fn markWorkerFailed(self: *DirtyTracker) void {
        self.mutex.lock();
        self.worker_failed = true;
        self.mutex.unlock();
    }

    fn recordWorkerEpochTiming(self: *DirtyTracker, epoch_start: u64, epoch_end: u64, deadline_ms: u64) void {
        const epoch_ms = epoch_end -| epoch_start;
        const lag_ms = if (epoch_start > deadline_ms) epoch_start - deadline_ms else 0;
        const overrun_ms = if (epoch_ms > self.epoch_ms) epoch_ms - self.epoch_ms else 0;

        self.mutex.lock();
        defer self.mutex.unlock();
        if (epoch_ms > self.stats.worker_epoch_max_ms) self.stats.worker_epoch_max_ms = epoch_ms;
        if (lag_ms > self.stats.worker_cadence_lag_max_ms) self.stats.worker_cadence_lag_max_ms = lag_ms;
        self.stats.worker_cadence_lag_total_ms +|= lag_ms;
        if (overrun_ms != 0) {
            self.stats.worker_epoch_overrun_count +|= 1;
            self.stats.worker_epoch_overrun_ms +|= overrun_ms;
        }
    }

    fn finish(self: *DirtyTracker) !spore.MemoryManifest {
        const worker_stop_start = try monotonicMs();
        self.stopWorker();
        self.stats.finish_worker_stop_ms = (try monotonicMs()) - worker_stop_start;
        if (self.worker_failed) return error.KvmDirtyWorkerFailed;

        const tail_start = try monotonicMs();
        try self.flushDirty(true);
        self.sealer.stats.tail_flush_ms = (try monotonicMs()) - tail_start;
        const now_ms = try monotonicMs();
        self.sealer.finishRates(self.tracking_start_ms, now_ms);
        self.stats.dirty_pages_per_sec = ratePerSec(self.stats.dirty_pages_total, self.sealer.stats.tracking_ms);
        return try self.sealer.finishBacking();
    }

    fn flushDirty(self: *DirtyTracker, tail: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.flushDirtyLocked(tail);
    }

    fn flushDirtyLocked(self: *DirtyTracker, tail: bool) !void {
        const dirty_pages = try self.collectDirtyLog(tail);
        if (dirty_pages == 0 and !self.sealer.hasDirtyChunks()) return;
        _ = try self.sealer.flushMarked(.{
            .tail = tail,
            .stop = &self.stop,
            .record_cpu = true,
        });
    }

    fn collectDirtyLog(self: *DirtyTracker, tail: bool) !u64 {
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
        if (!tail) self.stats.dirty_epoch_count += 1;

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
        if (tail) self.stats.dirty_pages_tail += dirty_pages;
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
        self.stats.dirty_epoch_count = 0;
        self.stats.dirty_pages_total = 0;
        self.stats.dirty_pages_tail = 0;
        self.stats.get_dirty_log_ms = 0;
        self.stats.get_dirty_log_cpu_ms = 0;
        self.stats.worker_epoch_max_ms = 0;
        self.stats.worker_cadence_lag_max_ms = 0;
        self.stats.worker_cadence_lag_total_ms = 0;
        self.stats.worker_epoch_overrun_count = 0;
        self.stats.worker_epoch_overrun_ms = 0;
        self.stats.worker_join_ms = 0;
        self.stats.finish_worker_stop_ms = 0;
        self.stats.dirty_pages_per_sec = 0;
        self.sealer.resetStatsAfterBaseline();
        @memset(self.bitmap, 0);
    }
};

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
    rootfs: ?spore.Rootfs,
    disk_snapshot: ?disk_layer.SnapshotState,
    network_manifest: ?spore.Network,
    annotations: spore.Annotations,
    dirty_tracker: ?*DirtyTracker,
    environ_map: ?*const std.process.Environ.Map,
) !void {
    if (vsock_dev.pending_len != 0) {
        std.log.err("cannot snapshot while virtio-vsock has pending packets", .{});
        return error.DeviceStatePending;
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const total_start = try monotonicMs();
    const machine_start = total_start;
    const machine = try snapshot.captureMachine(arena, gic_fd, vcpu_fd);
    const machine_ms = (try monotonicMs()) - machine_start;
    const devices_start = try monotonicMs();
    const devices = try captureTransports(arena, transports);
    const devices_ms = (try monotonicMs()) - devices_start;
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
        spore.writeLocalMemoryBackingProof(arena, environ, dir, memory, ram_size) catch |err| {
            std.log.debug("local RAM backing proof unavailable: {s}", .{@errorName(err)});
        };
    }
    const disk_manifest = if (disk_snapshot) |disk_state| try disk_state.finish(arena, dir) else null;
    const manifest_start = try monotonicMs();
    try spore.saveManifest(arena, dir, .{
        .platform = .{
            .cpu_profile = board.cpu_profile,
            .device_model_version = board.device_model_version,
            .ram_base = board.ram_base,
            .ram_size = ram_size,
            .gic_dist_base = gic_dist_base,
            .gic_redist_base = gic_redist_base,
            .counter_frequency_hz = snapshot.hostCounterFreq(),
        },
        .machine = machine,
        .devices = devices,
        .generation = gen_state,
        .annotations = annotations,
        .rootfs = rootfs,
        .disk = disk_manifest,
        .network = network_manifest,
        .memory = memory,
    });
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
            "kvm snapshot metrics: mode=dirty-log ram_mib={d} chunks={d} nonzero_chunks={d} machine_ms={d} devices_ms={d} generation_ms={d} memory_ms={d} manifest_ms={d} snapshot_pause_ms={d} snapshot_total_ms={d} dirty_epoch_ms={d} dirty_epoch_count={d} dirty_pages_total={d} dirty_pages_tail={d} dirty_chunks_total={d} dirty_chunks_tail={d} host_dirty_ranges_total={d} host_dirty_chunks_total={d} sealed_chunks_total={d} seed_ms={d} seed_chunks={d} seed_nonzero_chunks={d} tail_flush_ms={d}",
            .{
                ram_size / 1024 / 1024,
                memory_plan.chunk_count,
                memory_plan.nonzero_chunk_count,
                machine_ms,
                devices_ms,
                generation_ms,
                memory_ms,
                manifest_ms,
                snapshot_total_ms,
                snapshot_total_ms,
                stats.dirty_epoch_ms,
                stats.dirty_epoch_count,
                stats.dirty_pages_total,
                stats.dirty_pages_tail,
                ram_stats.dirty_chunks_total,
                ram_stats.dirty_chunks_tail,
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
            " get_dirty_log_ms={d} get_dirty_log_cpu_ms={d} seal_ms={d} seal_cpu_ms={d} seal_zero_scan_ms={d} seal_hash_ms={d} seal_chunk_write_ms={d} seal_backing_write_ms={d} seal_parallel_flush_count={d} seal_parallel_workers_max={d} worker_epoch_max_ms={d} worker_cadence_lag_max_ms={d} worker_cadence_lag_total_ms={d} worker_epoch_overrun_count={d} worker_epoch_overrun_ms={d} worker_join_ms={d} finish_worker_stop_ms={d} finish_fchmod_ms={d} finish_close_ms={d} finish_close_deferred={d} finish_rename_ms={d} tracking_ms={d} dirty_pages_per_sec={d} sealed_chunks_per_sec={d}",
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
                stats.worker_epoch_max_ms,
                stats.worker_cadence_lag_max_ms,
                stats.worker_cadence_lag_total_ms,
                stats.worker_epoch_overrun_count,
                stats.worker_epoch_overrun_ms,
                stats.worker_join_ms,
                stats.finish_worker_stop_ms,
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
            "kvm snapshot metrics: mode=full-scan ram_mib={d} chunks={d} nonzero_chunks={d} machine_ms={d} devices_ms={d} generation_ms={d} memory_ms={d} manifest_ms={d} snapshot_pause_ms={d} snapshot_total_ms={d}",
            .{
                ram_size / 1024 / 1024,
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
            t.queues[qi] = .{
                .size = qs.size,
                .ready = qs.ready,
                .desc_addr = qs.desc_addr,
                .avail_addr = qs.avail_addr,
                .used_addr = qs.used_addr,
                .last_avail = qs.last_avail,
                .used_idx = qs.used_idx,
            };
        }
    }
}

fn raiseGenerationIrqIfPending(vm_fd: std.c.fd_t, gen_dev: *const generation.Device) !void {
    if (gen_dev.interrupt_status & generation.irq_generation_changed != 0) {
        try kvm.setIrq(vm_fd, board.generationIntid(), true);
    }
}

fn closeFd(fd: std.c.fd_t) void {
    _ = std.c.close(fd);
}

fn linuxCall(rc: usize) !void {
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => return error.IoFailed,
    }
}

fn createGic(vm_fd: std.c.fd_t) !kvm.CreateDevice {
    var dev = kvm.CreateDevice{ .type = kvm.KVM_DEV_TYPE_ARM_VGIC_V3, .fd = 0, .flags = 0 };
    _ = try kvm.ioctl(vm_fd, kvm.KVM_CREATE_DEVICE, @intFromPtr(&dev), "KVM_CREATE_DEVICE vgicv3");
    var dist = gic_dist_base;
    var redist = gic_redist_base;
    try setDeviceAttr(dev.fd, kvm.KVM_DEV_ARM_VGIC_GRP_ADDR, kvm.KVM_VGIC_V3_ADDR_TYPE_DIST, &dist, "vgic dist addr");
    try setDeviceAttr(dev.fd, kvm.KVM_DEV_ARM_VGIC_GRP_ADDR, kvm.KVM_VGIC_V3_ADDR_TYPE_REDIST, &redist, "vgic redist addr");
    return dev;
}

fn initGic(gic_fd: u32) !void {
    var unused: u64 = 0;
    try setDeviceAttr(gic_fd, kvm.KVM_DEV_ARM_VGIC_GRP_CTRL, kvm.KVM_DEV_ARM_VGIC_CTRL_INIT, &unused, "vgic init");
}

fn setDeviceAttr(fd: u32, group: u32, attr_id: u64, value: *u64, op: []const u8) !void {
    var attr = kvm.DeviceAttr{
        .flags = 0,
        .group = group,
        .attr = attr_id,
        .addr = @intFromPtr(value),
    };
    _ = try kvm.ioctl(@intCast(fd), kvm.KVM_SET_DEVICE_ATTR, @intFromPtr(&attr), op);
}

fn initVcpu(vm_fd: std.c.fd_t, vcpu_fd: std.c.fd_t) !void {
    var init = kvm.VcpuInit{ .target = 0, .features = @splat(0) };
    _ = try kvm.ioctl(vm_fd, kvm.KVM_ARM_PREFERRED_TARGET, @intFromPtr(&init), "KVM_ARM_PREFERRED_TARGET");
    setFeature(&init, kvm.KVM_ARM_VCPU_PSCI_0_2);
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
