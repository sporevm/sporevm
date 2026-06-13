//! HVF virtual machine: board assembly and vCPU run loop.
//!
//! Single-vCPU bring-up scope: boots the pinned kernel with the SporeVM
//! board (GICv3 via hv_gic, virtio-mmio console/blk/rng), handles MMIO data
//! aborts, PSCI over HVC, vtimer exits, WFI, and HVF snapshot/resume.
//! Multi-vCPU and the rest of the device set land in later slices.

const std = @import("std");
const hvf = @import("hvf.zig");
const gic = @import("gic.zig");
const board = @import("../board.zig");
const boot = @import("../boot.zig");
const guestmem = @import("../guestmem.zig");
const mmio = @import("../virtio/mmio.zig");
const console = @import("../virtio/console.zig");
const blk = @import("../virtio/blk.zig");
const rng = @import("../virtio/rng.zig");
const spore = @import("../spore.zig");
const snapshot = @import("snapshot.zig");

pub const Config = struct {
    kernel: []const u8,
    ram_size: u64 = 512 * 1024 * 1024,
    cmdline: []const u8 = "console=hvc0",
    console_sink: *const fn ([]const u8) void,
    /// Read-write host fd backing /dev/vda, if any.
    disk_fd: ?std.c.fd_t = null,
    /// Poll fd 0 (set non-blocking by the caller) for console input on
    /// guest idle exits.
    poll_stdin: bool = false,
    /// Resume from a spore directory instead of booting the kernel.
    resume_dir: ?[]const u8 = null,
    /// Take a spore snapshot after this many milliseconds of run time and
    /// stop. Requires snapshot_dir.
    snapshot_after_ms: ?u64 = null,
    snapshot_dir: ?[]const u8 = null,
};

