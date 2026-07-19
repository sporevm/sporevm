//! Fresh-only x86-64 Linux/KVM virtual machine.
//!
//! Slice 2a combines the frozen board and approved CPU profile with the shared
//! device model. It deliberately excludes snapshots and persistent disk paths.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const generation = @import("../generation.zig");
const guestmem = @import("../guestmem.zig");
const kvm = @import("../kvm/x86_64.zig");
const topology = @import("../topology.zig");
const mmio = @import("../virtio/mmio.zig");
const virtio_queue = @import("../virtio/queue.zig");
const virtio_blk = @import("../virtio/blk.zig");
const virtio_console = @import("../virtio/console.zig");
const virtio_net = @import("../virtio/net.zig");
const virtio_rng = @import("../virtio/rng.zig");
const virtio_vsock = @import("../virtio/vsock.zig");
const board = @import("board.zig");
const boot = @import("boot.zig");
const cpu = @import("cpu.zig");
const cpu_profile = @import("cpu_profile.zig");
const host_evidence = @import("host_evidence.zig");
const lifecycle = @import("lifecycle.zig");
const pio = @import("pio.zig");

pub const default_vcpu_count: u8 = 2;
const wake_signal = posix.SIG.URG;
const msr_capacity = 256;

pub const GenerationSeed = struct {
    generation: u64,
    params: []const u8,
};

pub const Config = struct {
    kernel: []const u8,
    initrd: ?[]const u8,
    cmdline: []const u8,
    ram_size: u64,
    vcpu_count: u8 = default_vcpu_count,
    console_sink: *const fn ([]const u8) void,
    root_disk: ?virtio_blk.Backend = null,
    context_disk: ?virtio_blk.Backend = null,
    build_disk: ?virtio_blk.Backend = null,
    cache_disk: ?virtio_blk.Backend = null,
    network: virtio_net.Runtime = .{},
    exec_probe: ?*virtio_vsock.HostStream = null,
    exec_probe_timeout_ms: u64 = 30_000,
    generation_seed: ?GenerationSeed = null,
};

pub const ExitCause = union(enum) {
    terminal: lifecycle.Terminal,
    probe_complete,
};

pub fn formatTerminalEvidence(buffer: []u8, terminal: lifecycle.Terminal) ![]const u8 {
    return lifecycle.formatEvidence(buffer, terminal);
}

fn requireCompatibleProfile(facts: cpu_profile.HostFacts, requested_vcpus: u8) !void {
    if (cpu_profile.compatibility(facts, requested_vcpus)) |failure| {
        std.log.warn("refusing incompatible x86 CPU profile: {any}", .{failure});
        switch (failure) {
            .unsupported_cpuid => |selector| {
                const requested = try cpu_profile.candidateCpuid(requested_vcpus, 0);
                for (requested.entries[0..requested.nent]) |entry| {
                    if (entry.function != selector.function or entry.index != selector.index) continue;
                    std.log.warn("requested CPUID {x}:{x} eax={x} ebx={x} ecx={x} edx={x}", .{ entry.function, entry.index, entry.eax, entry.ebx, entry.ecx, entry.edx });
                }
                for (facts.supported_cpuid) |entry| {
                    if (entry.function != selector.function or entry.index != selector.index) continue;
                    std.log.warn("supported CPUID {x}:{x} eax={x} ebx={x} ecx={x} edx={x}", .{ entry.function, entry.index, entry.eax, entry.ebx, entry.ecx, entry.edx });
                }
            },
            else => {},
        }
        return error.IncompatibleCpuProfile;
    }
}

fn profileCapabilityAvailable(facts: []const cpu_profile.CapabilityFact, id: u32) bool {
    for (facts) |fact| if (fact.id == id) return fact.value != 0;
    return false;
}

const Vcpu = struct {
    index: u8 = 0,
    fd: std.c.fd_t = -1,
    run_bytes: []align(std.heap.page_size_min) u8 = undefined,
    run_mapped: bool = false,
    thread: ?std.Thread = null,
    thread_id: std.atomic.Value(linux.pid_t) = .init(0),

    fn joinThread(self: *Vcpu) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn releaseResources(self: *Vcpu) void {
        std.debug.assert(self.thread == null);
        if (self.run_mapped) std.posix.munmap(self.run_bytes);
        self.run_mapped = false;
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.fd = -1;
    }
};

fn joinThreads(entries: anytype) void {
    for (entries) |*entry| entry.joinThread();
}

fn teardownThreadResources(entries: anytype) void {
    // A live worker may still address every kvm_run page through WakeSet, so
    // collection-wide join is a barrier before releasing any entry.
    joinThreads(entries);
    for (entries) |*entry| entry.releaseResources();
}

const WakeSet = struct {
    vcpus: []Vcpu,

    fn wakeAll(self: *WakeSet) void {
        for (self.vcpus) |*vcpu| {
            requestWake(vcpu.run_bytes);
            const tid = vcpu.thread_id.load(.acquire);
            if (tid != 0) _ = linux.tgkill(linux.getpid(), tid, @enumFromInt(@intFromEnum(wake_signal)));
        }
    }
};

fn wakeNetwork(context: ?*anyopaque) void {
    const wake_set: *WakeSet = @ptrCast(@alignCast(context orelse return));
    wake_set.wakeAll();
}

const WakeSignal = struct {
    old_action: posix.Sigaction,
    active: bool = false,

    fn install() WakeSignal {
        var old_action: posix.Sigaction = undefined;
        const action = posix.Sigaction{
            .handler = .{ .sigaction = handleWakeSignal },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.SIGINFO,
        };
        posix.sigaction(wake_signal, &action, &old_action);
        return .{ .old_action = old_action, .active = true };
    }

    fn deinit(self: *WakeSignal) void {
        if (!self.active) return;
        posix.sigaction(wake_signal, &self.old_action, null);
        self.active = false;
    }
};

