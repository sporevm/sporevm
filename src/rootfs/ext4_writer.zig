//! Native write-only ext4-compatible image emitter.
//!
//! This module deliberately only creates fresh images. It does not read or
//! mutate existing filesystems.

const std = @import("std");
const chunk = @import("../chunk.zig");
const chunk_sealer = @import("../chunk_sealer.zig");
const disk_index = @import("../disk_index.zig");
const ext4 = @import("ext4.zig");
const rootfs_cas = @import("../rootfs_cas.zig");
const spore = @import("../spore.zig");
const tar = @import("tar.zig");
const xattrs_mod = @import("xattrs.zig");

const Io = std.Io;

const block_size: u32 = ext4.rootfs_ext4_block_size;
const inode_size: u16 = ext4.rootfs_ext4_inode_size;
const first_non_reserved_inode: u32 = 11;
const root_inode: u32 = 2;
const lost_found_inode: u32 = 11;
const min_image_size: u64 = 16 << 20;
const blocks_per_group: u32 = 32768;
const group_descriptor_size: u32 = 32;
const max_direct_blocks: usize = 12;
const pointers_per_block: usize = block_size / @sizeOf(u32);
const source_batch_bytes: usize = 16 << 20;

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

/// A symlink target is stored inline in i_block ("fast symlink") only when it
/// is strictly shorter than the 60-byte i_block area; a 60-byte target must
/// live in a data block, matching the kernel's `i_size < sizeof(i_data)` rule.
const fast_symlink_max_len: usize = 60;

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
    file_source: tar.FileSource,
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
    mtime: ?Mtime = null,
};

pub const Mtime = struct {
    seconds: i64,
    nanoseconds: u32,
};

pub const Options = struct {
    image_size: u64 = min_image_size,
    inode_count: u32 = 1024,
    determinism: ext4.Determinism,
    cas_cache_root: ?[]const u8 = null,
    cas_chunk_size: u64 = rootfs_cas.default_chunk_size,
    cas_seal_workers: usize = 0,
};

pub const Result = struct {
    size: u64,
    preload_result: ?rootfs_cas.PreloadResult = null,
    profile: EmitProfile = .{},
};

pub const EmitProfile = struct {
    plan_ms: u64 = 0,
    assign_ms: u64 = 0,
    metadata_build_ms: u64 = 0,
    file_create_ms: u64 = 0,
    emit_map_ms: u64 = 0,
    emit_map_bytes: u64 = 0,
    counted_emitter_buffers_bytes: u64 = 0,
    metadata_write_ms: u64 = 0,
    source_read_ms: u64 = 0,
    data_write_ms: u64 = 0,
    zero_ms: u64 = 0,
    zero_write_ms: u64 = 0,
    inline_cas_metadata_ms: u64 = 0,
    inline_cas_data_ms: u64 = 0,
    inline_cas_zero_ms: u64 = 0,
    inline_cas_finish_ms: u64 = 0,
    file_sync_ms: u64 = 0,
    file_close_ms: u64 = 0,
    metadata_blocks: u64 = 0,
    data_blocks: u64 = 0,
    zero_blocks: u64 = 0,
    metadata_bytes_written: u64 = 0,
    data_bytes_written: u64 = 0,
    zero_bytes_skipped: u64 = 0,
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
    path: []const u8 = &.{},
    kind: InodeKind,
    mode: u16,
    uid: u32,
    gid: u32,
    size: u64 = 0,
    links: u16 = 1,
    data: []const u8 = &.{},
    file_source: ?tar.FileSource = null,
    symlink_target: []const u8 = &.{},
    device: ?Device = null,
    xattrs: []const xattrs_mod.Attribute = &.{},
    data_blocks: []u32 = &.{},
    indirect_blocks: []u32 = &.{},
    single_indirect_block: u32 = 0,
    double_indirect_block: u32 = 0,
    xattr_block: u32 = 0,
    mtime: ?EncodedMtime = null,

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

const EncodedMtime = struct {
    seconds_low: u32,
    extra: u32,
};

const PathRef = struct {
    path: []const u8,
    inode_index: usize,
};

const DirChild = struct {
    name: []const u8,
    inode_index: usize,
};

const directory_child_index_threshold: usize = 8_000_000;

const DirectoryChildIndex = struct {
    const none: usize = std.math.maxInt(usize);

    heads: []usize,
    next: []usize,
    children: []DirChild,
    child_count: usize,

    fn build(allocator: std.mem.Allocator, planned: *const PlannedImage) !DirectoryChildIndex {
        const heads = try allocator.alloc(usize, planned.inodes.items.len);
        errdefer allocator.free(heads);
        @memset(heads, none);

        const next = try allocator.alloc(usize, planned.paths.items.len);
        errdefer allocator.free(next);
        @memset(next, none);

        const children = try allocator.alloc(DirChild, planned.paths.items.len);
        errdefer allocator.free(children);

        const tails = try allocator.alloc(usize, planned.inodes.items.len);
        defer allocator.free(tails);
        @memset(tails, none);

        var child_count: usize = 0;
        for (planned.paths.items) |path_ref| {
            if (path_ref.path.len == 0) continue;
            const parent = parentPath(path_ref.path);
            const parent_inode_index = planned.path_index.get(parent) orelse return error.BadExt4Tree;
            if (planned.inodes.items[parent_inode_index].kind != .directory) return error.ParentNotDirectory;
            const child_index = child_count;
            child_count += 1;
            children[child_index] = .{
                .name = baseName(path_ref.path),
                .inode_index = path_ref.inode_index,
            };
            if (tails[parent_inode_index] == none) {
                heads[parent_inode_index] = child_index;
            } else {
                next[tails[parent_inode_index]] = child_index;
            }
            tails[parent_inode_index] = child_index;
        }

        return .{
            .heads = heads,
            .next = next,
            .children = children,
            .child_count = child_count,
        };
    }

    fn deinit(self: *DirectoryChildIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.heads);
        allocator.free(self.next);
        allocator.free(self.children);
    }
};

const PlannedImage = struct {
    inodes: std.ArrayList(InodePlan) = .empty,
    paths: std.ArrayList(PathRef) = .empty,
    path_index: std.StringHashMap(usize),
    directory_count: usize = 0,

    fn deinit(self: *PlannedImage, allocator: std.mem.Allocator) void {
        for (self.inodes.items) |inode| {
            allocator.free(inode.data_blocks);
            allocator.free(inode.indirect_blocks);
        }
        self.inodes.deinit(allocator);
        self.paths.deinit(allocator);
        self.path_index.deinit();
    }

    fn appendPath(self: *PlannedImage, allocator: std.mem.Allocator, path: []const u8, inode_index: usize) !void {
        try self.paths.append(allocator, .{ .path = path, .inode_index = inode_index });
        errdefer _ = self.paths.pop();
        try self.path_index.put(path, inode_index);
    }
};

const BlockStore = std.AutoHashMap(u32, []u8);
const DataBlockStore = std.ArrayList(DataBlockRun);

const DataBlockRun = struct {
    first_block: u32,
    block_count: u32,
    source: tar.FileSource,
    source_offset: u64,
    byte_len: u64,
};

const EmitSpan = struct {
    first_block: u32,
    block_count: u32,
    payload: union(enum) {
        metadata: []u8,
        data: DataBlockRun,
    },
};

const EmitPlan = struct {
    spans: []EmitSpan,
    allocated_bytes: u64,
};

const SourceFile = struct {
    path: []const u8,
    file: Io.File,
};

const SourceFileCache = struct {
    files: std.ArrayList(SourceFile) = .empty,

    fn deinit(self: *SourceFileCache, allocator: std.mem.Allocator, io: Io) void {
        for (self.files.items) |item| item.file.close(io);
        self.files.deinit(allocator);
    }

    fn open(self: *SourceFileCache, allocator: std.mem.Allocator, io: Io, path: []const u8) !Io.File {
        for (self.files.items) |item| {
            if (std.mem.eql(u8, item.path, path)) return item.file;
        }
        const file = if (Io.Dir.path.isAbsolute(path))
            try Io.Dir.openFileAbsolute(io, path, .{})
        else
            try Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        try self.files.append(allocator, .{ .path = path, .file = file });
        return file;
    }
};

