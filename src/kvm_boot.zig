//! KVM boot harness: boot a kernel under Linux KVM on aarch64.
//!
//! Bring-up tool, not the product CLI. Usage:
//!   zig build kvm-boot
//!   ./zig-out/bin/kvm-boot <kernel-Image> [--cmdline "..."] [--mem-mib N] [--initrd root.cpio] [--disk rootfs.ext4] [--snapshot-after-ms N --spore DIR] [--dirty-track] [--dirty-epoch-ms N] [--resume DIR] [--lazy-ram] [--lazy-ram-trace PATH]

const std = @import("std");
const spore_internal = @import("spore_internal");
const boot_harness = spore_internal.boot_harness;

fn consoleSink(bytes: []const u8) void {
    spore_internal.fd.writeAllBestEffort(1, bytes);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var harness = try boot_harness.prepare(init, arena, args, "kvm-boot");
    defer harness.deinit();
    const options = harness.options;

    std.debug.print("sporevm kvm-boot: kernel={s} mem={d}MiB cmdline=\"{s}\"\n", .{ options.kernel_path, options.mem_mib, harness.cmdline });
    const cause = try spore_internal.kvm.vm.run(arena, .{
        .kernel = harness.kernel,
        .ram_size = options.mem_mib * 1024 * 1024,
        .cmdline = harness.cmdline,
        .initrd = harness.initrd,
        .console_sink = consoleSink,
        .disk_fd = harness.disk_fd,
        .resume_dir = options.resume_dir,
        .ram_restore = if (options.resume_dir == null) .fresh else if (options.lazy_ram) .lazy_chunks else .eager_chunks,
        .lazy_ram_trace_fd = harness.lazy_ram_trace_fd,
        .snapshot_after_ms = options.snapshot_after_ms,
        .snapshot_dir = options.spore_dir,
        .dirty_tracking = .{ .enabled = options.dirty_track, .epoch_ms = options.dirty_epoch_ms },
    });
    std.debug.print("\nsporevm kvm-boot: guest requested {s}\n", .{@tagName(cause)});
}
