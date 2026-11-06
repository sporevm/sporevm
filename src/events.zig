//! What `spore run`, `attach` and the other commands report: the run result,
//! the `--events=jsonl` records, and how an error maps to a failure code.

const std = @import("std");
const Io = std.Io;

const Backend = @import("backend.zig").Backend;
const machine_output = @import("machine_output.zig");
const memory_config = @import("memory.zig");
const net_gateway = @import("net_gateway.zig");
const ram_restore = @import("ram_restore.zig");
const saved_spore_ownership = @import("saved_spore_ownership.zig");
const spore_net_policy = @import("spore_net_policy.zig");
const topology = @import("topology.zig");
const vsock_stream = @import("virtio/vsock_stream.zig");

pub const TerminalOutcome = enum {
    completed,
    failed,
    canceled,
};

pub const EventMode = enum {
    none,
    jsonl,

    pub fn parse(raw: []const u8) ?EventMode {
        if (std.mem.eql(u8, raw, "jsonl")) return .jsonl;
        return null;
    }
};

pub const Result = struct {
    schema: []const u8 = "spore.run.result.v1",
    schema_version: u32 = 1,
    backend: Backend,
    start_ms: u64,
    vsock_connect_ms: u64,
    exec_response_ms: u64,
    probe_duration_ms: u64,
    exit_code: i32,
    vcpus: topology.VcpuCount,
    /// Initial guest-visible memory.
    memory_bytes: u64,
    /// Maximum guest-visible memory; equal to `memory_bytes` for fixed VMs.
    max_memory_bytes: u64,
    saved: bool = false,
    committed: bool = false,
    save_path: ?[]const u8 = null,
    save_ownership: ?[]const u8 = null,
    /// Product restore RAM source, such as `local_backing` or `chunks`.
    memory_restore_source: ?[]const u8 = null,
    /// Product restore planner reason, such as `proof_valid` or `proof_unavailable`.
    memory_restore_reason: ?[]const u8 = null,

    pub fn processExitCode(self: Result) u8 {
        std.debug.assert(self.exit_code >= 0 and self.exit_code <= 255);
        return @intCast(self.exit_code);
    }

    pub fn withMemoryRestore(self: Result, plan: *const ram_restore.Plan) Result {
        var result = self;
        result.memory_restore_source = @tagName(plan.restoreSource().?);
        result.memory_restore_reason = @tagName(plan.reason);
        return result;
    }
};

pub const Timings = struct {
    start_ms: u64,
    vsock_connect_ms: u64,
    exec_response_ms: u64,
    probe_duration_ms: u64,
};

pub const StartEvent = struct {
    command: []const u8,
    requested_backend: Backend,
};

pub const ReadyEvent = struct {
    command: []const u8,
    backend: ?Backend,
};

pub const OutputEvent = struct {
    command: []const u8,
    backend: ?Backend,
    offset: u64,
    bytes: []const u8,
};

pub const PortForwardKind = enum {
    bound_unix_service,

    pub fn name(self: PortForwardKind) []const u8 {
        return switch (self) {
            .bound_unix_service => "bound_unix_service",
        };
    }
};

pub const PortForwardEvent = struct {
    command: []const u8,
    backend: ?Backend,
    kind: PortForwardKind,
    name: []const u8,
    guest_host: ?[]const u8,
    guest_port: u16,
    target: []const u8,
};

pub const SaveEvent = struct {
    command: []const u8,
    backend: Backend,
    save_path: []const u8,
    ownership: []const u8,
};

pub const ImageCommitEvent = struct {
    command: []const u8,
    backend: Backend,
    ref: []const u8,
    resolved_image_ref: []const u8,
    rootfs_index_digest: []const u8,
};

pub const ExitEvent = struct {
    command: []const u8,
    backend: Backend,
    exit_code: i32,
    vcpus: topology.VcpuCount,
    memory_bytes: u64,
    max_memory_bytes: u64,
    saved: bool = false,
    save_path: ?[]const u8 = null,
    save_ownership: ?[]const u8 = null,
    memory_restore_source: ?[]const u8 = null,
    memory_restore_reason: ?[]const u8 = null,
    timings: Timings,
};

pub const FailureEvent = struct {
    command: []const u8,
    backend: ?Backend,
    classified: machine_output.CliError,
};

/// Runtime lifecycle events delivered synchronously to EventSink.
/// Output bytes are callback-scoped. Ready is emitted at most once, and exit or
/// failure is emitted at most once as the terminal completion event. Exit means
/// the guest operation completed, including a non-zero guest exit code.
pub const RunEvent = union(enum) {
    start: StartEvent,
    ready: ReadyEvent,
    port_forward: PortForwardEvent,
    network: NetworkAuditEvent,
    stdout: OutputEvent,
    stderr: OutputEvent,
    terminal: OutputEvent,
    save: SaveEvent,
    image_commit: ImageCommitEvent,
    exit: ExitEvent,
    failure: FailureEvent,
};

pub const NetworkAuditKind = enum {
    egress_denied,

    pub fn name(self: NetworkAuditKind) []const u8 {
        return switch (self) {
            .egress_denied => "egress_denied",
        };
    }
};

