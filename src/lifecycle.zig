//! Named VM lifecycle orchestration: create, restore, exec, copy, save, fork,
//! remove, list and initial output. The commands are in lifecycle_cli.zig.

const std = @import("std");
const TestDir = @import("test_dir.zig").TestDir;
const chunk_sealer = @import("chunk_sealer.zig");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;

const Context = @import("context.zig").Context;
const local_paths = @import("local_paths.zig");
const machine_output = @import("machine_output.zig");
const manifest_test_support = @import("manifest_test_support.zig");
const test_support = @import("test_support.zig");
const memory_config = @import("memory.zig");
const monitor_protocol = @import("monitor_protocol.zig");
const ExecNamedStream = monitor_protocol.ExecNamedStream;
const rootfs_cache = @import("rootfs_cache.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const rootfs_mod = @import("rootfs.zig");
const resource = @import("resource.zig");
const runtime_disk_claim = @import("runtime_disk_claim.zig");
const runtime_disk = @import("runtime_disk.zig");
const runtime_disk_fork_control = @import("runtime_disk_fork_control.zig");
const runtime_disk_lease = @import("runtime_disk_lease.zig");
const saved_spore_pin = @import("saved_spore_pin.zig");
const saved_spore_ownership = @import("saved_spore_ownership.zig");
const saved_spore_remove = @import("saved_spore_remove.zig");
const attach_mod = @import("attach.zig");
const backend_mod = @import("backend.zig");
const rootfs_input = @import("rootfs_input.zig");
const spore = @import("spore.zig");
const spore_fork = @import("spore_fork.zig");
const spore_net_policy = @import("spore_net_policy.zig");
const spore_stream = @import("spore_stream.zig");
const system = @import("system.zig");
const test_barrier = @import("test_barrier.zig");
const topology = @import("topology.zig");
const version = @import("version.zig");
const vm_registry = @import("vm_registry.zig");
const vm_session = @import("vm_session.zig");

pub const runtime_dir_env = local_paths.runtime_dir_env;

// Registry names that lifecycle code and its callers still reach through
// this module.
pub const max_name_len = vm_registry.max_name_len;
pub const Paths = vm_registry.Paths;
pub const Spec = vm_registry.Spec;
pub const DiskForkClaim = vm_registry.DiskForkClaim;
pub const Ready = vm_registry.Ready;
pub const CreateTiming = vm_registry.CreateTiming;
pub const MonitorTiming = vm_registry.MonitorTiming;
pub const MonitorStats = vm_registry.MonitorStats;
pub const VmState = vm_registry.VmState;
pub const max_control_socket_path_len = vm_registry.max_control_socket_path_len;
pub const clearLastError = vm_registry.clearLastError;
pub const lastErrorMessage = vm_registry.lastErrorMessage;
pub const validateName = vm_registry.validateName;
pub const validateControlSocketPath = vm_registry.validateControlSocketPath;
pub const validateControlSocketOwner = vm_registry.validateControlSocketOwner;
pub const runtimeRootPath = vm_registry.runtimeRootPath;
pub const pathsFor = vm_registry.pathsFor;
pub const pathsFromRoot = vm_registry.pathsFromRoot;
pub const readSpec = vm_registry.readSpec;
pub const writeSpec = vm_registry.writeSpec;
pub const readReady = vm_registry.readReady;
pub const writeReady = vm_registry.writeReady;
pub const writeCreateTiming = vm_registry.writeCreateTiming;
pub const writeMonitorStats = vm_registry.writeMonitorStats;
pub const readPid = vm_registry.readPid;
pub const writePid = vm_registry.writePid;
const max_metadata_bytes = vm_registry.max_metadata_bytes;
const setLastError = vm_registry.setLastError;
const validateSpec = vm_registry.validateSpec;
const readMonitorStats = vm_registry.readMonitorStats;
const pathExists = vm_registry.pathExists;
const openDirPath = vm_registry.openDirPath;
const ensureDirPath = vm_registry.ensureDirPath;
const requirePrivateDir = vm_registry.requirePrivateDir;
const validateExistingRuntimeDirs = vm_registry.validateExistingRuntimeDirs;
const claimControlSocketPath = vm_registry.claimControlSocketPath;
const releaseControlSocketPath = vm_registry.releaseControlSocketPath;
const deleteVmState = vm_registry.deleteVmState;

const lifecycle_spore_metadata_file = "sporevm-lifecycle.json";
const diskless_resume_device_count = 4;
const monitor_shutdown_grace_ms = 1_000;
const monitor_shutdown_term_ms = 1_000;
const monitor_shutdown_kill_ms = 1_000;

const testing = if (builtin.is_test) struct {
    var named_restore_authority_barrier: ?*test_barrier.Barrier = null;
    var create_rootfs_barrier: ?*test_barrier.Barrier = null;
    var fork_source_read_barrier: ?*test_barrier.Barrier = null;
} else struct {};

const darwin_process = if (builtin.os.tag.isDarwin()) struct {
    const proc_pid_task_info: c_int = 4;

    const TaskInfo = extern struct {
        virtual_size: u64,
        resident_size: u64,
        total_user: u64,
        total_system: u64,
        threads_user: u64,
        threads_system: u64,
        policy: i32,
        faults: i32,
        pageins: i32,
        cow_faults: i32,
        messages_sent: i32,
        messages_received: i32,
        syscalls_mach: i32,
        syscalls_unix: i32,
        csw: i32,
        threadnum: i32,
        numrunning: i32,
        priority: i32,
    };

    extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, buffersize: c_int) c_int;
} else struct {};

pub const ExecDefaults = spore.ExecDefaults;

pub const ListEntry = struct {
    resource_type: resource.Type = .live_vm,
    name: []const u8,
    state: []const u8,
    pid: ?i64 = null,
    memory: ?ListMemory = null,
    stats: ListStats = .{},
};

pub const ListMemory = struct {
    initial_bytes: u64,
    maximum_bytes: u64,
};

pub const ListStats = struct {
    resident_bytes: ?u64 = null,
    backing_logical_bytes: ?u64 = null,
    backing_allocated_bytes: ?u64 = null,
    chunk_size: ?u64 = null,
    chunks_total: ?u64 = null,
    chunks_nonzero: ?u64 = null,
    dirty_chunks_pending: ?u64 = null,
};

const ListMetadata = struct {
    memory: ListMemory,
    stats: ListStats,
};

pub const lifecycle_schema = "spore.lifecycle.v1";
pub const lifecycle_schema_version: u32 = 1;

pub const NamedForkResult = struct {
    schema: []const u8 = "spore.lifecycle.fork.result.v1",
    schema_version: u32 = 1,
    resource_type: resource.Type = .live_vm,
    source: []const u8,
    count: usize,
    children: []const []const u8,
    ram_capture_ms: ?u64 = null,
    disk_fork_ms: ?u64 = null,
    source_pause_ms: ?u64 = null,
    child_ready_ms: ?u64 = null,
};

pub const ForkNamedOptions = struct {
    source_name: []const u8,
    count: usize,
    name_pattern: []const u8,
    allow_slow_copy: bool = false,
    spore_executable: []const u8 = "spore",
    /// Start monitors with `--debug`.
    debug: bool = false,
};

pub const InitialOutputDisposition = enum {
    retain,
    discard,

    pub fn parse(raw: []const u8) ?InitialOutputDisposition {
        if (std.mem.eql(u8, raw, "retain")) return .retain;
        if (std.mem.eql(u8, raw, "discard")) return .discard;
        return null;
    }
};

pub const InitialOutputDestination = enum {
    named_logs,
};

pub const InitialCommandStartupStatus = enum {
    started,
};

pub const InitialCommandProcessStatus = enum {
    running,
    exited,
};

pub const InitialCommandResult = struct {
    output_disposition: InitialOutputDisposition,
    output_destination: ?InitialOutputDestination = null,
    output_limit_bytes_per_stream: ?u32 = null,
    startup_status: InitialCommandStartupStatus = .started,
    process_status: ?InitialCommandProcessStatus = null,
    exit_code: ?u8 = null,
    stdout: ?[]u8 = null,
    stderr: ?[]u8 = null,
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
};

pub const CreateNamedOptions = struct {
    name: []const u8,
    backend: backend_mod.Backend = .auto,
    kernel_path: ?[]const u8 = null,
    initrd_path: ?[]const u8 = null,
    rootfs_path: ?[]const u8 = null,
    image_ref: ?[]const u8 = null,
    image_pull_policy: rootfs_input.PullPolicy = .missing,
    /// Optional caller command. Image-backed creates prepend OCI Entrypoint;
    /// when omitted they use OCI Entrypoint and Cmd. Non-image creates remain idle.
    initial_command: []const []const u8 = &.{},
    network: spore_net_policy.Network = .disabled,
    memory: memory_config.Config = .{},
    vcpus: topology.VcpuCount = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    console_log_path: ?[]const u8 = null,
    initial_output: InitialOutputDisposition = .retain,
    spore_executable: []const u8 = "spore",
    /// Start the monitor with `--debug`.
    debug: bool = false,
    annotations: spore.Annotations = .{},
};

pub const RestoreNamedOptions = struct {
    spore_dir: []const u8,
    name: []const u8,
    backend: ?backend_mod.Backend = null,
    generation_path: ?[]const u8 = null,
    spore_executable: []const u8 = "spore",
    /// Start the monitor with `--debug`.
    debug: bool = false,
    bound_services: []const spore_net_policy.BoundServiceBinding = &.{},
};

pub const ExecNamedOptions = struct {
    name: []const u8,
    command: []const []const u8,
    guest_env: []const []const u8 = &.{},
    guest_working_dir: ?[]const u8 = null,
};

pub const CopyNamedOptions = struct {
    name: []const u8,
    host_path: []const u8,
    guest_path: []const u8,
};

pub const InitialOutputNamedOptions = struct {
    name: []const u8,
};

const SaveContinueNamedOptions = struct {
    name: []const u8,
    out_dir: []const u8,
    annotations: spore.Annotations = .{},
};

pub const SaveNamedOptions = struct {
    name: []const u8,
    out_dir: []const u8,
    stop: bool = false,
    annotations: spore.Annotations = .{},
};

pub const RemoveNamedOptions = struct {
    name: []const u8,
};

pub const ListNamedOptions = struct {};

pub const NamedLifecycleResult = struct {
    schema: []const u8 = lifecycle_schema,
    schema_version: u32 = lifecycle_schema_version,
    resource_type: resource.Type = .live_vm,
    action: []const u8,
    name: []const u8,
    state: []const u8,
    pid: ?i64 = null,
    console_log_path: ?[]const u8 = null,
    spore_dir: ?[]const u8 = null,
    saved_sessions: ?usize = null,
    ownership: ?[]const u8 = null,
    timing: ?NamedLifecycleTiming = null,
    initial_command: ?InitialCommandResult = null,
};

pub const NamedLifecycleTiming = struct {
    prepare_ms: u64,
    spawn_monitor_ms: u64,
    wait_exec_ready_ms: u64,
    total_ms: u64,
};

pub const NamedListResult = struct {
    schema: []const u8 = "spore.lifecycle.list.result.v2",
    schema_version: u32 = 2,
    entries: []const ListEntry,
};

pub const ExecNamedResult = struct {
    schema: []const u8 = "spore.exec.result.v1",
    schema_version: u32 = 1,
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
};

/// Per-stream limit for output the monitor retains for `start` and
/// `initial-output`. Use `openExecNamedStream` for streamed command output.
pub const exec_named_capture_limit = 16 * 1024;
pub const initial_output_protocol_header_len = 3;
pub const initial_output_limit_bytes_per_stream: u32 = exec_named_capture_limit - initial_output_protocol_header_len;

pub const TerminalSize = spore_stream.Resize;

pub const ExecNamedStreamOptions = struct {
    name: []const u8,
    command: []const []const u8,
    guest_env: []const []const u8 = &.{},
    guest_working_dir: ?[]const u8 = null,
    interactive: bool = false,
    tty: bool = false,
    terminal_size: TerminalSize = .{ .rows = 24, .cols = 80 },
};

/// The live policy a monitor reads, encoded next to the manifest form that a
/// save records.
fn specNetworkPolicy(arena: std.mem.Allocator, network: *const spore_net_policy.Network) !?[]const u8 {
    return switch (network.*) {
        .disabled => null,
        .spore => |*policy| try spore_net_policy.encodeArgAlloc(arena, policy),
    };
}

const CreateTimingAnchors = struct {
    start_ms: u64,
    parsed_ms: u64,
};

pub fn createNamedWithTiming(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    host: backend_mod.Host,
    options: CreateNamedOptions,
    timing: CreateTimingAnchors,
) !NamedLifecycleResult {
    clearLastError();
    if (options.rootfs_path != null and options.image_ref != null) return error.InvalidRootfsInput;
    const selected_backend = try backend_mod.select(options.backend, host);
    try vm_session.validateFreshProductPolicy(selected_backend, .{
        .memory = options.memory,
        .vcpus = options.vcpus,
    });
    try topology.validateVcpuCount(options.vcpus);
    try spore.validateAnnotations(options.annotations);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var spec = Spec{
        .name = options.name,
        .backend = options.backend.name(),
        .kernel_path = options.kernel_path,
        .initrd_path = options.initrd_path,
        .rootfs_path = options.rootfs_path,
        .image_ref = options.image_ref,
        .network = try spore_net_policy.manifestNetworkFromOptions(arena, &options.network),
        .network_policy = try specNetworkPolicy(arena, &options.network),
        .memory = options.memory,
        .vcpus = options.vcpus,
        .guest_port = options.guest_port,
        .timeout_ms = options.timeout_ms,
        .console_log_path = options.console_log_path,
        .annotations = options.annotations,
    };
    const paths = try apiPaths(.{ .io = init.io, .environ_map = init.environ_map }, arena, spec.name);
    const paths_ms = monotonicMs();
    // Fail fast on a taken name, but claim it only once the image is ready,
    // so a pull that is interrupted leaves no entry behind.
    const prior = try vm_registry.probe(init.io, paths);
    if (prior != .absent) return namedVmExists(arena, init.io, paths, "create", spec.name, prior);
    const state_checked_ms = monotonicMs();

    if (comptime builtin.is_test) if (testing.create_rootfs_barrier) |barrier| barrier.pause(init.io);
    const rootfs = try rootfs_input.resolveRootfsInputDetailed(init, arena, .{
        .rootfs_path = spec.rootfs_path,
        .image_ref = spec.image_ref,
        .pull_policy = options.image_pull_policy,
        .command_name = "create",
        .record_artifact = spec.rootfs_path != null or spec.image_ref != null,
    });
    if (spec.memory.isElastic()) {
        const managed_kernel = spec.kernel_path == null and init.environ_map.get("SPOREVM_KERNEL_IMAGE") == null;
        const managed_initrd = spec.initrd_path == null and init.environ_map.get("SPOREVM_RUN_INITRD") == null;
        if (!managed_kernel or !managed_initrd) return error.ElasticMemoryUnsupported;
    }
    const initial_command: ?[]const []const u8 = if (options.image_ref != null)
        try rootfs_input.resolveImageRuntimeCommand(arena, rootfs.image_config, options.initial_command)
    else if (options.initial_command.len != 0)
        options.initial_command
    else
        null;
    const rootfs_resolved_ms = monotonicMs();
    spec.rootfs_path = if (rootfs.path) |path| try std.fs.path.resolve(arena, &.{path}) else null;
    spec.rootfs = rootfs.rootfs;
    spec.exec_defaults = if (rootfs.guest_env.len != 0 or rootfs.guest_working_dir != null) .{
        .env = rootfs.guest_env,
        .working_dir = rootfs.guest_working_dir,
    } else null;
    const rootfs_abspath_ms = monotonicMs();

    var claim = try claimName(arena, init.io, paths, "create");
    var claimed = true;
    defer if (claimed) claim.abandon(init.io, paths);
    try spawnMonitorExecutable(init, arena, paths, &claim, spec, options.spore_executable, options.debug);
    claimed = false;
    const monitor_spawned_ms = monotonicMs();
    try waitForReadyResult(arena, init.io, paths, spec.timeout_ms, options.spore_executable);
    const ready_ms = monotonicMs();
    writeCreateTiming(arena, init.io, paths, .{
        .parse_ms = timing.parsed_ms - timing.start_ms,
        .paths_ms = paths_ms - timing.parsed_ms,
        .state_check_ms = state_checked_ms - paths_ms,
        .rootfs_resolve_ms = rootfs_resolved_ms - state_checked_ms,
        .rootfs_abspath_ms = rootfs_abspath_ms - rootfs_resolved_ms,
        .spawn_monitor_ms = monitor_spawned_ms - rootfs_abspath_ms,
        .wait_ready_ms = ready_ms - monitor_spawned_ms,
        .total_ms = ready_ms - timing.start_ms,
    }) catch {};

    const context = Context{ .io = init.io, .environ_map = init.environ_map };
    var ready = readReady(arena, init.io, paths) catch |err| {
        if (initial_command != null) return rollbackCreatedNamedAfterFailure(context, arena, paths, spec.name, err);
        return err;
    };
    defer ready.deinit();
    const result = ownedNamedLifecycleResult(allocator, .{
        .action = "created",
        .name = spec.name,
        .state = "ready",
        .pid = ready.value.pid,
        .console_log_path = ready.value.console_log_path,
        .timing = .{
            .prepare_ms = rootfs_abspath_ms - timing.start_ms,
            .spawn_monitor_ms = monitor_spawned_ms - rootfs_abspath_ms,
            .wait_exec_ready_ms = ready_ms - monitor_spawned_ms,
            .total_ms = ready_ms - timing.start_ms,
        },
        .initial_command = if (initial_command != null) .{
            .output_disposition = options.initial_output,
            .output_destination = if (options.initial_output == .retain) .named_logs else null,
            .output_limit_bytes_per_stream = if (options.initial_output == .retain) initial_output_limit_bytes_per_stream else null,
        } else null,
    }) catch |err| {
        if (initial_command != null) return rollbackCreatedNamedAfterFailure(context, arena, paths, spec.name, err);
        return err;
    };
    errdefer deinitNamedLifecycleResult(allocator, result);
    if (initial_command) |command| {
        const initial = startNamed(context, allocator, .{
            .name = spec.name,
            .command = command,
        }, options.initial_output == .retain) catch |err| {
            return rollbackCreatedNamedAfterFailure(context, arena, paths, spec.name, err);
        };
        defer deinitExecNamedResult(allocator, initial);
        if (initial.exit_code != 0) {
            setLastError(
                "named VM {s} initial command startup failed (status {d}); output disposition={s}, destination={s}; the VM was removed",
                .{
                    spec.name,
                    initial.exit_code,
                    @tagName(options.initial_output),
                    if (options.initial_output == .retain) "named_logs (unavailable after removal)" else "none",
                },
            );
            return rollbackCreatedNamedAfterFailure(context, arena, paths, spec.name, error.InitialCommandFailed);
        }
    }
    return result;
}

