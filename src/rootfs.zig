//! OCI image to ext4 rootfs builder.
//!
//! This is intentionally a builder utility, not part of the VMM monitor
//! process. OCI manifests and layer tar streams are attacker-influenced input,
//! so layer application is strict and fail-closed.

const std = @import("std");
const TestDir = @import("test_dir.zig").TestDir;
const builtin = @import("builtin");
const Sha256 = std.crypto.hash.sha2.Sha256;
const ext4 = @import("rootfs/ext4.zig");
pub const ext4_writer = @import("rootfs/ext4_writer.zig");
const image_mod = @import("image.zig");
const local_image = @import("local_image.zig");
const local_paths = @import("local_paths.zig");
const oci = @import("rootfs/oci.zig");
const oci_layout = @import("rootfs/oci_layout.zig");
const registry = @import("rootfs/registry.zig");
const rootfs_cache = @import("rootfs_cache.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const spore = @import("spore.zig");
const tar = @import("rootfs/tar.zig");
const test_barrier = @import("test_barrier.zig");
const test_support = @import("test_support.zig");

const Io = std.Io;

const max_rootfs_layers: usize = 512;
pub const builder_version = "sporevm-rootfs-v6";
const rootfs_build_profile_env = "SPOREVM_ROOTFS_BUILD_PROFILE";
/// Recorded in rootfs metadata. Cache lookups reject artifacts from any other
/// producer, such as the removed e2fsprogs writer.
const ext4_writer_name = "native";
const resolver_placeholder_path = "etc/resolv.conf";
const resolver_placeholder_bytes =
    "# SporeVM generated placeholder; --net bind-mounts the guest resolver here.\n";

pub const testing = if (builtin.is_test) struct {
    /// Pauses an image materialization after fetch and merge, before it takes
    /// the cache lock to emit and publish.
    pub var publish_lock_barrier: ?*test_barrier.Barrier = null;
} else struct {};

pub const ParsedBuildOptions = struct {
    ref: []const u8,
    output: []const u8,
    metadata: []const u8,
    platform: ?Platform = null,
};

pub const ParsedResolveOptions = struct {
    ref: []const u8,
    platform: Platform = .{},
};

pub const ParsedImportOciOptions = struct {
    input: []const u8,
    ref: []const u8,
    platform: Platform = .{},
    rootfs_storage: RootfsStoragePolicy = .chunked,
};

pub const ParsedImportTarOptions = ParsedImportOciOptions;

pub const BuildRequest = struct {
    ref: []const u8,
    output: []const u8,
    metadata: []const u8,
    platform: ?Platform = null,
};

pub const ImportOciRequest = struct {
    input: []const u8,
    ref: []const u8,
    platform: Platform = .{},
    rootfs_storage: RootfsStoragePolicy = .chunked,
};

pub const ImportTarRequest = ImportOciRequest;

pub const ResolveRequest = struct {
    ref: []const u8,
    platform: Platform = .{},
};

pub const ImportOciResult = struct {
    schema: []const u8 = "spore.rootfs.import.result.v2",
    schema_version: u32 = 2,
    metadata_path: []const u8,
    local_ref_path: []const u8,
    resolved_image_ref: []const u8,
    image_manifest_digest: []const u8,
    rootfs_storage: spore.RootfsStorage,
};

pub const ImportTarResult = ImportOciResult;

pub const RootfsStoragePolicy = enum {
    chunked,
    flat,
};

const BuildOptions = struct {
    ref: []const u8,
    platform: Platform = .{},
    temp_dir_root: []const u8,
    target: Target,
};

/// Where a materialized rootfs goes.
const Target = union(enum) {
    /// `spore image export-rootfs`: an ext4 file and its metadata sidecar.
    file: struct { output: []const u8, metadata: []const u8 },
    /// The local image catalog, under an optional name.
    catalog: struct { name: ?[]const u8 = null },
};

pub const ResolvedImage = struct {
    ref: []const u8,
    manifest_digest: []const u8,
    platform: Platform,
};

const rootfs_cache_lock_name = ".sporevm-rootfs-cache.lock";
const flock_exclusive: c_int = 2;
const flock_nonblocking: c_int = 4;
const flock_unlock: c_int = 8;

const RootfsCacheLockState = struct {
    fd: std.c.fd_t,
    file_identity: RootfsCacheLockFileIdentity,
};

const RootfsCacheLockFileIdentity = struct {
    device: u64,
    inode: u64,
};

pub const RootfsCacheLock = struct {
    state: RootfsCacheLockState,

    /// Ensures this borrowed guard's fd owns the lockfile selected by
    /// `cache_root`. Reasserting nonblocking flock also safely reacquires an
    /// unlocked but otherwise valid fd instead of trusting caller state.
    pub fn ensureHeldFor(self: *const RootfsCacheLock, allocator: std.mem.Allocator, cache_root: []const u8) !bool {
        if (self.state.fd < 0) return false;
        const held_identity = rootfsCacheLockFileIdentity(self.state.fd) orelse return false;
        if (!std.meta.eql(self.state.file_identity, held_identity)) return false;

        const path = try std.fs.path.join(allocator, &.{ cache_root, rootfs_cache_lock_name });
        defer allocator.free(path);
        const path_z = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(path_z);
        const expected_fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
        if (expected_fd < 0) return false;
        defer _ = std.c.close(expected_fd);
        const expected_identity = rootfsCacheLockFileIdentity(expected_fd) orelse return false;
        if (!std.meta.eql(self.state.file_identity, expected_identity)) return false;
        return std.c.flock(self.state.fd, flock_exclusive | flock_nonblocking) == 0;
    }

    pub fn deinit(self: *RootfsCacheLock) void {
        if (self.state.fd >= 0) {
            _ = std.c.flock(self.state.fd, flock_unlock);
            _ = std.c.close(self.state.fd);
            self.state.fd = -1;
            self.state.file_identity = .{ .device = 0, .inode = 0 };
        }
    }
};

pub fn lockRootfsCacheExclusive(io: Io, allocator: std.mem.Allocator, cache_root: []const u8) !RootfsCacheLock {
    return openRootfsCacheLock(io, allocator, cache_root, false);
}

pub fn tryLockRootfsCacheExclusive(io: Io, allocator: std.mem.Allocator, cache_root: []const u8) !RootfsCacheLock {
    return openRootfsCacheLock(io, allocator, cache_root, true);
}

fn openRootfsCacheLock(io: Io, allocator: std.mem.Allocator, cache_root: []const u8, nonblocking: bool) !RootfsCacheLock {
    try ensureDirPath(io, cache_root);
    const path = try std.fs.path.join(allocator, &.{ cache_root, rootfs_cache_lock_name });
    defer allocator.free(path);
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);
    const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0o600));
    if (fd < 0) return error.IoFailed;
    errdefer _ = std.c.close(fd);

    const op = flock_exclusive | if (nonblocking) flock_nonblocking else @as(c_int, 0);
    if (std.c.flock(fd, op) != 0) {
        return switch (std.c.errno(-1)) {
            .AGAIN => if (nonblocking) error.LockBusy else error.IoFailed,
            else => error.IoFailed,
        };
    }
    const file_identity = rootfsCacheLockFileIdentity(fd) orelse return error.IoFailed;
    return .{ .state = .{ .fd = fd, .file_identity = file_identity } };
}

fn rootfsCacheLockFileIdentity(fd: std.c.fd_t) ?RootfsCacheLockFileIdentity {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var stat: linux.Statx = std.mem.zeroes(linux.Statx);
        const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .INO = true }, &stat);
        if (linux.errno(rc) != .SUCCESS or !stat.mask.TYPE or !stat.mask.INO or !linux.S.ISREG(stat.mode)) return null;
        return .{
            .device = (@as(u64, stat.dev_major) << 32) | stat.dev_minor,
            .inode = stat.ino,
        };
    }
    var stat: std.c.Stat = undefined;
    if (std.c.fstat(fd, &stat) != 0 or !std.c.S.ISREG(stat.mode)) return null;
    return .{ .device = @intCast(stat.dev), .inode = @intCast(stat.ino) };
}

