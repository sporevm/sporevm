const std = @import("std");
const TestDir = @import("../test_dir.zig").TestDir;
const builtin = @import("builtin");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const rootfs_cas = @import("../rootfs_cas.zig");
const disk_layer = @import("../disk_layer.zig");
const rootfs_mod = @import("../rootfs.zig");
const boot_assets = @import("../boot_assets.zig");
const guest_request = @import("../guest_request.zig");
const spore_net_policy = @import("../spore_net_policy.zig");
const vm_session = @import("../vm_session.zig");
const backend_mod = @import("../backend.zig");
const net_gateway = @import("../net_gateway.zig");
const local_paths = @import("../local_paths.zig");
const memory_config = @import("../memory.zig");
const topology = @import("../topology.zig");
const runtime_disk = @import("../runtime_disk.zig");
const runtime_disk_lease = @import("../runtime_disk_lease.zig");
const cache_mount = @import("cache_mount.zig");
const fuzz_support = @import("../fuzz_support.zig");
const spore = @import("../spore.zig");
const run_contract = @import("run_contract.zig");
const step_cache = @import("step_cache.zig");
const vsock = @import("../virtio/vsock.zig");
const vsock_control = @import("../virtio/vsock_control.zig");
const vsock_stream = @import("../virtio/vsock_stream.zig");

const guest_port: u32 = 10700;
const max_virtio_devices = switch (builtin.cpu.arch) {
    .aarch64 => @import("../aarch64/board.zig").max_virtio_devices,
    .x86_64 => @import("../x86_64/board.zig").max_virtio_devices,
    else => 0,
};
pub const default_step_timeout_ms: u64 = 30 * 60 * 1000;
const max_captured_output = 64 * 1024;
const max_rootfs_grow_response = guest_request.max_rootfs_grow_response;
const build_producer_domain = "sporevm-build-producer-v2";
const prepare_host_contract = "grow-v1-strict-request-v2;ext4-source-preflight-v2;ext4-superblock-postcondition-v1;ext4-ioctl-v1;noinit-itable-v1;virtio-write-zeroes-1x4m-v1;chunk-zero-map-v1";
// The x86 product profile is intentionally fixed at 512 MiB. AArch64 keeps
// the established 2 GiB default for larger RUN steps.
const build_vm_memory_bytes: u64 = if (builtin.cpu.arch == .x86_64) 512 * 1024 * 1024 else 2 * 1024 * 1024 * 1024;
pub const default_build_memory = memory_config.Config.fixed(build_vm_memory_bytes);
pub const default_build_vcpus: topology.VcpuCount = 1;
pub const max_build_nofile: u64 = 1_048_576;
pub const default_build_nofile = NofileLimit{ .soft = 65_536, .hard = 65_536 };
const max_guest_request_len = guest_request.max_guest_request_len;
pub const max_run_command_len = run_contract.max_shell_command_bytes;
pub const max_run_exec_args = run_contract.max_exec_args;
pub const max_run_exec_args_bytes = run_contract.max_exec_args_bytes;
pub const max_guest_envc = guest_request.max_guest_envc;
pub const max_guest_env_len = guest_request.max_guest_env_len;
pub const max_guest_working_dir_len = guest_request.max_guest_working_dir_len;
pub const max_copy_entries = 65536;
pub const max_copy_entry_path_len = 512;
pub const max_context_bind_mounts = 8;
pub const max_build_input_disks = @import("../aarch64/vmm.zig").max_build_input_disks;
const test_support = @import("../test_support.zig");
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
        try self.memory.validate();
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

/// Process leases on every rootfs storage a build reads or publishes. A build
/// holds the rootfs cache lock only to look up, emit and publish storage, so
/// between those epochs these leases are what stop GC and prune from taking
/// its bases, stage outputs and step snapshots; they end with the process.
pub const StorageLeases = struct {
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    runtime_root: []const u8,
    held: std.ArrayList(runtime_disk_lease.Active) = .empty,

    /// Checks the runtime directory up front so a bad one fails the build
    /// before it pulls anything.
    pub fn init(io: Io, allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, cache_root: []const u8) !StorageLeases {
        const runtime_root = try local_paths.runtimeRootPath(allocator, environ);
        errdefer allocator.free(runtime_root);
        try runtime_disk_lease.ensurePrivateDir(io, runtime_root);
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);
        return .{
            .io = io,
            .allocator = allocator,
            .cache_root = try std.fs.path.resolve(allocator, &.{ cwd, cache_root }),
            .runtime_root = runtime_root,
        };
    }

    /// Leases `storage`, which the caller found complete in the epoch of
    /// `lock`, so it stays rooted after the lock is released.
    pub fn hold(self: *StorageLeases, lock: *const rootfs_mod.RootfsCacheLock, storage: spore.RootfsStorage) !void {
        if (!try lock.ensureHeldFor(self.allocator, self.cache_root)) return error.RootfsCacheLockNotHeld;
        try self.held.ensureUnusedCapacity(self.allocator, 1);
        self.held.appendAssumeCapacity(try runtime_disk_lease.acquireActive(self.io, self.allocator, self.runtime_root, .{
            .root = self.cache_root,
            .baseline_kind = .disk_index,
            .baseline_identity = storage.index_digest,
            .rootfs_storage = storage,
        }));
    }

    pub fn deinit(self: *StorageLeases) void {
        for (self.held.items) |*active| active.deinit();
        self.held.deinit(self.allocator);
        self.allocator.free(self.cache_root);
        self.allocator.free(self.runtime_root);
    }
};

pub const Producer = struct {
    identity: []const u8,
    boot_source: union(enum) {
        retained: boot_assets.MonitorBootArtifacts,
        managed: boot_assets.ManagedMonitorBootDescriptor,
    },
    eager_artifact_file_reads: usize = 0,
    eager_artifact_bytes_read: usize = 0,
};

pub fn resolveProducer(init: std.process.Init, allocator: std.mem.Allocator) !Producer {
    const noinit_itable = vm_session.rootfsGrowthNoInitItable(init.environ_map);
    if (init.environ_map.get("SPOREVM_KERNEL_IMAGE") == null and
        init.environ_map.get("SPOREVM_RUN_INITRD") == null)
    {
        const managed = try boot_assets.resolveManagedMonitorBootDescriptor(init, allocator);
        return managedProducer(allocator, managed, noinit_itable);
    }

    const kernel_path = try boot_assets.resolveDefaultKernelPath(init, allocator);
    const initrd_path = try boot_assets.resolveConfiguredInitrdPath(init, null);
    const boot = try boot_assets.loadMonitorBootArtifacts(init.io, allocator, kernel_path, initrd_path);
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
    managed: boot_assets.ManagedMonitorBootDescriptor,
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
    source_instruction: []const u8 = "",
    command: RunCommand,
    env: []const []const u8,
    env_digest: []const u8,
    workdir: []const u8,
    network_mode: step_cache.NetworkMode,
    cache_mount_digest: []const u8 = "",
    cache_mounts: []const cache_mount.Mount = &.{},
    context_bind_digest: []const u8 = "",
    context_bind_mounts: []const ContextBindMount = &.{},
    ssh_declared_absent: bool = false,
};

