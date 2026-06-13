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

    var cmdline: ?[]const u8 = null;
    var mem_mib: u64 = 512;
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

    std.debug.print("sporevm hvf-boot: kernel={s} mem={d}MiB cmdline=\"{s}\"\n", .{ args[1], mem_mib, effective_cmdline });

    const cause = try sporevm.hvf.vm.run(arena, .{
        .kernel = kernel,
        .ram_size = mem_mib * 1024 * 1024,
        .cmdline = effective_cmdline,
        .console_sink = consoleSink,
        .disk_fd = disk_fd,
        .poll_stdin = interactive,
        .resume_dir = resume_dir,
        .snapshot_after_ms = snapshot_after_ms,
        .snapshot_dir = spore_dir,
    });
    std.debug.print("\nsporevm hvf-boot: guest requested {s}\n", .{@tagName(cause)});
}