fn handleWakeSignal(_: posix.SIG, _: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {}

const RunResult = union(enum) {
    cause: ExitCause,
    err: anyerror,
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

const RunState = struct {
    mutex: SpinLock = .{},
    stop: std.atomic.Value(bool) = .init(false),
    phase: union(enum) {
        open,
        reserved: struct {
            owner: u8,
            cause: ExitCause,
            completed: bool = false,
        },
        published: RunResult,
    } = .open,

    fn finishError(self: *RunState, err: anyerror) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return switch (self.phase) {
            .open => blk: {
                self.phase = .{ .published = .{ .err = err } };
                self.stop.store(true, .release);
                break :blk true;
            },
            .reserved, .published => false,
        };
    }

    fn reserveTerminal(self: *RunState, terminal: lifecycle.Terminal) bool {
        return self.reserveCause(terminal.vcpu_index, .{ .terminal = terminal });
    }

    fn reserveProbeComplete(self: *RunState, owner: u8) bool {
        return self.reserveCause(owner, .probe_complete);
    }

    fn reserveCause(self: *RunState, owner: u8, cause: ExitCause) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return switch (self.phase) {
            .open => blk: {
                self.phase = .{ .reserved = .{ .owner = owner, .cause = cause } };
                break :blk true;
            },
            .reserved, .published => false,
        };
    }

    fn markTerminalCompleted(self: *RunState, owner: u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return switch (self.phase) {
            .reserved => |*reservation| blk: {
                if (reservation.owner != owner or reservation.completed) break :blk false;
                reservation.completed = true;
                break :blk true;
            },
            .open, .published => false,
        };
    }

    fn publishReserved(self: *RunState, owner: u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return switch (self.phase) {
            .reserved => |reservation| blk: {
                if (reservation.owner != owner or !reservation.completed) break :blk false;
                self.phase = .{ .published = .{ .cause = reservation.cause } };
                self.stop.store(true, .release);
                break :blk true;
            },
            .open, .published => false,
        };
    }

    fn failReserved(self: *RunState, owner: u8, err: anyerror) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return switch (self.phase) {
            .reserved => |reservation| blk: {
                if (reservation.owner != owner) break :blk false;
                self.phase = .{ .published = .{ .err = err } };
                self.stop.store(true, .release);
                break :blk true;
            },
            .open, .published => false,
        };
    }

    fn publishedResult(self: *RunState) ?RunResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        return switch (self.phase) {
            .published => |result| result,
            .open, .reserved => null,
        };
    }

    fn stopped(self: *const RunState) bool {
        return self.stop.load(.acquire);
    }
};

const ThreadContext = struct {
    vm_fd: std.c.fd_t,
    vcpu: *Vcpu,
    state: *RunState,
    wake_set: *WakeSet,
    device_lock: *SpinLock,
    transports: *[board.max_virtio_devices]mmio.Transport,
    gen_dev: *generation.Device,
    exec_probe: ?*virtio_vsock.HostStream,
    network: virtio_net.Runtime,
    net_dev: *virtio_net.Net,
    ram: guestmem.GuestRam,
};

const EmptyDevice = struct {
    fn notify(_: *anyopaque, _: u8, _: *[mmio.max_queues]virtio_queue.VirtQueue, _: guestmem.GuestRam) bool {
        return false;
    }

    fn device(self: *EmptyDevice) mmio.Device {
        return .{
            .context = self,
            .device_id = 0,
            .device_features = 0,
            .queue_count = 0,
            .notifyFn = notify,
        };
    }
};

const ProbeWatchdogContext = struct {
    state: *RunState,
    wake_set: *WakeSet,
    timeout_ms: u64,
};

fn probeWatchdogMain(ctx: *ProbeWatchdogContext) void {
    const start = monotonicMs();
    while (!ctx.state.stopped()) {
        const now = monotonicMs();
        if (now >= start and now - start >= ctx.timeout_ms) {
            if (ctx.state.finishError(error.ExecProbeTimeout)) ctx.wake_set.wakeAll();
            return;
        }
        var delay = std.c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.c.nanosleep(&delay, null);
    }
}

const KvmPostRunAction = enum { dispatch_exit, handle_async_wake, retry_not_runnable };

fn kvmPostRunAction(result: kvm.RunResult) KvmPostRunAction {
    return switch (result) {
        .completed => .dispatch_exit,
        .interrupted => .handle_async_wake,
        .not_runnable => .retry_not_runnable,
    };
}

