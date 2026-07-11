//! One-level chunk-mapped disk backend for writable runtime disks.
//!
//! Reads are resolved through an in-memory per-chunk source map. Writes land in
//! a sparse overlay fd and flip the affected chunks to the dirty overlay
//! source. A successful snapshot advances the logical baseline without moving
//! live reads away from their existing base, overlay, or CAS storage.

const std = @import("std");
const builtin = @import("builtin");
const block_source = @import("block_source.zig");
const chunk_sealer = @import("chunk_sealer.zig");
const disk_index = @import("disk_index.zig");
const fd_util = @import("fd.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const runtime_disk_fork = @import("runtime_disk_fork.zig");
const spore = @import("spore.zig");

extern "c" fn mkstemp(template: [*:0]u8) c_int;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn fclonefileat(src_fd: c_int, dst_dir_fd: c_int, dst: [*:0]const u8, flags: c_int) c_int;

/// Runtime overlays and transient clone names deliberately share one host
/// filesystem so APFS `fclonefileat` and Linux `FICLONE` can stay native.
pub const runtime_overlay_dir = "/tmp";

pub const Error = error{
    BadClusterSize,
    BadDiskSize,
    OutOfRange,
    ReadOnly,
    ShortRead,
    ShortWrite,
    ResizeFailed,
    FlushFailed,
    FastForkUnavailable,
} || chunk_sealer.Error || rootfs_cas.SourceError || runtime_disk_fork.Error || spore.Error || block_source.Error || std.mem.Allocator.Error;

const Source = enum(u8) {
    base,
    overlay,
    overlay_clean,
    zero,
    zero_dirty,
    cas,
};

fn sourceIsDirty(source: Source) bool {
    return source == .overlay or source == .zero_dirty;
}

pub const ForkCloneMethod = runtime_disk_fork.CloneMethod;

pub const ForkOptions = struct {
    force_copy: bool = false,
    quiesced: bool = false,
};

pub const ExportForkOptions = struct {
    allow_copy: bool = false,
    force_copy: bool = false,
    quiesced: bool = false,
};

pub const SnapshotStats = struct {
    full_scan: bool = false,
    sealed_candidate_chunks: usize = 0,
    parent_chunks_reused: usize = 0,
    parent_objects_linked: usize = 0,
    parent_objects_reused: usize = 0,
    parent_objects_copied: usize = 0,
    parent_object_bytes: u64 = 0,
    work: chunk_sealer.WorkStats = .{},
};

const LazyCasTraceStats = struct {
    runtime_open_ns: u64 = 0,
    index_attach_ns: u64 = 0,
    index_payload_bytes: u64 = 0,
    total_chunks: u64 = 0,
    cas_chunks_initial: u64 = 0,
    fault_attempts: u64 = 0,
    fault_errors: u64 = 0,
    unique_chunks: u64 = 0,
    fault_bytes: u64 = 0,
    fault_total_ns: u64 = 0,
    object_prepare_ns: u64 = 0,
    object_read_ns: u64 = 0,
    object_verify_ns: u64 = 0,
    sparse_write_ns: u64 = 0,
};

const LazyCasTrace = struct {
    fd: std.c.fd_t,
    stats: LazyCasTraceStats,
};

pub const ForkedDisk = struct {
    disk: ChunkMappedDisk,
    clone_method: ForkCloneMethod,

    pub fn deinit(self: *ForkedDisk) void {
        if (self.disk.overlay_fd) |fd| {
            _ = std.c.close(fd);
            self.disk.overlay_fd = null;
        }
        self.disk.deinit();
        self.* = undefined;
    }
};

pub const PreparedSnapshotRoot = struct {
    allocator: std.mem.Allocator,
    root: ?[]const u8,

    pub fn deinit(self: *PreparedSnapshotRoot) void {
        if (self.root) |root| self.allocator.free(root);
        self.* = undefined;
    }
};

pub const ChunkMappedDisk = struct {
    allocator: std.mem.Allocator,
    base: block_source.FileBlockSource,
    overlay_fd: ?std.c.fd_t,
    overlay_dir: ?[]const u8,
    size: u64,
    chunk_size: u64,
    sources: []Source,
    cas_root: ?[]const u8 = null,
    cas_digests: []?[]const u8 = &.{},
    parent_root: ?[]const u8 = null,
    parent_digests: []?[]const u8 = &.{},
    snapshot_published: bool = false,
    lazy_cas_trace: ?LazyCasTrace = null,

    pub fn initReadOnly(
        allocator: std.mem.Allocator,
        base: block_source.FileBlockSource,
        size: u64,
        chunk_size: u64,
    ) Error!ChunkMappedDisk {
        return init(allocator, base, null, null, size, chunk_size);
    }

    pub fn initWritable(
        allocator: std.mem.Allocator,
        base: block_source.FileBlockSource,
        overlay_fd: std.c.fd_t,
        size: u64,
        chunk_size: u64,
    ) Error!ChunkMappedDisk {
        return initWritableAt(allocator, base, overlay_fd, runtime_overlay_dir, size, chunk_size);
    }

    pub fn initWritableAt(
        allocator: std.mem.Allocator,
        base: block_source.FileBlockSource,
        overlay_fd: std.c.fd_t,
        overlay_dir: []const u8,
        size: u64,
        chunk_size: u64,
    ) Error!ChunkMappedDisk {
        return init(allocator, base, overlay_fd, overlay_dir, size, chunk_size);
    }

    fn init(
        allocator: std.mem.Allocator,
        base: block_source.FileBlockSource,
        overlay_fd: ?std.c.fd_t,
        overlay_dir: ?[]const u8,
        size: u64,
        chunk_size: u64,
    ) Error!ChunkMappedDisk {
        if ((overlay_fd == null) != (overlay_dir == null)) return error.BadOverlay;
        if (size == 0) return error.BadDiskSize;
        if (base.capacityBytes() < size) return error.BadDiskSize;
        if (chunk_size == 0 or chunk_size % 512 != 0 or chunk_size > std.math.maxInt(usize)) {
            return error.BadClusterSize;
        }
        const chunk_count = try computeChunkCount(size, chunk_size);
        if (chunk_count > std.math.maxInt(usize)) return error.BadDiskSize;
        if (overlay_fd) |fd| {
            const overlay_size = std.math.cast(std.c.off_t, size) orelse return error.BadDiskSize;
            if (std.c.ftruncate(fd, overlay_size) != 0) return error.ResizeFailed;
        }
        const owned_overlay_dir = if (overlay_dir) |dir| try allocator.dupe(u8, dir) else null;
        errdefer if (owned_overlay_dir) |dir| allocator.free(dir);
        const sources = try allocator.alloc(Source, @intCast(chunk_count));
        @memset(sources, .base);
        return .{
            .allocator = allocator,
            .base = base,
            .overlay_fd = overlay_fd,
            .overlay_dir = owned_overlay_dir,
            .size = size,
            .chunk_size = chunk_size,
            .sources = sources,
        };
    }

    pub fn deinit(self: *ChunkMappedDisk) void {
        self.appendLazyCasTrace();
        self.deinitCasState();
        self.deinitParentIndex();
        if (self.overlay_dir) |dir| self.allocator.free(dir);
        self.allocator.free(self.sources);
        self.* = undefined;
    }

    pub fn capacityBytes(self: ChunkMappedDisk) u64 {
        return self.size;
    }

    pub fn dirtyChunkCount(self: ChunkMappedDisk) usize {
        var count: usize = 0;
        for (self.sources) |source| {
            if (sourceIsDirty(source)) count += 1;
        }
        return count;
    }

    pub fn dirtyClusterCount(self: ChunkMappedDisk) usize {
        return self.dirtyChunkCount();
    }

    pub fn hasPublishedSnapshot(self: ChunkMappedDisk) bool {
        return self.snapshot_published;
    }

    pub fn chunkSize(self: ChunkMappedDisk) u64 {
        return self.chunk_size;
    }

    pub fn clusterSize(self: ChunkMappedDisk) u64 {
        return self.chunkSize();
    }

    pub fn chunkCount(self: ChunkMappedDisk) usize {
        return self.sources.len;
    }

    pub fn clusterCount(self: ChunkMappedDisk) usize {
        return self.chunkCount();
    }

    pub fn setLazyCasRuntimeOpenNs(self: *ChunkMappedDisk, elapsed_ns: u64) void {
        if (self.lazy_cas_trace) |*trace| trace.stats.runtime_open_ns = elapsed_ns;
    }

    pub fn grow(self: *ChunkMappedDisk, new_size: u64) Error!void {
        const overlay_fd = self.overlay_fd orelse return error.ReadOnly;
        if (new_size < self.size) return error.BadDiskSize;
        if (new_size == self.size) return;
        if (self.size % self.chunk_size != 0) return error.BadDiskSize;
        if (self.base.capacityBytes() < new_size) return error.BadDiskSize;

        const new_chunk_count = try computeChunkCount(new_size, self.chunk_size);
        if (new_chunk_count > std.math.maxInt(usize)) return error.BadDiskSize;
        const old_chunk_count = self.sources.len;
        const new_sources = try self.allocator.alloc(Source, @intCast(new_chunk_count));
        @memcpy(new_sources[0..old_chunk_count], self.sources);
        @memset(new_sources[old_chunk_count..], .zero_dirty);
        errdefer self.allocator.free(new_sources);

        var new_cas_digests: []?[]const u8 = &.{};
        if (self.cas_digests.len != 0) {
            const digests = try self.allocator.alloc(?[]const u8, @intCast(new_chunk_count));
            @memset(digests, null);
            errdefer freeOptionalDigests(self.allocator, digests);
            for (self.cas_digests, 0..) |maybe_digest, i| {
                if (maybe_digest) |digest| digests[i] = try self.allocator.dupe(u8, digest);
            }
            new_cas_digests = digests;
        }
        errdefer if (self.cas_digests.len != 0) freeOptionalDigests(self.allocator, new_cas_digests);

        var new_parent_digests: []?[]const u8 = &.{};
        if (self.parent_digests.len != 0) {
            const digests = try self.allocator.alloc(?[]const u8, @intCast(new_chunk_count));
            @memset(digests, null);
            errdefer freeOptionalDigests(self.allocator, digests);
            for (self.parent_digests, 0..) |maybe_digest, i| {
                if (maybe_digest) |digest| digests[i] = try self.allocator.dupe(u8, digest);
            }
            new_parent_digests = digests;
        }
        errdefer if (self.parent_digests.len != 0) freeOptionalDigests(self.allocator, new_parent_digests);

        const overlay_size = std.math.cast(std.c.off_t, new_size) orelse return error.BadDiskSize;
        if (std.c.ftruncate(overlay_fd, overlay_size) != 0) return error.ResizeFailed;

        self.allocator.free(self.sources);
        if (self.cas_digests.len != 0) freeOptionalDigests(self.allocator, self.cas_digests);
        if (self.parent_digests.len != 0) freeOptionalDigests(self.allocator, self.parent_digests);
        self.sources = new_sources;
        self.cas_digests = new_cas_digests;
        self.parent_digests = new_parent_digests;
        self.size = new_size;
    }

    pub fn chunkLen(self: ChunkMappedDisk, chunk_index: usize) Error!usize {
        if (chunk_index >= self.sources.len) return error.OutOfRange;
        const start = std.math.mul(u64, chunk_index, self.chunk_size) catch return error.OutOfRange;
        const end = @min(std.math.add(u64, start, self.chunk_size) catch self.size, self.size);
        return std.math.cast(usize, end - start) orelse return error.BadClusterSize;
    }

    pub fn clusterLen(self: ChunkMappedDisk, chunk_index: usize) Error!usize {
        return self.chunkLen(chunk_index);
    }

    pub fn isDirtyChunk(self: ChunkMappedDisk, chunk_index: usize) Error!bool {
        if (chunk_index >= self.sources.len) return error.OutOfRange;
        return sourceIsDirty(self.sources[chunk_index]);
    }

    pub fn isDirtyCluster(self: ChunkMappedDisk, chunk_index: usize) Error!bool {
        return self.isDirtyChunk(chunk_index);
    }

    pub fn markZeroChunk(self: *ChunkMappedDisk, chunk_index: usize) Error!void {
        if (chunk_index >= self.sources.len) return error.OutOfRange;
        if (self.sources[chunk_index] == .zero or self.sources[chunk_index] == .zero_dirty) return;
        self.clearCasDigest(chunk_index);
        self.sources[chunk_index] = .zero_dirty;
    }

    pub fn readChunk(self: *ChunkMappedDisk, chunk_index: usize, buf: []u8) Error!void {
        const len = try self.chunkLen(chunk_index);
        if (buf.len != len) return error.OutOfRange;
        const offset = std.math.mul(u64, chunk_index, self.chunk_size) catch return error.OutOfRange;
        try self.readAt(buf, offset);
    }

    pub fn readCluster(self: *ChunkMappedDisk, chunk_index: usize, buf: []u8) Error!void {
        try self.readChunk(chunk_index, buf);
    }

    /// Resolves every lazy CAS source in a read range before caller-visible
    /// bytes are written. Successfully faulted chunks may remain promoted when
    /// a later chunk fails; that internal progress is safe to reuse on retry.
    pub fn prefaultCasRange(self: *ChunkMappedDisk, len: usize, offset: u64) Error!void {
        try self.checkRange(len, offset);
        var cursor: usize = 0;
        while (cursor < len) {
            const absolute = offset + cursor;
            const span = try self.spanFor(absolute, len - cursor);
            if (self.sources[span.chunk_index] == .cas) try self.faultCasChunk(span.chunk_index);
            cursor += span.len;
        }
    }

    pub fn readAt(self: *ChunkMappedDisk, buf: []u8, offset: u64) Error!void {
        try self.prefaultCasRange(buf.len, offset);
        var cursor: usize = 0;
        while (cursor < buf.len) {
            const absolute = offset + cursor;
            const span = try self.spanFor(absolute, buf.len - cursor);
            const target = buf[cursor..][0..span.len];
            switch (self.sources[span.chunk_index]) {
                .base => try self.base.readAt(target, absolute),
                .overlay, .overlay_clean => try readExact(self.overlay_fd orelse return error.ShortRead, target, absolute),
                .zero, .zero_dirty => @memset(target, 0),
                .cas => {
                    try self.faultCasChunk(span.chunk_index);
                    try self.base.readAt(target, absolute);
                },
            }
            cursor += span.len;
        }
    }

    pub fn writeAt(self: *ChunkMappedDisk, buf: []const u8, offset: u64) Error!void {
        const overlay_fd = self.overlay_fd orelse return error.ReadOnly;
        try self.checkRange(buf.len, offset);
        var cursor: usize = 0;
        while (cursor < buf.len) {
            const absolute = offset + cursor;
            const span = try self.spanFor(absolute, buf.len - cursor);
            const full_chunk_write = span.chunk_offset == 0 and span.len == try self.chunkLen(span.chunk_index);
            const source = self.sources[span.chunk_index];
            if (source != .overlay and source != .overlay_clean and !full_chunk_write) {
                try self.seedChunk(span.chunk_index, overlay_fd);
            }
            // Overlay-backed clean bytes are immediately visible through this
            // fd, so classify them dirty before a short write can expose a
            // changed prefix while leaving the old parent digest reusable.
            if (source == .overlay_clean) self.sources[span.chunk_index] = .overlay;
            try writeExact(overlay_fd, buf[cursor..][0..span.len], absolute);
            self.clearCasDigest(span.chunk_index);
            self.sources[span.chunk_index] = .overlay;
            cursor += span.len;
        }
    }

    pub fn flush(self: *ChunkMappedDisk) Error!void {
        if (self.overlay_fd) |fd| {
            if (std.c.fsync(fd) != 0) return error.FlushFailed;
        }
    }

    /// Forks the mutable disk head. The caller must have paused the VM and
    /// proven there are no in-flight virtio-blk requests before cloning the
    /// source map and overlay fd; this primitive does not drain device queues.
    pub fn fork(self: *ChunkMappedDisk, options: ForkOptions) Error!ForkedDisk {
        std.debug.assert(options.quiesced);
        const parent_fd = self.overlay_fd orelse return error.ReadOnly;
        const child_sources = try self.allocator.dupe(Source, self.sources);
        errdefer self.allocator.free(child_sources);
        const child_cas = try self.cloneCasState();
        errdefer child_cas.deinit(self.allocator);
        const child_parent = try self.cloneParentIndex();
        errdefer child_parent.deinit(self.allocator);
        const child_overlay_dir = try self.allocator.dupe(u8, self.overlay_dir orelse return error.ReadOnly);
        errdefer self.allocator.free(child_overlay_dir);

        const cloned = try self.cloneOverlay(parent_fd, .{ .allow_copy = true, .force_copy = options.force_copy });
        errdefer _ = std.c.close(cloned.fd);
        return .{
            .disk = .{
                .allocator = self.allocator,
                .base = self.base,
                .overlay_fd = cloned.fd,
                .overlay_dir = child_overlay_dir,
                .size = self.size,
                .chunk_size = self.chunk_size,
                .sources = child_sources,
                .cas_root = child_cas.root,
                .cas_digests = child_cas.digests,
                .parent_root = child_parent.root,
                .parent_digests = child_parent.digests,
                .snapshot_published = self.snapshot_published,
            },
            .clone_method = cloned.method,
        };
    }

    /// Exports the process-independent portion of a live disk head. The
    /// caller owns quiescence; this method clones only the overlay and records
    /// two dense override maps, avoiding per-child digest-table duplication.
    pub fn exportForkHead(
        self: *ChunkMappedDisk,
        baseline: runtime_disk_fork.Baseline,
        options: ExportForkOptions,
    ) Error!runtime_disk_fork.Head {
        std.debug.assert(options.quiesced);
        const prepare_start_ns = monotonicNs() catch 0;
        const parent_fd = self.overlay_fd orelse return error.ReadOnly;
        spore.validateDiskDigest(baseline.identity) catch return error.BadManifest;
        const bitmap_len = try runtime_disk_fork.bitmapLen(@intCast(self.chunkCount()));
        const overlay_chunks = try self.allocator.alloc(u8, bitmap_len);
        errdefer self.allocator.free(overlay_chunks);
        @memset(overlay_chunks, 0);
        const zero_chunks = try self.allocator.alloc(u8, bitmap_len);
        errdefer self.allocator.free(zero_chunks);
        @memset(zero_chunks, 0);
        for (self.sources, 0..) |source, chunk_index| switch (source) {
            .overlay, .overlay_clean => runtime_disk_fork.bitmapSet(overlay_chunks, chunk_index),
            .zero, .zero_dirty => runtime_disk_fork.bitmapSet(zero_chunks, chunk_index),
            .base, .cas => {},
        };

        const identity = try self.allocator.dupe(u8, baseline.identity);
        errdefer self.allocator.free(identity);
        const cloned = try self.cloneOverlay(parent_fd, .{
            .allow_copy = options.allow_copy,
            .force_copy = options.force_copy,
        });
        errdefer _ = std.c.close(cloned.fd);
        return .{
            .descriptor = .{
                .allocator = self.allocator,
                .baseline = .{ .kind = baseline.kind, .identity = identity },
                .clone_method = cloned.method,
                .logical_size = self.size,
                .chunk_size = self.chunk_size,
                .chunk_count = @intCast(self.chunkCount()),
                .overlay_chunks = overlay_chunks,
                .zero_chunks = zero_chunks,
            },
            .overlay_fd = cloned.fd,
            .stats = .{
                .prepare_ns = elapsedSince(prepare_start_ns),
                .copied_bytes = cloned.copied_bytes,
            },
        };
    }

    /// Applies a validated runtime descriptor to a disk freshly opened from
    /// the descriptor-bound immutable baseline. Returns the replaced overlay
    /// fd so the owning `RuntimeDisk` can complete the ownership transfer.
    pub fn applyForkDescriptor(
        self: *ChunkMappedDisk,
        descriptor: runtime_disk_fork.Descriptor,
        overlay_fd: std.c.fd_t,
    ) Error!std.c.fd_t {
        try descriptor.validate();
        try runtime_disk_fork.validateOverlayFd(overlay_fd, descriptor.logical_size);
        const old_overlay_fd = self.overlay_fd orelse return error.ReadOnly;
        if (descriptor.logical_size != self.size or descriptor.chunk_size != self.chunk_size or descriptor.chunk_count != self.chunkCount()) return error.BadManifest;
        for (self.sources) |source| {
            if (source == .overlay or source == .overlay_clean or source == .zero_dirty) return error.BadManifest;
        }
        for (self.sources, 0..) |*source, chunk_index| {
            if (descriptor.overlay(chunk_index)) {
                source.* = .overlay;
                self.clearCasDigest(chunk_index);
            } else if (descriptor.zero(chunk_index)) {
                source.* = .zero_dirty;
                self.clearCasDigest(chunk_index);
            }
        }
        self.overlay_fd = overlay_fd;
        return old_overlay_fd;
    }

    pub fn attachCasIndex(self: *ChunkMappedDisk, cache_root: []const u8, index: disk_index.DiskIndex) Error!void {
        return self.attachCasIndexTraced(cache_root, index, null);
    }

    pub fn attachCasIndexTraced(
        self: *ChunkMappedDisk,
        cache_root: []const u8,
        index: disk_index.DiskIndex,
        trace_fd: ?std.c.fd_t,
    ) Error!void {
        if (self.cas_root != null or self.cas_digests.len != 0 or self.parent_digests.len != 0) return error.BadManifest;
        if (index.logical_size != self.size or index.chunk_size != self.chunk_size) return error.BadManifest;
        try disk_index.validateDiskIndex(index, .{
            .logical_size = self.size,
            .chunk_size = self.chunk_size,
            .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
            .object_namespace = spore.rootfs_storage_object_namespace,
        });

        if (trace_fd) |fd| {
            self.lazy_cas_trace = .{
                .fd = fd,
                .stats = .{ .total_chunks = self.sources.len },
            };
        }
        errdefer self.lazy_cas_trace = null;
        const attach_start_ns = if (trace_fd != null) monotonicNs() catch 0 else 0;
        const next = try self.indexStateFrom(cache_root, index);
        self.installIndexState(next);
        if (self.lazy_cas_trace) |*trace| {
            trace.stats.index_attach_ns = elapsedSince(attach_start_ns);
            trace.stats.cas_chunks_initial = @intCast(index.chunks.len);
            trace.stats.index_payload_bytes = indexStatePayloadBytes(self.sources.len, cache_root, index);
        }
    }

    /// Attaches a verified index as snapshot baseline metadata while keeping
    /// reads on the already-open flat rootfs artifact.
    pub fn attachParentIndex(self: *ChunkMappedDisk, cache_root: []const u8, index: disk_index.DiskIndex) Error!void {
        if (self.parent_root != null or self.parent_digests.len != 0) return error.BadManifest;
        if (index.logical_size != self.size or index.chunk_size != self.chunk_size) return error.BadManifest;
        try disk_index.validateDiskIndex(index, .{
            .logical_size = self.size,
            .chunk_size = self.chunk_size,
            .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
            .object_namespace = spore.rootfs_storage_object_namespace,
        });
        const parent = try self.parentStateFrom(cache_root, index);
        self.parent_root = parent.root;
        self.parent_digests = parent.digests;
    }

    /// Preallocates a stable snapshot authority before an atomic directory
    /// rename. `commitSnapshotRoot` transfers this allocation without a
    /// fallible operation after the rename succeeds.
    pub fn prepareSnapshotRoot(self: *ChunkMappedDisk, root: []const u8) Error!PreparedSnapshotRoot {
        return .{ .allocator = self.allocator, .root = try self.allocator.dupe(u8, root) };
    }

    /// Rebinds a just-published snapshot from its temporary directory to the
    /// final atomic-publish path. A fresh clean rootfs may not publish a disk
    /// index; in that case there is no baseline to rebind.
    pub fn commitSnapshotRoot(self: *ChunkMappedDisk, expected_root: []const u8, prepared: *PreparedSnapshotRoot) Error!void {
        if (!self.snapshot_published) return;
        const current = self.parent_root orelse return error.BadManifest;
        if (!std.mem.eql(u8, current, expected_root)) return error.BadManifest;
        const next = prepared.root orelse return error.BadManifest;
        prepared.root = null;
        self.parent_root = next;
        self.allocator.free(current);
    }

    fn indexStateFrom(self: *ChunkMappedDisk, cache_root: []const u8, index: disk_index.DiskIndex) Error!IndexState {
        const next_sources = try self.allocator.alloc(Source, self.sources.len);
        errdefer self.allocator.free(next_sources);
        @memset(next_sources, .zero);

        const next_digests = try self.allocator.alloc(?[]const u8, self.sources.len);
        @memset(next_digests, null);
        errdefer freeOptionalDigests(self.allocator, next_digests);

        const next_parent_digests = try self.allocator.alloc(?[]const u8, self.sources.len);
        @memset(next_parent_digests, null);
        errdefer freeOptionalDigests(self.allocator, next_parent_digests);

        const next_parent_root = try self.allocator.dupe(u8, cache_root);
        errdefer self.allocator.free(next_parent_root);

        const next_root = try self.allocator.dupe(u8, cache_root);
        errdefer self.allocator.free(next_root);

        for (index.chunks) |entry| {
            if (entry.logical_chunk >= self.sources.len) return error.BadManifest;
            const chunk_index: usize = @intCast(entry.logical_chunk);
            next_digests[chunk_index] = try self.allocator.dupe(u8, entry.digest);
            next_parent_digests[chunk_index] = try self.allocator.dupe(u8, entry.digest);
            next_sources[chunk_index] = .cas;
        }
        for (index.zero_chunks) |logical_chunk| {
            if (logical_chunk >= self.sources.len) return error.BadManifest;
        }

        return .{
            .sources = next_sources,
            .cas_root = next_root,
            .cas_digests = next_digests,
            .parent_root = next_parent_root,
            .parent_digests = next_parent_digests,
        };
    }

    fn installIndexState(self: *ChunkMappedDisk, next: IndexState) void {
        const old_sources = self.sources;
        const old_cas_root = self.cas_root;
        const old_cas_digests = self.cas_digests;
        const old_parent_root = self.parent_root;
        const old_parent_digests = self.parent_digests;

        self.sources = next.sources;
        self.cas_root = next.cas_root;
        self.cas_digests = next.cas_digests;
        self.parent_root = next.parent_root;
        self.parent_digests = next.parent_digests;

        self.allocator.free(old_sources);
        if (old_cas_root) |root| self.allocator.free(root);
        if (old_cas_digests.len != 0) freeOptionalDigests(self.allocator, old_cas_digests);
        if (old_parent_root) |root| self.allocator.free(root);
        if (old_parent_digests.len != 0) freeOptionalDigests(self.allocator, old_parent_digests);
    }

    /// Publishes a durable disk index for the current mutable disk head. The
    /// caller must have paused the VM and proven there are no in-flight
    /// virtio-blk requests; this method scans the mutable source map/overlay and
    /// intentionally fails fast in debug builds if called without that proof.
    pub fn snapshotIndex(self: *ChunkMappedDisk, dir: []const u8, device: spore.RootfsDevice, quiesced: bool) Error!spore.Disk {
        return self.snapshotIndexWithStats(dir, device, quiesced, null);
    }

    pub fn snapshotIndexWithStats(
        self: *ChunkMappedDisk,
        dir: []const u8,
        device: spore.RootfsDevice,
        quiesced: bool,
        stats_out: ?*SnapshotStats,
    ) Error!spore.Disk {
        std.debug.assert(quiesced);
        var chunks: std.ArrayList(disk_index.DiskIndexChunk) = .empty;
        errdefer {
            for (chunks.items) |entry| self.allocator.free(entry.digest);
            chunks.deinit(self.allocator);
        }
        var zero_chunks: std.ArrayList(u64) = .empty;
        errdefer zero_chunks.deinit(self.allocator);

        const object_dir = try objectDir(self.allocator, dir);
        defer self.allocator.free(object_dir);
        try chunk_sealer.ensureDirPath(self.allocator, object_dir);

        const max_chunk_size = std.math.cast(usize, self.chunk_size) orelse return error.BadClusterSize;
        const buf = try self.allocator.alloc(u8, max_chunk_size);
        defer self.allocator.free(buf);
        var work_stats: chunk_sealer.WorkStats = .{};
        const use_parent_index = self.canReuseParentIndex();
        var sealed_candidate_chunks: usize = 0;
        var parent_chunks_reused: usize = 0;
        var parent_objects_linked: usize = 0;
        var parent_objects_reused: usize = 0;
        var parent_objects_copied: usize = 0;
        var parent_object_bytes: u64 = 0;
        var linked_parent_object = false;
        var published_parent_objects = std.StringHashMap(void).init(self.allocator);
        defer published_parent_objects.deinit();

        for (0..self.chunkCount()) |chunk_index| {
            if (use_parent_index and !self.needsSnapshotSeal(chunk_index)) {
                if (self.parent_digests[chunk_index]) |digest| {
                    try appendChunkEntry(self.allocator, &chunks, chunk_index, digest);
                    parent_chunks_reused += 1;
                    if (!std.mem.eql(u8, self.parent_root.?, dir)) {
                        const entry = try published_parent_objects.getOrPut(digest);
                        if (!entry.found_existing) {
                            const object_len = try self.chunkLen(chunk_index);
                            switch (try self.publishParentObject(self.parent_root.?, dir, digest, object_len, &work_stats)) {
                                .linked => {
                                    parent_objects_linked += 1;
                                    linked_parent_object = true;
                                },
                                .reused_existing => parent_objects_reused += 1,
                                .copied => parent_objects_copied += 1,
                            }
                            parent_object_bytes +|= object_len;
                        }
                    }
                } else {
                    try zero_chunks.append(self.allocator, @intCast(chunk_index));
                    parent_chunks_reused += 1;
                }
                continue;
            }
            sealed_candidate_chunks += 1;
            try self.sealSnapshotChunk(dir, chunk_index, buf, &chunks, &zero_chunks, &work_stats);
        }
        if (linked_parent_object) try chunk_sealer.fsyncDirPath(self.allocator, object_dir);

        const chunk_slice = try chunks.toOwnedSlice(self.allocator);
        defer {
            for (chunk_slice) |entry| self.allocator.free(entry.digest);
            self.allocator.free(chunk_slice);
        }
        const zero_slice = try zero_chunks.toOwnedSlice(self.allocator);
        defer self.allocator.free(zero_slice);

        const index = disk_index.DiskIndex{
            .kind = disk_index.disk_index_kind,
            .logical_size = self.size,
            .chunk_size = self.chunk_size,
            .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
            .object_namespace = spore.rootfs_storage_object_namespace,
            .chunks = chunk_slice,
            .zero_chunks = zero_slice,
        };
        const encoded_index = try disk_index.encodeCanonicalAlloc(self.allocator, index);
        defer self.allocator.free(encoded_index.bytes);
        const index_digest = encoded_index.digest;
        errdefer self.allocator.free(index_digest);
        const index_path = try rootfs_cas.manifestIndexPath(self.allocator, dir, index_digest);
        defer self.allocator.free(index_path);
        const index_dir = std.fs.path.dirname(index_path) orelse return error.IoFailed;
        try chunk_sealer.ensureDirPath(self.allocator, index_dir);
        // Durable-index invariant: all object writes above have fsynced their
        // data and parent directory; publish the index last via temp/fsync/rename.
        try chunk_sealer.writeFileAtomicDurable(self.allocator, index_path, encoded_index.bytes, 0o444);
        const next_parent = try self.parentStateFrom(dir, index);
        errdefer next_parent.deinit(self.allocator);
        const kind = try self.allocator.dupe(u8, spore.disk_kind_chunk_index);
        errdefer self.allocator.free(kind);
        const cloned_device = try spore.cloneRootfsDevice(self.allocator, device);
        errdefer {
            self.allocator.free(cloned_device.kind);
            self.allocator.free(cloned_device.role);
        }
        const hash_algorithm = try self.allocator.dupe(u8, spore.rootfs_storage_hash_algorithm_blake3);
        errdefer self.allocator.free(hash_algorithm);
        const object_namespace = try self.allocator.dupe(u8, spore.rootfs_storage_object_namespace);
        errdefer self.allocator.free(object_namespace);

        const result = spore.Disk{
            .kind = kind,
            .device = cloned_device,
            .size = self.size,
            .base = index_digest,
            .chunk_size = self.chunk_size,
            .hash_algorithm = hash_algorithm,
            .object_namespace = object_namespace,
            .layers = &.{},
        };
        if (stats_out) |out| {
            out.* = .{
                .full_scan = !use_parent_index,
                .sealed_candidate_chunks = sealed_candidate_chunks,
                .parent_chunks_reused = parent_chunks_reused,
                .parent_objects_linked = parent_objects_linked,
                .parent_objects_reused = parent_objects_reused,
                .parent_objects_copied = parent_objects_copied,
                .parent_object_bytes = parent_object_bytes,
                .work = work_stats,
            };
        }
        self.installSnapshotBaseline(next_parent);
        return result;
    }

    fn canReuseParentIndex(self: ChunkMappedDisk) bool {
        _ = self.parent_root orelse return false;
        return self.parent_digests.len == self.sources.len;
    }

    fn needsSnapshotSeal(self: ChunkMappedDisk, chunk_index: usize) bool {
        return sourceIsDirty(self.sources[chunk_index]);
    }

    fn parentStateFrom(self: *ChunkMappedDisk, root: []const u8, index: disk_index.DiskIndex) Error!ParentClone {
        const parent_root = try self.allocator.dupe(u8, root);
        errdefer self.allocator.free(parent_root);
        const parent_digests = try self.allocator.alloc(?[]const u8, self.sources.len);
        @memset(parent_digests, null);
        errdefer freeOptionalDigests(self.allocator, parent_digests);
        for (index.chunks) |entry| {
            if (entry.logical_chunk >= self.sources.len) return error.BadManifest;
            parent_digests[@intCast(entry.logical_chunk)] = try self.allocator.dupe(u8, entry.digest);
        }
        return .{ .root = parent_root, .digests = parent_digests };
    }

    fn installSnapshotBaseline(self: *ChunkMappedDisk, next: ParentClone) void {
        const old_root = self.parent_root;
        const old_digests = self.parent_digests;
        self.parent_root = next.root;
        self.parent_digests = next.digests;
        self.snapshot_published = true;
        for (self.sources) |*source| {
            source.* = switch (source.*) {
                .overlay => .overlay_clean,
                .zero_dirty => .zero,
                else => source.*,
            };
        }
        if (old_root) |root| self.allocator.free(root);
        if (old_digests.len != 0) freeOptionalDigests(self.allocator, old_digests);
    }

    fn sealSnapshotChunk(
        self: *ChunkMappedDisk,
        dir: []const u8,
        chunk_index: usize,
        buf: []u8,
        chunks: *std.ArrayList(disk_index.DiskIndexChunk),
        zero_chunks: *std.ArrayList(u64),
        work_stats: *chunk_sealer.WorkStats,
    ) Error!void {
        const len = try self.chunkLen(chunk_index);
        const data = buf[0..len];
        try self.readChunk(chunk_index, data);
        const sealed = try chunk_sealer.sealBytes(data, work_stats);
        work_stats.sealed_chunks += 1;
        switch (sealed) {
            .zero => try zero_chunks.append(self.allocator, @intCast(chunk_index)),
            .data => |id| {
                const hex = id.toHex();
                const digest = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ spore.rootfs_digest_prefix, hex[0..] });
                errdefer self.allocator.free(digest);
                const object_path = try rootfs_cas.manifestObjectPath(self.allocator, dir, digest);
                defer self.allocator.free(object_path);
                try chunk_sealer.writePathAllIfMissingTimed(self.allocator, object_path, data, work_stats);
                try chunks.append(self.allocator, .{
                    .logical_chunk = @intCast(chunk_index),
                    .digest = digest,
                });
            },
        }
    }

    const ParentObjectPublication = enum {
        linked,
        reused_existing,
        copied,
    };

    fn publishParentObject(
        self: *ChunkMappedDisk,
        parent_root: []const u8,
        dir: []const u8,
        digest: []const u8,
        expected_size: usize,
        work_stats: *chunk_sealer.WorkStats,
    ) Error!ParentObjectPublication {
        const source_path = try rootfs_cas.manifestObjectPath(self.allocator, parent_root, digest);
        defer self.allocator.free(source_path);
        const dest_path = try rootfs_cas.manifestObjectPath(self.allocator, dir, digest);
        defer self.allocator.free(dest_path);
        switch (try chunk_sealer.publishTrustedFileIfMissing(self.allocator, source_path, dest_path, expected_size)) {
            .linked => return .linked,
            .reused_existing => return .reused_existing,
            .copy_required => {},
        }

        const data = try rootfs_cas.readVerifiedManifestObject(self.allocator, parent_root, digest, expected_size);
        defer self.allocator.free(data);
        _ = try chunk_sealer.writePathAllIfMissingTimedResult(self.allocator, dest_path, data, work_stats);
        return .copied;
    }

    fn checkRange(self: ChunkMappedDisk, len: usize, offset: u64) Error!void {
        const end = std.math.add(u64, offset, len) catch return error.OutOfRange;
        if (end > self.size) return error.OutOfRange;
    }

    fn spanFor(self: ChunkMappedDisk, offset: u64, remaining: usize) Error!Span {
        const chunk_index_u64 = offset / self.chunk_size;
        if (chunk_index_u64 > std.math.maxInt(usize)) return error.OutOfRange;
        const chunk_offset = offset % self.chunk_size;
        const left_in_chunk = self.chunk_size - chunk_offset;
        const len = @min(remaining, std.math.cast(usize, left_in_chunk) orelse return error.BadClusterSize);
        return .{
            .chunk_index = @intCast(chunk_index_u64),
            .chunk_offset = @intCast(chunk_offset),
            .len = len,
        };
    }

    fn seedChunk(self: *ChunkMappedDisk, chunk_index: usize, overlay_fd: std.c.fd_t) Error!void {
        const len = try self.chunkLen(chunk_index);
        const offset = std.math.mul(u64, chunk_index, self.chunk_size) catch return error.OutOfRange;
        const buf = try self.allocator.alloc(u8, len);
        defer self.allocator.free(buf);
        switch (self.sources[chunk_index]) {
            .base => try self.base.readAt(buf, offset),
            .overlay, .overlay_clean => return,
            .zero, .zero_dirty => @memset(buf, 0),
            .cas => {
                try self.faultCasChunk(chunk_index);
                try self.base.readAt(buf, offset);
            },
        }
        try writeExact(overlay_fd, buf, offset);
    }

    fn faultCasChunk(self: *ChunkMappedDisk, chunk_index: usize) Error!void {
        if (chunk_index >= self.sources.len) return error.OutOfRange;
        if (self.sources[chunk_index] != .cas) return;
        const trace_enabled = self.lazy_cas_trace != null;
        const fault_start_ns = if (trace_enabled) monotonicNs() catch 0 else 0;
        if (self.lazy_cas_trace) |*trace| trace.stats.fault_attempts +|= 1;
        var fault_recorded = false;
        var object_stats: rootfs_cas.ManifestObjectReadStats = .{};
        var write_ns: u64 = 0;
        defer if (trace_enabled and !fault_recorded) {
            self.recordLazyCasFault(false, 0, fault_start_ns, write_ns, object_stats);
        };
        const cache_root = self.cas_root orelse return error.BadManifest;
        if (self.cas_digests.len != self.sources.len) return error.BadManifest;
        const digest = self.cas_digests[chunk_index] orelse return error.BadManifest;
        const len = try self.chunkLen(chunk_index);
        const data = if (trace_enabled)
            try rootfs_cas.readVerifiedManifestObjectTimed(self.allocator, cache_root, digest, len, &object_stats)
        else
            try rootfs_cas.readVerifiedManifestObject(self.allocator, cache_root, digest, len);
        defer self.allocator.free(data);
        const offset = std.math.mul(u64, chunk_index, self.chunk_size) catch return error.OutOfRange;
        const write_start_ns = if (trace_enabled) monotonicNs() catch 0 else 0;
        writeExact(self.base.fd, data, offset) catch |err| {
            write_ns = elapsedSince(write_start_ns);
            return err;
        };
        write_ns = if (trace_enabled) elapsedSince(write_start_ns) else 0;
        self.clearCasDigest(chunk_index);
        self.sources[chunk_index] = .base;
        fault_recorded = true;
        self.recordLazyCasFault(true, len, fault_start_ns, write_ns, object_stats);
    }

    fn recordLazyCasFault(
        self: *ChunkMappedDisk,
        success: bool,
        bytes: usize,
        fault_start_ns: u64,
        write_ns: u64,
        object: rootfs_cas.ManifestObjectReadStats,
    ) void {
        if (self.lazy_cas_trace) |*trace| {
            if (success) {
                trace.stats.unique_chunks +|= 1;
                trace.stats.fault_bytes +|= bytes;
            } else {
                trace.stats.fault_errors +|= 1;
            }
            trace.stats.fault_total_ns +|= elapsedSince(fault_start_ns);
            trace.stats.object_prepare_ns +|= object.prepare_ns;
            trace.stats.object_read_ns +|= object.read_ns;
            trace.stats.object_verify_ns +|= object.verify_ns;
            trace.stats.sparse_write_ns +|= write_ns;
        }
    }

    fn appendLazyCasTrace(self: *ChunkMappedDisk) void {
        const trace = self.lazy_cas_trace orelse return;
        const stats = trace.stats;
        var remaining: u64 = 0;
        for (self.sources) |source| {
            if (source == .cas) remaining +|= 1;
        }
        var line_buf: [1024]u8 = undefined;
        const line = std.fmt.bufPrint(
            &line_buf,
            "{{\"event\":\"lazy_cas_fault_summary\",\"version\":1,\"runtime_open_ns\":{d},\"index_attach_ns\":{d},\"index_payload_bytes\":{d},\"total_chunks\":{d},\"cas_chunks_initial\":{d},\"cas_chunks_remaining\":{d},\"fault_attempts\":{d},\"fault_errors\":{d},\"unique_chunks\":{d},\"fault_bytes\":{d},\"fault_total_ns\":{d},\"object_prepare_ns\":{d},\"object_read_ns\":{d},\"object_verify_ns\":{d},\"sparse_write_ns\":{d}}}\n",
            .{
                stats.runtime_open_ns,
                stats.index_attach_ns,
                stats.index_payload_bytes,
                stats.total_chunks,
                stats.cas_chunks_initial,
                remaining,
                stats.fault_attempts,
                stats.fault_errors,
                stats.unique_chunks,
                stats.fault_bytes,
                stats.fault_total_ns,
                stats.object_prepare_ns,
                stats.object_read_ns,
                stats.object_verify_ns,
                stats.sparse_write_ns,
            },
        ) catch return;
        fd_util.writeAllBestEffort(trace.fd, line);
    }

    fn clearCasDigest(self: *ChunkMappedDisk, chunk_index: usize) void {
        if (self.cas_digests.len == 0) return;
        if (self.cas_digests[chunk_index]) |digest| {
            self.allocator.free(digest);
            self.cas_digests[chunk_index] = null;
        }
    }

    fn deinitCasState(self: *ChunkMappedDisk) void {
        if (self.cas_root) |root| {
            self.allocator.free(root);
            self.cas_root = null;
        }
        if (self.cas_digests.len != 0) {
            freeOptionalDigests(self.allocator, self.cas_digests);
            self.cas_digests = &.{};
        }
    }

    fn deinitParentIndex(self: *ChunkMappedDisk) void {
        if (self.parent_root) |root| {
            self.allocator.free(root);
            self.parent_root = null;
        }
        if (self.parent_digests.len != 0) {
            freeOptionalDigests(self.allocator, self.parent_digests);
            self.parent_digests = &.{};
        }
    }

    fn cloneCasState(self: ChunkMappedDisk) Error!CasClone {
        const root = if (self.cas_root) |cas_root| try self.allocator.dupe(u8, cas_root) else null;
        errdefer if (root) |cas_root| self.allocator.free(cas_root);
        if (self.cas_digests.len == 0) return .{ .root = root };
        if (self.cas_digests.len != self.sources.len) return error.BadManifest;

        const digests = try self.allocator.alloc(?[]const u8, self.cas_digests.len);
        @memset(digests, null);
        errdefer freeOptionalDigests(self.allocator, digests);
        for (self.cas_digests, 0..) |maybe_digest, i| {
            if (maybe_digest) |digest| {
                digests[i] = try self.allocator.dupe(u8, digest);
            } else if (self.sources[i] == .cas) {
                return error.BadManifest;
            }
        }
        return .{ .root = root, .digests = digests };
    }

    fn cloneParentIndex(self: ChunkMappedDisk) Error!ParentClone {
        const root = if (self.parent_root) |parent_root| try self.allocator.dupe(u8, parent_root) else null;
        errdefer if (root) |parent_root| self.allocator.free(parent_root);
        if (self.parent_digests.len == 0) return .{ .root = root };
        if (self.parent_digests.len != self.sources.len) return error.BadManifest;
        const digests = try self.allocator.alloc(?[]const u8, self.parent_digests.len);
        @memset(digests, null);
        errdefer freeOptionalDigests(self.allocator, digests);
        for (self.parent_digests, 0..) |maybe_digest, i| {
            if (maybe_digest) |digest| digests[i] = try self.allocator.dupe(u8, digest);
        }
        return .{ .root = root, .digests = digests };
    }

    fn copyOverlayChunks(self: *ChunkMappedDisk, parent_fd: std.c.fd_t, child_fd: std.c.fd_t) Error!u64 {
        const overlay_size = std.math.cast(std.c.off_t, self.size) orelse return error.BadDiskSize;
        if (std.c.ftruncate(child_fd, overlay_size) != 0) return error.ResizeFailed;

        const max_chunk_size = std.math.cast(usize, self.chunk_size) orelse return error.BadClusterSize;
        const buf = try self.allocator.alloc(u8, max_chunk_size);
        defer self.allocator.free(buf);

        var copied_bytes: u64 = 0;
        for (self.sources, 0..) |source, chunk_index| {
            if (source != .overlay and source != .overlay_clean) continue;
            const len = try self.chunkLen(chunk_index);
            const offset = std.math.mul(u64, chunk_index, self.chunk_size) catch return error.OutOfRange;
            const data = buf[0..len];
            try readExact(parent_fd, data, offset);
            try writeExact(child_fd, data, offset);
            copied_bytes += len;
        }
        return copied_bytes;
    }

    const CloneOverlayOptions = struct {
        allow_copy: bool,
        force_copy: bool,
    };

    const ClonedOverlay = struct {
        fd: std.c.fd_t,
        method: ForkCloneMethod,
        copied_bytes: u64,
    };

    fn cloneOverlay(self: *ChunkMappedDisk, parent_fd: std.c.fd_t, options: CloneOverlayOptions) Error!ClonedOverlay {
        const overlay_dir = self.overlay_dir orelse return error.ReadOnly;
        if (!options.force_copy) {
            if (try cloneOverlayNative(self.allocator, overlay_dir, parent_fd)) |fd| return .{ .fd = fd, .method = .reflink, .copied_bytes = 0 };
        }
        if (!options.allow_copy) return error.FastForkUnavailable;
        const child_fd = try createTempOverlayFd(self.allocator, overlay_dir);
        errdefer _ = std.c.close(child_fd);
        const copied_bytes = try self.copyOverlayChunks(parent_fd, child_fd);
        return .{ .fd = child_fd, .method = .copy, .copied_bytes = copied_bytes };
    }
};

