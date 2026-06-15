//! HVF virtual machine: board assembly and vCPU run loop.
//!
//! Single-vCPU bring-up scope: boots the pinned kernel with the SporeVM
//! board (GICv3 via hv_gic, virtio-mmio console/blk/net/vsock/rng, generation
//! MMIO), handles MMIO data aborts, PSCI over HVC, vtimer exits, WFI, and HVF
//! snapshot/resume.
//! Multi-vCPU and the rest of the device set land in later slices.

const std = @import("std");
const chunk = @import("../chunk.zig");
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
const vsock = @import("../virtio/vsock.zig");
const platform_contract = @import("../platform.zig");
const spore = @import("../spore.zig");
const snapshot = @import("snapshot.zig");

pub const Config = struct {
    kernel: []const u8,
    ram_size: u64 = 512 * 1024 * 1024,
    cmdline: []const u8 = "console=hvc0",
    initrd: ?[]const u8 = null,
    console_sink: *const fn ([]const u8) void,
    /// Read-write host fd backing /dev/vda, if any.
    disk_fd: ?std.c.fd_t = null,
    /// Poll fd 0 (set non-blocking by the caller) for console input on
    /// guest idle exits.
    poll_stdin: bool = false,
    /// Resume from a spore directory instead of booting the kernel.
    resume_dir: ?[]const u8 = null,
    /// Trusted same-host RAM backing fd supplied by the caller or future
    /// monitor. The fd must refer to the manifest's optional RAM backing and
    /// is mapped MAP_PRIVATE; imported or untrusted spores must leave this
    /// null so RAM is materialized through verified chunks.
    ram_backing_fd: ?std.c.fd_t = null,
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
    /// Opt-in HVF write-protect dirty tracking for Slice 7 measurement. When
    /// enabled, guest write faults identify dirty chunks and snapshots only
    /// need a final dirty-tail flush instead of a full RAM scan.
    dirty_tracking: DirtyTrackingOptions = .{},
    /// Optional minimal host-initiated vsock stream used by benchmark harnesses.
    exec_probe: ?*vsock.HostStream = null,
    exec_probe_timeout_ms: u64 = 30_000,
};

pub const ExitCause = enum { guest_off, guest_reset, snapshotted, probe_complete };

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

const ec_wfx: u6 = 0x01;
const ec_sysreg: u6 = 0x18;

