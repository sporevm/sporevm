//! Named VM lifecycle registry and CLI shape.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;

const Context = @import("context.zig").Context;
const local_paths = @import("local_paths.zig");
const machine_output = @import("machine_output.zig");
const memory_config = @import("memory.zig");
const run_mod = @import("run.zig");
const spore = @import("spore.zig");
const spore_net_policy = @import("spore_net_policy.zig");

pub const runtime_dir_env = local_paths.runtime_dir_env;
pub const max_name_len = 128;

const max_metadata_bytes = 128 * 1024;
const max_control_response = 128 * 1024;
const lifecycle_spore_metadata_file = "sporevm-lifecycle.json";
const diskless_resume_device_count = 4;
const spec_file = "spec.json";
const ready_file = "ready.json";
const create_timing_file = "create-timing.json";
const monitor_timing_file = "monitor-timing.json";
const pid_file = "pid";
const control_socket_file = "control.sock";
const console_log_file = "console.log";
const private_dir_permissions: Io.File.Permissions = if (builtin.os.tag == .windows)
    .default_dir
else
    @enumFromInt(0o700);

const create_usage =
    \\Usage:
    \\  spore create NAME [options]
    \\
    \\Options:
    \\  --backend auto|hvf|kvm  Backend to run (default: auto)
    \\  --kernel Image          Kernel Image path
    \\  --initrd root.cpio      Initrd path (default: embedded minimal exec initrd)
    \\  --rootfs rootfs.ext4    Attach rootfs image read-only as virtio-blk
    \\  --image REF             Build or reuse cached OCI rootfs
    \\  --pull=missing|always|never
    \\                          Pull policy for mutable --image refs (default: missing)
    \\  --net                   Experimental SporeVM-managed networking
    \\  --allow-cidr CIDR       With --net, restrict public egress to this CIDR
    \\  --allow-host HOST       With --net, restrict public egress to DNS A answers for this host
    \\  --memory VALUE          Guest memory: auto, 512mb, 2gb, ... (default: auto = 16GiB)
    \\  --vcpus N               Guest vCPU count; must be 1 today
    \\  --guest-port N          Guest vsock listen port (default: 10700)
    \\  --timeout-ms N          Exec timeout in milliseconds (default: 30000)
    \\  --console-log PATH      Write guest console output to PATH
    \\  -h, --help              Show this help
    \\
;

const exec_usage =
    \\Usage:
    \\  spore exec NAME -- <argv...>
    \\
    \\Options:
    \\  -h, --help              Show this help
    \\
;

const rm_usage =
    \\Usage:
    \\  spore rm NAME
    \\
    \\Options:
    \\  -h, --help              Show this help
    \\
;

const suspend_usage =
    \\Usage:
    \\  spore suspend NAME --out DIR
    \\
    \\Options:
    \\  --out DIR              Write a spore checkpoint to DIR
    \\  -h, --help             Show this help
    \\
;

const fork_usage =
    \\Usage:
    \\  spore fork --vm NAME --count N --name PATTERN
    \\
    \\Options:
    \\  --vm NAME             Running named VM to fork from
    \\  --count N             Number of named child VMs to create
    \\  --name PATTERN        Child VM name or pattern, e.g. worker-%d
    \\  -h, --help            Show this help
    \\
;

const resume_usage =
    \\Usage:
    \\  spore resume DIR --name NAME
    \\
    \\Options:
    \\  --name NAME            Name for the resumed VM
    \\  -h, --help             Show this help
    \\
;

const ls_usage =
    \\Usage:
    \\  spore ls
    \\
    \\Options:
    \\  -h, --help              Show this help
    \\
    \\Machine output:
    \\  spore --json ls         Emit the VM list as JSON
    \\
;

pub const Paths = struct {
    runtime_root: []const u8,
    vms_dir: []const u8,
    vm_dir: []const u8,
    spec_path: []const u8,
    ready_path: []const u8,
    create_timing_path: []const u8,
    monitor_timing_path: []const u8,
    pid_path: []const u8,
    control_socket_path: []const u8,
    console_log_path: []const u8,

    pub fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_root);
        allocator.free(self.vms_dir);
        allocator.free(self.vm_dir);
        allocator.free(self.spec_path);
        allocator.free(self.ready_path);
        allocator.free(self.create_timing_path);
        allocator.free(self.monitor_timing_path);
        allocator.free(self.pid_path);
        allocator.free(self.control_socket_path);
        allocator.free(self.console_log_path);
    }
};

pub const Spec = struct {
    name: []const u8,
    backend: []const u8 = "auto",
    kernel_path: ?[]const u8 = null,
    initrd_path: ?[]const u8 = null,
    rootfs_path: ?[]const u8 = null,
    rootfs: ?spore.Rootfs = null,
    disk: ?spore.Disk = null,
    network: ?spore.Network = null,
    annotations: spore.Annotations = .{},
    image_ref: ?[]const u8 = null,
    resume_dir: ?[]const u8 = null,
    memory: memory_config.Config = .{},
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    console_log_path: ?[]const u8 = null,
};

pub const Ready = struct {
    pid: i64,
    control_socket_path: []const u8,
    console_log_path: []const u8,
};

pub const CreateTiming = struct {
    version: u32 = 1,
    parse_ms: u64,
    paths_ms: u64,
    state_check_ms: u64,
    rootfs_resolve_ms: u64,
    rootfs_abspath_ms: u64,
    spawn_monitor_ms: u64,
    wait_ready_ms: u64,
    total_ms: u64,
};

pub const MonitorTiming = struct {
    version: u32 = 1,
    parse_ms: u64,
    paths_ms: u64,
    asset_resolve_ms: u64,
    metadata_ms: u64,
    ready_after_start_ms: u64,
};

pub const VmState = enum {
    absent,
    incomplete,
    ready,
    stale,

    pub fn name(self: VmState) []const u8 {
        return switch (self) {
            .absent => "absent",
            .incomplete => "incomplete",
            .ready => "ready",
            .stale => "stale",
        };
    }
};

pub const ListEntry = struct {
    name: []const u8,
    state: []const u8,
    pid: ?i64 = null,
    memory: ?ListMemory = null,
    stats: ListStats = .{},
};

pub const ListMemory = struct {
    policy: []const u8,
    bytes: u64,
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

pub const LifecycleResult = struct {
    schema: []const u8 = lifecycle_schema,
    schema_version: u32 = lifecycle_schema_version,
    action: []const u8,
    name: []const u8,
    state: []const u8,
    pid: ?i64 = null,
    control_socket_path: ?[]const u8 = null,
    console_log_path: ?[]const u8 = null,
    spore_dir: ?[]const u8 = null,
};

const CreateOptions = struct {
    spec: Spec,
    image_pull_policy: run_mod.PullPolicy = .missing,
    network: run_mod.NetworkMode = .disabled,
    network_policy: run_mod.NetworkPolicy = .{},
};

const ExecOptions = struct {
    name: []const u8,
    command: []const []const u8,
};

const SuspendOptions = struct {
    name: []const u8,
    out_dir: []const u8,
};

const ForkOptions = struct {
    source_name: []const u8,
    count: usize,
    name_pattern: []const u8,
};

const ResumeOptions = struct {
    spore_dir: []const u8,
    name: []const u8,
};

pub const NamedForkResult = struct {
    source: []const u8,
    count: usize,
    children: []const []const u8,
};

pub const ForkNamedOptions = struct {
    source_name: []const u8,
    count: usize,
    name_pattern: []const u8,
    spore_executable: []const u8 = "spore",
};

pub const NamedNetworkOptions = struct {
    enabled: bool = false,
    allow_cidrs: []const []const u8 = &.{},
    allow_hosts: []const []const u8 = &.{},
    policy: spore_net_policy.NetworkPolicy = .{},
    bound_services: []const spore_net_policy.BoundService = &.{},
};

pub const CreateNamedOptions = struct {
    name: []const u8,
    backend: run_mod.Backend = .auto,
    kernel_path: ?[]const u8 = null,
    initrd_path: ?[]const u8 = null,
    rootfs_path: ?[]const u8 = null,
    image_ref: ?[]const u8 = null,
    image_pull_policy: run_mod.PullPolicy = .missing,
    network: NamedNetworkOptions = .{},
    memory: memory_config.Config = .{},
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    console_log_path: ?[]const u8 = null,
    spore_executable: []const u8 = "spore",
    annotations: spore.Annotations = .{},
};

pub const ResumeNamedOptions = struct {
    spore_dir: []const u8,
    name: []const u8,
    spore_executable: []const u8 = "spore",
};

pub const ExecNamedOptions = struct {
    name: []const u8,
    command: []const []const u8,
    network_policy: ?spore_net_policy.NetworkPolicy = null,
};

pub const SnapshotNamedOptions = struct {
    name: []const u8,
    out_dir: []const u8,
    continue_after: bool = true,
    annotations: spore.Annotations = .{},
};

pub const SuspendNamedOptions = struct {
    name: []const u8,
    out_dir: []const u8,
};

pub const RemoveNamedOptions = struct {
    name: []const u8,
};

pub const ListNamedOptions = struct {};

pub const NamedLifecycleResult = struct {
    schema: []const u8 = lifecycle_schema,
    schema_version: u32 = lifecycle_schema_version,
    action: []const u8,
    name: []const u8,
    state: []const u8,
    pid: ?i64 = null,
    console_log_path: ?[]const u8 = null,
    spore_dir: ?[]const u8 = null,
};

pub const ExecNamedResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
    network_events_jsonl: []u8 = &.{},
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
};

const NamedNetworkConfig = struct {
    mode: run_mod.NetworkMode = .disabled,
    policy: run_mod.NetworkPolicy = .{},
};

fn namedNetworkConfig(options: NamedNetworkOptions) !NamedNetworkConfig {
    if (!options.enabled) {
        if (options.allow_cidrs.len != 0 or
            options.allow_hosts.len != 0 or
            options.policy.allow.len != 0 or
            options.bound_services.len != 0) return error.InvalidNetworkPolicy;
        return .{};
    }
    var config = run_mod.NetworkPolicy{};
    for (options.allow_cidrs) |cidr| {
        try config.addAllowCidr(cidr);
    }
    for (options.allow_hosts) |host| {
        try config.addAllowHost(host);
    }
    if (options.policy.allow.len != 0) {
        try config.addNetworkPolicy(options.policy);
    }
    for (options.bound_services) |service| {
        try config.addBoundService(service);
    }
    return .{ .mode = .spore, .policy = config };
}

pub fn createNamed(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: CreateNamedOptions,
) !NamedLifecycleResult {
    const start_ms = monotonicMs();
    return createNamedWithTiming(init, allocator, options, .{
        .start_ms = start_ms,
        .parsed_ms = start_ms,
    });
}

const CreateTimingAnchors = struct {
    start_ms: u64,
    parsed_ms: u64,
};

fn createNamedWithTiming(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: CreateNamedOptions,
    timing: CreateTimingAnchors,
) !NamedLifecycleResult {
    if (options.rootfs_path != null and options.image_ref != null) return error.InvalidRootfsInput;
    if (!monitorBackendSupported(options.backend.name())) return error.HostUnsupported;
    try spore.validateAnnotations(options.annotations);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const named_network = try namedNetworkConfig(options.network);

    var spec = Spec{
        .name = options.name,
        .backend = options.backend.name(),
        .kernel_path = options.kernel_path,
        .initrd_path = options.initrd_path,
        .rootfs_path = options.rootfs_path,
        .image_ref = options.image_ref,
        .network = try run_mod.manifestNetworkFromOptions(arena, named_network.mode, &named_network.policy),
        .memory = options.memory,
        .vcpus = options.vcpus,
        .guest_port = options.guest_port,
        .timeout_ms = options.timeout_ms,
        .console_log_path = options.console_log_path,
        .annotations = options.annotations,
    };
    const paths = try apiPaths(.{ .io = init.io, .environ_map = init.environ_map }, arena, spec.name);
    const paths_ms = monotonicMs();
    const state = try classifyVmState(arena, init.io, paths, pidAlive);
    if (state != .absent) return error.NamedVmExists;
    const state_checked_ms = monotonicMs();

    const rootfs = try run_mod.resolveRootfsInputDetailed(init, arena, .{
        .rootfs_path = spec.rootfs_path,
        .image_ref = spec.image_ref,
        .pull_policy = options.image_pull_policy,
        .command_name = "create",
        .record_artifact = spec.rootfs_path != null or spec.image_ref != null,
    });
    const rootfs_resolved_ms = monotonicMs();
    spec.rootfs_path = if (rootfs.path) |path| try std.fs.path.resolve(arena, &.{path}) else null;
    spec.rootfs = rootfs.rootfs;
    const rootfs_abspath_ms = monotonicMs();
    if (spec.rootfs != null or !spore.annotationsEmpty(spec.annotations)) try writeSpec(arena, init.io, paths, spec);

    const spawn_policy: ?*const run_mod.NetworkPolicy = if (named_network.mode == .spore) &named_network.policy else null;
    try spawnMonitorExecutable(init, arena, spec, options.spore_executable, spawn_policy);
    const monitor_spawned_ms = monotonicMs();
    try waitForReadyResult(arena, init.io, paths, spec.timeout_ms);
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

    var ready = try readReady(arena, init.io, paths);
    defer ready.deinit();
    return ownedNamedLifecycleResult(allocator, .{
        .action = "created",
        .name = spec.name,
        .state = "ready",
        .pid = ready.value.pid,
        .console_log_path = ready.value.console_log_path,
    });
}

