//! Static content-addressed image stores.
//!
//! `spore image push` writes one complete local image into a directory that
//! any static file server can publish. `spore run --image <store>/<tag>` (and
//! `create`) reads it lazily: it fetches and verifies the image manifest,
//! config and rootfs index before boot, records the image in the local catalog
//! with the store as its origin, and fetches each rootfs object the first time
//! the guest reads it. Layout under the store base:
//!
//!   objects/blake3/<hex>    rootfs object; its length comes from the index
//!   images/<hex>/manifest   canonical image manifest (image_manifest.zig)
//!   images/<hex>/config     canonical image config
//!   images/<hex>/index      canonical rootfs index
//!   tags/<name>             "blake3:<image hex>\n"
//!
//! A store is a directory, an HTTP(S) URL prefix, or an S3 prefix
//! (`s3://bucket/prefix`), read with SigV4-signed GETs using credentials
//! from the environment and written with the aws CLI.
//!
//! Store bytes are untrusted. A tag only names an image digest; the metadata
//! must recompute that digest, and an object must match the BLAKE3 digest the
//! verified index names before it is cached or reaches the guest.

const std = @import("std");
const Io = std.Io;
const chunk = @import("chunk.zig");
const chunk_sealer = @import("chunk_sealer.zig");
const disk_index = @import("disk_index.zig");
const host_fetch_policy = @import("host_fetch_policy.zig");
const image = @import("image.zig");
const image_archive = @import("image_archive.zig");
const image_manifest = @import("image_manifest.zig");
const local_image = @import("local_image.zig");
const local_paths = @import("local_paths.zig");
const resource = @import("resource.zig");
const rootfs = @import("rootfs.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const s3_sigv4 = @import("s3_sigv4.zig");
const spore = @import("spore.zig");
const test_support = @import("test_support.zig");

const digest_prefix = image.digest_prefix;
const digest_len = digest_prefix.len + chunk.ChunkId.hex_len;
pub const tag_file_len = digest_len + 1;
const max_tag_len = 128;

pub const Scheme = enum { file, http, https, s3 };

/// Where a store lives: an absolute directory (`/srv/images` or
/// `file:///srv/images`), an HTTP(S) URL prefix, or an S3 bucket and key
/// prefix (`s3://bucket/images`). `url` is the base as written, without a
/// trailing slash; `dir` is the directory of a file store; `prefix` is empty
/// or the `/`-led key prefix of an S3 store.
pub const Base = struct {
    scheme: Scheme,
    url: []const u8,
    dir: []const u8 = "",
    loopback: bool = false,
    bucket: []const u8 = "",
    prefix: []const u8 = "",
};

pub const Target = union(enum) {
    tag: []const u8,
    digest: []const u8,
};

/// `<base>/<tag>` or `<base>/blake3:<hex>`. Slices borrow the parsed input.
pub const StoreRef = struct {
    base: Base,
    target: Target,
};

/// Image refs never carry a scheme, so a scheme marks a store ref.
pub fn isStoreRef(raw: []const u8) bool {
    return std.mem.indexOf(u8, raw, "://") != null;
}

pub fn parseStoreRef(raw: []const u8) !StoreRef {
    try validateUrlBytes(raw);
    const slash = std.mem.lastIndexOfScalar(u8, raw, '/') orelse return error.InvalidImageStoreRef;
    const base = try parseBase(raw[0..slash]);
    const name = raw[slash + 1 ..];
    const target: Target = if (std.mem.startsWith(u8, name, digest_prefix)) blk: {
        try validateImageDigest(name);
        break :blk .{ .digest = name };
    } else blk: {
        try validateTag(name);
        break :blk .{ .tag = name };
    };
    // A tag is mutable, so only a digest may cross a network without TLS.
    if (target == .tag and base.scheme == .http and !base.loopback) return error.InsecureImageStoreTag;
    return .{ .base = base, .target = target };
}

pub fn parseBase(raw: []const u8) !Base {
    if (std.mem.startsWith(u8, raw, "/")) return .{ .scheme = .file, .url = raw, .dir = try validateDir(raw) };
    if (std.mem.startsWith(u8, raw, "file://")) return .{ .scheme = .file, .url = raw, .dir = try validateDir(raw["file://".len..]) };
    if (std.mem.startsWith(u8, raw, "s3://")) {
        try validateUrlBytes(raw);
        const rest = raw["s3://".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const bucket = rest[0..slash];
        try validateBucket(bucket);
        const prefix = rest[slash..];
        if (prefix.len != 0) {
            _ = try validateDir(prefix);
            // Unreserved bytes only, so a key's path is its canonical URI.
            for (prefix) |byte| if (!(std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "/-._~", byte) != null)) return error.InvalidImageStoreRef;
        }
        return .{ .scheme = .s3, .url = raw, .bucket = bucket, .prefix = prefix };
    }
    const scheme: Scheme = if (std.mem.startsWith(u8, raw, "https://"))
        .https
    else if (std.mem.startsWith(u8, raw, "http://"))
        .http
    else
        return error.UnsupportedImageStoreScheme;
    try validateUrlBytes(raw);
    const uri = std.Uri.parse(raw) catch return error.InvalidImageStoreRef;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidImageStoreRef;
    var host_buffer: [Io.net.HostName.max_len]u8 = undefined;
    const host = host_fetch_policy.rawHost(uri, &host_buffer) catch return error.InvalidImageStoreRef;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (path.len != 0) _ = try validateDir(path);
    return .{
        .scheme = scheme,
        .url = raw,
        .loopback = std.mem.eql(u8, host.bytes, "127.0.0.1") or std.mem.eql(u8, host.bytes, "::1") or std.mem.eql(u8, host.bytes, "[::1]"),
    };
}

/// A bucket name that is one DNS label of a virtual-hosted S3 endpoint:
/// dots would not match the endpoint's wildcard certificate.
fn validateBucket(bucket: []const u8) !void {
    if (bucket.len < 3 or bucket.len > 63) return error.InvalidImageStoreRef;
    for (bucket, 0..) |byte, index| {
        const edge = index == 0 or index == bucket.len - 1;
        if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or (!edge and byte == '-'))) return error.InvalidImageStoreRef;
    }
}

/// An absolute path of plain segments: no empty, `.` or `..` segments.
fn validateDir(path: []const u8) ![]const u8 {
    if (path.len < 2 or path[0] != '/') return error.InvalidImageStoreRef;
    try validateUrlBytes(path);
    var segments = std.mem.splitScalar(u8, path[1..], '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidImageStoreRef;
    }
    return path;
}

/// Printable ASCII without percent escapes, queries, fragments or backslashes,
/// so a ref names exactly the path it spells.
fn validateUrlBytes(raw: []const u8) !void {
    for (raw) |byte| {
        if (byte <= ' ' or byte >= 0x7f) return error.InvalidImageStoreRef;
        switch (byte) {
            '%', '?', '#', '\\' => return error.InvalidImageStoreRef,
            else => {},
        }
    }
}

fn validateTag(name: []const u8) !void {
    if (name.len == 0 or name.len > max_tag_len) return error.InvalidImageStoreTag;
    for (name, 0..) |byte, index| {
        const valid = std.ascii.isLower(byte) or std.ascii.isDigit(byte) or
            (index != 0 and (byte == '.' or byte == '_' or byte == '-'));
        if (!valid) return error.InvalidImageStoreTag;
    }
}

fn validateImageDigest(digest: []const u8) !void {
    image_manifest.validateDigest(digest, digest_prefix) catch return error.InvalidImageStoreRef;
}

/// Parse a tag file: exactly `blake3:<64 lowercase hex>\n`. Returns the digest.
pub fn parseTag(bytes: []const u8) ![]const u8 {
    if (bytes.len != tag_file_len or bytes[bytes.len - 1] != '\n') return error.BadImageStoreTag;
    const digest = bytes[0..digest_len];
    image_manifest.validateDigest(digest, digest_prefix) catch return error.BadImageStoreTag;
    return digest;
}

/// The digest-pinned ref of `identity` in the store `raw` names.
pub fn resolvedRefAlloc(allocator: std.mem.Allocator, raw: []const u8, identity: []const u8) ![]u8 {
    const ref = try parseStoreRef(raw);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ ref.base.url, identity });
}

pub fn objectPathAlloc(allocator: std.mem.Allocator, digest: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "objects/blake3/{s}", .{digest[digest_prefix.len..]});
}

fn imagePathAlloc(allocator: std.mem.Allocator, identity: []const u8, file: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "images/{s}/{s}", .{ identity[digest_prefix.len..], file });
}

pub const PushOptions = struct {
    source: []const u8,
    destination: []const u8,
    platform: rootfs.Platform,
    /// Uploads to an S3 store.
    aws_executable: []const u8 = "aws",
};

pub const PushResult = struct {
    schema: []const u8 = "spore.image.push.result.v1",
    schema_version: u32 = 1,
    resource_type: resource.Type = .image,
    ref: []const u8,
    image_digest: []const u8,
    objects_total: usize,
    objects_written: usize,
    bytes_written: u64,
};

/// Write the complete local image `source` into a directory or S3 store:
/// objects, then the image's manifest, config and index, then the tag.
/// Objects already present are kept, so pushing again writes nothing and
/// pushing another tag writes only that tag.
pub fn push(init: std.process.Init, allocator: std.mem.Allocator, options: PushOptions) !PushResult {
    try rootfs.validateLocalTagRef(options.source);
    const destination = try parsePushDestination(options.destination);

    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    defer allocator.free(cache_root);
    var cache_lock = try rootfs.lockRootfsCacheExclusive(init.io, allocator, cache_root);
    defer cache_lock.deinit();
    var closure = try image_archive.loadLocalClosure(init.io, allocator, cache_root, options.source, options.platform);
    defer closure.deinit(allocator);
    switch (destination.target) {
        .digest => |digest| if (!std.mem.eql(u8, digest, closure.image_digest)) return error.ImageIdentityMismatch,
        .tag => {},
    }

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const objects = try arena.alloc(PushObject, closure.objects.len);
    for (objects, closure.objects) |*object, descriptor| object.* = .{
        .digest = descriptor.digest,
        .size = descriptor.size,
        .path = try rootfs_cas.manifestObjectPath(arena, cache_root, descriptor.digest),
    };
    const hex = closure.image_digest[digest_prefix.len..];
    const files = [_]PushFile{
        .{ .path = try std.fmt.allocPrint(arena, "{s}/manifest", .{hex}), .bytes = closure.manifest.bytes },
        .{ .path = try std.fmt.allocPrint(arena, "{s}/config", .{hex}), .bytes = closure.config_bytes },
        .{ .path = try std.fmt.allocPrint(arena, "{s}/index", .{hex}), .bytes = closure.index_bytes },
    };
    const written = try pushClosure(init.io, allocator, options.aws_executable, destination, cache_root, &cache_lock, .{
        .digest = closure.image_digest,
        .objects = objects,
        .files_dir = "images",
        .files = &files,
        .tags_dir = "tags",
    });
    const ref = try pushedRefAlloc(allocator, destination.base, switch (destination.target) {
        .tag => |name| name,
        .digest => |digest| digest,
    });
    errdefer allocator.free(ref);
    return .{
        .ref = ref,
        .image_digest = try allocator.dupe(u8, closure.image_digest),
        .objects_total = closure.objects.len,
        .objects_written = written.objects,
        .bytes_written = written.bytes,
    };
}

/// A push destination: a directory or S3 store ref.
pub fn parsePushDestination(raw: []const u8) !StoreRef {
    const destination = try parseStoreRef(raw);
    if (destination.base.scheme == .http or destination.base.scheme == .https) return error.ImageStorePushUnsupportedScheme;
    return destination;
}

/// `name` in the store `base`, in the `file://` form for a directory store,
/// which `spore run --image` takes as a store ref.
pub fn pushedRefAlloc(allocator: std.mem.Allocator, base: Base, name: []const u8) ![]u8 {
    if (base.scheme == .file) return std.fmt.allocPrint(allocator, "file://{s}/{s}", .{ base.dir, name });
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base.url, name });
}

/// One object a push writes, read from `path` and verified against its
/// digest and size first.
pub const PushObject = struct {
    digest: []const u8,
    size: usize,
    path: []const u8,
};

/// One file a push writes after its objects, at `path` under the closure's
/// `files_dir`.
pub const PushFile = struct {
    path: []const u8,
    bytes: []const u8,
};

/// What one push writes, in order: objects, then files named by `digest`,
/// then a tag naming `digest` if the destination is a tag. A reader that
/// finds the tag finds everything it names.
pub const PushClosure = struct {
    digest: []const u8,
    objects: []const PushObject,
    /// `images` or `spores`.
    files_dir: []const u8,
    files: []const PushFile,
    /// `tags` or `spore-tags`.
    tags_dir: []const u8,
};

pub const PushWritten = struct {
    objects: usize = 0,
    bytes: u64 = 0,
};