const Span = struct {
    chunk_index: usize,
    chunk_offset: usize,
    len: usize,
};

const CasClone = struct {
    root: ?[]const u8 = null,
    digests: []?[]const u8 = &.{},

    fn deinit(self: CasClone, allocator: std.mem.Allocator) void {
        if (self.root) |root| allocator.free(root);
        if (self.digests.len != 0) freeOptionalDigests(allocator, self.digests);
    }
};

const ParentClone = struct {
    root: ?[]const u8 = null,
    digests: []?[]const u8 = &.{},

    fn deinit(self: ParentClone, allocator: std.mem.Allocator) void {
        if (self.root) |root| allocator.free(root);
        if (self.digests.len != 0) freeOptionalDigests(allocator, self.digests);
    }
};

const IndexState = struct {
    sources: []Source,
    cas_root: []const u8,
    cas_digests: []?[]const u8,
    parent_root: []const u8,
    parent_digests: []?[]const u8,
};

fn freeOptionalDigests(allocator: std.mem.Allocator, digests: []?[]const u8) void {
    if (digests.len == 0) return;
    for (digests) |maybe_digest| {
        if (maybe_digest) |digest| allocator.free(digest);
    }
    allocator.free(digests);
}

fn appendChunkEntry(
    allocator: std.mem.Allocator,
    chunks: *std.ArrayList(disk_index.DiskIndexChunk),
    chunk_index: usize,
    digest: []const u8,
) Error!void {
    const cloned_digest = try allocator.dupe(u8, digest);
    errdefer allocator.free(cloned_digest);
    try chunks.append(allocator, .{
        .logical_chunk = @intCast(chunk_index),
        .digest = cloned_digest,
    });
}

