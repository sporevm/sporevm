//! Bounded, canonical native image manifest and closure verification.
//!
//! The manifest describes one platform-specific native image. This module is
//! deliberately data-only: callers provide the manifest, config, and disk
//! index bytes, so image transports share verification without acquiring
//! network, cache, filesystem, or runtime dependencies.

const std = @import("std");
const disk_index = @import("disk_index.zig");
const image = @import("image.zig");
const oci = @import("rootfs/oci.zig");
const spore = @import("spore.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const image_manifest_kind = "spore-image-gateway-manifest-v1";
pub const max_image_manifest_bytes: usize = 64 * 1024;
pub const max_config_blob_bytes: usize = 64 * 1024 * 1024;

pub const rootfs_device_kind = "virtio-mmio";
pub const rootfs_device_role = "rootfs";
pub const rootfs_device_id: u32 = 2;
pub const rootfs_mmio_slot: u32 = 1;
pub const rootfs_storage_kind = "chunked-ext4-rootfs-v0";
pub const rootfs_chunk_size: u64 = 64 * 1024;
pub const rootfs_hash_algorithm = "blake3";
pub const rootfs_object_namespace = "rootfs/blake3";

pub const Error = error{
    BadProtocol,
    OutOfMemory,
};

pub const ConfigBlobDescriptor = struct {
    transport_digest: []const u8,
    config_digest: []const u8,
    bytes: u64,
};

pub const ManifestImage = struct {
    digest: []const u8,
    platform: oci.Platform,
    config_blob: ConfigBlobDescriptor,
    rootfs_storage: spore.RootfsStorage,
};

pub const RootfsIndexDescriptor = struct {
    digest: []const u8,
    bytes: u64,
    object_count: u64,
    object_bytes: u64,
};

pub const ImageManifest = struct {
    kind: []const u8,
    image: ManifestImage,
    rootfs_index: RootfsIndexDescriptor,
};

pub const EncodedImageManifest = struct {
    bytes: []u8,
    transport_digest: []u8,

    pub fn deinit(self: EncodedImageManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.transport_digest);
    }
};

/// Parse the one accepted image-manifest representation. Unknown or duplicate
/// fields, trailing bytes, alternate JSON formatting, and inconsistent closure
/// metadata fail closed.
pub fn parseImageManifest(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) Error!std.json.Parsed(ImageManifest) {
    if (bytes.len == 0 or bytes.len > max_image_manifest_bytes) return error.BadProtocol;
    const parsed = std.json.parseFromSlice(ImageManifest, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadProtocol,
    };
    errdefer parsed.deinit();
    try validateImageManifest(parsed.value);
    const canonical = try canonicalImageManifestAlloc(allocator, parsed.value);
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, bytes, canonical)) return error.BadProtocol;
    return parsed;
}

pub fn encodeImageManifestAlloc(
    allocator: std.mem.Allocator,
    manifest: ImageManifest,
) Error!EncodedImageManifest {
    const bytes = try canonicalImageManifestAlloc(allocator, manifest);
    errdefer allocator.free(bytes);
    return .{
        .bytes = bytes,
        .transport_digest = try transportDigestAlloc(allocator, bytes),
    };
}

