//! OCI layer tar application.
//!
//! This module handles attacker-influenced tar streams from digest-verified OCI
//! layers and is intentionally strict: unsupported metadata fails closed rather
//! than being silently dropped.

const std = @import("std");
const oci = @import("oci.zig");
const ownership_mod = @import("ownership.zig");
const xattrs_mod = @import("xattrs.zig");

const Io = std.Io;

pub const max_content_bytes: u64 = 32 << 30;
const max_archive_entries: u64 = 1_000_000;
const max_pax_header_bytes: u64 = 1 << 20;

const Ownership = ownership_mod.Ownership;
const OwnershipMap = ownership_mod.Map;
const XattrMap = xattrs_mod.Map;

pub const ApplyOptions = struct {
    case_sensitive_staging: bool,
};

pub const LayerInput = struct {
    media_type: []const u8,
    path: []const u8,
    spill_dir: ?[]const u8 = null,
};

pub const FileSlice = struct {
    path: []u8,
    offset: u64,
    size: u64,
};

pub const FileSource = union(enum) {
    memory: []u8,
    file: FileSlice,

    pub fn size(self: FileSource) u64 {
        return switch (self) {
            .memory => |data| data.len,
            .file => |slice| slice.size,
        };
    }

    fn deinit(self: FileSource, allocator: std.mem.Allocator) void {
        switch (self) {
            .memory => |data| allocator.free(data),
            .file => |slice| allocator.free(slice.path),
        }
    }
};

pub const MergedEntryKind = enum {
    directory,
    file,
    symlink,
};

pub const MergedEntry = struct {
    kind: MergedEntryKind,
    mode: u16,
    uid: u32,
    gid: u32,
    inode_id: u64 = 0,
    symlink_target: []u8 = &.{},
    xattrs: []xattrs_mod.Attribute = &.{},
};

const FileInodeMap = std.AutoHashMap(u64, FileSource);
const FileLinkCountMap = std.AutoHashMap(u64, usize);

pub const MergedTree = struct {
    entries: std.StringHashMap(MergedEntry),
    file_sources: FileInodeMap,
    file_link_counts: FileLinkCountMap,
    next_inode_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) MergedTree {
        return .{
            .entries = std.StringHashMap(MergedEntry).init(allocator),
            .file_sources = FileInodeMap.init(allocator),
            .file_link_counts = FileLinkCountMap.init(allocator),
        };
    }

    pub fn deinit(self: *MergedTree, allocator: std.mem.Allocator) void {
        var entries = self.entries.iterator();
        while (entries.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            deinitMergedEntry(allocator, entry.value_ptr.*);
        }
        self.entries.deinit();

        var files = self.file_sources.valueIterator();
        while (files.next()) |source| source.deinit(allocator);
        self.file_sources.deinit();
        self.file_link_counts.deinit();
    }

    pub fn fileSource(self: *const MergedTree, inode_id: u64) !FileSource {
        return self.file_sources.get(inode_id) orelse error.BadHardlinkTarget;
    }

    pub fn contentSize(self: *const MergedTree) u64 {
        var total: u64 = 0;
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.kind == .file) {
                const source = self.file_sources.get(entry.value_ptr.inode_id) orelse continue;
                total += source.size();
            }
        }
        return total;
    }

    pub fn entryCount(self: *const MergedTree) u64 {
        return self.entries.count() + 1;
    }
};

pub fn applyLayer(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    layer_path: []const u8,
    media_type: []const u8,
    ownership: *OwnershipMap,
    xattrs: *XattrMap,
    options: ApplyOptions,
) !void {
    if (oci.isGzipLayerMediaType(media_type)) {
        try applyGzipLayer(allocator, io, root, layer_path, ownership, xattrs, options);
        return;
    }
    if (oci.isPlainTarLayerMediaType(media_type)) {
        try applyTarFileLayer(allocator, io, root, layer_path, ownership, xattrs, options);
        return;
    }
    return error.UnsupportedLayerMediaType;
}

pub fn buildMergedTree(
    allocator: std.mem.Allocator,
    io: Io,
    layers: []const LayerInput,
) !MergedTree {
    var tree = MergedTree.init(allocator);
    errdefer tree.deinit(allocator);
    for (layers) |layer| {
        try applyLayerToMergedTree(allocator, io, &tree, layer);
        if (tree.contentSize() > max_content_bytes) return error.RootFSArchiveTooLarge;
    }
    return tree;
}

pub fn applyLayerToMergedTree(
    allocator: std.mem.Allocator,
    io: Io,
    tree: *MergedTree,
    layer: LayerInput,
) !void {
    if (oci.isGzipLayerMediaType(layer.media_type)) {
        if (layer.spill_dir) |spill_dir| {
            const spooled = try spoolGzipTarLayer(allocator, io, layer.path, spill_dir);
            defer allocator.free(spooled);
            try applySeekableTarLayerToMergedTree(allocator, io, tree, spooled);
            return;
        }
        // Test-only streaming fallback. Production native materialization passes
        // a spill dir so regular file payloads stay source-backed instead of
        // buffering gzip contents in memory.
        var file = try Io.Dir.cwd().openFile(io, layer.path, .{});
        defer file.close(io);
        var file_buf: [64 * 1024]u8 = undefined;
        var file_reader: Io.File.Reader = .initStreaming(file, io, &file_buf);
        var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, &decompress_buf);
        applyTarLayerToMergedTree(allocator, &decompress.reader, tree) catch |err| switch (err) {
            error.ReadFailed => return decompress.err orelse err,
            else => |e| return e,
        };
        return;
    }
    if (oci.isPlainTarLayerMediaType(layer.media_type)) {
        try applySeekableTarLayerToMergedTree(allocator, io, tree, layer.path);
        return;
    }
    return error.UnsupportedLayerMediaType;
}

pub fn ensureMergedDirectory(
    allocator: std.mem.Allocator,
    tree: *MergedTree,
    rel: []const u8,
    mode: u32,
    owner: Ownership,
) !void {
    try ensureNoMergedSymlinkPath(tree, rel, true);
    try ensureMergedParent(allocator, tree, parentPath(rel));
    if (tree.entries.get(rel)) |entry| {
        if (entry.kind != .directory) return error.RequiredRootFSPathNotDirectory;
    }
    try putMergedEntry(allocator, tree, rel, .{
        .kind = .directory,
        .mode = @intCast(mode & 0o7777),
        .uid = owner.uid,
        .gid = owner.gid,
    });
}

pub fn ensureMergedFile(
    allocator: std.mem.Allocator,
    tree: *MergedTree,
    rel: []const u8,
    data: []const u8,
    mode: u32,
    owner: Ownership,
) !void {
    if (tree.entries.contains(rel)) return;
    try ensureNoMergedSymlinkPath(tree, parentPath(rel), false);
    try ensureMergedParent(allocator, tree, parentPath(rel));
    const copied = try allocator.dupe(u8, data);
    errdefer allocator.free(copied);
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);
    try putMergedFile(allocator, tree, &created, rel, .{ .memory = copied }, mode, owner, &.{});
}

fn applyGzipLayer(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    layer_path: []const u8,
    ownership: *OwnershipMap,
    xattrs: *XattrMap,
    options: ApplyOptions,
) !void {
    var file = try Io.Dir.cwd().openFile(io, layer_path, .{});
    defer file.close(io);
    var file_buf: [64 * 1024]u8 = undefined;
    var file_reader: Io.File.Reader = .initStreaming(file, io, &file_buf);
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, &decompress_buf);
    applyTarLayerWithXattrs(allocator, io, root, &decompress.reader, ownership, xattrs, options) catch |err| switch (err) {
        error.ReadFailed => return decompress.err orelse err,
        else => |e| return e,
    };
}

fn applyTarFileLayer(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    layer_path: []const u8,
    ownership: *OwnershipMap,
    xattrs: *XattrMap,
    options: ApplyOptions,
) !void {
    var file = try Io.Dir.cwd().openFile(io, layer_path, .{});
    defer file.close(io);
    var file_buf: [64 * 1024]u8 = undefined;
    var file_reader: Io.File.Reader = .initStreaming(file, io, &file_buf);
    try applyTarLayerWithXattrs(allocator, io, root, &file_reader.interface, ownership, xattrs, options);
}

const LayerLimits = struct {
    payload_bytes: u64 = 0,
    entries: u64 = 0,
    xattrs: u64 = 0,
    xattr_value_bytes: u64 = 0,
};

const CreatedPathMap = std.StringHashMap(void);
const case_sensitive_test_options = ApplyOptions{ .case_sensitive_staging = true };
const case_insensitive_test_options = ApplyOptions{ .case_sensitive_staging = false };

const PendingPax = struct {
    path: ?[]u8 = null,
    linkpath: ?[]u8 = null,
    uid: ?u32 = null,
    gid: ?u32 = null,
    size: ?u64 = null,
    xattrs: std.ArrayList(xattrs_mod.Attribute) = .empty,

    fn clear(self: *PendingPax, allocator: std.mem.Allocator) void {
        if (self.path) |p| allocator.free(p);
        if (self.linkpath) |p| allocator.free(p);
        for (self.xattrs.items) |attr| allocator.free(attr.value);
        self.xattrs.deinit(allocator);
        self.* = .{};
    }
};

fn applyTarLayer(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    reader: *Io.Reader,
    ownership: *OwnershipMap,
) !void {
    var xattrs = XattrMap.init(allocator);
    defer xattrs_mod.deinit(allocator, &xattrs);
    try applyTarLayerWithXattrs(allocator, io, root, reader, ownership, &xattrs, .{
        .case_sensitive_staging = try isCaseSensitiveDirectory(io, root),
    });
}

fn applyTarLayerWithXattrs(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    reader: *Io.Reader,
    ownership: *OwnershipMap,
    xattrs: *XattrMap,
    options: ApplyOptions,
) !void {
    var limits: LayerLimits = .{};
    var long_name: ?[]u8 = null;
    var long_link: ?[]u8 = null;
    var pax: PendingPax = .{};
    var global_pax: PendingPax = .{};
    var created = CreatedPathMap.init(allocator);
    defer {
        if (long_name) |p| allocator.free(p);
        if (long_link) |p| allocator.free(p);
        pax.clear(allocator);
        global_pax.clear(allocator);
        deinitCreatedPaths(allocator, &created);
    }

    while (true) {
        var header: [512]u8 = undefined;
        if (!try readTarHeader(reader, &header)) break;
        if (isZeroBlock(&header)) break;
        try verifyTarHeader(&header);
        const size = try tarSize(&header);
        const kind = header[156];

        if (kind == 'L') {
            try accountTarMetadataRecord(&limits, size);
            if (long_name) |p| allocator.free(p);
            long_name = try readTarString(allocator, reader, size);
            continue;
        }
        if (kind == 'K') {
            try accountTarMetadataRecord(&limits, size);
            if (long_link) |p| allocator.free(p);
            long_link = try readTarString(allocator, reader, size);
            continue;
        }
        if (kind == 'x') {
            try accountTarMetadataRecord(&limits, size);
            pax.clear(allocator);
            try readPaxHeader(allocator, reader, size, &pax);
            continue;
        }
        if (kind == 'g') {
            try accountTarMetadataRecord(&limits, size);
            try readPaxHeader(allocator, reader, size, &global_pax);
            try validateGlobalPax(global_pax);
            continue;
        }

        try accountTarEntry(&limits);

        const raw_name = if (pax.path) |p|
            p
        else if (long_name) |p|
            p
        else
            try tarFullName(allocator, &header);
        defer if (pax.path == null and long_name == null) allocator.free(raw_name);
        const payload_size = pax.size orelse size;
        defer {
            if (long_name) |p| {
                allocator.free(p);
                long_name = null;
            }
            if (long_link) |p| {
                allocator.free(p);
                long_link = null;
            }
            pax.clear(allocator);
        }

        const rel = safeTarPath(allocator, raw_name) catch |err| switch (err) {
            error.RootTarPath => {
                if (kind != '5') return error.UnsafeTarPath;
                try discardTarPayload(reader, payload_size);
                continue;
            },
            else => |e| return e,
        };
        defer allocator.free(rel);
        const entry_ownership = try tarOwnership(&header, pax, global_pax);

        if (std.mem.startsWith(u8, baseName(rel), ".wh.") and pax.xattrs.items.len != 0) {
            try discardTarPayload(reader, payload_size);
            return error.UnsupportedTarXattr;
        }
        if (try applyWhiteoutWithXattrs(allocator, io, root, ownership, xattrs, &created, rel)) {
            try discardTarPayload(reader, payload_size);
            continue;
        }

        switch (kind) {
            0, '0' => {
                try addContentBytes(&limits, payload_size);
                try xattrs_mod.removeSubtree(allocator, xattrs, rel);
                try writeRegularFile(allocator, io, root, ownership, &created, rel, reader, payload_size, try tarMode(&header), options);
                try ownership_mod.record(allocator, ownership, rel, entry_ownership);
                try recordEntryXattrs(allocator, xattrs, &limits, rel, pax.xattrs.items);
                try recordCreatedPath(allocator, &created, rel);
            },
            '5' => {
                try discardTarPayload(reader, payload_size);
                if (pax.xattrs.items.len != 0) return error.UnsupportedTarXattr;
                xattrs_mod.clearPath(allocator, xattrs, rel);
                try writeDirectory(allocator, io, root, ownership, &created, rel, try tarMode(&header), options);
                try ownership_mod.record(allocator, ownership, rel, entry_ownership);
                try recordCreatedPath(allocator, &created, rel);
            },
            '2' => {
                try discardTarPayload(reader, payload_size);
                if (pax.xattrs.items.len != 0) return error.UnsupportedTarXattr;
                const raw_link = if (pax.linkpath) |p| p else if (long_link) |p| p else tarLinkName(&header);
                try xattrs_mod.removeSubtree(allocator, xattrs, rel);
                try writeSymlink(allocator, io, root, ownership, &created, rel, raw_link, options);
                try ownership_mod.record(allocator, ownership, rel, entry_ownership);
                try recordCreatedPath(allocator, &created, rel);
            },
            '1' => {
                try discardTarPayload(reader, payload_size);
                const raw_link = if (pax.linkpath) |p| p else if (long_link) |p| p else tarLinkName(&header);
                try xattrs_mod.removeSubtree(allocator, xattrs, rel);
                try createHardlinkTarget(allocator, io, root, ownership, &created, rel, raw_link, options);
                try recordHardlinkOwnership(allocator, io, root, ownership, rel, entry_ownership);
                try recordHardlinkXattrs(allocator, io, root, xattrs, &limits, rel, pax.xattrs.items);
                try recordCreatedPath(allocator, &created, rel);
            },
            else => {
                try discardTarPayload(reader, payload_size);
                if (pax.xattrs.items.len != 0) return error.UnsupportedTarXattr;
                return error.UnsupportedTarEntryType;
            },
        }
    }
}