pub fn resumeNamed(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: ResumeNamedOptions,
) !NamedLifecycleResult {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const spore_dir = try resolveExistingSporeDirApi(arena, init.io, options.spore_dir);
    var manifest = spore.loadManifest(arena, spore_dir) catch return error.InvalidSporeDir;
    defer manifest.deinit();
    const network_options = run_mod.networkOptionsFromManifest(arena, manifest.value.network) catch return error.InvalidNetworkPolicy;
    const rootfs = try run_mod.resumeRootfsForRun(arena, manifest.value);
    const disk = try run_mod.resumeDiskForRun(arena, manifest.value);
    if (rootfs == null and manifest.value.devices.len != diskless_resume_device_count) return error.UnsupportedLifecycleDeviceModel;
    const memory = memoryFromManifest(manifest.value) catch return error.InvalidMemorySize;

    var lifecycle_spec = readSporeLifecycleSpec(arena, init.io, spore_dir) catch return error.InvalidLifecycleMetadata;
    defer if (lifecycle_spec) |*spec| spec.deinit();
    if (lifecycle_spec) |spec| {
        if (spec.value.vcpus != 1) return error.UnsupportedLifecycleMetadata;
    }

    const base = if (lifecycle_spec) |spec| spec.value else Spec{ .name = options.name };
    const spec = Spec{
        .name = options.name,
        .backend = base.backend,
        .kernel_path = base.kernel_path,
        .initrd_path = base.initrd_path,
        .resume_dir = spore_dir,
        .rootfs = rootfs,
        .disk = disk,
        .network = try run_mod.manifestNetworkFromOptions(arena, network_options.network, &network_options.policy),
        .annotations = manifest.value.annotations,
        .memory = memory,
        .vcpus = 1,
        .guest_port = base.guest_port,
        .timeout_ms = base.timeout_ms,
        .console_log_path = base.console_log_path,
    };
    if (!monitorBackendSupported(spec.backend)) return error.HostUnsupported;

    const paths = try apiPaths(.{ .io = init.io, .environ_map = init.environ_map }, arena, spec.name);
    const state = try classifyVmState(arena, init.io, paths, pidAlive);
    if (state != .absent) return error.NamedVmExists;
    if (spec.rootfs != null or spec.disk != null or !spore.annotationsEmpty(spec.annotations)) try writeSpec(arena, init.io, paths, spec);

    const spawn_policy: ?*const run_mod.NetworkPolicy = if (network_options.network == .spore) &network_options.policy else null;
    try spawnMonitorExecutable(init, arena, spec, options.spore_executable, spawn_policy);
    try waitForReadyResult(arena, init.io, paths, spec.timeout_ms);

    var ready = try readReady(arena, init.io, paths);
    defer ready.deinit();
    return ownedNamedLifecycleResult(allocator, .{
        .action = "resumed",
        .name = spec.name,
        .state = "ready",
        .pid = ready.value.pid,
        .console_log_path = ready.value.console_log_path,
        .spore_dir = spore_dir,
    });
}

pub fn execNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: ExecNamedOptions,
) !ExecNamedResult {
    if (options.command.len == 0) return error.InvalidGuestCommand;
    if (options.network_policy != null) return error.UnsupportedNetworkPolicyUpdate;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths = try apiPaths(context, arena, options.name);
    const state = try classifyVmState(arena, context.io, paths, pidAlive);
    if (state != .ready) return error.NamedVmNotReady;
    var ready = try readReady(arena, context.io, paths);
    defer ready.deinit();
    const response = try sendExecRequest(arena, context.io, ready.value.control_socket_path, options.command);
    return parseExecNamedResponse(allocator, arena, response);
}

pub fn snapshotNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: SnapshotNamedOptions,
) !NamedLifecycleResult {
    if (!options.continue_after) return error.UnsupportedSnapshotMode;
    try spore.validateAnnotations(options.annotations);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out_dir = try resolveNewOutputDirApi(arena, context.io, options.out_dir);
    const paths = try apiPaths(context, arena, options.name);
    const state = try classifyVmState(arena, context.io, paths, pidAlive);
    if (state != .ready) return error.NamedVmNotReady;
    var spec = try readSpec(arena, context.io, paths);
    defer spec.deinit();
    if ((spec.value.rootfs_path != null or spec.value.image_ref != null) and spec.value.rootfs == null) {
        return error.MissingRootfsIdentity;
    }
    var ready = try readReady(arena, context.io, paths);
    defer ready.deinit();
    const response = try sendSnapshotRequest(arena, context.io, ready.value.control_socket_path, out_dir);
    if (!try snapshotResponseOk(arena, response)) return error.MonitorRequestFailed;
    var snapshot_spec = spec.value;
    if (!spore.annotationsEmpty(options.annotations)) {
        var manifest = try spore.loadManifest(arena, out_dir);
        defer manifest.deinit();
        manifest.value.annotations = try spore.mergeAnnotations(arena, manifest.value.annotations, options.annotations);
        try spore.saveManifest(arena, out_dir, manifest.value);
        snapshot_spec.annotations = manifest.value.annotations;
    }
    try writeSporeLifecycleSpec(arena, context.io, out_dir, snapshot_spec);
    return ownedNamedLifecycleResult(allocator, .{
        .action = "snapshotted",
        .name = options.name,
        .state = "ready",
        .pid = ready.value.pid,
        .spore_dir = out_dir,
    });
}

pub fn suspendNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: SuspendNamedOptions,
) !NamedLifecycleResult {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out_dir = try resolveNewOutputDirApi(arena, context.io, options.out_dir);
    const paths = try apiPaths(context, arena, options.name);
    const state = try classifyVmState(arena, context.io, paths, pidAlive);
    if (state != .ready) return error.NamedVmNotReady;
    var spec = try readSpec(arena, context.io, paths);
    defer spec.deinit();
    if ((spec.value.rootfs_path != null or spec.value.image_ref != null) and spec.value.rootfs == null) {
        return error.MissingRootfsIdentity;
    }
    var ready = try readReady(arena, context.io, paths);
    defer ready.deinit();
    const response = try sendSuspendRequest(arena, context.io, ready.value.control_socket_path, out_dir);
    if (try suspendResponseFailureMessage(arena, response) != null) return error.MonitorRequestFailed;

    var cleanup_after_suspend = true;
    defer if (cleanup_after_suspend) {
        waitForPidExit(ready.value.pid, 5_000);
        Io.Dir.cwd().deleteTree(context.io, paths.vm_dir) catch {};
    };
    try writeSporeLifecycleSpec(arena, context.io, out_dir, spec.value);
    cleanup_after_suspend = false;
    waitForPidExit(ready.value.pid, 5_000);
    try Io.Dir.cwd().deleteTree(context.io, paths.vm_dir);
    return ownedNamedLifecycleResult(allocator, .{
        .action = "suspended",
        .name = options.name,
        .state = "checkpointed",
        .pid = ready.value.pid,
        .spore_dir = out_dir,
    });
}

pub fn forkNamed(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: ForkNamedOptions,
) !NamedForkResult {
    if (options.count == 0) return error.InvalidForkCount;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const context = Context{ .io = init.io, .environ_map = init.environ_map };

    const child_names = try renderForkNames(arena, options.name_pattern, options.count);
    const source_paths = try apiPaths(context, arena, options.source_name);
    const state = try classifyVmState(arena, init.io, source_paths, pidAlive);
    if (state != .ready) return error.NamedVmNotReady;

    var source_spec = readSpec(arena, init.io, source_paths) catch return error.NamedVmNotReady;
    defer source_spec.deinit();
    if (source_spec.value.rootfs_path != null or source_spec.value.image_ref != null or source_spec.value.rootfs != null or source_spec.value.disk != null) {
        return error.UnsupportedNamedForkDisk;
    }
    if (source_spec.value.network != null) return error.UnsupportedNamedForkNetwork;
    if (source_spec.value.vcpus != 1) return error.UnsupportedNamedForkVcpu;

    for (child_names) |child_name| {
        const child_paths = try apiPaths(context, arena, child_name);
        const child_state = try classifyVmState(arena, init.io, child_paths, pidAlive);
        if (child_state != .absent) return error.NamedVmExists;
    }

    var ready = readReady(arena, init.io, source_paths) catch return error.NamedVmNotReady;
    defer ready.deinit();

    const batch_dir = try hiddenForkBatchDir(arena, source_paths.runtime_root, options.source_name);
    const snapshot_dir = try std.fs.path.resolve(arena, &.{ batch_dir, "source.spore" });
    const children_dir = try std.fs.path.resolve(arena, &.{ batch_dir, "children" });
    try ensureDirPath(init.io, batch_dir);
    var cleanup_batch = true;
    defer if (cleanup_batch) Io.Dir.cwd().deleteTree(init.io, batch_dir) catch {};

    const response = try sendSnapshotRequest(arena, init.io, ready.value.control_socket_path, snapshot_dir);
    if (!(snapshotResponseOk(arena, response) catch return error.BadMonitorResponse)) return error.MonitorRequestFailed;
    try writeSporeLifecycleSpec(arena, init.io, snapshot_dir, source_spec.value);

    _ = try spore.fork(arena, .{
        .parent_dir = snapshot_dir,
        .out_dir = children_dir,
        .count = options.count,
        .environ_map = init.environ_map,
    });

    var started = std.array_list.Managed([]const u8).init(arena);
    for (child_names, 0..) |child_name, index| {
        const spore_dir = try childSporeDir(arena, children_dir, index);
        startForkChildExecutable(init, arena, child_name, spore_dir, source_spec.value, options.spore_executable) catch |err| {
            cleanupStartedChildren(init, arena, started.items);
            return err;
        };
        try started.append(child_name);
    }

    cleanup_batch = false;
    return ownedNamedForkResult(allocator, .{
        .source = options.source_name,
        .count = options.count,
        .children = child_names,
    });
}

pub fn removeNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: RemoveNamedOptions,
) !NamedLifecycleResult {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths = try apiPaths(context, arena, options.name);
    const state = try classifyVmState(arena, context.io, paths, pidAlive);
    var removed_pid: ?i64 = null;
    switch (state) {
        .absent => return error.NamedVmNotFound,
        .ready => {
            var ready = try readReady(arena, context.io, paths);
            defer ready.deinit();
            removed_pid = ready.value.pid;
            _ = sendShutdownRequest(arena, context.io, ready.value.control_socket_path) catch {};
            waitForPidExit(ready.value.pid, 5_000);
            try Io.Dir.cwd().deleteTree(context.io, paths.vm_dir);
        },
        .incomplete, .stale => {
            removed_pid = readPid(arena, context.io, paths) catch null;
            try Io.Dir.cwd().deleteTree(context.io, paths.vm_dir);
        },
    }
    return ownedNamedLifecycleResult(allocator, .{
        .action = "removed",
        .name = options.name,
        .state = "absent",
        .pid = removed_pid,
    });
}

pub fn listNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: ListNamedOptions,
) ![]ListEntry {
    _ = options;
    const root = try runtimeRootPath(allocator, context.environ_map);
    defer allocator.free(root);
    return listEntries(allocator, context.io, root, pidAlive);
}

