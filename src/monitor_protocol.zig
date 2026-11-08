//! The named VM monitor's control protocol. A client connects to the
//! monitor's socket and sends one JSON request line; the monitor answers
//! with one JSON response line or, for exec and copy, with SPIO frames.
//! Requests and responses are closed sets decoded strictly: an unknown type,
//! an unknown field, or a duplicate field fails the whole message.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;

const lifecycle = @import("lifecycle.zig");
const runtime_disk_claim = @import("runtime_disk_claim.zig");
const runtime_disk_fork_control = @import("runtime_disk_fork_control.zig");
const spore_stream = @import("spore_stream.zig");
const version = @import("version.zig");
const vm_registry = @import("vm_registry.zig");

pub const hello_schema = "spore.monitor.hello.v1";
pub const helper_contract: u32 = 1;
/// The longest request line, newline included.
pub const max_request_bytes = 8192;
pub const max_response_bytes = 128 * 1024;
/// The monitor answers `hello` and `shutdown` when it accepts the
/// connection, so a monitor that takes longer is wedged.
pub const reply_deadline_ms = 2_000;

pub const Hello = struct { type: []const u8 = "hello" };
pub const Shutdown = struct { type: []const u8 = "shutdown" };
pub const InitialOutput = struct { type: []const u8 = "initial-output" };

pub const Start = struct {
    type: []const u8 = "start",
    argv: []const []const u8,
    env: []const []const u8 = &.{},
    working_dir: ?[]const u8 = null,
    retain_output: bool = false,
};

pub const Stdio = enum { pipe, tty };

pub const ExecStream = struct {
    type: []const u8 = "exec-stream-v1",
    argv: []const []const u8,
    env: []const []const u8 = &.{},
    working_dir: ?[]const u8 = null,
    /// Null inherits the VM default; zero disables the execution limit.
    timeout_ms: ?u64 = null,
    stdio: Stdio,
    terminal_rows: u16 = 24,
    terminal_cols: u16 = 80,
};

pub const CopyIn = struct { type: []const u8 = "copy-in-v1", path: []const u8 };
pub const CopyOut = struct { type: []const u8 = "copy-out-v1", path: []const u8 };

/// Captures the VM and ends it.
pub const Suspend = struct { type: []const u8 = "suspend", out_dir: []const u8 };

/// Captures the VM, which keeps running, into `out_dir`, then renames it to
/// `publish_dir` when one is given.
pub const Snapshot = struct {
    type: []const u8 = "snapshot",
    out_dir: []const u8,
    publish_dir: ?[]const u8 = null,
};

pub const Request = union(enum) {
    hello: Hello,
    shutdown: Shutdown,
    start: Start,
    initial_output: InitialOutput,
    exec_stream: ExecStream,
    copy_in: CopyIn,
    copy_out: CopyOut,
    @"suspend": Suspend,
    snapshot: Snapshot,
    disk_fork_prepare: runtime_disk_fork_control.PrepareRequest,
    disk_fork_cancel: runtime_disk_fork_control.CancelRequest,
    disk_claim: runtime_disk_claim.ClaimRequest,

    /// Whether the monitor answers with SPIO frames, errors included.
    pub fn streams(self: Request) bool {
        return switch (self) {
            .exec_stream, .copy_in, .copy_out => true,
            else => false,
        };
    }
};

pub const Ok = struct { type: []const u8 = "ok" };

/// Failures the CLI tells apart. Other failures carry only a message.
pub const ErrorCode = enum {
    image_store_incomplete,
    fast_fork_unavailable,
    unsupported_named_fork_disk,
    disk_fork_baseline_unavailable,

    pub fn of(err: anyerror) ?ErrorCode {
        return switch (err) {
            error.FastForkUnavailable => .fast_fork_unavailable,
            error.UnsupportedNamedForkDisk => .unsupported_named_fork_disk,
            error.DiskForkBaselineUnavailable => .disk_fork_baseline_unavailable,
            else => null,
        };
    }
};

pub const Error = struct {
    type: []const u8 = "error",
    message: []const u8,
    code: ?ErrorCode = null,
};

pub const ExecResult = struct {
    type: []const u8 = "exec_result",
    exit_code: i32,
    stdout_b64: []const u8,
    stderr_b64: []const u8,
    stdout_truncated: bool,
    stderr_truncated: bool,
};

pub const Suspended = struct { type: []const u8 = "suspended", out_dir: []const u8 };
pub const Snapshotted = struct { type: []const u8 = "snapshotted", out_dir: []const u8 };

pub const Response = union(enum) {
    ok: Ok,
    err: Error,
    exec_result: ExecResult,
    suspended: Suspended,
    snapshotted: Snapshotted,
    disk_fork_prepared: runtime_disk_fork_control.PreparedResponse,
};

/// The monitor's answer to `hello`. Clients read it leniently, so a monitor
/// from another release reports its version instead of failing to decode.
pub const HelloReply = struct {
    type: []const u8 = "hello",
    schema: []const u8 = hello_schema,
    spore_version: []const u8 = version.value,
    helper_contract: u32 = helper_contract,
};

