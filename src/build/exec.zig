const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const rootfs_cas = @import("../rootfs_cas.zig");
const disk_layer = @import("../disk_layer.zig");
const rootfs_mod = @import("../rootfs.zig");
const run_mod = @import("../run.zig");
const memory_config = @import("../memory.zig");
const topology = @import("../topology.zig");
const runtime_disk = @import("../runtime_disk.zig");
const cache_mount = @import("cache_mount.zig");
const board = @import("../board.zig");
const spore = @import("../spore.zig");
const run_contract = @import("run_contract.zig");
const step_cache = @import("step_cache.zig");
const vsock = @import("../virtio/vsock.zig");

const guest_port: u32 = 10700;
pub const default_step_timeout_ms: u64 = 30 * 60 * 1000;
const max_captured_output = 64 * 1024;
const max_rootfs_grow_response = run_mod.max_rootfs_grow_response;
const p0_idle_probe_env = "SPOREVM_ROOTFS_GROWTH_P0_IDLE_MS";
const max_p0_idle_probe_ms: u64 = 10_000;
const build_producer_domain = "sporevm-build-producer-v2";
const prepare_host_contract = "grow-v1-strict-request-v2;ext4-source-preflight-v2;ext4-superblock-postcondition-v1;ext4-ioctl-v1;noinit-itable-v1;virtio-write-zeroes-1x4m-v1;chunk-zero-map-v1";
// Provisional build-VM default; make this a `spore build` option when larger
// workloads such as `bundle install`-style RUN steps need more memory.
const build_vm_memory_bytes: u64 = 2 * 1024 * 1024 * 1024;
pub const default_build_memory = memory_config.Config{ .policy = .explicit, .bytes = build_vm_memory_bytes };
pub const default_build_vcpus: topology.VcpuCount = 1;
pub const max_build_nofile: u64 = 1_048_576;
pub const default_build_nofile = NofileLimit{ .soft = 65_536, .hard = 65_536 };
const max_guest_request_len = 8191;
pub const max_run_command_len = run_contract.max_shell_command_bytes;
pub const max_run_exec_args = run_contract.max_exec_args;
pub const max_run_exec_args_bytes = run_contract.max_exec_args_bytes;
pub const max_guest_envc = 64;
pub const max_guest_env_len = 255;
pub const max_guest_working_dir_len = 255;
pub const max_copy_entries = 65536;
pub const max_copy_entry_path_len = 512;
pub const max_build_input_disks = 2;
const enospc_patterns = [_][]const u8{
    "SPORE_BUILD_ENOSPC",
    "No space left on device",
    "ENOSPC",
};
const max_enospc_pattern_len = "No space left on device".len;

pub const NofileLimit = struct {
    soft: u64,
    hard: u64,

    pub fn validate(self: NofileLimit) !void {
        if (self.soft == 0 or self.soft > self.hard or self.hard > max_build_nofile) return error.InvalidBuildNofileLimit;
    }
};

pub const RunResources = struct {
    memory: memory_config.Config = default_build_memory,
    vcpus: topology.VcpuCount = default_build_vcpus,
    nofile: NofileLimit = default_build_nofile,

    pub fn validate(self: RunResources) !void {
        _ = try memory_config.fromManifestBytes(self.memory.bytes);
        try topology.validateVcpuCount(self.vcpus);
        try self.nofile.validate();
    }
};

pub const Diagnostic = struct {
    instruction: ?[]const u8 = null,
    instruction_line: usize = 0,
    exit_code: ?i32 = null,
    output: []const u8 = "",
    enospc: bool = false,
    boot_count: usize = 0,
    executed_steps: usize = 0,
    resize_count: usize = 0,
    boot_artifact_file_reads: usize = 0,
    boot_artifact_bytes_read: usize = 0,
    session_ms: u64 = 0,
    instruction_ms: u64 = 0,
    checkpoint_control_ms: u64 = 0,
    snapshot_ms: u64 = 0,
    max_checkpoint_control_ms: u64 = 0,
    snapshot_metrics: disk_layer.SnapshotMetrics = std.mem.zeroes(disk_layer.SnapshotMetrics),
};

pub const Producer = struct {
    identity: []const u8,
    boot_source: union(enum) {
        retained: run_mod.MonitorBootArtifacts,
        managed: run_mod.ManagedMonitorBootDescriptor,
    },
    eager_artifact_file_reads: usize = 0,
    eager_artifact_bytes_read: usize = 0,
};

pub fn resolveProducer(init: std.process.Init, allocator: std.mem.Allocator) !Producer {
    const noinit_itable = run_mod.rootfsGrowthNoInitItable(init.environ_map);
    if (init.environ_map.get("SPOREVM_KERNEL_IMAGE") == null and
        init.environ_map.get("SPOREVM_RUN_INITRD") == null)
    {
        const managed = try run_mod.resolveManagedMonitorBootDescriptor(init, allocator);
        return managedProducer(allocator, managed, noinit_itable);
    }

    const kernel_path = try run_mod.resolveDefaultKernelPath(init, allocator);
    const initrd_path = try run_mod.resolveConfiguredInitrdPath(init, null);
    const boot = try run_mod.loadMonitorBootArtifacts(init.io, allocator, kernel_path, initrd_path);
    const kernel_sha256 = sha256Bytes(boot.kernel);
    const initrd_sha256 = sha256Bytes(boot.initrd);
    return .{
        .identity = try producerIdentity(allocator, kernel_sha256, initrd_sha256, noinit_itable),
        .boot_source = .{ .retained = boot },
        .eager_artifact_file_reads = 1 + @as(usize, @intFromBool(initrd_path != null)),
        .eager_artifact_bytes_read = boot.kernel.len + if (initrd_path != null) boot.initrd.len else 0,
    };
}

fn managedProducer(
    allocator: std.mem.Allocator,
    managed: run_mod.ManagedMonitorBootDescriptor,
    noinit_itable: bool,
) !Producer {
    return .{
        .identity = try producerIdentity(allocator, managed.kernel_sha256, managed.initrd_sha256, noinit_itable),
        .boot_source = .{ .managed = managed },
    };
}

fn producerIdentity(
    allocator: std.mem.Allocator,
    kernel_sha256: [Sha256.digest_length]u8,
    initrd_sha256: [Sha256.digest_length]u8,
    noinit_itable: bool,
) ![]const u8 {
    var h = std.crypto.hash.Blake3.init(.{});
    hashProducerField(&h, build_producer_domain);
    hashProducerField(&h, "sha256");
    hashProducerField(&h, &kernel_sha256);
    hashProducerField(&h, "sha256");
    hashProducerField(&h, &initrd_sha256);
    hashProducerField(&h, "spore-rootfs-grow-v1");
    hashProducerField(&h, prepare_host_contract);
    hashProducerField(&h, if (noinit_itable) "noinit_itable=1" else "noinit_itable=0");
    var digest: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "blake3:{s}", .{&hex});
}

fn sha256Bytes(bytes: []const u8) [Sha256.digest_length]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn hashProducerField(h: *std.crypto.hash.Blake3, bytes: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, bytes.len, .little);
    h.update(&len);
    h.update(bytes);
}

pub const RunCommand = union(enum) {
    shell: []const u8,
    exec: []const []const u8,
};

pub const RunStep = struct {
    line: usize = 0,
    canonical_instruction: []const u8,
    command: RunCommand,
    env: []const []const u8,
    env_digest: []const u8,
    workdir: []const u8,
    network_mode: step_cache.NetworkMode,
    cache_mount_digest: []const u8 = "",
    cache_mounts: []const cache_mount.Mount = &.{},
};

pub const CopySourceKind = enum {
    auto,
    directory,
    file,
    sym_link,
};

pub const CopySourceDisk = enum {
    context,
    build_input,
};

pub const CopyDestinationPolicy = step_cache.CopyDestinationPolicy;

pub const CopyRequest = struct {
    source: []const u8,
    dest: []const u8,
    source_kind: CopySourceKind,
    dest_is_dir: bool,
    entry_count: usize,
    source_disk: CopySourceDisk = .context,
    input_index: usize = 0,
    mtime_unix_seconds: ?i64 = null,
    destination_policy: CopyDestinationPolicy = .follow,
};

pub const CopyStep = struct {
    instruction_kind: enum { copy, add } = .copy,
    line: usize = 0,
    canonical_instruction: []const u8,
    input_digest: []const u8,
    env_digest: []const u8,
    workdir: []const u8,
    destination_policy: CopyDestinationPolicy = .follow,
    requests: []const CopyRequest,
};

pub const WorkdirStep = struct {
    line: usize = 0,
    canonical_instruction: []const u8,
    target: []const u8,
    env_digest: []const u8,
    workdir: []const u8,
};

pub const Step = union(enum) {
    run: RunStep,
    copy: CopyStep,
    workdir: WorkdirStep,

    fn canonicalInstruction(self: Step) []const u8 {
        return switch (self) {
            .run => |step| step.canonical_instruction,
            .copy => |step| step.canonical_instruction,
            .workdir => |step| step.canonical_instruction,
        };
    }

    fn line(self: Step) usize {
        return switch (self) {
            .run => |step| step.line,
            .copy => |step| step.line,
            .workdir => |step| step.line,
        };
    }
};

pub const Options = struct {
    platform: rootfs_mod.Platform,
    cache_root: []const u8,
    base_storage: spore.RootfsStorage,
    steps: []const Step,
    rootfs_cache_lock: *const rootfs_mod.RootfsCacheLock,
    preparation: ?Preparation = null,
    producer: Producer,
    context_disk_path: ?[]const u8 = null,
    build_input_rootfs: []const spore.Rootfs = &.{},
    resources: RunResources = .{},
    timeout_ms: u64 = default_step_timeout_ms,
    spore_executable: []const u8 = "spore",
    output: ?*Io.Writer = null,
    diagnostic: ?*Diagnostic = null,
};

pub const Preparation = struct {
    input: step_cache.StepInput,
    step_key: []const u8,
    exact_target: u64,
};

pub fn cacheInputForStep(
    platform: rootfs_mod.Platform,
    parent_index_digest: []const u8,
    executor_identity: []const u8,
    step: Step,
    resources: RunResources,
) step_cache.StepInput {
    return switch (step) {
        .run => |run| .{
            .platform = platform,
            .parent_index_digest = parent_index_digest,
            .canonical_instruction = run.canonical_instruction,
            .executor_identity = executor_identity,
            .operation = .{ .run = .{
                .env_digest = run.env_digest,
                .workdir = run.workdir,
                .network_mode = run.network_mode,
                .memory_bytes = resources.memory.bytes,
                .vcpus = resources.vcpus,
                .nofile_soft = resources.nofile.soft,
                .nofile_hard = resources.nofile.hard,
                .cache_mount_digest = run.cache_mount_digest,
            } },
        },
        .copy => |copy| .{
            .platform = platform,
            .parent_index_digest = parent_index_digest,
            .canonical_instruction = copy.canonical_instruction,
            .executor_identity = executor_identity,
            .operation = switch (copy.instruction_kind) {
                .copy => .{ .copy = .{
                    .input_digest = copy.input_digest,
                    .env_digest = copy.env_digest,
                    .workdir = copy.workdir,
                    .destination_policy = copy.destination_policy,
                } },
                .add => .{ .add = .{
                    .input_digest = copy.input_digest,
                    .env_digest = copy.env_digest,
                    .workdir = copy.workdir,
                } },
            },
        },
        .workdir => |workdir| .{
            .platform = platform,
            .parent_index_digest = parent_index_digest,
            .canonical_instruction = workdir.canonical_instruction,
            .executor_identity = executor_identity,
            .operation = .{ .workdir = .{
                .target = workdir.target,
                .env_digest = workdir.env_digest,
                .workdir = workdir.workdir,
            } },
        },
    };
}

const Phase = enum {
    start_resize,
    active_resize,
    start_run,
    start_copy_request,
    active_run,
    start_freeze,
    active_freeze,
    snapshot,
    start_thaw,
    active_thaw,
    p0_idle_start,
    p0_idle_wait,
    done,
    failed,
};

const ActiveStream = enum {
    resize,
    run,
    copy,
    workdir,
    freeze,
    thaw,
};

const CheckpointKind = enum {
    prepare,
    dockerfile_step,
};

const EnospcDetector = struct {
    seen: bool = false,
    tail: [max_enospc_pattern_len - 1]u8 = undefined,
    tail_len: usize = 0,

    fn observe(self: *EnospcDetector, bytes: []const u8) void {
        if (self.seen or bytes.len == 0) return;
        for (enospc_patterns) |pattern| {
            if (std.mem.indexOf(u8, bytes, pattern) != null) {
                self.seen = true;
                return;
            }
            for (1..pattern.len) |split| {
                if (split > self.tail_len or pattern.len - split > bytes.len) continue;
                if (std.mem.endsWith(u8, self.tail[0..self.tail_len], pattern[0..split]) and
                    std.mem.startsWith(u8, bytes, pattern[split..]))
                {
                    self.seen = true;
                    return;
                }
            }
        }
        self.retainTail(bytes);
    }

    fn retainTail(self: *EnospcDetector, bytes: []const u8) void {
        const capacity = self.tail.len;
        if (bytes.len >= capacity) {
            @memcpy(&self.tail, bytes[bytes.len - capacity ..]);
            self.tail_len = capacity;
            return;
        }
        var merged: [2 * (max_enospc_pattern_len - 1)]u8 = undefined;
        @memcpy(merged[0..self.tail_len], self.tail[0..self.tail_len]);
        @memcpy(merged[self.tail_len..][0..bytes.len], bytes);
        const merged_len = self.tail_len + bytes.len;
        const keep = @min(capacity, merged_len);
        @memcpy(self.tail[0..keep], merged[merged_len - keep .. merged_len]);
        self.tail_len = keep;
    }
};

