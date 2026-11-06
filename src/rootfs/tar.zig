//! OCI layer tar application.
//!
//! This module handles attacker-influenced tar streams from digest-verified OCI
//! layers and is intentionally strict: unsupported metadata fails closed rather
//! than being silently dropped.

const std = @import("std");
const TestDir = @import("../test_dir.zig").TestDir;
const fuzz_support = @import("../fuzz_support.zig");
const oci = @import("oci.zig");
const xattrs_mod = @import("xattrs.zig");

const Io = std.Io;

pub const max_content_bytes: u64 = 32 << 30;
const max_archive_entries: u64 = 1_000_000;
const max_pax_header_bytes: u64 = 1 << 20;

pub const Ownership = struct {
    uid: u32,
    gid: u32,
};

pub const LayerInput = struct {
    media_type: []const u8,
    path: []const u8,
    /// Gzip layers are decompressed here so file data stays source-backed.
    spill_dir: []const u8,
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
        // Decompress once into the spill dir so the seekable parser can keep
        // regular file payloads source-backed instead of buffering them.
        const spooled = try spoolGzipTarLayer(allocator, io, layer.path, layer.spill_dir);
        defer allocator.free(spooled);
        try applySeekableTarLayerToMergedTree(allocator, io, tree, spooled);
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

/// Walks the header records of a tar stream. Every tar reader goes through
/// it, so record framing, header checksums, numeric fields, and payload
/// padding are parsed in one place. The caller may read the current payload;
/// `next` skips whatever is left of it.
pub const RecordIterator = struct {
    reader: *Io.Reader,
    /// Stream offset of the next byte `reader` returns.
    offset: u64 = 0,
    payload_left: u64 = 0,
    padding_left: usize = 0,

    pub const Record = struct {
        header: [512]u8,
        /// Payload size from the header.
        size: u64,
        /// Stream offset of the first payload byte.
        payload_offset: u64,

        pub fn kind(record: *const Record) u8 {
            return record.header[156];
        }

        pub fn name(record: *const Record, allocator: std.mem.Allocator) ![]u8 {
            return tarFullName(allocator, &record.header);
        }
    };

    /// Returns null at the end of the stream or at the first zero block.
    pub fn next(self: *RecordIterator) !?Record {
        try self.reader.discardAll64(self.payload_left);
        self.offset += self.payload_left;
        self.payload_left = 0;
        // The stream may end straight after the last payload.
        self.offset += try self.reader.discardShort(self.padding_left);
        self.padding_left = 0;

        var header: [512]u8 = undefined;
        const n = try self.reader.readSliceShort(&header);
        if (n == 0) return null;
        if (n != header.len) return error.TruncatedTarHeader;
        self.offset += header.len;
        if (isZeroBlock(&header)) return null;
        try verifyTarHeader(&header);
        const size = try tarSize(&header);
        try self.setPayloadSize(size);
        return .{ .header = header, .size = size, .payload_offset = self.offset };
    }

    /// Replaces the current record's payload size, as a pax `size` record
    /// does. Call it before reading any of the payload. Sizes above
    /// `max_content_bytes` fail, so skipping a payload cannot overflow the
    /// reader's position.
    pub fn setPayloadSize(self: *RecordIterator, size: u64) !void {
        if (size > max_content_bytes) return error.RootFSArchiveTooLarge;
        self.payload_left = size;
        self.padding_left = @intCast((512 - size % 512) % 512);
    }

    pub fn readPayloadAlloc(self: *RecordIterator, allocator: std.mem.Allocator, max_bytes: u64) ![]u8 {
        if (self.payload_left > max_bytes) return error.TarHeaderTooLarge;
        const bytes = try allocator.alloc(u8, @intCast(self.payload_left));
        errdefer allocator.free(bytes);
        try self.reader.readSliceAll(bytes);
        self.offset += bytes.len;
        self.payload_left = 0;
        return bytes;
    }

    pub fn streamPayload(self: *RecordIterator, writer: *Io.Writer) !void {
        try self.reader.streamExact64(writer, self.payload_left);
        self.offset += self.payload_left;
        self.payload_left = 0;
    }
};

const LayerLimits = struct {
    payload_bytes: u64 = 0,
    entries: u64 = 0,
    xattrs: u64 = 0,
    xattr_value_bytes: u64 = 0,
};

const CreatedPathMap = std.StringHashMap(void);
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

fn applySeekableTarLayerToMergedTree(
    allocator: std.mem.Allocator,
    io: Io,
    tree: *MergedTree,
    layer_path: []const u8,
) !void {
    var file = try Io.Dir.cwd().openFile(io, layer_path, .{});
    defer file.close(io);
    // Positional reads skip regular file payloads without reading them; the
    // tree keeps them as slices of the layer file.
    var buffer: [4096]u8 = undefined;
    var reader: Io.File.Reader = .init(file, io, &buffer);
    applyTarRecordsToMergedTree(allocator, tree, layer_path, &reader.interface) catch |err| switch (err) {
        error.ReadFailed => return reader.err orelse err,
        else => |e| return e,
    };
}

fn applyTarRecordsToMergedTree(
    allocator: std.mem.Allocator,
    tree: *MergedTree,
    layer_path: []const u8,
    reader: *Io.Reader,
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

    var records: RecordIterator = .{ .reader = reader };
    while (try records.next()) |record| {
        const kind = record.kind();

        if (kind == 'L') {
            try accountTarMetadataRecord(&limits, record.size);
            if (long_name) |p| allocator.free(p);
            long_name = try readTarString(allocator, &records);
            continue;
        }
        if (kind == 'K') {
            try accountTarMetadataRecord(&limits, record.size);
            if (long_link) |p| allocator.free(p);
            long_link = try readTarString(allocator, &records);
            continue;
        }
        if (kind == 'x') {
            try accountTarMetadataRecord(&limits, record.size);
            pax.clear(allocator);
            try readPaxHeader(allocator, &records, &pax);
            continue;
        }
        if (kind == 'g') {
            try accountTarMetadataRecord(&limits, record.size);
            try readPaxHeader(allocator, &records, &global_pax);
            try validateGlobalPax(global_pax);
            continue;
        }

        try accountTarEntry(&limits);

        // The deferred reset below clears pax.path and long_name first, so
        // decide ownership of raw_name now.
        const owns_name = pax.path == null and long_name == null;
        const raw_name = if (pax.path) |p|
            p
        else if (long_name) |p|
            p
        else
            try record.name(allocator);
        defer if (owns_name) allocator.free(raw_name);
        const payload_size = pax.size orelse record.size;
        try records.setPayloadSize(payload_size);
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
                continue;
            },
            else => |e| return e,
        };
        defer allocator.free(rel);
        const entry_ownership = try tarOwnership(&record.header, pax, global_pax);

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
                const source = try fileSourceFromLayer(allocator, layer_path, record.payload_offset, payload_size);
                errdefer source.deinit(allocator);
                try putMergedFile(allocator, tree, &created, rel, source, try tarMode(&record.header), entry_ownership, pax.xattrs.items);
            },
            '5' => {
                if (pax.xattrs.items.len != 0) return error.UnsupportedTarXattr;
                try putMergedDirectory(allocator, tree, &created, rel, try tarMode(&record.header), entry_ownership);
            },
            '2' => {
                if (pax.xattrs.items.len != 0) return error.UnsupportedTarXattr;
                const raw_link = if (pax.linkpath) |p| p else if (long_link) |p| p else tarLinkName(&record.header);
                try putMergedSymlink(allocator, tree, &created, rel, raw_link, entry_ownership);
            },
            '1' => {
                try addXattrBytes(&limits, pax.xattrs.items);
                const raw_link = if (pax.linkpath) |p| p else if (long_link) |p| p else tarLinkName(&record.header);
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

fn readTarString(allocator: std.mem.Allocator, records: *RecordIterator) ![]u8 {
    const bytes = try records.readPayloadAlloc(allocator, max_pax_header_bytes);
    defer allocator.free(bytes);
    return allocator.dupe(u8, trimTrailingNul(bytes));
}

fn readPaxHeader(allocator: std.mem.Allocator, records: *RecordIterator, out: *PendingPax) !void {
    const bytes = try records.readPayloadAlloc(allocator, max_pax_header_bytes);
    defer allocator.free(bytes);
    try parsePaxHeaderBytes(allocator, bytes, out);
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

const IncomingEntryKind = enum {
    directory,
    non_directory,
};

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
    if (isTarRootPath(raw)) return error.RootTarPath;
    return normalizeRelativePath(allocator, raw);
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

fn trimTrailingNul(bytes: []u8) []u8 {
    var end = bytes.len;
    while (end > 0 and bytes[end - 1] == 0) end -= 1;
    return bytes[0..end];
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
}

test "merged tree applies whiteouts and hardlinks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const layer1 = try tmp_dir.path("layer1.tar");
    const layer2 = try tmp_dir.path("layer2.tar");

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
        plainTestLayer(layer1),
        plainTestLayer(layer2),
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
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const layer1 = try tmp_dir.path("layer1.tar");
    const layer2 = try tmp_dir.path("layer2.tar");
    const layer3 = try tmp_dir.path("layer3.tar");

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
    try applyLayerToMergedTree(allocator, io, &tree, plainTestLayer(layer1));
    try std.testing.expectEqual(@as(usize, 1), tree.file_sources.count());
    const target = tree.entries.get("target") orelse return error.BadManifest;
    try std.testing.expectEqual(@as(usize, 2), tree.file_link_counts.get(target.inode_id).?);

    try applyLayerToMergedTree(allocator, io, &tree, plainTestLayer(layer2));
    try std.testing.expect(tree.entries.get("target") == null);
    const alias = tree.entries.get("alias") orelse return error.BadManifest;
    const alias_data = try readFileSourceAlloc(allocator, io, try tree.fileSource(alias.inode_id));
    defer allocator.free(alias_data);
    try std.testing.expectEqualStrings("same", alias_data);
    try std.testing.expectEqual(@as(usize, 1), tree.file_link_counts.get(alias.inode_id).?);

    try applyLayerToMergedTree(allocator, io, &tree, plainTestLayer(layer3));
    try std.testing.expectEqual(@as(usize, 0), tree.file_sources.count());
    try std.testing.expectEqual(@as(usize, 0), tree.file_link_counts.count());
}

test "merged tree replaces a file without scanning or removing siblings" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const layer1 = try tmp_dir.path("layer1.tar");
    const layer2 = try tmp_dir.path("layer2.tar");

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
    try applyLayerToMergedTree(allocator, io, &tree, plainTestLayer(layer1));
    try applyLayerToMergedTree(allocator, io, &tree, plainTestLayer(layer2));

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
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();

    var tar_bytes = std.ArrayList(u8).empty;
    defer tar_bytes.deinit(allocator);
    try appendTestTarEntry(allocator, &tar_bytes, "etc", '5', "", null);
    try appendTestTarEntry(allocator, &tar_bytes, "etc/gzip", '0', "compressed\n", null);
    try finishTestTar(allocator, &tar_bytes);
    const gzip_bytes = try gzipTestBytes(allocator, tar_bytes.items);
    defer allocator.free(gzip_bytes);

    const layer = try tmp_dir.path("layer.tar.gz");
    const spill_dir = try tmp_dir.path("spill");
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

test "merged tree rejects symlink traversal" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const layer = try tmp_dir.path("symlink.tar");

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);
    try appendTestTarEntry(allocator, &bytes, "link", '2', "", "/tmp");
    try appendTestTarEntry(allocator, &bytes, "link/escape", '0', "bad", null);
    try finishTestTar(allocator, &bytes);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = layer, .data = bytes.items });

    const layers = [_]LayerInput{plainTestLayer(layer)};
    var tree = MergedTree.init(allocator);
    defer tree.deinit(allocator);
    try std.testing.expectError(error.SymlinkTraversal, applyLayerToMergedTree(allocator, io, &tree, layers[0]));
}

