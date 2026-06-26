//! Product API boundary used by the CLI and embedding layers.
//!
//! Import this module through `libspore`. Backend, device, storage, monitor, and
//! CLI modules stay internal; this file owns the product operations and result
//! contracts callers should build against.

const std = @import("std");

const bundle = @import("bundle.zig");
const contracts = @import("contracts.zig");
const context_mod = @import("context.zig");
const local_paths = @import("local_paths.zig");
const platform = @import("platform.zig");
const resume_mod = @import("resume.zig");
const run_mod = @import("run.zig");
const spore = @import("spore.zig");

/// Process context shared by product operations.
///
/// `Context` carries process IO and environment access without requiring
/// embedders to construct CLI argument vectors.
pub const Context = context_mod.Context;

/// Cache root selection for operations that materialize or read cached bytes.
///
/// `.env` uses the same environment-derived defaults as the CLI, `.none`
/// disables the optional cache, and `.path` uses an explicit caller path.
pub const CacheRoot = union(enum) {
    env,
    none,
    path: []const u8,
};

/// Host capability and cache summary returned by `hostInfo`.
///
/// The result owns `backends` and any resolved cache-root paths. Release it with
/// `deinitHostInfo` using the same allocator passed to `hostInfo`.
pub const HostInfo = struct {
    schema: []const u8 = platform.host_info_schema,
    schema_version: u32 = platform.host_info_schema_version,
    host_class: []const u8,
    platform: PlatformFacts,
    backends: []const BackendAvailability,
    cache_roots: CacheRoots,
};

pub const PlatformFacts = struct {
    os: []const u8,
    arch: []const u8,
    cpu_profile: []const u8,
    device_model_version: u32,
    ram_base: u64,
    gic_dist_base: u64,
    gic_redist_base: u64,
    counter_frequency_source: []const u8,
    counter_frequency_hz: u64,
};

pub const BackendAvailability = struct {
    name: []const u8,
    supported: bool,
    available: bool,
    reason: []const u8,
};

pub const CacheRoots = struct {
    kernels: PathFact,
    rootfs: PathFact,
    bundles: PathFact,
    runtime: PathFact,
};

pub const PathFact = struct {
    path: ?[]const u8,
    resolved: bool,
    source: []const u8,
};

/// Rootfs storage policy used when packing a spore into a bundle.
pub const RootfsBundlePolicy = enum {
    /// Include rootfs bytes so the bundle can be unpacked without the original cache.
    exact_bytes,
    /// Include only rootfs metadata; unpacking requires an already-populated cache.
    metadata_only,
};

/// Inclusive bundle child range.
pub const ChildRange = struct {
    start: u32,
    end: u32,
};

/// Options for read-only bundle inspection.
pub const InspectBundleOptions = struct {
    /// Local path or remote reference understood by SporeVM's bundle resolver.
    source: []const u8,
    /// Optional child id to summarize.
    child_id: ?[]const u8 = null,
    /// Optional child range to summarize.
    child_range: ?ChildRange = null,
};

pub const DigestRef = contracts.DigestRef;
pub const CacheState = contracts.CacheState;
pub const ChunkMaterializationSummary = contracts.ChunkMaterializationSummary;
pub const RootfsMaterializationSummary = contracts.RootfsMaterializationSummary;
pub const RemoteBundleCache = contracts.RemoteBundleCache;
pub const BundleChildrenSummary = contracts.BundleChildrenSummary;
pub const PullResult = contracts.PullResult;
pub const BundleChildSummary = contracts.BundleChildSummary;
pub const BundleSelectionSummary = contracts.BundleSelectionSummary;
pub const ChunkpackSummary = contracts.ChunkpackSummary;
pub const RootfsBundleSummary = contracts.RootfsBundleSummary;
pub const InspectBundleResult = contracts.InspectBundleResult;

