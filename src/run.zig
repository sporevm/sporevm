//! One-shot VM boot/exec support for `spore run`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const capture = @import("capture.zig");
const Context = @import("context.zig").Context;
const disk_layer = @import("disk_layer.zig");
const hvf = @import("hvf/hvf.zig");
const kvm = if (builtin.os.tag == .linux and builtin.cpu.arch == .aarch64)
    @import("kvm/kvm.zig")
else
    struct {};
const local_paths = @import("local_paths.zig");
const machine_output = @import("machine_output.zig");
const memory_config = @import("memory.zig");
const net_gateway = @import("net_gateway.zig");
const rootfs_cache = @import("rootfs_cache.zig");
const rootfs_mod = @import("rootfs.zig");
const runtime_disk_mod = @import("runtime_disk.zig");
const run_assets = @import("run_assets");
const spore = @import("spore.zig");
const spore_net_policy = @import("spore_net_policy.zig");
const virtio_blk = @import("virtio/blk.zig");
const virtio_net = @import("virtio/net.zig");
const vsock = @import("virtio/vsock.zig");

const max_file_size = 256 * 1024 * 1024;
const max_kernel_asset_size = 256 * 1024 * 1024;
const max_kernel_config_asset_size = 2 * 1024 * 1024;
const managed_kernel_download_attempts = 3;
const max_guest_argc = 16;
const max_guest_arg_len = 255;
const max_guest_envc = 64;
const max_guest_env_len = 255;
const max_guest_working_dir_len = 255;
const max_guest_request_len = 8191;
const max_guest_port = 65535;
const embedded_run_initrd = run_assets.minimal_exec_initrd;
const default_kernel_repository = "sporevm/kernels";
const default_kernel_release = "v0.6.2";
const default_kernel_version = "6.1.155";
const managed_run_kernel_required_config_symbols = [_][]const u8{
    "CONFIG_CGROUPS",
    "CONFIG_FILE_LOCKING",
    "CONFIG_HW_RANDOM",
    "CONFIG_HW_RANDOM_VIRTIO",
    "CONFIG_SHMEM",
    "CONFIG_TMPFS",
    "CONFIG_FSNOTIFY",
    "CONFIG_INOTIFY_USER",
    "CONFIG_BPF_SYSCALL",
    "CONFIG_CGROUP_BPF",
    "CONFIG_MEMCG",
    "CONFIG_CGROUP_PIDS",
    "CONFIG_CPUSETS",
    "CONFIG_CGROUP_DEVICE",
    "CONFIG_MEMORY_HOTPLUG",
    "CONFIG_MEMORY_HOTPLUG_DEFAULT_ONLINE",
    "CONFIG_MEMORY_HOTREMOVE",
    "CONFIG_CONTIG_ALLOC",
    "CONFIG_EXCLUSIVE_SYSTEM_RAM",
    "CONFIG_VIRTIO_MEM",
};
const direct_image_platform = rootfs_mod.Platform{};
const max_rootfs_metadata_bytes = 1024 * 1024;
const auto_boot_memory_bytes: u64 = 512 * 1024 * 1024;

pub const MemoryConfig = memory_config.Config;
pub const CaptureTrigger = capture.Trigger;
pub const NetworkPolicy = spore_net_policy.Config;
pub const Rootfs = spore.Rootfs;
pub const Disk = spore.Disk;
pub const ClassifiedFailure = machine_output.CliError;
pub const FailureCode = machine_output.ErrorCode;
pub const FailureScope = machine_output.Scope;

pub const Backend = enum {
    auto,
    hvf,
    kvm,

    pub fn parse(raw: []const u8) ?Backend {
        if (std.mem.eql(u8, raw, "auto")) return .auto;
        if (std.mem.eql(u8, raw, "hvf")) return .hvf;
        if (std.mem.eql(u8, raw, "kvm")) return .kvm;
        return null;
    }

    pub fn name(self: Backend) []const u8 {
        return switch (self) {
            .auto => "auto",
            .hvf => "hvf",
            .kvm => "kvm",
        };
    }
};

pub const Options = struct {
    backend: Backend = .auto,
    kernel_path: []const u8,
    initrd_path: ?[]const u8 = null,
    auto_memory_hotplug_capable: bool = false,
    rootfs_path: ?[]const u8 = null,
    rootfs: ?spore.Rootfs = null,
    disk: ?spore.Disk = null,
    resume_dir: ?[]const u8 = null,
    command: []const []const u8,
    guest_env: []const []const u8 = &.{},
    guest_working_dir: ?[]const u8 = null,
    memory: memory_config.Config = .{},
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    console_log_path: ?[]const u8 = null,
    stream_output: bool = true,
    capture_path: ?[]const u8 = null,
    capture_trigger: capture.Trigger = .exit,
    continue_after_capture: bool = false,
    annotations: spore.Annotations = .{},
    network: NetworkMode = .disabled,
    network_policy: spore_net_policy.Config = .{},
    network_runtime: ?virtio_net.Runtime = null,
    events: ?EventSink = null,
    spore_executable: []const u8 = "spore",
    debug: bool = false,
};

pub const NetworkMode = enum {
    disabled,
    spore,
};

pub const EventMode = enum {
    none,
    jsonl,

    pub fn parse(raw: []const u8) ?EventMode {
        if (std.mem.eql(u8, raw, "jsonl")) return .jsonl;
        return null;
    }
};

pub const PullPolicy = enum {
    missing,
    always,
    never,

    pub fn parse(raw: []const u8) ?PullPolicy {
        if (std.mem.eql(u8, raw, "missing")) return .missing;
        if (std.mem.eql(u8, raw, "always")) return .always;
        if (std.mem.eql(u8, raw, "never")) return .never;
        return null;
    }
};

fn useMutableImageRefCache(policy: PullPolicy) bool {
    return switch (policy) {
        .missing, .never => true,
        .always => false,
    };
}

