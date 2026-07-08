//! Portable sealed disk layers for writable block devices.
//!
//! A running VM writes into a local COW head. Snapshot sealing turns dirty
//! clusters into verified disk objects plus a small content-addressed layer
//! index. Restore reads newest layer to oldest, then falls back to the
//! immutable rootfs base.

const std = @import("std");
const builtin = @import("builtin");
const block_source = @import("block_source.zig");
const chunk_mapped_disk = @import("chunk_mapped_disk.zig");
const chunk = @import("chunk.zig");
const cow_disk = @import("cow_disk.zig");
const spore = @import("spore.zig");

pub const default_cluster_size: u64 = 4096;
pub const layer_index_max_bytes: usize = 64 * 1024 * 1024;

extern "c" fn mkstemp(template: [*:0]u8) c_int;

pub const Error = spore.Error || chunk_mapped_disk.Error || cow_disk.Error || error{
    ShortRead,
    ShortWrite,
};

pub const SealResult = struct {
    layer_ref: []const u8,
    layer: spore.DiskLayer,
    json_size: usize,
};

pub const TempOverlay = struct {
    fd: std.c.fd_t,

    pub fn deinit(self: *TempOverlay) void {
        if (self.fd >= 0) {
            _ = std.c.close(self.fd);
            self.fd = -1;
        }
    }
};

pub const LayeredCowDisk = struct {
    allocator: std.mem.Allocator,
    dir: []const u8,
    base: block_source.FileBlockSource,
    overlay_fd: std.c.fd_t,
    size: u64,
    cluster_size: u64,
    layers: []const spore.DiskLayer,
    dirty: []bool,

    pub fn init(
        allocator: std.mem.Allocator,
        dir: []const u8,
        base: block_source.FileBlockSource,
        overlay_fd: std.c.fd_t,
        disk: spore.Disk,
        layers: []const spore.DiskLayer,
    ) Error!LayeredCowDisk {
        // Takes ownership of the cloned layer chain on success.
        if (layers.len == 0) return error.BadManifest;
        if (base.capacityBytes() < disk.size) return error.BadManifest;
        const cluster_size = layers[0].cluster_size;
        for (layers) |layer| {
            try spore.validateDiskLayer(layer);
            if (layer.disk_size != disk.size or layer.cluster_size != cluster_size) return error.BadManifest;
        }
        const cluster_count = try spore.diskClusterCount(disk.size, cluster_size);
        if (cluster_count > std.math.maxInt(usize)) return error.BadManifest;
        const overlay_size = std.math.cast(std.c.off_t, disk.size) orelse return error.BadManifest;
        if (std.c.ftruncate(overlay_fd, overlay_size) != 0) return error.IoFailed;
        const dirty = try allocator.alloc(bool, @intCast(cluster_count));
        @memset(dirty, false);
        return .{
            .allocator = allocator,
            .dir = dir,
            .base = base,
            .overlay_fd = overlay_fd,
            .size = disk.size,
            .cluster_size = cluster_size,
            .layers = layers,
            .dirty = dirty,
        };
    }

    pub fn deinit(self: *LayeredCowDisk) void {
        freeLayerChain(self.allocator, self.layers);
        self.allocator.free(self.dirty);
        self.* = undefined;
    }

    pub fn capacityBytes(self: LayeredCowDisk) u64 {
        return self.size;
    }

    pub fn dirtyClusterCount(self: LayeredCowDisk) usize {
        var count: usize = 0;
        for (self.dirty) |is_dirty| {
            if (is_dirty) count += 1;
        }
        return count;
    }

    pub fn clusterSize(self: LayeredCowDisk) u64 {
        return self.cluster_size;
    }

    pub fn clusterCount(self: LayeredCowDisk) usize {
        return self.dirty.len;
    }

    pub fn clusterLen(self: LayeredCowDisk, cluster_index: usize) Error!usize {
        return spore.diskClusterLen(self.size, self.cluster_size, @intCast(cluster_index));
    }

    pub fn isDirtyCluster(self: LayeredCowDisk, cluster_index: usize) Error!bool {
        if (cluster_index >= self.dirty.len) return error.OutOfRange;
        return self.dirty[cluster_index];
    }

    pub fn readCluster(self: *LayeredCowDisk, cluster_index: usize, buf: []u8) Error!void {
        const len = try self.clusterLen(cluster_index);
        if (buf.len != len) return error.OutOfRange;
        const offset = std.math.mul(u64, cluster_index, self.cluster_size) catch return error.OutOfRange;
        try self.readAt(buf, offset);
    }

    pub fn readAt(self: *LayeredCowDisk, buf: []u8, offset: u64) Error!void {
        try self.checkRange(buf.len, offset);
        var cluster_buf: ?[]u8 = null;
        defer if (cluster_buf) |scratch| self.allocator.free(scratch);

        var cursor: usize = 0;
        while (cursor < buf.len) {
            const absolute = offset + cursor;
            const span = try self.spanFor(absolute, buf.len - cursor);
            const target = buf[cursor..][0..span.len];
            if (self.dirty[span.cluster_index]) {
                try readExact(self.overlay_fd, target, absolute);
            } else {
                switch (self.layerSource(span.cluster_index)) {
                    .base => try self.base.readAt(target, absolute),
                    .zero => @memset(target, 0),
                    .object => |digest| {
                        const cluster_len = try self.clusterLen(span.cluster_index);
                        const scratch = try clusterScratch(self.allocator, &cluster_buf, cluster_len);
                        try readDiskObject(self.allocator, self.dir, digest, scratch);
                        const cluster_offset: usize = @intCast(absolute % self.cluster_size);
                        @memcpy(target, scratch[cluster_offset..][0..span.len]);
                    },
                }
            }
            cursor += span.len;
        }
    }

    pub fn writeAt(self: *LayeredCowDisk, buf: []const u8, offset: u64) Error!void {
        try self.checkRange(buf.len, offset);
        var cursor: usize = 0;
        while (cursor < buf.len) {
            const absolute = offset + cursor;
            const span = try self.spanFor(absolute, buf.len - cursor);
            if (!self.dirty[span.cluster_index]) {
                try self.seedCluster(span.cluster_index);
            }
            try writeExact(self.overlay_fd, buf[cursor..][0..span.len], absolute);
            self.dirty[span.cluster_index] = true;
            cursor += span.len;
        }
    }

    pub fn flush(self: *LayeredCowDisk) Error!void {
        if (std.c.fsync(self.overlay_fd) != 0) return error.IoFailed;
    }

    fn checkRange(self: LayeredCowDisk, len: usize, offset: u64) Error!void {
        const end = std.math.add(u64, offset, len) catch return error.OutOfRange;
        if (end > self.size) return error.OutOfRange;
    }

    fn spanFor(self: LayeredCowDisk, offset: u64, remaining: usize) Error!Span {
        const cluster_index_u64 = offset / self.cluster_size;
        if (cluster_index_u64 > std.math.maxInt(usize)) return error.OutOfRange;
        const cluster_offset = offset % self.cluster_size;
        const left_in_cluster = self.cluster_size - cluster_offset;
        const len = @min(remaining, std.math.cast(usize, left_in_cluster) orelse return error.BadManifest);
        return .{
            .cluster_index = @intCast(cluster_index_u64),
            .len = len,
        };
    }

    fn layerSource(self: LayeredCowDisk, cluster_index: usize) LayerSource {
        const logical_cluster: u64 = @intCast(cluster_index);
        var layer_index = self.layers.len;
        while (layer_index > 0) {
            layer_index -= 1;
            const layer = self.layers[layer_index];
            if (spore.findDiskExtent(layer, logical_cluster)) |extent| return .{ .object = extent.digest };
            if (spore.diskLayerHasZeroCluster(layer, logical_cluster)) return .zero;
        }
        return .base;
    }

    fn seedCluster(self: *LayeredCowDisk, cluster_index: usize) Error!void {
        const len = try self.clusterLen(cluster_index);
        const offset = std.math.mul(u64, cluster_index, self.cluster_size) catch return error.OutOfRange;
        const buf = try self.allocator.alloc(u8, len);
        defer self.allocator.free(buf);
        try readClusterFromChain(self.allocator, self.dir, self.base, self.layers, @intCast(cluster_index), buf);
        try writeExact(self.overlay_fd, buf, offset);
    }
};

