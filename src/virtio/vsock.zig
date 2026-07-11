//! Virtio socket device (virtio spec 1.2 §5.10).
//!
//! Queue 0 is receive, queue 1 is transmit, queue 2 is event. This first
//! product slice keeps the endpoint deliberately small: the default behavior
//! still rejects guest-initiated host connections, while benchmark harnesses can
//! attach one host-initiated stream to a guest listener.
//! Packet headers, queue descriptors, payload lengths, and rings are guest
//! controlled. See SECURITY.md.

const std = @import("std");
const guestmem = @import("../guestmem.zig");
const runtime_disk_fork_capture = @import("../runtime_disk_fork_capture.zig");
const queue = @import("queue.zig");
const mmio = @import("mmio.zig");
const spore = @import("../spore.zig");
const spore_stream = @import("../spore_stream.zig");

pub const device_id: u32 = 19;

pub const host_cid: u64 = 2;
pub const default_guest_cid: u64 = 3;

const rx_queue = 0;
const tx_queue = 1;
const event_queue = 2;

pub const header_len = 44;

const packet_type_stream: u16 = 1;

const op_request: u16 = 1;
const op_response: u16 = 2;
const op_rst: u16 = 3;
const op_shutdown: u16 = 4;
const op_rw: u16 = 5;
const op_credit_update: u16 = 6;
const op_credit_request: u16 = 7;

const max_pending = 16;
const max_payload = 8192;
const host_stream_credit = 64 * 1024;
const max_frame_header = 128;
const max_frame_payload = 64 * 1024;
const default_host_port: u32 = 49152;
const dynamic_host_port_first: u32 = 49154;
const dynamic_host_port_count: u32 = 65535 - dynamic_host_port_first + 1;
const max_outbound_frames = 16;
const max_v1_control_payload = 512;

pub const Header = struct {
    src_cid: u64,
    dst_cid: u64,
    src_port: u32,
    dst_port: u32,
    len: u32,
    packet_type: u16,
    op: u16,
    flags: u32 = 0,
    buf_alloc: u32 = 0,
    fwd_cnt: u32 = 0,
};

pub const Config = struct {
    guest_cid: u64 = default_guest_cid,
};

const Packet = struct {
    header: Header,
    data: [max_payload]u8 = [_]u8{0} ** max_payload,
    data_len: usize = 0,
};

const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

pub const HostStreamState = enum {
    idle,
    connecting,
    connected,
    complete,
    failed,
};

pub const HostStreamStart = enum {
    immediate,
    control,
};

pub const HostStreamOutput = enum {
    stdout,
    stderr,
    terminal,
};

pub const HostStreamOutputSink = *const fn (context: ?*anyopaque, output: HostStreamOutput, bytes: []const u8) void;

pub const HostStreamLifecycle = enum {
    ready,
};

pub const HostStreamLifecycleSink = *const fn (context: ?*anyopaque, event: HostStreamLifecycle) void;

pub const HostStreamProtocol = enum {
    legacy_text,
    spore_stream_v1,
};

const OutboundFrame = struct {
    data: [max_payload]u8 = [_]u8{0} ** max_payload,
    len: usize = 0,
};