pub const ContextBindMount = struct {
    source: []const u8,
    target: []const u8,
    mode: u32 = 0,
    content_digest: []const u8 = "",
    transport_source: []const u8 = "",
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

    fn diagnosticInstruction(self: Step) []const u8 {
        return switch (self) {
            .run => |step| if (step.source_instruction.len != 0) step.source_instruction else step.canonical_instruction,
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
    leases: *StorageLeases,
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
                .memory_bytes = resources.memory.initial_bytes,
                .vcpus = resources.vcpus,
                .nofile_soft = resources.nofile.soft,
                .nofile_hard = resources.nofile.hard,
                .cache_mount_digest = run.cache_mount_digest,
                .context_bind_digest = run.context_bind_digest,
                .ssh_declared_absent = run.ssh_declared_absent,
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
    const session_cache_mounts = try collectCacheMounts(allocator, options.steps);
    try cache_mount.validateCompatible(session_cache_mounts);
    if (!buildDeviceEnvelopeFits(options.context_disk_path != null, options.build_input_rootfs.len, cache_run != null)) {
        if (options.diagnostic) |diag| {
            diag.instruction = if (cache_run.?.source_instruction.len != 0) cache_run.?.source_instruction else cache_run.?.canonical_instruction;
            diag.instruction_line = cache_run.?.line;
        }
        return error.RunCacheMountDeviceBudgetUnsupported;
    }

    var cache_store: ?cache_mount.Store = if (cache_run != null)
        try cache_mount.Store.open(init.io, allocator, options.cache_root)
    else
        null;
    defer if (cache_store) |*store| store.deinit();

    var control = try BuildControl.init(init.io, allocator, options);
    defer control.deinit();

    const rootfs = try rootfsFromStorage(allocator, options.base_storage);
    const boot = switch (options.producer.boot_source) {
        .retained => |retained| retained,
        .managed => |managed| blk: {
            const artifacts = try boot_assets.materializeManagedMonitorBootArtifacts(init.io, allocator, managed);
            if (options.diagnostic) |diag| {
                diag.boot_artifact_file_reads += 1;
                diag.boot_artifact_bytes_read += artifacts.kernel.len;
            }
            break :blk artifacts;
        },
    };
    const backend = try backend_mod.Backend.auto.resolveForHost();
    const cause = cause: {
        // The gateway lives as long as the VM.
        const network = sessionNetwork(network_mode);
        var gateway: net_gateway.Process = undefined;
        var gateway_active = false;
        if (network == .spore) {
            try gateway.start(init.io, allocator, options.spore_executable, false, network.spore);
            gateway_active = true;
        }
        defer if (gateway_active) gateway.deinit();
        break :cause try vm_session.run(.{ .io = init.io, .environ_map = init.environ_map }, allocator, .{
            .backend = backend,
            .machine = .{ .boot = .{
                .kernel = boot.kernel,
                .initrd = boot.initrd,
                .memory = options.resources.memory,
                .guest_port = guest_port,
                .console_mirror = vm_session.console_fd >= 0,
            } },
            .vcpus = options.resources.vcpus,
            .disks = .{
                .rootfs = rootfs,
                .rootfs_grow_target = if (options.preparation) |preparation| preparation.exact_target else 0,
            },
            .network = .{
                .runtime = if (gateway_active) gateway.runtime() else .{},
                .manifest = try spore_net_policy.manifestNetworkFromOptions(allocator, &network),
            },
            .console_sink = vm_session.consoleSink,
            .mode = .{ .build = .{
                .control = control.control(),
                .context_disk_path = options.context_disk_path,
                .inputs = options.build_input_rootfs,
                .cache_disk_fd = if (cache_store) |*store| store.fd else null,
                .snapshot_metrics = if (options.diagnostic) |diag| &diag.snapshot_metrics else null,
            } },
        });
    };
    switch (cause) {
        .monitor_stopped, .snapshotted => {},
        .guest_off, .guest_reset, .probe_complete => return error.MonitorDidNotStopCleanly,
    }
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

/// `--network spore` gives build RUN steps unrestricted egress, like plain
/// `spore run --net`.
fn sessionNetwork(network_mode: step_cache.NetworkMode) spore_net_policy.Network {
    return switch (network_mode) {
        .spore => .{ .spore = .{ .egress = .unrestricted } },
        .none => .disabled,
    };
}

fn firstCacheMountRun(steps: []const Step) ?RunStep {
    for (steps) |step| switch (step) {
        .run => |run| if (run.cache_mounts.len != 0) return run,
        .copy, .workdir => {},
    };
    return null;
}

fn collectCacheMounts(allocator: std.mem.Allocator, steps: []const Step) ![]const cache_mount.Mount {
    var mounts = std.array_list.Managed(cache_mount.Mount).init(allocator);
    for (steps) |step| switch (step) {
        .run => |run| try mounts.appendSlice(run.cache_mounts),
        .copy, .workdir => {},
    };
    return mounts.toOwnedSlice();
}

pub fn buildDeviceEnvelopeFits(has_context: bool, build_input_count: usize, has_cache: bool) bool {
    const fixed_devices: usize = 5; // console, rootfs, net, vsock, rng
    return fixed_devices + @intFromBool(has_context) + build_input_count + @intFromBool(has_cache) <= max_virtio_devices;
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
    leases: *StorageLeases,
    /// Held from a checkpoint's snapshot until its output is leased.
    cache_lock: ?rootfs_mod.RootfsCacheLock = null,
    current_storage: spore.RootfsStorage,
    preparation: ?Preparation = null,
    rootfs_grow_target: u64 = 0,
    checkpoint_kind: CheckpointKind = .dockerfile_step,
    step_index: usize = 0,
    phase: Phase = .start_run,
    wake: ?vsock_control.Wake = null,
    active_stream: ActiveStream = .run,
    stream: vsock_stream.HostStream = undefined,
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

    fn init(io: Io, allocator: std.mem.Allocator, options: Options) !BuildControl {
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
            .leases = options.leases,
            .current_storage = try spore.cloneRootfsStorage(allocator, options.base_storage),
            .preparation = options.preparation,
            .rootfs_grow_target = if (options.preparation) |preparation| preparation.exact_target else 0,
            .checkpoint_kind = if (options.preparation == null) .dockerfile_step else .prepare,
            .phase = if (options.preparation == null) .start_run else .start_resize,
            .active_input = if (options.preparation) |preparation| preparation.input else null,
            .active_step_key = if (options.preparation) |preparation| preparation.step_key else "",
            .capture = std.array_list.Managed(u8).init(allocator),
            .resize_stdout = std.array_list.Managed(u8).init(allocator),
            .snapshot_metrics = if (options.diagnostic) |diag| &diag.snapshot_metrics else null,
        };
    }

    fn deinit(self: *BuildControl) void {
        if (self.cache_lock) |*lock| lock.deinit();
        self.capture.deinit();
        self.resize_stdout.deinit();
    }

    fn control(self: *BuildControl) vsock_control.Control {
        return .{
            .context = self,
            .pollFn = pollThunk,
            .setWakeFn = setWakeThunk,
            .completeSnapshotFn = completeSnapshotThunk,
            .completeRootfsSnapshotFn = completeRootfsSnapshotThunk,
            .reportStatsFn = reportStatsThunk,
        };
    }

    fn poll(self: *BuildControl, dev: *vsock.Vsock) !vsock_control.ControlAction {
        const phase = self.phase;
        // A new phase acts on the next poll.
        defer if (self.phase != phase) self.requestPoll();
        return self.pollPhase(dev);
    }

    fn pollPhase(self: *BuildControl, dev: *vsock.Vsock) !vsock_control.ControlAction {
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
            .snapshot => {
                // The snapshot seals objects into the shared cache and skips
                // ones already there, so GC must not run until its output is
                // leased. The guest is frozen while this waits.
                if (self.cache_lock == null) self.cache_lock = try rootfs_mod.lockRootfsCacheExclusive(self.io, self.allocator, self.cache_root);
                return .{ .rootfs_snapshot = .{ .dir = self.cache_root } };
            },
            .start_thaw => {
                try self.startSimpleControl(dev, .thaw);
                return .keep_running;
            },
            .active_thaw => return try self.pollActiveStream(dev),
            .done, .failed => return .stop,
        }
    }

    fn startResize(self: *BuildControl, dev: *vsock.Vsock) !void {
        if (self.preparation_start_ns != null) return error.BadManifest;
        self.preparation_start_ns = try monotonicNs();
        const request = try guest_request.simpleControlRequest(self.allocator, "spore-rootfs-grow-v1", "spore-build-resize");
        try self.startStream(dev, request, .resize, "");
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
                const request = try runRequestWithMounts(self.allocator, session_id, run.command, run.env, run.workdir, self.resources.nofile, run.cache_mounts, run.context_bind_mounts, self.io);
                const stdin_payload = switch (run.command) {
                    .shell => |shell| shell,
                    .exec => "",
                };
                try self.startStream(dev, request, .run, stdin_payload);
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
                try self.startStream(dev, request, .workdir, "");
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
        try self.startStream(dev, request, .copy, "");
        self.phase = .active_run;
    }

    fn stepInput(self: BuildControl, step: Step) step_cache.StepInput {
        return cacheInputForStep(self.platform, self.current_storage.index_digest, self.executor_identity, step, self.resources);
    }

    fn startSimpleControl(self: *BuildControl, dev: *vsock.Vsock, kind: ActiveStream) !void {
        const session_id = try checkpointSessionId(self.allocator, kind, self.checkpoint_kind, self.step_index);
        const request = switch (kind) {
            .freeze => try guest_request.simpleControlRequest(self.allocator, "fsfreeze-v1", session_id),
            .thaw => try guest_request.simpleControlRequest(self.allocator, "fsthaw-v1", session_id),
            .resize, .run, .copy, .workdir => unreachable,
        };
        try self.startStream(dev, request, kind, "");
        self.phase = switch (kind) {
            .freeze => .active_freeze,
            .thaw => .active_thaw,
            .resize, .run, .copy, .workdir => unreachable,
        };
    }

    fn startStream(self: *BuildControl, dev: *vsock.Vsock, request: []const u8, kind: ActiveStream, stdin_payload: []const u8) !void {
        self.stream = try vsock_stream.HostStream.init(guest_port, request);
        self.stream.host_port = vsock_stream.HostStream.hostPortForSequence(self.stream_sequence);
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

    fn pollActiveStream(self: *BuildControl, dev: *vsock.Vsock) !vsock_control.ControlAction {
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
                self.phase = .start_freeze;
            },
            .run, .copy, .workdir => {
                if (exit_code != 0) {
                    self.failed_instruction = self.steps[self.step_index].diagnosticInstruction();
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
        const lock = if (self.cache_lock) |*lock| lock else return error.RootfsCacheLockNotHeld;
        try self.leases.hold(lock, storage);
        lock.deinit();
        self.cache_lock = null;
        self.pending_storage = storage;
        self.phase = .start_thaw;
        self.requestPoll();
    }

    fn setWake(self: *BuildControl, wake: vsock_control.Wake) void {
        self.wake = wake;
    }

    /// Asks the VMM to poll again without waiting for guest activity.
    fn requestPoll(self: *BuildControl) void {
        if (self.wake) |wake| wake.wake();
    }

    fn completeSnapshot(_: *BuildControl, _: []const u8) !void {}

    fn reportStats(_: *BuildControl, _: vsock_control.ControlStats) void {}

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

    fn outputSink(context: ?*anyopaque, output: vsock_stream.HostStreamOutput, bytes: []const u8) void {
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

    fn pollThunk(context: *anyopaque, dev: *vsock.Vsock) !vsock_control.ControlAction {
        const self: *BuildControl = @ptrCast(@alignCast(context));
        return self.poll(dev);
    }

    fn setWakeThunk(context: *anyopaque, wake: vsock_control.Wake) void {
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

    fn reportStatsThunk(context: *anyopaque, stats: vsock_control.ControlStats) void {
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

fn parseRootfsGrowResponse(bytes: []const u8) !guest_request.RootfsGrowResult {
    return guest_request.parseRootfsGrowResponse(bytes);
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
    return runRequestWithMounts(allocator, session_id, command, env, workdir, nofile, &.{}, &.{}, io);
}

fn runRequestWithMounts(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    command: RunCommand,
    env: []const []const u8,
    workdir: []const u8,
    nofile: NofileLimit,
    cache_mounts: []const cache_mount.Mount,
    context_bind_mounts: []const ContextBindMount,
    io: Io,
) ![]const u8 {
    const now: u64 = @intCast(Io.Clock.real.now(io).nanoseconds);
    const json = try runRequestJson(allocator, session_id, command, env, workdir, nofile, cache_mounts, context_bind_mounts, now);
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
    return validateRunRequestWithContextBinds(allocator, command, env, workdir, nofile, cache_mounts, &.{});
}

pub fn validateRunRequestWithContextBinds(
    allocator: std.mem.Allocator,
    command: RunCommand,
    env: []const []const u8,
    workdir: []const u8,
    nofile: NofileLimit,
    cache_mounts: []const cache_mount.Mount,
    context_bind_mounts: []const ContextBindMount,
) !void {
    const max_session_id = test_support.repeat("x", 63);
    const json = try runRequestJson(allocator, max_session_id, command, env, workdir, nofile, cache_mounts, context_bind_mounts, std.math.maxInt(u64));
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
    context_bind_mounts: []const ContextBindMount,
    now: u64,
) ![]const u8 {
    try nofile.validate();
    if (workdir.len == 0 or workdir.len > max_guest_working_dir_len) return error.RunWorkingDirUnsupported;
    if (env.len > max_guest_envc) return error.RunEnvCountUnsupported;
    for (env) |entry| if (entry.len > max_guest_env_len) return error.RunEnvTooLong;
    if (cache_mounts.len > cache_mount.max_mounts_per_run) return error.TooManyRunCacheMounts;
    if (context_bind_mounts.len > max_context_bind_mounts) return error.TooManyRunContextBindMounts;
    for (context_bind_mounts) |mount| try validateContextBindMount(mount);
    // Shell form streams its command after the request; exec form sends argv.
    var shell: []const u8 = "";
    var argv: []const []const u8 = &.{};
    switch (command) {
        .shell => |value| {
            if (value.len > max_run_command_len) return error.RunCommandTooLong;
            shell = value;
        },
        .exec => |value| {
            if (context_bind_mounts.len != 0) return error.RunContextBindCommandUnsupported;
            if (run_contract.execArgvViolation(value)) |violation| switch (violation) {
                .empty, .too_many_args => return error.RunArgCountUnsupported,
                .empty_executable, .nul => return error.RunArgUnsupported,
                .decoded_too_large => return error.RunRequestTooLarge,
            };
            argv = value;
        },
    }
    const PayloadMount = struct { target: []const u8, key: []const u8 };
    const payload_mounts = try allocator.alloc(PayloadMount, cache_mounts.len);
    defer allocator.free(payload_mounts);
    for (cache_mounts, 0..) |mount, index| payload_mounts[index] = .{ .target = mount.target, .key = mount.key };
    const PayloadBind = struct { source: []const u8, target: []const u8 };
    const payload_binds = try allocator.alloc(PayloadBind, context_bind_mounts.len);
    defer allocator.free(payload_binds);
    for (context_bind_mounts, 0..) |mount, index| payload_binds[index] = .{ .source = mount.transport_source, .target = mount.target };
    const payload = struct {
        type: []const u8 = "spore-build-run-v4",
        session_id: []const u8,
        resume_time_unix_ns: u64,
        command_len: usize,
        argv: []const []const u8,
        env: []const []const u8,
        working_dir: []const u8,
        cache_mounts: []const PayloadMount,
        context_binds: []const PayloadBind,
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
        .context_binds = payload_binds,
        .nofile_soft = nofile.soft,
        .nofile_hard = nofile.hard,
    };
    return std.json.Stringify.valueAlloc(allocator, payload, .{});
}

fn validateContextBindMount(mount: ContextBindMount) !void {
    if (mount.source.len == 0 or mount.source.len > max_copy_entry_path_len or
        mount.transport_source.len == 0 or mount.transport_source.len > max_copy_entry_path_len or
        mount.target.len < 2 or mount.target.len > max_copy_entry_path_len or
        !std.fs.path.isAbsolute(mount.target) or mount.target[mount.target.len - 1] == '/')
    {
        return error.RunContextBindPathUnsupported;
    }
    for ([_][]const u8{ mount.source, mount.transport_source }) |path| {
        if (std.fs.path.isAbsolute(path)) return error.RunContextBindPathUnsupported;
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.RunContextBindPathUnsupported;
        }
    }
    var target_it = std.mem.splitScalar(u8, mount.target[1..], '/');
    while (target_it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.RunContextBindPathUnsupported;
    }
    for ([_][]const u8{ "/proc", "/dev", "/sys", "/run/sporevm", "/run/buildkit", "/etc/resolv.conf" }) |owned| {
        if (contextBindPathsOverlap(mount.target, owned)) return error.RunContextBindPathUnsupported;
    }
}

fn contextBindPathsOverlap(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    if (a.len < b.len and std.mem.startsWith(u8, b, a) and b[a.len] == '/') return true;
    return b.len < a.len and std.mem.startsWith(u8, a, b) and a[b.len] == '/';
}

fn copyRequest(allocator: std.mem.Allocator, session_id: []const u8, request: CopyRequest) ![]const u8 {
    try validateCopyRequest(request);
    const payload = struct {
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
        destination_policy: []const u8,
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
        .destination_policy = @tagName(request.destination_policy),
    };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
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
    const request = guest_request.simpleControlRequest(std.testing.allocator, buf[0..len], "session") catch return;
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
const guest_agent_fuzz_start_request: c_int = 8;
const guest_agent_fuzz_attach_request: c_int = 9;

extern fn spore_agent_fuzz_build_request(request: [*]const u8, request_len: usize, stream: [*]const u8, stream_len: usize) c_int;
extern fn spore_agent_fuzz_exec_arg_equals(request: [*]const u8, request_len: usize, arg_index: usize, expected: [*]const u8, expected_len: usize) c_int;
extern fn spore_agent_test_generation_params(params: [*]const u8, params_len: usize, generation: *u64, fork_index: *u64, vm_id: *[128]u8) c_int;
extern fn spore_agent_test_resolve_exec_path(command: [*]const u8, command_len: usize, path: [*]const u8, path_len: usize, path_present: c_int, resolved: [*]u8, resolved_cap: usize) c_int;
extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
extern fn spore_agent_fuzz_ext4_geometry(super: [*]const u8, super_len: usize, blocks_count: *u64, blocks_per_group: *u32, block_size: *u32) c_int;
extern fn spore_agent_fuzz_ext4_growth_source(super: [*]const u8, super_len: usize) c_int;
extern fn spore_agent_fuzz_rootfs_grow_geometry(target_blocks: u64, before_blocks: u64, before_blocks_per_group: u32, before_block_size: u32, after_blocks: u64, after_blocks_per_group: u32, after_block_size: u32) c_int;
extern fn spore_agent_fuzz_proc_stat(stat: [*]const u8, stat_len: usize) c_int;
extern fn spore_agent_fuzz_build_resolv_target(target: [*]const u8, target_len: usize, logical: [*]u8, logical_cap: usize) c_int;
extern fn spore_agent_test_bounded_readlink(target: [*]const u8, target_len: usize) c_int;
const GuestRequestLimits = extern struct {
    request_bytes: u64,
    argc: u64,
    exec_args_bytes: u64,
    shell_command_bytes: u64,
    envc: u64,
    env_bytes: u64,
    working_dir_bytes: u64,
    cache_mounts: u64,
    context_binds: u64,
    copy_path_bytes: u64,
    copy_entries: u64,
    build_input_disks: u64,
    nofile: u64,
    session_id_bytes: u64,
    generation_params_bytes: u64,
    frame_payload_bytes: u64,
    initial_output_bytes: u64,
    output_read_bytes: u64,
    replay_bytes: u64,
};
extern fn spore_agent_test_request_limits(out: *GuestRequestLimits) void;
extern fn spore_agent_test_serve_requests(captured_script: [*:0]const u8, captured_finishes: c_int, attach: [*]const u8, attach_len: usize, requests: [*]const u8, request_lens: [*]const usize, request_count: usize, response: [*]u8, response_cap: usize, captured_stdout: *u64) isize;
extern fn spore_build_copy_test_confined_source_parent(root: [*]const u8, root_len: usize, path: [*]const u8, path_len: usize) c_int;
extern fn spore_build_copy_test_confined_mtime(root: [*]const u8, root_len: usize, path: [*]const u8, path_len: usize, unix_seconds: i64) c_int;
extern fn spore_build_copy_test_context_bind_source(root: [*]const u8, root_len: usize, path: [*]const u8, path_len: usize) c_int;
extern fn spore_build_copy_test_context_bind_target(root: [*]const u8, root_len: usize, path: [*]const u8, path_len: usize, create_sibling: c_int) c_int;
extern fn spore_build_copy_fuzz_tree(source_root: [*]const u8, source_root_len: usize, dest_root: [*]const u8, dest_root_len: usize, fuzz: [*]const u8, fuzz_len: usize) c_int;
extern fn spore_build_copy_test_fd_budget() u64;
extern fn spore_build_copy_test_security_xattr_long_name(root: [*]const u8, root_len: usize) c_int;
extern fn spore_build_copy_test_security_xattr_policy(regular_source: c_int, existing_destination: c_int, name: [*]const u8, name_len: usize) c_int;
extern fn spore_build_copy_apply(
    root: [*:0]const u8,
    source_root: [*:0]const u8,
    source: [*:0]const u8,
    dest: [*:0]const u8,
    source_kind: c_int,
    dest_is_dir: c_int,
    entry_count: u64,
    destination_policy: c_int,
    mtime_present: c_int,
    mtime_unix_seconds: i64,
    error_message: [*]u8,
    error_cap: usize,
) c_int;

// Fork generation params as a JSON string value, with an extra member holding
// the kinds of value the agent must skip.
const guest_fork_params_json_string =
    \\{\"schema_version\":0,\"parent_generation\":1,\"generation\":2,\"fork_index\":0,\"fork_count\":2,\"parallel_index\":0,\"parallel_count\":2,\"fork_batch_id\":\"0123456789abcdef0123456789abcdef\",\"vm_id\":\"spore-0123456789abcdef0123456789abcdef\",\"hostname\":\"spore-01234567-000000\",\"mac_seed\":\"0123456789abcdef0123456789abcdef\",\"mac_address\":\"02:00:00:00:00:01\",\"resume_time_unix_ns\":1,\"resume_entropy_seed\":\"0123456789abcdef0123456789abcdef\",\"labels\":{\"generation\":[1,null,true,-1.5e3]}}
;

// start-v1 and attach-v1 requests as the host encodes them, without the
// closing "}\n". They seed the guest request fuzz target, each with a
// duplicate-key and an unknown-key variant, so mutations start from requests
// that reach every member parser, including the generation params parser.
const guest_exec_request_seeds = [_]struct { body: []const u8, kind: c_int, last_member: []const u8 }{
    .{ .kind = guest_agent_fuzz_start_request, .last_member = ",\"closed_env\":true", .body = "{\"type\":\"start-v1\",\"session_id\":\"run-1\",\"resume_time_unix_ns\":1,\"argv\":[\"/bin/true\"],\"env\":[],\"working_dir\":\"\",\"stdio\":\"null\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"params_json\":\"\",\"require_generation_ready\":false,\"detached\":false,\"retain_output\":false,\"closed_env\":true" },
    .{ .kind = guest_agent_fuzz_start_request, .last_member = ",\"closed_env\":true", .body = "{\"type\":\"start-v1\",\"session_id\":\"lifecycle-1\",\"resume_time_unix_ns\":1,\"argv\":[\"/bin/sh\",\"-c\",\"cat\"],\"env\":[\"A=1\"],\"working_dir\":\"/work\",\"stdio\":\"pipe\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":true,\"params_json\":\"{\\\"generation\\\":2}\",\"require_generation_ready\":true,\"detached\":false,\"retain_output\":false,\"closed_env\":true" },
    .{ .kind = guest_agent_fuzz_start_request, .last_member = ",\"closed_env\":true", .body = "{\"type\":\"start-v1\",\"session_id\":\"lifecycle-2\",\"resume_time_unix_ns\":1,\"argv\":[\"sh\"],\"env\":[],\"working_dir\":\"/\",\"stdio\":\"tty\",\"terminal_rows\":40,\"terminal_cols\":120,\"memory_pressure\":false,\"params_json\":\"\",\"require_generation_ready\":false,\"detached\":false,\"retain_output\":false,\"closed_env\":true" },
    .{ .kind = guest_agent_fuzz_start_request, .last_member = ",\"closed_env\":true", .body = "{\"type\":\"start-v1\",\"session_id\":\"lifecycle-3\",\"resume_time_unix_ns\":1,\"argv\":[\"/bin/sleep\",\"60\"],\"env\":[],\"working_dir\":\"\",\"stdio\":\"null\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"params_json\":\"\",\"require_generation_ready\":false,\"detached\":true,\"retain_output\":true,\"closed_env\":true" },
    .{ .kind = guest_agent_fuzz_attach_request, .last_member = ",\"params_json\":\"\"", .body = "{\"type\":\"attach-v1\",\"session_id\":\"default\",\"stdout_offset\":0,\"stderr_offset\":0,\"stdio\":\"null\",\"interactive\":false,\"terminal_rows\":24,\"terminal_cols\":80,\"params_json\":\"\"" },
    .{ .kind = guest_agent_fuzz_attach_request, .last_member = ",\"params_json\":\"\"", .body = "{\"type\":\"attach-v1\",\"session_id\":\"default\",\"stdout_offset\":0,\"stderr_offset\":0,\"stdio\":\"null\",\"interactive\":false,\"terminal_rows\":24,\"terminal_cols\":80,\"params_json\":\"" ++ guest_fork_params_json_string ++ "\"" },
};

// The removed term member doubles as the unknown key.
const guest_exec_request_unknown_member = ",\"term\":\"xterm\"";

// Fuzz inputs for fuzzGuestBuildRequest: raw mode 5 followed by a request.
const guest_request_fuzz_corpus = corpus: {
    var corpus: [3 * guest_exec_request_seeds.len][]const u8 = undefined;
    for (guest_exec_request_seeds, 0..) |seed, i| {
        corpus[3 * i] = fuzz_support.sliceSeed("\x05" ++ seed.body ++ "}\n");
        corpus[3 * i + 1] = fuzz_support.sliceSeed("\x05" ++ seed.body ++ seed.last_member ++ "}\n");
        corpus[3 * i + 2] = fuzz_support.sliceSeed("\x05" ++ seed.body ++ guest_exec_request_unknown_member ++ "}\n");
    }
    break :corpus corpus;
};

fn fuzzGuestBuildRequest(_: void, s: *std.testing.Smith) !void {
    if (comptime guest_agent_fuzz_supported) {
        // Raw mode (5) must fit any request the guest accepts.
        var fuzz_bytes: [max_guest_request_len + 1]u8 = undefined;
        const fuzz_len = s.slice(&fuzz_bytes);
        const mode = if (fuzz_len == 0) 0 else fuzz_bytes[0] % 11;
        const command = if (fuzz_len <= 1) "x" else fuzz_bytes[1..fuzz_len];
        var stream: [2 * 24 + fuzz_bytes.len]u8 = undefined;
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
            const request = over_limit_shell_request;
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

        if (mode == 9) {
            const tty = fuzz_len > 1 and (fuzz_bytes[1] & 1) != 0;
            const request = guest_request.interactiveExecRequestWithSession(std.testing.allocator, &.{ "/bin/sh", "-c", command }, "spore-exec-fuzz", .{ .tty = tty }) catch return;
            defer std.testing.allocator.free(request);
            _ = spore_agent_fuzz_build_request(request.ptr, request.len, stream[0..0].ptr, 0);
            return;
        }

        if (mode == 10) {
            const request = @import("../attach_stream.zig").attachV1Request(std.testing.allocator, .{ .session_id = command }) catch return;
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

test "host request limits match the guest agent" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;
    var guest: GuestRequestLimits = undefined;
    spore_agent_test_request_limits(&guest);
    try std.testing.expectEqual(@as(u64, guest_request.max_guest_request_len), guest.request_bytes);
    try std.testing.expectEqual(@as(u64, max_run_exec_args), guest.argc);
    try std.testing.expectEqual(@as(u64, guest_request.max_guest_argc), guest.argc);
    try std.testing.expectEqual(@as(u64, max_run_exec_args_bytes), guest.exec_args_bytes);
    try std.testing.expectEqual(@as(u64, max_run_command_len), guest.shell_command_bytes);
    try std.testing.expectEqual(@as(u64, max_guest_envc), guest.envc);
    try std.testing.expectEqual(@as(u64, max_guest_env_len), guest.env_bytes);
    try std.testing.expectEqual(@as(u64, max_guest_working_dir_len), guest.working_dir_bytes);
    try std.testing.expectEqual(@as(u64, cache_mount.max_mounts_per_run), guest.cache_mounts);
    try std.testing.expectEqual(@as(u64, max_context_bind_mounts), guest.context_binds);
    try std.testing.expectEqual(@as(u64, max_copy_entry_path_len), guest.copy_path_bytes);
    try std.testing.expectEqual(@as(u64, cache_mount.max_target_bytes), guest.copy_path_bytes);
    try std.testing.expectEqual(@as(u64, @import("../named_copy_archive.zig").max_path), guest.copy_path_bytes);
    try std.testing.expectEqual(@as(u64, max_copy_entries), guest.copy_entries);
    try std.testing.expectEqual(@as(u64, max_build_input_disks), guest.build_input_disks);
    try std.testing.expectEqual(max_build_nofile, guest.nofile);
    try std.testing.expectEqual(@as(u64, spore.max_session_id_len), guest.session_id_bytes);
    try std.testing.expectEqual(@as(u64, @import("../generation.zig").params_size), guest.generation_params_bytes);
    try std.testing.expectEqual(@as(u64, @import("../spore_stream.zig").max_payload_len), guest.frame_payload_bytes);
    try std.testing.expectEqual(@as(u64, @import("../lifecycle.zig").initial_output_limit_bytes_per_stream), guest.initial_output_bytes);
    // A `spore run` save trails the agent by at most a read it is still
    // sending plus the vsock credit the host grants, and an attach must be
    // able to resume from there.
    try std.testing.expect(guest.replay_bytes >= guest.output_read_bytes + @import("../virtio/vsock.zig").host_stream_credit);
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

test "build COPY parents preserves conflicts without changing auto directory merge" {
    if (comptime guest_agent_fuzz_supported) {
        const io = std.testing.io;
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.createDirPath(io, "source/root-tree");
        try tmp.dir.writeFile(io, .{ .sub_path = "source/root-tree/x", .data = "new" });
        try tmp.dir.createDirPath(io, "source/nested-tree/secret");
        try tmp.dir.writeFile(io, .{ .sub_path = "source/nested-tree/secret/value", .data = "new" });
        try tmp.dir.createDirPath(io, "root-conflict");
        try tmp.dir.writeFile(io, .{ .sub_path = "root-conflict/dest", .data = "old" });
        try tmp.dir.createDirPath(io, "nested-conflict/dest");
        try tmp.dir.writeFile(io, .{ .sub_path = "nested-conflict/dest/secret", .data = "old" });
        try tmp.dir.setFilePermissions(io, "root-conflict/dest", .fromMode(0o600), .{ .follow_symlinks = false });
        try tmp.dir.setFilePermissions(io, "nested-conflict/dest/secret", .fromMode(0o640), .{ .follow_symlinks = false });
        try tmp.dir.createDirPath(io, "auto-directory/dest");
        try tmp.dir.writeFile(io, .{ .sub_path = "auto-directory/dest/original", .data = "old" });

        const root_before = try tmp.dir.statFile(io, "root-conflict/dest", .{ .follow_symlinks = false });
        const nested_before = try tmp.dir.statFile(io, "nested-conflict/dest/secret", .{ .follow_symlinks = false });

        const source_root = try tmp.dir.realPathFileAlloc(io, "source", allocator);
        defer allocator.free(source_root);
        const source_root_z = try allocator.dupeSentinel(u8, source_root, 0);
        defer allocator.free(source_root_z);
        const root_conflict = try tmp.dir.realPathFileAlloc(io, "root-conflict", allocator);
        defer allocator.free(root_conflict);
        const root_conflict_z = try allocator.dupeSentinel(u8, root_conflict, 0);
        defer allocator.free(root_conflict_z);
        const nested_conflict = try tmp.dir.realPathFileAlloc(io, "nested-conflict", allocator);
        defer allocator.free(nested_conflict);
        const nested_conflict_z = try allocator.dupeSentinel(u8, nested_conflict, 0);
        defer allocator.free(nested_conflict_z);
        const auto_directory = try tmp.dir.realPathFileAlloc(io, "auto-directory", allocator);
        defer allocator.free(auto_directory);
        const auto_directory_z = try allocator.dupeSentinel(u8, auto_directory, 0);
        defer allocator.free(auto_directory_z);

        var diagnostic: [384]u8 = undefined;
        const root_rc = spore_build_copy_apply(
            root_conflict_z,
            source_root_z,
            "root-tree",
            "/dest",
            'D',
            0,
            2,
            0,
            0,
            0,
            &diagnostic,
            diagnostic.len,
        );
        try std.testing.expectEqual(@as(c_int, 1), root_rc);
        try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(&diagnostic, 0), "COPY directory apply failed: path=/dest errno=") != null);
        const root_value = try tmp.dir.readFileAlloc(io, "root-conflict/dest", allocator, .limited(16));
        defer allocator.free(root_value);
        try std.testing.expectEqualStrings("old", root_value);
        const root_after = try tmp.dir.statFile(io, "root-conflict/dest", .{ .follow_symlinks = false });
        try std.testing.expectEqual(root_before.inode, root_after.inode);
        try std.testing.expectEqual(@intFromEnum(root_before.permissions) & 0o7777, @intFromEnum(root_after.permissions) & 0o7777);

        @memset(diagnostic[0..], 0);
        const nested_rc = spore_build_copy_apply(
            nested_conflict_z,
            source_root_z,
            "nested-tree",
            "/dest",
            'D',
            0,
            3,
            0,
            0,
            0,
            &diagnostic,
            diagnostic.len,
        );
        try std.testing.expectEqual(@as(c_int, 1), nested_rc);
        try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(&diagnostic, 0), "COPY directory apply failed: path=/dest/secret errno=") != null);
        const nested_value = try tmp.dir.readFileAlloc(io, "nested-conflict/dest/secret", allocator, .limited(16));
        defer allocator.free(nested_value);
        try std.testing.expectEqualStrings("old", nested_value);
        const nested_after = try tmp.dir.statFile(io, "nested-conflict/dest/secret", .{ .follow_symlinks = false });
        try std.testing.expectEqual(nested_before.inode, nested_after.inode);
        try std.testing.expectEqual(@intFromEnum(nested_before.permissions) & 0o7777, @intFromEnum(nested_after.permissions) & 0o7777);

        @memset(diagnostic[0..], 0);
        const auto_rc = spore_build_copy_apply(
            auto_directory_z,
            source_root_z,
            "root-tree",
            "/dest",
            'A',
            0,
            0,
            0,
            0,
            0,
            &diagnostic,
            diagnostic.len,
        );
        try std.testing.expectEqual(@as(c_int, 0), auto_rc);
        const auto_value = try tmp.dir.readFileAlloc(io, "auto-directory/dest/x", allocator, .limited(16));
        defer allocator.free(auto_value);
        try std.testing.expectEqualStrings("new", auto_value);
        const auto_original = try tmp.dir.readFileAlloc(io, "auto-directory/dest/original", allocator, .limited(16));
        defer allocator.free(auto_original);
        try std.testing.expectEqualStrings("old", auto_original);
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

test "build context bind helpers reject symlinks and preserve owned target state" {
    if (comptime guest_agent_fuzz_supported) {
        const io = std.testing.io;
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "context/dir");
        try tmp.dir.writeFile(io, .{ .sub_path = "context/file", .data = "data" });
        try tmp.dir.symLink(io, "file", "context/link", .{});
        const context_root = try tmp.dir.realPathFileAlloc(io, "context", allocator);
        defer allocator.free(context_root);
        try std.testing.expectEqual(@as(c_int, 0), spore_build_copy_test_context_bind_source(context_root.ptr, context_root.len, "file".ptr, "file".len));
        try std.testing.expectEqual(@as(c_int, -1), spore_build_copy_test_context_bind_source(context_root.ptr, context_root.len, "link".ptr, "link".len));
        try std.testing.expectEqual(@as(c_int, -1), spore_build_copy_test_context_bind_source(context_root.ptr, context_root.len, "dir".ptr, "dir".len));

        try tmp.dir.createDirPath(io, "rootfs");
        const rootfs = try tmp.dir.realPathFileAlloc(io, "rootfs", allocator);
        defer allocator.free(rootfs);
        try std.testing.expectEqual(@as(c_int, 0), spore_build_copy_test_context_bind_target(rootfs.ptr, rootfs.len, "/new/target".ptr, "/new/target".len, 1));
        try tmp.dir.createDirPath(io, "rootfs/existing");
        try tmp.dir.writeFile(io, .{ .sub_path = "rootfs/existing/target", .data = "lower" });
        try std.testing.expectEqual(@as(c_int, 0), spore_build_copy_test_context_bind_target(rootfs.ptr, rootfs.len, "/existing/target".ptr, "/existing/target".len, 0));
        const lower = try tmp.dir.readFileAlloc(io, "rootfs/existing/target", allocator, .limited(16));
        defer allocator.free(lower);
        try std.testing.expectEqualStrings("lower", lower);
        try std.testing.expectEqual(@as(c_int, 0), spore_build_copy_test_context_bind_target(rootfs.ptr, rootfs.len, "/replaced/target".ptr, "/replaced/target".len, 2));
    }
}

test "security xattr inspection accepts an ext4 maximum-length clean name" {
    if (comptime guest_agent_fuzz_supported) {
        var tmp_dir = try TestDir.init();
        defer tmp_dir.deinit();
        const tmp = tmp_dir.root;
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
        var tmp = fuzz_support.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "source");
        try tmp.dir.createDirPath(io, "dest");
        var source_buf: [64]u8 = undefined;
        var dest_buf: [64]u8 = undefined;
        const source = try std.fmt.bufPrint(&source_buf, ".zig-cache/tmp/{s}/source", .{tmp.sub_path});
        const dest = try std.fmt.bufPrint(&dest_buf, ".zig-cache/tmp/{s}/dest", .{tmp.sub_path});
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

test "build rootfs grow request stays bounded" {
    const request = try guest_request.simpleControlRequest(std.testing.allocator, "spore-rootfs-grow-v1", "spore-build-resize");
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
            "{\"type\":\"spore-rootfs-grow-v1\",\"session_id\":\"" ++ (test_support.repeat("a", 64)) ++ "\"}\n",
            "{\"type\":\"spore-rootfs-grow-v1\",\"session_id\":\"a\"}\x00extra\n",
        };
        for (invalid) |raw| {
            try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(raw.ptr, raw.len, raw[0..0].ptr, 0));
        }
        const max_session = "{\"type\":\"spore-rootfs-grow-v1\",\"session_id\":\"" ++ (test_support.repeat("a", 63)) ++ "\"}\n";
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

test "a build control phase change asks the VMM to poll again" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var build_control: BuildControl = .{
        .io = std.testing.io,
        .allocator = arena,
        .platform = undefined,
        .executor_identity = "",
        .cache_root = "",
        .leases = undefined,
        .steps = &.{},
        .resources = .{},
        .timeout_ms = std.time.ms_per_min,
        .output = null,
        .current_storage = undefined,
        .capture = .init(arena),
        .resize_stdout = .init(arena),
        .phase = .start_thaw,
    };
    const PollCounter = struct {
        fn wake(context: *anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(context));
            count.* += 1;
        }
    };
    var polls: usize = 0;
    build_control.control().setWake(.{ .context = &polls, .wakeFn = PollCounter.wake });
    var dev = vsock.Vsock.init(.{});

    try std.testing.expect(try build_control.poll(&dev) == .keep_running);
    try std.testing.expectEqual(Phase.active_thaw, build_control.phase);
    try std.testing.expectEqual(@as(usize, 1), polls);

    // Waiting on the guest is not a new phase.
    try std.testing.expect(try build_control.poll(&dev) == .keep_running);
    try std.testing.expectEqual(@as(usize, 1), polls);
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

test "build RUN steps with --network spore get unrestricted egress" {
    try std.testing.expect(sessionNetwork(.spore).spore.egress == .unrestricted);
    try std.testing.expectEqual(spore_net_policy.NetworkMode.disabled, sessionNetwork(.none));
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
    try std.testing.expectEqualStrings("spore-build-copy-v5", object.get("type").?.string);
    try std.testing.expectEqualStrings("follow", object.get("destination_policy").?.string);
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

test "build copy guest parser rejects incomplete or ambiguous framing" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;

    const valid = "{\"type\":\"spore-build-copy-v5\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"file\",\"dest_is_dir\":false,\"entry_count\":1,\"source_disk\":\"context\",\"input_index\":0,\"mtime_unix_seconds\":null,\"destination_policy\":\"follow\"}\n";
    try std.testing.expectEqual(guest_agent_fuzz_copy_request, spore_agent_fuzz_build_request(valid.ptr, valid.len, valid[0..0].ptr, 0));

    const invalid = [_][]const u8{
        valid[0 .. valid.len - 1],
        valid[0 .. valid.len - 2] ++ ",}\n",
        valid[0 .. valid.len - 2] ++ " trailing\n",
        "{\"type\":\"spore-build-copy-v5\",\"type\":\"spore-build-copy-v5\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"file\",\"dest_is_dir\":false,\"entry_count\":1,\"source_disk\":\"context\",\"input_index\":0,\"mtime_unix_seconds\":null,\"destination_policy\":\"follow\"}\n",
        "{\"type\":\"spore-build-copy-v5\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"file\",\"dest_is_dir\":false,\"entry_count\":1,\"source_disk\":\"context\",\"input_index\":0,\"mtime_unix_seconds\":null,\"destination_policy\":\"follow\",\"extra\":true}\n",
        "{\"type\":\"spore-build-copy-v5\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"file\",\"dest_is_dir\":false,\"entry_count\":1,\"source_disk\":\"context\",\"input_index\":0,\"destination_policy\":\"follow\"}\n",
        "{\"type\":\"spore-build-copy-v5\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"file\",\"dest_is_dir\":false,\"entry_count\":1,\"source_disk\":\"context\",\"input_index\":0,\"mtime_unix_seconds\":9223372036854775808,\"destination_policy\":\"follow\"}\n",
        "{\"type\":\"spore-build-copy-v5\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"file\",\"dest_is_dir\":false,\"entry_count\":1,\"source_disk\":\"context\",\"input_index\":0,\"mtime_unix_seconds\":-9223372036854775809,\"destination_policy\":\"follow\"}\n",
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

test "build copy guest parser requires one known destination policy" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;

    const link = "{\"type\":\"spore-build-copy-v5\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"auto\",\"dest_is_dir\":false,\"entry_count\":0,\"source_disk\":\"build_input\",\"input_index\":0,\"mtime_unix_seconds\":null,\"destination_policy\":\"link\"}\n";
    const follow = "{\"type\":\"spore-build-copy-v5\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"auto\",\"dest_is_dir\":false,\"entry_count\":0,\"source_disk\":\"build_input\",\"input_index\":0,\"mtime_unix_seconds\":null,\"destination_policy\":\"follow\"}\n";
    for ([_][]const u8{ link, follow }) |request| {
        try std.testing.expectEqual(guest_agent_fuzz_copy_request, spore_agent_fuzz_build_request(request.ptr, request.len, request[0..0].ptr, 0));
    }

    const invalid = [_][]const u8{
        link[0 .. link.len - 1],
        link[0 .. link.len - 2] ++ " trailing\n",
        "{\"type\":\"spore-build-copy-v5\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"auto\",\"dest_is_dir\":false,\"entry_count\":0,\"source_disk\":\"build_input\",\"input_index\":0,\"mtime_unix_seconds\":null}\n",
        "{\"type\":\"spore-build-copy-v5\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"auto\",\"dest_is_dir\":false,\"entry_count\":0,\"source_disk\":\"build_input\",\"input_index\":0,\"mtime_unix_seconds\":null,\"destination_policy\":\"merge\"}\n",
        "{\"type\":\"spore-build-copy-v5\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"auto\",\"dest_is_dir\":false,\"entry_count\":0,\"source_disk\":\"build_input\",\"input_index\":0,\"mtime_unix_seconds\":null,\"destination_policy\":\"link\",\"destination_policy\":\"link\"}\n",
        "{\"type\":\"spore-build-copy-v5\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"file\",\"dest_is_dir\":false,\"entry_count\":1,\"source_disk\":\"context\",\"input_index\":0,\"mtime_unix_seconds\":null,\"destination_policy\":\"link\"}\n",
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

test "build shell-form RUN request streams its command" {
    const request = try runRequest(std.testing.allocator, "spore-build-1", .{ .shell = "echo ok" }, &.{"PATH=/usr/bin"}, "/work", default_build_nofile, std.testing.io);
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.endsWith(u8, request, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, request, "\"spore-build-run-v4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"stdio\":\"pipe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"command_len\":7,\"argv\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"cache_mounts\":[],\"context_binds\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"nofile_soft\":65536") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"nofile_hard\":65536") != null);
}

const over_limit_shell_request = "{\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":65537,\"argv\":[],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[],\"context_binds\":[],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n";

fn rawExecRequestForTest(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    const payload = struct {
        type: []const u8 = "spore-build-run-v4",
        session_id: []const u8 = "spore-build-test",
        resume_time_unix_ns: u64 = 1,
        command_len: usize = 0,
        argv: []const []const u8,
        env: []const []const u8 = &.{},
        working_dir: []const u8 = "/",
        cache_mounts: []const []const u8 = &.{},
        context_binds: []const []const u8 = &.{},
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
    try std.testing.expect(std.mem.indexOf(u8, request, "\"spore-build-run-v4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"command_len\":0,\"argv\":[\"printf\",\"%s|%s\",\"two words\",\"\",\"$VALUE\",\"control\\u0001\"]") != null);
    if (comptime guest_agent_fuzz_supported) {
        try std.testing.expectEqual(guest_agent_fuzz_run_complete, spore_agent_fuzz_build_request(request.ptr, request.len, request[0..0].ptr, 0));
    }

    try std.testing.expectError(error.RunArgCountUnsupported, runRequest(std.testing.allocator, "spore-build-1", .{ .exec = &.{} }, &.{}, "/", default_build_nofile, std.testing.io));
    try std.testing.expectError(error.RunArgUnsupported, runRequest(std.testing.allocator, "spore-build-1", .{ .exec = &.{""} }, &.{}, "/", default_build_nofile, std.testing.io));

    const sixteen: [max_run_exec_args][]const u8 = @splat("x");
    const max_count_request = try runRequest(std.testing.allocator, "spore-build-1", .{ .exec = &sixteen }, &.{}, "/", default_build_nofile, std.testing.io);
    defer std.testing.allocator.free(max_count_request);
    const seventeen: [max_run_exec_args + 1][]const u8 = @splat("x");
    try std.testing.expectError(error.RunArgCountUnsupported, runRequest(std.testing.allocator, "spore-build-1", .{ .exec = &seventeen }, &.{}, "/", default_build_nofile, std.testing.io));

    const max_bytes_request = try runRequest(std.testing.allocator, "spore-build-1", .{ .exec = &.{test_support.repeat("x", max_run_exec_args_bytes)} }, &.{}, "/", default_build_nofile, std.testing.io);
    defer std.testing.allocator.free(max_bytes_request);
    try std.testing.expectError(error.RunRequestTooLarge, runRequest(std.testing.allocator, "spore-build-1", .{ .exec = &.{test_support.repeat("x", (max_run_exec_args_bytes + 1))} }, &.{}, "/", default_build_nofile, std.testing.io));

    if (comptime guest_agent_fuzz_supported) {
        try std.testing.expectEqual(guest_agent_fuzz_run_complete, spore_agent_fuzz_build_request(max_count_request.ptr, max_count_request.len, max_count_request[0..0].ptr, 0));
        try std.testing.expectEqual(guest_agent_fuzz_run_complete, spore_agent_fuzz_build_request(max_bytes_request.ptr, max_bytes_request.len, max_bytes_request[0..0].ptr, 0));
        const too_many_request = try rawExecRequestForTest(std.testing.allocator, &seventeen);
        defer std.testing.allocator.free(too_many_request);
        try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(too_many_request.ptr, too_many_request.len, too_many_request[0..0].ptr, 0));
        const too_large_request = try rawExecRequestForTest(std.testing.allocator, &.{test_support.repeat("x", (max_run_exec_args_bytes + 1))});
        defer std.testing.allocator.free(too_large_request);
        try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(too_large_request.ptr, too_large_request.len, too_large_request[0..0].ptr, 0));
    }

    const escaped_controls = test_support.repeat("\x01", 1366);
    try std.testing.expectError(error.RunRequestTooLarge, validateRunRequest(std.testing.allocator, .{ .exec = &.{ "printf", escaped_controls } }, &.{"PATH=/usr/bin"}, "/", default_build_nofile));
}

test "cache-mounted RUN request carries an exact mount list" {
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
        &.{},
        std.testing.io,
    );
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"spore-build-run-v4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"command_len\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"target\":\"/var/cache/apt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"target\":\"/work/relative\"") != null);
    if (comptime guest_agent_fuzz_supported) {
        try std.testing.expectEqual(guest_agent_fuzz_run_complete, spore_agent_fuzz_build_request(request.ptr, request.len, request[0..0].ptr, 0));
        const reused_key = "{\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[{\"target\":\"/one\",\"key\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"},{\"target\":\"/two\",\"key\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}],\"context_binds\":[],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n";
        try std.testing.expectEqual(guest_agent_fuzz_run_complete, spore_agent_fuzz_build_request(reused_key.ptr, reused_key.len, reused_key[0..0].ptr, 0));
        const malformed = [_][]const u8{
            request[0 .. request.len - 1],
            "{\"type\":\"spore-build-run-v4\"}\n",
            "{\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[{\"target\":\"/cache/../escape\",\"key\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}],\"context_binds\":[],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
            "{\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[{\"target\":\"/cache\",\"key\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"}],\"context_binds\":[],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
            "{\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[{\"target\":\"/cache\",\"key\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"},{\"target\":\"/cache/nested\",\"key\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}],\"context_binds\":[],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
        };
        for (malformed) |raw| {
            try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(raw.ptr, raw.len, raw[0..0].ptr, 0));
        }
    }
}

test "context-bind RUN request carries exact shell-form binds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const caches = try cache_mount.resolve(arena, "/work", &.{"/cache"});
    const binds = [_]ContextBindMount{
        .{
            .source = "Gemfile",
            .target = "/work/Gemfile",
            .mode = 0o644,
            .content_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .transport_source = "s0/Gemfile",
        },
        .{
            .source = "Gemfile.lock",
            .target = "/work/Gemfile.lock",
            .mode = 0o644,
            .content_digest = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            .transport_source = "s1/Gemfile.lock",
        },
    };
    const request = try runRequestWithMounts(
        std.testing.allocator,
        "spore-build-1",
        .{ .shell = "cat Gemfile" },
        &.{"PATH=/usr/bin"},
        "/work",
        default_build_nofile,
        caches,
        &binds,
        std.testing.io,
    );
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"spore-build-run-v4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"source\":\"s0/Gemfile\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"target\":\"/work/Gemfile.lock\"") != null);
    var protected = binds;
    protected[0].target = "/proc/input";
    try std.testing.expectError(error.RunContextBindPathUnsupported, validateRunRequestWithContextBinds(
        arena,
        .{ .shell = "true" },
        &.{},
        "/",
        default_build_nofile,
        &.{},
        &protected,
    ));
    if (comptime guest_agent_fuzz_supported) {
        try std.testing.expectEqual(guest_agent_fuzz_run_request, spore_agent_fuzz_build_request(request.ptr, request.len, request[0..0].ptr, 0));
        const malformed = [_][]const u8{
            "{\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":1,\"argv\":[],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[],\"context_binds\":[{\"source\":\"../x\",\"target\":\"/x\"}],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
            "{\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":1,\"argv\":[],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[],\"context_binds\":[{\"source\":\"x\",\"target\":\"/proc/x\"}],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
            "{\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":1,\"argv\":[],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[],\"context_binds\":[{\"source\":\"x\",\"target\":\"/run/buildkit/ssh_agent.0\"}],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
            "{\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[],\"context_binds\":[{\"source\":\"x\",\"target\":\"/x\"}],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
            "{\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":1,\"argv\":[],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[{\"target\":\"/x\",\"key\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}],\"context_binds\":[{\"source\":\"x\",\"target\":\"/x\"}],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
        };
        for (malformed) |raw| try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(raw.ptr, raw.len, raw[0..0].ptr, 0));

        const duplicate_source = try std.mem.replaceOwned(
            u8,
            std.testing.allocator,
            request,
            "\"source\":\"s0/Gemfile\"",
            "\"source\":\"s0/Gemfile\",\"source\":\"s0/Gemfile\"",
        );
        defer std.testing.allocator.free(duplicate_source);
        try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(duplicate_source.ptr, duplicate_source.len, duplicate_source[0..0].ptr, 0));

        const unknown_field = try std.mem.replaceOwned(
            u8,
            std.testing.allocator,
            request,
            "\"source\":\"s0/Gemfile\"",
            "\"source\":\"s0/Gemfile\",\"readonly\":true",
        );
        defer std.testing.allocator.free(unknown_field);
        try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(unknown_field.ptr, unknown_field.len, unknown_field[0..0].ptr, 0));

        const trailing_bytes = try std.fmt.allocPrint(std.testing.allocator, "{s}x\n", .{request});
        defer std.testing.allocator.free(trailing_bytes);
        try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(trailing_bytes.ptr, trailing_bytes.len, trailing_bytes[0..0].ptr, 0));
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