fn rollbackCreatedNamedAfterFailure(context: Context, allocator: std.mem.Allocator, paths: Paths, name: []const u8, failure: anyerror) anyerror {
    _ = removeNamedAtPaths(context, allocator, paths) catch |err| {
        setLastError(
            "named VM {s} initial command failed and automatic removal failed ({s}); remove it manually",
            .{ name, @errorName(err) },
        );
        return error.InitialCommandRollbackFailed;
    };
    if (lastErrorMessage().len == 0) {
        setLastError("named VM {s} initial command failed ({s}); the VM was removed", .{ name, @errorName(failure) });
    }
    return failure;
}

pub fn restoreNamed(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: RestoreNamedOptions,
) !NamedLifecycleResult {
    const start_ms = monotonicMs();
    clearLastError();
    const requested_backend = options.backend orelse backend_mod.Backend.auto;
    const selected_backend = try requested_backend.resolveForHost();
    try vm_session.validateFreshProductPolicy(selected_backend, .{
        .memory = .{},
        .vcpus = 1,
        .resuming = true,
    });
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const spore_dir = try resolveExistingSporeDirApi(arena, init.io, options.spore_dir);
    const parsed_manifest = spore.loadManifest(arena, spore_dir) catch |err| switch (err) {
        error.FormatTooOld => return error.FormatTooOld,
        else => return error.InvalidSporeDir,
    };
    defer parsed_manifest.deinit();
    const manifest = parsed_manifest.value;
    const network = spore_net_policy.networkFromManifestWithBindings(arena, manifest.network, options.bound_services) catch |err| switch (err) {
        error.MissingBoundServiceBinding,
        error.UnexpectedBoundServiceBinding,
        error.DuplicateBoundServiceBinding,
        error.InvalidBoundService,
        error.InvalidBoundServiceTarget,
        error.UnsupportedBoundServiceTarget,
        => return err,
        else => return error.InvalidNetworkPolicy,
    };
    const rootfs = try rootfs_input.resumeRootfsForRun(arena, manifest);
    const disk = try rootfs_input.resumeDiskForRun(arena, manifest);
    if (rootfs == null and manifest.devices.len != diskless_resume_device_count) return error.UnsupportedLifecycleDeviceModel;
    const resume_generation = if (options.generation_path) |path| blk: {
        const params = attach_mod.loadGenerationParams(init.io, arena, path) catch |err| switch (err) {
            error.BadGenerationPayload => return error.BadGenerationPayload,
            error.StreamTooLong => return error.GenerationPayloadTooLarge,
            error.FileNotFound => return error.GenerationFileNotFound,
            else => return error.GenerationFileInvalid,
        };
        break :blk try attach_mod.prepareRestoreGenerationState(arena, manifest.generation, params);
    } else null;
    const memory = spore.memoryConfig(manifest.platform.ram_size, manifest.memory_state) catch return error.InvalidMemorySize;

    var lifecycle_spec = readSporeLifecycleSpec(arena, init.io, spore_dir) catch return error.InvalidLifecycleMetadata;
    defer if (lifecycle_spec) |*spec| spec.deinit();
    if (lifecycle_spec) |spec| {
        if (spec.value.vcpus != manifest.platform.vcpu_count) return error.UnsupportedLifecycleMetadata;
    }

    const base = if (lifecycle_spec) |spec| spec.value else Spec{ .name = options.name };
    var disk_handoff: ?SavedDiskLeaseHandoff = if (disk) |saved_disk|
        try leaseForSavedDisk(init.io, arena, init.environ_map, spore_dir, saved_disk)
    else
        null;
    defer if (disk_handoff) |*handoff| if (handoff.active) |*active| active.deinit();
    const spec = Spec{
        .name = options.name,
        .backend = if (options.backend) |backend| backend.name() else base.backend,
        .kernel_path = base.kernel_path,
        .initrd_path = base.initrd_path,
        .resume_dir = spore_dir,
        .resume_generation = resume_generation,
        .rootfs = rootfs,
        .disk = disk,
        .disk_baseline_lease = if (disk_handoff) |handoff| handoff.lease else base.disk_baseline_lease,
        .network = try spore_net_policy.manifestNetworkFromOptions(arena, &network),
        .network_policy = try specNetworkPolicy(arena, &network),
        .annotations = manifest.annotations,
        .sessions = manifest.sessions,
        .exec_defaults = manifest.exec_defaults orelse base.exec_defaults,
        .memory = memory,
        .vcpus = manifest.platform.vcpu_count,
        .guest_port = base.guest_port,
        .timeout_ms = base.timeout_ms,
        // Saved lifecycle metadata is part of the spore input and must not
        // authorize truncating an arbitrary host path during restore.
        .console_log_path = restoreConsoleLogPath(base.console_log_path),
    };
    if (!monitorBackendSupported(spec.backend)) return error.HostUnsupported;

    const paths = try apiPaths(.{ .io = init.io, .environ_map = init.environ_map }, arena, spec.name);
    var claim = try claimName(arena, init.io, paths, "restore");
    var claimed = true;
    defer if (claimed) claim.abandon(init.io, paths);

    const prepared_ms = monotonicMs();
    try spawnMonitorExecutable(init, arena, paths, &claim, spec, options.spore_executable, options.debug);
    claimed = false;
    const monitor_spawned_ms = monotonicMs();
    try waitForReadyResult(arena, init.io, paths, spec.timeout_ms, options.spore_executable);
    const ready_ms = monotonicMs();

    var ready = try readReady(arena, init.io, paths);
    defer ready.deinit();
    return ownedNamedLifecycleResult(allocator, .{
        .action = "restored",
        .name = spec.name,
        .state = "ready",
        .pid = ready.value.pid,
        .console_log_path = ready.value.console_log_path,
        .spore_dir = spore_dir,
        .timing = .{
            .prepare_ms = prepared_ms - start_ms,
            .spawn_monitor_ms = monitor_spawned_ms - prepared_ms,
            .wait_exec_ready_ms = ready_ms - monitor_spawned_ms,
            .total_ms = ready_ms - start_ms,
        },
    });
}

fn restoreConsoleLogPath(_: ?[]const u8) ?[]const u8 {
    return null;
}

const SavedDiskLeaseHandoff = struct {
    lease: runtime_disk_lease.Lease,
    active: ?runtime_disk_lease.Active = null,
};

fn leaseForSavedDisk(io: Io, allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, spore_dir: []const u8, disk: spore.Disk) !SavedDiskLeaseHandoff {
    const cache_root = try local_paths.rootfsCacheRootPath(allocator, environ);
    var cache_lock = try rootfs_mod.lockRootfsCacheExclusive(io, allocator, cache_root);
    defer cache_lock.deinit();
    const registry = try saved_spore_pin.LockedRegistry.init(allocator, cache_root, &cache_lock);
    var parsed = try saved_spore_pin.loadForSporeLocked(io, allocator, registry, spore_dir, disk);
    defer parsed.deinit();
    const lease = runtime_disk_lease.Lease{
        .root = cache_root,
        .baseline_kind = .disk_index,
        .baseline_identity = disk.base,
        .rootfs_storage = try runtime_disk.storageFromSnapshotDisk(allocator, disk),
    };
    const runtime_root = try local_paths.runtimeRootPath(allocator, environ);
    const active = try runtime_disk_lease.acquireActive(io, allocator, runtime_root, lease);
    if (comptime builtin.is_test) if (testing.named_restore_authority_barrier) |barrier| barrier.pause(io);
    return .{ .lease = lease, .active = active };
}

pub fn openExecNamedStream(
    context: Context,
    allocator: std.mem.Allocator,
    options: ExecNamedStreamOptions,
) !ExecNamedStream {
    clearLastError();
    if (options.command.len == 0) return error.InvalidGuestCommand;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths = try apiPaths(context, arena, options.name);
    const state = try vm_registry.probe(context.io, paths);
    if (state != .ready) return namedVmNotReady(arena, context.io, paths, "exec-stream", options.name, state);
    var ready = try readReady(arena, context.io, paths);
    defer ready.deinit();
    return openExecNamedStreamAt(context, arena, ready.value.control_socket_path, options);
}

pub fn rejectX86NamedCopy() !void {
    if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
        return error.X86NamedCopyUnsupported;
    }
}

pub fn openCopyNamedStream(
    context: Context,
    allocator: std.mem.Allocator,
    options: CopyNamedOptions,
    direction: CopyDirection,
) !ExecNamedStream {
    clearLastError();
    try rejectX86NamedCopy();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths = try apiPaths(context, arena, options.name);
    const state = try vm_registry.probe(context.io, paths);
    if (state != .ready) return namedVmNotReady(arena, context.io, paths, "copy", options.name, state);
    var ready = try readReady(arena, context.io, paths);
    defer ready.deinit();
    const request: monitor_protocol.Request = switch (direction) {
        .in => .{ .copy_in = .{ .path = options.guest_path } },
        .out => .{ .copy_out = .{ .path = options.guest_path } },
    };
    return monitor_protocol.openStream(arena, context.io, ready.value.control_socket_path, request);
}

fn startNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: ExecNamedOptions,
    retain_output: bool,
) !ExecNamedResult {
    clearLastError();
    if (options.command.len == 0) return error.InvalidGuestCommand;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths = try apiPaths(context, arena, options.name);
    const state = try vm_registry.probe(context.io, paths);
    if (state != .ready) return namedVmNotReady(arena, context.io, paths, "start", options.name, state);
    var ready = try readReady(arena, context.io, paths);
    defer ready.deinit();
    const response = try monitor_protocol.call(arena, context.io, ready.value.control_socket_path, .{ .start = .{
        .argv = options.command,
        .env = options.guest_env,
        .working_dir = options.guest_working_dir,
        .retain_output = retain_output,
    } });
    return execNamedResult(allocator, response);
}

pub fn initialOutputNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: InitialOutputNamedOptions,
) !NamedLifecycleResult {
    clearLastError();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths = try apiPaths(context, arena, options.name);
    const state = try vm_registry.probe(context.io, paths);
    if (state != .ready) return namedVmNotReady(arena, context.io, paths, "logs", options.name, state);
    var ready = try readReady(arena, context.io, paths);
    defer ready.deinit();
    const response = try monitor_protocol.call(arena, context.io, ready.value.control_socket_path, .{ .initial_output = .{} });
    const snapshot = try execNamedResult(allocator, response);
    defer deinitExecNamedResult(allocator, snapshot);
    if (snapshot.exit_code != 0) {
        setLastError("named VM {s} has no retained initial-command output", .{options.name});
        return error.InitialOutputUnavailable;
    }
    const initial = try initialCommandResultFromSnapshot(snapshot);
    return ownedNamedLifecycleResult(allocator, .{
        .action = "logs",
        .name = options.name,
        .state = "ready",
        .pid = ready.value.pid,
        .initial_command = initial,
    });
}

fn initialCommandResultFromSnapshot(snapshot: ExecNamedResult) !InitialCommandResult {
    const output_limit: usize = initial_output_limit_bytes_per_stream;
    if (snapshot.stdout.len < initial_output_protocol_header_len) return error.BadMonitorResponse;
    const header = snapshot.stdout[0..initial_output_protocol_header_len];
    if (header[0] > 1 or (header[0] == 0 and header[1] != 0) or (header[2] & ~@as(u8, 3)) != 0) {
        return error.BadMonitorResponse;
    }
    if (snapshot.stdout.len - initial_output_protocol_header_len > output_limit or
        snapshot.stderr.len > output_limit)
    {
        return error.BadMonitorResponse;
    }
    const exited = header[0] == 1;
    return .{
        .output_disposition = .retain,
        .output_destination = .named_logs,
        .output_limit_bytes_per_stream = initial_output_limit_bytes_per_stream,
        .process_status = if (exited) .exited else .running,
        .exit_code = if (exited) header[1] else null,
        .stdout = snapshot.stdout[initial_output_protocol_header_len..],
        .stderr = snapshot.stderr,
        .stdout_truncated = (header[2] & 1) != 0,
        .stderr_truncated = (header[2] & 2) != 0,
    };
}