pub const HostStream = struct {
    guest_port: u32,
    host_port: u32 = default_host_port,
    protocol: HostStreamProtocol = .legacy_text,
    request: [max_payload]u8 = [_]u8{0} ** max_payload,
    request_len: usize = 0,
    state: HostStreamState = .idle,
    started_at_ms: u64 = 0,
    start_ms: ?u64 = null,
    attach_ms: ?u64 = null,
    connect_request_delivered_ms: ?u64 = null,
    connect_ms: ?u64 = null,
    request_delivered_ms: ?u64 = null,
    memory_pressure_ms: ?u64 = null,
    memory_pressure_count: u32 = 0,
    first_output_ms: ?u64 = null,
    response_ms: ?u64 = null,
    guest_timing_ms: ?u64 = null,
    received_bytes: u32 = 0,
    sent_bytes: u32 = 0,
    credit_fwd_cnt_sent: u32 = 0,
    peer_buf_alloc: u32 = 0,
    peer_fwd_cnt: u32 = 0,
    request_sent: bool = false,
    exit_code: ?i32 = null,
    header_buf: [max_frame_header]u8 = undefined,
    header_len: usize = 0,
    payload_output: ?HostStreamOutput = null,
    payload_remaining: usize = 0,
    v1_header_buf: [spore_stream.header_len]u8 = undefined,
    v1_header_len: usize = 0,
    v1_payload_header: ?spore_stream.Header = null,
    v1_payload_remaining: usize = 0,
    v1_control_payload: [max_v1_control_payload]u8 = undefined,
    v1_control_payload_len: usize = 0,
    stdout_offset: u64 = 0,
    stderr_offset: u64 = 0,
    terminal_offset: u64 = 0,
    stdin_offset: u64 = 0,
    terminal_input_offset: u64 = 0,
    outbound_lock: SpinLock = .{},
    outbound_head: usize = 0,
    outbound_count: usize = 0,
    outbound_frames: [max_outbound_frames]OutboundFrame = undefined,
    output_sink: ?HostStreamOutputSink = null,
    output_sink_context: ?*anyopaque = null,
    lifecycle_sink: ?HostStreamLifecycleSink = null,
    lifecycle_sink_context: ?*anyopaque = null,

    pub fn init(guest_port: u32, request: []const u8) !HostStream {
        if (request.len > max_payload) return error.RequestTooLarge;
        var stream = HostStream{ .guest_port = guest_port };
        @memcpy(stream.request[0..request.len], request);
        stream.request_len = request.len;
        stream.started_at_ms = monotonicMs();
        stream.state = .connecting;
        return stream;
    }

    pub fn initWithProtocol(guest_port: u32, request: []const u8, protocol: HostStreamProtocol) !HostStream {
        var stream = try init(guest_port, request);
        stream.protocol = protocol;
        return stream;
    }

    pub fn deriveHostPort(request: []const u8) u32 {
        return dynamic_host_port_first + @as(u32, @intCast(std.hash.Wyhash.hash(0, request) % dynamic_host_port_count));
    }

    pub fn hostPortForSequence(sequence: u64) u32 {
        return dynamic_host_port_first + @as(u32, @intCast(sequence % dynamic_host_port_count));
    }

    pub fn markStarted(self: *HostStream) void {
        self.started_at_ms = monotonicMs();
        self.start_ms = self.elapsedMs();
    }

    fn markAttached(self: *HostStream) void {
        if (self.attach_ms == null) self.attach_ms = self.elapsedMs();
    }

    fn markConnectRequestDelivered(self: *HostStream) void {
        if (self.connect_request_delivered_ms == null) self.connect_request_delivered_ms = self.elapsedMs();
    }

    fn markRequestDelivered(self: *HostStream) void {
        if (self.request_delivered_ms == null) self.request_delivered_ms = self.elapsedMs();
    }

    pub fn setOutputSink(self: *HostStream, context: ?*anyopaque, sink: HostStreamOutputSink) void {
        self.output_sink_context = context;
        self.output_sink = sink;
    }

    pub fn setLifecycleSink(self: *HostStream, context: ?*anyopaque, sink: HostStreamLifecycleSink) void {
        self.lifecycle_sink_context = context;
        self.lifecycle_sink = sink;
    }

    pub fn elapsedMs(self: *const HostStream) u64 {
        const now = monotonicMs();
        if (now < self.started_at_ms) return 0;
        return now - self.started_at_ms;
    }

    fn markConnected(self: *HostStream) void {
        if (self.connect_ms == null) self.connect_ms = self.elapsedMs();
        self.state = .connected;
        if (self.lifecycle_sink) |sink| sink(self.lifecycle_sink_context, .ready);
    }

    fn appendOutput(self: *HostStream, data: []const u8) void {
        if (self.protocol == .spore_stream_v1) {
            self.appendOutputV1(data);
            return;
        }

        const inc: u32 = if (data.len > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(data.len);
        self.received_bytes +%= inc;

        var rest = data;
        while (rest.len > 0 and self.state != .failed and self.state != .complete) {
            if (self.payload_output) |output| {
                const take = @min(rest.len, self.payload_remaining);
                self.emitOutput(output, rest[0..take]);
                self.payload_remaining -= take;
                rest = rest[take..];
                if (self.payload_remaining == 0) self.payload_output = null;
                continue;
            }

            if (std.mem.indexOfScalar(u8, rest, '\n')) |newline| {
                if (self.header_len + newline > self.header_buf.len) {
                    self.fail();
                    return;
                }
                @memcpy(self.header_buf[self.header_len..][0..newline], rest[0..newline]);
                self.header_len += newline;
                const line = self.header_buf[0..self.header_len];
                self.header_len = 0;
                self.handleFrameHeader(line);
                rest = rest[newline + 1 ..];
            } else {
                if (self.header_len + rest.len > self.header_buf.len) {
                    self.fail();
                    return;
                }
                @memcpy(self.header_buf[self.header_len..][0..rest.len], rest);
                self.header_len += rest.len;
                return;
            }
        }
    }

    fn handleFrameHeader(self: *HostStream, line: []const u8) void {
        var fields = std.mem.splitScalar(u8, line, ' ');
        const kind = fields.next() orelse {
            self.fail();
            return;
        };
        if (std.mem.eql(u8, kind, "stdout") or std.mem.eql(u8, kind, "stderr")) {
            const offset_raw = fields.next() orelse {
                self.fail();
                return;
            };
            const len_raw = fields.next() orelse {
                self.fail();
                return;
            };
            if (fields.next() != null) {
                self.fail();
                return;
            }
            const offset = std.fmt.parseInt(u64, offset_raw, 10) catch {
                self.fail();
                return;
            };
            const len = std.fmt.parseInt(usize, len_raw, 10) catch {
                self.fail();
                return;
            };
            if (len > max_frame_payload) {
                self.fail();
                return;
            }
            const output: HostStreamOutput = if (std.mem.eql(u8, kind, "stdout")) .stdout else .stderr;
            const expected = switch (output) {
                .stdout => self.stdout_offset,
                .stderr => self.stderr_offset,
                .terminal => unreachable,
            };
            if (offset != expected) {
                self.fail();
                return;
            }
            self.payload_output = output;
            self.payload_remaining = len;
            if (len == 0) self.payload_output = null;
            return;
        }
        if (std.mem.eql(u8, kind, "exit")) {
            const code_raw = fields.next() orelse {
                self.fail();
                return;
            };
            if (fields.next() != null) {
                self.fail();
                return;
            }
            const code = std.fmt.parseInt(i32, code_raw, 10) catch {
                self.fail();
                return;
            };
            if (code < 0 or code > 255) {
                self.fail();
                return;
            }
            self.exit_code = code;
            if (self.response_ms == null) self.response_ms = self.elapsedMs();
            self.state = .complete;
            return;
        }
        if (std.mem.eql(u8, kind, "timing")) {
            if (self.guest_timing_ms == null) self.guest_timing_ms = self.elapsedMs();
            std.log.debug("vsock host stream guest timing: {s}", .{line});
            return;
        }
        if (std.mem.eql(u8, kind, "memory-pressure")) {
            if (self.memory_pressure_ms == null) self.memory_pressure_ms = self.elapsedMs();
            self.memory_pressure_count +|= 1;
            return;
        }
        self.fail();
    }

    fn appendOutputV1(self: *HostStream, data: []const u8) void {
        const inc: u32 = if (data.len > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(data.len);
        self.received_bytes +%= inc;

        var rest = data;
        while (rest.len > 0 and self.state != .failed and self.state != .complete) {
            if (self.v1_payload_header) |header| {
                const take = @min(rest.len, self.v1_payload_remaining);
                self.handleV1PayloadBytes(header, rest[0..take]);
                self.v1_payload_remaining -= take;
                rest = rest[take..];
                if (self.v1_payload_remaining == 0) {
                    self.finishV1Frame(header);
                    self.v1_payload_header = null;
                    self.v1_control_payload_len = 0;
                }
                continue;
            }

            const need = spore_stream.header_len - self.v1_header_len;
            const take = @min(rest.len, need);
            @memcpy(self.v1_header_buf[self.v1_header_len..][0..take], rest[0..take]);
            self.v1_header_len += take;
            rest = rest[take..];
            if (self.v1_header_len < spore_stream.header_len) continue;

            const header = spore_stream.readHeader(&self.v1_header_buf) catch {
                self.fail();
                return;
            };
            self.v1_header_len = 0;
            if (!self.validateV1Header(header)) {
                self.fail();
                return;
            }
            self.v1_payload_header = header;
            self.v1_payload_remaining = header.payload_len;
            self.v1_control_payload_len = 0;
            if (header.payload_len == 0) {
                self.finishV1Frame(header);
                self.v1_payload_header = null;
            }
        }
    }

    fn validateV1Header(self: *HostStream, header: spore_stream.Header) bool {
        if (header.flags != 0) return false;
        switch (header.frame_type) {
            .data => {
                const expected = switch (header.stream_id) {
                    .stdout => self.stdout_offset,
                    .stderr => self.stderr_offset,
                    .terminal => self.terminal_offset,
                    else => return false,
                };
                return header.offset == expected;
            },
            .close => return header.payload_len == 0 and (header.stream_id == .stdout or header.stream_id == .stderr or header.stream_id == .terminal),
            .exit => return header.stream_id == .control and header.offset == 0 and header.payload_len == 4,
            .event => return header.stream_id == .control and header.payload_len <= max_v1_control_payload,
            .err => return header.stream_id == .control and header.payload_len <= max_v1_control_payload,
            .resize, .signal => return false,
        }
    }

    fn handleV1PayloadBytes(self: *HostStream, header: spore_stream.Header, bytes: []const u8) void {
        switch (header.frame_type) {
            .data => {
                const output: HostStreamOutput = switch (header.stream_id) {
                    .stdout => .stdout,
                    .stderr => .stderr,
                    .terminal => .terminal,
                    else => return self.fail(),
                };
                self.emitOutput(output, bytes);
            },
            .exit, .event, .err => {
                if (self.v1_control_payload_len + bytes.len > self.v1_control_payload.len) {
                    self.fail();
                    return;
                }
                @memcpy(self.v1_control_payload[self.v1_control_payload_len..][0..bytes.len], bytes);
                self.v1_control_payload_len += bytes.len;
            },
            .close, .resize, .signal => {},
        }
    }

    fn finishV1Frame(self: *HostStream, header: spore_stream.Header) void {
        switch (header.frame_type) {
            .data => {},
            .close => {},
            .exit => {
                const code = spore_stream.readExitPayload(self.v1_control_payload[0..self.v1_control_payload_len]) catch {
                    self.fail();
                    return;
                };
                if (code > 255) {
                    self.fail();
                    return;
                }
                self.exit_code = @intCast(code);
                if (self.response_ms == null) self.response_ms = self.elapsedMs();
                self.state = .complete;
            },
            .event => {
                const payload = self.v1_control_payload[0..self.v1_control_payload_len];
                if (std.mem.eql(u8, payload, "memory-pressure")) {
                    if (self.memory_pressure_ms == null) self.memory_pressure_ms = self.elapsedMs();
                    self.memory_pressure_count +|= 1;
                } else if (std.mem.startsWith(u8, payload, "timing ")) {
                    if (self.guest_timing_ms == null) self.guest_timing_ms = self.elapsedMs();
                    std.log.debug("vsock host stream guest timing: {s}", .{payload});
                } else {
                    self.fail();
                }
            },
            .err => self.fail(),
            .resize, .signal => self.fail(),
        }
    }

    fn emitOutput(self: *HostStream, output: HostStreamOutput, data: []const u8) void {
        if (data.len == 0) return;
        if (self.first_output_ms == null) self.first_output_ms = self.elapsedMs();
        if (self.output_sink) |sink| sink(self.output_sink_context, output, data);
        const len: u64 = @intCast(data.len);
        switch (output) {
            .stdout => self.stdout_offset += len,
            .stderr => self.stderr_offset += len,
            .terminal => self.terminal_offset += len,
        }
    }

    pub fn enqueueStdinDataBlocking(self: *HostStream, data: []const u8, stop: *const std.atomic.Value(bool)) !bool {
        var rest = data;
        while (rest.len > 0) {
            if (stop.load(.acquire)) return false;
            const take = @min(rest.len, spore_stream.max_payload_len);
            var frame_buf: [spore_stream.max_frame_len]u8 = undefined;
            const frame = try spore_stream.writeFrame(&frame_buf, .{
                .frame_type = .data,
                .stream_id = .stdin,
                .offset = self.stdin_offset,
            }, rest[0..take]);
            if (!try self.enqueueOutboundBlocking(frame, stop)) return false;
            self.stdin_offset += take;
            rest = rest[take..];
        }
        return true;
    }

    pub fn enqueueStdinDataNonblocking(self: *HostStream, data: []const u8) !usize {
        if (data.len == 0) return 0;
        if (self.state == .complete or self.state == .failed) return 0;
        const take = @min(data.len, spore_stream.max_payload_len);
        var frame_buf: [spore_stream.max_frame_len]u8 = undefined;
        const frame = try spore_stream.writeFrame(&frame_buf, .{
            .frame_type = .data,
            .stream_id = .stdin,
            .offset = self.stdin_offset,
        }, data[0..take]);
        self.enqueueOutbound(frame) catch |err| switch (err) {
            error.OutboundFull => return 0,
            else => |e| return e,
        };
        self.stdin_offset += take;
        return take;
    }

    pub fn enqueueStdinCloseBlocking(self: *HostStream, stop: *const std.atomic.Value(bool)) !bool {
        var frame_buf: [spore_stream.max_frame_len]u8 = undefined;
        const frame = try spore_stream.writeFrame(&frame_buf, .{
            .frame_type = .close,
            .stream_id = .stdin,
            .offset = self.stdin_offset,
        }, "");
        return self.enqueueOutboundBlocking(frame, stop);
    }

    pub fn enqueueStdinCloseNonblocking(self: *HostStream) !bool {
        if (self.state == .complete or self.state == .failed) return false;
        var frame_buf: [spore_stream.max_frame_len]u8 = undefined;
        const frame = try spore_stream.writeFrame(&frame_buf, .{
            .frame_type = .close,
            .stream_id = .stdin,
            .offset = self.stdin_offset,
        }, "");
        self.enqueueOutbound(frame) catch |err| switch (err) {
            error.OutboundFull => return false,
            else => |e| return e,
        };
        return true;
    }

    pub fn enqueueTerminalDataBlocking(self: *HostStream, data: []const u8, stop: *const std.atomic.Value(bool)) !bool {
        var rest = data;
        while (rest.len > 0) {
            if (stop.load(.acquire)) return false;
            const take = @min(rest.len, spore_stream.max_payload_len);
            var frame_buf: [spore_stream.max_frame_len]u8 = undefined;
            const frame = try spore_stream.writeFrame(&frame_buf, .{
                .frame_type = .data,
                .stream_id = .terminal,
                .offset = self.terminal_input_offset,
            }, rest[0..take]);
            if (!try self.enqueueOutboundBlocking(frame, stop)) return false;
            self.terminal_input_offset += take;
            rest = rest[take..];
        }
        return true;
    }

    pub fn enqueueTerminalCloseBlocking(self: *HostStream, stop: *const std.atomic.Value(bool)) !bool {
        var frame_buf: [spore_stream.max_frame_len]u8 = undefined;
        const frame = try spore_stream.writeFrame(&frame_buf, .{
            .frame_type = .close,
            .stream_id = .terminal,
            .offset = self.terminal_input_offset,
        }, "");
        return self.enqueueOutboundBlocking(frame, stop);
    }

    pub fn enqueueResizeBlocking(self: *HostStream, resize: spore_stream.Resize, stop: *const std.atomic.Value(bool)) !bool {
        var payload: [4]u8 = undefined;
        spore_stream.writeResizePayload(&payload, resize);
        var frame_buf: [spore_stream.max_frame_len]u8 = undefined;
        const frame = try spore_stream.writeFrame(&frame_buf, .{
            .frame_type = .resize,
            .stream_id = .terminal,
            .offset = 0,
        }, &payload);
        return self.enqueueOutboundBlocking(frame, stop);
    }

    fn enqueueOutboundBlocking(self: *HostStream, frame: []const u8, stop: *const std.atomic.Value(bool)) !bool {
        if (frame.len > max_payload) return error.PacketTooLarge;
        while (!stop.load(.acquire)) {
            if (self.state == .complete or self.state == .failed) return false;
            self.enqueueOutbound(frame) catch |err| switch (err) {
                error.OutboundFull => {
                    var ts = std.c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
                    _ = std.c.nanosleep(&ts, null);
                    continue;
                },
                else => |e| return e,
            };
            return true;
        }
        return false;
    }

    fn enqueueOutbound(self: *HostStream, frame: []const u8) !void {
        if (frame.len > max_payload) return error.PacketTooLarge;
        self.outbound_lock.lock();
        defer self.outbound_lock.unlock();
        if (self.outbound_count >= self.outbound_frames.len) return error.OutboundFull;
        const index = (self.outbound_head + self.outbound_count) % self.outbound_frames.len;
        @memcpy(self.outbound_frames[index].data[0..frame.len], frame);
        self.outbound_frames[index].len = frame.len;
        self.outbound_count += 1;
    }

    /// Dequeue the next outbound frame only if it fits within `limit` bytes,
    /// so the caller can respect the guest's advertised credit window.
    fn dequeueOutboundWithin(self: *HostStream, out: *[max_payload]u8, limit: usize) ?[]const u8 {
        self.outbound_lock.lock();
        defer self.outbound_lock.unlock();
        if (self.outbound_count == 0) return null;
        const frame = &self.outbound_frames[self.outbound_head];
        const len = frame.len;
        if (len > limit) return null;
        @memcpy(out[0..len], frame.data[0..len]);
        frame.len = 0;
        self.outbound_head = (self.outbound_head + 1) % self.outbound_frames.len;
        self.outbound_count -= 1;
        return out[0..len];
    }

    /// Bytes the guest can still accept: its advertised receive buffer minus
    /// stream data the host has sent that the guest has not yet consumed.
    fn txWindowFree(self: *const HostStream) u32 {
        const inflight = self.sent_bytes -% self.peer_fwd_cnt;
        if (inflight >= self.peer_buf_alloc) return 0;
        return self.peer_buf_alloc - inflight;
    }

    pub fn fail(self: *HostStream) void {
        self.state = .failed;
        if (self.response_ms == null) self.response_ms = self.elapsedMs();
    }
};

pub const ControlAction = union(enum) {
    keep_running,
    stop,
    snapshot: SnapshotAction,
    rootfs_snapshot: RootfsSnapshotAction,
    disk_fork: DiskForkAction,
};

pub const SnapshotAction = struct {
    dir: []const u8,
    publish_dir: ?[]const u8 = null,
    continue_after: bool = false,
};

pub const RootfsSnapshotAction = struct {
    dir: []const u8,
};

pub const DiskForkAction = struct {
    dir: []const u8,
    count: u8,
    allow_copy: bool = false,
    force_copy: bool = false,
};

pub const ControlStats = struct {
    chunks_nonzero: ?u64 = null,
    dirty_chunks_pending: ?u64 = null,
    accepted_features: ?u64 = null,
    write_zeroes_requests: ?u64 = null,
    write_zeroes_bytes: ?u64 = null,
    write_zeroes_unmap_requests: ?u64 = null,
    write_zeroes_ok: ?u64 = null,
    write_zeroes_errors: ?u64 = null,
    write_zeroes_backend_failures: ?u64 = null,
    write_zeroes_unsupported: ?u64 = null,
    out_requests: ?u64 = null,
    out_bytes: ?u64 = null,
    out_all_zero_requests: ?u64 = null,
    out_all_zero_bytes: ?u64 = null,
};

pub const Wake = struct {
    context: *anyopaque,
    wakeFn: *const fn (context: *anyopaque) void,

    pub fn wake(self: Wake) void {
        self.wakeFn(self.context);
    }
};

pub const Control = struct {
    context: *anyopaque,
    pollFn: *const fn (context: *anyopaque, dev: *Vsock) anyerror!ControlAction,
    setWakeFn: *const fn (context: *anyopaque, wake: Wake) void,
    publishSnapshotFn: ?*const fn (context: *anyopaque, work_dir: []const u8, publish_dir: []const u8) anyerror!void = null,
    completeSnapshotFn: *const fn (context: *anyopaque, dir: []const u8) anyerror!void,
    completeRootfsSnapshotFn: *const fn (context: *anyopaque, disk: ?spore.Disk) anyerror!void,
    completeDiskForkFn: ?*const fn (context: *anyopaque, batch: *runtime_disk_fork_capture.Batch) anyerror!void = null,
    failDiskForkFn: ?*const fn (context: *anyopaque, err: anyerror) void = null,
    reportStatsFn: *const fn (context: *anyopaque, stats: ControlStats) void,

    pub fn poll(self: Control, dev: *Vsock) !ControlAction {
        return self.pollFn(self.context, dev);
    }

    pub fn setWake(self: Control, wake: Wake) void {
        self.setWakeFn(self.context, wake);
    }

    pub fn publishSnapshot(self: Control, work_dir: []const u8, publish_dir: []const u8) !void {
        const publish = self.publishSnapshotFn orelse return error.UnsupportedSnapshot;
        try publish(self.context, work_dir, publish_dir);
    }

    pub fn completeSnapshot(self: Control, dir: []const u8) !void {
        try self.completeSnapshotFn(self.context, dir);
    }

    pub fn completeRootfsSnapshot(self: Control, disk: ?spore.Disk) !void {
        try self.completeRootfsSnapshotFn(self.context, disk);
    }

    pub fn completeDiskFork(self: Control, batch: *runtime_disk_fork_capture.Batch) !void {
        const complete = self.completeDiskForkFn orelse return error.UnsupportedDiskFork;
        try complete(self.context, batch);
    }

    pub fn failDiskFork(self: Control, err: anyerror) void {
        const fail = self.failDiskForkFn orelse return;
        fail(self.context, err);
    }

    pub fn reportStats(self: Control, stats: ControlStats) void {
        self.reportStatsFn(self.context, stats);
    }
};

fn monotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

pub const Vsock = struct {
    guest_cid: u64,
    pending: [max_pending]Packet = undefined,
    pending_len: usize = 0,
    host_stream: ?*HostStream = null,

    pub fn init(config: Config) Vsock {
        return .{ .guest_cid = config.guest_cid };
    }

    pub fn attachHostStream(self: *Vsock, stream: *HostStream) !void {
        self.host_stream = stream;
        stream.markAttached();
        try self.enqueueHostConnectRequest(stream);
    }

    /// Detach the current host stream and tell the guest the connection is
    /// gone. Without the reset, a guest blocked writing stream data waits
    /// forever for credit on a connection the host has abandoned, wedging
    /// the guest agent and every subsequent exec.
    pub fn resetHostStream(self: *Vsock) void {
        const stream = self.host_stream orelse return;
        self.host_stream = null;
        if (stream.state == .complete) return;
        // Drop packets queued for the dead stream so the reset always fits.
        self.pending_len = 0;
        self.enqueuePacket(.{
            .src_cid = host_cid,
            .dst_cid = self.guest_cid,
            .src_port = stream.host_port,
            .dst_port = stream.guest_port,
            .len = 0,
            .packet_type = packet_type_stream,
            .op = op_rst,
            .buf_alloc = host_stream_credit,
            .fwd_cnt = stream.received_bytes,
        }, "") catch {};
    }

    pub fn flushPendingRx(self: *Vsock, queues: *[mmio.max_queues]queue.VirtQueue, ram: guestmem.GuestRam) bool {
        var budget: queue.NotifyBudget = .{};
        return self.flushRx(&queues[rx_queue], ram, &budget);
    }

    fn enqueueHostConnectRequest(self: *Vsock, stream: *HostStream) !void {
        try self.enqueuePacket(.{
            .src_cid = host_cid,
            .dst_cid = self.guest_cid,
            .src_port = stream.host_port,
            .dst_port = stream.guest_port,
            .len = 0,
            .packet_type = packet_type_stream,
            .op = op_request,
            .buf_alloc = host_stream_credit,
            .fwd_cnt = stream.received_bytes,
        }, "");
    }

    pub fn device(self: *Vsock) mmio.Device {
        return .{
            .context = self,
            .device_id = device_id,
            .device_features = 0,
            .queue_count = 3,
            .notifyFn = notify,
            .configReadFn = configRead,
        };
    }

    fn configRead(ctx: *anyopaque, offset: u64) u32 {
        const self: *Vsock = @ptrCast(@alignCast(ctx));
        // Config space is the guest CID as a little-endian u64.
        return switch (offset) {
            0 => @truncate(self.guest_cid),
            4 => @truncate(self.guest_cid >> 32),
            else => 0,
        };
    }

    fn notify(ctx: *anyopaque, queue_index: u8, queues: *[mmio.max_queues]queue.VirtQueue, ram: guestmem.GuestRam) bool {
        const self: *Vsock = @ptrCast(@alignCast(ctx));
        var budget: queue.NotifyBudget = .{};
        return switch (queue_index) {
            tx_queue => self.processTx(queues, ram, &budget),
            rx_queue => self.flushRx(&queues[rx_queue], ram, &budget),
            event_queue => false,
            else => false,
        };
    }

    fn processTx(self: *Vsock, queues: *[mmio.max_queues]queue.VirtQueue, ram: guestmem.GuestRam, budget: *queue.NotifyBudget) bool {
        const tx = &queues[tx_queue];
        var did_work = false;
        while (budget.hasRemaining()) {
            const maybe_chain = tx.popAvail(ram) catch return did_work;
            const chain = maybe_chain orelse break;
            budget.consume();
            if (parsePacketFromChain(&chain)) |packet| {
                self.handleGuestPacket(packet.header, packet.data[0..packet.data_len]);
            }
            tx.pushUsed(ram, chain.head, 0) catch return did_work;
            did_work = true;
        }
        // Guest packets may have grown the credit window; move deferred
        // outbound frames before delivering pending receive packets.
        if (self.host_stream) |stream| {
            _ = self.flushHostStreamOutboundFor(stream) catch stream.fail();
        }
        return self.flushRx(&queues[rx_queue], ram, budget) or did_work;
    }

    fn handleGuestPacket(self: *Vsock, h: Header, payload: []const u8) void {
        if (h.packet_type != packet_type_stream) return;

        if (self.host_stream) |stream| {
            const matches_host_stream =
                h.src_cid == self.guest_cid and
                h.dst_cid == host_cid and
                h.src_port == stream.guest_port and
                h.dst_port == stream.host_port;
            if (matches_host_stream) {
                self.handleHostStreamPacket(stream, h, payload);
                return;
            }
        }

        if (h.dst_cid != host_cid or h.src_cid != self.guest_cid) return;
        // Connection requests are refused, and packets for unknown or
        // abandoned connections are reset (virtio 1.2 §5.10.6.6) so guests
        // blocked on a stale stream unblock instead of waiting forever.
        // Never answer a reset with a reset.
        if (h.op == op_rst) return;
        self.enqueuePacket(.{
            .src_cid = h.dst_cid,
            .dst_cid = h.src_cid,
            .src_port = h.dst_port,
            .dst_port = h.src_port,
            .len = 0,
            .packet_type = h.packet_type,
            .op = op_rst,
        }, "") catch {};
    }

    fn handleHostStreamPacket(self: *Vsock, stream: *HostStream, h: Header, payload: []const u8) void {
        // Every guest packet carries the guest's current receive window.
        stream.peer_buf_alloc = h.buf_alloc;
        stream.peer_fwd_cnt = h.fwd_cnt;
        switch (h.op) {
            op_response => {
                if (stream.state == .connecting) {
                    stream.markConnected();
                    _ = self.flushHostStreamOutboundFor(stream) catch stream.fail();
                }
            },
            op_rw => {
                stream.appendOutput(payload);
            },
            op_credit_request => self.enqueueHostPacket(stream, op_credit_update, "") catch stream.fail(),
            op_credit_update => {},
            op_shutdown => {},
            op_rst => {
                if (stream.state == .connecting) {
                    self.enqueueHostConnectRequest(stream) catch stream.fail();
                } else {
                    stream.fail();
                }
            },
            else => {},
        }
        // Volunteer a credit update on any guest activity so an update
        // skipped while the pending queue was full is retried.
        self.maybeUpdateCredit(stream);
    }

    fn enqueueHostPacket(self: *Vsock, stream: *HostStream, op: u16, payload: []const u8) !void {
        try self.enqueuePacket(.{
            .src_cid = host_cid,
            .dst_cid = self.guest_cid,
            .src_port = stream.host_port,
            .dst_port = stream.guest_port,
            .len = @intCast(payload.len),
            .packet_type = packet_type_stream,
            .op = op,
            .buf_alloc = host_stream_credit,
            .fwd_cnt = stream.received_bytes,
        }, payload);
        stream.credit_fwd_cnt_sent = stream.received_bytes;
        const inc: u32 = if (payload.len > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(payload.len);
        stream.sent_bytes +%= inc;
    }

    /// Send a credit update once the guest has consumed enough of the
    /// advertised window that it risks stalling. The guest driver blocks
    /// without requesting credit when its window fills, so the host must
    /// volunteer updates as it consumes stream data.
    fn maybeUpdateCredit(self: *Vsock, stream: *HostStream) void {
        if (stream.state != .connected) return;
        const consumed = stream.received_bytes -% stream.credit_fwd_cnt_sent;
        if (consumed < host_stream_credit / 2) return;
        self.enqueueHostPacket(stream, op_credit_update, "") catch {};
    }

    pub fn flushHostStreamOutbound(self: *Vsock) !bool {
        const stream = self.host_stream orelse return false;
        return self.flushHostStreamOutboundFor(stream);
    }

    fn flushHostStreamOutboundFor(self: *Vsock, stream: *HostStream) !bool {
        if (stream.state != .connected) return false;
        var did_work = false;
        if (!stream.request_sent) {
            if (stream.request_len > stream.txWindowFree()) return did_work;
            if (self.pending_len >= self.pending.len) return did_work;
            try self.enqueueHostPacket(stream, op_rw, stream.request[0..stream.request_len]);
            stream.request_sent = true;
            did_work = true;
        }
        while (self.pending_len < self.pending.len) {
            var payload_buf: [max_payload]u8 = undefined;
            const payload = stream.dequeueOutboundWithin(&payload_buf, stream.txWindowFree()) orelse break;
            try self.enqueueHostPacket(stream, op_rw, payload);
            did_work = true;
        }
        return did_work;
    }

    fn enqueuePacket(self: *Vsock, header: Header, payload: []const u8) !void {
        if (payload.len > max_payload) return error.PacketTooLarge;
        if (self.pending_len >= self.pending.len) return error.PendingFull;
        var packet = Packet{ .header = header, .data_len = payload.len };
        packet.header.len = @intCast(payload.len);
        if (payload.len > 0) @memcpy(packet.data[0..payload.len], payload);
        self.pending[self.pending_len] = packet;
        self.pending_len += 1;
    }

    fn flushRx(self: *Vsock, rx: *queue.VirtQueue, ram: guestmem.GuestRam, budget: *queue.NotifyBudget) bool {
        var did_work = false;
        while (self.pending_len > 0 and budget.hasRemaining()) {
            const maybe_chain = rx.popAvail(ram) catch return did_work;
            const chain = maybe_chain orelse break;
            budget.consume();
            const packet = &self.pending[0];
            const capacity = chainWritableCapacity(&chain);
            // Stream data (op_rw) carries no per-packet boundaries, so a
            // payload larger than the guest buffer is legally delivered as
            // multiple smaller packets. Other packets must fit whole, and a
            // split fragment must make at least one byte of progress.
            const take = @min(packet.data_len, capacity -| header_len);
            const deliverable = capacity >= header_len and
                (take == packet.data_len or (packet.header.op == op_rw and take > 0));
            if (!deliverable) {
                // The guest posted a buffer too small for this packet.
                // Consume the undersized buffer but keep the packet pending;
                // dropping it would corrupt the stream. Progress is bounded
                // by the guest's available ring.
                chain.markWritableDirty(ram);
                rx.pushUsed(ram, chain.head, 0) catch return did_work;
                did_work = true;
                continue;
            }
            var fragment_header = packet.header;
            fragment_header.len = @intCast(take);
            const written = writePacketToChain(&chain, fragment_header, packet.data[0..take]) orelse {
                // Capacity was verified above, so this is unreachable; if it
                // ever fires, keep the packet pending rather than dropping
                // stream data.
                chain.markWritableDirty(ram);
                rx.pushUsed(ram, chain.head, 0) catch return did_work;
                did_work = true;
                continue;
            };
            chain.markWritableDirty(ram);
            rx.pushUsed(ram, chain.head, written) catch return did_work;
            if (take < packet.data_len) {
                const rest = packet.data_len - take;
                std.mem.copyForwards(u8, packet.data[0..rest], packet.data[take..packet.data_len]);
                packet.data_len = rest;
                packet.header.len = @intCast(rest);
            } else {
                self.recordHostDelivery(packet.header);
                self.dropFirstPending();
            }
            did_work = true;
        }
        return did_work;
    }

    fn recordHostDelivery(self: *Vsock, h: Header) void {
        const stream = self.host_stream orelse return;
        if (h.src_cid != host_cid or h.dst_cid != self.guest_cid) return;
        if (h.src_port != stream.host_port or h.dst_port != stream.guest_port) return;
        switch (h.op) {
            op_request => stream.markConnectRequestDelivered(),
            op_rw => stream.markRequestDelivered(),
            else => {},
        }
    }

    fn dropFirstPending(self: *Vsock) void {
        if (self.pending_len == 0) return;
        var i: usize = 1;
        while (i < self.pending_len) : (i += 1) {
            self.pending[i - 1] = self.pending[i];
        }
        self.pending_len -= 1;
    }
};

fn chainWritableCapacity(chain: *const queue.Chain) usize {
    var n: usize = 0;
    for (chain.segments.slice()) |seg| {
        if (seg.writable) n += seg.data.len;
    }
    return n;
}

fn parsePacketFromChain(chain: *const queue.Chain) ?Packet {
    var buf: [header_len]u8 = undefined;
    if (!chain.copyReadableRange(0, &buf)) return null;
    const header = parseHeader(&buf);
    if (header.len > max_payload) return null;
    const data_len: usize = @intCast(header.len);
    var packet = Packet{ .header = header, .data_len = data_len };
    if (data_len > 0 and !chain.copyReadableRange(header_len, packet.data[0..data_len])) return null;
    return packet;
}

fn writePacketToChain(chain: *const queue.Chain, h: Header, payload: []const u8) ?u32 {
    var buf: [header_len]u8 = undefined;
    writeHeader(&buf, h);
    var copied: usize = 0;
    const total = header_len + payload.len;
    for (chain.segments.slice()) |seg| {
        if (!seg.writable) continue;
        var written_to_seg: usize = 0;
        if (copied < header_len) {
            const n = @min(seg.data.len, header_len - copied);
            @memcpy(seg.data[0..n], buf[copied..][0..n]);
            copied += n;
            written_to_seg += n;
        }
        if (copied >= header_len and copied < total and written_to_seg < seg.data.len) {
            const payload_off = copied - header_len;
            const n = @min(seg.data.len - written_to_seg, payload.len - payload_off);
            @memcpy(seg.data[written_to_seg..][0..n], payload[payload_off..][0..n]);
            copied += n;
        }
        if (copied == total) return @intCast(total);
    }
    return null;
}

fn parseHeader(buf: *const [header_len]u8) Header {
    return .{
        .src_cid = std.mem.readInt(u64, buf[0..8], .little),
        .dst_cid = std.mem.readInt(u64, buf[8..16], .little),
        .src_port = std.mem.readInt(u32, buf[16..20], .little),
        .dst_port = std.mem.readInt(u32, buf[20..24], .little),
        .len = std.mem.readInt(u32, buf[24..28], .little),
        .packet_type = std.mem.readInt(u16, buf[28..30], .little),
        .op = std.mem.readInt(u16, buf[30..32], .little),
        .flags = std.mem.readInt(u32, buf[32..36], .little),
        .buf_alloc = std.mem.readInt(u32, buf[36..40], .little),
        .fwd_cnt = std.mem.readInt(u32, buf[40..44], .little),
    };
}

fn writeHeader(buf: *[header_len]u8, h: Header) void {
    std.mem.writeInt(u64, buf[0..8], h.src_cid, .little);
    std.mem.writeInt(u64, buf[8..16], h.dst_cid, .little);
    std.mem.writeInt(u32, buf[16..20], h.src_port, .little);
    std.mem.writeInt(u32, buf[20..24], h.dst_port, .little);
    std.mem.writeInt(u32, buf[24..28], h.len, .little);
    std.mem.writeInt(u16, buf[28..30], h.packet_type, .little);
    std.mem.writeInt(u16, buf[30..32], h.op, .little);
    std.mem.writeInt(u32, buf[32..36], h.flags, .little);
    std.mem.writeInt(u32, buf[36..40], h.buf_alloc, .little);
    std.mem.writeInt(u32, buf[40..44], h.fwd_cnt, .little);
}

// --- tests ------------------------------------------------------------------

fn configureQueue(t: *mmio.Transport, qi: u32, desc: u64, avail: u64, used: u64, ram: guestmem.GuestRam) void {
    _ = t.write(0x030, qi, ram);
    _ = t.write(0x038, 8, ram);
    _ = t.write(0x080, @truncate(desc), ram);
    _ = t.write(0x084, @truncate(desc >> 32), ram);
    _ = t.write(0x090, @truncate(avail), ram);
    _ = t.write(0x094, @truncate(avail >> 32), ram);
    _ = t.write(0x0a0, @truncate(used), ram);
    _ = t.write(0x0a4, @truncate(used >> 32), ram);
    _ = t.write(0x044, 1, ram);
}

fn setDesc(ram: guestmem.GuestRam, desc_base: u64, i: u16, addr: u64, len: u32, flags: u16) !void {
    const base = desc_base + 16 * @as(u64, i);
    try ram.write(u64, base, addr);
    try ram.write(u32, base + 8, len);
    try ram.write(u16, base + 12, flags);
    try ram.write(u16, base + 14, 0);
}

fn pushAvail(ram: guestmem.GuestRam, avail_base: u64, qsize: u16, head: u16) !void {
    const idx = try ram.read(u16, avail_base + 2);
    try ram.write(u16, avail_base + 4 + 2 * @as(u64, idx % qsize), head);
    try ram.write(u16, avail_base + 2, idx +% 1);
}

test "config reports guest cid" {
    var dev = Vsock.init(.{ .guest_cid = 42 });
    var t = mmio.Transport.init(dev.device());
    try std.testing.expectEqual(device_id, t.read(0x008));
    try std.testing.expectEqual(@as(u32, 42), t.read(0x100));
    try std.testing.expectEqual(@as(u32, 0), t.read(0x104));
}

test "stream connect request is answered with rst" {
    var dev = Vsock.init(.{ .guest_cid = default_guest_cid });
    var t = mmio.Transport.init(dev.device());
    var buf: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    const rx_desc = 0x000;
    const rx_avail = 0x400;
    const rx_used = 0x800;
    const tx_desc = 0x1000;
    const tx_avail = 0x1400;
    const tx_used = 0x1800;
    const rx_buf = 0x2000;
    const tx_buf = 0x2100;

    configureQueue(&t, rx_queue, rx_desc, rx_avail, rx_used, ram);
    configureQueue(&t, tx_queue, tx_desc, tx_avail, tx_used, ram);

    try setDesc(ram, rx_desc, 0, rx_buf, header_len, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 0);

    var request: [header_len]u8 = undefined;
    writeHeader(&request, .{
        .src_cid = default_guest_cid,
        .dst_cid = host_cid,
        .src_port = 1024,
        .dst_port = 80,
        .len = 0,
        .packet_type = packet_type_stream,
        .op = op_request,
    });
    @memcpy(buf[tx_buf..][0..header_len], &request);
    try setDesc(ram, tx_desc, 0, tx_buf, header_len, 0);
    try pushAvail(ram, tx_avail, 8, 0);

    try std.testing.expect(t.write(0x050, tx_queue, ram));
    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, tx_used + 2));
    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, rx_used + 2));
    try std.testing.expectEqual(@as(u32, header_len), try ram.read(u32, rx_used + 8));

    const response = parseHeader(buf[rx_buf..][0..header_len]);
    try std.testing.expectEqual(host_cid, response.src_cid);
    try std.testing.expectEqual(default_guest_cid, response.dst_cid);
    try std.testing.expectEqual(@as(u32, 80), response.src_port);
    try std.testing.expectEqual(@as(u32, 1024), response.dst_port);
    try std.testing.expectEqual(packet_type_stream, response.packet_type);
    try std.testing.expectEqual(op_rst, response.op);
    try std.testing.expectEqual(@as(u32, 0), response.len);
}