fn applyTarLayerToMergedTree(
    allocator: std.mem.Allocator,
    reader: *Io.Reader,
    tree: *MergedTree,
) !void {
    var limits: LayerLimits = .{};
    var long_name: ?[]u8 = null;
    var long_link: ?[]u8 = null;
    var pax: PendingPax = .{};
    var global_pax: PendingPax = .{};
    var created = CreatedPathMap.init(allocator);
    defer {
        if (long_name) |p| allocator.free(p);
        if (long_link) |p| allocator.free(p);
        pax.clear(allocator);
        global_pax.clear(allocator);
        deinitCreatedPaths(allocator, &created);
    }

    while (true) {
        var header: [512]u8 = undefined;
        if (!try readTarHeader(reader, &header)) break;
        if (isZeroBlock(&header)) break;
        try verifyTarHeader(&header);
        const size = try tarSize(&header);
        const kind = header[156];

        if (kind == 'L') {
            try accountTarMetadataRecord(&limits, size);
            if (long_name) |p| allocator.free(p);
            long_name = try readTarString(allocator, reader, size);
            continue;
        }
        if (kind == 'K') {
            try accountTarMetadataRecord(&limits, size);
            if (long_link) |p| allocator.free(p);
            long_link = try readTarString(allocator, reader, size);
            continue;
        }
        if (kind == 'x') {
            try accountTarMetadataRecord(&limits, size);
            pax.clear(allocator);
            try readPaxHeader(allocator, reader, size, &pax);
            continue;
        }
        if (kind == 'g') {
            try accountTarMetadataRecord(&limits, size);
            try readPaxHeader(allocator, reader, size, &global_pax);
            try validateGlobalPax(global_pax);
            continue;
        }

        try accountTarEntry(&limits);

        const raw_name = if (pax.path) |p|
            p
        else if (long_name) |p|
            p
        else
            try tarFullName(allocator, &header);
        defer if (pax.path == null and long_name == null) allocator.free(raw_name);
        const payload_size = pax.size orelse size;
        defer {
            if (long_name) |p| {
                allocator.free(p);
                long_name = null;
            }
            if (long_link) |p| {
                allocator.free(p);
                long_link = null;
            }
            pax.clear(allocator);
        }

        const rel = safeTarPath(allocator, raw_name) catch |err| switch (err) {
            error.RootTarPath => {
                if (kind != '5') return error.UnsafeTarPath;
                try discardTarPayload(reader, payload_size);
                continue;
            },
            else => |e| return e,
        };
        defer allocator.free(rel);
        const entry_ownership = try tarOwnership(&header, pax, global_pax);

        if (std.mem.startsWith(u8, baseName(rel), ".wh.") and pax.xattrs.items.len != 0) {
            try discardTarPayload(reader, payload_size);
            return error.UnsupportedTarXattr;
        }
        if (try applyMergedWhiteout(allocator, tree, &created, rel)) {
            try discardTarPayload(reader, payload_size);
            continue;
        }

        switch (kind) {
            0, '0' => {
                try addContentBytes(&limits, payload_size);
                try addXattrBytes(&limits, pax.xattrs.items);
                const data = try readTarPayloadAlloc(allocator, reader, payload_size);
                errdefer allocator.free(data);
                try putMergedFile(allocator, tree, &created, rel, .{ .memory = data }, try tarMode(&header), entry_ownership, pax.xattrs.items);
            },
            '5' => {
                try discardTarPayload(reader, payload_size);
                if (pax.xattrs.items.len != 0) return error.UnsupportedTarXattr;
                try putMergedDirectory(allocator, tree, &created, rel, try tarMode(&header), entry_ownership);
            },
            '2' => {
                try discardTarPayload(reader, payload_size);
                if (pax.xattrs.items.len != 0) return error.UnsupportedTarXattr;
                const raw_link = if (pax.linkpath) |p| p else if (long_link) |p| p else tarLinkName(&header);
                try putMergedSymlink(allocator, tree, &created, rel, raw_link, entry_ownership);
            },
            '1' => {
                try discardTarPayload(reader, payload_size);
                try addXattrBytes(&limits, pax.xattrs.items);
                const raw_link = if (pax.linkpath) |p| p else if (long_link) |p| p else tarLinkName(&header);
                try putMergedHardlink(allocator, tree, &created, rel, raw_link, entry_ownership, pax.xattrs.items);
            },
            else => {
                try discardTarPayload(reader, payload_size);
                if (pax.xattrs.items.len != 0) return error.UnsupportedTarXattr;
                return error.UnsupportedTarEntryType;
            },
        }
    }
}

fn applySeekableTarLayerToMergedTree(
    allocator: std.mem.Allocator,
    io: Io,
    tree: *MergedTree,
    layer_path: []const u8,
) !void {
    var file = try Io.Dir.cwd().openFile(io, layer_path, .{});
    defer file.close(io);

    var limits: LayerLimits = .{};
    var long_name: ?[]u8 = null;
    var long_link: ?[]u8 = null;
    var pax: PendingPax = .{};
    var global_pax: PendingPax = .{};
    var created = CreatedPathMap.init(allocator);
    defer {
        if (long_name) |p| allocator.free(p);
        if (long_link) |p| allocator.free(p);
        pax.clear(allocator);
        global_pax.clear(allocator);
        deinitCreatedPaths(allocator, &created);
    }

    var offset: u64 = 0;
    while (true) {
        var header: [512]u8 = undefined;
        if (!try readTarHeaderAt(file, io, &header, offset)) break;
        offset += header.len;
        if (isZeroBlock(&header)) break;
        try verifyTarHeader(&header);
        const size = try tarSize(&header);
        const kind = header[156];
        const payload_offset = offset;

        if (kind == 'L') {
            try accountTarMetadataRecord(&limits, size);
            if (long_name) |p| allocator.free(p);
            long_name = try readTarStringAt(allocator, file, io, payload_offset, size);
            offset = try tarPayloadEnd(payload_offset, size);
            continue;
        }
        if (kind == 'K') {
            try accountTarMetadataRecord(&limits, size);
            if (long_link) |p| allocator.free(p);
            long_link = try readTarStringAt(allocator, file, io, payload_offset, size);
            offset = try tarPayloadEnd(payload_offset, size);
            continue;
        }
        if (kind == 'x') {
            try accountTarMetadataRecord(&limits, size);
            pax.clear(allocator);
            try readPaxHeaderAt(allocator, file, io, payload_offset, size, &pax);
            offset = try tarPayloadEnd(payload_offset, size);
            continue;
        }
        if (kind == 'g') {
            try accountTarMetadataRecord(&limits, size);
            try readPaxHeaderAt(allocator, file, io, payload_offset, size, &global_pax);
            try validateGlobalPax(global_pax);
            offset = try tarPayloadEnd(payload_offset, size);
            continue;
        }

        try accountTarEntry(&limits);

        const raw_name = if (pax.path) |p|
            p
        else if (long_name) |p|
            p
        else
            try tarFullName(allocator, &header);
        defer if (pax.path == null and long_name == null) allocator.free(raw_name);
        const payload_size = pax.size orelse size;
        const next_offset = try tarPayloadEnd(payload_offset, payload_size);
        defer {
            offset = next_offset;
            if (long_name) |p| {
                allocator.free(p);
                long_name = null;
            }
            if (long_link) |p| {
                allocator.free(p);
                long_link = null;
            }
            pax.clear(allocator);
        }

        const rel = safeTarPath(allocator, raw_name) catch |err| switch (err) {
            error.RootTarPath => {
                if (kind != '5') return error.UnsafeTarPath;
                continue;
            },
            else => |e| return e,
        };
        defer allocator.free(rel);
        const entry_ownership = try tarOwnership(&header, pax, global_pax);

        if (std.mem.startsWith(u8, baseName(rel), ".wh.") and pax.xattrs.items.len != 0) {
            return error.UnsupportedTarXattr;
        }
        if (try applyMergedWhiteout(allocator, tree, &created, rel)) {
            continue;
        }

        switch (kind) {
            0, '0' => {
                try addContentBytes(&limits, payload_size);
                try addXattrBytes(&limits, pax.xattrs.items);
                const source = try fileSourceFromLayer(allocator, layer_path, payload_offset, payload_size);
                errdefer source.deinit(allocator);
                try putMergedFile(allocator, tree, &created, rel, source, try tarMode(&header), entry_ownership, pax.xattrs.items);
            },
            '5' => {
                if (pax.xattrs.items.len != 0) return error.UnsupportedTarXattr;
                try putMergedDirectory(allocator, tree, &created, rel, try tarMode(&header), entry_ownership);
            },
            '2' => {
                if (pax.xattrs.items.len != 0) return error.UnsupportedTarXattr;
                const raw_link = if (pax.linkpath) |p| p else if (long_link) |p| p else tarLinkName(&header);
                try putMergedSymlink(allocator, tree, &created, rel, raw_link, entry_ownership);
            },
            '1' => {
                try addXattrBytes(&limits, pax.xattrs.items);
                const raw_link = if (pax.linkpath) |p| p else if (long_link) |p| p else tarLinkName(&header);
                try putMergedHardlink(allocator, tree, &created, rel, raw_link, entry_ownership, pax.xattrs.items);
            },
            else => {
                if (pax.xattrs.items.len != 0) return error.UnsupportedTarXattr;
                return error.UnsupportedTarEntryType;
            },
        }
    }
}

fn spoolGzipTarLayer(
    allocator: std.mem.Allocator,
    io: Io,
    layer_path: []const u8,
    spill_dir: []const u8,
) ![]u8 {
    try Io.Dir.cwd().createDirPath(io, spill_dir);
    const hash = std.hash.Wyhash.hash(0, layer_path);
    const spooled = try std.fmt.allocPrint(allocator, "{s}/native-layer-{x}.tar", .{ spill_dir, hash });
    errdefer allocator.free(spooled);

    var input = try Io.Dir.cwd().openFile(io, layer_path, .{});
    defer input.close(io);
    var output = try Io.Dir.cwd().createFile(io, spooled, .{});
    defer output.close(io);

    var file_buf: [64 * 1024]u8 = undefined;
    var file_reader: Io.File.Reader = .initStreaming(input, io, &file_buf);
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, &decompress_buf);
    var output_buf: [64 * 1024]u8 = undefined;
    var writer: Io.File.Writer = .initStreaming(output, io, &output_buf);
    _ = decompress.reader.streamRemaining(&writer.interface) catch |err| switch (err) {
        error.ReadFailed => return decompress.err orelse err,
        else => |e| return e,
    };
    try writer.interface.flush();
    return spooled;
}

fn putMergedDirectory(
    allocator: std.mem.Allocator,
    tree: *MergedTree,
    created: *CreatedPathMap,
    rel: []const u8,
    mode: u32,
    owner: Ownership,
) !void {
    try ensureNoMergedSymlinkPath(tree, parentPath(rel), false);
    try ensureMergedParent(allocator, tree, parentPath(rel));
    try prepareMergedPath(allocator, tree, rel, .directory);
    try putMergedEntry(allocator, tree, rel, .{
        .kind = .directory,
        .mode = @intCast(mode & 0o7777),
        .uid = owner.uid,
        .gid = owner.gid,
    });
    try recordCreatedPath(allocator, created, rel);
}

fn putMergedFile(
    allocator: std.mem.Allocator,
    tree: *MergedTree,
    created: *CreatedPathMap,
    rel: []const u8,
    source: FileSource,
    mode: u32,
    owner: Ownership,
    attrs: []const xattrs_mod.Attribute,
) !void {
    try ensureNoMergedSymlinkPath(tree, parentPath(rel), false);
    try ensureMergedParent(allocator, tree, parentPath(rel));
    try prepareMergedPath(allocator, tree, rel, .non_directory);
    const inode_id = tree.next_inode_id;
    tree.next_inode_id += 1;
    try tree.file_sources.put(inode_id, source);
    errdefer _ = tree.file_sources.remove(inode_id);
    try putMergedEntry(allocator, tree, rel, .{
        .kind = .file,
        .mode = @intCast(mode & 0o7777),
        .uid = owner.uid,
        .gid = owner.gid,
        .inode_id = inode_id,
        .xattrs = try xattrs_mod.cloneAttributes(allocator, attrs),
    });
    try recordCreatedPath(allocator, created, rel);
}

fn putMergedSymlink(
    allocator: std.mem.Allocator,
    tree: *MergedTree,
    created: *CreatedPathMap,
    rel: []const u8,
    raw_link: []const u8,
    owner: Ownership,
) !void {
    try validateSymlinkTarget(allocator, rel, raw_link);
    try ensureNoMergedSymlinkPath(tree, parentPath(rel), false);
    try ensureMergedParent(allocator, tree, parentPath(rel));
    try prepareMergedPath(allocator, tree, rel, .non_directory);
    try putMergedEntry(allocator, tree, rel, .{
        .kind = .symlink,
        .mode = 0o777,
        .uid = owner.uid,
        .gid = owner.gid,
        .symlink_target = try allocator.dupe(u8, raw_link),
    });
    try recordCreatedPath(allocator, created, rel);
}

