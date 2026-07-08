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
const local_paths = @import("local_paths.zig");
const oci = @import("rootfs/oci.zig");
const oci_layout = @import("rootfs/oci_layout.zig");
const ownership_mod = @import("rootfs/ownership.zig");
const registry = @import("rootfs/registry.zig");
const rootfs_cache = @import("rootfs_cache.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const spore = @import("spore.zig");
const tar = @import("rootfs/tar.zig");
const xattrs_mod = @import("rootfs/xattrs.zig");

const Io = std.Io;

const max_rootfs_layers: usize = 512;
pub const builder_version = "sporevm-rootfs-v5";
const rootfs_build_profile_env = "SPOREVM_ROOTFS_BUILD_PROFILE";
const ext4_writer_env = "SPOREVM_EXT4_WRITER";
const resolver_placeholder_path = "etc/resolv.conf";
const resolver_placeholder_bytes =
    "# SporeVM generated placeholder; --net bind-mounts the guest resolver here.\n";

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
    \\  --platform <os/arch>       Target platform (default: linux/arm64)
    \\  --metadata <path>          Metadata sidecar path (default: <output>.json)
    \\  --mkfs <path>              external writer mkfs.ext4 binary (auto-detect)
    \\  --debugfs <path>           external writer debugfs binary (auto-detect)
    \\
;

pub const ParsedBuildOptions = struct {
    ref: []const u8,
    output: []const u8,
    metadata: []const u8,
    platform: Platform = .{},
    mkfs: ?[]const u8 = null,
    debugfs: ?[]const u8 = null,
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
    mkfs: ?[]const u8 = null,
    debugfs: ?[]const u8 = null,
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
    mkfs: ?[]const u8 = null,
    debugfs: ?[]const u8 = null,
    metadata_rootfs_path: ?[]const u8 = null,
    temp_dir_root: ?[]const u8 = null,
};

pub const ImportOciRequest = struct {
    input: []const u8,
    ref: []const u8,
    platform: Platform = .{},
    rootfs_storage: RootfsStoragePolicy = .chunked,
    mkfs: ?[]const u8 = null,
    debugfs: ?[]const u8 = null,
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
    rootfs_path: []const u8,
    metadata_path: []const u8,
    local_ref_path: []const u8,
    resolved_image_ref: []const u8,
    image_manifest_digest: []const u8,
    rootfs_blake3: [chunk.ChunkId.hex_len]u8,
};

pub const ImportTarResult = ImportOciResult;

pub const RootfsStoragePolicy = enum {
    chunked,
    flat,
};

const BuildOptions = struct {
    ref: []const u8,
    output: []const u8,
    metadata: []const u8,
    platform: Platform = .{},
    mkfs: ?[]const u8,
    debugfs: ?[]const u8,
    ext4_writer: Ext4Writer,
    metadata_rootfs_path: ?[]const u8 = null,
    temp_dir_root: ?[]const u8 = null,
    cache_owned_output: bool = false,
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

const LocalRefMetadata = struct {
    kind: []const u8 = local_ref_cache_kind,
    ref: []const u8,
    resolved_image_ref: []const u8,
    image_manifest_digest: []const u8,
    platform: Platform,
    builder_version: []const u8 = builder_version,
};

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
    var mkfs: ?[]const u8 = null;
    var debugfs: ?[]const u8 = null;

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
        } else if (std.mem.eql(u8, arg, "--mkfs")) {
            i += 1;
            if (i >= args.len) return error.MissingMkfsPath;
            mkfs = args[i];
        } else if (std.mem.eql(u8, arg, "--debugfs")) {
            i += 1;
            if (i >= args.len) return error.MissingDebugfsPath;
            debugfs = args[i];
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
        .mkfs = mkfs,
        .debugfs = debugfs,
    };
}

