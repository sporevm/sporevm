//! Spore manifest v0 and chunk store.
//!
//! A spore is a directory: `manifest.json` plus `chunks/<blake3-hex>` files.
//! Guest memory is stored as fixed-size content-addressed chunks with
//! all-zero chunks elided. Machine state is normalized architectural
//! aarch64 state — never raw hypervisor structures (see
//! docs/spore-format.md). v0 carries no compatibility promise.
//!
//! Manifests and chunks may come from untrusted storage: parsing is strict,
//! chunk contents are verified against their ids before use, and restore
//! fails closed on any mismatch. See SECURITY.md.

const std = @import("std");
const board = @import("board.zig");
const chunklib = @import("chunk.zig");
const generation = @import("generation.zig");
const gicv3 = @import("gicv3.zig");
const Blake3 = std.crypto.hash.Blake3;

pub const format_version: u32 = 0;
pub const chunk_size: usize = 2 * 1024 * 1024;
pub const ram_backing_kind = "map-private-file-v0";
pub const ram_backing_path = "ram.backing";

pub const Error = error{
    BadManifest,
    BadChunk,
    BadForkCount,
    AlreadyExists,
    PlatformMismatch,
    IoFailed,
    OutOfMemory,
};

pub const Platform = struct {
    arch: []const u8 = "aarch64",
    cpu_profile: []const u8,
    device_model_version: u32,
    ram_base: u64,
    ram_size: u64,
    gic_dist_base: u64,
    gic_redist_base: u64,
    /// Architected counter frequency in Hz. `machine.vtimer` values are in
    /// this tick domain; restore requires an exact match until cross-frequency
    /// timer virtualization has a real design.
    counter_frequency_hz: u64,
};

pub const QueueState = struct {
    size: u16,
    ready: bool,
    desc_addr: u64,
    avail_addr: u64,
    used_addr: u64,
    last_avail: u16,
    used_idx: u16,
};

pub const TransportState = struct {
    device_id: u32,
    status: u32,
    device_features_sel: u32,
    driver_features_sel: u32,
    driver_features: u64,
    queue_sel: u32,
    interrupt_status: u32,
    queues: []QueueState,
};

pub const VtimerState = struct {
    /// Guest virtual counter value at snapshot time.
    cntvct: u64,
    cntv_ctl: u64,
    cntv_cval: u64,
};

pub const SysRegEntry = struct {
    name: []const u8,
    value: u64,
};

pub const MachineState = struct {
    gprs: [31]u64,
    pc: u64,
    cpsr: u64,
    fpcr: u64,
    fpsr: u64,
    /// 32 Q registers as pairs of u64 (little-endian halves).
    simd: [32][2]u64,
    sys_regs: []SysRegEntry,
    /// GIC CPU-interface (ICC) registers, by architectural name.
    icc_regs: []SysRegEntry,
    vtimer: VtimerState,
    /// Interrupt controller state. Portable producers use architectural
    /// GICv3 offsets; same-backend temporary producers must tag their private
    /// blob so other backends fail closed.
    gic: gicv3.State,
};

pub const MemoryBacking = struct {
    kind: []const u8 = ram_backing_kind,
    path: []const u8,
    size: u64,
};

pub const MemoryManifest = struct {
    chunk_size: u64,
    /// One entry per chunk; null means all zeroes.
    chunks: []?[]const u8,
    /// Optional same-host acceleration hint. Chunks remain the portable,
    /// verified source of truth; backends may ignore this and materialize
    /// from chunks instead.
    backing: ?MemoryBacking = null,
};

pub const rootfs_kind = "immutable-ext4-rootfs-v0";
pub const rootfs_mode_read_only = "read-only";
pub const rootfs_device_kind_virtio_mmio = "virtio-mmio";
pub const rootfs_device_role = "rootfs";
pub const rootfs_artifact_format_ext4 = "ext4";
pub const rootfs_digest_prefix = "blake3:";
pub const rootfs_source_kind_oci_image = "oci-image";
pub const rootfs_virtio_blk_device_id: u32 = 2;

pub const RootfsDevice = struct {
    kind: []const u8 = rootfs_device_kind_virtio_mmio,
    role: []const u8 = rootfs_device_role,
    virtio_device_id: u32 = rootfs_virtio_blk_device_id,
    mmio_slot: u32,
};

pub const RootfsArtifactRef = struct {
    digest: []const u8,
    size: u64,
    format: []const u8 = rootfs_artifact_format_ext4,
};

pub const RootfsSource = struct {
    kind: []const u8 = rootfs_source_kind_oci_image,
    requested_ref: []const u8,
    resolved_image_ref: []const u8,
    image_manifest_digest: []const u8,
    platform: []const u8,
    builder_version: []const u8,
};

pub const Rootfs = struct {
    kind: []const u8 = rootfs_kind,
    mode: []const u8 = rootfs_mode_read_only,
    device: RootfsDevice,
    artifact: RootfsArtifactRef,
    source: ?RootfsSource = null,
};

pub const MemoryPlan = struct {
    chunk_size: usize,
    chunk_count: usize,
    nonzero_chunk_count: usize,
};

pub const MemoryChunkRange = struct {
    start: usize,
    end: usize,
};

pub const GenerationState = generation.State;

pub const Manifest = struct {
    version: u32 = format_version,
    platform: Platform,
    machine: MachineState,
    devices: []TransportState,
    generation: GenerationState,
    rootfs: ?Rootfs = null,
    memory: MemoryManifest,
};

// --- file helpers (libc-based; std.Io migration is a later cleanup) ---------

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

fn readFileAll(allocator: std.mem.Allocator, path: [:0]const u8, max: usize) Error![]u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);
    const size = try seekFileSize(fd);
    if (size > max) return error.BadChunk;
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    var done: usize = 0;
    while (done < size) {
        const n = std.c.read(fd, buf.ptr + done, size - done);
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
    return buf;
}

fn seekFileSize(fd: std.c.fd_t) Error!usize {
    const cur = std.c.lseek(fd, 0, std.c.SEEK.CUR);
    if (cur < 0) return error.IoFailed;
    const end = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (end < 0) return error.IoFailed;
    if (std.c.lseek(fd, cur, std.c.SEEK.SET) < 0) return error.IoFailed;
    return @intCast(end);
}