pub const Result = struct {
    backend: Backend,
    start_ms: u64,
    vsock_connect_ms: u64,
    exec_response_ms: u64,
    probe_duration_ms: u64,
    exit_code: i32,
    vcpus: u32,
    memory_bytes: u64,
    captured: bool = false,
    capture_path: ?[]const u8 = null,
    /// Product restore RAM source, such as `local_backing` or `chunks`.
    memory_restore_source: ?[]const u8 = null,
    /// Product restore planner reason, such as `proof_valid` or `proof_unavailable`.
    memory_restore_reason: ?[]const u8 = null,

    pub fn processExitCode(self: Result) u8 {
        std.debug.assert(self.exit_code >= 0 and self.exit_code <= 255);
        return @intCast(self.exit_code);
    }

    pub fn withMemoryRestore(self: Result, plan: spore.LocalBackingPlan) Result {
        var result = self;
        result.memory_restore_source = @tagName(plan.source);
        result.memory_restore_reason = plan.reason;
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

pub const ExitEvent = struct {
    command: []const u8,
    backend: Backend,
    exit_code: i32,
    vcpus: u32,
    memory_bytes: u64,
    captured: bool = false,
    capture_path: ?[]const u8 = null,
    memory_restore_source: ?[]const u8 = null,
    memory_restore_reason: ?[]const u8 = null,
    timings: Timings,
};

pub const FailureEvent = struct {
    command: []const u8,
    backend: ?Backend,
    classified: ClassifiedFailure,
};

/// Runtime lifecycle events delivered synchronously to EventSink.
/// Output bytes are callback-scoped. Ready is emitted at most once, and exit or
/// failure is emitted at most once as the terminal event.
pub const RunEvent = union(enum) {
    start: StartEvent,
    ready: ReadyEvent,
    network: NetworkAuditEvent,
    stdout: OutputEvent,
    stderr: OutputEvent,
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

    pub fn emitOutput(self: *EventEmitter, output: vsock.HostStreamOutput, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.emitReady();
        const offset = switch (output) {
            .stdout => self.stdout_offset,
            .stderr => self.stderr_offset,
        };
        const event: RunEvent = switch (output) {
            .stdout => .{ .stdout = .{ .command = self.command, .backend = self.backend, .offset = offset, .bytes = bytes } },
            .stderr => .{ .stderr = .{ .command = self.command, .backend = self.backend, .offset = offset, .bytes = bytes } },
        };
        if (self.sink) |sink| try sink.emit(event);
        const inc: u64 = @intCast(bytes.len);
        switch (output) {
            .stdout => self.stdout_offset += inc,
            .stderr => self.stderr_offset += inc,
        }
    }

    pub fn emitNetworkEvent(self: *EventEmitter, event: net_gateway.NetworkEvent) !void {
        const sink = self.sink orelse return;
        try self.emitReady();
        try sink.emit(.{ .network = networkAuditEvent(self.command, self.backend, event) });
    }

    pub fn emitExit(self: *EventEmitter, result: Result) !void {
        if (self.terminal_emitted) return;
        self.setBackend(result.backend);
        try self.emitReady();
        self.terminal_emitted = true;
        if (self.sink) |sink| try sink.emit(.{ .exit = exitEvent(self.command, result) });
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

    pub fn emitOutputBestEffort(self: *EventEmitter, output: vsock.HostStreamOutput, bytes: []const u8) void {
        self.emitOutput(output, bytes) catch {
            self.write_failed = true;
        };
    }

    pub fn emitNetworkEventBestEffort(self: *EventEmitter, event: net_gateway.NetworkEvent) void {
        self.emitNetworkEvent(event) catch {
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

fn exitEvent(command: []const u8, result: Result) ExitEvent {
    return .{
        .command = command,
        .backend = result.backend,
        .exit_code = result.exit_code,
        .vcpus = result.vcpus,
        .memory_bytes = result.memory_bytes,
        .captured = result.captured,
        .capture_path = result.capture_path,
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
            .network => |value| try self.emitNetworkEvent(value),
            .stdout => |value| try self.emitOutputEvent("stdout", value),
            .stderr => |value| try self.emitOutputEvent("stderr", value),
            .exit => |value| try self.emitExitEvent(value),
            .failure => |value| try self.emitFailure(value.classified),
        }
    }

    pub fn emitStart(self: *EventWriter, requested_backend: Backend) !void {
        const event = struct {
            schema: []const u8 = machine_output.run_events_schema,
            schema_version: u32 = machine_output.run_events_schema_version,
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
            schema: []const u8 = machine_output.run_events_schema,
            schema_version: u32 = machine_output.run_events_schema_version,
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
            schema: []const u8 = machine_output.run_events_schema,
            schema_version: u32 = machine_output.run_events_schema_version,
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

    fn emitExitEvent(self: *EventWriter, value: ExitEvent) !void {
        if (self.terminal_emitted) return;
        self.setBackend(value.backend);
        try self.emitReady();
        self.terminal_emitted = true;
        const event = struct {
            schema: []const u8 = machine_output.run_events_schema,
            schema_version: u32 = machine_output.run_events_schema_version,
            event: []const u8 = "exit",
            command: []const u8,
            backend: []const u8,
            exit_code: i32,
            vcpus: u32,
            memory_bytes: u64,
            captured: bool,
            capture_path: ?[]const u8,
            memory_restore_source: ?[]const u8,
            memory_restore_reason: ?[]const u8,
            timings: Timings,
        }{
            .command = value.command,
            .backend = value.backend.name(),
            .exit_code = value.exit_code,
            .vcpus = value.vcpus,
            .memory_bytes = value.memory_bytes,
            .captured = value.captured,
            .capture_path = value.capture_path,
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
            schema: []const u8 = machine_output.run_events_schema,
            schema_version: u32 = machine_output.run_events_schema_version,
            event: []const u8 = "ready",
            command: []const u8,
            backend: ?[]const u8,
        }{
            .command = self.command,
            .backend = self.backend,
        };
        try self.write(event);
    }

    pub fn emitOutput(self: *EventWriter, output: vsock.HostStreamOutput, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.emitReady();
        const offset = switch (output) {
            .stdout => self.stdout_offset,
            .stderr => self.stderr_offset,
        };
        const data_base64 = try base64Alloc(self.allocator, bytes);
        defer self.allocator.free(data_base64);
        const event = struct {
            schema: []const u8 = machine_output.run_events_schema,
            schema_version: u32 = machine_output.run_events_schema_version,
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
        }
    }

    pub fn emitExit(self: *EventWriter, result: Result) !void {
        try self.emitExitEvent(exitEvent(self.command, result));
    }

    pub fn emitFailure(self: *EventWriter, classified: ClassifiedFailure) !void {
        if (self.terminal_emitted) return;
        self.terminal_emitted = true;
        const event = struct {
            schema: []const u8 = machine_output.run_events_schema,
            schema_version: u32 = machine_output.run_events_schema_version,
            event: []const u8 = "failure",
            command: []const u8,
            backend: ?[]const u8,
            @"error": machine_output.ErrorBody,
        }{
            .command = self.command,
            .backend = self.backend,
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

    pub fn emitOutputBestEffort(self: *EventWriter, output: vsock.HostStreamOutput, bytes: []const u8) void {
        self.emitOutput(output, bytes) catch {
            self.write_failed = true;
        };
    }
};

pub fn classifyFailure(err: anyerror) ClassifiedFailure {
    return machine_output.fromZigError(err);
}

pub const MonitorExit = enum {
    stopped,
    snapshotted,
};

pub const MonitorResult = struct {
    backend: Backend,
    exit: MonitorExit,
};

pub const SharedOptions = struct {
    kernel_path: ?[]const u8 = null,
    initrd_path: ?[]const u8 = null,
    memory: memory_config.Config = .{},
    memory_set: bool = false,
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    console_log_path: ?[]const u8 = null,

    fn completeWithAssets(
        self: SharedOptions,
        backend: Backend,
        kernel_path: []const u8,
        initrd_path: ?[]const u8,
        rootfs_path: ?[]const u8,
        rootfs: ?spore.Rootfs,
        command: []const []const u8,
        stream_output: bool,
    ) Options {
        return .{
            .backend = backend,
            .kernel_path = kernel_path,
            .initrd_path = initrd_path,
            .rootfs_path = rootfs_path,
            .rootfs = rootfs,
            .disk = null,
            .resume_dir = null,
            .command = command,
            .memory = self.memory,
            .vcpus = self.vcpus,
            .guest_port = self.guest_port,
            .timeout_ms = self.timeout_ms,
            .console_log_path = self.console_log_path,
            .stream_output = stream_output,
        };
    }
};

pub const CliOptions = struct {
    backend: Backend = .auto,
    shared: SharedOptions = .{},
    from_spore_dir: ?[]const u8 = null,
    rootfs_path: ?[]const u8 = null,
    image_ref: ?[]const u8 = null,
    pull_policy: PullPolicy = .missing,
    capture_path: ?[]const u8 = null,
    capture_trigger: capture.Trigger = .exit,
    continue_after_capture: bool = false,
    network: NetworkMode = .disabled,
    network_requested: bool = false,
    network_policy: spore_net_policy.Config = .{},
    event_mode: EventMode = .none,
    command: []const []const u8,
};

pub const NetworkOptions = struct {
    network: NetworkMode = .disabled,
    policy: spore_net_policy.Config = .{},
};

pub const cli_usage =
    \\Usage:
    \\  spore run [--kernel Image] [--initrd root.cpio] [options] -- <argv...>
    \\
    \\Options:
    \\  --backend auto|hvf|kvm  Backend to run (default: auto)
    \\  --kernel Image          Kernel Image path (default: managed SporeVM kernel)
    \\  --initrd root.cpio      Initrd path (default: embedded minimal exec initrd)
    \\  --from DIR              Resume from an existing spore, then run argv
    \\  --rootfs rootfs.ext4    Attach local rootfs read-only; capture unsupported
    \\  --image REF             Build or reuse cached OCI rootfs; capture preserves rootfs writes
    \\  --pull=missing|always|never
    \\                          Pull policy for mutable --image refs (default: missing)
    \\  --net                   Experimental SporeVM-managed networking
    \\  --allow-cidr CIDR       With --net, restrict public egress to this CIDR
    \\  --allow-host HOST       With --net, restrict public egress to DNS A answers for this host
    \\  --bind-service NAME=unix:/path.sock
    \\                          With --net, declare a guest-local Unix service
    \\  --capture DIR           Snapshot to DIR; defaults to --capture-on EXIT
    \\  --capture-on WHEN       Capture trigger: EXIT, INT, TERM, HUP, USR1, or USR2
    \\  --continue-after-capture
    \\                          Keep running after a signal-triggered capture
    \\  --memory VALUE          Guest memory: auto, 512mb, 2gb, ... (default: auto = 16GiB)
    \\  --vcpus N               Guest vCPU count; must be 1 today
    \\  --guest-port N          Guest vsock listen port (default: 10700)
    \\  --timeout-ms N          Probe timeout in milliseconds (default: 30000)
    \\  --console-log PATH      Write guest console output to PATH
    \\  --events=jsonl          Emit lifecycle and guest output events as JSONL on stdout
    \\  -h, --help              Show this help
    \\
;

pub fn parseCliArgs(args: []const []const u8) !CliOptions {
    var backend: Backend = .auto;
    var shared = SharedOptions{};
    var from_spore_dir: ?[]const u8 = null;
    var rootfs_path: ?[]const u8 = null;
    var image_ref: ?[]const u8 = null;
    var pull_policy: PullPolicy = .missing;
    var capture_path: ?[]const u8 = null;
    var capture_trigger: capture.Trigger = .exit;
    var capture_trigger_set = false;
    var continue_after_capture = false;
    var network: NetworkMode = .disabled;
    var network_requested = false;
    var network_policy = spore_net_policy.Config{};
    var event_mode: EventMode = .none;
    var command: ?[]const []const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            command = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, args[i], "--backend") and i + 1 < args.len) {
            i += 1;
            backend = Backend.parse(args[i]) orelse {
                std.debug.print("--backend must be auto, hvf, or kvm\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--rootfs")) {
            rootfs_path = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--image")) {
            image_ref = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--pull")) {
            const raw = takeValue(args, &i, args[i]);
            pull_policy = PullPolicy.parse(raw) orelse {
                std.debug.print("--pull must be missing, always, or never\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, args[i], "--pull=")) {
            const raw = args[i]["--pull=".len..];
            pull_policy = PullPolicy.parse(raw) orelse {
                std.debug.print("--pull must be missing, always, or never\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--from")) {
            from_spore_dir = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--capture")) {
            capture_path = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--capture-on")) {
            const trigger_raw = takeValue(args, &i, args[i]);
            capture_trigger = capture.Trigger.parse(trigger_raw) orelse {
                std.debug.print("--capture-on must be EXIT, INT, TERM, HUP, USR1, or USR2\n", .{});
                std.process.exit(2);
            };
            capture_trigger_set = true;
        } else if (std.mem.eql(u8, args[i], "--continue-after-capture")) {
            continue_after_capture = true;
        } else if (std.mem.eql(u8, args[i], "--events") and i + 1 < args.len) {
            i += 1;
            event_mode = EventMode.parse(args[i]) orelse {
                std.debug.print("--events must be jsonl\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, args[i], "--events=")) {
            const raw = args[i]["--events=".len..];
            event_mode = EventMode.parse(raw) orelse {
                std.debug.print("--events must be jsonl\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--net")) {
            network = .spore;
            network_requested = true;
        } else if (std.mem.eql(u8, args[i], "--allow-cidr")) {
            const raw = takeValue(args, &i, args[i]);
            network_policy.addAllowCidr(raw) catch |err| {
                std.debug.print("spore run: invalid --allow-cidr {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--allow-host")) {
            const raw = takeValue(args, &i, args[i]);
            network_policy.addAllowHost(raw) catch |err| {
                std.debug.print("spore run: invalid --allow-host {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--bind-service")) {
            const raw = takeValue(args, &i, args[i]);
            network_policy.addBindService(raw) catch |err| {
                std.debug.print("spore run: invalid --bind-service {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            };
        } else if (try parseSharedOption(&shared, args, &i)) {
            continue;
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            std.debug.print("unknown run argument: {s}\n\n{s}", .{ args[i], cli_usage });
            std.process.exit(2);
        } else {
            command = args[i..];
            break;
        }
    }

    const argv = command orelse &.{};
    if (argv.len == 0) {
        std.debug.print("{s}", .{cli_usage});
        std.process.exit(2);
    }
    if (rootfs_path != null and image_ref != null) {
        std.debug.print("spore run: --rootfs and --image are mutually exclusive\n", .{});
        std.process.exit(2);
    }
    if (image_ref == null and pull_policy != .missing) {
        std.debug.print("spore run: --pull requires --image\n", .{});
        std.process.exit(2);
    }
    if (from_spore_dir != null) {
        if (rootfs_path != null or image_ref != null) {
            std.debug.print("spore run: --from is mutually exclusive with --rootfs and --image\n", .{});
            std.process.exit(2);
        }
        if (shared.kernel_path != null or shared.initrd_path != null) {
            std.debug.print("spore run: --from is mutually exclusive with --kernel and --initrd\n", .{});
            std.process.exit(2);
        }
        if (shared.memory_set) {
            std.debug.print("spore run: --from uses the spore manifest memory size; omit --memory\n", .{});
            std.process.exit(2);
        }
    }
    if (capture_trigger_set and capture_path == null) {
        std.debug.print("spore run: --capture-on requires --capture\n", .{});
        std.process.exit(2);
    }
    if (continue_after_capture and capture_path == null) {
        std.debug.print("spore run: --continue-after-capture requires --capture\n", .{});
        std.process.exit(2);
    }
    if (continue_after_capture and capture_trigger.isExit()) {
        std.debug.print("spore run: --continue-after-capture requires a signal capture trigger\n", .{});
        std.process.exit(2);
    }
    if (network == .disabled and network_policy.hasRules()) {
        std.debug.print("spore run: --allow-cidr and --allow-host require --net\n", .{});
        std.process.exit(2);
    }
    if (network == .disabled and network_policy.hasBoundServices()) {
        std.debug.print("spore run: --bind-service requires --net\n", .{});
        std.process.exit(2);
    }

    return .{
        .backend = backend,
        .shared = shared,
        .from_spore_dir = from_spore_dir,
        .rootfs_path = rootfs_path,
        .image_ref = image_ref,
        .pull_policy = pull_policy,
        .capture_path = capture_path,
        .capture_trigger = capture_trigger,
        .continue_after_capture = continue_after_capture,
        .network = network,
        .network_requested = network_requested,
        .network_policy = network_policy,
        .event_mode = event_mode,
        .command = argv,
    };
}

pub fn networkOptionsFromManifest(allocator: std.mem.Allocator, manifest_network: ?spore.Network) !NetworkOptions {
    const network = manifest_network orelse return .{};
    try spore.validateNetwork(network);
    var policy = spore_net_policy.Config{};
    if (network.default_action) |action| {
        if (!std.mem.eql(u8, action, spore.network_default_deny)) return error.InvalidNetworkPolicy;
        policy.default_deny = true;
    }
    for (network.allow_cidrs) |cidr| {
        try policy.addAllowCidr(try allocator.dupe(u8, cidr));
    }
    for (network.allow_hosts) |host| {
        try policy.addAllowHost(try allocator.dupe(u8, host));
    }
    for (network.allow_host_ports) |rule| {
        const host = try allocator.dupe(u8, rule.host);
        const ports = try allocator.dupe(u16, rule.ports);
        try policy.addExactHostPorts(host, ports);
    }
    if (network.bound_services.len != 0) return error.UnsupportedBoundServiceRestore;
    return .{ .network = .spore, .policy = policy };
}

pub fn manifestNetworkFromOptions(allocator: std.mem.Allocator, network: NetworkMode, policy: *const spore_net_policy.Config) !?spore.Network {
    if (network != .spore) return null;
    const exact_rules = try allocator.alloc(spore.NetworkHostPortRule, policy.exact_rule_count);
    for (policy.exactRuleSlice(), exact_rules) |*rule, *out| {
        out.* = .{
            .host = rule.host,
            .ports = rule.portSlice(),
        };
    }
    const bound_services = try allocator.alloc(spore.NetworkBoundServiceRequirement, policy.bound_service_count);
    for (policy.boundServiceSlice(), bound_services) |service, *out| {
        out.* = .{
            .name = service.name,
            .guest_host = service.guest_host,
            .guest_port = service.guest_port,
        };
    }
    return .{
        .default_action = if (policy.default_deny) spore.network_default_deny else null,
        .allow_cidrs = policy.allowCidrSlice(),
        .allow_hosts = policy.allowHostSlice(),
        .allow_host_ports = exact_rules,
        .bound_services = bound_services,
        .requirements = .{
            .exact_host_port = policy.default_deny or policy.exact_rule_count != 0,
            .bound_services = policy.bound_service_count != 0,
        },
    };
}

pub fn resumeRootfsForRun(allocator: std.mem.Allocator, manifest: spore.Manifest) !?spore.Rootfs {
    const disk_count = countBlockDevices(manifest.devices);
    if (disk_count == 0) return null;
    if (disk_count != 1) return error.UnsupportedRootfsDeviceCount;
    const rootfs = manifest.rootfs orelse return error.MissingRootfsArtifact;
    try spore.validateRootfs(rootfs, manifest.devices);
    return try cloneRootfs(allocator, rootfs);
}

pub fn resumeDiskForRun(allocator: std.mem.Allocator, manifest: spore.Manifest) !?spore.Disk {
    if (manifest.disk) |disk| {
        return try disk_layer.cloneDisk(allocator, disk);
    }
    return null;
}

fn countBlockDevices(devices: []const spore.TransportState) usize {
    var count: usize = 0;
    for (devices) |device| {
        if (device.device_id == virtio_blk.device_id) count += 1;
    }
    return count;
}

fn cloneRootfs(allocator: std.mem.Allocator, rootfs: spore.Rootfs) !spore.Rootfs {
    return .{
        .kind = try allocator.dupe(u8, rootfs.kind),
        .mode = try allocator.dupe(u8, rootfs.mode),
        .device = .{
            .kind = try allocator.dupe(u8, rootfs.device.kind),
            .role = try allocator.dupe(u8, rootfs.device.role),
            .virtio_device_id = rootfs.device.virtio_device_id,
            .mmio_slot = rootfs.device.mmio_slot,
        },
        .artifact = .{
            .digest = try allocator.dupe(u8, rootfs.artifact.digest),
            .size = rootfs.artifact.size,
            .format = try allocator.dupe(u8, rootfs.artifact.format),
        },
        .storage = if (rootfs.storage) |storage| try cloneRootfsStorage(allocator, storage) else null,
        .source = if (rootfs.source) |source| .{
            .kind = try allocator.dupe(u8, source.kind),
            .requested_ref = try allocator.dupe(u8, source.requested_ref),
            .resolved_image_ref = try allocator.dupe(u8, source.resolved_image_ref),
            .image_manifest_digest = try allocator.dupe(u8, source.image_manifest_digest),
            .platform = try allocator.dupe(u8, source.platform),
            .builder_version = try allocator.dupe(u8, source.builder_version),
        } else null,
    };
}

fn cloneRootfsStorage(allocator: std.mem.Allocator, storage: spore.RootfsStorage) !spore.RootfsStorage {
    return .{
        .kind = try allocator.dupe(u8, storage.kind),
        .device = .{
            .kind = try allocator.dupe(u8, storage.device.kind),
            .role = try allocator.dupe(u8, storage.device.role),
            .virtio_device_id = storage.device.virtio_device_id,
            .mmio_slot = storage.device.mmio_slot,
        },
        .logical_size = storage.logical_size,
        .chunk_size = storage.chunk_size,
        .hash_algorithm = try allocator.dupe(u8, storage.hash_algorithm),
        .index_digest = try allocator.dupe(u8, storage.index_digest),
        .base_identity = try allocator.dupe(u8, storage.base_identity),
        .object_namespace = try allocator.dupe(u8, storage.object_namespace),
    };
}

pub const RootfsInputOptions = struct {
    rootfs_path: ?[]const u8,
    image_ref: ?[]const u8,
    pull_policy: PullPolicy = .missing,
    command_name: []const u8,
    record_artifact: bool = false,
};

pub const ResolvedRootfsInput = struct {
    path: ?[]const u8,
    rootfs: ?spore.Rootfs = null,
    guest_env: []const []const u8 = &.{},
    guest_working_dir: ?[]const u8 = null,
};

pub const RootfsInputResolution = union(enum) {
    resolved: ResolvedRootfsInput,
    failure: machine_output.CliError,
};

pub fn resolveRootfsInputDetailed(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: RootfsInputOptions,
) !ResolvedRootfsInput {
    const resolution = try resolveRootfsInputDetailedResult(init, allocator, options);
    switch (resolution) {
        .resolved => |resolved| return resolved,
        .failure => |failure| return rootfsInputError(failure.code),
    }
}

pub fn resolveRootfsInputDetailedResult(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: RootfsInputOptions,
) !RootfsInputResolution {
    if (options.rootfs_path != null and options.image_ref != null) {
        return .{ .failure = rootfsInputFailure(
            allocator,
            .usage_invalid_argument,
            options.command_name,
            "spore {s}: --rootfs and --image are mutually exclusive",
            .{options.command_name},
        ) };
    }
    const resolved = if (options.rootfs_path) |path|
        try resolvePathRootfs(init, allocator, path, options.command_name, options.record_artifact)
    else if (options.image_ref) |ref|
        try resolveImageRootfs(init, allocator, ref, options.command_name, options.pull_policy, options.record_artifact)
    else
        RootfsInputResolution{ .resolved = .{ .path = null } };
    switch (resolved) {
        .failure => return resolved,
        .resolved => |rootfs| {
            return .{ .resolved = rootfs };
        },
    }
}

fn resolvePathRootfs(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    rootfs_path: []const u8,
    command_name: []const u8,
    record_artifact: bool,
) !RootfsInputResolution {
    if (!try readablePath(init.io, rootfs_path)) {
        return .{ .failure = rootfsInputFailure(
            allocator,
            .object_not_found,
            command_name,
            "spore {s}: rootfs not found: {s}",
            .{ command_name, rootfs_path },
        ) };
    }
    if (!record_artifact) return .{ .resolved = .{ .path = rootfs_path } };

    const cache_root = local_paths.rootfsCacheRootPath(allocator, init.environ_map) catch |err| switch (err) {
        error.MissingHome => return .{ .failure = rootfsInputFailure(
            allocator,
            .cache_unavailable,
            command_name,
            "spore {s}: cannot resolve rootfs cache directory; set {s} or HOME",
            .{ command_name, local_paths.rootfs_cache_env },
        ) },
        else => |e| return e,
    };
    try ensureDirPath(init.io, cache_root);
    const artifact = rootfs_cache.cacheByDigestPathCopy(init.io, allocator, cache_root, rootfs_path) catch |err| {
        return .{ .failure = rootfsInputFailure(
            allocator,
            machine_output.fromZigError(err).code,
            command_name,
            "spore {s}: rootfs artifact setup failed for {s}: {s}",
            .{ command_name, rootfs_path, @errorName(err) },
        ) };
    };
    return .{ .resolved = .{
        .path = rootfs_path,
        .rootfs = .{
            .device = .{ .mmio_slot = 1 },
            .artifact = artifact,
        },
    } };
}

fn resolveImageRootfs(init: std.process.Init, allocator: std.mem.Allocator, image_ref: []const u8, command_name: []const u8, pull_policy: PullPolicy, record_artifact: bool) !RootfsInputResolution {
    const cache_root = local_paths.rootfsCacheRootPath(allocator, init.environ_map) catch |err| switch (err) {
        error.MissingHome => return .{ .failure = rootfsInputFailure(
            allocator,
            .cache_unavailable,
            command_name,
            "spore {s}: cannot resolve rootfs cache directory; set {s} or HOME",
            .{ command_name, local_paths.rootfs_cache_env },
        ) },
        else => |e| return e,
    };
    try ensureDirPath(init.io, cache_root);

    const digest_pinned = try rootfs_mod.digestPinnedImageIdentity(allocator, image_ref, direct_image_platform);

    if (rootfs_mod.isLocalImageRef(image_ref)) {
        const resolved = rootfs_mod.resolveLocalCachedRef(init.io, allocator, cache_root, image_ref, direct_image_platform) catch |err| {
            return .{ .failure = rootfsInputFailure(
                allocator,
                .object_not_found,
                command_name,
                "spore {s}: local image ref not imported for {s}: {s}",
                .{ command_name, image_ref, @errorName(err) },
            ) };
        };
        if (rootfs_mod.cachedImageRootfsPath(init.io, allocator, cache_root, resolved) catch |err| {
            return .{ .failure = rootfsInputFailure(
                allocator,
                .cache_integrity_failed,
                command_name,
                "spore {s}: cached rootfs metadata check failed: {s}",
                .{ command_name, @errorName(err) },
            ) };
        }) |path| {
            return try resolvedImageRootfsInputResult(init, allocator, cache_root, image_ref, resolved, path, command_name, record_artifact);
        }
        return .{ .failure = rootfsInputFailure(
            allocator,
            .object_not_found,
            command_name,
            "spore {s}: local image rootfs cache miss for {s}; import an OCI layout with 'spore rootfs import-oci <layout> --ref local/name:tag'",
            .{ command_name, image_ref },
        ) };
    }

    if (digest_pinned) |resolved| {
        if (rootfs_mod.cachedImageRootfsPath(init.io, allocator, cache_root, resolved) catch |err| {
            return .{ .failure = rootfsInputFailure(
                allocator,
                .cache_integrity_failed,
                command_name,
                "spore {s}: cached rootfs metadata check failed: {s}",
                .{ command_name, @errorName(err) },
            ) };
        }) |path| {
            return try resolvedImageRootfsInputResult(init, allocator, cache_root, image_ref, resolved, path, command_name, record_artifact);
        }
    } else {
        rootfs_mod.validateTaggedImageRef(image_ref) catch |err| {
            return .{ .failure = rootfsInputFailure(
                allocator,
                .usage_invalid_argument,
                command_name,
                "spore {s}: image resolve failed for {s}: {s}",
                .{ command_name, image_ref, @errorName(err) },
            ) };
        };
        if (useMutableImageRefCache(pull_policy)) {
            if (rootfs_mod.cachedImageRefRootfsPath(init.io, allocator, cache_root, image_ref, direct_image_platform) catch |err| {
                return .{ .failure = rootfsInputFailure(
                    allocator,
                    .cache_integrity_failed,
                    command_name,
                    "spore {s}: cached image ref check failed: {s}",
                    .{ command_name, @errorName(err) },
                ) };
            }) |hit| {
                return try resolvedImageRootfsInputResult(init, allocator, cache_root, image_ref, hit.resolved, hit.path, command_name, record_artifact);
            }
        }
        if (pull_policy == .never) {
            return .{ .failure = rootfsInputFailure(
                allocator,
                .object_not_found,
                command_name,
                "spore {s}: image ref cache miss for {s} with --pull=never",
                .{ command_name, image_ref },
            ) };
        }
    }

    const resolved = rootfs_mod.resolveImageRef(init, allocator, image_ref, direct_image_platform) catch |err| {
        return .{ .failure = rootfsInputFailure(
            allocator,
            machine_output.fromZigError(err).code,
            command_name,
            "spore {s}: image resolve failed for {s}: {s}",
            .{ command_name, image_ref, @errorName(err) },
        ) };
    };
    if (rootfs_mod.cachedImageRootfsPath(init.io, allocator, cache_root, resolved) catch |err| {
        return .{ .failure = rootfsInputFailure(
            allocator,
            .cache_integrity_failed,
            command_name,
            "spore {s}: cached rootfs metadata check failed: {s}",
            .{ command_name, @errorName(err) },
        ) };
    }) |path| {
        if (digest_pinned == null) rootfs_mod.writeImageRefCacheRecord(init.io, allocator, cache_root, image_ref, resolved) catch |err| {
            return .{ .failure = rootfsInputFailure(
                allocator,
                machine_output.fromZigError(err).code,
                command_name,
                "spore {s}: image ref cache update failed: {s}",
                .{ command_name, @errorName(err) },
            ) };
        };
        return try resolvedImageRootfsInputResult(init, allocator, cache_root, image_ref, resolved, path, command_name, record_artifact);
    }
    const path = rootfs_mod.buildCachedImageRootfs(init, allocator, cache_root, resolved) catch |err| {
        return .{ .failure = rootfsInputFailure(
            allocator,
            machine_output.fromZigError(err).code,
            command_name,
            "spore {s}: image rootfs build failed for {s}: {s}",
            .{ command_name, resolved.ref, @errorName(err) },
        ) };
    };
    if (digest_pinned == null) rootfs_mod.writeImageRefCacheRecord(init.io, allocator, cache_root, image_ref, resolved) catch |err| {
        return .{ .failure = rootfsInputFailure(
            allocator,
            machine_output.fromZigError(err).code,
            command_name,
            "spore {s}: image ref cache update failed: {s}",
            .{ command_name, @errorName(err) },
        ) };
    };
    return try resolvedImageRootfsInputResult(init, allocator, cache_root, image_ref, resolved, path, command_name, record_artifact);
}

fn resolvedImageRootfsInputResult(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    requested_ref: []const u8,
    resolved: rootfs_mod.ResolvedImage,
    rootfs_path: []const u8,
    command_name: []const u8,
    record_artifact: bool,
) !RootfsInputResolution {
    const input = resolvedImageRootfsInput(init, allocator, cache_root, requested_ref, resolved, rootfs_path, record_artifact) catch |err| {
        return .{ .failure = rootfsInputFailure(
            allocator,
            machine_output.fromZigError(err).code,
            command_name,
            "spore {s}: image rootfs setup failed for {s}: {s}",
            .{ command_name, requested_ref, @errorName(err) },
        ) };
    };
    return .{ .resolved = input };
}

fn rootfsInputFailure(
    allocator: std.mem.Allocator,
    code: machine_output.ErrorCode,
    source: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) machine_output.CliError {
    const message = std.fmt.allocPrint(allocator, fmt, args) catch code.defaultMessage();
    return machine_output.CliError.init(code, message, source);
}

fn rootfsInputError(code: machine_output.ErrorCode) anyerror {
    return switch (code) {
        .usage_invalid_argument,
        .usage_missing_argument,
        => error.InvalidRootfsInput,
        .object_not_found => error.FileNotFound,
        .object_invalid => error.BadManifest,
        .cache_unavailable => error.RootfsCacheUnavailable,
        .cache_integrity_failed => error.BadRootfsDigest,
        .host_unsupported,
        .host_unavailable,
        => error.UnsupportedHost,
        .runtime_start_failed,
        .runtime_execution_failed,
        => error.RuntimeFailed,
    };
}

fn resolvedImageRootfsInput(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    requested_ref: []const u8,
    resolved: rootfs_mod.ResolvedImage,
    rootfs_path: []const u8,
    record_artifact: bool,
) !ResolvedRootfsInput {
    const metadata_path = try rootfs_mod.cachedImageRootfsMetadataPath(allocator, cache_root, resolved);
    const run_config = try readCachedImageRunConfig(init.io, allocator, metadata_path);
    if (!record_artifact) return .{
        .path = rootfs_path,
        .guest_env = run_config.env,
        .guest_working_dir = run_config.working_dir,
    };
    const artifact = try rootfs_cache.cacheByDigestPath(init.io, allocator, cache_root, rootfs_path);
    const rootfs_device = spore.RootfsDevice{ .mmio_slot = 1 };
    const storage = try rootfs_mod.ensureImageRootfsStorage(init, allocator, cache_root, resolved, artifact, rootfs_device);
    const platform = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ resolved.platform.os, resolved.platform.arch });
    const manifest_requested_ref = if (rootfs_mod.isLocalImageRef(requested_ref)) resolved.ref else requested_ref;
    return .{
        .path = rootfs_path,
        .rootfs = .{
            .device = rootfs_device,
            .artifact = artifact,
            .storage = storage,
            .source = .{
                .requested_ref = manifest_requested_ref,
                .resolved_image_ref = resolved.ref,
                .image_manifest_digest = resolved.manifest_digest,
                .platform = platform,
                .builder_version = rootfs_mod.builder_version,
            },
        },
        .guest_env = run_config.env,
        .guest_working_dir = run_config.working_dir,
    };
}

const ImageRunConfig = struct {
    env: []const []const u8 = &.{},
    working_dir: ?[]const u8 = null,
};

const CachedImageRunMetadata = struct {
    config: ?CachedImageConfig = null,
};

const CachedImageConfig = struct {
    config: ?CachedRuntimeConfig = null,
};

const CachedRuntimeConfig = struct {
    Env: ?[][]const u8 = null,
    WorkingDir: ?[]const u8 = null,
};

fn readCachedImageRunConfig(io: Io, allocator: std.mem.Allocator, metadata_path: []const u8) !ImageRunConfig {
    const metadata = Io.Dir.cwd().readFileAlloc(io, metadata_path, allocator, .limited(max_rootfs_metadata_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return .{},
        else => |e| return e,
    };
    defer allocator.free(metadata);
    var parsed = std.json.parseFromSlice(CachedImageRunMetadata, allocator, metadata, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return .{};
    defer parsed.deinit();

    const image_config = parsed.value.config orelse return .{};
    const runtime = image_config.config orelse return .{};
    const env = if (runtime.Env) |entries| try cloneStringList(allocator, entries) else &.{};
    const working_dir = if (runtime.WorkingDir) |dir|
        if (dir.len == 0) null else try allocator.dupe(u8, dir)
    else
        null;
    return .{ .env = env, .working_dir = working_dir };
}

fn cloneStringList(allocator: std.mem.Allocator, entries: []const []const u8) ![]const []const u8 {
    if (entries.len == 0) return &.{};
    const cloned = try allocator.alloc([]const u8, entries.len);
    for (entries, 0..) |entry, i| {
        cloned[i] = try allocator.dupe(u8, entry);
    }
    return cloned;
}

fn ensureDirPath(io: Io, path: []const u8) !void {
    if (!Io.Dir.path.isAbsolute(path)) {
        try Io.Dir.cwd().createDirPath(io, path);
        return;
    }
    var existing = Io.Dir.openDirAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (std.fs.path.dirname(path)) |parent| {
                if (parent.len > 0 and !std.mem.eql(u8, parent, path)) try ensureDirPath(io, parent);
            }
            Io.Dir.createDirAbsolute(io, path, .default_dir) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => {},
                else => |e| return e,
            };
            return;
        },
        else => |e| return e,
    };
    existing.close(io);
}

fn monotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn regularFileNoSymlink(io: Io, path: []const u8) !bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return false,
        else => |e| return e,
    };
    return stat.kind == .file;
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

pub fn resolveDefaultKernelPath(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    if (init.environ_map.get("SPOREVM_KERNEL_IMAGE")) |path| {
        if (!try readablePath(init.io, path)) return error.FileNotFound;
        return path;
    }

    return resolveManagedRunKernelPath(init, allocator);
}

pub fn resolveConfiguredInitrdPath(init: std.process.Init, cli_path: ?[]const u8) !?[]const u8 {
    if (cli_path) |path| return path;
    if (init.environ_map.get("SPOREVM_RUN_INITRD")) |path| {
        if (!try readablePath(init.io, path)) return error.FileNotFound;
        return path;
    }
    return null;
}

fn resolveManagedRunKernelPath(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    const opts = managedKernelOptions(init);
    const asset = try managedRunKernelAssetName(allocator, opts.linux_version);
    const config_asset = try managedRunKernelConfigAssetName(allocator, asset);
    const cache_root = local_paths.kernelCacheRootPath(allocator, init.environ_map) catch |err| switch (err) {
        error.MissingHome => return error.MissingHome,
        else => |e| return e,
    };
    const repo_cache = try managedKernelRepositoryCacheName(allocator, opts.repository);
    const dest_dir = try std.fs.path.join(allocator, &.{ cache_root, repo_cache, opts.release });
    const dest = try std.fs.path.join(allocator, &.{ dest_dir, asset });
    const sha_dest = try std.fmt.allocPrint(allocator, "{s}.sha256", .{dest});
    const config_dest = try std.fmt.allocPrint(allocator, "{s}.config", .{dest});

    if (try managedKernelCacheHit(init.io, allocator, dest, sha_dest, config_dest)) {
        return dest;
    }

    try ensureDirPath(init.io, dest_dir);
    const temp_dir_root = try std.fs.path.join(allocator, &.{ dest_dir, "download" });
    try ensureDirPath(init.io, temp_dir_root);

    var nonce_bytes: [8]u8 = undefined;
    init.io.random(&nonce_bytes);
    const nonce = std.mem.readInt(u64, &nonce_bytes, .little);
    const temp_image = try std.fmt.allocPrint(allocator, "{s}/{s}.{x}.tmp", .{ temp_dir_root, asset, nonce });
    const temp_sha = try std.fmt.allocPrint(allocator, "{s}.sha256", .{temp_image});
    const temp_config = try std.fmt.allocPrint(allocator, "{s}.config", .{temp_image});
    defer Io.Dir.cwd().deleteFile(init.io, temp_image) catch {};
    defer Io.Dir.cwd().deleteFile(init.io, temp_sha) catch {};
    defer Io.Dir.cwd().deleteFile(init.io, temp_config) catch {};

    var client: std.http.Client = .{ .allocator = allocator, .io = init.io };
    defer client.deinit();
    try fetchManagedKernelAsset(allocator, init.io, &client, opts.repository, opts.release, asset, temp_image, max_kernel_asset_size);
    const sha_asset = try std.fmt.allocPrint(allocator, "{s}.sha256", .{asset});
    try fetchManagedKernelAsset(allocator, init.io, &client, opts.repository, opts.release, sha_asset, temp_sha, max_kernel_config_asset_size);
    try fetchManagedKernelAsset(allocator, init.io, &client, opts.repository, opts.release, config_asset, temp_config, max_kernel_config_asset_size);
    if (!try verifiedManagedKernelPath(init.io, allocator, temp_image, temp_sha)) return error.ManagedKernelChecksumMismatch;
    if (try missingManagedRunKernelConfigSymbolFromPath(init.io, allocator, temp_config)) |missing| {
        defer allocator.free(missing);
        return error.ManagedKernelConfigMissing;
    }

    try Io.Dir.renameAbsolute(temp_image, dest, init.io);
    try Io.Dir.renameAbsolute(temp_sha, sha_dest, init.io);
    try Io.Dir.renameAbsolute(temp_config, config_dest, init.io);
    chmodFileReadOnly(allocator, dest) catch {};
    chmodFileReadOnly(allocator, sha_dest) catch {};
    chmodFileReadOnly(allocator, config_dest) catch {};
    return dest;
}

const ManagedKernelOptions = struct {
    repository: []const u8,
    release: []const u8,
    linux_version: []const u8,
};

fn managedKernelOptions(init: std.process.Init) ManagedKernelOptions {
    return .{
        .repository = init.environ_map.get("SPOREVM_KERNEL_REPOSITORY") orelse default_kernel_repository,
        .release = init.environ_map.get("SPOREVM_KERNEL_RELEASE") orelse default_kernel_release,
        .linux_version = init.environ_map.get("SPOREVM_KERNEL_VERSION") orelse default_kernel_version,
    };
}

fn managedRunKernelAssetName(allocator: std.mem.Allocator, linux_version: []const u8) ![]const u8 {
    try validateManagedKernelVersion(linux_version);
    return std.fmt.allocPrint(allocator, "sporevm-arm64-linux-{s}-Image", .{linux_version});
}

fn managedRunKernelConfigAssetName(allocator: std.mem.Allocator, image_asset: []const u8) ![]const u8 {
    try validateManagedKernelAsset(image_asset);
    return std.fmt.allocPrint(allocator, "{s}.config", .{image_asset});
}

fn validateManagedKernelVersion(version: []const u8) !void {
    if (version.len == 0) return error.BadManagedKernelVersion;
    for (version) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_')) return error.BadManagedKernelVersion;
    }
}

fn managedKernelRepositoryCacheName(allocator: std.mem.Allocator, repository: []const u8) ![]const u8 {
    try validateManagedKernelRepository(repository);
    const cache = try allocator.dupe(u8, repository);
    std.mem.replaceScalar(u8, cache, '/', '-');
    return cache;
}

fn validateManagedKernelRepository(repository: []const u8) !void {
    if (repository.len == 0) return error.BadManagedKernelRepository;
    var slash_count: u8 = 0;
    var segments = std.mem.splitScalar(u8, repository, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.BadManagedKernelRepository;
    }
    for (repository) |c| {
        if (c == '/') {
            slash_count += 1;
        } else if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_')) {
            return error.BadManagedKernelRepository;
        }
    }
    if (slash_count != 1) return error.BadManagedKernelRepository;
}

fn verifiedManagedKernelPath(io: Io, allocator: std.mem.Allocator, image_path: []const u8, sha_path: []const u8) !bool {
    if (!try regularFileNoSymlink(io, image_path)) return false;
    if (!try regularFileNoSymlink(io, sha_path)) return false;
    const expected = readExpectedSha256(io, allocator, sha_path) catch |err| switch (err) {
        error.BadManagedKernelChecksum => return false,
        else => |e| return e,
    };
    defer allocator.free(expected);
    const actual = try sha256FileHex(io, image_path);
    return std.ascii.eqlIgnoreCase(expected, &actual);
}

fn managedKernelCacheHit(io: Io, allocator: std.mem.Allocator, image_path: []const u8, sha_path: []const u8, config_path: []const u8) !bool {
    if (!try readOnlyRegularFileNoSymlink(io, image_path)) return false;
    if (!try readOnlyRegularFileNoSymlink(io, sha_path)) return false;
    if (!try readOnlyRegularFileNoSymlink(io, config_path)) return false;

    if (!try verifiedManagedKernelPath(io, allocator, image_path, sha_path)) return false;
    if (!try managedRunKernelConfigHasRequiredSymbols(io, allocator, config_path)) return false;
    return true;
}

fn managedRunKernelConfigHasRequiredSymbols(io: Io, allocator: std.mem.Allocator, config_path: []const u8) !bool {
    const missing = try missingManagedRunKernelConfigSymbolFromPath(io, allocator, config_path);
    if (missing) |symbol| {
        allocator.free(symbol);
        return false;
    }
    return true;
}

fn missingManagedRunKernelConfigSymbolFromPath(io: Io, allocator: std.mem.Allocator, config_path: []const u8) !?[]const u8 {
    if (!try regularFileNoSymlink(io, config_path)) return error.ManagedKernelConfigMissing;
    const config = try Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(max_kernel_config_asset_size));
    defer allocator.free(config);
    return missingManagedRunKernelConfigSymbol(allocator, config);
}

fn missingManagedRunKernelConfigSymbol(allocator: std.mem.Allocator, config: []const u8) !?[]const u8 {
    for (&managed_run_kernel_required_config_symbols) |symbol| {
        if (!kernelConfigHasBuiltin(config, symbol)) return try allocator.dupe(u8, symbol);
    }
    return null;
}

fn kernelConfigHasBuiltin(config: []const u8, symbol: []const u8) bool {
    var lines = std.mem.splitScalar(u8, config, '\n');
    while (lines.next()) |raw_line| {
        const line = if (std.mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
        if (line.len != symbol.len + 2) continue;
        if (!std.mem.startsWith(u8, line, symbol)) continue;
        if (line[symbol.len] != '=') continue;
        if (line[symbol.len + 1] != 'y') continue;
        return true;
    }
    return false;
}

fn readOnlyRegularFileNoSymlink(io: Io, path: []const u8) !bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return false,
        else => |e| return e,
    };
    return stat.kind == .file and @intFromEnum(stat.permissions) & 0o222 == 0;
}

fn readExpectedSha256(io: Io, allocator: std.mem.Allocator, sha_path: []const u8) ![]const u8 {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, sha_path, allocator, .limited(4096));
    defer allocator.free(bytes);
    var fields = std.mem.tokenizeAny(u8, bytes, " \t\r\n");
    const first = fields.next() orelse return error.BadManagedKernelChecksum;
    if (!isSha256Hex(first)) return error.BadManagedKernelChecksum;
    return allocator.dupe(u8, first);
}

fn isSha256Hex(value: []const u8) bool {
    if (value.len != Sha256.digest_length * 2) return false;
    for (value) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn sha256FileHex(io: Io, path: []const u8) ![Sha256.digest_length * 2]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader_buf: [64 * 1024]u8 = undefined;
    var reader: Io.File.Reader = .initStreaming(file, io, &reader_buf);
    var h = Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try reader.interface.readSliceShort(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var out: [Sha256.digest_length]u8 = undefined;
    h.final(&out);
    return std.fmt.bytesToHex(out, .lower);
}

fn fetchManagedKernelAsset(
    allocator: std.mem.Allocator,
    io: Io,
    client: *std.http.Client,
    repository: []const u8,
    release: []const u8,
    asset: []const u8,
    output_path: []const u8,
    max_body_bytes: u64,
) !void {
    try validateManagedKernelRepository(repository);
    try validateManagedKernelVersion(release);
    try validateManagedKernelAsset(asset);
    const url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/releases/download/{s}/{s}", .{ repository, release, asset });
    var attempt: u8 = 0;
    while (attempt < managed_kernel_download_attempts) : (attempt += 1) {
        Io.Dir.cwd().deleteFile(io, output_path) catch {};
        httpGetToFile(io, client, url, output_path, max_body_bytes) catch |err| {
            if (attempt + 1 == managed_kernel_download_attempts) return err;
            continue;
        };
        return;
    }
    unreachable;
}

fn validateManagedKernelAsset(asset: []const u8) !void {
    if (asset.len == 0) return error.BadManagedKernelAsset;
    for (asset) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_')) return error.BadManagedKernelAsset;
    }
}

fn httpGetToFile(
    io: Io,
    client: *std.http.Client,
    url: []const u8,
    output_path: []const u8,
    max_body_bytes: u64,
) !void {
    var file = try Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var file_writer: Io.File.Writer = .initStreaming(file, io, &buffer);
    try httpGetToWriter(client, url, &file_writer.interface, max_body_bytes);
    try file_writer.interface.flush();
}

fn httpGetToWriter(client: *std.http.Client, url: []const u8, writer: *Io.Writer, max_body_bytes: u64) !void {
    const uri = try std.Uri.parse(url);
    const accept_header = std.http.Header{ .name = "accept", .value = "application/octet-stream" };
    var req = try client.request(.GET, uri, .{
        .extra_headers = &.{accept_header},
    });
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) return error.ManagedKernelHTTPStatus;

    var transfer_buffer: [64 * 1024]u8 = undefined;
    var body = response.reader(&transfer_buffer);
    var copied: u64 = 0;
    var copy_buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = body.readSliceShort(&copy_buffer) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse err,
            else => |e| return e,
        };
        if (n == 0) return;
        if (n > max_body_bytes - copied) return error.ManagedKernelBodyTooLarge;
        copied += @intCast(n);
        try writer.writeAll(copy_buffer[0..n]);
    }
}

fn chmodFileReadOnly(allocator: std.mem.Allocator, path: []const u8) !void {
    const pathz = try allocator.dupeZ(u8, path);
    defer allocator.free(pathz);
    if (std.c.chmod(pathz, 0o444) != 0) return error.ChmodFailed;
}

fn chmodFileWritable(allocator: std.mem.Allocator, path: []const u8) !void {
    const pathz = try allocator.dupeZ(u8, path);
    defer allocator.free(pathz);
    if (std.c.chmod(pathz, 0o644) != 0) return error.ChmodFailed;
}

fn loadRunInitrd(io: Io, allocator: std.mem.Allocator, path: ?[]const u8) ![]const u8 {
    if (path) |initrd_path| {
        return try std.Io.Dir.cwd().readFileAlloc(io, initrd_path, allocator, .limited(max_file_size));
    }
    return embedded_run_initrd;
}

fn readablePath(io: Io, path: []const u8) !bool {
    return accessPath(io, path, .{ .read = true });
}

fn accessPath(io: Io, path: []const u8, options: Io.Dir.AccessOptions) !bool {
    if (Io.Dir.path.isAbsolute(path)) {
        Io.Dir.accessAbsolute(io, path, options) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return false,
            else => |e| return e,
        };
        return true;
    }
    Io.Dir.cwd().access(io, path, options) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return false,
        else => |e| return e,
    };
    return true;
}

fn failRunSetup(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(2);
}

pub fn execute(context: Context, allocator: std.mem.Allocator, opts: Options) !Result {
    var events = EventEmitter.init(opts.events, "run");
    try events.emitStart(opts.backend);
    errdefer |err| events.emitFailure(err) catch {};

    const setup_start = monotonicMs();
    if (opts.vcpus != 1) return error.UnsupportedVcpuCount;
    try spore.validateAnnotations(opts.annotations);

    const backend = try resolveBackend(opts.backend);
    events.setBackend(backend);
    var gateway: net_gateway.Process = undefined;
    var gateway_active = false;
    if (opts.network == .spore) {
        try gateway.start(context.io, allocator, opts.spore_executable, opts.debug, opts.network_policy);
        gateway_active = true;
    }
    defer if (gateway_active) gateway.deinit();
    const network: virtio_net.Runtime = if (gateway_active) gateway.runtime() else .{};
    errdefer finishGatewayNetworkEvents(&gateway, &gateway_active, &events);
    const network_manifest = try manifestNetworkFromOptions(allocator, opts.network, &opts.network_policy);

    const resuming = opts.resume_dir != null;
    const memory_plan = runMemoryPlan(opts.memory, .{
        .fixed_ram = resuming or opts.capture_path != null,
        .auto_hotplug_capable = opts.auto_memory_hotplug_capable,
    });
    const local_backing_start = monotonicMs();
    const local_backing = try openRunLocalMemoryBacking(allocator, context.environ_map, opts.resume_dir, memory_plan.boot_ram_size);
    const local_backing_ms = monotonicMs() -| local_backing_start;
    defer if (local_backing.fd) |fd| {
        _ = std.c.close(fd);
    };
    const kernel_start = monotonicMs();
    const kernel = if (resuming) "" else try std.Io.Dir.cwd().readFileAlloc(context.io, opts.kernel_path, allocator, .limited(max_file_size));
    const kernel_ms = monotonicMs() -| kernel_start;
    const initrd_start = monotonicMs();
    const initrd: ?[]const u8 = if (resuming) null else try loadRunInitrd(context.io, allocator, opts.initrd_path);
    const initrd_ms = monotonicMs() -| initrd_start;
    const disk_start = monotonicMs();
    var runtime_disk = try runtime_disk_mod.open(context, allocator, .{
        .rootfs_path = opts.rootfs_path,
        .rootfs = opts.rootfs,
        .disk = opts.disk,
        .spore_dir = opts.resume_dir,
    });
    const disk_ms = monotonicMs() -| disk_start;
    defer runtime_disk.deinit();
    const boot_args = if (resuming) "" else try cmdline(allocator, opts.guest_port, opts.rootfs_path != null, rootfsWritable(opts), opts.network);
    const request_start = monotonicMs();
    const request = try execRequestForRun(context, allocator, opts, memory_plan.virtio_mem_region_size != 0);
    var stream = try vsock.HostStream.init(opts.guest_port, request);
    const request_ms = monotonicMs() -| request_start;
    if (resuming) stream.host_port = vsock.HostStream.deriveHostPort(request);
    if (opts.events != null) {
        stream.setLifecycleSink(&events, runEventLifecycleSink);
        stream.setOutputSink(&events, runEventOutputSink);
    } else if (opts.stream_output) {
        stream.setOutputSink(null, runOutputSink);
    }
    var capture_request = capture.Request{};
    var signal_registration: ?capture.SignalRegistration = null;
    defer if (signal_registration) |*registration| registration.deinit();
    const capture_plan = capture.Plan.productRun(.{
        .capture_path = opts.capture_path,
        .trigger = opts.capture_trigger,
        .resume_dir = opts.resume_dir,
        .request = &capture_request,
        .continue_after_capture = opts.continue_after_capture,
    });
    if (capture_plan.signal) |signal| {
        signal_registration = capture.SignalRegistration.install(signal, capture_plan.request.?);
    }
    std.log.debug(
        "run host setup timing: total_ms={d} local_backing_ms={d} kernel_ms={d} initrd_ms={d} disk_ms={d} request_ms={d} ram_mib={d} virtio_mem_mib={d}",
        .{
            monotonicMs() -| setup_start,
            local_backing_ms,
            kernel_ms,
            initrd_ms,
            disk_ms,
            request_ms,
            memory_plan.boot_ram_size / 1024 / 1024,
            memory_plan.virtio_mem_region_size / 1024 / 1024,
        },
    );

    const backend_run_start = monotonicMs();
    const cause = (switch (backend) {
        .auto => unreachable,
        .hvf => blk: {
            if (comptime !(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) return error.UnsupportedBackend;
            break :blk hvf.vm.run(allocator, .{
                .kernel = kernel,
                .ram_size = memory_plan.boot_ram_size,
                .virtio_mem_region_size = memory_plan.virtio_mem_region_size,
                .cmdline = boot_args,
                .initrd = initrd,
                .console_sink = consoleSink,
                .disk_backend = runtime_disk.backend(),
                .disk_snapshot = runtime_disk.snapshot(),
                .rootfs = opts.rootfs,
                .network_manifest = network_manifest,
                .annotations = opts.annotations,
                .resume_dir = opts.resume_dir,
                .ram_backing_fd = local_backing.fd,
                .exec_probe = &stream,
                .exec_probe_timeout_ms = opts.timeout_ms,
                .snapshot_dir = capture_plan.snapshot_dir,
                .snapshot_on_probe_complete = capture_plan.snapshot_on_probe_complete,
                .capture_request = capture_plan.request,
                .continue_after_capture = capture_plan.continue_after_capture,
                .dirty_tracking = .{ .enabled = capture_plan.dirty_tracking.enabled, .epoch_ms = capture_plan.dirty_tracking.epoch_ms },
                .network = network,
                .environ_map = context.environ_map,
            });
        },
        .kvm => blk: {
            if (comptime !(builtin.os.tag == .linux and builtin.cpu.arch == .aarch64)) return error.UnsupportedBackend;
            break :blk kvm.vm.run(allocator, .{
                .kernel = kernel,
                .ram_size = memory_plan.boot_ram_size,
                .virtio_mem_region_size = memory_plan.virtio_mem_region_size,
                .cmdline = boot_args,
                .initrd = initrd,
                .console_sink = consoleSink,
                .disk_backend = runtime_disk.backend(),
                .disk_snapshot = runtime_disk.snapshot(),
                .rootfs = opts.rootfs,
                .network_manifest = network_manifest,
                .annotations = opts.annotations,
                .resume_dir = opts.resume_dir,
                .ram_backing_fd = local_backing.fd,
                .exec_probe = &stream,
                .exec_probe_timeout_ms = opts.timeout_ms,
                .snapshot_dir = capture_plan.snapshot_dir,
                .snapshot_on_probe_complete = capture_plan.snapshot_on_probe_complete,
                .capture_request = capture_plan.request,
                .continue_after_capture = capture_plan.continue_after_capture,
                .dirty_tracking = .{ .enabled = capture_plan.dirty_tracking.enabled, .epoch_ms = capture_plan.dirty_tracking.epoch_ms },
                .network = network,
                .environ_map = context.environ_map,
            });
        },
    }) catch |err| {
        if (capture_plan.isSignalCapture() and capture_request.isCompleted() and isCaptureAborted(err)) {
            var result = resultFromAbortedSignalCapture(backend, opts, &stream);
            if (resuming) result = result.withMemoryRestore(local_backing);
            finishGatewayNetworkEvents(&gateway, &gateway_active, &events);
            try events.emitExit(result);
            if (events.write_failed) return error.EventSinkFailed;
            return result;
        }
        return @errorCast(err);
    };
    const backend_run_ms = monotonicMs() -| backend_run_start;
    const response_ms = stream.response_ms orelse stream.elapsedMs();
    std.log.debug(
        "run backend timing: elapsed_ms={d} stream_response_ms={d} tail_ms={d} cause={s}",
        .{
            backend_run_ms,
            response_ms,
            if (backend_run_ms >= response_ms) backend_run_ms - response_ms else 0,
            @tagName(cause),
        },
    );
    if (gateway_active and gateway.hasFailed()) return error.NetworkGatewayFailed;
    const signal_capture_observed = capture_plan.isSignalCapture() and capture_request.isCompleted();
    var result = try switch (cause) {
        .probe_complete => resultFromStream(backend, opts, &stream, signal_capture_observed),
        .snapshotted => if (capture_plan.isExitCapture())
            resultFromExitCapture(backend, opts, &stream)
        else
            resultFromSignalCapture(backend, opts, &stream),
        else => error.ProbeDidNotComplete,
    };
    if (resuming) result = result.withMemoryRestore(local_backing);
    finishGatewayNetworkEvents(&gateway, &gateway_active, &events);
    try events.emitExit(result);
    if (events.write_failed) return error.EventSinkFailed;
    return result;
}

pub fn finishGatewayNetworkEvents(gateway: *net_gateway.Process, gateway_active: *bool, events: *EventEmitter) void {
    if (!gateway_active.*) return;
    gateway.deinit();
    gateway_active.* = false;
    while (gateway.popNetworkEvent()) |event| {
        events.emitNetworkEventBestEffort(event);
    }
}

const RunMemoryPlan = struct {
    boot_ram_size: u64,
    virtio_mem_region_size: u64,
};

const RunMemoryConstraints = struct {
    fixed_ram: bool = false,
    auto_hotplug_capable: bool = false,
};

fn runMemoryPlan(memory: memory_config.Config, constraints: RunMemoryConstraints) RunMemoryPlan {
    if (!constraints.fixed_ram and
        constraints.auto_hotplug_capable and
        memory.policy == .auto and
        memory.bytes > auto_boot_memory_bytes)
    {
        return .{
            .boot_ram_size = auto_boot_memory_bytes,
            .virtio_mem_region_size = memory.bytes - auto_boot_memory_bytes,
        };
    }
    return .{
        .boot_ram_size = memory.bytes,
        .virtio_mem_region_size = 0,
    };
}

pub fn executeMonitor(context: Context, allocator: std.mem.Allocator, opts: Options, control: vsock.Control) !MonitorResult {
    if (opts.vcpus != 1) return error.UnsupportedVcpuCount;
    try spore.validateAnnotations(opts.annotations);

    const backend = try resolveBackend(opts.backend);
    var gateway: net_gateway.Process = undefined;
    var gateway_active = false;
    const network: virtio_net.Runtime = if (opts.network_runtime) |runtime| runtime else blk: {
        if (opts.network == .spore) {
            try gateway.start(context.io, allocator, opts.spore_executable, opts.debug, opts.network_policy);
            gateway_active = true;
            break :blk gateway.runtime();
        }
        break :blk .{};
    };
    defer if (gateway_active) gateway.deinit();
    const network_manifest = try manifestNetworkFromOptions(allocator, opts.network, &opts.network_policy);
    const kernel = try std.Io.Dir.cwd().readFileAlloc(context.io, opts.kernel_path, allocator, .limited(max_file_size));
    const initrd = try loadRunInitrd(context.io, allocator, opts.initrd_path);
    var runtime_disk = try runtime_disk_mod.open(context, allocator, .{
        .rootfs_path = opts.rootfs_path,
        .rootfs = opts.rootfs,
        .disk = opts.disk,
        .spore_dir = opts.resume_dir,
    });
    defer runtime_disk.deinit();
    const has_rootfs = opts.rootfs_path != null or opts.rootfs != null;
    const boot_args = try cmdline(allocator, opts.guest_port, has_rootfs, rootfsWritable(opts), opts.network);

    const cause = switch (backend) {
        .auto => unreachable,
        .hvf => blk: {
            if (comptime !(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) return error.UnsupportedBackend;
            break :blk try hvf.vm.run(allocator, .{
                .kernel = kernel,
                .ram_size = opts.memory.bytes,
                .cmdline = boot_args,
                .initrd = initrd,
                .console_sink = consoleSink,
                .disk_backend = runtime_disk.backend(),
                .disk_snapshot = runtime_disk.snapshot(),
                .rootfs = opts.rootfs,
                .network_manifest = network_manifest,
                .annotations = opts.annotations,
                .resume_dir = opts.resume_dir,
                .ram_restore_mode = .eager_chunks,
                .exec_control = control,
                .network = network,
                .environ_map = context.environ_map,
            });
        },
        .kvm => blk: {
            if (comptime !(builtin.os.tag == .linux and builtin.cpu.arch == .aarch64)) return error.UnsupportedBackend;
            break :blk try kvm.vm.run(allocator, .{
                .kernel = kernel,
                .ram_size = opts.memory.bytes,
                .cmdline = boot_args,
                .initrd = initrd,
                .console_sink = consoleSink,
                .disk_backend = runtime_disk.backend(),
                .disk_snapshot = runtime_disk.snapshot(),
                .rootfs = opts.rootfs,
                .network_manifest = network_manifest,
                .annotations = opts.annotations,
                .resume_dir = opts.resume_dir,
                .ram_restore_mode = .eager_chunks,
                .exec_control = control,
                .network = network,
                .environ_map = context.environ_map,
            });
        },
    };
    if (network.failed()) return error.NetworkGatewayFailed;
    return switch (cause) {
        .monitor_stopped => .{ .backend = backend, .exit = .stopped },
        .snapshotted => .{ .backend = backend, .exit = .snapshotted },
        else => error.MonitorDidNotStopCleanly,
    };
}

fn openRunLocalMemoryBacking(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    resume_dir: ?[]const u8,
    ram_size: u64,
) !spore.LocalBackingPlan {
    const dir = resume_dir orelse return .{};
    const parsed = try spore.loadManifest(allocator, dir);
    defer parsed.deinit();
    const local_backing = try spore.openProvenLocalMemoryBacking(allocator, environ, dir, parsed.value.memory, ram_size);
    std.log.info("run --from memory restore source={s} reason={s}", .{ @tagName(local_backing.source), local_backing.reason });
    return local_backing;
}

pub var console_fd: std.c.fd_t = -1;

fn runOutputSink(_: ?*anyopaque, output: vsock.HostStreamOutput, bytes: []const u8) void {
    const fd: std.c.fd_t = switch (output) {
        .stdout => 1,
        .stderr => 2,
    };
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(fd, remaining.ptr, remaining.len);
        if (n <= 0) return;
        remaining = remaining[@intCast(n)..];
    }
}

fn runEventOutputSink(context: ?*anyopaque, output: vsock.HostStreamOutput, bytes: []const u8) void {
    const events: *EventEmitter = @ptrCast(@alignCast(context.?));
    events.emitOutputBestEffort(output, bytes);
}

fn runEventLifecycleSink(context: ?*anyopaque, event: vsock.HostStreamLifecycle) void {
    const events: *EventEmitter = @ptrCast(@alignCast(context.?));
    switch (event) {
        .ready => events.emitReadyBestEffort(),
    }
}

fn base64Alloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(out, bytes);
    return out;
}

pub fn consoleSink(bytes: []const u8) void {
    if (console_fd < 0) return;
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(console_fd, remaining.ptr, remaining.len);
        if (n <= 0) return;
        remaining = remaining[@intCast(n)..];
    }
}

pub fn openConsoleLog(path: ?[]const u8) !void {
    if (path == null) return;
    const pathz = try std.heap.page_allocator.dupeZ(u8, path.?);
    defer std.heap.page_allocator.free(pathz);
    const fd = std.c.open(pathz, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
    if (fd < 0) return error.ConsoleLogOpenFailed;
    console_fd = fd;
}

pub fn closeConsoleLog() void {
    if (console_fd >= 0) {
        _ = std.c.close(console_fd);
        console_fd = -1;
    }
}

pub fn execRequest(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    return execRequestWithSession(allocator, argv, "default");
}

fn execRequestForRun(context: Context, allocator: std.mem.Allocator, opts: Options, memory_pressure: bool) ![]const u8 {
    const resume_time_unix_ns: u64 = @intCast(Io.Clock.real.now(context.io).nanoseconds);
    if (opts.resume_dir == null) return execRequestWithSessionOptions(allocator, opts.command, "default", .{
        .env = opts.guest_env,
        .working_dir = opts.guest_working_dir,
        .resume_time_unix_ns = resume_time_unix_ns,
        .memory_pressure = memory_pressure,
    });

    const now = Io.Clock.real.now(context.io).nanoseconds;
    var nonce_bytes: [8]u8 = undefined;
    context.io.random(&nonce_bytes);
    const nonce = std.mem.readInt(u64, &nonce_bytes, .little);
    const session_id = try std.fmt.allocPrint(allocator, "run-{x}-{x}", .{ now, nonce });
    return execRequestWithSessionOptions(allocator, opts.command, session_id, .{
        .resume_time_unix_ns = resume_time_unix_ns,
        .memory_pressure = memory_pressure,
    });
}

pub fn execRequestWithSession(allocator: std.mem.Allocator, argv: []const []const u8, session_id: []const u8) ![]const u8 {
    return execRequestWithSessionOptions(allocator, argv, session_id, .{});
}

const GuestExecOptions = struct {
    env: []const []const u8 = &.{},
    working_dir: ?[]const u8 = null,
    resume_time_unix_ns: u64 = 0,
    memory_pressure: bool = false,
};

fn execRequestWithSessionOptions(allocator: std.mem.Allocator, argv: []const []const u8, session_id: []const u8, options: GuestExecOptions) ![]const u8 {
    try validateGuestArgv(argv);
    try validateGuestExecOptions(options);
    const payload = struct {
        type: []const u8 = "start",
        session_id: []const u8,
        resume_time_unix_ns: u64,
        argv: []const []const u8,
        env: []const []const u8,
        working_dir: []const u8,
        memory_pressure: bool,
        closed_env: bool = true,
    }{
        .session_id = session_id,
        .resume_time_unix_ns = options.resume_time_unix_ns,
        .argv = argv,
        .env = options.env,
        .working_dir = options.working_dir orelse "",
        .memory_pressure = options.memory_pressure,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

pub fn generationRequest(allocator: std.mem.Allocator, params_json: []const u8) ![]const u8 {
    const payload = struct {
        type: []const u8 = "generation",
        session_id: []const u8 = "default",
        params_json: []const u8,
    }{ .params_json = params_json };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

fn rootfsWritable(opts: Options) bool {
    // Manifest-bound rootfs runs get a COW head; plain --rootfs stays local/read-only.
    return opts.rootfs != null or opts.disk != null;
}

pub fn cmdline(allocator: std.mem.Allocator, guest_port: u32, rootfs: bool, rootfs_writable: bool, network: NetworkMode) ![]const u8 {
    const rootfs_flag = if (rootfs) " spore_rootfs=1" else "";
    const rootfs_rw_flag = if (rootfs and rootfs_writable) " spore_rootfs_rw=1" else "";
    const network_flag = if (network == .spore) " spore_net=1" else "";
    return std.fmt.allocPrint(
        allocator,
        "console=hvc0 rdinit=/init cleanroom_guest_port={d} cleanroom_guest_boot_timing=1{s}{s}{s}",
        .{ guest_port, rootfs_flag, rootfs_rw_flag, network_flag },
    );
}

fn resolveBackend(backend: Backend) !Backend {
    if (backend != .auto) return backend;
    if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) return .hvf;
    if (builtin.os.tag == .linux and builtin.cpu.arch == .aarch64) return .kvm;
    return error.UnsupportedBackend;
}

fn resultFromStream(backend: Backend, opts: Options, stream: *const vsock.HostStream, captured: bool) !Result {
    const start_ms = stream.start_ms orelse 0;
    const connect_ms = stream.connect_ms orelse stream.elapsedMs();
    const response_ms = stream.response_ms orelse stream.elapsedMs();
    std.log.debug(
        "run exec probe timing: attach_ms={?} connect_request_delivered_ms={?} connect_ms={?} request_delivered_ms={?} first_output_ms={?} guest_timing_ms={?} response_ms={?}",
        .{
            stream.attach_ms,
            stream.connect_request_delivered_ms,
            stream.connect_ms,
            stream.request_delivered_ms,
            stream.first_output_ms,
            stream.guest_timing_ms,
            stream.response_ms,
        },
    );
    return .{
        .backend = backend,
        .start_ms = start_ms,
        .vsock_connect_ms = connect_ms,
        .exec_response_ms = response_ms,
        .probe_duration_ms = if (response_ms >= connect_ms) response_ms - connect_ms else 0,
        .exit_code = stream.exit_code orelse return error.BadRunExitFrame,
        .vcpus = opts.vcpus,
        .memory_bytes = opts.memory.bytes,
        .captured = captured,
        .capture_path = if (captured) opts.capture_path else null,
    };
}

fn resultFromSignalCapture(backend: Backend, opts: Options, stream: *const vsock.HostStream) Result {
    return resultFromSignalCaptureExitCode(backend, opts, stream, 0);
}

fn resultFromAbortedSignalCapture(backend: Backend, opts: Options, stream: *const vsock.HostStream) Result {
    return resultFromSignalCaptureExitCode(backend, opts, stream, 130);
}

fn resultFromSignalCaptureExitCode(backend: Backend, opts: Options, stream: *const vsock.HostStream, exit_code: u8) Result {
    const start_ms = stream.start_ms orelse 0;
    const connect_ms = stream.connect_ms orelse stream.elapsedMs();
    const response_ms = stream.response_ms orelse stream.elapsedMs();
    return .{
        .backend = backend,
        .start_ms = start_ms,
        .vsock_connect_ms = connect_ms,
        .exec_response_ms = response_ms,
        .probe_duration_ms = if (response_ms >= connect_ms) response_ms - connect_ms else 0,
        .exit_code = exit_code,
        .vcpus = opts.vcpus,
        .memory_bytes = opts.memory.bytes,
        .captured = true,
        .capture_path = opts.capture_path,
    };
}

fn resultFromExitCapture(backend: Backend, opts: Options, stream: *const vsock.HostStream) !Result {
    const start_ms = stream.start_ms orelse 0;
    const connect_ms = stream.connect_ms orelse stream.elapsedMs();
    const response_ms = stream.response_ms orelse stream.elapsedMs();
    return .{
        .backend = backend,
        .start_ms = start_ms,
        .vsock_connect_ms = connect_ms,
        .exec_response_ms = response_ms,
        .probe_duration_ms = if (response_ms >= connect_ms) response_ms - connect_ms else 0,
        .exit_code = stream.exit_code orelse return error.BadRunExitFrame,
        .vcpus = opts.vcpus,
        .memory_bytes = opts.memory.bytes,
        .captured = true,
        .capture_path = opts.capture_path,
    };
}

pub fn isCaptureAborted(err: anyerror) bool {
    return std.mem.eql(u8, @errorName(err), "CaptureAborted");
}

pub fn isNetworkGatewayError(err: anyerror) bool {
    return std.mem.eql(u8, @errorName(err), "NetdSpawnFailed") or
        std.mem.eql(u8, @errorName(err), "NetdReadyTimedOut") or
        std.mem.eql(u8, @errorName(err), "NetdReadyFailed") or
        std.mem.eql(u8, @errorName(err), "NetdThreadFailed") or
        std.mem.eql(u8, @errorName(err), "NetworkGatewayFailed");
}

pub fn printNetworkGatewayError(err: anyerror) void {
    const message = if (std.mem.eql(u8, @errorName(err), "NetdSpawnFailed"))
        "spore run: failed to start spore-netd"
    else if (std.mem.eql(u8, @errorName(err), "NetdReadyTimedOut"))
        "spore run: spore-netd did not become ready"
    else if (std.mem.eql(u8, @errorName(err), "NetdReadyFailed"))
        "spore run: spore-netd failed before ready"
    else if (std.mem.eql(u8, @errorName(err), "NetdThreadFailed"))
        "spore run: failed to monitor spore-netd"
    else
        "spore run: spore-netd exited during run";
    std.debug.print("{s}\n", .{message});
}

fn parsePositive(comptime T: type, name: []const u8, raw: []const u8) !T {
    const parsed = std.fmt.parseInt(T, raw, 10) catch {
        std.debug.print("{s} must be a positive integer\n", .{name});
        std.process.exit(2);
    };
    if (parsed == 0) {
        std.debug.print("{s} must be a positive integer\n", .{name});
        std.process.exit(2);
    }
    return parsed;
}

fn parseGuestPort(name: []const u8, raw: []const u8) !u32 {
    const parsed = std.fmt.parseInt(u32, raw, 10) catch {
        std.debug.print("{s} must be an integer from 1 to {d}\n", .{ name, max_guest_port });
        std.process.exit(2);
    };
    if (parsed == 0 or parsed > max_guest_port) {
        std.debug.print("{s} must be an integer from 1 to {d}\n", .{ name, max_guest_port });
        std.process.exit(2);
    }
    return parsed;
}

fn validateGuestArgv(argv: []const []const u8) !void {
    if (argv.len == 0 or argv.len > max_guest_argc) return error.RunArgCountUnsupported;
    for (argv) |arg| {
        if (arg.len > max_guest_arg_len) return error.RunArgTooLong;
    }
}

fn validateGuestExecOptions(options: GuestExecOptions) !void {
    if (options.env.len > max_guest_envc) return error.RunEnvCountUnsupported;
    for (options.env) |entry| {
        if (entry.len > max_guest_env_len) return error.RunEnvTooLong;
    }
    if (options.working_dir) |dir| {
        if (dir.len == 0 or dir.len > max_guest_working_dir_len) return error.RunWorkingDirUnsupported;
    }
}

fn parseSharedOption(shared: *SharedOptions, args: []const []const u8, i: *usize) !bool {
    const name = args[i.*];
    if (std.mem.eql(u8, name, "--kernel")) {
        shared.kernel_path = takeValue(args, i, name);
    } else if (std.mem.eql(u8, name, "--initrd")) {
        shared.initrd_path = takeValue(args, i, name);
    } else if (std.mem.eql(u8, name, "--memory")) {
        shared.memory = memory_config.parseCliOrExit("spore run", takeValue(args, i, name));
        shared.memory_set = true;
    } else if (std.mem.eql(u8, name, "--memory-mib")) {
        memory_config.rejectMemoryMiBFlag("spore run");
    } else if (std.mem.eql(u8, name, "--vcpus")) {
        shared.vcpus = try parsePositive(u32, name, takeValue(args, i, name));
    } else if (std.mem.eql(u8, name, "--guest-port")) {
        shared.guest_port = try parseGuestPort(name, takeValue(args, i, name));
    } else if (std.mem.eql(u8, name, "--timeout-ms")) {
        shared.timeout_ms = try parsePositive(u64, name, takeValue(args, i, name));
    } else if (std.mem.eql(u8, name, "--console-log")) {
        shared.console_log_path = takeValue(args, i, name);
    } else {
        return false;
    }
    return true;
}

fn takeValue(args: []const []const u8, i: *usize, name: []const u8) []const u8 {
    if (i.* + 1 >= args.len) {
        std.debug.print("{s} requires a value\n", .{name});
        std.process.exit(2);
    }
    i.* += 1;
    return args[i.*];
}

test "run request encodes argv" {
    const request = try execRequest(std.testing.allocator, &.{ "/bin/echo", "hello world" });
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings("{\"type\":\"start\",\"session_id\":\"default\",\"resume_time_unix_ns\":0,\"argv\":[\"/bin/echo\",\"hello world\"],\"env\":[],\"working_dir\":\"\",\"memory_pressure\":false,\"closed_env\":true}\n", request);
}

test "run request can encode explicit session id" {
    const request = try execRequestWithSession(std.testing.allocator, &.{"/bin/true"}, "lifecycle-42");
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings("{\"type\":\"start\",\"session_id\":\"lifecycle-42\",\"resume_time_unix_ns\":0,\"argv\":[\"/bin/true\"],\"env\":[],\"working_dir\":\"\",\"memory_pressure\":false,\"closed_env\":true}\n", request);
}

test "run request encodes image env and working directory" {
    const request = try execRequestWithSessionOptions(std.testing.allocator, &.{ "/bin/sh", "-lc", "env && pwd" }, "default", .{
        .env = &.{ "GEM_HOME=/usr/local/bundle", "RUBYOPT=--yjit" },
        .working_dir = "/app",
        .resume_time_unix_ns = 123,
        .memory_pressure = true,
    });
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings("{\"type\":\"start\",\"session_id\":\"default\",\"resume_time_unix_ns\":123,\"argv\":[\"/bin/sh\",\"-lc\",\"env && pwd\"],\"env\":[\"GEM_HOME=/usr/local/bundle\",\"RUBYOPT=--yjit\"],\"working_dir\":\"/app\",\"memory_pressure\":true,\"closed_env\":true}\n", request);
}

test "image rootfs metadata supplies run env and working directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-image-config";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, cache_root);

    const resolved = rootfs_mod.ResolvedImage{
        .ref = "local/buildkite-spore@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .manifest_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = .{},
    };
    const metadata_path = try rootfs_mod.cachedImageRootfsMetadataPath(arena, cache_root, resolved);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = metadata_path,
        .data =
        \\{
        \\  "config": {
        \\    "architecture": "arm64",
        \\    "os": "linux",
        \\    "config": {
        \\      "Env": ["GEM_HOME=/usr/local/bundle", "BUNDLE_APP_CONFIG=/usr/local/bundle"],
        \\      "WorkingDir": "/app"
        \\    }
        \\  }
        \\}
        ,
    });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var process_arena = std.heap.ArenaAllocator.init(allocator);
    defer process_arena.deinit();
    const init = std.process.Init{
        .minimal = undefined,
        .arena = &process_arena,
        .gpa = allocator,
        .io = io,
        .environ_map = &env,
        .preopens = .empty,
    };

    const rootfs_path = tmp ++ "/rootfs.ext4";
    const input = try resolvedImageRootfsInput(init, arena, cache_root, "local/buildkite-spore:ci", resolved, rootfs_path, false);
    try std.testing.expectEqual(@as(usize, 2), input.guest_env.len);
    try std.testing.expectEqualStrings("GEM_HOME=/usr/local/bundle", input.guest_env[0]);
    try std.testing.expectEqualStrings("BUNDLE_APP_CONFIG=/usr/local/bundle", input.guest_env[1]);
    try std.testing.expectEqualStrings("/app", input.guest_working_dir.?);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = ("abcd" ** 1024) ++ ("efgh" ** 1024) });
    const captured = try resolvedImageRootfsInput(init, arena, cache_root, "local/buildkite-spore:ci", resolved, rootfs_path, true);
    try std.testing.expect(captured.rootfs != null);
    try std.testing.expect(rootfsWritable(.{
        .kernel_path = "",
        .rootfs_path = captured.path,
        .rootfs = captured.rootfs,
        .command = &.{"/bin/true"},
    }));
}

