//! Small libc fd helpers shared by CLI and trace glue.

const std = @import("std");

pub fn writeAllBestEffort(fd: std.c.fd_t, bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(fd, remaining.ptr, remaining.len);
        if (n <= 0) return;
        remaining = remaining[@intCast(n)..];
    }
}

pub fn setCloseOnExec(fd: std.c.fd_t) error{IoFailed}!void {
    const flags = std.c.fcntl(fd, std.c.F.GETFD, @as(c_int, 0));
    if (flags < 0) return error.IoFailed;
    if ((flags & std.c.FD_CLOEXEC) != 0) return;
    if (std.c.fcntl(fd, std.c.F.SETFD, flags | @as(c_int, std.c.FD_CLOEXEC)) != 0) return error.IoFailed;
}
