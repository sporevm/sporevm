//! OCI image to ext4 rootfs builder.
//!
//! This is intentionally a builder utility, not part of the VMM monitor
//! process. OCI manifests and layer tar streams are attacker-influenced input,
//! so layer application is strict and fail-closed.

const std = @import("std");
const chunk = @import("chunk.zig");
const ext4 = @import("rootfs/ext4.zig");
const oci = @import("rootfs/oci.zig");
const ownership_mod = @import("rootfs/ownership.zig");
const registry = @import("rootfs/registry.zig");

const Io = std.Io;

const max_rootfs_content_bytes: u64 = 32 << 30;
const max_rootfs_archive_entries: u64 = 1_000_000;
const max_rootfs_layers: usize = 512;
const max_pax_header_bytes: u64 = 1 << 20;

const usage =
    \\Usage: spore rootfs <command>
    \\
    \\Commands:
    \\  build <image@sha256:...> --output <rootfs.ext4>
    \\
    \\Options:
    \\  --platform <os/arch>       Target platform (default: linux/arm64)
    \\  --metadata <path>          Metadata sidecar path (default: <output>.json)
    \\  --mkfs <path>              mkfs.ext4 binary (default: auto-detect)
    \\  --debugfs <path>           debugfs binary (default: auto-detect)
    \\
;

pub fn run(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "help")) {
        try stdout.writeAll(usage);
        return;
    }
    if (std.mem.eql(u8, args[0], "build")) {
        try runBuild(init, args[1..], stdout);
        return;
    }
    try stdout.print("unknown rootfs command: {s}\n\n", .{args[0]});
    try stdout.writeAll(usage);
    try stdout.flush();
    std.process.exit(2);
}

const ParsedBuildOptions = struct {
    ref: []const u8,
    output: []const u8,
    metadata: []const u8,
    platform: Platform = .{},
    mkfs: ?[]const u8 = null,
    debugfs: ?[]const u8 = null,
};

const BuildOptions = struct {
    ref: []const u8,
    output: []const u8,
    metadata: []const u8,
    platform: Platform = .{},
    mkfs: []const u8,
    debugfs: []const u8,
};

fn runBuild(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    const arena = init.arena.allocator();
    const parsed = try parseBuildOptions(arena, args, stdout);
    const opts = BuildOptions{
        .ref = parsed.ref,
        .output = parsed.output,
        .metadata = parsed.metadata,
        .platform = parsed.platform,
        .mkfs = try resolveExt4Tool(arena, init.io, init.environ_map, parsed.mkfs, .mkfs),
        .debugfs = try resolveExt4Tool(arena, init.io, init.environ_map, parsed.debugfs, .debugfs),
    };
    const result = try buildRootFS(init, arena, opts);
    try stdout.print("rootfs: {s}\nmetadata: {s}\nsource: {s}\nrootfs_blake3: {s}\n", .{
        opts.output,
        opts.metadata,
        opts.ref,
        result.rootfs_blake3,
    });
}

