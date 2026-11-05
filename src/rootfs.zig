//! OCI image to ext4 rootfs builder.
//!
//! This is intentionally a builder utility, not part of the VMM monitor
//! process. OCI manifests and layer tar streams are attacker-influenced input,
//! so layer application is strict and fail-closed.

const std = @import("std");
const builtin = @import("builtin");
const Sha256 = std.crypto.hash.sha2.Sha256;
const chunk = @import("chunk.zig");
const ext4 = @import("rootfs/ext4.zig");
pub const ext4_writer = @import("rootfs/ext4_writer.zig");
const image_mod = @import("image.zig");
const local_paths = @import("local_paths.zig");
const oci = @import("rootfs/oci.zig");
const oci_layout = @import("rootfs/oci_layout.zig");
const registry = @import("rootfs/registry.zig");
const rootfs_cache = @import("rootfs_cache.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const spore = @import("spore.zig");
const tar = @import("rootfs/tar.zig");
const test_barrier = @import("test_barrier.zig");

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

pub const usage =
    \\Usage: spore rootfs <command>
    \\
    \\Commands:
    \\  build <image@sha256:...|image:tag> --output <rootfs.ext4>
    \\  import-oci <layout-dir|layout.tar> --ref local/name:tag
    \\  import-tar <rootfs.tar> --ref local/name:tag
    \\  resolve <image:tag>
    \\
    \\Options:
    \\  --platform <os/arch>       Target platform: linux/arm64 or linux/amd64 (default: linux/arm64)
    \\  --metadata <path>          Metadata sidecar path (default: <output>.json)
    \\
;

pub const ParsedBuildOptions = struct {
    ref: []const u8,
    output: []const u8,
    metadata: []const u8,
    platform: Platform = .{},
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

pub const ParsedCasPreloadOptions = struct {
    digest: []const u8,
    chunk_size: u64 = rootfs_cas.default_chunk_size,
    attach_spore: ?[]const u8 = null,
};

pub const BuildRequest = struct {
    ref: []const u8,
    output: []const u8,
    metadata: []const u8,
    platform: Platform = .{},
    metadata_rootfs_path: ?[]const u8 = null,
    temp_dir_root: ?[]const u8 = null,
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

pub const CasPreloadRequest = struct {
    digest: []const u8,
    chunk_size: u64 = rootfs_cas.default_chunk_size,
    attach_spore: ?[]const u8 = null,
};

pub const CasPreloadResult = rootfs_cas.PreloadResult;

pub const ImportOciResult = struct {
    schema: []const u8 = "spore.rootfs.import.result.v1",
    schema_version: u32 = 1,
    rootfs_path: []const u8,
    metadata_path: []const u8,
    local_ref_path: []const u8,
    resolved_image_ref: []const u8,
    image_manifest_digest: []const u8,
    rootfs_storage: spore.RootfsStorage,
};

pub const ImportTarResult = ImportOciResult;

pub const PublishIndexedImageRequest = struct {
    ref: []const u8,
    platform: Platform = .{},
    config: ImageConfig = .{},
    rootfs_storage: spore.RootfsStorage,
    expected_image_digest: ?[]const u8 = null,
};

pub const PublishIndexedImageResult = struct {
    metadata_path: []const u8,
    local_ref_path: []const u8,
    resolved_image_ref: []const u8,
    image_manifest_digest: []const u8,
    rootfs_storage: spore.RootfsStorage,
};

pub const CachedIndexedRootfs = struct {
    metadata_path: []const u8,
    artifact: spore.RootfsArtifactRef,
    storage: spore.RootfsStorage,
};

pub const RootfsStoragePolicy = enum {
    chunked,
    flat,
};

const BuildOptions = struct {
    ref: []const u8,
    output: []const u8,
    metadata: []const u8,
    platform: Platform = .{},
    metadata_rootfs_path: ?[]const u8 = null,
    temp_dir_root: ?[]const u8 = null,
    publish: ?CachePublish = null,
};

/// Final cache paths for a materialized rootfs and its metadata. The metadata
/// roots the image's CAS storage for GC, so both are renamed into place in the
/// same cache-lock epoch that wrote the storage.
const CachePublish = struct {
    rootfs_path: []const u8,
    metadata_path: []const u8,
};

pub const ResolvedImage = struct {
    ref: []const u8,
    manifest_digest: []const u8,
    platform: Platform,
};

pub const local_ref_cache_kind = "sporevm-local-rootfs-ref-v1";
const image_ref_cache_record_version: u32 = 1;
const max_rootfs_metadata_bytes = 1024 * 1024;
const max_image_ref_cache_record_bytes = 64 * 1024;
const rootfs_cache_lock_name = ".sporevm-rootfs-cache.lock";
const flock_exclusive: c_int = 2;
const flock_nonblocking: c_int = 4;
const flock_unlock: c_int = 8;

const LocalRefMetadata = struct {
    kind: []const u8 = local_ref_cache_kind,
    ref: []const u8,
    resolved_image_ref: []const u8,
    image_manifest_digest: []const u8,
    platform: Platform,
    builder_version: []const u8 = builder_version,
};

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
        const path_z = try allocator.dupeZ(u8, path);
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
    const path_z = try allocator.dupeZ(u8, path);
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

pub fn parseResolveOptions(args: []const []const u8, stdout: *Io.Writer) !ParsedResolveOptions {
    if (args.len == 0) {
        try stdout.writeAll(usage);
        try stdout.flush();
        std.process.exit(2);
    }

    var image_ref: ?[]const u8 = null;
    var platform: Platform = .{};

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

pub fn parseImportOciOptions(args: []const []const u8, stdout: *Io.Writer) !ParsedImportOciOptions {
    return parseLocalImportOptions(args, stdout, error.MissingOciLayoutPath);
}

pub fn parseImportTarOptions(args: []const []const u8, stdout: *Io.Writer) !ParsedImportTarOptions {
    return parseLocalImportOptions(args, stdout, error.MissingRootFSTarPath);
}

fn parseLocalImportOptions(args: []const []const u8, stdout: *Io.Writer, missing_input: anyerror) !ParsedImportOciOptions {
    if (args.len == 0) {
        try stdout.writeAll(usage);
        try stdout.flush();
        std.process.exit(2);
    }

    var input: ?[]const u8 = null;
    var image_ref: ?[]const u8 = null;
    var platform: Platform = .{};
    var rootfs_storage: RootfsStoragePolicy = .chunked;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--ref")) {
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

pub fn parseCasPreloadOptions(args: []const []const u8, stdout: *Io.Writer) !ParsedCasPreloadOptions {
    if (args.len == 0) {
        try stdout.writeAll(usage);
        try stdout.flush();
        std.process.exit(2);
    }

    var digest: ?[]const u8 = null;
    var chunk_size: u64 = rootfs_cas.default_chunk_size;
    var attach_spore: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--chunk-size")) {
            i += 1;
            if (i >= args.len) return error.MissingChunkSize;
            chunk_size = std.fmt.parseInt(u64, args[i], 10) catch return error.InvalidChunkSize;
            if (chunk_size == 0 or chunk_size % 512 != 0 or chunk_size > std.math.maxInt(usize)) return error.InvalidChunkSize;
        } else if (std.mem.eql(u8, arg, "--attach-spore")) {
            i += 1;
            if (i >= args.len) return error.MissingSporeDir;
            attach_spore = args[i];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownRootFSOption;
        } else if (digest == null) {
            digest = arg;
        } else {
            return error.TooManyRootFSArguments;
        }
    }

    return .{
        .digest = digest orelse return error.MissingRootFSDigest,
        .chunk_size = chunk_size,
        .attach_spore = attach_spore,
    };
}

fn attachPreloadedRootfsStorage(
    allocator: std.mem.Allocator,
    spore_dir: []const u8,
    expected_digest: []const u8,
    preload_result: rootfs_cas.PreloadResult,
) !void {
    var parsed = try spore.loadManifest(allocator, spore_dir);
    defer parsed.deinit();
    var manifest = parsed.value;
    var rootfs = manifest.rootfs orelse return error.BadManifest;
    const previous_rootfs_digest = rootfs.artifact.digest;
    if (!std.mem.eql(u8, preload_result.rootfs_digest, expected_digest)) return error.BadManifest;
    if (rootfs.artifact.size != preload_result.rootfs_size) return error.BadManifest;

    const storage = rootfs_cas.storageDescriptor(rootfs.device, preload_result);
    const rootfs_matches_source = std.mem.eql(u8, rootfs.artifact.digest, expected_digest);
    const rootfs_matches_existing_index = if (rootfs.storage) |existing|
        std.mem.eql(u8, rootfs.artifact.digest, existing.index_digest)
    else
        false;
    if (!rootfs_matches_source and !rootfs_matches_existing_index) return error.BadManifest;
    if (rootfs.storage) |existing| {
        if (!spore.rootfsStorageEql(existing, storage)) return error.BadManifest;
    }
    rootfs.artifact.digest = storage.index_digest;
    rootfs.storage = storage;
    manifest.rootfs = rootfs;

    if (manifest.disk) |disk_value| {
        var disk = disk_value;
        if (!std.mem.eql(u8, disk.base, previous_rootfs_digest) and
            !std.mem.eql(u8, disk.base, storage.base_identity)) return error.BadManifest;
        disk.base = storage.base_identity;
        manifest.disk = disk;
    }

    try spore.validateManifest(manifest);
    try spore.saveManifest(allocator, spore_dir, manifest);
}

pub fn parseBuildOptions(allocator: std.mem.Allocator, args: []const []const u8, stdout: *Io.Writer) !ParsedBuildOptions {
    if (args.len == 0) {
        try stdout.writeAll(usage);
        try stdout.flush();
        std.process.exit(2);
    }

    var image_ref: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var metadata: ?[]const u8 = null;
    var platform: Platform = .{};

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

    const out = output orelse return error.MissingOutputPath;
    const meta = metadata orelse try std.fmt.allocPrint(allocator, "{s}.json", .{out});
    if (try sameResolvedPath(allocator, out, meta)) return error.RootFSMetadataPathMatchesOutput;
    return .{
        .ref = image_ref orelse return error.MissingImageReference,
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
pub const ImageRef = oci.ImageRef;
const ImageTag = oci.ImageTag;
const ImageManifest = oci.ImageManifest;
pub const ImageConfig = image_mod.Config;

pub const BuildResult = struct {
    schema: []const u8 = "spore.rootfs.build.result.v1",
    schema_version: u32 = 1,
    rootfs_storage: spore.RootfsStorage,
};

const MaterializeResult = struct {
    rootfs_storage: spore.RootfsStorage,
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
            "spore rootfs profile: phase={s} ms={d} chunks={d} zero_chunks={d} nonzero_chunks={d} objects_written={d} object_bytes_written={d} index_bytes={d} source_verify_ms={d} chunk_scan_ms={d} object_check_ms={d} object_write_ms={d} index_build_ms={d} index_write_ms={d} sealed_chunks={d} seal_workers={d} seal_wall_ms={d} seal_worker_cpu_ms={d}\n",
            .{
                name,
                monotonicMs() -| start_ms,
                result.chunk_count,
                result.zero_chunks,
                result.nonzero_chunks,
                result.objects_written,
                result.object_bytes_written,
                result.index_bytes,
                result.source_verify_ms,
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
    const opts = BuildOptions{
        .ref = request.ref,
        .output = request.output,
        .metadata = request.metadata,
        .platform = request.platform,
        .metadata_rootfs_path = request.metadata_rootfs_path,
        .temp_dir_root = request.temp_dir_root,
    };
    return buildRootFS(init, allocator, opts);
}

pub fn importOciLayout(init: std.process.Init, allocator: std.mem.Allocator, request: ImportOciRequest) !ImportOciResult {
    _ = try parseLocalTagRef(request.ref);
    try ensureSupportedRootfsStoragePolicy(request.rootfs_storage);
    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    defer allocator.free(cache_root);
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
    const resolved_image_ref = try localResolvedImageRef(allocator, request.ref, source.manifest_digest);
    const resolved = ResolvedImage{
        .ref = resolved_image_ref,
        .manifest_digest = source.manifest_digest,
        .platform = request.platform,
    };
    const cache_key = try rootfsCacheKeyAlloc(allocator, resolved);
    const rootfs_path = try std.fmt.allocPrint(allocator, "{s}/{s}.ext4", .{ cache_root, cache_key });
    const metadata_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ cache_root, cache_key });
    if (try cachedImportedRootfsStorage(init, allocator, cache_root, resolved, rootfs_path, metadata_path, request.rootfs_storage)) |rootfs_storage| {
        const local_ref_path = try writeLocalRefCache(init.io, allocator, cache_root, request.ref, resolved);
        return .{
            .rootfs_path = rootfs_path,
            .metadata_path = metadata_path,
            .local_ref_path = local_ref_path,
            .resolved_image_ref = resolved_image_ref,
            .image_manifest_digest = source.manifest_digest,
            .rootfs_storage = rootfs_storage,
        };
    }
    const temp_rootfs_path = try std.fmt.allocPrint(allocator, "{s}/.{s}.{d}.{x}.ext4.tmp", .{ cache_root, cache_key, temp_id, temp_nonce });
    const temp_metadata_path = try std.fmt.allocPrint(allocator, "{s}/.{s}.{d}.{x}.json.tmp", .{ cache_root, cache_key, temp_id, temp_nonce });
    defer Io.Dir.cwd().deleteFile(init.io, temp_rootfs_path) catch {};
    defer Io.Dir.cwd().deleteFile(init.io, temp_metadata_path) catch {};

    const result = try buildRootFSFromLayout(init, allocator, .{
        .requested_ref = request.ref,
        .resolved_image_ref = resolved_image_ref,
        .manifest_digest = source.manifest_digest,
        .source = source,
        .output = temp_rootfs_path,
        .metadata = temp_metadata_path,
        .platform = request.platform,
        .metadata_rootfs_path = rootfs_path,
        .temp_dir_root = temp_dir_root,
        .publish = .{ .rootfs_path = rootfs_path, .metadata_path = metadata_path },
    });
    const local_ref_path = try writeLocalRefCache(init.io, allocator, cache_root, request.ref, resolved);

    return .{
        .rootfs_path = rootfs_path,
        .metadata_path = metadata_path,
        .local_ref_path = local_ref_path,
        .resolved_image_ref = resolved_image_ref,
        .image_manifest_digest = source.manifest_digest,
        .rootfs_storage = result.rootfs_storage,
    };
}

pub fn importTar(init: std.process.Init, allocator: std.mem.Allocator, request: ImportTarRequest) !ImportTarResult {
    _ = try parseLocalTagRef(request.ref);
    try ensureSupportedRootfsStoragePolicy(request.rootfs_storage);
    const input_stat = try Io.Dir.cwd().statFile(init.io, request.input, .{ .follow_symlinks = false });
    if (input_stat.kind != .file) return error.UnsupportedRootFSTarInput;

    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    defer allocator.free(cache_root);
    try ensureDirPath(init.io, cache_root);
    const temp_dir_root = try std.fs.path.join(allocator, &.{ cache_root, "tmp" });
    try ensureDirPath(init.io, temp_dir_root);

    const input_digest = try sha256FileDigestAlloc(allocator, init.io, request.input);
    const resolved_image_ref = try localResolvedImageRef(allocator, request.ref, input_digest);
    const resolved = ResolvedImage{
        .ref = resolved_image_ref,
        .manifest_digest = input_digest,
        .platform = request.platform,
    };
    const cache_key = try rootfsCacheKeyAlloc(allocator, resolved);
    const rootfs_path = try std.fmt.allocPrint(allocator, "{s}/{s}.ext4", .{ cache_root, cache_key });
    const metadata_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ cache_root, cache_key });
    if (try cachedImportedRootfsStorage(init, allocator, cache_root, resolved, rootfs_path, metadata_path, request.rootfs_storage)) |rootfs_storage| {
        const local_ref_path = try writeLocalRefCache(init.io, allocator, cache_root, request.ref, resolved);
        return .{
            .rootfs_path = rootfs_path,
            .metadata_path = metadata_path,
            .local_ref_path = local_ref_path,
            .resolved_image_ref = resolved_image_ref,
            .image_manifest_digest = input_digest,
            .rootfs_storage = rootfs_storage,
        };
    }

    const temp_id = Io.Clock.real.now(init.io).nanoseconds;
    var temp_nonce_bytes: [8]u8 = undefined;
    init.io.random(&temp_nonce_bytes);
    const temp_nonce = std.mem.readInt(u64, &temp_nonce_bytes, .little);
    const temp_rootfs_path = try std.fmt.allocPrint(allocator, "{s}/.{s}.{d}.{x}.ext4.tmp", .{ cache_root, cache_key, temp_id, temp_nonce });
    const temp_metadata_path = try std.fmt.allocPrint(allocator, "{s}/.{s}.{d}.{x}.json.tmp", .{ cache_root, cache_key, temp_id, temp_nonce });
    defer Io.Dir.cwd().deleteFile(init.io, temp_rootfs_path) catch {};
    defer Io.Dir.cwd().deleteFile(init.io, temp_metadata_path) catch {};

    const result = try buildRootFSFromTar(init, allocator, .{
        .requested_ref = request.ref,
        .resolved_image_ref = resolved_image_ref,
        .manifest_digest = input_digest,
        .input = request.input,
        .output = temp_rootfs_path,
        .metadata = temp_metadata_path,
        .platform = request.platform,
        .metadata_rootfs_path = rootfs_path,
        .temp_dir_root = temp_dir_root,
        .publish = .{ .rootfs_path = rootfs_path, .metadata_path = metadata_path },
    });
    const local_ref_path = try writeLocalRefCache(init.io, allocator, cache_root, request.ref, resolved);

    return .{
        .rootfs_path = rootfs_path,
        .metadata_path = metadata_path,
        .local_ref_path = local_ref_path,
        .resolved_image_ref = resolved_image_ref,
        .image_manifest_digest = input_digest,
        .rootfs_storage = result.rootfs_storage,
    };
}

pub fn publishIndexedImage(init: std.process.Init, allocator: std.mem.Allocator, request: PublishIndexedImageRequest) !PublishIndexedImageResult {
    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    defer allocator.free(cache_root);
    try ensureDirPath(init.io, cache_root);
    var cache_lock = try lockRootfsCacheExclusive(init.io, allocator, cache_root);
    defer cache_lock.deinit();
    return publishIndexedImageLocked(init.io, allocator, cache_root, &cache_lock, request);
}

/// Publish an indexed image in the caller's cache-lock epoch. This lets
/// run/build transactions protect newly sealed CAS objects from GC until the
/// local ref has been updated.
pub fn publishIndexedImageLocked(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    cache_lock: *const RootfsCacheLock,
    request: PublishIndexedImageRequest,
) !PublishIndexedImageResult {
    if (!try cache_lock.ensureHeldFor(allocator, cache_root)) return error.RootfsCacheLockNotHeld;
    _ = try parseLocalTagRef(request.ref);
    try spore.validateRootfsStorageDescriptor(request.rootfs_storage);
    try spore.validateRootfsDeviceShape(request.rootfs_storage.device);
    if (!std.mem.eql(u8, request.rootfs_storage.index_digest, request.rootfs_storage.base_identity)) return error.BadManifest;

    if (!try rootfs_cas.storageCompleteWithStampRepair(io, allocator, cache_root, request.rootfs_storage)) return error.RootFSDigestCacheMiss;

    const canonical_config_json = try image_mod.canonicalConfigJson(allocator, request.config);
    defer allocator.free(canonical_config_json);
    const config_digest = try image_mod.configDigestAlloc(allocator, canonical_config_json);
    defer allocator.free(config_digest);
    const image_digest = try image_mod.imageDigestAlloc(allocator, request.rootfs_storage.index_digest, canonical_config_json);
    errdefer allocator.free(image_digest);
    if (request.expected_image_digest) |expected| {
        if (!std.mem.eql(u8, image_digest, expected)) return error.ImageIdentityMismatch;
    }
    const resolved_image_ref = try localResolvedBlake3Ref(allocator, request.ref, image_digest);
    errdefer allocator.free(resolved_image_ref);
    const resolved = ResolvedImage{
        .ref = resolved_image_ref,
        .manifest_digest = image_digest,
        .platform = request.platform,
    };
    const metadata_path = try cachedImageRootfsMetadataPath(allocator, cache_root, resolved);
    errdefer allocator.free(metadata_path);
    const metadata = RootFSMetadata{
        .builder_version = builder_version,
        .ext4_writer = "built-index",
        .image_ref = request.ref,
        .resolved_image_ref = resolved_image_ref,
        .image_manifest_digest = image_digest,
        .platform = request.platform,
        .config_digest = config_digest,
        .config = request.config,
        .layers = &.{},
        .deterministic = false,
        .ext4_uuid = "",
        .ext4_hash_seed = "",
        .rootfs_path = "",
        .rootfs_size = request.rootfs_storage.logical_size,
        .rootfs_storage = request.rootfs_storage,
    };
    const metadata_json = try std.json.Stringify.valueAlloc(allocator, metadata, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
    defer allocator.free(metadata_json);
    try ext4.ensureParentDir(io, metadata_path);
    try writeFileAtomicPath(io, allocator, metadata_path, metadata_json);

    const result_storage = try cloneRootfsStorageDigestFields(allocator, request.rootfs_storage);
    errdefer deinitStorageDigestFields(allocator, result_storage);
    const local_ref_path = try writeLocalRefLocked(io, allocator, cache_root, cache_lock, request.ref, resolved);
    return .{
        .metadata_path = metadata_path,
        .local_ref_path = local_ref_path,
        .resolved_image_ref = resolved_image_ref,
        .image_manifest_digest = image_digest,
        .rootfs_storage = result_storage,
    };
}

pub fn resolveReference(init: std.process.Init, allocator: std.mem.Allocator, request: ResolveRequest) ![]const u8 {
    if (isLocalImageRef(request.ref)) {
        const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
        defer allocator.free(cache_root);
        const resolved = try resolveLocalCachedRef(init.io, allocator, cache_root, request.ref, request.platform);
        return resolved.ref;
    }
    return resolveTaggedImageRef(init, allocator, .{
        .ref = request.ref,
        .platform = request.platform,
    });
}

pub fn casPreload(init: std.process.Init, allocator: std.mem.Allocator, request: CasPreloadRequest) !CasPreloadResult {
    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    defer allocator.free(cache_root);
    const result = try rootfs_cas.preload(init.io, allocator, cache_root, request.digest, request.chunk_size);
    if (request.attach_spore) |spore_dir| {
        try attachPreloadedRootfsStorage(allocator, spore_dir, request.digest, result);
    }
    return result;
}

pub fn deinitBuildResult(allocator: std.mem.Allocator, result: BuildResult) void {
    deinitStorageDigestFields(allocator, result.rootfs_storage);
}

pub fn deinitImportOciResult(allocator: std.mem.Allocator, result: ImportOciResult) void {
    allocator.free(result.rootfs_path);
    allocator.free(result.metadata_path);
    allocator.free(result.local_ref_path);
    allocator.free(result.resolved_image_ref);
    allocator.free(result.image_manifest_digest);
    deinitStorageDigestFields(allocator, result.rootfs_storage);
}

pub const deinitImportTarResult = deinitImportOciResult;

pub fn deinitPublishIndexedImageResult(allocator: std.mem.Allocator, result: PublishIndexedImageResult) void {
    allocator.free(result.metadata_path);
    allocator.free(result.local_ref_path);
    allocator.free(result.resolved_image_ref);
    allocator.free(result.image_manifest_digest);
    deinitStorageDigestFields(allocator, result.rootfs_storage);
}

pub fn deinitCachedIndexedRootfs(allocator: std.mem.Allocator, result: CachedIndexedRootfs) void {
    allocator.free(result.metadata_path);
    allocator.free(result.artifact.digest);
    deinitStorageDigestFields(allocator, result.storage);
}

pub fn deinitResolvedReference(allocator: std.mem.Allocator, resolved_ref: []const u8) void {
    allocator.free(resolved_ref);
}

pub fn deinitCasPreloadResult(allocator: std.mem.Allocator, result: CasPreloadResult) void {
    allocator.free(result.index_path);
    allocator.free(result.index_digest);
    allocator.free(result.rootfs_digest);
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

test "publish indexed image result deinit frees every owned field" {
    const allocator = std.testing.allocator;
    const storage = try cloneRootfsStorageDigestFields(allocator, .{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = .{ .mmio_slot = 1 },
        .logical_size = 4096,
        .chunk_size = spore.disk_chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .index_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .base_identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .object_namespace = spore.rootfs_storage_object_namespace,
    });
    deinitPublishIndexedImageResult(allocator, .{
        .metadata_path = try allocator.dupe(u8, "metadata.json"),
        .local_ref_path = try allocator.dupe(u8, "refs/local/app"),
        .resolved_image_ref = try allocator.dupe(u8, "local/app@blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .image_manifest_digest = try allocator.dupe(u8, "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .rootfs_storage = storage,
    });
}

const LayoutBuildOptions = struct {
    requested_ref: []const u8,
    resolved_image_ref: []const u8,
    manifest_digest: []const u8,
    source: oci_layout.SelectedImage,
    output: []const u8,
    metadata: []const u8,
    platform: Platform = .{},
    metadata_rootfs_path: ?[]const u8 = null,
    temp_dir_root: []const u8,
    publish: ?CachePublish = null,
};

const TarBuildOptions = struct {
    requested_ref: []const u8,
    resolved_image_ref: []const u8,
    manifest_digest: []const u8,
    input: []const u8,
    output: []const u8,
    metadata: []const u8,
    platform: Platform = .{},
    metadata_rootfs_path: ?[]const u8 = null,
    temp_dir_root: []const u8,
    publish: ?CachePublish = null,
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
    platform: Platform = .{},
    config_digest: []const u8,
    config: ImageConfig,
    layers: []const MaterializeLayer,
    output: []const u8,
    metadata: []const u8,
    metadata_rootfs_path: ?[]const u8 = null,
    temp_dir: []const u8,
    profile: RootfsBuildProfile,
    publish: ?CachePublish = null,
};

fn buildRootFS(init: std.process.Init, allocator: std.mem.Allocator, opts: BuildOptions) !BuildResult {
    var client: std.http.Client = .{ .allocator = allocator, .io = init.io };
    defer client.deinit();
    var session = try registry.Session.init(&client, init.environ_map);

    const temp_dir_root = opts.temp_dir_root orelse ".zig-cache";
    try Io.Dir.cwd().createDirPath(init.io, temp_dir_root);
    const temp_id = Io.Clock.real.now(init.io).nanoseconds;
    var temp_nonce_bytes: [8]u8 = undefined;
    init.io.random(&temp_nonce_bytes);
    const temp_nonce = std.mem.readInt(u64, &temp_nonce_bytes, .little);
    const temp_dir = try std.fmt.allocPrint(allocator, "{s}/spore-rootfs-{d}-{x}", .{ temp_dir_root, temp_id, temp_nonce });
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
        .platform = opts.platform,
        .config_digest = manifest.config.digest,
        .config = config_parsed.value,
        .layers = layer_files,
        .output = opts.output,
        .metadata = opts.metadata,
        .metadata_rootfs_path = opts.metadata_rootfs_path,
        .temp_dir = temp_dir,
        .profile = profile,
        .publish = opts.publish,
    });
    const cleanup_start = profile.start();
    Io.Dir.cwd().deleteTree(init.io, temp_dir) catch {};
    profile.phase("temp_cleanup", cleanup_start);
    profile.finish();
    return .{
        .rootfs_storage = result.rootfs_storage,
    };
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
        .output = opts.output,
        .metadata = opts.metadata,
        .metadata_rootfs_path = opts.metadata_rootfs_path,
        .temp_dir = temp_dir,
        .profile = profile,
        .publish = opts.publish,
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
        .output = opts.output,
        .metadata = opts.metadata,
        .metadata_rootfs_path = opts.metadata_rootfs_path,
        .temp_dir = temp_dir,
        .profile = profile,
        .publish = opts.publish,
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
    var tree = try mergeLayers(init, allocator, opts, layer_meta);
    defer tree.deinit(allocator);

    // Fetching and merging touched only the private temp dir, which GC and
    // prune never read, so they run without the cache lock. Emit writes CAS
    // objects (or skips ones already present) that nothing roots until the
    // metadata below is published, so emit and publication share one lock
    // epoch: GC cannot collect storage the new metadata is about to root.
    if (comptime builtin.is_test) if (testing.publish_lock_barrier) |barrier| barrier.pause(init.io);
    var cache_lock = try lockRootfsCacheExclusive(init.io, allocator, cache_root);
    defer cache_lock.deinit();
    const preload_result = try emitMergedTree(init, allocator, opts, &tree, deterministic_ext4, cache_root, &cache_lock);
    const stat = try Io.Dir.cwd().statFile(init.io, opts.output, .{});

    const rootfs_storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload_result);
    if (trustedDigestHardlinkEligible(opts.publish != null, opts.output, cache_root)) {
        const cache_start = opts.profile.start();
        _ = try rootfs_cache.installTrustedMaterializationByHardlink(
            init.io,
            allocator,
            cache_root,
            opts.output,
            rootfs_storage.index_digest,
            stat.size,
        );
        opts.profile.phase("identity_cache_install", cache_start);
    }

    const metadata_start = opts.profile.start();
    try ext4.ensureParentDir(init.io, opts.metadata);
    try rejectMetadataOutputAlias(init.io, opts.output, opts.metadata);
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
        .rootfs_path = opts.metadata_rootfs_path orelse opts.output,
        .rootfs_size = stat.size,
        .rootfs_storage = rootfs_storage,
    };
    const metadata_json = try std.json.Stringify.valueAlloc(allocator, metadata, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
    try ext4.writeFileAtPath(init.io, opts.metadata, metadata_json);
    if (opts.publish) |publish| {
        try renameCachePath(init.io, opts.output, publish.rootfs_path);
        try renameCachePath(init.io, opts.metadata, publish.metadata_path);
    }
    opts.profile.phase("metadata_write", metadata_start);

    return .{ .rootfs_storage = rootfs_storage };
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
    const emit_result = try ext4_writer.emitFromMergedTree(allocator, init.io, tree, opts.output, .{
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

fn trustedDigestHardlinkEligible(cache_owned_output: bool, path: []const u8, cache_root: []const u8) bool {
    return cache_owned_output and cacheOwnedPath(path, cache_root);
}

fn cacheOwnedPath(path: []const u8, cache_root: []const u8) bool {
    if (!std.mem.startsWith(u8, path, cache_root)) return false;
    if (path.len == cache_root.len) return true;
    if (cache_root.len > 0 and cache_root[cache_root.len - 1] == std.fs.path.sep) return true;
    return path[cache_root.len] == std.fs.path.sep;
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

fn parseLocalDigestRef(raw: []const u8) !ImageRef {
    const image_ref = try ImageRef.parse(raw);
    if (!std.mem.eql(u8, image_ref.registry, "local")) return error.LocalRefMustUseLocalRegistry;
    return image_ref;
}

fn localResolvedImageRef(allocator: std.mem.Allocator, raw_ref: []const u8, manifest_digest: []const u8) ![]u8 {
    if (!oci.isSha256Digest(manifest_digest)) return error.UnsupportedDigest;
    const tag = try parseLocalTagRef(raw_ref);
    return std.fmt.allocPrint(allocator, "local/{s}@{s}", .{ tag.repository, manifest_digest });
}

fn localResolvedBlake3Ref(allocator: std.mem.Allocator, raw_ref: []const u8, digest: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, digest, spore.rootfs_digest_prefix)) return error.UnsupportedDigest;
    const tag = try parseLocalTagRef(raw_ref);
    return std.fmt.allocPrint(allocator, "local/{s}@{s}", .{ tag.repository, digest });
}

fn localResolvedRefMatchesDigest(allocator: std.mem.Allocator, raw_ref: []const u8, resolved_ref: []const u8, digest: []const u8) !bool {
    if (parseLocalDigestRef(resolved_ref)) |image_ref| {
        return std.mem.eql(u8, image_ref.digest, digest);
    } else |err| switch (err) {
        error.UnsupportedDigest => {},
        else => |e| return e,
    }
    if (!std.mem.startsWith(u8, digest, spore.rootfs_digest_prefix)) return false;
    const tag = try parseLocalTagRef(raw_ref);
    const expected = try std.fmt.allocPrint(allocator, "local/{s}@{s}", .{ tag.repository, digest });
    defer allocator.free(expected);
    return std.mem.eql(u8, resolved_ref, expected);
}

fn localResolvedBlake3DigestRef(allocator: std.mem.Allocator, raw_ref: []const u8) !?ResolvedImage {
    const at = std.mem.lastIndexOfScalar(u8, raw_ref, '@') orelse return null;
    const name = raw_ref[0..at];
    const digest = raw_ref[at + 1 ..];
    if (!std.mem.startsWith(u8, digest, spore.rootfs_digest_prefix)) return error.UnsupportedDigest;
    try spore.validateRootfsDigest(digest);

    const tag_probe = try std.fmt.allocPrint(allocator, "{s}:digest", .{name});
    defer allocator.free(tag_probe);
    const tag = try parseLocalTagRef(tag_probe);
    const resolved_ref = try std.fmt.allocPrint(allocator, "local/{s}@{s}", .{ tag.repository, digest });
    return .{
        .ref = resolved_ref,
        .manifest_digest = digest,
        .platform = .{},
    };
}

pub fn resolveLocalCachedRef(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    raw_ref: []const u8,
    platform: Platform,
) !ResolvedImage {
    if (ImageRef.parse(raw_ref)) |image_ref| {
        if (!std.mem.eql(u8, image_ref.registry, "local")) return error.LocalRefMustUseLocalRegistry;
        return .{
            .ref = try digestImageRef(allocator, image_ref, image_ref.digest),
            .manifest_digest = image_ref.digest,
            .platform = platform,
        };
    } else |err| switch (err) {
        error.ImageRefMustBeDigestPinned => {},
        error.UnsupportedDigest => {
            if (try localResolvedBlake3DigestRef(allocator, raw_ref)) |resolved| {
                return .{ .ref = resolved.ref, .manifest_digest = resolved.manifest_digest, .platform = platform };
            }
            return err;
        },
        else => |e| return e,
    }

    _ = try parseLocalTagRef(raw_ref);
    const path = try localRefCachePath(allocator, cache_root, raw_ref, platform);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    var parsed = try std.json.parseFromSlice(LocalRefMetadata, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const value = parsed.value;

    if (!std.mem.eql(u8, value.kind, local_ref_cache_kind)) return error.LocalRefCacheMismatch;
    if (!std.mem.eql(u8, value.ref, raw_ref)) return error.LocalRefCacheMismatch;
    if (!std.mem.eql(u8, value.builder_version, builder_version)) return error.LocalRefCacheMismatch;
    if (!std.mem.eql(u8, value.platform.os, platform.os) or value.platform.arch != platform.arch) {
        return error.UnsupportedPlatform;
    }
    if (!try localResolvedRefMatchesDigest(allocator, raw_ref, value.resolved_image_ref, value.image_manifest_digest)) return error.LocalRefCacheMismatch;

    return .{
        .ref = try allocator.dupe(u8, value.resolved_image_ref),
        .manifest_digest = try allocator.dupe(u8, value.image_manifest_digest),
        .platform = platform,
    };
}

pub fn writeLocalRefCache(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    raw_ref: []const u8,
    resolved: ResolvedImage,
) ![]const u8 {
    _ = try parseLocalTagRef(raw_ref);
    const resolved_ref = try parseLocalDigestRef(resolved.ref);
    if (!std.mem.eql(u8, resolved_ref.digest, resolved.manifest_digest)) return error.LocalRefCacheMismatch;

    return writeLocalRefCacheAnyDigest(io, allocator, cache_root, raw_ref, resolved);
}

fn writeLocalRefCacheAnyDigest(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    raw_ref: []const u8,
    resolved: ResolvedImage,
) ![]const u8 {
    var cache_lock = try lockRootfsCacheExclusive(io, allocator, cache_root);
    defer cache_lock.deinit();
    return writeLocalRefLocked(io, allocator, cache_root, &cache_lock, raw_ref, resolved);
}

fn writeLocalRefLocked(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    cache_lock: *const RootfsCacheLock,
    raw_ref: []const u8,
    resolved: ResolvedImage,
) ![]const u8 {
    if (!try cache_lock.ensureHeldFor(allocator, cache_root)) return error.RootfsCacheLockNotHeld;
    _ = try parseLocalTagRef(raw_ref);
    if (!try localResolvedRefMatchesDigest(allocator, raw_ref, resolved.ref, resolved.manifest_digest)) return error.LocalRefCacheMismatch;

    const path = try localRefCachePath(allocator, cache_root, raw_ref, resolved.platform);
    errdefer allocator.free(path);
    try ext4.ensureParentDir(io, path);

    var nonce_bytes: [8]u8 = undefined;
    io.random(&nonce_bytes);
    const nonce = std.mem.readInt(u64, &nonce_bytes, .little);
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.{x}.tmp", .{ path, nonce });
    defer allocator.free(temp_path);
    defer Io.Dir.cwd().deleteFile(io, temp_path) catch {};
    const metadata = LocalRefMetadata{
        .ref = raw_ref,
        .resolved_image_ref = resolved.ref,
        .image_manifest_digest = resolved.manifest_digest,
        .platform = resolved.platform,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, metadata, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try ext4.writeFileAtPath(io, temp_path, json);
    try renameCachePath(io, temp_path, path);
    return path;
}

pub fn localRefCachePath(
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    raw_ref: []const u8,
    platform: Platform,
) ![]u8 {
    _ = try parseLocalTagRef(raw_ref);
    var h = Sha256.init(.{});
    h.update(local_ref_cache_kind);
    h.update("\n");
    h.update(builder_version);
    h.update("\n");
    h.update(platform.os);
    h.update("/");
    h.update(platform.arch.name());
    h.update("\n");
    h.update(raw_ref);
    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{&hex});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ cache_root, "refs", "local", file_name });
}

/// Rejects anything that is not a well-formed local ref record.
pub fn validateLocalRefRecord(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var parsed = try std.json.parseFromSlice(LocalRefMetadata, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const value = parsed.value;
    if (!std.mem.eql(u8, value.kind, local_ref_cache_kind)) return error.LocalRefCacheMismatch;
    if (!try localResolvedRefMatchesDigest(allocator, value.ref, value.resolved_image_ref, value.image_manifest_digest)) return error.LocalRefCacheMismatch;
}

pub fn rootfsCacheKeyAlloc(allocator: std.mem.Allocator, resolved: ResolvedImage) ![]u8 {
    var h = Sha256.init(.{});
    h.update(builder_version);
    h.update("\n");
    h.update(resolved.platform.os);
    h.update("/");
    h.update(resolved.platform.arch.name());
    h.update("\n");
    h.update(resolved.manifest_digest);
    h.update("\n");
    h.update(resolved.ref);
    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

pub fn cachedImageRootfsMetadataPath(
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    resolved: ResolvedImage,
) ![]const u8 {
    const cache_key = try rootfsCacheKeyAlloc(allocator, resolved);
    return std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ cache_root, cache_key });
}

pub fn cachedImageRootfsPath(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    resolved: ResolvedImage,
) !?[]const u8 {
    const cache_key = try rootfsCacheKeyAlloc(allocator, resolved);
    const rootfs_path = try std.fmt.allocPrint(allocator, "{s}/{s}.ext4", .{ cache_root, cache_key });
    const metadata_path = try cachedImageRootfsMetadataPath(allocator, cache_root, resolved);
    if (try cachedRootfsMetadataMatches(io, allocator, metadata_path, resolved) and try readablePath(io, rootfs_path)) {
        const artifact = (try cachedImageRootfsArtifact(io, allocator, metadata_path, rootfs_path)) orelse return null;
        defer allocator.free(artifact.digest);
        const storage = (try readCachedRootfsStorage(io, allocator, metadata_path, artifact)) orelse return null;
        defer deinitStorageDigestFields(allocator, storage);
        if (!try rootfs_cas.storageCompleteWithStampRepair(io, allocator, cache_root, storage)) return null;
        std.log.debug("spore rootfs: using cached rootfs {s} for {s}", .{ rootfs_path, resolved.ref });
        return rootfs_path;
    }
    return null;
}

pub fn cachedImageIndexedRootfs(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    resolved: ResolvedImage,
) !?CachedIndexedRootfs {
    const metadata_path = try cachedImageRootfsMetadataPath(allocator, cache_root, resolved);
    errdefer allocator.free(metadata_path);
    if (!try cachedRootfsIdentityMatches(io, allocator, metadata_path, resolved)) {
        allocator.free(metadata_path);
        return null;
    }
    const storage = (try readCachedRootfsStorageDescriptor(io, allocator, metadata_path)) orelse {
        allocator.free(metadata_path);
        return null;
    };
    errdefer deinitStorageDigestFields(allocator, storage);
    if (!try rootfs_cas.storageCompleteWithStampRepair(io, allocator, cache_root, storage)) {
        allocator.free(metadata_path);
        deinitStorageDigestFields(allocator, storage);
        return null;
    }
    const artifact_digest = try allocator.dupe(u8, storage.index_digest);
    errdefer allocator.free(artifact_digest);
    const artifact = spore.RootfsArtifactRef{
        .digest = artifact_digest,
        .size = storage.logical_size,
        .format = spore.rootfs_artifact_format_ext4,
    };
    return .{
        .metadata_path = metadata_path,
        .artifact = artifact,
        .storage = storage,
    };
}

pub fn cachedImageRootfsArtifact(
    io: Io,
    allocator: std.mem.Allocator,
    metadata_path: []const u8,
    rootfs_path: []const u8,
) !?spore.RootfsArtifactRef {
    const metadata = Io.Dir.cwd().readFileAlloc(io, metadata_path, allocator, .limited(max_rootfs_metadata_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return null,
        else => |e| return e,
    };
    defer allocator.free(metadata);

    var parsed = std.json.parseFromSlice(CachedRootfsArtifactMetadata, allocator, metadata, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    const value = parsed.value;
    if (!std.mem.eql(u8, value.rootfs_path, rootfs_path)) return null;

    const stat = Io.Dir.cwd().statFile(io, rootfs_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => {
            return null;
        },
        else => |e| return e,
    };
    if (stat.kind != .file or stat.size != value.rootfs_size) {
        return null;
    }
    const storage = value.rootfs_storage orelse return null;
    spore.validateRootfsStorageDescriptor(storage) catch return null;
    if (storage.logical_size != value.rootfs_size) return null;
    if (!std.mem.eql(u8, storage.index_digest, storage.base_identity)) return null;
    const digest = try allocator.dupe(u8, storage.index_digest);

    return .{
        .digest = digest,
        .size = value.rootfs_size,
        .format = spore.rootfs_artifact_format_ext4,
    };
}

fn cachedImportedRootfsStorage(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    resolved: ResolvedImage,
    rootfs_path: []const u8,
    metadata_path: []const u8,
    storage_policy: RootfsStoragePolicy,
) !?spore.RootfsStorage {
    try ensureSupportedRootfsStoragePolicy(storage_policy);
    if (!try cachedRootfsMetadataMatches(init.io, allocator, metadata_path, resolved)) return null;
    const artifact = (try cachedImageRootfsArtifact(init.io, allocator, metadata_path, rootfs_path)) orelse return null;
    defer allocator.free(artifact.digest);
    if (!try readablePath(init.io, rootfs_path)) return null;

    const storage = (try readCachedRootfsStorage(init.io, allocator, metadata_path, artifact)) orelse return null;
    errdefer deinitStorageDigestFields(allocator, storage);
    if (!try rootfs_cas.storageComplete(init.io, allocator, cache_root, storage)) {
        deinitStorageDigestFields(allocator, storage);
        return null;
    }
    _ = try rootfs_cache.installTrustedMaterializationByHardlink(
        init.io,
        allocator,
        cache_root,
        rootfs_path,
        storage.index_digest,
        storage.logical_size,
    );

    std.log.debug("spore rootfs: using cached imported rootfs {s} for {s}", .{ rootfs_path, resolved.ref });
    return storage;
}

fn rootfsArtifactRefMatches(a: spore.RootfsArtifactRef, b: spore.RootfsArtifactRef) bool {
    return a.size == b.size and
        std.mem.eql(u8, a.digest, b.digest) and
        std.mem.eql(u8, a.format, b.format);
}

pub const ImageRefCacheHit = struct {
    path: []const u8,
    resolved: ResolvedImage,
};

const ImageRefCacheRecord = struct {
    version: u32,
    requested_ref: []const u8,
    platform: []const u8,
    builder_version: []const u8,
    resolved_image_ref: []const u8,
    image_manifest_digest: []const u8,
    rootfs_cache_key: []const u8,
    resolved_at_unix: i64,
};

pub fn cachedImageRefRootfsPath(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    requested_ref: []const u8,
    platform: Platform,
) !?ImageRefCacheHit {
    const record_path = try imageRefCacheRecordPath(allocator, cache_root, requested_ref, platform);
    if (!try rootfs_cache.regularFileNoSymlink(io, record_path)) return null;

    const data = Io.Dir.cwd().readFileAlloc(io, record_path, allocator, .limited(max_image_ref_cache_record_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return null,
        else => |e| return e,
    };
    defer allocator.free(data);

    var parsed = std.json.parseFromSlice(ImageRefCacheRecord, allocator, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    const record = parsed.value;
    const platform_text = try platformTextAlloc(allocator, platform);
    if (record.version != image_ref_cache_record_version) return null;
    if (!std.mem.eql(u8, record.requested_ref, requested_ref)) return null;
    if (!std.mem.eql(u8, record.platform, platform_text)) return null;
    if (!std.mem.eql(u8, record.builder_version, builder_version)) return null;

    const resolved = (digestPinnedImageIdentity(allocator, record.resolved_image_ref, platform) catch return null) orelse return null;
    if (!std.mem.eql(u8, resolved.manifest_digest, record.image_manifest_digest)) return null;
    const expected_cache_key = try rootfsCacheKeyAlloc(allocator, resolved);
    if (!std.mem.eql(u8, record.rootfs_cache_key, expected_cache_key)) return null;

    const rootfs_path = (try cachedImageRootfsPath(io, allocator, cache_root, resolved)) orelse return null;
    std.log.debug("spore rootfs: using cached image ref {s} -> {s}", .{ requested_ref, resolved.ref });
    return .{ .path = rootfs_path, .resolved = resolved };
}

pub fn writeImageRefCacheRecord(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    requested_ref: []const u8,
    resolved: ResolvedImage,
) !void {
    const refs_dir = try std.fs.path.join(allocator, &.{ cache_root, "refs" });
    try ensureDirPath(io, refs_dir);
    var cache_lock = try lockRootfsCacheExclusive(io, allocator, cache_root);
    defer cache_lock.deinit();

    const rootfs_cache_key = try rootfsCacheKeyAlloc(allocator, resolved);
    const platform = try platformTextAlloc(allocator, resolved.platform);
    const record_path = try imageRefCacheRecordPath(allocator, cache_root, requested_ref, resolved.platform);
    const now = Io.Clock.real.now(io).nanoseconds;
    const record = ImageRefCacheRecord{
        .version = image_ref_cache_record_version,
        .requested_ref = requested_ref,
        .platform = platform,
        .builder_version = builder_version,
        .resolved_image_ref = resolved.ref,
        .image_manifest_digest = resolved.manifest_digest,
        .rootfs_cache_key = rootfs_cache_key,
        .resolved_at_unix = @intCast(@divFloor(now, std.time.ns_per_s)),
    };
    const json = try std.json.Stringify.valueAlloc(allocator, record, .{ .whitespace = .indent_2 });
    const temp_id = now;
    var temp_nonce_bytes: [8]u8 = undefined;
    io.random(&temp_nonce_bytes);
    const temp_nonce = std.mem.readInt(u64, &temp_nonce_bytes, .little);
    const temp_path = try std.fmt.allocPrint(allocator, "{s}/.{d}.{x}.json.tmp", .{ refs_dir, temp_id, temp_nonce });
    defer Io.Dir.cwd().deleteFile(io, temp_path) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = temp_path, .data = json });
    try renameCachePath(io, temp_path, record_path);
    std.log.debug("spore rootfs: cached image ref {s} -> {s}", .{ requested_ref, resolved.ref });
}

fn imageRefCacheRecordPath(
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    requested_ref: []const u8,
    platform: Platform,
) ![]const u8 {
    const key = try imageRefCacheKeyAlloc(allocator, requested_ref, platform);
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{key});
    return std.fs.path.join(allocator, &.{ cache_root, "refs", filename });
}

fn imageRefCacheKeyAlloc(
    allocator: std.mem.Allocator,
    requested_ref: []const u8,
    platform: Platform,
) ![]u8 {
    var h = Sha256.init(.{});
    h.update("sporevm-rootfs-ref-v1\n");
    h.update(builder_version);
    h.update("\n");
    h.update(platform.os);
    h.update("/");
    h.update(platform.arch.name());
    h.update("\n");
    h.update(requested_ref);
    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

fn platformTextAlloc(allocator: std.mem.Allocator, platform: Platform) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ platform.os, platform.arch.name() });
}

pub fn buildCachedImageRootfs(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    resolved: ResolvedImage,
) ![]const u8 {
    const cache_key = try rootfsCacheKeyAlloc(allocator, resolved);
    const rootfs_path = try std.fmt.allocPrint(allocator, "{s}/{s}.ext4", .{ cache_root, cache_key });
    const metadata_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ cache_root, cache_key });
    const temp_dir_root = try std.fmt.allocPrint(allocator, "{s}/tmp", .{cache_root});
    try ensureDirPath(init.io, temp_dir_root);
    const temp_id = Io.Clock.real.now(init.io).nanoseconds;
    var temp_nonce_bytes: [8]u8 = undefined;
    init.io.random(&temp_nonce_bytes);
    const temp_nonce = std.mem.readInt(u64, &temp_nonce_bytes, .little);
    const temp_rootfs_path = try std.fmt.allocPrint(allocator, "{s}/.{s}.{d}.{x}.ext4.tmp", .{ cache_root, cache_key, temp_id, temp_nonce });
    const temp_metadata_path = try std.fmt.allocPrint(allocator, "{s}/.{s}.{d}.{x}.json.tmp", .{ cache_root, cache_key, temp_id, temp_nonce });
    defer Io.Dir.cwd().deleteFile(init.io, temp_rootfs_path) catch {};
    defer Io.Dir.cwd().deleteFile(init.io, temp_metadata_path) catch {};

    std.log.debug("spore rootfs: building cached rootfs for {s}", .{resolved.ref});
    _ = try buildRootFS(init, allocator, .{
        .ref = resolved.ref,
        .output = temp_rootfs_path,
        .metadata = temp_metadata_path,
        .platform = resolved.platform,
        .metadata_rootfs_path = rootfs_path,
        .temp_dir_root = temp_dir_root,
        .publish = .{ .rootfs_path = rootfs_path, .metadata_path = metadata_path },
    });
    std.log.debug("spore rootfs: cached rootfs {s}", .{rootfs_path});
    return rootfs_path;
}

