//! Immutable transport archives for final native Spore images.
//!
//! Archives carry one verified native image closure: canonical image manifest,
//! canonical config, canonical rootfs index, and every distinct rootfs object.
//! The gzip/USTAR bytes are transport metadata named by SHA-256; native image
//! identity remains the manifest-bound BLAKE3 identity installed into the
//! ordinary local image cache.

const std = @import("std");
const TestDir = @import("test_dir.zig").TestDir;
const chunk = @import("chunk.zig");
const chunk_sealer = @import("chunk_sealer.zig");
const disk_index = @import("disk_index.zig");
const fuzz_support = @import("fuzz_support.zig");
const image = @import("image.zig");
const image_manifest = @import("image_manifest.zig");
const local_image = @import("local_image.zig");
const local_paths = @import("local_paths.zig");
const resource = @import("resource.zig");
const rootfs = @import("rootfs.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const spore = @import("spore.zig");
const tar = @import("rootfs/tar.zig");

const Io = std.Io;
const Blake3 = std.crypto.hash.Blake3;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const media_type = "application/vnd.sporevm.image.archive.v1+tar+gzip";
pub const max_archive_bytes: u64 = 4 * 1024 * 1024 * 1024;
const max_rootfs_logical_bytes: u64 = 16 * 1024 * 1024 * 1024;
const max_object_count: u64 = 65_536;
const max_object_bytes: u64 = 4 * 1024 * 1024 * 1024;

const manifest_entry = "spore-image-manifest.json";
const config_entry = "image-config.json";
const index_entry = "rootfs-index.json";
const object_prefix = "objects/";

pub const PackOptions = struct {
    source: []const u8,
    output_path: []const u8,
    platform: rootfs.Platform,
};

pub const PackResult = struct {
    schema: []const u8 = "spore.image.archive.pack.result.v1",
    schema_version: u32 = 1,
    resource_type: resource.Type = .image,
    archive_digest: []const u8,
    manifest_digest: []const u8,
    image_digest: []const u8,
    object_count: usize,
    archive_bytes: u64,
};

pub const UnpackOptions = struct {
    archive_path: []const u8,
    archive_digest: []const u8,
    expected_image_digest: []const u8,
    ref: []const u8,
    platform: rootfs.Platform,
};

pub const UnpackResult = struct {
    schema: []const u8 = "spore.image.archive.unpack.result.v1",
    schema_version: u32 = 1,
    resource_type: resource.Type = .image,
    resolved_image_ref: []const u8,
    manifest_digest: []const u8,
    image_digest: []const u8,
    object_count: usize,
};

pub const ObjectDescriptor = struct {
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
    var closure = try loadLocalClosure(init.io, allocator, cache_root, options.source, options.platform);
    defer closure.deinit(allocator);
    _ = try validateArchiveBounds(closure.storage.logical_size, closure.objects);

    const temp_path = try temporarySiblingPath(allocator, init.io, options.output_path);
    defer allocator.free(temp_path);
    defer Io.Dir.cwd().deleteFile(init.io, temp_path) catch {};
    try writeArchive(init.io, allocator, temp_path, cache_root, closure.manifest.bytes, closure.config_bytes, closure.index_bytes, closure.objects);
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

    const manifest_digest = try allocator.dupe(u8, closure.manifest.transport_digest);
    errdefer allocator.free(manifest_digest);
    return .{
        .archive_digest = archive_digest,
        .manifest_digest = manifest_digest,
        .image_digest = try allocator.dupe(u8, closure.image_digest),
        .object_count = closure.objects.len,
        .archive_bytes = archive_stat.size,
    };
}

/// One complete local image as `pack` and `image push` publish it: canonical
/// manifest, config and rootfs index, and its distinct objects sorted by
/// digest. Objects stay in the local CAS; read them with
/// `rootfs_cas.readVerifiedManifestObject`.
pub const LocalClosure = struct {
    image_digest: []const u8,
    storage: spore.RootfsStorage,
    manifest: image_manifest.EncodedImageManifest,
    config_bytes: []const u8,
    index_bytes: []const u8,
    objects: []ObjectDescriptor,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *LocalClosure, allocator: std.mem.Allocator) void {
        self.manifest.deinit(allocator);
        allocator.free(self.config_bytes);
        allocator.free(self.index_bytes);
        deinitObjects(allocator, self.objects);
        self.arena.deinit();
    }
};

