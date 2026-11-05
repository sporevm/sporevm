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
//! Store bytes are untrusted. A tag only names an image digest; the metadata
//! must recompute that digest, and an object must match the BLAKE3 digest the
//! verified index names before it is cached or reaches the guest.

const std = @import("std");
const Io = std.Io;
const chunk = @import("chunk.zig");
const chunk_sealer = @import("chunk_sealer.zig");
const disk_index = @import("disk_index.zig");
const image = @import("image.zig");
const image_archive = @import("image_archive.zig");
const image_manifest = @import("image_manifest.zig");
const local_image = @import("local_image.zig");
const local_paths = @import("local_paths.zig");
const resource = @import("resource.zig");
const rootfs = @import("rootfs.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const spore = @import("spore.zig");

const digest_prefix = image.digest_prefix;
const digest_len = digest_prefix.len + chunk.ChunkId.hex_len;
pub const tag_file_len = digest_len + 1;
const max_tag_len = 128;

pub const Scheme = enum { file, http, https };

/// Where a store lives: an absolute directory (`/srv/images` or
/// `file:///srv/images`) or an HTTP(S) URL prefix. `url` is the base as
/// written, without a trailing slash; `dir` is the directory of a file store.
pub const Base = struct {
    scheme: Scheme,
    url: []const u8,
    dir: []const u8 = "",
    loopback: bool = false,
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
    const host = uri.getHost(&host_buffer) catch return error.InvalidImageStoreRef;
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

fn objectPathAlloc(allocator: std.mem.Allocator, digest: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "objects/blake3/{s}", .{digest[digest_prefix.len..]});
}

fn imagePathAlloc(allocator: std.mem.Allocator, identity: []const u8, file: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "images/{s}/{s}", .{ identity[digest_prefix.len..], file });
}

pub const PushOptions = struct {
    source: []const u8,
    destination: []const u8,
    platform: rootfs.Platform,
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

/// Write the complete local image `source` into a directory store: objects,
/// then the image's manifest, config and index, then the tag. Objects already
/// present with the right bytes are kept, so pushing again writes nothing and
/// pushing another tag writes only that tag.
pub fn push(init: std.process.Init, allocator: std.mem.Allocator, options: PushOptions) !PushResult {
    try rootfs.validateLocalTagRef(options.source);
    const destination = try parseStoreRef(options.destination);
    if (destination.base.scheme != .file) return error.ImageStorePushNeedsDirectory;

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

    const dir = destination.base.dir;
    const objects_dir = try std.fs.path.join(allocator, &.{ dir, "objects", "blake3" });
    defer allocator.free(objects_dir);
    try chunk_sealer.ensureDirPath(allocator, objects_dir);
    var written: usize = 0;
    var bytes_written: u64 = 0;
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
            error.BadChunk, error.ShortRead => try Io.Dir.cwd().deleteFile(init.io, path),
            else => |e| return e,
        }
        const bytes = try rootfs_cas.readVerifiedManifestObject(allocator, cache_root, object.digest, object.size);
        defer allocator.free(bytes);
        _ = try chunk_sealer.writePathAllIfMissingTimedForBatch(allocator, path, bytes, &work_stats);
        written += 1;
        bytes_written += object.size;
    }
    if (written != 0) try chunk_sealer.fsyncDirPath(allocator, objects_dir);

    const image_files = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "manifest", .bytes = closure.manifest.bytes },
        .{ .name = "config", .bytes = closure.config_bytes },
        .{ .name = "index", .bytes = closure.index_bytes },
    };
    for (image_files) |file| {
        const relative = try imagePathAlloc(allocator, closure.image_digest, file.name);
        defer allocator.free(relative);
        const path = try std.fs.path.join(allocator, &.{ dir, relative });
        defer allocator.free(path);
        chunk_sealer.writeFileAtomicDurable(allocator, path, file.bytes, 0o444) catch |err| switch (err) {
            // Metadata is named by the image digest; different bytes mean
            // a damaged store file, so replace it.
            error.BadChunk => try chunk_sealer.replaceFileAtomicDurable(allocator, path, file.bytes, 0o444),
            else => |e| return e,
        };
    }
    switch (destination.target) {
        .tag => |name| {
            const path = try std.fs.path.join(allocator, &.{ dir, "tags", name });
            defer allocator.free(path);
            const tag_bytes = try std.fmt.allocPrint(allocator, "{s}\n", .{closure.image_digest});
            defer allocator.free(tag_bytes);
            try chunk_sealer.replaceFileAtomicDurable(allocator, path, tag_bytes, 0o644);
        },
        .digest => {},
    }

    // The `file://` form, which `spore run --image` takes as a store ref.
    const ref = try std.fmt.allocPrint(allocator, "file://{s}/{s}", .{ dir, switch (destination.target) {
        .tag => |name| name,
        .digest => |digest| digest,
    } });
    errdefer allocator.free(ref);
    return .{
        .ref = ref,
        .image_digest = try allocator.dupe(u8, closure.image_digest),
        .objects_total = closure.objects.len,
        .objects_written = written,
        .bytes_written = bytes_written,
    };
}

