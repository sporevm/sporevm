//! Saved spores in an image store. `spore checkpoint push` writes the manifest to
//! `spores/<hex>`, where `hex` is its BLAKE3, and the RAM chunks, the disk
//! index and the disk objects to the store's shared `objects/blake3/`, so a
//! spore's unchanged disk chunks dedupe against its image. `spore checkpoint pull`
//! fetches them back into a pinned save.

const std = @import("std");
const Io = std.Io;
const chunk = @import("chunk.zig");
const Context = @import("context.zig").Context;
const disk_index = @import("disk_index.zig");
const image_store = @import("image_store.zig");
const local_paths = @import("local_paths.zig");
const resource = @import("resource.zig");
const rootfs = @import("rootfs.zig");
const rootfs_cache = @import("rootfs_cache.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const runtime_disk_lease = @import("runtime_disk_lease.zig");
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
/// host-local RAM backing, then the tag. The rootfs cache must hold the
/// complete disk. A spore with a rootfs must have a disk, as every save of one
/// does: a pin roots only a disk's storage.
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
        if (!try rootfs_cas.storageContentComplete(context.io, arena, cache_root, storage)) return error.SporeStorageIncomplete;
        const index_path = try rootfs_cas.manifestIndexPath(arena, cache_root, storage.index_digest);
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
                .path = try rootfs_cas.objectPath(arena, cache_root, entry.id),
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

pub const PullOptions = struct {
    source: []const u8,
    out_dir: []const u8,
};

pub const PullObjects = struct {
    objects: usize = 0,
    objects_fetched: usize = 0,
    bytes_fetched: u64 = 0,
};

pub const PullResult = struct {
    schema: []const u8 = "spore.pull.result.v2",
    schema_version: u32 = 2,
    resource_type: resource.Type = .checkpoint,
    /// The digest-pinned ref of the pulled spore.
    ref: []const u8,
    spore_digest: []const u8,
    out_dir: []const u8,
    ram: PullObjects,
    /// The disk index and the disk objects.
    disk: PullObjects,
};

/// Pull a spore from a store into the new directory `out_dir` as a pinned
/// save: the manifest, verified against its digest, then its RAM chunks into
/// `out_dir/chunks`, then the disk index and the disk objects this rootfs
/// cache lacks, each verified against its BLAKE3 digest. A runtime lease
/// keeps the fetched objects from GC until the pin roots them. On failure
/// `out_dir` is removed.
pub fn pull(context: Context, allocator: std.mem.Allocator, options: PullOptions) !PullResult {
    const io = context.io;
    const source = try image_store.parseStoreRef(options.source);
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Concurrent requests allocate on Io workers.
    const gpa = std.heap.c_allocator;
    var client = try image_store.Client.init(gpa, io, source.base.url, context.environ_map);
    defer client.deinit();

    const digest = switch (source.target) {
        .digest => |value| value,
        .tag => |name| try image_store.parseTag(try client.get(arena, try std.fmt.allocPrint(arena, "spore-tags/{s}", .{name}), .{ .max = image_store.tag_file_len }, image_store.metadata_budget)),
    };
    const hex = digest[chunk.ChunkId.digest_prefix.len..];
    const manifest_bytes = try client.get(arena, try std.fmt.allocPrint(arena, "spores/{s}", .{hex}), .{ .max = spore.max_manifest_bytes }, image_store.metadata_budget);
    if (!std.mem.eql(u8, &chunk.ChunkId.fromContents(manifest_bytes).toHex(), hex)) return error.SporeIdentityMismatch;
    var parsed = try spore.parseManifest(arena, manifest_bytes);
    defer parsed.deinit();
    const manifest = parsed.value;
    // It names a file in the spore directory, which this pull does not write.
    if (manifest.memory.backing != null) return error.BadManifest;
    const disk = manifest.disk orelse if (manifest.rootfs != null) return error.SporeRootfsWithoutDisk else null;

    var ram: PullObjects = .{};
    var ram_objects: std.ArrayList(image_store.Object) = .empty;
    var seen: std.AutoHashMapUnmanaged(chunk.ChunkId, void) = .empty;
    const memory = manifest.memory;
    for (memory.chunks) |entry| {
        if ((try seen.getOrPut(arena, entry.id)).found_existing) continue;
        const start = std.math.mul(u64, entry.logical_chunk, memory.chunk_size) catch return error.BadManifest;
        if (start >= memory.logical_size) return error.BadManifest;
        const len = std.math.cast(usize, @min(memory.chunk_size, memory.logical_size - start)) orelse return error.BadManifest;
        try ram_objects.append(arena, .{ .digest = entry.id.toDigest(), .len = len });
        ram.bytes_fetched += len;
    }
    // A 64 MiB manifest can name a million RAM chunks.
    if (ram.bytes_fetched > max_pull_ram_bytes) return error.SporeRamTooLarge;

    const cache_root = try local_paths.absolutePathAlloc(io, arena, try local_paths.rootfsCacheRootPath(arena, context.environ_map));
    // The pin records the save's absolute path.
    const out_dir = try local_paths.absolutePathAlloc(io, arena, options.out_dir);
    try Io.Dir.cwd().createDirPath(io, cache_root);
    if (disk != null) try saved_spore_pin.ensureOwnershipLinkCompatible(arena, cache_root, out_dir);
    try spore.createSnapshotRoot(arena, out_dir);
    errdefer Io.Dir.cwd().deleteTree(io, out_dir) catch {};
    const chunks_dir = try std.fs.path.join(arena, &.{ out_dir, "chunks" });
    try Io.Dir.cwd().createDirPath(io, chunks_dir);

    var ram_fetch: RamFetch = .{ .io = io, .client = &client, .dir = chunks_dir };
    try image_store.fillEach(io, ram_objects.items, null, &ram_fetch, RamFetch.fetch);
    ram.objects = ram_objects.items.len;
    ram.objects_fetched = ram.objects;

    const ref = try image_store.pushedRefAlloc(allocator, source.base, digest);
    errdefer allocator.free(ref);
    const spore_digest = try allocator.dupe(u8, digest);
    errdefer allocator.free(spore_digest);
    const result_out_dir = try allocator.dupe(u8, out_dir);
    errdefer allocator.free(result_out_dir);

    var disk_objects: PullObjects = .{};
    const saved_disk = disk orelse {
        try spore.saveManifest(arena, out_dir, manifest);
        return .{ .ref = ref, .spore_digest = spore_digest, .out_dir = result_out_dir, .ram = ram, .disk = disk_objects };
    };
    const storage = try saved_spore_pin.storageForDisk(saved_disk);
    const index_path = try rootfs_cas.manifestIndexPath(arena, cache_root, storage.index_digest);
    // Fetch without the cache lock, which every other spore command takes.
    const index_bytes: ?[]const u8 = if (try rootfs_cache.regularFileNoSymlink(io, index_path)) null else blk: {
        const bytes = try client.get(arena, try image_store.objectPathAlloc(arena, storage.index_digest), .{ .max = disk_index.max_index_bytes }, image_store.metadata_budget);
        const id = chunk.ChunkId.fromDigest(storage.index_digest) catch return error.BadManifest;
        if (!id.matches(bytes)) return error.BadChunk;
        break :blk bytes;
    };
    var lease = blk: {
        var cache_lock = try rootfs.lockRootfsCacheExclusive(io, arena, cache_root);
        defer cache_lock.deinit();
        if (index_bytes) |bytes| {
            if (!(try rootfs_cas.installStorageIndexPath(arena, io, index_path, bytes, storage)).cache_hit) {
                disk_objects.objects_fetched += 1;
                disk_objects.bytes_fetched += bytes.len;
            }
        }
        try saved_spore_pin.validateRoot(arena, cache_root, storage);
        // GC roots every object a leased index names, fetched or not.
        break :blk try runtime_disk_lease.acquireActive(io, arena, try local_paths.runtimeRootPath(arena, context.environ_map), .{
            .root = cache_root,
            .baseline_kind = .disk_index,
            .baseline_identity = storage.index_digest,
            .rootfs_storage = storage,
        });
    };
    defer lease.deinit();

    const fetcher = try image_store.Fetcher.create(gpa, io, cache_root, source.base.url, storage, context.environ_map);
    defer fetcher.release();
    try fetcher.fetchAll();
    const stats = fetcher.currentStats();
    disk_objects.objects = 1 + try indexObjectCount(arena, cache_root, storage);
    disk_objects.objects_fetched += stats.fetches;
    disk_objects.bytes_fetched += stats.bytes;

    var cache_lock = try rootfs.lockRootfsCacheExclusive(io, arena, cache_root);
    defer cache_lock.deinit();
    try saved_spore_pin.publishManifest(io, arena, try saved_spore_pin.LockedRegistry.init(arena, cache_root, &cache_lock), out_dir, saved_disk, manifest);
    return .{ .ref = ref, .spore_digest = spore_digest, .out_dir = result_out_dir, .ram = ram, .disk = disk_objects };
}

/// The most nonzero RAM a pull writes.
const max_pull_ram_bytes: u64 = 128 * 1024 * 1024 * 1024;

/// Fetches RAM chunks into a spore's `chunks` directory.
const RamFetch = struct {
    io: Io,
    client: *image_store.Client,
    dir: []const u8,

    fn fetch(self: *RamFetch, object: image_store.Object) !void {
        const gpa = std.heap.c_allocator;
        const path = try image_store.objectPathAlloc(gpa, &object.digest);
        defer gpa.free(path);
        const bytes = try self.client.get(gpa, path, .{ .max = object.len, .exact = true }, image_store.metadata_budget);
        defer gpa.free(bytes);
        const dest = try std.fs.path.join(gpa, &.{ self.dir, object.digest[chunk.ChunkId.digest_prefix.len..] });
        defer gpa.free(dest);
        // Verifies the digest and length before it writes.
        _ = try rootfs_cas.installChunkPath(gpa, self.io, dest, bytes, &object.digest, object.len);
    }
};

/// The distinct objects the installed index of `storage` names.
fn indexObjectCount(arena: std.mem.Allocator, cache_root: []const u8, storage: spore.RootfsStorage) !usize {
    const index = try rootfs_cas.readStorageIndexPath(arena, try rootfs_cas.manifestIndexPath(arena, cache_root, storage.index_digest), storage);
    var seen: std.AutoHashMapUnmanaged(chunk.ChunkId, void) = .empty;
    for (index.parsed.value.chunks) |entry| _ = try seen.getOrPut(arena, entry.id);
    return seen.count();
}

const chunk_sealer = @import("chunk_sealer.zig");
const manifest_test_support = @import("manifest_test_support.zig");
const saved_spore_ownership = @import("saved_spore_ownership.zig");
const system = @import("system.zig");
const test_support = @import("test_support.zig");

/// Test support: a saved spore in `<fixture>/saved` whose disk is the fixture
/// image with its first chunk changed, with a nonzero full RAM chunk, a
/// nonzero 19-byte tail chunk, and a RAM backing.
const TestSpore = struct {
    dir: []const u8,
    ram: []const u8,
    disk: spore.Disk,
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
        .ram = ram,
        .disk = manifest.disk.?,
        .disk_object = try rootfs_cas.objectPath(allocator, cache, changed),
        .index_len = (try Io.Dir.cwd().statFile(io, try rootfs_cas.manifestIndexPath(allocator, cache, storage.index_digest), .{})).size,
    };
}