const CachedRootfsStorageMetadata = struct {
    rootfs_size: u64,
    rootfs_storage: ?spore.RootfsStorage = null,
};

const CachedRootfsArtifactMetadata = struct {
    rootfs_path: []const u8,
    rootfs_size: u64,
    rootfs_storage: ?spore.RootfsStorage = null,
};

fn readCachedRootfsStorageDescriptor(
    io: Io,
    allocator: std.mem.Allocator,
    metadata_path: []const u8,
) !?spore.RootfsStorage {
    const metadata = Io.Dir.cwd().readFileAlloc(io, metadata_path, allocator, .limited(max_rootfs_metadata_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return null,
        else => |e| return e,
    };
    defer allocator.free(metadata);
    var parsed = std.json.parseFromSlice(CachedRootfsStorageMetadata, allocator, metadata, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    const storage = parsed.value.rootfs_storage orelse return null;
    spore.validateRootfsStorageDescriptor(storage) catch return null;
    if (storage.logical_size != parsed.value.rootfs_size) return null;
    if (!std.mem.eql(u8, storage.index_digest, storage.base_identity)) return null;
    return try cloneRootfsStorageDigestFields(allocator, storage);
}

fn rootfsArtifactDigestSuffix(artifact_digest: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, artifact_digest, spore.rootfs_digest_prefix)) return null;
    return artifact_digest[spore.rootfs_digest_prefix.len..];
}