/// Load the local image `source` names on `platform` with complete local
/// storage. The caller holds the rootfs cache lock while it reads objects.
pub fn loadLocalClosure(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    source: []const u8,
    platform: rootfs.Platform,
) !LocalClosure {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const catalog_allocator = arena.allocator();
    const identity = (try local_image.lookup(io, catalog_allocator, cache_root, source, platform)) orelse
        return error.FileNotFound;
    const local = (try local_image.readRecord(io, catalog_allocator, cache_root, identity)) orelse return error.FileNotFound;
    if (!try rootfs_cas.storageCompleteWithStampRepair(io, catalog_allocator, cache_root, local.storage))
        return error.LocalImageStorageUnavailable;

    const storage = local.storage;
    const index_path = try rootfs_cas.manifestIndexPath(allocator, cache_root, storage.index_digest);
    defer allocator.free(index_path);
    const index = try rootfs_cas.readStorageIndexPath(allocator, index_path, storage);
    const index_bytes = index.bytes;
    errdefer allocator.free(index_bytes);
    const parsed_index = index.parsed;
    defer parsed_index.deinit();

    const objects = try uniqueSortedObjects(allocator, storage, parsed_index.value.chunks);
    errdefer deinitObjects(allocator, objects);
    var object_bytes: u64 = 0;
    for (objects) |object| object_bytes = std.math.add(u64, object_bytes, object.size) catch return error.BadManifest;

    const config_bytes = try image.canonicalConfigJson(allocator, local.config);
    errdefer allocator.free(config_bytes);
    const config_transport = try image_manifest.transportDigestAlloc(catalog_allocator, config_bytes);
    const config_digest = try image.configDigestAlloc(catalog_allocator, config_bytes);

    const manifest = try image_manifest.encodeImageManifestAlloc(allocator, .{
        .kind = image_manifest.image_manifest_kind,
        .image = .{
            .digest = local.identity,
            .platform = platform,
            .config_blob = .{
                .transport_digest = config_transport,
                .config_digest = config_digest,
                .bytes = config_bytes.len,
            },
            .rootfs_storage = storage,
        },
        .rootfs_index = .{
            .digest = storage.index_digest,
            .bytes = index_bytes.len,
            .object_count = objects.len,
            .object_bytes = object_bytes,
        },
    });
    return .{
        .image_digest = local.identity,
        .storage = storage,
        .manifest = manifest,
        .config_bytes = config_bytes,
        .index_bytes = index_bytes,
        .objects = objects,
        .arena = arena,
    };
}