test "merged tree rejects hardlink that replaces target ancestor" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const layer = try tmp_dir.path("hardlink-ancestor.tar");

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
        applyLayerToMergedTree(allocator, io, &tree, plainTestLayer(layer)),
    );
}

test "oversized binary tar numbers fail closed" {
    var raw = @as([12]u8, @splat(0xff));
    raw[0] = 0x80;
    try std.testing.expectError(error.BadTarHeader, parseTarNumber(&raw));
}

test "oversized binary tar modes fail closed" {
    var header = @as([512]u8, @splat(0));
    header[100] = 0x80;
    header[103] = 0x01;
    try std.testing.expectError(error.BadTarHeader, tarMode(&header));
}

const plain_tar_media_type = "application/vnd.oci.image.layer.v1.tar";

/// Writes `bytes` into `tmp` and applies them as a plain tar layer through the
/// seekable parser that production uses. File sources keep pointing into
/// `tmp`, so read them before cleaning it up.
fn applyTestLayer(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    tree: *MergedTree,
    name: []const u8,
    bytes: []const u8,
) !void {
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path[0..], name });
    defer allocator.free(path);
    try applyLayerToMergedTree(allocator, io, tree, plainTestLayer(path));
}

/// Plain tar layers never spill; tests point the spill dir at the layer's own
/// directory.
fn plainTestLayer(path: []const u8) LayerInput {
    return .{ .media_type = plain_tar_media_type, .path = path, .spill_dir = std.fs.path.dirname(path).? };
}