fn putMergedHardlink(
    allocator: std.mem.Allocator,
    tree: *MergedTree,
    created: *CreatedPathMap,
    rel: []const u8,
    raw_link: []const u8,
    owner: Ownership,
    attrs: []const xattrs_mod.Attribute,
) !void {
    const link_rel = try safeTarPath(allocator, raw_link);
    defer allocator.free(link_rel);
    if (std.mem.eql(u8, rel, link_rel)) return error.BadHardlinkTarget;
    if (isMergedDescendant(rel, link_rel)) return error.BadHardlinkTarget;
    try ensureNoMergedSymlinkPath(tree, link_rel, false);
    const target = tree.entries.get(link_rel) orelse return error.BadHardlinkTarget;
    if (target.kind != .file) return error.BadHardlinkTarget;

    try ensureNoMergedSymlinkPath(tree, parentPath(rel), false);
    try ensureMergedParent(allocator, tree, parentPath(rel));
    try prepareMergedPath(allocator, tree, rel, .non_directory);

    const cloned_attrs = if (attrs.len == 0)
        try xattrs_mod.cloneAttributes(allocator, target.xattrs)
    else
        try xattrs_mod.cloneAttributes(allocator, attrs);
    errdefer xattrs_mod.freeAttributes(allocator, cloned_attrs);

    try putMergedEntry(allocator, tree, rel, .{
        .kind = .file,
        .mode = target.mode,
        .uid = owner.uid,
        .gid = owner.gid,
        .inode_id = target.inode_id,
        .xattrs = cloned_attrs,
    });
    try normalizeMergedHardlinkMetadata(allocator, tree, target.inode_id, owner, if (attrs.len == 0) null else attrs);
    try recordCreatedPath(allocator, created, rel);
}

fn applyMergedWhiteout(
    allocator: std.mem.Allocator,
    tree: *MergedTree,
    created: *CreatedPathMap,
    rel: []const u8,
) !bool {
    const base = baseName(rel);
    if (!std.mem.startsWith(u8, base, ".wh.")) return false;
    const parent = parentPath(rel);
    if (std.mem.eql(u8, base, ".wh..wh..opq")) {
        try ensureNoMergedSymlinkPath(tree, parent, true);
        try removeMergedLowerChildren(allocator, tree, created, parent);
        return true;
    }
    const target_base = base[".wh.".len..];
    if (target_base.len == 0) return error.BadWhiteout;
    if (std.mem.eql(u8, target_base, ".") or std.mem.eql(u8, target_base, "..")) return error.BadWhiteout;
    const target = if (parent.len == 0)
        try allocator.dupe(u8, target_base)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, target_base });
    defer allocator.free(target);
    try ensureNoMergedSymlinkPath(tree, parent, true);
    if (created.contains(target) or createdHasDescendant(created, target)) {
        if (tree.entries.get(target)) |entry| {
            if (entry.kind == .directory) try removeMergedLowerChildren(allocator, tree, created, target);
        }
        return true;
    }
    try removeMergedSubtree(allocator, tree, target);
    try removeCreatedSubtree(allocator, created, target);
    return true;
}

fn prepareMergedPath(
    allocator: std.mem.Allocator,
    tree: *MergedTree,
    rel: []const u8,
    incoming: IncomingEntryKind,
) !void {
    if (tree.entries.get(rel)) |entry| {
        if (incoming == .directory and entry.kind == .directory) return;
        if (entry.kind != .directory) {
            try removeMergedPath(allocator, tree, rel);
            return;
        }
        try removeMergedSubtree(allocator, tree, rel);
    }
}

fn ensureMergedParent(allocator: std.mem.Allocator, tree: *MergedTree, parent: []const u8) !void {
    if (parent.len == 0) return;
    var accum: Io.Writer.Allocating = .init(allocator);
    defer accum.deinit();
    var iter = std.mem.splitScalar(u8, parent, '/');
    while (iter.next()) |part| {
        if (part.len == 0) continue;
        if (accum.written().len != 0) try accum.writer.writeByte('/');
        try accum.writer.writeAll(part);
        const current = accum.written();
        if (tree.entries.get(current)) |entry| {
            if (entry.kind != .directory) return error.ParentNotDirectory;
            continue;
        }
        try putMergedEntry(allocator, tree, current, .{
            .kind = .directory,
            .mode = 0o755,
            .uid = 0,
            .gid = 0,
        });
    }
}

fn ensureNoMergedSymlinkPath(tree: *const MergedTree, rel: []const u8, allow_missing_leaf: bool) !void {
    if (rel.len == 0) return;
    var split = std.mem.splitScalar(u8, rel, '/');
    var component_count: usize = 0;
    while (split.next()) |_| component_count += 1;

    var accum: [Io.Dir.max_path_bytes]u8 = undefined;
    var len: usize = 0;
    var iter = std.mem.splitScalar(u8, rel, '/');
    var index: usize = 0;
    while (iter.next()) |part| : (index += 1) {
        if (part.len == 0) continue;
        if (len != 0) {
            if (len >= accum.len) return error.NameTooLong;
            accum[len] = '/';
            len += 1;
        }
        if (part.len > accum.len - len) return error.NameTooLong;
        @memcpy(accum[len .. len + part.len], part);
        len += part.len;
        const is_leaf = index + 1 == component_count;
        if (tree.entries.get(accum[0..len])) |entry| {
            if (entry.kind == .symlink) return error.SymlinkTraversal;
        } else if (is_leaf and allow_missing_leaf) {
            return;
        }
    }
}

fn putMergedEntry(allocator: std.mem.Allocator, tree: *MergedTree, rel: []const u8, entry: MergedEntry) !void {
    const key = try allocator.dupe(u8, rel);
    errdefer allocator.free(key);
    const result = try tree.entries.getOrPut(key);
    if (result.found_existing) {
        allocator.free(key);
        releaseMergedEntry(allocator, tree, result.value_ptr.*);
    }
    result.value_ptr.* = entry;
    if (entry.kind == .file) {
        const count = try tree.file_link_counts.getOrPut(entry.inode_id);
        if (count.found_existing) {
            count.value_ptr.* += 1;
        } else {
            count.value_ptr.* = 1;
        }
    }
}

fn removeMergedSubtree(allocator: std.mem.Allocator, tree: *MergedTree, rel: []const u8) !void {
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(allocator);
    const prefix = try std.fmt.allocPrint(allocator, "{s}/", .{rel});
    defer allocator.free(prefix);

    var it = tree.entries.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, rel) or std.mem.startsWith(u8, key, prefix)) {
            try keys.append(allocator, key);
        }
    }
    for (keys.items) |key| try removeMergedPath(allocator, tree, key);
}

fn removeMergedLowerChildren(
    allocator: std.mem.Allocator,
    tree: *MergedTree,
    created: *CreatedPathMap,
    rel: []const u8,
) !void {
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(allocator);

    var it = tree.entries.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!isMergedDescendant(rel, key)) continue;
        if (created.contains(key) or createdHasDescendant(created, key)) continue;
        try keys.append(allocator, key);
    }
    for (keys.items) |key| try removeMergedPath(allocator, tree, key);
}

fn removeMergedPath(allocator: std.mem.Allocator, tree: *MergedTree, rel: []const u8) !void {
    const removed = tree.entries.fetchRemove(rel) orelse return;
    defer allocator.free(removed.key);
    releaseMergedEntry(allocator, tree, removed.value);
}

fn releaseMergedEntry(allocator: std.mem.Allocator, tree: *MergedTree, entry: MergedEntry) void {
    defer deinitMergedEntry(allocator, entry);
    if (entry.kind != .file) return;

    const count = tree.file_link_counts.getPtr(entry.inode_id) orelse return;
    std.debug.assert(count.* != 0);
    count.* -= 1;
    if (count.* != 0) return;
    _ = tree.file_link_counts.remove(entry.inode_id);
    if (tree.file_sources.fetchRemove(entry.inode_id)) |source| source.value.deinit(allocator);
}

fn normalizeMergedHardlinkMetadata(
    allocator: std.mem.Allocator,
    tree: *MergedTree,
    inode_id: u64,
    owner: Ownership,
    attrs: ?[]const xattrs_mod.Attribute,
) !void {
    var it = tree.entries.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.kind != .file or entry.value_ptr.inode_id != inode_id) continue;
        entry.value_ptr.uid = owner.uid;
        entry.value_ptr.gid = owner.gid;
        if (attrs) |source| {
            const cloned = try xattrs_mod.cloneAttributes(allocator, source);
            xattrs_mod.freeAttributes(allocator, entry.value_ptr.xattrs);
            entry.value_ptr.xattrs = cloned;
        }
    }
}

fn deinitMergedEntry(allocator: std.mem.Allocator, entry: MergedEntry) void {
    if (entry.kind == .symlink) allocator.free(entry.symlink_target);
    xattrs_mod.freeAttributes(allocator, entry.xattrs);
}

fn isMergedDescendant(parent: []const u8, path: []const u8) bool {
    if (parent.len == 0) return path.len != 0;
    if (path.len <= parent.len) return false;
    if (!std.mem.startsWith(u8, path, parent)) return false;
    return path[parent.len] == '/';
}

fn fileSourceFromLayer(
    allocator: std.mem.Allocator,
    layer_path: []const u8,
    payload_offset: u64,
    payload_size: u64,
) !FileSource {
    return .{ .file = .{
        .path = try allocator.dupe(u8, layer_path),
        .offset = payload_offset,
        .size = payload_size,
    } };
}

fn readFileSourceAlloc(allocator: std.mem.Allocator, io: Io, source: FileSource) ![]u8 {
    const size = source.size();
    if (size > max_content_bytes) return error.RootFSArchiveTooLarge;
    switch (source) {
        .memory => |data| return allocator.dupe(u8, data),
        .file => |slice| {
            const data = try allocator.alloc(u8, @intCast(size));
            errdefer allocator.free(data);
            var file = if (Io.Dir.path.isAbsolute(slice.path))
                try Io.Dir.openFileAbsolute(io, slice.path, .{})
            else
                try Io.Dir.cwd().openFile(io, slice.path, .{});
            defer file.close(io);
            const n = try file.readPositionalAll(io, data, slice.offset);
            if (n != data.len) return error.UnexpectedEndOfStream;
            return data;
        },
    }
}

fn readTarHeaderAt(file: Io.File, io: Io, header: *[512]u8, offset: u64) !bool {
    const n = try file.readPositionalAll(io, header, offset);
    if (n == 0) return false;
    if (n != header.len) return error.TruncatedTarHeader;
    return true;
}

fn readFilePayloadAllocAt(
    allocator: std.mem.Allocator,
    file: Io.File,
    io: Io,
    offset: u64,
    size: u64,
) ![]u8 {
    if (size > max_pax_header_bytes) return error.TarHeaderTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(bytes);
    const n = try file.readPositionalAll(io, bytes, offset);
    if (n != bytes.len) return error.UnexpectedEndOfStream;
    return bytes;
}

fn readTarStringAt(
    allocator: std.mem.Allocator,
    file: Io.File,
    io: Io,
    offset: u64,
    size: u64,
) ![]u8 {
    const bytes = try readFilePayloadAllocAt(allocator, file, io, offset, size);
    defer allocator.free(bytes);
    return allocator.dupe(u8, trimTrailingNul(bytes));
}

fn readPaxHeaderAt(
    allocator: std.mem.Allocator,
    file: Io.File,
    io: Io,
    offset: u64,
    size: u64,
    out: *PendingPax,
) !void {
    const bytes = try readFilePayloadAllocAt(allocator, file, io, offset, size);
    defer allocator.free(bytes);
    try parsePaxHeaderBytes(allocator, bytes, out);
}

fn tarPayloadEnd(payload_offset: u64, size: u64) !u64 {
    const padding = (512 - (size % 512)) % 512;
    return std.math.add(u64, try std.math.add(u64, payload_offset, size), padding);
}

fn readTarPayloadAlloc(allocator: std.mem.Allocator, reader: *Io.Reader, size: u64) ![]u8 {
    if (size > max_content_bytes) return error.RootFSArchiveTooLarge;
    const data = try reader.readAlloc(allocator, @intCast(size));
    errdefer allocator.free(data);
    try discardTarPadding(reader, size);
    return data;
}

fn accountTarEntry(limits: *LayerLimits) !void {
    if (limits.entries >= max_archive_entries) return error.RootFSArchiveTooManyEntries;
    limits.entries += 1;
}

fn accountTarPayloadBytes(limits: *LayerLimits, size: u64) !void {
    if (size > max_content_bytes - limits.payload_bytes) return error.RootFSArchiveTooLarge;
    limits.payload_bytes += size;
}

fn accountTarMetadataRecord(limits: *LayerLimits, size: u64) !void {
    try accountTarEntry(limits);
    try accountTarPayloadBytes(limits, size);
}

fn addContentBytes(limits: *LayerLimits, size: u64) !void {
    try accountTarPayloadBytes(limits, size);
}

fn addXattrBytes(limits: *LayerLimits, attrs: []const xattrs_mod.Attribute) !void {
    if (attrs.len == 0) return;
    if (limits.xattrs > xattrs_mod.max_layer_xattrs - attrs.len) return error.RootFSTooManyXattrs;
    limits.xattrs += attrs.len;
    for (attrs) |attr| {
        if (limits.xattr_value_bytes > xattrs_mod.max_layer_value_bytes - attr.value.len) {
            return error.RootFSXattrsTooLarge;
        }
        limits.xattr_value_bytes += attr.value.len;
    }
}

fn recordEntryXattrs(
    allocator: std.mem.Allocator,
    xattrs: *XattrMap,
    limits: *LayerLimits,
    rel: []const u8,
    attrs: []const xattrs_mod.Attribute,
) !void {
    if (attrs.len == 0) return;
    try addXattrBytes(limits, attrs);
    try xattrs_mod.record(allocator, xattrs, rel, attrs);
}

fn readTarHeader(reader: *Io.Reader, header: *[512]u8) !bool {
    var filled: usize = 0;
    while (filled < header.len) {
        const n = try reader.readSliceShort(header[filled..]);
        if (n == 0) {
            if (filled == 0) return false;
            return error.TruncatedTarHeader;
        }
        filled += n;
    }
    return true;
}