pub fn run(allocator: std.mem.Allocator, config: Config) !ExitCause {
    _ = allocator;
    try board.validateLayout(config.ram_size);
    try topology.validateVcpuCount(config.vcpu_count);
    if (config.exec_probe != null and config.exec_probe_timeout_ms == 0) return error.InvalidProbeTimeout;

    const kvm_fd = try kvm.openDevKvm();
    defer _ = std.c.close(kvm_fd);
    try kvm.checkApiVersion(kvm_fd);
    var profile_capabilities: [cpu_profile.required_capabilities.len]cpu_profile.CapabilityFact = undefined;
    for (cpu_profile.required_capabilities, &profile_capabilities) |required, *fact| {
        const value = try kvm.checkExtension(kvm_fd, required.id);
        fact.* = .{ .id = required.id, .value = std.math.cast(u32, value) orelse return error.CapabilityValueTooLarge };
    }
    const capabilities = try host_evidence.collectCapabilities(kvm_fd);
    var host_buffer: [512]u8 = undefined;
    std.debug.print("sporevm kvm-boot: {s}\n", .{try host_evidence.formatCapabilities(&host_buffer, capabilities)});
    if (capabilities.nrVcpus() < config.vcpu_count) {
        return error.UnsupportedVcpuCount;
    }

    const supported_cpuid = try kvm.getSupportedCpuid(kvm_fd);
    const cpuid_evidence = try host_evidence.collectCpuid(&supported_cpuid);
    std.debug.print("sporevm kvm-boot: {s}\n", .{try host_evidence.formatCpuid(&host_buffer, cpuid_evidence)});
    var msr_list = kvm.MsrList(msr_capacity){};
    const msr_indices = try kvm.getMsrIndexList(kvm_fd, kvm.KVM_GET_MSR_INDEX_LIST, msr_capacity, &msr_list, "KVM_GET_MSR_INDEX_LIST fresh runner");
    const xsave2_bytes = try kvm.checkExtension(kvm_fd, kvm.KVM_CAP_XSAVE2);
    const xsave_bytes = if (xsave2_bytes == 0)
        @as(u32, @sizeOf(kvm.Xsave))
    else
        std.math.cast(u32, xsave2_bytes) orelse return error.XsaveSizeTooLarge;
    var profile_facts = cpu_profile.HostFacts{
        .api_version = kvm.KVM_API_VERSION,
        .vendor = cpuid_evidence.vendor,
        .max_vcpus = std.math.cast(u32, capabilities.nrVcpus()) orelse return error.VcpuCapacityTooLarge,
        .capabilities = &profile_capabilities,
        .msr_indices = msr_indices,
        .supported_cpuid = supported_cpuid.entries[0..supported_cpuid.nent],
        .xsave_bytes = xsave_bytes,
        // The VM-scoped frequency is verified on the first vCPU below.
        .tsc_khz = cpu_profile.guest_tsc_khz,
        .has_tsc_offset = profileCapabilityAvailable(&profile_capabilities, kvm.KVM_CAP_TSC_CONTROL) and
            profileCapabilityAvailable(&profile_capabilities, kvm.KVM_CAP_VM_TSC_CONTROL),
    };
    try requireCompatibleProfile(profile_facts, config.vcpu_count);
    const vm_fd: std.c.fd_t = @intCast(try kvm.ioctl(kvm_fd, kvm.KVM_CREATE_VM, 0, "KVM_CREATE_VM"));
    defer _ = std.c.close(vm_fd);

    var exception_payload = kvm.EnableCap{ .cap = kvm.KVM_CAP_EXCEPTION_PAYLOAD, .args = .{ 1, 0, 0, 0 } };
    _ = try kvm.ioctl(vm_fd, kvm.KVM_ENABLE_CAP, @intFromPtr(&exception_payload), "KVM_ENABLE_CAP exception payload");
    _ = try kvm.ioctl(vm_fd, kvm.KVM_SET_TSC_KHZ, cpu_profile.guest_tsc_khz, "KVM_SET_TSC_KHZ VM before vCPUs");
    _ = try kvm.ioctl(vm_fd, kvm.KVM_SET_TSS_ADDR, board.tss_addr, "KVM_SET_TSS_ADDR");
    var identity_map_addr = board.identity_map_addr;
    _ = try kvm.ioctl(vm_fd, kvm.KVM_SET_IDENTITY_MAP_ADDR, @intFromPtr(&identity_map_addr), "KVM_SET_IDENTITY_MAP_ADDR");
    _ = try kvm.ioctl(vm_fd, kvm.KVM_CREATE_IRQCHIP, 0, "KVM_CREATE_IRQCHIP");
    var pit = kvm.PitConfig{};
    _ = try kvm.ioctl(vm_fd, kvm.KVM_CREATE_PIT2, @intFromPtr(&pit), "KVM_CREATE_PIT2");
    std.debug.print("sporevm kvm-boot: setup tss=0x{x} identity_map=0x{x} irqchip=ok pit2=ok\n", .{ board.tss_addr, board.identity_map_addr });

    const ram = try std.posix.mmap(
        null,
        @intCast(config.ram_size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(ram);
    const layout = try boot.load(ram, config.kernel, config.initrd, config.cmdline, config.vcpu_count);
    const guest_ram = guestmem.GuestRam{ .bytes = ram, .base = 0 };

    var memory_region = kvm.UserspaceMemoryRegion{
        .slot = 0,
        .flags = 0,
        .guest_phys_addr = 0,
        .memory_size = config.ram_size,
        .userspace_addr = @intFromPtr(ram.ptr),
    };
    _ = try kvm.ioctl(vm_fd, kvm.KVM_SET_USER_MEMORY_REGION, @intFromPtr(&memory_region), "KVM_SET_USER_MEMORY_REGION");
    std.debug.print("sporevm kvm-boot: setup memslot=ok guest_phys=0x0 size={d}\n", .{config.ram_size});

    const run_size = try kvm.ioctl(kvm_fd, kvm.KVM_GET_VCPU_MMAP_SIZE, 0, "KVM_GET_VCPU_MMAP_SIZE");
    if (run_size < kvm.RunLayout.mmio_end) return error.KvmRunMappingTooSmall;
    var signal = WakeSignal.install();
    defer signal.deinit();
    var net_dev = virtio_net.Net.init(.{ .backend = config.network.backend });
    defer net_dev.shutdown();
    var vcpus: [topology.max_vcpus]Vcpu = undefined;
    var initialized: usize = 0;
    defer teardownThreadResources(vcpus[0..initialized]);

    // Every vCPU and its distinct CPUID is ready before any worker can enter
    // KVM_RUN, so Linux never observes a partially constructed topology.
    while (initialized < config.vcpu_count) : (initialized += 1) {
        const vcpu_fd: std.c.fd_t = @intCast(try kvm.ioctl(vm_fd, kvm.KVM_CREATE_VCPU, initialized, "KVM_CREATE_VCPU"));
        errdefer _ = std.c.close(vcpu_fd);
        const run_bytes = try std.posix.mmap(
            null,
            run_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            vcpu_fd,
            0,
        );
        errdefer std.posix.munmap(run_bytes);
        vcpus[initialized] = .{
            .index = @intCast(initialized),
            .fd = vcpu_fd,
            .run_bytes = run_bytes,
            .run_mapped = true,
        };
        var enforce_pv_cpuid = kvm.EnableCap{ .cap = kvm.KVM_CAP_ENFORCE_PV_FEATURE_CPUID };
        _ = try kvm.ioctl(vcpu_fd, kvm.KVM_ENABLE_CAP, @intFromPtr(&enforce_pv_cpuid), "KVM_ENABLE_CAP enforce PV CPUID");
        var cpuid = try cpu_profile.candidateCpuid(config.vcpu_count, @intCast(initialized));
        const tsc_khz = try kvm.ioctl(vcpu_fd, kvm.KVM_GET_TSC_KHZ, 0, "KVM_GET_TSC_KHZ after create");
        if (initialized == 0) {
            profile_facts.tsc_khz = tsc_khz;
            profile_facts.has_tsc_offset = try kvm.hasTscOffset(vcpu_fd);
            try requireCompatibleProfile(profile_facts, config.vcpu_count);
        }
        _ = try kvm.ioctl(vcpu_fd, kvm.KVM_SET_CPUID2, @intFromPtr(&cpuid), "KVM_SET_CPUID2");
    }
    std.debug.print("sporevm kvm-boot: setup profile={s} tsc_khz={d} set_cpuid2_vcpus={d}\n", .{ cpu_profile.profile_name, cpu_profile.guest_tsc_khz, initialized });
    try configureProtectedMode(vcpus[0].fd, layout);
    for (vcpus[1..initialized]) |*vcpu| {
        if ((try kvm.getMpState(vcpu.fd)).mp_state != kvm.KVM_MP_STATE_UNINITIALIZED) {
            return error.UnexpectedApState;
        }
    }
    std.debug.print("sporevm kvm-boot: setup bsp=protected-mode ap_initial_state=uninitialized ap_count={d}\n", .{initialized - 1});

    var console_dev = virtio_console.Console{ .sink = config.console_sink };
    var block_devs: [4]virtio_blk.Blk = undefined;
    var empty_devs: [4]EmptyDevice = @splat(.{});
    const disk_backends = [_]?virtio_blk.Backend{ config.root_disk, config.context_disk, config.build_disk, config.cache_disk };
    var vsock_dev = virtio_vsock.Vsock.init(.{});
    var rng_dev = virtio_rng.Rng{};
    var transports: [board.max_virtio_devices]mmio.Transport = undefined;
    transports[0] = .init(console_dev.device());
    for (disk_backends, 0..) |maybe_backend, index| {
        if (maybe_backend) |backend| {
            block_devs[index] = if (index == 0) .init(backend) else .initImmutableSource(backend);
            transports[index + 1] = .init(block_devs[index].device());
        } else {
            transports[index + 1] = .init(empty_devs[index].device());
        }
    }
    transports[5] = .init(net_dev.device());
    transports[6] = .init(vsock_dev.device());
    transports[7] = .init(rng_dev.device());
    try validateTransportSlots(&transports, disk_backends);
    var gen_dev = generation.Device{};
    if (config.generation_seed) |seed| {
        if (try gen_dev.setResume(seed.generation, seed.params)) {
            try kvm.setIrq(vm_fd, board.generation_gsi, true);
        }
    }
    if (config.exec_probe) |probe| try vsock_dev.attachHostStream(probe);

    var state = RunState{};
    var wake_set = WakeSet{ .vcpus = vcpus[0..initialized] };
    config.network.setWake(.{ .context = &wake_set, .wakeFn = wakeNetwork });
    defer config.network.clearWake();
    var device_lock = SpinLock{};
    var contexts: [topology.max_vcpus]ThreadContext = undefined;
    var started: usize = 0;
    while (started < initialized) : (started += 1) {
        contexts[started] = .{
            .vm_fd = vm_fd,
            .vcpu = &vcpus[started],
            .state = &state,
            .wake_set = &wake_set,
            .device_lock = &device_lock,
            .transports = &transports,
            .gen_dev = &gen_dev,
            .exec_probe = config.exec_probe,
            .network = config.network,
            .net_dev = &net_dev,
            .ram = guest_ram,
        };
        vcpus[started].thread = std.Thread.spawn(.{}, vcpuThreadMain, .{&contexts[started]}) catch |err| {
            if (state.finishError(err)) wake_set.wakeAll();
            return err;
        };
    }

    var watchdog_context = ProbeWatchdogContext{
        .state = &state,
        .wake_set = &wake_set,
        .timeout_ms = config.exec_probe_timeout_ms,
    };
    const watchdog = if (config.exec_probe != null)
        std.Thread.spawn(.{}, probeWatchdogMain, .{&watchdog_context}) catch |err| {
            if (state.finishError(err)) wake_set.wakeAll();
            return err;
        }
    else
        null;
    defer if (watchdog) |thread| thread.join();

    // Joining is safe because the first terminal/error result wakes every
    // KVM_RUN with immediate_exit plus a thread-directed SIGURG.
    joinThreads(vcpus[0..started]);
    const result = state.publishedResult() orelse return error.MissingVcpuResult;
    const cause: ExitCause = switch (result) {
        .cause => |cause| cause,
        .err => |err| return err,
    };
    if (cause == .probe_complete and gen_dev.interrupt_status != 0) return error.GenerationNotAcknowledged;
    return cause;
}

fn configureProtectedMode(vcpu_fd: std.c.fd_t, layout: boot.Plan) !void {
    var sregs: kvm.Sregs = undefined;
    _ = try kvm.ioctl(vcpu_fd, kvm.KVM_GET_SREGS, @intFromPtr(&sregs), "KVM_GET_SREGS");
    var state = cpu.protectedModeState(sregs, layout.kernel_load.start, layout.zero_page.start);
    _ = try kvm.ioctl(vcpu_fd, kvm.KVM_SET_SREGS, @intFromPtr(&state.sregs), "KVM_SET_SREGS");
    _ = try kvm.ioctl(vcpu_fd, kvm.KVM_SET_REGS, @intFromPtr(&state.regs), "KVM_SET_REGS");
}

fn vcpuThreadMain(ctx: *ThreadContext) void {
    ctx.vcpu.thread_id.store(linux.gettid(), .release);
    var pending_completion = false;
    while (true) {
        if (ctx.state.stopped()) {
            completePending(ctx, &pending_completion) catch |err| finishThread(ctx, err);
            return;
        }
        const run_result = kvm.runVcpu(ctx.vcpu.fd) catch |err| {
            finishThread(ctx, err);
            return;
        };
        // Re-entry completes the prior PIO/MMIO operation before KVM observes
        // immediate_exit or the wake signal.
        pending_completion = false;
        // A successful KVM_RUN publishes an authoritative exit_reason. A
        // racing immediate_exit stays set until the following re-entry so it
        // cannot make userspace discard the completed PIO/MMIO envelope.
        switch (kvmPostRunAction(run_result)) {
            .dispatch_exit => {},
            .handle_async_wake => {
                _ = consumeWake(ctx.vcpu.run_bytes);
                if (ctx.network.failed()) {
                    finishThread(ctx, error.NetworkGatewayFailed);
                    return;
                }
                ctx.device_lock.lock();
                if (ctx.network.consumeWake()) {
                    flushNetworkRx(ctx.vm_fd, ctx.net_dev, &ctx.transports[5], ctx.ram) catch |err| {
                        ctx.device_lock.unlock();
                        finishThread(ctx, err);
                        return;
                    };
                }
                ctx.device_lock.unlock();
                continue;
            },
            .retry_not_runnable => {
                _ = consumeWake(ctx.vcpu.run_bytes);
                if (!ctx.state.stopped()) sleepNotRunnableAp();
                continue;
            },
        }

        switch (kvm.exitReason(ctx.vcpu.run_bytes)) {
            kvm.KVM_EXIT_IO => {
                ctx.device_lock.lock();
                const terminal = handlePio(ctx.vcpu.index, ctx.vcpu.run_bytes) catch |err| {
                    ctx.device_lock.unlock();
                    finishThread(ctx, err);
                    return;
                };
                pending_completion = true;
                const owns_terminal = if (terminal) |result|
                    ctx.state.reserveTerminal(result)
                else
                    false;
                ctx.device_lock.unlock();
                if (terminal != null) {
                    completeTerminal(ctx, &pending_completion, owns_terminal);
                    return;
                }
            },
            kvm.KVM_EXIT_MMIO => {
                ctx.device_lock.lock();
                const terminal = handleMmio(ctx.vcpu.index, ctx.vm_fd, ctx.vcpu.run_bytes, ctx.transports, ctx.gen_dev, ctx.ram) catch |err| {
                    ctx.device_lock.unlock();
                    finishThread(ctx, err);
                    return;
                };
                pending_completion = true;
                var completes_run = terminal != null;
                var probe_failed = false;
                const owns_terminal = if (terminal) |result| ctx.state.reserveTerminal(result) else blk: {
                    if (ctx.exec_probe) |probe| switch (probe.state) {
                        .complete => {
                            completes_run = true;
                            break :blk ctx.state.reserveProbeComplete(ctx.vcpu.index);
                        },
                        .failed => probe_failed = true,
                        .idle, .connecting, .connected => {},
                    };
                    break :blk false;
                };
                ctx.device_lock.unlock();
                if (probe_failed) {
                    completePending(ctx, &pending_completion) catch |err| {
                        finishThread(ctx, err);
                        return;
                    };
                    finishThread(ctx, error.ExecProbeFailed);
                    return;
                }
                if (completes_run) {
                    completeTerminal(ctx, &pending_completion, owns_terminal);
                    return;
                }
            },
            kvm.KVM_EXIT_HLT => std.Thread.yield() catch {},
            kvm.KVM_EXIT_SYSTEM_EVENT => switch (readRunInt(u32, ctx.vcpu.run_bytes, kvm.RunLayout.system_event_type)) {
                kvm.KVM_SYSTEM_EVENT_SHUTDOWN => {
                    publishSystemTerminal(ctx, .{ .vcpu_index = ctx.vcpu.index, .cause = .{ .system_event_shutdown = .{
                        .exit_reason = kvm.KVM_EXIT_SYSTEM_EVENT,
                    } } });
                    return;
                },
                kvm.KVM_SYSTEM_EVENT_RESET => {
                    publishSystemTerminal(ctx, .{ .vcpu_index = ctx.vcpu.index, .cause = .{ .system_event_reset = .{
                        .exit_reason = kvm.KVM_EXIT_SYSTEM_EVENT,
                    } } });
                    return;
                },
                else => |event_type| {
                    std.log.err("raw unknown KVM_EXIT_SYSTEM_EVENT type={d} reason={d} vcpu={d}", .{
                        event_type,
                        kvm.KVM_EXIT_SYSTEM_EVENT,
                        ctx.vcpu.index,
                    });
                    finishThread(ctx, error.UnexpectedKvmExit);
                    return;
                },
            },
            // KVM_EXIT_SHUTDOWN commonly represents a triple fault. It remains
            // raw fatal evidence and never acquires reset or poweroff meaning.
            kvm.KVM_EXIT_SHUTDOWN => {
                std.log.err("raw unclassified KVM_EXIT_SHUTDOWN reason={d} vcpu={d}", .{ kvm.KVM_EXIT_SHUTDOWN, ctx.vcpu.index });
                finishThread(ctx, error.UnclassifiedKvmShutdown);
                return;
            },
            kvm.KVM_EXIT_FAIL_ENTRY, kvm.KVM_EXIT_INTERNAL_ERROR => {
                finishThread(ctx, error.UnexpectedKvmExit);
                return;
            },
            else => |reason| {
                std.log.err("unhandled x86 KVM exit reason {d} on vcpu {d}", .{ reason, ctx.vcpu.index });
                finishThread(ctx, error.UnexpectedKvmExit);
                return;
            },
        }
        if (ctx.state.stopped()) {
            completePending(ctx, &pending_completion) catch |err| finishThread(ctx, err);
            return;
        }
    }
}

fn finishThread(ctx: *ThreadContext, err: anyerror) void {
    if (ctx.state.finishError(err)) {
        ctx.wake_set.wakeAll();
    } else {
        logRefusedVcpuError(ctx, err);
    }
}

fn logRefusedVcpuError(ctx: *ThreadContext, err: anyerror) void {
    std.log.err("refused losing vCPU error vcpu={d} error={s}", .{ ctx.vcpu.index, @errorName(err) });
}

fn completePending(ctx: *ThreadContext, pending: *bool) !void {
    if (!pending.*) return;
    try kvm.completePendingExit(ctx.vcpu.fd, ctx.vcpu.run_bytes);
    pending.* = false;
}

fn completeTerminal(ctx: *ThreadContext, pending: *bool, owns_terminal: bool) void {
    // Reservation happens under device_lock, but deliberately does not stop or
    // wake any vCPU. The owner first completes its KVM exit; a losing terminal
    // also completes its own exit and returns without attempting publication.
    std.debug.assert(pending.*);
    completePending(ctx, pending) catch |err| {
        if (owns_terminal) {
            if (ctx.state.failReserved(ctx.vcpu.index, err)) {
                ctx.wake_set.wakeAll();
            } else {
                logRefusedVcpuError(ctx, err);
            }
        } else {
            finishThread(ctx, err);
        }
        return;
    };
    std.debug.assert(!pending.*);
    if (!owns_terminal) return;
    std.debug.assert(ctx.state.markTerminalCompleted(ctx.vcpu.index));
    if (ctx.state.publishReserved(ctx.vcpu.index)) ctx.wake_set.wakeAll();
}

fn publishSystemTerminal(ctx: *ThreadContext, terminal: lifecycle.Terminal) void {
    ctx.device_lock.lock();
    const owns_terminal = ctx.state.reserveTerminal(terminal);
    ctx.device_lock.unlock();
    if (!owns_terminal) return;
    std.debug.assert(ctx.state.markTerminalCompleted(ctx.vcpu.index));
    if (ctx.state.publishReserved(ctx.vcpu.index)) ctx.wake_set.wakeAll();
}

fn handlePio(vcpu_index: u8, run_bytes: []u8) !?lifecycle.Terminal {
    const exit = try kvm.decodeIoExit(run_bytes);
    const direction: pio.Direction = switch (exit.direction) {
        .read => .read,
        .write => .write,
    };
    const action = try pio.handle(.{
        .direction = direction,
        .width = exit.width,
        .port = exit.port,
        .count = exit.count,
        .data = exit.data,
    });
    return switch (action) {
        .continue_guest => null,
        .guest_reset => .{
            .vcpu_index = vcpu_index,
            .cause = .{ .pio_reset = .{
                .exit_reason = kvm.KVM_EXIT_IO,
                .width = exit.width,
                .port = exit.port,
                .count = exit.count,
                .value = exit.data[0],
            } },
        },
    };
}

const MmioTarget = union(enum) {
    virtio: struct { index: usize, offset: u64 },
    generation: u64,
};

const MmioExit = struct {
    target: MmioTarget,
    len: u32,
    is_write: bool,
    data: []u8,
};

fn decodeMmioTarget(phys_addr: u64, len: u32) !MmioTarget {
    if (len != 1 and len != 2 and len != 4 and len != 8) return error.MalformedMmioExit;
    const end = std.math.add(u64, phys_addr, len) catch return error.MalformedMmioExit;
    if (phys_addr >= board.virtio_base and phys_addr < board.generation_base) {
        if (len == 8) return error.MalformedMmioExit;
        if (phys_addr % len != 0) return error.MalformedMmioExit;
        const relative = phys_addr - board.virtio_base;
        const index: usize = @intCast(relative / board.virtio_stride);
        const offset = relative % board.virtio_stride;
        if (index >= board.max_virtio_devices or offset + len > board.virtio_window_size) return error.MalformedMmioExit;
        return .{ .virtio = .{ .index = index, .offset = offset } };
    }
    if (phys_addr >= board.generation_base and phys_addr < board.generation_base + board.generation_size) {
        if (end > board.generation_base + board.generation_size or phys_addr % len != 0) return error.MalformedMmioExit;
        return .{ .generation = phys_addr - board.generation_base };
    }
    return error.UnhandledMmio;
}

fn decodeMmioExit(run_bytes: []u8) !MmioExit {
    if (run_bytes.len < kvm.RunLayout.mmio_end) return error.MalformedMmioExit;
    const phys_addr = readRunInt(u64, run_bytes, kvm.RunLayout.mmio_phys_addr);
    const len = readRunInt(u32, run_bytes, kvm.RunLayout.mmio_len);
    const is_write = run_bytes[kvm.RunLayout.mmio_is_write];
    if (is_write > 1) return error.MalformedMmioExit;
    return .{
        .target = try decodeMmioTarget(phys_addr, len),
        .len = len,
        .is_write = is_write == 1,
        .data = run_bytes[kvm.RunLayout.mmio_data..][0..8],
    };
}

fn handleMmio(
    vcpu_index: u8,
    vm_fd: std.c.fd_t,
    run_bytes: []u8,
    transports: *[board.max_virtio_devices]mmio.Transport,
    gen_dev: *generation.Device,
    ram: guestmem.GuestRam,
) !?lifecycle.Terminal {
    const exit = try decodeMmioExit(run_bytes);
    switch (exit.target) {
        .virtio => |access| {
            const transport = &transports[access.index];
            const slot = board.virtio_slots[access.index];
            if (exit.is_write) {
                const value: u32 = @truncate(readMmioValue(exit.data, exit.len));
                const before = transport.interrupt_status;
                const raised = transport.write(access.offset, value, ram);
                switch (transportIrqAction(before, transport.interrupt_status, raised)) {
                    .none => {},
                    .raise => try kvm.setIrq(vm_fd, slot.gsi, true),
                    .lower => try kvm.setIrq(vm_fd, slot.gsi, false),
                }
            } else {
                writeMmioValue(exit.data, exit.len, transport.read(access.offset));
            }
            return null;
        },
        .generation => |offset| {
            const size_log2: u2 = switch (exit.len) {
                1 => 0,
                2 => 1,
                4 => 2,
                8 => 3,
                else => unreachable,
            };
            const value = readMmioValue(exit.data, exit.len);
            switch (try board.generationControlAction(offset, exit.len, exit.is_write, value)) {
                .none => if (exit.is_write) {
                    if (gen_dev.write(offset, value, size_log2)) try kvm.setIrq(vm_fd, board.generation_gsi, false);
                } else {
                    writeMmioValue(exit.data, exit.len, gen_dev.read(offset, size_log2));
                },
                .read_zero => writeMmioValue(exit.data, exit.len, 0),
                .guest_off => return .{
                    .vcpu_index = vcpu_index,
                    .cause = .{ .board_poweroff = .{
                        .exit_reason = kvm.KVM_EXIT_MMIO,
                        .gpa = board.generation_base + offset,
                        .offset = offset,
                        .len = exit.len,
                        .value = value,
                    } },
                },
            }
            return null;
        },
    }
}

const TransportIrqAction = enum { none, raise, lower };

fn transportIrqAction(before: u32, after: u32, raised: bool) TransportIrqAction {
    if (before != 0 and after == 0) return .lower;
    if (raised) return .raise;
    return .none;
}

fn flushNetworkRx(
    vm_fd: std.c.fd_t,
    net_dev: *virtio_net.Net,
    transport: *mmio.Transport,
    ram: guestmem.GuestRam,
) !void {
    if (net_dev.flushPendingRx(&transport.queues, ram)) {
        transport.interrupt_status |= 1;
        try kvm.setIrq(vm_fd, board.virtio_slots[5].gsi, true);
    }
}

fn readMmioValue(data: []const u8, len: u32) u64 {
    return switch (len) {
        1 => data[0],
        2 => std.mem.readInt(u16, data[0..2], .little),
        4 => std.mem.readInt(u32, data[0..4], .little),
        8 => std.mem.readInt(u64, data[0..8], .little),
        else => unreachable,
    };
}

fn writeMmioValue(data: []u8, len: u32, value: u64) void {
    switch (len) {
        1 => data[0] = @truncate(value),
        2 => std.mem.writeInt(u16, data[0..2], @truncate(value), .little),
        4 => std.mem.writeInt(u32, data[0..4], @truncate(value), .little),
        8 => std.mem.writeInt(u64, data[0..8], value, .little),
        else => unreachable,
    }
}

fn validateTransportSlots(
    transports: *const [board.max_virtio_devices]mmio.Transport,
    disk_backends: [4]?virtio_blk.Backend,
) !void {
    try board.validateDeviceInventory();
    const fixed = [_]u32{ virtio_console.device_id, 0, 0, 0, 0, virtio_net.device_id, virtio_vsock.device_id, virtio_rng.device_id };
    for (transports, 0..) |transport, index| {
        const expected = if (index >= 1 and index <= 4 and disk_backends[index - 1] != null)
            virtio_blk.device_id
        else
            fixed[index];
        if (transport.dev.device_id != expected) return error.InvalidDeviceInventory;
    }
}

fn requestWake(run_bytes: []u8) void {
    kvm.requestImmediateExit(run_bytes) catch unreachable;
}

fn consumeWake(run_bytes: []u8) bool {
    return kvm.consumeImmediateExit(run_bytes) catch unreachable;
}

fn sleepNotRunnableAp() void {
    // APs can remain in KVM's UNINITIALIZED state for the whole BSP boot.
    // Bound stop latency to one millisecond without hot-spinning on EAGAIN.
    var delay = std.c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
    _ = std.c.nanosleep(&delay, null);
}

fn monotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn readRunInt(comptime T: type, run_bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, run_bytes[offset..][0..@sizeOf(T)], .native);
}

test "MMIO router accepts only complete aligned board windows" {
    const first = try decodeMmioTarget(board.virtio_base + 1, 1);
    try std.testing.expectEqual(@as(usize, 0), first.virtio.index);
    try std.testing.expectEqual(@as(u64, 1), first.virtio.offset);
    const config_word = try decodeMmioTarget(board.virtio_slots[5].base + 0x102, 2);
    try std.testing.expectEqual(@as(usize, 5), config_word.virtio.index);
    try std.testing.expectEqual(@as(u64, 0x102), config_word.virtio.offset);
    const last = try decodeMmioTarget(board.virtio_slots[7].base + 0x1fc, 4);
    try std.testing.expectEqual(@as(usize, 7), last.virtio.index);
    try std.testing.expectEqual(@as(u64, 0x1fc), last.virtio.offset);
    try std.testing.expectEqual(@as(u64, 0x18), (try decodeMmioTarget(board.generation_base + 0x18, 8)).generation);
    try std.testing.expectError(error.MalformedMmioExit, decodeMmioTarget(board.virtio_base + 1, 2));
    try std.testing.expectError(error.MalformedMmioExit, decodeMmioTarget(board.virtio_base + 0xf8, 8));
    try std.testing.expectError(error.MalformedMmioExit, decodeMmioTarget(board.virtio_slots[6].base + 0x100, 8));
    try std.testing.expectError(error.MalformedMmioExit, decodeMmioTarget(board.virtio_slots[0].base + 0x1ff, 2));
    try std.testing.expectError(error.MalformedMmioExit, decodeMmioTarget(board.virtio_slots[7].base + 0x1fc, 8));
    try std.testing.expectError(error.MalformedMmioExit, decodeMmioTarget(board.generation_base + board.generation_size - 4, 8));
    try std.testing.expectError(error.UnhandledMmio, decodeMmioTarget(board.generation_base + board.generation_size, 4));
}

test "MMIO exit decoder rejects truncated and non-boolean envelopes" {
    var run_bytes: [kvm.RunLayout.mmio_end]u8 = @splat(0);
    std.mem.writeInt(u64, run_bytes[kvm.RunLayout.mmio_phys_addr..][0..8], board.virtio_base, .native);
    std.mem.writeInt(u32, run_bytes[kvm.RunLayout.mmio_len..][0..4], 4, .native);
    run_bytes[kvm.RunLayout.mmio_is_write] = 1;
    const exit = try decodeMmioExit(&run_bytes);
    try std.testing.expect(exit.is_write);
    try std.testing.expectEqual(@as(u32, 4), exit.len);

    run_bytes[kvm.RunLayout.mmio_is_write] = 2;
    try std.testing.expectError(error.MalformedMmioExit, decodeMmioExit(&run_bytes));
    try std.testing.expectError(error.MalformedMmioExit, decodeMmioExit(run_bytes[0 .. run_bytes.len - 1]));
}

fn fuzzMmioExit(_: void, smith: *std.testing.Smith) !void {
    var run_bytes: [128]u8 = undefined;
    const run_len = smith.slice(&run_bytes);
    const exit = decodeMmioExit(run_bytes[0..run_len]) catch return;
    try std.testing.expect(exit.len == 1 or exit.len == 2 or exit.len == 4 or exit.len == 8);
    try std.testing.expect(exit.data.len == 8);
    switch (exit.target) {
        .virtio => |access| {
            try std.testing.expect(exit.len != 8);
            try std.testing.expect(access.index < board.max_virtio_devices);
            try std.testing.expect(access.offset % exit.len == 0);
            try std.testing.expect(access.offset + exit.len <= board.virtio_window_size);
        },
        .generation => |offset| {
            try std.testing.expect(offset % exit.len == 0);
            try std.testing.expect(offset + exit.len <= board.generation_size);
        },
    }
}

test "fuzz x86 KVM MMIO exit router" {
    try std.testing.fuzz({}, fuzzMmioExit, .{});
}

test "MMIO data helpers zero extend reads and truncate writes" {
    const source = [_]u8{ 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11 };
    try std.testing.expectEqual(@as(u64, 0x88), readMmioValue(&source, 1));
    try std.testing.expectEqual(@as(u64, 0x7788), readMmioValue(&source, 2));
    try std.testing.expectEqual(@as(u64, 0x5566_7788), readMmioValue(&source, 4));
    try std.testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), readMmioValue(&source, 8));

    var target: [8]u8 = @splat(0xa5);
    writeMmioValue(&target, 2, 0x1122_3344_5566_7788);
    try std.testing.expectEqualSlices(u8, &.{ 0x88, 0x77 }, target[0..2]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 6), target[2..]);
}

