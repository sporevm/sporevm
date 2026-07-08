//! Local spore chunkpack bundles.
//!
//! Bundles are the first distribution shape for spores: a portable manifest
//! plus an index that maps logical BLAKE3 chunks into larger pack blobs. The
//! normal spore manifest remains the machine-state contract; bundle indexes are
//! transport metadata and must be verified before chunks are written back to a
//! CAS directory.

const std = @import("std");
const builtin = @import("builtin");
const block_source = @import("block_source.zig");
const contracts = @import("contracts.zig");
const chunklib = @import("chunk.zig");
const cow_disk = @import("cow_disk.zig");
const disk_layer = @import("disk_layer.zig");
const fetch_policy = @import("host_fetch_policy.zig");
const gicv3 = @import("gicv3.zig");
const rootfs_cache = @import("rootfs_cache.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const disk_index = @import("disk_index.zig");
const spore = @import("spore.zig");
const topology = @import("topology.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Io = std.Io;

const Error = spore.Error || error{ FileNotFound, UnsupportedMetadataOnlyRootfsStorage, BundleBodyTooLarge };

pub const index_version: u32 = 0;
pub const bundle_index_version: u32 = 0;
pub const rootfs_index_version: u32 = 0;
pub const bundle_index_path = "bundle.json";
pub const index_path = "chunkpack.index.json";
pub const pack_path = "chunkpacks/000000.pack";
pub const manifests_dir_path = "manifests";
pub const parent_manifest_path = "manifests/parent.json";
pub const child_manifests_dir_path = "manifests/children";
pub const rootfs_dir_path = "rootfs";
pub const rootfs_blake3_dir_path = "rootfs/blake3";
pub const rootfs_blake3_indexes_dir_path = "rootfs/blake3/indexes";
pub const rootfs_blake3_objects_dir_path = "rootfs/blake3/objects";
pub const rootfs_index_path = "rootfs.index.json";
pub const rootfs_policy_exact_bytes = "exact-bytes";
pub const rootfs_policy_metadata_only = "metadata-only";
pub const disk_layers_blake3_dir_path = "disklayers/blake3";
pub const disk_objects_blake3_dir_path = "diskobjects/blake3";
pub const inspect_bundle_schema = contracts.inspect_bundle_schema;
pub const pull_result_schema = contracts.pull_result_schema;
pub const bundle_schema_version = contracts.bundle_schema_version;

const max_remote_bundle_metadata_file_bytes: u64 = 64 * 1024 * 1024;
const max_remote_bundle_metadata_bytes: u64 = 256 * 1024 * 1024;
const max_remote_bundle_materialization_bytes: u64 = 128 * 1024 * 1024 * 1024;

const LoadedManifest = struct {
    v0: ?std.json.Parsed(spore.Manifest) = null,
    v1: ?std.json.Parsed(spore.ManifestV1) = null,

    fn loadDir(allocator: std.mem.Allocator, dir: []const u8) Error!LoadedManifest {
        var loaded = LoadedManifest{};
        loaded.v0 = spore.loadManifest(allocator, dir) catch |err| switch (err) {
            error.BadManifest => null,
            else => |e| return e,
        };
        if (loaded.v0 == null) loaded.v1 = try spore.loadManifestV1(allocator, dir);
        return loaded;
    }

    fn loadPath(allocator: std.mem.Allocator, path: []const u8) Error!LoadedManifest {
        var loaded = LoadedManifest{};
        loaded.v0 = spore.loadManifestPath(allocator, path) catch |err| switch (err) {
            error.BadManifest => null,
            else => |e| return e,
        };
        if (loaded.v0 == null) loaded.v1 = try spore.loadManifestV1Path(allocator, path);
        return loaded;
    }

    fn deinit(self: *LoadedManifest) void {
        if (self.v0) |*parsed| parsed.deinit();
        if (self.v1) |*parsed| parsed.deinit();
    }

    fn memoryPtr(self: *LoadedManifest) *spore.MemoryManifest {
        if (self.v0) |*parsed| return &parsed.value.memory;
        return &self.v1.?.value.memory;
    }

    fn memory(self: LoadedManifest) spore.MemoryManifest {
        if (self.v0) |parsed| return parsed.value.memory;
        return self.v1.?.value.memory;
    }

    fn clearMemoryBacking(self: *LoadedManifest) void {
        self.memoryPtr().backing = null;
    }

    fn ramSize(self: LoadedManifest) u64 {
        if (self.v0) |parsed| return parsed.value.platform.ram_size;
        return self.v1.?.value.platform.ram_size;
    }

    fn rootfs(self: LoadedManifest) ?spore.Rootfs {
        if (self.v0) |parsed| return parsed.value.rootfs;
        return self.v1.?.value.rootfs;
    }

    fn disk(self: LoadedManifest) ?spore.Disk {
        if (self.v0) |parsed| return parsed.value.disk;
        return self.v1.?.value.disk;
    }

    fn saveDir(self: LoadedManifest, allocator: std.mem.Allocator, dir: []const u8) Error!void {
        if (self.v0) |parsed| {
            try spore.saveManifest(allocator, dir, parsed.value);
        } else {
            try spore.saveManifestV1(allocator, dir, self.v1.?.value);
        }
    }

    fn savePath(self: LoadedManifest, allocator: std.mem.Allocator, path: []const u8) Error!void {
        if (self.v0) |parsed| {
            try spore.saveManifestPath(allocator, path, parsed.value);
        } else {
            try spore.saveManifestV1Path(allocator, path, self.v1.?.value);
        }
    }
};

pub const RootfsBundlePolicy = enum {
    exact_bytes,
    metadata_only,
};

pub const PackOptions = struct {
    io: Io,
    spore_dir: []const u8,
    out_dir: []const u8,
    rootfs_cache_dir: ?[]const u8 = null,
    children_dir: ?[]const u8 = null,
    rootfs_policy: RootfsBundlePolicy = .exact_bytes,
};

pub const PackResult = struct {
    source: []const u8,
    out_dir: []const u8,
    bundle_digest: []const u8,
    chunk_count: usize,
    packed_chunk_count: usize,
    pack_count: usize,
    payload_bytes: u64,
    rootfs_artifact_count: usize = 0,
    rootfs_payload_bytes: u64 = 0,
    child_count: usize = 0,
};

pub const UnpackOptions = struct {
    io: Io,
    bundle_dir: []const u8,
    out_dir: []const u8,
    rootfs_cache_dir: ?[]const u8 = null,
    child_id: ?[]const u8 = null,
    allow_metadata_only_rootfs: bool = false,
};

pub const UnpackResult = struct {
    bundle: []const u8,
    out_dir: []const u8,
    bundle_digest: []const u8,
    chunk_count: usize,
    unpacked_chunk_count: usize,
    payload_bytes: u64,
    rootfs_artifact_count: usize = 0,
    rootfs_payload_bytes: u64 = 0,
    child_count: usize = 0,
    selected_child: ?[]const u8 = null,
};

pub const PushOptions = struct {
    io: Io,
    bundle_dir: []const u8,
    destination: []const u8,
    aws_region: ?[]const u8 = null,
    aws_executable: []const u8 = "aws",
};

pub const PushResult = struct {
    source: []const u8,
    destination: []const u8,
    store: []const u8 = "s3",
    bundle_digest: []const u8,
    uploaded_file_count: usize,
    uploaded_bytes: u64,
};

pub const PullOptions = struct {
    io: Io,
    source: []const u8,
    out_dir: []const u8,
    rootfs_cache_dir: ?[]const u8 = null,
    bundle_cache_dir: ?[]const u8 = null,
    child_id: ?[]const u8 = null,
    allow_metadata_only_rootfs: bool = false,
    aws_region: ?[]const u8 = null,
    aws_executable: []const u8 = "aws",
};

pub const DigestRef = contracts.DigestRef;
pub const CacheState = contracts.CacheState;
pub const ChunkMaterializationSummary = contracts.ChunkMaterializationSummary;
pub const RootfsMaterializationSummary = contracts.RootfsMaterializationSummary;
pub const RemoteBundleCache = contracts.RemoteBundleCache;
pub const BundleChildrenSummary = contracts.BundleChildrenSummary;
pub const PullResult = contracts.PullResult;

pub const ChildRange = struct {
    start: u32,
    end: u32,
};

pub const InspectBundleOptions = struct {
    source: []const u8,
    child_id: ?[]const u8 = null,
    child_range: ?ChildRange = null,
};

pub const BundleChildSummary = contracts.BundleChildSummary;
pub const BundleSelectionSummary = contracts.BundleSelectionSummary;
pub const ChunkpackSummary = contracts.ChunkpackSummary;
pub const RootfsBundleSummary = contracts.RootfsBundleSummary;
pub const InspectBundleResult = contracts.InspectBundleResult;

pub const IndexChunk = struct {
    id: []const u8,
    pack: []const u8,
    offset: u64,
    size: u64,
    sha256: []const u8,
};

pub const Index = struct {
    version: u32 = index_version,
    chunk_size: u64 = spore.chunk_size,
    chunks: []IndexChunk,
};

pub const BundleChild = struct {
    id: []const u8,
    manifest: []const u8,
};

pub const BundleIndex = struct {
    version: u32 = bundle_index_version,
    parent_manifest: []const u8 = parent_manifest_path,
    children: []BundleChild,
    chunkpack_index: []const u8 = index_path,
    rootfs_index: ?[]const u8 = null,
};

pub const RootfsArtifactEntry = struct {
    digest: []const u8,
    size: u64,
    format: []const u8 = spore.rootfs_artifact_format_ext4,
    policy: []const u8 = rootfs_policy_exact_bytes,
    path: ?[]const u8 = null,
};

pub const RootfsStorageEntry = struct {
    kind: []const u8 = spore.rootfs_storage_kind_chunked_ext4,
    device: spore.RootfsDevice,
    logical_size: u64,
    chunk_size: u64,
    hash_algorithm: []const u8 = spore.rootfs_storage_hash_algorithm_blake3,
    index_digest: []const u8,
    base_identity: []const u8,
    object_namespace: []const u8 = spore.rootfs_storage_object_namespace,
    index_path: []const u8,
    index_bytes: u64,
    object_count: usize,
    object_bytes: u64,
};

pub const RootfsIndex = struct {
    version: u32 = rootfs_index_version,
    artifacts: []RootfsArtifactEntry = &.{},
    storages: []RootfsStorageEntry = &.{},
};

const VerifiedContentSource = struct {
    ctx: *anyopaque,
    read_chunk_fn: *const fn (*anyopaque, std.mem.Allocator, IndexChunk, []const u8, usize) Error![]u8,

    fn readChunk(
        self: VerifiedContentSource,
        allocator: std.mem.Allocator,
        entry: IndexChunk,
        expected_id: []const u8,
        expected_size: usize,
    ) Error![]u8 {
        return self.read_chunk_fn(self.ctx, allocator, entry, expected_id, expected_size);
    }
};

const LocalBundleContentSource = struct {
    bundle_dir: []const u8,

    fn source(self: *LocalBundleContentSource) VerifiedContentSource {
        return .{
            .ctx = self,
            .read_chunk_fn = readChunk,
        };
    }

    fn readChunk(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        entry: IndexChunk,
        expected_id: []const u8,
        expected_size: usize,
    ) Error![]u8 {
        const self: *LocalBundleContentSource = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, entry.id, expected_id)) return error.BadManifest;
        if (entry.size != @as(u64, @intCast(expected_size))) return error.BadManifest;
        const source_pack_path = try pathZ(allocator, "{s}/{s}", .{ self.bundle_dir, entry.pack });
        const data = try readFileRange(allocator, source_pack_path, entry.offset, entry.size);
        errdefer allocator.free(data);
        if (!sha256HexMatches(entry.sha256, data)) return error.BadChunk;
        const id = chunklib.ChunkId.fromHex(expected_id) catch return error.BadManifest;
        if (!id.matches(data)) return error.BadChunk;
        return data;
    }
};

const MaterializeResult = struct {
    chunk_count: usize,
    materialized_chunk_count: usize = 0,
    payload_bytes: u64 = 0,
    cache_hit_count: usize = 0,
    cache_miss_count: usize = 0,
    cache_reused_bytes: u64 = 0,
    linked_chunk_count: usize = 0,
    copied_chunk_count: usize = 0,
};

const RemoteBundleFileClass = enum {
    metadata,
    payload,
};

const RemoteBundleDownloadBudget = struct {
    total_read: u64 = 0,
    metadata_read: u64 = 0,

    fn limitFor(self: RemoteBundleDownloadBudget, class: RemoteBundleFileClass, file_limit: u64) Error!u64 {
        if (self.total_read >= max_remote_bundle_materialization_bytes) return error.BundleBodyTooLarge;
        var limit = @min(file_limit, max_remote_bundle_materialization_bytes - self.total_read);
        if (class == .metadata) {
            if (self.metadata_read >= max_remote_bundle_metadata_bytes) return error.BundleBodyTooLarge;
            limit = @min(limit, max_remote_bundle_metadata_bytes - self.metadata_read);
        }
        return limit;
    }

    fn record(self: *RemoteBundleDownloadBudget, class: RemoteBundleFileClass, bytes: u64) Error!void {
        if (bytes > max_remote_bundle_materialization_bytes - self.total_read) return error.BundleBodyTooLarge;
        self.total_read += bytes;
        if (class == .metadata) {
            if (bytes > max_remote_bundle_metadata_bytes - self.metadata_read) return error.BundleBodyTooLarge;
            self.metadata_read += bytes;
        }
    }
};

const RootfsMaterializeResult = struct {
    artifact_count: usize = 0,
    payload_bytes: u64 = 0,
    cache_hit_count: usize = 0,
    cache_miss_count: usize = 0,
    bytes_fetched: u64 = 0,
    bytes_reused: u64 = 0,
};

pub fn inspectBundle(allocator: std.mem.Allocator, options: InspectBundleOptions) Error!InspectBundleResult {
    if (options.child_id != null and options.child_range != null) return error.BadManifest;

    const bundle_dir = try localBundleRefPath(allocator, options.source);
    errdefer allocator.free(bundle_dir);
    try ensureInspectableBundlePath(allocator, bundle_dir);
    const bundle_digest = try digestHex(allocator, bundle_dir);
    errdefer allocator.free(bundle_digest);
    const parsed_index = try loadIndex(allocator, bundle_dir);
    defer parsed_index.deinit();
    const chunkpack = try summarizeChunkpack(allocator, parsed_index.value);

    if (try hasBundleIndex(allocator, bundle_dir)) {
        return inspectIndexedBundle(allocator, options, bundle_dir, bundle_digest, chunkpack);
    }

    if (options.child_id != null or options.child_range != null) return error.BadManifest;
    const rootfs = try inspectLegacyRootfs(allocator, bundle_dir);
    const parent_manifest = allocator.dupe(u8, "manifest.json") catch return error.OutOfMemory;
    errdefer allocator.free(parent_manifest);
    const chunkpack_index = allocator.dupe(u8, index_path) catch return error.OutOfMemory;
    errdefer allocator.free(chunkpack_index);
    return .{
        .source = options.source,
        .bundle_dir = bundle_dir,
        .bundle_digest = contracts.digestRef(bundle_digest),
        .indexed = false,
        .parent_manifest = parent_manifest,
        .chunkpack_index = chunkpack_index,
        .chunkpack = chunkpack,
        .rootfs = rootfs,
    };
}

fn inspectIndexedBundle(
    allocator: std.mem.Allocator,
    options: InspectBundleOptions,
    bundle_dir: []const u8,
    bundle_digest: []const u8,
    chunkpack: ChunkpackSummary,
) Error!InspectBundleResult {
    const parsed_bundle = try loadBundleIndex(allocator, bundle_dir);
    defer parsed_bundle.deinit();
    const bundle_index = parsed_bundle.value;
    const children = try childSummaries(allocator, bundle_index.children);
    errdefer contracts.deinitBundleChildSummaries(allocator, children);
    const selection = try inspectSelection(allocator, bundle_index, options.child_id, options.child_range);
    errdefer contracts.deinitBundleSelectionSummary(allocator, selection);
    const rootfs = try inspectIndexedRootfs(allocator, bundle_dir, bundle_index);
    const parent_manifest = allocator.dupe(u8, bundle_index.parent_manifest) catch return error.OutOfMemory;
    errdefer allocator.free(parent_manifest);
    const chunkpack_index = allocator.dupe(u8, bundle_index.chunkpack_index) catch return error.OutOfMemory;
    errdefer allocator.free(chunkpack_index);
    return .{
        .source = options.source,
        .bundle_dir = bundle_dir,
        .bundle_digest = contracts.digestRef(bundle_digest),
        .indexed = true,
        .parent_manifest = parent_manifest,
        .chunkpack_index = chunkpack_index,
        .chunkpack = chunkpack,
        .child_count = bundle_index.children.len,
        .children = children,
        .selection = selection,
        .rootfs = rootfs,
    };
}

fn localBundleRefPath(allocator: std.mem.Allocator, source: []const u8) Error![]const u8 {
    if (std.mem.startsWith(u8, source, "file://")) return localFileUriPath(allocator, source);
    if (std.mem.startsWith(u8, source, "s3://") or
        std.mem.startsWith(u8, source, "http://") or
        std.mem.startsWith(u8, source, "https://"))
    {
        return error.BadManifest;
    }
    return std.fs.path.resolve(allocator, &.{source}) catch return error.IoFailed;
}

fn ensureInspectableBundlePath(allocator: std.mem.Allocator, bundle_dir: []const u8) Error!void {
    const path = try pathZ(allocator, "{s}", .{bundle_dir});
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) {
        return switch (std.c.errno(fd)) {
            .NOENT => error.FileNotFound,
            .NOTDIR => error.BadManifest,
            else => error.IoFailed,
        };
    }
    _ = std.c.close(fd);
}

fn summarizeChunkpack(allocator: std.mem.Allocator, index: Index) Error!ChunkpackSummary {
    var packs = std.StringHashMap(void).init(allocator);
    defer packs.deinit();
    var payload_bytes: u64 = 0;
    for (index.chunks) |chunk| {
        const existing = packs.getOrPut(chunk.pack) catch return error.OutOfMemory;
        _ = existing;
        payload_bytes += chunk.size;
    }
    return .{
        .chunk_count = index.chunks.len,
        .pack_count = packs.count(),
        .payload_bytes = payload_bytes,
    };
}

fn childSummaries(allocator: std.mem.Allocator, children: []const BundleChild) Error![]const BundleChildSummary {
    const out = allocator.alloc(BundleChildSummary, children.len) catch return error.OutOfMemory;
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |summary| {
            allocator.free(summary.id);
            allocator.free(summary.manifest);
        }
        allocator.free(out);
    }
    for (children, out) |child, *summary| {
        const id = allocator.dupe(u8, child.id) catch return error.OutOfMemory;
        errdefer allocator.free(id);
        const manifest = allocator.dupe(u8, child.manifest) catch return error.OutOfMemory;
        summary.* = .{
            .id = id,
            .manifest = manifest,
        };
        initialized += 1;
    }
    return out;
}

fn inspectSelection(
    allocator: std.mem.Allocator,
    index: BundleIndex,
    child_id: ?[]const u8,
    child_range: ?ChildRange,
) Error!BundleSelectionSummary {
    if (child_id) |raw| {
        const canonical = try canonicalChildId(allocator, raw);
        defer allocator.free(canonical);
        const child = try findBundleChild(index, canonical);
        const children = allocator.alloc(BundleChildSummary, 1) catch return error.OutOfMemory;
        errdefer allocator.free(children);
        const id = allocator.dupe(u8, child.id) catch return error.OutOfMemory;
        errdefer allocator.free(id);
        const manifest = allocator.dupe(u8, child.manifest) catch return error.OutOfMemory;
        errdefer {
            allocator.free(manifest);
        }
        children[0] = .{ .id = id, .manifest = manifest };
        return .{ .kind = "child", .selected_count = 1, .children = children };
    }

    if (child_range) |range| {
        if (range.start > range.end) return error.BadManifest;
        var selected = std.array_list.Managed(BundleChildSummary).init(allocator);
        errdefer {
            for (selected.items) |child| {
                allocator.free(child.id);
                allocator.free(child.manifest);
            }
            selected.deinit();
        }
        for (index.children) |child| {
            const value = std.fmt.parseInt(u32, child.id, 10) catch return error.BadManifest;
            if (value < range.start or value > range.end) continue;
            const id = allocator.dupe(u8, child.id) catch return error.OutOfMemory;
            const manifest = allocator.dupe(u8, child.manifest) catch {
                allocator.free(id);
                return error.OutOfMemory;
            };
            selected.append(.{
                .id = id,
                .manifest = manifest,
            }) catch {
                allocator.free(id);
                allocator.free(manifest);
                return error.OutOfMemory;
            };
        }
        if (selected.items.len == 0) return error.BadManifest;
        const children = selected.toOwnedSlice() catch return error.OutOfMemory;
        return .{ .kind = "child_range", .selected_count = children.len, .children = children };
    }

    return .{ .kind = "none" };
}

fn findBundleChild(index: BundleIndex, child_id: []const u8) Error!BundleChild {
    try validateChildId(child_id);
    for (index.children) |child| {
        if (std.mem.eql(u8, child.id, child_id)) return child;
    }
    return error.BadManifest;
}

fn inspectLegacyRootfs(allocator: std.mem.Allocator, bundle_dir: []const u8) Error!RootfsBundleSummary {
    var parsed_manifest = try LoadedManifest.loadDir(allocator, bundle_dir);
    defer parsed_manifest.deinit();
    const rootfs = parsed_manifest.rootfs() orelse return .{};
    return .{
        .artifact_count = 1,
        .exact_bytes_count = 1,
        .payload_bytes = rootfs.artifact.size,
    };
}

fn inspectIndexedRootfs(allocator: std.mem.Allocator, bundle_dir: []const u8, bundle_index: BundleIndex) Error!RootfsBundleSummary {
    if (bundle_index.rootfs_index == null) return .{};
    const parsed_rootfs = try loadRootfsIndex(allocator, bundle_dir);
    defer parsed_rootfs.deinit();
    var summary = RootfsBundleSummary{
        .artifact_count = parsed_rootfs.value.artifacts.len,
        .storage_count = parsed_rootfs.value.storages.len,
    };
    for (parsed_rootfs.value.artifacts) |artifact| {
        if (std.mem.eql(u8, artifact.policy, rootfs_policy_exact_bytes)) {
            summary.exact_bytes_count += 1;
            summary.payload_bytes += artifact.size;
        } else if (std.mem.eql(u8, artifact.policy, rootfs_policy_metadata_only)) {
            summary.metadata_only_count += 1;
        } else {
            return error.BadManifest;
        }
    }
    for (parsed_rootfs.value.storages) |storage| {
        summary.object_count += storage.object_count;
        summary.payload_bytes += storage.index_bytes + storage.object_bytes;
    }
    return summary;
}