fn writeRegularFile(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *OwnershipMap,
    created: *CreatedPathMap,
    rel: []const u8,
    reader: *Io.Reader,
    size: u64,
    mode: u32,
    options: ApplyOptions,
) !void {
    try ensureNoSymlinkPath(allocator, io, root, parentPath(rel), false);
    try ensureNoCaseCollision(allocator, io, root, rel, options);
    try ensureParent(allocator, root, io, rel);
    try prepareEntryPath(allocator, io, root, ownership, created, rel, .non_directory);
    var file = try root.createFile(io, rel, .{ .permissions = permissionsFromMode(mode, .default_file) });
    defer file.close(io);
    var file_buf: [64 * 1024]u8 = undefined;
    var writer: Io.File.Writer = .initStreaming(file, io, &file_buf);
    try copyTarPayload(reader, &writer.interface, size);
    try writer.interface.flush();
    try discardTarPadding(reader, size);
    file.setPermissions(io, permissionsFromMode(mode, .default_file)) catch {};
}

fn writeDirectory(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *OwnershipMap,
    created: *CreatedPathMap,
    rel: []const u8,
    mode: u32,
    options: ApplyOptions,
) !void {
    try ensureNoSymlinkPath(allocator, io, root, parentPath(rel), false);
    try ensureNoCaseCollision(allocator, io, root, rel, options);
    try ensureParent(allocator, root, io, rel);
    try prepareEntryPath(allocator, io, root, ownership, created, rel, .directory);
    const permissions = permissionsFromMode(mode, .default_dir);
    root.createDir(io, rel, permissions) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };
    root.setFilePermissions(io, rel, permissions, .{ .follow_symlinks = false }) catch {};
}

fn writeSymlink(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *OwnershipMap,
    created: *CreatedPathMap,
    rel: []const u8,
    raw_link: []const u8,
    options: ApplyOptions,
) !void {
    try validateSymlinkTarget(allocator, rel, raw_link);
    try ensureNoSymlinkPath(allocator, io, root, parentPath(rel), false);
    try ensureNoCaseCollision(allocator, io, root, rel, options);
    try ensureParent(allocator, root, io, rel);
    try prepareEntryPath(allocator, io, root, ownership, created, rel, .non_directory);
    try root.symLink(io, raw_link, rel, .{});
}

fn createHardlinkTarget(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *OwnershipMap,
    created: *CreatedPathMap,
    rel: []const u8,
    raw_link: []const u8,
    options: ApplyOptions,
) !void {
    const link_rel = try safeTarPath(allocator, raw_link);
    defer allocator.free(link_rel);
    try ensureNoSymlinkPath(allocator, io, root, link_rel, false);
    try ensureNoCaseCollision(allocator, io, root, link_rel, options);
    const stat = try root.statFile(io, link_rel, .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.BadHardlinkTarget;
    try ensureNoSymlinkPath(allocator, io, root, parentPath(rel), false);
    try ensureNoCaseCollision(allocator, io, root, rel, options);
    try ensureParent(allocator, root, io, rel);
    try prepareEntryPath(allocator, io, root, ownership, created, rel, .non_directory);
    try Io.Dir.hardLink(root, link_rel, root, rel, io, .{});
}

fn recordHardlinkOwnership(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *OwnershipMap,
    rel: []const u8,
    owner: Ownership,
) !void {
    const linked = try root.statFile(io, rel, .{ .follow_symlinks = false });
    var it = ownership.iterator();
    while (it.next()) |entry| {
        const stat = root.statFile(io, entry.key_ptr.*, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        if (stat.kind == .file and stat.inode == linked.inode) {
            entry.value_ptr.* = owner;
        }
    }
    try ownership_mod.record(allocator, ownership, rel, owner);
}

fn recordHardlinkXattrs(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    xattrs: *XattrMap,
    limits: *LayerLimits,
    rel: []const u8,
    attrs: []const xattrs_mod.Attribute,
) !void {
    const linked = try root.statFile(io, rel, .{ .follow_symlinks = false });
    if (attrs.len != 0) {
        try addXattrBytes(limits, attrs);
        var it = xattrs.iterator();
        while (it.next()) |entry| {
            const stat = root.statFile(io, entry.key_ptr.*, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => |e| return e,
            };
            if (stat.kind == .file and stat.inode == linked.inode) {
                const cloned = try xattrs_mod.cloneAttributes(allocator, attrs);
                xattrs_mod.freeAttributes(allocator, entry.value_ptr.attrs);
                entry.value_ptr.* = .{ .attrs = cloned };
            }
        }
        try xattrs_mod.record(allocator, xattrs, rel, attrs);
        return;
    }

    var it = xattrs.iterator();
    while (it.next()) |entry| {
        const stat = root.statFile(io, entry.key_ptr.*, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        if (stat.kind == .file and stat.inode == linked.inode) {
            try xattrs_mod.record(allocator, xattrs, rel, entry.value_ptr.attrs);
            return;
        }
    }
}

const IncomingEntryKind = enum {
    directory,
    non_directory,
};

fn prepareEntryPath(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *OwnershipMap,
    created: *CreatedPathMap,
    rel: []const u8,
    incoming: IncomingEntryKind,
) !void {
    const stat = root.statFile(io, rel, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    if (incoming == .directory and stat.kind == .directory) return;
    try root.deleteTree(io, rel);
    try ownership_mod.removeSubtree(allocator, ownership, rel);
    try removeCreatedSubtree(allocator, created, rel);
}

fn applyWhiteout(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *OwnershipMap,
    created: *CreatedPathMap,
    rel: []const u8,
) !bool {
    var xattrs = XattrMap.init(allocator);
    defer xattrs_mod.deinit(allocator, &xattrs);
    return applyWhiteoutWithXattrs(allocator, io, root, ownership, &xattrs, created, rel);
}

fn applyWhiteoutWithXattrs(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *OwnershipMap,
    xattrs: *XattrMap,
    created: *CreatedPathMap,
    rel: []const u8,
) !bool {
    const base = baseName(rel);
    if (!std.mem.startsWith(u8, base, ".wh.")) return false;
    const parent = parentPath(rel);
    if (std.mem.eql(u8, base, ".wh..wh..opq")) {
        try ensureNoSymlinkPath(allocator, io, root, parent, true);
        try deleteLowerChildrenAt(allocator, io, root, ownership, xattrs, created, parent);
        return true;
    }
    const target_base = base[".wh.".len..];
    if (target_base.len == 0) return error.BadWhiteout;
    if (std.mem.eql(u8, target_base, ".") or std.mem.eql(u8, target_base, "..")) return error.BadWhiteout;
    const target = if (parent.len == 0)
        try allocator.dupe(u8, target_base)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, target_base });
    defer allocator.free(target);
    try ensureNoSymlinkPath(allocator, io, root, parent, true);
    if (created.contains(target) or createdHasDescendant(created, target)) {
        const stat = root.statFile(io, target, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return true,
            else => |e| return e,
        };
        if (stat.kind == .directory) {
            try deleteLowerChildrenAt(allocator, io, root, ownership, xattrs, created, target);
        }
        return true;
    }
    try root.deleteTree(io, target);
    try ownership_mod.removeSubtree(allocator, ownership, target);
    try xattrs_mod.removeSubtree(allocator, xattrs, target);
    try removeCreatedSubtree(allocator, created, target);
    return true;
}

fn deleteLowerChildrenAt(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *OwnershipMap,
    xattrs: *XattrMap,
    created: *CreatedPathMap,
    rel: []const u8,
) !void {
    if (rel.len == 0) {
        try deleteLowerChildren(allocator, io, root, ownership, xattrs, created, "");
        return;
    }
    var dir = root.openDir(io, rel, .{
        .access_sub_paths = true,
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer dir.close(io);
    try deleteLowerChildren(allocator, io, dir, ownership, xattrs, created, rel);
}

fn deleteLowerChildren(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *OwnershipMap,
    xattrs: *XattrMap,
    created: *CreatedPathMap,
    prefix: []const u8,
) !void {
    var it = root.iterate();
    while (try it.next(io)) |entry| {
        const name = try allocator.dupe(u8, entry.name);
        defer allocator.free(name);
        const rel = if (prefix.len == 0)
            try allocator.dupe(u8, name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
        defer allocator.free(rel);

        const has_created_descendant = createdHasDescendant(created, rel);
        if (entry.kind == .directory and (created.contains(rel) or has_created_descendant)) {
            var child = try root.openDir(io, name, .{
                .access_sub_paths = true,
                .iterate = true,
                .follow_symlinks = false,
            });
            defer child.close(io);
            try deleteLowerChildren(allocator, io, child, ownership, xattrs, created, rel);
            continue;
        }
        if (created.contains(rel)) continue;

        try root.deleteTree(io, name);
        try ownership_mod.removeSubtree(allocator, ownership, rel);
        try xattrs_mod.removeSubtree(allocator, xattrs, rel);
    }
}

fn recordCreatedPath(allocator: std.mem.Allocator, created: *CreatedPathMap, rel: []const u8) !void {
    const key = try allocator.dupe(u8, rel);
    const entry = try created.getOrPut(key);
    if (entry.found_existing) allocator.free(key);
}

fn deinitCreatedPaths(allocator: std.mem.Allocator, created: *CreatedPathMap) void {
    var it = created.iterator();
    while (it.next()) |entry| allocator.free(entry.key_ptr.*);
    created.deinit();
}

fn removeCreatedSubtree(allocator: std.mem.Allocator, created: *CreatedPathMap, rel: []const u8) !void {
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(allocator);
    const prefix = try std.fmt.allocPrint(allocator, "{s}/", .{rel});
    defer allocator.free(prefix);

    var it = created.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, rel) or std.mem.startsWith(u8, key, prefix)) {
            try keys.append(allocator, key);
        }
    }
    for (keys.items) |key| {
        _ = created.remove(key);
        allocator.free(key);
    }
}

fn createdHasDescendant(created: *const CreatedPathMap, rel: []const u8) bool {
    var it = created.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.len <= rel.len) continue;
        if (!std.mem.startsWith(u8, key, rel)) continue;
        if (key[rel.len] == '/') return true;
    }
    return false;
}

fn ensureParent(allocator: std.mem.Allocator, root: Io.Dir, io: Io, rel: []const u8) !void {
    const parent = parentPath(rel);
    if (parent.len == 0) return;
    var accum: Io.Writer.Allocating = .init(allocator);
    defer accum.deinit();
    var iter = std.mem.splitScalar(u8, parent, '/');
    while (iter.next()) |part| {
        if (part.len == 0) continue;
        if (accum.written().len != 0) try accum.writer.writeByte('/');
        try accum.writer.writeAll(part);
        const current = accum.written();
        const stat = root.statFile(io, current, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                const permissions = permissionsFromMode(0o755, .default_dir);
                try root.createDir(io, current, permissions);
                root.setFilePermissions(io, current, permissions, .{ .follow_symlinks = false }) catch {};
                continue;
            },
            else => |e| return e,
        };
        if (stat.kind != .directory) return error.ParentNotDirectory;
    }
}

fn ensureNoSymlinkPath(allocator: std.mem.Allocator, io: Io, root: Io.Dir, rel: []const u8, allow_missing_leaf: bool) !void {
    if (rel.len == 0) return;
    var accum: Io.Writer.Allocating = .init(allocator);
    defer accum.deinit();
    var iter = std.mem.splitScalar(u8, rel, '/');
    var index: usize = 0;
    var component_count: usize = 0;
    {
        var counter = std.mem.splitScalar(u8, rel, '/');
        while (counter.next()) |_| component_count += 1;
    }
    while (iter.next()) |part| : (index += 1) {
        if (part.len == 0) continue;
        if (accum.written().len != 0) try accum.writer.writeByte('/');
        try accum.writer.writeAll(part);
        const is_leaf = index + 1 == component_count;
        const stat = root.statFile(io, accum.written(), .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                if (is_leaf and allow_missing_leaf) return;
                continue;
            },
            else => |e| return e,
        };
        if (stat.kind == .sym_link) return error.SymlinkTraversal;
    }
}

pub fn isCaseSensitiveDirectory(io: Io, dir: Io.Dir) !bool {
    const lower = ".sporevm-case-probe";
    const upper = ".SPOREVM-CASE-PROBE";

    dir.deleteFile(io, lower) catch {};
    dir.deleteFile(io, upper) catch {};
    defer dir.deleteFile(io, lower) catch {};
    defer dir.deleteFile(io, upper) catch {};

    try dir.writeFile(io, .{ .sub_path = lower, .data = "lower" });
    try dir.writeFile(io, .{ .sub_path = upper, .data = "upper" });

    const lower_stat = try dir.statFile(io, lower, .{ .follow_symlinks = false });
    const upper_stat = try dir.statFile(io, upper, .{ .follow_symlinks = false });
    return lower_stat.inode != upper_stat.inode;
}

fn ensureNoCaseCollision(allocator: std.mem.Allocator, io: Io, root: Io.Dir, rel: []const u8, options: ApplyOptions) !void {
    _ = allocator;
    if (options.case_sensitive_staging) return;
    if (rel.len == 0) return;
    try ensureNoCaseCollisionInDir(io, root, rel);
}

fn ensureNoCaseCollisionInDir(io: Io, dir: Io.Dir, rel: []const u8) !void {
    const slash = std.mem.indexOfScalar(u8, rel, '/');
    const part = if (slash) |i| rel[0..i] else rel;
    if (part.len == 0) return;

    var exact_directory = false;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.ascii.eqlIgnoreCase(entry.name, part)) continue;
        if (!std.mem.eql(u8, entry.name, part)) return error.CaseCollisionPath;
        exact_directory = entry.kind == .directory;
    }

    if (slash) |i| {
        if (!exact_directory) return;
        var child = try dir.openDir(io, part, .{ .iterate = true, .follow_symlinks = false });
        defer child.close(io);
        try ensureNoCaseCollisionInDir(io, child, rel[i + 1 ..]);
    }
}