/// Runs all uncached build steps in one build VM session.
///
/// Allocation ownership follows the build path's arena-per-invocation contract:
/// session ids, request buffers, step keys, storage clones, and current_storage
/// replacements live until the caller resets its arena. Do not call this with a
/// long-lived general-purpose allocator.
pub fn runSession(init: std.process.Init, allocator: std.mem.Allocator, options: Options) !spore.RootfsStorage {
    try options.resources.validate();
    if (options.build_input_rootfs.len > max_build_input_disks) return error.TooManyBuildInputDisks;
    if (options.timeout_ms == 0) return error.InvalidBuildTimeout;
    if (options.steps.len == 0) return spore.cloneRootfsStorage(allocator, options.base_storage);
    if (options.diagnostic) |diag| {
        diag.* = .{
            .resize_count = @intFromBool(options.preparation != null),
        };
    }
    const network_mode = try networkModeForSteps(options.steps);
    const session_start_ns = try monotonicNs();
    const cache_run = firstCacheMountRun(options.steps);
    if (!buildDeviceEnvelopeFits(options.context_disk_path != null, options.build_input_rootfs.len, cache_run != null)) {
        if (options.diagnostic) |diag| {
            diag.instruction = cache_run.?.canonical_instruction;
            diag.instruction_line = cache_run.?.line;
        }
        return error.RunCacheMountDeviceBudgetUnsupported;
    }

    var cache_store: ?cache_mount.Store = if (cache_run != null)
        try cache_mount.Store.open(init.io, allocator, options.cache_root)
    else
        null;
    defer if (cache_store) |*store| store.deinit();

    var control = try BuildControl.init(init.io, allocator, options, try p0IdleProbeMs(init.environ_map));
    defer control.deinit();

    const rootfs = try rootfsFromStorage(allocator, options.base_storage);
    const monitor_options = monitorOptionsForSession(options, rootfs, network_mode, if (cache_store) |*store| store.fd else null);
    const boot = switch (options.producer.boot_source) {
        .retained => |retained| retained,
        .managed => |managed| blk: {
            const artifacts = try run_mod.materializeManagedMonitorBootArtifacts(init.io, allocator, managed);
            if (options.diagnostic) |diag| {
                diag.boot_artifact_file_reads += 1;
                diag.boot_artifact_bytes_read += artifacts.kernel.len;
            }
            break :blk artifacts;
        },
    };
    _ = try run_mod.executeMonitorWithBootArtifactsAndRootfsCacheLock(
        .{ .io = init.io, .environ_map = init.environ_map },
        allocator,
        monitor_options,
        boot,
        control.control(),
        null,
        options.rootfs_cache_lock,
    );
    if (cache_store) |*store| try store.sync();

    if (control.failed_exit_code) |exit_code| {
        if (options.diagnostic) |diag| {
            diag.instruction = control.failed_instruction;
            diag.instruction_line = control.failed_instruction_line;
            diag.exit_code = exit_code;
            diag.output = try control.capture.toOwnedSlice();
            diag.enospc = control.enospc_detector.seen;
            diag.boot_count = 1;
            diag.executed_steps = control.executed_steps;
            diag.session_ms = ((try monotonicNs()) -| session_start_ns) / std.time.ns_per_ms;
            diag.instruction_ms = control.instruction_timing.total_ms;
            diag.checkpoint_control_ms = control.checkpoint_control_ms;
            diag.snapshot_ms = control.snapshot_ms;
            diag.max_checkpoint_control_ms = control.max_checkpoint_control_ms;
        }
        return error.BuildRunFailed;
    }
    if (control.failure) |err| return err;
    if (control.phase != .done) return error.BuildGuestProtocolFailed;
    if (options.diagnostic) |diag| {
        diag.boot_count = 1;
        diag.executed_steps = control.executed_steps;
        diag.session_ms = ((try monotonicNs()) -| session_start_ns) / std.time.ns_per_ms;
        diag.instruction_ms = control.instruction_timing.total_ms;
        diag.checkpoint_control_ms = control.checkpoint_control_ms;
        diag.snapshot_ms = control.snapshot_ms;
        diag.max_checkpoint_control_ms = control.max_checkpoint_control_ms;
    }
    return try spore.cloneRootfsStorage(allocator, control.current_storage);
}

fn monitorOptionsForSession(options: Options, rootfs: spore.Rootfs, network_mode: step_cache.NetworkMode, cache_disk_fd: ?std.c.fd_t) run_mod.Options {
    return .{
        .kernel_path = "",
        .initrd_path = null,
        .rootfs = rootfs,
        .rootfs_grow_target = if (options.preparation) |preparation| preparation.exact_target else 0,
        .context_disk_path = options.context_disk_path,
        .build_input_rootfs = options.build_input_rootfs,
        .build_cache_disk_fd = cache_disk_fd,
        .build_mode = true,
        .disk_snapshot_metrics = if (options.diagnostic) |diag| &diag.snapshot_metrics else null,
        .command = &.{},
        .memory = options.resources.memory,
        .vcpus = options.resources.vcpus,
        .network = if (network_mode == .spore) .spore else .disabled,
        .timeout_ms = options.timeout_ms,
        .spore_executable = options.spore_executable,
    };
}

fn firstCacheMountRun(steps: []const Step) ?RunStep {
    for (steps) |step| switch (step) {
        .run => |run| if (run.cache_mounts.len != 0) return run,
        .copy, .workdir => {},
    };
    return null;
}

pub fn buildDeviceEnvelopeFits(has_context: bool, build_input_count: usize, has_cache: bool) bool {
    const fixed_devices: usize = 5; // console, rootfs, net, vsock, rng
    return fixed_devices + @intFromBool(has_context) + build_input_count + @intFromBool(has_cache) <= board.max_virtio_devices;
}

test "cache mounts preserve the frozen build device envelope" {
    try std.testing.expect(buildDeviceEnvelopeFits(true, 1, true));
    try std.testing.expect(buildDeviceEnvelopeFits(false, 2, true));
    try std.testing.expect(!buildDeviceEnvelopeFits(true, 2, true));
}

fn networkModeForSteps(steps: []const Step) !step_cache.NetworkMode {
    var mode: ?step_cache.NetworkMode = null;
    for (steps) |step| switch (step) {
        .run => |run| {
            if (mode) |existing| {
                if (existing != run.network_mode) return error.BuildNetworkModeMismatch;
            } else {
                mode = run.network_mode;
            }
        },
        .copy, .workdir => {},
    };
    return mode orelse .none;
}

/// Session state is arena-owned; see `runSession` for the allocator lifetime
/// contract. Fields that are replaced during checkpointing are intentionally not
/// individually freed.
const InstructionTiming = struct {
    total_ms: u64 = 0,
    current_step_ms: u64 = 0,

    fn record(self: *InstructionTiming, elapsed_ms: u64) void {
        self.total_ms +|= elapsed_ms;
        self.current_step_ms +|= elapsed_ms;
    }

    fn elapsedWithActive(self: InstructionTiming, active_ms: u64) u64 {
        return self.current_step_ms +| active_ms;
    }

    fn finishStep(self: *InstructionTiming) void {
        self.current_step_ms = 0;
    }
};

const BuildControl = struct {
    io: Io,
    allocator: std.mem.Allocator,
    platform: rootfs_mod.Platform,
    executor_identity: []const u8,
    cache_root: []const u8,
    steps: []const Step,
    resources: RunResources,
    timeout_ms: u64,
    output: ?*Io.Writer,
    current_storage: spore.RootfsStorage,
    preparation: ?Preparation = null,
    rootfs_grow_target: u64 = 0,
    checkpoint_kind: CheckpointKind = .dockerfile_step,
    step_index: usize = 0,
    phase: Phase = .start_run,
    active_stream: ActiveStream = .run,
    stream: vsock.HostStream = undefined,
    stream_valid: bool = false,
    stream_sequence: u64 = 0,
    active_input: ?step_cache.StepInput = null,
    active_step_key: []const u8 = "",
    pending_storage: ?spore.RootfsStorage = null,
    active_stdin_payload: []const u8 = "",
    active_stdin_offset: usize = 0,
    active_stdin_close_sent: bool = true,
    active_copy_request_index: usize = 0,
    capture: std.array_list.Managed(u8),
    resize_stdout: std.array_list.Managed(u8),
    resize_stdout_overflow: bool = false,
    enospc_detector: EnospcDetector = .{},
    p0_idle_probe_ms: u64 = 0,
    p0_idle_deadline_ns: u64 = 0,
    p0_idle_baseline: vsock.ControlStats = .{},
    latest_stats: vsock.ControlStats = .{},
    executed_steps: usize = 0,
    failed_instruction: ?[]const u8 = null,
    failed_instruction_line: usize = 0,
    failed_exit_code: ?i32 = null,
    failure: ?anyerror = null,
    checkpoint_control_ms: u64 = 0,
    snapshot_ms: u64 = 0,
    snapshot_metrics: ?*disk_layer.SnapshotMetrics = null,
    max_checkpoint_control_ms: u64 = 0,
    preparation_start_ns: ?u64 = null,
    preparation_publish_ms: ?u64 = null,
    instruction_timing: InstructionTiming = .{},

    fn init(io: Io, allocator: std.mem.Allocator, options: Options, p0_idle_probe_ms: u64) !BuildControl {
        return .{
            .io = io,
            .allocator = allocator,
            .platform = options.platform,
            .executor_identity = options.producer.identity,
            .cache_root = options.cache_root,
            .steps = options.steps,
            .resources = options.resources,
            .timeout_ms = options.timeout_ms,
            .output = options.output,
            .current_storage = try spore.cloneRootfsStorage(allocator, options.base_storage),
            .preparation = options.preparation,
            .rootfs_grow_target = if (options.preparation) |preparation| preparation.exact_target else 0,
            .checkpoint_kind = if (options.preparation == null) .dockerfile_step else .prepare,
            .phase = if (options.preparation == null) .start_run else .start_resize,
            .active_input = if (options.preparation) |preparation| preparation.input else null,
            .active_step_key = if (options.preparation) |preparation| preparation.step_key else "",
            .capture = std.array_list.Managed(u8).init(allocator),
            .resize_stdout = std.array_list.Managed(u8).init(allocator),
            .p0_idle_probe_ms = p0_idle_probe_ms,
            .snapshot_metrics = if (options.diagnostic) |diag| &diag.snapshot_metrics else null,
        };
    }

    fn deinit(self: *BuildControl) void {
        self.capture.deinit();
        self.resize_stdout.deinit();
    }

    fn control(self: *BuildControl) vsock.Control {
        return .{
            .context = self,
            .pollFn = pollThunk,
            .setWakeFn = setWakeThunk,
            .completeSnapshotFn = completeSnapshotThunk,
            .completeRootfsSnapshotFn = completeRootfsSnapshotThunk,
            .reportStatsFn = reportStatsThunk,
        };
    }

    fn poll(self: *BuildControl, dev: *vsock.Vsock) !vsock.ControlAction {
        switch (self.phase) {
            .start_resize => {
                try self.startResize(dev);
                return .keep_running;
            },
            .active_resize => return try self.pollActiveStream(dev),
            .start_run => {
                try self.startStep(dev);
                return .keep_running;
            },
            .start_copy_request => {
                try self.startCopyRequest(dev);
                return .keep_running;
            },
            .active_run => return try self.pollActiveStream(dev),
            .start_freeze => {
                try self.startSimpleControl(dev, .freeze);
                return .keep_running;
            },
            .active_freeze => return try self.pollActiveStream(dev),
            .snapshot => return .{ .rootfs_snapshot = .{ .dir = self.cache_root } },
            .start_thaw => {
                try self.startSimpleControl(dev, .thaw);
                return .keep_running;
            },
            .active_thaw => return try self.pollActiveStream(dev),
            .p0_idle_start => {
                self.p0_idle_baseline = self.latest_stats;
                self.p0_idle_deadline_ns = std.math.add(u64, try monotonicNs(), self.p0_idle_probe_ms * std.time.ns_per_ms) catch return error.ClockFailed;
                self.phase = .p0_idle_wait;
                return .keep_running;
            },
            .p0_idle_wait => {
                if (try monotonicNs() < self.p0_idle_deadline_ns) return .keep_running;
                try validateIdleBlockStats(self.p0_idle_baseline, self.latest_stats);
                std.log.info("rootfs growth P0 idle: ms={d} write_zeroes_delta=0 out_delta=0", .{self.p0_idle_probe_ms});
                self.phase = .start_freeze;
                return .keep_running;
            },
            .done, .failed => return .stop,
        }
    }

    fn startResize(self: *BuildControl, dev: *vsock.Vsock) !void {
        if (self.preparation_start_ns != null) return error.BadManifest;
        self.preparation_start_ns = try monotonicNs();
        const request = try run_mod.simpleControlRequest(self.allocator, "spore-rootfs-grow-v1", "spore-build-resize");
        try self.startStream(dev, request, .spore_stream_v1, .resize, "");
        self.phase = .active_resize;
    }

    fn startStep(self: *BuildControl, dev: *vsock.Vsock) !void {
        const step = self.steps[self.step_index];
        self.enospc_detector = .{};
        self.executed_steps += 1;
        self.checkpoint_kind = .dockerfile_step;
        const input = self.stepInput(step);
        self.active_input = input;
        self.active_step_key = try step_cache.stepKey(self.allocator, input);
        const session_id = try std.fmt.allocPrint(self.allocator, "spore-build-{d}", .{self.step_index + 1});
        switch (step) {
            .run => |run| {
                const request = try runRequestWithMounts(self.allocator, session_id, run.command, run.env, run.workdir, self.resources.nofile, run.cache_mounts, self.io);
                const stdin_payload = switch (run.command) {
                    .shell => |shell| shell,
                    .exec => "",
                };
                try self.startStream(dev, request, .spore_stream_v1, .run, stdin_payload);
            },
            .copy => |copy| {
                if (copy.requests.len == 0) return error.CopyEntryCountUnsupported;
                for (copy.requests) |request| {
                    if (request.destination_policy != copy.destination_policy) return error.BadManifest;
                }
                self.active_copy_request_index = 0;
                try self.startCopyRequest(dev);
            },
            .workdir => |workdir| {
                const request = try workdirRequest(self.allocator, session_id, workdir.target);
                try self.startStream(dev, request, .spore_stream_v1, .workdir, "");
            },
        }
        self.phase = .active_run;
    }

    fn startCopyRequest(self: *BuildControl, dev: *vsock.Vsock) !void {
        const copy = switch (self.steps[self.step_index]) {
            .copy => |copy| copy,
            .run, .workdir => return error.BadManifest,
        };
        if (self.active_copy_request_index >= copy.requests.len) return error.BadManifest;
        const session_id = try std.fmt.allocPrint(self.allocator, "spore-build-{d}-{d}", .{ self.step_index + 1, self.active_copy_request_index + 1 });
        const request = try copyRequest(self.allocator, session_id, copy.requests[self.active_copy_request_index]);
        try self.startStream(dev, request, .spore_stream_v1, .copy, "");
        self.phase = .active_run;
    }

    fn stepInput(self: BuildControl, step: Step) step_cache.StepInput {
        return cacheInputForStep(self.platform, self.current_storage.index_digest, self.executor_identity, step, self.resources);
    }

    fn startSimpleControl(self: *BuildControl, dev: *vsock.Vsock, kind: ActiveStream) !void {
        const session_id = try checkpointSessionId(self.allocator, kind, self.checkpoint_kind, self.step_index);
        const request = switch (kind) {
            .freeze => try run_mod.simpleControlRequest(self.allocator, "fsfreeze-v1", session_id),
            .thaw => try run_mod.simpleControlRequest(self.allocator, "fsthaw-v1", session_id),
            .resize, .run, .copy, .workdir => unreachable,
        };
        try self.startStream(dev, request, .spore_stream_v1, kind, "");
        self.phase = switch (kind) {
            .freeze => .active_freeze,
            .thaw => .active_thaw,
            .resize, .run, .copy, .workdir => unreachable,
        };
    }

    fn startStream(self: *BuildControl, dev: *vsock.Vsock, request: []const u8, protocol: vsock.HostStreamProtocol, kind: ActiveStream, stdin_payload: []const u8) !void {
        self.stream = try vsock.HostStream.initWithProtocol(guest_port, request, protocol);
        self.stream.host_port = vsock.HostStream.hostPortForSequence(self.stream_sequence);
        self.stream_sequence +%= 1;
        self.active_stream = kind;
        if (kind == .run or kind == .copy or kind == .workdir or kind == .resize) self.stream.setOutputSink(self, outputSink);
        self.active_stdin_payload = stdin_payload;
        self.active_stdin_offset = 0;
        self.active_stdin_close_sent = kind != .run or stdin_payload.len == 0;
        try dev.attachHostStream(&self.stream);
        self.stream.markStarted();
        self.stream_valid = true;
        try self.pumpActiveStdin();
        _ = try dev.flushHostStreamOutbound();
    }

    fn pollActiveStream(self: *BuildControl, dev: *vsock.Vsock) !vsock.ControlAction {
        if (!self.stream_valid) return .keep_running;
        try self.pumpActiveStdin();
        _ = try dev.flushHostStreamOutbound();
        switch (self.stream.state) {
            .complete => {
                const exit_code = self.stream.exit_code orelse return error.BadRunExitFrame;
                if (self.active_stream == .run or self.active_stream == .copy or self.active_stream == .workdir) {
                    self.instruction_timing.record(self.stream.elapsedMs());
                }
                dev.resetHostStream();
                self.stream_valid = false;
                try self.finishActiveStream(exit_code);
            },
            .failed => {
                dev.resetHostStream();
                self.stream_valid = false;
                self.failure = error.BuildGuestProtocolFailed;
                self.phase = .failed;
            },
            else => {
                const elapsed = if (self.active_stream == .run or self.active_stream == .copy or self.active_stream == .workdir)
                    self.instruction_timing.elapsedWithActive(self.stream.elapsedMs())
                else
                    self.stream.elapsedMs();
                if (elapsed > self.timeout_ms) {
                    dev.resetHostStream();
                    self.stream_valid = false;
                    self.failure = error.BuildGuestTimedOut;
                    self.phase = .failed;
                }
            },
        }
        return .keep_running;
    }

    fn finishActiveStream(self: *BuildControl, exit_code: i32) !void {
        switch (self.active_stream) {
            .resize => {
                if (exit_code != 0) {
                    self.failure = error.BuildGuestResizeFailed;
                    self.phase = .failed;
                    return;
                }
                if (self.resize_stdout_overflow) return error.BuildGuestResizeResponseInvalid;
                const result = parseRootfsGrowResponse(self.resize_stdout.items) catch return error.BuildGuestResizeResponseInvalid;
                if (result.device_bytes != self.rootfs_grow_target) return error.BuildGuestResizeGeometryMismatch;
                self.capture.clearRetainingCapacity();
                self.phase = if (self.p0_idle_probe_ms == 0) .start_freeze else .p0_idle_start;
            },
            .run, .copy, .workdir => {
                if (exit_code != 0) {
                    self.failed_instruction = self.steps[self.step_index].canonicalInstruction();
                    self.failed_instruction_line = self.steps[self.step_index].line();
                    self.failed_exit_code = exit_code;
                    self.phase = .failed;
                    return;
                }
                if (self.active_stream == .copy) {
                    const copy = switch (self.steps[self.step_index]) {
                        .copy => |copy| copy,
                        .run, .workdir => return error.BadManifest,
                    };
                    self.active_copy_request_index += 1;
                    if (self.active_copy_request_index < copy.requests.len) {
                        self.capture.clearRetainingCapacity();
                        self.phase = .start_copy_request;
                        return;
                    }
                }
                self.phase = .start_freeze;
            },
            .freeze => {
                const elapsed_ms = self.stream.elapsedMs();
                self.checkpoint_control_ms +|= elapsed_ms;
                self.max_checkpoint_control_ms = @max(self.max_checkpoint_control_ms, elapsed_ms);
                if (exit_code != 0) {
                    self.failure = error.BuildGuestFreezeFailed;
                    self.phase = .failed;
                    return;
                }
                self.phase = .snapshot;
            },
            .thaw => {
                const elapsed_ms = self.stream.elapsedMs();
                self.checkpoint_control_ms +|= elapsed_ms;
                self.max_checkpoint_control_ms = @max(self.max_checkpoint_control_ms, elapsed_ms);
                if (exit_code != 0) {
                    self.failure = error.BuildGuestThawFailed;
                    self.phase = .failed;
                    return;
                }
                // The storage index is durable after the snapshot, but the
                // step is not reusable until the guest has restored its
                // filesystem state. Publishing the record here keeps a failed
                // thaw from turning an incomplete build transition into a hit.
                const storage = self.pending_storage orelse return error.BadManifest;
                const input = self.active_input orelse return error.BadManifest;
                if (self.active_step_key.len == 0) return error.BadManifest;
                _ = try step_cache.writeRecord(self.io, self.allocator, self.cache_root, input, self.active_step_key, storage);
                const completed_kind = self.checkpoint_kind;
                if (completed_kind == .prepare) {
                    const start_ns = self.preparation_start_ns orelse return error.BadManifest;
                    self.preparation_publish_ms = ((try monotonicNs()) -| start_ns) / std.time.ns_per_ms;
                }
                self.current_storage = storage;
                self.pending_storage = null;
                if (completed_kind == .dockerfile_step) {
                    self.step_index += 1;
                    self.instruction_timing.finishStep();
                }
                self.active_input = null;
                self.active_step_key = "";
                self.active_stdin_payload = "";
                self.active_stdin_offset = 0;
                self.active_stdin_close_sent = true;
                self.active_copy_request_index = 0;
                self.capture.clearRetainingCapacity();
                if (completed_kind == .prepare) {
                    const start_ns = self.preparation_start_ns orelse return error.BadManifest;
                    const elapsed_ns = (try monotonicNs()) -| start_ns;
                    var metrics_buf: [256]u8 = undefined;
                    const metrics = try preparationMetricsLine(
                        &metrics_buf,
                        self.preparation_publish_ms orelse return error.BadManifest,
                        elapsed_ns / std.time.ns_per_ms,
                        self.rootfs_grow_target / (1024 * 1024),
                        self.max_checkpoint_control_ms,
                    );
                    std.log.info("{s}", .{metrics});
                    self.preparation = null;
                    self.checkpoint_kind = .dockerfile_step;
                    self.phase = .start_run;
                } else {
                    self.phase = if (self.step_index >= self.steps.len) .done else .start_run;
                }
            },
        }
    }

    fn pumpActiveStdin(self: *BuildControl) !void {
        if (self.active_stdin_close_sent) return;
        while (self.active_stdin_offset < self.active_stdin_payload.len) {
            const written = try self.stream.enqueueStdinDataNonblocking(self.active_stdin_payload[self.active_stdin_offset..]);
            if (written == 0) return;
            self.active_stdin_offset += written;
        }
        self.active_stdin_close_sent = try self.stream.enqueueStdinCloseNonblocking();
    }

    fn completeRootfsSnapshot(self: *BuildControl, maybe_disk: ?spore.Disk) !void {
        if (self.phase != .snapshot) return;
        if (self.pending_storage != null) return error.BadManifest;
        _ = self.active_input orelse return error.BadManifest;
        if (self.active_step_key.len == 0) return error.BadManifest;
        const disk = maybe_disk orelse return error.BadManifest;
        if (self.snapshot_metrics) |metrics| self.snapshot_ms +|= metrics.total_us / std.time.us_per_ms;
        const storage = try runtime_disk.storageFromSnapshotDisk(self.allocator, disk);
        if (self.checkpoint_kind == .prepare) try validatePreparedStorage(self.current_storage, storage, self.rootfs_grow_target);
        // A zero-dirty RUN/COPY/WORKDIR can intentionally yield child digest ==
        // parent digest; the step key still proves which instruction inputs ran.
        try rootfs_cas.markStorageComplete(self.io, self.allocator, self.cache_root, storage.index_digest);
        self.pending_storage = storage;
        self.phase = .start_thaw;
    }

    fn setWake(_: *BuildControl, _: vsock.Wake) void {}

    fn completeSnapshot(_: *BuildControl, _: []const u8) !void {}

    fn reportStats(self: *BuildControl, stats: vsock.ControlStats) void {
        self.latest_stats = stats;
    }

    fn appendOutput(self: *BuildControl, bytes: []const u8) void {
        self.enospc_detector.observe(bytes);
        if (self.output) |writer| {
            writer.writeAll(bytes) catch {};
            writer.flush() catch {};
        }
        const remaining = max_captured_output -| self.capture.items.len;
        const take = @min(remaining, bytes.len);
        if (take != 0) self.capture.appendSlice(bytes[0..take]) catch {};
    }

    fn outputSink(context: ?*anyopaque, output: vsock.HostStreamOutput, bytes: []const u8) void {
        const self: *BuildControl = @ptrCast(@alignCast(context.?));
        if (self.active_stream == .resize and output == .stdout) {
            const remaining = max_rootfs_grow_response -| self.resize_stdout.items.len;
            if (bytes.len > remaining) self.resize_stdout_overflow = true;
            const take = @min(remaining, bytes.len);
            if (take != 0) self.resize_stdout.appendSlice(bytes[0..take]) catch {
                self.resize_stdout_overflow = true;
            };
        }
        self.appendOutput(bytes);
    }

    fn pollThunk(context: *anyopaque, dev: *vsock.Vsock) !vsock.ControlAction {
        const self: *BuildControl = @ptrCast(@alignCast(context));
        return self.poll(dev);
    }

    fn setWakeThunk(context: *anyopaque, wake: vsock.Wake) void {
        const self: *BuildControl = @ptrCast(@alignCast(context));
        self.setWake(wake);
    }

    fn completeSnapshotThunk(context: *anyopaque, dir: []const u8) !void {
        const self: *BuildControl = @ptrCast(@alignCast(context));
        try self.completeSnapshot(dir);
    }

    fn completeRootfsSnapshotThunk(context: *anyopaque, disk: ?spore.Disk) !void {
        const self: *BuildControl = @ptrCast(@alignCast(context));
        try self.completeRootfsSnapshot(disk);
    }

    fn reportStatsThunk(context: *anyopaque, stats: vsock.ControlStats) void {
        const self: *BuildControl = @ptrCast(@alignCast(context));
        self.reportStats(stats);
    }
};