fn ensureDir(path: [:0]const u8) Error!void {
    if (std.c.mkdir(path, 0o755) != 0) {
        const err = std.posix.errno(@as(isize, -1));
        _ = err;
        // Already exists is fine; verify it is usable by probing access.
        if (std.c.access(path, 0) != 0) return error.IoFailed;
    }
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

fn realpathAlloc(allocator: std.mem.Allocator, path: []const u8) Error![]const u8 {
    const path_z = try pathZ(allocator, "{s}", .{path});
    var buf: [std.c.PATH_MAX]u8 = undefined;
    const resolved = std.c.realpath(path_z, &buf) orelse return error.IoFailed;
    return allocator.dupe(u8, std.mem.span(resolved)) catch error.OutOfMemory;
}

fn symlinkPath(target: []const u8, link_path: []const u8) Error!void {
    const target_z = try std.heap.c_allocator.dupeZ(u8, target);
    defer std.heap.c_allocator.free(target_z);
    const link_z = try std.heap.c_allocator.dupeZ(u8, link_path);
    defer std.heap.c_allocator.free(link_z);
    if (std.c.symlink(target_z, link_z) != 0) {
        if (std.c.access(link_z, 0) == 0) return error.AlreadyExists;
        return error.IoFailed;
    }
}

pub fn validateMemoryBacking(backing: MemoryBacking, expected_size: u64) Error!void {
    if (!std.mem.eql(u8, backing.kind, ram_backing_kind)) return error.BadManifest;
    if (!std.mem.eql(u8, backing.path, ram_backing_path)) return error.BadManifest;
    if (backing.size != expected_size) return error.BadManifest;
}

pub fn validateRootfs(rootfs: Rootfs, devices: []const TransportState) Error!void {
    if (!std.mem.eql(u8, rootfs.kind, rootfs_kind)) return error.BadManifest;
    if (!std.mem.eql(u8, rootfs.mode, rootfs_mode_read_only)) return error.BadManifest;
    if (!std.mem.eql(u8, rootfs.device.kind, rootfs_device_kind_virtio_mmio)) return error.BadManifest;
    if (!std.mem.eql(u8, rootfs.device.role, rootfs_device_role)) return error.BadManifest;
    if (rootfs.device.virtio_device_id != rootfs_virtio_blk_device_id) return error.BadManifest;
    if (rootfs.device.mmio_slot >= devices.len) return error.BadManifest;
    if (devices[rootfs.device.mmio_slot].device_id != rootfs_virtio_blk_device_id) return error.BadManifest;
    if (!std.mem.eql(u8, rootfs.artifact.format, rootfs_artifact_format_ext4)) return error.BadManifest;
    if (rootfs.artifact.size == 0 or rootfs.artifact.size > std.math.maxInt(usize)) return error.BadManifest;
    try validateRootfsDigest(rootfs.artifact.digest);
    if (rootfs.source) |source| try validateRootfsSource(source);
}

pub fn rootfsQueuesQuiescent(rootfs: Rootfs, devices: []const TransportState) Error!bool {
    try validateRootfs(rootfs, devices);
    const device = devices[rootfs.device.mmio_slot];
    for (device.queues) |queue| {
        if (queue.ready and queue.last_avail != queue.used_idx) return false;
    }
    return true;
}

pub fn validateRootfsDigest(digest: []const u8) Error!void {
    if (!std.mem.startsWith(u8, digest, rootfs_digest_prefix)) return error.BadManifest;
    const hex = digest[rootfs_digest_prefix.len..];
    _ = chunklib.ChunkId.fromHex(hex) catch return error.BadManifest;
}

fn validateRootfsSource(source: RootfsSource) Error!void {
    if (!std.mem.eql(u8, source.kind, rootfs_source_kind_oci_image)) return error.BadManifest;
    if (source.requested_ref.len == 0) return error.BadManifest;
    if (source.resolved_image_ref.len == 0) return error.BadManifest;
    if (source.image_manifest_digest.len == 0) return error.BadManifest;
    if (source.platform.len == 0) return error.BadManifest;
    if (source.builder_version.len == 0) return error.BadManifest;
}

pub fn memoryBackingPath(allocator: std.mem.Allocator, dir: []const u8, backing: MemoryBacking) Error![:0]const u8 {
    try validateMemoryBacking(backing, backing.size);
    return pathZ(allocator, "{s}/{s}", .{ dir, backing.path });
}

// --- save / load -------------------------------------------------------------

/// Write guest memory into the chunk store, returning the memory manifest.
pub fn saveMemory(allocator: std.mem.Allocator, dir: []const u8, ram: []const u8) Error!MemoryManifest {
    return saveMemoryInternal(allocator, dir, ram, false);
}

/// Write guest memory into the chunk store and a sparse local RAM backing.
/// The backing is a same-host acceleration hint for MAP_PRIVATE fork resumes;
/// chunks remain the portable verified source of truth.
pub fn saveMemoryWithBacking(allocator: std.mem.Allocator, dir: []const u8, ram: []const u8) Error!MemoryManifest {
    return saveMemoryInternal(allocator, dir, ram, true);
}

fn saveMemoryInternal(allocator: std.mem.Allocator, dir: []const u8, ram: []const u8, with_backing: bool) Error!MemoryManifest {
    const chunks_dir = try pathZ(allocator, "{s}/chunks", .{dir});
    try ensureDir(try pathZ(allocator, "{s}", .{dir}));
    try ensureDir(chunks_dir);

    var backing_fd: std.c.fd_t = -1;
    var backing_tmp_path: ?[:0]const u8 = null;
    if (with_backing) {
        const tmp_path = try pathZ(allocator, "{s}/{s}.tmp", .{ dir, ram_backing_path });
        backing_tmp_path = tmp_path;
        backing_fd = std.c.open(tmp_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
        if (backing_fd < 0) return error.IoFailed;
        if (std.c.ftruncate(backing_fd, @intCast(ram.len)) != 0) return error.IoFailed;
    }
    defer {
        if (backing_fd >= 0) _ = std.c.close(backing_fd);
    }

    const count = (ram.len + chunk_size - 1) / chunk_size;
    const refs = try allocator.alloc(?[]const u8, count);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const start = i * chunk_size;
        const end = @min(start + chunk_size, ram.len);
        const data = ram[start..end];
        if (std.mem.allEqual(u8, data, 0)) {
            refs[i] = null;
            continue;
        }
        const id = chunklib.ChunkId.fromContents(data);
        const hex = id.toHex();
        const ref = try allocator.dupe(u8, &hex);
        refs[i] = ref;
        const chunk_path = try pathZ(allocator, "{s}/chunks/{s}", .{ dir, ref });
        if (std.c.access(chunk_path, 0) != 0) {
            try writeFileAll(chunk_path, data);
        }
        if (backing_fd >= 0) {
            try pwriteFileAll(backing_fd, start, data);
        }
    }

    const backing = if (with_backing) blk: {
        if (std.c.fchmod(backing_fd, 0o444) != 0) return error.IoFailed;
        _ = std.c.close(backing_fd);
        backing_fd = -1;
        const final_path = try pathZ(allocator, "{s}/{s}", .{ dir, ram_backing_path });
        if (std.c.rename(backing_tmp_path.?.ptr, final_path.ptr) != 0) return error.IoFailed;
        break :blk MemoryBacking{ .path = ram_backing_path, .size = ram.len };
    } else null;

    return .{ .chunk_size = chunk_size, .chunks = refs, .backing = backing };
}

/// Materialize guest memory from the chunk store. Verifies every chunk
/// against its id; fails closed on mismatch.
pub fn loadMemory(allocator: std.mem.Allocator, dir: []const u8, manifest: MemoryManifest, ram: []u8) Error!void {
    const plan = try validateMemoryForRam(manifest, ram.len);

    var i: usize = 0;
    while (i < plan.chunk_count) : (i += 1) {
        const range = memoryChunkRangeFromPlan(plan, ram.len, i) catch return error.BadManifest;
        try loadMemoryChunkRef(allocator, dir, manifest.chunks[i], ram[range.start..range.end]);
    }
}

pub fn validateMemoryForRam(manifest: MemoryManifest, ram_len: usize) Error!MemoryPlan {
    if (manifest.chunk_size != chunk_size) return error.BadManifest;
    const csize: usize = chunk_size;
    const expected = (ram_len + csize - 1) / csize;
    if (manifest.chunks.len != expected) return error.BadManifest;

    var nonzero: usize = 0;
    for (manifest.chunks) |maybe_ref| {
        if (maybe_ref) |ref| {
            _ = chunklib.ChunkId.fromHex(ref) catch return error.BadManifest;
            nonzero += 1;
        }
    }
    return .{ .chunk_size = csize, .chunk_count = manifest.chunks.len, .nonzero_chunk_count = nonzero };
}

pub fn memoryChunkRange(manifest: MemoryManifest, ram_len: usize, index: usize) Error!MemoryChunkRange {
    const plan = try validateMemoryForRam(manifest, ram_len);
    return memoryChunkRangeFromPlan(plan, ram_len, index) catch return error.BadManifest;
}

pub fn loadMemoryChunk(allocator: std.mem.Allocator, dir: []const u8, manifest: MemoryManifest, ram_len: usize, index: usize, target: []u8) Error!void {
    const range = try memoryChunkRange(manifest, ram_len, index);
    if (target.len != range.end - range.start) return error.BadManifest;
    try loadMemoryChunkRef(allocator, dir, manifest.chunks[index], target);
}

fn memoryChunkRangeFromPlan(plan: MemoryPlan, ram_len: usize, index: usize) !MemoryChunkRange {
    if (index >= plan.chunk_count) return error.BadManifest;
    const start = index * plan.chunk_size;
    const end = @min(start + plan.chunk_size, ram_len);
    return .{ .start = start, .end = end };
}

fn loadMemoryChunkRef(allocator: std.mem.Allocator, dir: []const u8, maybe_ref: ?[]const u8, target: []u8) Error!void {
    if (maybe_ref) |ref| {
        const id = chunklib.ChunkId.fromHex(ref) catch return error.BadManifest;
        const chunk_path = try pathZ(allocator, "{s}/chunks/{s}", .{ dir, ref });
        const data = try readFileAll(allocator, chunk_path, target.len);
        defer allocator.free(data);
        if (data.len != target.len) return error.BadChunk;
        if (!id.matches(data)) return error.BadChunk;
        @memcpy(target, data);
    } else {
        @memset(target, 0);
    }
}

pub fn saveManifest(allocator: std.mem.Allocator, dir: []const u8, manifest: Manifest) Error!void {
    const path = try pathZ(allocator, "{s}/manifest.json", .{dir});
    try saveManifestPath(allocator, path, manifest);
}

pub fn saveManifestPath(allocator: std.mem.Allocator, path: []const u8, manifest: Manifest) Error!void {
    const json = std.json.Stringify.valueAlloc(allocator, manifest, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
    defer allocator.free(json);
    const path_z = try pathZ(allocator, "{s}", .{path});
    try writeFileAll(path_z, json);
}

pub fn loadManifest(allocator: std.mem.Allocator, dir: []const u8) Error!std.json.Parsed(Manifest) {
    const path = try pathZ(allocator, "{s}/manifest.json", .{dir});
    return loadManifestPath(allocator, path);
}

pub fn loadManifestPath(allocator: std.mem.Allocator, path: []const u8) Error!std.json.Parsed(Manifest) {
    const path_z = try pathZ(allocator, "{s}", .{path});
    const bytes = try readFileAll(allocator, path_z, 64 * 1024 * 1024);
    defer allocator.free(bytes);
    const parsed = std.json.parseFromSlice(Manifest, allocator, bytes, .{
        // The byte buffer is freed before the parse result is used.
        .allocate = .alloc_always,
    }) catch return error.BadManifest;
    errdefer parsed.deinit();
    validateManifest(parsed.value) catch return error.BadManifest;
    return parsed;
}

pub const ForkOptions = struct {
    parent_dir: []const u8,
    out_dir: []const u8,
    count: usize,
};

pub const ForkResult = struct {
    parent: []const u8,
    out_dir: []const u8,
    count: usize,
    parent_generation: u64,
    first_generation: u64,
    last_generation: u64,
    first_child: []const u8,
    last_child: []const u8,
};

pub fn fork(allocator: std.mem.Allocator, options: ForkOptions) Error!ForkResult {
    if (options.count == 0) return error.BadForkCount;

    const parsed = try loadManifest(allocator, options.parent_dir);
    defer parsed.deinit();
    const parent = parsed.value;
    if (parent.generation.generation > std.math.maxInt(u64) - options.count) return error.BadForkCount;

    const parent_chunks = try pathZ(allocator, "{s}/chunks", .{options.parent_dir});
    const shared_chunks = try realpathAlloc(allocator, parent_chunks);
    var shared_backing: ?[]const u8 = null;
    if (parent.memory.backing) |backing| {
        const parent_backing = try memoryBackingPath(allocator, options.parent_dir, backing);
        shared_backing = realpathAlloc(allocator, parent_backing) catch |err| switch (err) {
            error.IoFailed => null,
            else => |e| return e,
        };
    }
    try ensureDir(try pathZ(allocator, "{s}", .{options.out_dir}));

    const fork_batch_id = try randomHex(allocator, 16);

    var i: usize = 0;
    while (i < options.count) : (i += 1) {
        const child_dir = try pathZ(allocator, "{s}/{d:0>6}", .{ options.out_dir, i });
        try ensureNewDir(child_dir);
        const chunks_link = try pathZ(allocator, "{s}/chunks", .{child_dir});
        try symlinkPath(shared_chunks, chunks_link);
        var child = parent;
        if (shared_backing == null) child.memory.backing = null;
        if (child.memory.backing) |backing| {
            const backing_link = try pathZ(allocator, "{s}/{s}", .{ child_dir, backing.path });
            try symlinkPath(shared_backing.?, backing_link);
        }

        const child_generation = parent.generation.generation + i + 1;
        const identity = try childIdentity(allocator, fork_batch_id, i);
        const params_b64 = try forkParamsB64(allocator, .{
            .schema_version = 0,
            .parent_generation = parent.generation.generation,
            .generation = child_generation,
            .fork_index = i,
            .fork_count = options.count,
            .parallel_index = i,
            .parallel_count = options.count,
            .fork_batch_id = fork_batch_id,
            .vm_id = identity.vm_id,
            .hostname = identity.hostname,
            .mac_seed = identity.mac_seed,
            .mac_address = identity.mac_address,
        });
        defer allocator.free(params_b64);
        child.generation = .{
            .generation = child_generation,
            .interrupt_status = generation.irq_generation_changed,
            .params_b64 = params_b64,
        };
        child.machine.gic = try forkGicState(allocator, parent.machine.gic);
        try saveManifest(allocator, child_dir, child);
    }

    const first_child = try std.fmt.allocPrint(allocator, "{s}/{d:0>6}", .{ options.out_dir, 0 });
    const last_child = try std.fmt.allocPrint(allocator, "{s}/{d:0>6}", .{ options.out_dir, options.count - 1 });
    return .{
        .parent = options.parent_dir,
        .out_dir = options.out_dir,
        .count = options.count,
        .parent_generation = parent.generation.generation,
        .first_generation = parent.generation.generation + 1,
        .last_generation = parent.generation.generation + options.count,
        .first_child = first_child,
        .last_child = last_child,
    };
}

const ForkStableParams = struct {
    schema_version: u32,
    parent_generation: u64,
    generation: u64,
    fork_index: usize,
    fork_count: usize,
    parallel_index: usize,
    parallel_count: usize,
    fork_batch_id: []const u8,
    vm_id: []const u8,
    hostname: []const u8,
    mac_seed: []const u8,
    mac_address: []const u8,
};

const ForkResumeParams = struct {
    schema_version: u32,
    parent_generation: u64,
    generation: u64,
    fork_index: usize,
    fork_count: usize,
    parallel_index: usize,
    parallel_count: usize,
    fork_batch_id: []const u8,
    vm_id: []const u8,
    hostname: []const u8,
    mac_seed: []const u8,
    mac_address: []const u8,
    resume_time_unix_ns: u64,
    resume_entropy_seed: []const u8,
};

const ChildIdentity = struct {
    vm_id: []const u8,
    hostname: []const u8,
    mac_seed: []const u8,
    mac_address: []const u8,
};

fn forkParamsB64(allocator: std.mem.Allocator, payload: ForkStableParams) Error![]const u8 {
    const json = std.json.Stringify.valueAlloc(allocator, payload, .{}) catch return error.OutOfMemory;
    defer allocator.free(json);
    if (json.len > generation.params_size) return error.BadManifest;

    const enc = std.base64.standard.Encoder;
    const out = allocator.alloc(u8, enc.calcSize(json.len)) catch return error.OutOfMemory;
    _ = enc.encode(out, json);
    return out;
}

/// Add resume-time volatile fields to the generation parameter page. Forked
/// manifests carry stable child identity; entropy and wall-clock samples are
/// minted only when a child actually resumes on a host.
pub fn refreshResumeParams(allocator: std.mem.Allocator, gen_dev: *generation.Device) Error!void {
    var end = gen_dev.params.len;
    while (end > 0 and gen_dev.params[end - 1] == 0) : (end -= 1) {}
    if (end == 0) return;

    const parsed = std.json.parseFromSlice(ForkStableParams, allocator, gen_dev.params[0..end], .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.BadManifest;
    defer parsed.deinit();
    if (parsed.value.schema_version != 0) return error.BadManifest;

    const entropy_seed = try randomHex(allocator, 16);
    defer allocator.free(entropy_seed);
    const payload = ForkResumeParams{
        .schema_version = parsed.value.schema_version,
        .parent_generation = parsed.value.parent_generation,
        .generation = parsed.value.generation,
        .fork_index = parsed.value.fork_index,
        .fork_count = parsed.value.fork_count,
        .parallel_index = parsed.value.parallel_index,
        .parallel_count = parsed.value.parallel_count,
        .fork_batch_id = parsed.value.fork_batch_id,
        .vm_id = parsed.value.vm_id,
        .hostname = parsed.value.hostname,
        .mac_seed = parsed.value.mac_seed,
        .mac_address = parsed.value.mac_address,
        .resume_time_unix_ns = try realtimeUnixNs(),
        .resume_entropy_seed = entropy_seed,
    };

    const json = std.json.Stringify.valueAlloc(allocator, payload, .{}) catch return error.OutOfMemory;
    defer allocator.free(json);
    _ = gen_dev.setResume(parsed.value.generation, json) catch return error.BadManifest;
}

fn childIdentity(allocator: std.mem.Allocator, fork_batch_id: []const u8, fork_index: usize) Error!ChildIdentity {
    const input = std.fmt.allocPrint(allocator, "{s}:{d}", .{ fork_batch_id, fork_index }) catch return error.OutOfMemory;
    defer allocator.free(input);

    var digest: [Blake3.digest_length]u8 = undefined;
    Blake3.hash(input, &digest, .{});

    const vm_id_hex = try hexAlloc(allocator, digest[0..16]);
    const vm_id = std.fmt.allocPrint(allocator, "spore-{s}", .{vm_id_hex}) catch return error.OutOfMemory;
    const hostname = std.fmt.allocPrint(allocator, "spore-{s}-{d:0>6}", .{ fork_batch_id[0..8], fork_index }) catch return error.OutOfMemory;
    const mac_seed = try hexAlloc(allocator, digest[16..32]);
    var mac: [6]u8 = digest[0..6].*;
    mac[0] = (mac[0] | 0x02) & 0xfe; // locally administered, unicast
    const mac_address = try macString(allocator, mac);
    return .{
        .vm_id = vm_id,
        .hostname = hostname,
        .mac_seed = mac_seed,
        .mac_address = mac_address,
    };
}

fn randomHex(allocator: std.mem.Allocator, comptime byte_count: usize) Error![]const u8 {
    var bytes: [byte_count]u8 = undefined;
    try fillRandom(&bytes);
    return hexAlloc(allocator, &bytes);
}

fn fillRandom(out: []u8) Error!void {
    const fd = std.c.open("/dev/urandom", .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);

    var done: usize = 0;
    while (done < out.len) {
        const n = std.c.read(fd, out.ptr + done, out.len - done);
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
}

fn realtimeUnixNs() Error!u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return error.IoFailed;
    if (ts.sec < 0 or ts.nsec < 0) return error.IoFailed;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn hexAlloc(allocator: std.mem.Allocator, bytes: []const u8) Error![]const u8 {
    const digits = "0123456789abcdef";
    const out = allocator.alloc(u8, bytes.len * 2) catch return error.OutOfMemory;
    for (bytes, 0..) |byte, i| {
        out[i * 2] = digits[byte >> 4];
        out[i * 2 + 1] = digits[byte & 0x0f];
    }
    return out;
}

fn macString(allocator: std.mem.Allocator, mac: [6]u8) Error![]const u8 {
    const hex = try hexAlloc(allocator, &mac);
    return std.fmt.allocPrint(allocator, "{s}:{s}:{s}:{s}:{s}:{s}", .{
        hex[0..2],
        hex[2..4],
        hex[4..6],
        hex[6..8],
        hex[8..10],
        hex[10..12],
    }) catch return error.OutOfMemory;
}

fn forkGicState(allocator: std.mem.Allocator, state: gicv3.State) Error!gicv3.State {
    if (state.kind != .gicv3) return state;

    const gic = state.gicv3 orelse return error.BadManifest;
    var has_generation_line = false;
    for (gic.line_levels) |line| {
        if (line.intid == board.generationIntid()) {
            has_generation_line = true;
            break;
        }
    }

    const next_len = gic.line_levels.len + @intFromBool(!has_generation_line);
    const line_levels = allocator.alloc(gicv3.LineLevel, next_len) catch return error.OutOfMemory;
    for (gic.line_levels, 0..) |line, i| {
        line_levels[i] = if (line.intid == board.generationIntid()) .{
            .intid = line.intid,
            .asserted = true,
        } else line;
    }
    if (!has_generation_line) {
        line_levels[gic.line_levels.len] = .{ .intid = board.generationIntid(), .asserted = true };
    }

    return .{
        .kind = .gicv3,
        .gicv3 = .{
            .schema_version = gic.schema_version,
            .dist_regs = gic.dist_regs,
            .redist_regs = gic.redist_regs,
            .line_levels = line_levels,
        },
    };
}

fn validateManifest(manifest: Manifest) Error!void {
    if (manifest.version != format_version) return error.BadManifest;
    if (manifest.platform.cpu_profile.len == 0) return error.BadManifest;
    if (manifest.platform.counter_frequency_hz == 0 or
        manifest.platform.counter_frequency_hz > std.math.maxInt(u32))
    {
        return error.BadManifest;
    }
    if (manifest.platform.ram_size > std.math.maxInt(usize)) return error.BadManifest;
    _ = try validateMemoryForRam(manifest.memory, @intCast(manifest.platform.ram_size));
    if (manifest.memory.backing) |backing| {
        try validateMemoryBacking(backing, manifest.platform.ram_size);
    }
    if (manifest.rootfs) |rootfs| {
        try validateRootfs(rootfs, manifest.devices);
    }
    gicv3.validate(manifest.machine.gic) catch return error.BadManifest;
}

// --- tests ------------------------------------------------------------------

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

fn testDir(allocator: std.mem.Allocator) ![]const u8 {
    const tmpl = "/tmp/sporevm-test-XXXXXX";
    const buf = try allocator.dupeZ(u8, tmpl);
    if (mkdtemp(buf) == null) return error.IoFailed;
    return buf;
}

test "memory round-trips through the chunk store with zero elision" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);

    const ram = try arena.alloc(u8, 5 * chunk_size + 1234);
    @memset(ram, 0);
    ram[0] = 1; // chunk 0 non-zero
    ram[3 * chunk_size + 7] = 0xCC; // chunk 3 non-zero
    ram[ram.len - 1] = 0xEE; // tail chunk non-zero

    const mm = try saveMemory(arena, dir, ram);
    try std.testing.expectEqual(@as(usize, 6), mm.chunks.len);
    try std.testing.expect(mm.chunks[0] != null);
    try std.testing.expect(mm.chunks[1] == null);
    try std.testing.expect(mm.chunks[3] != null);
    try std.testing.expect(mm.chunks[5] != null);
    const plan = try validateMemoryForRam(mm, ram.len);
    try std.testing.expectEqual(@as(usize, chunk_size), plan.chunk_size);
    try std.testing.expectEqual(@as(usize, 6), plan.chunk_count);
    try std.testing.expectEqual(@as(usize, 3), plan.nonzero_chunk_count);
    const tail_range = try memoryChunkRange(mm, ram.len, 5);
    try std.testing.expectEqual(@as(usize, 5 * chunk_size), tail_range.start);
    try std.testing.expectEqual(ram.len, tail_range.end);

    const out = try arena.alloc(u8, ram.len);
    @memset(out, 0xAA);
    try loadMemory(arena, dir, mm, out);
    try std.testing.expectEqualSlices(u8, ram, out);

    const zero_chunk = try arena.alloc(u8, chunk_size);
    @memset(zero_chunk, 0xAA);
    try loadMemoryChunk(arena, dir, mm, ram.len, 1, zero_chunk);
    try std.testing.expect(std.mem.allEqual(u8, zero_chunk, 0));

    const nonzero_chunk = try arena.alloc(u8, chunk_size);
    @memset(nonzero_chunk, 0xAA);
    try loadMemoryChunk(arena, dir, mm, ram.len, 3, nonzero_chunk);
    try std.testing.expectEqualSlices(u8, ram[3 * chunk_size .. 4 * chunk_size], nonzero_chunk);

    const tail_chunk = try arena.alloc(u8, ram.len - 5 * chunk_size);
    @memset(tail_chunk, 0xAA);
    try loadMemoryChunk(arena, dir, mm, ram.len, 5, tail_chunk);
    try std.testing.expectEqualSlices(u8, ram[5 * chunk_size ..], tail_chunk);
}

test "memory backing is sparse local acceleration metadata" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);

    const ram = try arena.alloc(u8, 3 * chunk_size + 17);
    @memset(ram, 0);
    ram[11] = 0xAB;
    ram[2 * chunk_size + 9] = 0xCD;

    const mm = try saveMemoryWithBacking(arena, dir, ram);
    const backing = mm.backing orelse return error.BadManifest;
    try std.testing.expectEqualStrings(ram_backing_kind, backing.kind);
    try std.testing.expectEqualStrings(ram_backing_path, backing.path);
    try std.testing.expectEqual(@as(u64, ram.len), backing.size);
    try validateMemoryBacking(backing, ram.len);

    const backing_path = try memoryBackingPath(arena, dir, backing);
    const backing_bytes = try readFileAll(arena, backing_path, ram.len);
    try std.testing.expectEqualSlices(u8, ram, backing_bytes);

    const out = try arena.alloc(u8, ram.len);
    @memset(out, 0xAA);
    try loadMemory(arena, dir, mm, out);
    try std.testing.expectEqualSlices(u8, ram, out);
}

