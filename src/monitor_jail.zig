//! Monitor process jail entrypoint.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const linux = std.os.linux;

pub const smoke_env = "SPOREVM_MONITOR_JAIL_SMOKE";

const macos_profile =
    \\(version 1)
    \\(allow default)
    \\(deny process-exec)
;

const macos = if (builtin.os.tag == .macos) struct {
    extern "c" fn sandbox_init(profile: [*:0]const u8, flags: u64, errorbuf: *?[*:0]u8) c_int;
    extern "c" fn sandbox_free_error(errorbuf: ?[*:0]u8) void;
} else struct {};

pub fn wantsSmoke(environ: *const std.process.Environ.Map) bool {
    return std.mem.eql(u8, environ.get(smoke_env) orelse "", "1");
}

pub fn applyForMonitor(_: *const std.process.Environ.Map) !void {
    if (comptime builtin.os.tag == .macos) try applyMacos();
    if (comptime builtin.os.tag == .linux) try applyLinux();
}

fn applyMacos() !void {
    var errorbuf: ?[*:0]u8 = null;
    if (macos.sandbox_init(macos_profile, 0, &errorbuf) != 0) {
        defer macos.sandbox_free_error(errorbuf);
        if (errorbuf) |message| std.debug.print("spore monitor: sandbox_init failed: {s}\n", .{std.mem.span(message)});
        return error.MonitorJailFailed;
    }
}

const SockFilter = extern struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
};

const SockFprog = extern struct {
    len: u16,
    filter: [*]const SockFilter,
};

const exec_denied: u32 = linux.SECCOMP.RET.ERRNO | @as(u32, @backingInt(std.posix.E.ACCES));
const audit_arch_current: u32 = switch (builtin.cpu.arch) {
    .aarch64 => 0xc00000b7,
    .x86_64 => 0xc000003e,
    else => 0,
};

fn stmt(code: u16, k: u32) SockFilter {
    return .{ .code = code, .jt = 0, .jf = 0, .k = k };
}

fn jump(code: u16, k: u32, jt: u8, jf: u8) SockFilter {
    return .{ .code = code, .jt = jt, .jf = jf, .k = k };
}

fn applyLinux() !void {
    if (linux.errno(linux.prctl(@backingInt(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0)) != .SUCCESS) return error.MonitorJailFailed;

    const filter = linuxExecDenyFilter();
    const program = SockFprog{ .len = filter.len, .filter = &filter };
    if (linux.errno(linux.seccomp(linux.SECCOMP.SET_MODE_FILTER, 0, &program)) != .SUCCESS) return error.MonitorJailFailed;
}

pub fn smokeDeniedExec(io: Io) !void {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return error.UnsupportedMonitorJailSmoke;

    var child = std.process.spawn(io, .{
        .argv = &.{"/usr/bin/true"},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    child.kill(io);
    return error.MonitorJailAllowedExec;
}

/// x86_64 kernels with x32 enabled report x32 syscalls under the native
/// x86_64 audit arch with this bit set in `nr`, so x32 execve would miss the
/// native exec checks. No other supported architecture uses the bit.
const x32_syscall_bit: u32 = 0x40000000;

fn linuxExecDenyFilter() [11]SockFilter {
    return .{
        stmt(linux.BPF.LD | linux.BPF.W | linux.BPF.ABS, @offsetOf(linux.SECCOMP.data, "arch")),
        jump(linux.BPF.JMP | linux.BPF.JEQ | linux.BPF.K, audit_arch_current, 1, 0),
        stmt(linux.BPF.RET | linux.BPF.K, linux.SECCOMP.RET.KILL_PROCESS),
        stmt(linux.BPF.LD | linux.BPF.W | linux.BPF.ABS, @offsetOf(linux.SECCOMP.data, "nr")),
        jump(linux.BPF.JMP | linux.BPF.JSET | linux.BPF.K, x32_syscall_bit, 0, 1),
        stmt(linux.BPF.RET | linux.BPF.K, linux.SECCOMP.RET.KILL_PROCESS),
        jump(linux.BPF.JMP | linux.BPF.JEQ | linux.BPF.K, @backingInt(linux.SYS.execve), 0, 1),
        stmt(linux.BPF.RET | linux.BPF.K, exec_denied),
        jump(linux.BPF.JMP | linux.BPF.JEQ | linux.BPF.K, @backingInt(linux.SYS.execveat), 0, 1),
        stmt(linux.BPF.RET | linux.BPF.K, exec_denied),
        stmt(linux.BPF.RET | linux.BPF.K, linux.SECCOMP.RET.ALLOW),
    };
}

/// Runs the classic BPF subset used by the jail filter for one syscall, as
/// the kernel would before dispatch.
fn evalSeccompFilter(filter: []const SockFilter, arch: u32, nr: u32) !u32 {
    var data = std.mem.zeroes(linux.SECCOMP.data);
    data.arch = arch;
    data.nr = @bitCast(nr);
    const bytes = std.mem.asBytes(&data);
    var acc: u32 = 0;
    var pc: usize = 0;
    while (pc < filter.len) : (pc += 1) {
        const insn = filter[pc];
        switch (insn.code) {
            linux.BPF.LD | linux.BPF.W | linux.BPF.ABS => acc = std.mem.readInt(u32, bytes[insn.k..][0..4], builtin.cpu.arch.endian()),
            linux.BPF.JMP | linux.BPF.JEQ | linux.BPF.K => pc += if (acc == insn.k) insn.jt else insn.jf,
            linux.BPF.JMP | linux.BPF.JSET | linux.BPF.K => pc += if (acc & insn.k != 0) insn.jt else insn.jf,
            linux.BPF.RET | linux.BPF.K => return insn.k,
            else => return error.UnsupportedInstruction,
        }
    }
    return error.MissingReturn;
}

test "linux monitor jail denies native exec and kills x32 syscalls" {
    const filter = linuxExecDenyFilter();
    const denied = linux.SECCOMP.RET.ERRNO | @as(u32, @backingInt(std.posix.E.ACCES));
    const killed = linux.SECCOMP.RET.KILL_PROCESS;
    const audit_arch_i386: u32 = 0x40000003;

    try std.testing.expectEqual(denied, try evalSeccompFilter(&filter, audit_arch_current, @backingInt(linux.SYS.execve)));
    try std.testing.expectEqual(denied, try evalSeccompFilter(&filter, audit_arch_current, @backingInt(linux.SYS.execveat)));
    try std.testing.expectEqual(linux.SECCOMP.RET.ALLOW, try evalSeccompFilter(&filter, audit_arch_current, @backingInt(linux.SYS.getpid)));
    try std.testing.expectEqual(killed, try evalSeccompFilter(&filter, audit_arch_i386, @backingInt(linux.SYS.getpid)));
    try std.testing.expectEqual(killed, try evalSeccompFilter(&filter, audit_arch_current, @backingInt(linux.syscalls.X32.execve)));
    try std.testing.expectEqual(killed, try evalSeccompFilter(&filter, audit_arch_current, @backingInt(linux.syscalls.X32.execveat)));
}