/// Write `closure` into a directory or S3 store. Objects the store already
/// has intact are kept, so pushing again writes nothing. The caller holds
/// `cache_lock` exclusively; an S3 push releases it once its objects are
/// staged.
pub fn pushClosure(
    io: Io,
    allocator: std.mem.Allocator,
    aws: []const u8,
    destination: StoreRef,
    cache_root: []const u8,
    cache_lock: *rootfs.RootfsCacheLock,
    closure: PushClosure,
) !PushWritten {
    if (destination.base.scheme == .s3) return pushS3(io, allocator, aws, destination, cache_root, cache_lock, closure);

    const dir = destination.base.dir;
    const objects_dir = try std.fs.path.join(allocator, &.{ dir, "objects", "blake3" });
    defer allocator.free(objects_dir);
    try chunk_sealer.ensureDirPath(allocator, objects_dir);
    var written: PushWritten = .{};
    var work_stats: chunk_sealer.WorkStats = .{};
    for (closure.objects) |object| {
        const path = try std.fs.path.join(allocator, &.{ objects_dir, object.digest[digest_prefix.len..] });
        defer allocator.free(path);
        if (rootfs_cas.readVerifiedChunkPath(allocator, path, object.digest, object.size)) |existing| {
            allocator.free(existing);
            continue;
        } else |err| switch (err) {
            error.MissingChunk => {},
            // Replace a damaged object rather than keep serving it.
            error.BadChunk, error.ShortRead => try Io.Dir.cwd().deleteFile(io, path),
            else => |e| return e,
        }
        const bytes = try rootfs_cas.readVerifiedChunkPath(allocator, object.path, object.digest, object.size);
        defer allocator.free(bytes);
        _ = try chunk_sealer.writePathAllIfMissingTimedForBatch(allocator, path, bytes, &work_stats);
        written.objects += 1;
        written.bytes += object.size;
    }
    if (written.objects != 0) try chunk_sealer.fsyncDirPath(allocator, objects_dir);

    for (closure.files) |file| {
        const path = try std.fs.path.join(allocator, &.{ dir, closure.files_dir, file.path });
        defer allocator.free(path);
        chunk_sealer.writeFileAtomicDurable(allocator, path, file.bytes, 0o444) catch |err| switch (err) {
            // Files are named by the pushed digest; different bytes mean a
            // damaged store file, so replace it.
            error.BadChunk => try chunk_sealer.replaceFileAtomicDurable(allocator, path, file.bytes, 0o444),
            else => |e| return e,
        };
    }
    switch (destination.target) {
        .tag => |name| {
            const path = try std.fs.path.join(allocator, &.{ dir, closure.tags_dir, name });
            defer allocator.free(path);
            const tag_bytes = try std.fmt.allocPrint(allocator, "{s}\n", .{closure.digest});
            defer allocator.free(tag_bytes);
            try chunk_sealer.replaceFileAtomicDurable(allocator, path, tag_bytes, 0o644);
        },
        .digest => {},
    }
    return written;
}

/// Stage the closure as a directory store under the cache's `tmp` directory,
/// with its objects hardlinked and verified, then upload it with the aws
/// CLI: objects, then the files, then the tag. The links keep the objects,
/// so the upload does not hold the cache lock. `--size-only` skips objects
/// the store already has: an object's key is its digest, so its size only
/// differs when the store copy is damaged.
fn pushS3(
    io: Io,
    allocator: std.mem.Allocator,
    aws: []const u8,
    destination: StoreRef,
    cache_root: []const u8,
    cache_lock: *rootfs.RootfsCacheLock,
    closure: PushClosure,
) !PushWritten {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const stage = try std.fmt.allocPrint(arena, "{s}/tmp/store-push-{x}", .{ cache_root, std.mem.readInt(u64, &nonce, .little) });
    defer Io.Dir.cwd().deleteTree(io, stage) catch {};
    const objects_dir = try std.fs.path.join(arena, &.{ stage, "objects", "blake3" });
    try Io.Dir.cwd().createDirPath(io, objects_dir);

    var uploads: Uploads = .{};
    // Linked objects, verified once the lock is released: a link pins the
    // inode, so GC cannot change what it holds.
    var linked: std.ArrayList(PushObject) = .empty;
    for (closure.objects) |object| {
        const hex = object.digest[digest_prefix.len..];
        const staged = try std.fs.path.join(arena, &.{ objects_dir, hex });
        if (Io.Dir.cwd().hardLink(object.path, Io.Dir.cwd(), staged, io, .{})) {
            try linked.append(arena, .{ .digest = object.digest, .size = object.size, .path = staged });
        } else |_| {
            const bytes = try rootfs_cas.readVerifiedChunkPath(allocator, object.path, object.digest, object.size);
            defer allocator.free(bytes);
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = staged, .data = bytes });
        }
        try uploads.sizes.put(arena, hex, object.size);
    }
    for (closure.files) |file| {
        const path = try std.fs.path.join(arena, &.{ stage, closure.files_dir, file.path });
        try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = file.bytes });
    }
    cache_lock.deinit();
    for (linked.items) |object| allocator.free(try rootfs_cas.readVerifiedChunkPath(allocator, object.path, object.digest, object.size));

    const base = destination.base.url;
    try runAws(io, arena, aws, &.{ "s3", "sync", "--size-only", "--no-progress", try std.fs.path.join(arena, &.{ stage, "objects" }), try std.fmt.allocPrint(arena, "{s}/objects", .{base}) }, &uploads);
    try runAws(io, arena, aws, &.{ "s3", "sync", "--size-only", "--only-show-errors", try std.fs.path.join(arena, &.{ stage, closure.files_dir }), try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, closure.files_dir }) }, null);
    switch (destination.target) {
        .tag => |name| {
            const path = try std.fs.path.join(arena, &.{ stage, "tag" });
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try std.fmt.allocPrint(arena, "{s}\n", .{closure.digest}) });
            try runAws(io, arena, aws, &.{ "s3", "cp", "--only-show-errors", path, try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ base, closure.tags_dir, name }) }, null);
        },
        .digest => {},
    }
    return .{ .objects = uploads.count, .bytes = uploads.bytes };
}

/// Counts the objects `aws s3 sync` uploads from the lines it prints:
/// `upload: <local path> to s3://<bucket>/<prefix>/objects/blake3/<hex>`.
const Uploads = struct {
    /// Object sizes by digest hex.
    sizes: std.StringHashMapUnmanaged(u64) = .empty,
    count: usize = 0,
    bytes: u64 = 0,

    fn line(self: *Uploads, text: []const u8) void {
        if (!std.mem.startsWith(u8, text, "upload: ")) return;
        const key = std.mem.trimEnd(u8, text, "\r");
        const size = self.sizes.get(key[(std.mem.lastIndexOfScalar(u8, key, '/') orelse return) + 1 ..]) orelse return;
        self.count += 1;
        self.bytes += size;
    }
};

/// Run `aws ARGS...` and fail unless it exits 0. Its errors go to stderr;
/// `uploads` counts the uploads it reports on stdout.
fn runAws(io: Io, allocator: std.mem.Allocator, aws: []const u8, args: []const []const u8, uploads: ?*Uploads) !void {
    const argv = try std.mem.concat(allocator, []const u8, &.{ &.{aws}, args });
    defer allocator.free(argv);
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .inherit }) catch return error.AwsCliUnavailable;
    defer child.kill(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buffer);
    while (reader.interface.takeDelimiter('\n') catch return error.ImageStorePushFailed) |text| {
        if (uploads) |counter| counter.line(text);
    }
    switch (try child.wait(io)) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.ImageStorePushFailed;
}

pub fn deinitPushResult(allocator: std.mem.Allocator, result: PushResult) void {
    allocator.free(result.ref);
    allocator.free(result.image_digest);
}

/// Resolve the store ref `raw` to a local image for `platform`, fetching and
/// verifying its manifest, config and index if this cache has none, and
/// recording the store as the origin of objects still missing locally. A tag
/// is read from the store every time; a digest is not when the image is local.
/// An S3 store takes its credentials from `env`. Allocates into `allocator`;
/// use an arena.
pub fn resolve(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    raw: []const u8,
    platform: rootfs.Platform,
    env: *const std.process.Environ.Map,
) !local_image.LocalImage {
    const ref = try parseStoreRef(raw);
    var client = try Client.init(allocator, io, ref.base.url, env);
    defer client.deinit();
    const identity = switch (ref.target) {
        .digest => |digest| digest,
        .tag => |name| blk: {
            const path = try std.fmt.allocPrint(allocator, "tags/{s}", .{name});
            const bytes = try client.get(allocator, path, .{ .max = tag_file_len }, metadata_budget);
            break :blk try parseTag(bytes);
        },
    };

    try Io.Dir.cwd().createDirPath(io, cache_root);
    if (try local_image.loadAllowingOrigin(io, allocator, cache_root, identity)) |local| {
        if (local.platform.arch != platform.arch or !std.mem.eql(u8, local.platform.os, platform.os)) return error.UnsupportedPlatform;
        if (local.origin == null or std.mem.eql(u8, local.origin.?, ref.base.url)) return local;
        // Fetch missing objects from the store this run names.
        _ = try local_image.lockAndPublish(io, allocator, cache_root, .{
            .platform = local.platform,
            .config = local.config,
            .storage = local.storage,
            .oci = local.oci,
            .origin = ref.base.url,
        });
        return (try local_image.loadAllowingOrigin(io, allocator, cache_root, identity)) orelse error.RootFSDigestCacheMiss;
    }

    const manifest_path = try imagePathAlloc(allocator, identity, "manifest");
    const manifest_bytes = try client.get(allocator, manifest_path, .{ .max = image_manifest.max_image_manifest_bytes }, metadata_budget);
    const summary = try image_manifest.parseImageManifest(allocator, manifest_bytes);
    if (summary.value.image.platform.arch != platform.arch or !std.mem.eql(u8, summary.value.image.platform.os, platform.os)) return error.UnsupportedPlatform;
    const config_path = try imagePathAlloc(allocator, identity, "config");
    const config_bytes = try client.get(allocator, config_path, .{ .max = image_manifest.max_config_blob_bytes }, metadata_budget);
    const index_path = try imagePathAlloc(allocator, identity, "index");
    const index_bytes = try client.get(allocator, index_path, .{ .max = disk_index.max_index_bytes }, metadata_budget);

    // The image digest binds the index and config; the manifest summary must
    // match both, so its own transport digest needs no outside pin.
    const manifest_digest = try image_manifest.transportDigestAlloc(allocator, manifest_bytes);
    const verified = try image_manifest.verifyImageManifest(allocator, manifest_digest, platform, manifest_bytes, config_bytes, index_bytes);
    if (!std.mem.eql(u8, verified.value.image.digest, identity)) return error.BadProtocol;
    const config = try image_manifest.parseCanonicalConfig(allocator, config_bytes);
    const storage = verified.value.image.rootfs_storage;

    var cache_lock = try rootfs.lockRootfsCacheExclusive(io, allocator, cache_root);
    defer cache_lock.deinit();
    const installed_index = try rootfs_cas.manifestIndexPath(allocator, cache_root, storage.index_digest);
    _ = try rootfs_cas.installStorageIndexPath(allocator, io, installed_index, index_bytes, storage);
    _ = try local_image.publish(io, allocator, cache_root, &cache_lock, .{
        .platform = platform,
        .config = config.value,
        .storage = storage,
        .origin = ref.base.url,
        .expected_identity = identity,
    });
    return (try local_image.loadAllowingOrigin(io, allocator, cache_root, identity)) orelse error.RootFSDigestCacheMiss;
}

/// Retry policy for one store read: at most `attempts` tries, each bounded by
/// `attempt_ms`, all within `total_ms`.
pub const Budget = struct {
    attempts: u32,
    attempt_ms: u64,
    total_ms: u64,
};

/// Image metadata is read before boot, where only the caller waits.
pub const metadata_budget = Budget{ .attempts = 3, .attempt_ms = 60_000, .total_ms = 120_000 };
/// A guest disk read waits for an object, and on x86_64 so does the vCPU
/// that issued it. Stay well under the guest's 20 s soft-lockup watchdog; a
/// failed read poisons the disk, which then fetches nothing more.
pub const object_budget = Budget{ .attempts = 3, .attempt_ms = 5_000, .total_ms = 10_000 };

pub const Limit = struct {
    max: usize,
    /// The body must be exactly `max` bytes.
    exact: bool = false,
};

pub const GetError = error{
    /// The store has no such file (HTTP 404). Permanent.
    ImageStoreNotFound,
    /// The store refused the request (any other 4xx or a redirect). Permanent.
    ImageStoreRejected,
    /// The body is longer than allowed, a different length than expected, or
    /// encoded. Permanent.
    ImageStoreBadResponse,
    /// The store did not answer (connection or read failure, 429, 5xx) after
    /// every attempt.
    ImageStoreUnavailable,
    /// The budget ran out.
    ImageStoreTimeout,
    /// The task making the request was canceled. Not retried.
    Canceled,
    OutOfMemory,
};