pub const ActiveHead = union(enum) {
    chunk_mapped: *chunk_mapped_disk.ChunkMappedDisk,
    cow: *cow_disk.CowDisk,
    layered_cow: *LayeredCowDisk,

    pub fn dirtyClusterCount(self: ActiveHead) usize {
        return switch (self) {
            .chunk_mapped => |disk| disk.dirtyClusterCount(),
            .cow => |disk| disk.dirtyClusterCount(),
            .layered_cow => |disk| disk.dirtyClusterCount(),
        };
    }

    pub fn seal(self: ActiveHead, allocator: std.mem.Allocator, dir: []const u8) Error!SealResult {
        return switch (self) {
            .chunk_mapped => |disk| sealDisk(allocator, dir, disk),
            .cow => |disk| sealDisk(allocator, dir, disk),
            .layered_cow => |disk| sealDisk(allocator, dir, disk),
        };
    }

    pub fn sourceDir(self: ActiveHead) ?[]const u8 {
        return switch (self) {
            .chunk_mapped => null,
            .cow => null,
            .layered_cow => |disk| disk.dir,
        };
    }
};

pub const SnapshotState = struct {
    base: spore.Disk,
    active: ActiveHead,

    pub fn finish(self: SnapshotState, allocator: std.mem.Allocator, dir: []const u8) Error!?spore.Disk {
        if (self.active.sourceDir()) |source_dir| {
            try copyLayerChain(allocator, source_dir, dir, self.base);
        }
        if (self.active.dirtyClusterCount() == 0) {
            if (std.mem.eql(u8, self.base.kind, spore.disk_kind_chunk_index)) return try cloneDisk(allocator, self.base);
            if (self.base.layers.len == 0) return null;
            return try cloneDisk(allocator, self.base);
        }
        switch (self.active) {
            .chunk_mapped => |disk| return try disk.snapshotIndex(dir, self.base.device),
            else => {},
        }

        const sealed = try self.active.seal(allocator, dir);
        return try appendLayer(allocator, self.base, sealed.layer_ref);
    }
};

pub fn createTempOverlay(allocator: std.mem.Allocator) Error!TempOverlay {
    const template = try allocator.dupeZ(u8, "/tmp/sporevm-disk-head-XXXXXX");
    defer allocator.free(template);
    const fd = mkstemp(template.ptr);
    if (fd < 0) return error.IoFailed;
    _ = std.c.unlink(template.ptr);
    return .{ .fd = fd };
}

pub fn diskFromRootfs(rootfs: spore.Rootfs) spore.Disk {
    return .{
        .kind = spore.disk_kind_cow_block,
        .device = rootfs.device,
        .size = spore.effectiveRootfsLogicalSize(rootfs),
        .base = spore.effectiveRootfsBaseIdentity(rootfs),
        .layers = &.{},
    };
}

pub fn cloneDisk(allocator: std.mem.Allocator, disk: spore.Disk) Error!spore.Disk {
    const layers = try allocator.alloc([]const u8, disk.layers.len);
    errdefer allocator.free(layers);
    for (disk.layers, 0..) |layer_ref, i| {
        layers[i] = try allocator.dupe(u8, layer_ref);
    }
    return .{
        .kind = try allocator.dupe(u8, disk.kind),
        .device = try spore.cloneRootfsDevice(allocator, disk.device),
        .size = disk.size,
        .base = try allocator.dupe(u8, disk.base),
        .chunk_size = disk.chunk_size,
        .hash_algorithm = try allocator.dupe(u8, disk.hash_algorithm),
        .object_namespace = try allocator.dupe(u8, disk.object_namespace),
        .layers = layers,
    };
}

pub fn loadLayerChain(allocator: std.mem.Allocator, dir: []const u8, disk: spore.Disk) Error![]spore.DiskLayer {
    const layers = try allocator.alloc(spore.DiskLayer, disk.layers.len);
    var initialized: usize = 0;
    errdefer {
        for (layers[0..initialized]) |layer| freeLayer(allocator, layer);
        allocator.free(layers);
    }
    for (disk.layers, 0..) |layer_ref, i| {
        const parsed = try loadLayer(allocator, dir, layer_ref);
        defer parsed.deinit();
        layers[i] = try cloneLayer(allocator, parsed.value);
        initialized += 1;
        if (layers[i].disk_size != disk.size) return error.BadManifest;
    }
    return layers;
}

pub fn freeLayerChain(allocator: std.mem.Allocator, layers: []const spore.DiskLayer) void {
    for (layers) |layer| {
        freeLayer(allocator, layer);
    }
    allocator.free(layers);
}

fn freeLayer(allocator: std.mem.Allocator, layer: spore.DiskLayer) void {
    allocator.free(layer.kind);
    for (layer.extents) |extent| {
        allocator.free(extent.digest);
    }
    allocator.free(layer.extents);
    allocator.free(layer.zero_clusters);
}

