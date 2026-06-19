//! Portable sealed disk layers for writable block devices.
//!
//! A running VM writes into a local COW head. Snapshot sealing turns dirty
//! clusters into verified disk objects plus a small content-addressed layer
//! index. Restore reads newest layer to oldest, then falls back to the
//! immutable rootfs base.

const std = @import("std");
const chunk = @import("chunk.zig");
const cow_disk = @import("cow_disk.zig");
const spore = @import("spore.zig");

pub const default_cluster_size: u64 = 4096;
pub const layer_index_max_bytes: usize = 64 * 1024 * 1024;

extern "c" fn mkstemp(template: [*:0]u8) c_int;

pub const Error = spore.Error || cow_disk.Error || error{
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
    base_fd: std.c.fd_t,
    overlay_fd: std.c.fd_t,
    size: u64,
    cluster_size: u64,
    layers: []const spore.DiskLayer,
    dirty: []bool,

    pub fn init(
        allocator: std.mem.Allocator,
        dir: []const u8,
        base_fd: std.c.fd_t,
        overlay_fd: std.c.fd_t,
        disk: spore.Disk,
        layers: []const spore.DiskLayer,
    ) Error!LayeredCowDisk {
        // Takes ownership of the cloned layer chain on success.
        if (layers.len == 0) return error.BadManifest;
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
            .base_fd = base_fd,
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
        var cursor: usize = 0;
        while (cursor < buf.len) {
            const absolute = offset + cursor;
            const span = try self.spanFor(absolute, buf.len - cursor);
            const target = buf[cursor..][0..span.len];
            if (self.dirty[span.cluster_index]) {
                try readExact(self.overlay_fd, target, absolute);
            } else {
                const cluster_len = try self.clusterLen(span.cluster_index);
                const cluster_buf = try self.allocator.alloc(u8, cluster_len);
                defer self.allocator.free(cluster_buf);
                try readClusterFromChain(self.allocator, self.dir, self.base_fd, self.layers, @intCast(span.cluster_index), cluster_buf);
                const cluster_offset: usize = @intCast(absolute % self.cluster_size);
                @memcpy(target, cluster_buf[cluster_offset..][0..span.len]);
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

    fn seedCluster(self: *LayeredCowDisk, cluster_index: usize) Error!void {
        const len = try self.clusterLen(cluster_index);
        const offset = std.math.mul(u64, cluster_index, self.cluster_size) catch return error.OutOfRange;
        const buf = try self.allocator.alloc(u8, len);
        defer self.allocator.free(buf);
        try readClusterFromChain(self.allocator, self.dir, self.base_fd, self.layers, @intCast(cluster_index), buf);
        try writeExact(self.overlay_fd, buf, offset);
    }
};

pub const ActiveHead = union(enum) {
    cow: *cow_disk.CowDisk,
    layered_cow: *LayeredCowDisk,

    pub fn dirtyClusterCount(self: ActiveHead) usize {
        return switch (self) {
            .cow => |disk| disk.dirtyClusterCount(),
            .layered_cow => |disk| disk.dirtyClusterCount(),
        };
    }

    pub fn seal(self: ActiveHead, allocator: std.mem.Allocator, dir: []const u8) Error!SealResult {
        return switch (self) {
            .cow => |disk| sealDisk(allocator, dir, disk),
            .layered_cow => |disk| sealDisk(allocator, dir, disk),
        };
    }

    pub fn sourceDir(self: ActiveHead) ?[]const u8 {
        return switch (self) {
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
            if (self.base.layers.len == 0) return null;
            return try cloneDisk(allocator, self.base);
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
        .device = rootfs.device,
        .size = rootfs.artifact.size,
        .base = rootfs.artifact.digest,
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
        .device = .{
            .kind = try allocator.dupe(u8, disk.device.kind),
            .role = try allocator.dupe(u8, disk.device.role),
            .virtio_device_id = disk.device.virtio_device_id,
            .mmio_slot = disk.device.mmio_slot,
        },
        .size = disk.size,
        .base = try allocator.dupe(u8, disk.base),
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
        .device = .{
            .kind = try allocator.dupe(u8, disk.device.kind),
            .role = try allocator.dupe(u8, disk.device.role),
            .virtio_device_id = disk.device.virtio_device_id,
            .mmio_slot = disk.device.mmio_slot,
        },
        .size = disk.size,
        .base = try allocator.dupe(u8, disk.base),
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

pub fn sealCowDisk(allocator: std.mem.Allocator, dir: []const u8, disk: *cow_disk.CowDisk) Error!SealResult {
    return sealDisk(allocator, dir, disk);
}

pub fn sealLayeredCowDisk(allocator: std.mem.Allocator, dir: []const u8, disk: *LayeredCowDisk) Error!SealResult {
    return sealDisk(allocator, dir, disk);
}

fn sealDisk(allocator: std.mem.Allocator, dir: []const u8, disk: anytype) Error!SealResult {
    try ensureStoreDirs(allocator, dir);

    var extents: std.ArrayList(spore.DiskLayerExtent) = .empty;
    errdefer extents.deinit(allocator);
    var zero_clusters: std.ArrayList(u64) = .empty;
    errdefer zero_clusters.deinit(allocator);

    var cluster_index: usize = 0;
    while (cluster_index < disk.clusterCount()) : (cluster_index += 1) {
        if (!try disk.isDirtyCluster(cluster_index)) continue;

        const len = try disk.clusterLen(cluster_index);
        const buf = try allocator.alloc(u8, len);
        defer allocator.free(buf);
        try disk.readCluster(cluster_index, buf);

        if (std.mem.allEqual(u8, buf, 0)) {
            try zero_clusters.append(allocator, @intCast(cluster_index));
            continue;
        }

        const digest = try digestRefAlloc(allocator, buf);
        const object_path = try diskObjectPath(allocator, dir, digest);
        try writeFileAllIfMissing(allocator, object_path, buf);
        try extents.append(allocator, .{
            .logical_cluster = @intCast(cluster_index),
            .digest = digest,
        });
    }

    const extent_slice = try extents.toOwnedSlice(allocator);
    errdefer allocator.free(extent_slice);
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
    const layer_path = try diskLayerPath(allocator, dir, layer_ref);
    try writeFileAllIfMissing(allocator, layer_path, json);

    return .{
        .layer_ref = layer_ref,
        .layer = layer,
        .json_size = json.len,
    };
}

pub fn loadLayer(allocator: std.mem.Allocator, dir: []const u8, layer_ref: []const u8) Error!std.json.Parsed(spore.DiskLayer) {
    const path = try diskLayerPath(allocator, dir, layer_ref);
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
        const source_layer_path = try diskLayerPath(allocator, source_dir, layer_ref);
        const layer_bytes = try readFileAll(allocator, source_layer_path, layer_index_max_bytes);
        defer allocator.free(layer_bytes);

        const layer_id = chunk.ChunkId.fromHex(try spore.diskDigestHex(layer_ref)) catch return error.BadManifest;
        if (!layer_id.matches(layer_bytes)) return error.BadChunk;

        const parsed = std.json.parseFromSlice(spore.DiskLayer, allocator, layer_bytes, .{
            .allocate = .alloc_always,
        }) catch return error.BadManifest;
        defer parsed.deinit();
        try spore.validateDiskLayer(parsed.value);
        if (parsed.value.disk_size != disk.size) return error.BadManifest;

        const target_layer_path = try diskLayerPath(allocator, target_dir, layer_ref);
        try writeFileAllIfMissing(allocator, target_layer_path, layer_bytes);

        for (parsed.value.extents) |extent| {
            const len = try spore.diskClusterLen(parsed.value.disk_size, parsed.value.cluster_size, extent.logical_cluster);
            const data = try allocator.alloc(u8, len);
            defer allocator.free(data);
            try readDiskObject(allocator, source_dir, extent.digest, data);
            const target_object_path = try diskObjectPath(allocator, target_dir, extent.digest);
            try writeFileAllIfMissing(allocator, target_object_path, data);
        }
    }
}

pub fn readAt(
    allocator: std.mem.Allocator,
    dir: []const u8,
    base_fd: std.c.fd_t,
    layers: []const spore.DiskLayer,
    buf: []u8,
    offset: u64,
) Error!void {
    if (layers.len == 0) {
        try readExact(base_fd, buf, offset);
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

    var cursor: usize = 0;
    while (cursor < buf.len) {
        const absolute = offset + cursor;
        const logical_cluster = absolute / cluster_size;
        const cluster_start = logical_cluster * cluster_size;
        const cluster_offset = absolute - cluster_start;
        const cluster_len = try spore.diskClusterLen(disk_size, cluster_size, logical_cluster);
        const span_len = @min(buf.len - cursor, cluster_len - @as(usize, @intCast(cluster_offset)));

        const cluster_buf = try allocator.alloc(u8, cluster_len);
        defer allocator.free(cluster_buf);
        try readClusterFromChain(allocator, dir, base_fd, layers, logical_cluster, cluster_buf);
        @memcpy(buf[cursor..][0..span_len], cluster_buf[@intCast(cluster_offset)..][0..span_len]);
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
    base_fd: std.c.fd_t,
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
    try readExact(base_fd, target, offset);
}

fn readDiskObject(allocator: std.mem.Allocator, dir: []const u8, digest: []const u8, target: []u8) Error!void {
    const path = try diskObjectPath(allocator, dir, digest);
    const data = try readFileAll(allocator, path, target.len);
    defer allocator.free(data);
    if (data.len != target.len) return error.BadChunk;
    const id = chunk.ChunkId.fromHex(try spore.diskDigestHex(digest)) catch return error.BadManifest;
    if (!id.matches(data)) return error.BadChunk;
    @memcpy(target, data);
}

fn digestRefAlloc(allocator: std.mem.Allocator, data: []const u8) Error![]const u8 {
    const id = chunk.ChunkId.fromContents(data);
    const hex = id.toHex();
    return std.fmt.allocPrint(allocator, "blake3:{s}", .{hex[0..]}) catch return error.OutOfMemory;
}

fn ensureStoreDirs(allocator: std.mem.Allocator, dir: []const u8) Error!void {
    try ensureDir(try pathZ(allocator, "{s}", .{dir}));
    try ensureDir(try pathZ(allocator, "{s}/diskobjects", .{dir}));
    try ensureDir(try pathZ(allocator, "{s}/diskobjects/blake3", .{dir}));
    try ensureDir(try pathZ(allocator, "{s}/disklayers", .{dir}));
    try ensureDir(try pathZ(allocator, "{s}/disklayers/blake3", .{dir}));
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
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);

    const cur = std.c.lseek(fd, 0, std.c.SEEK.CUR);
    if (cur < 0) return error.IoFailed;
    const end = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (end < 0) return error.IoFailed;
    if (std.c.lseek(fd, cur, std.c.SEEK.SET) < 0) return error.IoFailed;
    if (end < 0 or end > std.math.maxInt(usize)) return error.BadChunk;
    const size: usize = @intCast(end);
    if (size > max) return error.BadChunk;

    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    var done: usize = 0;
    while (done < size) {
        const n = std.c.read(fd, buf.ptr + done, size - done);
        if (n <= 0) return error.ShortRead;
        done += @intCast(n);
    }
    return buf;
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

    var disk = try cow_disk.CowDisk.init(arena, base_fd, overlay_fd, base_bytes.len, default_cluster_size);
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
    try readAt(arena, dir, base_fd, &layers, &readback, 0);
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

    var disk = try cow_disk.CowDisk.init(arena, base_fd, overlay_fd, base_bytes.len, default_cluster_size);
    defer disk.deinit();
    const zeros = [_]u8{0} ** 4096;
    try disk.writeAt(&zeros, 0);

    const sealed = try sealCowDisk(arena, dir, &disk);
    try std.testing.expectEqual(@as(usize, 0), sealed.layer.extents.len);
    try std.testing.expectEqual(@as(usize, 1), sealed.layer.zero_clusters.len);

    const layers = [_]spore.DiskLayer{sealed.layer};
    var readback: [4096]u8 = undefined;
    try readAt(arena, dir, base_fd, &layers, &readback, 0);
    try std.testing.expect(std.mem.allEqual(u8, &readback, 0));
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

    const base_disk = spore.Disk{
        .device = .{ .mmio_slot = 0 },
        .size = base_bytes.len,
        .base = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
    var first_head = try cow_disk.CowDisk.init(arena, base_fd, overlay_fd, base_bytes.len, default_cluster_size);
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
    var second_head = try LayeredCowDisk.init(arena, parent_dir, base_fd, second_overlay.fd, first_disk, loaded_layers);
    defer second_head.deinit();

    var inherited: [4096]u8 = undefined;
    try second_head.readAt(&inherited, 0);
    try std.testing.expectEqualSlices(u8, &first_patch, &inherited);
    const second_patch = [_]u8{0x33} ** 4096;
    try second_head.writeAt(&second_patch, 4096);

    const second_disk = (try (SnapshotState{
        .base = first_disk,
        .active = .{ .layered_cow = &second_head },
    }).finish(arena, child_dir)) orelse return error.BadManifest;
    try std.testing.expectEqual(@as(usize, 2), second_disk.layers.len);

    const second_layers = try loadLayerChain(arena, child_dir, second_disk);
    var readback: [8192]u8 = undefined;
    try readAt(arena, child_dir, base_fd, second_layers, &readback, 0);
    try std.testing.expectEqualSlices(u8, &first_patch, readback[0..4096]);
    try std.testing.expectEqualSlices(u8, &second_patch, readback[4096..8192]);
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

    var disk = try cow_disk.CowDisk.init(arena, base_fd, overlay_fd, base_bytes.len, default_cluster_size);
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

    var disk = try cow_disk.CowDisk.init(arena, base_fd, overlay_fd, base_bytes.len, default_cluster_size);
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
    try std.testing.expectError(error.BadChunk, readAt(arena, dir, base_fd, &layers, &readback, 0));

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
