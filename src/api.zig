//! Product API boundary used by the CLI and embedding layers.
//!
//! Import this module through `libspore`. Backend, device, storage, monitor, and
//! CLI modules stay internal; this file owns the product operations and result
//! contracts callers should build against.

const std = @import("std");
const builtin = @import("builtin");

const bundle = @import("bundle.zig");
const chunk = @import("chunk.zig");
const chunk_sealer = @import("chunk_sealer.zig");
const contracts = @import("contracts.zig");
const disk_index = @import("disk_index.zig");
const context_mod = @import("context.zig");
const generation = @import("generation.zig");
const lifecycle = @import("lifecycle.zig");
const local_paths = @import("local_paths.zig");
const memory_config = @import("memory.zig");
const platform = @import("platform.zig");
const attach_mod = @import("attach.zig");
const rootfs_mod = @import("rootfs.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const runtime_disk_fork_capture = @import("runtime_disk_fork_capture.zig");
const runtime_disk_lease = @import("runtime_disk_lease.zig");
const saved_spore_pin = @import("saved_spore_pin.zig");
const run_mod = @import("run.zig");
const runtime_disk_mod = @import("runtime_disk.zig");
const gicv3 = @import("gicv3.zig");
const spore = @import("spore.zig");
const spore_net_policy = @import("spore_net_policy.zig");
const topology = @import("topology.zig");
const system = @import("system.zig");

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
pub const SaveTrigger = run_mod.SaveTrigger;
pub const ImagePullPolicy = run_mod.PullPolicy;
pub const NetworkMode = run_mod.NetworkMode;
pub const NetworkConfig = run_mod.NetworkPolicy;
pub const NetworkCapabilities = spore_net_policy.NetworkCapabilities;
pub const NetworkDefault = spore_net_policy.NetworkDefault;
pub const NetworkPolicy = spore_net_policy.NetworkPolicy;
pub const NetworkRule = spore_net_policy.NetworkRule;
pub const BoundService = spore_net_policy.BoundService;
pub const BoundServiceBinding = spore_net_policy.BoundServiceBinding;
pub const BoundServiceBindingDiagnostic = spore_net_policy.BoundServiceBindingDiagnostic;
pub const BoundServiceTarget = spore_net_policy.BoundServiceTarget;
pub const PortForwardConfig = spore_net_policy.PortForwardConfig;
pub const Rootfs = run_mod.Rootfs;
pub const Annotations = spore.Annotations;
pub const validateAnnotations = spore.validateAnnotations;
pub const NetworkRequirements = spore.NetworkRequirements;
pub const NetworkBoundServiceRequirement = spore.NetworkBoundServiceRequirement;
pub const Session = spore.Session;
pub const SessionStreams = spore.SessionStreams;
pub const RootfsBuildOptions = rootfs_mod.BuildRequest;
pub const RootfsBuildResult = rootfs_mod.BuildResult;
pub const RootfsCasPreloadOptions = rootfs_mod.CasPreloadRequest;
pub const RootfsCasPreloadResult = rootfs_mod.CasPreloadResult;
pub const RootfsImportOciOptions = rootfs_mod.ImportOciRequest;
pub const RootfsImportOciResult = rootfs_mod.ImportOciResult;
pub const RootfsImportTarOptions = rootfs_mod.ImportTarRequest;
pub const RootfsImportTarResult = rootfs_mod.ImportTarResult;
pub const RootfsPlatform = rootfs_mod.Platform;
pub const RootfsResolveOptions = rootfs_mod.ResolveRequest;
pub const RootfsStoragePolicy = rootfs_mod.RootfsStoragePolicy;
pub const Disk = run_mod.Disk;
pub const InjectedFile = run_mod.InjectedFile;
pub const RunResult = run_mod.Result;
pub const AttachResult = run_mod.Result;
pub const RunEvent = run_mod.RunEvent;
pub const EventSink = run_mod.EventSink;
pub const ClassifiedFailure = run_mod.ClassifiedFailure;
pub const FailureCode = run_mod.FailureCode;
pub const FailureScope = run_mod.FailureScope;
pub const Timings = run_mod.Timings;
pub const StartEvent = run_mod.StartEvent;
pub const ReadyEvent = run_mod.ReadyEvent;
pub const OutputEvent = run_mod.OutputEvent;
pub const SaveEvent = run_mod.SaveEvent;
pub const ImageCommitEvent = run_mod.ImageCommitEvent;
pub const ExitEvent = run_mod.ExitEvent;
pub const FailureEvent = run_mod.FailureEvent;
pub const CreateNamedOptions = lifecycle.CreateNamedOptions;
pub const RestoreNamedOptions = lifecycle.RestoreNamedOptions;
pub const ForkNamedOptions = lifecycle.ForkNamedOptions;
pub const ExecNamedOptions = lifecycle.ExecNamedOptions;
pub const ExecNamedStreamOptions = lifecycle.ExecNamedStreamOptions;
pub const ExecNamedStream = lifecycle.ExecNamedStream;
pub const ExecNamedStreamEvent = lifecycle.ExecNamedStreamEvent;
pub const TerminalSize = lifecycle.TerminalSize;
pub const CopyNamedOptions = lifecycle.CopyNamedOptions;
pub const NamedNetworkOptions = lifecycle.NamedNetworkOptions;
pub const SaveNamedOptions = lifecycle.SaveNamedOptions;
pub const RemoveNamedOptions = lifecycle.RemoveNamedOptions;
pub const RemovedSavedSpore = lifecycle.RemovedSavedSpore;
pub const ListNamedOptions = lifecycle.ListNamedOptions;
pub const NamedLifecycleResult = lifecycle.NamedLifecycleResult;
pub const ExecNamedResult = lifecycle.ExecNamedResult;
pub const NamedForkResult = lifecycle.NamedForkResult;
pub const NamedListEntry = lifecycle.ListEntry;
pub const NamedListMemory = lifecycle.ListMemory;
pub const NamedListStats = lifecycle.ListStats;
pub const CacheStats = system.CacheStats;
pub const RootfsSystemSummary = system.RootfsSystemSummary;
pub const RootfsPruneEntry = system.RootfsPruneEntry;
pub const RootfsPruneResult = system.RootfsPruneResult;
pub const RuntimeForkPruneEntry = system.RuntimeForkPruneEntry;
pub const RuntimeForkPruneResult = system.RuntimeForkPruneResult;

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
    /// Ephemeral files made available under /run/sporevm/injected for this fresh run.
    injected_files: []const InjectedFile = &.{},
    interactive: bool = false,
    tty: bool = false,
    memory: MemoryConfig = .{},
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    save_path: ?[]const u8 = null,
    save_trigger: SaveTrigger = .exit,
    continue_after_save: bool = false,
    annotations: Annotations = .{},
    network: NetworkMode = .disabled,
    network_policy: NetworkConfig = .{},
    spore_executable: []const u8 = "spore",
    debug: bool = false,
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
    image_pull_policy: ImagePullPolicy = .missing,
    /// Guest command and arguments. The first element is the executable.
    command: []const []const u8,
    guest_env: []const []const u8 = &.{},
    /// Ephemeral files made available under /run/sporevm/injected for this fresh run.
    injected_files: []const InjectedFile = &.{},
    interactive: bool = false,
    tty: bool = false,
    memory: MemoryConfig = .{},
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    save_path: ?[]const u8 = null,
    save_trigger: SaveTrigger = .exit,
    continue_after_save: bool = false,
    /// Publish the writable root disk under this local image ref after exit zero.
    commit_ref: ?[]const u8 = null,
    /// Absolute logical root-disk size for a commit run. Must not shrink the source image.
    disk_size: ?u64 = null,
    annotations: Annotations = .{},
    network: NetworkMode = .disabled,
    network_policy: NetworkConfig = .{},
    spore_executable: []const u8 = "spore",
    debug: bool = false,
    /// Optional synchronous event sink. Output byte slices are callback-scoped.
    events: ?EventSink = null,
};

/// Run a command from a spore directory, or attach to one of its saved sessions.
///
/// This is the product API for `spore run --from`: it reads the manifest,
/// restores machine/rootfs/disk policy from the spore, then executes a new
/// guest command. Empty `command` attaches to a saved session for lower-level
/// API compatibility; the CLI spells that path `spore attach`.
pub const RunFromSporeOptions = struct {
    backend: Backend = .auto,
    spore_dir: []const u8,
    /// Guest command and arguments. The first element is the executable.
    /// Leave empty to attach to a saved session.
    command: []const []const u8,
    guest_env: []const []const u8 = &.{},
    /// Saved session to attach when command is empty.
    attach_session_id: ?[]const u8 = null,
    interactive: bool = false,
    tty: bool = false,
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    save_path: ?[]const u8 = null,
    save_trigger: SaveTrigger = .exit,
    continue_after_save: bool = false,
    /// Optional fan-out identity JSON to deliver before a run-from command starts.
    /// Only meaningful when `command` starts a fresh process.
    generation_path: ?[]const u8 = null,
    spore_executable: []const u8 = "spore",
    debug: bool = false,
    /// Live host-side bindings for manifest-declared bound services.
    bound_services: []const BoundServiceBinding = &.{},
    /// Optional detail for binding mismatch errors.
    bound_service_diagnostic: ?*BoundServiceBindingDiagnostic = null,
    /// Optional synchronous event sink. Output byte slices are callback-scoped.
    events: ?EventSink = null,
};

/// Attach to a spore's recorded session.
pub const AttachOptions = struct {
    backend: Backend = .auto,
    spore_dir: []const u8,
    session_id: ?[]const u8 = null,
    generation_path: ?[]const u8 = null,
    timeout_ms: u64 = 30_000,
    spore_executable: []const u8 = "spore",
    debug: bool = false,
    interactive: bool = false,
    tty: bool = false,
    /// Live host-side bindings for manifest-declared bound services.
    bound_services: []const BoundServiceBinding = &.{},
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
    pin_publish_ms: ?u64 = null,
    pin_lock_wait_ms: ?u64 = null,
};

