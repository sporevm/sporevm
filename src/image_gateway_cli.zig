//! CLI adapter for explicit image-gateway pulls.

const std = @import("std");
const Io = std.Io;
const api = @import("api.zig");
const image_archive = @import("image_archive.zig");
const gateway_pull = @import("image_gateway_pull.zig");
const machine_output = @import("machine_output.zig");
const rootfs = @import("rootfs.zig");

pub fn run(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer, mode: machine_output.Mode) !void {
    if (args.len == 0) {
        if (mode == .json) return error.MissingImageCommand;
        try stdout.writeAll(gateway_pull.usage);
        return;
    }
    if (wantsHelp(args)) {
        try stdout.writeAll(gateway_pull.usage);
        return;
    }
    if (std.mem.eql(u8, args[0], "pull")) {
        const options = try parsePullOptions(args[1..]);
        const result = try api.imageGatewayPull(init, init.arena.allocator(), options);
        if (mode == .json) return machine_output.writeJson(init.arena.allocator(), stdout, result);
        try stdout.print(
            "ref: {s}\nresolved: {s}\nplatform: {s}/{s}\nobjects_fetched: {d}\nbytes_fetched: {d}\n",
            .{ options.ref, result.resolved_image_ref, options.platform.os, options.platform.arch.name(), result.objects_fetched, result.bytes_fetched },
        );
        return;
    }
    if (std.mem.eql(u8, args[0], "pack")) {
        const options = try parsePackOptions(args[1..]);
        const result = try api.imageArchivePack(init, init.arena.allocator(), options);
        if (mode == .json) return machine_output.writeJson(init.arena.allocator(), stdout, result);
        try stdout.print(
            "archive: {s}\narchive_digest: {s}\nmanifest_digest: {s}\nimage_digest: {s}\nplatform: {s}/{s}\nobjects: {d}\nbytes: {d}\n",
            .{ options.output_path, result.archive_digest, result.manifest_digest, result.image_digest, options.platform.os, options.platform.arch.name(), result.object_count, result.archive_bytes },
        );
        return;
    }
    if (std.mem.eql(u8, args[0], "unpack")) {
        const options = try parseUnpackOptions(args[1..]);
        const result = try api.imageArchiveUnpack(init, init.arena.allocator(), options);
        if (mode == .json) return machine_output.writeJson(init.arena.allocator(), stdout, result);
        try stdout.print(
            "ref: {s}\nresolved: {s}\narchive_digest: {s}\nmanifest_digest: {s}\nimage_digest: {s}\nplatform: {s}/{s}\nobjects: {d}\n",
            .{ options.ref, result.resolved_image_ref, options.archive_digest, result.manifest_digest, result.image_digest, options.platform.os, options.platform.arch.name(), result.object_count },
        );
        return;
    }
    if (std.mem.eql(u8, args[0], "export-fixture")) {
        const options = try parseExportFixtureOptions(args[1..]);
        const result = try gateway_pull.exportFixture(init, init.arena.allocator(), options);
        if (mode == .json) return machine_output.writeJson(init.arena.allocator(), stdout, result);
        try stdout.print("fixture: {s}\nmanifest: {s}\nimage: {s}\nobjects: {d}\n", .{
            options.output_dir,
            result.manifest_digest,
            result.image_digest,
            result.object_count,
        });
        return;
    }
    return error.UnknownImageCommand;
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
    const selected = platform orelse return error.MissingPlatform;
    return .{
        .source = source orelse return error.MissingImageSource,
        .output_path = output_path orelse return error.MissingImageArchiveOutput,
        .platform = .{ .os = selected.os, .arch = selected.arch },
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
    const selected = platform orelse return error.MissingPlatform;
    return .{
        .archive_path = archive_path orelse return error.MissingImageArchive,
        .archive_digest = archive_digest orelse return error.MissingImageArchiveDigest,
        .expected_image_digest = expected_image_digest orelse return error.MissingExpectedImageDigest,
        .ref = ref orelse return error.MissingImageReference,
        .platform = .{ .os = selected.os, .arch = selected.arch },
    };
}

pub fn parsePullOptions(args: []const []const u8) !api.ImageGatewayPullOptions {
    var source: ?[]const u8 = null;
    var gateway_url: ?[]const u8 = null;
    var repository: ?[]const u8 = null;
    var ref: ?[]const u8 = null;
    var platform = rootfs.Platform{
        .os = gateway_pull.default_platform.os,
        .arch = gateway_pull.default_platform.arch,
    };
    var allow_insecure_http = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--gateway")) {
            i += 1;
            if (i >= args.len) return error.MissingGatewayUrl;
            gateway_url = args[i];
        } else if (std.mem.eql(u8, arg, "--repository")) {
            i += 1;
            if (i >= args.len) return error.MissingGatewayRepository;
            repository = args[i];
        } else if (std.mem.eql(u8, arg, "--ref")) {
            i += 1;
            if (i >= args.len) return error.MissingImageReference;
            ref = args[i];
        } else if (std.mem.eql(u8, arg, "--platform")) {
            i += 1;
            if (i >= args.len) return error.MissingPlatform;
            platform = try rootfs.Platform.parse(args[i]);
        } else if (std.mem.eql(u8, arg, "--allow-insecure-http")) {
            allow_insecure_http = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownImageOption;
        } else if (source == null) {
            source = arg;
        } else {
            return error.TooManyImageArguments;
        }
    }
    return .{
        .source = source orelse return error.MissingImageSource,
        .gateway_url = gateway_url orelse return error.MissingGatewayUrl,
        .repository = repository orelse return error.MissingGatewayRepository,
        .ref = ref orelse return error.MissingImageReference,
        .platform = .{ .os = platform.os, .arch = platform.arch },
        .allow_insecure_http = allow_insecure_http,
    };
}

