//! Eager, verified installation of one image from an image gateway.
//!
//! Network bytes stay outside the rootfs cache until the complete platform
//! closure has been fetched and verified. Publication then reuses the same CAS
//! and local-ref transaction as native builds and OCI imports.

const std = @import("std");
const chunk = @import("chunk.zig");
const disk_index = @import("disk_index.zig");
const gateway = @import("image_gateway.zig");
const gateway_manifest = @import("image_gateway_manifest.zig");
const image = @import("image.zig");
const local_paths = @import("local_paths.zig");
const rootfs = @import("rootfs.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const spore = @import("spore.zig");

const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const usage =
    \\Usage:
    \\  spore image pull SOURCE --gateway URL --repository NAME --ref local/name:tag [--platform os/arch]
    \\  spore image export-fixture SOURCE --repository NAME --metadata PATH --out DIR
    \\
    \\Options:
    \\  --gateway URL          Image gateway origin (HTTPS required)
    \\  --repository NAME     Gateway repository containing the source alias
    \\  --ref local/name:tag  Local mutable image ref to publish
    \\  --platform os/arch    linux/arm64 or linux/amd64 (default: linux/arm64)
    \\  --allow-insecure-http Allow HTTP only for a loopback fixture gateway
    \\  --metadata PATH       Existing indexed-rootfs metadata for export-fixture
    \\  --out DIR             New static gateway fixture directory
    \\  -h, --help            Show this help
    \\
;

pub const PullOptions = struct {
    source: []const u8,
    gateway_url: []const u8,
    repository: []const u8,
    ref: []const u8,
    platform: gateway.Platform = default_platform,
    allow_insecure_http: bool = false,
};

pub const default_platform = gateway.Platform{ .os = "linux", .arch = .arm64 };

pub const PullResult = struct {
    resolved_image_ref: []const u8,
    image_digest: []const u8,
    objects_fetched: usize,
    bytes_fetched: u64,
};

pub const ExportFixtureOptions = struct {
    source: []const u8,
    repository: []const u8,
    metadata_path: []const u8,
    output_dir: []const u8,
};

pub const ExportFixtureResult = struct {
    manifest_digest: []const u8,
    image_digest: []const u8,
    object_count: usize,
};

const CachedMetadata = struct {
    platform: rootfs.Platform,
    config: image.Config,
    rootfs_storage: spore.RootfsStorage,
};

const StagedObject = struct {
    digest: []const u8,
    expected_size: usize,
    path: []const u8,
};

pub fn pull(init: std.process.Init, allocator: std.mem.Allocator, options: PullOptions) !PullResult {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const result = try pullInner(init, arena_state.allocator(), options);
    const resolved_image_ref = try allocator.dupe(u8, result.resolved_image_ref);
    errdefer allocator.free(resolved_image_ref);
    return .{
        .resolved_image_ref = resolved_image_ref,
        .image_digest = try allocator.dupe(u8, result.image_digest),
        .objects_fetched = result.objects_fetched,
        .bytes_fetched = result.bytes_fetched,
    };
}

fn pullInner(init: std.process.Init, allocator: std.mem.Allocator, options: PullOptions) !PullResult {
    try validateGatewayUrl(options.gateway_url, options.allow_insecure_http);
    try validateRepository(options.repository);
    try rootfs.validateLocalTagRef(options.ref);
    if (options.source.len == 0 or options.source.len > gateway_manifest.max_reference_bytes) return error.InvalidGatewaySource;

    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    defer allocator.free(cache_root);
    try Io.Dir.cwd().createDirPath(init.io, cache_root);

    const stage_dir = try stageDirPath(allocator, init.io, cache_root);
    defer allocator.free(stage_dir);
    defer Io.Dir.cwd().deleteTree(init.io, stage_dir) catch {};
    try Io.Dir.cwd().createDirPath(init.io, stage_dir);
    try chmodPath(allocator, stage_dir, 0o700);

    var client: std.http.Client = .{ .allocator = allocator, .io = init.io };
    defer client.deinit();

    const source_key = try sourceKeyAlloc(allocator, options.source);
    defer allocator.free(source_key);
    const index_url = try endpointAlloc(allocator, options.gateway_url, options.repository, &.{ "sources", source_key, "index" });
    defer allocator.free(index_url);
    const index_bytes = try httpGetAlloc(allocator, &client, index_url, gateway.max_platform_index_bytes);
    defer allocator.free(index_bytes);
    var platform_index = try gateway.parsePlatformIndex(allocator, index_bytes);
    defer platform_index.deinit();
    const selected = try gateway.selectManifest(platform_index.value, options.platform);

    const manifest_url = try endpointAlloc(allocator, options.gateway_url, options.repository, &.{ "manifests", selected.manifest_digest, "manifest" });
    defer allocator.free(manifest_url);
    const manifest_bytes = try httpGetAlloc(allocator, &client, manifest_url, gateway_manifest.max_image_manifest_bytes);
    defer allocator.free(manifest_bytes);

    const config_url = try endpointAlloc(allocator, options.gateway_url, options.repository, &.{ "manifests", selected.manifest_digest, "config" });
    defer allocator.free(config_url);
    const config_bytes = try httpGetAlloc(allocator, &client, config_url, gateway_manifest.max_config_blob_bytes);
    defer allocator.free(config_bytes);

    const rootfs_index_url = try endpointAlloc(allocator, options.gateway_url, options.repository, &.{ "manifests", selected.manifest_digest, "rootfs-index" });
    defer allocator.free(rootfs_index_url);
    const rootfs_index_bytes = try httpGetAlloc(allocator, &client, rootfs_index_url, disk_index.max_index_bytes);
    defer allocator.free(rootfs_index_bytes);

    var verified = try gateway_manifest.verifySelectedImageManifest(
        allocator,
        selected,
        platform_index.value.source_index_digest,
        manifest_bytes,
        config_bytes,
        rootfs_index_bytes,
    );
    defer verified.deinit();
    const manifest = verified.value;
    const storage = gatewayStorage(manifest.image.rootfs_storage);

    var parsed_config = try gateway_manifest.parseCanonicalConfig(allocator, config_bytes);
    defer parsed_config.deinit();
    var parsed_index = try disk_index.parseDiskIndex(allocator, rootfs_index_bytes, .{
        .logical_size = storage.logical_size,
        .chunk_size = storage.chunk_size,
        .hash_algorithm = storage.hash_algorithm,
        .object_namespace = storage.object_namespace,
        .index_digest = storage.index_digest,
    });
    defer parsed_index.deinit();

    const staged = try allocator.alloc(StagedObject, parsed_index.value.chunks.len);
    defer allocator.free(staged);
    var staged_by_digest = std.StringHashMap(usize).init(allocator);
    defer staged_by_digest.deinit();
    var staged_count: usize = 0;
    defer for (staged[0..staged_count]) |entry| {
        allocator.free(entry.digest);
        allocator.free(entry.path);
    };
    var bytes_fetched: u64 = @intCast(index_bytes.len + manifest_bytes.len + config_bytes.len + rootfs_index_bytes.len);
    for (parsed_index.value.chunks) |entry| {
        const expected_size = try rootfs_cas.storageChunkLen(storage, entry.logical_chunk);
        if (staged_by_digest.get(entry.digest)) |existing| {
            if (staged[existing].expected_size != expected_size) return error.BadGatewayObject;
            continue;
        }
        const object_url = try endpointAlloc(allocator, options.gateway_url, options.repository, &.{ "manifests", selected.manifest_digest, "objects", entry.digest });
        defer allocator.free(object_url);
        const object_bytes = try httpGetAlloc(allocator, &client, object_url, expected_size);
        defer allocator.free(object_bytes);
        if (object_bytes.len != expected_size) return error.BadGatewayObject;
        try verifyObjectBytes(entry.digest, object_bytes);
        const path = try std.fmt.allocPrint(allocator, "{s}/{d}.chunk", .{ stage_dir, staged_count });
        errdefer allocator.free(path);
        try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = object_bytes });
        const digest = try allocator.dupe(u8, entry.digest);
        errdefer allocator.free(digest);
        try staged_by_digest.put(digest, staged_count);
        staged[staged_count] = .{
            .digest = digest,
            .expected_size = expected_size,
            .path = path,
        };
        staged_count += 1;
        bytes_fetched += @intCast(object_bytes.len);
    }

    var cache_lock = try rootfs.lockRootfsCacheExclusive(init.io, allocator, cache_root);
    defer cache_lock.deinit();
    try rootfs_cas.removeStorageCompleteStamp(init.io, allocator, cache_root, storage.index_digest);
    for (staged[0..staged_count]) |entry| {
        const read_limit = std.math.add(usize, entry.expected_size, 1) catch return error.BadGatewayObject;
        const bytes = try Io.Dir.cwd().readFileAlloc(init.io, entry.path, allocator, .limited(read_limit));
        defer allocator.free(bytes);
        const installed_path = try rootfs_cas.manifestObjectPath(allocator, cache_root, entry.digest);
        defer allocator.free(installed_path);
        _ = try rootfs_cas.installChunkPathRepairingInvalid(allocator, init.io, installed_path, bytes, entry.digest, entry.expected_size);
    }
    const installed_index_path = try rootfs_cas.manifestIndexPath(allocator, cache_root, storage.index_digest);
    defer allocator.free(installed_index_path);
    _ = try rootfs_cas.installStorageIndexPathRepairingInvalid(allocator, init.io, installed_index_path, rootfs_index_bytes, storage);
    if (!try rootfs_cas.storageContentComplete(init.io, allocator, cache_root, storage)) return error.IncompleteGatewayImage;
    try rootfs_cas.markStorageComplete(init.io, allocator, cache_root, storage.index_digest);
    const published = try rootfs.publishIndexedImageWithCacheLockHeld(init.io, allocator, cache_root, .{
        .ref = options.ref,
        .platform = .{ .os = options.platform.os, .arch = options.platform.arch },
        .config = parsed_config.value,
        .rootfs_storage = storage,
        .expected_image_digest = manifest.image.digest,
    });
    return .{
        .resolved_image_ref = published.resolved_image_ref,
        .image_digest = published.image_manifest_digest,
        .objects_fetched = staged_count,
        .bytes_fetched = bytes_fetched,
    };
}