pub fn deinitNamedLifecycleResult(allocator: std.mem.Allocator, result: NamedLifecycleResult) void {
    allocator.free(result.name);
    if (result.console_log_path) |path| allocator.free(path);
    if (result.spore_dir) |path| allocator.free(path);
}

pub fn deinitExecNamedResult(allocator: std.mem.Allocator, result: ExecNamedResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    allocator.free(result.network_events_jsonl);
}

pub fn deinitNamedForkResult(allocator: std.mem.Allocator, result: NamedForkResult) void {
    allocator.free(result.source);
    for (result.children) |child| allocator.free(child);
    allocator.free(result.children);
}

pub fn createCli(
    init: std.process.Init,
    args: []const []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) !void {
    const start_ms = monotonicMs();
    if (wantsHelp(args)) {
        if (mode == .json) {
            exitLifecycleCliError(
                init.arena.allocator(),
                stderr,
                mode,
                machine_output.usageInvalidArgument("spore --json create does not support help output", "create"),
                "spore --json create does not support help output",
            );
        }
        try stdout.writeAll(create_usage);
        return;
    }
    if (args.len == 0) {
        exitLifecycleCliError(
            init.arena.allocator(),
            stderr,
            mode,
            machine_output.usageMissingArgument("usage: spore create NAME [options]", "create"),
            create_usage,
        );
    }

    const allocator = init.arena.allocator();
    const parsed = try parseCreateArgs(args, allocator, stderr, mode);
    const parsed_ms = monotonicMs();
    const spec = parsed.spec;
    const full_args = try init.minimal.args.toSlice(allocator);
    const result = createNamedWithTiming(init, allocator, .{
        .name = spec.name,
        .backend = run_mod.Backend.parse(spec.backend) orelse unreachable,
        .kernel_path = spec.kernel_path,
        .initrd_path = spec.initrd_path,
        .rootfs_path = spec.rootfs_path,
        .image_ref = spec.image_ref,
        .image_pull_policy = parsed.image_pull_policy,
        .network = .{
            .enabled = parsed.network == .spore,
            .allow_cidrs = if (parsed.network == .spore) parsed.network_policy.allowCidrSlice() else &.{},
            .allow_hosts = if (parsed.network == .spore) parsed.network_policy.allowHostSlice() else &.{},
        },
        .memory = spec.memory,
        .vcpus = spec.vcpus,
        .guest_port = spec.guest_port,
        .timeout_ms = spec.timeout_ms,
        .console_log_path = spec.console_log_path,
        .spore_executable = full_args[0],
    }, .{
        .start_ms = start_ms,
        .parsed_ms = parsed_ms,
    }) catch |err| switch (err) {
        error.InvalidRuntimeDir, error.InsecureRuntimeDir => exitLifecycleRuntimePathError(allocator, stderr, mode, "create", err),
        error.HostUnsupported => {
            const message = "spore create: monitor mode requires HVF on Apple Silicon or KVM on Linux/aarch64";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.host_unsupported, message, "create"), message);
        },
        error.NamedVmExists => {
            const message = allocLifecycleMessage(allocator, "spore create: VM already exists or has stale state: {s}", .{spec.name});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
        },
        error.InvalidNetworkPolicy, error.InvalidRootfsInput => {
            const message = allocLifecycleMessage(allocator, "spore create: invalid configuration: {s}", .{@errorName(err)});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
        },
        error.FileNotFound => {
            const message = "spore create: required rootfs object was not found";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_not_found, message, "create"), message);
        },
        error.MonitorReadyTimeout => {
            const message = "spore create: timed out waiting for monitor readiness";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_start_failed, message, "create"), message);
        },
        else => |e| return e,
    };
    defer deinitNamedLifecycleResult(allocator, result);
    if (mode == .json) {
        try machine_output.writeJson(allocator, stdout, result);
    }
}

pub fn execCli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (wantsHelp(args)) {
        try stdout.writeAll(exec_usage);
        return;
    }
    const parsed = parseExecArgs(args);
    const allocator = init.arena.allocator();
    const result = execNamed(.{
        .io = init.io,
        .environ_map = init.environ_map,
    }, allocator, .{
        .name = parsed.name,
        .command = parsed.command,
    }) catch |err| switch (err) {
        error.InvalidRuntimeDir, error.InsecureRuntimeDir => cliRuntimePathExit("exec", err),
        error.NamedVmNotReady => {
            std.debug.print("spore exec: VM is not ready: {s}\n", .{parsed.name});
            std.process.exit(2);
        },
        error.MonitorUnavailable, error.MonitorRequestFailed, error.BadMonitorResponse => {
            switch (err) {
                error.MonitorUnavailable => std.debug.print("spore exec: monitor is unavailable for VM: {s}\n", .{parsed.name}),
                else => std.debug.print("spore exec: monitor request failed for VM {s}: {s}\n", .{ parsed.name, @errorName(err) }),
            }
            std.process.exit(1);
        },
        else => |e| return e,
    };
    defer deinitExecNamedResult(allocator, result);
    try writeExecNamedResult(stdout, result);
    if (result.exit_code != 0) std.process.exit(result.exit_code);
}

pub fn rmCli(
    init: std.process.Init,
    args: []const []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) !void {
    if (wantsHelp(args)) {
        if (mode == .json) {
            exitLifecycleCliError(
                init.arena.allocator(),
                stderr,
                mode,
                machine_output.usageInvalidArgument("spore --json rm does not support help output", "rm"),
                "spore --json rm does not support help output",
            );
        }
        try stdout.writeAll(rm_usage);
        return;
    }
    const allocator = init.arena.allocator();
    const name = parseRmArgs(args, allocator, stderr, mode);
    const result = removeNamed(.{
        .io = init.io,
        .environ_map = init.environ_map,
    }, allocator, .{ .name = name }) catch |err| switch (err) {
        error.InvalidRuntimeDir, error.InsecureRuntimeDir => exitLifecycleRuntimePathError(allocator, stderr, mode, "rm", err),
        error.NamedVmNotFound => {
            const message = allocLifecycleMessage(allocator, "spore rm: VM not found: {s}", .{name});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_not_found, message, "rm"), message);
        },
        else => |e| return e,
    };
    defer deinitNamedLifecycleResult(allocator, result);
    if (mode == .json) {
        try machine_output.writeJson(allocator, stdout, result);
    }
}

pub fn suspendCli(
    init: std.process.Init,
    args: []const []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) !void {
    if (wantsHelp(args)) {
        if (mode == .json) {
            exitLifecycleCliError(
                init.arena.allocator(),
                stderr,
                mode,
                machine_output.usageInvalidArgument("spore --json suspend does not support help output", "suspend"),
                "spore --json suspend does not support help output",
            );
        }
        try stdout.writeAll(suspend_usage);
        return;
    }
    const allocator = init.arena.allocator();
    const parsed = parseSuspendArgs(args, allocator, stderr, mode);
    const result = suspendNamed(.{
        .io = init.io,
        .environ_map = init.environ_map,
    }, allocator, .{
        .name = parsed.name,
        .out_dir = parsed.out_dir,
    }) catch |err| switch (err) {
        error.InvalidRuntimeDir, error.InsecureRuntimeDir => exitLifecycleRuntimePathError(allocator, stderr, mode, "suspend", err),
        error.NamedVmNotReady => {
            const message = allocLifecycleMessage(allocator, "spore suspend: VM is not ready: {s}", .{parsed.name});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "suspend"), message);
        },
        error.MissingRootfsIdentity => {
            const message = "spore suspend: disk-backed lifecycle suspend requires recorded immutable rootfs identity";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "suspend"), message);
        },
        error.MonitorUnavailable, error.MonitorRequestFailed => {
            const message = switch (err) {
                error.MonitorUnavailable => allocLifecycleMessage(allocator, "spore suspend: monitor is unavailable for VM: {s}", .{parsed.name}),
                else => allocLifecycleMessage(allocator, "spore suspend: monitor request failed for VM {s}: {s}", .{ parsed.name, @errorName(err) }),
            };
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_execution_failed, message, "suspend"), message);
        },
        else => |e| return e,
    };
    defer deinitNamedLifecycleResult(allocator, result);
    if (mode == .json) {
        try machine_output.writeJson(allocator, stdout, result);
    }
}

pub fn forkCli(
    init: std.process.Init,
    args: []const []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) !void {
    if (wantsHelp(args)) {
        if (mode == .json) {
            exitLifecycleCliError(
                init.arena.allocator(),
                stderr,
                mode,
                machine_output.usageInvalidArgument("spore --json fork does not support help output", "fork"),
                "spore --json fork does not support help output",
            );
        }
        try stdout.writeAll(fork_usage);
        return;
    }

    const allocator = init.arena.allocator();
    const parsed = parseForkArgs(args, allocator, stderr, mode);
    const full_args = try init.minimal.args.toSlice(allocator);
    const result = forkNamed(init, allocator, .{
        .source_name = parsed.source_name,
        .count = parsed.count,
        .name_pattern = parsed.name_pattern,
        .spore_executable = full_args[0],
    }) catch |err| switch (err) {
        error.InvalidRuntimeDir, error.InsecureRuntimeDir => exitLifecycleRuntimePathError(allocator, stderr, mode, "fork", err),
        error.InvalidForkNamePattern => {
            const message = "spore fork: --name must contain at most one %d or %0Nd placeholder";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.MissingForkNamePlaceholder => {
            const message = "spore fork: --name must contain %d when --count is greater than 1";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.InvalidVMName => {
            const message = "spore fork: rendered VM name is invalid";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.DuplicateForkName => {
            const message = "spore fork: duplicate rendered VM name";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.NamedVmNotReady => {
            const message = allocLifecycleMessage(allocator, "spore fork: VM is not ready: {s}", .{parsed.source_name});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "fork"), message);
        },
        error.UnsupportedNamedForkDisk => {
            const message = "spore fork: disk-backed named live fork is not supported yet";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.UnsupportedNamedForkNetwork => {
            const message = "spore fork: networked named live fork is not supported yet";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.UnsupportedNamedForkVcpu => {
            const message = "spore fork: multi-vCPU named live fork is not supported yet";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.NamedVmExists => {
            const message = "spore fork: VM already exists or has stale state";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.MonitorUnavailable, error.MonitorRequestFailed, error.BadMonitorResponse => {
            const message = allocLifecycleMessage(allocator, "spore fork: monitor request failed for VM {s}: {s}", .{ parsed.source_name, @errorName(err) });
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_execution_failed, message, "fork"), message);
        },
        error.MonitorReadyTimeout => {
            const message = "spore fork: timed out waiting for monitor readiness";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_start_failed, message, "fork"), message);
        },
        else => |e| return e,
    };
    defer deinitNamedForkResult(allocator, result);
    if (mode == .json) {
        try machine_output.writeJson(allocator, stdout, result);
    } else {
        try writeNamedForkResult(stdout, result);
    }
}

pub fn resumeCli(
    init: std.process.Init,
    args: []const []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) !void {
    if (wantsHelp(args)) {
        if (mode == .json) {
            exitLifecycleCliError(
                init.arena.allocator(),
                stderr,
                mode,
                machine_output.usageInvalidArgument("spore --json resume does not support help output", "resume"),
                "spore --json resume does not support help output",
            );
        }
        try stdout.writeAll(resume_usage);
        return;
    }
    const allocator = init.arena.allocator();
    const parsed = parseResumeArgs(args, allocator, stderr, mode);
    const full_args = try init.minimal.args.toSlice(allocator);
    const result = resumeNamed(init, allocator, .{
        .spore_dir = parsed.spore_dir,
        .name = parsed.name,
        .spore_executable = full_args[0],
    }) catch |err| switch (err) {
        error.InvalidRuntimeDir, error.InsecureRuntimeDir => exitLifecycleRuntimePathError(allocator, stderr, mode, "resume", err),
        error.FileNotFound => {
            const message = "spore resume: spore directory is not available";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_not_found, message, "resume"), message);
        },
        error.InvalidSporeDir => {
            const message = allocLifecycleMessage(allocator, "spore resume: invalid spore directory: {s}", .{parsed.spore_dir});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "resume"), message);
        },
        error.InvalidNetworkPolicy => {
            const message = "spore resume: invalid network policy in manifest";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "resume"), message);
        },
        error.UnsupportedLifecycleDeviceModel => {
            const message = "spore resume: unsupported lifecycle device model";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "resume"), message);
        },
        error.InvalidMemorySize => {
            const message = "spore resume: invalid spore memory size";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "resume"), message);
        },
        error.InvalidLifecycleMetadata => {
            const message = "spore resume: invalid lifecycle metadata";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "resume"), message);
        },
        error.UnsupportedLifecycleMetadata => {
            const message = "spore resume: multi-vCPU lifecycle metadata is not supported yet";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "resume"), message);
        },
        error.HostUnsupported => {
            const message = "spore resume: monitor mode requires HVF on Apple Silicon or KVM on Linux/aarch64";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.host_unsupported, message, "resume"), message);
        },
        error.NamedVmExists => {
            const message = allocLifecycleMessage(allocator, "spore resume: VM already exists or has stale state: {s}", .{parsed.name});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "resume"), message);
        },
        error.MonitorReadyTimeout => {
            const message = "spore resume: timed out waiting for monitor readiness";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_start_failed, message, "resume"), message);
        },
        else => |e| return e,
    };
    defer deinitNamedLifecycleResult(allocator, result);
    if (mode == .json) {
        try machine_output.writeJson(allocator, stdout, result);
    }
}

