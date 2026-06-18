//! Local spore chunkpack bundles.
//!
//! Bundles are the first distribution shape for spores: a portable manifest
//! plus an index that maps logical BLAKE3 chunks into larger pack blobs. The
//! normal spore manifest remains the machine-state contract; bundle indexes are
//! transport metadata and must be verified before chunks are written back to a
//! CAS directory.

const std = @import("std");
const chunklib = @import("chunk.zig");
const gicv3 = @import("gicv3.zig");
const rootfs_cache = @import("rootfs_cache.zig");
const spore = @import("spore.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Io = std.Io;

const Error = spore.Error;

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
pub const rootfs_index_path = "rootfs.index.json";
pub const rootfs_policy_exact_bytes = "exact-bytes";
pub const rootfs_policy_metadata_only = "metadata-only";

pub const PackOptions = struct {
    io: Io,
    spore_dir: []const u8,
    out_dir: []const u8,
    rootfs_cache_dir: ?[]const u8 = null,
    children_dir: ?[]const u8 = null,
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

pub const RootfsIndex = struct {
    version: u32 = rootfs_index_version,
    artifacts: []RootfsArtifactEntry,
};

pub fn pack(allocator: std.mem.Allocator, options: PackOptions) Error!PackResult {
    if (options.children_dir != null) return packWithChildren(allocator, options);

    const parsed = try spore.loadManifest(allocator, options.spore_dir);
    defer parsed.deinit();
    var manifest = parsed.value;
    manifest.memory.backing = null;
    const plan = try spore.validateMemoryForRam(manifest.memory, @intCast(manifest.platform.ram_size));

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
        const ref = manifest.memory.chunks[i] orelse continue;
        if (seen.contains(ref)) continue;
        seen.put(ref, {}) catch return error.OutOfMemory;

        const range = chunkRange(plan, @intCast(manifest.platform.ram_size), i) catch return error.BadManifest;
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

    const rootfs_payload_bytes = try packRootfsArtifact(allocator, options, manifest);
    try spore.saveManifest(allocator, options.out_dir, manifest);
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
        .rootfs_artifact_count = if (manifest.rootfs == null) 0 else 1,
        .rootfs_payload_bytes = rootfs_payload_bytes,
    };
}

fn packWithChildren(allocator: std.mem.Allocator, options: PackOptions) Error!PackResult {
    const children_dir = options.children_dir orelse return error.BadManifest;
    const children = try listChildDirs(allocator, options.io, children_dir);
    if (children.len == 0) return error.BadManifest;

    try ensureNewDir(try pathZ(allocator, "{s}", .{options.out_dir}));
    try ensureNewDir(try pathZ(allocator, "{s}/{s}", .{ options.out_dir, manifests_dir_path }));
    try ensureNewDir(try pathZ(allocator, "{s}/{s}", .{ options.out_dir, child_manifests_dir_path }));
    try ensureNewDir(try pathZ(allocator, "{s}/chunkpacks", .{options.out_dir}));
    try ensureNewDir(try pathZ(allocator, "{s}/{s}", .{ options.out_dir, rootfs_dir_path }));
    try ensureNewDir(try pathZ(allocator, "{s}/{s}", .{ options.out_dir, rootfs_blake3_dir_path }));

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
    var rootfs_entries = std.array_list.Managed(RootfsArtifactEntry).init(allocator);
    defer rootfs_entries.deinit();
    var bundle_children = std.array_list.Managed(BundleChild).init(allocator);
    defer bundle_children.deinit();

    var payload_bytes: u64 = 0;
    var rootfs_payload_bytes: u64 = 0;
    var total_chunk_count: usize = 0;

    const parsed_parent = try spore.loadManifest(allocator, options.spore_dir);
    defer parsed_parent.deinit();
    var parent_manifest = parsed_parent.value;
    parent_manifest.memory.backing = null;
    total_chunk_count += (try packManifestChunks(
        allocator,
        parent_manifest,
        options.spore_dir,
        pack_fd,
        &seen_chunks,
        &chunk_entries,
        &payload_bytes,
    )).chunk_count;
    rootfs_payload_bytes += try packRootfsArtifactIndexed(allocator, options, parent_manifest, &seen_rootfs, &rootfs_entries);
    try spore.saveManifestPath(
        allocator,
        try pathZ(allocator, "{s}/{s}", .{ options.out_dir, parent_manifest_path }),
        parent_manifest,
    );

    for (children) |child| {
        const child_dir = child.path;
        const parsed_child = try spore.loadManifest(allocator, child_dir);
        defer parsed_child.deinit();
        var child_manifest = parsed_child.value;
        child_manifest.memory.backing = null;
        total_chunk_count += (try packManifestChunks(
            allocator,
            child_manifest,
            child_dir,
            pack_fd,
            &seen_chunks,
            &chunk_entries,
            &payload_bytes,
        )).chunk_count;
        rootfs_payload_bytes += try packRootfsArtifactIndexed(allocator, options, child_manifest, &seen_rootfs, &rootfs_entries);
        const manifest_rel = try childManifestRelPath(allocator, child.id);
        try spore.saveManifestPath(
            allocator,
            try pathZ(allocator, "{s}/{s}", .{ options.out_dir, manifest_rel }),
            child_manifest,
        );
        try bundle_children.append(.{
            .id = child.id,
            .manifest = manifest_rel,
        });
    }

    try saveIndex(allocator, options.out_dir, .{
        .chunk_size = spore.chunk_size,
        .chunks = chunk_entries.items,
    });

    const rootfs_index_rel: ?[]const u8 = if (rootfs_entries.items.len > 0) blk: {
        std.mem.sort(RootfsArtifactEntry, rootfs_entries.items, {}, lessRootfsArtifactEntry);
        try saveRootfsIndex(allocator, options.out_dir, .{
            .artifacts = rootfs_entries.items,
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
        .rootfs_artifact_count = rootfs_entries.items.len,
        .rootfs_payload_bytes = rootfs_payload_bytes,
        .child_count = children.len,
    };
}

pub fn unpack(allocator: std.mem.Allocator, options: UnpackOptions) Error!UnpackResult {
    if (try hasBundleIndex(allocator, options.bundle_dir)) return unpackIndexed(allocator, options);
    if (options.child_id != null) return error.BadManifest;

    const parsed_manifest = try spore.loadManifest(allocator, options.bundle_dir);
    defer parsed_manifest.deinit();
    var manifest = parsed_manifest.value;
    manifest.memory.backing = null;
    const plan = try spore.validateMemoryForRam(manifest.memory, @intCast(manifest.platform.ram_size));

    const parsed_index = try loadIndex(allocator, options.bundle_dir);
    defer parsed_index.deinit();
    try validateIndex(allocator, parsed_index.value);

    var by_id = std.StringHashMap(IndexChunk).init(allocator);
    defer by_id.deinit();
    for (parsed_index.value.chunks) |entry| {
        by_id.put(entry.id, entry) catch return error.OutOfMemory;
    }

    try ensureNewDir(try pathZ(allocator, "{s}", .{options.out_dir}));
    try ensureNewDir(try pathZ(allocator, "{s}/chunks", .{options.out_dir}));

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var unpacked_chunk_count: usize = 0;
    var payload_bytes: u64 = 0;

    var i: usize = 0;
    while (i < plan.chunk_count) : (i += 1) {
        const ref = manifest.memory.chunks[i] orelse continue;
        if (seen.contains(ref)) continue;
        seen.put(ref, {}) catch return error.OutOfMemory;
        const entry = by_id.get(ref) orelse return error.BadManifest;
        const range = chunkRange(plan, @intCast(manifest.platform.ram_size), i) catch return error.BadManifest;
        const expected_size = range.end - range.start;
        if (entry.size != @as(u64, @intCast(expected_size))) return error.BadManifest;
        const source_pack_path = try pathZ(allocator, "{s}/{s}", .{ options.bundle_dir, entry.pack });
        const data = try readFileRange(allocator, source_pack_path, entry.offset, entry.size);
        defer allocator.free(data);
        if (!sha256HexMatches(entry.sha256, data)) return error.BadChunk;
        const id = chunklib.ChunkId.fromHex(ref) catch return error.BadManifest;
        if (!id.matches(data)) return error.BadChunk;
        const chunk_path = try pathZ(allocator, "{s}/chunks/{s}", .{ options.out_dir, ref });
        try writeFileAll(chunk_path, data);
        unpacked_chunk_count += 1;
        payload_bytes += @intCast(data.len);
    }

    const rootfs_payload_bytes = try unpackRootfsArtifact(allocator, options, manifest);
    try spore.saveManifest(allocator, options.out_dir, manifest);
    const bundle_digest = try digestHex(allocator, options.bundle_dir);

    return .{
        .bundle = options.bundle_dir,
        .out_dir = options.out_dir,
        .bundle_digest = bundle_digest,
        .chunk_count = plan.chunk_count,
        .unpacked_chunk_count = unpacked_chunk_count,
        .payload_bytes = payload_bytes,
        .rootfs_artifact_count = if (manifest.rootfs == null) 0 else 1,
        .rootfs_payload_bytes = rootfs_payload_bytes,
    };
}

fn unpackIndexed(allocator: std.mem.Allocator, options: UnpackOptions) Error!UnpackResult {
    const parsed_bundle = try loadBundleIndex(allocator, options.bundle_dir);
    defer parsed_bundle.deinit();
    const bundle_index = parsed_bundle.value;

    const selected_rel = try selectedManifestPath(allocator, bundle_index, options.child_id);
    const parsed_manifest = try spore.loadManifestPath(
        allocator,
        try pathZ(allocator, "{s}/{s}", .{ options.bundle_dir, selected_rel }),
    );
    defer parsed_manifest.deinit();
    var manifest = parsed_manifest.value;
    manifest.memory.backing = null;
    const plan = try spore.validateMemoryForRam(manifest.memory, @intCast(manifest.platform.ram_size));

    const parsed_index = try loadIndex(allocator, options.bundle_dir);
    defer parsed_index.deinit();
    try validateIndex(allocator, parsed_index.value);

    var by_id = std.StringHashMap(IndexChunk).init(allocator);
    defer by_id.deinit();
    for (parsed_index.value.chunks) |entry| {
        by_id.put(entry.id, entry) catch return error.OutOfMemory;
    }

    try ensureNewDir(try pathZ(allocator, "{s}", .{options.out_dir}));
    try ensureNewDir(try pathZ(allocator, "{s}/chunks", .{options.out_dir}));

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var unpacked_chunk_count: usize = 0;
    var payload_bytes: u64 = 0;

    var i: usize = 0;
    while (i < plan.chunk_count) : (i += 1) {
        const ref = manifest.memory.chunks[i] orelse continue;
        if (seen.contains(ref)) continue;
        seen.put(ref, {}) catch return error.OutOfMemory;
        const entry = by_id.get(ref) orelse return error.BadManifest;
        const range = chunkRange(plan, @intCast(manifest.platform.ram_size), i) catch return error.BadManifest;
        const expected_size = range.end - range.start;
        if (entry.size != @as(u64, @intCast(expected_size))) return error.BadManifest;
        const source_pack_path = try pathZ(allocator, "{s}/{s}", .{ options.bundle_dir, entry.pack });
        const data = try readFileRange(allocator, source_pack_path, entry.offset, entry.size);
        defer allocator.free(data);
        if (!sha256HexMatches(entry.sha256, data)) return error.BadChunk;
        const id = chunklib.ChunkId.fromHex(ref) catch return error.BadManifest;
        if (!id.matches(data)) return error.BadChunk;
        const chunk_path = try pathZ(allocator, "{s}/chunks/{s}", .{ options.out_dir, ref });
        try writeFileAll(chunk_path, data);
        unpacked_chunk_count += 1;
        payload_bytes += @intCast(data.len);
    }

    const rootfs_payload_bytes = try unpackRootfsArtifactIndexed(allocator, options, bundle_index, manifest);
    try spore.saveManifest(allocator, options.out_dir, manifest);
    const bundle_digest = try digestHex(allocator, options.bundle_dir);

    return .{
        .bundle = options.bundle_dir,
        .out_dir = options.out_dir,
        .bundle_digest = bundle_digest,
        .chunk_count = plan.chunk_count,
        .unpacked_chunk_count = unpacked_chunk_count,
        .payload_bytes = payload_bytes,
        .rootfs_artifact_count = if (manifest.rootfs == null) 0 else 1,
        .rootfs_payload_bytes = rootfs_payload_bytes,
        .child_count = bundle_index.children.len,
        .selected_child = options.child_id,
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
    const parsed_manifest = try spore.loadManifest(allocator, bundle_dir);
    defer parsed_manifest.deinit();
    if (parsed_manifest.value.rootfs) |rootfs| {
        const rel_path = try rootfsArtifactRelPath(allocator, rootfs.artifact);
        try updateHashWithFile(allocator, &h, bundle_dir, rel_path);
    }

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
        for (parsed_rootfs_index.value.artifacts) |artifact| {
            if (std.mem.eql(u8, artifact.policy, rootfs_policy_exact_bytes)) {
                try updateHashWithFile(allocator, &h, bundle_dir, artifact.path orelse return error.BadManifest);
            }
        }
    }

    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex) catch return error.OutOfMemory;
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
    if (index.children.len == 0) return error.BadManifest;
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
    if (index.artifacts.len == 0) return error.BadManifest;
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

fn packManifestChunks(
    allocator: std.mem.Allocator,
    manifest: spore.Manifest,
    source_dir: []const u8,
    pack_fd: std.c.fd_t,
    seen: *std.StringHashMap(void),
    entries: *std.array_list.Managed(IndexChunk),
    payload_bytes: *u64,
) Error!spore.MemoryPlan {
    const plan = try spore.validateMemoryForRam(manifest.memory, @intCast(manifest.platform.ram_size));
    var i: usize = 0;
    while (i < plan.chunk_count) : (i += 1) {
        const ref = manifest.memory.chunks[i] orelse continue;
        if (seen.contains(ref)) continue;
        const ref_copy = allocator.dupe(u8, ref) catch return error.OutOfMemory;
        seen.put(ref_copy, {}) catch return error.OutOfMemory;

        const range = chunkRange(plan, @intCast(manifest.platform.ram_size), i) catch return error.BadManifest;
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

fn packRootfsArtifact(allocator: std.mem.Allocator, options: PackOptions, manifest: spore.Manifest) Error!u64 {
    const rootfs = manifest.rootfs orelse return 0;
    const cache_root = options.rootfs_cache_dir orelse return error.IoFailed;
    try ensureNewDir(try pathZ(allocator, "{s}/{s}", .{ options.out_dir, rootfs_dir_path }));
    try ensureNewDir(try pathZ(allocator, "{s}/{s}", .{ options.out_dir, rootfs_blake3_dir_path }));
    const source_path = rootfs_cache.digestPath(allocator, cache_root, rootfs.artifact.digest) catch |err| return rootfsError(err);
    const rel_path = try rootfsArtifactRelPath(allocator, rootfs.artifact);
    const dest_path = try pathZ(allocator, "{s}/{s}", .{ options.out_dir, rel_path });
    rootfs_cache.copyVerifiedPath(options.io, allocator, source_path, dest_path, rootfs.artifact, .{
        .source_must_not_be_symlink = true,
        .allow_hardlink = false,
    }) catch |err| return rootfsError(err);
    return rootfs.artifact.size;
}

fn packRootfsArtifactIndexed(
    allocator: std.mem.Allocator,
    options: PackOptions,
    manifest: spore.Manifest,
    seen: *std.StringHashMap(void),
    entries: *std.array_list.Managed(RootfsArtifactEntry),
) Error!u64 {
    const rootfs = manifest.rootfs orelse return 0;
    const cache_root = options.rootfs_cache_dir orelse return error.IoFailed;
    if (seen.contains(rootfs.artifact.digest)) return 0;
    const digest_copy = allocator.dupe(u8, rootfs.artifact.digest) catch return error.OutOfMemory;
    seen.put(digest_copy, {}) catch return error.OutOfMemory;

    const source_path = rootfs_cache.digestPath(allocator, cache_root, rootfs.artifact.digest) catch |err| return rootfsError(err);
    const rel_path = try rootfsArtifactRelPath(allocator, rootfs.artifact);
    const dest_path = try pathZ(allocator, "{s}/{s}", .{ options.out_dir, rel_path });
    rootfs_cache.copyVerifiedPath(options.io, allocator, source_path, dest_path, rootfs.artifact, .{
        .source_must_not_be_symlink = true,
        .allow_hardlink = false,
    }) catch |err| return rootfsError(err);
    try entries.append(.{
        .digest = digest_copy,
        .size = rootfs.artifact.size,
        .format = spore.rootfs_artifact_format_ext4,
        .policy = rootfs_policy_exact_bytes,
        .path = rel_path,
    });
    return rootfs.artifact.size;
}

fn unpackRootfsArtifact(allocator: std.mem.Allocator, options: UnpackOptions, manifest: spore.Manifest) Error!u64 {
    const rootfs = manifest.rootfs orelse return 0;
    const cache_root = options.rootfs_cache_dir orelse return error.IoFailed;
    const rel_path = try rootfsArtifactRelPath(allocator, rootfs.artifact);
    const source_path = try pathZ(allocator, "{s}/{s}", .{ options.bundle_dir, rel_path });
    rootfs_cache.verifyPath(options.io, allocator, source_path, rootfs.artifact, true) catch |err| return rootfsError(err);
    rootfs_cache.installExpectedPath(options.io, allocator, cache_root, source_path, rootfs.artifact, .{
        .source_must_not_be_symlink = true,
        .allow_hardlink = false,
    }) catch |err| return rootfsError(err);
    return rootfs.artifact.size;
}

fn unpackRootfsArtifactIndexed(
    allocator: std.mem.Allocator,
    options: UnpackOptions,
    bundle_index: BundleIndex,
    manifest: spore.Manifest,
) Error!u64 {
    const rootfs = manifest.rootfs orelse return 0;
    const cache_root = options.rootfs_cache_dir orelse return error.IoFailed;
    if (bundle_index.rootfs_index == null) return error.BadManifest;
    const parsed_rootfs_index = try loadRootfsIndex(allocator, options.bundle_dir);
    defer parsed_rootfs_index.deinit();
    const entry = findRootfsEntry(parsed_rootfs_index.value, rootfs.artifact.digest) orelse return error.BadManifest;
    if (entry.size != rootfs.artifact.size) return error.BadManifest;
    if (!std.mem.eql(u8, entry.format, rootfs.artifact.format)) return error.BadManifest;
    if (std.mem.eql(u8, entry.policy, rootfs_policy_metadata_only)) return error.BadManifest;
    if (!std.mem.eql(u8, entry.policy, rootfs_policy_exact_bytes)) return error.BadManifest;
    const rel_path = entry.path orelse return error.BadManifest;
    const source_path = try pathZ(allocator, "{s}/{s}", .{ options.bundle_dir, rel_path });
    rootfs_cache.verifyPath(options.io, allocator, source_path, rootfs.artifact, true) catch |err| return rootfsError(err);
    rootfs_cache.installExpectedPath(options.io, allocator, cache_root, source_path, rootfs.artifact, .{
        .source_must_not_be_symlink = true,
        .allow_hardlink = false,
    }) catch |err| return rootfsError(err);
    return rootfs.artifact.size;
}

fn findRootfsEntry(index: RootfsIndex, digest: []const u8) ?RootfsArtifactEntry {
    for (index.artifacts) |entry| {
        if (std.mem.eql(u8, entry.digest, digest)) return entry;
    }
    return null;
}

fn rootfsArtifactRelPath(allocator: std.mem.Allocator, artifact: spore.RootfsArtifactRef) Error![]const u8 {
    try spore.validateRootfsDigest(artifact.digest);
    if (!std.mem.eql(u8, artifact.format, spore.rootfs_artifact_format_ext4)) return error.BadManifest;
    const hex = artifact.digest[spore.rootfs_digest_prefix.len..];
    return std.fmt.allocPrint(allocator, "{s}/{s}.ext4", .{ rootfs_blake3_dir_path, hex }) catch return error.OutOfMemory;
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

fn rootfsError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadManifest => error.BadManifest,
        error.RootFSDigestMismatch,
        error.RootFSDigestCacheMiss,
        error.RootFSOpenFailed,
        error.BadPathName,
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
    const rootfs_index = try loadRootfsIndex(arena, bundle_dir);
    defer rootfs_index.deinit();
    try std.testing.expectEqual(@as(usize, 1), rootfs_index.value.artifacts.len);
    try std.testing.expectEqualStrings(rootfs_policy_exact_bytes, rootfs_index.value.artifacts[0].policy);
    try std.testing.expectEqualStrings(artifact.digest, rootfs_index.value.artifacts[0].digest);

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

test "unpack rejects metadata-only rootfs policy for materialized children" {
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
    @memset(ram, 0x45);
    const memory = try spore.saveMemory(arena, parent_dir, ram);
    try writeFileAll(rootfs_source_path, "rootfs metadata only bytes");
    const artifact = try rootfs_cache.cacheByDigestPath(io, arena, pack_cache_root, rootfs_source_path);
    try spore.saveManifest(arena, parent_dir, testRootfsManifest(memory, ram.len, 61, artifact));
    _ = try spore.fork(arena, .{ .parent_dir = parent_dir, .out_dir = children_dir, .count = 1 });
    _ = try pack(arena, .{
        .io = io,
        .spore_dir = parent_dir,
        .out_dir = bundle_dir,
        .rootfs_cache_dir = pack_cache_root,
        .children_dir = children_dir,
    });

    var metadata_only = [_]RootfsArtifactEntry{.{
        .digest = artifact.digest,
        .size = artifact.size,
        .policy = rootfs_policy_metadata_only,
        .path = null,
    }};
    try saveRootfsIndex(arena, bundle_dir, .{ .artifacts = &metadata_only });
    try std.testing.expectError(error.BadManifest, unpack(arena, .{
        .io = io,
        .bundle_dir = bundle_dir,
        .out_dir = out_dir,
        .rootfs_cache_dir = unpack_cache_root,
        .child_id = "000000",
    }));
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
}