fn parseRootfsStoragePolicy(raw: []const u8) !RootfsStoragePolicy {
    if (std.mem.eql(u8, raw, "chunked")) return .chunked;
    if (std.mem.eql(u8, raw, "flat")) return .flat;
    return error.UnsupportedRootFSStoragePolicy;
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
    if (!std.mem.eql(u8, rootfs.artifact.digest, expected_digest)) return error.BadManifest;
    if (!std.mem.eql(u8, preload_result.rootfs_digest, expected_digest)) return error.BadManifest;
    if (rootfs.artifact.size != preload_result.rootfs_size) return error.BadManifest;

    const storage = rootfs_cas.storageDescriptor(rootfs.device, preload_result);
    if (rootfs.storage) |existing| {
        if (!spore.rootfsStorageEql(existing, storage)) return error.BadManifest;
    }
    rootfs.storage = storage;
    manifest.rootfs = rootfs;

    if (manifest.disk) |disk_value| {
        var disk = disk_value;
        if (!std.mem.eql(u8, disk.base, rootfs.artifact.digest) and
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
    var mkfs: ?[]const u8 = null;
    var debugfs: ?[]const u8 = null;

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
        } else if (std.mem.eql(u8, arg, "--mkfs")) {
            i += 1;
            if (i >= args.len) return error.MissingMkfsPath;
            mkfs = args[i];
        } else if (std.mem.eql(u8, arg, "--debugfs")) {
            i += 1;
            if (i >= args.len) return error.MissingDebugfsPath;
            debugfs = args[i];
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
        .mkfs = mkfs,
        .debugfs = debugfs,
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

const Ext4Tool = enum {
    mkfs,
    debugfs,

    fn executableName(tool: Ext4Tool) []const u8 {
        return switch (tool) {
            .mkfs => "mkfs.ext4",
            .debugfs => "debugfs",
        };
    }
};

fn resolveExt4Tool(
    allocator: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    explicit: ?[]const u8,
    tool: Ext4Tool,
) ![]const u8 {
    if (explicit) |path| return path;
    const name = tool.executableName();
    if (try detectToolPath(allocator, io, environ, name)) |path| return path;
    return switch (tool) {
        .mkfs => error.MkfsNotFound,
        .debugfs => error.DebugfsNotFound,
    };
}

fn detectToolPath(
    allocator: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    name: []const u8,
) !?[]const u8 {
    if (environ.get("PATH")) |path_value| {
        if (try findExecutableInPath(allocator, io, path_value, name)) |path| return path;
    }

    if (environ.get("HOMEBREW_PREFIX")) |prefix| {
        if (try findExecutableInDir(allocator, io, prefix, "opt/e2fsprogs/sbin", name)) |path| return path;
    }

    const known_dirs = [_][]const u8{
        "/opt/homebrew/opt/e2fsprogs/sbin",
        "/usr/local/opt/e2fsprogs/sbin",
        "/usr/local/sbin",
        "/usr/sbin",
        "/sbin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
    };
    for (known_dirs) |dir| {
        if (try findExecutableInDir(allocator, io, dir, "", name)) |path| return path;
    }
    return null;
}

fn findExecutableInPath(
    allocator: std.mem.Allocator,
    io: Io,
    path_value: []const u8,
    name: []const u8,
) !?[]const u8 {
    var iter = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
    while (iter.next()) |raw_dir| {
        const dir = if (raw_dir.len == 0) "." else raw_dir;
        if (try findExecutableInDir(allocator, io, dir, "", name)) |path| return path;
    }
    return null;
}

fn findExecutableInDir(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    suffix: []const u8,
    name: []const u8,
) !?[]const u8 {
    const candidate = if (suffix.len == 0)
        try std.fs.path.join(allocator, &.{ dir, name })
    else
        try std.fs.path.join(allocator, &.{ dir, suffix, name });
    if (try isExecutablePath(io, candidate)) return candidate;
    allocator.free(candidate);
    return null;
}

fn isExecutablePath(io: Io, path: []const u8) !bool {
    const options: Io.Dir.AccessOptions = .{ .execute = true };
    if (Io.Dir.path.isAbsolute(path)) {
        Io.Dir.accessAbsolute(io, path, options) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return false,
            else => |e| return e,
        };
        return true;
    }
    Io.Dir.cwd().access(io, path, options) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return false,
        else => |e| return e,
    };
    return true;
}

pub const Platform = oci.Platform;
pub const ImageRef = oci.ImageRef;
const ImageTag = oci.ImageTag;
const ImageManifest = oci.ImageManifest;
const ImageConfig = oci.ImageConfig;

pub const BuildResult = struct {
    rootfs_blake3: [chunk.ChunkId.hex_len]u8,
    rootfs_storage: spore.RootfsStorage,
};

const MaterializeResult = struct {
    rootfs_blake3: [chunk.ChunkId.hex_len]u8,
    rootfs_storage: ?spore.RootfsStorage,
};

pub const Ext4Writer = enum {
    native,
    external,

    fn text(self: Ext4Writer) []const u8 {
        return @tagName(self);
    }
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

    fn preloadPhase(self: RootfsBuildProfile, start_ms: u64, result: rootfs_cas.PreloadResult) void {
        if (!self.enabled) return;
        std.debug.print(
            "spore rootfs profile: phase=rootfs_cas_preload ms={d} chunks={d} zero_chunks={d} nonzero_chunks={d} objects_written={d} object_bytes_written={d} index_bytes={d} source_verify_ms={d} chunk_scan_ms={d} object_check_ms={d} object_write_ms={d} index_build_ms={d} index_write_ms={d}\n",
            .{
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

fn ext4WriterFromEnvValue(value: ?[]const u8) !Ext4Writer {
    const raw = value orelse return .native;
    if (raw.len == 0 or std.mem.eql(u8, raw, "native")) return .native;
    if (std.mem.eql(u8, raw, "external")) return .external;
    return error.UnsupportedExt4Writer;
}

pub fn selectedExt4Writer(environ: *const std.process.Environ.Map) !Ext4Writer {
    return ext4WriterFromEnvValue(environ.get(ext4_writer_env));
}

pub fn validateTaggedImageRef(raw_ref: []const u8) !void {
    _ = try ImageTag.parse(raw_ref);
}

const OwnershipMap = ownership_mod.Map;
const XattrMap = xattrs_mod.Map;

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
    rootfs_blake3: []const u8,
    rootfs_storage: ?spore.RootfsStorage = null,
};

fn resolveTaggedImageRef(init: std.process.Init, allocator: std.mem.Allocator, opts: ParsedResolveOptions) ![]const u8 {
    const image_tag = try ImageTag.parse(opts.ref);

    var client: std.http.Client = .{ .allocator = allocator, .io = init.io };
    defer client.deinit();
    var bearer_token: ?[]const u8 = null;

    const fetched = try registry.fetchManifestByTag(allocator, &client, &bearer_token, image_tag);
    const tag_digest = try manifestContentDigest(allocator, fetched.bytes, fetched.content_digest);
    const image_ref = ImageRef{
        .registry = image_tag.registry,
        .repository = image_tag.repository,
        .digest = tag_digest,
    };
    const selected_manifest_digest = try resolveManifestDigest(
        allocator,
        &client,
        &bearer_token,
        image_ref,
        opts.platform,
        tag_digest,
        fetched.bytes,
    );
    const selected_manifest_bytes = try selectedManifestBytes(
        allocator,
        &client,
        &bearer_token,
        image_ref,
        selected_manifest_digest,
        fetched.bytes,
    );
    try validateManifestConfigPlatform(allocator, &client, &bearer_token, image_ref, selected_manifest_bytes, opts.platform);
    return image_tag.digestRef(allocator, selected_manifest_digest);
}

pub fn resolveImageRef(init: std.process.Init, allocator: std.mem.Allocator, raw_ref: []const u8, platform: Platform) !ResolvedImage {
    var client: std.http.Client = .{ .allocator = allocator, .io = init.io };
    defer client.deinit();
    var bearer_token: ?[]const u8 = null;

    const image_source = try fetchBuildImageSource(allocator, &client, &bearer_token, raw_ref);
    const image_ref = image_source.ref;
    const manifest_digest = try resolveManifestDigest(allocator, &client, &bearer_token, image_ref, platform, image_ref.digest, image_source.manifest_bytes);
    const selected_manifest_bytes = try selectedManifestBytes(allocator, &client, &bearer_token, image_ref, manifest_digest, image_source.manifest_bytes);
    try validateManifestConfigPlatform(allocator, &client, &bearer_token, image_ref, selected_manifest_bytes, platform);

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
    client: *std.http.Client,
    bearer_token: *?[]const u8,
    raw_ref: []const u8,
) !BuildImageSource {
    if (ImageRef.parse(raw_ref)) |image_ref| {
        const manifest_bytes = try registry.fetchManifest(allocator, client, bearer_token, image_ref, image_ref.digest);
        try oci.verifyDigestBytes(image_ref.digest, manifest_bytes);
        return .{ .ref = image_ref, .manifest_bytes = manifest_bytes };
    } else |err| switch (err) {
        error.ImageRefMustBeDigestPinned => {},
        else => |e| return e,
    }

    const image_tag = try ImageTag.parse(raw_ref);
    const fetched = try registry.fetchManifestByTag(allocator, client, bearer_token, image_tag);
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
    client: *std.http.Client,
    bearer_token: *?[]const u8,
    image_ref: ImageRef,
    digest: []const u8,
    initial_manifest_bytes: []const u8,
) ![]const u8 {
    const bytes = if (std.mem.eql(u8, digest, image_ref.digest))
        initial_manifest_bytes
    else
        try registry.fetchManifest(allocator, client, bearer_token, image_ref, digest);
    try oci.verifyDigestBytes(digest, bytes);
    return bytes;
}

fn validateManifestConfigPlatform(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    bearer_token: *?[]const u8,
    image_ref: ImageRef,
    manifest_bytes: []const u8,
    platform: Platform,
) !void {
    var manifest_parsed = try std.json.parseFromSlice(ImageManifest, allocator, manifest_bytes, .{ .ignore_unknown_fields = true });
    defer manifest_parsed.deinit();
    const manifest = manifest_parsed.value;

    if (manifest.schemaVersion != 2) return error.UnsupportedManifestSchema;
    if (!oci.isSha256Digest(manifest.config.digest)) return error.UnsupportedDigest;
    const config_bytes = try registry.fetchBlobBytes(allocator, client, bearer_token, image_ref, manifest.config.digest, manifest.config.size);
    try oci.verifyDigestBytes(manifest.config.digest, config_bytes);
    var config_parsed = try std.json.parseFromSlice(ImageConfig, allocator, config_bytes, .{ .ignore_unknown_fields = true });
    defer config_parsed.deinit();
    try validateConfigPlatform(config_parsed.value, platform);
}

pub fn build(init: std.process.Init, allocator: std.mem.Allocator, request: BuildRequest) !BuildResult {
    const ext4_writer_choice = try selectedExt4Writer(init.environ_map);
    const opts = BuildOptions{
        .ref = request.ref,
        .output = request.output,
        .metadata = request.metadata,
        .platform = request.platform,
        .mkfs = request.mkfs,
        .debugfs = request.debugfs,
        .ext4_writer = ext4_writer_choice,
        .metadata_rootfs_path = request.metadata_rootfs_path,
        .temp_dir_root = request.temp_dir_root,
    };
    return buildRootFS(init, allocator, opts);
}

pub fn importOciLayout(init: std.process.Init, allocator: std.mem.Allocator, request: ImportOciRequest) !ImportOciResult {
    _ = try parseLocalTagRef(request.ref);
    const ext4_writer_choice = try selectedExt4Writer(init.environ_map);
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
    if (try cachedImportedRootfsBlake3(init, allocator, cache_root, resolved, rootfs_path, metadata_path, request.rootfs_storage, ext4_writer_choice)) |rootfs_blake3| {
        const local_ref_path = try writeLocalRefCache(init.io, allocator, cache_root, request.ref, resolved);
        return .{
            .rootfs_path = rootfs_path,
            .metadata_path = metadata_path,
            .local_ref_path = local_ref_path,
            .resolved_image_ref = resolved_image_ref,
            .image_manifest_digest = source.manifest_digest,
            .rootfs_blake3 = rootfs_blake3,
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
        .mkfs = request.mkfs,
        .debugfs = request.debugfs,
        .ext4_writer = ext4_writer_choice,
        .metadata_rootfs_path = rootfs_path,
        .temp_dir_root = temp_dir_root,
        .rootfs_storage = request.rootfs_storage,
        .cache_owned_output = true,
    });
    try Io.Dir.renameAbsolute(temp_rootfs_path, rootfs_path, init.io);
    try Io.Dir.renameAbsolute(temp_metadata_path, metadata_path, init.io);
    const local_ref_path = try writeLocalRefCache(init.io, allocator, cache_root, request.ref, resolved);

    return .{
        .rootfs_path = rootfs_path,
        .metadata_path = metadata_path,
        .local_ref_path = local_ref_path,
        .resolved_image_ref = resolved_image_ref,
        .image_manifest_digest = source.manifest_digest,
        .rootfs_blake3 = result.rootfs_blake3,
    };
}

pub fn importTar(init: std.process.Init, allocator: std.mem.Allocator, request: ImportTarRequest) !ImportTarResult {
    _ = try parseLocalTagRef(request.ref);
    const ext4_writer_choice = try selectedExt4Writer(init.environ_map);
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
    if (try cachedImportedRootfsBlake3(init, allocator, cache_root, resolved, rootfs_path, metadata_path, request.rootfs_storage, ext4_writer_choice)) |rootfs_blake3| {
        const local_ref_path = try writeLocalRefCache(init.io, allocator, cache_root, request.ref, resolved);
        return .{
            .rootfs_path = rootfs_path,
            .metadata_path = metadata_path,
            .local_ref_path = local_ref_path,
            .resolved_image_ref = resolved_image_ref,
            .image_manifest_digest = input_digest,
            .rootfs_blake3 = rootfs_blake3,
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
        .mkfs = request.mkfs,
        .debugfs = request.debugfs,
        .ext4_writer = ext4_writer_choice,
        .metadata_rootfs_path = rootfs_path,
        .temp_dir_root = temp_dir_root,
        .rootfs_storage = request.rootfs_storage,
        .cache_owned_output = true,
    });
    try Io.Dir.renameAbsolute(temp_rootfs_path, rootfs_path, init.io);
    try Io.Dir.renameAbsolute(temp_metadata_path, metadata_path, init.io);
    const local_ref_path = try writeLocalRefCache(init.io, allocator, cache_root, request.ref, resolved);

    return .{
        .rootfs_path = rootfs_path,
        .metadata_path = metadata_path,
        .local_ref_path = local_ref_path,
        .resolved_image_ref = resolved_image_ref,
        .image_manifest_digest = input_digest,
        .rootfs_blake3 = result.rootfs_blake3,
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
}

pub const deinitImportTarResult = deinitImportOciResult;

pub fn deinitResolvedReference(allocator: std.mem.Allocator, resolved_ref: []const u8) void {
    allocator.free(resolved_ref);
}

pub fn deinitCasPreloadResult(allocator: std.mem.Allocator, result: CasPreloadResult) void {
    allocator.free(result.index_path);
    allocator.free(result.index_digest);
    allocator.free(result.rootfs_digest);
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
    output: []const u8,
    metadata: []const u8,
    platform: Platform = .{},
    mkfs: ?[]const u8,
    debugfs: ?[]const u8,
    ext4_writer: Ext4Writer,
    metadata_rootfs_path: ?[]const u8 = null,
    temp_dir_root: []const u8,
    rootfs_storage: RootfsStoragePolicy = .chunked,
    cache_owned_output: bool = false,
};

const TarBuildOptions = struct {
    requested_ref: []const u8,
    resolved_image_ref: []const u8,
    manifest_digest: []const u8,
    input: []const u8,
    output: []const u8,
    metadata: []const u8,
    platform: Platform = .{},
    mkfs: ?[]const u8,
    debugfs: ?[]const u8,
    ext4_writer: Ext4Writer,
    metadata_rootfs_path: ?[]const u8 = null,
    temp_dir_root: []const u8,
    rootfs_storage: RootfsStoragePolicy = .chunked,
    cache_owned_output: bool = false,
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
    mkfs: ?[]const u8,
    debugfs: ?[]const u8,
    ext4_writer: Ext4Writer,
    metadata_rootfs_path: ?[]const u8 = null,
    temp_dir: []const u8,
    profile: RootfsBuildProfile,
    rootfs_storage: RootfsStoragePolicy = .chunked,
    cache_owned_output: bool = false,
};

fn buildRootFS(init: std.process.Init, allocator: std.mem.Allocator, opts: BuildOptions) !BuildResult {
    var client: std.http.Client = .{ .allocator = allocator, .io = init.io };
    defer client.deinit();
    var bearer_token: ?[]const u8 = null;

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
    const staging_start = profile.start();
    var materialize_temp = try prepareMaterializeTempDir(init.io, allocator, temp_dir);
    errdefer materialize_temp.deinit(init.io);
    profile.phase("staging_prepare", staging_start);

    const layers_dir = try std.fmt.allocPrint(allocator, "{s}/layers", .{temp_dir});
    try Io.Dir.cwd().createDirPath(init.io, layers_dir);

    const resolve_start = profile.start();
    const image_source = try fetchBuildImageSource(allocator, &client, &bearer_token, opts.ref);
    const image_ref = image_source.ref;
    const manifest_bytes = image_source.manifest_bytes;
    const manifest_digest = try resolveManifestDigest(allocator, &client, &bearer_token, image_ref, opts.platform, image_ref.digest, manifest_bytes);
    const resolved_image_ref = try digestImageRef(allocator, image_ref, manifest_digest);
    const selected_manifest_bytes = try selectedManifestBytes(allocator, &client, &bearer_token, image_ref, manifest_digest, manifest_bytes);
    profile.phase("oci_resolve_fetch", resolve_start);

    var manifest_parsed = try std.json.parseFromSlice(ImageManifest, allocator, selected_manifest_bytes, .{ .ignore_unknown_fields = true });
    defer manifest_parsed.deinit();
    const manifest = manifest_parsed.value;

    if (manifest.schemaVersion != 2) return error.UnsupportedManifestSchema;
    if (manifest.layers.len > max_rootfs_layers) return error.RootFSTooManyLayers;

    const config_start = profile.start();
    if (!oci.isSha256Digest(manifest.config.digest)) return error.UnsupportedDigest;
    const config_bytes = try registry.fetchBlobBytes(allocator, &client, &bearer_token, image_ref, manifest.config.digest, manifest.config.size);
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
        try registry.fetchBlobToFile(allocator, init.io, &client, &bearer_token, image_ref, layer.digest, layer.size, tar.max_content_bytes, layer_path);
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
        .mkfs = opts.mkfs,
        .debugfs = opts.debugfs,
        .ext4_writer = opts.ext4_writer,
        .metadata_rootfs_path = opts.metadata_rootfs_path,
        .temp_dir = materialize_temp.path,
        .profile = profile,
        .rootfs_storage = .chunked,
        .cache_owned_output = opts.cache_owned_output,
    });
    const cleanup_start = profile.start();
    materialize_temp.deinit(init.io);
    Io.Dir.cwd().deleteTree(init.io, temp_dir) catch {};
    profile.phase("temp_cleanup", cleanup_start);
    profile.finish();
    return .{
        .rootfs_blake3 = result.rootfs_blake3,
        .rootfs_storage = result.rootfs_storage orelse return error.BadManifest,
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
    const staging_start = profile.start();
    var materialize_temp = try prepareMaterializeTempDir(init.io, allocator, temp_dir);
    errdefer materialize_temp.deinit(init.io);
    profile.phase("staging_prepare", staging_start);

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
        .mkfs = opts.mkfs,
        .debugfs = opts.debugfs,
        .ext4_writer = opts.ext4_writer,
        .metadata_rootfs_path = opts.metadata_rootfs_path,
        .temp_dir = materialize_temp.path,
        .profile = profile,
        .rootfs_storage = opts.rootfs_storage,
        .cache_owned_output = opts.cache_owned_output,
    });
    const cleanup_start = profile.start();
    materialize_temp.deinit(init.io);
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
    const staging_start = profile.start();
    var materialize_temp = try prepareMaterializeTempDir(init.io, allocator, temp_dir);
    errdefer materialize_temp.deinit(init.io);
    profile.phase("staging_prepare", staging_start);

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
        .mkfs = opts.mkfs,
        .debugfs = opts.debugfs,
        .ext4_writer = opts.ext4_writer,
        .metadata_rootfs_path = opts.metadata_rootfs_path,
        .temp_dir = materialize_temp.path,
        .profile = profile,
        .rootfs_storage = opts.rootfs_storage,
        .cache_owned_output = opts.cache_owned_output,
    });
    const cleanup_start = profile.start();
    materialize_temp.deinit(init.io);
    Io.Dir.cwd().deleteTree(init.io, temp_dir) catch {};
    profile.phase("temp_cleanup", cleanup_start);
    profile.finish();
    return result;
}