test "wake state requests and consumes immediate exit once" {
    var run_bytes: [kvm.RunLayout.mmio_end]u8 = @splat(0);
    try std.testing.expect(!consumeWake(&run_bytes));
    requestWake(&run_bytes);
    try std.testing.expect(consumeWake(&run_bytes));
    try std.testing.expect(!consumeWake(&run_bytes));
}

test "post-run dispatch retries an uninitialized AP without losing real exits" {
    try std.testing.expectEqual(KvmPostRunAction.dispatch_exit, kvmPostRunAction(.completed));
    try std.testing.expectEqual(KvmPostRunAction.handle_async_wake, kvmPostRunAction(.interrupted));
    try std.testing.expectEqual(KvmPostRunAction.retry_not_runnable, kvmPostRunAction(.not_runnable));
}

const TeardownProbe = struct {
    joined: *usize,
    released: *usize,
    entry_count: usize,

    fn joinThread(self: *TeardownProbe) void {
        self.joined.* += 1;
    }

    fn releaseResources(self: *TeardownProbe) void {
        std.debug.assert(self.joined.* == self.entry_count);
        self.released.* += 1;
    }
};

test "vCPU teardown joins the collection before releasing any run mapping" {
    const entry_count = 3;
    var joined: usize = 0;
    var released: usize = 0;
    var entries: [entry_count]TeardownProbe = @splat(.{
        .joined = &joined,
        .released = &released,
        .entry_count = entry_count,
    });

    teardownThreadResources(entries[0..]);

    try std.testing.expectEqual(entry_count, joined);
    try std.testing.expectEqual(entry_count, released);
}