const InlineRootfsCas = struct {
    const SealTask = struct {
        logical_chunk: usize,
        data: []u8,
    };

    const SealResult = struct {
        id: chunk.ChunkId,
        bytes_len: usize,
        published: bool,
    };

    allocator: std.mem.Allocator,
    io: Io,
    cache_root: []const u8,
    chunk_size: usize,
    image_size: u64,
    chunk_buf: []u8,
    seal_results: []?SealResult,
    seal_queue: []?SealTask,
    seal_threads: []std.Thread,
    seal_worker_stats: []chunk_sealer.WorkStats,
    seal_mutex: Io.Mutex = .init,
    seal_cond: Io.Condition = .init,
    seal_queue_head: usize = 0,
    seal_queue_tail: usize = 0,
    seal_queue_count: usize = 0,
    seal_queue_closed: bool = false,
    seal_queue_failed: bool = false,
    seal_queue_error: ?anyerror = null,
    seal_workers_started: usize = 0,
    seal_workers_joined: bool = false,
    seal_start_ms: u64 = 0,
    chunk_fill: usize = 0,
    logical_chunk: u64 = 0,
    manifest_chunks: std.ArrayList(disk_index.DiskIndexChunk) = .empty,
    manifest_zero_chunks: std.ArrayList(u64) = .empty,
    chunk_count: usize = 0,
    zero_chunks: usize = 0,
    nonzero_chunks: usize = 0,
    objects_written: usize = 0,
    object_bytes_written: u64 = 0,
    chunk_scan_ms: u64 = 0,
    object_write_ms: u64 = 0,
    index_build_ms: u64 = 0,
    index_write_ms: u64 = 0,
    seal_wall_ms: u64 = 0,
    seal_worker_cpu_ms: u64 = 0,
    work_stats: chunk_sealer.WorkStats = .{},

    fn init(
        allocator: std.mem.Allocator,
        io: Io,
        cache_root: []const u8,
        image_size: u64,
        chunk_size: u64,
        requested_workers: usize,
    ) !InlineRootfsCas {
        if (chunk_size == 0 or chunk_size % block_size != 0 or chunk_size > std.math.maxInt(usize)) return error.BadManifest;
        const expected_chunks_u64 = divCeilU64(image_size, chunk_size);
        if (expected_chunks_u64 > std.math.maxInt(usize)) return error.BadManifest;
        const expected_chunks: usize = @intCast(expected_chunks_u64);
        const worker_count = if (requested_workers == 0)
            chunk_sealer.parallelWorkerCount(expected_chunks)
        else
            @min(requested_workers, expected_chunks);
        const queue_capacity = @max(worker_count * 2, @as(usize, 1));
        const object_dir = try std.fmt.allocPrint(allocator, "{s}/cas/rootfs/blake3/objects", .{cache_root});
        defer allocator.free(object_dir);
        try chunk_sealer.ensureDirPath(allocator, object_dir);
        const chunk_buf = try allocator.alloc(u8, @intCast(chunk_size));
        errdefer allocator.free(chunk_buf);
        const seal_results = try allocator.alloc(?SealResult, expected_chunks);
        errdefer allocator.free(seal_results);
        @memset(seal_results, null);
        const seal_queue = try allocator.alloc(?SealTask, queue_capacity);
        errdefer allocator.free(seal_queue);
        @memset(seal_queue, null);
        const seal_threads = try allocator.alloc(std.Thread, worker_count);
        errdefer allocator.free(seal_threads);
        const seal_worker_stats = try allocator.alloc(chunk_sealer.WorkStats, worker_count);
        errdefer allocator.free(seal_worker_stats);
        @memset(seal_worker_stats, .{});
        return .{
            .allocator = allocator,
            .io = io,
            .cache_root = cache_root,
            .chunk_size = @intCast(chunk_size),
            .image_size = image_size,
            .chunk_buf = chunk_buf,
            .seal_results = seal_results,
            .seal_queue = seal_queue,
            .seal_threads = seal_threads,
            .seal_worker_stats = seal_worker_stats,
        };
    }

    fn deinit(self: *InlineRootfsCas) void {
        self.stopSealWorkers();
        self.freeQueuedSealTasks();
        for (self.manifest_chunks.items) |entry| self.allocator.free(entry.digest);
        self.manifest_chunks.deinit(self.allocator);
        self.manifest_zero_chunks.deinit(self.allocator);
        self.allocator.free(self.seal_worker_stats);
        self.allocator.free(self.seal_threads);
        self.allocator.free(self.seal_queue);
        self.allocator.free(self.seal_results);
        self.allocator.free(self.chunk_buf);
        self.* = undefined;
    }

    fn writeBytes(self: *InlineRootfsCas, bytes: []const u8) !void {
        var remaining = bytes;
        while (remaining.len > 0) {
            const take = @min(remaining.len, self.chunk_size - self.chunk_fill);
            @memcpy(self.chunk_buf[self.chunk_fill..][0..take], remaining[0..take]);
            self.chunk_fill += take;
            remaining = remaining[take..];
            if (self.chunk_fill == self.chunk_size) try self.flushChunk(self.chunk_buf);
        }
    }

    fn writeZeroBytes(self: *InlineRootfsCas, byte_len: usize) !void {
        var remaining = byte_len;
        if (self.chunk_fill != 0) {
            const take = @min(remaining, self.chunk_size - self.chunk_fill);
            @memset(self.chunk_buf[self.chunk_fill..][0..take], 0);
            self.chunk_fill += take;
            remaining -= take;
            if (self.chunk_fill == self.chunk_size) try self.flushChunk(self.chunk_buf);
        }
        while (remaining >= self.chunk_size) {
            try self.appendZeroChunk();
            remaining -= self.chunk_size;
        }
        if (remaining > 0) {
            @memset(self.chunk_buf[0..remaining], 0);
            self.chunk_fill = remaining;
        }
    }

    fn finish(self: *InlineRootfsCas) !rootfs_cas.PreloadResult {
        if (self.chunk_fill != 0) try self.flushChunk(self.chunk_buf[0..self.chunk_fill]);
        const expected_chunks_u64 = divCeilU64(self.image_size, @intCast(self.chunk_size));
        if (expected_chunks_u64 > std.math.maxInt(usize)) return error.BadManifest;
        const expected_chunks: usize = @intCast(expected_chunks_u64);
        if (self.logical_chunk != expected_chunks_u64 or self.chunk_count != expected_chunks) return error.BadManifest;
        try self.finishSealWorkers();
        try self.appendSealedManifestChunks(expected_chunks);

        const index_build_start = monotonicMs();
        const manifest_index = disk_index.DiskIndex{
            .kind = disk_index.disk_index_kind,
            .logical_size = self.image_size,
            .chunk_size = self.chunk_size,
            .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
            .object_namespace = spore.rootfs_storage_object_namespace,
            .chunks = self.manifest_chunks.items,
            .zero_chunks = self.manifest_zero_chunks.items,
        };
        const encoded_index = try disk_index.encodeCanonicalAlloc(self.allocator, manifest_index);
        defer self.allocator.free(encoded_index.bytes);
        const index_digest = encoded_index.digest;
        errdefer self.allocator.free(index_digest);
        self.index_build_ms = monotonicMs() -| index_build_start;

        const index_path = try rootfs_cas.manifestIndexPath(self.allocator, self.cache_root, index_digest);
        errdefer self.allocator.free(index_path);
        const index_dir = std.fs.path.dirname(index_path) orelse return error.BadManifest;
        try chunk_sealer.ensureDirPath(self.allocator, index_dir);
        const index_write_start = monotonicMs();
        try chunk_sealer.writeFileAtomicDurable(self.allocator, index_path, encoded_index.bytes, 0o444);
        self.index_write_ms = monotonicMs() -| index_write_start;
        try rootfs_cas.markStorageComplete(self.io, self.allocator, self.cache_root, index_digest);

        const rootfs_digest = try self.allocator.dupe(u8, index_digest);
        errdefer self.allocator.free(rootfs_digest);
        return .{
            .index_path = index_path,
            .index_digest = index_digest,
            .rootfs_digest = rootfs_digest,
            .rootfs_size = self.image_size,
            .chunk_size = self.chunk_size,
            .chunk_count = self.chunk_count,
            .zero_chunks = self.zero_chunks,
            .nonzero_chunks = self.nonzero_chunks,
            .objects_written = self.objects_written,
            .object_bytes_written = self.object_bytes_written,
            .index_bytes = encoded_index.bytes.len,
            .chunk_scan_ms = self.chunk_scan_ms,
            .object_write_ms = self.object_write_ms,
            .index_build_ms = self.index_build_ms,
            .index_write_ms = self.index_write_ms,
            .sealed_chunks = self.work_stats.sealed_chunks,
            .seal_workers = self.seal_workers_started,
            .seal_wall_ms = self.seal_wall_ms,
            .seal_worker_cpu_ms = self.seal_worker_cpu_ms,
        };
    }

    fn appendZeroChunk(self: *InlineRootfsCas) !void {
        try self.manifest_zero_chunks.append(self.allocator, self.logical_chunk);
        self.logical_chunk += 1;
        self.chunk_count += 1;
        self.zero_chunks += 1;
        self.chunk_fill = 0;
    }

    fn flushChunk(self: *InlineRootfsCas, bytes: []const u8) !void {
        const scan_start = monotonicMs();
        const is_zero = std.mem.allEqual(u8, bytes, 0);
        self.chunk_scan_ms += monotonicMs() -| scan_start;
        if (is_zero) {
            try self.appendZeroChunk();
            return;
        }
        try self.enqueueDataChunk(bytes);
    }

    fn enqueueDataChunk(self: *InlineRootfsCas, bytes: []const u8) !void {
        if (self.logical_chunk > std.math.maxInt(usize)) return error.BadManifest;
        try self.startSealWorkers();

        const data = try std.heap.page_allocator.alloc(u8, bytes.len);
        errdefer std.heap.page_allocator.free(data);
        @memcpy(data, bytes);
        const task = SealTask{
            .logical_chunk = @intCast(self.logical_chunk),
            .data = data,
        };

        self.seal_mutex.lockUncancelable(self.io);
        defer self.seal_mutex.unlock(self.io);
        while (self.seal_queue_count == self.seal_queue.len and !self.seal_queue_failed) {
            self.seal_cond.waitUncancelable(self.io, &self.seal_mutex);
        }
        if (self.seal_queue_failed) return self.seal_queue_error orelse error.IoFailed;
        if (self.seal_queue_closed) return error.BadManifest;

        self.seal_queue[self.seal_queue_tail] = task;
        self.seal_queue_tail = (self.seal_queue_tail + 1) % self.seal_queue.len;
        self.seal_queue_count += 1;
        self.seal_cond.signal(self.io);

        self.logical_chunk += 1;
        self.chunk_count += 1;
        self.nonzero_chunks += 1;
        self.chunk_fill = 0;
    }

    fn startSealWorkers(self: *InlineRootfsCas) !void {
        if (self.seal_workers_started != 0 or self.seal_threads.len == 0) return;
        self.seal_start_ms = monotonicMs();
        while (self.seal_workers_started < self.seal_threads.len) : (self.seal_workers_started += 1) {
            self.seal_threads[self.seal_workers_started] = std.Thread.spawn(.{}, sealWorkerMain, .{ self, self.seal_workers_started }) catch |err| {
                self.failSealQueue(err);
                self.joinSealWorkers();
                return err;
            };
        }
    }

    fn finishSealWorkers(self: *InlineRootfsCas) !void {
        self.closeSealQueue();
        self.joinSealWorkers();
        if (self.seal_queue_failed) return self.seal_queue_error orelse error.IoFailed;

        var work_stats: chunk_sealer.WorkStats = .{};
        for (self.seal_worker_stats[0..self.seal_workers_started]) |stats| work_stats.add(stats);
        self.work_stats.add(work_stats);
        self.chunk_scan_ms +|= chunk_sealer.nsToMs(work_stats.zero_scan_ns +| work_stats.hash_ns);
        self.object_write_ms +|= chunk_sealer.nsToMs(work_stats.chunk_write_ns);
        self.seal_worker_cpu_ms +|= chunk_sealer.nsToMs(work_stats.cpu_ns);
        if (self.seal_start_ms != 0) self.seal_wall_ms = monotonicMs() -| self.seal_start_ms;
    }

    fn closeSealQueue(self: *InlineRootfsCas) void {
        self.seal_mutex.lockUncancelable(self.io);
        defer self.seal_mutex.unlock(self.io);
        self.seal_queue_closed = true;
        self.seal_cond.broadcast(self.io);
    }

    fn failSealQueue(self: *InlineRootfsCas, err: anyerror) void {
        self.seal_mutex.lockUncancelable(self.io);
        defer self.seal_mutex.unlock(self.io);
        if (!self.seal_queue_failed) {
            self.seal_queue_failed = true;
            self.seal_queue_error = err;
        }
        self.seal_cond.broadcast(self.io);
    }

    fn joinSealWorkers(self: *InlineRootfsCas) void {
        if (self.seal_workers_joined) return;
        for (self.seal_threads[0..self.seal_workers_started]) |thread| thread.join();
        self.seal_workers_joined = true;
    }

    fn stopSealWorkers(self: *InlineRootfsCas) void {
        self.closeSealQueue();
        self.joinSealWorkers();
    }

    fn takeSealTask(self: *InlineRootfsCas) ?SealTask {
        self.seal_mutex.lockUncancelable(self.io);
        defer self.seal_mutex.unlock(self.io);
        while (self.seal_queue_count == 0 and !self.seal_queue_closed and !self.seal_queue_failed) {
            self.seal_cond.waitUncancelable(self.io, &self.seal_mutex);
        }
        if (self.seal_queue_failed) return null;
        if (self.seal_queue_count == 0) return null;
        const task = self.seal_queue[self.seal_queue_head].?;
        self.seal_queue[self.seal_queue_head] = null;
        self.seal_queue_head = (self.seal_queue_head + 1) % self.seal_queue.len;
        self.seal_queue_count -= 1;
        self.seal_cond.signal(self.io);
        return task;
    }

    fn freeQueuedSealTasks(self: *InlineRootfsCas) void {
        for (self.seal_queue) |maybe_task| {
            if (maybe_task) |task| std.heap.page_allocator.free(task.data);
        }
    }

    fn processSealTask(self: *InlineRootfsCas, task: SealTask, work_stats: *chunk_sealer.WorkStats) !void {
        switch (try chunk_sealer.sealBytes(task.data, work_stats)) {
            .zero => return error.BadManifest,
            .data => |id| {
                const hex = id.toHex();
                const object_path = try std.fmt.allocPrint(
                    std.heap.page_allocator,
                    "{s}/cas/rootfs/blake3/objects/{s}.chunk",
                    .{ self.cache_root, hex[0..] },
                );
                defer std.heap.page_allocator.free(object_path);
                const write_result = try chunk_sealer.writePathAllIfMissingTimedResult(
                    std.heap.page_allocator,
                    object_path,
                    task.data,
                    work_stats,
                );
                self.seal_results[task.logical_chunk] = .{
                    .id = id,
                    .bytes_len = task.data.len,
                    .published = write_result == .published,
                };
                work_stats.sealed_chunks +|= 1;
            },
        }
    }

    fn appendSealedManifestChunks(self: *InlineRootfsCas, expected_chunks: usize) !void {
        var nonzero_results: usize = 0;
        for (self.seal_results[0..expected_chunks], 0..) |maybe_result, logical_chunk| {
            const result = maybe_result orelse continue;
            nonzero_results += 1;
            const hex = result.id.toHex();
            const digest = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ spore.rootfs_digest_prefix, hex[0..] });
            self.manifest_chunks.append(self.allocator, .{
                .logical_chunk = @intCast(logical_chunk),
                .digest = digest,
            }) catch |err| {
                self.allocator.free(digest);
                return err;
            };
            if (result.published) {
                self.objects_written += 1;
                self.object_bytes_written += result.bytes_len;
            }
        }
        if (nonzero_results != self.nonzero_chunks) return error.BadManifest;
    }

    fn sealWorkerMain(self: *InlineRootfsCas, worker_index: usize) void {
        var work_stats: chunk_sealer.WorkStats = .{};
        const cpu_start = chunk_sealer.threadCpuNs();
        defer {
            work_stats.cpu_ns = chunk_sealer.elapsedCpuNs(cpu_start);
            self.seal_worker_stats[worker_index] = work_stats;
        }

        while (self.takeSealTask()) |task| {
            self.processSealTask(task, &work_stats) catch |err| {
                std.heap.page_allocator.free(task.data);
                self.failSealQueue(err);
                break;
            };
            std.heap.page_allocator.free(task.data);
        }
    }
};

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
    try validateInodeCount(options.inode_count);

    var profile: EmitProfile = .{};
    const plan_start = monotonicMs();
    var planned = try planImage(allocator, entries, options.inode_count);
    profile.plan_ms = monotonicMs() -| plan_start;
    defer planned.deinit(allocator);

    var blocks = BlockStore.init(allocator);
    defer freeBlockStore(allocator, &blocks);
    var data_blocks = DataBlockStore.empty;
    defer data_blocks.deinit(allocator);

    const assign_start = monotonicMs();
    const layout = try assignBlocks(allocator, &planned, total_blocks, options.inode_count, &blocks, &data_blocks);
    profile.assign_ms = monotonicMs() -| assign_start;
    defer allocator.free(layout.groups);
    const metadata_build_start = monotonicMs();
    try writeMetadataBlocks(allocator, &planned, layout, options, &blocks);
    profile.metadata_build_ms = monotonicMs() -| metadata_build_start;
    return try writeImage(allocator, io, output_path, options.image_size, total_blocks, &blocks, &data_blocks, options.cas_cache_root, options.cas_chunk_size, options.cas_seal_workers, &profile);
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
                    .kind = .{ .file_source = try tree.fileSource(ref.entry.inode_id) },
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
    var planned = PlannedImage{ .path_index = std.StringHashMap(usize).init(allocator) };
    errdefer planned.deinit(allocator);

    try planned.inodes.append(allocator, .{
        .ino = root_inode,
        .path = "",
        .kind = .directory,
        .mode = s_ifdir | 0o755,
        .uid = 0,
        .gid = 0,
    });
    planned.directory_count += 1;
    try planned.appendPath(allocator, "", 0);

    _ = try ensureDirectoryPath(allocator, &planned, "lost+found", 0o700, 0, 0, lost_found_inode);

    const sorted = try allocator.alloc(Entry, entries.len);
    defer allocator.free(sorted);
    @memcpy(sorted, entries);
    std.mem.sort(Entry, sorted, {}, lessEntryPath);

    var next_inode: u32 = first_non_reserved_inode + 1;
    for (sorted) |entry| {
        if (entry.mtime != null) switch (entry.kind) {
            .file, .file_source => {},
            else => return error.UnsupportedEntryMtime,
        };
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
                if (pathIndex(&planned, normalized) != null) return error.DuplicateRootFSEntry;
                if (next_inode > inode_count) return error.RootFSTooManyInodes;
                try planned.inodes.append(allocator, try entryInodePlan(entry, normalized, next_inode));
                try planned.appendPath(allocator, normalized, planned.inodes.items.len - 1);
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
        const target_path_index = pathIndex(&planned, target_path) orelse return error.BadHardlinkTarget;
        const target_inode = planned.inodes.items[target_path_index.inode_index];
        if (target_inode.kind != .file) return error.BadHardlinkTarget;
        if (pathIndex(&planned, normalized) != null) return error.DuplicateRootFSEntry;
        try planned.appendPath(allocator, normalized, target_path_index.inode_index);
    }

    try computeLinkCounts(&planned);
    try validateDirectoryPathCache(&planned);
    return planned;
}