pub fn readCachedRootfsStorage(
    io: Io,
    allocator: std.mem.Allocator,
    metadata_path: []const u8,
    artifact: spore.RootfsArtifactRef,
) !?spore.RootfsStorage {
    const metadata = Io.Dir.cwd().readFileAlloc(io, metadata_path, allocator, .limited(max_rootfs_metadata_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return null,
        else => |e| return e,
    };
    defer allocator.free(metadata);
    var parsed = std.json.parseFromSlice(CachedRootfsStorageMetadata, allocator, metadata, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    if (parsed.value.rootfs_size != artifact.size) return null;
    const storage = parsed.value.rootfs_storage orelse return null;
    spore.validateRootfsStorageDescriptor(storage) catch return null;
    if (storage.logical_size != artifact.size) return null;
    if (!std.mem.eql(u8, storage.index_digest, artifact.digest)) return null;
    return try cloneRootfsStorageDigestFields(allocator, storage);
}

fn writeFileAtomicPath(io: Io, allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    var temp_nonce_bytes: [8]u8 = undefined;
    io.random(&temp_nonce_bytes);
    const temp_nonce = std.mem.readInt(u64, &temp_nonce_bytes, .little);
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.{x}.tmp", .{ path, temp_nonce });
    defer Io.Dir.cwd().deleteFile(io, temp_path) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = temp_path, .data = data });
    try renameCachePath(io, temp_path, path);
}