test "transport IRQ transitions preserve level semantics" {
    try std.testing.expectEqual(TransportIrqAction.none, transportIrqAction(0, 0, false));
    try std.testing.expectEqual(TransportIrqAction.none, transportIrqAction(1, 1, false));
    try std.testing.expectEqual(TransportIrqAction.raise, transportIrqAction(0, 1, true));
    try std.testing.expectEqual(TransportIrqAction.raise, transportIrqAction(1, 1, true));
    try std.testing.expectEqual(TransportIrqAction.lower, transportIrqAction(1, 0, false));
    try std.testing.expectEqual(TransportIrqAction.lower, transportIrqAction(1, 0, true));
}

fn testTerminal(vcpu_index: u8) lifecycle.Terminal {
    return .{ .vcpu_index = vcpu_index, .cause = .{ .pio_reset = .{
        .exit_reason = kvm.KVM_EXIT_IO,
        .width = 1,
        .port = 0x64,
        .count = 1,
        .value = 0xfe,
    } } };
}

test "terminal reservation blocks unclaimed finish and publication before completion" {
    var state = RunState{};
    try std.testing.expect(state.reserveTerminal(testTerminal(0)));
    try std.testing.expect(!state.stopped());
    try std.testing.expect(state.publishedResult() == null);
    try std.testing.expect(!state.finishError(error.UnclaimedError));
    try std.testing.expect(!state.publishReserved(0));
    try std.testing.expect(!state.stopped());
    try std.testing.expect(state.publishedResult() == null);

    try std.testing.expect(state.markTerminalCompleted(0));
    try std.testing.expect(!state.stopped());
    try std.testing.expect(state.publishedResult() == null);
    try std.testing.expect(state.publishReserved(0));
    try std.testing.expect(state.stopped());
    switch (state.publishedResult().?) {
        .cause => |cause| switch (cause) {
            .terminal => |terminal| try std.testing.expectEqual(lifecycle.Outcome.guest_reset, terminal.cause.outcome()),
            .probe_complete => return error.TestUnexpectedResult,
        },
        .err => return error.TestUnexpectedResult,
    }
}