fn validateDirectoryPathCache(planned: *const PlannedImage) !void {
    for (planned.inodes.items, 0..) |inode, inode_index| {
        if (inode.kind != .directory) continue;
        const path_inode_index = planned.path_index.get(inode.path) orelse return error.BadExt4Tree;
        if (path_inode_index != inode_index) return error.BadExt4Tree;
    }
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
    if (pathIndex(planned, path)) |existing| {
        const inode = &planned.inodes.items[existing.inode_index];
        if (inode.kind != .directory) return error.ParentNotDirectory;
        inode.mode = s_ifdir | (mode & 0o7777);
        inode.uid = uid;
        inode.gid = gid;
        return false;
    }
    try planned.inodes.append(allocator, .{
        .ino = inode_no,
        .path = path,
        .kind = .directory,
        .mode = s_ifdir | (mode & 0o7777),
        .uid = uid,
        .gid = gid,
    });
    planned.directory_count += 1;
    try planned.appendPath(allocator, path, planned.inodes.items.len - 1);
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
        if (parent.len != 0) {
            if (pathIndex(planned, parent)) |existing| {
                if (planned.inodes.items[existing.inode_index].kind != .directory) return error.ParentNotDirectory;
            } else {
                if (next_inode.* > inode_count) return error.RootFSTooManyInodes;
                if (try ensureDirectoryPath(allocator, planned, parent, 0o755, 0, 0, next_inode.*)) {
                    next_inode.* += 1;
                }
            }
        }
        slash_index = slash + 1;
    }
}