const ForkPinTestFault = struct {
    fail_before_child: ?usize = null,
    fail_before_registry_sync: bool = false,
    fail_before_batch_rename: bool = false,
    fail_before_portable_sync: ?usize = null,
    portable_sync_count: usize = 0,
};

var fork_pin_test_fault: ForkPinTestFault = .{};

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

/// Options for rootfs cache inspection.
pub const SystemDfOptions = struct {
    rootfs_cache: CacheRoot = .env,
};

/// Options for local rootfs and runtime cleanup.
pub const SystemPruneOptions = struct {
    rootfs_cache: CacheRoot = .env,
    dry_run: bool = true,
    include_digest_artifacts: bool = false,
    older_than_seconds: ?u64 = null,
    max_bytes: ?u64 = null,
    rootfs_only: bool = false,
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

pub const SporeNetworkSummary = struct {
    kind: []const u8,
    requirements: NetworkRequirements,
    bound_services: []const NetworkBoundServiceRequirement = &.{},
};

/// Manifest summary returned by `inspectSpore`.
///
/// Owned string fields must be released with `deinitSporeInspectResult`.
pub const SporeInspectResult = struct {
    version: u32,
    vm_state_present: bool,
    storage_mode: []const u8,
    vcpu_count: u32,
    platform: SporePlatformSummary,
    device_count: usize,
    memory_chunk_count: usize,
    present_memory_chunk_count: usize,
    memory_backing_kind: ?[]const u8,
    memory_backing_size: ?u64,
    gic_kind: []const u8,
    sessions: []Session = &.{},
    network: ?SporeNetworkSummary = null,
    annotations: Annotations = .{},
    annotation_keys: []const []const u8 = &.{},
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

/// Summarize the local rootfs cache.
///
/// The returned cache root is owned by the caller. Release it with
/// `deinitRootfsSystemSummary`.
pub fn systemDf(
    context: Context,
    allocator: std.mem.Allocator,
    options: SystemDfOptions,
) !RootfsSystemSummary {
    const rootfs_cache = try resolveRequiredCacheRoot(options.rootfs_cache, allocator, context.environ_map, .rootfs);
    defer rootfs_cache.deinit(allocator);
    return system.df(allocator, context.io, .{ .cache_root = rootfs_cache.path.? });
}

/// Release memory owned by a `RootfsSystemSummary`.
pub fn deinitRootfsSystemSummary(allocator: std.mem.Allocator, summary: RootfsSystemSummary) void {
    system.deinitRootfsSystemSummary(allocator, summary);
}

/// Prune the local rootfs cache and, when age-based cleanup is requested,
/// unreferenced runtime fork batches.
///
/// The result owns cache roots and entry paths. Release it with
/// `deinitRootfsPruneResult`.
pub fn systemPrune(
    context: Context,
    allocator: std.mem.Allocator,
    options: SystemPruneOptions,
) !RootfsPruneResult {
    const rootfs_cache = try resolveRequiredCacheRoot(options.rootfs_cache, allocator, context.environ_map, .rootfs);
    defer rootfs_cache.deinit(allocator);

    const runtime_root = if (!options.rootfs_only and options.older_than_seconds != null)
        local_paths.runtimeRootPath(allocator, context.environ_map) catch null
    else
        null;
    defer if (runtime_root) |root| allocator.free(root);

    return system.prune(allocator, context.io, .{
        .cache_root = rootfs_cache.path.?,
        .runtime_root = runtime_root,
        .dry_run = options.dry_run,
        .include_digest_artifacts = options.include_digest_artifacts,
        .older_than_seconds = options.older_than_seconds,
        .max_bytes = options.max_bytes,
        .rootfs_only = options.rootfs_only,
    }, std.Io.Clock.real.now(context.io).nanoseconds);
}

/// Build an ext4 rootfs from an OCI image reference.
///
/// Release owned result fields with `deinitRootfsBuildResult`.
pub fn rootfsBuild(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: RootfsBuildOptions,
) !RootfsBuildResult {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const result = try rootfs_mod.build(init, arena_state.allocator(), options);
    return .{
        .rootfs_storage = try ownRootfsStorageDigestFields(allocator, result.rootfs_storage),
    };
}

/// Release memory owned by a `RootfsBuildResult`.
pub fn deinitRootfsBuildResult(allocator: std.mem.Allocator, result: RootfsBuildResult) void {
    rootfs_mod.deinitBuildResult(allocator, result);
}

/// Import an OCI layout into the local rootfs cache under a local ref.
///
/// Release owned result fields with `deinitRootfsImportOciResult`.
pub fn rootfsImportOci(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: RootfsImportOciOptions,
) !RootfsImportOciResult {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const result = try rootfs_mod.importOciLayout(init, arena_state.allocator(), options);
    return ownRootfsImportOciResult(allocator, result);
}

/// Release memory owned by a `RootfsImportOciResult`.
pub fn deinitRootfsImportOciResult(allocator: std.mem.Allocator, result: RootfsImportOciResult) void {
    rootfs_mod.deinitImportOciResult(allocator, result);
}

/// Import an uncompressed rootfs tar into the local rootfs cache under a local ref.
///
/// Release owned result fields with `deinitRootfsImportTarResult`.
pub fn rootfsImportTar(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: RootfsImportTarOptions,
) !RootfsImportTarResult {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const result = try rootfs_mod.importTar(init, arena_state.allocator(), options);
    return ownRootfsImportOciResult(allocator, result);
}

/// Release memory owned by a `RootfsImportTarResult`.
pub fn deinitRootfsImportTarResult(allocator: std.mem.Allocator, result: RootfsImportTarResult) void {
    rootfs_mod.deinitImportTarResult(allocator, result);
}

/// Resolve an image tag or local ref to the digest-pinned ref used by SporeVM.
///
/// The returned string is owned by the caller. Release it with
/// `deinitRootfsResolveResult`.
pub fn rootfsResolve(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: RootfsResolveOptions,
) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const resolved = try rootfs_mod.resolveReference(init, arena_state.allocator(), options);
    return allocator.dupe(u8, resolved);
}

/// Release memory owned by a `rootfsResolve` result.
pub fn deinitRootfsResolveResult(allocator: std.mem.Allocator, resolved_ref: []const u8) void {
    rootfs_mod.deinitResolvedReference(allocator, resolved_ref);
}

/// Preload a cached rootfs into chunked CAS storage.
///
/// Release owned result fields with `deinitRootfsCasPreloadResult`.
pub fn rootfsCasPreload(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: RootfsCasPreloadOptions,
) !RootfsCasPreloadResult {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const result = try rootfs_mod.casPreload(init, arena_state.allocator(), options);
    return ownRootfsCasPreloadResult(allocator, result);
}

/// Release memory owned by a `RootfsCasPreloadResult`.
pub fn deinitRootfsCasPreloadResult(allocator: std.mem.Allocator, result: RootfsCasPreloadResult) void {
    rootfs_mod.deinitCasPreloadResult(allocator, result);
}

fn ownRootfsStorageDigestFields(allocator: std.mem.Allocator, storage: spore.RootfsStorage) !spore.RootfsStorage {
    const index_digest = try allocator.dupe(u8, storage.index_digest);
    errdefer allocator.free(index_digest);
    const same_base = storage.index_digest.ptr == storage.base_identity.ptr and storage.index_digest.len == storage.base_identity.len;
    const base_identity = if (same_base) index_digest else try allocator.dupe(u8, storage.base_identity);
    return .{
        .kind = storage.kind,
        .device = storage.device,
        .logical_size = storage.logical_size,
        .chunk_size = storage.chunk_size,
        .hash_algorithm = storage.hash_algorithm,
        .index_digest = index_digest,
        .base_identity = base_identity,
        .object_namespace = storage.object_namespace,
    };
}

fn ownRootfsImportOciResult(allocator: std.mem.Allocator, result: RootfsImportOciResult) !RootfsImportOciResult {
    const rootfs_path = try allocator.dupe(u8, result.rootfs_path);
    errdefer allocator.free(rootfs_path);
    const metadata_path = try allocator.dupe(u8, result.metadata_path);
    errdefer allocator.free(metadata_path);
    const local_ref_path = try allocator.dupe(u8, result.local_ref_path);
    errdefer allocator.free(local_ref_path);
    const resolved_image_ref = try allocator.dupe(u8, result.resolved_image_ref);
    errdefer allocator.free(resolved_image_ref);
    const image_manifest_digest = try allocator.dupe(u8, result.image_manifest_digest);
    errdefer allocator.free(image_manifest_digest);
    const rootfs_storage = try ownRootfsStorageDigestFields(allocator, result.rootfs_storage);
    return .{
        .rootfs_path = rootfs_path,
        .metadata_path = metadata_path,
        .local_ref_path = local_ref_path,
        .resolved_image_ref = resolved_image_ref,
        .image_manifest_digest = image_manifest_digest,
        .rootfs_storage = rootfs_storage,
    };
}

fn ownRootfsCasPreloadResult(allocator: std.mem.Allocator, result: RootfsCasPreloadResult) !RootfsCasPreloadResult {
    const index_path = try allocator.dupe(u8, result.index_path);
    errdefer allocator.free(index_path);
    const index_digest = try allocator.dupe(u8, result.index_digest);
    errdefer allocator.free(index_digest);
    const rootfs_digest = try allocator.dupe(u8, result.rootfs_digest);
    return .{
        .index_path = index_path,
        .index_digest = index_digest,
        .rootfs_digest = rootfs_digest,
        .rootfs_size = result.rootfs_size,
        .chunk_size = result.chunk_size,
        .chunk_count = result.chunk_count,
        .zero_chunks = result.zero_chunks,
        .nonzero_chunks = result.nonzero_chunks,
        .objects_written = result.objects_written,
        .object_bytes_written = result.object_bytes_written,
        .index_bytes = result.index_bytes,
        .source_verify_ms = result.source_verify_ms,
        .chunk_scan_ms = result.chunk_scan_ms,
        .object_check_ms = result.object_check_ms,
        .object_write_ms = result.object_write_ms,
        .index_build_ms = result.index_build_ms,
        .index_write_ms = result.index_write_ms,
        .sealed_chunks = result.sealed_chunks,
        .seal_workers = result.seal_workers,
        .seal_wall_ms = result.seal_wall_ms,
        .seal_worker_cpu_ms = result.seal_worker_cpu_ms,
    };
}

/// Release memory owned by a `RootfsPruneResult`.
pub fn deinitRootfsPruneResult(allocator: std.mem.Allocator, result: RootfsPruneResult) void {
    system.deinitRootfsPruneResult(allocator, result);
}

/// Inspect a spore manifest without resuming or mutating it.
///
/// Owned strings in the result must be released with
/// `deinitSporeInspectResult`.
pub fn inspectSpore(
    allocator: std.mem.Allocator,
    spore_dir: []const u8,
) !SporeInspectResult {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Multi-vCPU spores carry a v1 manifest; try the same version fallback
    // resume uses so inspect accepts everything resume can restore.
    if (spore.loadManifest(arena, spore_dir)) |manifest| {
        defer manifest.deinit();
        return summarizeSpore(allocator, manifest.value, 1);
    } else |err| {
        if (err != error.BadManifest) return err;
    }
    const manifest = try spore.loadManifestV1(arena, spore_dir);
    defer manifest.deinit();
    return summarizeSpore(allocator, manifest.value, manifest.value.platform.vcpu_count);
}

/// Release memory owned by a `SporeInspectResult`.
pub fn deinitSporeInspectResult(allocator: std.mem.Allocator, result: SporeInspectResult) void {
    allocator.free(result.platform.arch);
    allocator.free(result.platform.cpu_profile);
    if (result.memory_backing_kind) |kind| allocator.free(kind);
    freeSessions(allocator, result.sessions);
    if (result.network) |network| freeNetworkSummary(allocator, network);
    allocator.free(result.annotation_keys);
    var annotations = result.annotations;
    deinitOwnedAnnotations(allocator, &annotations);
}

/// Map an internal Zig error to the stable failure classification used by
/// machine output and run/resume event consumers.
pub fn classifyFailure(err: anyerror) ClassifiedFailure {
    return run_mod.classifyFailure(err);
}

/// Return libspore's enforceable network capability facts.
pub fn networkCapabilities() NetworkCapabilities {
    return spore_net_policy.capabilities();
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
        .injected_files = options.injected_files,
        .interactive = options.interactive,
        .tty = options.tty,
        .memory = options.memory,
        .vcpus = options.vcpus,
        .guest_port = options.guest_port,
        .timeout_ms = options.timeout_ms,
        .stream_output = false,
        .save_path = options.save_path,
        .save_trigger = options.save_trigger,
        .continue_after_save = options.continue_after_save,
        .annotations = options.annotations,
        .network = options.network,
        .network_policy = options.network_policy,
        .spore_executable = options.spore_executable,
        .debug = options.debug,
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
    if (options.save_path != null and options.rootfs_path != null and options.image_ref == null) {
        return error.InvalidRootfsInput;
    }
    if (options.commit_ref) |ref| {
        try rootfs_mod.validateLocalTagRef(ref);
        if (options.image_ref == null or options.rootfs_path != null or options.save_path != null or !options.save_trigger.isExit() or options.continue_after_save or options.interactive or options.tty or options.command.len == 0) {
            return error.InvalidRunCommitOptions;
        }
    }
    if (options.disk_size) |disk_size| {
        if (options.commit_ref == null or disk_size == 0 or disk_size % rootfs_cas.default_chunk_size != 0) return error.InvalidRunDiskSize;
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rootfs = try run_mod.resolveRootfsInputDetailed(init, arena, .{
        .rootfs_path = options.rootfs_path,
        .image_ref = options.image_ref,
        .pull_policy = options.image_pull_policy,
        .command_name = "run",
        .record_artifact = options.save_path != null or options.image_ref != null,
    });
    const default_kernel = options.kernel_path == null and init.environ_map.get("SPOREVM_KERNEL_IMAGE") == null;
    const default_initrd = options.initrd_path == null and init.environ_map.get("SPOREVM_RUN_INITRD") == null;
    const kernel_path = options.kernel_path orelse try run_mod.resolveDefaultKernelPath(init, arena);
    const initrd_path = try run_mod.resolveConfiguredInitrdPath(init, options.initrd_path);
    const guest_env = try run_mod.mergeGuestEnv(arena, rootfs.guest_env, options.guest_env);
    const rootfs_grow_target = if (options.disk_size) |target| blk: {
        const resolved_rootfs = rootfs.rootfs orelse return error.RunCommitRootfsNotSnapshotable;
        const storage = resolved_rootfs.storage orelse return error.RunCommitRootfsNotSnapshotable;
        break :blk try run_mod.rootfsGrowTarget(storage.logical_size, target);
    } else 0;

    return run_mod.execute(.{ .io = init.io, .environ_map = init.environ_map }, arena, .{
        .backend = options.backend,
        .kernel_path = kernel_path,
        .initrd_path = initrd_path,
        .auto_memory_hotplug_capable = default_kernel and default_initrd,
        .rootfs_path = rootfs.path,
        .rootfs = rootfs.rootfs,
        .rootfs_grow_target = rootfs_grow_target,
        .command = options.command,
        .injected_files = options.injected_files,
        .interactive = options.interactive,
        .tty = options.tty,
        .guest_env = guest_env,
        .guest_working_dir = rootfs.guest_working_dir,
        .memory = options.memory,
        .vcpus = options.vcpus,
        .guest_port = options.guest_port,
        .timeout_ms = options.timeout_ms,
        .stream_output = false,
        .save_path = options.save_path,
        .save_trigger = options.save_trigger,
        .continue_after_save = options.continue_after_save,
        .commit = if (options.commit_ref) |ref| .{
            .ref = ref,
            .config = rootfs.image_config orelse return error.RunCommitImageConfigUnavailable,
        } else null,
        .annotations = options.annotations,
        .network = options.network,
        .network_policy = options.network_policy,
        .spore_executable = options.spore_executable,
        .debug = options.debug,
        .events = options.events,
    });
}

/// Restore machine inputs from an existing spore directory and execute a new
/// guest command, or attach when the command is empty.
pub fn runFromSpore(
    context: Context,
    allocator: std.mem.Allocator,
    options: RunFromSporeOptions,
) !RunResult {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var manifest = spore.loadManifest(arena, options.spore_dir) catch |err| switch (err) {
        error.BadManifest => null,
        else => |e| return e,
    };
    defer if (manifest) |*parsed| parsed.deinit();
    var manifest_v1: ?std.json.Parsed(spore.ManifestV1) = null;
    defer if (manifest_v1) |*parsed| parsed.deinit();
    if (manifest == null) manifest_v1 = try spore.loadManifestV1(arena, options.spore_dir);

    const rootfs = if (manifest) |parsed|
        try run_mod.resumeRootfsForRun(arena, parsed.value)
    else
        try run_mod.resumeRootfsForRunV1(arena, manifest_v1.?.value);
    const disk = if (manifest) |parsed|
        try run_mod.resumeDiskForRun(arena, parsed.value)
    else
        try run_mod.resumeDiskForRunV1(arena, manifest_v1.?.value);
    const network_options = try run_mod.networkOptionsFromManifestWithBindingDiagnostic(arena, if (manifest) |parsed| parsed.value.network else manifest_v1.?.value.network, options.bound_services, options.bound_service_diagnostic);
    const manifest_vcpus = if (manifest_v1) |parsed| parsed.value.platform.vcpu_count else options.vcpus;
    if (manifest_v1 != null and options.vcpus != 1 and options.vcpus != manifest_vcpus) return error.PlatformMismatch;
    const manifest_generation = if (manifest) |parsed| parsed.value.generation else manifest_v1.?.value.generation;
    const sessions = if (manifest) |parsed| parsed.value.sessions else manifest_v1.?.value.sessions;
    const explicit_generation_params = if (options.generation_path) |path|
        attach_mod.loadGenerationParams(context.io, arena, path) catch |err| switch (err) {
            error.BadGenerationPayload, error.StreamTooLong => return err,
            else => return error.GenerationReadFailed,
        }
    else
        null;
    const run_generation = try prepareRunFromGenerationState(arena, manifest_generation, explicit_generation_params);

    return run_mod.execute(context, arena, .{
        .backend = options.backend,
        .kernel_path = "",
        .initrd_path = null,
        .rootfs_path = null,
        .rootfs = rootfs,
        .disk = disk,
        .resume_dir = options.spore_dir,
        .resume_generation = run_generation.resume_generation,
        .resume_sessions = sessions,
        .attach_session_id = options.attach_session_id orelse spore.defaultAttachSessionId(sessions),
        .start_generation_params = run_generation.start_generation_params,
        .require_generation_ready = run_generation.start_generation_params != null,
        .command = options.command,
        .guest_env = options.guest_env,
        .interactive = options.interactive,
        .tty = options.tty,
        .memory = try memory_config.fromManifestBytes(if (manifest) |parsed| parsed.value.platform.ram_size else manifest_v1.?.value.platform.ram_size),
        .vcpus = manifest_vcpus,
        .guest_port = options.guest_port,
        .timeout_ms = options.timeout_ms,
        .stream_output = false,
        .save_path = options.save_path,
        .save_trigger = options.save_trigger,
        .continue_after_save = options.continue_after_save,
        .annotations = if (manifest) |parsed| parsed.value.annotations else manifest_v1.?.value.annotations,
        .network = network_options.network,
        .network_policy = network_options.policy,
        .spore_executable = options.spore_executable,
        .debug = options.debug,
        .events = options.events,
    });
}

const RunFromGenerationState = struct {
    resume_generation: ?generation.State = null,
    start_generation_params: ?[]const u8 = null,
};

fn prepareRunFromGenerationState(
    allocator: std.mem.Allocator,
    manifest_generation: spore.GenerationState,
    explicit_generation_params: ?[]const u8,
) !RunFromGenerationState {
    if (explicit_generation_params) |params| {
        return .{
            .resume_generation = try attach_mod.prepareRestoreGenerationState(allocator, manifest_generation, params),
            .start_generation_params = params,
        };
    }
    if (manifest_generation.params_b64.len == 0) return .{};

    var gen_dev = generation.Device{};
    try gen_dev.restore(allocator, manifest_generation);
    try spore.refreshResumeParams(allocator, &gen_dev);
    return .{
        .resume_generation = try gen_dev.capture(allocator),
        .start_generation_params = try allocator.dupe(u8, gen_dev.paramsPayload()),
    };
}

/// Attach to a spore's recorded session.
pub fn attachSpore(
    context: Context,
    allocator: std.mem.Allocator,
    options: AttachOptions,
) !AttachResult {
    var bound_services = run_mod.BoundServiceBindingList{};
    for (options.bound_services) |binding| try bound_services.append(binding);
    return attach_mod.execute(context, allocator, .{
        .backend = options.backend,
        .spore_dir = options.spore_dir,
        .session_id = options.session_id,
        .generation_path = options.generation_path,
        .timeout_ms = options.timeout_ms,
        .spore_executable = options.spore_executable,
        .debug = options.debug,
        .bound_services = bound_services,
        .interactive = options.interactive,
        .tty = options.tty,
        .events = options.events,
    });
}

/// Create a long-lived named VM without exposing the private monitor socket.
pub fn createNamed(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: CreateNamedOptions,
) !NamedLifecycleResult {
    return lifecycle.createNamed(init, allocator, options);
}

/// Restore a spore as a long-lived named VM.
pub fn restoreNamed(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: RestoreNamedOptions,
) !NamedLifecycleResult {
    return lifecycle.restoreNamed(init, allocator, options);
}

/// Fork a ready named VM into ready children. One writable rootfs disk is
/// supported; networked sources remain unsupported.
pub fn forkNamed(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: ForkNamedOptions,
) !NamedForkResult {
    return lifecycle.forkNamed(init, allocator, options);
}

/// Execute a command inside a ready named VM.
pub fn execNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: ExecNamedOptions,
) !ExecNamedResult {
    return lifecycle.execNamed(context, allocator, options);
}

/// Open a bidirectional streaming exec inside a ready named VM.
pub fn openExecNamedStream(
    context: Context,
    allocator: std.mem.Allocator,
    options: ExecNamedStreamOptions,
) !ExecNamedStream {
    return lifecycle.openExecNamedStream(context, allocator, options);
}

pub const clearLastLifecycleError = lifecycle.clearLastError;
pub const lastLifecycleErrorMessage = lifecycle.lastErrorMessage;

/// Copy an explicit host file or directory into a ready named VM.
pub fn copyInNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: CopyNamedOptions,
) !void {
    return lifecycle.copyInNamed(context, allocator, options);
}