fn parseBuildOptions(allocator: std.mem.Allocator, args: []const []const u8, stdout: *Io.Writer) !ParsedBuildOptions {
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
    return .{
        .ref = image_ref orelse return error.MissingImageReference,
        .output = out,
        .metadata = meta,
        .platform = platform,
        .mkfs = mkfs,
        .debugfs = debugfs,
    };
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
const ImageManifest = oci.ImageManifest;
const ImageConfig = oci.ImageConfig;

const BuildResult = struct {
    rootfs_blake3: [chunk.ChunkId.hex_len]u8,
};

const Ownership = ownership_mod.Ownership;
const OwnershipMap = ownership_mod.Map;

const RootFSMetadata = struct {
    builder_version: []const u8,
    image_ref: []const u8,
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
};

fn buildRootFS(init: std.process.Init, allocator: std.mem.Allocator, opts: BuildOptions) !BuildResult {
    const image_ref = try ImageRef.parse(opts.ref);

    var client: std.http.Client = .{ .allocator = allocator, .io = init.io };
    defer client.deinit();
    var bearer_token: ?[]const u8 = null;

    const temp_id = Io.Clock.real.now(init.io).nanoseconds;
    const temp_dir = try std.fmt.allocPrint(allocator, ".zig-cache/spore-rootfs-{d}", .{temp_id});
    defer Io.Dir.cwd().deleteTree(init.io, temp_dir) catch {};
    try Io.Dir.cwd().createDirPath(init.io, temp_dir);

    const rootfs_dir_path = try std.fmt.allocPrint(allocator, "{s}/rootfs", .{temp_dir});
    var rootfs_dir = try Io.Dir.cwd().createDirPathOpen(init.io, rootfs_dir_path, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    });
    defer rootfs_dir.close(init.io);
    var owners = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &owners);

    const layers_dir = try std.fmt.allocPrint(allocator, "{s}/layers", .{temp_dir});
    try Io.Dir.cwd().createDirPath(init.io, layers_dir);

    const manifest_bytes = try registry.fetchManifest(allocator, &client, &bearer_token, image_ref, image_ref.digest);
    try oci.verifyDigestBytes(image_ref.digest, manifest_bytes);
    const manifest_digest = try resolveManifestDigest(allocator, &client, &bearer_token, image_ref, opts.platform, image_ref.digest, manifest_bytes);
    const selected_manifest_bytes = if (std.mem.eql(u8, manifest_digest, image_ref.digest))
        manifest_bytes
    else
        try registry.fetchManifest(allocator, &client, &bearer_token, image_ref, manifest_digest);
    try oci.verifyDigestBytes(manifest_digest, selected_manifest_bytes);

    var manifest_parsed = try std.json.parseFromSlice(ImageManifest, allocator, selected_manifest_bytes, .{ .ignore_unknown_fields = true });
    defer manifest_parsed.deinit();
    const manifest = manifest_parsed.value;

    if (manifest.schemaVersion != 2) return error.UnsupportedManifestSchema;
    if (manifest.layers.len > max_rootfs_layers) return error.RootFSTooManyLayers;

    if (!oci.isSha256Digest(manifest.config.digest)) return error.UnsupportedDigest;
    const config_bytes = try registry.fetchBlobBytes(allocator, &client, &bearer_token, image_ref, manifest.config.digest, manifest.config.size);
    try oci.verifyDigestBytes(manifest.config.digest, config_bytes);
    var config_parsed = try std.json.parseFromSlice(ImageConfig, allocator, config_bytes, .{ .ignore_unknown_fields = true });
    defer config_parsed.deinit();
    try validateConfigPlatform(config_parsed.value, opts.platform);

    const layer_meta = try allocator.alloc(oci.LayerMetadata, manifest.layers.len);
    for (manifest.layers, 0..) |layer, i| {
        if (!oci.isSupportedLayerMediaType(layer.mediaType)) return error.UnsupportedLayerMediaType;
        const layer_path = try layerBlobPath(allocator, layers_dir, layer.digest);
        try registry.fetchBlobToFile(allocator, init.io, &client, &bearer_token, image_ref, layer.digest, layer.size, max_rootfs_content_bytes, layer_path);
        try oci.verifyDigestFile(init.io, layer.digest, layer_path);
        try applyLayer(allocator, init.io, rootfs_dir, layer_path, layer.mediaType, &owners);
        if (try ext4.dirContentSize(init.io, rootfs_dir) > max_rootfs_content_bytes) return error.RootFSArchiveTooLarge;
        layer_meta[i] = .{ .media_type = layer.mediaType, .digest = layer.digest };
    }

    try ensureRequiredDir(allocator, init.io, rootfs_dir, &owners, "dev", 0o755);
    try ensureRequiredDir(allocator, init.io, rootfs_dir, &owners, "proc", 0o755);
    try ensureRequiredDir(allocator, init.io, rootfs_dir, &owners, "run", 0o755);
    try ensureRequiredDir(allocator, init.io, rootfs_dir, &owners, "sys", 0o755);
    try ensureRequiredDir(allocator, init.io, rootfs_dir, &owners, "tmp", 0o1777);
    try recordImplicitDirectoryOwnership(allocator, init.io, rootfs_dir, &owners, "");

    const deterministic_ext4 = ext4.Determinism.fromDigest(manifest_digest);
    try ext4.normalizeHostTreeTimestamps(allocator, init.io, rootfs_dir, rootfs_dir_path);

    const content_size = try ext4.dirContentSize(init.io, rootfs_dir);
    const inode_count = ext4.computeImageInodes(try ext4.dirEntryCount(init.io, rootfs_dir));
    const image_size = ext4.computeImageSize(content_size);

    try ext4.ensureParentDir(init.io, opts.output);
    try ext4.createEmptyFile(init.io, opts.output, image_size);
    try ext4.runMkfs(init, allocator, opts.mkfs, rootfs_dir_path, opts.output, deterministic_ext4, inode_count);
    const debugfs_script = try std.fmt.allocPrint(allocator, "{s}/debugfs-ownership.cmds", .{temp_dir});
    try ext4.runDebugfsFinalize(init, allocator, opts.debugfs, opts.output, debugfs_script, &owners, deterministic_ext4);

    const rootfs_blake3 = try ext4.blake3File(init.io, opts.output);
    const rootfs_hex = try allocator.dupe(u8, &rootfs_blake3);
    const stat = try Io.Dir.cwd().statFile(init.io, opts.output, .{});

    try ext4.ensureParentDir(init.io, opts.metadata);
    const metadata = RootFSMetadata{
        .builder_version = "sporevm-rootfs-v1",
        .image_ref = opts.ref,
        .image_manifest_digest = manifest_digest,
        .platform = opts.platform,
        .config_digest = manifest.config.digest,
        .config = config_parsed.value,
        .layers = layer_meta,
        .deterministic = true,
        .ext4_uuid = deterministic_ext4.uuid[0..],
        .ext4_hash_seed = deterministic_ext4.hash_seed[0..],
        .rootfs_path = opts.output,
        .rootfs_size = stat.size,
        .rootfs_blake3 = rootfs_hex,
    };
    const metadata_json = try std.json.Stringify.valueAlloc(allocator, metadata, .{ .whitespace = .indent_2 });
    try ext4.writeFileAtPath(init.io, opts.metadata, metadata_json);

    return .{ .rootfs_blake3 = rootfs_blake3 };
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

fn applyLayer(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    layer_path: []const u8,
    media_type: []const u8,
    ownership: *OwnershipMap,
) !void {
    if (oci.isGzipLayerMediaType(media_type)) {
        try applyGzipLayer(allocator, io, root, layer_path, ownership);
        return;
    }
    if (oci.isPlainTarLayerMediaType(media_type)) {
        try applyTarFileLayer(allocator, io, root, layer_path, ownership);
        return;
    }
    return error.UnsupportedLayerMediaType;
}

fn applyGzipLayer(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    layer_path: []const u8,
    ownership: *OwnershipMap,
) !void {
    var file = try Io.Dir.cwd().openFile(io, layer_path, .{});
    defer file.close(io);
    var file_buf: [64 * 1024]u8 = undefined;
    var file_reader: Io.File.Reader = .initStreaming(file, io, &file_buf);
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, &decompress_buf);
    applyTarLayer(allocator, io, root, &decompress.reader, ownership) catch |err| switch (err) {
        error.ReadFailed => return decompress.err orelse err,
        else => |e| return e,
    };
}

fn applyTarFileLayer(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    layer_path: []const u8,
    ownership: *OwnershipMap,
) !void {
    var file = try Io.Dir.cwd().openFile(io, layer_path, .{});
    defer file.close(io);
    var file_buf: [64 * 1024]u8 = undefined;
    var file_reader: Io.File.Reader = .initStreaming(file, io, &file_buf);
    try applyTarLayer(allocator, io, root, &file_reader.interface, ownership);
}

const LayerLimits = struct {
    content_bytes: u64 = 0,
    entries: u64 = 0,
};

const CreatedPathMap = std.StringHashMap(void);

const PendingPax = struct {
    path: ?[]u8 = null,
    linkpath: ?[]u8 = null,
    uid: ?u32 = null,
    gid: ?u32 = null,

    fn clear(self: *PendingPax, allocator: std.mem.Allocator) void {
        if (self.path) |p| allocator.free(p);
        if (self.linkpath) |p| allocator.free(p);
        self.* = .{};
    }
};

