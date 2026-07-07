//! Native write-only ext4-compatible image emitter.
//!
//! This module deliberately only creates fresh images. It does not read or
//! mutate existing filesystems.

const std = @import("std");
const chunk = @import("../chunk.zig");
const ext4 = @import("ext4.zig");
const tar = @import("tar.zig");
const xattrs_mod = @import("xattrs.zig");

const Io = std.Io;
const Blake3 = std.crypto.hash.Blake3;

const block_size: u32 = 4096;
const inode_size: u16 = 256;
const first_non_reserved_inode: u32 = 11;
const root_inode: u32 = 2;
const lost_found_inode: u32 = 11;
const min_image_size: u64 = 16 << 20;
const blocks_per_group: u32 = 32768;
const group_descriptor_size: u32 = 32;
const max_direct_blocks: usize = 12;
const pointers_per_block: usize = block_size / @sizeOf(u32);

const s_ififo: u16 = 0o010000;
const s_ifchr: u16 = 0o020000;
const s_ifdir: u16 = 0o040000;
const s_ifblk: u16 = 0o060000;
const s_ifreg: u16 = 0o100000;
const s_iflnk: u16 = 0o120000;
const s_ifsock: u16 = 0o140000;

const file_type_regular: u8 = 1;
const file_type_dir: u8 = 2;
const file_type_chrdev: u8 = 3;
const file_type_blkdev: u8 = 4;
const file_type_fifo: u8 = 5;
const file_type_sock: u8 = 6;
const file_type_symlink: u8 = 7;

const feature_compat_ext_attr: u32 = 0x0008;
const feature_incompat_filetype: u32 = 0x0002;
const feature_ro_compat_sparse_super: u32 = 0x0001;
const feature_ro_compat_large_file: u32 = 0x0002;
const ext4_magic: u16 = 0xef53;
const ext4_state_clean: u16 = 1;
const ext4_errors_continue: u16 = 1;
const bg_inode_zeroed: u16 = 0x0004;
const xattr_magic: u32 = 0xea020000;
const xattr_index_security: u8 = 6;

pub const DeviceKind = enum {
    char,
    block,
};

pub const Device = struct {
    kind: DeviceKind,
    major: u32,
    minor: u32,
};

pub const EntryKind = union(enum) {
    directory,
    file: []const u8,
    symlink: []const u8,
    hardlink: []const u8,
    device: Device,
    fifo,
    socket,
};

pub const Entry = struct {
    path: []const u8,
    kind: EntryKind,
    mode: u16 = 0o644,
    uid: u32 = 0,
    gid: u32 = 0,
    xattrs: []const xattrs_mod.Attribute = &.{},
};

pub const Options = struct {
    image_size: u64 = min_image_size,
    inode_count: u32 = 1024,
    determinism: ext4.Determinism,
};

pub const Result = struct {
    blake3: [chunk.ChunkId.hex_len]u8,
    size: u64,
};

const InodeKind = enum {
    directory,
    file,
    symlink,
    char_device,
    block_device,
    fifo,
    socket,
};

const InodePlan = struct {
    ino: u32,
    kind: InodeKind,
    mode: u16,
    uid: u32,
    gid: u32,
    size: u64 = 0,
    links: u16 = 1,
    data: []const u8 = &.{},
    symlink_target: []const u8 = &.{},
    device: ?Device = null,
    xattrs: []const xattrs_mod.Attribute = &.{},
    data_blocks: []u32 = &.{},
    indirect_blocks: []u32 = &.{},
    single_indirect_block: u32 = 0,
    double_indirect_block: u32 = 0,
    xattr_block: u32 = 0,

    fn fileType(self: InodePlan) u8 {
        return switch (self.kind) {
            .directory => file_type_dir,
            .file => file_type_regular,
            .symlink => file_type_symlink,
            .char_device => file_type_chrdev,
            .block_device => file_type_blkdev,
            .fifo => file_type_fifo,
            .socket => file_type_sock,
        };
    }
};

const PathRef = struct {
    path: []const u8,
    inode_index: usize,
};

const DirChild = struct {
    name: []const u8,
    inode_index: usize,
};

const PlannedImage = struct {
    inodes: std.ArrayList(InodePlan) = .empty,
    paths: std.ArrayList(PathRef) = .empty,

    fn deinit(self: *PlannedImage, allocator: std.mem.Allocator) void {
        for (self.inodes.items) |inode| {
            allocator.free(inode.data_blocks);
            allocator.free(inode.indirect_blocks);
        }
        self.inodes.deinit(allocator);
        self.paths.deinit(allocator);
    }
};

const BlockStore = std.AutoHashMap(u32, []u8);

pub fn emit(
    allocator: std.mem.Allocator,
    io: Io,
    output_path: []const u8,
    entries: []const Entry,
    options: Options,
) !Result {
    if (options.image_size < min_image_size or options.image_size % block_size != 0) return error.InvalidExt4ImageSize;
    const total_blocks_u64 = options.image_size / block_size;
    if (total_blocks_u64 == 0 or total_blocks_u64 > std.math.maxInt(u32)) return error.UnsupportedExt4ImageSize;
    const total_blocks: u32 = @intCast(total_blocks_u64);
    if (options.inode_count < first_non_reserved_inode or options.inode_count % inodesPerBlock() != 0) return error.InvalidExt4InodeCount;

    var planned = try planImage(allocator, entries, options.inode_count);
    defer planned.deinit(allocator);

    var blocks = BlockStore.init(allocator);
    defer freeBlockStore(allocator, &blocks);

    const layout = try assignBlocks(allocator, &planned, total_blocks, options.inode_count, &blocks);
    defer allocator.free(layout.groups);
    try writeMetadataBlocks(allocator, &planned, layout, options, &blocks);
    return try writeImage(io, output_path, options.image_size, total_blocks, &blocks);
}