/// Copy an explicit guest file or directory out of a ready named VM.
pub fn copyOutNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: CopyNamedOptions,
) !void {
    return lifecycle.copyOutNamed(context, allocator, options);
}

/// Save a named VM into a spore. Set `stop` to remove the live registry entry.
pub fn saveNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: SaveNamedOptions,
) !NamedLifecycleResult {
    return lifecycle.saveNamed(context, allocator, options);
}

/// Remove a named VM registry entry, stopping the monitor when it is ready.
pub fn removeNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: RemoveNamedOptions,
) !NamedLifecycleResult {
    return lifecycle.removeNamed(context, allocator, options);
}

/// Remove a machine-local saved spore and unregister its durable CAS pin.
pub fn removeSavedSpore(context: Context, allocator: std.mem.Allocator, spore_dir: []const u8) !RemovedSavedSpore {
    return lifecycle.removeSavedSpore(context, allocator, spore_dir);
}

pub fn deinitRemovedSavedSpore(allocator: std.mem.Allocator, result: RemovedSavedSpore) void {
    lifecycle.deinitRemovedSavedSpore(allocator, result);
}

/// List named VMs in the process runtime root.
pub fn listNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: ListNamedOptions,
) ![]NamedListEntry {
    return lifecycle.listNamed(context, allocator, options);
}