fn applyTarLayer(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    reader: *Io.Reader,
    ownership: *OwnershipMap,
) !void {
    var limits: LayerLimits = .{};
    var long_name: ?[]u8 = null;
    var long_link: ?[]u8 = null;
    var pax: PendingPax = .{};
    var created = CreatedPathMap.init(allocator);
    defer {
        if (long_name) |p| allocator.free(p);
        if (long_link) |p| allocator.free(p);
        pax.clear(allocator);
        deinitCreatedPaths(allocator, &created);
    }

    while (true) {
        var header: [512]u8 = undefined;
        if (!try readTarHeader(reader, &header)) break;
        if (isZeroBlock(&header)) break;
        try verifyTarHeader(&header);
        const size = try tarSize(&header);
        const kind = header[156];

        if (kind == 'L') {
            if (long_name) |p| allocator.free(p);
            long_name = try readTarString(allocator, reader, size);
            continue;
        }
        if (kind == 'K') {
            if (long_link) |p| allocator.free(p);
            long_link = try readTarString(allocator, reader, size);
            continue;
        }
        if (kind == 'x') {
            pax.clear(allocator);
            try readPaxHeader(allocator, reader, size, &pax);
            continue;
        }

        limits.entries += 1;
        if (limits.entries > max_rootfs_archive_entries) return error.RootFSArchiveTooManyEntries;

        const raw_name = if (pax.path) |p|
            p
        else if (long_name) |p|
            p
        else
            try tarFullName(allocator, &header);
        defer if (pax.path == null and long_name == null) allocator.free(raw_name);
        defer {
            if (long_name) |p| {
                allocator.free(p);
                long_name = null;
            }
            if (long_link) |p| {
                allocator.free(p);
                long_link = null;
            }
            pax.clear(allocator);
        }

        const rel = safeTarPath(allocator, raw_name) catch |err| switch (err) {
            error.RootTarPath => {
                if (kind != '5') return error.UnsafeTarPath;
                try discardTarPayload(reader, size);
                continue;
            },
            else => |e| return e,
        };
        defer allocator.free(rel);
        const entry_ownership = try tarOwnership(&header, pax);

        if (try applyWhiteout(allocator, io, root, ownership, &created, rel)) {
            try discardTarPayload(reader, size);
            continue;
        }

        switch (kind) {
            0, '0' => {
                try addContentBytes(&limits, size);
                try writeRegularFile(allocator, io, root, ownership, &created, rel, reader, size, try tarMode(&header));
                try ownership_mod.record(allocator, ownership, rel, entry_ownership);
                try recordCreatedPath(allocator, &created, rel);
            },
            '5' => {
                try discardTarPayload(reader, size);
                try writeDirectory(allocator, io, root, ownership, &created, rel, try tarMode(&header));
                try ownership_mod.record(allocator, ownership, rel, entry_ownership);
                try recordCreatedPath(allocator, &created, rel);
            },
            '2' => {
                try discardTarPayload(reader, size);
                const raw_link = if (pax.linkpath) |p| p else if (long_link) |p| p else tarLinkName(&header);
                try writeSymlink(allocator, io, root, ownership, &created, rel, raw_link);
                try ownership_mod.record(allocator, ownership, rel, entry_ownership);
                try recordCreatedPath(allocator, &created, rel);
            },
            '1' => {
                try discardTarPayload(reader, size);
                const raw_link = if (pax.linkpath) |p| p else if (long_link) |p| p else tarLinkName(&header);
                try createHardlinkTarget(allocator, io, root, ownership, &created, rel, raw_link);
                try recordHardlinkOwnership(allocator, io, root, ownership, rel, entry_ownership);
                try recordCreatedPath(allocator, &created, rel);
            },
            else => {
                try discardTarPayload(reader, size);
                return error.UnsupportedTarEntryType;
            },
        }
    }
}

fn addContentBytes(limits: *LayerLimits, size: u64) !void {
    if (size > max_rootfs_content_bytes - limits.content_bytes) return error.RootFSArchiveTooLarge;
    limits.content_bytes += size;
}

fn readTarHeader(reader: *Io.Reader, header: *[512]u8) !bool {
    var filled: usize = 0;
    while (filled < header.len) {
        const n = try reader.readSliceShort(header[filled..]);
        if (n == 0) {
            if (filled == 0) return false;
            return error.TruncatedTarHeader;
        }
        filled += n;
    }
    return true;
}

fn writeRegularFile(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *OwnershipMap,
    created: *CreatedPathMap,
    rel: []const u8,
    reader: *Io.Reader,
    size: u64,
    mode: u32,
) !void {
    try ensureNoSymlinkPath(allocator, io, root, parentPath(rel), false);
    try ensureParent(allocator, root, io, rel);
    try prepareEntryPath(allocator, io, root, ownership, created, rel, .non_directory);
    var file = try root.createFile(io, rel, .{ .permissions = permissionsFromMode(mode, .default_file) });
    defer file.close(io);
    var file_buf: [64 * 1024]u8 = undefined;
    var writer: Io.File.Writer = .initStreaming(file, io, &file_buf);
    try copyTarPayload(reader, &writer.interface, size);
    try writer.interface.flush();
    try discardTarPadding(reader, size);
    file.setPermissions(io, permissionsFromMode(mode, .default_file)) catch {};
}

fn writeDirectory(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *OwnershipMap,
    created: *CreatedPathMap,
    rel: []const u8,
    mode: u32,
) !void {
    try ensureNoSymlinkPath(allocator, io, root, parentPath(rel), false);
    try prepareEntryPath(allocator, io, root, ownership, created, rel, .directory);
    try root.createDirPath(io, rel);
    root.setFilePermissions(io, rel, permissionsFromMode(mode, .default_dir), .{ .follow_symlinks = false }) catch {};
}

fn writeSymlink(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *OwnershipMap,
    created: *CreatedPathMap,
    rel: []const u8,
    raw_link: []const u8,
) !void {
    try validateSymlinkTarget(allocator, rel, raw_link);
    try ensureNoSymlinkPath(allocator, io, root, parentPath(rel), false);
    try ensureParent(allocator, root, io, rel);
    try prepareEntryPath(allocator, io, root, ownership, created, rel, .non_directory);
    try root.symLink(io, raw_link, rel, .{});
}

