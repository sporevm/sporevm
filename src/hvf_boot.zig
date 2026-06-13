//! HVF boot harness: boot a kernel under Hypervisor.framework.
//!
//! Bring-up tool, not the product CLI. Usage:
//!   zig build hvf-boot
//!   ./zig-out/bin/hvf-boot <kernel-Image> [--cmdline "..."] [--mem-mib N]

const std = @import("std");
const sporevm = @import("sporevm");

fn consoleSink(bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(1, remaining.ptr, remaining.len);
        if (n <= 0) return;
        remaining = remaining[@intCast(n)..];
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        std.debug.print("usage: hvf-boot <kernel-Image> [--cmdline \"...\"] [--mem-mib N]\n", .{});
        std.process.exit(2);
    }

    var cmdline: []const u8 = "console=hvc0 earlycon loglevel=8";
    var mem_mib: u64 = 512;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--cmdline") and i + 1 < args.len) {
            i += 1;
            cmdline = args[i];
        } else if (std.mem.eql(u8, args[i], "--mem-mib") and i + 1 < args.len) {
            i += 1;
            mem_mib = try std.fmt.parseInt(u64, args[i], 10);
        } else {
            std.debug.print("unknown argument: {s}\n", .{args[i]});
            std.process.exit(2);
        }
    }

    const kernel = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], arena, .limited(256 * 1024 * 1024));

    std.debug.print("sporevm hvf-boot: kernel={s} mem={d}MiB cmdline=\"{s}\"\n", .{ args[1], mem_mib, cmdline });

    const cause = try sporevm.hvf.vm.run(arena, .{
        .kernel = kernel,
        .ram_size = mem_mib * 1024 * 1024,
        .cmdline = cmdline,
        .console_sink = consoleSink,
    });
    std.debug.print("\nsporevm hvf-boot: guest requested {s}\n", .{@tagName(cause)});
}