/// Reads files from one store. Requests are bounded by size and time; an
/// HTTP(S) or S3 request runs on an `Io` worker that is canceled at its
/// deadline. Thread-safe: concurrent requests share the connection pool.
pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    base: Base,
    http: std.http.Client,
    /// Signs requests to an S3 store.
    s3: ?S3 = null,

    /// Where an S3 store's requests go, and what signs them. Owns copies of
    /// the credentials, which only the signature and the session token
    /// header carry: no URL, log line or error holds them.
    const S3 = struct {
        /// Owns every slice here.
        arena: std.heap.ArenaAllocator,
        credentials: s3_sigv4.Credentials,
        region: []const u8,
        /// `https://<bucket>.s3.<region>.amazonaws.com`, without a path.
        endpoint: []const u8,
        /// The signed Host header: the endpoint's authority.
        host: []const u8,

        fn init(allocator: std.mem.Allocator, base: Base, env: *const std.process.Environ.Map, endpoint_override: ?[]const u8) !S3 {
            // Reads go only to AWS, so an endpoint meant for an S3-compatible
            // store must not be ignored silently.
            for ([_][]const u8{ "AWS_ENDPOINT_URL", "AWS_ENDPOINT_URL_S3" }) |name| {
                const value: []const u8 = env.get(name) orelse "";
                if (value.len != 0) return error.AwsEndpointUrlUnsupported;
            }
            const credentials = try s3_sigv4.Credentials.fromEnv(env);
            const region = try s3_sigv4.regionFromEnv(env);
            var arena: std.heap.ArenaAllocator = .init(allocator);
            errdefer arena.deinit();
            const a = arena.allocator();
            const endpoint = if (endpoint_override) |value|
                try a.dupe(u8, value)
            else
                try std.fmt.allocPrint(a, "https://{s}.s3.{s}.amazonaws.com", .{ base.bucket, region });
            const authority = std.mem.indexOf(u8, endpoint, "://") orelse return error.InvalidImageStoreRef;
            return .{
                .credentials = .{
                    .access_key_id = try a.dupe(u8, credentials.access_key_id),
                    .secret_access_key = try a.dupe(u8, credentials.secret_access_key),
                    .session_token = if (credentials.session_token) |token| try a.dupe(u8, token) else null,
                },
                .region = try a.dupe(u8, region),
                .endpoint = endpoint,
                .host = endpoint[authority + 3 ..],
                .arena = arena,
            };
        }

        fn deinit(self: *S3) void {
            std.crypto.secureZero(u8, @constCast(self.credentials.secret_access_key));
            self.arena.deinit();
        }
    };

    /// `allocator` must be thread-safe: requests run on `Io` workers. An S3
    /// store reads its credentials and region from `env` now.
    pub fn init(allocator: std.mem.Allocator, io: Io, base_url: []const u8, env: *const std.process.Environ.Map) !Client {
        return initWithEndpoint(allocator, io, base_url, env, null);
    }

    /// `init`, but an S3 store's requests go to `s3_endpoint`, a test stub.
    fn initWithEndpoint(allocator: std.mem.Allocator, io: Io, base_url: []const u8, env: *const std.process.Environ.Map, s3_endpoint: ?[]const u8) !Client {
        const url = try allocator.dupe(u8, base_url);
        errdefer allocator.free(url);
        const base = try parseBase(url);
        var s3: ?S3 = if (base.scheme == .s3) try S3.init(allocator, base, env, s3_endpoint) else null;
        errdefer if (s3) |*value| value.deinit();
        var client: Client = .{ .allocator = allocator, .io = io, .base = base, .http = .{ .allocator = allocator, .io = io }, .s3 = s3 };
        errdefer client.http.deinit();
        if (client.tls()) {
            // Load CA certificates now rather than on a guest fault.
            const now = Io.Clock.real.now(io);
            client.http.ca_bundle.rescan(allocator, io, now) catch return error.CertificateBundleLoadFailure;
            client.http.now = now;
        }
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
        if (self.s3) |*s3| s3.deinit();
        self.allocator.free(self.base.url);
    }

    fn tls(self: *const Client) bool {
        if (self.s3) |s3| return std.mem.startsWith(u8, s3.endpoint, "https://");
        return self.base.scheme == .https;
    }

    /// GET `<base>/<path>`, retrying transient failures within `budget`.
    pub fn get(self: *Client, allocator: std.mem.Allocator, path: []const u8, limit: Limit, budget: Budget) GetError![]u8 {
        const start_ms = monotonicMs();
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            const remaining_ms = budget.total_ms -| (monotonicMs() -| start_ms);
            if (remaining_ms == 0) return error.ImageStoreTimeout;
            if (self.getOnce(allocator, path, limit, @min(budget.attempt_ms, remaining_ms))) |bytes| {
                return bytes;
            } else |err| switch (err) {
                error.ImageStoreUnavailable, error.ImageStoreTimeout => {
                    std.log.debug("image store GET {s}/{s} attempt {d} failed: {s}", .{ self.base.url, path, attempt, @errorName(err) });
                    if (attempt >= budget.attempts) return err;
                    const backoff_ms: u64 = 100 * @as(u64, attempt);
                    if (monotonicMs() -| start_ms + backoff_ms >= budget.total_ms) return err;
                    try self.io.sleep(.fromMilliseconds(@intCast(backoff_ms)), .awake);
                },
                else => return err,
            }
        }
    }

    fn getOnce(self: *Client, allocator: std.mem.Allocator, path: []const u8, limit: Limit, timeout_ms: u64) GetError![]u8 {
        if (self.base.scheme == .file) return self.readFile(allocator, path, limit);
        const url = if (self.s3) |s3|
            try std.fmt.allocPrint(allocator, "{s}{s}/{s}", .{ s3.endpoint, self.base.prefix, path })
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.base.url, path });
        defer allocator.free(url);

        const Attempt = struct {
            client: *Client,
            allocator: std.mem.Allocator,
            url: []const u8,
            limit: Limit,
            done: Io.Event = .unset,
            result: GetError![]u8 = error.ImageStoreTimeout,

            fn run(attempt: *@This()) Io.Cancelable!void {
                defer attempt.done.set(attempt.client.io);
                const bytes = attempt.client.httpGet(attempt.allocator, attempt.url, attempt.limit) catch |err| {
                    const any: anyerror = err;
                    attempt.result = switch (any) {
                        error.Canceled => return error.Canceled,
                        error.ImageStoreNotFound => error.ImageStoreNotFound,
                        error.ImageStoreRejected => error.ImageStoreRejected,
                        error.ImageStoreBadResponse => error.ImageStoreBadResponse,
                        error.OutOfMemory => error.OutOfMemory,
                        else => blk: {
                            std.log.debug("image store GET {s} failed: {s}", .{ attempt.url, @errorName(any) });
                            break :blk error.ImageStoreUnavailable;
                        },
                    };
                    return;
                };
                attempt.result = bytes;
            }
        };
        var attempt = Attempt{ .client = self, .allocator = allocator, .url = url, .limit = limit };
        const io = self.io;
        var future = io.concurrent(Attempt.run, .{&attempt}) catch return error.ImageStoreUnavailable;
        const deadline = Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(@intCast(timeout_ms)), .clock = .awake });
        var timed_out = false;
        var canceled = false;
        while (!attempt.done.isSet()) {
            attempt.done.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
                error.Timeout => if (Io.Clock.awake.now(io).nanoseconds >= deadline.raw.nanoseconds) {
                    timed_out = true;
                    break;
                },
                error.Canceled => {
                    canceled = true;
                    break;
                },
            };
        }
        // Canceling interrupts a blocked socket call; the request then
        // closes its connection instead of returning it to the pool.
        future.cancel(io) catch {};
        if (canceled) {
            // The caller is going away, so the request ends here.
            if (attempt.result) |bytes| allocator.free(bytes) else |_| {}
            return error.Canceled;
        }
        if (timed_out) {
            const bytes = attempt.result catch return error.ImageStoreTimeout;
            return bytes;
        }
        return attempt.result;
    }

    fn httpGet(self: *Client, allocator: std.mem.Allocator, url: []const u8, limit: Limit) ![]u8 {
        const uri = try std.Uri.parse(url);
        // Certificate validity is checked against `now`, which init set when
        // it loaded the CA bundle; a long run must not keep that time. The
        // HTTP client updates `now` under this lock too.
        if (self.tls()) {
            self.http.ca_bundle_lock.lockUncancelable(self.io);
            defer self.http.ca_bundle_lock.unlock(self.io);
            self.http.now = Io.Clock.real.now(self.io);
        }
        var headers: std.http.Client.Request.Headers = .{ .accept_encoding = .omit };
        var amz_headers: [3]std.http.Header = undefined;
        var extra_headers: []const std.http.Header = &.{};
        var signed: s3_sigv4.SignedGet = undefined;
        if (self.s3) |s3| {
            const path = switch (uri.path) {
                .raw, .percent_encoded => |value| value,
            };
            const now = Io.Clock.real.now(self.io).toSeconds();
            signed = try s3_sigv4.signGet(s3.credentials, s3.region, s3.host, path, @intCast(now));
            var signed_buf: [4]s3_sigv4.Header = undefined;
            // Host goes first; the client writes it from `headers.host`.
            const signed_headers = signed.headers(&signed_buf)[1..];
            for (signed_headers, 0..) |header, index| amz_headers[index] = .{ .name = header.name, .value = header.value };
            extra_headers = amz_headers[0..signed_headers.len];
            headers.host = .{ .override = s3.host };
            headers.authorization = .{ .override = signed.authorization() };
        }
        // The user named the store, so loopback and private addresses are
        // fine. Connecting to the resolved address keeps IPv6-literal hosts
        // such as `[::1]` working; `std.http.Client.request` rejects them.
        const addresses = try host_fetch_policy.resolveUriAddresses(self.io, uri, .{ .allow_private = true });
        var request: std.http.Client.Request = undefined;
        var no_redirects: [0]u8 = undefined;
        var response = try host_fetch_policy.getHead(&self.http, uri, addresses.slice(), .{
            .redirect_behavior = .unhandled,
            .headers = headers,
            .extra_headers = extra_headers,
        }, &request, &no_redirects);
        defer request.deinit();
        switch (response.head.status) {
            .ok => {},
            .not_found => return error.ImageStoreNotFound,
            .too_many_requests => return error.ImageStoreUnavailable,
            else => |status| return if (status.class() == .server_error) error.ImageStoreUnavailable else error.ImageStoreRejected,
        }
        if (response.head.content_encoding != .identity) return error.ImageStoreBadResponse;
        if (response.head.content_length) |length| {
            if (length > limit.max or (limit.exact and length != limit.max)) return error.ImageStoreBadResponse;
        }
        var transfer_buffer: [64 * 1024]u8 = undefined;
        const body = response.reader(&transfer_buffer);
        var out: Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        var scratch: [64 * 1024]u8 = undefined;
        while (true) {
            const n = body.readSliceShort(&scratch) catch |err| switch (err) {
                error.ReadFailed => return response.bodyErr() orelse err,
            };
            if (n == 0) break;
            if (out.written().len + n > limit.max) return error.ImageStoreBadResponse;
            try out.writer.writeAll(scratch[0..n]);
        }
        if (limit.exact and out.written().len != limit.max) return error.ImageStoreBadResponse;
        return out.toOwnedSlice();
    }

    /// Reads a regular file of a directory store. A file store has no
    /// deadline: opening never waits for a FIFO writer, but a hung mount can
    /// still block the read.
    fn readFile(self: *Client, allocator: std.mem.Allocator, path: []const u8, limit: Limit) GetError![]u8 {
        const full_path = try std.fs.path.joinZ(allocator, &.{ self.base.dir, path });
        defer allocator.free(full_path);
        const fd = std.c.open(full_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true }, @as(c_uint, 0));
        if (fd < 0) return switch (std.c.errno(fd)) {
            .NOENT, .NOTDIR => error.ImageStoreNotFound,
            .NOMEM => error.OutOfMemory,
            else => error.ImageStoreUnavailable,
        };
        // O_NONBLOCK does not change reads of a regular file.
        const file = Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
        defer file.close(self.io);
        const stat = file.stat(self.io) catch return error.ImageStoreUnavailable;
        if (stat.kind != .file) return error.ImageStoreBadResponse;
        if (stat.size > limit.max or (limit.exact and stat.size != limit.max)) return error.ImageStoreBadResponse;
        const bytes = try allocator.alloc(u8, @intCast(stat.size));
        errdefer allocator.free(bytes);
        const read = file.readPositionalAll(self.io, bytes, 0) catch return error.ImageStoreUnavailable;
        if (read != bytes.len) return error.ImageStoreBadResponse;
        return bytes;
    }
};

