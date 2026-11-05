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