fn cachedRootfsMetadataMatches(
    io: Io,
    allocator: std.mem.Allocator,
    metadata_path: []const u8,
    resolved: ResolvedImage,
) !bool {
    return (try cachedRootfsIdentityMatches(io, allocator, metadata_path, resolved)) and
        try cachedRootfsExt4WriterMatches(io, allocator, metadata_path);
}

fn cachedRootfsIdentityMatches(
    io: Io,
    allocator: std.mem.Allocator,
    metadata_path: []const u8,
    resolved: ResolvedImage,
) !bool {
    const metadata = Io.Dir.cwd().readFileAlloc(io, metadata_path, allocator, .limited(max_rootfs_metadata_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return false,
        else => |e| return e,
    };
    defer allocator.free(metadata);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, metadata, .{}) catch return false;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    if (!jsonStringEquals(object.get("builder_version"), builder_version)) return false;
    if (!jsonStringEquals(object.get("resolved_image_ref"), resolved.ref)) return false;
    if (!jsonStringEquals(object.get("image_manifest_digest"), resolved.manifest_digest)) return false;
    const platform_value = object.get("platform") orelse return false;
    const platform_object = switch (platform_value) {
        .object => |platform_object| platform_object,
        else => return false,
    };
    return jsonStringEquals(platform_object.get("os"), resolved.platform.os) and
        jsonStringEquals(platform_object.get("arch"), resolved.platform.arch.name());
}

