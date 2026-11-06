//! Product operations and result contracts used by the CLI.

const std = @import("std");
const TestDir = @import("test_dir.zig").TestDir;
const builtin = @import("builtin");

const aarch64_topology = @import("aarch64/topology.zig");
const architecture = @import("architecture.zig");
const backend_mod = @import("backend.zig");
const boot_assets = @import("boot_assets.zig");
const bundle = @import("bundle.zig");
const chunk_sealer = @import("chunk_sealer.zig");
const contracts = @import("contracts.zig");
const context_mod = @import("context.zig");
const generation = @import("generation.zig");
const image_archive = @import("image_archive.zig");
const image_store = @import("image_store.zig");
const local_paths = @import("local_paths.zig");
const manifest_test_support = @import("manifest_test_support.zig");
const memory_config = @import("memory.zig");
const platform = @import("platform.zig");
const attach_mod = @import("attach.zig");
const rootfs_mod = @import("rootfs.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const resource = @import("resource.zig");
const saved_spore_fork = @import("saved_spore_fork.zig");
const saved_spore_ownership = @import("saved_spore_ownership.zig");
const saved_spore_pin = @import("saved_spore_pin.zig");
const guest_request = @import("guest_request.zig");
const rootfs_input = @import("rootfs_input.zig");
const events_mod = @import("events.zig");
const machine_output = @import("machine_output.zig");
const run_mod = @import("run.zig");
const gicv3 = @import("aarch64/gicv3.zig");
const spore = @import("spore.zig");
const spore_fork = @import("spore_fork.zig");
const spore_net_policy = @import("spore_net_policy.zig");
const spore_store = @import("spore_store.zig");
const topology = @import("topology.zig");

pub const ImageArchivePackOptions = image_archive.PackOptions;
pub const ImageArchivePackResult = image_archive.PackResult;
pub const ImageArchiveUnpackOptions = image_archive.UnpackOptions;
pub const ImageArchiveUnpackResult = image_archive.UnpackResult;
pub const ImagePushOptions = image_store.PushOptions;
pub const ImagePushResult = image_store.PushResult;

/// Process IO and environment access shared by product operations.
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

/// Architecture-discriminated `spore.host-info.v3` host facts.
pub const HostInfo = platform.HostInfo;

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

pub const PullResult = spore_store.PullResult;
pub const BundleChildSummary = contracts.BundleChildSummary;
pub const InspectBundleResult = contracts.InspectBundleResult;

pub const Backend = backend_mod.Backend;
pub const MemoryConfig = run_mod.MemoryConfig;
pub const SaveTrigger = run_mod.SaveTrigger;
pub const ImagePullPolicy = rootfs_input.PullPolicy;
pub const Network = spore_net_policy.Network;
pub const BoundServiceBinding = spore_net_policy.BoundServiceBinding;
pub const BoundServiceBindingDiagnostic = spore_net_policy.BoundServiceBindingDiagnostic;
pub const Rootfs = run_mod.Rootfs;
pub const Annotations = spore.Annotations;
pub const NetworkRequirements = spore.NetworkRequirements;
pub const NetworkBoundServiceRequirement = spore.NetworkBoundServiceRequirement;
pub const Session = spore.Session;
pub const RootfsBuildOptions = rootfs_mod.BuildRequest;
pub const RootfsBuildResult = rootfs_mod.BuildResult;
pub const RootfsCasPreloadOptions = rootfs_mod.CasPreloadRequest;
pub const RootfsCasPreloadResult = rootfs_mod.CasPreloadResult;
pub const RootfsImportOciOptions = rootfs_mod.ImportOciRequest;
pub const RootfsImportOciResult = rootfs_mod.ImportOciResult;
pub const RootfsImportTarOptions = rootfs_mod.ImportTarRequest;
pub const RootfsImportTarResult = rootfs_mod.ImportTarResult;
pub const Architecture = architecture.Architecture;
pub const ResourceType = resource.Type;
pub const Portability = resource.Portability;
pub const RootfsResolveOptions = rootfs_mod.ResolveRequest;
pub const InjectedFile = boot_assets.InjectedFile;
pub const RunResult = events_mod.Result;
pub const AttachResult = events_mod.Result;
pub const RunEvent = events_mod.RunEvent;
pub const EventSink = events_mod.EventSink;
pub const ClassifiedFailure = machine_output.CliError;

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
    /// Replaces the image's OCI Entrypoint when set. The image Cmd still
    /// supplies the default command when `command` is empty.
    image_entrypoint: ?[]const []const u8 = null,
    /// Guest command and arguments. Empty uses OCI Entrypoint and Cmd for an
    /// image-backed run; non-image managed runs require an explicit command.
    command: []const []const u8 = &.{},
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
    network: Network = .disabled,
    spore_executable: []const u8 = "spore",
    debug: bool = false,
    /// Optional synchronous event sink. Output byte slices are callback-scoped.
    events: ?EventSink = null,
};

