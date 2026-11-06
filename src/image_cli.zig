//! CLI adapter for native image archives and image stores.

const std = @import("std");
const TestDir = @import("test_dir.zig").TestDir;
const Io = std.Io;
const api = @import("api.zig");
const machine_output = @import("machine_output.zig");
const rootfs = @import("rootfs.zig");
const run_mod = @import("run.zig");

const usage =
    \\Usage:
    \\  spore image push local/name:tag STORE/TAG [--platform os/arch]
    \\  spore image pack local/name:tag --platform os/arch --out image.tar.gz
    \\  spore image unpack image.tar.gz --archive-digest sha256:... --expected-image-digest blake3:... --platform os/arch --ref local/name:tag
    \\
    \\STORE is a directory, a file:// URL or s3://bucket/prefix (uploaded with
    \\the aws CLI); TAG may be blake3:<digest>.
    \\Run a pushed image with `spore run --image <store-url>/TAG`.
    \\
    \\Options:
    \\  --archive-digest DIGEST  Expected immutable SHA-256 archive identity
    \\  --expected-image-digest DIGEST  Expected native BLAKE3 image identity
    \\  --ref local/name:tag  Local mutable image ref to publish
    \\  --platform os/arch    linux/arm64 or linux/amd64 (push defaults to this host's)
    \\  --out PATH            New image archive path
    \\  -h, --help            Show this help
    \\
;

pub fn run(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer, mode: machine_output.Mode) !void {
    if (args.len == 0) {
        if (mode == .json) return error.MissingImageCommand;
        try stdout.writeAll(usage);
        return;
    }
    if (wantsHelp(args)) {
        try stdout.writeAll(usage);
        return;
    }
    const allocator = init.arena.allocator();
    if (std.mem.eql(u8, args[0], "push")) {
        const options = try parsePushOptions(args[1..]);
        const result = try api.imagePush(init, allocator, options);
        if (mode == .json) return machine_output.writeJson(allocator, stdout, result);
        try stdout.print(
            "ref: {s}\nimage_digest: {s}\nobjects: {d}\nobjects_written: {d}\nbytes_written: {d}\n",
            .{ result.ref, result.image_digest, result.objects_total, result.objects_written, result.bytes_written },
        );
        return;
    }
    if (std.mem.eql(u8, args[0], "pack")) {
        const options = try parsePackOptions(args[1..]);
        const result = try api.imageArchivePack(init, allocator, options);
        if (mode == .json) return machine_output.writeJson(allocator, stdout, result);
        try stdout.print(
            "archive: {s}\narchive_digest: {s}\nmanifest_digest: {s}\nimage_digest: {s}\nplatform: {s}/{s}\nobjects: {d}\nbytes: {d}\n",
            .{ options.output_path, result.archive_digest, result.manifest_digest, result.image_digest, options.platform.os, options.platform.arch.name(), result.object_count, result.archive_bytes },
        );
        return;
    }
    if (std.mem.eql(u8, args[0], "unpack")) {
        const options = try parseUnpackOptions(args[1..]);
        const result = try api.imageArchiveUnpack(init, allocator, options);
        if (mode == .json) return machine_output.writeJson(allocator, stdout, result);
        try stdout.print(
            "ref: {s}\nresolved: {s}\narchive_digest: {s}\nmanifest_digest: {s}\nimage_digest: {s}\nplatform: {s}/{s}\nobjects: {d}\n",
            .{ options.ref, result.resolved_image_ref, options.archive_digest, result.manifest_digest, result.image_digest, options.platform.os, options.platform.arch.name(), result.object_count },
        );
        return;
    }
    return error.UnknownImageCommand;
}

pub fn parsePushOptions(args: []const []const u8) !api.ImagePushOptions {
    var positional: [2][]const u8 = undefined;
    var count: usize = 0;
    var platform: rootfs.Platform = run_mod.direct_image_platform;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--platform")) {
            i += 1;
            if (i >= args.len) return error.MissingPlatform;
            platform = try rootfs.Platform.parse(args[i]);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownImageOption;
        } else if (count < positional.len) {
            positional[count] = arg;
            count += 1;
        } else return error.TooManyImageArguments;
    }
    if (count == 0) return error.MissingImageSource;
    if (count == 1) return error.MissingImageReference;
    return .{ .source = positional[0], .destination = positional[1], .platform = platform };
}