fn computeChunkCount(size: u64, chunk_size: u64) Error!u64 {
    return std.math.divCeil(u64, size, chunk_size) catch return error.BadDiskSize;
}

fn indexStatePayloadBytes(source_count: usize, cache_root: []const u8, index: disk_index.DiskIndex) u64 {
    var bytes: u64 = @as(u64, @intCast(source_count)) *| @sizeOf(Source);
    bytes +|= @as(u64, @intCast(source_count)) *| @sizeOf(?[]const u8) *| 2;
    bytes +|= @as(u64, @intCast(cache_root.len)) *| 2;
    for (index.chunks) |entry| bytes +|= @as(u64, @intCast(entry.digest.len)) *| 2;
    return bytes;
}

fn readExact(fd: std.c.fd_t, buf: []u8, offset: u64) Error!void {
    var done: usize = 0;
    while (done < buf.len) {
        const absolute = std.math.add(u64, offset, done) catch return error.OutOfRange;
        const file_offset = std.math.cast(std.c.off_t, absolute) orelse return error.OutOfRange;
        const n = std.c.pread(fd, buf.ptr + done, buf.len - done, file_offset);
        if (n <= 0) return error.ShortRead;
        done += @intCast(n);
    }
}

fn writeExact(fd: std.c.fd_t, buf: []const u8, offset: u64) Error!void {
    var done: usize = 0;
    while (done < buf.len) {
        const absolute = std.math.add(u64, offset, done) catch return error.OutOfRange;
        const file_offset = std.math.cast(std.c.off_t, absolute) orelse return error.OutOfRange;
        const n = std.c.pwrite(fd, buf.ptr + done, buf.len - done, file_offset);
        if (n <= 0) return error.ShortWrite;
        done += @intCast(n);
    }
}