pub const FetchStats = struct {
    fetches: u64 = 0,
    bytes: u64 = 0,
    fetch_ns: u64 = 0,
    errors: u64 = 0,
    install_errors: u64 = 0,
    /// Objects fault windows fetched.
    window_fetches: u64 = 0,
    /// Objects fault windows fetched that no guest read has used yet.
    window_unused: u64 = 0,
};

/// Store reads at once while `Fetcher.fetchAll` fills the cache.
pub const fill_concurrency = 16;

/// A fault on chunk `i` also starts fetches of the missing chunks in
/// `[i + 1, i + window_chunks)`, and at most `window_chunks - 1` such fetches
/// run at once.
pub const window_chunks = 8;

pub const Object = struct {
    digest: chunk.ChunkId.Digest,
    len: usize,
};

/// Fetches the rootfs objects of one leased storage that are missing from the
/// local CAS and installs them there. Installs skip the rootfs cache lock: the
/// runtime lease, taken with the cache lock held after the index was
/// installed, already roots every object the index names.
///
/// Thread-safe. Reference-counted, because a named monitor's control handler
/// thread can still be filling the cache when the run loop closes the disk.
pub const Fetcher = struct {
    allocator: std.mem.Allocator,
    io: Io,
    /// Owns `cache_root` and `storage`.
    arena: std.heap.ArenaAllocator,
    cache_root: []const u8,
    storage: spore.RootfsStorage,
    client: Client,
    refs: std.atomic.Value(u32) = .init(1),
    /// Guards `stats`.
    mutex: Io.Mutex = .init,
    stats: FetchStats = .{},
    /// Serializes `fetchAll`.
    fill_mutex: Io.Mutex = .init,
    /// Every object of `storage` is local.
    complete: std.atomic.Value(bool) = .init(false),
    /// A guest read could not fetch its object, which poisoned the disk.
    read_failed: std.atomic.Value(bool) = .init(false),
    /// `fetchAll` stops and fails; set when the VM is stopping.
    canceled: std.atomic.Value(bool) = .init(false),
    /// Objects being fetched, so that concurrent requesters share one GET.
    /// Guarded by `mutex`.
    in_flight: std.AutoHashMapUnmanaged(chunk.ChunkId, *InFlight) = .empty,
    /// Objects fault windows fetched that no guest read has used yet.
    /// Guarded by `mutex`.
    window_unread: std.AutoHashMapUnmanaged(chunk.ChunkId, void) = .empty,
    /// A window fetch failed, so faults fetch only what the guest reads.
    window_failed: std.atomic.Value(bool) = .init(false),
    /// Window fetches, which outlive the fault that started them. Faults
    /// add to it one at a time: one thread serves each disk's reads.
    windows: Io.Group = .init,
    /// Window fetches still running.
    windows_running: std.atomic.Value(u32) = .init(0),

    const InFlight = struct {
        done: Io.Event = .unset,
        /// Why the shared request failed; waiters fail with it too.
        err: ?anyerror = null,
        /// The object is in the cache. A shared request that fetched it but
        /// could not install it leaves each waiter to fetch it itself.
        installed: bool = false,
        /// The fetching requester and its waiters; the last one frees it.
        refs: u32 = 1,
    };

    const Purpose = enum { read, window, fill };

    /// `allocator` must be thread-safe: faults run on disk worker or vCPU
    /// threads and requests on `Io` workers. An S3 store takes its credentials from `env`
    /// now and keeps them for the Fetcher's life.
    pub fn create(allocator: std.mem.Allocator, io: Io, cache_root: []const u8, origin: []const u8, storage: spore.RootfsStorage, env: *const std.process.Environ.Map) !*Fetcher {
        const self = try allocator.create(Fetcher);
        errdefer allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned_root = try arena.allocator().dupe(u8, cache_root);
        const owned_storage = try spore.cloneRootfsStorage(arena.allocator(), storage);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .arena = arena,
            .cache_root = owned_root,
            .storage = owned_storage,
            .client = try Client.init(allocator, io, origin, env),
        };
        return self;
    }

    pub fn retain(self: *Fetcher) *Fetcher {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn release(self: *Fetcher) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        // The disk is closed, so its window fetches are of no further use.
        self.windows.cancel(self.io);
        const stats = self.stats;
        std.log.debug("image store {s}: fetched {d} objects, {d} bytes in {d} ms; {d} errors, {d} install errors", .{
            self.client.base.url, stats.fetches, stats.bytes, stats.fetch_ns / std.time.ns_per_ms, stats.errors, stats.install_errors,
        });
        self.in_flight.deinit(self.allocator);
        self.window_unread.deinit(self.allocator);
        self.client.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn currentStats(self: *Fetcher) FetchStats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stats = self.stats;
        stats.window_unused = self.window_unread.count();
        return stats;
    }

    /// Fill `buf` with the object `digest` names for a guest read, verified
    /// against its BLAKE3 digest; its length is `buf.len`. The caller has found
    /// it missing locally. Fetches of the objects of `window`, which the guest
    /// is likely to read next, start too and finish into the cache after this
    /// returns; a failure there only stops later windows. A failed local
    /// install of the read object is counted, not returned: the bytes are
    /// already verified.
    pub fn fetchObject(self: *Fetcher, digest: []const u8, buf: []u8, window: []const Object) !void {
        if (!self.window_failed.load(.acquire)) {
            for (window) |object| {
                if (self.windows_running.fetchAdd(1, .monotonic) >= window_chunks - 1) {
                    _ = self.windows_running.fetchSub(1, .monotonic);
                    break;
                }
                self.windows.concurrent(self.io, prefetch, .{ self, object }) catch {
                    _ = self.windows_running.fetchSub(1, .monotonic);
                    break;
                };
            }
        }
        errdefer self.read_failed.store(true, .release);
        var object = Object{ .digest = undefined, .len = buf.len };
        if (digest.len != object.digest.len) return error.BadChunk;
        @memcpy(&object.digest, digest);
        if (try self.fetchOnce(object, .read)) |bytes| {
            defer self.allocator.free(bytes);
            @memcpy(buf, bytes);
            return;
        }
        // Another requester installed it.
        const bytes = try rootfs_cas.readVerifiedManifestObject(self.allocator, self.cache_root, digest, buf.len);
        defer self.allocator.free(bytes);
        @memcpy(buf, bytes);
        self.noteRead(digest);
    }

    /// A guest read used the local object `digest`.
    pub fn noteRead(self: *Fetcher, digest: []const u8) void {
        const id = chunk.ChunkId.fromHex(digest[digest_prefix.len..]) catch return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        _ = self.window_unread.remove(id);
    }

    fn prefetch(self: *Fetcher, object: Object) Io.Cancelable!void {
        defer _ = self.windows_running.fetchSub(1, .monotonic);
        if (self.fetchOnce(object, .window)) |_| {} else |_| self.window_failed.store(true, .release);
    }

    /// Fetch, verify and install `object` unless it is local, or wait while
    /// another requester does, so concurrent requesters issue one GET per
    /// object. Returns the bytes when this call fetched them for a guest
    /// read, else null once the object is installed.
    fn fetchOnce(self: *Fetcher, object: Object, purpose: Purpose) !?[]u8 {
        const id = chunk.ChunkId.fromDigest(&object.digest) catch return error.BadChunk;
        self.mutex.lockUncancelable(self.io);
        while (self.in_flight.get(id)) |entry| {
            entry.refs += 1;
            self.mutex.unlock(self.io);
            entry.done.waitUncancelable(self.io);
            self.mutex.lockUncancelable(self.io);
            const err = entry.err;
            const installed = entry.installed;
            entry.refs -= 1;
            if (entry.refs == 0) self.allocator.destroy(entry);
            if (err) |e| {
                self.mutex.unlock(self.io);
                return e;
            }
            if (installed) {
                self.mutex.unlock(self.io);
                return null;
            }
            // Fetched but not installed: fetch it here, unless someone
            // else already is.
        }
        const entry = self.allocator.create(InFlight) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        entry.* = .{};
        self.in_flight.put(self.allocator, id, entry) catch |err| {
            self.allocator.destroy(entry);
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);

        var bytes: ?[]u8 = null;
        var fetch_err: ?anyerror = null;
        var install_err: ?anyerror = null;
        if (self.isLocal(object)) |local| {
            if (!local) {
                if (self.fetchVerified(&object.digest, object.len)) |fetched| {
                    bytes = fetched;
                    self.install(&object.digest, fetched) catch |err| {
                        install_err = err;
                    };
                } else |err| fetch_err = err;
            }
        } else |err| fetch_err = err;

        self.mutex.lockUncancelable(self.io);
        _ = self.in_flight.remove(id);
        if (purpose == .window and bytes != null and install_err == null) {
            self.stats.window_fetches += 1;
            self.window_unread.put(self.allocator, id, {}) catch {};
        }
        // Waiters wake with the outcome, and the last one out frees it.
        entry.err = fetch_err;
        entry.installed = fetch_err == null and install_err == null;
        entry.refs -= 1;
        if (entry.refs == 0) self.allocator.destroy(entry) else entry.done.set(self.io);
        self.mutex.unlock(self.io);

        // A guest read already has verified bytes, so its failed install is
        // only counted.
        if (purpose == .read) if (bytes) |value| return value;
        if (bytes) |value| self.allocator.free(value);
        if (fetch_err) |e| return e;
        if (install_err) |e| return e;
        return null;
    }

    /// Whether `object` is in the local CAS at its indexed length.
    fn isLocal(self: *Fetcher, object: Object) !bool {
        const path = try rootfs_cas.manifestObjectPath(self.allocator, self.cache_root, &object.digest);
        defer self.allocator.free(path);
        const stat = Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => |e| return e,
        };
        return stat.kind == .file and stat.size == object.len;
    }

    /// Make `fetchAll` stop at its next object and fail, so a VM that is
    /// stopping need not wait for a whole image to download.
    pub fn cancel(self: *Fetcher) void {
        self.canceled.store(true, .release);
    }

    /// Whether a guest read could not fetch its object. The disk is then
    /// poisoned, and no snapshot can capture it.
    pub fn readFailed(self: *Fetcher) bool {
        return self.read_failed.load(.acquire);
    }

    /// Fetch every object of the storage that is missing locally, so that a
    /// snapshot can name them all, with up to `fill_concurrency` reads at
    /// once. On failure the objects fetched so far stay installed and the
    /// disk keeps serving reads; a later call fetches the rest.
    pub fn fetchAll(self: *Fetcher) !void {
        if (self.canceled.load(.acquire)) return error.ImageStoreFetchCanceled;
        if (self.complete.load(.acquire)) return;
        self.fill_mutex.lockUncancelable(self.io);
        defer self.fill_mutex.unlock(self.io);
        if (self.complete.load(.acquire)) return;
        const start_ns = monotonicNs();
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const missing = try self.missingObjects(arena_state.allocator());
        try fillEach(self.io, missing, &self.canceled, self, fillOne);
        self.complete.store(true, .release);
        std.log.info("image store {s}: fetched the root disk's {d} missing objects in {d} ms", .{ self.client.base.url, missing.len, (monotonicNs() -| start_ns) / std.time.ns_per_ms });
    }

    fn fillOne(self: *Fetcher, object: Object) !void {
        _ = try self.fetchOnce(object, .fill);
    }

    /// The distinct objects of the storage's index that are not in the local
    /// CAS at their indexed length.
    fn missingObjects(self: *Fetcher, arena: std.mem.Allocator) ![]const Object {
        const index_path = try rootfs_cas.manifestIndexPath(arena, self.cache_root, self.storage.index_digest);
        const index = try rootfs_cas.readStorageIndexPath(arena, index_path, self.storage);
        var seen = std.AutoHashMap(chunk.ChunkId, void).init(arena);
        var missing: std.ArrayList(Object) = .empty;
        for (index.parsed.value.chunks) |entry| {
            if ((try seen.getOrPut(entry.id)).found_existing) continue;
            const object = Object{ .digest = entry.id.toDigest(), .len = try rootfs_cas.storageChunkLen(self.storage, entry.logical_chunk) };
            if (!try self.isLocal(object)) try missing.append(arena, object);
        }
        return missing.items;
    }

    fn fetchVerified(self: *Fetcher, digest: []const u8, len: usize) (GetError || error{BadChunk})![]u8 {
        const start_ns = monotonicNs();
        const id = chunk.ChunkId.fromHex(digest[digest_prefix.len..]) catch return error.BadChunk;
        const path = try objectPathAlloc(self.allocator, digest);
        defer self.allocator.free(path);
        const bytes = self.client.get(self.allocator, path, .{ .max = len, .exact = true }, object_budget) catch |err| {
            self.record(.{ .errors = 1 });
            std.log.debug("image store {s}: fetching {s} failed: {s}", .{ self.client.base.url, digest, @errorName(err) });
            return err;
        };
        errdefer self.allocator.free(bytes);
        if (!id.matches(bytes)) {
            self.record(.{ .errors = 1 });
            std.log.debug("image store {s}: object {s} failed verification", .{ self.client.base.url, digest });
            return error.BadChunk;
        }
        self.record(.{ .fetches = 1, .bytes = bytes.len, .fetch_ns = monotonicNs() -| start_ns });
        return bytes;
    }

    fn install(self: *Fetcher, digest: []const u8, bytes: []const u8) !void {
        errdefer self.record(.{ .install_errors = 1 });
        const path = try rootfs_cas.manifestObjectPath(self.allocator, self.cache_root, digest);
        defer self.allocator.free(path);
        _ = try rootfs_cas.installChunkPath(self.allocator, self.io, path, bytes, digest, bytes.len);
    }

    fn record(self: *Fetcher, delta: FetchStats) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.stats.fetches += delta.fetches;
        self.stats.bytes += delta.bytes;
        self.stats.fetch_ns += delta.fetch_ns;
        self.stats.errors += delta.errors;
        self.stats.install_errors += delta.install_errors;
    }
};