pub fn lsCli(
    init: std.process.Init,
    args: []const []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) !void {
    if (wantsHelp(args)) {
        if (mode == .json) {
            exitLifecycleCliError(
                init.arena.allocator(),
                stderr,
                mode,
                machine_output.usageInvalidArgument("spore --json ls does not support help output", "ls"),
                "spore --json ls does not support help output",
            );
        }
        try stdout.writeAll(ls_usage);
        return;
    }
    if (args.len != 0) {
        if (args.len == 1 and std.mem.eql(u8, args[0], "--json")) {
            exitLifecycleCliError(
                init.arena.allocator(),
                stderr,
                mode,
                machine_output.usageInvalidArgument("spore ls: use global --json before the command", "ls"),
                "spore ls: use global --json before the command",
            );
        }
        const message = "usage: spore ls";
        exitLifecycleCliError(
            init.arena.allocator(),
            stderr,
            mode,
            machine_output.usageInvalidArgument(message, "ls"),
            ls_usage,
        );
    }

    const allocator = init.arena.allocator();
    const entries = listNamed(.{
        .io = init.io,
        .environ_map = init.environ_map,
    }, allocator, .{}) catch |err| switch (err) {
        error.InvalidRuntimeDir, error.InsecureRuntimeDir => exitLifecycleRuntimePathError(allocator, stderr, mode, "ls", err),
        else => |e| return e,
    };
    defer freeListEntries(allocator, entries);
    if (mode == .json) {
        try machine_output.writeJson(allocator, stdout, entries);
    } else {
        try writeListEntries(stdout, entries);
    }
}

fn writeListEntries(writer: *Io.Writer, entries: []const ListEntry) !void {
    if (entries.len == 0) {
        try writer.writeAll("No VMs\n");
        return;
    }

    try writer.writeAll("NAME\tSTATE\tPID\tMEMORY\tRESIDENT\tBACKING\tCHUNKS\tDIRTY\n");
    for (entries) |entry| {
        try writer.print("{s}\t{s}\t", .{ entry.name, entry.state });
        if (entry.pid) |pid| {
            try writer.print("{d}", .{pid});
        } else {
            try writer.writeByte('-');
        }
        try writer.writeByte('\t');
        if (entry.memory) |memory| {
            try writeMemoryValue(writer, memory);
        } else {
            try writer.writeByte('?');
        }
        try writer.writeByte('\t');
        try writeOptionalBytesHuman(writer, entry.stats.resident_bytes);
        try writer.writeByte('\t');
        try writeBackingStats(writer, entry.stats);
        try writer.writeByte('\t');
        try writeChunkStats(writer, entry.stats);
        try writer.writeByte('\t');
        try writeOptionalCount(writer, entry.stats.dirty_chunks_pending);
        try writer.writeByte('\n');
    }
}

pub fn validateName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidVMName;
    if (name.len > max_name_len) return error.InvalidVMName;
    if (!std.ascii.isAlphanumeric(name[0])) return error.InvalidVMName;
    for (name[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return error.InvalidVMName;
    }
}

pub fn runtimeRootPath(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    return local_paths.runtimeRootPath(allocator, environ);
}

pub fn pathsFor(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, name: []const u8) !Paths {
    const root = try runtimeRootPath(allocator, environ);
    defer allocator.free(root);
    return pathsFromRoot(allocator, root, name);
}

pub fn pathsFromRoot(allocator: std.mem.Allocator, runtime_root: []const u8, name: []const u8) !Paths {
    try validateName(name);
    const runtime_root_owned = try allocator.dupe(u8, runtime_root);
    errdefer allocator.free(runtime_root_owned);
    const vms_dir = try std.fs.path.resolve(allocator, &.{ runtime_root, "vms" });
    errdefer allocator.free(vms_dir);
    const vm_dir = try std.fs.path.resolve(allocator, &.{ vms_dir, name });
    errdefer allocator.free(vm_dir);
    const spec_path = try std.fs.path.resolve(allocator, &.{ vm_dir, spec_file });
    errdefer allocator.free(spec_path);
    const ready_path = try std.fs.path.resolve(allocator, &.{ vm_dir, ready_file });
    errdefer allocator.free(ready_path);
    const create_timing_path = try std.fs.path.resolve(allocator, &.{ vm_dir, create_timing_file });
    errdefer allocator.free(create_timing_path);
    const monitor_timing_path = try std.fs.path.resolve(allocator, &.{ vm_dir, monitor_timing_file });
    errdefer allocator.free(monitor_timing_path);
    const pid_path = try std.fs.path.resolve(allocator, &.{ vm_dir, pid_file });
    errdefer allocator.free(pid_path);
    const control_socket_path = try std.fs.path.resolve(allocator, &.{ vm_dir, control_socket_file });
    errdefer allocator.free(control_socket_path);
    const console_log_path = try std.fs.path.resolve(allocator, &.{ vm_dir, console_log_file });
    return .{
        .runtime_root = runtime_root_owned,
        .vms_dir = vms_dir,
        .vm_dir = vm_dir,
        .spec_path = spec_path,
        .ready_path = ready_path,
        .create_timing_path = create_timing_path,
        .monitor_timing_path = monitor_timing_path,
        .pid_path = pid_path,
        .control_socket_path = control_socket_path,
        .console_log_path = console_log_path,
    };
}

pub fn writeSpec(allocator: std.mem.Allocator, io: Io, paths: Paths, spec: Spec) !void {
    try ensureVmDir(io, paths);
    const json = try std.json.Stringify.valueAlloc(allocator, spec, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = paths.spec_path, .data = json });
}

pub fn readSpec(allocator: std.mem.Allocator, io: Io, paths: Paths) !std.json.Parsed(Spec) {
    const data = try Io.Dir.cwd().readFileAlloc(io, paths.spec_path, allocator, .limited(max_metadata_bytes));
    defer allocator.free(data);
    const parsed = try std.json.parseFromSlice(Spec, allocator, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    return parsed;
}

pub fn writeReady(allocator: std.mem.Allocator, io: Io, paths: Paths, ready: Ready) !void {
    try ensureVmDir(io, paths);
    const json = try std.json.Stringify.valueAlloc(allocator, ready, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = paths.ready_path, .data = json });
}

pub fn readReady(allocator: std.mem.Allocator, io: Io, paths: Paths) !std.json.Parsed(Ready) {
    const data = try Io.Dir.cwd().readFileAlloc(io, paths.ready_path, allocator, .limited(max_metadata_bytes));
    defer allocator.free(data);
    return std.json.parseFromSlice(Ready, allocator, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

pub fn writeCreateTiming(allocator: std.mem.Allocator, io: Io, paths: Paths, timing: CreateTiming) !void {
    try writeTimingJson(allocator, io, paths.create_timing_path, timing);
}

pub fn writeMonitorTiming(allocator: std.mem.Allocator, io: Io, paths: Paths, timing: MonitorTiming) !void {
    try writeTimingJson(allocator, io, paths.monitor_timing_path, timing);
}

fn writeTimingJson(allocator: std.mem.Allocator, io: Io, path: []const u8, timing: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, timing, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
}

pub fn writePid(allocator: std.mem.Allocator, io: Io, paths: Paths, pid: i64) !void {
    if (pid <= 0) return error.InvalidPid;
    try ensureVmDir(io, paths);
    const data = try std.fmt.allocPrint(allocator, "{d}\n", .{pid});
    defer allocator.free(data);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = paths.pid_path, .data = data });
}

pub fn readPid(allocator: std.mem.Allocator, io: Io, paths: Paths) !i64 {
    const data = try Io.Dir.cwd().readFileAlloc(io, paths.pid_path, allocator, .limited(64));
    defer allocator.free(data);
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidPid;
    const pid = try std.fmt.parseInt(i64, trimmed, 10);
    if (pid <= 0) return error.InvalidPid;
    return pid;
}

pub const PidAliveFn = *const fn (pid: i64) bool;

pub fn classifyVmState(allocator: std.mem.Allocator, io: Io, paths: Paths, pid_alive: PidAliveFn) !VmState {
    const stat = Io.Dir.cwd().statFile(io, paths.vm_dir, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => |e| return e,
    };
    if (stat.kind != Io.File.Kind.directory) return error.InvalidVMState;

    var spec = readSpec(allocator, io, paths) catch |err| switch (err) {
        error.FileNotFound => return .stale,
        else => return .stale,
    };
    defer spec.deinit();
    if (!std.mem.eql(u8, spec.value.name, std.fs.path.basename(paths.vm_dir))) return .stale;
    var ready = readReady(allocator, io, paths) catch |err| switch (err) {
        error.FileNotFound => return .incomplete,
        else => return .stale,
    };
    defer ready.deinit();

    const pid = readPid(allocator, io, paths) catch return .stale;
    if (ready.value.pid != pid) return .stale;
    return if (pid_alive(pid)) .ready else .stale;
}

