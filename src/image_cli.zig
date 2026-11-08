//! CLI adapters for `spore image`: local image import, resolve and export,
//! native image archives, and image stores. The operations are in `api.zig`.

const std = @import("std");
const TestDir = @import("test_dir.zig").TestDir;
const Io = std.Io;
const api = @import("api.zig");
const cli = @import("cli.zig");
const Ctx = cli.Ctx;
const machine_output = @import("machine_output.zig");
const rootfs = @import("rootfs.zig");

pub const push_usage =
    \\Usage:
    \\  spore image push local/name:tag --to STORE/TAG [--platform os/arch]
    \\
    \\STORE is a directory, a file:// URL or s3://bucket/prefix (uploaded with
    \\the aws CLI); TAG may be blake3:<digest>. HTTP(S) stores are read-only;
    \\publish a directory and serve it with a static HTTP server instead.
    \\Run a pushed image with `spore run --image <store-url>/TAG`.
    \\S3 reads use explicit environment credentials first, otherwise AWS CLI v2's
    \\provider chain (including AWS_PROFILE), refreshing expiring credentials.
    \\Use image pull for complete offline acquisition; resolve only finds identity.
    \\
    \\Options:
    \\  --platform os/arch    linux/arm64 or linux/amd64 (infer recorded platform;
    \\                        prefer native when a local tag has both)
    \\  --to STORE/TAG        Store publication destination, not an OCI registry
    \\  -h, --help            Show this help
    \\
;

pub const pack_usage =
    \\Usage:
    \\  spore image pack IMAGE --output image.tar.gz [--platform os/arch]
    \\
    \\Write a native image archive for offline transfer, not a checkpoint bundle.
    \\The output must be new. Record both returned digests for trusted unpacking.
    \\
    \\Options:
    \\  --output PATH        New image archive path
    \\  --platform os/arch   Infer recorded platform; prefer native for multi-platform tags
    \\  -h, --help           Show this help
    \\
;

pub const unpack_usage =
    \\Usage:
    \\  spore image unpack ARCHIVE --expected-archive-digest sha256:... --expected-image-digest blake3:... --tag local/name:tag [--platform os/arch]
    \\
    \\Verify a native image archive against independently trusted digests before
    \\publishing its local tag. Hashes from the archive alone are not trust anchors.
    \\
    \\Options:
    \\  --expected-archive-digest DIGEST  Expected SHA-256 archive identity
    \\  --expected-image-digest DIGEST    Expected native BLAKE3 image identity
    \\  --tag REF                        Local mutable image name to publish
    \\  --platform os/arch               Infer the archive's recorded platform
    \\  -h, --help                       Show this help
    \\
;

pub const pull_usage =
    \\Usage:
    \\  spore image pull SOURCE [--tag local/name:tag] [--platform os/arch]
    \\
    \\Acquire a registry image, native image store ref, or local image completely
    \\without starting a VM. Success roots verified content in the local cache;
    \\the returned local digest_ref works offline until explicit image prune.
    \\Registry tags are refreshed. Resolve alone does not acquire content.
    \\
    \\Options:
    \\  --tag REF             Optional local mutable name for the acquired image
    \\  --platform os/arch    Registry: host-native Linux; native input: recorded
    \\  -h, --help            Show this help
    \\
;

pub const export_usage =
    \\Usage:
    \\  spore image export-rootfs IMAGE --output <rootfs.ext4>
    \\
    \\Writes a registry, local or native-store image as a new ext4 file and
    \\metadata sidecar. Native sources are fully acquired first. Output is an
    \\independent writable copy, not a hard link into the image cache.
    \\
    \\Options:
    \\  --output <path>        Rootfs ext4 output path
    \\  --metadata <path>      Metadata sidecar path (default: <output>.json)
    \\  --platform <os/arch>   Registry: host-native Linux; native input: recorded
    \\  -h, --help             Show this help
    \\
;

pub const import_oci_usage =
    \\Usage:
    \\  spore image import-oci <layout-dir|layout.tar> --tag local/name:tag
    \\
    \\Options:
    \\  --tag <name:tag>       Local mutable image ref to record
    \\  --platform <os/arch>   linux/arm64 or linux/amd64 (default: host-native Linux)
    \\  --rootfs-storage <policy>
    \\                       Rootfs storage: chunked (default: chunked)
    \\  -h, --help             Show this help
    \\
;