pub fn deinitPullResult(allocator: std.mem.Allocator, result: PullResult) void {
    allocator.free(result.resolved_image_ref);
    allocator.free(result.image_digest);
}

/// Export one already-built indexed rootfs as a repository-bound static HTTP
/// fixture. `python3 -m http.server --directory OUTPUT` can serve the result.
pub fn exportFixture(init: std.process.Init, allocator: std.mem.Allocator, options: ExportFixtureOptions) !ExportFixtureResult {
    try validateRepository(options.repository);
    if (options.source.len == 0 or options.source.len > gateway_manifest.max_reference_bytes) return error.InvalidGatewaySource;
    if (Io.Dir.cwd().access(init.io, options.output_dir, .{})) |_| {
        return error.GatewayFixtureOutputExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try Io.Dir.cwd().createDirPath(init.io, options.output_dir);
    errdefer Io.Dir.cwd().deleteTree(init.io, options.output_dir) catch {};

    const metadata_bytes = try Io.Dir.cwd().readFileAlloc(init.io, options.metadata_path, allocator, .limited(1024 * 1024));
    defer allocator.free(metadata_bytes);
    var metadata = try std.json.parseFromSlice(CachedMetadata, allocator, metadata_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    });
    defer metadata.deinit();
    const storage = metadata.value.rootfs_storage;
    try spore.validateRootfsStorageDescriptor(storage);
    if (!std.mem.eql(u8, metadata.value.platform.os, "linux") or metadata.value.config.os == null or
        metadata.value.config.architecture == null or
        !std.mem.eql(u8, metadata.value.config.os.?, metadata.value.platform.os) or
        metadata.value.config.architecture.? != metadata.value.platform.arch) return error.UnsupportedPlatform;

    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    defer allocator.free(cache_root);
    const index_path = try rootfs_cas.manifestIndexPath(allocator, cache_root, storage.index_digest);
    defer allocator.free(index_path);
    const index_bytes = try rootfs_cas.readVerifiedStorageIndexPath(allocator, index_path, storage);
    defer allocator.free(index_bytes);
    var parsed_index = try disk_index.parseDiskIndex(allocator, index_bytes, .{
        .logical_size = storage.logical_size,
        .chunk_size = storage.chunk_size,
        .hash_algorithm = storage.hash_algorithm,
        .object_namespace = storage.object_namespace,
        .index_digest = storage.index_digest,
    });
    defer parsed_index.deinit();

    const config_bytes = try image.canonicalConfigJson(allocator, metadata.value.config);
    defer allocator.free(config_bytes);
    const config_transport = try gateway.transportDigestAlloc(allocator, config_bytes);
    defer allocator.free(config_transport);
    const config_digest = try image.configDigestAlloc(allocator, config_bytes);
    defer allocator.free(config_digest);
    const image_digest = try image.imageDigestAlloc(allocator, storage.index_digest, config_bytes);
    errdefer allocator.free(image_digest);

    var objects = std.StringHashMap(u64).init(allocator);
    defer objects.deinit();
    var object_bytes: u64 = 0;
    for (parsed_index.value.chunks) |entry| {
        const expected_size = try rootfs_cas.storageChunkLen(storage, entry.logical_chunk);
        const gop = try objects.getOrPut(entry.digest);
        if (gop.found_existing) {
            if (gop.value_ptr.* != expected_size) return error.BadManifest;
        } else {
            gop.value_ptr.* = expected_size;
            object_bytes = std.math.add(u64, object_bytes, expected_size) catch return error.BadManifest;
        }
    }

    const manifest_value = gateway_manifest.ImageManifest{
        .kind = gateway_manifest.image_manifest_kind,
        .image = .{
            .digest = image_digest,
            .platform = .{ .os = metadata.value.platform.os, .arch = metadata.value.platform.arch },
            .config_blob = .{
                .transport_digest = config_transport,
                .config_digest = config_digest,
                .bytes = config_bytes.len,
            },
            .rootfs_storage = .{
                .kind = storage.kind,
                .device = .{
                    .kind = storage.device.kind,
                    .role = storage.device.role,
                    .virtio_device_id = storage.device.virtio_device_id,
                    .mmio_slot = storage.device.mmio_slot,
                },
                .logical_size = storage.logical_size,
                .chunk_size = storage.chunk_size,
                .hash_algorithm = storage.hash_algorithm,
                .index_digest = storage.index_digest,
                .base_identity = storage.base_identity,
                .object_namespace = storage.object_namespace,
            },
        },
        .rootfs_index = .{
            .digest = storage.index_digest,
            .bytes = index_bytes.len,
            .object_count = objects.count(),
            .object_bytes = object_bytes,
        },
    };
    const encoded_manifest = try gateway_manifest.encodeImageManifestAlloc(allocator, manifest_value);
    defer encoded_manifest.deinit(allocator);
    const platform_manifests = [_]gateway.ManifestDescriptor{.{
        .platform = manifest_value.image.platform,
        .manifest_digest = encoded_manifest.transport_digest,
        .image_digest = image_digest,
    }};
    const encoded_platform = try gateway.encodePlatformIndexAlloc(allocator, .{
        .kind = gateway.platform_index_kind,
        .manifests = &platform_manifests,
    });
    defer encoded_platform.deinit(allocator);

    const manifest_base = try fixturePathAlloc(allocator, options.output_dir, options.repository, &.{ "manifests", encoded_manifest.transport_digest });
    defer allocator.free(manifest_base);
    const manifest_path = try std.fs.path.join(allocator, &.{ manifest_base, "manifest" });
    defer allocator.free(manifest_path);
    try writeFixtureFile(init.io, allocator, manifest_path, encoded_manifest.bytes);
    const config_path = try std.fs.path.join(allocator, &.{ manifest_base, "config" });
    defer allocator.free(config_path);
    try writeFixtureFile(init.io, allocator, config_path, config_bytes);
    const fixture_index_path = try std.fs.path.join(allocator, &.{ manifest_base, "rootfs-index" });
    defer allocator.free(fixture_index_path);
    try writeFixtureFile(init.io, allocator, fixture_index_path, index_bytes);

    var object_it = objects.iterator();
    while (object_it.next()) |entry| {
        const source_path = try rootfs_cas.manifestObjectPath(allocator, cache_root, entry.key_ptr.*);
        defer allocator.free(source_path);
        const bytes = try rootfs_cas.readVerifiedChunkPath(allocator, source_path, entry.key_ptr.*, @intCast(entry.value_ptr.*));
        defer allocator.free(bytes);
        const output_path = try std.fs.path.join(allocator, &.{ manifest_base, "objects", entry.key_ptr.* });
        defer allocator.free(output_path);
        try writeFixtureFile(init.io, allocator, output_path, bytes);
    }
    const source_key = try sourceKeyAlloc(allocator, options.source);
    defer allocator.free(source_key);
    const source_index_path = try fixturePathAlloc(allocator, options.output_dir, options.repository, &.{ "sources", source_key, "index" });
    defer allocator.free(source_index_path);
    try writeFixtureFile(init.io, allocator, source_index_path, encoded_platform.bytes);

    return .{
        .manifest_digest = try allocator.dupe(u8, encoded_manifest.transport_digest),
        .image_digest = image_digest,
        .object_count = objects.count(),
    };
}