pub const NetworkAuditEvent = struct {
    command: []const u8,
    backend: ?Backend,
    kind: NetworkAuditKind,
    destination_ip: [4]u8,
    destination_port: u16,
    reason: []const u8,
};

/// Callback interface for run/resume lifecycle consumers. If the sink fails
/// while relaying guest output or readiness, execution records the failure and
/// returns error.EventSinkFailed after the terminal event path completes.
pub const EventSink = struct {
    context: ?*anyopaque = null,
    emitFn: *const fn (?*anyopaque, RunEvent) anyerror!void,

    pub fn emit(self: EventSink, event: RunEvent) !void {
        try self.emitFn(self.context, event);
    }
};

pub const EventEmitter = struct {
    sink: ?EventSink,
    command: []const u8,
    backend: ?Backend = null,
    ready_emitted: bool = false,
    terminal_emitted: bool = false,
    stdout_offset: u64 = 0,
    stderr_offset: u64 = 0,
    terminal_offset: u64 = 0,
    write_failed: bool = false,

    pub fn init(sink: ?EventSink, command: []const u8) EventEmitter {
        return .{ .sink = sink, .command = command };
    }

    pub fn emitStart(self: *EventEmitter, requested_backend: Backend) !void {
        if (self.sink) |sink| try sink.emit(.{ .start = .{ .command = self.command, .requested_backend = requested_backend } });
    }

    pub fn setBackend(self: *EventEmitter, backend: Backend) void {
        self.backend = backend;
    }

    pub fn emitReady(self: *EventEmitter) !void {
        if (self.ready_emitted) return;
        self.ready_emitted = true;
        if (self.sink) |sink| try sink.emit(.{ .ready = .{ .command = self.command, .backend = self.backend } });
    }

    pub fn emitOutput(self: *EventEmitter, output: vsock_stream.HostStreamOutput, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.emitReady();
        const offset = switch (output) {
            .stdout => self.stdout_offset,
            .stderr => self.stderr_offset,
            .terminal => self.terminal_offset,
        };
        const event: RunEvent = switch (output) {
            .stdout => .{ .stdout = .{ .command = self.command, .backend = self.backend, .offset = offset, .bytes = bytes } },
            .stderr => .{ .stderr = .{ .command = self.command, .backend = self.backend, .offset = offset, .bytes = bytes } },
            .terminal => .{ .terminal = .{ .command = self.command, .backend = self.backend, .offset = offset, .bytes = bytes } },
        };
        if (self.sink) |sink| try sink.emit(event);
        const inc: u64 = @intCast(bytes.len);
        switch (output) {
            .stdout => self.stdout_offset += inc,
            .stderr => self.stderr_offset += inc,
            .terminal => self.terminal_offset += inc,
        }
    }

    pub fn emitNetworkEvent(self: *EventEmitter, event: net_gateway.NetworkEvent) !void {
        const sink = self.sink orelse return;
        try self.emitReady();
        try sink.emit(.{ .network = networkAuditEvent(self.command, self.backend, event) });
    }

    pub fn emitPortForwards(self: *EventEmitter, policy: *const spore_net_policy.Config) !void {
        const sink = self.sink orelse return;
        for (policy.boundServiceSlice()) |service| {
            try sink.emit(.{ .port_forward = portForwardEvent(self.command, self.backend, service) });
        }
    }

    pub fn emitExit(self: *EventEmitter, result: Result) !void {
        if (self.terminal_emitted) return;
        self.setBackend(result.backend);
        try self.emitReady();
        if (self.sink) |sink| {
            if (saveEvent(self.command, result)) |event| try sink.emit(.{ .save = event });
        }
        self.terminal_emitted = true;
        if (self.sink) |sink| try sink.emit(.{ .exit = exitEvent(self.command, result) });
    }

    pub fn emitImageCommit(self: *EventEmitter, event: ImageCommitEvent) !void {
        if (self.sink) |sink| try sink.emit(.{ .image_commit = event });
    }

    pub fn emitFailure(self: *EventEmitter, err: anyerror) !void {
        if (self.terminal_emitted) return;
        self.terminal_emitted = true;
        if (self.sink) |sink| try sink.emit(.{ .failure = .{ .command = self.command, .backend = self.backend, .classified = classifyFailure(err) } });
    }

    pub fn emitReadyBestEffort(self: *EventEmitter) void {
        self.emitReady() catch {
            self.write_failed = true;
        };
    }

    pub fn emitOutputBestEffort(self: *EventEmitter, output: vsock_stream.HostStreamOutput, bytes: []const u8) void {
        self.emitOutput(output, bytes) catch {
            self.write_failed = true;
        };
    }

    pub fn emitNetworkEventBestEffort(self: *EventEmitter, event: net_gateway.NetworkEvent) void {
        self.emitNetworkEvent(event) catch {
            self.write_failed = true;
        };
    }

    pub fn emitImageCommitBestEffort(self: *EventEmitter, event: ImageCommitEvent) void {
        self.emitImageCommit(event) catch {
            self.write_failed = true;
        };
    }
};

