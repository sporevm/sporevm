//! Spore manifest v0 and chunk store.
//!
//! A spore is a directory rooted at `manifest.json`. Guest memory is stored as
//! fixed-size `chunks/<blake3-hex>` files with all-zero chunks elided; optional
//! writable disk layers use verified `disklayers/` indexes and `diskobjects/`
//! clusters. Machine state is normalized architectural aarch64 state — never raw
//! hypervisor structures (see docs/spore-format.md). v0 carries no compatibility
//! promise.
//!
//! Manifests and chunks may come from untrusted storage: parsing is strict,
//! chunk contents are verified against their ids before use, and restore
//! fails closed on any mismatch. See SECURITY.md.

const std = @import("std");
const builtin = @import("builtin");
const board = @import("board.zig");
const chunklib = @import("chunk.zig");
const generation = @import("generation.zig");
const gicv3 = @import("gicv3.zig");
const local_paths = @import("local_paths.zig");
const spore_net_policy = @import("spore_net_policy.zig");
const Blake3 = std.crypto.hash.Blake3;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const format_version: u32 = 0;
pub const chunk_size: usize = 2 * 1024 * 1024;
pub const ram_backing_kind = "map-private-file-v0";
pub const ram_backing_path = "ram.backing";
pub const ram_backing_proof_path = "ram.backing.proof";

const local_backing_proof_version: u32 = 1;
const local_backing_producer = "sporevm-local-ram-backing-v0";
const local_backing_key_path = "local-ram-backing.key";
const local_backing_key_len = HmacSha256.key_length;
const local_backing_proof_max_bytes = 16 * 1024;

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

pub const LocalBackingRestoreSource = enum {
    local_backing,
    chunks,
};

pub const LocalBackingPlan = struct {
    fd: ?std.c.fd_t = null,
    source: LocalBackingRestoreSource = .chunks,
    reason: []const u8 = "not_attempted",
};

const LocalBackingProof = struct {
    schema_version: u32,
    memory_fingerprint: []const u8,
    backing: LocalBackingProofBacking,
    file: LocalBackingFileIdentity,
    producer: []const u8,
    mac: []const u8,
};

const LocalBackingProofBacking = struct {
    kind: []const u8,
    path: []const u8,
    size: u64,
};

const LocalBackingFileIdentity = struct {
    file_type: []const u8 = "regular",
    device: u64,
    inode: u64,
    owner_uid: u64,
    size: u64,
    mtime_sec: i64,
    mtime_nsec: i64,
};

const LocalFileStat = struct {
    mode: u64,
    device: u64,
    inode: u64,
    owner_uid: u64,
    size: u64,
    mtime_sec: i64,
    mtime_nsec: i64,

    fn identity(self: LocalFileStat) LocalBackingFileIdentity {
        return .{
            .device = self.device,
            .inode = self.inode,
            .owner_uid = self.owner_uid,
            .size = self.size,
            .mtime_sec = self.mtime_sec,
            .mtime_nsec = self.mtime_nsec,
        };
    }
};

pub const rootfs_kind = "immutable-ext4-rootfs-v0";
pub const rootfs_mode_read_only = "read-only";
pub const rootfs_device_kind_virtio_mmio = "virtio-mmio";
pub const rootfs_device_role = "rootfs";
pub const rootfs_artifact_format_ext4 = "ext4";
pub const rootfs_digest_prefix = "blake3:";
pub const rootfs_source_kind_oci_image = "oci-image";
pub const rootfs_virtio_blk_device_id: u32 = 2;
pub const rootfs_storage_kind_chunked_ext4 = "chunked-ext4-rootfs-v0";
pub const rootfs_storage_hash_algorithm_blake3 = "blake3";
pub const rootfs_storage_object_namespace = "rootfs/blake3";

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

pub const RootfsStorage = struct {
    kind: []const u8,
    device: RootfsDevice,
    logical_size: u64,
    chunk_size: u64,
    hash_algorithm: []const u8,
    index_digest: []const u8,
    base_identity: []const u8,
    object_namespace: []const u8,
};

pub const Rootfs = struct {
    kind: []const u8 = rootfs_kind,
    mode: []const u8 = rootfs_mode_read_only,
    device: RootfsDevice,
    artifact: RootfsArtifactRef,
    storage: ?RootfsStorage = null,
    source: ?RootfsSource = null,
};

pub const disk_kind_cow_block = "cow-block-v0";
pub const disk_layer_kind = "disk-layer-v0";
pub const disk_digest_prefix = rootfs_digest_prefix;

pub const Disk = struct {
    kind: []const u8 = disk_kind_cow_block,
    device: RootfsDevice,
    size: u64,
    base: []const u8,
    layers: []const []const u8 = &.{},
};

pub const DiskLayerExtent = struct {
    logical_cluster: u64,
    digest: []const u8,
};

pub const DiskLayer = struct {
    kind: []const u8 = disk_layer_kind,
    cluster_size: u64,
    disk_size: u64,
    extents: []const DiskLayerExtent = &.{},
    zero_clusters: []const u64 = &.{},
};

pub const network_kind_spore = "spore-net-v0";