fn validateSymlinkTarget(allocator: std.mem.Allocator, rel: []const u8, raw_link: []const u8) !void {
    if (raw_link.len == 0 or std.mem.indexOfScalar(u8, raw_link, 0) != null) return error.BadSymlinkTarget;
    var owned_candidate: ?[]u8 = null;
    defer if (owned_candidate) |candidate| allocator.free(candidate);
    const candidate = if (std.mem.startsWith(u8, raw_link, "/"))
        raw_link[1..]
    else if (parentPath(rel).len == 0)
        raw_link
    else candidate: {
        owned_candidate = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parentPath(rel), raw_link });
        break :candidate owned_candidate.?;
    };
    const normalized = try normalizeRelativePath(allocator, candidate);
    defer allocator.free(normalized);
}

fn safeTarPath(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len == 0 or std.mem.startsWith(u8, raw, "/")) return error.UnsafeTarPath;
    if (std.mem.indexOfScalar(u8, raw, 0) != null) return error.UnsafeTarPath;
    if (hasUnsupportedDebugfsPathByte(raw)) return error.UnsupportedDebugfsPath;
    if (isTarRootPath(raw)) return error.RootTarPath;
    return normalizeRelativePath(allocator, raw);
}

fn hasUnsupportedDebugfsPathByte(path: []const u8) bool {
    for (path) |c| {
        switch (c) {
            '"', '\\', '\n', '\r' => return true,
            else => {},
        }
    }
    return false;
}

fn isTarRootPath(raw: []const u8) bool {
    if (raw.len == 0) return false;
    var saw_component = false;
    var iter = std.mem.splitScalar(u8, raw, '/');
    while (iter.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        saw_component = true;
        break;
    }
    return !saw_component;
}

fn normalizeRelativePath(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);
    var iter = std.mem.splitScalar(u8, raw, '/');
    while (iter.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len == 0) return error.UnsafeTarPath;
            _ = parts.pop();
            continue;
        }
        try parts.append(allocator, part);
    }
    if (parts.items.len == 0) return error.UnsafeTarPath;
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (parts.items, 0..) |part, i| {
        if (i != 0) try out.writer.writeByte('/');
        try out.writer.writeAll(part);
    }
    return out.toOwnedSlice();
}

fn parentPath(rel: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, rel, '/') orelse return "";
    return rel[0..slash];
}

fn baseName(rel: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, rel, '/') orelse return rel;
    return rel[slash + 1 ..];
}

fn copyTarPayload(reader: *Io.Reader, writer: *Io.Writer, size: u64) !void {
    var remaining = size;
    var buf: [64 * 1024]u8 = undefined;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, buf.len));
        const n = try reader.readSliceShort(buf[0..want]);
        if (n == 0) return error.UnexpectedEndOfStream;
        try writer.writeAll(buf[0..n]);
        remaining -= n;
    }
}

fn discardTarPayload(reader: *Io.Reader, size: u64) !void {
    try reader.discardAll64(size);
    try discardTarPadding(reader, size);
}

fn discardTarPadding(reader: *Io.Reader, size: u64) !void {
    const padding = (512 - (size % 512)) % 512;
    if (padding != 0) try reader.discardAll(@intCast(padding));
}

fn readTarString(allocator: std.mem.Allocator, reader: *Io.Reader, size: u64) ![]u8 {
    if (size > max_pax_header_bytes) return error.TarHeaderTooLarge;
    const bytes = try reader.readAlloc(allocator, @intCast(size));
    defer allocator.free(bytes);
    try discardTarPadding(reader, size);
    return allocator.dupe(u8, trimTrailingNul(bytes));
}

fn trimTrailingNul(bytes: []u8) []u8 {
    var end = bytes.len;
    while (end > 0 and bytes[end - 1] == 0) end -= 1;
    return bytes[0..end];
}

fn readPaxHeader(allocator: std.mem.Allocator, reader: *Io.Reader, size: u64, out: *PendingPax) !void {
    if (size > max_pax_header_bytes) return error.TarHeaderTooLarge;
    const bytes = try reader.readAlloc(allocator, @intCast(size));
    defer allocator.free(bytes);
    try discardTarPadding(reader, size);
    try parsePaxHeaderBytes(allocator, bytes, out);
}

fn parsePaxHeaderBytes(allocator: std.mem.Allocator, bytes: []const u8, out: *PendingPax) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        const line_start = index;
        while (index < bytes.len and bytes[index] != ' ') : (index += 1) {}
        if (index >= bytes.len) return error.BadPaxHeader;
        const line_len = try std.fmt.parseInt(usize, bytes[line_start..index], 10);
        if (line_len == 0 or line_len > bytes.len - line_start) return error.BadPaxHeader;
        const record_start = index + 1;
        const record_end = line_start + line_len;
        if (record_end <= record_start or bytes[record_end - 1] != '\n') return error.BadPaxHeader;
        const record = bytes[record_start .. record_end - 1];
        if (std.mem.indexOfScalar(u8, record, '=')) |eq| {
            const key = record[0..eq];
            const value = record[eq + 1 ..];
            if (std.mem.eql(u8, key, "path")) {
                if (out.path) |old| allocator.free(old);
                out.path = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "linkpath")) {
                if (out.linkpath) |old| allocator.free(old);
                out.linkpath = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "uid")) {
                out.uid = try parsePaxId(value);
            } else if (std.mem.eql(u8, key, "gid")) {
                out.gid = try parsePaxId(value);
            } else if (std.mem.eql(u8, key, "size")) {
                out.size = try parsePaxSize(value);
            } else if (isPaxXattrKey(key)) {
                try addPaxXattr(allocator, out, key, value);
            } else if (isPaxSparseKey(key)) {
                return error.UnsupportedTarSparse;
            }
        }
        index = line_start + line_len;
    }
}

fn validateGlobalPax(pax: PendingPax) !void {
    if (pax.path != null or pax.linkpath != null or pax.size != null) return error.UnsupportedGlobalPaxRecord;
    if (pax.xattrs.items.len != 0) return error.UnsupportedTarXattr;
}

fn isPaxXattrKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "SCHILY.xattr.") or
        std.mem.startsWith(u8, key, "LIBARCHIVE.xattr.");
}

fn addPaxXattr(allocator: std.mem.Allocator, out: *PendingPax, key: []const u8, value: []const u8) !void {
    if (!std.mem.eql(u8, key, "SCHILY.xattr." ++ xattrs_mod.security_capability_name)) {
        return error.UnsupportedTarXattr;
    }
    try xattrs_mod.validateSecurityCapability(value);
    if (out.xattrs.items.len >= xattrs_mod.max_per_entry) return error.TarTooManyXattrs;
    for (out.xattrs.items) |attr| {
        if (std.mem.eql(u8, attr.name, xattrs_mod.security_capability_name)) return error.DuplicateTarXattr;
    }
    const copied = try allocator.dupe(u8, value);
    errdefer allocator.free(copied);
    try out.xattrs.append(allocator, .{
        .name = xattrs_mod.security_capability_name,
        .value = copied,
    });
}

fn isPaxSparseKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "GNU.sparse.");
}

fn parsePaxId(raw: []const u8) !u32 {
    const value = std.fmt.parseInt(u64, raw, 10) catch return error.BadPaxHeader;
    if (value > std.math.maxInt(u32)) return error.BadPaxHeader;
    return @intCast(value);
}

fn parsePaxSize(raw: []const u8) !u64 {
    return std.fmt.parseInt(u64, raw, 10) catch return error.BadPaxHeader;
}

fn tarFullName(allocator: std.mem.Allocator, header: *const [512]u8) ![]u8 {
    const name = trimTarField(header[0..100]);
    const prefix = trimTarField(header[345..500]);
    if (prefix.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
}

fn tarLinkName(header: *const [512]u8) []const u8 {
    return trimTarField(header[157..257]);
}

fn tarMode(header: *const [512]u8) !u32 {
    const value = try parseTarNumber(header[100..108]);
    if (value > std.math.maxInt(u32)) return error.BadTarHeader;
    return @intCast(value);
}

fn tarOwnership(header: *const [512]u8, pax: PendingPax, global_pax: PendingPax) !Ownership {
    return .{
        .uid = pax.uid orelse global_pax.uid orelse try tarId(header[108..116]),
        .gid = pax.gid orelse global_pax.gid orelse try tarId(header[116..124]),
    };
}

fn tarId(raw: []const u8) !u32 {
    const value = try parseTarNumber(raw);
    if (value > std.math.maxInt(u32)) return error.BadTarHeader;
    return @intCast(value);
}

fn tarSize(header: *const [512]u8) !u64 {
    return parseTarNumber(header[124..136]);
}

fn parseTarNumber(raw: []const u8) !u64 {
    if (raw.len == 0) return error.BadTarHeader;
    if ((raw[0] & 0x80) != 0) {
        var value: u64 = 0;
        var significant: usize = 0;
        for (raw, 0..) |b, i| {
            const byte = if (i == 0) b & 0x7f else b;
            if (significant == 0 and byte == 0) continue;
            significant += 1;
            if (significant > @sizeOf(u64)) return error.BadTarHeader;
            value = (value << 8) | byte;
        }
        return value;
    }
    const trimmed = std.mem.trim(u8, raw, " \x00");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(u64, trimmed, 8) catch return error.BadTarHeader;
}

fn trimTarField(raw: []const u8) []const u8 {
    const nul = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
    return std.mem.trim(u8, raw[0..nul], " ");
}

fn verifyTarHeader(header: *const [512]u8) !void {
    const stored = try parseTarNumber(header[148..156]);
    var unsigned_sum: u64 = 0;
    var signed_sum: i64 = 0;
    for (header, 0..) |b, i| {
        const value: u8 = if (i >= 148 and i < 156) ' ' else b;
        unsigned_sum += value;
        signed_sum += @as(i8, @bitCast(value));
    }
    if (stored != unsigned_sum and @as(i64, @intCast(stored)) != signed_sum) return error.BadTarChecksum;
}

fn isZeroBlock(block: *const [512]u8) bool {
    for (block) |b| if (b != 0) return false;
    return true;
}

fn permissionsFromMode(mode: u32, fallback: Io.Dir.Permissions) Io.Dir.Permissions {
    if (@hasDecl(Io.Dir.Permissions, "fromMode")) {
        return Io.Dir.Permissions.fromMode(@intCast(mode & 0o7777));
    }
    return fallback;
}

fn permissionsToMode(permissions: Io.Dir.Permissions) ?u32 {
    if (@hasDecl(Io.Dir.Permissions, "toMode")) {
        return @intCast(permissions.toMode() & 0o7777);
    }
    return null;
}

fn makeTarHeader(header: []u8, name: []const u8, kind: u8, size: u64) void {
    std.debug.assert(header.len == 512);
    std.debug.assert(name.len <= 100);
    @memset(header, 0);
    @memcpy(header[0..name.len], name);
    writeTarOctal(header[100..108], if (kind == '5') 0o755 else 0o644);
    writeTarOctal(header[108..116], 0);
    writeTarOctal(header[116..124], 0);
    writeTarOctal(header[124..136], size);
    writeTarOctal(header[136..148], 0);
    @memset(header[148..156], ' ');
    header[156] = kind;
    @memcpy(header[257..263], "ustar\x00");
    @memcpy(header[263..265], "00");
    var sum: u64 = 0;
    for (header[0..512]) |b| sum += b;
    writeTarOctal(header[148..156], sum);
}

fn writePaxRecord(dst: []u8, key: []const u8, value: []const u8) usize {
    var digits: usize = 1;
    while (true) {
        const total = digits + 1 + key.len + 1 + value.len + 1;
        const next_digits = decimalDigits(total);
        if (next_digits == digits) {
            const prefix = std.fmt.bufPrint(dst[0 .. digits + 1], "{d} ", .{total}) catch unreachable;
            std.debug.assert(prefix.len == digits + 1);
            var index = prefix.len;
            @memcpy(dst[index .. index + key.len], key);
            index += key.len;
            dst[index] = '=';
            index += 1;
            @memcpy(dst[index .. index + value.len], value);
            index += value.len;
            dst[index] = '\n';
            return total;
        }
        digits = next_digits;
    }
}

fn decimalDigits(value: usize) usize {
    var remaining = value;
    var digits: usize = 1;
    while (remaining >= 10) {
        remaining /= 10;
        digits += 1;
    }
    return digits;
}

fn writeTarOctal(field: []u8, value: u64) void {
    @memset(field, 0);
    var remaining = value;
    var index = field.len - 2;
    while (true) {
        field[index] = @intCast('0' + (remaining & 7));
        remaining >>= 3;
        if (remaining == 0 or index == 0) break;
        index -= 1;
    }
}

fn appendTestTarEntry(
    allocator: std.mem.Allocator,
    bytes: *std.ArrayList(u8),
    name: []const u8,
    kind: u8,
    data: []const u8,
    link_name: ?[]const u8,
) !void {
    const start = bytes.items.len;
    try bytes.appendNTimes(allocator, 0, 512);
    makeTarHeader(bytes.items[start .. start + 512], name, kind, data.len);
    if (link_name) |link| {
        @memset(bytes.items[start + 157 .. start + 257], 0);
        @memcpy(bytes.items[start + 157 .. start + 157 + link.len], link);
        rewriteTestTarChecksum(bytes.items[start .. start + 512]);
    }
    try bytes.appendSlice(allocator, data);
    const padding = (512 - (data.len % 512)) % 512;
    try bytes.appendNTimes(allocator, 0, padding);
}

fn finishTestTar(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8)) !void {
    try bytes.appendNTimes(allocator, 0, 1024);
}

fn gzipTestBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const output = try allocator.alloc(u8, bytes.len + (bytes.len / 8) + 1024);
    defer allocator.free(output);
    var writer: Io.Writer = .fixed(output);
    const deflate_buffer = try allocator.alloc(u8, std.compress.flate.max_window_len * 2);
    defer allocator.free(deflate_buffer);
    var compressor = try std.compress.flate.Compress.init(&writer, deflate_buffer, .gzip, .fastest);
    try compressor.writer.writeAll(bytes);
    try compressor.finish();
    return allocator.dupe(u8, writer.buffered());
}

const PathSet = std.StringHashMap(void);