fn cachedRootfsExt4WriterMatches(
    io: Io,
    allocator: std.mem.Allocator,
    metadata_path: []const u8,
) !bool {
    const metadata = Io.Dir.cwd().readFileAlloc(io, metadata_path, allocator, .limited(max_rootfs_metadata_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return false,
        else => |e| return e,
    };
    defer allocator.free(metadata);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, metadata, .{}) catch return false;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    return jsonStringEquals(object.get("ext4_writer"), ext4_writer_name);
}

fn jsonStringEquals(value: ?std.json.Value, expected: []const u8) bool {
    const actual = switch (value orelse return false) {
        .string => |string| string,
        else => return false,
    };
    return std.mem.eql(u8, actual, expected);
}

fn readablePath(io: Io, path: []const u8) !bool {
    if (Io.Dir.path.isAbsolute(path)) {
        Io.Dir.accessAbsolute(io, path, .{ .read = true }) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return false,
            else => |e| return e,
        };
        return true;
    }
    Io.Dir.cwd().access(io, path, .{ .read = true }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return false,
        else => |e| return e,
    };
    return true;
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

fn renameCachePath(io: Io, old_path: []const u8, new_path: []const u8) !void {
    const old_absolute = Io.Dir.path.isAbsolute(old_path);
    const new_absolute = Io.Dir.path.isAbsolute(new_path);
    if (old_absolute != new_absolute) return error.BadPathName;
    if (old_absolute) {
        try Io.Dir.renameAbsolute(old_path, new_path, io);
    } else {
        try Io.Dir.rename(Io.Dir.cwd(), old_path, Io.Dir.cwd(), new_path, io);
    }
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
    var stdout: Io.Writer.Allocating = .init(allocator);
    defer stdout.deinit();

    try std.testing.expectError(
        error.RootFSMetadataPathMatchesOutput,
        parseBuildOptions(allocator, &.{
            "registry.example/repo@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "--output",
            "rootfs.ext4",
            "--metadata",
            "rootfs.ext4",
        }, &stdout.writer),
    );
    try std.testing.expectError(
        error.RootFSMetadataPathMatchesOutput,
        parseBuildOptions(allocator, &.{
            "registry.example/repo@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "--output",
            "rootfs.ext4",
            "--metadata",
            "./rootfs.ext4",
        }, &stdout.writer),
    );
}

test "build options accept tag image refs" {
    const allocator = std.testing.allocator;
    var stdout: Io.Writer.Allocating = .init(allocator);
    defer stdout.deinit();

    const parsed = try parseBuildOptions(allocator, &.{
        "registry.example/repo:latest",
        "--output",
        "rootfs.ext4",
    }, &stdout.writer);
    defer allocator.free(parsed.metadata);
    try std.testing.expectEqualStrings("registry.example/repo:latest", parsed.ref);
    try std.testing.expectEqualStrings("rootfs.ext4.json", parsed.metadata);
}

