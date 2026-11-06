//! Saved spores in an image store. `spore push` writes the manifest to
//! `spores/<hex>`, where `hex` is its BLAKE3, and the RAM chunks, the disk
//! index and the disk objects to the store's shared `objects/blake3/`, so a
//! spore's unchanged disk chunks dedupe against its image.

const std = @import("std");
const Io = std.Io;
const chunk = @import("chunk.zig");
const Context = @import("context.zig").Context;
const image_store = @import("image_store.zig");
const local_paths = @import("local_paths.zig");
const resource = @import("resource.zig");
const rootfs = @import("rootfs.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const saved_spore_pin = @import("saved_spore_pin.zig");
const spore = @import("spore.zig");

pub const PushOptions = struct {
    spore_dir: []const u8,
    destination: []const u8,
    /// Uploads to an S3 store.
    aws_executable: []const u8 = "aws",
};

pub const PushResult = struct {
    schema: []const u8 = "spore.push.result.v2",
    schema_version: u32 = 2,
    resource_type: resource.Type = .checkpoint,
    /// The digest-pinned ref of the pushed spore.
    ref: []const u8,
    spore_digest: []const u8,
    objects_total: usize,
    objects_written: usize,
    bytes_written: u64,
};

/// Push the saved spore in `spore_dir` to a directory or S3 store: its RAM
/// chunks, disk index and disk objects, then its manifest without the
/// host-local RAM backing, then the tag. The rootfs cache or, for a portable
/// spore, the spore directory must hold the complete disk. A spore with a
/// rootfs must have a disk, as every save of one does: a pin roots only a
/// disk's storage.
pub fn push(context: Context, allocator: std.mem.Allocator, options: PushOptions) !PushResult {
    const destination = try image_store.parsePushDestination(options.destination);
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parsed = try spore.loadManifest(arena, options.spore_dir);
    defer parsed.deinit();
    var manifest = parsed.value;
    // A host path the receiving host must not use; chunks hold the RAM.
    manifest.memory.backing = null;
    const manifest_bytes = try spore.encodeManifestAlloc(arena, manifest);
    const digest = chunk.ChunkId.fromContents(manifest_bytes).toDigest();
    switch (destination.target) {
        .digest => |expected| if (!std.mem.eql(u8, expected, &digest)) return error.SporeIdentityMismatch,
        .tag => {},
    }
    const disk = manifest.disk orelse if (manifest.rootfs != null) return error.SporeRootfsWithoutDisk else null;

    const cache_root = try local_paths.rootfsCacheRootPath(arena, context.environ_map);
    var cache_lock = try rootfs.lockRootfsCacheExclusive(context.io, arena, cache_root);
    defer cache_lock.deinit();

    var objects: std.ArrayList(image_store.PushObject) = .empty;
    var seen: std.AutoHashMapUnmanaged(chunk.ChunkId, void) = .empty;
    const memory = manifest.memory;
    for (memory.chunks) |entry| {
        if ((try seen.getOrPut(arena, entry.id)).found_existing) continue;
        const start = std.math.mul(u64, entry.logical_chunk, memory.chunk_size) catch return error.BadManifest;
        if (start >= memory.logical_size) return error.BadManifest;
        try objects.append(arena, .{
            .digest = try arena.dupe(u8, &entry.id.toDigest()),
            .size = std.math.cast(usize, @min(memory.chunk_size, memory.logical_size - start)) orelse return error.BadManifest,
            .path = try std.fmt.allocPrint(arena, "{s}/chunks/{s}", .{ options.spore_dir, &entry.id.toHex() }),
        });
    }
    if (disk) |saved_disk| {
        const storage = try saved_spore_pin.storageForDisk(saved_disk);
        // A portable spore carries its disk in its own CAS.
        const root = if (try saved_spore_pin.hasLocalIndex(context.io, arena, options.spore_dir, saved_disk)) options.spore_dir else cache_root;
        if (!try rootfs_cas.storageContentComplete(context.io, arena, root, storage)) return error.SporeStorageIncomplete;
        const index_path = try rootfs_cas.manifestIndexPath(arena, root, storage.index_digest);
        const index = try rootfs_cas.readStorageIndexPath(arena, index_path, storage);
        defer index.deinit();
        const index_id = chunk.ChunkId.fromDigest(storage.index_digest) catch return error.BadManifest;
        if (!(try seen.getOrPut(arena, index_id)).found_existing) {
            try objects.append(arena, .{ .digest = storage.index_digest, .size = index.bytes.len, .path = index_path });
        }
        for (index.parsed.value.chunks) |entry| {
            if ((try seen.getOrPut(arena, entry.id)).found_existing) continue;
            try objects.append(arena, .{
                .digest = try arena.dupe(u8, &entry.id.toDigest()),
                .size = try rootfs_cas.storageChunkLen(storage, entry.logical_chunk),
                .path = try rootfs_cas.objectPath(arena, root, entry.id),
            });
        }
    }

    const files = [_]image_store.PushFile{.{ .path = digest[chunk.ChunkId.digest_prefix.len..], .bytes = manifest_bytes }};
    const written = try image_store.pushClosure(context.io, arena, options.aws_executable, destination, cache_root, &cache_lock, .{
        .digest = &digest,
        .objects = objects.items,
        .files_dir = "spores",
        .files = &files,
        .tags_dir = "spore-tags",
    });
    const ref = try image_store.pushedRefAlloc(allocator, destination.base, &digest);
    errdefer allocator.free(ref);
    return .{
        .ref = ref,
        .spore_digest = try allocator.dupe(u8, &digest),
        .objects_total = objects.items.len,
        .objects_written = written.objects,
        .bytes_written = written.bytes,
    };
}

const manifest_test_support = @import("manifest_test_support.zig");

/// Test support: a saved spore in `<fixture>/saved` whose disk is the fixture
/// image with its first chunk changed, with a nonzero full RAM chunk, a
/// nonzero 19-byte tail chunk, and a RAM backing.
const TestSpore = struct {
    dir: []const u8,
    /// The changed disk chunk's object in the rootfs cache.
    disk_object: []const u8,
    index_len: u64,
};

fn saveTestSpore(fixture: *image_store.TestImage) !TestSpore {
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const cache = fixture.env.get(local_paths.rootfs_cache_env).?;
    const disk_bytes = try allocator.dupe(u8, fixture.rootfs_bytes);
    disk_bytes[0] ^= 0xff;
    const disk_path = try fixture.path("disk.ext4");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = disk_path, .data = disk_bytes });
    const preload = try rootfs_cas.preloadPath(io, allocator, cache, disk_path, rootfs_cas.default_chunk_size);
    const storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload);

    const dir = try fixture.path("saved");
    const ram = try allocator.alloc(u8, spore.chunk_size + 19);
    @memset(ram, 0);
    ram[3] = 1;
    ram[spore.chunk_size + 7] = 2;
    var manifest = manifest_test_support.manifest(.{});
    manifest.memory = try spore.saveMemoryWithBacking(allocator, dir, ram);
    manifest.platform.ram_size = ram.len;
    const devices = try allocator.alloc(spore.TransportState, 2);
    devices[0] = manifest_test_support.testTransport(3);
    devices[1] = manifest_test_support.testTransport(spore.rootfs_virtio_blk_device_id);
    manifest.devices = devices;
    manifest.rootfs = .{
        .device = storage.device,
        .artifact = .{ .digest = storage.index_digest, .size = storage.logical_size },
        .storage = storage,
    };
    manifest.disk = .{ .device = storage.device, .size = storage.logical_size, .base = storage.index_digest };
    try spore.saveManifest(allocator, dir, manifest);
    const changed = chunk.ChunkId.fromContents(disk_bytes[0..rootfs_cas.default_chunk_size]);
    return .{
        .dir = dir,
        .disk_object = try rootfs_cas.objectPath(allocator, cache, changed),
        .index_len = (try Io.Dir.cwd().statFile(io, try rootfs_cas.manifestIndexPath(allocator, cache, storage.index_digest), .{})).size,
    };
}