pub fn emitFromMergedTree(
    allocator: std.mem.Allocator,
    io: Io,
    tree: *const tar.MergedTree,
    output_path: []const u8,
    options: Options,
) !Result {
    const refs = try allocator.alloc(MergedPathRef, tree.entries.count());
    defer allocator.free(refs);
    var count: usize = 0;
    var it = tree.entries.iterator();
    while (it.next()) |entry| : (count += 1) {
        refs[count] = .{
            .path = entry.key_ptr.*,
            .entry = entry.value_ptr,
        };
    }
    std.mem.sort(MergedPathRef, refs, {}, lessMergedPathRef);

    var canonical_files = std.AutoHashMap(u64, []const u8).init(allocator);
    defer canonical_files.deinit();

    var entries = std.ArrayList(Entry).empty;
    defer entries.deinit(allocator);
    for (refs) |ref| {
        switch (ref.entry.kind) {
            .directory => try entries.append(allocator, .{
                .path = ref.path,
                .kind = .directory,
                .mode = ref.entry.mode,
                .uid = ref.entry.uid,
                .gid = ref.entry.gid,
                .xattrs = ref.entry.xattrs,
            }),
            .symlink => try entries.append(allocator, .{
                .path = ref.path,
                .kind = .{ .symlink = ref.entry.symlink_target },
                .mode = ref.entry.mode,
                .uid = ref.entry.uid,
                .gid = ref.entry.gid,
                .xattrs = ref.entry.xattrs,
            }),
            .file => {
                const canonical = try canonical_files.getOrPut(ref.entry.inode_id);
                if (canonical.found_existing) {
                    try entries.append(allocator, .{
                        .path = ref.path,
                        .kind = .{ .hardlink = canonical.value_ptr.* },
                        .mode = ref.entry.mode,
                        .uid = ref.entry.uid,
                        .gid = ref.entry.gid,
                        .xattrs = ref.entry.xattrs,
                    });
                    continue;
                }
                canonical.value_ptr.* = ref.path;
                try entries.append(allocator, .{
                    .path = ref.path,
                    .kind = .{ .file = try tree.fileData(ref.entry.inode_id) },
                    .mode = ref.entry.mode,
                    .uid = ref.entry.uid,
                    .gid = ref.entry.gid,
                    .xattrs = ref.entry.xattrs,
                });
            },
        }
    }
    return emit(allocator, io, output_path, entries.items, options);
}

const MergedPathRef = struct {
    path: []const u8,
    entry: *const tar.MergedEntry,
};

fn lessMergedPathRef(_: void, a: MergedPathRef, b: MergedPathRef) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn planImage(allocator: std.mem.Allocator, entries: []const Entry, inode_count: u32) !PlannedImage {
    var planned = PlannedImage{};
    errdefer planned.deinit(allocator);

    try planned.inodes.append(allocator, .{
        .ino = root_inode,
        .kind = .directory,
        .mode = s_ifdir | 0o755,
        .uid = 0,
        .gid = 0,
    });
    try planned.paths.append(allocator, .{ .path = "", .inode_index = 0 });

    _ = try ensureDirectoryPath(allocator, &planned, "lost+found", 0o700, 0, 0, lost_found_inode);

    const sorted = try allocator.alloc(Entry, entries.len);
    defer allocator.free(sorted);
    @memcpy(sorted, entries);
    std.mem.sort(Entry, sorted, {}, lessEntryPath);

    var next_inode: u32 = first_non_reserved_inode + 1;
    for (sorted) |entry| {
        if (entry.kind == .hardlink) continue;
        const normalized = try validatePath(entry.path);
        if (std.mem.eql(u8, normalized, "lost+found")) return error.DuplicateRootFSEntry;
        try ensureParents(allocator, &planned, normalized, &next_inode, inode_count);

        switch (entry.kind) {
            .directory => {
                if (next_inode > inode_count) return error.RootFSTooManyInodes;
                if (try ensureDirectoryPath(allocator, &planned, normalized, entry.mode, entry.uid, entry.gid, next_inode)) {
                    next_inode += 1;
                }
            },
            .hardlink => unreachable,
            else => {
                if (pathIndex(planned.paths.items, normalized) != null) return error.DuplicateRootFSEntry;
                if (next_inode > inode_count) return error.RootFSTooManyInodes;
                try planned.inodes.append(allocator, try entryInodePlan(entry, normalized, next_inode));
                try planned.paths.append(allocator, .{ .path = normalized, .inode_index = planned.inodes.items.len - 1 });
                next_inode += 1;
            },
        }
    }

    for (sorted) |entry| {
        const target = switch (entry.kind) {
            .hardlink => |target| target,
            else => continue,
        };
        const normalized = try validatePath(entry.path);
        if (std.mem.eql(u8, normalized, "lost+found")) return error.DuplicateRootFSEntry;
        try ensureParents(allocator, &planned, normalized, &next_inode, inode_count);
        const target_path = try validatePath(target);
        const target_path_index = pathIndex(planned.paths.items, target_path) orelse return error.BadHardlinkTarget;
        const target_inode = planned.inodes.items[target_path_index.inode_index];
        if (target_inode.kind != .file) return error.BadHardlinkTarget;
        if (pathIndex(planned.paths.items, normalized) != null) return error.DuplicateRootFSEntry;
        try planned.paths.append(allocator, .{ .path = normalized, .inode_index = target_path_index.inode_index });
    }

    try computeLinkCounts(&planned);
    return planned;
}

const PathLookup = struct {
    inode_index: usize,
};

fn ensureDirectoryPath(
    allocator: std.mem.Allocator,
    planned: *PlannedImage,
    path: []const u8,
    mode: u16,
    uid: u32,
    gid: u32,
    inode_no: u32,
) !bool {
    if (pathIndex(planned.paths.items, path)) |existing| {
        const inode = &planned.inodes.items[existing.inode_index];
        if (inode.kind != .directory) return error.ParentNotDirectory;
        inode.mode = s_ifdir | (mode & 0o7777);
        inode.uid = uid;
        inode.gid = gid;
        return false;
    }
    try planned.inodes.append(allocator, .{
        .ino = inode_no,
        .kind = .directory,
        .mode = s_ifdir | (mode & 0o7777),
        .uid = uid,
        .gid = gid,
    });
    try planned.paths.append(allocator, .{ .path = path, .inode_index = planned.inodes.items.len - 1 });
    return true;
}