test "trusted digest hardlink requires internal cache output ownership" {
    try std.testing.expect(!trustedDigestHardlinkEligible(false, "/tmp/sporevm-rootfs/user.ext4", "/tmp/sporevm-rootfs"));
    try std.testing.expect(trustedDigestHardlinkEligible(true, "/tmp/sporevm-rootfs/.image.ext4.tmp", "/tmp/sporevm-rootfs"));
    try std.testing.expect(!trustedDigestHardlinkEligible(true, "/tmp/sporevm-rootfs-sibling/.image.ext4.tmp", "/tmp/sporevm-rootfs"));
}

test "resolve options parse image tag and platform" {
    const allocator = std.testing.allocator;
    var stdout: Io.Writer.Allocating = .init(allocator);
    defer stdout.deinit();

    const parsed = try parseResolveOptions(&.{
        "registry.example/repo:latest",
        "--platform",
        "linux/arm64",
    }, &stdout.writer);
    try std.testing.expectEqualStrings("registry.example/repo:latest", parsed.ref);
    try std.testing.expectEqualStrings("linux", parsed.platform.os);
    try std.testing.expectEqual(.arm64, parsed.platform.arch);
    try std.testing.expectError(
        error.TooManyRootFSArguments,
        parseResolveOptions(&.{ "registry.example/repo:latest", "extra" }, &stdout.writer),
    );
}

test "import-oci options require a local mutable ref" {
    const allocator = std.testing.allocator;
    var stdout: Io.Writer.Allocating = .init(allocator);
    defer stdout.deinit();

    const parsed = try parseImportOciOptions(&.{
        "layout.oci",
        "--ref",
        "local/sporevm-app:dev",
        "--platform",
        "linux/arm64",
        "--rootfs-storage=chunked",
    }, &stdout.writer);
    try std.testing.expectEqualStrings("layout.oci", parsed.input);
    try std.testing.expectEqualStrings("local/sporevm-app:dev", parsed.ref);
    try std.testing.expectEqual(.chunked, parsed.rootfs_storage);

    try std.testing.expectError(
        error.LocalRefMustUseLocalRegistry,
        parseImportOciOptions(&.{ "layout.oci", "--ref", "ghcr.io/org/image:dev" }, &stdout.writer),
    );
    try std.testing.expectError(
        error.BadImageReference,
        parseImportOciOptions(
            &.{ "layout.oci", "--ref", "local/sporevm-app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
            &stdout.writer,
        ),
    );
    try std.testing.expectError(
        error.UnsupportedRootFSStoragePolicy,
        parseImportOciOptions(
            &.{ "layout.oci", "--ref", "local/sporevm-app:dev", "--rootfs-storage=flat" },
            &stdout.writer,
        ),
    );
    try std.testing.expectError(
        error.UnsupportedRootFSStoragePolicy,
        parseImportOciOptions(
            &.{ "layout.oci", "--ref", "local/sporevm-app:dev", "--rootfs-storage", "native-oci" },
            &stdout.writer,
        ),
    );
}

test "import-tar options require a local mutable ref" {
    const allocator = std.testing.allocator;
    var stdout: Io.Writer.Allocating = .init(allocator);
    defer stdout.deinit();

    const parsed = try parseImportTarOptions(&.{
        "rootfs.tar",
        "--ref",
        "local/sporevm-app:dev",
        "--platform",
        "linux/arm64",
        "--rootfs-storage",
        "chunked",
    }, &stdout.writer);
    try std.testing.expectEqualStrings("rootfs.tar", parsed.input);
    try std.testing.expectEqualStrings("local/sporevm-app:dev", parsed.ref);
    try std.testing.expectEqual(.chunked, parsed.rootfs_storage);

    try std.testing.expectError(
        error.UnsupportedRootFSStoragePolicy,
        parseImportTarOptions(
            &.{ "rootfs.tar", "--ref", "local/sporevm-app:dev", "--rootfs-storage", "flat" },
            &stdout.writer,
        ),
    );

    try std.testing.expectError(
        error.MissingRootFSTarPath,
        parseImportTarOptions(&.{ "--ref", "local/sporevm-app:dev" }, &stdout.writer),
    );
    try std.testing.expectError(
        error.LocalRefMustUseLocalRegistry,
        parseImportTarOptions(&.{ "rootfs.tar", "--ref", "ghcr.io/org/image:dev" }, &stdout.writer),
    );
}

test "cas preload can attach manifest-bound rootfs storage to a spore" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-cas-attach-spore";
    const spore_dir = tmp ++ "/spore";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, spore_dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = ("abcd" ** 1024) ++ ("efgh" ** 1024) });

    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const preload_result = try rootfs_cas.preload(io, arena, cache_root, artifact.digest, spore.disk_chunk_size);
    const manifest = try testRootfsAttachManifest(arena, artifact);
    try spore.saveManifest(arena, spore_dir, manifest);

    try attachPreloadedRootfsStorage(arena, spore_dir, artifact.digest, preload_result);

    const parsed = try spore.loadManifest(arena, spore_dir);
    defer parsed.deinit();
    const storage = parsed.value.rootfs.?.storage orelse return error.BadManifest;
    try std.testing.expectEqualStrings(preload_result.index_digest, storage.index_digest);
    try std.testing.expectEqualStrings(preload_result.index_digest, storage.base_identity);
    try std.testing.expectEqual(preload_result.rootfs_size, storage.logical_size);
    try std.testing.expectEqual(preload_result.chunk_size, storage.chunk_size);
    try std.testing.expectEqualStrings(storage.base_identity, parsed.value.disk.?.base);

    const first_index_digest = storage.index_digest;
    try attachPreloadedRootfsStorage(arena, spore_dir, artifact.digest, preload_result);
    const second = try spore.loadManifest(arena, spore_dir);
    defer second.deinit();
    try std.testing.expectEqualStrings(first_index_digest, second.value.rootfs.?.storage.?.index_digest);
}

test "cas preload attach rejects unexpected disk base" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-cas-attach-spore-bad-disk-base";
    const spore_dir = tmp ++ "/spore";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, spore_dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });

    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const preload_result = try rootfs_cas.preload(io, arena, cache_root, artifact.digest, spore.disk_chunk_size);
    var manifest = try testRootfsAttachManifest(arena, artifact);
    manifest.disk.?.base = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    try spore.saveManifest(arena, spore_dir, manifest);

    try std.testing.expectError(
        error.BadManifest,
        attachPreloadedRootfsStorage(arena, spore_dir, artifact.digest, preload_result),
    );
}

fn testRootfsAttachManifest(allocator: std.mem.Allocator, artifact: spore.RootfsArtifactRef) !spore.Manifest {
    const devices = try allocator.alloc(spore.TransportState, 2);
    devices[0] = .{
        .device_id = 3,
        .status = 0,
        .device_features_sel = 0,
        .driver_features_sel = 0,
        .driver_features = 0,
        .queue_sel = 0,
        .interrupt_status = 0,
        .queues = &.{},
    };
    devices[1] = .{
        .device_id = spore.rootfs_virtio_blk_device_id,
        .status = 0,
        .device_features_sel = 0,
        .driver_features_sel = 0,
        .driver_features = 0,
        .queue_sel = 0,
        .interrupt_status = 0,
        .queues = &.{},
    };
    return .{
        .platform = .{
            .cpu_profile = "sporevm-aarch64-v0",
            .device_model_version = 4,
            .ram_base = 0x8000_0000,
            .ram_size = spore.chunk_size,
            .gic_dist_base = 0x0800_0000,
            .gic_redist_base = 0x0801_0000,
            .counter_frequency_hz = 24_000_000,
        },
        .machine = .{
            .gprs = [_]u64{0} ** 31,
            .pc = 0xffff_ffc0_0000_0000,
            .cpsr = 0x3c5,
            .fpcr = 0,
            .fpsr = 0,
            .simd = [_][2]u64{.{ 0, 0 }} ** 32,
            .sys_regs = &.{},
            .icc_regs = &.{},
            .vtimer = .{ .cntvct = 123, .cntv_ctl = 1, .cntv_cval = 456 },
            .gic = .{
                .kind = .gicv3,
                .gicv3 = .{
                    .dist_regs = &.{},
                    .redist_regs = &.{},
                    .line_levels = &.{},
                },
            },
        },
        .devices = devices,
        .generation = .{
            .generation = 7,
            .interrupt_status = 0,
            .params_b64 = "",
        },
        .rootfs = .{
            .device = .{ .mmio_slot = 1 },
            .artifact = artifact,
            .source = .{
                .requested_ref = "docker.io/library/ruby:3.3",
                .resolved_image_ref = "docker.io/library/ruby@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                .image_manifest_digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                .platform = "linux/arm64",
                .builder_version = builder_version,
            },
        },
        .disk = .{
            .device = .{ .mmio_slot = 1 },
            .size = artifact.size,
            .base = artifact.digest,
            .layers = &.{},
        },
        .memory = .{ .logical_size = spore.chunk_size, .chunk_size = spore.chunk_size, .zero_ranges = &.{.{ .start = 0, .count = 1 }} },
    };
}

test "local ref cache resolves to digest-pinned local identity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-local-ref-cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    const cache_root = try std.fs.path.resolve(allocator, &.{tmp});

    const resolved = ResolvedImage{
        .ref = "local/sporevm-app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .manifest_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = .{},
    };
    const ref_path = try writeLocalRefCache(io, allocator, cache_root, "local/sporevm-app:dev", resolved);
    try Io.Dir.cwd().access(io, ref_path, .{});

    const loaded = try resolveLocalCachedRef(io, allocator, cache_root, "local/sporevm-app:dev", .{});
    try std.testing.expectEqualStrings(resolved.ref, loaded.ref);
    try std.testing.expectEqualStrings(resolved.manifest_digest, loaded.manifest_digest);

    try std.testing.expectError(
        error.FileNotFound,
        resolveLocalCachedRef(io, allocator, cache_root, "local/sporevm-app:dev", .{ .os = "linux", .arch = .amd64 }),
    );

    const arm64_path = try localRefCachePath(allocator, cache_root, "local/sporevm-app:dev", .{});
    const amd64_path = try localRefCachePath(allocator, cache_root, "local/sporevm-app:dev", .{ .os = "linux", .arch = .amd64 });
    try std.testing.expect(!std.mem.eql(u8, arm64_path, amd64_path));
}

test "local digest ref resolves without mutable ref cache" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const resolved = try resolveLocalCachedRef(
        std.testing.io,
        allocator,
        "zig-cache/no-local-ref-cache-needed",
        "local/sporevm-app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .{},
    );
    try std.testing.expectEqualStrings(
        "local/sporevm-app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        resolved.ref,
    );
    try std.testing.expectEqualStrings(
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        resolved.manifest_digest,
    );
}

test "local indexed digest ref resolves without mutable ref cache" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const resolved = try resolveLocalCachedRef(
        std.testing.io,
        allocator,
        "zig-cache/no-local-ref-cache-needed",
        "local/sporevm-app@blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .{},
    );
    try std.testing.expectEqualStrings(
        "local/sporevm-app@blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        resolved.ref,
    );
    try std.testing.expectEqualStrings(
        "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        resolved.manifest_digest,
    );
}

test "image rootfs cache key is deterministic and scoped to resolved image identity" {
    const allocator = std.testing.allocator;
    const resolved = ResolvedImage{
        .ref = "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .manifest_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = .{},
    };
    const same = try rootfsCacheKeyAlloc(allocator, resolved);
    defer allocator.free(same);
    const again = try rootfsCacheKeyAlloc(allocator, resolved);
    defer allocator.free(again);
    try std.testing.expectEqual(@as(usize, Sha256.digest_length * 2), same.len);
    try std.testing.expectEqualStrings(same, again);

    const changed_ref = try rootfsCacheKeyAlloc(allocator, .{
        .ref = "docker.io/library/alpine@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .manifest_digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .platform = .{},
    });
    defer allocator.free(changed_ref);
    try std.testing.expect(!std.mem.eql(u8, same, changed_ref));

    const changed_platform = try rootfsCacheKeyAlloc(allocator, .{
        .ref = resolved.ref,
        .manifest_digest = resolved.manifest_digest,
        .platform = .{ .os = "linux", .arch = .amd64 },
    });
    defer allocator.free(changed_platform);
    try std.testing.expect(!std.mem.eql(u8, same, changed_platform));
}

