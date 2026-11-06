//! Local image catalog in the rootfs cache.
//!
//! Every local image is identified by its native digest: BLAKE3 over its rootfs
//! index and canonical config (see image.zig), however it was produced. The
//! catalog has three record kinds, each replaced atomically and durably:
//!
//!   images/<hex>.json              the image: platform, config, rootfs
//!                                  storage, and where it came from
//!   images/derivations/<key>.json  an OCI source (manifest, index or tar
//!                                  digest) converted by one rootfs builder
//!                                  on one platform into an image
//!   refs/<key>.json                a name (`local/app:dev`,
//!                                  `docker.io/library/alpine:3.20`) on one
//!                                  platform pointing at an image
//!
//! Images converted from OCI layers also keep their flat ext4 as
//! `images/<hex>.ext4`, a hard link of the digest-addressed materialization.
//!
//! Only image records root CAS storage for GC. Refs and derivations only name
//! images, so they may dangle after `system prune` removes an image; lookups
//! then miss and the image is rebuilt or reported missing.
//!
//! Values read from the catalog are allocated, with their parse scratch, into
//! the caller's allocator; pass an arena.

const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const chunk_sealer = @import("chunk_sealer.zig");
const image = @import("image.zig");
const oci = @import("rootfs/oci.zig");
const rootfs = @import("rootfs.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const spore = @import("spore.zig");

pub const Platform = oci.Platform;

pub const images_dir = "images";
pub const derivations_dir = "derivations";
pub const refs_dir = "refs";
const record_kind = "spore-local-image-v1";
const derivation_kind = "spore-image-derivation-v1";
const ref_kind = "spore-image-ref-v1";
const max_record_bytes = 1024 * 1024;

/// Where an image converted from OCI layers came from.
pub const OciProvenance = struct {
    /// Digest-pinned source: `registry/repo@sha256:...` for a registry pull,
    /// `local/name@sha256:...` for an imported OCI layout or rootfs tar.
    ref: []const u8,
    /// The selected OCI manifest digest, or the imported tar digest.
    manifest_digest: []const u8,
    /// Rootfs builder that converted the layers.
    builder_version: []const u8,
};

pub const LocalImage = struct {
    kind: []const u8 = record_kind,
    identity: []const u8,
    platform: Platform,
    config: image.Config,
    storage: spore.RootfsStorage,
    oci: ?OciProvenance = null,
    /// Image store that holds every object `storage` names, recorded only
    /// while some objects are missing locally. The index is always local.
    origin: ?[]const u8 = null,
};

const DerivationRecord = struct {
    kind: []const u8 = derivation_kind,
    /// OCI manifest, OCI index or rootfs tar digest.
    source_digest: []const u8,
    platform: Platform,
    builder_version: []const u8,
    image: []const u8,
};

const RefRecord = struct {
    kind: []const u8 = ref_kind,
    name: []const u8,
    platform: Platform,
    image: []const u8,
};

pub const PublishRequest = struct {
    platform: Platform,
    /// Missing architecture and OS are filled in from `platform`.
    config: image.Config = .{},
    storage: spore.RootfsStorage,
    oci: ?OciProvenance = null,
    /// OCI index digest `oci.manifest_digest` was selected from for
    /// `platform`, also recorded as a derivation so the index digest
    /// resolves without the registry.
    selected_from: ?[]const u8 = null,
    /// Store to fetch missing objects from. Ignored when storage is complete
    /// locally; required when it is not.
    origin: ?[]const u8 = null,
    /// Materialized ext4 hard-linked into the catalog as `images/<hex>.ext4`.
    flat_path: ?[]const u8 = null,
    /// Name pointed at the image after everything else is published.
    name: ?[]const u8 = null,
    expected_identity: ?[]const u8 = null,
};

pub const Published = struct {
    identity: []const u8,
    /// `local/<repo>@<identity>` for local names, otherwise the OCI source.
    resolved_ref: []const u8,
    record_path: []const u8,
    ref_path: ?[]const u8,

    pub fn deinit(self: Published, allocator: std.mem.Allocator) void {
        allocator.free(self.identity);
        allocator.free(self.resolved_ref);
        allocator.free(self.record_path);
        if (self.ref_path) |path| allocator.free(path);
    }
};

/// Resolve `ref` on `platform` to an image identity, without network access.
/// `name@blake3:...` names the image itself, `name@sha256:...` the image the
/// current builder converted from that OCI source, and a tag follows its ref
/// record. Returns null when nothing is recorded; the image record itself may
/// still be missing. Allocates the result into `allocator`.
pub fn lookup(io: Io, allocator: std.mem.Allocator, cache_root: []const u8, ref: []const u8, platform: Platform) !?[]const u8 {
    if (std.mem.lastIndexOfScalar(u8, ref, '@')) |at| {
        const digest = ref[at + 1 ..];
        if (std.mem.startsWith(u8, digest, image.digest_prefix)) {
            _ = try oci.parseImageName(ref[0..at]);
            try validateIdentity(digest);
            return try allocator.dupe(u8, digest);
        }
        const source = try oci.ImageRef.parse(ref);
        const path = try derivationPath(allocator, cache_root, source.digest, platform, rootfs.builder_version);
        defer allocator.free(path);
        const record = (try readJson(DerivationRecord, io, allocator, path)) orelse return null;
        if (!std.mem.eql(u8, record.kind, derivation_kind) or
            !std.mem.eql(u8, record.source_digest, source.digest) or
            !samePlatform(record.platform, platform) or
            !std.mem.eql(u8, record.builder_version, rootfs.builder_version)) return error.BadManifest;
        try validateIdentity(record.image);
        return record.image;
    }
    _ = try oci.ImageTag.parse(ref);
    const path = try refPath(allocator, cache_root, ref, platform);
    defer allocator.free(path);
    const record = (try readJson(RefRecord, io, allocator, path)) orelse return null;
    if (!std.mem.eql(u8, record.kind, ref_kind) or
        !std.mem.eql(u8, record.name, ref) or
        !samePlatform(record.platform, platform)) return error.BadManifest;
    try validateIdentity(record.image);
    return record.image;
}

/// `lookup` then `load`, for an image built for `platform`.
pub fn find(io: Io, allocator: std.mem.Allocator, cache_root: []const u8, ref: []const u8, platform: Platform) !?LocalImage {
    const identity = (try lookup(io, allocator, cache_root, ref, platform)) orelse return null;
    const local = (try load(io, allocator, cache_root, identity)) orelse return null;
    if (!samePlatform(local.platform, platform)) return error.UnsupportedPlatform;
    return local;
}

/// Load an image whose record exists and whose storage is complete locally.
/// Returns null otherwise. Allocates into `allocator`; use an arena.
pub fn load(io: Io, allocator: std.mem.Allocator, cache_root: []const u8, identity: []const u8) !?LocalImage {
    const local = (try readRecord(io, allocator, cache_root, identity)) orelse return null;
    if (!try rootfs_cas.storageCompleteWithStampRepair(io, allocator, cache_root, local.storage)) return null;
    return local;
}

/// Like `load`, but also returns an image with objects missing locally when
/// its record names an `origin` to fetch them from. Only for callers that
/// attach that origin to the disk they open.
pub fn loadAllowingOrigin(io: Io, allocator: std.mem.Allocator, cache_root: []const u8, identity: []const u8) !?LocalImage {
    const local = (try readRecord(io, allocator, cache_root, identity)) orelse return null;
    if (local.origin == null and !try rootfs_cas.storageCompleteWithStampRepair(io, allocator, cache_root, local.storage)) return null;
    return local;
}

/// Read the record for `identity` without checking its storage. Returns null
/// when there is no record and `error.BadManifest` when it is malformed.
pub fn readRecord(io: Io, allocator: std.mem.Allocator, cache_root: []const u8, identity: []const u8) !?LocalImage {
    const path = try recordPath(allocator, cache_root, identity);
    defer allocator.free(path);
    const bytes = try readBounded(io, allocator, path) orelse return null;
    return try parseRecord(allocator, bytes, identity);
}

/// Parse and validate an image record named `<hex>.json` for `identity`.
pub fn parseRecord(allocator: std.mem.Allocator, bytes: []const u8, identity: []const u8) !LocalImage {
    const local = std.json.parseFromSliceLeaky(LocalImage, allocator, bytes, .{ .allocate = .alloc_always }) catch return error.BadManifest;
    if (!std.mem.eql(u8, local.kind, record_kind)) return error.BadManifest;
    try spore.validateRootfsStorageDescriptor(local.storage);
    const arch = local.config.architecture orelse return error.BadManifest;
    const os = local.config.os orelse return error.BadManifest;
    if (arch != local.platform.arch or !std.mem.eql(u8, os, local.platform.os)) return error.BadManifest;
    if (local.origin) |origin| if (origin.len == 0) return error.BadManifest;
    const computed = try identityAlloc(allocator, local.storage.index_digest, local.config);
    defer allocator.free(computed);
    if (!std.mem.eql(u8, local.identity, identity) or !std.mem.eql(u8, computed, identity)) return error.BadManifest;
    return local;
}

/// Publish an image in the caller's cache-lock epoch, so GC cannot collect
/// storage the record is about to root: the flat file and the record, then
/// its derivation, then `name`. Each step is a durable atomic replacement.
pub fn publish(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    cache_lock: *const rootfs.RootfsCacheLock,
    request: PublishRequest,
) !Published {
    if (!try cache_lock.ensureHeldFor(allocator, cache_root)) return error.RootfsCacheLockNotHeld;
    try spore.validateRootfsStorageDescriptor(request.storage);
    try spore.validateRootfsDeviceShape(request.storage.device);
    if (!std.mem.eql(u8, request.storage.index_digest, request.storage.base_identity)) return error.BadManifest;
    if (request.name) |name| try validateName(name, request.oci);
    var config = request.config;
    if (config.architecture) |arch| {
        if (arch != request.platform.arch) return error.UnsupportedPlatform;
    } else config.architecture = request.platform.arch;
    if (config.os) |os| {
        if (!std.mem.eql(u8, os, request.platform.os)) return error.UnsupportedPlatform;
    } else config.os = request.platform.os;
    // A complete local copy is authoritative: the record names an origin only
    // while objects are missing, so publishing with or without one never
    // changes a complete image.
    const origin = if (try rootfs_cas.storageCompleteWithStampRepair(io, allocator, cache_root, request.storage)) null else origin: {
        const origin = request.origin orelse return error.RootFSDigestCacheMiss;
        if (origin.len == 0) return error.BadManifest;
        // GC and a later fetch both need the index to know the objects.
        const index_path = try rootfs_cas.manifestIndexPath(allocator, cache_root, request.storage.index_digest);
        defer allocator.free(index_path);
        try rootfs_cas.verifyStorageIndexPath(allocator, index_path, request.storage);
        break :origin origin;
    };

    const identity = try identityAlloc(allocator, request.storage.index_digest, config);
    errdefer allocator.free(identity);
    if (request.expected_identity) |expected| {
        if (!std.mem.eql(u8, identity, expected)) return error.ImageIdentityMismatch;
    }
    const resolved_ref = try resolvedRefAlloc(allocator, request.name, identity, request.oci);
    errdefer allocator.free(resolved_ref);

    if (request.flat_path) |flat_path| {
        // Share the digest-addressed inode, so prune sees the flat file as
        // linked and keeps the record.
        const path = try flatPath(allocator, cache_root, identity);
        defer allocator.free(path);
        try chunk_sealer.ensureDirPath(allocator, std.fs.path.dirname(path).?);
        Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
        try Io.Dir.hardLink(Io.Dir.cwd(), flat_path, Io.Dir.cwd(), path, io, .{});
        try chunk_sealer.fsyncParentDirPath(allocator, path);
    }
    const record_path = try recordPath(allocator, cache_root, identity);
    errdefer allocator.free(record_path);
    const local = LocalImage{
        .identity = identity,
        .platform = request.platform,
        .config = config,
        .storage = request.storage,
        .oci = request.oci,
        .origin = origin,
    };
    try writeJsonDurable(allocator, record_path, local);
    if (request.oci) |provenance| {
        try derive(allocator, cache_root, provenance.manifest_digest, request.platform, provenance.builder_version, identity);
        if (request.selected_from) |index_digest| {
            if (!std.mem.eql(u8, index_digest, provenance.manifest_digest)) {
                try derive(allocator, cache_root, index_digest, request.platform, provenance.builder_version, identity);
            }
        }
    }
    const ref_path = if (request.name) |name| try tag(allocator, cache_root, cache_lock, name, local) else null;
    return .{ .identity = identity, .resolved_ref = resolved_ref, .record_path = record_path, .ref_path = ref_path };
}

fn derive(allocator: std.mem.Allocator, cache_root: []const u8, source_digest: []const u8, platform: Platform, builder_version: []const u8, identity: []const u8) !void {
    const path = try derivationPath(allocator, cache_root, source_digest, platform, builder_version);
    defer allocator.free(path);
    try writeJsonDurable(allocator, path, DerivationRecord{
        .source_digest = source_digest,
        .platform = platform,
        .builder_version = builder_version,
        .image = identity,
    });
}

/// `publish` under a cache lock held for just this call.
pub fn lockAndPublish(io: Io, allocator: std.mem.Allocator, cache_root: []const u8, request: PublishRequest) !Published {
    var cache_lock = try rootfs.lockRootfsCacheExclusive(io, allocator, cache_root);
    defer cache_lock.deinit();
    return publish(io, allocator, cache_root, &cache_lock, request);
}

/// Point `name` on the image's platform at `local`. Returns the ref record
/// path.
pub fn tag(
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    cache_lock: *const rootfs.RootfsCacheLock,
    name: []const u8,
    local: LocalImage,
) ![]const u8 {
    if (!try cache_lock.ensureHeldFor(allocator, cache_root)) return error.RootfsCacheLockNotHeld;
    try validateName(name, local.oci);
    try validateIdentity(local.identity);
    const path = try refPath(allocator, cache_root, name, local.platform);
    errdefer allocator.free(path);
    try writeJsonDurable(allocator, path, RefRecord{ .name = name, .platform = local.platform, .image = local.identity });
    return path;
}

/// A name outside `local/` may only point at an image converted from OCI
/// layers, never at a build, commit or unpack. A registry pull may find an
/// image imported from the same manifest, so the source repository is not
/// checked.
fn validateName(name: []const u8, provenance: ?OciProvenance) !void {
    _ = try oci.ImageTag.parse(name);
    if (!rootfs.isLocalImageRef(name) and provenance == null) return error.LocalRefMustUseLocalRegistry;
}

/// The digest-pinned reference a run records for `requested`: local names
/// resolve to `local/<repo>@<identity>`, registry names to their repository
/// at the converted OCI manifest digest. Without a name, the OCI source.
pub fn resolvedRefAlloc(allocator: std.mem.Allocator, requested: ?[]const u8, identity: []const u8, provenance: ?OciProvenance) ![]u8 {
    const name = requested orelse return allocator.dupe(u8, if (provenance) |source| source.ref else identity);
    const end = std.mem.lastIndexOfScalar(u8, name, '@') orelse std.mem.lastIndexOfScalar(u8, name, ':') orelse name.len;
    const repo = name[0..end];
    const digest = if (provenance) |source| if (std.mem.startsWith(u8, repo, "local/")) identity else source.manifest_digest else identity;
    return std.fmt.allocPrint(allocator, "{s}@{s}", .{ repo, digest });
}

pub fn identityAlloc(allocator: std.mem.Allocator, index_digest: []const u8, config: image.Config) ![]u8 {
    const canonical = try image.canonicalConfigJson(allocator, config);
    defer allocator.free(canonical);
    return image.imageDigestAlloc(allocator, index_digest, canonical);
}

pub fn recordPath(allocator: std.mem.Allocator, cache_root: []const u8, identity: []const u8) ![]u8 {
    return identityPath(allocator, cache_root, identity, ".json");
}

pub fn flatPath(allocator: std.mem.Allocator, cache_root: []const u8, identity: []const u8) ![]u8 {
    return identityPath(allocator, cache_root, identity, ".ext4");
}

/// The identity named by a catalog file `images/<hex><extension>`, or null.
pub fn identityFromFileName(allocator: std.mem.Allocator, file_name: []const u8, extension: []const u8) !?[]u8 {
    if (!std.mem.endsWith(u8, file_name, extension)) return null;
    const identity = try std.fmt.allocPrint(allocator, "{s}{s}", .{ image.digest_prefix, file_name[0 .. file_name.len - extension.len] });
    validateIdentity(identity) catch {
        allocator.free(identity);
        return null;
    };
    return identity;
}

fn identityPath(allocator: std.mem.Allocator, cache_root: []const u8, identity: []const u8, extension: []const u8) ![]u8 {
    try validateIdentity(identity);
    const file_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ identity[image.digest_prefix.len..], extension });
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ cache_root, images_dir, file_name });
}