test "terminal reservation owner can publish a completion error" {
    var state = RunState{};
    try std.testing.expect(state.reserveTerminal(testTerminal(0)));
    try std.testing.expect(!state.failReserved(1, error.WrongOwner));
    try std.testing.expect(state.failReserved(0, error.TerminalCompletionFailed));
    try std.testing.expect(state.stopped());
    switch (state.publishedResult().?) {
        .cause => return error.TestUnexpectedResult,
        .err => |err| try std.testing.expectEqual(error.TerminalCompletionFailed, err),
    }
}

test "probe completion uses the same reservation and publication barrier" {
    var state = RunState{};
    try std.testing.expect(state.reserveProbeComplete(0));
    try std.testing.expect(!state.stopped());
    try std.testing.expect(state.markTerminalCompleted(0));
    try std.testing.expect(state.publishReserved(0));
    try std.testing.expect(state.stopped());
    switch (state.publishedResult().?) {
        .cause => |cause| switch (cause) {
            .probe_complete => {},
            .terminal => return error.TestUnexpectedResult,
        },
        .err => return error.TestUnexpectedResult,
    }
}

test "probe watchdog publishes a typed timeout" {
    var state = RunState{};
    var vcpus: [0]Vcpu = .{};
    var wake_set = WakeSet{ .vcpus = vcpus[0..] };
    var context = ProbeWatchdogContext{
        .state = &state,
        .wake_set = &wake_set,
        .timeout_ms = 0,
    };
    probeWatchdogMain(&context);
    try std.testing.expect(state.stopped());
    switch (state.publishedResult().?) {
        .cause => return error.TestUnexpectedResult,
        .err => |err| try std.testing.expectEqual(error.ExecProbeTimeout, err),
    }
}