pub fn deinitExportFixtureResult(allocator: std.mem.Allocator, result: ExportFixtureResult) void {
    allocator.free(result.manifest_digest);
    allocator.free(result.image_digest);
}

fn fixturePathAlloc(allocator: std.mem.Allocator, output_dir: []const u8, repository: []const u8, suffix: []const []const u8) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    try parts.appendSlice(allocator, &.{ output_dir, "v1", "repositories", repository });
    try parts.appendSlice(allocator, suffix);
    return std.fs.path.join(allocator, parts.items);
}

fn writeFixtureFile(io: Io, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.BadGatewayFixturePath;
    try Io.Dir.cwd().createDirPath(io, parent);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    _ = allocator;
}

fn verifyObjectBytes(expected_digest: []const u8, bytes: []const u8) !void {
    try gateway.validateDigest(expected_digest, "blake3:");
    const id = chunk.ChunkId.fromContents(bytes);
    const hex = id.toHex();
    if (!std.mem.eql(u8, expected_digest["blake3:".len..], hex[0..])) return error.BadGatewayObject;
}

fn chmodPath(allocator: std.mem.Allocator, path: []const u8, mode: std.c.mode_t) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (std.c.chmod(path_z.ptr, mode) != 0) return error.GatewayStagingUnavailable;
}