/// Run `work(context, object)` for each of `objects`, up to `fill_concurrency`
/// at once with this thread among the workers, and return the first failure.
/// Workers stop at a failure, or with `ImageStoreFetchCanceled` once
/// `canceled` is set.
pub fn fillEach(
    io: Io,
    objects: []const Object,
    canceled: ?*const std.atomic.Value(bool),
    context: anytype,
    comptime work: anytype,
) !void {
    const Fill = struct {
        io: Io,
        objects: []const Object,
        canceled: ?*const std.atomic.Value(bool),
        context: @TypeOf(context),
        next: std.atomic.Value(usize) = .init(0),
        failed: std.atomic.Value(bool) = .init(false),
        /// Guards `err`.
        mutex: Io.Mutex = .init,
        /// The first failure.
        err: ?anyerror = null,

        fn run(fill: *@This()) Io.Cancelable!void {
            while (!fill.failed.load(.acquire)) {
                if (fill.canceled) |flag| if (flag.load(.acquire)) return fill.fail(error.ImageStoreFetchCanceled);
                const i = fill.next.fetchAdd(1, .monotonic);
                if (i >= fill.objects.len) return;
                work(fill.context, fill.objects[i]) catch |err| return fill.fail(err);
            }
        }

        fn fail(fill: *@This(), err: anyerror) void {
            fill.mutex.lockUncancelable(fill.io);
            defer fill.mutex.unlock(fill.io);
            if (fill.err == null) fill.err = err;
            fill.failed.store(true, .release);
        }
    };
    var fill: Fill = .{ .io = io, .objects = objects, .canceled = canceled, .context = context };
    var group: Io.Group = .init;
    for (0..@min(fill_concurrency, objects.len) -| 1) |_| {
        group.concurrent(io, Fill.run, .{&fill}) catch break;
    }
    Fill.run(&fill) catch {};
    group.await(io) catch {};
    if (fill.err) |err| return err;
}

fn monotonicMs() u64 {
    return monotonicNs() / std.time.ns_per_ms;
}

fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn fuzzTagParse(_: void, smith: *std.testing.Smith) !void {
    var buf: [tag_file_len + 1]u8 = undefined;
    const bytes = buf[0..smith.slice(&buf)];
    const digest = parseTag(bytes) catch return;
    try std.testing.expectEqual(@as(usize, digest_len), digest.len);
}

test "fuzz image store tag" {
    try std.testing.fuzz({}, fuzzTagParse, .{});
}

test "image store tags name exactly one image digest" {
    const digest = "blake3:" ++ test_support.repeat("0123456789abcdef", 4);
    try std.testing.expectEqualStrings(digest, try parseTag(digest ++ "\n"));
    for ([_][]const u8{
        digest,
        digest ++ "\n\n",
        digest ++ " \n",
        "blake3:" ++ test_support.repeat("0123456789ABCDEF", 4) ++ "\n",
        "sha256:" ++ test_support.repeat("0123456789abcdef", 4) ++ "\n",
        "",
    }) |bytes| try std.testing.expectError(error.BadImageStoreTag, parseTag(bytes));
}

test "image store refs name a store and a tag or digest" {
    const digest = "blake3:" ++ test_support.repeat("a", 64);
    const Case = struct { raw: []const u8, scheme: Scheme, url: []const u8, dir: []const u8 = "", tag: ?[]const u8 = null, bucket: []const u8 = "", prefix: []const u8 = "" };
    for ([_]Case{
        .{ .raw = "s3://my-bucket-1/team/images/app", .scheme = .s3, .url = "s3://my-bucket-1/team/images", .tag = "app", .bucket = "my-bucket-1", .prefix = "/team/images" },
        .{ .raw = "s3://abc/app", .scheme = .s3, .url = "s3://abc", .tag = "app", .bucket = "abc" },
        .{ .raw = "s3://abc/a_b.c~d/" ++ digest, .scheme = .s3, .url = "s3://abc/a_b.c~d", .bucket = "abc", .prefix = "/a_b.c~d" },
        .{ .raw = "/srv/store/app", .scheme = .file, .url = "/srv/store", .dir = "/srv/store", .tag = "app" },
        .{ .raw = "file:///srv/store/1.0_rc-2", .scheme = .file, .url = "file:///srv/store", .dir = "/srv/store", .tag = "1.0_rc-2" },
        .{ .raw = "https://images.example.test/team/app", .scheme = .https, .url = "https://images.example.test/team", .tag = "app" },
        .{ .raw = "https://images.example.test:8443/app", .scheme = .https, .url = "https://images.example.test:8443", .tag = "app" },
        .{ .raw = "http://127.0.0.1:8000/app", .scheme = .http, .url = "http://127.0.0.1:8000", .tag = "app" },
        .{ .raw = "http://[::1]:8000/app", .scheme = .http, .url = "http://[::1]:8000", .tag = "app" },
        .{ .raw = "http://10.0.0.1/store/" ++ digest, .scheme = .http, .url = "http://10.0.0.1/store" },
    }) |case| {
        const ref = try parseStoreRef(case.raw);
        try std.testing.expectEqual(case.scheme, ref.base.scheme);
        try std.testing.expectEqualStrings(case.url, ref.base.url);
        try std.testing.expectEqualStrings(case.dir, ref.base.dir);
        try std.testing.expectEqualStrings(case.bucket, ref.base.bucket);
        try std.testing.expectEqualStrings(case.prefix, ref.base.prefix);
        if (case.tag) |tag| {
            try std.testing.expectEqualStrings(tag, ref.target.tag);
        } else try std.testing.expectEqualStrings(digest, ref.target.digest);
    }

    const Rejected = struct { raw: []const u8, err: anyerror };
    for ([_]Rejected{
        .{ .raw = "http://images.example.test/app", .err = error.InsecureImageStoreTag },
        .{ .raw = "http://localhost:8000/app", .err = error.InsecureImageStoreTag },
        .{ .raw = "gs://bucket/app", .err = error.UnsupportedImageStoreScheme },
        .{ .raw = "relative/store/app", .err = error.UnsupportedImageStoreScheme },
        // A bucket is one DNS label of the endpoint; a prefix only plain
        // segments of unreserved bytes.
        .{ .raw = "s3://my.bucket/app", .err = error.InvalidImageStoreRef },
        .{ .raw = "s3://My-bucket/app", .err = error.InvalidImageStoreRef },
        .{ .raw = "s3://ab/app", .err = error.InvalidImageStoreRef },
        .{ .raw = "s3://" ++ test_support.repeat("a", 64) ++ "/app", .err = error.InvalidImageStoreRef },
        .{ .raw = "s3://-bucket/app", .err = error.InvalidImageStoreRef },
        .{ .raw = "s3:///app", .err = error.InvalidImageStoreRef },
        .{ .raw = "s3://user@bucket/app", .err = error.InvalidImageStoreRef },
        .{ .raw = "s3://bucket:443/app", .err = error.InvalidImageStoreRef },
        .{ .raw = "s3://bucket/team//app", .err = error.InvalidImageStoreRef },
        .{ .raw = "s3://bucket/../app", .err = error.InvalidImageStoreRef },
        .{ .raw = "s3://bucket/te:am/app", .err = error.InvalidImageStoreRef },
        .{ .raw = "s3://bucket/te+am/app", .err = error.InvalidImageStoreRef },
        .{ .raw = "https://user@images.example.test/app", .err = error.InvalidImageStoreRef },
        .{ .raw = "https://user:pass@images.example.test/app", .err = error.InvalidImageStoreRef },
        .{ .raw = "https://images.example.test/app?x=1", .err = error.InvalidImageStoreRef },
        .{ .raw = "https://images.example.test/a#b", .err = error.InvalidImageStoreRef },
        .{ .raw = "https://images.example.test/a%2fb/app", .err = error.InvalidImageStoreRef },
        .{ .raw = "https://images.example.test/../app", .err = error.InvalidImageStoreRef },
        .{ .raw = "https://images.example.test/team//app", .err = error.InvalidImageStoreRef },
        .{ .raw = "https://images.example.test/./app", .err = error.InvalidImageStoreRef },
        .{ .raw = "/srv/../store/app", .err = error.InvalidImageStoreRef },
        .{ .raw = "file://host/srv/app", .err = error.InvalidImageStoreRef },
        .{ .raw = "file:///app", .err = error.InvalidImageStoreRef },
        .{ .raw = "/srv/store/App", .err = error.InvalidImageStoreTag },
        .{ .raw = "/srv/store/-app", .err = error.InvalidImageStoreTag },
        .{ .raw = "/srv/store/", .err = error.InvalidImageStoreTag },
        .{ .raw = "/srv/store/" ++ test_support.repeat("a", (max_tag_len + 1)), .err = error.InvalidImageStoreTag },
        .{ .raw = "/srv/store/blake3:" ++ test_support.repeat("A", 64), .err = error.InvalidImageStoreRef },
        .{ .raw = "/srv/store/blake3:abc", .err = error.InvalidImageStoreRef },
    }) |case| try std.testing.expectError(case.err, parseStoreRef(case.raw));

    try std.testing.expect(isStoreRef("file:///srv/store/app"));
    try std.testing.expect(!isStoreRef("/srv/store/app"));
    try std.testing.expect(!isStoreRef("docker.io/library/alpine:3.20"));
}

/// Test support: a producer cache with one image and a store beside it.
pub const TestImage = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    env: std.process.Environ.Map,
    rootfs_bytes: []const u8,
    identity: []const u8,
    platform: rootfs.Platform,

    /// A producer cache holding `local/app:1` for `platform`, three nonzero
    /// objects and a zero chunk, and a store directory beside it.
    pub fn init(self: *TestImage, platform: rootfs.Platform) !void {
        self.platform = platform;
        self.tmp = std.testing.tmpDir(.{});
        self.arena = .init(std.testing.allocator);
        const allocator = self.arena.allocator();
        const io = std.testing.io;
        self.root = try self.tmp.dir.realPathFileAlloc(io, ".", allocator);
        self.env = .init(allocator);
        try self.env.put(local_paths.rootfs_cache_env, try self.path("producer-cache"));
        try self.env.put(local_paths.runtime_dir_env, try self.path("runtime"));
        try self.env.put("TMPDIR", self.root);

        const chunk_size = rootfs_cas.default_chunk_size;
        const bytes = try allocator.alloc(u8, 3 * chunk_size + 100);
        for (bytes, 0..) |*byte, i| byte.* = @truncate(i / chunk_size * 31 + i % 251 + 1);
        @memset(bytes[chunk_size .. 2 * chunk_size], 0);
        self.rootfs_bytes = bytes;
        const source_path = try self.path("rootfs.ext4");
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = bytes });
        const producer = self.env.get(local_paths.rootfs_cache_env).?;
        try Io.Dir.cwd().createDirPath(io, producer);
        const preload = try rootfs_cas.preloadPath(io, allocator, producer, source_path, chunk_size);
        const published = try local_image.lockAndPublish(io, allocator, producer, .{
            .platform = platform,
            .storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload),
            .name = "local/app:1",
        });
        self.identity = published.identity;
    }

    pub fn deinit(self: *TestImage) void {
        self.env.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
    }

    pub fn path(self: *TestImage, name: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ self.root, name });
    }

    pub fn processInit(self: *TestImage) std.process.Init {
        return .{
            .minimal = undefined,
            .arena = &self.arena,
            .gpa = self.arena.allocator(),
            .io = std.testing.io,
            .environ_map = &self.env,
            .preopens = .empty,
        };
    }

    pub fn pushTo(self: *TestImage, destination: []const u8) !PushResult {
        return push(self.processInit(), self.arena.allocator(), .{ .source = "local/app:1", .destination = destination, .platform = self.platform });
    }

    /// A fake aws CLI that keeps S3 in the fixture's `bucket` directory, with
    /// `sync --size-only` semantics. It logs each command to `aws.log`, and a
    /// sync to `.../<dir>` fails while `bucket/fail-<dir>` exists.
    pub fn fakeAws(self: *TestImage) ![]const u8 {
        const allocator = self.arena.allocator();
        const io = std.testing.io;
        const bucket = try self.path("bucket");
        const aws = try self.path("aws");
        try Io.Dir.cwd().createDirPath(io, bucket);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = aws, .data = try std.fmt.allocPrint(allocator,
            \\#!/usr/bin/env bash
            \\set -euo pipefail
            \\root="{s}"
            \\printf '%s\n' "$*" >> "{s}"
            \\args=("$@")
            \\src="${{args[$# - 2]}}"
            \\url="${{args[$# - 1]}}"
            \\dst="$root/${{url#s3://}}"
            \\case "$1 $2" in
            \\  "s3 sync")
            \\    if [[ -e "$root/fail-${{url##*/}}" ]]; then exit 1; fi
            \\    (cd "$src" && find . -type f | sort) | while read -r file; do
            \\      file="${{file#./}}"
            \\      if [[ -f "$dst/$file" && $(wc -c < "$dst/$file") == $(wc -c < "$src/$file") ]]; then continue; fi
            \\      mkdir -p "$(dirname "$dst/$file")"
            \\      cp "$src/$file" "$dst/$file"
            \\      [[ " $* " == *" --only-show-errors "* ]] || echo "upload: $src/$file to $url/$file"
            \\    done ;;
            \\  "s3 cp") mkdir -p "$(dirname "$dst")"; cp "$src" "$dst" ;;
            \\  *) exit 2 ;;
            \\esac
            \\
        , .{ bucket, try self.path("aws.log") }), .flags = .{ .permissions = .fromMode(0o755) } });
        return aws;
    }

    pub fn listStore(self: *TestImage, store: []const u8) ![]const []const u8 {
        const allocator = self.arena.allocator();
        var dir = try Io.Dir.cwd().openDir(std.testing.io, store, .{ .iterate = true });
        defer dir.close(std.testing.io);
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        var files: std.ArrayList([]const u8) = .empty;
        while (try walker.next(std.testing.io)) |entry| {
            if (entry.kind == .file) try files.append(allocator, try allocator.dupe(u8, entry.path));
        }
        std.mem.sort([]const u8, files.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        return files.items;
    }
};