fn deinitPathSet(allocator: std.mem.Allocator, paths: *PathSet) void {
    var it = paths.iterator();
    while (it.next()) |entry| allocator.free(entry.key_ptr.*);
    paths.deinit();
}

fn collectStagedPaths(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    rel: []const u8,
    paths: *PathSet,
) !void {
    var dir = if (rel.len == 0)
        root
    else
        try root.openDir(io, rel, .{
            .iterate = true,
            .access_sub_paths = true,
            .follow_symlinks = false,
        });
    defer if (rel.len != 0) dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child = if (rel.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel, entry.name });
        const result = paths.getOrPut(child) catch |err| {
            allocator.free(child);
            return err;
        };
        if (result.found_existing) {
            allocator.free(child);
            continue;
        }
        if (entry.kind == .directory) try collectStagedPaths(allocator, io, root, child, paths);
    }
}

fn expectAttributesEqual(expected: []const xattrs_mod.Attribute, actual: []const xattrs_mod.Attribute) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |a, b| {
        try std.testing.expectEqualStrings(a.name, b.name);
        try std.testing.expectEqualSlices(u8, a.value, b.value);
    }
}

fn expectMergedTreeMatchesStaging(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    ownership: *const OwnershipMap,
    xattrs: *const XattrMap,
    tree: *const MergedTree,
) !void {
    var staged_paths = PathSet.init(allocator);
    defer deinitPathSet(allocator, &staged_paths);
    try collectStagedPaths(allocator, io, root, "", &staged_paths);

    var file_inodes = std.AutoHashMap(u64, Io.File.INode).init(allocator);
    defer file_inodes.deinit();

    var tree_it = tree.entries.iterator();
    while (tree_it.next()) |tree_entry| {
        const rel = tree_entry.key_ptr.*;
        const entry = tree_entry.value_ptr.*;
        try std.testing.expect(staged_paths.contains(rel));
        const stat = try root.statFile(io, rel, .{ .follow_symlinks = false });
        if (ownership.get(rel)) |owner| {
            try std.testing.expectEqual(owner.uid, entry.uid);
            try std.testing.expectEqual(owner.gid, entry.gid);
        }
        if (xattrs.get(rel)) |attrs| {
            try expectAttributesEqual(entry.xattrs, attrs.attrs);
        } else {
            try std.testing.expectEqual(@as(usize, 0), entry.xattrs.len);
        }

        switch (entry.kind) {
            .directory => {
                try std.testing.expectEqual(Io.File.Kind.directory, stat.kind);
                if (permissionsToMode(stat.permissions)) |mode| {
                    try std.testing.expectEqual(@as(u32, entry.mode), mode & 0o7777);
                }
            },
            .file => {
                try std.testing.expectEqual(Io.File.Kind.file, stat.kind);
                const staged_data = try root.readFileAlloc(io, rel, allocator, .limited(max_content_bytes));
                defer allocator.free(staged_data);
                const tree_data = try readFileSourceAlloc(allocator, io, try tree.fileSource(entry.inode_id));
                defer allocator.free(tree_data);
                try std.testing.expectEqualSlices(u8, staged_data, tree_data);
                if (permissionsToMode(stat.permissions)) |mode| {
                    try std.testing.expectEqual(@as(u32, entry.mode), mode & 0o7777);
                }
                const mapped = try file_inodes.getOrPut(entry.inode_id);
                if (mapped.found_existing) {
                    try std.testing.expectEqual(mapped.value_ptr.*, stat.inode);
                } else {
                    mapped.value_ptr.* = stat.inode;
                }
            },
            .symlink => {
                try std.testing.expectEqual(Io.File.Kind.sym_link, stat.kind);
                var target: [Io.Dir.max_path_bytes]u8 = undefined;
                const len = try root.readLink(io, rel, &target);
                try std.testing.expectEqualStrings(entry.symlink_target, target[0..len]);
            },
        }
    }

    var staged_it = staged_paths.iterator();
    while (staged_it.next()) |path| {
        try std.testing.expect(tree.entries.contains(path.key_ptr.*));
    }
}

fn rewriteTestTarChecksum(header: []u8) void {
    @memset(header[148..156], ' ');
    var sum: u64 = 0;
    for (header[0..512]) |b| sum += b;
    writeTarOctal(header[148..156], sum);
}

test "tar metadata records count against layer limits" {
    var limits: LayerLimits = .{};
    try accountTarMetadataRecord(&limits, 5);
    try std.testing.expectEqual(@as(u64, 1), limits.entries);
    try std.testing.expectEqual(@as(u64, 5), limits.payload_bytes);

    limits = .{ .entries = max_archive_entries };
    try std.testing.expectError(error.RootFSArchiveTooManyEntries, accountTarMetadataRecord(&limits, 0));

    limits = .{ .payload_bytes = max_content_bytes - 1 };
    try std.testing.expectError(error.RootFSArchiveTooLarge, accountTarMetadataRecord(&limits, 2));
}

test "safe tar path rejects traversal and absolute entries" {
    const allocator = std.testing.allocator;
    const path = try safeTarPath(allocator, "./usr/bin/tool");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("usr/bin/tool", path);
    try std.testing.expectError(error.RootTarPath, safeTarPath(allocator, "."));
    try std.testing.expectError(error.RootTarPath, safeTarPath(allocator, "./"));
    try std.testing.expectError(error.UnsafeTarPath, safeTarPath(allocator, "/etc/passwd"));
    try std.testing.expectError(error.UnsafeTarPath, safeTarPath(allocator, "../escape"));
    try std.testing.expectError(error.UnsafeTarPath, safeTarPath(allocator, "a/../../escape"));
    try std.testing.expectError(error.UnsupportedDebugfsPath, safeTarPath(allocator, "quote\"name"));
    try std.testing.expectError(error.UnsupportedDebugfsPath, safeTarPath(allocator, "back\\slash"));
}

test "plain tar layer media type extracts without gzip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const layer_path = "zig-cache/test-rootfs-plain-layer.tar";
    defer Io.Dir.cwd().deleteFile(io, layer_path) catch {};
    var block = [_]u8{0} ** 1536;
    makeTarHeader(block[0..512], "file", '0', 5);
    @memcpy(block[512..517], "hello");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = layer_path, .data = &block });

    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var xattrs = XattrMap.init(allocator);
    defer xattrs_mod.deinit(allocator, &xattrs);

    try applyLayer(allocator, io, tmp.dir, layer_path, "application/vnd.oci.image.layer.v1.tar", &ownership, &xattrs, case_sensitive_test_options);
    const bytes = try tmp.dir.readFileAlloc(io, "file", allocator, .limited(16));
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("hello", bytes);
}

test "whiteout removes lower-layer path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-whiteout";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    try root.createDirPath(io, "etc");
    try root.writeFile(io, .{ .sub_path = "etc/old", .data = "old" });
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var xattrs = XattrMap.init(allocator);
    defer xattrs_mod.deinit(allocator, &xattrs);
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);
    try ownership_mod.record(allocator, &ownership, "etc/old", .{ .uid = 1, .gid = 2 });
    var cap = [_]u8{ 1, 0, 0, 2 } ++ [_]u8{0} ** 16;
    const attrs = [_]xattrs_mod.Attribute{.{ .name = xattrs_mod.security_capability_name, .value = &cap }};
    try xattrs_mod.record(allocator, &xattrs, "etc/old", &attrs);
    try std.testing.expect(try applyWhiteoutWithXattrs(allocator, io, root, &ownership, &xattrs, &created, "etc/.wh.old"));
    try std.testing.expectError(error.FileNotFound, root.statFile(io, "etc/old", .{}));
    try std.testing.expect(!ownership.contains("etc/old"));
    try std.testing.expect(!xattrs.contains("etc/old"));
}

test "whiteout ignores already absent target" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-whiteout-absent";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    try root.createDirPath(io, "etc");
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);
    try std.testing.expect(try applyWhiteout(allocator, io, root, &ownership, &created, "etc/.wh.missing"));
}

test "whiteout rejects dot and dot-dot targets" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-whiteout-dot-target";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);

    try std.testing.expectError(error.BadWhiteout, applyWhiteout(allocator, io, root, &ownership, &created, ".wh.."));
    try std.testing.expectError(error.BadWhiteout, applyWhiteout(allocator, io, root, &ownership, &created, ".wh..."));
}

test "opaque whiteout preserves entries created in current layer" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-opaque-current-layer";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true, .access_sub_paths = true } });
    defer root.close(io);
    try root.createDirPath(io, "dir/sub");
    try root.writeFile(io, .{ .sub_path = "dir/lower", .data = "lower" });
    try root.writeFile(io, .{ .sub_path = "dir/current", .data = "current" });
    try root.writeFile(io, .{ .sub_path = "dir/sub/lower", .data = "lower" });
    try root.writeFile(io, .{ .sub_path = "dir/sub/current", .data = "current" });

    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    try ownership_mod.record(allocator, &ownership, "dir/lower", .{ .uid = 1, .gid = 1 });
    try ownership_mod.record(allocator, &ownership, "dir/current", .{ .uid = 2, .gid = 2 });
    try ownership_mod.record(allocator, &ownership, "dir/sub/lower", .{ .uid = 3, .gid = 3 });
    try ownership_mod.record(allocator, &ownership, "dir/sub/current", .{ .uid = 4, .gid = 4 });

    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);
    try recordCreatedPath(allocator, &created, "dir/current");
    try recordCreatedPath(allocator, &created, "dir/sub/current");

    try std.testing.expect(try applyWhiteout(allocator, io, root, &ownership, &created, "dir/.wh..wh..opq"));
    try std.testing.expectError(error.FileNotFound, root.statFile(io, "dir/lower", .{}));
    try std.testing.expectError(error.FileNotFound, root.statFile(io, "dir/sub/lower", .{}));
    try root.access(io, "dir/current", .{});
    try root.access(io, "dir/sub/current", .{});
    try std.testing.expect(!ownership.contains("dir/lower"));
    try std.testing.expect(!ownership.contains("dir/sub/lower"));
    try std.testing.expect(ownership.contains("dir/current"));
    try std.testing.expect(ownership.contains("dir/sub/current"));
}

test "normal whiteout preserves current-layer target" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-whiteout-current-layer";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true, .access_sub_paths = true } });
    defer root.close(io);
    try root.createDirPath(io, "dir/sub");
    try root.writeFile(io, .{ .sub_path = "dir/sub/lower", .data = "lower" });
    try root.writeFile(io, .{ .sub_path = "dir/sub/current", .data = "current" });

    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    try ownership_mod.record(allocator, &ownership, "dir/sub/lower", .{ .uid = 1, .gid = 1 });
    try ownership_mod.record(allocator, &ownership, "dir/sub/current", .{ .uid = 2, .gid = 2 });

    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);
    try recordCreatedPath(allocator, &created, "dir/sub/current");

    try std.testing.expect(try applyWhiteout(allocator, io, root, &ownership, &created, "dir/.wh.sub"));
    try root.access(io, "dir/sub/current", .{});
    try std.testing.expectError(error.FileNotFound, root.statFile(io, "dir/sub/lower", .{}));
    try std.testing.expect(ownership.contains("dir/sub/current"));
    try std.testing.expect(!ownership.contains("dir/sub/lower"));
}

test "opaque whiteout rejects symlink parent" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root_path = "zig-cache/test-rootfs-opaque-symlink";
    const victim_path = "zig-cache/test-rootfs-opaque-victim";
    defer Io.Dir.cwd().deleteTree(io, root_path) catch {};
    defer Io.Dir.cwd().deleteTree(io, victim_path) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, root_path, .{ .open_options = .{ .iterate = true, .access_sub_paths = true } });
    defer root.close(io);
    var victim = try Io.Dir.cwd().createDirPathOpen(io, victim_path, .{});
    victim.close(io);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = victim_path ++ "/keep", .data = "keep" });
    try root.symLink(io, "../test-rootfs-opaque-victim", "link", .{});

    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);
    try std.testing.expectError(
        error.SymlinkTraversal,
        applyWhiteout(allocator, io, root, &ownership, &created, "link/.wh..wh..opq"),
    );
    try Io.Dir.cwd().access(io, victim_path ++ "/keep", .{});
}

test "directory entries preserve tar mode" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-directory-mode";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);

    try writeDirectory(allocator, io, root, &ownership, &created, "root", 0o700, case_sensitive_test_options);
    const stat = try root.statFile(io, "root", .{ .follow_symlinks = false });
    if (permissionsToMode(stat.permissions)) |mode| {
        try std.testing.expectEqual(@as(u32, 0o700), mode & 0o777);
    }
}

test "directory entries replace non-directories" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-directory-replaces-file";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true, .access_sub_paths = true } });
    defer root.close(io);
    try root.writeFile(io, .{ .sub_path = "x", .data = "file" });
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    try ownership_mod.record(allocator, &ownership, "x", .{ .uid = 1, .gid = 1 });
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);

    try writeDirectory(allocator, io, root, &ownership, &created, "x", 0o755, case_sensitive_test_options);
    const stat = try root.statFile(io, "x", .{ .follow_symlinks = false });
    try std.testing.expectEqual(Io.File.Kind.directory, stat.kind);
    try std.testing.expect(!ownership.contains("x"));
}

test "implicit parent directories use deterministic mode without changing explicit parents" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-implicit-parent-mode";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true, .access_sub_paths = true } });
    defer root.close(io);
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);

    try writeDirectory(allocator, io, root, &ownership, &created, "usr", 0o700, case_sensitive_test_options);
    var payload = [_]u8{0} ** 512;
    payload[0] = 'x';
    var reader: Io.Reader = .fixed(&payload);
    try writeRegularFile(allocator, io, root, &ownership, &created, "usr/bin/tool", &reader, 1, 0o755, case_sensitive_test_options);

    const usr = try root.statFile(io, "usr", .{ .follow_symlinks = false });
    const bin = try root.statFile(io, "usr/bin", .{ .follow_symlinks = false });
    if (permissionsToMode(usr.permissions)) |mode| {
        try std.testing.expectEqual(@as(u32, 0o700), mode & 0o777);
    }
    if (permissionsToMode(bin.permissions)) |mode| {
        try std.testing.expectEqual(@as(u32, 0o755), mode & 0o777);
    }
}