pub fn validateImageManifest(manifest: ImageManifest) Error!void {
    if (!std.mem.eql(u8, manifest.kind, image_manifest_kind)) return error.BadProtocol;
    if (!std.mem.eql(u8, manifest.image.platform.os, "linux")) return error.BadProtocol;
    try validateDigest(manifest.image.digest, "blake3:");

    const config = manifest.image.config_blob;
    try validateDigest(config.transport_digest, "sha256:");
    try validateDigest(config.config_digest, "blake3:");
    if (config.bytes == 0 or config.bytes > max_config_blob_bytes) return error.BadProtocol;

    const storage = manifest.image.rootfs_storage;
    if (!std.mem.eql(u8, storage.kind, rootfs_storage_kind) or
        !std.mem.eql(u8, storage.device.kind, rootfs_device_kind) or
        !std.mem.eql(u8, storage.device.role, rootfs_device_role) or
        storage.device.virtio_device_id != rootfs_device_id or
        storage.device.mmio_slot != rootfs_mmio_slot or
        storage.logical_size == 0 or storage.logical_size > std.math.maxInt(usize) or
        storage.chunk_size != rootfs_chunk_size or
        !std.mem.eql(u8, storage.hash_algorithm, rootfs_hash_algorithm) or
        !std.mem.eql(u8, storage.object_namespace, rootfs_object_namespace)) return error.BadProtocol;
    try validateDigest(storage.index_digest, "blake3:");
    if (!std.mem.eql(u8, storage.base_identity, storage.index_digest)) return error.BadProtocol;

    const index = manifest.rootfs_index;
    try validateDigest(index.digest, "blake3:");
    if (!std.mem.eql(u8, index.digest, storage.index_digest) or
        index.bytes == 0 or index.bytes > disk_index.max_index_bytes or
        index.object_bytes > storage.logical_size) return error.BadProtocol;
    const chunk_count = std.math.divCeil(u64, storage.logical_size, storage.chunk_size) catch return error.BadProtocol;
    if (index.object_count > chunk_count) return error.BadProtocol;
}

/// Verify the manifest named by `expected_manifest_digest` and its complete
/// closure, and return the owned parsed manifest. Success proves transport
/// digests, platform, canonical native config, disk-index integrity and
/// summary, and native image identity.
pub fn verifyImageManifest(
    allocator: std.mem.Allocator,
    expected_manifest_digest: []const u8,
    platform: oci.Platform,
    manifest_bytes: []const u8,
    canonical_config_bytes: []const u8,
    rootfs_index_bytes: []const u8,
) Error!std.json.Parsed(ImageManifest) {
    var parsed = try parseImageManifest(allocator, manifest_bytes);
    errdefer parsed.deinit();
    const manifest = parsed.value;

    const manifest_digest = try transportDigestAlloc(allocator, manifest_bytes);
    defer allocator.free(manifest_digest);
    if (!std.mem.eql(u8, manifest_digest, expected_manifest_digest) or
        !std.mem.eql(u8, platform.os, manifest.image.platform.os) or
        platform.arch != manifest.image.platform.arch) return error.BadProtocol;

    if (canonical_config_bytes.len != manifest.image.config_blob.bytes) return error.BadProtocol;
    const config_transport = try transportDigestAlloc(allocator, canonical_config_bytes);
    defer allocator.free(config_transport);
    if (!std.mem.eql(u8, config_transport, manifest.image.config_blob.transport_digest)) return error.BadProtocol;

    var config = parseCanonicalConfig(allocator, canonical_config_bytes) catch |err| return mapProtocolError(err);
    defer config.deinit();
    if (config.value.os == null or config.value.architecture == null or
        !std.mem.eql(u8, config.value.os.?, manifest.image.platform.os) or
        config.value.architecture.? != manifest.image.platform.arch) return error.BadProtocol;
    const config_digest = image.configDigestAlloc(allocator, canonical_config_bytes) catch return error.OutOfMemory;
    defer allocator.free(config_digest);
    if (!std.mem.eql(u8, config_digest, manifest.image.config_blob.config_digest)) return error.BadProtocol;

    const storage = manifest.image.rootfs_storage;
    var index = disk_index.parseDiskIndex(allocator, rootfs_index_bytes, .{
        .logical_size = storage.logical_size,
        .chunk_size = storage.chunk_size,
        .hash_algorithm = storage.hash_algorithm,
        .object_namespace = storage.object_namespace,
        .index_digest = storage.index_digest,
    }) catch |err| return mapProtocolError(err);
    defer index.deinit();
    const summary = objectSummary(allocator, index.value) catch |err| return mapProtocolError(err);
    if (rootfs_index_bytes.len != manifest.rootfs_index.bytes or
        summary.count != manifest.rootfs_index.object_count or
        summary.bytes != manifest.rootfs_index.object_bytes) return error.BadProtocol;

    const image_digest = image.imageDigestAlloc(allocator, storage.index_digest, canonical_config_bytes) catch return error.OutOfMemory;
    defer allocator.free(image_digest);
    if (!std.mem.eql(u8, image_digest, manifest.image.digest)) return error.BadProtocol;
    return parsed;
}