fn ensureParents(
    allocator: std.mem.Allocator,
    planned: *PlannedImage,
    path: []const u8,
    next_inode: *u32,
    inode_count: u32,
) !void {
    var slash_index: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, slash_index, '/')) |slash| {
        const parent = path[0..slash];
        if (parent.len != 0 and pathIndex(planned.paths.items, parent) == null) {
            if (next_inode.* > inode_count) return error.RootFSTooManyInodes;
            if (try ensureDirectoryPath(allocator, planned, parent, 0o755, 0, 0, next_inode.*)) {
                next_inode.* += 1;
            }
        }
        slash_index = slash + 1;
    }
}

fn entryInodePlan(entry: Entry, normalized: []const u8, inode_no: u32) !InodePlan {
    _ = normalized;
    for (entry.xattrs) |attr| {
        if (!std.mem.eql(u8, attr.name, xattrs_mod.security_capability_name)) return error.UnsupportedTarXattr;
        try xattrs_mod.validateSecurityCapability(attr.value);
    }
    return switch (entry.kind) {
        .file => |data| .{
            .ino = inode_no,
            .kind = .file,
            .mode = s_ifreg | (entry.mode & 0o7777),
            .uid = entry.uid,
            .gid = entry.gid,
            .size = data.len,
            .data = data,
            .xattrs = entry.xattrs,
        },
        .symlink => |target| .{
            .ino = inode_no,
            .kind = .symlink,
            .mode = s_iflnk | 0o777,
            .uid = entry.uid,
            .gid = entry.gid,
            .size = target.len,
            .symlink_target = target,
            .xattrs = entry.xattrs,
        },
        .device => |dev| .{
            .ino = inode_no,
            .kind = if (dev.kind == .char) .char_device else .block_device,
            .mode = (if (dev.kind == .char) s_ifchr else s_ifblk) | (entry.mode & 0o7777),
            .uid = entry.uid,
            .gid = entry.gid,
            .device = dev,
            .xattrs = entry.xattrs,
        },
        .fifo => .{
            .ino = inode_no,
            .kind = .fifo,
            .mode = s_ififo | (entry.mode & 0o7777),
            .uid = entry.uid,
            .gid = entry.gid,
            .xattrs = entry.xattrs,
        },
        .socket => .{
            .ino = inode_no,
            .kind = .socket,
            .mode = s_ifsock | (entry.mode & 0o7777),
            .uid = entry.uid,
            .gid = entry.gid,
            .xattrs = entry.xattrs,
        },
        .directory, .hardlink => unreachable,
    };
}

fn computeLinkCounts(planned: *PlannedImage) !void {
    for (planned.inodes.items) |*inode| inode.links = if (inode.kind == .directory) 2 else 0;
    for (planned.paths.items) |path_ref| {
        if (path_ref.path.len == 0) continue;
        const inode = &planned.inodes.items[path_ref.inode_index];
        if (inode.kind == .directory) {
            if (parentPathIndex(planned.paths.items, path_ref.path)) |parent| {
                planned.inodes.items[parent.inode_index].links = try addLink(planned.inodes.items[parent.inode_index].links);
            }
        } else {
            inode.links = try addLink(inode.links);
        }
    }
}

fn addLink(current: u16) !u16 {
    if (current == std.math.maxInt(u16)) return error.RootFSTooManyLinks;
    return current + 1;
}

const Layout = struct {
    total_blocks: u32,
    inode_count: u32,
    inodes_per_group: u32,
    descriptor_blocks: u32,
    free_blocks: u32,
    free_inodes: u32,
    groups: []GroupLayout,
};

const GroupLayout = struct {
    index: u32,
    first_block: u32,
    block_count: u32,
    has_super: bool,
    block_bitmap: u32,
    inode_bitmap: u32,
    inode_table: u32,
    inode_table_blocks: u32,
    free_blocks: u32 = 0,
    free_inodes: u32 = 0,
    used_dirs: u32 = 0,

    fn metadataEnd(self: GroupLayout) u32 {
        return self.inode_table + self.inode_table_blocks;
    }
};

