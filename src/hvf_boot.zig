//! HVF boot harness: boot a kernel under Hypervisor.framework.
//!
//! Bring-up tool, not the product CLI. Usage:
//!   zig build hvf-boot
//!   ./zig-out/bin/hvf-boot <kernel-Image> [--cmdline "..."] [--mem-mib N] [--initrd root.cpio] [--disk rootfs.ext4] [--snapshot-after-ms N --spore DIR] [--dirty-track] [--dirty-epoch-ms N] [--resume DIR] [--lazy-ram] [--lazy-ram-trace PATH]

const std = @import("std");
const spore_internal = @import("spore_internal");
const boot_harness = spore_internal.boot_harness;

fn consoleSink(bytes: []const u8) void {
    spore_internal.fd.writeAllBestEffort(1, bytes);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var harness = try boot_harness.prepare(init, arena, args, "hvf-boot");
    defer harness.deinit();
    const options = harness.options;

    const interactive = std.c.isatty(0) != 0;
    var saved_termios: ?std.c.termios = null;
    if (interactive) {
        // Raw-ish mode: no echo, no line buffering; keep ISIG so ^C kills us.
        var t: std.c.termios = undefined;
        if (std.c.tcgetattr(0, &t) == 0) {
            saved_termios = t;
            t.lflag.ICANON = false;
            t.lflag.ECHO = false;
            _ = std.c.tcsetattr(0, .NOW, &t);
        }
        // Non-blocking stdin for the poll-based console input path.
        const fl = std.c.fcntl(0, std.c.F.GETFL, @as(c_int, 0));
        _ = std.c.fcntl(0, std.c.F.SETFL, fl | @as(c_int, 1 << @bitOffsetOf(std.c.O, "NONBLOCK")));
    }
    defer if (saved_termios) |t| {
        var copy = t;
        _ = std.c.tcsetattr(0, .NOW, &copy);
    };

    std.debug.print("sporevm hvf-boot: kernel={s} mem={d}MiB cmdline=\"{s}\"\n", .{ options.kernel_path, options.mem_mib, harness.cmdline });

    const cause = try spore_internal.hvf.vm.run(arena, .{
        .kernel = harness.kernel,
        .ram_size = options.mem_mib * 1024 * 1024,
        .cmdline = harness.cmdline,
        .initrd = harness.initrd,
        .console_sink = consoleSink,
        .disk_fd = harness.disk_fd,
        .poll_stdin = interactive,
        .resume_dir = options.resume_dir,
        .ram_restore = if (options.resume_dir == null) .fresh else if (options.lazy_ram) .lazy_chunks else .eager_chunks,
        .lazy_ram_trace_fd = harness.lazy_ram_trace_fd,
        .snapshot_after_ms = options.snapshot_after_ms,
        .snapshot_dir = options.spore_dir,
        .dirty_tracking = .{ .enabled = options.dirty_track, .epoch_ms = options.dirty_epoch_ms },
    });
    std.debug.print("\nsporevm hvf-boot: guest requested {s}\n", .{@tagName(cause)});
}
