//! Resolves a run's rootfs input (a local path, a pulled image or a saved
//! spore's disk) and an image's runtime command.

const std = @import("std");
const TestDir = @import("test_dir.zig").TestDir;
const builtin = @import("builtin");
const Io = std.Io;

const architecture = @import("architecture.zig");
const disk_layer = @import("disk_layer.zig");
const guest_request = @import("guest_request.zig");
const image = @import("image.zig");
const image_store = @import("image_store.zig");
const local_image = @import("local_image.zig");
const local_paths = @import("local_paths.zig");
const machine_output = @import("machine_output.zig");
const rootfs_cache = @import("rootfs_cache.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const rootfs_mod = @import("rootfs.zig");
const spore = @import("spore.zig");
const test_support = @import("test_support.zig");

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

pub const direct_image_platform = directImagePlatformFor(builtin.cpu.arch) catch
    @compileError("SporeVM product execution requires an arm64 or amd64 host architecture");

fn directImagePlatformFor(zig_arch: std.Target.Cpu.Arch) !rootfs_mod.Platform {
    return .{
        .arch = architecture.fromTarget(zig_arch) orelse return error.UnsupportedArchitecture,
    };
}

pub fn resumeRootfsForRun(allocator: std.mem.Allocator, manifest: spore.Manifest) !?spore.Rootfs {
    const disk_count = spore.countBlockDevices(manifest.devices);
    if (disk_count == 0) return null;
    if (disk_count != 1) return error.UnsupportedRootfsDeviceCount;
    const rootfs = manifest.rootfs orelse return error.MissingRootfsArtifact;
    try spore.validateRootfs(rootfs, manifest.devices);
    return try cloneRootfs(allocator, rootfs);
}

pub fn resumeDiskForRun(allocator: std.mem.Allocator, manifest: spore.Manifest) !?spore.Disk {
    const disk = manifest.disk orelse return null;
    return try disk_layer.cloneDisk(allocator, disk);
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
    return resolveImageRuntimeCommandWithEntrypoint(allocator, image_config, caller_command, null);
}

/// Resolve OCI process metadata while replacing the image Entrypoint when an
/// override is provided. An empty override explicitly clears the Entrypoint.
pub fn resolveImageRuntimeCommandWithEntrypoint(
    allocator: std.mem.Allocator,
    image_config: ?rootfs_mod.ImageConfig,
    caller_command: []const []const u8,
    entrypoint_override: ?[]const []const u8,
) ![]const []const u8 {
    const runtime = if (image_config) |config| config.config else null;
    const entrypoint = entrypoint_override orelse if (runtime) |config| config.Entrypoint orelse &.{} else &.{};
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
    if (entrypoint.len > guest_request.max_guest_argc or command.len > guest_request.max_guest_argc - entrypoint.len) return error.RunArgCountUnsupported;
    const len = entrypoint.len + command.len;
    const argv = try allocator.alloc([]const u8, len);
    errdefer allocator.free(argv);
    @memcpy(argv[0..entrypoint.len], entrypoint);
    @memcpy(argv[entrypoint.len..], command);
    try guest_request.validateGuestArgv(argv);
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
        try resolveImageRootfs(init, allocator, ref, options.command_name, options.pull_policy)
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
    if (!try local_paths.readablePath(init.io, rootfs_path)) {
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
    try local_paths.ensureDirPath(init.io, cache_root);
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
    return rootfs_cache.cacheByDigestPathCopy(io, allocator, cache_root, rootfs_path);
}

fn resolveImageRootfs(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    image_ref: []const u8,
    command_name: []const u8,
    pull_policy: PullPolicy,
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
    try local_paths.ensureDirPath(init.io, cache_root);

    if (image_store.isStoreRef(image_ref)) {
        const local = image_store.resolve(init.io, allocator, cache_root, image_ref, direct_image_platform, init.environ_map) catch |err| {
            return .{ .failure = rootfsInputFailure(
                allocator,
                machine_output.fromZigError(err).code,
                command_name,
                "spore {s}: image store fetch failed for {s}: {s}",
                .{ command_name, image_ref, @errorName(err) },
            ) };
        };
        return .{ .resolved = try imageRootfsInput(allocator, image_ref, local) };
    }

    const local_ref = rootfs_mod.isLocalImageRef(image_ref);
    const digest_pinned = if (local_ref) null else try rootfs_mod.digestPinnedImageIdentity(allocator, image_ref, direct_image_platform);
    if (!local_ref and digest_pinned == null) rootfs_mod.validateTaggedImageRef(image_ref) catch |err| {
        return .{ .failure = rootfsInputFailure(
            allocator,
            .usage_invalid_argument,
            command_name,
            "spore {s}: image resolve failed for {s}: {s}",
            .{ command_name, image_ref, @errorName(err) },
        ) };
    };
    // Local names and digests are immutable or never pulled; a registry tag
    // follows its ref record unless --pull=always asks the registry again,
    // or --pull=missing finds a conversion by an older rootfs builder.
    if (local_ref or digest_pinned != null or pull_policy != .always) {
        const found = local_image.find(init.io, allocator, cache_root, image_ref, direct_image_platform) catch |err| {
            return .{ .failure = rootfsInputFailure(
                allocator,
                .cache_integrity_failed,
                command_name,
                "spore {s}: local image check failed for {s}: {s}",
                .{ command_name, image_ref, @errorName(err) },
            ) };
        };
        if (found) |local| {
            const stale = !local_ref and digest_pinned == null and pull_policy == .missing and
                if (local.oci) |source| !std.mem.eql(u8, source.builder_version, rootfs_mod.builder_version) else false;
            if (!stale) return .{ .resolved = try imageRootfsInput(allocator, image_ref, local) };
        }
    }
    if (local_ref) return .{ .failure = rootfsInputFailure(
        allocator,
        .object_not_found,
        command_name,
        "spore {s}: local image not found: {s}; build, import or unpack it first",
        .{ command_name, image_ref },
    ) };
    if (digest_pinned == null and pull_policy == .never) return .{ .failure = rootfsInputFailure(
        allocator,
        .object_not_found,
        command_name,
        "spore {s}: image ref cache miss for {s} with --pull=never",
        .{ command_name, image_ref },
    ) };

    const resolved = digest_pinned orelse rootfs_mod.resolveImageRef(init, allocator, image_ref, direct_image_platform) catch |err| {
        return .{ .failure = rootfsInputFailure(
            allocator,
            machine_output.fromZigError(err).code,
            command_name,
            "spore {s}: image resolve failed for {s}: {s}",
            .{ command_name, image_ref, @errorName(err) },
        ) };
    };
    const name = if (digest_pinned == null) image_ref else null;
    const local = pulledImage(init, allocator, cache_root, resolved, name) catch |err| {
        return .{ .failure = rootfsInputFailure(
            allocator,
            machine_output.fromZigError(err).code,
            command_name,
            "spore {s}: image rootfs build failed for {s}: {s}",
            .{ command_name, resolved.ref, @errorName(err) },
        ) };
    };
    return .{ .resolved = try imageRootfsInput(allocator, image_ref, local) };
}

/// The image the current builder converted from `resolved`, pulling it if
/// this host has none. Points `name` at it.
fn pulledImage(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    resolved: rootfs_mod.ResolvedImage,
    name: ?[]const u8,
) !local_image.LocalImage {
    if (try local_image.find(init.io, allocator, cache_root, resolved.ref, resolved.platform)) |local| {
        if (name) |tag| {
            var cache_lock = try rootfs_mod.lockRootfsCacheExclusive(init.io, allocator, cache_root);
            defer cache_lock.deinit();
            _ = try local_image.tag(allocator, cache_root, &cache_lock, tag, local);
        }
        return local;
    }
    const published = try rootfs_mod.pullImage(init, allocator, cache_root, resolved, name);
    return (try local_image.load(init.io, allocator, cache_root, published.identity)) orelse error.RootFSDigestCacheMiss;
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
        .operation_canceled => error.OperationCanceled,
        .stream_interrupted => error.EventSinkFailed,
    };
}

fn imageRootfsInput(allocator: std.mem.Allocator, requested_ref: []const u8, local: local_image.LocalImage) !ResolvedRootfsInput {
    const rootfs_device = spore.RootfsDevice{ .mmio_slot = 1 };
    var storage = local.storage;
    storage.device = rootfs_device;
    const resolved_ref = if (image_store.isStoreRef(requested_ref))
        try image_store.resolvedRefAlloc(allocator, requested_ref, local.identity)
    else
        try local_image.resolvedRefAlloc(allocator, requested_ref, local.identity, local.oci);
    // `repo@digest`, or `<store>/blake3:<hex>` for a store image.
    const digest_start = std.mem.lastIndexOfAny(u8, resolved_ref, "@/").? + 1;
    const runtime = local.config.config;
    const working_dir = if (runtime) |config| config.WorkingDir else null;
    return .{
        .path = null,
        .rootfs = .{
            .device = rootfs_device,
            .artifact = .{
                .digest = storage.index_digest,
                .size = storage.logical_size,
                .format = spore.rootfs_artifact_format_ext4,
            },
            .storage = storage,
            .source = .{
                // A local tag is mutable, so saves record what it resolved to.
                .requested_ref = if (rootfs_mod.isLocalImageRef(requested_ref)) resolved_ref else requested_ref,
                .resolved_image_ref = resolved_ref,
                .image_manifest_digest = resolved_ref[digest_start..],
                .platform = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ local.platform.os, local.platform.arch.name() }),
                .builder_version = if (local.oci) |source| source.builder_version else rootfs_mod.builder_version,
            },
        },
        .guest_env = if (runtime) |config| config.Env orelse &.{} else &.{},
        .guest_working_dir = if (working_dir) |dir| if (dir.len == 0) null else dir else null,
        .image_config = local.config,
    };
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