fn assignBlocks(
    allocator: std.mem.Allocator,
    planned: *PlannedImage,
    total_blocks: u32,
    inode_count: u32,
    blocks: *BlockStore,
) !Layout {
    const group_count = divCeilU32(total_blocks, blocks_per_group);
    const descriptor_blocks = divCeilU32(group_count * group_descriptor_size, block_size);
    const inodes_per_group = alignUpU32(divCeilU32(inode_count, group_count), inodesPerBlock());
    if (inodes_per_group == 0 or inodes_per_group > block_size * 8) return error.InvalidExt4InodeCount;
    const total_inode_count = try std.math.mul(u32, inodes_per_group, group_count);
    const inode_table_blocks_per_group = try inodeTableBlocks(inodes_per_group);

    const groups = try allocator.alloc(GroupLayout, group_count);
    errdefer allocator.free(groups);

    var used = try std.DynamicBitSetUnmanaged.initEmpty(allocator, total_blocks);
    defer used.deinit(allocator);

    for (groups, 0..) |*group, i| {
        const index: u32 = @intCast(i);
        const first_block = index * blocks_per_group;
        const block_count = @min(blocks_per_group, total_blocks - first_block);
        const has_super = isSparseSuperGroup(index);
        const descriptor_start = first_block + if (has_super) @as(u32, 1) else 0;
        const block_bitmap = descriptor_start + if (has_super) descriptor_blocks else 0;
        const inode_bitmap = block_bitmap + 1;
        const inode_table = inode_bitmap + 1;
        group.* = .{
            .index = index,
            .first_block = first_block,
            .block_count = block_count,
            .has_super = has_super,
            .block_bitmap = block_bitmap,
            .inode_bitmap = inode_bitmap,
            .inode_table = inode_table,
            .inode_table_blocks = inode_table_blocks_per_group,
        };
        if (group.metadataEnd() > first_block + block_count) return error.Ext4ImageTooSmall;
        used.setRangeValue(.{ .start = first_block, .end = group.metadataEnd() }, true);
    }

    for (planned.inodes.items) |*inode| {
        if (inode.kind == .directory) {
            const bytes = try directoryBytes(allocator, planned, inode.*);
            defer allocator.free(bytes);
            inode.size = bytes.len;
            try allocatePayloadBlocks(allocator, inode, bytes, &used, blocks);
        } else if (inode.kind == .file) {
            try allocatePayloadBlocks(allocator, inode, inode.data, &used, blocks);
        } else if (inode.kind == .symlink and inode.symlink_target.len > 60) {
            try allocatePayloadBlocks(allocator, inode, inode.symlink_target, &used, blocks);
        }
        if (inode.xattrs.len != 0) {
            inode.xattr_block = try allocateBlock(&used);
            const xattr_block = try xattrBlock(allocator, inode.xattrs);
            try blocks.put(inode.xattr_block, xattr_block);
        }
        try allocateIndirectBlocks(allocator, inode, &used, blocks);
    }

    var free_blocks: u32 = 0;
    for (groups) |*group| {
        const bitmap = try zeroBlock(allocator);
        var used_in_group: u32 = 0;
        var local: u32 = 0;
        while (local < group.block_count) : (local += 1) {
            const absolute = group.first_block + local;
            if (used.isSet(absolute)) {
                used_in_group += 1;
                setBitmapBit(bitmap, local);
            }
        }
        setBitmapTail(bitmap, group.block_count);
        group.free_blocks = group.block_count - used_in_group;
        free_blocks += group.free_blocks;
        try blocks.put(group.block_bitmap, bitmap);
    }

    fillInodeGroupStats(planned, groups, inodes_per_group);
    return .{
        .total_blocks = total_blocks,
        .inode_count = total_inode_count,
        .inodes_per_group = inodes_per_group,
        .descriptor_blocks = descriptor_blocks,
        .free_blocks = free_blocks,
        .free_inodes = total_inode_count - usedInodeCount(planned),
        .groups = groups,
    };
}

fn allocatePayloadBlocks(
    allocator: std.mem.Allocator,
    inode: *InodePlan,
    payload: []const u8,
    used: *std.DynamicBitSetUnmanaged,
    blocks: *BlockStore,
) !void {
    if (payload.len == 0) return;
    const count = divCeilUsize(payload.len, block_size);
    inode.data_blocks = try allocator.alloc(u32, count);
    var offset: usize = 0;
    for (inode.data_blocks) |*block| {
        block.* = try allocateBlock(used);
        const data_block = try zeroBlock(allocator);
        const take = @min(payload.len - offset, block_size);
        @memcpy(data_block[0..take], payload[offset .. offset + take]);
        try blocks.put(block.*, data_block);
        offset += take;
    }
}

fn allocateIndirectBlocks(
    allocator: std.mem.Allocator,
    inode: *InodePlan,
    used: *std.DynamicBitSetUnmanaged,
    blocks: *BlockStore,
) !void {
    if (inode.data_blocks.len <= max_direct_blocks) return;
    const double_capacity = pointers_per_block * pointers_per_block;
    if (inode.data_blocks.len > max_direct_blocks + pointers_per_block + double_capacity) return error.UnsupportedExt4FileSize;

    var metadata_blocks = std.ArrayList(u32).empty;
    errdefer metadata_blocks.deinit(allocator);

    var data_index: usize = max_direct_blocks;
    if (data_index < inode.data_blocks.len) {
        inode.single_indirect_block = try allocateBlock(used);
        try metadata_blocks.append(allocator, inode.single_indirect_block);
        const table = try zeroBlock(allocator);
        const table_count = @min(inode.data_blocks.len - data_index, pointers_per_block);
        for (inode.data_blocks[data_index .. data_index + table_count], 0..) |block, i| {
            put(u32, table, i * @sizeOf(u32), block);
        }
        try blocks.put(inode.single_indirect_block, table);
        data_index += table_count;
    }

    if (data_index < inode.data_blocks.len) {
        inode.double_indirect_block = try allocateBlock(used);
        try metadata_blocks.append(allocator, inode.double_indirect_block);
        const root = try zeroBlock(allocator);
        var root_index: usize = 0;
        while (data_index < inode.data_blocks.len) : (root_index += 1) {
            if (root_index >= pointers_per_block) return error.UnsupportedExt4FileSize;
            const leaf_block = try allocateBlock(used);
            try metadata_blocks.append(allocator, leaf_block);
            put(u32, root, root_index * @sizeOf(u32), leaf_block);
            const leaf = try zeroBlock(allocator);
            const leaf_count = @min(inode.data_blocks.len - data_index, pointers_per_block);
            for (inode.data_blocks[data_index .. data_index + leaf_count], 0..) |block, i| {
                put(u32, leaf, i * @sizeOf(u32), block);
            }
            try blocks.put(leaf_block, leaf);
            data_index += leaf_count;
        }
        try blocks.put(inode.double_indirect_block, root);
    }

    inode.indirect_blocks = try metadata_blocks.toOwnedSlice(allocator);
}

fn allocateBlock(used: *std.DynamicBitSetUnmanaged) !u32 {
    var i: usize = 0;
    while (i < used.bit_length) : (i += 1) {
        if (used.isSet(i)) continue;
        used.set(i);
        return @intCast(i);
    }
    return error.Ext4ImageTooSmall;
}