pub fn parseResolveOptions(args: []const []const u8) !ParsedResolveOptions {
    var image_ref: ?[]const u8 = null;
    var platform: Platform = native_platform;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--platform")) {
            i += 1;
            if (i >= args.len) return error.MissingPlatform;
            platform = try Platform.parse(args[i]);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownRootFSOption;
        } else if (image_ref == null) {
            image_ref = arg;
        } else {
            return error.TooManyRootFSArguments;
        }
    }

    return .{
        .ref = image_ref orelse return error.MissingImageReference,
        .platform = platform,
    };
}

pub fn parseImportOciOptions(args: []const []const u8) !ParsedImportOciOptions {
    return parseLocalImportOptions(args, error.MissingOciLayoutPath);
}

pub fn parseImportTarOptions(args: []const []const u8) !ParsedImportTarOptions {
    return parseLocalImportOptions(args, error.MissingRootFSTarPath);
}

fn parseLocalImportOptions(args: []const []const u8, missing_input: anyerror) !ParsedImportOciOptions {
    var input: ?[]const u8 = null;
    var image_ref: ?[]const u8 = null;
    var platform: Platform = native_platform;
    var rootfs_storage: RootfsStoragePolicy = .chunked;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--tag")) {
            i += 1;
            if (i >= args.len) return error.MissingImageReference;
            image_ref = args[i];
        } else if (std.mem.eql(u8, arg, "--platform")) {
            i += 1;
            if (i >= args.len) return error.MissingPlatform;
            platform = try Platform.parse(args[i]);
        } else if (std.mem.eql(u8, arg, "--rootfs-storage")) {
            i += 1;
            if (i >= args.len) return error.MissingRootFSStoragePolicy;
            rootfs_storage = try parseRootfsStoragePolicy(args[i]);
        } else if (std.mem.startsWith(u8, arg, "--rootfs-storage=")) {
            rootfs_storage = try parseRootfsStoragePolicy(arg["--rootfs-storage=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownRootFSOption;
        } else if (input == null) {
            input = arg;
        } else {
            return error.TooManyRootFSArguments;
        }
    }

    const ref = image_ref orelse return error.MissingImageReference;
    _ = try parseLocalTagRef(ref);
    return .{
        .input = input orelse return missing_input,
        .ref = ref,
        .platform = platform,
        .rootfs_storage = rootfs_storage,
    };
}

fn parseRootfsStoragePolicy(raw: []const u8) !RootfsStoragePolicy {
    if (std.mem.eql(u8, raw, "chunked")) return .chunked;
    return error.UnsupportedRootFSStoragePolicy;
}

fn ensureSupportedRootfsStoragePolicy(policy: RootfsStoragePolicy) !void {
    switch (policy) {
        .chunked => {},
        .flat => return error.UnsupportedRootfsStorage,
    }
}

pub fn parseBuildOptions(allocator: std.mem.Allocator, args: []const []const u8) !ParsedBuildOptions {
    var image_ref: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var metadata: ?[]const u8 = null;
    var platform: ?Platform = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.MissingOutputPath;
            output = args[i];
        } else if (std.mem.eql(u8, arg, "--metadata")) {
            i += 1;
            if (i >= args.len) return error.MissingMetadataPath;
            metadata = args[i];
        } else if (std.mem.eql(u8, arg, "--platform")) {
            i += 1;
            if (i >= args.len) return error.MissingPlatform;
            platform = try Platform.parse(args[i]);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownRootFSOption;
        } else if (image_ref == null) {
            image_ref = arg;
        } else {
            return error.TooManyRootFSArguments;
        }
    }

    const ref = image_ref orelse return error.MissingImageReference;
    const out = output orelse return error.MissingOutputPath;
    const meta = metadata orelse try std.fmt.allocPrint(allocator, "{s}.json", .{out});
    if (try sameResolvedPath(allocator, out, meta)) return error.RootFSMetadataPathMatchesOutput;
    return .{
        .ref = ref,
        .output = out,
        .metadata = meta,
        .platform = platform,
    };
}