fn appendLayer(allocator: std.mem.Allocator, disk: spore.Disk, layer_ref: []const u8) Error!spore.Disk {
    const layers = try allocator.alloc([]const u8, disk.layers.len + 1);
    errdefer allocator.free(layers);
    for (disk.layers, 0..) |existing_ref, i| {
        layers[i] = try allocator.dupe(u8, existing_ref);
    }
    layers[disk.layers.len] = try allocator.dupe(u8, layer_ref);
    return .{
        .kind = try allocator.dupe(u8, disk.kind),
        .device = try spore.cloneRootfsDevice(allocator, disk.device),
        .size = disk.size,
        .base = try allocator.dupe(u8, disk.base),
        .chunk_size = disk.chunk_size,
        .hash_algorithm = try allocator.dupe(u8, disk.hash_algorithm),
        .object_namespace = try allocator.dupe(u8, disk.object_namespace),
        .layers = layers,
    };
}

fn cloneLayer(allocator: std.mem.Allocator, layer: spore.DiskLayer) Error!spore.DiskLayer {
    const extents = try allocator.alloc(spore.DiskLayerExtent, layer.extents.len);
    var initialized: usize = 0;
    errdefer {
        for (extents[0..initialized]) |extent| {
            allocator.free(extent.digest);
        }
        allocator.free(extents);
    }
    for (layer.extents, 0..) |extent, i| {
        extents[i] = .{
            .logical_cluster = extent.logical_cluster,
            .digest = try allocator.dupe(u8, extent.digest),
        };
        initialized += 1;
    }
    const zero_clusters = try allocator.dupe(u64, layer.zero_clusters);
    errdefer allocator.free(zero_clusters);
    const kind = try allocator.dupe(u8, layer.kind);
    return .{
        .kind = kind,
        .cluster_size = layer.cluster_size,
        .disk_size = layer.disk_size,
        .extents = extents,
        .zero_clusters = zero_clusters,
    };
}

const Span = struct {
    cluster_index: usize,
    len: usize,
};

const LayerSource = union(enum) {
    base,
    zero,
    object: []const u8,
};

pub fn sealCowDisk(allocator: std.mem.Allocator, dir: []const u8, disk: *cow_disk.CowDisk) Error!SealResult {
    return sealDisk(allocator, dir, disk);
}

