//! Full image acquisition without a VM, and native-image ext4 export.
const std = @import("std");
const Io = std.Io;
const local_image = @import("local_image.zig");
const local_paths = @import("local_paths.zig");
const image_store = @import("image_store.zig");
const rootfs = @import("rootfs.zig");
const rootfs_input = @import("rootfs_input.zig");
const rootfs_cas = @import("rootfs_cas.zig");

pub const Options = struct {
    source: []const u8,
    tag: ?[]const u8 = null,
    platform: ?rootfs.Platform = null,
};

pub const Result = struct {
    schema: []const u8 = "spore.image.pull.result.v1",
    schema_version: u32 = 1,
    image_digest: []const u8,
    digest_ref: []const u8,
    tag_ref: ?[]const u8,
    platform: rootfs.Platform,
};

/// Uses the caller's arena. The image record roots the complete closure;
/// explicit image prune may remove it, just as it may remove a built image.
pub fn pull(init: std.process.Init, allocator: std.mem.Allocator, options: Options) !Result {
    const local = try acquire(init, allocator, options);
    return .{
        .image_digest = local.identity,
        .digest_ref = try local_image.resolvedRefAlloc(allocator, options.tag orelse "local/pulled", local.identity, null),
        .tag_ref = options.tag,
        .platform = local.platform,
    };
}

fn acquire(init: std.process.Init, allocator: std.mem.Allocator, options: Options) !local_image.LocalImage {
    if (options.tag) |tag| try rootfs.validateLocalTagRef(tag);
    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    try Io.Dir.cwd().createDirPath(init.io, cache_root);
    const local = if (image_store.isStoreRef(options.source))
        try image_store.resolve(init.io, allocator, cache_root, options.source, options.platform, init.environ_map)
    else if (rootfs.isLocalImageRef(options.source)) blk: {
        const platform = try local_image.selectPlatform(init.io, allocator, cache_root, options.source, options.platform);
        const identity = (try local_image.lookup(init.io, allocator, cache_root, options.source, platform)) orelse return error.FileNotFound;
        const found = (try local_image.loadAllowingOrigin(init.io, allocator, cache_root, identity)) orelse return error.FileNotFound;
        if (found.platform.arch != platform.arch or !std.mem.eql(u8, found.platform.os, platform.os)) return error.UnsupportedPlatform;
        break :blk found;
    } else blk: {
        const platform = options.platform orelse rootfs.native_platform;
        // Pull refreshes registry tags; immutable conversions may be reused.
        const pinned = try rootfs.digestPinnedImageIdentity(allocator, options.source, platform);
        const resolved = pinned orelse try rootfs.resolveImageRef(init, allocator, options.source, platform);
        break :blk try rootfs_input.pulledImage(init, allocator, cache_root, resolved, if (pinned == null) options.source else null);
    };

    // Resolution publishes an index and image record. Hold the cache lock
    // through fill and complete publication, preventing GC/prune from removing
    // objects while they are installed but not yet rooted as a full image.
    var lock = try rootfs.lockRootfsCacheExclusive(init.io, allocator, cache_root);
    defer lock.deinit();
    if (local.origin) |origin| {
        const fetcher = try image_store.Fetcher.create(init.gpa, init.io, cache_root, origin, local.storage, init.environ_map);
        defer fetcher.release();
        try fetcher.fetchAll();
    }
    _ = try local_image.publish(init.io, allocator, cache_root, &lock, .{
        .platform = local.platform,
        .config = local.config,
        .storage = local.storage,
        .oci = local.oci,
        .expected_identity = local.identity,
        .name = options.tag,
    });
    return (try local_image.load(init.io, allocator, cache_root, local.identity)) orelse error.LocalImageStorageUnavailable;
}

/// Existing files, including dangling symlinks, are never export destinations.
fn requireNewOutput(io: Io, path: []const u8) !void {
    _ = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.PathAlreadyExists;
}

