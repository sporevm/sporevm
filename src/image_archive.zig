//! Immutable transport archives for final native Spore images.
//!
//! Archives carry one verified native image closure: canonical image manifest,
//! canonical config, canonical rootfs index, and every distinct rootfs object.
//! The gzip/USTAR bytes are transport metadata named by SHA-256; native image
//! identity remains the manifest-bound BLAKE3 identity installed into the
//! ordinary local image cache.

const std = @import("std");
const chunk = @import("chunk.zig");
const chunk_sealer = @import("chunk_sealer.zig");
const disk_index = @import("disk_index.zig");
const gateway = @import("image_gateway.zig");
const gateway_manifest = @import("image_gateway_manifest.zig");
const image = @import("image.zig");
const local_paths = @import("local_paths.zig");
const rootfs = @import("rootfs.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const spore = @import("spore.zig");

const Io = std.Io;
const Blake3 = std.crypto.hash.Blake3;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const media_type = "application/vnd.sporevm.image.archive.v1+tar+gzip";
pub const max_archive_bytes: u64 = 4 * 1024 * 1024 * 1024;

const manifest_entry = "spore-image-manifest.json";
const config_entry = "image-config.json";
const index_entry = "rootfs-index.json";
const object_prefix = "objects/";

pub const PackOptions = struct {
    source: []const u8,
    output_path: []const u8,
    platform: gateway.Platform,
};

pub const PackResult = struct {
    archive_digest: []const u8,
    manifest_digest: []const u8,
    image_digest: []const u8,
    object_count: usize,
    archive_bytes: u64,
};

pub const UnpackOptions = struct {
    archive_path: []const u8,
    archive_digest: []const u8,
    ref: []const u8,
    platform: gateway.Platform,
};

pub const UnpackResult = struct {
    resolved_image_ref: []const u8,
    manifest_digest: []const u8,
    image_digest: []const u8,
    object_count: usize,
};

const CachedMetadata = struct {
    image_manifest_digest: []const u8,
    platform: rootfs.Platform,
    config: image.Config,
    rootfs_storage: spore.RootfsStorage,
};

const ObjectDescriptor = struct {
    digest: []const u8,
    size: usize,
};

pub fn pack(init: std.process.Init, allocator: std.mem.Allocator, options: PackOptions) !PackResult {
    try validateOutputPath(init.io, options.output_path);
    try rootfs.validateLocalTagRef(options.source);

    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    defer allocator.free(cache_root);
    var cache_lock = try rootfs.lockRootfsCacheExclusive(init.io, allocator, cache_root);
    defer cache_lock.deinit();
    const resolved = try rootfs.resolveLocalCachedRef(
        init.io,
        allocator,
        cache_root,
        options.source,
        .{ .os = options.platform.os, .arch = options.platform.arch },
    );
    defer {
        allocator.free(resolved.ref);
        allocator.free(resolved.manifest_digest);
    }
    const cached = (try rootfs.cachedImageIndexedRootfs(init.io, allocator, cache_root, resolved)) orelse
        return error.LocalImageStorageUnavailable;
    defer rootfs.deinitCachedIndexedRootfs(allocator, cached);

    const metadata_bytes = try Io.Dir.cwd().readFileAlloc(
        init.io,
        cached.metadata_path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(metadata_bytes);
    var metadata = try std.json.parseFromSlice(CachedMetadata, allocator, metadata_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    });
    defer metadata.deinit();
    if (!std.mem.eql(u8, metadata.value.image_manifest_digest, resolved.manifest_digest) or
        !std.mem.eql(u8, metadata.value.platform.os, options.platform.os) or
        metadata.value.platform.arch != options.platform.arch or
        metadata.value.config.architecture == null or
        metadata.value.config.architecture.? != options.platform.arch or
        metadata.value.config.os == null or
        !std.mem.eql(u8, metadata.value.config.os.?, options.platform.os)) return error.ImageIdentityMismatch;

    const storage = metadata.value.rootfs_storage;
    try spore.validateRootfsStorageDescriptor(storage);
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

    const objects = try uniqueSortedObjects(allocator, storage, parsed_index.value.chunks);
    defer deinitObjects(allocator, objects);
    var object_bytes: u64 = 0;
    for (objects) |object| object_bytes = std.math.add(u64, object_bytes, object.size) catch return error.ImageArchiveTooLarge;
    try @import("image_gateway_pull.zig").validateEagerTransferBoundsForArchive(
        storage.logical_size,
        objects.len,
        object_bytes,
    );

    const config_bytes = try image.canonicalConfigJson(allocator, metadata.value.config);
    defer allocator.free(config_bytes);
    const config_transport = try gateway.transportDigestAlloc(allocator, config_bytes);
    defer allocator.free(config_transport);
    const config_digest = try image.configDigestAlloc(allocator, config_bytes);
    defer allocator.free(config_digest);
    const image_digest = try image.imageDigestAlloc(allocator, storage.index_digest, config_bytes);
    errdefer allocator.free(image_digest);
    if (!std.mem.eql(u8, image_digest, resolved.manifest_digest)) return error.ImageIdentityMismatch;

    const manifest_value = gateway_manifest.ImageManifest{
        .kind = gateway_manifest.image_manifest_kind,
        .image = .{
            .digest = image_digest,
            .platform = options.platform,
            .config_blob = .{
                .transport_digest = config_transport,
                .config_digest = config_digest,
                .bytes = config_bytes.len,
            },
            .rootfs_storage = gatewayStorage(storage),
        },
        .rootfs_index = .{
            .digest = storage.index_digest,
            .bytes = index_bytes.len,
            .object_count = objects.len,
            .object_bytes = object_bytes,
        },
    };
    const encoded_manifest = try gateway_manifest.encodeImageManifestAlloc(allocator, manifest_value);
    defer encoded_manifest.deinit(allocator);

    const temp_path = try temporarySiblingPath(allocator, init.io, options.output_path);
    defer allocator.free(temp_path);
    defer Io.Dir.cwd().deleteFile(init.io, temp_path) catch {};
    try writeArchive(init.io, allocator, temp_path, cache_root, encoded_manifest.bytes, config_bytes, index_bytes, objects);
    const archive_digest = try sha256FileDigestAlloc(allocator, init.io, temp_path);
    errdefer allocator.free(archive_digest);
    const archive_stat = try Io.Dir.cwd().statFile(init.io, temp_path, .{ .follow_symlinks = false });
    if (archive_stat.kind != .file or archive_stat.size > max_archive_bytes) return error.ImageArchiveTooLarge;
    Io.Dir.hardLink(Io.Dir.cwd(), temp_path, Io.Dir.cwd(), options.output_path, init.io, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => return error.ImageArchiveOutputExists,
        else => |e| return e,
    };
    errdefer Io.Dir.cwd().deleteFile(init.io, options.output_path) catch {};
    try chunk_sealer.fsyncParentDirPath(allocator, options.output_path);

    return .{
        .archive_digest = archive_digest,
        .manifest_digest = try allocator.dupe(u8, encoded_manifest.transport_digest),
        .image_digest = image_digest,
        .object_count = objects.len,
        .archive_bytes = archive_stat.size,
    };
}

pub fn unpack(init: std.process.Init, allocator: std.mem.Allocator, options: UnpackOptions) !UnpackResult {
    try rootfs.validateLocalTagRef(options.ref);
    try gateway.validateDigest(options.archive_digest, "sha256:");
    const stat = try Io.Dir.cwd().statFile(init.io, options.archive_path, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.size == 0 or stat.size > max_archive_bytes) return error.ImageArchiveTooLarge;
    const actual_archive_digest = try sha256FileDigestAlloc(allocator, init.io, options.archive_path);
    defer allocator.free(actual_archive_digest);
    if (!std.mem.eql(u8, actual_archive_digest, options.archive_digest)) return error.ImageArchiveDigestMismatch;

    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    defer allocator.free(cache_root);
    try Io.Dir.cwd().createDirPath(init.io, cache_root);
    const stage_dir = try stageDirPath(allocator, init.io, cache_root);
    defer allocator.free(stage_dir);
    defer Io.Dir.cwd().deleteTree(init.io, stage_dir) catch {};
    try Io.Dir.cwd().createDirPath(init.io, stage_dir);
    try chmodPath(allocator, stage_dir, 0o700);

    var extracted = try extractArchive(init.io, allocator, options.archive_path, stage_dir, options.platform);
    defer extracted.deinit(allocator);
    const storage = gatewayStorageToSpore(extracted.verified.value.image.rootfs_storage);

    var cache_lock = try rootfs.lockRootfsCacheExclusive(init.io, allocator, cache_root);
    defer cache_lock.deinit();
    try rootfs_cas.removeStorageCompleteStamp(init.io, allocator, cache_root, storage.index_digest);
    for (extracted.objects) |object| {
        const staged_path = try std.fs.path.join(allocator, &.{ stage_dir, object.digest["blake3:".len..] });
        defer allocator.free(staged_path);
        const bytes = try rootfs_cas.readVerifiedChunkPath(allocator, staged_path, object.digest, object.size);
        defer allocator.free(bytes);
        const installed_path = try rootfs_cas.manifestObjectPath(allocator, cache_root, object.digest);
        defer allocator.free(installed_path);
        _ = try rootfs_cas.installChunkPathRepairingInvalid(allocator, init.io, installed_path, bytes, object.digest, object.size);
    }
    const index_path = try rootfs_cas.manifestIndexPath(allocator, cache_root, storage.index_digest);
    defer allocator.free(index_path);
    _ = try rootfs_cas.installStorageIndexPathRepairingInvalid(allocator, init.io, index_path, extracted.index_bytes, storage);
    if (!try rootfs_cas.storageContentComplete(init.io, allocator, cache_root, storage)) return error.IncompleteImageArchive;
    try rootfs_cas.markStorageComplete(init.io, allocator, cache_root, storage.index_digest);
    const published = try rootfs.publishIndexedImageWithCacheLockHeld(init.io, allocator, cache_root, .{
        .ref = options.ref,
        .platform = .{ .os = options.platform.os, .arch = options.platform.arch },
        .config = extracted.config.value,
        .rootfs_storage = storage,
        .expected_image_digest = extracted.verified.value.image.digest,
    });
    defer rootfs.deinitPublishIndexedImageResult(allocator, published);

    return .{
        .resolved_image_ref = try allocator.dupe(u8, published.resolved_image_ref),
        .manifest_digest = try allocator.dupe(u8, extracted.manifest_digest),
        .image_digest = try allocator.dupe(u8, published.image_manifest_digest),
        .object_count = extracted.objects.len,
    };
}

pub fn deinitPackResult(allocator: std.mem.Allocator, result: PackResult) void {
    allocator.free(result.archive_digest);
    allocator.free(result.manifest_digest);
    allocator.free(result.image_digest);
}

pub fn deinitUnpackResult(allocator: std.mem.Allocator, result: UnpackResult) void {
    allocator.free(result.resolved_image_ref);
    allocator.free(result.manifest_digest);
    allocator.free(result.image_digest);
}

const Extracted = struct {
    manifest_digest: []const u8,
    index_bytes: []const u8,
    config: std.json.Parsed(image.Config),
    verified: std.json.Parsed(gateway_manifest.ImageManifest),
    objects: []ObjectDescriptor,

    fn deinit(self: *Extracted, allocator: std.mem.Allocator) void {
        allocator.free(self.manifest_digest);
        allocator.free(self.index_bytes);
        self.config.deinit();
        self.verified.deinit();
        deinitObjects(allocator, self.objects);
    }
};

fn extractArchive(io: Io, allocator: std.mem.Allocator, archive_path: []const u8, stage_dir: []const u8, platform: gateway.Platform) !Extracted {
    var file = try Io.Dir.cwd().openFile(io, archive_path, .{});
    defer file.close(io);
    var file_buf: [64 * 1024]u8 = undefined;
    var file_reader: Io.File.Reader = .initStreaming(file, io, &file_buf);
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, &decompress_buf);

    const manifest_bytes = try readNamedEntryAlloc(allocator, &decompress.reader, manifest_entry, gateway_manifest.max_image_manifest_bytes);
    defer allocator.free(manifest_bytes);
    const config_bytes = try readNamedEntryAlloc(allocator, &decompress.reader, config_entry, gateway_manifest.max_config_blob_bytes);
    defer allocator.free(config_bytes);
    const index_bytes = try readNamedEntryAlloc(allocator, &decompress.reader, index_entry, disk_index.max_index_bytes);
    errdefer allocator.free(index_bytes);

    const manifest_digest = try gateway.transportDigestAlloc(allocator, manifest_bytes);
    errdefer allocator.free(manifest_digest);
    var parsed_manifest = try gateway_manifest.parseImageManifest(allocator, manifest_bytes);
    defer parsed_manifest.deinit();
    const descriptor = gateway.ManifestDescriptor{
        .platform = platform,
        .manifest_digest = manifest_digest,
        .image_digest = parsed_manifest.value.image.digest,
    };
    var verified = try gateway_manifest.verifySelectedImageManifest(
        allocator,
        descriptor,
        null,
        manifest_bytes,
        config_bytes,
        index_bytes,
    );
    errdefer verified.deinit();
    var parsed_config = try gateway_manifest.parseCanonicalConfig(allocator, config_bytes);
    errdefer parsed_config.deinit();
    const storage = gatewayStorageToSpore(verified.value.image.rootfs_storage);
    var parsed_index = try disk_index.parseDiskIndex(allocator, index_bytes, .{
        .logical_size = storage.logical_size,
        .chunk_size = storage.chunk_size,
        .hash_algorithm = storage.hash_algorithm,
        .object_namespace = storage.object_namespace,
        .index_digest = storage.index_digest,
    });
    defer parsed_index.deinit();
    const objects = try uniqueSortedObjects(allocator, storage, parsed_index.value.chunks);
    errdefer deinitObjects(allocator, objects);

    for (objects) |object| {
        const expected_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ object_prefix, object.digest["blake3:".len..] });
        defer allocator.free(expected_name);
        const staged_path = try std.fs.path.join(allocator, &.{ stage_dir, object.digest["blake3:".len..] });
        defer allocator.free(staged_path);
        try readObjectEntry(io, allocator, &decompress.reader, expected_name, object, staged_path);
    }
    try readArchiveEnd(&decompress.reader);

    return .{
        .manifest_digest = manifest_digest,
        .index_bytes = index_bytes,
        .config = parsed_config,
        .verified = verified,
        .objects = objects,
    };
}