pub fn unpack(init: std.process.Init, allocator: std.mem.Allocator, options: UnpackOptions) !UnpackResult {
    try rootfs.validateLocalTagRef(options.ref);
    try image_manifest.validateDigest(options.archive_digest, "sha256:");
    try image_manifest.validateDigest(options.expected_image_digest, "blake3:");
    const stat = try Io.Dir.cwd().statFile(init.io, options.archive_path, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.size == 0 or stat.size > max_archive_bytes) return error.ImageArchiveTooLarge;

    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    defer allocator.free(cache_root);
    try Io.Dir.cwd().createDirPath(init.io, cache_root);
    const stage_dir = try stageDirPath(allocator, init.io, cache_root);
    defer allocator.free(stage_dir);
    defer Io.Dir.cwd().deleteTree(init.io, stage_dir) catch {};
    try Io.Dir.cwd().createDirPath(init.io, stage_dir);
    try chmodPath(allocator, stage_dir, 0o700);

    var extracted = try extractArchive(
        init.io,
        allocator,
        options.archive_path,
        options.archive_digest,
        stage_dir,
        options.platform,
    );
    defer extracted.deinit(allocator);
    if (!std.mem.eql(u8, extracted.verified.value.image.digest, options.expected_image_digest))
        return error.ImageIdentityMismatch;
    const storage = extracted.verified.value.image.rootfs_storage;

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
    const published = try local_image.publish(init.io, allocator, cache_root, &cache_lock, .{
        .platform = options.platform,
        .config = extracted.config.value,
        .storage = storage,
        .name = options.ref,
        .expected_identity = options.expected_image_digest,
    });
    defer published.deinit(allocator);

    return .{
        .resolved_image_ref = try allocator.dupe(u8, published.resolved_ref),
        .manifest_digest = try allocator.dupe(u8, extracted.manifest_digest),
        .image_digest = try allocator.dupe(u8, published.identity),
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
    verified: std.json.Parsed(image_manifest.ImageManifest),
    objects: []ObjectDescriptor,

    fn deinit(self: *Extracted, allocator: std.mem.Allocator) void {
        allocator.free(self.manifest_digest);
        allocator.free(self.index_bytes);
        self.config.deinit();
        self.verified.deinit();
        deinitObjects(allocator, self.objects);
    }
};

fn extractArchive(
    io: Io,
    allocator: std.mem.Allocator,
    archive_path: []const u8,
    expected_archive_digest: []const u8,
    stage_dir: []const u8,
    platform: rootfs.Platform,
) !Extracted {
    var file = try Io.Dir.cwd().openFile(io, archive_path, .{});
    defer file.close(io);
    var file_buf: [64 * 1024]u8 = undefined;
    var file_reader: Io.File.Reader = .initStreaming(file, io, &file_buf);
    var hash_buf: [64 * 1024]u8 = undefined;
    var hashed = file_reader.interface.hashed(Sha256.init(.{}), &hash_buf);
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&hashed.reader, .gzip, &decompress_buf);
    var records: tar.RecordIterator = .{ .reader = &decompress.reader };

    const manifest_bytes = try readNamedEntryAlloc(allocator, &records, manifest_entry, image_manifest.max_image_manifest_bytes);
    defer allocator.free(manifest_bytes);
    const config_bytes = try readNamedEntryAlloc(allocator, &records, config_entry, image_manifest.max_config_blob_bytes);
    defer allocator.free(config_bytes);
    const index_bytes = try readNamedEntryAlloc(allocator, &records, index_entry, disk_index.max_index_bytes);
    errdefer allocator.free(index_bytes);

    const manifest_digest = try image_manifest.transportDigestAlloc(allocator, manifest_bytes);
    errdefer allocator.free(manifest_digest);
    var verified = try image_manifest.verifyImageManifest(
        allocator,
        manifest_digest,
        platform,
        manifest_bytes,
        config_bytes,
        index_bytes,
    );
    errdefer verified.deinit();
    var parsed_config = try image_manifest.parseCanonicalConfig(allocator, config_bytes);
    errdefer parsed_config.deinit();
    const storage = verified.value.image.rootfs_storage;
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
    _ = try validateArchiveBounds(storage.logical_size, objects);

    for (objects) |object| {
        const expected_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ object_prefix, object.digest["blake3:".len..] });
        defer allocator.free(expected_name);
        const staged_path = try std.fs.path.join(allocator, &.{ stage_dir, object.digest["blake3:".len..] });
        defer allocator.free(staged_path);
        try readObjectEntry(io, &records, expected_name, object, staged_path);
    }
    try readArchiveEnd(&records);
    _ = try hashed.reader.discardRemaining();
    var archive_digest: [Sha256.digest_length]u8 = undefined;
    hashed.hasher.final(&archive_digest);
    const archive_hex = std.fmt.bytesToHex(archive_digest, .lower);
    if (!std.mem.eql(u8, expected_archive_digest["sha256:".len..], &archive_hex))
        return error.ImageArchiveDigestMismatch;

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
    var map = std.AutoHashMap(chunk.ChunkId, usize).init(allocator);
    defer map.deinit();
    for (chunks) |entry| {
        const size = try rootfs_cas.storageChunkLen(storage, entry.logical_chunk);
        const gop = try map.getOrPut(entry.id);
        if (gop.found_existing) {
            if (gop.value_ptr.* != size) return error.BadManifest;
        } else gop.value_ptr.* = size;
    }
    const objects = try allocator.alloc(ObjectDescriptor, map.count());
    errdefer allocator.free(objects);
    var it = map.iterator();
    var index: usize = 0;
    while (it.next()) |entry| : (index += 1) {
        objects[index] = .{ .digest = try allocator.dupe(u8, &entry.key_ptr.toDigest()), .size = entry.value_ptr.* };
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

fn validateArchiveBounds(logical_bytes: u64, objects: []const ObjectDescriptor) !u64 {
    var object_bytes: u64 = 0;
    for (objects) |object|
        object_bytes = std.math.add(u64, object_bytes, object.size) catch return error.ImageArchiveTooLarge;
    if (logical_bytes > max_rootfs_logical_bytes or
        objects.len > max_object_count or
        object_bytes > max_object_bytes) return error.ImageArchiveTooLarge;
    return object_bytes;
}

fn readNamedEntryAlloc(allocator: std.mem.Allocator, records: *tar.RecordIterator, expected_name: []const u8, max_bytes: usize) ![]u8 {
    const record = try records.next() orelse return error.BadImageArchive;
    if (record.size == 0 or record.size > max_bytes) return error.BadImageArchive;
    try verifyTarHeader(&record.header, expected_name, record.size);
    return records.readPayloadAlloc(allocator, max_bytes);
}

fn readObjectEntry(io: Io, records: *tar.RecordIterator, expected_name: []const u8, object: ObjectDescriptor, path: []const u8) !void {
    const record = try records.next() orelse return error.BadImageArchive;
    try verifyTarHeader(&record.header, expected_name, object.size);
    var file = try Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    var file_buf: [64 * 1024]u8 = undefined;
    var writer: Io.File.Writer = .initStreaming(file, io, &file_buf);
    var hash_buf: [64 * 1024]u8 = undefined;
    var hashed = writer.interface.hashed(Blake3.init(.{}), &hash_buf);
    try records.streamPayload(&hashed.writer);
    try hashed.writer.flush();
    try writer.interface.flush();
    var digest: [Blake3.digest_length]u8 = undefined;
    hashed.hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, object.digest["blake3:".len..], &hex)) return error.BadImageArchiveObject;
}