pub const ExitCause = enum { guest_off, guest_reset, snapshotted };

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

    // GIC layout from runtime parameters; created before any vCPU.
    var dist_size: usize = 0;
    var dist_align: usize = 0;
    var redist_size: usize = 0;
    var redist_align: usize = 0;
    try hvf.check(hvf.hv_gic_get_distributor_size(&dist_size), "gic dist size");
    try hvf.check(hvf.hv_gic_get_distributor_base_alignment(&dist_align), "gic dist align");
    try hvf.check(hvf.hv_gic_get_redistributor_region_size(&redist_size), "gic redist size");
    try hvf.check(hvf.hv_gic_get_redistributor_base_alignment(&redist_align), "gic redist align");

    const dist_base: u64 = std.mem.alignForward(u64, 0x0800_0000, dist_align);
    const redist_base: u64 = std.mem.alignForward(u64, dist_base + dist_size, redist_align);

    const gic_config = hvf.hv_gic_config_create();
    defer hvf.os_release(gic_config);
    try hvf.check(hvf.hv_gic_config_set_distributor_base(gic_config, dist_base), "gic set dist base");
    try hvf.check(hvf.hv_gic_config_set_redistributor_base(gic_config, redist_base), "gic set redist base");
    try hvf.check(hvf.hv_gic_create(gic_config), "hv_gic_create");

    // Guest RAM.
    const ram_bytes = try std.posix.mmap(
        null,
        @intCast(config.ram_size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(ram_bytes);
    try hvf.check(
        hvf.hv_vm_map(ram_bytes.ptr, board.ram_base, ram_bytes.len, hvf.MemoryFlags.rwx),
        "hv_vm_map ram",
    );
    const ram = guestmem.GuestRam{ .bytes = ram_bytes, .base = board.ram_base };

    // Devices: console is virtio-mmio slot 0, disk (if any) follows, rng last.
    var con = console.Console{ .sink = config.console_sink };
    var blk_dev: blk.Blk = undefined;
    var rng_dev = rng.Rng{};
    var transports_buf: [3]mmio.Transport = undefined;
    transports_buf[0] = mmio.Transport.init(con.device());
    var transport_count: usize = 1;
    if (config.disk_fd) |fd| {
        blk_dev = blk.Blk.init(.{ .file = fd });
        transports_buf[1] = mmio.Transport.init(blk_dev.device());
        transport_count = 2;
    }
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
        const parsed = try spore.loadManifest(allocator, spore_dir);
        defer parsed.deinit();
        const m = parsed.value;
        if (m.version != spore.format_version or
            m.platform.device_model_version != board.device_model_version or
            m.platform.ram_base != board.ram_base or
            m.platform.ram_size != config.ram_size or
            m.platform.gic_dist_base != dist_base or
            m.platform.gic_redist_base != vcpu_redist_base or
            m.devices.len != transports.len)
        {
            return error.PlatformMismatch;
        }
        try spore.loadMemory(allocator, spore_dir, m.memory, ram_bytes);
        try applyTransports(transports, m.devices);
        try snapshot.applyMachine(allocator, vcpu, m.machine);
    } else {
        // Fresh boot: DTB + kernel. The DTB describes exactly one
        // redistributor frame, where the framework actually put it.
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
        });
        defer allocator.free(dtb);
        const layout = try boot.load(ram_bytes, board.ram_base, config.kernel, dtb);

        try hvf.check(hvf.hv_vcpu_set_reg(vcpu, .cpsr, 0x3c5), "set cpsr"); // EL1h, DAIF masked
        try hvf.check(hvf.hv_vcpu_set_reg(vcpu, .pc, layout.entry), "set pc");
        try hvf.check(hvf.hv_vcpu_set_reg(vcpu, .x0, layout.dtb), "set x0");
    }

    const counter_start = snapshot.hostCounter();
    const counter_freq = snapshot.hostCounterFreq();

    // Run loop.
    while (true) {
        if (config.snapshot_after_ms) |after_ms| {
            const elapsed_ms = (snapshot.hostCounter() - counter_start) * 1000 / counter_freq;
            if (elapsed_ms >= after_ms) {
                const dir = config.snapshot_dir orelse return error.HvCallFailed;
                try takeSnapshot(allocator, dir, vcpu, transports, ram_bytes, .{
                    .dist_base = dist_base,
                    .redist_base = vcpu_redist_base,
                    .ram_size = config.ram_size,
                });
                return .snapshotted;
            }
        }
        try hvf.check(hvf.hv_vcpu_run(vcpu), "hv_vcpu_run");
        switch (exit.reason) {
            .exception => {
                const ec = exit.exception.exceptionClass();
                switch (ec) {
                    hvf.ec_data_abort => try handleMmio(vcpu, exit, transports, ram, .{
                        .dist_base = dist_base,
                        .dist_size = dist_size,
                        .redist_base = vcpu_redist_base,
                        .redist_size = redist_stride,
                    }),
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
                        if (config.poll_stdin) try drainStdin(&con, &transports[0], ram);
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
                if (config.poll_stdin) try drainStdin(&con, &transports[0], ram);
            },
            .canceled => return error.VcpuCanceled,
            else => {
                std.log.err("unhandled exit reason {}", .{exit.reason});
                return error.UnhandledExit;
            },
        }
    }
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
    ram_bytes: []const u8,
    platform: SnapshotPlatform,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const machine = try snapshot.captureMachine(arena, vcpu);
    const devices = try captureTransports(arena, transports);
    const memory = try spore.saveMemory(arena, dir, ram_bytes);
    try spore.saveManifest(arena, dir, .{
        .platform = .{
            .device_model_version = board.device_model_version,
            .ram_base = board.ram_base,
            .ram_size = platform.ram_size,
            .gic_dist_base = platform.dist_base,
            .gic_redist_base = platform.redist_base,
        },
        .machine = machine,
        .devices = devices,
        .memory = memory,
    });
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
    ram: guestmem.GuestRam,
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