/// Run a new command from a checkpoint.
///
/// This is the product API for `spore run --from`: it reads the manifest,
/// restores machine/rootfs/disk policy from the checkpoint, then executes a new
/// guest command. Use `attachSpore` to attach to a recorded session.
pub const RunFromSporeOptions = struct {
    backend: Backend = .auto,
    spore_dir: []const u8,
    /// Guest command and arguments. The first element is the executable.
    command: []const []const u8,
    guest_env: []const []const u8 = &.{},
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
    schema: []const u8 = "spore.fork.result.v1",
    schema_version: u32 = 1,
    resource_type: ResourceType = .checkpoint,
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

/// Options for packing a spore directory into a portable bundle.
pub const PackOptions = struct {
    spore_dir: []const u8,
    out_dir: []const u8,
    rootfs_cache: CacheRoot = .env,
    children_dir: ?[]const u8 = null,
    rootfs_policy: RootfsBundlePolicy = .exact_bytes,
};

/// Result returned by `pack`.
pub const PackResult = struct {
    schema: []const u8 = "spore.pack.result.v1",
    schema_version: u32 = 1,
    resource_type: ResourceType = .bundle,
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
pub const UnpackResult = struct {
    schema: []const u8 = "spore.unpack.result.v1",
    schema_version: u32 = 1,
    resource_type: ResourceType = .checkpoint,
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

/// Options for making an independently owned portable copy of one spore.
pub const CloneOptions = struct {
    spore_dir: []const u8,
    out_dir: []const u8,
    rootfs_cache: CacheRoot = .env,
};

pub const CloneResult = struct {
    schema: []const u8 = "spore.clone.result.v1",
    schema_version: u32 = 1,
    resource_type: ResourceType = .checkpoint,
    portability: Portability = .portable,
    source: []const u8,
    out_dir: []const u8,
    ownership: []const u8 = saved_spore_ownership.portable_self_contained,
};

/// Options for pushing a saved spore to an image store.
pub const PushOptions = spore_store.PushOptions;

/// Result returned by `push`.
pub const PushResult = spore_store.PushResult;

/// Options for pulling a saved spore from an image store.
pub const PullOptions = spore_store.PullOptions;

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
    schema: []const u8 = "spore.inspect.result.v1",
    schema_version: u32 = 1,
    resource_type: ResourceType = .checkpoint,
    portability: Portability,
    can_attach: bool,
    can_run_from: bool,
    version: u32,
    vm_state_present: bool,
    storage_mode: []const u8,
    ownership: []const u8,
    vcpu_count: u32,
    platform: SporePlatformSummary,
    device_count: usize,
    memory_chunk_count: usize,
    present_memory_chunk_count: usize,
    memory_backing_kind: ?[]const u8,
    memory_backing_size: ?u64,
    initial_memory_bytes: u64,
    max_memory_bytes: u64,
    requested_memory_bytes: u64,
    captured_memory_bytes: u64,
    plugged_memory_ranges: []const spore.MemoryPluggedRange = &.{},
    gic_kind: []const u8,
    sessions: []Session = &.{},
    network: ?SporeNetworkSummary = null,
    annotations: Annotations = .{},
    annotation_keys: []const []const u8 = &.{},
};

/// Return architecture-discriminated `spore.host-info.v3` facts on either
/// aarch64 or x86-64.
pub fn hostInfo(
    context: Context,
    allocator: std.mem.Allocator,
) !HostInfo {
    return platform.hostInfo(allocator, context.environ_map);
}

/// Build an ext4 rootfs from an OCI image reference.
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

/// Import an OCI layout into the local rootfs cache under a local ref.
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

/// Import an uncompressed rootfs tar into the local rootfs cache under a local ref.
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

/// Resolve an image tag or local ref to the digest-pinned ref used by SporeVM.
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

/// Write one complete local native image into a directory image store.
pub fn imagePush(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: ImagePushOptions,
) !ImagePushResult {
    return image_store.push(init, allocator, options);
}

/// Pack one complete local native image into an immutable transport archive.
pub fn imageArchivePack(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: ImageArchivePackOptions,
) !ImageArchivePackResult {
    return image_archive.pack(init, allocator, options);
}

/// Verify and install one immutable native image archive into the local cache.
pub fn imageArchiveUnpack(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: ImageArchiveUnpackOptions,
) !ImageArchiveUnpackResult {
    return image_archive.unpack(init, allocator, options);
}

/// Preload a cached rootfs into chunked CAS storage.
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

fn ownRootfsStorageDigestFields(allocator: std.mem.Allocator, storage: spore.RootfsStorage) !spore.RootfsStorage {
    return rootfs_mod.cloneRootfsStorageDigestFields(allocator, storage);
}

fn ownRootfsImportOciResult(allocator: std.mem.Allocator, result: RootfsImportOciResult) !RootfsImportOciResult {
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

    const manifest = try spore.loadManifest(arena, spore_dir);
    defer manifest.deinit();
    return summarizeSpore(allocator, spore_dir, manifest.value);
}

/// Release memory owned by a `SporeInspectResult`.
pub fn deinitSporeInspectResult(allocator: std.mem.Allocator, result: SporeInspectResult) void {
    allocator.free(result.platform.arch);
    allocator.free(result.platform.cpu_profile);
    if (result.memory_backing_kind) |kind| allocator.free(kind);
    allocator.free(result.plugged_memory_ranges);
    freeSessions(allocator, result.sessions);
    if (result.network) |network| freeNetworkSummary(allocator, network);
    allocator.free(result.annotation_keys);
    var annotations = result.annotations;
    deinitOwnedAnnotations(allocator, &annotations);
}

/// Map an internal Zig error to the stable failure classification used by
/// machine output and run/resume event consumers.
pub fn classifyFailure(err: anyerror) ClassifiedFailure {
    return events_mod.classifyFailure(err);
}

/// Resolve managed kernel/initrd/rootfs inputs, boot a VM, and execute a command.
///
/// This is the high-level `spore run` setup path.
pub fn runManaged(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: ManagedRunOptions,
) !RunResult {
    if (options.save_path != null and options.rootfs_path != null and options.image_ref == null) {
        return error.InvalidRootfsInput;
    }
    if (options.image_entrypoint != null and options.image_ref == null) {
        return error.InvalidImageEntrypointOverride;
    }
    if (options.commit_ref) |ref| {
        try rootfs_mod.validateLocalTagRef(ref);
        if (options.image_ref == null or options.rootfs_path != null or options.save_path != null or !options.save_trigger.isExit() or options.continue_after_save or options.interactive or options.tty) {
            return error.InvalidRunCommitOptions;
        }
    }
    if (options.disk_size) |disk_size| {
        if (options.commit_ref == null or disk_size == 0 or disk_size % rootfs_cas.default_chunk_size != 0) return error.InvalidRunDiskSize;
    }
    const selected_backend = try backend_mod.select(options.backend, .probe());
    try run_mod.validateFreshProductPolicy(selected_backend, .{
        .memory = options.memory,
        .vcpus = options.vcpus,
        .capture = options.save_path != null or !options.save_trigger.isExit() or options.continue_after_save,
        .rootfs = options.rootfs_path != null or options.image_ref != null or options.disk_size != null,
        .network = options.network != .disabled,
    });

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rootfs = try rootfs_input.resolveRootfsInputDetailed(init, arena, .{
        .rootfs_path = options.rootfs_path,
        .image_ref = options.image_ref,
        .pull_policy = options.image_pull_policy,
        .command_name = "run",
        .record_artifact = options.save_path != null or options.image_ref != null,
    });
    const command = if (options.image_ref != null)
        try rootfs_input.resolveImageRuntimeCommandWithEntrypoint(arena, rootfs.image_config, options.command, options.image_entrypoint)
    else blk: {
        if (options.command.len == 0) return error.RunArgCountUnsupported;
        break :blk options.command;
    };
    const default_kernel = options.kernel_path == null and init.environ_map.get("SPOREVM_KERNEL_IMAGE") == null;
    const default_initrd = options.initrd_path == null and init.environ_map.get("SPOREVM_RUN_INITRD") == null;
    const managed_boot_descriptor = if (default_kernel and default_initrd)
        try boot_assets.resolveManagedMonitorBootDescriptor(init, arena)
    else
        null;
    const boot_artifacts = if (managed_boot_descriptor) |descriptor|
        try boot_assets.materializeManagedMonitorBootArtifacts(init.io, arena, descriptor)
    else
        null;
    const kernel_path = if (managed_boot_descriptor) |descriptor|
        descriptor.kernel_path
    else
        options.kernel_path orelse try boot_assets.resolveDefaultKernelPath(init, arena);
    const initrd_path = if (managed_boot_descriptor != null) null else try boot_assets.resolveConfiguredInitrdPath(init, options.initrd_path);
    const guest_env = try guest_request.mergeGuestEnv(arena, rootfs.guest_env, options.guest_env);
    const rootfs_grow_target = if (options.disk_size) |target| blk: {
        const resolved_rootfs = rootfs.rootfs orelse return error.RunCommitRootfsNotSnapshotable;
        const storage = resolved_rootfs.storage orelse return error.RunCommitRootfsNotSnapshotable;
        break :blk try run_mod.rootfsGrowTarget(storage.logical_size, target);
    } else 0;

    return run_mod.execute(.{ .io = init.io, .environ_map = init.environ_map }, arena, .{
        .backend = options.backend,
        .kernel_path = kernel_path,
        .initrd_path = initrd_path,
        .boot_artifacts = boot_artifacts,
        .auto_memory_hotplug_capable = default_kernel and default_initrd,
        .rootfs_path = rootfs.path,
        .rootfs = rootfs.rootfs,
        .rootfs_grow_target = rootfs_grow_target,
        .command = command,
        .injected_files = options.injected_files,
        .interactive = options.interactive,
        .tty = options.tty,
        .guest_env = guest_env,
        .guest_working_dir = rootfs.guest_working_dir,
        .memory = options.memory,
        .vcpus = options.vcpus,
        .guest_port = options.guest_port,
        .timeout_ms = options.timeout_ms,
        .save_path = options.save_path,
        .save_trigger = options.save_trigger,
        .continue_after_save = options.continue_after_save,
        .commit = if (options.commit_ref) |ref| .{
            .ref = ref,
            .config = rootfs.image_config orelse return error.RunCommitImageConfigUnavailable,
        } else null,
        .annotations = options.annotations,
        .network = options.network,
        .spore_executable = options.spore_executable,
        .debug = options.debug,
        .events = options.events,
    });
}

/// Restore machine inputs from an existing checkpoint and execute a new guest
/// command. Attach is a separate `attachSpore` operation.
pub fn runFromSpore(
    context: Context,
    allocator: std.mem.Allocator,
    options: RunFromSporeOptions,
) !RunResult {
    if (options.command.len == 0) return error.InvalidGuestCommand;
    const selected_backend = try options.backend.resolveForHost();
    try run_mod.validateFreshProductPolicy(selected_backend, .{
        .memory = .{},
        .vcpus = options.vcpus,
        .resuming = true,
    });

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try spore.loadManifest(arena, options.spore_dir);
    defer parsed.deinit();
    const manifest = parsed.value;

    const rootfs = try rootfs_input.resumeRootfsForRun(arena, manifest);
    const disk = try rootfs_input.resumeDiskForRun(arena, manifest);
    const network = try spore_net_policy.networkFromManifestWithBindingDiagnostic(arena, manifest.network, options.bound_services, options.bound_service_diagnostic);
    if (options.vcpus != 1 and options.vcpus != manifest.platform.vcpu_count) return error.PlatformMismatch;
    const explicit_generation_params = if (options.generation_path) |path|
        attach_mod.loadGenerationParams(context.io, arena, path) catch |err| switch (err) {
            error.BadGenerationPayload, error.StreamTooLong => return err,
            else => return error.GenerationReadFailed,
        }
    else
        null;
    const run_generation = try prepareRunFromGenerationState(arena, manifest.generation, explicit_generation_params);

    return run_mod.execute(context, arena, .{
        .backend = options.backend,
        .kernel_path = "",
        .initrd_path = null,
        .rootfs_path = null,
        .rootfs = rootfs,
        .disk = disk,
        .resume_dir = options.spore_dir,
        .resume_generation = run_generation.resume_generation,
        .start_generation_params = run_generation.start_generation_params,
        .require_generation_ready = run_generation.start_generation_params != null,
        .command = options.command,
        .guest_env = options.guest_env,
        .interactive = options.interactive,
        .tty = options.tty,
        .memory = try spore.memoryConfig(manifest.platform.ram_size, manifest.memory_state),
        .vcpus = manifest.platform.vcpu_count,
        .guest_port = options.guest_port,
        .timeout_ms = options.timeout_ms,
        .save_path = options.save_path,
        .save_trigger = options.save_trigger,
        .continue_after_save = options.continue_after_save,
        .annotations = manifest.annotations,
        .network = network,
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
    try spore_fork.refreshResumeParams(allocator, &gen_dev);
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
    var bound_services = spore_net_policy.BoundServiceBindingList{};
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

/// Fork a parent spore into multiple child spores.
///
/// Owned strings in the result must be released with `deinitForkResult`.
fn rejectX86SavedStateFork() !void {
    if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
        return error.X86ForkUnsupported;
    }
}

pub fn fork(
    context: Context,
    allocator: std.mem.Allocator,
    options: ForkOptions,
) !ForkResult {
    if (options.count == 0) return error.BadForkCount;
    try rejectX86SavedStateFork();
    const result = try saved_spore_fork.execute(context, allocator, .{
        .parent_dir = options.parent_dir,
        .out_dir = options.out_dir,
        .count = options.count,
    });
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
        .pin_publish_ms = result.pin_publish_ms,
        .pin_lock_wait_ms = result.pin_lock_wait_ms,
    };
}

/// Release memory owned by a `ForkResult`.
pub fn deinitForkResult(allocator: std.mem.Allocator, result: ForkResult) void {
    allocator.free(result.first_child);
    allocator.free(result.last_child);
}

test "fork validates count and returns owned child paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const parent = try std.fs.path.join(arena, &.{ root, "parent.spore" });
    const children = try std.fs.path.join(arena, &.{ root, "children" });
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const context = Context{ .io = io, .environ_map = &env };

    try std.testing.expectError(error.BadForkCount, fork(context, allocator, .{
        .parent_dir = parent,
        .out_dir = children,
        .count = 0,
    }));

    if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
        try std.testing.expectError(error.X86ForkUnsupported, fork(context, allocator, .{
            .parent_dir = parent,
            .out_dir = children,
            .count = 2,
        }));
        return;
    }

    try std.Io.Dir.cwd().createDirPath(io, parent);
    try spore.saveManifest(arena, parent, manifest_test_support.manifest(.{}));
    const result = try fork(context, allocator, .{
        .parent_dir = parent,
        .out_dir = children,
        .count = 2,
    });
    defer deinitForkResult(allocator, result);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualStrings(try std.fs.path.join(arena, &.{ children, "000000" }), result.first_child);
    try std.testing.expectEqualStrings(try std.fs.path.join(arena, &.{ children, "000001" }), result.last_child);
}

/// Pack a spore directory into a portable bundle.
pub fn pack(
    context: Context,
    allocator: std.mem.Allocator,
    options: PackOptions,
) !PackResult {
    const rootfs_cache = resolveCacheRoot(options.rootfs_cache, allocator, context.environ_map);
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

/// Unpack a bundle into a spore directory.
pub fn unpack(
    context: Context,
    allocator: std.mem.Allocator,
    options: UnpackOptions,
) !UnpackResult {
    const rootfs_cache = resolveCacheRoot(options.rootfs_cache, allocator, context.environ_map);
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

/// Clone one spore through the existing pack/unpack transport encoding so the
/// output owns all RAM and disk content it needs.
pub fn cloneSpore(context: Context, allocator: std.mem.Allocator, options: CloneOptions) !CloneResult {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stage_root: ?[]const u8 = null;
    if (std.Io.Dir.cwd().statFile(context.io, options.out_dir, .{ .follow_symlinks = false })) |_| {
        return error.AlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }
    for (0..16) |_| {
        var nonce: [8]u8 = undefined;
        context.io.random(&nonce);
        const candidate = try std.fmt.allocPrint(arena, "{s}.clone-stage-{x}", .{ options.out_dir, std.mem.readInt(u64, &nonce, .little) });
        std.Io.Dir.cwd().createDir(context.io, candidate, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |e| return e,
        };
        stage_root = candidate;
        break;
    }
    const owned_stage_root = stage_root orelse return error.PathAlreadyExists;
    defer std.Io.Dir.cwd().deleteTree(context.io, owned_stage_root) catch {};
    const bundle_dir = try std.fs.path.join(arena, &.{ owned_stage_root, "bundle" });
    const staged_output = try std.fs.path.join(arena, &.{ owned_stage_root, "output" });

    _ = try pack(context, arena, .{
        .spore_dir = options.spore_dir,
        .out_dir = bundle_dir,
        .rootfs_cache = options.rootfs_cache,
    });
    _ = try unpack(context, arena, .{
        .bundle_dir = bundle_dir,
        .out_dir = staged_output,
        .rootfs_cache = options.rootfs_cache,
    });
    try chunk_sealer.fsyncDirPath(arena, staged_output);
    try renameDirectoryNoReplace(arena, staged_output, options.out_dir);
    try chunk_sealer.fsyncDirPath(arena, std.fs.path.dirname(options.out_dir) orelse ".");
    return .{ .source = options.spore_dir, .out_dir = options.out_dir };
}

fn renameDirectoryNoReplace(allocator: std.mem.Allocator, source: []const u8, destination: []const u8) !void {
    const source_z = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(source_z);
    const destination_z = try allocator.dupeSentinel(u8, destination, 0);
    defer allocator.free(destination_z);
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const rc = linux.renameat2(std.c.AT.FDCWD, source_z.ptr, std.c.AT.FDCWD, destination_z.ptr, .{ .NOREPLACE = true });
        return switch (linux.errno(rc)) {
            .SUCCESS => {},
            .EXIST => error.AlreadyExists,
            .NOENT => error.FileNotFound,
            .XDEV => error.CrossDevice,
            else => error.IoFailed,
        };
    } else {
        const Darwin = struct {
            extern "c" fn renamex_np(old: [*:0]const u8, new: [*:0]const u8, flags: c_uint) c_int;
        };
        if (Darwin.renamex_np(source_z.ptr, destination_z.ptr, 0x00000004) == 0) return;
        return switch (std.c.errno(-1)) {
            .EXIST => error.AlreadyExists,
            .NOENT => error.FileNotFound,
            .XDEV => error.CrossDevice,
            else => error.IoFailed,
        };
    }
}

test "clone spore makes a pinned save independently portable" {
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
    const source = try std.fs.path.join(arena, &.{ root, "source.spore" });
    const output = try std.fs.path.join(arena, &.{ root, "portable.spore" });
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_root);
    try env.put(local_paths.runtime_dir_env, runtime_root);
    const fixture = try manifest_test_support.diskFixture(arena, io, cache_root, source, 0x71, false);
    {
        var lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, cache_root);
        defer lock.deinit();
        const registry = try saved_spore_pin.LockedRegistry.init(arena, cache_root, &lock);
        try saved_spore_pin.publishManifest(io, arena, registry, source, fixture.disk, fixture.manifest);
    }
    const source_inspected = try inspectSpore(allocator, source);
    defer deinitSporeInspectResult(allocator, source_inspected);
    try std.testing.expectEqualStrings(saved_spore_ownership.machine_local_pinned, source_inspected.ownership);
    const result = try cloneSpore(.{ .io = io, .environ_map = &env }, allocator, .{ .spore_dir = source, .out_dir = output });
    try std.testing.expectEqualStrings(saved_spore_ownership.portable_self_contained, result.ownership);
    const inspected = try inspectSpore(allocator, output);
    defer deinitSporeInspectResult(allocator, inspected);
    try std.testing.expectEqualStrings(saved_spore_ownership.portable_self_contained, inspected.ownership);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, try std.fs.path.join(arena, &.{ output, saved_spore_pin.reference_file }), .{ .follow_symlinks = false }));

    const occupied = try std.fs.path.join(arena, &.{ root, "occupied.spore" });
    try std.Io.Dir.cwd().createDirPath(io, occupied);
    const sentinel = try std.fs.path.join(arena, &.{ occupied, "keep" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sentinel, .data = "owned elsewhere" });
    try std.testing.expectError(error.AlreadyExists, cloneSpore(.{ .io = io, .environ_map = &env }, allocator, .{ .spore_dir = source, .out_dir = occupied }));
    try std.testing.expectEqualStrings("owned elsewhere", try std.Io.Dir.cwd().readFileAlloc(io, sentinel, arena, .limited(64)));
}