/// Decodes one request line into `arena`.
pub fn decodeRequest(arena: std.mem.Allocator, line: []const u8) error{ BadControlRequest, OutOfMemory }!Request {
    const request = decodeTagged(Request, arena, line) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadMessage => return error.BadControlRequest,
    };
    switch (request) {
        .disk_fork_prepare => |prepare| runtime_disk_fork_control.validatePrepare(prepare) catch return error.BadControlRequest,
        .disk_fork_cancel => |cancel| runtime_disk_fork_control.validateCancel(cancel) catch return error.BadControlRequest,
        .disk_claim => |claim| runtime_disk_claim.validateClaimRequest(claim) catch return error.BadControlRequest,
        else => {},
    }
    return request;
}

/// Decodes one response line into `arena`.
pub fn decodeResponse(arena: std.mem.Allocator, line: []const u8) error{ BadMonitorResponse, OutOfMemory }!Response {
    const response = decodeTagged(Response, arena, line) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadMessage => return error.BadMonitorResponse,
    };
    switch (response) {
        .disk_fork_prepared => |prepared| runtime_disk_fork_control.validatePrepared(prepared) catch return error.BadMonitorResponse,
        else => {},
    }
    return response;
}

/// Encodes a request or response as one JSON line, without the newline.
pub fn encode(allocator: std.mem.Allocator, message: anytype) error{OutOfMemory}![]u8 {
    return switch (message) {
        inline else => |value| std.json.Stringify.valueAlloc(allocator, value, .{}),
    };
}

/// A message's `type`: its `wire_type` when it declares one, so its other
/// fields need no defaults, else the default of its `type` field.
fn wireType(comptime T: type) []const u8 {
    if (@hasDecl(T, "wire_type")) return T.wire_type;
    return comptime std.meta.fieldInfo(T, .type).defaultValue().?;
}

/// Reads the `type` field, then decodes the variant it names with unknown
/// fields rejected.
fn decodeTagged(comptime U: type, arena: std.mem.Allocator, line: []const u8) error{ BadMessage, OutOfMemory }!U {
    const Probe = struct { type: []const u8 };
    const probe = std.json.parseFromSliceLeaky(Probe, arena, line, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadMessage,
    };
    inline for (@typeInfo(U).@"union".fields) |field| {
        if (std.mem.eql(u8, probe.type, wireType(field.type))) {
            const value = std.json.parseFromSliceLeaky(field.type, arena, line, .{ .allocate = .alloc_always }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.BadMessage,
            };
            return @unionInit(U, field.name, value);
        }
    }
    return error.BadMessage;
}

/// Sends `request` once the monitor's hello matches this build, and returns
/// the response decoded into `arena`.
pub fn call(arena: std.mem.Allocator, io: Io, socket_path: []const u8, request: Request) !Response {
    std.debug.assert(!request.streams());
    try hello(arena, io, socket_path, null);
    const line = try exchange(arena, io, socket_path, try encode(arena, request), null);
    return decodeResponse(arena, line);
}

/// Asks the monitor to stop, without a hello: an old monitor must stop too.
pub fn shutdown(allocator: std.mem.Allocator, io: Io, socket_path: []const u8) !void {
    const response = try exchange(allocator, io, socket_path, "{\"type\":\"shutdown\"}", reply_deadline_ms);
    allocator.free(response);
}

/// Opens an exec or copy stream once the monitor's hello matches this
/// build. The monitor answers with SPIO frames.
pub fn openStream(allocator: std.mem.Allocator, io: Io, socket_path: []const u8, request: Request) !ExecNamedStream {
    std.debug.assert(request.streams());
    const json = try encode(allocator, request);
    defer allocator.free(json);
    try hello(allocator, io, socket_path, null);
    const address = try vm_registry.controlSocketAddress(socket_path);
    const stream = address.connect(io) catch return error.MonitorUnavailable;
    errdefer stream.close(io);
    writeAll(io, stream, json) catch return error.MonitorUnavailable;
    writeAll(io, stream, "\n") catch return error.MonitorUnavailable;
    return .{ .io = io, .stream = stream };
}

/// Fails with `error.MonitorVersionMismatch` unless the monitor reports
/// this build's version and helper contract.
pub fn hello(allocator: std.mem.Allocator, io: Io, socket_path: []const u8, spore_executable_path: ?[]const u8) !void {
    const response = try exchange(allocator, io, socket_path, "{\"type\":\"hello\"}", reply_deadline_ms);
    defer allocator.free(response);
    try validateHello(allocator, response, spore_executable_path);
}

const LenientHello = struct {
    type: []const u8,
    schema: ?[]const u8 = null,
    spore_version: ?[]const u8 = null,
    helper_contract: ?u32 = null,
};

fn validateHello(allocator: std.mem.Allocator, response: []const u8, spore_executable_path: ?[]const u8) !void {
    var parsed = std.json.parseFromSlice(LenientHello, allocator, response, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.BadMonitorResponse;
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.type, "hello")) return helloMismatch(parsed.value, spore_executable_path);
    if (!std.mem.eql(u8, parsed.value.schema orelse "", hello_schema)) return helloMismatch(parsed.value, spore_executable_path);
    if (!std.mem.eql(u8, parsed.value.spore_version orelse "", version.value)) return helloMismatch(parsed.value, spore_executable_path);
    if ((parsed.value.helper_contract orelse 0) != helper_contract) return helloMismatch(parsed.value, spore_executable_path);
}

