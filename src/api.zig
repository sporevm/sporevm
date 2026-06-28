//! Product API boundary used by the CLI and embedding layers.
//!
//! Import this module through `libspore`. Backend, device, storage, monitor, and
//! CLI modules stay internal; this file owns the product operations and result
//! contracts callers should build against.

const std = @import("std");

const bundle = @import("bundle.zig");
const contracts = @import("contracts.zig");
const context_mod = @import("context.zig");
const lifecycle = @import("lifecycle.zig");
const local_paths = @import("local_paths.zig");
const memory_config = @import("memory.zig");
const platform = @import("platform.zig");
const resume_mod = @import("resume.zig");
const rootfs_mod = @import("rootfs.zig");
const run_mod = @import("run.zig");
const spore = @import("spore.zig");
const spore_net_policy = @import("spore_net_policy.zig");
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
pub const CaptureTrigger = run_mod.CaptureTrigger;
pub const ImagePullPolicy = run_mod.PullPolicy;
pub const NetworkMode = run_mod.NetworkMode;
pub const NetworkConfig = run_mod.NetworkPolicy;
pub const NetworkCapabilities = spore_net_policy.NetworkCapabilities;
pub const NetworkDefault = spore_net_policy.NetworkDefault;
pub const NetworkPolicy = spore_net_policy.NetworkPolicy;
pub const NetworkRule = spore_net_policy.NetworkRule;
pub const BoundService = spore_net_policy.BoundService;
pub const BoundServiceTarget = spore_net_policy.BoundServiceTarget;
pub const Rootfs = run_mod.Rootfs;
pub const Annotations = spore.Annotations;
pub const validateAnnotations = spore.validateAnnotations;
pub const RootfsBuildOptions = rootfs_mod.BuildRequest;
pub const RootfsBuildResult = rootfs_mod.BuildResult;
pub const RootfsCasPreloadOptions = rootfs_mod.CasPreloadRequest;
pub const RootfsCasPreloadResult = rootfs_mod.CasPreloadResult;
pub const RootfsImportOciOptions = rootfs_mod.ImportOciRequest;
pub const RootfsImportOciResult = rootfs_mod.ImportOciResult;
pub const RootfsPlatform = rootfs_mod.Platform;
pub const RootfsResolveOptions = rootfs_mod.ResolveRequest;
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
pub const CreateNamedOptions = lifecycle.CreateNamedOptions;
pub const ResumeNamedOptions = lifecycle.ResumeNamedOptions;
pub const ForkNamedOptions = lifecycle.ForkNamedOptions;
pub const ExecNamedOptions = lifecycle.ExecNamedOptions;
pub const NamedNetworkOptions = lifecycle.NamedNetworkOptions;
pub const SnapshotNamedOptions = lifecycle.SnapshotNamedOptions;
pub const SuspendNamedOptions = lifecycle.SuspendNamedOptions;
pub const RemoveNamedOptions = lifecycle.RemoveNamedOptions;
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
    memory: MemoryConfig = .{},
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    capture_path: ?[]const u8 = null,
    capture_trigger: CaptureTrigger = .exit,
    continue_after_capture: bool = false,
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
    memory: MemoryConfig = .{},
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    capture_path: ?[]const u8 = null,
    capture_trigger: CaptureTrigger = .exit,
    continue_after_capture: bool = false,
    annotations: Annotations = .{},
    network: NetworkMode = .disabled,
    network_policy: NetworkConfig = .{},
    spore_executable: []const u8 = "spore",
    debug: bool = false,
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
    debug: bool = false,
    /// Optional synchronous event sink. Output byte slices are callback-scoped.
    events: ?EventSink = null,
};