fn expectMergedFileData(allocator: std.mem.Allocator, tree: *const MergedTree, rel: []const u8, expected: []const u8) !void {
    const entry = tree.entries.get(rel) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(MergedEntryKind.file, entry.kind);
    const data = try readFileSourceAlloc(allocator, std.testing.io, try tree.fileSource(entry.inode_id));
    defer allocator.free(data);
    try std.testing.expectEqualStrings(expected, data);
}

test "merged tree whiteouts ignore absent targets and reject dot targets" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tree = MergedTree.init(allocator);
    defer tree.deinit(allocator);

    var layer = std.ArrayList(u8).empty;
    defer layer.deinit(allocator);
    try appendTestTarEntry(allocator, &layer, "etc/.wh.missing", '0', "", null);
    try finishTestTar(allocator, &layer);
    try applyTestLayer(allocator, &tmp, &tree, "absent.tar", layer.items);
    try std.testing.expect(tree.entries.get("etc/missing") == null);

    for ([_][]const u8{ ".wh..", ".wh..." }) |name| {
        layer.clearRetainingCapacity();
        try appendTestTarEntry(allocator, &layer, name, '0', "", null);
        try finishTestTar(allocator, &layer);
        try std.testing.expectError(error.BadWhiteout, applyTestLayer(allocator, &tmp, &tree, "dot.tar", layer.items));
    }
}