const StreamCapture = struct {
    stdout: [64]u8 = [_]u8{0} ** 64,
    stderr: [64]u8 = [_]u8{0} ** 64,
    terminal: [64]u8 = [_]u8{0} ** 64,
    stdout_len: usize = 0,
    stderr_len: usize = 0,
    terminal_len: usize = 0,
    ready_count: usize = 0,
};

fn captureSink(context: ?*anyopaque, output: HostStreamOutput, bytes: []const u8) void {
    const capture: *StreamCapture = @ptrCast(@alignCast(context.?));
    switch (output) {
        .stdout => {
            const n = @min(bytes.len, capture.stdout.len - capture.stdout_len);
            if (n > 0) {
                @memcpy(capture.stdout[capture.stdout_len..][0..n], bytes[0..n]);
                capture.stdout_len += n;
            }
        },
        .stderr => {
            const n = @min(bytes.len, capture.stderr.len - capture.stderr_len);
            if (n > 0) {
                @memcpy(capture.stderr[capture.stderr_len..][0..n], bytes[0..n]);
                capture.stderr_len += n;
            }
        },
        .terminal => {
            const n = @min(bytes.len, capture.terminal.len - capture.terminal_len);
            if (n > 0) {
                @memcpy(capture.terminal[capture.terminal_len..][0..n], bytes[0..n]);
                capture.terminal_len += n;
            }
        },
    }
}