fn directoryBytes(allocator: std.mem.Allocator, planned: *const PlannedImage, inode: InodePlan) ![]u8 {
    var children = std.ArrayList(DirChild).empty;
    defer children.deinit(allocator);
    const self_path = pathForInode(planned, inode.ino) orelse return error.BadExt4Tree;
    for (planned.paths.items) |path_ref| {
        if (path_ref.path.len == 0 or std.mem.eql(u8, path_ref.path, self_path)) continue;
        if (!isDirectChild(self_path, path_ref.path)) continue;
        try children.append(allocator, .{
            .name = baseName(path_ref.path),
            .inode_index = path_ref.inode_index,
        });
    }
    std.mem.sort(DirChild, children.items, planned, lessDirChild);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendDirent(allocator, &out, inode.ino, ".", file_type_dir, false);
    const parent_inode = if (self_path.len == 0)
        inode.ino
    else blk: {
        const parent = parentPathIndex(planned.paths.items, self_path) orelse return error.BadExt4Tree;
        break :blk planned.inodes.items[parent.inode_index].ino;
    };
    try appendDirent(allocator, &out, parent_inode, "..", file_type_dir, false);
    for (children.items, 0..) |child, i| {
        const child_inode = planned.inodes.items[child.inode_index];
        try appendDirent(allocator, &out, child_inode.ino, child.name, child_inode.fileType(), i + 1 == children.items.len);
    }
    if (children.items.len == 0) try finishDirectoryBlock(allocator, &out);
    return out.toOwnedSlice(allocator);
}

fn appendDirent(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    inode_no: u32,
    name: []const u8,
    file_type: u8,
    last_for_now: bool,
) !void {
    if (name.len > 255) return error.Ext4NameTooLong;
    const min_len = direntLen(name.len);
    if (block_size - (out.items.len % block_size) < min_len) {
        try finishDirectoryBlock(allocator, out);
    }
    const start = out.items.len;
    try out.appendNTimes(allocator, 0, min_len);
    put(u32, out.items, start + 0, inode_no);
    put(u16, out.items, start + 4, @intCast(min_len));
    out.items[start + 6] = @intCast(name.len);
    out.items[start + 7] = file_type;
    @memcpy(out.items[start + 8 .. start + 8 + name.len], name);
    if (last_for_now) try finishDirectoryBlock(allocator, out);
}

fn finishDirectoryBlock(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    const used_in_block = out.items.len % block_size;
    if (used_in_block == 0) return;
    const pad = block_size - used_in_block;
    if (out.items.len < 8) return error.BadExt4Tree;
    const last = lastDirentOffset(out.items);
    const rec_len = std.mem.readInt(u16, out.items[last + 4 ..][0..2], .little);
    put(u16, out.items, last + 4, rec_len + @as(u16, @intCast(pad)));
    try out.appendNTimes(allocator, 0, pad);
}

fn lastDirentOffset(bytes: []const u8) usize {
    var off: usize = bytes.len - (bytes.len % block_size);
    if (off == bytes.len) off -= block_size;
    var last = off;
    while (off < bytes.len) {
        last = off;
        off += std.mem.readInt(u16, bytes[off + 4 ..][0..2], .little);
    }
    return last;
}

fn writeMetadataBlocks(
    allocator: std.mem.Allocator,
    planned: *const PlannedImage,
    layout: Layout,
    options: Options,
    blocks: *BlockStore,
) !void {
    for (layout.groups) |group| {
        const inode_bitmap = try zeroBlock(allocator);
        if (group.index == 0) {
            for (0..first_non_reserved_inode) |i| setBitmapBit(inode_bitmap, @intCast(i));
        }
        for (planned.inodes.items) |inode| {
            const inode_group = (inode.ino - 1) / layout.inodes_per_group;
            if (inode_group != group.index) continue;
            setBitmapBit(inode_bitmap, (inode.ino - 1) % layout.inodes_per_group);
        }
        setBitmapTail(inode_bitmap, layout.inodes_per_group);
        try blocks.put(group.inode_bitmap, inode_bitmap);

        const inode_table_bytes = try allocator.alloc(u8, group.inode_table_blocks * block_size);
        defer allocator.free(inode_table_bytes);
        @memset(inode_table_bytes, 0);
        for (planned.inodes.items) |inode| {
            const inode_group = (inode.ino - 1) / layout.inodes_per_group;
            if (inode_group != group.index) continue;
            const local_inode = (inode.ino - 1) % layout.inodes_per_group;
            const offset = local_inode * inode_size;
            writeInode(inode_table_bytes[@intCast(offset)..][0..inode_size], inode);
        }
        var table_offset: usize = 0;
        for (0..group.inode_table_blocks) |i| {
            const block = try allocator.alloc(u8, block_size);
            @memcpy(block, inode_table_bytes[table_offset .. table_offset + block_size]);
            try blocks.put(group.inode_table + @as(u32, @intCast(i)), block);
            table_offset += block_size;
        }
    }

    const descriptor_bytes = try groupDescriptorBytes(allocator, layout);
    defer allocator.free(descriptor_bytes);
    for (layout.groups) |group| {
        if (!group.has_super) continue;
        if (group.index == 0) {
            const first = try zeroBlock(allocator);
            writeSuperblock(first[1024..2048], layout, options, 0);
            try blocks.put(0, first);
        } else {
            const backup_super = try zeroBlock(allocator);
            writeSuperblock(backup_super[0..1024], layout, options, group.index);
            try blocks.put(group.first_block, backup_super);
        }
        for (0..layout.descriptor_blocks) |descriptor_block| {
            const block = try zeroBlock(allocator);
            const start = descriptor_block * block_size;
            const end = @min(start + block_size, descriptor_bytes.len);
            if (start < end) @memcpy(block[0 .. end - start], descriptor_bytes[start..end]);
            try blocks.put(group.first_block + 1 + @as(u32, @intCast(descriptor_block)), block);
        }
    }
}

fn groupDescriptorBytes(allocator: std.mem.Allocator, layout: Layout) ![]u8 {
    const len = layout.descriptor_blocks * block_size;
    const bytes = try allocator.alloc(u8, len);
    @memset(bytes, 0);
    for (layout.groups) |group| {
        const offset = group.index * group_descriptor_size;
        put(u32, bytes, offset + 0x00, group.block_bitmap);
        put(u32, bytes, offset + 0x04, group.inode_bitmap);
        put(u32, bytes, offset + 0x08, group.inode_table);
        put(u16, bytes, offset + 0x0c, @intCast(group.free_blocks));
        put(u16, bytes, offset + 0x0e, @intCast(group.free_inodes));
        put(u16, bytes, offset + 0x10, @intCast(group.used_dirs));
        put(u16, bytes, offset + 0x12, bg_inode_zeroed);
    }
    return bytes;
}

