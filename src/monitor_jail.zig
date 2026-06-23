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

const exec_denied: u32 = linux.SECCOMP.RET.ERRNO | @as(u32, @intFromEnum(std.posix.E.ACCES));
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
    if (linux.errno(linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0)) != .SUCCESS) return error.MonitorJailFailed;

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

test "monitor jail has a denied exec profile" {
    try std.testing.expect(std.mem.indexOf(u8, macos_profile, "(deny process-exec)") != null);
    if (comptime builtin.os.tag == .linux) {
        const filter = linuxExecDenyFilter();
        try std.testing.expectEqual(@as(u32, @offsetOf(linux.SECCOMP.data, "arch")), filter[0].k);
        try std.testing.expectEqual(audit_arch_current, filter[1].k);
        try std.testing.expectEqual(@as(u32, @offsetOf(linux.SECCOMP.data, "nr")), filter[3].k);
    }
}

fn linuxExecDenyFilter() [9]SockFilter {
    return .{
        stmt(linux.BPF.LD | linux.BPF.W | linux.BPF.ABS, @offsetOf(linux.SECCOMP.data, "arch")),
        jump(linux.BPF.JMP | linux.BPF.JEQ | linux.BPF.K, audit_arch_current, 1, 0),
        stmt(linux.BPF.RET | linux.BPF.K, linux.SECCOMP.RET.KILL_PROCESS),
        stmt(linux.BPF.LD | linux.BPF.W | linux.BPF.ABS, @offsetOf(linux.SECCOMP.data, "nr")),
        jump(linux.BPF.JMP | linux.BPF.JEQ | linux.BPF.K, @intFromEnum(linux.SYS.execve), 0, 1),
        stmt(linux.BPF.RET | linux.BPF.K, exec_denied),
        jump(linux.BPF.JMP | linux.BPF.JEQ | linux.BPF.K, @intFromEnum(linux.SYS.execveat), 0, 1),
        stmt(linux.BPF.RET | linux.BPF.K, exec_denied),
        stmt(linux.BPF.RET | linux.BPF.K, linux.SECCOMP.RET.ALLOW),
    };
}