fn testPush(fixture: *image_store.TestImage, spore_dir: []const u8, destination: []const u8, aws: []const u8) !PushResult {
    return push(.{ .io = std.testing.io, .environ_map = &fixture.env }, fixture.arena.allocator(), .{
        .spore_dir = spore_dir,
        .destination = destination,
        .aws_executable = aws,
    });
}

test "spore push writes a spore once, without its RAM backing, and dedupes against its image" {
    var fixture: image_store.TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const saved = try saveTestSpore(&fixture);
    const store = try fixture.path("store");
    _ = try fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/app", .{store}));

    // Two RAM chunks, the disk index and three disk objects, of which the
    // image already wrote two.
    const first = try testPush(&fixture, saved.dir, try std.fmt.allocPrint(allocator, "{s}/warm", .{store}), "aws");
    try std.testing.expectEqual(@as(usize, 6), first.objects_total);
    try std.testing.expectEqual(@as(usize, 4), first.objects_written);
    try std.testing.expectEqual(spore.chunk_size + 19 + saved.index_len + rootfs_cas.default_chunk_size, first.bytes_written);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "file://{s}/{s}", .{ store, first.spore_digest }), first.ref);

    const hex = first.spore_digest[chunk.ChunkId.digest_prefix.len..];
    const bytes = try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(allocator, "{s}/spores/{s}", .{ store, hex }), allocator, .limited(spore.max_manifest_bytes));
    try std.testing.expectEqualStrings(hex, &chunk.ChunkId.fromContents(bytes).toHex());
    const pushed = try spore.parseManifest(allocator, bytes);
    try std.testing.expectEqual(null, pushed.value.memory.backing);
    try std.testing.expect((try spore.loadManifest(allocator, saved.dir)).value.memory.backing != null);
    const tag = try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(allocator, "{s}/spore-tags/warm", .{store}), allocator, .limited(128));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "{s}\n", .{first.spore_digest}), tag);
    try std.testing.expectEqualStrings(first.spore_digest, try image_store.parseTag(tag));

    const again = try testPush(&fixture, saved.dir, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ store, first.spore_digest }), "aws");
    try std.testing.expectEqualStrings(first.spore_digest, again.spore_digest);
    try std.testing.expectEqual(@as(usize, 0), again.objects_written);
    try std.testing.expectError(error.SporeIdentityMismatch, testPush(&fixture, saved.dir, try std.fmt.allocPrint(allocator, "{s}/blake3:{s}", .{ store, "b" ** 64 }), "aws"));
    try std.testing.expectError(error.ImageStorePushUnsupportedScheme, testPush(&fixture, saved.dir, "https://images.example.test/warm", "aws"));
}