fn sealDisk(allocator: std.mem.Allocator, dir: []const u8, disk: anytype) Error!SealResult {
    try ensureStoreDirs(allocator, dir);

    var extents: std.ArrayList(spore.DiskLayerExtent) = .empty;
    errdefer {
        for (extents.items) |extent| allocator.free(extent.digest);
        extents.deinit(allocator);
    }
    var zero_clusters: std.ArrayList(u64) = .empty;
    errdefer zero_clusters.deinit(allocator);

    var cluster_buf: ?[]u8 = null;
    defer if (cluster_buf) |buf| allocator.free(buf);

    var cluster_index: usize = 0;
    while (cluster_index < disk.clusterCount()) : (cluster_index += 1) {
        if (!try disk.isDirtyCluster(cluster_index)) continue;

        const len = try disk.clusterLen(cluster_index);
        if (cluster_buf == null) {
            const cluster_size = std.math.cast(usize, disk.clusterSize()) orelse return error.BadManifest;
            cluster_buf = try allocator.alloc(u8, cluster_size);
        }
        if (len > cluster_buf.?.len) return error.BadManifest;
        const buf = cluster_buf.?[0..len];
        try disk.readCluster(cluster_index, buf);

        if (std.mem.allEqual(u8, buf, 0)) {
            try zero_clusters.append(allocator, @intCast(cluster_index));
            continue;
        }

        const digest = try digestRefAlloc(allocator, buf);
        errdefer allocator.free(digest);
        const object_path = try diskObjectPath(allocator, dir, digest);
        defer allocator.free(object_path);
        try writeFileAllIfMissing(allocator, object_path, buf);
        try extents.append(allocator, .{
            .logical_cluster = @intCast(cluster_index),
            .digest = digest,
        });
    }

    const extent_slice = try extents.toOwnedSlice(allocator);
    errdefer {
        for (extent_slice) |extent| allocator.free(extent.digest);
        allocator.free(extent_slice);
    }
    const zero_slice = try zero_clusters.toOwnedSlice(allocator);
    errdefer allocator.free(zero_slice);

    const layer = spore.DiskLayer{
        .cluster_size = disk.clusterSize(),
        .disk_size = disk.capacityBytes(),
        .extents = extent_slice,
        .zero_clusters = zero_slice,
    };
    try spore.validateDiskLayer(layer);

    const json = std.json.Stringify.valueAlloc(allocator, layer, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
    defer allocator.free(json);
    const layer_ref = try digestRefAlloc(allocator, json);
    errdefer allocator.free(layer_ref);
    const layer_path = try diskLayerPath(allocator, dir, layer_ref);
    defer allocator.free(layer_path);
    try writeFileAllIfMissing(allocator, layer_path, json);

    return .{
        .layer_ref = layer_ref,
        .layer = layer,
        .json_size = json.len,
    };
}

pub fn loadLayer(allocator: std.mem.Allocator, dir: []const u8, layer_ref: []const u8) Error!std.json.Parsed(spore.DiskLayer) {
    const path = try diskLayerPath(allocator, dir, layer_ref);
    defer allocator.free(path);
    const bytes = try readFileAll(allocator, path, layer_index_max_bytes);
    defer allocator.free(bytes);

    const id = chunk.ChunkId.fromHex(try spore.diskDigestHex(layer_ref)) catch return error.BadManifest;
    if (!id.matches(bytes)) return error.BadChunk;

    const parsed = std.json.parseFromSlice(spore.DiskLayer, allocator, bytes, .{
        .allocate = .alloc_always,
    }) catch return error.BadManifest;
    errdefer parsed.deinit();
    try spore.validateDiskLayer(parsed.value);
    return parsed;
}

pub fn copyLayerChain(allocator: std.mem.Allocator, source_dir: []const u8, target_dir: []const u8, disk: spore.Disk) Error!void {
    if (disk.layers.len == 0) return;
    try ensureStoreDirs(allocator, target_dir);

    for (disk.layers) |layer_ref| {
        try copyLayer(allocator, source_dir, target_dir, layer_ref, disk.size);
    }
}

fn copyLayer(
    allocator: std.mem.Allocator,
    source_dir: []const u8,
    target_dir: []const u8,
    layer_ref: []const u8,
    disk_size: u64,
) Error!void {
    const source_layer_path = try diskLayerPath(allocator, source_dir, layer_ref);
    defer allocator.free(source_layer_path);
    const layer_bytes = try readFileAll(allocator, source_layer_path, layer_index_max_bytes);
    defer allocator.free(layer_bytes);

    const layer_id = chunk.ChunkId.fromHex(try spore.diskDigestHex(layer_ref)) catch return error.BadManifest;
    if (!layer_id.matches(layer_bytes)) return error.BadChunk;

    const parsed = std.json.parseFromSlice(spore.DiskLayer, allocator, layer_bytes, .{
        .allocate = .alloc_always,
    }) catch return error.BadManifest;
    defer parsed.deinit();
    try spore.validateDiskLayer(parsed.value);
    if (parsed.value.disk_size != disk_size) return error.BadManifest;

    const target_layer_path = try diskLayerPath(allocator, target_dir, layer_ref);
    defer allocator.free(target_layer_path);
    try writeFileAllIfMissing(allocator, target_layer_path, layer_bytes);

    for (parsed.value.extents) |extent| {
        try copyLayerExtent(allocator, source_dir, target_dir, parsed.value, extent);
    }
}

fn copyLayerExtent(
    allocator: std.mem.Allocator,
    source_dir: []const u8,
    target_dir: []const u8,
    layer: spore.DiskLayer,
    extent: spore.DiskLayerExtent,
) Error!void {
    const len = try spore.diskClusterLen(layer.disk_size, layer.cluster_size, extent.logical_cluster);
    const data = try allocator.alloc(u8, len);
    defer allocator.free(data);
    try readDiskObject(allocator, source_dir, extent.digest, data);
    const target_object_path = try diskObjectPath(allocator, target_dir, extent.digest);
    defer allocator.free(target_object_path);
    try writeFileAllIfMissing(allocator, target_object_path, data);
}

pub fn readAt(
    allocator: std.mem.Allocator,
    dir: []const u8,
    base: block_source.FileBlockSource,
    layers: []const spore.DiskLayer,
    buf: []u8,
    offset: u64,
) Error!void {
    if (layers.len == 0) {
        try base.readAt(buf, offset);
        return;
    }

    const disk_size = layers[0].disk_size;
    const cluster_size = layers[0].cluster_size;
    const end = std.math.add(u64, offset, buf.len) catch return error.BadManifest;
    if (end > disk_size) return error.BadManifest;
    for (layers) |layer| {
        try spore.validateDiskLayer(layer);
        if (layer.disk_size != disk_size or layer.cluster_size != cluster_size) return error.BadManifest;
    }

    var cluster_buf: ?[]u8 = null;
    defer if (cluster_buf) |scratch| allocator.free(scratch);

    var cursor: usize = 0;
    while (cursor < buf.len) {
        const absolute = offset + cursor;
        const logical_cluster = absolute / cluster_size;
        const cluster_start = logical_cluster * cluster_size;
        const cluster_offset = absolute - cluster_start;
        const cluster_len = try spore.diskClusterLen(disk_size, cluster_size, logical_cluster);
        const span_len = @min(buf.len - cursor, cluster_len - @as(usize, @intCast(cluster_offset)));

        const scratch = try clusterScratch(allocator, &cluster_buf, cluster_len);
        try readClusterFromChain(allocator, dir, base, layers, logical_cluster, scratch);
        @memcpy(buf[cursor..][0..span_len], scratch[@intCast(cluster_offset)..][0..span_len]);
        cursor += span_len;
    }
}

pub fn diskObjectPath(allocator: std.mem.Allocator, dir: []const u8, digest: []const u8) Error![:0]const u8 {
    const hex = try spore.diskDigestHex(digest);
    return pathZ(allocator, "{s}/diskobjects/blake3/{s}.cluster", .{ dir, hex });
}

pub fn diskLayerPath(allocator: std.mem.Allocator, dir: []const u8, layer_ref: []const u8) Error![:0]const u8 {
    const hex = try spore.diskDigestHex(layer_ref);
    return pathZ(allocator, "{s}/disklayers/blake3/{s}.json", .{ dir, hex });
}

fn readClusterFromChain(
    allocator: std.mem.Allocator,
    dir: []const u8,
    base: block_source.FileBlockSource,
    layers: []const spore.DiskLayer,
    logical_cluster: u64,
    target: []u8,
) Error!void {
    var layer_index = layers.len;
    while (layer_index > 0) {
        layer_index -= 1;
        const layer = layers[layer_index];
        if (spore.findDiskExtent(layer, logical_cluster)) |extent| {
            try readDiskObject(allocator, dir, extent.digest, target);
            return;
        }
        if (spore.diskLayerHasZeroCluster(layer, logical_cluster)) {
            @memset(target, 0);
            return;
        }
    }

    const offset = std.math.mul(u64, logical_cluster, layers[0].cluster_size) catch return error.BadManifest;
    try base.readAt(target, offset);
}

fn clusterScratch(allocator: std.mem.Allocator, scratch: *?[]u8, len: usize) Error![]u8 {
    if (scratch.*) |buf| {
        if (buf.len >= len) return buf[0..len];
        allocator.free(buf);
        scratch.* = null;
    }
    const buf = try allocator.alloc(u8, len);
    scratch.* = buf;
    return buf;
}

fn readDiskObject(allocator: std.mem.Allocator, dir: []const u8, digest: []const u8, target: []u8) Error!void {
    const path = try diskObjectPath(allocator, dir, digest);
    defer allocator.free(path);
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);
    const size = try fstatRegularSize(fd);
    if (size != target.len) return error.BadChunk;
    try readExact(fd, target, 0);
    const id = chunk.ChunkId.fromHex(try spore.diskDigestHex(digest)) catch return error.BadManifest;
    if (!id.matches(target)) return error.BadChunk;
}

fn digestRefAlloc(allocator: std.mem.Allocator, data: []const u8) Error![]const u8 {
    const id = chunk.ChunkId.fromContents(data);
    const hex = id.toHex();
    return std.fmt.allocPrint(allocator, "blake3:{s}", .{hex[0..]}) catch return error.OutOfMemory;
}

fn ensureStoreDirs(allocator: std.mem.Allocator, dir: []const u8) Error!void {
    try ensureStoreDir(allocator, "{s}", .{dir});
    try ensureStoreDir(allocator, "{s}/diskobjects", .{dir});
    try ensureStoreDir(allocator, "{s}/diskobjects/blake3", .{dir});
    try ensureStoreDir(allocator, "{s}/disklayers", .{dir});
    try ensureStoreDir(allocator, "{s}/disklayers/blake3", .{dir});
}