fn createHardlinkTarget(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *OwnershipMap,
    created: *CreatedPathMap,
    rel: []const u8,
    raw_link: []const u8,
) !void {
    const link_rel = try safeTarPath(allocator, raw_link);
    defer allocator.free(link_rel);
    try ensureNoSymlinkPath(allocator, io, root, link_rel, false);
    const stat = try root.statFile(io, link_rel, .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.BadHardlinkTarget;
    try ensureNoSymlinkPath(allocator, io, root, parentPath(rel), false);
    try ensureParent(allocator, root, io, rel);
    try prepareEntryPath(allocator, io, root, ownership, created, rel, .non_directory);
    try Io.Dir.hardLink(root, link_rel, root, rel, io, .{});
}

fn recordHardlinkOwnership(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *OwnershipMap,
    rel: []const u8,
    owner: Ownership,
) !void {
    const linked = try root.statFile(io, rel, .{ .follow_symlinks = false });
    var it = ownership.iterator();
    while (it.next()) |entry| {
        const stat = root.statFile(io, entry.key_ptr.*, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        if (stat.kind == .file and stat.inode == linked.inode) {
            entry.value_ptr.* = owner;
        }
    }
    try ownership_mod.record(allocator, ownership, rel, owner);
}

const IncomingEntryKind = enum {
    directory,
    non_directory,
};

fn prepareEntryPath(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *OwnershipMap,
    created: *CreatedPathMap,
    rel: []const u8,
    incoming: IncomingEntryKind,
) !void {
    const stat = root.statFile(io, rel, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    if (incoming == .directory and stat.kind == .directory) return;
    try root.deleteTree(io, rel);
    try ownership_mod.removeSubtree(allocator, ownership, rel);
    try removeCreatedSubtree(allocator, created, rel);
}

fn applyWhiteout(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *OwnershipMap,
    created: *CreatedPathMap,
    rel: []const u8,
) !bool {
    const base = baseName(rel);
    if (!std.mem.startsWith(u8, base, ".wh.")) return false;
    const parent = parentPath(rel);
    if (std.mem.eql(u8, base, ".wh..wh..opq")) {
        try ensureNoSymlinkPath(allocator, io, root, parent, true);
        try deleteLowerChildrenAt(allocator, io, root, ownership, created, parent);
        return true;
    }
    const target_base = base[".wh.".len..];
    if (target_base.len == 0) return error.BadWhiteout;
    if (std.mem.eql(u8, target_base, ".") or std.mem.eql(u8, target_base, "..")) return error.BadWhiteout;
    const target = if (parent.len == 0)
        try allocator.dupe(u8, target_base)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, target_base });
    defer allocator.free(target);
    try ensureNoSymlinkPath(allocator, io, root, parent, true);
    if (created.contains(target) or createdHasDescendant(created, target)) {
        const stat = root.statFile(io, target, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return true,
            else => |e| return e,
        };
        if (stat.kind == .directory) {
            try deleteLowerChildrenAt(allocator, io, root, ownership, created, target);
        }
        return true;
    }
    try root.deleteTree(io, target);
    try ownership_mod.removeSubtree(allocator, ownership, target);
    try removeCreatedSubtree(allocator, created, target);
    return true;
}

fn deleteLowerChildrenAt(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *OwnershipMap,
    created: *CreatedPathMap,
    rel: []const u8,
) !void {
    if (rel.len == 0) {
        try deleteLowerChildren(allocator, io, root, ownership, created, "");
        return;
    }
    var dir = root.openDir(io, rel, .{
        .access_sub_paths = true,
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer dir.close(io);
    try deleteLowerChildren(allocator, io, dir, ownership, created, rel);
}

fn deleteLowerChildren(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *OwnershipMap,
    created: *CreatedPathMap,
    prefix: []const u8,
) !void {
    var it = root.iterate();
    while (try it.next(io)) |entry| {
        const name = try allocator.dupe(u8, entry.name);
        defer allocator.free(name);
        const rel = if (prefix.len == 0)
            try allocator.dupe(u8, name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
        defer allocator.free(rel);

        const has_created_descendant = createdHasDescendant(created, rel);
        if (entry.kind == .directory and (created.contains(rel) or has_created_descendant)) {
            var child = try root.openDir(io, name, .{
                .access_sub_paths = true,
                .iterate = true,
                .follow_symlinks = false,
            });
            defer child.close(io);
            try deleteLowerChildren(allocator, io, child, ownership, created, rel);
            continue;
        }
        if (created.contains(rel)) continue;

        try root.deleteTree(io, name);
        try ownership_mod.removeSubtree(allocator, ownership, rel);
    }
}

fn recordCreatedPath(allocator: std.mem.Allocator, created: *CreatedPathMap, rel: []const u8) !void {
    const key = try allocator.dupe(u8, rel);
    const entry = try created.getOrPut(key);
    if (entry.found_existing) allocator.free(key);
}

fn deinitCreatedPaths(allocator: std.mem.Allocator, created: *CreatedPathMap) void {
    var it = created.iterator();
    while (it.next()) |entry| allocator.free(entry.key_ptr.*);
    created.deinit();
}

fn removeCreatedSubtree(allocator: std.mem.Allocator, created: *CreatedPathMap, rel: []const u8) !void {
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(allocator);
    const prefix = try std.fmt.allocPrint(allocator, "{s}/", .{rel});
    defer allocator.free(prefix);

    var it = created.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, rel) or std.mem.startsWith(u8, key, prefix)) {
            try keys.append(allocator, key);
        }
    }
    for (keys.items) |key| {
        _ = created.remove(key);
        allocator.free(key);
    }
}

fn createdHasDescendant(created: *const CreatedPathMap, rel: []const u8) bool {
    var it = created.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.len <= rel.len) continue;
        if (!std.mem.startsWith(u8, key, rel)) continue;
        if (key[rel.len] == '/') return true;
    }
    return false;
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

fn ensureParent(allocator: std.mem.Allocator, root: Io.Dir, io: Io, rel: []const u8) !void {
    const parent = parentPath(rel);
    if (parent.len == 0) return;
    var accum: Io.Writer.Allocating = .init(allocator);
    defer accum.deinit();
    var iter = std.mem.splitScalar(u8, parent, '/');
    while (iter.next()) |part| {
        if (part.len == 0) continue;
        if (accum.written().len != 0) try accum.writer.writeByte('/');
        try accum.writer.writeAll(part);
        const current = accum.written();
        const stat = root.statFile(io, current, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                const permissions = permissionsFromMode(0o755, .default_dir);
                try root.createDir(io, current, permissions);
                root.setFilePermissions(io, current, permissions, .{ .follow_symlinks = false }) catch {};
                continue;
            },
            else => |e| return e,
        };
        if (stat.kind != .directory) return error.ParentNotDirectory;
    }
}

