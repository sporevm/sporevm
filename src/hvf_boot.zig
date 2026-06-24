//! HVF boot harness: boot a kernel under Hypervisor.framework.
//!
//! Bring-up tool, not the product CLI. Usage:
//!   zig build hvf-boot
//!   ./zig-out/bin/hvf-boot <kernel-Image> [--cmdline "..."] [--mem-mib N] [--initrd root.cpio] [--disk rootfs.ext4] [--snapshot-after-ms N --spore DIR] [--dirty-track] [--dirty-epoch-ms N] [--resume DIR] [--lazy-ram] [--lazy-ram-trace PATH] [--trust-ram-backing]

const std = @import("std");
const spore_internal = @import("spore_internal");

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
        std.debug.print("usage: hvf-boot <kernel-Image> [--cmdline \"...\"] [--mem-mib N] [--initrd root.cpio] [--disk rootfs.ext4] [--snapshot-after-ms N --spore DIR] [--dirty-track] [--dirty-epoch-ms N] [--resume DIR] [--lazy-ram] [--lazy-ram-trace PATH] [--trust-ram-backing]\n", .{});
        std.process.exit(2);
    }

    var cmdline: ?[]const u8 = null;
    var mem_mib: u64 = 512;
    var initrd_path: ?[]const u8 = null;
    var disk_path: ?[]const u8 = null;
    var snapshot_after_ms: ?u64 = null;
    var spore_dir: ?[]const u8 = null;
    var resume_dir: ?[]const u8 = null;
    var lazy_ram = false;
    var lazy_ram_trace_path: ?[]const u8 = null;
    var trust_ram_backing = false;
    var dirty_track = false;
    var dirty_epoch_ms: u64 = 250;
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
        } else if (std.mem.eql(u8, args[i], "--dirty-track")) {
            dirty_track = true;
        } else if (std.mem.eql(u8, args[i], "--dirty-epoch-ms") and i + 1 < args.len) {
            i += 1;
            dirty_epoch_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--resume") and i + 1 < args.len) {
            i += 1;
            resume_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--lazy-ram")) {
            lazy_ram = true;
        } else if (std.mem.eql(u8, args[i], "--lazy-ram-trace") and i + 1 < args.len) {
            i += 1;
            lazy_ram_trace_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--trust-ram-backing")) {
            trust_ram_backing = true;
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
    if (dirty_track and snapshot_after_ms == null) {
        std.debug.print("--dirty-track requires --snapshot-after-ms and --spore\n", .{});
        std.process.exit(2);
    }
    if (lazy_ram and resume_dir == null) {
        std.debug.print("--lazy-ram requires --resume\n", .{});
        std.process.exit(2);
    }
    if (lazy_ram and trust_ram_backing) {
        std.debug.print("--lazy-ram cannot be combined with --trust-ram-backing\n", .{});
        std.process.exit(2);
    }
    if (lazy_ram_trace_path != null and !lazy_ram) {
        std.debug.print("--lazy-ram-trace requires --lazy-ram\n", .{});
        std.process.exit(2);
    }

    var ram_backing_fd: ?std.c.fd_t = null;
    defer {
        if (ram_backing_fd) |fd| _ = std.c.close(fd);
    }
    if (trust_ram_backing) {
        ram_backing_fd = try openTrustedRamBacking(arena, resume_dir);
    }

    var lazy_ram_trace_fd: ?std.c.fd_t = null;
    defer {
        if (lazy_ram_trace_fd) |fd| _ = std.c.close(fd);
    }
    if (lazy_ram_trace_path) |path| {
        const pathz = try arena.dupeZ(u8, path);
        const fd = std.c.open(pathz, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c_uint, 0o644));
        if (fd < 0) {
            std.debug.print("cannot open lazy RAM trace: {s}\n", .{path});
            std.process.exit(1);
        }
        lazy_ram_trace_fd = fd;
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

    const cause = try spore_internal.hvf.vm.run(arena, .{
        .kernel = kernel,
        .ram_size = mem_mib * 1024 * 1024,
        .cmdline = effective_cmdline,
        .initrd = initrd,
        .console_sink = consoleSink,
        .disk_fd = disk_fd,
        .poll_stdin = interactive,
        .resume_dir = resume_dir,
        .ram_backing_fd = ram_backing_fd,
        .ram_restore_mode = if (lazy_ram) .lazy_chunks else .eager_chunks,
        .lazy_ram_trace_fd = lazy_ram_trace_fd,
        .snapshot_after_ms = snapshot_after_ms,
        .snapshot_dir = spore_dir,
        .dirty_tracking = .{ .enabled = dirty_track, .epoch_ms = dirty_epoch_ms },
    });
    std.debug.print("\nsporevm hvf-boot: guest requested {s}\n", .{@tagName(cause)});
}

fn openTrustedRamBacking(allocator: std.mem.Allocator, resume_dir: ?[]const u8) !?std.c.fd_t {
    const dir = resume_dir orelse return null;
    const parsed = try spore_internal.spore.loadManifest(allocator, dir);
    defer parsed.deinit();
    const backing = parsed.value.memory.backing orelse return null;
    const path = try spore_internal.spore.memoryBackingPath(allocator, dir, backing);
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) {
        std.debug.print("trusted RAM backing unavailable: {s}; falling back to chunks\n", .{path});
        return null;
    }
    return fd;
}