fn readArchiveEnd(records: *tar.RecordIterator) !void {
    // `next` returns null at the first zero block and at the end of the
    // stream; only after a zero block can a second one follow.
    if (try records.next() != null) return error.BadImageArchive;
    var second: [512]u8 = undefined;
    var trailing: [1]u8 = undefined;
    if (try records.reader.readSliceShort(&second) != second.len or !allZero(&second) or
        try records.reader.readSliceShort(&trailing) != 0) return error.BadImageArchive;
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
    var sum: u64 = 0;
    for (header, 0..) |byte, index| sum += if (index >= 148 and index < 156) ' ' else byte;
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

const fuzz_archive_bytes = 16 * 1024;

fn fuzzArchiveExtraction(_: void, smith: *std.testing.Smith) !void {
    // Archives come from CI or object stores, and unpack parses every entry
    // before it can compare the archive digest. The input is the tar stream
    // inside the gzip layer, so mutations reach the tar, manifest, index and
    // object checks instead of failing in the decompressor.
    var buf: [fuzz_archive_bytes]u8 = undefined;
    const len = smith.slice(&buf);

    // The checking allocator, so leaks and double frees on error paths fail
    // the run.
    const allocator = std.testing.allocator;
    var tmp = fuzz_support.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir);
    extractTestTar(allocator, dir, buf[0..len]) catch {};
}

test "image archive extraction is fuzzed from a packed archive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = fuzz_support.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});

    const seed_tar = try testArchiveTarAlloc(&arena, dir);
    try std.testing.expect(seed_tar.len <= fuzz_archive_bytes);
    // The seed passes every check before the archive digest comparison.
    try std.testing.expectError(error.ImageArchiveDigestMismatch, extractTestTar(allocator, dir, seed_tar));
    // Smith reads a little-endian u32 length before the slice bytes.
    const seed = try allocator.alloc(u8, 4 + seed_tar.len);
    std.mem.writeInt(u32, seed[0..4], @intCast(seed_tar.len), .little);
    @memcpy(seed[4..], seed_tar);
    try std.testing.fuzz({}, fuzzArchiveExtraction, .{ .corpus = &.{seed} });
}