/// Push a saved spore to a directory or S3 image store.
pub fn push(
    context: Context,
    allocator: std.mem.Allocator,
    options: PushOptions,
) !PushResult {
    return spore_store.push(context, allocator, options);
}

/// Inspect bundle metadata without materializing a child spore.
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

/// Pull a saved spore from a directory, HTTP(S) or S3 image store.
pub fn pull(
    context: Context,
    allocator: std.mem.Allocator,
    options: PullOptions,
) !PullResult {
    return spore_store.pull(context, allocator, options);
}

fn summarizeSpore(allocator: std.mem.Allocator, spore_dir: []const u8, manifest: spore.Manifest) !SporeInspectResult {
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
    const ownership = try saved_spore_ownership.classify(allocator, spore_dir, manifest.disk);
    const memory_state = manifest.memory_state;
    const plugged_ranges = if (memory_state) |state|
        try allocator.dupe(spore.MemoryPluggedRange, state.plugged_ranges)
    else
        try allocator.alloc(spore.MemoryPluggedRange, 0);
    errdefer allocator.free(plugged_ranges);

    return .{
        .portability = resource.portabilityForOwnership(ownership),
        .can_attach = manifest.sessions.len != 0,
        .can_run_from = true,
        .version = manifest.version,
        .vm_state_present = true,
        .storage_mode = inspectStorageMode(manifest),
        .ownership = ownership,
        .vcpu_count = manifest.platform.vcpu_count,
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
        .initial_memory_bytes = if (memory_state) |state| state.initial_size else manifest.platform.ram_size,
        .max_memory_bytes = if (memory_state) |state| state.maximum_size else manifest.platform.ram_size,
        .requested_memory_bytes = if (memory_state) |state| state.requested_size else manifest.platform.ram_size,
        .captured_memory_bytes = if (memory_state) |state| state.captured_size else manifest.platform.ram_size,
        .plugged_memory_ranges = plugged_ranges,
        .gic_kind = switch (manifest.machine) {
            inline else => |machine| @tagName(machine.gic.kind),
        },
        .sessions = sessions,
        .network = network,
        .annotations = annotations,
        .annotation_keys = annotation_keys,
    };
}