fn helloMismatch(reply: LenientHello, spore_executable_path: ?[]const u8) error{MonitorVersionMismatch} {
    const reported = reply.spore_version orelse "unknown";
    if (spore_executable_path) |path| {
        vm_registry.setLastError("spore {s} cannot use spore executable {s} at {s}", .{ version.value, reported, path });
    } else {
        vm_registry.setLastError("spore {s} cannot use monitor helper reporting version {s}", .{ version.value, reported });
    }
    return error.MonitorVersionMismatch;
}

/// Sends one request line and reads one response line. With a deadline, a
/// monitor that has not taken the request and answered in time is treated
/// as unavailable.
fn exchange(allocator: std.mem.Allocator, io: Io, socket_path: []const u8, json: []const u8, deadline_ms: ?u64) ![]const u8 {
    // Callers commonly use arenas that cannot reclaim scratch beneath the response.
    const read_buffer = try std.heap.page_allocator.alloc(u8, max_response_bytes);
    defer std.heap.page_allocator.free(read_buffer);
    if (deadline_ms) |ms| {
        // Connecting shares the deadline: an unbounded connect waits as long
        // as the monitor's listen backlog stays full.
        const deadline = lifecycle.monotonicMs() +| ms;
        const fd = try connectBefore(socket_path, deadline);
        defer _ = std.c.close(fd);
        try setSendDeadline(fd, deadline);
        try writeLine(fd, json);
        return allocator.dupe(u8, try readLine(fd, read_buffer, deadline -| lifecycle.monotonicMs()));
    }
    const address = try vm_registry.controlSocketAddress(socket_path);
    const stream = address.connect(io) catch return error.MonitorUnavailable;
    defer stream.close(io);
    writeAll(io, stream, json) catch return error.MonitorUnavailable;
    writeAll(io, stream, "\n") catch return error.MonitorUnavailable;

    const line = try readLine(stream.socket.handle, read_buffer, null);
    return allocator.dupe(u8, line);
}

/// Connect to a control socket by `deadline`. While the monitor's listen
/// backlog is full (its accept thread is waiting out a slow client and
/// others queue behind it), Linux makes a blocking AF_UNIX connect wait for
/// room for up to the send timeout, then fail with EAGAIN. macOS refuses a
/// full backlog at once with ECONNREFUSED, which is not retried: it also
/// means a dead monitor's socket, and `spore vm rm` should not wait on that.
fn connectBefore(socket_path: []const u8, deadline: u64) !std.c.fd_t {
    try vm_registry.validateControlSocketPath(socket_path);
    var address = std.mem.zeroes(std.c.sockaddr.un);
    address.family = std.c.AF.UNIX;
    if (@hasField(std.c.sockaddr.un, "len")) address.len = @sizeOf(std.c.sockaddr.un);
    if (socket_path.len >= address.path.len) return error.NameTooLong;
    @memcpy(address.path[0..socket_path.len], socket_path);
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.MonitorUnavailable;
    errdefer _ = std.c.close(fd);
    _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    while (true) {
        try setSendDeadline(fd, deadline);
        const rc = std.c.connect(fd, @ptrCast(&address), @sizeOf(std.c.sockaddr.un));
        if (rc == 0) return fd;
        if (std.c.errno(rc) != .INTR) return error.MonitorUnavailable;
    }
}

/// Bounds blocking connects and writes on `fd` by `deadline`.
fn setSendDeadline(fd: std.c.fd_t, deadline: u64) !void {
    const now = lifecycle.monotonicMs();
    if (now >= deadline) return error.MonitorUnavailable;
    const ms = deadline - now;
    const timeout = std.c.timeval{ .sec = @intCast(ms / 1000), .usec = @intCast((ms % 1000) * std.time.us_per_ms) };
    if (std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.SNDTIMEO, &timeout, @sizeOf(std.c.timeval)) != 0) return error.MonitorUnavailable;
}

/// Write `json` and a newline to the control socket `fd`, whose send
/// timeout bounds a write the monitor does not take. A monitor that closed
/// its socket fails the write instead of raising SIGPIPE.
fn writeLine(fd: std.c.fd_t, json: []const u8) !void {
    for ([_][]const u8{ json, "\n" }) |part| {
        var remaining = part;
        while (remaining.len != 0) {
            const n = std.c.send(fd, remaining.ptr, remaining.len, std.c.MSG.NOSIGNAL);
            if (n >= 0) {
                remaining = remaining[@intCast(n)..];
            } else if (std.c.errno(n) != .INTR) {
                return error.MonitorUnavailable;
            }
        }
    }
}