pub fn pack(allocator: std.mem.Allocator, options: PackOptions) Error!PackResult {
    if (options.children_dir != null or options.rootfs_policy != .exact_bytes) return packIndexed(allocator, options);

    var manifest = try LoadedManifest.loadDir(allocator, options.spore_dir);
    defer manifest.deinit();
    manifest.clearMemoryBacking();
    if (manifest.rootfs()) |rootfs| {
        if (rootfs.storage != null) return packIndexed(allocator, options);
    }
    const memory = manifest.memory();
    const ram_size = manifest.ramSize();
    const plan = try spore.validateMemoryForRam(memory, @intCast(ram_size));

    try ensureNewDir(try pathZ(allocator, "{s}", .{options.out_dir}));
    try ensureNewDir(try pathZ(allocator, "{s}/chunkpacks", .{options.out_dir}));

    const bundle_pack_path = try pathZ(allocator, "{s}/{s}", .{ options.out_dir, pack_path });
    const pack_fd = std.c.open(bundle_pack_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
    if (pack_fd < 0) return error.IoFailed;
    defer _ = std.c.close(pack_fd);

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    const entries = allocator.alloc(IndexChunk, plan.nonzero_chunk_count) catch return error.OutOfMemory;
    var entry_count: usize = 0;
    var payload_bytes: u64 = 0;

    var i: usize = 0;
    while (i < plan.chunk_count) : (i += 1) {
        const ref = memory.chunks[i] orelse continue;
        if (seen.contains(ref)) continue;
        seen.put(ref, {}) catch return error.OutOfMemory;

        const range = chunkRange(plan, @intCast(ram_size), i) catch return error.BadManifest;
        const expected_size = range.end - range.start;
        const chunk_path = try pathZ(allocator, "{s}/chunks/{s}", .{ options.spore_dir, ref });
        const data = try readFileAll(allocator, chunk_path, expected_size);
        defer allocator.free(data);
        if (data.len != expected_size) return error.BadChunk;
        const id = chunklib.ChunkId.fromHex(ref) catch return error.BadManifest;
        if (!id.matches(data)) return error.BadChunk;
        if (payload_bytes > std.math.maxInt(usize)) return error.BadChunk;
        try pwriteFileAll(pack_fd, @intCast(payload_bytes), data);
        entries[entry_count] = .{
            .id = ref,
            .pack = pack_path,
            .offset = payload_bytes,
            .size = @intCast(data.len),
            .sha256 = try sha256HexAlloc(allocator, data),
        };
        entry_count += 1;
        payload_bytes += @intCast(data.len);
    }

    const rootfs_payload_bytes = try packRootfsArtifact(allocator, options, manifest.rootfs());
    try packDiskLayersForManifest(allocator, options.spore_dir, options.out_dir, manifest.disk());
    try manifest.saveDir(allocator, options.out_dir);
    try saveIndex(allocator, options.out_dir, .{
        .chunk_size = spore.chunk_size,
        .chunks = entries[0..entry_count],
    });
    const bundle_digest = try digestHex(allocator, options.out_dir);

    return .{
        .source = options.spore_dir,
        .out_dir = options.out_dir,
        .bundle_digest = bundle_digest,
        .chunk_count = plan.chunk_count,
        .packed_chunk_count = entry_count,
        .pack_count = 1,
        .payload_bytes = payload_bytes,
        .rootfs_artifact_count = if (manifest.rootfs() == null) 0 else 1,
        .rootfs_payload_bytes = rootfs_payload_bytes,
    };
}

fn packIndexed(allocator: std.mem.Allocator, options: PackOptions) Error!PackResult {
    const children: []const ChildDir = if (options.children_dir) |children_dir| blk: {
        const listed = try listChildDirs(allocator, options.io, children_dir);
        if (listed.len == 0) return error.BadManifest;
        break :blk listed;
    } else &.{};

    try ensureNewDir(try pathZ(allocator, "{s}", .{options.out_dir}));
    try ensureNewDir(try pathZ(allocator, "{s}/{s}", .{ options.out_dir, manifests_dir_path }));
    try ensureNewDir(try pathZ(allocator, "{s}/{s}", .{ options.out_dir, child_manifests_dir_path }));
    try ensureNewDir(try pathZ(allocator, "{s}/chunkpacks", .{options.out_dir}));
    try ensureNewDir(try pathZ(allocator, "{s}/{s}", .{ options.out_dir, rootfs_dir_path }));
    try ensureNewDir(try pathZ(allocator, "{s}/{s}", .{ options.out_dir, rootfs_blake3_dir_path }));
    try ensureNewDir(try pathZ(allocator, "{s}/{s}", .{ options.out_dir, rootfs_blake3_indexes_dir_path }));
    try ensureNewDir(try pathZ(allocator, "{s}/{s}", .{ options.out_dir, rootfs_blake3_objects_dir_path }));

    const bundle_pack_path = try pathZ(allocator, "{s}/{s}", .{ options.out_dir, pack_path });
    const pack_fd = std.c.open(bundle_pack_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
    if (pack_fd < 0) return error.IoFailed;
    defer _ = std.c.close(pack_fd);

    var seen_chunks = std.StringHashMap(void).init(allocator);
    defer seen_chunks.deinit();
    var chunk_entries = std.array_list.Managed(IndexChunk).init(allocator);
    defer chunk_entries.deinit();
    var seen_rootfs = std.StringHashMap(void).init(allocator);
    defer seen_rootfs.deinit();
    var seen_rootfs_storage = std.StringHashMap(void).init(allocator);
    defer seen_rootfs_storage.deinit();
    var seen_rootfs_objects = std.StringHashMap(void).init(allocator);
    defer seen_rootfs_objects.deinit();
    var rootfs_entries = std.array_list.Managed(RootfsArtifactEntry).init(allocator);
    defer rootfs_entries.deinit();
    var rootfs_storage_entries = std.array_list.Managed(RootfsStorageEntry).init(allocator);
    defer rootfs_storage_entries.deinit();
    var bundle_children = std.array_list.Managed(BundleChild).init(allocator);
    defer bundle_children.deinit();

    var payload_bytes: u64 = 0;
    var rootfs_payload_bytes: u64 = 0;
    var total_chunk_count: usize = 0;

    var parent_manifest = try LoadedManifest.loadDir(allocator, options.spore_dir);
    defer parent_manifest.deinit();
    parent_manifest.clearMemoryBacking();
    total_chunk_count += (try packManifestChunks(
        allocator,
        parent_manifest.memory(),
        parent_manifest.ramSize(),
        options.spore_dir,
        pack_fd,
        &seen_chunks,
        &chunk_entries,
        &payload_bytes,
    )).chunk_count;
    rootfs_payload_bytes += try packRootfsIndexed(
        allocator,
        options,
        parent_manifest.rootfs(),
        &seen_rootfs,
        &rootfs_entries,
        &seen_rootfs_storage,
        &rootfs_storage_entries,
        &seen_rootfs_objects,
    );
    try packDiskLayersForManifest(allocator, options.spore_dir, options.out_dir, parent_manifest.disk());
    try parent_manifest.savePath(allocator, try pathZ(allocator, "{s}/{s}", .{ options.out_dir, parent_manifest_path }));

    for (children) |child| {
        const child_dir = child.path;
        var child_manifest = try LoadedManifest.loadDir(allocator, child_dir);
        defer child_manifest.deinit();
        child_manifest.clearMemoryBacking();
        total_chunk_count += (try packManifestChunks(
            allocator,
            child_manifest.memory(),
            child_manifest.ramSize(),
            child_dir,
            pack_fd,
            &seen_chunks,
            &chunk_entries,
            &payload_bytes,
        )).chunk_count;
        rootfs_payload_bytes += try packRootfsIndexed(
            allocator,
            options,
            child_manifest.rootfs(),
            &seen_rootfs,
            &rootfs_entries,
            &seen_rootfs_storage,
            &rootfs_storage_entries,
            &seen_rootfs_objects,
        );
        try packDiskLayersForManifest(allocator, child_dir, options.out_dir, child_manifest.disk());
        const manifest_rel = try childManifestRelPath(allocator, child.id);
        try child_manifest.savePath(allocator, try pathZ(allocator, "{s}/{s}", .{ options.out_dir, manifest_rel }));
        try bundle_children.append(.{
            .id = child.id,
            .manifest = manifest_rel,
        });
    }

    try saveIndex(allocator, options.out_dir, .{
        .chunk_size = spore.chunk_size,
        .chunks = chunk_entries.items,
    });

    const rootfs_index_rel: ?[]const u8 = if (rootfs_entries.items.len > 0 or rootfs_storage_entries.items.len > 0) blk: {
        std.mem.sort(RootfsArtifactEntry, rootfs_entries.items, {}, lessRootfsArtifactEntry);
        std.mem.sort(RootfsStorageEntry, rootfs_storage_entries.items, {}, lessRootfsStorageEntry);
        try saveRootfsIndex(allocator, options.out_dir, .{
            .artifacts = rootfs_entries.items,
            .storages = rootfs_storage_entries.items,
        });
        break :blk rootfs_index_path;
    } else null;

    try saveBundleIndex(allocator, options.out_dir, .{
        .children = bundle_children.items,
        .rootfs_index = rootfs_index_rel,
    });

    const bundle_digest = try digestHex(allocator, options.out_dir);
    return .{
        .source = options.spore_dir,
        .out_dir = options.out_dir,
        .bundle_digest = bundle_digest,
        .chunk_count = total_chunk_count,
        .packed_chunk_count = chunk_entries.items.len,
        .pack_count = 1,
        .payload_bytes = payload_bytes,
        .rootfs_artifact_count = rootfs_entries.items.len + rootfs_storage_entries.items.len,
        .rootfs_payload_bytes = rootfs_payload_bytes,
        .child_count = children.len,
    };
}

pub fn unpack(allocator: std.mem.Allocator, options: UnpackOptions) Error!UnpackResult {
    if (try hasBundleIndex(allocator, options.bundle_dir)) return unpackIndexed(allocator, options);
    if (options.child_id != null) return error.BadManifest;

    var manifest = try LoadedManifest.loadDir(allocator, options.bundle_dir);
    defer manifest.deinit();
    manifest.clearMemoryBacking();
    const plan = try spore.validateMemoryForRam(manifest.memory(), @intCast(manifest.ramSize()));

    const parsed_index = try loadIndex(allocator, options.bundle_dir);
    defer parsed_index.deinit();
    try validateIndex(allocator, parsed_index.value);

    var by_id = try indexById(allocator, parsed_index.value);
    defer by_id.deinit();
    var local_source = LocalBundleContentSource{ .bundle_dir = options.bundle_dir };
    const materialized = try materializeChunks(
        allocator,
        options.io,
        options.out_dir,
        manifest.memory(),
        manifest.ramSize(),
        plan,
        &by_id,
        local_source.source(),
        null,
    );

    const rootfs_result = try unpackRootfsArtifact(allocator, options, manifest.rootfs());
    try unpackDiskLayersForManifest(allocator, options.bundle_dir, options.out_dir, manifest.disk());
    try manifest.saveDir(allocator, options.out_dir);
    const bundle_digest = try digestHex(allocator, options.bundle_dir);

    return .{
        .bundle = options.bundle_dir,
        .out_dir = options.out_dir,
        .bundle_digest = bundle_digest,
        .chunk_count = plan.chunk_count,
        .unpacked_chunk_count = materialized.materialized_chunk_count,
        .payload_bytes = materialized.payload_bytes,
        .rootfs_artifact_count = rootfs_result.artifact_count,
        .rootfs_payload_bytes = rootfs_result.payload_bytes,
    };
}

fn unpackIndexed(allocator: std.mem.Allocator, options: UnpackOptions) Error!UnpackResult {
    const parsed_bundle = try loadBundleIndex(allocator, options.bundle_dir);
    defer parsed_bundle.deinit();
    const bundle_index = parsed_bundle.value;

    const child_id = if (options.child_id) |id| try canonicalChildId(allocator, id) else null;
    const selected_rel = try selectedManifestPath(allocator, bundle_index, child_id);
    var manifest = try LoadedManifest.loadPath(
        allocator,
        try pathZ(allocator, "{s}/{s}", .{ options.bundle_dir, selected_rel }),
    );
    defer manifest.deinit();
    manifest.clearMemoryBacking();
    const plan = try spore.validateMemoryForRam(manifest.memory(), @intCast(manifest.ramSize()));

    const parsed_index = try loadIndex(allocator, options.bundle_dir);
    defer parsed_index.deinit();
    try validateIndex(allocator, parsed_index.value);

    const rootfs_result = try unpackRootfsArtifactIndexed(allocator, options, bundle_index, manifest.rootfs());

    var by_id = try indexById(allocator, parsed_index.value);
    defer by_id.deinit();
    var local_source = LocalBundleContentSource{ .bundle_dir = options.bundle_dir };
    const materialized = try materializeChunks(
        allocator,
        options.io,
        options.out_dir,
        manifest.memory(),
        manifest.ramSize(),
        plan,
        &by_id,
        local_source.source(),
        null,
    );

    try unpackDiskLayersForManifest(allocator, options.bundle_dir, options.out_dir, manifest.disk());
    try manifest.saveDir(allocator, options.out_dir);
    const bundle_digest = try digestHex(allocator, options.bundle_dir);

    return .{
        .bundle = options.bundle_dir,
        .out_dir = options.out_dir,
        .bundle_digest = bundle_digest,
        .chunk_count = plan.chunk_count,
        .unpacked_chunk_count = materialized.materialized_chunk_count,
        .payload_bytes = materialized.payload_bytes,
        .rootfs_artifact_count = rootfs_result.artifact_count,
        .rootfs_payload_bytes = rootfs_result.payload_bytes,
        .child_count = bundle_index.children.len,
        .selected_child = child_id,
    };
}

pub fn push(allocator: std.mem.Allocator, options: PushOptions) Error!PushResult {
    const destination = try parseS3Destination(allocator, options.destination);
    const files = try indexedBundleFiles(allocator, options.bundle_dir);
    const bundle_digest = try digestHex(allocator, options.bundle_dir);

    var uploaded_bytes: u64 = 0;
    for (files) |rel_path| {
        const local_path = try pathZ(allocator, "{s}/{s}", .{ options.bundle_dir, rel_path });
        uploaded_bytes += try fileSizeNoSymlink(options.io, local_path);
        const object_uri = try destination.objectUri(allocator, rel_path);
        try runAwsS3Cp(allocator, options.io, options.aws_executable, local_path, object_uri, options.aws_region);
    }

    const final_digest = try digestHex(allocator, options.bundle_dir);
    if (!std.mem.eql(u8, bundle_digest, final_digest)) return error.BadChunk;

    return .{
        .source = options.bundle_dir,
        .destination = options.destination,
        .bundle_digest = bundle_digest,
        .uploaded_file_count = files.len,
        .uploaded_bytes = uploaded_bytes,
    };
}

pub fn pull(allocator: std.mem.Allocator, options: PullOptions) Error!PullResult {
    if (std.mem.startsWith(u8, options.source, "s3://")) {
        const remote = try parseS3Source(allocator, options.source);
        const cached = try materializeS3Bundle(allocator, options, remote);
        var result = try pullLocalIndexedBundle(allocator, options, cached.bundle_dir, options.source);
        result.remote.origin_bytes_read = cached.origin_bytes_read;
        result.remote.cache_hit = cached.cache_hit;
        return result;
    }
    if (std.mem.startsWith(u8, options.source, "http://") or std.mem.startsWith(u8, options.source, "https://")) {
        const remote = try parseHttpSource(allocator, options.source);
        var client: std.http.Client = .{ .allocator = allocator, .io = options.io };
        defer client.deinit();
        const cached = try materializeHttpBundle(allocator, options, &client, remote);
        var result = try pullLocalIndexedBundle(allocator, options, cached.bundle_dir, options.source);
        result.remote.peer_bytes_read = cached.origin_bytes_read;
        result.remote.cache_hit = cached.cache_hit;
        return result;
    }
    const bundle_dir = try localFileUriPath(allocator, options.source);
    return pullLocalIndexedBundle(allocator, options, bundle_dir, options.source);
}

fn pullLocalIndexedBundle(
    allocator: std.mem.Allocator,
    options: PullOptions,
    bundle_dir: []const u8,
    source: []const u8,
) Error!PullResult {
    const child_id = if (options.child_id) |id| try canonicalChildId(allocator, id) else null;

    const parsed_bundle = try loadBundleIndex(allocator, bundle_dir);
    defer parsed_bundle.deinit();
    const bundle_index = parsed_bundle.value;

    const selected_rel = try selectedManifestPath(allocator, bundle_index, child_id);
    var manifest = try LoadedManifest.loadPath(
        allocator,
        try pathZ(allocator, "{s}/{s}", .{ bundle_dir, selected_rel }),
    );
    defer manifest.deinit();
    manifest.clearMemoryBacking();
    const plan = try spore.validateMemoryForRam(manifest.memory(), @intCast(manifest.ramSize()));

    const parsed_index = try loadIndex(allocator, bundle_dir);
    defer parsed_index.deinit();
    try validateIndex(allocator, parsed_index.value);
    const unpack_options = UnpackOptions{
        .io = options.io,
        .bundle_dir = bundle_dir,
        .out_dir = options.out_dir,
        .rootfs_cache_dir = options.rootfs_cache_dir,
        .child_id = child_id,
        .allow_metadata_only_rootfs = options.allow_metadata_only_rootfs,
    };
    const rootfs_result = try unpackRootfsArtifactIndexed(allocator, unpack_options, bundle_index, manifest.rootfs());

    var by_id = try indexById(allocator, parsed_index.value);
    defer by_id.deinit();

    var local_source = LocalBundleContentSource{ .bundle_dir = bundle_dir };
    const materialized = try materializeChunks(
        allocator,
        options.io,
        options.out_dir,
        manifest.memory(),
        manifest.ramSize(),
        plan,
        &by_id,
        local_source.source(),
        options.bundle_cache_dir,
    );

    try unpackDiskLayersForManifest(allocator, bundle_dir, options.out_dir, manifest.disk());
    try manifest.saveDir(allocator, options.out_dir);
    const bundle_digest = try digestHex(allocator, bundle_dir);

    return .{
        .source = source,
        .bundle_dir = bundle_dir,
        .out_dir = options.out_dir,
        .bundle_digest = contracts.digestRef(bundle_digest),
        .materialization = .{
            .chunk_count = plan.chunk_count,
            .materialized_chunk_count = materialized.materialized_chunk_count,
            .payload_bytes = materialized.payload_bytes,
            .linked_chunk_count = materialized.linked_chunk_count,
            .copied_chunk_count = materialized.copied_chunk_count,
            .cache = .{
                .hit_count = materialized.cache_hit_count,
                .miss_count = materialized.cache_miss_count,
                .bytes_fetched = materialized.payload_bytes,
                .bytes_reused = materialized.cache_reused_bytes,
            },
        },
        .rootfs = .{
            .artifact_count = rootfs_result.artifact_count,
            .payload_bytes = rootfs_result.payload_bytes,
            .cache = .{
                .hit_count = rootfs_result.cache_hit_count,
                .miss_count = rootfs_result.cache_miss_count,
                .bytes_fetched = rootfs_result.bytes_fetched,
                .bytes_reused = rootfs_result.bytes_reused,
            },
        },
        .children = .{
            .count = bundle_index.children.len,
            .selected_child = child_id,
        },
    };
}

pub fn digestHex(allocator: std.mem.Allocator, bundle_dir: []const u8) Error![]const u8 {
    if (try hasBundleIndex(allocator, bundle_dir)) return digestHexIndexed(allocator, bundle_dir);

    const parsed_index = try loadIndex(allocator, bundle_dir);
    defer parsed_index.deinit();
    _ = parsed_index.value.chunks.len;

    var h = Sha256.init(.{});
    h.update("sporevm-bundle-v0");
    h.update(&[_]u8{0});
    try updateHashWithFile(allocator, &h, bundle_dir, "manifest.json");
    try updateHashWithFile(allocator, &h, bundle_dir, index_path);
    try updateHashWithFile(allocator, &h, bundle_dir, pack_path);
    var parsed_manifest = try LoadedManifest.loadDir(allocator, bundle_dir);
    defer parsed_manifest.deinit();
    if (parsed_manifest.rootfs()) |rootfs| {
        const rel_path = try rootfsArtifactRelPath(allocator, rootfs.artifact);
        try updateHashWithFile(allocator, &h, bundle_dir, rel_path);
    }
    var seen_disk_files = std.StringHashMap(void).init(allocator);
    defer seen_disk_files.deinit();
    try updateHashWithDiskFilesForManifest(allocator, &h, bundle_dir, parsed_manifest.disk(), &seen_disk_files);

    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex) catch return error.OutOfMemory;
}

fn digestHexIndexed(allocator: std.mem.Allocator, bundle_dir: []const u8) Error![]const u8 {
    const parsed_bundle = try loadBundleIndex(allocator, bundle_dir);
    defer parsed_bundle.deinit();
    const bundle_index = parsed_bundle.value;

    const parsed_chunk_index = try loadIndex(allocator, bundle_dir);
    defer parsed_chunk_index.deinit();
    _ = parsed_chunk_index.value.chunks.len;

    var h = Sha256.init(.{});
    h.update("sporevm-bundle-v0");
    h.update(&[_]u8{0});
    try updateHashWithFile(allocator, &h, bundle_dir, bundle_index_path);
    try updateHashWithFile(allocator, &h, bundle_dir, bundle_index.parent_manifest);
    for (bundle_index.children) |child| {
        try updateHashWithFile(allocator, &h, bundle_dir, child.manifest);
    }
    try updateHashWithFile(allocator, &h, bundle_dir, index_path);
    try updateHashWithFile(allocator, &h, bundle_dir, pack_path);
    if (bundle_index.rootfs_index) |rootfs_index_rel| {
        try updateHashWithFile(allocator, &h, bundle_dir, rootfs_index_rel);
        const parsed_rootfs_index = try loadRootfsIndex(allocator, bundle_dir);
        defer parsed_rootfs_index.deinit();
        try updateHashWithRootfsIndexPayloads(allocator, &h, bundle_dir, parsed_rootfs_index.value);
    }
    var seen_disk_files = std.StringHashMap(void).init(allocator);
    defer seen_disk_files.deinit();
    try updateHashWithDiskFilesForManifestPath(allocator, &h, bundle_dir, bundle_index.parent_manifest, &seen_disk_files);
    for (bundle_index.children) |child| {
        try updateHashWithDiskFilesForManifestPath(allocator, &h, bundle_dir, child.manifest, &seen_disk_files);
    }

    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex) catch return error.OutOfMemory;
}

fn updateHashWithRootfsIndexPayloads(
    allocator: std.mem.Allocator,
    h: *Sha256,
    bundle_dir: []const u8,
    index: RootfsIndex,
) Error!void {
    for (index.artifacts) |artifact| {
        if (std.mem.eql(u8, artifact.policy, rootfs_policy_exact_bytes)) {
            try updateHashWithFile(allocator, h, bundle_dir, artifact.path orelse return error.BadManifest);
        }
    }

    var seen_objects = std.StringHashMap(void).init(allocator);
    defer seen_objects.deinit();
    for (index.storages) |storage_entry| {
        try updateHashWithFile(allocator, h, bundle_dir, storage_entry.index_path);
        const storage = rootfsStorageEntryDescriptor(storage_entry);
        const parsed_index = try loadDiskIndexForEntry(allocator, bundle_dir, storage_entry, storage);
        defer parsed_index.deinit();
        for (parsed_index.value.chunks) |chunk_entry| {
            const rel_path = try rootfsStorageObjectRelPath(allocator, chunk_entry.digest);
            if (!try markBundleFileSeen(&seen_objects, rel_path)) continue;
            try updateHashWithFile(allocator, h, bundle_dir, rel_path);
        }
    }
}