test "image runtime command permits an explicit entrypoint override" {
    const allocator = std.testing.allocator;
    var entrypoint = [_][]const u8{"/image-entry"};
    var cmd = [_][]const u8{"default"};
    var entrypoint_override = [_][]const u8{"/scanner"};
    const config = rootfs_mod.ImageConfig{ .config = .{ .Entrypoint = &entrypoint, .Cmd = &cmd } };

    const default_command = try resolveImageRuntimeCommandWithEntrypoint(allocator, config, &.{}, &entrypoint_override);
    defer allocator.free(default_command);
    try std.testing.expectEqualSlices([]const u8, &.{ "/scanner", "default" }, default_command);

    const resolved = try resolveImageRuntimeCommandWithEntrypoint(allocator, config, &.{"/runtime"}, &entrypoint_override);
    defer allocator.free(resolved);
    try std.testing.expectEqualSlices([]const u8, &.{ "/scanner", "/runtime" }, resolved);
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
    var too_many: [guest_request.max_guest_argc + 1][]const u8 = @splat("x");
    try std.testing.expectError(error.RunArgCountUnsupported, resolveImageRuntimeCommand(allocator, null, &too_many));
    var too_long: [guest_request.max_guest_arg_len + 1]u8 = @splat('x');
    try std.testing.expectError(error.RunArgTooLong, resolveImageRuntimeCommand(allocator, null, &.{&too_long}));
}