fn saveContinueNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: SaveContinueNamedOptions,
) !NamedLifecycleResult {
    clearLastError();
    try spore.validateAnnotations(options.annotations);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out_dir = try resolveNewOutputDirApi(arena, context.io, options.out_dir);
    const temp_dir = try temporarySiblingOutputDir(arena, context.io, out_dir);
    var cleanup_temp = true;
    defer if (cleanup_temp) Io.Dir.cwd().deleteTree(context.io, temp_dir) catch {};
    const paths = try apiPaths(context, arena, options.name);
    const state = try vm_registry.probe(context.io, paths);
    if (state != .ready) return namedVmNotReady(arena, context.io, paths, "save", options.name, state);
    var spec = try readSpec(arena, context.io, paths);
    defer spec.deinit();
    try rejectX86NamedPersistence(spec.value);
    // Non-destructive save supports multi-vCPU VMs: both KVM and HVF quiesce
    // every vCPU at one barrier, capture manifest-v1 state, and resume the
    // guest through the monitor snapshot-and-continue path (the same path
    // `spore vm fork` uses). No vCPU-count gate is needed here.
    if ((spec.value.rootfs_path != null or spec.value.image_ref != null) and spec.value.rootfs == null) {
        return error.MissingRootfsIdentity;
    }
    if (spec.value.disk != null or spec.value.rootfs != null or spec.value.rootfs_path != null or spec.value.image_ref != null) {
        const cache_root = try local_paths.rootfsCacheRootPath(arena, context.environ_map);
        try saved_spore_pin.ensureOwnershipLinkCompatible(arena, cache_root, temp_dir);
    }
    var snapshot_spec = spec.value;
    if (!spore.annotationsEmpty(options.annotations)) {
        snapshot_spec.annotations = try spore.mergeAnnotations(arena, snapshot_spec.annotations, options.annotations);
    }
    try Io.Dir.cwd().createDirPath(context.io, temp_dir);
    try writeSporeLifecycleSpec(arena, context.io, temp_dir, snapshot_spec);
    var ready = try readReady(arena, context.io, paths);
    defer ready.deinit();
    const response = try monitor_protocol.call(arena, context.io, ready.value.control_socket_path, .{ .snapshot = .{
        .out_dir = temp_dir,
        .publish_dir = out_dir,
    } });
    if (response != .snapshotted) return saveFailed(options.name, response);
    cleanup_temp = false;
    return ownedNamedLifecycleResult(allocator, .{
        .action = "saved",
        .name = options.name,
        .state = "ready",
        .pid = ready.value.pid,
        .spore_dir = out_dir,
        .ownership = if (spec.value.disk != null or spec.value.rootfs != null or spec.value.rootfs_path != null or spec.value.image_ref != null)
            saved_spore_ownership.machine_local_pinned
        else
            saved_spore_ownership.portable_self_contained,
    });
}

pub fn saveNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: SaveNamedOptions,
) !NamedLifecycleResult {
    clearLastError();
    if (options.stop) return saveStopNamed(context, allocator, options);
    return saveContinueNamed(context, allocator, .{
        .name = options.name,
        .out_dir = options.out_dir,
        .annotations = options.annotations,
    });
}

fn rejectX86NamedPersistence(spec: Spec) !void {
    const requested = backend_mod.Backend.parse(spec.backend) orelse return error.UnsupportedBackend;
    const selected = try requested.resolveForHost();
    try vm_session.validateFreshProductPolicy(selected, .{
        .memory = spec.memory,
        .vcpus = spec.vcpus,
        .capture = true,
    });
}

fn saveStopNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: SaveNamedOptions,
) !NamedLifecycleResult {
    clearLastError();
    try spore.validateAnnotations(options.annotations);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out_dir = try resolveNewOutputDirApi(arena, context.io, options.out_dir);
    const paths = try apiPaths(context, arena, options.name);
    const state = try vm_registry.probe(context.io, paths);
    if (state != .ready) return namedVmNotReady(arena, context.io, paths, "save", options.name, state);
    var spec = try readSpec(arena, context.io, paths);
    defer spec.deinit();
    try rejectX86NamedPersistence(spec.value);
    if ((spec.value.rootfs_path != null or spec.value.image_ref != null) and spec.value.rootfs == null) {
        return error.MissingRootfsIdentity;
    }
    if (spec.value.disk != null or spec.value.rootfs != null or spec.value.rootfs_path != null or spec.value.image_ref != null) {
        const cache_root = try local_paths.rootfsCacheRootPath(arena, context.environ_map);
        try saved_spore_pin.ensureOwnershipLinkCompatible(arena, cache_root, out_dir);
    }
    var ready = try readReady(arena, context.io, paths);
    defer ready.deinit();
    const response = try monitor_protocol.call(arena, context.io, ready.value.control_socket_path, .{ .@"suspend" = .{ .out_dir = out_dir } });
    if (response != .suspended) return saveFailed(options.name, response);

    var cleanup_after_suspend = true;
    defer if (cleanup_after_suspend) {
        if (awaitMonitorExit(context.io, paths, ready.value.pid)) |lock| {
            deleteLocked(context.io, paths, lock) catch {};
        } else |_| {}
    };
    var suspend_spec = spec.value;
    var manifest = try spore.loadManifest(arena, out_dir);
    defer manifest.deinit();
    if (suspend_spec.exec_defaults != null or !spore.annotationsEmpty(options.annotations)) {
        if (!spore.annotationsEmpty(options.annotations)) {
            manifest.value.annotations = try spore.mergeAnnotations(arena, manifest.value.annotations, options.annotations);
        }
        manifest.value.exec_defaults = suspend_spec.exec_defaults;
        const bytes = try spore.encodeManifestAlloc(arena, manifest.value);
        try chunk_sealer.replaceFileAtomicDurable(arena, try std.fs.path.join(arena, &.{ out_dir, "manifest.json" }), bytes, 0o644);
        suspend_spec.annotations = manifest.value.annotations;
    }
    if (manifest.value.disk) |disk| {
        suspend_spec.disk = disk;
        const cache_root = try local_paths.rootfsCacheRootPath(arena, context.environ_map);
        suspend_spec.disk_baseline_lease = .{
            .root = cache_root,
            .baseline_kind = .disk_index,
            .baseline_identity = disk.base,
            .rootfs_storage = try runtime_disk.storageFromSnapshotDisk(arena, disk),
        };
    }
    try writeSporeLifecycleSpec(arena, context.io, out_dir, suspend_spec);
    const saved_sessions = manifest.value.sessions.len;
    cleanup_after_suspend = false;
    try deleteLocked(context.io, paths, try awaitMonitorExit(context.io, paths, ready.value.pid));
    return ownedNamedLifecycleResult(allocator, .{
        .action = "saved_stopped",
        .name = options.name,
        .state = "stopped",
        .pid = ready.value.pid,
        .spore_dir = out_dir,
        .saved_sessions = saved_sessions,
        .ownership = if (manifest.value.disk != null) saved_spore_ownership.machine_local_pinned else saved_spore_ownership.portable_self_contained,
    });
}

pub fn forkNamed(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: ForkNamedOptions,
) !NamedForkResult {
    clearLastError();
    if (options.count == 0 or options.count > runtime_disk_claim.max_children_per_batch) return error.InvalidForkCount;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const context = Context{ .io = init.io, .environ_map = init.environ_map };

    const child_names = try renderForkNames(arena, options.name_pattern, options.count);
    const source_paths = try apiPaths(context, arena, options.source_name);
    const state = try vm_registry.probe(init.io, source_paths);
    if (state != .ready) return namedVmNotReady(arena, init.io, source_paths, "fork", options.source_name, state);

    var source_spec = try readSpec(arena, init.io, source_paths);
    defer source_spec.deinit();
    try rejectX86NamedPersistence(source_spec.value);
    const disk_backed = source_spec.value.rootfs != null or source_spec.value.rootfs_path != null or source_spec.value.image_ref != null or source_spec.value.disk != null;
    if (disk_backed and source_spec.value.rootfs == null) return error.UnsupportedNamedForkDisk;
    if (source_spec.value.network != null) return error.UnsupportedNamedForkNetwork;

    // Every child name is claimed before the source pauses. A claim is
    // abandoned, deleting its entry, until its monitor has started.
    const children = try arena.alloc(ForkChild, child_names.len);
    var claimed: usize = 0;
    defer for (children[0..claimed]) |*child| if (child.claim) |*claim| claim.abandon(init.io, child.paths);
    for (child_names, children) |child_name, *child| {
        const child_paths = try apiPaths(context, arena, child_name);
        child.* = .{ .paths = child_paths, .claim = try claimName(arena, init.io, child_paths, "fork") };
        claimed += 1;
    }

    var ready = try readReady(arena, init.io, source_paths);
    defer ready.deinit();

    const batch_dir = try hiddenForkBatchDir(arena, source_paths.runtime_root);
    const snapshot_dir = try std.fs.path.resolve(arena, &.{ batch_dir, "source.spore" });
    const children_dir = try std.fs.path.resolve(arena, &.{ batch_dir, "children" });
    try ensureDirPath(init.io, batch_dir);
    var cleanup_batch = true;
    defer if (cleanup_batch) Io.Dir.cwd().deleteTree(init.io, batch_dir) catch {};
    var prepared_batch: ?[]const u8 = null;
    defer if (cleanup_batch) {
        if (prepared_batch) |batch| _ = monitor_protocol.call(arena, init.io, ready.value.control_socket_path, .{ .disk_fork_cancel = .{
            .type = runtime_disk_fork_control.cancel_type,
            .schema = runtime_disk_fork_control.cancel_schema,
            .batch = batch,
        } }) catch {};
    };

    var ram_capture_ms: ?u64 = null;
    var disk_fork_ms: ?u64 = null;
    var source_pause_ms: ?u64 = null;
    var child_ready_ms: ?u64 = null;
    if (comptime builtin.is_test) if (testing.fork_source_read_barrier) |barrier| barrier.pause(init.io);

    if (disk_backed) {
        const batch_name = std.fs.path.basename(batch_dir);
        const prepare_request = runtime_disk_fork_control.PrepareRequest{
            .type = runtime_disk_fork_control.prepare_type,
            .schema = runtime_disk_fork_control.prepare_schema,
            .out_dir = snapshot_dir,
            .batch = batch_name,
            .children = child_names,
            .allow_copy = options.allow_slow_copy,
        };
        // Cancellation is idempotent and must cover a response transport
        // failure after the source has already registered the batch.
        prepared_batch = batch_name;
        const prepared = try diskForkPrepared(try monitor_protocol.call(arena, init.io, ready.value.control_socket_path, .{ .disk_fork_prepare = prepare_request }));
        try validatePreparedDiskFork(prepared, prepare_request);
        // The source monitor names and records the baseline while it holds
        // the guest, so a save that replaced the disk after this CLI read the
        // spec is already reflected in the response. The CLI never writes
        // the source's spec.
        source_spec.value.disk = prepared.disk;
        source_spec.value.disk_baseline_lease = prepared.lease;
        ram_capture_ms = prepared.ram_capture_ns / std.time.ns_per_ms;
        disk_fork_ms = prepared.disk_fork_ns / std.time.ns_per_ms;
        source_pause_ms = prepared.source_pause_ns / std.time.ns_per_ms;
        const children_start_ms = monotonicMs();

        try writeSporeLifecycleSpec(arena, init.io, snapshot_dir, source_spec.value);
        try writeSporeExecDefaults(arena, snapshot_dir, source_spec.value.exec_defaults);
        _ = try spore_fork.fork(arena, .{
            .parent_dir = snapshot_dir,
            .out_dir = children_dir,
            .count = options.count,
            .environ_map = init.environ_map,
        });
        for (children, prepared.claims, 0..) |*child, claim, index| {
            const spore_dir = try childSporeDir(arena, children_dir, index);
            startForkChildExecutable(init, arena, child, spore_dir, source_spec.value, options.spore_executable, options.debug, .{
                .source_socket_path = ready.value.control_socket_path,
                .batch_name = batch_name,
                .prepared_claim = claim,
            }) catch |err| {
                cleanupStartedChildren(context, arena, children);
                return err;
            };
        }
        child_ready_ms = monotonicMs() -| children_start_ms;
    } else {
        const response = try monitor_protocol.call(arena, init.io, ready.value.control_socket_path, .{ .snapshot = .{ .out_dir = snapshot_dir } });
        if (response != .snapshotted) return monitorRequestFailed(if (response == .err) response.err.message else null);
        try writeSporeLifecycleSpec(arena, init.io, snapshot_dir, source_spec.value);
        try writeSporeExecDefaults(arena, snapshot_dir, source_spec.value.exec_defaults);

        _ = try spore_fork.fork(arena, .{
            .parent_dir = snapshot_dir,
            .out_dir = children_dir,
            .count = options.count,
            .environ_map = init.environ_map,
        });
        for (children, 0..) |*child, index| {
            const spore_dir = try childSporeDir(arena, children_dir, index);
            startForkChildExecutable(init, arena, child, spore_dir, source_spec.value, options.spore_executable, options.debug, null) catch |err| {
                cleanupStartedChildren(context, arena, children);
                return err;
            };
        }
    }

    cleanup_batch = false;
    return ownedNamedForkResult(allocator, .{
        .source = options.source_name,
        .count = options.count,
        .children = child_names,
        .ram_capture_ms = ram_capture_ms,
        .disk_fork_ms = disk_fork_ms,
        .source_pause_ms = source_pause_ms,
        .child_ready_ms = child_ready_ms,
    });
}

pub fn removeNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: RemoveNamedOptions,
) !NamedLifecycleResult {
    clearLastError();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths = try apiPaths(context, arena, options.name);
    const removed_pid = try removeNamedAtPaths(context, arena, paths);
    return ownedNamedLifecycleResult(allocator, .{
        .action = "removed",
        .name = options.name,
        .state = "absent",
        .pid = removed_pid,
    });
}

fn removeNamedAtPaths(context: Context, allocator: std.mem.Allocator, paths: Paths) !?i64 {
    if (try vm_registry.probe(context.io, paths) == .absent) return error.NamedVmNotFound;
    const lock = (try vm_registry.tryLockForRemoval(context.io, paths)) orelse try stopLockHolder(allocator, context.io, paths);
    const removed_pid = readPid(allocator, context.io, paths) catch null;
    try deleteLocked(context.io, paths, lock);
    return removed_pid;
}

pub fn listNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: ListNamedOptions,
) ![]ListEntry {
    clearLastError();
    _ = options;
    const root = try runtimeRootPath(allocator, context.environ_map);
    defer allocator.free(root);
    return listEntries(allocator, context.io, root);
}

pub fn deinitNamedLifecycleResult(allocator: std.mem.Allocator, result: NamedLifecycleResult) void {
    allocator.free(result.name);
    if (result.console_log_path) |path| allocator.free(path);
    if (result.spore_dir) |path| allocator.free(path);
    if (result.initial_command) |initial| {
        if (initial.stdout) |bytes| allocator.free(bytes);
        if (initial.stderr) |bytes| allocator.free(bytes);
    }
}

pub fn deinitExecNamedResult(allocator: std.mem.Allocator, result: ExecNamedResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

pub fn deinitNamedForkResult(allocator: std.mem.Allocator, result: NamedForkResult) void {
    allocator.free(result.source);
    for (result.children) |child| allocator.free(child);
    allocator.free(result.children);
}

pub const RemovedSavedSpore = saved_spore_remove.Result;

pub fn deinitRemovedSavedSpore(allocator: std.mem.Allocator, result: RemovedSavedSpore) void {
    saved_spore_remove.deinit(allocator, result);
}

pub fn removeSavedSpore(context: Context, allocator: std.mem.Allocator, raw_dir: []const u8) !RemovedSavedSpore {
    return saved_spore_remove.remove(context, allocator, raw_dir);
}

pub fn listEntries(allocator: std.mem.Allocator, io: Io, runtime_root: []const u8) ![]ListEntry {
    requirePrivateDir(io, runtime_root) catch |err| switch (err) {
        error.FileNotFound => return emptyListEntries(allocator),
        else => |e| return e,
    };
    const vms_dir = try std.fs.path.resolve(allocator, &.{ runtime_root, "vms" });
    defer allocator.free(vms_dir);
    requirePrivateDir(io, vms_dir) catch |err| switch (err) {
        error.FileNotFound => return emptyListEntries(allocator),
        else => |e| return e,
    };
    var dir = openDirPath(io, vms_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return emptyListEntries(allocator),
        else => |e| return e,
    };
    defer dir.close(io);

    var entries = std.array_list.Managed(ListEntry).init(allocator);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        validateName(entry.name) catch continue;
        const paths = try pathsFromRoot(allocator, runtime_root, entry.name);
        defer paths.deinit(allocator);
        const state = try vm_registry.probe(io, paths);
        if (state == .absent) continue;
        const pid = readPid(allocator, io, paths) catch null;
        const metadata = readListMetadata(allocator, io, paths) catch null;
        var stats = if (metadata) |value| value.stats else ListStats{};
        if (state == .ready) {
            if (pid) |value| stats.resident_bytes = readProcessResidentBytes(allocator, io, value);
            if (readMonitorStats(allocator, io, paths)) |monitor_stats| {
                stats.chunks_nonzero = monitor_stats.chunks_nonzero;
                stats.dirty_chunks_pending = monitor_stats.dirty_chunks_pending;
            } else |_| {}
        }
        try entries.append(.{
            .name = try allocator.dupe(u8, entry.name),
            .state = state.name(),
            .pid = pid,
            .memory = if (metadata) |value| value.memory else null,
            .stats = stats,
        });
    }
    const out = try entries.toOwnedSlice();
    std.mem.sort(ListEntry, out, {}, lessListEntry);
    return out;
}