test "nested directory entries use deterministic implicit parent mode" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-directory-implicit-parent-mode";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true, .access_sub_paths = true } });
    defer root.close(io);
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);

    try writeDirectory(allocator, io, root, &ownership, &created, "a/b", 0o700, case_sensitive_test_options);
    const parent = try root.statFile(io, "a", .{ .follow_symlinks = false });
    const child = try root.statFile(io, "a/b", .{ .follow_symlinks = false });
    if (permissionsToMode(parent.permissions)) |mode| {
        try std.testing.expectEqual(@as(u32, 0o755), mode & 0o777);
    }
    if (permissionsToMode(child.permissions)) |mode| {
        try std.testing.expectEqual(@as(u32, 0o700), mode & 0o777);
    }
}

test "case-colliding layer paths fail closed on case-insensitive staging" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-case-collision";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true, .access_sub_paths = true } });
    defer root.close(io);
    try root.createDirPath(io, "bin");
    try root.writeFile(io, .{ .sub_path = "bin/Foo", .data = "old" });
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);
    var payload = [_]u8{0} ** 512;
    payload[0] = 'x';
    var reader: Io.Reader = .fixed(&payload);

    try std.testing.expectError(
        error.CaseCollisionPath,
        writeRegularFile(allocator, io, root, &ownership, &created, "bin/foo", &reader, 1, 0o644, case_insensitive_test_options),
    );
}

test "case-distinct layer paths are allowed on case-sensitive staging" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-case-sensitive-collision";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true, .access_sub_paths = true } });
    defer root.close(io);
    if (!try isCaseSensitiveDirectory(io, root)) return error.SkipZigTest;

    try root.createDirPath(io, "bin");
    try root.writeFile(io, .{ .sub_path = "bin/Foo", .data = "old" });
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);
    var payload = [_]u8{0} ** 512;
    payload[0] = 'x';
    var reader: Io.Reader = .fixed(&payload);

    try writeRegularFile(allocator, io, root, &ownership, &created, "bin/foo", &reader, 1, 0o644, case_sensitive_test_options);
    try root.access(io, "bin/Foo", .{});
    const bytes = try root.readFileAlloc(io, "bin/foo", allocator, .limited(8));
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("x", bytes);
}

test "hardlink entries preserve inode identity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-hardlink";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true, .access_sub_paths = true } });
    defer root.close(io);
    try root.writeFile(io, .{ .sub_path = "target", .data = "same" });
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);

    try createHardlinkTarget(allocator, io, root, &ownership, &created, "alias", "target", case_sensitive_test_options);
    const target = try root.statFile(io, "target", .{ .follow_symlinks = false });
    const alias = try root.statFile(io, "alias", .{ .follow_symlinks = false });
    try std.testing.expectEqual(target.inode, alias.inode);
    try std.testing.expect(target.nlink >= 2);
}

test "hardlink ownership is normalized across shared inode paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-hardlink-ownership";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true, .access_sub_paths = true } });
    defer root.close(io);
    try root.writeFile(io, .{ .sub_path = "target", .data = "same" });
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    try ownership_mod.record(allocator, &ownership, "target", .{ .uid = 1, .gid = 1 });
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);

    try createHardlinkTarget(allocator, io, root, &ownership, &created, "alias", "target", case_sensitive_test_options);
    try recordHardlinkOwnership(allocator, io, root, &ownership, "alias", .{ .uid = 2, .gid = 3 });

    try std.testing.expectEqual(@as(u32, 2), ownership.get("target").?.uid);
    try std.testing.expectEqual(@as(u32, 3), ownership.get("target").?.gid);
    try std.testing.expectEqual(@as(u32, 2), ownership.get("alias").?.uid);
    try std.testing.expectEqual(@as(u32, 3), ownership.get("alias").?.gid);
}

test "merged tree applies whiteouts and hardlinks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const layer1 = "zig-cache/test-rootfs-merged-tree-1.tar";
    const layer2 = "zig-cache/test-rootfs-merged-tree-2.tar";
    defer Io.Dir.cwd().deleteFile(io, layer1) catch {};
    defer Io.Dir.cwd().deleteFile(io, layer2) catch {};

    var first = std.ArrayList(u8).empty;
    defer first.deinit(allocator);
    try appendTestTarEntry(allocator, &first, "etc", '5', "", null);
    try appendTestTarEntry(allocator, &first, "etc/old", '0', "old", null);
    try appendTestTarEntry(allocator, &first, "target", '0', "same", null);
    try finishTestTar(allocator, &first);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = layer1, .data = first.items });

    var second = std.ArrayList(u8).empty;
    defer second.deinit(allocator);
    try appendTestTarEntry(allocator, &second, "etc/.wh.old", '0', "", null);
    try appendTestTarEntry(allocator, &second, "alias", '1', "", "target");
    try finishTestTar(allocator, &second);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = layer2, .data = second.items });

    const layers = [_]LayerInput{
        .{ .media_type = "application/vnd.oci.image.layer.v1.tar", .path = layer1 },
        .{ .media_type = "application/vnd.oci.image.layer.v1.tar", .path = layer2 },
    };
    var tree = try buildMergedTree(allocator, io, &layers);
    defer tree.deinit(allocator);

    try std.testing.expect(tree.entries.get("etc/old") == null);
    const target = tree.entries.get("target") orelse return error.BadManifest;
    const alias = tree.entries.get("alias") orelse return error.BadManifest;
    try std.testing.expectEqual(MergedEntryKind.file, target.kind);
    try std.testing.expectEqual(MergedEntryKind.file, alias.kind);
    try std.testing.expectEqual(target.inode_id, alias.inode_id);
    const source = try tree.fileSource(target.inode_id);
    try std.testing.expect(source == .file);
    try std.testing.expectEqualStrings(layer1, source.file.path);
    const data = try readFileSourceAlloc(allocator, io, source);
    defer allocator.free(data);
    try std.testing.expectEqualStrings("same", data);
}

test "merged tree retains hardlink sources until the final path is removed" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-merged-tree-hardlink-lifetime";
    const layer1 = tmp ++ "/layer1.tar";
    const layer2 = tmp ++ "/layer2.tar";
    const layer3 = tmp ++ "/layer3.tar";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);

    var first = std.ArrayList(u8).empty;
    defer first.deinit(allocator);
    try appendTestTarEntry(allocator, &first, "target", '0', "same", null);
    try appendTestTarEntry(allocator, &first, "alias", '1', "", "target");
    try finishTestTar(allocator, &first);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = layer1, .data = first.items });

    var second = std.ArrayList(u8).empty;
    defer second.deinit(allocator);
    try appendTestTarEntry(allocator, &second, ".wh.target", '0', "", null);
    try finishTestTar(allocator, &second);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = layer2, .data = second.items });

    var third = std.ArrayList(u8).empty;
    defer third.deinit(allocator);
    try appendTestTarEntry(allocator, &third, ".wh.alias", '0', "", null);
    try finishTestTar(allocator, &third);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = layer3, .data = third.items });

    var tree = MergedTree.init(allocator);
    defer tree.deinit(allocator);
    try applyLayerToMergedTree(allocator, io, &tree, .{ .media_type = "application/vnd.oci.image.layer.v1.tar", .path = layer1 });
    try std.testing.expectEqual(@as(usize, 1), tree.file_sources.count());
    const target = tree.entries.get("target") orelse return error.BadManifest;
    try std.testing.expectEqual(@as(usize, 2), tree.file_link_counts.get(target.inode_id).?);

    try applyLayerToMergedTree(allocator, io, &tree, .{ .media_type = "application/vnd.oci.image.layer.v1.tar", .path = layer2 });
    try std.testing.expect(tree.entries.get("target") == null);
    const alias = tree.entries.get("alias") orelse return error.BadManifest;
    const alias_data = try readFileSourceAlloc(allocator, io, try tree.fileSource(alias.inode_id));
    defer allocator.free(alias_data);
    try std.testing.expectEqualStrings("same", alias_data);
    try std.testing.expectEqual(@as(usize, 1), tree.file_link_counts.get(alias.inode_id).?);

    try applyLayerToMergedTree(allocator, io, &tree, .{ .media_type = "application/vnd.oci.image.layer.v1.tar", .path = layer3 });
    try std.testing.expectEqual(@as(usize, 0), tree.file_sources.count());
    try std.testing.expectEqual(@as(usize, 0), tree.file_link_counts.count());
}

test "merged tree replaces a file without scanning or removing siblings" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-merged-tree-file-replacement";
    const layer1 = tmp ++ "/layer1.tar";
    const layer2 = tmp ++ "/layer2.tar";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);

    var first = std.ArrayList(u8).empty;
    defer first.deinit(allocator);
    try appendTestTarEntry(allocator, &first, "app/target", '0', "old", null);
    try appendTestTarEntry(allocator, &first, "app/sibling", '0', "keep", null);
    try finishTestTar(allocator, &first);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = layer1, .data = first.items });

    var second = std.ArrayList(u8).empty;
    defer second.deinit(allocator);
    try appendTestTarEntry(allocator, &second, "app/target", '0', "new", null);
    try finishTestTar(allocator, &second);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = layer2, .data = second.items });

    var tree = MergedTree.init(allocator);
    defer tree.deinit(allocator);
    try applyLayerToMergedTree(allocator, io, &tree, .{ .media_type = "application/vnd.oci.image.layer.v1.tar", .path = layer1 });
    try applyLayerToMergedTree(allocator, io, &tree, .{ .media_type = "application/vnd.oci.image.layer.v1.tar", .path = layer2 });

    const target = tree.entries.get("app/target") orelse return error.BadManifest;
    const target_data = try readFileSourceAlloc(allocator, io, try tree.fileSource(target.inode_id));
    defer allocator.free(target_data);
    try std.testing.expectEqualStrings("new", target_data);

    const sibling = tree.entries.get("app/sibling") orelse return error.BadManifest;
    const sibling_data = try readFileSourceAlloc(allocator, io, try tree.fileSource(sibling.inode_id));
    defer allocator.free(sibling_data);
    try std.testing.expectEqualStrings("keep", sibling_data);
    try std.testing.expectEqual(@as(usize, 2), tree.file_sources.count());
    try std.testing.expectEqual(@as(usize, 2), tree.file_link_counts.count());
}

test "merged tree spools gzip layers to file sources" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-merged-tree-gzip";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);

    var tar_bytes = std.ArrayList(u8).empty;
    defer tar_bytes.deinit(allocator);
    try appendTestTarEntry(allocator, &tar_bytes, "etc", '5', "", null);
    try appendTestTarEntry(allocator, &tar_bytes, "etc/gzip", '0', "compressed\n", null);
    try finishTestTar(allocator, &tar_bytes);
    const gzip_bytes = try gzipTestBytes(allocator, tar_bytes.items);
    defer allocator.free(gzip_bytes);

    const layer = tmp ++ "/layer.tar.gz";
    const spill_dir = tmp ++ "/spill";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = layer, .data = gzip_bytes });

    var tree = try buildMergedTree(allocator, io, &.{.{ .media_type = "application/vnd.oci.image.layer.v1.tar+gzip", .path = layer, .spill_dir = spill_dir }});
    defer tree.deinit(allocator);

    const entry = tree.entries.get("etc/gzip") orelse return error.BadManifest;
    const source = try tree.fileSource(entry.inode_id);
    try std.testing.expect(source == .file);
    try std.testing.expect(std.mem.startsWith(u8, source.file.path, spill_dir));
    try std.testing.expect(!std.mem.eql(u8, source.file.path, layer));
    const data = try readFileSourceAlloc(allocator, io, source);
    defer allocator.free(data);
    try std.testing.expectEqualStrings("compressed\n", data);
}

test "merged tree matches staging layer semantics" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-merged-tree-staging-compare";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);

    const layer1 = tmp ++ "/layer1.tar";
    const layer2 = tmp ++ "/layer2.tar";

    var first = std.ArrayList(u8).empty;
    defer first.deinit(allocator);
    var global_pax = [_]u8{0} ** 512;
    var global_pax_len: usize = 0;
    global_pax_len += writePaxRecord(global_pax[global_pax_len..], "uid", "1000");
    global_pax_len += writePaxRecord(global_pax[global_pax_len..], "gid", "1001");
    try appendTestTarEntry(allocator, &first, "global-pax", 'g', global_pax[0..global_pax_len], null);
    try appendTestTarEntry(allocator, &first, "etc", '5', "", null);
    try appendTestTarEntry(allocator, &first, "etc/old", '0', "old\n", null);
    try appendTestTarEntry(allocator, &first, "bin/tool", '0', "tool\n", null);
    try appendTestTarEntry(allocator, &first, "bin/tool-link", '2', "", "tool");
    const cap = [_]u8{ 1, 0, 0, 2 } ++ [_]u8{0} ** 16;
    var xattr_pax = [_]u8{0} ** 512;
    const xattr_pax_len = writePaxRecord(&xattr_pax, "SCHILY.xattr.security.capability", &cap);
    try appendTestTarEntry(allocator, &first, "pax", 'x', xattr_pax[0..xattr_pax_len], null);
    try appendTestTarEntry(allocator, &first, "bin/ping", '0', "ping", null);
    try finishTestTar(allocator, &first);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = layer1, .data = first.items });

    var second = std.ArrayList(u8).empty;
    defer second.deinit(allocator);
    try appendTestTarEntry(allocator, &second, "etc/.wh.old", '0', "", null);
    try appendTestTarEntry(allocator, &second, "target", '0', "same\n", null);
    try appendTestTarEntry(allocator, &second, "alias", '1', "", "target");
    try appendTestTarEntry(allocator, &second, "var/lib", '5', "", null);
    try appendTestTarEntry(allocator, &second, "var/lib/state", '0', "state\n", null);
    try finishTestTar(allocator, &second);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = layer2, .data = second.items });

    const staging_path = tmp ++ "/staging";
    var staging = try Io.Dir.cwd().createDirPathOpen(io, staging_path, .{
        .open_options = .{ .iterate = true, .access_sub_paths = true },
    });
    defer staging.close(io);
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var xattrs = XattrMap.init(allocator);
    defer xattrs_mod.deinit(allocator, &xattrs);
    const layers = [_]LayerInput{
        .{ .media_type = "application/vnd.oci.image.layer.v1.tar", .path = layer1 },
        .{ .media_type = "application/vnd.oci.image.layer.v1.tar", .path = layer2 },
    };
    for (layers) |layer| {
        try applyLayer(allocator, io, staging, layer.path, layer.media_type, &ownership, &xattrs, case_sensitive_test_options);
    }

    var tree = try buildMergedTree(allocator, io, &layers);
    defer tree.deinit(allocator);
    try expectMergedTreeMatchesStaging(allocator, io, staging, &ownership, &xattrs, &tree);
}

