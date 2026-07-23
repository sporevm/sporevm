//! Product result contracts shared by libspore and CLI serializers.

const std = @import("std");
const resource = @import("resource.zig");

pub const inspect_bundle_schema = "spore.bundle.inspect.v1";
pub const pull_result_schema = "spore.pull.result.v1";
pub const bundle_schema_version: u32 = 1;

pub const DigestRef = struct {
    algorithm: []const u8 = "sha256",
    hex: []const u8,
};

pub const CacheState = struct {
    hit_count: usize = 0,
    miss_count: usize = 0,
    bytes_fetched: u64 = 0,
    bytes_reused: u64 = 0,
};

pub const ChunkMaterializationSummary = struct {
    chunk_count: usize,
    materialized_chunk_count: usize,
    payload_bytes: u64,
    linked_chunk_count: usize = 0,
    copied_chunk_count: usize = 0,
    cache: CacheState = .{},
};

pub const RootfsMaterializationSummary = struct {
    artifact_count: usize = 0,
    payload_bytes: u64 = 0,
    cache: CacheState = .{},
};

pub const RemoteBundleCache = struct {
    cache_hit: bool = false,
    origin_bytes_read: u64 = 0,
    peer_bytes_read: u64 = 0,
};

pub const BundleChildrenSummary = struct {
    count: usize = 0,
    selected_child: ?[]const u8 = null,
};

pub const PullResult = struct {
    schema: []const u8 = pull_result_schema,
    schema_version: u32 = bundle_schema_version,
    source: []const u8,
    bundle_dir: []const u8,
    out_dir: []const u8,
    bundle_digest: DigestRef,
    materialization: ChunkMaterializationSummary,
    rootfs: RootfsMaterializationSummary = .{},
    remote: RemoteBundleCache = .{},
    children: BundleChildrenSummary = .{},
};

pub const BundleChildSummary = struct {
    id: []const u8,
    manifest: []const u8,
};

pub const BundleSelectionSummary = struct {
    kind: []const u8,
    selected_count: usize = 0,
    children: []const BundleChildSummary = &.{},
};

pub const ChunkpackSummary = struct {
    chunk_count: usize,
    pack_count: usize,
    payload_bytes: u64,
};

pub const RootfsBundleSummary = struct {
    artifact_count: usize = 0,
    storage_count: usize = 0,
    exact_bytes_count: usize = 0,
    metadata_only_count: usize = 0,
    object_count: usize = 0,
    payload_bytes: u64 = 0,
};

pub const InspectBundleResult = struct {
    schema: []const u8 = inspect_bundle_schema,
    schema_version: u32 = bundle_schema_version,
    resource_type: resource.Type = .bundle,
    source: []const u8,
    bundle_dir: []const u8,
    bundle_digest: DigestRef,
    indexed: bool,
    parent_manifest: []const u8,
    chunkpack_index: []const u8,
    chunkpack: ChunkpackSummary,
    child_count: usize = 0,
    children: []const BundleChildSummary = &.{},
    selection: BundleSelectionSummary = .{ .kind = "none" },
    rootfs: RootfsBundleSummary = .{},
};

pub fn digestRef(hex: []const u8) DigestRef {
    return .{ .hex = hex };
}

pub fn deinitPullResult(allocator: std.mem.Allocator, result: PullResult) void {
    allocator.free(result.bundle_dir);
    allocator.free(result.bundle_digest.hex);
    if (result.children.selected_child) |child| allocator.free(child);
}

pub fn deinitInspectBundleResult(allocator: std.mem.Allocator, result: InspectBundleResult) void {
    allocator.free(result.bundle_dir);
    allocator.free(result.bundle_digest.hex);
    allocator.free(result.parent_manifest);
    allocator.free(result.chunkpack_index);
    deinitBundleChildSummaries(allocator, result.children);
    deinitBundleSelectionSummary(allocator, result.selection);
}

pub fn deinitBundleSelectionSummary(allocator: std.mem.Allocator, selection: BundleSelectionSummary) void {
    deinitBundleChildSummaries(allocator, selection.children);
}

pub fn deinitBundleChildSummaries(allocator: std.mem.Allocator, children: []const BundleChildSummary) void {
    for (children) |child| {
        allocator.free(child.id);
        allocator.free(child.manifest);
    }
    if (children.len != 0) allocator.free(children);
}