pub const Network = struct {
    kind: []const u8 = network_kind_spore,
    allow_cidrs: []const []const u8 = &.{},
    allow_hosts: []const []const u8 = &.{},
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
    disk: ?Disk = null,
    network: ?Network = null,
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

fn hardlinkPath(target: []const u8, link_path: []const u8) Error!void {
    const target_z = try std.heap.c_allocator.dupeZ(u8, target);
    defer std.heap.c_allocator.free(target_z);
    const link_z = try std.heap.c_allocator.dupeZ(u8, link_path);
    defer std.heap.c_allocator.free(link_z);
    if (std.c.link(target_z, link_z) != 0) return error.IoFailed;
}

fn openReadOnlyNoFollow(path: [:0]const u8) Error!std.c.fd_t {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.IoFailed;
    return fd;
}

fn fstatLocalFile(fd: std.c.fd_t) Error!LocalFileStat {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var statx_buf: linux.Statx = undefined;
        const flags: u32 = linux.AT.EMPTY_PATH;
        const rc = linux.statx(fd, "", flags, .{
            .TYPE = true,
            .MODE = true,
            .UID = true,
            .INO = true,
            .SIZE = true,
            .MTIME = true,
        }, &statx_buf);
        if (linux.errno(rc) != .SUCCESS) return error.IoFailed;
        if (!linux.S.ISREG(statx_buf.mode)) return error.BadManifest;
        return .{
            .mode = statx_buf.mode,
            .device = (@as(u64, statx_buf.dev_major) << 32) | statx_buf.dev_minor,
            .inode = statx_buf.ino,
            .owner_uid = statx_buf.uid,
            .size = statx_buf.size,
            .mtime_sec = statx_buf.mtime.sec,
            .mtime_nsec = statx_buf.mtime.nsec,
        };
    } else {
        var st: std.c.Stat = undefined;
        if (std.c.fstat(fd, &st) != 0) return error.IoFailed;
        if (!std.c.S.ISREG(st.mode)) return error.BadManifest;
        const mtim = st.mtime();
        return .{
            .mode = @intCast(st.mode),
            .device = @intCast(st.dev),
            .inode = @intCast(st.ino),
            .owner_uid = @intCast(st.uid),
            .size = @intCast(st.size),
            .mtime_sec = mtim.sec,
            .mtime_nsec = mtim.nsec,
        };
    }
}

fn localBackingChunksPlan(reason: []const u8) LocalBackingPlan {
    return .{ .source = .chunks, .reason = reason };
}

fn memoryFingerprintHex(allocator: std.mem.Allocator, memory: MemoryManifest, expected_size: u64) Error![]const u8 {
    if (expected_size > std.math.maxInt(usize)) return error.BadManifest;
    const plan = try validateMemoryForRam(memory, @intCast(expected_size));
    var h = Blake3.init(.{});
    h.update("sporevm-memory-fingerprint-v1");
    hashU64(&h, expected_size);
    hashU64(&h, memory.chunk_size);
    hashU64(&h, plan.chunk_count);
    for (memory.chunks) |maybe_ref| {
        if (maybe_ref) |ref| {
            h.update(&.{1});
            hashBytes(&h, ref);
        } else {
            h.update(&.{0});
        }
    }
    var digest: [Blake3.digest_length]u8 = undefined;
    h.final(&digest);
    return hexAlloc(allocator, &digest);
}

fn hashU64(hasher: *Blake3, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hasher.update(&bytes);
}

fn hashBytes(hasher: *Blake3, value: []const u8) void {
    hashU64(hasher, value.len);
    hasher.update(value);
}

fn proofMac(
    allocator: std.mem.Allocator,
    key: *const [local_backing_key_len]u8,
    memory_fingerprint: []const u8,
    backing: LocalBackingProofBacking,
    file: LocalBackingFileIdentity,
    producer: []const u8,
) Error![HmacSha256.mac_length]u8 {
    _ = allocator;
    var mac = HmacSha256.init(key);
    mac.update("sporevm-local-ram-backing-proof-v1");
    macU64(&mac, local_backing_proof_version);
    macBytes(&mac, memory_fingerprint);
    macBytes(&mac, backing.kind);
    macBytes(&mac, backing.path);
    macU64(&mac, backing.size);
    macBytes(&mac, file.file_type);
    macU64(&mac, file.device);
    macU64(&mac, file.inode);
    macU64(&mac, file.owner_uid);
    macU64(&mac, file.size);
    macI64(&mac, file.mtime_sec);
    macI64(&mac, file.mtime_nsec);
    macBytes(&mac, producer);
    var out: [HmacSha256.mac_length]u8 = undefined;
    mac.final(&out);
    return out;
}

fn macU64(mac: *HmacSha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    mac.update(&bytes);
}

fn macI64(mac: *HmacSha256, value: i64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(i64, &bytes, value, .little);
    mac.update(&bytes);
}

fn macBytes(mac: *HmacSha256, value: []const u8) void {
    macU64(mac, value.len);
    mac.update(value);
}

fn localBackingRuntimeRoot(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) Error![]const u8 {
    const root = local_paths.runtimeRootPath(allocator, environ) catch return error.IoFailed;
    const root_z = try pathZ(allocator, "{s}", .{root});
    if (std.c.mkdir(root_z, 0o700) != 0 and std.c.access(root_z, 0) != 0) return error.IoFailed;
    const fd = std.c.open(root_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);
    if (std.c.fchmod(fd, 0o700) != 0) return error.IoFailed;
    return root;
}

fn localBackingKey(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, create: bool) Error!?[local_backing_key_len]u8 {
    const root = try localBackingRuntimeRoot(allocator, environ);
    const path = try pathZ(allocator, "{s}/{s}", .{ root, local_backing_key_path });
    var fd = std.c.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) {
        if (!create) return null;
        fd = std.c.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0o600));
        if (fd < 0) return error.IoFailed;
        defer _ = std.c.close(fd);
        var key: [local_backing_key_len]u8 = undefined;
        try fillRandom(&key);
        try writeFdAll(fd, &key);
        if (std.c.fchmod(fd, 0o600) != 0) return error.IoFailed;
        return key;
    }
    defer _ = std.c.close(fd);
    const st = try fstatLocalFile(fd);
    if (st.owner_uid != std.c.getuid() or st.size != local_backing_key_len) return error.IoFailed;
    if (std.c.fchmod(fd, 0o600) != 0) return error.IoFailed;
    var key: [local_backing_key_len]u8 = undefined;
    try readFdExact(fd, &key);
    return key;
}