const MaterializeTempDir = struct {
    path: []const u8,
    mountpoint: ?[]const u8 = null,

    fn deinit(self: *MaterializeTempDir, io: Io) void {
        if (self.mountpoint) |mountpoint| {
            runProcess(io, &.{ "/usr/bin/hdiutil", "detach", "-quiet", mountpoint }) catch |err| {
                std.log.warn("spore rootfs: failed to detach managed case-sensitive staging volume {s}: {s}", .{ mountpoint, @errorName(err) });
            };
        }
    }
};

fn prepareMaterializeTempDir(io: Io, allocator: std.mem.Allocator, temp_dir: []const u8) !MaterializeTempDir {
    var dir = try Io.Dir.cwd().openDir(io, temp_dir, .{ .iterate = true });
    defer dir.close(io);
    if (try tar.isCaseSensitiveDirectory(io, dir)) return .{ .path = temp_dir };

    if (comptime builtin.os.tag != .macos) return .{ .path = temp_dir };

    const image_path = try std.fmt.allocPrint(allocator, "{s}/case-sensitive.sparseimage", .{temp_dir});
    const mountpoint = try std.fmt.allocPrint(allocator, "{s}/case-sensitive", .{temp_dir});
    try Io.Dir.cwd().createDirPath(io, mountpoint);
    try runProcess(io, &.{
        "/usr/bin/hdiutil",
        "create",
        "-quiet",
        "-type",
        "SPARSE",
        "-size",
        "128g",
        "-fs",
        "Case-sensitive APFS",
        "-volname",
        "SporeVMRootFS",
        image_path,
    });
    errdefer Io.Dir.cwd().deleteFile(io, image_path) catch {};
    try runProcess(io, &.{ "/usr/bin/hdiutil", "attach", "-quiet", "-nobrowse", "-mountpoint", mountpoint, image_path });
    return .{ .path = mountpoint, .mountpoint = mountpoint };
}

fn runProcess(io: Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    defer child.kill(io);
    const term = try child.wait(io);
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return error.ProcessFailed;
}

fn materializeRootFS(init: std.process.Init, allocator: std.mem.Allocator, opts: MaterializeOptions) !MaterializeResult {
    if (opts.layers.len > max_rootfs_layers) return error.RootFSTooManyLayers;
    const layer_meta = try allocator.alloc(oci.LayerMetadata, opts.layers.len);
    const deterministic_ext4 = ext4.Determinism.fromDigest(opts.manifest_digest);
    const rootfs_blake3 = switch (opts.ext4_writer) {
        .native => try materializeRootFSNative(init, allocator, opts, layer_meta, deterministic_ext4),
        .external => try materializeRootFSExternal(init, allocator, opts, layer_meta, deterministic_ext4),
    };
    const rootfs_hex = try allocator.dupe(u8, &rootfs_blake3);
    const stat = try Io.Dir.cwd().statFile(init.io, opts.output, .{});
    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    defer allocator.free(cache_root);
    const artifact = spore.RootfsArtifactRef{
        .digest = try std.fmt.allocPrint(allocator, "{s}{s}", .{ spore.rootfs_digest_prefix, rootfs_hex }),
        .size = stat.size,
        .format = spore.rootfs_artifact_format_ext4,
    };
    const cache_start = opts.profile.start();
    const fast_install = if (trustedDigestHardlinkEligible(opts.cache_owned_output, opts.output, cache_root))
        try rootfs_cache.installExpectedPathAfterSourceVerifiedByHardlink(init.io, allocator, cache_root, opts.output, artifact)
    else
        null;
    if (fast_install) |_| {} else {
        _ = try rootfs_cache.installExpectedPathAfterSourceVerified(init.io, allocator, cache_root, opts.output, artifact, .{
            .source_must_not_be_symlink = false,
            .allow_hardlink = false,
        });
    }
    opts.profile.phase("digest_cache_install", cache_start);
    const rootfs_storage: ?spore.RootfsStorage = switch (opts.rootfs_storage) {
        .chunked => blk: {
            const preload_start = opts.profile.start();
            const preload_result = try rootfs_cas.preload(init.io, allocator, cache_root, artifact.digest, rootfs_cas.default_chunk_size);
            opts.profile.preloadPhase(preload_start, preload_result);
            break :blk rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload_result);
        },
        .flat => null,
    };

    const metadata_start = opts.profile.start();
    try ext4.ensureParentDir(init.io, opts.metadata);
    try rejectMetadataOutputAlias(init.io, opts.output, opts.metadata);
    const metadata = RootFSMetadata{
        .builder_version = builder_version,
        .ext4_writer = opts.ext4_writer.text(),
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
        .rootfs_blake3 = rootfs_hex,
        .rootfs_storage = rootfs_storage,
    };
    const metadata_json = try std.json.Stringify.valueAlloc(allocator, metadata, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
    try ext4.writeFileAtPath(init.io, opts.metadata, metadata_json);
    opts.profile.phase("metadata_write", metadata_start);

    return .{ .rootfs_blake3 = rootfs_blake3, .rootfs_storage = rootfs_storage };
}