fn saveIndex(allocator: std.mem.Allocator, dir: []const u8, index: Index) Error!void {
    const json = std.json.Stringify.valueAlloc(allocator, index, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
    defer allocator.free(json);
    const path = try pathZ(allocator, "{s}/{s}", .{ dir, index_path });
    try writeFileAll(path, json);
}

fn loadIndex(allocator: std.mem.Allocator, dir: []const u8) Error!std.json.Parsed(Index) {
    const path = try pathZ(allocator, "{s}/{s}", .{ dir, index_path });
    const bytes = try readFileAll(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(bytes);
    const parsed = std.json.parseFromSlice(Index, allocator, bytes, .{
        .allocate = .alloc_always,
    }) catch return error.BadManifest;
    errdefer parsed.deinit();
    try validateIndex(allocator, parsed.value);
    return parsed;
}

fn validateIndex(allocator: std.mem.Allocator, index: Index) Error!void {
    if (index.version != index_version) return error.BadManifest;
    if (index.chunk_size != spore.chunk_size) return error.BadManifest;
    var ids = std.StringHashMap(void).init(allocator);
    defer ids.deinit();
    for (index.chunks) |entry| {
        try validateChunk(entry);
        const existing = ids.getOrPut(entry.id) catch return error.OutOfMemory;
        if (existing.found_existing) return error.BadManifest;
    }
}

fn saveBundleIndex(allocator: std.mem.Allocator, dir: []const u8, index: BundleIndex) Error!void {
    try validateBundleIndex(allocator, index);
    const json = std.json.Stringify.valueAlloc(allocator, index, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
    defer allocator.free(json);
    const path = try pathZ(allocator, "{s}/{s}", .{ dir, bundle_index_path });
    try writeFileAll(path, json);
}

fn loadBundleIndex(allocator: std.mem.Allocator, dir: []const u8) Error!std.json.Parsed(BundleIndex) {
    const path = try pathZ(allocator, "{s}/{s}", .{ dir, bundle_index_path });
    const bytes = try readFileAll(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(bytes);
    const parsed = std.json.parseFromSlice(BundleIndex, allocator, bytes, .{
        .allocate = .alloc_always,
    }) catch return error.BadManifest;
    errdefer parsed.deinit();
    try validateBundleIndex(allocator, parsed.value);
    return parsed;
}

fn validateBundleIndex(allocator: std.mem.Allocator, index: BundleIndex) Error!void {
    if (index.version != bundle_index_version) return error.BadManifest;
    if (!std.mem.eql(u8, index.parent_manifest, parent_manifest_path)) return error.BadManifest;
    if (!std.mem.eql(u8, index.chunkpack_index, index_path)) return error.BadManifest;
    if (index.rootfs_index) |path| {
        if (!std.mem.eql(u8, path, rootfs_index_path)) return error.BadManifest;
    }
    var ids = std.StringHashMap(void).init(allocator);
    defer ids.deinit();
    var previous: ?[]const u8 = null;
    for (index.children) |child| {
        try validateChildId(child.id);
        var path_buf: [128]u8 = undefined;
        const expected_path = std.fmt.bufPrint(&path_buf, "{s}/{s}.json", .{ child_manifests_dir_path, child.id }) catch return error.BadManifest;
        if (!std.mem.eql(u8, child.manifest, expected_path)) return error.BadManifest;
        const existing = ids.getOrPut(child.id) catch return error.OutOfMemory;
        if (existing.found_existing) return error.BadManifest;
        if (previous) |prev| {
            if (std.mem.order(u8, prev, child.id) != .lt) return error.BadManifest;
        }
        previous = child.id;
    }
}

fn saveRootfsIndex(allocator: std.mem.Allocator, dir: []const u8, index: RootfsIndex) Error!void {
    try validateRootfsIndex(allocator, index);
    const json = std.json.Stringify.valueAlloc(allocator, index, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
    defer allocator.free(json);
    const path = try pathZ(allocator, "{s}/{s}", .{ dir, rootfs_index_path });
    try writeFileAll(path, json);
}

fn loadRootfsIndex(allocator: std.mem.Allocator, dir: []const u8) Error!std.json.Parsed(RootfsIndex) {
    const path = try pathZ(allocator, "{s}/{s}", .{ dir, rootfs_index_path });
    const bytes = try readFileAll(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(bytes);
    const parsed = std.json.parseFromSlice(RootfsIndex, allocator, bytes, .{
        .allocate = .alloc_always,
    }) catch return error.BadManifest;
    errdefer parsed.deinit();
    try validateRootfsIndex(allocator, parsed.value);
    return parsed;
}

fn validateRootfsIndex(allocator: std.mem.Allocator, index: RootfsIndex) Error!void {
    if (index.version != rootfs_index_version) return error.BadManifest;
    if (index.artifacts.len == 0 and index.storages.len == 0) return error.BadManifest;
    var digests = std.StringHashMap(void).init(allocator);
    defer digests.deinit();
    var previous: ?[]const u8 = null;
    for (index.artifacts) |entry| {
        try validateRootfsArtifactEntry(allocator, entry);
        const existing = digests.getOrPut(entry.digest) catch return error.OutOfMemory;
        if (existing.found_existing) return error.BadManifest;
        if (previous) |prev| {
            if (std.mem.order(u8, prev, entry.digest) != .lt) return error.BadManifest;
        }
        previous = entry.digest;
    }

    var storage_digests = std.StringHashMap(void).init(allocator);
    defer storage_digests.deinit();
    var previous_storage: ?[]const u8 = null;
    for (index.storages) |entry| {
        try validateRootfsStorageEntry(allocator, entry);
        const existing = storage_digests.getOrPut(entry.index_digest) catch return error.OutOfMemory;
        if (existing.found_existing) return error.BadManifest;
        if (previous_storage) |prev| {
            if (std.mem.order(u8, prev, entry.index_digest) != .lt) return error.BadManifest;
        }
        previous_storage = entry.index_digest;
    }
}

fn validateRootfsArtifactEntry(allocator: std.mem.Allocator, entry: RootfsArtifactEntry) Error!void {
    _ = allocator;
    try spore.validateRootfsDigest(entry.digest);
    if (entry.size == 0 or entry.size > std.math.maxInt(usize)) return error.BadManifest;
    if (!std.mem.eql(u8, entry.format, spore.rootfs_artifact_format_ext4)) return error.BadManifest;
    if (std.mem.eql(u8, entry.policy, rootfs_policy_exact_bytes)) {
        const hex = entry.digest[spore.rootfs_digest_prefix.len..];
        var path_buf: [128]u8 = undefined;
        const expected_path = std.fmt.bufPrint(&path_buf, "{s}/{s}.ext4", .{ rootfs_blake3_dir_path, hex }) catch return error.BadManifest;
        if (!std.mem.eql(u8, entry.path orelse return error.BadManifest, expected_path)) return error.BadManifest;
    } else if (std.mem.eql(u8, entry.policy, rootfs_policy_metadata_only)) {
        if (entry.path != null) return error.BadManifest;
    } else {
        return error.BadManifest;
    }
}

fn validateRootfsStorageEntry(allocator: std.mem.Allocator, entry: RootfsStorageEntry) Error!void {
    try spore.validateRootfsDeviceShape(entry.device);
    const storage = rootfsStorageEntryDescriptor(entry);
    try spore.validateRootfsStorageDescriptor(storage);
    const expected_path = try rootfsStorageIndexRelPath(allocator, entry.index_digest);
    defer allocator.free(expected_path);
    if (!std.mem.eql(u8, entry.index_path, expected_path)) return error.BadManifest;
    if (entry.index_bytes == 0 or entry.index_bytes > @as(u64, @intCast(disk_index.max_index_bytes))) return error.BadManifest;
    const chunk_count = try spore.diskClusterCount(entry.logical_size, entry.chunk_size);
    if (@as(u64, @intCast(entry.object_count)) > chunk_count) return error.BadManifest;
    if (entry.object_bytes > entry.logical_size) return error.BadManifest;
}

fn hasBundleIndex(allocator: std.mem.Allocator, bundle_dir: []const u8) Error!bool {
    const path = try pathZ(allocator, "{s}/{s}", .{ bundle_dir, bundle_index_path });
    return std.c.access(path, 0) == 0;
}

fn validateChunk(entry: IndexChunk) Error!void {
    _ = chunklib.ChunkId.fromHex(entry.id) catch return error.BadManifest;
    if (!std.mem.eql(u8, entry.pack, pack_path)) return error.BadManifest;
    if (entry.size == 0 or entry.size > spore.chunk_size) return error.BadManifest;
    if (entry.sha256.len != Sha256.digest_length * 2) return error.BadManifest;
    var digest: [Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, entry.sha256) catch return error.BadManifest;
}

fn chunkPackPayloadBytes(index: Index) Error!u64 {
    var max_end: u64 = 0;
    for (index.chunks) |entry| {
        const end = std.math.add(u64, entry.offset, entry.size) catch return error.BadManifest;
        max_end = @max(max_end, end);
    }
    return max_end;
}

fn indexById(allocator: std.mem.Allocator, index: Index) Error!std.StringHashMap(IndexChunk) {
    var by_id = std.StringHashMap(IndexChunk).init(allocator);
    errdefer by_id.deinit();
    for (index.chunks) |entry| {
        by_id.put(entry.id, entry) catch return error.OutOfMemory;
    }
    return by_id;
}

fn materializeChunks(
    allocator: std.mem.Allocator,
    io: Io,
    out_dir: []const u8,
    memory: spore.MemoryManifest,
    ram_size: u64,
    plan: spore.MemoryPlan,
    by_id: *const std.StringHashMap(IndexChunk),
    source: VerifiedContentSource,
    chunk_cache_dir: ?[]const u8,
) Error!MaterializeResult {
    try ensureNewDir(try pathZ(allocator, "{s}", .{out_dir}));
    try ensureNewDir(try pathZ(allocator, "{s}/chunks", .{out_dir}));

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var result = MaterializeResult{ .chunk_count = plan.chunk_count };

    var i: usize = 0;
    while (i < plan.chunk_count) : (i += 1) {
        const ref = memory.chunks[i] orelse continue;
        if (seen.contains(ref)) continue;
        seen.put(ref, {}) catch return error.OutOfMemory;
        const entry = by_id.get(ref) orelse return error.BadManifest;
        const range = chunkRange(plan, @intCast(ram_size), i) catch return error.BadManifest;
        const expected_size = range.end - range.start;
        const chunk_path = try pathZ(allocator, "{s}/chunks/{s}", .{ out_dir, ref });
        if (chunk_cache_dir) |cache_dir| {
            try materializeChunkViaCache(
                allocator,
                io,
                cache_dir,
                chunk_path,
                source,
                entry,
                ref,
                expected_size,
                &result,
            );
        } else {
            const data = try source.readChunk(allocator, entry, ref, expected_size);
            defer allocator.free(data);
            try writeFileAll(chunk_path, data);
            result.materialized_chunk_count += 1;
            result.payload_bytes += @intCast(data.len);
            result.copied_chunk_count += 1;
        }
    }

    return result;
}

fn materializeChunkViaCache(
    allocator: std.mem.Allocator,
    io: Io,
    cache_dir: []const u8,
    out_chunk_path: []const u8,
    source: VerifiedContentSource,
    entry: IndexChunk,
    expected_id: []const u8,
    expected_size: usize,
    result: *MaterializeResult,
) Error!void {
    const cache_path = try chunkCachePath(allocator, cache_dir, expected_id);
    const cache_parent = std.fs.path.dirname(cache_path) orelse return error.IoFailed;
    try ensureDirPath(io, cache_parent);

    if (try pathExistsNoSymlink(io, cache_path)) {
        try verifyChunkPath(io, allocator, cache_path, expected_id, expected_size);
        result.cache_hit_count += 1;
        result.cache_reused_bytes += @intCast(expected_size);
    } else {
        const data = try source.readChunk(allocator, entry, expected_id, expected_size);
        defer allocator.free(data);
        try installChunkCachePath(allocator, io, cache_path, data, expected_id, expected_size);
        result.cache_miss_count += 1;
        result.payload_bytes += @intCast(data.len);
    }

    const linked = try linkOrCopyVerifiedChunk(allocator, io, cache_path, out_chunk_path, expected_id, expected_size);
    if (linked) {
        result.linked_chunk_count += 1;
    } else {
        result.copied_chunk_count += 1;
    }
    result.materialized_chunk_count += 1;
}

fn installChunkCachePath(
    allocator: std.mem.Allocator,
    io: Io,
    cache_path: []const u8,
    data: []const u8,
    expected_id: []const u8,
    expected_size: usize,
) Error!void {
    if (data.len != expected_size) return error.BadChunk;
    const id = chunklib.ChunkId.fromHex(expected_id) catch return error.BadManifest;
    if (!id.matches(data)) return error.BadChunk;

    var temp_nonce_bytes: [8]u8 = undefined;
    io.random(&temp_nonce_bytes);
    const temp_nonce = std.mem.readInt(u64, &temp_nonce_bytes, .little);
    const temp_path = std.fmt.allocPrintSentinel(allocator, "{s}.{x}.tmp", .{ cache_path, temp_nonce }, 0) catch return error.OutOfMemory;
    defer Io.Dir.cwd().deleteFile(io, temp_path) catch {};
    try writeFileExclusive(temp_path, data, 0o444);
    try verifyChunkPath(io, allocator, temp_path, expected_id, expected_size);
    try renamePath(io, temp_path, cache_path);
    try verifyChunkPath(io, allocator, cache_path, expected_id, expected_size);
}

fn linkOrCopyVerifiedChunk(
    allocator: std.mem.Allocator,
    io: Io,
    source_path: []const u8,
    dest_path: []const u8,
    expected_id: []const u8,
    expected_size: usize,
) Error!bool {
    const source_z = try pathZ(allocator, "{s}", .{source_path});
    const dest_z = try pathZ(allocator, "{s}", .{dest_path});
    if (std.c.link(source_z, dest_z) == 0) {
        try verifyChunkPath(io, allocator, dest_path, expected_id, expected_size);
        return true;
    }

    const data = try readVerifiedChunkPath(io, allocator, source_path, expected_id, expected_size);
    defer allocator.free(data);
    try writeFileAll(dest_z, data);
    try verifyChunkPath(io, allocator, dest_path, expected_id, expected_size);
    return false;
}

fn verifyChunkPath(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    expected_id: []const u8,
    expected_size: usize,
) Error!void {
    const data = try readVerifiedChunkPath(io, allocator, path, expected_id, expected_size);
    allocator.free(data);
}

fn readVerifiedChunkPath(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    expected_id: []const u8,
    expected_size: usize,
) Error![]u8 {
    if (!try regularFileNoSymlink(io, path)) return error.BadChunk;
    const path_z = try pathZ(allocator, "{s}", .{path});
    const data = try readFileAll(allocator, path_z, expected_size);
    errdefer allocator.free(data);
    if (data.len != expected_size) return error.BadChunk;
    const id = chunklib.ChunkId.fromHex(expected_id) catch return error.BadManifest;
    if (!id.matches(data)) return error.BadChunk;
    return data;
}

fn chunkCachePath(allocator: std.mem.Allocator, cache_dir: []const u8, chunk_id: []const u8) Error![]const u8 {
    _ = chunklib.ChunkId.fromHex(chunk_id) catch return error.BadManifest;
    return std.fs.path.join(allocator, &.{ cache_dir, "chunks", "blake3", chunk_id }) catch return error.OutOfMemory;
}

fn packManifestChunks(
    allocator: std.mem.Allocator,
    memory: spore.MemoryManifest,
    ram_size: u64,
    source_dir: []const u8,
    pack_fd: std.c.fd_t,
    seen: *std.StringHashMap(void),
    entries: *std.array_list.Managed(IndexChunk),
    payload_bytes: *u64,
) Error!spore.MemoryPlan {
    const plan = try spore.validateMemoryForRam(memory, @intCast(ram_size));
    var i: usize = 0;
    while (i < plan.chunk_count) : (i += 1) {
        const ref = memory.chunks[i] orelse continue;
        if (seen.contains(ref)) continue;
        const ref_copy = allocator.dupe(u8, ref) catch return error.OutOfMemory;
        seen.put(ref_copy, {}) catch return error.OutOfMemory;

        const range = chunkRange(plan, @intCast(ram_size), i) catch return error.BadManifest;
        const expected_size = range.end - range.start;
        const chunk_path = try pathZ(allocator, "{s}/chunks/{s}", .{ source_dir, ref });
        const data = try readFileAll(allocator, chunk_path, expected_size);
        defer allocator.free(data);
        if (data.len != expected_size) return error.BadChunk;
        const id = chunklib.ChunkId.fromHex(ref) catch return error.BadManifest;
        if (!id.matches(data)) return error.BadChunk;
        if (payload_bytes.* > std.math.maxInt(usize)) return error.BadChunk;
        try pwriteFileAll(pack_fd, @intCast(payload_bytes.*), data);
        try entries.append(.{
            .id = ref_copy,
            .pack = pack_path,
            .offset = payload_bytes.*,
            .size = @intCast(data.len),
            .sha256 = try sha256HexAlloc(allocator, data),
        });
        payload_bytes.* += @intCast(data.len);
    }
    return plan;
}

fn packRootfsArtifact(allocator: std.mem.Allocator, options: PackOptions, rootfs_opt: ?spore.Rootfs) Error!u64 {
    const rootfs = rootfs_opt orelse return 0;
    const cache_root = options.rootfs_cache_dir orelse return error.IoFailed;
    try ensureNewDir(try pathZ(allocator, "{s}/{s}", .{ options.out_dir, rootfs_dir_path }));
    try ensureNewDir(try pathZ(allocator, "{s}/{s}", .{ options.out_dir, rootfs_blake3_dir_path }));
    const source_path = rootfs_cache.digestPath(allocator, cache_root, rootfs.artifact.digest) catch |err| return rootfsError(err);
    const rel_path = try rootfsArtifactRelPath(allocator, rootfs.artifact);
    const dest_path = try pathZ(allocator, "{s}/{s}", .{ options.out_dir, rel_path });
    rootfs_cache.copyTrustedPath(options.io, allocator, source_path, dest_path, rootfs.artifact) catch |err| return rootfsError(err);
    return rootfs.artifact.size;
}

fn packRootfsIndexed(
    allocator: std.mem.Allocator,
    options: PackOptions,
    rootfs_opt: ?spore.Rootfs,
    seen_artifacts: *std.StringHashMap(void),
    entries: *std.array_list.Managed(RootfsArtifactEntry),
    seen_storages: *std.StringHashMap(void),
    storage_entries: *std.array_list.Managed(RootfsStorageEntry),
    seen_objects: *std.StringHashMap(void),
) Error!u64 {
    const rootfs = rootfs_opt orelse return 0;
    if (rootfs.storage != null) {
        return packRootfsStorageIndexed(
            allocator,
            options,
            rootfs,
            seen_storages,
            storage_entries,
            seen_objects,
        );
    }
    const cache_root = options.rootfs_cache_dir orelse return error.IoFailed;
    if (seen_artifacts.contains(rootfs.artifact.digest)) return 0;
    const digest_copy = allocator.dupe(u8, rootfs.artifact.digest) catch return error.OutOfMemory;
    seen_artifacts.put(digest_copy, {}) catch return error.OutOfMemory;

    if (options.rootfs_policy == .metadata_only) {
        const fd = rootfs_cache.openTrustedFromCache(options.io, allocator, cache_root, .{ .device = rootfs.device, .artifact = rootfs.artifact }) catch |err| return rootfsError(err);
        _ = std.c.close(fd);
        try entries.append(.{
            .digest = digest_copy,
            .size = rootfs.artifact.size,
            .format = spore.rootfs_artifact_format_ext4,
            .policy = rootfs_policy_metadata_only,
            .path = null,
        });
        return 0;
    }

    const source_path = rootfs_cache.digestPath(allocator, cache_root, rootfs.artifact.digest) catch |err| return rootfsError(err);
    const rel_path = try rootfsArtifactRelPath(allocator, rootfs.artifact);
    const dest_path = try pathZ(allocator, "{s}/{s}", .{ options.out_dir, rel_path });
    rootfs_cache.copyTrustedPath(options.io, allocator, source_path, dest_path, rootfs.artifact) catch |err| return rootfsError(err);
    try entries.append(.{
        .digest = digest_copy,
        .size = rootfs.artifact.size,
        .format = spore.rootfs_artifact_format_ext4,
        .policy = rootfs_policy_exact_bytes,
        .path = rel_path,
    });
    return rootfs.artifact.size;
}

fn packRootfsStorageIndexed(
    allocator: std.mem.Allocator,
    options: PackOptions,
    rootfs: spore.Rootfs,
    seen_storages: *std.StringHashMap(void),
    storage_entries: *std.array_list.Managed(RootfsStorageEntry),
    seen_objects: *std.StringHashMap(void),
) Error!u64 {
    if (options.rootfs_policy == .metadata_only) return error.UnsupportedMetadataOnlyRootfsStorage;
    const cache_root = options.rootfs_cache_dir orelse return error.IoFailed;
    const storage = rootfs.storage orelse return error.BadManifest;
    try validateRootfsStorageForRootfs(storage, rootfs);

    if (seen_storages.contains(storage.index_digest)) {
        const existing = findRootfsStorageEntry(storage_entries.items, storage.index_digest) orelse return error.BadManifest;
        if (!rootfsStorageEntryMatches(existing, storage)) return error.BadManifest;
        return 0;
    }

    try ensureRootfsStorageMatchesArtifact(allocator, options, cache_root, rootfs, storage);

    const source_index_path = rootfs_cas.manifestIndexPath(allocator, cache_root, storage.index_digest) catch |err| return rootfsError(err);
    const index_bytes = rootfs_cas.readVerifiedStorageIndexPath(allocator, source_index_path, storage) catch |err| return rootfsError(err);
    defer allocator.free(index_bytes);
    const parsed_index = disk_index.parseDiskIndex(allocator, index_bytes, storage) catch |err| return rootfsError(err);
    defer parsed_index.deinit();

    const index_rel_path = try rootfsStorageIndexRelPath(allocator, storage.index_digest);
    const dest_index_path = try pathZ(allocator, "{s}/{s}", .{ options.out_dir, index_rel_path });
    if (std.fs.path.dirname(dest_index_path)) |parent| try ensureDirPath(options.io, parent);
    try writeFileAll(dest_index_path, index_bytes);

    var payload_bytes: u64 = @intCast(index_bytes.len);
    var object_bytes: u64 = 0;
    var object_count: usize = 0;
    for (parsed_index.value.chunks) |chunk_entry| {
        const expected_size = rootfs_cas.storageChunkLen(storage, chunk_entry.logical_chunk) catch |err| return rootfsError(err);
        const source_object_path = rootfs_cas.manifestObjectPath(allocator, cache_root, chunk_entry.digest) catch |err| return rootfsError(err);
        const object_data = rootfs_cas.readVerifiedChunkPath(allocator, source_object_path, chunk_entry.digest, expected_size) catch |err| return rootfsError(err);
        defer allocator.free(object_data);
        object_count += 1;
        object_bytes += @intCast(object_data.len);
        if (seen_objects.contains(chunk_entry.digest)) continue;
        const digest_copy = allocator.dupe(u8, chunk_entry.digest) catch return error.OutOfMemory;
        seen_objects.put(digest_copy, {}) catch return error.OutOfMemory;

        const object_rel_path = try rootfsStorageObjectRelPath(allocator, chunk_entry.digest);
        const dest_object_path = try pathZ(allocator, "{s}/{s}", .{ options.out_dir, object_rel_path });
        if (std.fs.path.dirname(dest_object_path)) |parent| try ensureDirPath(options.io, parent);
        try writeFileAll(dest_object_path, object_data);
        payload_bytes += @intCast(object_data.len);
    }

    const storage_copy = try spore.cloneRootfsStorage(allocator, storage);
    seen_storages.put(storage_copy.index_digest, {}) catch return error.OutOfMemory;
    try storage_entries.append(.{
        .kind = storage_copy.kind,
        .device = storage_copy.device,
        .logical_size = storage_copy.logical_size,
        .chunk_size = storage_copy.chunk_size,
        .hash_algorithm = storage_copy.hash_algorithm,
        .index_digest = storage_copy.index_digest,
        .base_identity = storage_copy.base_identity,
        .object_namespace = storage_copy.object_namespace,
        .index_path = index_rel_path,
        .index_bytes = @intCast(index_bytes.len),
        .object_count = object_count,
        .object_bytes = object_bytes,
    });
    return payload_bytes;
}

fn ensureRootfsStorageMatchesArtifact(
    allocator: std.mem.Allocator,
    options: PackOptions,
    cache_root: []const u8,
    rootfs: spore.Rootfs,
    storage: spore.RootfsStorage,
) Error!void {
    // storageComplete proves only that the descriptor-named index and chunk
    // objects are locally present and well-formed. It does not prove that the
    // descriptor was derived from this rootfs artifact digest, so regenerate the
    // index from the flat artifact before emitting chunked rootfs storage.
    const regenerated = rootfs_cas.preload(
        options.io,
        allocator,
        cache_root,
        rootfs.artifact.digest,
        storage.chunk_size,
    ) catch |err| switch (err) {
        error.RootFSDigestCacheMiss => blk: {
            rootfs_cas.materializeFlatFromChunks(options.io, allocator, cache_root, rootfs) catch |materialize_err| return rootfsError(materialize_err);
            break :blk rootfs_cas.preload(
                options.io,
                allocator,
                cache_root,
                rootfs.artifact.digest,
                storage.chunk_size,
            ) catch |preload_err| return rootfsError(preload_err);
        },
        else => |preload_err| return rootfsError(preload_err),
    };
    defer allocator.free(regenerated.index_path);
    defer allocator.free(regenerated.index_digest);

    if (!std.mem.eql(u8, regenerated.index_digest, storage.index_digest)) return error.BadManifest;
}

fn unpackRootfsArtifact(allocator: std.mem.Allocator, options: UnpackOptions, rootfs_opt: ?spore.Rootfs) Error!RootfsMaterializeResult {
    const rootfs = rootfs_opt orelse return .{};
    if (rootfs.storage != null) return error.BadManifest;
    const cache_root = options.rootfs_cache_dir orelse return error.IoFailed;
    const rel_path = try rootfsArtifactRelPath(allocator, rootfs.artifact);
    const source_path = try pathZ(allocator, "{s}/{s}", .{ options.bundle_dir, rel_path });
    const installed = rootfs_cache.installExpectedPathWithResult(options.io, allocator, cache_root, source_path, rootfs.artifact, .{
        .source_must_not_be_symlink = true,
        .allow_hardlink = false,
    }) catch |err| return rootfsError(err);
    return .{
        .artifact_count = 1,
        .payload_bytes = rootfs.artifact.size,
        .cache_hit_count = if (installed.cache_hit) 1 else 0,
        .cache_miss_count = if (installed.cache_hit) 0 else 1,
        .bytes_fetched = installed.bytes_fetched,
        .bytes_reused = if (installed.cache_hit) rootfs.artifact.size else 0,
    };
}

fn unpackRootfsArtifactIndexed(
    allocator: std.mem.Allocator,
    options: UnpackOptions,
    bundle_index: BundleIndex,
    rootfs_opt: ?spore.Rootfs,
) Error!RootfsMaterializeResult {
    const rootfs = rootfs_opt orelse return .{};
    const cache_root = options.rootfs_cache_dir orelse return error.IoFailed;
    if (bundle_index.rootfs_index == null) return error.BadManifest;
    const parsed_rootfs_index = try loadRootfsIndex(allocator, options.bundle_dir);
    defer parsed_rootfs_index.deinit();
    if (rootfs.storage) |storage| {
        return unpackRootfsStorageIndexed(
            allocator,
            options,
            rootfs,
            storage,
            parsed_rootfs_index.value,
            cache_root,
        );
    }
    const entry = findRootfsEntry(parsed_rootfs_index.value, rootfs.artifact.digest) orelse return error.BadManifest;
    if (entry.size != rootfs.artifact.size) return error.BadManifest;
    if (!std.mem.eql(u8, entry.format, rootfs.artifact.format)) return error.BadManifest;
    if (std.mem.eql(u8, entry.policy, rootfs_policy_metadata_only)) {
        if (!options.allow_metadata_only_rootfs) return error.BadManifest;
        const fd = rootfs_cache.openTrustedFromCache(options.io, allocator, cache_root, rootfs) catch |err| return rootfsError(err);
        _ = std.c.close(fd);
        return .{
            .artifact_count = 1,
            .payload_bytes = 0,
            .cache_hit_count = 1,
            .cache_miss_count = 0,
            .bytes_fetched = 0,
            .bytes_reused = rootfs.artifact.size,
        };
    }
    if (!std.mem.eql(u8, entry.policy, rootfs_policy_exact_bytes)) return error.BadManifest;
    const rel_path = entry.path orelse return error.BadManifest;
    const source_path = try pathZ(allocator, "{s}/{s}", .{ options.bundle_dir, rel_path });
    const installed = rootfs_cache.installExpectedPathWithResult(options.io, allocator, cache_root, source_path, rootfs.artifact, .{
        .source_must_not_be_symlink = true,
        .allow_hardlink = false,
    }) catch |err| return rootfsError(err);
    return .{
        .artifact_count = 1,
        .payload_bytes = rootfs.artifact.size,
        .cache_hit_count = if (installed.cache_hit) 1 else 0,
        .cache_miss_count = if (installed.cache_hit) 0 else 1,
        .bytes_fetched = installed.bytes_fetched,
        .bytes_reused = if (installed.cache_hit) rootfs.artifact.size else 0,
    };
}

fn unpackRootfsStorageIndexed(
    allocator: std.mem.Allocator,
    options: UnpackOptions,
    rootfs: spore.Rootfs,
    storage: spore.RootfsStorage,
    index: RootfsIndex,
    cache_root: []const u8,
) Error!RootfsMaterializeResult {
    try validateRootfsStorageForRootfs(storage, rootfs);
    const entry = findRootfsStorageEntry(index.storages, storage.index_digest) orelse return error.BadManifest;
    if (!rootfsStorageEntryMatches(entry, storage)) return error.BadManifest;

    const source_index_path = try pathZ(allocator, "{s}/{s}", .{ options.bundle_dir, entry.index_path });
    const index_bytes = rootfs_cas.readVerifiedStorageIndexPath(allocator, source_index_path, storage) catch |err| return rootfsError(err);
    defer allocator.free(index_bytes);
    const parsed_index = disk_index.parseDiskIndex(allocator, index_bytes, storage) catch |err| return rootfsError(err);
    defer parsed_index.deinit();

    const cache_index_path = rootfs_cas.manifestIndexPath(allocator, cache_root, storage.index_digest) catch |err| return rootfsError(err);
    var result = RootfsMaterializeResult{
        .artifact_count = 1,
        .payload_bytes = @intCast(index_bytes.len),
    };
    const installed_index = rootfs_cas.installStorageIndexPath(allocator, options.io, cache_index_path, index_bytes, storage) catch |err| return rootfsError(err);
    if (installed_index.cache_hit) {
        result.cache_hit_count += 1;
        result.bytes_reused += @intCast(index_bytes.len);
    } else {
        result.cache_miss_count += 1;
        result.bytes_fetched += installed_index.bytes_fetched;
    }

    var object_count: usize = 0;
    var object_bytes: u64 = 0;
    for (parsed_index.value.chunks) |chunk_entry| {
        const expected_size = rootfs_cas.storageChunkLen(storage, chunk_entry.logical_chunk) catch |err| return rootfsError(err);
        const source_object_rel_path = try rootfsStorageObjectRelPath(allocator, chunk_entry.digest);
        const source_object_path = try pathZ(allocator, "{s}/{s}", .{ options.bundle_dir, source_object_rel_path });
        const object_data = rootfs_cas.readVerifiedChunkPath(allocator, source_object_path, chunk_entry.digest, expected_size) catch |err| return rootfsError(err);
        defer allocator.free(object_data);
        const cache_object_path = rootfs_cas.manifestObjectPath(allocator, cache_root, chunk_entry.digest) catch |err| return rootfsError(err);
        const installed_object = rootfs_cas.installChunkPath(allocator, options.io, cache_object_path, object_data, chunk_entry.digest, expected_size) catch |err| return rootfsError(err);
        if (installed_object.cache_hit) {
            result.cache_hit_count += 1;
            result.bytes_reused += @intCast(object_data.len);
        } else {
            result.cache_miss_count += 1;
            result.bytes_fetched += installed_object.bytes_fetched;
        }
        object_count += 1;
        object_bytes += @intCast(object_data.len);
        result.payload_bytes += @intCast(object_data.len);
    }
    if (entry.object_count != object_count or
        entry.object_bytes != object_bytes or
        entry.index_bytes != @as(u64, @intCast(index_bytes.len))) return error.BadManifest;
    // The flat digest-addressed artifact is the only runtime base source;
    // assemble it eagerly from the just-installed verified chunks so the
    // first resume of a pulled child does not pay the assembly cost.
    rootfs_cas.materializeFlatFromChunks(options.io, allocator, cache_root, rootfs) catch |err| return rootfsError(err);
    return result;
}

fn findRootfsEntry(index: RootfsIndex, digest: []const u8) ?RootfsArtifactEntry {
    for (index.artifacts) |entry| {
        if (std.mem.eql(u8, entry.digest, digest)) return entry;
    }
    return null;
}

fn findRootfsStorageEntry(entries: []const RootfsStorageEntry, index_digest: []const u8) ?RootfsStorageEntry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.index_digest, index_digest)) return entry;
    }
    return null;
}

fn rootfsArtifactRelPath(allocator: std.mem.Allocator, artifact: spore.RootfsArtifactRef) Error![]const u8 {
    try spore.validateRootfsDigest(artifact.digest);
    if (!std.mem.eql(u8, artifact.format, spore.rootfs_artifact_format_ext4)) return error.BadManifest;
    const hex = artifact.digest[spore.rootfs_digest_prefix.len..];
    return std.fmt.allocPrint(allocator, "{s}/{s}.ext4", .{ rootfs_blake3_dir_path, hex }) catch return error.OutOfMemory;
}

fn rootfsStorageEntryDescriptor(entry: RootfsStorageEntry) spore.RootfsStorage {
    return .{
        .kind = entry.kind,
        .device = entry.device,
        .logical_size = entry.logical_size,
        .chunk_size = entry.chunk_size,
        .hash_algorithm = entry.hash_algorithm,
        .index_digest = entry.index_digest,
        .base_identity = entry.base_identity,
        .object_namespace = entry.object_namespace,
    };
}

fn rootfsStorageEntryMatches(entry: RootfsStorageEntry, storage: spore.RootfsStorage) bool {
    return spore.rootfsStorageEql(rootfsStorageEntryDescriptor(entry), storage);
}

fn validateRootfsStorageForRootfs(storage: spore.RootfsStorage, rootfs: spore.Rootfs) Error!void {
    try spore.validateRootfsStorageDescriptor(storage);
    try spore.validateRootfsDeviceShape(storage.device);
    if (!spore.rootfsDeviceEql(storage.device, rootfs.device)) return error.BadManifest;
    if (storage.logical_size != rootfs.artifact.size) return error.BadManifest;
}

fn rootfsStorageIndexRelPath(allocator: std.mem.Allocator, index_digest: []const u8) Error![]const u8 {
    const hex = try spore.diskDigestHex(index_digest);
    return std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ rootfs_blake3_indexes_dir_path, hex }) catch return error.OutOfMemory;
}

fn rootfsStorageObjectRelPath(allocator: std.mem.Allocator, object_digest: []const u8) Error![]const u8 {
    const hex = try spore.diskDigestHex(object_digest);
    return std.fmt.allocPrint(allocator, "{s}/{s}.chunk", .{ rootfs_blake3_objects_dir_path, hex }) catch return error.OutOfMemory;
}

fn loadDiskIndexForEntry(
    allocator: std.mem.Allocator,
    bundle_dir: []const u8,
    entry: RootfsStorageEntry,
    storage: spore.RootfsStorage,
) Error!std.json.Parsed(disk_index.DiskIndex) {
    const expected_path = try rootfsStorageIndexRelPath(allocator, entry.index_digest);
    defer allocator.free(expected_path);
    if (!std.mem.eql(u8, entry.index_path, expected_path)) return error.BadManifest;
    const path = try pathZ(allocator, "{s}/{s}", .{ bundle_dir, entry.index_path });
    const bytes = try readFileAllNoSymlink(allocator, path, disk_index.max_index_bytes);
    defer allocator.free(bytes);
    if (entry.index_bytes != @as(u64, @intCast(bytes.len))) return error.BadManifest;
    const parsed = disk_index.parseDiskIndex(allocator, bytes, storage) catch |err| return rootfsError(err);
    errdefer parsed.deinit();
    try validateRootfsStoragePayloadStats(entry, storage, parsed.value);
    return parsed;
}

fn validateRootfsStoragePayloadStats(
    entry: RootfsStorageEntry,
    storage: spore.RootfsStorage,
    index: disk_index.DiskIndex,
) Error!void {
    var object_count: usize = 0;
    var object_bytes: u64 = 0;
    for (index.chunks) |chunk_entry| {
        const expected_size = rootfs_cas.storageChunkLen(storage, chunk_entry.logical_chunk) catch |err| return rootfsError(err);
        object_count += 1;
        object_bytes = std.math.add(u64, object_bytes, @intCast(expected_size)) catch return error.BadManifest;
    }
    if (entry.object_count != object_count or entry.object_bytes != object_bytes) return error.BadManifest;
}

fn packDiskLayersForManifest(
    allocator: std.mem.Allocator,
    source_dir: []const u8,
    bundle_dir: []const u8,
    disk_opt: ?spore.Disk,
) Error!void {
    const disk = disk_opt orelse return;
    disk_layer.copyLayerChain(allocator, source_dir, bundle_dir, disk) catch |err| return diskLayerError(err);
}

fn unpackDiskLayersForManifest(
    allocator: std.mem.Allocator,
    bundle_dir: []const u8,
    out_dir: []const u8,
    disk_opt: ?spore.Disk,
) Error!void {
    const disk = disk_opt orelse return;
    disk_layer.copyLayerChain(allocator, bundle_dir, out_dir, disk) catch |err| return diskLayerError(err);
}

fn diskLayerRelPath(allocator: std.mem.Allocator, layer_ref: []const u8) Error![]const u8 {
    const hex = try spore.diskDigestHex(layer_ref);
    return std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ disk_layers_blake3_dir_path, hex }) catch return error.OutOfMemory;
}

fn diskObjectRelPath(allocator: std.mem.Allocator, digest: []const u8) Error![]const u8 {
    const hex = try spore.diskDigestHex(digest);
    return std.fmt.allocPrint(allocator, "{s}/{s}.cluster", .{ disk_objects_blake3_dir_path, hex }) catch return error.OutOfMemory;
}

fn updateHashWithDiskFilesForManifestPath(
    allocator: std.mem.Allocator,
    h: *Sha256,
    bundle_dir: []const u8,
    manifest_rel: []const u8,
    seen: *std.StringHashMap(void),
) Error!void {
    var parsed_manifest = try LoadedManifest.loadPath(
        allocator,
        try pathZ(allocator, "{s}/{s}", .{ bundle_dir, manifest_rel }),
    );
    defer parsed_manifest.deinit();
    try updateHashWithDiskFilesForManifest(allocator, h, bundle_dir, parsed_manifest.disk(), seen);
}

fn updateHashWithDiskFilesForManifest(
    allocator: std.mem.Allocator,
    h: *Sha256,
    bundle_dir: []const u8,
    disk_opt: ?spore.Disk,
    seen: *std.StringHashMap(void),
) Error!void {
    const disk = disk_opt orelse return;
    for (disk.layers) |layer_ref| {
        const layer_rel = try diskLayerRelPath(allocator, layer_ref);
        if (try markBundleFileSeen(seen, layer_rel)) {
            try updateHashWithFile(allocator, h, bundle_dir, layer_rel);
        }

        const parsed_layer = disk_layer.loadLayer(allocator, bundle_dir, layer_ref) catch |err| return diskLayerError(err);
        defer parsed_layer.deinit();
        if (parsed_layer.value.disk_size != disk.size) return error.BadManifest;
        for (parsed_layer.value.extents) |extent| {
            const object_rel = try diskObjectRelPath(allocator, extent.digest);
            if (try markBundleFileSeen(seen, object_rel)) {
                try updateHashWithFile(allocator, h, bundle_dir, object_rel);
            }
        }
    }
}

fn childManifestRelPath(allocator: std.mem.Allocator, child_id: []const u8) Error![]const u8 {
    try validateChildId(child_id);
    return std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ child_manifests_dir_path, child_id }) catch return error.OutOfMemory;
}

fn selectedManifestPath(allocator: std.mem.Allocator, index: BundleIndex, child_id: ?[]const u8) Error![]const u8 {
    const id = child_id orelse return index.parent_manifest;
    try validateChildId(id);
    for (index.children) |child| {
        if (std.mem.eql(u8, child.id, id)) return child.manifest;
    }
    _ = allocator;
    return error.BadManifest;
}

fn canonicalChildId(allocator: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    if (raw.len == 0 or raw.len > 6) return error.BadManifest;
    for (raw) |c| {
        if (!std.ascii.isDigit(c)) return error.BadManifest;
    }
    const value = std.fmt.parseInt(u32, raw, 10) catch return error.BadManifest;
    if (value > 999999) return error.BadManifest;
    return std.fmt.allocPrint(allocator, "{d:0>6}", .{value}) catch return error.OutOfMemory;
}

fn localFileUriPath(allocator: std.mem.Allocator, source: []const u8) Error![]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, source, prefix)) return error.BadManifest;
    var path = source[prefix.len..];
    if (std.mem.startsWith(u8, path, "localhost/")) {
        path = path["localhost".len..];
    }
    if (path.len == 0 or !Io.Dir.path.isAbsolute(path)) return error.BadManifest;
    if (std.mem.indexOfScalar(u8, path, '%') != null) return error.BadManifest;
    return std.fs.path.resolve(allocator, &.{path}) catch return error.IoFailed;
}

const S3Location = struct {
    bucket: []const u8,
    prefix: []const u8,

    fn objectKey(self: S3Location, allocator: std.mem.Allocator, rel_path: []const u8) Error![]const u8 {
        try validateBundleRelPath(rel_path);
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.prefix, rel_path }) catch return error.OutOfMemory;
    }

    fn objectUri(self: S3Location, allocator: std.mem.Allocator, rel_path: []const u8) Error![]const u8 {
        try validateBundleRelPath(rel_path);
        return std.fmt.allocPrint(allocator, "s3://{s}/{s}/{s}", .{ self.bucket, self.prefix, rel_path }) catch return error.OutOfMemory;
    }
};

const S3Source = struct {
    location: S3Location,
    expected_digest: []const u8,
};

const HttpLocation = struct {
    base_url: []const u8,

    fn objectUrl(self: HttpLocation, allocator: std.mem.Allocator, rel_path: []const u8) Error![]const u8 {
        try validateBundleRelPath(rel_path);
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.base_url, rel_path }) catch return error.OutOfMemory;
    }
};