pub fn deinitNamedLifecycleResult(allocator: std.mem.Allocator, result: NamedLifecycleResult) void {
    lifecycle.deinitNamedLifecycleResult(allocator, result);
}

pub fn deinitExecNamedResult(allocator: std.mem.Allocator, result: ExecNamedResult) void {
    lifecycle.deinitExecNamedResult(allocator, result);
}

pub fn deinitNamedForkResult(allocator: std.mem.Allocator, result: NamedForkResult) void {
    lifecycle.deinitNamedForkResult(allocator, result);
}

pub fn deinitNamedList(allocator: std.mem.Allocator, entries: []NamedListEntry) void {
    lifecycle.freeListEntries(allocator, entries);
}

/// Fork a parent spore into multiple child spores.
///
/// Owned strings in the result must be released with `deinitForkResult`.
pub fn fork(
    context: Context,
    allocator: std.mem.Allocator,
    options: ForkOptions,
) !ForkResult {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var manifest = spore.loadManifest(arena, options.parent_dir) catch |err| switch (err) {
        error.BadManifest => null,
        else => |e| return e,
    };
    defer if (manifest) |*parsed| parsed.deinit();
    var manifest_v1: ?std.json.Parsed(spore.ManifestV1) = null;
    defer if (manifest_v1) |*parsed| parsed.deinit();
    if (manifest == null) manifest_v1 = try spore.loadManifestV1(arena, options.parent_dir);
    const disk = if (manifest) |parsed| parsed.value.disk else manifest_v1.?.value.disk;
    var disk_root: ?[]const u8 = null;
    var parent_pin_id: ?[]const u8 = null;
    var validated_storage: ?spore.RootfsStorage = null;
    if (disk) |value| {
        const cache_root = try local_paths.rootfsCacheRootPath(arena, context.environ_map);
        var phase_one_lock = try rootfs_mod.lockRootfsCacheExclusive(context.io, arena, cache_root);
        defer phase_one_lock.deinit();
        const phase_one_registry = try saved_spore_pin.LockedRegistry.init(arena, cache_root, &phase_one_lock);
        if (saved_spore_pin.loadForSporeLocked(context.io, arena, phase_one_registry, options.parent_dir, value)) |pin_value| {
            var pin = pin_value;
            defer pin.deinit();
            disk_root = cache_root;
            parent_pin_id = try arena.dupe(u8, pin.value.id);
            validated_storage = try saved_spore_pin.storageForDisk(value);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }
    }
    const fork_out = if (disk != null) blk: {
        var nonce: [8]u8 = undefined;
        context.io.random(&nonce);
        break :blk try std.fmt.allocPrint(arena, "{s}.pin-stage-{x}", .{ options.out_dir, std.mem.readInt(u64, &nonce, .little) });
    } else options.out_dir;
    var cleanup_stage = disk != null;
    defer if (cleanup_stage) std.Io.Dir.cwd().deleteTree(context.io, fork_out) catch {};
    const result = try spore.fork(arena, .{
        .parent_dir = options.parent_dir,
        .out_dir = fork_out,
        .count = options.count,
        .environ_map = context.environ_map,
        .disk_root = disk_root,
    });
    if (disk_root == null) if (disk) |portable_disk| {
        try materializeForkDiskStore(context.io, arena, allocator, options.parent_dir, fork_out, portable_disk, options.count);
        if (builtin.is_test and fork_pin_test_fault.fail_before_batch_rename) return error.InjectedFailure;
        try std.Io.Dir.rename(std.Io.Dir.cwd(), fork_out, std.Io.Dir.cwd(), options.out_dir, context.io);
        try chunk_sealer.fsyncDirPath(arena, std.fs.path.dirname(options.out_dir) orelse ".");
        cleanup_stage = false;
    };
    var prepared_pins: ?[]saved_spore_pin.PreparedPin = null;
    if (disk_root != null) {
        prepared_pins = try arena.alloc(saved_spore_pin.PreparedPin, options.count);
        // Phase two must leave complete durable child manifests before phase
        // three can publish their pins. References are synced while the batch
        // is hidden, outside the short global-cache critical section.
        for (0..options.count) |index| {
            const child = try std.fmt.allocPrint(arena, "{s}/{d:0>6}", .{ fork_out, index });
            const manifest_path = try std.fs.path.join(arena, &.{ child, "manifest.json" });
            const bytes = try std.Io.Dir.cwd().readFileAlloc(context.io, manifest_path, allocator, .limited(saved_spore_pin.max_manifest_bytes + 1));
            defer allocator.free(bytes);
            if (bytes.len > saved_spore_pin.max_manifest_bytes) return error.StreamTooLong;
            try chunk_sealer.replaceFileAtomicDurable(arena, manifest_path, bytes, 0o644);
            var child_manifest = spore.loadManifest(arena, child) catch |err| switch (err) {
                error.BadManifest => null,
                else => |e| return e,
            };
            defer if (child_manifest) |*parsed| parsed.deinit();
            var child_v1: ?std.json.Parsed(spore.ManifestV1) = null;
            defer if (child_v1) |*parsed| parsed.deinit();
            if (child_manifest == null) child_v1 = try spore.loadManifestV1(arena, child);
            const child_disk = if (child_manifest) |parsed| parsed.value.disk else child_v1.?.value.disk;
            prepared_pins.?[index] = try saved_spore_pin.prepareValidatedReference(
                context.io,
                arena,
                child,
                child_disk orelse return error.BadManifest,
                validated_storage.?,
            );
        }
        try chunk_sealer.fsyncDirPath(arena, fork_out);
    }
    var pin_publish_ms: ?u64 = null;
    var pin_lock_wait_ms: ?u64 = null;
    if (disk != null and disk_root != null) {
        const wait_started = runtime_disk_fork_capture.monotonicNs();
        var publish_lock = try rootfs_mod.lockRootfsCacheExclusive(context.io, arena, disk_root.?);
        defer publish_lock.deinit();
        const publish_registry = try saved_spore_pin.LockedRegistry.init(arena, disk_root.?, &publish_lock);
        const lock_started = runtime_disk_fork_capture.monotonicNs();
        pin_lock_wait_ms = (lock_started -| wait_started) / std.time.ns_per_ms;
        var current = try saved_spore_pin.loadForSporeLocked(context.io, arena, publish_registry, options.parent_dir, disk.?);
        defer current.deinit();
        if (!std.mem.eql(u8, current.value.id, parent_pin_id.?)) return error.BadManifest;
        try saved_spore_pin.ensureRegistryDurable(arena, publish_registry);
        for (0..options.count) |index| {
            if (builtin.is_test and fork_pin_test_fault.fail_before_child == index) return error.InjectedFailure;
            try saved_spore_pin.publishPreparedRecord(arena, publish_registry, validated_storage.?, prepared_pins.?[index]);
        }
        if (builtin.is_test and fork_pin_test_fault.fail_before_registry_sync) return error.InjectedFailure;
        try saved_spore_pin.syncPreparedRecords(arena, publish_registry);
        if (builtin.is_test and fork_pin_test_fault.fail_before_batch_rename) return error.InjectedFailure;
        try std.Io.Dir.rename(std.Io.Dir.cwd(), fork_out, std.Io.Dir.cwd(), options.out_dir, context.io);
        try chunk_sealer.fsyncDirPath(arena, std.fs.path.dirname(options.out_dir) orelse ".");
        cleanup_stage = false;
        const lock_finished = runtime_disk_fork_capture.monotonicNs();
        pin_publish_ms = (lock_finished -| lock_started) / std.time.ns_per_ms;
    }
    const first_child = try std.fmt.allocPrint(allocator, "{s}/{d:0>6}", .{ options.out_dir, 0 });
    errdefer allocator.free(first_child);
    const last_child = try std.fmt.allocPrint(allocator, "{s}/{d:0>6}", .{ options.out_dir, options.count - 1 });
    return .{
        .parent = options.parent_dir,
        .out_dir = options.out_dir,
        .count = result.count,
        .parent_generation = result.parent_generation,
        .first_generation = result.first_generation,
        .last_generation = result.last_generation,
        .first_child = first_child,
        .last_child = last_child,
        .pin_publish_ms = pin_publish_ms,
        .pin_lock_wait_ms = pin_lock_wait_ms,
    };
}

