//! KVM lazy RAM materialization using Linux userfaultfd.
//!
//! This is deliberately small: one handler thread resolves missing faults by
//! loading and verifying the whole spore memory chunk, then `UFFDIO_COPY`ing it
//! into the registered guest RAM mapping. Readahead, duplicate-fault coalescing,
//! zero-page optimisation, and graceful cross-thread error propagation are later
//! work.

const builtin = @import("builtin");
const std = @import("std");
const linux = std.os.linux;
const spore = @import("../spore.zig");

comptime {
    if (builtin.os.tag != .linux) @compileError("lazy KVM RAM restore is Linux-only");
}

const c = @cImport({
    @cInclude("poll.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/syscall.h");
    @cInclude("unistd.h");
    @cInclude("linux/userfaultfd.h");
});

pub const Options = struct {
    dir: []const u8,
    manifest: spore.MemoryManifest,
    ram: []u8,
    trace_fd: ?std.c.fd_t = null,
};

pub const Pager = struct {
    context: *Context,
    thread: std.Thread,

    pub fn start(options: Options) !Pager {
        try validateMapping(options.ram);

        const uffd = try openUserfaultfd();
        errdefer closeFd(uffd);
        try userfaultApi(uffd);
        try registerMissing(uffd, options.ram);

        var stop_pipe: [2]std.c.fd_t = undefined;
        try linuxCall(linux.pipe2(&stop_pipe, .{ .CLOEXEC = true }));
        errdefer closeFd(stop_pipe[0]);
        errdefer closeFd(stop_pipe[1]);

        const context = try std.heap.c_allocator.create(Context);
        errdefer std.heap.c_allocator.destroy(context);
        context.* = .{
            .uffd = uffd,
            .stop_read_fd = stop_pipe[0],
            .stop_write_fd = stop_pipe[1],
            .dir = options.dir,
            .manifest = options.manifest,
            .ram_addr = @intFromPtr(options.ram.ptr),
            .ram_len = options.ram.len,
            .trace_fd = options.trace_fd,
            .start_ms = monotonicMs() catch 0,
        };

        const thread = try std.Thread.spawn(.{}, faultThread, .{context});
        std.log.info("kvm lazy RAM pager registered: bytes={d} chunks={d}", .{ options.ram.len, options.manifest.chunks.len });
        return .{ .context = context, .thread = thread };
    }

    pub fn deinit(self: *Pager) void {
        var byte: [1]u8 = .{1};
        _ = linux.write(self.context.stop_write_fd, &byte, byte.len);
        self.thread.join();
        closeFd(self.context.uffd);
        closeFd(self.context.stop_read_fd);
        closeFd(self.context.stop_write_fd);
        std.heap.c_allocator.destroy(self.context);
    }
};

const Context = struct {
    uffd: std.c.fd_t,
    stop_read_fd: std.c.fd_t,
    stop_write_fd: std.c.fd_t,
    dir: []const u8,
    manifest: spore.MemoryManifest,
    ram_addr: usize,
    ram_len: usize,
    trace_fd: ?std.c.fd_t,
    start_ms: u64,
};

fn validateMapping(ram: []const u8) !void {
    const page_size = std.heap.page_size_min;
    if (ram.len == 0) return error.BadManifest;
    if (@intFromPtr(ram.ptr) % page_size != 0) return error.BadManifest;
    if (ram.len % page_size != 0) return error.BadManifest;
    if (spore.chunk_size % page_size != 0) return error.BadManifest;
}

fn openUserfaultfd() !std.c.fd_t {
    const flags: u32 = @bitCast(linux.O{ .CLOEXEC = true, .NONBLOCK = true });
    const rc = c.syscall(c.SYS_userfaultfd, flags);
    if (rc < 0) {
        std.log.err("userfaultfd unavailable; enable vm.unprivileged_userfaultfd or run with the required capability", .{});
        return error.UserfaultfdUnavailable;
    }
    return @intCast(rc);
}

fn userfaultApi(uffd: std.c.fd_t) !void {
    var api = c.struct_uffdio_api{
        .api = c.UFFD_API,
        .features = 0,
        .ioctls = 0,
    };
    try userfaultIoctl(uffd, c.UFFDIO_API, @intFromPtr(&api));
}

fn registerMissing(uffd: std.c.fd_t, ram: []u8) !void {
    var reg = c.struct_uffdio_register{
        .range = .{
            .start = @intFromPtr(ram.ptr),
            .len = ram.len,
        },
        .mode = c.UFFDIO_REGISTER_MODE_MISSING,
        .ioctls = 0,
    };
    try userfaultIoctl(uffd, c.UFFDIO_REGISTER, @intFromPtr(&reg));
}