fn sameResolvedPath(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !bool {
    const resolved_a = try std.fs.path.resolve(allocator, &.{a});
    defer allocator.free(resolved_a);
    const resolved_b = try std.fs.path.resolve(allocator, &.{b});
    defer allocator.free(resolved_b);
    return std.mem.eql(u8, resolved_a, resolved_b);
}

fn rejectMetadataOutputAlias(io: Io, output: []const u8, metadata: []const u8) !void {
    const output_stat = try Io.Dir.cwd().statFile(io, output, .{});
    const metadata_stat = Io.Dir.cwd().statFile(io, metadata, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    if (output_stat.kind == .file and metadata_stat.kind == .file and output_stat.inode == metadata_stat.inode) {
        return error.RootFSMetadataPathMatchesOutput;
    }
}

pub const Platform = oci.Platform;
pub const native_platform: Platform = .{ .arch = @import("architecture.zig").fromTarget(builtin.cpu.arch) orelse
    @compileError("SporeVM requires an arm64 or amd64 host architecture") };
pub const ImageRef = oci.ImageRef;
const ImageTag = oci.ImageTag;
const ImageManifest = oci.ImageManifest;
pub const ImageConfig = image_mod.Config;

pub const BuildResult = struct {
    schema: []const u8 = "spore.rootfs.build.result.v1",
    schema_version: u32 = 1,
    rootfs_storage: spore.RootfsStorage,
    platform: Platform = native_platform,
};

const MaterializeResult = struct {
    rootfs_storage: spore.RootfsStorage,
    /// Set for the catalog target.
    published: ?local_image.Published = null,
};

const RootfsBuildProfile = struct {
    enabled: bool,
    total_start_ms: u64,

    fn init(environ: *const std.process.Environ.Map) RootfsBuildProfile {
        const enabled = rootfsBuildProfileEnabled(environ.get(rootfs_build_profile_env));
        return .{
            .enabled = enabled,
            .total_start_ms = if (enabled) monotonicMs() else 0,
        };
    }

    fn start(self: RootfsBuildProfile) u64 {
        return if (self.enabled) monotonicMs() else 0;
    }

    fn phase(self: RootfsBuildProfile, name: []const u8, start_ms: u64) void {
        if (!self.enabled) return;
        std.debug.print("spore rootfs profile: phase={s} ms={d}\n", .{ name, monotonicMs() -| start_ms });
    }

    fn layerPhase(self: RootfsBuildProfile, layer: usize, start_ms: u64, input_bytes: u64, entries: u64, content_bytes: u64) void {
        if (!self.enabled) return;
        std.debug.print(
            "spore rootfs profile: phase=tree_merge_layer layer={d} ms={d} input_bytes={d} merged_entries={d} merged_content_bytes={d}\n",
            .{ layer, monotonicMs() -| start_ms, input_bytes, entries, content_bytes },
        );
    }

    fn inlineCasPhase(self: RootfsBuildProfile, start_ms: u64, result: rootfs_cas.PreloadResult) void {
        self.casPhase("rootfs_cas_inline", start_ms, result);
    }

    fn nativeExt4EmitPhase(self: RootfsBuildProfile, start_ms: u64, result: ext4_writer.Result) void {
        if (!self.enabled) return;
        const profile = result.profile;
        std.debug.print(
            "spore rootfs profile: phase=native_ext4_emit ms={d} plan_ms={d} assign_ms={d} metadata_build_ms={d} file_create_ms={d} emit_map_ms={d} metadata_write_ms={d} source_read_ms={d} data_write_ms={d} zero_ms={d} zero_write_ms={d} inline_cas_metadata_ms={d} inline_cas_data_ms={d} inline_cas_zero_ms={d} inline_cas_finish_ms={d} file_sync_ms={d} file_close_ms={d} metadata_blocks={d} data_blocks={d} zero_blocks={d} metadata_bytes_written={d} data_bytes_written={d} zero_bytes_skipped={d}\n",
            .{
                monotonicMs() -| start_ms,
                profile.plan_ms,
                profile.assign_ms,
                profile.metadata_build_ms,
                profile.file_create_ms,
                profile.emit_map_ms,
                profile.metadata_write_ms,
                profile.source_read_ms,
                profile.data_write_ms,
                profile.zero_ms,
                profile.zero_write_ms,
                profile.inline_cas_metadata_ms,
                profile.inline_cas_data_ms,
                profile.inline_cas_zero_ms,
                profile.inline_cas_finish_ms,
                profile.file_sync_ms,
                profile.file_close_ms,
                profile.metadata_blocks,
                profile.data_blocks,
                profile.zero_blocks,
                profile.metadata_bytes_written,
                profile.data_bytes_written,
                profile.zero_bytes_skipped,
            },
        );
    }

    fn casPhase(self: RootfsBuildProfile, name: []const u8, start_ms: u64, result: rootfs_cas.PreloadResult) void {
        if (!self.enabled) return;
        std.debug.print(
            "spore rootfs profile: phase={s} ms={d} chunks={d} zero_chunks={d} nonzero_chunks={d} objects_written={d} object_bytes_written={d} index_bytes={d} chunk_scan_ms={d} object_check_ms={d} object_write_ms={d} index_build_ms={d} index_write_ms={d} sealed_chunks={d} seal_workers={d} seal_wall_ms={d} seal_worker_cpu_ms={d}\n",
            .{
                name,
                monotonicMs() -| start_ms,
                result.chunk_count,
                result.zero_chunks,
                result.nonzero_chunks,
                result.objects_written,
                result.object_bytes_written,
                result.index_bytes,
                result.chunk_scan_ms,
                result.object_check_ms,
                result.object_write_ms,
                result.index_build_ms,
                result.index_write_ms,
                result.sealed_chunks,
                result.seal_workers,
                result.seal_wall_ms,
                result.seal_worker_cpu_ms,
            },
        );
    }

    fn finish(self: RootfsBuildProfile) void {
        self.phase("total", self.total_start_ms);
    }
};

fn rootfsBuildProfileEnabled(value: ?[]const u8) bool {
    const raw = value orelse return false;
    return raw.len != 0;
}

pub fn validateTaggedImageRef(raw_ref: []const u8) !void {
    _ = try ImageTag.parse(raw_ref);
}

const BuildImageSource = struct {
    ref: ImageRef,
    manifest_bytes: []const u8,
};

const RootFSMetadata = struct {
    builder_version: []const u8,
    ext4_writer: []const u8,
    image_ref: []const u8,
    resolved_image_ref: []const u8,
    image_manifest_digest: []const u8,
    platform: Platform,
    config_digest: []const u8,
    config: ImageConfig,
    layers: []const oci.LayerMetadata,
    deterministic: bool,
    ext4_uuid: []const u8,
    ext4_hash_seed: []const u8,
    rootfs_path: []const u8,
    rootfs_size: u64,
    rootfs_storage: spore.RootfsStorage,
};

fn resolveTaggedImageRef(init: std.process.Init, allocator: std.mem.Allocator, opts: ParsedResolveOptions) ![]const u8 {
    const image_tag = try ImageTag.parse(opts.ref);

    var client: std.http.Client = .{ .allocator = allocator, .io = init.io };
    defer client.deinit();
    var session = try registry.Session.init(&client, init.environ_map);

    const fetched = try registry.fetchManifestByTag(allocator, &session, image_tag);
    const tag_digest = try manifestContentDigest(allocator, fetched.bytes, fetched.content_digest);
    const image_ref = ImageRef{
        .registry = image_tag.registry,
        .repository = image_tag.repository,
        .digest = tag_digest,
    };
    const selected_manifest_digest = try resolveManifestDigest(
        allocator,
        &session,
        image_ref,
        opts.platform,
        tag_digest,
        fetched.bytes,
    );
    const selected_manifest_bytes = try selectedManifestBytes(
        allocator,
        &session,
        image_ref,
        selected_manifest_digest,
        fetched.bytes,
    );
    try validateManifestConfigPlatform(allocator, &session, image_ref, selected_manifest_bytes, opts.platform);
    return image_tag.digestRef(allocator, selected_manifest_digest);
}

pub fn resolveImageRef(init: std.process.Init, allocator: std.mem.Allocator, raw_ref: []const u8, platform: Platform) !ResolvedImage {
    var client: std.http.Client = .{ .allocator = allocator, .io = init.io };
    defer client.deinit();
    var session = try registry.Session.init(&client, init.environ_map);

    const image_source = try fetchBuildImageSource(allocator, &session, raw_ref);
    const image_ref = image_source.ref;
    const manifest_digest = try resolveManifestDigest(allocator, &session, image_ref, platform, image_ref.digest, image_source.manifest_bytes);
    const selected_manifest_bytes = try selectedManifestBytes(allocator, &session, image_ref, manifest_digest, image_source.manifest_bytes);
    try validateManifestConfigPlatform(allocator, &session, image_ref, selected_manifest_bytes, platform);

    return .{
        .ref = try digestImageRef(allocator, image_ref, manifest_digest),
        .manifest_digest = manifest_digest,
        .platform = platform,
    };
}

pub fn digestPinnedImageIdentity(allocator: std.mem.Allocator, raw_ref: []const u8, platform: Platform) !?ResolvedImage {
    const image_ref = ImageRef.parse(raw_ref) catch |err| switch (err) {
        error.ImageRefMustBeDigestPinned => return null,
        else => |e| return e,
    };
    return .{
        .ref = try digestImageRef(allocator, image_ref, image_ref.digest),
        .manifest_digest = image_ref.digest,
        .platform = platform,
    };
}

fn manifestContentDigest(allocator: std.mem.Allocator, manifest_bytes: []const u8, content_digest: ?[]const u8) ![]const u8 {
    if (content_digest) |digest| {
        if (!oci.isSha256Digest(digest)) return error.UnsupportedDigest;
        try oci.verifyDigestBytes(digest, manifest_bytes);
    }
    return oci.digestBytesAlloc(allocator, manifest_bytes);
}

fn fetchBuildImageSource(
    allocator: std.mem.Allocator,
    session: *registry.Session,
    raw_ref: []const u8,
) !BuildImageSource {
    if (ImageRef.parse(raw_ref)) |image_ref| {
        const manifest_bytes = try registry.fetchManifest(allocator, session, image_ref, image_ref.digest);
        try oci.verifyDigestBytes(image_ref.digest, manifest_bytes);
        return .{ .ref = image_ref, .manifest_bytes = manifest_bytes };
    } else |err| switch (err) {
        error.ImageRefMustBeDigestPinned => {},
        else => |e| return e,
    }

    const image_tag = try ImageTag.parse(raw_ref);
    const fetched = try registry.fetchManifestByTag(allocator, session, image_tag);
    const tag_digest = try manifestContentDigest(allocator, fetched.bytes, fetched.content_digest);
    return .{
        .ref = .{
            .registry = image_tag.registry,
            .repository = image_tag.repository,
            .digest = tag_digest,
        },
        .manifest_bytes = fetched.bytes,
    };
}

fn digestImageRef(allocator: std.mem.Allocator, image_ref: ImageRef, digest: []const u8) ![]u8 {
    if (!oci.isSha256Digest(digest)) return error.UnsupportedDigest;
    return std.fmt.allocPrint(allocator, "{s}/{s}@{s}", .{ image_ref.registry, image_ref.repository, digest });
}

fn selectedManifestBytes(
    allocator: std.mem.Allocator,
    session: *registry.Session,
    image_ref: ImageRef,
    digest: []const u8,
    initial_manifest_bytes: []const u8,
) ![]const u8 {
    const bytes = if (std.mem.eql(u8, digest, image_ref.digest))
        initial_manifest_bytes
    else
        try registry.fetchManifest(allocator, session, image_ref, digest);
    try oci.verifyDigestBytes(digest, bytes);
    return bytes;
}

fn validateManifestConfigPlatform(
    allocator: std.mem.Allocator,
    session: *registry.Session,
    image_ref: ImageRef,
    manifest_bytes: []const u8,
    platform: Platform,
) !void {
    var manifest_parsed = try std.json.parseFromSlice(ImageManifest, allocator, manifest_bytes, .{ .ignore_unknown_fields = true });
    defer manifest_parsed.deinit();
    const manifest = manifest_parsed.value;

    if (manifest.schemaVersion != 2) return error.UnsupportedManifestSchema;
    if (!oci.isSha256Digest(manifest.config.digest)) return error.UnsupportedDigest;
    const config_bytes = try registry.fetchBlobBytes(allocator, session, image_ref, manifest.config.digest, manifest.config.size);
    try oci.verifyDigestBytes(manifest.config.digest, config_bytes);
    var config_parsed = try std.json.parseFromSlice(ImageConfig, allocator, config_bytes, .{ .ignore_unknown_fields = true });
    defer config_parsed.deinit();
    try validateConfigPlatform(config_parsed.value, platform);
}

pub fn build(init: std.process.Init, allocator: std.mem.Allocator, request: BuildRequest) !BuildResult {
    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    const result = try buildRootFS(init, allocator, .{
        .ref = request.ref,
        .platform = request.platform orelse native_platform,
        .temp_dir_root = try std.fs.path.join(allocator, &.{ cache_root, "tmp" }),
        .target = .{ .file = .{ .output = request.output, .metadata = request.metadata } },
    });
    return .{ .rootfs_storage = result.rootfs_storage, .platform = request.platform orelse native_platform };
}

/// Pull `resolved` from its registry, convert it, and publish it as a local
/// image, pointing `name` at it when set.
pub fn pullImage(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    resolved: ResolvedImage,
    name: ?[]const u8,
) !local_image.Published {
    const temp_dir_root = try std.fs.path.join(allocator, &.{ cache_root, "tmp" });
    try ensureDirPath(init.io, temp_dir_root);
    std.log.debug("spore rootfs: pulling {s}", .{resolved.ref});
    const result = try buildRootFS(init, allocator, .{
        .ref = resolved.ref,
        .platform = resolved.platform,
        .temp_dir_root = temp_dir_root,
        .target = .{ .catalog = .{ .name = name } },
    });
    return result.published.?;
}

pub fn importOciLayout(init: std.process.Init, allocator: std.mem.Allocator, request: ImportOciRequest) !ImportOciResult {
    _ = try parseLocalTagRef(request.ref);
    try ensureSupportedRootfsStoragePolicy(request.rootfs_storage);
    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    try ensureDirPath(init.io, cache_root);
    const temp_dir_root = try std.fs.path.join(allocator, &.{ cache_root, "tmp" });
    try ensureDirPath(init.io, temp_dir_root);

    const temp_id = Io.Clock.real.now(init.io).nanoseconds;
    var temp_nonce_bytes: [8]u8 = undefined;
    init.io.random(&temp_nonce_bytes);
    const temp_nonce = std.mem.readInt(u64, &temp_nonce_bytes, .little);
    const import_temp_dir = try std.fmt.allocPrint(allocator, "{s}/import-oci-{d}-{x}", .{ temp_dir_root, temp_id, temp_nonce });
    defer Io.Dir.cwd().deleteTree(init.io, import_temp_dir) catch {};
    try Io.Dir.cwd().createDirPath(init.io, import_temp_dir);

    const layout_dir = try prepareOciLayoutPath(allocator, init.io, request.input, import_temp_dir);
    const source = try oci_layout.readSelectedImage(allocator, init.io, layout_dir, request.platform);
    const source_ref = try localSourceRef(allocator, request.ref, source.manifest_digest);
    if (try importedImage(init.io, allocator, cache_root, request.ref, source_ref, request.platform)) |result| return result;
    const result = try buildRootFSFromLayout(init, allocator, .{
        .requested_ref = request.ref,
        .resolved_image_ref = source_ref,
        .manifest_digest = source.manifest_digest,
        .source = source,
        .platform = request.platform,
        .temp_dir_root = temp_dir_root,
        .target = .{ .catalog = .{ .name = request.ref } },
    });
    return importResult(result.published.?, result.rootfs_storage);
}

pub fn importTar(init: std.process.Init, allocator: std.mem.Allocator, request: ImportTarRequest) !ImportTarResult {
    _ = try parseLocalTagRef(request.ref);
    try ensureSupportedRootfsStoragePolicy(request.rootfs_storage);
    const input_stat = try Io.Dir.cwd().statFile(init.io, request.input, .{ .follow_symlinks = false });
    if (input_stat.kind != .file) return error.UnsupportedRootFSTarInput;

    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    try ensureDirPath(init.io, cache_root);
    const temp_dir_root = try std.fs.path.join(allocator, &.{ cache_root, "tmp" });
    try ensureDirPath(init.io, temp_dir_root);

    const input_digest = try sha256FileDigestAlloc(allocator, init.io, request.input);
    const source_ref = try localSourceRef(allocator, request.ref, input_digest);
    if (try importedImage(init.io, allocator, cache_root, request.ref, source_ref, request.platform)) |result| return result;
    const result = try buildRootFSFromTar(init, allocator, .{
        .requested_ref = request.ref,
        .resolved_image_ref = source_ref,
        .manifest_digest = input_digest,
        .input = request.input,
        .platform = request.platform,
        .temp_dir_root = temp_dir_root,
        .target = .{ .catalog = .{ .name = request.ref } },
    });
    return importResult(result.published.?, result.rootfs_storage);
}

/// An import of a source the current builder already converted only retags
/// the existing image.
fn importedImage(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    name: []const u8,
    source_ref: []const u8,
    platform: Platform,
) !?ImportOciResult {
    const local = (try local_image.find(io, allocator, cache_root, source_ref, platform)) orelse return null;
    var cache_lock = try lockRootfsCacheExclusive(io, allocator, cache_root);
    defer cache_lock.deinit();
    const ref_path = try local_image.tag(allocator, cache_root, &cache_lock, name, local);
    std.log.debug("spore rootfs: using imported image {s} for {s}", .{ local.identity, name });
    return .{
        .metadata_path = try local_image.recordPath(allocator, cache_root, local.identity),
        .local_ref_path = ref_path,
        .resolved_image_ref = try local_image.resolvedRefAlloc(allocator, name, local.identity, local.oci),
        .image_manifest_digest = local.identity,
        .rootfs_storage = local.storage,
    };
}

fn importResult(published: local_image.Published, storage: spore.RootfsStorage) ImportOciResult {
    return .{
        .metadata_path = published.record_path,
        .local_ref_path = published.ref_path.?,
        .resolved_image_ref = published.resolved_ref,
        .image_manifest_digest = published.identity,
        .rootfs_storage = storage,
    };
}

pub fn resolveReference(init: std.process.Init, allocator: std.mem.Allocator, request: ResolveRequest) ![]const u8 {
    if (isLocalImageRef(request.ref)) {
        const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
        const identity = (try local_image.lookup(init.io, allocator, cache_root, request.ref, request.platform)) orelse return error.FileNotFound;
        const local = (try local_image.readRecord(init.io, allocator, cache_root, identity)) orelse return error.FileNotFound;
        return local_image.resolvedRefAlloc(allocator, request.ref, local.identity, local.oci);
    }
    return resolveTaggedImageRef(init, allocator, .{
        .ref = request.ref,
        .platform = request.platform,
    });
}

pub fn deinitBuildResult(allocator: std.mem.Allocator, result: BuildResult) void {
    deinitStorageDigestFields(allocator, result.rootfs_storage);
}

pub fn deinitResolvedReference(allocator: std.mem.Allocator, resolved_ref: []const u8) void {
    allocator.free(resolved_ref);
}

pub fn deinitRootfsStorageDescriptor(allocator: std.mem.Allocator, storage: spore.RootfsStorage) void {
    deinitStorageDigestFields(allocator, storage);
}

/// Own only the digest strings; validated invariant fields are normalized to
/// static format constants so every rootfs result has one deinit discipline.
pub fn cloneRootfsStorageDigestFields(allocator: std.mem.Allocator, storage: spore.RootfsStorage) !spore.RootfsStorage {
    try spore.validateRootfsStorageDescriptor(storage);
    try spore.validateRootfsDeviceShape(storage.device);
    const index_digest = try allocator.dupe(u8, storage.index_digest);
    return .{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = .{ .mmio_slot = storage.device.mmio_slot },
        .logical_size = storage.logical_size,
        .chunk_size = spore.disk_chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .index_digest = index_digest,
        .base_identity = index_digest,
        .object_namespace = spore.rootfs_storage_object_namespace,
    };
}

fn deinitStorageDigestFields(allocator: std.mem.Allocator, storage: spore.RootfsStorage) void {
    if (storage.index_digest.ptr == storage.base_identity.ptr and storage.index_digest.len == storage.base_identity.len) {
        allocator.free(storage.index_digest);
    } else {
        allocator.free(storage.index_digest);
        allocator.free(storage.base_identity);
    }
}

const LayoutBuildOptions = struct {
    requested_ref: []const u8,
    resolved_image_ref: []const u8,
    manifest_digest: []const u8,
    source: oci_layout.SelectedImage,
    platform: Platform = .{},
    temp_dir_root: []const u8,
    target: Target,
};

const TarBuildOptions = struct {
    requested_ref: []const u8,
    resolved_image_ref: []const u8,
    manifest_digest: []const u8,
    input: []const u8,
    platform: Platform = .{},
    temp_dir_root: []const u8,
    target: Target,
};

const MaterializeLayer = struct {
    media_type: []const u8,
    digest: []const u8,
    path: []const u8,
};

const MaterializeOptions = struct {
    requested_ref: []const u8,
    resolved_image_ref: []const u8,
    manifest_digest: []const u8,
    /// Index digest the registry manifest was selected from.
    selected_from: ?[]const u8 = null,
    platform: Platform = .{},
    config_digest: []const u8,
    config: ImageConfig,
    layers: []const MaterializeLayer,
    temp_dir: []const u8,
    profile: RootfsBuildProfile,
    target: Target,
};

fn buildRootFS(init: std.process.Init, allocator: std.mem.Allocator, opts: BuildOptions) !MaterializeResult {
    var client: std.http.Client = .{ .allocator = allocator, .io = init.io };
    defer client.deinit();
    var session = try registry.Session.init(&client, init.environ_map);

    try Io.Dir.cwd().createDirPath(init.io, opts.temp_dir_root);
    const temp_id = Io.Clock.real.now(init.io).nanoseconds;
    var temp_nonce_bytes: [8]u8 = undefined;
    init.io.random(&temp_nonce_bytes);
    const temp_nonce = std.mem.readInt(u64, &temp_nonce_bytes, .little);
    const temp_dir = try std.fmt.allocPrint(allocator, "{s}/spore-rootfs-{d}-{x}", .{ opts.temp_dir_root, temp_id, temp_nonce });
    errdefer Io.Dir.cwd().deleteTree(init.io, temp_dir) catch {};
    try Io.Dir.cwd().createDirPath(init.io, temp_dir);
    const profile = RootfsBuildProfile.init(init.environ_map);

    const layers_dir = try std.fmt.allocPrint(allocator, "{s}/layers", .{temp_dir});
    try Io.Dir.cwd().createDirPath(init.io, layers_dir);

    const resolve_start = profile.start();
    const image_source = try fetchBuildImageSource(allocator, &session, opts.ref);
    const image_ref = image_source.ref;
    const manifest_bytes = image_source.manifest_bytes;
    const manifest_digest = try resolveManifestDigest(allocator, &session, image_ref, opts.platform, image_ref.digest, manifest_bytes);
    const resolved_image_ref = try digestImageRef(allocator, image_ref, manifest_digest);
    const selected_manifest_bytes = try selectedManifestBytes(allocator, &session, image_ref, manifest_digest, manifest_bytes);
    profile.phase("oci_resolve_fetch", resolve_start);

    var manifest_parsed = try std.json.parseFromSlice(ImageManifest, allocator, selected_manifest_bytes, .{ .ignore_unknown_fields = true });
    defer manifest_parsed.deinit();
    const manifest = manifest_parsed.value;

    if (manifest.schemaVersion != 2) return error.UnsupportedManifestSchema;
    if (manifest.layers.len > max_rootfs_layers) return error.RootFSTooManyLayers;

    const config_start = profile.start();
    if (!oci.isSha256Digest(manifest.config.digest)) return error.UnsupportedDigest;
    const config_bytes = try registry.fetchBlobBytes(allocator, &session, image_ref, manifest.config.digest, manifest.config.size);
    try oci.verifyDigestBytes(manifest.config.digest, config_bytes);
    var config_parsed = try std.json.parseFromSlice(ImageConfig, allocator, config_bytes, .{ .ignore_unknown_fields = true });
    defer config_parsed.deinit();
    try validateConfigPlatform(config_parsed.value, opts.platform);
    profile.phase("oci_config_fetch", config_start);

    const layer_fetch_start = profile.start();
    const layer_files = try allocator.alloc(MaterializeLayer, manifest.layers.len);
    for (manifest.layers, 0..) |layer, i| {
        if (!oci.isSupportedLayerMediaType(layer.mediaType)) return error.UnsupportedLayerMediaType;
        const layer_path = try layerBlobPath(allocator, layers_dir, layer.digest);
        try registry.fetchBlobToFile(allocator, init.io, &session, image_ref, layer.digest, layer.size, tar.max_content_bytes, layer_path);
        try oci.verifyDigestFile(init.io, layer.digest, layer_path);
        layer_files[i] = .{ .media_type = layer.mediaType, .digest = layer.digest, .path = layer_path };
    }
    profile.phase("oci_layer_fetch", layer_fetch_start);

    const result = try materializeRootFS(init, allocator, .{
        .requested_ref = opts.ref,
        .resolved_image_ref = resolved_image_ref,
        .manifest_digest = manifest_digest,
        .selected_from = image_ref.digest,
        .platform = opts.platform,
        .config_digest = manifest.config.digest,
        .config = config_parsed.value,
        .layers = layer_files,
        .temp_dir = temp_dir,
        .profile = profile,
        .target = opts.target,
    });
    const cleanup_start = profile.start();
    Io.Dir.cwd().deleteTree(init.io, temp_dir) catch {};
    profile.phase("temp_cleanup", cleanup_start);
    profile.finish();
    return result;
}

fn buildRootFSFromLayout(init: std.process.Init, allocator: std.mem.Allocator, opts: LayoutBuildOptions) !MaterializeResult {
    try Io.Dir.cwd().createDirPath(init.io, opts.temp_dir_root);
    const temp_id = Io.Clock.real.now(init.io).nanoseconds;
    var temp_nonce_bytes: [8]u8 = undefined;
    init.io.random(&temp_nonce_bytes);
    const temp_nonce = std.mem.readInt(u64, &temp_nonce_bytes, .little);
    const temp_dir = try std.fmt.allocPrint(allocator, "{s}/spore-rootfs-{d}-{x}", .{ opts.temp_dir_root, temp_id, temp_nonce });
    errdefer Io.Dir.cwd().deleteTree(init.io, temp_dir) catch {};
    try Io.Dir.cwd().createDirPath(init.io, temp_dir);
    const profile = RootfsBuildProfile.init(init.environ_map);

    if (opts.source.layers.len > max_rootfs_layers) return error.RootFSTooManyLayers;

    const config_start = profile.start();
    var config_parsed = try std.json.parseFromSlice(ImageConfig, allocator, opts.source.config_bytes, .{ .ignore_unknown_fields = true });
    defer config_parsed.deinit();
    try validateConfigPlatform(config_parsed.value, opts.platform);
    profile.phase("oci_config_parse", config_start);

    const layer_plan_start = profile.start();
    const layer_files = try allocator.alloc(MaterializeLayer, opts.source.layers.len);
    for (opts.source.layers, 0..) |layer, i| {
        if (!oci.isSupportedLayerMediaType(layer.media_type)) return error.UnsupportedLayerMediaType;
        layer_files[i] = .{ .media_type = layer.media_type, .digest = layer.digest, .path = layer.path };
    }
    profile.phase("oci_layer_plan", layer_plan_start);

    const result = try materializeRootFS(init, allocator, .{
        .requested_ref = opts.requested_ref,
        .resolved_image_ref = opts.resolved_image_ref,
        .manifest_digest = opts.manifest_digest,
        .platform = opts.platform,
        .config_digest = opts.source.config_digest,
        .config = config_parsed.value,
        .layers = layer_files,
        .temp_dir = temp_dir,
        .profile = profile,
        .target = opts.target,
    });
    const cleanup_start = profile.start();
    Io.Dir.cwd().deleteTree(init.io, temp_dir) catch {};
    profile.phase("temp_cleanup", cleanup_start);
    profile.finish();
    return result;
}

fn buildRootFSFromTar(init: std.process.Init, allocator: std.mem.Allocator, opts: TarBuildOptions) !MaterializeResult {
    try Io.Dir.cwd().createDirPath(init.io, opts.temp_dir_root);
    const temp_id = Io.Clock.real.now(init.io).nanoseconds;
    var temp_nonce_bytes: [8]u8 = undefined;
    init.io.random(&temp_nonce_bytes);
    const temp_nonce = std.mem.readInt(u64, &temp_nonce_bytes, .little);
    const temp_dir = try std.fmt.allocPrint(allocator, "{s}/spore-rootfs-{d}-{x}", .{ opts.temp_dir_root, temp_id, temp_nonce });
    errdefer Io.Dir.cwd().deleteTree(init.io, temp_dir) catch {};
    try Io.Dir.cwd().createDirPath(init.io, temp_dir);
    const profile = RootfsBuildProfile.init(init.environ_map);

    const layer_plan_start = profile.start();
    const layers = try allocator.alloc(MaterializeLayer, 1);
    layers[0] = .{
        .media_type = "application/vnd.oci.image.layer.v1.tar",
        .digest = opts.manifest_digest,
        .path = opts.input,
    };
    profile.phase("rootfs_tar_plan", layer_plan_start);

    const result = try materializeRootFS(init, allocator, .{
        .requested_ref = opts.requested_ref,
        .resolved_image_ref = opts.resolved_image_ref,
        .manifest_digest = opts.manifest_digest,
        .platform = opts.platform,
        .config_digest = opts.manifest_digest,
        .config = .{ .architecture = opts.platform.arch, .os = opts.platform.os },
        .layers = layers,
        .temp_dir = temp_dir,
        .profile = profile,
        .target = opts.target,
    });
    const cleanup_start = profile.start();
    Io.Dir.cwd().deleteTree(init.io, temp_dir) catch {};
    profile.phase("temp_cleanup", cleanup_start);
    profile.finish();
    return result;
}

fn materializeRootFS(init: std.process.Init, allocator: std.mem.Allocator, opts: MaterializeOptions) !MaterializeResult {
    if (opts.layers.len > max_rootfs_layers) return error.RootFSTooManyLayers;
    const layer_meta = try allocator.alloc(oci.LayerMetadata, opts.layers.len);
    const deterministic_ext4 = ext4.Determinism.fromDigest(opts.manifest_digest);
    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    defer allocator.free(cache_root);
    const output = switch (opts.target) {
        .file => |file| file.output,
        .catalog => try std.fs.path.join(allocator, &.{ opts.temp_dir, "rootfs.ext4" }),
    };
    var tree = try mergeLayers(init, allocator, opts, layer_meta);
    defer tree.deinit(allocator);

    // Fetching and merging touched only the private temp dir, which GC and
    // prune never read, so they run without the cache lock. Emit writes CAS
    // objects (or skips ones already present) that nothing roots until the
    // image record below is published, so emit and publication share one
    // lock epoch: GC cannot collect storage the record is about to root.
    if (comptime builtin.is_test) if (testing.publish_lock_barrier) |barrier| barrier.pause(init.io);
    var cache_lock = try lockRootfsCacheExclusive(init.io, allocator, cache_root);
    defer cache_lock.deinit();
    const preload_result = try emitMergedTree(init, allocator, opts, output, &tree, deterministic_ext4, cache_root, &cache_lock);
    const rootfs_storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload_result);
    const stat = try Io.Dir.cwd().statFile(init.io, output, .{});

    const metadata_start = opts.profile.start();
    defer opts.profile.phase("metadata_write", metadata_start);
    switch (opts.target) {
        .file => |file| {
            try ext4.ensureParentDir(init.io, file.metadata);
            try rejectMetadataOutputAlias(init.io, file.output, file.metadata);
            const metadata = RootFSMetadata{
                .builder_version = builder_version,
                .ext4_writer = ext4_writer_name,
                .image_ref = opts.requested_ref,
                .resolved_image_ref = opts.resolved_image_ref,
                .image_manifest_digest = opts.manifest_digest,
                .platform = opts.platform,
                .config_digest = opts.config_digest,
                .config = opts.config,
                .layers = layer_meta,
                .deterministic = true,
                .ext4_uuid = deterministic_ext4.uuid[0..],
                .ext4_hash_seed = deterministic_ext4.hash_seed[0..],
                .rootfs_path = file.output,
                .rootfs_size = stat.size,
                .rootfs_storage = rootfs_storage,
            };
            const metadata_json = try std.json.Stringify.valueAlloc(allocator, metadata, .{
                .whitespace = .indent_2,
                .emit_null_optional_fields = false,
            });
            try ext4.writeFileAtPath(init.io, file.metadata, metadata_json);
            return .{ .rootfs_storage = rootfs_storage };
        },
        .catalog => |catalog| {
            // An existing digest-addressed file wins over this output; the
            // catalog links whichever file the digest path names. Without
            // hard links the image keeps no flat file; runs read its chunks.
            const flat_path = if (try rootfs_cache.installTrustedMaterializationByHardlink(init.io, allocator, cache_root, output, rootfs_storage.index_digest, stat.size)) |_|
                try rootfs_cache.digestPath(allocator, cache_root, rootfs_storage.index_digest)
            else
                null;
            const published = try local_image.publish(init.io, allocator, cache_root, &cache_lock, .{
                .platform = opts.platform,
                .config = opts.config,
                .storage = rootfs_storage,
                .oci = .{
                    .ref = opts.resolved_image_ref,
                    .manifest_digest = opts.manifest_digest,
                    .builder_version = builder_version,
                },
                .selected_from = opts.selected_from,
                .flat_path = flat_path,
                .name = catalog.name,
            });
            return .{ .rootfs_storage = rootfs_storage, .published = published };
        },
    }
}

fn mergeLayers(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    opts: MaterializeOptions,
    layer_meta: []oci.LayerMetadata,
) !tar.MergedTree {
    const merge_start = opts.profile.start();
    var tree = tar.MergedTree.init(allocator);
    errdefer tree.deinit(allocator);
    for (opts.layers, 0..) |layer, layer_index| {
        if (!oci.isSupportedLayerMediaType(layer.media_type)) return error.UnsupportedLayerMediaType;
        layer_meta[layer_index] = .{ .media_type = layer.media_type, .digest = layer.digest };
        const layer_start = opts.profile.start();
        try tar.applyLayerToMergedTree(allocator, init.io, &tree, .{ .media_type = layer.media_type, .path = layer.path, .spill_dir = opts.temp_dir });
        const content_size = tree.contentSize();
        if (content_size > tar.max_content_bytes) return error.RootFSArchiveTooLarge;
        if (opts.profile.enabled) {
            const stat = try Io.Dir.cwd().statFile(init.io, layer.path, .{});
            opts.profile.layerPhase(layer_index, layer_start, stat.size, tree.entryCount(), content_size);
        }
    }
    opts.profile.phase("tree_merge", merge_start);

    const required_dirs_start = opts.profile.start();
    try ensureRequiredMergedDir(allocator, &tree, "dev", 0o755);
    try ensureRequiredMergedDir(allocator, &tree, "proc", 0o755);
    try ensureRequiredMergedDir(allocator, &tree, "run", 0o755);
    try ensureRequiredMergedDir(allocator, &tree, "sys", 0o755);
    try ensureRequiredMergedDir(allocator, &tree, "tmp", 0o1777);
    try ensureMergedResolverPlaceholder(allocator, &tree);
    opts.profile.phase("rootfs_tree_finalize", required_dirs_start);
    return tree;
}

fn emitMergedTree(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    opts: MaterializeOptions,
    output: []const u8,
    tree: *tar.MergedTree,
    deterministic_ext4: ext4.Determinism,
    cache_root: []const u8,
    cache_lock: *const RootfsCacheLock,
) !rootfs_cas.PreloadResult {
    if (!try cache_lock.ensureHeldFor(allocator, cache_root)) return error.RootfsCacheLockNotHeld;
    const scan_start = opts.profile.start();
    const content_size = tree.contentSize();
    if (content_size > tar.max_content_bytes) return error.RootFSArchiveTooLarge;
    const inode_count = ext4.computeImageInodes(tree.entryCount());
    const image_size = ext4.computeImageSize(content_size);
    opts.profile.phase("ext4_size_scan", scan_start);

    const native_start = opts.profile.start();
    const emit_result = try ext4_writer.emitFromMergedTree(allocator, init.io, tree, output, .{
        .image_size = image_size,
        .inode_count = @intCast(inode_count),
        .determinism = deterministic_ext4,
        .cas_cache_root = cache_root,
    });
    opts.profile.nativeExt4EmitPhase(native_start, emit_result);
    // A CAS cache root always yields an inline preload result.
    const preload_result = emit_result.preload_result.?;
    opts.profile.inlineCasPhase(native_start, preload_result);
    return preload_result;
}

fn monotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn resolveManifestDigest(
    allocator: std.mem.Allocator,
    session: *registry.Session,
    image_ref: ImageRef,
    platform: Platform,
    digest: []const u8,
    manifest_bytes: []const u8,
) ![]const u8 {
    const selected = try oci.selectedManifestDigest(allocator, manifest_bytes, platform) orelse return digest;
    const bytes = try registry.fetchManifest(allocator, session, image_ref, selected);
    try oci.verifyDigestBytes(selected, bytes);
    return selected;
}

fn validateConfigPlatform(config: ImageConfig, platform: Platform) !void {
    const os = config.os orelse return error.UnsupportedPlatform;
    const arch = config.architecture orelse return error.UnsupportedPlatform;
    if (!std.mem.eql(u8, os, platform.os) or arch != platform.arch) {
        return error.UnsupportedPlatform;
    }
}

fn layerBlobPath(allocator: std.mem.Allocator, layers_dir: []const u8, digest: []const u8) ![]u8 {
    if (!oci.isSha256Digest(digest)) return error.UnsupportedDigest;
    return std.fmt.allocPrint(allocator, "{s}/{s}.blob", .{ layers_dir, digest["sha256:".len..] });
}

fn sha256FileDigestAlloc(allocator: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
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
    const hex = std.fmt.bytesToHex(out, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{&hex});
}

fn prepareOciLayoutPath(allocator: std.mem.Allocator, io: Io, input: []const u8, temp_dir: []const u8) ![]const u8 {
    const stat = try Io.Dir.cwd().statFile(io, input, .{ .follow_symlinks = false });
    return switch (stat.kind) {
        .directory => input,
        .file => layout: {
            const layout_dir = try std.fs.path.join(allocator, &.{ temp_dir, "layout" });
            try oci_layout.extractTarToDir(allocator, io, input, layout_dir);
            break :layout layout_dir;
        },
        else => error.UnsupportedOciLayoutInput,
    };
}

pub fn isLocalImageRef(raw: []const u8) bool {
    return std.mem.startsWith(u8, raw, "local/");
}

pub fn validateLocalTagRef(raw: []const u8) !void {
    _ = try parseLocalTagRef(raw);
}

fn parseLocalTagRef(raw: []const u8) !ImageTag {
    const image_tag = try ImageTag.parse(raw);
    if (!std.mem.eql(u8, image_tag.registry, "local")) return error.LocalRefMustUseLocalRegistry;
    return image_tag;
}

/// The digest-pinned source ref recorded for an image imported under the
/// local name `raw_ref`: `local/<repo>@sha256:<digest>`.
fn localSourceRef(allocator: std.mem.Allocator, raw_ref: []const u8, digest: []const u8) ![]u8 {
    if (!oci.isSha256Digest(digest)) return error.UnsupportedDigest;
    const tag = try parseLocalTagRef(raw_ref);
    return std.fmt.allocPrint(allocator, "local/{s}@{s}", .{ tag.repository, digest });
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

fn ensureRequiredMergedDir(
    allocator: std.mem.Allocator,
    tree: *tar.MergedTree,
    rel: []const u8,
    mode: u32,
) !void {
    try tar.ensureMergedDirectory(allocator, tree, rel, mode, .{ .uid = 0, .gid = 0 });
}

fn ensureMergedResolverPlaceholder(
    allocator: std.mem.Allocator,
    tree: *tar.MergedTree,
) !void {
    try tar.ensureMergedDirectory(allocator, tree, "etc", 0o755, .{ .uid = 0, .gid = 0 });
    try tar.ensureMergedFile(allocator, tree, resolver_placeholder_path, resolver_placeholder_bytes, 0o644, .{ .uid = 0, .gid = 0 });
}

test {
    std.testing.refAllDecls(ext4_writer);
    std.testing.refAllDecls(oci_layout);
}

test "layer blob path validates sha256 digest before slicing" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedDigest, layerBlobPath(allocator, "layers", "sha256:short"));
    try std.testing.expectError(
        error.UnsupportedDigest,
        layerBlobPath(allocator, "layers", "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde/"),
    );
    const path = try layerBlobPath(
        allocator,
        "layers",
        "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    );
    defer allocator.free(path);
    try std.testing.expectEqualStrings(
        "layers/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.blob",
        path,
    );
}

test "build options reject metadata path matching output path" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.RootFSMetadataPathMatchesOutput,
        parseBuildOptions(allocator, &.{
            "registry.example/repo@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "--output",
            "rootfs.ext4",
            "--metadata",
            "rootfs.ext4",
        }),
    );
    try std.testing.expectError(
        error.RootFSMetadataPathMatchesOutput,
        parseBuildOptions(allocator, &.{
            "registry.example/repo@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "--output",
            "rootfs.ext4",
            "--metadata",
            "./rootfs.ext4",
        }),
    );
}