fn writeArchive(io: Io, allocator: std.mem.Allocator, path: []const u8, cache_root: []const u8, manifest_bytes: []const u8, config_bytes: []const u8, index_bytes: []const u8, objects: []const ObjectDescriptor) !void {
    var file = try Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    var file_buf: [64 * 1024]u8 = undefined;
    var file_writer: Io.File.Writer = .initStreaming(file, io, &file_buf);
    const compress_buf = try allocator.alloc(u8, std.compress.flate.max_window_len * 2);
    defer allocator.free(compress_buf);
    var compressor = try std.compress.flate.Compress.init(&file_writer.interface, compress_buf, .gzip, .fastest);
    var tar_writer = std.tar.Writer{ .underlying_writer = &compressor.writer };
    const tar_options = std.tar.Writer.Options{ .mode = 0o444, .mtime = 0 };
    try tar_writer.writeFileBytes(manifest_entry, manifest_bytes, tar_options);
    try tar_writer.writeFileBytes(config_entry, config_bytes, tar_options);
    try tar_writer.writeFileBytes(index_entry, index_bytes, tar_options);
    for (objects) |object| {
        const object_bytes = try rootfs_cas.readVerifiedManifestObject(allocator, cache_root, object.digest, object.size);
        defer allocator.free(object_bytes);
        const name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ object_prefix, object.digest["blake3:".len..] });
        defer allocator.free(name);
        try tar_writer.writeFileBytes(name, object_bytes, tar_options);
    }
    try tar_writer.finishPedantically();
    try compressor.finish();
    try file_writer.interface.flush();
    try file.sync(io);
}