pub fn freeListEntries(allocator: std.mem.Allocator, entries: []ListEntry) void {
    for (entries) |entry| allocator.free(entry.name);
    allocator.free(entries);
}

fn emptyListEntries(allocator: std.mem.Allocator) ![]ListEntry {
    return allocator.alloc(ListEntry, 0);
}

fn readListMetadata(allocator: std.mem.Allocator, io: Io, paths: Paths) !ListMetadata {
    var spec = try readSpec(allocator, io, paths);
    defer spec.deinit();
    const memory = listMemoryFromConfig(spec.value.memory);
    var stats = listStatsFromMemory(memory);
    if (spec.value.resume_dir) |dir| {
        const backing_stats = readBackingFileStats(allocator, dir) catch null;
        if (backing_stats) |value| {
            stats.backing_logical_bytes = value.backing_logical_bytes;
            stats.backing_allocated_bytes = value.backing_allocated_bytes;
        }
    }
    return .{ .memory = memory, .stats = stats };
}

pub fn listMemoryFromConfig(memory: memory_config.Config) ListMemory {
    return .{
        .initial_bytes = memory.initial_bytes,
        .maximum_bytes = memory.maximum_bytes,
    };
}

pub fn listStatsFromMemory(memory: ListMemory) ListStats {
    const chunk_size: u64 = spore.chunk_size;
    return .{
        .chunk_size = chunk_size,
        .chunks_total = std.math.divCeil(u64, memory.maximum_bytes, chunk_size) catch unreachable,
    };
}

fn readBackingFileStats(allocator: std.mem.Allocator, dir: []const u8) !ListStats {
    const backing_path = try std.fs.path.resolve(allocator, &.{ dir, spore.ram_backing_path });
    defer allocator.free(backing_path);
    const backing_path_z = try allocator.dupeSentinel(u8, backing_path, 0);
    defer allocator.free(backing_path_z);

    const fd = std.c.open(backing_path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);

    return fstatBackingFileStats(fd);
}

fn fstatBackingFileStats(fd: std.c.fd_t) !ListStats {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var statx_buf: linux.Statx = undefined;
        const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{
            .TYPE = true,
            .MODE = true,
            .SIZE = true,
            .BLOCKS = true,
        }, &statx_buf);
        if (linux.errno(rc) != .SUCCESS) return error.IoFailed;
        if (!linux.S.ISREG(statx_buf.mode)) return error.FileNotFound;
        return .{
            .backing_logical_bytes = statx_buf.size,
            .backing_allocated_bytes = if (statx_buf.mask.BLOCKS)
                std.math.mul(u64, statx_buf.blocks, 512) catch null
            else
                null,
        };
    } else if (comptime builtin.os.tag.isDarwin()) {
        var stat: std.c.Stat = undefined;
        if (std.c.fstat(fd, &stat) != 0) return error.IoFailed;
        if (!std.c.S.ISREG(stat.mode)) return error.FileNotFound;
        if (stat.size < 0) return error.IoFailed;
        return .{
            .backing_logical_bytes = @intCast(stat.size),
            .backing_allocated_bytes = if (stat.blocks >= 0)
                std.math.mul(u64, @intCast(stat.blocks), 512) catch null
            else
                null,
        };
    } else {
        return error.UnsupportedPlatform;
    }
}

fn readProcessResidentBytes(allocator: std.mem.Allocator, io: Io, pid: i64) ?u64 {
    if (pid <= 0) return null;
    return if (comptime builtin.os.tag == .linux)
        readLinuxProcessResidentBytes(allocator, io, pid) catch null
    else if (comptime builtin.os.tag.isDarwin())
        readDarwinProcessResidentBytes(pid)
    else
        null;
}

fn readLinuxProcessResidentBytes(allocator: std.mem.Allocator, io: Io, pid: i64) !u64 {
    const statm_path = try std.fmt.allocPrint(allocator, "/proc/{d}/statm", .{pid});
    defer allocator.free(statm_path);
    const data = try Io.Dir.cwd().readFileAlloc(io, statm_path, allocator, .limited(256));
    defer allocator.free(data);
    return linuxStatmResidentBytes(data, @intCast(std.heap.pageSize()));
}

fn linuxStatmResidentBytes(data: []const u8, page_size: u64) !u64 {
    var fields = std.mem.tokenizeAny(u8, data, " \t\r\n");
    _ = fields.next() orelse return error.InvalidProcessStat;
    const resident_raw = fields.next() orelse return error.InvalidProcessStat;
    const resident_pages = try std.fmt.parseUnsigned(u64, resident_raw, 10);
    return std.math.mul(u64, resident_pages, page_size) catch error.InvalidProcessStat;
}

fn readDarwinProcessResidentBytes(pid: i64) ?u64 {
    const pid_c = std.math.cast(c_int, pid) orelse return null;
    var info: darwin_process.TaskInfo = undefined;
    const expected: c_int = @intCast(@sizeOf(darwin_process.TaskInfo));
    const rc = darwin_process.proc_pidinfo(pid_c, darwin_process.proc_pid_task_info, 0, @ptrCast(&info), expected);
    if (rc != expected) return null;
    return info.resident_size;
}

fn apiPaths(context: Context, allocator: std.mem.Allocator, name: []const u8) !Paths {
    const paths = try pathsFor(allocator, context.environ_map, name);
    try validateExistingRuntimeDirs(context.io, paths);
    return paths;
}

fn resolveNewOutputDirApi(allocator: std.mem.Allocator, io: Io, raw: []const u8) ![]const u8 {
    const path = try std.fs.path.resolve(allocator, &.{raw});
    if (try pathExists(io, path)) return error.OutputDirExists;
    const parent = std.fs.path.dirname(path) orelse ".";
    const stat = Io.Dir.cwd().statFile(io, parent, .{ .follow_symlinks = true }) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidOutputDir,
        else => |e| return e,
    };
    if (stat.kind != Io.File.Kind.directory) return error.InvalidOutputDir;
    if (std.fs.path.isAbsolute(path)) return path;
    // Output directories cross process boundaries (the monitor receives them
    // over the control socket and resolves them against its own cwd), so a
    // relative --out must become absolute before it leaves this process.
    const abs_parent = try absoluteExistingDirPath(allocator, parent);
    return std.fs.path.join(allocator, &.{ abs_parent, std.fs.path.basename(path) });
}

fn absoluteExistingDirPath(allocator: std.mem.Allocator, path: []const u8) error{ OutOfMemory, InvalidOutputDir }![]const u8 {
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);
    var buf: [std.c.PATH_MAX]u8 = undefined;
    const resolved = std.c.realpath(path_z, &buf) orelse return error.InvalidOutputDir;
    return allocator.dupe(u8, std.mem.span(resolved));
}

fn temporarySiblingOutputDir(allocator: std.mem.Allocator, io: Io, out_dir: []const u8) ![]const u8 {
    const parent = std.fs.path.dirname(out_dir) orelse return error.InvalidOutputDir;
    const base = std.fs.path.basename(out_dir);
    const now: u64 = @intCast(Io.Clock.real.now(io).nanoseconds);
    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        const name = try std.fmt.allocPrint(allocator, ".{s}.tmp-{x}-{d}", .{ base, now, attempt });
        const path = try std.fs.path.resolve(allocator, &.{ parent, name });
        if (!try pathExists(io, path)) return path;
    }
    return error.OutputDirExists;
}

fn resolveExistingSporeDirApi(allocator: std.mem.Allocator, io: Io, raw: []const u8) ![]const u8 {
    const path = try std.fs.path.resolve(allocator, &.{raw});
    defer allocator.free(path);
    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != Io.File.Kind.directory) return error.InvalidSporeDir;
    var real_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const real_len = try Io.Dir.cwd().realPathFile(io, path, &real_buf);
    return allocator.dupe(u8, real_buf[0..real_len]);
}

pub fn writeSporeLifecycleSpec(allocator: std.mem.Allocator, io: Io, dir: []const u8, spec: Spec) !void {
    try validateSpec(spec);
    const path = try std.fs.path.resolve(allocator, &.{ dir, lifecycle_spore_metadata_file });
    defer allocator.free(path);
    var metadata = spec;
    metadata.resume_dir = null;
    metadata.resume_generation = null;
    metadata.network_policy = null;
    const json = try std.json.Stringify.valueAlloc(allocator, metadata, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
}

fn writeSporeExecDefaults(allocator: std.mem.Allocator, dir: []const u8, defaults: ?spore.ExecDefaults) !void {
    if (defaults == null) return;
    var manifest = try spore.loadManifest(allocator, dir);
    defer manifest.deinit();
    manifest.value.exec_defaults = defaults;
    try spore.saveManifest(allocator, dir, manifest.value);
}

pub fn readSporeLifecycleSpec(allocator: std.mem.Allocator, io: Io, dir: []const u8) !?std.json.Parsed(Spec) {
    const path = try std.fs.path.resolve(allocator, &.{ dir, lifecycle_spore_metadata_file });
    defer allocator.free(path);
    const data = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_metadata_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer allocator.free(data);
    var parsed = try std.json.parseFromSlice(Spec, allocator, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    errdefer parsed.deinit();
    try validateSpec(parsed.value);
    return parsed;
}

const ForkNamePlaceholder = struct {
    start: usize,
    end: usize,
    width: usize = 0,
};

fn renderForkNames(allocator: std.mem.Allocator, pattern: []const u8, count: usize) ![]const []const u8 {
    const placeholder = try findForkNamePlaceholder(pattern);
    if (count > 1 and placeholder == null) return error.MissingForkNamePlaceholder;
    const names = try allocator.alloc([]const u8, count);
    var name_count: usize = 0;
    errdefer {
        for (names[0..name_count]) |name| allocator.free(name);
        allocator.free(names);
    }
    for (names, 0..) |*slot, index| {
        slot.* = try renderForkName(allocator, pattern, placeholder, index);
        name_count += 1;
        try validateName(slot.*);
        for (names[0..index]) |previous| {
            if (std.mem.eql(u8, previous, slot.*)) return error.DuplicateForkName;
        }
    }
    return names;
}

fn findForkNamePlaceholder(pattern: []const u8) !?ForkNamePlaceholder {
    var found: ?ForkNamePlaceholder = null;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, pattern, i, '%')) |start| {
        if (found != null) return error.InvalidForkNamePattern;
        if (start + 1 >= pattern.len) return error.InvalidForkNamePattern;

        var cursor = start + 1;
        var width: usize = 0;
        if (pattern[cursor] == '0') {
            cursor += 1;
            if (cursor >= pattern.len or !std.ascii.isDigit(pattern[cursor])) return error.InvalidForkNamePattern;
            while (cursor < pattern.len and std.ascii.isDigit(pattern[cursor])) : (cursor += 1) {
                width = std.math.mul(usize, width, 10) catch return error.InvalidForkNamePattern;
                width = std.math.add(usize, width, pattern[cursor] - '0') catch return error.InvalidForkNamePattern;
                if (width > max_name_len) return error.InvalidForkNamePattern;
            }
            if (cursor >= pattern.len or pattern[cursor] != 'd') return error.InvalidForkNamePattern;
        } else if (pattern[cursor] != 'd') {
            return error.InvalidForkNamePattern;
        }
        found = .{ .start = start, .end = cursor + 1, .width = width };
        i = cursor + 1;
    }
    return found;
}

fn renderForkName(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    placeholder: ?ForkNamePlaceholder,
    index: usize,
) ![]const u8 {
    const marker = placeholder orelse return allocator.dupe(u8, pattern);
    const digits = try std.fmt.allocPrint(allocator, "{d}", .{index});
    defer allocator.free(digits);
    const prefix = pattern[0..marker.start];
    const suffix = pattern[marker.end..];
    const padding = if (marker.width > digits.len) marker.width - digits.len else 0;
    const out = try allocator.alloc(u8, prefix.len + padding + digits.len + suffix.len);
    var offset: usize = 0;
    @memcpy(out[offset..][0..prefix.len], prefix);
    offset += prefix.len;
    @memset(out[offset..][0..padding], '0');
    offset += padding;
    @memcpy(out[offset..][0..digits.len], digits);
    offset += digits.len;
    @memcpy(out[offset..][0..suffix.len], suffix);
    return out;
}

fn hiddenForkBatchDir(allocator: std.mem.Allocator, runtime_root: []const u8) ![]const u8 {
    const token = try runtime_disk_claim.randomToken();
    var token_hex: [runtime_disk_claim.token_hex_bytes]u8 = undefined;
    var leaf: ["fork-".len + 32]u8 = undefined;
    @memcpy(leaf[0.."fork-".len], "fork-");
    @memcpy(leaf["fork-".len..], runtime_disk_claim.formatTokenHex(token, &token_hex)[0..32]);
    return std.fs.path.resolve(allocator, &.{ runtime_root, "forks", &leaf });
}

fn validatePreparedDiskFork(
    response: runtime_disk_fork_control.PreparedResponse,
    request: runtime_disk_fork_control.PrepareRequest,
) !void {
    if (!std.mem.eql(u8, response.batch, request.batch) or
        !std.mem.eql(u8, response.capture_dir, request.out_dir) or
        response.claims.len != request.children.len) return error.BadMonitorResponse;
    for (response.claims, request.children) |claim, child| {
        if (!std.mem.eql(u8, claim.child, child)) return error.BadMonitorResponse;
    }
}

fn childSporeDir(allocator: std.mem.Allocator, children_dir: []const u8, index: usize) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{d:0>6}", .{ children_dir, index });
}

const ForkChildDiskClaim = struct {
    source_socket_path: []const u8,
    batch_name: []const u8,
    prepared_claim: runtime_disk_fork_control.PreparedClaim,
};

/// A fork child's registry entry. `claim` is null once the child's monitor
/// holds the lock.
const ForkChild = struct {
    paths: Paths,
    claim: ?vm_registry.Claim,
};