test "memory backing rejects non-canonical paths" {
    const valid_size: u64 = 4096;
    const invalid_paths = [_][]const u8{
        "",
        ".",
        "..",
        "chunks",
        "manifest.json",
        "ram.backing.tmp",
        "nested/ram.backing",
        "ram.backing\x00suffix",
    };
    for (invalid_paths) |path| {
        try std.testing.expectError(error.BadManifest, validateMemoryBacking(.{
            .path = path,
            .size = valid_size,
        }, valid_size));
    }
}

test "memory manifest validation rejects non-canonical chunks" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    const ram = try arena.alloc(u8, chunk_size);
    @memset(ram, 0x42);
    const mm = try saveMemory(arena, dir, ram);

    var wrong_size = mm;
    wrong_size.chunk_size = chunk_size / 2;
    try std.testing.expectError(error.BadManifest, validateMemoryForRam(wrong_size, ram.len));

    var malformed_refs = try arena.alloc(?[]const u8, mm.chunks.len);
    @memcpy(malformed_refs, mm.chunks);
    malformed_refs[0] = "not-a-blake3-id";
    var malformed = mm;
    malformed.chunks = malformed_refs;
    try std.testing.expectError(error.BadManifest, validateMemoryForRam(malformed, ram.len));
    try std.testing.expectError(error.BadManifest, loadMemory(arena, dir, malformed, ram));
}