fn readLine(fd: std.c.fd_t, buffer: []u8, deadline_ms: ?u64) ![]const u8 {
    const deadline = if (deadline_ms) |ms| lifecycle.monotonicMs() +| ms else null;
    var len: usize = 0;
    while (len < buffer.len) {
        const wait_ms: i32 = if (deadline) |end| blk: {
            const now = lifecycle.monotonicMs();
            if (now >= end) return error.MonitorUnavailable;
            break :blk @intCast(@min(end - now, std.math.maxInt(i32)));
        } else -1;
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, wait_ms) == 0) return error.MonitorUnavailable;
        const n = std.c.read(fd, buffer[len..].ptr, buffer.len - len);
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            return error.MonitorUnavailable;
        }
        if (n == 0) return error.MonitorUnavailable;
        const end = len + @as(usize, @intCast(n));
        if (std.mem.indexOfScalar(u8, buffer[len..end], '\n')) |index| return buffer[0 .. len + index];
        len = end;
    }
    return error.MonitorUnavailable;
}

pub const ExecNamedStreamEvent = union(enum) {
    stdout: []const u8,
    stderr: []const u8,
    terminal: []const u8,
    exit: u8,
    err: []const u8,
};

pub const ExecNamedStream = struct {
    io: Io,
    stream: net.Stream,
    closed: bool = false,
    stdin_offset: u64 = 0,
    terminal_input_offset: u64 = 0,
    stdout_offset: u64 = 0,
    stderr_offset: u64 = 0,
    terminal_offset: u64 = 0,
    payload: [spore_stream.max_payload_len]u8 = undefined,

    pub fn deinit(self: *ExecNamedStream) void {
        if (self.closed) return;
        self.stream.close(self.io);
        self.closed = true;
    }

    /// Return the next output, terminal, exit, or monitor-error frame.
    ///
    /// Byte slices are borrowed from the stream and valid until the next call.
    pub fn next(self: *ExecNamedStream) !ExecNamedStreamEvent {
        var header_buf: [spore_stream.header_len]u8 = undefined;
        readFdExact(self.stream.socket.handle, &header_buf) catch return error.StreamInterrupted;
        const header = try spore_stream.readHeader(&header_buf);
        if (header.flags != 0 or header.payload_len > self.payload.len) return error.BadMonitorResponse;
        const payload = self.payload[0..header.payload_len];
        if (payload.len > 0) readFdExact(self.stream.socket.handle, payload) catch return error.StreamInterrupted;
        switch (header.frame_type) {
            .data => {
                const expected = switch (header.stream_id) {
                    .stdout => self.stdout_offset,
                    .stderr => self.stderr_offset,
                    .terminal => self.terminal_offset,
                    else => return error.BadMonitorResponse,
                };
                if (header.offset != expected) return error.BadMonitorResponse;
                const len: u64 = @intCast(payload.len);
                switch (header.stream_id) {
                    .stdout => {
                        self.stdout_offset += len;
                        return .{ .stdout = payload };
                    },
                    .stderr => {
                        self.stderr_offset += len;
                        return .{ .stderr = payload };
                    },
                    .terminal => {
                        self.terminal_offset += len;
                        return .{ .terminal = payload };
                    },
                    else => unreachable,
                }
            },
            .exit => {
                if (header.stream_id != .control or header.offset != 0) return error.BadMonitorResponse;
                const code = try spore_stream.readExitPayload(payload);
                if (code > 255) return error.BadMonitorResponse;
                return .{ .exit = @intCast(code) };
            },
            .err => {
                if (header.stream_id != .control) return error.BadMonitorResponse;
                return .{ .err = payload };
            },
            else => return error.BadMonitorResponse,
        }
    }

    pub fn writeStdin(self: *ExecNamedStream, bytes: []const u8) !void {
        try self.writeInputData(.stdin, bytes);
    }

    pub fn writeTerminal(self: *ExecNamedStream, bytes: []const u8) !void {
        try self.writeInputData(.terminal, bytes);
    }

    pub fn closeStdin(self: *ExecNamedStream) !void {
        try self.writeInputFrame(.close, .stdin, "");
    }

    pub fn closeTerminal(self: *ExecNamedStream) !void {
        try self.writeInputFrame(.close, .terminal, "");
    }

    pub fn resizeTerminal(self: *ExecNamedStream, size: spore_stream.Resize) !void {
        var payload: [4]u8 = undefined;
        spore_stream.writeResizePayload(&payload, size);
        try self.writeInputFrame(.resize, .terminal, &payload);
    }

    fn writeInputData(self: *ExecNamedStream, stream_id: spore_stream.StreamId, bytes: []const u8) !void {
        var remaining = bytes;
        while (remaining.len > 0) {
            const take = @min(remaining.len, spore_stream.max_payload_len);
            try self.writeInputFrame(.data, stream_id, remaining[0..take]);
            remaining = remaining[take..];
        }
    }

    fn writeInputFrame(self: *ExecNamedStream, frame_type: spore_stream.FrameType, stream_id: spore_stream.StreamId, payload: []const u8) !void {
        const offset = switch (stream_id) {
            .stdin => self.stdin_offset,
            .terminal => self.terminal_input_offset,
            else => 0,
        };
        var frame_buf: [spore_stream.max_frame_len]u8 = undefined;
        const frame = try spore_stream.writeFrame(&frame_buf, .{
            .frame_type = frame_type,
            .stream_id = stream_id,
            .offset = if (frame_type == .resize) 0 else offset,
        }, payload);
        try writeFdAll(self.stream.socket.handle, frame);
        if (frame_type == .data) {
            const len: u64 = @intCast(payload.len);
            switch (stream_id) {
                .stdin => self.stdin_offset += len,
                .terminal => self.terminal_input_offset += len,
                else => {},
            }
        }
    }
};