fn startForkChildExecutable(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    child: *ForkChild,
    spore_dir: []const u8,
    base: Spec,
    spore_executable: []const u8,
    debug: bool,
    disk_claim: ?ForkChildDiskClaim,
) !void {
    if ((base.rootfs != null) != (disk_claim != null)) return error.UnsupportedNamedForkDisk;
    const parsed_manifest = spore.loadManifest(allocator, spore_dir) catch return error.InvalidSporeDir;
    defer parsed_manifest.deinit();
    const manifest = parsed_manifest.value;

    if (manifest.network != null) return error.UnsupportedNamedForkNetwork;
    const expected_devices = diskless_resume_device_count + @as(usize, @intFromBool(base.rootfs != null));
    if (manifest.devices.len != expected_devices) return error.UnsupportedNamedForkDisk;
    if (manifest.disk != null) return error.UnsupportedNamedForkDisk;
    const memory = try spore.memoryConfig(manifest.platform.ram_size, manifest.memory_state);
    const spec = Spec{
        .name = std.fs.path.basename(child.paths.vm_dir),
        .backend = base.backend,
        .kernel_path = base.kernel_path,
        .initrd_path = base.initrd_path,
        .resume_dir = spore_dir,
        .rootfs = base.rootfs,
        .disk = base.disk,
        .disk_baseline_lease = base.disk_baseline_lease,
        .annotations = manifest.annotations,
        .sessions = manifest.sessions,
        .exec_defaults = base.exec_defaults,
        .memory = memory,
        .vcpus = manifest.platform.vcpu_count,
        .guest_port = base.guest_port,
        .timeout_ms = base.timeout_ms,
        .console_log_path = null,
    };
    if (disk_claim) |claim| try vm_registry.writeDiskForkClaim(allocator, init.io, child.paths, spec, .{
        .source_socket_path = claim.source_socket_path,
        .request = .{
            .type = runtime_disk_claim.claim_type,
            .schema = runtime_disk_claim.claim_schema,
            .token = claim.prepared_claim.token,
            .batch = claim.batch_name,
            .child = claim.prepared_claim.child,
            .child_index = claim.prepared_claim.child_index,
            .baseline_kind = claim.prepared_claim.baseline_kind,
            .baseline_identity = claim.prepared_claim.baseline_identity,
        },
    });
    try spawnMonitorExecutable(init, allocator, child.paths, &child.claim.?, spec, spore_executable, debug);
    child.claim = null;
    try waitForReadyResult(allocator, init.io, child.paths, spec.timeout_ms, spore_executable);
}

/// Stops and removes every child whose monitor started. Children still
/// holding a claim are left to the caller.
fn cleanupStartedChildren(context: Context, allocator: std.mem.Allocator, children: []const ForkChild) void {
    for (children) |child| {
        if (child.claim == null) _ = removeNamedAtPaths(context, allocator, child.paths) catch {};
    }
}

/// Writes the complete spec and starts `exe [--debug] monitor NAME` with the
/// claim's lock as its stdin. CLI callers pass the running executable's path
/// so the monitor is always this exact build. Once the monitor is started it
/// holds the lock and the claimer's copy is closed; on an earlier failure the
/// caller still holds the claim.
fn spawnMonitorExecutable(init: std.process.Init, allocator: std.mem.Allocator, paths: Paths, claim: *vm_registry.Claim, spec: Spec, exe: []const u8, debug: bool) !void {
    try validateControlSocketPath(paths.control_socket_path);
    try claimControlSocketPath(init.io, paths);
    var monitor_log = try createFileAtPath(init.io, paths.monitor_log_path);
    defer monitor_log.close(init.io);
    try writeSpec(allocator, init.io, paths, spec);

    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.append(exe);
    if (debug) try argv.append("--debug");
    try argv.append("monitor");
    try argv.append(spec.name);
    _ = try std.process.spawn(init.io, .{
        .argv = argv.items,
        .environ_map = init.environ_map,
        .stdin = .{ .file = claim.lock },
        .stdout = .{ .file = monitor_log },
        .stderr = .{ .file = monitor_log },
        .pgid = if (builtin.os.tag == .windows) null else 0,
    });
    claim.release(init.io);
}

test "lifecycle monitor spawn receives context environment, debug flag and only the name" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var root_dir = try TestDir.init();
    defer root_dir.deinit();
    const root = try root_dir.path("runtime");
    try ensureDirPath(io, root);

    const script_path = try std.fs.path.resolve(allocator, &.{ root, "monitor-env.sh" });
    defer allocator.free(script_path);
    const out_path = try std.fs.path.resolve(allocator, &.{ root, "home.txt" });
    defer allocator.free(out_path);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = script_path,
        .data = "#!/bin/sh\nprintf '%s\\n%s\\n' \"$HOME\" \"$*\" > \"$SPOREVM_TEST_ENV_OUT\"\n",
    });
    try Io.Dir.cwd().setFilePermissions(io, script_path, @enumFromInt(0o755), .{});

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/sporevm-context-home");
    try env.put("SPOREVM_TEST_ENV_OUT", out_path);

    var spawn_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer spawn_arena_state.deinit();
    const spawn_arena = spawn_arena_state.allocator();
    const paths = try pathsFromRoot(spawn_arena, root, "env-probe");
    releaseControlSocketPath(io, paths) catch {};
    defer releaseControlSocketPath(io, paths) catch {};

    var claim = try vm_registry.claim(io, paths);
    try spawnMonitorExecutable(.{
        .minimal = undefined,
        .arena = undefined,
        .gpa = allocator,
        .io = io,
        .environ_map = &env,
        .preopens = .empty,
    }, spawn_arena, paths, &claim, .{
        .name = "env-probe",
        .backend = "auto",
        .memory = memory_config.Config.fixed(1024 * 1024 * 1024),
    }, script_path, true);

    var observed: ?[]u8 = null;
    defer if (observed) |bytes| allocator.free(bytes);
    const start = monotonicMs();
    while (monotonicMs() - start < 2_000) {
        observed = Io.Dir.cwd().readFileAlloc(io, out_path, allocator, .limited(4096)) catch |err| switch (err) {
            error.FileNotFound => {
                sleepMs(20);
                continue;
            },
            else => |e| return e,
        };
        break;
    }
    try std.testing.expect(observed != null);
    // The spec reaches the monitor only through spec.json.
    try std.testing.expectEqualStrings("/tmp/sporevm-context-home\n--debug monitor env-probe\n", observed.?);
    var spec = try readSpec(allocator, io, paths);
    defer spec.deinit();
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024), spec.value.memory.initial_bytes);
}

const FakeHelloServer = struct {
    io: Io,
    server: net.Server,
    response: []const u8,
    request_count: usize = 1,
};

fn fakeHelloServerMain(fake: *FakeHelloServer) void {
    for (0..fake.request_count) |_| fakeHelloServerOnce(fake) catch return;
}

fn fakeHelloServerOnce(fake: *FakeHelloServer) !void {
    var stream = fake.server.accept(fake.io) catch return;
    defer stream.close(fake.io);

    var read_buffer: [256]u8 = undefined;
    var reader = stream.reader(fake.io, &read_buffer);
    _ = try reader.interface.takeDelimiterExclusive('\n');
    try writeAll(fake.io, stream, fake.response);
    try writeAll(fake.io, stream, "\n");
}

fn readyPollDelayMs(attempt: u32) u64 {
    if (attempt < 10) return 1;
    if (attempt < 110) return 5;
    return 20;
}

fn readyPollSleep(attempt: *u32) void {
    const delay_ms = readyPollDelayMs(attempt.*);
    attempt.* +|= 1;
    sleepMs(delay_ms);
}

fn waitForReadyResult(allocator: std.mem.Allocator, io: Io, paths: Paths, timeout_ms: u64, spore_executable_path: []const u8) !void {
    const start = monotonicMs();
    var sleep_attempt: u32 = 0;
    while (monotonicMs() - start < timeout_ms) {
        switch (try vm_registry.probe(io, paths)) {
            .starting, .ready => {},
            // The monitor held the lock from its spawn, so it has exited.
            .stale, .absent => {
                setStartupError(allocator, io, paths, std.fs.path.basename(paths.vm_dir), spore_executable_path, "monitor exited before it was ready");
                return error.MonitorExited;
            },
        }
        var ready = readReady(allocator, io, paths) catch {
            readyPollSleep(&sleep_attempt);
            continue;
        };
        monitor_protocol.hello(allocator, io, ready.value.control_socket_path, spore_executable_path) catch |err| switch (err) {
            error.MonitorVersionMismatch => {
                ready.deinit();
                return err;
            },
            // Transient failures (socket races, monitor mid-start, garbage
            // responders) retry until the diagnosed readiness timeout.
            else => {
                ready.deinit();
                readyPollSleep(&sleep_attempt);
                continue;
            },
        };
        ready.deinit();
        return;
    }
    setStartupError(allocator, io, paths, std.fs.path.basename(paths.vm_dir), spore_executable_path, "timed out waiting for monitor readiness");
    return error.MonitorReadyTimeout;
}

fn createFileAtPath(io: Io, path: []const u8) !Io.File {
    if (Io.Dir.path.isAbsolute(path)) return Io.Dir.createFileAbsolute(io, path, .{});
    return Io.Dir.cwd().createFile(io, path, .{});
}

fn setStartupError(allocator: std.mem.Allocator, io: Io, paths: Paths, name: []const u8, spore_executable_path: []const u8, reason: []const u8) void {
    const state = vm_registry.probe(io, paths) catch VmState.stale;
    const pid = readPid(allocator, io, paths) catch null;
    const console_log_path = configuredConsoleLogPath(allocator, io, paths);
    defer if (console_log_path) |path| allocator.free(path);
    setLastError(
        "named VM {s} startup failed: {s}; state={s} pid={?d} console_log={s} monitor_log={s} control_socket={s} spore_executable={s}",
        .{ name, reason, state.name(), pid, console_log_path orelse "none", paths.monitor_log_path, paths.control_socket_path, spore_executable_path },
    );
}

fn namedVmNotReady(allocator: std.mem.Allocator, io: Io, paths: Paths, operation: []const u8, name: []const u8, state: VmState) anyerror {
    const pid = readPid(allocator, io, paths) catch null;
    const console_log_path = configuredConsoleLogPath(allocator, io, paths);
    defer if (console_log_path) |path| allocator.free(path);
    setLastError(
        "named VM {s} is not ready for {s}: state={s} pid={?d} console_log={s} monitor_log={s} control_socket={s}",
        .{ name, operation, state.name(), pid, console_log_path orelse "none", paths.monitor_log_path, paths.control_socket_path },
    );
    return error.NamedVmNotReady;
}

/// Claims a name for create, restore or a fork child, reporting an existing
/// entry with the same diagnostics as other lifecycle failures.
fn claimName(allocator: std.mem.Allocator, io: Io, paths: Paths, operation: []const u8) !vm_registry.Claim {
    return vm_registry.claim(io, paths) catch |err| switch (err) {
        error.NamedVmExists => namedVmExists(allocator, io, paths, operation, std.fs.path.basename(paths.vm_dir), vm_registry.probe(io, paths) catch .stale),
        else => |e| e,
    };
}

fn namedVmExists(allocator: std.mem.Allocator, io: Io, paths: Paths, operation: []const u8, name: []const u8, state: VmState) anyerror {
    const pid = readPid(allocator, io, paths) catch null;
    const console_log_path = configuredConsoleLogPath(allocator, io, paths);
    defer if (console_log_path) |path| allocator.free(path);
    setLastError(
        "named VM {s} already exists for {s}: state={s} pid={?d} console_log={s} monitor_log={s} control_socket={s}",
        .{ name, operation, state.name(), pid, console_log_path orelse "none", paths.monitor_log_path, paths.control_socket_path },
    );
    return error.NamedVmExists;
}

fn configuredConsoleLogPath(allocator: std.mem.Allocator, io: Io, paths: Paths) ?[]u8 {
    var spec = readSpec(allocator, io, paths) catch return null;
    defer spec.deinit();
    const path = spec.value.console_log_path orelse return null;
    return allocator.dupe(u8, path) catch null;
}

test "lifecycle readiness requires monitor control socket hello" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var root_dir = try TestDir.init();
    defer root_dir.deinit();
    const root = try root_dir.path("runtime");
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);

    var claim = try vm_registry.claim(io, paths);
    defer claim.release(io);
    const pid = currentTestPid();
    try writeSpec(allocator, io, paths, .{ .name = "bench-1", .timeout_ms = 40 });
    try writeReady(allocator, io, paths, .{
        .pid = pid,
        .control_socket_path = paths.control_socket_path,
        .console_log_path = null,
    });
    try writePid(allocator, io, paths, pid);

    clearLastError();
    try std.testing.expectError(error.MonitorReadyTimeout, waitForReadyResult(allocator, io, paths, 40, "/tmp/spore-1.5.0"));
    const detail = lastErrorMessage();
    try std.testing.expect(std.mem.indexOf(u8, detail, "timed out waiting for monitor readiness") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "state=ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "console_log=none") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, paths.monitor_log_path) != null);
}

test "lifecycle readiness fails on monitor version mismatch" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var root_dir = try TestDir.init();
    defer root_dir.deinit();
    const root = try root_dir.path("runtime");
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);

    var claim = try vm_registry.claim(io, paths);
    defer claim.release(io);
    const pid = currentTestPid();
    try writeSpec(allocator, io, paths, .{ .name = "bench-1", .console_log_path = paths.console_log_path });
    try writeReady(allocator, io, paths, .{
        .pid = pid,
        .control_socket_path = paths.control_socket_path,
        .console_log_path = paths.console_log_path,
    });
    try writePid(allocator, io, paths, pid);

    Io.Dir.cwd().deleteFile(io, paths.control_socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    const address = try net.UnixAddress.init(paths.control_socket_path);
    var fake = FakeHelloServer{
        .io = io,
        .server = try address.listen(io, .{ .kernel_backlog = 1 }),
        .response = "{\"type\":\"hello\",\"schema\":\"spore.monitor.hello.v1\",\"spore_version\":\"1.3.0\",\"helper_contract\":1}",
    };
    const thread = try std.Thread.spawn(.{}, fakeHelloServerMain, .{&fake});
    defer thread.join();
    defer fake.server.deinit(io);

    clearLastError();
    try std.testing.expectError(error.MonitorVersionMismatch, waitForReadyResult(allocator, io, paths, 1_000, "/tmp/spore-1.3.0"));
    const expected = try std.fmt.allocPrint(allocator, "spore {s} cannot use spore executable 1.3.0 at /tmp/spore-1.3.0", .{version.value});
    defer allocator.free(expected);
    const detail = lastErrorMessage();
    try std.testing.expect(std.mem.indexOf(u8, detail, expected) != null);
}

test "lifecycle named not ready diagnostics include state pid and logs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var root_dir = try TestDir.init();
    defer root_dir.deinit();
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const root = try std.fs.path.resolve(allocator, &.{ cwd, try root_dir.path("runtime") });
    defer allocator.free(root);
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);

    var claim = try vm_registry.claim(io, paths);
    claim.release(io);
    const dead_pid: i64 = 999_999_999;
    try writeSpec(allocator, io, paths, .{ .name = "bench-1", .console_log_path = paths.console_log_path });
    try writeReady(allocator, io, paths, .{
        .pid = dead_pid,
        .control_socket_path = paths.control_socket_path,
        .console_log_path = paths.console_log_path,
    });
    try writePid(allocator, io, paths, dead_pid);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(runtime_dir_env, root);

    clearLastError();
    try std.testing.expectError(error.NamedVmNotReady, openExecNamedStream(.{
        .io = io,
        .environ_map = &env,
    }, allocator, .{
        .name = "bench-1",
        .command = &.{"/bin/true"},
    }));

    const detail = lastErrorMessage();
    try std.testing.expect(std.mem.indexOf(u8, detail, "state=stale") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "pid=999999999") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, paths.console_log_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, paths.monitor_log_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, paths.control_socket_path) != null);
}