/// Test support: an environment with its own rootfs cache and runtime
/// directory, `<fixture>/<name>-cache` and `<name>-runtime`.
fn testEnv(fixture: *image_store.TestImage, name: []const u8) !*std.process.Environ.Map {
    const allocator = fixture.arena.allocator();
    const env = try allocator.create(std.process.Environ.Map);
    env.* = .init(allocator);
    try env.put(local_paths.rootfs_cache_env, try fixture.path(try std.fmt.allocPrint(allocator, "{s}-cache", .{name})));
    try env.put(local_paths.runtime_dir_env, try fixture.path(try std.fmt.allocPrint(allocator, "{s}-runtime", .{name})));
    try env.put("TMPDIR", fixture.root);
    return env;
}

fn testPull(fixture: *image_store.TestImage, env: *const std.process.Environ.Map, source: []const u8, out_dir: []const u8) !PullResult {
    return pull(.{ .io = std.testing.io, .environ_map = env }, fixture.arena.allocator(), .{ .source = source, .out_dir = out_dir });
}

/// Test support: whether `path` exists.
fn exists(path: []const u8) !bool {
    Io.Dir.cwd().access(std.testing.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

fn testPush(fixture: *image_store.TestImage, spore_dir: []const u8, destination: []const u8, aws: []const u8) !PushResult {
    return push(.{ .io = std.testing.io, .environ_map = &fixture.env }, fixture.arena.allocator(), .{
        .spore_dir = spore_dir,
        .destination = destination,
        .aws_executable = aws,
    });
}

test "spore checkpoint push writes a spore once, without its RAM backing, and dedupes against its image" {
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
    try std.testing.expectError(error.SporeIdentityMismatch, testPush(&fixture, saved.dir, try std.fmt.allocPrint(allocator, "{s}/blake3:{s}", .{ store, test_support.repeat("b", 64) }), "aws"));
    try std.testing.expectError(error.ImageStorePushUnsupportedScheme, testPush(&fixture, saved.dir, "https://images.example.test/warm", "aws"));
}

test "spore checkpoint push sends a spore without a rootfs and refuses an incomplete or missing disk" {
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

test "spore checkpoint push to S3 uploads objects, then the manifest, then the tag" {
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

test "spore checkpoint pull fetches a pushed spore into a pinned save" {
    var fixture: image_store.TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const saved = try saveTestSpore(&fixture);
    const store = try fixture.path("store");
    const pushed = try testPush(&fixture, saved.dir, try std.fmt.allocPrint(allocator, "{s}/warm", .{store}), "aws");
    const env = try testEnv(&fixture, "consumer");
    const cache = env.get(local_paths.rootfs_cache_env).?;
    const out = try fixture.path("pulled");

    const pulled = try testPull(&fixture, env, try std.fmt.allocPrint(allocator, "file://{s}/warm", .{store}), out);
    try std.testing.expectEqualStrings(pushed.spore_digest, pulled.spore_digest);
    try std.testing.expectEqualStrings(pushed.ref, pulled.ref);
    try std.testing.expectEqual(PullObjects{ .objects = 2, .objects_fetched = 2, .bytes_fetched = saved.ram.len }, pulled.ram);
    const disk_bytes = saved.index_len + 2 * rootfs_cas.default_chunk_size + 100;
    try std.testing.expectEqual(PullObjects{ .objects = 4, .objects_fetched = 4, .bytes_fetched = disk_bytes }, pulled.disk);

    // A pinned save of the pushed manifest, with its RAM and complete disk.
    const manifest_bytes = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(allocator, &.{ out, "manifest.json" }), allocator, .limited(spore.max_manifest_bytes));
    try std.testing.expectEqualStrings(pushed.spore_digest, &chunk.ChunkId.fromContents(manifest_bytes).toDigest());
    try std.testing.expectEqualStrings(saved_spore_ownership.machine_local_pinned, try saved_spore_ownership.classify(allocator, out, saved.disk));
    const manifest = try spore.loadManifest(allocator, out);
    const ram = try allocator.alloc(u8, saved.ram.len);
    @memset(ram, 0);
    try spore.loadMemory(allocator, out, manifest.value.memory, ram);
    try std.testing.expectEqualSlices(u8, saved.ram, ram);
    const storage = try saved_spore_pin.storageForDisk(saved.disk);
    try std.testing.expect(try rootfs_cas.storageMarkedComplete(io, allocator, cache, storage));
    try std.testing.expect(try rootfs_cas.storageContentComplete(io, allocator, cache, storage));
    try std.testing.expectEqual(@as(usize, 1), (try saved_spore_pin.list(io, allocator, cache)).len);
    var leases = try runtime_disk_lease.ActiveIterator.init(allocator, io, env.get(local_paths.runtime_dir_env).?);
    defer leases.deinit();
    try std.testing.expectEqual(null, try leases.next());

    // Another pull into this cache fetches only the RAM.
    const again = try testPull(&fixture, env, pushed.ref, try fixture.path("pulled-again"));
    try std.testing.expectEqual(@as(usize, 2), again.ram.objects_fetched);
    try std.testing.expectEqual(PullObjects{ .objects = 4 }, again.disk);
    try std.testing.expectError(error.AlreadyExists, testPull(&fixture, env, pushed.ref, out));
}

test "spore checkpoint pull writes to a relative --out and one under a symlinked directory" {
    var fixture: image_store.TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const saved = try saveTestSpore(&fixture);
    const pushed = try testPush(&fixture, saved.dir, try std.fmt.allocPrint(allocator, "{s}/warm", .{try fixture.path("store")}), "aws");
    const env = try testEnv(&fixture, "consumer");

    // Relative to the working directory, as a shell user passes it.
    const relative = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &fixture.tmp.sub_path, "relative.spore" });
    const pulled = try testPull(&fixture, env, pushed.ref, relative);
    try std.testing.expectEqualStrings(try fixture.path("relative.spore"), pulled.out_dir);
    try std.testing.expectEqualStrings(saved_spore_ownership.machine_local_pinned, try saved_spore_ownership.classify(allocator, try fixture.path("relative.spore"), saved.disk));

    // /tmp is a symlink on macOS.
    try Io.Dir.cwd().createDirPath(io, try fixture.path("real"));
    try Io.Dir.cwd().symLink(io, try fixture.path("real"), try fixture.path("link"), .{});
    _ = try testPull(&fixture, env, pushed.ref, try fixture.path("link/linked.spore"));
    try std.testing.expectEqualStrings(saved_spore_ownership.machine_local_pinned, try saved_spore_ownership.classify(allocator, try fixture.path("real/linked.spore"), saved.disk));
}

test "spore checkpoint pull refuses a spore with more RAM than it writes before creating --out" {
    var fixture: image_store.TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const store = try fixture.path("store");
    const out = try fixture.path("pulled");

    // Distinct nonzero chunks one past the limit.
    const count = max_pull_ram_bytes / spore.chunk_size + 1;
    const chunks = try allocator.alloc(spore.MemoryChunk, count);
    for (chunks, 0..) |*entry, i| entry.* = .{ .logical_chunk = i, .id = chunk.ChunkId.fromContents(std.mem.asBytes(&i)) };
    var manifest = manifest_test_support.manifest(.{});
    manifest.platform.ram_size = count * spore.chunk_size;
    manifest.memory = .{ .logical_size = manifest.platform.ram_size, .chunk_size = spore.chunk_size, .chunks = chunks };
    const bytes = try spore.encodeManifestAlloc(allocator, manifest);
    const digest = chunk.ChunkId.fromContents(bytes).toDigest();
    try chunk_sealer.ensureDirPath(allocator, try std.fs.path.join(allocator, &.{ store, "spores" }));
    try chunk_sealer.writeFileAtomicDurable(allocator, try std.fmt.allocPrint(allocator, "{s}/spores/{s}", .{ store, digest[chunk.ChunkId.digest_prefix.len..] }), bytes, 0o644);
    try std.testing.expectError(error.SporeRamTooLarge, testPull(&fixture, &fixture.env, try std.fmt.allocPrint(allocator, "file://{s}/{s}", .{ store, &digest }), out));
    try std.testing.expect(!try exists(out));
}

test "spore checkpoint pull fails closed on bad store data and leaves no save or pin" {
    var fixture: image_store.TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const saved = try saveTestSpore(&fixture);
    const store = try fixture.path("store");
    const pushed = try testPush(&fixture, saved.dir, try std.fmt.allocPrint(allocator, "{s}/warm", .{store}), "aws");
    const env = try testEnv(&fixture, "consumer");
    const cache = env.get(local_paths.rootfs_cache_env).?;
    const out = try fixture.path("pulled");
    const storage = try saved_spore_pin.storageForDisk(saved.disk);

    // A manifest that does not hash to its name.
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/spores/{s}", .{ store, pushed.spore_digest[chunk.ChunkId.digest_prefix.len..] });
    const manifest_bytes = try Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(spore.max_manifest_bytes));
    try chunk_sealer.replaceFileAtomicDurable(allocator, manifest_path, try std.mem.concat(allocator, u8, &.{ manifest_bytes, "\n" }), 0o644);
    try std.testing.expectError(error.SporeIdentityMismatch, testPull(&fixture, env, pushed.ref, out));
    try std.testing.expect(!try exists(out));
    try chunk_sealer.replaceFileAtomicDurable(allocator, manifest_path, manifest_bytes, 0o644);

    // A manifest that names a RAM backing file, a path on its host.
    const local_bytes = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(allocator, &.{ saved.dir, "manifest.json" }), allocator, .limited(spore.max_manifest_bytes));
    const local_digest = chunk.ChunkId.fromContents(local_bytes).toDigest();
    try chunk_sealer.writeFileAtomicDurable(allocator, try std.fmt.allocPrint(allocator, "{s}/spores/{s}", .{ store, local_digest[chunk.ChunkId.digest_prefix.len..] }), local_bytes, 0o644);
    try std.testing.expectError(error.BadManifest, testPull(&fixture, env, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ store, &local_digest }), out));
    try std.testing.expect(!try exists(out));

    // A corrupt RAM chunk, disk index or disk object.
    const memory = (try spore.loadManifest(allocator, saved.dir)).value.memory;
    for ([_][]const u8{
        try image_store.objectPathAlloc(allocator, &memory.chunks[0].id.toDigest()),
        try image_store.objectPathAlloc(allocator, storage.index_digest),
        try std.fmt.allocPrint(allocator, "objects/blake3/{s}", .{std.fs.path.basename(saved.disk_object)[0..chunk.ChunkId.hex_len]}),
    }) |relative| {
        const path = try std.fs.path.join(allocator, &.{ store, relative });
        const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(disk_index.max_index_bytes));
        const corrupt = try allocator.dupe(u8, bytes);
        corrupt[0] ^= 0xff;
        try chunk_sealer.replaceFileAtomicDurable(allocator, path, corrupt, 0o644);
        try std.testing.expectError(error.BadChunk, testPull(&fixture, env, pushed.ref, out));
        try std.testing.expect(!try exists(out));
        try std.testing.expectEqual(@as(usize, 0), (try saved_spore_pin.list(io, allocator, cache)).len);
        try std.testing.expect(!try rootfs_cas.storageMarkedComplete(io, allocator, cache, storage));
        try chunk_sealer.replaceFileAtomicDurable(allocator, path, bytes, 0o644);
    }
    _ = try testPull(&fixture, env, pushed.ref, out);
}