fn writeAll(io: Io, stream: net.Stream, bytes: []const u8) !void {
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn readFdExact(fd: std.c.fd_t, buf: []u8) !void {
    var remaining = buf;
    while (remaining.len > 0) {
        const n = std.c.read(fd, remaining.ptr, remaining.len);
        if (n < 0) {
            switch (std.c.errno(n)) {
                .INTR => continue,
                else => return error.MonitorUnavailable,
            }
        }
        if (n == 0) return error.MonitorUnavailable;
        remaining = remaining[@intCast(n)..];
    }
}

fn writeFdAll(fd: std.c.fd_t, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(fd, remaining.ptr, remaining.len);
        if (n < 0) {
            switch (std.c.errno(n)) {
                .INTR => continue,
                else => return error.MonitorUnavailable,
            }
        }
        if (n == 0) return error.MonitorUnavailable;
        remaining = remaining[@intCast(n)..];
    }
}

const test_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const test_token = "abababababababababababababababababababababababababababababababab";

/// One instance of every request, as the seed corpus for decoding.
const test_requests = [_]Request{
    .{ .hello = .{} },
    .{ .shutdown = .{} },
    .{ .start = .{ .argv = &.{ "/bin/sh", "-c", "echo hi" }, .env = &.{"A=1"}, .working_dir = "/srv", .retain_output = true } },
    .{ .initial_output = .{} },
    .{ .exec_stream = .{ .argv = &.{"/bin/true"}, .stdio = .tty, .terminal_rows = 40, .terminal_cols = 120 } },
    .{ .copy_in = .{ .path = "/srv/in" } },
    .{ .copy_out = .{ .path = "/srv/out" } },
    .{ .@"suspend" = .{ .out_dir = "/tmp/save.spore" } },
    .{ .snapshot = .{ .out_dir = "/tmp/save.tmp", .publish_dir = "/tmp/save.spore" } },
    .{ .disk_fork_prepare = .{
        .type = runtime_disk_fork_control.prepare_type,
        .schema = runtime_disk_fork_control.prepare_schema,
        .out_dir = "/tmp/capture",
        .batch = "batch-1",
        .children = &.{ "child-0", "child-1" },
        .allow_copy = true,
    } },
    .{ .disk_fork_cancel = .{
        .type = runtime_disk_fork_control.cancel_type,
        .schema = runtime_disk_fork_control.cancel_schema,
        .batch = "batch-1",
    } },
    .{ .disk_claim = .{
        .type = runtime_disk_claim.claim_type,
        .schema = runtime_disk_claim.claim_schema,
        .token = test_token,
        .batch = "batch-1",
        .child = "child-0",
        .child_index = 0,
        .baseline_kind = .rootfs,
        .baseline_identity = test_digest,
    } },
};

test "every request round-trips through the wire format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (test_requests) |request| {
        const line = try encode(allocator, request);
        const decoded = try decodeRequest(allocator, line);
        try std.testing.expectEqual(std.meta.activeTag(request), std.meta.activeTag(decoded));
        try std.testing.expectEqualStrings(line, try encode(allocator, decoded));
    }
}

test "requests are a closed set of strict messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // Optional fields take their defaults.
    const start = (try decodeRequest(allocator, "{\"type\":\"start\",\"argv\":[\"/bin/true\"]}")).start;
    try std.testing.expectEqual(0, start.env.len);
    try std.testing.expect(!start.retain_output);
    const snapshot = (try decodeRequest(allocator, "{\"type\":\"snapshot\",\"out_dir\":\"/tmp/a\"}")).snapshot;
    try std.testing.expectEqual(null, snapshot.publish_dir);

    for ([_][]const u8{
        // Unknown and duplicate fields, including the retired `continue`.
        "{\"type\":\"start\",\"argv\":[\"/bin/true\"],\"argz\":1}",
        "{\"type\":\"snapshot\",\"out_dir\":\"/tmp/a\",\"continue\":true}",
        "{\"type\":\"hello\",\"type\":\"shutdown\"}",
        "{\"type\":\"suspend\",\"out_dir\":\"/a\",\"out_dir\":\"/b\"}",
        // Unknown types and values, and missing fields.
        "{\"type\":\"reboot\"}",
        "{\"type\":\"exec-stream-v1\",\"argv\":[\"/bin/true\"],\"stdio\":\"file\"}",
        "{\"type\":\"exec-stream-v1\",\"argv\":[\"/bin/true\"]}",
        "{\"type\":\"copy-in-v1\"}",
        "{\"argv\":[\"/bin/true\"]}",
        "[\"hello\"]",
        "",
        // Disk-fork messages are validated as well as decoded.
        "{\"type\":\"disk-fork-prepare\",\"schema\":\"spore.disk-fork-prepare.v1\",\"out_dir\":\"/tmp/capture\",\"batch\":\"batch-1\",\"children\":[\"child-0\"],\"extra\":true}",
        "{\"type\":\"disk-fork-prepare\",\"schema\":\"spore.disk-fork-prepare.v2\",\"out_dir\":\"/tmp/capture\",\"batch\":\"batch-1\",\"children\":[\"child-0\"]}",
        "{\"type\":\"disk-fork-prepare\",\"schema\":\"spore.disk-fork-prepare.v1\",\"out_dir\":\"/tmp/capture\",\"batch\":\"batch-1\",\"children\":[]}",
        "{\"type\":\"disk-fork-cancel\",\"schema\":\"spore.disk-fork-cancel.v1\",\"batch\":\"../x\"}",
        "{\"type\":\"disk-fork-cancel\",\"batch\":\"batch-1\"}",
    }) |line| {
        try std.testing.expectError(error.BadControlRequest, decodeRequest(allocator, line));
    }
}