fn gatewayStorage(value: gateway_manifest.RootfsStorage) spore.RootfsStorage {
    return .{
        .kind = value.kind,
        .device = .{
            .kind = value.device.kind,
            .role = value.device.role,
            .virtio_device_id = value.device.virtio_device_id,
            .mmio_slot = value.device.mmio_slot,
        },
        .logical_size = value.logical_size,
        .chunk_size = value.chunk_size,
        .hash_algorithm = value.hash_algorithm,
        .index_digest = value.index_digest,
        .base_identity = value.base_identity,
        .object_namespace = value.object_namespace,
    };
}

fn sourceKeyAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(source, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

fn endpointAlloc(allocator: std.mem.Allocator, base: []const u8, repository: []const u8, suffix: []const []const u8) ![]u8 {
    var writer: Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll(std.mem.trimEnd(u8, base, "/"));
    try writer.writer.print("/v1/repositories/{s}", .{repository});
    for (suffix) |segment| try writer.writer.print("/{s}", .{segment});
    return writer.toOwnedSlice();
}

fn validateRepository(repository: []const u8) !void {
    if (repository.len == 0 or repository.len > 255) return error.InvalidGatewayRepository;
    var segment_len: usize = 0;
    for (repository) |byte| {
        if (byte == '/') {
            if (segment_len == 0) return error.InvalidGatewayRepository;
            segment_len = 0;
            continue;
        }
        if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '.' or byte == '_' or byte == '-')) return error.InvalidGatewayRepository;
        segment_len += 1;
    }
    if (segment_len == 0 or std.mem.indexOf(u8, repository, "..") != null) return error.InvalidGatewayRepository;
}