test "builder and runtime share bounded guest PATH resolution" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;

    const io = std.testing.io;
    const root = try std.fmt.allocPrint(std.testing.allocator, "/tmp/sporevm-path-resolution-{d}", .{std.c.getpid()});
    defer std.testing.allocator.free(root);
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const root_dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer root_dir.close(io);
    try root_dir.createDirPath(io, "bin");
    try root_dir.createDirPath(io, "fallback");
    try root_dir.createDirPath(io, "sub");
    const executable = try root_dir.createFile(io, "bin/tool", .{ .permissions = .executable_file });
    executable.close(io);
    const fallback = try root_dir.createFile(io, "fallback/node", .{ .permissions = .executable_file });
    fallback.close(io);
    const fifo_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/bin/node", .{root}, 0);
    defer std.testing.allocator.free(fifo_path);
    try std.testing.expectEqual(@as(c_int, 0), mkfifo(fifo_path, 0o755));

    var resolved: [512]u8 = undefined;
    const empty = "";
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(std.posix.E.NOENT)),
        spore_agent_test_resolve_exec_path("tool", 4, empty, 0, 0, &resolved, resolved.len),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(std.posix.E.NOENT)),
        spore_agent_test_resolve_exec_path("tool", 4, empty, 0, 1, &resolved, resolved.len),
    );

    const normal_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/missing:{s}/bin", .{ root, root });
    defer std.testing.allocator.free(normal_path);
    try std.testing.expectEqual(
        @as(c_int, 0),
        spore_agent_test_resolve_exec_path("tool", 4, normal_path.ptr, normal_path.len, 1, &resolved, resolved.len),
    );
    const expected_normal = try std.fmt.allocPrint(std.testing.allocator, "{s}/bin/tool", .{root});
    defer std.testing.allocator.free(expected_normal);
    try std.testing.expectEqualStrings(expected_normal, std.mem.sliceTo(&resolved, 0));

    const node_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/bin:{s}/fallback", .{ root, root });
    defer std.testing.allocator.free(node_path);
    try std.testing.expectEqual(
        @as(c_int, 0),
        spore_agent_test_resolve_exec_path("node", 4, node_path.ptr, node_path.len, 1, &resolved, resolved.len),
    );
    const expected_node = try std.fmt.allocPrint(std.testing.allocator, "{s}/fallback/node", .{root});
    defer std.testing.allocator.free(expected_node);
    try std.testing.expectEqualStrings(expected_node, std.mem.sliceTo(&resolved, 0));

    const traversal_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/sub/../bin", .{root});
    defer std.testing.allocator.free(traversal_path);
    try std.testing.expectEqual(
        @as(c_int, 0),
        spore_agent_test_resolve_exec_path("tool", 4, traversal_path.ptr, traversal_path.len, 1, &resolved, resolved.len),
    );
    const expected_traversal = try std.fmt.allocPrint(std.testing.allocator, "{s}/sub/../bin/tool", .{root});
    defer std.testing.allocator.free(expected_traversal);
    try std.testing.expectEqualStrings(expected_traversal, std.mem.sliceTo(&resolved, 0));

    const first_entry = try std.fmt.allocPrint(std.testing.allocator, "{s}/bin", .{root});
    defer std.testing.allocator.free(first_entry);
    const max_entries = try std.testing.allocator.alloc(u8, first_entry.len + 63 * 2);
    defer std.testing.allocator.free(max_entries);
    @memcpy(max_entries[0..first_entry.len], first_entry);
    for (0..63) |i| {
        max_entries[first_entry.len + i * 2] = ':';
        max_entries[first_entry.len + i * 2 + 1] = '/';
    }
    try std.testing.expectEqual(
        @as(c_int, 0),
        spore_agent_test_resolve_exec_path("tool", 4, max_entries.ptr, max_entries.len, 1, &resolved, resolved.len),
    );

    const too_many_entries = try std.testing.allocator.alloc(u8, first_entry.len + 64 * 2);
    defer std.testing.allocator.free(too_many_entries);
    @memcpy(too_many_entries[0..first_entry.len], first_entry);
    for (0..64) |i| {
        too_many_entries[first_entry.len + i * 2] = ':';
        too_many_entries[first_entry.len + i * 2 + 1] = '/';
    }
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(std.posix.E.@"2BIG")),
        spore_agent_test_resolve_exec_path("tool", 4, too_many_entries.ptr, too_many_entries.len, 1, &resolved, resolved.len),
    );

    const max_path = try std.testing.allocator.alloc(u8, 250);
    defer std.testing.allocator.free(max_path);
    const prefix_len = max_path.len - first_entry.len - 1;
    @memset(max_path[0..prefix_len], 'x');
    max_path[0] = '/';
    max_path[prefix_len] = ':';
    @memcpy(max_path[prefix_len + 1 ..], first_entry);
    try std.testing.expectEqual(
        @as(c_int, 0),
        spore_agent_test_resolve_exec_path("tool", 4, max_path.ptr, max_path.len, 1, &resolved, resolved.len),
    );

    const long_path = test_support.repeat("/", 251);
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(std.posix.E.NAMETOOLONG)),
        spore_agent_test_resolve_exec_path("missing", 7, long_path, long_path.len, 1, &resolved, resolved.len),
    );

    const long_command = test_support.repeat("x", 511);
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(std.posix.E.NAMETOOLONG)),
        spore_agent_test_resolve_exec_path(long_command, long_command.len, "/bin", 4, 1, &resolved, resolved.len),
    );
}