pub fn run(allocator: std.mem.Allocator, config: Config) !ExitCause {
    try hvf.check(hvf.hv_vm_create(null), "hv_vm_create");
    defer _ = hvf.hv_vm_destroy();

    var resume_parsed: ?std.json.Parsed(spore.Manifest) = null;
    defer if (resume_parsed) |*parsed| parsed.deinit();
    var lazy_pager: ?lazy_ram.Pager = null;
    var dirty_tracker: ?DirtyTracker = null;
    var restore_stats: ?RestoreStats = null;
    if (config.dirty_tracking.enabled and (config.resume_dir != null or config.snapshot_after_ms == null or config.snapshot_dir == null)) {
        return error.BadManifest;
    }
    if (config.ram_backing_fd != null and config.ram_restore_mode == .lazy_chunks) return error.BadManifest;
    if (config.resume_dir) |spore_dir| {
        const manifest_start = monotonicMs();
        resume_parsed = try spore.loadManifest(allocator, spore_dir);
        restore_stats = .{
            .start_ms = manifest_start,
            .manifest_ms = monotonicMs() - manifest_start,
        };
    }

    // GIC layout from runtime parameters; created before any vCPU.
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
    const dist_base: u64 = if (resume_parsed) |parsed| parsed.value.platform.gic_dist_base else default_dist_base;
    const redist_base: u64 = if (resume_parsed) |parsed| parsed.value.platform.gic_redist_base else default_redist_base;
    if (dist_base % dist_align != 0 or redist_base % redist_align != 0) return error.PlatformMismatch;

    const gic_config = hvf.hv_gic_config_create();
    defer hvf.os_release(gic_config);
    try hvf.check(hvf.hv_gic_config_set_distributor_base(gic_config, dist_base), "gic set dist base");
    try hvf.check(hvf.hv_gic_config_set_redistributor_base(gic_config, redist_base), "gic set redist base");
    try hvf.check(hvf.hv_gic_create(gic_config), "hv_gic_create");

    // Guest RAM. Eager and trusted-file resumes map the whole range up front;
    // lazy chunk resumes leave it unmapped in HVF and materialize chunks from
    // instruction/data-abort exits in the run loop.
    const map_ram_start = monotonicMs();
    const ram_mapping = try mapRam(config, if (resume_parsed) |parsed| parsed.value else null);
    if (restore_stats) |*stats| stats.map_ram_ms = monotonicMs() - map_ram_start;
    defer ram_mapping.deinit();
    defer if (lazy_pager) |*pager| pager.deinit();
    const ram_bytes = ram_mapping.bytes;
    var ram_mapped_at_start = false;
    if (shouldMapRamAtStart(config, ram_mapping)) {
        try hvf.check(
            hvf.hv_vm_map(ram_bytes.ptr, board.ram_base, ram_bytes.len, hvf.MemoryFlags.rwx),
            "hv_vm_map ram",
        );
        ram_mapped_at_start = true;
    }
    defer {
        if (ram_mapped_at_start) _ = hvf.hv_vm_unmap(board.ram_base, ram_bytes.len);
    }
    defer if (dirty_tracker) |*tracker| tracker.deinit();
    var ram = guestmem.GuestRam{ .bytes = ram_bytes, .base = board.ram_base };

    // Devices: console is virtio-mmio slot 0, disk (if any) follows, then net, vsock, rng.
    // The generation device is a separate fixed MMIO window after the reserved virtio range.
    var con = console.Console{ .sink = config.console_sink };
    var blk_dev: blk.Blk = undefined;
    var net_dev = net.Net.init(.{});
    var rng_dev = rng.Rng{};
    var vsock_dev = vsock.Vsock.init(.{});
    var gen_dev = generation.Device{};
    var transports_buf: [5]mmio.Transport = undefined;
    transports_buf[0] = mmio.Transport.init(con.device());
    var transport_count: usize = 1;
    if (config.disk_fd) |fd| {
        blk_dev = blk.Blk.init(.{ .file = fd });
        transports_buf[1] = mmio.Transport.init(blk_dev.device());
        transport_count = 2;
    }
    transports_buf[transport_count] = mmio.Transport.init(net_dev.device());
    transport_count += 1;
    transports_buf[transport_count] = mmio.Transport.init(vsock_dev.device());
    transport_count += 1;
    transports_buf[transport_count] = mmio.Transport.init(rng_dev.device());
    transport_count += 1;
    const transports = transports_buf[0..transport_count];

    // vCPU. Created before the DTB because the framework assigns the
    // redistributor frame from the vCPU's MPIDR affinity.
    var vcpu: hvf.VcpuHandle = undefined;
    var exit: *hvf.VcpuExit = undefined;
    try hvf.check(hvf.hv_vcpu_create(&vcpu, &exit, null), "hv_vcpu_create");
    defer _ = hvf.hv_vcpu_destroy(vcpu);

    try hvf.check(hvf.hv_vcpu_set_sys_reg(vcpu, .mpidr_el1, 0x8000_0000), "set mpidr"); // aff 0, RES1
    var vcpu_redist_base: hvf.Ipa = 0;
    try hvf.check(hvf.hv_gic_get_redistributor_base(vcpu, &vcpu_redist_base), "gic redist base for vcpu");
    var redist_stride: usize = 0;
    try hvf.check(hvf.hv_gic_get_redistributor_size(&redist_stride), "gic redist stride");
    std.log.debug(
        "gic: dist=0x{x}+0x{x} redist(vcpu0)=0x{x}+0x{x} (region 0x{x}+0x{x})",
        .{ dist_base, dist_size, vcpu_redist_base, redist_stride, redist_base, redist_size },
    );

    if (config.resume_dir) |spore_dir| {
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
            if (restore_stats) |*stats| stats.mode = "trusted_file_backed";
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
        try gen_dev.restore(allocator, m.generation);
        try spore.refreshResumeParams(allocator, &gen_dev);
        try snapshot.applyMachine(allocator, vcpu, m.machine);
        try raiseGenerationIrqIfPending(&gen_dev);
        if (restore_stats) |*stats| stats.state_ms = monotonicMs() - state_start;
    } else {
        // Fresh boot: DTB + kernel. The DTB describes exactly one
        // redistributor frame, where the framework actually put it.
        const initrd_range = if (config.initrd) |initrd| try boot.planInitrd(ram_bytes.len, board.ram_base, config.kernel, initrd.len) else null;
        const dtb = try board.buildDtb(allocator, .{
            .ram_size = config.ram_size,
            .cpu_count = 1,
            .gic = .{
                .distributor_base = dist_base,
                .distributor_size = dist_size,
                .redistributor_base = vcpu_redist_base,
                .redistributor_size = redist_stride,
            },
            .virtio_count = @intCast(transports.len),
            .bootargs = config.cmdline,
            .initrd = if (initrd_range) |r| .{ .start = r.start, .end = r.end } else null,
        });
        defer allocator.free(dtb);
        const layout = try boot.load(ram_bytes, board.ram_base, config.kernel, config.initrd, dtb);

        try hvf.check(hvf.hv_vcpu_set_reg(vcpu, .cpsr, 0x3c5), "set cpsr"); // EL1h, DAIF masked
        try hvf.check(hvf.hv_vcpu_set_reg(vcpu, .pc, layout.entry), "set pc");
        try hvf.check(hvf.hv_vcpu_set_reg(vcpu, .x0, layout.dtb), "set x0");

        if (config.dirty_tracking.enabled) {
            dirty_tracker = try DirtyTracker.start(allocator, .{
                .dir = config.snapshot_dir.?,
                .ram = ram_bytes,
                .epoch_ms = config.dirty_tracking.epoch_ms,
            });
            if (dirty_tracker) |*tracker| {
                ram.dirty_context = tracker;
                ram.dirty_fn = DirtyTracker.markGuestWriteCallback;
                try tracker.startWorker();
            }
        }
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
    if (config.exec_probe) |probe| {
        try vsock_dev.attachHostStream(probe);
        probe.markStarted();
    }

    // Run loop.
    while (true) {
        if (config.exec_probe) |probe| {
            if (probe.state == .failed) return error.VsockProbeFailed;
            if (probe.state == .complete) return .probe_complete;
            if (probe.elapsedMs() > config.exec_probe_timeout_ms) return error.VsockProbeTimedOut;
        }
        if (config.snapshot_after_ms) |after_ms| {
            const elapsed_ms = (snapshot.hostCounter() - counter_start) * 1000 / counter_freq;
            if (elapsed_ms >= after_ms) {
                const dir = config.snapshot_dir orelse return error.HvCallFailed;
                try takeSnapshot(allocator, dir, vcpu, transports, &gen_dev, ram_bytes, .{
                    .dist_base = dist_base,
                    .redist_base = vcpu_redist_base,
                    .ram_size = config.ram_size,
                }, if (dirty_tracker) |*tracker| tracker else null);
                return .snapshotted;
            }
        }
        try hvf.check(hvf.hv_vcpu_run(vcpu), "hv_vcpu_run");
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
                        });
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
            .canceled => return error.VcpuCanceled,
            else => {
                std.log.err("unhandled exit reason {}", .{exit.reason});
                return error.UnhandledExit;
            },
        }
    }
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