fn inspectStorageMode(manifest: spore.Manifest) []const u8 {
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
    var tmp = try TestDir.init();
    defer tmp.deinit();
    const dir = tmp.root;

    var annotations = spore.Annotations{};
    try annotations.map.put(arena, "cleanroom.create", "created");
    try annotations.map.put(arena, "cleanroom.snapshot", "warm");
    var manifest = manifest_test_support.manifest(annotations);
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
    try std.testing.expectEqual(ResourceType.checkpoint, inspected.resource_type);
    try std.testing.expectEqual(Portability.portable, inspected.portability);
    try std.testing.expect(inspected.can_attach);
    try std.testing.expect(inspected.can_run_from);
    try std.testing.expect(inspected.vm_state_present);
    try std.testing.expectEqualStrings("exact-rootfs", inspected.storage_mode);
    try std.testing.expectEqualStrings(saved_spore_ownership.portable_self_contained, inspected.ownership);
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

test "inspect spore reports batch-relative offline fork children" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const batch = try std.fs.path.join(arena, &.{ root, "batch" });
    const child = try std.fs.path.join(arena, &.{ batch, "000000" });
    const shared = try std.fs.path.join(arena, &.{ batch, "shared-chunks" });
    try std.Io.Dir.cwd().createDirPath(io, child);
    try std.Io.Dir.cwd().createDirPath(io, shared);
    try std.Io.Dir.cwd().symLink(io, "../shared-chunks", try std.fs.path.join(arena, &.{ child, "chunks" }), .{});
    try spore.saveManifest(arena, child, manifest_test_support.manifest(.{}));

    const inspected = try inspectSpore(allocator, child);
    defer deinitSporeInspectResult(allocator, inspected);
    try std.testing.expectEqual(Portability.batch_relative, inspected.portability);
    try std.testing.expectEqualStrings(saved_spore_ownership.batch_relative, inspected.ownership);
}

