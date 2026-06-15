//! KVM virtual machine: aarch64 Linux bring-up path.
//!
//! This is the first KVM slice: a single-vCPU VM using the shared SporeVM
//! board, DTB builder, virtio-mmio devices, and generation MMIO device. KVM
//! owns GICv3 and PSCI emulation; userspace handles only device MMIO exits and
//! forwards virtio/generation interrupts into the VGIC.

const std = @import("std");
const chunk = @import("../chunk.zig");
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
    /// Read-write host fd backing /dev/vda, if any.
    disk_fd: ?std.c.fd_t = null,
    /// Resume from a spore directory instead of booting the kernel.
    resume_dir: ?[]const u8 = null,
    /// Trusted same-host RAM backing fd supplied by the caller or future
    /// monitor. The fd must refer to the manifest's optional RAM backing and
    /// is mapped MAP_PRIVATE; imported or untrusted spores must leave this
    /// null so RAM is materialized through verified chunks.
    ram_backing_fd: ?std.c.fd_t = null,
    /// Chunk restore strategy for cold/imported KVM resumes. Eager remains the
    /// default; lazy is an explicit development path backed by userfaultfd.
    ram_restore_mode: RamRestoreMode = .eager_chunks,
    /// Optional fd that receives one line per lazily materialized chunk.
    lazy_ram_trace_fd: ?std.c.fd_t = null,
    /// Take a spore snapshot after this many milliseconds of run time and
    /// stop. Requires snapshot_dir.
    snapshot_after_ms: ?u64 = null,
    snapshot_dir: ?[]const u8 = null,
    /// Opt-in KVM dirty-log capture path for Slice 7 measurement. When
    /// enabled, guest writes are collected in epochs and snapshot only needs a
    /// final dirty-log tail flush instead of a full RAM scan.
    dirty_tracking: DirtyTrackingOptions = .{},
    /// Optional minimal host-initiated vsock stream used by benchmark harnesses.
    exec_probe: ?*vsock.HostStream = null,
    exec_probe_timeout_ms: u64 = 30_000,
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

pub const ExitCause = enum { guest_off, guest_reset, snapshotted, probe_complete };

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