fn shouldMapRamAtStart(config: Config, ram_mapping: RamMapping) bool {
    if (config.resume_dir == null) return true;
    if (ram_mapping.file_backed) return true;
    return config.ram_restore_mode != .lazy_chunks;
}

fn mapRam(config: Config, manifest: ?spore.Manifest) !RamMapping {
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

fn writeFileAll(path: [:0]const u8, data: []const u8) !void {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);
    var done: usize = 0;
    while (done < data.len) {
        const n = std.c.write(fd, data.ptr + done, data.len - done);
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
}

fn pwriteFileAll(fd: std.c.fd_t, offset: usize, data: []const u8) !void {
    var done: usize = 0;
    while (done < data.len) {
        const n = std.c.pwrite(fd, data.ptr + done, data.len - done, @intCast(offset + done));
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
}

fn ensureDir(path: [:0]const u8) !void {
    if (std.c.mkdir(path, 0o755) != 0) {
        if (std.c.access(path, 0) != 0) return error.IoFailed;
    }
}

fn pathZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(allocator, fmt, args, 0) catch error.OutOfMemory;
}

fn ratePerSec(count: u64, elapsed_ms: u64) u64 {
    if (elapsed_ms == 0) return 0;
    return count * std.time.ms_per_s / elapsed_ms;
}

const DirtyTracker = struct {
    allocator: std.mem.Allocator,
    dir: []const u8,
    ram: []const u8,
    refs: []?[]const u8,
    dirty_chunks: []bool,
    writable_chunks: []bool,
    backing_fd: std.c.fd_t,
    backing_tmp_path: [:0]const u8,
    backing_final_path: [:0]const u8,
    epoch_ms: u64,
    mutex: SpinLock = .{},
    stop: std.atomic.Value(bool) = .init(false),
    worker_thread: ?std.Thread = null,
    worker_failed: bool = false,
    tracking_start_ms: u64 = 0,
    finished: bool = false,
    stats: DirtyStats = .{},

    const Options = struct {
        dir: []const u8,
        ram: []const u8,
        epoch_ms: u64,
    };

    const DirtyStats = struct {
        seed_ms: u64 = 0,
        seed_chunks: usize = 0,
        seed_nonzero_chunks: usize = 0,
        dirty_epoch_ms: u64 = 0,
        dirty_epoch_count: u64 = 0,
        write_fault_count: u64 = 0,
        dirty_chunks_total: u64 = 0,
        host_dirty_ranges_total: u64 = 0,
        host_dirty_chunks_total: u64 = 0,
        sealed_chunks_total: u64 = 0,
        seed_protect_ms: u64 = 0,
        protect_ms: u64 = 0,
        seal_ms: u64 = 0,
        tail_flush_ms: u64 = 0,
        worker_epoch_max_ms: u64 = 0,
        worker_join_ms: u64 = 0,
        tracking_ms: u64 = 0,
        dirty_chunks_per_sec: u64 = 0,
        sealed_chunks_per_sec: u64 = 0,
    };

    fn start(allocator: std.mem.Allocator, options: Options) !DirtyTracker {
        if (options.ram.len == 0) return error.BadManifest;
        if (options.ram.len % std.heap.page_size_min != 0) return error.BadManifest;
        if (spore.chunk_size % std.heap.page_size_min != 0) return error.BadManifest;

        const chunk_count = (options.ram.len + spore.chunk_size - 1) / spore.chunk_size;
        const dir_z = try pathZ(allocator, "{s}", .{options.dir});
        const chunks_dir = try pathZ(allocator, "{s}/chunks", .{options.dir});
        try ensureDir(dir_z);
        try ensureDir(chunks_dir);

        const backing_tmp_path = try pathZ(allocator, "{s}/{s}.tmp", .{ options.dir, spore.ram_backing_path });
        const backing_final_path = try pathZ(allocator, "{s}/{s}", .{ options.dir, spore.ram_backing_path });
        const backing_fd = std.c.open(backing_tmp_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
        if (backing_fd < 0) return error.IoFailed;
        errdefer _ = std.c.close(backing_fd);
        if (std.c.ftruncate(backing_fd, @intCast(options.ram.len)) != 0) return error.IoFailed;

        var tracker = DirtyTracker{
            .allocator = allocator,
            .dir = options.dir,
            .ram = options.ram,
            .refs = try allocator.alloc(?[]const u8, chunk_count),
            .dirty_chunks = try allocator.alloc(bool, chunk_count),
            .writable_chunks = try allocator.alloc(bool, chunk_count),
            .backing_fd = backing_fd,
            .backing_tmp_path = backing_tmp_path,
            .backing_final_path = backing_final_path,
            .epoch_ms = options.epoch_ms,
        };
        @memset(tracker.refs, null);
        @memset(tracker.dirty_chunks, false);
        @memset(tracker.writable_chunks, false);

        const seed_start = monotonicMs();
        for (tracker.refs, 0..) |_, i| {
            const nonzero = try tracker.sealChunk(i, false);
            tracker.stats.seed_chunks += 1;
            if (nonzero) tracker.stats.seed_nonzero_chunks += 1;
        }
        tracker.stats.seed_ms = monotonicMs() - seed_start;
        tracker.stats.dirty_epoch_ms = options.epoch_ms;

        const protect_start = monotonicMs();
        try tracker.protectAll(hvf.MemoryFlags.rx);
        tracker.stats.seed_protect_ms = monotonicMs() - protect_start;
        tracker.tracking_start_ms = monotonicMs();

        std.log.info(
            "hvf dirty tracking started: mode=write-protect ram_mib={d} chunks={d} seed_nonzero_chunks={d} seed_ms={d} seed_protect_ms={d} epoch_ms={d}",
            .{ options.ram.len / 1024 / 1024, tracker.refs.len, tracker.stats.seed_nonzero_chunks, tracker.stats.seed_ms, tracker.stats.seed_protect_ms, options.epoch_ms },
        );
        return tracker;
    }

    fn deinit(self: *DirtyTracker) void {
        self.stopWorker();
        if (!self.finished) {
            _ = self.protectAll(hvf.MemoryFlags.rwx) catch {};
        }
        if (self.backing_fd >= 0) {
            _ = std.c.close(self.backing_fd);
            self.backing_fd = -1;
        }
        if (!self.finished) {
            _ = std.c.unlink(self.backing_tmp_path.ptr);
        }
    }

    fn startWorker(self: *DirtyTracker) !void {
        if (self.epoch_ms == 0) return;
        self.worker_thread = try std.Thread.spawn(.{}, dirtyWorker, .{self});
        std.log.info("hvf dirty tracking worker started: epoch_ms={d}", .{self.epoch_ms});
    }

    fn stopWorker(self: *DirtyTracker) void {
        if (self.worker_thread) |thread| {
            const join_start = monotonicMs();
            self.stop.store(true, .release);
            thread.join();
            self.worker_thread = null;
            self.stats.worker_join_ms += monotonicMs() - join_start;
        }
    }

    fn dirtyWorker(self: *DirtyTracker) void {
        while (!self.waitForStop()) {
            const epoch_start = monotonicMs();
            self.flushDirty(false) catch {
                self.markWorkerFailed();
                return;
            };
            const epoch_ms = monotonicMs() - epoch_start;
            self.mutex.lock();
            if (epoch_ms > self.stats.worker_epoch_max_ms) self.stats.worker_epoch_max_ms = epoch_ms;
            self.mutex.unlock();
        }
    }

    fn waitForStop(self: *DirtyTracker) bool {
        var slept_ms: u64 = 0;
        while (slept_ms < self.epoch_ms) {
            if (self.stop.load(.acquire)) return true;
            const remaining = self.epoch_ms - slept_ms;
            const slice_ms = @min(remaining, 10);
            sleepMs(slice_ms);
            slept_ms += slice_ms;
        }
        return self.stop.load(.acquire);
    }

    fn markWorkerFailed(self: *DirtyTracker) void {
        self.mutex.lock();
        self.worker_failed = true;
        self.mutex.unlock();
    }

    fn handleWriteFault(self: *DirtyTracker, syndrome: u64, ipa: u64) !bool {
        const is_write = syndrome & (1 << 6) != 0;
        if (!is_write) return false;
        if (ipa < board.ram_base) return false;
        const guest_offset = ipa - board.ram_base;
        if (guest_offset >= self.ram.len) return false;
        const chunk_index: usize = @intCast(guest_offset / spore.chunk_size);

        self.mutex.lock();
        defer self.mutex.unlock();
        self.stats.write_fault_count += 1;
        self.dirty_chunks[chunk_index] = true;
        if (!self.writable_chunks[chunk_index]) {
            const protect_start = monotonicMs();
            try self.protectChunk(chunk_index, hvf.MemoryFlags.rwx);
            self.stats.protect_ms += monotonicMs() - protect_start;
            self.writable_chunks[chunk_index] = true;
        }
        return true;
    }

    fn finish(self: *DirtyTracker) !spore.MemoryManifest {
        self.stopWorker();
        if (self.worker_failed) return error.HvfDirtyWorkerFailed;
        const tail_start = monotonicMs();
        try self.flushDirty(true);
        self.stats.tail_flush_ms = monotonicMs() - tail_start;
        self.finishRates(monotonicMs());

        try self.protectAll(hvf.MemoryFlags.rwx);
        if (std.c.fchmod(self.backing_fd, 0o444) != 0) return error.IoFailed;
        _ = std.c.close(self.backing_fd);
        self.backing_fd = -1;
        if (std.c.rename(self.backing_tmp_path.ptr, self.backing_final_path.ptr) != 0) return error.IoFailed;
        self.finished = true;

        return .{
            .chunk_size = spore.chunk_size,
            .chunks = self.refs,
            .backing = .{ .path = spore.ram_backing_path, .size = self.ram.len },
        };
    }

    fn flushDirty(self: *DirtyTracker, tail: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.hasDirtyChunks()) return;

        var dirty_chunks_this_flush: u64 = 0;
        const seal_start = monotonicMs();
        for (self.dirty_chunks, 0..) |is_dirty, i| {
            if (!is_dirty) continue;
            self.dirty_chunks[i] = false;
            dirty_chunks_this_flush += 1;
            if (self.writable_chunks[i]) {
                const protect_start = monotonicMs();
                try self.protectChunk(i, hvf.MemoryFlags.rx);
                self.stats.protect_ms += monotonicMs() - protect_start;
                self.writable_chunks[i] = false;
            }
            _ = try self.sealChunk(i, true);
        }
        self.stats.seal_ms += monotonicMs() - seal_start;
        self.stats.dirty_chunks_total += dirty_chunks_this_flush;
        if (!tail) self.stats.dirty_epoch_count += 1;
    }

    fn hasDirtyChunks(self: *const DirtyTracker) bool {
        for (self.dirty_chunks) |is_dirty| {
            if (is_dirty) return true;
        }
        return false;
    }

    fn markGuestWriteCallback(ctx: *anyopaque, gpa: u64, len: u64) void {
        const self: *DirtyTracker = @ptrCast(@alignCast(ctx));
        self.markGuestWrite(gpa, len);
    }

    fn markGuestWrite(self: *DirtyTracker, gpa: u64, len: u64) void {
        if (len == 0) return;
        if (gpa < board.ram_base) return;
        const guest_offset = gpa - board.ram_base;
        if (guest_offset >= self.ram.len) return;
        const start_offset: usize = @intCast(guest_offset);
        const remaining: u64 = @intCast(self.ram.len - start_offset);
        const capped_len: usize = @intCast(@min(len, remaining));
        if (capped_len == 0) return;

        const first_chunk = start_offset / spore.chunk_size;
        const last_byte = start_offset + capped_len - 1;
        const last_chunk = last_byte / spore.chunk_size;

        self.mutex.lock();
        defer self.mutex.unlock();
        self.stats.host_dirty_ranges_total += 1;
        var chunk_index = first_chunk;
        while (chunk_index <= last_chunk) : (chunk_index += 1) {
            if (!self.dirty_chunks[chunk_index]) {
                self.stats.host_dirty_chunks_total += 1;
            }
            self.dirty_chunks[chunk_index] = true;
        }
    }

    fn finishRates(self: *DirtyTracker, now_ms: u64) void {
        if (now_ms <= self.tracking_start_ms) return;
        const tracking_ms = now_ms - self.tracking_start_ms;
        self.stats.tracking_ms = tracking_ms;
        self.stats.dirty_chunks_per_sec = ratePerSec(self.stats.dirty_chunks_total, tracking_ms);
        self.stats.sealed_chunks_per_sec = ratePerSec(self.stats.sealed_chunks_total, tracking_ms);
    }

    fn sealChunk(self: *DirtyTracker, index: usize, count_dirty_seal: bool) !bool {
        const chunk_start = index * spore.chunk_size;
        const end = @min(chunk_start + spore.chunk_size, self.ram.len);
        const data = self.ram[chunk_start..end];

        if (std.mem.allEqual(u8, data, 0)) {
            if (self.refs[index] != null) {
                self.refs[index] = null;
                try pwriteFileAll(self.backing_fd, chunk_start, data);
                if (count_dirty_seal) self.stats.sealed_chunks_total += 1;
            }
            return false;
        }

        const id = chunk.ChunkId.fromContents(data);
        const hex = id.toHex();
        const existing = self.refs[index];
        if (existing == null or !std.mem.eql(u8, existing.?, &hex)) {
            const ref = try self.allocator.dupe(u8, &hex);
            self.refs[index] = ref;
            const chunk_path = try pathZ(self.allocator, "{s}/chunks/{s}", .{ self.dir, ref });
            if (std.c.access(chunk_path, 0) != 0) {
                try writeFileAll(chunk_path, data);
            }
        }
        try pwriteFileAll(self.backing_fd, chunk_start, data);
        if (count_dirty_seal) self.stats.sealed_chunks_total += 1;
        return true;
    }

    fn protectAll(self: *DirtyTracker, flags: hvf.MemoryFlags) !void {
        for (self.refs, 0..) |_, i| {
            try self.protectChunk(i, flags);
            self.writable_chunks[i] = flags.write;
        }
    }

    fn protectChunk(self: *DirtyTracker, index: usize, flags: hvf.MemoryFlags) !void {
        const chunk_start = index * spore.chunk_size;
        const end = @min(chunk_start + spore.chunk_size, self.ram.len);
        try hvf.check(
            hvf.hv_vm_protect(board.ram_base + chunk_start, end - chunk_start, flags),
            "hv_vm_protect dirty chunk",
        );
    }
};

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
    dirty_tracker: ?*DirtyTracker,
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
    const generation_start = monotonicMs();
    const gen_state = try gen_dev.capture(arena);
    const generation_ms = monotonicMs() - generation_start;
    const memory_start = monotonicMs();
    const memory = if (dirty_tracker) |tracker|
        try tracker.finish()
    else
        try spore.saveMemoryWithBacking(arena, dir, ram_bytes);
    const memory_ms = monotonicMs() - memory_start;
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
        .memory = memory,
    });
    const manifest_ms = monotonicMs() - manifest_start;
    const snapshot_total_ms = monotonicMs() - total_start;
    const memory_plan = try spore.validateMemoryForRam(memory, ram_bytes.len);
    if (dirty_tracker) |tracker| {
        const stats = tracker.stats;
        std.log.info(
            "hvf snapshot metrics: mode=write-protect ram_mib={d} chunks={d} nonzero_chunks={d} machine_ms={d} devices_ms={d} generation_ms={d} memory_ms={d} manifest_ms={d} snapshot_pause_ms={d} snapshot_total_ms={d} dirty_epoch_ms={d} dirty_epoch_count={d} write_fault_count={d} dirty_chunks_total={d} host_dirty_ranges_total={d} host_dirty_chunks_total={d} sealed_chunks_total={d} seed_ms={d} seed_chunks={d} seed_nonzero_chunks={d} seed_protect_ms={d} tail_flush_ms={d} seal_ms={d} protect_ms={d} worker_epoch_max_ms={d} worker_join_ms={d} tracking_ms={d} dirty_chunks_per_sec={d} sealed_chunks_per_sec={d}",
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
                stats.dirty_epoch_ms,
                stats.dirty_epoch_count,
                stats.write_fault_count,
                stats.dirty_chunks_total,
                stats.host_dirty_ranges_total,
                stats.host_dirty_chunks_total,
                stats.sealed_chunks_total,
                stats.seed_ms,
                stats.seed_chunks,
                stats.seed_nonzero_chunks,
                stats.seed_protect_ms,
                stats.tail_flush_ms,
                stats.seal_ms,
                stats.protect_ms,
                stats.worker_epoch_max_ms,
                stats.worker_join_ms,
                stats.tracking_ms,
                stats.dirty_chunks_per_sec,
                stats.sealed_chunks_per_sec,
            },
        );
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

fn raiseGenerationIrqIfPending(gen_dev: *const generation.Device) !void {
    if (gen_dev.interrupt_status & generation.irq_generation_changed != 0) {
        try hvf.check(hvf.hv_gic_set_spi(board.generationIntid(), true), "generation raise spi");
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
};

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
    const gic_region: ?struct { region: gic.Region, offset: u64 } = blk: {
        if (ipa >= gic_windows.dist_base and ipa < gic_windows.dist_base + gic_windows.dist_size)
            break :blk .{ .region = .distributor, .offset = ipa - gic_windows.dist_base };
        if (ipa >= gic_windows.redist_base and ipa < gic_windows.redist_base + gic_windows.redist_size)
            break :blk .{ .region = .redistributor, .offset = ipa - gic_windows.redist_base };
        break :blk null;
    };
    if (gic_region) |g| {
        if (is_write) {
            var value: u64 = 0;
            if (srt < 31) {
                try hvf.check(hvf.hv_vcpu_get_reg(vcpu, @enumFromInt(@as(u32, srt)), &value), "gic read xt");
            }
            gic.mmioWrite(g.region, vcpu, g.offset, value);
        } else if (srt < 31) {
            const value = gic.mmioRead(g.region, vcpu, g.offset, sas);
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