pub fn validatePreparedStorage(parent: spore.RootfsStorage, child: spore.RootfsStorage, exact_target: u64) !void {
    try spore.validateRootfsStorageDescriptor(parent);
    try spore.validateRootfsStorageDescriptor(child);
    if (child.logical_size != exact_target or
        !std.mem.eql(u8, parent.kind, child.kind) or
        !spore.rootfsDeviceEql(parent.device, child.device) or
        parent.chunk_size != child.chunk_size or
        !std.mem.eql(u8, parent.hash_algorithm, child.hash_algorithm) or
        !std.mem.eql(u8, parent.object_namespace, child.object_namespace))
    {
        return error.BuildGuestResizeGeometryMismatch;
    }
}

fn checkpointSessionId(allocator: std.mem.Allocator, kind: ActiveStream, checkpoint_kind: CheckpointKind, step_index: usize) ![]const u8 {
    const name = switch (kind) {
        .freeze => "freeze",
        .thaw => "thaw",
        .resize, .run, .copy, .workdir => unreachable,
    };
    return if (checkpoint_kind == .prepare)
        std.fmt.allocPrint(allocator, "spore-build-prepare-{s}", .{name})
    else
        std.fmt.allocPrint(allocator, "spore-build-{s}-{d}", .{ name, step_index + 1 });
}

fn preparationMetricsLine(buf: []u8, publish_ms: u64, resume_ms: u64, target_mib: u64, checkpoint_control_max_ms: u64) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "rootfs preparation metrics: publish_ms={d} resume_ms={d} target_mib={d} checkpoint_control_max_ms={d}",
        .{ publish_ms, resume_ms, target_mib, checkpoint_control_max_ms },
    );
}

fn parseRootfsGrowResponse(bytes: []const u8) !run_mod.RootfsGrowResult {
    return run_mod.parseRootfsGrowResponse(bytes);
}

fn parseP0IdleProbeMs(value: ?[]const u8) !u64 {
    const raw = value orelse return 0;
    if (raw.len == 0 or std.mem.eql(u8, raw, "0")) return 0;
    const parsed = std.fmt.parseUnsigned(u64, raw, 10) catch return error.BadP0IdleProbe;
    if (parsed > max_p0_idle_probe_ms) return error.BadP0IdleProbe;
    return parsed;
}

fn p0IdleProbeMs(environ: *const std.process.Environ.Map) !u64 {
    if (!run_mod.rootfsGrowthExperimentsEnabled(environ)) return 0;
    return parseP0IdleProbeMs(environ.get(p0_idle_probe_env));
}

fn validateIdleBlockStats(before: vsock.ControlStats, after: vsock.ControlStats) !void {
    const before_write_zeroes_requests = before.write_zeroes_requests orelse return error.MissingP0BlockStats;
    const before_write_zeroes_bytes = before.write_zeroes_bytes orelse return error.MissingP0BlockStats;
    const before_write_zeroes_errors = before.write_zeroes_errors orelse return error.MissingP0BlockStats;
    const before_write_zeroes_backend_failures = before.write_zeroes_backend_failures orelse return error.MissingP0BlockStats;
    const before_write_zeroes_unsupported = before.write_zeroes_unsupported orelse return error.MissingP0BlockStats;
    const before_out_requests = before.out_requests orelse return error.MissingP0BlockStats;
    const before_out_bytes = before.out_bytes orelse return error.MissingP0BlockStats;
    if ((after.write_zeroes_requests orelse return error.MissingP0BlockStats) != before_write_zeroes_requests or
        (after.write_zeroes_bytes orelse return error.MissingP0BlockStats) != before_write_zeroes_bytes or
        (after.write_zeroes_errors orelse return error.MissingP0BlockStats) != before_write_zeroes_errors or
        (after.write_zeroes_backend_failures orelse return error.MissingP0BlockStats) != before_write_zeroes_backend_failures or
        (after.write_zeroes_unsupported orelse return error.MissingP0BlockStats) != before_write_zeroes_unsupported or
        (after.out_requests orelse return error.MissingP0BlockStats) != before_out_requests or
        (after.out_bytes orelse return error.MissingP0BlockStats) != before_out_bytes)
    {
        return error.RootfsBackgroundWritesDetected;
    }
}

fn monotonicNs() !u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return error.ClockFailed;
    const seconds = std.math.mul(u64, @intCast(ts.sec), std.time.ns_per_s) catch return error.ClockFailed;
    return std.math.add(u64, seconds, @intCast(ts.nsec)) catch return error.ClockFailed;
}

fn runRequest(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    command: RunCommand,
    env: []const []const u8,
    workdir: []const u8,
    nofile: NofileLimit,
    io: Io,
) ![]const u8 {
    return runRequestWithMounts(allocator, session_id, command, env, workdir, nofile, &.{}, io);
}