test "generation request encodes params json as a string" {
    const request = try generationRequest(std.testing.allocator, "{\"parallel_index\":2,\"parallel_count\":5}");
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings("{\"type\":\"generation\",\"session_id\":\"default\",\"params_json\":\"{\\\"parallel_index\\\":2,\\\"parallel_count\\\":5}\"}\n", request);
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
        .memory_bytes = memory_config.auto_bytes,
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
    try expectJsonStringField(allocator, start_line, "schema", machine_output.run_events_schema);
    try expectJsonStringField(allocator, start_line, "event", "start");
    try expectJsonStringField(allocator, ready_line, "event", "ready");
    try expectJsonStringField(allocator, ready_line, "backend", "hvf");
    try expectJsonStringField(allocator, stdout_line, "event", "stdout");
    try expectJsonStringField(allocator, stdout_line, "data_base64", "aGkK");
    try expectJsonStringField(allocator, exit_line, "event", "exit");
    try expectJsonStringField(allocator, exit_line, "memory_restore_source", "local_backing");
    try expectJsonStringField(allocator, exit_line, "memory_restore_reason", "proof_valid");
}

test "event writer emits exactly one terminal failure" {
    const allocator = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var events = EventWriter.init(allocator, &out.writer, "run");
    const sink = events.sink();

    try sink.emit(.{ .failure = .{ .command = "run", .backend = null, .classified = classifyFailure(error.BadChunk) } });
    try events.emitExit(.{
        .backend = .hvf,
        .start_ms = 1,
        .vsock_connect_ms = 2,
        .exec_response_ms = 3,
        .probe_duration_ms = 1,
        .exit_code = 0,
        .vcpus = 1,
        .memory_bytes = memory_config.auto_bytes,
    });

    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    const failure_line = lines.next().?;
    try std.testing.expectEqualStrings("", lines.next().?);
    try expectJsonStringField(allocator, failure_line, "event", "failure");
    try expectNestedJsonStringField(allocator, failure_line, "error", "code", "cache.integrity_failed");
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

fn failingEventSink(_: ?*anyopaque, _: RunEvent) !void {
    return error.TestEventSinkFailed;
}

test "event emitter records best-effort sink failures" {
    var events = EventEmitter.init(.{ .emitFn = failingEventSink }, "run");
    events.emitOutputBestEffort(.stdout, "lost\n");
    try std.testing.expect(events.write_failed);
}

test "run request rejects guest argv count overflow" {
    const argv = [_][]const u8{
        "/bin/true", "1",  "2",  "3",
        "4",         "5",  "6",  "7",
        "8",         "9",  "10", "11",
        "12",        "13", "14", "15",
        "16",
    };
    try std.testing.expectError(error.RunArgCountUnsupported, execRequest(std.testing.allocator, &argv));
}

test "run request rejects guest argv length overflow" {
    var arg = [_]u8{'a'} ** (max_guest_arg_len + 1);
    try std.testing.expectError(error.RunArgTooLong, execRequest(std.testing.allocator, &.{arg[0..]}));
}

test "run request rejects encoded line overflow" {
    var env_entry = [_]u8{'A'} ** max_guest_env_len;
    var env: [max_guest_envc][]const u8 = undefined;
    for (&env) |*slot| slot.* = env_entry[0..];
    try std.testing.expectError(error.RunRequestTooLarge, execRequestWithSessionOptions(std.testing.allocator, &.{"/bin/true"}, "default", .{ .env = &env }));
}

fn testDiskGuardManifest(with_disk: bool) spore.Manifest {
    return .{
        .platform = .{
            .cpu_profile = "test",
            .device_model_version = 1,
            .ram_base = 0x8000_0000,
            .ram_size = 0,
            .gic_dist_base = 0x0800_0000,
            .gic_redist_base = 0x0801_0000,
            .counter_frequency_hz = 24_000_000,
        },
        .machine = .{
            .gprs = [_]u64{0} ** 31,
            .pc = 0,
            .cpsr = 0,
            .fpcr = 0,
            .fpsr = 0,
            .simd = [_][2]u64{.{ 0, 0 }} ** 32,
            .sys_regs = &.{},
            .icc_regs = &.{},
            .vtimer = .{ .cntvct = 0, .cntv_ctl = 0, .cntv_cval = 0 },
            .gic = .{
                .kind = .gicv3,
                .gicv3 = .{
                    .dist_regs = &.{},
                    .redist_regs = &.{},
                    .line_levels = &.{},
                },
            },
        },
        .devices = &.{},
        .generation = .{ .generation = 0, .interrupt_status = 0, .params_b64 = "" },
        .disk = if (with_disk) .{
            .device = .{ .mmio_slot = 0 },
            .size = 4096,
            .base = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        } else null,
        .memory = .{ .chunk_size = spore.chunk_size, .chunks = &.{} },
    };
}

test "run from carries writable disk manifests into runtime options" {
    try std.testing.expect((try resumeDiskForRun(std.testing.allocator, testDiskGuardManifest(false))) == null);
    const disk = (try resumeDiskForRun(std.testing.allocator, testDiskGuardManifest(true))).?;
    defer {
        std.testing.allocator.free(disk.kind);
        std.testing.allocator.free(disk.device.kind);
        std.testing.allocator.free(disk.device.role);
        std.testing.allocator.free(disk.base);
        std.testing.allocator.free(disk.layers);
    }
    try std.testing.expectEqualStrings("blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", disk.base);
}

test "run cli parser accepts command after separator" {
    const opts = try parseCliArgs(&.{ "--backend", "hvf", "--kernel", "Image", "--initrd", "root.cpio", "--", "/bin/true" });
    try std.testing.expectEqual(Backend.hvf, opts.backend);
    try std.testing.expectEqualStrings("Image", opts.shared.kernel_path.?);
    try std.testing.expectEqualStrings("root.cpio", opts.shared.initrd_path.?);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("/bin/true", opts.command[0]);
}

test "run cli parser allows default boot assets" {
    const opts = try parseCliArgs(&.{ "--", "/bin/writeout" });
    try std.testing.expectEqual(Backend.auto, opts.backend);
    try std.testing.expect(opts.shared.kernel_path == null);
    try std.testing.expect(opts.shared.initrd_path == null);
    try std.testing.expectEqual(memory_config.Policy.auto, opts.shared.memory.policy);
    try std.testing.expectEqual(memory_config.auto_bytes, opts.shared.memory.bytes);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("/bin/writeout", opts.command[0]);
}

test "run cli parser accepts memory policy" {
    const auto_opts = try parseCliArgs(&.{ "--memory", "auto", "--", "/bin/true" });
    try std.testing.expectEqual(memory_config.Policy.auto, auto_opts.shared.memory.policy);
    try std.testing.expectEqual(memory_config.auto_bytes, auto_opts.shared.memory.bytes);
    try std.testing.expect(auto_opts.shared.memory_set);

    const explicit_opts = try parseCliArgs(&.{ "--memory", "16gb", "--", "/bin/true" });
    try std.testing.expectEqual(memory_config.Policy.explicit, explicit_opts.shared.memory.policy);
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024 * 1024), explicit_opts.shared.memory.bytes);
    try std.testing.expect(explicit_opts.shared.memory_set);
}