test "image push writes a complete store once and retags without rewriting" {
    var fixture: TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const store = try fixture.path("store");
    const hex = fixture.identity[digest_prefix.len..];

    const first = try fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/1", .{store}));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "file://{s}/1", .{store}), first.ref);
    try std.testing.expect(isStoreRef(first.ref));
    try std.testing.expectEqualStrings(fixture.identity, first.image_digest);
    try std.testing.expectEqual(@as(usize, 3), first.objects_total);
    try std.testing.expectEqual(@as(usize, 3), first.objects_written);
    try std.testing.expectEqual(@as(u64, 2 * rootfs_cas.default_chunk_size + 100), first.bytes_written);

    const files = try fixture.listStore(store);
    try std.testing.expectEqual(@as(usize, 7), files.len);
    for (files[0..3]) |file| try std.testing.expect(std.mem.startsWith(u8, file, "images/"));
    for (files[3..6]) |file| try std.testing.expect(std.mem.startsWith(u8, file, "objects/blake3/"));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "images/{s}/config", .{hex}), files[0]);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "images/{s}/index", .{hex}), files[1]);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "images/{s}/manifest", .{hex}), files[2]);
    try std.testing.expectEqualStrings("tags/1", files[6]);
    const tag_path = try std.fs.path.join(allocator, &.{ store, "tags", "1" });
    const tag_bytes = try Io.Dir.cwd().readFileAlloc(io, tag_path, allocator, .limited(128));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "{s}\n", .{fixture.identity}), tag_bytes);

    const again = try fixture.pushTo(try std.fmt.allocPrint(allocator, "file://{s}/1", .{store}));
    try std.testing.expectEqual(@as(usize, 0), again.objects_written);
    try std.testing.expectEqual(@as(u64, 0), again.bytes_written);

    const object_path = try std.fs.path.join(allocator, &.{ store, files[3] });
    const object_before = try Io.Dir.cwd().statFile(io, object_path, .{});
    const retagged = try fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/latest", .{store}));
    try std.testing.expectEqual(@as(usize, 0), retagged.objects_written);
    const object_after = try Io.Dir.cwd().statFile(io, object_path, .{});
    try std.testing.expectEqual(object_before.inode, object_after.inode);
    const retagged_files = try fixture.listStore(store);
    try std.testing.expectEqual(@as(usize, 8), retagged_files.len);
    try std.testing.expectEqualStrings("tags/latest", retagged_files[7]);

    // A damaged object is replaced; a digest destination must name the image.
    try chunk_sealer.replaceFileAtomicDurable(allocator, object_path, "damaged", 0o644);
    const repaired = try fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/{s}", .{ store, fixture.identity }));
    try std.testing.expectEqual(@as(usize, 1), repaired.objects_written);
    try std.testing.expectEqual(@as(usize, 8), (try fixture.listStore(store)).len);
    try std.testing.expectError(error.ImageIdentityMismatch, fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/blake3:{s}", .{ store, test_support.repeat("b", 64) })));
    try std.testing.expectError(error.ImageStorePushUnsupportedScheme, fixture.pushTo("https://images.example.test/app"));
}

test "image push to S3 uploads objects, then the image, then the tag, with the aws CLI" {
    var fixture: TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const aws = try fixture.fakeAws();
    const bucket = try fixture.path("bucket");
    const log = try fixture.path("aws.log");
    const options = PushOptions{ .source = "local/app:1", .destination = "s3://bucket-1/team/1", .platform = fixture.platform, .aws_executable = aws };

    // The image's files reach the bucket before its tag, so a reader never
    // sees a tag naming an image the store lacks.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(allocator, &.{ bucket, "fail-images" }), .data = "" });
    try std.testing.expectError(error.ImageStorePushFailed, push(fixture.processInit(), allocator, options));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, try std.fs.path.join(allocator, &.{ bucket, "bucket-1", "team", "tags" }), .{}));
    try Io.Dir.cwd().deleteFile(io, try std.fs.path.join(allocator, &.{ bucket, "fail-images" }));

    const pushed = try push(fixture.processInit(), allocator, options);
    try std.testing.expectEqualStrings("s3://bucket-1/team/1", pushed.ref);
    try std.testing.expectEqualStrings(fixture.identity, pushed.image_digest);
    try std.testing.expectEqual(@as(usize, 3), pushed.objects_total);
    // The failed push uploaded the objects already.
    try std.testing.expectEqual(@as(usize, 0), pushed.objects_written);
    const commands = try Io.Dir.cwd().readFileAlloc(io, log, allocator, .limited(64 * 1024));
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, commands, "\n"), '\n');
    const objects_sync = .{ "s3 sync --size-only --no-progress ", " s3://bucket-1/team/objects" };
    const images_sync = .{ "s3 sync --size-only --only-show-errors ", " s3://bucket-1/team/images" };
    const tag_copy = .{ "s3 cp --only-show-errors ", " s3://bucket-1/team/tags/1" };
    inline for (.{ objects_sync, images_sync, objects_sync, images_sync, tag_copy }) |expected| {
        const line = lines.next() orelse return error.TestExpectedAwsCommand;
        try std.testing.expect(std.mem.startsWith(u8, line, expected[0]));
        try std.testing.expect(std.mem.endsWith(u8, line, expected[1]));
    }
    try std.testing.expectEqual(null, lines.next());

    // The bucket is a store: it reads back as one, and a fresh object
    // upload is counted from what the CLI reports.
    const store = try std.fs.path.join(allocator, &.{ bucket, "bucket-1", "team" });
    const consumer = try fixture.path("consumer-cache");
    const local = try resolve(io, allocator, consumer, try std.fmt.allocPrint(allocator, "{s}/1", .{store}), .{}, &fixture.env);
    try std.testing.expectEqualStrings(fixture.identity, local.identity);
    try Io.Dir.cwd().deleteTree(io, try std.fs.path.join(allocator, &.{ store, "objects" }));
    const again = try push(fixture.processInit(), allocator, .{ .source = "local/app:1", .destination = try std.fmt.allocPrint(allocator, "s3://bucket-1/team/{s}", .{fixture.identity}), .platform = fixture.platform, .aws_executable = aws });
    try std.testing.expectEqual(@as(usize, 3), again.objects_written);
    try std.testing.expectEqual(@as(u64, 2 * rootfs_cas.default_chunk_size + 100), again.bytes_written);

    // Every push removed its staging directory.
    const cache = fixture.env.get(local_paths.rootfs_cache_env).?;
    var tmp = try Io.Dir.cwd().openDir(io, try std.fs.path.join(allocator, &.{ cache, "tmp" }), .{ .iterate = true });
    defer tmp.close(io);
    var entries = tmp.iterate();
    try std.testing.expectEqual(null, try entries.next(io));
    try std.testing.expectError(error.AwsCliUnavailable, push(fixture.processInit(), allocator, .{ .source = "local/app:1", .destination = "s3://bucket-1/team/1", .platform = fixture.platform, .aws_executable = try fixture.path("missing-aws") }));
}

test "a store image resolves into an empty cache with only its metadata" {
    var fixture: TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const store = try fixture.path("store");
    _ = try fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/1", .{store}));
    const consumer = try fixture.path("consumer-cache");
    const ref = try std.fmt.allocPrint(allocator, "file://{s}/1", .{store});
    const platform = rootfs.Platform{};

    const local = try resolve(io, allocator, consumer, ref, platform, &fixture.env);
    try std.testing.expectEqualStrings(fixture.identity, local.identity);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "file://{s}", .{store}), local.origin.?);
    try std.testing.expect(!try rootfs_cas.storageMarkedComplete(io, allocator, consumer, local.storage));
    const objects_dir = try std.fs.path.join(allocator, &.{ consumer, "cas", "rootfs", "blake3", "objects" });
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, objects_dir, .{}));
    try std.testing.expectError(error.UnsupportedPlatform, resolve(io, allocator, consumer, ref, .{ .arch = .amd64 }, &fixture.env));

    // A digest ref of a local image needs no store.
    const digest_ref = try std.fmt.allocPrint(allocator, "file://{s}/missing/{s}", .{ store, fixture.identity });
    const by_digest = try resolve(io, allocator, consumer, digest_ref, platform, &fixture.env);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "file://{s}/missing", .{store}), by_digest.origin.?);

    // Tampered metadata never reaches the catalog.
    const hex = fixture.identity[digest_prefix.len..];
    for ([_][]const u8{ "manifest", "config", "index" }) |file| {
        const tampered_store = try fixture.path(try std.fmt.allocPrint(allocator, "tampered-{s}", .{file}));
        _ = try fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/1", .{tampered_store}));
        const file_path = try std.fs.path.join(allocator, &.{ tampered_store, "images", hex, file });
        var bytes = try Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(disk_index.max_index_bytes));
        bytes[bytes.len / 2] ^= 1;
        try chunk_sealer.replaceFileAtomicDurable(allocator, file_path, bytes, 0o644);
        const tampered_cache = try fixture.path(try std.fmt.allocPrint(allocator, "tampered-{s}-cache", .{file}));
        try std.testing.expectError(error.BadProtocol, resolve(io, allocator, tampered_cache, try std.fmt.allocPrint(allocator, "{s}/1", .{tampered_store}), platform, &fixture.env));
        try std.testing.expectEqual(null, try local_image.loadAllowingOrigin(io, allocator, tampered_cache, fixture.identity));
    }
    const missing_cache = try fixture.path("missing-cache");
    try std.testing.expectError(error.ImageStoreNotFound, resolve(io, allocator, missing_cache, try std.fmt.allocPrint(allocator, "{s}/2", .{store}), platform, &fixture.env));
}