test "spore push sends a spore without a rootfs and refuses an incomplete or missing disk" {
    var fixture: image_store.TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const saved = try saveTestSpore(&fixture);
    const store = try fixture.path("store");

    // Nothing reaches the store before the disk is known to be complete.
    try Io.Dir.cwd().deleteFile(io, saved.disk_object);
    try std.testing.expectError(error.SporeStorageIncomplete, testPush(&fixture, saved.dir, try std.fmt.allocPrint(allocator, "{s}/x", .{store}), "aws"));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, store, .{}));

    var parsed = try spore.loadManifest(allocator, saved.dir);
    parsed.value.disk = null;
    try spore.saveManifest(allocator, saved.dir, parsed.value);
    try std.testing.expectError(error.SporeRootfsWithoutDisk, testPush(&fixture, saved.dir, try std.fmt.allocPrint(allocator, "{s}/x", .{store}), "aws"));

    parsed.value.rootfs = null;
    parsed.value.devices = &.{};
    try spore.saveManifest(allocator, saved.dir, parsed.value);
    const pushed = try testPush(&fixture, saved.dir, try std.fmt.allocPrint(allocator, "{s}/ram-only", .{store}), "aws");
    try std.testing.expectEqual(@as(usize, 2), pushed.objects_total);
    try std.testing.expectEqual(@as(usize, 2), pushed.objects_written);
}

test "spore push to S3 uploads objects, then the manifest, then the tag" {
    var fixture: image_store.TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const saved = try saveTestSpore(&fixture);
    const aws = try fixture.fakeAws();
    const bucket = try fixture.path("bucket");
    const fail = try std.fs.path.join(allocator, &.{ bucket, "fail-spores" });

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = fail, .data = "" });
    try std.testing.expectError(error.ImageStorePushFailed, testPush(&fixture, saved.dir, "s3://bucket-1/team/warm", aws));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, try std.fs.path.join(allocator, &.{ bucket, "bucket-1", "team", "spore-tags" }), .{}));
    try Io.Dir.cwd().deleteFile(io, fail);

    const pushed = try testPush(&fixture, saved.dir, "s3://bucket-1/team/warm", aws);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "s3://bucket-1/team/{s}", .{pushed.spore_digest}), pushed.ref);
    try std.testing.expectEqual(@as(usize, 6), pushed.objects_total);
    // The failed push uploaded the objects already.
    try std.testing.expectEqual(@as(usize, 0), pushed.objects_written);
    const commands = try Io.Dir.cwd().readFileAlloc(io, try fixture.path("aws.log"), allocator, .limited(64 * 1024));
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, commands, "\n"), '\n');
    const objects_sync = .{ "s3 sync --size-only --no-progress ", " s3://bucket-1/team/objects" };
    const spores_sync = .{ "s3 sync --size-only --only-show-errors ", " s3://bucket-1/team/spores" };
    const tag_copy = .{ "s3 cp --only-show-errors ", " s3://bucket-1/team/spore-tags/warm" };
    inline for (.{ objects_sync, spores_sync, objects_sync, spores_sync, tag_copy }) |expected| {
        const line = lines.next() orelse return error.TestExpectedAwsCommand;
        try std.testing.expect(std.mem.startsWith(u8, line, expected[0]));
        try std.testing.expect(std.mem.endsWith(u8, line, expected[1]));
    }
    try std.testing.expectEqual(null, lines.next());

    const store = try std.fs.path.join(allocator, &.{ bucket, "bucket-1", "team" });
    const files = try fixture.listStore(store);
    try std.testing.expectEqual(@as(usize, 8), files.len);
    try std.testing.expectEqualStrings("spore-tags/warm", files[6]);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "spores/{s}", .{pushed.spore_digest[chunk.ChunkId.digest_prefix.len..]}), files[7]);

    // Every push removed its staging directory.
    var tmp = try Io.Dir.cwd().openDir(io, try std.fs.path.join(allocator, &.{ fixture.env.get(local_paths.rootfs_cache_env).?, "tmp" }), .{ .iterate = true });
    defer tmp.close(io);
    var entries = tmp.iterate();
    try std.testing.expectEqual(null, try entries.next(io));
}