fn runRequestWithMounts(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    command: RunCommand,
    env: []const []const u8,
    workdir: []const u8,
    nofile: NofileLimit,
    cache_mounts: []const cache_mount.Mount,
    io: Io,
) ![]const u8 {
    const now: u64 = @intCast(Io.Clock.real.now(io).nanoseconds);
    const json = try runRequestJson(allocator, session_id, command, env, workdir, nofile, cache_mounts, now);
    defer allocator.free(json);
    if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

pub fn validateRunRequest(
    allocator: std.mem.Allocator,
    command: RunCommand,
    env: []const []const u8,
    workdir: []const u8,
    nofile: NofileLimit,
) !void {
    return validateRunRequestWithMounts(allocator, command, env, workdir, nofile, &.{});
}

pub fn validateRunRequestWithMounts(
    allocator: std.mem.Allocator,
    command: RunCommand,
    env: []const []const u8,
    workdir: []const u8,
    nofile: NofileLimit,
    cache_mounts: []const cache_mount.Mount,
) !void {
    const max_session_id = "x" ** 63;
    const json = try runRequestJson(allocator, max_session_id, command, env, workdir, nofile, cache_mounts, std.math.maxInt(u64));
    defer allocator.free(json);
    if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
}

fn runRequestJson(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    command: RunCommand,
    env: []const []const u8,
    workdir: []const u8,
    nofile: NofileLimit,
    cache_mounts: []const cache_mount.Mount,
    now: u64,
) ![]const u8 {
    try nofile.validate();
    if (workdir.len == 0 or workdir.len > max_guest_working_dir_len) return error.RunWorkingDirUnsupported;
    if (env.len > max_guest_envc) return error.RunEnvCountUnsupported;
    for (env) |entry| if (entry.len > max_guest_env_len) return error.RunEnvTooLong;
    if (cache_mounts.len > cache_mount.max_mounts_per_run) return error.TooManyRunCacheMounts;
    if (cache_mounts.len != 0) {
        const shell = switch (command) {
            .shell => |value| value,
            .exec => "",
        };
        const argv = switch (command) {
            .shell => &.{},
            .exec => |value| value,
        };
        if (shell.len > max_run_command_len) return error.RunCommandTooLong;
        if (argv.len != 0) {
            if (run_contract.execArgvViolation(argv)) |violation| switch (violation) {
                .empty, .too_many_args => return error.RunArgCountUnsupported,
                .empty_executable, .nul => return error.RunArgUnsupported,
                .decoded_too_large => return error.RunRequestTooLarge,
            };
        }
        const PayloadMount = struct { target: []const u8, key: []const u8 };
        const payload_mounts = try allocator.alloc(PayloadMount, cache_mounts.len);
        defer allocator.free(payload_mounts);
        for (cache_mounts, 0..) |mount, index| payload_mounts[index] = .{ .target = mount.target, .key = mount.key };
        const payload = struct {
            type: []const u8 = "spore-build-run-v3",
            session_id: []const u8,
            resume_time_unix_ns: u64,
            command_len: usize,
            argv: []const []const u8,
            env: []const []const u8,
            working_dir: []const u8,
            cache_mounts: []const PayloadMount,
            stdio: []const u8 = "pipe",
            term: []const u8 = "xterm",
            terminal_rows: u16 = 24,
            terminal_cols: u16 = 80,
            memory_pressure: bool = false,
            nofile_soft: u64,
            nofile_hard: u64,
            closed_env: bool = true,
        }{
            .session_id = session_id,
            .resume_time_unix_ns = now,
            .command_len = shell.len,
            .argv = argv,
            .env = env,
            .working_dir = workdir,
            .cache_mounts = payload_mounts,
            .nofile_soft = nofile.soft,
            .nofile_hard = nofile.hard,
        };
        return std.json.Stringify.valueAlloc(allocator, payload, .{});
    }
    return switch (command) {
        .shell => |shell| blk: {
            if (shell.len > max_run_command_len) return error.RunCommandTooLong;
            const payload = struct {
                type: []const u8 = "spore-build-run-v1",
                session_id: []const u8,
                resume_time_unix_ns: u64,
                command_len: usize,
                env: []const []const u8,
                working_dir: []const u8,
                stdio: []const u8 = "pipe",
                term: []const u8 = "xterm",
                terminal_rows: u16 = 24,
                terminal_cols: u16 = 80,
                memory_pressure: bool = false,
                nofile_soft: u64,
                nofile_hard: u64,
                closed_env: bool = true,
            }{
                .session_id = session_id,
                .resume_time_unix_ns = now,
                .command_len = shell.len,
                .env = env,
                .working_dir = workdir,
                .nofile_soft = nofile.soft,
                .nofile_hard = nofile.hard,
            };
            break :blk try std.json.Stringify.valueAlloc(allocator, payload, .{});
        },
        .exec => |argv| blk: {
            if (run_contract.execArgvViolation(argv)) |violation| switch (violation) {
                .empty, .too_many_args => return error.RunArgCountUnsupported,
                .empty_executable, .nul => return error.RunArgUnsupported,
                .decoded_too_large => return error.RunRequestTooLarge,
            };
            const payload = struct {
                type: []const u8 = "spore-build-run-v2",
                session_id: []const u8,
                resume_time_unix_ns: u64,
                argv: []const []const u8,
                env: []const []const u8,
                working_dir: []const u8,
                stdio: []const u8 = "pipe",
                term: []const u8 = "xterm",
                terminal_rows: u16 = 24,
                terminal_cols: u16 = 80,
                memory_pressure: bool = false,
                nofile_soft: u64,
                nofile_hard: u64,
                closed_env: bool = true,
            }{
                .session_id = session_id,
                .resume_time_unix_ns = now,
                .argv = argv,
                .env = env,
                .working_dir = workdir,
                .nofile_soft = nofile.soft,
                .nofile_hard = nofile.hard,
            };
            break :blk try std.json.Stringify.valueAlloc(allocator, payload, .{});
        },
    };
}

fn copyRequest(allocator: std.mem.Allocator, session_id: []const u8, request: CopyRequest) ![]const u8 {
    try validateCopyRequest(request);
    const payload = struct {
        type: []const u8 = "spore-build-copy-v4",
        session_id: []const u8,
        source: []const u8,
        dest: []const u8,
        source_kind: []const u8,
        dest_is_dir: bool,
        entry_count: usize,
        source_disk: []const u8,
        input_index: usize,
        mtime_unix_seconds: ?i64,
    }{
        .session_id = session_id,
        .source = request.source,
        .dest = request.dest,
        .source_kind = @tagName(request.source_kind),
        .dest_is_dir = request.dest_is_dir,
        .entry_count = request.entry_count,
        .source_disk = @tagName(request.source_disk),
        .input_index = request.input_index,
        .mtime_unix_seconds = request.mtime_unix_seconds,
    };
    const json = switch (request.destination_policy) {
        .follow => try std.json.Stringify.valueAlloc(allocator, payload, .{}),
        .link => blk: {
            const LinkPayload = struct {
                type: []const u8 = "spore-build-copy-v5",
                session_id: []const u8,
                source: []const u8,
                dest: []const u8,
                source_kind: []const u8,
                dest_is_dir: bool,
                entry_count: usize,
                source_disk: []const u8,
                input_index: usize,
                mtime_unix_seconds: ?i64,
                destination_policy: []const u8 = "link",
            };
            break :blk try std.json.Stringify.valueAlloc(allocator, LinkPayload{
                .session_id = session_id,
                .source = request.source,
                .dest = request.dest,
                .source_kind = @tagName(request.source_kind),
                .dest_is_dir = request.dest_is_dir,
                .entry_count = request.entry_count,
                .source_disk = @tagName(request.source_disk),
                .input_index = request.input_index,
                .mtime_unix_seconds = request.mtime_unix_seconds,
            }, .{});
        },
    };
    defer allocator.free(json);
    if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

fn workdirRequest(allocator: std.mem.Allocator, session_id: []const u8, target: []const u8) ![]const u8 {
    try validateWorkdirTarget(target);
    const payload = struct {
        type: []const u8 = "spore-build-workdir-v1",
        session_id: []const u8,
        working_dir: []const u8,
    }{
        .session_id = session_id,
        .working_dir = target,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

pub fn validateWorkdirTarget(target: []const u8) !void {
    if (target.len == 0 or target.len > max_guest_working_dir_len or !std.fs.path.isAbsolute(target)) return error.RunWorkingDirUnsupported;
}

pub fn validateCopyRequest(request: CopyRequest) !void {
    if (request.source.len == 0 or request.source.len > max_copy_entry_path_len) return error.CopySourceNotFound;
    if (std.fs.path.isAbsolute(request.source)) return error.CopySourceEscapesContext;
    if (!std.mem.eql(u8, request.source, ".")) {
        var source_it = std.mem.splitScalar(u8, request.source, '/');
        while (source_it.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.CopySourceEscapesContext;
        }
    }
    if (request.dest.len == 0 or request.dest.len > max_copy_entry_path_len) return error.CopyDestinationUnsupported;
    if (!std.fs.path.isAbsolute(request.dest)) return error.CopyDestinationUnsupported;
    if (request.dest.len > 1 and std.mem.endsWith(u8, request.dest, "/")) return error.CopyDestinationUnsupported;
    if (request.dest.len > 1) {
        var it = std.mem.splitScalar(u8, request.dest[1..], '/');
        while (it.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.CopyDestinationUnsupported;
        }
    }
    if (request.dest_is_dir) try validateCopyDestinationJoin(request);
    if (request.source_disk == .context) {
        if (request.source_kind == .auto or request.input_index != 0) return error.CopySourceUnsupported;
        if (request.entry_count == 0 or request.entry_count > max_copy_entries) return error.CopyEntryCountUnsupported;
    } else {
        if (request.source_kind != .auto or request.entry_count != 0 or request.input_index >= max_build_input_disks) return error.CopySourceUnsupported;
    }
    if (request.destination_policy == .link and request.source_disk != .build_input) return error.CopySourceUnsupported;
}

pub fn validateCopyDestinationJoin(request: CopyRequest) !void {
    if (request.source_kind != .directory) {
        const source_name = std.fs.path.basename(request.source);
        const separator_len: usize = if (std.mem.eql(u8, request.dest, "/")) 0 else 1;
        if (request.dest.len + separator_len + source_name.len > max_copy_entry_path_len) return error.CopyDestinationUnsupported;
    }
}

pub fn rootfsFromStorage(allocator: std.mem.Allocator, storage: spore.RootfsStorage) !spore.Rootfs {
    return .{
        .device = try spore.cloneRootfsDevice(allocator, storage.device),
        .artifact = .{
            .digest = try allocator.dupe(u8, storage.index_digest),
            .size = storage.logical_size,
            .format = try allocator.dupe(u8, spore.rootfs_artifact_format_ext4),
        },
        .storage = try spore.cloneRootfsStorage(allocator, storage),
    };
}

fn fuzzSimpleRequest(_: void, s: *std.testing.Smith) !void {
    var buf: [64]u8 = undefined;
    const len = s.slice(&buf);
    const request = run_mod.simpleControlRequest(std.testing.allocator, buf[0..len], "session") catch return;
    defer std.testing.allocator.free(request);
    try std.testing.expect(request.len <= max_guest_request_len);
}

fn fuzzCopyRequest(_: void, s: *std.testing.Smith) !void {
    var path_buf: [64]u8 = undefined;
    const raw_len = s.slice(&path_buf);
    for (path_buf[0..raw_len]) |*byte| {
        if (byte.* == 0 or byte.* == '/') byte.* = 'x';
    }
    const name = if (raw_len == 0) "x" else path_buf[0..raw_len];
    const link = raw_len != 0 and (path_buf[0] & 1) != 0;
    var path_storage: [80]u8 = undefined;
    const dest = std.fmt.bufPrint(&path_storage, "/{s}", .{name}) catch return;
    const request = copyRequest(std.testing.allocator, "spore-build-1", .{
        .source = name,
        .dest = dest,
        .source_kind = if (link) .auto else .file,
        .dest_is_dir = false,
        .entry_count = if (link) 0 else 1,
        .source_disk = if (link) .build_input else .context,
        .destination_policy = if (link) .link else .follow,
    }) catch return;
    defer std.testing.allocator.free(request);
    try std.testing.expect(request.len <= max_guest_request_len);
    if (comptime guest_agent_fuzz_supported) {
        _ = spore_agent_fuzz_build_request(request.ptr, request.len, path_buf[0..0].ptr, 0);
    }
}

const guest_agent_fuzz_supported = builtin.os.tag == .linux and builtin.cpu.arch == .aarch64;
const guest_agent_fuzz_invalid: c_int = 0;
const guest_agent_fuzz_run_request: c_int = 1;
const guest_agent_fuzz_copy_request: c_int = 2;
const guest_agent_fuzz_run_complete: c_int = 3;
const guest_agent_fuzz_workdir_request: c_int = 4;
const guest_agent_fuzz_ready_request: c_int = 5;
const guest_agent_fuzz_grow_request: c_int = 6;
const guest_agent_fuzz_other_request: c_int = 7;

extern fn spore_agent_fuzz_build_request(request: [*]const u8, request_len: usize, stream: [*]const u8, stream_len: usize) c_int;
extern fn spore_agent_fuzz_exec_arg_equals(request: [*]const u8, request_len: usize, arg_index: usize, expected: [*]const u8, expected_len: usize) c_int;
extern fn spore_agent_fuzz_ext4_geometry(super: [*]const u8, super_len: usize, blocks_count: *u64, blocks_per_group: *u32, block_size: *u32) c_int;
extern fn spore_agent_fuzz_ext4_growth_source(super: [*]const u8, super_len: usize) c_int;
extern fn spore_agent_fuzz_rootfs_grow_geometry(target_blocks: u64, before_blocks: u64, before_blocks_per_group: u32, before_block_size: u32, after_blocks: u64, after_blocks_per_group: u32, after_block_size: u32) c_int;
extern fn spore_agent_fuzz_proc_stat(stat: [*]const u8, stat_len: usize) c_int;
extern fn spore_agent_fuzz_build_resolv_target(target: [*]const u8, target_len: usize, logical: [*]u8, logical_cap: usize) c_int;
extern fn spore_agent_test_bounded_readlink(target: [*]const u8, target_len: usize) c_int;
extern fn spore_build_copy_test_confined_source_parent(root: [*]const u8, root_len: usize, path: [*]const u8, path_len: usize) c_int;
extern fn spore_build_copy_test_confined_mtime(root: [*]const u8, root_len: usize, path: [*]const u8, path_len: usize, unix_seconds: i64) c_int;
extern fn spore_build_copy_fuzz_tree(source_root: [*]const u8, source_root_len: usize, dest_root: [*]const u8, dest_root_len: usize, fuzz: [*]const u8, fuzz_len: usize) c_int;
extern fn spore_build_copy_test_fd_budget() u64;
extern fn spore_build_copy_test_security_xattr_long_name(root: [*]const u8, root_len: usize) c_int;
extern fn spore_build_copy_test_security_xattr_policy(regular_source: c_int, existing_destination: c_int, name: [*]const u8, name_len: usize) c_int;

fn fuzzGuestBuildRequest(_: void, s: *std.testing.Smith) !void {
    if (comptime guest_agent_fuzz_supported) {
        var fuzz_bytes: [128]u8 = undefined;
        const fuzz_len = s.slice(&fuzz_bytes);
        const mode = if (fuzz_len == 0) 0 else fuzz_bytes[0] % 9;
        const command = if (fuzz_len <= 1) "x" else fuzz_bytes[1..fuzz_len];
        var stream: [256]u8 = undefined;
        var stream_len: usize = 0;

        if (mode == 4) {
            const link = fuzz_len > 1 and (fuzz_bytes[1] & 1) != 0;
            const request = copyRequest(std.testing.allocator, "spore-build-fuzz", .{
                .source = "input",
                .dest = "/output",
                .source_kind = if (link) .auto else .file,
                .dest_is_dir = false,
                .entry_count = if (link) 0 else 1,
                .source_disk = if (link) .build_input else .context,
                .destination_policy = if (link) .link else .follow,
            }) catch return;
            defer std.testing.allocator.free(request);
            _ = spore_agent_fuzz_build_request(request.ptr, request.len, stream[0..0].ptr, 0);
            return;
        }

        if (mode == 2) {
            const request = "{\"type\":\"spore-build-run-v1\",\"command_len\":65537}\n";
            _ = spore_agent_fuzz_build_request(request.ptr, request.len, stream[0..0].ptr, 0);
            return;
        }

        if (mode == 5) {
            const request = if (fuzz_len <= 1) fuzz_bytes[0..0] else fuzz_bytes[1..fuzz_len];
            _ = spore_agent_fuzz_build_request(request.ptr, request.len, stream[0..0].ptr, 0);
            return;
        }

        if (mode == 6) {
            const request = workdirRequest(std.testing.allocator, "spore-build-fuzz", "/work") catch return;
            defer std.testing.allocator.free(request);
            _ = spore_agent_fuzz_build_request(request.ptr, request.len, stream[0..0].ptr, 0);
            return;
        }

        if (mode == 7) {
            const request = copyRequest(std.testing.allocator, "spore-build-fuzz", .{
                .source = "out/app",
                .dest = "/app",
                .source_kind = .auto,
                .dest_is_dir = false,
                .entry_count = 0,
                .source_disk = .build_input,
                .input_index = 1,
            }) catch return;
            defer std.testing.allocator.free(request);
            _ = spore_agent_fuzz_build_request(request.ptr, request.len, stream[0..0].ptr, 0);
            return;
        }

        if (mode == 8) {
            const request = runRequest(std.testing.allocator, "spore-build-fuzz", .{ .exec = &.{ "printf", "%s", command } }, &.{"PATH=/usr/bin"}, "/", default_build_nofile, std.testing.io) catch return;
            defer std.testing.allocator.free(request);
            _ = spore_agent_fuzz_build_request(request.ptr, request.len, stream[0..0].ptr, 0);
            return;
        }

        const request = runRequest(std.testing.allocator, "spore-build-fuzz", .{ .shell = command }, &.{}, "/", default_build_nofile, std.testing.io) catch return;
        defer std.testing.allocator.free(request);
        appendTestSpioFrame(&stream, &stream_len, 1, if (mode == 1) 1 else 0, command);
        if (mode != 3) appendTestSpioFrame(&stream, &stream_len, 2, command.len, "");
        _ = spore_agent_fuzz_build_request(request.ptr, request.len, stream[0..stream_len].ptr, stream_len);
    }
}

test "build agent fd budget covers every bounded hardlink authority" {
    if (comptime guest_agent_fuzz_supported) {
        try std.testing.expectEqual(@as(u64, max_copy_entries + 256), spore_build_copy_test_fd_budget());
    }
}

test "build COPY engine confines source parent resolution" {
    if (comptime guest_agent_fuzz_supported) {
        const io = std.testing.io;
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "root/safe");
        try tmp.dir.createDirPath(io, "outside");
        try tmp.dir.writeFile(io, .{ .sub_path = "root/safe/inside", .data = "inside" });
        try tmp.dir.writeFile(io, .{ .sub_path = "outside/secret", .data = "secret" });
        try tmp.dir.symLink(io, "../../outside", "root/safe/escape", .{});
        const root = try tmp.dir.realPathFileAlloc(io, "root", allocator);
        defer allocator.free(root);

        try std.testing.expectEqual(
            @as(c_int, 0),
            spore_build_copy_test_confined_source_parent(root.ptr, root.len, "safe/inside".ptr, "safe/inside".len),
        );
        try std.testing.expectEqual(
            @as(c_int, -1),
            spore_build_copy_test_confined_source_parent(root.ptr, root.len, "safe/escape/secret".ptr, "safe/escape/secret".len),
        );
    }
}

test "build COPY engine applies remote mtime through a confined final symlink" {
    if (comptime guest_agent_fuzz_supported) {
        const io = std.testing.io;
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "root/inside");
        try tmp.dir.writeFile(io, .{ .sub_path = "root/inside/target", .data = "payload" });
        try tmp.dir.symLink(io, "inside/target", "root/link", .{});
        const root = try tmp.dir.realPathFileAlloc(io, "root", allocator);
        defer allocator.free(root);

        const expected: i64 = 1_700_000_000;
        try std.testing.expectEqual(@as(c_int, 0), spore_build_copy_test_confined_mtime(root.ptr, root.len, "/link".ptr, "/link".len, expected));
        const target = try tmp.dir.statFile(io, "root/inside/target", .{ .follow_symlinks = false });
        try std.testing.expectEqual(expected * std.time.ns_per_s, target.mtime.nanoseconds);
    }
}

test "security xattr inspection accepts an ext4 maximum-length clean name" {
    if (comptime guest_agent_fuzz_supported) {
        const io = std.testing.io;
        const tmp = "zig-cache/test-copy-security-long-name";
        Io.Dir.cwd().deleteTree(io, tmp) catch {};
        defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
        try Io.Dir.cwd().createDirPath(io, tmp);
        try std.testing.expectEqual(@as(c_int, 0), spore_build_copy_test_security_xattr_long_name(tmp.ptr, tmp.len));
    }
}

test "COPY security xattr policy is regular-file capability only" {
    if (comptime guest_agent_fuzz_supported) {
        const cases = [_]struct {
            regular_source: c_int,
            existing_destination: c_int,
            name: []const u8,
            accepted: bool,
        }{
            .{ .regular_source = 1, .existing_destination = 0, .name = "security.capability", .accepted = true },
            .{ .regular_source = 1, .existing_destination = 0, .name = "security.ima", .accepted = false },
            .{ .regular_source = 0, .existing_destination = 0, .name = "security.capability", .accepted = false },
            .{ .regular_source = 0, .existing_destination = 0, .name = "security.selinux", .accepted = false },
            .{ .regular_source = 1, .existing_destination = 1, .name = "security.capability", .accepted = false },
            .{ .regular_source = 0, .existing_destination = 1, .name = "security.capability", .accepted = false },
            .{ .regular_source = 0, .existing_destination = 1, .name = "user.visible", .accepted = true },
        };
        for (cases) |case| {
            const result = spore_build_copy_test_security_xattr_policy(
                case.regular_source,
                case.existing_destination,
                case.name.ptr,
                case.name.len,
            );
            try std.testing.expectEqual(case.accepted, result == 0);
        }
    }
}

fn fuzzGuestProcStat(_: void, s: *std.testing.Smith) !void {
    if (comptime guest_agent_fuzz_supported) {
        var bytes: [256]u8 = undefined;
        const len = s.slice(&bytes);
        _ = spore_agent_fuzz_proc_stat(bytes[0..len].ptr, len);
    }
}

fn fuzzGuestBuildResolvTarget(_: void, s: *std.testing.Smith) !void {
    if (comptime guest_agent_fuzz_supported) {
        var target: [512]u8 = undefined;
        const len = s.slice(&target);
        var logical: [512]u8 = undefined;
        _ = spore_agent_fuzz_build_resolv_target(target[0..len].ptr, len, &logical, logical.len);
    }
}

fn fuzzGuestCopyTree(_: void, s: *std.testing.Smith) !void {
    if (comptime guest_agent_fuzz_supported) {
        const io = std.testing.io;
        const tmp = "zig-cache/fuzz-guest-copy-tree";
        const source = tmp ++ "/source";
        const dest = tmp ++ "/dest";
        Io.Dir.cwd().deleteTree(io, tmp) catch {};
        defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
        try Io.Dir.cwd().createDirPath(io, source);
        try Io.Dir.cwd().createDirPath(io, dest);
        var bytes: [256]u8 = undefined;
        const len = s.slice(&bytes);
        _ = spore_build_copy_fuzz_tree(source.ptr, source.len, dest.ptr, dest.len, bytes[0..len].ptr, len);
    }
}

fn appendTestSpioFrame(out: []u8, cursor: *usize, frame_type: u8, offset: u64, payload: []const u8) void {
    var header: [24]u8 = @splat(0);
    @memcpy(header[0..4], "SPIO");
    header[4] = 1;
    header[5] = frame_type;
    std.mem.writeInt(u32, header[8..12], 1, .little);
    std.mem.writeInt(u64, header[12..20], offset, .little);
    std.mem.writeInt(u32, header[20..24], @intCast(payload.len), .little);
    std.debug.assert(cursor.* + header.len + payload.len <= out.len);
    @memcpy(out[cursor.*..][0..header.len], &header);
    cursor.* += header.len;
    @memcpy(out[cursor.*..][0..payload.len], payload);
    cursor.* += payload.len;
}

test "build fsfreeze request stays bounded" {
    const request = try run_mod.simpleControlRequest(std.testing.allocator, "fsfreeze-v1", "spore-build-freeze-1");
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.endsWith(u8, request, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, request, "\"fsfreeze-v1\"") != null);
}

test "build rootfs grow request stays bounded" {
    const request = try run_mod.simpleControlRequest(std.testing.allocator, "spore-rootfs-grow-v1", "spore-build-resize");
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.endsWith(u8, request, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, request, "\"spore-rootfs-grow-v1\"") != null);
    if (comptime guest_agent_fuzz_supported) {
        try std.testing.expectEqual(guest_agent_fuzz_grow_request, spore_agent_fuzz_build_request(request.ptr, request.len, request[0..0].ptr, 0));
        const reversed = " { \"session_id\" : \"spore-build-resize\", \"type\" : \"spore-rootfs-grow-v1\" } \n";
        try std.testing.expectEqual(guest_agent_fuzz_grow_request, spore_agent_fuzz_build_request(reversed.ptr, reversed.len, reversed[0..0].ptr, 0));

        const invalid = [_][]const u8{
            "{\"type\":\"spore-rootfs-grow-v1\"}\n",
            "{\"type\":\"spore-rootfs-grow-v1\",\"session_id\":\"a\"}",
            "{\"type\":\"spore-rootfs-grow-v1\",\"session_id\":\"\"}\n",
            "{\"type\":\"spore-rootfs-grow-v1\",\"session_id\":1}\n",
            "{\"type\":\"spore-rootfs-grow-v1\",\"type\":\"spore-rootfs-grow-v1\"}\n",
            "{\"type\":\"spore-rootfs-grow-v1\",\"session_id\":\"a\",\"session_id\":\"b\"}\n",
            "{\"type\":\"spore-rootfs-grow-v1\",\"session_id\":\"a\",\"capacity\":1}\n",
            "{\"type\":\"spore-rootfs-grow-v1\",\"session_id\":\"a\",\"stdout_offset\":0}\n",
            "{\"type\":\"spore-rootfs-grow-v1\",\"session_id\":\"a\"} trailing\n",
            "{\"type\":\"spore-rootfs-grow-v1\",\"session_id\":\"" ++ ("a" ** 64) ++ "\"}\n",
            "{\"type\":\"spore-rootfs-grow-v1\",\"session_id\":\"a\"}\x00extra\n",
        };
        for (invalid) |raw| {
            try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(raw.ptr, raw.len, raw[0..0].ptr, 0));
        }
        const max_session = "{\"type\":\"spore-rootfs-grow-v1\",\"session_id\":\"" ++ ("a" ** 63) ++ "\"}\n";
        try std.testing.expectEqual(guest_agent_fuzz_grow_request, spore_agent_fuzz_build_request(max_session.ptr, max_session.len, max_session[0..0].ptr, 0));
    }
}