fn faultThread(context: *Context) void {
    while (true) {
        var fds = [_]linux.pollfd{
            .{ .fd = context.uffd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = context.stop_read_fd, .events = linux.POLL.IN, .revents = 0 },
        };
        const rc = linux.poll(&fds, fds.len, -1);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => fail("userfaultfd poll failed", .{}),
        }

        if ((fds[1].revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR)) != 0) return;
        if ((fds[0].revents & linux.POLL.IN) != 0) handleFault(context) catch |err| {
            fail("lazy RAM fault handling failed: {s}", .{@errorName(err)});
        };
        if ((fds[0].revents & (linux.POLL.ERR | linux.POLL.HUP)) != 0) {
            // Linux can report POLLERR on an otherwise usable userfaultfd even
            // with no pending fault. Stay responsive to the stop pipe without
            // spinning until a real fault arrives with POLLIN.
            sleepOneMs();
        }
    }
}

fn handleFault(context: *Context) !void {
    var msg: c.struct_uffd_msg = undefined;
    const msg_bytes = std.mem.asBytes(&msg);
    while (true) {
        const rc = linux.read(context.uffd, msg_bytes.ptr, msg_bytes.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc != msg_bytes.len) return error.UserfaultfdShortRead;
                break;
            },
            .INTR => continue,
            .AGAIN => return,
            else => return error.UserfaultfdReadFailed,
        }
    }

    if (msg.event != c.UFFD_EVENT_PAGEFAULT) return error.UserfaultfdUnexpectedEvent;
    const fault_addr: usize = @intCast(msg.arg.pagefault.address);
    if (fault_addr < context.ram_addr) return error.BadManifest;
    const offset = fault_addr - context.ram_addr;
    if (offset >= context.ram_len) return error.BadManifest;
    const index = offset / spore.chunk_size;
    const range = try spore.memoryChunkRange(context.manifest, context.ram_len, index);
    const len = range.end - range.start;
    if (len == 0 or len % std.heap.page_size_min != 0) return error.BadManifest;

    const chunk = try std.heap.c_allocator.alloc(u8, len);
    defer std.heap.c_allocator.free(chunk);
    try spore.loadMemoryChunk(std.heap.c_allocator, context.dir, context.manifest, context.ram_len, index, chunk);

    var copy = c.struct_uffdio_copy{
        .dst = context.ram_addr + range.start,
        .src = @intFromPtr(chunk.ptr),
        .len = len,
        .mode = 0,
        .copy = 0,
    };
    userfaultIoctl(context.uffd, c.UFFDIO_COPY, @intFromPtr(&copy)) catch return error.UserfaultfdCopyFailed;
    if (copy.copy < 0 or @as(usize, @intCast(copy.copy)) != len) return error.UserfaultfdCopyFailed;
    try writeTrace(context, index, range, len);
}

fn userfaultIoctl(fd: std.c.fd_t, request: u32, arg: usize) !void {
    switch (linux.errno(linux.ioctl(fd, request, arg))) {
        .SUCCESS => {},
        else => return error.UserfaultfdIoctlFailed,
    }
}

fn linuxCall(rc: usize) !void {
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => return error.IoFailed,
    }
}

fn closeFd(fd: std.c.fd_t) void {
    _ = std.c.close(fd);
}

fn sleepOneMs() void {
    var req = linux.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
    while (true) {
        switch (linux.errno(linux.nanosleep(&req, &req))) {
            .SUCCESS => return,
            .INTR => continue,
            else => return,
        }
    }
}

fn writeTrace(context: *Context, index: usize, range: spore.MemoryChunkRange, len: usize) !void {
    const fd = context.trace_fd orelse return;
    const now = monotonicMs() catch context.start_ms;
    const fault_ms = if (now >= context.start_ms) now - context.start_ms else 0;
    const nonzero: u1 = if (context.manifest.chunks[index] == null) 0 else 1;
    var buf: [192]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "fault_ms={d} chunk_index={d} guest_offset={d} len={d} nonzero={d}\n", .{
        fault_ms,
        index,
        range.start,
        len,
        nonzero,
    });
    try writeAll(fd, line);
}

fn writeAll(fd: std.c.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const tail = bytes[written..];
        const rc = linux.write(fd, tail.ptr, tail.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.IoFailed;
                written += @intCast(rc);
            },
            .INTR => continue,
            else => return error.IoFailed,
        }
    }
}

fn monotonicMs() !u64 {
    var ts: linux.timespec = undefined;
    const rc = linux.clock_gettime(.MONOTONIC, &ts);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => return error.IoFailed,
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}

test "fault address maps to memory chunk range" {
    var refs = [_]?[]const u8{null} ** 3;
    const manifest = spore.MemoryManifest{ .chunk_size = spore.chunk_size, .chunks = &refs };
    const ram_len = refs.len * spore.chunk_size;
    const range = try spore.memoryChunkRange(manifest, ram_len, 2);
    try std.testing.expectEqual(@as(usize, 2 * spore.chunk_size), range.start);
    try std.testing.expectEqual(@as(usize, 3 * spore.chunk_size), range.end);
}
