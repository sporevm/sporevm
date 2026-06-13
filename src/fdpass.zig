//! Unix-domain fd passing helpers for the Linux monitor path.
//!
//! Same-host RAM sharing must move through explicit fd transfer between
//! trusted monitor processes, not through manifest path trust. This module is
//! deliberately small: one `SCM_RIGHTS` fd per message, with a payload byte so
//! the ancillary data is delivered consistently.

const builtin = @import("builtin");
const std = @import("std");
const linux = std.os.linux;

comptime {
    if (builtin.os.tag != .linux) @compileError("fdpass is Linux-only for now");
}

pub const Error = error{
    IoFailed,
    MissingFd,
    ShortMessage,
    TooManyFds,
    TruncatedControl,
    WrongControlMessage,
};

const payload_byte: u8 = 0;
const fd_size = @sizeOf(std.c.fd_t);
const cmsg_cloexec: u32 = 0x40000000;

/// Send a duplicate of `fd_to_send` over `socket_fd`.
/// The caller keeps ownership of `fd_to_send`; the receiver owns and must close
/// the descriptor returned by `recvFd`.
pub fn sendFd(socket_fd: std.c.fd_t, fd_to_send: std.c.fd_t) Error!void {
    var payload = [_]u8{payload_byte};
    var iov = [_]std.posix.iovec_const{.{ .base = &payload, .len = payload.len }};

    var control: [cmsgSpace(fd_size)]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    @memset(&control, 0);
    const header = cmsgHeader(&control);
    header.* = .{
        .len = cmsgLen(fd_size),
        .level = linux.SOL.SOCKET,
        .type = linux.SCM.RIGHTS,
    };
    fdData(&control).* = fd_to_send;

    const msg = linux.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = iov[0..].ptr,
        .iovlen = iov.len,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    while (true) {
        const rc = linux.sendmsg(socket_fd, &msg, linux.MSG.NOSIGNAL);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc != payload.len) return error.ShortMessage;
                return;
            },
            .INTR => continue,
            else => return error.IoFailed,
        }
    }
}

/// Receive exactly one fd from `socket_fd`.
/// The returned fd is owned by the caller and has close-on-exec set.
pub fn recvFd(socket_fd: std.c.fd_t) Error!std.c.fd_t {
    var payload: [1]u8 = undefined;
    var iov = [_]std.posix.iovec{.{ .base = &payload, .len = payload.len }};

    var control: [cmsgSpace(fd_size)]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    @memset(&control, 0);
    var msg = linux.msghdr{
        .name = null,
        .namelen = 0,
        .iov = iov[0..].ptr,
        .iovlen = iov.len,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    while (true) {
        const rc = linux.recvmsg(socket_fd, &msg, cmsg_cloexec);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc != payload.len) return error.ShortMessage;
                break;
            },
            .INTR => continue,
            else => return error.IoFailed,
        }
    }

    var keep_fd = false;
    defer {
        if (!keep_fd) closeDeliveredRights(&control, msg.controllen);
    }

    if ((msg.flags & linux.MSG.CTRUNC) != 0) return error.TruncatedControl;
    if (msg.controllen < @sizeOf(linux.cmsghdr)) return error.MissingFd;

    const header = cmsgHeader(&control);
    if (header.len < cmsgLen(fd_size)) return error.MissingFd;
    if (header.level != linux.SOL.SOCKET or header.type != linux.SCM.RIGHTS) return error.WrongControlMessage;
    if (header.len != cmsgLen(fd_size)) return error.TooManyFds;
    keep_fd = true;
    return fdData(&control).*;
}

fn cmsgAlign(len: usize) usize {
    const alignment = @sizeOf(usize);
    const mask: usize = alignment - 1;
    return (len + mask) & ~mask;
}

fn cmsgLen(len: usize) usize {
    return cmsgAlign(@sizeOf(linux.cmsghdr)) + len;
}

fn cmsgSpace(len: usize) usize {
    return cmsgAlign(@sizeOf(linux.cmsghdr)) + cmsgAlign(len);
}

fn cmsgHeader(control: *align(@alignOf(linux.cmsghdr)) [cmsgSpace(fd_size)]u8) *linux.cmsghdr {
    return @as(*linux.cmsghdr, @ptrCast(control));
}

fn fdData(control: *align(@alignOf(linux.cmsghdr)) [cmsgSpace(fd_size)]u8) *std.c.fd_t {
    return @as(*std.c.fd_t, @ptrCast(@alignCast(control[cmsgAlign(@sizeOf(linux.cmsghdr))..].ptr)));
}