test "rootfs grow response is exact and geometry-bound" {
    const valid = "spore-rootfs-grow-v1 device_bytes=10737418240 block_size=4096 target_blocks=2621440 before_blocks=131072 filesystem_blocks=2621440 blocks_per_group=32768 usable_blocks=2580000 free_bytes=8589934592 inodes=655360 free_inodes=650000\n";
    const parsed = try parseRootfsGrowResponse(valid);
    try std.testing.expectEqual(@as(u64, 10 * 1024 * 1024 * 1024), parsed.device_bytes);
    try std.testing.expectEqual(@as(u64, 4096), parsed.block_size);
    try std.testing.expectEqual(@as(u64, 131072), parsed.before_blocks);
    try std.testing.expectEqual(parsed.target_blocks, parsed.filesystem_blocks);
    try std.testing.expectEqual(@as(u32, 32768), parsed.blocks_per_group);
    try std.testing.expectError(error.BadRootfsGrowResponse, parseRootfsGrowResponse(valid[0 .. valid.len - 1]));

    const legal_shortfall = "spore-rootfs-grow-v1 device_bytes=409600 block_size=4096 target_blocks=100 before_blocks=40 filesystem_blocks=69 blocks_per_group=32 usable_blocks=60 free_bytes=0 inodes=1 free_inodes=1\n";
    _ = try parseRootfsGrowResponse(legal_shortfall);
    try std.testing.expectError(
        error.BadRootfsGrowResponse,
        parseRootfsGrowResponse("spore-rootfs-grow-v1 device_bytes=409600 block_size=4096 target_blocks=100 before_blocks=69 filesystem_blocks=69 blocks_per_group=32 usable_blocks=60 free_bytes=0 inodes=1 free_inodes=1\n"),
    );
    try std.testing.expectError(
        error.BadRootfsGrowResponse,
        parseRootfsGrowResponse("spore-rootfs-grow-v1 device_bytes=409600 block_size=4096 target_blocks=100 before_blocks=100 filesystem_blocks=100 blocks_per_group=32 usable_blocks=60 free_bytes=0 inodes=1 free_inodes=1\n"),
    );
    try std.testing.expectError(
        error.BadRootfsGrowResponse,
        parseRootfsGrowResponse("spore-rootfs-grow-v1 device_bytes=409600 block_size=4096 target_blocks=100 before_blocks=40 filesystem_blocks=101 blocks_per_group=32 usable_blocks=60 free_bytes=0 inodes=1 free_inodes=1\n"),
    );
    try std.testing.expectError(
        error.BadRootfsGrowResponse,
        parseRootfsGrowResponse("spore-rootfs-grow-v1 device_bytes=409600 block_size=4096 target_blocks=100 before_blocks=40 filesystem_blocks=68 blocks_per_group=32 usable_blocks=60 free_bytes=0 inodes=1 free_inodes=1\n"),
    );
    try std.testing.expectError(
        error.BadRootfsGrowResponse,
        parseRootfsGrowResponse("spore-rootfs-grow-v1 device_bytes=409600 block_size=4096 target_blocks=100 before_blocks=40 filesystem_blocks=69 blocks_per_group=32 usable_blocks=70 free_bytes=0 inodes=1 free_inodes=1\n"),
    );
    try std.testing.expectError(
        error.BadRootfsGrowResponse,
        parseRootfsGrowResponse("spore-rootfs-grow-v1 device_bytes=409600 block_size=4096 target_blocks=100 filesystem_blocks=69 before_blocks=40 blocks_per_group=32 usable_blocks=60 free_bytes=0 inodes=1 free_inodes=1\n"),
    );
    try std.testing.expectError(
        error.BadRootfsGrowResponse,
        parseRootfsGrowResponse("spore-rootfs-grow-v1 device_bytes=409600 block_size=4096 target_blocks=100 before_blocks=40 filesystem_blocks=69 blocks_per_group=4294967296 usable_blocks=60 free_bytes=0 inodes=1 free_inodes=1\n"),
    );
    try std.testing.expectError(
        error.BadRootfsGrowResponse,
        parseRootfsGrowResponse("spore-rootfs-grow-v1 device_bytes=409600 block_size=4096 target_blocks=100 before_blocks=40 filesystem_blocks=69 blocks_per_group=32 usable_blocks=60 free_bytes=249856 inodes=1 free_inodes=1\n"),
    );
    try std.testing.expectError(
        error.BadRootfsGrowResponse,
        parseRootfsGrowResponse("spore-rootfs-grow-v1 device_bytes=409600 block_size=4096 target_blocks=100 before_blocks=40 filesystem_blocks=69 blocks_per_group=32 usable_blocks=60 free_bytes=1 inodes=1 free_inodes=1\n"),
    );
    try std.testing.expectError(
        error.BadRootfsGrowResponse,
        parseRootfsGrowResponse("spore-rootfs-grow-v1 device_bytes=409600 block_size=4096 target_blocks=100 before_blocks=40 filesystem_blocks=69 blocks_per_group=32 usable_blocks=60 free_bytes=0 inodes=0 free_inodes=0\n"),
    );
}