test "image rootfs cache can identify digest-pinned refs without network" {
    const allocator = std.testing.allocator;
    const resolved = (try digestPinnedImageIdentity(
        allocator,
        "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .{},
    )).?;
    defer allocator.free(resolved.ref);

    try std.testing.expectEqualStrings(
        "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        resolved.ref,
    );
    try std.testing.expectEqualStrings(
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        resolved.manifest_digest,
    );
    try std.testing.expect((try digestPinnedImageIdentity(allocator, "docker.io/library/alpine:3.20", .{})) == null);
    try validateTaggedImageRef("docker.io/library/alpine:3.20");
    try std.testing.expectError(error.ImageRefNeedsRegistry, validateTaggedImageRef("alpine:3.20"));
}

test "image rootfs cache metadata matches resolved image identity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-image-cache-metadata";
    const metadata_path = tmp ++ "/metadata.json";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);

    const resolved = ResolvedImage{
        .ref = "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .manifest_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = .{},
    };
    try std.testing.expect(!try cachedRootfsMetadataMatches(io, allocator, metadata_path, resolved));
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = metadata_path,
        .data =
        \\{
        \\  "builder_version": "sporevm-rootfs-v6",
        \\  "ext4_writer": "native",
        \\  "resolved_image_ref": "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "image_manifest_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "platform": {"os": "linux", "arch": "arm64"}
        \\}
        ,
    });
    try std.testing.expect(try cachedRootfsMetadataMatches(io, allocator, metadata_path, resolved));

    try std.testing.expect(!try cachedRootfsMetadataMatches(io, allocator, metadata_path, .{
        .ref = "docker.io/library/alpine@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .manifest_digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .platform = .{},
    }));

    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = metadata_path,
        .data =
        \\{
        \\  "builder_version": "sporevm-rootfs-v6",
        \\  "ext4_writer": "external",
        \\  "resolved_image_ref": "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "image_manifest_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "platform": {"os": "linux", "arch": "arm64"}
        \\}
        ,
    });
    try std.testing.expect(!try cachedRootfsMetadataMatches(io, allocator, metadata_path, resolved));

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = "not json" });
    try std.testing.expect(!try cachedRootfsMetadataMatches(io, allocator, metadata_path, resolved));
}

fn testRootfsStorageFromPath(io: Io, allocator: std.mem.Allocator, cache_root: []const u8, rootfs_path: []const u8) !spore.RootfsStorage {
    const preload_result = try rootfs_cas.preloadPath(io, allocator, cache_root, rootfs_path, rootfs_cas.default_chunk_size);
    return rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload_result);
}

fn testImageRootfsMetadataJson(
    allocator: std.mem.Allocator,
    resolved: ResolvedImage,
    rootfs_path: []const u8,
    rootfs_size: u64,
    storage: spore.RootfsStorage,
) ![]u8 {
    const metadata = .{
        .builder_version = builder_version,
        .ext4_writer = ext4_writer_name,
        .image_ref = "local/example:dev",
        .resolved_image_ref = resolved.ref,
        .image_manifest_digest = resolved.manifest_digest,
        .platform = resolved.platform,
        .rootfs_path = rootfs_path,
        .rootfs_size = rootfs_size,
        .rootfs_storage = storage,
    };
    return std.json.Stringify.valueAlloc(allocator, metadata, .{ .whitespace = .indent_2 });
}

test "image rootfs cache lookup does not repair evicted flat materialization" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-image-cache-lazy-after-flat-evict";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try ensureDirPath(io, cache_root);

    const resolved = ResolvedImage{
        .ref = "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .manifest_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = .{},
    };
    const cache_key = try rootfsCacheKeyAlloc(arena, resolved);
    const rootfs_path = try std.fmt.allocPrint(arena, "{s}/{s}.ext4", .{ cache_root, cache_key });
    const metadata_path = try cachedImageRootfsMetadataPath(arena, cache_root, resolved);
    const rootfs_bytes = ("abcd" ** 1024) ++ ("efgh" ** 1024);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = rootfs_bytes });

    const storage = try testRootfsStorageFromPath(io, arena, cache_root, rootfs_path);
    const metadata = try testImageRootfsMetadataJson(arena, resolved, rootfs_path, storage.logical_size, storage);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = metadata });
    try std.testing.expect(try rootfs_cas.storageComplete(io, arena, cache_root, storage));

    const digest_path = try rootfs_cache.digestPath(arena, cache_root, storage.index_digest);
    try std.testing.expect(!try rootfs_cache.pathExistsNoSymlink(io, digest_path));
    try std.testing.expectEqualStrings(rootfs_path, (try cachedImageRootfsPath(io, arena, cache_root, resolved)).?);
    try std.testing.expect(!try rootfs_cache.pathExistsNoSymlink(io, digest_path));
}

test "image rootfs cache lookup repairs missing complete stamp" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-image-cache-repair-complete-stamp";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try ensureDirPath(io, cache_root);

    const resolved = ResolvedImage{
        .ref = "docker.io/library/alpine@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        .manifest_digest = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        .platform = .{},
    };
    const cache_key = try rootfsCacheKeyAlloc(arena, resolved);
    const rootfs_path = try std.fmt.allocPrint(arena, "{s}/{s}.ext4", .{ cache_root, cache_key });
    const metadata_path = try cachedImageRootfsMetadataPath(arena, cache_root, resolved);
    const rootfs_bytes = ("abcd" ** 1024) ++ ("efgh" ** 1024);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = rootfs_bytes });

    const storage = try testRootfsStorageFromPath(io, arena, cache_root, rootfs_path);
    const metadata = try testImageRootfsMetadataJson(arena, resolved, rootfs_path, storage.logical_size, storage);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = metadata });
    try std.testing.expect(try rootfs_cas.storageMarkedComplete(io, arena, cache_root, storage));

    try rootfs_cas.removeStorageCompleteStamp(io, arena, cache_root, storage.index_digest);
    try std.testing.expect(!try rootfs_cas.storageMarkedComplete(io, arena, cache_root, storage));
    try std.testing.expectEqualStrings(rootfs_path, (try cachedImageRootfsPath(io, arena, cache_root, resolved)).?);
    try std.testing.expect(try rootfs_cas.storageMarkedComplete(io, arena, cache_root, storage));
}

test "image rootfs cache lookup uses complete stamp without per-object stat" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-image-cache-flat-before-cas";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try ensureDirPath(io, cache_root);

    const resolved = ResolvedImage{
        .ref = "docker.io/library/alpine@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .manifest_digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .platform = .{},
    };
    const cache_key = try rootfsCacheKeyAlloc(arena, resolved);
    const rootfs_path = try std.fmt.allocPrint(arena, "{s}/{s}.ext4", .{ cache_root, cache_key });
    const metadata_path = try cachedImageRootfsMetadataPath(arena, cache_root, resolved);
    const rootfs_bytes = ("abcd" ** 1024) ++ ("efgh" ** 1024);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = rootfs_bytes });

    const storage = try testRootfsStorageFromPath(io, arena, cache_root, rootfs_path);
    const metadata = try testImageRootfsMetadataJson(arena, resolved, rootfs_path, storage.logical_size, storage);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = metadata });
    _ = try rootfs_cache.installTrustedMaterializationByHardlink(io, arena, cache_root, rootfs_path, storage.index_digest, storage.logical_size);

    const object_id = chunk.ChunkId.fromContents(rootfs_bytes);
    const object_hex = object_id.toHex();
    const object_digest = try std.fmt.allocPrint(arena, "{s}{s}", .{ spore.rootfs_digest_prefix, object_hex[0..] });
    const object_path = try rootfs_cas.manifestObjectPath(arena, cache_root, object_digest);
    try Io.Dir.cwd().deleteFile(io, object_path);
    try std.testing.expect(!try rootfs_cas.storageComplete(io, arena, cache_root, storage));
    try std.testing.expect(try rootfs_cas.storageMarkedComplete(io, arena, cache_root, storage));
    try std.testing.expectEqualStrings(rootfs_path, (try cachedImageRootfsPath(io, arena, cache_root, resolved)).?);

    try rootfs_cas.removeStorageCompleteStampsReferencingObject(io, arena, cache_root, object_digest);
    try std.testing.expect(!try rootfs_cas.storageMarkedComplete(io, arena, cache_root, storage));
    try std.testing.expect((try cachedImageRootfsPath(io, arena, cache_root, resolved)) == null);
}

test "image rootfs metadata supplies cached artifact identity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-image-cache-artifact";
    const cache_root = tmp ++ "/cache";
    const metadata_path = tmp ++ "/metadata.json";
    const rootfs_path = tmp ++ "/rootfs.ext4";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try ensureDirPath(io, cache_root);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });

    const storage = try testRootfsStorageFromPath(io, arena, cache_root, rootfs_path);
    const metadata_json = try testImageRootfsMetadataJson(arena, .{
        .ref = "local/example@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .manifest_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = .{},
    }, rootfs_path, "rootfs bytes".len, storage);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = metadata_json });

    const cached = (try cachedImageRootfsArtifact(io, arena, metadata_path, rootfs_path)).?;
    try std.testing.expectEqualStrings(storage.index_digest, cached.digest);
    try std.testing.expectEqual(storage.logical_size, cached.size);
    try std.testing.expectEqualStrings(spore.rootfs_artifact_format_ext4, cached.format);

    try std.testing.expect((try cachedImageRootfsArtifact(io, arena, metadata_path, tmp ++ "/other.ext4")) == null);

    const wrong_size_json = try testImageRootfsMetadataJson(arena, .{
        .ref = "local/example@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .manifest_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = .{},
    }, rootfs_path, storage.logical_size + 1, storage);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = wrong_size_json });
    try std.testing.expect((try cachedImageRootfsArtifact(io, arena, metadata_path, rootfs_path)) == null);

    const missing_storage_json = try std.fmt.allocPrint(arena,
        \\{{
        \\  "rootfs_path": "{s}",
        \\  "rootfs_size": {d}
        \\}}
    , .{ rootfs_path, storage.logical_size });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = missing_storage_json });
    try std.testing.expect((try cachedImageRootfsArtifact(io, arena, metadata_path, rootfs_path)) == null);
}

test "image rootfs artifact metadata rejects symlink rootfs path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-image-cache-artifact-symlink";
    const cache_root = tmp ++ "/cache";
    const metadata_path = tmp ++ "/metadata.json";
    const target_path = tmp ++ "/target.ext4";
    const rootfs_path = tmp ++ "/rootfs.ext4";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try ensureDirPath(io, cache_root);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = target_path, .data = "rootfs bytes" });
    const target_z = try arena.dupeZ(u8, target_path);
    const rootfs_z = try arena.dupeZ(u8, rootfs_path);
    if (std.c.symlink(target_z, rootfs_z) != 0) return error.SkipZigTest;

    const storage = try testRootfsStorageFromPath(io, arena, cache_root, target_path);
    const metadata_json = try testImageRootfsMetadataJson(arena, .{
        .ref = "local/example@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .manifest_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = .{},
    }, rootfs_path, "rootfs bytes".len, storage);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = metadata_json });

    try std.testing.expect((try cachedImageRootfsArtifact(io, arena, metadata_path, rootfs_path)) == null);
}