fn validateGatewayUrl(raw: []const u8, allow_insecure_http: bool) !void {
    const uri = try std.Uri.parse(raw);
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null or
        (!uri.path.isEmpty() and !std.mem.eql(u8, switch (uri.path) {
            .raw, .percent_encoded => |path| path,
        }, "/"))) return error.InvalidGatewayUrl;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_buffer) catch return error.InvalidGatewayUrl;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return;
    if (!allow_insecure_http or !std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.InsecureGatewayUrl;
    if (!std.mem.eql(u8, host.bytes, "127.0.0.1") and
        !std.mem.eql(u8, host.bytes, "::1") and
        !std.mem.eql(u8, host.bytes, "[::1]")) return error.InsecureGatewayUrl;
}

fn stageDirPath(allocator: std.mem.Allocator, io: Io, cache_root: []const u8) ![]u8 {
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    return std.fmt.allocPrint(allocator, "{s}/tmp/gateway-{d}-{x}", .{
        cache_root,
        Io.Clock.real.now(io).nanoseconds,
        std.mem.readInt(u64, &nonce, .little),
    });
}

fn httpGetAlloc(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, max_bytes: usize) ![]u8 {
    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{ .redirect_behavior = .unhandled });
    defer req.deinit();
    try req.sendBodiless();
    var header_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&header_buffer);
    if (response.head.status != .ok) return error.GatewayHTTPStatus;
    var body_buffer: [64 * 1024]u8 = undefined;
    var body = response.reader(&body_buffer);
    var writer: Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var scratch: [64 * 1024]u8 = undefined;
    while (true) {
        const n = body.readSliceShort(&scratch) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse err,
            else => |e| return e,
        };
        if (n == 0) break;
        if (writer.writer.end + n > max_bytes) return error.GatewayBodyTooLarge;
        try writer.writer.writeAll(scratch[0..n]);
    }
    return writer.toOwnedSlice();
}