test "guest ext4 superblock and resize geometry validation is feature-aware" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;

    var super: [1024]u8 = @splat(0);
    std.mem.writeInt(u32, super[0x04..0x08], 1234, .little);
    std.mem.writeInt(u32, super[0x18..0x1c], 2, .little);
    std.mem.writeInt(u32, super[0x20..0x24], 32768, .little);
    std.mem.writeInt(u16, super[0x38..0x3a], 0xef53, .little);
    std.mem.writeInt(u32, super[0x150..0x154], 1, .little);

    var blocks_count: u64 = 0;
    var blocks_per_group: u32 = 0;
    var block_size: u32 = 0;
    try std.testing.expectEqual(@as(c_int, 1), spore_agent_fuzz_ext4_geometry(&super, super.len, &blocks_count, &blocks_per_group, &block_size));
    try std.testing.expectEqual(@as(u64, 1234), blocks_count);
    try std.testing.expectEqual(@as(u32, 32768), blocks_per_group);
    try std.testing.expectEqual(@as(u32, 4096), block_size);
    // A frozen journal-less checkpoint is consistent but need not carry the
    // clean-unmount bit, so both state values are accepted by the preflight.
    try std.testing.expectEqual(@as(c_int, 1), spore_agent_fuzz_ext4_growth_source(&super, super.len));
    std.mem.writeInt(u16, super[0x3a..0x3c], 0x0001, .little);
    try std.testing.expectEqual(@as(c_int, 1), spore_agent_fuzz_ext4_growth_source(&super, super.len));

    std.mem.writeInt(u32, super[0x5c..0x60], 0x0004, .little);
    try std.testing.expectEqual(@as(c_int, 0), spore_agent_fuzz_ext4_growth_source(&super, super.len));
    std.mem.writeInt(u32, super[0x5c..0x60], 0, .little);

    std.mem.writeInt(u32, super[0x60..0x64], 0x0004, .little);
    try std.testing.expectEqual(@as(c_int, 0), spore_agent_fuzz_ext4_growth_source(&super, super.len));
    std.mem.writeInt(u32, super[0x60..0x64], 0x0008, .little);
    try std.testing.expectEqual(@as(c_int, 0), spore_agent_fuzz_ext4_growth_source(&super, super.len));
    std.mem.writeInt(u32, super[0x60..0x64], 0, .little);

    std.mem.writeInt(u16, super[0x3a..0x3c], 0x0002, .little);
    try std.testing.expectEqual(@as(c_int, 0), spore_agent_fuzz_ext4_growth_source(&super, super.len));
    std.mem.writeInt(u16, super[0x3a..0x3c], 0x0004, .little);
    try std.testing.expectEqual(@as(c_int, 0), spore_agent_fuzz_ext4_growth_source(&super, super.len));
    std.mem.writeInt(u16, super[0x3a..0x3c], 0, .little);

    std.mem.writeInt(u32, super[0xe8..0xec], 1, .little);
    try std.testing.expectEqual(@as(c_int, 0), spore_agent_fuzz_ext4_growth_source(&super, super.len));
    std.mem.writeInt(u32, super[0xe8..0xec], 0, .little);
    std.mem.writeInt(u32, super[0x64..0x68], 0x00010000, .little);
    try std.testing.expectEqual(@as(c_int, 0), spore_agent_fuzz_ext4_growth_source(&super, super.len));
    std.mem.writeInt(u32, super[0x64..0x68], 0, .little);

    std.mem.writeInt(u32, super[0x60..0x64], 0x80, .little);
    try std.testing.expectEqual(@as(c_int, 1), spore_agent_fuzz_ext4_geometry(&super, super.len, &blocks_count, &blocks_per_group, &block_size));
    try std.testing.expectEqual((@as(u64, 1) << 32) | 1234, blocks_count);

    try std.testing.expectEqual(@as(c_int, 1), spore_agent_fuzz_rootfs_grow_geometry(100, 40, 32, 4096, 100, 32, 4096));
    try std.testing.expectEqual(@as(c_int, 1), spore_agent_fuzz_rootfs_grow_geometry(100, 40, 32, 4096, 69, 32, 4096));
    try std.testing.expectEqual(@as(c_int, 0), spore_agent_fuzz_rootfs_grow_geometry(100, 40, 32, 4096, 40, 32, 4096));
    try std.testing.expectEqual(@as(c_int, 0), spore_agent_fuzz_rootfs_grow_geometry(100, 100, 32, 4096, 100, 32, 4096));
    try std.testing.expectEqual(@as(c_int, 0), spore_agent_fuzz_rootfs_grow_geometry(100, 40, 32, 4096, 101, 32, 4096));
    try std.testing.expectEqual(@as(c_int, 0), spore_agent_fuzz_rootfs_grow_geometry(100, 40, 32, 4096, 68, 32, 4096));
    try std.testing.expectEqual(@as(c_int, 0), spore_agent_fuzz_rootfs_grow_geometry(100, 40, 32, 4096, 100, 64, 4096));
    try std.testing.expectEqual(@as(c_int, 0), spore_agent_fuzz_rootfs_grow_geometry(100, 40, 32, 4096, 100, 32, 1024));

    std.mem.writeInt(u16, super[0x38..0x3a], 0, .little);
    try std.testing.expectEqual(@as(c_int, 0), spore_agent_fuzz_ext4_geometry(&super, super.len, &blocks_count, &blocks_per_group, &block_size));
    std.mem.writeInt(u16, super[0x38..0x3a], 0xef53, .little);
    std.mem.writeInt(u32, super[0x20..0x24], 0, .little);
    try std.testing.expectEqual(@as(c_int, 0), spore_agent_fuzz_ext4_geometry(&super, super.len, &blocks_count, &blocks_per_group, &block_size));
    std.mem.writeInt(u32, super[0x20..0x24], 32768, .little);
    std.mem.writeInt(u32, super[0x18..0x1c], 7, .little);
    try std.testing.expectEqual(@as(c_int, 0), spore_agent_fuzz_ext4_geometry(&super, super.len, &blocks_count, &blocks_per_group, &block_size));
}

fn fuzzRootfsGrowResponse(_: void, smith: *std.testing.Smith) !void {
    var storage: [max_rootfs_grow_response + 1]u8 = undefined;
    const bytes = storage[0..smith.slice(&storage)];
    const parsed = parseRootfsGrowResponse(bytes) catch return;
    try std.testing.expect(parsed.device_bytes != 0);
    try std.testing.expect(parsed.block_size != 0);
    try std.testing.expectEqual(@as(u64, 0), parsed.device_bytes % parsed.block_size);
    try std.testing.expectEqual(parsed.device_bytes / parsed.block_size, parsed.target_blocks);
    try std.testing.expect(parsed.before_blocks < parsed.filesystem_blocks);
    try std.testing.expect(parsed.filesystem_blocks <= parsed.target_blocks);
    try std.testing.expect(parsed.target_blocks - parsed.filesystem_blocks < parsed.blocks_per_group);
    try std.testing.expect(parsed.usable_blocks <= parsed.filesystem_blocks);
    try std.testing.expect(parsed.free_inodes <= parsed.inodes);
}

fn fuzzGuestExt4Geometry(_: void, smith: *std.testing.Smith) !void {
    if (comptime !guest_agent_fuzz_supported) return;
    var storage: [1024]u8 = undefined;
    const bytes = storage[0..smith.slice(&storage)];
    var blocks_count: u64 = 0;
    var blocks_per_group: u32 = 0;
    var block_size: u32 = 0;
    if (spore_agent_fuzz_ext4_geometry(bytes.ptr, bytes.len, &blocks_count, &blocks_per_group, &block_size) == 0) return;
    try std.testing.expect(blocks_count != 0);
    try std.testing.expect(blocks_per_group != 0);
    try std.testing.expect(block_size >= 1024 and block_size <= 65536 and std.math.isPowerOfTwo(block_size));
}

fn fuzzGuestExt4GrowthSource(_: void, smith: *std.testing.Smith) !void {
    if (comptime !guest_agent_fuzz_supported) return;
    var storage: [1024]u8 = undefined;
    const bytes = storage[0..smith.slice(&storage)];
    const accepted = spore_agent_fuzz_ext4_growth_source(bytes.ptr, bytes.len);
    try std.testing.expect(accepted == 0 or accepted == 1);
    if (accepted == 0) return;
    var blocks_count: u64 = 0;
    var blocks_per_group: u32 = 0;
    var block_size: u32 = 0;
    try std.testing.expectEqual(@as(c_int, 1), spore_agent_fuzz_ext4_geometry(bytes.ptr, bytes.len, &blocks_count, &blocks_per_group, &block_size));
}

test "fuzz rootfs grow response parser" {
    try std.testing.fuzz({}, fuzzRootfsGrowResponse, .{});
}

test "fuzz guest ext4 geometry parser" {
    try std.testing.fuzz({}, fuzzGuestExt4Geometry, .{});
}

test "fuzz guest ext4 growth source preflight" {
    try std.testing.fuzz({}, fuzzGuestExt4GrowthSource, .{});
}

test "P0 idle probe is bounded and rejects background block writes" {
    try std.testing.expectEqual(@as(u64, 0), try parseP0IdleProbeMs(null));
    try std.testing.expectEqual(@as(u64, 6000), try parseP0IdleProbeMs("6000"));
    try std.testing.expectError(error.BadP0IdleProbe, parseP0IdleProbeMs("10001"));

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put(p0_idle_probe_env, "6000");
    try std.testing.expectEqual(@as(u64, 0), try p0IdleProbeMs(&env));
    try env.put(run_mod.rootfs_growth_experiments_env, "1");
    try std.testing.expectEqual(@as(u64, 6000), try p0IdleProbeMs(&env));

    const baseline = vsock.ControlStats{
        .write_zeroes_requests = 3,
        .write_zeroes_bytes = 4096,
        .write_zeroes_errors = 0,
        .write_zeroes_backend_failures = 0,
        .write_zeroes_unsupported = 0,
        .out_requests = 7,
        .out_bytes = 8192,
    };
    try validateIdleBlockStats(baseline, baseline);
    var changed = baseline;
    changed.out_requests.? += 1;
    try std.testing.expectError(error.RootfsBackgroundWritesDetected, validateIdleBlockStats(baseline, changed));
    try std.testing.expectError(error.MissingP0BlockStats, validateIdleBlockStats(.{}, baseline));
}

test "checkpoint controls use step-specific vsock identities" {
    const allocator = std.testing.allocator;
    const freeze_one = try checkpointSessionId(allocator, .freeze, .dockerfile_step, 0);
    defer allocator.free(freeze_one);
    const freeze_two = try checkpointSessionId(allocator, .freeze, .dockerfile_step, 1);
    defer allocator.free(freeze_two);
    const thaw_one = try checkpointSessionId(allocator, .thaw, .dockerfile_step, 0);
    defer allocator.free(thaw_one);
    const thaw_two = try checkpointSessionId(allocator, .thaw, .dockerfile_step, 1);
    defer allocator.free(thaw_two);

    try std.testing.expectEqualStrings("spore-build-freeze-1", freeze_one);
    try std.testing.expectEqualStrings("spore-build-thaw-2", thaw_two);
    const prepare_freeze = try checkpointSessionId(allocator, .freeze, .prepare, 0);
    defer allocator.free(prepare_freeze);
    const prepare_thaw = try checkpointSessionId(allocator, .thaw, .prepare, 0);
    defer allocator.free(prepare_thaw);
    try std.testing.expectEqualStrings("spore-build-prepare-freeze", prepare_freeze);
    try std.testing.expectEqualStrings("spore-build-prepare-thaw", prepare_thaw);
}

test "instruction timeout accounting resets between Dockerfile steps" {
    var timing: InstructionTiming = .{};
    timing.record(1_200);
    try std.testing.expectEqual(@as(u64, 1_900), timing.elapsedWithActive(700));
    timing.finishStep();
    try std.testing.expectEqual(@as(u64, 700), timing.elapsedWithActive(700));
    try std.testing.expectEqual(@as(u64, 1_200), timing.total_ms);
}

test "preparation metric line preserves authoritative publication and total fields" {
    var buf: [256]u8 = undefined;
    const line = try preparationMetricsLine(&buf, 217, 219, 16_384, 31);
    try std.testing.expectEqualStrings(
        "rootfs preparation metrics: publish_ms=217 resume_ms=219 target_mib=16384 checkpoint_control_max_ms=31",
        line,
    );
}

test "build session network mode derives from RUN steps" {
    const copy = Step{ .copy = .{
        .canonical_instruction = "COPY . /app",
        .input_digest = "blake3:copy",
        .env_digest = "blake3:env",
        .workdir = "/",
        .requests = &.{},
    } };
    const spore_run = Step{ .run = .{
        .canonical_instruction = "RUN fetch",
        .command = .{ .shell = "fetch" },
        .env = &.{},
        .env_digest = "blake3:env",
        .workdir = "/",
        .network_mode = .spore,
    } };
    var none_run = spore_run;
    none_run.run.network_mode = .none;

    try std.testing.expectEqual(step_cache.NetworkMode.none, try networkModeForSteps(&.{copy}));
    try std.testing.expectEqual(step_cache.NetworkMode.spore, try networkModeForSteps(&.{ copy, spore_run }));
    try std.testing.expectError(error.BuildNetworkModeMismatch, networkModeForSteps(&.{ spore_run, none_run }));
}

test "build session forwards the selected spore executable to the monitor" {
    const executable = "/opt/sporevm/exact-build/spore";
    const options = Options{
        .platform = .{},
        .cache_root = "/cache",
        .base_storage = undefined,
        .steps = &.{},
        .rootfs_cache_lock = undefined,
        .producer = undefined,
        .spore_executable = executable,
    };
    const rootfs = spore.Rootfs{
        .device = .{ .mmio_slot = 1 },
        .artifact = .{ .digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .size = 4096 },
    };
    const monitor_options = monitorOptionsForSession(options, rootfs, .spore, null);
    try std.testing.expectEqualStrings(executable, monitor_options.spore_executable);
    try std.testing.expectEqual(run_mod.NetworkMode.spore, monitor_options.network);
}

test "build copy request names context disk source" {
    const request = try copyRequest(std.testing.allocator, "spore-build-1", .{
        .source = "src",
        .dest = "/work",
        .source_kind = .directory,
        .dest_is_dir = true,
        .entry_count = 2,
    });
    defer std.testing.allocator.free(request);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, request, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("spore-build-copy-v4", object.get("type").?.string);
    try std.testing.expectEqualStrings("src", object.get("source").?.string);
    try std.testing.expectEqualStrings("/work", object.get("dest").?.string);
    try std.testing.expectEqualStrings("directory", object.get("source_kind").?.string);
    try std.testing.expectEqual(@as(i64, 2), object.get("entry_count").?.integer);
    try std.testing.expectEqualStrings("context", object.get("source_disk").?.string);
    try std.testing.expect(object.get("mtime_unix_seconds").? == .null);
}