test "build options accept tag image refs" {
    const allocator = std.testing.allocator;
    const parsed = try parseBuildOptions(allocator, &.{
        "registry.example/repo:latest",
        "--output",
        "rootfs.ext4",
    });
    defer allocator.free(parsed.metadata);
    try std.testing.expectEqualStrings("registry.example/repo:latest", parsed.ref);
    try std.testing.expectEqualStrings("rootfs.ext4.json", parsed.metadata);
}

test "build options preserve platform inference for a local image ref" {
    const parsed = try parseBuildOptions(std.testing.allocator, &.{ "local/seed:v1", "--output", "rootfs.ext4" });
    defer std.testing.allocator.free(parsed.metadata);
    try std.testing.expectEqualStrings("local/seed:v1", parsed.ref);
    try std.testing.expectEqual(null, parsed.platform);
}

test "rootfs build keeps its temp dir in the rootfs cache and removes it on failure" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var env = std.process.Environ.Map.init(arena);
    try env.put(local_paths.rootfs_cache_env, try std.fs.path.join(arena, &.{ root, "cache" }));

    // The untagged ref fails only after the build has made its temp dir.
    try std.testing.expectError(error.ImageTagRequired, build(.{
        .minimal = undefined,
        .arena = &arena_state,
        .gpa = std.testing.allocator,
        .io = io,
        .environ_map = &env,
        .preopens = .empty,
    }, arena, .{
        .ref = "registry.example/repo",
        .output = try std.fs.path.join(arena, &.{ root, "rootfs.ext4" }),
        .metadata = try std.fs.path.join(arena, &.{ root, "rootfs.ext4.json" }),
    }));
    var temp_root = try tmp.dir.openDir(io, "cache/tmp", .{ .iterate = true });
    defer temp_root.close(io);
    var entries = temp_root.iterate();
    try std.testing.expect(try entries.next(io) == null);
}