test "run memory plan selects virtio-mem only for capable fresh auto runs" {
    const auto = memory_config.Config{};
    const hotplug = runMemoryPlan(auto, .{ .auto_hotplug_capable = true });
    try std.testing.expectEqual(auto_boot_memory_bytes, hotplug.boot_ram_size);
    try std.testing.expectEqual(memory_config.auto_bytes - auto_boot_memory_bytes, hotplug.virtio_mem_region_size);

    const custom_assets = runMemoryPlan(auto, .{});
    try std.testing.expectEqual(memory_config.auto_bytes, custom_assets.boot_ram_size);
    try std.testing.expectEqual(@as(u64, 0), custom_assets.virtio_mem_region_size);

    const capture_or_resume = runMemoryPlan(auto, .{ .fixed_ram = true, .auto_hotplug_capable = true });
    try std.testing.expectEqual(memory_config.auto_bytes, capture_or_resume.boot_ram_size);
    try std.testing.expectEqual(@as(u64, 0), capture_or_resume.virtio_mem_region_size);

    const explicit = memory_config.Config{ .policy = .explicit, .bytes = 1024 * 1024 * 1024 };
    const explicit_plan = runMemoryPlan(explicit, .{ .auto_hotplug_capable = true });
    try std.testing.expectEqual(explicit.bytes, explicit_plan.boot_ram_size);
    try std.testing.expectEqual(@as(u64, 0), explicit_plan.virtio_mem_region_size);
}