fn canonicalImageManifestAlloc(allocator: std.mem.Allocator, manifest: ImageManifest) Error![]u8 {
    try validateImageManifest(manifest);
    const bytes = std.json.Stringify.valueAlloc(allocator, manifest, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    }) catch return error.OutOfMemory;
    errdefer allocator.free(bytes);
    if (bytes.len == 0 or bytes.len > max_image_manifest_bytes) return error.BadProtocol;
    return bytes;
}

pub fn parseCanonicalConfig(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(image.Config) {
    if (bytes.len == 0 or bytes.len > max_config_blob_bytes) return error.BadProtocol;
    const parsed = try std.json.parseFromSlice(image.Config, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    });
    errdefer parsed.deinit();
    const canonical = try image.canonicalConfigJson(allocator, parsed.value);
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, bytes, canonical)) return error.BadProtocol;
    return parsed;
}

pub fn validateDigest(digest: []const u8, prefix: []const u8) Error!void {
    if (!std.mem.startsWith(u8, digest, prefix)) return error.BadProtocol;
    const hex = digest[prefix.len..];
    if (hex.len != 64) return error.BadProtocol;
    for (hex) |byte| {
        if ((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f')) continue;
        return error.BadProtocol;
    }
}

/// Name exact canonical bytes by their lowercase SHA-256 transport digest.
pub fn transportDigestAlloc(allocator: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex}) catch return error.OutOfMemory;
}

const ObjectSummary = struct {
    count: u64,
    bytes: u64,
};

fn objectSummary(allocator: std.mem.Allocator, index: disk_index.DiskIndex) !ObjectSummary {
    var seen = std.StringHashMap(u64).init(allocator);
    defer seen.deinit();
    var total: u64 = 0;
    for (index.chunks) |entry| {
        const offset = std.math.mul(u64, entry.logical_chunk, index.chunk_size) catch return error.BadProtocol;
        if (offset >= index.logical_size) return error.BadProtocol;
        const bytes = @min(index.chunk_size, index.logical_size - offset);
        const result = try seen.getOrPut(entry.digest);
        if (result.found_existing) {
            if (result.value_ptr.* != bytes) return error.BadProtocol;
            continue;
        }
        result.value_ptr.* = bytes;
        total = std.math.add(u64, total, bytes) catch return error.BadProtocol;
    }
    return .{ .count = @intCast(seen.count()), .bytes = total };
}

fn mapProtocolError(err: anyerror) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.BadProtocol;
}

fn readFixtureAlloc(allocator: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max));
}

fn canonicalFixtureBytes(bytes: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, bytes, "\n")) bytes[0 .. bytes.len - 1] else bytes;
}

const arm64_manifest_digest = "sha256:b657390a5d37e2f098694027575d44fee3e235d64d6ffa630c995d9be54a01ca";

fn verifyFixture(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    config_path: []const u8,
    platform: oci.Platform,
    manifest_digest: []const u8,
    image_digest: []const u8,
) !void {
    const manifest_storage = try readFixtureAlloc(allocator, manifest_path, max_image_manifest_bytes);
    defer allocator.free(manifest_storage);
    const config_storage = try readFixtureAlloc(allocator, config_path, max_config_blob_bytes);
    defer allocator.free(config_storage);
    const index_storage = try readFixtureAlloc(allocator, "test/image/rootfs-index.json", disk_index.max_index_bytes);
    defer allocator.free(index_storage);
    const manifest_bytes = canonicalFixtureBytes(manifest_storage);
    const config_bytes = canonicalFixtureBytes(config_storage);
    const index_bytes = canonicalFixtureBytes(index_storage);

    var parsed = try verifyImageManifest(allocator, manifest_digest, platform, manifest_bytes, config_bytes, index_bytes);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(image_digest, parsed.value.image.digest);
    const encoded = try encodeImageManifestAlloc(allocator, parsed.value);
    defer encoded.deinit(allocator);
    try std.testing.expectEqualStrings(manifest_bytes, encoded.bytes);
    try std.testing.expectEqualStrings(manifest_digest, encoded.transport_digest);
}

