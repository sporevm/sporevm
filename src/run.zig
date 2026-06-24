//! One-shot VM boot/exec support for `spore run`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const block_source = @import("block_source.zig");
const capture = @import("capture.zig");
const Context = @import("context.zig").Context;
const cow_disk = @import("cow_disk.zig");
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
const rootfs_cas = @import("rootfs_cas.zig");
const rootfs_cache = @import("rootfs_cache.zig");
const rootfs_mod = @import("rootfs.zig");
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
const default_kernel_repository = "buildkite/cleanroom-kernels";
const default_kernel_release = "v0.5.2";
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
};
const direct_image_platform = rootfs_mod.Platform{};
const max_rootfs_metadata_bytes = 1024 * 1024;
const rootfs_trace_env = "SPOREVM_ROOTFS_TRACE";

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
    network: NetworkMode = .disabled,
    network_policy: spore_net_policy.Config = .{},
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

    pub fn processExitCode(self: Result) u8 {
        std.debug.assert(self.exit_code >= 0 and self.exit_code <= 255);
        return @intCast(self.exit_code);
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
    stdout: OutputEvent,
    stderr: OutputEvent,
    exit: ExitEvent,
    failure: FailureEvent,
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
};

fn exitEvent(command: []const u8, result: Result) ExitEvent {
    return .{
        .command = command,
        .backend = result.backend,
        .exit_code = result.exit_code,
        .vcpus = result.vcpus,
        .memory_bytes = result.memory_bytes,
        .captured = result.captured,
        .capture_path = result.capture_path,
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
            timings: Timings,
        }{
            .command = value.command,
            .backend = value.backend.name(),
            .exit_code = value.exit_code,
            .vcpus = value.vcpus,
            .memory_bytes = value.memory_bytes,
            .captured = value.captured,
            .capture_path = value.capture_path,
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

pub fn machineErrorExitCode(err: anyerror) u8 {
    return machine_output.fromZigError(err).exit_code;
}

pub const MonitorExit = enum {
    stopped,
    snapshotted,
};

pub const MonitorResult = struct {
    backend: Backend,
    exit: MonitorExit,
};

const SharedOptions = struct {
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

const cli_usage =
    \\Usage:
    \\  spore run [--kernel Image] [--initrd root.cpio] [options] -- <argv...>
    \\
    \\Options:
    \\  --backend auto|hvf|kvm  Backend to run (default: auto)
    \\  --kernel Image          Kernel Image path (default: managed SporeVM run kernel)
    \\  --initrd root.cpio      Initrd path (default: embedded minimal exec initrd)
    \\  --from DIR              Resume from an existing spore, then run argv
    \\  --rootfs rootfs.ext4    Attach rootfs image read-only as virtio-blk
    \\  --image REF             Build or reuse cached OCI rootfs, then run from it
    \\  --net                   Experimental SporeVM-managed networking
    \\  --allow-cidr CIDR       With --net, restrict public egress to this CIDR
    \\  --allow-host HOST       With --net, restrict public egress to DNS A answers for this host
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

pub fn cli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help")) {
        try stdout.writeAll(cli_usage);
        return;
    }

    const arena = init.arena.allocator();
    const parsed = try parseCliArgs(args);
    var opts = try resolveCliOptions(init, arena, parsed);
    var event_writer = EventWriter.init(std.heap.page_allocator, stdout, "run");
    if (parsed.event_mode == .jsonl) {
        opts.stream_output = false;
        opts.events = event_writer.sink();
    }
    try openConsoleLog(opts.console_log_path);
    defer closeConsoleLog();

    const full_args = try init.minimal.args.toSlice(arena);
    opts.spore_executable = full_args[0];
    opts.debug = runtimeDebugEnabled(full_args);
    const result = execute(.{
        .io = init.io,
        .environ_map = init.environ_map,
    }, arena, opts) catch |err| {
        if (parsed.event_mode == .jsonl) {
            std.process.exit(machine_output.fromZigError(err).exit_code);
        }
        if (isCaptureAborted(err)) std.process.exit(130);
        if (isNetworkGatewayError(err)) {
            printNetworkGatewayError(err);
            std.process.exit(1);
        }
        return err;
    };
    if (result.captured and parsed.event_mode != .jsonl) {
        if (result.capture_path) |path| {
            const message = try std.fmt.allocPrint(arena, "spore run: captured snapshot at {s}\n", .{path});
            try writeSetupStderr(init, message);
        }
    }
    if (parsed.event_mode == .jsonl) {
        try stdout.flush();
    }
    const code = result.processExitCode();
    if (code != 0) std.process.exit(code);
}

pub fn parseCliArgs(args: []const []const u8) !CliOptions {
    var backend: Backend = .auto;
    var shared = SharedOptions{};
    var from_spore_dir: ?[]const u8 = null;
    var rootfs_path: ?[]const u8 = null;
    var image_ref: ?[]const u8 = null;
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

    return .{
        .backend = backend,
        .shared = shared,
        .from_spore_dir = from_spore_dir,
        .rootfs_path = rootfs_path,
        .image_ref = image_ref,
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

fn resolveCliOptions(init: std.process.Init, allocator: std.mem.Allocator, parsed: CliOptions) !Options {
    if (parsed.from_spore_dir) |spore_dir| {
        const manifest = spore.loadManifest(allocator, spore_dir) catch |err| {
            failRunSetup("spore run: --from could not load spore manifest: {s}", .{@errorName(err)});
        };
        defer manifest.deinit();

        if (parsed.network_requested or parsed.network_policy.hasRules()) {
            failRunSetup("spore run: --from uses the captured network policy; omit --net and network allow flags", .{});
        }
        const rootfs = try resumeRootfsForRun(allocator, manifest.value);
        const disk = try resumeDiskForRun(allocator, manifest.value);
        const network_options = try networkOptionsFromManifest(allocator, manifest.value.network);
        var opts = parsed.shared.completeWithAssets(parsed.backend, "", null, null, rootfs, parsed.command, true);
        opts.disk = disk;
        opts.resume_dir = spore_dir;
        opts.memory = runMemoryFromManifest(manifest.value);
        opts.capture_path = parsed.capture_path;
        opts.capture_trigger = parsed.capture_trigger;
        opts.continue_after_capture = parsed.continue_after_capture;
        opts.network = network_options.network;
        opts.network_policy = network_options.policy;
        return opts;
    }

    if (parsed.capture_path != null and parsed.rootfs_path != null and parsed.image_ref == null) {
        failRunSetup("spore run: --rootfs with --capture is not portable yet; use --image so capture can record immutable rootfs identity", .{});
    }
    const rootfs = try resolveRootfsInputDetailed(init, allocator, .{
        .rootfs_path = parsed.rootfs_path,
        .image_ref = parsed.image_ref,
        .command_name = "run",
        .record_artifact = parsed.capture_path != null,
    });
    const kernel_path = parsed.shared.kernel_path orelse try resolveDefaultKernelPath(init, allocator);
    const initrd_path = try resolveConfiguredInitrdPath(init, parsed.shared.initrd_path);
    var opts = parsed.shared.completeWithAssets(parsed.backend, kernel_path, initrd_path, rootfs.path, rootfs.rootfs, parsed.command, true);
    opts.guest_env = rootfs.guest_env;
    opts.guest_working_dir = rootfs.guest_working_dir;
    opts.capture_path = parsed.capture_path;
    opts.capture_trigger = parsed.capture_trigger;
    opts.continue_after_capture = parsed.continue_after_capture;
    opts.network = parsed.network;
    opts.network_policy = parsed.network_policy;
    return opts;
}

pub fn networkOptionsFromManifest(allocator: std.mem.Allocator, manifest_network: ?spore.Network) !NetworkOptions {
    const network = manifest_network orelse return .{};
    try spore.validateNetwork(network);
    var policy = spore_net_policy.Config{};
    for (network.allow_cidrs) |cidr| {
        try policy.addAllowCidr(try allocator.dupe(u8, cidr));
    }
    for (network.allow_hosts) |host| {
        try policy.addAllowHost(try allocator.dupe(u8, host));
    }
    return .{ .network = .spore, .policy = policy };
}

fn manifestNetworkFromOptions(network: NetworkMode, policy: *const spore_net_policy.Config) ?spore.Network {
    if (network != .spore) return null;
    return .{
        .allow_cidrs = policy.allowCidrSlice(),
        .allow_hosts = policy.allowHostSlice(),
    };
}

fn runMemoryFromManifest(manifest: spore.Manifest) memory_config.Config {
    return memory_config.fromManifestBytes(manifest.platform.ram_size) catch {
        failRunSetup("spore run: --from manifest RAM size is not positive and page-aligned: {d}", .{manifest.platform.ram_size});
    };
}

fn resumeRootfsForRun(allocator: std.mem.Allocator, manifest: spore.Manifest) !?spore.Rootfs {
    const disk_count = countBlockDevices(manifest.devices);
    if (disk_count == 0) return null;
    if (disk_count != 1) {
        failRunSetup("spore run: --from supports at most one immutable rootfs disk; found {d} block devices", .{disk_count});
    }
    const rootfs = manifest.rootfs orelse {
        failRunSetup("spore run: --from disk-backed spore has no immutable rootfs artifact; capture with spore run --image", .{});
    };
    spore.validateRootfs(rootfs, manifest.devices) catch {
        failRunSetup("spore run: --from manifest has invalid immutable rootfs metadata", .{});
    };
    return try cloneRootfs(allocator, rootfs);
}

fn resumeDiskForRun(allocator: std.mem.Allocator, manifest: spore.Manifest) !?spore.Disk {
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

const RootfsInputOptions = struct {
    rootfs_path: ?[]const u8,
    image_ref: ?[]const u8,
    command_name: []const u8,
    record_artifact: bool = false,
};

const ResolvedRootfsInput = struct {
    path: ?[]const u8,
    rootfs: ?spore.Rootfs = null,
    guest_env: []const []const u8 = &.{},
    guest_working_dir: ?[]const u8 = null,
};

pub fn resolveRootfsInput(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    rootfs_path: ?[]const u8,
    image_ref: ?[]const u8,
    command_name: []const u8,
) !?[]const u8 {
    return (try resolveRootfsInputDetailed(init, allocator, .{
        .rootfs_path = rootfs_path,
        .image_ref = image_ref,
        .command_name = command_name,
    })).path;
}

fn resolveRootfsInputDetailed(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: RootfsInputOptions,
) !ResolvedRootfsInput {
    if (options.rootfs_path != null and options.image_ref != null) {
        failRunSetup("spore {s}: --rootfs and --image are mutually exclusive", .{options.command_name});
    }
    const resolved = if (options.image_ref) |ref|
        try resolveImageRootfs(init, allocator, ref, options.command_name, options.record_artifact)
    else
        ResolvedRootfsInput{ .path = options.rootfs_path };
    if (resolved.path) |path| {
        if (!try readablePath(init.io, path)) {
            failRunSetup("spore {s}: rootfs not found: {s}", .{ options.command_name, path });
        }
    }
    return resolved;
}

fn resolveImageRootfs(init: std.process.Init, allocator: std.mem.Allocator, image_ref: []const u8, command_name: []const u8, record_artifact: bool) !ResolvedRootfsInput {
    const cache_root = try rootfsCacheRootPath(.{ .io = init.io, .environ_map = init.environ_map }, allocator, command_name);
    try ensureDirPath(init.io, cache_root);

    const digest_pinned = try rootfs_mod.digestPinnedImageIdentity(allocator, image_ref, direct_image_platform);

    if (rootfs_mod.isLocalImageRef(image_ref)) {
        const resolved = rootfs_mod.resolveLocalCachedRef(init.io, allocator, cache_root, image_ref, direct_image_platform) catch |err| {
            failRunSetup("spore {s}: local image ref not imported for {s}: {s}", .{ command_name, image_ref, @errorName(err) });
        };
        if (rootfs_mod.cachedImageRootfsPath(init.io, allocator, cache_root, resolved) catch |err| {
            failRunSetup("spore {s}: cached rootfs metadata check failed: {s}", .{ command_name, @errorName(err) });
        }) |path| {
            return try resolvedImageRootfsInput(init, allocator, cache_root, image_ref, resolved, path, record_artifact);
        }
        failRunSetup(
            "spore {s}: local image rootfs cache miss for {s}; import an OCI layout with 'spore rootfs import-oci <layout> --ref local/name:tag'",
            .{ command_name, image_ref },
        );
    }

    if (digest_pinned) |resolved| {
        if (rootfs_mod.cachedImageRootfsPath(init.io, allocator, cache_root, resolved) catch |err| {
            failRunSetup("spore {s}: cached rootfs metadata check failed: {s}", .{ command_name, @errorName(err) });
        }) |path| {
            return try resolvedImageRootfsInput(init, allocator, cache_root, image_ref, resolved, path, record_artifact);
        }
    } else {
        rootfs_mod.validateTaggedImageRef(image_ref) catch |err| {
            failRunSetup("spore {s}: image resolve failed for {s}: {s}", .{ command_name, image_ref, @errorName(err) });
        };
        if (rootfs_mod.cachedImageRefRootfsPath(init.io, allocator, cache_root, image_ref, direct_image_platform) catch |err| {
            failRunSetup("spore {s}: cached image ref check failed: {s}", .{ command_name, @errorName(err) });
        }) |hit| {
            return try resolvedImageRootfsInput(init, allocator, cache_root, image_ref, hit.resolved, hit.path, record_artifact);
        }
    }

    const resolved = rootfs_mod.resolveImageRef(init, allocator, image_ref, direct_image_platform) catch |err| {
        failRunSetup("spore {s}: image resolve failed for {s}: {s}", .{ command_name, image_ref, @errorName(err) });
    };
    if (rootfs_mod.cachedImageRootfsPath(init.io, allocator, cache_root, resolved) catch |err| {
        failRunSetup("spore {s}: cached rootfs metadata check failed: {s}", .{ command_name, @errorName(err) });
    }) |path| {
        if (digest_pinned == null) rootfs_mod.writeImageRefCacheRecord(init.io, allocator, cache_root, image_ref, resolved) catch |err| {
            failRunSetup("spore {s}: image ref cache update failed: {s}", .{ command_name, @errorName(err) });
        };
        return try resolvedImageRootfsInput(init, allocator, cache_root, image_ref, resolved, path, record_artifact);
    }
    const path = rootfs_mod.buildCachedImageRootfs(init, allocator, cache_root, resolved) catch |err| {
        failRunSetup("spore {s}: image rootfs build failed for {s}: {s}", .{ command_name, resolved.ref, @errorName(err) });
    };
    if (digest_pinned == null) rootfs_mod.writeImageRefCacheRecord(init.io, allocator, cache_root, image_ref, resolved) catch |err| {
        failRunSetup("spore {s}: image ref cache update failed: {s}", .{ command_name, @errorName(err) });
    };
    return try resolvedImageRootfsInput(init, allocator, cache_root, image_ref, resolved, path, record_artifact);
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
    const artifact = try cacheRootfsByDigest(init, allocator, cache_root, rootfs_path);
    const rootfs_device = spore.RootfsDevice{ .mmio_slot = 1 };
    const storage = rootfs_mod.ensureImageRootfsStorage(init, allocator, cache_root, resolved, artifact, rootfs_device) catch |err| {
        failRunSetup("spore run: image rootfs storage update failed for {s}: {s}", .{ artifact.digest, @errorName(err) });
    };
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

pub fn rootfsCacheRootPath(context: Context, allocator: std.mem.Allocator, command_name: []const u8) ![]const u8 {
    return local_paths.rootfsCacheRootPath(allocator, context.environ_map) catch |err| switch (err) {
        error.MissingHome => failRunSetup(
            "spore {s}: cannot resolve rootfs cache directory; set {s} or HOME",
            .{ command_name, local_paths.rootfs_cache_env },
        ),
        else => |e| return e,
    };
}

pub fn openVerifiedRootfs(context: Context, allocator: std.mem.Allocator, rootfs: spore.Rootfs, command_name: []const u8) !std.c.fd_t {
    const cache_root = try rootfsCacheRootPath(context, allocator, command_name);
    const trace_path = try rootfsTracePath(context, allocator);
    const start_ms = monotonicMs();
    const fd = try openVerifiedRootfsFromCache(context.io, allocator, cache_root, rootfs);
    if (trace_path) |path| {
        appendRootfsTrace(allocator, path, rootfs, monotonicMs() -| start_ms) catch {};
    }
    return fd;
}

fn openVerifiedRootfsFromCache(io: Io, allocator: std.mem.Allocator, cache_root: []const u8, rootfs: spore.Rootfs) !std.c.fd_t {
    return rootfs_cache.openVerifiedFromCache(io, allocator, cache_root, rootfs);
}

fn rootfsTracePath(context: Context, allocator: std.mem.Allocator) !?[:0]const u8 {
    const path = context.environ_map.get(rootfs_trace_env) orelse return null;
    if (path.len == 0) return null;
    const copy = try allocator.dupeZ(u8, path);
    return copy;
}

fn appendRootfsTrace(
    allocator: std.mem.Allocator,
    path: [:0]const u8,
    rootfs: spore.Rootfs,
    elapsed_ms: u64,
) !void {
    const line = try std.fmt.allocPrint(
        allocator,
        "{{\"event\":\"rootfs_open_verified\",\"digest\":\"{s}\",\"size\":{d},\"elapsed_ms\":{d}}}\n",
        .{ rootfs.artifact.digest, rootfs.artifact.size, elapsed_ms },
    );
    defer allocator.free(line);
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c_uint, 0o644));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    writeAllTrace(fd, line);
}

fn writeAllTrace(fd: std.c.fd_t, bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(fd, remaining.ptr, remaining.len);
        if (n <= 0) return;
        remaining = remaining[@intCast(n)..];
    }
}

fn monotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn cacheRootfsByDigest(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    rootfs_path: []const u8,
) !spore.RootfsArtifactRef {
    return cacheRootfsByDigestPath(init.io, allocator, cache_root, rootfs_path);
}

fn cacheRootfsByDigestPath(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    rootfs_path: []const u8,
) !spore.RootfsArtifactRef {
    return rootfs_cache.cacheByDigestPath(io, allocator, cache_root, rootfs_path);
}

fn regularFileNoSymlink(io: Io, path: []const u8) !bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return false,
        else => |e| return e,
    };
    return stat.kind == .file;
}