test "image archive must end with exactly two zero blocks after its last object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = try TestDir.init();
    defer tmp.deinit();
    const dir = tmp.root;

    const seed_tar = try testArchiveTarAlloc(&arena, dir);
    const end = seed_tar.len - 1024;
    try std.testing.expect(allZero(seed_tar[end..]));
    try std.testing.expectError(error.ImageArchiveDigestMismatch, extractTestTar(allocator, dir, seed_tar));

    const zero_blocks = [_]u8{0} ** 1024;
    const cases = [_][]const u8{
        seed_tar[0..end],
        seed_tar[0 .. end + 512],
        try std.mem.concat(allocator, u8, &.{ seed_tar, "\x00" }),
        try std.mem.concat(allocator, u8, &.{ seed_tar[0..end], seed_tar[0..512], &zero_blocks }),
    };
    for (cases) |case| try std.testing.expectError(error.BadImageArchive, extractTestTar(allocator, dir, case));
}

/// Gzips `tar_bytes` into `dir` and extracts them as `spore image unpack`
/// does. No archive matches the all-zero digest, so a well-formed archive
/// fails with ImageArchiveDigestMismatch only after every entry has been
/// parsed and every object verified.
fn extractTestTar(allocator: std.mem.Allocator, dir: []const u8, tar_bytes: []const u8) !void {
    const io = std.testing.io;
    const archive_path = try std.fs.path.join(allocator, &.{ dir, "archive.tar.gz" });
    defer allocator.free(archive_path);
    {
        var file = try Io.Dir.cwd().createFile(io, archive_path, .{});
        defer file.close(io);
        var file_buf: [4096]u8 = undefined;
        var writer: Io.File.Writer = .initStreaming(file, io, &file_buf);
        const compress_buf = try allocator.alloc(u8, std.compress.flate.max_window_len * 2);
        defer allocator.free(compress_buf);
        var compressor = try std.compress.flate.Compress.init(&writer.interface, compress_buf, .gzip, .fastest);
        try compressor.writer.writeAll(tar_bytes);
        try compressor.finish();
        try writer.interface.flush();
    }
    const stage_dir = try std.fs.path.join(allocator, &.{ dir, "stage" });
    defer allocator.free(stage_dir);
    Io.Dir.cwd().deleteTree(io, stage_dir) catch {};
    try Io.Dir.cwd().createDirPath(io, stage_dir);
    var extracted = try extractArchive(io, allocator, archive_path, "sha256:" ++ "0" ** 64, stage_dir, .{ .os = "linux", .arch = .arm64 });
    extracted.deinit(allocator);
}

/// Packs a one-object image under `dir` and returns the archive's
/// decompressed tar stream, allocated in `arena`.
fn testArchiveTarAlloc(arena: *std.heap.ArenaAllocator, dir: []const u8) ![]u8 {
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cache = try std.fs.path.join(allocator, &.{ dir, "cache" });
    _ = try publishTestImage(allocator, io, cache, "local/archive:seed", "image archive seed object");

    var env = std.process.Environ.Map.init(allocator);
    try env.put(local_paths.rootfs_cache_env, cache);
    const init = std.process.Init{
        .minimal = undefined,
        .arena = arena,
        .gpa = allocator,
        .io = io,
        .environ_map = &env,
        .preopens = .empty,
    };
    const archive_path = try std.fs.path.join(allocator, &.{ dir, "image.tar.gz" });
    _ = try pack(init, allocator, .{ .source = "local/archive:seed", .output_path = archive_path, .platform = .{ .os = "linux", .arch = .arm64 } });
    const archive = try Io.Dir.cwd().readFileAlloc(io, archive_path, allocator, .limited(1 << 20));
    var input: Io.Reader = .fixed(archive);
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&input, .gzip, &decompress_buf);
    return decompress.reader.allocRemaining(allocator, .limited(1 << 20));
}

const TestImage = struct {
    storage: spore.RootfsStorage,
    object_path: []const u8,
    published: local_image.Published,
};