test "run cli parser accepts rootfs path" {
    const opts = try parseCliArgs(&.{ "--rootfs", "rootfs.ext4", "--", "/bin/echo", "hi" });
    try std.testing.expectEqualStrings("rootfs.ext4", opts.rootfs_path.?);
    try std.testing.expectEqual(@as(usize, 2), opts.command.len);
    try std.testing.expectEqualStrings("/bin/echo", opts.command[0]);
    try std.testing.expectEqualStrings("hi", opts.command[1]);
}

test "run cli parser accepts image ref" {
    const opts = try parseCliArgs(&.{ "--image", "docker.io/library/alpine:3.20", "--", "/bin/echo", "hi" });
    try std.testing.expect(opts.rootfs_path == null);
    try std.testing.expectEqualStrings("docker.io/library/alpine:3.20", opts.image_ref.?);
    try std.testing.expectEqual(PullPolicy.missing, opts.pull_policy);
    try std.testing.expectEqual(@as(usize, 2), opts.command.len);
    try std.testing.expectEqualStrings("/bin/echo", opts.command[0]);
    try std.testing.expectEqualStrings("hi", opts.command[1]);
}

test "run cli parser accepts image pull policy" {
    const equals_opts = try parseCliArgs(&.{ "--pull=always", "--image", "docker.io/library/alpine:3.20", "--", "/bin/true" });
    try std.testing.expectEqual(PullPolicy.always, equals_opts.pull_policy);

    const value_opts = try parseCliArgs(&.{ "--image", "docker.io/library/alpine:3.20", "--pull", "never", "--", "/bin/true" });
    try std.testing.expectEqual(PullPolicy.never, value_opts.pull_policy);
}