test "merged tree whiteouts keep entries created earlier in the same layer" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var lower = std.ArrayList(u8).empty;
    defer lower.deinit(allocator);
    try appendTestTarEntry(allocator, &lower, "dir/lower", '0', "lower", null);
    try appendTestTarEntry(allocator, &lower, "dir/sub/lower", '0', "lower", null);
    try finishTestTar(allocator, &lower);

    var opaque_layer = std.ArrayList(u8).empty;
    defer opaque_layer.deinit(allocator);
    try appendTestTarEntry(allocator, &opaque_layer, "dir/current", '0', "current", null);
    try appendTestTarEntry(allocator, &opaque_layer, "dir/sub/current", '0', "current", null);
    try appendTestTarEntry(allocator, &opaque_layer, "dir/.wh..wh..opq", '0', "", null);
    try finishTestTar(allocator, &opaque_layer);

    var opaque_tree = MergedTree.init(allocator);
    defer opaque_tree.deinit(allocator);
    try applyTestLayer(allocator, &tmp, &opaque_tree, "lower.tar", lower.items);
    try applyTestLayer(allocator, &tmp, &opaque_tree, "opaque.tar", opaque_layer.items);
    try std.testing.expect(opaque_tree.entries.get("dir/lower") == null);
    try std.testing.expect(opaque_tree.entries.get("dir/sub/lower") == null);
    try expectMergedFileData(allocator, &opaque_tree, "dir/current", "current");
    try expectMergedFileData(allocator, &opaque_tree, "dir/sub/current", "current");

    var whiteout_layer = std.ArrayList(u8).empty;
    defer whiteout_layer.deinit(allocator);
    try appendTestTarEntry(allocator, &whiteout_layer, "dir/sub/current", '0', "current", null);
    try appendTestTarEntry(allocator, &whiteout_layer, "dir/.wh.sub", '0', "", null);
    try finishTestTar(allocator, &whiteout_layer);

    var whiteout_tree = MergedTree.init(allocator);
    defer whiteout_tree.deinit(allocator);
    try applyTestLayer(allocator, &tmp, &whiteout_tree, "lower.tar", lower.items);
    try applyTestLayer(allocator, &tmp, &whiteout_tree, "whiteout.tar", whiteout_layer.items);
    try std.testing.expect(whiteout_tree.entries.get("dir/sub/lower") == null);
    try expectMergedFileData(allocator, &whiteout_tree, "dir/sub/current", "current");
    try expectMergedFileData(allocator, &whiteout_tree, "dir/lower", "lower");
}