fn networkAuditEvent(command: []const u8, backend: ?Backend, event: net_gateway.NetworkEvent) NetworkAuditEvent {
    return .{
        .command = command,
        .backend = backend,
        .kind = switch (event.kind) {
            .egress_denied => .egress_denied,
        },
        .destination_ip = event.destination_ip,
        .destination_port = event.destination_port,
        .reason = event.reason.name(),
    };
}

fn portForwardEvent(command: []const u8, backend: ?Backend, service: spore_net_policy.BoundServiceConfig) PortForwardEvent {
    return .{
        .command = command,
        .backend = backend,
        .kind = .bound_unix_service,
        .name = service.name,
        .guest_host = service.guest_host,
        .guest_port = service.guest_port,
        .target = "unix",
    };
}

fn saveEvent(command: []const u8, result: Result) ?SaveEvent {
    if (!result.saved) return null;
    return .{
        .command = command,
        .backend = result.backend,
        .save_path = result.save_path orelse return null,
        .ownership = result.save_ownership orelse return null,
    };
}

fn exitEvent(command: []const u8, result: Result) ExitEvent {
    return .{
        .command = command,
        .backend = result.backend,
        .exit_code = result.exit_code,
        .vcpus = result.vcpus,
        .memory_bytes = result.memory_bytes,
        .max_memory_bytes = result.max_memory_bytes,
        .saved = result.saved,
        .save_path = result.save_path,
        .save_ownership = result.save_ownership,
        .memory_restore_source = result.memory_restore_source,
        .memory_restore_reason = result.memory_restore_reason,
        .timings = .{
            .start_ms = result.start_ms,
            .vsock_connect_ms = result.vsock_connect_ms,
            .exec_response_ms = result.exec_response_ms,
            .probe_duration_ms = result.probe_duration_ms,
        },
    };
}