test "fresh runner routes incompatible hosts through the canonical profile predicate" {
    var capabilities: [cpu_profile.required_capabilities.len]cpu_profile.CapabilityFact = undefined;
    for (cpu_profile.required_capabilities, &capabilities) |required, *fact| fact.* = .{
        .id = required.id,
        .value = @max(required.minimum, required.required_bits),
    };
    var msrs: [cpu_profile.candidate_msrs.len]u32 = undefined;
    for (cpu_profile.candidate_msrs, &msrs) |required, *index| index.* = required.index;
    const supported = try cpu_profile.candidateCpuid(1, 0);
    var bad_vendor = cpu_profile.vendor_id.*;
    bad_vendor[0] = 'A';
    try std.testing.expectError(error.IncompatibleCpuProfile, requireCompatibleProfile(.{
        .api_version = kvm.KVM_API_VERSION,
        .vendor = bad_vendor,
        .max_vcpus = topology.max_vcpus,
        .capabilities = &capabilities,
        .msr_indices = &msrs,
        .supported_cpuid = supported.entries[0..supported.nent],
        .xsave_bytes = cpu_profile.kvm_xsave_min_bytes,
        .tsc_khz = cpu_profile.guest_tsc_khz,
        .has_tsc_offset = true,
    }, 1));
}