pub fn parseExportFixtureOptions(args: []const []const u8) !gateway_pull.ExportFixtureOptions {
    var source: ?[]const u8 = null;
    var repository: ?[]const u8 = null;
    var metadata_path: ?[]const u8 = null;
    var output_dir: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--repository")) {
            i += 1;
            if (i >= args.len) return error.MissingGatewayRepository;
            repository = args[i];
        } else if (std.mem.eql(u8, arg, "--metadata")) {
            i += 1;
            if (i >= args.len) return error.MissingMetadataPath;
            metadata_path = args[i];
        } else if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= args.len) return error.MissingOutputPath;
            output_dir = args[i];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownImageOption;
        } else if (source == null) {
            source = arg;
        } else {
            return error.TooManyImageArguments;
        }
    }
    return .{
        .source = source orelse return error.MissingImageSource,
        .repository = repository orelse return error.MissingGatewayRepository,
        .metadata_path = metadata_path orelse return error.MissingMetadataPath,
        .output_dir = output_dir orelse return error.MissingOutputPath,
    };
}

fn wantsHelp(args: []const []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return true;
    return false;
}

test "image pull options require explicit gateway repository and local ref" {
    const parsed = try parsePullOptions(&.{
        "docker.io/library/alpine:3.20",
        "--gateway",
        "https://images.example.test",
        "--repository",
        "team/base-images",
        "--ref",
        "local/alpine:gateway",
        "--platform",
        "linux/amd64",
    });
    try std.testing.expectEqualStrings("docker.io/library/alpine:3.20", parsed.source);
    try std.testing.expectEqual(.amd64, parsed.platform.arch);
    try std.testing.expectError(error.MissingGatewayUrl, parsePullOptions(&.{
        "docker.io/library/alpine:3.20",
        "--repository",
        "team/base-images",
        "--ref",
        "local/alpine:gateway",
    }));
    const defaults = try parsePullOptions(&.{
        "docker.io/library/alpine:3.20",
        "--gateway",
        "https://images.example.test",
        "--repository",
        "team/base-images",
        "--ref",
        "local/alpine:gateway",
    });
    try std.testing.expectEqual(gateway_pull.default_platform.arch, defaults.platform.arch);
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
    const local_paths = @import("local_paths.zig");
    const rootfs_cas = @import("rootfs_cas.zig");
    const spore = @import("spore.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tmp = "zig-cache/test-image-cli-json";
    Io.Dir.cwd().deleteTree(io, tmp) catch {};
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);

    const producer_cache = tmp ++ "/producer-cache";
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
    const entries = [_]disk_index.DiskIndexChunk{.{ .logical_chunk = 0, .digest = object_digest }};
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
    _ = try rootfs.publishIndexedImage(init, allocator, .{
        .ref = "local/cli-json:producer",
        .platform = .{},
        .config = .{ .architecture = .arm64, .os = "linux" },
        .rootfs_storage = storage,
    });

    var pack_out: Io.Writer.Allocating = .init(allocator);
    try run(init, &.{ "pack", "local/cli-json:producer", "--platform", "linux/arm64", "--out", tmp ++ "/image.tar.gz" }, &pack_out.writer, .json);
    const pack = try std.json.parseFromSliceLeaky(std.json.Value, allocator, pack_out.written(), .{});
    try std.testing.expectEqualStrings("spore.image.archive.pack.result.v1", pack.object.get("schema").?.string);
    try std.testing.expectEqualStrings("image", pack.object.get("resource_type").?.string);
    const archive_digest = pack.object.get("archive_digest").?.string;
    const image_digest = pack.object.get("image_digest").?.string;

    try env.put(local_paths.rootfs_cache_env, tmp ++ "/consumer-cache");
    var unpack_out: Io.Writer.Allocating = .init(allocator);
    try run(init, &.{
        "unpack",                  tmp ++ "/image.tar.gz",
        "--archive-digest",        archive_digest,
        "--expected-image-digest", image_digest,
        "--platform",              "linux/arm64",
        "--ref",                   "local/cli-json:consumer",
    }, &unpack_out.writer, .json);
    const unpack = try std.json.parseFromSliceLeaky(std.json.Value, allocator, unpack_out.written(), .{});
    try std.testing.expectEqualStrings("spore.image.archive.unpack.result.v1", unpack.object.get("schema").?.string);
    try std.testing.expectEqualStrings(image_digest, unpack.object.get("image_digest").?.string);
}