pub fn deinitPushResult(allocator: std.mem.Allocator, result: PushResult) void {
    allocator.free(result.ref);
    allocator.free(result.image_digest);
}

/// Resolve the store ref `raw` to a local image for `platform`, fetching and
/// verifying its manifest, config and index if this cache has none, and
/// recording the store as the origin of objects still missing locally. A tag
/// is read from the store every time; a digest is not when the image is local.
/// Allocates into `allocator`; use an arena.
pub fn resolve(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    raw: []const u8,
    platform: rootfs.Platform,
) !local_image.LocalImage {
    const ref = try parseStoreRef(raw);
    var client = try Client.init(allocator, io, ref.base.url);
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
/// An object read holds the VMM device lock, so every vCPU may wait for it.
/// Stay well under the guest's 20 s soft-lockup watchdog; a failed read
/// poisons the disk, which then fetches nothing more.
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
    OutOfMemory,
};

/// Reads files from one store. Requests are bounded by size and time; an
/// HTTP(S) request runs on an `Io` worker that is canceled at its deadline.
/// Thread-safe: concurrent requests share the connection pool.
pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    base: Base,
    http: std.http.Client,

    /// `allocator` must be thread-safe: requests run on `Io` workers.
    pub fn init(allocator: std.mem.Allocator, io: Io, base_url: []const u8) !Client {
        const url = try allocator.dupe(u8, base_url);
        errdefer allocator.free(url);
        const base = try parseBase(url);
        var http: std.http.Client = .{ .allocator = allocator, .io = io };
        errdefer http.deinit();
        if (base.scheme == .https) {
            // Load CA certificates now rather than on a guest fault.
            const now = Io.Clock.real.now(io);
            http.ca_bundle.rescan(allocator, io, now) catch return error.CertificateBundleLoadFailure;
            http.now = now;
        }
        return .{ .allocator = allocator, .io = io, .base = base, .http = http };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
        self.allocator.free(self.base.url);
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
                    self.io.sleep(.fromMilliseconds(@intCast(backoff_ms)), .awake) catch return err;
                },
                else => return err,
            }
        }
    }

    fn getOnce(self: *Client, allocator: std.mem.Allocator, path: []const u8, limit: Limit, timeout_ms: u64) GetError![]u8 {
        if (self.base.scheme == .file) return self.readFile(allocator, path, limit);
        const url = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.base.url, path });
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
        while (!attempt.done.isSet()) {
            attempt.done.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
                error.Timeout => if (Io.Clock.awake.now(io).nanoseconds >= deadline.raw.nanoseconds) {
                    timed_out = true;
                    break;
                },
                else => break,
            };
        }
        // Canceling interrupts a blocked socket call; the request then
        // closes its connection instead of returning it to the pool.
        future.cancel(io) catch {};
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
        if (self.base.scheme == .https) {
            self.http.ca_bundle_lock.lockUncancelable(self.io);
            defer self.http.ca_bundle_lock.unlock(self.io);
            self.http.now = Io.Clock.real.now(self.io);
        }
        var request = try self.http.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{ .accept_encoding = .omit },
        });
        defer request.deinit();
        try request.sendBodiless();
        var no_redirects: [0]u8 = undefined;
        var response = try request.receiveHead(&no_redirects);
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
};