fn materializeForkDiskStore(
    io: std.Io,
    path_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    parent_dir: []const u8,
    batch_dir: []const u8,
    disk: spore.Disk,
    child_count: usize,
) !void {
    const storage = try saved_spore_pin.storageForDisk(disk);
    const source_index = try rootfs_cas.manifestIndexPath(path_allocator, parent_dir, storage.index_digest);
    const index_bytes = try rootfs_cas.readVerifiedStorageIndexPath(scratch_allocator, source_index, storage);
    defer scratch_allocator.free(index_bytes);
    var parsed = try disk_index.parseDiskIndex(scratch_allocator, index_bytes, try spore.diskIndexDescriptorForStorage(storage));
    defer parsed.deinit();

    const shared_root = try std.fs.path.join(path_allocator, &.{ batch_dir, "shared-disk" });
    const dest_index = try rootfs_cas.manifestIndexPath(path_allocator, shared_root, storage.index_digest);
    try chunk_sealer.ensureDirPath(path_allocator, std.fs.path.dirname(dest_index).?);
    try chunk_sealer.writeFileAtomicDurable(path_allocator, dest_index, index_bytes, 0o444);
    const cas_root = try std.fs.path.join(path_allocator, &.{ shared_root, "cas" });
    const rootfs_root = try std.fs.path.join(path_allocator, &.{ cas_root, "rootfs" });
    const blake3_root = try std.fs.path.join(path_allocator, &.{ rootfs_root, "blake3" });
    const objects_root = try std.fs.path.join(path_allocator, &.{ blake3_root, "objects" });
    try chunk_sealer.ensureDirPath(path_allocator, objects_root);
    var seen = std.StringHashMap(void).init(path_allocator);
    defer seen.deinit();
    for (parsed.value.chunks) |entry| {
        if (seen.contains(entry.digest)) continue;
        try seen.put(entry.digest, {});
        const expected_size = try rootfs_cas.storageChunkLen(storage, entry.logical_chunk);
        const source_object = try rootfs_cas.manifestObjectPath(path_allocator, parent_dir, entry.digest);
        const source_bytes = try rootfs_cas.readVerifiedChunkPath(scratch_allocator, source_object, entry.digest, expected_size);
        defer scratch_allocator.free(source_bytes);
        const dest_object = try rootfs_cas.manifestObjectPath(path_allocator, shared_root, entry.digest);
        const dest_parent = std.fs.path.dirname(dest_object) orelse return error.BadManifest;
        try chunk_sealer.ensureDirPath(path_allocator, dest_parent);
        if (builtin.is_test and fork_pin_test_fault.fail_before_portable_sync == fork_pin_test_fault.portable_sync_count) return error.InjectedFailure;
        switch (try chunk_sealer.publishTrustedFileIfMissing(path_allocator, source_object, dest_object, expected_size)) {
            .copy_required => try chunk_sealer.writeFileAtomicDurable(path_allocator, dest_object, source_bytes, 0o444),
            .linked, .reused_existing => try chunk_sealer.fsyncDirPath(path_allocator, dest_parent),
        }
        if (builtin.is_test) fork_pin_test_fault.portable_sync_count += 1;
        const dest_bytes = try rootfs_cas.readVerifiedChunkPath(scratch_allocator, dest_object, entry.digest, expected_size);
        scratch_allocator.free(dest_bytes);
    }
    // The shared CAS hierarchy is new in this hidden batch. Sync bottom-up so
    // every newly created directory entry is durable before children can see
    // the batch after its final rename.
    const durable_parents = [_][]const u8{ objects_root, blake3_root, rootfs_root, cas_root, shared_root };
    for (durable_parents) |path| {
        if (builtin.is_test and fork_pin_test_fault.fail_before_portable_sync == fork_pin_test_fault.portable_sync_count) return error.InjectedFailure;
        try chunk_sealer.fsyncDirPath(path_allocator, path);
        if (builtin.is_test) fork_pin_test_fault.portable_sync_count += 1;
    }
    for (0..child_count) |index| {
        const child = try std.fmt.allocPrint(path_allocator, "{s}/{d:0>6}", .{ batch_dir, index });
        const cas_link = try std.fs.path.join(path_allocator, &.{ child, "cas" });
        try std.Io.Dir.cwd().deleteFile(io, cas_link);
        try std.Io.Dir.cwd().symLink(io, "../shared-disk/cas", cas_link, .{});
        try chunk_sealer.fsyncDirPath(path_allocator, child);
    }
    try chunk_sealer.fsyncDirPath(path_allocator, batch_dir);
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
    const runtime_root = try local_paths.runtimeRootPath(allocator, context.environ_map);
    defer allocator.free(runtime_root);

    const result = try bundle.pack(allocator, .{
        .io = context.io,
        .spore_dir = options.spore_dir,
        .out_dir = options.out_dir,
        .rootfs_cache_dir = rootfs_cache.path,
        .runtime_root = runtime_root,
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

/// Summarize either manifest version; the fields read here are shared
/// between `spore.Manifest` and `spore.ManifestV1`.
fn summarizeSpore(allocator: std.mem.Allocator, manifest: anytype, vcpu_count: u32) !SporeInspectResult {
    const present_chunks = manifest.memory.chunks.len;

    var annotations = spore.Annotations{};
    errdefer deinitOwnedAnnotations(allocator, &annotations);
    var annotation_it = manifest.annotations.map.iterator();
    while (annotation_it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, entry.value_ptr.*);
        errdefer allocator.free(value);
        annotations.map.put(allocator, key, value) catch return error.OutOfMemory;
    }

    var annotation_keys = try allocator.alloc([]const u8, annotations.map.count());
    errdefer allocator.free(annotation_keys);
    var annotation_index: usize = 0;
    var copied_annotation_it = annotations.map.iterator();
    while (copied_annotation_it.next()) |entry| {
        annotation_keys[annotation_index] = entry.key_ptr.*;
        annotation_index += 1;
    }
    const sessions = try ownSessions(allocator, manifest.sessions);
    errdefer freeSessions(allocator, sessions);
    const network = try ownNetworkSummary(allocator, manifest.network);
    errdefer if (network) |owned_network| freeNetworkSummary(allocator, owned_network);

    return .{
        .version = manifest.version,
        .vm_state_present = true,
        .storage_mode = inspectStorageMode(manifest),
        .vcpu_count = vcpu_count,
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
        .sessions = sessions,
        .network = network,
        .annotations = annotations,
        .annotation_keys = annotation_keys,
    };
}

fn inspectStorageMode(manifest: anytype) []const u8 {
    const rootfs = manifest.rootfs orelse return "memory-only";
    const writable_disk = manifest.disk != null;
    if (rootfs.storage != null) return if (writable_disk) "chunked-rootfs-with-writable-disk" else "chunked-rootfs";
    return if (writable_disk) "exact-rootfs-with-writable-disk" else "exact-rootfs";
}

fn ownNetworkSummary(allocator: std.mem.Allocator, maybe_network: ?spore.Network) !?SporeNetworkSummary {
    const network = maybe_network orelse return null;
    const kind = try allocator.dupe(u8, network.kind);
    errdefer allocator.free(kind);
    const bound_services = try allocator.alloc(spore.NetworkBoundServiceRequirement, network.bound_services.len);
    var initialized: usize = 0;
    errdefer {
        freeBoundServiceRequirements(allocator, bound_services[0..initialized]);
        allocator.free(bound_services);
    }
    for (network.bound_services, 0..) |service, i| {
        const name = try allocator.dupe(u8, service.name);
        const guest_host = allocator.dupe(u8, service.guest_host) catch |err| {
            allocator.free(name);
            return err;
        };
        bound_services[i] = .{
            .name = name,
            .guest_host = guest_host,
            .guest_port = service.guest_port,
        };
        initialized += 1;
    }
    return .{
        .kind = kind,
        .requirements = network.requirements,
        .bound_services = bound_services,
    };
}

fn freeNetworkSummary(allocator: std.mem.Allocator, network: SporeNetworkSummary) void {
    allocator.free(network.kind);
    freeBoundServiceRequirements(allocator, network.bound_services);
    allocator.free(network.bound_services);
}

fn freeBoundServiceRequirements(allocator: std.mem.Allocator, services: []const spore.NetworkBoundServiceRequirement) void {
    for (services) |service| {
        allocator.free(service.name);
        allocator.free(service.guest_host);
    }
}

fn ownSessions(allocator: std.mem.Allocator, sessions: []const spore.Session) ![]Session {
    const out = try allocator.alloc(Session, sessions.len);
    var initialized: usize = 0;
    errdefer {
        freeSessionFields(allocator, out[0..initialized]);
        allocator.free(out);
    }
    for (sessions, 0..) |session, i| {
        const id = allocator.dupe(u8, session.id) catch |err| return err;
        const kind = allocator.dupe(u8, session.kind) catch |err| {
            allocator.free(id);
            return err;
        };
        out[i] = .{
            .id = id,
            .kind = kind,
            .streams = session.streams,
        };
        initialized += 1;
    }
    return out;
}

fn freeSessions(allocator: std.mem.Allocator, sessions: []const Session) void {
    freeSessionFields(allocator, sessions);
    allocator.free(sessions);
}

fn freeSessionFields(allocator: std.mem.Allocator, sessions: []const Session) void {
    for (sessions) |session| {
        allocator.free(session.id);
        allocator.free(session.kind);
    }
}

fn deinitOwnedAnnotations(allocator: std.mem.Allocator, annotations: *spore.Annotations) void {
    var it = annotations.map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    annotations.deinit(allocator);
}

test "inspect spore returns annotation values from saved manifest" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});

    var annotations = spore.Annotations{};
    try annotations.map.put(arena, "cleanroom.create", "created");
    try annotations.map.put(arena, "cleanroom.snapshot", "warm");
    var manifest = annotationTestManifest(annotations);
    const rootfs_digest = "blake3:1111111111111111111111111111111111111111111111111111111111111111";
    const rootfs_device = spore.RootfsDevice{ .mmio_slot = 0 };
    var rootfs_devices = [_]spore.TransportState{.{
        .device_id = spore.rootfs_virtio_blk_device_id,
        .status = 0,
        .device_features_sel = 0,
        .driver_features_sel = 0,
        .driver_features = 0,
        .queue_sel = 0,
        .interrupt_status = 0,
        .queues = &.{},
    }};
    manifest.devices = rootfs_devices[0..];
    manifest.rootfs = .{
        .device = rootfs_device,
        .artifact = .{ .digest = rootfs_digest, .size = 4096 },
    };
    manifest.network = .{
        .bound_services = &.{.{
            .name = "cleanroom-gateway",
            .guest_host = "gateway.cleanroom.internal",
            .guest_port = 8170,
        }},
        .requirements = .{ .exact_host_port = true, .bound_services = true },
    };
    try spore.saveManifest(arena, dir, manifest);

    const inspected = try inspectSpore(allocator, dir);
    defer deinitSporeInspectResult(allocator, inspected);
    try std.testing.expect(inspected.vm_state_present);
    try std.testing.expectEqualStrings("exact-rootfs", inspected.storage_mode);
    try std.testing.expectEqualStrings("created", inspected.annotations.map.get("cleanroom.create").?);
    try std.testing.expectEqualStrings("warm", inspected.annotations.map.get("cleanroom.snapshot").?);
    try std.testing.expectEqual(@as(usize, 1), inspected.sessions.len);
    try std.testing.expectEqualStrings(spore.default_session_id, inspected.sessions[0].id);
    try std.testing.expect(inspected.sessions[0].streams.terminal);
    const network = inspected.network orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(spore.network_kind_spore, network.kind);
    try std.testing.expect(network.requirements.exact_host_port);
    try std.testing.expect(network.requirements.bound_services);
    try std.testing.expectEqual(@as(usize, 1), network.bound_services.len);
    try std.testing.expectEqualStrings("cleanroom-gateway", network.bound_services[0].name);
    try std.testing.expectEqualStrings("gateway.cleanroom.internal", network.bound_services[0].guest_host);
    try std.testing.expectEqual(@as(u16, 8170), network.bound_services[0].guest_port);
}