fn materializeRootFSNative(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    opts: MaterializeOptions,
    layer_meta: []oci.LayerMetadata,
    deterministic_ext4: ext4.Determinism,
) ![chunk.ChunkId.hex_len]u8 {
    const native_layers = try allocator.alloc(tar.LayerInput, opts.layers.len);
    defer allocator.free(native_layers);

    const merge_start = opts.profile.start();
    for (opts.layers, 0..) |layer, i| {
        if (!oci.isSupportedLayerMediaType(layer.media_type)) return error.UnsupportedLayerMediaType;
        layer_meta[i] = .{ .media_type = layer.media_type, .digest = layer.digest };
        native_layers[i] = .{ .media_type = layer.media_type, .path = layer.path, .spill_dir = opts.temp_dir };
    }
    var tree = try tar.buildMergedTree(allocator, init.io, native_layers);
    defer tree.deinit(allocator);
    opts.profile.phase("tree_merge", merge_start);

    const required_dirs_start = opts.profile.start();
    try ensureRequiredMergedDir(allocator, &tree, "dev", 0o755);
    try ensureRequiredMergedDir(allocator, &tree, "proc", 0o755);
    try ensureRequiredMergedDir(allocator, &tree, "run", 0o755);
    try ensureRequiredMergedDir(allocator, &tree, "sys", 0o755);
    try ensureRequiredMergedDir(allocator, &tree, "tmp", 0o1777);
    try ensureMergedResolverPlaceholder(allocator, &tree);
    opts.profile.phase("rootfs_tree_finalize", required_dirs_start);

    const scan_start = opts.profile.start();
    const content_size = tree.contentSize();
    if (content_size > tar.max_content_bytes) return error.RootFSArchiveTooLarge;
    const inode_count = ext4.computeImageInodes(tree.entryCount());
    const image_size = ext4.computeImageSize(content_size);
    opts.profile.phase("ext4_size_scan", scan_start);

    const native_start = opts.profile.start();
    const result = try ext4_writer.emitFromMergedTree(allocator, init.io, &tree, opts.output, .{
        .image_size = image_size,
        .inode_count = @intCast(inode_count),
        .determinism = deterministic_ext4,
    });
    opts.profile.phase("native_ext4_emit", native_start);
    return result.blake3;
}

fn materializeRootFSExternal(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    opts: MaterializeOptions,
    layer_meta: []oci.LayerMetadata,
    deterministic_ext4: ext4.Determinism,
) ![chunk.ChunkId.hex_len]u8 {
    const mkfs = try resolveExt4Tool(allocator, init.io, init.environ_map, opts.mkfs, .mkfs);
    const debugfs = try resolveExt4Tool(allocator, init.io, init.environ_map, opts.debugfs, .debugfs);
    const rootfs_dir_path = try std.fmt.allocPrint(allocator, "{s}/rootfs", .{opts.temp_dir});
    var rootfs_dir = try Io.Dir.cwd().createDirPathOpen(init.io, rootfs_dir_path, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    });
    defer rootfs_dir.close(init.io);
    var owners = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &owners);
    var xattrs = XattrMap.init(allocator);
    defer xattrs_mod.deinit(allocator, &xattrs);
    const tar_options = tar.ApplyOptions{
        .case_sensitive_staging = try tar.isCaseSensitiveDirectory(init.io, rootfs_dir),
    };

    const extraction_start = opts.profile.start();
    for (opts.layers, 0..) |layer, i| {
        if (!oci.isSupportedLayerMediaType(layer.media_type)) return error.UnsupportedLayerMediaType;
        try tar.applyLayer(allocator, init.io, rootfs_dir, layer.path, layer.media_type, &owners, &xattrs, tar_options);
        if (try ext4.dirContentSize(init.io, rootfs_dir) > tar.max_content_bytes) return error.RootFSArchiveTooLarge;
        layer_meta[i] = .{ .media_type = layer.media_type, .digest = layer.digest };
    }
    opts.profile.phase("layer_extract_staging", extraction_start);

    const required_dirs_start = opts.profile.start();
    try ensureRequiredDir(allocator, init.io, rootfs_dir, &owners, "dev", 0o755);
    try ensureRequiredDir(allocator, init.io, rootfs_dir, &owners, "proc", 0o755);
    try ensureRequiredDir(allocator, init.io, rootfs_dir, &owners, "run", 0o755);
    try ensureRequiredDir(allocator, init.io, rootfs_dir, &owners, "sys", 0o755);
    try ensureRequiredDir(allocator, init.io, rootfs_dir, &owners, "tmp", 0o1777);
    try ensureResolverPlaceholder(allocator, init.io, rootfs_dir, &owners);
    try recordImplicitDirectoryOwnership(allocator, init.io, rootfs_dir, &owners, "");
    opts.profile.phase("rootfs_tree_finalize", required_dirs_start);

    const normalize_start = opts.profile.start();
    try ext4.normalizeHostTreeTimestamps(allocator, init.io, rootfs_dir, rootfs_dir_path);
    opts.profile.phase("host_metadata_normalize", normalize_start);

    const scan_start = opts.profile.start();
    const content_size = try ext4.dirContentSize(init.io, rootfs_dir);
    const inode_count = ext4.computeImageInodes(try ext4.dirEntryCount(init.io, rootfs_dir));
    const image_size = ext4.computeImageSize(content_size);
    opts.profile.phase("ext4_size_scan", scan_start);

    const create_start = opts.profile.start();
    try ext4.ensureParentDir(init.io, opts.output);
    try ext4.createEmptyFile(init.io, opts.output, image_size);
    opts.profile.phase("ext4_create_empty", create_start);
    const mkfs_start = opts.profile.start();
    try ext4.runMkfs(init, allocator, mkfs, rootfs_dir_path, opts.output, deterministic_ext4, inode_count);
    opts.profile.phase("mkfs_ext4", mkfs_start);
    const debugfs_script = try std.fmt.allocPrint(allocator, "{s}/debugfs-ownership.cmds", .{opts.temp_dir});
    const debugfs_start = opts.profile.start();
    try ext4.runDebugfsFinalize(init, allocator, debugfs, opts.output, debugfs_script, &owners, &xattrs, deterministic_ext4);
    opts.profile.phase("debugfs_finalize", debugfs_start);

    const blake3_start = opts.profile.start();
    const rootfs_blake3 = try ext4.blake3File(init.io, opts.output);
    opts.profile.phase("rootfs_blake3", blake3_start);
    return rootfs_blake3;
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
    client: *std.http.Client,
    bearer_token: *?[]const u8,
    image_ref: ImageRef,
    platform: Platform,
    digest: []const u8,
    manifest_bytes: []const u8,
) ![]const u8 {
    const selected = try oci.selectedManifestDigest(allocator, manifest_bytes, platform) orelse return digest;
    const bytes = try registry.fetchManifest(allocator, client, bearer_token, image_ref, selected);
    try oci.verifyDigestBytes(selected, bytes);
    return selected;
}

fn validateConfigPlatform(config: ImageConfig, platform: Platform) !void {
    const os = config.os orelse return error.UnsupportedPlatform;
    const arch = config.architecture orelse return error.UnsupportedPlatform;
    if (!std.mem.eql(u8, os, platform.os) or !std.mem.eql(u8, arch, platform.arch)) {
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
    if (!std.mem.eql(u8, value.platform.os, platform.os) or !std.mem.eql(u8, value.platform.arch, platform.arch)) {
        return error.UnsupportedPlatform;
    }
    const image_ref = try parseLocalDigestRef(value.resolved_image_ref);
    if (!std.mem.eql(u8, image_ref.digest, value.image_manifest_digest)) return error.LocalRefCacheMismatch;

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

    const path = try localRefCachePath(allocator, cache_root, raw_ref, resolved.platform);
    try ext4.ensureParentDir(io, path);
    var nonce_bytes: [8]u8 = undefined;
    io.random(&nonce_bytes);
    const nonce = std.mem.readInt(u64, &nonce_bytes, .little);
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.{x}.tmp", .{ path, nonce });
    defer Io.Dir.cwd().deleteFile(io, temp_path) catch {};
    const metadata = LocalRefMetadata{
        .ref = raw_ref,
        .resolved_image_ref = resolved.ref,
        .image_manifest_digest = resolved.manifest_digest,
        .platform = resolved.platform,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, metadata, .{ .whitespace = .indent_2 });
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
    h.update(platform.arch);
    h.update("\n");
    h.update(raw_ref);
    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{&hex});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ cache_root, "refs", "local", file_name });
}

pub fn rootfsCacheKeyAlloc(allocator: std.mem.Allocator, resolved: ResolvedImage) ![]u8 {
    var h = Sha256.init(.{});
    h.update(builder_version);
    h.update("\n");
    h.update(resolved.platform.os);
    h.update("/");
    h.update(resolved.platform.arch);
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
    ext4_writer_choice: Ext4Writer,
) !?[]const u8 {
    const cache_key = try rootfsCacheKeyAlloc(allocator, resolved);
    const rootfs_path = try std.fmt.allocPrint(allocator, "{s}/{s}.ext4", .{ cache_root, cache_key });
    const metadata_path = try cachedImageRootfsMetadataPath(allocator, cache_root, resolved);
    if (try cachedRootfsMetadataMatches(io, allocator, metadata_path, resolved, ext4_writer_choice) and try readablePath(io, rootfs_path)) {
        std.log.debug("spore rootfs: using cached rootfs {s} for {s}", .{ rootfs_path, resolved.ref });
        return rootfs_path;
    }
    return null;
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

    const digest = try std.fmt.allocPrint(allocator, "{s}{s}", .{ spore.rootfs_digest_prefix, value.rootfs_blake3 });
    errdefer allocator.free(digest);
    spore.validateRootfsDigest(digest) catch {
        allocator.free(digest);
        return null;
    };

    const stat = Io.Dir.cwd().statFile(io, rootfs_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => {
            allocator.free(digest);
            return null;
        },
        else => |e| return e,
    };
    if (stat.kind != .file or stat.size != value.rootfs_size) {
        allocator.free(digest);
        return null;
    }

    return .{
        .digest = digest,
        .size = value.rootfs_size,
        .format = spore.rootfs_artifact_format_ext4,
    };
}