fn ensureNoSymlinkPath(allocator: std.mem.Allocator, io: Io, root: Io.Dir, rel: []const u8, allow_missing_leaf: bool) !void {
    if (rel.len == 0) return;
    var accum: Io.Writer.Allocating = .init(allocator);
    defer accum.deinit();
    var iter = std.mem.splitScalar(u8, rel, '/');
    var index: usize = 0;
    var component_count: usize = 0;
    {
        var counter = std.mem.splitScalar(u8, rel, '/');
        while (counter.next()) |_| component_count += 1;
    }
    while (iter.next()) |part| : (index += 1) {
        if (part.len == 0) continue;
        if (accum.written().len != 0) try accum.writer.writeByte('/');
        try accum.writer.writeAll(part);
        const is_leaf = index + 1 == component_count;
        const stat = root.statFile(io, accum.written(), .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                if (is_leaf and allow_missing_leaf) return;
                continue;
            },
            else => |e| return e,
        };
        if (stat.kind == .sym_link) return error.SymlinkTraversal;
    }
}

fn validateSymlinkTarget(allocator: std.mem.Allocator, rel: []const u8, raw_link: []const u8) !void {
    if (raw_link.len == 0 or std.mem.indexOfScalar(u8, raw_link, 0) != null) return error.BadSymlinkTarget;
    var owned_candidate: ?[]u8 = null;
    defer if (owned_candidate) |candidate| allocator.free(candidate);
    const candidate = if (std.mem.startsWith(u8, raw_link, "/"))
        raw_link[1..]
    else if (parentPath(rel).len == 0)
        raw_link
    else candidate: {
        owned_candidate = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parentPath(rel), raw_link });
        break :candidate owned_candidate.?;
    };
    const normalized = try normalizeRelativePath(allocator, candidate);
    defer allocator.free(normalized);
}

fn safeTarPath(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len == 0 or std.mem.startsWith(u8, raw, "/")) return error.UnsafeTarPath;
    if (std.mem.indexOfScalar(u8, raw, 0) != null) return error.UnsafeTarPath;
    if (isTarRootPath(raw)) return error.RootTarPath;
    return normalizeRelativePath(allocator, raw);
}

fn isTarRootPath(raw: []const u8) bool {
    if (raw.len == 0) return false;
    var saw_component = false;
    var iter = std.mem.splitScalar(u8, raw, '/');
    while (iter.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        saw_component = true;
        break;
    }
    return !saw_component;
}

fn normalizeRelativePath(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);
    var iter = std.mem.splitScalar(u8, raw, '/');
    while (iter.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len == 0) return error.UnsafeTarPath;
            _ = parts.pop();
            continue;
        }
        try parts.append(allocator, part);
    }
    if (parts.items.len == 0) return error.UnsafeTarPath;
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (parts.items, 0..) |part, i| {
        if (i != 0) try out.writer.writeByte('/');
        try out.writer.writeAll(part);
    }
    return out.toOwnedSlice();
}

fn parentPath(rel: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, rel, '/') orelse return "";
    return rel[0..slash];
}

fn baseName(rel: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, rel, '/') orelse return rel;
    return rel[slash + 1 ..];
}

fn copyTarPayload(reader: *Io.Reader, writer: *Io.Writer, size: u64) !void {
    var remaining = size;
    var buf: [64 * 1024]u8 = undefined;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, buf.len));
        const n = try reader.readSliceShort(buf[0..want]);
        if (n == 0) return error.UnexpectedEndOfStream;
        try writer.writeAll(buf[0..n]);
        remaining -= n;
    }
}

fn discardTarPayload(reader: *Io.Reader, size: u64) !void {
    try reader.discardAll64(size);
    try discardTarPadding(reader, size);
}

fn discardTarPadding(reader: *Io.Reader, size: u64) !void {
    const padding = (512 - (size % 512)) % 512;
    if (padding != 0) try reader.discardAll(@intCast(padding));
}

fn readTarString(allocator: std.mem.Allocator, reader: *Io.Reader, size: u64) ![]u8 {
    if (size > max_pax_header_bytes) return error.TarHeaderTooLarge;
    const bytes = try reader.readAlloc(allocator, @intCast(size));
    defer allocator.free(bytes);
    try discardTarPadding(reader, size);
    return allocator.dupe(u8, trimTrailingNul(bytes));
}

fn trimTrailingNul(bytes: []u8) []u8 {
    var end = bytes.len;
    while (end > 0 and bytes[end - 1] == 0) end -= 1;
    return bytes[0..end];
}

fn readPaxHeader(allocator: std.mem.Allocator, reader: *Io.Reader, size: u64, out: *PendingPax) !void {
    if (size > max_pax_header_bytes) return error.TarHeaderTooLarge;
    const bytes = try reader.readAlloc(allocator, @intCast(size));
    defer allocator.free(bytes);
    try discardTarPadding(reader, size);

    var index: usize = 0;
    while (index < bytes.len) {
        const line_start = index;
        while (index < bytes.len and bytes[index] != ' ') : (index += 1) {}
        if (index >= bytes.len) return error.BadPaxHeader;
        const line_len = try std.fmt.parseInt(usize, bytes[line_start..index], 10);
        if (line_len == 0 or line_len > bytes.len - line_start) return error.BadPaxHeader;
        const record_start = index + 1;
        const record_end = line_start + line_len;
        if (record_end <= record_start or bytes[record_end - 1] != '\n') return error.BadPaxHeader;
        const record = bytes[record_start .. record_end - 1];
        if (std.mem.indexOfScalar(u8, record, '=')) |eq| {
            const key = record[0..eq];
            const value = record[eq + 1 ..];
            if (std.mem.eql(u8, key, "path")) {
                if (out.path) |old| allocator.free(old);
                out.path = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "linkpath")) {
                if (out.linkpath) |old| allocator.free(old);
                out.linkpath = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "uid")) {
                out.uid = try parsePaxId(value);
            } else if (std.mem.eql(u8, key, "gid")) {
                out.gid = try parsePaxId(value);
            }
        }
        index = line_start + line_len;
    }
}