pub const EventWriter = struct {
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    command: []const u8,
    backend: ?[]const u8 = null,
    ready_emitted: bool = false,
    terminal_emitted: bool = false,
    stdout_offset: u64 = 0,
    stderr_offset: u64 = 0,
    terminal_offset: u64 = 0,
    write_failed: bool = false,

    pub fn init(allocator: std.mem.Allocator, writer: *Io.Writer, command: []const u8) EventWriter {
        return .{
            .allocator = allocator,
            .writer = writer,
            .command = command,
        };
    }

    pub fn sink(self: *EventWriter) EventSink {
        return .{ .context = self, .emitFn = emitSink };
    }

    fn emitSink(context: ?*anyopaque, event: RunEvent) !void {
        const self: *EventWriter = @ptrCast(@alignCast(context.?));
        try self.emitEvent(event);
    }

    pub fn emitEvent(self: *EventWriter, event: RunEvent) !void {
        switch (event) {
            .start => |value| try self.emitStart(value.requested_backend),
            .ready => |value| {
                if (value.backend) |backend| self.setBackend(backend);
                try self.emitReady();
            },
            .port_forward => |value| try self.emitPortForwardEvent(value),
            .network => |value| try self.emitNetworkEvent(value),
            .stdout => |value| try self.emitOutputEvent("stdout", value),
            .stderr => |value| try self.emitOutputEvent("stderr", value),
            .terminal => |value| try self.emitOutputEvent("terminal", value),
            .save => |value| try self.emitSaveEvent(value),
            .image_commit => |value| try self.emitImageCommitEvent(value),
            .exit => |value| try self.emitExitEvent(value),
            .failure => |value| try self.emitFailure(value.classified),
        }
    }

    pub fn emitStart(self: *EventWriter, requested_backend: Backend) !void {
        const event = struct {
            schema: []const u8 = machine_output.automation_event_schema,
            schema_version: u32 = machine_output.automation_event_schema_version,
            event: []const u8 = "start",
            command: []const u8,
            requested_backend: []const u8,
        }{
            .command = self.command,
            .requested_backend = requested_backend.name(),
        };
        try self.write(event);
    }

    fn emitOutputEvent(self: *EventWriter, name: []const u8, output: OutputEvent) !void {
        if (output.bytes.len == 0) return;
        if (output.backend) |backend| self.setBackend(backend);
        try self.emitReady();
        const data_base64 = try base64Alloc(self.allocator, output.bytes);
        defer self.allocator.free(data_base64);
        const event = struct {
            schema: []const u8 = machine_output.automation_event_schema,
            schema_version: u32 = machine_output.automation_event_schema_version,
            event: []const u8,
            command: []const u8,
            backend: ?[]const u8,
            offset: u64,
            byte_count: usize,
            data_base64: []const u8,
        }{
            .event = name,
            .command = output.command,
            .backend = self.backend,
            .offset = output.offset,
            .byte_count = output.bytes.len,
            .data_base64 = data_base64,
        };
        try self.write(event);
    }

    fn emitPortForwardEvent(self: *EventWriter, value: PortForwardEvent) !void {
        if (value.backend) |backend| self.setBackend(backend);
        const event = struct {
            schema: []const u8 = machine_output.automation_event_schema,
            schema_version: u32 = machine_output.automation_event_schema_version,
            event: []const u8 = "port_forward",
            command: []const u8,
            backend: ?[]const u8,
            type: []const u8,
            name: []const u8,
            guest_host: ?[]const u8,
            guest_port: u16,
            target: []const u8,
        }{
            .command = value.command,
            .backend = self.backend,
            .type = value.kind.name(),
            .name = value.name,
            .guest_host = value.guest_host,
            .guest_port = value.guest_port,
            .target = value.target,
        };
        try self.write(event);
    }

    fn emitNetworkEvent(self: *EventWriter, value: NetworkAuditEvent) !void {
        if (value.backend) |backend| self.setBackend(backend);
        try self.emitReady();
        const destination_ip = try std.fmt.allocPrint(
            self.allocator,
            "{d}.{d}.{d}.{d}",
            .{ value.destination_ip[0], value.destination_ip[1], value.destination_ip[2], value.destination_ip[3] },
        );
        defer self.allocator.free(destination_ip);
        const event = struct {
            schema: []const u8 = machine_output.automation_event_schema,
            schema_version: u32 = machine_output.automation_event_schema_version,
            event: []const u8 = "network",
            command: []const u8,
            backend: ?[]const u8,
            type: []const u8,
            destination_ip: []const u8,
            destination_port: u16,
            reason: []const u8,
        }{
            .command = value.command,
            .backend = self.backend,
            .type = value.kind.name(),
            .destination_ip = destination_ip,
            .destination_port = value.destination_port,
            .reason = value.reason,
        };
        try self.write(event);
    }

    fn emitSaveEvent(self: *EventWriter, value: SaveEvent) !void {
        self.setBackend(value.backend);
        const event = struct {
            schema: []const u8 = machine_output.automation_event_schema,
            schema_version: u32 = machine_output.automation_event_schema_version,
            event: []const u8 = "capture",
            command: []const u8,
            backend: []const u8,
            capture_path: []const u8,
            ownership: []const u8,
        }{
            .command = value.command,
            .backend = value.backend.name(),
            .capture_path = value.save_path,
            .ownership = value.ownership,
        };
        try self.write(event);
    }

    fn emitImageCommitEvent(self: *EventWriter, value: ImageCommitEvent) !void {
        self.setBackend(value.backend);
        const event = struct {
            schema: []const u8 = machine_output.automation_event_schema,
            schema_version: u32 = machine_output.automation_event_schema_version,
            event: []const u8 = "image_committed",
            command: []const u8,
            backend: []const u8,
            ref: []const u8,
            resolved_image_ref: []const u8,
            rootfs_index_digest: []const u8,
        }{
            .command = value.command,
            .backend = value.backend.name(),
            .ref = value.ref,
            .resolved_image_ref = value.resolved_image_ref,
            .rootfs_index_digest = value.rootfs_index_digest,
        };
        try self.write(event);
    }

    fn emitExitEvent(self: *EventWriter, value: ExitEvent) !void {
        if (self.terminal_emitted) return;
        self.setBackend(value.backend);
        try self.emitReady();
        self.terminal_emitted = true;
        const event = struct {
            schema: []const u8 = machine_output.automation_event_schema,
            schema_version: u32 = machine_output.automation_event_schema_version,
            event: []const u8 = "completion",
            outcome: []const u8 = @tagName(TerminalOutcome.completed),
            command: []const u8,
            backend: []const u8,
            exit_code: i32,
            vcpus: topology.VcpuCount,
            memory_bytes: u64,
            max_memory_bytes: u64,
            captured: bool,
            capture_path: ?[]const u8,
            capture_ownership: ?[]const u8,
            memory_restore_source: ?[]const u8,
            memory_restore_reason: ?[]const u8,
            timings: Timings,
        }{
            .command = value.command,
            .backend = value.backend.name(),
            .exit_code = value.exit_code,
            .vcpus = value.vcpus,
            .memory_bytes = value.memory_bytes,
            .max_memory_bytes = value.max_memory_bytes,
            .captured = value.saved,
            .capture_path = value.save_path,
            .capture_ownership = value.save_ownership,
            .memory_restore_source = value.memory_restore_source,
            .memory_restore_reason = value.memory_restore_reason,
            .timings = value.timings,
        };
        try self.write(event);
    }

    pub fn setBackend(self: *EventWriter, backend: Backend) void {
        self.backend = backend.name();
    }

    pub fn emitReady(self: *EventWriter) !void {
        if (self.ready_emitted) return;
        self.ready_emitted = true;
        const event = struct {
            schema: []const u8 = machine_output.automation_event_schema,
            schema_version: u32 = machine_output.automation_event_schema_version,
            event: []const u8 = "ready",
            command: []const u8,
            backend: ?[]const u8,
        }{
            .command = self.command,
            .backend = self.backend,
        };
        try self.write(event);
    }

    pub fn emitOutput(self: *EventWriter, output: vsock_stream.HostStreamOutput, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.emitReady();
        const offset = switch (output) {
            .stdout => self.stdout_offset,
            .stderr => self.stderr_offset,
            .terminal => self.terminal_offset,
        };
        const data_base64 = try base64Alloc(self.allocator, bytes);
        defer self.allocator.free(data_base64);
        const event = struct {
            schema: []const u8 = machine_output.automation_event_schema,
            schema_version: u32 = machine_output.automation_event_schema_version,
            event: []const u8,
            command: []const u8,
            backend: ?[]const u8,
            offset: u64,
            byte_count: usize,
            data_base64: []const u8,
        }{
            .event = @tagName(output),
            .command = self.command,
            .backend = self.backend,
            .offset = offset,
            .byte_count = bytes.len,
            .data_base64 = data_base64,
        };
        try self.write(event);
        const inc: u64 = @intCast(bytes.len);
        switch (output) {
            .stdout => self.stdout_offset += inc,
            .stderr => self.stderr_offset += inc,
            .terminal => self.terminal_offset += inc,
        }
    }

    pub fn emitExit(self: *EventWriter, result: Result) !void {
        if (self.terminal_emitted) return;
        self.setBackend(result.backend);
        try self.emitReady();
        if (saveEvent(self.command, result)) |event| try self.emitSaveEvent(event);
        try self.emitExitEvent(exitEvent(self.command, result));
    }

    pub fn emitExecCompletion(self: *EventWriter, exit_code: u8) !void {
        if (self.terminal_emitted) return;
        self.terminal_emitted = true;
        try self.write(.{
            .schema = machine_output.automation_event_schema,
            .schema_version = machine_output.automation_event_schema_version,
            .event = "completion",
            .outcome = @tagName(TerminalOutcome.completed),
            .command = self.command,
            .backend = self.backend,
            .exit_code = exit_code,
        });
    }

    pub fn emitFailure(self: *EventWriter, classified: machine_output.CliError) !void {
        if (self.terminal_emitted) return;
        self.terminal_emitted = true;
        const event = struct {
            schema: []const u8 = machine_output.automation_event_schema,
            schema_version: u32 = machine_output.automation_event_schema_version,
            event: []const u8 = "completion",
            outcome: []const u8,
            command: []const u8,
            backend: ?[]const u8,
            exit_code: u8,
            @"error": machine_output.ErrorBody,
        }{
            .command = self.command,
            .backend = self.backend,
            .outcome = if (classified.code == .operation_canceled) @tagName(TerminalOutcome.canceled) else @tagName(TerminalOutcome.failed),
            .exit_code = classified.exit_code,
            .@"error" = classified.envelope().@"error",
        };
        try self.write(event);
    }

    fn write(self: *EventWriter, event: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(self.allocator, event, .{});
        defer self.allocator.free(json);
        try self.writer.writeAll(json);
        try self.writer.writeByte('\n');
        try self.writer.flush();
    }

    pub fn emitReadyBestEffort(self: *EventWriter) void {
        self.emitReady() catch {
            self.write_failed = true;
        };
    }

    pub fn emitOutputBestEffort(self: *EventWriter, output: vsock_stream.HostStreamOutput, bytes: []const u8) void {
        self.emitOutput(output, bytes) catch {
            self.write_failed = true;
        };
    }
};