pub fn parsePackOptions(args: []const []const u8) !api.ImageArchivePackOptions {
    var source: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var platform: ?rootfs.Platform = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--out")) {
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
        .platform = platform orelse return error.MissingPlatform,
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
        if (std.mem.eql(u8, arg, "--archive-digest")) {
            i += 1;
            if (i >= args.len) return error.MissingImageArchiveDigest;
            archive_digest = args[i];
        } else if (std.mem.eql(u8, arg, "--expected-image-digest")) {
            i += 1;
            if (i >= args.len) return error.MissingExpectedImageDigest;
            expected_image_digest = args[i];
        } else if (std.mem.eql(u8, arg, "--ref")) {
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
        .platform = platform orelse return error.MissingPlatform,
    };
}

fn wantsHelp(args: []const []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return true;
    return false;
}

test "image archive options require immutable digest and explicit platform" {
    const pack = try parsePackOptions(&.{
        "local/app:ci",
        "--out",
        "app.spore-image.tar.gz",
        "--platform",
        "linux/arm64",
    });
    try std.testing.expectEqualStrings("local/app:ci", pack.source);
    try std.testing.expectEqual(.arm64, pack.platform.arch);
    try std.testing.expectError(error.MissingPlatform, parsePackOptions(&.{
        "local/app:ci",
        "--out",
        "app.spore-image.tar.gz",
    }));

    const unpack = try parseUnpackOptions(&.{
        "app.spore-image.tar.gz",
        "--archive-digest",
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "--expected-image-digest",
        "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "--platform",
        "linux/amd64",
        "--ref",
        "local/app:ci",
    });
    try std.testing.expectEqual(.amd64, unpack.platform.arch);
    try std.testing.expectError(error.MissingImageArchiveDigest, parseUnpackOptions(&.{
        "app.spore-image.tar.gz",
        "--expected-image-digest",
        "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "--platform",
        "linux/amd64",
        "--ref",
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
    try run(init, &.{ "pack", "local/cli-json:producer", "--platform", "linux/arm64", "--out", try tmp_dir.path("image.tar.gz") }, &pack_out.writer, .json);
    const pack = try std.json.parseFromSliceLeaky(std.json.Value, allocator, pack_out.written(), .{});
    try std.testing.expectEqualStrings("spore.image.archive.pack.result.v1", pack.object.get("schema").?.string);
    try std.testing.expectEqualStrings("image", pack.object.get("resource_type").?.string);
    const archive_digest = pack.object.get("archive_digest").?.string;
    const image_digest = pack.object.get("image_digest").?.string;

    try env.put(local_paths.rootfs_cache_env, try tmp_dir.path("consumer-cache"));
    var unpack_out: Io.Writer.Allocating = .init(allocator);
    try run(init, &.{
        "unpack",                  try tmp_dir.path("image.tar.gz"),
        "--archive-digest",        archive_digest,
        "--expected-image-digest", image_digest,
        "--platform",              "linux/arm64",
        "--ref",                   "local/cli-json:consumer",
    }, &unpack_out.writer, .json);
    const unpack = try std.json.parseFromSliceLeaky(std.json.Value, allocator, unpack_out.written(), .{});
    try std.testing.expectEqualStrings("spore.image.archive.unpack.result.v1", unpack.object.get("schema").?.string);
    try std.testing.expectEqualStrings(image_digest, unpack.object.get("image_digest").?.string);
}