const HttpSource = struct {
    location: HttpLocation,
    expected_digest: []const u8,
};

const RemoteBundleMaterialization = struct {
    bundle_dir: []const u8,
    origin_bytes_read: u64,
    cache_hit: bool,
};

fn parseS3Destination(allocator: std.mem.Allocator, uri: []const u8) Error!S3Location {
    if (std.mem.indexOf(u8, uri, "@sha256:") != null) return error.BadManifest;
    return parseS3Location(allocator, uri);
}

fn parseS3Source(allocator: std.mem.Allocator, uri: []const u8) Error!S3Source {
    const marker = "@sha256:";
    const marker_index = std.mem.lastIndexOf(u8, uri, marker) orelse return error.BadManifest;
    const location_uri = uri[0..marker_index];
    const digest = uri[marker_index + marker.len ..];
    try validateSha256DigestHex(digest);
    return .{
        .location = try parseS3Location(allocator, location_uri),
        .expected_digest = allocator.dupe(u8, digest) catch return error.OutOfMemory,
    };
}

fn parseHttpSource(allocator: std.mem.Allocator, uri: []const u8) Error!HttpSource {
    const marker = "@sha256:";
    const marker_index = std.mem.lastIndexOf(u8, uri, marker) orelse return error.BadManifest;
    const location_url = uri[0..marker_index];
    const digest = uri[marker_index + marker.len ..];
    try validateSha256DigestHex(digest);
    return .{
        .location = try parseHttpLocation(allocator, location_url),
        .expected_digest = allocator.dupe(u8, digest) catch return error.OutOfMemory,
    };
}

fn parseHttpLocation(allocator: std.mem.Allocator, raw_url: []const u8) Error!HttpLocation {
    if (std.mem.indexOfScalar(u8, raw_url, '@') != null) return error.BadManifest;
    if (std.mem.indexOfScalar(u8, raw_url, '%') != null) return error.BadManifest;
    const trimmed = std.mem.trimEnd(u8, raw_url, "/");
    if (trimmed.len == 0) return error.BadManifest;
    const uri = std.Uri.parse(trimmed) catch return error.BadManifest;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.BadManifest;
    if (uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.BadManifest;
    const path = uriComponentText(uri.path);
    if (path.len > 0) {
        if (path[0] != '/') return error.BadManifest;
        if (path.len > 1) try validateRelativeSegments(path[1..]);
    }
    return .{ .base_url = allocator.dupe(u8, trimmed) catch return error.OutOfMemory };
}

fn parseS3Location(allocator: std.mem.Allocator, uri: []const u8) Error!S3Location {
    const prefix = "s3://";
    if (!std.mem.startsWith(u8, uri, prefix)) return error.BadManifest;
    const rest = uri[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.BadManifest;
    const bucket = rest[0..slash];
    try validateS3Bucket(bucket);
    const raw_key = rest[slash + 1 ..];
    var key_end = raw_key.len;
    while (key_end > 0 and raw_key[key_end - 1] == '/') key_end -= 1;
    const key = raw_key[0..key_end];
    try validateS3KeyPrefix(key);
    return .{
        .bucket = allocator.dupe(u8, bucket) catch return error.OutOfMemory,
        .prefix = allocator.dupe(u8, key) catch return error.OutOfMemory,
    };
}

fn uriComponentText(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw => |s| s,
        .percent_encoded => |s| s,
    };
}

fn validateS3Bucket(bucket: []const u8) Error!void {
    if (bucket.len == 0 or bucket.len > 63) return error.BadManifest;
    for (bucket) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '.' or c == '-') continue;
        return error.BadManifest;
    }
}

fn validateS3KeyPrefix(key: []const u8) Error!void {
    if (key.len == 0) return error.BadManifest;
    if (std.mem.indexOfScalar(u8, key, '@') != null) return error.BadManifest;
    try validateRelativeSegments(key);
}

fn validateBundleRelPath(rel_path: []const u8) Error!void {
    if (rel_path.len == 0 or rel_path[0] == '/') return error.BadManifest;
    if (std.mem.indexOfScalar(u8, rel_path, '\\') != null) return error.BadManifest;
    try validateRelativeSegments(rel_path);
}

fn validateRelativeSegments(path: []const u8) Error!void {
    var segment_start: usize = 0;
    for (path, 0..) |c, i| {
        if (c < 0x20 or c == 0x7f or c == '\\' or c == '%') return error.BadManifest;
        if (c == '/') {
            try validateRelativeSegment(path[segment_start..i]);
            segment_start = i + 1;
        }
    }
    try validateRelativeSegment(path[segment_start..]);
}

fn validateRelativeSegment(segment: []const u8) Error!void {
    if (segment.len == 0) return error.BadManifest;
    if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.BadManifest;
}

fn validateSha256DigestHex(digest: []const u8) Error!void {
    if (digest.len != Sha256.digest_length * 2) return error.BadManifest;
    var bytes: [Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, digest) catch return error.BadManifest;
}

fn indexedBundleFiles(allocator: std.mem.Allocator, bundle_dir: []const u8) Error![][]const u8 {
    const parsed_bundle = try loadBundleIndex(allocator, bundle_dir);
    defer parsed_bundle.deinit();
    const bundle_index = parsed_bundle.value;

    const parsed_chunk_index = try loadIndex(allocator, bundle_dir);
    defer parsed_chunk_index.deinit();
    _ = parsed_chunk_index.value.chunks.len;

    var files = std.array_list.Managed([]const u8).init(allocator);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    try appendBundleFile(allocator, &files, &seen, bundle_index_path);
    try appendBundleFile(allocator, &files, &seen, bundle_index.parent_manifest);
    for (bundle_index.children) |child| {
        try appendBundleFile(allocator, &files, &seen, child.manifest);
    }
    try appendBundleFile(allocator, &files, &seen, index_path);
    try appendBundleFile(allocator, &files, &seen, pack_path);
    if (bundle_index.rootfs_index) |rootfs_index_rel| {
        try appendBundleFile(allocator, &files, &seen, rootfs_index_rel);
        const parsed_rootfs_index = try loadRootfsIndex(allocator, bundle_dir);
        defer parsed_rootfs_index.deinit();
        try appendRootfsIndexPayloadFiles(allocator, bundle_dir, parsed_rootfs_index.value, &files, &seen);
    }
    try appendDiskBundleFilesForManifestPath(allocator, bundle_dir, bundle_index.parent_manifest, &files, &seen);
    for (bundle_index.children) |child| {
        try appendDiskBundleFilesForManifestPath(allocator, bundle_dir, child.manifest, &files, &seen);
    }

    return files.toOwnedSlice() catch return error.OutOfMemory;
}

fn appendRootfsIndexPayloadFiles(
    allocator: std.mem.Allocator,
    bundle_dir: []const u8,
    index: RootfsIndex,
    files: *std.array_list.Managed([]const u8),
    seen: *std.StringHashMap(void),
) Error!void {
    for (index.artifacts) |artifact| {
        if (std.mem.eql(u8, artifact.policy, rootfs_policy_exact_bytes)) {
            try appendBundleFileIfMissing(allocator, files, seen, artifact.path orelse return error.BadManifest);
        }
    }
    for (index.storages) |storage_entry| {
        try appendBundleFileIfMissing(allocator, files, seen, storage_entry.index_path);
        const storage = rootfsStorageEntryDescriptor(storage_entry);
        const parsed_index = try loadDiskIndexForEntry(allocator, bundle_dir, storage_entry, storage);
        defer parsed_index.deinit();
        for (parsed_index.value.chunks) |chunk_entry| {
            const object_rel = try rootfsStorageObjectRelPath(allocator, chunk_entry.digest);
            try appendBundleFileIfMissing(allocator, files, seen, object_rel);
        }
    }
}

fn appendDiskBundleFilesForManifestPath(
    allocator: std.mem.Allocator,
    bundle_dir: []const u8,
    manifest_rel: []const u8,
    files: *std.array_list.Managed([]const u8),
    seen: *std.StringHashMap(void),
) Error!void {
    var parsed_manifest = try LoadedManifest.loadPath(
        allocator,
        try pathZ(allocator, "{s}/{s}", .{ bundle_dir, manifest_rel }),
    );
    defer parsed_manifest.deinit();
    const disk = parsed_manifest.disk() orelse return;
    for (disk.layers) |layer_ref| {
        const layer_rel = try diskLayerRelPath(allocator, layer_ref);
        try appendBundleFileIfMissing(allocator, files, seen, layer_rel);

        const parsed_layer = disk_layer.loadLayer(allocator, bundle_dir, layer_ref) catch |err| return diskLayerError(err);
        defer parsed_layer.deinit();
        if (parsed_layer.value.disk_size != disk.size) return error.BadManifest;
        for (parsed_layer.value.extents) |extent| {
            const object_rel = try diskObjectRelPath(allocator, extent.digest);
            try appendBundleFileIfMissing(allocator, files, seen, object_rel);
        }
    }
}

fn appendBundleFile(
    allocator: std.mem.Allocator,
    files: *std.array_list.Managed([]const u8),
    seen: *std.StringHashMap(void),
    rel_path: []const u8,
) Error!void {
    try validateBundleRelPath(rel_path);
    if (seen.contains(rel_path)) return error.BadManifest;
    const copy = allocator.dupe(u8, rel_path) catch return error.OutOfMemory;
    seen.put(copy, {}) catch return error.OutOfMemory;
    files.append(copy) catch return error.OutOfMemory;
}

fn appendBundleFileIfMissing(
    allocator: std.mem.Allocator,
    files: *std.array_list.Managed([]const u8),
    seen: *std.StringHashMap(void),
    rel_path: []const u8,
) Error!void {
    try validateBundleRelPath(rel_path);
    if (seen.contains(rel_path)) return;
    const copy = allocator.dupe(u8, rel_path) catch return error.OutOfMemory;
    seen.put(copy, {}) catch return error.OutOfMemory;
    files.append(copy) catch return error.OutOfMemory;
}

fn markBundleFileSeen(
    seen: *std.StringHashMap(void),
    rel_path: []const u8,
) Error!bool {
    try validateBundleRelPath(rel_path);
    if (seen.contains(rel_path)) return false;
    seen.put(rel_path, {}) catch return error.OutOfMemory;
    return true;
}

fn materializeS3Bundle(
    allocator: std.mem.Allocator,
    options: PullOptions,
    source: S3Source,
) Error!RemoteBundleMaterialization {
    const cache_root = options.bundle_cache_dir orelse return error.IoFailed;
    const bundle_dir = try remoteBundleCacheBundleDir(allocator, cache_root, "s3", source.expected_digest);
    const complete_path = try remoteBundleCacheCompletePath(allocator, cache_root, "s3", source.expected_digest);
    if (try pathExistsNoSymlink(options.io, complete_path)) {
        const cached_digest = try digestHex(allocator, bundle_dir);
        if (!std.mem.eql(u8, cached_digest, source.expected_digest)) return error.BadChunk;
        return .{
            .bundle_dir = bundle_dir,
            .origin_bytes_read = 0,
            .cache_hit = true,
        };
    }

    const cache_parent = try remoteBundleCacheParent(allocator, cache_root, "s3");
    try ensureDirPath(options.io, cache_parent);
    var nonce_bytes: [8]u8 = undefined;
    options.io.random(&nonce_bytes);
    const nonce = std.mem.readInt(u64, &nonce_bytes, .little);
    const temp_dir = try pathZ(allocator, "{s}/.tmp-{s}-{x}", .{ cache_parent, source.expected_digest[0..16], nonce });
    defer Io.Dir.cwd().deleteTree(options.io, temp_dir) catch {};
    try ensureNewDir(temp_dir);
    const temp_bundle_dir = try pathZ(allocator, "{s}/bundle", .{temp_dir});

    const origin_bytes = try downloadS3BundleToDir(allocator, options, source.location, temp_bundle_dir);
    const downloaded_digest = try digestHex(allocator, temp_bundle_dir);
    if (!std.mem.eql(u8, downloaded_digest, source.expected_digest)) return error.BadChunk;
    const temp_complete = try pathZ(allocator, "{s}/.complete", .{temp_dir});
    try writeFileAll(temp_complete, source.expected_digest);

    const final_dir = try remoteBundleCacheDir(allocator, cache_root, "s3", source.expected_digest);
    renamePath(options.io, temp_dir, final_dir) catch |err| {
        if (try pathExistsNoSymlink(options.io, complete_path)) {
            const cached_digest = try digestHex(allocator, bundle_dir);
            if (!std.mem.eql(u8, cached_digest, source.expected_digest)) return error.BadChunk;
            return .{
                .bundle_dir = bundle_dir,
                .origin_bytes_read = 0,
                .cache_hit = true,
            };
        }
        return err;
    };

    return .{
        .bundle_dir = bundle_dir,
        .origin_bytes_read = origin_bytes,
        .cache_hit = false,
    };
}

fn materializeHttpBundle(
    allocator: std.mem.Allocator,
    options: PullOptions,
    client: *std.http.Client,
    source: HttpSource,
) Error!RemoteBundleMaterialization {
    const cache_root = options.bundle_cache_dir orelse return error.IoFailed;
    const bundle_dir = try remoteBundleCacheBundleDir(allocator, cache_root, "http", source.expected_digest);
    const complete_path = try remoteBundleCacheCompletePath(allocator, cache_root, "http", source.expected_digest);
    if (try pathExistsNoSymlink(options.io, complete_path)) {
        const cached_digest = try digestHex(allocator, bundle_dir);
        if (!std.mem.eql(u8, cached_digest, source.expected_digest)) return error.BadChunk;
        return .{
            .bundle_dir = bundle_dir,
            .origin_bytes_read = 0,
            .cache_hit = true,
        };
    }

    const cache_parent = try remoteBundleCacheParent(allocator, cache_root, "http");
    try ensureDirPath(options.io, cache_parent);
    var nonce_bytes: [8]u8 = undefined;
    options.io.random(&nonce_bytes);
    const nonce = std.mem.readInt(u64, &nonce_bytes, .little);
    const temp_dir = try pathZ(allocator, "{s}/.tmp-{s}-{x}", .{ cache_parent, source.expected_digest[0..16], nonce });
    defer Io.Dir.cwd().deleteTree(options.io, temp_dir) catch {};
    try ensureNewDir(temp_dir);
    const temp_bundle_dir = try pathZ(allocator, "{s}/bundle", .{temp_dir});

    const peer_bytes = try downloadHttpBundleToDir(allocator, options, client, source.location, temp_bundle_dir);
    const downloaded_digest = try digestHex(allocator, temp_bundle_dir);
    if (!std.mem.eql(u8, downloaded_digest, source.expected_digest)) return error.BadChunk;
    const temp_complete = try pathZ(allocator, "{s}/.complete", .{temp_dir});
    try writeFileAll(temp_complete, source.expected_digest);

    const final_dir = try remoteBundleCacheDir(allocator, cache_root, "http", source.expected_digest);
    renamePath(options.io, temp_dir, final_dir) catch |err| {
        if (try pathExistsNoSymlink(options.io, complete_path)) {
            const cached_digest = try digestHex(allocator, bundle_dir);
            if (!std.mem.eql(u8, cached_digest, source.expected_digest)) return error.BadChunk;
            return .{
                .bundle_dir = bundle_dir,
                .origin_bytes_read = 0,
                .cache_hit = true,
            };
        }
        return err;
    };

    return .{
        .bundle_dir = bundle_dir,
        .origin_bytes_read = peer_bytes,
        .cache_hit = false,
    };
}

fn downloadS3BundleToDir(
    allocator: std.mem.Allocator,
    options: PullOptions,
    location: S3Location,
    bundle_dir: []const u8,
) Error!u64 {
    try ensureNewDir(try pathZ(allocator, "{s}", .{bundle_dir}));

    var origin_bytes: u64 = 0;
    var budget = RemoteBundleDownloadBudget{};
    origin_bytes += try downloadS3BundleMetadataFile(allocator, options, location, bundle_dir, bundle_index_path, &budget);

    const parsed_bundle = try loadBundleIndex(allocator, bundle_dir);
    defer parsed_bundle.deinit();
    const bundle_index = parsed_bundle.value;

    origin_bytes += try downloadS3BundleMetadataFile(allocator, options, location, bundle_dir, bundle_index.parent_manifest, &budget);
    for (bundle_index.children) |child| {
        origin_bytes += try downloadS3BundleMetadataFile(allocator, options, location, bundle_dir, child.manifest, &budget);
    }
    origin_bytes += try downloadS3BundleMetadataFile(allocator, options, location, bundle_dir, index_path, &budget);

    const parsed_chunk_index = try loadIndex(allocator, bundle_dir);
    defer parsed_chunk_index.deinit();
    _ = parsed_chunk_index.value.chunks.len;
    origin_bytes += try downloadS3BundlePayloadFile(allocator, options, location, bundle_dir, pack_path, &budget, try chunkPackPayloadBytes(parsed_chunk_index.value));

    if (bundle_index.rootfs_index) |rootfs_index_rel| {
        origin_bytes += try downloadS3BundleMetadataFile(allocator, options, location, bundle_dir, rootfs_index_rel, &budget);
        const parsed_rootfs_index = try loadRootfsIndex(allocator, bundle_dir);
        defer parsed_rootfs_index.deinit();
        origin_bytes += try downloadS3RootfsIndexPayloadFiles(allocator, options, location, bundle_dir, parsed_rootfs_index.value, &budget);
    }
    var seen_disk_files = std.StringHashMap(void).init(allocator);
    defer seen_disk_files.deinit();
    origin_bytes += try downloadS3DiskFilesForManifestPath(allocator, options, location, bundle_dir, bundle_index.parent_manifest, &seen_disk_files, &budget);
    for (bundle_index.children) |child| {
        origin_bytes += try downloadS3DiskFilesForManifestPath(allocator, options, location, bundle_dir, child.manifest, &seen_disk_files, &budget);
    }
    return origin_bytes;
}

fn downloadHttpBundleToDir(
    allocator: std.mem.Allocator,
    options: PullOptions,
    client: *std.http.Client,
    location: HttpLocation,
    bundle_dir: []const u8,
) Error!u64 {
    try ensureNewDir(try pathZ(allocator, "{s}", .{bundle_dir}));

    var peer_bytes: u64 = 0;
    var budget = RemoteBundleDownloadBudget{};
    peer_bytes += try downloadHttpBundleMetadataFile(allocator, options, client, location, bundle_dir, bundle_index_path, &budget);

    const parsed_bundle = try loadBundleIndex(allocator, bundle_dir);
    defer parsed_bundle.deinit();
    const bundle_index = parsed_bundle.value;

    peer_bytes += try downloadHttpBundleMetadataFile(allocator, options, client, location, bundle_dir, bundle_index.parent_manifest, &budget);
    for (bundle_index.children) |child| {
        peer_bytes += try downloadHttpBundleMetadataFile(allocator, options, client, location, bundle_dir, child.manifest, &budget);
    }
    peer_bytes += try downloadHttpBundleMetadataFile(allocator, options, client, location, bundle_dir, index_path, &budget);

    const parsed_chunk_index = try loadIndex(allocator, bundle_dir);
    defer parsed_chunk_index.deinit();
    _ = parsed_chunk_index.value.chunks.len;
    peer_bytes += try downloadHttpBundlePayloadFile(allocator, options, client, location, bundle_dir, pack_path, &budget, try chunkPackPayloadBytes(parsed_chunk_index.value));

    if (bundle_index.rootfs_index) |rootfs_index_rel| {
        peer_bytes += try downloadHttpBundleMetadataFile(allocator, options, client, location, bundle_dir, rootfs_index_rel, &budget);
        const parsed_rootfs_index = try loadRootfsIndex(allocator, bundle_dir);
        defer parsed_rootfs_index.deinit();
        peer_bytes += try downloadHttpRootfsIndexPayloadFiles(allocator, options, client, location, bundle_dir, parsed_rootfs_index.value, &budget);
    }
    var seen_disk_files = std.StringHashMap(void).init(allocator);
    defer seen_disk_files.deinit();
    peer_bytes += try downloadHttpDiskFilesForManifestPath(allocator, options, client, location, bundle_dir, bundle_index.parent_manifest, &seen_disk_files, &budget);
    for (bundle_index.children) |child| {
        peer_bytes += try downloadHttpDiskFilesForManifestPath(allocator, options, client, location, bundle_dir, child.manifest, &seen_disk_files, &budget);
    }
    return peer_bytes;
}

fn downloadS3RootfsIndexPayloadFiles(
    allocator: std.mem.Allocator,
    options: PullOptions,
    location: S3Location,
    bundle_dir: []const u8,
    index: RootfsIndex,
    budget: *RemoteBundleDownloadBudget,
) Error!u64 {
    var bytes: u64 = 0;
    for (index.artifacts) |artifact| {
        if (std.mem.eql(u8, artifact.policy, rootfs_policy_exact_bytes)) {
            bytes += try downloadS3BundlePayloadFile(allocator, options, location, bundle_dir, artifact.path orelse return error.BadManifest, budget, artifact.size);
        }
    }
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    for (index.storages) |storage_entry| {
        if (try markBundleFileSeen(&seen, storage_entry.index_path)) {
            bytes += try downloadS3BundleSizedMetadataFile(allocator, options, location, bundle_dir, storage_entry.index_path, budget, storage_entry.index_bytes);
        }
        const storage = rootfsStorageEntryDescriptor(storage_entry);
        const parsed_index = try loadDiskIndexForEntry(allocator, bundle_dir, storage_entry, storage);
        defer parsed_index.deinit();
        for (parsed_index.value.chunks) |chunk_entry| {
            const object_rel = try rootfsStorageObjectRelPath(allocator, chunk_entry.digest);
            if (try markBundleFileSeen(&seen, object_rel)) {
                const expected_size = rootfs_cas.storageChunkLen(storage, chunk_entry.logical_chunk) catch |err| return rootfsError(err);
                bytes += try downloadS3BundlePayloadFile(allocator, options, location, bundle_dir, object_rel, budget, @intCast(expected_size));
            }
        }
    }
    return bytes;
}

fn downloadHttpRootfsIndexPayloadFiles(
    allocator: std.mem.Allocator,
    options: PullOptions,
    client: *std.http.Client,
    location: HttpLocation,
    bundle_dir: []const u8,
    index: RootfsIndex,
    budget: *RemoteBundleDownloadBudget,
) Error!u64 {
    var bytes: u64 = 0;
    for (index.artifacts) |artifact| {
        if (std.mem.eql(u8, artifact.policy, rootfs_policy_exact_bytes)) {
            bytes += try downloadHttpBundlePayloadFile(allocator, options, client, location, bundle_dir, artifact.path orelse return error.BadManifest, budget, artifact.size);
        }
    }
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    for (index.storages) |storage_entry| {
        if (try markBundleFileSeen(&seen, storage_entry.index_path)) {
            bytes += try downloadHttpBundleSizedMetadataFile(allocator, options, client, location, bundle_dir, storage_entry.index_path, budget, storage_entry.index_bytes);
        }
        const storage = rootfsStorageEntryDescriptor(storage_entry);
        const parsed_index = try loadDiskIndexForEntry(allocator, bundle_dir, storage_entry, storage);
        defer parsed_index.deinit();
        for (parsed_index.value.chunks) |chunk_entry| {
            const object_rel = try rootfsStorageObjectRelPath(allocator, chunk_entry.digest);
            if (try markBundleFileSeen(&seen, object_rel)) {
                const expected_size = rootfs_cas.storageChunkLen(storage, chunk_entry.logical_chunk) catch |err| return rootfsError(err);
                bytes += try downloadHttpBundlePayloadFile(allocator, options, client, location, bundle_dir, object_rel, budget, @intCast(expected_size));
            }
        }
    }
    return bytes;
}

fn downloadS3DiskFilesForManifestPath(
    allocator: std.mem.Allocator,
    options: PullOptions,
    location: S3Location,
    bundle_dir: []const u8,
    manifest_rel: []const u8,
    seen: *std.StringHashMap(void),
    budget: *RemoteBundleDownloadBudget,
) Error!u64 {
    var parsed_manifest = try LoadedManifest.loadPath(
        allocator,
        try pathZ(allocator, "{s}/{s}", .{ bundle_dir, manifest_rel }),
    );
    defer parsed_manifest.deinit();
    const disk = parsed_manifest.disk() orelse return 0;
    var bytes: u64 = 0;
    for (disk.layers) |layer_ref| {
        const layer_rel = try diskLayerRelPath(allocator, layer_ref);
        if (try markBundleFileSeen(seen, layer_rel)) {
            bytes += try downloadS3BundleMetadataFile(allocator, options, location, bundle_dir, layer_rel, budget);
        }
        const parsed_layer = disk_layer.loadLayer(allocator, bundle_dir, layer_ref) catch |err| return diskLayerError(err);
        defer parsed_layer.deinit();
        if (parsed_layer.value.disk_size != disk.size) return error.BadManifest;
        for (parsed_layer.value.extents) |extent| {
            const object_rel = try diskObjectRelPath(allocator, extent.digest);
            if (try markBundleFileSeen(seen, object_rel)) {
                const expected_size = try spore.diskClusterLen(parsed_layer.value.disk_size, parsed_layer.value.cluster_size, extent.logical_cluster);
                bytes += try downloadS3BundlePayloadFile(allocator, options, location, bundle_dir, object_rel, budget, @intCast(expected_size));
            }
        }
    }
    return bytes;
}

fn downloadHttpDiskFilesForManifestPath(
    allocator: std.mem.Allocator,
    options: PullOptions,
    client: *std.http.Client,
    location: HttpLocation,
    bundle_dir: []const u8,
    manifest_rel: []const u8,
    seen: *std.StringHashMap(void),
    budget: *RemoteBundleDownloadBudget,
) Error!u64 {
    var parsed_manifest = try LoadedManifest.loadPath(
        allocator,
        try pathZ(allocator, "{s}/{s}", .{ bundle_dir, manifest_rel }),
    );
    defer parsed_manifest.deinit();
    const disk = parsed_manifest.disk() orelse return 0;
    var bytes: u64 = 0;
    for (disk.layers) |layer_ref| {
        const layer_rel = try diskLayerRelPath(allocator, layer_ref);
        if (try markBundleFileSeen(seen, layer_rel)) {
            bytes += try downloadHttpBundleMetadataFile(allocator, options, client, location, bundle_dir, layer_rel, budget);
        }
        const parsed_layer = disk_layer.loadLayer(allocator, bundle_dir, layer_ref) catch |err| return diskLayerError(err);
        defer parsed_layer.deinit();
        if (parsed_layer.value.disk_size != disk.size) return error.BadManifest;
        for (parsed_layer.value.extents) |extent| {
            const object_rel = try diskObjectRelPath(allocator, extent.digest);
            if (try markBundleFileSeen(seen, object_rel)) {
                const expected_size = try spore.diskClusterLen(parsed_layer.value.disk_size, parsed_layer.value.cluster_size, extent.logical_cluster);
                bytes += try downloadHttpBundlePayloadFile(allocator, options, client, location, bundle_dir, object_rel, budget, @intCast(expected_size));
            }
        }
    }
    return bytes;
}

fn downloadS3BundleMetadataFile(
    allocator: std.mem.Allocator,
    options: PullOptions,
    location: S3Location,
    bundle_dir: []const u8,
    rel_path: []const u8,
    budget: *RemoteBundleDownloadBudget,
) Error!u64 {
    return downloadS3BundleFile(allocator, options, location, bundle_dir, rel_path, budget, .metadata, max_remote_bundle_metadata_file_bytes);
}

fn downloadS3BundleSizedMetadataFile(
    allocator: std.mem.Allocator,
    options: PullOptions,
    location: S3Location,
    bundle_dir: []const u8,
    rel_path: []const u8,
    budget: *RemoteBundleDownloadBudget,
    max_body_bytes: u64,
) Error!u64 {
    return downloadS3BundleFile(allocator, options, location, bundle_dir, rel_path, budget, .metadata, max_body_bytes);
}

fn downloadS3BundlePayloadFile(
    allocator: std.mem.Allocator,
    options: PullOptions,
    location: S3Location,
    bundle_dir: []const u8,
    rel_path: []const u8,
    budget: *RemoteBundleDownloadBudget,
    max_body_bytes: u64,
) Error!u64 {
    return downloadS3BundleFile(allocator, options, location, bundle_dir, rel_path, budget, .payload, max_body_bytes);
}

fn downloadS3BundleFile(
    allocator: std.mem.Allocator,
    options: PullOptions,
    location: S3Location,
    bundle_dir: []const u8,
    rel_path: []const u8,
    budget: *RemoteBundleDownloadBudget,
    file_class: RemoteBundleFileClass,
    max_body_bytes: u64,
) Error!u64 {
    try validateBundleRelPath(rel_path);
    const dest_path = try pathZ(allocator, "{s}/{s}", .{ bundle_dir, rel_path });
    if (std.fs.path.dirname(dest_path)) |parent| try ensureDirPath(options.io, parent);
    errdefer Io.Dir.cwd().deleteFile(options.io, dest_path) catch {};

    const object_key = try location.objectKey(allocator, rel_path);
    const limit = try budget.limitFor(file_class, max_body_bytes);
    const object_size = try runAwsS3HeadObjectContentLength(allocator, options.io, options.aws_executable, location.bucket, object_key, options.aws_region);
    if (object_size > limit) return error.BundleBodyTooLarge;

    if (object_size == 0) {
        var file = Io.Dir.cwd().createFile(options.io, dest_path, .{}) catch return error.IoFailed;
        file.close(options.io);
    } else {
        try runAwsS3GetObject(allocator, options.io, options.aws_executable, location.bucket, object_key, dest_path, options.aws_region, limit);
    }
    const copied = try fileSizeNoSymlink(options.io, dest_path);
    if (copied != object_size) return error.BadChunk;
    try budget.record(file_class, copied);
    return copied;
}