test "corrupted chunk fails closed" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    const ram = try arena.alloc(u8, chunk_size);
    @memset(ram, 0x42);
    const mm = try saveMemory(arena, dir, ram);

    // Corrupt the stored chunk.
    const chunk_path = try pathZ(arena, "{s}/chunks/{s}", .{ dir, mm.chunks[0].? });
    const data = try readFileAll(arena, chunk_path, chunk_size);
    data[100] ^= 0xFF;
    try writeFileAll(chunk_path, data);

    const out = try arena.alloc(u8, ram.len);
    try std.testing.expectError(error.BadChunk, loadMemory(arena, dir, mm, out));
    try std.testing.expectError(error.BadChunk, loadMemoryChunk(arena, dir, mm, ram.len, 0, out));
}

fn fuzzManifestParse(_: void, s: *std.testing.Smith) !void {
    // Manifests come from untrusted storage: parsing must never crash and
    // must either fail or produce a structurally valid manifest.
    var buf: [4096]u8 = undefined;
    const len = s.slice(&buf);
    const parsed = std.json.parseFromSlice(Manifest, std.testing.allocator, buf[0..len], .{
        .allocate = .alloc_always,
    }) catch return;
    parsed.deinit();
}

test "fuzz manifest parsing" {
    try std.testing.fuzz({}, fuzzManifestParse, .{});
}