fn digestRootfsPath(allocator: std.mem.Allocator, cache_root: []const u8, digest: []const u8) ![]const u8 {
    return rootfs_cache.digestPath(allocator, cache_root, digest);
}

fn jsonStringEquals(value: ?std.json.Value, expected: []const u8) bool {
    const actual = switch (value orelse return false) {
        .string => |string| string,
        else => return false,
    };
    return std.mem.eql(u8, actual, expected);
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
        if (!try readablePath(init.io, path)) {
            failRunSetup("spore run: SPOREVM_KERNEL_IMAGE not found: {s}", .{path});
        }
        return path;
    }

    return resolveManagedRunKernelPath(init, allocator) catch |err| {
        failRunSetup(
            "spore run: managed run kernel resolution failed: {s}; pass --kernel or set SPOREVM_KERNEL_IMAGE",
            .{@errorName(err)},
        );
    };
}

pub fn resolveConfiguredInitrdPath(init: std.process.Init, cli_path: ?[]const u8) !?[]const u8 {
    if (cli_path) |path| return path;
    if (init.environ_map.get("SPOREVM_RUN_INITRD")) |path| {
        if (!try readablePath(init.io, path)) {
            failRunSetup("spore run: SPOREVM_RUN_INITRD not found: {s}", .{path});
        }
        return path;
    }
    return null;
}