fn lifecycleSink(context: ?*anyopaque, event: HostStreamLifecycle) void {
    const capture: *StreamCapture = @ptrCast(@alignCast(context.?));
    switch (event) {
        .ready => capture.ready_count += 1,
    }
}

fn appendV1Frame(stream: *HostStream, frame_type: spore_stream.FrameType, stream_id: spore_stream.StreamId, offset: u64, payload: []const u8) !void {
    var frame_buf: [spore_stream.max_frame_len]u8 = undefined;
    const frame = try spore_stream.writeFrame(&frame_buf, .{
        .frame_type = frame_type,
        .stream_id = stream_id,
        .offset = offset,
    }, payload);
    const split = @min(frame.len, 7);
    stream.appendOutput(frame[0..split]);
    stream.appendOutput(frame[split..]);
}

test "host stream parses spore stream v1 frames" {
    var stream = try HostStream.initWithProtocol(10700, "{}\n", .spore_stream_v1);
    var capture = StreamCapture{};
    stream.setOutputSink(&capture, captureSink);
    stream.state = .connected;

    try appendV1Frame(&stream, .data, .stdout, 0, "hello ");
    try appendV1Frame(&stream, .data, .stdout, 6, "world");
    try appendV1Frame(&stream, .data, .stderr, 0, "err");
    try appendV1Frame(&stream, .data, .terminal, 0, "tty");
    try appendV1Frame(&stream, .event, .control, 0, "memory-pressure");
    try appendV1Frame(&stream, .event, .control, 0, "timing listen=1 accept=2 decode=3 spawn=4 exit=5 now=6");
    var exit_payload: [4]u8 = undefined;
    spore_stream.writeExitPayload(&exit_payload, 7);
    try appendV1Frame(&stream, .exit, .control, 0, &exit_payload);

    try std.testing.expectEqual(HostStreamState.complete, stream.state);
    try std.testing.expectEqual(@as(i32, 7), stream.exit_code.?);
    try std.testing.expectEqual(@as(u32, 1), stream.memory_pressure_count);
    try std.testing.expect(stream.guest_timing_ms != null);
    try std.testing.expectEqualStrings("hello world", capture.stdout[0..capture.stdout_len]);
    try std.testing.expectEqualStrings("err", capture.stderr[0..capture.stderr_len]);
    try std.testing.expectEqualStrings("tty", capture.terminal[0..capture.terminal_len]);
}