fn fuzzMemoryManifest(_: void, s: *std.testing.Smith) !void {
    // Hostile memory manifests must fail closed, never read outside the
    // chunk store or write outside the target buffer.
    var ram: [4096]u8 = undefined;
    var ref_buf: [128]u8 = undefined;
    const ref_len = s.slice(&ref_buf);
    var refs: [4]?[]const u8 = .{ null, null, null, null };
    if (ref_len > 0) refs[0] = ref_buf[0..ref_len];
    const mm = MemoryManifest{
        .chunk_size = s.value(u64),
        .chunks = &refs,
    };
    _ = loadMemory(std.testing.allocator, "/nonexistent-spore", mm, &ram) catch return;
}

test "fuzz memory manifest handling" {
    try std.testing.fuzz({}, fuzzMemoryManifest, .{});
}

test "manifest json round-trip" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    var memory_chunks = [_]?[]const u8{null} ** ((1 << 29) / chunk_size);
    var queues = [_]QueueState{.{
        .size = 64,
        .ready = true,
        .desc_addr = 0x1000,
        .avail_addr = 0x2000,
        .used_addr = 0x3000,
        .last_avail = 7,
        .used_idx = 7,
    }};
    var devices = [_]TransportState{.{
        .device_id = 3,
        .status = 0xf,
        .device_features_sel = 0,
        .driver_features_sel = 1,
        .driver_features = 1 << 32,
        .queue_sel = 1,
        .interrupt_status = 0,
        .queues = &queues,
    }};
    var sys_regs = [_]SysRegEntry{.{ .name = "sctlr_el1", .value = 0xdeadbeef }};
    const manifest = Manifest{
        .platform = .{
            .cpu_profile = "sporevm-aarch64-v0",
            .device_model_version = 4,
            .ram_base = 0x8000_0000,
            .ram_size = 1 << 29,
            .gic_dist_base = 0x0800_0000,
            .gic_redist_base = 0x0801_0000,
            .counter_frequency_hz = 24_000_000,
        },
        .machine = .{
            .gprs = [_]u64{0} ** 31,
            .pc = 0xffff_ffc0_0000_0000,
            .cpsr = 0x3c5,
            .fpcr = 0,
            .fpsr = 0,
            .simd = [_][2]u64{.{ 0, 0 }} ** 32,
            .sys_regs = &sys_regs,
            .icc_regs = &.{},
            .vtimer = .{ .cntvct = 123, .cntv_ctl = 1, .cntv_cval = 456 },
            .gic = .{
                .kind = .gicv3,
                .gicv3 = .{
                    .dist_regs = &.{.{ .offset = gicv3.distRouterOffset(32), .width_bits = 64, .value = 0 }},
                    .redist_regs = &.{.{ .offset = 0x10080, .width_bits = 32, .value = 0 }},
                    .line_levels = &.{.{ .intid = 16, .asserted = false }},
                },
            },
        },
        .devices = &devices,
        .generation = .{
            .generation = 7,
            .interrupt_status = generation.irq_generation_changed,
            .params_b64 = "",
        },
        .memory = .{ .chunk_size = chunk_size, .chunks = &memory_chunks },
    };
    try saveManifest(arena, dir, manifest);
    const parsed = try loadManifest(arena, dir);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 0), parsed.value.version);
    try std.testing.expectEqualStrings("sporevm-aarch64-v0", parsed.value.platform.cpu_profile);
    try std.testing.expectEqual(@as(u64, 0x8000_0000), parsed.value.platform.ram_base);
    try std.testing.expectEqual(@as(u64, 24_000_000), parsed.value.platform.counter_frequency_hz);
    try std.testing.expectEqual(@as(u64, 123), parsed.value.machine.vtimer.cntvct);
    try std.testing.expectEqualStrings("sctlr_el1", parsed.value.machine.sys_regs[0].name);
    try std.testing.expectEqual(gicv3.StateKind.gicv3, parsed.value.machine.gic.kind);
    try std.testing.expectEqual(@as(u32, gicv3.distRouterOffset(32)), parsed.value.machine.gic.gicv3.?.dist_regs[0].offset);
    try std.testing.expectEqual(@as(u16, 64), parsed.value.devices[0].queues[0].size);
    try std.testing.expectEqual(@as(u64, 7), parsed.value.generation.generation);
}