pub const import_tar_usage =
    \\Usage:
    \\  spore image import-tar <rootfs.tar> --tag local/name:tag
    \\
    \\Options:
    \\  --tag <name:tag>       Local mutable image ref to record
    \\  --platform <os/arch>   linux/arm64 or linux/amd64 (default: host-native Linux)
    \\  --rootfs-storage <policy>
    \\                       Rootfs storage: chunked (default: chunked)
    \\  -h, --help             Show this help
    \\
;

pub const resolve_usage =
    \\Usage:
    \\  spore image resolve <image:tag>
    \\
    \\Resolves identity and metadata, not an offline image acquisition.
    \\
    \\Options:
    \\  --platform <os/arch>   linux/arm64 or linux/amd64 (default: host-native Linux)
    \\  -h, --help             Show this help
    \\
;

pub fn exportRootfs(ctx: *const Ctx, args: []const []const u8) !void {
    const arena = ctx.init.arena.allocator();
    if (args.len == 0) cli.exitUsage(arena, ctx.stderr, ctx.mode, "image export-rootfs", "usage: spore image export-rootfs IMAGE --output FILE");
    const parsed = try rootfs.parseBuildOptions(arena, args);
    const result = api.rootfsBuild(ctx.init, arena, .{
        .ref = parsed.ref,
        .output = parsed.output,
        .metadata = parsed.metadata,
        .platform = parsed.platform,
    }) catch |err| {
        if (err != error.FileNotFound and err != error.PathAlreadyExists) return err;
        var failure = machine_output.fromZigError(err);
        const source = if (rootfs.isLocalImageRef(parsed.ref)) parsed.ref else "registry/store image";
        failure.message = cli.allocMessage(arena, "spore image export-rootfs: {s}; source: {s}; output: {s}; metadata: {s}", .{ failure.message, source, parsed.output, parsed.metadata });
        cli.exitWithCliError(arena, ctx.stderr, ctx.mode, failure, failure.message);
    };
    if (ctx.mode == .json) return machine_output.writeJson(arena, ctx.stdout, result);
    try ctx.stdout.print("rootfs: {s}\nmetadata: {s}\nsource: {s}\nrootfs_identity: {s}\nrootfs_storage: {s}\n", .{
        parsed.output,
        parsed.metadata,
        parsed.ref,
        result.rootfs_storage.index_digest,
        result.rootfs_storage.index_digest,
    });
    try ctx.stdout.print("platform: {s}/{s}\n", .{ result.platform.os, result.platform.arch.name() });
}

pub fn pull(ctx: *const Ctx, args: []const []const u8) !void {
    const allocator = ctx.init.arena.allocator();
    const options = try parsePullOptions(args);
    const result = api.imagePull(ctx.init, allocator, options) catch |err| {
        if (err != error.FileNotFound) return err;
        const message = cli.allocMessage(allocator, "spore image pull: image not found: {s}; build, import or unpack it first, or select a registry/store source", .{options.source});
        const failure = machine_output.CliError.init(.object_not_found, message, "image pull");
        cli.exitWithCliError(allocator, ctx.stderr, ctx.mode, failure, message);
    };
    if (ctx.mode == .json) return machine_output.writeJson(allocator, ctx.stdout, result);
    try ctx.stdout.print("digest_ref: {s}\nimage_digest: {s}\nplatform: {s}/{s}\n", .{ result.digest_ref, result.image_digest, result.platform.os, result.platform.arch.name() });
    if (result.tag_ref) |tag| try ctx.stdout.print("tag_ref: {s}\n", .{tag});
}

pub fn parsePullOptions(args: []const []const u8) !api.ImagePullOptions {
    var source: ?[]const u8 = null;
    var tag: ?[]const u8 = null;
    var platform: ?rootfs.Platform = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--tag")) {
            i += 1;
            if (i >= args.len) return error.MissingImageReference;
            tag = args[i];
        } else if (std.mem.eql(u8, arg, "--platform")) {
            i += 1;
            if (i >= args.len) return error.MissingPlatform;
            platform = try rootfs.Platform.parse(args[i]);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownImageOption;
        } else if (source == null) {
            source = arg;
        } else return error.TooManyImageArguments;
    }
    if (tag) |name| try rootfs.validateLocalTagRef(name);
    return .{ .source = source orelse return error.MissingImageSource, .tag = tag, .platform = platform };
}