fn cachedImportedRootfsBlake3(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    resolved: ResolvedImage,
    rootfs_path: []const u8,
    metadata_path: []const u8,
    storage_policy: RootfsStoragePolicy,
    ext4_writer_choice: Ext4Writer,
) !?[chunk.ChunkId.hex_len]u8 {
    if (!try cachedRootfsMetadataMatches(init.io, allocator, metadata_path, resolved, ext4_writer_choice)) return null;
    const artifact = (try cachedImageRootfsArtifact(init.io, allocator, metadata_path, rootfs_path)) orelse return null;
    defer allocator.free(artifact.digest);
    if (!try readablePath(init.io, rootfs_path)) return null;

    const rootfs_blake3 = rootfsArtifactDigestHexArray(artifact.digest) orelse return null;

    if (!try ensureImportedRootfsDigestCacheEntry(init.io, allocator, cache_root, rootfs_path, artifact)) return null;

    switch (storage_policy) {
        .flat => {},
        .chunked => {
            var storage_arena_state = std.heap.ArenaAllocator.init(allocator);
            defer storage_arena_state.deinit();
            const storage_arena = storage_arena_state.allocator();
            _ = try ensureImageRootfsStorage(init, storage_arena, cache_root, metadata_path, artifact, .{ .mmio_slot = 1 });
        },
    }

    std.log.debug("spore rootfs: using cached imported rootfs {s} for {s}", .{ rootfs_path, resolved.ref });
    return rootfs_blake3;
}

fn ensureImportedRootfsDigestCacheEntry(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    rootfs_path: []const u8,
    artifact: spore.RootfsArtifactRef,
) !bool {
    const rootfs = spore.Rootfs{ .device = .{ .mmio_slot = 1 }, .artifact = artifact };
    const fd = rootfs_cache.openTrustedFromCache(io, allocator, cache_root, rootfs) catch |err| switch (err) {
        error.RootFSDigestCacheMiss => {
            const installed = try rootfs_cache.cacheByDigestPath(io, allocator, cache_root, rootfs_path);
            defer allocator.free(installed.digest);
            return rootfsArtifactRefMatches(installed, artifact);
        },
        else => |e| return e,
    };
    _ = std.c.close(fd);
    return true;
}

fn rootfsArtifactRefMatches(a: spore.RootfsArtifactRef, b: spore.RootfsArtifactRef) bool {
    return a.size == b.size and
        std.mem.eql(u8, a.digest, b.digest) and
        std.mem.eql(u8, a.format, b.format);
}

fn rootfsArtifactDigestHexArray(artifact_digest: []const u8) ?[chunk.ChunkId.hex_len]u8 {
    const digest_hex = rootfsArtifactDigestSuffix(artifact_digest) orelse return null;
    if (digest_hex.len != chunk.ChunkId.hex_len) return null;
    _ = chunk.ChunkId.fromHex(digest_hex) catch return null;
    var rootfs_blake3: [chunk.ChunkId.hex_len]u8 = undefined;
    @memcpy(rootfs_blake3[0..], digest_hex);
    return rootfs_blake3;
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
    ext4_writer_choice: Ext4Writer,
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

    const rootfs_path = (try cachedImageRootfsPath(io, allocator, cache_root, resolved, ext4_writer_choice)) orelse return null;
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
    h.update(platform.arch);
    h.update("\n");
    h.update(requested_ref);
    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

fn platformTextAlloc(allocator: std.mem.Allocator, platform: Platform) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ platform.os, platform.arch });
}

pub fn buildCachedImageRootfs(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    resolved: ResolvedImage,
    ext4_writer_choice: Ext4Writer,
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
        .mkfs = null,
        .debugfs = null,
        .ext4_writer = ext4_writer_choice,
        .metadata_rootfs_path = rootfs_path,
        .temp_dir_root = temp_dir_root,
        .cache_owned_output = true,
    });
    try renameCachePath(init.io, temp_rootfs_path, rootfs_path);
    try renameCachePath(init.io, temp_metadata_path, metadata_path);

    std.log.debug("spore rootfs: cached rootfs {s}", .{rootfs_path});
    return rootfs_path;
}

pub fn ensureImageRootfsStorage(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    metadata_path: []const u8,
    artifact: spore.RootfsArtifactRef,
    device: spore.RootfsDevice,
) !spore.RootfsStorage {
    if (try readCachedRootfsStorage(init.io, allocator, metadata_path, artifact)) |cached| {
        var storage = cached;
        storage.device = device;
        if (storage.logical_size == artifact.size) {
            // Cached storage is trusted metadata for the hot image-create path.
            // `spore pack` validates and regenerates missing derived CAS chunks
            // from the flat digest artifact before bundle emission when those
            // chunks are actually needed.
            return storage;
        }
    }

    const preload = try rootfs_cas.preload(init.io, allocator, cache_root, artifact.digest, rootfs_cas.default_chunk_size);
    const storage = rootfs_cas.storageDescriptor(device, preload);
    try writeCachedRootfsStorage(init.io, allocator, metadata_path, artifact, storage);
    return storage;
}

const CachedRootfsStorageMetadata = struct {
    rootfs_size: u64,
    rootfs_blake3: []const u8,
    rootfs_storage: ?spore.RootfsStorage = null,
};

const CachedRootfsArtifactMetadata = struct {
    rootfs_path: []const u8,
    rootfs_size: u64,
    rootfs_blake3: []const u8,
};

fn rootfsArtifactDigestSuffix(artifact_digest: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, artifact_digest, spore.rootfs_digest_prefix)) return null;
    return artifact_digest[spore.rootfs_digest_prefix.len..];
}

fn cachedRootfsBlake3MatchesArtifact(rootfs_blake3: []const u8, artifact: spore.RootfsArtifactRef) bool {
    const artifact_rootfs_blake3 = rootfsArtifactDigestSuffix(artifact.digest) orelse return false;
    return std.mem.eql(u8, rootfs_blake3, artifact_rootfs_blake3);
}

fn readCachedRootfsStorage(
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
    if (!cachedRootfsBlake3MatchesArtifact(parsed.value.rootfs_blake3, artifact)) return null;
    const storage = parsed.value.rootfs_storage orelse return null;
    spore.validateRootfsStorageDescriptor(storage) catch return null;
    return try spore.cloneRootfsStorage(allocator, storage);
}