test "lifecycle named exists diagnostics include stale state and logs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var root_dir = try TestDir.init();
    defer root_dir.deinit();
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const root = try std.fs.path.resolve(allocator, &.{ cwd, try root_dir.path("runtime") });
    defer allocator.free(root);
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);

    var claim = try vm_registry.claim(io, paths);
    claim.release(io);
    const dead_pid: i64 = 999_999_998;
    const spec_bytes = "{\"name\":\"bench-1\"}";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = paths.spec_path, .data = spec_bytes });
    try writeReady(allocator, io, paths, .{
        .pid = dead_pid,
        .control_socket_path = paths.control_socket_path,
        .console_log_path = null,
    });
    try writePid(allocator, io, paths, dead_pid);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(runtime_dir_env, root);

    clearLastError();
    try std.testing.expectError(error.NamedVmExists, createNamedWithTiming(.{
        .minimal = undefined,
        .arena = undefined,
        .gpa = allocator,
        .io = io,
        .environ_map = &env,
        .preopens = .empty,
    }, allocator, .{}, .{
        .name = "bench-1",
        .memory = memory_config.Config.fixed(vm_session.x86_experimental_memory_bytes),
    }, .{ .start_ms = 0, .parsed_ms = 0 }));

    const detail = lastErrorMessage();
    try std.testing.expect(std.mem.indexOf(u8, detail, "state=stale") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "pid=999999998") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "console_log=none") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, paths.monitor_log_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, paths.control_socket_path) != null);
    const after = try Io.Dir.cwd().readFileAlloc(io, paths.spec_path, allocator, .limited(4096));
    defer allocator.free(after);
    try std.testing.expectEqualStrings(spec_bytes, after);
}

test "lifecycle create claims the name only once the image is ready" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_root);
    const root = try std.fs.path.join(allocator, &.{ tmp_root, "runtime" });
    defer allocator.free(root);
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(runtime_dir_env, root);

    var rootfs_boundary = test_barrier.Barrier{};
    testing.create_rootfs_barrier = &rootfs_boundary;
    defer testing.create_rootfs_barrier = null;
    const Create = struct {
        env: *std.process.Environ.Map,
        boundary: *test_barrier.Barrier,
        err: ?anyerror = null,
        finished: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            // A create that fails before the barrier must not leave the test
            // waiting for it.
            defer {
                self.finished.store(true, .release);
                self.boundary.reached.post(std.testing.io);
            }
            const result = createNamedWithTiming(.{
                .minimal = undefined,
                .arena = undefined,
                .gpa = std.testing.allocator,
                .io = std.testing.io,
                .environ_map = self.env,
                .preopens = .empty,
            }, std.testing.allocator, .{}, .{
                .name = "bench-1",
                .memory = memory_config.Config.fixed(vm_session.x86_experimental_memory_bytes),
                .spore_executable = "/nonexistent/spore",
            }, .{ .start_ms = 0, .parsed_ms = 0 }) catch |err| {
                self.err = err;
                return;
            };
            deinitNamedLifecycleResult(std.testing.allocator, result);
        }
    };
    var create = Create{ .env = &env, .boundary = &rootfs_boundary };
    var create_thread = test_barrier.ThreadGuard{
        .io = io,
        .thread = try std.Thread.spawn(.{}, Create.run, .{&create}),
        .barriers = &.{&rootfs_boundary},
    };
    defer create_thread.deinit();

    // A create killed while it pulls its image leaves nothing to remove.
    rootfs_boundary.waitReached(io);
    if (create.finished.load(.acquire)) return create.err orelse error.TestUnexpectedResult;
    try std.testing.expectEqual(VmState.absent, try vm_registry.probe(io, paths));
    rootfs_boundary.release(io);
    create_thread.join();
    try std.testing.expect(create.err != null);
    try std.testing.expectEqual(VmState.absent, try vm_registry.probe(io, paths));
}

fn openExecNamedStreamAt(context: Context, allocator: std.mem.Allocator, socket_path: []const u8, options: ExecNamedStreamOptions) !ExecNamedStream {
    var exec_stream = try monitor_protocol.openStream(allocator, context.io, socket_path, .{ .exec_stream = .{
        .argv = options.command,
        .env = options.guest_env,
        .working_dir = options.guest_working_dir,
        .stdio = if (options.tty) .tty else .pipe,
        .terminal_rows = options.terminal_size.rows,
        .terminal_cols = options.terminal_size.cols,
    } });
    errdefer exec_stream.deinit();
    if (!options.interactive) {
        if (options.tty) {
            try exec_stream.closeTerminal();
        } else {
            try exec_stream.closeStdin();
        }
    }
    return exec_stream;
}

pub const CopyDirection = enum { in, out };

fn execNamedResult(allocator: std.mem.Allocator, response: monitor_protocol.Response) !ExecNamedResult {
    const result = switch (response) {
        .exec_result => |result| result,
        .err => |failure| return monitorRequestFailed(failure.message),
        else => return error.BadMonitorResponse,
    };
    if (result.exit_code < 0 or result.exit_code > 255) return error.BadMonitorResponse;
    if (result.stdout_truncated or result.stderr_truncated) {
        const stream_name = if (result.stdout_truncated and result.stderr_truncated)
            "stdout and stderr"
        else if (result.stdout_truncated)
            "stdout"
        else
            "stderr";
        setLastError(
            "named exec {s} exceeded the bounded {d}-byte collector; use openExecNamedStream",
            .{ stream_name, exec_named_capture_limit },
        );
        return error.ExecOutputTruncated;
    }

    const stdout = try decodeControlOutput(allocator, result.stdout_b64);
    errdefer allocator.free(stdout);
    const stderr = try decodeControlOutput(allocator, result.stderr_b64);
    errdefer allocator.free(stderr);
    return .{
        .exit_code = @intCast(result.exit_code),
        .stdout = stdout,
        .stderr = stderr,
        .stdout_truncated = result.stdout_truncated,
        .stderr_truncated = result.stderr_truncated,
    };
}

pub fn monitorRequestFailed(message: ?[]const u8) error{MonitorRequestFailed} {
    if (message) |detail| {
        if (detail.len != 0) setLastError("{s}", .{detail});
    }
    return error.MonitorRequestFailed;
}

/// The error for a save the monitor did not take. A refusal for the root
/// disk's image store leaves the VM running.
fn saveFailed(name: []const u8, response: monitor_protocol.Response) error{ ImageStoreIncomplete, MonitorRequestFailed } {
    const failure = switch (response) {
        .err => |failure| failure,
        else => return error.MonitorRequestFailed,
    };
    if (failure.code != .image_store_incomplete) return monitorRequestFailed(failure.message);
    setLastError("VM {s} was not saved: {s}; the VM keeps running", .{ name, failure.message });
    return error.ImageStoreIncomplete;
}

fn diskForkPrepared(response: monitor_protocol.Response) !runtime_disk_fork_control.PreparedResponse {
    const failure = switch (response) {
        .disk_fork_prepared => |prepared| return prepared,
        .err => |failure| failure,
        else => return error.BadMonitorResponse,
    };
    return switch (failure.code orelse return monitorRequestFailed(failure.message)) {
        .fast_fork_unavailable => error.FastForkUnavailable,
        .unsupported_named_fork_disk => error.UnsupportedNamedForkDisk,
        .disk_fork_baseline_unavailable => error.DiskForkBaselineUnavailable,
        .image_store_incomplete => monitorRequestFailed(failure.message),
    };
}

fn ownedNamedLifecycleResult(allocator: std.mem.Allocator, result: NamedLifecycleResult) !NamedLifecycleResult {
    const name = try allocator.dupe(u8, result.name);
    errdefer allocator.free(name);
    const console_log_path = if (result.console_log_path) |path| try allocator.dupe(u8, path) else null;
    errdefer if (console_log_path) |path| allocator.free(path);
    const spore_dir = if (result.spore_dir) |path| try allocator.dupe(u8, path) else null;
    errdefer if (spore_dir) |path| allocator.free(path);
    var initial_command = result.initial_command;
    if (initial_command) |*initial| {
        initial.stdout = if (initial.stdout) |bytes| try allocator.dupe(u8, bytes) else null;
        errdefer if (initial.stdout) |bytes| allocator.free(bytes);
        initial.stderr = if (initial.stderr) |bytes| try allocator.dupe(u8, bytes) else null;
    }
    return .{
        .action = result.action,
        .name = name,
        .state = result.state,
        .pid = result.pid,
        .console_log_path = console_log_path,
        .spore_dir = spore_dir,
        .saved_sessions = result.saved_sessions,
        .timing = result.timing,
        .initial_command = initial_command,
    };
}

fn ownedNamedForkResult(allocator: std.mem.Allocator, result: NamedForkResult) !NamedForkResult {
    const source = try allocator.dupe(u8, result.source);
    errdefer allocator.free(source);
    const children = try allocator.alloc([]const u8, result.children.len);
    errdefer allocator.free(children);
    var child_count: usize = 0;
    errdefer {
        for (children[0..child_count]) |owned| allocator.free(owned);
    }
    for (result.children, children) |child, *out| {
        out.* = try allocator.dupe(u8, child);
        child_count += 1;
    }
    return .{
        .source = source,
        .count = result.count,
        .children = children,
        .ram_capture_ms = result.ram_capture_ms,
        .disk_fork_ms = result.disk_fork_ms,
        .source_pause_ms = result.source_pause_ms,
        .child_ready_ms = result.child_ready_ms,
    };
}

fn writeAll(io: Io, stream: net.Stream, bytes: []const u8) !void {
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn decodeControlOutput(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const dec = std.base64.standard.Decoder;
    const decoded_size = dec.calcSizeForSlice(encoded) catch return error.BadMonitorResponse;
    if (decoded_size > monitor_protocol.max_response_bytes) return error.BadMonitorResponse;
    const decoded = try allocator.alloc(u8, decoded_size);
    errdefer allocator.free(decoded);
    dec.decode(decoded, encoded) catch return error.BadMonitorResponse;
    return decoded;
}

/// Stops whoever holds a live entry's lock and returns the lock. With no
/// `pid` file the claimer has not started the monitor yet, so after a short
/// wait the entry is busy.
fn stopLockHolder(allocator: std.mem.Allocator, io: Io, paths: Paths) !Io.File {
    const start = monotonicMs();
    const pid = while (true) {
        if (readPid(allocator, io, paths)) |value| break value else |_| {}
        if (try vm_registry.tryLockForRemoval(io, paths)) |lock| return lock;
        if (monotonicMs() -| start >= monitor_shutdown_grace_ms) {
            setLastError("named VM {s} is still starting; retry once it is ready", .{std.fs.path.basename(paths.vm_dir)});
            return error.NamedVmBusy;
        }
        sleepMs(20);
    };
    // The monitor answers `shutdown` as it accepts it and then exits.
    monitor_protocol.shutdown(allocator, io, paths.control_socket_path) catch {};
    return awaitMonitorExit(io, paths, pid);
}

/// Waits for the monitor to exit, which frees the entry's lock, signalling
/// its process group after each grace period, and returns the lock.
fn awaitMonitorExit(io: Io, paths: Paths, pid: i64) !Io.File {
    if (try waitForLock(io, paths, monitor_shutdown_grace_ms)) |lock| return lock;
    signalMonitorProcessGroup(pid, .TERM);
    if (try waitForLock(io, paths, monitor_shutdown_term_ms)) |lock| return lock;
    signalMonitorProcessGroup(pid, .KILL);
    if (try waitForLock(io, paths, monitor_shutdown_kill_ms)) |lock| return lock;
    setLastError(
        "timed out waiting for named VM monitor shutdown: name={s} pid={d} monitor_log={s} control_socket={s}",
        .{ std.fs.path.basename(paths.vm_dir), pid, paths.monitor_log_path, paths.control_socket_path },
    );
    return error.MonitorShutdownTimedOut;
}

fn waitForLock(io: Io, paths: Paths, timeout_ms: u64) !?Io.File {
    const start = monotonicMs();
    while (true) {
        if (try vm_registry.tryLockForRemoval(io, paths)) |lock| return lock;
        if (monotonicMs() -| start >= timeout_ms) return null;
        sleepMs(20);
    }
}

/// Deletes an entry while holding its lock, so no prober or claimer sees a
/// half-deleted entry as live.
fn deleteLocked(io: Io, paths: Paths, lock: Io.File) !void {
    defer lock.close(io);
    try deleteVmState(io, paths);
}

fn signalMonitorProcessGroup(pid: i64, signal: std.posix.SIG) void {
    if (pid <= 0) return;
    if (comptime builtin.os.tag == .windows) return;

    const target: std.posix.pid_t = @intCast(pid);
    std.posix.kill(-target, signal) catch {
        std.posix.kill(target, signal) catch {};
    };
}

fn sleepMs(ms: u64) void {
    var ts = std.c.timespec{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast((ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);
}

pub fn monotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

pub fn monitorBackendSupported(raw: []const u8) bool {
    _ = (backend_mod.Backend.parse(raw) orelse return false).resolveForHost() catch return false;
    return true;
}

fn lessListEntry(_: void, a: ListEntry, b: ListEntry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

test "named exec response rejects truncated collector output" {
    const allocator = std.testing.allocator;
    clearLastError();
    defer clearLastError();
    try std.testing.expectError(error.ExecOutputTruncated, execNamedResult(allocator, .{ .exec_result = .{
        .exit_code = 7,
        .stdout_b64 = "b2s=",
        .stderr_b64 = "ZXJy",
        .stdout_truncated = false,
        .stderr_truncated = true,
    } }));
    try std.testing.expectEqualStrings(
        "named exec stderr exceeded the bounded 16384-byte collector; use openExecNamedStream",
        lastErrorMessage(),
    );
}

test "named exec response decodes complete bounded output" {
    const allocator = std.testing.allocator;
    const result = try execNamedResult(allocator, .{ .exec_result = .{
        .exit_code = 7,
        .stdout_b64 = "/wBB",
        .stderr_b64 = "/kI=",
        .stdout_truncated = false,
        .stderr_truncated = false,
    } });
    defer deinitExecNamedResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 7), result.exit_code);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x00, 'A' }, result.stdout);
    try std.testing.expectEqualSlices(u8, &.{ 0xfe, 'B' }, result.stderr);
}

test "named exec response preserves monitor error detail" {
    clearLastError();
    defer clearLastError();
    const message = "guest command exceeds the 8191-byte request limit; shorten it or run a script in the guest";
    try std.testing.expectError(error.MonitorRequestFailed, execNamedResult(std.testing.allocator, .{ .err = .{ .message = message } }));
    try std.testing.expectEqualStrings(message, lastErrorMessage());
}

test "lifecycle renders fork name patterns" {
    const allocator = std.testing.allocator;
    const placeholder = (try findForkNamePlaceholder("worker-%06d")).?;
    const first = try renderForkName(allocator, "worker-%06d", placeholder, 7);
    defer allocator.free(first);
    try std.testing.expectEqualStrings("worker-000007", first);

    const literal = try renderForkName(allocator, "worker", null, 0);
    defer allocator.free(literal);
    try std.testing.expectEqualStrings("worker", literal);

    const names = try renderForkNames(allocator, "worker-%d", 2);
    defer {
        for (names) |name| allocator.free(name);
        allocator.free(names);
    }
    try std.testing.expectEqualStrings("worker-0", names[0]);
    try std.testing.expectEqualStrings("worker-1", names[1]);

    try std.testing.expect(try findForkNamePlaceholder("worker") == null);
    try std.testing.expectError(error.InvalidForkNamePattern, findForkNamePlaceholder("worker-%d-%d"));
    try std.testing.expectError(error.MissingForkNamePlaceholder, renderForkNames(allocator, "worker", 2));
    try std.testing.expectError(error.InvalidVMName, renderForkNames(allocator, "-worker", 1));
}

test "runtime fork batch paths use bounded claim-safe names" {
    const allocator = std.testing.allocator;
    const path = try hiddenForkBatchDir(allocator, "/tmp/sporevm-runtime");
    defer allocator.free(path);
    const batch = std.fs.path.basename(path);
    try std.testing.expect(runtime_disk_claim.validBindingName(batch, runtime_disk_claim.max_batch_name_bytes));
    try std.testing.expect(std.mem.startsWith(u8, batch, "fork-"));
}