fn parsePaxId(raw: []const u8) !u32 {
    const value = std.fmt.parseInt(u64, raw, 10) catch return error.BadPaxHeader;
    if (value > std.math.maxInt(u32)) return error.BadPaxHeader;
    return @intCast(value);
}

fn tarFullName(allocator: std.mem.Allocator, header: *const [512]u8) ![]u8 {
    const name = trimTarField(header[0..100]);
    const prefix = trimTarField(header[345..500]);
    if (prefix.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
}

fn tarLinkName(header: *const [512]u8) []const u8 {
    return trimTarField(header[157..257]);
}

fn tarMode(header: *const [512]u8) !u32 {
    const value = try parseTarNumber(header[100..108]);
    if (value > std.math.maxInt(u32)) return error.BadTarHeader;
    return @intCast(value);
}

fn tarOwnership(header: *const [512]u8, pax: PendingPax) !Ownership {
    return .{
        .uid = pax.uid orelse try tarId(header[108..116]),
        .gid = pax.gid orelse try tarId(header[116..124]),
    };
}

fn tarId(raw: []const u8) !u32 {
    const value = try parseTarNumber(raw);
    if (value > std.math.maxInt(u32)) return error.BadTarHeader;
    return @intCast(value);
}

fn tarSize(header: *const [512]u8) !u64 {
    return parseTarNumber(header[124..136]);
}

fn parseTarNumber(raw: []const u8) !u64 {
    if (raw.len == 0) return error.BadTarHeader;
    if ((raw[0] & 0x80) != 0) {
        var value: u64 = 0;
        var significant: usize = 0;
        for (raw, 0..) |b, i| {
            const byte = if (i == 0) b & 0x7f else b;
            if (significant == 0 and byte == 0) continue;
            significant += 1;
            if (significant > @sizeOf(u64)) return error.BadTarHeader;
            value = (value << 8) | byte;
        }
        return value;
    }
    const trimmed = std.mem.trim(u8, raw, " \x00");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(u64, trimmed, 8) catch return error.BadTarHeader;
}

fn trimTarField(raw: []const u8) []const u8 {
    const nul = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
    return std.mem.trim(u8, raw[0..nul], " ");
}

fn verifyTarHeader(header: *const [512]u8) !void {
    const stored = try parseTarNumber(header[148..156]);
    var unsigned_sum: u64 = 0;
    var signed_sum: i64 = 0;
    for (header, 0..) |b, i| {
        const value: u8 = if (i >= 148 and i < 156) ' ' else b;
        unsigned_sum += value;
        signed_sum += @as(i8, @bitCast(value));
    }
    if (stored != unsigned_sum and @as(i64, @intCast(stored)) != signed_sum) return error.BadTarChecksum;
}

fn isZeroBlock(block: *const [512]u8) bool {
    for (block) |b| if (b != 0) return false;
    return true;
}

fn permissionsFromMode(mode: u32, fallback: Io.Dir.Permissions) Io.Dir.Permissions {
    if (@hasDecl(Io.Dir.Permissions, "fromMode")) {
        return Io.Dir.Permissions.fromMode(@intCast(mode & 0o7777));
    }
    return fallback;
}

fn permissionsToMode(permissions: Io.Dir.Permissions) ?u32 {
    if (@hasDecl(Io.Dir.Permissions, "toMode")) {
        return @intCast(permissions.toMode() & 0o7777);
    }
    return null;
}

fn makeTarHeader(header: []u8, name: []const u8, kind: u8, size: u64) void {
    std.debug.assert(header.len == 512);
    std.debug.assert(name.len <= 100);
    @memset(header, 0);
    @memcpy(header[0..name.len], name);
    writeTarOctal(header[100..108], if (kind == '5') 0o755 else 0o644);
    writeTarOctal(header[108..116], 0);
    writeTarOctal(header[116..124], 0);
    writeTarOctal(header[124..136], size);
    writeTarOctal(header[136..148], 0);
    @memset(header[148..156], ' ');
    header[156] = kind;
    @memcpy(header[257..263], "ustar\x00");
    @memcpy(header[263..265], "00");
    var sum: u64 = 0;
    for (header[0..512]) |b| sum += b;
    writeTarOctal(header[148..156], sum);
}

fn writeTarOctal(field: []u8, value: u64) void {
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

test "safe tar path rejects traversal and absolute entries" {
    const allocator = std.testing.allocator;
    const path = try safeTarPath(allocator, "./usr/bin/tool");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("usr/bin/tool", path);
    try std.testing.expectError(error.RootTarPath, safeTarPath(allocator, "."));
    try std.testing.expectError(error.RootTarPath, safeTarPath(allocator, "./"));
    try std.testing.expectError(error.UnsafeTarPath, safeTarPath(allocator, "/etc/passwd"));
    try std.testing.expectError(error.UnsafeTarPath, safeTarPath(allocator, "../escape"));
    try std.testing.expectError(error.UnsafeTarPath, safeTarPath(allocator, "a/../../escape"));
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

test "plain tar layer media type extracts without gzip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const layer_path = "zig-cache/test-rootfs-plain-layer.tar";
    defer Io.Dir.cwd().deleteFile(io, layer_path) catch {};
    var block = [_]u8{0} ** 1536;
    makeTarHeader(block[0..512], "file", '0', 5);
    @memcpy(block[512..517], "hello");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = layer_path, .data = &block });

    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);

    try applyLayer(allocator, io, tmp.dir, layer_path, "application/vnd.oci.image.layer.v1.tar", &ownership);
    const bytes = try tmp.dir.readFileAlloc(io, "file", allocator, .limited(16));
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("hello", bytes);
}

test "whiteout removes lower-layer path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-whiteout";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    try root.createDirPath(io, "etc");
    try root.writeFile(io, .{ .sub_path = "etc/old", .data = "old" });
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);
    try ownership_mod.record(allocator, &ownership, "etc/old", .{ .uid = 1, .gid = 2 });
    try std.testing.expect(try applyWhiteout(allocator, io, root, &ownership, &created, "etc/.wh.old"));
    try std.testing.expectError(error.FileNotFound, root.statFile(io, "etc/old", .{}));
    try std.testing.expect(!ownership.contains("etc/old"));
}