fn writeSuperblock(buf: []u8, layout: Layout, options: Options, group_index: u32) void {
    put(u32, buf, 0x00, layout.inode_count);
    put(u32, buf, 0x04, layout.total_blocks);
    put(u32, buf, 0x08, 0);
    put(u32, buf, 0x0c, layout.free_blocks);
    put(u32, buf, 0x10, layout.free_inodes);
    put(u32, buf, 0x14, 0);
    put(u32, buf, 0x18, 2);
    put(u32, buf, 0x1c, 2);
    put(u32, buf, 0x20, blocks_per_group);
    put(u32, buf, 0x24, blocks_per_group);
    put(u32, buf, 0x28, layout.inodes_per_group);
    put(u16, buf, 0x34, 0);
    put(u16, buf, 0x36, 0xffff);
    put(u16, buf, 0x38, ext4_magic);
    put(u16, buf, 0x3a, ext4_state_clean);
    put(u16, buf, 0x3c, ext4_errors_continue);
    put(u32, buf, 0x4c, 1);
    put(u32, buf, 0x54, first_non_reserved_inode);
    put(u16, buf, 0x58, inode_size);
    put(u16, buf, 0x5a, @intCast(group_index));
    put(u32, buf, 0x5c, feature_compat_ext_attr);
    put(u32, buf, 0x60, feature_incompat_filetype);
    put(u32, buf, 0x64, feature_ro_compat_sparse_super | feature_ro_compat_large_file);
    @memcpy(buf[0x68..0x78], &options.determinism.uuid_bytes);
    const name = "SporeVM";
    @memcpy(buf[0x78 .. 0x78 + name.len], name);
    put(u16, buf, 0xfe, @intCast(group_descriptor_size));
}

fn writeInode(buf: []u8, inode: InodePlan) void {
    put(u16, buf, 0x00, inode.mode);
    put(u16, buf, 0x02, @truncate(inode.uid));
    put(u32, buf, 0x04, @truncate(inode.size));
    put(u16, buf, 0x18, @truncate(inode.gid));
    put(u16, buf, 0x1a, inode.links);
    const allocated_blocks = inode.data_blocks.len + inode.indirect_blocks.len + if (inode.xattr_block != 0) @as(usize, 1) else 0;
    put(u32, buf, 0x1c, @intCast(allocated_blocks * (block_size / 512)));
    if (inode.xattr_block != 0) put(u32, buf, 0x68, inode.xattr_block);
    if (inode.size > std.math.maxInt(u32)) put(u32, buf, 0x6c, @intCast(inode.size >> 32));
    put(u16, buf, 0x78, @truncate(inode.uid >> 16));
    put(u16, buf, 0x7a, @truncate(inode.gid >> 16));

    switch (inode.kind) {
        .symlink => {
            if (inode.symlink_target.len <= 60) {
                @memcpy(buf[0x28 .. 0x28 + inode.symlink_target.len], inode.symlink_target);
            } else {
                writeBlockPointers(buf[0x28..0x64], inode);
            }
        },
        .char_device, .block_device => {
            const dev = inode.device.?;
            put(u32, buf, 0x28, encodeDevice(dev.major, dev.minor));
        },
        else => writeBlockPointers(buf[0x28..0x64], inode),
    }
}

fn writeBlockPointers(buf: []u8, inode: InodePlan) void {
    const direct_count = @min(inode.data_blocks.len, max_direct_blocks);
    for (inode.data_blocks[0..direct_count], 0..) |block, i| {
        put(u32, buf, i * @sizeOf(u32), block);
    }
    if (inode.single_indirect_block != 0) put(u32, buf, max_direct_blocks * @sizeOf(u32), inode.single_indirect_block);
    if (inode.double_indirect_block != 0) put(u32, buf, (max_direct_blocks + 1) * @sizeOf(u32), inode.double_indirect_block);
}

fn xattrBlock(allocator: std.mem.Allocator, attrs: []const xattrs_mod.Attribute) ![]u8 {
    if (attrs.len > xattrs_mod.max_per_entry) return error.RootFSTooManyXattrs;
    const block = try zeroBlock(allocator);
    put(u32, block, 0x00, xattr_magic);
    put(u32, block, 0x04, 1);
    put(u32, block, 0x08, 1);

    var entry_off: usize = 0x20;
    var value_off: usize = block_size;
    for (attrs) |attr| {
        if (!std.mem.eql(u8, attr.name, xattrs_mod.security_capability_name)) return error.UnsupportedTarXattr;
        const name = "capability";
        value_off = alignDown(value_off - attr.value.len, 4);
        if (entry_off + 16 + name.len + 4 > value_off) return error.RootFSXattrsTooLarge;
        block[entry_off + 0] = @intCast(name.len);
        block[entry_off + 1] = xattr_index_security;
        put(u16, block, entry_off + 2, @intCast(value_off));
        put(u32, block, entry_off + 4, 0);
        put(u32, block, entry_off + 8, @intCast(attr.value.len));
        @memcpy(block[entry_off + 16 .. entry_off + 16 + name.len], name);
        @memcpy(block[value_off .. value_off + attr.value.len], attr.value);
        put(u32, block, entry_off + 12, xattrEntryHash(name, attr.value));
        entry_off = alignUp(entry_off + 16 + name.len, 4);
    }
    put(u32, block, 0x0c, xattrBlockHash(block[0x20..entry_off]));
    return block;
}