pub fn importOci(ctx: *const Ctx, args: []const []const u8) !void {
    const arena = ctx.init.arena.allocator();
    if (args.len == 0) cli.exitUsage(arena, ctx.stderr, ctx.mode, "image import-oci", "usage: spore image import-oci LAYOUT --tag local/NAME:TAG");
    const parsed = try rootfs.parseImportOciOptions(args);
    const result = try api.rootfsImportOci(ctx.init, arena, .{
        .input = parsed.input,
        .ref = parsed.ref,
        .platform = parsed.platform,
        .rootfs_storage = parsed.rootfs_storage,
    });
    if (ctx.mode == .json) return machine_output.writeJson(arena, ctx.stdout, result);
    try writeImportResult(ctx.stdout, parsed.ref, result);
    try ctx.stdout.print("platform: {s}/{s}\n", .{ parsed.platform.os, parsed.platform.arch.name() });
}

pub fn importTar(ctx: *const Ctx, args: []const []const u8) !void {
    const arena = ctx.init.arena.allocator();
    if (args.len == 0) cli.exitUsage(arena, ctx.stderr, ctx.mode, "image import-tar", "usage: spore image import-tar ROOTFS.tar --tag local/NAME:TAG");
    const parsed = try rootfs.parseImportTarOptions(args);
    const result = try api.rootfsImportTar(ctx.init, arena, .{
        .input = parsed.input,
        .ref = parsed.ref,
        .platform = parsed.platform,
        .rootfs_storage = parsed.rootfs_storage,
    });
    if (ctx.mode == .json) return machine_output.writeJson(arena, ctx.stdout, result);
    try writeImportResult(ctx.stdout, parsed.ref, result);
    try ctx.stdout.print("platform: {s}/{s}\n", .{ parsed.platform.os, parsed.platform.arch.name() });
}

fn writeImportResult(writer: *Io.Writer, ref: []const u8, result: api.RootfsImportOciResult) !void {
    try writer.print(
        "metadata: {s}\nref: {s}\nresolved: {s}\nrootfs_identity: {s}\n",
        .{ result.metadata_path, ref, result.resolved_image_ref, result.rootfs_storage.index_digest },
    );
}

pub const ResolveResult = struct {
    schema: []const u8 = "spore.rootfs.resolve.result.v1",
    schema_version: u32 = 1,
    ref: []const u8,
    resolved_image_ref: []const u8,
    platform: rootfs.Platform,
};

pub fn resolve(ctx: *const Ctx, args: []const []const u8) !void {
    const arena = ctx.init.arena.allocator();
    if (args.len == 0) cli.exitUsage(arena, ctx.stderr, ctx.mode, "image resolve", "usage: spore image resolve IMAGE");
    const parsed = try rootfs.parseResolveOptions(args);
    const resolved = try api.rootfsResolve(ctx.init, arena, .{
        .ref = parsed.ref,
        .platform = parsed.platform,
    });
    if (ctx.mode == .json) return machine_output.writeJson(arena, ctx.stdout, ResolveResult{
        .ref = parsed.ref,
        .resolved_image_ref = resolved,
        .platform = parsed.platform,
    });
    try ctx.stdout.print("{s}\n", .{resolved});
    try ctx.stderr.print("platform: {s}/{s}\n", .{ parsed.platform.os, parsed.platform.arch.name() });
    try ctx.stderr.flush();
}

pub fn push(ctx: *const Ctx, args: []const []const u8) !void {
    const allocator = ctx.init.arena.allocator();
    const options = try parsePushOptions(args);
    const result = try api.imagePush(ctx.init, allocator, options);
    if (ctx.mode == .json) return machine_output.writeJson(allocator, ctx.stdout, result);
    try ctx.stdout.print(
        "digest_ref: {s}\ntag_ref: {s}\nimage_digest: {s}\nplatform: {s}/{s}\nobjects: {d}\nobjects_written: {d}\nbytes_written: {d}\n",
        .{ result.digest_ref, result.tag_ref orelse "(none)", result.image_digest, result.platform.os, result.platform.arch.name(), result.objects_total, result.objects_written, result.bytes_written },
    );
}

pub fn pack(ctx: *const Ctx, args: []const []const u8) !void {
    const allocator = ctx.init.arena.allocator();
    const options = try parsePackOptions(args);
    const result = try api.imageArchivePack(ctx.init, allocator, options);
    if (ctx.mode == .json) return machine_output.writeJson(allocator, ctx.stdout, result);
    try ctx.stdout.print(
        "archive: {s}\narchive_digest: {s}\nmanifest_digest: {s}\nimage_digest: {s}\nplatform: {s}/{s}\nobjects: {d}\nbytes: {d}\n",
        .{ options.output_path, result.archive_digest, result.manifest_digest, result.image_digest, result.platform.os, result.platform.arch.name(), result.object_count, result.archive_bytes },
    );
}