fn ensureStoreDir(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Error!void {
    const path = try pathZ(allocator, fmt, args);
    defer allocator.free(path);
    try ensureDir(path);
}

fn ensureDir(path: [:0]const u8) Error!void {
    if (std.c.mkdir(path, 0o755) != 0) {
        if (std.c.access(path, 0) != 0) return error.IoFailed;
    }
}

fn writeFileAllIfMissing(allocator: std.mem.Allocator, path: [:0]const u8, data: []const u8) Error!void {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(c_uint, 0o644));
    if (fd < 0) {
        if (std.c.errno(fd) == .EXIST) {
            const max = std.math.add(usize, data.len, 1) catch return error.BadChunk;
            const existing = try readFileAll(allocator, path, max);
            defer allocator.free(existing);
            if (!std.mem.eql(u8, existing, data)) return error.BadChunk;
            return;
        }
        return error.IoFailed;
    }
    defer _ = std.c.close(fd);
    try writeAllFd(fd, data);
}

fn writeFileAll(path: [:0]const u8, data: []const u8) Error!void {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);
    try writeAllFd(fd, data);
}

fn writeAllFd(fd: std.c.fd_t, data: []const u8) Error!void {
    var done: usize = 0;
    while (done < data.len) {
        const n = std.c.write(fd, data.ptr + done, data.len - done);
        if (n <= 0) return error.ShortWrite;
        done += @intCast(n);
    }
}

fn readFileAll(allocator: std.mem.Allocator, path: [:0]const u8, max: usize) Error![]u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);

    const size = try fstatRegularSize(fd);
    if (size > max) return error.BadChunk;

    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    try readExact(fd, buf, 0);
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

fn readExact(fd: std.c.fd_t, buf: []u8, offset: u64) Error!void {
    var done: usize = 0;
    while (done < buf.len) {
        const absolute = std.math.add(u64, offset, done) catch return error.BadManifest;
        const file_offset = std.math.cast(std.c.off_t, absolute) orelse return error.BadManifest;
        const n = std.c.pread(fd, buf.ptr + done, buf.len - done, file_offset);
        if (n <= 0) return error.ShortRead;
        done += @intCast(n);
    }
}

fn writeExact(fd: std.c.fd_t, buf: []const u8, offset: u64) Error!void {
    var done: usize = 0;
    while (done < buf.len) {
        const absolute = std.math.add(u64, offset, done) catch return error.BadManifest;
        const file_offset = std.math.cast(std.c.off_t, absolute) orelse return error.BadManifest;
        const n = std.c.pwrite(fd, buf.ptr + done, buf.len - done, file_offset);
        if (n <= 0) return error.ShortWrite;
        done += @intCast(n);
    }
}

fn pathZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Error![:0]const u8 {
    return std.fmt.allocPrintSentinel(allocator, fmt, args, 0) catch error.OutOfMemory;
}

// --- tests ------------------------------------------------------------------

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

fn testDir(allocator: std.mem.Allocator) ![]const u8 {
    const tmpl = "/tmp/sporevm-disk-layer-test-XXXXXX";
    const buf = try allocator.dupeZ(u8, tmpl);
    if (mkdtemp(buf) == null) return error.IoFailed;
    return buf;
}

fn openTestFile(path: [:0]const u8, mode: std.c.O) Error!std.c.fd_t {
    const fd = std.c.open(path, mode, @as(c_uint, 0o644));
    if (fd < 0) return error.IoFailed;
    return fd;
}