const StaticGatewayServer = struct {
    allocator: std.mem.Allocator,
    io: Io,
    root: []const u8,
    server: Io.net.Server,
    thread: std.Thread,
    closed: std.atomic.Value(bool),

    fn init(self: *StaticGatewayServer, allocator: std.mem.Allocator, io: Io, root: []const u8) !void {
        var address = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .root = root,
            .server = try address.listen(io, .{ .kernel_backlog = 8, .reuse_address = true }),
            .thread = undefined,
            .closed = .init(false),
        };
        self.thread = try std.Thread.spawn(.{}, serveThread, .{self});
    }

    fn deinit(self: *StaticGatewayServer) void {
        const wake_address = self.server.socket.address;
        self.closed.store(true, .release);
        if (wake_address.connect(self.io, .{ .mode = .stream })) |stream| {
            stream.close(self.io);
        } else |_| {}
        self.server.deinit(self.io);
        self.thread.join();
    }

    fn url(self: *StaticGatewayServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{self.server.socket.address.getPort()});
    }

    fn serveThread(self: *StaticGatewayServer) void {
        while (!self.closed.load(.acquire)) {
            var stream = self.server.accept(self.io) catch {
                if (self.closed.load(.acquire)) return;
                continue;
            };
            self.handle(stream) catch {};
            stream.close(self.io);
        }
    }

    fn handle(self: *StaticGatewayServer, stream: Io.net.Stream) !void {
        var read_buffer: [8 * 1024]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        const request_line_raw = reader.interface.takeDelimiterExclusive('\n') catch return;
        const request_line = std.mem.trimEnd(u8, request_line_raw, "\r");
        while (true) {
            const header_raw = reader.interface.takeDelimiterExclusive('\n') catch return;
            if (std.mem.trimEnd(u8, header_raw, "\r").len == 0) break;
        }
        if (!std.mem.startsWith(u8, request_line, "GET ")) return self.writeStatus(stream, 405);
        const rest = request_line["GET ".len..];
        const path_end = std.mem.indexOfScalar(u8, rest, ' ') orelse return self.writeStatus(stream, 400);
        const path = rest[0..path_end];
        if (path.len < 2 or path[0] != '/' or std.mem.indexOfAny(u8, path, "?%") != null or
            std.mem.indexOf(u8, path, "..") != null) return self.writeStatus(stream, 404);
        const file_path = try std.fs.path.join(self.allocator, &.{ self.root, path[1..] });
        defer self.allocator.free(file_path);
        const data = Io.Dir.cwd().readFileAlloc(self.io, file_path, self.allocator, .limited(disk_index.max_index_bytes + 1)) catch
            return self.writeStatus(stream, 404);
        defer self.allocator.free(data);

        var write_buffer: [8 * 1024]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        try writer.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{data.len});
        try writer.interface.writeAll(data);
        try writer.interface.flush();
    }

    fn writeStatus(self: *StaticGatewayServer, stream: Io.net.Stream, status: u16) !void {
        var write_buffer: [256]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        try writer.interface.print("HTTP/1.1 {d} Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{status});
        try writer.interface.flush();
    }
};