test "whiteout ignores already absent target" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-whiteout-absent";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    try root.createDirPath(io, "etc");
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);
    try std.testing.expect(try applyWhiteout(allocator, io, root, &ownership, &created, "etc/.wh.missing"));
}

test "whiteout rejects dot and dot-dot targets" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-whiteout-dot-target";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);

    try std.testing.expectError(error.BadWhiteout, applyWhiteout(allocator, io, root, &ownership, &created, ".wh.."));
    try std.testing.expectError(error.BadWhiteout, applyWhiteout(allocator, io, root, &ownership, &created, ".wh..."));
}

test "opaque whiteout preserves entries created in current layer" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-opaque-current-layer";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true, .access_sub_paths = true } });
    defer root.close(io);
    try root.createDirPath(io, "dir/sub");
    try root.writeFile(io, .{ .sub_path = "dir/lower", .data = "lower" });
    try root.writeFile(io, .{ .sub_path = "dir/current", .data = "current" });
    try root.writeFile(io, .{ .sub_path = "dir/sub/lower", .data = "lower" });
    try root.writeFile(io, .{ .sub_path = "dir/sub/current", .data = "current" });

    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    try ownership_mod.record(allocator, &ownership, "dir/lower", .{ .uid = 1, .gid = 1 });
    try ownership_mod.record(allocator, &ownership, "dir/current", .{ .uid = 2, .gid = 2 });
    try ownership_mod.record(allocator, &ownership, "dir/sub/lower", .{ .uid = 3, .gid = 3 });
    try ownership_mod.record(allocator, &ownership, "dir/sub/current", .{ .uid = 4, .gid = 4 });

    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);
    try recordCreatedPath(allocator, &created, "dir/current");
    try recordCreatedPath(allocator, &created, "dir/sub/current");

    try std.testing.expect(try applyWhiteout(allocator, io, root, &ownership, &created, "dir/.wh..wh..opq"));
    try std.testing.expectError(error.FileNotFound, root.statFile(io, "dir/lower", .{}));
    try std.testing.expectError(error.FileNotFound, root.statFile(io, "dir/sub/lower", .{}));
    try root.access(io, "dir/current", .{});
    try root.access(io, "dir/sub/current", .{});
    try std.testing.expect(!ownership.contains("dir/lower"));
    try std.testing.expect(!ownership.contains("dir/sub/lower"));
    try std.testing.expect(ownership.contains("dir/current"));
    try std.testing.expect(ownership.contains("dir/sub/current"));
}

test "normal whiteout preserves current-layer target" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-whiteout-current-layer";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true, .access_sub_paths = true } });
    defer root.close(io);
    try root.createDirPath(io, "dir/sub");
    try root.writeFile(io, .{ .sub_path = "dir/sub/lower", .data = "lower" });
    try root.writeFile(io, .{ .sub_path = "dir/sub/current", .data = "current" });

    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    try ownership_mod.record(allocator, &ownership, "dir/sub/lower", .{ .uid = 1, .gid = 1 });
    try ownership_mod.record(allocator, &ownership, "dir/sub/current", .{ .uid = 2, .gid = 2 });

    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);
    try recordCreatedPath(allocator, &created, "dir/sub/current");

    try std.testing.expect(try applyWhiteout(allocator, io, root, &ownership, &created, "dir/.wh.sub"));
    try root.access(io, "dir/sub/current", .{});
    try std.testing.expectError(error.FileNotFound, root.statFile(io, "dir/sub/lower", .{}));
    try std.testing.expect(ownership.contains("dir/sub/current"));
    try std.testing.expect(!ownership.contains("dir/sub/lower"));
}

test "opaque whiteout rejects symlink parent" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root_path = "zig-cache/test-rootfs-opaque-symlink";
    const victim_path = "zig-cache/test-rootfs-opaque-victim";
    defer Io.Dir.cwd().deleteTree(io, root_path) catch {};
    defer Io.Dir.cwd().deleteTree(io, victim_path) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, root_path, .{ .open_options = .{ .iterate = true, .access_sub_paths = true } });
    defer root.close(io);
    var victim = try Io.Dir.cwd().createDirPathOpen(io, victim_path, .{});
    victim.close(io);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = victim_path ++ "/keep", .data = "keep" });
    try root.symLink(io, "../test-rootfs-opaque-victim", "link", .{});

    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);
    try std.testing.expectError(
        error.SymlinkTraversal,
        applyWhiteout(allocator, io, root, &ownership, &created, "link/.wh..wh..opq"),
    );
    try Io.Dir.cwd().access(io, victim_path ++ "/keep", .{});
}

test "directory entries preserve tar mode" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-directory-mode";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);

    try writeDirectory(allocator, io, root, &ownership, &created, "root", 0o700);
    const stat = try root.statFile(io, "root", .{ .follow_symlinks = false });
    if (permissionsToMode(stat.permissions)) |mode| {
        try std.testing.expectEqual(@as(u32, 0o700), mode & 0o777);
    }
}

test "directory entries replace non-directories" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-directory-replaces-file";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true, .access_sub_paths = true } });
    defer root.close(io);
    try root.writeFile(io, .{ .sub_path = "x", .data = "file" });
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    try ownership_mod.record(allocator, &ownership, "x", .{ .uid = 1, .gid = 1 });
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);

    try writeDirectory(allocator, io, root, &ownership, &created, "x", 0o755);
    const stat = try root.statFile(io, "x", .{ .follow_symlinks = false });
    try std.testing.expectEqual(Io.File.Kind.directory, stat.kind);
    try std.testing.expect(!ownership.contains("x"));
}

test "implicit parent directories use deterministic mode without changing explicit parents" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-implicit-parent-mode";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true, .access_sub_paths = true } });
    defer root.close(io);
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);

    try writeDirectory(allocator, io, root, &ownership, &created, "usr", 0o700);
    var payload = [_]u8{0} ** 512;
    payload[0] = 'x';
    var reader: Io.Reader = .fixed(&payload);
    try writeRegularFile(allocator, io, root, &ownership, &created, "usr/bin/tool", &reader, 1, 0o755);

    const usr = try root.statFile(io, "usr", .{ .follow_symlinks = false });
    const bin = try root.statFile(io, "usr/bin", .{ .follow_symlinks = false });
    if (permissionsToMode(usr.permissions)) |mode| {
        try std.testing.expectEqual(@as(u32, 0o700), mode & 0o777);
    }
    if (permissionsToMode(bin.permissions)) |mode| {
        try std.testing.expectEqual(@as(u32, 0o755), mode & 0o777);
    }
}