fn uniqueSortedObjects(allocator: std.mem.Allocator, storage: spore.RootfsStorage, chunks: []const disk_index.DiskIndexChunk) ![]ObjectDescriptor {
    var map = std.StringHashMap(usize).init(allocator);
    defer map.deinit();
    for (chunks) |entry| {
        const size = try rootfs_cas.storageChunkLen(storage, entry.logical_chunk);
        const gop = try map.getOrPut(entry.digest);
        if (gop.found_existing) {
            if (gop.value_ptr.* != size) return error.BadManifest;
        } else gop.value_ptr.* = size;
    }
    const objects = try allocator.alloc(ObjectDescriptor, map.count());
    errdefer allocator.free(objects);
    var it = map.iterator();
    var index: usize = 0;
    while (it.next()) |entry| : (index += 1) {
        objects[index] = .{ .digest = try allocator.dupe(u8, entry.key_ptr.*), .size = entry.value_ptr.* };
    }
    std.mem.sort(ObjectDescriptor, objects, {}, struct {
        fn lessThan(_: void, a: ObjectDescriptor, b: ObjectDescriptor) bool {
            return std.mem.lessThan(u8, a.digest, b.digest);
        }
    }.lessThan);
    return objects;
}

fn deinitObjects(allocator: std.mem.Allocator, objects: []ObjectDescriptor) void {
    for (objects) |object| allocator.free(object.digest);
    allocator.free(objects);
}