test "save validates annotations before touching runtime state" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(runtime_dir_env, "/tmp/sporevm-runtime");

    var annotations = spore.Annotations{};
    defer annotations.deinit(allocator);
    try annotations.map.put(allocator, "", "bad");

    try std.testing.expectError(error.BadManifest, saveContinueNamed(.{
        .io = std.testing.io,
        .environ_map = &env,
    }, allocator, .{
        .name = "bench-1",
        .out_dir = "zig-cache/missing-parent/save.spore",
        .annotations = annotations,
    }));
}

test "lifecycle liveness follows the lock holder, not its spec or pid" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_root);
    const root = try std.fs.path.join(allocator, &.{ tmp_root, "runtime" });
    defer allocator.free(root);
    const paths = try pathsFromRoot(allocator, root, "old-1");
    defer paths.deinit(allocator);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(runtime_dir_env, root);
    const context = Context{ .io = io, .environ_map = &env };

    // A sleeper holding the lock on stdin stands in for the monitor.
    var claim = try vm_registry.claim(io, paths);
    var monitor = try std.process.spawn(io, .{ .argv = &.{ "/bin/sleep", "30" }, .stdin = .{ .file = claim.lock }, .pgid = 0 });
    defer if (monitor.id != null) monitor.kill(io);
    claim.release(io);
    const monitor_pid: i64 = monitor.id.?;
    try std.testing.expectEqual(VmState.starting, try vm_registry.probe(io, paths));
    try std.testing.expectError(error.NamedVmExists, vm_registry.claim(io, paths));

    // A spec this build cannot read does not make a live VM stale.
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = paths.spec_path,
        .data = "{\"name\":\"old-1\",\"memory\":{\"policy\":\"auto\",\"bytes\":17179869184}}",
    });
    try std.testing.expectError(error.UnknownField, readSpec(allocator, io, paths));
    try writePid(allocator, io, paths, monitor_pid);
    try writeReady(allocator, io, paths, .{ .pid = monitor_pid, .control_socket_path = paths.control_socket_path });
    try std.testing.expectEqual(VmState.ready, try vm_registry.probe(io, paths));

    // `rm` stops a live holder with no control socket by signal.
    const removed = try removeNamed(context, allocator, .{ .name = "old-1" });
    defer deinitNamedLifecycleResult(allocator, removed);
    try std.testing.expectEqual(monitor_pid, removed.pid.?);
    try std.testing.expectEqual(std.process.Child.Term{ .signal = .TERM }, try monitor.wait(io));
    try std.testing.expectEqual(VmState.absent, try vm_registry.probe(io, paths));

    // A holder killed outright leaves a stale entry that `rm` deletes and
    // the name can be claimed again.
    var second_claim = try vm_registry.claim(io, paths);
    var second = try std.process.spawn(io, .{ .argv = &.{ "/bin/sleep", "30" }, .stdin = .{ .file = second_claim.lock }, .pgid = 0 });
    defer if (second.id != null) second.kill(io);
    second_claim.release(io);
    try writePid(allocator, io, paths, second.id.?);
    try writeReady(allocator, io, paths, .{ .pid = second.id.?, .control_socket_path = paths.control_socket_path });
    try std.testing.expectEqual(VmState.ready, try vm_registry.probe(io, paths));
    try std.posix.kill(second.id.?, .KILL);
    _ = try second.wait(io);
    try std.testing.expectEqual(VmState.stale, try vm_registry.probe(io, paths));
    const stale_removed = try removeNamed(context, allocator, .{ .name = "old-1" });
    defer deinitNamedLifecycleResult(allocator, stale_removed);
    try std.testing.expectEqual(VmState.absent, try vm_registry.probe(io, paths));
    var reclaimed = try vm_registry.claim(io, paths);
    reclaimed.abandon(io, paths);
}

test "lifecycle lists a VM nobody holds as stale even when its pid is alive" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_root);
    const root = try std.fs.path.join(allocator, &.{ tmp_root, "runtime" });
    defer allocator.free(root);
    const paths = try pathsFromRoot(allocator, root, "reused-pid");
    defer paths.deinit(allocator);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(runtime_dir_env, root);

    // The dead monitor's pid now names a live process of another user, so
    // kill(pid, 0) fails with EPERM.
    try ensureDirPath(io, paths.vm_dir);
    try writeSpec(allocator, io, paths, .{ .name = "reused-pid" });
    try writeReady(allocator, io, paths, .{ .pid = 1, .control_socket_path = paths.control_socket_path });
    try writePid(allocator, io, paths, 1);
    const entries = try listNamed(.{ .io = io, .environ_map = &env }, allocator, .{});
    defer freeListEntries(allocator, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("stale", entries[0].state);
}

test "lifecycle rm of a starting VM is busy" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_root);
    const root = try std.fs.path.join(allocator, &.{ tmp_root, "runtime" });
    defer allocator.free(root);
    const paths = try pathsFromRoot(allocator, root, "starting-1");
    defer paths.deinit(allocator);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(runtime_dir_env, root);

    // The claimer holds the lock and has not started a monitor, so there is
    // no pid to stop.
    var claim = try vm_registry.claim(io, paths);
    defer claim.abandon(io, paths);
    clearLastError();
    try std.testing.expectError(error.NamedVmBusy, removeNamed(.{ .io = io, .environ_map = &env }, allocator, .{ .name = "starting-1" }));
    try std.testing.expect(std.mem.indexOf(u8, lastErrorMessage(), "still starting") != null);
    try std.testing.expectEqual(VmState.starting, try vm_registry.probe(io, paths));
}

test "lifecycle fork claims every child name before contacting the source and releases them on failure" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_root);
    const root = try std.fs.path.join(allocator, &.{ tmp_root, "runtime" });
    defer allocator.free(root);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(runtime_dir_env, root);

    const source_spec = Spec{ .name = "source", .backend = "auto" };
    rejectX86NamedPersistence(source_spec) catch return error.SkipZigTest;
    // A live source whose control socket does not exist: any request to it
    // would fail the fork with a different error.
    const source = try pathsFromRoot(allocator, root, "source");
    defer source.deinit(allocator);
    var source_claim = try vm_registry.claim(io, source);
    defer source_claim.abandon(io, source);
    try writeSpec(allocator, io, source, source_spec);
    try writeReady(allocator, io, source, .{ .pid = currentTestPid(), .control_socket_path = source.control_socket_path });

    const taken = try pathsFromRoot(allocator, root, "worker-1");
    defer taken.deinit(allocator);
    var taken_claim = try vm_registry.claim(io, taken);
    defer taken_claim.abandon(io, taken);
    const taken_spec = "{\"name\":\"worker-1\",\"timeout_ms\":1234}";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = taken.spec_path, .data = taken_spec });
    try writeReady(allocator, io, taken, .{ .pid = currentTestPid(), .control_socket_path = taken.control_socket_path });

    try std.testing.expectError(error.NamedVmExists, forkNamed(.{
        .minimal = undefined,
        .arena = undefined,
        .gpa = allocator,
        .io = io,
        .environ_map = &env,
        .preopens = .empty,
    }, allocator, .{
        .source_name = "source",
        .count = 2,
        .name_pattern = "worker-%d",
        .spore_executable = "/nonexistent/spore",
    }));
    const after = try Io.Dir.cwd().readFileAlloc(io, taken.spec_path, allocator, .limited(4096));
    defer allocator.free(after);
    try std.testing.expectEqualStrings(taken_spec, after);
    const released = try pathsFromRoot(allocator, root, "worker-0");
    defer released.deinit(allocator);
    try std.testing.expectEqual(VmState.absent, try vm_registry.probe(io, released));
}

test "lifecycle fork leaves the source spec to its monitor" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_root);
    const root = try std.fs.path.join(allocator, &.{ tmp_root, "runtime" });
    defer allocator.free(root);
    const old_dir = try std.fs.path.join(allocator, &.{ tmp_root, "old.spore" });
    defer allocator.free(old_dir);
    const new_dir = try std.fs.path.join(allocator, &.{ tmp_root, "new.spore" });
    defer allocator.free(new_dir);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(runtime_dir_env, root);

    const old_digest = "blake3:" ++ test_support.repeat("a", 64);
    const new_digest = "blake3:" ++ test_support.repeat("b", 64);
    const old_disk = spore.Disk{ .device = .{ .mmio_slot = 1 }, .size = spore.disk_chunk_size, .base = old_digest };
    const source_spec = Spec{
        .name = "source",
        .backend = "auto",
        .rootfs = .{ .device = .{ .mmio_slot = 1 }, .artifact = .{ .digest = old_digest, .size = spore.disk_chunk_size } },
        .disk = old_disk,
        .disk_baseline_lease = .{ .root = old_dir, .baseline_kind = .rootfs, .baseline_identity = old_digest },
    };
    rejectX86NamedPersistence(source_spec) catch return error.SkipZigTest;
    // A live source whose control socket does not exist, so the fork fails
    // at prepare.
    const source = try pathsFromRoot(allocator, root, "source");
    defer source.deinit(allocator);
    var source_claim = try vm_registry.claim(io, source);
    defer source_claim.abandon(io, source);
    try writeSpec(allocator, io, source, source_spec);
    try writeReady(allocator, io, source, .{ .pid = currentTestPid(), .control_socket_path = source.control_socket_path });

    var read_boundary = test_barrier.Barrier{};
    testing.fork_source_read_barrier = &read_boundary;
    defer testing.fork_source_read_barrier = null;
    const Fork = struct {
        env: *std.process.Environ.Map,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            const result = forkNamed(.{
                .minimal = undefined,
                .arena = undefined,
                .gpa = std.testing.allocator,
                .io = std.testing.io,
                .environ_map = self.env,
                .preopens = .empty,
            }, std.testing.allocator, .{
                .source_name = "source",
                .count = 1,
                .name_pattern = "child-%d",
                .spore_executable = "/nonexistent/spore",
            }) catch |err| {
                self.err = err;
                return;
            };
            deinitNamedForkResult(std.testing.allocator, result);
        }
    };
    var fork = Fork{ .env = &env };
    var fork_thread = test_barrier.ThreadGuard{
        .io = io,
        .thread = try std.Thread.spawn(.{}, Fork.run, .{&fork}),
        .barriers = &.{&read_boundary},
    };
    defer fork_thread.deinit();

    // The source's monitor saves a newer disk after the fork read the spec.
    read_boundary.waitReached(io);
    var saved = source_spec;
    saved.disk.?.base = new_digest;
    saved.disk_baseline_lease = .{ .root = new_dir, .baseline_kind = .rootfs, .baseline_identity = new_digest };
    try writeSpec(allocator, io, source, saved);
    read_boundary.release(io);
    fork_thread.join();
    try std.testing.expectEqual(@as(?anyerror, error.MonitorUnavailable), fork.err);

    var after = try readSpec(allocator, io, source);
    defer after.deinit();
    try std.testing.expectEqualStrings(new_digest, after.value.disk.?.base);
    try std.testing.expectEqualStrings(new_digest, after.value.disk_baseline_lease.?.baseline_identity);
}

test "durable lifecycle metadata drops the live network policy" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var dir_dir = try TestDir.init();
    defer dir_dir.deinit();
    const dir = dir_dir.root;
    try std.testing.expect((try readSporeLifecycleSpec(allocator, io, dir)) == null);

    try writeSporeLifecycleSpec(allocator, io, dir, .{
        .name = "child",
        .network = .{ .default_action = spore.network_default_deny },
        .network_policy = "{\"egress\":{\"allowlist\":{\"cidrs\":[],\"hosts\":[],\"host_ports\":[]}},\"bound_services\":[],\"port_forwards\":[]}",
    });
    var parsed = (try readSporeLifecycleSpec(allocator, io, dir)).?;
    defer parsed.deinit();
    try std.testing.expect(parsed.value.network != null);
    try std.testing.expect(parsed.value.network_policy == null);
}

test "named exec defaults are additive portable manifest metadata" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir_dir = try TestDir.init();
    defer dir_dir.deinit();
    const dir = dir_dir.root;
    try spore.saveManifest(arena, dir, manifest_test_support.manifest(.{}));

    try writeSporeExecDefaults(arena, dir, .{
        .env = &.{ "IMAGE_VALUE=default", "CLEAR_ME=inherited" },
        .working_dir = "/workspace",
    });

    const parsed = try spore.loadManifest(arena, dir);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("IMAGE_VALUE=default", parsed.value.exec_defaults.?.env[0]);
    try std.testing.expectEqualStrings("CLEAR_ME=inherited", parsed.value.exec_defaults.?.env[1]);
    try std.testing.expectEqualStrings("/workspace", parsed.value.exec_defaults.?.working_dir.?);
}

test "named restore rejects every saved console host path authority" {
    const saved_paths = [_]?[]const u8{
        null,
        "/tmp/attacker-selected.log",
        "../../relative-escape.log",
        "/tmp/symlink-shaped/target.log",
    };
    for (saved_paths) |saved_path| {
        try std.testing.expectEqual(@as(?[]const u8, null), restoreConsoleLogPath(saved_path));
    }
}

test "initial output snapshot reports process state bytes and truncation" {
    var running_stdout = [_]u8{ 0, 0, 0, 'o', 'k' };
    var running_stderr = [_]u8{'e'};
    const running = try initialCommandResultFromSnapshot(.{
        .exit_code = 0,
        .stdout = &running_stdout,
        .stderr = &running_stderr,
    });
    try std.testing.expectEqual(InitialCommandProcessStatus.running, running.process_status.?);
    try std.testing.expectEqual(@as(?u8, null), running.exit_code);
    try std.testing.expectEqualStrings("ok", running.stdout.?);
    try std.testing.expectEqualStrings("e", running.stderr.?);

    var exited_stdout = [_]u8{ 1, 7, 3, 'x' };
    const exited = try initialCommandResultFromSnapshot(.{
        .exit_code = 0,
        .stdout = &exited_stdout,
        .stderr = &.{},
    });
    try std.testing.expectEqual(InitialCommandProcessStatus.exited, exited.process_status.?);
    try std.testing.expectEqual(@as(?u8, 7), exited.exit_code);
    try std.testing.expect(exited.stdout_truncated);
    try std.testing.expect(exited.stderr_truncated);

    var short = [_]u8{ 1, 0 };
    try std.testing.expectError(error.BadMonitorResponse, initialCommandResultFromSnapshot(.{
        .exit_code = 0,
        .stdout = &short,
        .stderr = &.{},
    }));
    var invalid_flags = [_]u8{ 1, 0, 4 };
    try std.testing.expectError(error.BadMonitorResponse, initialCommandResultFromSnapshot(.{
        .exit_code = 0,
        .stdout = &invalid_flags,
        .stderr = &.{},
    }));
    var invalid_running_exit = [_]u8{ 0, 7, 0 };
    try std.testing.expectError(error.BadMonitorResponse, initialCommandResultFromSnapshot(.{
        .exit_code = 0,
        .stdout = &invalid_running_exit,
        .stderr = &.{},
    }));
    const oversized_stderr = try std.testing.allocator.alloc(u8, @as(usize, initial_output_limit_bytes_per_stream) + 1);
    defer std.testing.allocator.free(oversized_stderr);
    var bounded_stdout = [_]u8{ 0, 0, 0 };
    try std.testing.expectError(error.BadMonitorResponse, initialCommandResultFromSnapshot(.{
        .exit_code = 0,
        .stdout = &bounded_stdout,
        .stderr = oversized_stderr,
    }));
}