test "run from generation state uses explicit params" {
    const allocator = std.testing.allocator;
    const params =
        \\{"run_id":"k8s-run-1","child_id":7,"parallel_index":7,"parallel_count":1000,"fork_index":7,"fork_count":1000,"fork_batch_id":"batch-1","vm_id":"spore-child-7","generation":99,"resume_entropy_seed":"0123456789abcdef0123456789abcdef"}
    ;
    const prepared = try prepareRunFromGenerationState(allocator, .{
        .generation = 42,
        .interrupt_status = 0,
        .params_b64 = "",
    }, params);
    const resume_generation = prepared.resume_generation orelse return error.TestUnexpectedResult;
    defer allocator.free(resume_generation.params_b64);

    try std.testing.expectEqualStrings(params, prepared.start_generation_params.?);

    var restored = generation.Device{};
    try restored.restore(allocator, resume_generation);
    try std.testing.expectEqual(@as(u64, 42), restored.generation);
    try std.testing.expectEqual(@as(u32, generation.irq_generation_changed), restored.interrupt_status);
    try std.testing.expectEqualStrings(params, restored.paramsPayload());
}

test "run from generation state omits empty generation when params are absent" {
    const prepared = try prepareRunFromGenerationState(std.testing.allocator, .{
        .generation = 0,
        .interrupt_status = 0,
        .params_b64 = "",
    }, null);
    try std.testing.expect(prepared.resume_generation == null);
    try std.testing.expect(prepared.start_generation_params == null);
}

fn annotationTestManifest(annotations: spore.Annotations) spore.Manifest {
    return .{
        .annotations = annotations,
        .platform = .{
            .cpu_profile = "sporevm-aarch64-v0",
            .device_model_version = 4,
            .ram_base = 0x8000_0000,
            .ram_size = 1,
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
        .sessions = &annotation_test_sessions,
        .memory = .{ .logical_size = 1, .chunk_size = spore.chunk_size, .zero_chunks = &.{0} },
    };
}

const annotation_test_sessions = [_]spore.Session{.{
    .id = spore.default_session_id,
    .streams = .{
        .stdout = false,
        .stderr = false,
        .terminal = true,
    },
}};

test "inspect spore summarizes multi-vcpu v1 manifests" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});

    var annotations = spore.Annotations{};
    try annotations.map.put(arena, "cleanroom.bake", "warm");
    var vcpus = [_]spore.VcpuState{ testVcpuState(0), testVcpuState(1) };
    const redists = [_]gicv3.RedistributorState{
        .{ .mpidr = vcpus[0].mpidr, .regs = &.{} },
        .{ .mpidr = vcpus[1].mpidr, .regs = &.{} },
    };
    const manifest = spore.ManifestV1{
        .annotations = annotations,
        .platform = .{
            .cpu_profile = "sporevm-aarch64-v0",
            .device_model_version = 4,
            .vcpu_count = 2,
            .ram_base = 0x8000_0000,
            .ram_size = 1,
            .gic_dist_base = 0x0800_0000,
            .gic_redist_base = 0x0802_0000,
            .gic_redist_stride = 0x2_0000,
            .counter_frequency_hz = 24_000_000,
        },
        .machine = .{
            .vcpus = &vcpus,
            .gic = .{
                .kind = .gicv3_multi,
                .gicv3_multi = .{
                    .dist_regs = &.{},
                    .redistributors = &redists,
                    .line_levels = &.{},
                },
            },
        },
        .devices = &.{},
        .generation = .{ .generation = 1, .interrupt_status = 0, .params_b64 = "" },
        .memory = .{ .logical_size = 1, .chunk_size = spore.chunk_size, .zero_chunks = &.{0} },
    };
    try spore.saveManifestV1(arena, dir, manifest);

    const inspected = try inspectSpore(allocator, dir);
    defer deinitSporeInspectResult(allocator, inspected);
    try std.testing.expectEqual(@as(u32, spore.format_version_v1), inspected.version);
    try std.testing.expect(inspected.vm_state_present);
    try std.testing.expectEqualStrings("memory-only", inspected.storage_mode);
    try std.testing.expectEqual(@as(u32, 2), inspected.vcpu_count);
    try std.testing.expectEqualStrings("gicv3_multi", inspected.gic_kind);
    try std.testing.expectEqualStrings("warm", inspected.annotations.map.get("cleanroom.bake").?);
}