fn monotonicNs() Error!u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return error.IoFailed;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn elapsedSince(start_ns: u64) u64 {
    if (start_ns == 0) return 0;
    const end_ns = monotonicNs() catch return 0;
    return end_ns -| start_ns;
}

fn createTempOverlayFd(allocator: std.mem.Allocator, dir: []const u8) Error!std.c.fd_t {
    if (dir.len == 0) return error.BadOverlay;
    const template = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/sporevm-disk-fork-XXXXXX",
        .{std.mem.trimEnd(u8, dir, "/")},
        0,
    );
    defer allocator.free(template);
    const fd = mkstemp(template.ptr);
    if (fd < 0) return error.IoFailed;
    errdefer _ = std.c.close(fd);
    if (std.c.unlink(template.ptr) != 0) return error.IoFailed;
    try fd_util.setCloseOnExec(fd);
    return fd;
}

fn tryCloneOverlayLinux(parent_fd: std.c.fd_t, child_fd: std.c.fd_t) bool {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const request = linux.IOCTL.IOW(0x94, 9, c_int);
        return linux.errno(linux.ioctl(child_fd, request, @as(usize, @intCast(parent_fd)))) == .SUCCESS;
    }
    return false;
}

fn cloneOverlayNative(allocator: std.mem.Allocator, overlay_dir: []const u8, parent_fd: std.c.fd_t) Error!?std.c.fd_t {
    if (comptime builtin.os.tag == .linux) {
        const child_fd = try createTempOverlayFd(allocator, overlay_dir);
        if (tryCloneOverlayLinux(parent_fd, child_fd)) return child_fd;
        _ = std.c.close(child_fd);
        return null;
    }
    if (comptime builtin.os.tag == .macos) return try cloneOverlayMacos(allocator, overlay_dir, parent_fd);
    return null;
}