pub fn classifyFailure(err: anyerror) machine_output.CliError {
    if (err == error.ImageCommandMissing) {
        return machine_output.CliError.init(
            .usage_missing_argument,
            "spore run: image has no Entrypoint or Cmd; pass a command",
            @errorName(err),
        );
    }
    if (err == error.UnsupportedImageUser) {
        return machine_output.CliError.init(
            .usage_invalid_argument,
            "spore run: image Config.User must select root (root, 0, root:root, or 0:0); guest credential switching is not supported yet",
            @errorName(err),
        );
    }
    if (err == error.RunArgCountUnsupported) {
        return machine_output.CliError.init(
            .usage_invalid_argument,
            "spore run: effective command must contain between 1 and 16 arguments",
            @errorName(err),
        );
    }
    if (err == error.RunArgTooLong) {
        return machine_output.CliError.init(
            .usage_invalid_argument,
            "spore run: effective command contains an argument longer than 8191 bytes",
            @errorName(err),
        );
    }
    if (err == error.RunProgramEmpty) {
        return machine_output.CliError.init(
            .usage_invalid_argument,
            "spore run: effective command has an empty program name",
            @errorName(err),
        );
    }
    if (err == error.X86ElasticMemoryUnsupported or err == error.X86ExperimentalMemorySizeUnsupported) {
        return machine_output.CliError.init(
            .usage_invalid_argument,
            "spore run: experimental x86-64 KVM requires fixed 512mib memory; --max-memory is unavailable",
            @errorName(err),
        );
    }
    if (err == error.X86ResumeUnsupported or err == error.X86CaptureUnsupported) {
        return machine_output.CliError.init(
            .usage_invalid_argument,
            "spore run: x86-64 KVM currently supports fresh execution only; resume, save, capture, and fork are unavailable",
            @errorName(err),
        );
    }
    if (err == error.X86DiskForkUnsupported) {
        return machine_output.CliError.init(
            .usage_invalid_argument,
            "spore run: x86-64 KVM disk fork is unavailable",
            @errorName(err),
        );
    }
    if (err == error.X86VcpuCountUnsupported) {
        return machine_output.CliError.init(
            .usage_invalid_argument,
            "spore run: the experimental x86-64 product path currently requires --vcpus 1",
            @errorName(err),
        );
    }
    if (err == error.ImageStoreIncomplete) {
        return machine_output.CliError.init(
            .runtime_execution_failed,
            "spore run: the image store could not supply every object of the image, so nothing was saved or committed",
            @errorName(err),
        );
    }
    if (err == error.InvalidRunCommitOptions or err == error.RunCommitImageConfigUnavailable or err == error.RunCommitRootfsNotSnapshotable) {
        return machine_output.CliError.init(
            .usage_invalid_argument,
            "spore run: --commit requires a fresh non-interactive --image run with an effective command and cannot be combined with save options",
            @errorName(err),
        );
    }
    if (err == error.RunCommitGuestFreezeFailed or err == error.RunCommitGuestFreezeTimedOut) {
        return machine_output.CliError.init(
            .runtime_execution_failed,
            "spore run: image commit could not freeze the guest filesystem; the destination ref was not updated",
            @errorName(err),
        );
    }
    if (err == error.InvalidRunDiskSize or err == error.RunDiskSizeWouldShrink) {
        return machine_output.CliError.init(
            .usage_invalid_argument,
            "spore run: --disk-size must be a 64KiB-aligned absolute size at least as large as the source image and currently requires --commit",
            @errorName(err),
        );
    }
    if (err == error.RunCommitGuestResizeFailed or err == error.RunCommitGuestResizeTimedOut) {
        return machine_output.CliError.init(
            .runtime_execution_failed,
            "spore run: image commit could not grow the guest rootfs before the command; the destination ref was not updated",
            @errorName(err),
        );
    }
    if (err == error.RunCommitDidNotComplete or err == error.DeviceStatePending) {
        return machine_output.CliError.init(
            .runtime_execution_failed,
            "spore run: image commit could not seal a quiescent root disk; the destination ref was not updated",
            @errorName(err),
        );
    }
    if (err == error.CrossDeviceOwnershipLink) {
        return machine_output.CliError.init(
            .object_invalid,
            "spore run: a machine-local pinned save must be on the rootfs cache's filesystem; choose --save DIR there",
            @errorName(err),
        );
    }
    if (err == error.SavedSporePublicationRecoveryRequired) {
        return machine_output.CliError.init(
            .object_invalid,
            "spore run: a previous save failed after capture; recover `.sporevm-pin-stage/manifest.json` from the save directory before retrying",
            @errorName(err),
        );
    }
    if (err == error.TtyRunFromSporeUnsupported) {
        return machine_output.CliError.init(
            .usage_invalid_argument,
            "spore run: -t with --from command execution is not supported yet; use `spore attach -t <spore>` to connect to a saved terminal session",
            @errorName(err),
        );
    }
    if (err == error.SavedSessionHasNoInteractiveStdin) {
        return machine_output.CliError.init(
            .usage_invalid_argument,
            "spore run: saved session has no interactive stdin",
            @errorName(err),
        );
    }
    if (err == error.SavedSessionHasNoTerminal) {
        return machine_output.CliError.init(
            .usage_invalid_argument,
            "spore run: saved session has no terminal",
            @errorName(err),
        );
    }
    if (err == error.NoSavedSession) {
        return machine_output.CliError.init(
            .object_invalid,
            "spore run: spore has no saved session; pass a command after --from or use spore run --save to create a session spore",
            @errorName(err),
        );
    }
    if (err == error.SavedSessionUnavailable) {
        return machine_output.CliError.init(
            .usage_invalid_argument,
            "spore run: saved session handle is unavailable",
            @errorName(err),
        );
    }
    return machine_output.fromZigError(err);
}

