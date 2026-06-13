//! KVM boot harness: boot a kernel under Linux KVM on aarch64.
//!
//! Bring-up tool, not the product CLI. Usage:
//!   zig build kvm-boot
//!   ./zig-out/bin/kvm-boot <kernel-Image> [--cmdline "..."] [--mem-mib N] [--disk rootfs.ext4]

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
        std.debug.print("usage: kvm-boot <kernel-Image> [--cmdline \"...\"] [--mem-mib N] [--disk rootfs.ext4]\n", .{});
        std.process.exit(2);
    }

    var cmdline: ?[]const u8 = null;
    var mem_mib: u64 = 512;
    var disk_path: ?[]const u8 = null;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--cmdline") and i + 1 < args.len) {
            i += 1;
            cmdline = args[i];
        } else if (std.mem.eql(u8, args[i], "--mem-mib") and i + 1 < args.len) {
            i += 1;
            mem_mib = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--disk") and i + 1 < args.len) {
            i += 1;
            disk_path = args[i];
        } else {
            std.debug.print("unknown argument: {s}\n", .{args[i]});
            std.process.exit(2);
        }
    }

    const kernel = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], arena, .limited(256 * 1024 * 1024));

    var disk_fd: ?std.c.fd_t = null;
    if (disk_path) |path| {
        const pathz = try arena.dupeZ(u8, path);
        const fd = std.c.open(pathz, .{ .ACCMODE = .RDWR }, @as(c_uint, 0));
        if (fd < 0) {
            std.debug.print("cannot open disk: {s}\n", .{path});
            std.process.exit(1);
        }
        disk_fd = fd;
    }

    const effective_cmdline = cmdline orelse if (disk_fd != null)
        "console=hvc0 root=/dev/vda rw init=/bin/sh"
    else
        "console=hvc0 loglevel=8";

    std.debug.print("sporevm kvm-boot: kernel={s} mem={d}MiB cmdline=\"{s}\"\n", .{ args[1], mem_mib, effective_cmdline });
    const cause = try sporevm.kvm.vm.run(arena, .{
        .kernel = kernel,
        .ram_size = mem_mib * 1024 * 1024,
        .cmdline = effective_cmdline,
        .console_sink = consoleSink,
        .disk_fd = disk_fd,
    });
    std.debug.print("\nsporevm kvm-boot: guest requested {s}\n", .{@tagName(cause)});
}