fn entryInodePlan(entry: Entry, normalized: []const u8, inode_no: u32) !InodePlan {
    for (entry.xattrs) |attr| {
        if (!std.mem.eql(u8, attr.name, xattrs_mod.security_capability_name)) return error.UnsupportedTarXattr;
        try xattrs_mod.validateSecurityCapability(attr.value);
    }
    const mtime = if (entry.mtime) |value| try encodeMtime(value) else null;
    return switch (entry.kind) {
        .file => |data| .{
            .ino = inode_no,
            .path = normalized,
            .kind = .file,
            .mode = s_ifreg | (entry.mode & 0o7777),
            .uid = entry.uid,
            .gid = entry.gid,
            .size = data.len,
            .data = data,
            .xattrs = entry.xattrs,
            .mtime = mtime,
        },
        .file_source => |source| .{
            .ino = inode_no,
            .path = normalized,
            .kind = .file,
            .mode = s_ifreg | (entry.mode & 0o7777),
            .uid = entry.uid,
            .gid = entry.gid,
            .size = source.size(),
            .file_source = source,
            .xattrs = entry.xattrs,
            .mtime = mtime,
        },
        .symlink => |target| .{
            .ino = inode_no,
            .path = normalized,
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
            .path = normalized,
            .kind = if (dev.kind == .char) .char_device else .block_device,
            .mode = (if (dev.kind == .char) s_ifchr else s_ifblk) | (entry.mode & 0o7777),
            .uid = entry.uid,
            .gid = entry.gid,
            .device = dev,
            .xattrs = entry.xattrs,
        },
        .fifo => .{
            .ino = inode_no,
            .path = normalized,
            .kind = .fifo,
            .mode = s_ififo | (entry.mode & 0o7777),
            .uid = entry.uid,
            .gid = entry.gid,
            .xattrs = entry.xattrs,
        },
        .socket => .{
            .ino = inode_no,
            .path = normalized,
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
            if (parentPathIndex(planned, path_ref.path)) |parent| {
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

const BlockAllocator = struct {
    used: *std.DynamicBitSetUnmanaged,
    next: usize = 0,

    fn alloc(self: *BlockAllocator) !u32 {
        var i = self.next;
        while (i < self.used.bit_length) : (i += 1) {
            if (self.used.isSet(i)) continue;
            self.used.set(i);
            self.next = i + 1;
            return @intCast(i);
        }
        return error.Ext4ImageTooSmall;
    }

    fn allocSlice(self: *BlockAllocator, out: []u32) !void {
        var filled: usize = 0;
        while (filled < out.len) {
            var start = self.next;
            while (start < self.used.bit_length and self.used.isSet(start)) : (start += 1) {}
            if (start >= self.used.bit_length) return error.Ext4ImageTooSmall;

            const max_end = @min(self.used.bit_length, start + out.len - filled);
            var end = start;
            while (end < max_end and !self.used.isSet(end)) : (end += 1) {}
            self.used.setRangeValue(.{ .start = start, .end = end }, true);
            self.next = end;

            var block_no = start;
            while (block_no < end) : (block_no += 1) {
                out[filled] = @intCast(block_no);
                filled += 1;
            }
        }
    }
};

fn assignBlocks(
    allocator: std.mem.Allocator,
    planned: *PlannedImage,
    total_blocks: u32,
    inode_count: u32,
    blocks: *BlockStore,
    data_blocks: *DataBlockStore,
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

    var block_allocator = BlockAllocator{ .used = &used };
    var maybe_directory_children: ?DirectoryChildIndex = if (shouldIndexDirectoryChildren(planned))
        try DirectoryChildIndex.build(allocator, planned)
    else
        null;
    defer if (maybe_directory_children) |*directory_children| directory_children.deinit(allocator);

    for (planned.inodes.items, 0..) |*inode, inode_index| {
        if (inode.kind == .directory) {
            const bytes = if (maybe_directory_children) |*directory_children|
                try directoryBytesIndexed(allocator, planned, inode.*, inode_index, directory_children)
            else
                try directoryBytes(allocator, planned, inode.*);
            defer allocator.free(bytes);
            inode.size = bytes.len;
            try allocatePayloadBlocks(allocator, inode, bytes, &block_allocator, blocks);
        } else if (inode.kind == .file) {
            if (inode.file_source) |source| {
                try allocateSourcePayloadBlocks(allocator, inode, source, &block_allocator, data_blocks);
            } else {
                try allocatePayloadBlocks(allocator, inode, inode.data, &block_allocator, blocks);
            }
        } else if (inode.kind == .symlink and inode.symlink_target.len >= fast_symlink_max_len) {
            try allocatePayloadBlocks(allocator, inode, inode.symlink_target, &block_allocator, blocks);
        }
        if (inode.xattrs.len != 0) {
            inode.xattr_block = try block_allocator.alloc();
            const xattr_block = try xattrBlock(allocator, inode.xattrs);
            try blocks.put(inode.xattr_block, xattr_block);
        }
        try allocateIndirectBlocks(allocator, inode, &block_allocator, blocks);
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

fn shouldIndexDirectoryChildren(planned: *const PlannedImage) bool {
    return planned.directory_count != 0 and
        planned.paths.items.len > directory_child_index_threshold / planned.directory_count;
}

fn allocateSourcePayloadBlocks(
    allocator: std.mem.Allocator,
    inode: *InodePlan,
    source: tar.FileSource,
    block_allocator: *BlockAllocator,
    data_blocks: *DataBlockStore,
) !void {
    const size = source.size();
    if (size == 0) return;
    const count = divCeilU64(size, block_size);
    inode.data_blocks = try allocator.alloc(u32, @intCast(count));
    try block_allocator.allocSlice(inode.data_blocks);
    var offset: u64 = 0;
    var run_first_block: u32 = 0;
    var run_block_count: u32 = 0;
    var run_source_offset: u64 = 0;
    var run_byte_len: u64 = 0;
    var previous_block: u32 = 0;
    for (inode.data_blocks) |block| {
        const take: usize = @intCast(@min(size - offset, block_size));
        if (run_block_count == 0) {
            run_first_block = block;
            run_source_offset = offset;
        } else if (block != previous_block + 1) {
            try appendDataBlockRun(data_blocks, allocator, run_first_block, run_block_count, source, run_source_offset, run_byte_len);
            run_first_block = block;
            run_block_count = 0;
            run_source_offset = offset;
            run_byte_len = 0;
        }
        run_block_count += 1;
        run_byte_len += take;
        previous_block = block;
        offset += take;
    }
    try appendDataBlockRun(data_blocks, allocator, run_first_block, run_block_count, source, run_source_offset, run_byte_len);
}

fn appendDataBlockRun(
    data_blocks: *DataBlockStore,
    allocator: std.mem.Allocator,
    first_block: u32,
    block_count: u32,
    source: tar.FileSource,
    source_offset: u64,
    byte_len: u64,
) !void {
    if (block_count == 0) return;
    try data_blocks.append(allocator, .{
        .first_block = first_block,
        .block_count = block_count,
        .source = source,
        .source_offset = source_offset,
        .byte_len = byte_len,
    });
}

fn allocatePayloadBlocks(
    allocator: std.mem.Allocator,
    inode: *InodePlan,
    payload: []const u8,
    block_allocator: *BlockAllocator,
    blocks: *BlockStore,
) !void {
    if (payload.len == 0) return;
    const count = divCeilUsize(payload.len, block_size);
    inode.data_blocks = try allocator.alloc(u32, count);
    try block_allocator.allocSlice(inode.data_blocks);
    var offset: usize = 0;
    for (inode.data_blocks) |block| {
        const data_block = try zeroBlock(allocator);
        const take = @min(payload.len - offset, block_size);
        @memcpy(data_block[0..take], payload[offset .. offset + take]);
        try blocks.put(block, data_block);
        offset += take;
    }
}

fn allocateIndirectBlocks(
    allocator: std.mem.Allocator,
    inode: *InodePlan,
    block_allocator: *BlockAllocator,
    blocks: *BlockStore,
) !void {
    if (inode.data_blocks.len <= max_direct_blocks) return;
    const double_capacity = pointers_per_block * pointers_per_block;
    if (inode.data_blocks.len > max_direct_blocks + pointers_per_block + double_capacity) return error.UnsupportedExt4FileSize;

    var metadata_blocks = std.ArrayList(u32).empty;
    errdefer metadata_blocks.deinit(allocator);

    var data_index: usize = max_direct_blocks;
    if (data_index < inode.data_blocks.len) {
        inode.single_indirect_block = try block_allocator.alloc();
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
        inode.double_indirect_block = try block_allocator.alloc();
        try metadata_blocks.append(allocator, inode.double_indirect_block);
        const root = try zeroBlock(allocator);
        var root_index: usize = 0;
        while (data_index < inode.data_blocks.len) : (root_index += 1) {
            if (root_index >= pointers_per_block) return error.UnsupportedExt4FileSize;
            const leaf_block = try block_allocator.alloc();
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

fn directoryBytes(allocator: std.mem.Allocator, planned: *const PlannedImage, inode: InodePlan) ![]u8 {
    var children = std.ArrayList(DirChild).empty;
    defer children.deinit(allocator);
    const self_path = inode.path;
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
        const parent = parentPathIndex(planned, self_path) orelse return error.BadExt4Tree;
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

fn directoryBytesIndexed(
    allocator: std.mem.Allocator,
    planned: *const PlannedImage,
    inode: InodePlan,
    inode_index: usize,
    directory_children: *const DirectoryChildIndex,
) ![]u8 {
    var children = std.ArrayList(DirChild).empty;
    defer children.deinit(allocator);
    var child_index = directory_children.heads[inode_index];
    while (child_index != DirectoryChildIndex.none) {
        if (child_index >= directory_children.child_count) return error.BadExt4Tree;
        try children.append(allocator, directory_children.children[child_index]);
        child_index = directory_children.next[child_index];
    }
    std.mem.sort(DirChild, children.items, planned, lessDirChild);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendDirent(allocator, &out, inode.ino, ".", file_type_dir, false);
    const self_path = inode.path;
    const parent_inode = if (self_path.len == 0)
        inode.ino
    else blk: {
        const parent = parentPathIndex(planned, self_path) orelse return error.BadExt4Tree;
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
    if (inode.mtime) |mtime| {
        put(u32, buf, 0x10, mtime.seconds_low);
        // The mtime extra field ends 12 bytes beyond the original 128-byte
        // inode. Leave legacy inodes untouched unless a caller opted in.
        put(u16, buf, 0x80, 12);
        put(u32, buf, 0x88, mtime.extra);
    }

    switch (inode.kind) {
        .symlink => {
            if (inode.symlink_target.len < fast_symlink_max_len) {
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

fn encodeMtime(mtime: Mtime) !EncodedMtime {
    if (mtime.seconds < std.math.minInt(i32) or mtime.seconds > 0x37fffffff) return error.Ext4MtimeOutOfRange;
    if (mtime.nanoseconds >= std.time.ns_per_s) return error.Ext4MtimeOutOfRange;
    const seconds_bits: u64 = @bitCast(mtime.seconds);
    const seconds_low: u32 = @truncate(seconds_bits);
    const signed_low: i64 = @as(i32, @bitCast(seconds_low));
    const epoch_delta = mtime.seconds - signed_low;
    const epoch_width: i64 = @as(i64, 1) << 32;
    if (@mod(epoch_delta, epoch_width) != 0) return error.Ext4MtimeOutOfRange;
    const epoch: u32 = @intCast(@divExact(epoch_delta, epoch_width));
    if (epoch > 3) return error.Ext4MtimeOutOfRange;
    // Linux stores the two epoch bits below the 30-bit nanosecond value.
    return .{
        .seconds_low = seconds_low,
        .extra = (mtime.nanoseconds << 2) | epoch,
    };
}

test "ext4 mtime encoding preserves epochs and nanoseconds" {
    const ordinary = try encodeMtime(.{ .seconds = 1_700_000_000, .nanoseconds = 123_456_789 });
    try std.testing.expectEqual(@as(u32, 1_700_000_000), ordinary.seconds_low);
    try std.testing.expectEqual(@as(u32, 123_456_789 << 2), ordinary.extra);

    const after_2038 = try encodeMtime(.{ .seconds = 0x80000000, .nanoseconds = 1 });
    try std.testing.expectEqual(@as(u32, 0x80000000), after_2038.seconds_low);
    try std.testing.expectEqual(@as(u32, 5), after_2038.extra);

    const minimum = try encodeMtime(.{ .seconds = std.math.minInt(i32), .nanoseconds = 0 });
    try std.testing.expectEqual(@as(u32, 0x80000000), minimum.seconds_low);
    try std.testing.expectEqual(@as(u32, 0), minimum.extra);

    const maximum = try encodeMtime(.{ .seconds = 0x37fffffff, .nanoseconds = 999_999_999 });
    try std.testing.expectEqual(@as(u32, 0x7fffffff), maximum.seconds_low);
    try std.testing.expectEqual(@as(u32, (999_999_999 << 2) | 3), maximum.extra);

    try std.testing.expectError(error.Ext4MtimeOutOfRange, encodeMtime(.{ .seconds = @as(i64, std.math.minInt(i32)) - 1, .nanoseconds = 0 }));
    try std.testing.expectError(error.Ext4MtimeOutOfRange, encodeMtime(.{ .seconds = 0x380000000, .nanoseconds = 0 }));
    try std.testing.expectError(error.Ext4MtimeOutOfRange, encodeMtime(.{ .seconds = 0, .nanoseconds = std.time.ns_per_s }));
}

test "write inode leaves legacy timestamps byte-identical unless opted in" {
    var legacy: [inode_size]u8 = @splat(0);
    writeInode(&legacy, .{
        .ino = 12,
        .kind = .file,
        .mode = s_ifreg | 0o644,
        .uid = 0,
        .gid = 0,
    });
    try std.testing.expect(std.mem.allEqual(u8, legacy[0x08..0x18], 0));
    try std.testing.expect(std.mem.allEqual(u8, legacy[0x80..0x8c], 0));

    var captured: [inode_size]u8 = @splat(0);
    writeInode(&captured, .{
        .ino = 12,
        .kind = .file,
        .mode = s_ifreg | 0o644,
        .uid = 0,
        .gid = 0,
        .mtime = try encodeMtime(.{ .seconds = 1_700_000_000, .nanoseconds = 123_456_789 }),
    });
    try std.testing.expectEqual(@as(u32, 1_700_000_000), std.mem.readInt(u32, captured[0x10..0x14], .little));
    try std.testing.expectEqual(@as(u16, 12), std.mem.readInt(u16, captured[0x80..0x82], .little));
    try std.testing.expectEqual(@as(u32, 123_456_789 << 2), std.mem.readInt(u32, captured[0x88..0x8c], .little));
    try std.testing.expect(std.mem.allEqual(u8, captured[0x08..0x10], 0));
    try std.testing.expect(std.mem.allEqual(u8, captured[0x14..0x18], 0));
}

test "ext4 writer rejects mtime on non-file entries" {
    const entries = [_]Entry{.{
        .path = "directory",
        .kind = .directory,
        .mtime = .{ .seconds = 1, .nanoseconds = 2 },
    }};
    try std.testing.expectError(error.UnsupportedEntryMtime, planImage(std.testing.allocator, &entries, 1024));
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

fn writeImage(
    allocator: std.mem.Allocator,
    io: Io,
    output_path: []const u8,
    image_size: u64,
    total_blocks: u32,
    blocks: *BlockStore,
    data_blocks: *DataBlockStore,
    cas_cache_root: ?[]const u8,
    cas_chunk_size: u64,
    cas_seal_workers: usize,
    profile: *EmitProfile,
) !Result {
    const file_create_start = monotonicMs();
    try ext4.ensureParentDir(io, output_path);
    try ext4.createEmptyFile(io, output_path, image_size);
    var file = if (Io.Dir.path.isAbsolute(output_path))
        try Io.Dir.openFileAbsolute(io, output_path, .{ .mode = .read_write })
    else
        try Io.Dir.cwd().openFile(io, output_path, .{ .mode = .read_write });
    profile.file_create_ms +|= monotonicMs() -| file_create_start;
    var file_closed = false;
    defer if (!file_closed) file.close(io);

    const emit_map_start = monotonicMs();
    const emit_plan = try buildEmitSpans(allocator, total_blocks, blocks, data_blocks);
    const emit_spans = emit_plan.spans;
    profile.emit_map_ms +|= monotonicMs() -| emit_map_start;
    profile.emit_map_bytes = emit_plan.allocated_bytes;
    defer allocator.free(emit_spans);

    const source_buffer = try allocator.alloc(u8, source_batch_bytes);
    defer allocator.free(source_buffer);
    var source_files = SourceFileCache{};
    defer source_files.deinit(allocator, io);
    var maybe_inline_cas: ?InlineRootfsCas = if (cas_cache_root) |cache_root|
        try InlineRootfsCas.init(allocator, io, cache_root, image_size, cas_chunk_size, cas_seal_workers)
    else
        null;
    defer if (maybe_inline_cas) |*inline_cas| inline_cas.deinit();
    var block_cursor: u32 = 0;
    for (emit_spans) |span| {
        if (span.first_block > block_cursor) {
            try emitZeroGap(span.first_block - block_cursor, if (maybe_inline_cas) |*cas| cas else null, profile);
        }
        const offset = @as(u64, span.first_block) * block_size;
        switch (span.payload) {
            .metadata => |block| {
                const write_start = monotonicMs();
                try file.writePositionalAll(io, block, offset);
                profile.metadata_write_ms +|= monotonicMs() -| write_start;
                profile.metadata_blocks +|= 1;
                profile.metadata_bytes_written +|= @intCast(block.len);
                if (maybe_inline_cas) |*inline_cas| {
                    const cas_start = monotonicMs();
                    try inline_cas.writeBytes(block);
                    profile.inline_cas_metadata_ms +|= monotonicMs() -| cas_start;
                }
            },
            .data => |run| {
                try writeDataSpan(
                    allocator,
                    io,
                    &file,
                    &source_files,
                    run,
                    offset,
                    source_buffer,
                    if (maybe_inline_cas) |*inline_cas| inline_cas else null,
                    profile,
                );
            },
        }
        block_cursor = span.first_block + span.block_count;
    }
    if (block_cursor < total_blocks) {
        try emitZeroGap(total_blocks - block_cursor, if (maybe_inline_cas) |*cas| cas else null, profile);
    }
    // Count the large, fixed emitter-owned buffers. Planner/hash-map and
    // source-file-cache allocations are intentionally excluded; native RSS is
    // measured separately by the scratch performance gate.
    profile.counted_emitter_buffers_bytes = profile.emit_map_bytes + source_buffer.len + profile.metadata_bytes_written +
        (if (cas_cache_root != null) cas_chunk_size else 0);
    const preload_result = if (maybe_inline_cas) |*inline_cas| blk: {
        const cas_finish_start = monotonicMs();
        const result = try inline_cas.finish();
        profile.inline_cas_finish_ms +|= monotonicMs() -| cas_finish_start;
        break :blk result;
    } else null;
    const close_start = monotonicMs();
    file.close(io);
    file_closed = true;
    profile.file_close_ms +|= monotonicMs() -| close_start;
    return .{
        .size = image_size,
        .preload_result = preload_result,
        .profile = profile.*,
    };
}

fn buildEmitSpans(
    allocator: std.mem.Allocator,
    total_blocks: u32,
    blocks: *BlockStore,
    data_blocks: *DataBlockStore,
) !EmitPlan {
    var spans = try std.ArrayList(EmitSpan).initCapacity(allocator, blocks.count() + data_blocks.items.len);
    errdefer spans.deinit(allocator);
    var metadata_it = blocks.iterator();
    while (metadata_it.next()) |entry| {
        if (entry.key_ptr.* >= total_blocks) return error.Ext4ImageTooSmall;
        try spans.append(allocator, .{
            .first_block = entry.key_ptr.*,
            .block_count = 1,
            .payload = .{ .metadata = entry.value_ptr.* },
        });
    }
    for (data_blocks.items) |run| {
        if (run.block_count == 0 or run.byte_len == 0) return error.BadExt4Tree;
        const end_block = std.math.add(u32, run.first_block, run.block_count) catch return error.Ext4ImageTooSmall;
        if (end_block > total_blocks) return error.Ext4ImageTooSmall;
        const max_bytes = try std.math.mul(u64, @as(u64, run.block_count), @as(u64, block_size));
        const full_prefix_bytes = try std.math.mul(u64, @as(u64, run.block_count - 1), @as(u64, block_size));
        const min_bytes = full_prefix_bytes + 1;
        if (run.byte_len < min_bytes or run.byte_len > max_bytes) return error.BadExt4Tree;
        const source_end = std.math.add(u64, run.source_offset, run.byte_len) catch return error.BadExt4Tree;
        if (source_end > run.source.size()) return error.BadExt4Tree;

        try spans.append(allocator, .{
            .first_block = run.first_block,
            .block_count = run.block_count,
            .payload = .{ .data = run },
        });
    }
    std.mem.sort(EmitSpan, spans.items, {}, struct {
        fn lessThan(_: void, a: EmitSpan, b: EmitSpan) bool {
            return a.first_block < b.first_block;
        }
    }.lessThan);
    var previous_end: u32 = 0;
    for (spans.items, 0..) |span, index| {
        if (index != 0 and span.first_block < previous_end) return error.BadExt4Tree;
        previous_end = span.first_block + span.block_count;
    }
    const allocated_bytes = @as(u64, spans.capacity) * @sizeOf(EmitSpan);
    return .{ .spans = try spans.toOwnedSlice(allocator), .allocated_bytes = allocated_bytes };
}

fn emitZeroGap(block_count: u32, inline_cas: ?*InlineRootfsCas, profile: *EmitProfile) !void {
    if (block_count == 0) return;
    const zero_start = monotonicMs();
    const byte_len = @as(u64, block_count) * block_size;
    profile.zero_blocks +|= block_count;
    profile.zero_bytes_skipped +|= byte_len;
    if (inline_cas) |cas| {
        const cas_start = monotonicMs();
        try cas.writeZeroBytes(@intCast(byte_len));
        profile.inline_cas_zero_ms +|= monotonicMs() -| cas_start;
    }
    profile.zero_ms +|= monotonicMs() -| zero_start;
}

fn writeDataSpan(
    allocator: std.mem.Allocator,
    io: Io,
    output: *Io.File,
    cache: *SourceFileCache,
    run: DataBlockRun,
    output_offset: u64,
    buffer: []u8,
    inline_cas: ?*InlineRootfsCas,
    profile: *EmitProfile,
) !void {
    var remaining_blocks = run.block_count;
    var remaining_payload = run.byte_len;
    var consumed_payload: u64 = 0;
    var write_offset = output_offset;
    const max_batch_blocks: u32 = @intCast(buffer.len / block_size);
    if (max_batch_blocks == 0) return error.BadExt4Tree;
    while (remaining_blocks != 0) {
        const batch_blocks = @min(remaining_blocks, max_batch_blocks);
        const batch_bytes: usize = @as(usize, batch_blocks) * block_size;
        const source_bytes: usize = @intCast(@min(remaining_payload, batch_bytes));
        const run_source_offset = std.math.add(u64, run.source_offset, consumed_payload) catch return error.BadExt4Tree;
        const read_start = monotonicMs();
        switch (run.source) {
            .memory => |data| {
                const start: usize = @intCast(run_source_offset);
                @memcpy(buffer[0..source_bytes], data[start .. start + source_bytes]);
            },
            .file => |slice| {
                const source_file = try cache.open(allocator, io, slice.path);
                const source_offset = try std.math.add(u64, slice.offset, run_source_offset);
                const n = try source_file.readPositionalAll(io, buffer[0..source_bytes], source_offset);
                if (n != source_bytes) return error.UnexpectedEndOfStream;
            },
        }
        profile.source_read_ms +|= monotonicMs() -| read_start;
        if (source_bytes < batch_bytes) @memset(buffer[source_bytes..batch_bytes], 0);
        const write_start = monotonicMs();
        try output.writePositionalAll(io, buffer[0..batch_bytes], write_offset);
        profile.data_write_ms +|= monotonicMs() -| write_start;
        profile.data_blocks +|= batch_blocks;
        profile.data_bytes_written +|= batch_bytes;
        if (inline_cas) |cas| {
            const cas_start = monotonicMs();
            try cas.writeBytes(buffer[0..batch_bytes]);
            profile.inline_cas_data_ms +|= monotonicMs() -| cas_start;
        }
        remaining_blocks -= batch_blocks;
        remaining_payload -= source_bytes;
        consumed_payload += source_bytes;
        write_offset += batch_bytes;
    }
    if (remaining_payload != 0) return error.BadExt4Tree;
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

fn pathIndex(planned: *const PlannedImage, path: []const u8) ?PathLookup {
    const inode_index = planned.path_index.get(path) orelse return null;
    return .{ .inode_index = inode_index };
}

fn parentPathIndex(planned: *const PlannedImage, path: []const u8) ?PathRef {
    const parent = parentPath(path);
    const inode_index = planned.path_index.get(parent) orelse return null;
    return .{ .path = parent, .inode_index = inode_index };
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
    return ext4.rootfs_ext4_inodes_per_block;
}

fn validateInodeCount(inode_count: u32) !void {
    if (inode_count < first_non_reserved_inode or inode_count % inodesPerBlock() != 0) return error.InvalidExt4InodeCount;
}

fn divCeilUsize(n: usize, d: usize) usize {
    return (n + d - 1) / d;
}

fn divCeilU32(n: u32, d: u32) u32 {
    return (n + d - 1) / d;
}

fn divCeilU64(n: u64, d: u64) u64 {
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

fn monotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
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

test "computed rootfs inode counts satisfy native writer packing" {
    const inode_count = ext4.computeImageInodes(100_001);
    try std.testing.expectEqual(@as(u64, 0), inode_count % ext4.rootfs_ext4_inodes_per_block);
    try validateInodeCount(@intCast(inode_count));
}

test "native ext4 writer inline CAS index matches rescanned image" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-native-ext4-inline-cas";
    const image_path = tmp ++ "/rootfs.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);

    const payload = try allocator.alloc(u8, 96 * 1024);
    defer allocator.free(payload);
    for (payload, 0..) |*byte, i| byte.* = @truncate((i * 31) ^ (i >> 3));

    const entries = [_]Entry{
        .{ .path = "etc/config", .kind = .{ .file = "inline-cas\n" }, .mode = 0o644 },
        .{ .path = "var/payload.bin", .kind = .{ .file = payload }, .mode = 0o600 },
    };
    const result = try emit(allocator, io, image_path, &entries, .{
        .image_size = min_image_size,
        .inode_count = 1024,
        .determinism = ext4.Determinism.fromDigest("sha256:test-native-ext4-inline-cas"),
        .cas_cache_root = cache_root,
        .cas_seal_workers = 2,
    });
    const inline_result = result.preload_result orelse return error.BadManifest;
    defer {
        allocator.free(inline_result.index_path);
        allocator.free(inline_result.index_digest);
        allocator.free(inline_result.rootfs_digest);
    }

    const rescan = try rootfs_cas.preloadPath(io, allocator, cache_root, image_path, rootfs_cas.default_chunk_size);
    defer {
        allocator.free(rescan.index_path);
        allocator.free(rescan.index_digest);
        allocator.free(rescan.rootfs_digest);
    }

    try std.testing.expectEqualStrings(rescan.index_digest, inline_result.index_digest);
    try std.testing.expectEqual(rescan.chunk_count, inline_result.chunk_count);
    try std.testing.expectEqual(rescan.zero_chunks, inline_result.zero_chunks);
    try std.testing.expectEqual(rescan.nonzero_chunks, inline_result.nonzero_chunks);
    try std.testing.expectEqual(@as(usize, 2), inline_result.seal_workers);
    try std.testing.expectEqual(@as(u64, @intCast(inline_result.nonzero_chunks)), inline_result.sealed_chunks);
    try std.testing.expect(inline_result.objects_written > 0);
}

test "sparse emit plan rejects metadata and data overlap deterministically" {
    const allocator = std.testing.allocator;
    var blocks = BlockStore.init(allocator);
    defer freeBlockStore(allocator, &blocks);
    try blocks.put(7, try zeroBlock(allocator));
    var payload = [_]u8{'x'};
    var data_blocks = DataBlockStore.empty;
    defer data_blocks.deinit(allocator);
    try data_blocks.append(allocator, .{
        .first_block = 7,
        .block_count = 1,
        .source = .{ .memory = &payload },
        .source_offset = 0,
        .byte_len = payload.len,
    });
    try std.testing.expectError(error.BadExt4Tree, buildEmitSpans(allocator, 16, &blocks, &data_blocks));
}

test "sparse data span zero pads its partial final block" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-native-ext4-sparse-data-span";
    const path = tmp ++ "/output";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    var output = try Io.Dir.cwd().createFile(io, path, .{ .read = true });
    defer output.close(io);

    const payload = try allocator.alloc(u8, block_size + 123);
    defer allocator.free(payload);
    for (payload, 0..) |*byte, index| byte.* = @truncate(index * 17 + 3);
    var source_files = SourceFileCache{};
    defer source_files.deinit(allocator, io);
    const buffer = try allocator.alloc(u8, 4 * block_size);
    defer allocator.free(buffer);
    var profile: EmitProfile = .{};
    try writeDataSpan(allocator, io, &output, &source_files, .{
        .first_block = 0,
        .block_count = 2,
        .source = .{ .memory = payload },
        .source_offset = 0,
        .byte_len = payload.len,
    }, 0, buffer, null, &profile);

    var actual: [2 * block_size]u8 = undefined;
    try std.testing.expectEqual(actual.len, try output.readPositionalAll(io, &actual, 0));
    try std.testing.expectEqualSlices(u8, payload, actual[0..payload.len]);
    try std.testing.expect(std.mem.allEqual(u8, actual[payload.len..], 0));
}

test "sparse zero gap accounts a large logical tail without a dense map" {
    var profile: EmitProfile = .{};
    const blocks: u32 = 4 * 1024 * 1024;
    try emitZeroGap(blocks, null, &profile);
    try std.testing.expectEqual(@as(u64, blocks), profile.zero_blocks);
    try std.testing.expectEqual(@as(u64, blocks) * block_size, profile.zero_bytes_skipped);
    try std.testing.expectEqual(@as(u64, 0), profile.emit_map_bytes);
}

test "indexed directory children match scanned directory bytes" {
    const allocator = std.testing.allocator;
    const entries = [_]Entry{
        .{ .path = "alpha/target", .kind = .{ .file = "target\n" } },
        .{ .path = "beta/target-hard", .kind = .{ .hardlink = "alpha/target" } },
        .{ .path = "alpha/nested/leaf", .kind = .{ .file = "leaf\n" } },
        .{ .path = "empty", .kind = .directory },
        .{ .path = "links/tool", .kind = .{ .symlink = "../alpha/target" } },
        .{ .path = "dev/nullish", .kind = .{ .device = .{ .kind = .char, .major = 1, .minor = 3 } } },
    };

    var planned = try planImage(allocator, &entries, 1024);
    defer planned.deinit(allocator);
    var directory_children = try DirectoryChildIndex.build(allocator, &planned);
    defer directory_children.deinit(allocator);

    for (planned.inodes.items, 0..) |inode, inode_index| {
        if (inode.kind != .directory) continue;
        const scanned = try directoryBytes(allocator, &planned, inode);
        defer allocator.free(scanned);
        const indexed = try directoryBytesIndexed(allocator, &planned, inode, inode_index, &directory_children);
        defer allocator.free(indexed);
        try std.testing.expectEqualSlices(u8, scanned, indexed);
    }
}

test "planner rejects children below non-directory parents" {
    const allocator = std.testing.allocator;
    const entries = [_]Entry{
        .{ .path = "alpha", .kind = .{ .file = "not a directory\n" } },
        .{ .path = "alpha/child", .kind = .{ .file = "child\n" } },
    };

    try std.testing.expectError(error.ParentNotDirectory, planImage(allocator, &entries, 1024));
}

test "source data runs split across block group metadata gaps" {
    const allocator = std.testing.allocator;
    const inode_count: u32 = 1024;
    const total_blocks: u32 = blocks_per_group * 2;
    const source_size: u64 = @as(u64, blocks_per_group + 2) * block_size + 123;
    const source_path: []u8 = @constCast("unused-large-source");
    const entries = [_]Entry{.{
        .path = "large.bin",
        .kind = .{ .file_source = .{ .file = .{
            .path = source_path,
            .offset = 0,
            .size = source_size,
        } } },
    }};

    var planned = try planImage(allocator, &entries, inode_count);
    defer planned.deinit(allocator);
    var blocks = BlockStore.init(allocator);
    defer freeBlockStore(allocator, &blocks);
    var data_blocks = DataBlockStore.empty;
    defer data_blocks.deinit(allocator);

    const layout = try assignBlocks(allocator, &planned, total_blocks, inode_count, &blocks, &data_blocks);
    defer allocator.free(layout.groups);
    try std.testing.expect(data_blocks.items.len >= 2);
    var saw_gap = false;
    for (data_blocks.items[1..], 1..) |run, i| {
        const previous = data_blocks.items[i - 1];
        if (previous.first_block + previous.block_count != run.first_block) saw_gap = true;
    }
    try std.testing.expect(saw_gap);

    const emit_plan = try buildEmitSpans(allocator, total_blocks, &blocks, &data_blocks);
    const emit_spans = emit_plan.spans;
    defer allocator.free(emit_spans);
    var large_inode: ?InodePlan = null;
    for (planned.inodes.items) |inode| {
        if (inode.kind == .file and inode.file_source != null) {
            large_inode = inode;
            break;
        }
    }
    const inode = large_inode orelse return error.BadExt4Tree;
    const last_block = inode.data_blocks[inode.data_blocks.len - 1];
    var last_payload_len: ?u64 = null;
    for (emit_spans) |span| {
        if (last_block < span.first_block or last_block >= span.first_block + span.block_count) continue;
        last_payload_len = switch (span.payload) {
            .data => |run| run.byte_len - @as(u64, span.block_count - 1) * block_size,
            .metadata => return error.BadExt4Tree,
        };
        break;
    }
    try std.testing.expectEqual(@as(?u64, 123), last_payload_len);
}

fn fuzzNativeExt4PlannerAndMetadataEmitter(_: void, s: *std.testing.Smith) !void {
    // The native materializer receives trees derived from attacker-influenced
    // layer metadata. Exercise the same public entry shape through planning,
    // data block assignment, and metadata emission without depending on fsck.
    const allocator = std.testing.allocator;

    var inline_data: [8192]u8 = undefined;
    const inline_len = s.slice(&inline_data);

    var source_data: [96 * 1024]u8 = undefined;
    @memset(&source_data, 0xa5);
    const source_len = 1 + (@as(usize, s.value(u32)) % source_data.len);

    var link_target: [96]u8 = undefined;
    for (&link_target, 0..) |*byte, i| byte.* = 'a' + @as(u8, @intCast(i % 26));
    _ = s.slice(&link_target);
    const link_len = 1 + @as(usize, s.value(u8) % link_target.len);

    var cap = [_]u8{ 1, 0, 0, 2 } ++ [_]u8{0} ** 16;
    const cap_fuzz_len = @min(s.slice(&cap), cap.len);
    if (cap_fuzz_len < cap.len) @memset(cap[cap_fuzz_len..], 0);
    cap[0..4].* = .{ 1, 0, 0, 2 };
    const attrs = [_]xattrs_mod.Attribute{.{ .name = xattrs_mod.security_capability_name, .value = cap[0..] }};

    const entries = [_]Entry{
        .{
            .path = "etc/config",
            .kind = .{ .file = inline_data[0..inline_len] },
            .mode = 0o600 | @as(u16, s.value(u8) & 0o77),
            .uid = s.value(u16),
            .gid = s.value(u16),
            .xattrs = &attrs,
        },
        .{
            .path = "bin/tool",
            .kind = .{ .file_source = .{ .memory = source_data[0..source_len] } },
            .mode = 0o700 | @as(u16, s.value(u8) & 0o77),
            .uid = s.value(u16),
            .gid = s.value(u16),
        },
        .{ .path = "bin/tool-hard", .kind = .{ .hardlink = "bin/tool" } },
        .{ .path = "run/tool-link", .kind = .{ .symlink = link_target[0..link_len] } },
        .{
            .path = "dev/nullish",
            .kind = .{ .device = .{
                .kind = if ((s.value(u8) & 1) == 0) .char else .block,
                .major = s.value(u8),
                .minor = s.value(u16),
            } },
            .mode = 0o600 | @as(u16, s.value(u8) & 0o77),
        },
        .{ .path = "run/input", .kind = .fifo, .mode = 0o600 | @as(u16, s.value(u8) & 0o77) },
        .{ .path = "run/socket", .kind = .socket, .mode = 0o600 | @as(u16, s.value(u8) & 0o77) },
    };

    const inode_count: u32 = 1024 + @as(u32, s.value(u8) % 4) * 1024;
    const total_blocks: u32 = min_image_size / block_size;

    var planned = try planImage(allocator, &entries, inode_count);
    defer planned.deinit(allocator);

    var blocks = BlockStore.init(allocator);
    defer freeBlockStore(allocator, &blocks);
    var data_blocks = DataBlockStore.empty;
    defer data_blocks.deinit(allocator);

    const layout = try assignBlocks(allocator, &planned, total_blocks, inode_count, &blocks, &data_blocks);
    defer allocator.free(layout.groups);
    try writeMetadataBlocks(allocator, &planned, layout, .{
        .image_size = min_image_size,
        .inode_count = inode_count,
        .determinism = ext4.Determinism.fromDigest("sha256:fuzz-native-ext4-writer"),
    }, &blocks);

    var block_keys = blocks.keyIterator();
    while (block_keys.next()) |block| {
        try std.testing.expect(block.* < total_blocks);
    }
    for (data_blocks.items) |run| {
        try std.testing.expect(run.first_block < total_blocks);
        try std.testing.expect(run.block_count > 0);
        try std.testing.expect(run.first_block + run.block_count <= total_blocks);
        try std.testing.expect(run.source_offset + run.byte_len <= run.source.size());
    }
}

test "fuzz native ext4 writer planner and metadata emitter" {
    try std.testing.fuzz({}, fuzzNativeExt4PlannerAndMetadataEmitter, .{});
}