pub fn unpack(ctx: *const Ctx, args: []const []const u8) !void {
    const allocator = ctx.init.arena.allocator();
    const options = try parseUnpackOptions(args);
    const result = try api.imageArchiveUnpack(ctx.init, allocator, options);
    if (ctx.mode == .json) return machine_output.writeJson(allocator, ctx.stdout, result);
    try ctx.stdout.print(
        "ref: {s}\nresolved: {s}\narchive_digest: {s}\nmanifest_digest: {s}\nimage_digest: {s}\nplatform: {s}/{s}\nobjects: {d}\n",
        .{ options.ref, result.resolved_image_ref, options.archive_digest, result.manifest_digest, result.image_digest, result.platform.os, result.platform.arch.name(), result.object_count },
    );
}

pub fn parsePushOptions(args: []const []const u8) !api.ImagePushOptions {
    var source: ?[]const u8 = null;
    var destination: ?[]const u8 = null;
    var platform: ?rootfs.Platform = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--platform")) {
            i += 1;
            if (i >= args.len) return error.MissingPlatform;
            platform = try rootfs.Platform.parse(args[i]);
        } else if (std.mem.eql(u8, arg, "--to")) {
            i += 1;
            if (i >= args.len) return error.MissingImageReference;
            destination = args[i];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownImageOption;
        } else if (source == null) {
            source = arg;
        } else return error.TooManyImageArguments;
    }
    return .{ .source = source orelse return error.MissingImageSource, .destination = destination orelse return error.MissingImageReference, .platform = platform };
}

pub fn parsePackOptions(args: []const []const u8) !api.ImageArchivePackOptions {
    var source: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var platform: ?rootfs.Platform = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.MissingImageArchiveOutput;
            output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--platform")) {
            i += 1;
            if (i >= args.len) return error.MissingPlatform;
            platform = try rootfs.Platform.parse(args[i]);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownImageOption;
        } else if (source == null) {
            source = arg;
        } else return error.TooManyImageArguments;
    }
    return .{
        .source = source orelse return error.MissingImageSource,
        .output_path = output_path orelse return error.MissingImageArchiveOutput,
        .platform = platform,
    };
}

pub fn parseUnpackOptions(args: []const []const u8) !api.ImageArchiveUnpackOptions {
    var archive_path: ?[]const u8 = null;
    var archive_digest: ?[]const u8 = null;
    var expected_image_digest: ?[]const u8 = null;
    var ref: ?[]const u8 = null;
    var platform: ?rootfs.Platform = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--expected-archive-digest")) {
            i += 1;
            if (i >= args.len) return error.MissingImageArchiveDigest;
            archive_digest = args[i];
        } else if (std.mem.eql(u8, arg, "--expected-image-digest")) {
            i += 1;
            if (i >= args.len) return error.MissingExpectedImageDigest;
            expected_image_digest = args[i];
        } else if (std.mem.eql(u8, arg, "--tag")) {
            i += 1;
            if (i >= args.len) return error.MissingImageReference;
            ref = args[i];
        } else if (std.mem.eql(u8, arg, "--platform")) {
            i += 1;
            if (i >= args.len) return error.MissingPlatform;
            platform = try rootfs.Platform.parse(args[i]);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownImageOption;
        } else if (archive_path == null) {
            archive_path = arg;
        } else return error.TooManyImageArguments;
    }
    return .{
        .archive_path = archive_path orelse return error.MissingImageArchive,
        .archive_digest = archive_digest orelse return error.MissingImageArchiveDigest,
        .expected_image_digest = expected_image_digest orelse return error.MissingExpectedImageDigest,
        .ref = ref orelse return error.MissingImageReference,
        .platform = platform,
    };
}

test "image archive options require immutable digests and allow platform inference" {
    const pack_options = try parsePackOptions(&.{
        "local/app:ci",
        "--output",
        "app.spore-image.tar.gz",
        "--platform",
        "linux/arm64",
    });
    try std.testing.expectEqualStrings("local/app:ci", pack_options.source);
    try std.testing.expectEqual(.arm64, pack_options.platform.?.arch);
    try std.testing.expectEqual(null, (try parsePackOptions(&.{
        "local/app:ci",
        "--output",
        "app.spore-image.tar.gz",
    })).platform);

    const unpack_options = try parseUnpackOptions(&.{
        "app.spore-image.tar.gz",
        "--expected-archive-digest",
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "--expected-image-digest",
        "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "--platform",
        "linux/amd64",
        "--tag",
        "local/app:ci",
    });
    try std.testing.expectEqual(.amd64, unpack_options.platform.?.arch);
    try std.testing.expectError(error.MissingImageArchiveDigest, parseUnpackOptions(&.{
        "app.spore-image.tar.gz",
        "--expected-image-digest",
        "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "--platform",
        "linux/amd64",
        "--tag",
        "local/app:ci",
    }));
}