/// Test support: serves files from `root` over HTTP/1.1 on loopback address
/// `ip`, each connection on its own thread. `failures` answers that many
/// requests with 500 first; `hang` holds every request open until `deinit`;
/// `delay_ms` delays every answer, reading the file after the delay; requests
/// for `held` wait until `releaseHeld`; with `s3` set, a request without a
/// valid SigV4 signature by those credentials gets 403, as S3 answers.
pub const TestServer = struct {
    allocator: std.mem.Allocator,
    io: Io,
    root: []const u8,
    server: Io.net.Server,
    thread: std.Thread,
    /// Connection threads; guarded by `mutex`.
    handlers: std.ArrayList(std.Thread) = .empty,
    mutex: Io.Mutex = .init,
    closed: std.atomic.Value(bool) = .init(false),
    failures: std.atomic.Value(u32) = .init(0),
    requests: std.atomic.Value(u32) = .init(0),
    hang: std.atomic.Value(bool) = .init(false),
    delay_ms: std.atomic.Value(u32) = .init(0),
    /// A request path, such as `/objects/blake3/<hex>`; set before requests.
    held: ?[]const u8 = null,
    released: std.atomic.Value(bool) = .init(false),
    /// Set before requests.
    s3: ?struct { credentials: s3_sigv4.Credentials, region: []const u8 } = null,
    /// Requests whose signature did not verify.
    unsigned: std.atomic.Value(u32) = .init(0),
    /// Requests that carried the secret key anywhere in their head.
    leaked: std.atomic.Value(u32) = .init(0),

    pub fn start(self: *TestServer, allocator: std.mem.Allocator, io: Io, root: []const u8, ip: []const u8) !void {
        var address = try Io.net.IpAddress.parse(ip, 0);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .root = root,
            .server = try address.listen(io, .{ .kernel_backlog = 8, .reuse_address = true }),
            .thread = undefined,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    pub fn stop(self: *TestServer) void {
        self.closed.store(true, .release);
        if (self.server.socket.address.connect(self.io, .{ .mode = .stream })) |stream| {
            stream.close(self.io);
        } else |_| {}
        self.thread.join();
        for (self.handlers.items) |thread| thread.join();
        self.handlers.deinit(self.allocator);
        self.server.deinit(self.io);
    }

    pub fn releaseHeld(self: *TestServer) void {
        self.released.store(true, .release);
    }

    pub fn url(self: *TestServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://{f}", .{self.server.socket.address});
    }

    fn serve(self: *TestServer) void {
        while (!self.closed.load(.acquire)) {
            const stream = self.server.accept(self.io) catch continue;
            if (self.closed.load(.acquire)) return stream.close(self.io);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.handlers.ensureUnusedCapacity(self.allocator, 1) catch return stream.close(self.io);
            const thread = std.Thread.spawn(.{}, connection, .{ self, stream }) catch return stream.close(self.io);
            self.handlers.appendAssumeCapacity(thread);
        }
    }

    fn connection(self: *TestServer, stream: Io.net.Stream) void {
        defer stream.close(self.io);
        self.handle(stream) catch {};
    }

    fn handle(self: *TestServer, stream: Io.net.Stream) !void {
        var read_buffer: [8 * 1024]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        // The head as read: request line, then header lines.
        var head: std.ArrayList([]const u8) = .empty;
        while (true) {
            const line = std.mem.trimEnd(u8, try reader.interface.takeDelimiterInclusive('\n'), "\r\n");
            if (line.len == 0) break;
            try head.append(arena, try arena.dupe(u8, line));
        }
        const request_line = head.items[0];
        const path = request_line["GET ".len..std.mem.lastIndexOfScalar(u8, request_line, ' ').?];
        const file_path = try std.fs.path.join(arena, &.{ self.root, path[1..] });
        _ = self.requests.fetchAdd(1, .monotonic);
        if (self.s3) |s3| {
            for (head.items) |line| {
                if (std.mem.indexOf(u8, line, s3.credentials.secret_access_key) != null) _ = self.leaked.fetchAdd(1, .monotonic);
            }
            if (!try verifySigV4(arena, s3.credentials, s3.region, path, head.items[1..])) {
                _ = self.unsigned.fetchAdd(1, .monotonic);
                var forbidden_buffer: [256]u8 = undefined;
                var forbidden = stream.writer(self.io, &forbidden_buffer);
                try forbidden.interface.writeAll("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                return forbidden.interface.flush();
            }
        }
        std.Io.sleep(self.io, .fromMilliseconds(self.delay_ms.load(.monotonic)), .awake) catch {};
        if (self.held) |held| if (std.mem.eql(u8, held, path)) {
            while (!self.released.load(.acquire) and !self.closed.load(.acquire)) std.Io.sleep(self.io, .fromMilliseconds(5), .awake) catch {};
        };
        if (self.hang.load(.acquire)) {
            while (!self.closed.load(.acquire)) std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch {};
            return;
        }
        var write_buffer: [8 * 1024]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        if (self.failures.load(.monotonic) != 0) {
            _ = self.failures.fetchSub(1, .monotonic);
            try writer.interface.writeAll("HTTP/1.1 500 Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            return writer.interface.flush();
        }
        const data = Io.Dir.cwd().readFileAlloc(self.io, file_path, self.allocator, .limited(disk_index.max_index_bytes)) catch {
            try writer.interface.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            return writer.interface.flush();
        };
        defer self.allocator.free(data);
        try writer.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{data.len});
        try writer.interface.writeAll(data);
        try writer.interface.flush();
    }
};

/// Test support: checks a GET's SigV4 Authorization header the way S3 does,
/// from the request as received. The host, payload hash, date and any
/// session token must be signed, and the signature must be the one
/// `credentials` give over the headers it names.
fn verifySigV4(arena: std.mem.Allocator, credentials: s3_sigv4.Credentials, region: []const u8, path: []const u8, header_lines: []const []const u8) !bool {
    var values: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (header_lines) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
        try values.put(arena, try std.ascii.allocLowerString(arena, line[0..colon]), std.mem.trim(u8, line[colon + 1 ..], " "));
    }
    const sent = values.get("authorization") orelse return false;
    const names_start = (std.mem.indexOf(u8, sent, ",SignedHeaders=") orelse return false) + ",SignedHeaders=".len;
    const names_end = std.mem.indexOfScalarPos(u8, sent, names_start, ',') orelse return false;
    var signed: std.ArrayList(s3_sigv4.Header) = .empty;
    var names = std.mem.splitScalar(u8, sent[names_start..names_end], ';');
    while (names.next()) |name| try signed.append(arena, .{ .name = name, .value = values.get(name) orelse return false });
    var required: std.ArrayList([]const u8) = .empty;
    try required.appendSlice(arena, &.{ "host", "x-amz-content-sha256", "x-amz-date" });
    if (credentials.session_token) |token| {
        if (!std.mem.eql(u8, values.get("x-amz-security-token") orelse return false, token)) return false;
        try required.append(arena, "x-amz-security-token");
    }
    for (required.items) |name| {
        for (signed.items) |header| {
            if (std.mem.eql(u8, header.name, name)) break;
        } else return false;
    }
    var buf: [512]u8 = undefined;
    const expected = s3_sigv4.authorization(&buf, credentials, .{
        .method = "GET",
        .path = path,
        .region = region,
        .amz_date = values.get("x-amz-date").?,
        .payload_hash = values.get("x-amz-content-sha256").?,
        .headers = signed.items,
    }) catch return false;
    return std.mem.eql(u8, expected, sent);
}

test "HTTP store reads retry transient failures and fail closed on the rest" {
    var fixture: TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const store = try fixture.path("store");
    _ = try fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/1", .{store}));
    const tag_path = try std.fs.path.join(allocator, &.{ store, "tags", "1" });
    const tag = try Io.Dir.cwd().readFileAlloc(io, tag_path, allocator, .limited(tag_file_len + 1));

    var server: TestServer = undefined;
    try server.start(std.testing.allocator, io, store, "127.0.0.1");
    defer server.stop();
    var client = try Client.init(std.testing.allocator, io, try server.url(allocator), &fixture.env);
    defer client.deinit();
    const quick = Budget{ .attempts = 3, .attempt_ms = 2_000, .total_ms = 5_000 };

    const bytes = try client.get(std.testing.allocator, "tags/1", .{ .max = tag_file_len }, quick);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(tag, bytes);

    server.failures.store(1, .monotonic);
    const retried = try client.get(std.testing.allocator, "tags/1", .{ .max = tag_file_len }, quick);
    std.testing.allocator.free(retried);

    server.failures.store(3, .monotonic);
    try std.testing.expectError(error.ImageStoreUnavailable, client.get(std.testing.allocator, "tags/1", .{ .max = tag_file_len }, quick));

    const before_missing = server.requests.load(.monotonic);
    try std.testing.expectError(error.ImageStoreNotFound, client.get(std.testing.allocator, "tags/2", .{ .max = tag_file_len }, quick));
    try std.testing.expectEqual(before_missing + 1, server.requests.load(.monotonic));
    try std.testing.expectError(error.ImageStoreBadResponse, client.get(std.testing.allocator, "tags/1", .{ .max = tag_file_len - 1 }, quick));
    try std.testing.expectError(error.ImageStoreBadResponse, client.get(std.testing.allocator, "tags/1", .{ .max = tag_file_len + 1, .exact = true }, quick));

    server.hang.store(true, .release);
    const start_ms = monotonicMs();
    try std.testing.expectError(error.ImageStoreTimeout, client.get(std.testing.allocator, "tags/1", .{ .max = tag_file_len }, .{ .attempts = 2, .attempt_ms = 200, .total_ms = 600 }));
    try std.testing.expect(monotonicMs() - start_ms < 2_000);
}

test "HTTP stores at loopback IP literals resolve images" {
    var fixture: TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const store = try fixture.path("store");
    _ = try fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/1", .{store}));

    for ([_][]const u8{ "127.0.0.1", "::1" }, 0..) |ip, i| {
        var server: TestServer = undefined;
        server.start(std.testing.allocator, io, store, ip) catch |err| switch (err) {
            // The host has no IPv6 loopback.
            error.AddressUnavailable, error.AddressFamilyUnsupported => continue,
            else => return err,
        };
        defer server.stop();
        const cache = try fixture.path(try std.fmt.allocPrint(allocator, "cache-{d}", .{i}));
        const ref = try std.fmt.allocPrint(allocator, "{s}/1", .{try server.url(allocator)});
        const local = try resolve(io, allocator, cache, ref, .{}, &fixture.env);
        try std.testing.expectEqualStrings(fixture.identity, local.identity);
    }
}

test "S3 store reads are signed with the environment's credentials, which only the signature carries" {
    var fixture: TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const bucket = try fixture.path("bucket");
    _ = try fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/team/1", .{bucket}));
    const tag = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(allocator, &.{ bucket, "team", "tags", "1" }), allocator, .limited(tag_file_len + 1));
    const objects = try testObjects(&fixture, try std.fs.path.join(allocator, &.{ bucket, "team" }));

    const secret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY";
    const token = "IQoJb3JpZ2luX2VjEXAMPLE/session+token==";
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("AWS_ACCESS_KEY_ID", "AKIDEXAMPLE");
    try env.put("AWS_SECRET_ACCESS_KEY", secret);
    try env.put("AWS_SESSION_TOKEN", token);
    try env.put("AWS_REGION", "eu-west-2");

    var server: TestServer = undefined;
    try server.start(std.testing.allocator, io, bucket, "127.0.0.1");
    defer server.stop();
    server.s3 = .{ .credentials = .{ .access_key_id = "AKIDEXAMPLE", .secret_access_key = secret, .session_token = token }, .region = "eu-west-2" };
    const endpoint = try server.url(allocator);
    const once = Budget{ .attempts = 1, .attempt_ms = 2_000, .total_ms = 2_000 };

    var client = try Client.initWithEndpoint(std.testing.allocator, io, "s3://bucket-1/team", &env, endpoint);
    defer client.deinit();
    const bytes = try client.get(std.testing.allocator, "tags/1", .{ .max = tag_file_len }, once);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(tag, bytes);
    const path = try objectPathAlloc(allocator, &objects[0].digest);
    const object = try client.get(std.testing.allocator, path, .{ .max = objects[0].len, .exact = true }, once);
    std.testing.allocator.free(object);
    try std.testing.expectEqual(@as(u32, 0), server.unsigned.load(.monotonic));

    // A wrong secret, a missing session token or another region signs
    // something S3 rejects, and the read fails closed.
    const Variant = struct { name: []const u8, value: ?[]const u8 };
    for ([_]Variant{
        .{ .name = "AWS_SECRET_ACCESS_KEY", .value = "another-secret" },
        .{ .name = "AWS_SESSION_TOKEN", .value = null },
        .{ .name = "AWS_REGION", .value = "us-east-1" },
    }) |variant| {
        var other = try env.clone(std.testing.allocator);
        defer other.deinit();
        if (variant.value) |value| try other.put(variant.name, value) else _ = other.swapRemove(variant.name);
        var rejected = try Client.initWithEndpoint(std.testing.allocator, io, "s3://bucket-1/team", &other, endpoint);
        defer rejected.deinit();
        try std.testing.expectError(error.ImageStoreRejected, rejected.get(std.testing.allocator, "tags/1", .{ .max = tag_file_len }, once));
    }
    try std.testing.expectEqual(@as(u32, 3), server.unsigned.load(.monotonic));

    // The secret never crossed the wire, and what logs and the catalog show
    // of the store is the ref as written.
    try std.testing.expectEqual(@as(u32, 0), server.leaked.load(.monotonic));
    try std.testing.expectEqualStrings("s3://bucket-1/team", client.base.url);

    // Credentials and region must be present and plain before any request.
    var missing = std.process.Environ.Map.init(std.testing.allocator);
    defer missing.deinit();
    try std.testing.expectError(error.AwsCredentialsMissing, Client.init(std.testing.allocator, io, "s3://bucket-1/team", &missing));
    try missing.put("AWS_ACCESS_KEY_ID", "AKIDEXAMPLE");
    try missing.put("AWS_SECRET_ACCESS_KEY", secret);
    try std.testing.expectError(error.AwsRegionMissing, Client.init(std.testing.allocator, io, "s3://bucket-1/team", &missing));
    try missing.put("AWS_REGION", "eu-west-2");
    try missing.put("AWS_SESSION_TOKEN", "token\r\nx-injected: 1");
    try std.testing.expectError(error.AwsCredentialsInvalid, Client.init(std.testing.allocator, io, "s3://bucket-1/team", &missing));
    // An S3-compatible endpoint is refused rather than ignored.
    for ([_][]const u8{ "AWS_ENDPOINT_URL", "AWS_ENDPOINT_URL_S3" }) |name| {
        var compatible = try env.clone(std.testing.allocator);
        defer compatible.deinit();
        try compatible.put(name, "http://127.0.0.1:9000");
        try std.testing.expectError(error.AwsEndpointUrlUnsupported, Client.init(std.testing.allocator, io, "s3://bucket-1/team", &compatible));
    }
}