test "hardlink entries preserve inode identity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-hardlink";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true, .access_sub_paths = true } });
    defer root.close(io);
    try root.writeFile(io, .{ .sub_path = "target", .data = "same" });
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);

    try createHardlinkTarget(allocator, io, root, &ownership, &created, "alias", "target");
    const target = try root.statFile(io, "target", .{ .follow_symlinks = false });
    const alias = try root.statFile(io, "alias", .{ .follow_symlinks = false });
    try std.testing.expectEqual(target.inode, alias.inode);
    try std.testing.expect(target.nlink >= 2);
}

test "hardlink ownership is normalized across shared inode paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-hardlink-ownership";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true, .access_sub_paths = true } });
    defer root.close(io);
    try root.writeFile(io, .{ .sub_path = "target", .data = "same" });
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    try ownership_mod.record(allocator, &ownership, "target", .{ .uid = 1, .gid = 1 });
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);

    try createHardlinkTarget(allocator, io, root, &ownership, &created, "alias", "target");
    try recordHardlinkOwnership(allocator, io, root, &ownership, "alias", .{ .uid = 2, .gid = 3 });

    try std.testing.expectEqual(@as(u32, 2), ownership.get("target").?.uid);
    try std.testing.expectEqual(@as(u32, 3), ownership.get("target").?.gid);
    try std.testing.expectEqual(@as(u32, 2), ownership.get("alias").?.uid);
    try std.testing.expectEqual(@as(u32, 3), ownership.get("alias").?.gid);
}

test "regular files clear stale ownership when replacing directories" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-file-replaces-dir";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true, .access_sub_paths = true } });
    defer root.close(io);
    try root.createDirPath(io, "etc/conf.d");
    try root.writeFile(io, .{ .sub_path = "etc/conf.d/file", .data = "old" });
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    try ownership_mod.record(allocator, &ownership, "etc/conf.d/file", .{ .uid = 1, .gid = 1 });
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);
    var payload = [_]u8{0} ** 512;
    @memcpy(payload[0..3], "new");
    var reader: Io.Reader = .fixed(&payload);

    try writeRegularFile(allocator, io, root, &ownership, &created, "etc/conf.d", &reader, 3, 0o644);
    try std.testing.expect(!ownership.contains("etc/conf.d/file"));
    const stat = try root.statFile(io, "etc/conf.d", .{ .follow_symlinks = false });
    try std.testing.expectEqual(Io.File.Kind.file, stat.kind);
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

test "tar layer rejects symlink traversal from earlier entry" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-symlink-traversal";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    try root.symLink(io, "/tmp", "link", .{});
    try std.testing.expectError(error.SymlinkTraversal, ensureNoSymlinkPath(allocator, io, root, "link/escape", true));
    var reader: Io.Reader = .fixed("");
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);
    try std.testing.expectError(
        error.SymlinkTraversal,
        writeRegularFile(allocator, io, root, &ownership, &created, "link/escape", &reader, 0, 0o644),
    );
}

test "unsupported tar entry types fail closed" {
    const allocator = std.testing.allocator;
    var block = [_]u8{0} ** 1024;
    makeTarHeader(block[0..512], "dev/null", '3', 0);
    var reader: Io.Reader = .fixed(&block);
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);

    try std.testing.expectError(
        error.UnsupportedTarEntryType,
        applyTarLayer(allocator, std.testing.io, tmp.dir, &reader, &ownership),
    );
}

test "truncated tar headers fail closed" {
    const allocator = std.testing.allocator;
    var block = [_]u8{0} ** 511;
    var reader: Io.Reader = .fixed(&block);
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);

    try std.testing.expectError(error.TruncatedTarHeader, applyTarLayer(allocator, std.testing.io, tmp.dir, &reader, &ownership));
}

test "root directory tar entry is ignored" {
    const allocator = std.testing.allocator;
    var block = [_]u8{0} ** 1024;
    makeTarHeader(block[0..512], ".", '5', 0);
    var reader: Io.Reader = .fixed(&block);
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);

    try applyTarLayer(allocator, std.testing.io, tmp.dir, &reader, &ownership);
}

test "root non-directory tar entry fails closed" {
    const allocator = std.testing.allocator;
    var block = [_]u8{0} ** 1024;
    makeTarHeader(block[0..512], ".", '0', 0);
    var reader: Io.Reader = .fixed(&block);
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);

    try std.testing.expectError(error.UnsafeTarPath, applyTarLayer(allocator, std.testing.io, tmp.dir, &reader, &ownership));
}

test "malformed pax records fail closed" {
    const allocator = std.testing.allocator;
    var block = [_]u8{0} ** 512;
    @memcpy(block[0..2], "1 ");
    var reader: Io.Reader = .fixed(&block);
    var pax: PendingPax = .{};
    defer pax.clear(allocator);
    try std.testing.expectError(error.BadPaxHeader, readPaxHeader(allocator, &reader, 2, &pax));
}

test "oversized binary tar numbers fail closed" {
    var raw = [_]u8{0xff} ** 12;
    raw[0] = 0x80;
    try std.testing.expectError(error.BadTarHeader, parseTarNumber(&raw));
}

test "oversized binary tar modes fail closed" {
    var header = [_]u8{0} ** 512;
    header[100] = 0x80;
    header[103] = 0x01;
    try std.testing.expectError(error.BadTarHeader, tarMode(&header));
}

fn fuzzTarLayer(_: void, s: *std.testing.Smith) !void {
    // OCI layers are attacker-influenced tar streams. The applier must reject
    // malformed data, traversal attempts, and odd link metadata without
    // escaping the scratch root or crashing.
    var buf: [8192]u8 = undefined;
    const len = s.slice(&buf);

    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ownership = OwnershipMap.init(arena_state.allocator());
    defer ownership_mod.deinit(arena_state.allocator(), &ownership);

    var reader: Io.Reader = .fixed(buf[0..len]);
    applyTarLayer(arena_state.allocator(), std.testing.io, tmp.dir, &reader, &ownership) catch return;
}

test "fuzz OCI tar layer parsing" {
    try std.testing.fuzz({}, fuzzTarLayer, .{});
}