fn resolveManagedRunKernelPath(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    const opts = managedKernelOptions(init);
    const asset = try managedRunKernelAssetName(allocator, opts.linux_version);
    const config_asset = try managedRunKernelConfigAssetName(allocator, asset);
    const cache_root = local_paths.kernelCacheRootPath(allocator, init.environ_map) catch |err| switch (err) {
        error.MissingHome => failRunSetup(
            "spore run: cannot resolve kernel cache directory; set {s} or HOME",
            .{local_paths.kernel_cache_env},
        ),
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

    const message = try std.fmt.allocPrint(allocator, "spore run: downloading managed kernel {s}@{s}:{s}\n", .{ opts.repository, opts.release, asset });
    try writeSetupStderr(init, message);

    var client: std.http.Client = .{ .allocator = allocator, .io = init.io };
    defer client.deinit();
    try fetchManagedKernelAsset(allocator, init.io, &client, opts.repository, opts.release, asset, temp_image, max_kernel_asset_size);
    const sha_asset = try std.fmt.allocPrint(allocator, "{s}.sha256", .{asset});
    try fetchManagedKernelAsset(allocator, init.io, &client, opts.repository, opts.release, sha_asset, temp_sha, max_kernel_config_asset_size);
    fetchManagedKernelAsset(allocator, init.io, &client, opts.repository, opts.release, config_asset, temp_config, max_kernel_config_asset_size) catch |err| {
        failRunSetup(
            "spore run: managed run kernel config asset {s}@{s}:{s} is unavailable: {s}",
            .{ opts.repository, opts.release, config_asset, @errorName(err) },
        );
    };
    if (!try verifiedManagedKernelPath(init.io, allocator, temp_image, temp_sha)) return error.ManagedKernelChecksumMismatch;
    if (try missingManagedRunKernelConfigSymbolFromPath(init.io, allocator, temp_config)) |missing| {
        defer allocator.free(missing);
        failRunSetup(
            "spore run: managed run kernel config {s}@{s}:{s} is missing {s}; use cleanroom-kernels v0.5.2 or newer, pass --kernel, or set SPOREVM_KERNEL_RELEASE to a fixed release",
            .{ opts.repository, opts.release, config_asset, missing },
        );
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
    return std.fmt.allocPrint(allocator, "sporevm-run-arm64-linux-{s}-Image", .{linux_version});
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

fn executablePath(io: Io, path: []const u8) !bool {
    return accessPath(io, path, .{ .execute = true });
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

fn writeSetupStderr(_: std.process.Init, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(2, remaining.ptr, remaining.len);
        if (n <= 0) return error.StderrWriteFailed;
        remaining = remaining[@intCast(n)..];
    }
}

fn failRunSetup(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(2);
}

fn runtimeDebugEnabled(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--debug")) return true;
    }
    return false;
}

pub fn execute(context: Context, allocator: std.mem.Allocator, opts: Options) !Result {
    var events = EventEmitter.init(opts.events, "run");
    try events.emitStart(opts.backend);
    errdefer |err| events.emitFailure(err) catch {};

    const setup_start = monotonicMs();
    if (opts.vcpus != 1) return error.UnsupportedVcpuCount;

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
    const network_manifest = manifestNetworkFromOptions(opts.network, &opts.network_policy);

    const resuming = opts.resume_dir != null;
    const local_backing_start = monotonicMs();
    const local_backing = try openRunLocalMemoryBacking(allocator, context.environ_map, opts.resume_dir, opts.memory.bytes);
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
    var runtime_disk = try openRuntimeDisk(context, allocator, .{
        .rootfs_path = opts.rootfs_path,
        .rootfs = opts.rootfs,
        .disk = opts.disk,
        .spore_dir = opts.resume_dir,
        .command_name = "run",
    });
    const disk_ms = monotonicMs() -| disk_start;
    defer runtime_disk.deinit();
    const boot_args = if (resuming) "" else try cmdline(allocator, opts.guest_port, opts.rootfs_path != null, rootfsWritable(opts), opts.network);
    const request_start = monotonicMs();
    const request = try execRequestForRun(context, allocator, opts);
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
        "run host setup timing: total_ms={d} local_backing_ms={d} kernel_ms={d} initrd_ms={d} disk_ms={d} request_ms={d} ram_mib={d}",
        .{
            monotonicMs() -| setup_start,
            local_backing_ms,
            kernel_ms,
            initrd_ms,
            disk_ms,
            request_ms,
            opts.memory.bytes / 1024 / 1024,
        },
    );

    const cause = (switch (backend) {
        .auto => unreachable,
        .hvf => blk: {
            if (comptime !(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) return error.UnsupportedBackend;
            break :blk hvf.vm.run(allocator, .{
                .kernel = kernel,
                .ram_size = opts.memory.bytes,
                .cmdline = boot_args,
                .initrd = initrd,
                .console_sink = consoleSink,
                .disk_backend = runtime_disk.backend(),
                .disk_snapshot = runtime_disk.snapshot(),
                .rootfs = opts.rootfs,
                .network_manifest = network_manifest,
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
                .ram_size = opts.memory.bytes,
                .cmdline = boot_args,
                .initrd = initrd,
                .console_sink = consoleSink,
                .disk_backend = runtime_disk.backend(),
                .disk_snapshot = runtime_disk.snapshot(),
                .rootfs = opts.rootfs,
                .network_manifest = network_manifest,
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
            const result = resultFromAbortedSignalCapture(backend, opts, &stream);
            try events.emitExit(result);
            if (events.write_failed) return error.EventSinkFailed;
            return result;
        }
        return @errorCast(err);
    };
    if (gateway_active and gateway.hasFailed()) return error.NetworkGatewayFailed;
    const signal_capture_observed = capture_plan.isSignalCapture() and capture_request.isCompleted();
    const result = try switch (cause) {
        .probe_complete => resultFromStream(backend, opts, &stream, signal_capture_observed),
        .snapshotted => if (capture_plan.isExitCapture())
            resultFromExitCapture(backend, opts, &stream)
        else
            resultFromSignalCapture(backend, opts, &stream),
        else => error.ProbeDidNotComplete,
    };
    try events.emitExit(result);
    if (events.write_failed) return error.EventSinkFailed;
    return result;
}

pub fn executeMonitor(context: Context, allocator: std.mem.Allocator, opts: Options, control: vsock.Control) !MonitorResult {
    if (opts.vcpus != 1) return error.UnsupportedVcpuCount;

    const backend = try resolveBackend(opts.backend);
    const kernel = try std.Io.Dir.cwd().readFileAlloc(context.io, opts.kernel_path, allocator, .limited(max_file_size));
    const initrd = try loadRunInitrd(context.io, allocator, opts.initrd_path);
    var runtime_disk = try openRuntimeDisk(context, allocator, .{
        .rootfs_path = opts.rootfs_path,
        .rootfs = opts.rootfs,
        .disk = opts.disk,
        .spore_dir = opts.resume_dir,
        .command_name = "run",
    });
    defer runtime_disk.deinit();
    const boot_args = try cmdline(allocator, opts.guest_port, opts.rootfs_path != null, rootfsWritable(opts), .disabled);

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
                .resume_dir = opts.resume_dir,
                .ram_restore_mode = .eager_chunks,
                .exec_control = control,
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
                .resume_dir = opts.resume_dir,
                .ram_restore_mode = .eager_chunks,
                .exec_control = control,
                .environ_map = context.environ_map,
            });
        },
    };
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

fn openRootfsDisk(allocator: std.mem.Allocator, rootfs_path: ?[]const u8) !?std.c.fd_t {
    const path = rootfs_path orelse return null;
    const pathz = try allocator.dupeZ(u8, path);
    defer allocator.free(pathz);
    const fd = std.c.open(pathz, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return error.RootFSOpenFailed;
    return fd;
}

pub const RuntimeDiskOptions = struct {
    rootfs_path: ?[]const u8 = null,
    rootfs: ?spore.Rootfs = null,
    disk: ?spore.Disk = null,
    spore_dir: ?[]const u8 = null,
    command_name: []const u8,
};

pub const RuntimeDisk = struct {
    allocator: ?std.mem.Allocator = null,
    rootfs_fd: ?std.c.fd_t = null,
    cas_rootfs: ?*rootfs_cas.CasBlockSource = null,
    overlay: ?disk_layer.TempOverlay = null,
    cow: ?cow_disk.CowDisk = null,
    layered_cow: ?disk_layer.LayeredCowDisk = null,
    base_disk: ?spore.Disk = null,

    pub fn backend(self: *RuntimeDisk) ?virtio_blk.Backend {
        if (self.layered_cow) |*disk| return .{ .layered_cow = disk };
        if (self.cow) |*disk| return .{ .cow = disk };
        if (self.rootfs_fd) |fd| return .{ .file = fd };
        return null;
    }

    pub fn snapshot(self: *RuntimeDisk) ?disk_layer.SnapshotState {
        const base = self.base_disk orelse return null;
        if (self.layered_cow) |*disk| return .{ .base = base, .active = .{ .layered_cow = disk } };
        if (self.cow) |*disk| return .{ .base = base, .active = .{ .cow = disk } };
        return null;
    }

    pub fn deinit(self: *RuntimeDisk) void {
        if (self.layered_cow) |*disk| disk.deinit();
        if (self.cow) |*disk| disk.deinit();
        if (self.overlay) |*overlay| overlay.deinit();
        if (self.rootfs_fd) |fd| _ = std.c.close(fd);
        if (self.cas_rootfs) |source| {
            source.deinit();
            if (self.allocator) |alloc| alloc.destroy(source);
        }
        self.* = .{};
    }

    fn baseSource(self: *RuntimeDisk, size: u64, trace_path: ?[:0]const u8) !block_source.BlockSource {
        if (self.cas_rootfs) |source| return .{ .cas = source };
        const fd = self.rootfs_fd orelse return error.BadManifest;
        return block_source.FileBlockSource.initWithTrace(fd, size, trace_path).source();
    }
};

pub fn openRuntimeDisk(context: Context, allocator: std.mem.Allocator, options: RuntimeDiskOptions) !RuntimeDisk {
    var runtime = RuntimeDisk{};
    errdefer runtime.deinit();
    const trace_path = try rootfsTracePath(context, allocator);

    if (options.rootfs) |rootfs| {
        if (rootfs.storage != null) {
            runtime.allocator = allocator;
            runtime.cas_rootfs = try openManifestCasRootfs(context, allocator, rootfs, options.command_name, trace_path);
        } else {
            runtime.rootfs_fd = try openVerifiedRootfs(context, allocator, rootfs, options.command_name);
        }
    } else {
        runtime.rootfs_fd = try openRootfsDisk(allocator, options.rootfs_path);
    }

    if (runtime.rootfs_fd == null and runtime.cas_rootfs == null) return .{};

    if (options.disk) |disk| {
        const rootfs = options.rootfs orelse return error.BadManifest;
        const spore_dir = options.spore_dir orelse return error.BadManifest;
        if (disk.size != spore.effectiveRootfsLogicalSize(rootfs) or
            !std.mem.eql(u8, disk.base, spore.effectiveRootfsBaseIdentity(rootfs))) return error.BadManifest;
        const base_source = try runtime.baseSource(disk.size, trace_path);
        runtime.overlay = try disk_layer.createTempOverlay(allocator);
        if (disk.layers.len == 0) {
            runtime.cow = try cow_disk.CowDisk.init(allocator, base_source, runtime.overlay.?.fd, disk.size, disk_layer.default_cluster_size);
            runtime.base_disk = disk;
        } else {
            const layers = try disk_layer.loadLayerChain(allocator, spore_dir, disk);
            errdefer disk_layer.freeLayerChain(allocator, layers);
            runtime.layered_cow = try disk_layer.LayeredCowDisk.init(allocator, spore_dir, base_source, runtime.overlay.?.fd, disk, layers);
            runtime.base_disk = disk;
        }
        return runtime;
    }

    if (options.rootfs) |rootfs| {
        runtime.overlay = try disk_layer.createTempOverlay(allocator);
        const base = disk_layer.diskFromRootfs(rootfs);
        const base_source = try runtime.baseSource(base.size, trace_path);
        runtime.cow = try cow_disk.CowDisk.init(allocator, base_source, runtime.overlay.?.fd, base.size, disk_layer.default_cluster_size);
        runtime.base_disk = base;
        return runtime;
    }

    return runtime;
}

fn openManifestCasRootfs(
    context: Context,
    allocator: std.mem.Allocator,
    rootfs: spore.Rootfs,
    command_name: []const u8,
    trace_path: ?[:0]const u8,
) !*rootfs_cas.CasBlockSource {
    const cache_root = try rootfsCacheRootPath(context, allocator, command_name);
    defer allocator.free(cache_root);
    const source = try allocator.create(rootfs_cas.CasBlockSource);
    errdefer allocator.destroy(source);
    source.* = try rootfs_cas.CasBlockSource.openManifest(allocator, cache_root, rootfs, trace_path);
    return source;
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

fn execRequestForRun(context: Context, allocator: std.mem.Allocator, opts: Options) ![]const u8 {
    const resume_time_unix_ns: u64 = @intCast(Io.Clock.real.now(context.io).nanoseconds);
    if (opts.resume_dir == null) return execRequestWithSessionOptions(allocator, opts.command, "default", .{
        .env = opts.guest_env,
        .working_dir = opts.guest_working_dir,
        .resume_time_unix_ns = resume_time_unix_ns,
    });

    const now = Io.Clock.real.now(context.io).nanoseconds;
    var nonce_bytes: [8]u8 = undefined;
    context.io.random(&nonce_bytes);
    const nonce = std.mem.readInt(u64, &nonce_bytes, .little);
    const session_id = try std.fmt.allocPrint(allocator, "run-{x}-{x}", .{ now, nonce });
    return execRequestWithSessionOptions(allocator, opts.command, session_id, .{
        .resume_time_unix_ns = resume_time_unix_ns,
    });
}

pub fn execRequestWithSession(allocator: std.mem.Allocator, argv: []const []const u8, session_id: []const u8) ![]const u8 {
    return execRequestWithSessionOptions(allocator, argv, session_id, .{});
}

const GuestExecOptions = struct {
    env: []const []const u8 = &.{},
    working_dir: ?[]const u8 = null,
    resume_time_unix_ns: u64 = 0,
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
        closed_env: bool = true,
    }{
        .session_id = session_id,
        .resume_time_unix_ns = options.resume_time_unix_ns,
        .argv = argv,
        .env = options.env,
        .working_dir = options.working_dir orelse "",
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

fn isCaptureAborted(err: anyerror) bool {
    return std.mem.eql(u8, @errorName(err), "CaptureAborted");
}

fn isNetworkGatewayError(err: anyerror) bool {
    return std.mem.eql(u8, @errorName(err), "NetdSpawnFailed") or
        std.mem.eql(u8, @errorName(err), "NetdReadyTimedOut") or
        std.mem.eql(u8, @errorName(err), "NetdReadyFailed") or
        std.mem.eql(u8, @errorName(err), "NetdThreadFailed") or
        std.mem.eql(u8, @errorName(err), "NetworkGatewayFailed");
}

fn printNetworkGatewayError(err: anyerror) void {
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
    try std.testing.expectEqualStrings("{\"type\":\"start\",\"session_id\":\"default\",\"resume_time_unix_ns\":0,\"argv\":[\"/bin/echo\",\"hello world\"],\"env\":[],\"working_dir\":\"\",\"closed_env\":true}\n", request);
}

test "run request can encode explicit session id" {
    const request = try execRequestWithSession(std.testing.allocator, &.{"/bin/true"}, "lifecycle-42");
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings("{\"type\":\"start\",\"session_id\":\"lifecycle-42\",\"resume_time_unix_ns\":0,\"argv\":[\"/bin/true\"],\"env\":[],\"working_dir\":\"\",\"closed_env\":true}\n", request);
}

test "run request encodes image env and working directory" {
    const request = try execRequestWithSessionOptions(std.testing.allocator, &.{ "/bin/sh", "-lc", "env && pwd" }, "default", .{
        .env = &.{ "GEM_HOME=/usr/local/bundle", "RUBYOPT=--yjit" },
        .working_dir = "/app",
        .resume_time_unix_ns = 123,
    });
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings("{\"type\":\"start\",\"session_id\":\"default\",\"resume_time_unix_ns\":123,\"argv\":[\"/bin/sh\",\"-lc\",\"env && pwd\"],\"env\":[\"GEM_HOME=/usr/local/bundle\",\"RUBYOPT=--yjit\"],\"working_dir\":\"/app\",\"closed_env\":true}\n", request);
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

    const input = try resolvedImageRootfsInput(init, arena, cache_root, "local/buildkite-spore:ci", resolved, tmp ++ "/rootfs.ext4", false);
    try std.testing.expectEqual(@as(usize, 2), input.guest_env.len);
    try std.testing.expectEqualStrings("GEM_HOME=/usr/local/bundle", input.guest_env[0]);
    try std.testing.expectEqualStrings("BUNDLE_APP_CONFIG=/usr/local/bundle", input.guest_env[1]);
    try std.testing.expectEqualStrings("/app", input.guest_working_dir.?);
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
    try std.testing.expectEqual(@as(usize, 2), opts.command.len);
    try std.testing.expectEqualStrings("/bin/echo", opts.command[0]);
    try std.testing.expectEqualStrings("hi", opts.command[1]);
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

test "run restores network options from manifest policy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const manifest_network = spore.Network{
        .allow_cidrs = &.{"93.184.216.34/32"},
        .allow_hosts = &.{"example.com"},
    };

    const opts = try networkOptionsFromManifest(arena, manifest_network);
    try std.testing.expectEqual(NetworkMode.spore, opts.network);
    try std.testing.expectEqual(@as(usize, 1), opts.policy.allow_cidr_count);
    try std.testing.expectEqualStrings("93.184.216.34/32", opts.policy.allow_cidrs[0]);
    try std.testing.expectEqual(@as(usize, 1), opts.policy.allow_host_count);
    try std.testing.expectEqualStrings("example.com", opts.policy.allow_hosts[0]);

    const disabled = try networkOptionsFromManifest(arena, null);
    try std.testing.expectEqual(NetworkMode.disabled, disabled.network);
    try std.testing.expect(!disabled.policy.hasRules());
}

test "run builds manifest network from active policy" {
    var policy = spore_net_policy.Config{};
    try policy.addAllowCidr("93.184.216.34/32");
    try policy.addAllowHost("example.com");

    const network = manifestNetworkFromOptions(.spore, &policy) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(spore.network_kind_spore, network.kind);
    try std.testing.expectEqualStrings("93.184.216.34/32", network.allow_cidrs[0]);
    try std.testing.expectEqualStrings("example.com", network.allow_hosts[0]);

    try std.testing.expect(manifestNetworkFromOptions(.disabled, &policy) == null);
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

    const artifact = try cacheRootfsByDigestPath(io, arena, cache_root, rootfs_path);
    try std.testing.expect(std.mem.startsWith(u8, artifact.digest, spore.rootfs_digest_prefix));
    try std.testing.expectEqual(@as(u64, "rootfs bytes".len), artifact.size);

    const rootfs = spore.Rootfs{ .device = .{ .mmio_slot = 1 }, .artifact = artifact };
    const fd = try openVerifiedRootfsFromCache(io, arena, cache_root, rootfs);
    _ = std.c.close(fd);

    const digest_path = try digestRootfsPath(arena, cache_root, artifact.digest);
    const stat = try Io.Dir.cwd().statFile(io, digest_path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o444), @as(u32, @intCast(@intFromEnum(stat.permissions) & 0o777)));

    try Io.Dir.cwd().deleteFile(io, digest_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = digest_path, .data = "tampered" });
    try std.testing.expectError(error.RootFSDigestMismatch, openVerifiedRootfsFromCache(io, arena, cache_root, rootfs));
}

test "runtime disk rejects corrupt rootfs before constructing file block source" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-runtime-disk-corrupt-rootfs";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });

    const artifact = try cacheRootfsByDigestPath(io, arena, cache_root, rootfs_path);
    const digest_path = try digestRootfsPath(arena, cache_root, artifact.digest);
    try Io.Dir.cwd().deleteFile(io, digest_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = digest_path, .data = "tampered" });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const absolute_cache_root = try std.fs.path.resolve(arena, &.{cache_root});
    try env.put(local_paths.rootfs_cache_env, absolute_cache_root);

    const context = Context{ .io = io, .environ_map = &env };

    const rootfs = spore.Rootfs{ .device = .{ .mmio_slot = 1 }, .artifact = artifact };
    try std.testing.expectError(error.RootFSDigestMismatch, openRuntimeDisk(context, arena, .{
        .rootfs = rootfs,
        .command_name = "run",
    }));
}