const AgentResult = struct {
    stdout: []u8,
    stderr: []u8,
    /// The offsets of the first stdout and stderr frames.
    stdout_offset: ?u64,
    stderr_offset: ?u64,
    exit_code: ?u32,
    captured_stdout: u64,

    fn deinit(self: AgentResult) void {
        std.testing.allocator.free(self.stdout);
        std.testing.allocator.free(self.stderr);
    }
};

// Runs `argv` the way `spore vm exec` does, with `stdin` streamed and closed,
// while the guest agent's captured session runs `/bin/sh -c captured_script`.
fn execBesideCapturedSession(captured_script: [*:0]const u8, argv: []const []const u8, stdin: []const u8) !AgentResult {
    const spore_stream = @import("../spore_stream.zig");
    const allocator = std.testing.allocator;

    const request = try guest_request.interactiveExecRequestWithSession(allocator, argv, "exec-1", .{});
    defer allocator.free(request);
    var input: [2 * spore_stream.header_len + 64]u8 = undefined;
    const data = if (stdin.len == 0) input[0..0] else try spore_stream.writeFrame(input[0..], .{ .frame_type = .data, .stream_id = .stdin }, stdin);
    const close = try spore_stream.writeFrame(input[data.len..], .{ .frame_type = .close, .stream_id = .stdin, .offset = stdin.len }, "");
    const with_input = try std.mem.concat(allocator, u8, &.{ request, input[0 .. data.len + close.len] });
    defer allocator.free(with_input);
    return agentServeRequests(.{ .captured_script = captured_script }, &.{with_input});
}