fn writeImage(io: Io, output_path: []const u8, image_size: u64, total_blocks: u32, blocks: *BlockStore) !Result {
    try ext4.ensureParentDir(io, output_path);
    try ext4.createEmptyFile(io, output_path, image_size);
    var file = if (Io.Dir.path.isAbsolute(output_path))
        try Io.Dir.openFileAbsolute(io, output_path, .{ .mode = .read_write })
    else
        try Io.Dir.cwd().openFile(io, output_path, .{ .mode = .read_write });
    defer file.close(io);

    var hasher = Blake3.init(.{});
    const zero = [_]u8{0} ** block_size;
    for (0..total_blocks) |block_index| {
        const block_no: u32 = @intCast(block_index);
        const offset = @as(u64, block_no) * block_size;
        if (blocks.get(block_no)) |block| {
            try file.writePositionalAll(io, block, offset);
            hasher.update(block);
        } else {
            hasher.update(&zero);
        }
    }
    var raw: [chunk.ChunkId.len]u8 = undefined;
    hasher.final(&raw);
    return .{
        .blake3 = std.fmt.bytesToHex(raw, .lower),
        .size = image_size,
    };
}

fn freeBlockStore(allocator: std.mem.Allocator, blocks: *BlockStore) void {
    var it = blocks.valueIterator();
    while (it.next()) |block| allocator.free(block.*);
    blocks.deinit();
}

fn zeroBlock(allocator: std.mem.Allocator) ![]u8 {
    const block = try allocator.alloc(u8, block_size);
    @memset(block, 0);
    return block;
}

fn usedInodeCount(planned: *const PlannedImage) u32 {
    var max_ino: u32 = first_non_reserved_inode;
    for (planned.inodes.items) |inode| max_ino = @max(max_ino, inode.ino);
    return max_ino;
}

fn fillInodeGroupStats(planned: *const PlannedImage, groups: []GroupLayout, inodes_per_group: u32) void {
    for (groups) |*group| {
        group.free_inodes = inodes_per_group;
        group.used_dirs = 0;
    }
    groups[0].free_inodes -= first_non_reserved_inode;
    for (planned.inodes.items) |inode| {
        const group_index = (inode.ino - 1) / inodes_per_group;
        const group = &groups[group_index];
        if (inode.ino > first_non_reserved_inode) group.free_inodes -= 1;
        if (inode.kind == .directory) group.used_dirs += 1;
    }
}

fn setBitmapBit(bitmap: []u8, bit: u32) void {
    bitmap[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
}

fn setBitmapTail(bitmap: []u8, valid_bits: u32) void {
    var bit = valid_bits;
    while (bit < bitmap.len * 8) : (bit += 1) {
        setBitmapBit(bitmap, @intCast(bit));
    }
}

fn pathIndex(paths: []const PathRef, path: []const u8) ?PathLookup {
    for (paths) |path_ref| {
        if (std.mem.eql(u8, path_ref.path, path)) return .{ .inode_index = path_ref.inode_index };
    }
    return null;
}

fn parentPathIndex(paths: []const PathRef, path: []const u8) ?PathRef {
    const parent = parentPath(path);
    for (paths) |path_ref| {
        if (std.mem.eql(u8, path_ref.path, parent)) return path_ref;
    }
    return null;
}

fn pathForInode(planned: *const PlannedImage, inode_no: u32) ?[]const u8 {
    for (planned.paths.items) |path_ref| {
        if (planned.inodes.items[path_ref.inode_index].ino == inode_no) return path_ref.path;
    }
    return null;
}

fn lessEntryPath(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn lessDirChild(planned: *const PlannedImage, a: DirChild, b: DirChild) bool {
    _ = planned;
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn validatePath(path: []const u8) ![]const u8 {
    if (path.len == 0 or std.mem.startsWith(u8, path, "/")) return error.UnsafeTarPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.UnsafeTarPath;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.UnsafeTarPath;
    }
    return path;
}

fn isDirectChild(parent: []const u8, path: []const u8) bool {
    if (parent.len == 0) return std.mem.indexOfScalar(u8, path, '/') == null;
    if (!std.mem.startsWith(u8, path, parent)) return false;
    if (path.len <= parent.len or path[parent.len] != '/') return false;
    return std.mem.indexOfScalar(u8, path[parent.len + 1 ..], '/') == null;
}

fn parentPath(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..slash];
}

fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn direntLen(name_len: usize) usize {
    return alignUp(8 + name_len, 4);
}

fn inodesPerBlock() u32 {
    return block_size / inode_size;
}

fn divCeilUsize(n: usize, d: usize) usize {
    return (n + d - 1) / d;
}

fn divCeilU32(n: u32, d: u32) u32 {
    return (n + d - 1) / d;
}

fn alignUpU32(n: u32, a: u32) u32 {
    return ((n + a - 1) / a) * a;
}

fn inodeTableBlocks(inode_count: u32) !u32 {
    const bytes = try std.math.mul(u64, inode_count, inode_size);
    return @intCast((bytes + block_size - 1) / block_size);
}

fn alignUp(n: usize, a: usize) usize {
    return (n + a - 1) & ~(a - 1);
}

fn alignDown(n: usize, a: usize) usize {
    return n & ~(a - 1);
}

fn put(comptime T: type, buf: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, buf[offset..][0..@sizeOf(T)], value, .little);
}

fn encodeDevice(major: u32, minor: u32) u32 {
    return (minor & 0xff) | ((major & 0xfff) << 8) | ((minor & 0xfffff00) << 12);
}

fn isSparseSuperGroup(group: u32) bool {
    return group == 0 or group == 1 or isPowerOf(group, 3) or isPowerOf(group, 5) or isPowerOf(group, 7);
}

fn isPowerOf(value: u32, base: u32) bool {
    if (value == 0) return false;
    var n = value;
    while (n % base == 0) n /= base;
    return n == 1;
}

fn xattrEntryHash(name: []const u8, value: []const u8) u32 {
    var hash: u32 = 0;
    for (name) |c| hash = rotateHash(hash, 5) ^ c;
    var offset: usize = 0;
    while (offset < value.len) : (offset += 4) {
        var word_bytes = [_]u8{0} ** 4;
        const take = @min(value.len - offset, 4);
        @memcpy(word_bytes[0..take], value[offset .. offset + take]);
        hash = rotateHash(hash, 16) ^ std.mem.readInt(u32, &word_bytes, .little);
    }
    return hash;
}