fn downloadHttpBundleMetadataFile(
    allocator: std.mem.Allocator,
    options: PullOptions,
    client: *std.http.Client,
    location: HttpLocation,
    bundle_dir: []const u8,
    rel_path: []const u8,
    budget: *RemoteBundleDownloadBudget,
) Error!u64 {
    return downloadHttpBundleFile(allocator, options, client, location, bundle_dir, rel_path, budget, .metadata, max_remote_bundle_metadata_file_bytes);
}

fn downloadHttpBundleSizedMetadataFile(
    allocator: std.mem.Allocator,
    options: PullOptions,
    client: *std.http.Client,
    location: HttpLocation,
    bundle_dir: []const u8,
    rel_path: []const u8,
    budget: *RemoteBundleDownloadBudget,
    max_body_bytes: u64,
) Error!u64 {
    return downloadHttpBundleFile(allocator, options, client, location, bundle_dir, rel_path, budget, .metadata, max_body_bytes);
}

fn downloadHttpBundlePayloadFile(
    allocator: std.mem.Allocator,
    options: PullOptions,
    client: *std.http.Client,
    location: HttpLocation,
    bundle_dir: []const u8,
    rel_path: []const u8,
    budget: *RemoteBundleDownloadBudget,
    max_body_bytes: u64,
) Error!u64 {
    return downloadHttpBundleFile(allocator, options, client, location, bundle_dir, rel_path, budget, .payload, max_body_bytes);
}

fn downloadHttpBundleFile(
    allocator: std.mem.Allocator,
    options: PullOptions,
    client: *std.http.Client,
    location: HttpLocation,
    bundle_dir: []const u8,
    rel_path: []const u8,
    budget: *RemoteBundleDownloadBudget,
    file_class: RemoteBundleFileClass,
    max_body_bytes: u64,
) Error!u64 {
    try validateBundleRelPath(rel_path);
    const dest_path = try pathZ(allocator, "{s}/{s}", .{ bundle_dir, rel_path });
    if (std.fs.path.dirname(dest_path)) |parent| try ensureDirPath(options.io, parent);
    const url = try location.objectUrl(allocator, rel_path);
    const limit = try budget.limitFor(file_class, max_body_bytes);
    const copied = try httpGetToFile(options.io, client, url, dest_path, limit);
    try budget.record(file_class, copied);
    return copied;
}

fn httpGetToFile(
    io: Io,
    client: *std.http.Client,
    url: []const u8,
    path: []const u8,
    max_body_bytes: u64,
) Error!u64 {
    const uri = std.Uri.parse(url) catch return error.BadManifest;
    const target_address = resolveHttpFetchTarget(client.io, uri) catch |err| return err;
    return httpGetToFileAfterPolicy(io, client, uri, target_address, path, max_body_bytes);
}

fn httpGetToFileAfterPolicy(
    io: Io,
    client: *std.http.Client,
    uri: std.Uri,
    target_address: Io.net.IpAddress,
    path: []const u8,
    max_body_bytes: u64,
) Error!u64 {
    var file = Io.Dir.cwd().createFile(io, path, .{}) catch return error.IoFailed;
    errdefer Io.Dir.cwd().deleteFile(io, path) catch {};
    defer file.close(io);

    var file_buffer: [64 * 1024]u8 = undefined;
    var file_writer: Io.File.Writer = .initStreaming(file, io, &file_buffer);
    const connection = fetch_policy.connectResolvedUri(client, uri, target_address) catch return error.IoFailed;
    var req = client.request(.GET, uri, .{
        .headers = .{ .accept_encoding = .omit },
        .extra_headers = &.{std.http.Header{ .name = "accept", .value = "application/octet-stream" }},
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .connection = connection,
    }) catch {
        client.connection_pool.release(connection, client.io);
        return error.IoFailed;
    };
    defer req.deinit();
    req.sendBodiless() catch return error.IoFailed;
    var header_buffer: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&header_buffer) catch return error.IoFailed;
    if (response.head.status != .ok) return error.BadChunk;
    if (try httpContentLength(response.head.bytes)) |content_length| {
        if (content_length > max_body_bytes) return error.BundleBodyTooLarge;
    }

    var transfer_buffer: [64 * 1024]u8 = undefined;
    var body = response.reader(&transfer_buffer);
    var copied: u64 = 0;
    var copy_buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = body.readSliceShort(&copy_buffer) catch return error.IoFailed;
        if (n == 0) break;
        const n_u64: u64 = @intCast(n);
        if (n_u64 > max_body_bytes - copied) return error.BundleBodyTooLarge;
        copied += n_u64;
        file_writer.interface.writeAll(copy_buffer[0..n]) catch return error.IoFailed;
    }
    file_writer.interface.flush() catch return error.IoFailed;
    return copied;
}

fn httpContentLength(head: []const u8) Error!?u64 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.first();
    var found: ?u64 = null;
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const header_name = line[0..colon];
        if (!std.ascii.eqlIgnoreCase(header_name, "content-length")) continue;
        if (found != null) return error.BadChunk;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len == 0) return error.BadChunk;
        found = std.fmt.parseInt(u64, value, 10) catch return error.BadChunk;
    }
    return found;
}

fn resolveHttpFetchTarget(io: Io, uri: std.Uri) Error!Io.net.IpAddress {
    return fetch_policy.resolveUriAddress(io, uri, .{}) catch |err| switch (err) {
        error.UnsupportedRemoteFetchScheme,
        error.UnsafeRemoteFetchTarget,
        => return error.BadManifest,
        else => return error.IoFailed,
    };
}

fn validateHttpFetchTarget(io: Io, uri: std.Uri) Error!void {
    _ = try resolveHttpFetchTarget(io, uri);
}

fn appendAwsRegion(argv: *std.array_list.Managed([]const u8), region: ?[]const u8) Error!void {
    if (region) |value| {
        if (value.len == 0) return error.BadManifest;
        argv.append("--region") catch return error.OutOfMemory;
        argv.append(value) catch return error.OutOfMemory;
    }
}

fn runAwsS3HeadObjectContentLength(
    allocator: std.mem.Allocator,
    io: Io,
    aws_executable: []const u8,
    bucket: []const u8,
    key: []const u8,
    region: ?[]const u8,
) Error!u64 {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    argv.append(aws_executable) catch return error.OutOfMemory;
    argv.append("s3api") catch return error.OutOfMemory;
    argv.append("head-object") catch return error.OutOfMemory;
    argv.append("--bucket") catch return error.OutOfMemory;
    argv.append(bucket) catch return error.OutOfMemory;
    argv.append("--key") catch return error.OutOfMemory;
    argv.append(key) catch return error.OutOfMemory;
    argv.append("--query") catch return error.OutOfMemory;
    argv.append("ContentLength") catch return error.OutOfMemory;
    argv.append("--output") catch return error.OutOfMemory;
    argv.append("text") catch return error.OutOfMemory;
    try appendAwsRegion(&argv, region);

    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(8 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch return error.IoFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) {
            const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
            if (trimmed.len == 0) return error.BadChunk;
            return std.fmt.parseInt(u64, trimmed, 10) catch return error.BadChunk;
        },
        else => {},
    }
    return error.IoFailed;
}

fn runAwsS3GetObject(
    allocator: std.mem.Allocator,
    io: Io,
    aws_executable: []const u8,
    bucket: []const u8,
    key: []const u8,
    destination: []const u8,
    region: ?[]const u8,
    max_body_bytes: u64,
) Error!void {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    argv.append(aws_executable) catch return error.OutOfMemory;
    argv.append("s3api") catch return error.OutOfMemory;
    argv.append("get-object") catch return error.OutOfMemory;
    argv.append("--bucket") catch return error.OutOfMemory;
    argv.append(bucket) catch return error.OutOfMemory;
    argv.append("--key") catch return error.OutOfMemory;
    argv.append(key) catch return error.OutOfMemory;
    if (max_body_bytes > 0) {
        const range = std.fmt.allocPrint(allocator, "bytes=0-{d}", .{max_body_bytes - 1}) catch return error.OutOfMemory;
        argv.append("--range") catch return error.OutOfMemory;
        argv.append(range) catch return error.OutOfMemory;
    }
    try appendAwsRegion(&argv, region);
    argv.append(destination) catch return error.OutOfMemory;

    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch return error.IoFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.IoFailed;
}

fn runAwsS3Cp(
    allocator: std.mem.Allocator,
    io: Io,
    aws_executable: []const u8,
    source: []const u8,
    destination: []const u8,
    region: ?[]const u8,
) Error!void {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    argv.append(aws_executable) catch return error.OutOfMemory;
    argv.append("s3") catch return error.OutOfMemory;
    argv.append("cp") catch return error.OutOfMemory;
    argv.append(source) catch return error.OutOfMemory;
    argv.append(destination) catch return error.OutOfMemory;
    try appendAwsRegion(&argv, region);
    argv.append("--only-show-errors") catch return error.OutOfMemory;

    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch return error.IoFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.IoFailed;
}

fn fileSizeNoSymlink(io: Io, path: []const u8) Error!u64 {
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return error.BadChunk,
        else => return error.IoFailed,
    };
    if (stat.kind != .file) return error.BadChunk;
    return stat.size;
}

fn remoteBundleCacheParent(allocator: std.mem.Allocator, cache_root: []const u8, source_kind: []const u8) Error![]const u8 {
    try validateRelativeSegment(source_kind);
    return std.fs.path.join(allocator, &.{ cache_root, "remote", source_kind, "sha256" }) catch return error.OutOfMemory;
}

fn remoteBundleCacheDir(allocator: std.mem.Allocator, cache_root: []const u8, source_kind: []const u8, digest: []const u8) Error![]const u8 {
    try validateRelativeSegment(source_kind);
    try validateSha256DigestHex(digest);
    return std.fs.path.join(allocator, &.{ cache_root, "remote", source_kind, "sha256", digest }) catch return error.OutOfMemory;
}

fn remoteBundleCacheBundleDir(allocator: std.mem.Allocator, cache_root: []const u8, source_kind: []const u8, digest: []const u8) Error![]const u8 {
    try validateRelativeSegment(source_kind);
    try validateSha256DigestHex(digest);
    return std.fs.path.join(allocator, &.{ cache_root, "remote", source_kind, "sha256", digest, "bundle" }) catch return error.OutOfMemory;
}

fn remoteBundleCacheCompletePath(allocator: std.mem.Allocator, cache_root: []const u8, source_kind: []const u8, digest: []const u8) Error![]const u8 {
    try validateRelativeSegment(source_kind);
    try validateSha256DigestHex(digest);
    return std.fs.path.join(allocator, &.{ cache_root, "remote", source_kind, "sha256", digest, ".complete" }) catch return error.OutOfMemory;
}

const ChildDir = struct {
    id: []const u8,
    path: []const u8,
};

fn listChildDirs(allocator: std.mem.Allocator, io: Io, children_dir: []const u8) Error![]ChildDir {
    var dir = Io.Dir.cwd().openDir(io, children_dir, .{ .iterate = true }) catch return error.IoFailed;
    defer dir.close(io);

    var children = std.array_list.Managed(ChildDir).init(allocator);
    var it = dir.iterate();
    while (it.next(io) catch return error.IoFailed) |entry| {
        if (entry.kind != .directory) continue;
        validateChildId(entry.name) catch continue;
        const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{entry.name});
        dir.access(io, manifest_path, .{}) catch continue;
        try children.append(.{
            .id = allocator.dupe(u8, entry.name) catch return error.OutOfMemory,
            .path = std.fs.path.join(allocator, &.{ children_dir, entry.name }) catch return error.OutOfMemory,
        });
    }

    const out = children.toOwnedSlice() catch return error.OutOfMemory;
    std.mem.sort(ChildDir, out, {}, lessChildDir);
    return out;
}

fn validateChildId(id: []const u8) Error!void {
    if (id.len != 6) return error.BadManifest;
    for (id) |c| {
        if (!std.ascii.isDigit(c)) return error.BadManifest;
    }
}

fn lessChildDir(_: void, a: ChildDir, b: ChildDir) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

fn lessRootfsArtifactEntry(_: void, a: RootfsArtifactEntry, b: RootfsArtifactEntry) bool {
    return std.mem.lessThan(u8, a.digest, b.digest);
}

fn lessRootfsStorageEntry(_: void, a: RootfsStorageEntry, b: RootfsStorageEntry) bool {
    return std.mem.lessThan(u8, a.index_digest, b.index_digest);
}

fn rootfsError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadManifest => error.BadManifest,
        error.BadChunk,
        error.MissingChunk,
        error.ShortRead,
        error.RootFSDigestMismatch,
        error.RootFSDigestCacheMiss,
        error.RootFSOpenFailed,
        error.BadPathName,
        => error.BadChunk,
        else => error.IoFailed,
    };
}

fn diskLayerError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadManifest => error.BadManifest,
        error.BadChunk,
        error.BadClusterSize,
        error.BadDiskSize,
        error.OutOfRange,
        error.ShortRead,
        error.ShortWrite,
        error.ResizeFailed,
        error.FlushFailed,
        => error.BadChunk,
        else => error.IoFailed,
    };
}

fn chunkRange(plan: spore.MemoryPlan, ram_len: usize, index: usize) Error!spore.MemoryChunkRange {
    if (index >= plan.chunk_count) return error.BadManifest;
    const start = index * plan.chunk_size;
    const end = @min(start + plan.chunk_size, ram_len);
    return .{ .start = start, .end = end };
}

fn writeFileAll(path: [:0]const u8, data: []const u8) Error!void {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);
    var done: usize = 0;
    while (done < data.len) {
        const n = std.c.write(fd, data.ptr + done, data.len - done);
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
}

fn pwriteFileAll(fd: std.c.fd_t, offset: usize, data: []const u8) Error!void {
    var done: usize = 0;
    while (done < data.len) {
        const n = std.c.pwrite(fd, data.ptr + done, data.len - done, @intCast(offset + done));
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
}

fn preadFileAll(fd: std.c.fd_t, offset: usize, target: []u8) Error!void {
    var done: usize = 0;
    while (done < target.len) {
        const n = std.c.pread(fd, target.ptr + done, target.len - done, @intCast(offset + done));
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
}

fn readFileAll(allocator: std.mem.Allocator, path: [:0]const u8, max: usize) Error![]u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);
    const size = try seekFileSize(fd);
    if (size > max) return error.BadChunk;
    const buf = allocator.alloc(u8, size) catch return error.OutOfMemory;
    errdefer allocator.free(buf);
    var done: usize = 0;
    while (done < size) {
        const n = std.c.read(fd, buf.ptr + done, size - done);
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
    return buf;
}

fn readFileAllNoSymlink(allocator: std.mem.Allocator, path: []const u8, max: usize) Error![]u8 {
    const path_z = try pathZ(allocator, "{s}", .{path});
    defer allocator.free(path_z);
    const fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.BadChunk;
    defer _ = std.c.close(fd);
    const size = try fstatRegularSize(fd);
    if (size > max) return error.BadChunk;
    const buf = allocator.alloc(u8, size) catch return error.OutOfMemory;
    errdefer allocator.free(buf);
    var done: usize = 0;
    while (done < size) {
        const n = std.c.read(fd, buf.ptr + done, size - done);
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
    return buf;
}

fn fstatRegularSize(fd: std.c.fd_t) Error!usize {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var statx_buf: linux.Statx = undefined;
        const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{
            .TYPE = true,
            .MODE = true,
            .SIZE = true,
        }, &statx_buf);
        if (linux.errno(rc) != .SUCCESS) return error.IoFailed;
        if (!linux.S.ISREG(statx_buf.mode)) return error.BadChunk;
        return std.math.cast(usize, statx_buf.size) orelse error.BadChunk;
    } else {
        var stat: std.c.Stat = undefined;
        if (std.c.fstat(fd, &stat) != 0) return error.IoFailed;
        if (!std.c.S.ISREG(stat.mode)) return error.BadChunk;
        if (stat.size < 0) return error.IoFailed;
        return std.math.cast(usize, stat.size) orelse error.BadChunk;
    }
}

fn readFileRange(allocator: std.mem.Allocator, path: [:0]const u8, offset: u64, size: u64) Error![]u8 {
    if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) return error.BadChunk;
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);
    const file_size = try seekFileSize(fd);
    const start: usize = @intCast(offset);
    const len: usize = @intCast(size);
    if (start > file_size or len > file_size - start) return error.BadChunk;
    const out = allocator.alloc(u8, len) catch return error.OutOfMemory;
    errdefer allocator.free(out);
    try preadFileAll(fd, start, out);
    return out;
}

fn writeFileExclusive(path: [:0]const u8, data: []const u8, mode: c_uint) Error!void {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, mode);
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);
    var done: usize = 0;
    while (done < data.len) {
        const n = std.c.write(fd, data.ptr + done, data.len - done);
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
    if (std.c.fchmod(fd, @intCast(mode)) != 0) return error.IoFailed;
}

fn regularFileNoSymlink(io: Io, path: []const u8) Error!bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return false,
        else => return error.IoFailed,
    };
    return stat.kind == .file;
}

fn pathExistsNoSymlink(io: Io, path: []const u8) Error!bool {
    _ = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return false,
        else => return error.IoFailed,
    };
    return true;
}

fn ensureDirPath(io: Io, path: []const u8) Error!void {
    if (!Io.Dir.path.isAbsolute(path)) {
        Io.Dir.cwd().createDirPath(io, path) catch return error.IoFailed;
        return;
    }
    var existing = Io.Dir.openDirAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (std.fs.path.dirname(path)) |parent| {
                if (parent.len > 0 and !std.mem.eql(u8, parent, path)) try ensureDirPath(io, parent);
            }
            Io.Dir.createDirAbsolute(io, path, .default_dir) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => {},
                else => return error.IoFailed,
            };
            return;
        },
        else => return error.IoFailed,
    };
    existing.close(io);
}

fn renamePath(io: Io, old_path: []const u8, new_path: []const u8) Error!void {
    const old_absolute = Io.Dir.path.isAbsolute(old_path);
    const new_absolute = Io.Dir.path.isAbsolute(new_path);
    if (old_absolute != new_absolute) return error.BadManifest;
    if (old_absolute) {
        Io.Dir.renameAbsolute(old_path, new_path, io) catch return error.IoFailed;
    } else {
        Io.Dir.rename(Io.Dir.cwd(), old_path, Io.Dir.cwd(), new_path, io) catch return error.IoFailed;
    }
}

fn updateHashWithFile(
    allocator: std.mem.Allocator,
    h: *Sha256,
    dir: []const u8,
    rel_path: []const u8,
) Error!void {
    const path = try pathZ(allocator, "{s}/{s}", .{ dir, rel_path });
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);

    const size = try seekFileSize(fd);
    var size_buf: [32]u8 = undefined;
    const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{size}) catch unreachable;
    h.update(rel_path);
    h.update(&[_]u8{0});
    h.update(size_str);
    h.update(&[_]u8{0});

    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, buf[0..].ptr, buf.len);
        if (n < 0) return error.IoFailed;
        if (n == 0) break;
        h.update(buf[0..@intCast(n)]);
    }
}

fn seekFileSize(fd: std.c.fd_t) Error!usize {
    const cur = std.c.lseek(fd, 0, std.c.SEEK.CUR);
    if (cur < 0) return error.IoFailed;
    const end = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (end < 0) return error.IoFailed;
    if (std.c.lseek(fd, cur, std.c.SEEK.SET) < 0) return error.IoFailed;
    return @intCast(end);
}

fn ensureNewDir(path: [:0]const u8) Error!void {
    if (std.c.mkdir(path, 0o755) != 0) {
        if (std.c.access(path, 0) == 0) return error.AlreadyExists;
        return error.IoFailed;
    }
}

fn pathZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Error![:0]const u8 {
    return std.fmt.allocPrintSentinel(allocator, fmt, args, 0) catch error.OutOfMemory;
}

fn sha256HexAlloc(allocator: std.mem.Allocator, data: []const u8) Error![]const u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex) catch return error.OutOfMemory;
}

fn sha256HexMatches(hex: []const u8, data: []const u8) bool {
    var expected: [Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, hex) catch return false;
    var actual: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &actual, .{});
    return std.mem.eql(u8, &expected, &actual);
}

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

fn testDir(allocator: std.mem.Allocator) ![]const u8 {
    const tmpl = "/tmp/sporevm-bundle-test-XXXXXX";
    const buf = try allocator.dupeZ(u8, tmpl);
    if (mkdtemp(buf) == null) return error.IoFailed;
    return buf;
}

const StaticHttpBundleServer = struct {
    allocator: std.mem.Allocator,
    io: Io,
    bundle_dir: []const u8,
    url_prefix: []const u8,
    server: std.Io.net.Server,
    thread: std.Thread,
    closed: std.atomic.Value(bool),
    request_count: std.atomic.Value(usize),

    fn init(self: *StaticHttpBundleServer, allocator: std.mem.Allocator, io: Io, bundle_dir: []const u8, url_prefix: []const u8) !void {
        var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .bundle_dir = bundle_dir,
            .url_prefix = url_prefix,
            .server = try address.listen(io, .{ .kernel_backlog = 8, .reuse_address = true }),
            .thread = undefined,
            .closed = .init(false),
            .request_count = .init(0),
        };
        self.thread = try std.Thread.spawn(.{}, StaticHttpBundleServer.serveThread, .{self});
    }

    fn deinit(self: *StaticHttpBundleServer) void {
        const wake_address = self.server.socket.address;
        self.closed.store(true, .release);
        if (wake_address.connect(self.io, .{ .mode = .stream })) |stream| {
            stream.close(self.io);
        } else |_| {}
        self.server.deinit(self.io);
        self.thread.join();
    }

    fn baseUrl(self: *StaticHttpBundleServer, allocator: std.mem.Allocator) ![]const u8 {
        const port = self.server.socket.address.getPort();
        if (self.url_prefix.len == 0) return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/{s}", .{ port, self.url_prefix });
    }

    fn serveThread(self: *StaticHttpBundleServer) void {
        while (!self.closed.load(.acquire)) {
            var stream = self.server.accept(self.io) catch {
                if (self.closed.load(.acquire)) return;
                continue;
            };
            self.handle(stream) catch {};
            stream.close(self.io);
        }
    }

    fn handle(self: *StaticHttpBundleServer, stream: std.Io.net.Stream) !void {
        _ = self.request_count.fetchAdd(1, .monotonic);
        var read_buffer: [8 * 1024]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        const request_line_raw = reader.interface.takeDelimiterExclusive('\n') catch return;
        const request_line = std.mem.trimEnd(u8, request_line_raw, "\r");
        while (true) {
            const header_raw = reader.interface.takeDelimiterExclusive('\n') catch return;
            const header = std.mem.trimEnd(u8, header_raw, "\r");
            if (header.len == 0) break;
        }

        const method_prefix = "GET ";
        if (!std.mem.startsWith(u8, request_line, method_prefix)) return self.writeStatus(stream, 405);
        const rest = request_line[method_prefix.len..];
        const path_end = std.mem.indexOfScalar(u8, rest, ' ') orelse return self.writeStatus(stream, 400);
        const path = rest[0..path_end];
        if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, '?') != null) return self.writeStatus(stream, 404);
        var rel_path = path[1..];
        if (self.url_prefix.len > 0) {
            if (!std.mem.startsWith(u8, rel_path, self.url_prefix)) return self.writeStatus(stream, 404);
            rel_path = rel_path[self.url_prefix.len..];
            if (rel_path.len == 0 or rel_path[0] != '/') return self.writeStatus(stream, 404);
            rel_path = rel_path[1..];
        }
        validateBundleRelPath(rel_path) catch return self.writeStatus(stream, 404);
        const file_path = try pathZ(self.allocator, "{s}/{s}", .{ self.bundle_dir, rel_path });
        const data = readFileAll(self.allocator, file_path, std.math.maxInt(usize)) catch return self.writeStatus(stream, 404);
        defer self.allocator.free(data);

        var write_buffer: [8 * 1024]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        try writer.interface.print(
            "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{data.len},
        );
        try writer.interface.writeAll(data);
        try writer.interface.flush();
    }

    fn writeStatus(self: *StaticHttpBundleServer, stream: std.Io.net.Stream, status: u16) !void {
        var write_buffer: [256]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        try writer.interface.print(
            "HTTP/1.1 {d} Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            .{status},
        );
        try writer.interface.flush();
    }
};

const TestHttpBodyServer = struct {
    const Mode = enum {
        content_length,
        chunked,
    };

    io: Io,
    server: std.Io.net.Server,
    thread: std.Thread,
    closed: std.atomic.Value(bool),
    request_count: std.atomic.Value(usize),
    body: []const u8,
    mode: Mode,
    content_length: ?u64,

    fn init(self: *TestHttpBodyServer, io: Io, body: []const u8, mode: Mode, content_length: ?u64) !void {
        var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        self.* = .{
            .io = io,
            .server = try address.listen(io, .{ .kernel_backlog = 8, .reuse_address = true }),
            .thread = undefined,
            .closed = .init(false),
            .request_count = .init(0),
            .body = body,
            .mode = mode,
            .content_length = content_length,
        };
        self.thread = try std.Thread.spawn(.{}, TestHttpBodyServer.serveThread, .{self});
    }

    fn deinit(self: *TestHttpBodyServer) void {
        const wake_address = self.server.socket.address;
        self.closed.store(true, .release);
        if (wake_address.connect(self.io, .{ .mode = .stream })) |stream| {
            stream.close(self.io);
        } else |_| {}
        self.server.deinit(self.io);
        self.thread.join();
    }

    fn url(self: *TestHttpBodyServer, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/body", .{self.server.socket.address.getPort()});
    }

    fn serveThread(self: *TestHttpBodyServer) void {
        while (!self.closed.load(.acquire)) {
            var stream = self.server.accept(self.io) catch {
                if (self.closed.load(.acquire)) return;
                continue;
            };
            self.handle(stream) catch {};
            stream.close(self.io);
        }
    }

    fn handle(self: *TestHttpBodyServer, stream: std.Io.net.Stream) !void {
        _ = self.request_count.fetchAdd(1, .monotonic);
        var read_buffer: [8 * 1024]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        _ = reader.interface.takeDelimiterExclusive('\n') catch return;
        while (true) {
            const header_raw = reader.interface.takeDelimiterExclusive('\n') catch return;
            const header = std.mem.trimEnd(u8, header_raw, "\r");
            if (header.len == 0) break;
        }

        var write_buffer: [8 * 1024]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        switch (self.mode) {
            .content_length => {
                try writer.interface.print(
                    "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
                    .{self.content_length orelse self.body.len},
                );
                try writer.interface.writeAll(self.body);
            },
            .chunked => {
                try writer.interface.writeAll("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n");
                if (self.body.len > 0) {
                    try writer.interface.print("{x}\r\n", .{self.body.len});
                    try writer.interface.writeAll(self.body);
                    try writer.interface.writeAll("\r\n");
                }
                try writer.interface.writeAll("0\r\n\r\n");
            },
        }
        try writer.interface.flush();
    }
};

fn writeFakeAwsScript(allocator: std.mem.Allocator, script_path: [:0]const u8, fake_s3_root: []const u8) !void {
    try writeFakeAwsScriptWithLog(allocator, script_path, fake_s3_root, null);
}

fn writeFakeAwsScriptWithLog(
    allocator: std.mem.Allocator,
    script_path: [:0]const u8,
    fake_s3_root: []const u8,
    log_path: ?[]const u8,
) !void {
    const script = try std.fmt.allocPrint(
        allocator,
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\root="{s}"
        \\log_path="{s}"
        \\if [[ -n "$log_path" ]]; then
        \\  printf '%s\n' "$*" >> "$log_path"
        \\fi
        \\map_path() {{
        \\  case "$1" in
        \\    s3://*) key="$(printf '%s' "$1" | sed 's#^s3://##')"; printf '%s/%s' "$root" "$key" ;;
        \\    *) printf '%s' "$1" ;;
        \\  esac
        \\}}
        \\parse_s3api_args() {{
        \\  bucket=""
        \\  key=""
        \\  range=""
        \\  outfile=""
        \\  while [[ "$#" -gt 0 ]]; do
        \\    case "$1" in
        \\      --bucket) bucket="$2"; shift 2 ;;
        \\      --key) key="$2"; shift 2 ;;
        \\      --range) range="$2"; shift 2 ;;
        \\      --region|--query|--output) shift 2 ;;
        \\      *) outfile="$1"; shift ;;
        \\    esac
        \\  done
        \\  if [[ -z "$bucket" || -z "$key" ]]; then
        \\    echo "missing fake aws bucket/key" >&2
        \\    exit 64
        \\  fi
        \\}}
        \\if [[ "$#" -ge 4 && "$1" == "s3" && "$2" == "cp" ]]; then
        \\  src="$3"
        \\  dst="$4"
        \\  src_path="$(map_path "$src")"
        \\  dst_path="$(map_path "$dst")"
        \\  mkdir -p "$(dirname "$dst_path")"
        \\  cp "$src_path" "$dst_path"
        \\elif [[ "$#" -ge 2 && "$1" == "s3api" && "$2" == "head-object" ]]; then
        \\  shift 2
        \\  parse_s3api_args "$@"
        \\  src_path="$root/$bucket/$key"
        \\  wc -c < "$src_path" | tr -d '[:space:]'
        \\  printf '\n'
        \\elif [[ "$#" -ge 2 && "$1" == "s3api" && "$2" == "get-object" ]]; then
        \\  shift 2
        \\  parse_s3api_args "$@"
        \\  if [[ -z "$outfile" ]]; then
        \\    echo "missing fake aws output path" >&2
        \\    exit 64
        \\  fi
        \\  src_path="$root/$bucket/$key"
        \\  mkdir -p "$(dirname "$outfile")"
        \\  cp "$src_path" "$outfile"
        \\  size="$(wc -c < "$outfile" | tr -d '[:space:]')"
        \\  printf '{{"ContentLength":%s}}\n' "$size"
        \\else
        \\  echo "unsupported fake aws invocation: $*" >&2
        \\  exit 64
        \\fi
        \\
    ,
        .{ fake_s3_root, log_path orelse "" },
    );
    try writeFileAll(script_path, script);
    if (std.c.chmod(script_path, 0o755) != 0) return error.IoFailed;
}