test "named create hands an explicit deny-all policy to the monitor" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const network: spore_net_policy.Network = .{ .spore = .{ .egress = .deny_all } };
    const encoded = (try specNetworkPolicy(arena, &network)).?;
    const runtime = try spore_net_policy.Runtime.init(try spore_net_policy.parseArg(arena, encoded));
    try std.testing.expectEqual(spore_net_policy.Decision.deny_not_allowed, runtime.decideIpv4Port(.{ 93, 184, 216, 34 }, 443));
    const manifest_network = (try spore_net_policy.manifestNetworkFromOptions(arena, &network)).?;
    try std.testing.expectEqualStrings(spore.network_default_deny, manifest_network.default_action orelse "");

    try std.testing.expect((try specNetworkPolicy(arena, &.disabled)) == null);
}

test "new output dirs resolve to absolute paths" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    const resolved = try resolveNewOutputDirApi(arena, io, "lifecycle-test-does-not-exist.spore");
    try std.testing.expect(std.fs.path.isAbsolute(resolved));
    try std.testing.expect(std.mem.endsWith(u8, resolved, "/lifecycle-test-does-not-exist.spore"));

    try std.testing.expectError(error.OutputDirExists, resolveNewOutputDirApi(arena, io, "."));
    try std.testing.expectError(error.InvalidOutputDir, resolveNewOutputDirApi(arena, io, "lifecycle-test-missing-parent/child.spore"));
}

test "named restore active lease survives concurrent saved-spore removal and destructive collection" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const cache_root = try std.fs.path.join(arena, &.{ root, "cache" });
    const runtime_root = try std.fs.path.join(arena, &.{ root, "runtime" });
    const save_dir = try std.fs.path.join(arena, &.{ root, "saved.spore" });
    const fixture = try manifest_test_support.diskFixture(arena, io, cache_root, save_dir, 0x72);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_root);
    try env.put(local_paths.runtime_dir_env, runtime_root);
    {
        var pin_lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, cache_root);
        defer pin_lock.deinit();
        const registry = try saved_spore_pin.LockedRegistry.init(arena, cache_root, &pin_lock);
        try saved_spore_pin.publishManifest(io, arena, registry, save_dir, fixture.disk, fixture.manifest);
    }

    var restore_boundary = test_barrier.Barrier{};
    testing.named_restore_authority_barrier = &restore_boundary;
    defer testing.named_restore_authority_barrier = null;
    var restore_ready = Io.Semaphore{};
    var restore_finish = Io.Semaphore{};
    const RestoreContext = struct {
        allocator: std.mem.Allocator,
        io: Io,
        env: *const std.process.Environ.Map,
        save_dir: []const u8,
        disk: spore.Disk,
        object_path: []const u8,
        object_digest: []const u8,
        expected: []const u8,
        ready: *Io.Semaphore,
        finish: *Io.Semaphore,
        read_ok: bool = false,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            defer if (testing.named_restore_authority_barrier) |barrier| barrier.reached.post(self.io);
            var handoff = leaseForSavedDisk(self.io, self.allocator, self.env, self.save_dir, self.disk) catch |err| {
                self.err = err;
                self.ready.post(self.io);
                return;
            };
            defer if (handoff.active) |*active| active.deinit();
            self.ready.post(self.io);
            self.finish.waitUncancelable(self.io);
            const bytes = rootfs_cas.readVerifiedChunkPath(self.allocator, self.object_path, self.object_digest, self.expected.len) catch |err| {
                self.err = err;
                return;
            };
            defer self.allocator.free(bytes);
            self.read_ok = std.mem.eql(u8, bytes, self.expected);
        }
    };
    var restore_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer restore_arena_state.deinit();
    const object_path = try rootfs_cas.manifestObjectPath(arena, cache_root, fixture.object_digest);
    var restore_context = RestoreContext{
        .allocator = restore_arena_state.allocator(),
        .io = io,
        .env = &env,
        .save_dir = save_dir,
        .disk = fixture.disk,
        .object_path = object_path,
        .object_digest = fixture.object_digest,
        .expected = fixture.object_bytes,
        .ready = &restore_ready,
        .finish = &restore_finish,
    };
    var restore_thread = test_barrier.ThreadGuard{
        .io = io,
        .thread = try std.Thread.spawn(.{}, RestoreContext.run, .{&restore_context}),
        .barriers = &.{&restore_boundary},
    };
    defer restore_thread.deinit();
    restore_boundary.waitReached(io);
    if (restore_context.err) |err| return err;

    var remove_boundary = test_barrier.Barrier{};
    var gc_boundary = test_barrier.Barrier{};
    var prune_boundary = test_barrier.Barrier{};
    saved_spore_pin.testing.remove_mutation_barrier = &remove_boundary;
    defer saved_spore_pin.testing.remove_mutation_barrier = null;
    system.testing.gc_mutation_barrier = &gc_boundary;
    defer system.testing.gc_mutation_barrier = null;
    system.testing.prune_mutation_barrier = &prune_boundary;
    defer system.testing.prune_mutation_barrier = null;
    const DestructiveContext = struct {
        allocator: std.mem.Allocator,
        io: Io,
        cache_root: []const u8,
        runtime_root: []const u8,
        save_dir: []const u8,
        env: *const std.process.Environ.Map,
        attempting: *Io.Semaphore,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            defer {
                if (saved_spore_pin.testing.remove_mutation_barrier) |barrier| barrier.reached.post(self.io);
                if (system.testing.gc_mutation_barrier) |barrier| barrier.reached.post(self.io);
                if (system.testing.prune_mutation_barrier) |barrier| barrier.reached.post(self.io);
            }
            self.attempting.post(self.io);
            const removed = removeSavedSpore(.{ .io = self.io, .environ_map = self.env }, self.allocator, self.save_dir) catch |err| {
                self.err = err;
                return;
            };
            deinitRemovedSavedSpore(self.allocator, removed);
            const gc_result = system.gc(self.allocator, self.io, .{ .cache_root = self.cache_root, .runtime_root = self.runtime_root, .dry_run = false }) catch |err| {
                self.err = err;
                return;
            };
            system.deinitRootfsGcResult(self.allocator, gc_result);
            const prune_result = system.prune(self.allocator, self.io, .{
                .cache_root = self.cache_root,
                .runtime_root = self.runtime_root,
                .dry_run = false,
                .include_rootfs_chunks = true,
                .max_bytes = 0,
                .rootfs_only = true,
            }, Io.Clock.real.now(self.io).nanoseconds) catch |err| {
                self.err = err;
                return;
            };
            system.deinitRootfsPruneResult(self.allocator, prune_result);
        }
    };
    var destructive_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer destructive_arena_state.deinit();
    var destructive_attempting = Io.Semaphore{};
    var destructive_context = DestructiveContext{
        .allocator = destructive_arena_state.allocator(),
        .io = io,
        .cache_root = cache_root,
        .runtime_root = runtime_root,
        .save_dir = save_dir,
        .env = &env,
        .attempting = &destructive_attempting,
    };
    var destructive_thread = test_barrier.ThreadGuard{
        .io = io,
        .thread = try std.Thread.spawn(.{}, DestructiveContext.run, .{&destructive_context}),
        .barriers = &.{ &remove_boundary, &gc_boundary, &prune_boundary },
    };
    defer destructive_thread.deinit();
    destructive_attempting.waitUncancelable(io);
    restore_boundary.release(io);
    restore_ready.waitUncancelable(io);
    if (restore_context.err) |err| return err;
    remove_boundary.waitReached(io);
    if (destructive_context.err) |err| return err;
    remove_boundary.release(io);
    gc_boundary.waitReached(io);
    if (destructive_context.err) |err| return err;
    gc_boundary.release(io);
    prune_boundary.waitReached(io);
    if (destructive_context.err) |err| return err;
    prune_boundary.release(io);
    destructive_thread.join();
    if (destructive_context.err) |err| return err;
    _ = try Io.Dir.cwd().statFile(io, object_path, .{ .follow_symlinks = false });
    restore_finish.post(io);
    restore_thread.join();
    if (restore_context.err) |err| return err;
    try std.testing.expect(restore_context.read_ok);
}
test "lifecycle list entries sorts and classifies VM directories" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var root_dir = try TestDir.init();
    defer root_dir.deinit();
    const root = try root_dir.path("runtime");

    const empty = try listEntries(allocator, io, root);
    defer freeListEntries(allocator, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const stale = try pathsFromRoot(allocator, root, "b-stale");
    defer stale.deinit(allocator);
    const stale_spore_dir = try std.fs.path.resolve(allocator, &.{ root, "b-stale.spore" });
    defer allocator.free(stale_spore_dir);
    try ensureDirPath(io, stale_spore_dir);
    const stale_backing_path = try std.fs.path.resolve(allocator, &.{ stale_spore_dir, spore.ram_backing_path });
    defer allocator.free(stale_backing_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = stale_backing_path, .data = "backing-bytes" });
    var stale_claim = try vm_registry.claim(io, stale);
    stale_claim.release(io);
    try writeSpec(allocator, io, stale, .{
        .name = "b-stale",
        .resume_dir = stale_spore_dir,
        .memory = memory_config.Config.fixed(512 * 1024 * 1024),
    });
    try writeReady(allocator, io, stale, .{
        .pid = 9001,
        .control_socket_path = stale.control_socket_path,
        .console_log_path = stale.console_log_path,
    });
    try writePid(allocator, io, stale, 9001);

    const ready = try pathsFromRoot(allocator, root, "a-ready");
    defer ready.deinit(allocator);
    const ready_pid = currentTestPid();
    var ready_claim = try vm_registry.claim(io, ready);
    defer ready_claim.release(io);
    try writeSpec(allocator, io, ready, .{
        .name = "a-ready",
        .memory = .{ .initial_bytes = 512 * 1024 * 1024, .maximum_bytes = 16 * 1024 * 1024 * 1024 },
    });
    try writeReady(allocator, io, ready, .{
        .pid = ready_pid,
        .control_socket_path = ready.control_socket_path,
        .console_log_path = ready.console_log_path,
    });
    try writePid(allocator, io, ready, ready_pid);
    try writeMonitorStats(allocator, io, ready, .{
        .chunks_nonzero = 17,
        .dirty_chunks_pending = 2,
    });

    const entries = try listEntries(allocator, io, root);
    defer freeListEntries(allocator, entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("a-ready", entries[0].name);
    try std.testing.expectEqualStrings("ready", entries[0].state);
    try std.testing.expectEqual(@as(?i64, ready_pid), entries[0].pid);
    try std.testing.expectEqual(memory_config.default_bytes, entries[0].memory.?.initial_bytes);
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024 * 1024), entries[0].memory.?.maximum_bytes);
    if (readProcessResidentBytes(allocator, io, ready_pid) != null) {
        try std.testing.expect(entries[0].stats.resident_bytes != null);
    } else if (!(comptime builtin.os.tag == .linux or builtin.os.tag.isDarwin())) {
        try std.testing.expectEqual(@as(?u64, null), entries[0].stats.resident_bytes);
    }
    const chunk_size: u64 = spore.chunk_size;
    try std.testing.expectEqual(@as(?u64, chunk_size), entries[0].stats.chunk_size);
    try std.testing.expectEqual(@as(?u64, (16 * 1024 * 1024 * 1024) / chunk_size), entries[0].stats.chunks_total);
    try std.testing.expectEqual(@as(?u64, 17), entries[0].stats.chunks_nonzero);
    try std.testing.expectEqual(@as(?u64, 2), entries[0].stats.dirty_chunks_pending);
    try std.testing.expectEqualStrings("b-stale", entries[1].name);
    try std.testing.expectEqualStrings("stale", entries[1].state);
    try std.testing.expectEqual(@as(?i64, 9001), entries[1].pid);
    try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), entries[1].memory.?.initial_bytes);
    try std.testing.expectEqual(entries[1].memory.?.initial_bytes, entries[1].memory.?.maximum_bytes);
    try std.testing.expectEqual(@as(?u64, 13), entries[1].stats.backing_logical_bytes);
    try std.testing.expect(entries[1].stats.backing_allocated_bytes != null);
    try std.testing.expectEqual(@as(?u64, 256), entries[1].stats.chunks_total);
}

test "saved-spore removal machine output names only the removed directory" {
    const allocator = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try machine_output.writeJson(allocator, &out.writer, RemovedSavedSpore{ .spore_dir = "disk.spore" });
    try std.testing.expectEqualStrings(
        "{\n" ++
            "  \"schema\": \"spore.saved.remove.result.v2\",\n" ++
            "  \"schema_version\": 2,\n" ++
            "  \"resource_type\": \"checkpoint\",\n" ++
            "  \"action\": \"removed_spore\",\n" ++
            "  \"spore_dir\": \"disk.spore\"\n" ++
            "}\n",
        out.written(),
    );
}

test "initial output machine result preserves invalid UTF-8 as bytes" {
    const allocator = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var invalid_stdout = [_]u8{ 0xff, 'A' };

    try machine_output.writeJson(allocator, &out.writer, NamedLifecycleResult{
        .action = "logs",
        .name = "worker-1",
        .state = "ready",
        .initial_command = .{
            .output_disposition = .retain,
            .output_destination = .named_logs,
            .output_limit_bytes_per_stream = initial_output_limit_bytes_per_stream,
            .process_status = .exited,
            .exit_code = 0,
            .stdout = &invalid_stdout,
            .stderr = &.{},
        },
    });

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.written(), .{});
    defer parsed.deinit();
    const initial = parsed.value.object.get("initial_command").?.object;
    const stdout = initial.get("stdout").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), stdout.len);
    try std.testing.expectEqual(@as(i64, 255), stdout[0].integer);
    try std.testing.expectEqual(@as(i64, 65), stdout[1].integer);
}

test "lifecycle list JSON exposes memory and nullable stats" {
    const allocator = std.testing.allocator;
    const json = try std.json.Stringify.valueAlloc(allocator, ListEntry{
        .name = "a-ready",
        .state = "ready",
        .pid = 42,
        .memory = listMemoryFromConfig(.{}),
    }, .{});
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"resource_type\":\"live_vm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"memory\":{\"initial_bytes\":536870912,\"maximum_bytes\":536870912}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stats\":{\"resident_bytes\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dirty_chunks_pending\":null") != null);
}

test "linux statm resident parser reads resident pages" {
    try std.testing.expectEqual(@as(u64, 12 * 4096), try linuxStatmResidentBytes("99 12 3 4 5 6 7\n", 4096));
    try std.testing.expectError(error.InvalidProcessStat, linuxStatmResidentBytes("99\n", 4096));
}

fn currentTestPid() i64 {
    return if (comptime builtin.os.tag == .windows) 1 else @intCast(std.c.getpid());
}

test "save reports the monitor's refusal for a root disk's image store" {
    clearLastError();
    defer clearLastError();
    const message = "the image store of the root disk could not supply every object: ImageStoreNotFound";
    try std.testing.expectEqual(error.ImageStoreIncomplete, saveFailed("app", .{ .err = .{ .message = message, .code = .image_store_incomplete } }));
    try std.testing.expectEqualStrings("VM app was not saved: " ++ message ++ "; the VM keeps running", lastErrorMessage());
    clearLastError();
    try std.testing.expectEqual(error.MonitorRequestFailed, saveFailed("app", .{ .err = .{ .message = "monitor busy" } }));
    try std.testing.expectEqualStrings("monitor busy", lastErrorMessage());
}

test "fork maps the monitor's typed refusals to their errors" {
    clearLastError();
    defer clearLastError();
    try std.testing.expectError(error.FastForkUnavailable, diskForkPrepared(.{ .err = .{
        .message = "disk fork capture failed: FastForkUnavailable",
        .code = .fast_fork_unavailable,
    } }));
    try std.testing.expectError(error.DiskForkBaselineUnavailable, diskForkPrepared(.{ .err = .{
        .message = "DiskForkBaselineUnavailable",
        .code = .disk_fork_baseline_unavailable,
    } }));
    try std.testing.expectError(error.MonitorRequestFailed, diskForkPrepared(.{ .err = .{ .message = "the source VM has no rootfs" } }));
    try std.testing.expectEqualStrings("the source VM has no rootfs", lastErrorMessage());
}