pub fn listEntries(allocator: std.mem.Allocator, io: Io, runtime_root: []const u8, pid_alive: PidAliveFn) ![]ListEntry {
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
        const state = try classifyVmState(allocator, io, paths, pid_alive);
        if (state == .absent) continue;
        const pid = if (state == .ready or state == .stale) readPid(allocator, io, paths) catch null else null;
        const metadata = readListMetadata(allocator, io, paths) catch null;
        try entries.append(.{
            .name = try allocator.dupe(u8, entry.name),
            .state = state.name(),
            .pid = pid,
            .memory = if (metadata) |value| value.memory else null,
            .stats = if (metadata) |value| value.stats else .{},
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

fn listMemoryFromConfig(memory: memory_config.Config) ListMemory {
    return .{
        .policy = @tagName(memory.policy),
        .bytes = memory.bytes,
    };
}

fn listStatsFromMemory(memory: ListMemory) ListStats {
    const chunk_size: u64 = spore.chunk_size;
    return .{
        .chunk_size = chunk_size,
        .chunks_total = std.math.divCeil(u64, memory.bytes, chunk_size) catch unreachable,
    };
}

fn readBackingFileStats(allocator: std.mem.Allocator, dir: []const u8) !ListStats {
    const backing_path = try std.fs.path.resolve(allocator, &.{ dir, spore.ram_backing_path });
    defer allocator.free(backing_path);
    const backing_path_z = try allocator.dupeZ(u8, backing_path);
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

fn writeMemoryValue(writer: *Io.Writer, memory: ListMemory) !void {
    if (std.mem.eql(u8, memory.policy, "auto")) {
        try writer.writeAll("auto/");
    }
    try writeBytesHuman(writer, memory.bytes);
}

fn writeBytesHuman(writer: *Io.Writer, bytes: u64) !void {
    const gib: u64 = 1024 * 1024 * 1024;
    const mib: u64 = 1024 * 1024;
    if (bytes % gib == 0) {
        try writer.print("{d}GiB", .{bytes / gib});
    } else if (bytes % mib == 0) {
        try writer.print("{d}MiB", .{bytes / mib});
    } else {
        try writer.print("{d}B", .{bytes});
    }
}

fn writeOptionalBytesHuman(writer: *Io.Writer, value: ?u64) !void {
    if (value) |bytes| {
        try writeBytesHuman(writer, bytes);
    } else {
        try writer.writeByte('?');
    }
}

fn writeBackingStats(writer: *Io.Writer, stats: ListStats) !void {
    if (stats.backing_logical_bytes == null and stats.backing_allocated_bytes == null) {
        try writer.writeByte('?');
        return;
    }
    try writeOptionalBytesHuman(writer, stats.backing_allocated_bytes);
    try writer.writeByte('/');
    try writeOptionalBytesHuman(writer, stats.backing_logical_bytes);
}

fn writeChunkStats(writer: *Io.Writer, stats: ListStats) !void {
    if (stats.chunks_total == null and stats.chunks_nonzero == null) {
        try writer.writeByte('?');
        return;
    }
    try writeOptionalCount(writer, stats.chunks_nonzero);
    try writer.writeByte('/');
    try writeOptionalCount(writer, stats.chunks_total);
}

fn writeOptionalCount(writer: *Io.Writer, value: ?u64) !void {
    if (value) |count| {
        try writer.print("{d}", .{count});
    } else {
        try writer.writeByte('?');
    }
}

fn parseCreateArgs(
    args: []const []const u8,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) !CreateOptions {
    var name: ?[]const u8 = null;
    var spec = Spec{ .name = "" };
    var image_pull_policy: run_mod.PullPolicy = .missing;
    var network: run_mod.NetworkMode = .disabled;
    var network_policy = run_mod.NetworkPolicy{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--backend")) {
            spec.backend = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            if (run_mod.Backend.parse(spec.backend) == null) {
                const message = "--backend must be auto, hvf, or kvm";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            }
        } else if (std.mem.eql(u8, args[i], "--kernel")) {
            spec.kernel_path = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--initrd")) {
            spec.initrd_path = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--rootfs")) {
            spec.rootfs_path = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--image")) {
            spec.image_ref = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--pull")) {
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            image_pull_policy = run_mod.PullPolicy.parse(raw) orelse {
                const message = "spore create: --pull must be missing, always, or never";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
        } else if (std.mem.startsWith(u8, args[i], "--pull=")) {
            const raw = args[i]["--pull=".len..];
            image_pull_policy = run_mod.PullPolicy.parse(raw) orelse {
                const message = "spore create: --pull must be missing, always, or never";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
        } else if (std.mem.eql(u8, args[i], "--net")) {
            network = .spore;
        } else if (std.mem.eql(u8, args[i], "--allow-cidr")) {
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            network_policy.addAllowCidr(raw) catch |err| {
                const message = allocLifecycleMessage(allocator, "spore create: invalid --allow-cidr {s}: {s}", .{ raw, @errorName(err) });
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
        } else if (std.mem.eql(u8, args[i], "--allow-host")) {
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            network_policy.addAllowHost(raw) catch |err| {
                const message = allocLifecycleMessage(allocator, "spore create: invalid --allow-host {s}: {s}", .{ raw, @errorName(err) });
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
        } else if (std.mem.eql(u8, args[i], "--memory")) {
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            spec.memory = memory_config.parse(raw) catch |err| {
                const message = allocLifecycleMessage(
                    allocator,
                    "spore create: --memory must be auto or a positive page-aligned size like 512mb or 16gb ({s})",
                    .{@errorName(err)},
                );
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
        } else if (std.mem.eql(u8, args[i], "--memory-mib")) {
            const message = "spore create: --memory-mib has been replaced by --memory";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
        } else if (std.mem.eql(u8, args[i], "--vcpus")) {
            const flag = args[i];
            spec.vcpus = parseIntArgLifecycleCli(u32, allocator, stderr, mode, "create", takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, flag), flag);
        } else if (std.mem.eql(u8, args[i], "--guest-port")) {
            const flag = args[i];
            spec.guest_port = parseIntArgLifecycleCli(u32, allocator, stderr, mode, "create", takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, flag), flag);
        } else if (std.mem.eql(u8, args[i], "--timeout-ms")) {
            const flag = args[i];
            spec.timeout_ms = parseIntArgLifecycleCli(u64, allocator, stderr, mode, "create", takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, flag), flag);
        } else if (std.mem.eql(u8, args[i], "--console-log")) {
            spec.console_log_path = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            const message = allocLifecycleMessage(allocator, "unknown create argument: {s}", .{args[i]});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
        } else if (name == null) {
            validateNameLifecycleCli(allocator, stderr, mode, "create", args[i]);
            name = args[i];
            spec.name = args[i];
        } else {
            const message = allocLifecycleMessage(allocator, "unexpected create argument: {s}", .{args[i]});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
        }
    }

    if (name == null) {
        exitLifecycleCliError(
            allocator,
            stderr,
            mode,
            machine_output.usageMissingArgument("usage: spore create NAME [options]", "create"),
            create_usage,
        );
    }
    if (spec.rootfs_path != null and spec.image_ref != null) {
        const message = "spore create: --rootfs and --image are mutually exclusive";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
    }
    if (spec.image_ref == null and image_pull_policy != .missing) {
        const message = "spore create: --pull requires --image";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
    }
    if (network == .disabled and network_policy.hasRules()) {
        const message = "spore create: --allow-cidr and --allow-host require --net";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
    }
    return .{
        .spec = spec,
        .image_pull_policy = image_pull_policy,
        .network = network,
        .network_policy = network_policy,
    };
}

fn parseExecArgs(args: []const []const u8) ExecOptions {
    if (args.len < 3 or !std.mem.eql(u8, args[1], "--")) usageExit(exec_usage);
    validateNameOrExit("exec", args[0]) catch unreachable;
    const command = args[2..];
    if (command.len == 0) usageExit(exec_usage);
    return .{ .name = args[0], .command = command };
}

fn parseRmArgs(args: []const []const u8, allocator: std.mem.Allocator, stderr: *Io.Writer, mode: machine_output.Mode) []const u8 {
    if (args.len != 1) {
        exitLifecycleCliError(
            allocator,
            stderr,
            mode,
            machine_output.usageMissingArgument("usage: spore rm NAME", "rm"),
            rm_usage,
        );
    }
    validateNameLifecycleCli(allocator, stderr, mode, "rm", args[0]);
    return args[0];
}

fn parseSuspendArgs(
    args: []const []const u8,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) SuspendOptions {
    var name: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out")) {
            out_dir = takeValueLifecycleCli(allocator, stderr, mode, "suspend", args, &i, args[i]);
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            const message = allocLifecycleMessage(allocator, "unknown suspend argument: {s}", .{args[i]});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "suspend"), message);
        } else if (name == null) {
            validateNameLifecycleCli(allocator, stderr, mode, "suspend", args[i]);
            name = args[i];
        } else {
            const message = allocLifecycleMessage(allocator, "unexpected suspend argument: {s}", .{args[i]});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "suspend"), message);
        }
    }

    if (name == null or out_dir == null) {
        exitLifecycleCliError(
            allocator,
            stderr,
            mode,
            machine_output.usageMissingArgument("usage: spore suspend NAME --out DIR", "suspend"),
            suspend_usage,
        );
    }
    return .{ .name = name.?, .out_dir = out_dir.? };
}

fn parseForkArgs(
    args: []const []const u8,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) ForkOptions {
    var source_name: ?[]const u8 = null;
    var count: ?usize = null;
    var name_pattern: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--vm")) {
            source_name = takeValueLifecycleCli(allocator, stderr, mode, "fork", args, &i, args[i]);
            validateNameLifecycleCli(allocator, stderr, mode, "fork", source_name.?);
        } else if (std.mem.eql(u8, args[i], "--count")) {
            const flag = args[i];
            count = parseIntArgLifecycleCli(usize, allocator, stderr, mode, "fork", takeValueLifecycleCli(allocator, stderr, mode, "fork", args, &i, flag), flag);
        } else if (std.mem.eql(u8, args[i], "--name")) {
            name_pattern = takeValueLifecycleCli(allocator, stderr, mode, "fork", args, &i, args[i]);
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            const message = allocLifecycleMessage(allocator, "unknown fork argument: {s}", .{args[i]});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        } else {
            const message = allocLifecycleMessage(allocator, "unexpected fork argument: {s}", .{args[i]});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        }
    }

    if (source_name == null or count == null or name_pattern == null) {
        exitLifecycleCliError(
            allocator,
            stderr,
            mode,
            machine_output.usageMissingArgument("usage: spore fork --vm NAME --count N --name PATTERN", "fork"),
            fork_usage,
        );
    }
    if (count.? == 0) {
        const message = "spore fork: --count must be a positive integer";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
    }
    return .{
        .source_name = source_name.?,
        .count = count.?,
        .name_pattern = name_pattern.?,
    };
}

fn parseResumeArgs(
    args: []const []const u8,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) ResumeOptions {
    var spore_dir: ?[]const u8 = null;
    var name: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--name")) {
            name = takeValueLifecycleCli(allocator, stderr, mode, "resume", args, &i, args[i]);
            validateNameLifecycleCli(allocator, stderr, mode, "resume", name.?);
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            const message = allocLifecycleMessage(allocator, "unknown resume argument: {s}", .{args[i]});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "resume"), message);
        } else if (spore_dir == null) {
            spore_dir = args[i];
        } else {
            const message = allocLifecycleMessage(allocator, "unexpected resume argument: {s}", .{args[i]});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "resume"), message);
        }
    }

    if (spore_dir == null or name == null) {
        exitLifecycleCliError(
            allocator,
            stderr,
            mode,
            machine_output.usageMissingArgument("usage: spore resume DIR --name NAME", "resume"),
            resume_usage,
        );
    }
    return .{ .spore_dir = spore_dir.?, .name = name.? };
}

fn cliPaths(init: std.process.Init, allocator: std.mem.Allocator, command: []const u8, name: []const u8) !Paths {
    const paths = pathsFor(allocator, init.environ_map, name) catch |err| {
        cliRuntimePathExit(command, err);
    };
    validateExistingRuntimeDirs(init.io, paths) catch |err| {
        cliRuntimePathExit(command, err);
    };
    return paths;
}

fn apiPaths(context: Context, allocator: std.mem.Allocator, name: []const u8) !Paths {
    const paths = try pathsFor(allocator, context.environ_map, name);
    try validateExistingRuntimeDirs(context.io, paths);
    return paths;
}

fn resolveNewOutputDirApi(allocator: std.mem.Allocator, io: Io, raw: []const u8) ![]const u8 {
    const path = try std.fs.path.resolve(allocator, &.{raw});
    if (try pathExists(io, path)) return error.OutputDirExists;
    const parent = std.fs.path.dirname(path) orelse return error.InvalidOutputDir;
    const stat = try Io.Dir.cwd().statFile(io, parent, .{ .follow_symlinks = true });
    if (stat.kind != Io.File.Kind.directory) return error.InvalidOutputDir;
    return path;
}

fn resolveExistingSporeDirApi(allocator: std.mem.Allocator, io: Io, raw: []const u8) ![]const u8 {
    const path = try std.fs.path.resolve(allocator, &.{raw});
    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != Io.File.Kind.directory) return error.InvalidSporeDir;
    return path;
}

fn resolveNewOutputDir(
    allocator: std.mem.Allocator,
    io: Io,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    raw: []const u8,
) []const u8 {
    const path = std.fs.path.resolve(allocator, &.{raw}) catch |err| {
        const message = allocLifecycleMessage(allocator, "spore {s}: invalid output directory: {s}", .{ command, @errorName(err) });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
    };
    if (pathExists(io, path) catch |err| {
        const message = allocLifecycleMessage(allocator, "spore {s}: output directory check failed: {s}", .{ command, @errorName(err) });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, command), message);
    }) {
        const message = allocLifecycleMessage(allocator, "spore {s}: output directory already exists: {s}", .{ command, path });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
    }
    const parent = std.fs.path.dirname(path) orelse {
        const message = allocLifecycleMessage(allocator, "spore {s}: output directory has no parent: {s}", .{ command, path });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
    };
    const stat = Io.Dir.cwd().statFile(io, parent, .{ .follow_symlinks = true }) catch |err| {
        const message = allocLifecycleMessage(allocator, "spore {s}: output parent is not available: {s}", .{ command, @errorName(err) });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_not_found, message, command), message);
    };
    if (stat.kind != Io.File.Kind.directory) {
        const message = allocLifecycleMessage(allocator, "spore {s}: output parent is not a directory: {s}", .{ command, parent });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, command), message);
    }
    return path;
}

