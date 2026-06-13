//! KVM boot harness: boot a kernel under Linux KVM on aarch64.
//!
//! Bring-up tool, not the product CLI. Usage:
//!   zig build kvm-boot
//!   ./zig-out/bin/kvm-boot <kernel-Image> [--cmdline "..."] [--mem-mib N] [--initrd root.cpio] [--disk rootfs.ext4] [--snapshot-after-ms N --spore DIR] [--resume DIR] [--trust-ram-backing] [--fdpass-ram-backing]

const std = @import("std");
const linux = std.os.linux;
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
        std.debug.print("usage: kvm-boot <kernel-Image> [--cmdline \"...\"] [--mem-mib N] [--initrd root.cpio] [--disk rootfs.ext4] [--snapshot-after-ms N --spore DIR] [--resume DIR] [--trust-ram-backing] [--fdpass-ram-backing]\n", .{});
        std.process.exit(2);
    }

    var cmdline: ?[]const u8 = null;
    var mem_mib: u64 = 512;
    var initrd_path: ?[]const u8 = null;
    var disk_path: ?[]const u8 = null;
    var snapshot_after_ms: ?u64 = null;
    var spore_dir: ?[]const u8 = null;
    var resume_dir: ?[]const u8 = null;
    var trust_ram_backing = false;
    var fdpass_ram_backing = false;
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
        } else if (std.mem.eql(u8, args[i], "--trust-ram-backing")) {
            trust_ram_backing = true;
        } else if (std.mem.eql(u8, args[i], "--fdpass-ram-backing")) {
            fdpass_ram_backing = true;
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
    if (fdpass_ram_backing and !trust_ram_backing) {
        std.debug.print("--fdpass-ram-backing requires --trust-ram-backing\n", .{});
        std.process.exit(2);
    }
    if (fdpass_ram_backing and resume_dir == null) {
        std.debug.print("--fdpass-ram-backing requires --resume\n", .{});
        std.process.exit(2);
    }

    var ram_backing_fd: ?std.c.fd_t = null;
    defer {
        if (ram_backing_fd) |fd| _ = std.c.close(fd);
    }
    if (trust_ram_backing) {
        ram_backing_fd = try openTrustedRamBacking(arena, resume_dir);
    }
    if (fdpass_ram_backing) {
        if (ram_backing_fd == null) {
            std.debug.print("--fdpass-ram-backing requires an available trusted RAM backing\n", .{});
            std.process.exit(1);
        }
        const original_fd = ram_backing_fd.?;
        ram_backing_fd = null;
        ram_backing_fd = try receiveRamBackingViaFdpass(original_fd);
        std.debug.print("sporevm kvm-boot: received RAM backing fd via SCM_RIGHTS harness path\n", .{});
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
        .ram_backing_fd = ram_backing_fd,
        .snapshot_after_ms = snapshot_after_ms,
        .snapshot_dir = spore_dir,
    });
    std.debug.print("\nsporevm kvm-boot: guest requested {s}\n", .{@tagName(cause)});
}

fn openTrustedRamBacking(allocator: std.mem.Allocator, resume_dir: ?[]const u8) !?std.c.fd_t {
    const dir = resume_dir orelse return null;
    const parsed = try sporevm.spore.loadManifest(allocator, dir);
    defer parsed.deinit();
    const backing = parsed.value.memory.backing orelse return null;
    const path = try sporevm.spore.memoryBackingPath(allocator, dir, backing);
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) {
        std.debug.print("trusted RAM backing unavailable: {s}; falling back to chunks\n", .{path});
        return null;
    }
    return fd;
}

fn receiveRamBackingViaFdpass(original_fd: std.c.fd_t) !std.c.fd_t {
    var sockets: [2]std.c.fd_t = undefined;
    try linuxCall(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets));

    const fork_rc = linux.fork();
    switch (linux.errno(fork_rc)) {
        .SUCCESS => {},
        else => {
            _ = std.c.close(sockets[0]);
            _ = std.c.close(sockets[1]);
            return error.IoFailed;
        },
    }

    if (fork_rc == 0) {
        _ = std.c.close(sockets[0]);
        sporevm.fdpass.sendFd(sockets[1], original_fd) catch std.process.exit(1);
        _ = std.c.close(sockets[1]);
        std.process.exit(0);
    }

    const helper_pid: linux.pid_t = @intCast(fork_rc);
    _ = std.c.close(sockets[1]);
    _ = std.c.close(original_fd);

    const received = sporevm.fdpass.recvFd(sockets[0]) catch |err| {
        _ = std.c.close(sockets[0]);
        _ = waitForHelper(helper_pid) catch {};
        return err;
    };
    _ = std.c.close(sockets[0]);
    errdefer _ = std.c.close(received);
    try waitForHelper(helper_pid);
    return received;
}

fn waitForHelper(pid: linux.pid_t) !void {
    var status: u32 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &status, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.IoFailed,
        }
    }
    if (!linux.W.IFEXITED(status) or linux.W.EXITSTATUS(status) != 0) return error.IoFailed;
}

fn linuxCall(rc: usize) !void {
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => return error.IoFailed,
    }
}