fn derivationPath(allocator: std.mem.Allocator, cache_root: []const u8, source_digest: []const u8, platform: Platform, builder_version: []const u8) ![]u8 {
    if (!oci.isSha256Digest(source_digest)) return error.UnsupportedDigest;
    return keyedPath(allocator, cache_root, &.{ images_dir, derivations_dir }, &.{ derivation_kind, builder_version, platform.os, platform.arch.name(), source_digest });
}

fn refPath(allocator: std.mem.Allocator, cache_root: []const u8, name: []const u8, platform: Platform) ![]u8 {
    return keyedPath(allocator, cache_root, &.{refs_dir}, &.{ ref_kind, platform.os, platform.arch.name(), name });
}

fn keyedPath(allocator: std.mem.Allocator, cache_root: []const u8, dirs: []const []const u8, fields: []const []const u8) ![]u8 {
    var h = Sha256.init(.{});
    for (fields) |field| {
        h.update(field);
        h.update("\n");
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    const file_name = std.fmt.bytesToHex(digest, .lower) ++ ".json".*;
    var parts: [4][]const u8 = undefined;
    parts[0] = cache_root;
    for (dirs, 1..) |dir, i| parts[i] = dir;
    parts[dirs.len + 1] = &file_name;
    return std.fs.path.join(allocator, parts[0 .. dirs.len + 2]);
}

fn validateIdentity(identity: []const u8) !void {
    if (!std.mem.startsWith(u8, identity, image.digest_prefix)) return error.UnsupportedDigest;
    try spore.validateRootfsDigest(identity);
}

fn samePlatform(a: Platform, b: Platform) bool {
    return a.arch == b.arch and std.mem.eql(u8, a.os, b.os);
}

fn readJson(comptime T: type, io: Io, allocator: std.mem.Allocator, path: []const u8) !?T {
    const bytes = try readBounded(io, allocator, path) orelse return null;
    return std.json.parseFromSliceLeaky(T, allocator, bytes, .{ .allocate = .alloc_always }) catch return error.BadManifest;
}

fn readBounded(io: Io, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_record_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.StreamTooLong => return error.BadManifest,
        else => |e| return e,
    };
}