/// Resume a captured spore to its recorded continuation point.
pub const ResumeOptions = struct {
    backend: Backend = .auto,
    spore_dir: []const u8,
    generation_path: ?[]const u8 = null,
    timeout_ms: u64 = 30_000,
    spore_executable: []const u8 = "spore",
    debug: bool = false,
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
        .rootfs_blake3 = result.rootfs_blake3,
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
    return .{
        .rootfs_path = rootfs_path,
        .metadata_path = metadata_path,
        .local_ref_path = local_ref_path,
        .resolved_image_ref = resolved_image_ref,
        .image_manifest_digest = image_manifest_digest,
        .rootfs_blake3 = result.rootfs_blake3,
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
    const manifest = try spore.loadManifest(allocator, spore_dir);
    defer manifest.deinit();
    return summarizeSpore(allocator, manifest.value);
}

/// Release memory owned by a `SporeInspectResult`.
pub fn deinitSporeInspectResult(allocator: std.mem.Allocator, result: SporeInspectResult) void {
    allocator.free(result.platform.arch);
    allocator.free(result.platform.cpu_profile);
    if (result.memory_backing_kind) |kind| allocator.free(kind);
    for (result.annotation_keys) |key| allocator.free(key);
    allocator.free(result.annotation_keys);
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
        .memory = options.memory,
        .vcpus = options.vcpus,
        .guest_port = options.guest_port,
        .timeout_ms = options.timeout_ms,
        .stream_output = false,
        .capture_path = options.capture_path,
        .capture_trigger = options.capture_trigger,
        .continue_after_capture = options.continue_after_capture,
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
    if (options.capture_path != null and options.rootfs_path != null and options.image_ref == null) {
        return error.InvalidRootfsInput;
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rootfs = try run_mod.resolveRootfsInputDetailed(init, arena, .{
        .rootfs_path = options.rootfs_path,
        .image_ref = options.image_ref,
        .pull_policy = options.image_pull_policy,
        .command_name = "run",
        .record_artifact = options.capture_path != null,
    });
    const default_kernel = options.kernel_path == null and init.environ_map.get("SPOREVM_KERNEL_IMAGE") == null;
    const default_initrd = options.initrd_path == null and init.environ_map.get("SPOREVM_RUN_INITRD") == null;
    const kernel_path = options.kernel_path orelse try run_mod.resolveDefaultKernelPath(init, arena);
    const initrd_path = try run_mod.resolveConfiguredInitrdPath(init, options.initrd_path);

    return run_mod.execute(.{ .io = init.io, .environ_map = init.environ_map }, arena, .{
        .backend = options.backend,
        .kernel_path = kernel_path,
        .initrd_path = initrd_path,
        .auto_memory_hotplug_capable = default_kernel and default_initrd,
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
        .annotations = options.annotations,
        .network = options.network,
        .network_policy = options.network_policy,
        .spore_executable = options.spore_executable,
        .debug = options.debug,
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
        .memory = try memory_config.fromManifestBytes(manifest.value.platform.ram_size),
        .vcpus = options.vcpus,
        .guest_port = options.guest_port,
        .timeout_ms = options.timeout_ms,
        .stream_output = false,
        .capture_path = options.capture_path,
        .capture_trigger = options.capture_trigger,
        .continue_after_capture = options.continue_after_capture,
        .annotations = manifest.value.annotations,
        .network = network_options.network,
        .network_policy = network_options.policy,
        .spore_executable = options.spore_executable,
        .debug = options.debug,
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
        .generation_path = options.generation_path,
        .timeout_ms = options.timeout_ms,
        .spore_executable = options.spore_executable,
        .debug = options.debug,
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

/// Resume a spore checkpoint as a long-lived named VM.
pub fn resumeNamed(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: ResumeNamedOptions,
) !NamedLifecycleResult {
    return lifecycle.resumeNamed(init, allocator, options);
}

/// Fork a ready diskless named VM into ready named child VMs.
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

/// Snapshot a named VM while it keeps running.
pub fn snapshotNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: SnapshotNamedOptions,
) !NamedLifecycleResult {
    return lifecycle.snapshotNamed(context, allocator, options);
}

/// Suspend a named VM into a spore checkpoint and remove the live registry entry.
pub fn suspendNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: SuspendNamedOptions,
) !NamedLifecycleResult {
    return lifecycle.suspendNamed(context, allocator, options);
}

/// Remove a named VM registry entry, stopping the monitor when it is ready.
pub fn removeNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: RemoveNamedOptions,
) !NamedLifecycleResult {
    return lifecycle.removeNamed(context, allocator, options);
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
    var annotation_keys = try allocator.alloc([]const u8, manifest.annotations.map.count());
    var annotation_index: usize = 0;
    errdefer {
        for (annotation_keys[0..annotation_index]) |key| allocator.free(key);
        allocator.free(annotation_keys);
    }
    var annotation_it = manifest.annotations.map.iterator();
    while (annotation_it.next()) |entry| {
        annotation_keys[annotation_index] = try allocator.dupe(u8, entry.key_ptr.*);
        annotation_index += 1;
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
        .annotation_keys = annotation_keys,
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