test "run pull policy routes mutable image ref cache lookups" {
    try std.testing.expect(useMutableImageRefCache(.missing));
    try std.testing.expect(!useMutableImageRefCache(.always));
    try std.testing.expect(useMutableImageRefCache(.never));
}

test "run pull never fails closed on mutable image ref cache miss" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-image-pull-never-cache-miss";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, tmp ++ "/cache");
    var process_arena = std.heap.ArenaAllocator.init(allocator);
    defer process_arena.deinit();
    const init = std.process.Init{
        .minimal = undefined,
        .arena = &process_arena,
        .gpa = allocator,
        .io = io,
        .environ_map = &env,
        .preopens = .empty,
    };

    const result = try resolveRootfsInputDetailedResult(init, arena, .{
        .rootfs_path = null,
        .image_ref = "docker.io/library/alpine:3.20",
        .pull_policy = .never,
        .command_name = "run",
    });
    switch (result) {
        .resolved => return error.ExpectedPullNeverCacheMiss,
        .failure => |failure| {
            try std.testing.expectEqual(machine_output.ErrorCode.object_not_found, failure.code);
            try std.testing.expect(std.mem.indexOf(u8, failure.message, "--pull=never") != null);
        },
    }
}

test "run cli parser accepts source spore" {
    const opts = try parseCliArgs(&.{ "--from", "base.spore", "--", "/bin/writeout" });
    try std.testing.expectEqualStrings("base.spore", opts.from_spore_dir.?);
    try std.testing.expect(opts.rootfs_path == null);
    try std.testing.expect(opts.image_ref == null);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("/bin/writeout", opts.command[0]);
}