test "pinned offline fork owns duplicate RAM chunks and independent child disk pins" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const cache = try std.fs.path.join(arena, &.{ root, "cache" });
    const runtime_root = try std.fs.path.join(arena, &.{ root, "runtime" });
    const parent = try std.fs.path.join(arena, &.{ root, "parent.spore" });
    const children = try std.fs.path.join(arena, &.{ root, "children" });
    const nested = try std.fs.path.join(arena, &.{ root, "nested" });
    try std.Io.Dir.cwd().createDirPath(io, parent);

    const ram = try arena.alloc(u8, 2 * spore.chunk_size);
    @memset(ram, 0x5a);
    const memory = try spore.saveMemoryWithBacking(arena, parent, ram);
    try std.testing.expectEqual(@as(usize, 2), memory.chunks.len);
    try std.testing.expectEqualStrings(memory.chunks[0].digest, memory.chunks[1].digest);

    const disk_payload = try arena.alloc(u8, 512);
    @memset(disk_payload, 0x6b);
    const disk_chunk_id = chunk.ChunkId.fromContents(disk_payload);
    const disk_chunk_hex = disk_chunk_id.toHex();
    const disk_chunk_digest = try std.fmt.allocPrint(arena, "{s}{s}", .{ spore.rootfs_digest_prefix, disk_chunk_hex[0..] });
    const disk_chunks = [_]disk_index.DiskIndexChunk{.{ .logical_chunk = 0, .digest = disk_chunk_digest }};
    const disk_index_value = disk_index.DiskIndex{
        .kind = disk_index.disk_index_kind,
        .logical_size = @intCast(disk_payload.len),
        .chunk_size = spore.disk_chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .object_namespace = spore.rootfs_storage_object_namespace,
        .chunks = &disk_chunks,
    };
    const encoded = try disk_index.encodeCanonicalAlloc(arena, disk_index_value);
    const index_path = try rootfs_cas.manifestIndexPath(arena, cache, encoded.digest);
    try chunk_sealer.ensureDirPath(arena, std.fs.path.dirname(index_path).?);
    try chunk_sealer.writeFileAtomicDurable(arena, index_path, encoded.bytes, 0o444);
    const storage = spore.RootfsStorage{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = .{ .mmio_slot = 1 },
        .logical_size = @intCast(disk_payload.len),
        .chunk_size = spore.disk_chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .index_digest = encoded.digest,
        .base_identity = encoded.digest,
        .object_namespace = spore.rootfs_storage_object_namespace,
    };
    const disk = spore.Disk{
        .kind = spore.disk_kind_chunk_index,
        .device = storage.device,
        .size = storage.logical_size,
        .base = storage.index_digest,
        .chunk_size = storage.chunk_size,
        .hash_algorithm = storage.hash_algorithm,
        .object_namespace = storage.object_namespace,
        .layers = &.{},
    };
    var manifest = annotationTestManifest(.{});
    manifest.platform.ram_size = ram.len;
    manifest.memory = memory;
    var devices = [_]spore.TransportState{
        .{ .device_id = 3, .status = 0, .device_features_sel = 0, .driver_features_sel = 0, .driver_features = 0, .queue_sel = 0, .interrupt_status = 0, .queues = &.{} },
        .{ .device_id = spore.rootfs_virtio_blk_device_id, .status = 0, .device_features_sel = 0, .driver_features_sel = 0, .driver_features = 0, .queue_sel = 0, .interrupt_status = 0, .queues = &.{} },
    };
    manifest.devices = &devices;
    manifest.rootfs = .{ .device = storage.device, .artifact = .{ .digest = storage.index_digest, .size = storage.logical_size }, .storage = storage };
    manifest.disk = disk;
    try spore.saveManifest(arena, parent, manifest);
    const parent_index_path = try rootfs_cas.manifestIndexPath(arena, parent, encoded.digest);
    try chunk_sealer.ensureDirPath(arena, std.fs.path.dirname(parent_index_path).?);
    try chunk_sealer.writeFileAtomicDurable(arena, parent_index_path, encoded.bytes, 0o444);
    const parent_object_path = try rootfs_cas.manifestObjectPath(arena, parent, disk_chunk_digest);
    try chunk_sealer.ensureDirPath(arena, std.fs.path.dirname(parent_object_path).?);
    try chunk_sealer.writeFileAtomicDurable(arena, parent_object_path, disk_payload, 0o444);
    const cache_object_path = try rootfs_cas.manifestObjectPath(arena, cache, disk_chunk_digest);
    try chunk_sealer.ensureDirPath(arena, std.fs.path.dirname(cache_object_path).?);
    try chunk_sealer.writeFileAtomicDurable(arena, cache_object_path, disk_payload, 0o444);
    const verified_local_object = try rootfs_cas.readVerifiedChunkPath(allocator, parent_object_path, disk_chunk_digest, disk_payload.len);
    defer allocator.free(verified_local_object);
    try std.testing.expectEqualSlices(u8, disk_payload, verified_local_object);
    const verified_cache_object = try rootfs_cas.readVerifiedChunkPath(allocator, cache_object_path, disk_chunk_digest, disk_payload.len);
    defer allocator.free(verified_cache_object);
    try std.testing.expectEqualSlices(u8, disk_payload, verified_cache_object);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache);
    try env.put(local_paths.runtime_dir_env, runtime_root);
    try spore.writeLocalMemoryBackingProof(arena, &env, parent, memory, ram.len);
    const context = Context{ .io = io, .environ_map = &env };

    // A portable/local-CAS fork stays hidden until every new CAS directory
    // entry has been synced bottom-up. Failure at any boundary leaves no
    // visible batch; the final rename is a separate injected boundary.
    defer fork_pin_test_fault = .{};
    for (0..6) |sync_index| {
        const failed_portable = try std.fmt.allocPrint(arena, "{s}/portable-sync-{d}", .{ root, sync_index });
        fork_pin_test_fault = .{ .fail_before_portable_sync = sync_index };
        try std.testing.expectError(error.InjectedFailure, fork(context, allocator, .{
            .parent_dir = parent,
            .out_dir = failed_portable,
            .count = 1,
        }));
        try std.testing.expectEqual(sync_index, fork_pin_test_fault.portable_sync_count);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, failed_portable, .{ .follow_symlinks = false }));
    }
    const failed_portable_rename = try std.fs.path.join(arena, &.{ root, "portable-rename" });
    fork_pin_test_fault = .{ .fail_before_batch_rename = true };
    try std.testing.expectError(error.InjectedFailure, fork(context, allocator, .{
        .parent_dir = parent,
        .out_dir = failed_portable_rename,
        .count = 1,
    }));
    try std.testing.expectEqual(@as(usize, 6), fork_pin_test_fault.portable_sync_count);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, failed_portable_rename, .{ .follow_symlinks = false }));
    fork_pin_test_fault = .{};

    var parent_lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, cache);
    defer parent_lock.deinit();
    const parent_registry = try saved_spore_pin.LockedRegistry.init(arena, cache, &parent_lock);
    const parent_pin = try saved_spore_pin.create(io, arena, parent_registry, parent, disk);
    const parent_manifest_path = try std.fs.path.join(arena, &.{ parent, "manifest.json" });
    const parent_ref_path = try std.fs.path.join(arena, &.{ parent, saved_spore_pin.reference_file });
    const parent_record_path = try std.fmt.allocPrint(arena, "{s}/{s}/{s}.json", .{ cache, saved_spore_pin.dir_name, parent_pin });
    const manifest_before_fault = try std.Io.Dir.cwd().readFileAlloc(io, parent_manifest_path, allocator, .limited(saved_spore_pin.max_manifest_bytes));
    defer allocator.free(manifest_before_fault);
    const ref_before_fault = try std.Io.Dir.cwd().readFileAlloc(io, parent_ref_path, allocator, .limited(saved_spore_pin.max_record_bytes));
    defer allocator.free(ref_before_fault);
    const record_before_fault = try std.Io.Dir.cwd().readFileAlloc(io, parent_record_path, allocator, .limited(saved_spore_pin.max_record_bytes));
    defer allocator.free(record_before_fault);
    var replacement_manifest = manifest;
    replacement_manifest.generation.generation += 1;
    saved_spore_pin.publish_test_fault = .{ .fail_before_complete_stamp = true };
    defer saved_spore_pin.publish_test_fault = .{};
    try std.testing.expectError(error.InjectedFailure, saved_spore_pin.publishManifest(io, arena, parent_registry, parent, disk, replacement_manifest));
    saved_spore_pin.publish_test_fault = .{};
    const manifest_after_fault = try std.Io.Dir.cwd().readFileAlloc(io, parent_manifest_path, allocator, .limited(saved_spore_pin.max_manifest_bytes));
    defer allocator.free(manifest_after_fault);
    const ref_after_fault = try std.Io.Dir.cwd().readFileAlloc(io, parent_ref_path, allocator, .limited(saved_spore_pin.max_record_bytes));
    defer allocator.free(ref_after_fault);
    const record_after_fault = try std.Io.Dir.cwd().readFileAlloc(io, parent_record_path, allocator, .limited(saved_spore_pin.max_record_bytes));
    defer allocator.free(record_after_fault);
    try std.testing.expectEqualSlices(u8, manifest_before_fault, manifest_after_fault);
    try std.testing.expectEqualSlices(u8, ref_before_fault, ref_after_fault);
    try std.testing.expectEqualSlices(u8, record_before_fault, record_after_fault);
    const pins_after_fault = try saved_spore_pin.list(io, arena, cache);
    try std.testing.expectEqual(@as(usize, 1), pins_after_fault.len);
    const failed_stamp_path = try rootfs_cas.storageCompleteStampPath(arena, cache, encoded.digest);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, failed_stamp_path, .{ .follow_symlinks = false }));
    const active_leases_path = try std.fs.path.join(arena, &.{ runtime_root, runtime_disk_lease.active_dir_name });
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, active_leases_path, .{ .follow_symlinks = false }));
    parent_lock.deinit();

    const forked = try fork(context, allocator, .{ .parent_dir = parent, .out_dir = children, .count = 2 });
    defer deinitForkResult(allocator, forked);
    try std.testing.expect(forked.pin_lock_wait_ms != null);
    try std.testing.expect(forked.pin_publish_ms != null);
    const moved_children = try std.fs.path.join(arena, &.{ root, "moved-children" });
    try std.Io.Dir.renameAbsolute(children, moved_children, io);
    try chunk_sealer.fsyncDirPath(arena, root);
    const moved_first_child = try std.fmt.allocPrint(arena, "{s}/000000", .{moved_children});
    var child_ids: [2][]const u8 = undefined;
    for (0..2) |index| {
        const child = try std.fmt.allocPrint(arena, "{s}/{d:0>6}", .{ moved_children, index });
        var parsed = try spore.loadManifest(arena, child);
        defer parsed.deinit();
        try std.testing.expectEqualStrings(encoded.digest, parsed.value.disk.?.base);
        const child_cas = try std.fs.path.join(arena, &.{ child, "cas" });
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, child_cas, .{ .follow_symlinks = false }));
        var lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, cache);
        defer lock.deinit();
        const registry = try saved_spore_pin.LockedRegistry.init(arena, cache, &lock);
        var pin = try saved_spore_pin.loadForSporeLocked(io, arena, registry, child, parsed.value.disk.?);
        child_ids[index] = try arena.dupe(u8, pin.value.id);
        pin.deinit();
        lock.deinit();
    }
    try std.testing.expect(!std.mem.eql(u8, child_ids[0], child_ids[1]));

    try std.Io.Dir.cwd().deleteTree(io, parent);
    var remove_lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, cache);
    defer remove_lock.deinit();
    const remove_registry = try saved_spore_pin.LockedRegistry.init(arena, cache, &remove_lock);
    try saved_spore_pin.remove(io, arena, remove_registry, parent_pin);
    remove_lock.deinit();
    const prune_result = try system.prune(allocator, io, .{
        .cache_root = cache,
        .runtime_root = runtime_root,
        .dry_run = false,
        .include_rootfs_chunks = true,
        .max_bytes = 0,
    }, std.Io.Clock.real.now(io).nanoseconds);
    defer system.deinitRootfsPruneResult(allocator, prune_result);
    try std.testing.expectEqual(@as(usize, 0), prune_result.deleted_count);
    const gc_result = try system.gc(allocator, io, .{ .cache_root = cache, .runtime_root = runtime_root, .dry_run = false });
    defer system.deinitRootfsGcResult(allocator, gc_result);
    try std.testing.expectEqual(@as(usize, 0), gc_result.deleted_count);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, parent_object_path, .{ .follow_symlinks = false }));
    const verified_rooted_object = try rootfs_cas.readVerifiedChunkPath(allocator, cache_object_path, disk_chunk_digest, disk_payload.len);
    defer allocator.free(verified_rooted_object);
    try std.testing.expectEqualSlices(u8, disk_payload, verified_rooted_object);

    for (0..2) |index| {
        const child = try std.fmt.allocPrint(arena, "{s}/{d:0>6}", .{ moved_children, index });
        var parsed = try spore.loadManifest(arena, child);
        defer parsed.deinit();
        try std.testing.expect(parsed.value.memory.backing != null);
        const backing_plan = try spore.openProvenLocalMemoryBacking(arena, &env, child, parsed.value.memory, ram.len);
        try std.testing.expectEqual(spore.LocalBackingRestoreSource.local_backing, backing_plan.source);
        try std.testing.expectEqual(spore.LocalBackingRestoreReason.proof_valid, backing_plan.reason);
        defer if (backing_plan.fd) |fd| {
            _ = std.c.close(fd);
        };
        const restored = try arena.alloc(u8, ram.len);
        try spore.loadMemory(arena, child, parsed.value.memory, restored);
        try std.testing.expectEqualSlices(u8, ram, restored);
        var runtime_disk = try runtime_disk_mod.open(context, allocator, .{
            .rootfs = parsed.value.rootfs.?,
            .disk = parsed.value.disk.?,
            .spore_dir = child,
        });
        defer runtime_disk.deinit();
        var disk_byte = [_]u8{0xaa};
        try runtime_disk.chunk_mapped.?.readAt(&disk_byte, 0);
        try std.testing.expectEqual(disk_payload[0], disk_byte[0]);
        try runtime_disk.chunk_mapped.?.writeAt(&.{0x7b}, 0);
        try runtime_disk.chunk_mapped.?.readAt(&disk_byte, 0);
        try std.testing.expectEqual(@as(u8, 0x7b), disk_byte[0]);
    }
    const nested_result = try fork(context, allocator, .{ .parent_dir = moved_first_child, .out_dir = nested, .count = 1 });
    defer deinitForkResult(allocator, nested_result);

    // A pin failure never exposes a partial batch. Pins already published for
    // hidden children are safe orphans and remain explicitly reclaimable.
    const failed_batch = try std.fs.path.join(arena, &.{ root, "failed-children" });
    fork_pin_test_fault.fail_before_child = 1;
    try std.testing.expectError(error.InjectedFailure, fork(context, allocator, .{
        .parent_dir = moved_first_child,
        .out_dir = failed_batch,
        .count = 2,
    }));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, failed_batch, .{ .follow_symlinks = false }));
    fork_pin_test_fault = .{};
    var orphan_lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, cache);
    const pins_after_failed_batch = try saved_spore_pin.list(io, arena, cache);
    try std.testing.expect(pins_after_failed_batch.len >= 4);
    orphan_lock.deinit();
    const failed_sync_batch = try std.fs.path.join(arena, &.{ root, "failed-sync-children" });
    fork_pin_test_fault.fail_before_registry_sync = true;
    try std.testing.expectError(error.InjectedFailure, fork(context, allocator, .{
        .parent_dir = moved_first_child,
        .out_dir = failed_sync_batch,
        .count = 1,
    }));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, failed_sync_batch, .{ .follow_symlinks = false }));
    fork_pin_test_fault = .{ .fail_before_batch_rename = true };
    const failed_rename_batch = try std.fs.path.join(arena, &.{ root, "failed-rename-children" });
    try std.testing.expectError(error.InjectedFailure, fork(context, allocator, .{
        .parent_dir = moved_first_child,
        .out_dir = failed_rename_batch,
        .count = 1,
    }));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, failed_rename_batch, .{ .follow_symlinks = false }));
    fork_pin_test_fault = .{};

    // A process-owned active lease protects unread lazy disk data after every
    // visible save and pin has been removed.
    var active_manifest = try spore.loadManifest(arena, moved_first_child);
    defer active_manifest.deinit();
    var active_runtime = try runtime_disk_mod.open(context, allocator, .{
        .rootfs = active_manifest.value.rootfs.?,
        .disk = active_manifest.value.disk.?,
        .spore_dir = moved_first_child,
    });
    defer active_runtime.deinit();
    try std.Io.Dir.cwd().deleteTree(io, moved_children);
    try std.Io.Dir.cwd().deleteTree(io, nested);
    var unpin_lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, cache);
    defer unpin_lock.deinit();
    const unpin_registry = try saved_spore_pin.LockedRegistry.init(arena, cache, &unpin_lock);
    const remaining_pins = try saved_spore_pin.list(io, arena, cache);
    for (remaining_pins) |entry| try saved_spore_pin.remove(io, arena, unpin_registry, entry.id);
    unpin_lock.deinit();
    const leased_gc = try system.gc(allocator, io, .{ .cache_root = cache, .runtime_root = runtime_root, .dry_run = false });
    defer system.deinitRootfsGcResult(allocator, leased_gc);
    try std.testing.expectEqual(@as(usize, 0), leased_gc.deleted_count);
    var unread = [_]u8{0xaa};
    try active_runtime.chunk_mapped.?.readAt(&unread, 0);
    try std.testing.expectEqual(disk_payload[0], unread[0]);
}