test "merged tree rejects symlink traversal" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const layer = "zig-cache/test-rootfs-merged-tree-symlink.tar";
    defer Io.Dir.cwd().deleteFile(io, layer) catch {};

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);
    try appendTestTarEntry(allocator, &bytes, "link", '2', "", "/tmp");
    try appendTestTarEntry(allocator, &bytes, "link/escape", '0', "bad", null);
    try finishTestTar(allocator, &bytes);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = layer, .data = bytes.items });

    const layers = [_]LayerInput{.{ .media_type = "application/vnd.oci.image.layer.v1.tar", .path = layer }};
    var tree = MergedTree.init(allocator);
    defer tree.deinit(allocator);
    try std.testing.expectError(error.SymlinkTraversal, applyLayerToMergedTree(allocator, io, &tree, layers[0]));
}

test "merged tree rejects hardlink that replaces target ancestor" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const layer = "zig-cache/test-rootfs-merged-tree-hardlink-ancestor.tar";
    defer Io.Dir.cwd().deleteFile(io, layer) catch {};

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);
    try appendTestTarEntry(allocator, &bytes, "dir", '5', "", null);
    try appendTestTarEntry(allocator, &bytes, "dir/file", '0', "data", null);
    try appendTestTarEntry(allocator, &bytes, "dir", '1', "", "dir/file");
    try finishTestTar(allocator, &bytes);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = layer, .data = bytes.items });

    var tree = MergedTree.init(allocator);
    defer tree.deinit(allocator);
    try std.testing.expectError(
        error.BadHardlinkTarget,
        applyLayerToMergedTree(allocator, io, &tree, .{ .media_type = "application/vnd.oci.image.layer.v1.tar", .path = layer }),
    );
}

test "regular files clear stale ownership when replacing directories" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-file-replaces-dir";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true, .access_sub_paths = true } });
    defer root.close(io);
    try root.createDirPath(io, "etc/conf.d");
    try root.writeFile(io, .{ .sub_path = "etc/conf.d/file", .data = "old" });
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    try ownership_mod.record(allocator, &ownership, "etc/conf.d/file", .{ .uid = 1, .gid = 1 });
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);
    var payload = [_]u8{0} ** 512;
    @memcpy(payload[0..3], "new");
    var reader: Io.Reader = .fixed(&payload);

    try writeRegularFile(allocator, io, root, &ownership, &created, "etc/conf.d", &reader, 3, 0o644, case_sensitive_test_options);
    try std.testing.expect(!ownership.contains("etc/conf.d/file"));
    const stat = try root.statFile(io, "etc/conf.d", .{ .follow_symlinks = false });
    try std.testing.expectEqual(Io.File.Kind.file, stat.kind);
}

test "tar layer rejects symlink traversal from earlier entry" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-symlink-traversal";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    var root = try Io.Dir.cwd().createDirPathOpen(io, tmp, .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    try root.symLink(io, "/tmp", "link", .{});
    try std.testing.expectError(error.SymlinkTraversal, ensureNoSymlinkPath(allocator, io, root, "link/escape", true));
    var reader: Io.Reader = .fixed("");
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var created = CreatedPathMap.init(allocator);
    defer deinitCreatedPaths(allocator, &created);
    try std.testing.expectError(
        error.SymlinkTraversal,
        writeRegularFile(allocator, io, root, &ownership, &created, "link/escape", &reader, 0, 0o644, case_sensitive_test_options),
    );
}

test "unsupported tar entry types fail closed" {
    const allocator = std.testing.allocator;
    var block = [_]u8{0} ** 1024;
    makeTarHeader(block[0..512], "dev/null", '3', 0);
    var reader: Io.Reader = .fixed(&block);
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);

    try std.testing.expectError(
        error.UnsupportedTarEntryType,
        applyTarLayer(allocator, std.testing.io, tmp.dir, &reader, &ownership),
    );
}

test "truncated tar headers fail closed" {
    const allocator = std.testing.allocator;
    var block = [_]u8{0} ** 511;
    var reader: Io.Reader = .fixed(&block);
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);

    try std.testing.expectError(error.TruncatedTarHeader, applyTarLayer(allocator, std.testing.io, tmp.dir, &reader, &ownership));
}

test "global pax headers are consumed before following entries" {
    const allocator = std.testing.allocator;
    var block = [_]u8{0} ** 2560;
    const record = "13 comment=x\n";
    makeTarHeader(block[0..512], "global-pax", 'g', record.len);
    @memcpy(block[512 .. 512 + record.len], record);
    makeTarHeader(block[1024..1536], "file", '0', 1);
    block[1536] = 'x';
    var reader: Io.Reader = .fixed(&block);
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);

    try applyTarLayer(allocator, std.testing.io, tmp.dir, &reader, &ownership);
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "file", allocator, .limited(8));
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("x", bytes);
}

test "global pax uid gid defaults apply to following entries" {
    const allocator = std.testing.allocator;
    var block = [_]u8{0} ** 2560;
    const record = "10 uid=12\n10 gid=34\n";
    makeTarHeader(block[0..512], "global-pax", 'g', record.len);
    @memcpy(block[512 .. 512 + record.len], record);
    makeTarHeader(block[1024..1536], "file", '0', 1);
    block[1536] = 'x';
    var reader: Io.Reader = .fixed(&block);
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);

    try applyTarLayer(allocator, std.testing.io, tmp.dir, &reader, &ownership);
    try std.testing.expectEqual(@as(u32, 12), ownership.get("file").?.uid);
    try std.testing.expectEqual(@as(u32, 34), ownership.get("file").?.gid);
}

test "global pax extraction fields fail closed" {
    const allocator = std.testing.allocator;
    var block = [_]u8{0} ** 1024;
    const record = "13 path=file\n";
    makeTarHeader(block[0..512], "global-pax", 'g', record.len);
    @memcpy(block[512 .. 512 + record.len], record);
    var reader: Io.Reader = .fixed(&block);
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);

    try std.testing.expectError(
        error.UnsupportedGlobalPaxRecord,
        applyTarLayer(allocator, std.testing.io, tmp.dir, &reader, &ownership),
    );
}

test "pax size overrides ustar file size" {
    const allocator = std.testing.allocator;
    var block = [_]u8{0} ** 2560;
    const record = "10 size=5\n";
    makeTarHeader(block[0..512], "pax", 'x', record.len);
    @memcpy(block[512 .. 512 + record.len], record);
    makeTarHeader(block[1024..1536], "file", '0', 0);
    @memcpy(block[1536..1541], "hello");
    var reader: Io.Reader = .fixed(&block);
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);

    try applyTarLayer(allocator, std.testing.io, tmp.dir, &reader, &ownership);
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "file", allocator, .limited(16));
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("hello", bytes);
}

test "root directory tar entry is ignored" {
    const allocator = std.testing.allocator;
    var block = [_]u8{0} ** 1024;
    makeTarHeader(block[0..512], ".", '5', 0);
    var reader: Io.Reader = .fixed(&block);
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);

    try applyTarLayer(allocator, std.testing.io, tmp.dir, &reader, &ownership);
}

test "root non-directory tar entry fails closed" {
    const allocator = std.testing.allocator;
    var block = [_]u8{0} ** 1024;
    makeTarHeader(block[0..512], ".", '0', 0);
    var reader: Io.Reader = .fixed(&block);
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);

    try std.testing.expectError(error.UnsafeTarPath, applyTarLayer(allocator, std.testing.io, tmp.dir, &reader, &ownership));
}

test "malformed pax records fail closed" {
    const allocator = std.testing.allocator;
    var block = [_]u8{0} ** 512;
    @memcpy(block[0..2], "1 ");
    var reader: Io.Reader = .fixed(&block);
    var pax: PendingPax = .{};
    defer pax.clear(allocator);
    try std.testing.expectError(error.BadPaxHeader, readPaxHeader(allocator, &reader, 2, &pax));
}

test "pax xattr records fail closed" {
    const allocator = std.testing.allocator;
    const record = "24 SCHILY.xattr.foo=bar\n";
    var block = [_]u8{0} ** 512;
    @memcpy(block[0..record.len], record);
    var reader: Io.Reader = .fixed(&block);
    var pax: PendingPax = .{};
    defer pax.clear(allocator);

    try std.testing.expectError(error.UnsupportedTarXattr, readPaxHeader(allocator, &reader, record.len, &pax));
}

test "pax security capability xattr records are retained" {
    const allocator = std.testing.allocator;
    const cap = [_]u8{ 1, 0, 0, 2 } ++ [_]u8{0} ** 16;
    var block = [_]u8{0} ** 512;
    const len = writePaxRecord(&block, "SCHILY.xattr.security.capability", &cap);
    var reader: Io.Reader = .fixed(&block);
    var pax: PendingPax = .{};
    defer pax.clear(allocator);

    try readPaxHeader(allocator, &reader, len, &pax);
    try std.testing.expectEqual(@as(usize, 1), pax.xattrs.items.len);
    try std.testing.expectEqualStrings(xattrs_mod.security_capability_name, pax.xattrs.items[0].name);
    try std.testing.expectEqualSlices(u8, &cap, pax.xattrs.items[0].value);
}

test "global pax xattrs fail closed" {
    const allocator = std.testing.allocator;
    const cap = [_]u8{ 1, 0, 0, 2 } ++ [_]u8{0} ** 16;
    var block = [_]u8{0} ** 1024;
    const len = writePaxRecord(block[512..], "SCHILY.xattr.security.capability", &cap);
    makeTarHeader(block[0..512], "global-pax", 'g', len);
    var reader: Io.Reader = .fixed(&block);
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);

    try std.testing.expectError(error.UnsupportedTarXattr, applyTarLayer(allocator, std.testing.io, tmp.dir, &reader, &ownership));
}

test "tar layer records file security capability xattrs" {
    const allocator = std.testing.allocator;
    const cap = [_]u8{ 1, 0, 0, 2 } ++ [_]u8{0} ** 16;
    var block = [_]u8{0} ** 3072;
    const len = writePaxRecord(block[512..], "SCHILY.xattr.security.capability", &cap);
    makeTarHeader(block[0..512], "pax", 'x', len);
    makeTarHeader(block[1024..1536], "bin/ping", '0', 4);
    @memcpy(block[1536..1540], "ping");
    var reader: Io.Reader = .fixed(&block);
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var ownership = OwnershipMap.init(allocator);
    defer ownership_mod.deinit(allocator, &ownership);
    var xattrs = XattrMap.init(allocator);
    defer xattrs_mod.deinit(allocator, &xattrs);

    try applyTarLayerWithXattrs(allocator, std.testing.io, tmp.dir, &reader, &ownership, &xattrs, case_sensitive_test_options);
    const entry = xattrs.get("bin/ping").?;
    try std.testing.expectEqual(@as(usize, 1), entry.attrs.len);
    try std.testing.expectEqualStrings(xattrs_mod.security_capability_name, entry.attrs[0].name);
    try std.testing.expectEqualSlices(u8, &cap, entry.attrs[0].value);
}

test "pax sparse records fail closed" {
    const allocator = std.testing.allocator;
    const record = "20 GNU.sparse.map=0\n";
    var block = [_]u8{0} ** 512;
    @memcpy(block[0..record.len], record);
    var reader: Io.Reader = .fixed(&block);
    var pax: PendingPax = .{};
    defer pax.clear(allocator);

    try std.testing.expectError(error.UnsupportedTarSparse, readPaxHeader(allocator, &reader, record.len, &pax));
}

test "oversized binary tar numbers fail closed" {
    var raw = [_]u8{0xff} ** 12;
    raw[0] = 0x80;
    try std.testing.expectError(error.BadTarHeader, parseTarNumber(&raw));
}

test "oversized binary tar modes fail closed" {
    var header = [_]u8{0} ** 512;
    header[100] = 0x80;
    header[103] = 0x01;
    try std.testing.expectError(error.BadTarHeader, tarMode(&header));
}

fn fuzzTarLayer(_: void, s: *std.testing.Smith) !void {
    // OCI layers are attacker-influenced tar streams. The applier must reject
    // malformed data, traversal attempts, and odd link metadata without
    // escaping the scratch root or crashing.
    var buf: [8192]u8 = undefined;
    const len = s.slice(&buf);

    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ownership = OwnershipMap.init(arena_state.allocator());
    defer ownership_mod.deinit(arena_state.allocator(), &ownership);

    var reader: Io.Reader = .fixed(buf[0..len]);
    applyTarLayer(arena_state.allocator(), std.testing.io, tmp.dir, &reader, &ownership) catch return;
}

test "fuzz OCI tar layer parsing" {
    try std.testing.fuzz({}, fuzzTarLayer, .{});
}

fn fuzzMergedTreeTarLayer(_: void, s: *std.testing.Smith) !void {
    // The native writer consumes the same attacker-influenced tar shape without
    // a host staging directory. It must fail closed without corrupting the
    // in-memory tree.
    var buf: [8192]u8 = undefined;
    const len = s.slice(&buf);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tree = MergedTree.init(arena_state.allocator());
    defer tree.deinit(arena_state.allocator());

    var reader: Io.Reader = .fixed(buf[0..len]);
    applyTarLayerToMergedTree(arena_state.allocator(), &reader, &tree) catch return;
}

test "fuzz OCI tar layer merged tree parsing" {
    try std.testing.fuzz({}, fuzzMergedTreeTarLayer, .{});
}