test "prepared disk forks must name one baseline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const prepared_format = "{{\"type\":\"disk-fork-prepared\",\"schema\":\"spore.disk-fork-prepared.v1\",\"batch\":\"batch-1\",\"capture_dir\":\"/tmp/capture\",\"claims\":[{{\"child\":\"child-0\",\"child_index\":0,\"token\":\"{s}\",\"baseline_kind\":\"rootfs\",\"baseline_identity\":\"{s}\"}}],\"lease\":{{\"store\":\"rootfs_cache\",\"root\":\"/cache\",\"baseline_kind\":\"rootfs\",\"baseline_identity\":\"{s}\"}},\"disk\":null,\"ram_capture_ns\":1,\"disk_fork_ns\":2,\"source_pause_ns\":3,\"copied_bytes\":0}}";
    const prepared = (try decodeResponse(allocator, try std.fmt.allocPrint(allocator, prepared_format, .{ test_token, test_digest, test_digest }))).disk_fork_prepared;
    try std.testing.expectEqualStrings("child-0", prepared.claims[0].child);
    try std.testing.expectEqualStrings(test_digest, prepared.lease.baseline_identity);

    // Every claim must be for the baseline the lease names.
    const other = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    try std.testing.expectError(error.BadMonitorResponse, decodeResponse(allocator, try std.fmt.allocPrint(allocator, prepared_format, .{ test_token, test_digest, other })));
}

test "responses decode strictly and carry typed error codes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const failure = (try decodeResponse(allocator, "{\"type\":\"error\",\"message\":\"disk fork capture failed: FastForkUnavailable\",\"code\":\"fast_fork_unavailable\"}")).err;
    try std.testing.expectEqual(ErrorCode.fast_fork_unavailable, failure.code.?);
    try std.testing.expectEqual(null, (try decodeResponse(allocator, "{\"type\":\"error\",\"message\":\"monitor busy\"}")).err.code);
    try std.testing.expectEqualStrings("/tmp/a", (try decodeResponse(allocator, "{\"type\":\"snapshotted\",\"out_dir\":\"/tmp/a\"}")).snapshotted.out_dir);
    for ([_][]const u8{
        "{\"type\":\"error\",\"message\":\"x\",\"code\":\"not_a_code\"}",
        "{\"type\":\"snapshotted\",\"out_dir\":\"/tmp/a\",\"extra\":1}",
        "{\"type\":\"exec_result\",\"exit_code\":0,\"stdout_b64\":\"\",\"stderr_b64\":\"\",\"stdout_truncated\":false}",
        "{\"type\":\"hello\"}",
    }) |line| {
        try std.testing.expectError(error.BadMonitorResponse, decodeResponse(allocator, line));
    }
    try std.testing.expectEqual(ErrorCode.disk_fork_baseline_unavailable, ErrorCode.of(error.DiskForkBaselineUnavailable).?);
    try std.testing.expectEqual(null, ErrorCode.of(error.ControlBusy));
}

test "monitor hello response validates helper version" {
    const allocator = std.testing.allocator;
    const ok = try std.json.Stringify.valueAlloc(allocator, HelloReply{}, .{});
    defer allocator.free(ok);
    try validateHello(allocator, ok, null);

    try std.testing.expectError(error.MonitorVersionMismatch, validateHello(allocator,
        \\{"type":"error","message":"unknown control request"}
    , null));
    try std.testing.expectError(error.MonitorVersionMismatch, validateHello(allocator,
        \\{"type":"hello","schema":"spore.monitor.hello.v1","spore_version":"1.3.0","helper_contract":1}
    , null));
    try std.testing.expectError(error.MonitorVersionMismatch, validateHello(allocator,
        \\{"type":"hello","schema":"spore.monitor.hello.v1","spore_version":"1.5.0","helper_contract":2,"features":[]}
    , null));
}

/// Decodes `bytes`; whatever decodes must encode to a line that decodes and
/// encodes to the same bytes.
fn checkRequestRoundTrip(bytes: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const request = decodeRequest(allocator, bytes) catch return;
    const line = try encode(allocator, request);
    const again = try decodeRequest(allocator, line);
    try std.testing.expectEqualStrings(line, try encode(allocator, again));
}