// What the guest agent is doing when agentServeRequests sends its requests.
const AgentScenario = struct {
    /// Runs as the captured session, through `/bin/sh -c`.
    captured_script: [*:0]const u8 = "read line",
    /// Waits for the captured session to finish first.
    captured_finishes: bool = false,
    /// When nonempty, another client sends this first and stays attached
    /// until the first request arrives, then hangs up.
    attach: []const u8 = "",
};

// Sends each request, with any input frames appended, to the guest agent as
// one client after another, and decodes the SPIO reply to the last request.
fn agentServeRequests(scenario: AgentScenario, requests: []const []const u8) !AgentResult {
    const spore_stream = @import("../spore_stream.zig");
    const allocator = std.testing.allocator;

    const joined = try std.mem.concat(allocator, u8, requests);
    defer allocator.free(joined);
    const lens = try allocator.alloc(usize, requests.len);
    defer allocator.free(lens);
    for (requests, lens) |request, *len| len.* = request.len;
    const response = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(response);
    var captured_stdout: u64 = 0;
    const response_len = spore_agent_test_serve_requests(scenario.captured_script, @intFromBool(scenario.captured_finishes), scenario.attach.ptr, scenario.attach.len, joined.ptr, lens.ptr, requests.len, response.ptr, response.len, &captured_stdout);
    if (response_len < 0) return error.AgentHarnessFailed;

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(allocator);
    var stdout_offset: ?u64 = null;
    var stderr_offset: ?u64 = null;
    var exit_code: ?u32 = null;
    var rest = response[0..@intCast(response_len)];
    while (rest.len >= spore_stream.header_len) {
        const header = try spore_stream.readHeader(rest[0..spore_stream.header_len]);
        const payload = rest[spore_stream.header_len..][0..header.payload_len];
        if (header.frame_type == .data and header.stream_id == .stdout) {
            if (stdout_offset == null) stdout_offset = header.offset;
            try stdout.appendSlice(allocator, payload);
        }
        if (header.frame_type == .data and header.stream_id == .stderr) {
            if (stderr_offset == null) stderr_offset = header.offset;
            try stderr.appendSlice(allocator, payload);
        }
        if (header.frame_type == .exit) exit_code = try spore_stream.readExitPayload(payload);
        rest = rest[spore_stream.header_len + payload.len ..];
    }
    return .{
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
        .stdout_offset = stdout_offset,
        .stderr_offset = stderr_offset,
        .exit_code = exit_code,
        .captured_stdout = captured_stdout,
    };
}

