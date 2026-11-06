//! Product result contracts shared by CLI serializers.

const std = @import("std");
const resource = @import("resource.zig");

pub const inspect_bundle_schema = "spore.bundle.inspect.v1";
pub const bundle_schema_version: u32 = 1;

pub const DigestRef = struct {
    algorithm: []const u8 = "sha256",
    hex: []const u8,
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