fn xattrBlockHash(entries: []const u8) u32 {
    var hash: u32 = 0;
    var offset: usize = 0;
    while (offset + 16 <= entries.len and entries[offset] != 0) {
        const entry_hash = std.mem.readInt(u32, entries[offset + 12 ..][0..4], .little);
        if (entry_hash == 0) return 0;
        hash = rotateHash(hash, 16) ^ entry_hash;
        offset += alignUp(16 + entries[offset], 4);
    }
    return hash;
}

fn rotateHash(hash: u32, shift: u5) u32 {
    const right: u5 = @intCast(32 - @as(u32, shift));
    return (hash << shift) ^ (hash >> right);
}

test "native ext4 writer emits deterministic fsck-clean image" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path_a = "zig-cache/test-native-ext4-a.img";
    const path_b = "zig-cache/test-native-ext4-b.img";
    defer Io.Dir.cwd().deleteFile(io, path_a) catch {};
    defer Io.Dir.cwd().deleteFile(io, path_b) catch {};

    var cap = [_]u8{ 1, 0, 0, 2 } ++ [_]u8{0} ** 16;
    const attrs = [_]xattrs_mod.Attribute{.{ .name = xattrs_mod.security_capability_name, .value = &cap }};
    const entries = [_]Entry{
        .{ .path = "etc", .kind = .directory, .mode = 0o755 },
        .{ .path = "etc/hello", .kind = .{ .file = "hello\n" }, .mode = 0o644, .uid = 1000, .gid = 1000, .xattrs = &attrs },
        .{ .path = "etc/hello-hard", .kind = .{ .hardlink = "etc/hello" } },
        .{ .path = "bin", .kind = .directory, .mode = 0o755 },
        .{ .path = "bin/hello-link", .kind = .{ .symlink = "../etc/hello" } },
        .{ .path = "dev/nullish", .kind = .{ .device = .{ .kind = .char, .major = 1, .minor = 3 } }, .mode = 0o666 },
        .{ .path = "run/socket", .kind = .socket, .mode = 0o755 },
    };
    const determinism = ext4.Determinism.fromDigest("sha256:test-native-ext4");
    const opts = Options{
        .image_size = min_image_size,
        .inode_count = 1024,
        .determinism = determinism,
    };

    const first = try emit(allocator, io, path_a, &entries, opts);
    const second = try emit(allocator, io, path_b, &entries, opts);
    try std.testing.expectEqual(first.size, second.size);
    try std.testing.expectEqualSlices(u8, &first.blake3, &second.blake3);
    try std.testing.expectEqualSlices(u8, &first.blake3, &(try ext4.blake3File(io, path_a)));
    try runE2fsck(allocator, io, path_a);
}

test "native ext4 writer emits fsck-clean multi-group image" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "zig-cache/test-native-ext4-multigroup.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const entries = [_]Entry{
        .{ .path = "etc/hostname", .kind = .{ .file = "sporevm\n" }, .mode = 0o644 },
    };
    const result = try emit(allocator, io, path, &entries, .{
        .image_size = 512 << 20,
        .inode_count = 65_536,
        .determinism = ext4.Determinism.fromDigest("sha256:test-native-ext4-multigroup"),
    });
    try std.testing.expectEqual(@as(u64, 512 << 20), result.size);
    try std.testing.expectEqualSlices(u8, &result.blake3, &(try ext4.blake3File(io, path)));
    try runE2fsck(allocator, io, path);
}

test "native ext4 writer supports double indirect regular files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "zig-cache/test-native-ext4-double-indirect.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const data = try allocator.alloc(u8, 5 * 1024 * 1024);
    defer allocator.free(data);
    for (data, 0..) |*byte, i| byte.* = @truncate(i);

    const entries = [_]Entry{
        .{ .path = "var/big.bin", .kind = .{ .file = data }, .mode = 0o644 },
    };
    const result = try emit(allocator, io, path, &entries, .{
        .image_size = 32 << 20,
        .inode_count = 1024,
        .determinism = ext4.Determinism.fromDigest("sha256:test-native-ext4-double-indirect"),
    });
    try std.testing.expectEqualSlices(u8, &result.blake3, &(try ext4.blake3File(io, path)));
    try runE2fsck(allocator, io, path);
}

test "native ext4 writer resolves hardlinks after sorted targets" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "zig-cache/test-native-ext4-hardlink-order.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const entries = [_]Entry{
        .{ .path = "z-target", .kind = .{ .file = "shared\n" }, .mode = 0o644 },
        .{ .path = "a-alias", .kind = .{ .hardlink = "z-target" } },
    };
    const result = try emit(allocator, io, path, &entries, .{
        .image_size = min_image_size,
        .inode_count = 1024,
        .determinism = ext4.Determinism.fromDigest("sha256:test-native-ext4-hardlink-order"),
    });
    try std.testing.expectEqualSlices(u8, &result.blake3, &(try ext4.blake3File(io, path)));
    try runE2fsck(allocator, io, path);
}

fn runE2fsck(allocator: std.mem.Allocator, io: Io, path: []const u8) !void {
    const candidates = [_][]const u8{
        "/opt/homebrew/opt/e2fsprogs/sbin/e2fsck",
        "e2fsck",
    };
    for (candidates) |candidate| {
        const result = std.process.run(allocator, io, .{
            .argv = &.{ candidate, "-f", "-n", path },
            .stdout_limit = .limited(256 * 1024),
            .stderr_limit = .limited(256 * 1024),
        }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) return,
            else => {},
        }
        if (result.stdout.len != 0) std.debug.print("{s}\n", .{result.stdout});
        if (result.stderr.len != 0) std.debug.print("{s}\n", .{result.stderr});
        return error.E2fsckFailed;
    }
    return error.E2fsckMissing;
}