/// Test support: the store's objects, each with its index-derived length.
fn testObjects(fixture: *TestImage, store: []const u8) ![]const Object {
    const allocator = fixture.arena.allocator();
    var objects: std.ArrayList(Object) = .empty;
    for (try fixture.listStore(store)) |file| {
        if (!std.mem.startsWith(u8, file, "objects/blake3/")) continue;
        const size = (try Io.Dir.cwd().statFile(std.testing.io, try std.fs.path.join(allocator, &.{ store, file }), .{})).size;
        var object = Object{ .digest = undefined, .len = @intCast(size) };
        _ = try std.fmt.bufPrint(&object.digest, "blake3:{s}", .{std.fs.path.basename(file)});
        try objects.append(allocator, object);
    }
    return objects.items;
}

/// Test support: wait for `fetcher`'s window fetches to finish.
pub fn awaitWindows(fetcher: *Fetcher) !void {
    const start_ms = monotonicMs();
    while (fetcher.windows_running.load(.acquire) != 0) {
        if (monotonicMs() - start_ms > 5_000) return error.TestWindowsDidNotFinish;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
}

test "a guest read fetches its window with it, with one GET per object" {
    var fixture: TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const store = try fixture.path("store");
    _ = try fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/1", .{store}));
    const local = try resolve(io, allocator, try fixture.path("metadata-cache"), try std.fmt.allocPrint(allocator, "file://{s}/1", .{store}), .{}, &fixture.env);
    const objects = try testObjects(&fixture, store);
    const read, const next, const after = .{ objects[0], objects[1], objects[2] };

    var server: TestServer = undefined;
    try server.start(std.testing.allocator, io, store, "127.0.0.1");
    defer server.stop();
    // Every GET is slow, so the window's two requests for `next` overlap.
    server.delay_ms.store(100, .monotonic);
    const cache = try fixture.path("cache");
    const fetcher = try Fetcher.create(std.testing.allocator, io, cache, try server.url(allocator), local.storage, &fixture.env);
    defer fetcher.release();
    const buf = try allocator.alloc(u8, read.len);
    try fetcher.fetchObject(&read.digest, buf, &.{ next, next, after });
    try std.testing.expect((try chunk.ChunkId.fromDigest(&read.digest)).matches(buf));
    try awaitWindows(fetcher);
    try std.testing.expectEqual(@as(u32, 3), server.requests.load(.monotonic));
    var stats = fetcher.currentStats();
    try std.testing.expectEqual(@as(u64, 3), stats.fetches);
    try std.testing.expectEqual(@as(u64, 2), stats.window_fetches);
    try std.testing.expectEqual(@as(u64, 2), stats.window_unused);
    for ([_]Object{ next, after }) |object| try std.testing.expect(try fetcher.isLocal(object));
    fetcher.noteRead(&next.digest);
    stats = fetcher.currentStats();
    try std.testing.expectEqual(@as(u64, 1), stats.window_unused);

    // A failed window fetch fails nothing, but stops later windows.
    server.delay_ms.store(0, .monotonic);
    const lossy = try Fetcher.create(std.testing.allocator, io, try fixture.path("lossy-cache"), try server.url(allocator), local.storage, &fixture.env);
    defer lossy.release();
    const hidden = try fixture.path("hidden");
    const after_path = try std.fs.path.join(allocator, &.{ store, "objects", "blake3", after.digest[digest_prefix.len..] });
    try Io.Dir.renameAbsolute(after_path, hidden, io);
    try lossy.fetchObject(&read.digest, buf, &.{after});
    try awaitWindows(lossy);
    try std.testing.expect(!lossy.readFailed());
    try Io.Dir.renameAbsolute(hidden, after_path, io);
    const before = server.requests.load(.monotonic);
    try lossy.fetchObject(&next.digest, try allocator.alloc(u8, next.len), &.{after});
    try awaitWindows(lossy);
    try std.testing.expectEqual(before + 1, server.requests.load(.monotonic));
    try std.testing.expect(!try lossy.isLocal(after));
}

test "a guest read returns before its window, which finishes into the cache" {
    var fixture: TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const store = try fixture.path("store");
    _ = try fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/1", .{store}));
    const local = try resolve(io, allocator, try fixture.path("metadata-cache"), try std.fmt.allocPrint(allocator, "file://{s}/1", .{store}), .{}, &fixture.env);
    const objects = try testObjects(&fixture, store);
    const read, const next = .{ objects[0], objects[1] };

    var server: TestServer = undefined;
    try server.start(std.testing.allocator, io, store, "127.0.0.1");
    defer server.stop();
    server.held = try std.fmt.allocPrint(allocator, "/objects/blake3/{s}", .{next.digest[digest_prefix.len..]});
    const fetcher = try Fetcher.create(std.testing.allocator, io, try fixture.path("cache"), try server.url(allocator), local.storage, &fixture.env);
    defer fetcher.release();
    // The window's store stalls; a fault that waited for it would wait
    // until the release below.
    const Releaser = struct {
        fn run(test_server: *TestServer) void {
            std.Io.sleep(std.testing.io, .fromMilliseconds(1_000), .awake) catch {};
            test_server.releaseHeld();
        }
    };
    const releaser = try std.Thread.spawn(.{}, Releaser.run, .{&server});
    defer releaser.join();
    const start_ms = monotonicMs();
    try fetcher.fetchObject(&read.digest, try allocator.alloc(u8, read.len), &.{next});
    try std.testing.expect(monotonicMs() - start_ms < 800);
    try std.testing.expect(!try fetcher.isLocal(next));
    try awaitWindows(fetcher);
    try std.testing.expect(try fetcher.isLocal(next));
    try std.testing.expectEqual(@as(u64, 1), fetcher.currentStats().window_fetches);
}

test "releasing a fetcher cancels a window fetch the store never answers" {
    var fixture: TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const store = try fixture.path("store");
    _ = try fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/1", .{store}));
    const local = try resolve(io, allocator, try fixture.path("metadata-cache"), try std.fmt.allocPrint(allocator, "file://{s}/1", .{store}), .{}, &fixture.env);
    const objects = try testObjects(&fixture, store);
    const read, const next = .{ objects[0], objects[1] };

    var server: TestServer = undefined;
    try server.start(std.testing.allocator, io, store, "127.0.0.1");
    defer server.stop();
    server.held = try std.fmt.allocPrint(allocator, "/objects/blake3/{s}", .{next.digest[digest_prefix.len..]});
    const fetcher = try Fetcher.create(std.testing.allocator, io, try fixture.path("cache"), try server.url(allocator), local.storage, &fixture.env);
    try fetcher.fetchObject(&read.digest, try allocator.alloc(u8, read.len), &.{next});
    while (server.requests.load(.monotonic) < 2) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    // A canceled window fetch ends at once rather than retrying for the
    // rest of its 10 s budget.
    const start_ms = monotonicMs();
    fetcher.release();
    try std.testing.expect(monotonicMs() - start_ms < 2_000);
    try std.testing.expectEqual(@as(u32, 2), server.requests.load(.monotonic));
}

test "a read that shares a request that could not install its object fetches it itself" {
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    var fixture: TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const store = try fixture.path("store");
    _ = try fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/1", .{store}));
    const local = try resolve(io, allocator, try fixture.path("metadata-cache"), try std.fmt.allocPrint(allocator, "file://{s}/1", .{store}), .{}, &fixture.env);
    const objects = try testObjects(&fixture, store);
    const read, const next = .{ objects[0], objects[1] };

    var server: TestServer = undefined;
    try server.start(std.testing.allocator, io, store, "127.0.0.1");
    defer server.stop();
    server.held = try std.fmt.allocPrint(allocator, "/objects/blake3/{s}", .{next.digest[digest_prefix.len..]});
    // Nothing can be installed into this cache.
    const cache = try fixture.path("cache");
    const objects_dir = std.fs.path.dirname(try rootfs_cas.manifestObjectPath(allocator, cache, &next.digest)).?;
    try Io.Dir.cwd().createDirPath(io, objects_dir);
    const objects_dir_z = try allocator.dupeSentinel(u8, objects_dir, 0);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(objects_dir_z, 0o555));
    defer _ = std.c.chmod(objects_dir_z, 0o755);
    const fetcher = try Fetcher.create(std.testing.allocator, io, cache, try server.url(allocator), local.storage, &fixture.env);
    defer fetcher.release();

    // A window fetch of `next` is in flight when the guest reads `next`.
    try fetcher.fetchObject(&read.digest, try allocator.alloc(u8, read.len), &.{next});
    while (server.requests.load(.monotonic) < 2) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    const Releaser = struct {
        fn run(test_server: *TestServer) void {
            std.Io.sleep(std.testing.io, .fromMilliseconds(100), .awake) catch {};
            test_server.releaseHeld();
        }
    };
    const releaser = try std.Thread.spawn(.{}, Releaser.run, .{&server});
    defer releaser.join();
    const buf = try allocator.alloc(u8, next.len);
    try fetcher.fetchObject(&next.digest, buf, &.{});
    try std.testing.expect((try chunk.ChunkId.fromDigest(&next.digest)).matches(buf));
    try std.testing.expect(!fetcher.readFailed());
    try awaitWindows(fetcher);
    try std.testing.expectEqual(@as(u32, 3), server.requests.load(.monotonic));
}

test "filling a cache that already holds every object fetches nothing" {
    var fixture: TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const store = try fixture.path("store");
    _ = try fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/1", .{store}));
    const cache = try fixture.path("cache");
    const local = try resolve(io, allocator, cache, try std.fmt.allocPrint(allocator, "file://{s}/1", .{store}), .{}, &fixture.env);
    const first = try Fetcher.create(std.testing.allocator, io, cache, local.origin.?, local.storage, &fixture.env);
    defer first.release();
    try first.fetchAll();
    try std.testing.expectEqual(@as(u64, 3), first.currentStats().fetches);
    // A second VM on the image saves after the first fetched everything.
    const second = try Fetcher.create(std.testing.allocator, io, cache, local.origin.?, local.storage, &fixture.env);
    defer second.release();
    try second.fetchAll();
    try std.testing.expectEqual(@as(u64, 0), second.currentStats().fetches);
}

test "file store reads only regular files and never waits for a FIFO writer" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.createDirPath(io, "tags/dir");
    try tmp.dir.writeFile(io, .{ .sub_path = "tags/1", .data = "blake3:" ++ test_support.repeat("a", 64) ++ "\n" });
    const fifo = try std.fs.path.joinZ(allocator, &.{ root, "tags", "fifo" });
    defer allocator.free(fifo);
    const c = struct {
        extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
    };
    try std.testing.expectEqual(@as(c_int, 0), c.mkfifo(fifo, 0o600));

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var client = try Client.init(allocator, io, root, &env);
    defer client.deinit();
    const budget = Budget{ .attempts = 1, .attempt_ms = 1_000, .total_ms = 1_000 };
    const bytes = try client.get(allocator, "tags/1", .{ .max = tag_file_len }, budget);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("blake3:" ++ test_support.repeat("a", 64), try parseTag(bytes));
    try std.testing.expectError(error.ImageStoreBadResponse, client.get(allocator, "tags/fifo", .{ .max = tag_file_len }, budget));
    try std.testing.expectError(error.ImageStoreBadResponse, client.get(allocator, "tags/dir", .{ .max = tag_file_len }, budget));
    try std.testing.expectError(error.ImageStoreNotFound, client.get(allocator, "tags/2", .{ .max = tag_file_len }, budget));
    try std.testing.expectError(error.ImageStoreBadResponse, client.get(allocator, "tags/1", .{ .max = tag_file_len - 1 }, budget));
}