fn closeDeliveredRights(control: *align(@alignOf(linux.cmsghdr)) [cmsgSpace(fd_size)]u8, controllen: usize) void {
    if (controllen < @sizeOf(linux.cmsghdr)) return;
    const header = cmsgHeader(control);
    if (header.level != linux.SOL.SOCKET or header.type != linux.SCM.RIGHTS) return;

    const data_offset = cmsgAlign(@sizeOf(linux.cmsghdr));
    const visible_len = @min(header.len, controllen);
    if (visible_len <= data_offset) return;

    const data_len = visible_len - data_offset;
    const fd_count = data_len / fd_size;
    const fds = @as([*]std.c.fd_t, @ptrCast(@alignCast(control[data_offset..].ptr)));
    for (fds[0..fd_count]) |fd| closeFd(fd);
}

fn checkLinux(rc: usize) Error!void {
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => return error.IoFailed,
    }
}

fn closeFd(fd: std.c.fd_t) void {
    _ = std.c.close(fd);
}

test "SCM_RIGHTS round-trips a writable fd" {
    var sockets: [2]std.c.fd_t = undefined;
    try checkLinux(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets));
    defer closeFd(sockets[0]);
    defer closeFd(sockets[1]);

    var pipe_fds: [2]std.c.fd_t = undefined;
    try checkLinux(linux.pipe(&pipe_fds));
    defer closeFd(pipe_fds[0]);
    defer closeFd(pipe_fds[1]);

    try sendFd(sockets[0], pipe_fds[1]);
    const received = try recvFd(sockets[1]);
    defer closeFd(received);

    const fd_flags = linux.fcntl(received, linux.F.GETFD, 0);
    try checkLinux(fd_flags);
    try std.testing.expect((fd_flags & linux.FD_CLOEXEC) != 0);

    const sent = "ok";
    const write_rc = linux.write(received, sent.ptr, sent.len);
    try checkLinux(write_rc);
    try std.testing.expectEqual(sent.len, write_rc);

    var buf: [2]u8 = undefined;
    const read_rc = linux.read(pipe_fds[0], &buf, buf.len);
    try checkLinux(read_rc);
    try std.testing.expectEqual(sent.len, read_rc);
    try std.testing.expectEqualSlices(u8, sent, &buf);
}

test "SCM_RIGHTS rejects and closes extra fds" {
    var sockets: [2]std.c.fd_t = undefined;
    try checkLinux(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets));
    defer closeFd(sockets[0]);
    defer closeFd(sockets[1]);

    var pipe_fds: [2]std.c.fd_t = undefined;
    try checkLinux(linux.pipe2(&pipe_fds, .{ .NONBLOCK = true, .CLOEXEC = true }));
    defer closeFd(pipe_fds[0]);
    var write_open = true;
    defer {
        if (write_open) closeFd(pipe_fds[1]);
    }

    try sendFdPairForTest(sockets[0], pipe_fds[1], pipe_fds[1]);
    try std.testing.expectError(error.TooManyFds, recvFd(sockets[1]));

    closeFd(pipe_fds[1]);
    write_open = false;

    var buf: [1]u8 = undefined;
    const read_rc = linux.read(pipe_fds[0], &buf, buf.len);
    try checkLinux(read_rc);
    try std.testing.expectEqual(@as(usize, 0), read_rc);
}

fn sendFdPairForTest(socket_fd: std.c.fd_t, first: std.c.fd_t, second: std.c.fd_t) Error!void {
    var payload = [_]u8{payload_byte};
    var iov = [_]std.posix.iovec_const{.{ .base = &payload, .len = payload.len }};

    var control: [cmsgSpace(fd_size * 2)]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    @memset(&control, 0);
    const header = @as(*linux.cmsghdr, @ptrCast(&control));
    header.* = .{
        .len = cmsgLen(fd_size * 2),
        .level = linux.SOL.SOCKET,
        .type = linux.SCM.RIGHTS,
    };
    const fds = @as(*[2]std.c.fd_t, @ptrCast(@alignCast(control[cmsgAlign(@sizeOf(linux.cmsghdr))..].ptr)));
    fds.* = .{ first, second };

    const msg = linux.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = iov[0..].ptr,
        .iovlen = iov.len,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    const rc = linux.sendmsg(socket_fd, &msg, linux.MSG.NOSIGNAL);
    try checkLinux(rc);
    if (rc != payload.len) return error.ShortMessage;
}