test "direct image product platform follows the native architecture" {
    try std.testing.expectEqual(architecture.Architecture.arm64, (try directImagePlatformFor(.aarch64)).arch);
    try std.testing.expectEqual(architecture.Architecture.amd64, (try directImagePlatformFor(.x86_64)).arch);
    try std.testing.expectError(error.UnsupportedArchitecture, directImagePlatformFor(.wasm32));
}

test "run pull never fails closed on mutable image ref cache miss" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, try tmp_dir.path("cache"));
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

test "run points a registry tag at the image imported from the same OCI manifest" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const cache_root = try std.fs.path.join(arena, &.{ root, "cache" });
    const layout = try std.fs.path.join(arena, &.{ root, "layout" });
    const blobs = try std.fs.path.join(arena, &.{ layout, "blobs", "sha256" });
    try Io.Dir.cwd().createDirPath(io, blobs);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ layout, "oci-layout" }), .data = "{\"imageLayoutVersion\":\"1.0.0\"}" });
    const Blob = struct {
        fn write(a: std.mem.Allocator, dir: []const u8, bytes: []const u8) ![]const u8 {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            const hex = std.fmt.bytesToHex(digest, .lower);
            try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fs.path.join(a, &.{ dir, &hex }), .data = bytes });
            return std.fmt.allocPrint(a, "sha256:{s}", .{&hex});
        }
    };
    var layer: Io.Writer.Allocating = .init(arena);
    var layer_writer = std.tar.Writer{ .underlying_writer = &layer.writer };
    try layer_writer.writeFileBytes("etc/hello", "hello\n", .{ .mode = 0o644 });
    try layer_writer.finishPedantically();
    const arch = direct_image_platform.arch.name();
    const config = try std.fmt.allocPrint(arena, "{{\"architecture\":\"{s}\",\"os\":\"linux\"}}", .{arch});
    const manifest = try std.fmt.allocPrint(
        arena,
        "{{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"config\":{{\"mediaType\":\"application/vnd.oci.image.config.v1+json\",\"digest\":\"{s}\",\"size\":{d}}},\"layers\":[{{\"mediaType\":\"application/vnd.oci.image.layer.v1.tar\",\"digest\":\"{s}\",\"size\":{d}}}]}}",
        .{ try Blob.write(arena, blobs, config), config.len, try Blob.write(arena, blobs, layer.written()), layer.written().len },
    );
    const manifest_digest = try Blob.write(arena, blobs, manifest);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ layout, "index.json" }),
        .data = try std.fmt.allocPrint(
            arena,
            "{{\"schemaVersion\":2,\"manifests\":[{{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"{s}\",\"size\":{d},\"platform\":{{\"os\":\"linux\",\"architecture\":\"{s}\"}}}}]}}",
            .{ manifest_digest, manifest.len, arch },
        ),
    });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_root);
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

    // `spore build --build-context` imports its base like this.
    const imported = try rootfs_mod.importOciLayout(init, arena, .{ .input = layout, .ref = "local/app:dev", .platform = direct_image_platform });
    // `spore run registry.example.test/app:1` after the registry resolved the
    // tag to the same manifest.
    const resolved_ref = try std.fmt.allocPrint(arena, "registry.example.test/app@{s}", .{manifest_digest});
    const pulled = try pulledImage(init, arena, cache_root, .{ .ref = resolved_ref, .manifest_digest = manifest_digest, .platform = direct_image_platform }, "registry.example.test/app:1");
    try std.testing.expectEqualStrings(imported.image_manifest_digest, pulled.identity);

    const result = try resolveRootfsInputDetailedResult(init, arena, .{
        .rootfs_path = null,
        .image_ref = "registry.example.test/app:1",
        .pull_policy = .never,
        .command_name = "run",
    });
    const input = switch (result) {
        .resolved => |input| input,
        .failure => return error.ExpectedLocalImage,
    };
    try std.testing.expectEqualStrings(resolved_ref, input.rootfs.?.source.?.resolved_image_ref);
}