test "merged tree opaque whiteout rejects symlink parent" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tree = MergedTree.init(allocator);
    defer tree.deinit(allocator);

    var layer = std.ArrayList(u8).empty;
    defer layer.deinit(allocator);
    try appendTestTarEntry(allocator, &layer, "victim/keep", '0', "keep", null);
    try appendTestTarEntry(allocator, &layer, "link", '2', "", "victim");
    try appendTestTarEntry(allocator, &layer, "link/.wh..wh..opq", '0', "", null);
    try finishTestTar(allocator, &layer);
    try std.testing.expectError(error.SymlinkTraversal, applyTestLayer(allocator, &tmp, &tree, "layer.tar", layer.items));
    try std.testing.expect(tree.entries.get("victim/keep") != null);
}

test "merged tree entries replace other kinds at the same path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tree = MergedTree.init(allocator);
    defer tree.deinit(allocator);

    var lower = std.ArrayList(u8).empty;
    defer lower.deinit(allocator);
    try appendTestTarEntry(allocator, &lower, "x", '0', "file", null);
    try appendTestTarEntry(allocator, &lower, "etc/conf.d/file", '0', "old", null);
    try finishTestTar(allocator, &lower);
    var upper = std.ArrayList(u8).empty;
    defer upper.deinit(allocator);
    try appendTestTarEntry(allocator, &upper, "x", '5', "", null);
    try appendTestTarEntry(allocator, &upper, "etc/conf.d", '0', "new", null);
    try finishTestTar(allocator, &upper);

    try applyTestLayer(allocator, &tmp, &tree, "lower.tar", lower.items);
    try applyTestLayer(allocator, &tmp, &tree, "upper.tar", upper.items);
    try std.testing.expectEqual(MergedEntryKind.directory, tree.entries.get("x").?.kind);
    try expectMergedFileData(allocator, &tree, "etc/conf.d", "new");
    try std.testing.expect(tree.entries.get("etc/conf.d/file") == null);
    try std.testing.expectEqual(@as(usize, 1), tree.file_sources.count());
}

test "merged tree implicit parents use deterministic mode without changing explicit parents" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tree = MergedTree.init(allocator);
    defer tree.deinit(allocator);

    var layer = std.ArrayList(u8).empty;
    defer layer.deinit(allocator);
    for ([_][]const u8{ "usr", "a/b" }) |dir| {
        const start = layer.items.len;
        try appendTestTarEntry(allocator, &layer, dir, '5', "", null);
        writeTarOctal(layer.items[start + 100 .. start + 108], 0o700);
        rewriteTestTarChecksum(layer.items[start .. start + 512]);
    }
    try appendTestTarEntry(allocator, &layer, "usr/bin/tool", '0', "x", null);
    try finishTestTar(allocator, &layer);
    try applyTestLayer(allocator, &tmp, &tree, "layer.tar", layer.items);

    try std.testing.expectEqual(@as(u16, 0o700), tree.entries.get("usr").?.mode);
    try std.testing.expectEqual(@as(u16, 0o755), tree.entries.get("usr/bin").?.mode);
    try std.testing.expectEqual(@as(u16, 0o755), tree.entries.get("a").?.mode);
    try std.testing.expectEqual(@as(u16, 0o700), tree.entries.get("a/b").?.mode);
}