fn base64Alloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(out, bytes);
    return out;
}

fn jsonStringEquals(value: ?std.json.Value, expected: []const u8) bool {
    const actual = switch (value orelse return false) {
        .string => |string| string,
        else => return false,
    };
    return std.mem.eql(u8, actual, expected);
}

fn jsonIntegerEquals(value: ?std.json.Value, expected: i64) bool {
    const actual = switch (value orelse return false) {
        .integer => |integer| integer,
        else => return false,
    };
    return actual == expected;
}

fn expectJsonStringField(allocator: std.mem.Allocator, line: []const u8, field: []const u8, expected: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.BadManifest,
    };
    try std.testing.expect(jsonStringEquals(object.get(field), expected));
}

fn expectJsonIntegerField(allocator: std.mem.Allocator, line: []const u8, field: []const u8, expected: i64) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.BadManifest,
    };
    try std.testing.expect(jsonIntegerEquals(object.get(field), expected));
}

fn expectNestedJsonStringField(
    allocator: std.mem.Allocator,
    line: []const u8,
    object_field: []const u8,
    field: []const u8,
    expected: []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.BadManifest,
    };
    const nested_value = object.get(object_field) orelse return error.BadManifest;
    const nested_object = switch (nested_value) {
        .object => |nested| nested,
        else => return error.BadManifest,
    };
    try std.testing.expect(jsonStringEquals(nested_object.get(field), expected));
}

fn failingEventSink(_: ?*anyopaque, _: RunEvent) !void {
    return error.TestEventSinkFailed;
}