test "build copy request carries a remote Last-Modified timestamp" {
    const request = try copyRequest(std.testing.allocator, "spore-build-1", .{
        .source = "asset.gz",
        .dest = "/tmp/asset.gz",
        .source_kind = .file,
        .dest_is_dir = false,
        .entry_count = 1,
        .mtime_unix_seconds = 1_772_839_831,
    });
    defer std.testing.allocator.free(request);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, request, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1_772_839_831), parsed.value.object.get("mtime_unix_seconds").?.integer);
}

test "build copy request accepts the root destination" {
    const request = try copyRequest(std.testing.allocator, "spore-build-1", .{
        .source = "asset.bin",
        .dest = "/",
        .source_kind = .file,
        .dest_is_dir = true,
        .entry_count = 1,
    });
    defer std.testing.allocator.free(request);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, request, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/", parsed.value.object.get("dest").?.string);
}

test "build copy v4 guest parser rejects incomplete or ambiguous framing" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;

    const valid = "{\"type\":\"spore-build-copy-v4\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"file\",\"dest_is_dir\":false,\"entry_count\":1,\"source_disk\":\"context\",\"input_index\":0,\"mtime_unix_seconds\":null}\n";
    try std.testing.expectEqual(guest_agent_fuzz_copy_request, spore_agent_fuzz_build_request(valid.ptr, valid.len, valid[0..0].ptr, 0));

    const invalid = [_][]const u8{
        valid[0 .. valid.len - 1],
        valid[0 .. valid.len - 2] ++ ",}\n",
        valid[0 .. valid.len - 2] ++ " trailing\n",
        "{\"type\":\"spore-build-copy-v4\",\"type\":\"spore-build-copy-v4\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"file\",\"dest_is_dir\":false,\"entry_count\":1,\"source_disk\":\"context\",\"input_index\":0,\"mtime_unix_seconds\":null}\n",
        "{\"type\":\"spore-build-copy-v4\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"file\",\"dest_is_dir\":false,\"entry_count\":1,\"source_disk\":\"context\",\"input_index\":0,\"mtime_unix_seconds\":null,\"extra\":true}\n",
        "{\"type\":\"spore-build-copy-v4\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"file\",\"dest_is_dir\":false,\"entry_count\":1,\"source_disk\":\"context\",\"input_index\":0}\n",
        "{\"type\":\"spore-build-copy-v4\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"file\",\"dest_is_dir\":false,\"entry_count\":1,\"source_disk\":\"context\",\"input_index\":0,\"mtime_unix_seconds\":9223372036854775808}\n",
        "{\"type\":\"spore-build-copy-v4\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"file\",\"dest_is_dir\":false,\"entry_count\":1,\"source_disk\":\"context\",\"input_index\":0,\"mtime_unix_seconds\":-9223372036854775809}\n",
    };
    for (invalid) |request| {
        try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(request.ptr, request.len, request[0..0].ptr, 0));
    }
}

test "build copy request selects an immutable build input" {
    const request = try copyRequest(std.testing.allocator, "spore-build-1", .{
        .source = "out/app",
        .dest = "/app",
        .source_kind = .auto,
        .dest_is_dir = false,
        .entry_count = 0,
        .source_disk = .build_input,
        .input_index = 1,
    });
    defer std.testing.allocator.free(request);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, request, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("build_input", object.get("source_disk").?.string);
    try std.testing.expectEqual(@as(i64, 1), object.get("input_index").?.integer);
    try std.testing.expectEqualStrings("auto", object.get("source_kind").?.string);
}

test "build copy link request uses the strict v5 build-input contract" {
    const request = try copyRequest(std.testing.allocator, "spore-build-1", .{
        .source = "out/app",
        .dest = "/app",
        .source_kind = .auto,
        .dest_is_dir = false,
        .entry_count = 0,
        .source_disk = .build_input,
        .input_index = 1,
        .destination_policy = .link,
    });
    defer std.testing.allocator.free(request);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, request, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("spore-build-copy-v5", object.get("type").?.string);
    try std.testing.expectEqualStrings("link", object.get("destination_policy").?.string);

    try std.testing.expectError(error.CopySourceUnsupported, copyRequest(std.testing.allocator, "spore-build-1", .{
        .source = "input",
        .dest = "/output",
        .source_kind = .file,
        .dest_is_dir = false,
        .entry_count = 1,
        .destination_policy = .link,
    }));
}

test "build copy v5 guest parser rejects incomplete or ambiguous link policy" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;

    const valid = "{\"type\":\"spore-build-copy-v5\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"auto\",\"dest_is_dir\":false,\"entry_count\":0,\"source_disk\":\"build_input\",\"input_index\":0,\"mtime_unix_seconds\":null,\"destination_policy\":\"link\"}\n";
    try std.testing.expectEqual(guest_agent_fuzz_copy_request, spore_agent_fuzz_build_request(valid.ptr, valid.len, valid[0..0].ptr, 0));

    const invalid = [_][]const u8{
        valid[0 .. valid.len - 1],
        valid[0 .. valid.len - 2] ++ " trailing\n",
        "{\"type\":\"spore-build-copy-v5\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"auto\",\"dest_is_dir\":false,\"entry_count\":0,\"source_disk\":\"build_input\",\"input_index\":0,\"mtime_unix_seconds\":null}\n",
        "{\"type\":\"spore-build-copy-v5\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"auto\",\"dest_is_dir\":false,\"entry_count\":0,\"source_disk\":\"build_input\",\"input_index\":0,\"mtime_unix_seconds\":null,\"destination_policy\":\"follow\"}\n",
        "{\"type\":\"spore-build-copy-v5\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"auto\",\"dest_is_dir\":false,\"entry_count\":0,\"source_disk\":\"build_input\",\"input_index\":0,\"mtime_unix_seconds\":null,\"destination_policy\":\"link\",\"destination_policy\":\"link\"}\n",
        "{\"type\":\"spore-build-copy-v5\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"file\",\"dest_is_dir\":false,\"entry_count\":1,\"source_disk\":\"context\",\"input_index\":0,\"mtime_unix_seconds\":null,\"destination_policy\":\"link\"}\n",
        "{\"type\":\"spore-build-copy-v4\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"file\",\"dest_is_dir\":false,\"entry_count\":1,\"source_disk\":\"context\",\"input_index\":0,\"mtime_unix_seconds\":null,\"destination_policy\":\"link\"}\n",
    };
    for (invalid) |request| {
        try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(request.ptr, request.len, request[0..0].ptr, 0));
    }
}

test "build workdir request names an absolute target" {
    const request = try workdirRequest(std.testing.allocator, "spore-build-1", "/work/app");
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"spore-build-workdir-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"working_dir\":\"/work/app\"") != null);
    try std.testing.expectError(error.RunWorkingDirUnsupported, workdirRequest(std.testing.allocator, "spore-build-1", "relative"));
}

test "build copy request rejects path escapes" {
    try std.testing.expectError(error.CopySourceEscapesContext, copyRequest(std.testing.allocator, "spore-build-1", .{
        .source = "../secret",
        .dest = "/app/secret",
        .source_kind = .file,
        .dest_is_dir = false,
        .entry_count = 1,
    }));
    try std.testing.expectError(error.CopyDestinationUnsupported, copyRequest(std.testing.allocator, "spore-build-1", .{
        .source = "file",
        .dest = "/app/../secret",
        .source_kind = .file,
        .dest_is_dir = false,
        .entry_count = 1,
    }));
}

test "build copy request accepts exact path bound" {
    const allocator = std.testing.allocator;
    const path = try allocator.alloc(u8, max_copy_entry_path_len);
    defer allocator.free(path);
    path[0] = '/';
    @memset(path[1..], 'a');

    const request = try copyRequest(allocator, "spore-build-1", .{
        .source = "file",
        .dest = path,
        .source_kind = .file,
        .dest_is_dir = false,
        .entry_count = 1,
    });
    defer allocator.free(request);

    const too_long = try allocator.alloc(u8, max_copy_entry_path_len + 1);
    defer allocator.free(too_long);
    too_long[0] = '/';
    @memset(too_long[1..], 'b');
    try std.testing.expectError(error.CopyDestinationUnsupported, copyRequest(allocator, "spore-build-1", .{
        .source = "file",
        .dest = too_long,
        .source_kind = .file,
        .dest_is_dir = false,
        .entry_count = 1,
    }));
}

test "build run request uses spore stream v1 start" {
    const request = try runRequest(std.testing.allocator, "spore-build-1", .{ .shell = "echo ok" }, &.{"PATH=/usr/bin"}, "/work", default_build_nofile, std.testing.io);
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.endsWith(u8, request, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, request, "\"spore-build-run-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"stdio\":\"pipe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"command_len\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"nofile_soft\":65536") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"nofile_hard\":65536") != null);
}

fn rawExecRequestForTest(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    const payload = struct {
        type: []const u8 = "spore-build-run-v2",
        session_id: []const u8 = "spore-build-test",
        resume_time_unix_ns: u64 = 1,
        argv: []const []const u8,
        env: []const []const u8 = &.{},
        working_dir: []const u8 = "/",
        stdio: []const u8 = "pipe",
        term: []const u8 = "xterm",
        terminal_rows: u16 = 24,
        terminal_cols: u16 = 80,
        memory_pressure: bool = false,
        nofile_soft: u64 = 1,
        nofile_hard: u64 = 1,
        closed_env: bool = true,
    }{ .argv = argv };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

test "build exec-form RUN request carries exact bounded argv" {
    const request = try runRequest(
        std.testing.allocator,
        "spore-build-1",
        .{ .exec = &.{ "printf", "%s|%s", "two words", "", "$VALUE", "control\x01" } },
        &.{ "PATH=/usr/bin", "VALUE=expanded" },
        "/work",
        default_build_nofile,
        std.testing.io,
    );
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"spore-build-run-v2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"argv\":[\"printf\",\"%s|%s\",\"two words\",\"\",\"$VALUE\",\"control\\u0001\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "command_len") == null);
    if (comptime guest_agent_fuzz_supported) {
        try std.testing.expectEqual(guest_agent_fuzz_run_complete, spore_agent_fuzz_build_request(request.ptr, request.len, request[0..0].ptr, 0));
    }

    try std.testing.expectError(error.RunArgCountUnsupported, runRequest(std.testing.allocator, "spore-build-1", .{ .exec = &.{} }, &.{}, "/", default_build_nofile, std.testing.io));
    try std.testing.expectError(error.RunArgUnsupported, runRequest(std.testing.allocator, "spore-build-1", .{ .exec = &.{""} }, &.{}, "/", default_build_nofile, std.testing.io));

    const sixteen = [_][]const u8{"x"} ** max_run_exec_args;
    const max_count_request = try runRequest(std.testing.allocator, "spore-build-1", .{ .exec = &sixteen }, &.{}, "/", default_build_nofile, std.testing.io);
    defer std.testing.allocator.free(max_count_request);
    const seventeen = [_][]const u8{"x"} ** (max_run_exec_args + 1);
    try std.testing.expectError(error.RunArgCountUnsupported, runRequest(std.testing.allocator, "spore-build-1", .{ .exec = &seventeen }, &.{}, "/", default_build_nofile, std.testing.io));

    const max_bytes_request = try runRequest(std.testing.allocator, "spore-build-1", .{ .exec = &.{"x" ** max_run_exec_args_bytes} }, &.{}, "/", default_build_nofile, std.testing.io);
    defer std.testing.allocator.free(max_bytes_request);
    try std.testing.expectError(error.RunRequestTooLarge, runRequest(std.testing.allocator, "spore-build-1", .{ .exec = &.{"x" ** (max_run_exec_args_bytes + 1)} }, &.{}, "/", default_build_nofile, std.testing.io));

    if (comptime guest_agent_fuzz_supported) {
        try std.testing.expectEqual(guest_agent_fuzz_run_complete, spore_agent_fuzz_build_request(max_count_request.ptr, max_count_request.len, max_count_request[0..0].ptr, 0));
        try std.testing.expectEqual(guest_agent_fuzz_run_complete, spore_agent_fuzz_build_request(max_bytes_request.ptr, max_bytes_request.len, max_bytes_request[0..0].ptr, 0));
        const too_many_request = try rawExecRequestForTest(std.testing.allocator, &seventeen);
        defer std.testing.allocator.free(too_many_request);
        try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(too_many_request.ptr, too_many_request.len, too_many_request[0..0].ptr, 0));
        const too_large_request = try rawExecRequestForTest(std.testing.allocator, &.{"x" ** (max_run_exec_args_bytes + 1)});
        defer std.testing.allocator.free(too_large_request);
        try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(too_large_request.ptr, too_large_request.len, too_large_request[0..0].ptr, 0));
    }

    const escaped_controls = "\x01" ** 1366;
    try std.testing.expectError(error.RunRequestTooLarge, validateRunRequest(std.testing.allocator, .{ .exec = &.{ "printf", escaped_controls } }, &.{"PATH=/usr/bin"}, "/", default_build_nofile));
}

test "cache-mounted RUN uses strict v3 request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mounts = try cache_mount.resolve(arena, "/work", &.{ "/var/cache/apt", "relative" });
    const request = try runRequestWithMounts(
        std.testing.allocator,
        "spore-build-1",
        .{ .exec = &.{ "printf", "ok" } },
        &.{"PATH=/usr/bin"},
        "/work",
        default_build_nofile,
        mounts,
        std.testing.io,
    );
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"spore-build-run-v3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"command_len\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"target\":\"/var/cache/apt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"target\":\"/work/relative\"") != null);
    if (comptime guest_agent_fuzz_supported) {
        try std.testing.expectEqual(guest_agent_fuzz_run_complete, spore_agent_fuzz_build_request(request.ptr, request.len, request[0..0].ptr, 0));
        const malformed = [_][]const u8{
            request[0 .. request.len - 1],
            "{\"type\":\"spore-build-run-v3\"}\n",
            "{\"type\":\"spore-build-run-v3\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
            "{\"type\":\"spore-build-run-v3\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[{\"target\":\"/cache/../escape\",\"key\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
            "{\"type\":\"spore-build-run-v3\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[{\"target\":\"/cache\",\"key\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"}],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
            "{\"type\":\"spore-build-run-v3\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[{\"target\":\"/cache\",\"key\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"},{\"target\":\"/cache/nested\",\"key\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
        };
        for (malformed) |raw| {
            try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(raw.ptr, raw.len, raw[0..0].ptr, 0));
        }
    }
}