test "run --pull=missing converts a registry tag again after a rootfs builder change, but keeps a local name" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const cache_root = try tmp_dir.path("cache");
    try Io.Dir.cwd().createDirPath(io, cache_root);
    const rootfs_path = try tmp_dir.path("rootfs.ext4");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = (test_support.repeat("abcd", 1024)) ++ (test_support.repeat("efgh", 1024)) });
    const preload = try rootfs_cas.preloadPath(io, arena, cache_root, rootfs_path, rootfs_cas.default_chunk_size);
    const storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload);

    // The loopback registry fails every registry request before connecting.
    const manifest = "sha256:" ++ test_support.repeat("a", 64);
    for ([_]struct { name: []const u8, source: []const u8, builder: []const u8, workdir: []const u8 }{
        .{ .name = "127.0.0.1:1/app:old", .source = "127.0.0.1:1/app@" ++ manifest, .builder = "sporevm-rootfs-previous", .workdir = "/old" },
        .{ .name = "127.0.0.1:1/app:current", .source = "127.0.0.1:1/app@" ++ manifest, .builder = rootfs_mod.builder_version, .workdir = "/current" },
        .{ .name = "local/app:old", .source = "local/app@" ++ manifest, .builder = "sporevm-rootfs-previous", .workdir = "/local-old" },
    }) |published| {
        _ = try local_image.lockAndPublish(io, arena, cache_root, .{
            .platform = direct_image_platform,
            .config = .{ .config = .{ .WorkingDir = published.workdir } },
            .storage = storage,
            .oci = .{ .ref = published.source, .manifest_digest = manifest, .builder_version = published.builder },
            .name = published.name,
        });
    }

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_root);
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
    const Case = struct { ref: []const u8, pull: PullPolicy, workdir: ?[]const u8 };
    for ([_]Case{
        .{ .ref = "127.0.0.1:1/app:current", .pull = .missing, .workdir = "/current" },
        .{ .ref = "127.0.0.1:1/app:old", .pull = .never, .workdir = "/old" },
        .{ .ref = "127.0.0.1:1/app:old", .pull = .missing, .workdir = null },
        // A local name has no registry to convert from again.
        .{ .ref = "local/app:old", .pull = .missing, .workdir = "/local-old" },
    }) |case| {
        const result = try resolveRootfsInputDetailedResult(init, arena, .{
            .rootfs_path = null,
            .image_ref = case.ref,
            .pull_policy = case.pull,
            .command_name = "run",
        });
        switch (result) {
            .resolved => |input| try std.testing.expectEqualStrings(case.workdir orelse return error.ExpectedRegistryResolve, input.guest_working_dir.?),
            .failure => |failure| {
                if (case.workdir != null) return error.ExpectedLocalImage;
                try std.testing.expect(std.mem.indexOf(u8, failure.message, "image resolve failed") != null);
            },
        }
    }
}

test "explicit rootfs input can record exact immutable identity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const rootfs_path = try tmp_dir.path("source.ext4");
    const cache_root = try tmp_dir.path("cache");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });
    try Io.Dir.cwd().setFilePermissions(io, rootfs_path, @fromBackingInt(@intCast(0o644)), .{});

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
    try std.testing.expectEqual(@as(u32, 0o644), @as(u32, @intCast(@backingInt(source_stat.permissions) & 0o777)));
}