test "event writer emits JSONL lifecycle and output records" {
    const allocator = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var events = EventWriter.init(allocator, &out.writer, "run");
    const sink = events.sink();

    const result = Result{
        .backend = .hvf,
        .start_ms = 1,
        .vsock_connect_ms = 2,
        .exec_response_ms = 4,
        .probe_duration_ms = 2,
        .exit_code = 7,
        .vcpus = 1,
        .memory_bytes = memory_config.default_bytes,
        .max_memory_bytes = memory_config.default_bytes,
        .memory_restore_source = "local_backing",
        .memory_restore_reason = "proof_valid",
    };
    try sink.emit(.{ .start = .{ .command = "run", .requested_backend = .hvf } });
    try sink.emit(.{ .ready = .{ .command = "run", .backend = .hvf } });
    try sink.emit(.{ .stdout = .{ .command = "run", .backend = .hvf, .offset = 0, .bytes = "hi\n" } });
    try sink.emit(.{ .exit = exitEvent("run", result) });

    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    const start_line = lines.next().?;
    const ready_line = lines.next().?;
    const stdout_line = lines.next().?;
    const exit_line = lines.next().?;
    try std.testing.expectEqualStrings("", lines.next().?);
    try expectJsonStringField(allocator, start_line, "schema", machine_output.automation_event_schema);
    try expectJsonStringField(allocator, start_line, "event", "start");
    try expectJsonStringField(allocator, ready_line, "event", "ready");
    try expectJsonStringField(allocator, ready_line, "backend", "hvf");
    try expectJsonStringField(allocator, stdout_line, "event", "stdout");
    try expectJsonStringField(allocator, stdout_line, "data_base64", "aGkK");
    try expectJsonStringField(allocator, exit_line, "event", "completion");
    try expectJsonStringField(allocator, exit_line, "outcome", "completed");
    try expectJsonStringField(allocator, exit_line, "memory_restore_source", "local_backing");
    try expectJsonStringField(allocator, exit_line, "memory_restore_reason", "proof_valid");
}