test "gateway URL and repository validation fail closed" {
    try validateGatewayUrl("https://images.example.test", false);
    try validateGatewayUrl("http://127.0.0.1:8080", true);
    try validateGatewayUrl("http://[::1]:8080", true);
    try std.testing.expectError(error.InsecureGatewayUrl, validateGatewayUrl("http://127.0.0.1:8080", false));
    try std.testing.expectError(error.InsecureGatewayUrl, validateGatewayUrl("http://localhost:8080", true));
    try std.testing.expectError(error.InsecureGatewayUrl, validateGatewayUrl("http://10.0.0.1:8080", true));
    try validateRepository("team/base-images");
    try std.testing.expectError(error.InvalidGatewayRepository, validateRepository("team//base"));
    try std.testing.expectError(error.InvalidGatewayRepository, validateRepository("team/../base"));
}

test "source keys and endpoints are stable" {
    const allocator = std.testing.allocator;
    const key = try sourceKeyAlloc(allocator, "docker.io/library/alpine:3.20");
    defer allocator.free(key);
    try std.testing.expectEqualStrings("sha256:75be9c490b21b793193f47be0daf1e1ba283c3a002c8e84091e2c871cc49f219", key);
    const endpoint = try endpointAlloc(allocator, "https://images.example.test/", "team/base", &.{ "sources", key, "index" });
    defer allocator.free(endpoint);
    try std.testing.expectEqualStrings("https://images.example.test/v1/repositories/team/base/sources/sha256:75be9c490b21b793193f47be0daf1e1ba283c3a002c8e84091e2c871cc49f219/index", endpoint);
}

test "staged gateway objects are verified before cache installation" {
    const bytes = "gateway object";
    const id = chunk.ChunkId.fromContents(bytes);
    const hex = id.toHex();
    var digest_buffer: ["blake3:".len + chunk.ChunkId.hex_len]u8 = undefined;
    const digest = try std.fmt.bufPrint(&digest_buffer, "blake3:{s}", .{hex[0..]});
    try verifyObjectBytes(digest, bytes);
    try std.testing.expectError(error.BadGatewayObject, verifyObjectBytes(digest, "changed"));
}