fn writeJsonDurable(allocator: std.mem.Allocator, path: []const u8, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    defer allocator.free(json);
    if (json.len >= max_record_bytes) return error.BadManifest;
    try chunk_sealer.replaceFileAtomicDurable(allocator, path, json, 0o644);
}

const TestCache = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: []const u8,

    fn init() !TestCache {
        var cache: TestCache = .{ .tmp = std.testing.tmpDir(.{}), .arena = .init(std.testing.allocator), .root = undefined };
        cache.root = try cache.tmp.dir.realPathFileAlloc(std.testing.io, ".", cache.arena.allocator());
        return cache;
    }

    fn deinit(self: *TestCache) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn storage(self: *TestCache, seed: u8) !spore.RootfsStorage {
        const allocator = self.arena.allocator();
        const io = std.testing.io;
        const bytes = try allocator.alloc(u8, 8192);
        for (bytes, 0..) |*byte, i| byte.* = seed +% @as(u8, @truncate(i));
        const path = try std.fs.path.join(allocator, &.{ self.root, "rootfs.ext4" });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
        defer Io.Dir.cwd().deleteFile(io, path) catch {};
        const preload = try rootfs_cas.preloadPath(io, allocator, self.root, path, rootfs_cas.default_chunk_size);
        return rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload);
    }
};