const PeakLiveAllocator = struct {
    backing: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,
    limit: usize = std.math.maxInt(usize),

    fn allocator(self: *PeakLiveAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PeakLiveAllocator = @ptrCast(@alignCast(ctx));
        const next = std.math.add(usize, self.live, len) catch return null;
        if (next > self.limit) return null;
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.live = next;
        self.peak = @max(self.peak, self.live);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *PeakLiveAllocator = @ptrCast(@alignCast(ctx));
        if (new_len == memory.len) return true;
        if (new_len > memory.len) {
            const next = std.math.add(usize, self.live, new_len - memory.len) catch return false;
            if (next > self.limit) return false;
            if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
            self.live = next;
            self.peak = @max(self.peak, self.live);
            return true;
        }
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.live -= memory.len - new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *PeakLiveAllocator = @ptrCast(@alignCast(ctx));
        if (new_len == memory.len) return memory.ptr;
        if (new_len > memory.len) {
            const next = std.math.add(usize, self.live, new_len - memory.len) catch return null;
            if (next > self.limit) return null;
            const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
            self.live = next;
            self.peak = @max(self.peak, self.live);
            return ptr;
        }
        const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.live -= memory.len - new_len;
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *PeakLiveAllocator = @ptrCast(@alignCast(ctx));
        std.debug.assert(self.live >= memory.len);
        self.live -= memory.len;
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

fn expectPatternedClusters(bytes: []const u8, cluster_size: usize, cluster_count: usize) !void {
    var cluster_index: usize = 0;
    while (cluster_index < cluster_count) : (cluster_index += 1) {
        const start = cluster_index * cluster_size;
        const end = start + cluster_size;
        try std.testing.expect(std.mem.allEqual(u8, bytes[start..end], @intCast(cluster_index + 1)));
    }
}

fn writeDiskLayerForTest(allocator: std.mem.Allocator, dir: []const u8, layer: spore.DiskLayer) Error![]const u8 {
    const json = std.json.Stringify.valueAlloc(allocator, layer, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
    defer allocator.free(json);
    const layer_ref = try digestRefAlloc(allocator, json);
    errdefer allocator.free(layer_ref);
    const layer_path = try diskLayerPath(allocator, dir, layer_ref);
    defer allocator.free(layer_path);
    try writeFileAll(layer_path, json);
    return layer_ref;
}

const PatternedLayerFixture = struct {
    dir: []const u8,
    base_fd: std.c.fd_t,
    base_source: block_source.FileBlockSource,
    sealed: SealResult,
    disk_size: usize,
    cluster_size: usize,
    cluster_count: usize,

    fn deinit(self: *PatternedLayerFixture) void {
        if (self.base_fd >= 0) {
            _ = std.c.close(self.base_fd);
            self.base_fd = -1;
        }
    }
};

fn createPatternedLayerFixture(arena: std.mem.Allocator, cluster_size: usize, cluster_count: usize) !PatternedLayerFixture {
    const disk_size = cluster_size * cluster_count;
    const dir = try testDir(arena);
    const base_path = try pathZ(arena, "{s}/base.img", .{dir});
    const overlay_path = try pathZ(arena, "{s}/overlay.img", .{dir});

    const base_bytes = try arena.alloc(u8, disk_size);
    @memset(base_bytes, 0x11);
    try writeFileAll(base_path, base_bytes);
    try writeFileAll(overlay_path, "");

    const base_fd = try openTestFile(base_path, .{ .ACCMODE = .RDONLY });
    errdefer _ = std.c.close(base_fd);
    const overlay_fd = try openTestFile(overlay_path, .{ .ACCMODE = .RDWR });
    defer _ = std.c.close(overlay_fd);

    const base_source = block_source.FileBlockSource.init(base_fd, base_bytes.len);
    var disk = try cow_disk.CowDisk.init(arena, base_source, overlay_fd, base_bytes.len, cluster_size);
    defer disk.deinit();

    const patch = try arena.alloc(u8, cluster_size);
    var cluster_index: usize = 0;
    while (cluster_index < cluster_count) : (cluster_index += 1) {
        @memset(patch, @intCast(cluster_index + 1));
        try disk.writeAt(patch, @intCast(cluster_index * cluster_size));
    }

    const sealed = try sealCowDisk(arena, dir, &disk);
    return .{
        .dir = dir,
        .base_fd = base_fd,
        .base_source = base_source,
        .sealed = sealed,
        .disk_size = disk_size,
        .cluster_size = cluster_size,
        .cluster_count = cluster_count,
    };
}

test "sealed cow layer reads over immutable base" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    const base_path = try pathZ(arena, "{s}/base.img", .{dir});
    const overlay_path = try pathZ(arena, "{s}/overlay.img", .{dir});

    var base_bytes: [8192]u8 = undefined;
    for (&base_bytes, 0..) |*byte, i| byte.* = @truncate(i);
    try writeFileAll(base_path, &base_bytes);
    try writeFileAll(overlay_path, "");

    const base_fd = try openTestFile(base_path, .{ .ACCMODE = .RDONLY });
    defer _ = std.c.close(base_fd);
    const overlay_fd = try openTestFile(overlay_path, .{ .ACCMODE = .RDWR });
    defer _ = std.c.close(overlay_fd);

    const base_source = block_source.FileBlockSource.init(base_fd, base_bytes.len);
    var disk = try cow_disk.CowDisk.init(arena, base_source, overlay_fd, base_bytes.len, default_cluster_size);
    defer disk.deinit();

    const patch = [_]u8{0xAA} ** 512;
    try disk.writeAt(&patch, 1024);

    const sealed = try sealCowDisk(arena, dir, &disk);
    try std.testing.expectEqual(@as(usize, 1), sealed.layer.extents.len);
    try std.testing.expectEqual(@as(usize, 0), sealed.layer.zero_clusters.len);

    const parsed = try loadLayer(arena, dir, sealed.layer_ref);
    defer parsed.deinit();
    const layers = [_]spore.DiskLayer{parsed.value};
    var readback: [4096]u8 = undefined;
    try readAt(arena, dir, base_source, &layers, &readback, 0);
    try std.testing.expectEqualSlices(u8, base_bytes[0..1024], readback[0..1024]);
    try std.testing.expectEqualSlices(u8, &patch, readback[1024..1536]);
    try std.testing.expectEqualSlices(u8, base_bytes[1536..4096], readback[1536..4096]);
}

test "zero dirty cluster overrides nonzero base" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    const base_path = try pathZ(arena, "{s}/base.img", .{dir});
    const overlay_path = try pathZ(arena, "{s}/overlay.img", .{dir});
    const base_bytes = [_]u8{0x77} ** 4096;
    try writeFileAll(base_path, &base_bytes);
    try writeFileAll(overlay_path, "");

    const base_fd = try openTestFile(base_path, .{ .ACCMODE = .RDONLY });
    defer _ = std.c.close(base_fd);
    const overlay_fd = try openTestFile(overlay_path, .{ .ACCMODE = .RDWR });
    defer _ = std.c.close(overlay_fd);

    const base_source = block_source.FileBlockSource.init(base_fd, base_bytes.len);
    var disk = try cow_disk.CowDisk.init(arena, base_source, overlay_fd, base_bytes.len, default_cluster_size);
    defer disk.deinit();
    const zeros = [_]u8{0} ** 4096;
    try disk.writeAt(&zeros, 0);

    const sealed = try sealCowDisk(arena, dir, &disk);
    try std.testing.expectEqual(@as(usize, 0), sealed.layer.extents.len);
    try std.testing.expectEqual(@as(usize, 1), sealed.layer.zero_clusters.len);

    const layers = [_]spore.DiskLayer{sealed.layer};
    var readback: [4096]u8 = undefined;
    try readAt(arena, dir, base_source, &layers, &readback, 0);
    try std.testing.expect(std.mem.allEqual(u8, &readback, 0));
}

test "sealing keeps scratch cluster storage bounded" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cluster_size: usize = 4096;
    const cluster_count: usize = 6;
    const disk_size = cluster_size * cluster_count;

    const dir = try testDir(arena);
    const base_path = try pathZ(arena, "{s}/base.img", .{dir});
    const overlay_path = try pathZ(arena, "{s}/overlay.img", .{dir});

    const base_bytes = try arena.alloc(u8, disk_size);
    @memset(base_bytes, 0x11);
    try writeFileAll(base_path, base_bytes);
    try writeFileAll(overlay_path, "");

    const base_fd = try openTestFile(base_path, .{ .ACCMODE = .RDONLY });
    defer _ = std.c.close(base_fd);
    const overlay_fd = try openTestFile(overlay_path, .{ .ACCMODE = .RDWR });
    defer _ = std.c.close(overlay_fd);

    const base_source = block_source.FileBlockSource.init(base_fd, base_bytes.len);
    var disk = try cow_disk.CowDisk.init(arena, base_source, overlay_fd, base_bytes.len, cluster_size);
    defer disk.deinit();

    var patch: [cluster_size]u8 = undefined;
    var cluster_index: usize = 0;
    while (cluster_index < cluster_count) : (cluster_index += 1) {
        @memset(&patch, @intCast(cluster_index + 1));
        try disk.writeAt(&patch, @intCast(cluster_index * cluster_size));
    }

    var peak_allocator = PeakLiveAllocator{ .backing = arena };
    const seal_allocator = peak_allocator.allocator();
    const sealed = try sealCowDisk(seal_allocator, dir, &disk);
    defer {
        seal_allocator.free(sealed.layer_ref);
        for (sealed.layer.extents) |extent| seal_allocator.free(extent.digest);
        seal_allocator.free(sealed.layer.extents);
        seal_allocator.free(sealed.layer.zero_clusters);
    }

    try std.testing.expectEqual(@as(usize, cluster_count), sealed.layer.extents.len);
    try std.testing.expect(peak_allocator.peak < cluster_size * 3);
}