test "static fixture export produces a verified repository-bound closure" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-image-gateway-export-fixture";
    Io.Dir.cwd().deleteTree(io, tmp) catch {};
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, tmp ++ "/cache");
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

    const object_bytes = "gateway fixture object";
    const object_id = chunk.ChunkId.fromContents(object_bytes);
    const object_hex = object_id.toHex();
    const object_digest = try std.fmt.allocPrint(allocator, "blake3:{s}", .{object_hex[0..]});
    defer allocator.free(object_digest);
    const entries = [_]disk_index.DiskIndexChunk{.{ .logical_chunk = 0, .digest = object_digest }};
    const encoded_index = try disk_index.encodeCanonicalAlloc(allocator, .{
        .kind = disk_index.disk_index_kind,
        .logical_size = object_bytes.len,
        .chunk_size = gateway_manifest.rootfs_chunk_size,
        .hash_algorithm = gateway_manifest.rootfs_hash_algorithm,
        .object_namespace = gateway_manifest.rootfs_object_namespace,
        .chunks = &entries,
    });
    defer encoded_index.deinit(allocator);
    const storage = spore.RootfsStorage{
        .kind = gateway_manifest.rootfs_storage_kind,
        .device = .{ .mmio_slot = gateway_manifest.rootfs_mmio_slot },
        .logical_size = object_bytes.len,
        .chunk_size = gateway_manifest.rootfs_chunk_size,
        .hash_algorithm = gateway_manifest.rootfs_hash_algorithm,
        .index_digest = encoded_index.digest,
        .base_identity = encoded_index.digest,
        .object_namespace = gateway_manifest.rootfs_object_namespace,
    };
    const cache_root = tmp ++ "/cache";
    const installed_index = try rootfs_cas.manifestIndexPath(allocator, cache_root, storage.index_digest);
    defer allocator.free(installed_index);
    _ = try rootfs_cas.installStorageIndexPath(allocator, io, installed_index, encoded_index.bytes, storage);
    const installed_object = try rootfs_cas.manifestObjectPath(allocator, cache_root, object_digest);
    defer allocator.free(installed_object);
    _ = try rootfs_cas.installChunkPath(allocator, io, installed_object, object_bytes, object_digest, object_bytes.len);
    try rootfs_cas.markStorageComplete(io, allocator, cache_root, storage.index_digest);

    const metadata_path = tmp ++ "/metadata.json";
    const metadata_bytes = try std.json.Stringify.valueAlloc(allocator, CachedMetadata{
        .platform = .{},
        .config = .{ .architecture = .arm64, .os = "linux" },
        .rootfs_storage = storage,
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(metadata_bytes);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = metadata_bytes });
    const result = try exportFixture(init, allocator, .{
        .source = "docker.io/library/alpine:3.20",
        .repository = "fixture",
        .metadata_path = metadata_path,
        .output_dir = tmp ++ "/gateway",
    });
    defer deinitExportFixtureResult(allocator, result);
    try std.testing.expectEqual(@as(usize, 1), result.object_count);

    const source_key = try sourceKeyAlloc(allocator, "docker.io/library/alpine:3.20");
    defer allocator.free(source_key);
    const exported_index_path = try fixturePathAlloc(allocator, tmp ++ "/gateway", "fixture", &.{ "sources", source_key, "index" });
    defer allocator.free(exported_index_path);
    const exported_index = try Io.Dir.cwd().readFileAlloc(io, exported_index_path, allocator, .limited(gateway.max_platform_index_bytes));
    defer allocator.free(exported_index);
    var parsed = try gateway.parsePlatformIndex(allocator, exported_index);
    defer parsed.deinit();
    const selected = try gateway.selectManifest(parsed.value, .{ .os = "linux", .arch = .arm64 });
    try std.testing.expectEqualStrings(result.manifest_digest, selected.manifest_digest);
    try std.testing.expectEqualStrings(result.image_digest, selected.image_digest);

    var server: StaticGatewayServer = undefined;
    try server.init(allocator, io, tmp ++ "/gateway");
    defer server.deinit();
    const gateway_url = try server.url(allocator);
    defer allocator.free(gateway_url);

    const pull_cache = tmp ++ "/pull-cache";
    try env.put(local_paths.rootfs_cache_env, pull_cache);
    const pulled = try pull(init, allocator, .{
        .source = "docker.io/library/alpine:3.20",
        .gateway_url = gateway_url,
        .repository = "fixture",
        .ref = "local/alpine:gateway",
        .allow_insecure_http = true,
    });
    defer deinitPullResult(allocator, pulled);
    try std.testing.expectEqualStrings(result.image_digest, pulled.image_digest);
    try std.testing.expectEqual(@as(usize, 1), pulled.objects_fetched);
    try std.testing.expect(try rootfs_cas.storageMarkedComplete(io, allocator, pull_cache, storage));
    try Io.Dir.cwd().access(io, pull_cache ++ "/refs", .{});
    try rootfs_cas.removeStorageCompleteStamp(io, allocator, pull_cache, storage.index_digest);
    var read_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer read_arena_state.deinit();
    const read_arena = read_arena_state.allocator();
    const cached = try rootfs.cachedImageIndexedRootfs(io, read_arena, pull_cache, .{
        .ref = pulled.resolved_image_ref,
        .manifest_digest = pulled.image_digest,
        .platform = .{},
    });
    try std.testing.expect(cached != null);
    try std.testing.expect(try rootfs_cas.storageMarkedComplete(io, allocator, pull_cache, storage));

    const failed_cache = tmp ++ "/failed-cache";
    try env.put(local_paths.rootfs_cache_env, failed_cache);
    try Io.Dir.cwd().createDirPath(io, failed_cache ++ "/cas/rootfs/blake3");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = failed_cache ++ "/cas/rootfs/blake3/objects", .data = "blocks object installation" });
    if (pull(init, allocator, .{
        .source = "docker.io/library/alpine:3.20",
        .gateway_url = gateway_url,
        .repository = "fixture",
        .ref = "local/alpine:gateway",
        .allow_insecure_http = true,
    })) |unexpected| {
        deinitPullResult(allocator, unexpected);
        return error.TestUnexpectedResult;
    } else |_| {}
    try std.testing.expect(!try rootfs_cas.storageMarkedComplete(io, allocator, failed_cache, storage));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, failed_cache ++ "/refs", .{}));
}