const test_line_levels = [_]gicv3.LineLevel{.{ .intid = 56, .asserted = false }};
var test_rootfs_transport_devices = [_]spore.TransportState{.{
    .device_id = spore.rootfs_virtio_blk_device_id,
    .status = 0,
    .device_features_sel = 0,
    .driver_features_sel = 0,
    .driver_features = 0,
    .queue_sel = 0,
    .interrupt_status = 0,
    .queues = &.{},
}};

fn testManifest(memory: spore.MemoryManifest, ram_size: u64, initial_generation: u64) spore.Manifest {
    return .{
        .platform = .{
            .cpu_profile = "sporevm-aarch64-v0",
            .device_model_version = 4,
            .ram_base = 0x8000_0000,
            .ram_size = ram_size,
            .gic_dist_base = 0x0800_0000,
            .gic_redist_base = 0x0801_0000,
            .counter_frequency_hz = 24_000_000,
        },
        .machine = .{
            .gprs = [_]u64{0} ** 31,
            .pc = 0,
            .cpsr = 0,
            .fpcr = 0,
            .fpsr = 0,
            .simd = [_][2]u64{.{ 0, 0 }} ** 32,
            .sys_regs = &.{},
            .icc_regs = &.{},
            .vtimer = .{ .cntvct = 0, .cntv_ctl = 0, .cntv_cval = 0 },
            .gic = .{
                .kind = .gicv3,
                .gicv3 = .{
                    .dist_regs = &.{},
                    .redist_regs = &.{},
                    .line_levels = &test_line_levels,
                },
            },
        },
        .devices = &.{},
        .generation = .{ .generation = initial_generation, .interrupt_status = 0, .params_b64 = "" },
        .memory = memory,
    };
}

fn testVcpuState(index: topology.VcpuIndex) spore.VcpuState {
    return .{
        .index = index,
        .mpidr = topology.mpidrForIndex(index),
        .gprs = [_]u64{0} ** 31,
        .pc = 0,
        .cpsr = 0,
        .fpcr = 0,
        .fpsr = 0,
        .simd = [_][2]u64{.{ 0, 0 }} ** 32,
        .sys_regs = &.{},
        .icc_regs = &.{},
        .vtimer = .{ .cntvct = 0, .cntv_ctl = 0, .cntv_cval = 0 },
    };
}

fn testManifestV1(memory: spore.MemoryManifest, ram_size: u64, vcpus: []spore.VcpuState) spore.ManifestV1 {
    return .{
        .platform = .{
            .cpu_profile = "sporevm-aarch64-v0",
            .device_model_version = 5,
            .vcpu_count = @intCast(vcpus.len),
            .ram_base = 0x8000_0000,
            .ram_size = ram_size,
            .gic_dist_base = 0x0800_0000,
            .gic_redist_base = 0x0802_0000,
            .gic_redist_stride = 0x2_0000,
            .counter_frequency_hz = 24_000_000,
        },
        .machine = .{
            .vcpus = vcpus,
            .gic = .{
                .kind = .backend_private,
                .backend_private = .{
                    .backend = .hvf,
                    .format = gicv3.hvf_backend_private_format,
                    .data_b64 = "AA==",
                },
            },
        },
        .devices = &.{},
        .generation = .{ .generation = 1, .interrupt_status = 0, .params_b64 = "" },
        .memory = memory,
    };
}

fn testRootfsManifest(memory: spore.MemoryManifest, ram_size: u64, initial_generation: u64, artifact: spore.RootfsArtifactRef) spore.Manifest {
    var manifest = testManifest(memory, ram_size, initial_generation);
    manifest.devices = test_rootfs_transport_devices[0..];
    manifest.rootfs = .{
        .device = .{ .mmio_slot = 0 },
        .artifact = artifact,
        .source = .{
            .requested_ref = "docker.io/library/ruby:3.3-alpine",
            .resolved_image_ref = "docker.io/library/ruby@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            .image_manifest_digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            .platform = "linux/arm64",
            .builder_version = "sporevm-rootfs-v1",
        },
    };
    return manifest;
}

fn attachTestDiskLayer(
    allocator: std.mem.Allocator,
    dir: []const u8,
    manifest: *spore.Manifest,
    rootfs_path: []const u8,
    write_offset: u64,
    payload: []const u8,
) !void {
    const rootfs = manifest.rootfs orelse return error.BadManifest;
    const base_fd = try openTestFile(try pathZ(allocator, "{s}", .{rootfs_path}), .{ .ACCMODE = .RDONLY });
    defer _ = std.c.close(base_fd);
    const overlay_path = try pathZ(allocator, "{s}/disk-overlay.img", .{dir});
    try writeFileAll(overlay_path, "");
    const overlay_fd = try openTestFile(overlay_path, .{ .ACCMODE = .RDWR });
    defer _ = std.c.close(overlay_fd);

    const base_source = block_source.FileBlockSource.init(base_fd, rootfs.artifact.size);
    var cow = try cow_disk.CowDisk.init(allocator, base_source, overlay_fd, rootfs.artifact.size, disk_layer.default_cluster_size);
    defer cow.deinit();
    try cow.writeAt(payload, write_offset);
    try cow.flush();

    const sealed = try disk_layer.sealCowDisk(allocator, dir, &cow);
    const layers = try allocator.alloc([]const u8, 1);
    layers[0] = sealed.layer_ref;
    manifest.disk = .{
        .device = rootfs.device,
        .size = rootfs.artifact.size,
        .base = rootfs.artifact.digest,
        .layers = layers,
    };
}

fn openTestFile(path: [:0]const u8, mode: std.c.O) Error!std.c.fd_t {
    const fd = std.c.open(path, mode, @as(c_uint, 0o644));
    if (fd < 0) return error.IoFailed;
    return fd;
}

fn fuzzIndexParse(_: void, s: *std.testing.Smith) !void {
    // Bundle indexes are distribution metadata from disk/peers/registries. They
    // must either fail to parse or validate to canonical, path-safe chunkpack
    // entries.
    var buf: [4096]u8 = undefined;
    const len = s.slice(&buf);
    const parsed = std.json.parseFromSlice(Index, std.testing.allocator, buf[0..len], .{
        .allocate = .alloc_always,
    }) catch return;
    defer parsed.deinit();
    validateIndex(std.testing.allocator, parsed.value) catch return;
}

test "fuzz bundle index parsing" {
    try std.testing.fuzz({}, fuzzIndexParse, .{});
}

fn fuzzDistributionBundleIndexParse(_: void, s: *std.testing.Smith) !void {
    // bundle.json is attacker-influenced distribution metadata. It must only
    // validate when every referenced relative path is canonical and child ids
    // are sorted, unique, fixed-width decimal ids.
    var buf: [4096]u8 = undefined;
    const len = s.slice(&buf);
    const parsed = std.json.parseFromSlice(BundleIndex, std.testing.allocator, buf[0..len], .{
        .allocate = .alloc_always,
    }) catch return;
    defer parsed.deinit();
    validateBundleIndex(std.testing.allocator, parsed.value) catch return;
}

test "fuzz distribution bundle index parsing" {
    try std.testing.fuzz({}, fuzzDistributionBundleIndexParse, .{});
}

fn fuzzRootfsIndexParse(_: void, s: *std.testing.Smith) !void {
    // rootfs.index.json is attacker-influenced distribution metadata. It must
    // either reject the input or validate to digest-addressed rootfs entries
    // with explicit artifact policy.
    var buf: [4096]u8 = undefined;
    const len = s.slice(&buf);
    const parsed = std.json.parseFromSlice(RootfsIndex, std.testing.allocator, buf[0..len], .{
        .allocate = .alloc_always,
    }) catch return;
    defer parsed.deinit();
    validateRootfsIndex(std.testing.allocator, parsed.value) catch return;
}

test "fuzz rootfs index parsing" {
    try std.testing.fuzz({}, fuzzRootfsIndexParse, .{});
}

fn fuzzHttpSourceParse(_: void, s: *std.testing.Smith) !void {
    // HTTP peer pull sources are attacker-influenced URI strings. They must
    // either fail closed or parse to a digest-pinned, path-safe base URL.
    var buf: [1024]u8 = undefined;
    const len = s.slice(&buf);
    const parsed = parseHttpSource(std.testing.allocator, buf[0..len]) catch return;
    defer std.testing.allocator.free(parsed.location.base_url);
    defer std.testing.allocator.free(parsed.expected_digest);
    try validateSha256DigestHex(parsed.expected_digest);
    const uri = std.Uri.parse(parsed.location.base_url) catch return error.BadManifest;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.BadManifest;
    if (uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.BadManifest;
    const path = uriComponentText(uri.path);
    if (path.len > 0) {
        if (path[0] != '/') return error.BadManifest;
        if (path.len > 1) try validateRelativeSegments(path[1..]);
    }
}

test "fuzz http pull source parsing" {
    try std.testing.fuzz({}, fuzzHttpSourceParse, .{});
}

test "pack and unpack chunkpack bundle strips local backing" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const out_dir = try pathZ(arena, "{s}/unpacked", .{root_dir});

    const ram = try arena.alloc(u8, 2 * spore.chunk_size + 17);
    @memset(ram, 0);
    ram[9] = 0xA1;
    ram[2 * spore.chunk_size + 3] = 0xB2;
    const memory = try spore.saveMemoryWithBacking(arena, parent_dir, ram);
    try spore.saveManifest(arena, parent_dir, testManifest(memory, ram.len, 7));

    const pack_result = try pack(arena, .{ .io = std.testing.io, .spore_dir = parent_dir, .out_dir = bundle_dir });
    try std.testing.expectEqual(@as(usize, 3), pack_result.chunk_count);
    try std.testing.expectEqual(@as(usize, 2), pack_result.packed_chunk_count);
    try std.testing.expectEqual(@as(usize, 1), pack_result.pack_count);
    try std.testing.expectEqual(@as(u64, spore.chunk_size + 17), pack_result.payload_bytes);
    try std.testing.expectEqual(@as(usize, Sha256.digest_length * 2), pack_result.bundle_digest.len);

    const bundle_manifest = try spore.loadManifest(arena, bundle_dir);
    defer bundle_manifest.deinit();
    try std.testing.expect(bundle_manifest.value.memory.backing == null);
    const backing_path = try pathZ(arena, "{s}/{s}", .{ bundle_dir, spore.ram_backing_path });
    try std.testing.expect(std.c.access(backing_path, 0) != 0);

    const index = try loadIndex(arena, bundle_dir);
    defer index.deinit();
    try std.testing.expectEqual(@as(u32, index_version), index.value.version);
    try std.testing.expectEqual(@as(usize, 2), index.value.chunks.len);
    try std.testing.expectEqualStrings(pack_path, index.value.chunks[0].pack);
    try std.testing.expectEqual(@as(u64, 0), index.value.chunks[0].offset);
    try std.testing.expectEqual(@as(u64, spore.chunk_size), index.value.chunks[0].size);
    try std.testing.expectEqual(@as(u64, spore.chunk_size), index.value.chunks[1].offset);
    try std.testing.expectEqual(@as(u64, 17), index.value.chunks[1].size);

    const unpacked = try unpack(arena, .{ .io = std.testing.io, .bundle_dir = bundle_dir, .out_dir = out_dir });
    try std.testing.expectEqual(@as(usize, 3), unpacked.chunk_count);
    try std.testing.expectEqual(@as(usize, 2), unpacked.unpacked_chunk_count);
    try std.testing.expectEqual(@as(u64, spore.chunk_size + 17), unpacked.payload_bytes);
    try std.testing.expectEqualStrings(pack_result.bundle_digest, unpacked.bundle_digest);

    const restored_manifest = try spore.loadManifest(arena, out_dir);
    defer restored_manifest.deinit();
    try std.testing.expect(restored_manifest.value.memory.backing == null);
    const out = try arena.alloc(u8, ram.len);
    @memset(out, 0xCC);
    try spore.loadMemory(arena, out_dir, restored_manifest.value.memory, out);
    try std.testing.expectEqualSlices(u8, ram, out);
}

test "pack and unpack preserves manifest v1" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const out_dir = try pathZ(arena, "{s}/unpacked", .{root_dir});
    const missing_out_dir = try pathZ(arena, "{s}/missing", .{root_dir});

    const ram = try arena.alloc(u8, spore.chunk_size + 11);
    @memset(ram, 0);
    ram[0] = 0x41;
    ram[ram.len - 1] = 0x42;
    const memory = try spore.saveMemoryWithBacking(arena, parent_dir, ram);
    var vcpus = [_]spore.VcpuState{ testVcpuState(0), testVcpuState(1) };
    try spore.saveManifestV1(arena, parent_dir, testManifestV1(memory, ram.len, &vcpus));

    _ = try pack(arena, .{ .io = io, .spore_dir = parent_dir, .out_dir = bundle_dir });
    try std.testing.expectError(error.BadManifest, spore.loadManifest(arena, bundle_dir));
    const bundle_manifest = try spore.loadManifestV1(arena, bundle_dir);
    defer bundle_manifest.deinit();
    try std.testing.expectEqual(@as(topology.VcpuCount, 2), bundle_manifest.value.platform.vcpu_count);
    try std.testing.expect(bundle_manifest.value.memory.backing == null);
    try std.testing.expectEqual(gicv3.StateKind.backend_private, bundle_manifest.value.machine.gic.kind);

    _ = try unpack(arena, .{ .io = io, .bundle_dir = bundle_dir, .out_dir = out_dir });
    const restored_manifest = try spore.loadManifestV1(arena, out_dir);
    defer restored_manifest.deinit();
    try std.testing.expectEqual(@as(topology.VcpuCount, 2), restored_manifest.value.platform.vcpu_count);
    try std.testing.expect(restored_manifest.value.memory.backing == null);
    const out = try arena.alloc(u8, ram.len);
    @memset(out, 0xCC);
    try spore.loadMemory(arena, out_dir, restored_manifest.value.memory, out);
    try std.testing.expectEqualSlices(u8, ram, out);

    try Io.Dir.cwd().deleteFile(io, try pathZ(arena, "{s}/{s}", .{ bundle_dir, pack_path }));
    try std.testing.expectError(error.IoFailed, unpack(arena, .{ .io = io, .bundle_dir = bundle_dir, .out_dir = missing_out_dir }));
}

test "indexed bundle pull preserves manifest v1" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const children_dir = try pathZ(arena, "{s}/children", .{root_dir});
    const child_dir = try pathZ(arena, "{s}/000000", .{children_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const out_dir = try pathZ(arena, "{s}/pulled", .{root_dir});
    const source_uri = try std.fmt.allocPrint(arena, "file://{s}", .{bundle_dir});

    const ram = try arena.alloc(u8, spore.chunk_size + 3);
    @memset(ram, 0);
    ram[2] = 0x51;
    ram[ram.len - 1] = 0x52;
    var vcpus = [_]spore.VcpuState{ testVcpuState(0), testVcpuState(1) };
    try spore.saveManifestV1(arena, parent_dir, testManifestV1(try spore.saveMemory(arena, parent_dir, ram), ram.len, &vcpus));
    try ensureDirPath(io, children_dir);
    try spore.saveManifestV1(arena, child_dir, testManifestV1(try spore.saveMemory(arena, child_dir, ram), ram.len, &vcpus));

    const pack_result = try pack(arena, .{ .io = io, .spore_dir = parent_dir, .out_dir = bundle_dir, .children_dir = children_dir });
    const pulled = try pull(arena, .{ .io = io, .source = source_uri, .out_dir = out_dir, .child_id = "0" });
    try std.testing.expectEqualStrings(pack_result.bundle_digest, pulled.bundle_digest.hex);
    try std.testing.expectEqualStrings("000000", pulled.children.selected_child.?);

    const restored_manifest = try spore.loadManifestV1(arena, out_dir);
    defer restored_manifest.deinit();
    try std.testing.expectEqual(@as(topology.VcpuCount, 2), restored_manifest.value.platform.vcpu_count);
    const out = try arena.alloc(u8, ram.len);
    @memset(out, 0xCC);
    try spore.loadMemory(arena, out_dir, restored_manifest.value.memory, out);
    try std.testing.expectEqualSlices(u8, ram, out);
}

test "unpack rejects corrupted chunkpack payload" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const out_dir = try pathZ(arena, "{s}/unpacked", .{root_dir});

    const ram = try arena.alloc(u8, spore.chunk_size);
    @memset(ram, 0x5D);
    const memory = try spore.saveMemory(arena, parent_dir, ram);
    try spore.saveManifest(arena, parent_dir, testManifest(memory, ram.len, 3));
    _ = try pack(arena, .{ .io = std.testing.io, .spore_dir = parent_dir, .out_dir = bundle_dir });
    const clean_digest = try digestHex(arena, bundle_dir);

    const source_pack_path = try pathZ(arena, "{s}/{s}", .{ bundle_dir, pack_path });
    const data = try readFileAll(arena, source_pack_path, spore.chunk_size);
    data[100] ^= 0xFF;
    try writeFileAll(source_pack_path, data);
    const corrupt_digest = try digestHex(arena, bundle_dir);
    try std.testing.expect(!std.mem.eql(u8, clean_digest, corrupt_digest));

    try std.testing.expectError(error.BadChunk, unpack(arena, .{ .io = std.testing.io, .bundle_dir = bundle_dir, .out_dir = out_dir }));
}

test "pack and unpack rootfs artifact in existing bundle shape" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const out_dir = try pathZ(arena, "{s}/unpacked", .{root_dir});
    const pack_cache_root = try pathZ(arena, "{s}/pack-cache", .{root_dir});
    const unpack_cache_root = try pathZ(arena, "{s}/unpack-cache", .{root_dir});
    const rootfs_source_path = try pathZ(arena, "{s}/rootfs-source.ext4", .{root_dir});

    const ram = try arena.alloc(u8, spore.chunk_size);
    @memset(ram, 0);
    ram[77] = 0xC7;
    const memory = try spore.saveMemory(arena, parent_dir, ram);
    try writeFileAll(rootfs_source_path, "rootfs bytes for distribution");
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, pack_cache_root, rootfs_source_path);
    try spore.saveManifest(arena, parent_dir, testRootfsManifest(memory, ram.len, 11, artifact));

    const pack_result = try pack(arena, .{
        .io = io,
        .spore_dir = parent_dir,
        .out_dir = bundle_dir,
        .rootfs_cache_dir = pack_cache_root,
    });
    try std.testing.expectEqual(@as(usize, 1), pack_result.rootfs_artifact_count);
    try std.testing.expectEqual(artifact.size, pack_result.rootfs_payload_bytes);

    const rel_path = try rootfsArtifactRelPath(arena, artifact);
    const bundle_rootfs_path = try pathZ(arena, "{s}/{s}", .{ bundle_dir, rel_path });
    const bundled_rootfs = try readFileAll(arena, bundle_rootfs_path, 4096);
    try std.testing.expectEqualSlices(u8, "rootfs bytes for distribution", bundled_rootfs);

    const unpacked = try unpack(arena, .{
        .io = io,
        .bundle_dir = bundle_dir,
        .out_dir = out_dir,
        .rootfs_cache_dir = unpack_cache_root,
    });
    try std.testing.expectEqual(@as(usize, 1), unpacked.rootfs_artifact_count);
    try std.testing.expectEqual(artifact.size, unpacked.rootfs_payload_bytes);
    try std.testing.expectEqualStrings(pack_result.bundle_digest, unpacked.bundle_digest);

    const restored_manifest = try spore.loadManifest(arena, out_dir);
    defer restored_manifest.deinit();
    const restored_rootfs = restored_manifest.value.rootfs orelse return error.BadManifest;
    try std.testing.expectEqualStrings(artifact.digest, restored_rootfs.artifact.digest);
    try std.testing.expectEqual(artifact.size, restored_rootfs.artifact.size);

    const fd = try rootfs_cache.openVerifiedFromCache(io, arena, unpack_cache_root, restored_rootfs);
    _ = std.c.close(fd);
}

test "bundle digest covers rootfs artifact bytes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const pack_cache_root = try pathZ(arena, "{s}/pack-cache", .{root_dir});
    const rootfs_source_path = try pathZ(arena, "{s}/rootfs-source.ext4", .{root_dir});

    const ram = try arena.alloc(u8, 4096);
    @memset(ram, 0x41);
    const memory = try spore.saveMemory(arena, parent_dir, ram);
    try writeFileAll(rootfs_source_path, "rootfs digest bytes");
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, pack_cache_root, rootfs_source_path);
    try spore.saveManifest(arena, parent_dir, testRootfsManifest(memory, ram.len, 12, artifact));

    const pack_result = try pack(arena, .{
        .io = io,
        .spore_dir = parent_dir,
        .out_dir = bundle_dir,
        .rootfs_cache_dir = pack_cache_root,
    });
    const clean_digest = pack_result.bundle_digest;

    const rel_path = try rootfsArtifactRelPath(arena, artifact);
    const bundle_rootfs_path = try pathZ(arena, "{s}/{s}", .{ bundle_dir, rel_path });
    const data = try readFileAll(arena, bundle_rootfs_path, 4096);
    data[0] ^= 0xFF;
    try Io.Dir.cwd().deleteFile(io, bundle_rootfs_path);
    try writeFileAll(bundle_rootfs_path, data);
    const corrupt_digest = try digestHex(arena, bundle_dir);
    try std.testing.expect(!std.mem.eql(u8, clean_digest, corrupt_digest));
}

test "pack and unpack disk layers in existing bundle shape" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const out_dir = try pathZ(arena, "{s}/unpacked", .{root_dir});
    const out_bad_dir = try pathZ(arena, "{s}/unpacked-bad", .{root_dir});
    const pack_cache_root = try pathZ(arena, "{s}/pack-cache", .{root_dir});
    const unpack_cache_root = try pathZ(arena, "{s}/unpack-cache", .{root_dir});
    const rootfs_source_path = try pathZ(arena, "{s}/rootfs-source.ext4", .{root_dir});

    const ram = try arena.alloc(u8, 4096);
    @memset(ram, 0x31);
    const memory = try spore.saveMemory(arena, parent_dir, ram);
    const base_bytes = try arena.alloc(u8, 8192);
    @memset(base_bytes, 0);
    base_bytes[0] = 0x11;
    base_bytes[4096] = 0x22;
    try writeFileAll(rootfs_source_path, base_bytes);
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, pack_cache_root, rootfs_source_path);
    var manifest = testRootfsManifest(memory, ram.len, 17, artifact);
    try attachTestDiskLayer(arena, parent_dir, &manifest, rootfs_source_path, 4096, "disk bundle payload");
    try spore.saveManifest(arena, parent_dir, manifest);

    const pack_result = try pack(arena, .{
        .io = io,
        .spore_dir = parent_dir,
        .out_dir = bundle_dir,
        .rootfs_cache_dir = pack_cache_root,
    });

    const disk = manifest.disk orelse return error.BadManifest;
    const layer_rel = try diskLayerRelPath(arena, disk.layers[0]);
    try std.testing.expectEqual(@as(c_int, 0), std.c.access(try pathZ(arena, "{s}/{s}", .{ bundle_dir, layer_rel }), 0));
    const parsed_layer = try disk_layer.loadLayer(arena, bundle_dir, disk.layers[0]);
    defer parsed_layer.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_layer.value.extents.len);
    const object_rel = try diskObjectRelPath(arena, parsed_layer.value.extents[0].digest);
    const object_path = try pathZ(arena, "{s}/{s}", .{ bundle_dir, object_rel });
    try std.testing.expectEqual(@as(c_int, 0), std.c.access(object_path, 0));

    const unpacked = try unpack(arena, .{
        .io = io,
        .bundle_dir = bundle_dir,
        .out_dir = out_dir,
        .rootfs_cache_dir = unpack_cache_root,
    });
    try std.testing.expectEqualStrings(pack_result.bundle_digest, unpacked.bundle_digest);
    const restored_manifest = try spore.loadManifest(arena, out_dir);
    defer restored_manifest.deinit();
    _ = try disk_layer.loadLayerChain(arena, out_dir, restored_manifest.value.disk orelse return error.BadManifest);

    const clean_digest = pack_result.bundle_digest;
    const data = try readFileAll(arena, object_path, 8192);
    data[0] ^= 0xFF;
    try Io.Dir.cwd().deleteFile(io, object_path);
    try writeFileAll(object_path, data);
    const corrupt_digest = try digestHex(arena, bundle_dir);
    try std.testing.expect(!std.mem.eql(u8, clean_digest, corrupt_digest));
    try std.testing.expectError(error.BadChunk, unpack(arena, .{
        .io = io,
        .bundle_dir = bundle_dir,
        .out_dir = out_bad_dir,
        .rootfs_cache_dir = unpack_cache_root,
    }));
    try std.testing.expect(std.c.access(try pathZ(arena, "{s}/manifest.json", .{out_bad_dir}), 0) != 0);
}

test "unpack rejects corrupted rootfs artifact" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const out_dir = try pathZ(arena, "{s}/unpacked", .{root_dir});
    const pack_cache_root = try pathZ(arena, "{s}/pack-cache", .{root_dir});
    const unpack_cache_root = try pathZ(arena, "{s}/unpack-cache", .{root_dir});
    const rootfs_source_path = try pathZ(arena, "{s}/rootfs-source.ext4", .{root_dir});

    const ram = try arena.alloc(u8, 4096);
    @memset(ram, 0x7A);
    const memory = try spore.saveMemory(arena, parent_dir, ram);
    try writeFileAll(rootfs_source_path, "rootfs clean bytes");
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, pack_cache_root, rootfs_source_path);
    try spore.saveManifest(arena, parent_dir, testRootfsManifest(memory, ram.len, 13, artifact));
    _ = try pack(arena, .{
        .io = io,
        .spore_dir = parent_dir,
        .out_dir = bundle_dir,
        .rootfs_cache_dir = pack_cache_root,
    });

    const rel_path = try rootfsArtifactRelPath(arena, artifact);
    const bundle_rootfs_path = try pathZ(arena, "{s}/{s}", .{ bundle_dir, rel_path });
    try Io.Dir.cwd().deleteFile(io, bundle_rootfs_path);
    try writeFileAll(bundle_rootfs_path, "tampered rootfs bytes");
    try std.testing.expectError(error.BadChunk, unpack(arena, .{
        .io = io,
        .bundle_dir = bundle_dir,
        .out_dir = out_dir,
        .rootfs_cache_dir = unpack_cache_root,
    }));
    const cache_path = try rootfs_cache.digestPath(arena, unpack_cache_root, artifact.digest);
    try std.testing.expect(!try rootfs_cache.pathExistsNoSymlink(io, cache_path));
}

test "unpack requires bundled rootfs artifact even when destination cache is warm" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const out_dir = try pathZ(arena, "{s}/unpacked", .{root_dir});
    const pack_cache_root = try pathZ(arena, "{s}/pack-cache", .{root_dir});
    const unpack_cache_root = try pathZ(arena, "{s}/unpack-cache", .{root_dir});
    const rootfs_source_path = try pathZ(arena, "{s}/rootfs-source.ext4", .{root_dir});

    const ram = try arena.alloc(u8, 4096);
    @memset(ram, 0x21);
    const memory = try spore.saveMemory(arena, parent_dir, ram);
    try writeFileAll(rootfs_source_path, "rootfs cache warm bytes");
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, pack_cache_root, rootfs_source_path);
    try rootfs_cache.installExpectedPath(io, arena, unpack_cache_root, rootfs_source_path, artifact, .{});
    try spore.saveManifest(arena, parent_dir, testRootfsManifest(memory, ram.len, 15, artifact));
    _ = try pack(arena, .{
        .io = io,
        .spore_dir = parent_dir,
        .out_dir = bundle_dir,
        .rootfs_cache_dir = pack_cache_root,
    });

    const rel_path = try rootfsArtifactRelPath(arena, artifact);
    const bundle_rootfs_path = try pathZ(arena, "{s}/{s}", .{ bundle_dir, rel_path });
    try Io.Dir.cwd().deleteFile(io, bundle_rootfs_path);
    try std.testing.expectError(error.BadChunk, unpack(arena, .{
        .io = io,
        .bundle_dir = bundle_dir,
        .out_dir = out_dir,
        .rootfs_cache_dir = unpack_cache_root,
    }));
}

test "unpack rejects symlinked rootfs artifact" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const out_dir = try pathZ(arena, "{s}/unpacked", .{root_dir});
    const pack_cache_root = try pathZ(arena, "{s}/pack-cache", .{root_dir});
    const unpack_cache_root = try pathZ(arena, "{s}/unpack-cache", .{root_dir});
    const rootfs_source_path = try pathZ(arena, "{s}/rootfs-source.ext4", .{root_dir});

    const ram = try arena.alloc(u8, 4096);
    @memset(ram, 0x22);
    const memory = try spore.saveMemory(arena, parent_dir, ram);
    try writeFileAll(rootfs_source_path, "rootfs symlink bytes");
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, pack_cache_root, rootfs_source_path);
    try spore.saveManifest(arena, parent_dir, testRootfsManifest(memory, ram.len, 16, artifact));
    _ = try pack(arena, .{
        .io = io,
        .spore_dir = parent_dir,
        .out_dir = bundle_dir,
        .rootfs_cache_dir = pack_cache_root,
    });

    const rel_path = try rootfsArtifactRelPath(arena, artifact);
    const bundle_rootfs_path = try pathZ(arena, "{s}/{s}", .{ bundle_dir, rel_path });
    const cache_rootfs_path = try rootfs_cache.digestPath(arena, pack_cache_root, artifact.digest);
    try Io.Dir.cwd().deleteFile(io, bundle_rootfs_path);
    const bundle_rootfs_z = try arena.dupeZ(u8, bundle_rootfs_path);
    const cache_rootfs_z = try arena.dupeZ(u8, cache_rootfs_path);
    if (std.c.symlink(cache_rootfs_z, bundle_rootfs_z) != 0) return error.SkipZigTest;

    try std.testing.expectError(error.BadChunk, unpack(arena, .{
        .io = io,
        .bundle_dir = bundle_dir,
        .out_dir = out_dir,
        .rootfs_cache_dir = unpack_cache_root,
    }));
}