test "guest agent runs named exec beside a running captured session" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;

    const result = try execBesideCapturedSession("read line", &.{ "/bin/sh", "-c", "read line; echo beside:$line" }, "hi\n");
    defer result.deinit();
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqualStrings("beside:hi\n", result.stdout);
    try std.testing.expectEqual(@as(?u32, 0), result.exit_code);
}

test "guest agent gives a null-stdio exec /dev/null stdin" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;

    const request = try guest_request.execRequestWithSession(std.testing.allocator, &.{ "/bin/sh", "-c", "cat; echo stdin-closed" }, "exec-1", 0);
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"stdio\":\"null\"") != null);
    const result = try agentServeRequests(.{}, &.{request});
    defer result.deinit();
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqualStrings("stdin-closed\n", result.stdout);
    try std.testing.expectEqual(@as(?u32, 0), result.exit_code);
}

test "guest agent answers a legacy start request with an SPIO bad request" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;

    const legacy = "{\"type\":\"start\",\"session_id\":\"exec-1\",\"resume_time_unix_ns\":0,\"argv\":[\"/bin/true\"],\"env\":[],\"working_dir\":\"\",\"memory_pressure\":false,\"params_json\":\"\",\"require_generation_ready\":false,\"closed_env\":true}\n";
    const result = try agentServeRequests(.{}, &.{legacy});
    defer result.deinit();
    try std.testing.expectEqualStrings("spore run: bad request\n", result.stderr);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqual(@as(?u32, 2), result.exit_code);
}

test "guest agent keeps a named exec whose request arrives as the attached client hangs up" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // `spore attach` to the captured session ends just as `spore vm exec`
    // connects. The agent sees both in one poll and must not take the
    // attached client's hangup for the exec's.
    const attach = try @import("../attach_stream.zig").attachV1Request(allocator, .{ .session_id = "captured" });
    defer allocator.free(attach);
    const request = try guest_request.execRequestWithSession(allocator, &.{ "/bin/sh", "-c", "echo beside" }, "exec-1", 0);
    defer allocator.free(request);
    const result = try agentServeRequests(.{ .attach = attach }, &.{request});
    defer result.deinit();
    try std.testing.expectEqual(@as(?u32, 0), result.exit_code);
    try std.testing.expectEqualStrings("beside\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "guest agent drains the captured session while a named exec runs" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "drain");
    const dir = try tmp.dir.realPathFileAlloc(io, "drain", allocator);
    defer allocator.free(dir);

    // The captured workload writes more than a pipe holds, then leaves a
    // marker. The exec waits up to 10s for the marker, so it only succeeds if
    // the agent keeps reading the captured output while the exec runs. A
    // default pipe holds 16 pages, at most 1 MiB with 64 KiB pages.
    const max_pipe_bytes = 1024 * 1024;
    const captured_bytes = 4 * max_pipe_bytes;
    const captured_script = try std.fmt.allocPrintSentinel(allocator, "head -c {d} /dev/zero && : > '{s}/written'", .{ captured_bytes, dir }, 0);
    defer allocator.free(captured_script);
    const wait_script = try std.fmt.allocPrint(allocator, "i=0; while [ ! -e '{s}/written' ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; [ -e '{s}/written' ] && echo beside:written", .{ dir, dir });
    defer allocator.free(wait_script);

    const result = try execBesideCapturedSession(captured_script.ptr, &.{ "/bin/sh", "-c", wait_script }, "");
    defer result.deinit();
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqualStrings("beside:written\n", result.stdout);
    try std.testing.expectEqual(@as(?u32, 0), result.exit_code);
    // At most one pipe of output can still be unread when the marker appears.
    try std.testing.expect(result.captured_stdout >= captured_bytes - max_pipe_bytes);
}