test "imported rootfs flat-only cache metadata misses" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-import-cache-flat-hit";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try ensureDirPath(io, cache_root);

    const resolved = ResolvedImage{
        .ref = "local/example@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .manifest_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = .{},
    };
    const cache_key = try rootfsCacheKeyAlloc(arena, resolved);
    const rootfs_path = try std.fmt.allocPrint(arena, "{s}/{s}.ext4", .{ cache_root, cache_key });
    const metadata_path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ cache_root, cache_key });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "cached rootfs bytes" });

    const metadata_json = try std.fmt.allocPrint(arena,
        \\{{
        \\  "builder_version": "{s}",
        \\  "ext4_writer": "native",
        \\  "image_ref": "local/example:dev",
        \\  "resolved_image_ref": "{s}",
        \\  "image_manifest_digest": "{s}",
        \\  "platform": {{"os": "{s}", "arch": "{s}"}},
        \\  "rootfs_path": "{s}",
        \\  "rootfs_size": {d}
        \\}}
    , .{ builder_version, resolved.ref, resolved.manifest_digest, resolved.platform.os, resolved.platform.arch.name(), rootfs_path, "cached rootfs bytes".len });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = metadata_json });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
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

    try std.testing.expect((try cachedImportedRootfsStorage(init, arena, cache_root, resolved, rootfs_path, metadata_path, .chunked)) == null);
    try std.testing.expectError(
        error.UnsupportedRootfsStorage,
        cachedImportedRootfsStorage(init, arena, cache_root, resolved, rootfs_path, metadata_path, .flat),
    );
    const updated_metadata = try Io.Dir.cwd().readFileAlloc(io, metadata_path, arena, .limited(max_rootfs_metadata_bytes));
    try std.testing.expect(std.mem.indexOf(u8, updated_metadata, "\"rootfs_storage\"") == null);
}

test "imported rootfs chunked cache hit reuses storage metadata" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-import-cache-chunked-upgrade";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try ensureDirPath(io, cache_root);

    const resolved = ResolvedImage{
        .ref = "local/example@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .manifest_digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .platform = .{},
    };
    const cache_key = try rootfsCacheKeyAlloc(arena, resolved);
    const rootfs_path = try std.fmt.allocPrint(arena, "{s}/{s}.ext4", .{ cache_root, cache_key });
    const metadata_path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ cache_root, cache_key });
    const rootfs_bytes = ("abcd" ** 1024) ++ ("efgh" ** 1024);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = rootfs_bytes });

    const storage = try testRootfsStorageFromPath(io, arena, cache_root, rootfs_path);
    const metadata_json = try testImageRootfsMetadataJson(arena, resolved, rootfs_path, rootfs_bytes.len, storage);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = metadata_json });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
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

    const hit = (try cachedImportedRootfsStorage(init, arena, cache_root, resolved, rootfs_path, metadata_path, .chunked)).?;
    try std.testing.expectEqualStrings(storage.index_digest, hit.index_digest);
    const updated_metadata = try Io.Dir.cwd().readFileAlloc(io, metadata_path, arena, .limited(max_rootfs_metadata_bytes));
    try std.testing.expect(std.mem.indexOf(u8, updated_metadata, "\"rootfs_storage\"") != null);
    const artifact = spore.RootfsArtifactRef{ .digest = hit.index_digest, .size = hit.logical_size };
    const recorded = (try readCachedRootfsStorage(io, arena, metadata_path, artifact)).?;
    try std.testing.expect(try rootfs_cas.storageComplete(io, arena, cache_root, recorded));
}

test "image rootfs cache treats oversized metadata as a miss" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-image-cache-oversized-metadata";
    const metadata_path = tmp ++ "/metadata.json";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);

    const oversized = try allocator.alloc(u8, max_rootfs_metadata_bytes);
    defer allocator.free(oversized);
    @memset(oversized, ' ');
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = oversized });

    try std.testing.expect(!try cachedRootfsMetadataMatches(io, allocator, metadata_path, .{
        .ref = "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .manifest_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = .{},
    }));
}

test "image ref cache key is deterministic and scoped to requested tag" {
    const allocator = std.testing.allocator;
    const key = try imageRefCacheKeyAlloc(allocator, "docker.io/library/alpine:3.20", .{});
    defer allocator.free(key);
    const again = try imageRefCacheKeyAlloc(allocator, "docker.io/library/alpine:3.20", .{});
    defer allocator.free(again);
    try std.testing.expectEqual(@as(usize, Sha256.digest_length * 2), key.len);
    try std.testing.expectEqualStrings(key, again);

    const changed_tag = try imageRefCacheKeyAlloc(allocator, "docker.io/library/alpine:3.21", .{});
    defer allocator.free(changed_tag);
    try std.testing.expect(!std.mem.eql(u8, key, changed_tag));

    const changed_platform = try imageRefCacheKeyAlloc(allocator, "docker.io/library/alpine:3.20", .{ .os = "linux", .arch = .amd64 });
    defer allocator.free(changed_platform);
    try std.testing.expect(!std.mem.eql(u8, key, changed_platform));
}

test "image ref cache maps tag to verified rootfs path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-image-ref-cache-hit";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try ensureDirPath(io, cache_root);

    const resolved = ResolvedImage{
        .ref = "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .manifest_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = .{},
    };
    const cache_key = try rootfsCacheKeyAlloc(arena, resolved);
    const rootfs_path = try std.fmt.allocPrint(arena, "{s}/{s}.ext4", .{ cache_root, cache_key });
    const metadata_path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ cache_root, cache_key });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });
    const storage = try testRootfsStorageFromPath(io, arena, cache_root, rootfs_path);
    const metadata_json = try testImageRootfsMetadataJson(arena, resolved, rootfs_path, "rootfs bytes".len, storage);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = metadata_json });

    try writeImageRefCacheRecord(io, arena, cache_root, "docker.io/library/alpine:3.20", resolved);
    const hit = (try cachedImageRefRootfsPath(io, arena, cache_root, "docker.io/library/alpine:3.20", .{})).?;
    try std.testing.expectEqualStrings(rootfs_path, hit.path);
    try std.testing.expectEqualStrings(resolved.ref, hit.resolved.ref);
    try std.testing.expectEqualStrings(resolved.manifest_digest, hit.resolved.manifest_digest);
}

test "image ref cache treats mismatched records and missing rootfs as misses" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-image-ref-cache-miss";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try ensureDirPath(io, cache_root);
    try ensureDirPath(io, try std.fs.path.join(arena, &.{ cache_root, "refs" }));

    const resolved = ResolvedImage{
        .ref = "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .manifest_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = .{},
    };
    const cache_key = try rootfsCacheKeyAlloc(arena, resolved);
    const record_path = try imageRefCacheRecordPath(arena, cache_root, "docker.io/library/alpine:3.20", .{});
    const bad_record = try std.fmt.allocPrint(arena,
        \\{{
        \\  "version": 1,
        \\  "requested_ref": "docker.io/library/alpine:other",
        \\  "platform": "linux/arm64",
        \\  "builder_version": "sporevm-rootfs-v6",
        \\  "resolved_image_ref": "{s}",
        \\  "image_manifest_digest": "{s}",
        \\  "rootfs_cache_key": "{s}",
        \\  "resolved_at_unix": 123
        \\}}
    , .{ resolved.ref, resolved.manifest_digest, cache_key });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = record_path, .data = bad_record });
    try std.testing.expect((try cachedImageRefRootfsPath(io, arena, cache_root, "docker.io/library/alpine:3.20", .{})) == null);

    const bad_resolved_ref_record = try std.fmt.allocPrint(arena,
        \\{{
        \\  "version": 1,
        \\  "requested_ref": "docker.io/library/alpine:3.20",
        \\  "platform": "linux/arm64",
        \\  "builder_version": "sporevm-rootfs-v6",
        \\  "resolved_image_ref": "docker.io/library/alpine:not-a-digest",
        \\  "image_manifest_digest": "{s}",
        \\  "rootfs_cache_key": "{s}",
        \\  "resolved_at_unix": 123
        \\}}
    , .{ resolved.manifest_digest, cache_key });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = record_path, .data = bad_resolved_ref_record });
    try std.testing.expect((try cachedImageRefRootfsPath(io, arena, cache_root, "docker.io/library/alpine:3.20", .{})) == null);

    try writeImageRefCacheRecord(io, arena, cache_root, "docker.io/library/alpine:3.20", resolved);
    try std.testing.expect((try cachedImageRefRootfsPath(io, arena, cache_root, "docker.io/library/alpine:3.20", .{})) == null);
}

test "image rootfs storage is recorded and reused without the digest artifact" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-image-rootfs-storage";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try ensureDirPath(io, cache_root);

    const resolved = ResolvedImage{
        .ref = "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .manifest_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = .{},
    };
    const cache_key = try rootfsCacheKeyAlloc(arena, resolved);
    const rootfs_path = try std.fmt.allocPrint(arena, "{s}/{s}.ext4", .{ cache_root, cache_key });
    const metadata_path = try cachedImageRootfsMetadataPath(arena, cache_root, resolved);
    const rootfs_bytes = ("abcd" ** 1024) ++ ("efgh" ** 1024);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = rootfs_bytes });

    const first = try testRootfsStorageFromPath(io, arena, cache_root, rootfs_path);
    const artifact = spore.RootfsArtifactRef{ .digest = first.index_digest, .size = first.logical_size };
    const metadata_json = try testImageRootfsMetadataJson(arena, resolved, rootfs_path, rootfs_bytes.len, first);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = metadata_json });
    try std.testing.expect(try rootfs_cas.storageComplete(io, arena, cache_root, first));
    const recorded = (try readCachedRootfsStorage(io, arena, metadata_path, artifact)).?;
    try std.testing.expectEqualStrings(first.index_digest, recorded.index_digest);

    const stale_storage_digest = try arena.dupe(u8, first.index_digest);
    stale_storage_digest[spore.rootfs_digest_prefix.len] = if (stale_storage_digest[spore.rootfs_digest_prefix.len] == '0') '1' else '0';
    const stale_metadata = try std.fmt.allocPrint(arena,
        \\{{
        \\  "rootfs_size": {d},
        \\  "rootfs_storage": {{
        \\    "kind": "{s}",
        \\    "device": {{
        \\      "kind": "{s}",
        \\      "role": "{s}",
        \\      "virtio_device_id": {d},
        \\      "mmio_slot": 1
        \\    }},
        \\    "logical_size": {d},
        \\    "chunk_size": {d},
        \\    "hash_algorithm": "{s}",
        \\    "index_digest": "{s}",
        \\    "base_identity": "{s}",
        \\    "object_namespace": "{s}"
        \\  }}
        \\}}
    , .{
        artifact.size,
        spore.rootfs_storage_kind_chunked_ext4,
        spore.rootfs_device_kind_virtio_mmio,
        spore.rootfs_device_role,
        spore.rootfs_virtio_blk_device_id,
        artifact.size,
        rootfs_cas.default_chunk_size,
        spore.rootfs_storage_hash_algorithm_blake3,
        stale_storage_digest,
        stale_storage_digest,
        spore.rootfs_storage_object_namespace,
    });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = stale_metadata });
    try std.testing.expect((try readCachedRootfsStorage(io, arena, metadata_path, artifact)) == null);

    const object_id = chunk.ChunkId.fromContents(rootfs_bytes);
    const object_hex = object_id.toHex();
    const object_digest = try std.fmt.allocPrint(arena, "{s}{s}", .{ spore.rootfs_digest_prefix, object_hex[0..] });
    const object_path = try rootfs_cas.manifestObjectPath(arena, cache_root, object_digest);
    try Io.Dir.cwd().deleteFile(io, object_path);
    try std.testing.expect(!try rootfs_cas.storageComplete(io, arena, cache_root, first));
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
    const tmp = "zig-cache/test-rootfs-metadata-symlink";
    const output = tmp ++ "/rootfs.ext4";
    const metadata = tmp ++ "/metadata.json";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
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