fn cloneOverlayMacos(allocator: std.mem.Allocator, overlay_dir: []const u8, parent_fd: std.c.fd_t) Error!?std.c.fd_t {
    const dir_template = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/sporevm-disk-fork-XXXXXX",
        .{std.mem.trimEnd(u8, overlay_dir, "/")},
        0,
    );
    defer allocator.free(dir_template);
    const dir_ptr = mkdtemp(dir_template.ptr) orelse return error.IoFailed;
    defer _ = std.c.rmdir(dir_ptr);
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/overlay", .{std.mem.span(dir_ptr)}, 0);
    defer allocator.free(path);
    if (fclonefileat(parent_fd, std.c.AT.FDCWD, path.ptr, 0) != 0) return null;
    var linked = true;
    defer {
        if (linked) _ = std.c.unlink(path.ptr);
    }
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.IoFailed;
    if (std.c.unlink(path.ptr) != 0) {
        _ = std.c.close(fd);
        return error.IoFailed;
    }
    linked = false;
    return fd;
}

fn objectDir(allocator: std.mem.Allocator, dir: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/cas/rootfs/blake3/objects", .{dir}) catch return error.OutOfMemory;
}

fn freeTestDisk(allocator: std.mem.Allocator, disk: spore.Disk) void {
    allocator.free(disk.kind);
    allocator.free(disk.device.kind);
    allocator.free(disk.device.role);
    allocator.free(disk.base);
    allocator.free(disk.hash_algorithm);
    allocator.free(disk.object_namespace);
}

fn digestForChunk(index: disk_index.DiskIndex, logical_chunk: u64) Error![]const u8 {
    for (index.chunks) |entry| {
        if (entry.logical_chunk == logical_chunk) return entry.digest;
    }
    return error.BadManifest;
}

fn expectChunkDigest(index: disk_index.DiskIndex, logical_chunk: u64, digest: []const u8) !void {
    const actual = try digestForChunk(index, logical_chunk);
    try std.testing.expectEqualStrings(digest, actual);
}

fn expectZeroChunk(index: disk_index.DiskIndex, logical_chunk: u64) !void {
    for (index.zero_chunks) |zero_chunk| {
        if (zero_chunk == logical_chunk) return;
    }
    return error.TestExpectedEqual;
}

test "partial write preserves untouched bytes from base" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);

    var base_bytes: [8192]u8 = undefined;
    for (&base_bytes, 0..) |*byte, i| byte.* = @truncate(i);
    try base.writeStreamingAll(io, &base_bytes);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try ChunkMappedDisk.initWritable(std.testing.allocator, base_source, overlay.handle, base_bytes.len, 4096);
    defer disk.deinit();

    const patch = [_]u8{0xAA} ** 512;
    try disk.writeAt(&patch, 1024);

    var readback: [4096]u8 = undefined;
    try disk.readAt(&readback, 0);
    try std.testing.expectEqualSlices(u8, base_bytes[0..1024], readback[0..1024]);
    try std.testing.expectEqualSlices(u8, &patch, readback[1024..1536]);
    try std.testing.expectEqualSlices(u8, base_bytes[1536..4096], readback[1536..4096]);
    try std.testing.expectEqual(@as(usize, 1), disk.dirtyChunkCount());
}

test "chunk mapped disk matches byte model across partial writes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);

    var base_bytes: [2048 + 137]u8 = undefined;
    for (&base_bytes, 0..) |*byte, i| byte.* = @truncate((i * 31) + 7);
    var model = base_bytes;
    try base.writeStreamingAll(io, &base_bytes);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try ChunkMappedDisk.initWritable(std.testing.allocator, base_source, overlay.handle, base_bytes.len, 512);
    defer disk.deinit();

    const patch_a = [_]u8{0xAA} ** 13;
    const patch_b = [_]u8{0xBB} ** 700;
    const patch_c = [_]u8{0xCC} ** 37;
    const writes = [_]struct {
        offset: usize,
        data: []const u8,
    }{
        .{ .offset = 3, .data = &patch_a },
        .{ .offset = 500, .data = &patch_b },
        .{ .offset = base_bytes.len - patch_c.len, .data = &patch_c },
    };

    var dirty_model = [_]bool{false} ** 5;
    for (writes) |write| {
        try disk.writeAt(write.data, write.offset);
        @memcpy(model[write.offset..][0..write.data.len], write.data);

        const first = write.offset / 512;
        const last = (write.offset + write.data.len - 1) / 512;
        for (first..last + 1) |i| dirty_model[i] = true;
    }

    for (dirty_model, 0..) |is_dirty, i| {
        try std.testing.expectEqual(is_dirty, try disk.isDirtyChunk(i));
    }

    const read_lengths = [_]usize{ 0, 1, 7, 255, 512, 513, 900 };
    var readback: [900]u8 = undefined;
    var offset: usize = 0;
    while (offset < model.len) : (offset += 127) {
        for (read_lengths) |len| {
            if (offset + len > model.len) continue;
            try disk.readAt(readback[0..len], offset);
            try std.testing.expectEqualSlices(u8, model[offset..][0..len], readback[0..len]);
        }
    }
}

test "zero chunks seed partial overlay writes from zeroes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);

    const base_bytes = [_]u8{0x11} ** 1024;
    try base.writeStreamingAll(io, &base_bytes);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try ChunkMappedDisk.initWritable(std.testing.allocator, base_source, overlay.handle, base_bytes.len, 512);
    defer disk.deinit();
    try disk.markZeroChunk(1);

    const patch = [_]u8{0x7B} ** 4;
    try disk.writeAt(&patch, 512 + 10);

    var readback: [512]u8 = undefined;
    try disk.readAt(&readback, 512);
    try std.testing.expect(std.mem.allEqual(u8, readback[0..10], 0));
    try std.testing.expectEqualSlices(u8, &patch, readback[10..14]);
    try std.testing.expect(std.mem.allEqual(u8, readback[14..], 0));
}

test "zero marking and growth advance dirty state" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const spore_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/spore", .{tmp.sub_path[0..]});
    defer allocator.free(spore_dir);
    try std.Io.Dir.cwd().createDirPath(io, spore_dir);
    const chunk_size: usize = 512;
    const base_bytes = try allocator.alloc(u8, chunk_size * 2);
    defer allocator.free(base_bytes);
    @memset(base_bytes, 0x31);
    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    try base.writeStreamingAll(io, base_bytes);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try ChunkMappedDisk.initWritable(allocator, base_source, overlay.handle, chunk_size, chunk_size);
    defer disk.deinit();

    try disk.markZeroChunk(0);
    try std.testing.expectEqual(@as(usize, 1), disk.dirtyChunkCount());
    const zeroed = try disk.snapshotIndex(spore_dir, .{ .mmio_slot = 1 }, true);
    defer freeTestDisk(allocator, zeroed);
    try std.testing.expectEqual(@as(usize, 0), disk.dirtyChunkCount());

    try disk.grow(chunk_size * 2);
    try std.testing.expectEqual(@as(usize, 1), disk.dirtyChunkCount());
    const grown = try disk.snapshotIndex(spore_dir, .{ .mmio_slot = 1 }, true);
    defer freeTestDisk(allocator, grown);
    try std.testing.expectEqual(@as(u64, chunk_size * 2), grown.size);
    try std.testing.expectEqual(@as(usize, 0), disk.dirtyChunkCount());
}