test "merged tree hardlinks share ownership and xattrs across paths" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tree = MergedTree.init(allocator);
    defer tree.deinit(allocator);

    const cap = [_]u8{ 1, 0, 0, 2 } ++ @as([16]u8, @splat(0));
    var pax = @as([512]u8, @splat(0));
    var pax_len: usize = 0;
    pax_len += writePaxRecord(pax[pax_len..], "uid", "2");
    pax_len += writePaxRecord(pax[pax_len..], "gid", "3");
    pax_len += writePaxRecord(pax[pax_len..], "SCHILY.xattr.security.capability", &cap);

    var layer = std.ArrayList(u8).empty;
    defer layer.deinit(allocator);
    try appendTestTarEntry(allocator, &layer, "target", '0', "same", null);
    try appendTestTarEntry(allocator, &layer, "pax", 'x', pax[0..pax_len], null);
    try appendTestTarEntry(allocator, &layer, "alias", '1', "", "target");
    try finishTestTar(allocator, &layer);
    try applyTestLayer(allocator, &tmp, &tree, "layer.tar", layer.items);

    for ([_][]const u8{ "target", "alias" }) |rel| {
        const entry = tree.entries.get(rel).?;
        try std.testing.expectEqual(@as(u32, 2), entry.uid);
        try std.testing.expectEqual(@as(u32, 3), entry.gid);
        try std.testing.expectEqual(@as(usize, 1), entry.xattrs.len);
        try std.testing.expectEqualStrings(xattrs_mod.security_capability_name, entry.xattrs[0].name);
        try std.testing.expectEqualSlices(u8, &cap, entry.xattrs[0].value);
    }
    try std.testing.expectEqual(tree.entries.get("target").?.inode_id, tree.entries.get("alias").?.inode_id);
}

test "unsupported tar entry types fail closed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tree = MergedTree.init(allocator);
    defer tree.deinit(allocator);
    var block = @as([1024]u8, @splat(0));
    makeTarHeader(block[0..512], "dev/null", '3', 0);

    try std.testing.expectError(error.UnsupportedTarEntryType, applyTestLayer(allocator, &tmp, &tree, "layer.tar", &block));
}

test "truncated tar headers fail closed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tree = MergedTree.init(allocator);
    defer tree.deinit(allocator);
    const block = @as([511]u8, @splat(0));

    try std.testing.expectError(error.TruncatedTarHeader, applyTestLayer(allocator, &tmp, &tree, "layer.tar", &block));
}

test "truncated tar payloads fail closed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tree = MergedTree.init(allocator);
    defer tree.deinit(allocator);
    var block = @as([612]u8, @splat(0));
    makeTarHeader(block[0..512], "file", '0', 1000);

    try std.testing.expectError(error.EndOfStream, applyTestLayer(allocator, &tmp, &tree, "layer.tar", &block));
}

test "global pax uid gid defaults apply to following entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tree = MergedTree.init(allocator);
    defer tree.deinit(allocator);
    var block = @as([2560]u8, @splat(0));
    const record = "10 uid=12\n10 gid=34\n13 comment=x\n";
    makeTarHeader(block[0..512], "global-pax", 'g', record.len);
    @memcpy(block[512 .. 512 + record.len], record);
    makeTarHeader(block[1024..1536], "file", '0', 1);
    block[1536] = 'x';

    try applyTestLayer(allocator, &tmp, &tree, "layer.tar", &block);
    try expectMergedFileData(allocator, &tree, "file", "x");
    try std.testing.expectEqual(@as(u32, 12), tree.entries.get("file").?.uid);
    try std.testing.expectEqual(@as(u32, 34), tree.entries.get("file").?.gid);
}

test "global pax extraction fields and xattrs fail closed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tree = MergedTree.init(allocator);
    defer tree.deinit(allocator);

    var path_block = @as([1024]u8, @splat(0));
    const path_record = "13 path=file\n";
    makeTarHeader(path_block[0..512], "global-pax", 'g', path_record.len);
    @memcpy(path_block[512 .. 512 + path_record.len], path_record);
    try std.testing.expectError(error.UnsupportedGlobalPaxRecord, applyTestLayer(allocator, &tmp, &tree, "path.tar", &path_block));

    const cap = [_]u8{ 1, 0, 0, 2 } ++ @as([16]u8, @splat(0));
    var xattr_block = @as([1024]u8, @splat(0));
    const len = writePaxRecord(xattr_block[512..], "SCHILY.xattr.security.capability", &cap);
    makeTarHeader(xattr_block[0..512], "global-pax", 'g', len);
    try std.testing.expectError(error.UnsupportedTarXattr, applyTestLayer(allocator, &tmp, &tree, "xattr.tar", &xattr_block));
}