test "a cache gc during a pull keeps what the pull fetched" {
    var fixture: image_store.TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const saved = try saveTestSpore(&fixture);
    const store = try fixture.path("store");
    const pushed = try testPush(&fixture, saved.dir, try std.fmt.allocPrint(allocator, "{s}/warm", .{store}), "aws");
    const env = try testEnv(&fixture, "consumer");
    const cache = env.get(local_paths.rootfs_cache_env).?;
    const storage = try saved_spore_pin.storageForDisk(saved.disk);

    // The store holds back the changed disk object until the GC has run.
    var server: image_store.TestServer = undefined;
    try server.start(std.testing.allocator, io, store, "127.0.0.1");
    defer server.stop();
    const changed_hex = std.fs.path.basename(saved.disk_object)[0..chunk.ChunkId.hex_len];
    server.held = try std.fmt.allocPrint(allocator, "/objects/blake3/{s}", .{changed_hex});
    const Puller = struct {
        fixture: *image_store.TestImage,
        env: *const std.process.Environ.Map,
        source: []const u8,
        out: []const u8,
        result: anyerror!PullResult = error.TestUnexpectedResult,

        fn run(self: *@This()) void {
            self.result = testPull(self.fixture, self.env, self.source, self.out);
        }
    };
    var puller: Puller = .{
        .fixture = &fixture,
        .env = env,
        .source = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ try server.url(allocator), pushed.spore_digest }),
        .out = try fixture.path("pulled"),
    };
    const thread = try std.Thread.spawn(.{}, Puller.run, .{&puller});
    var joined = false;
    defer if (!joined) {
        server.releaseHeld();
        thread.join();
    };

    // The other disk objects are in the cache, and only the pull's lease
    // roots them and the index.
    const index_path = try rootfs_cas.manifestIndexPath(allocator, cache, storage.index_digest);
    const others = [_]usize{ 2, 3 };
    var other_paths: [others.len][]const u8 = undefined;
    for (others, &other_paths) |logical_chunk, *path| {
        const start = logical_chunk * rootfs_cas.default_chunk_size;
        const bytes = fixture.rootfs_bytes[start..@min(start + rootfs_cas.default_chunk_size, fixture.rootfs_bytes.len)];
        path.* = try rootfs_cas.objectPath(allocator, cache, chunk.ChunkId.fromContents(bytes));
    }
    for (other_paths) |path| while (!try exists(path)) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    _ = try system.gc(allocator, io, .{ .cache_root = cache, .runtime_root = env.get(local_paths.runtime_dir_env).?, .dry_run = false });
    try std.testing.expect(try exists(index_path));
    for (other_paths) |path| try std.testing.expect(try exists(path));
    server.releaseHeld();
    thread.join();
    joined = true;
    _ = try puller.result;
    try std.testing.expect(try rootfs_cas.storageContentComplete(io, allocator, cache, storage));
}