test "snapshot writes disk index and chunk objects" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const spore_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/spore", .{tmp.sub_path[0..]});
    defer allocator.free(spore_dir);
    try std.Io.Dir.cwd().createDirPath(io, spore_dir);

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);

    const base_bytes = [_]u8{0} ** 1024;
    try base.writeStreamingAll(io, &base_bytes);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try ChunkMappedDisk.initWritable(allocator, base_source, overlay.handle, base_bytes.len, spore.disk_chunk_size);
    defer disk.deinit();

    const patch = [_]u8{0x5A} ** 16;
    try disk.writeAt(&patch, 600);

    var stats: SnapshotStats = .{};
    const manifest_disk = try disk.snapshotIndexWithStats(spore_dir, .{ .mmio_slot = 1 }, true, &stats);
    defer freeTestDisk(allocator, manifest_disk);

    try std.testing.expect(stats.full_scan);
    try std.testing.expectEqual(@as(usize, 1), stats.sealed_candidate_chunks);
    try std.testing.expectEqual(@as(u64, 1), stats.work.sealed_chunks);

    try std.testing.expectEqualStrings(spore.disk_kind_chunk_index, manifest_disk.kind);
    try std.testing.expectEqual(@as(u64, spore.disk_chunk_size), manifest_disk.chunk_size);
    try std.testing.expectEqual(@as(usize, 0), manifest_disk.layers.len);

    const index_path = try rootfs_cas.manifestIndexPath(allocator, spore_dir, manifest_disk.base);
    defer allocator.free(index_path);
    const index_bytes = try std.Io.Dir.cwd().readFileAlloc(io, index_path, allocator, .limited(disk_index.max_index_bytes));
    defer allocator.free(index_bytes);
    const storage = spore.RootfsStorage{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = manifest_disk.device,
        .logical_size = manifest_disk.size,
        .chunk_size = manifest_disk.chunk_size,
        .hash_algorithm = manifest_disk.hash_algorithm,
        .index_digest = manifest_disk.base,
        .base_identity = manifest_disk.base,
        .object_namespace = manifest_disk.object_namespace,
    };
    const parsed = try disk_index.parseDiskIndex(allocator, index_bytes, try spore.diskIndexDescriptorForStorage(storage));
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.chunks.len);
    try std.testing.expectEqual(@as(u64, 0), parsed.value.chunks[0].logical_chunk);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.zero_chunks.len);
    try std.testing.expectEqual(@as(usize, 0), disk.dirtyChunkCount());

    const object_path = try rootfs_cas.manifestObjectPath(allocator, spore_dir, parsed.value.chunks[0].digest);
    defer allocator.free(object_path);
    try std.Io.Dir.cwd().access(io, object_path, .{ .read = true });
}

test "snapshot output does not become live disk storage" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const temp_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/temp.spore", .{tmp.sub_path[0..]});
    defer allocator.free(temp_dir);
    const final_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/final.spore", .{tmp.sub_path[0..]});
    defer allocator.free(final_dir);
    const second_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/second.spore", .{tmp.sub_path[0..]});
    defer allocator.free(second_dir);
    try std.Io.Dir.cwd().createDirPath(io, temp_dir);

    const chunk_size: usize = 512;
    const base_bytes = try allocator.alloc(u8, chunk_size * 2);
    defer allocator.free(base_bytes);
    for (base_bytes, 0..) |*byte, i| byte.* = @truncate((i * 29) + 11);
    const model = try allocator.dupe(u8, base_bytes);
    defer allocator.free(model);

    {
        var writer = try tmp.dir.createFile(io, "base.img", .{});
        defer writer.close(io);
        try writer.writeStreamingAll(io, base_bytes);
    }
    var base = try tmp.dir.openFile(io, "base.img", .{ .mode = .read_only });
    defer base.close(io);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try ChunkMappedDisk.initWritable(allocator, base_source, overlay.handle, base_bytes.len, chunk_size);
    defer disk.deinit();

    const first_patch = [_]u8{0xA1} ** 31;
    try disk.writeAt(&first_patch, 17);
    @memcpy(model[17..][0..first_patch.len], &first_patch);

    var prepared_root = try disk.prepareSnapshotRoot(final_dir);
    defer prepared_root.deinit();
    const saved = try disk.snapshotIndex(temp_dir, .{ .mmio_slot = 1 }, true);
    defer freeTestDisk(allocator, saved);
    try std.testing.expectEqual(@as(usize, 0), disk.dirtyChunkCount());
    const readback = try allocator.alloc(u8, model.len);
    defer allocator.free(readback);
    try disk.readAt(readback, 0);
    try std.testing.expectEqualSlices(u8, model, readback);
    try std.Io.Dir.rename(std.Io.Dir.cwd(), temp_dir, std.Io.Dir.cwd(), final_dir, io);
    try disk.commitSnapshotRoot(temp_dir, &prepared_root);
    try disk.readAt(readback, 0);
    try std.testing.expectEqualSlices(u8, model, readback);

    const overlay_patch = [_]u8{0xB2} ** 47;
    try disk.writeAt(&overlay_patch, 101);
    @memcpy(model[101..][0..overlay_patch.len], &overlay_patch);
    try std.Io.Dir.cwd().createDirPath(io, second_dir);
    var stats: SnapshotStats = .{};
    const second = try disk.snapshotIndexWithStats(second_dir, .{ .mmio_slot = 1 }, true, &stats);
    defer freeTestDisk(allocator, second);
    try std.testing.expect(!stats.full_scan);
    try std.testing.expectEqual(@as(usize, 1), stats.parent_chunks_reused);

    const base_patch = [_]u8{0xC3} ** 53;
    const base_patch_offset = chunk_size + 23;
    try disk.writeAt(&base_patch, base_patch_offset);
    @memcpy(model[base_patch_offset..][0..base_patch.len], &base_patch);

    try std.testing.expectEqual(@as(usize, 1), disk.dirtyChunkCount());
    try disk.readAt(readback, 0);
    try std.testing.expectEqualSlices(u8, model, readback);
}

test "failed write cannot leave overlay bytes classified clean" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const spore_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/spore", .{tmp.sub_path[0..]});
    defer allocator.free(spore_dir);
    try std.Io.Dir.cwd().createDirPath(io, spore_dir);
    const base_bytes = [_]u8{0xD4} ** 512;
    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    try base.writeStreamingAll(io, &base_bytes);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try ChunkMappedDisk.initWritable(allocator, base_source, overlay.handle, base_bytes.len, 512);
    defer disk.deinit();
    const first_patch = [_]u8{0xE5} ** 16;
    try disk.writeAt(&first_patch, 8);
    const saved = try disk.snapshotIndex(spore_dir, .{ .mmio_slot = 1 }, true);
    defer freeTestDisk(allocator, saved);
    try std.testing.expectEqual(@as(usize, 0), disk.dirtyChunkCount());

    overlay.close(io);
    const second_patch = [_]u8{0xF6} ** 16;
    try std.testing.expectError(error.ShortWrite, disk.writeAt(&second_patch, 32));
    try std.testing.expectEqual(@as(usize, 1), disk.dirtyChunkCount());
}