fn pathExists(io: Io, path: []const u8) !bool {
    _ = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

fn writeSporeLifecycleSpec(allocator: std.mem.Allocator, io: Io, dir: []const u8, spec: Spec) !void {
    const path = try std.fs.path.resolve(allocator, &.{ dir, lifecycle_spore_metadata_file });
    var metadata = spec;
    metadata.resume_dir = null;
    const json = try std.json.Stringify.valueAlloc(allocator, metadata, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
}

fn readSporeLifecycleSpec(allocator: std.mem.Allocator, io: Io, dir: []const u8) !?std.json.Parsed(Spec) {
    const path = try std.fs.path.resolve(allocator, &.{ dir, lifecycle_spore_metadata_file });
    const data = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_metadata_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer allocator.free(data);
    const parsed = try std.json.parseFromSlice(Spec, allocator, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    return parsed;
}

fn memoryFromManifest(manifest: spore.Manifest) !memory_config.Config {
    return memory_config.fromManifestBytes(manifest.platform.ram_size);
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

fn hiddenForkBatchDir(allocator: std.mem.Allocator, runtime_root: []const u8, source_name: []const u8) ![]const u8 {
    const pid: i64 = if (comptime builtin.os.tag == .windows) 1 else @intCast(std.c.getpid());
    const leaf = try std.fmt.allocPrint(allocator, "{s}-{d}-{d}", .{ source_name, pid, monotonicMs() });
    return std.fs.path.resolve(allocator, &.{ runtime_root, "forks", leaf });
}

fn childSporeDir(allocator: std.mem.Allocator, children_dir: []const u8, index: usize) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{d:0>6}", .{ children_dir, index });
}

fn startForkChildExecutable(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    child_name: []const u8,
    spore_dir: []const u8,
    base: Spec,
    spore_executable: []const u8,
) !void {
    var manifest = try spore.loadManifest(allocator, spore_dir);
    defer manifest.deinit();
    if (manifest.value.network != null) return error.UnsupportedNamedForkNetwork;
    if (manifest.value.devices.len != diskless_resume_device_count) return error.UnsupportedNamedForkDisk;
    const memory = try memoryFromManifest(manifest.value);
    const spec = Spec{
        .name = child_name,
        .backend = base.backend,
        .kernel_path = base.kernel_path,
        .initrd_path = base.initrd_path,
        .resume_dir = spore_dir,
        .annotations = manifest.value.annotations,
        .memory = memory,
        .vcpus = 1,
        .guest_port = base.guest_port,
        .timeout_ms = base.timeout_ms,
        .console_log_path = null,
    };
    const paths = try apiPaths(.{ .io = init.io, .environ_map = init.environ_map }, allocator, child_name);
    try spawnMonitorExecutable(init, allocator, spec, spore_executable, null);
    try waitForReadyResult(allocator, init.io, paths, spec.timeout_ms);
}

fn cleanupStartedChildren(init: std.process.Init, allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |name| {
        const paths = pathsFor(allocator, init.environ_map, name) catch continue;
        var ready = readReady(allocator, init.io, paths) catch {
            Io.Dir.cwd().deleteTree(init.io, paths.vm_dir) catch {};
            continue;
        };
        _ = sendShutdownRequest(allocator, init.io, ready.value.control_socket_path) catch {};
        waitForPidExit(ready.value.pid, 5_000);
        ready.deinit();
        Io.Dir.cwd().deleteTree(init.io, paths.vm_dir) catch {};
    }
}

fn writeNamedForkResult(writer: *Io.Writer, result: NamedForkResult) !void {
    try writer.writeAll("Named fork complete\n");
    try writer.print("  Source: {s}\n", .{result.source});
    try writer.print("  Children: {d}\n", .{result.count});
    for (result.children) |name| {
        try writer.print("  - {s}\n", .{name});
    }
}

fn spawnMonitorExecutable(init: std.process.Init, allocator: std.mem.Allocator, spec: Spec, exe: []const u8, network_policy: ?*const run_mod.NetworkPolicy) !void {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.append(exe);
    try argv.append("monitor");
    try argv.append(spec.name);
    try argv.append("--backend");
    try argv.append(spec.backend);
    if (spec.kernel_path) |path| {
        try argv.append("--kernel");
        try argv.append(path);
    }
    if (spec.initrd_path) |path| {
        try argv.append("--initrd");
        try argv.append(path);
    }
    if (spec.rootfs_path) |path| {
        try argv.append("--rootfs");
        try argv.append(path);
    }
    if (spec.image_ref) |image| {
        try argv.append("--image");
        try argv.append(image);
    }
    if (spec.resume_dir) |path| {
        try argv.append("--resume");
        try argv.append(path);
    }
    if (network_policy) |policy| {
        if (spec.network != null) try appendMonitorNetworkPolicyArgs(allocator, &argv, policy);
    } else if (spec.network) |network| {
        try appendMonitorNetworkManifestArgs(allocator, &argv, network);
    }
    try appendMemoryArg(allocator, &argv, spec.memory);
    try appendIntArg(allocator, &argv, "--vcpus", spec.vcpus);
    try appendIntArg(allocator, &argv, "--guest-port", spec.guest_port);
    try appendIntArg(allocator, &argv, "--timeout-ms", spec.timeout_ms);
    if (spec.console_log_path) |path| {
        try argv.append("--console-log");
        try argv.append(path);
    }
    _ = try std.process.spawn(init.io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = if (builtin.os.tag == .windows) null else 0,
    });
}

fn appendMonitorNetworkPolicyArgs(allocator: std.mem.Allocator, argv: *std.array_list.Managed([]const u8), policy: *const run_mod.NetworkPolicy) !void {
    try argv.append("--net");
    for (policy.allowCidrSlice()) |cidr| {
        try argv.append("--allow-cidr");
        try argv.append(cidr);
    }
    for (policy.allowHostSlice()) |host| {
        try argv.append("--allow-host");
        try argv.append(host);
    }
    for (policy.exactRuleSlice()) |rule| {
        for (rule.portSlice()) |port| {
            try argv.append("--allow-host-port");
            try argv.append(try std.fmt.allocPrint(allocator, "{s}:{d}", .{ rule.host, port }));
        }
    }
    for (policy.boundServiceSlice()) |service| {
        try argv.append("--bound-unix-service");
        try argv.append(service.name);
        try argv.append(service.guest_host);
        try argv.append(try std.fmt.allocPrint(allocator, "{d}", .{service.guest_port}));
        try argv.append(service.unix_path);
    }
}

fn appendMonitorNetworkManifestArgs(allocator: std.mem.Allocator, argv: *std.array_list.Managed([]const u8), network: spore.Network) !void {
    if (network.bound_services.len != 0) return error.UnsupportedBoundServiceRestore;
    try argv.append("--net");
    for (network.allow_cidrs) |cidr| {
        try argv.append("--allow-cidr");
        try argv.append(cidr);
    }
    for (network.allow_hosts) |host| {
        try argv.append("--allow-host");
        try argv.append(host);
    }
    for (network.allow_host_ports) |rule| {
        for (rule.ports) |port| {
            try argv.append("--allow-host-port");
            try argv.append(try std.fmt.allocPrint(allocator, "{s}:{d}", .{ rule.host, port }));
        }
    }
}

fn appendIntArg(allocator: std.mem.Allocator, argv: *std.array_list.Managed([]const u8), flag: []const u8, value: anytype) !void {
    try argv.append(flag);
    try argv.append(try std.fmt.allocPrint(allocator, "{d}", .{value}));
}

fn appendMemoryArg(allocator: std.mem.Allocator, argv: *std.array_list.Managed([]const u8), memory: memory_config.Config) !void {
    try argv.append("--memory");
    try argv.append(try memory.cliValueAlloc(allocator));
}

fn waitForReady(command: []const u8, allocator: std.mem.Allocator, io: Io, paths: Paths, timeout_ms: u64) !void {
    waitForReadyResult(allocator, io, paths, timeout_ms) catch |err| switch (err) {
        error.MonitorReadyTimeout => {
            std.debug.print("spore {s}: timed out waiting for monitor readiness\n", .{command});
            std.process.exit(1);
        },
        else => |e| return e,
    };
}

fn waitForReadyResult(allocator: std.mem.Allocator, io: Io, paths: Paths, timeout_ms: u64) !void {
    const start = monotonicMs();
    while (monotonicMs() - start < timeout_ms) {
        var ready = readReady(allocator, io, paths) catch {
            sleepMs(20);
            continue;
        };
        if (!pidAlive(ready.value.pid)) {
            ready.deinit();
            sleepMs(20);
            continue;
        }
        ready.deinit();
        return;
    }
    return error.MonitorReadyTimeout;
}

fn sendExecRequest(allocator: std.mem.Allocator, io: Io, socket_path: []const u8, argv: []const []const u8) ![]const u8 {
    const payload = struct {
        type: []const u8 = "exec",
        argv: []const []const u8,
    }{ .argv = argv };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    return sendControlJson(allocator, io, socket_path, json);
}

fn sendShutdownRequest(allocator: std.mem.Allocator, io: Io, socket_path: []const u8) ![]const u8 {
    return sendControlJson(allocator, io, socket_path, "{\"type\":\"shutdown\"}");
}

fn sendSuspendRequest(allocator: std.mem.Allocator, io: Io, socket_path: []const u8, out_dir: []const u8) ![]const u8 {
    const payload = struct {
        type: []const u8 = "suspend",
        out_dir: []const u8,
    }{ .out_dir = out_dir };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    return sendControlJson(allocator, io, socket_path, json);
}

fn sendSnapshotRequest(allocator: std.mem.Allocator, io: Io, socket_path: []const u8, out_dir: []const u8) ![]const u8 {
    const payload = struct {
        type: []const u8 = "snapshot",
        out_dir: []const u8,
        @"continue": bool = true,
    }{ .out_dir = out_dir };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    return sendControlJson(allocator, io, socket_path, json);
}

fn sendControlJson(allocator: std.mem.Allocator, io: Io, socket_path: []const u8, json: []const u8) ![]const u8 {
    const address = try net.UnixAddress.init(socket_path);
    const stream = address.connect(io) catch return error.MonitorUnavailable;
    defer stream.close(io);
    writeAll(io, stream, json) catch return error.MonitorUnavailable;
    writeAll(io, stream, "\n") catch return error.MonitorUnavailable;

    var read_buffer: [max_control_response]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const line = reader.interface.takeDelimiterExclusive('\n') catch return error.MonitorUnavailable;
    return allocator.dupe(u8, line);
}

const ControlResponse = struct {
    type: []const u8,
    exit_code: ?i32 = null,
    stdout_b64: ?[]const u8 = null,
    stderr_b64: ?[]const u8 = null,
    network_events_jsonl_b64: ?[]const u8 = null,
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
    out_dir: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

fn writeExecNamedResult(stdout: *Io.Writer, result: ExecNamedResult) !void {
    try stdout.writeAll(result.stdout);
    try stdout.flush();
    try writeRawStderr(result.stderr);
    if (result.stdout_truncated) try writeRawStderr("spore exec: stdout truncated after 16384 bytes\n");
    if (result.stderr_truncated) try writeRawStderr("spore exec: stderr truncated after 16384 bytes\n");
}

fn parseExecNamedResponse(
    allocator: std.mem.Allocator,
    parse_allocator: std.mem.Allocator,
    response: []const u8,
) !ExecNamedResult {
    var parsed = try std.json.parseFromSlice(ControlResponse, parse_allocator, response, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.type, "exec_result")) return error.MonitorRequestFailed;
    const exit_code = parsed.value.exit_code orelse return error.BadMonitorResponse;
    if (exit_code < 0 or exit_code > 255) return error.BadMonitorResponse;

    const stdout = try decodeControlOutput(allocator, parsed.value.stdout_b64 orelse return error.BadMonitorResponse);
    errdefer allocator.free(stdout);
    const stderr = try decodeControlOutput(allocator, parsed.value.stderr_b64 orelse return error.BadMonitorResponse);
    errdefer allocator.free(stderr);
    const network_events_jsonl = if (parsed.value.network_events_jsonl_b64) |encoded|
        try decodeControlOutput(allocator, encoded)
    else
        try allocator.dupe(u8, "");
    errdefer allocator.free(network_events_jsonl);
    return .{
        .exit_code = @intCast(exit_code),
        .stdout = stdout,
        .stderr = stderr,
        .network_events_jsonl = network_events_jsonl,
        .stdout_truncated = parsed.value.stdout_truncated,
        .stderr_truncated = parsed.value.stderr_truncated,
    };
}

fn suspendResponseFailureMessage(allocator: std.mem.Allocator, response: []const u8) !?[]const u8 {
    var parsed = try std.json.parseFromSlice(ControlResponse, allocator, response, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (std.mem.eql(u8, parsed.value.type, "suspended")) return null;
    const message = parsed.value.message orelse "monitor request failed";
    return try allocator.dupe(u8, message);
}

fn snapshotResponseOk(allocator: std.mem.Allocator, response: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(ControlResponse, allocator, response, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    return std.mem.eql(u8, parsed.value.type, "snapshotted");
}

fn ownedNamedLifecycleResult(allocator: std.mem.Allocator, result: NamedLifecycleResult) !NamedLifecycleResult {
    const name = try allocator.dupe(u8, result.name);
    errdefer allocator.free(name);
    const console_log_path = if (result.console_log_path) |path| try allocator.dupe(u8, path) else null;
    errdefer if (console_log_path) |path| allocator.free(path);
    const spore_dir = if (result.spore_dir) |path| try allocator.dupe(u8, path) else null;
    return .{
        .action = result.action,
        .name = name,
        .state = result.state,
        .pid = result.pid,
        .console_log_path = console_log_path,
        .spore_dir = spore_dir,
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
    if (decoded_size > max_control_response) return error.BadMonitorResponse;
    const decoded = try allocator.alloc(u8, decoded_size);
    errdefer allocator.free(decoded);
    dec.decode(decoded, encoded) catch return error.BadMonitorResponse;
    return decoded;
}

fn writeRawStderr(bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(2, remaining.ptr, remaining.len);
        if (n <= 0) return error.StderrWriteFailed;
        remaining = remaining[@intCast(n)..];
    }
}

fn waitForPidExit(pid: i64, timeout_ms: u64) void {
    const start = monotonicMs();
    while (monotonicMs() - start < timeout_ms) {
        if (!pidAlive(pid)) return;
        sleepMs(20);
    }
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

fn wantsHelp(args: []const []const u8) bool {
    return args.len == 1 and
        (std.mem.eql(u8, args[0], "help") or
            std.mem.eql(u8, args[0], "-h") or
            std.mem.eql(u8, args[0], "--help"));
}

fn usageExit(comptime text: []const u8) noreturn {
    std.debug.print("{s}", .{text});
    std.process.exit(2);
}

fn allocLifecycleMessage(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(allocator, fmt, args) catch "CLI argument error";
}

fn exitLifecycleCliError(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    err: machine_output.CliError,
    human_text: []const u8,
) noreturn {
    if (mode == .json) {
        machine_output.writeError(allocator, stderr, err) catch {};
    } else {
        stderr.writeAll(human_text) catch {};
        if (!std.mem.endsWith(u8, human_text, "\n")) stderr.writeByte('\n') catch {};
    }
    stderr.flush() catch {};
    std.process.exit(err.exit_code);
}

fn exitLifecycleRuntimePathError(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    err: anyerror,
) noreturn {
    const message = switch (err) {
        error.InvalidRuntimeDir => allocLifecycleMessage(allocator, "spore {s}: invalid runtime directory; set {s} or XDG_RUNTIME_DIR to an absolute path", .{ command, runtime_dir_env }),
        error.InsecureRuntimeDir => allocLifecycleMessage(allocator, "spore {s}: insecure runtime directory; registry directories must be private to the current user", .{command}),
        else => allocLifecycleMessage(allocator, "spore {s}: runtime directory error: {s}", .{ command, @errorName(err) }),
    };
    exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
}

fn validateNameOrExit(command: []const u8, name: []const u8) !void {
    validateName(name) catch {
        std.debug.print("spore {s}: invalid VM name: {s}\n", .{ command, name });
        std.process.exit(2);
    };
}

fn validateNameLifecycleCli(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    name: []const u8,
) void {
    validateName(name) catch {
        const message = allocLifecycleMessage(allocator, "spore {s}: invalid VM name: {s}", .{ command, name });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
    };
}

fn cliRuntimePathExit(command: []const u8, err: anyerror) noreturn {
    switch (err) {
        error.InvalidRuntimeDir => std.debug.print(
            "spore {s}: invalid runtime directory; set {s} or XDG_RUNTIME_DIR to an absolute path\n",
            .{ command, runtime_dir_env },
        ),
        error.InsecureRuntimeDir => std.debug.print(
            "spore {s}: insecure runtime directory; registry directories must be private to the current user\n",
            .{command},
        ),
        else => std.debug.print("spore {s}: runtime directory error: {s}\n", .{ command, @errorName(err) }),
    }
    std.process.exit(2);
}

fn takeValue(args: []const []const u8, i: *usize, flag: []const u8) []const u8 {
    if (i.* + 1 >= args.len) {
        std.debug.print("{s} requires a value\n", .{flag});
        std.process.exit(2);
    }
    i.* += 1;
    return args[i.*];
}

fn takeValueLifecycleCli(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    args: []const []const u8,
    i: *usize,
    flag: []const u8,
) []const u8 {
    if (i.* + 1 >= args.len) {
        const message = allocLifecycleMessage(allocator, "{s} requires a value", .{flag});
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageMissingArgument(message, command), message);
    }
    i.* += 1;
    return args[i.*];
}

fn parseIntArg(comptime T: type, raw: []const u8, flag: []const u8) T {
    return std.fmt.parseInt(T, raw, 10) catch {
        std.debug.print("{s} must be an integer\n", .{flag});
        std.process.exit(2);
    };
}

fn parseIntArgLifecycleCli(
    comptime T: type,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    raw: []const u8,
    flag: []const u8,
) T {
    return std.fmt.parseInt(T, raw, 10) catch {
        const message = allocLifecycleMessage(allocator, "{s} must be an integer", .{flag});
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
    };
}

pub fn monitorBackendSupported(raw: []const u8) bool {
    const hvf_supported = comptime builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;
    const kvm_supported = comptime builtin.os.tag == .linux and builtin.cpu.arch == .aarch64;
    return switch (run_mod.Backend.parse(raw) orelse return false) {
        .auto => hvf_supported or kvm_supported,
        .hvf => hvf_supported,
        .kvm => kvm_supported,
    };
}

pub fn wantsNamedFork(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--vm") or std.mem.eql(u8, arg, "--name")) return true;
    }
    return false;
}

fn openDirPath(io: Io, path: []const u8, flags: Io.Dir.OpenOptions) !Io.Dir {
    if (Io.Dir.path.isAbsolute(path)) return Io.Dir.openDirAbsolute(io, path, flags);
    return Io.Dir.cwd().openDir(io, path, flags);
}

fn ensureVmDir(io: Io, paths: Paths) !void {
    try ensureDirPath(io, paths.runtime_root);
    try requirePrivateDir(io, paths.runtime_root);
    try ensureDirPath(io, paths.vms_dir);
    try requirePrivateDir(io, paths.vms_dir);
    try ensureDirPath(io, paths.vm_dir);
    try requirePrivateDir(io, paths.vm_dir);
}

fn ensureDirPath(io: Io, path: []const u8) !void {
    if (!Io.Dir.path.isAbsolute(path)) {
        _ = try Io.Dir.cwd().createDirPathStatus(io, path, private_dir_permissions);
        return;
    }
    var existing = Io.Dir.openDirAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (std.fs.path.dirname(path)) |parent| {
                if (parent.len > 0 and !std.mem.eql(u8, parent, path)) try ensureDirPath(io, parent);
            }
            Io.Dir.createDirAbsolute(io, path, private_dir_permissions) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => {},
                else => |e| return e,
            };
            return;
        },
        else => |e| return e,
    };
    existing.close(io);
}

