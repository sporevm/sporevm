//! Host-only x86-64 Linux/KVM bzImage boot harness.
//!
//! Stage 0a.2 proves the provisional SMP board and its complete ordinary
//! device inventory. It deliberately excludes product profiles, snapshots,
//! and persistent disk paths.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const boot_harness = @import("../boot_harness.zig");
const fd_util = @import("../fd.zig");
const generation = @import("../generation.zig");
const guestmem = @import("../guestmem.zig");
const kvm = @import("../kvm/x86_64.zig");
const mmio = @import("../virtio/mmio.zig");
const virtio_blk = @import("../virtio/blk.zig");
const virtio_console = @import("../virtio/console.zig");
const virtio_mem = @import("../virtio/mem.zig");
const virtio_net = @import("../virtio/net.zig");
const virtio_rng = @import("../virtio/rng.zig");
const virtio_vsock = @import("../virtio/vsock.zig");
const board = @import("board.zig");
const boot = @import("boot.zig");
const cpu = @import("cpu.zig");

const max_boot_file = 256 * 1024 * 1024;
const stage_vcpu_count: u8 = 2;
const probe_disk_size = 1024 * 1024;
const wake_signal = posix.SIG.URG;

pub const ExitCause = enum { system_shutdown, system_reset, shutdown };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const options = boot_harness.parseArgs(args) catch usageExit();
    validateOptions(options) catch usageExit();

    const kernel = try std.Io.Dir.cwd().readFileAlloc(init.io, options.kernel_path, arena, .limited(max_boot_file));
    const initrd_file = if (options.initrd_path) |path|
        try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(max_boot_file))
    else
        null;
    const initrd = if (initrd_file) |bytes| if (bytes.len == 0) null else bytes else null;
    const base_cmdline = options.cmdline orelse if (initrd != null)
        "console=hvc0 rdinit=/init"
    else
        "console=hvc0 loglevel=8";
    var descriptors_buf: [board.max_virtio_command_line_len]u8 = undefined;
    const descriptors = try board.formatVirtioCommandLine(&descriptors_buf);
    const cmdline = try std.fmt.allocPrint(arena, "{s} {s}", .{ base_cmdline, descriptors });
    const ram_size = std.math.mul(u64, options.mem_mib, 1024 * 1024) catch return error.InvalidRamSize;

    std.debug.print("sporevm kvm-boot: arch=x86_64 kernel={s} mem={d}MiB vcpus={d} cmdline=\"{s}\"\n", .{
        options.kernel_path,
        options.mem_mib,
        stage_vcpu_count,
        cmdline,
    });
    const cause = try run(arena, .{
        .kernel = kernel,
        .initrd = initrd,
        .cmdline = cmdline,
        .ram_size = ram_size,
    });
    std.debug.print("\nsporevm kvm-boot: raw exit cause={s}\n", .{@tagName(cause)});
}

const Config = struct {
    kernel: []const u8,
    initrd: ?[]const u8,
    cmdline: []const u8,
    ram_size: u64,
};

const Vcpu = struct {
    index: u8 = 0,
    fd: std.c.fd_t = -1,
    run_bytes: []align(std.heap.page_size_min) u8 = undefined,
    run_mapped: bool = false,
    thread: ?std.Thread = null,
    thread_id: std.atomic.Value(linux.pid_t) = .init(0),

    fn deinit(self: *Vcpu) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.run_mapped) std.posix.munmap(self.run_bytes);
        self.run_mapped = false;
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.fd = -1;
    }
};

const WakeSet = struct {
    vcpus: []Vcpu,

    fn wakeAll(self: *WakeSet) void {
        for (self.vcpus) |*vcpu| {
            requestWake(vcpu.run_bytes);
            const tid = vcpu.thread_id.load(.acquire);
            if (tid != 0) _ = linux.tgkill(linux.getpid(), tid, wake_signal);
        }
    }
};

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
    first: ?RunResult = null,

    fn finish(self: *RunState, result: RunResult) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.first != null) return false;
        self.first = result;
        self.stop.store(true, .release);
        return true;
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
    ram: guestmem.GuestRam,
};

const KvmPostRunAction = enum { dispatch_exit, handle_async_wake, retry_not_runnable };

fn kvmPostRunAction(result: kvm.RunResult) KvmPostRunAction {
    return switch (result) {
        .completed => .dispatch_exit,
        .interrupted => .handle_async_wake,
        .not_runnable => .retry_not_runnable,
    };
}