pub const Backend = run_mod.Backend;
pub const MemoryConfig = run_mod.MemoryConfig;
pub const CaptureTrigger = run_mod.CaptureTrigger;
pub const NetworkMode = run_mod.NetworkMode;
pub const NetworkPolicy = run_mod.NetworkPolicy;
pub const Rootfs = run_mod.Rootfs;
pub const Disk = run_mod.Disk;
pub const RunResult = run_mod.Result;
pub const ResumeResult = run_mod.Result;
pub const RunEvent = run_mod.RunEvent;
pub const EventSink = run_mod.EventSink;
pub const ClassifiedFailure = run_mod.ClassifiedFailure;
pub const FailureCode = run_mod.FailureCode;
pub const FailureScope = run_mod.FailureScope;
pub const Timings = run_mod.Timings;
pub const StartEvent = run_mod.StartEvent;
pub const ReadyEvent = run_mod.ReadyEvent;
pub const OutputEvent = run_mod.OutputEvent;
pub const ExitEvent = run_mod.ExitEvent;
pub const FailureEvent = run_mod.FailureEvent;

/// Low-level VM run options.
///
/// Use this when the caller already has an explicit kernel and rootfs/disk
/// inputs. For CLI-like image/rootfs setup, use `runManaged`.
pub const RunOptions = struct {
    backend: Backend = .auto,
    kernel_path: []const u8,
    initrd_path: ?[]const u8 = null,
    rootfs_path: ?[]const u8 = null,
    rootfs: ?Rootfs = null,
    disk: ?Disk = null,
    /// Guest command and arguments. The first element is the executable.
    command: []const []const u8,
    guest_env: []const []const u8 = &.{},
    guest_working_dir: ?[]const u8 = null,
    memory: MemoryConfig = .{},
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    capture_path: ?[]const u8 = null,
    capture_trigger: CaptureTrigger = .exit,
    continue_after_capture: bool = false,
    network: NetworkMode = .disabled,
    network_policy: NetworkPolicy = .{},
    spore_executable: []const u8 = "spore",
    /// Optional synchronous event sink. Output byte slices are callback-scoped.
    events: ?EventSink = null,
};

/// CLI-like fresh run options.
///
/// `runManaged` resolves default kernel/initrd assets and can materialize an OCI
/// image reference before booting. It takes `std.process.Init` because this setup
/// path may spawn helper tools and read the process environment.
pub const ManagedRunOptions = struct {
    backend: Backend = .auto,
    kernel_path: ?[]const u8 = null,
    initrd_path: ?[]const u8 = null,
    rootfs_path: ?[]const u8 = null,
    image_ref: ?[]const u8 = null,
    /// Guest command and arguments. The first element is the executable.
    command: []const []const u8,
    memory: MemoryConfig = .{},
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    capture_path: ?[]const u8 = null,
    capture_trigger: CaptureTrigger = .exit,
    continue_after_capture: bool = false,
    network: NetworkMode = .disabled,
    network_policy: NetworkPolicy = .{},
    spore_executable: []const u8 = "spore",
    /// Optional synchronous event sink. Output byte slices are callback-scoped.
    events: ?EventSink = null,
};

/// Run a command from a captured spore directory.
///
/// This is the product API for `spore run --from`: it reads the manifest,
/// restores machine/rootfs/disk policy from the capture, then executes a new
/// guest command.
pub const RunFromSporeOptions = struct {
    backend: Backend = .auto,
    spore_dir: []const u8,
    /// Guest command and arguments. The first element is the executable.
    command: []const []const u8,
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    capture_path: ?[]const u8 = null,
    capture_trigger: CaptureTrigger = .exit,
    continue_after_capture: bool = false,
    spore_executable: []const u8 = "spore",
    /// Optional synchronous event sink. Output byte slices are callback-scoped.
    events: ?EventSink = null,
};

/// Resume a captured spore to its recorded continuation point.
pub const ResumeOptions = struct {
    backend: Backend = .auto,
    spore_dir: []const u8,
    spore_executable: []const u8 = "spore",
    /// Optional synchronous event sink. Output byte slices are callback-scoped.
    events: ?EventSink = null,
};

/// Options for creating child spores from a parent spore.
pub const ForkOptions = struct {
    parent_dir: []const u8,
    out_dir: []const u8,
    count: usize,
};