fn testTransport(device_id: u32) TransportState {
    return .{
        .device_id = device_id,
        .status = 0,
        .device_features_sel = 0,
        .driver_features_sel = 0,
        .driver_features = 0,
        .queue_sel = 0,
        .interrupt_status = 0,
        .queues = &.{},
    };
}

fn testRootfs(mmio_slot: u32) Rootfs {
    return .{
        .device = .{ .mmio_slot = mmio_slot },
        .artifact = .{
            .digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .size = 4096,
        },
        .source = .{
            .requested_ref = "docker.io/library/ruby:3.3",
            .resolved_image_ref = "docker.io/library/ruby@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            .image_manifest_digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            .platform = "linux/arm64",
            .builder_version = "sporevm-rootfs-v1",
        },
    };
}

test "manifest rootfs artifact validates transport binding" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    var memory_chunks = [_]?[]const u8{null} ** ((1 << 29) / chunk_size);
    var devices = [_]TransportState{
        testTransport(3),
        testTransport(rootfs_virtio_blk_device_id),
    };
    var manifest = testForkManifest(.{ .chunk_size = chunk_size, .chunks = &memory_chunks }, 1 << 29, 3);
    manifest.devices = &devices;
    manifest.rootfs = testRootfs(1);

    try saveManifest(arena, dir, manifest);
    const parsed = try loadManifest(arena, dir);
    defer parsed.deinit();
    const rootfs = parsed.value.rootfs orelse return error.BadManifest;
    try std.testing.expectEqual(@as(u32, 1), rootfs.device.mmio_slot);
    try std.testing.expectEqualStrings("blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", rootfs.artifact.digest);
    try std.testing.expect(try rootfsQueuesQuiescent(rootfs, manifest.devices));

    manifest.rootfs.?.device.mmio_slot = 0;
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    manifest.rootfs.?.device.mmio_slot = 1;
    manifest.rootfs.?.artifact.digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));

    var pending_queue = [_]QueueState{.{
        .size = 64,
        .ready = true,
        .desc_addr = 0x1000,
        .avail_addr = 0x2000,
        .used_addr = 0x3000,
        .last_avail = 2,
        .used_idx = 1,
    }};
    devices[1].queues = &pending_queue;
    manifest.rootfs.?.artifact.digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expect(!try rootfsQueuesQuiescent(manifest.rootfs.?, manifest.devices));
}