test "spore checkpoint pull over HTTP fetches a spore without a rootfs and refuses a rootfs without a disk" {
    var fixture: image_store.TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const saved = try saveTestSpore(&fixture);
    const store = try fixture.path("store");
    var parsed = try spore.loadManifest(allocator, saved.dir);
    parsed.value.rootfs = null;
    parsed.value.disk = null;
    parsed.value.devices = &.{};
    try spore.saveManifest(allocator, saved.dir, parsed.value);
    _ = try testPush(&fixture, saved.dir, try std.fmt.allocPrint(allocator, "{s}/ram", .{store}), "aws");
    var server: image_store.TestServer = undefined;
    try server.start(std.testing.allocator, io, store, "127.0.0.1");
    defer server.stop();
    const base = try server.url(allocator);
    const env = try testEnv(&fixture, "consumer");

    const out = try fixture.path("pulled");
    const pulled = try testPull(&fixture, env, try std.fmt.allocPrint(allocator, "{s}/ram", .{base}), out);
    try std.testing.expectEqual(PullObjects{ .objects = 2, .objects_fetched = 2, .bytes_fetched = saved.ram.len }, pulled.ram);
    try std.testing.expectEqual(PullObjects{}, pulled.disk);
    try std.testing.expectEqualStrings(saved_spore_ownership.portable_self_contained, try saved_spore_ownership.classify(allocator, out, null));
    const ram = try allocator.alloc(u8, saved.ram.len);
    @memset(ram, 0);
    try spore.loadMemory(allocator, out, (try spore.loadManifest(allocator, out)).value.memory, ram);
    try std.testing.expectEqualSlices(u8, saved.ram, ram);

    // A rootfs needs a disk for a pin to root its storage.
    var devices = [_]spore.TransportState{ manifest_test_support.testTransport(3), manifest_test_support.testTransport(spore.rootfs_virtio_blk_device_id) };
    parsed.value.rootfs = manifest_test_support.testRootfs(1);
    parsed.value.devices = &devices;
    parsed.value.memory.backing = null;
    const bytes = try spore.encodeManifestAlloc(allocator, parsed.value);
    const digest = chunk.ChunkId.fromContents(bytes).toDigest();
    try chunk_sealer.writeFileAtomicDurable(allocator, try std.fmt.allocPrint(allocator, "{s}/spores/{s}", .{ store, digest[chunk.ChunkId.digest_prefix.len..] }), bytes, 0o644);
    try std.testing.expectError(error.SporeRootfsWithoutDisk, testPull(&fixture, env, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, &digest }), try fixture.path("refused")));
    try std.testing.expect(!try exists(try fixture.path("refused")));
}