/// Store reads at once while `Fetcher.fetchAll` fills the cache.
pub const fill_concurrency = 16;

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

    /// `allocator` must be thread-safe: faults run on vCPU threads and
    /// requests on `Io` workers.
    pub fn create(allocator: std.mem.Allocator, io: Io, cache_root: []const u8, origin: []const u8, storage: spore.RootfsStorage) !*Fetcher {
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
            .client = try Client.init(allocator, io, origin),
        };
        return self;
    }

    pub fn retain(self: *Fetcher) *Fetcher {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn release(self: *Fetcher) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const stats = self.stats;
        std.log.debug("image store {s}: fetched {d} objects, {d} bytes in {d} ms; {d} errors, {d} install errors", .{
            self.client.base.url, stats.fetches, stats.bytes, stats.fetch_ns / std.time.ns_per_ms, stats.errors, stats.install_errors,
        });
        self.client.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn currentStats(self: *Fetcher) FetchStats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.stats;
    }

    /// Fill `buf` with the object `digest` names for a guest read, verified
    /// against its BLAKE3 digest; its length is `buf.len`. The caller has found
    /// it missing locally. A failed local install is counted, not returned:
    /// the bytes are already verified.
    pub fn fetchObject(self: *Fetcher, digest: []const u8, buf: []u8) (GetError || error{BadChunk})!void {
        const bytes = self.fetchVerified(digest, buf.len) catch |err| {
            self.read_failed.store(true, .release);
            return err;
        };
        defer self.allocator.free(bytes);
        @memcpy(buf, bytes);
        self.install(digest, bytes) catch {};
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
        var fill = Fill{ .fetcher = self, .objects = missing };
        var group: Io.Group = .init;
        // This thread is one of the workers.
        for (1..@min(fill_concurrency, missing.len)) |_| {
            group.concurrent(self.io, Fill.run, .{&fill}) catch break;
        }
        Fill.run(&fill) catch {};
        group.await(self.io) catch {};
        if (fill.err) |err| return err;
        self.complete.store(true, .release);
        std.log.info("image store {s}: fetched the root disk's {d} missing objects in {d} ms", .{ self.client.base.url, missing.len, (monotonicNs() -| start_ns) / std.time.ns_per_ms });
    }

    const Object = struct {
        digest: []const u8,
        len: usize,
    };

    const Fill = struct {
        fetcher: *Fetcher,
        objects: []const Object,
        next: std.atomic.Value(usize) = .init(0),
        failed: std.atomic.Value(bool) = .init(false),
        /// The first failure; guarded by `fetcher.mutex`.
        err: ?anyerror = null,

        fn run(fill: *Fill) Io.Cancelable!void {
            while (!fill.failed.load(.acquire)) {
                if (fill.fetcher.canceled.load(.acquire)) return fill.fail(error.ImageStoreFetchCanceled);
                const i = fill.next.fetchAdd(1, .monotonic);
                if (i >= fill.objects.len) return;
                const object = fill.objects[i];
                const bytes = fill.fetcher.fetchVerified(object.digest, object.len) catch |err| return fill.fail(err);
                defer fill.fetcher.allocator.free(bytes);
                fill.fetcher.install(object.digest, bytes) catch |err| return fill.fail(err);
            }
        }

        fn fail(fill: *Fill, err: anyerror) void {
            fill.fetcher.mutex.lockUncancelable(fill.fetcher.io);
            defer fill.fetcher.mutex.unlock(fill.fetcher.io);
            if (fill.err == null) fill.err = err;
            fill.failed.store(true, .release);
        }
    };

    /// The distinct objects of the storage's index that are not in the local
    /// CAS at their indexed length.
    fn missingObjects(self: *Fetcher, arena: std.mem.Allocator) ![]const Object {
        const index_path = try rootfs_cas.manifestIndexPath(arena, self.cache_root, self.storage.index_digest);
        const bytes = try rootfs_cas.readVerifiedStorageIndexPath(arena, index_path, self.storage);
        const parsed = try disk_index.parseDiskIndex(arena, bytes, try spore.diskIndexDescriptorForStorage(self.storage));
        var seen = std.AutoHashMap(chunk.ChunkId, void).init(arena);
        var missing: std.ArrayList(Object) = .empty;
        for (parsed.value.chunks) |entry| {
            if ((try seen.getOrPut(entry.id)).found_existing) continue;
            const len = try rootfs_cas.storageChunkLen(self.storage, entry.logical_chunk);
            const digest = try arena.dupe(u8, &entry.id.toDigest());
            const path = try rootfs_cas.manifestObjectPath(self.allocator, self.cache_root, digest);
            defer self.allocator.free(path);
            const stat = Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => null,
                else => |e| return e,
            };
            if (stat) |value| if (value.kind == .file and value.size == len) continue;
            try missing.append(arena, .{ .digest = digest, .len = len });
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
    const digest = "blake3:" ++ "0123456789abcdef" ** 4;
    try std.testing.expectEqualStrings(digest, try parseTag(digest ++ "\n"));
    for ([_][]const u8{
        digest,
        digest ++ "\n\n",
        digest ++ " \n",
        "blake3:" ++ "0123456789ABCDEF" ** 4 ++ "\n",
        "sha256:" ++ "0123456789abcdef" ** 4 ++ "\n",
        "",
    }) |bytes| try std.testing.expectError(error.BadImageStoreTag, parseTag(bytes));
}