/// Result returned by `fork`.
///
/// `first_child` and `last_child` are owned and must be released with
/// `deinitForkResult`.
pub const ForkResult = struct {
    parent: []const u8,
    out_dir: []const u8,
    count: usize,
    parent_generation: u64,
    first_generation: u64,
    last_generation: u64,
    first_child: []const u8,
    last_child: []const u8,
};

/// Options for packing a spore directory into a portable bundle.
pub const PackOptions = struct {
    spore_dir: []const u8,
    out_dir: []const u8,
    rootfs_cache: CacheRoot = .env,
    children_dir: ?[]const u8 = null,
    rootfs_policy: RootfsBundlePolicy = .exact_bytes,
};

/// Result returned by `pack`.
///
/// `bundle_digest` is owned and must be released with `deinitPackResult`.
pub const PackResult = struct {
    source: []const u8,
    out_dir: []const u8,
    bundle_digest: []const u8,
    chunk_count: usize,
    packed_chunk_count: usize,
    pack_count: usize,
    payload_bytes: u64,
    rootfs_artifact_count: usize = 0,
    rootfs_payload_bytes: u64 = 0,
    child_count: usize = 0,
};

/// Options for unpacking a bundle into a spore directory.
pub const UnpackOptions = struct {
    bundle_dir: []const u8,
    out_dir: []const u8,
    rootfs_cache: CacheRoot = .env,
    child_id: ?[]const u8 = null,
    allow_metadata_only_rootfs: bool = false,
};

/// Result returned by `unpack`.
///
/// `bundle_digest` and `selected_child`, when present, are owned and must be
/// released with `deinitUnpackResult`.
pub const UnpackResult = struct {
    bundle: []const u8,
    out_dir: []const u8,
    bundle_digest: []const u8,
    chunk_count: usize,
    unpacked_chunk_count: usize,
    payload_bytes: u64,
    rootfs_artifact_count: usize = 0,
    rootfs_payload_bytes: u64 = 0,
    child_count: usize = 0,
    selected_child: ?[]const u8 = null,
};

/// Options for pushing a bundle to a remote destination.
pub const PushOptions = struct {
    bundle_dir: []const u8,
    destination: []const u8,
    aws_region: ?[]const u8 = null,
    aws_executable: []const u8 = "aws",
};

/// Result returned by `push`.
///
/// `bundle_digest` is owned and must be released with `deinitPushResult`.
pub const PushResult = struct {
    source: []const u8,
    destination: []const u8,
    store: []const u8 = "s3",
    bundle_digest: []const u8,
    uploaded_file_count: usize,
    uploaded_bytes: u64,
};

/// Options for pulling a bundle into a local spore directory.
pub const PullOptions = struct {
    source: []const u8,
    out_dir: []const u8,
    rootfs_cache: CacheRoot = .env,
    bundle_cache: CacheRoot = .env,
    child_id: ?[]const u8 = null,
    allow_metadata_only_rootfs: bool = false,
    aws_region: ?[]const u8 = null,
    aws_executable: []const u8 = "aws",
};

/// Platform summary returned by `inspectSpore`.
pub const SporePlatformSummary = struct {
    arch: []const u8,
    cpu_profile: []const u8,
    device_model_version: u32,
    ram_base: u64,
    ram_size: u64,
    gic_dist_base: u64,
    gic_redist_base: u64,
    counter_frequency_hz: u64,
};

/// Manifest summary returned by `inspectSpore`.
///
/// Owned string fields must be released with `deinitSporeInspectResult`.
pub const SporeInspectResult = struct {
    version: u32,
    platform: SporePlatformSummary,
    device_count: usize,
    memory_chunk_count: usize,
    present_memory_chunk_count: usize,
    memory_backing_kind: ?[]const u8,
    memory_backing_size: ?u64,
    gic_kind: []const u8,
};