test "local image names resolve through refs, identities and derivations across builder versions" {
    const io = std.testing.io;
    var cache = try TestCache.init();
    defer cache.deinit();
    const allocator = cache.arena.allocator();
    const arm64 = Platform{};
    const amd64 = Platform{ .arch = .amd64 };

    const native = try lockAndPublish(io, allocator, cache.root, .{ .platform = arm64, .storage = try cache.storage(1), .name = "local/app:dev" });
    try std.testing.expectEqualStrings(native.identity, (try lookup(io, allocator, cache.root, "local/app:dev", arm64)).?);
    try std.testing.expectEqual(null, try lookup(io, allocator, cache.root, "local/app:dev", amd64));
    const pinned = try std.fmt.allocPrint(allocator, "local/app@{s}", .{native.identity});
    try std.testing.expectEqualStrings(pinned, native.resolved_ref);
    try std.testing.expectEqualStrings(native.identity, (try find(io, allocator, cache.root, pinned, arm64)).?.identity);
    try std.testing.expectError(error.UnsupportedPlatform, find(io, allocator, cache.root, pinned, amd64));

    const manifest = "sha256:" ++ "a" ** 64;
    const index = "sha256:" ++ "b" ** 64;
    const pulled = try lockAndPublish(io, allocator, cache.root, .{
        .platform = arm64,
        .storage = try cache.storage(2),
        .oci = .{ .ref = "registry.example.test/app@" ++ manifest, .manifest_digest = manifest, .builder_version = rootfs.builder_version },
        .selected_from = index,
        .name = "registry.example.test/app:1",
    });
    try std.testing.expectEqualStrings("registry.example.test/app@" ++ manifest, pulled.resolved_ref);
    for ([_][]const u8{ "registry.example.test/app:1", "registry.example.test/app@" ++ manifest, "mirror.example.test/app@" ++ index }) |ref| {
        try std.testing.expectEqualStrings(pulled.identity, (try lookup(io, allocator, cache.root, ref, arm64)).?);
    }
    const local = (try find(io, allocator, cache.root, "mirror.example.test/app@" ++ index, arm64)).?;
    try std.testing.expectEqualStrings("mirror.example.test/app@" ++ manifest, try resolvedRefAlloc(allocator, "mirror.example.test/app@" ++ index, local.identity, local.oci));

    // A name keeps resolving after the builder changes; only the source
    // digest must be converted again.
    const old_manifest = "sha256:" ++ "c" ** 64;
    const old = try lockAndPublish(io, allocator, cache.root, .{
        .platform = arm64,
        .storage = try cache.storage(3),
        .oci = .{ .ref = "registry.example.test/app@" ++ old_manifest, .manifest_digest = old_manifest, .builder_version = "sporevm-rootfs-previous" },
        .name = "registry.example.test/app:old",
    });
    try std.testing.expectEqualStrings(old.identity, (try find(io, allocator, cache.root, "registry.example.test/app:old", arm64)).?.identity);
    try std.testing.expectEqual(null, try lookup(io, allocator, cache.root, "registry.example.test/app@" ++ old_manifest, arm64));

    // Registry names only point at images converted from OCI layers.
    try std.testing.expectError(error.LocalRefMustUseLocalRegistry, lockAndPublish(io, allocator, cache.root, .{
        .platform = arm64,
        .storage = try cache.storage(4),
        .name = "registry.example.test/app:native",
    }));
    var cache_lock = try rootfs.lockRootfsCacheExclusive(io, allocator, cache.root);
    defer cache_lock.deinit();
    const native_image = (try load(io, allocator, cache.root, native.identity)).?;
    try std.testing.expectError(error.LocalRefMustUseLocalRegistry, tag(allocator, cache.root, &cache_lock, "registry.example.test/app:native", native_image));
}