test "pack children writes bundle index and unpacks selected child" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const children_dir = try pathZ(arena, "{s}/children", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const out_dir = try pathZ(arena, "{s}/unpacked-child", .{root_dir});

    const ram = try arena.alloc(u8, spore.chunk_size + 8);
    @memset(ram, 0);
    ram[1] = 0x19;
    ram[spore.chunk_size + 2] = 0x91;
    const memory = try spore.saveMemory(arena, parent_dir, ram);
    try spore.saveManifest(arena, parent_dir, testManifest(memory, ram.len, 41));
    _ = try spore.fork(arena, .{ .parent_dir = parent_dir, .out_dir = children_dir, .count = 2 });

    const pack_result = try pack(arena, .{
        .io = io,
        .spore_dir = parent_dir,
        .out_dir = bundle_dir,
        .children_dir = children_dir,
    });
    try std.testing.expectEqual(@as(usize, 2), pack_result.child_count);
    try std.testing.expectEqual(@as(usize, 2), pack_result.packed_chunk_count);

    const bundle_index = try loadBundleIndex(arena, bundle_dir);
    defer bundle_index.deinit();
    try std.testing.expectEqual(@as(usize, 2), bundle_index.value.children.len);
    try std.testing.expectEqualStrings(parent_manifest_path, bundle_index.value.parent_manifest);
    try std.testing.expectEqualStrings("000001", bundle_index.value.children[1].id);
    try std.testing.expect(bundle_index.value.rootfs_index == null);

    const inspected = try inspectBundle(arena, .{ .source = bundle_dir });
    try std.testing.expectEqualStrings(inspect_bundle_schema, inspected.schema);
    try std.testing.expectEqual(bundle_schema_version, inspected.schema_version);
    try std.testing.expect(inspected.indexed);
    try std.testing.expectEqualStrings(pack_result.bundle_digest, inspected.bundle_digest.hex);
    try std.testing.expectEqualStrings(parent_manifest_path, inspected.parent_manifest);
    try std.testing.expectEqual(@as(usize, 2), inspected.child_count);
    try std.testing.expectEqual(@as(usize, 2), inspected.children.len);
    try std.testing.expectEqual(@as(usize, 2), inspected.chunkpack.chunk_count);
    try std.testing.expectEqual(@as(usize, 1), inspected.chunkpack.pack_count);
    try std.testing.expectEqualStrings("none", inspected.selection.kind);
    try std.testing.expectEqual(@as(usize, 0), inspected.selection.selected_count);

    const selected = try inspectBundle(arena, .{ .source = bundle_dir, .child_id = "1" });
    try std.testing.expectEqualStrings("child", selected.selection.kind);
    try std.testing.expectEqual(@as(usize, 1), selected.selection.selected_count);
    try std.testing.expectEqualStrings("000001", selected.selection.children[0].id);

    const ranged = try inspectBundle(arena, .{ .source = bundle_dir, .child_range = .{ .start = 0, .end = 1 } });
    try std.testing.expectEqualStrings("child_range", ranged.selection.kind);
    try std.testing.expectEqual(@as(usize, 2), ranged.selection.selected_count);
    try std.testing.expectEqualStrings("000000", ranged.selection.children[0].id);
    try std.testing.expectEqualStrings("000001", ranged.selection.children[1].id);
    try std.testing.expectError(error.BadManifest, inspectBundle(arena, .{ .source = bundle_dir, .child_id = "missing" }));

    const unpacked = try unpack(arena, .{
        .io = io,
        .bundle_dir = bundle_dir,
        .out_dir = out_dir,
        .child_id = "000001",
    });
    try std.testing.expectEqual(@as(usize, 2), unpacked.child_count);
    try std.testing.expectEqualStrings("000001", unpacked.selected_child.?);
    try std.testing.expectEqualStrings(pack_result.bundle_digest, unpacked.bundle_digest);

    const restored_manifest = try spore.loadManifest(arena, out_dir);
    defer restored_manifest.deinit();
    try std.testing.expectEqual(@as(u64, 43), restored_manifest.value.generation.generation);
    const out = try arena.alloc(u8, ram.len);
    @memset(out, 0xCC);
    try spore.loadMemory(arena, out_dir, restored_manifest.value.memory, out);
    try std.testing.expectEqualSlices(u8, ram, out);
}

test "pull file bundle materializes children through chunk cache" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const children_dir = try pathZ(arena, "{s}/children", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const out0_dir = try pathZ(arena, "{s}/pulled-0", .{root_dir});
    const out1_dir = try pathZ(arena, "{s}/pulled-1", .{root_dir});
    const chunk_cache_dir = try pathZ(arena, "{s}/chunk-cache", .{root_dir});
    const pack_cache_root = try pathZ(arena, "{s}/pack-rootfs-cache", .{root_dir});
    const pull_rootfs_cache = try pathZ(arena, "{s}/pull-rootfs-cache", .{root_dir});
    const rootfs_source_path = try pathZ(arena, "{s}/rootfs-source.ext4", .{root_dir});
    const source_uri = try std.fmt.allocPrint(arena, "file://{s}", .{bundle_dir});

    const ram = try arena.alloc(u8, spore.chunk_size + 11);
    @memset(ram, 0);
    ram[7] = 0x53;
    ram[spore.chunk_size + 3] = 0xA7;
    const memory = try spore.saveMemory(arena, parent_dir, ram);
    try writeFileAll(rootfs_source_path, "pull rootfs artifact bytes");
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, pack_cache_root, rootfs_source_path);
    try spore.saveManifest(arena, parent_dir, testRootfsManifest(memory, ram.len, 71, artifact));
    _ = try spore.fork(arena, .{ .parent_dir = parent_dir, .out_dir = children_dir, .count = 2 });

    const pack_result = try pack(arena, .{
        .io = io,
        .spore_dir = parent_dir,
        .out_dir = bundle_dir,
        .rootfs_cache_dir = pack_cache_root,
        .children_dir = children_dir,
    });

    const pulled0 = try pull(arena, .{
        .io = io,
        .source = source_uri,
        .out_dir = out0_dir,
        .rootfs_cache_dir = pull_rootfs_cache,
        .bundle_cache_dir = chunk_cache_dir,
        .child_id = "0",
    });
    try std.testing.expectEqualStrings(pack_result.bundle_digest, pulled0.bundle_digest.hex);
    try std.testing.expectEqualStrings("000000", pulled0.children.selected_child.?);
    try std.testing.expectEqual(@as(usize, 2), pulled0.materialization.materialized_chunk_count);
    try std.testing.expectEqual(@as(usize, 0), pulled0.materialization.cache.hit_count);
    try std.testing.expectEqual(@as(usize, 2), pulled0.materialization.cache.miss_count);
    try std.testing.expectEqual(@as(u64, @intCast(ram.len)), pulled0.materialization.cache.bytes_fetched);
    try std.testing.expectEqual(@as(usize, 2), pulled0.materialization.linked_chunk_count);
    try std.testing.expectEqual(@as(usize, 0), pulled0.rootfs.cache.hit_count);
    try std.testing.expectEqual(@as(usize, 1), pulled0.rootfs.cache.miss_count);
    try std.testing.expectEqual(artifact.size, pulled0.rootfs.cache.bytes_fetched);

    const pulled1 = try pull(arena, .{
        .io = io,
        .source = source_uri,
        .out_dir = out1_dir,
        .rootfs_cache_dir = pull_rootfs_cache,
        .bundle_cache_dir = chunk_cache_dir,
        .child_id = "1",
    });
    try std.testing.expectEqualStrings("000001", pulled1.children.selected_child.?);
    try std.testing.expectEqual(@as(usize, 2), pulled1.materialization.materialized_chunk_count);
    try std.testing.expectEqual(@as(usize, 2), pulled1.materialization.cache.hit_count);
    try std.testing.expectEqual(@as(usize, 0), pulled1.materialization.cache.miss_count);
    try std.testing.expectEqual(@as(u64, 0), pulled1.materialization.cache.bytes_fetched);
    try std.testing.expectEqual(@as(usize, 2), pulled1.materialization.linked_chunk_count);
    try std.testing.expectEqual(@as(usize, 1), pulled1.rootfs.cache.hit_count);
    try std.testing.expectEqual(@as(usize, 0), pulled1.rootfs.cache.miss_count);
    try std.testing.expectEqual(@as(u64, 0), pulled1.rootfs.cache.bytes_fetched);

    const restored_manifest = try spore.loadManifest(arena, out1_dir);
    defer restored_manifest.deinit();
    const restored_rootfs = restored_manifest.value.rootfs orelse return error.BadManifest;
    const fd = try rootfs_cache.openVerifiedFromCache(io, arena, pull_rootfs_cache, restored_rootfs);
    _ = std.c.close(fd);
    const out = try arena.alloc(u8, ram.len);
    @memset(out, 0xCC);
    try spore.loadMemory(arena, out1_dir, restored_manifest.value.memory, out);
    try std.testing.expectEqualSlices(u8, ram, out);
}

test "push and pull s3 indexed bundle through verified remote cache" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const children_dir = try pathZ(arena, "{s}/children", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const out0_dir = try pathZ(arena, "{s}/s3-pulled-0", .{root_dir});
    const out1_dir = try pathZ(arena, "{s}/s3-pulled-1", .{root_dir});
    const out_bad_dir = try pathZ(arena, "{s}/s3-pulled-bad", .{root_dir});
    const pack_cache_root = try pathZ(arena, "{s}/pack-rootfs-cache", .{root_dir});
    const pull_rootfs_cache = try pathZ(arena, "{s}/pull-rootfs-cache", .{root_dir});
    const remote_cache_dir = try pathZ(arena, "{s}/remote-cache", .{root_dir});
    const bad_remote_cache_dir = try pathZ(arena, "{s}/bad-remote-cache", .{root_dir});
    const rootfs_source_path = try pathZ(arena, "{s}/rootfs-source.ext4", .{root_dir});
    const fake_s3_root = try pathZ(arena, "{s}/fake-s3", .{root_dir});
    const fake_aws = try pathZ(arena, "{s}/fake-aws", .{root_dir});
    try ensureDirPath(io, fake_s3_root);
    try writeFakeAwsScript(arena, fake_aws, fake_s3_root);

    const ram = try arena.alloc(u8, spore.chunk_size + 19);
    @memset(ram, 0);
    ram[11] = 0x74;
    ram[spore.chunk_size + 9] = 0x45;
    const memory = try spore.saveMemory(arena, parent_dir, ram);
    try writeFileAll(rootfs_source_path, "s3 pull rootfs artifact bytes");
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, pack_cache_root, rootfs_source_path);
    try spore.saveManifest(arena, parent_dir, testRootfsManifest(memory, ram.len, 101, artifact));
    _ = try spore.fork(arena, .{ .parent_dir = parent_dir, .out_dir = children_dir, .count = 2 });

    const pack_result = try pack(arena, .{
        .io = io,
        .spore_dir = parent_dir,
        .out_dir = bundle_dir,
        .rootfs_cache_dir = pack_cache_root,
        .children_dir = children_dir,
    });

    const push_result = try push(arena, .{
        .io = io,
        .bundle_dir = bundle_dir,
        .destination = "s3://bucket/runs/demo.bundle/",
        .aws_region = "ap-southeast-2",
        .aws_executable = fake_aws,
    });
    try std.testing.expectEqualStrings(pack_result.bundle_digest, push_result.bundle_digest);
    try std.testing.expectEqual(@as(usize, 8), push_result.uploaded_file_count);
    try std.testing.expect(push_result.uploaded_bytes > 0);

    const source_uri = try std.fmt.allocPrint(arena, "s3://bucket/runs/demo.bundle@sha256:{s}", .{push_result.bundle_digest});
    const pulled0 = try pull(arena, .{
        .io = io,
        .source = source_uri,
        .out_dir = out0_dir,
        .rootfs_cache_dir = pull_rootfs_cache,
        .bundle_cache_dir = remote_cache_dir,
        .child_id = "0",
        .aws_region = "ap-southeast-2",
        .aws_executable = fake_aws,
    });
    try std.testing.expectEqualStrings("000000", pulled0.children.selected_child.?);
    try std.testing.expectEqualStrings(push_result.bundle_digest, pulled0.bundle_digest.hex);
    try std.testing.expect(!pulled0.remote.cache_hit);
    try std.testing.expectEqual(push_result.uploaded_bytes, pulled0.remote.origin_bytes_read);
    try std.testing.expectEqual(@as(usize, 2), pulled0.materialization.cache.miss_count);
    try std.testing.expectEqual(@as(u64, @intCast(ram.len)), pulled0.materialization.cache.bytes_fetched);
    try std.testing.expectEqual(@as(usize, 0), pulled0.rootfs.cache.hit_count);
    try std.testing.expectEqual(@as(usize, 1), pulled0.rootfs.cache.miss_count);
    try std.testing.expectEqual(artifact.size, pulled0.rootfs.cache.bytes_fetched);

    const pulled1 = try pull(arena, .{
        .io = io,
        .source = source_uri,
        .out_dir = out1_dir,
        .rootfs_cache_dir = pull_rootfs_cache,
        .bundle_cache_dir = remote_cache_dir,
        .child_id = "1",
        .aws_region = "ap-southeast-2",
        .aws_executable = fake_aws,
    });
    try std.testing.expectEqualStrings("000001", pulled1.children.selected_child.?);
    try std.testing.expect(pulled1.remote.cache_hit);
    try std.testing.expectEqual(@as(u64, 0), pulled1.remote.origin_bytes_read);
    try std.testing.expectEqual(@as(usize, 2), pulled1.materialization.cache.hit_count);
    try std.testing.expectEqual(@as(u64, 0), pulled1.materialization.cache.bytes_fetched);
    try std.testing.expectEqual(@as(usize, 1), pulled1.rootfs.cache.hit_count);
    try std.testing.expectEqual(@as(usize, 0), pulled1.rootfs.cache.miss_count);
    try std.testing.expectEqual(@as(u64, 0), pulled1.rootfs.cache.bytes_fetched);

    const restored_manifest = try spore.loadManifest(arena, out1_dir);
    defer restored_manifest.deinit();
    const restored_rootfs = restored_manifest.value.rootfs orelse return error.BadManifest;
    const fd = try rootfs_cache.openVerifiedFromCache(io, arena, pull_rootfs_cache, restored_rootfs);
    _ = std.c.close(fd);
    const out = try arena.alloc(u8, ram.len);
    @memset(out, 0xCC);
    try spore.loadMemory(arena, out1_dir, restored_manifest.value.memory, out);
    try std.testing.expectEqualSlices(u8, ram, out);

    const remote_pack_path = try pathZ(arena, "{s}/bucket/runs/demo.bundle/{s}", .{ fake_s3_root, pack_path });
    const data = try readFileAll(arena, remote_pack_path, 2 * spore.chunk_size);
    data[0] ^= 0x11;
    try writeFileAll(remote_pack_path, data);
    try std.testing.expectError(error.BadChunk, pull(arena, .{
        .io = io,
        .source = source_uri,
        .out_dir = out_bad_dir,
        .rootfs_cache_dir = pull_rootfs_cache,
        .bundle_cache_dir = bad_remote_cache_dir,
        .child_id = "1",
        .aws_region = "ap-southeast-2",
        .aws_executable = fake_aws,
    }));
}

test "push and pull s3 indexed bundle carries disk layers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const children_dir = try pathZ(arena, "{s}/children", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const out0_dir = try pathZ(arena, "{s}/s3-disk-pulled-0", .{root_dir});
    const out1_dir = try pathZ(arena, "{s}/s3-disk-pulled-1", .{root_dir});
    const out_bad_dir = try pathZ(arena, "{s}/s3-disk-pulled-bad", .{root_dir});
    const pack_cache_root = try pathZ(arena, "{s}/pack-rootfs-cache", .{root_dir});
    const pull_rootfs_cache = try pathZ(arena, "{s}/pull-rootfs-cache", .{root_dir});
    const remote_cache_dir = try pathZ(arena, "{s}/remote-cache", .{root_dir});
    const bad_remote_cache_dir = try pathZ(arena, "{s}/bad-remote-cache", .{root_dir});
    const rootfs_source_path = try pathZ(arena, "{s}/rootfs-source.ext4", .{root_dir});
    const fake_s3_root = try pathZ(arena, "{s}/fake-s3", .{root_dir});
    const fake_aws = try pathZ(arena, "{s}/fake-aws", .{root_dir});
    try ensureDirPath(io, fake_s3_root);
    try writeFakeAwsScript(arena, fake_aws, fake_s3_root);

    const ram = try arena.alloc(u8, spore.chunk_size + 29);
    @memset(ram, 0);
    ram[17] = 0x6A;
    ram[spore.chunk_size + 13] = 0xB4;
    const memory = try spore.saveMemory(arena, parent_dir, ram);
    const base_bytes = try arena.alloc(u8, 8192);
    @memset(base_bytes, 0);
    base_bytes[0] = 0x41;
    base_bytes[4096] = 0x42;
    try writeFileAll(rootfs_source_path, base_bytes);
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, pack_cache_root, rootfs_source_path);
    var manifest = testRootfsManifest(memory, ram.len, 121, artifact);
    try attachTestDiskLayer(arena, parent_dir, &manifest, rootfs_source_path, 4096, "remote disk bundle payload");
    try spore.saveManifest(arena, parent_dir, manifest);
    _ = try spore.fork(arena, .{ .parent_dir = parent_dir, .out_dir = children_dir, .count = 2 });

    const pack_result = try pack(arena, .{
        .io = io,
        .spore_dir = parent_dir,
        .out_dir = bundle_dir,
        .rootfs_cache_dir = pack_cache_root,
        .children_dir = children_dir,
    });
    const files = try indexedBundleFiles(arena, bundle_dir);
    try std.testing.expectEqual(@as(usize, 10), files.len);

    const push_result = try push(arena, .{
        .io = io,
        .bundle_dir = bundle_dir,
        .destination = "s3://bucket/runs/disk-demo.bundle/",
        .aws_region = "ap-southeast-2",
        .aws_executable = fake_aws,
    });
    try std.testing.expectEqualStrings(pack_result.bundle_digest, push_result.bundle_digest);
    try std.testing.expectEqual(@as(usize, 10), push_result.uploaded_file_count);

    const source_uri = try std.fmt.allocPrint(arena, "s3://bucket/runs/disk-demo.bundle@sha256:{s}", .{push_result.bundle_digest});
    const pulled0 = try pull(arena, .{
        .io = io,
        .source = source_uri,
        .out_dir = out0_dir,
        .rootfs_cache_dir = pull_rootfs_cache,
        .bundle_cache_dir = remote_cache_dir,
        .child_id = "0",
        .aws_region = "ap-southeast-2",
        .aws_executable = fake_aws,
    });
    try std.testing.expectEqualStrings("000000", pulled0.children.selected_child.?);
    try std.testing.expectEqualStrings(push_result.bundle_digest, pulled0.bundle_digest.hex);
    try std.testing.expect(!pulled0.remote.cache_hit);
    try std.testing.expectEqual(push_result.uploaded_bytes, pulled0.remote.origin_bytes_read);
    const restored0 = try spore.loadManifest(arena, out0_dir);
    defer restored0.deinit();
    _ = try disk_layer.loadLayerChain(arena, out0_dir, restored0.value.disk orelse return error.BadManifest);

    const pulled1 = try pull(arena, .{
        .io = io,
        .source = source_uri,
        .out_dir = out1_dir,
        .rootfs_cache_dir = pull_rootfs_cache,
        .bundle_cache_dir = remote_cache_dir,
        .child_id = "1",
        .aws_region = "ap-southeast-2",
        .aws_executable = fake_aws,
    });
    try std.testing.expectEqualStrings("000001", pulled1.children.selected_child.?);
    try std.testing.expect(pulled1.remote.cache_hit);
    try std.testing.expectEqual(@as(u64, 0), pulled1.remote.origin_bytes_read);
    const restored1 = try spore.loadManifest(arena, out1_dir);
    defer restored1.deinit();
    _ = try disk_layer.loadLayerChain(arena, out1_dir, restored1.value.disk orelse return error.BadManifest);

    const disk = manifest.disk orelse return error.BadManifest;
    const parsed_layer = try disk_layer.loadLayer(arena, bundle_dir, disk.layers[0]);
    defer parsed_layer.deinit();
    const object_rel = try diskObjectRelPath(arena, parsed_layer.value.extents[0].digest);
    const remote_object_path = try pathZ(arena, "{s}/bucket/runs/disk-demo.bundle/{s}", .{ fake_s3_root, object_rel });
    const object_data = try readFileAll(arena, remote_object_path, 8192);
    object_data[0] ^= 0x55;
    try writeFileAll(remote_object_path, object_data);
    try std.testing.expectError(error.BadChunk, pull(arena, .{
        .io = io,
        .source = source_uri,
        .out_dir = out_bad_dir,
        .rootfs_cache_dir = pull_rootfs_cache,
        .bundle_cache_dir = bad_remote_cache_dir,
        .child_id = "1",
        .aws_region = "ap-southeast-2",
        .aws_executable = fake_aws,
    }));
}

test "s3 bundle file uses head-object and bounded get-object range" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const fake_s3_root = try pathZ(arena, "{s}/fake-s3", .{root_dir});
    const remote_bundle_dir = try pathZ(arena, "{s}/bucket/runs/demo.bundle", .{fake_s3_root});
    const fake_aws = try pathZ(arena, "{s}/fake-aws", .{root_dir});
    const log_path = try pathZ(arena, "{s}/fake-aws.log", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/downloaded", .{root_dir});
    try ensureDirPath(io, remote_bundle_dir);
    try writeFileAll(try pathZ(arena, "{s}/{s}", .{ remote_bundle_dir, bundle_index_path }), "1234");
    try writeFakeAwsScriptWithLog(arena, fake_aws, fake_s3_root, log_path);

    const location = try parseS3Location(arena, "s3://bucket/runs/demo.bundle");
    var budget = RemoteBundleDownloadBudget{};
    const copied = try downloadS3BundleFile(arena, .{
        .io = io,
        .source = "s3://bucket/runs/demo.bundle@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .out_dir = root_dir,
        .aws_region = "ap-southeast-2",
        .aws_executable = fake_aws,
    }, location, bundle_dir, bundle_index_path, &budget, .metadata, 4);
    try std.testing.expectEqual(@as(u64, 4), copied);
    try std.testing.expectEqual(@as(u64, 4), budget.total_read);
    try std.testing.expectEqual(@as(u64, 4), budget.metadata_read);

    const downloaded = try readFileAll(arena, try pathZ(arena, "{s}/{s}", .{ bundle_dir, bundle_index_path }), 16);
    try std.testing.expectEqualStrings("1234", downloaded);
    const log = try readFileAll(arena, log_path, 4096);
    try std.testing.expect(std.mem.indexOf(u8, log, "s3api head-object") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "s3api get-object") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "--range bytes=0-3") != null);
}

test "s3 bundle file rejects oversized head before get-object" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const fake_s3_root = try pathZ(arena, "{s}/fake-s3", .{root_dir});
    const remote_bundle_dir = try pathZ(arena, "{s}/bucket/runs/demo.bundle", .{fake_s3_root});
    const fake_aws = try pathZ(arena, "{s}/fake-aws", .{root_dir});
    const log_path = try pathZ(arena, "{s}/fake-aws.log", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/downloaded", .{root_dir});
    try ensureDirPath(io, remote_bundle_dir);
    try writeFileAll(try pathZ(arena, "{s}/{s}", .{ remote_bundle_dir, bundle_index_path }), "12345");
    try writeFakeAwsScriptWithLog(arena, fake_aws, fake_s3_root, log_path);

    const location = try parseS3Location(arena, "s3://bucket/runs/demo.bundle");
    var budget = RemoteBundleDownloadBudget{};
    try std.testing.expectError(error.BundleBodyTooLarge, downloadS3BundleFile(arena, .{
        .io = io,
        .source = "s3://bucket/runs/demo.bundle@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .out_dir = root_dir,
        .aws_region = "ap-southeast-2",
        .aws_executable = fake_aws,
    }, location, bundle_dir, bundle_index_path, &budget, .metadata, 4));
    try std.testing.expectEqual(@as(u64, 0), budget.total_read);
    try std.testing.expectEqual(@as(u64, 0), budget.metadata_read);
    try std.testing.expect(!try pathExistsNoSymlink(io, try pathZ(arena, "{s}/{s}", .{ bundle_dir, bundle_index_path })));

    const log = try readFileAll(arena, log_path, 4096);
    try std.testing.expect(std.mem.indexOf(u8, log, "s3api head-object") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "s3api get-object") == null);
}

test "s3 bundle file deletes partial file when observed size changes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const fake_aws = try pathZ(arena, "{s}/fake-aws-racy", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/downloaded", .{root_dir});
    const script =
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\if [[ "$1" == "s3api" && "$2" == "head-object" ]]; then
        \\  printf '4\n'
        \\  exit 0
        \\fi
        \\if [[ "$1" == "s3api" && "$2" == "get-object" ]]; then
        \\  shift 2
        \\  outfile=""
        \\  while [[ "$#" -gt 0 ]]; do
        \\    case "$1" in
        \\      --bucket|--key|--range|--region) shift 2 ;;
        \\      *) outfile="$1"; shift ;;
        \\    esac
        \\  done
        \\  mkdir -p "$(dirname "$outfile")"
        \\  printf '12345' > "$outfile"
        \\  printf '{"ContentLength":5}\n'
        \\  exit 0
        \\fi
        \\exit 64
        \\
    ;
    try writeFileAll(fake_aws, script);
    if (std.c.chmod(fake_aws, 0o755) != 0) return error.IoFailed;

    const location = try parseS3Location(arena, "s3://bucket/runs/demo.bundle");
    var budget = RemoteBundleDownloadBudget{};
    try std.testing.expectError(error.BadChunk, downloadS3BundleFile(arena, .{
        .io = io,
        .source = "s3://bucket/runs/demo.bundle@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .out_dir = root_dir,
        .aws_region = "ap-southeast-2",
        .aws_executable = fake_aws,
    }, location, bundle_dir, bundle_index_path, &budget, .metadata, 8));
    try std.testing.expect(!try pathExistsNoSymlink(io, try pathZ(arena, "{s}/{s}", .{ bundle_dir, bundle_index_path })));
    try std.testing.expectEqual(@as(u64, 0), budget.total_read);
}

test "http bundle pull rejects loopback source before request" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    try ensureDirPath(io, bundle_dir);
    try writeFileAll(try pathZ(arena, "{s}/{s}", .{ bundle_dir, bundle_index_path }), "{}");

    var server: StaticHttpBundleServer = undefined;
    try server.init(arena, io, bundle_dir, "spore.bundle");
    defer server.deinit();

    const base_url = try server.baseUrl(arena);
    const url = try std.fmt.allocPrint(arena, "{s}/{s}", .{ base_url, bundle_index_path });
    const dest_path = try pathZ(arena, "{s}/downloaded-bundle.json", .{root_dir});
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    try std.testing.expectError(error.BadManifest, httpGetToFile(io, &client, url, dest_path, max_remote_bundle_metadata_file_bytes));
    try std.testing.expectEqual(@as(usize, 0), server.request_count.load(.monotonic));
}

test "http bundle file rejects oversized content length before writing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const dest_path = try pathZ(arena, "{s}/oversized-body", .{root_dir});
    var server: TestHttpBodyServer = undefined;
    try server.init(io, "", .content_length, 17);
    defer server.deinit();

    const url = try server.url(arena);
    const uri = try std.Uri.parse(url);
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    try std.testing.expectError(error.BundleBodyTooLarge, httpGetToFileAfterPolicy(io, &client, uri, server.server.socket.address, dest_path, 16));
    try std.testing.expect(!try pathExistsNoSymlink(io, dest_path));
    try std.testing.expectEqual(@as(usize, 1), server.request_count.load(.monotonic));
}

test "http bundle file stops chunked bodies at the streaming limit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try arena.alloc(u8, 128 * 1024);
    @memset(body, 0xAB);
    const root_dir = try testDir(arena);
    const dest_path = try pathZ(arena, "{s}/oversized-chunked-body", .{root_dir});
    var server: TestHttpBodyServer = undefined;
    try server.init(io, body, .chunked, null);
    defer server.deinit();

    const url = try server.url(arena);
    const uri = try std.Uri.parse(url);
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    try std.testing.expectError(error.BundleBodyTooLarge, httpGetToFileAfterPolicy(io, &client, uri, server.server.socket.address, dest_path, 16 * 1024));
    try std.testing.expect(!try pathExistsNoSymlink(io, dest_path));
    try std.testing.expectEqual(@as(usize, 1), server.request_count.load(.monotonic));
}