fn run(allocator: std.mem.Allocator, config: Config) !ExitCause {
    try board.validateLayout(config.ram_size);

    const kvm_fd = try kvm.openDevKvm();
    defer _ = std.c.close(kvm_fd);
    try kvm.checkApiVersion(kvm_fd);
    try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_USER_MEMORY, "KVM_CAP_USER_MEMORY");
    try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_IRQCHIP, "KVM_CAP_IRQCHIP");
    try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_SET_TSS_ADDR, "KVM_CAP_SET_TSS_ADDR");
    try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_SET_IDENTITY_MAP_ADDR, "KVM_CAP_SET_IDENTITY_MAP_ADDR");
    try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_PIT2, "KVM_CAP_PIT2");
    try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_EXT_CPUID, "KVM_CAP_EXT_CPUID");
    try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_MP_STATE, "KVM_CAP_MP_STATE");
    try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_IMMEDIATE_EXIT, "KVM_CAP_IMMEDIATE_EXIT");
    if (try kvm.checkExtension(kvm_fd, kvm.KVM_CAP_NR_VCPUS) < stage_vcpu_count) {
        return error.UnsupportedVcpuCount;
    }

    const supported_cpuid = try kvm.getSupportedCpuid(kvm_fd);
    const vm_fd: std.c.fd_t = @intCast(try kvm.ioctl(kvm_fd, kvm.KVM_CREATE_VM, 0, "KVM_CREATE_VM"));
    defer _ = std.c.close(vm_fd);

    _ = try kvm.ioctl(vm_fd, kvm.KVM_SET_TSS_ADDR, board.tss_addr, "KVM_SET_TSS_ADDR");
    var identity_map_addr = board.identity_map_addr;
    _ = try kvm.ioctl(vm_fd, kvm.KVM_SET_IDENTITY_MAP_ADDR, @intFromPtr(&identity_map_addr), "KVM_SET_IDENTITY_MAP_ADDR");
    _ = try kvm.ioctl(vm_fd, kvm.KVM_CREATE_IRQCHIP, 0, "KVM_CREATE_IRQCHIP");
    var pit = kvm.PitConfig{};
    _ = try kvm.ioctl(vm_fd, kvm.KVM_CREATE_PIT2, @intFromPtr(&pit), "KVM_CREATE_PIT2");

    const ram = try std.posix.mmap(
        null,
        @intCast(config.ram_size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(ram);
    const layout = try boot.load(ram, config.kernel, config.initrd, config.cmdline, stage_vcpu_count);
    const guest_ram = guestmem.GuestRam{ .bytes = ram, .base = 0 };

    var memory_region = kvm.UserspaceMemoryRegion{
        .slot = 0,
        .flags = 0,
        .guest_phys_addr = 0,
        .memory_size = config.ram_size,
        .userspace_addr = @intFromPtr(ram.ptr),
    };
    _ = try kvm.ioctl(vm_fd, kvm.KVM_SET_USER_MEMORY_REGION, @intFromPtr(&memory_region), "KVM_SET_USER_MEMORY_REGION");

    const run_size = try kvm.ioctl(kvm_fd, kvm.KVM_GET_VCPU_MMAP_SIZE, 0, "KVM_GET_VCPU_MMAP_SIZE");
    if (run_size < kvm.RunLayout.mmio_end) return error.KvmRunMappingTooSmall;
    var vcpus: [stage_vcpu_count]Vcpu = undefined;
    var initialized: usize = 0;
    defer for (vcpus[0..initialized]) |*vcpu| vcpu.deinit();

    // Every vCPU and its distinct CPUID is ready before any worker can enter
    // KVM_RUN, so Linux never observes a partially constructed topology.
    while (initialized < stage_vcpu_count) : (initialized += 1) {
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
        var cpuid = try kvm.normalizeSupportedCpuidTopology(supported_cpuid, stage_vcpu_count, @intCast(initialized));
        _ = try kvm.ioctl(vcpu_fd, kvm.KVM_SET_CPUID2, @intFromPtr(&cpuid), "KVM_SET_CPUID2");
    }
    try configureProtectedMode(vcpus[0].fd, layout);
    for (vcpus[1..initialized]) |*vcpu| {
        if ((try kvm.getMpState(vcpu.fd)).mp_state != kvm.KVM_MP_STATE_UNINITIALIZED) {
            return error.UnexpectedApState;
        }
    }

    var console_dev = virtio_console.Console{ .sink = consoleSink };
    var disk_memory: [4][]u8 = undefined;
    for (&disk_memory) |*bytes| {
        bytes.* = try allocator.alloc(u8, probe_disk_size);
        @memset(bytes.*, 0);
    }
    var block_devs = [_]virtio_blk.Blk{
        .init(.{ .memory = disk_memory[0] }),
        .initImmutableSource(.{ .memory = disk_memory[1] }),
        .initImmutableSource(.{ .memory = disk_memory[2] }),
        .initImmutableSource(.{ .memory = disk_memory[3] }),
    };
    var net_dev = virtio_net.Net.init(.{});
    var vsock_dev = virtio_vsock.Vsock.init(.{});
    var rng_dev = virtio_rng.Rng{};
    var transports = [_]mmio.Transport{
        .init(console_dev.device()),
        .init(block_devs[0].device()),
        .init(block_devs[1].device()),
        .init(block_devs[2].device()),
        .init(block_devs[3].device()),
        .init(net_dev.device()),
        .init(vsock_dev.device()),
        .init(rng_dev.device()),
    };
    try validateTransportInventory(&transports, &board.stage0a2_ordinary_inventory);
    var gen_dev = generation.Device{};

    var signal = WakeSignal.install();
    defer signal.deinit();
    var state = RunState{};
    var wake_set = WakeSet{ .vcpus = vcpus[0..initialized] };
    var device_lock = SpinLock{};
    var contexts: [stage_vcpu_count]ThreadContext = undefined;
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
            .ram = guest_ram,
        };
        vcpus[started].thread = std.Thread.spawn(.{}, vcpuThreadMain, .{&contexts[started]}) catch |err| {
            _ = state.finish(.{ .err = err });
            wake_set.wakeAll();
            return err;
        };
    }

    // Joining is safe because the first terminal/error result wakes every
    // KVM_RUN with immediate_exit plus a process-directed SIGURG.
    for (vcpus[0..started]) |*vcpu| {
        if (vcpu.thread) |thread| thread.join();
        vcpu.thread = null;
    }
    const result = state.first orelse return error.MissingVcpuResult;
    return switch (result) {
        .cause => |cause| cause,
        .err => |err| err,
    };
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
            completePending(ctx, &pending_completion) catch |err| finishThread(ctx, .{ .err = err });
            return;
        }
        const run_result = kvm.runVcpu(ctx.vcpu.fd) catch |err| {
            finishThread(ctx, .{ .err = err });
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
                handlePio(ctx.vcpu.index, ctx.vcpu.run_bytes) catch |err| {
                    ctx.device_lock.unlock();
                    finishThread(ctx, .{ .err = err });
                    return;
                };
                ctx.device_lock.unlock();
                pending_completion = true;
            },
            kvm.KVM_EXIT_MMIO => {
                ctx.device_lock.lock();
                handleMmio(ctx.vm_fd, ctx.vcpu.run_bytes, ctx.transports, ctx.gen_dev, ctx.ram) catch |err| {
                    ctx.device_lock.unlock();
                    finishThread(ctx, .{ .err = err });
                    return;
                };
                ctx.device_lock.unlock();
                pending_completion = true;
            },
            kvm.KVM_EXIT_HLT => std.Thread.yield() catch {},
            kvm.KVM_EXIT_SYSTEM_EVENT => switch (readRunInt(u32, ctx.vcpu.run_bytes, kvm.RunLayout.system_event_type)) {
                kvm.KVM_SYSTEM_EVENT_SHUTDOWN => finishThread(ctx, .{ .cause = .system_shutdown }),
                kvm.KVM_SYSTEM_EVENT_RESET => finishThread(ctx, .{ .cause = .system_reset }),
                else => finishThread(ctx, .{ .err = error.UnexpectedKvmExit }),
            },
            // Preserve the raw exit class. Stage 0a.3 must prove whether this
            // is a triple fault, reset, or poweroff before assigning product
            // lifecycle semantics.
            kvm.KVM_EXIT_SHUTDOWN => finishThread(ctx, .{ .cause = .shutdown }),
            kvm.KVM_EXIT_FAIL_ENTRY, kvm.KVM_EXIT_INTERNAL_ERROR => finishThread(ctx, .{ .err = error.UnexpectedKvmExit }),
            else => |reason| {
                std.log.err("unhandled x86 KVM exit reason {d} on vcpu {d}", .{ reason, ctx.vcpu.index });
                finishThread(ctx, .{ .err = error.UnexpectedKvmExit });
            },
        }
        if (ctx.state.stopped()) {
            completePending(ctx, &pending_completion) catch |err| finishThread(ctx, .{ .err = err });
            return;
        }
    }
}