/// Return host facts, backend availability, and cache roots.
///
/// The caller owns returned slices and optional paths. Call `deinitHostInfo`
/// with the same allocator when done.
pub fn hostInfo(
    context: Context,
    allocator: std.mem.Allocator,
) !HostInfo {
    const info = try platform.hostInfo(allocator, context.environ_map);
    errdefer platform.deinitHostInfo(allocator, info);

    const backends = try allocator.alloc(BackendAvailability, info.backends.len);
    errdefer allocator.free(backends);
    for (info.backends, backends) |backend, *out| {
        out.* = .{
            .name = backend.name,
            .supported = backend.supported,
            .available = backend.available,
            .reason = backend.reason,
        };
    }
    allocator.free(info.backends);

    return .{
        .host_class = info.host_class,
        .platform = .{
            .os = info.platform.os,
            .arch = info.platform.arch,
            .cpu_profile = info.platform.cpu_profile,
            .device_model_version = info.platform.device_model_version,
            .ram_base = info.platform.ram_base,
            .gic_dist_base = info.platform.gic_dist_base,
            .gic_redist_base = info.platform.gic_redist_base,
            .counter_frequency_source = info.platform.counter_frequency_source,
            .counter_frequency_hz = info.platform.counter_frequency_hz,
        },
        .backends = backends,
        .cache_roots = .{
            .kernels = pathFact(info.cache_roots.kernels),
            .rootfs = pathFact(info.cache_roots.rootfs),
            .bundles = pathFact(info.cache_roots.bundles),
            .runtime = pathFact(info.cache_roots.runtime),
        },
    };
}

/// Release memory owned by a `HostInfo` result.
pub fn deinitHostInfo(allocator: std.mem.Allocator, info: HostInfo) void {
    allocator.free(info.backends);
    freePathFact(allocator, info.cache_roots.kernels);
    freePathFact(allocator, info.cache_roots.rootfs);
    freePathFact(allocator, info.cache_roots.bundles);
    freePathFact(allocator, info.cache_roots.runtime);
}

/// Inspect a spore manifest without resuming or mutating it.
///
/// Owned strings in the result must be released with
/// `deinitSporeInspectResult`.
pub fn inspectSpore(
    allocator: std.mem.Allocator,
    spore_dir: []const u8,
) !SporeInspectResult {
    const manifest = try spore.loadManifest(allocator, spore_dir);
    defer manifest.deinit();
    return summarizeSpore(allocator, manifest.value);
}

/// Release memory owned by a `SporeInspectResult`.
pub fn deinitSporeInspectResult(allocator: std.mem.Allocator, result: SporeInspectResult) void {
    allocator.free(result.platform.arch);
    allocator.free(result.platform.cpu_profile);
    if (result.memory_backing_kind) |kind| allocator.free(kind);
}

/// Map an internal Zig error to the stable failure classification used by
/// machine output and run/resume event consumers.
pub fn classifyFailure(err: anyerror) ClassifiedFailure {
    return run_mod.classifyFailure(err);
}

/// Boot a VM with explicit kernel/rootfs inputs and execute a guest command.
///
/// This call does not stream guest output to process stdout/stderr. Use
/// `RunOptions.events` to observe lifecycle and output events.
pub fn run(
    context: Context,
    allocator: std.mem.Allocator,
    options: RunOptions,
) !RunResult {
    return run_mod.execute(context, allocator, .{
        .backend = options.backend,
        .kernel_path = options.kernel_path,
        .initrd_path = options.initrd_path,
        .rootfs_path = options.rootfs_path,
        .rootfs = options.rootfs,
        .disk = options.disk,
        .command = options.command,
        .guest_env = options.guest_env,
        .guest_working_dir = options.guest_working_dir,
        .memory = options.memory,
        .vcpus = options.vcpus,
        .guest_port = options.guest_port,
        .timeout_ms = options.timeout_ms,
        .stream_output = false,
        .capture_path = options.capture_path,
        .capture_trigger = options.capture_trigger,
        .continue_after_capture = options.continue_after_capture,
        .network = options.network,
        .network_policy = options.network_policy,
        .spore_executable = options.spore_executable,
        .events = options.events,
    });
}