test "pull fails closed on corrupt chunk cache entries" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const children_dir = try pathZ(arena, "{s}/children", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const out0_dir = try pathZ(arena, "{s}/pulled-0", .{root_dir});
    const out_bad_dir = try pathZ(arena, "{s}/pulled-bad", .{root_dir});
    const chunk_cache_dir = try pathZ(arena, "{s}/chunk-cache", .{root_dir});
    const source_uri = try std.fmt.allocPrint(arena, "file://{s}", .{bundle_dir});

    const ram = try arena.alloc(u8, spore.chunk_size);
    @memset(ram, 0x62);
    const memory = try spore.saveMemory(arena, parent_dir, ram);
    try spore.saveManifest(arena, parent_dir, testManifest(memory, ram.len, 81));
    _ = try spore.fork(arena, .{ .parent_dir = parent_dir, .out_dir = children_dir, .count = 1 });
    _ = try pack(arena, .{
        .io = io,
        .spore_dir = parent_dir,
        .out_dir = bundle_dir,
        .children_dir = children_dir,
    });
    _ = try pull(arena, .{
        .io = io,
        .source = source_uri,
        .out_dir = out0_dir,
        .bundle_cache_dir = chunk_cache_dir,
        .child_id = "000000",
    });

    const restored_manifest = try spore.loadManifest(arena, out0_dir);
    defer restored_manifest.deinit();
    const first_ref = restored_manifest.value.memory.chunks[0] orelse return error.BadManifest;
    const cache_path = try chunkCachePath(arena, chunk_cache_dir, first_ref);
    try Io.Dir.cwd().deleteFile(io, cache_path);
    try writeFileAll(try pathZ(arena, "{s}", .{cache_path}), "tampered");

    try std.testing.expectError(error.BadChunk, pull(arena, .{
        .io = io,
        .source = source_uri,
        .out_dir = out_bad_dir,
        .bundle_cache_dir = chunk_cache_dir,
        .child_id = "000000",
    }));
    const manifest_path = try pathZ(arena, "{s}/manifest.json", .{out_bad_dir});
    try std.testing.expect(std.c.access(manifest_path, 0) != 0);
}

test "pull rejects mutable or ambiguous sources" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.BadManifest, pull(allocator, .{
        .io = std.testing.io,
        .source = "https://example.test/spore.bundle",
        .out_dir = "zig-cache/pull-unsupported",
    }));
    try std.testing.expectError(error.BadManifest, pull(allocator, .{
        .io = std.testing.io,
        .source = "s3://bucket/spore.bundle",
        .out_dir = "zig-cache/pull-unsupported",
    }));
    try std.testing.expectError(error.BadManifest, pull(allocator, .{
        .io = std.testing.io,
        .source = "file://relative.bundle",
        .out_dir = "zig-cache/pull-relative",
    }));
    try std.testing.expectError(error.BadManifest, pull(allocator, .{
        .io = std.testing.io,
        .source = "file:///tmp/with%20escape.bundle",
        .out_dir = "zig-cache/pull-escaped",
    }));
}

test "http uri parser requires immutable digest and path-safe source" {
    const allocator = std.testing.allocator;
    const digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expectError(error.BadManifest, parseHttpSource(allocator, "http://127.0.0.1:20000/spore.bundle"));
    try std.testing.expectError(error.BadManifest, parseHttpSource(allocator, "http://127.0.0.1:20000/spore.bundle@sha256:not-hex"));
    try std.testing.expectError(error.BadManifest, parseHttpSource(allocator, "http://user@127.0.0.1:20000/spore.bundle@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try std.testing.expectError(error.BadManifest, parseHttpSource(allocator, "http://127.0.0.1:20000/runs/../spore.bundle@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try std.testing.expectError(error.BadManifest, parseHttpSource(allocator, "http://127.0.0.1:20000/spore.bundle?mutable=1@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));

    const source = try std.fmt.allocPrint(allocator, "http://127.0.0.1:20000/spore.bundle/@sha256:{s}", .{digest});
    defer allocator.free(source);
    const parsed = try parseHttpSource(allocator, source);
    defer allocator.free(parsed.location.base_url);
    defer allocator.free(parsed.expected_digest);
    try std.testing.expectEqualStrings("http://127.0.0.1:20000/spore.bundle", parsed.location.base_url);
    try std.testing.expectEqualStrings(digest, parsed.expected_digest);
}

test "http fetch target policy rejects private bundle sources" {
    try std.testing.expectError(error.BadManifest, validateHttpFetchTarget(std.testing.io, try std.Uri.parse("https://127.0.0.1/spore.bundle")));
    try std.testing.expectError(error.BadManifest, validateHttpFetchTarget(std.testing.io, try std.Uri.parse("https://169.254.169.254/spore.bundle")));
    try std.testing.expectError(error.BadManifest, validateHttpFetchTarget(std.testing.io, try std.Uri.parse("https://10.0.0.1/spore.bundle")));
}

test "s3 uri parser requires immutable digest for sources" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.BadManifest, parseS3Source(allocator, "s3://bucket/runs/demo.bundle"));
    try std.testing.expectError(error.BadManifest, parseS3Source(allocator, "s3://bucket/runs/demo.bundle@sha256:not-hex"));
    try std.testing.expectError(error.BadManifest, parseS3Destination(allocator, "s3://bucket/runs/demo.bundle@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));

    const parsed = try parseS3Source(allocator, "s3://bucket/runs/demo.bundle/@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    defer allocator.free(parsed.location.bucket);
    defer allocator.free(parsed.location.prefix);
    defer allocator.free(parsed.expected_digest);
    try std.testing.expectEqualStrings("bucket", parsed.location.bucket);
    try std.testing.expectEqualStrings("runs/demo.bundle", parsed.location.prefix);
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", parsed.expected_digest);

    try std.testing.expectError(error.BadManifest, parseS3Source(allocator, "s3://bucket/runs/../demo.bundle@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
}

test "local bundle content source rejects out-of-bounds ranges" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});

    const ram = try arena.alloc(u8, 4096);
    @memset(ram, 0x84);
    const memory = try spore.saveMemory(arena, parent_dir, ram);
    try spore.saveManifest(arena, parent_dir, testManifest(memory, ram.len, 91));
    _ = try pack(arena, .{ .io = io, .spore_dir = parent_dir, .out_dir = bundle_dir });

    const parsed_index = try loadIndex(arena, bundle_dir);
    defer parsed_index.deinit();
    var bad_entry = parsed_index.value.chunks[0];
    bad_entry.offset = spore.chunk_size;
    var local_source = LocalBundleContentSource{ .bundle_dir = bundle_dir };
    try std.testing.expectError(error.BadChunk, local_source.source().readChunk(
        arena,
        bad_entry,
        bad_entry.id,
        @intCast(bad_entry.size),
    ));
}

test "pack children writes exact rootfs policy and unpacks selected rootfs child" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const children_dir = try pathZ(arena, "{s}/children", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const out_dir = try pathZ(arena, "{s}/unpacked-child", .{root_dir});
    const pack_cache_root = try pathZ(arena, "{s}/pack-cache", .{root_dir});
    const unpack_cache_root = try pathZ(arena, "{s}/unpack-cache", .{root_dir});
    const rootfs_source_path = try pathZ(arena, "{s}/rootfs-source.ext4", .{root_dir});

    const ram = try arena.alloc(u8, 4096);
    @memset(ram, 0x44);
    const memory = try spore.saveMemory(arena, parent_dir, ram);
    try writeFileAll(rootfs_source_path, "rootfs child bundle bytes");
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, pack_cache_root, rootfs_source_path);
    try spore.saveManifest(arena, parent_dir, testRootfsManifest(memory, ram.len, 51, artifact));
    _ = try spore.fork(arena, .{ .parent_dir = parent_dir, .out_dir = children_dir, .count = 2 });

    _ = try pack(arena, .{
        .io = io,
        .spore_dir = parent_dir,
        .out_dir = bundle_dir,
        .rootfs_cache_dir = pack_cache_root,
        .children_dir = children_dir,
    });

    const bundle_index = try loadBundleIndex(arena, bundle_dir);
    defer bundle_index.deinit();
    try std.testing.expectEqualStrings(rootfs_index_path, bundle_index.value.rootfs_index.?);
    const parsed_rootfs_index = try loadRootfsIndex(arena, bundle_dir);
    defer parsed_rootfs_index.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_rootfs_index.value.artifacts.len);
    try std.testing.expectEqualStrings(rootfs_policy_exact_bytes, parsed_rootfs_index.value.artifacts[0].policy);
    try std.testing.expectEqualStrings(artifact.digest, parsed_rootfs_index.value.artifacts[0].digest);

    _ = try unpack(arena, .{
        .io = io,
        .bundle_dir = bundle_dir,
        .out_dir = out_dir,
        .rootfs_cache_dir = unpack_cache_root,
        .child_id = "000000",
    });
    const restored_manifest = try spore.loadManifest(arena, out_dir);
    defer restored_manifest.deinit();
    const restored_rootfs = restored_manifest.value.rootfs orelse return error.BadManifest;
    const fd = try rootfs_cache.openVerifiedFromCache(io, arena, unpack_cache_root, restored_rootfs);
    _ = std.c.close(fd);
}

test "pack and pull chunked rootfs storage materializes rootfs CAS" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const children_dir = try pathZ(arena, "{s}/children", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const single_bundle_dir = try pathZ(arena, "{s}/single-bundle", .{root_dir});
    const metadata_only_storage_bundle_dir = try pathZ(arena, "{s}/metadata-only-storage-bundle", .{root_dir});
    const single_out_dir = try pathZ(arena, "{s}/single-unpacked", .{root_dir});
    const out_dir = try pathZ(arena, "{s}/pulled-child", .{root_dir});
    const out_cached_dir = try pathZ(arena, "{s}/pulled-cached-child", .{root_dir});
    const out_bad_dir = try pathZ(arena, "{s}/pulled-bad-child", .{root_dir});
    const pack_cache_root = try pathZ(arena, "{s}/pack-cache", .{root_dir});
    const single_rootfs_cache = try pathZ(arena, "{s}/single-rootfs-cache", .{root_dir});
    const pull_rootfs_cache = try pathZ(arena, "{s}/pull-rootfs-cache", .{root_dir});
    const bad_rootfs_cache = try pathZ(arena, "{s}/bad-rootfs-cache", .{root_dir});
    const pull_bundle_cache = try pathZ(arena, "{s}/pull-bundle-cache", .{root_dir});
    const bad_bundle_cache = try pathZ(arena, "{s}/bad-bundle-cache", .{root_dir});
    const rootfs_source_path = try pathZ(arena, "{s}/rootfs-source.ext4", .{root_dir});

    const ram = try arena.alloc(u8, 4096);
    @memset(ram, 0x64);
    const memory = try spore.saveMemory(arena, parent_dir, ram);
    const rootfs_bytes = try arena.alloc(u8, 3 * 4096 + 7);
    @memset(rootfs_bytes, 0);
    rootfs_bytes[0] = 0x11;
    rootfs_bytes[2 * 4096 + 3] = 0x22;
    try writeFileAll(rootfs_source_path, rootfs_bytes);
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, pack_cache_root, rootfs_source_path);
    const preload_result = try rootfs_cas.preload(io, arena, pack_cache_root, artifact.digest, 4096);
    var manifest = testRootfsManifest(memory, ram.len, 62, artifact);
    manifest.rootfs.?.storage = rootfs_cas.storageDescriptor(manifest.rootfs.?.device, preload_result);
    try spore.saveManifest(arena, parent_dir, manifest);
    try std.testing.expectError(error.UnsupportedMetadataOnlyRootfsStorage, pack(arena, .{
        .io = io,
        .spore_dir = parent_dir,
        .out_dir = metadata_only_storage_bundle_dir,
        .rootfs_cache_dir = pack_cache_root,
        .rootfs_policy = .metadata_only,
    }));

    const single_pack = try pack(arena, .{
        .io = io,
        .spore_dir = parent_dir,
        .out_dir = single_bundle_dir,
        .rootfs_cache_dir = pack_cache_root,
    });
    try std.testing.expectEqual(@as(usize, 0), single_pack.child_count);
    try std.testing.expectEqual(@as(usize, 1), single_pack.rootfs_artifact_count);
    const single_unpacked = try unpack(arena, .{
        .io = io,
        .bundle_dir = single_bundle_dir,
        .out_dir = single_out_dir,
        .rootfs_cache_dir = single_rootfs_cache,
    });
    try std.testing.expectEqual(@as(usize, 0), single_unpacked.child_count);
    try std.testing.expectEqual(@as(usize, 1), single_unpacked.rootfs_artifact_count);
    _ = try spore.fork(arena, .{ .parent_dir = parent_dir, .out_dir = children_dir, .count = 1 });

    const pack_result = try pack(arena, .{
        .io = io,
        .spore_dir = parent_dir,
        .out_dir = bundle_dir,
        .rootfs_cache_dir = pack_cache_root,
        .children_dir = children_dir,
    });
    try std.testing.expectEqual(@as(usize, 1), pack_result.rootfs_artifact_count);
    try std.testing.expect(pack_result.rootfs_payload_bytes > 0);

    const exact_rel_path = try rootfsArtifactRelPath(arena, artifact);
    try std.testing.expect(!try pathExistsNoSymlink(io, try pathZ(arena, "{s}/{s}", .{ bundle_dir, exact_rel_path })));
    const parsed_rootfs_index = try loadRootfsIndex(arena, bundle_dir);
    defer parsed_rootfs_index.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed_rootfs_index.value.artifacts.len);
    try std.testing.expectEqual(@as(usize, 1), parsed_rootfs_index.value.storages.len);
    const storage_entry = parsed_rootfs_index.value.storages[0];
    try std.testing.expectEqualStrings(preload_result.index_digest, storage_entry.index_digest);
    try std.testing.expectEqual(preload_result.nonzero_chunks, storage_entry.object_count);

    const source_uri = try std.fmt.allocPrint(arena, "file://{s}", .{bundle_dir});
    const pulled = try pull(arena, .{
        .io = io,
        .source = source_uri,
        .out_dir = out_dir,
        .rootfs_cache_dir = pull_rootfs_cache,
        .bundle_cache_dir = pull_bundle_cache,
        .child_id = "000000",
    });
    try std.testing.expectEqual(@as(usize, 1), pulled.rootfs.artifact_count);
    try std.testing.expectEqual(@as(usize, 0), pulled.rootfs.cache.hit_count);
    try std.testing.expectEqual(preload_result.nonzero_chunks + 1, pulled.rootfs.cache.miss_count);
    try std.testing.expect(pulled.rootfs.cache.bytes_fetched > 0);
    try std.testing.expectEqual(@as(u64, 0), pulled.rootfs.cache.bytes_reused);

    const pulled_cached = try pull(arena, .{
        .io = io,
        .source = source_uri,
        .out_dir = out_cached_dir,
        .rootfs_cache_dir = pull_rootfs_cache,
        .bundle_cache_dir = pull_bundle_cache,
        .child_id = "000000",
    });
    try std.testing.expectEqual(preload_result.nonzero_chunks + 1, pulled_cached.rootfs.cache.hit_count);
    try std.testing.expectEqual(@as(usize, 0), pulled_cached.rootfs.cache.miss_count);
    try std.testing.expectEqual(@as(u64, 0), pulled_cached.rootfs.cache.bytes_fetched);
    try std.testing.expectEqual(pulled.rootfs.payload_bytes, pulled_cached.rootfs.cache.bytes_reused);
    try std.testing.expectEqual(@as(u64, @intCast(ram.len)), pulled_cached.materialization.cache.bytes_reused);

    // Chunked pulls eagerly assemble the flat digest-addressed artifact from
    // the installed verified chunks; it is the only runtime base source.
    const exact_cache_path = try rootfs_cache.digestPath(arena, pull_rootfs_cache, artifact.digest);
    try std.testing.expect(try pathExistsNoSymlink(io, exact_cache_path));
    const restored_manifest = try spore.loadManifest(arena, out_dir);
    defer restored_manifest.deinit();
    const restored_rootfs = restored_manifest.value.rootfs orelse return error.BadManifest;
    try std.testing.expect(restored_rootfs.storage != null);
    const exact_cache_path_z = try arena.dupeZ(u8, exact_cache_path);
    const assembled = try readFileAll(arena, exact_cache_path_z, 1 << 20);
    try std.testing.expectEqual(@as(u8, 0x11), assembled[0]);
    try std.testing.expectEqual(@as(u8, 0), assembled[4096]);
    try std.testing.expectEqual(@as(u8, 0x22), assembled[2 * 4096 + 3]);

    const storage = rootfsStorageEntryDescriptor(storage_entry);
    const parsed_block_index = try loadDiskIndexForEntry(arena, bundle_dir, storage_entry, storage);
    defer parsed_block_index.deinit();
    const first_chunk = parsed_block_index.value.chunks[0];
    const object_rel_path = try rootfsStorageObjectRelPath(arena, first_chunk.digest);
    const object_path = try pathZ(arena, "{s}/{s}", .{ bundle_dir, object_rel_path });
    const clean_digest = try digestHex(arena, bundle_dir);
    const object_data = try readFileAll(arena, object_path, 4096);
    object_data[0] ^= 0xff;
    try writeFileAll(object_path, object_data);
    const corrupt_digest = try digestHex(arena, bundle_dir);
    try std.testing.expect(!std.mem.eql(u8, clean_digest, corrupt_digest));
    try std.testing.expectError(error.BadChunk, pull(arena, .{
        .io = io,
        .source = source_uri,
        .out_dir = out_bad_dir,
        .rootfs_cache_dir = bad_rootfs_cache,
        .bundle_cache_dir = bad_bundle_cache,
        .child_id = "000000",
    }));
    try std.testing.expect(!try pathExistsNoSymlink(io, out_bad_dir));
}

test "pack rejects chunked rootfs storage derived from different artifact" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const pack_cache_root = try pathZ(arena, "{s}/pack-cache", .{root_dir});
    const rootfs_a_path = try pathZ(arena, "{s}/rootfs-a.ext4", .{root_dir});
    const rootfs_b_path = try pathZ(arena, "{s}/rootfs-b.ext4", .{root_dir});

    const ram = try arena.alloc(u8, 4096);
    @memset(ram, 0x74);
    const memory = try spore.saveMemory(arena, parent_dir, ram);

    const rootfs_a = try arena.alloc(u8, 4096);
    @memset(rootfs_a, 0);
    rootfs_a[0] = 0xa1;
    const rootfs_b = try arena.alloc(u8, 4096);
    @memset(rootfs_b, 0);
    rootfs_b[0] = 0xb2;
    try writeFileAll(rootfs_a_path, rootfs_a);
    try writeFileAll(rootfs_b_path, rootfs_b);

    const artifact_a = try rootfs_cache.cacheByDigestPath(io, arena, pack_cache_root, rootfs_a_path);
    const artifact_b = try rootfs_cache.cacheByDigestPath(io, arena, pack_cache_root, rootfs_b_path);
    try std.testing.expectEqual(artifact_a.size, artifact_b.size);
    try std.testing.expect(!std.mem.eql(u8, artifact_a.digest, artifact_b.digest));

    const preload_b = try rootfs_cas.preload(io, arena, pack_cache_root, artifact_b.digest, 4096);
    var manifest = testRootfsManifest(memory, ram.len, 73, artifact_a);
    manifest.rootfs.?.storage = rootfs_cas.storageDescriptor(manifest.rootfs.?.device, preload_b);
    try spore.saveManifest(arena, parent_dir, manifest);

    try std.testing.expect(rootfs_cas.storageComplete(io, arena, pack_cache_root, manifest.rootfs.?.storage.?) catch |err| return rootfsError(err));
    try std.testing.expectError(error.BadManifest, pack(arena, .{
        .io = io,
        .spore_dir = parent_dir,
        .out_dir = bundle_dir,
        .rootfs_cache_dir = pack_cache_root,
    }));
}

test "metadata-only rootfs policy requires explicit prepared cache" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const children_dir = try pathZ(arena, "{s}/children", .{root_dir});
    const single_bundle_dir = try pathZ(arena, "{s}/single-bundle", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const out_dir = try pathZ(arena, "{s}/unpacked-child", .{root_dir});
    const out_missing_dir = try pathZ(arena, "{s}/unpacked-missing-child", .{root_dir});
    const out_prepared_dir = try pathZ(arena, "{s}/unpacked-prepared-child", .{root_dir});
    const out_pull_denied_dir = try pathZ(arena, "{s}/pulled-denied-child", .{root_dir});
    const out_pull_missing_dir = try pathZ(arena, "{s}/pulled-missing-child", .{root_dir});
    const out_pull_dir = try pathZ(arena, "{s}/pulled-prepared-child", .{root_dir});
    const pack_cache_root = try pathZ(arena, "{s}/pack-cache", .{root_dir});
    const unpack_cache_root = try pathZ(arena, "{s}/unpack-cache", .{root_dir});
    const missing_cache_root = try pathZ(arena, "{s}/missing-cache", .{root_dir});
    const pull_chunk_cache = try pathZ(arena, "{s}/pull-chunk-cache", .{root_dir});
    const rootfs_source_path = try pathZ(arena, "{s}/rootfs-source.ext4", .{root_dir});

    const ram = try arena.alloc(u8, 4096);
    @memset(ram, 0x45);
    const memory = try spore.saveMemory(arena, parent_dir, ram);
    const rootfs_bytes = "rootfs metadata only bytes";
    const trusted_rootfs_bytes = "ROOTFS METADATA ONLY BYTES";
    try std.testing.expectEqual(rootfs_bytes.len, trusted_rootfs_bytes.len);
    try writeFileAll(rootfs_source_path, rootfs_bytes);
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, pack_cache_root, rootfs_source_path);
    try spore.saveManifest(arena, parent_dir, testRootfsManifest(memory, ram.len, 61, artifact));
    const single_pack = try pack(arena, .{
        .io = io,
        .spore_dir = parent_dir,
        .out_dir = single_bundle_dir,
        .rootfs_cache_dir = pack_cache_root,
        .rootfs_policy = .metadata_only,
    });
    try std.testing.expectEqual(@as(usize, 0), single_pack.child_count);
    try std.testing.expectEqual(@as(usize, 1), single_pack.rootfs_artifact_count);
    try std.testing.expectEqual(@as(u64, 0), single_pack.rootfs_payload_bytes);
    const single_rootfs_index = try loadRootfsIndex(arena, single_bundle_dir);
    defer single_rootfs_index.deinit();
    try std.testing.expectEqualStrings(rootfs_policy_metadata_only, single_rootfs_index.value.artifacts[0].policy);

    _ = try spore.fork(arena, .{ .parent_dir = parent_dir, .out_dir = children_dir, .count = 1 });
    _ = try pack(arena, .{
        .io = io,
        .spore_dir = parent_dir,
        .out_dir = bundle_dir,
        .rootfs_cache_dir = pack_cache_root,
        .children_dir = children_dir,
        .rootfs_policy = .metadata_only,
    });

    const rootfs_rel_path = try rootfsArtifactRelPath(arena, artifact);
    try std.testing.expect(!try pathExistsNoSymlink(io, try pathZ(arena, "{s}/{s}", .{ bundle_dir, rootfs_rel_path })));
    const parsed_rootfs_index = try loadRootfsIndex(arena, bundle_dir);
    defer parsed_rootfs_index.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_rootfs_index.value.artifacts.len);
    try std.testing.expectEqualStrings(rootfs_policy_metadata_only, parsed_rootfs_index.value.artifacts[0].policy);
    try std.testing.expect(parsed_rootfs_index.value.artifacts[0].path == null);

    try std.testing.expectError(error.BadManifest, unpack(arena, .{
        .io = io,
        .bundle_dir = bundle_dir,
        .out_dir = out_dir,
        .rootfs_cache_dir = unpack_cache_root,
        .child_id = "000000",
    }));
    try std.testing.expect(!try pathExistsNoSymlink(io, out_dir));
    try std.testing.expectError(error.BadChunk, unpack(arena, .{
        .io = io,
        .bundle_dir = bundle_dir,
        .out_dir = out_missing_dir,
        .rootfs_cache_dir = missing_cache_root,
        .child_id = "000000",
        .allow_metadata_only_rootfs = true,
    }));
    try std.testing.expect(!try pathExistsNoSymlink(io, out_missing_dir));

    const source_uri = try std.fmt.allocPrint(arena, "file://{s}", .{bundle_dir});
    try std.testing.expectError(error.BadManifest, pull(arena, .{
        .io = io,
        .source = source_uri,
        .out_dir = out_pull_denied_dir,
        .rootfs_cache_dir = unpack_cache_root,
        .bundle_cache_dir = pull_chunk_cache,
        .child_id = "000000",
    }));
    try std.testing.expect(!try pathExistsNoSymlink(io, out_pull_denied_dir));
    try std.testing.expectError(error.BadChunk, pull(arena, .{
        .io = io,
        .source = source_uri,
        .out_dir = out_pull_missing_dir,
        .rootfs_cache_dir = missing_cache_root,
        .bundle_cache_dir = pull_chunk_cache,
        .child_id = "000000",
        .allow_metadata_only_rootfs = true,
    }));
    try std.testing.expect(!try pathExistsNoSymlink(io, out_pull_missing_dir));

    const trusted_cache_path = try rootfs_cache.digestPath(arena, unpack_cache_root, artifact.digest);
    const trusted_cache_parent = std.fs.path.dirname(trusted_cache_path) orelse return error.BadManifest;
    try ensureDirPath(io, trusted_cache_parent);
    const trusted_cache_path_z = try pathZ(arena, "{s}", .{trusted_cache_path});
    try writeFileAll(trusted_cache_path_z, trusted_rootfs_bytes);
    const unpacked = try unpack(arena, .{
        .io = io,
        .bundle_dir = bundle_dir,
        .out_dir = out_prepared_dir,
        .rootfs_cache_dir = unpack_cache_root,
        .child_id = "000000",
        .allow_metadata_only_rootfs = true,
    });
    try std.testing.expectEqual(@as(usize, 1), unpacked.rootfs_artifact_count);
    try std.testing.expectEqual(@as(u64, 0), unpacked.rootfs_payload_bytes);

    const pulled = try pull(arena, .{
        .io = io,
        .source = source_uri,
        .out_dir = out_pull_dir,
        .rootfs_cache_dir = unpack_cache_root,
        .bundle_cache_dir = pull_chunk_cache,
        .child_id = "000000",
        .allow_metadata_only_rootfs = true,
    });
    try std.testing.expectEqual(@as(usize, 1), pulled.rootfs.artifact_count);
    try std.testing.expectEqual(@as(u64, 0), pulled.rootfs.payload_bytes);
    try std.testing.expectEqual(@as(usize, 1), pulled.rootfs.cache.hit_count);
    try std.testing.expectEqual(@as(usize, 0), pulled.rootfs.cache.miss_count);
    try std.testing.expectEqual(@as(u64, 0), pulled.rootfs.cache.bytes_fetched);
}

test "pack rejects rootfs manifests without cache artifact" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const cache_root = try pathZ(arena, "{s}/cache", .{root_dir});

    const ram = try arena.alloc(u8, 4096);
    @memset(ram, 0x33);
    const memory = try spore.saveMemory(arena, parent_dir, ram);
    const artifact = spore.RootfsArtifactRef{
        .digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .size = 4096,
    };
    try spore.saveManifest(arena, parent_dir, testRootfsManifest(memory, ram.len, 14, artifact));

    try std.testing.expectError(error.BadChunk, pack(arena, .{
        .io = io,
        .spore_dir = parent_dir,
        .out_dir = bundle_dir,
        .rootfs_cache_dir = cache_root,
    }));
}

test "bundle index rejects duplicate chunk ids" {
    const id = chunklib.ChunkId.fromContents("duplicate");
    const id_hex = id.toHex();
    const sha_hex = try sha256HexAlloc(std.testing.allocator, "duplicate");
    defer std.testing.allocator.free(sha_hex);
    var chunks = [_]IndexChunk{
        .{ .id = &id_hex, .pack = pack_path, .offset = 0, .size = 9, .sha256 = sha_hex },
        .{ .id = &id_hex, .pack = pack_path, .offset = 9, .size = 9, .sha256 = sha_hex },
    };
    try std.testing.expectError(error.BadManifest, validateIndex(std.testing.allocator, .{
        .chunk_size = spore.chunk_size,
        .chunks = &chunks,
    }));
}

test "distribution bundle index rejects non-canonical child paths" {
    var children = [_]BundleChild{.{
        .id = "000000",
        .manifest = "../manifest.json",
    }};
    try std.testing.expectError(error.BadManifest, validateBundleIndex(std.testing.allocator, .{
        .children = &children,
    }));
}

test "rootfs index rejects duplicate digests and unsafe exact paths" {
    const digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    var duplicate = [_]RootfsArtifactEntry{
        .{
            .digest = digest,
            .size = 4096,
            .path = "rootfs/blake3/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.ext4",
        },
        .{
            .digest = digest,
            .size = 4096,
            .path = "rootfs/blake3/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.ext4",
        },
    };
    try std.testing.expectError(error.BadManifest, validateRootfsIndex(std.testing.allocator, .{
        .artifacts = &duplicate,
    }));

    var unsafe = [_]RootfsArtifactEntry{.{
        .digest = digest,
        .size = 4096,
        .path = "../rootfs.ext4",
    }};
    try std.testing.expectError(error.BadManifest, validateRootfsIndex(std.testing.allocator, .{
        .artifacts = &unsafe,
    }));

    const storage_path = "rootfs/blake3/indexes/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json";
    var duplicate_storage = [_]RootfsStorageEntry{
        .{
            .device = .{ .mmio_slot = 0 },
            .logical_size = 4096,
            .chunk_size = 4096,
            .index_digest = digest,
            .base_identity = digest,
            .index_path = storage_path,
            .index_bytes = 128,
            .object_count = 0,
            .object_bytes = 0,
        },
        .{
            .device = .{ .mmio_slot = 0 },
            .logical_size = 4096,
            .chunk_size = 4096,
            .index_digest = digest,
            .base_identity = digest,
            .index_path = storage_path,
            .index_bytes = 128,
            .object_count = 0,
            .object_bytes = 0,
        },
    };
    try std.testing.expectError(error.BadManifest, validateRootfsIndex(std.testing.allocator, .{
        .storages = &duplicate_storage,
    }));

    var unsafe_storage = [_]RootfsStorageEntry{.{
        .device = .{ .mmio_slot = 0 },
        .logical_size = 4096,
        .chunk_size = 4096,
        .index_digest = digest,
        .base_identity = digest,
        .index_path = "../rootfs-index.json",
        .index_bytes = 128,
        .object_count = 0,
        .object_bytes = 0,
    }};
    try std.testing.expectError(error.BadManifest, validateRootfsIndex(std.testing.allocator, .{
        .storages = &unsafe_storage,
    }));
}