/// Registry export keeps its existing OCI sidecar. Native export records native
/// identity/config/storage instead of inventing OCI layer history.
pub fn exportRootfs(init: std.process.Init, allocator: std.mem.Allocator, request: rootfs.BuildRequest) !rootfs.BuildResult {
    try requireNewOutput(init.io, request.output);
    try requireNewOutput(init.io, request.metadata);
    if (!rootfs.isLocalImageRef(request.ref) and !image_store.isStoreRef(request.ref))
        return rootfs.build(init, allocator, request);

    const local = try acquire(init, allocator, .{ .source = request.ref, .platform = request.platform });
    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    var lock = try rootfs.lockRootfsCacheExclusive(init.io, allocator, cache_root);
    defer lock.deinit();
    const storage = local.storage;
    try rootfs_cas.exportFlatFromChunks(init.io, allocator, cache_root, .{
        .device = storage.device,
        .artifact = .{ .digest = storage.index_digest, .size = storage.logical_size },
        .storage = storage,
    }, request.output);
    errdefer Io.Dir.cwd().deleteFile(init.io, request.output) catch {};
    const metadata = try std.json.Stringify.valueAlloc(allocator, .{
        .schema = "spore.rootfs.export.metadata.v1",
        .schema_version = @as(u32, 1),
        .image_ref = request.ref,
        .image_digest = local.identity,
        .platform = local.platform,
        .config = local.config,
        .rootfs_path = request.output,
        .rootfs_size = storage.logical_size,
        .rootfs_storage = storage,
    }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    if (std.fs.path.dirname(request.metadata)) |parent| try Io.Dir.cwd().createDirPath(init.io, parent);
    var sidecar = try Io.Dir.cwd().createFileAtomic(init.io, request.metadata, .{ .replace = false });
    defer sidecar.deinit(init.io);
    try sidecar.file.writeStreamingAll(init.io, metadata);
    try sidecar.link(init.io);
    return .{ .rootfs_storage = storage, .platform = local.platform };
}

test "image pull fills a cold cache for offline native export without aliasing cache bytes" {
    var fixture: image_store.TestImage = undefined;
    try fixture.init(.{ .arch = .arm64 });
    defer fixture.deinit();
    const a = fixture.arena.allocator();
    const io = std.testing.io;
    var init = fixture.processInit();
    init.gpa = std.testing.allocator;
    const store = try fixture.path("store");
    _ = try fixture.pushTo(try std.fmt.allocPrint(a, "{s}/app", .{store}));
    const consumer = try fixture.path("consumer-cache");
    try fixture.env.put(local_paths.rootfs_cache_env, consumer);
    const result = try pull(init, a, .{
        .source = try std.fmt.allocPrint(a, "file://{s}/app", .{store}),
        .tag = "local/offline:1",
    });
    try std.testing.expectEqualStrings(fixture.identity, result.image_digest);
    try std.testing.expectEqual(.arm64, result.platform.arch);
    const local = (try local_image.load(io, a, consumer, result.image_digest)).?;
    try std.testing.expectEqual(null, local.origin);
    try Io.Dir.cwd().deleteTree(io, store);
    // The returned local ref, not the former store URL, is an offline input.
    _ = try pull(init, a, .{ .source = result.digest_ref });
    try std.testing.expectError(error.UnsupportedPlatform, pull(init, a, .{
        .source = result.digest_ref,
        .platform = .{ .arch = .amd64 },
    }));
    const output = try fixture.path("export.ext4");
    const metadata = try fixture.path("export.json");
    _ = try exportRootfs(init, a, .{ .ref = result.digest_ref, .output = output, .metadata = metadata });
    try std.testing.expectEqualSlices(u8, fixture.rootfs_bytes, try Io.Dir.cwd().readFileAlloc(io, output, a, .limited(fixture.rootfs_bytes.len + 1)));
    try std.testing.expectError(error.PathAlreadyExists, exportRootfs(init, a, .{ .ref = result.digest_ref, .output = output, .metadata = metadata }));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = output, .data = "caller mutation" });
    const second = try fixture.path("second.ext4");
    _ = try exportRootfs(init, a, .{ .ref = result.digest_ref, .output = second, .metadata = try fixture.path("second.json") });
    try std.testing.expectEqualSlices(u8, fixture.rootfs_bytes, try Io.Dir.cwd().readFileAlloc(io, second, a, .limited(fixture.rootfs_bytes.len + 1)));
    const sidecar = try Io.Dir.cwd().readFileAlloc(io, metadata, a, .limited(1 << 20));
    var parsed = try std.json.parseFromSlice(std.json.Value, a, sidecar, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(fixture.identity, parsed.value.object.get("image_digest").?.string);
    try std.testing.expect(parsed.value.object.get("layers") == null);
}

test "image pull rejects corrupt store content before publishing the requested tag" {
    var fixture: image_store.TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const a = fixture.arena.allocator();
    const io = std.testing.io;
    var init = fixture.processInit();
    init.gpa = std.testing.allocator;
    const store = try fixture.path("store");
    _ = try fixture.pushTo(try std.fmt.allocPrint(a, "{s}/app", .{store}));
    for (try fixture.listStore(store)) |path| {
        if (!std.mem.startsWith(u8, path, "objects/")) continue;
        const full = try std.fs.path.join(a, &.{ store, path });
        const bytes = try Io.Dir.cwd().readFileAlloc(io, full, a, .limited(1 << 20));
        bytes[0] ^= 0xff;
        try @import("chunk_sealer.zig").replaceFileAtomicDurable(a, full, bytes, 0o644);
        break;
    }
    const consumer = try fixture.path("consumer-cache");
    try fixture.env.put(local_paths.rootfs_cache_env, consumer);
    try std.testing.expectError(error.BadChunk, pull(init, a, .{
        .source = try std.fmt.allocPrint(a, "file://{s}/app", .{store}),
        .tag = "local/rejected:1",
    }));
    try std.testing.expectEqual(null, try local_image.lookup(io, a, consumer, "local/rejected:1", .{}));
    try std.testing.expectEqual(null, try local_image.load(io, a, consumer, fixture.identity));
}