test "image store refs name a store and a tag or digest" {
    const digest = "blake3:" ++ "a" ** 64;
    const Case = struct { raw: []const u8, scheme: Scheme, url: []const u8, dir: []const u8 = "", tag: ?[]const u8 = null };
    for ([_]Case{
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
        if (case.tag) |tag| {
            try std.testing.expectEqualStrings(tag, ref.target.tag);
        } else try std.testing.expectEqualStrings(digest, ref.target.digest);
    }

    const Rejected = struct { raw: []const u8, err: anyerror };
    for ([_]Rejected{
        .{ .raw = "http://images.example.test/app", .err = error.InsecureImageStoreTag },
        .{ .raw = "http://localhost:8000/app", .err = error.InsecureImageStoreTag },
        .{ .raw = "s3://bucket/app", .err = error.UnsupportedImageStoreScheme },
        .{ .raw = "relative/store/app", .err = error.UnsupportedImageStoreScheme },
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
        .{ .raw = "/srv/store/" ++ "a" ** (max_tag_len + 1), .err = error.InvalidImageStoreTag },
        .{ .raw = "/srv/store/blake3:" ++ "A" ** 64, .err = error.InvalidImageStoreRef },
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
    try std.testing.expectError(error.ImageIdentityMismatch, fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/blake3:{s}", .{ store, "b" ** 64 })));
    try std.testing.expectError(error.ImageStorePushNeedsDirectory, fixture.pushTo("https://images.example.test/app"));
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

    const local = try resolve(io, allocator, consumer, ref, platform);
    try std.testing.expectEqualStrings(fixture.identity, local.identity);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "file://{s}", .{store}), local.origin.?);
    try std.testing.expect(!try rootfs_cas.storageMarkedComplete(io, allocator, consumer, local.storage));
    const objects_dir = try std.fs.path.join(allocator, &.{ consumer, "cas", "rootfs", "blake3", "objects" });
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, objects_dir, .{}));
    try std.testing.expectError(error.UnsupportedPlatform, resolve(io, allocator, consumer, ref, .{ .arch = .amd64 }));

    // A digest ref of a local image needs no store.
    const digest_ref = try std.fmt.allocPrint(allocator, "file://{s}/missing/{s}", .{ store, fixture.identity });
    const by_digest = try resolve(io, allocator, consumer, digest_ref, platform);
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
        try std.testing.expectError(error.BadProtocol, resolve(io, allocator, tampered_cache, try std.fmt.allocPrint(allocator, "{s}/1", .{tampered_store}), platform));
        try std.testing.expectEqual(null, try local_image.loadAllowingOrigin(io, allocator, tampered_cache, fixture.identity));
    }
    const missing_cache = try fixture.path("missing-cache");
    try std.testing.expectError(error.ImageStoreNotFound, resolve(io, allocator, missing_cache, try std.fmt.allocPrint(allocator, "{s}/2", .{store}), platform));
}