test "package layered reads keep scratch cluster storage bounded" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture = try createPatternedLayerFixture(arena, 4096, 6);
    defer fixture.deinit();
    const layers = [_]spore.DiskLayer{fixture.sealed.layer};
    const readback = try arena.alloc(u8, fixture.disk_size);

    var peak_allocator = PeakLiveAllocator{ .backing = arena, .limit = fixture.cluster_size * 3 };
    try readAt(peak_allocator.allocator(), fixture.dir, fixture.base_source, &layers, readback, 0);

    try std.testing.expectEqual(@as(usize, 0), peak_allocator.live);
    try std.testing.expect(peak_allocator.peak < fixture.cluster_size * 3);
    try expectPatternedClusters(readback, fixture.cluster_size, fixture.cluster_count);
}

test "layered cow reads keep scratch cluster storage bounded" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture = try createPatternedLayerFixture(arena, 4096, 6);
    defer fixture.deinit();
    const layer_refs = [_][]const u8{fixture.sealed.layer_ref};
    const layered_disk = spore.Disk{
        .device = .{ .mmio_slot = 0 },
        .size = fixture.disk_size,
        .base = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .layers = &layer_refs,
    };
    const loaded_layers = try loadLayerChain(arena, fixture.dir, layered_disk);
    var layered_overlay = try createTempOverlay(arena);
    defer layered_overlay.deinit();
    var layered = try LayeredCowDisk.init(arena, fixture.dir, fixture.base_source, layered_overlay.fd, layered_disk, loaded_layers);
    defer layered.deinit();

    const readback = try arena.alloc(u8, fixture.disk_size);
    var peak_allocator = PeakLiveAllocator{ .backing = arena, .limit = fixture.cluster_size * 3 };
    const original_allocator = layered.allocator;
    layered.allocator = peak_allocator.allocator();
    defer layered.allocator = original_allocator;
    try layered.readAt(readback, 0);

    try std.testing.expectEqual(@as(usize, 0), peak_allocator.live);
    try std.testing.expect(peak_allocator.peak < fixture.cluster_size * 3);
    try expectPatternedClusters(readback, fixture.cluster_size, fixture.cluster_count);
}

test "copying layer object data keeps scratch storage bounded" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture = try createPatternedLayerFixture(arena, 4096, 6);
    defer fixture.deinit();
    const target_dir = try pathZ(arena, "{s}/target.spore", .{fixture.dir});
    const layer_refs = [_][]const u8{fixture.sealed.layer_ref};
    const manifest_disk = spore.Disk{
        .device = .{ .mmio_slot = 0 },
        .size = fixture.disk_size,
        .base = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .layers = &layer_refs,
    };

    var peak_allocator = PeakLiveAllocator{ .backing = arena, .limit = fixture.cluster_size * 3 };
    try copyLayerChain(peak_allocator.allocator(), fixture.dir, target_dir, manifest_disk);

    try std.testing.expectEqual(@as(usize, 0), peak_allocator.live);
    try std.testing.expect(peak_allocator.peak < fixture.cluster_size * 3);

    const copied = try loadLayer(arena, target_dir, fixture.sealed.layer_ref);
    defer copied.deinit();
    const copied_layers = [_]spore.DiskLayer{copied.value};
    const readback = try arena.alloc(u8, fixture.disk_size);
    try readAt(arena, target_dir, fixture.base_source, &copied_layers, readback, 0);
    try expectPatternedClusters(readback, fixture.cluster_size, fixture.cluster_count);
}

test "copying layer indexes releases each layer before the next" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cluster_size: usize = 512;
    const zero_count: usize = 2048;
    const layer_count: usize = 6;
    const disk_size: u64 = @intCast(cluster_size * zero_count * layer_count);

    const source_dir = try testDir(arena);
    const target_dir = try pathZ(arena, "{s}/target.spore", .{source_dir});
    try ensureStoreDirs(arena, source_dir);

    const layer_refs = try arena.alloc([]const u8, layer_count);
    var layer_index: usize = 0;
    while (layer_index < layer_count) : (layer_index += 1) {
        const zero_clusters = try arena.alloc(u64, zero_count);
        for (zero_clusters, 0..) |*logical_cluster, zero_index| {
            logical_cluster.* = @intCast(layer_index * zero_count + zero_index);
        }
        const layer = spore.DiskLayer{
            .cluster_size = cluster_size,
            .disk_size = disk_size,
            .zero_clusters = zero_clusters,
        };
        layer_refs[layer_index] = try writeDiskLayerForTest(arena, source_dir, layer);
    }

    const manifest_disk = spore.Disk{
        .device = .{ .mmio_slot = 0 },
        .size = disk_size,
        .base = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .layers = layer_refs,
    };

    const live_limit = 1024 * 1024;
    var peak_allocator = PeakLiveAllocator{ .backing = arena, .limit = live_limit };
    try copyLayerChain(peak_allocator.allocator(), source_dir, target_dir, manifest_disk);

    try std.testing.expectEqual(@as(usize, 0), peak_allocator.live);
    try std.testing.expect(peak_allocator.peak < live_limit);
}