const test_fork_line_levels = [_]gicv3.LineLevel{.{ .intid = board.generationIntid(), .asserted = false }};

fn testForkManifest(memory: MemoryManifest, ram_size: u64, initial_generation: u64) Manifest {
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
                    .line_levels = &test_fork_line_levels,
                },
            },
        },
        .devices = &.{},
        .generation = .{ .generation = initial_generation, .interrupt_status = 0, .params_b64 = "" },
        .memory = memory,
    };
}

test "fork mints child manifests with shared chunks and pending generation" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const out_dir = try pathZ(arena, "{s}/children", .{root_dir});

    const ram = try arena.alloc(u8, chunk_size + 8);
    @memset(ram, 0);
    ram[0] = 0x42;
    ram[ram.len - 1] = 0x99;
    const memory = try saveMemoryWithBacking(arena, parent_dir, ram);

    var devices = [_]TransportState{
        testTransport(3),
        testTransport(rootfs_virtio_blk_device_id),
    };
    var parent_manifest = testForkManifest(memory, ram.len, 41);
    parent_manifest.devices = &devices;
    parent_manifest.rootfs = testRootfs(1);
    try saveManifest(arena, parent_dir, parent_manifest);

    const result = try fork(arena, .{ .parent_dir = parent_dir, .out_dir = out_dir, .count = 2 });
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqual(@as(u64, 41), result.parent_generation);
    try std.testing.expectEqual(@as(u64, 42), result.first_generation);
    try std.testing.expectEqual(@as(u64, 43), result.last_generation);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}/000000", .{out_dir}), result.first_child);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}/000001", .{out_dir}), result.last_child);

    const first_child_dir = try pathZ(arena, "{s}/000000", .{out_dir});
    const first = try loadManifest(arena, first_child_dir);
    defer first.deinit();
    try std.testing.expectEqual(@as(u64, 42), first.value.generation.generation);
    try std.testing.expectEqual(@as(u32, generation.irq_generation_changed), first.value.generation.interrupt_status);
    try std.testing.expect(first.value.generation.params_b64.len > 0);
    try std.testing.expect(first.value.machine.gic.gicv3.?.line_levels[0].asserted);
    try std.testing.expect(first.value.rootfs != null);
    try std.testing.expectEqualStrings(parent_manifest.rootfs.?.artifact.digest, first.value.rootfs.?.artifact.digest);
    const first_backing = first.value.memory.backing orelse return error.BadManifest;
    try std.testing.expectEqualStrings(ram_backing_path, first_backing.path);
    const first_backing_path = try memoryBackingPath(arena, first_child_dir, first_backing);
    try std.testing.expectEqual(@as(c_int, 0), std.c.access(first_backing_path, 0));

    const second_child_dir = try pathZ(arena, "{s}/000001", .{out_dir});
    const second = try loadManifest(arena, second_child_dir);
    defer second.deinit();
    try std.testing.expectEqual(@as(u64, 43), second.value.generation.generation);

    const dec = std.base64.standard.Decoder;
    const decoded_size = try dec.calcSizeForSlice(second.value.generation.params_b64);
    const decoded = try arena.alloc(u8, decoded_size);
    try dec.decode(decoded, second.value.generation.params_b64);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"fork_index\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"fork_count\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"parallel_index\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"parallel_count\":2") != null);
    const stable = try std.json.parseFromSlice(ForkStableParams, arena, decoded, .{ .allocate = .alloc_always });
    defer stable.deinit();
    try std.testing.expectEqual(@as(u32, 0), stable.value.schema_version);
    try std.testing.expectEqual(@as(u64, 41), stable.value.parent_generation);
    try std.testing.expectEqual(@as(u64, 43), stable.value.generation);
    try std.testing.expectEqual(@as(usize, 1), stable.value.fork_index);
    try std.testing.expectEqual(@as(usize, 2), stable.value.fork_count);
    try std.testing.expectEqual(@as(usize, 1), stable.value.parallel_index);
    try std.testing.expectEqual(@as(usize, 2), stable.value.parallel_count);
    try std.testing.expectEqual(@as(usize, 32), stable.value.fork_batch_id.len);
    try std.testing.expect(std.mem.startsWith(u8, stable.value.vm_id, "spore-"));
    try std.testing.expect(std.mem.startsWith(u8, stable.value.hostname, "spore-"));
    try std.testing.expectEqual(@as(usize, 32), stable.value.mac_seed.len);
    try std.testing.expectEqual(@as(usize, 17), stable.value.mac_address.len);

    var gen_dev = generation.Device{};
    try gen_dev.restore(arena, second.value.generation);
    try refreshResumeParams(arena, &gen_dev);
    try std.testing.expectEqual(@as(u32, generation.irq_generation_changed), gen_dev.interrupt_status);
    var params_end = gen_dev.params.len;
    while (params_end > 0 and gen_dev.params[params_end - 1] == 0) : (params_end -= 1) {}
    const resumed_params = try std.json.parseFromSlice(ForkResumeParams, arena, gen_dev.params[0..params_end], .{ .allocate = .alloc_always });
    defer resumed_params.deinit();
    try std.testing.expectEqualStrings(stable.value.vm_id, resumed_params.value.vm_id);
    try std.testing.expectEqualStrings(stable.value.hostname, resumed_params.value.hostname);
    try std.testing.expectEqual(@as(usize, 1), resumed_params.value.parallel_index);
    try std.testing.expectEqual(@as(usize, 2), resumed_params.value.parallel_count);
    try std.testing.expect(resumed_params.value.resume_time_unix_ns > 0);
    try std.testing.expectEqual(@as(usize, 32), resumed_params.value.resume_entropy_seed.len);

    const out = try arena.alloc(u8, ram.len);
    @memset(out, 0);
    try loadMemory(arena, second_child_dir, second.value.memory, out);
    try std.testing.expectEqualSlices(u8, ram, out);
}

