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
