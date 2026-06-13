//! KVM boot harness: boot a kernel under Linux KVM on aarch64.
//!
//! Bring-up tool, not the product CLI. Usage:
//!   zig build kvm-boot
//!   ./zig-out/bin/kvm-boot <kernel-Image> [--cmdline "..."] [--mem-mib N] [--initrd root.cpio] [--disk rootfs.ext4] [--snapshot-after-ms N --spore DIR] [--resume DIR]

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
        std.debug.print("usage: kvm-boot <kernel-Image> [--cmdline \"...\"] [--mem-mib N] [--initrd root.cpio] [--disk rootfs.ext4] [--snapshot-after-ms N --spore DIR] [--resume DIR]\n", .{});
        std.process.exit(2);
    }

    var cmdline: ?[]const u8 = null;
    var mem_mib: u64 = 512;
    var initrd_path: ?[]const u8 = null;
    var disk_path: ?[]const u8 = null;
    var snapshot_after_ms: ?u64 = null;
    var spore_dir: ?[]const u8 = null;
    var resume_dir: ?[]const u8 = null;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--cmdline") and i + 1 < args.len) {
            i += 1;
            cmdline = args[i];
        } else if (std.mem.eql(u8, args[i], "--mem-mib") and i + 1 < args.len) {
            i += 1;
            mem_mib = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--initrd") and i + 1 < args.len) {
            i += 1;
            initrd_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--disk") and i + 1 < args.len) {
            i += 1;
            disk_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--snapshot-after-ms") and i + 1 < args.len) {
            i += 1;
            snapshot_after_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--spore") and i + 1 < args.len) {
            i += 1;
            spore_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--resume") and i + 1 < args.len) {
            i += 1;
            resume_dir = args[i];
        } else {
            std.debug.print("unknown argument: {s}\n", .{args[i]});
            std.process.exit(2);
        }
    }
    if ((snapshot_after_ms == null) != (spore_dir == null)) {
        std.debug.print("--snapshot-after-ms and --spore must be used together\n", .{});
        std.process.exit(2);
    }
    if (resume_dir != null and snapshot_after_ms != null) {
        std.debug.print("--resume cannot be combined with --snapshot-after-ms\n", .{});
        std.process.exit(2);
    }

    const kernel = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], arena, .limited(256 * 1024 * 1024));
    const initrd = if (initrd_path) |path| try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(256 * 1024 * 1024)) else null;

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
    else if (initrd != null)
        "console=hvc0 rdinit=/init"
    else
        "console=hvc0 loglevel=8";

    std.debug.print("sporevm kvm-boot: kernel={s} mem={d}MiB cmdline=\"{s}\"\n", .{ args[1], mem_mib, effective_cmdline });
    const cause = try sporevm.kvm.vm.run(arena, .{
        .kernel = kernel,
        .ram_size = mem_mib * 1024 * 1024,
        .cmdline = effective_cmdline,
        .initrd = initrd,
        .console_sink = consoleSink,
        .disk_fd = disk_fd,
        .resume_dir = resume_dir,
        .snapshot_after_ms = snapshot_after_ms,
        .snapshot_dir = spore_dir,
    });
    std.debug.print("\nsporevm kvm-boot: guest requested {s}\n", .{@tagName(cause)});
}