test "fork drops stale optional memory backing" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const out_dir = try pathZ(arena, "{s}/children", .{root_dir});

    const ram = try arena.alloc(u8, chunk_size);
    @memset(ram, 0x5A);
    var memory = try saveMemory(arena, parent_dir, ram);
    memory.backing = .{ .path = ram_backing_path, .size = ram.len };
    try saveManifest(arena, parent_dir, testForkManifest(memory, ram.len, 9));

    _ = try fork(arena, .{ .parent_dir = parent_dir, .out_dir = out_dir, .count = 1 });
    const child_dir = try pathZ(arena, "{s}/000000", .{out_dir});
    const child = try loadManifest(arena, child_dir);
    defer child.deinit();
    try std.testing.expect(child.value.memory.backing == null);

    const out = try arena.alloc(u8, ram.len);
    @memset(out, 0);
    try loadMemory(arena, child_dir, child.value.memory, out);
    try std.testing.expectEqualSlices(u8, ram, out);
}

test "fork rejects empty count" {
    try std.testing.expectError(error.BadForkCount, fork(std.testing.allocator, .{
        .parent_dir = "/does/not/matter",
        .out_dir = "/does/not/matter-either",
        .count = 0,
    }));
}

test "backend-private GIC state json round-trip" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    var memory_chunks = [_]?[]const u8{null} ** ((1 << 29) / chunk_size);
    const manifest = Manifest{
        .platform = .{
            .cpu_profile = "sporevm-aarch64-v0",
            .device_model_version = 4,
            .ram_base = 0x8000_0000,
            .ram_size = 1 << 29,
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
                .kind = .backend_private,
                .backend_private = .{
                    .backend = .hvf,
                    .format = gicv3.hvf_backend_private_format,
                    .data_b64 = "AAAA",
                },
            },
        },
        .devices = &.{},
        .generation = .{ .generation = 0, .interrupt_status = 0, .params_b64 = "" },
        .memory = .{ .chunk_size = chunk_size, .chunks = &memory_chunks },
    };
    try saveManifest(arena, dir, manifest);
    const parsed = try loadManifest(arena, dir);
    defer parsed.deinit();
    try std.testing.expectEqual(gicv3.StateKind.backend_private, parsed.value.machine.gic.kind);
    try std.testing.expectEqual(gicv3.BackendKind.hvf, parsed.value.machine.gic.backend_private.?.backend);
    try std.testing.expectEqualStrings(gicv3.hvf_backend_private_format, parsed.value.machine.gic.backend_private.?.format);
}

test "manifest rejects invalid counter frequency" {
    var manifest = Manifest{
        .platform = .{
            .cpu_profile = "sporevm-aarch64-v0",
            .device_model_version = 4,
            .ram_base = 0x8000_0000,
            .ram_size = 1 << 29,
            .gic_dist_base = 0x0800_0000,
            .gic_redist_base = 0x0801_0000,
            .counter_frequency_hz = 0,
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
                .kind = .backend_private,
                .backend_private = .{
                    .backend = .hvf,
                    .format = gicv3.hvf_backend_private_format,
                    .data_b64 = "AAAA",
                },
            },
        },
        .devices = &.{},
        .generation = .{ .generation = 0, .interrupt_status = 0, .params_b64 = "" },
        .memory = .{ .chunk_size = chunk_size, .chunks = &.{} },
    };
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    manifest.platform.counter_frequency_hz = @as(u64, std.math.maxInt(u32)) + 1;
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    manifest.platform.counter_frequency_hz = 24_000_000;
    manifest.platform.cpu_profile = "";
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
}