test "arm64 and amd64 image-manifest fixtures verify complete closure" {
    const allocator = std.testing.allocator;
    try verifyFixture(
        allocator,
        "test/image/image-manifest-arm64.json",
        "test/image/config-arm64.json",
        .{ .os = "linux", .arch = .arm64 },
        arm64_manifest_digest,
        "blake3:792e35d2abe3a9155e79ae1e57bdedffaefe9be673852eda44e87297e8ddbcca",
    );
    try verifyFixture(
        allocator,
        "test/image/image-manifest-amd64.json",
        "test/image/config-amd64.json",
        .{ .os = "linux", .arch = .amd64 },
        "sha256:5204bf7ae314b9ec88c9650b445d505d5e044a577794cafd7ba927a3377f6727",
        "blake3:8817e359af38ba3e65881b4ccd3c68e387ffbfe0eb59cc1c79146657d7b2fe4c",
    );
}

test "image-manifest verification rejects broken closure" {
    const allocator = std.testing.allocator;
    const manifest_storage = try readFixtureAlloc(allocator, "test/image/image-manifest-arm64.json", max_image_manifest_bytes);
    defer allocator.free(manifest_storage);
    const config_storage = try readFixtureAlloc(allocator, "test/image/config-arm64.json", max_config_blob_bytes);
    defer allocator.free(config_storage);
    const index_storage = try readFixtureAlloc(allocator, "test/image/rootfs-index.json", disk_index.max_index_bytes);
    defer allocator.free(index_storage);
    const manifest_bytes = canonicalFixtureBytes(manifest_storage);
    const config_bytes = canonicalFixtureBytes(config_storage);
    const index_bytes = canonicalFixtureBytes(index_storage);
    const arm64 = oci.Platform{ .os = "linux", .arch = .arm64 };

    try std.testing.expectError(error.BadProtocol, verifyImageManifest(allocator, "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", arm64, manifest_bytes, config_bytes, index_bytes));
    try std.testing.expectError(error.BadProtocol, verifyImageManifest(allocator, arm64_manifest_digest, .{ .os = "linux", .arch = .amd64 }, manifest_bytes, config_bytes, index_bytes));

    const bad_config = try allocator.dupe(u8, config_bytes);
    defer allocator.free(bad_config);
    bad_config[17] = 'x';
    try std.testing.expectError(error.BadProtocol, verifyImageManifest(allocator, arm64_manifest_digest, arm64, manifest_bytes, bad_config, index_bytes));

    const bad_index = try allocator.dupe(u8, index_bytes);
    defer allocator.free(bad_index);
    bad_index[bad_index.len - 3] = '1';
    try std.testing.expectError(error.BadProtocol, verifyImageManifest(allocator, arm64_manifest_digest, arm64, manifest_bytes, config_bytes, bad_index));

    var parsed = try parseImageManifest(allocator, manifest_bytes);
    defer parsed.deinit();
    parsed.value.rootfs_index.object_bytes -= 1;
    const inconsistent = try encodeImageManifestAlloc(allocator, parsed.value);
    defer inconsistent.deinit(allocator);
    try std.testing.expectError(error.BadProtocol, verifyImageManifest(allocator, inconsistent.transport_digest, arm64, inconsistent.bytes, config_bytes, index_bytes));

    parsed.value.rootfs_index.object_bytes += 1;
    parsed.value.rootfs_index.object_count -= 1;
    const wrong_count = try encodeImageManifestAlloc(allocator, parsed.value);
    defer wrong_count.deinit(allocator);
    try std.testing.expectError(error.BadProtocol, verifyImageManifest(allocator, wrong_count.transport_digest, arm64, wrong_count.bytes, config_bytes, index_bytes));

    parsed.value.rootfs_index.object_count += 1;
    parsed.value.rootfs_index.bytes += 1;
    const wrong_index_bytes = try encodeImageManifestAlloc(allocator, parsed.value);
    defer wrong_index_bytes.deinit(allocator);
    try std.testing.expectError(error.BadProtocol, verifyImageManifest(allocator, wrong_index_bytes.transport_digest, arm64, wrong_index_bytes.bytes, config_bytes, index_bytes));
}