test "guest exec request parser preserves Unicode and rejects invalid scalar encodings" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const raw_utf8 = try rawExecRequestForTest(allocator, &.{"café"});
    defer allocator.free(raw_utf8);
    try std.testing.expectEqual(@as(c_int, 1), spore_agent_fuzz_exec_arg_equals(raw_utf8.ptr, raw_utf8.len, 0, "café", "café".len));

    const escaped_utf8 = try std.mem.replaceOwned(u8, allocator, raw_utf8, "café", "caf\\u00e9");
    defer allocator.free(escaped_utf8);
    try std.testing.expectEqual(@as(c_int, 1), spore_agent_fuzz_exec_arg_equals(escaped_utf8.ptr, escaped_utf8.len, 0, "café", "café".len));

    const raw_supplementary = try rawExecRequestForTest(allocator, &.{"😀"});
    defer allocator.free(raw_supplementary);
    const escaped_supplementary = try std.mem.replaceOwned(u8, allocator, raw_supplementary, "😀", "\\ud83d\\ude00");
    defer allocator.free(escaped_supplementary);
    try std.testing.expectEqual(@as(c_int, 1), spore_agent_fuzz_exec_arg_equals(escaped_supplementary.ptr, escaped_supplementary.len, 0, "😀", "😀".len));

    const nul_escape = try std.mem.replaceOwned(u8, allocator, raw_utf8, "café", "\\u0000");
    defer allocator.free(nul_escape);
    try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(nul_escape.ptr, nul_escape.len, nul_escape[0..0].ptr, 0));

    const invalid_utf8 = try std.mem.replaceOwned(u8, allocator, raw_utf8, "café", "\xff");
    defer allocator.free(invalid_utf8);
    try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(invalid_utf8.ptr, invalid_utf8.len, invalid_utf8[0..0].ptr, 0));

    const lone_high = try std.mem.replaceOwned(u8, allocator, raw_utf8, "café", "\\ud83d");
    defer allocator.free(lone_high);
    try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(lone_high.ptr, lone_high.len, lone_high[0..0].ptr, 0));

    const lone_low = try std.mem.replaceOwned(u8, allocator, raw_utf8, "café", "\\ude00");
    defer allocator.free(lone_low);
    try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(lone_low.ptr, lone_low.len, lone_low[0..0].ptr, 0));
}

test "build nofile limit is bounded" {
    try default_build_nofile.validate();
    try std.testing.expectError(error.InvalidBuildNofileLimit, (NofileLimit{ .soft = 0, .hard = 1 }).validate());
    try std.testing.expectError(error.InvalidBuildNofileLimit, (NofileLimit{ .soft = 2, .hard = 1 }).validate());
    try std.testing.expectError(error.InvalidBuildNofileLimit, (NofileLimit{ .soft = 1, .hard = max_build_nofile + 1 }).validate());
}

test "build RUN resources validate as one execution contract" {
    try (RunResources{}).validate();
    try std.testing.expectError(error.ZeroMemory, (RunResources{
        .memory = .{ .policy = .explicit, .bytes = 0 },
    }).validate());
    try std.testing.expectError(error.UnsupportedVcpuCount, (RunResources{ .vcpus = 0 }).validate());
    try std.testing.expectError(error.InvalidBuildNofileLimit, (RunResources{
        .nofile = .{ .soft = 2, .hard = 1 },
    }).validate());
}

test "build run request accepts multi-kib command and rejects configured bound" {
    const multi_kib = "x" ** 4096;
    const request = try runRequest(std.testing.allocator, "spore-build-1", .{ .shell = multi_kib }, &.{}, "/", default_build_nofile, std.testing.io);
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"command_len\":4096") != null);
    const command = "x" ** (max_run_command_len + 1);
    try std.testing.expectError(error.RunCommandTooLong, runRequest(std.testing.allocator, "spore-build-1", .{ .shell = command }, &.{}, "/", default_build_nofile, std.testing.io));
    const workdir = "/" ** (max_guest_working_dir_len + 1);
    try std.testing.expectError(error.RunWorkingDirUnsupported, runRequest(std.testing.allocator, "spore-build-1", .{ .shell = "true" }, &.{}, workdir, default_build_nofile, std.testing.io));
}

test "guest build request parser rejects malformed RUN framing and accepts build controls" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;

    const run_request = try runRequest(std.testing.allocator, "spore-build-1", .{ .shell = "abc" }, &.{}, "/", default_build_nofile, std.testing.io);
    defer std.testing.allocator.free(run_request);
    var stream: [128]u8 = undefined;
    var stream_len: usize = 0;
    appendTestSpioFrame(&stream, &stream_len, 1, 0, "abc");
    appendTestSpioFrame(&stream, &stream_len, 2, 3, "");
    try std.testing.expectEqual(guest_agent_fuzz_run_complete, spore_agent_fuzz_build_request(run_request.ptr, run_request.len, stream[0..stream_len].ptr, stream_len));

    stream_len = 0;
    appendTestSpioFrame(&stream, &stream_len, 1, 1, "abc");
    appendTestSpioFrame(&stream, &stream_len, 2, 3, "");
    try std.testing.expectEqual(guest_agent_fuzz_run_request, spore_agent_fuzz_build_request(run_request.ptr, run_request.len, stream[0..stream_len].ptr, stream_len));

    stream_len = 0;
    appendTestSpioFrame(&stream, &stream_len, 1, 0, "abc");
    try std.testing.expectEqual(guest_agent_fuzz_run_request, spore_agent_fuzz_build_request(run_request.ptr, run_request.len, stream[0..stream_len].ptr, stream_len));

    const over_limit = "{\"type\":\"spore-build-run-v1\",\"command_len\":65537}\n";
    try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(over_limit.ptr, over_limit.len, stream[0..0].ptr, 0));

    const empty_exec = try rawExecRequestForTest(std.testing.allocator, &.{});
    defer std.testing.allocator.free(empty_exec);
    try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(empty_exec.ptr, empty_exec.len, stream[0..0].ptr, 0));

    const reordered_exec = "{\"closed_env\":true,\"nofile_hard\":1,\"nofile_soft\":1,\"memory_pressure\":false,\"terminal_cols\":80,\"terminal_rows\":24,\"term\":\"xterm\",\"stdio\":\"pipe\",\"working_dir\":\"/\",\"env\":[],\"argv\":[\"true\"],\"resume_time_unix_ns\":1,\"session_id\":\"s\",\"type\":\"spore-build-run-v2\"}\n";
    try std.testing.expectEqual(guest_agent_fuzz_run_complete, spore_agent_fuzz_build_request(reordered_exec.ptr, reordered_exec.len, stream[0..0].ptr, 0));

    const malformed_exec_requests = [_][]const u8{
        "{\"type\":\"spore-build-run-v2\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
        "{\"type\":\"spore-build-run-v2\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"argv\":[\"true\",],\"env\":[],\"working_dir\":\"/\",\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
        "{\"type\":\"spore-build-run-v2\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true} trailing\n",
        "{\"type\":\"spore-build-run-v2\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"argv\":[\"true\"],\"argv\":[\"false\"],\"env\":[],\"working_dir\":\"/\",\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
        "{\"type\":\"spore-build-run-v2\",\"type\":\"spore-build-run-v2\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
        "{\"type\":\"spore-build-run-v2\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true,\"unknown\":0}\n",
        "{\"type\":\"spore-build-run-v2\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1}\n",
        "{\"type\":\"spore-build-run-v2\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,}\n",
        "{\"type\":\"spore-build-run-v2\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"argv\":[\"line\nbreak\"],\"env\":[],\"working_dir\":\"/\",\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
        "{\"type\":\"spore-build-run-v2\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"stdio\":\"tty\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
        "{\"type\":\"spore-build-run-v2\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":01,\"nofile_hard\":1,\"closed_env\":true}\n",
        "{\"type\":\"start\",\"type\":\"spore-build-run-v2\",\"argv\":[\"/bin/true\"]}\n",
        "{\"type\":\"spore-build-run-v2\",\"type\":\"start\",\"argv\":[\"/bin/true\"]}\n",
    };
    for (malformed_exec_requests) |malformed| {
        try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(malformed.ptr, malformed.len, stream[0..0].ptr, 0));
    }

    const missing_newline = reordered_exec[0 .. reordered_exec.len - 1];
    try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(missing_newline.ptr, missing_newline.len, stream[0..0].ptr, 0));

    const exactly_full = try std.testing.allocator.alloc(u8, max_guest_request_len);
    defer std.testing.allocator.free(exactly_full);
    @memcpy(exactly_full[0..missing_newline.len], missing_newline);
    @memset(exactly_full[missing_newline.len..], ' ');
    try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(exactly_full.ptr, exactly_full.len, stream[0..0].ptr, 0));

    const escaped_type_key = "{\"\\u0074ype\":\"spore-build-run-v2\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n";
    try std.testing.expectEqual(guest_agent_fuzz_run_complete, spore_agent_fuzz_build_request(escaped_type_key.ptr, escaped_type_key.len, stream[0..0].ptr, 0));

    const ordinary_start = "{\"type\":\"start\",\"argv\":[\"/bin/true\"]}\n";
    try std.testing.expectEqual(guest_agent_fuzz_other_request, spore_agent_fuzz_build_request(ordinary_start.ptr, ordinary_start.len, stream[0..0].ptr, 0));

    const escaped_ordinary_start = "{\"type\":\"st\\u0061rt\",\"argv\":[\"/bin/true\"]}\n";
    try std.testing.expectEqual(guest_agent_fuzz_other_request, spore_agent_fuzz_build_request(escaped_ordinary_start.ptr, escaped_ordinary_start.len, stream[0..0].ptr, 0));

    const invalid_ordinary_start = "{\"type\":\"st\xffrt\",\"argv\":[\"/bin/true\"]}\n";
    try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(invalid_ordinary_start.ptr, invalid_ordinary_start.len, stream[0..0].ptr, 0));

    const copy_request = try copyRequest(std.testing.allocator, "spore-build-1", .{
        .source = "input",
        .dest = "/output",
        .source_kind = .file,
        .dest_is_dir = false,
        .entry_count = 1,
    });
    defer std.testing.allocator.free(copy_request);
    try std.testing.expectEqual(guest_agent_fuzz_copy_request, spore_agent_fuzz_build_request(copy_request.ptr, copy_request.len, stream[0..0].ptr, 0));

    const input_copy_request = try copyRequest(std.testing.allocator, "spore-build-1", .{
        .source = "out/app",
        .dest = "/app",
        .source_kind = .auto,
        .dest_is_dir = false,
        .entry_count = 0,
        .source_disk = .build_input,
        .input_index = 1,
    });
    defer std.testing.allocator.free(input_copy_request);
    try std.testing.expectEqual(guest_agent_fuzz_copy_request, spore_agent_fuzz_build_request(input_copy_request.ptr, input_copy_request.len, stream[0..0].ptr, 0));

    const workdir_request = try workdirRequest(std.testing.allocator, "spore-build-1", "/work");
    defer std.testing.allocator.free(workdir_request);
    try std.testing.expectEqual(guest_agent_fuzz_workdir_request, spore_agent_fuzz_build_request(workdir_request.ptr, workdir_request.len, stream[0..0].ptr, 0));

    const stale_resize_request = try run_mod.simpleControlRequest(std.testing.allocator, "spore-build-resize-v1", "spore-build-resize");
    defer std.testing.allocator.free(stale_resize_request);
    try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(stale_resize_request.ptr, stale_resize_request.len, stream[0..0].ptr, 0));

    const ready_request = "{\"type\":\"ready\",\"nonce\":\"1234\"}\n";
    try std.testing.expectEqual(guest_agent_fuzz_ready_request, spore_agent_fuzz_build_request(ready_request.ptr, ready_request.len, stream[0..0].ptr, 0));

    const grow_request = try run_mod.simpleControlRequest(std.testing.allocator, "spore-rootfs-grow-v1", "spore-build-resize");
    defer std.testing.allocator.free(grow_request);
    try std.testing.expectEqual(guest_agent_fuzz_grow_request, spore_agent_fuzz_build_request(grow_request.ptr, grow_request.len, stream[0..0].ptr, 0));
}

test "guest proc stat parser identifies kernel threads with adversarial task names" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;

    const user = "123 (user) S 1 2 3 4 5 0 0 0\n";
    try std.testing.expectEqual(@as(c_int, 0), spore_agent_fuzz_proc_stat(user.ptr, user.len));
    const kernel = "2 (name ) with spaces) S 0 0 0 0 0 2097152 0 0\n";
    try std.testing.expectEqual(@as(c_int, 1), spore_agent_fuzz_proc_stat(kernel.ptr, kernel.len));
    const malformed = "2 (unterminated S 0 0 0";
    try std.testing.expectEqual(@as(c_int, -1), spore_agent_fuzz_proc_stat(malformed.ptr, malformed.len));
}

test "prepare producer identity binds exact boot bytes but not paths or backend" {
    const allocator = std.testing.allocator;
    const a = try producerIdentity(allocator, sha256Bytes("kernel-a"), sha256Bytes("initrd-a"), true);
    defer allocator.free(a);
    const same = try producerIdentity(allocator, sha256Bytes("kernel-a"), sha256Bytes("initrd-a"), true);
    defer allocator.free(same);
    const kernel_changed = try producerIdentity(allocator, sha256Bytes("kernel-b"), sha256Bytes("initrd-a"), true);
    defer allocator.free(kernel_changed);
    const initrd_changed = try producerIdentity(allocator, sha256Bytes("kernel-a"), sha256Bytes("initrd-b"), true);
    defer allocator.free(initrd_changed);
    const swapped = try producerIdentity(allocator, sha256Bytes("initrd-a"), sha256Bytes("kernel-a"), true);
    defer allocator.free(swapped);

    try std.testing.expectEqualStrings(a, same);
    try std.testing.expect(!std.mem.eql(u8, a, kernel_changed));
    try std.testing.expect(!std.mem.eql(u8, a, initrd_changed));
    try std.testing.expect(!std.mem.eql(u8, a, swapped));
    const lazy_init = try producerIdentity(allocator, sha256Bytes("kernel-a"), sha256Bytes("initrd-a"), false);
    defer allocator.free(lazy_init);
    try std.testing.expect(!std.mem.eql(u8, a, lazy_init));
    try spore.validateRootfsDigest(a);
}

test "managed producer identity resolves without materializing boot artifact bytes" {
    const kernel_sha256 = sha256Bytes("kernel-a");
    const initrd_sha256 = sha256Bytes("initrd-a");
    const producer = try managedProducer(std.testing.allocator, .{
        .kernel_path = "/path-is-not-opened-during-identity-resolution",
        .kernel_sha256 = kernel_sha256,
        .initrd_sha256 = initrd_sha256,
    }, true);
    defer std.testing.allocator.free(producer.identity);

    try std.testing.expectEqual(@as(usize, 0), producer.eager_artifact_file_reads);
    try std.testing.expectEqual(@as(usize, 0), producer.eager_artifact_bytes_read);
    switch (producer.boot_source) {
        .managed => |managed| {
            try std.testing.expectEqualStrings("/path-is-not-opened-during-identity-resolution", managed.kernel_path);
            try std.testing.expectEqualSlices(u8, &kernel_sha256, &managed.kernel_sha256);
            try std.testing.expectEqualSlices(u8, &initrd_sha256, &managed.initrd_sha256);
        },
        .retained => return error.TestUnexpectedResult,
    }
}

test "ENOSPC detector survives output truncation and frame splits" {
    var detector: EnospcDetector = .{};
    const noise = [_]u8{'x'} ** 4096;
    for (0..20) |_| detector.observe(&noise);
    try std.testing.expect(!detector.seen);

    detector.observe("fallocate: No space left");
    try std.testing.expect(!detector.seen);
    detector.observe(" on device\n");
    try std.testing.expect(detector.seen);

    var stable: EnospcDetector = .{};
    stable.observe("SPORE_BUILD_");
    stable.observe("ENOSPC COPY apply failed\n");
    try std.testing.expect(stable.seen);
}

test "fuzz build control request framing" {
    try std.testing.fuzz({}, fuzzSimpleRequest, .{});
    try std.testing.fuzz({}, fuzzCopyRequest, .{});
    try std.testing.fuzz({}, fuzzGuestBuildRequest, .{});
    try std.testing.fuzz({}, fuzzGuestProcStat, .{});
    try std.testing.fuzz({}, fuzzGuestBuildResolvTarget, .{});
    try std.testing.fuzz({}, fuzzGuestCopyTree, .{});
}