fn writeCachedRootfsStorage(
    io: Io,
    allocator: std.mem.Allocator,
    metadata_path: []const u8,
    artifact: spore.RootfsArtifactRef,
    storage: spore.RootfsStorage,
) !void {
    const metadata = try Io.Dir.cwd().readFileAlloc(io, metadata_path, allocator, .limited(max_rootfs_metadata_bytes));
    defer allocator.free(metadata);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parsed = try std.json.parseFromSlice(std.json.Value, arena, metadata, .{});
    const object = switch (parsed.value) {
        .object => |*object| object,
        else => return error.BadManifest,
    };
    const artifact_hex = try spore.diskDigestHex(artifact.digest);
    const size_json = try std.fmt.allocPrint(arena, "{d}", .{artifact.size});
    const size_value = try std.json.parseFromSlice(std.json.Value, arena, size_json, .{});
    const storage_json = try std.json.Stringify.valueAlloc(arena, storage, .{});
    const storage_value = try std.json.parseFromSlice(std.json.Value, arena, storage_json, .{});
    try object.put(arena, "rootfs_size", size_value.value);
    try object.put(arena, "rootfs_blake3", .{ .string = try arena.dupe(u8, artifact_hex) });
    try object.put(arena, "rootfs_storage", storage_value.value);
    const json = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try writeFileAtomicPath(io, allocator, metadata_path, json);
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
    ext4_writer_choice: Ext4Writer,
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
    if (!jsonStringEquals(object.get("ext4_writer"), ext4_writer_choice.text())) return false;
    if (!jsonStringEquals(object.get("resolved_image_ref"), resolved.ref)) return false;
    if (!jsonStringEquals(object.get("image_manifest_digest"), resolved.manifest_digest)) return false;
    const platform_value = object.get("platform") orelse return false;
    const platform_object = switch (platform_value) {
        .object => |platform_object| platform_object,
        else => return false,
    };
    return jsonStringEquals(platform_object.get("os"), resolved.platform.os) and
        jsonStringEquals(platform_object.get("arch"), resolved.platform.arch);
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

fn ensureRequiredDir(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *OwnershipMap,
    rel: []const u8,
    mode: u32,
) !void {
    const stat = root.statFile(io, rel, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => {
            try root.createDirPath(io, rel);
            const permissions = permissionsFromMode(mode, .default_dir);
            root.setFilePermissions(io, rel, permissions, .{ .follow_symlinks = false }) catch {};
            try ownership_mod.record(allocator, ownership, rel, .{ .uid = 0, .gid = 0 });
            return;
        },
        else => |e| return e,
    };
    if (stat.kind != .directory) return error.RequiredRootFSPathNotDirectory;
    root.setFilePermissions(io, rel, permissionsFromMode(mode, .default_dir), .{ .follow_symlinks = false }) catch {};
    try ownership_mod.record(allocator, ownership, rel, .{ .uid = 0, .gid = 0 });
}

fn ensureRequiredMergedDir(
    allocator: std.mem.Allocator,
    tree: *tar.MergedTree,
    rel: []const u8,
    mode: u32,
) !void {
    try tar.ensureMergedDirectory(allocator, tree, rel, mode, .{ .uid = 0, .gid = 0 });
}

fn ensureResolverPlaceholder(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *OwnershipMap,
) !void {
    if (root.statFile(io, "etc", .{ .follow_symlinks = false })) |stat| {
        if (stat.kind != .directory) return error.RequiredRootFSPathNotDirectory;
    } else |err| {
        switch (err) {
            error.FileNotFound => {
                const permissions = permissionsFromMode(0o755, .default_dir);
                try root.createDir(io, "etc", permissions);
                root.setFilePermissions(io, "etc", permissions, .{ .follow_symlinks = false }) catch {};
                try ownership_mod.record(allocator, ownership, "etc", .{ .uid = 0, .gid = 0 });
            },
            else => |e| return e,
        }
    }

    if (root.statFile(io, resolver_placeholder_path, .{ .follow_symlinks = false })) |_| {
        return;
    } else |err| {
        switch (err) {
            error.FileNotFound => {
                const permissions = permissionsFromMode(0o644, .default_file);
                var file = try root.createFile(io, resolver_placeholder_path, .{ .permissions = permissions });
                defer file.close(io);
                try file.writeStreamingAll(io, resolver_placeholder_bytes);
                file.setPermissions(io, permissions) catch {};
                try ownership_mod.record(allocator, ownership, resolver_placeholder_path, .{ .uid = 0, .gid = 0 });
                return;
            },
            else => |e| return e,
        }
    }
}

fn ensureMergedResolverPlaceholder(
    allocator: std.mem.Allocator,
    tree: *tar.MergedTree,
) !void {
    try tar.ensureMergedDirectory(allocator, tree, "etc", 0o755, .{ .uid = 0, .gid = 0 });
    try tar.ensureMergedFile(allocator, tree, resolver_placeholder_path, resolver_placeholder_bytes, 0o644, .{ .uid = 0, .gid = 0 });
}

fn recordImplicitDirectoryOwnership(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    ownership: *OwnershipMap,
    prefix: []const u8,
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const rel = if (prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        defer allocator.free(rel);

        if (!ownership.contains(rel)) {
            try ownership_mod.record(allocator, ownership, rel, .{ .uid = 0, .gid = 0 });
        }

        var child = try dir.openDir(io, entry.name, .{ .iterate = true });
        defer child.close(io);
        try recordImplicitDirectoryOwnership(allocator, io, child, ownership, rel);
    }
}

fn permissionsFromMode(mode: u32, fallback: Io.Dir.Permissions) Io.Dir.Permissions {
    if (@hasDecl(Io.Dir.Permissions, "fromMode")) {
        return Io.Dir.Permissions.fromMode(@intCast(mode & 0o7777));
    }
    return fallback;
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

test "rootfs build profile env is opt-in" {
    try std.testing.expect(!rootfsBuildProfileEnabled(null));
    try std.testing.expect(!rootfsBuildProfileEnabled(""));
    try std.testing.expect(rootfsBuildProfileEnabled("1"));
}

test "native ext4 writer env defaults native and fails closed" {
    try std.testing.expectEqual(Ext4Writer.native, try ext4WriterFromEnvValue(null));
    try std.testing.expectEqual(Ext4Writer.native, try ext4WriterFromEnvValue(""));
    try std.testing.expectEqual(Ext4Writer.external, try ext4WriterFromEnvValue("external"));
    try std.testing.expectEqual(Ext4Writer.native, try ext4WriterFromEnvValue("native"));
    try std.testing.expectError(error.UnsupportedExt4Writer, ext4WriterFromEnvValue("yes"));
}

test "trusted digest hardlink requires internal cache output ownership" {
    try std.testing.expect(!trustedDigestHardlinkEligible(false, "/tmp/sporevm-rootfs/user.ext4", "/tmp/sporevm-rootfs"));
    try std.testing.expect(trustedDigestHardlinkEligible(true, "/tmp/sporevm-rootfs/.image.ext4.tmp", "/tmp/sporevm-rootfs"));
    try std.testing.expect(!trustedDigestHardlinkEligible(true, "/tmp/sporevm-rootfs-sibling/.image.ext4.tmp", "/tmp/sporevm-rootfs"));
}

test "rootfs metadata omits absent rootfs storage" {
    const allocator = std.testing.allocator;
    const metadata = RootFSMetadata{
        .builder_version = builder_version,
        .ext4_writer = Ext4Writer.native.text(),
        .image_ref = "local/sporevm-app:dev",
        .resolved_image_ref = "local/sporevm-app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .image_manifest_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = .{},
        .config_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .config = .{},
        .layers = &.{},
        .deterministic = true,
        .ext4_uuid = "00000000-0000-0000-0000-000000000000",
        .ext4_hash_seed = "00000000000000000000000000000000",
        .rootfs_path = "rootfs.ext4",
        .rootfs_size = 4096,
        .rootfs_blake3 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
    const json = try std.json.Stringify.valueAlloc(allocator, metadata, .{
        .emit_null_optional_fields = false,
    });
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "rootfs_storage") == null);
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
    try std.testing.expectEqualStrings("arm64", parsed.platform.arch);
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
        "--rootfs-storage=flat",
    }, &stdout.writer);
    try std.testing.expectEqualStrings("layout.oci", parsed.input);
    try std.testing.expectEqualStrings("local/sporevm-app:dev", parsed.ref);
    try std.testing.expectEqual(.flat, parsed.rootfs_storage);

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
        "flat",
    }, &stdout.writer);
    try std.testing.expectEqualStrings("rootfs.tar", parsed.input);
    try std.testing.expectEqualStrings("local/sporevm-app:dev", parsed.ref);
    try std.testing.expectEqual(.flat, parsed.rootfs_storage);

    try std.testing.expectError(
        error.MissingRootFSTarPath,
        parseImportTarOptions(&.{ "--ref", "local/sporevm-app:dev" }, &stdout.writer),
    );
    try std.testing.expectError(
        error.LocalRefMustUseLocalRegistry,
        parseImportTarOptions(&.{ "rootfs.tar", "--ref", "ghcr.io/org/image:dev" }, &stdout.writer),
    );
}

test "rootfs tar digest uses sha256 digest refs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-tar-digest";
    const tar_path = tmp ++ "/rootfs.tar";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tar_path, .data = "tar bytes" });

    const digest = try sha256FileDigestAlloc(allocator, io, tar_path);
    defer allocator.free(digest);
    try std.testing.expect(oci.isSha256Digest(digest));
    try oci.verifyDigestFile(io, digest, tar_path);
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
    const preload_result = try rootfs_cas.preload(io, arena, cache_root, artifact.digest, 4096);
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
    const preload_result = try rootfs_cas.preload(io, arena, cache_root, artifact.digest, 4096);
    var manifest = try testRootfsAttachManifest(arena, artifact);
    manifest.disk.?.base = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    try spore.saveManifest(arena, spore_dir, manifest);

    try std.testing.expectError(
        error.BadManifest,
        attachPreloadedRootfsStorage(arena, spore_dir, artifact.digest, preload_result),
    );
}

fn testRootfsAttachManifest(allocator: std.mem.Allocator, artifact: spore.RootfsArtifactRef) !spore.Manifest {
    const memory_chunks = try allocator.alloc(?[]const u8, 1);
    memory_chunks[0] = null;
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
        .memory = .{ .chunk_size = spore.chunk_size, .chunks = memory_chunks },
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
        resolveLocalCachedRef(io, allocator, cache_root, "local/sporevm-app:dev", .{ .os = "linux", .arch = "amd64" }),
    );

    const arm64_path = try localRefCachePath(allocator, cache_root, "local/sporevm-app:dev", .{});
    const amd64_path = try localRefCachePath(allocator, cache_root, "local/sporevm-app:dev", .{ .os = "linux", .arch = "amd64" });
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
        .platform = .{ .os = "linux", .arch = "amd64" },
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
    try std.testing.expect(!try cachedRootfsMetadataMatches(io, allocator, metadata_path, resolved, .native));
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = metadata_path,
        .data =
        \\{
        \\  "builder_version": "sporevm-rootfs-v5",
        \\  "ext4_writer": "native",
        \\  "resolved_image_ref": "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "image_manifest_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "platform": {"os": "linux", "arch": "arm64"}
        \\}
        ,
    });
    try std.testing.expect(try cachedRootfsMetadataMatches(io, allocator, metadata_path, resolved, .native));
    try std.testing.expect(!try cachedRootfsMetadataMatches(io, allocator, metadata_path, resolved, .external));

    try std.testing.expect(!try cachedRootfsMetadataMatches(io, allocator, metadata_path, .{
        .ref = "docker.io/library/alpine@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .manifest_digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .platform = .{},
    }, .native));

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = "not json" });
    try std.testing.expect(!try cachedRootfsMetadataMatches(io, allocator, metadata_path, resolved, .native));
}

test "image rootfs cache can replace same-key artifacts for writer escape hatch" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-image-cache-writer-replace";
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
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "native" });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = metadata_path,
        .data =
        \\{
        \\  "builder_version": "sporevm-rootfs-v5",
        \\  "ext4_writer": "native",
        \\  "resolved_image_ref": "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "image_manifest_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "platform": {"os": "linux", "arch": "arm64"}
        \\}
        ,
    });

    try std.testing.expect((try cachedImageRootfsPath(io, arena, cache_root, resolved, .native)) != null);
    try std.testing.expect((try cachedImageRootfsPath(io, arena, cache_root, resolved, .external)) == null);

    const temp_rootfs_path = tmp ++ "/external.ext4.tmp";
    const temp_metadata_path = tmp ++ "/external.json.tmp";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = temp_rootfs_path, .data = "external" });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = temp_metadata_path,
        .data =
        \\{
        \\  "builder_version": "sporevm-rootfs-v5",
        \\  "ext4_writer": "external",
        \\  "resolved_image_ref": "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "image_manifest_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "platform": {"os": "linux", "arch": "arm64"}
        \\}
        ,
    });
    try renameCachePath(io, temp_rootfs_path, rootfs_path);
    try renameCachePath(io, temp_metadata_path, metadata_path);

    try std.testing.expect((try cachedImageRootfsPath(io, arena, cache_root, resolved, .native)) == null);
    try std.testing.expectEqualStrings(rootfs_path, (try cachedImageRootfsPath(io, arena, cache_root, resolved, .external)).?);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, rootfs_path, arena, .limited(32));
    try std.testing.expectEqualStrings("external", bytes);
}