fn requirePrivateDir(io: Io, path: []const u8) !void {
    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != Io.File.Kind.directory) return error.InvalidRuntimeDir;
    if (comptime builtin.os.tag != .windows) {
        const mode = @intFromEnum(stat.permissions);
        if (mode & 0o077 != 0) return error.InsecureRuntimeDir;
    }
}

fn validateExistingRuntimeDirs(io: Io, paths: Paths) !void {
    try validateExistingPrivateDir(io, paths.runtime_root);
    try validateExistingPrivateDir(io, paths.vms_dir);
    try validateExistingPrivateDir(io, paths.vm_dir);
}

fn validateExistingPrivateDir(io: Io, path: []const u8) !void {
    requirePrivateDir(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
}

pub fn pidAlive(pid: i64) bool {
    if (pid <= 0) return false;
    if (comptime builtin.os.tag == .windows) return false;
    std.posix.kill(@intCast(pid), @enumFromInt(0)) catch |err| return err == error.PermissionDenied;
    return true;
}

fn lessListEntry(_: void, a: ListEntry, b: ListEntry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

test "lifecycle validates VM names" {
    try validateName("bench-1");
    try validateName("a.b_c9");
    try std.testing.expectError(error.InvalidVMName, validateName(""));
    try std.testing.expectError(error.InvalidVMName, validateName("-flag"));
    try std.testing.expectError(error.InvalidVMName, validateName("."));
    try std.testing.expectError(error.InvalidVMName, validateName("bad/name"));
    try std.testing.expectError(error.InvalidVMName, validateName("bad name"));
}

test "lifecycle result carries stable schema" {
    const result = LifecycleResult{
        .action = "created",
        .name = "bench-1",
        .state = "ready",
        .pid = 42,
    };
    try std.testing.expectEqualStrings(lifecycle_schema, result.schema);
    try std.testing.expectEqual(lifecycle_schema_version, result.schema_version);
    try std.testing.expectEqualStrings("created", result.action);
    try std.testing.expectEqualStrings("bench-1", result.name);
    try std.testing.expectEqualStrings("ready", result.state);
    try std.testing.expectEqual(@as(?i64, 42), result.pid);
}

test "named exec response decodes owned output" {
    const allocator = std.testing.allocator;
    const response =
        \\{"type":"exec_result","exit_code":7,"stdout_b64":"b2s=","stderr_b64":"ZXJy","network_events_jsonl_b64":"eyJldmVudCI6Im5ldHdvcmtfZGVjaXNpb24ifQo=","stdout_truncated":false,"stderr_truncated":true}
    ;
    const result = try parseExecNamedResponse(allocator, allocator, response);
    defer deinitExecNamedResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 7), result.exit_code);
    try std.testing.expectEqualStrings("ok", result.stdout);
    try std.testing.expectEqualStrings("err", result.stderr);
    try std.testing.expectEqualStrings("{\"event\":\"network_decision\"}\n", result.network_events_jsonl);
    try std.testing.expect(!result.stdout_truncated);
    try std.testing.expect(result.stderr_truncated);
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

test "lifecycle monitor backend support is explicit" {
    const hvf_supported = comptime builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;
    const kvm_supported = comptime builtin.os.tag == .linux and builtin.cpu.arch == .aarch64;
    try std.testing.expectEqual(hvf_supported or kvm_supported, monitorBackendSupported("auto"));
    try std.testing.expectEqual(hvf_supported, monitorBackendSupported("hvf"));
    try std.testing.expectEqual(kvm_supported, monitorBackendSupported("kvm"));
    try std.testing.expect(!monitorBackendSupported("bogus"));
}

test "lifecycle runtime root prefers explicit and xdg absolute paths" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    try env.put(runtime_dir_env, "/tmp/sporevm-runtime");
    const explicit = try runtimeRootPath(allocator, &env);
    defer allocator.free(explicit);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime", explicit);

    _ = env.swapRemove(runtime_dir_env);
    try env.put("XDG_RUNTIME_DIR", "/tmp/xdg-runtime");
    const xdg = try runtimeRootPath(allocator, &env);
    defer allocator.free(xdg);
    try std.testing.expectEqualStrings("/tmp/xdg-runtime/sporevm", xdg);
}

test "lifecycle runtime root rejects relative environment paths" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    try env.put(runtime_dir_env, "relative");
    try std.testing.expectError(error.InvalidRuntimeDir, runtimeRootPath(allocator, &env));

    _ = env.swapRemove(runtime_dir_env);
    try env.put("XDG_RUNTIME_DIR", "");
    try std.testing.expectError(error.InvalidRuntimeDir, runtimeRootPath(allocator, &env));
}