fn fuzzMonitorRequest(_: void, smith: *std.testing.Smith) anyerror!void {
    var bytes: [max_request_bytes]u8 = undefined;
    // Raw input, then a mutated and truncated encoding of a valid request.
    try checkRequestRoundTrip(bytes[0..smith.slice(&bytes)]);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const seed = try encode(arena.allocator(), test_requests[smith.index(test_requests.len)]);
    @memcpy(bytes[0..seed.len], seed);
    for (0..smith.valueRangeAtMost(u8, 0, 4)) |_| {
        bytes[smith.index(seed.len)] = smith.value(u8);
    }
    try checkRequestRoundTrip(bytes[0..smith.index(seed.len + 1)]);
}

test "fuzz monitor request decoding" {
    // Zig 0.16 cannot build `--fuzz`, so this runs the seed corpus.
    for (test_requests) |request| {
        const line = try encode(std.testing.allocator, request);
        defer std.testing.allocator.free(line);
        try checkRequestRoundTrip(line);
        for (0..line.len) |len| try checkRequestRoundTrip(line[0..len]);
    }
    try std.testing.fuzz({}, fuzzMonitorRequest, .{});
}

/// Answers `request_count` requests with `response`.
const LineServer = struct {
    io: Io,
    server: net.Server,
    response: []const u8,
    request_count: usize = 1,

    fn run(fake: *LineServer) void {
        for (0..fake.request_count) |_| fake.once() catch return;
    }

    fn once(fake: *LineServer) !void {
        var stream = fake.server.accept(fake.io) catch return;
        defer stream.close(fake.io);

        var read_buffer: [256]u8 = undefined;
        var reader = stream.reader(fake.io, &read_buffer);
        _ = try reader.interface.takeDelimiterExclusive('\n');
        try writeAll(fake.io, stream, fake.response);
        try writeAll(fake.io, stream, "\n");
    }
};

test "a control request with a deadline gives up when the monitor's backlog is full" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const socket_path = try std.fmt.allocPrint(allocator, "/tmp/sporevm-control-busy-{d}.sock", .{std.c.getpid()});
    defer allocator.free(socket_path);
    Io.Dir.cwd().deleteFile(io, socket_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, socket_path) catch {};
    // A listener that never accepts stands in for a monitor whose accept
    // thread is stuck; clients queued behind it fill the backlog, and a
    // blocking connect would then wait for an accept that never comes.
    const address = try net.UnixAddress.init(socket_path);
    var server = try address.listen(io, .{ .kernel_backlog = 1 });
    defer server.deinit(io);
    var queued: [64]std.c.fd_t = undefined;
    var count: usize = 0;
    defer for (queued[0..count]) |fd| {
        _ = std.c.close(fd);
    };
    while (count < queued.len) : (count += 1) {
        queued[count] = connectBefore(socket_path, lifecycle.monotonicMs() + 100) catch break;
    }
    try std.testing.expect(count < queued.len);

    const start = lifecycle.monotonicMs();
    try std.testing.expectError(error.MonitorUnavailable, exchange(allocator, io, socket_path, "{\"type\":\"shutdown\"}", 100));
    try std.testing.expect(lifecycle.monotonicMs() - start < 2_000);
}

test "a control request to a monitor that closed its socket fails instead of raising SIGPIPE" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const socket_path = try std.fmt.allocPrint(allocator, "/tmp/sporevm-control-closed-{d}.sock", .{std.c.getpid()});
    defer allocator.free(socket_path);
    Io.Dir.cwd().deleteFile(io, socket_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, socket_path) catch {};
    // A client queued on the monitor's socket, which the monitor then closes
    // as it exits, so the connection is reset before the request is written.
    const address = try net.UnixAddress.init(socket_path);
    var server = try address.listen(io, .{});
    const fd = connectBefore(socket_path, lifecycle.monotonicMs() + 1_000) catch |err| {
        server.deinit(io);
        return err;
    };
    defer _ = std.c.close(fd);
    server.deinit(io);
    // The test runtime catches SIGPIPE and the spore CLI does not, so restore
    // the default: a write that raises it ends the test process.
    var old_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(.PIPE, &.{ .handler = .{ .handler = std.c.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 }, &old_action);
    defer std.posix.sigaction(.PIPE, &old_action, null);
    try std.testing.expectError(error.MonitorUnavailable, writeLine(fd, "{\"type\":\"shutdown\"}"));
}