test "resolve options parse image tag and platform" {
    try std.testing.expectEqual(native_platform.arch, (try parseResolveOptions(&.{"registry.example/repo:latest"})).platform.arch);
    const parsed = try parseResolveOptions(&.{
        "registry.example/repo:latest",
        "--platform",
        "linux/arm64",
    });
    try std.testing.expectEqualStrings("registry.example/repo:latest", parsed.ref);
    try std.testing.expectEqualStrings("linux", parsed.platform.os);
    try std.testing.expectEqual(.arm64, parsed.platform.arch);
    try std.testing.expectError(
        error.TooManyRootFSArguments,
        parseResolveOptions(&.{ "registry.example/repo:latest", "extra" }),
    );
}

test "import-oci options require a local mutable ref" {
    const parsed = try parseImportOciOptions(&.{
        "layout.oci",
        "--tag",
        "local/sporevm-app:dev",
        "--platform",
        "linux/arm64",
        "--rootfs-storage=chunked",
    });
    try std.testing.expectEqualStrings("layout.oci", parsed.input);
    try std.testing.expectEqualStrings("local/sporevm-app:dev", parsed.ref);
    try std.testing.expectEqual(.chunked, parsed.rootfs_storage);

    try std.testing.expectError(
        error.LocalRefMustUseLocalRegistry,
        parseImportOciOptions(&.{ "layout.oci", "--tag", "ghcr.io/org/image:dev" }),
    );
    try std.testing.expectError(
        error.BadImageReference,
        parseImportOciOptions(
            &.{ "layout.oci", "--tag", "local/sporevm-app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
        ),
    );
    try std.testing.expectError(
        error.UnsupportedRootFSStoragePolicy,
        parseImportOciOptions(
            &.{ "layout.oci", "--tag", "local/sporevm-app:dev", "--rootfs-storage=flat" },
        ),
    );
    try std.testing.expectError(
        error.UnsupportedRootFSStoragePolicy,
        parseImportOciOptions(
            &.{ "layout.oci", "--tag", "local/sporevm-app:dev", "--rootfs-storage", "native-oci" },
        ),
    );
}

test "import-tar options require a local mutable ref" {
    try std.testing.expectEqual(native_platform.arch, (try parseImportTarOptions(&.{ "rootfs.tar", "--tag", "local/default:dev" })).platform.arch);
    const parsed = try parseImportTarOptions(&.{
        "rootfs.tar",
        "--tag",
        "local/sporevm-app:dev",
        "--platform",
        "linux/arm64",
        "--rootfs-storage",
        "chunked",
    });
    try std.testing.expectEqualStrings("rootfs.tar", parsed.input);
    try std.testing.expectEqualStrings("local/sporevm-app:dev", parsed.ref);
    try std.testing.expectEqual(.chunked, parsed.rootfs_storage);

    try std.testing.expectError(
        error.UnsupportedRootFSStoragePolicy,
        parseImportTarOptions(
            &.{ "rootfs.tar", "--tag", "local/sporevm-app:dev", "--rootfs-storage", "flat" },
        ),
    );

    try std.testing.expectError(
        error.MissingRootFSTarPath,
        parseImportTarOptions(&.{ "--tag", "local/sporevm-app:dev" }),
    );
    try std.testing.expectError(
        error.LocalRefMustUseLocalRegistry,
        parseImportTarOptions(&.{ "rootfs.tar", "--tag", "ghcr.io/org/image:dev" }),
    );
}

test "tag manifest content digest is computed and registry header is verified" {
    const allocator = std.testing.allocator;
    const manifest = "{\"schemaVersion\":2,\"config\":{},\"layers\":[]}";
    const digest = try manifestContentDigest(allocator, manifest, null);
    defer allocator.free(digest);
    try std.testing.expectEqualStrings(
        "sha256:4108250765b19c4d5000be73d2bdd612bbb17a989972bcfd1adbf5085a9af46b",
        digest,
    );

    try std.testing.expectError(
        error.DigestMismatch,
        manifestContentDigest(
            allocator,
            manifest,
            "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        ),
    );
}

test "resolved image refs render selected digest" {
    const allocator = std.testing.allocator;
    const image_ref = try ImageRef.parse("registry.example/repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const resolved = try digestImageRef(
        allocator,
        image_ref,
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    );
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(
        "registry.example/repo@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        resolved,
    );
}

test "metadata path rejects symlink alias of existing output" {
    const io = std.testing.io;
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const output = try tmp_dir.path("rootfs.ext4");
    const metadata = try tmp_dir.path("metadata.json");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = output, .data = "image" });
    try Io.Dir.cwd().symLink(io, "rootfs.ext4", metadata, .{});

    try std.testing.expectError(error.RootFSMetadataPathMatchesOutput, rejectMetadataOutputAlias(io, output, metadata));
}