fn finishThread(ctx: *ThreadContext, result: RunResult) void {
    if (ctx.state.finish(result)) ctx.wake_set.wakeAll();
}

fn completePending(ctx: *ThreadContext, pending: *bool) !void {
    if (!pending.*) return;
    try kvm.completePendingExit(ctx.vcpu.fd, ctx.vcpu.run_bytes);
    pending.* = false;
}

fn handlePio(vcpu_index: u8, run_bytes: []u8) !void {
    const exit = try kvm.decodeIoExit(run_bytes);
    std.debug.print("sporevm kvm-boot: vcpu={d} pio direction={s} width={d} port=0x{x} count={d}\n", .{
        vcpu_index,
        @tagName(exit.direction),
        exit.width,
        exit.port,
        exit.count,
    });
    if (exit.direction == .read) @memset(exit.data, 0);
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
    vm_fd: std.c.fd_t,
    run_bytes: []u8,
    transports: *[board.max_virtio_devices]mmio.Transport,
    gen_dev: *generation.Device,
    ram: guestmem.GuestRam,
) !void {
    const exit = try decodeMmioExit(run_bytes);
    switch (exit.target) {
        .virtio => |access| {
            const transport = &transports[access.index];
            const slot = board.virtio_slots[access.index];
            if (exit.is_write) {
                const value: u32 = @truncate(readMmioValue(exit.data, exit.len));
                if (transport.write(access.offset, value, ram)) try kvm.setIrq(vm_fd, slot.gsi, true);
                if (access.offset == 0x064 and transport.interrupt_status == 0) try kvm.setIrq(vm_fd, slot.gsi, false);
            } else {
                writeMmioValue(exit.data, exit.len, transport.read(access.offset));
            }
        },
        .generation => |offset| {
            const size_log2: u2 = switch (exit.len) {
                1 => 0,
                2 => 1,
                4 => 2,
                8 => 3,
                else => unreachable,
            };
            if (exit.is_write) {
                const value = readMmioValue(exit.data, exit.len);
                if (gen_dev.write(offset, value, size_log2)) try kvm.setIrq(vm_fd, board.generation_gsi, false);
            } else {
                writeMmioValue(exit.data, exit.len, gen_dev.read(offset, size_log2));
            }
        },
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

fn validateTransportInventory(
    transports: *const [board.max_virtio_devices]mmio.Transport,
    inventory: *const [board.max_virtio_devices]board.ProbeAttachment,
) !void {
    try board.validateProbeInventory(inventory);
    for (transports, inventory) |transport, expected| {
        if (transport.dev.device_id != @intFromEnum(expected.device)) return error.InvalidDeviceInventory;
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

fn readRunInt(comptime T: type, run_bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, run_bytes[offset..][0..@sizeOf(T)], .native);
}

fn validateOptions(options: boot_harness.Options) !void {
    if (options.disk_path != null or
        options.snapshot_after_ms != null or
        options.spore_dir != null or
        options.resume_dir != null or
        options.lazy_ram or
        options.lazy_ram_trace_path != null or
        options.dirty_track)
    {
        return error.UnsupportedStageOption;
    }
}

fn consoleSink(bytes: []const u8) void {
    fd_util.writeAllBestEffort(1, bytes);
}

fn usageExit() noreturn {
    std.debug.print("usage: kvm-boot <kernel-bzImage> [--cmdline \"...\"] [--mem-mib 64..2048] [--initrd root.cpio]\n", .{});
    std.process.exit(2);
}

test "MMIO router accepts only complete aligned board windows" {
    const first = try decodeMmioTarget(board.virtio_base + 1, 1);
    try std.testing.expectEqual(@as(usize, 0), first.virtio.index);
    try std.testing.expectEqual(@as(u64, 1), first.virtio.offset);
    const config_word = try decodeMmioTarget(board.virtio_slots[5].base + 0x102, 2);
    try std.testing.expectEqual(@as(usize, 5), config_word.virtio.index);
    try std.testing.expectEqual(@as(u64, 0x102), config_word.virtio.offset);
    const config_double = try decodeMmioTarget(board.virtio_slots[6].base + 0x100, 8);
    try std.testing.expectEqual(@as(usize, 6), config_double.virtio.index);
    try std.testing.expectEqual(@as(u64, 0x100), config_double.virtio.offset);
    const last = try decodeMmioTarget(board.virtio_slots[7].base + 0x1fc, 4);
    try std.testing.expectEqual(@as(usize, 7), last.virtio.index);
    try std.testing.expectEqual(@as(u64, 0x1fc), last.virtio.offset);
    try std.testing.expectEqual(@as(u64, 0x18), (try decodeMmioTarget(board.generation_base + 0x18, 8)).generation);
    try std.testing.expectError(error.MalformedMmioExit, decodeMmioTarget(board.virtio_base + 1, 2));
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

test "real transports match the exact ordinary and transient-memory inventories" {
    var con = virtio_console.Console{ .sink = consoleSink };
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
    var memory_dev = virtio_mem.Mem.init(.{
        .addr = 0x1_0000_0000,
        .region_size = virtio_mem.default_block_size,
        .requested_size = 0,
    });
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
    try validateTransportInventory(&ordinary_transports, &board.stage0a2_ordinary_inventory);

    const transient_memory_transports = [_]mmio.Transport{
        .init(con.device()),
        .init(block_devs[0].device()),
        .init(block_devs[1].device()),
        .init(block_devs[2].device()),
        .init(memory_dev.device()),
        .init(net_dev.device()),
        .init(vsock_dev.device()),
        .init(rng_dev.device()),
    };
    try validateTransportInventory(&transient_memory_transports, &board.stage0a2_transient_memory_inventory);
}