fn writeFdAll(fd: std.c.fd_t, data: []const u8) Error!void {
    var done: usize = 0;
    while (done < data.len) {
        const n = std.c.write(fd, data.ptr + done, data.len - done);
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
}

fn readFdExact(fd: std.c.fd_t, out: []u8) Error!void {
    if (std.c.lseek(fd, 0, std.c.SEEK.SET) < 0) return error.IoFailed;
    var done: usize = 0;
    while (done < out.len) {
        const n = std.c.read(fd, out.ptr + done, out.len - done);
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
}

fn readRegularFileAllNoFollow(allocator: std.mem.Allocator, path: [:0]const u8, max: usize) Error![]u8 {
    const fd = try openReadOnlyNoFollow(path);
    defer _ = std.c.close(fd);
    const st = try fstatLocalFile(fd);
    if (st.size > std.math.maxInt(usize)) return error.BadChunk;
    const size: usize = @intCast(st.size);
    if (size > max) return error.BadChunk;
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    try readFdExact(fd, buf);
    return buf;
}

fn proofBackingFromManifest(backing: MemoryBacking) LocalBackingProofBacking {
    return .{
        .kind = backing.kind,
        .path = backing.path,
        .size = backing.size,
    };
}

fn proofFieldsMatch(
    proof: LocalBackingProof,
    memory_fingerprint: []const u8,
    backing: LocalBackingProofBacking,
    file: LocalBackingFileIdentity,
) bool {
    return proof.schema_version == local_backing_proof_version and
        std.mem.eql(u8, proof.memory_fingerprint, memory_fingerprint) and
        std.mem.eql(u8, proof.backing.kind, backing.kind) and
        std.mem.eql(u8, proof.backing.path, backing.path) and
        proof.backing.size == backing.size and
        std.mem.eql(u8, proof.file.file_type, "regular") and
        proof.file.device == file.device and
        proof.file.inode == file.inode and
        proof.file.owner_uid == file.owner_uid and
        proof.file.size == file.size and
        proof.file.mtime_sec == file.mtime_sec and
        proof.file.mtime_nsec == file.mtime_nsec and
        std.mem.eql(u8, proof.producer, local_backing_producer);
}

pub fn writeLocalMemoryBackingProof(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    dir: []const u8,
    memory: MemoryManifest,
    expected_size: u64,
) Error!void {
    const backing = memory.backing orelse return;
    try validateMemoryBacking(backing, expected_size);
    const backing_path = try memoryBackingPath(allocator, dir, backing);
    const fd = try openReadOnlyNoFollow(backing_path);
    defer _ = std.c.close(fd);
    const file = (try fstatLocalFile(fd)).identity();
    if (file.size != expected_size) return error.BadManifest;
    const key = (try localBackingKey(allocator, environ, true)) orelse return error.IoFailed;
    const memory_fingerprint = try memoryFingerprintHex(allocator, memory, expected_size);
    const proof_backing = proofBackingFromManifest(backing);
    const mac = try proofMac(allocator, &key, memory_fingerprint, proof_backing, file, local_backing_producer);
    const mac_hex = try hexAlloc(allocator, &mac);
    const proof = LocalBackingProof{
        .schema_version = local_backing_proof_version,
        .memory_fingerprint = memory_fingerprint,
        .backing = proof_backing,
        .file = file,
        .producer = local_backing_producer,
        .mac = mac_hex,
    };
    const json = std.json.Stringify.valueAlloc(allocator, proof, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
    const proof_path = try pathZ(allocator, "{s}/{s}", .{ dir, ram_backing_proof_path });
    try writeFileAll(proof_path, json);
}

pub fn openProvenLocalMemoryBacking(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    dir: []const u8,
    memory: MemoryManifest,
    expected_size: u64,
) Error!LocalBackingPlan {
    const backing = memory.backing orelse return localBackingChunksPlan("no_backing");
    validateMemoryBacking(backing, expected_size) catch return localBackingChunksPlan("bad_backing_metadata");
    const backing_path = try memoryBackingPath(allocator, dir, backing);
    const fd = openReadOnlyNoFollow(backing_path) catch return localBackingChunksPlan("backing_unavailable");
    var handoff_fd = false;
    defer if (!handoff_fd) {
        _ = std.c.close(fd);
    };
    const file = (fstatLocalFile(fd) catch return localBackingChunksPlan("backing_stat_failed")).identity();
    if (file.size != expected_size) return localBackingChunksPlan("backing_size_mismatch");

    const proof_path = try pathZ(allocator, "{s}/{s}", .{ dir, ram_backing_proof_path });
    const proof_bytes = readRegularFileAllNoFollow(allocator, proof_path, local_backing_proof_max_bytes) catch return localBackingChunksPlan("proof_unavailable");
    const parsed = std.json.parseFromSlice(LocalBackingProof, allocator, proof_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch return localBackingChunksPlan("proof_invalid");
    defer parsed.deinit();

    const key = (localBackingKey(allocator, environ, false) catch return localBackingChunksPlan("key_unavailable")) orelse
        return localBackingChunksPlan("key_unavailable");
    const memory_fingerprint = try memoryFingerprintHex(allocator, memory, expected_size);
    const proof_backing = proofBackingFromManifest(backing);
    if (!proofFieldsMatch(parsed.value, memory_fingerprint, proof_backing, file)) return localBackingChunksPlan("proof_mismatch");
    if (parsed.value.mac.len != HmacSha256.mac_length * 2) return localBackingChunksPlan("proof_mac_invalid");
    var actual_mac: [HmacSha256.mac_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&actual_mac, parsed.value.mac) catch return localBackingChunksPlan("proof_mac_invalid");
    const expected_mac = try proofMac(allocator, &key, memory_fingerprint, proof_backing, file, local_backing_producer);
    if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, actual_mac, expected_mac)) return localBackingChunksPlan("proof_mac_mismatch");
    handoff_fd = true;
    return .{ .fd = fd, .source = .local_backing, .reason = "proof_valid" };
}

pub fn validateMemoryBacking(backing: MemoryBacking, expected_size: u64) Error!void {
    if (!std.mem.eql(u8, backing.kind, ram_backing_kind)) return error.BadManifest;
    if (!std.mem.eql(u8, backing.path, ram_backing_path)) return error.BadManifest;
    if (backing.size != expected_size) return error.BadManifest;
}

pub fn validateRootfs(rootfs: Rootfs, devices: []const TransportState) Error!void {
    if (!std.mem.eql(u8, rootfs.kind, rootfs_kind)) return error.BadManifest;
    if (!std.mem.eql(u8, rootfs.mode, rootfs_mode_read_only)) return error.BadManifest;
    try validateRootfsDevice(rootfs.device, devices);
    if (!std.mem.eql(u8, rootfs.artifact.format, rootfs_artifact_format_ext4)) return error.BadManifest;
    if (rootfs.artifact.size == 0 or rootfs.artifact.size > std.math.maxInt(usize)) return error.BadManifest;
    try validateRootfsDigest(rootfs.artifact.digest);
    if (rootfs.storage) |storage| try validateRootfsStorage(storage, rootfs, devices);
    if (rootfs.source) |source| try validateRootfsSource(source);
}

fn validateRootfsDevice(device: RootfsDevice, devices: []const TransportState) Error!void {
    if (!std.mem.eql(u8, device.kind, rootfs_device_kind_virtio_mmio)) return error.BadManifest;
    if (!std.mem.eql(u8, device.role, rootfs_device_role)) return error.BadManifest;
    if (device.virtio_device_id != rootfs_virtio_blk_device_id) return error.BadManifest;
    if (device.mmio_slot >= devices.len) return error.BadManifest;
    if (devices[device.mmio_slot].device_id != rootfs_virtio_blk_device_id) return error.BadManifest;
}

fn rootfsDeviceEql(a: RootfsDevice, b: RootfsDevice) bool {
    return std.mem.eql(u8, a.kind, b.kind) and
        std.mem.eql(u8, a.role, b.role) and
        a.virtio_device_id == b.virtio_device_id and
        a.mmio_slot == b.mmio_slot;
}

fn validateRootfsStorage(storage: RootfsStorage, rootfs: Rootfs, devices: []const TransportState) Error!void {
    try validateRootfsStorageDescriptor(storage);
    try validateRootfsDevice(storage.device, devices);
    if (!rootfsDeviceEql(storage.device, rootfs.device)) return error.BadManifest;
    if (storage.logical_size != rootfs.artifact.size) return error.BadManifest;
}

pub fn validateRootfsStorageDescriptor(storage: RootfsStorage) Error!void {
    if (!std.mem.eql(u8, storage.kind, rootfs_storage_kind_chunked_ext4)) return error.BadManifest;
    if (storage.logical_size == 0 or storage.logical_size > std.math.maxInt(usize)) return error.BadManifest;
    if (!validDiskClusterSize(storage.chunk_size)) return error.BadManifest;
    if (!std.mem.eql(u8, storage.hash_algorithm, rootfs_storage_hash_algorithm_blake3)) return error.BadManifest;
    try validateRootfsDigest(storage.index_digest);
    try validateRootfsDigest(storage.base_identity);
    if (!std.mem.eql(u8, storage.base_identity, storage.index_digest)) return error.BadManifest;
    if (!std.mem.eql(u8, storage.object_namespace, rootfs_storage_object_namespace)) return error.BadManifest;
}

pub fn effectiveRootfsBaseIdentity(rootfs: Rootfs) []const u8 {
    if (rootfs.storage) |storage| return storage.base_identity;
    return rootfs.artifact.digest;
}

pub fn effectiveRootfsLogicalSize(rootfs: Rootfs) u64 {
    if (rootfs.storage) |storage| return storage.logical_size;
    return rootfs.artifact.size;
}

pub fn validateDisk(disk: Disk, maybe_rootfs: ?Rootfs, devices: []const TransportState) Error!void {
    const rootfs = maybe_rootfs orelse return error.BadManifest;
    if (!std.mem.eql(u8, disk.kind, disk_kind_cow_block)) return error.BadManifest;
    try validateRootfsDevice(disk.device, devices);
    if (!rootfsDeviceEql(disk.device, rootfs.device)) return error.BadManifest;
    if (disk.size == 0 or disk.size != effectiveRootfsLogicalSize(rootfs)) return error.BadManifest;
    if (!std.mem.eql(u8, disk.base, effectiveRootfsBaseIdentity(rootfs))) return error.BadManifest;
    try validateDiskDigest(disk.base);
    for (disk.layers) |layer_ref| {
        try validateDiskDigest(layer_ref);
    }
}

pub fn validateDiskLayer(layer: DiskLayer) Error!void {
    if (!std.mem.eql(u8, layer.kind, disk_layer_kind)) return error.BadManifest;
    const cluster_count = try diskClusterCount(layer.disk_size, layer.cluster_size);

    var previous_extent: ?u64 = null;
    for (layer.extents) |extent| {
        if (extent.logical_cluster >= cluster_count) return error.BadManifest;
        if (previous_extent) |previous| {
            if (extent.logical_cluster <= previous) return error.BadManifest;
        }
        try validateDiskDigest(extent.digest);
        previous_extent = extent.logical_cluster;
    }

    var extent_index: usize = 0;
    var previous_zero: ?u64 = null;
    for (layer.zero_clusters) |logical_cluster| {
        if (logical_cluster >= cluster_count) return error.BadManifest;
        if (previous_zero) |previous| {
            if (logical_cluster <= previous) return error.BadManifest;
        }
        while (extent_index < layer.extents.len and layer.extents[extent_index].logical_cluster < logical_cluster) {
            extent_index += 1;
        }
        if (extent_index < layer.extents.len and layer.extents[extent_index].logical_cluster == logical_cluster) {
            return error.BadManifest;
        }
        previous_zero = logical_cluster;
    }
}

pub fn validDiskClusterSize(cluster_size: u64) bool {
    return cluster_size != 0 and
        cluster_size % 512 == 0 and
        cluster_size <= std.math.maxInt(usize);
}

pub fn diskClusterCount(disk_size: u64, cluster_size: u64) Error!u64 {
    if (disk_size == 0 or disk_size > std.math.maxInt(usize)) return error.BadManifest;
    if (!validDiskClusterSize(cluster_size)) return error.BadManifest;
    const rounded = std.math.add(u64, disk_size, cluster_size - 1) catch return error.BadManifest;
    return rounded / cluster_size;
}

pub fn diskClusterLen(disk_size: u64, cluster_size: u64, logical_cluster: u64) Error!usize {
    const cluster_count = try diskClusterCount(disk_size, cluster_size);
    if (logical_cluster >= cluster_count) return error.BadManifest;
    const start = std.math.mul(u64, logical_cluster, cluster_size) catch return error.BadManifest;
    if (start >= disk_size) return error.BadManifest;
    const len = @min(cluster_size, disk_size - start);
    return std.math.cast(usize, len) orelse return error.BadManifest;
}

pub fn findDiskExtent(layer: DiskLayer, logical_cluster: u64) ?DiskLayerExtent {
    for (layer.extents) |extent| {
        if (extent.logical_cluster == logical_cluster) return extent;
        if (extent.logical_cluster > logical_cluster) return null;
    }
    return null;
}

pub fn diskLayerHasZeroCluster(layer: DiskLayer, logical_cluster: u64) bool {
    for (layer.zero_clusters) |zero_cluster| {
        if (zero_cluster == logical_cluster) return true;
        if (zero_cluster > logical_cluster) return false;
    }
    return false;
}

pub fn validateNetwork(network: Network) Error!void {
    if (!std.mem.eql(u8, network.kind, network_kind_spore)) return error.BadManifest;
    if (network.allow_cidrs.len > spore_net_policy.max_allow_cidrs) return error.BadManifest;
    if (network.allow_hosts.len > spore_net_policy.max_allow_hosts) return error.BadManifest;
    for (network.allow_cidrs) |cidr| {
        _ = spore_net_policy.parseCidr(cidr) catch return error.BadManifest;
    }
    for (network.allow_hosts) |host| {
        spore_net_policy.validateHost(host) catch return error.BadManifest;
    }
}

pub fn rootfsQueuesQuiescent(rootfs: Rootfs, devices: []const TransportState) Error!bool {
    try validateRootfs(rootfs, devices);
    const device = devices[rootfs.device.mmio_slot];
    for (device.queues) |queue| {
        if (queue.ready and queue.last_avail != queue.used_idx) return false;
    }
    return true;
}

pub fn diskQueuesQuiescent(disk: Disk, devices: []const TransportState) Error!bool {
    try validateRootfsDevice(disk.device, devices);
    const device = devices[disk.device.mmio_slot];
    for (device.queues) |queue| {
        if (queue.ready and queue.last_avail != queue.used_idx) return false;
    }
    return true;
}

pub fn validateRootfsDigest(digest: []const u8) Error!void {
    try validateDiskDigest(digest);
}

pub fn validateDiskDigest(digest: []const u8) Error!void {
    _ = try diskDigestHex(digest);
}

pub fn diskDigestHex(digest: []const u8) Error![]const u8 {
    if (!std.mem.startsWith(u8, digest, disk_digest_prefix)) return error.BadManifest;
    const hex = digest[disk_digest_prefix.len..];
    _ = chunklib.ChunkId.fromHex(hex) catch return error.BadManifest;
    return hex;
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
    environ_map: ?*const std.process.Environ.Map = null,
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
        if (options.environ_map) |environ| {
            const parent_backing_plan = try openProvenLocalMemoryBacking(allocator, environ, options.parent_dir, parent.memory, parent.platform.ram_size);
            defer if (parent_backing_plan.fd) |fd| {
                _ = std.c.close(fd);
            };
            if (parent_backing_plan.source == .local_backing) {
                const parent_backing = try memoryBackingPath(allocator, options.parent_dir, backing);
                shared_backing = realpathAlloc(allocator, parent_backing) catch |err| switch (err) {
                    error.IoFailed => null,
                    else => |e| return e,
                };
            }
        }
    }
    var shared_disk_layers: ?[]const u8 = null;
    var shared_disk_objects: ?[]const u8 = null;
    if (parent.disk) |disk| {
        if (disk.layers.len > 0) {
            shared_disk_layers = try realpathAlloc(allocator, try pathZ(allocator, "{s}/disklayers", .{options.parent_dir}));
            shared_disk_objects = try realpathAlloc(allocator, try pathZ(allocator, "{s}/diskobjects", .{options.parent_dir}));
        }
    }
    try ensureDir(try pathZ(allocator, "{s}", .{options.out_dir}));

    const fork_batch_id = try randomHex(allocator, 16);

    var i: usize = 0;
    while (i < options.count) : (i += 1) {
        const child_dir = try pathZ(allocator, "{s}/{d:0>6}", .{ options.out_dir, i });
        try ensureNewDir(child_dir);
        const chunks_link = try pathZ(allocator, "{s}/chunks", .{child_dir});
        try symlinkPath(shared_chunks, chunks_link);
        if (shared_disk_layers) |layers| {
            try symlinkPath(layers, try pathZ(allocator, "{s}/disklayers", .{child_dir}));
        }
        if (shared_disk_objects) |objects| {
            try symlinkPath(objects, try pathZ(allocator, "{s}/diskobjects", .{child_dir}));
        }
        var child = parent;
        if (shared_backing == null) child.memory.backing = null;
        if (child.memory.backing) |backing| {
            const backing_link = try pathZ(allocator, "{s}/{s}", .{ child_dir, backing.path });
            hardlinkPath(shared_backing.?, backing_link) catch {
                child.memory.backing = null;
            };
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
        if (child.memory.backing != null) {
            if (options.environ_map) |environ| {
                writeLocalMemoryBackingProof(allocator, environ, child_dir, child.memory, child.platform.ram_size) catch {};
            }
        }
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

pub fn validateManifest(manifest: Manifest) Error!void {
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
    if (manifest.disk) |disk| {
        try validateDisk(disk, manifest.rootfs, manifest.devices);
    }
    if (manifest.network) |network| {
        try validateNetwork(network);
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

test "local memory backing proof opens local fd and falls back safely" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const dir = try pathZ(arena, "{s}/spore", .{root_dir});
    const runtime_dir = try pathZ(arena, "{s}/runtime", .{root_dir});
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.runtime_dir_env, runtime_dir);

    const ram = try arena.alloc(u8, 2 * chunk_size + 32);
    @memset(ram, 0);
    ram[13] = 0x33;
    ram[chunk_size + 7] = 0x44;
    const mm = try saveMemoryWithBacking(arena, dir, ram);
    try writeLocalMemoryBackingProof(arena, &env, dir, mm, ram.len);

    const plan = try openProvenLocalMemoryBacking(arena, &env, dir, mm, ram.len);
    defer if (plan.fd) |fd| {
        _ = std.c.close(fd);
    };
    try std.testing.expectEqual(LocalBackingRestoreSource.local_backing, plan.source);
    try std.testing.expect(plan.fd != null);
    try std.testing.expectEqualStrings("proof_valid", plan.reason);

    const proof_path = try pathZ(arena, "{s}/{s}", .{ dir, ram_backing_proof_path });
    try writeFileAll(proof_path, "{}");
    const corrupt_plan = try openProvenLocalMemoryBacking(arena, &env, dir, mm, ram.len);
    defer if (corrupt_plan.fd) |fd| {
        _ = std.c.close(fd);
    };
    try std.testing.expectEqual(LocalBackingRestoreSource.chunks, corrupt_plan.source);
    try std.testing.expect(corrupt_plan.fd == null);
    try std.testing.expectEqualStrings("proof_invalid", corrupt_plan.reason);

    try writeLocalMemoryBackingProof(arena, &env, dir, mm, ram.len);
    const proof_real_path = try pathZ(arena, "{s}/{s}.real", .{ dir, ram_backing_proof_path });
    if (std.c.rename(proof_path.ptr, proof_real_path.ptr) != 0) return error.IoFailed;
    try symlinkPath(proof_real_path, proof_path);
    const symlink_plan = try openProvenLocalMemoryBacking(arena, &env, dir, mm, ram.len);
    defer if (symlink_plan.fd) |fd| {
        _ = std.c.close(fd);
    };
    try std.testing.expectEqual(LocalBackingRestoreSource.chunks, symlink_plan.source);
    try std.testing.expect(symlink_plan.fd == null);
    try std.testing.expectEqualStrings("proof_unavailable", symlink_plan.reason);
}

test "local memory backing proof rejects foreign key and manifest mismatch" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const dir = try pathZ(arena, "{s}/spore", .{root_dir});
    const runtime_a = try pathZ(arena, "{s}/runtime-a", .{root_dir});
    const runtime_b = try pathZ(arena, "{s}/runtime-b", .{root_dir});
    var env_a = std.process.Environ.Map.init(allocator);
    defer env_a.deinit();
    var env_b = std.process.Environ.Map.init(allocator);
    defer env_b.deinit();
    try env_a.put(local_paths.runtime_dir_env, runtime_a);
    try env_b.put(local_paths.runtime_dir_env, runtime_b);

    const ram = try arena.alloc(u8, chunk_size);
    @memset(ram, 0x5A);
    const mm = try saveMemoryWithBacking(arena, dir, ram);
    try writeLocalMemoryBackingProof(arena, &env_a, dir, mm, ram.len);

    const missing_key_plan = try openProvenLocalMemoryBacking(arena, &env_b, dir, mm, ram.len);
    defer if (missing_key_plan.fd) |fd| {
        _ = std.c.close(fd);
    };
    try std.testing.expectEqual(LocalBackingRestoreSource.chunks, missing_key_plan.source);
    try std.testing.expectEqualStrings("key_unavailable", missing_key_plan.reason);

    _ = try localBackingKey(arena, &env_b, true);
    const foreign_key_plan = try openProvenLocalMemoryBacking(arena, &env_b, dir, mm, ram.len);
    defer if (foreign_key_plan.fd) |fd| {
        _ = std.c.close(fd);
    };
    try std.testing.expectEqual(LocalBackingRestoreSource.chunks, foreign_key_plan.source);
    try std.testing.expectEqualStrings("proof_mac_mismatch", foreign_key_plan.reason);

    var refs = try arena.alloc(?[]const u8, mm.chunks.len);
    @memcpy(refs, mm.chunks);
    refs[0] = null;
    var changed = mm;
    changed.chunks = refs;
    const mismatch_plan = try openProvenLocalMemoryBacking(arena, &env_a, dir, changed, ram.len);
    defer if (mismatch_plan.fd) |fd| {
        _ = std.c.close(fd);
    };
    try std.testing.expectEqual(LocalBackingRestoreSource.chunks, mismatch_plan.source);
    try std.testing.expectEqualStrings("proof_mismatch", mismatch_plan.reason);
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
        .network = .{
            .allow_cidrs = &.{"93.184.216.34/32"},
            .allow_hosts = &.{"example.com"},
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
    try std.testing.expect(parsed.value.network != null);
    try std.testing.expectEqualStrings(network_kind_spore, parsed.value.network.?.kind);
    try std.testing.expectEqualStrings("93.184.216.34/32", parsed.value.network.?.allow_cidrs[0]);
    try std.testing.expectEqualStrings("example.com", parsed.value.network.?.allow_hosts[0]);
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

fn testDisk(mmio_slot: u32) Disk {
    return .{
        .device = .{ .mmio_slot = mmio_slot },
        .size = 4096,
        .base = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .layers = &.{"blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
    };
}

fn testRootfsStorage(mmio_slot: u32) RootfsStorage {
    return .{
        .kind = rootfs_storage_kind_chunked_ext4,
        .device = .{ .mmio_slot = mmio_slot },
        .logical_size = 4096,
        .chunk_size = 4096,
        .hash_algorithm = rootfs_storage_hash_algorithm_blake3,
        .index_digest = "blake3:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        .base_identity = "blake3:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        .object_namespace = rootfs_storage_object_namespace,
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

test "manifest disk validates rootfs base and layer chain" {
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
    manifest.disk = testDisk(1);

    try saveManifest(arena, dir, manifest);
    const parsed = try loadManifest(arena, dir);
    defer parsed.deinit();
    const disk = parsed.value.disk orelse return error.BadManifest;
    try std.testing.expectEqualStrings(disk_kind_cow_block, disk.kind);
    try std.testing.expectEqualStrings(manifest.rootfs.?.artifact.digest, disk.base);
    try std.testing.expectEqual(@as(u64, 4096), disk.size);
    try std.testing.expect(try diskQueuesQuiescent(disk, parsed.value.devices));

    manifest.rootfs = null;
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    manifest.rootfs = testRootfs(1);
    manifest.disk.?.base = "blake3:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    manifest.disk.?.base = manifest.rootfs.?.artifact.digest;
    manifest.disk.?.device.mmio_slot = 0;
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    manifest.disk.?.device.mmio_slot = 1;
    manifest.disk.?.size = 8192;
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    manifest.disk.?.size = 4096;
    manifest.disk.?.layers = &.{"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"};
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
}

test "manifest disk binds to chunked rootfs storage identity" {
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
    manifest.rootfs.?.storage = testRootfsStorage(1);
    manifest.disk = testDisk(1);
    manifest.disk.?.base = manifest.rootfs.?.storage.?.base_identity;

    try saveManifest(arena, dir, manifest);
    const parsed = try loadManifest(arena, dir);
    defer parsed.deinit();
    const rootfs = parsed.value.rootfs orelse return error.BadManifest;
    const disk = parsed.value.disk orelse return error.BadManifest;
    try std.testing.expectEqualStrings(rootfs.storage.?.index_digest, effectiveRootfsBaseIdentity(rootfs));
    try std.testing.expectEqualStrings(rootfs.storage.?.base_identity, disk.base);
    try std.testing.expectEqual(@as(u64, 4096), effectiveRootfsLogicalSize(rootfs));

    manifest.disk.?.base = manifest.rootfs.?.artifact.digest;
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    manifest.disk.?.base = manifest.rootfs.?.storage.?.base_identity;

    manifest.rootfs.?.storage.?.base_identity = "blake3:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    manifest.rootfs.?.storage = testRootfsStorage(1);

    manifest.rootfs.?.storage.?.device.mmio_slot = 0;
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    manifest.rootfs.?.storage = testRootfsStorage(1);

    manifest.rootfs.?.storage.?.object_namespace = "../rootfs";
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
}

test "disk layer index validation fails closed" {
    const digest_a = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const digest_b = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    var layer = DiskLayer{
        .cluster_size = 4096,
        .disk_size = 8192,
        .extents = &.{
            .{ .logical_cluster = 0, .digest = digest_a },
            .{ .logical_cluster = 1, .digest = digest_b },
        },
        .zero_clusters = &.{},
    };
    try validateDiskLayer(layer);
    try std.testing.expectEqual(@as(u64, 2), try diskClusterCount(layer.disk_size, layer.cluster_size));
    try std.testing.expectEqual(@as(usize, 4096), try diskClusterLen(layer.disk_size, layer.cluster_size, 1));
    try std.testing.expect(findDiskExtent(layer, 1) != null);
    try std.testing.expect(!diskLayerHasZeroCluster(layer, 1));

    layer.extents = &.{
        .{ .logical_cluster = 1, .digest = digest_b },
        .{ .logical_cluster = 0, .digest = digest_a },
    };
    try std.testing.expectError(error.BadManifest, validateDiskLayer(layer));

    layer.extents = &.{
        .{ .logical_cluster = 1, .digest = digest_a },
        .{ .logical_cluster = 1, .digest = digest_b },
    };
    try std.testing.expectError(error.BadManifest, validateDiskLayer(layer));

    layer.extents = &.{.{ .logical_cluster = 2, .digest = digest_a }};
    try std.testing.expectError(error.BadManifest, validateDiskLayer(layer));

    layer.extents = &.{.{ .logical_cluster = 0, .digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }};
    try std.testing.expectError(error.BadManifest, validateDiskLayer(layer));

    layer.extents = &.{.{ .logical_cluster = 0, .digest = digest_a }};
    layer.zero_clusters = &.{0};
    try std.testing.expectError(error.BadManifest, validateDiskLayer(layer));

    layer.extents = &.{};
    layer.zero_clusters = &.{ 1, 1 };
    try std.testing.expectError(error.BadManifest, validateDiskLayer(layer));

    layer.zero_clusters = &.{2};
    try std.testing.expectError(error.BadManifest, validateDiskLayer(layer));

    layer.zero_clusters = &.{};
    layer.cluster_size = 1000;
    try std.testing.expectError(error.BadManifest, validateDiskLayer(layer));

    layer.cluster_size = 4096;
    layer.disk_size = 0;
    try std.testing.expectError(error.BadManifest, validateDiskLayer(layer));
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
    const runtime_dir = try pathZ(arena, "{s}/runtime", .{root_dir});
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.runtime_dir_env, runtime_dir);
    try writeLocalMemoryBackingProof(arena, &env, parent_dir, memory, ram.len);

    var devices = [_]TransportState{
        testTransport(3),
        testTransport(rootfs_virtio_blk_device_id),
    };
    var parent_manifest = testForkManifest(memory, ram.len, 41);
    parent_manifest.devices = &devices;
    parent_manifest.rootfs = testRootfs(1);
    parent_manifest.disk = testDisk(1);
    parent_manifest.network = .{
        .allow_cidrs = &.{"93.184.216.0/24"},
        .allow_hosts = &.{"example.com"},
    };
    try ensureDir(try pathZ(arena, "{s}/disklayers", .{parent_dir}));
    try ensureDir(try pathZ(arena, "{s}/diskobjects", .{parent_dir}));
    try saveManifest(arena, parent_dir, parent_manifest);

    const result = try fork(arena, .{ .parent_dir = parent_dir, .out_dir = out_dir, .count = 2, .environ_map = &env });
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
    try std.testing.expect(first.value.disk != null);
    try std.testing.expectEqualStrings(parent_manifest.disk.?.base, first.value.disk.?.base);
    try std.testing.expectEqualStrings(parent_manifest.disk.?.layers[0], first.value.disk.?.layers[0]);
    try std.testing.expectEqual(@as(c_int, 0), std.c.access(try pathZ(arena, "{s}/disklayers", .{first_child_dir}), 0));
    try std.testing.expectEqual(@as(c_int, 0), std.c.access(try pathZ(arena, "{s}/diskobjects", .{first_child_dir}), 0));
    try std.testing.expect(first.value.network != null);
    try std.testing.expectEqualStrings(network_kind_spore, first.value.network.?.kind);
    try std.testing.expectEqualStrings(parent_manifest.network.?.allow_cidrs[0], first.value.network.?.allow_cidrs[0]);
    try std.testing.expectEqualStrings(parent_manifest.network.?.allow_hosts[0], first.value.network.?.allow_hosts[0]);
    const first_backing = first.value.memory.backing orelse return error.BadManifest;
    try std.testing.expectEqualStrings(ram_backing_path, first_backing.path);
    const first_backing_path = try memoryBackingPath(arena, first_child_dir, first_backing);
    try std.testing.expectEqual(@as(c_int, 0), std.c.access(first_backing_path, 0));
    const first_backing_plan = try openProvenLocalMemoryBacking(arena, &env, first_child_dir, first.value.memory, first.value.platform.ram_size);
    defer if (first_backing_plan.fd) |fd| {
        _ = std.c.close(fd);
    };
    try std.testing.expectEqual(LocalBackingRestoreSource.local_backing, first_backing_plan.source);

    const parent_backing_path = try memoryBackingPath(arena, parent_dir, memory.backing.?);
    const parent_backing_fd = try openReadOnlyNoFollow(parent_backing_path);
    defer _ = std.c.close(parent_backing_fd);
    const child_backing_fd = try openReadOnlyNoFollow(first_backing_path);
    defer _ = std.c.close(child_backing_fd);
    try std.testing.expectEqual((try fstatLocalFile(parent_backing_fd)).inode, (try fstatLocalFile(child_backing_fd)).inode);

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

test "fork does not mint child backing proof from unproven parent backing" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const out_dir = try pathZ(arena, "{s}/children", .{root_dir});
    const runtime_dir = try pathZ(arena, "{s}/runtime", .{root_dir});
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.runtime_dir_env, runtime_dir);

    const ram = try arena.alloc(u8, chunk_size);
    @memset(ram, 0x7B);
    const memory = try saveMemoryWithBacking(arena, parent_dir, ram);
    try saveManifest(arena, parent_dir, testForkManifest(memory, ram.len, 11));

    _ = try fork(arena, .{ .parent_dir = parent_dir, .out_dir = out_dir, .count = 1, .environ_map = &env });
    const child_dir = try pathZ(arena, "{s}/000000", .{out_dir});
    const child = try loadManifest(arena, child_dir);
    defer child.deinit();
    try std.testing.expect(child.value.memory.backing == null);

    const out = try arena.alloc(u8, ram.len);
    @memset(out, 0);
    try loadMemory(arena, child_dir, child.value.memory, out);
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

test "manifest rejects invalid network policy" {
    var memory_chunks = [_]?[]const u8{null} ** ((1 << 29) / chunk_size);
    var manifest = testForkManifest(.{ .chunk_size = chunk_size, .chunks = &memory_chunks }, 1 << 29, 3);

    manifest.network = .{ .kind = "future-net-v0" };
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));

    manifest.network = .{ .allow_cidrs = &.{"not-cidr"} };
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));

    manifest.network = .{ .allow_hosts = &.{"bad host"} };
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
}