test "json image pack and unpack print their documented result documents" {
    const chunk = @import("chunk.zig");
    const disk_index = @import("disk_index.zig");
    const local_image = @import("local_image.zig");
    const local_paths = @import("local_paths.zig");
    const rootfs_cas = @import("rootfs_cas.zig");
    const spore = @import("spore.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();

    const producer_cache = try tmp_dir.path("producer-cache");
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, producer_cache);
    const init = std.process.Init{
        .minimal = undefined,
        .arena = &arena,
        .gpa = allocator,
        .io = io,
        .environ_map = &env,
        .preopens = .empty,
    };

    const object_bytes = "image cli json object";
    const object_hex = chunk.ChunkId.fromContents(object_bytes).toHex();
    const object_digest = try std.fmt.allocPrint(allocator, "blake3:{s}", .{object_hex[0..]});
    const entries = [_]disk_index.DiskIndexChunk{.{ .logical_chunk = 0, .id = try chunk.ChunkId.fromDigest(object_digest) }};
    const encoded_index = try disk_index.encodeCanonicalAlloc(allocator, .{
        .kind = disk_index.disk_index_kind,
        .logical_size = object_bytes.len,
        .chunk_size = spore.disk_chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .object_namespace = spore.rootfs_storage_object_namespace,
        .chunks = &entries,
    });
    const storage = spore.RootfsStorage{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = .{ .mmio_slot = 1 },
        .logical_size = object_bytes.len,
        .chunk_size = spore.disk_chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .index_digest = encoded_index.digest,
        .base_identity = encoded_index.digest,
        .object_namespace = spore.rootfs_storage_object_namespace,
    };
    const index_path = try rootfs_cas.manifestIndexPath(allocator, producer_cache, storage.index_digest);
    _ = try rootfs_cas.installStorageIndexPath(allocator, io, index_path, encoded_index.bytes, storage);
    const object_path = try rootfs_cas.manifestObjectPath(allocator, producer_cache, object_digest);
    _ = try rootfs_cas.installChunkPath(allocator, io, object_path, object_bytes, object_digest, object_bytes.len);
    try rootfs_cas.markStorageComplete(io, allocator, producer_cache, storage.index_digest);
    _ = try local_image.lockAndPublish(io, allocator, producer_cache, .{
        .platform = .{},
        .config = .{ .architecture = .arm64, .os = "linux" },
        .storage = storage,
        .name = "local/cli-json:producer",
    });

    var pack_out: Io.Writer.Allocating = .init(allocator);
    var discard: Io.Writer = .failing;
    const pack_ctx = Ctx{ .init = init, .stdout = &pack_out.writer, .stderr = &discard, .mode = .json };
    try pack(&pack_ctx, &.{ "local/cli-json:producer", "--platform", "linux/arm64", "--output", try tmp_dir.path("image.tar.gz") });
    const pack_doc = try std.json.parseFromSliceLeaky(std.json.Value, allocator, pack_out.written(), .{});
    try std.testing.expectEqualStrings("spore.image.archive.pack.result.v1", pack_doc.object.get("schema").?.string);
    try std.testing.expectEqualStrings("image", pack_doc.object.get("resource_type").?.string);
    const archive_digest = pack_doc.object.get("archive_digest").?.string;
    const image_digest = pack_doc.object.get("image_digest").?.string;

    try env.put(local_paths.rootfs_cache_env, try tmp_dir.path("consumer-cache"));
    var unpack_out: Io.Writer.Allocating = .init(allocator);
    const unpack_ctx = Ctx{ .init = init, .stdout = &unpack_out.writer, .stderr = &discard, .mode = .json };
    try unpack(&unpack_ctx, &.{
        try tmp_dir.path("image.tar.gz"),
        "--expected-archive-digest",
        archive_digest,
        "--expected-image-digest",
        image_digest,
        "--platform",
        "linux/arm64",
        "--tag",
        "local/cli-json:consumer",
    });
    const unpack_doc = try std.json.parseFromSliceLeaky(std.json.Value, allocator, unpack_out.written(), .{});
    try std.testing.expectEqualStrings("spore.image.archive.unpack.result.v1", unpack_doc.object.get("schema").?.string);
    try std.testing.expectEqualStrings(image_digest, unpack_doc.object.get("image_digest").?.string);
}