test "host stream v1 parser fails closed on malformed frames" {
    {
        var stream = try HostStream.initWithProtocol(10700, "{}\n", .spore_stream_v1);
        stream.state = .connected;
        var bad: [spore_stream.header_len]u8 = [_]u8{0} ** spore_stream.header_len;
        stream.appendOutput(&bad);
        try std.testing.expectEqual(HostStreamState.failed, stream.state);
    }
    {
        var stream = try HostStream.initWithProtocol(10700, "{}\n", .spore_stream_v1);
        stream.state = .connected;
        var header: [spore_stream.header_len]u8 = undefined;
        spore_stream.writeHeader(&header, .{
            .frame_type = .data,
            .flags = 1,
            .stream_id = .stdout,
            .offset = 0,
            .payload_len = 0,
        });
        stream.appendOutput(&header);
        try std.testing.expectEqual(HostStreamState.failed, stream.state);
    }
    {
        var stream = try HostStream.initWithProtocol(10700, "{}\n", .spore_stream_v1);
        stream.state = .connected;
        try appendV1Frame(&stream, .data, .stdout, 1, "x");
        try std.testing.expectEqual(HostStreamState.failed, stream.state);
    }
    {
        var stream = try HostStream.initWithProtocol(10700, "{}\n", .spore_stream_v1);
        stream.state = .connected;
        var header: [spore_stream.header_len]u8 = undefined;
        spore_stream.writeHeader(&header, .{
            .frame_type = .data,
            .stream_id = .stdin,
            .offset = 0,
            .payload_len = 1,
        });
        stream.appendOutput(&header);
        try std.testing.expectEqual(HostStreamState.failed, stream.state);
    }
}