test "layered cow appends only the new active head" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent.spore", .{dir});
    const child_dir = try pathZ(arena, "{s}/child.spore", .{dir});
    const base_path = try pathZ(arena, "{s}/base.img", .{dir});
    const overlay_path = try pathZ(arena, "{s}/overlay.img", .{dir});

    var base_bytes: [8192]u8 = undefined;
    @memset(&base_bytes, 0x11);
    try writeFileAll(base_path, &base_bytes);
    try writeFileAll(overlay_path, "");

    const base_fd = try openTestFile(base_path, .{ .ACCMODE = .RDONLY });
    defer _ = std.c.close(base_fd);
    const overlay_fd = try openTestFile(overlay_path, .{ .ACCMODE = .RDWR });
    defer _ = std.c.close(overlay_fd);
    const base_source = block_source.FileBlockSource.init(base_fd, base_bytes.len);

    const base_disk = spore.Disk{
        .device = .{ .mmio_slot = 0 },
        .size = base_bytes.len,
        .base = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
    var first_head = try cow_disk.CowDisk.init(arena, base_source, overlay_fd, base_bytes.len, default_cluster_size);
    defer first_head.deinit();
    const first_patch = [_]u8{0x22} ** 4096;
    try first_head.writeAt(&first_patch, 0);

    const first_disk = (try (SnapshotState{
        .base = base_disk,
        .active = .{ .cow = &first_head },
    }).finish(arena, parent_dir)) orelse return error.BadManifest;
    try std.testing.expectEqual(@as(usize, 1), first_disk.layers.len);

    const loaded_layers = try loadLayerChain(arena, parent_dir, first_disk);
    var second_overlay = try createTempOverlay(arena);
    defer second_overlay.deinit();
    var second_head = try LayeredCowDisk.init(arena, parent_dir, base_source, second_overlay.fd, first_disk, loaded_layers);
    defer second_head.deinit();

    var inherited: [4096]u8 = undefined;
    try second_head.readAt(&inherited, 0);
    try std.testing.expectEqualSlices(u8, &first_patch, &inherited);
    var base_fallback: [4096]u8 = undefined;
    try second_head.readAt(&base_fallback, 4096);
    try std.testing.expectEqualSlices(u8, base_bytes[4096..8192], &base_fallback);
    const second_patch = [_]u8{0x33} ** 4096;
    try second_head.writeAt(&second_patch, 4096);

    const second_disk = (try (SnapshotState{
        .base = first_disk,
        .active = .{ .layered_cow = &second_head },
    }).finish(arena, child_dir)) orelse return error.BadManifest;
    try std.testing.expectEqual(@as(usize, 2), second_disk.layers.len);

    const second_layers = try loadLayerChain(arena, child_dir, second_disk);
    var readback: [8192]u8 = undefined;
    try readAt(arena, child_dir, base_source, second_layers, &readback, 0);
    try std.testing.expectEqualSlices(u8, &first_patch, readback[0..4096]);
    try std.testing.expectEqualSlices(u8, &second_patch, readback[4096..8192]);

    var model = base_bytes;
    @memcpy(model[0..4096], &first_patch);
    @memcpy(model[4096..8192], &second_patch);
    const read_lengths = [_]usize{ 0, 1, 17, 4095, 4096, 4097, 7000 };
    var window: [7000]u8 = undefined;
    var offset: usize = 0;
    while (offset < model.len) : (offset += 733) {
        for (read_lengths) |len| {
            if (offset + len > model.len) continue;
            try readAt(arena, child_dir, base_source, second_layers, window[0..len], offset);
            try std.testing.expectEqualSlices(u8, model[offset..][0..len], window[0..len]);
        }
    }
}

test "sealing rejects corrupt preexisting objects" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    const base_path = try pathZ(arena, "{s}/base.img", .{dir});
    const overlay_path = try pathZ(arena, "{s}/overlay.img", .{dir});
    const base_bytes = [_]u8{0x11} ** 4096;
    try writeFileAll(base_path, &base_bytes);
    try writeFileAll(overlay_path, "");

    const base_fd = try openTestFile(base_path, .{ .ACCMODE = .RDONLY });
    defer _ = std.c.close(base_fd);
    const overlay_fd = try openTestFile(overlay_path, .{ .ACCMODE = .RDWR });
    defer _ = std.c.close(overlay_fd);

    const base_source = block_source.FileBlockSource.init(base_fd, base_bytes.len);
    var disk = try cow_disk.CowDisk.init(arena, base_source, overlay_fd, base_bytes.len, default_cluster_size);
    defer disk.deinit();
    const patch = [_]u8{0x44} ** 4096;
    try disk.writeAt(&patch, 0);

    try ensureStoreDirs(arena, dir);
    const digest = try digestRefAlloc(arena, &patch);
    const object_path = try diskObjectPath(arena, dir, digest);
    var corrupt = patch;
    corrupt[0] ^= 0xFF;
    try writeFileAll(object_path, &corrupt);

    try std.testing.expectError(error.BadChunk, sealCowDisk(arena, dir, &disk));
}

test "content-addressed disk reads reject unsafe paths" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    try ensureStoreDirs(arena, dir);

    const object_data = [_]u8{0x42} ** 128;
    const object_ref = try digestRefAlloc(arena, &object_data);
    const object_path = try diskObjectPath(arena, dir, object_ref);
    if (std.c.mkdir(object_path.ptr, 0o755) != 0) return error.IoFailed;
    var target: [object_data.len]u8 = undefined;
    try std.testing.expectError(error.BadChunk, readDiskObject(arena, dir, object_ref, &target));

    const layer_bytes = "{}";
    const layer_ref = try digestRefAlloc(arena, layer_bytes);
    const layer_path = try diskLayerPath(arena, dir, layer_ref);
    const symlink_target = try pathZ(arena, "{s}/layer-target.json", .{dir});
    try writeFileAll(symlink_target, layer_bytes);
    if (std.c.symlink(symlink_target.ptr, layer_path.ptr) != 0) return error.SkipZigTest;
    try std.testing.expectError(error.IoFailed, loadLayer(arena, dir, layer_ref));
}

test "corrupt disk objects and layer indexes fail closed" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    const base_path = try pathZ(arena, "{s}/base.img", .{dir});
    const overlay_path = try pathZ(arena, "{s}/overlay.img", .{dir});
    const base_bytes = [_]u8{0x11} ** 4096;
    try writeFileAll(base_path, &base_bytes);
    try writeFileAll(overlay_path, "");

    const base_fd = try openTestFile(base_path, .{ .ACCMODE = .RDONLY });
    defer _ = std.c.close(base_fd);
    const overlay_fd = try openTestFile(overlay_path, .{ .ACCMODE = .RDWR });
    defer _ = std.c.close(overlay_fd);

    const base_source = block_source.FileBlockSource.init(base_fd, base_bytes.len);
    var disk = try cow_disk.CowDisk.init(arena, base_source, overlay_fd, base_bytes.len, default_cluster_size);
    defer disk.deinit();
    const patch = [_]u8{0x22} ** 4096;
    try disk.writeAt(&patch, 0);

    const sealed = try sealCowDisk(arena, dir, &disk);
    const object_path = try diskObjectPath(arena, dir, sealed.layer.extents[0].digest);
    var corrupt = patch;
    corrupt[0] ^= 0xFF;
    try writeFileAll(object_path, &corrupt);

    const layers = [_]spore.DiskLayer{sealed.layer};
    var readback: [4096]u8 = undefined;
    try std.testing.expectError(error.BadChunk, readAt(arena, dir, base_source, &layers, &readback, 0));

    const layer_path = try diskLayerPath(arena, dir, sealed.layer_ref);
    try writeFileAll(layer_path, "{}");
    try std.testing.expectError(error.BadChunk, loadLayer(arena, dir, sealed.layer_ref));
}

fn fuzzDiskLayerParse(_: void, s: *std.testing.Smith) !void {
    var buf: [4096]u8 = undefined;
    const len = s.slice(&buf);
    const parsed = std.json.parseFromSlice(spore.DiskLayer, std.testing.allocator, buf[0..len], .{
        .allocate = .alloc_always,
    }) catch return;
    defer parsed.deinit();
    _ = spore.validateDiskLayer(parsed.value) catch return;
}

test "fuzz disk layer parsing" {
    try std.testing.fuzz({}, fuzzDiskLayerParse, .{});
}