fn testVcpuState(index: u32) spore.VcpuState {
    return .{
        .index = index,
        .mpidr = topology.mpidrForIndex(index),
        .gprs = [_]u64{0} ** 31,
        .pc = 0,
        .cpsr = 0,
        .fpcr = 0,
        .fpsr = 0,
        .simd = [_][2]u64{.{ 0, 0 }} ** 32,
        .sys_regs = &.{},
        .icc_regs = &.{},
        .vtimer = .{ .cntvct = 0, .cntv_ctl = 0, .cntv_cval = 0 },
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

fn resolveRequiredCacheRoot(
    requested: CacheRoot,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    kind: CacheKind,
) !ResolvedCacheRoot {
    return switch (requested) {
        .none => error.CacheUnavailable,
        .path => |path| .{ .path = path },
        .env => switch (kind) {
            .rootfs => .{ .path = try local_paths.rootfsCacheRootPath(allocator, environ_map), .owned = true },
            .bundle => .{ .path = try local_paths.bundleCacheRootPath(allocator, environ_map), .owned = true },
        },
    };
}

fn rootfsBundlePolicy(policy: RootfsBundlePolicy) bundle.RootfsBundlePolicy {
    return switch (policy) {
        .exact_bytes => .exact_bytes,
        .metadata_only => .metadata_only,
    };
}