test "a control request with a deadline waits for the monitor's backlog to drain" {
    // macOS refuses a connect to a full backlog at once instead of waiting.
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const socket_path = try std.fmt.allocPrint(allocator, "/tmp/sporevm-control-drain-{d}.sock", .{std.c.getpid()});
    defer allocator.free(socket_path);
    Io.Dir.cwd().deleteFile(io, socket_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, socket_path) catch {};
    const address = try net.UnixAddress.init(socket_path);
    var server = try address.listen(io, .{ .kernel_backlog = 1 });
    defer server.deinit(io);
    var queued: [64]std.c.fd_t = undefined;
    var count: usize = 0;
    defer for (queued[0..count]) |fd| {
        _ = std.c.close(fd);
    };
    while (count < queued.len) : (count += 1) {
        queued[count] = connectBefore(socket_path, lifecycle.monotonicMs() + 100) catch break;
    }
    try std.testing.expect(count < queued.len);

    // The monitor's accept thread comes back partway through the deadline,
    // takes the queued clients, then answers the request.
    const Monitor = struct {
        fn run(listener: std.c.fd_t, backlog: usize) void {
            var ts = std.c.timespec{ .sec = 0, .nsec = 300 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
            for (0..backlog) |_| _ = std.c.close(std.c.accept(listener, null, null));
            // Bounded, so a request that gave up fails the test instead of
            // hanging it.
            var fds = [_]std.posix.pollfd{.{ .fd = listener, .events = std.c.POLL.IN, .revents = 0 }};
            if ((std.posix.poll(&fds, 3_000) catch 0) == 0) return;
            const client = std.c.accept(listener, null, null);
            if (client < 0) return;
            defer _ = std.c.close(client);
            var buf: [64]u8 = undefined;
            _ = std.c.read(client, &buf, buf.len);
            const reply = "{\"type\":\"ok\"}\n";
            _ = std.c.write(client, reply, reply.len);
        }
    };
    const monitor = try std.Thread.spawn(.{}, Monitor.run, .{ server.socket.handle, count });
    defer monitor.join();
    const start = lifecycle.monotonicMs();
    const response = try exchange(allocator, io, socket_path, "{\"type\":\"hello\"}", 2_000);
    defer allocator.free(response);
    try std.testing.expectEqualStrings("{\"type\":\"ok\"}", response);
    try std.testing.expect(lifecycle.monotonicMs() - start >= 250);
}
const small_stack_control_requests = 16;
// The exact Linux ARM64 test binary needs 272 KiB after TLS and guard overhead.
// Keep functional coverage comfortably above that runtime-specific floor; the
// ReleaseSafe frame budget is verified separately from this thread size.
const small_stack_control_bytes = 512 * 1024;

const SmallStackControlClient = struct {
    io: Io,
    socket_path: []const u8,
    response_matches: bool = false,
    err: ?anyerror = null,

    fn run(client: *SmallStackControlClient) void {
        var caller_storage: [64]u8 = undefined;
        var caller_allocator = std.heap.FixedBufferAllocator.init(&caller_storage);
        for (0..small_stack_control_requests) |_| {
            const response = exchange(
                caller_allocator.allocator(),
                client.io,
                client.socket_path,
                "{\"type\":\"hello\"}",
                null,
            ) catch |err| {
                client.err = err;
                return;
            };
            const response_matches = std.mem.eql(u8, "{\"type\":\"hello\"}", response);
            caller_allocator.allocator().free(response);
            if (!response_matches) return;
        }
        client.response_matches = true;
    }
};

test "control response scratch fits a bounded stack and caller allocator" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const socket_path = try std.fmt.allocPrint(allocator, "/tmp/sporevm-control-small-stack-{d}.sock", .{std.c.getpid()});
    defer allocator.free(socket_path);
    defer Io.Dir.cwd().deleteFile(io, socket_path) catch {};
    Io.Dir.cwd().deleteFile(io, socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };

    const address = try net.UnixAddress.init(socket_path);
    var fake = LineServer{
        .io = io,
        .server = try address.listen(io, .{ .kernel_backlog = 1 }),
        .response = "{\"type\":\"hello\"}",
        .request_count = small_stack_control_requests,
    };
    defer fake.server.deinit(io);

    var client = SmallStackControlClient{ .io = io, .socket_path = socket_path };
    const client_thread = try std.Thread.spawn(.{ .stack_size = small_stack_control_bytes }, SmallStackControlClient.run, .{&client});
    LineServer.run(&fake);
    client_thread.join();

    if (client.err) |err| return err;
    try std.testing.expect(client.response_matches);
}

const SilentMonitor = struct {
    io: Io,
    server: net.Server,

    /// Reads one request and never answers; it closes once the client
    /// hangs up, or after two seconds.
    fn run(silent: *SilentMonitor) void {
        var stream = silent.server.accept(silent.io) catch return;
        defer stream.close(silent.io);
        var read_buffer: [256]u8 = undefined;
        var reader = stream.reader(silent.io, &read_buffer);
        _ = reader.interface.takeDelimiterExclusive('\n') catch return;
        var fds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.c.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&fds, 2_000) catch {};
    }
};

test "control requests with a deadline give up on a silent monitor" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const socket_path = try std.fmt.allocPrint(allocator, "/tmp/sporevm-control-silent-{d}.sock", .{std.c.getpid()});
    defer allocator.free(socket_path);
    defer Io.Dir.cwd().deleteFile(io, socket_path) catch {};
    Io.Dir.cwd().deleteFile(io, socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };

    const address = try net.UnixAddress.init(socket_path);
    var silent = SilentMonitor{ .io = io, .server = try address.listen(io, .{ .kernel_backlog = 1 }) };
    defer silent.server.deinit(io);
    const thread = try std.Thread.spawn(.{}, SilentMonitor.run, .{&silent});
    defer thread.join();

    const start = lifecycle.monotonicMs();
    try std.testing.expectError(error.MonitorUnavailable, exchange(allocator, io, socket_path, "{\"type\":\"shutdown\"}", 100));
    try std.testing.expect(lifecycle.monotonicMs() - start < 1_000);
}