test "host stream queues stdin v1 frames with offsets" {
    var stream = try HostStream.initWithProtocol(10700, "{}\n", .spore_stream_v1);
    var stop = std.atomic.Value(bool).init(false);
    try std.testing.expect(try stream.enqueueStdinDataBlocking("hi", &stop));
    try std.testing.expect(try stream.enqueueStdinCloseBlocking(&stop));

    var payload_buf: [max_payload]u8 = undefined;
    const data_frame = stream.dequeueOutboundWithin(&payload_buf, max_payload).?;
    var header_buf: [spore_stream.header_len]u8 = undefined;
    @memcpy(&header_buf, data_frame[0..spore_stream.header_len]);
    const data_header = try spore_stream.readHeader(&header_buf);
    try std.testing.expectEqual(spore_stream.FrameType.data, data_header.frame_type);
    try std.testing.expectEqual(spore_stream.StreamId.stdin, data_header.stream_id);
    try std.testing.expectEqual(@as(u64, 0), data_header.offset);
    try std.testing.expectEqualStrings("hi", data_frame[spore_stream.header_len..]);

    const close_frame = stream.dequeueOutboundWithin(&payload_buf, max_payload).?;
    @memcpy(&header_buf, close_frame[0..spore_stream.header_len]);
    const close_header = try spore_stream.readHeader(&header_buf);
    try std.testing.expectEqual(spore_stream.FrameType.close, close_header.frame_type);
    try std.testing.expectEqual(spore_stream.StreamId.stdin, close_header.stream_id);
    try std.testing.expectEqual(@as(u64, 2), close_header.offset);
    try std.testing.expectEqual(@as(u32, 0), close_header.payload_len);
    try std.testing.expect(stream.dequeueOutboundWithin(&payload_buf, max_payload) == null);
}

test "host stream queues terminal v1 frames and resize" {
    var stream = try HostStream.initWithProtocol(10700, "{}\n", .spore_stream_v1);
    var stop = std.atomic.Value(bool).init(false);
    try std.testing.expect(try stream.enqueueTerminalDataBlocking("ab", &stop));
    try std.testing.expect(try stream.enqueueResizeBlocking(.{ .rows = 40, .cols = 120 }, &stop));
    try std.testing.expect(try stream.enqueueTerminalCloseBlocking(&stop));

    var payload_buf: [max_payload]u8 = undefined;
    const data_frame = stream.dequeueOutboundWithin(&payload_buf, max_payload).?;
    var header_buf: [spore_stream.header_len]u8 = undefined;
    @memcpy(&header_buf, data_frame[0..spore_stream.header_len]);
    const data_header = try spore_stream.readHeader(&header_buf);
    try std.testing.expectEqual(spore_stream.FrameType.data, data_header.frame_type);
    try std.testing.expectEqual(spore_stream.StreamId.terminal, data_header.stream_id);
    try std.testing.expectEqual(@as(u64, 0), data_header.offset);
    try std.testing.expectEqualStrings("ab", data_frame[spore_stream.header_len..]);

    const resize_frame = stream.dequeueOutboundWithin(&payload_buf, max_payload).?;
    @memcpy(&header_buf, resize_frame[0..spore_stream.header_len]);
    const resize_header = try spore_stream.readHeader(&header_buf);
    try std.testing.expectEqual(spore_stream.FrameType.resize, resize_header.frame_type);
    try std.testing.expectEqual(spore_stream.StreamId.terminal, resize_header.stream_id);
    const resize = try spore_stream.readResizePayload(resize_frame[spore_stream.header_len..]);
    try std.testing.expectEqual(@as(u16, 40), resize.rows);
    try std.testing.expectEqual(@as(u16, 120), resize.cols);

    const close_frame = stream.dequeueOutboundWithin(&payload_buf, max_payload).?;
    @memcpy(&header_buf, close_frame[0..spore_stream.header_len]);
    const close_header = try spore_stream.readHeader(&header_buf);
    try std.testing.expectEqual(spore_stream.FrameType.close, close_header.frame_type);
    try std.testing.expectEqual(spore_stream.StreamId.terminal, close_header.stream_id);
    try std.testing.expectEqual(@as(u64, 2), close_header.offset);
    try std.testing.expect(stream.dequeueOutboundWithin(&payload_buf, max_payload) == null);
}

test "host stream connects, sends request, and parses streamed frames" {
    var dev = Vsock.init(.{ .guest_cid = default_guest_cid });
    var t = mmio.Transport.init(dev.device());
    var buf: [32 * 1024]u8 = [_]u8{0} ** (32 * 1024);
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    const rx_desc = 0x000;
    const rx_avail = 0x400;
    const rx_used = 0x800;
    const tx_desc = 0x1000;
    const tx_avail = 0x1400;
    const tx_used = 0x1800;
    const rx_buf_request = 0x2000;
    const rx_buf_retry = 0x2200;
    const rx_buf_payload = 0x2400;
    const tx_buf_rst = 0x2600;
    const tx_buf_response = 0x2800;
    const tx_buf_stdout = 0x2a00;
    const tx_buf_stderr = 0x2c00;
    const tx_buf_exit = 0x2e00;

    configureQueue(&t, rx_queue, rx_desc, rx_avail, rx_used, ram);
    configureQueue(&t, tx_queue, tx_desc, tx_avail, tx_used, ram);

    const request = "{\"command\":[\"/bin/true\"],\"closed_env\":true}\n";
    var stream = try HostStream.init(10700, request);
    var capture = StreamCapture{};
    stream.setOutputSink(&capture, captureSink);
    stream.setLifecycleSink(&capture, lifecycleSink);
    try dev.attachHostStream(&stream);

    try setDesc(ram, rx_desc, 0, rx_buf_request, header_len, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 0);
    try std.testing.expect(t.write(0x050, rx_queue, ram));
    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, rx_used + 2));

    const connect = parseHeader(buf[rx_buf_request..][0..header_len]);
    try std.testing.expectEqual(host_cid, connect.src_cid);
    try std.testing.expectEqual(default_guest_cid, connect.dst_cid);
    try std.testing.expectEqual(default_host_port, connect.src_port);
    try std.testing.expectEqual(@as(u32, 10700), connect.dst_port);
    try std.testing.expectEqual(op_request, connect.op);

    try setDesc(ram, rx_desc, 1, rx_buf_retry, header_len, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 1);

    var rst: [header_len]u8 = undefined;
    writeHeader(&rst, .{
        .src_cid = default_guest_cid,
        .dst_cid = host_cid,
        .src_port = 10700,
        .dst_port = default_host_port,
        .len = 0,
        .packet_type = packet_type_stream,
        .op = op_rst,
    });
    @memcpy(buf[tx_buf_rst..][0..header_len], &rst);
    try setDesc(ram, tx_desc, 0, tx_buf_rst, header_len, 0);
    try pushAvail(ram, tx_avail, 8, 0);
    try std.testing.expect(t.write(0x050, tx_queue, ram));
    try std.testing.expectEqual(HostStreamState.connecting, stream.state);
    try std.testing.expectEqual(@as(u16, 2), try ram.read(u16, rx_used + 2));

    const retry = parseHeader(buf[rx_buf_retry..][0..header_len]);
    try std.testing.expectEqual(op_request, retry.op);
    try std.testing.expectEqual(host_cid, retry.src_cid);
    try std.testing.expectEqual(default_guest_cid, retry.dst_cid);

    try setDesc(ram, rx_desc, 2, rx_buf_payload, @intCast(header_len + request.len), 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 2);

    var response: [header_len]u8 = undefined;
    writeHeader(&response, .{
        .src_cid = default_guest_cid,
        .dst_cid = host_cid,
        .src_port = 10700,
        .dst_port = default_host_port,
        .len = 0,
        .packet_type = packet_type_stream,
        .op = op_response,
        .buf_alloc = 64 * 1024,
    });
    @memcpy(buf[tx_buf_response..][0..header_len], &response);
    try setDesc(ram, tx_desc, 1, tx_buf_response, header_len, 0);
    try pushAvail(ram, tx_avail, 8, 1);
    try std.testing.expect(t.write(0x050, tx_queue, ram));
    try std.testing.expectEqual(HostStreamState.connected, stream.state);
    try std.testing.expectEqual(@as(usize, 1), capture.ready_count);
    try std.testing.expectEqual(@as(u16, 3), try ram.read(u16, rx_used + 2));

    const delivered = parseHeader(buf[rx_buf_payload..][0..header_len]);
    try std.testing.expectEqual(op_rw, delivered.op);
    try std.testing.expectEqual(@as(u32, @intCast(request.len)), delivered.len);
    try std.testing.expectEqualStrings(request, buf[rx_buf_payload + header_len ..][0..request.len]);

    const stdout_frame = "stdout 0 6\nhello\n";
    var stdout_rw: [header_len]u8 = undefined;
    writeHeader(&stdout_rw, .{
        .src_cid = default_guest_cid,
        .dst_cid = host_cid,
        .src_port = 10700,
        .dst_port = default_host_port,
        .len = @intCast(stdout_frame.len),
        .packet_type = packet_type_stream,
        .op = op_rw,
    });
    @memcpy(buf[tx_buf_stdout..][0..header_len], &stdout_rw);
    @memcpy(buf[tx_buf_stdout + header_len ..][0..stdout_frame.len], stdout_frame);
    try setDesc(ram, tx_desc, 2, tx_buf_stdout, @intCast(header_len + stdout_frame.len), 0);
    try pushAvail(ram, tx_avail, 8, 2);
    try std.testing.expect(t.write(0x050, tx_queue, ram));

    const stderr_frame = "stderr 0 4\nerr\n";
    var stderr_rw: [header_len]u8 = undefined;
    writeHeader(&stderr_rw, .{
        .src_cid = default_guest_cid,
        .dst_cid = host_cid,
        .src_port = 10700,
        .dst_port = default_host_port,
        .len = @intCast(stderr_frame.len),
        .packet_type = packet_type_stream,
        .op = op_rw,
    });
    @memcpy(buf[tx_buf_stderr..][0..header_len], &stderr_rw);
    @memcpy(buf[tx_buf_stderr + header_len ..][0..stderr_frame.len], stderr_frame);
    try setDesc(ram, tx_desc, 3, tx_buf_stderr, @intCast(header_len + stderr_frame.len), 0);
    try pushAvail(ram, tx_avail, 8, 3);
    try std.testing.expect(t.write(0x050, tx_queue, ram));

    const exit_frame = "exit 7\n";
    var rw: [header_len]u8 = undefined;
    writeHeader(&rw, .{
        .src_cid = default_guest_cid,
        .dst_cid = host_cid,
        .src_port = 10700,
        .dst_port = default_host_port,
        .len = @intCast(exit_frame.len),
        .packet_type = packet_type_stream,
        .op = op_rw,
    });
    @memcpy(buf[tx_buf_exit..][0..header_len], &rw);
    @memcpy(buf[tx_buf_exit + header_len ..][0..exit_frame.len], exit_frame);
    try setDesc(ram, tx_desc, 4, tx_buf_exit, @intCast(header_len + exit_frame.len), 0);
    try pushAvail(ram, tx_avail, 8, 4);
    try std.testing.expect(t.write(0x050, tx_queue, ram));

    try std.testing.expectEqual(HostStreamState.complete, stream.state);
    try std.testing.expectEqual(@as(i32, 7), stream.exit_code.?);
    try std.testing.expectEqualStrings("hello\n", capture.stdout[0..capture.stdout_len]);
    try std.testing.expectEqualStrings("err\n", capture.stderr[0..capture.stderr_len]);
}

