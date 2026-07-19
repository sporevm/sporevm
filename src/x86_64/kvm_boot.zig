//! CLI adapter for the fresh-only x86-64 KVM virtual machine.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const boot_harness = @import("../boot_harness.zig");
const fd_util = @import("../fd.zig");
const board = @import("board.zig");
const vm = @import("vm.zig");

const max_boot_file = 256 * 1024 * 1024;
const probe_disk_size = 1024 * 1024;

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

    var kernel_digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(kernel, &kernel_digest, .{});
    const kernel_hex = std.fmt.bytesToHex(kernel_digest, .lower);
    if (initrd) |bytes| {
        var initrd_digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(bytes, &initrd_digest, .{});
        const initrd_hex = std.fmt.bytesToHex(initrd_digest, .lower);
        std.debug.print("sporevm kvm-boot: artifacts kernel_sha256={s} initrd_sha256={s}\n", .{ &kernel_hex, &initrd_hex });
    } else {
        std.debug.print("sporevm kvm-boot: artifacts kernel_sha256={s} initrd=absent\n", .{&kernel_hex});
    }

    std.debug.print("sporevm kvm-boot: arch=x86_64 kernel={s} mem={d}MiB vcpus={d} cmdline=\"{s}\"\n", .{
        options.kernel_path,
        options.mem_mib,
        vm.default_vcpu_count,
        cmdline,
    });
    var disk_memory: [4][]u8 = undefined;
    for (&disk_memory) |*bytes| {
        bytes.* = try arena.alloc(u8, probe_disk_size);
        @memset(bytes.*, 0);
    }
    const result = try vm.run(arena, .{
        .kernel = kernel,
        .initrd = initrd,
        .cmdline = cmdline,
        .ram_size = ram_size,
        .console_sink = consoleSink,
        .root_disk = .{ .memory = disk_memory[0] },
        .context_disk = .{ .memory = disk_memory[1] },
        .build_disk = .{ .memory = disk_memory[2] },
        .cache_disk = .{ .memory = disk_memory[3] },
    });
    switch (result) {
        .terminal => |terminal| {
            var evidence_buffer: [512]u8 = undefined;
            std.debug.print("\nsporevm kvm-boot: {s}\n", .{try vm.formatTerminalEvidence(&evidence_buffer, terminal)});
        },
        .probe_complete => return error.UnexpectedProbeCompletion,
    }
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