/// Resolve managed kernel/initrd/rootfs inputs, boot a VM, and execute a command.
///
/// This is the library form of the high-level `spore run` setup path.
pub fn runManaged(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: ManagedRunOptions,
) !RunResult {
    if (options.capture_path != null and options.rootfs_path != null and options.image_ref == null) {
        return error.InvalidRootfsInput;
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rootfs = try run_mod.resolveRootfsInputDetailed(init, arena, .{
        .rootfs_path = options.rootfs_path,
        .image_ref = options.image_ref,
        .command_name = "run",
        .record_artifact = options.capture_path != null,
    });
    const kernel_path = options.kernel_path orelse try run_mod.resolveDefaultKernelPath(init, arena);
    const initrd_path = try run_mod.resolveConfiguredInitrdPath(init, options.initrd_path);

    return run_mod.execute(.{ .io = init.io, .environ_map = init.environ_map }, arena, .{
        .backend = options.backend,
        .kernel_path = kernel_path,
        .initrd_path = initrd_path,
        .rootfs_path = rootfs.path,
        .rootfs = rootfs.rootfs,
        .command = options.command,
        .guest_env = rootfs.guest_env,
        .guest_working_dir = rootfs.guest_working_dir,
        .memory = options.memory,
        .vcpus = options.vcpus,
        .guest_port = options.guest_port,
        .timeout_ms = options.timeout_ms,
        .stream_output = false,
        .capture_path = options.capture_path,
        .capture_trigger = options.capture_trigger,
        .continue_after_capture = options.continue_after_capture,
        .network = options.network,
        .network_policy = options.network_policy,
        .spore_executable = options.spore_executable,
        .events = options.events,
    });
}

/// Restore machine inputs from an existing spore directory and execute a new
/// guest command.
pub fn runFromSpore(
    context: Context,
    allocator: std.mem.Allocator,
    options: RunFromSporeOptions,
) !RunResult {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const manifest = try spore.loadManifest(arena, options.spore_dir);
    defer manifest.deinit();

    const rootfs = try run_mod.resumeRootfsForRun(arena, manifest.value);
    const disk = try run_mod.resumeDiskForRun(arena, manifest.value);
    const network_options = try run_mod.networkOptionsFromManifest(arena, manifest.value.network);

    return run_mod.execute(context, arena, .{
        .backend = options.backend,
        .kernel_path = "",
        .initrd_path = null,
        .rootfs_path = null,
        .rootfs = rootfs,
        .disk = disk,
        .resume_dir = options.spore_dir,
        .command = options.command,
        .memory = try run_mod.runMemoryFromManifest(manifest.value),
        .vcpus = options.vcpus,
        .guest_port = options.guest_port,
        .timeout_ms = options.timeout_ms,
        .stream_output = false,
        .capture_path = options.capture_path,
        .capture_trigger = options.capture_trigger,
        .continue_after_capture = options.continue_after_capture,
        .network = network_options.network,
        .network_policy = network_options.policy,
        .spore_executable = options.spore_executable,
        .events = options.events,
    });
}

/// Resume a captured spore to its recorded continuation point.
pub fn resumeSpore(
    context: Context,
    allocator: std.mem.Allocator,
    options: ResumeOptions,
) !ResumeResult {
    return resume_mod.execute(context, allocator, .{
        .backend = options.backend,
        .spore_dir = options.spore_dir,
        .spore_executable = options.spore_executable,
        .events = options.events,
    });
}

/// Fork a parent spore into multiple child spores.
///
/// Owned strings in the result must be released with `deinitForkResult`.
pub fn fork(
    context: Context,
    allocator: std.mem.Allocator,
    options: ForkOptions,
) !ForkResult {
    const result = try spore.fork(allocator, .{
        .parent_dir = options.parent_dir,
        .out_dir = options.out_dir,
        .count = options.count,
        .environ_map = context.environ_map,
    });
    return .{
        .parent = result.parent,
        .out_dir = result.out_dir,
        .count = result.count,
        .parent_generation = result.parent_generation,
        .first_generation = result.first_generation,
        .last_generation = result.last_generation,
        .first_child = result.first_child,
        .last_child = result.last_child,
    };
}

/// Release memory owned by a `ForkResult`.
pub fn deinitForkResult(allocator: std.mem.Allocator, result: ForkResult) void {
    allocator.free(result.first_child);
    allocator.free(result.last_child);
}

/// Pack a spore directory into a portable bundle.
///
/// Owned strings in the result must be released with `deinitPackResult`.
pub fn pack(
    context: Context,
    allocator: std.mem.Allocator,
    options: PackOptions,
) !PackResult {
    const rootfs_cache = resolveCacheRoot(options.rootfs_cache, allocator, context.environ_map, .rootfs);
    defer rootfs_cache.deinit(allocator);

    const result = try bundle.pack(allocator, .{
        .io = context.io,
        .spore_dir = options.spore_dir,
        .out_dir = options.out_dir,
        .rootfs_cache_dir = rootfs_cache.path,
        .children_dir = options.children_dir,
        .rootfs_policy = rootfsBundlePolicy(options.rootfs_policy),
    });
    return .{
        .source = result.source,
        .out_dir = result.out_dir,
        .bundle_digest = result.bundle_digest,
        .chunk_count = result.chunk_count,
        .packed_chunk_count = result.packed_chunk_count,
        .pack_count = result.pack_count,
        .payload_bytes = result.payload_bytes,
        .rootfs_artifact_count = result.rootfs_artifact_count,
        .rootfs_payload_bytes = result.rootfs_payload_bytes,
        .child_count = result.child_count,
    };
}

/// Release memory owned by a `PackResult`.
pub fn deinitPackResult(allocator: std.mem.Allocator, result: PackResult) void {
    allocator.free(result.bundle_digest);
}

/// Unpack a bundle into a spore directory.
///
/// Owned strings in the result must be released with `deinitUnpackResult`.
pub fn unpack(
    context: Context,
    allocator: std.mem.Allocator,
    options: UnpackOptions,
) !UnpackResult {
    const rootfs_cache = resolveCacheRoot(options.rootfs_cache, allocator, context.environ_map, .rootfs);
    defer rootfs_cache.deinit(allocator);

    const result = try bundle.unpack(allocator, .{
        .io = context.io,
        .bundle_dir = options.bundle_dir,
        .out_dir = options.out_dir,
        .rootfs_cache_dir = rootfs_cache.path,
        .child_id = options.child_id,
        .allow_metadata_only_rootfs = options.allow_metadata_only_rootfs,
    });
    return .{
        .bundle = result.bundle,
        .out_dir = result.out_dir,
        .bundle_digest = result.bundle_digest,
        .chunk_count = result.chunk_count,
        .unpacked_chunk_count = result.unpacked_chunk_count,
        .payload_bytes = result.payload_bytes,
        .rootfs_artifact_count = result.rootfs_artifact_count,
        .rootfs_payload_bytes = result.rootfs_payload_bytes,
        .child_count = result.child_count,
        .selected_child = result.selected_child,
    };
}

/// Release memory owned by an `UnpackResult`.
pub fn deinitUnpackResult(allocator: std.mem.Allocator, result: UnpackResult) void {
    allocator.free(result.bundle_digest);
    if (result.selected_child) |child| allocator.free(child);
}

/// Push a bundle to a remote destination.
///
/// Owned strings in the result must be released with `deinitPushResult`.
pub fn push(
    context: Context,
    allocator: std.mem.Allocator,
    options: PushOptions,
) !PushResult {
    const result = try bundle.push(allocator, .{
        .io = context.io,
        .bundle_dir = options.bundle_dir,
        .destination = options.destination,
        .aws_region = options.aws_region,
        .aws_executable = options.aws_executable,
    });
    return .{
        .source = result.source,
        .destination = result.destination,
        .store = result.store,
        .bundle_digest = result.bundle_digest,
        .uploaded_file_count = result.uploaded_file_count,
        .uploaded_bytes = result.uploaded_bytes,
    };
}

/// Release memory owned by a `PushResult`.
pub fn deinitPushResult(allocator: std.mem.Allocator, result: PushResult) void {
    allocator.free(result.bundle_digest);
}

/// Inspect bundle metadata without materializing a child spore.
///
/// Owned strings and child summaries must be released with
/// `deinitInspectBundleResult`.
pub fn inspectBundle(
    allocator: std.mem.Allocator,
    options: InspectBundleOptions,
) !InspectBundleResult {
    return bundle.inspectBundle(allocator, .{
        .source = options.source,
        .child_id = options.child_id,
        .child_range = if (options.child_range) |range| .{ .start = range.start, .end = range.end } else null,
    });
}

/// Release memory owned by an `InspectBundleResult`.
pub fn deinitInspectBundleResult(allocator: std.mem.Allocator, result: InspectBundleResult) void {
    contracts.deinitInspectBundleResult(allocator, result);
}

/// Pull a bundle into a local spore directory.
///
/// The returned contract is owned by the caller and must be released with
/// `deinitPullResult`.
pub fn pull(
    context: Context,
    allocator: std.mem.Allocator,
    options: PullOptions,
) !PullResult {
    const rootfs_cache = resolveCacheRoot(options.rootfs_cache, allocator, context.environ_map, .rootfs);
    defer rootfs_cache.deinit(allocator);
    const bundle_cache = resolveCacheRoot(options.bundle_cache, allocator, context.environ_map, .bundle);
    defer bundle_cache.deinit(allocator);

    return bundle.pull(allocator, .{
        .io = context.io,
        .source = options.source,
        .out_dir = options.out_dir,
        .rootfs_cache_dir = rootfs_cache.path,
        .bundle_cache_dir = bundle_cache.path,
        .child_id = options.child_id,
        .allow_metadata_only_rootfs = options.allow_metadata_only_rootfs,
        .aws_region = options.aws_region,
        .aws_executable = options.aws_executable,
    });
}

/// Release memory owned by a `PullResult`.
pub fn deinitPullResult(allocator: std.mem.Allocator, result: PullResult) void {
    contracts.deinitPullResult(allocator, result);
}

fn summarizeSpore(allocator: std.mem.Allocator, manifest: spore.Manifest) !SporeInspectResult {
    var present_chunks: usize = 0;
    for (manifest.memory.chunks) |maybe_chunk| {
        if (maybe_chunk != null) present_chunks += 1;
    }

    return .{
        .version = manifest.version,
        .platform = .{
            .arch = try allocator.dupe(u8, manifest.platform.arch),
            .cpu_profile = try allocator.dupe(u8, manifest.platform.cpu_profile),
            .device_model_version = manifest.platform.device_model_version,
            .ram_base = manifest.platform.ram_base,
            .ram_size = manifest.platform.ram_size,
            .gic_dist_base = manifest.platform.gic_dist_base,
            .gic_redist_base = manifest.platform.gic_redist_base,
            .counter_frequency_hz = manifest.platform.counter_frequency_hz,
        },
        .device_count = manifest.devices.len,
        .memory_chunk_count = manifest.memory.chunks.len,
        .present_memory_chunk_count = present_chunks,
        .memory_backing_kind = if (manifest.memory.backing) |backing| try allocator.dupe(u8, backing.kind) else null,
        .memory_backing_size = if (manifest.memory.backing) |backing| backing.size else null,
        .gic_kind = @tagName(manifest.machine.gic.kind),
    };
}

fn pathFact(fact: platform.PathFact) PathFact {
    return .{
        .path = fact.path,
        .resolved = fact.resolved,
        .source = fact.source,
    };
}

fn freePathFact(allocator: std.mem.Allocator, fact: PathFact) void {
    if (fact.path) |path| allocator.free(path);
}

const CacheKind = enum {
    rootfs,
    bundle,
};

const ResolvedCacheRoot = struct {
    path: ?[]const u8 = null,
    owned: bool = false,

    fn deinit(self: ResolvedCacheRoot, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.path.?);
    }
};

fn resolveCacheRoot(
    requested: CacheRoot,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    kind: CacheKind,
) ResolvedCacheRoot {
    return switch (requested) {
        .none => .{},
        .path => |path| .{ .path = path },
        .env => switch (kind) {
            .rootfs => if (local_paths.rootfsCacheRootPath(allocator, environ_map) catch null) |path| .{ .path = path, .owned = true } else .{},
            .bundle => if (local_paths.bundleCacheRootPath(allocator, environ_map) catch null) |path| .{ .path = path, .owned = true } else .{},
        },
    };
}

fn rootfsBundlePolicy(policy: RootfsBundlePolicy) bundle.RootfsBundlePolicy {
    return switch (policy) {
        .exact_bytes => .exact_bytes,
        .metadata_only => .metadata_only,
    };
}