pub fn run(allocator: std.mem.Allocator, config: Config) !ExitCause {
    var resume_parsed: ?std.json.Parsed(spore.Manifest) = null;
    defer if (resume_parsed) |*parsed| parsed.deinit();
    var lazy_pager: ?lazy_ram.Pager = null;
    var dirty_tracker: ?DirtyTracker = null;
    defer if (dirty_tracker) |*tracker| tracker.deinit();
    var restore_stats: ?RestoreStats = null;
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
    if (config.resume_dir != null or config.snapshot_after_ms != null) {
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
            if (restore_stats) |*stats| stats.mode = "trusted_file_backed";
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
        try gen_dev.restore(allocator, m.generation);
        try spore.refreshResumeParams(allocator, &gen_dev);
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
            .epoch_ms = config.dirty_tracking.epoch_ms,
        });
        if (dirty_tracker) |*tracker| {
            ram.dirty_context = tracker;
            ram.dirty_fn = DirtyTracker.markGuestWriteCallback;
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
        try vsock_dev.attachHostStream(probe);
        probe.markStarted();
    }
    var pending_kvm_completion = false;
    while (true) {
        if (config.exec_probe) |probe| {
            if (probe.state == .failed) return error.VsockProbeFailed;
            if (probe.state == .complete) {
                if (pending_kvm_completion) {
                    try kvm.completePendingExit(vcpu_fd, run_bytes);
                    pending_kvm_completion = false;
                }
                return .probe_complete;
            }
            if (probe.elapsedMs() > config.exec_probe_timeout_ms) return error.VsockProbeTimedOut;
        }
        if (dirty_tracker) |*tracker| {
            try tracker.flushEpochIfDue(try monotonicMs());
        }
        if (config.snapshot_after_ms) |after_ms| {
            const elapsed_ms = (try monotonicMs()) - start_ms;
            if (elapsed_ms >= after_ms) {
                if (pending_kvm_completion) {
                    try kvm.completePendingExit(vcpu_fd, run_bytes);
                    pending_kvm_completion = false;
                }
                const dir = config.snapshot_dir orelse return error.KvmIoctlFailed;
                try takeSnapshot(allocator, dir, @intCast(gic_dev.fd), vcpu_fd, transports, &gen_dev, &vsock_dev, ram_bytes, config.ram_size, if (dirty_tracker) |*tracker| tracker else null);
                return .snapshotted;
            }
        }

        _ = try kvm.ioctl(vcpu_fd, kvm.KVM_RUN, 0, "KVM_RUN");
        pending_kvm_completion = false;
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

const DirtyTracker = struct {
    allocator: std.mem.Allocator,
    vm_fd: std.c.fd_t,
    slot: u32,
    dir: []const u8,
    ram: []const u8,
    refs: []?[]const u8,
    dirty_chunks: []bool,
    bitmap: []usize,
    backing_fd: std.c.fd_t,
    backing_tmp_path: [:0]const u8,
    backing_final_path: [:0]const u8,
    epoch_ms: u64,
    next_epoch_ms: u64,
    finished: bool = false,
    stats: DirtyStats = .{},

    const Options = struct {
        vm_fd: std.c.fd_t,
        slot: u32,
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
        dirty_pages_total: u64 = 0,
        dirty_pages_tail: u64 = 0,
        dirty_chunks_total: u64 = 0,
        host_dirty_ranges_total: u64 = 0,
        host_dirty_chunks_total: u64 = 0,
        sealed_chunks_total: u64 = 0,
        get_dirty_log_ms: u64 = 0,
        seal_ms: u64 = 0,
        tail_flush_ms: u64 = 0,
    };

    fn start(allocator: std.mem.Allocator, options: Options) !DirtyTracker {
        if (options.ram.len == 0) return error.BadManifest;
        if (options.ram.len % std.heap.page_size_min != 0) return error.BadManifest;
        if (spore.chunk_size % std.heap.page_size_min != 0) return error.BadManifest;

        const page_count = (options.ram.len + std.heap.page_size_min - 1) / std.heap.page_size_min;
        const bitmap_word_count = (page_count + @bitSizeOf(usize) - 1) / @bitSizeOf(usize);
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
            .vm_fd = options.vm_fd,
            .slot = options.slot,
            .dir = options.dir,
            .ram = options.ram,
            .refs = try allocator.alloc(?[]const u8, chunk_count),
            .dirty_chunks = try allocator.alloc(bool, chunk_count),
            .bitmap = try allocator.alloc(usize, bitmap_word_count),
            .backing_fd = backing_fd,
            .backing_tmp_path = backing_tmp_path,
            .backing_final_path = backing_final_path,
            .epoch_ms = options.epoch_ms,
            .next_epoch_ms = (try monotonicMs()) + options.epoch_ms,
        };
        @memset(tracker.refs, null);
        @memset(tracker.dirty_chunks, false);

        const seed_start = try monotonicMs();
        for (tracker.refs, 0..) |_, i| {
            const nonzero = try tracker.sealChunk(i, false);
            tracker.stats.seed_chunks += 1;
            if (nonzero) tracker.stats.seed_nonzero_chunks += 1;
        }
        tracker.stats.seed_ms = (try monotonicMs()) - seed_start;
        tracker.stats.dirty_epoch_ms = options.epoch_ms;

        // Some kernels conservatively mark a logging memslot dirty at
        // creation. Drop that baseline after the host has loaded the kernel,
        // initrd, and DTB so subsequent epochs measure guest writes only.
        _ = try tracker.collectDirtyLog(false);
        tracker.resetDirtyStatsAfterBaseline();

        std.log.info(
            "kvm dirty tracking started: mode=dirty-log ram_mib={d} chunks={d} seed_nonzero_chunks={d} seed_ms={d} epoch_ms={d}",
            .{ options.ram.len / 1024 / 1024, tracker.refs.len, tracker.stats.seed_nonzero_chunks, tracker.stats.seed_ms, options.epoch_ms },
        );
        return tracker;
    }

    fn deinit(self: *DirtyTracker) void {
        if (self.backing_fd >= 0) {
            _ = std.c.close(self.backing_fd);
            self.backing_fd = -1;
        }
        if (!self.finished) {
            _ = std.c.unlink(self.backing_tmp_path.ptr);
        }
    }

    fn flushEpochIfDue(self: *DirtyTracker, now_ms: u64) !void {
        if (self.epoch_ms == 0) return;
        if (now_ms < self.next_epoch_ms) return;
        try self.flushDirty(false);
        while (self.next_epoch_ms <= now_ms) : (self.next_epoch_ms += self.epoch_ms) {}
    }

    fn finish(self: *DirtyTracker) !spore.MemoryManifest {
        const tail_start = try monotonicMs();
        try self.flushDirty(true);
        self.stats.tail_flush_ms = (try monotonicMs()) - tail_start;

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
        const dirty_pages = try self.collectDirtyLog(tail);
        if (dirty_pages == 0 and !self.hasDirtyChunks()) return;

        var dirty_chunks_this_flush: u64 = 0;
        const seal_start = try monotonicMs();
        for (self.dirty_chunks, 0..) |is_dirty, i| {
            if (!is_dirty) continue;
            self.dirty_chunks[i] = false;
            dirty_chunks_this_flush += 1;
            _ = try self.sealChunk(i, true);
        }
        self.stats.seal_ms += (try monotonicMs()) - seal_start;
        self.stats.dirty_chunks_total += dirty_chunks_this_flush;
    }

    fn collectDirtyLog(self: *DirtyTracker, tail: bool) !u64 {
        @memset(self.bitmap, 0);
        var log = kvm.DirtyLog{
            .slot = self.slot,
            .dirty_bitmap = @intFromPtr(self.bitmap.ptr),
        };
        const log_start = try monotonicMs();
        _ = try kvm.ioctl(self.vm_fd, kvm.KVM_GET_DIRTY_LOG, @intFromPtr(&log), "KVM_GET_DIRTY_LOG");
        self.stats.get_dirty_log_ms += (try monotonicMs()) - log_start;
        if (!tail) self.stats.dirty_epoch_count += 1;

        var dirty_pages: u64 = 0;
        const page_count = (self.ram.len + std.heap.page_size_min - 1) / std.heap.page_size_min;
        for (self.bitmap, 0..) |word, word_index| {
            var bits = word;
            while (bits != 0) {
                const bit_index: usize = @ctz(bits);
                const page_index = word_index * @bitSizeOf(usize) + bit_index;
                if (page_index >= page_count) break;
                const chunk_index = (page_index * std.heap.page_size_min) / spore.chunk_size;
                self.dirty_chunks[chunk_index] = true;
                dirty_pages += 1;
                bits &= bits - 1;
            }
        }
        self.stats.dirty_pages_total += dirty_pages;
        if (tail) self.stats.dirty_pages_tail += dirty_pages;
        return dirty_pages;
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

        self.stats.host_dirty_ranges_total += 1;
        var chunk_index = first_chunk;
        while (chunk_index <= last_chunk) : (chunk_index += 1) {
            if (!self.dirty_chunks[chunk_index]) {
                self.stats.host_dirty_chunks_total += 1;
            }
            self.dirty_chunks[chunk_index] = true;
        }
    }

    fn resetDirtyStatsAfterBaseline(self: *DirtyTracker) void {
        self.stats.dirty_epoch_count = 0;
        self.stats.dirty_pages_total = 0;
        self.stats.dirty_pages_tail = 0;
        self.stats.dirty_chunks_total = 0;
        self.stats.host_dirty_ranges_total = 0;
        self.stats.host_dirty_chunks_total = 0;
        self.stats.sealed_chunks_total = 0;
        self.stats.get_dirty_log_ms = 0;
        self.stats.seal_ms = 0;
        self.stats.tail_flush_ms = 0;
        @memset(self.dirty_chunks, false);
        @memset(self.bitmap, 0);
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
    dirty_tracker: ?*DirtyTracker,
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
    const generation_start = try monotonicMs();
    const gen_state = try gen_dev.capture(arena);
    const generation_ms = (try monotonicMs()) - generation_start;
    const memory_start = try monotonicMs();
    const memory = if (dirty_tracker) |tracker|
        try tracker.finish()
    else
        try spore.saveMemoryWithBacking(arena, dir, ram_bytes);
    const memory_ms = (try monotonicMs()) - memory_start;
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
        .memory = memory,
    });
    const manifest_ms = (try monotonicMs()) - manifest_start;
    const snapshot_total_ms = (try monotonicMs()) - total_start;

    const memory_plan = try spore.validateMemoryForRam(memory, ram_bytes.len);
    if (dirty_tracker) |tracker| {
        const stats = tracker.stats;
        std.log.info(
            "kvm snapshot metrics: mode=dirty-log ram_mib={d} chunks={d} nonzero_chunks={d} machine_ms={d} devices_ms={d} generation_ms={d} memory_ms={d} manifest_ms={d} snapshot_pause_ms={d} snapshot_total_ms={d} dirty_epoch_ms={d} dirty_epoch_count={d} dirty_pages_total={d} dirty_pages_tail={d} dirty_chunks_total={d} host_dirty_ranges_total={d} host_dirty_chunks_total={d} sealed_chunks_total={d} seed_ms={d} seed_chunks={d} seed_nonzero_chunks={d} tail_flush_ms={d} get_dirty_log_ms={d} seal_ms={d}",
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
                stats.dirty_chunks_total,
                stats.host_dirty_ranges_total,
                stats.host_dirty_chunks_total,
                stats.sealed_chunks_total,
                stats.seed_ms,
                stats.seed_chunks,
                stats.seed_nonzero_chunks,
                stats.tail_flush_ms,
                stats.get_dirty_log_ms,
                stats.seal_ms,
            },
        );
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