test "runtime disk uses manifest-bound rootfs cas source without experiment flag" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-runtime-disk-manifest-rootfs-cas";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    const rootfs_bytes = ("abcd" ** 1024) ++ ("efgh" ** 1024);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = rootfs_bytes });

    const artifact = try cacheRootfsByDigestPath(io, arena, cache_root, rootfs_path);
    const preload_result = try rootfs_cas.preload(io, arena, cache_root, artifact.digest, 4096);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const absolute_cache_root = try std.fs.path.resolve(arena, &.{cache_root});
    try env.put(local_paths.rootfs_cache_env, absolute_cache_root);

    const context = Context{ .io = io, .environ_map = &env };

    const rootfs = spore.Rootfs{
        .device = .{ .mmio_slot = 1 },
        .artifact = artifact,
        .storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload_result),
    };
    var runtime = try openRuntimeDisk(context, allocator, .{
        .rootfs = rootfs,
        .command_name = "run",
    });
    defer runtime.deinit();

    try std.testing.expect(runtime.rootfs_fd == null);
    try std.testing.expect(runtime.cas_rootfs != null);
    try std.testing.expect(runtime.cow != null);
    var readback: [4]u8 = undefined;
    try runtime.cow.?.readAt(&readback, 0);
    try std.testing.expectEqualStrings("abcd", &readback);
    try std.testing.expectEqual(@as(u64, 1), runtime.cas_rootfs.?.stats.cache_misses);
    try runtime.cow.?.readAt(&readback, 0);
    try std.testing.expectEqual(@as(u64, 1), runtime.cas_rootfs.?.stats.cache_hits);
}