test "image rootfs metadata supplies cached artifact identity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-image-cache-artifact";
    const metadata_path = tmp ++ "/metadata.json";
    const rootfs_path = tmp ++ "/rootfs.ext4";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });

    const artifact = try rootfs_cache.hashPath(io, arena, rootfs_path);
    const rootfs_hex = artifact.digest[spore.rootfs_digest_prefix.len..];
    const metadata_json = try std.fmt.allocPrint(arena,
        \\{{
        \\  "rootfs_path": "{s}",
        \\  "rootfs_size": {d},
        \\  "rootfs_blake3": "{s}",
        \\  "unknown": true
        \\}}
    , .{ rootfs_path, artifact.size, rootfs_hex });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = metadata_json });

    const cached = (try cachedImageRootfsArtifact(io, arena, metadata_path, rootfs_path)).?;
    try std.testing.expectEqualStrings(artifact.digest, cached.digest);
    try std.testing.expectEqual(artifact.size, cached.size);
    try std.testing.expectEqualStrings(spore.rootfs_artifact_format_ext4, cached.format);

    try std.testing.expect((try cachedImageRootfsArtifact(io, arena, metadata_path, tmp ++ "/other.ext4")) == null);

    const wrong_size_json = try std.fmt.allocPrint(arena,
        \\{{
        \\  "rootfs_path": "{s}",
        \\  "rootfs_size": {d},
        \\  "rootfs_blake3": "{s}"
        \\}}
    , .{ rootfs_path, artifact.size + 1, rootfs_hex });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = wrong_size_json });
    try std.testing.expect((try cachedImageRootfsArtifact(io, arena, metadata_path, rootfs_path)) == null);

    const bad_digest_json = try std.fmt.allocPrint(arena,
        \\{{
        \\  "rootfs_path": "{s}",
        \\  "rootfs_size": {d},
        \\  "rootfs_blake3": "not-a-blake3-digest"
        \\}}
    , .{ rootfs_path, artifact.size });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = bad_digest_json });
    try std.testing.expect((try cachedImageRootfsArtifact(io, arena, metadata_path, rootfs_path)) == null);
}

test "image rootfs artifact metadata rejects symlink rootfs path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-image-cache-artifact-symlink";
    const metadata_path = tmp ++ "/metadata.json";
    const target_path = tmp ++ "/target.ext4";
    const rootfs_path = tmp ++ "/rootfs.ext4";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = target_path, .data = "rootfs bytes" });
    const target_z = try arena.dupeZ(u8, target_path);
    const rootfs_z = try arena.dupeZ(u8, rootfs_path);
    if (std.c.symlink(target_z, rootfs_z) != 0) return error.SkipZigTest;

    const artifact = try rootfs_cache.hashPath(io, arena, target_path);
    const rootfs_hex = artifact.digest[spore.rootfs_digest_prefix.len..];
    const metadata_json = try std.fmt.allocPrint(arena,
        \\{{
        \\  "rootfs_path": "{s}",
        \\  "rootfs_size": {d},
        \\  "rootfs_blake3": "{s}"
        \\}}
    , .{ rootfs_path, artifact.size, rootfs_hex });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = metadata_json });

    try std.testing.expect((try cachedImageRootfsArtifact(io, arena, metadata_path, rootfs_path)) == null);
}

test "imported rootfs flat cache hit reuses metadata without rootfs storage" {
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

    const rootfs_hash = try rootfs_cache.hashPath(io, arena, rootfs_path);
    const artifact = spore.RootfsArtifactRef{ .digest = rootfs_hash.digest, .size = rootfs_hash.size };
    const expected = rootfsArtifactDigestHexArray(artifact.digest).?;
    const rootfs_hex = rootfsArtifactDigestSuffix(artifact.digest).?;
    const metadata_json = try std.fmt.allocPrint(arena,
        \\{{
        \\  "builder_version": "{s}",
        \\  "ext4_writer": "native",
        \\  "image_ref": "local/example:dev",
        \\  "resolved_image_ref": "{s}",
        \\  "image_manifest_digest": "{s}",
        \\  "platform": {{"os": "{s}", "arch": "{s}"}},
        \\  "rootfs_path": "{s}",
        \\  "rootfs_size": {d},
        \\  "rootfs_blake3": "{s}"
        \\}}
    , .{ builder_version, resolved.ref, resolved.manifest_digest, resolved.platform.os, resolved.platform.arch, rootfs_path, artifact.size, rootfs_hex });
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

    const hit = (try cachedImportedRootfsBlake3(init, arena, cache_root, resolved, rootfs_path, metadata_path, .flat, .native)).?;
    try std.testing.expectEqualSlices(u8, expected[0..], hit[0..]);
    try std.testing.expect((try cachedImportedRootfsBlake3(init, arena, cache_root, resolved, rootfs_path, metadata_path, .flat, .external)) == null);
    const updated_metadata = try Io.Dir.cwd().readFileAlloc(io, metadata_path, arena, .limited(max_rootfs_metadata_bytes));
    try std.testing.expect(std.mem.indexOf(u8, updated_metadata, "\"rootfs_storage\"") == null);

    const digest_path = try rootfs_cache.digestPath(arena, cache_root, artifact.digest);
    try std.testing.expect(try rootfs_cache.regularFileNoSymlink(io, digest_path));
}

test "imported rootfs chunked cache hit upgrades flat metadata storage" {
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

    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
    const expected = rootfsArtifactDigestHexArray(artifact.digest).?;
    const rootfs_hex = rootfsArtifactDigestSuffix(artifact.digest).?;
    const metadata_json = try std.fmt.allocPrint(arena,
        \\{{
        \\  "builder_version": "{s}",
        \\  "ext4_writer": "native",
        \\  "image_ref": "local/example:dev",
        \\  "resolved_image_ref": "{s}",
        \\  "image_manifest_digest": "{s}",
        \\  "platform": {{"os": "{s}", "arch": "{s}"}},
        \\  "rootfs_path": "{s}",
        \\  "rootfs_size": {d},
        \\  "rootfs_blake3": "{s}"
        \\}}
    , .{ builder_version, resolved.ref, resolved.manifest_digest, resolved.platform.os, resolved.platform.arch, rootfs_path, artifact.size, rootfs_hex });
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

    const hit = (try cachedImportedRootfsBlake3(init, arena, cache_root, resolved, rootfs_path, metadata_path, .chunked, .native)).?;
    try std.testing.expectEqualSlices(u8, expected[0..], hit[0..]);
    const updated_metadata = try Io.Dir.cwd().readFileAlloc(io, metadata_path, arena, .limited(max_rootfs_metadata_bytes));
    try std.testing.expect(std.mem.indexOf(u8, updated_metadata, "\"rootfs_storage\"") != null);
    const storage = (try readCachedRootfsStorage(io, arena, metadata_path, artifact)).?;
    try std.testing.expect(try rootfs_cas.storageComplete(io, arena, cache_root, storage));
}