test "rx delivery splits stream data across small guest buffers" {
    var dev = Vsock.init(.{ .guest_cid = default_guest_cid });
    var t = mmio.Transport.init(dev.device());
    var buf: [32 * 1024]u8 = [_]u8{0} ** (32 * 1024);
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    const rx_desc = 0x000;
    const rx_avail = 0x400;
    const rx_used = 0x800;
    const rx_bufs = 0x2000;
    // Each guest receive buffer only has room for the packet header plus 100
    // payload bytes, mirroring guests whose receive buffers are smaller than
    // one full host frame.
    const rx_buf_len: u32 = header_len + 100;

    configureQueue(&t, rx_queue, rx_desc, rx_avail, rx_used, ram);

    var stream = try HostStream.init(10700, "{}\n");
    stream.state = .connected;
    dev.host_stream = &stream;

    var payload: [250]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);
    try dev.enqueueHostPacket(&stream, op_rw, &payload);

    var i: u16 = 0;
    while (i < 3) : (i += 1) {
        try setDesc(ram, rx_desc, i, rx_bufs + @as(u64, i) * 0x200, rx_buf_len, 2); // VIRTQ_DESC_F_WRITE
        try pushAvail(ram, rx_avail, 8, i);
    }
    try std.testing.expect(t.write(0x050, rx_queue, ram));

    // All three buffers hold one op_rw fragment each; nothing is dropped.
    try std.testing.expectEqual(@as(u16, 3), try ram.read(u16, rx_used + 2));

    var received: [250]u8 = undefined;
    var received_len: usize = 0;
    i = 0;
    while (i < 3) : (i += 1) {
        const base = rx_bufs + @as(u64, i) * 0x200;
        const fragment = parseHeader(buf[base..][0..header_len]);
        try std.testing.expectEqual(op_rw, fragment.op);
        try std.testing.expectEqual(host_cid, fragment.src_cid);
        try std.testing.expectEqual(default_guest_cid, fragment.dst_cid);
        const fragment_len: usize = @intCast(fragment.len);
        try std.testing.expect(fragment_len > 0);
        try std.testing.expect(received_len + fragment_len <= payload.len);
        @memcpy(received[received_len..][0..fragment_len], buf[base + header_len ..][0..fragment_len]);
        received_len += fragment_len;
    }
    try std.testing.expectEqual(payload.len, received_len);
    try std.testing.expectEqualSlices(u8, &payload, &received);
    try std.testing.expectEqual(@as(usize, 0), dev.pending_len);
}

test "rx delivery makes no empty fragments for header-only guest buffers" {
    var dev = Vsock.init(.{ .guest_cid = default_guest_cid });
    var t = mmio.Transport.init(dev.device());
    var buf: [32 * 1024]u8 = [_]u8{0} ** (32 * 1024);
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    const rx_desc = 0x000;
    const rx_avail = 0x400;
    const rx_used = 0x800;
    const rx_buf_tiny = 0x2000;
    const rx_buf_ok = 0x2200;

    configureQueue(&t, rx_queue, rx_desc, rx_avail, rx_used, ram);

    var stream = try HostStream.init(10700, "{}\n");
    stream.state = .connected;
    dev.host_stream = &stream;

    try dev.enqueueHostPacket(&stream, op_rw, "hello");

    // A buffer holding exactly the packet header would only fit an empty
    // fragment; the packet must stay pending until a useful buffer arrives.
    try setDesc(ram, rx_desc, 0, rx_buf_tiny, header_len, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 0);
    try setDesc(ram, rx_desc, 1, rx_buf_ok, header_len + 5, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 1);
    try std.testing.expect(t.write(0x050, rx_queue, ram));

    try std.testing.expectEqual(@as(u16, 2), try ram.read(u16, rx_used + 2));
    const delivered = parseHeader(buf[rx_buf_ok..][0..header_len]);
    try std.testing.expectEqual(op_rw, delivered.op);
    try std.testing.expectEqual(@as(u32, 5), delivered.len);
    try std.testing.expectEqualStrings("hello", buf[rx_buf_ok + header_len ..][0..5]);
    try std.testing.expectEqual(@as(usize, 0), dev.pending_len);
}

test "rx delivery keeps packets pending when a guest buffer cannot hold the header" {
    var dev = Vsock.init(.{ .guest_cid = default_guest_cid });
    var t = mmio.Transport.init(dev.device());
    var buf: [32 * 1024]u8 = [_]u8{0} ** (32 * 1024);
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    const rx_desc = 0x000;
    const rx_avail = 0x400;
    const rx_used = 0x800;
    const rx_buf_small = 0x2000;
    const rx_buf_ok = 0x2200;

    configureQueue(&t, rx_queue, rx_desc, rx_avail, rx_used, ram);

    var stream = try HostStream.init(10700, "{}\n");
    stream.state = .connected;
    dev.host_stream = &stream;

    try dev.enqueueHostPacket(&stream, op_rw, "hello");

    // First buffer cannot even hold the 44-byte packet header; the packet must
    // survive and land in the next adequate buffer.
    try setDesc(ram, rx_desc, 0, rx_buf_small, header_len - 1, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 0);
    try setDesc(ram, rx_desc, 1, rx_buf_ok, header_len + 5, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 1);
    try std.testing.expect(t.write(0x050, rx_queue, ram));

    try std.testing.expectEqual(@as(u16, 2), try ram.read(u16, rx_used + 2));
    const delivered = parseHeader(buf[rx_buf_ok..][0..header_len]);
    try std.testing.expectEqual(op_rw, delivered.op);
    try std.testing.expectEqual(@as(u32, 5), delivered.len);
    try std.testing.expectEqualStrings("hello", buf[rx_buf_ok + header_len ..][0..5]);
    try std.testing.expectEqual(@as(usize, 0), dev.pending_len);
}

test "host proactively updates credit while consuming guest stream data" {
    var dev = Vsock.init(.{ .guest_cid = default_guest_cid });
    var t = mmio.Transport.init(dev.device());
    var buf = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(buf);
    @memset(buf, 0);
    const ram = guestmem.GuestRam{ .bytes = buf, .base = 0 };

    const rx_desc = 0x000;
    const rx_avail = 0x400;
    const rx_used = 0x800;
    const tx_desc = 0x1000;
    const tx_avail = 0x1400;
    const tx_used = 0x1800;
    const rx_buf = 0x2000;
    const tx_buf = 0x2200;

    configureQueue(&t, rx_queue, rx_desc, rx_avail, rx_used, ram);
    configureQueue(&t, tx_queue, tx_desc, tx_avail, tx_used, ram);

    var stream = try HostStream.init(10700, "{}\n");
    stream.state = .connected;
    dev.host_stream = &stream;

    // 16-byte lines the legacy frame parser consumes without failing.
    const line = "timing 12345678\n";
    var payload: [4096]u8 = undefined;
    var off: usize = 0;
    while (off < payload.len) : (off += line.len) {
        @memcpy(payload[off..][0..line.len], line);
    }

    // The guest sends half the advertised credit without the host ever writing
    // back; the host must volunteer a credit update or the guest stalls.
    var header: [header_len]u8 = undefined;
    var sent: usize = 0;
    var head: u16 = 0;
    while (sent < host_stream_credit / 2) : (head += 1) {
        writeHeader(&header, .{
            .src_cid = default_guest_cid,
            .dst_cid = host_cid,
            .src_port = 10700,
            .dst_port = default_host_port,
            .len = payload.len,
            .packet_type = packet_type_stream,
            .op = op_rw,
        });
        @memcpy(buf[tx_buf..][0..header_len], &header);
        @memcpy(buf[tx_buf + header_len ..][0..payload.len], &payload);
        try setDesc(ram, tx_desc, head % 8, tx_buf, header_len + payload.len, 0);
        try pushAvail(ram, tx_avail, 8, head % 8);
        try std.testing.expect(t.write(0x050, tx_queue, ram));
        sent += payload.len;
    }
    try std.testing.expectEqual(HostStreamState.connected, stream.state);

    try setDesc(ram, rx_desc, 0, rx_buf, header_len, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 0);
    try std.testing.expect(t.write(0x050, rx_queue, ram));

    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, rx_used + 2));
    const update = parseHeader(buf[rx_buf..][0..header_len]);
    try std.testing.expectEqual(op_credit_update, update.op);
    try std.testing.expectEqual(@as(u32, host_stream_credit), update.buf_alloc);
    try std.testing.expectEqual(@as(u32, host_stream_credit / 2), update.fwd_cnt);
}