/// A pax `size` near 2^64 for a directory entry, whose payload the parser
/// skips instead of reading.
fn hugePaxSizeLayer() [1536]u8 {
    var layer = @as([1536]u8, @splat(0));
    const record = "29 size=18446744073709551615\n";
    makeTarHeader(layer[0..512], "pax", 'x', record.len);
    @memcpy(layer[512 .. 512 + record.len], record);
    makeTarHeader(layer[1024..1536], "dir", '5', 0);
    return layer;
}

test "tar payload sizes past the content limit fail closed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tree = MergedTree.init(allocator);
    defer tree.deinit(allocator);

    const pax_layer = hugePaxSizeLayer();
    try std.testing.expectError(error.RootFSArchiveTooLarge, applyTestLayer(allocator, &tmp, &tree, "pax.tar", &pax_layer));

    // The same size as a base-256 header field.
    var header = @as([512]u8, @splat(0));
    makeTarHeader(&header, "dir", '5', 0);
    header[124..136].* = .{ 0x80, 0, 0, 0 } ++ @as([8]u8, @splat(0xff));
    @memset(header[148..156], ' ');
    var sum: u64 = 0;
    for (header) |b| sum += b;
    writeTarOctal(header[148..156], sum);
    try std.testing.expectError(error.RootFSArchiveTooLarge, applyTestLayer(allocator, &tmp, &tree, "header.tar", &header));
}

test "pax size overrides ustar file size" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tree = MergedTree.init(allocator);
    defer tree.deinit(allocator);
    var block = @as([2560]u8, @splat(0));
    const record = "10 size=5\n";
    makeTarHeader(block[0..512], "pax", 'x', record.len);
    @memcpy(block[512 .. 512 + record.len], record);
    makeTarHeader(block[1024..1536], "file", '0', 0);
    @memcpy(block[1536..1541], "hello");

    try applyTestLayer(allocator, &tmp, &tree, "layer.tar", &block);
    try expectMergedFileData(allocator, &tree, "file", "hello");
}

test "pax paths and GNU long names name the next entry" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tree = MergedTree.init(allocator);
    defer tree.deinit(allocator);
    var block = @as([4096]u8, @splat(0));
    const pax_record = "17 path=pax-name\n";
    makeTarHeader(block[0..512], "pax", 'x', pax_record.len);
    @memcpy(block[512 .. 512 + pax_record.len], pax_record);
    makeTarHeader(block[1024..1536], "ignored", '0', 1);
    block[1536] = 'p';
    const long_name = "gnu-name\x00";
    makeTarHeader(block[2048..2560], "././@LongLink", 'L', long_name.len);
    @memcpy(block[2560 .. 2560 + long_name.len], long_name);
    makeTarHeader(block[3072..3584], "ignored", '0', 1);
    block[3584] = 'g';

    try applyTestLayer(allocator, &tmp, &tree, "layer.tar", &block);
    try expectMergedFileData(allocator, &tree, "pax-name", "p");
    try expectMergedFileData(allocator, &tree, "gnu-name", "g");
    try std.testing.expect(tree.entries.get("ignored") == null);
}

test "root tar entries are ignored only for directories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tree = MergedTree.init(allocator);
    defer tree.deinit(allocator);

    var block = @as([1024]u8, @splat(0));
    makeTarHeader(block[0..512], ".", '5', 0);
    try applyTestLayer(allocator, &tmp, &tree, "dir.tar", &block);
    try std.testing.expectEqual(@as(u32, 0), tree.entries.count());

    makeTarHeader(block[0..512], ".", '0', 0);
    try std.testing.expectError(error.UnsafeTarPath, applyTestLayer(allocator, &tmp, &tree, "file.tar", &block));
}