test "run from checkpoint does not represent attach with an empty command" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectError(error.InvalidGuestCommand, runFromSpore(.{
        .io = std.testing.io,
        .environ_map = &env,
    }, std.testing.allocator, .{
        .spore_dir = "base.spore",
        .command = &.{},
    }));
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

test "inspect spore summarizes multi-vcpu manifests" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = try TestDir.init();
    defer tmp.deinit();
    const dir = tmp.root;

    var annotations = spore.Annotations{};
    try annotations.map.put(arena, "cleanroom.bake", "warm");
    var vcpus = [_]spore.VcpuState{ testVcpuState(0), testVcpuState(1) };
    const redists = [_]gicv3.RedistributorState{
        .{ .mpidr = vcpus[0].mpidr, .regs = &.{} },
        .{ .mpidr = vcpus[1].mpidr, .regs = &.{} },
    };
    const manifest = spore.Manifest{
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
        .machine = .{ .multi = .{
            .vcpus = &vcpus,
            .gic = .{
                .kind = .gicv3_multi,
                .gicv3_multi = .{
                    .dist_regs = &.{},
                    .redistributors = &redists,
                    .line_levels = &.{},
                },
            },
        } },
        .devices = &.{},
        .generation = .{ .generation = 1, .interrupt_status = 0, .params_b64 = "" },
        .memory = .{ .logical_size = 1, .chunk_size = spore.chunk_size, .zero_ranges = &.{.{ .start = 0, .count = 1 }} },
    };
    try spore.saveManifest(arena, dir, manifest);

    const inspected = try inspectSpore(allocator, dir);
    defer deinitSporeInspectResult(allocator, inspected);
    try std.testing.expectEqual(spore.format_version, inspected.version);
    try std.testing.expect(inspected.vm_state_present);
    try std.testing.expectEqualStrings("memory-only", inspected.storage_mode);
    try std.testing.expectEqual(@as(u32, 2), inspected.vcpu_count);
    try std.testing.expectEqualStrings("gicv3_multi", inspected.gic_kind);
    try std.testing.expectEqualStrings("warm", inspected.annotations.map.get("cleanroom.bake").?);
}

fn testVcpuState(index: u32) spore.VcpuState {
    return .{
        .index = index,
        .mpidr = aarch64_topology.mpidrForIndex(index),
        .gprs = @splat(0),
        .pc = 0,
        .cpsr = 0,
        .fpcr = 0,
        .fpsr = 0,
        .simd = @splat(.{ 0, 0 }),
        .sys_regs = &.{},
        .icc_regs = &.{},
        .vtimer = .{ .cntvct = 0, .cntv_ctl = 0, .cntv_cval = 0 },
    };
}

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
) ResolvedCacheRoot {
    return switch (requested) {
        .none => .{},
        .path => |path| .{ .path = path },
        .env => if (local_paths.rootfsCacheRootPath(allocator, environ_map) catch null) |path| .{ .path = path, .owned = true } else .{},
    };
}

fn rootfsBundlePolicy(policy: RootfsBundlePolicy) bundle.RootfsBundlePolicy {
    return switch (policy) {
        .exact_bytes => .exact_bytes,
        .metadata_only => .metadata_only,
    };
}