test "host defers stream data until the guest advertises credit" {
    var dev = Vsock.init(.{ .guest_cid = default_guest_cid });
    var t = mmio.Transport.init(dev.device());
    var buf: [32 * 1024]u8 = [_]u8{0} ** (32 * 1024);
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    const rx_desc = 0x000;
    const rx_avail = 0x400;
    const rx_used = 0x800;
    const tx_desc = 0x1000;
    const tx_avail = 0x1400;
    const tx_used = 0x1800;
    const rx_buf = 0x2000;
    const rx_buf_second = 0x2400;
    const tx_buf = 0x2800;

    configureQueue(&t, rx_queue, rx_desc, rx_avail, rx_used, ram);
    configureQueue(&t, tx_queue, tx_desc, tx_avail, tx_used, ram);

    var stream = try HostStream.init(10700, "{}\n");
    stream.state = .connected;
    stream.request_sent = true;
    // The guest has advertised only 8 bytes of receive buffer.
    stream.peer_buf_alloc = 8;
    dev.host_stream = &stream;

    var stop = std.atomic.Value(bool).init(false);
    try std.testing.expect(try stream.enqueueStdinDataBlocking("hello", &stop));

    try setDesc(ram, rx_desc, 0, rx_buf, 0x200, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 0);
    _ = t.write(0x050, rx_queue, ram);
    _ = try dev.flushHostStreamOutbound();
    _ = t.write(0x050, rx_queue, ram);

    // The stdin frame exceeds the guest's window, so nothing may be sent yet.
    try std.testing.expectEqual(@as(u16, 0), try ram.read(u16, rx_used + 2));

    // The guest consumes its buffer and advertises a realistic window.
    var credit: [header_len]u8 = undefined;
    writeHeader(&credit, .{
        .src_cid = default_guest_cid,
        .dst_cid = host_cid,
        .src_port = 10700,
        .dst_port = default_host_port,
        .len = 0,
        .packet_type = packet_type_stream,
        .op = op_credit_update,
        .buf_alloc = 64 * 1024,
        .fwd_cnt = 0,
    });
    @memcpy(buf[tx_buf..][0..header_len], &credit);
    try setDesc(ram, tx_desc, 0, tx_buf, header_len, 0);
    try pushAvail(ram, tx_avail, 8, 0);
    try setDesc(ram, rx_desc, 1, rx_buf_second, 0x200, 2); // VIRTQ_DESC_F_WRITE
    try pushAvail(ram, rx_avail, 8, 1);
    try std.testing.expect(t.write(0x050, tx_queue, ram));

    try std.testing.expectEqual(@as(u16, 1), try ram.read(u16, rx_used + 2));
    const delivered = parseHeader(buf[rx_buf..][0..header_len]);
    try std.testing.expectEqual(op_rw, delivered.op);
    const frame_len = spore_stream.header_len + 5;
    try std.testing.expectEqual(@as(u32, frame_len), delivered.len);
    try std.testing.expectEqualStrings("hello", buf[rx_buf + header_len + spore_stream.header_len ..][0..5]);
}

test "request-derived host ports are stable dynamic ports" {
    const first = HostStream.deriveHostPort("{\"session_id\":\"run-a\"}\n");
    const again = HostStream.deriveHostPort("{\"session_id\":\"run-a\"}\n");
    const second = HostStream.deriveHostPort("{\"session_id\":\"run-b\"}\n");

    try std.testing.expect(first >= dynamic_host_port_first);
    try std.testing.expect(first < dynamic_host_port_first + dynamic_host_port_count);
    try std.testing.expectEqual(first, again);
    try std.testing.expect(first != second);
}

test "host stream sequences dynamic host ports without early reuse" {
    try std.testing.expectEqual(dynamic_host_port_first, HostStream.hostPortForSequence(0));
    try std.testing.expectEqual(dynamic_host_port_first + 1, HostStream.hostPortForSequence(1));
    try std.testing.expectEqual(dynamic_host_port_first, HostStream.hostPortForSequence(dynamic_host_port_count));
}

test "host stream frame parser handles split frames" {
    var stream = try HostStream.init(10700, "{}\n");
    var capture = StreamCapture{};
    stream.state = .connected;
    stream.setOutputSink(&capture, captureSink);

    stream.appendOutput("stdout 0 11\nhello");
    try std.testing.expectEqual(HostStreamState.connected, stream.state);
    stream.appendOutput(" worldmemory-pressure\nstderr 0 4\n");
    stream.appendOutput("err\nexit 3\n");

    try std.testing.expectEqual(HostStreamState.complete, stream.state);
    try std.testing.expectEqual(@as(i32, 3), stream.exit_code.?);
    try std.testing.expect(stream.memory_pressure_ms != null);
    try std.testing.expectEqual(@as(u32, 1), stream.memory_pressure_count);
    try std.testing.expectEqualStrings("hello world", capture.stdout[0..capture.stdout_len]);
    try std.testing.expectEqualStrings("err\n", capture.stderr[0..capture.stderr_len]);
}

test "host stream frame parser counts memory pressure frames" {
    var stream = try HostStream.init(10700, "{}\n");
    stream.state = .connected;

    stream.appendOutput("memory-pressure\nmemory-pressure\n");

    try std.testing.expectEqual(@as(u32, 2), stream.memory_pressure_count);
}

test "host stream frame parser is independent of two-part packetization" {
    const frames = "stdout 0 5\nhello" ++
        "stderr 0 4\nwarn" ++
        "exit 9\n";

    var split: usize = 0;
    while (split <= frames.len) : (split += 1) {
        var stream = try HostStream.init(10700, "{}\n");
        var capture = StreamCapture{};
        stream.state = .connected;
        stream.setOutputSink(&capture, captureSink);

        stream.appendOutput(frames[0..split]);
        stream.appendOutput(frames[split..]);

        try std.testing.expectEqual(HostStreamState.complete, stream.state);
        try std.testing.expectEqual(@as(i32, 9), stream.exit_code.?);
        try std.testing.expectEqualStrings("hello", capture.stdout[0..capture.stdout_len]);
        try std.testing.expectEqualStrings("warn", capture.stderr[0..capture.stderr_len]);
    }
}

test "host stream frame parser rejects offset mismatch" {
    var stream = try HostStream.init(10700, "{}\n");
    stream.state = .connected;

    stream.appendOutput("stdout 1 1\nx");

    try std.testing.expectEqual(HostStreamState.failed, stream.state);
}

test "host stream frame parser rejects oversized payloads" {
    var stream = try HostStream.init(10700, "{}\n");
    stream.state = .connected;

    stream.appendOutput("stderr 0 65537\n");

    try std.testing.expectEqual(HostStreamState.failed, stream.state);
}

fn fuzzVsockTx(_: void, s: *std.testing.Smith) !void {
    var dev = Vsock.init(.{});
    var t = mmio.Transport.init(dev.device());
    var buf: [4096]u8 = [_]u8{0} ** 4096;
    _ = s.slice(&buf);
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };
    t.queues[rx_queue] = .{ .size = 8, .ready = true, .desc_addr = 0x1000, .avail_addr = 0x1200, .used_addr = 0x1400 };
    t.queues[tx_queue] = .{ .size = 8, .ready = true, .desc_addr = 0x0000, .avail_addr = 0x0400, .used_addr = 0x0800 };
    _ = t.write(0x050, tx_queue, ram);
}

test "fuzz vsock tx handling" {
    try std.testing.fuzz({}, fuzzVsockTx, .{});
}

fn fuzzVsockRxDelivery(_: void, s: *std.testing.Smith) !void {
    var dev = Vsock.init(.{});
    var t = mmio.Transport.init(dev.device());
    var buf: [8192]u8 = [_]u8{0} ** 8192;
    _ = s.slice(&buf);
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };
    t.queues[rx_queue] = .{ .size = 8, .ready = true, .desc_addr = 0x1000, .avail_addr = 0x1200, .used_addr = 0x1400 };
    t.queues[tx_queue] = .{ .size = 8, .ready = true, .desc_addr = 0x0000, .avail_addr = 0x0400, .used_addr = 0x0800 };

    var stream = HostStream.init(10700, "{}\n") catch return;
    stream.state = .connected;
    dev.host_stream = &stream;

    var payload: [max_payload]u8 = undefined;
    const payload_len: usize = s.valueRangeAtMost(u16, 0, max_payload);
    @memset(payload[0..payload_len], 0xa5);
    dev.enqueueHostPacket(&stream, op_rw, payload[0..payload_len]) catch return;

    // Guest-controlled descriptor layouts drive the RX split path.
    _ = t.write(0x050, rx_queue, ram);
    _ = t.write(0x050, rx_queue, ram);
}

test "fuzz vsock rx delivery splitting" {
    try std.testing.fuzz({}, fuzzVsockRxDelivery, .{});
}

fn fuzzHostStreamFrames(_: void, s: *std.testing.Smith) !void {
    var stream = try HostStream.init(10700, "{}\n");
    stream.state = .connected;
    var buf: [4096]u8 = undefined;
    const len = s.slice(&buf);
    stream.appendOutput(buf[0..len]);
}

test "fuzz host stream frame parsing" {
    try std.testing.fuzz({}, fuzzHostStreamFrames, .{});
}

fn fuzzHostStreamV1Frames(_: void, s: *std.testing.Smith) !void {
    var stream = try HostStream.initWithProtocol(10700, "{}\n", .spore_stream_v1);
    stream.state = .connected;
    var buf: [4096]u8 = undefined;
    const len = s.slice(&buf);
    stream.appendOutput(buf[0..len]);
}

test "fuzz host stream v1 frame parsing" {
    try std.testing.fuzz({}, fuzzHostStreamV1Frames, .{});
}