/// Installs `object_bytes` as the only chunk of an arm64 image in `cache`
/// and publishes it as `name`. `allocator` must be an arena.
fn publishTestImage(allocator: std.mem.Allocator, io: Io, cache: []const u8, name: []const u8, object_bytes: []const u8) !TestImage {
    try Io.Dir.cwd().createDirPath(io, cache);
    const object_id = chunk.ChunkId.fromContents(object_bytes);
    const object_digest_buf = object_id.toDigest();
    const object_digest: []const u8 = &object_digest_buf;
    const entries = [_]disk_index.DiskIndexChunk{.{ .logical_chunk = 0, .id = object_id }};
    const encoded_index = try disk_index.encodeCanonicalAlloc(allocator, .{
        .kind = disk_index.disk_index_kind,
        .logical_size = object_bytes.len,
        .chunk_size = image_manifest.rootfs_chunk_size,
        .hash_algorithm = image_manifest.rootfs_hash_algorithm,
        .object_namespace = image_manifest.rootfs_object_namespace,
        .chunks = &entries,
    });
    const storage = spore.RootfsStorage{
        .kind = image_manifest.rootfs_storage_kind,
        .device = .{ .mmio_slot = image_manifest.rootfs_mmio_slot },
        .logical_size = object_bytes.len,
        .chunk_size = image_manifest.rootfs_chunk_size,
        .hash_algorithm = image_manifest.rootfs_hash_algorithm,
        .index_digest = encoded_index.digest,
        .base_identity = encoded_index.digest,
        .object_namespace = image_manifest.rootfs_object_namespace,
    };
    const index_path = try rootfs_cas.manifestIndexPath(allocator, cache, storage.index_digest);
    _ = try rootfs_cas.installStorageIndexPath(allocator, io, index_path, encoded_index.bytes, storage);
    const object_path = try rootfs_cas.manifestObjectPath(allocator, cache, object_digest);
    _ = try rootfs_cas.installChunkPath(allocator, io, object_path, object_bytes, object_digest, object_bytes.len);
    try rootfs_cas.markStorageComplete(io, allocator, cache, storage.index_digest);
    const published = try local_image.lockAndPublish(io, allocator, cache, .{
        .platform = .{},
        .config = .{ .architecture = .arm64, .os = "linux" },
        .storage = storage,
        .name = name,
    });
    return .{ .storage = storage, .object_path = object_path, .published = published };
}

test "native image archive import enforces aggregate bounds" {
    try std.testing.expectError(
        error.ImageArchiveTooLarge,
        validateArchiveBounds(max_rootfs_logical_bytes + 1, &.{}),
    );

    const half = max_object_bytes / 2 + 1;
    const large = [_]ObjectDescriptor{ .{ .digest = "", .size = half }, .{ .digest = "", .size = half } };
    try std.testing.expectError(error.ImageArchiveTooLarge, validateArchiveBounds(1, &large));

    const many = try std.testing.allocator.alloc(ObjectDescriptor, max_object_count + 1);
    defer std.testing.allocator.free(many);
    @memset(many, .{ .digest = "", .size = 0 });
    try std.testing.expectError(error.ImageArchiveTooLarge, validateArchiveBounds(1, many));
}

test "image pack rejects an image record that does not match its identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const cache = try tmp_dir.path("cache");

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache);
    const init = std.process.Init{
        .minimal = undefined,
        .arena = &arena,
        .gpa = allocator,
        .io = io,
        .environ_map = &env,
        .preopens = .empty,
    };

    const published = (try publishTestImage(allocator, io, cache, "local/archive:native", "local digest archive object")).published;
    const arm64 = rootfs.Platform{ .os = "linux", .arch = .arm64 };
    const native = try pack(init, allocator, .{ .source = "local/archive:native", .output_path = try tmp_dir.path("native.tar.gz"), .platform = arm64 });
    try std.testing.expectEqualStrings(published.identity, native.image_digest);

    const record = try Io.Dir.cwd().readFileAlloc(io, published.record_path, allocator, .limited(1024 * 1024));
    const tampered = try std.mem.replaceOwned(u8, allocator, record, "\"architecture\": \"arm64\"", "\"architecture\": \"arm64\", \"config\": {\"WorkingDir\": \"/tampered\"}");
    try std.testing.expect(!std.mem.eql(u8, record, tampered));
    try chunk_sealer.replaceFileAtomicDurable(allocator, published.record_path, tampered, 0o644);
    try std.testing.expectError(error.BadManifest, pack(init, allocator, .{ .source = "local/archive:native", .output_path = try tmp_dir.path("tampered.tar.gz"), .platform = arm64 }));
    try std.testing.expectError(error.FileNotFound, pack(init, allocator, .{ .source = "local/archive:missing", .output_path = try tmp_dir.path("missing.tar.gz"), .platform = arm64 }));
}

