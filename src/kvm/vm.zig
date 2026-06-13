//! KVM virtual machine: aarch64 Linux bring-up path.
//!
//! This is the first KVM slice: a single-vCPU VM using the shared SporeVM
//! board, DTB builder, virtio-mmio devices, and generation MMIO device. KVM
//! owns GICv3 and PSCI emulation; userspace handles only device MMIO exits and
//! forwards virtio/generation interrupts into the VGIC.

const std = @import("std");
const kvm = @import("kvm.zig");
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
const spore = @import("../spore.zig");
const vsock = @import("../virtio/vsock.zig");

pub const Config = struct {
    kernel: []const u8,
    ram_size: u64 = 512 * 1024 * 1024,
    cmdline: []const u8 = "console=hvc0",
    console_sink: *const fn ([]const u8) void,
    /// Read-write host fd backing /dev/vda, if any.
    disk_fd: ?std.c.fd_t = null,
    /// Resume from a spore directory instead of booting the kernel.
    resume_dir: ?[]const u8 = null,
    /// Take a spore snapshot after this many milliseconds of run time and
    /// stop. Requires snapshot_dir.
    snapshot_after_ms: ?u64 = null,
    snapshot_dir: ?[]const u8 = null,
};

pub const ExitCause = enum { guest_off, guest_reset, snapshotted };

const gic_dist_base: u64 = 0x0800_0000;
const gic_dist_size: u64 = 0x0001_0000;
const gic_redist_base: u64 = 0x0802_0000;
const gic_redist_size: u64 = 0x0002_0000;

pub fn run(allocator: std.mem.Allocator, config: Config) !ExitCause {
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

    const ram_bytes = try std.posix.mmap(
        null,
        @intCast(config.ram_size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(ram_bytes);
    const ram = guestmem.GuestRam{ .bytes = ram_bytes, .base = board.ram_base };

    var region = kvm.UserspaceMemoryRegion{
        .slot = 0,
        .flags = 0,
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
        const parsed = try spore.loadManifest(allocator, spore_dir);
        defer parsed.deinit();
        const m = parsed.value;
        const host_counter_frequency_hz = snapshot.hostCounterFreq();
        if (m.version != spore.format_version or
            !std.mem.eql(u8, m.platform.cpu_profile, board.cpu_profile) or
            m.platform.device_model_version != board.device_model_version or
            m.platform.ram_base != board.ram_base or
            m.platform.ram_size != config.ram_size or
            m.platform.gic_dist_base != gic_dist_base or
            m.platform.gic_redist_base != gic_redist_base or
            m.devices.len != transports.len)
        {
            return error.PlatformMismatch;
        }
        if (m.platform.counter_frequency_hz != host_counter_frequency_hz) {
            std.log.err(
                "counter frequency mismatch: spore={d}Hz host={d}Hz; cross-frequency architected timer restore unsupported",
                .{ m.platform.counter_frequency_hz, host_counter_frequency_hz },
            );
            return error.PlatformMismatch;
        }
        try spore.loadMemory(allocator, spore_dir, m.memory, ram_bytes);
        try applyTransports(transports, m.devices);
        try gen_dev.restore(allocator, m.generation);
        try snapshot.applyMachine(allocator, vm_fd, @intCast(gic_dev.fd), vcpu_fd, m.machine);
    } else {
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
        });
        defer allocator.free(dtb);
        const layout = try boot.load(ram_bytes, board.ram_base, config.kernel, dtb);

        try kvm.setOneRegU64(vcpu_fd, kvm.coreReg(kvm.KVM_REG_ARM_CORE_PSTATE), 0x3c5); // EL1h, DAIF masked.
        try kvm.setOneRegU64(vcpu_fd, kvm.coreReg(kvm.KVM_REG_ARM_CORE_PC), layout.entry);
        try kvm.setOneRegU64(vcpu_fd, kvm.gprReg(0), layout.dtb);
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
    var pending_kvm_completion = false;
    while (true) {
        if (config.snapshot_after_ms) |after_ms| {
            const elapsed_ms = (try monotonicMs()) - start_ms;
            if (elapsed_ms >= after_ms) {
                if (pending_kvm_completion) {
                    try kvm.completePendingExit(vcpu_fd, run_bytes);
                    pending_kvm_completion = false;
                }
                const dir = config.snapshot_dir orelse return error.KvmIoctlFailed;
                try takeSnapshot(allocator, dir, @intCast(gic_dev.fd), vcpu_fd, transports, &gen_dev, &vsock_dev, ram_bytes, config.ram_size);
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
) !void {
    if (vsock_dev.pending_len != 0) {
        std.log.err("cannot snapshot while virtio-vsock has pending packets", .{});
        return error.DeviceStatePending;
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const machine = try snapshot.captureMachine(arena, gic_fd, vcpu_fd);
    const devices = try captureTransports(arena, transports);
    const gen_state = try gen_dev.capture(arena);
    const memory = try spore.saveMemory(arena, dir, ram_bytes);
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