test "snapshot validates annotations before touching runtime state" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(runtime_dir_env, "/tmp/sporevm-runtime");

    var annotations = spore.Annotations{};
    defer annotations.deinit(allocator);
    try annotations.map.put(allocator, "", "bad");

    try std.testing.expectError(error.BadManifest, snapshotNamed(.{
        .io = std.testing.io,
        .environ_map = &env,
    }, allocator, .{
        .name = "bench-1",
        .out_dir = "zig-cache/missing-parent/snapshot.spore",
        .annotations = annotations,
    }));
}

test "lifecycle paths are rooted under vms by name" {
    const allocator = std.testing.allocator;
    const paths = try pathsFromRoot(allocator, "/tmp/sporevm-runtime", "bench-1");
    defer paths.deinit(allocator);

    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms", paths.vms_dir);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1", paths.vm_dir);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1/spec.json", paths.spec_path);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1/ready.json", paths.ready_path);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1/create-timing.json", paths.create_timing_path);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1/monitor-timing.json", paths.monitor_timing_path);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1/pid", paths.pid_path);
}

test "lifecycle metadata helpers round trip spec ready and pid" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fs.path.resolve(allocator, &.{"zig-cache/test-lifecycle-metadata"});
    defer allocator.free(root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);

    try writeSpec(allocator, io, paths, .{
        .name = "bench-1",
        .backend = "hvf",
        .image_ref = "docker.io/library/alpine:3.20",
        .network = .{
            .allow_cidrs = &.{"93.184.216.34/32"},
            .allow_hosts = &.{"example.com"},
        },
        .memory = .{ .policy = .explicit, .bytes = 512 * 1024 * 1024 },
    });
    var spec = try readSpec(allocator, io, paths);
    defer spec.deinit();
    try std.testing.expectEqualStrings("bench-1", spec.value.name);
    try std.testing.expectEqualStrings("hvf", spec.value.backend);
    try std.testing.expectEqualStrings("docker.io/library/alpine:3.20", spec.value.image_ref.?);
    try std.testing.expectEqualStrings("93.184.216.34/32", spec.value.network.?.allow_cidrs[0]);
    try std.testing.expectEqualStrings("example.com", spec.value.network.?.allow_hosts[0]);
    try std.testing.expectEqual(memory_config.Policy.explicit, spec.value.memory.policy);
    try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), spec.value.memory.bytes);

    try writeReady(allocator, io, paths, .{
        .pid = 1234,
        .control_socket_path = paths.control_socket_path,
        .console_log_path = paths.console_log_path,
    });
    var ready = try readReady(allocator, io, paths);
    defer ready.deinit();
    try std.testing.expectEqual(@as(i64, 1234), ready.value.pid);
    try std.testing.expectEqualStrings(paths.control_socket_path, ready.value.control_socket_path);

    try writePid(allocator, io, paths, 1234);
    try std.testing.expectEqual(@as(i64, 1234), try readPid(allocator, io, paths));
}

test "create parser accepts memory policy" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    const default_opts = try parseCreateArgs(&.{"bench-1"}, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(memory_config.Policy.auto, default_opts.spec.memory.policy);
    try std.testing.expectEqual(memory_config.auto_bytes, default_opts.spec.memory.bytes);

    const explicit_opts = try parseCreateArgs(&.{ "bench-1", "--memory", "16gb" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(memory_config.Policy.explicit, explicit_opts.spec.memory.policy);
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024 * 1024), explicit_opts.spec.memory.bytes);
}

test "create parser accepts image pull policy" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    const default_opts = try parseCreateArgs(&.{ "bench-1", "--image", "docker.io/library/alpine:3.20" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(run_mod.PullPolicy.missing, default_opts.image_pull_policy);

    const equals_opts = try parseCreateArgs(&.{ "bench-1", "--pull=always", "--image", "docker.io/library/alpine:3.20" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(run_mod.PullPolicy.always, equals_opts.image_pull_policy);

    const value_opts = try parseCreateArgs(&.{ "bench-1", "--image", "docker.io/library/alpine:3.20", "--pull", "never" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(run_mod.PullPolicy.never, value_opts.image_pull_policy);
}

test "create parser accepts network allow policy" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    const opts = try parseCreateArgs(&.{
        "bench-1",
        "--net",
        "--allow-cidr",
        "93.184.216.34/32",
        "--allow-host",
        "example.com",
    }, allocator, &stderr.writer, .human);

    try std.testing.expectEqual(run_mod.NetworkMode.spore, opts.network);
    try std.testing.expectEqual(@as(usize, 1), opts.network_policy.allow_cidr_count);
    try std.testing.expectEqualStrings("93.184.216.34/32", opts.network_policy.allow_cidrs[0]);
    try std.testing.expectEqual(@as(usize, 1), opts.network_policy.allow_host_count);
    try std.testing.expectEqualStrings("example.com", opts.network_policy.allow_hosts[0]);
}

test "named network config accepts create cli policy" {
    const config = try namedNetworkConfig(.{
        .enabled = true,
        .allow_cidrs = &.{"93.184.216.34/32"},
        .allow_hosts = &.{"example.com"},
    });

    try std.testing.expectEqual(run_mod.NetworkMode.spore, config.mode);
    try std.testing.expectEqual(@as(usize, 1), config.policy.allow_cidr_count);
    try std.testing.expectEqualStrings("93.184.216.34/32", config.policy.allow_cidrs[0]);
    try std.testing.expectEqual(@as(usize, 1), config.policy.allow_host_count);
    try std.testing.expectEqualStrings("example.com", config.policy.allow_hosts[0]);
}

test "named network config keeps bare network unrestricted" {
    const config = try namedNetworkConfig(.{ .enabled = true });

    try std.testing.expectEqual(run_mod.NetworkMode.spore, config.mode);
    try std.testing.expect(!config.policy.default_deny);
    try std.testing.expect(!config.policy.hasRules());
}

test "lifecycle detects incomplete ready and stale pid state" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fs.path.resolve(allocator, &.{"zig-cache/test-lifecycle-state"});
    defer allocator.free(root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);

    try std.testing.expectEqual(VmState.absent, try classifyVmState(allocator, io, paths, alwaysDead));

    try writeSpec(allocator, io, paths, .{ .name = "bench-1" });
    try std.testing.expectEqual(VmState.incomplete, try classifyVmState(allocator, io, paths, alwaysDead));

    try writeReady(allocator, io, paths, .{
        .pid = 7777,
        .control_socket_path = paths.control_socket_path,
        .console_log_path = paths.console_log_path,
    });
    try writePid(allocator, io, paths, 7777);
    try std.testing.expectEqual(VmState.stale, try classifyVmState(allocator, io, paths, alwaysDead));
    try std.testing.expectEqual(VmState.ready, try classifyVmState(allocator, io, paths, alwaysAlive));

    try writePid(allocator, io, paths, 8888);
    try std.testing.expectEqual(VmState.stale, try classifyVmState(allocator, io, paths, alwaysAlive));

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = paths.spec_path, .data = "not json" });
    try std.testing.expectEqual(VmState.stale, try classifyVmState(allocator, io, paths, alwaysAlive));

    try writeSpec(allocator, io, paths, .{ .name = "wrong-name" });
    try std.testing.expectEqual(VmState.stale, try classifyVmState(allocator, io, paths, alwaysAlive));
}

test "lifecycle rejects insecure existing runtime directories" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fs.path.resolve(allocator, &.{"zig-cache/test-lifecycle-insecure"});
    defer allocator.free(root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = try Io.Dir.cwd().createDirPathStatus(io, root, @enumFromInt(0o755));
    try Io.Dir.cwd().setFilePermissions(io, root, @enumFromInt(0o755), .{});

    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);
    try std.testing.expectError(error.InsecureRuntimeDir, validateExistingRuntimeDirs(io, paths));
}

test "lifecycle list entries sorts and classifies VM directories" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fs.path.resolve(allocator, &.{"zig-cache/test-lifecycle-list"});
    defer allocator.free(root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};

    const empty = try listEntries(allocator, io, root, alwaysDead);
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
    try writeSpec(allocator, io, stale, .{
        .name = "b-stale",
        .resume_dir = stale_spore_dir,
        .memory = .{ .policy = .explicit, .bytes = 512 * 1024 * 1024 },
    });
    try writeReady(allocator, io, stale, .{
        .pid = 9001,
        .control_socket_path = stale.control_socket_path,
        .console_log_path = stale.console_log_path,
    });
    try writePid(allocator, io, stale, 9001);

    const ready = try pathsFromRoot(allocator, root, "a-ready");
    defer ready.deinit(allocator);
    try writeSpec(allocator, io, ready, .{ .name = "a-ready" });
    try writeReady(allocator, io, ready, .{
        .pid = 42,
        .control_socket_path = ready.control_socket_path,
        .console_log_path = ready.console_log_path,
    });
    try writePid(allocator, io, ready, 42);

    const entries = try listEntries(allocator, io, root, aliveOnly42);
    defer freeListEntries(allocator, entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("a-ready", entries[0].name);
    try std.testing.expectEqualStrings("ready", entries[0].state);
    try std.testing.expectEqual(@as(?i64, 42), entries[0].pid);
    try std.testing.expectEqualStrings("auto", entries[0].memory.?.policy);
    try std.testing.expectEqual(memory_config.auto_bytes, entries[0].memory.?.bytes);
    try std.testing.expectEqual(@as(?u64, null), entries[0].stats.resident_bytes);
    const chunk_size: u64 = spore.chunk_size;
    try std.testing.expectEqual(@as(?u64, chunk_size), entries[0].stats.chunk_size);
    try std.testing.expectEqual(@as(?u64, memory_config.auto_bytes / chunk_size), entries[0].stats.chunks_total);
    try std.testing.expectEqualStrings("b-stale", entries[1].name);
    try std.testing.expectEqualStrings("stale", entries[1].state);
    try std.testing.expectEqual(@as(?i64, 9001), entries[1].pid);
    try std.testing.expectEqualStrings("explicit", entries[1].memory.?.policy);
    try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), entries[1].memory.?.bytes);
    try std.testing.expectEqual(@as(?u64, 13), entries[1].stats.backing_logical_bytes);
    try std.testing.expect(entries[1].stats.backing_allocated_bytes != null);
    try std.testing.expectEqual(@as(?u64, 256), entries[1].stats.chunks_total);
}

test "lifecycle list entries render human table" {
    const allocator = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const stale_memory = listMemoryFromConfig(.{ .policy = .explicit, .bytes = 512 * 1024 * 1024 });
    try writeListEntries(&out.writer, &.{
        .{
            .name = "a-ready",
            .state = "ready",
            .pid = 42,
            .memory = listMemoryFromConfig(.{}),
            .stats = .{
                .resident_bytes = 184 * 1024 * 1024,
                .backing_logical_bytes = memory_config.auto_bytes,
                .backing_allocated_bytes = 34 * 1024 * 1024,
                .chunks_total = 8192,
                .chunks_nonzero = 17,
                .dirty_chunks_pending = 2,
            },
        },
        .{
            .name = "b-stale",
            .state = "stale",
            .pid = null,
            .memory = stale_memory,
            .stats = listStatsFromMemory(stale_memory),
        },
    });
    try std.testing.expectEqualStrings(
        "NAME\tSTATE\tPID\tMEMORY\tRESIDENT\tBACKING\tCHUNKS\tDIRTY\n" ++
            "a-ready\tready\t42\tauto/16GiB\t184MiB\t34MiB/16GiB\t17/8192\t2\n" ++
            "b-stale\tstale\t-\t512MiB\t?\t?\t?/256\t?\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    try writeListEntries(&out.writer, &.{});
    try std.testing.expectEqualStrings("No VMs\n", out.written());
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

    try std.testing.expect(std.mem.indexOf(u8, json, "\"memory\":{\"policy\":\"auto\",\"bytes\":17179869184}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stats\":{\"resident_bytes\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dirty_chunks_pending\":null") != null);
}

fn alwaysDead(_: i64) bool {
    return false;
}

fn alwaysAlive(_: i64) bool {
    return true;
}

fn aliveOnly42(pid: i64) bool {
    return pid == 42;
}