test "native image archive round-trips into a clean cache and rejects substitution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, try tmp_dir.path("producer-cache"));
    const init = std.process.Init{
        .minimal = undefined,
        .arena = &arena,
        .gpa = allocator,
        .io = io,
        .environ_map = &env,
        .preopens = .empty,
    };

    const object_bytes = "native image archive object";
    const producer = try publishTestImage(allocator, io, try tmp_dir.path("producer-cache"), "local/archive:producer", object_bytes);
    const published = producer.published;
    const storage = producer.storage;
    const installed_object = producer.object_path;

    const archive_path = try tmp_dir.path("image.tar.gz");
    const pack_result = try pack(init, allocator, .{
        .source = "local/archive:producer",
        .output_path = archive_path,
        .platform = .{ .os = "linux", .arch = .arm64 },
    });
    defer deinitPackResult(allocator, pack_result);
    try std.testing.expectEqual(resource.Type.image, pack_result.resource_type);
    try std.testing.expectEqualStrings(published.identity, pack_result.image_digest);
    try std.testing.expectEqual(@as(usize, 1), pack_result.object_count);
    try std.testing.expectError(error.ImageArchiveOutputExists, pack(init, allocator, .{
        .source = "local/archive:producer",
        .output_path = archive_path,
        .platform = .{ .os = "linux", .arch = .arm64 },
    }));

    const duplicate_archive_path = try tmp_dir.path("image-duplicate.tar.gz");
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
        .output_path = try tmp_dir.path("corrupt.tar.gz"),
        .platform = .{ .os = "linux", .arch = .arm64 },
    }));

    const consumer_cache = try tmp_dir.path("consumer-cache");
    try env.put(local_paths.rootfs_cache_env, consumer_cache);
    const unpacked = try unpack(init, allocator, .{
        .archive_path = archive_path,
        .archive_digest = pack_result.archive_digest,
        .expected_image_digest = pack_result.image_digest,
        .ref = "local/archive:consumer",
        .platform = .{ .os = "linux", .arch = .arm64 },
    });
    defer deinitUnpackResult(allocator, unpacked);
    try std.testing.expectEqual(resource.Type.image, unpacked.resource_type);
    try std.testing.expectEqualStrings(pack_result.image_digest, unpacked.image_digest);
    try std.testing.expect(try rootfs_cas.storageMarkedComplete(io, allocator, consumer_cache, storage));
    try Io.Dir.cwd().access(io, try tmp_dir.path("consumer-cache/refs"), .{});

    const rejected_cache = try tmp_dir.path("rejected-cache");
    try env.put(local_paths.rootfs_cache_env, rejected_cache);
    try std.testing.expectError(error.ImageArchiveDigestMismatch, unpack(init, allocator, .{
        .archive_path = archive_path,
        .archive_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .expected_image_digest = pack_result.image_digest,
        .ref = "local/archive:rejected",
        .platform = .{ .os = "linux", .arch = .arm64 },
    }));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, try tmp_dir.path("rejected-cache/refs"), .{}));

    const identity_rejected_cache = try tmp_dir.path("identity-rejected-cache");
    try env.put(local_paths.rootfs_cache_env, identity_rejected_cache);
    try std.testing.expectError(error.ImageIdentityMismatch, unpack(init, allocator, .{
        .archive_path = archive_path,
        .archive_digest = pack_result.archive_digest,
        .expected_image_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .ref = "local/archive:wrong-identity",
        .platform = .{ .os = "linux", .arch = .arm64 },
    }));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, try tmp_dir.path("identity-rejected-cache/refs"), .{}));

    try std.testing.expectError(error.BadProtocol, unpack(init, allocator, .{
        .archive_path = archive_path,
        .archive_digest = pack_result.archive_digest,
        .expected_image_digest = pack_result.image_digest,
        .ref = "local/archive:wrong-arch",
        .platform = .{ .os = "linux", .arch = .amd64 },
    }));
}