test "image-manifest verification rejects config and manifest architecture confusion" {
    const allocator = std.testing.allocator;
    const manifest_storage = try readFixtureAlloc(allocator, "test/image/image-manifest-amd64.json", max_image_manifest_bytes);
    defer allocator.free(manifest_storage);
    const config_storage = try readFixtureAlloc(allocator, "test/image/config-amd64.json", max_config_blob_bytes);
    defer allocator.free(config_storage);
    const index_storage = try readFixtureAlloc(allocator, "test/image/rootfs-index.json", disk_index.max_index_bytes);
    defer allocator.free(index_storage);
    const config_bytes = canonicalFixtureBytes(config_storage);
    const index_bytes = canonicalFixtureBytes(index_storage);

    var parsed = try parseImageManifest(allocator, canonicalFixtureBytes(manifest_storage));
    defer parsed.deinit();
    parsed.value.image.platform.arch = .arm64;
    const confused = try encodeImageManifestAlloc(allocator, parsed.value);
    defer confused.deinit(allocator);
    try std.testing.expectError(error.BadProtocol, verifyImageManifest(
        allocator,
        confused.transport_digest,
        .{ .os = "linux", .arch = .arm64 },
        confused.bytes,
        config_bytes,
        index_bytes,
    ));
}

test "rootfs object summary counts unique immutable objects" {
    const repeated = disk_index.DiskIndex{
        .kind = disk_index.disk_index_kind,
        .logical_size = 2 * rootfs_chunk_size,
        .chunk_size = rootfs_chunk_size,
        .hash_algorithm = rootfs_hash_algorithm,
        .object_namespace = rootfs_object_namespace,
        .chunks = &.{
            .{ .logical_chunk = 0, .digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
            .{ .logical_chunk = 1, .digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
        },
    };
    const summary = try objectSummary(std.testing.allocator, repeated);
    try std.testing.expectEqual(@as(u64, 1), summary.count);
    try std.testing.expectEqual(rootfs_chunk_size, summary.bytes);

    var inconsistent = repeated;
    inconsistent.logical_size -= 1;
    try std.testing.expectError(error.BadProtocol, objectSummary(std.testing.allocator, inconsistent));
}

test "image-manifest parser and schema bounds fail closed" {
    const allocator = std.testing.allocator;
    const manifest_storage = try readFixtureAlloc(allocator, "test/image/image-manifest-arm64.json", max_image_manifest_bytes);
    defer allocator.free(manifest_storage);
    const manifest_bytes = canonicalFixtureBytes(manifest_storage);
    const trailing = try std.mem.concat(allocator, u8, &.{ manifest_bytes, "\n" });
    defer allocator.free(trailing);
    try std.testing.expectError(error.BadProtocol, parseImageManifest(allocator, trailing));

    const duplicate = try std.mem.replaceOwned(
        u8,
        allocator,
        manifest_bytes,
        "\"kind\": \"spore-image-gateway-manifest-v1\"",
        "\"kind\": \"spore-image-gateway-manifest-v1\",\n  \"kind\": \"spore-image-gateway-manifest-v1\"",
    );
    defer allocator.free(duplicate);
    try std.testing.expectError(error.BadProtocol, parseImageManifest(allocator, duplicate));

    const unknown = try std.mem.replaceOwned(
        u8,
        allocator,
        manifest_bytes,
        "\"object_bytes\": 65537",
        "\"object_bytes\": 65537,\n    \"objects_url\": \"https://example.invalid\"",
    );
    defer allocator.free(unknown);
    try std.testing.expectError(error.BadProtocol, parseImageManifest(allocator, unknown));

    const uppercase = try allocator.dupe(u8, manifest_bytes);
    defer allocator.free(uppercase);
    const digest_offset = std.mem.indexOf(u8, uppercase, "792e35d2") orelse unreachable;
    uppercase[digest_offset + 3] = 'E';
    try std.testing.expectError(error.BadProtocol, parseImageManifest(allocator, uppercase));

    const invalid_utf8 = try allocator.dupe(u8, manifest_bytes);
    defer allocator.free(invalid_utf8);
    const storage_kind = std.mem.indexOf(u8, invalid_utf8, "chunked-ext4") orelse unreachable;
    invalid_utf8[storage_kind] = 0xff;
    try std.testing.expectError(error.BadProtocol, parseImageManifest(allocator, invalid_utf8));

    const oversized = try allocator.alloc(u8, max_image_manifest_bytes + 1);
    defer allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.BadProtocol, parseImageManifest(allocator, oversized));

    var parsed = try parseImageManifest(allocator, manifest_bytes);
    defer parsed.deinit();
    parsed.value.image.rootfs_storage.device.mmio_slot = 2;
    try std.testing.expectError(error.BadProtocol, validateImageManifest(parsed.value));
    parsed.value.image.rootfs_storage.device.mmio_slot = rootfs_mmio_slot;
    parsed.value.image.rootfs_storage.base_identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expectError(error.BadProtocol, validateImageManifest(parsed.value));
    parsed.value.image.rootfs_storage.base_identity = parsed.value.image.rootfs_storage.index_digest;
    parsed.value.rootfs_index.digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expectError(error.BadProtocol, validateImageManifest(parsed.value));
}

test "image-manifest rootfs wire constants match the native storage contract" {
    try std.testing.expectEqualStrings(spore.rootfs_device_kind_virtio_mmio, rootfs_device_kind);
    try std.testing.expectEqualStrings(spore.rootfs_device_role, rootfs_device_role);
    try std.testing.expectEqual(spore.rootfs_virtio_blk_device_id, rootfs_device_id);
    try std.testing.expectEqualStrings(spore.rootfs_storage_kind_chunked_ext4, rootfs_storage_kind);
    try std.testing.expectEqual(spore.disk_chunk_size, rootfs_chunk_size);
    try std.testing.expectEqualStrings(spore.rootfs_storage_hash_algorithm_blake3, rootfs_hash_algorithm);
    try std.testing.expectEqualStrings(spore.rootfs_storage_object_namespace, rootfs_object_namespace);
}

fn fuzzImageManifestParse(_: void, smith: *std.testing.Smith) !void {
    var buf: [max_image_manifest_bytes + 1]u8 = undefined;
    const bytes = buf[0..smith.slice(&buf)];
    const parsed = parseImageManifest(std.testing.allocator, bytes) catch return;
    parsed.deinit();
}

test "fuzz image-manifest parser" {
    try std.testing.fuzz({}, fuzzImageManifestParse, .{});
}

fn fuzzCanonicalConfigParse(_: void, smith: *std.testing.Smith) !void {
    var buf: [max_image_manifest_bytes]u8 = undefined;
    const bytes = buf[0..smith.slice(&buf)];
    const parsed = parseCanonicalConfig(std.testing.allocator, bytes) catch return;
    parsed.deinit();
}

test "fuzz canonical image-config parser" {
    try std.testing.fuzz({}, fuzzCanonicalConfigParse, .{});
}
