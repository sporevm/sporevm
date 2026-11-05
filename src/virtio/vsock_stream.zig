//! Host end of the exec stream: one host-initiated virtio-vsock stream
//! connection to the guest agent. It holds the request the host sends, the
//! credit state the vsock device drives, queued stdin and terminal frames, and
//! the parser for the guest's framed output (legacy text or SPIO v1). Output
//! bytes are guest controlled. See SECURITY.md.

const std = @import("std");
const spore_stream = @import("../spore_stream.zig");
const vsock = @import("vsock.zig");

/// Port the host uses when a caller does not pick one.
pub const default_host_port: u32 = 49152;
const dynamic_host_port_first: u32 = 49154;
const dynamic_host_port_count: u32 = 65535 - dynamic_host_port_first + 1;
const max_frame_header = 128;
const max_frame_payload = 64 * 1024;
const max_outbound_frames = 16;
const max_v1_control_payload = 512;
const max_payload = vsock.max_payload;

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

const HostStreamStartState = enum(u8) {
    pending,
    started,
    timed_out,
};

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
    start_state: std.atomic.Value(HostStreamStartState) = .init(.pending),
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
    guest_accept_ms: ?u64 = null,
    guest_spawn_ms: ?u64 = null,
    guest_exit_ms: ?u64 = null,
    guest_now_ms: ?u64 = null,
    guest_user_cpu_us: ?u64 = null,
    guest_system_cpu_us: ?u64 = null,
    backend_restore_memory_ms: ?u64 = null,
    backend_restore_state_ms: ?u64 = null,
    backend_restore_pre_run_ms: ?u64 = null,
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
    /// Latest terminal size waiting for an outbound slot; guarded by
    /// `outbound_lock` and only set while the ring is full.
    pending_resize: ?spore_stream.Resize = null,
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
        _ = self.start_state.cmpxchgStrong(.pending, .started, .release, .monotonic);
    }

    pub fn hasStarted(self: *const HostStream) bool {
        return self.start_state.load(.acquire) == .started;
    }

    pub fn claimStartTimeout(self: *HostStream) bool {
        return self.start_state.cmpxchgStrong(.pending, .timed_out, .acq_rel, .acquire) == null;
    }

    pub fn setBackendRestoreMetrics(self: *HostStream, memory_ms: u64, state_ms: u64, pre_run_ms: u64) void {
        self.backend_restore_memory_ms = memory_ms;
        self.backend_restore_state_ms = state_ms;
        self.backend_restore_pre_run_ms = pre_run_ms;
    }

    pub fn markAttached(self: *HostStream) void {
        if (self.attach_ms == null) self.attach_ms = self.elapsedMs();
    }

    pub fn markConnectRequestDelivered(self: *HostStream) void {
        if (self.connect_request_delivered_ms == null) self.connect_request_delivered_ms = self.elapsedMs();
    }

    pub fn markRequestDelivered(self: *HostStream) void {
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

    pub fn markConnected(self: *HostStream) void {
        if (self.connect_ms == null) self.connect_ms = self.elapsedMs();
        self.state = .connected;
        if (self.lifecycle_sink) |sink| sink(self.lifecycle_sink_context, .ready);
    }

    pub fn appendOutput(self: *HostStream, data: []const u8) void {
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
            self.recordGuestTiming(line);
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
                    self.recordGuestTiming(payload);
                } else {
                    self.fail();
                }
            },
            .err => self.fail(),
            .resize, .signal => self.fail(),
        }
    }

    fn recordGuestTiming(self: *HostStream, payload: []const u8) void {
        if (self.guest_timing_ms == null) self.guest_timing_ms = self.elapsedMs();
        parseGuestTiming(payload, self);
        std.log.debug("vsock host stream guest timing: {s}", .{payload});
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

    /// Queues a terminal resize without waiting for ring space. Callers may
    /// hold the VMM device lock, which every path that drains the ring also
    /// takes, so this must never block. Resize is idempotent: while the ring
    /// is full only the latest size is kept, and it takes the next free slot.
    pub fn enqueueResize(self: *HostStream, resize: spore_stream.Resize) bool {
        if (self.state == .complete or self.state == .failed) return false;
        self.outbound_lock.lock();
        defer self.outbound_lock.unlock();
        self.pending_resize = resize;
        self.queuePendingResizeLocked();
        return true;
    }

    fn queuePendingResizeLocked(self: *HostStream) void {
        const resize = self.pending_resize orelse return;
        if (self.outbound_count >= self.outbound_frames.len) return;
        const frame = &self.outbound_frames[(self.outbound_head + self.outbound_count) % self.outbound_frames.len];
        spore_stream.writeHeader(frame.data[0..spore_stream.header_len], .{
            .frame_type = .resize,
            .stream_id = .terminal,
            .payload_len = 4,
        });
        spore_stream.writeResizePayload(frame.data[spore_stream.header_len..][0..4], resize);
        frame.len = spore_stream.header_len + 4;
        self.outbound_count += 1;
        self.pending_resize = null;
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
    pub fn dequeueOutboundWithin(self: *HostStream, out: *[max_payload]u8, limit: usize) ?[]const u8 {
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
        self.queuePendingResizeLocked();
        return out[0..len];
    }

    /// Bytes the guest can still accept: its advertised receive buffer minus
    /// stream data the host has sent that the guest has not yet consumed.
    pub fn txWindowFree(self: *const HostStream) u32 {
        const inflight = self.sent_bytes -% self.peer_fwd_cnt;
        if (inflight >= self.peer_buf_alloc) return 0;
        return self.peer_buf_alloc - inflight;
    }

    pub fn fail(self: *HostStream) void {
        self.state = .failed;
        if (self.response_ms == null) self.response_ms = self.elapsedMs();
    }
};

fn parseGuestTiming(payload: []const u8, stream: *HostStream) void {
    var fields = std.mem.splitScalar(u8, payload, ' ');
    if (!std.mem.eql(u8, fields.next() orelse return, "timing")) return;
    while (fields.next()) |field| {
        const separator = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        if (separator == 0 or separator + 1 >= field.len) continue;
        const value = std.fmt.parseInt(i64, field[separator + 1 ..], 10) catch continue;
        if (value < 0) continue;
        const unsigned: u64 = @intCast(value);
        const key = field[0..separator];
        if (std.mem.eql(u8, key, "accept")) {
            stream.guest_accept_ms = unsigned;
        } else if (std.mem.eql(u8, key, "spawn")) {
            stream.guest_spawn_ms = unsigned;
        } else if (std.mem.eql(u8, key, "exit")) {
            stream.guest_exit_ms = unsigned;
        } else if (std.mem.eql(u8, key, "now")) {
            stream.guest_now_ms = unsigned;
        } else if (std.mem.eql(u8, key, "user_us")) {
            stream.guest_user_cpu_us = unsigned;
        } else if (std.mem.eql(u8, key, "system_us")) {
            stream.guest_system_cpu_us = unsigned;
        }
    }
}

fn monotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

// --- tests ------------------------------------------------------------------

/// Output and lifecycle capture shared with the vsock device tests.
pub const StreamCapture = struct {
    stdout: [64]u8 = [_]u8{0} ** 64,
    stderr: [64]u8 = [_]u8{0} ** 64,
    terminal: [64]u8 = [_]u8{0} ** 64,
    stdout_len: usize = 0,
    stderr_len: usize = 0,
    terminal_len: usize = 0,
    ready_count: usize = 0,
};

pub fn captureSink(context: ?*anyopaque, output: HostStreamOutput, bytes: []const u8) void {
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

pub fn lifecycleSink(context: ?*anyopaque, event: HostStreamLifecycle) void {
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
    try appendV1Frame(&stream, .event, .control, 0, "timing listen=1 accept=2 decode=3 spawn=4 exit=5 now=6 user_us=7000 system_us=8000");
    var exit_payload: [4]u8 = undefined;
    spore_stream.writeExitPayload(&exit_payload, 7);
    try appendV1Frame(&stream, .exit, .control, 0, &exit_payload);

    try std.testing.expectEqual(HostStreamState.complete, stream.state);
    try std.testing.expectEqual(@as(i32, 7), stream.exit_code.?);
    try std.testing.expectEqual(@as(u32, 1), stream.memory_pressure_count);
    try std.testing.expect(stream.guest_timing_ms != null);
    try std.testing.expectEqual(@as(u64, 2), stream.guest_accept_ms.?);
    try std.testing.expectEqual(@as(u64, 4), stream.guest_spawn_ms.?);
    try std.testing.expectEqual(@as(u64, 5), stream.guest_exit_ms.?);
    try std.testing.expectEqual(@as(u64, 7_000), stream.guest_user_cpu_us.?);
    try std.testing.expectEqual(@as(u64, 8_000), stream.guest_system_cpu_us.?);
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
    try std.testing.expect(stream.enqueueResize(.{ .rows = 40, .cols = 120 }));
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

test "host stream resize does not wait for a full outbound ring and sends the latest size" {
    var stream = try HostStream.initWithProtocol(10700, "{}\n", .spore_stream_v1);
    for (0..max_outbound_frames) |_| {
        try std.testing.expectEqual(@as(usize, 1), try stream.enqueueStdinDataNonblocking("x"));
    }
    // Resizes are queued under the VMM device lock, which every ring drainer
    // also needs, so a full ring must coalesce instead of waiting.
    try std.testing.expect(stream.enqueueResize(.{ .rows = 30, .cols = 100 }));
    try std.testing.expect(stream.enqueueResize(.{ .rows = 40, .cols = 120 }));

    var payload_buf: [max_payload]u8 = undefined;
    var header_buf: [spore_stream.header_len]u8 = undefined;
    for (0..max_outbound_frames) |_| {
        const frame = stream.dequeueOutboundWithin(&payload_buf, max_payload).?;
        @memcpy(&header_buf, frame[0..spore_stream.header_len]);
        try std.testing.expectEqual(spore_stream.FrameType.data, (try spore_stream.readHeader(&header_buf)).frame_type);
    }
    const resize_frame = stream.dequeueOutboundWithin(&payload_buf, max_payload).?;
    @memcpy(&header_buf, resize_frame[0..spore_stream.header_len]);
    const resize_header = try spore_stream.readHeader(&header_buf);
    try std.testing.expectEqual(spore_stream.FrameType.resize, resize_header.frame_type);
    try std.testing.expectEqual(spore_stream.StreamId.terminal, resize_header.stream_id);
    const resize = try spore_stream.readResizePayload(resize_frame[spore_stream.header_len..]);
    try std.testing.expectEqual(@as(u16, 40), resize.rows);
    try std.testing.expectEqual(@as(u16, 120), resize.cols);
    try std.testing.expect(stream.dequeueOutboundWithin(&payload_buf, max_payload) == null);
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

fn fuzzGuestTimingEvent(_: void, s: *std.testing.Smith) !void {
    var bytes: [512]u8 = undefined;
    const len = s.slice(&bytes);
    var stream = try HostStream.init(10700, "{}\n");
    parseGuestTiming(bytes[0..len], &stream);

    var tail: [480]u8 = undefined;
    const tail_len = s.slice(&tail);
    var prefixed: ["timing ".len + tail.len]u8 = undefined;
    @memcpy(prefixed[0.."timing ".len], "timing ");
    @memcpy(prefixed["timing ".len..][0..tail_len], tail[0..tail_len]);
    parseGuestTiming(prefixed[0 .. "timing ".len + tail_len], &stream);
}

test "fuzz guest timing event parsing" {
    try std.testing.fuzz({}, fuzzGuestTimingEvent, .{});
}