fn readNamedEntryAlloc(allocator: std.mem.Allocator, reader: *Io.Reader, expected_name: []const u8, max_bytes: usize) ![]u8 {
    var header: [512]u8 = undefined;
    if (!try readTarHeader(reader, &header) or isZeroBlock(&header)) return error.BadImageArchive;
    const size = try tarSize(&header);
    if (size == 0 or size > max_bytes) return error.BadImageArchive;
    try verifyTarHeader(&header, expected_name, size);
    const bytes = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(bytes);
    try reader.readSliceAll(bytes);
    try discardTarPadding(reader, size);
    return bytes;
}

fn readObjectEntry(io: Io, allocator: std.mem.Allocator, reader: *Io.Reader, expected_name: []const u8, object: ObjectDescriptor, path: []const u8) !void {
    var header: [512]u8 = undefined;
    if (!try readTarHeader(reader, &header) or isZeroBlock(&header)) return error.BadImageArchive;
    try verifyTarHeader(&header, expected_name, object.size);
    var file = try Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    var file_buf: [64 * 1024]u8 = undefined;
    var writer: Io.File.Writer = .initStreaming(file, io, &file_buf);
    var hasher = Blake3.init(.{});
    var remaining: usize = object.size;
    var buffer: [64 * 1024]u8 = undefined;
    while (remaining > 0) {
        const want = @min(remaining, buffer.len);
        const n = try reader.readSliceShort(buffer[0..want]);
        if (n == 0) return error.BadImageArchive;
        hasher.update(buffer[0..n]);
        try writer.interface.writeAll(buffer[0..n]);
        remaining -= n;
    }
    try writer.interface.flush();
    var digest: [Blake3.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, object.digest["blake3:".len..], &hex)) return error.BadImageArchiveObject;
    try discardTarPadding(reader, object.size);
    _ = allocator;
}