test "snapshot from parent index seals only dirty chunks and matches full rescan" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const snapshot_dir = try std.fmt.allocPrint(arena, "{s}/snapshot.spore", .{tmp_root});
    const parent_cache = try std.fmt.allocPrint(arena, "{s}/parent-cache", .{tmp_root});
    const full_cache = try std.fmt.allocPrint(arena, "{s}/full-cache", .{tmp_root});
    const parent_path = try std.fmt.allocPrint(arena, "{s}/parent.img", .{tmp_root});
    const full_path = try std.fmt.allocPrint(arena, "{s}/full.img", .{tmp_root});
    try std.Io.Dir.cwd().createDirPath(io, tmp_root);
    try std.Io.Dir.cwd().createDirPath(io, snapshot_dir);

    const chunk_size: usize = @intCast(spore.disk_chunk_size);
    const chunk_count: usize = 8;
    const total_size = chunk_size * chunk_count;
    const parent_bytes = try allocator.alloc(u8, total_size);
    defer allocator.free(parent_bytes);
    for (parent_bytes, 0..) |*byte, i| {
        byte.* = @truncate((i * 37) + ((i / chunk_size) * 13) + 19);
    }
    @memset(parent_bytes[5 * chunk_size ..][0..chunk_size], 0);
    const model = try allocator.dupe(u8, parent_bytes);
    defer allocator.free(model);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = parent_path, .data = parent_bytes });

    const parent_preload = try rootfs_cas.preloadPath(io, arena, parent_cache, parent_path, spore.disk_chunk_size);
    const parent_storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, parent_preload);
    const parent_index_bytes = try std.Io.Dir.cwd().readFileAlloc(io, parent_preload.index_path, arena, .limited(disk_index.max_index_bytes));
    const parent_index = try disk_index.parseDiskIndex(arena, parent_index_bytes, try spore.diskIndexDescriptorForStorage(parent_storage));
    defer parent_index.deinit();

    var base = try tmp.dir.createFile(io, "lazy-base.img", .{ .read = true });
    defer base.close(io);
    if (std.c.ftruncate(base.handle, @intCast(total_size)) != 0) return error.ResizeFailed;
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);

    const base_source = block_source.FileBlockSource.init(base.handle, total_size);
    var disk = try ChunkMappedDisk.initWritable(allocator, base_source, overlay.handle, total_size, spore.disk_chunk_size);
    defer disk.deinit();
    try disk.attachCasIndex(parent_cache, parent_index.value);

    var promoted: [16]u8 = undefined;
    try disk.readAt(&promoted, 4 * spore.disk_chunk_size + 17);
    try std.testing.expectEqualSlices(u8, parent_bytes[4 * chunk_size + 17 ..][0..promoted.len], &promoted);

    const zero_chunk = try allocator.alloc(u8, chunk_size);
    defer allocator.free(zero_chunk);
    @memset(zero_chunk, 0);
    try disk.writeAt(zero_chunk, spore.disk_chunk_size);
    @memset(model[chunk_size..][0..chunk_size], 0);

    const replacement = try allocator.alloc(u8, chunk_size);
    defer allocator.free(replacement);
    @memset(replacement, 0xA7);
    try disk.writeAt(replacement, 2 * spore.disk_chunk_size);
    try disk.writeAt(parent_bytes[2 * chunk_size ..][0..chunk_size], 2 * spore.disk_chunk_size);

    const patch_a = [_]u8{0x3C} ** 113;
    try disk.writeAt(&patch_a, 3 * spore.disk_chunk_size + 29);
    @memcpy(model[3 * chunk_size + 29 ..][0..patch_a.len], &patch_a);

    const patch_b = [_]u8{0x4D} ** 257;
    try disk.writeAt(&patch_b, 5 * spore.disk_chunk_size + 41);
    @memcpy(model[5 * chunk_size + 41 ..][0..patch_b.len], &patch_b);

    var fork_a = try disk.fork(.{ .force_copy = true, .quiesced = true });
    defer fork_a.deinit();
    const patch_c = [_]u8{0x5E} ** 211;
    try fork_a.disk.writeAt(&patch_c, 73);
    @memcpy(model[73..][0..patch_c.len], &patch_c);

    var fork_b = try fork_a.disk.fork(.{ .force_copy = true, .quiesced = true });
    defer fork_b.deinit();
    @memset(replacement, 0x6F);
    try fork_b.disk.writeAt(replacement, 6 * spore.disk_chunk_size);
    @memcpy(model[6 * chunk_size ..][0..chunk_size], replacement);

    const dirty_count = fork_b.disk.dirtyChunkCount();
    try std.testing.expect(dirty_count < fork_b.disk.chunkCount());

    var snapshot_stats: SnapshotStats = .{};
    const snapshot_disk = try fork_b.disk.snapshotIndexWithStats(snapshot_dir, .{ .mmio_slot = 1 }, true, &snapshot_stats);
    defer freeTestDisk(allocator, snapshot_disk);
    try std.testing.expect(!snapshot_stats.full_scan);
    try std.testing.expectEqual(dirty_count, snapshot_stats.sealed_candidate_chunks);
    try std.testing.expectEqual(@as(u64, @intCast(dirty_count)), snapshot_stats.work.sealed_chunks);
    try std.testing.expect(snapshot_stats.parent_chunks_reused > 0);
    try std.testing.expect(snapshot_stats.parent_objects_linked + snapshot_stats.parent_objects_reused + snapshot_stats.parent_objects_copied > 0);
    try std.testing.expect(snapshot_stats.parent_object_bytes > 0);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full_path, .data = model });
    const full_preload = try rootfs_cas.preloadPath(io, arena, full_cache, full_path, spore.disk_chunk_size);
    try std.testing.expectEqualStrings(full_preload.index_digest, snapshot_disk.base);

    const snapshot_index_path = try rootfs_cas.manifestIndexPath(arena, snapshot_dir, snapshot_disk.base);
    const snapshot_index_bytes = try std.Io.Dir.cwd().readFileAlloc(io, snapshot_index_path, arena, .limited(disk_index.max_index_bytes));
    const full_index_bytes = try std.Io.Dir.cwd().readFileAlloc(io, full_preload.index_path, arena, .limited(disk_index.max_index_bytes));
    try std.testing.expectEqualSlices(u8, full_index_bytes, snapshot_index_bytes);

    const snapshot_storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, .{
        .index_path = snapshot_index_path,
        .index_digest = snapshot_disk.base,
        .rootfs_digest = snapshot_disk.base,
        .rootfs_size = snapshot_disk.size,
        .chunk_size = snapshot_disk.chunk_size,
        .chunk_count = chunk_count,
        .zero_chunks = 0,
        .nonzero_chunks = 0,
        .objects_written = 0,
        .object_bytes_written = 0,
        .index_bytes = snapshot_index_bytes.len,
    });
    const snapshot_index = try disk_index.parseDiskIndex(arena, snapshot_index_bytes, try spore.diskIndexDescriptorForStorage(snapshot_storage));
    defer snapshot_index.deinit();
    try expectZeroChunk(snapshot_index.value, 1);
    try expectChunkDigest(snapshot_index.value, 2, try digestForChunk(parent_index.value, 2));
    try std.testing.expectEqual(@as(usize, 0), fork_b.disk.dirtyChunkCount());
    try std.testing.expectEqual(Source.overlay_clean, fork_b.disk.sources[6]);
    var promoted_after_snapshot: [64]u8 = undefined;
    const promoted_offset = 6 * chunk_size + 123;
    try fork_b.disk.readAt(&promoted_after_snapshot, @intCast(promoted_offset));
    try std.testing.expectEqualSlices(u8, model[promoted_offset..][0..promoted_after_snapshot.len], &promoted_after_snapshot);

    const patch_d = [_]u8{0x71} ** 31;
    try fork_b.disk.writeAt(&patch_d, 7 * spore.disk_chunk_size + 9);
    @memcpy(model[7 * chunk_size + 9 ..][0..patch_d.len], &patch_d);
    try std.testing.expectEqual(@as(usize, 1), fork_b.disk.dirtyChunkCount());

    var second_stats: SnapshotStats = .{};
    const second_snapshot_disk = try fork_b.disk.snapshotIndexWithStats(snapshot_dir, .{ .mmio_slot = 1 }, true, &second_stats);
    defer freeTestDisk(allocator, second_snapshot_disk);
    try std.testing.expect(!second_stats.full_scan);
    try std.testing.expectEqual(@as(usize, 1), second_stats.sealed_candidate_chunks);
    try std.testing.expectEqual(@as(u64, 1), second_stats.work.sealed_chunks);
    try std.testing.expectEqual(@as(usize, 0), fork_b.disk.dirtyChunkCount());

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full_path, .data = model });
    const second_full_preload = try rootfs_cas.preloadPath(io, arena, full_cache, full_path, spore.disk_chunk_size);
    try std.testing.expectEqualStrings(second_full_preload.index_digest, second_snapshot_disk.base);

    const second_full_index_bytes = try std.Io.Dir.cwd().readFileAlloc(io, second_full_preload.index_path, arena, .limited(disk_index.max_index_bytes));
    const second_full_storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, second_full_preload);
    const second_full_index = try disk_index.parseDiskIndex(arena, second_full_index_bytes, try spore.diskIndexDescriptorForStorage(second_full_storage));
    defer second_full_index.deinit();
    try std.Io.Dir.cwd().deleteTree(io, parent_cache);
    try std.Io.Dir.cwd().deleteTree(io, full_cache);
    for (second_full_index.value.chunks) |entry| {
        const offset: usize = @intCast(entry.logical_chunk * spore.disk_chunk_size);
        const expected = model[offset..@min(offset + chunk_size, model.len)];
        const object = try rootfs_cas.readVerifiedManifestObject(allocator, snapshot_dir, entry.digest, expected.len);
        defer allocator.free(object);
        try std.testing.expectEqualSlices(u8, expected, object);
    }
}

test "read only disk rejects writes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);

    const base_bytes = [_]u8{0x11} ** 512;
    try base.writeStreamingAll(io, &base_bytes);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try ChunkMappedDisk.initReadOnly(std.testing.allocator, base_source, base_bytes.len, 512);
    defer disk.deinit();

    const patch = [_]u8{0x22} ** 4;
    try std.testing.expectError(error.ReadOnly, disk.writeAt(&patch, 0));

    var readback: [512]u8 = undefined;
    try disk.readAt(&readback, 0);
    try std.testing.expectEqualSlices(u8, &base_bytes, &readback);
}

test "read only disk rejects fork" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);

    const base_bytes = [_]u8{0x11} ** 512;
    try base.writeStreamingAll(io, &base_bytes);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try ChunkMappedDisk.initReadOnly(std.testing.allocator, base_source, base_bytes.len, 512);
    defer disk.deinit();

    try std.testing.expectError(error.ReadOnly, disk.fork(.{ .quiesced = true }));
}

test "cas index attach rejects incomplete coverage" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);

    const base_bytes = [_]u8{0x33} ** 1024;
    try base.writeStreamingAll(io, &base_bytes);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try ChunkMappedDisk.initWritable(std.testing.allocator, base_source, overlay.handle, base_bytes.len, 512);
    defer disk.deinit();

    const chunks = [_]disk_index.DiskIndexChunk{.{
        .logical_chunk = 0,
        .digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }};
    const incomplete = disk_index.DiskIndex{
        .kind = disk_index.disk_index_kind,
        .logical_size = base_bytes.len,
        .chunk_size = 512,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .object_namespace = spore.rootfs_storage_object_namespace,
        .chunks = &chunks,
        .zero_chunks = &.{},
    };
    try std.testing.expectError(error.BadManifest, disk.attachCasIndex("/missing-cache", incomplete));

    var readback: [1024]u8 = undefined;
    try disk.readAt(&readback, 0);
    try std.testing.expectEqualSlices(u8, &base_bytes, &readback);
}

test "forced-copy fork isolates parent and child overlays" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);

    var base_bytes: [1536]u8 = undefined;
    for (&base_bytes, 0..) |*byte, i| byte.* = @truncate((i * 17) + 3);
    var parent_model = base_bytes;
    var child_model = base_bytes;
    try base.writeStreamingAll(io, &base_bytes);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try ChunkMappedDisk.initWritable(std.testing.allocator, base_source, overlay.handle, base_bytes.len, 512);
    defer disk.deinit();

    const first_parent_patch = [_]u8{0xA1} ** 48;
    try disk.writeAt(&first_parent_patch, 480);
    @memcpy(parent_model[480..][0..first_parent_patch.len], &first_parent_patch);
    @memcpy(child_model[480..][0..first_parent_patch.len], &first_parent_patch);

    var child = try disk.fork(.{ .force_copy = true, .quiesced = true });
    defer child.deinit();

    try std.testing.expectEqual(ForkCloneMethod.copy, child.clone_method);
    try std.testing.expectEqual(disk.chunkCount(), child.disk.chunkCount());
    try std.testing.expectEqual(disk.dirtyChunkCount(), child.disk.dirtyChunkCount());

    var readback: [1536]u8 = undefined;
    try child.disk.readAt(&readback, 0);
    try std.testing.expectEqualSlices(u8, &child_model, &readback);

    const second_parent_patch = [_]u8{0xB2} ** 32;
    try disk.writeAt(&second_parent_patch, 32);
    @memcpy(parent_model[32..][0..second_parent_patch.len], &second_parent_patch);

    try child.disk.readAt(&readback, 0);
    try std.testing.expectEqualSlices(u8, &child_model, &readback);

    const child_patch = [_]u8{0xC3} ** 40;
    try child.disk.writeAt(&child_patch, 512 + 24);
    @memcpy(child_model[512 + 24 ..][0..child_patch.len], &child_patch);

    try disk.readAt(&readback, 0);
    try std.testing.expectEqualSlices(u8, &parent_model, &readback);
    try child.disk.readAt(&readback, 0);
    try std.testing.expectEqualSlices(u8, &child_model, &readback);
}

test "portable fork head round trips overlay and zero overrides" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const disk_size = 3 * spore.disk_chunk_size;
    const base_bytes = try allocator.alloc(u8, disk_size);
    defer allocator.free(base_bytes);
    for (base_bytes, 0..) |*byte, i| byte.* = @truncate((i * 17) + 9);
    var model = try allocator.dupe(u8, base_bytes);
    defer allocator.free(model);

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    try base.writeStreamingAll(io, base_bytes);
    const base_source = block_source.FileBlockSource.init(base.handle, disk_size);

    const parent_fd = try createTempOverlayFd(allocator, runtime_overlay_dir);
    defer _ = std.c.close(parent_fd);
    var parent = try ChunkMappedDisk.initWritable(allocator, base_source, parent_fd, disk_size, spore.disk_chunk_size);
    defer parent.deinit();
    const patch = [_]u8{0xA7} ** 127;
    try parent.writeAt(&patch, spore.disk_chunk_size - 31);
    @memcpy(model[spore.disk_chunk_size - 31 ..][0..patch.len], &patch);
    try parent.markZeroChunk(2);
    @memset(model[2 * spore.disk_chunk_size ..][0..spore.disk_chunk_size], 0);

    var head = try parent.exportForkHead(.{
        .kind = .rootfs,
        .identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }, .{ .allow_copy = true, .force_copy = true, .quiesced = true });
    defer head.deinit();
    try std.testing.expectEqual(runtime_disk_fork.CloneMethod.copy, head.descriptor.clone_method);
    try std.testing.expectEqual(@as(u64, 2 * spore.disk_chunk_size), head.stats.copied_bytes);
    const encoded = try head.descriptor.encodeAlloc(allocator);
    defer allocator.free(encoded);
    const parsed = try runtime_disk_fork.Descriptor.parse(allocator, encoded);
    head.descriptor.deinit();
    head.descriptor = parsed;

    var child_fd = try createTempOverlayFd(allocator, runtime_overlay_dir);
    defer {
        if (child_fd >= 0) _ = std.c.close(child_fd);
    }
    var child = try ChunkMappedDisk.initWritable(allocator, base_source, child_fd, disk_size, spore.disk_chunk_size);
    defer child.deinit();
    const claimed_fd = head.overlay_fd;
    const replaced_fd = try child.applyForkDescriptor(head.descriptor, claimed_fd);
    try std.testing.expectEqual(child_fd, replaced_fd);
    _ = std.c.close(replaced_fd);
    child_fd = claimed_fd;
    head.overlay_fd = -1;

    const readback = try allocator.alloc(u8, disk_size);
    defer allocator.free(readback);
    try child.readAt(readback, 0);
    try std.testing.expectEqualSlices(u8, model, readback);

    const parent_patch = [_]u8{0xB8} ** 33;
    try parent.writeAt(&parent_patch, 7);
    try child.readAt(readback[0..parent_patch.len], 7);
    try std.testing.expectEqualSlices(u8, model[7..][0..parent_patch.len], readback[0..parent_patch.len]);

    const child_patch = [_]u8{0xC9} ** 41;
    try child.writeAt(&child_patch, spore.disk_chunk_size + 91);
    try parent.readAt(readback[0..child_patch.len], spore.disk_chunk_size + 91);
    try std.testing.expectEqualSlices(u8, model[spore.disk_chunk_size + 91 ..][0..child_patch.len], readback[0..child_patch.len]);
}

