//! Host-only x86-64 Linux/KVM bzImage boot harness.
//!
//! This is Stage 0a.1 bring-up code, not the product runner. It exposes one
//! vCPU, one low RAM slot, and the existing virtio-mmio console only.

const std = @import("std");
const boot_harness = @import("../boot_harness.zig");
const fd_util = @import("../fd.zig");
const guestmem = @import("../guestmem.zig");
const kvm = @import("../kvm/x86_64.zig");
const mmio = @import("../virtio/mmio.zig");
const console = @import("../virtio/console.zig");
const board = @import("board.zig");
const boot = @import("boot.zig");
const cpu = @import("cpu.zig");

const max_boot_file = 256 * 1024 * 1024;
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
    const cmdline = try std.fmt.allocPrint(arena, "{s} virtio_mmio.device={d}@0x{x}:{d}", .{
        base_cmdline,
        board.virtio_window_size,
        board.virtio_console_base,
        board.virtio_console_gsi,
    });
    const ram_size = std.math.mul(u64, options.mem_mib, 1024 * 1024) catch return error.InvalidRamSize;

    std.debug.print("sporevm kvm-boot: arch=x86_64 kernel={s} mem={d}MiB cmdline=\"{s}\"\n", .{
        options.kernel_path,
        options.mem_mib,
        cmdline,
    });
    const cause = try run(.{
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

fn run(config: Config) !ExitCause {
    try board.validateLayout(config.ram_size);

    const kvm_fd = try kvm.openDevKvm();
    defer _ = std.c.close(kvm_fd);
    try kvm.checkApiVersion(kvm_fd);
    try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_USER_MEMORY, "KVM_CAP_USER_MEMORY");
    try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_IRQCHIP, "KVM_CAP_IRQCHIP");
    try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_SET_TSS_ADDR, "KVM_CAP_SET_TSS_ADDR");
    try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_SET_IDENTITY_MAP_ADDR, "KVM_CAP_SET_IDENTITY_MAP_ADDR");
    try kvm.requireExtension(kvm_fd, kvm.KVM_CAP_PIT2, "KVM_CAP_PIT2");

    const cpuid = try kvm.getSupportedCpuid(kvm_fd);
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
    const layout = try boot.load(ram, config.kernel, config.initrd, config.cmdline);
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
    const vcpu_fd: std.c.fd_t = @intCast(try kvm.ioctl(vm_fd, kvm.KVM_CREATE_VCPU, 0, "KVM_CREATE_VCPU"));
    defer _ = std.c.close(vcpu_fd);
    const run_bytes = try std.posix.mmap(
        null,
        run_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        vcpu_fd,
        0,
    );
    defer std.posix.munmap(run_bytes);

    var cpuid_copy = cpuid;
    _ = try kvm.ioctl(vcpu_fd, kvm.KVM_SET_CPUID2, @intFromPtr(&cpuid_copy), "KVM_SET_CPUID2");
    try configureProtectedMode(vcpu_fd, layout);

    var con = console.Console{ .sink = consoleSink };
    var transport = mmio.Transport.init(con.device());
    while (true) {
        if (try kvm.runVcpu(vcpu_fd) == .interrupted) continue;
        switch (kvm.exitReason(run_bytes)) {
            kvm.KVM_EXIT_IO => try handlePio(run_bytes),
            kvm.KVM_EXIT_MMIO => try handleMmio(vm_fd, run_bytes, &transport, guest_ram),
            kvm.KVM_EXIT_HLT => std.Thread.yield() catch {},
            kvm.KVM_EXIT_SYSTEM_EVENT => switch (readRunInt(u32, run_bytes, kvm.RunLayout.system_event_type)) {
                kvm.KVM_SYSTEM_EVENT_SHUTDOWN => return .system_shutdown,
                kvm.KVM_SYSTEM_EVENT_RESET => return .system_reset,
                else => return error.UnexpectedKvmExit,
            },
            // Preserve the raw exit class. Stage 0a.3 must prove whether this
            // is a triple fault, reset, or poweroff before assigning product
            // lifecycle semantics.
            kvm.KVM_EXIT_SHUTDOWN => return .shutdown,
            kvm.KVM_EXIT_FAIL_ENTRY, kvm.KVM_EXIT_INTERNAL_ERROR => return error.UnexpectedKvmExit,
            else => |reason| {
                std.log.err("unhandled x86 KVM exit reason {d}", .{reason});
                return error.UnexpectedKvmExit;
            },
        }
    }
}

fn configureProtectedMode(vcpu_fd: std.c.fd_t, layout: boot.Plan) !void {
    var sregs: kvm.Sregs = undefined;
    _ = try kvm.ioctl(vcpu_fd, kvm.KVM_GET_SREGS, @intFromPtr(&sregs), "KVM_GET_SREGS");
    var state = cpu.protectedModeState(sregs, layout.kernel_load.start, layout.zero_page.start);
    _ = try kvm.ioctl(vcpu_fd, kvm.KVM_SET_SREGS, @intFromPtr(&state.sregs), "KVM_SET_SREGS");
    _ = try kvm.ioctl(vcpu_fd, kvm.KVM_SET_REGS, @intFromPtr(&state.regs), "KVM_SET_REGS");
}

fn handlePio(run_bytes: []u8) !void {
    const exit = try kvm.decodeIoExit(run_bytes);
    std.debug.print("sporevm kvm-boot: pio direction={s} width={d} port=0x{x} count={d}\n", .{
        @tagName(exit.direction),
        exit.width,
        exit.port,
        exit.count,
    });
    if (exit.direction == .read) @memset(exit.data, 0);
}

fn handleMmio(vm_fd: std.c.fd_t, run_bytes: []u8, transport: *mmio.Transport, ram: guestmem.GuestRam) !void {
    if (run_bytes.len < kvm.RunLayout.mmio_end) return error.MalformedMmioExit;
    const phys_addr = readRunInt(u64, run_bytes, kvm.RunLayout.mmio_phys_addr);
    const len = readRunInt(u32, run_bytes, kvm.RunLayout.mmio_len);
    const is_write = run_bytes[kvm.RunLayout.mmio_is_write] != 0;
    if (len != 4) return error.MalformedMmioExit;
    if (phys_addr < board.virtio_console_base or phys_addr >= board.virtio_console_base + board.virtio_window_size) {
        return error.UnhandledMmio;
    }
    const offset = phys_addr - board.virtio_console_base;
    const data = run_bytes[kvm.RunLayout.mmio_data..][0..8];
    if (is_write) {
        const value = std.mem.readInt(u32, data[0..4], .native);
        if (transport.write(offset, value, ram)) {
            try kvm.setIrq(vm_fd, board.virtio_console_gsi, true);
        }
        if (offset == 0x064 and transport.interrupt_status == 0) {
            try kvm.setIrq(vm_fd, board.virtio_console_gsi, false);
        }
    } else {
        std.mem.writeInt(u32, data[0..4], transport.read(offset), .native);
    }
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