test "event writer emits image commit identity" {
    const allocator = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var events = EventWriter.init(allocator, &out.writer, "run");

    try events.emitEvent(.{ .image_commit = .{
        .command = "run",
        .backend = .hvf,
        .ref = "local/example:prepared",
        .resolved_image_ref = "local/example@blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .rootfs_index_digest = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    } });

    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    const event_line = lines.next().?;
    try std.testing.expectEqualStrings("", lines.next().?);
    try expectJsonStringField(allocator, event_line, "event", "image_committed");
    try expectJsonStringField(allocator, event_line, "ref", "local/example:prepared");
    try expectJsonStringField(allocator, event_line, "resolved_image_ref", "local/example@blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    try expectJsonStringField(allocator, event_line, "rootfs_index_digest", "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
}

test "event writer emits exactly one terminal failure" {
    const allocator = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var events = EventWriter.init(allocator, &out.writer, "run");
    const sink = events.sink();

    try sink.emit(.{ .failure = .{ .command = "run", .backend = null, .classified = classifyFailure(error.RuntimeFailed) } });
    try events.emitExit(.{
        .backend = .hvf,
        .start_ms = 1,
        .vsock_connect_ms = 2,
        .exec_response_ms = 3,
        .probe_duration_ms = 1,
        .exit_code = 0,
        .vcpus = 1,
        .memory_bytes = memory_config.default_bytes,
        .max_memory_bytes = memory_config.default_bytes,
    });

    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    const failure_line = lines.next().?;
    try std.testing.expectEqualStrings("", lines.next().?);
    try expectJsonStringField(allocator, failure_line, "event", "completion");
    try expectJsonStringField(allocator, failure_line, "outcome", "failed");
    try expectNestedJsonStringField(allocator, failure_line, "error", "code", "runtime.execution_failed");
}

test "event writer serializes setup failure as a failed completion" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var writer = EventWriter.init(allocator, &out.writer, "run");

    try writer.emitFailure(machine_output.usageMissingArgument("missing command", "run"));

    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    const completion_line = lines.next().?;
    try std.testing.expectEqualStrings("", lines.next().?);
    try expectJsonStringField(allocator, completion_line, "event", "completion");
    try expectJsonStringField(allocator, completion_line, "outcome", "failed");
    try expectJsonIntegerField(allocator, completion_line, "exit_code", 2);
    try expectNestedJsonStringField(allocator, completion_line, "error", "code", "usage.missing_argument");
}

test "event writer serializes cancellation as a canceled completion" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var writer = EventWriter.init(allocator, &out.writer, "exec");

    try writer.emitFailure(classifyFailure(error.OperationCanceled));

    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    const completion_line = lines.next().?;
    try std.testing.expectEqualStrings("", lines.next().?);
    try expectJsonStringField(allocator, completion_line, "event", "completion");
    try expectJsonStringField(allocator, completion_line, "outcome", "canceled");
    try expectJsonIntegerField(allocator, completion_line, "exit_code", 130);
    try expectNestedJsonStringField(allocator, completion_line, "error", "code", "operation.canceled");
}

test "saved session attach failures are usage errors" {
    const classified = classifyFailure(error.SavedSessionHasNoInteractiveStdin);
    try std.testing.expectEqual(machine_output.ErrorCode.usage_invalid_argument, classified.code);
    try std.testing.expect(std.mem.indexOf(u8, classified.message, "no interactive stdin") != null);
}

test "tty run-from unsupported failure has a clear public message" {
    const classified = classifyFailure(error.TtyRunFromSporeUnsupported);
    try std.testing.expectEqual(machine_output.ErrorCode.usage_invalid_argument, classified.code);
    try std.testing.expect(std.mem.indexOf(u8, classified.message, "-t with --from") != null);
}

test "event writer emits terminal output records" {
    const allocator = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var events = EventWriter.init(allocator, &out.writer, "run");
    const sink = events.sink();

    try sink.emit(.{ .terminal = .{ .command = "run", .backend = .hvf, .offset = 0, .bytes = "$ " } });

    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    const ready_line = lines.next().?;
    const terminal_line = lines.next().?;
    try std.testing.expectEqualStrings("", lines.next().?);
    try expectJsonStringField(allocator, ready_line, "event", "ready");
    try expectJsonStringField(allocator, terminal_line, "event", "terminal");
    try expectJsonStringField(allocator, terminal_line, "data_base64", "JCA=");
    try expectJsonIntegerField(allocator, terminal_line, "offset", 0);
}

test "event writer emits network denied events" {
    const allocator = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var events = EventWriter.init(allocator, &out.writer, "run");
    const sink = events.sink();

    try sink.emit(.{ .network = .{
        .command = "run",
        .backend = .hvf,
        .kind = .egress_denied,
        .destination_ip = .{ 169, 254, 169, 254 },
        .destination_port = 80,
        .reason = "hard-floor",
    } });

    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    const ready_line = lines.next().?;
    const network_line = lines.next().?;
    try std.testing.expectEqualStrings("", lines.next().?);
    try expectJsonStringField(allocator, ready_line, "event", "ready");
    try expectJsonStringField(allocator, network_line, "event", "network");
    try expectJsonStringField(allocator, network_line, "type", "egress_denied");
    try expectJsonStringField(allocator, network_line, "destination_ip", "169.254.169.254");
    try expectJsonIntegerField(allocator, network_line, "destination_port", 80);
    try expectJsonStringField(allocator, network_line, "reason", "hard-floor");
}

test "event writer emits port forward events" {
    const allocator = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var writer = EventWriter.init(allocator, &out.writer, "run");
    var events = EventEmitter.init(writer.sink(), "run");
    events.setBackend(.hvf);
    var policy = spore_net_policy.Config{ .egress = .unrestricted };
    try policy.addBoundUnixService("gateway", "gateway.internal", 8170, "/tmp/gateway.sock");

    try events.emitPortForwards(&policy);

    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    const port_forward_line = lines.next().?;
    try std.testing.expectEqualStrings("", lines.next().?);
    try std.testing.expectEqualStrings(
        "{\"schema\":\"spore.automation.event.v1\",\"schema_version\":1,\"event\":\"port_forward\",\"command\":\"run\",\"backend\":\"hvf\",\"type\":\"bound_unix_service\",\"name\":\"gateway\",\"guest_host\":\"gateway.internal\",\"guest_port\":8170,\"target\":\"unix\"}",
        port_forward_line,
    );
}

test "event writer emits capture events before exit" {
    const allocator = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var events = EventWriter.init(allocator, &out.writer, "run");

    try events.emitExit(.{
        .backend = .hvf,
        .start_ms = 1,
        .vsock_connect_ms = 2,
        .exec_response_ms = 3,
        .probe_duration_ms = 1,
        .exit_code = 0,
        .vcpus = 1,
        .memory_bytes = memory_config.default_bytes,
        .max_memory_bytes = memory_config.default_bytes,
        .saved = true,
        .save_path = "out.spore",
        .save_ownership = saved_spore_ownership.portable_self_contained,
    });

    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    const ready_line = lines.next().?;
    const capture_line = lines.next().?;
    const exit_line = lines.next().?;
    try std.testing.expectEqualStrings("", lines.next().?);
    try expectJsonStringField(allocator, ready_line, "event", "ready");
    try std.testing.expectEqualStrings(
        "{\"schema\":\"spore.automation.event.v1\",\"schema_version\":1,\"event\":\"capture\",\"command\":\"run\",\"backend\":\"hvf\",\"capture_path\":\"out.spore\",\"ownership\":\"portable-self-contained\"}",
        capture_line,
    );
    try expectJsonStringField(allocator, exit_line, "event", "completion");
    try expectJsonStringField(allocator, exit_line, "outcome", "completed");
}

test "event emitter records best-effort sink failures" {
    var events = EventEmitter.init(.{ .emitFn = failingEventSink }, "run");
    events.emitOutputBestEffort(.stdout, "lost\n");
    try std.testing.expect(events.write_failed);
}

test "saved run result preserves stored exit code" {
    const result = Result{
        .backend = .hvf,
        .start_ms = 1,
        .vsock_connect_ms = 2,
        .exec_response_ms = 3,
        .probe_duration_ms = 1,
        .exit_code = 7,
        .vcpus = 1,
        .memory_bytes = memory_config.default_bytes,
        .max_memory_bytes = memory_config.default_bytes,
        .saved = true,
        .save_path = "out.spore",
    };
    try std.testing.expectEqual(@as(u8, 7), result.processExitCode());
}