test "direct image config must match requested platform" {
    try validateConfigPlatform(.{ .os = "linux", .architecture = .arm64 }, .{ .os = "linux", .arch = .arm64 });
    try std.testing.expectError(
        error.UnsupportedPlatform,
        validateConfigPlatform(.{ .os = "linux", .architecture = .amd64 }, .{ .os = "linux", .arch = .arm64 }),
    );
    try std.testing.expectError(
        error.UnsupportedPlatform,
        validateConfigPlatform(.{ .os = null, .architecture = .arm64 }, .{ .os = "linux", .arch = .arm64 }),
    );
}

test "rootfs materialization adds required directories and resolver placeholder" {
    const allocator = std.testing.allocator;
    var tree = tar.MergedTree.init(allocator);
    defer tree.deinit(allocator);

    try ensureRequiredMergedDir(allocator, &tree, "tmp", 0o1777);
    try ensureMergedResolverPlaceholder(allocator, &tree);

    try std.testing.expectEqual(@as(u16, 0o1777), tree.entries.get("tmp").?.mode);
    try std.testing.expectEqual(tar.MergedEntryKind.directory, tree.entries.get("etc").?.kind);
    const resolver = tree.entries.get(resolver_placeholder_path).?;
    try std.testing.expectEqual(@as(u32, 0), resolver.uid);
    try std.testing.expectEqualStrings(resolver_placeholder_bytes, (try tree.fileSource(resolver.inode_id)).memory);
}