test "run cli parser accepts net flag" {
    const opts = try parseCliArgs(&.{ "--net", "--", "/bin/true" });
    try std.testing.expectEqual(NetworkMode.spore, opts.network);
    try std.testing.expect(opts.network_requested);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("/bin/true", opts.command[0]);
}

test "run cli parser accepts network allow rules" {
    const opts = try parseCliArgs(&.{
        "--net",
        "--allow-cidr",
        "93.184.216.34/32",
        "--allow-host",
        "example.com",
        "--",
        "/bin/true",
    });
    try std.testing.expectEqual(NetworkMode.spore, opts.network);
    try std.testing.expect(opts.network_requested);
    try std.testing.expectEqual(@as(usize, 1), opts.network_policy.allow_cidr_count);
    try std.testing.expectEqualStrings("93.184.216.34/32", opts.network_policy.allow_cidrs[0]);
    try std.testing.expectEqual(@as(usize, 1), opts.network_policy.allow_host_count);
    try std.testing.expectEqualStrings("example.com", opts.network_policy.allow_hosts[0]);
    try std.testing.expectEqualStrings("/bin/true", opts.command[0]);
}

test "run cli parser accepts network bind services" {
    const opts = try parseCliArgs(&.{
        "--net",
        "--bind-service",
        "metadata=unix:/tmp/metadata.sock",
        "--",
        "/bin/true",
    });
    try std.testing.expectEqual(NetworkMode.spore, opts.network);
    try std.testing.expect(opts.network_requested);
    try std.testing.expectEqual(@as(usize, 1), opts.network_policy.bound_service_count);
    try std.testing.expectEqualStrings("metadata", opts.network_policy.bound_services[0].name);
    try std.testing.expectEqualStrings("/tmp/metadata.sock", opts.network_policy.bound_services[0].unix_path);
}

test "run restores network options from manifest policy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const manifest_network = spore.Network{
        .default_action = spore.network_default_deny,
        .allow_cidrs = &.{"93.184.216.34/32"},
        .allow_hosts = &.{"example.com"},
        .allow_host_ports = &.{.{
            .host = "github.com",
            .ports = &.{443},
        }},
    };

    const opts = try networkOptionsFromManifest(arena, manifest_network);
    try std.testing.expectEqual(NetworkMode.spore, opts.network);
    try std.testing.expect(opts.policy.default_deny);
    try std.testing.expectEqual(@as(usize, 1), opts.policy.allow_cidr_count);
    try std.testing.expectEqualStrings("93.184.216.34/32", opts.policy.allow_cidrs[0]);
    try std.testing.expectEqual(@as(usize, 1), opts.policy.allow_host_count);
    try std.testing.expectEqualStrings("example.com", opts.policy.allow_hosts[0]);
    try std.testing.expectEqual(@as(usize, 1), opts.policy.exact_rule_count);
    try std.testing.expectEqualStrings("github.com", opts.policy.exact_rules[0].host);
    try std.testing.expectEqual(@as(u16, 443), opts.policy.exact_rules[0].ports[0]);

    const disabled = try networkOptionsFromManifest(arena, null);
    try std.testing.expectEqual(NetworkMode.disabled, disabled.network);
    try std.testing.expect(!disabled.policy.hasRules());
}

test "run builds manifest network from active policy" {
    var policy = spore_net_policy.Config{};
    try policy.addAllowCidr("93.184.216.34/32");
    try policy.addAllowHost("example.com");
    try policy.addNetworkPolicy(.{
        .allow = &.{.{
            .host = "github.com",
            .ports = &.{443},
        }},
    });

    const network = (try manifestNetworkFromOptions(std.testing.allocator, .spore, &policy)) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(network.allow_host_ports);
    defer std.testing.allocator.free(network.bound_services);
    try std.testing.expectEqualStrings(spore.network_kind_spore, network.kind);
    try std.testing.expectEqualStrings(spore.network_default_deny, network.default_action.?);
    try std.testing.expectEqualStrings("93.184.216.34/32", network.allow_cidrs[0]);
    try std.testing.expectEqualStrings("example.com", network.allow_hosts[0]);
    try std.testing.expectEqualStrings("github.com", network.allow_host_ports[0].host);
    try std.testing.expectEqual(@as(u16, 443), network.allow_host_ports[0].ports[0]);
    try std.testing.expect(network.requirements.exact_host_port);

    try std.testing.expect((try manifestNetworkFromOptions(std.testing.allocator, .disabled, &policy)) == null);
}

test "run refuses to restore captured bound services without live bindings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const manifest_network = spore.Network{
        .bound_services = &.{.{
            .name = "cleanroom-gateway",
            .guest_host = "gateway.cleanroom.internal",
            .guest_port = 8170,
        }},
        .requirements = .{ .bound_services = true },
    };

    try std.testing.expectError(error.UnsupportedBoundServiceRestore, networkOptionsFromManifest(arena, manifest_network));
}

test "run network gateway errors are reported clearly" {
    try std.testing.expect(isNetworkGatewayError(error.NetdSpawnFailed));
    try std.testing.expect(isNetworkGatewayError(error.NetdReadyTimedOut));
    try std.testing.expect(isNetworkGatewayError(error.NetdReadyFailed));
    try std.testing.expect(isNetworkGatewayError(error.NetdThreadFailed));
    try std.testing.expect(isNetworkGatewayError(error.NetworkGatewayFailed));
    try std.testing.expect(!isNetworkGatewayError(error.UnsupportedBackend));
}

test "run cli parser accepts capture flags" {
    const opts = try parseCliArgs(&.{ "--capture", "out.spore", "--capture-on", "USR1", "--continue-after-capture", "--", "/bin/sleeper" });
    try std.testing.expectEqualStrings("out.spore", opts.capture_path.?);
    try std.testing.expectEqual(capture.Signal.USR1, opts.capture_trigger.signalValue().?);
    try std.testing.expect(opts.continue_after_capture);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("/bin/sleeper", opts.command[0]);
}

test "run cli parser accepts jsonl events" {
    const opts = try parseCliArgs(&.{ "--events=jsonl", "--", "/bin/true" });
    try std.testing.expectEqual(EventMode.jsonl, opts.event_mode);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("/bin/true", opts.command[0]);
}

test "run cli parser defaults capture trigger to exit" {
    const opts = try parseCliArgs(&.{ "--capture", "out.spore", "--", "/bin/true" });
    try std.testing.expectEqualStrings("out.spore", opts.capture_path.?);
    try std.testing.expect(opts.capture_trigger.isExit());
    try std.testing.expect(!opts.continue_after_capture);
}

test "captured run result exits zero" {
    const result = Result{
        .backend = .hvf,
        .start_ms = 1,
        .vsock_connect_ms = 2,
        .exec_response_ms = 3,
        .probe_duration_ms = 1,
        .exit_code = 0,
        .vcpus = 1,
        .memory_bytes = memory_config.auto_bytes,
        .captured = true,
        .capture_path = "out.spore",
    };
    try std.testing.expectEqual(@as(u8, 0), result.processExitCode());
}

test "captured run result preserves stored exit code" {
    const result = Result{
        .backend = .hvf,
        .start_ms = 1,
        .vsock_connect_ms = 2,
        .exec_response_ms = 3,
        .probe_duration_ms = 1,
        .exit_code = 7,
        .vcpus = 1,
        .memory_bytes = memory_config.auto_bytes,
        .captured = true,
        .capture_path = "out.spore",
    };
    try std.testing.expectEqual(@as(u8, 7), result.processExitCode());
}