test "first terminal reservation wins" {
    var state = RunState{};
    try std.testing.expect(state.reserveTerminal(testTerminal(0)));
    try std.testing.expect(!state.reserveTerminal(testTerminal(1)));
    try std.testing.expect(!state.markTerminalCompleted(1));
    try std.testing.expect(state.markTerminalCompleted(0));
    try std.testing.expect(state.publishReserved(0));
    switch (state.publishedResult().?) {
        .cause => |cause| switch (cause) {
            .terminal => |terminal| try std.testing.expectEqual(@as(u8, 0), terminal.vcpu_index),
            .probe_complete => return error.TestUnexpectedResult,
        },
        .err => return error.TestUnexpectedResult,
    }
}

const ReservationRace = struct {
    fn run(state: *RunState, wins: *std.atomic.Value(u32), owner: u8) void {
        if (state.reserveTerminal(testTerminal(owner))) _ = wins.fetchAdd(1, .acq_rel);
    }
};

test "concurrent terminal reservations admit one owner" {
    var state = RunState{};
    var wins = std.atomic.Value(u32).init(0);
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, ReservationRace.run, .{ &state, &wins, @as(u8, @intCast(index)) });
    }
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(u32, 1), wins.load(.acquire));
    try std.testing.expect(!state.stopped());
    try std.testing.expect(state.publishedResult() == null);
}

fn testConsoleSink(_: []const u8) void {}

test "fixed slots accept real disks or empty device-id-zero transports" {
    var con = virtio_console.Console{ .sink = testConsoleSink };
    var disks: [4][512]u8 = @splat(@splat(0));
    var block_devs = [_]virtio_blk.Blk{
        .init(.{ .memory = &disks[0] }),
        .initImmutableSource(.{ .memory = &disks[1] }),
        .initImmutableSource(.{ .memory = &disks[2] }),
        .initImmutableSource(.{ .memory = &disks[3] }),
    };
    var net_dev = virtio_net.Net.init(.{});
    var vsock_dev = virtio_vsock.Vsock.init(.{});
    var rng_dev = virtio_rng.Rng{};
    const ordinary_transports = [_]mmio.Transport{
        .init(con.device()),
        .init(block_devs[0].device()),
        .init(block_devs[1].device()),
        .init(block_devs[2].device()),
        .init(block_devs[3].device()),
        .init(net_dev.device()),
        .init(vsock_dev.device()),
        .init(rng_dev.device()),
    };
    const ordinary_backends = [_]?virtio_blk.Backend{
        .{ .memory = &disks[0] },
        .{ .memory = &disks[1] },
        .{ .memory = &disks[2] },
        .{ .memory = &disks[3] },
    };
    try validateTransportSlots(&ordinary_transports, ordinary_backends);

    var empty: [4]EmptyDevice = @splat(.{});
    const empty_transports = [_]mmio.Transport{
        .init(con.device()),
        .init(empty[0].device()),
        .init(empty[1].device()),
        .init(empty[2].device()),
        .init(empty[3].device()),
        .init(net_dev.device()),
        .init(vsock_dev.device()),
        .init(rng_dev.device()),
    };
    try validateTransportSlots(&empty_transports, @splat(null));
    for (empty_transports[1..5]) |transport| {
        try std.testing.expectEqual(@as(u32, 0), transport.dev.device_id);
        try std.testing.expectEqual(@as(u8, 0), transport.dev.queue_count);
    }
}