test "a local name's ref does not depend on the rootfs builder" {
    // Refs used to be keyed by the rootfs builder version, so a builder bump
    // orphaned every `local/...` name. This is the ref the current format
    // writes for `local/app:dev` on linux/arm64, named
    // `sha256("spore-image-ref-v1\nlinux\narm64\nlocal/app:dev\n")`; with no
    // builder in its path or record, the name keeps resolving whatever the
    // builder.
    const io = std.testing.io;
    var cache = try TestCache.init();
    defer cache.deinit();
    const allocator = cache.arena.allocator();
    const ref_path = try std.fs.path.join(allocator, &.{ cache.root, refs_dir, "dbe40c92415cf6b6180e7c570afc0b17c0d8e936177fc21041afddf9def8ae63.json" });

    const published = try lockAndPublish(io, allocator, cache.root, .{ .platform = .{}, .storage = try cache.storage(1), .name = "local/app:dev" });
    try std.testing.expectEqualStrings(ref_path, published.ref_path.?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = ref_path, .data = try std.fmt.allocPrint(allocator,
        \\{{"kind":"spore-image-ref-v1","name":"local/app:dev","platform":{{"os":"linux","arch":"arm64"}},"image":"{s}"}}
    , .{published.identity}) });
    try std.testing.expectEqualStrings(published.identity, (try find(io, allocator, cache.root, "local/app:dev", .{})).?.identity);
}