test "rootfs digest cache verifies exact bytes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-rootfs-digest-cache";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });

    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    try std.testing.expect(std.mem.startsWith(u8, artifact.digest, spore.rootfs_digest_prefix));
    try std.testing.expectEqual(@as(u64, "rootfs bytes".len), artifact.size);

    const rootfs = spore.Rootfs{ .device = .{ .mmio_slot = 1 }, .artifact = artifact };
    const fd = try rootfs_cache.openVerifiedFromCache(io, arena, cache_root, rootfs);
    _ = std.c.close(fd);

    const digest_path = try rootfs_cache.digestPath(arena, cache_root, artifact.digest);
    const stat = try Io.Dir.cwd().statFile(io, digest_path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o444), @as(u32, @intCast(@intFromEnum(stat.permissions) & 0o777)));

    try Io.Dir.cwd().deleteFile(io, digest_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = digest_path, .data = "tampered" });
    try std.testing.expectError(error.RootFSDigestMismatch, rootfs_cache.openVerifiedFromCache(io, arena, cache_root, rootfs));
}

test "explicit rootfs input can record exact immutable identity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-explicit-rootfs-record-artifact";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });
    try Io.Dir.cwd().setFilePermissions(io, rootfs_path, @enumFromInt(0o644), .{});

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const absolute_cache_root = try std.fs.path.resolve(arena, &.{cache_root});
    try env.put(local_paths.rootfs_cache_env, absolute_cache_root);
    var process_arena = std.heap.ArenaAllocator.init(allocator);
    defer process_arena.deinit();
    const init = std.process.Init{
        .minimal = undefined,
        .arena = &process_arena,
        .gpa = allocator,
        .io = io,
        .environ_map = &env,
        .preopens = .empty,
    };

    const result = try resolveRootfsInputDetailedResult(init, arena, .{
        .rootfs_path = rootfs_path,
        .image_ref = null,
        .command_name = "create",
        .record_artifact = true,
    });
    const resolved = switch (result) {
        .resolved => |resolved| resolved,
        .failure => return error.ExpectedRootfsRecord,
    };
    try std.testing.expectEqualStrings(rootfs_path, resolved.path.?);
    try std.testing.expect(resolved.rootfs != null);
    try std.testing.expect(resolved.rootfs.?.storage == null);
    try std.testing.expect(resolved.rootfs.?.source == null);
    try std.testing.expectEqual(@as(u32, 1), resolved.rootfs.?.device.mmio_slot);
    try std.testing.expectEqual(@as(u64, "rootfs bytes".len), resolved.rootfs.?.artifact.size);

    const digest_path = try rootfs_cache.digestPath(arena, absolute_cache_root, resolved.rootfs.?.artifact.digest);
    try Io.Dir.cwd().access(io, digest_path, .{ .read = true });
    const source_stat = try Io.Dir.cwd().statFile(io, rootfs_path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o644), @as(u32, @intCast(@intFromEnum(source_stat.permissions) & 0o777)));
}

test "rootfs digest cache rejects unsafe existing paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-rootfs-digest-cache-symlink";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });

    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const digest_path = try rootfs_cache.digestPath(arena, cache_root, artifact.digest);
    try Io.Dir.cwd().deleteFile(io, digest_path);
    const digest_z = try arena.dupeZ(u8, digest_path);
    const rootfs_z = try arena.dupeZ(u8, rootfs_path);
    if (std.c.symlink(rootfs_z, digest_z) != 0) return error.SkipZigTest;

    try std.testing.expectError(error.RootFSDigestMismatch, rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path));
}

test "run image cache creates absolute cache directories" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = "zig-cache/test-run-image-cache-dir";
    const nested = root ++ "/a/b";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};

    const absolute_nested = try std.fs.path.resolve(allocator, &.{nested});
    defer allocator.free(absolute_nested);
    try ensureDirPath(io, absolute_nested);
    try Io.Dir.cwd().access(io, nested, .{});
}

test "run cmdline marks rootfs mode" {
    const without_rootfs = try cmdline(std.testing.allocator, 10700, false, false, .disabled);
    defer std.testing.allocator.free(without_rootfs);
    try std.testing.expect(std.mem.indexOf(u8, without_rootfs, "spore_rootfs=1") == null);
    try std.testing.expect(std.mem.indexOf(u8, without_rootfs, "spore_rootfs_rw=1") == null);

    const with_rootfs = try cmdline(std.testing.allocator, 10700, true, false, .disabled);
    defer std.testing.allocator.free(with_rootfs);
    try std.testing.expect(std.mem.indexOf(u8, with_rootfs, "spore_rootfs=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_rootfs, "spore_rootfs_rw=1") == null);

    const with_writable_rootfs = try cmdline(std.testing.allocator, 10700, true, true, .disabled);
    defer std.testing.allocator.free(with_writable_rootfs);
    try std.testing.expect(std.mem.indexOf(u8, with_writable_rootfs, "spore_rootfs=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_writable_rootfs, "spore_rootfs_rw=1") != null);
}

test "run rootfs path stays read-only without manifest rootfs metadata" {
    try std.testing.expect(!rootfsWritable(.{
        .kernel_path = "",
        .rootfs_path = "rootfs.ext4",
        .command = &.{"/bin/true"},
    }));
}

test "run cmdline marks network mode" {
    const without_network = try cmdline(std.testing.allocator, 10700, false, false, .disabled);
    defer std.testing.allocator.free(without_network);
    try std.testing.expect(std.mem.indexOf(u8, without_network, "spore_net=1") == null);

    const with_network = try cmdline(std.testing.allocator, 10700, false, false, .spore);
    defer std.testing.allocator.free(with_network);
    try std.testing.expect(std.mem.indexOf(u8, with_network, "spore_net=1") != null);
}

test "run embeds default initrd" {
    try std.testing.expect(embedded_run_initrd.len > 0);
}

test "managed run kernel asset names validate input" {
    const allocator = std.testing.allocator;
    const asset = try managedRunKernelAssetName(allocator, "6.1.155");
    defer allocator.free(asset);
    try std.testing.expectEqualStrings("sporevm-arm64-linux-6.1.155-Image", asset);

    const config_asset = try managedRunKernelConfigAssetName(allocator, asset);
    defer allocator.free(config_asset);
    try std.testing.expectEqualStrings("sporevm-arm64-linux-6.1.155-Image.config", config_asset);

    try std.testing.expectError(error.BadManagedKernelVersion, managedRunKernelAssetName(allocator, "../bad"));
}

test "managed kernel repository cache name validates owner and repo" {
    const allocator = std.testing.allocator;
    const cache = try managedKernelRepositoryCacheName(allocator, "sporevm/kernels");
    defer allocator.free(cache);
    try std.testing.expectEqualStrings("sporevm-kernels", cache);

    try std.testing.expectError(error.BadManagedKernelRepository, managedKernelRepositoryCacheName(allocator, "buildkite"));
    try std.testing.expectError(error.BadManagedKernelRepository, managedKernelRepositoryCacheName(allocator, "../sporevm-kernels"));
}

test "managed kernel checksum parser reads sha256 sidecar" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-run-kernel-checksum";
    Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try ensureDirPath(io, tmp);
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};

    const sha_path = tmp ++ "/Image.sha256";
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = sha_path,
        .data = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  Image\n",
    });

    const expected = try readExpectedSha256(io, allocator, sha_path);
    defer allocator.free(expected);
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", expected);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = sha_path, .data = "not-a-sha\n" });
    try std.testing.expectError(error.BadManagedKernelChecksum, readExpectedSha256(io, allocator, sha_path));
}

test "managed kernel cache hit trusts read-only image with checksum sidecar" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-run-kernel-cache-hit";
    Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try ensureDirPath(io, tmp);
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};

    const image_path = tmp ++ "/Image";
    const sha_path = tmp ++ "/Image.sha256";
    const config_path = tmp ++ "/Image.config";
    const bad_sha_path = tmp ++ "/Image.bad.sha256";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = image_path, .data = "kernel bytes" });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = sha_path,
        .data = "8daf3e4f39d310222b89e05b97f1aa56319811c728a147e8c6c86448f534194f  Image\n",
    });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = config_path,
        .data = "CONFIG_FILE_LOCKING=y\n" ++
            "CONFIG_CGROUPS=y\n" ++
            "CONFIG_HW_RANDOM=y\n" ++
            "CONFIG_HW_RANDOM_VIRTIO=y\n" ++
            "CONFIG_SHMEM=y\n" ++
            "CONFIG_TMPFS=y\n" ++
            "CONFIG_FSNOTIFY=y\n" ++
            "CONFIG_INOTIFY_USER=y\n" ++
            "CONFIG_BPF_SYSCALL=y\n" ++
            "CONFIG_CGROUP_BPF=y\n" ++
            "CONFIG_MEMCG=y\n" ++
            "CONFIG_CGROUP_PIDS=y\n" ++
            "CONFIG_CPUSETS=y\n" ++
            "CONFIG_CGROUP_DEVICE=y\n" ++
            "CONFIG_MEMORY_HOTPLUG=y\n" ++
            "CONFIG_MEMORY_HOTPLUG_DEFAULT_ONLINE=y\n" ++
            "CONFIG_MEMORY_HOTREMOVE=y\n" ++
            "CONFIG_CONTIG_ALLOC=y\n" ++
            "CONFIG_EXCLUSIVE_SYSTEM_RAM=y\n" ++
            "CONFIG_VIRTIO_MEM=y\n",
    });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = bad_sha_path, .data = "not-a-sha\n" });

    try std.testing.expect(!try managedKernelCacheHit(io, allocator, image_path, sha_path, config_path));
    try chmodFileReadOnly(allocator, image_path);
    try std.testing.expect(!try managedKernelCacheHit(io, allocator, image_path, sha_path, config_path));
    try chmodFileReadOnly(allocator, sha_path);
    try std.testing.expect(!try managedKernelCacheHit(io, allocator, image_path, sha_path, config_path));
    try chmodFileReadOnly(allocator, config_path);
    try std.testing.expect(try managedKernelCacheHit(io, allocator, image_path, sha_path, config_path));

    try chmodFileWritable(allocator, image_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = image_path, .data = "tampered kernel bytes" });
    try chmodFileReadOnly(allocator, image_path);
    try std.testing.expect(!try managedKernelCacheHit(io, allocator, image_path, sha_path, config_path));

    try chmodFileReadOnly(allocator, bad_sha_path);
    try std.testing.expect(!try managedKernelCacheHit(io, allocator, image_path, bad_sha_path, config_path));
}

test "managed run kernel config requires Docker and virtio-mem runtime symbols" {
    const allocator = std.testing.allocator;
    const good_config =
        "# CONFIG_DEVMEM is not set\n" ++
        "CONFIG_FILE_LOCKING=y\n" ++
        "CONFIG_CGROUPS=y\n" ++
        "CONFIG_HW_RANDOM=y\n" ++
        "CONFIG_HW_RANDOM_VIRTIO=y\n" ++
        "CONFIG_SHMEM=y\n" ++
        "CONFIG_TMPFS=y\n" ++
        "CONFIG_FSNOTIFY=y\n" ++
        "CONFIG_INOTIFY_USER=y\n" ++
        "CONFIG_BPF_SYSCALL=y\n" ++
        "CONFIG_CGROUP_BPF=y\n" ++
        "CONFIG_MEMCG=y\n" ++
        "CONFIG_CGROUP_PIDS=y\n" ++
        "CONFIG_CPUSETS=y\n" ++
        "CONFIG_CGROUP_DEVICE=y\n" ++
        "CONFIG_MEMORY_HOTPLUG=y\n" ++
        "CONFIG_MEMORY_HOTPLUG_DEFAULT_ONLINE=y\n" ++
        "CONFIG_MEMORY_HOTREMOVE=y\n" ++
        "CONFIG_CONTIG_ALLOC=y\n" ++
        "CONFIG_EXCLUSIVE_SYSTEM_RAM=y\n" ++
        "CONFIG_VIRTIO_MEM=y\n";

    try std.testing.expect(try missingManagedRunKernelConfigSymbol(allocator, good_config) == null);

    const missing_file_locking =
        "# CONFIG_FILE_LOCKING is not set\n" ++
        "CONFIG_CGROUPS=y\n" ++
        "CONFIG_HW_RANDOM=y\n" ++
        "CONFIG_HW_RANDOM_VIRTIO=y\n" ++
        "CONFIG_SHMEM=y\n" ++
        "CONFIG_TMPFS=y\n" ++
        "CONFIG_FSNOTIFY=y\n" ++
        "CONFIG_INOTIFY_USER=y\n" ++
        "CONFIG_BPF_SYSCALL=y\n" ++
        "CONFIG_CGROUP_BPF=y\n" ++
        "CONFIG_MEMCG=y\n" ++
        "CONFIG_CGROUP_PIDS=y\n" ++
        "CONFIG_CPUSETS=y\n" ++
        "CONFIG_CGROUP_DEVICE=y\n" ++
        "CONFIG_MEMORY_HOTPLUG=y\n" ++
        "CONFIG_MEMORY_HOTPLUG_DEFAULT_ONLINE=y\n" ++
        "CONFIG_MEMORY_HOTREMOVE=y\n" ++
        "CONFIG_CONTIG_ALLOC=y\n" ++
        "CONFIG_EXCLUSIVE_SYSTEM_RAM=y\n" ++
        "CONFIG_VIRTIO_MEM=y\n";
    const missing = (try missingManagedRunKernelConfigSymbol(allocator, missing_file_locking)).?;
    defer allocator.free(missing);
    try std.testing.expectEqualStrings("CONFIG_FILE_LOCKING", missing);

    const module_value =
        "CONFIG_FILE_LOCKING=m\n" ++
        "CONFIG_CGROUPS=y\n" ++
        "CONFIG_SHMEM=y\n" ++
        "CONFIG_TMPFS=y\n" ++
        "CONFIG_FSNOTIFY=y\n" ++
        "CONFIG_INOTIFY_USER=y\n" ++
        "CONFIG_BPF_SYSCALL=y\n" ++
        "CONFIG_CGROUP_BPF=y\n" ++
        "CONFIG_MEMCG=y\n" ++
        "CONFIG_CGROUP_PIDS=y\n" ++
        "CONFIG_CPUSETS=y\n" ++
        "CONFIG_CGROUP_DEVICE=y\n" ++
        "CONFIG_MEMORY_HOTPLUG=y\n" ++
        "CONFIG_MEMORY_HOTPLUG_DEFAULT_ONLINE=y\n" ++
        "CONFIG_MEMORY_HOTREMOVE=y\n" ++
        "CONFIG_CONTIG_ALLOC=y\n" ++
        "CONFIG_EXCLUSIVE_SYSTEM_RAM=y\n" ++
        "CONFIG_VIRTIO_MEM=y\n";
    const module_missing = (try missingManagedRunKernelConfigSymbol(allocator, module_value)).?;
    defer allocator.free(module_missing);
    try std.testing.expectEqualStrings("CONFIG_FILE_LOCKING", module_missing);
}