test "native portable fork head uses its configured overlay filesystem" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const overlay_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(overlay_dir);

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    const base_bytes = [_]u8{0x5A} ** spore.disk_chunk_size;
    try base.writeStreamingAll(io, &base_bytes);
    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    const overlay_fd = try createTempOverlayFd(allocator, overlay_dir);
    defer _ = std.c.close(overlay_fd);
    var disk = try ChunkMappedDisk.initWritableAt(allocator, base_source, overlay_fd, overlay_dir, base_bytes.len, spore.disk_chunk_size);
    defer disk.deinit();
    try disk.writeAt("reflink", 32);

    var head = disk.exportForkHead(.{
        .kind = .rootfs,
        .identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }, .{ .quiesced = true }) catch |err| switch (err) {
        error.FastForkUnavailable => if (builtin.os.tag == .macos) return err else return error.SkipZigTest,
        else => |e| return e,
    };
    defer head.deinit();
    try std.testing.expectEqual(runtime_disk_fork.CloneMethod.reflink, head.descriptor.clone_method);
    try runtime_disk_fork.validateOverlayFd(head.overlay_fd, head.descriptor.logical_size);
}

test "8GiB native disk fork benchmark" {
    if (std.c.getenv("SPOREVM_DISK_FORK_BENCHMARK") == null) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const overlay_dir = benchmarkOverlayDir();
    const disk_size: u64 = 8 * 1024 * 1024 * 1024;
    const logical_size = std.math.cast(std.c.off_t, disk_size) orelse return error.BadDiskSize;
    const base_fd = try createTempOverlayFd(allocator, overlay_dir);
    defer _ = std.c.close(base_fd);
    if (std.c.ftruncate(base_fd, logical_size) != 0) return error.ResizeFailed;
    const overlay_fd = try createTempOverlayFd(allocator, overlay_dir);
    defer _ = std.c.close(overlay_fd);
    if (std.c.ftruncate(overlay_fd, logical_size) != 0) return error.ResizeFailed;

    const base_source = block_source.FileBlockSource.init(base_fd, disk_size);
    var disk = try ChunkMappedDisk.initWritableAt(allocator, base_source, overlay_fd, overlay_dir, disk_size, spore.disk_chunk_size);
    defer disk.deinit();
    const write_buf = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(write_buf);
    @memset(write_buf, 0xA5);

    const coverages = [_]usize{ 0, 50, 100 };
    var materialized_chunks: usize = 0;
    for (coverages) |coverage| {
        const target_chunks = disk.sources.len * coverage / 100;
        while (materialized_chunks < target_chunks) {
            const batch_chunks = @min(write_buf.len / spore.disk_chunk_size, target_chunks - materialized_chunks);
            const batch_bytes = batch_chunks * spore.disk_chunk_size;
            const offset = @as(u64, @intCast(materialized_chunks)) * spore.disk_chunk_size;
            try writeExact(overlay_fd, write_buf[0..batch_bytes], offset);
            @memset(disk.sources[materialized_chunks .. materialized_chunks + batch_chunks], .overlay);
            materialized_chunks += batch_chunks;
        }

        const start_ns = try monotonicNs();
        var head = try disk.exportForkHead(.{
            .kind = .rootfs,
            .identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        }, .{ .quiesced = true });
        defer head.deinit();
        const elapsed_ns = (try monotonicNs()) - start_ns;
        const encoded = try head.descriptor.encodeAlloc(allocator);
        defer allocator.free(encoded);
        std.debug.print(
            "disk-fork-benchmark logical_gib=8 overlay_coverage={d}% disk_fork_ms={d:.3} reported_prepare_ms={d:.3} descriptor_bytes={d} copied_bytes={d} clone_method={s}\n",
            .{
                coverage,
                @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(head.stats.prepare_ns)) / std.time.ns_per_ms,
                encoded.len,
                head.stats.copied_bytes,
                @tagName(head.descriptor.clone_method),
            },
        );
        try std.testing.expectEqual(runtime_disk_fork.CloneMethod.reflink, head.descriptor.clone_method);
        try std.testing.expect(elapsed_ns < 100 * std.time.ns_per_ms);
    }

    var batch_heads = [_]?runtime_disk_fork.Head{null} ** 32;
    defer for (&batch_heads) |*head| {
        if (head.*) |*value| value.deinit();
    };
    const batch_start_ns = try monotonicNs();
    for (&batch_heads) |*head| {
        head.* = try disk.exportForkHead(.{
            .kind = .rootfs,
            .identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        }, .{ .quiesced = true });
    }
    const batch_elapsed_ns = (try monotonicNs()) - batch_start_ns;
    std.debug.print(
        "disk-fork-benchmark logical_gib=8 children=32 disk_fork_ms={d:.3}\n",
        .{@as(f64, @floatFromInt(batch_elapsed_ns)) / std.time.ns_per_ms},
    );
    try std.testing.expect(batch_elapsed_ns < std.time.ns_per_s);
}

fn benchmarkRandomReads(disk: *ChunkMappedDisk, offsets: []const u64, buffer: []u8) !u64 {
    const start_ns = try monotonicNs();
    for (offsets) |offset| try disk.readAt(buffer, offset);
    return (try monotonicNs()) - start_ns;
}

fn lessU64(_: void, lhs: u64, rhs: u64) bool {
    return lhs < rhs;
}

fn p95(samples: []u64) u64 {
    std.mem.sort(u64, samples, {}, lessU64);
    return samples[(samples.len * 95 + 99) / 100 - 1];
}

test "32-generation disk fork benchmark keeps warm random reads flat" {
    if (std.c.getenv("SPOREVM_DISK_FORK_BENCHMARK") == null) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const overlay_dir = benchmarkOverlayDir();
    const disk_size: u64 = 64 * 1024 * 1024;
    const logical_size: std.c.off_t = @intCast(disk_size);
    const base_fd = try createTempOverlayFd(allocator, overlay_dir);
    defer _ = std.c.close(base_fd);
    if (std.c.ftruncate(base_fd, logical_size) != 0) return error.ResizeFailed;
    const overlay_fd = try createTempOverlayFd(allocator, overlay_dir);
    defer _ = std.c.close(overlay_fd);
    if (std.c.ftruncate(overlay_fd, logical_size) != 0) return error.ResizeFailed;

    const base_source = block_source.FileBlockSource.init(base_fd, disk_size);
    var generation_zero = try ChunkMappedDisk.initWritableAt(allocator, base_source, overlay_fd, overlay_dir, disk_size, spore.disk_chunk_size);
    defer generation_zero.deinit();
    const fill = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(fill);
    @memset(fill, 0xA5);
    var fill_offset: u64 = 0;
    while (fill_offset < disk_size) : (fill_offset += fill.len) {
        try generation_zero.writeAt(fill, fill_offset);
    }

    var generations: [32]ForkedDisk = undefined;
    var initialized: usize = 0;
    defer {
        var i = initialized;
        while (i > 0) {
            i -= 1;
            generations[i].deinit();
        }
    }
    var current = &generation_zero;
    while (initialized < generations.len) : (initialized += 1) {
        generations[initialized] = try current.fork(.{ .quiesced = true });
        current = &generations[initialized].disk;
    }

    const offsets = try allocator.alloc(u64, 32768);
    defer allocator.free(offsets);
    var random: u64 = 0x9e3779b97f4a7c15;
    for (offsets) |*offset| {
        random = random *% 6364136223846793005 +% 1442695040888963407;
        offset.* = (random % (disk_size / 4096)) * 4096;
    }
    var read_buffer: [4096]u8 = undefined;
    _ = try benchmarkRandomReads(&generation_zero, offsets, &read_buffer);
    _ = try benchmarkRandomReads(current, offsets, &read_buffer);

    var generation_zero_samples: [21]u64 = undefined;
    var generation_32_samples: [21]u64 = undefined;
    for (0..generation_zero_samples.len) |i| {
        if (i % 2 == 0) {
            generation_zero_samples[i] = try benchmarkRandomReads(&generation_zero, offsets, &read_buffer);
            generation_32_samples[i] = try benchmarkRandomReads(current, offsets, &read_buffer);
        } else {
            generation_32_samples[i] = try benchmarkRandomReads(current, offsets, &read_buffer);
            generation_zero_samples[i] = try benchmarkRandomReads(&generation_zero, offsets, &read_buffer);
        }
    }
    const generation_zero_p95 = p95(&generation_zero_samples);
    const generation_32_p95 = p95(&generation_32_samples);
    std.debug.print(
        "disk-fork-benchmark random_reads=32768 generation=0 p95_ms={d:.3} generation=32 p95_ms={d:.3} ratio={d:.3}\n",
        .{
            @as(f64, @floatFromInt(generation_zero_p95)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(generation_32_p95)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(generation_32_p95)) / @as(f64, @floatFromInt(generation_zero_p95)),
        },
    );
    try std.testing.expect(generation_32_p95 <= generation_zero_p95 + generation_zero_p95 / 10);
}

fn benchmarkOverlayDir() []const u8 {
    const raw = std.c.getenv("TMPDIR") orelse return runtime_overlay_dir;
    const dir = std.mem.span(raw);
    return if (dir.len == 0) runtime_overlay_dir else dir;
}

test "sequential forks keep a flat chunk map" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base = try tmp.dir.createFile(io, "base.img", .{ .read = true });
    defer base.close(io);
    var overlay = try tmp.dir.createFile(io, "overlay.img", .{ .read = true });
    defer overlay.close(io);

    var base_bytes: [2048]u8 = undefined;
    for (&base_bytes, 0..) |*byte, i| byte.* = @truncate((i * 29) + 11);
    var parent_model = base_bytes;
    var final_model = base_bytes;
    try base.writeStreamingAll(io, &base_bytes);

    const base_source = block_source.FileBlockSource.init(base.handle, base_bytes.len);
    var disk = try ChunkMappedDisk.initWritable(std.testing.allocator, base_source, overlay.handle, base_bytes.len, 512);
    defer disk.deinit();

    const parent_patch = [_]u8{0xD4} ** 64;
    try disk.writeAt(&parent_patch, 700);
    @memcpy(parent_model[700..][0..parent_patch.len], &parent_patch);
    @memcpy(final_model[700..][0..parent_patch.len], &parent_patch);

    var forks: [32]ForkedDisk = undefined;
    var initialized: usize = 0;
    defer {
        var i = initialized;
        while (i > 0) {
            i -= 1;
            forks[i].deinit();
        }
    }

    var current: *ChunkMappedDisk = &disk;
    while (initialized < forks.len) {
        forks[initialized] = try current.fork(.{ .force_copy = true, .quiesced = true });
        initialized += 1;
        const forked = &forks[initialized - 1];
        try std.testing.expectEqual(ForkCloneMethod.copy, forked.clone_method);
        try std.testing.expectEqual(disk.chunkCount(), forked.disk.chunkCount());
        try std.testing.expectEqual(@as(usize, 1), forked.disk.dirtyChunkCount());
        current = &forked.disk;
    }

    var readback: [2048]u8 = undefined;
    try current.readAt(&readback, 0);
    try std.testing.expectEqualSlices(u8, &final_model, &readback);

    const final_patch = [_]u8{0xE5} ** 96;
    try current.writeAt(&final_patch, 1200);
    @memcpy(final_model[1200..][0..final_patch.len], &final_patch);

    try current.readAt(&readback, 0);
    try std.testing.expectEqualSlices(u8, &final_model, &readback);
    try disk.readAt(&readback, 0);
    try std.testing.expectEqualSlices(u8, &parent_model, &readback);
}