fn readArchiveEnd(reader: *Io.Reader) !void {
    var first: [512]u8 = undefined;
    var second: [512]u8 = undefined;
    if (!try readTarHeader(reader, &first) or !isZeroBlock(&first) or
        !try readTarHeader(reader, &second) or !isZeroBlock(&second)) return error.BadImageArchive;
    var trailing: [1]u8 = undefined;
    if (try reader.readSliceShort(&trailing) != 0) return error.BadImageArchive;
}

fn readTarHeader(reader: *Io.Reader, header: *[512]u8) !bool {
    var filled: usize = 0;
    while (filled < header.len) {
        const n = try reader.readSliceShort(header[filled..]);
        if (n == 0) {
            if (filled == 0) return false;
            return error.BadImageArchive;
        }
        filled += n;
    }
    return true;
}

fn verifyTarHeader(header: *const [512]u8, expected_name: []const u8, expected_size: u64) !void {
    if (!std.mem.eql(u8, header[257..263], "ustar\x00") or !std.mem.eql(u8, header[263..265], "00")) return error.BadImageArchive;
    if (header[156] != '0' or expected_name.len > 100 or
        !std.mem.eql(u8, header[0..expected_name.len], expected_name) or
        !allZero(header[expected_name.len..100])) return error.BadImageArchive;
    if (!std.mem.eql(u8, header[100..108], "0000444\x00") or
        !allZero(header[108..124]) or
        !std.mem.eql(u8, header[136..148], "00000000000\x00") or
        !allZero(header[157..257]) or
        !allZero(header[265..512])) return error.BadImageArchive;
    var canonical_size = [_]u8{'0'} ** 12;
    canonical_size[11] = 0;
    var value = expected_size;
    var position: usize = 11;
    while (value > 0) {
        if (position == 0) return error.BadImageArchive;
        position -= 1;
        canonical_size[position] = @intCast('0' + value % 8);
        value /= 8;
    }
    if (!std.mem.eql(u8, header[124..136], &canonical_size)) return error.BadImageArchive;
    const stored = try parseTarNumber(header[148..156]);
    var sum: u64 = 0;
    for (header, 0..) |byte, index| sum += if (index >= 148 and index < 156) ' ' else byte;
    if (stored != sum) return error.BadImageArchive;
    var canonical_checksum = [_]u8{' '} ** 8;
    canonical_checksum[7] = 0;
    value = sum;
    position = 7;
    while (value > 0) {
        if (position == 0) return error.BadImageArchive;
        position -= 1;
        canonical_checksum[position] = @intCast('0' + value % 8);
        value /= 8;
    }
    if (!std.mem.eql(u8, header[148..156], &canonical_checksum)) return error.BadImageArchive;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn tarSize(header: *const [512]u8) !u64 {
    return parseTarNumber(header[124..136]);
}

fn parseTarNumber(raw: []const u8) !u64 {
    const trimmed = std.mem.trim(u8, raw, " \x00");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(u64, trimmed, 8) catch return error.BadImageArchive;
}

fn isZeroBlock(block: *const [512]u8) bool {
    for (block) |byte| if (byte != 0) return false;
    return true;
}

fn discardTarPadding(reader: *Io.Reader, size: u64) !void {
    const padding = (512 - (size % 512)) % 512;
    if (padding != 0) try reader.discardAll(@intCast(padding));
}

fn gatewayStorage(storage: spore.RootfsStorage) gateway_manifest.RootfsStorage {
    return .{
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
    };
}

fn gatewayStorageToSpore(storage: gateway_manifest.RootfsStorage) spore.RootfsStorage {
    return .{
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
    };
}

fn validateOutputPath(io: Io, path: []const u8) !void {
    if (path.len == 0) return error.MissingImageArchiveOutput;
    Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    return error.ImageArchiveOutputExists;
}

fn temporarySiblingPath(allocator: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    return std.fmt.allocPrint(allocator, "{s}.{x}.tmp", .{ path, std.mem.readInt(u64, &nonce, .little) });
}

fn stageDirPath(allocator: std.mem.Allocator, io: Io, cache_root: []const u8) ![]u8 {
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    return std.fmt.allocPrint(allocator, "{s}/tmp/image-archive-{d}-{x}", .{
        cache_root,
        Io.Clock.real.now(io).nanoseconds,
        std.mem.readInt(u64, &nonce, .little),
    });
}

fn sha256FileDigestAlloc(allocator: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var file_buf: [64 * 1024]u8 = undefined;
    var reader: Io.File.Reader = .initStreaming(file, io, &file_buf);
    var hasher = Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try reader.interface.readSliceShort(&buffer);
        if (n == 0) break;
        hasher.update(buffer[0..n]);
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

fn chmodPath(allocator: std.mem.Allocator, path: []const u8, mode: std.c.mode_t) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (std.c.chmod(path_z.ptr, mode) != 0) return error.ImageArchiveStagingUnavailable;
}

fn fuzzTarHeader(_: void, smith: *std.testing.Smith) !void {
    var header: [512]u8 = undefined;
    _ = smith.slice(&header);
    verifyTarHeader(&header, manifest_entry, 1) catch {};
    _ = tarSize(&header) catch {};
}

test "image archive tar header parser is fuzzed" {
    try std.testing.fuzz({}, fuzzTarHeader, .{});
}

test "native image archive round-trips into a clean cache and rejects substitution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tmp = "zig-cache/test-native-image-archive";
    Io.Dir.cwd().deleteTree(io, tmp) catch {};
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, tmp ++ "/producer-cache");
    const init = std.process.Init{
        .minimal = undefined,
        .arena = &arena,
        .gpa = allocator,
        .io = io,
        .environ_map = &env,
        .preopens = .empty,
    };

    const object_bytes = "native image archive object";
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
    const producer_cache = tmp ++ "/producer-cache";
    const installed_index = try rootfs_cas.manifestIndexPath(allocator, producer_cache, storage.index_digest);
    defer allocator.free(installed_index);
    _ = try rootfs_cas.installStorageIndexPath(allocator, io, installed_index, encoded_index.bytes, storage);
    const installed_object = try rootfs_cas.manifestObjectPath(allocator, producer_cache, object_digest);
    defer allocator.free(installed_object);
    _ = try rootfs_cas.installChunkPath(allocator, io, installed_object, object_bytes, object_digest, object_bytes.len);
    try rootfs_cas.markStorageComplete(io, allocator, producer_cache, storage.index_digest);
    const published = try rootfs.publishIndexedImage(init, allocator, .{
        .ref = "local/archive:producer",
        .platform = .{},
        .config = .{ .architecture = .arm64, .os = "linux" },
        .rootfs_storage = storage,
    });
    defer rootfs.deinitPublishIndexedImageResult(allocator, published);

    const archive_path = tmp ++ "/image.tar.gz";
    const pack_result = try pack(init, allocator, .{
        .source = "local/archive:producer",
        .output_path = archive_path,
        .platform = .{ .os = "linux", .arch = .arm64 },
    });
    defer deinitPackResult(allocator, pack_result);
    try std.testing.expectEqualStrings(published.image_manifest_digest, pack_result.image_digest);
    try std.testing.expectEqual(@as(usize, 1), pack_result.object_count);
    try std.testing.expectError(error.ImageArchiveOutputExists, pack(init, allocator, .{
        .source = "local/archive:producer",
        .output_path = archive_path,
        .platform = .{ .os = "linux", .arch = .arm64 },
    }));

    const duplicate_archive_path = tmp ++ "/image-duplicate.tar.gz";
    const duplicate = try pack(init, allocator, .{
        .source = "local/archive:producer",
        .output_path = duplicate_archive_path,
        .platform = .{ .os = "linux", .arch = .arm64 },
    });
    defer deinitPackResult(allocator, duplicate);
    try std.testing.expectEqualStrings(pack_result.archive_digest, duplicate.archive_digest);

    var corrupted: [object_bytes.len]u8 = undefined;
    @memcpy(&corrupted, object_bytes);
    corrupted[0] ^= 0xff;
    try chunk_sealer.replaceFileAtomicDurable(allocator, installed_object, &corrupted, 0o444);
    try std.testing.expectError(error.BadChunk, pack(init, allocator, .{
        .source = "local/archive:producer",
        .output_path = tmp ++ "/corrupt.tar.gz",
        .platform = .{ .os = "linux", .arch = .arm64 },
    }));

    const consumer_cache = tmp ++ "/consumer-cache";
    try env.put(local_paths.rootfs_cache_env, consumer_cache);
    const unpacked = try unpack(init, allocator, .{
        .archive_path = archive_path,
        .archive_digest = pack_result.archive_digest,
        .ref = "local/archive:consumer",
        .platform = .{ .os = "linux", .arch = .arm64 },
    });
    defer deinitUnpackResult(allocator, unpacked);
    try std.testing.expectEqualStrings(pack_result.image_digest, unpacked.image_digest);
    try std.testing.expect(try rootfs_cas.storageMarkedComplete(io, allocator, consumer_cache, storage));
    try Io.Dir.cwd().access(io, consumer_cache ++ "/refs", .{});

    const rejected_cache = tmp ++ "/rejected-cache";
    try env.put(local_paths.rootfs_cache_env, rejected_cache);
    try std.testing.expectError(error.ImageArchiveDigestMismatch, unpack(init, allocator, .{
        .archive_path = archive_path,
        .archive_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .ref = "local/archive:rejected",
        .platform = .{ .os = "linux", .arch = .arm64 },
    }));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, rejected_cache ++ "/refs", .{}));
    try std.testing.expectError(error.BadProtocol, unpack(init, allocator, .{
        .archive_path = archive_path,
        .archive_digest = pack_result.archive_digest,
        .ref = "local/archive:wrong-arch",
        .platform = .{ .os = "linux", .arch = .amd64 },
    }));
}