/// Test support: serves files from `root` over HTTP/1.1 on loopback, one
/// connection at a time. `failures` answers that many requests with 500
/// first; `hang` holds every request open until `deinit`; `delay_ms` delays
/// every answer, reading the file after the delay.
pub const TestServer = struct {
    allocator: std.mem.Allocator,
    io: Io,
    root: []const u8,
    server: Io.net.Server,
    thread: std.Thread,
    closed: std.atomic.Value(bool) = .init(false),
    failures: std.atomic.Value(u32) = .init(0),
    requests: std.atomic.Value(u32) = .init(0),
    hang: std.atomic.Value(bool) = .init(false),
    delay_ms: std.atomic.Value(u32) = .init(0),

    pub fn start(self: *TestServer, allocator: std.mem.Allocator, io: Io, root: []const u8) !void {
        var address = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
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
        self.server.deinit(self.io);
    }

    pub fn url(self: *TestServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{self.server.socket.address.getPort()});
    }

    fn serve(self: *TestServer) void {
        while (!self.closed.load(.acquire)) {
            const stream = self.server.accept(self.io) catch continue;
            defer stream.close(self.io);
            if (self.closed.load(.acquire)) return;
            self.handle(stream) catch {};
        }
    }

    fn handle(self: *TestServer, stream: Io.net.Stream) !void {
        var read_buffer: [8 * 1024]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        const request_line = std.mem.trimEnd(u8, try reader.interface.takeDelimiterExclusive('\n'), "\r");
        const path = request_line["GET ".len..std.mem.lastIndexOfScalar(u8, request_line, ' ').?];
        const file_path = try std.fs.path.join(self.allocator, &.{ self.root, path[1..] });
        defer self.allocator.free(file_path);
        while (std.mem.trimEnd(u8, try reader.interface.takeDelimiterExclusive('\n'), "\r").len != 0) {}
        _ = self.requests.fetchAdd(1, .monotonic);
        std.Io.sleep(self.io, .fromMilliseconds(self.delay_ms.load(.monotonic)), .awake) catch {};
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
    try server.start(std.testing.allocator, io, store);
    defer server.stop();
    var client = try Client.init(std.testing.allocator, io, try server.url(allocator));
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

test "file store reads only regular files and never waits for a FIFO writer" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.createDirPath(io, "tags/dir");
    try tmp.dir.writeFile(io, .{ .sub_path = "tags/1", .data = "blake3:" ++ "a" ** 64 ++ "\n" });
    const fifo = try std.fs.path.joinZ(allocator, &.{ root, "tags", "fifo" });
    defer allocator.free(fifo);
    const c = struct {
        extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
    };
    try std.testing.expectEqual(@as(c_int, 0), c.mkfifo(fifo, 0o600));

    var client = try Client.init(allocator, io, root);
    defer client.deinit();
    const budget = Budget{ .attempts = 1, .attempt_ms = 1_000, .total_ms = 1_000 };
    const bytes = try client.get(allocator, "tags/1", .{ .max = tag_file_len }, budget);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("blake3:" ++ "a" ** 64, try parseTag(bytes));
    try std.testing.expectError(error.ImageStoreBadResponse, client.get(allocator, "tags/fifo", .{ .max = tag_file_len }, budget));
    try std.testing.expectError(error.ImageStoreBadResponse, client.get(allocator, "tags/dir", .{ .max = tag_file_len }, budget));
    try std.testing.expectError(error.ImageStoreNotFound, client.get(allocator, "tags/2", .{ .max = tag_file_len }, budget));
    try std.testing.expectError(error.ImageStoreBadResponse, client.get(allocator, "tags/1", .{ .max = tag_file_len - 1 }, budget));
}