test "guest agent replays an exec that followed the captured session" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // In a VM captured after its command exited, the next exec becomes the
    // session. Its output must be retained like the first command's, so an
    // attach from offset zero replays all of it.
    const start = try guest_request.execRequestWithSession(allocator, &.{ "/bin/sh", "-c", "echo out; echo err >&2" }, "exec-1", 0);
    defer allocator.free(start);
    const attach = try @import("../attach_stream.zig").attachV1Request(allocator, .{ .session_id = "exec-1" });
    defer allocator.free(attach);
    const result = try agentServeRequests(.{ .captured_script = "true", .captured_finishes = true }, &.{ start, attach });
    defer result.deinit();
    try std.testing.expectEqualStrings("out\n", result.stdout);
    try std.testing.expectEqualStrings("err\n", result.stderr);
    try std.testing.expectEqual(@as(?u32, 0), result.exit_code);
}

test "guest agent refuses an attach at the offsets it was asked to resume from" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // The host's stream expects the refusal's stderr where the saved
    // session's stderr left off, not at zero.
    const attach = try @import("../attach_stream.zig").attachV1Request(allocator, .{ .session_id = "other", .stdout_offset = 3, .stderr_offset = 5 });
    defer allocator.free(attach);
    const result = try agentServeRequests(.{}, &.{attach});
    defer result.deinit();
    try std.testing.expectEqualStrings("spore run: no session\n", result.stderr);
    try std.testing.expectEqual(@as(?u64, 5), result.stderr_offset);
    try std.testing.expectEqual(@as(?u32, 2), result.exit_code);
}

test "guest agent resumes a session's output from as far back as a save leaves the host" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const attach_stream = @import("../attach_stream.zig");

    // More output than the agent keeps, so its replay buffer has wrapped.
    // `seq` writes whole 4 KiB pages; the leading byte stops the agent's reads
    // from ending exactly at the ring's end, so one read's append crosses it.
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    try expected.append(allocator, 'x');
    for (1..60_001) |i| try expected.print(allocator, "{d}\n", .{i});
    const total = expected.items.len;
    var limits: GuestRequestLimits = undefined;
    spore_agent_test_request_limits(&limits);
    try std.testing.expect(total > limits.replay_bytes);
    const scenario: AgentScenario = .{ .captured_script = "printf x; seq 1 60000", .captured_finishes = true };

    // The furthest a `spore run` save can trail the agent.
    const lag: usize = @intCast(limits.output_read_bytes + @import("../virtio/vsock.zig").host_stream_credit);
    const behind = try attach_stream.attachV1Request(allocator, .{ .session_id = "captured", .stdout_offset = total - lag });
    defer allocator.free(behind);
    const resumed = try agentServeRequests(scenario, &.{behind});
    defer resumed.deinit();
    try std.testing.expectEqual(@as(?u64, total - lag), resumed.stdout_offset);
    try std.testing.expectEqualSlices(u8, expected.items[total - lag ..], resumed.stdout);
    try std.testing.expectEqual(@as(?u32, 0), resumed.exit_code);

    // An attach where the output ends gets only the exit.
    const at_end = try attach_stream.attachV1Request(allocator, .{ .session_id = "captured", .stdout_offset = total });
    defer allocator.free(at_end);
    const caught_up = try agentServeRequests(scenario, &.{at_end});
    defer caught_up.deinit();
    try std.testing.expectEqualStrings("", caught_up.stdout);
    try std.testing.expectEqual(@as(?u32, 0), caught_up.exit_code);

    // Output older than the agent keeps is gone.
    const too_far = try attach_stream.attachV1Request(allocator, .{ .session_id = "captured", .stdout_offset = total - @as(usize, @intCast(limits.replay_bytes)) - 1 });
    defer allocator.free(too_far);
    const refused = try agentServeRequests(scenario, &.{too_far});
    defer refused.deinit();
    try std.testing.expectEqualStrings("spore run: requested replay offset is unavailable\n", refused.stderr);
    try std.testing.expectEqual(@as(?u32, 125), refused.exit_code);
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
        .memory = .{ .initial_bytes = 0, .maximum_bytes = 0 },
    }).validate());
    try std.testing.expectError(error.UnsupportedVcpuCount, (RunResources{ .vcpus = 0 }).validate());
    try std.testing.expectError(error.InvalidBuildNofileLimit, (RunResources{
        .nofile = .{ .soft = 2, .hard = 1 },
    }).validate());
}

test "build run request accepts multi-kib command and rejects configured bound" {
    const multi_kib = test_support.repeat("x", 4096);
    const request = try runRequest(std.testing.allocator, "spore-build-1", .{ .shell = multi_kib }, &.{}, "/", default_build_nofile, std.testing.io);
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"command_len\":4096") != null);
    const command = test_support.repeat("x", (max_run_command_len + 1));
    try std.testing.expectError(error.RunCommandTooLong, runRequest(std.testing.allocator, "spore-build-1", .{ .shell = command }, &.{}, "/", default_build_nofile, std.testing.io));
    const workdir = test_support.repeat("/", (max_guest_working_dir_len + 1));
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

    try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(over_limit_shell_request.ptr, over_limit_shell_request.len, stream[0..0].ptr, 0));

    const empty_exec = try rawExecRequestForTest(std.testing.allocator, &.{});
    defer std.testing.allocator.free(empty_exec);
    try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(empty_exec.ptr, empty_exec.len, stream[0..0].ptr, 0));

    const reordered_exec = "{\"closed_env\":true,\"nofile_hard\":1,\"nofile_soft\":1,\"memory_pressure\":false,\"terminal_cols\":80,\"terminal_rows\":24,\"term\":\"xterm\",\"stdio\":\"pipe\",\"context_binds\":[],\"cache_mounts\":[],\"working_dir\":\"/\",\"env\":[],\"argv\":[\"true\"],\"command_len\":0,\"resume_time_unix_ns\":1,\"session_id\":\"s\",\"type\":\"spore-build-run-v4\"}\n";
    try std.testing.expectEqual(guest_agent_fuzz_run_complete, spore_agent_fuzz_build_request(reordered_exec.ptr, reordered_exec.len, stream[0..0].ptr, 0));

    const malformed_exec_requests = [_][]const u8{
        "{\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"command\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[],\"context_binds\":[],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
        "{\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"argv\":[\"true\",],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[],\"context_binds\":[],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
        "{\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[],\"context_binds\":[],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true} trailing\n",
        "{\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"argv\":[\"true\"],\"argv\":[\"false\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[],\"context_binds\":[],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
        "{\"type\":\"spore-build-run-v4\",\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[],\"context_binds\":[],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
        "{\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[],\"context_binds\":[],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true,\"unknown\":0}\n",
        "{\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[],\"context_binds\":[],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1}\n",
        "{\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[],\"context_binds\":[],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,}\n",
        "{\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"argv\":[\"line\nbreak\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[],\"context_binds\":[],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
        "{\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[],\"context_binds\":[],\"stdio\":\"tty\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
        "{\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[],\"context_binds\":[],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":01,\"nofile_hard\":1,\"closed_env\":true}\n",
        "{\"type\":\"start\",\"type\":\"spore-build-run-v4\",\"argv\":[\"/bin/true\"]}\n",
        "{\"type\":\"spore-build-run-v4\",\"type\":\"start\",\"argv\":[\"/bin/true\"]}\n",
        "{\"type\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":4,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[],\"context_binds\":[],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
    };
    for (malformed_exec_requests) |malformed| {
        try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(malformed.ptr, malformed.len, stream[0..0].ptr, 0));
    }

    const removed_versions = [_][]const u8{
        "{\"type\":\"spore-build-run-v1\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":3,\"env\":[],\"working_dir\":\"/\",\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
        "{\"type\":\"spore-build-run-v2\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
        "{\"type\":\"spore-build-run-v3\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[{\"target\":\"/one\",\"key\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n",
        "{\"type\":\"spore-build-copy-v2\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"file\",\"entry_count\":1}\n",
        "{\"type\":\"spore-build-copy-v3\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"file\",\"dest_is_dir\":false,\"entry_count\":1,\"source_disk\":\"context\"}\n",
        "{\"type\":\"spore-build-copy-v4\",\"session_id\":\"s\",\"source\":\"input\",\"dest\":\"/output\",\"source_kind\":\"file\",\"dest_is_dir\":false,\"entry_count\":1,\"source_disk\":\"context\",\"input_index\":0,\"mtime_unix_seconds\":null}\n",
    };
    for (removed_versions) |removed| {
        try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(removed.ptr, removed.len, stream[0..0].ptr, 0));
    }

    const missing_newline = reordered_exec[0 .. reordered_exec.len - 1];
    try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(missing_newline.ptr, missing_newline.len, stream[0..0].ptr, 0));

    const exactly_full = try std.testing.allocator.alloc(u8, max_guest_request_len);
    defer std.testing.allocator.free(exactly_full);
    @memcpy(exactly_full[0..missing_newline.len], missing_newline);
    @memset(exactly_full[missing_newline.len..], ' ');
    try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(exactly_full.ptr, exactly_full.len, stream[0..0].ptr, 0));

    const escaped_type_key = "{\"\\u0074ype\":\"spore-build-run-v4\",\"session_id\":\"s\",\"resume_time_unix_ns\":1,\"command_len\":0,\"argv\":[\"true\"],\"env\":[],\"working_dir\":\"/\",\"cache_mounts\":[],\"context_binds\":[],\"stdio\":\"pipe\",\"term\":\"xterm\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"nofile_soft\":1,\"nofile_hard\":1,\"closed_env\":true}\n";
    try std.testing.expectEqual(guest_agent_fuzz_run_complete, spore_agent_fuzz_build_request(escaped_type_key.ptr, escaped_type_key.len, stream[0..0].ptr, 0));

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

    const stale_resize_request = try guest_request.simpleControlRequest(std.testing.allocator, "spore-build-resize-v1", "spore-build-resize");
    defer std.testing.allocator.free(stale_resize_request);
    try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(stale_resize_request.ptr, stale_resize_request.len, stream[0..0].ptr, 0));

    const ready_request = "{\"type\":\"ready\"}\n";
    try std.testing.expectEqual(guest_agent_fuzz_ready_request, spore_agent_fuzz_build_request(ready_request.ptr, ready_request.len, stream[0..0].ptr, 0));
    const ready_with_nonce = "{\"type\":\"ready\",\"nonce\":\"1234\"}\n";
    try std.testing.expectEqual(guest_agent_fuzz_invalid, spore_agent_fuzz_build_request(ready_with_nonce.ptr, ready_with_nonce.len, stream[0..0].ptr, 0));

    const grow_request = try guest_request.simpleControlRequest(std.testing.allocator, "spore-rootfs-grow-v1", "spore-build-resize");
    defer std.testing.allocator.free(grow_request);
    try std.testing.expectEqual(guest_agent_fuzz_grow_request, spore_agent_fuzz_build_request(grow_request.ptr, grow_request.len, stream[0..0].ptr, 0));
}

fn expectGuestRequestKind(expected: c_int, request: []const u8) !void {
    std.testing.expectEqual(expected, spore_agent_fuzz_build_request(request.ptr, request.len, request[0..0].ptr, 0)) catch |err| {
        std.debug.print("guest request: {s}\n", .{request});
        return err;
    };
}

fn expectGuestRequestEdit(expected: c_int, base: []const u8, edits: []const [2][]const u8) !void {
    const allocator = std.testing.allocator;
    var request = try allocator.dupe(u8, base);
    defer allocator.free(request);
    for (edits) |edit| {
        try std.testing.expect(std.mem.indexOf(u8, request, edit[0]) != null);
        const next = try std.mem.replaceOwned(u8, allocator, request, edit[0], edit[1]);
        allocator.free(request);
        request = next;
    }
    try expectGuestRequestKind(expected, request);
}