test "pax records fail closed unless supported" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { record: []const u8, err: anyerror }{
        .{ .record = "1 ", .err = error.BadPaxHeader },
        .{ .record = "24 SCHILY.xattr.foo=bar\n", .err = error.UnsupportedTarXattr },
        .{ .record = "20 GNU.sparse.map=0\n", .err = error.UnsupportedTarSparse },
    };
    for (cases) |case| {
        var pax: PendingPax = .{};
        defer pax.clear(allocator);
        try std.testing.expectError(case.err, parsePaxHeaderBytes(allocator, case.record, &pax));
    }

    const cap = [_]u8{ 1, 0, 0, 2 } ++ @as([16]u8, @splat(0));
    var block = @as([512]u8, @splat(0));
    const len = writePaxRecord(&block, "SCHILY.xattr.security.capability", &cap);
    var pax: PendingPax = .{};
    defer pax.clear(allocator);
    try parsePaxHeaderBytes(allocator, block[0..len], &pax);
    try std.testing.expectEqual(@as(usize, 1), pax.xattrs.items.len);
    try std.testing.expectEqualStrings(xattrs_mod.security_capability_name, pax.xattrs.items[0].name);
    try std.testing.expectEqualSlices(u8, &cap, pax.xattrs.items[0].value);
}

test "required rootfs paths reject symlinks and keep existing entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tree = MergedTree.init(allocator);
    defer tree.deinit(allocator);

    var layer = std.ArrayList(u8).empty;
    defer layer.deinit(allocator);
    try appendTestTarEntry(allocator, &layer, "target", '5', "", null);
    try appendTestTarEntry(allocator, &layer, "dev", '2', "", "target");
    try appendTestTarEntry(allocator, &layer, "run", '0', "file", null);
    try appendTestTarEntry(allocator, &layer, "etc/resolv.conf", '2', "", "../run/systemd/resolve/resolv.conf");
    try appendTestTarEntry(allocator, &layer, "etc/hosts", '0', "hosts", null);
    try finishTestTar(allocator, &layer);
    try applyTestLayer(allocator, &tmp, &tree, "layer.tar", layer.items);

    const root: Ownership = .{ .uid = 0, .gid = 0 };
    try std.testing.expectError(error.SymlinkTraversal, ensureMergedDirectory(allocator, &tree, "dev", 0o755, root));
    try std.testing.expectError(error.RequiredRootFSPathNotDirectory, ensureMergedDirectory(allocator, &tree, "run", 0o755, root));
    try std.testing.expectError(error.SymlinkTraversal, ensureMergedFile(allocator, &tree, "dev/resolv.conf", "x", 0o644, root));
    try ensureMergedFile(allocator, &tree, "etc/resolv.conf", "placeholder", 0o644, root);
    try std.testing.expectEqual(MergedEntryKind.symlink, tree.entries.get("etc/resolv.conf").?.kind);
    try ensureMergedFile(allocator, &tree, "etc/hosts", "placeholder", 0o644, root);
    try expectMergedFileData(allocator, &tree, "etc/hosts", "hosts");
}

fn fuzzTarLayer(_: void, s: *std.testing.Smith) !void {
    // OCI layers are attacker-influenced tar streams. The parser reads them in
    // place and must reject malformed data, traversal attempts, and odd link
    // metadata without crashing or corrupting the in-memory tree.
    var buf: [8192]u8 = undefined;
    const len = s.slice(&buf);

    // The checking allocator, not an arena, so leaks and double frees on
    // error paths fail the run.
    const allocator = std.testing.allocator;
    var tmp = fuzz_support.tmpDir(.{});
    defer tmp.cleanup();
    var tree = MergedTree.init(allocator);
    defer tree.deinit(allocator);
    applyTestLayer(allocator, &tmp, &tree, "layer.tar", buf[0..len]) catch return;
}

test "fuzz OCI tar layer parsing" {
    // Smith reads a little-endian u32 length before the slice bytes.
    const layer = hugePaxSizeLayer();
    var seed: [4 + layer.len]u8 = undefined;
    std.mem.writeInt(u32, seed[0..4], layer.len, .little);
    @memcpy(seed[4..], &layer);
    try std.testing.fuzz({}, fuzzTarLayer, .{ .corpus = &.{&seed} });
}