test "runtime disk manifest rootfs cas fails closed without index" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-runtime-disk-manifest-rootfs-cas-missing";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });

    const artifact = try cacheRootfsByDigestPath(io, arena, cache_root, rootfs_path);
    const preload_result = try rootfs_cas.preload(io, arena, cache_root, artifact.digest, 4096);
    const index_path = try rootfs_cas.manifestIndexPath(arena, cache_root, preload_result.index_digest);
    try Io.Dir.cwd().deleteFile(io, index_path);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const absolute_cache_root = try std.fs.path.resolve(arena, &.{cache_root});
    try env.put(local_paths.rootfs_cache_env, absolute_cache_root);

    const context = Context{ .io = io, .environ_map = &env };

    const rootfs = spore.Rootfs{
        .device = .{ .mmio_slot = 1 },
        .artifact = artifact,
        .storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload_result),
    };
    try std.testing.expectError(error.MissingChunk, openRuntimeDisk(context, allocator, .{
        .rootfs = rootfs,
        .command_name = "run",
    }));
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

    const artifact = try cacheRootfsByDigestPath(io, arena, cache_root, rootfs_path);
    const digest_path = try digestRootfsPath(arena, cache_root, artifact.digest);
    try Io.Dir.cwd().deleteFile(io, digest_path);
    const digest_z = try arena.dupeZ(u8, digest_path);
    const rootfs_z = try arena.dupeZ(u8, rootfs_path);
    if (std.c.symlink(rootfs_z, digest_z) != 0) return error.SkipZigTest;

    try std.testing.expectError(error.RootFSDigestMismatch, cacheRootfsByDigestPath(io, arena, cache_root, rootfs_path));
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
    try std.testing.expectEqualStrings("sporevm-run-arm64-linux-6.1.155-Image", asset);

    const config_asset = try managedRunKernelConfigAssetName(allocator, asset);
    defer allocator.free(config_asset);
    try std.testing.expectEqualStrings("sporevm-run-arm64-linux-6.1.155-Image.config", config_asset);

    try std.testing.expectError(error.BadManagedKernelVersion, managedRunKernelAssetName(allocator, "../bad"));
}

test "managed kernel repository cache name validates owner and repo" {
    const allocator = std.testing.allocator;
    const cache = try managedKernelRepositoryCacheName(allocator, "buildkite/cleanroom-kernels");
    defer allocator.free(cache);
    try std.testing.expectEqualStrings("buildkite-cleanroom-kernels", cache);

    try std.testing.expectError(error.BadManagedKernelRepository, managedKernelRepositoryCacheName(allocator, "buildkite"));
    try std.testing.expectError(error.BadManagedKernelRepository, managedKernelRepositoryCacheName(allocator, "../cleanroom-kernels"));
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
            "CONFIG_CGROUP_DEVICE=y\n",
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

test "managed run kernel config requires Docker runtime and entropy symbols" {
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
        "CONFIG_CGROUP_DEVICE=y\n";

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
        "CONFIG_CGROUP_DEVICE=y\n";
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
        "CONFIG_CGROUP_DEVICE=y\n";
    const module_missing = (try missingManagedRunKernelConfigSymbol(allocator, module_value)).?;
    defer allocator.free(module_missing);
    try std.testing.expectEqualStrings("CONFIG_FILE_LOCKING", module_missing);
}
