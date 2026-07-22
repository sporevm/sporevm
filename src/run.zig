//! One-shot VM boot/exec support for `spore run`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const attach_stream = @import("attach_stream.zig");
const backend_mod = @import("backend.zig");
const capture = @import("capture.zig");
const Context = @import("context.zig").Context;
const disk_layer = @import("disk_layer.zig");
const fd_util = @import("fd.zig");
const generation = @import("generation.zig");
const hvf = @import("hvf/hvf.zig");
const image = @import("image.zig");
const kvm_native = @import("kvm/native.zig");
const kvm = kvm_native.binding;
const x86_board = @import("x86_64/board.zig");
const x86_vm = if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64)
    @import("x86_64/vm.zig")
else
    struct {};
const local_paths = @import("local_paths.zig");
const machine_output = @import("machine_output.zig");
const memory_config = @import("memory.zig");
const net_gateway = @import("net_gateway.zig");
const ram_restore = @import("ram_restore.zig");
const rootfs_cache = @import("rootfs_cache.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const rootfs_mod = @import("rootfs.zig");
const runtime_disk_mod = @import("runtime_disk.zig");
const runtime_disk_fork = @import("runtime_disk_fork.zig");
const run_assets = @import("run_assets");
const spore = @import("spore.zig");
const spore_net_policy = @import("spore_net_policy.zig");
const spore_stream = @import("spore_stream.zig");
const topology = @import("topology.zig");
const virtio_blk = @import("virtio/blk.zig");
const virtio_net = @import("virtio/net.zig");
const vsock = @import("virtio/vsock.zig");

const max_file_size = 256 * 1024 * 1024;
const max_kernel_asset_size = 256 * 1024 * 1024;
const max_kernel_config_asset_size = 2 * 1024 * 1024;
const managed_kernel_download_attempts = 3;
const max_guest_argc = 16;
pub const max_guest_request_len = 8191;
const max_guest_arg_len = max_guest_request_len;
pub const max_guest_envc = 64;
const max_guest_env_len = 255;
const max_guest_working_dir_len = 255;
const max_guest_port = 65535;
const max_injected_files = 16;
const max_injected_file_id_len = 96;
const max_injected_file_total_bytes = 16 * 1024 * 1024;
const embedded_run_initrd = run_assets.minimal_exec_initrd;
const embedded_run_initrd_sha256 = blk: {
    var digest: [Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, run_assets.minimal_exec_initrd_sha256_hex) catch
        @compileError("generated minimal initrd SHA-256 is not canonical hex");
    break :blk digest;
};
const default_kernel_repository = "sporevm/kernels";
const default_kernel_release = "v0.6.3";
const default_x86_kernel_release = "v0.7.0";
const default_kernel_version = "6.1.155";
pub const rootfs_growth_experiments_env = "SPOREVM_ROOTFS_GROWTH_EXPERIMENTS";
const force_write_zeroes_unsupported_experiment_env = "SPOREVM_WRITE_ZEROES_FORCE_UNSUPPORTED_EXPERIMENT";
const force_write_zeroes_backend_failure_experiment_env = "SPOREVM_WRITE_ZEROES_FORCE_BACKEND_FAILURE_EXPERIMENT";
const lazy_init_negative_control_experiment_env = "SPOREVM_ROOTFS_LAZY_INIT_NEGATIVE_CONTROL";
const managed_run_kernel_required_config_symbols = [_][]const u8{
    "CONFIG_CGROUPS",
    "CONFIG_FILE_LOCKING",
    "CONFIG_HW_RANDOM",
    "CONFIG_HW_RANDOM_VIRTIO",
    "CONFIG_VIRTIO_BLK",
    "CONFIG_EXT4_FS",
    "CONFIG_JBD2",
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
    "CONFIG_EXT4_FS_SECURITY",
    "CONFIG_MEMORY_HOTPLUG",
    "CONFIG_MEMORY_HOTPLUG_DEFAULT_ONLINE",
    "CONFIG_MEMORY_HOTREMOVE",
    "CONFIG_CONTIG_ALLOC",
    "CONFIG_EXCLUSIVE_SYSTEM_RAM",
    "CONFIG_VIRTIO_MEM",
};
const managed_x86_kernel_required_config_symbols = [_][]const u8{
    "CONFIG_X86_64",
    "CONFIG_SMP",
    "CONFIG_X86_LOCAL_APIC",
    "CONFIG_X86_IO_APIC",
    "CONFIG_X86_MPPARSE",
    "CONFIG_HYPERVISOR_GUEST",
    "CONFIG_PARAVIRT",
    "CONFIG_PARAVIRT_CLOCK",
    "CONFIG_KVM_GUEST",
    "CONFIG_RELOCATABLE",
    "CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES",
    "CONFIG_DEVMEM",
    "CONFIG_STRICT_DEVMEM",
};
const managed_x86_kernel_forbidden_config_symbols = [_][]const u8{
    "CONFIG_IO_STRICT_DEVMEM",
    "CONFIG_ACPI",
    "CONFIG_EFI",
    "CONFIG_PCI",
    "CONFIG_VIRTIO_PCI",
    "CONFIG_RTC_CLASS",
    "CONFIG_SERIAL_8250",
    "CONFIG_KEYBOARD_ATKBD",
    "CONFIG_MOUSE_PS2",
    "CONFIG_SERIO_I8042",
};
const approved_x86_kernel_sha256 = [_]u8{
    0x07, 0xa9, 0xb6, 0xd8, 0xa9, 0xef, 0xd2, 0xb7,
    0xc5, 0xe8, 0x86, 0xd1, 0xc0, 0x10, 0xe6, 0x72,
    0x45, 0xfa, 0x13, 0x2c, 0x8b, 0x48, 0xcf, 0x56,
    0x7f, 0x20, 0x00, 0x99, 0xb5, 0x5a, 0xbe, 0xe8,
};
const direct_image_platform = rootfs_mod.Platform{};
const max_rootfs_metadata_bytes = 1024 * 1024;
const auto_boot_memory_bytes: u64 = 512 * 1024 * 1024;
pub const x86_experimental_memory_bytes: u64 = 512 * 1024 * 1024;

pub const MemoryConfig = memory_config.Config;
pub const SaveTrigger = capture.Trigger;
pub const NetworkPolicy = spore_net_policy.Config;
pub const Rootfs = spore.Rootfs;
pub const Disk = spore.Disk;
pub const ClassifiedFailure = machine_output.CliError;
pub const FailureCode = machine_output.ErrorCode;
pub const FailureScope = machine_output.Scope;

pub const Backend = backend_mod.Backend;

pub const FreshProductPolicy = struct {
    memory: memory_config.Config,
    vcpus: topology.VcpuCount,
    resuming: bool = false,
    capture: bool = false,
    rootfs: bool = false,
    network: bool = false,
    build: bool = false,
};

/// Slice 3a exposes one deliberately narrow x86 product profile. Keep this
/// pure so API and lifecycle callers can reject unsupported work before
/// downloads, rootfs resolution, gateway startup, or monitor state creation.
pub fn validateFreshProductPolicy(selected_backend: Backend, policy: FreshProductPolicy) !void {
    if (comptime builtin.os.tag != .linux) return;
    return validateFreshProductPolicyFor(builtin.cpu.arch, selected_backend, policy);
}

fn validateFreshProductPolicyFor(zig_arch: std.Target.Cpu.Arch, selected_backend: Backend, policy: FreshProductPolicy) !void {
    if (zig_arch != .x86_64) return;
    if (selected_backend != .kvm) return error.UnsupportedBackend;
    if (policy.resuming) return error.X86ResumeUnsupported;
    if (policy.capture) return error.X86CaptureUnsupported;
    if (policy.rootfs) return error.X86RootfsUnsupported;
    if (policy.network) return error.X86NetworkUnsupported;
    if (policy.build) return error.X86BuildUnsupported;
    if (policy.memory.policy != .explicit) return error.X86ExplicitMemoryRequired;
    if (policy.memory.bytes != x86_experimental_memory_bytes) return error.X86ExperimentalMemorySizeUnsupported;
    if (policy.vcpus != 1) return error.X86VcpuCountUnsupported;
}

pub const Options = struct {
    backend: Backend = .auto,
    kernel_path: []const u8,
    initrd_path: ?[]const u8 = null,
    boot_artifacts: ?MonitorBootArtifacts = null,
    auto_memory_hotplug_capable: bool = false,
    rootfs_path: ?[]const u8 = null,
    rootfs: ?spore.Rootfs = null,
    rootfs_grow_target: u64 = 0,
    context_disk_path: ?[]const u8 = null,
    /// Immutable rootfs artifacts attached read-only after the optional build
    /// context disk. Build requests address these by bounded input index.
    build_input_rootfs: []const spore.Rootfs = &.{},
    /// Mutable host-local cache volume attached after immutable build inputs.
    /// It is build-only state and is never represented in a Spore manifest.
    build_cache_disk_fd: ?std.c.fd_t = null,
    /// Selects the build guest contract. Build checkpoints must persist
    /// Docker-visible rootfs paths such as /tmp and /run instead of covering
    /// them with the runtime's ephemeral tmpfs mounts.
    build_mode: bool = false,
    disk_snapshot_metrics: ?*disk_layer.SnapshotMetrics = null,
    disk: ?spore.Disk = null,
    disk_root: ?[]const u8 = null,
    runtime_disk_head: ?*runtime_disk_fork.Head = null,
    resume_dir: ?[]const u8 = null,
    resume_generation: ?generation.State = null,
    resume_sessions: []const spore.Session = &.{},
    attach_session_id: []const u8 = spore.default_session_id,
    start_generation_params: ?[]const u8 = null,
    require_generation_ready: bool = false,
    command: []const []const u8,
    guest_env: []const []const u8 = &.{},
    guest_working_dir: ?[]const u8 = null,
    injected_files: []const InjectedFile = &.{},
    interactive: bool = false,
    tty: bool = false,
    memory: memory_config.Config = .{},
    vcpus: topology.VcpuCount = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    console_log_path: ?[]const u8 = null,
    stream_output: bool = true,
    save_path: ?[]const u8 = null,
    save_trigger: capture.Trigger = .exit,
    continue_after_save: bool = false,
    commit: ?CommitOptions = null,
    annotations: spore.Annotations = .{},
    network: NetworkMode = .disabled,
    network_policy: spore_net_policy.Config = .{},
    network_runtime: ?virtio_net.Runtime = null,
    events: ?EventSink = null,
    spore_executable: []const u8 = "spore",
    debug: bool = false,
};

pub const CommitOptions = struct {
    ref: []const u8,
    config: rootfs_mod.ImageConfig,
    platform: rootfs_mod.Platform = direct_image_platform,
};

pub const InjectedFile = struct {
    id: []const u8,
    bytes: []const u8,
};

pub const InjectedFileSource = struct {
    id: []const u8,
    path: []const u8,
};

pub const GuestEnvSpec = union(enum) {
    literal: []const u8,
    copy: []const u8,
};

pub const GuestEnvSpecList = struct {
    items: [max_guest_envc]GuestEnvSpec = undefined,
    len: usize = 0,

    pub fn append(self: *GuestEnvSpecList, spec: GuestEnvSpec) !void {
        if (self.len >= max_guest_envc) return error.TooManyRunEnv;
        self.items[self.len] = spec;
        self.len += 1;
    }

    pub fn slice(self: *const GuestEnvSpecList) []const GuestEnvSpec {
        return self.items[0..self.len];
    }
};

pub const InjectedFileSourceList = struct {
    items: [max_injected_files]InjectedFileSource = undefined,
    len: usize = 0,

    pub fn append(self: *InjectedFileSourceList, input: InjectedFileSource) !void {
        if (self.len >= max_injected_files) return error.TooManyInjectedFiles;
        try validateInjectedFileId(input.id);
        if (input.path.len == 0) return error.BadInjectedFilePath;
        for (self.items[0..self.len]) |existing| {
            if (std.mem.eql(u8, existing.id, input.id)) return error.DuplicateInjectedFile;
        }
        self.items[self.len] = input;
        self.len += 1;
    }

    pub fn slice(self: *const InjectedFileSourceList) []const InjectedFileSource {
        return self.items[0..self.len];
    }
};

pub const BoundServiceArgList = struct {
    items: [spore_net_policy.max_bound_services][]const u8 = undefined,
    len: usize = 0,

    pub fn append(self: *BoundServiceArgList, raw: []const u8) !void {
        if (self.len >= spore_net_policy.max_bound_services) return error.TooManyBoundServices;
        self.items[self.len] = raw;
        self.len += 1;
    }

    pub fn slice(self: *const BoundServiceArgList) []const []const u8 {
        return self.items[0..self.len];
    }
};

pub const BoundServiceBindingList = struct {
    items: [spore_net_policy.max_bound_services]spore_net_policy.BoundServiceBinding = undefined,
    len: usize = 0,

    pub fn append(self: *BoundServiceBindingList, binding: spore_net_policy.BoundServiceBinding) !void {
        if (self.len >= spore_net_policy.max_bound_services) return error.TooManyBoundServices;
        self.items[self.len] = binding;
        self.len += 1;
    }

    pub fn slice(self: *const BoundServiceBindingList) []const spore_net_policy.BoundServiceBinding {
        return self.items[0..self.len];
    }
};

pub const BoundServiceBindingDiagnostic = spore_net_policy.BoundServiceBindingDiagnostic;

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
    vcpus: topology.VcpuCount,
    memory_bytes: u64,
    saved: bool = false,
    committed: bool = false,
    save_path: ?[]const u8 = null,
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
    saved: bool = false,
    save_path: ?[]const u8 = null,
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

    pub fn emitOutput(self: *EventEmitter, output: vsock.HostStreamOutput, bytes: []const u8) !void {
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
        .guest_host = if (service.guest_host.len == 0) null else service.guest_host,
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
    };
}