test "only the origin-aware load returns an image with objects missing locally" {
    const io = std.testing.io;
    var cache = try TestCache.init();
    defer cache.deinit();
    const allocator = cache.arena.allocator();
    const store = "https://images.example.test/store";

    // A complete local copy is authoritative and records no origin.
    const storage = try cache.storage(5);
    const published = try lockAndPublish(io, allocator, cache.root, .{ .platform = .{}, .storage = storage, .origin = store, .name = "local/app:dev" });
    try std.testing.expectEqual(null, (try load(io, allocator, cache.root, published.identity)).?.origin);

    const objects = try std.fs.path.join(allocator, &.{ cache.root, "cas", "rootfs", "blake3", "objects" });
    try Io.Dir.cwd().deleteTree(io, objects);
    try rootfs_cas.removeStorageCompleteStamp(io, allocator, cache.root, storage.index_digest);
    try std.testing.expectEqual(null, try load(io, allocator, cache.root, published.identity));
    try std.testing.expectEqual(null, try loadAllowingOrigin(io, allocator, cache.root, published.identity));
    try std.testing.expectError(error.RootFSDigestCacheMiss, lockAndPublish(io, allocator, cache.root, .{ .platform = .{}, .storage = storage }));

    const remote = try lockAndPublish(io, allocator, cache.root, .{ .platform = .{}, .storage = storage, .origin = store });
    try std.testing.expectEqualStrings(published.identity, remote.identity);
    try std.testing.expectEqual(null, try load(io, allocator, cache.root, remote.identity));
    try std.testing.expectEqual(null, try find(io, allocator, cache.root, "local/app:dev", .{}));
    try std.testing.expectEqualStrings(store, (try loadAllowingOrigin(io, allocator, cache.root, remote.identity)).?.origin.?);

    const record = try Io.Dir.cwd().readFileAlloc(io, remote.record_path, allocator, .limited(max_record_bytes));
    const tampered = try std.mem.replaceOwned(u8, allocator, record, "\"os\": \"linux\"", "\"os\": \"freebsd\"");
    try std.testing.expect(!std.mem.eql(u8, record, tampered));
    try chunk_sealer.replaceFileAtomicDurable(allocator, remote.record_path, tampered, 0o644);
    try std.testing.expectError(error.BadManifest, loadAllowingOrigin(io, allocator, cache.root, remote.identity));
}