test "imported rootfs cache treats metadata identity mismatch as miss" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-rootfs-import-cache-identity-miss";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try ensureDirPath(io, cache_root);

    const cached_resolved = ResolvedImage{
        .ref = "local/example@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        .manifest_digest = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        .platform = .{},
    };
    const requested_resolved = ResolvedImage{
        .ref = "local/example@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        .manifest_digest = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        .platform = .{},
    };
    const cache_key = try rootfsCacheKeyAlloc(arena, requested_resolved);
    const rootfs_path = try std.fmt.allocPrint(arena, "{s}/{s}.ext4", .{ cache_root, cache_key });
    const metadata_path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ cache_root, cache_key });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "cached rootfs bytes" });

    const rootfs_hash = try rootfs_cache.hashPath(io, arena, rootfs_path);
    const artifact = spore.RootfsArtifactRef{ .digest = rootfs_hash.digest, .size = rootfs_hash.size };
    const rootfs_hex = rootfsArtifactDigestSuffix(artifact.digest).?;
    const metadata_json = try std.fmt.allocPrint(arena,
        \\{{
        \\  "builder_version": "{s}",
        \\  "ext4_writer": "native",
        \\  "image_ref": "local/example:dev",
        \\  "resolved_image_ref": "{s}",
        \\  "image_manifest_digest": "{s}",
        \\  "platform": {{"os": "{s}", "arch": "{s}"}},
        \\  "rootfs_path": "{s}",
        \\  "rootfs_size": {d},
        \\  "rootfs_blake3": "{s}"
        \\}}
    , .{ builder_version, cached_resolved.ref, cached_resolved.manifest_digest, cached_resolved.platform.os, cached_resolved.platform.arch, rootfs_path, artifact.size, rootfs_hex });
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

    try std.testing.expect((try cachedImportedRootfsBlake3(init, arena, cache_root, requested_resolved, rootfs_path, metadata_path, .chunked, .native)) == null);
    const updated_metadata = try Io.Dir.cwd().readFileAlloc(io, metadata_path, arena, .limited(max_rootfs_metadata_bytes));
    try std.testing.expect(std.mem.indexOf(u8, updated_metadata, "\"rootfs_storage\"") == null);
    const digest_path = try rootfs_cache.digestPath(arena, cache_root, artifact.digest);
    try std.testing.expect(!try rootfs_cache.regularFileNoSymlink(io, digest_path));
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
    }, .native));
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

    const changed_platform = try imageRefCacheKeyAlloc(allocator, "docker.io/library/alpine:3.20", .{ .os = "linux", .arch = "amd64" });
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
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = metadata_path,
        .data =
        \\{
        \\  "builder_version": "sporevm-rootfs-v5",
        \\  "ext4_writer": "native",
        \\  "resolved_image_ref": "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "image_manifest_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "platform": {"os": "linux", "arch": "arm64"}
        \\}
        ,
    });

    try writeImageRefCacheRecord(io, arena, cache_root, "docker.io/library/alpine:3.20", resolved);
    const hit = (try cachedImageRefRootfsPath(io, arena, cache_root, "docker.io/library/alpine:3.20", .{}, .native)).?;
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
        \\  "builder_version": "sporevm-rootfs-v5",
        \\  "resolved_image_ref": "{s}",
        \\  "image_manifest_digest": "{s}",
        \\  "rootfs_cache_key": "{s}",
        \\  "resolved_at_unix": 123
        \\}}
    , .{ resolved.ref, resolved.manifest_digest, cache_key });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = record_path, .data = bad_record });
    try std.testing.expect((try cachedImageRefRootfsPath(io, arena, cache_root, "docker.io/library/alpine:3.20", .{}, .native)) == null);

    const bad_resolved_ref_record = try std.fmt.allocPrint(arena,
        \\{{
        \\  "version": 1,
        \\  "requested_ref": "docker.io/library/alpine:3.20",
        \\  "platform": "linux/arm64",
        \\  "builder_version": "sporevm-rootfs-v5",
        \\  "resolved_image_ref": "docker.io/library/alpine:not-a-digest",
        \\  "image_manifest_digest": "{s}",
        \\  "rootfs_cache_key": "{s}",
        \\  "resolved_at_unix": 123
        \\}}
    , .{ resolved.manifest_digest, cache_key });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = record_path, .data = bad_resolved_ref_record });
    try std.testing.expect((try cachedImageRefRootfsPath(io, arena, cache_root, "docker.io/library/alpine:3.20", .{}, .native)) == null);

    try writeImageRefCacheRecord(io, arena, cache_root, "docker.io/library/alpine:3.20", resolved);
    try std.testing.expect((try cachedImageRefRootfsPath(io, arena, cache_root, "docker.io/library/alpine:3.20", .{}, .native)) == null);
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
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = metadata_path,
        .data =
        \\{
        \\  "builder_version": "sporevm-rootfs-v5",
        \\  "resolved_image_ref": "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "image_manifest_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "platform": {"os": "linux", "arch": "arm64"}
        \\}
        ,
    });

    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, cache_root, rootfs_path);
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

    const first = try ensureImageRootfsStorage(init, arena, cache_root, metadata_path, artifact, .{ .mmio_slot = 1 });
    try std.testing.expect(try rootfs_cas.storageComplete(io, arena, cache_root, first));
    const recorded = (try readCachedRootfsStorage(io, arena, metadata_path, artifact)).?;
    try std.testing.expectEqualStrings(first.index_digest, recorded.index_digest);

    const artifact_hex = try spore.diskDigestHex(artifact.digest);
    const wrong_rootfs_blake3 = try arena.dupe(u8, artifact_hex);
    wrong_rootfs_blake3[0] = if (wrong_rootfs_blake3[0] == '0') '1' else '0';
    const stale_storage_digest = try arena.dupe(u8, first.index_digest);
    stale_storage_digest[spore.rootfs_digest_prefix.len] = if (stale_storage_digest[spore.rootfs_digest_prefix.len] == '0') '1' else '0';
    const stale_metadata = try std.fmt.allocPrint(arena,
        \\{{
        \\  "rootfs_size": {d},
        \\  "rootfs_blake3": "{s}",
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
        wrong_rootfs_blake3,
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
    const regenerated = try ensureImageRootfsStorage(init, arena, cache_root, metadata_path, artifact, .{ .mmio_slot = 3 });
    try std.testing.expectEqualStrings(first.index_digest, regenerated.index_digest);
    try std.testing.expect(!std.mem.eql(u8, stale_storage_digest, regenerated.index_digest));
    try std.testing.expectEqual(@as(u32, 3), regenerated.device.mmio_slot);

    const object_id = chunk.ChunkId.fromContents(rootfs_bytes);
    const object_hex = object_id.toHex();
    const object_digest = try std.fmt.allocPrint(arena, "{s}{s}", .{ spore.rootfs_digest_prefix, object_hex[0..] });
    const object_path = try rootfs_cas.manifestObjectPath(arena, cache_root, object_digest);
    try Io.Dir.cwd().deleteFile(io, object_path);
    try std.testing.expect(!try rootfs_cas.storageComplete(io, arena, cache_root, first));

    const digest_path = try rootfs_cache.digestPath(arena, cache_root, artifact.digest);
    try Io.Dir.cwd().deleteFile(io, digest_path);
    const second = try ensureImageRootfsStorage(init, arena, cache_root, metadata_path, artifact, .{ .mmio_slot = 2 });
    try std.testing.expectEqualStrings(first.index_digest, second.index_digest);
    try std.testing.expectEqual(@as(u32, 2), second.device.mmio_slot);
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

test "required mount directories reject symlinks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-required-dir-symlink";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    try root.createDirPath(io, "target");
    try root.symLink(io, "target", "dev", .{});
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);

    try std.testing.expectError(
        error.RequiredRootFSPathNotDirectory,
        ensureRequiredDir(allocator, io, root, &ownership, "dev", 0o755),
    );
}

test "rootfs materialization creates missing resolver placeholder" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-resolver-placeholder";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    });
    defer root.close(io);
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);

    try ensureResolverPlaceholder(allocator, io, root, &ownership);

    const etc = try root.statFile(io, "etc", .{ .follow_symlinks = false });
    const resolv = try root.statFile(io, resolver_placeholder_path, .{ .follow_symlinks = false });
    try std.testing.expect(etc.kind == .directory);
    try std.testing.expect(resolv.kind == .file);
    const bytes = try root.readFileAlloc(io, resolver_placeholder_path, allocator, .limited(256));
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings(resolver_placeholder_bytes, bytes);
    try std.testing.expectEqual(@as(u32, 0), ownership.get("etc").?.uid);
    try std.testing.expectEqual(@as(u32, 0), ownership.get(resolver_placeholder_path).?.gid);
}

test "rootfs materialization preserves existing resolver file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-resolver-preserve-file";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    });
    defer root.close(io);
    try root.createDirPath(io, "etc");
    try root.writeFile(io, .{ .sub_path = resolver_placeholder_path, .data = "nameserver 1.1.1.1\n" });
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);

    try ensureResolverPlaceholder(allocator, io, root, &ownership);

    const bytes = try root.readFileAlloc(io, resolver_placeholder_path, allocator, .limited(256));
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("nameserver 1.1.1.1\n", bytes);
    try std.testing.expect(ownership.get(resolver_placeholder_path) == null);
}

test "rootfs materialization preserves existing resolver symlink" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-resolver-preserve-symlink";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    });
    defer root.close(io);
    try root.createDirPath(io, "etc");
    try root.symLink(io, "../run/systemd/resolve/resolv.conf", resolver_placeholder_path, .{});
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);

    try ensureResolverPlaceholder(allocator, io, root, &ownership);

    const stat = try root.statFile(io, resolver_placeholder_path, .{ .follow_symlinks = false });
    try std.testing.expect(stat.kind == .sym_link);
    try std.testing.expect(ownership.get(resolver_placeholder_path) == null);
}

test "rootfs materialization does not follow etc symlink for resolver placeholder" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-resolver-etc-symlink";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    });
    defer root.close(io);
    try root.createDirPath(io, "target");
    try root.symLink(io, "target", "etc", .{});
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);

    try std.testing.expectError(
        error.RequiredRootFSPathNotDirectory,
        ensureResolverPlaceholder(allocator, io, root, &ownership),
    );
    try std.testing.expectError(
        error.FileNotFound,
        root.statFile(io, "target/resolv.conf", .{ .follow_symlinks = false }),
    );
}

test "direct image config must match requested platform" {
    try validateConfigPlatform(.{ .os = "linux", .architecture = "arm64" }, .{ .os = "linux", .arch = "arm64" });
    try std.testing.expectError(
        error.UnsupportedPlatform,
        validateConfigPlatform(.{ .os = "linux", .architecture = "amd64" }, .{ .os = "linux", .arch = "arm64" }),
    );
    try std.testing.expectError(
        error.UnsupportedPlatform,
        validateConfigPlatform(.{ .os = null, .architecture = "arm64" }, .{ .os = "linux", .arch = "arm64" }),
    );
}

test "ext4 tool detection finds executable on PATH" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-tool-path";
    const tool_path = tmp ++ "/mkfs.ext4";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = tool_path,
        .data = "#!/bin/sh\n",
        .flags = .{ .permissions = .executable_file },
    });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("PATH", tmp);

    const found = try detectToolPath(allocator, io, &env, "mkfs.ext4") orelse return error.TestExpectedEqual;
    defer allocator.free(found);
    try std.testing.expectEqualStrings(tool_path, found);
}

test "ext4 tool detection checks Homebrew e2fsprogs prefix" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-tool-homebrew";
    const prefix = tmp ++ "/brew";
    const tool_dir = prefix ++ "/opt/e2fsprogs/sbin";
    const tool_path = tool_dir ++ "/debugfs";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tool_dir);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = tool_path,
        .data = "#!/bin/sh\n",
        .flags = .{ .permissions = .executable_file },
    });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOMEBREW_PREFIX", prefix);

    const found = try detectToolPath(allocator, io, &env, "debugfs") orelse return error.TestExpectedEqual;
    defer allocator.free(found);
    try std.testing.expectEqualStrings(tool_path, found);
}

fn writeTestTar(allocator: std.mem.Allocator, io: Io, path: []const u8, name: []const u8, data: []const u8) !void {
    var tar_bytes = std.ArrayList(u8).empty;
    defer tar_bytes.deinit(allocator);
    try tar_bytes.appendNTimes(allocator, 0, 512);
    writeTestTarHeader(tar_bytes.items[0..512], name, '0', data.len);
    try tar_bytes.appendSlice(allocator, data);
    const padding = (512 - (data.len % 512)) % 512;
    try tar_bytes.appendNTimes(allocator, 0, padding + 1024);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = tar_bytes.items });
}

fn writeTestTarHeader(header: []u8, name: []const u8, kind: u8, size: u64) void {
    std.debug.assert(header.len == 512);
    std.debug.assert(name.len <= 100);
    @memset(header, 0);
    @memcpy(header[0..name.len], name);
    writeTestTarOctal(header[100..108], if (kind == '5') 0o755 else 0o644);
    writeTestTarOctal(header[108..116], 0);
    writeTestTarOctal(header[116..124], 0);
    writeTestTarOctal(header[124..136], size);
    writeTestTarOctal(header[136..148], 0);
    @memset(header[148..156], ' ');
    header[156] = kind;
    @memcpy(header[257..263], "ustar\x00");
    @memcpy(header[263..265], "00");
    var sum: u64 = 0;
    for (header[0..512]) |b| sum += b;
    writeTestTarOctal(header[148..156], sum);
}

fn writeTestTarOctal(field: []u8, value: u64) void {
    @memset(field, 0);
    var remaining = value;
    var index = field.len - 2;
    while (true) {
        field[index] = @intCast('0' + (remaining & 7));
        remaining >>= 3;
        if (remaining == 0 or index == 0) break;
        index -= 1;
    }
}