fn exitEvent(command: []const u8, result: Result) ExitEvent {
    return .{
        .command = command,
        .backend = result.backend,
        .exit_code = result.exit_code,
        .vcpus = result.vcpus,
        .memory_bytes = result.memory_bytes,
        .saved = result.saved,
        .save_path = result.save_path,
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

    fn emitPortForwardEvent(self: *EventWriter, value: PortForwardEvent) !void {
        if (value.backend) |backend| self.setBackend(backend);
        const event = struct {
            schema: []const u8 = machine_output.run_events_schema,
            schema_version: u32 = machine_output.run_events_schema_version,
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

    fn emitSaveEvent(self: *EventWriter, value: SaveEvent) !void {
        self.setBackend(value.backend);
        const event = struct {
            schema: []const u8 = machine_output.run_events_schema,
            schema_version: u32 = machine_output.run_events_schema_version,
            event: []const u8 = "capture",
            command: []const u8,
            backend: []const u8,
            capture_path: []const u8,
        }{
            .command = value.command,
            .backend = value.backend.name(),
            .capture_path = value.save_path,
        };
        try self.write(event);
    }

    fn emitImageCommitEvent(self: *EventWriter, value: ImageCommitEvent) !void {
        self.setBackend(value.backend);
        const event = struct {
            schema: []const u8 = machine_output.run_events_schema,
            schema_version: u32 = machine_output.run_events_schema_version,
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
            schema: []const u8 = machine_output.run_events_schema,
            schema_version: u32 = machine_output.run_events_schema_version,
            event: []const u8 = "exit",
            command: []const u8,
            backend: []const u8,
            exit_code: i32,
            vcpus: topology.VcpuCount,
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
            .captured = value.saved,
            .capture_path = value.save_path,
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
            .terminal => self.terminal_offset,
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
    if (err == error.X86ExplicitMemoryRequired or err == error.X86ExperimentalMemorySizeUnsupported) {
        return machine_output.CliError.init(
            .usage_invalid_argument,
            "spore run: experimental x86-64 KVM requires explicit --memory 512mib; omitted and automatic memory are unavailable",
            @errorName(err),
        );
    }
    if (err == error.X86ResumeUnsupported or err == error.X86CaptureUnsupported) {
        return machine_output.CliError.init(
            .usage_invalid_argument,
            "spore run: x86-64 KVM currently supports fresh execution only; resume, save, capture, fork, and image commit are unavailable",
            @errorName(err),
        );
    }
    if (err == error.X86RootfsUnsupported or err == error.X86NetworkUnsupported or err == error.X86BuildUnsupported) {
        return machine_output.CliError.init(
            .usage_invalid_argument,
            "spore run: x86-64 KVM rootfs, OCI, networking, and build integration have not landed yet",
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
    if (err == error.TtyRunFromSporeUnsupported) {
        return machine_output.CliError.init(
            .usage_invalid_argument,
            "spore run: -t with --from command execution is not supported yet; use `spore attach -t <spore>` to connect to a saved terminal session",
            @errorName(err),
        );
    }
    if (err == error.InteractiveStreamProtocolFailed) {
        return machine_output.CliError.init(
            .runtime_start_failed,
            "spore run: interactive stream protocol failed; ensure the guest initrd supports start-v1 or omit -i/-t",
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
            .usage_invalid_argument,
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

pub fn isX86ProductPolicyError(err: anyerror) bool {
    return err == error.X86ExplicitMemoryRequired or
        err == error.X86ExperimentalMemorySizeUnsupported or
        err == error.X86VcpuCountUnsupported or
        err == error.X86ResumeUnsupported or
        err == error.X86CaptureUnsupported or
        err == error.X86RootfsUnsupported or
        err == error.X86NetworkUnsupported or
        err == error.X86BuildUnsupported;
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
    vcpus: topology.VcpuCount = 1,
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
    generation_path: ?[]const u8 = null,
    rootfs_path: ?[]const u8 = null,
    image_ref: ?[]const u8 = null,
    pull_policy: PullPolicy = .missing,
    commit_ref: ?[]const u8 = null,
    disk_size: ?u64 = null,
    save_path: ?[]const u8 = null,
    save_trigger: capture.Trigger = .exit,
    continue_after_save: bool = false,
    network: NetworkMode = .disabled,
    network_requested: bool = false,
    network_policy: spore_net_policy.Config = .{},
    bound_services: BoundServiceBindingList = .{},
    event_mode: EventMode = .none,
    interactive: bool = false,
    tty: bool = false,
    guest_env_specs: GuestEnvSpecList = .{},
    injected_file_sources: InjectedFileSourceList = .{},
    command_mode: CommandMode = .argv,
    command: []const []const u8,
};

pub const CommandMode = enum {
    argv,
    shell,
};

pub const NetworkOptions = struct {
    network: NetworkMode = .disabled,
    policy: spore_net_policy.Config = .{},
};

pub const cli_usage =
    \\Usage:
    \\  spore run --image REF [options]
    \\  spore run [--kernel Image] [--initrd root.cpio] [options] 'shell command'
    \\  spore run [--kernel Image] [--initrd root.cpio] [options] -- <argv...>
    \\  spore run --from DIR [options] 'shell command'
    \\  spore run --from DIR [options] -- <argv...>
    \\
    \\Options:
    \\  --backend auto|hvf|kvm  Backend to run (default: auto)
    \\  --kernel Image          Kernel Image path (default: managed SporeVM kernel)
    \\  --initrd root.cpio      Initrd path (default: embedded minimal exec initrd)
    \\  --from DIR              Restore VM state from a spore and run a new command
    \\                          Uses spore memory/device sizing; omit --memory
    \\  --generation FILE       With --from, inject fan-out identity JSON before command
    \\  --rootfs rootfs.ext4    Attach local rootfs read-only; save unsupported
    \\  --image REF             Build or reuse cached OCI rootfs; default to Entrypoint + Cmd
    \\  --pull=missing|always|never
    \\                          Pull policy for mutable --image refs (default: missing)
    \\  --commit LOCAL_REF      On command success, publish the writable root disk as an image
    \\  --disk-size SIZE        Grow an image-backed commit disk before the command (e.g. 20gb)
    \\  --net                   Experimental SporeVM-managed networking
    \\  --allow-cidr CIDR       With --net, restrict public egress to this CIDR
    \\  --allow-host HOST       With --net, restrict public egress to DNS A answers for this host
    \\  --bind-service NAME[:PORT]=unix:/path.sock
    \\                          With --net, declare a guest-local Unix service
    \\  --bind-service NAME=unix:/path.sock
    \\                          With --from, bind a manifest-declared service
    \\  --forward 127.0.0.1:HOST_PORT:GUEST_PORT
    \\                          With --net, forward host loopback TCP to a guest port
    \\  --save DIR              Save a spore to DIR; defaults to --save-on EXIT
    \\  --save-on WHEN          Save trigger: EXIT, INT, TERM, HUP, USR1, or USR2
    \\  --continue-after-save   Keep running after a signal-triggered save
    \\  --memory VALUE          Guest memory: auto, 512mb, 2gb, ... (default: auto = 16GiB)
    \\  --vcpus N               Guest vCPU count (1-8; save/restore backend-dependent)
    \\  --guest-port N          Guest vsock listen port (default: 10700)
    \\  --timeout DURATION      Probe timeout (default: 30s; e.g. 500ms, 1m)
    \\  --console-log PATH      Write guest console output to PATH
    \\  --events=jsonl          Emit lifecycle and guest output events as JSONL on stdout
    \\  --env KEY[=VALUE]       Set or copy a host env var for the guest command
    \\  --inject ID=PATH        Inject PATH as /run/sporevm/injected/ID for this run
    \\  -i, --interactive       Keep stdin open and forward it to the guest process
    \\  -t, --tty               Allocate a guest terminal for the process
    \\  -- <argv...>            Run exact argv instead of /bin/sh -lc
    \\  -h, --help              Show this help
    \\
    \\Workflow:
    \\  spore run --save base.spore --save-on TERM 'while true; do echo tick; sleep 1; done'
    \\  spore fork base.spore --count 2 --out children
    \\  spore fanout children --for 10s
    \\
;

/// Redirect hints for run flags removed in the spore/saved-session rename.
fn renamedRunFlagHint(arg: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, arg, "--capture")) return "--save DIR";
    if (std.mem.eql(u8, arg, "--capture-on")) return "--save-on WHEN";
    if (std.mem.eql(u8, arg, "--continue-after-capture")) return "--continue-after-save";
    return null;
}

pub fn parseCliArgs(args: []const []const u8) !CliOptions {
    var backend: Backend = .auto;
    var shared = SharedOptions{};
    var from_spore_dir: ?[]const u8 = null;
    var generation_path: ?[]const u8 = null;
    var rootfs_path: ?[]const u8 = null;
    var image_ref: ?[]const u8 = null;
    var pull_policy: PullPolicy = .missing;
    var commit_ref: ?[]const u8 = null;
    var disk_size: ?u64 = null;
    var save_path: ?[]const u8 = null;
    var save_trigger: capture.Trigger = .exit;
    var save_trigger_set = false;
    var continue_after_save = false;
    var network: NetworkMode = .disabled;
    var network_requested = false;
    var network_policy = spore_net_policy.Config{};
    var bind_service_args = BoundServiceArgList{};
    var bound_services = BoundServiceBindingList{};
    var event_mode: EventMode = .none;
    var interactive = false;
    var tty = false;
    var guest_env_specs = GuestEnvSpecList{};
    var injected_file_sources = InjectedFileSourceList{};
    var command_mode: CommandMode = .shell;
    var command_had_delimiter = false;
    var command: ?[]const []const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            command_mode = .argv;
            command_had_delimiter = true;
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
        } else if (std.mem.eql(u8, args[i], "--commit")) {
            commit_ref = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--disk-size")) {
            const raw = takeValue(args, &i, args[i]);
            const parsed = memory_config.parse(raw) catch |err| {
                std.debug.print("spore run: invalid --disk-size {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            };
            if (parsed.policy != .explicit or parsed.bytes % rootfs_cas.default_chunk_size != 0) {
                std.debug.print("spore run: --disk-size must be a positive 64KiB-aligned size like 20gb\n", .{});
                std.process.exit(2);
            }
            disk_size = parsed.bytes;
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
        } else if (std.mem.eql(u8, args[i], "--generation")) {
            generation_path = takeValue(args, &i, args[i]);
        } else if (std.mem.startsWith(u8, args[i], "--generation=")) {
            generation_path = args[i]["--generation=".len..];
        } else if (std.mem.eql(u8, args[i], "--save")) {
            save_path = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--save-on")) {
            const trigger_raw = takeValue(args, &i, args[i]);
            save_trigger = capture.Trigger.parse(trigger_raw) orelse {
                std.debug.print("--save-on must be EXIT, INT, TERM, HUP, USR1, or USR2\n", .{});
                std.process.exit(2);
            };
            save_trigger_set = true;
        } else if (std.mem.eql(u8, args[i], "--continue-after-save")) {
            continue_after_save = true;
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
        } else if (std.mem.eql(u8, args[i], "--env")) {
            const raw = takeValue(args, &i, args[i]);
            guest_env_specs.append(parseGuestEnvSpec(raw) catch |err| {
                std.debug.print("spore run: invalid --env {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            }) catch |err| {
                std.debug.print("spore run: invalid --env {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "-i") or std.mem.eql(u8, args[i], "--interactive")) {
            interactive = true;
        } else if (std.mem.eql(u8, args[i], "-t") or std.mem.eql(u8, args[i], "--tty")) {
            tty = true;
        } else if (std.mem.eql(u8, args[i], "-it") or std.mem.eql(u8, args[i], "-ti")) {
            interactive = true;
            tty = true;
        } else if (std.mem.eql(u8, args[i], "--inject")) {
            const raw = takeValue(args, &i, args[i]);
            injected_file_sources.append(parseInjectedFileSource(raw) catch |err| {
                std.debug.print("spore run: invalid --inject {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            }) catch |err| {
                std.debug.print("spore run: invalid --inject {s}: {s}\n", .{ raw, @errorName(err) });
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
            bind_service_args.append(raw) catch |err| {
                std.debug.print("spore run: invalid --bind-service {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--forward")) {
            const raw = takeValue(args, &i, args[i]);
            network_policy.addPortForward(raw) catch |err| {
                std.debug.print("spore run: invalid --forward {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            };
        } else if (try parseSharedOption(&shared, args, &i)) {
            continue;
        } else if (renamedRunFlagHint(args[i])) |replacement| {
            std.debug.print("spore run: {s} was renamed; use {s}\n", .{ args[i], replacement });
            std.process.exit(2);
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            std.debug.print("unknown run argument: {s}\n\n{s}", .{ args[i], cli_usage });
            std.process.exit(2);
        } else {
            command = args[i..];
            break;
        }
    }

    const argv = command orelse &.{};
    if (argv.len == 0 and (command_had_delimiter or (from_spore_dir == null and image_ref == null))) {
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
    if (disk_size != null and commit_ref == null) {
        std.debug.print("spore run: --disk-size currently requires --commit\n", .{});
        std.process.exit(2);
    }
    if (commit_ref) |ref| {
        rootfs_mod.validateLocalTagRef(ref) catch |err| {
            std.debug.print("spore run: invalid --commit ref {s}: {s}\n", .{ ref, @errorName(err) });
            std.process.exit(2);
        };
        if (image_ref == null) {
            std.debug.print("spore run: --commit requires --image\n", .{});
            std.process.exit(2);
        }
        if (from_spore_dir != null or rootfs_path != null) {
            std.debug.print("spore run: --commit supports fresh --image runs only\n", .{});
            std.process.exit(2);
        }
        if (save_path != null or save_trigger_set or continue_after_save) {
            std.debug.print("spore run: --commit cannot be combined with --save, --save-on, or --continue-after-save\n", .{});
            std.process.exit(2);
        }
        if (interactive or tty) {
            std.debug.print("spore run: --commit cannot be combined with -i or -t\n", .{});
            std.process.exit(2);
        }
    }
    if (from_spore_dir != null) {
        for (bind_service_args.slice()) |raw| {
            bound_services.append(spore_net_policy.parseBoundServiceBinding(raw) catch |err| {
                std.debug.print("spore run: invalid --bind-service {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            }) catch |err| {
                std.debug.print("spore run: invalid --bind-service {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            };
        }
        if (injected_file_sources.len != 0) {
            std.debug.print("spore run: --inject is not supported with --from; injected files are fresh-run only\n", .{});
            std.process.exit(2);
        }
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
    } else {
        if (generation_path != null) {
            std.debug.print("spore run: --generation requires --from\n", .{});
            std.process.exit(2);
        }
        for (bind_service_args.slice()) |raw| {
            network_policy.addBindService(raw) catch |err| {
                std.debug.print("spore run: invalid --bind-service {s}: {s}\n", .{ raw, @errorName(err) });
                std.process.exit(2);
            };
        }
    }
    if (save_trigger_set and save_path == null) {
        std.debug.print("spore run: --save-on requires --save\n", .{});
        std.process.exit(2);
    }
    if (continue_after_save and save_path == null) {
        std.debug.print("spore run: --continue-after-save requires --save\n", .{});
        std.process.exit(2);
    }
    if (continue_after_save and save_trigger.isExit()) {
        std.debug.print("spore run: --continue-after-save requires a signal save trigger\n", .{});
        std.process.exit(2);
    }
    if (save_path != null and injected_file_sources.len != 0) {
        std.debug.print("spore run: --inject with --save is not supported; injected files are intentionally not persisted\n", .{});
        std.process.exit(2);
    }
    if (network == .disabled and network_policy.hasRules()) {
        std.debug.print("spore run: network flags require --net\n", .{});
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
        .generation_path = generation_path,
        .rootfs_path = rootfs_path,
        .image_ref = image_ref,
        .pull_policy = pull_policy,
        .commit_ref = commit_ref,
        .disk_size = disk_size,
        .save_path = save_path,
        .save_trigger = save_trigger,
        .continue_after_save = continue_after_save,
        .network = network,
        .network_requested = network_requested,
        .network_policy = network_policy,
        .bound_services = bound_services,
        .event_mode = event_mode,
        .interactive = interactive,
        .tty = tty,
        .guest_env_specs = guest_env_specs,
        .injected_file_sources = injected_file_sources,
        .command_mode = command_mode,
        .command = argv,
    };
}

pub fn parseGuestEnvSpec(raw: []const u8) !GuestEnvSpec {
    if (std.mem.indexOfScalar(u8, raw, '=')) |eq| {
        const key = raw[0..eq];
        try validateGuestEnvKey(key);
        return .{ .literal = raw };
    }
    try validateGuestEnvKey(raw);
    return .{ .copy = raw };
}

pub const GuestEnvResolveDiagnostic = struct {
    missing_key: ?[]const u8 = null,
};

pub fn resolveCliGuestEnv(
    allocator: std.mem.Allocator,
    specs: []const GuestEnvSpec,
    environ: *const std.process.Environ.Map,
    diagnostic: ?*GuestEnvResolveDiagnostic,
) ![]const []const u8 {
    if (diagnostic) |diag| diag.* = .{};
    var out = std.array_list.Managed([]const u8).init(allocator);
    for (specs) |spec| {
        const entry = switch (spec) {
            .literal => |entry| entry,
            .copy => |key| blk: {
                const value = environ.get(key) orelse {
                    if (diagnostic) |diag| diag.missing_key = key;
                    return error.MissingHostEnvironment;
                };
                break :blk try std.fmt.allocPrint(allocator, "{s}={s}", .{ key, value });
            },
        };
        if (entry.len > max_guest_env_len) return error.RunEnvTooLong;
        try upsertGuestEnvEntry(&out, entry);
    }
    return out.toOwnedSlice();
}

pub fn mergeGuestEnv(allocator: std.mem.Allocator, base: []const []const u8, overrides: []const []const u8) ![]const []const u8 {
    if (base.len == 0) return overrides;
    if (overrides.len == 0) return base;
    var out = std.array_list.Managed([]const u8).init(allocator);
    for (base) |entry| {
        if (!guestEnvHasKey(overrides, inheritedGuestEnvEntryKey(entry))) try out.append(entry);
    }
    for (overrides) |entry| try out.append(entry);
    if (out.items.len > max_guest_envc) return error.RunEnvCountUnsupported;
    return out.toOwnedSlice();
}

pub fn mergeGuestEnvInto(out: [][]const u8, base: []const []const u8, overrides: []const []const u8) ![]const []const u8 {
    var len: usize = 0;
    for (base) |entry| {
        if (!guestEnvHasKey(overrides, inheritedGuestEnvEntryKey(entry))) {
            if (len >= out.len or len >= max_guest_envc) return error.RunEnvCountUnsupported;
            out[len] = entry;
            len += 1;
        }
    }
    for (overrides) |entry| {
        if (len >= out.len or len >= max_guest_envc) return error.RunEnvCountUnsupported;
        out[len] = entry;
        len += 1;
    }
    return out[0..len];
}

fn upsertGuestEnvEntry(entries: *std.array_list.Managed([]const u8), entry: []const u8) !void {
    const key = guestEnvEntryKey(entry) orelse return error.BadGuestEnvKey;
    for (entries.items, 0..) |existing, i| {
        if (guestEnvKeyEql(guestEnvEntryKey(existing), key)) {
            entries.items[i] = entry;
            return;
        }
    }
    if (entries.items.len >= max_guest_envc) return error.RunEnvCountUnsupported;
    try entries.append(entry);
}

fn guestEnvHasKey(entries: []const []const u8, key: ?[]const u8) bool {
    for (entries) |entry| {
        if (guestEnvKeyEql(guestEnvEntryKey(entry), key)) return true;
    }
    return false;
}

fn guestEnvKeyEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn guestEnvEntryKey(entry: []const u8) ?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return null;
    if (eq == 0) return null;
    return entry[0..eq];
}

fn inheritedGuestEnvEntryKey(entry: []const u8) ?[]const u8 {
    return guestEnvEntryKey(entry) orelse if (entry.len != 0) entry else null;
}

fn validateGuestEnvKey(key: []const u8) !void {
    if (key.len == 0) return error.BadGuestEnvKey;
    for (key, 0..) |c, i| {
        if (std.ascii.isAlphabetic(c) or c == '_' or (i != 0 and std.ascii.isDigit(c))) continue;
        return error.BadGuestEnvKey;
    }
}

fn parseInjectedFileSource(raw: []const u8) !InjectedFileSource {
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return error.BadInjectedFile;
    const id = raw[0..eq];
    const path = raw[eq + 1 ..];
    try validateInjectedFileId(id);
    if (path.len == 0) return error.BadInjectedFilePath;
    return .{ .id = id, .path = path };
}

pub fn cliGuestCommand(allocator: std.mem.Allocator, opts: CliOptions) ![]const []const u8 {
    return cliGuestCommandFromMode(allocator, opts.command_mode, opts.command);
}

pub fn cliGuestCommandFromMode(allocator: std.mem.Allocator, mode: CommandMode, command: []const []const u8) ![]const []const u8 {
    return switch (mode) {
        .argv => command,
        .shell => {
            if (command.len != 1) return error.ShellCommandArgumentCountUnsupported;
            return allocator.dupe([]const u8, &.{ "/bin/sh", "-lc", command[0] });
        },
    };
}

pub fn networkOptionsFromManifest(allocator: std.mem.Allocator, manifest_network: ?spore.Network) !NetworkOptions {
    return networkOptionsFromManifestWithBindings(allocator, manifest_network, &.{});
}

pub fn networkOptionsFromManifestWithBindings(
    allocator: std.mem.Allocator,
    manifest_network: ?spore.Network,
    bound_services: []const spore_net_policy.BoundServiceBinding,
) !NetworkOptions {
    return networkOptionsFromManifestWithBindingDiagnostic(allocator, manifest_network, bound_services, null);
}

pub fn networkOptionsFromManifestWithBindingDiagnostic(
    allocator: std.mem.Allocator,
    manifest_network: ?spore.Network,
    bound_services: []const spore_net_policy.BoundServiceBinding,
    diagnostic: ?*BoundServiceBindingDiagnostic,
) !NetworkOptions {
    if (diagnostic) |diag| diag.* = .{};
    const network = manifest_network orelse {
        if (bound_services.len != 0) {
            if (diagnostic) |diag| diag.unexpected_name = bound_services[0].name;
            return error.UnexpectedBoundServiceBinding;
        }
        return .{};
    };
    return .{ .network = .spore, .policy = try spore_net_policy.configFromManifestNetworkWithBindingDiagnostic(allocator, network, bound_services, diagnostic) };
}

pub fn manifestNetworkFromOptions(allocator: std.mem.Allocator, network: NetworkMode, policy: *const spore_net_policy.Config) !?spore.Network {
    if (network != .spore) return null;
    return try spore_net_policy.manifestNetworkFromConfig(allocator, policy);
}

pub fn resumeRootfsForRun(allocator: std.mem.Allocator, manifest: spore.Manifest) !?spore.Rootfs {
    return resumeRootfsForRunParts(allocator, manifest.devices, manifest.rootfs);
}

pub fn resumeRootfsForRunV1(allocator: std.mem.Allocator, manifest: spore.ManifestV1) !?spore.Rootfs {
    return resumeRootfsForRunParts(allocator, manifest.devices, manifest.rootfs);
}

fn resumeRootfsForRunParts(allocator: std.mem.Allocator, devices: []const spore.TransportState, rootfs_opt: ?spore.Rootfs) !?spore.Rootfs {
    const disk_count = spore.countBlockDevices(devices);
    if (disk_count == 0) return null;
    if (disk_count != 1) return error.UnsupportedRootfsDeviceCount;
    const rootfs = rootfs_opt orelse return error.MissingRootfsArtifact;
    try spore.validateRootfs(rootfs, devices);
    return try cloneRootfs(allocator, rootfs);
}

pub fn resumeDiskForRun(allocator: std.mem.Allocator, manifest: spore.Manifest) !?spore.Disk {
    return resumeDiskForRunParts(allocator, manifest.disk);
}

pub fn resumeDiskForRunV1(allocator: std.mem.Allocator, manifest: spore.ManifestV1) !?spore.Disk {
    return resumeDiskForRunParts(allocator, manifest.disk);
}

fn resumeDiskForRunParts(allocator: std.mem.Allocator, disk_opt: ?spore.Disk) !?spore.Disk {
    if (disk_opt) |disk| {
        return try disk_layer.cloneDisk(allocator, disk);
    }
    return null;
}

fn cloneRootfs(allocator: std.mem.Allocator, rootfs: spore.Rootfs) !spore.Rootfs {
    return .{
        .kind = try allocator.dupe(u8, rootfs.kind),
        .mode = try allocator.dupe(u8, rootfs.mode),
        .device = try spore.cloneRootfsDevice(allocator, rootfs.device),
        .artifact = .{
            .digest = try allocator.dupe(u8, rootfs.artifact.digest),
            .size = rootfs.artifact.size,
            .format = try allocator.dupe(u8, rootfs.artifact.format),
        },
        .storage = if (rootfs.storage) |storage| try spore.cloneRootfsStorage(allocator, storage) else null,
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
    image_config: ?rootfs_mod.ImageConfig = null,
    guest_env: []const []const u8 = &.{},
    guest_working_dir: ?[]const u8 = null,
};

/// Resolve OCI process metadata for a fresh image-backed invocation. The
/// returned argv borrows strings from the image config and caller command;
/// only the slice itself is allocated. OCI User is deliberately root-only
/// until the guest can switch credentials.
pub fn resolveImageRuntimeCommand(
    allocator: std.mem.Allocator,
    image_config: ?rootfs_mod.ImageConfig,
    caller_command: []const []const u8,
) ![]const []const u8 {
    const runtime = if (image_config) |config| config.config else null;
    const entrypoint = if (runtime) |config| config.Entrypoint orelse &.{} else &.{};
    const command = if (caller_command.len != 0)
        caller_command
    else if (runtime) |config|
        config.Cmd orelse &.{}
    else
        &.{};

    if (runtime) |config| {
        if (!image.isRootUser(config.User)) return error.UnsupportedImageUser;
    }
    if (entrypoint.len == 0 and command.len == 0) return error.ImageCommandMissing;
    if (entrypoint.len > max_guest_argc or command.len > max_guest_argc - entrypoint.len) return error.RunArgCountUnsupported;
    const len = entrypoint.len + command.len;
    const argv = try allocator.alloc([]const u8, len);
    errdefer allocator.free(argv);
    @memcpy(argv[0..entrypoint.len], entrypoint);
    @memcpy(argv[entrypoint.len..], command);
    try validateGuestArgv(argv);
    return argv;
}

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
    const artifact = resolvePathRootfsArtifact(init.io, allocator, cache_root, rootfs_path) catch |err| {
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

fn resolvePathRootfsArtifact(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    rootfs_path: []const u8,
) !spore.RootfsArtifactRef {
    if (try trustedExplicitCachedRootfsArtifact(io, allocator, cache_root, rootfs_path)) |artifact| return artifact;
    return rootfs_cache.cacheByDigestPathCopy(io, allocator, cache_root, rootfs_path);
}

fn trustedExplicitCachedRootfsArtifact(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    rootfs_path: []const u8,
) !?spore.RootfsArtifactRef {
    const cache_key = directImageCacheRootfsKey(cache_root, rootfs_path) orelse return null;
    const metadata_file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{cache_key});
    defer allocator.free(metadata_file_name);
    const metadata_path = try std.fs.path.join(allocator, &.{ cache_root, metadata_file_name });
    defer allocator.free(metadata_path);

    const artifact = (try rootfs_mod.cachedImageRootfsArtifact(io, allocator, metadata_path, rootfs_path)) orelse return null;
    errdefer allocator.free(artifact.digest);

    const trusted_rootfs = spore.Rootfs{
        .device = .{ .mmio_slot = 1 },
        .artifact = artifact,
    };
    const fd = rootfs_cache.openTrustedFromCache(io, allocator, cache_root, trusted_rootfs) catch |err| switch (err) {
        error.RootFSDigestCacheMiss => {
            allocator.free(artifact.digest);
            return null;
        },
        else => |e| return e,
    };
    _ = std.c.close(fd);
    return artifact;
}

fn directImageCacheRootfsKey(cache_root: []const u8, rootfs_path: []const u8) ?[]const u8 {
    if (!Io.Dir.path.isAbsolute(rootfs_path)) return null;

    const file_name = directCacheChildName(cache_root, rootfs_path) orelse return null;
    if (!std.mem.endsWith(u8, file_name, ".ext4")) return null;
    const cache_key = file_name[0 .. file_name.len - ".ext4".len];
    if (cache_key.len != Sha256.digest_length * 2) return null;
    for (cache_key) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return null;
    }
    return cache_key;
}

fn directCacheChildName(cache_root: []const u8, path: []const u8) ?[]const u8 {
    if (cache_root.len == 0) return null;
    if (std.mem.eql(u8, cache_root, std.fs.path.sep_str)) {
        if (path.len <= cache_root.len) return null;
        const file_name = path[cache_root.len..];
        if (std.mem.indexOfScalar(u8, file_name, std.fs.path.sep) != null) return null;
        return file_name;
    }

    if (!std.mem.startsWith(u8, path, cache_root)) return null;
    if (path.len <= cache_root.len + 1) return null;
    if (path[cache_root.len] != std.fs.path.sep) return null;
    const file_name = path[cache_root.len + 1 ..];
    if (std.mem.indexOfScalar(u8, file_name, std.fs.path.sep) != null) return null;
    return file_name;
}

fn resolveImageRootfs(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    image_ref: []const u8,
    command_name: []const u8,
    pull_policy: PullPolicy,
    record_artifact: bool,
) !RootfsInputResolution {
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

    const ext4_writer_choice = rootfs_mod.selectedExt4Writer(init.environ_map) catch |err| {
        return .{ .failure = rootfsInputFailure(
            allocator,
            machine_output.fromZigError(err).code,
            command_name,
            "spore {s}: rootfs writer selection failed: {s}",
            .{ command_name, @errorName(err) },
        ) };
    };
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
        if (rootfs_mod.cachedImageRootfsPath(init.io, allocator, cache_root, resolved, ext4_writer_choice) catch |err| {
            return .{ .failure = rootfsInputFailure(
                allocator,
                .cache_integrity_failed,
                command_name,
                "spore {s}: cached rootfs metadata check failed: {s}",
                .{ command_name, @errorName(err) },
            ) };
        }) |path| {
            return try resolvedImageRootfsInputResult(init, allocator, cache_root, image_ref, resolved, path, command_name, record_artifact, true);
        }
        if (try resolvedIndexedImageRootfsInputResult(init, allocator, cache_root, image_ref, resolved, command_name)) |indexed| {
            return indexed;
        }
        return .{ .failure = rootfsInputFailure(
            allocator,
            .object_not_found,
            command_name,
            "spore {s}: local image rootfs cache miss for {s}; import an OCI layout with 'spore rootfs import-oci <layout> --ref local/name:tag'",
            .{ command_name, image_ref },
        ) };
    }

    const digest_pinned = try rootfs_mod.digestPinnedImageIdentity(allocator, image_ref, direct_image_platform);

    if (digest_pinned) |resolved| {
        if (rootfs_mod.cachedImageRootfsPath(init.io, allocator, cache_root, resolved, ext4_writer_choice) catch |err| {
            return .{ .failure = rootfsInputFailure(
                allocator,
                .cache_integrity_failed,
                command_name,
                "spore {s}: cached rootfs metadata check failed: {s}",
                .{ command_name, @errorName(err) },
            ) };
        }) |path| {
            return try resolvedImageRootfsInputResult(init, allocator, cache_root, image_ref, resolved, path, command_name, record_artifact, true);
        }
        if (try resolvedIndexedImageRootfsInputResult(init, allocator, cache_root, image_ref, resolved, command_name)) |indexed| {
            return indexed;
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
            if (rootfs_mod.cachedImageRefRootfsPath(init.io, allocator, cache_root, image_ref, direct_image_platform, ext4_writer_choice) catch |err| {
                return .{ .failure = rootfsInputFailure(
                    allocator,
                    .cache_integrity_failed,
                    command_name,
                    "spore {s}: cached image ref check failed: {s}",
                    .{ command_name, @errorName(err) },
                ) };
            }) |hit| {
                return try resolvedImageRootfsInputResult(init, allocator, cache_root, image_ref, hit.resolved, hit.path, command_name, record_artifact, true);
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
    if (rootfs_mod.cachedImageRootfsPath(init.io, allocator, cache_root, resolved, ext4_writer_choice) catch |err| {
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
        return try resolvedImageRootfsInputResult(init, allocator, cache_root, image_ref, resolved, path, command_name, record_artifact, true);
    }
    if (try resolvedIndexedImageRootfsInputResult(init, allocator, cache_root, image_ref, resolved, command_name)) |indexed| {
        return indexed;
    }
    const path = rootfs_mod.buildCachedImageRootfs(init, allocator, cache_root, resolved, ext4_writer_choice) catch |err| {
        if (err == error.UnsupportedExt4FileSize) {
            return .{ .failure = rootfsInputFailure(
                allocator,
                machine_output.fromZigError(err).code,
                command_name,
                "spore {s}: image rootfs build failed for {s}: native ext4 writer does not support files larger than 4 GiB yet; set SPOREVM_EXT4_WRITER=external to use the e2fsprogs writer",
                .{ command_name, resolved.ref },
            ) };
        }
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
    return try resolvedImageRootfsInputResult(init, allocator, cache_root, image_ref, resolved, path, command_name, record_artifact, false);
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
    storage_prevalidated: bool,
) !RootfsInputResolution {
    const input = resolvedImageRootfsInput(init, allocator, cache_root, requested_ref, resolved, rootfs_path, record_artifact, storage_prevalidated) catch |err| {
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

fn resolvedIndexedImageRootfsInputResult(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    requested_ref: []const u8,
    resolved: rootfs_mod.ResolvedImage,
    command_name: []const u8,
) !?RootfsInputResolution {
    var indexed = (try rootfs_mod.cachedImageIndexedRootfs(init.io, allocator, cache_root, resolved)) orelse return null;
    const input = indexedImageRootfsInput(init, allocator, requested_ref, resolved, &indexed) catch |err| {
        rootfs_mod.deinitCachedIndexedRootfs(allocator, indexed);
        return .{ .failure = rootfsInputFailure(
            allocator,
            machine_output.fromZigError(err).code,
            command_name,
            "spore {s}: indexed image rootfs setup failed for {s}: {s}",
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

fn indexedImageRootfsInput(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    requested_ref: []const u8,
    resolved: rootfs_mod.ResolvedImage,
    indexed: *rootfs_mod.CachedIndexedRootfs,
) !ResolvedRootfsInput {
    const run_config = try readCachedImageRunConfig(init.io, allocator, indexed.metadata_path);

    const rootfs_device = spore.RootfsDevice{ .mmio_slot = 1 };
    indexed.storage.device = rootfs_device;
    const platform = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ resolved.platform.os, resolved.platform.arch.name() });
    const manifest_requested_ref = if (rootfs_mod.isLocalImageRef(requested_ref)) resolved.ref else requested_ref;
    allocator.free(indexed.metadata_path);
    indexed.metadata_path = &.{};
    return .{
        .path = null,
        .rootfs = .{
            .device = rootfs_device,
            .artifact = indexed.artifact,
            .storage = indexed.storage,
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
        .image_config = run_config.image_config,
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
    storage_prevalidated: bool,
) !ResolvedRootfsInput {
    const metadata_path = try rootfs_mod.cachedImageRootfsMetadataPath(allocator, cache_root, resolved);
    const run_config = try readCachedImageRunConfig(init.io, allocator, metadata_path);
    if (!record_artifact) return .{
        .path = rootfs_path,
        .guest_env = run_config.env,
        .guest_working_dir = run_config.working_dir,
        .image_config = run_config.image_config,
    };
    const rootfs_device = spore.RootfsDevice{ .mmio_slot = 1 };
    const artifact = (try rootfs_mod.cachedImageRootfsArtifact(init.io, allocator, metadata_path, rootfs_path)) orelse return error.BadManifest;
    errdefer allocator.free(artifact.digest);
    var storage = (try rootfs_mod.readCachedRootfsStorage(init.io, allocator, metadata_path, artifact)) orelse return error.BadManifest;
    errdefer rootfs_mod.deinitRootfsStorageDescriptor(allocator, storage);
    storage.device = rootfs_device;
    if (!storage_prevalidated and !try rootfs_cas.storageCompleteWithStampRepair(init.io, allocator, cache_root, storage)) return error.RootFSDigestCacheMiss;
    const platform = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ resolved.platform.os, resolved.platform.arch.name() });
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
        .image_config = run_config.image_config,
    };
}

const ImageRunConfig = struct {
    env: []const []const u8 = &.{},
    working_dir: ?[]const u8 = null,
    image_config: ?rootfs_mod.ImageConfig = null,
};

const CachedImageRunMetadata = struct {
    config: ?rootfs_mod.ImageConfig = null,
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

    const source_config = parsed.value.config orelse return .{};
    const image_config = try cloneImageConfig(allocator, source_config);
    const runtime = image_config.config orelse return .{ .image_config = image_config };
    return .{
        .env = runtime.Env orelse &.{},
        .working_dir = if (runtime.WorkingDir) |dir| if (dir.len == 0) null else dir else null,
        .image_config = image_config,
    };
}

fn cloneImageConfig(allocator: std.mem.Allocator, config: rootfs_mod.ImageConfig) !rootfs_mod.ImageConfig {
    return .{
        .architecture = config.architecture,
        .os = if (config.os) |value| try allocator.dupe(u8, value) else null,
        .config = if (config.config) |runtime| .{
            .Env = if (runtime.Env) |entries| try cloneStringListMutable(allocator, entries) else null,
            .Entrypoint = if (runtime.Entrypoint) |entries| try cloneStringListMutable(allocator, entries) else null,
            .Cmd = if (runtime.Cmd) |entries| try cloneStringListMutable(allocator, entries) else null,
            .WorkingDir = if (runtime.WorkingDir) |value| try allocator.dupe(u8, value) else null,
            .User = if (runtime.User) |value| try allocator.dupe(u8, value) else null,
        } else null,
    };
}

fn cloneStringListMutable(allocator: std.mem.Allocator, entries: []const []const u8) ![][]const u8 {
    const cloned = try allocator.alloc([]const u8, entries.len);
    for (entries, 0..) |entry, i| cloned[i] = try allocator.dupe(u8, entry);
    return cloned;
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

    return (try resolveManagedRunKernel(init, allocator)).path;
}

pub fn resolveConfiguredInitrdPath(init: std.process.Init, cli_path: ?[]const u8) !?[]const u8 {
    if (cli_path) |path| return path;
    if (init.environ_map.get("SPOREVM_RUN_INITRD")) |path| {
        if (!try readablePath(init.io, path)) return error.FileNotFound;
        return path;
    }
    return null;
}

const ManagedRunKernel = struct {
    path: []const u8,
    sha256: [Sha256.digest_length]u8,
};

fn resolveManagedRunKernel(init: std.process.Init, allocator: std.mem.Allocator) !ManagedRunKernel {
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

    if (try managedKernelCacheDigest(init.io, allocator, dest, sha_dest, config_dest, asset)) |digest| {
        try validateManagedKernelArchitectureDigest(digest);
        return .{ .path = dest, .sha256 = digest };
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
    const expected_digest = (try verifiedManagedKernelDigest(init.io, allocator, temp_image, temp_sha, asset)) orelse
        return error.ManagedKernelChecksumMismatch;
    try validateManagedKernelArchitectureDigest(expected_digest);
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
    return .{ .path = dest, .sha256 = expected_digest };
}

const ManagedKernelOptions = struct {
    repository: []const u8,
    release: []const u8,
    linux_version: []const u8,
};

fn managedKernelOptions(init: std.process.Init) ManagedKernelOptions {
    return .{
        .repository = init.environ_map.get("SPOREVM_KERNEL_REPOSITORY") orelse default_kernel_repository,
        .release = init.environ_map.get("SPOREVM_KERNEL_RELEASE") orelse defaultManagedKernelReleaseFor(builtin.cpu.arch),
        .linux_version = init.environ_map.get("SPOREVM_KERNEL_VERSION") orelse default_kernel_version,
    };
}

fn defaultManagedKernelReleaseFor(zig_arch: std.Target.Cpu.Arch) []const u8 {
    return if (zig_arch == .x86_64) default_x86_kernel_release else default_kernel_release;
}

fn managedRunKernelAssetName(allocator: std.mem.Allocator, linux_version: []const u8) ![]const u8 {
    return managedRunKernelAssetNameFor(allocator, builtin.cpu.arch, linux_version);
}

fn managedRunKernelAssetNameFor(allocator: std.mem.Allocator, zig_arch: std.Target.Cpu.Arch, linux_version: []const u8) ![]const u8 {
    try validateManagedKernelVersion(linux_version);
    if (zig_arch == .x86_64) {
        return std.fmt.allocPrint(allocator, "sporevm-x86_64-linux-{s}-bzImage", .{linux_version});
    }
    return std.fmt.allocPrint(allocator, "sporevm-arm64-linux-{s}-Image", .{linux_version});
}

fn validateManagedKernelArchitectureDigest(digest: [Sha256.digest_length]u8) !void {
    if (comptime builtin.cpu.arch == .x86_64) {
        if (!std.mem.eql(u8, &digest, &approved_x86_kernel_sha256)) return error.ManagedKernelArchitectureDigestMismatch;
    }
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

fn verifiedManagedKernelDigest(
    io: Io,
    allocator: std.mem.Allocator,
    image_path: []const u8,
    sha_path: []const u8,
    asset_name: []const u8,
) !?[Sha256.digest_length]u8 {
    if (!try rootfs_cache.regularFileNoSymlink(io, image_path)) return null;
    if (!try rootfs_cache.regularFileNoSymlink(io, sha_path)) return null;
    const expected = readExpectedSha256Digest(io, allocator, sha_path, asset_name, false) catch |err| switch (err) {
        error.BadManagedKernelChecksum => return null,
        else => |e| return e,
    };
    const actual = try sha256FileDigest(io, image_path);
    if (!std.mem.eql(u8, &expected, &actual)) return null;
    return expected;
}

fn managedKernelCacheDigest(
    io: Io,
    allocator: std.mem.Allocator,
    image_path: []const u8,
    sha_path: []const u8,
    config_path: []const u8,
    asset_name: []const u8,
) !?[Sha256.digest_length]u8 {
    if (!try readOnlyRegularFileNoSymlink(io, image_path)) return null;
    if (!try readOnlyRegularFileNoSymlink(io, sha_path)) return null;
    if (!try readOnlyRegularFileNoSymlink(io, config_path)) return null;

    const expected = readExpectedSha256Digest(io, allocator, sha_path, asset_name, true) catch |err| switch (err) {
        error.BadManagedKernelChecksum => return null,
        else => |e| return e,
    };

    // Managed kernel assets are verified against the release checksum before
    // being atomically installed read-only. Cache lookup reads only the small,
    // canonical checksum sidecar and config; an executor miss separately opens
    // the Image once, verifies those exact bytes, and boots the same allocation.
    // The config-symbol check stays because the required symbol list belongs to
    // the running binary, which may demand more than the installer did.
    if (!try managedRunKernelConfigHasRequiredSymbols(io, allocator, config_path)) return null;
    return expected;
}

fn managedKernelCacheHit(
    io: Io,
    allocator: std.mem.Allocator,
    image_path: []const u8,
    sha_path: []const u8,
    config_path: []const u8,
    asset_name: []const u8,
) !bool {
    return (try managedKernelCacheDigest(io, allocator, image_path, sha_path, config_path, asset_name)) != null;
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
    if (!try rootfs_cache.regularFileNoSymlink(io, config_path)) return error.ManagedKernelConfigMissing;
    const config = try Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(max_kernel_config_asset_size));
    defer allocator.free(config);
    return missingManagedRunKernelConfigSymbol(allocator, config);
}

fn missingManagedRunKernelConfigSymbol(allocator: std.mem.Allocator, config: []const u8) !?[]const u8 {
    return missingManagedRunKernelConfigSymbolFor(allocator, builtin.cpu.arch, config);
}

fn missingManagedRunKernelConfigSymbolFor(allocator: std.mem.Allocator, zig_arch: std.Target.Cpu.Arch, config: []const u8) !?[]const u8 {
    for (&managed_run_kernel_required_config_symbols) |symbol| {
        if (!kernelConfigHasBuiltin(config, symbol)) return try allocator.dupe(u8, symbol);
    }
    if (zig_arch == .x86_64) {
        for (&managed_x86_kernel_required_config_symbols) |symbol| {
            if (!kernelConfigHasBuiltin(config, symbol)) return try allocator.dupe(u8, symbol);
        }
        for (&managed_x86_kernel_forbidden_config_symbols) |symbol| {
            if (kernelConfigEnabled(config, symbol)) return try allocator.dupe(u8, symbol);
        }
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

fn kernelConfigEnabled(config: []const u8, symbol: []const u8) bool {
    var lines = std.mem.splitScalar(u8, config, '\n');
    while (lines.next()) |raw_line| {
        const line = if (std.mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
        if (line.len != symbol.len + 2 or !std.mem.startsWith(u8, line, symbol) or line[symbol.len] != '=') continue;
        return line[symbol.len + 1] == 'y' or line[symbol.len + 1] == 'm';
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

fn readExpectedSha256Digest(
    io: Io,
    allocator: std.mem.Allocator,
    sha_path: []const u8,
    asset_name: []const u8,
    require_read_only: bool,
) ![Sha256.digest_length]u8 {
    const bytes = try readRegularFileNoSymlinkAlloc(io, allocator, sha_path, 4096, require_read_only);
    defer allocator.free(bytes);
    var fields = std.mem.tokenizeAny(u8, bytes, " \t\r\n");
    const first = fields.next() orelse return error.BadManagedKernelChecksum;
    if (!isCanonicalSha256Hex(first)) return error.BadManagedKernelChecksum;
    if (fields.next()) |named_asset| {
        const normalized_name = if (std.mem.startsWith(u8, named_asset, "*")) named_asset[1..] else named_asset;
        if (!std.mem.eql(u8, normalized_name, asset_name)) return error.BadManagedKernelChecksum;
    }
    if (fields.next() != null) return error.BadManagedKernelChecksum;
    var digest: [Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, first) catch return error.BadManagedKernelChecksum;
    return digest;
}

fn readRegularFileNoSymlinkAlloc(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_size: usize,
    require_read_only: bool,
) ![]u8 {
    const pathz = try allocator.dupeZ(u8, path);
    defer allocator.free(pathz);
    const fd = std.c.open(pathz, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.ManagedKernelAssetOpenFailed;
    defer _ = std.c.close(fd);

    const file = Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    const stat = file.stat(io) catch return error.ManagedKernelAssetOpenFailed;
    if (stat.kind != .file) return error.ManagedKernelAssetOpenFailed;
    if (require_read_only and @intFromEnum(stat.permissions) & 0o222 != 0)
        return error.ManagedKernelCacheEntryWritable;
    if (stat.size > max_size) return error.ManagedKernelAssetTooLarge;
    const len: usize = @intCast(stat.size);
    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < len) {
        const n = std.c.read(fd, bytes[offset..].ptr, len - offset);
        if (n <= 0) return error.ManagedKernelAssetReadFailed;
        offset += @intCast(n);
    }
    var extra: [1]u8 = undefined;
    const trailing = std.c.read(fd, extra[0..].ptr, extra.len);
    if (trailing < 0) return error.ManagedKernelAssetReadFailed;
    if (trailing != 0) return error.ManagedKernelAssetChanged;
    return bytes;
}

fn isCanonicalSha256Hex(value: []const u8) bool {
    if (value.len != Sha256.digest_length * 2) return false;
    for (value) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

fn sha256FileDigest(io: Io, path: []const u8) ![Sha256.digest_length]u8 {
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
    return out;
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

fn loadRunInitrd(io: Io, allocator: std.mem.Allocator, path: ?[]const u8, injected_files: []const InjectedFile) ![]const u8 {
    try validateInjectedFiles(injected_files);
    if (path) |initrd_path| {
        const base = try std.Io.Dir.cwd().readFileAlloc(io, initrd_path, allocator, .limited(max_file_size));
        return try initrdWithInjectedFiles(allocator, base, injected_files);
    }
    return try initrdWithInjectedFiles(allocator, embedded_run_initrd, injected_files);
}

pub fn readInjectedFileSources(io: Io, allocator: std.mem.Allocator, files: []const InjectedFileSource) ![]const InjectedFile {
    if (files.len == 0) return &.{};
    const injected = try allocator.alloc(InjectedFile, files.len);
    var total: usize = 0;
    for (files, injected) |file, *out| {
        try validateInjectedFileId(file.id);
        if (file.path.len == 0) return error.BadInjectedFilePath;
        const remaining = max_injected_file_total_bytes -| total;
        const bytes = try readInjectedFileSource(allocator, io, file.path, remaining);
        total += bytes.len;
        if (total > max_injected_file_total_bytes) return error.InjectedFileTooLarge;
        out.* = .{ .id = file.id, .bytes = bytes };
    }
    try validateInjectedFiles(injected);
    return injected;
}

fn readInjectedFileSource(allocator: std.mem.Allocator, io: Io, path: []const u8, max_bytes: usize) ![]const u8 {
    const pathz = try allocator.dupeZ(u8, path);
    defer allocator.free(pathz);
    const fd = std.c.open(pathz, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.InjectedFileOpenFailed;
    defer _ = std.c.close(fd);

    const file = Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    const stat = file.stat(io) catch return error.InjectedFileOpenFailed;
    if (stat.kind != .file) return error.InjectedFileOpenFailed;
    if (stat.size > max_bytes) return error.InjectedFileTooLarge;
    const len: usize = @intCast(stat.size);
    const bytes = try allocator.alloc(u8, len);
    var off: usize = 0;
    while (off < len) {
        const n = std.c.read(fd, bytes[off..].ptr, len - off);
        if (n < 0) return error.InjectedFileOpenFailed;
        if (n == 0) return error.InjectedFileOpenFailed;
        off += @intCast(n);
    }
    return bytes;
}

fn initrdWithInjectedFiles(allocator: std.mem.Allocator, base: []const u8, injected_files: []const InjectedFile) ![]const u8 {
    if (injected_files.len == 0) return base;
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(base);
    try padCpio(&out);
    var ino: u32 = 0x5000;
    try appendCpioDir(&out, &ino, "run/sporevm");
    try appendCpioDir(&out, &ino, "run/sporevm/injected");
    for (injected_files) |file| {
        const path = try std.fmt.allocPrint(allocator, "run/sporevm/injected/{s}", .{file.id});
        defer allocator.free(path);
        try appendCpioFile(&out, &ino, path, file.bytes);
    }
    try appendCpioEntry(&out, &ino, "TRAILER!!!", 0, 1, "");
    return try out.toOwnedSlice();
}

fn appendCpioDir(out: *Io.Writer.Allocating, ino: *u32, name: []const u8) !void {
    try appendCpioEntry(out, ino, name, 0o040700, 2, "");
}

fn appendCpioFile(out: *Io.Writer.Allocating, ino: *u32, name: []const u8, bytes: []const u8) !void {
    try appendCpioEntry(out, ino, name, 0o100400, 1, bytes);
}

fn appendCpioEntry(out: *Io.Writer.Allocating, ino: *u32, name: []const u8, mode: u32, nlink: u32, bytes: []const u8) !void {
    ino.* += 1;
    try out.writer.print(
        "070701{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}",
        .{
            ino.*,
            mode,
            @as(u32, 0),
            @as(u32, 0),
            nlink,
            @as(u32, 0),
            @as(u32, @intCast(bytes.len)),
            @as(u32, 0),
            @as(u32, 0),
            @as(u32, 0),
            @as(u32, 0),
            @as(u32, @intCast(name.len + 1)),
            @as(u32, 0),
        },
    );
    try out.writer.writeAll(name);
    try out.writer.writeByte(0);
    try padCpio(out);
    try out.writer.writeAll(bytes);
    try padCpio(out);
}

fn padCpio(out: *Io.Writer.Allocating) !void {
    while (out.written().len % 4 != 0) try out.writer.writeByte(0);
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

const CommitControl = struct {
    io: Io,
    allocator: std.mem.Allocator,
    command_stream: *vsock.HostStream,
    guest_port: u32,
    timeout_ms: u64,
    cache_root: []const u8,
    rootfs_grow_target: u64,
    phase: Phase,
    resize_stream: vsock.HostStream = undefined,
    resize_stdout: std.array_list.Managed(u8),
    resize_stdout_overflow: bool = false,
    freeze_stream: vsock.HostStream = undefined,
    storage: ?spore.RootfsStorage = null,
    cache_lock: ?rootfs_mod.RootfsCacheLock = null,

    const Phase = enum {
        start_resize,
        active_resize,
        start_command,
        wait_command,
        start_freeze,
        active_freeze,
        snapshot,
        done,
    };

    fn deinit(self: *CommitControl) void {
        self.resize_stdout.deinit();
        if (self.cache_lock) |*lock| lock.deinit();
    }

    fn control(self: *CommitControl) vsock.Control {
        return .{
            .context = self,
            .pollFn = pollThunk,
            .setWakeFn = setWakeThunk,
            .completeSnapshotFn = completeSnapshotThunk,
            .completeRootfsSnapshotFn = completeRootfsSnapshotThunk,
            .reportStatsFn = reportStatsThunk,
        };
    }

    fn poll(self: *CommitControl, dev: *vsock.Vsock) !vsock.ControlAction {
        switch (self.phase) {
            .start_resize => {
                const request = try simpleControlRequest(self.allocator, "spore-rootfs-grow-v1", "spore-run-commit-resize");
                self.resize_stream = try vsock.HostStream.initWithProtocol(self.guest_port, request, .spore_stream_v1);
                self.resize_stream.host_port = vsock.HostStream.deriveHostPort(request);
                self.resize_stream.setOutputSink(self, resizeOutputSink);
                try self.startStream(dev, &self.resize_stream);
                self.phase = .active_resize;
                return .keep_running;
            },
            .active_resize => {
                _ = try dev.flushHostStreamOutbound();
                switch (self.resize_stream.state) {
                    .complete => {
                        const exit_code = self.resize_stream.exit_code orelse return error.BadRunExitFrame;
                        dev.resetHostStream();
                        if (exit_code != 0) return error.RunCommitGuestResizeFailed;
                        if (self.resize_stdout_overflow) return error.RunCommitGuestResizeFailed;
                        const result = parseRootfsGrowResponse(self.resize_stdout.items) catch return error.RunCommitGuestResizeFailed;
                        if (result.device_bytes != self.rootfs_grow_target) return error.RunCommitGuestResizeFailed;
                        self.phase = .start_command;
                    },
                    .failed => {
                        dev.resetHostStream();
                        return error.RunCommitGuestResizeFailed;
                    },
                    else => if (self.resize_stream.elapsedMs() > self.timeout_ms) {
                        dev.resetHostStream();
                        return error.RunCommitGuestResizeTimedOut;
                    },
                }
                return .keep_running;
            },
            .start_command => {
                try self.startStream(dev, self.command_stream);
                self.phase = .wait_command;
                return .keep_running;
            },
            .wait_command => {
                if (self.command_stream.state != .complete) return .keep_running;
                const exit_code = self.command_stream.exit_code orelse return error.BadRunExitFrame;
                self.phase = if (exit_code == 0) .start_freeze else .done;
                // The backend detaches the completed exec probe later in this
                // loop. Start the freeze stream on the following poll.
                return .keep_running;
            },
            .start_freeze => {
                const request = try simpleControlRequest(self.allocator, "fsfreeze-v1", "spore-run-commit-freeze");
                self.freeze_stream = try vsock.HostStream.initWithProtocol(self.guest_port, request, .spore_stream_v1);
                self.freeze_stream.host_port = vsock.HostStream.deriveHostPort(request);
                try dev.attachHostStream(&self.freeze_stream);
                self.freeze_stream.markStarted();
                _ = try dev.flushHostStreamOutbound();
                self.phase = .active_freeze;
                return .keep_running;
            },
            .active_freeze => {
                _ = try dev.flushHostStreamOutbound();
                switch (self.freeze_stream.state) {
                    .complete => {
                        const exit_code = self.freeze_stream.exit_code orelse return error.BadRunExitFrame;
                        dev.resetHostStream();
                        if (exit_code != 0) return error.RunCommitGuestFreezeFailed;
                        self.cache_lock = try rootfs_mod.lockRootfsCacheExclusive(self.io, self.allocator, self.cache_root);
                        self.phase = .snapshot;
                    },
                    .failed => {
                        dev.resetHostStream();
                        return error.RunCommitGuestFreezeFailed;
                    },
                    else => if (self.freeze_stream.elapsedMs() > self.timeout_ms) {
                        dev.resetHostStream();
                        return error.RunCommitGuestFreezeTimedOut;
                    },
                }
                return .keep_running;
            },
            .snapshot => return .{ .rootfs_snapshot = .{ .dir = self.cache_root } },
            .done => return .stop,
        }
    }

    fn startStream(_: *CommitControl, dev: *vsock.Vsock, stream: *vsock.HostStream) !void {
        try dev.attachHostStream(stream);
        stream.markStarted();
        _ = try dev.flushHostStreamOutbound();
    }

    fn resizeOutputSink(context: ?*anyopaque, output: vsock.HostStreamOutput, bytes: []const u8) void {
        if (output != .stdout) return;
        const self: *CommitControl = @ptrCast(@alignCast(context.?));
        const remaining = max_rootfs_grow_response -| self.resize_stdout.items.len;
        if (bytes.len > remaining) self.resize_stdout_overflow = true;
        const take = @min(remaining, bytes.len);
        if (take != 0) self.resize_stdout.appendSlice(bytes[0..take]) catch {
            self.resize_stdout_overflow = true;
        };
    }

    fn completeRootfsSnapshot(self: *CommitControl, maybe_disk: ?spore.Disk) !void {
        if (self.phase != .snapshot or self.cache_lock == null) return error.BadManifest;
        const disk = maybe_disk orelse return error.BadManifest;
        const storage = try runtime_disk_mod.storageFromSnapshotDisk(self.allocator, disk);
        try rootfs_cas.markStorageComplete(self.io, self.allocator, self.cache_root, storage.index_digest);
        self.storage = storage;
        self.phase = .done;
    }

    fn pollThunk(context: *anyopaque, dev: *vsock.Vsock) !vsock.ControlAction {
        const self: *CommitControl = @ptrCast(@alignCast(context));
        return self.poll(dev);
    }

    fn setWakeThunk(_: *anyopaque, _: vsock.Wake) void {}
    fn completeSnapshotThunk(_: *anyopaque, _: []const u8) !void {}

    fn completeRootfsSnapshotThunk(context: *anyopaque, disk: ?spore.Disk) !void {
        const self: *CommitControl = @ptrCast(@alignCast(context));
        try self.completeRootfsSnapshot(disk);
    }

    fn reportStatsThunk(_: *anyopaque, _: vsock.ControlStats) void {}
};

pub fn simpleControlRequest(allocator: std.mem.Allocator, request_type: []const u8, session_id: []const u8) ![]const u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .type = request_type,
        .session_id = session_id,
    }, .{});
    defer allocator.free(json);
    if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

pub fn execute(context: Context, allocator: std.mem.Allocator, opts: Options) !Result {
    var events = EventEmitter.init(opts.events, "run");
    try events.emitStart(opts.backend);
    errdefer |err| events.emitFailure(err) catch {};

    const setup_start = monotonicMs();
    try topology.validateVcpuCount(opts.vcpus);
    try spore.validateAnnotations(opts.annotations);
    if (opts.rootfs_grow_target != 0 and opts.commit == null) return error.InvalidRunDiskSize;
    if (opts.commit != null and (opts.resume_dir != null or opts.save_path != null or !opts.save_trigger.isExit() or opts.continue_after_save or opts.interactive or opts.tty or opts.command.len == 0)) return error.InvalidRunCommitOptions;
    if (opts.tty and opts.resume_dir != null and opts.command.len != 0) return error.TtyRunFromSporeUnsupported;
    if (opts.resume_dir != null and opts.command.len == 0) {
        try spore.validateSessionAttach(opts.resume_sessions, .{
            .id = opts.attach_session_id,
            .stdin = opts.interactive and !opts.tty,
            .terminal = opts.tty,
        });
    }

    const backend = try backend_mod.requireProductRunner(opts.backend);
    events.setBackend(backend);
    try validateFreshProductPolicy(backend, .{
        .memory = opts.memory,
        .vcpus = opts.vcpus,
        .resuming = opts.resume_dir != null,
        .capture = opts.save_path != null or !opts.save_trigger.isExit() or opts.continue_after_save or opts.commit != null,
        .rootfs = opts.rootfs_path != null or opts.rootfs != null or opts.disk != null or opts.rootfs_grow_target != 0,
        .network = opts.network != .disabled or opts.network_runtime != null,
        .build = opts.context_disk_path != null or opts.build_input_rootfs.len != 0 or opts.build_cache_disk_fd != null or opts.build_mode or opts.runtime_disk_head != null,
    });
    var gateway: net_gateway.Process = undefined;
    var gateway_active = false;
    if (opts.network == .spore) {
        try gateway.start(context.io, allocator, opts.spore_executable, opts.debug, opts.network_policy);
        gateway_active = true;
    }
    defer if (gateway_active) gateway.deinit();
    if (gateway_active) try events.emitPortForwards(&opts.network_policy);
    const network: virtio_net.Runtime = if (gateway_active) gateway.runtime() else .{};
    errdefer finishGatewayNetworkEvents(&gateway, &gateway_active, &events);
    const network_manifest = try manifestNetworkFromOptions(allocator, opts.network, &opts.network_policy);

    const resuming = opts.resume_dir != null;
    const memory_plan = runMemoryPlan(opts.memory, .{
        .fixed_ram = resuming or opts.save_path != null or opts.vcpus != 1,
        .auto_hotplug_capable = opts.auto_memory_hotplug_capable,
    });
    const local_backing_start = monotonicMs();
    var ram_plan = try ram_restore.Plan.fromSporeDir(allocator, context.environ_map, opts.resume_dir, memory_plan.boot_ram_size);
    const local_backing_ms = monotonicMs() -| local_backing_start;
    defer ram_plan.deinit();
    if (resuming) std.log.info("run --from memory restore source={s} reason={s}", .{ @tagName(ram_plan.restoreSource().?), @tagName(ram_plan.reason) });
    const kernel_start = monotonicMs();
    const kernel = if (resuming)
        ""
    else if (opts.boot_artifacts) |artifacts|
        artifacts.kernel
    else
        try std.Io.Dir.cwd().readFileAlloc(context.io, opts.kernel_path, allocator, .limited(max_file_size));
    const kernel_ms = monotonicMs() -| kernel_start;
    const initrd_start = monotonicMs();
    if (resuming and opts.injected_files.len != 0) return error.InjectedFileResumeUnsupported;
    if (opts.save_path != null and opts.injected_files.len != 0) return error.InjectedFileCaptureUnsupported;
    const initrd: ?[]const u8 = if (resuming)
        null
    else if (opts.boot_artifacts) |artifacts|
        if (opts.injected_files.len == 0) artifacts.initrd else try loadRunInitrd(context.io, allocator, opts.initrd_path, opts.injected_files)
    else
        try loadRunInitrd(context.io, allocator, opts.initrd_path, opts.injected_files);
    const initrd_ms = monotonicMs() -| initrd_start;
    const disk_start = monotonicMs();
    var runtime_disk = try runtime_disk_mod.open(context, allocator, .{
        .rootfs_path = opts.rootfs_path,
        .rootfs = opts.rootfs,
        .rootfs_grow_target = opts.rootfs_grow_target,
        .disk = opts.disk,
        .spore_dir = opts.resume_dir,
    });
    const disk_ms = monotonicMs() -| disk_start;
    defer runtime_disk.deinit();
    const growth_session = opts.rootfs_grow_target != 0;
    const noinit_itable = growth_session and rootfsGrowthNoInitItable(context.environ_map);
    const base_boot_args = if (resuming) "" else try cmdline(allocator, opts.guest_port, hasRootfs(opts), rootfsWritable(opts), growth_session, noinit_itable, opts.network, false, false, 0);
    const boot_args = if (resuming) "" else try productBootArgs(allocator, base_boot_args);
    const request_start = monotonicMs();
    const request = try execRequestForRun(context, allocator, opts, memory_plan.virtio_mem_region_size != 0);
    var stream = try vsock.HostStream.initWithProtocol(opts.guest_port, request.bytes, if (opts.interactive or opts.tty) .spore_stream_v1 else .legacy_text);
    const request_ms = monotonicMs() -| request_start;
    if (resuming) stream.host_port = vsock.HostStream.deriveHostPort(request.bytes);
    if (opts.events != null) {
        stream.setLifecycleSink(&events, runEventLifecycleSink);
        stream.setOutputSink(&events, runEventOutputSink);
    } else if (opts.stream_output) {
        stream.setOutputSink(null, runOutputSink);
    }
    var stdin_control = if (opts.interactive or opts.tty) attach_stream.RunStdinControl.init(&stream, opts.tty, opts.interactive, attach_stream.terminalSizeFd()) else null;
    if (stdin_control) |*control| try control.start(opts.tty and opts.interactive);
    defer if (stdin_control) |*control| control.deinit();
    const commit_cache_root = if (opts.commit != null)
        try local_paths.rootfsCacheRootPath(allocator, context.environ_map)
    else
        null;
    var commit_control: ?CommitControl = if (commit_cache_root) |cache_root| .{
        .io = context.io,
        .allocator = allocator,
        .command_stream = &stream,
        .guest_port = opts.guest_port,
        .timeout_ms = opts.timeout_ms,
        .cache_root = cache_root,
        .rootfs_grow_target = opts.rootfs_grow_target,
        .phase = if (opts.rootfs_grow_target != 0) .start_resize else .wait_command,
        .resize_stdout = std.array_list.Managed(u8).init(allocator),
    } else null;
    defer if (commit_control) |*control| control.deinit();
    if (commit_control != null and runtime_disk.snapshot() == null) return error.RunCommitRootfsNotSnapshotable;
    const exec_control = if (commit_control) |*control|
        control.control()
    else if (stdin_control) |*control|
        control.control()
    else
        null;
    var root_blk_stats: virtio_blk.Stats = .{};
    const root_blk_options = rootBlkOptions(context.environ_map, opts.rootfs_grow_target != 0, &root_blk_stats);
    defer if (opts.rootfs_grow_target != 0) logRootBlkStats(&root_blk_stats);
    var capture_request = capture.Request{};
    var signal_registration: ?capture.SignalRegistration = null;
    defer if (signal_registration) |*registration| registration.deinit();
    const capture_plan = capture.Plan.productRun(.{
        .capture_path = opts.save_path,
        .trigger = opts.save_trigger,
        .resume_dir = opts.resume_dir,
        .request = &capture_request,
        .continue_after_capture = opts.continue_after_save,
    });
    if (capture_plan.snapshot_dir) |snapshot_dir| {
        try spore.createSnapshotRoot(allocator, snapshot_dir);
    }
    var saved_session_buf: [1]spore.Session = undefined;
    const saved_sessions = if (request.attaches_existing and opts.resume_sessions.len != 0)
        opts.resume_sessions
    else blk: {
        saved_session_buf[0] = spore.processSession(request.session_id, opts.interactive, opts.tty);
        break :blk saved_session_buf[0..1];
    };
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
                .vcpus = opts.vcpus,
                .virtio_mem_region_size = memory_plan.virtio_mem_region_size,
                .cmdline = boot_args,
                .initrd = initrd,
                .console_sink = consoleSink,
                .disk_backend = runtime_disk.backend(),
                .root_blk_options = root_blk_options,
                .disk_snapshot = runtime_disk.snapshotWithMetrics(opts.disk_snapshot_metrics),
                .rootfs = opts.rootfs,
                .network_manifest = network_manifest,
                .annotations = opts.annotations,
                .sessions = saved_sessions,
                .resume_dir = opts.resume_dir,
                .resume_generation = opts.resume_generation,
                .ram_restore = ram_plan.strategy,
                .exec_probe = &stream,
                .exec_probe_start = if (opts.rootfs_grow_target != 0) .control else .immediate,
                .exec_probe_completes_run = opts.commit == null,
                .exec_control = exec_control,
                .exec_probe_timeout_ms = opts.timeout_ms,
                .snapshot_dir = capture_plan.snapshot_dir,
                .snapshot_on_probe_complete = capture_plan.snapshot_on_probe_complete,
                .capture_request = capture_plan.request,
                .continue_after_capture = capture_plan.continue_after_capture,
                .dirty_tracking = .{ .enabled = capture_plan.dirty_tracking.enabled and opts.vcpus == 1, .epoch_ms = capture_plan.dirty_tracking.epoch_ms },
                .network = network,
                .environ_map = context.environ_map,
            });
        },
        .kvm => blk: {
            if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .aarch64) {
                break :blk kvm.vm.run(allocator, .{
                    .kernel = kernel,
                    .ram_size = memory_plan.boot_ram_size,
                    .vcpus = opts.vcpus,
                    .virtio_mem_region_size = memory_plan.virtio_mem_region_size,
                    .cmdline = boot_args,
                    .initrd = initrd,
                    .console_sink = consoleSink,
                    .disk_backend = runtime_disk.backend(),
                    .root_blk_options = root_blk_options,
                    .disk_snapshot = runtime_disk.snapshotWithMetrics(opts.disk_snapshot_metrics),
                    .rootfs = opts.rootfs,
                    .network_manifest = network_manifest,
                    .annotations = opts.annotations,
                    .sessions = saved_sessions,
                    .resume_dir = opts.resume_dir,
                    .resume_generation = opts.resume_generation,
                    .ram_restore = ram_plan.strategy,
                    .exec_probe = &stream,
                    .exec_probe_start = if (opts.rootfs_grow_target != 0) .control else .immediate,
                    .exec_probe_completes_run = opts.commit == null,
                    .exec_control = exec_control,
                    .exec_probe_timeout_ms = opts.timeout_ms,
                    .snapshot_dir = capture_plan.snapshot_dir,
                    .snapshot_on_probe_complete = capture_plan.snapshot_on_probe_complete,
                    .capture_request = capture_plan.request,
                    .continue_after_capture = capture_plan.continue_after_capture,
                    .dirty_tracking = .{ .enabled = capture_plan.dirty_tracking.enabled, .epoch_ms = capture_plan.dirty_tracking.epoch_ms },
                    .network = network,
                    .environ_map = context.environ_map,
                });
            }
            if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
                break :blk x86_vm.run(allocator, .{
                    .kernel = kernel,
                    .ram_size = memory_plan.boot_ram_size,
                    .vcpu_count = @intCast(opts.vcpus),
                    .cmdline = boot_args,
                    .initrd = initrd,
                    .console_sink = consoleSink,
                    .root_disk = runtime_disk.backend(),
                    .network = network,
                    .exec_probe = &stream,
                    .exec_control = exec_control,
                    .exec_probe_timeout_ms = opts.timeout_ms,
                });
            }
            return error.UnsupportedBackend;
        },
    }) catch |err| {
        if ((opts.interactive or opts.tty) and err == error.VsockProbeFailed) return error.InteractiveStreamProtocolFailed;
        if (capture_plan.isSignalCapture() and capture_request.isCompleted() and isCaptureAborted(err)) {
            var result = resultFromAbortedSignalCapture(backend, opts, &stream);
            if (resuming) result = result.withMemoryRestore(&ram_plan);
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
        .monitor_stopped => if (opts.commit != null)
            resultFromStream(backend, opts, &stream, false)
        else
            error.ProbeDidNotComplete,
        .snapshotted => if (capture_plan.isExitCapture())
            resultFromExitCapture(backend, opts, &stream)
        else
            resultFromSignalCapture(backend, opts, &stream),
        else => error.ProbeDidNotComplete,
    };
    if (opts.commit) |commit| {
        if (result.exit_code == 0) {
            const control = if (commit_control) |*value| value else return error.RunCommitDidNotComplete;
            const storage = control.storage orelse return error.RunCommitDidNotComplete;
            if (control.cache_lock == null) return error.RunCommitDidNotComplete;
            const published = try rootfs_mod.publishIndexedImageWithCacheLockHeld(context.io, allocator, control.cache_root, .{
                .ref = commit.ref,
                .platform = commit.platform,
                .config = commit.config,
                .rootfs_storage = storage,
            });
            events.emitImageCommitBestEffort(.{
                .command = "run",
                .backend = backend,
                .ref = commit.ref,
                .resolved_image_ref = published.resolved_image_ref,
                .rootfs_index_digest = published.rootfs_storage.index_digest,
            });
            result.committed = true;
        }
    }
    if (resuming) result = result.withMemoryRestore(&ram_plan);
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

pub const MonitorBootArtifacts = struct {
    kernel: []const u8,
    initrd: []const u8,
};

/// Identity-only view of the managed default boot producer. Resolving it reads
/// the bounded checksum/config metadata but deliberately does not read the
/// kernel Image. The Image is opened exactly once if an executor miss needs to
/// boot, then the same verified allocation is passed to the VMM.
pub const ManagedMonitorBootDescriptor = struct {
    kernel_path: []const u8,
    kernel_sha256: [Sha256.digest_length]u8,
    initrd_sha256: [Sha256.digest_length]u8,
};

pub fn resolveManagedMonitorBootDescriptor(
    init: std.process.Init,
    allocator: std.mem.Allocator,
) !ManagedMonitorBootDescriptor {
    if (init.environ_map.get("SPOREVM_KERNEL_IMAGE") != null or
        init.environ_map.get("SPOREVM_RUN_INITRD") != null)
    {
        return error.CustomBootArtifactsConfigured;
    }
    const kernel = try resolveManagedRunKernel(init, allocator);
    return .{
        .kernel_path = kernel.path,
        .kernel_sha256 = kernel.sha256,
        .initrd_sha256 = embedded_run_initrd_sha256,
    };
}

pub fn materializeManagedMonitorBootArtifacts(
    io: Io,
    allocator: std.mem.Allocator,
    descriptor: ManagedMonitorBootDescriptor,
) !MonitorBootArtifacts {
    if (!std.mem.eql(u8, &descriptor.initrd_sha256, &embedded_run_initrd_sha256))
        return error.ManagedInitrdIdentityMismatch;
    const kernel = try readRegularFileNoSymlinkAlloc(io, allocator, descriptor.kernel_path, max_file_size, true);
    errdefer allocator.free(kernel);
    var actual: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(kernel, &actual, .{});
    if (!std.mem.eql(u8, &descriptor.kernel_sha256, &actual))
        return error.ManagedKernelChecksumMismatch;
    return .{ .kernel = kernel, .initrd = embedded_run_initrd };
}

pub fn loadMonitorBootArtifacts(
    io: Io,
    allocator: std.mem.Allocator,
    kernel_path: []const u8,
    initrd_path: ?[]const u8,
) !MonitorBootArtifacts {
    return .{
        .kernel = try std.Io.Dir.cwd().readFileAlloc(io, kernel_path, allocator, .limited(max_file_size)),
        .initrd = try loadRunInitrd(io, allocator, initrd_path, &.{}),
    };
}

pub fn executeMonitor(context: Context, allocator: std.mem.Allocator, opts: Options, control: vsock.Control, startup_probe: ?*vsock.HostStream) !MonitorResult {
    _ = try backend_mod.requireProductRunner(opts.backend);
    const artifacts = try loadMonitorBootArtifacts(context.io, allocator, opts.kernel_path, opts.initrd_path);
    return executeMonitorWithBootArtifacts(context, allocator, opts, artifacts, control, startup_probe);
}

pub fn executeMonitorWithRootfsCacheLock(
    context: Context,
    allocator: std.mem.Allocator,
    opts: Options,
    control: vsock.Control,
    startup_probe: ?*vsock.HostStream,
    rootfs_cache_lock: *const rootfs_mod.RootfsCacheLock,
) !MonitorResult {
    _ = try backend_mod.requireProductRunner(opts.backend);
    const artifacts = try loadMonitorBootArtifacts(context.io, allocator, opts.kernel_path, opts.initrd_path);
    return executeMonitorWithOptionalRootfsCacheLock(context, allocator, opts, artifacts, control, startup_probe, rootfs_cache_lock);
}

pub fn executeMonitorWithBootArtifacts(
    context: Context,
    allocator: std.mem.Allocator,
    opts: Options,
    artifacts: MonitorBootArtifacts,
    control: vsock.Control,
    startup_probe: ?*vsock.HostStream,
) !MonitorResult {
    return executeMonitorWithOptionalRootfsCacheLock(context, allocator, opts, artifacts, control, startup_probe, null);
}

pub fn executeMonitorWithBootArtifactsAndRootfsCacheLock(
    context: Context,
    allocator: std.mem.Allocator,
    opts: Options,
    artifacts: MonitorBootArtifacts,
    control: vsock.Control,
    startup_probe: ?*vsock.HostStream,
    rootfs_cache_lock: *const rootfs_mod.RootfsCacheLock,
) !MonitorResult {
    return executeMonitorWithOptionalRootfsCacheLock(context, allocator, opts, artifacts, control, startup_probe, rootfs_cache_lock);
}

fn executeMonitorWithOptionalRootfsCacheLock(
    context: Context,
    allocator: std.mem.Allocator,
    opts: Options,
    artifacts: MonitorBootArtifacts,
    control: vsock.Control,
    startup_probe: ?*vsock.HostStream,
    rootfs_cache_lock: ?*const rootfs_mod.RootfsCacheLock,
) !MonitorResult {
    try topology.validateVcpuCount(opts.vcpus);
    try spore.validateAnnotations(opts.annotations);

    const backend = try backend_mod.requireProductRunner(opts.backend);
    try validateFreshProductPolicy(backend, .{
        .memory = opts.memory,
        .vcpus = opts.vcpus,
        .resuming = opts.resume_dir != null or opts.resume_generation != null or opts.resume_sessions.len != 0,
        .rootfs = opts.rootfs_path != null or opts.rootfs != null or opts.disk != null or opts.rootfs_grow_target != 0,
        .network = opts.network != .disabled or opts.network_runtime != null,
        .build = opts.context_disk_path != null or opts.build_input_rootfs.len != 0 or opts.build_cache_disk_fd != null or opts.build_mode or opts.runtime_disk_head != null,
    });
    var ram_plan = try ram_restore.Plan.fromSporeDir(allocator, context.environ_map, opts.resume_dir, opts.memory.bytes);
    defer ram_plan.deinit();
    if (opts.resume_dir != null) std.log.info("named monitor memory restore source={s} reason={s}", .{ @tagName(ram_plan.restoreSource().?), @tagName(ram_plan.reason) });
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
    if (opts.injected_files.len != 0) return error.InjectedFileMonitorUnsupported;
    var runtime_disk = try runtime_disk_mod.open(context, allocator, .{
        .rootfs_path = opts.rootfs_path,
        .rootfs = opts.rootfs,
        .rootfs_grow_target = opts.rootfs_grow_target,
        .rootfs_cache_lock = rootfs_cache_lock,
        .disk = opts.disk,
        .spore_dir = opts.resume_dir,
        .disk_root = opts.disk_root,
    });
    defer runtime_disk.deinit();
    if (opts.runtime_disk_head) |head| try runtime_disk.adoptForkHead(head);
    const context_disk_fd = if (opts.context_disk_path) |path| try openReadOnlyDiskFd(context.io, allocator, path) else null;
    defer if (context_disk_fd) |fd| {
        _ = std.c.close(fd);
    };
    const build_input_disks = try allocator.alloc(runtime_disk_mod.RuntimeDisk, opts.build_input_rootfs.len);
    defer allocator.free(build_input_disks);
    var build_input_count: usize = 0;
    defer {
        for (build_input_disks[0..build_input_count]) |*disk| disk.deinit();
    }
    for (opts.build_input_rootfs, 0..) |input_rootfs, index| {
        build_input_disks[index] = try runtime_disk_mod.openReadOnlyRootfs(context, allocator, input_rootfs, opts.disk_root, rootfs_cache_lock);
        build_input_count += 1;
    }
    const build_input_backends = try allocator.alloc(virtio_blk.Backend, build_input_disks.len);
    defer allocator.free(build_input_backends);
    for (build_input_disks, 0..) |*disk, index| build_input_backends[index] = disk.backend() orelse return error.BadManifest;
    const growth_session = opts.rootfs_grow_target != 0;
    const noinit_itable = growth_session and rootfsGrowthNoInitItable(context.environ_map);
    const base_boot_args = try cmdline(allocator, opts.guest_port, hasRootfs(opts), rootfsWritable(opts), growth_session, noinit_itable, opts.network, opts.context_disk_path != null, opts.build_mode, build_input_disks.len);
    const boot_args = try productBootArgs(allocator, base_boot_args);
    var root_blk_stats: virtio_blk.Stats = .{};
    const root_blk_options = rootBlkOptions(context.environ_map, opts.rootfs_grow_target != 0, &root_blk_stats);
    defer if (opts.rootfs_grow_target != 0) logRootBlkStats(&root_blk_stats);

    const cause = switch (backend) {
        .auto => unreachable,
        .hvf => blk: {
            if (comptime !(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) return error.UnsupportedBackend;
            break :blk try hvf.vm.run(allocator, .{
                .kernel = artifacts.kernel,
                .ram_size = opts.memory.bytes,
                .vcpus = opts.vcpus,
                .cmdline = boot_args,
                .initrd = artifacts.initrd,
                .console_sink = consoleSink,
                .disk_backend = runtime_disk.backend(),
                .root_blk_options = root_blk_options,
                .context_disk_fd = context_disk_fd,
                .build_input_disk_backends = build_input_backends,
                .build_cache_disk_backend = if (opts.build_cache_disk_fd) |fd| .{ .file = fd } else null,
                .disk_snapshot = runtime_disk.snapshotWithMetrics(opts.disk_snapshot_metrics),
                .rootfs = opts.rootfs,
                .network_manifest = network_manifest,
                .annotations = opts.annotations,
                .sessions = opts.resume_sessions,
                .resume_dir = opts.resume_dir,
                .resume_generation = opts.resume_generation,
                .ram_restore = ram_plan.strategy,
                .exec_probe = startup_probe,
                .exec_probe_timeout_ms = opts.timeout_ms,
                .exec_probe_completes_run = false,
                .exec_control = control,
                .network = network,
                .environ_map = context.environ_map,
            });
        },
        .kvm => blk: {
            if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .aarch64) {
                break :blk try kvm.vm.run(allocator, .{
                    .kernel = artifacts.kernel,
                    .ram_size = opts.memory.bytes,
                    .vcpus = opts.vcpus,
                    .cmdline = boot_args,
                    .initrd = artifacts.initrd,
                    .console_sink = consoleSink,
                    .disk_backend = runtime_disk.backend(),
                    .root_blk_options = root_blk_options,
                    .context_disk_fd = context_disk_fd,
                    .build_input_disk_backends = build_input_backends,
                    .build_cache_disk_backend = if (opts.build_cache_disk_fd) |fd| .{ .file = fd } else null,
                    .disk_snapshot = runtime_disk.snapshotWithMetrics(opts.disk_snapshot_metrics),
                    .rootfs = opts.rootfs,
                    .network_manifest = network_manifest,
                    .annotations = opts.annotations,
                    .sessions = opts.resume_sessions,
                    .resume_dir = opts.resume_dir,
                    .resume_generation = opts.resume_generation,
                    .ram_restore = ram_plan.strategy,
                    .exec_probe = startup_probe,
                    .exec_probe_timeout_ms = opts.timeout_ms,
                    .exec_probe_completes_run = false,
                    .exec_control = control,
                    .network = network,
                    .environ_map = context.environ_map,
                });
            }
            if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
                break :blk try x86_vm.run(allocator, .{
                    .kernel = artifacts.kernel,
                    .ram_size = opts.memory.bytes,
                    .vcpu_count = @intCast(opts.vcpus),
                    .cmdline = boot_args,
                    .initrd = artifacts.initrd,
                    .console_sink = consoleSink,
                    .root_disk = runtime_disk.backend(),
                    .network = network,
                    .exec_probe = startup_probe,
                    .exec_probe_completes_run = false,
                    .exec_control = control,
                    .exec_probe_timeout_ms = opts.timeout_ms,
                });
            }
            return error.UnsupportedBackend;
        },
    };
    if (network.failed()) return error.NetworkGatewayFailed;
    return switch (cause) {
        .monitor_stopped => .{ .backend = backend, .exit = .stopped },
        .snapshotted => .{ .backend = backend, .exit = .snapshotted },
        else => error.MonitorDidNotStopCleanly,
    };
}

fn openReadOnlyDiskFd(io: Io, allocator: std.mem.Allocator, path: []const u8) !std.c.fd_t {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.ContextDiskOpenFailed;
    errdefer _ = std.c.close(fd);
    const file = Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    const stat = file.stat(io) catch return error.ContextDiskOpenFailed;
    if (stat.kind != .file) return error.ContextDiskOpenFailed;
    return fd;
}

pub var console_fd: std.c.fd_t = -1;

fn runOutputSink(_: ?*anyopaque, output: vsock.HostStreamOutput, bytes: []const u8) void {
    const fd: std.c.fd_t = switch (output) {
        .stdout => 1,
        .stderr => 2,
        .terminal => 1,
    };
    fd_util.writeAllBestEffort(fd, bytes);
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
    fd_util.writeAllBestEffort(console_fd, bytes);
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
    return execRequestWithSession(allocator, argv, "default", 0);
}

const RunRequestInfo = struct {
    bytes: []const u8,
    session_id: []const u8,
    attaches_existing: bool = false,
};

fn execRequestForRun(context: Context, allocator: std.mem.Allocator, opts: Options, memory_pressure: bool) !RunRequestInfo {
    const resume_time_unix_ns: u64 = @intCast(Io.Clock.real.now(context.io).nanoseconds);
    if (opts.resume_dir != null and opts.command.len == 0) {
        if (opts.interactive or opts.tty) {
            return .{
                .bytes = try attach_stream.attachV1Request(allocator, .{
                    .session_id = opts.attach_session_id,
                    .interactive = opts.interactive,
                    .tty = opts.tty,
                    .terminal_name = attach_stream.terminalName(context.environ_map),
                    .terminal_size = attach_stream.terminalSizeOrDefault(attach_stream.terminalSizeFd()),
                }),
                .session_id = opts.attach_session_id,
                .attaches_existing = true,
            };
        }
        return .{
            .bytes = try attach_stream.attachRequest(allocator, opts.attach_session_id),
            .session_id = opts.attach_session_id,
            .attaches_existing = true,
        };
    }
    if (opts.resume_dir == null) return .{
        .bytes = try execRequestWithSessionOptions(allocator, opts.command, spore.default_session_id, .{
            .env = opts.guest_env,
            .working_dir = opts.guest_working_dir,
            .resume_time_unix_ns = resume_time_unix_ns,
            .memory_pressure = memory_pressure,
            .interactive = opts.interactive,
            .tty = opts.tty,
            .terminal_name = attach_stream.terminalName(context.environ_map),
            .terminal_size = attach_stream.terminalSizeOrDefault(attach_stream.terminalSizeFd()),
        }),
        .session_id = spore.default_session_id,
    };

    const session_id = try randomRunSessionId(context, allocator);
    return .{
        .bytes = try execRequestWithSessionOptions(allocator, opts.command, session_id, .{
            .env = opts.guest_env,
            .resume_time_unix_ns = resume_time_unix_ns,
            .memory_pressure = memory_pressure,
            .interactive = opts.interactive,
            .tty = opts.tty,
            .terminal_name = attach_stream.terminalName(context.environ_map),
            .terminal_size = attach_stream.terminalSizeOrDefault(attach_stream.terminalSizeFd()),
            .generation_params = opts.start_generation_params,
            .require_generation_ready = opts.require_generation_ready,
        }),
        .session_id = session_id,
    };
}

fn randomRunSessionId(context: Context, allocator: std.mem.Allocator) ![]const u8 {
    const now = Io.Clock.real.now(context.io).nanoseconds;
    var nonce_bytes: [8]u8 = undefined;
    context.io.random(&nonce_bytes);
    const nonce = std.mem.readInt(u64, &nonce_bytes, .little);
    return std.fmt.allocPrint(allocator, "run-{x}-{x}", .{ now, nonce });
}

pub fn execRequestWithSession(allocator: std.mem.Allocator, argv: []const []const u8, session_id: []const u8, resume_time_unix_ns: u64) ![]const u8 {
    return execRequestWithSessionOptions(allocator, argv, session_id, .{
        .resume_time_unix_ns = resume_time_unix_ns,
    });
}

pub const ExecRequestContextOptions = struct {
    env: []const []const u8 = &.{},
    working_dir: ?[]const u8 = null,
    resume_time_unix_ns: u64 = 0,
    generation_params: ?[]const u8 = null,
};

pub fn execRequestWithSessionContext(allocator: std.mem.Allocator, argv: []const []const u8, session_id: []const u8, options: ExecRequestContextOptions) ![]const u8 {
    return execRequestWithSessionOptions(allocator, argv, session_id, .{
        .env = options.env,
        .working_dir = options.working_dir,
        .resume_time_unix_ns = options.resume_time_unix_ns,
        .generation_params = options.generation_params,
    });
}

pub fn execRequestWithSessionGenerationParams(allocator: std.mem.Allocator, argv: []const []const u8, session_id: []const u8, resume_time_unix_ns: u64, generation_params: []const u8) ![]const u8 {
    return execRequestWithSessionOptions(allocator, argv, session_id, .{
        .resume_time_unix_ns = resume_time_unix_ns,
        .generation_params = generation_params,
    });
}

pub const InteractiveExecRequestOptions = struct {
    env: []const []const u8 = &.{},
    working_dir: ?[]const u8 = null,
    interactive: bool = false,
    tty: bool = false,
    terminal_name: []const u8 = "xterm",
    terminal_size: spore_stream.Resize = .{ .rows = 24, .cols = 80 },
    resume_time_unix_ns: u64 = 0,
};

pub fn interactiveExecRequestWithSession(allocator: std.mem.Allocator, argv: []const []const u8, session_id: []const u8, options: InteractiveExecRequestOptions) ![]const u8 {
    const exec_options = GuestExecOptions{
        .env = options.env,
        .working_dir = options.working_dir,
        .interactive = options.interactive,
        .tty = options.tty,
        .terminal_name = options.terminal_name,
        .terminal_size = options.terminal_size,
        .resume_time_unix_ns = options.resume_time_unix_ns,
    };
    try validateGuestArgv(argv);
    try validateGuestExecOptions(exec_options);
    return execV1RequestWithSessionOptions(allocator, argv, session_id, exec_options);
}

pub fn detachedExecRequestWithSession(allocator: std.mem.Allocator, argv: []const []const u8, session_id: []const u8, resume_time_unix_ns: u64) ![]const u8 {
    return detachedExecRequestWithSessionContext(allocator, argv, session_id, .{
        .resume_time_unix_ns = resume_time_unix_ns,
    });
}

pub fn detachedExecRequestWithSessionContext(allocator: std.mem.Allocator, argv: []const []const u8, session_id: []const u8, options: ExecRequestContextOptions) ![]const u8 {
    try validateGuestArgv(argv);
    try validateGuestExecContext(options.env, options.working_dir);
    const payload = struct {
        type: []const u8 = "start",
        session_id: []const u8,
        resume_time_unix_ns: u64,
        argv: []const []const u8,
        env: []const []const u8,
        working_dir: []const u8,
        memory_pressure: bool = false,
        detached: bool = true,
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

const GuestExecOptions = struct {
    env: []const []const u8 = &.{},
    working_dir: ?[]const u8 = null,
    resume_time_unix_ns: u64 = 0,
    memory_pressure: bool = false,
    interactive: bool = false,
    tty: bool = false,
    terminal_name: []const u8 = "xterm",
    terminal_size: spore_stream.Resize = .{ .rows = 24, .cols = 80 },
    generation_params: ?[]const u8 = null,
    require_generation_ready: bool = false,
};

fn execRequestWithSessionOptions(allocator: std.mem.Allocator, argv: []const []const u8, session_id: []const u8, options: GuestExecOptions) ![]const u8 {
    try validateGuestArgv(argv);
    try validateGuestExecOptions(options);
    if (options.interactive or options.tty) return execV1RequestWithSessionOptions(allocator, argv, session_id, options);
    const working_dir = options.working_dir orelse "";

    const payload = struct {
        type: []const u8 = "start",
        session_id: []const u8,
        resume_time_unix_ns: u64,
        argv: []const []const u8,
        env: []const []const u8,
        working_dir: []const u8,
        memory_pressure: bool,
        params_json: []const u8,
        require_generation_ready: bool,
        closed_env: bool = true,
    }{
        .session_id = session_id,
        .resume_time_unix_ns = options.resume_time_unix_ns,
        .argv = argv,
        .env = options.env,
        .working_dir = working_dir,
        .memory_pressure = options.memory_pressure,
        .params_json = options.generation_params orelse "",
        .require_generation_ready = options.require_generation_ready,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

fn execV1RequestWithSessionOptions(allocator: std.mem.Allocator, argv: []const []const u8, session_id: []const u8, options: GuestExecOptions) ![]const u8 {
    const payload = struct {
        type: []const u8 = "start-v1",
        session_id: []const u8,
        resume_time_unix_ns: u64,
        argv: []const []const u8,
        env: []const []const u8,
        working_dir: []const u8,
        stdio: []const u8,
        term: []const u8,
        terminal_rows: u16,
        terminal_cols: u16,
        memory_pressure: bool,
        params_json: []const u8,
        require_generation_ready: bool,
        closed_env: bool = true,
    }{
        .session_id = session_id,
        .resume_time_unix_ns = options.resume_time_unix_ns,
        .argv = argv,
        .env = options.env,
        .working_dir = options.working_dir orelse "",
        .stdio = if (options.tty) "tty" else "pipe",
        .term = options.terminal_name,
        .terminal_rows = options.terminal_size.rows,
        .terminal_cols = options.terminal_size.cols,
        .memory_pressure = options.memory_pressure,
        .params_json = options.generation_params orelse "",
        .require_generation_ready = options.require_generation_ready,
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

fn hasRootfs(opts: Options) bool {
    return opts.rootfs_path != null or opts.rootfs != null;
}

pub fn rootfsGrowTarget(current_size: u64, requested_size: u64) !u64 {
    if (requested_size < current_size) return error.RunDiskSizeWouldShrink;
    return if (requested_size == current_size) 0 else requested_size;
}

pub const max_rootfs_grow_response: usize = 1024;

pub const RootfsGrowResult = struct {
    device_bytes: u64,
    block_size: u64,
    target_blocks: u64,
    before_blocks: u64,
    filesystem_blocks: u64,
    blocks_per_group: u32,
    usable_blocks: u64,
    free_bytes: u64,
    inodes: u64,
    free_inodes: u64,
};

pub fn parseRootfsGrowResponse(bytes: []const u8) !RootfsGrowResult {
    if (bytes.len == 0 or bytes.len > max_rootfs_grow_response) return error.BadRootfsGrowResponse;
    if (!std.mem.endsWith(u8, bytes, "\n") or std.mem.count(u8, bytes, "\n") != 1) return error.BadRootfsGrowResponse;
    const line = bytes[0 .. bytes.len - 1];
    if (std.mem.indexOfScalar(u8, line, '\r') != null) return error.BadRootfsGrowResponse;

    var tokens = std.mem.splitScalar(u8, line, ' ');
    if (!std.mem.eql(u8, tokens.next() orelse return error.BadRootfsGrowResponse, "spore-rootfs-grow-v1")) return error.BadRootfsGrowResponse;
    const device_bytes = try parseRootfsGrowField(tokens.next(), "device_bytes");
    const block_size = try parseRootfsGrowField(tokens.next(), "block_size");
    const target_blocks = try parseRootfsGrowField(tokens.next(), "target_blocks");
    const before_blocks = try parseRootfsGrowField(tokens.next(), "before_blocks");
    const filesystem_blocks = try parseRootfsGrowField(tokens.next(), "filesystem_blocks");
    const blocks_per_group_raw = try parseRootfsGrowField(tokens.next(), "blocks_per_group");
    const usable_blocks = try parseRootfsGrowField(tokens.next(), "usable_blocks");
    const free_bytes = try parseRootfsGrowField(tokens.next(), "free_bytes");
    const inodes = try parseRootfsGrowField(tokens.next(), "inodes");
    const free_inodes = try parseRootfsGrowField(tokens.next(), "free_inodes");
    if (tokens.next() != null) return error.BadRootfsGrowResponse;

    if (device_bytes == 0 or block_size == 0 or device_bytes % block_size != 0) return error.BadRootfsGrowResponse;
    if (target_blocks != device_bytes / block_size) return error.BadRootfsGrowResponse;
    const blocks_per_group = std.math.cast(u32, blocks_per_group_raw) orelse return error.BadRootfsGrowResponse;
    if (before_blocks == 0 or before_blocks >= filesystem_blocks or filesystem_blocks > target_blocks or blocks_per_group == 0) return error.BadRootfsGrowResponse;
    if (target_blocks - filesystem_blocks >= blocks_per_group) return error.BadRootfsGrowResponse;
    if (usable_blocks == 0 or usable_blocks > filesystem_blocks or inodes == 0) return error.BadRootfsGrowResponse;
    const usable_bytes = std.math.mul(u64, usable_blocks, block_size) catch return error.BadRootfsGrowResponse;
    if (free_bytes > usable_bytes or free_bytes % block_size != 0 or free_inodes > inodes) return error.BadRootfsGrowResponse;
    return .{
        .device_bytes = device_bytes,
        .block_size = block_size,
        .target_blocks = target_blocks,
        .before_blocks = before_blocks,
        .filesystem_blocks = filesystem_blocks,
        .blocks_per_group = blocks_per_group,
        .usable_blocks = usable_blocks,
        .free_bytes = free_bytes,
        .inodes = inodes,
        .free_inodes = free_inodes,
    };
}

fn parseRootfsGrowField(maybe_token: ?[]const u8, expected_name: []const u8) !u64 {
    const token = maybe_token orelse return error.BadRootfsGrowResponse;
    if (token.len <= expected_name.len + 1 or !std.mem.startsWith(u8, token, expected_name) or token[expected_name.len] != '=') {
        return error.BadRootfsGrowResponse;
    }
    return std.fmt.parseUnsigned(u64, token[expected_name.len + 1 ..], 10) catch error.BadRootfsGrowResponse;
}

fn rootBlkOptions(environ: *const std.process.Environ.Map, growth_session: bool, stats: *virtio_blk.Stats) virtio_blk.Options {
    if (!growth_session) return .{};
    const experiments_enabled = rootfsGrowthExperimentsEnabled(environ);
    return .{
        .write_zeroes = true,
        .force_write_zeroes_unsupported = experiments_enabled and internalExperimentEnabled(environ.get(force_write_zeroes_unsupported_experiment_env)),
        .force_write_zeroes_backend_failure = experiments_enabled and internalExperimentEnabled(environ.get(force_write_zeroes_backend_failure_experiment_env)),
        .stats = stats,
    };
}

pub fn rootfsGrowthExperimentsEnabled(environ: *const std.process.Environ.Map) bool {
    return if (environ.get(rootfs_growth_experiments_env)) |value|
        std.mem.eql(u8, value, "1")
    else
        false;
}

fn internalExperimentEnabled(value: ?[]const u8) bool {
    const raw = value orelse return false;
    if (raw.len == 0 or std.mem.eql(u8, raw, "0")) return false;
    return !std.ascii.eqlIgnoreCase(raw, "false");
}

pub fn rootfsGrowthNoInitItable(environ: *const std.process.Environ.Map) bool {
    return !rootfsGrowthExperimentsEnabled(environ) or
        !internalExperimentEnabled(environ.get(lazy_init_negative_control_experiment_env));
}

fn logRootBlkStats(stats: *const virtio_blk.Stats) void {
    const snapshot = stats.snapshot();
    std.log.info(
        "rootfs growth blk metrics: accepted_features=0x{x} write_zeroes_requests={d} write_zeroes_bytes={d} write_zeroes_unmap={d} write_zeroes_ok={d} write_zeroes_errors={d} write_zeroes_backend_failures={d} write_zeroes_unsupported={d} out_requests={d} out_bytes={d} out_all_zero_requests={d} out_all_zero_bytes={d}",
        .{
            snapshot.accepted_features,
            snapshot.write_zeroes_requests,
            snapshot.write_zeroes_bytes,
            snapshot.write_zeroes_unmap_requests,
            snapshot.write_zeroes_ok,
            snapshot.write_zeroes_errors,
            snapshot.write_zeroes_backend_failures,
            snapshot.write_zeroes_unsupported,
            snapshot.out_requests,
            snapshot.out_bytes,
            snapshot.out_all_zero_requests,
            snapshot.out_all_zero_bytes,
        },
    );
}

pub fn cmdline(allocator: std.mem.Allocator, guest_port: u32, rootfs: bool, rootfs_writable: bool, rootfs_growth: bool, noinit_itable: bool, network: NetworkMode, build_context: bool, build_mode: bool, build_input_count: usize) ![]const u8 {
    const rootfs_flag = if (rootfs) " spore_rootfs=1" else "";
    const rootfs_rw_flag = if (rootfs and rootfs_writable) " spore_rootfs_rw=1" else "";
    const rootfs_growth_flag = if (rootfs and rootfs_writable and rootfs_growth) " spore_rootfs_growth=1" else "";
    const noinit_itable_flag = if (rootfs and rootfs_writable and rootfs_growth and noinit_itable) " spore_rootfs_noinit_itable=1" else "";
    const network_flag = if (network == .spore) " spore_net=1" else "";
    const build_context_flag = if (build_context) " spore_build_context=1" else "";
    const build_mode_flag = if (build_mode) " spore_build=1" else "";
    const build_inputs_flag = if (build_input_count != 0)
        try std.fmt.allocPrint(allocator, " spore_build_inputs={d}", .{build_input_count})
    else
        null;
    defer if (build_inputs_flag) |flag| allocator.free(flag);
    return std.fmt.allocPrint(
        allocator,
        "console=hvc0 rdinit=/init cleanroom_guest_port={d} cleanroom_guest_boot_timing=1{s}{s}{s}{s}{s}{s}{s}{s}",
        .{ guest_port, rootfs_flag, rootfs_rw_flag, rootfs_growth_flag, noinit_itable_flag, network_flag, build_context_flag, build_mode_flag, build_inputs_flag orelse "" },
    );
}

fn productBootArgs(allocator: std.mem.Allocator, base: []const u8) ![]const u8 {
    if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
        var descriptors_buf: [x86_board.max_virtio_command_line_len]u8 = undefined;
        const descriptors = try x86_board.formatVirtioCommandLine(&descriptors_buf);
        return std.fmt.allocPrint(allocator, "{s} {s}", .{ base, descriptors });
    }
    return base;
}

fn resultFromStream(backend: Backend, opts: Options, stream: *const vsock.HostStream, saved: bool) !Result {
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
        .saved = saved,
        .save_path = if (saved) opts.save_path else null,
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
        .saved = true,
        .save_path = opts.save_path,
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
        .saved = true,
        .save_path = opts.save_path,
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

pub fn parseDurationMs(raw: []const u8) !u64 {
    if (raw.len == 0) return error.InvalidDuration;
    if (std.mem.endsWith(u8, raw, "ms")) {
        return parsePositiveDuration(raw[0 .. raw.len - 2], 1);
    }
    if (std.mem.endsWith(u8, raw, "s")) {
        return parsePositiveDuration(raw[0 .. raw.len - 1], std.time.ms_per_s);
    }
    if (std.mem.endsWith(u8, raw, "m")) {
        return parsePositiveDuration(raw[0 .. raw.len - 1], std.time.ms_per_min);
    }
    return parsePositiveDuration(raw, std.time.ms_per_s);
}

fn parseDurationMsOrExit(name: []const u8, raw: []const u8) u64 {
    return parseDurationMs(raw) catch {
        std.debug.print("{s} expects a duration like 30s, 500ms, or 1m\n", .{name});
        std.process.exit(2);
    };
}

fn parsePositiveDuration(number: []const u8, multiplier: u64) !u64 {
    const value = try parsePositiveDurationInteger(number);
    return try std.math.mul(u64, value, multiplier);
}

fn parsePositiveDurationInteger(raw: []const u8) !u64 {
    if (raw.len == 0) return error.InvalidDuration;
    const value = try std.fmt.parseInt(u64, raw, 10);
    if (value == 0) return error.InvalidDuration;
    return value;
}

pub fn parseVcpuCountOrExit(name: []const u8, raw: []const u8) topology.VcpuCount {
    return topology.parseVcpuCount(raw) catch {
        std.debug.print("{s} must be an integer from 1 to {d}\n", .{ name, topology.max_vcpus });
        std.process.exit(2);
    };
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
    try validateGuestExecContext(options.env, options.working_dir);
}

pub fn validateGuestExecContext(env: []const []const u8, working_dir: ?[]const u8) !void {
    if (env.len > max_guest_envc) return error.RunEnvCountUnsupported;
    for (env) |entry| {
        if (entry.len > max_guest_env_len) return error.RunEnvTooLong;
    }
    if (working_dir) |dir| {
        if (dir.len == 0 or dir.len > max_guest_working_dir_len or !std.fs.path.isAbsolute(dir)) return error.RunWorkingDirUnsupported;
    }
}

fn validateInjectedFiles(injected_files: []const InjectedFile) !void {
    if (injected_files.len > max_injected_files) return error.TooManyInjectedFiles;
    var total: usize = 0;
    for (injected_files, 0..) |file, i| {
        try validateInjectedFileId(file.id);
        if (file.bytes.len > max_injected_file_total_bytes -| total) return error.InjectedFileTooLarge;
        total += file.bytes.len;
        for (injected_files[0..i]) |existing| {
            if (std.mem.eql(u8, existing.id, file.id)) return error.DuplicateInjectedFile;
        }
    }
}

fn validateInjectedFileId(id: []const u8) !void {
    if (id.len == 0 or id.len > max_injected_file_id_len) return error.BadInjectedFileId;
    if (std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return error.BadInjectedFileId;
    for (id) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-') continue;
        return error.BadInjectedFileId;
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
        shared.vcpus = parseVcpuCountOrExit(name, takeValue(args, i, name));
    } else if (std.mem.eql(u8, name, "--guest-port")) {
        shared.guest_port = try parseGuestPort(name, takeValue(args, i, name));
    } else if (std.mem.eql(u8, name, "--timeout")) {
        shared.timeout_ms = parseDurationMsOrExit(name, takeValue(args, i, name));
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
    try std.testing.expectEqualStrings("{\"type\":\"start\",\"session_id\":\"default\",\"resume_time_unix_ns\":0,\"argv\":[\"/bin/echo\",\"hello world\"],\"env\":[],\"working_dir\":\"\",\"memory_pressure\":false,\"params_json\":\"\",\"require_generation_ready\":false,\"closed_env\":true}\n", request);
}

test "run request can encode explicit session id" {
    const request = try execRequestWithSession(std.testing.allocator, &.{"/bin/true"}, "lifecycle-42", 1_700_000_000_000_000_000);
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings("{\"type\":\"start\",\"session_id\":\"lifecycle-42\",\"resume_time_unix_ns\":1700000000000000000,\"argv\":[\"/bin/true\"],\"env\":[],\"working_dir\":\"\",\"memory_pressure\":false,\"params_json\":\"\",\"require_generation_ready\":false,\"closed_env\":true}\n", request);
}

test "run detached exec request asks guest to start without waiting" {
    const request = try detachedExecRequestWithSessionContext(std.testing.allocator, &.{"/bin/true"}, "lifecycle-1", .{
        .env = &.{"SPORE_CONTEXT=detached"},
        .working_dir = "/work",
        .resume_time_unix_ns = 1_700_000_000_000_000_000,
    });
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings("{\"type\":\"start\",\"session_id\":\"lifecycle-1\",\"resume_time_unix_ns\":1700000000000000000,\"argv\":[\"/bin/true\"],\"env\":[\"SPORE_CONTEXT=detached\"],\"working_dir\":\"/work\",\"memory_pressure\":false,\"detached\":true,\"closed_env\":true}\n", request);
}

test "run request encodes image env and working directory" {
    const request = try execRequestWithSessionOptions(std.testing.allocator, &.{ "/bin/sh", "-lc", "env && pwd" }, "default", .{
        .env = &.{ "GEM_HOME=/usr/local/bundle", "RUBYOPT=--yjit" },
        .working_dir = "/app",
        .resume_time_unix_ns = 123,
        .memory_pressure = true,
        .generation_params = "{\"resume_entropy_seed\":\"abcd\"}",
        .require_generation_ready = true,
    });
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings("{\"type\":\"start\",\"session_id\":\"default\",\"resume_time_unix_ns\":123,\"argv\":[\"/bin/sh\",\"-lc\",\"env && pwd\"],\"env\":[\"GEM_HOME=/usr/local/bundle\",\"RUBYOPT=--yjit\"],\"working_dir\":\"/app\",\"memory_pressure\":true,\"params_json\":\"{\\\"resume_entropy_seed\\\":\\\"abcd\\\"}\",\"require_generation_ready\":true,\"closed_env\":true}\n", request);
}

test "run request encodes env for run from spore command" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const request = try execRequestForRun(.{ .io = std.testing.io, .environ_map = &env }, std.testing.allocator, .{
        .kernel_path = "",
        .resume_dir = "base.spore",
        .command = &.{"/usr/bin/env"},
        .guest_env = &.{"SPORE_TEST_ENV=ok"},
    }, false);
    defer std.testing.allocator.free(request.bytes);
    defer std.testing.allocator.free(request.session_id);
    try std.testing.expect(std.mem.indexOf(u8, request.bytes, "\"env\":[\"SPORE_TEST_ENV=ok\"]") != null);
}

test "cli env specs resolve host copies and last override wins" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("SPORE_TEST_ENV", "from-host");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const literal = try parseGuestEnvSpec("SPORE_TEST_ENV=literal=with-equals");
    const copy = try parseGuestEnvSpec("SPORE_TEST_ENV");
    const resolved = try resolveCliGuestEnv(arena, &.{ literal, copy }, &env, null);

    try std.testing.expectEqual(@as(usize, 1), resolved.len);
    try std.testing.expectEqualStrings("SPORE_TEST_ENV=from-host", resolved[0]);
}

test "cli env specs reject empty keys and missing host values" {
    try std.testing.expectError(error.BadGuestEnvKey, parseGuestEnvSpec("=bad"));
    try std.testing.expectError(error.BadGuestEnvKey, parseGuestEnvSpec("1BAD=value"));
    try std.testing.expectError(error.BadGuestEnvKey, parseGuestEnvSpec("BAD-KEY=value"));

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var diagnostic = GuestEnvResolveDiagnostic{};
    const spec = try parseGuestEnvSpec("MISSING_ENV");
    try std.testing.expectError(error.MissingHostEnvironment, resolveCliGuestEnv(std.testing.allocator, &.{spec}, &env, &diagnostic));
    try std.testing.expectEqualStrings("MISSING_ENV", diagnostic.missing_key.?);
}

test "cli env overrides image env by key" {
    const merged = try mergeGuestEnv(std.testing.allocator, &.{ "PATH", "KEEP=1" }, &.{ "PATH=/usr/bin", "NEW=2" });
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try std.testing.expectEqualStrings("KEEP=1", merged[0]);
    try std.testing.expectEqualStrings("PATH=/usr/bin", merged[1]);
    try std.testing.expectEqualStrings("NEW=2", merged[2]);

    var buffer: [max_guest_envc][]const u8 = undefined;
    const cleared = try mergeGuestEnvInto(&buffer, &.{ "CLEAR_ME", "KEEP=1" }, &.{"CLEAR_ME="});
    try std.testing.expectEqual(@as(usize, 2), cleared.len);
    try std.testing.expectEqualStrings("KEEP=1", cleared[0]);
    try std.testing.expectEqualStrings("CLEAR_ME=", cleared[1]);
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
        \\      "Entrypoint": ["/usr/bin/env"],
        \\      "Cmd": ["bundle", "exec"],
        \\      "WorkingDir": "/app",
        \\      "User": "1000:1000"
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
    const input = try resolvedImageRootfsInput(init, arena, cache_root, "local/buildkite-spore:ci", resolved, rootfs_path, false, false);
    try std.testing.expectEqual(@as(usize, 2), input.guest_env.len);
    try std.testing.expectEqualStrings("GEM_HOME=/usr/local/bundle", input.guest_env[0]);
    try std.testing.expectEqualStrings("BUNDLE_APP_CONFIG=/usr/local/bundle", input.guest_env[1]);
    try std.testing.expectEqualStrings("/app", input.guest_working_dir.?);
    try std.testing.expectEqual(.arm64, input.image_config.?.architecture.?);
    try std.testing.expectEqualStrings("linux", input.image_config.?.os.?);
    try std.testing.expectEqualStrings("/usr/bin/env", input.image_config.?.config.?.Entrypoint.?[0]);
    try std.testing.expectEqualStrings("bundle", input.image_config.?.config.?.Cmd.?[0]);
    try std.testing.expectEqualStrings("1000:1000", input.image_config.?.config.?.User.?);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = ("abcd" ** 1024) ++ ("efgh" ** 1024) });
    const preload = try rootfs_cas.preloadPath(io, arena, cache_root, rootfs_path, rootfs_cas.default_chunk_size);
    const storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload);
    _ = try rootfs_cache.installTrustedMaterializationByHardlink(io, arena, cache_root, rootfs_path, storage.index_digest, storage.logical_size);
    const storage_json = try std.json.Stringify.valueAlloc(arena, storage, .{});
    const rootfs_metadata = try std.fmt.allocPrint(arena,
        \\{{
        \\  "rootfs_path": "{s}",
        \\  "rootfs_size": {d},
        \\  "rootfs_storage": {s},
        \\  "config": {{
        \\    "architecture": "arm64",
        \\    "os": "linux",
        \\    "config": {{
        \\      "Env": ["GEM_HOME=/usr/local/bundle", "BUNDLE_APP_CONFIG=/usr/local/bundle"],
        \\      "WorkingDir": "/app"
        \\    }}
        \\  }}
        \\}}
    , .{ rootfs_path, storage.logical_size, storage_json });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = rootfs_metadata });
    const captured = try resolvedImageRootfsInput(init, arena, cache_root, "local/buildkite-spore:ci", resolved, rootfs_path, true, false);
    try std.testing.expect(captured.rootfs != null);
    try std.testing.expect(captured.rootfs.?.storage != null);
    try std.testing.expectEqualStrings(resolved.ref, captured.rootfs.?.source.?.requested_ref);
    try std.testing.expect(try rootfs_cas.storageComplete(io, arena, cache_root, captured.rootfs.?.storage.?));

    const updated_metadata = try Io.Dir.cwd().readFileAlloc(io, metadata_path, arena, .limited(1024 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, updated_metadata, "\"rootfs_storage\"") != null);

    const digest_path = try rootfs_cache.digestPath(arena, cache_root, captured.rootfs.?.artifact.digest);
    try Io.Dir.cwd().deleteFile(io, digest_path);
    try std.testing.expect(!try rootfs_cache.regularFileNoSymlink(io, digest_path));
    try std.testing.expect(try rootfs_cas.storageComplete(io, arena, cache_root, captured.rootfs.?.storage.?));
    try std.testing.expect(rootfsWritable(.{
        .kernel_path = "",
        .rootfs_path = captured.path,
        .rootfs = captured.rootfs,
        .command = &.{"/bin/true"},
    }));
}

test "image runtime command composes entrypoint defaults and caller override" {
    const allocator = std.testing.allocator;
    var entrypoint = [_][]const u8{ "/entry", "fixed" };
    var cmd = [_][]const u8{ "default", "arg" };
    const config = rootfs_mod.ImageConfig{ .config = .{ .Entrypoint = &entrypoint, .Cmd = &cmd } };

    const defaults = try resolveImageRuntimeCommand(allocator, config, &.{});
    defer allocator.free(defaults);
    try std.testing.expectEqualSlices([]const u8, &.{ "/entry", "fixed", "default", "arg" }, defaults);

    const override = try resolveImageRuntimeCommand(allocator, config, &.{ "/bin/sh", "-lc", "echo hi" });
    defer allocator.free(override);
    try std.testing.expectEqualSlices([]const u8, &.{ "/entry", "fixed", "/bin/sh", "-lc", "echo hi" }, override);
}

test "image runtime command handles absent and empty defaults" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.ImageCommandMissing, resolveImageRuntimeCommand(allocator, null, &.{}));
    try std.testing.expectError(error.ImageCommandMissing, resolveImageRuntimeCommand(allocator, .{ .config = .{} }, &.{}));
    var empty = [_][]const u8{};
    try std.testing.expectError(error.ImageCommandMissing, resolveImageRuntimeCommand(allocator, .{ .config = .{ .Entrypoint = &empty, .Cmd = &empty } }, &.{}));

    var cmd = [_][]const u8{"/default"};
    const command = try resolveImageRuntimeCommand(allocator, .{ .config = .{ .Entrypoint = &empty, .Cmd = &cmd } }, &.{});
    defer allocator.free(command);
    try std.testing.expectEqualStrings("/default", command[0]);
}

test "image runtime command rejects a non-root image user" {
    try std.testing.expectError(
        error.UnsupportedImageUser,
        resolveImageRuntimeCommand(std.testing.allocator, .{ .config = .{ .User = "1000:1000" } }, &.{"/bin/true"}),
    );
}

test "image runtime command enforces guest argv bounds" {
    const allocator = std.testing.allocator;
    var too_many: [max_guest_argc + 1][]const u8 = @splat("x");
    try std.testing.expectError(error.RunArgCountUnsupported, resolveImageRuntimeCommand(allocator, null, &too_many));
    var too_long: [max_guest_arg_len + 1]u8 = @splat('x');
    try std.testing.expectError(error.RunArgTooLong, resolveImageRuntimeCommand(allocator, null, &.{&too_long}));
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

test "interactive stream protocol failure has a clear public message" {
    const classified = classifyFailure(error.InteractiveStreamProtocolFailed);
    try std.testing.expectEqual(machine_output.ErrorCode.runtime_start_failed, classified.code);
    try std.testing.expect(std.mem.indexOf(u8, classified.message, "start-v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, classified.message, "omit -i/-t") != null);
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
    var policy = spore_net_policy.Config{};
    try policy.addBoundUnixService("gateway", "gateway.internal", 8170, "/tmp/gateway.sock");

    try events.emitPortForwards(&policy);

    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    const port_forward_line = lines.next().?;
    try std.testing.expectEqualStrings("", lines.next().?);
    try std.testing.expectEqualStrings(
        "{\"schema\":\"spore.run-events.v1\",\"schema_version\":1,\"event\":\"port_forward\",\"command\":\"run\",\"backend\":\"hvf\",\"type\":\"bound_unix_service\",\"name\":\"gateway\",\"guest_host\":\"gateway.internal\",\"guest_port\":8170,\"target\":\"unix\"}",
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
        .memory_bytes = memory_config.auto_bytes,
        .saved = true,
        .save_path = "out.spore",
    });

    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    const ready_line = lines.next().?;
    const capture_line = lines.next().?;
    const exit_line = lines.next().?;
    try std.testing.expectEqualStrings("", lines.next().?);
    try expectJsonStringField(allocator, ready_line, "event", "ready");
    try std.testing.expectEqualStrings(
        "{\"schema\":\"spore.run-events.v1\",\"schema_version\":1,\"event\":\"capture\",\"command\":\"run\",\"backend\":\"hvf\",\"capture_path\":\"out.spore\"}",
        capture_line,
    );
    try expectJsonStringField(allocator, exit_line, "event", "exit");
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

test "run request accepts 256 byte argv at legacy boundary" {
    var arg = [_]u8{'a'} ** 256;
    const request = try execRequest(std.testing.allocator, &.{arg[0..]});
    defer std.testing.allocator.free(request);
    try std.testing.expect(request.len > arg.len);
}

test "run request accepts 4096 byte argv within total request limit" {
    var arg = [_]u8{'a'} ** 4096;
    const request = try execRequest(std.testing.allocator, &.{arg[0..]});
    defer std.testing.allocator.free(request);
    try std.testing.expect(request.len > arg.len);
}

test "run request rejects encoded line overflow" {
    var env_entry = [_]u8{'A'} ** max_guest_env_len;
    var env: [max_guest_envc][]const u8 = undefined;
    for (&env) |*slot| slot.* = env_entry[0..];
    try std.testing.expectError(error.RunRequestTooLarge, execRequestWithSessionOptions(std.testing.allocator, &.{"/bin/true"}, "default", .{ .env = &env }));
}

test "interactive run request uses start v1 pipe stdio" {
    const request = try execRequestWithSessionOptions(std.testing.allocator, &.{"/bin/cat"}, "default", .{ .interactive = true });
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"type\":\"start-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"stdio\":\"pipe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"argv\":[\"/bin/cat\"]") != null);
}

test "streaming exec request uses start v1 with closed pipe stdin" {
    const request = try interactiveExecRequestWithSession(std.testing.allocator, &.{"/bin/true"}, "default", .{
        .env = &.{"SPORE_CONTEXT=stream"},
        .working_dir = "/workspace",
    });
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"type\":\"start-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"stdio\":\"pipe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"env\":[\"SPORE_CONTEXT=stream\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"working_dir\":\"/workspace\"") != null);
}

test "tty run request uses start v1 terminal metadata" {
    const request = try execRequestWithSessionOptions(std.testing.allocator, &.{"/bin/sh"}, "default", .{
        .tty = true,
        .terminal_name = "xterm-256color",
        .terminal_size = .{ .rows = 40, .cols = 120 },
    });
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"type\":\"start-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"stdio\":\"tty\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"term\":\"xterm-256color\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"terminal_rows\":40") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"terminal_cols\":120") != null);
}

fn testDiskGuardManifest(with_disk: bool) spore.Manifest {
    return .{
        .platform = .{
            .cpu_profile = "test",
            .device_model_version = 1,
            .ram_base = 0x8000_0000,
            .ram_size = 4096,
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
        .memory = .{ .logical_size = 4096, .chunk_size = spore.chunk_size, .zero_chunks = &.{0} },
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
        std.testing.allocator.free(disk.hash_algorithm);
        std.testing.allocator.free(disk.object_namespace);
        std.testing.allocator.free(disk.layers);
    }
    try std.testing.expectEqualStrings("blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", disk.base);
}

test "run cli parser accepts command after separator" {
    const opts = try parseCliArgs(&.{ "--backend", "hvf", "--kernel", "Image", "--initrd", "root.cpio", "--", "/bin/true" });
    try std.testing.expectEqual(Backend.hvf, opts.backend);
    try std.testing.expectEqualStrings("Image", opts.shared.kernel_path.?);
    try std.testing.expectEqualStrings("root.cpio", opts.shared.initrd_path.?);
    try std.testing.expectEqual(CommandMode.argv, opts.command_mode);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("/bin/true", opts.command[0]);
}

test "run cli parser accepts flexible timeout duration" {
    const opts = try parseCliArgs(&.{ "--timeout", "120s", "--", "/bin/true" });
    try std.testing.expectEqual(@as(u64, 120_000), opts.shared.timeout_ms);
}

test "run cli parser accepts hidden timeout-ms compatibility spelling" {
    const opts = try parseCliArgs(&.{ "--timeout-ms", "120000", "--", "/bin/true" });
    try std.testing.expectEqual(@as(u64, 120_000), opts.shared.timeout_ms);
}

test "run duration parser accepts common suffixes" {
    try std.testing.expectEqual(@as(u64, 500), try parseDurationMs("500ms"));
    try std.testing.expectEqual(@as(u64, 10_000), try parseDurationMs("10s"));
    try std.testing.expectEqual(@as(u64, 60_000), try parseDurationMs("1m"));
    try std.testing.expectEqual(@as(u64, 5_000), try parseDurationMs("5"));
    try std.testing.expectError(error.InvalidDuration, parseDurationMs("0s"));
}

test "run cli parser accepts injected files" {
    const opts = try parseCliArgs(&.{ "--inject", "config=host-config.json", "--", "/bin/true" });
    try std.testing.expectEqual(@as(usize, 1), opts.injected_file_sources.len);
    try std.testing.expectEqualStrings("config", opts.injected_file_sources.items[0].id);
    try std.testing.expectEqualStrings("host-config.json", opts.injected_file_sources.items[0].path);
}

test "run cli parser accepts repeatable env specs" {
    const opts = try parseCliArgs(&.{ "--env", "SPORE_TEST_ENV=ok", "--env", "HOST_ENV", "--", "/usr/bin/env" });
    try std.testing.expectEqual(@as(usize, 2), opts.guest_env_specs.len);
    try std.testing.expectEqualStrings("SPORE_TEST_ENV=ok", opts.guest_env_specs.items[0].literal);
    try std.testing.expectEqualStrings("HOST_ENV", opts.guest_env_specs.items[1].copy);
}

test "injected file initrd overlay contains the file" {
    const initrd = try initrdWithInjectedFiles(std.testing.allocator, "base-cpio", &.{
        .{ .id = "config.json", .bytes = "{\"ok\":true}\n" },
    });
    defer std.testing.allocator.free(initrd);
    try std.testing.expect(std.mem.indexOf(u8, initrd, "base-cpio") != null);
    try std.testing.expect(std.mem.indexOf(u8, initrd, "run/sporevm/injected/config.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, initrd, "{\"ok\":true}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, initrd, "TRAILER!!!") != null);
}

test "injected file ids reject paths" {
    try std.testing.expectError(error.BadInjectedFileId, validateInjectedFileId("../secret"));
    try std.testing.expectError(error.BadInjectedFileId, validateInjectedFileId("nested/path"));
}

test "run cli parser accepts interactive stdin" {
    const opts = try parseCliArgs(&.{ "-i", "--image", "docker.io/library/alpine:3.20", "--", "/bin/cat" });
    try std.testing.expect(opts.interactive);
    try std.testing.expect(!opts.tty);
    try std.testing.expectEqual(CommandMode.argv, opts.command_mode);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("/bin/cat", opts.command[0]);
}

test "run cli parser accepts tty and combined interactive tty" {
    const tty_opts = try parseCliArgs(&.{ "-t", "--image", "docker.io/library/alpine:3.20", "--", "/bin/sh" });
    try std.testing.expect(!tty_opts.interactive);
    try std.testing.expect(tty_opts.tty);
    try std.testing.expectEqual(CommandMode.argv, tty_opts.command_mode);
    try std.testing.expectEqualStrings("/bin/sh", tty_opts.command[0]);

    const it_opts = try parseCliArgs(&.{ "-it", "--image", "docker.io/library/alpine:3.20", "--", "/bin/sh" });
    try std.testing.expect(it_opts.interactive);
    try std.testing.expect(it_opts.tty);
    try std.testing.expectEqual(CommandMode.argv, it_opts.command_mode);
    try std.testing.expectEqualStrings("/bin/sh", it_opts.command[0]);
}

test "run cli parser accepts shell command without separator" {
    const opts = try parseCliArgs(&.{ "--image", "docker.io/library/alpine:3.20", "echo hi" });
    try std.testing.expectEqualStrings("docker.io/library/alpine:3.20", opts.image_ref.?);
    try std.testing.expectEqual(CommandMode.shell, opts.command_mode);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("echo hi", opts.command[0]);
}

test "run cli parser accepts shell command with source spore" {
    const opts = try parseCliArgs(&.{ "--from", "base.spore", "cat /work-ready" });
    try std.testing.expectEqualStrings("base.spore", opts.from_spore_dir.?);
    try std.testing.expectEqual(CommandMode.shell, opts.command_mode);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("cat /work-ready", opts.command[0]);
}

test "run cli parser accepts commandless source spore" {
    const opts = try parseCliArgs(&.{ "--from", "live.spore" });
    try std.testing.expectEqualStrings("live.spore", opts.from_spore_dir.?);
    try std.testing.expectEqual(CommandMode.shell, opts.command_mode);
    try std.testing.expectEqual(@as(usize, 0), opts.command.len);
}

test "run cli guest command wraps shell command" {
    const opts = try parseCliArgs(&.{ "--image", "docker.io/library/alpine:3.20", "echo hi" });
    const argv = try cliGuestCommand(std.testing.allocator, opts);
    defer std.testing.allocator.free(argv);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("/bin/sh", argv[0]);
    try std.testing.expectEqualStrings("-lc", argv[1]);
    try std.testing.expectEqualStrings("echo hi", argv[2]);
}

test "run cli guest command keeps exact argv" {
    const opts = try parseCliArgs(&.{ "--image", "docker.io/library/alpine:3.20", "--", "/bin/echo", "hi" });
    const argv = try cliGuestCommand(std.testing.allocator, opts);
    try std.testing.expectEqual(@as(usize, 2), argv.len);
    try std.testing.expectEqualStrings("/bin/echo", argv[0]);
    try std.testing.expectEqualStrings("hi", argv[1]);
}

test "run cli guest command rejects unquoted shell words" {
    const opts = try parseCliArgs(&.{ "--image", "docker.io/library/alpine:3.20", "echo", "hi" });
    try std.testing.expectError(error.ShellCommandArgumentCountUnsupported, cliGuestCommand(std.testing.allocator, opts));
}

test "run cli parser allows default boot assets" {
    const opts = try parseCliArgs(&.{ "--", "/bin/writeout" });
    try std.testing.expectEqual(Backend.auto, opts.backend);
    try std.testing.expect(opts.shared.kernel_path == null);
    try std.testing.expect(opts.shared.initrd_path == null);
    try std.testing.expectEqual(memory_config.Policy.auto, opts.shared.memory.policy);
    try std.testing.expectEqual(memory_config.auto_bytes, opts.shared.memory.bytes);
    try std.testing.expectEqual(CommandMode.argv, opts.command_mode);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("/bin/writeout", opts.command[0]);
}

test "backend auto resolves to a supported host backend" {
    if (Backend.auto.supportedOnHost()) {
        const resolved = try Backend.auto.resolveForHost();
        try std.testing.expect(resolved != .auto);
        try std.testing.expect(resolved.supportedOnHost());
    } else {
        try std.testing.expectError(error.UnsupportedBackend, Backend.auto.resolveForHost());
    }
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

test "x86 fresh product policy is explicit and fail closed" {
    const accepted = FreshProductPolicy{
        .memory = .{ .policy = .explicit, .bytes = x86_experimental_memory_bytes },
        .vcpus = 1,
    };
    try validateFreshProductPolicyFor(.x86_64, .kvm, accepted);
    try validateFreshProductPolicyFor(.aarch64, .kvm, .{ .memory = .{}, .vcpus = 8, .resuming = true, .capture = true });
    try std.testing.expectError(error.UnsupportedBackend, validateFreshProductPolicyFor(.x86_64, .hvf, accepted));
    try std.testing.expectError(error.X86ExplicitMemoryRequired, validateFreshProductPolicyFor(.x86_64, .kvm, .{ .memory = .{}, .vcpus = 1 }));
    try std.testing.expectError(error.X86ExperimentalMemorySizeUnsupported, validateFreshProductPolicyFor(.x86_64, .kvm, .{
        .memory = .{ .policy = .explicit, .bytes = 1024 * 1024 * 1024 },
        .vcpus = 1,
    }));
    try std.testing.expectError(error.X86VcpuCountUnsupported, validateFreshProductPolicyFor(.x86_64, .kvm, .{
        .memory = accepted.memory,
        .vcpus = 2,
    }));
    try std.testing.expectError(error.X86ResumeUnsupported, validateFreshProductPolicyFor(.x86_64, .kvm, .{ .memory = accepted.memory, .vcpus = 1, .resuming = true }));
    try std.testing.expectError(error.X86CaptureUnsupported, validateFreshProductPolicyFor(.x86_64, .kvm, .{ .memory = accepted.memory, .vcpus = 1, .capture = true }));
    try std.testing.expectError(error.X86RootfsUnsupported, validateFreshProductPolicyFor(.x86_64, .kvm, .{ .memory = accepted.memory, .vcpus = 1, .rootfs = true }));
    try std.testing.expectError(error.X86NetworkUnsupported, validateFreshProductPolicyFor(.x86_64, .kvm, .{ .memory = accepted.memory, .vcpus = 1, .network = true }));
    try std.testing.expectError(error.X86BuildUnsupported, validateFreshProductPolicyFor(.x86_64, .kvm, .{ .memory = accepted.memory, .vcpus = 1, .build = true }));
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
    try std.testing.expectEqual(CommandMode.argv, opts.command_mode);
    try std.testing.expectEqual(@as(usize, 2), opts.command.len);
    try std.testing.expectEqualStrings("/bin/echo", opts.command[0]);
    try std.testing.expectEqualStrings("hi", opts.command[1]);
}

test "run cli parser permits omitted command only for images" {
    const opts = try parseCliArgs(&.{ "--image", "docker.io/library/alpine:3.20" });
    try std.testing.expectEqual(@as(usize, 0), opts.command.len);
}

test "run cli parser accepts image commit" {
    const opts = try parseCliArgs(&.{
        "--image",
        "docker.io/library/alpine:3.20",
        "--commit",
        "local/example:prepared",
        "--inject",
        "setup=prepare.sh",
        "--",
        "/bin/sh",
        "/run/sporevm/injected/setup",
    });
    try std.testing.expectEqualStrings("local/example:prepared", opts.commit_ref.?);
    try std.testing.expectEqual(@as(usize, 1), opts.injected_file_sources.len);
    try std.testing.expectEqualStrings("/bin/sh", opts.command[0]);
}

test "run cli parser accepts commit disk size" {
    const opts = try parseCliArgs(&.{
        "--image",
        "docker.io/library/alpine:3.20",
        "--commit",
        "local/example:prepared",
        "--disk-size",
        "20gb",
        "--",
        "/bin/true",
    });
    try std.testing.expectEqual(@as(?u64, 20 * 1024 * 1024 * 1024), opts.disk_size);
}

test "run disk size is absolute and cannot shrink" {
    try std.testing.expectEqual(@as(u64, 0), try rootfsGrowTarget(4 * 1024 * 1024, 4 * 1024 * 1024));
    try std.testing.expectEqual(@as(u64, 8 * 1024 * 1024), try rootfsGrowTarget(4 * 1024 * 1024, 8 * 1024 * 1024));
    try std.testing.expectError(error.RunDiskSizeWouldShrink, rootfsGrowTarget(8 * 1024 * 1024, 4 * 1024 * 1024));
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
    try std.testing.expectEqual(CommandMode.argv, opts.command_mode);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("/bin/writeout", opts.command[0]);
}

test "run cli parser accepts source spore generation file" {
    const opts = try parseCliArgs(&.{ "--from", "base.spore", "--generation", "generation.json", "--", "/bin/writeout" });
    try std.testing.expectEqualStrings("base.spore", opts.from_spore_dir.?);
    try std.testing.expectEqualStrings("generation.json", opts.generation_path.?);
    try std.testing.expectEqual(CommandMode.argv, opts.command_mode);
    try std.testing.expectEqualStrings("/bin/writeout", opts.command[0]);

    const equals_opts = try parseCliArgs(&.{ "--from", "base.spore", "--generation=generation.json", "--", "/bin/writeout" });
    try std.testing.expectEqualStrings("generation.json", equals_opts.generation_path.?);
}

test "run cli parser accepts source spore bound service bindings" {
    const opts = try parseCliArgs(&.{
        "--from",
        "base.spore",
        "--bind-service",
        "metadata=unix:/tmp/metadata.sock",
    });
    try std.testing.expectEqualStrings("base.spore", opts.from_spore_dir.?);
    try std.testing.expectEqual(@as(usize, 1), opts.bound_services.len);
    try std.testing.expectEqualStrings("metadata", opts.bound_services.items[0].name);
    try std.testing.expectEqualStrings("/tmp/metadata.sock", opts.bound_services.items[0].target.unix);
    try std.testing.expect(!opts.network_policy.hasRules());
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
        "--bind-service",
        "cache:8080=unix:/tmp/cache.sock",
        "--",
        "/bin/true",
    });
    try std.testing.expectEqual(NetworkMode.spore, opts.network);
    try std.testing.expect(opts.network_requested);
    try std.testing.expectEqual(@as(usize, 2), opts.network_policy.bound_service_count);
    try std.testing.expectEqualStrings("metadata", opts.network_policy.bound_services[0].name);
    try std.testing.expectEqualStrings("/tmp/metadata.sock", opts.network_policy.bound_services[0].unix_path);
    try std.testing.expectEqualStrings("cache", opts.network_policy.bound_services[1].name);
    try std.testing.expectEqual(@as(u16, 8080), opts.network_policy.bound_services[1].guest_port);
    try std.testing.expectEqualStrings("/tmp/cache.sock", opts.network_policy.bound_services[1].unix_path);
}

test "run cli parser accepts network port forwards" {
    const opts = try parseCliArgs(&.{
        "--net",
        "--forward",
        "127.0.0.1:8080:80",
        "--",
        "/bin/true",
    });
    try std.testing.expectEqual(NetworkMode.spore, opts.network);
    try std.testing.expect(opts.network_requested);
    try std.testing.expectEqual(@as(usize, 1), opts.network_policy.port_forward_count);
    try std.testing.expectEqual(@as(u16, 8080), opts.network_policy.port_forwards[0].host_port);
    try std.testing.expectEqual(@as(u16, 80), opts.network_policy.port_forwards[0].guest_port);
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

test "run refuses to restore saved bound services without live bindings" {
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

    try std.testing.expectError(error.MissingBoundServiceBinding, networkOptionsFromManifest(arena, manifest_network));
}

test "run binding diagnostics name missing saved bound service" {
    var diagnostic = BoundServiceBindingDiagnostic{};
    {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const service_name = try arena.dupe(u8, "cleanroom-gateway");
        const manifest_network = spore.Network{
            .bound_services = &.{.{
                .name = service_name,
                .guest_host = "gateway.cleanroom.internal",
                .guest_port = 8170,
            }},
            .requirements = .{ .bound_services = true },
        };

        try std.testing.expectError(
            error.MissingBoundServiceBinding,
            networkOptionsFromManifestWithBindingDiagnostic(arena, manifest_network, &.{}, &diagnostic),
        );
    }
    try std.testing.expectEqualStrings("cleanroom-gateway", diagnostic.missing_name.?);
}

test "run restores saved bound services with live bindings" {
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

    const opts = try networkOptionsFromManifestWithBindings(arena, manifest_network, &.{.{
        .name = "cleanroom-gateway",
        .target = .{ .unix = "/tmp/fresh-cleanroom-gateway.sock" },
    }});
    try std.testing.expectEqual(NetworkMode.spore, opts.network);
    try std.testing.expectEqual(@as(usize, 1), opts.policy.bound_service_count);
    try std.testing.expectEqualStrings("cleanroom-gateway", opts.policy.bound_services[0].name);
    try std.testing.expectEqualStrings("gateway.cleanroom.internal", opts.policy.bound_services[0].guest_host);
    try std.testing.expectEqual(@as(u16, 8170), opts.policy.bound_services[0].guest_port);
    try std.testing.expectEqualStrings("/tmp/fresh-cleanroom-gateway.sock", opts.policy.bound_services[0].unix_path);
}

test "run rejects live bound service bindings that do not match manifest" {
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

    try std.testing.expectError(error.MissingBoundServiceBinding, networkOptionsFromManifestWithBindings(arena, manifest_network, &.{.{
        .name = "wrong-service",
        .target = .{ .unix = "/tmp/wrong.sock" },
    }}));

    try std.testing.expectError(error.UnexpectedBoundServiceBinding, networkOptionsFromManifestWithBindings(arena, null, &.{.{
        .name = "cleanroom-gateway",
        .target = .{ .unix = "/tmp/fresh-cleanroom-gateway.sock" },
    }}));
}

test "run network gateway errors are reported clearly" {
    try std.testing.expect(isNetworkGatewayError(error.NetdSpawnFailed));
    try std.testing.expect(isNetworkGatewayError(error.NetdReadyTimedOut));
    try std.testing.expect(isNetworkGatewayError(error.NetdReadyFailed));
    try std.testing.expect(isNetworkGatewayError(error.NetdThreadFailed));
    try std.testing.expect(isNetworkGatewayError(error.NetworkGatewayFailed));
    try std.testing.expect(!isNetworkGatewayError(error.UnsupportedBackend));
}

test "removed capture flags map to save rename hints" {
    try std.testing.expectEqualStrings("--save DIR", renamedRunFlagHint("--capture").?);
    try std.testing.expectEqualStrings("--save-on WHEN", renamedRunFlagHint("--capture-on").?);
    try std.testing.expectEqualStrings("--continue-after-save", renamedRunFlagHint("--continue-after-capture").?);
    try std.testing.expect(renamedRunFlagHint("--save") == null);
    try std.testing.expect(renamedRunFlagHint("--unknown") == null);
}

test "run cli parser accepts save flags" {
    const opts = try parseCliArgs(&.{ "--save", "out.spore", "--save-on", "USR1", "--continue-after-save", "--", "/bin/sleeper" });
    try std.testing.expectEqualStrings("out.spore", opts.save_path.?);
    try std.testing.expectEqual(capture.Signal.USR1, opts.save_trigger.signalValue().?);
    try std.testing.expect(opts.continue_after_save);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("/bin/sleeper", opts.command[0]);
}

test "run cli parser accepts bounded vcpu count" {
    const opts = try parseCliArgs(&.{ "--vcpus", "2", "--", "/bin/true" });
    try std.testing.expectEqual(@as(topology.VcpuCount, 2), opts.shared.vcpus);
}

test "run cli parser accepts jsonl events" {
    const opts = try parseCliArgs(&.{ "--events=jsonl", "--", "/bin/true" });
    try std.testing.expectEqual(EventMode.jsonl, opts.event_mode);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("/bin/true", opts.command[0]);
}

test "run cli parser defaults save trigger to exit" {
    const opts = try parseCliArgs(&.{ "--save", "out.spore", "--", "/bin/true" });
    try std.testing.expectEqualStrings("out.spore", opts.save_path.?);
    try std.testing.expect(opts.save_trigger.isExit());
    try std.testing.expect(!opts.continue_after_save);
}

test "saved run result exits zero" {
    const result = Result{
        .backend = .hvf,
        .start_ms = 1,
        .vsock_connect_ms = 2,
        .exec_response_ms = 3,
        .probe_duration_ms = 1,
        .exit_code = 0,
        .vcpus = 1,
        .memory_bytes = memory_config.auto_bytes,
        .saved = true,
        .save_path = "out.spore",
    };
    try std.testing.expectEqual(@as(u8, 0), result.processExitCode());
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
        .memory_bytes = memory_config.auto_bytes,
        .saved = true,
        .save_path = "out.spore",
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

test "direct image cache rootfs key requires exact cache child shape" {
    const cache_root = "/tmp/cache";
    const cache_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    try std.testing.expectEqualStrings(cache_key, directImageCacheRootfsKey(cache_root, "/tmp/cache/" ++ cache_key ++ ".ext4").?);
    try std.testing.expect(directImageCacheRootfsKey(cache_root, "/tmp/cache-other/" ++ cache_key ++ ".ext4") == null);
    try std.testing.expect(directImageCacheRootfsKey(cache_root, "/tmp/cache/by-digest/" ++ cache_key ++ ".ext4") == null);
    try std.testing.expect(directImageCacheRootfsKey(cache_root, "/tmp/cache/0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef.ext4") == null);
    try std.testing.expect(directImageCacheRootfsKey(cache_root, "/tmp/cache/" ++ cache_key ++ ".raw") == null);
    try std.testing.expect(directImageCacheRootfsKey(cache_root, "tmp/cache/" ++ cache_key ++ ".ext4") == null);
}

test "explicit rootfs input falls back when direct image cache metadata has no storage" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-explicit-rootfs-cache-fast-path";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, cache_root);
    const absolute_cache_root = try std.fs.path.resolve(arena, &.{cache_root});

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
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

    const cache_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const rootfs_path = try std.fmt.allocPrint(arena, "{s}/{s}.ext4", .{ absolute_cache_root, cache_key });
    const metadata_path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ absolute_cache_root, cache_key });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, absolute_cache_root, rootfs_path);
    const metadata = .{
        .rootfs_path = rootfs_path,
        .rootfs_size = artifact.size,
    };
    const metadata_json = try std.json.Stringify.valueAlloc(arena, metadata, .{});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = metadata_json });

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
    try std.testing.expectEqualStrings(artifact.digest, resolved.rootfs.?.artifact.digest);
    try std.testing.expectEqual(artifact.size, resolved.rootfs.?.artifact.size);

    const fallback_cache_key = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";
    const fallback_rootfs_path = try std.fmt.allocPrint(arena, "{s}/{s}.ext4", .{ absolute_cache_root, fallback_cache_key });
    const fallback_metadata_path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ absolute_cache_root, fallback_cache_key });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = fallback_rootfs_path, .data = "fallback rootfs bytes" });
    const fallback_metadata = .{
        .rootfs_path = fallback_rootfs_path,
        .rootfs_size = @as(u64, "fallback rootfs bytes".len),
    };
    const fallback_metadata_json = try std.json.Stringify.valueAlloc(arena, fallback_metadata, .{});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = fallback_metadata_path, .data = fallback_metadata_json });
    const fallback_expected = try rootfs_cache.hashPath(io, arena, fallback_rootfs_path);

    const fallback_result = try resolveRootfsInputDetailedResult(init, arena, .{
        .rootfs_path = fallback_rootfs_path,
        .image_ref = null,
        .command_name = "create",
        .record_artifact = true,
    });
    const fallback_resolved = switch (fallback_result) {
        .resolved => |value| value,
        .failure => return error.ExpectedRootfsRecord,
    };
    try std.testing.expect(fallback_resolved.rootfs != null);
    try std.testing.expectEqualStrings(fallback_expected.digest, fallback_resolved.rootfs.?.artifact.digest);
    try std.testing.expectEqual(fallback_expected.size, fallback_resolved.rootfs.?.artifact.size);
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
    const without_rootfs = try cmdline(std.testing.allocator, 10700, false, true, true, true, .disabled, false, false, 0);
    defer std.testing.allocator.free(without_rootfs);
    try std.testing.expect(std.mem.indexOf(u8, without_rootfs, "spore_rootfs=1") == null);
    try std.testing.expect(std.mem.indexOf(u8, without_rootfs, "spore_rootfs_rw=1") == null);
    try std.testing.expect(std.mem.indexOf(u8, without_rootfs, "spore_rootfs_growth=1") == null);
    try std.testing.expect(std.mem.indexOf(u8, without_rootfs, "spore_rootfs_noinit_itable=1") == null);

    const with_rootfs = try cmdline(std.testing.allocator, 10700, true, false, true, true, .disabled, false, false, 0);
    defer std.testing.allocator.free(with_rootfs);
    try std.testing.expect(std.mem.indexOf(u8, with_rootfs, "spore_rootfs=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_rootfs, "spore_rootfs_rw=1") == null);
    try std.testing.expect(std.mem.indexOf(u8, with_rootfs, "spore_rootfs_growth=1") == null);
    try std.testing.expect(std.mem.indexOf(u8, with_rootfs, "spore_rootfs_noinit_itable=1") == null);

    const with_writable_rootfs = try cmdline(std.testing.allocator, 10700, true, true, false, true, .disabled, false, false, 0);
    defer std.testing.allocator.free(with_writable_rootfs);
    try std.testing.expect(std.mem.indexOf(u8, with_writable_rootfs, "spore_rootfs=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_writable_rootfs, "spore_rootfs_rw=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_writable_rootfs, "spore_rootfs_growth=1") == null);

    const with_growth = try cmdline(std.testing.allocator, 10700, true, true, true, true, .disabled, false, false, 0);
    defer std.testing.allocator.free(with_growth);
    try std.testing.expect(std.mem.indexOf(u8, with_growth, "spore_rootfs_growth=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_growth, "spore_rootfs_noinit_itable=1") != null);

    const lazy_init_control = try cmdline(std.testing.allocator, 10700, true, true, true, false, .disabled, false, false, 0);
    defer std.testing.allocator.free(lazy_init_control);
    try std.testing.expect(std.mem.indexOf(u8, lazy_init_control, "spore_rootfs_growth=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazy_init_control, "spore_rootfs_noinit_itable=1") == null);
}

test "rootfs growth block profile is internal and opt in" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var stats: virtio_blk.Stats = .{};

    const ordinary = rootBlkOptions(&env, false, &stats);
    try std.testing.expect(!ordinary.write_zeroes);
    try std.testing.expect(ordinary.stats == null);

    const growth = rootBlkOptions(&env, true, &stats);
    try std.testing.expect(growth.write_zeroes);
    try std.testing.expect(!growth.force_write_zeroes_unsupported);
    try std.testing.expect(!growth.force_write_zeroes_backend_failure);
    try std.testing.expect(growth.stats == &stats);

    try env.put(force_write_zeroes_unsupported_experiment_env, "1");
    try std.testing.expect(!rootBlkOptions(&env, true, &stats).force_write_zeroes_unsupported);
    try env.put(force_write_zeroes_backend_failure_experiment_env, "1");
    try std.testing.expect(!rootBlkOptions(&env, true, &stats).force_write_zeroes_backend_failure);
    try env.put(lazy_init_negative_control_experiment_env, "1");
    try std.testing.expect(rootfsGrowthNoInitItable(&env));

    try env.put(rootfs_growth_experiments_env, "1");
    try std.testing.expect(rootBlkOptions(&env, true, &stats).force_write_zeroes_unsupported);
    try std.testing.expect(rootBlkOptions(&env, true, &stats).force_write_zeroes_backend_failure);
    try std.testing.expect(!rootfsGrowthNoInitItable(&env));
}

test "run rootfs path stays read-only without manifest rootfs metadata" {
    try std.testing.expect(!rootfsWritable(.{
        .kernel_path = "",
        .rootfs_path = "rootfs.ext4",
        .command = &.{"/bin/true"},
    }));
}

test "indexed rootfs input enables rootfs boot mode" {
    try std.testing.expect(hasRootfs(.{
        .kernel_path = "",
        .rootfs = .{
            .device = .{ .mmio_slot = 1 },
            .artifact = .{
                .digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                .size = 4096,
                .format = spore.rootfs_artifact_format_ext4,
            },
            .storage = .{
                .kind = spore.rootfs_storage_kind_chunked_ext4,
                .device = .{ .mmio_slot = 1 },
                .logical_size = 4096,
                .chunk_size = 4096,
                .hash_algorithm = "blake3",
                .index_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                .base_identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                .object_namespace = "rootfs/blake3",
            },
        },
        .command = &.{"/bin/true"},
    }));
}

test "run cmdline marks network mode" {
    const without_network = try cmdline(std.testing.allocator, 10700, false, false, false, false, .disabled, false, false, 0);
    defer std.testing.allocator.free(without_network);
    try std.testing.expect(std.mem.indexOf(u8, without_network, "spore_net=1") == null);

    const with_network = try cmdline(std.testing.allocator, 10700, false, false, false, false, .spore, false, false, 0);
    defer std.testing.allocator.free(with_network);
    try std.testing.expect(std.mem.indexOf(u8, with_network, "spore_net=1") != null);
}

test "run cmdline marks build mode and immutable input disks only when requested" {
    const without_context = try cmdline(std.testing.allocator, 10700, true, true, false, false, .disabled, false, true, 0);
    defer std.testing.allocator.free(without_context);
    try std.testing.expect(std.mem.indexOf(u8, without_context, "spore_build_context=1") == null);
    try std.testing.expect(std.mem.indexOf(u8, without_context, "spore_build=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, without_context, "spore_build_inputs=") == null);

    const with_context = try cmdline(std.testing.allocator, 10700, true, true, false, false, .disabled, true, true, 2);
    defer std.testing.allocator.free(with_context);
    try std.testing.expect(std.mem.indexOf(u8, with_context, "spore_build_context=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_context, "spore_build=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_context, "spore_build_inputs=2") != null);
}

test "run embeds default initrd with its generated canonical digest" {
    try std.testing.expect(embedded_run_initrd.len > 0);
    var actual: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(embedded_run_initrd, &actual, .{});
    try std.testing.expectEqualSlices(u8, &embedded_run_initrd_sha256, &actual);
}

test "managed run kernel asset names validate input" {
    const x86 = try managedRunKernelAssetNameFor(std.testing.allocator, .x86_64, "6.1.155");
    defer std.testing.allocator.free(x86);
    try std.testing.expectEqualStrings("sporevm-x86_64-linux-6.1.155-bzImage", x86);
    const arm = try managedRunKernelAssetNameFor(std.testing.allocator, .aarch64, "6.1.155");
    defer std.testing.allocator.free(arm);
    try std.testing.expectEqualStrings("sporevm-arm64-linux-6.1.155-Image", arm);
    const allocator = std.testing.allocator;
    const asset = try managedRunKernelAssetName(allocator, "6.1.155");
    defer allocator.free(asset);
    const native_expected = if (builtin.cpu.arch == .x86_64)
        "sporevm-x86_64-linux-6.1.155-bzImage"
    else
        "sporevm-arm64-linux-6.1.155-Image";
    try std.testing.expectEqualStrings(native_expected, asset);

    const config_asset = try managedRunKernelConfigAssetName(allocator, asset);
    defer allocator.free(config_asset);
    const native_config_expected = if (builtin.cpu.arch == .x86_64)
        "sporevm-x86_64-linux-6.1.155-bzImage.config"
    else
        "sporevm-arm64-linux-6.1.155-Image.config";
    try std.testing.expectEqualStrings(native_config_expected, config_asset);

    try std.testing.expectError(error.BadManagedKernelVersion, managedRunKernelAssetName(allocator, "../bad"));
}

test "managed kernel release defaults are architecture specific" {
    try std.testing.expectEqualStrings("v0.7.0", defaultManagedKernelReleaseFor(.x86_64));
    try std.testing.expectEqualStrings("v0.6.3", defaultManagedKernelReleaseFor(.aarch64));
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

    const expected = try readExpectedSha256Digest(io, allocator, sha_path, "Image", false);
    const expected_hex = std.fmt.bytesToHex(expected, .lower);
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &expected_hex);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = sha_path, .data = "not-a-sha\n" });
    try std.testing.expectError(error.BadManagedKernelChecksum, readExpectedSha256Digest(io, allocator, sha_path, "Image", false));
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = sha_path,
        .data = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA  Image\n",
    });
    try std.testing.expectError(error.BadManagedKernelChecksum, readExpectedSha256Digest(io, allocator, sha_path, "Image", false));
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = sha_path,
        .data = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  Other\n",
    });
    try std.testing.expectError(error.BadManagedKernelChecksum, readExpectedSha256Digest(io, allocator, sha_path, "Image", false));
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = sha_path,
        .data = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  Image extra\n",
    });
    try std.testing.expectError(error.BadManagedKernelChecksum, readExpectedSha256Digest(io, allocator, sha_path, "Image", false));
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
            "CONFIG_VIRTIO_BLK=y\n" ++
            "CONFIG_EXT4_FS=y\n" ++
            "CONFIG_JBD2=y\n" ++
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
            "CONFIG_EXT4_FS_SECURITY=y\n" ++
            "CONFIG_MEMORY_HOTPLUG=y\n" ++
            "CONFIG_MEMORY_HOTPLUG_DEFAULT_ONLINE=y\n" ++
            "CONFIG_MEMORY_HOTREMOVE=y\n" ++
            "CONFIG_CONTIG_ALLOC=y\n" ++
            "CONFIG_EXCLUSIVE_SYSTEM_RAM=y\n" ++
            "CONFIG_VIRTIO_MEM=y\n" ++
            "CONFIG_X86_64=y\n" ++
            "CONFIG_SMP=y\n" ++
            "CONFIG_X86_LOCAL_APIC=y\n" ++
            "CONFIG_X86_IO_APIC=y\n" ++
            "CONFIG_X86_MPPARSE=y\n" ++
            "CONFIG_HYPERVISOR_GUEST=y\n" ++
            "CONFIG_PARAVIRT=y\n" ++
            "CONFIG_PARAVIRT_CLOCK=y\n" ++
            "CONFIG_KVM_GUEST=y\n" ++
            "CONFIG_RELOCATABLE=y\n" ++
            "CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES=y\n" ++
            "CONFIG_DEVMEM=y\n" ++
            "CONFIG_STRICT_DEVMEM=y\n",
    });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = bad_sha_path, .data = "not-a-sha\n" });

    try std.testing.expect(!try managedKernelCacheHit(io, allocator, image_path, sha_path, config_path, "Image"));
    try chmodFileReadOnly(allocator, image_path);
    try std.testing.expect(!try managedKernelCacheHit(io, allocator, image_path, sha_path, config_path, "Image"));
    try chmodFileReadOnly(allocator, sha_path);
    try std.testing.expect(!try managedKernelCacheHit(io, allocator, image_path, sha_path, config_path, "Image"));
    try chmodFileReadOnly(allocator, config_path);
    try std.testing.expect(try managedKernelCacheHit(io, allocator, image_path, sha_path, config_path, "Image"));

    // Identity-only cache hits do not read the large Image. An executor miss
    // verifies the exact opened bytes before boot; see the materialization test.
    try chmodFileWritable(allocator, image_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = image_path, .data = "tampered kernel bytes" });
    try chmodFileReadOnly(allocator, image_path);
    try std.testing.expect(try managedKernelCacheHit(io, allocator, image_path, sha_path, config_path, "Image"));

    try chmodFileReadOnly(allocator, bad_sha_path);
    try std.testing.expect(!try managedKernelCacheHit(io, allocator, image_path, bad_sha_path, config_path, "Image"));

    // A writable image is not trusted, and missing required config symbols
    // still miss so a newer binary re-fetches a suitable kernel.
    try chmodFileWritable(allocator, image_path);
    try std.testing.expect(!try managedKernelCacheHit(io, allocator, image_path, sha_path, config_path, "Image"));
    try chmodFileReadOnly(allocator, image_path);
    const sparse_config_path = tmp ++ "/Image.sparse.config";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = sparse_config_path, .data = "CONFIG_FILE_LOCKING=y\n" });
    try chmodFileReadOnly(allocator, sparse_config_path);
    try std.testing.expect(!try managedKernelCacheHit(io, allocator, image_path, sha_path, sparse_config_path, "Image"));
}

test "managed monitor boot materialization verifies and retains opened kernel bytes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-run-managed-boot-materialization";
    Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try ensureDirPath(io, tmp);
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};

    const image_path = tmp ++ "/Image";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = image_path, .data = "kernel bytes" });
    try chmodFileReadOnly(allocator, image_path);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash("kernel bytes", &digest, .{});
    const descriptor = ManagedMonitorBootDescriptor{
        .kernel_path = image_path,
        .kernel_sha256 = digest,
        .initrd_sha256 = embedded_run_initrd_sha256,
    };
    const boot = try materializeManagedMonitorBootArtifacts(io, allocator, descriptor);
    defer allocator.free(boot.kernel);
    try std.testing.expectEqualStrings("kernel bytes", boot.kernel);
    try std.testing.expect(boot.initrd.ptr == embedded_run_initrd.ptr);

    try chmodFileWritable(allocator, image_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = image_path, .data = "changed kernel bytes" });
    try chmodFileReadOnly(allocator, image_path);
    try std.testing.expectError(
        error.ManagedKernelChecksumMismatch,
        materializeManagedMonitorBootArtifacts(io, allocator, descriptor),
    );
}

test "managed run kernel config requires rootfs, Docker, and virtio-mem runtime symbols" {
    const allocator = std.testing.allocator;
    const good_config =
        "# CONFIG_DEVMEM is not set\n" ++
        "CONFIG_FILE_LOCKING=y\n" ++
        "CONFIG_CGROUPS=y\n" ++
        "CONFIG_HW_RANDOM=y\n" ++
        "CONFIG_HW_RANDOM_VIRTIO=y\n" ++
        "CONFIG_VIRTIO_BLK=y\n" ++
        "CONFIG_EXT4_FS=y\n" ++
        "CONFIG_JBD2=y\n" ++
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
        "CONFIG_EXT4_FS_SECURITY=y\n" ++
        "CONFIG_MEMORY_HOTPLUG=y\n" ++
        "CONFIG_MEMORY_HOTPLUG_DEFAULT_ONLINE=y\n" ++
        "CONFIG_MEMORY_HOTREMOVE=y\n" ++
        "CONFIG_CONTIG_ALLOC=y\n" ++
        "CONFIG_EXCLUSIVE_SYSTEM_RAM=y\n" ++
        "CONFIG_VIRTIO_MEM=y\n";

    try std.testing.expect(try missingManagedRunKernelConfigSymbolFor(allocator, .aarch64, good_config) == null);

    const missing_virtio_blk = try std.mem.replaceOwned(
        u8,
        allocator,
        good_config,
        "CONFIG_VIRTIO_BLK=y",
        "# CONFIG_VIRTIO_BLK is not set",
    );
    defer allocator.free(missing_virtio_blk);
    const missing_rootfs_symbol = (try missingManagedRunKernelConfigSymbolFor(allocator, .aarch64, missing_virtio_blk)).?;
    defer allocator.free(missing_rootfs_symbol);
    try std.testing.expectEqualStrings("CONFIG_VIRTIO_BLK", missing_rootfs_symbol);

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
        "CONFIG_EXT4_FS_SECURITY=y\n" ++
        "CONFIG_MEMORY_HOTPLUG=y\n" ++
        "CONFIG_MEMORY_HOTPLUG_DEFAULT_ONLINE=y\n" ++
        "CONFIG_MEMORY_HOTREMOVE=y\n" ++
        "CONFIG_CONTIG_ALLOC=y\n" ++
        "CONFIG_EXCLUSIVE_SYSTEM_RAM=y\n" ++
        "CONFIG_VIRTIO_MEM=y\n";
    const missing = (try missingManagedRunKernelConfigSymbolFor(allocator, .aarch64, missing_file_locking)).?;
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
        "CONFIG_EXT4_FS_SECURITY=y\n" ++
        "CONFIG_MEMORY_HOTPLUG=y\n" ++
        "CONFIG_MEMORY_HOTPLUG_DEFAULT_ONLINE=y\n" ++
        "CONFIG_MEMORY_HOTREMOVE=y\n" ++
        "CONFIG_CONTIG_ALLOC=y\n" ++
        "CONFIG_EXCLUSIVE_SYSTEM_RAM=y\n" ++
        "CONFIG_VIRTIO_MEM=y\n";
    const module_missing = (try missingManagedRunKernelConfigSymbolFor(allocator, .aarch64, module_value)).?;
    defer allocator.free(module_missing);
    try std.testing.expectEqualStrings("CONFIG_FILE_LOCKING", module_missing);
}

test "managed x86 kernel config enforces the frozen direct boot profile" {
    var buffer: [8192]u8 = undefined;
    var used: usize = 0;
    for (managed_run_kernel_required_config_symbols ++ managed_x86_kernel_required_config_symbols) |symbol| {
        const line = try std.fmt.bufPrint(buffer[used..], "{s}=y\n", .{symbol});
        used += line.len;
    }
    for (managed_x86_kernel_forbidden_config_symbols) |symbol| {
        const line = try std.fmt.bufPrint(buffer[used..], "# {s} is not set\n", .{symbol});
        used += line.len;
    }
    try std.testing.expect(try missingManagedRunKernelConfigSymbolFor(std.testing.allocator, .x86_64, buffer[0..used]) == null);

    const enabled = try std.fmt.bufPrint(buffer[used..], "CONFIG_ACPI=y\n", .{});
    used += enabled.len;
    const forbidden = (try missingManagedRunKernelConfigSymbolFor(std.testing.allocator, .x86_64, buffer[0..used])).?;
    defer std.testing.allocator.free(forbidden);
    try std.testing.expectEqualStrings("CONFIG_ACPI", forbidden);
}