test "guest agent parses exec and control requests strictly" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const attach_stream = @import("../attach_stream.zig");
    const start = guest_agent_fuzz_start_request;
    const attach = guest_agent_fuzz_attach_request;
    const other = guest_agent_fuzz_other_request;
    const invalid = guest_agent_fuzz_invalid;

    const null_start = try guest_request.execRequestWithSession(allocator, &.{"/bin/true"}, "s", 1);
    defer allocator.free(null_start);
    try expectGuestRequestKind(start, null_start);
    const pipe_start = try guest_request.interactiveExecRequestWithSession(allocator, &.{"/bin/cat"}, "s", .{ .working_dir = "/work" });
    defer allocator.free(pipe_start);
    try expectGuestRequestKind(start, pipe_start);
    const tty_start = try guest_request.interactiveExecRequestWithSession(allocator, &.{"/bin/sh"}, "s", .{ .tty = true, .terminal_size = .{ .rows = 65535, .cols = 1 } });
    defer allocator.free(tty_start);
    try expectGuestRequestKind(start, tty_start);
    const detached_start = try guest_request.detachedExecRequestWithSessionContext(allocator, &.{"/bin/true"}, "s", .{ .retain_output = true });
    defer allocator.free(detached_start);
    try expectGuestRequestKind(start, detached_start);

    // Each edit of a valid start-v1 request breaks one rule.
    const start_rejects = [_][]const [2][]const u8{
        &.{.{ "\"type\":\"start-v1\"", "\"type\":\"start\"" }},
        &.{.{ "\"type\":\"start-v1\",", "" }},
        &.{.{ ",\"closed_env\":true", "" }},
        &.{.{ "\"closed_env\":true", "\"closed_env\":false" }},
        &.{.{ "\"closed_env\":true", "\"closed_env\":true,\"closed_env\":true" }},
        &.{.{ "\"closed_env\":true", "\"closed_env\":true,\"interactive\":false" }},
        &.{.{ "\"closed_env\":true", "\"closed_env\":true,\"nonce\":\"1\"" }},
        &.{.{ "\"stdio\":\"null\"", "\"stdio\":\"file\"" }},
        &.{ .{ "\"stdio\":\"null\"", "\"stdio\":\"pipe\"" }, .{ "\"detached\":false", "\"detached\":true" } },
        &.{.{ "\"retain_output\":false", "\"retain_output\":true" }},
        &.{.{ "\"working_dir\":\"\"", "\"working_dir\":\"work\"" }},
        &.{.{ "\"argv\":[\"/bin/true\"]", "\"argv\":[]" }},
        &.{.{ "\"terminal_rows\":24", "\"terminal_rows\":65536" }},
        &.{.{ "\"terminal_rows\":24", "\"terminal_rows\":0" }},
        &.{.{ "\"terminal_cols\":80", "\"terminal_cols\":0" }},
        &.{.{ "\"stdio\":\"null\"", "\"stdio\":\"null\",\"term\":\"xterm\"" }},
        &.{.{ "\"session_id\":\"s\"", "\"session_id\":\"\"" }},
        &.{.{ "}\n", "}" }},
    };
    for (start_rejects) |edits| try expectGuestRequestEdit(invalid, null_start, edits);

    const null_attach = try attach_stream.attachV1Request(allocator, .{ .session_id = "s" });
    defer allocator.free(null_attach);
    try expectGuestRequestKind(attach, null_attach);
    const pipe_attach = try attach_stream.attachV1Request(allocator, .{ .session_id = "s", .interactive = true });
    defer allocator.free(pipe_attach);
    try expectGuestRequestKind(attach, pipe_attach);
    const tty_attach = try attach_stream.attachV1Request(allocator, .{ .session_id = "s", .tty = true });
    defer allocator.free(tty_attach);
    try expectGuestRequestKind(attach, tty_attach);

    const attach_rejects = [_][]const [2][]const u8{
        &.{.{ "\"type\":\"attach-v1\"", "\"type\":\"attach\"" }},
        &.{.{ "\"stdio\":\"null\"", "\"stdio\":\"pipe\"" }},
        &.{.{ "\"interactive\":false", "\"interactive\":true" }},
        &.{.{ "\"stdout_offset\":0,", "" }},
        &.{.{ "\"params_json\":\"\"", "\"params_json\":\"\",\"detached\":false" }},
        &.{.{ "\"params_json\":\"\"", "\"params_json\":\"\",\"term\":\"xterm\"" }},
        &.{.{ "\"terminal_cols\":80", "\"terminal_cols\":0" }},
    };
    for (attach_rejects) |edits| try expectGuestRequestEdit(invalid, null_attach, edits);

    const freeze = try guest_request.simpleControlRequest(allocator, "fsfreeze-v1", "spore-run-commit-freeze");
    defer allocator.free(freeze);
    try expectGuestRequestKind(other, freeze);
    const thaw = try guest_request.simpleControlRequest(allocator, "fsthaw-v1", "spore-run-commit-thaw");
    defer allocator.free(thaw);
    try expectGuestRequestKind(other, thaw);
    try expectGuestRequestKind(other, "{\"type\":\"initial-output\"}\n");
    try expectGuestRequestKind(other, "{\"type\":\"copy-in-v1\",\"session_id\":\"s\",\"path\":\"/in\"}\n");
    try expectGuestRequestKind(other, "{\"type\":\"copy-out-v1\",\"session_id\":\"s\",\"path\":\"/out\"}\n");

    const control_rejects = [_][]const u8{
        "{\"type\":\"ready\",\"session_id\":\"s\"}\n",
        "{\"type\":\"fsfreeze-v1\"}\n",
        "{\"type\":\"fsthaw-v1\",\"session_id\":\"s\",\"path\":\"/\"}\n",
        "{\"type\":\"spore-build-workdir-v1\",\"working_dir\":\"/work\"}\n",
        "{\"type\":\"spore-build-workdir-v1\",\"session_id\":\"s\",\"working_dir\":\"work\"}\n",
        "{\"type\":\"generation\",\"session_id\":\"default\",\"params_json\":\"{}\"}\n",
        "{\"type\":\"initial-output\",\"session_id\":\"s\"}\n",
        "{\"type\":\"copy-in-v1\",\"session_id\":\"s\"}\n",
        "{\"type\":\"copy-out-v1\",\"session_id\":\"s\",\"path\":\"/a\",\"path\":\"/b\"}\n",
        "{\"session_id\":\"s\",\"path\":\"/in\"}\n",
    };
    for (control_rejects) |request| try expectGuestRequestKind(invalid, request);

    // Build RUN alone still carries term, pinned to xterm.
    const build_run = try runRequest(allocator, "spore-build-1", .{ .exec = &.{"true"} }, &.{}, "/", default_build_nofile, std.testing.io);
    defer allocator.free(build_run);
    try expectGuestRequestKind(guest_agent_fuzz_run_complete, build_run);
    try expectGuestRequestEdit(invalid, build_run, &.{.{ "\"term\":\"xterm\",", "" }});
    try expectGuestRequestEdit(invalid, build_run, &.{.{ "\"term\":\"xterm\"", "\"term\":\"xterm-256color\"" }});

    // The fuzz seeds are valid requests, and their variants are rejected.
    inline for (guest_exec_request_seeds) |seed| {
        try expectGuestRequestKind(seed.kind, seed.body ++ "}\n");
        try expectGuestRequestKind(invalid, seed.body ++ seed.last_member ++ "}\n");
        try expectGuestRequestKind(invalid, seed.body ++ guest_exec_request_unknown_member ++ "}\n");
    }
}

test "guest generation params are read only from their top-level members" {
    if (comptime !guest_agent_fuzz_supported) return error.SkipZigTest;
    const cases = [_]struct { params: []const u8, result: c_int, generation: u64 = 0, fork_index: u64 = 0, vm_id: []const u8 = "" }{
        .{ .params = "{\"generation\":7}", .result = 1, .generation = 7 },
        // A substring search for "generation": finds a nested key, or a key
        // that only ends in that text, before the real member.
        .{ .params = "{\"labels\":{\"generation\":5},\"generation\":7}", .result = 1, .generation = 7 },
        .{ .params = "{\"\\\"generation\":5,\"generation\":7}", .result = 1, .generation = 7 },
        .{ .params = "{\"labels\":{\"generation\":5}}", .result = 0 },
        .{ .params = "{\"vm_id\":\"\\\"generation\\\":5\",\"generation\":7}", .result = 1, .generation = 7, .vm_id = "\"generation\":5" },
        // Fork params as the host writes them, with members the agent skips.
        // The members the agent reads have distinct values, so reading the
        // generation, fork index or VM id from another member fails.
        .{ .params = "{\"schema_version\":0,\"parent_generation\":1,\"generation\":2,\"fork_index\":3,\"fork_count\":4,\"parallel_index\":5,\"parallel_count\":6,\"fork_batch_id\":\"0123456789abcdef0123456789abcdef\",\"vm_id\":\"spore-0123456789abcdef0123456789abcdef\",\"hostname\":\"spore-01234567-000000\",\"mac_seed\":\"0123456789abcdef0123456789abcdef\",\"mac_address\":\"02:00:00:00:00:01\"}", .result = 1, .generation = 2, .fork_index = 3, .vm_id = "spore-0123456789abcdef0123456789abcdef" },
        .{ .params = "{\"run_id\":\"r\",\"child_id\":7,\"note\":null,\"ok\":true,\"ratio\":-1.5e+3,\"tree\":[[{\"a\":[]}],{}],\"generation\":3}", .result = 1, .generation = 3 },
        .{ .params = " { } ", .result = 0 },
        .{ .params = "{\"tree\":" ++ test_support.repeat("[", 1900) ++ test_support.repeat("]", 1900) ++ ",\"generation\":4}", .result = 1, .generation = 4 },
        .{ .params = "{\"generation\":1,\"generation\":2}", .result = -1 },
        .{ .params = "{\"generation\":\"7\"}", .result = -1 },
        .{ .params = "{\"generation\":-1}", .result = -1 },
        .{ .params = "{\"generation\":1.5}", .result = -1 },
        .{ .params = "{\"generation\":07}", .result = -1 },
        .{ .params = "{\"hostname\":7}", .result = -1 },
        .{ .params = "{\"hostname\":\"" ++ test_support.repeat("h", 128) ++ "\"}", .result = -1 },
        .{ .params = "{\"generation\":7", .result = -1 },
        .{ .params = "{\"generation\":7}x", .result = -1 },
        .{ .params = "{\"generation\":7,}", .result = -1 },
        .{ .params = "{\"tree\":[1,]}", .result = -1 },
        .{ .params = "{\"tree\":{\"a\"}}", .result = -1 },
        .{ .params = "{\"ratio\":1.}", .result = -1 },
        .{ .params = "[]", .result = -1 },
        .{ .params = "", .result = -1 },
    };
    for (cases) |case| {
        var generation: u64 = 0;
        var fork_index: u64 = 0;
        var vm_id: [128]u8 = undefined;
        const result = spore_agent_test_generation_params(case.params.ptr, case.params.len, &generation, &fork_index, &vm_id);
        std.testing.expectEqual(case.result, result) catch |err| {
            std.debug.print("generation params: {s}\n", .{case.params});
            return err;
        };
        if (result == -1) continue;
        if (result == 1) try std.testing.expectEqual(case.generation, generation);
        try std.testing.expectEqual(case.fork_index, fork_index);
        try std.testing.expectEqualStrings(case.vm_id, std.mem.sliceTo(&vm_id, 0));
    }
    var generation: u64 = 0;
    var fork_index: u64 = 0;
    var vm_id: [128]u8 = undefined;
    const longest_hostname = "{\"hostname\":\"" ++ test_support.repeat("h", 127) ++ "\"}";
    try std.testing.expectEqual(@as(c_int, 0), spore_agent_test_generation_params(longest_hostname.ptr, longest_hostname.len, &generation, &fork_index, &vm_id));
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
    const noise = @as([4096]u8, @splat('x'));
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

// One fuzz call per test: the fuzzer keeps one corpus per test, and with a
// single test selected the first call would take every run.
test "fuzz build control request framing" {
    try std.testing.fuzz({}, fuzzSimpleRequest, .{});
}

test "fuzz build copy request framing" {
    try std.testing.fuzz({}, fuzzCopyRequest, .{});
}

test "fuzz guest build request parser" {
    try std.testing.fuzz({}, fuzzGuestBuildRequest, .{ .corpus = &guest_request_fuzz_corpus });
}

test "fuzz guest proc stat parser" {
    try std.testing.fuzz({}, fuzzGuestProcStat, .{});
}

test "fuzz guest build resolv target" {
    try std.testing.fuzz({}, fuzzGuestBuildResolvTarget, .{});
}

test "fuzz guest copy tree" {
    try std.testing.fuzz({}, fuzzGuestCopyTree, .{});
}
