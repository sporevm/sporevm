//! Spore manifest and chunk store.
//!
//! A spore is a directory rooted at `manifest.json`. Guest memory is stored as
//! fixed-size `chunks/<blake3-hex>` files with all-zero chunks elided; optional
//! writable disks use verified chunk indexes and CAS objects. Machine state is
//! normalized architectural aarch64 state — never raw
//! hypervisor structures (see docs/spore-format.md). Formats v2 and v3 are the
//! current manifest contracts; future versions should be deliberate migrations.
//!
//! Manifests and chunks may come from untrusted storage: parsing is strict,
//! chunk contents are verified against their ids before use, and restore
//! fails closed on any mismatch. See SECURITY.md.

const std = @import("std");
const builtin = @import("builtin");
const board = @import("aarch64/board.zig");
const aarch64_topology = @import("aarch64/topology.zig");
const chunklib = @import("chunk.zig");
const disk_index = @import("disk_index.zig");
const generation = @import("generation.zig");
const gicv3 = @import("aarch64/gicv3.zig");
const local_paths = @import("local_paths.zig");
const spore_net_policy = @import("spore_net_policy.zig");
const topology = @import("topology.zig");
const virtqueue = @import("virtio/queue.zig");
const Blake3 = std.crypto.hash.Blake3;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const format_version_legacy_v0: u32 = 0;
pub const format_version_legacy_v1: u32 = 1;
pub const format_version: u32 = 2;
pub const format_version_v1: u32 = 3;
pub const max_manifest_bytes: usize = 64 * 1024 * 1024;
pub const machine_schema_version_v1: u32 = 1;
pub const chunk_size: usize = 2 * 1024 * 1024;
pub const ram_backing_kind = "map-private-file-v0";
pub const ram_backing_path = "ram.backing";
pub const ram_backing_proof_path = "ram.backing.proof";
pub const memory_object_namespace = "memory/blake3";

const local_backing_proof_version_v1: u32 = 1;
const local_backing_proof_version_v2: u32 = 2;
const local_backing_producer = "sporevm-local-ram-backing-v0";
const local_backing_verity_algorithm_sha256 = "sha256";
const local_backing_key_path = "local-ram-backing.key";
const local_backing_key_len = HmacSha256.key_length;
const local_backing_proof_max_bytes = 16 * 1024;
const fs_verity_hash_alg_sha256: u16 = 1;

pub const Error = error{
    BadManifest,
    FormatTooOld,
    BadChunk,
    BadForkCount,
    UnsupportedVcpuCount,
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

pub const PlatformV1 = struct {
    arch: []const u8 = "aarch64",
    cpu_profile: []const u8,
    device_model_version: u32,
    vcpu_count: topology.VcpuCount,
    ram_base: u64,
    ram_size: u64,
    gic_dist_base: u64,
    gic_redist_base: u64,
    gic_redist_stride: u64,
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

pub const VcpuState = struct {
    index: topology.VcpuIndex,
    mpidr: aarch64_topology.Mpidr,
    gprs: [31]u64,
    pc: u64,
    cpsr: u64,
    fpcr: u64,
    fpsr: u64,
    /// 32 Q registers as pairs of u64 (little-endian halves).
    simd: [32][2]u64,
    sys_regs: []SysRegEntry,
    /// Per-vCPU GIC CPU-interface (ICC) registers, by architectural name.
    icc_regs: []SysRegEntry,
    vtimer: VtimerState,
};

pub const MachineStateV1 = struct {
    schema_version: u32 = machine_schema_version_v1,
    vcpus: []VcpuState,
    /// Interrupt controller state. Portable producers use the multi-vCPU GICv3
    /// shape; same-backend temporary producers must tag private blobs so other
    /// backends fail closed.
    gic: gicv3.State,
};

pub const MemoryBacking = struct {
    kind: []const u8 = ram_backing_kind,
    path: []const u8,
    size: u64,
};

pub const MemoryChunk = disk_index.DiskIndexChunk;

pub const MemoryManifest = struct {
    kind: []const u8 = disk_index.disk_index_kind_v1,
    logical_size: u64,
    chunk_size: u64,
    hash_algorithm: []const u8 = rootfs_storage_hash_algorithm_blake3,
    object_namespace: []const u8 = memory_object_namespace,
    chunks: []const MemoryChunk = &.{},
    zero_chunks: []const u64 = &.{},
    /// Optional same-host acceleration hint. Chunks remain the portable,
    /// verified source of truth; backends may ignore this and materialize
    /// from chunks instead.
    backing: ?MemoryBacking = null,
};

pub const LocalBackingRestoreSource = enum {
    local_backing,
    chunks,
};

pub const LocalBackingRestoreReason = enum {
    not_attempted,
    no_backing,
    backing_unavailable,
    backing_not_regular,
    backing_size_mismatch,
    proof_unavailable,
    proof_invalid,
    key_unavailable,
    proof_mismatch,
    proof_mac_invalid,
    proof_mac_mismatch,
    verity_unavailable,
    verity_mismatch,
    proof_valid,
};

pub const LocalBackingPlan = struct {
    fd: ?std.c.fd_t = null,
    source: LocalBackingRestoreSource = .chunks,
    reason: LocalBackingRestoreReason = .not_attempted,
};

const LocalBackingProof = struct {
    schema_version: u32,
    memory_fingerprint: []const u8,
    backing: LocalBackingProofBacking,
    file: LocalBackingFileIdentity,
    producer: []const u8,
    verity: ?LocalBackingVerity = null,
    mac: []const u8,
};

const LocalBackingVerity = struct {
    algorithm: []const u8,
    digest: []const u8,
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

fn localBackingFileIdentityEqual(a: LocalBackingFileIdentity, b: LocalBackingFileIdentity) bool {
    return std.mem.eql(u8, a.file_type, b.file_type) and
        a.device == b.device and
        a.inode == b.inode and
        a.owner_uid == b.owner_uid and
        a.size == b.size and
        a.mtime_sec == b.mtime_sec and
        a.mtime_nsec == b.mtime_nsec;
}

fn localBackingFileIdentityEqualWithoutMtime(a: LocalBackingFileIdentity, b: LocalBackingFileIdentity) bool {
    return std.mem.eql(u8, a.file_type, b.file_type) and
        a.device == b.device and
        a.inode == b.inode and
        a.owner_uid == b.owner_uid and
        a.size == b.size;
}

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
pub const disk_chunk_size: u64 = 64 * 1024;

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
pub const disk_kind_chunk_index = "chunk-index-disk-v0";
pub const disk_digest_prefix = rootfs_digest_prefix;

pub const Disk = struct {
    kind: []const u8 = disk_kind_chunk_index,
    device: RootfsDevice,
    size: u64,
    /// BLAKE3 digest of the disk index.
    base: []const u8,
    chunk_size: u64 = 64 * 1024,
    hash_algorithm: []const u8 = rootfs_storage_hash_algorithm_blake3,
    object_namespace: []const u8 = rootfs_storage_object_namespace,
    /// Must be empty for chunk-index manifests.
    layers: []const []const u8 = &.{},
};

pub const network_kind_spore = "spore-net-v0";
pub const network_default_deny = "deny";

pub const NetworkHostPortRule = struct {
    host: []const u8,
    ports: []const u16,
};

pub const NetworkBoundServiceRequirement = struct {
    name: []const u8,
    guest_host: []const u8,
    guest_port: u16,
};

pub const NetworkRequirements = struct {
    tcp_ipv4: bool = true,
    exact_host_port: bool = false,
    bound_services: bool = false,
};

pub const Network = struct {
    kind: []const u8 = network_kind_spore,
    default_action: ?[]const u8 = null,
    allow_cidrs: []const []const u8 = &.{},
    allow_hosts: []const []const u8 = &.{},
    allow_host_ports: []const NetworkHostPortRule = &.{},
    bound_services: []const NetworkBoundServiceRequirement = &.{},
    requirements: NetworkRequirements = .{},
};

pub const default_session_id = "default";
pub const session_kind_process = "process";
pub const max_sessions = 16;
pub const max_session_id_len = 63;

pub const SessionStreams = struct {
    stdin: bool = false,
    stdout: bool = true,
    stderr: bool = true,
    terminal: bool = false,
};

pub const Session = struct {
    id: []const u8 = default_session_id,
    kind: []const u8 = session_kind_process,
    streams: SessionStreams = .{},
};

pub const max_exec_default_env = 64;
pub const max_exec_default_env_entry_len = 255;
pub const max_exec_default_working_dir_len = 255;

pub const ExecDefaults = struct {
    env: []const []const u8 = &.{},
    working_dir: ?[]const u8 = null,
};

pub const SessionAttachRequest = struct {
    id: []const u8 = default_session_id,
    stdin: bool = false,
    terminal: bool = false,
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
pub const max_annotations_json_bytes = 64 * 1024;
pub const Annotations = std.json.ArrayHashMap([]const u8);

pub const Manifest = struct {
    version: u32 = format_version,
    annotations: Annotations = .{},
    platform: Platform,
    machine: MachineState,
    devices: []TransportState,
    generation: GenerationState,
    rootfs: ?Rootfs = null,
    disk: ?Disk = null,
    network: ?Network = null,
    sessions: []const Session = &.{},
    exec_defaults: ?ExecDefaults = null,
    memory: MemoryManifest,

    pub fn jsonStringify(self: @This(), writer: anytype) !void {
        try stringifyManifest(self, writer);
    }
};

pub const ManifestV1 = struct {
    version: u32 = format_version_v1,
    annotations: Annotations = .{},
    platform: PlatformV1,
    machine: MachineStateV1,
    devices: []TransportState,
    generation: GenerationState,
    rootfs: ?Rootfs = null,
    disk: ?Disk = null,
    network: ?Network = null,
    sessions: []const Session = &.{},
    exec_defaults: ?ExecDefaults = null,
    memory: MemoryManifest,

    pub fn jsonStringify(self: @This(), writer: anytype) !void {
        try stringifyManifest(self, writer);
    }
};

fn stringifyManifest(manifest: anytype, writer: anytype) !void {
    try writer.beginObject();
    inline for (std.meta.fields(@TypeOf(manifest))) |field| {
        if (comptime std.mem.eql(u8, field.name, "exec_defaults")) {
            if (@field(manifest, field.name)) |defaults| {
                try writer.objectField(field.name);
                try writer.write(defaults);
            }
        } else {
            try writer.objectField(field.name);
            try writer.write(@field(manifest, field.name));
        }
    }
    try writer.endObject();
}

// --- file helpers (libc-based; std.Io migration is a later cleanup) ---------

pub fn createSnapshotRoot(allocator: std.mem.Allocator, dir: []const u8) Error!void {
    const dir_z = try pathZ(allocator, "{s}", .{dir});
    const rc = std.c.mkdir(dir_z, 0o700);
    if (rc != 0) {
        return switch (std.c.errno(rc)) {
            .EXIST => error.AlreadyExists,
            else => error.IoFailed,
        };
    }
    const fd = try openDirectoryNoFollow(dir_z);
    defer _ = std.c.close(fd);
}

fn openDirectoryNoFollow(path: [:0]const u8) Error!std.c.fd_t {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.IoFailed;
    return fd;
}

fn writeFileAll(path: [:0]const u8, data: []const u8) Error!void {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0o644));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);
    try writeAllFd(fd, data);
}

fn writeNewFileAll(path: [:0]const u8, data: []const u8) Error!void {
    const fd = try createNewFile(path, 0o644);
    defer _ = std.c.close(fd);
    try writeAllFd(fd, data);
}

fn writeFileAllIfMissing(path: [:0]const u8, data: []const u8) Error!void {
    const fd = createNewFile(path, 0o644) catch |err| switch (err) {
        error.AlreadyExists => {
            try verifyExistingFile(path, data);
            return;
        },
        else => |e| return e,
    };
    defer _ = std.c.close(fd);
    try writeAllFd(fd, data);
}

fn createNewFile(path: [:0]const u8, mode: c_uint) Error!std.c.fd_t {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, mode);
    if (fd < 0) {
        return switch (std.c.errno(fd)) {
            .EXIST => error.AlreadyExists,
            else => error.IoFailed,
        };
    }
    return fd;
}

fn writeAllFd(fd: std.c.fd_t, data: []const u8) Error!void {
    var done: usize = 0;
    while (done < data.len) {
        const n = std.c.write(fd, data.ptr + done, data.len - done);
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
}

fn verifyExistingFile(path: [:0]const u8, expected: []const u8) Error!void {
    const fd = try openReadOnlyNoFollow(path);
    defer _ = std.c.close(fd);

    const stat = try fstatLocalFile(fd);
    if (stat.identity().size != expected.len) return error.BadChunk;

    var buf: [8192]u8 = undefined;
    var done: usize = 0;
    while (done < expected.len) {
        const len = @min(buf.len, expected.len - done);
        const offset = std.math.cast(std.c.off_t, done) orelse return error.BadChunk;
        const n = std.c.pread(fd, buf[0..len].ptr, len, offset);
        if (n <= 0) return error.BadChunk;
        const read_len: usize = @intCast(n);
        if (!std.mem.eql(u8, buf[0..read_len], expected[done..][0..read_len])) return error.BadChunk;
        done += read_len;
    }
}

fn publishFileNoOverwrite(tmp_path: [:0]const u8, final_path: [:0]const u8) Error!void {
    const rc = std.c.link(tmp_path.ptr, final_path.ptr);
    if (rc != 0) {
        return switch (std.c.errno(rc)) {
            .EXIST => error.AlreadyExists,
            else => error.IoFailed,
        };
    }
    if (std.c.unlink(tmp_path.ptr) != 0) {
        _ = std.c.unlink(final_path.ptr);
        return error.IoFailed;
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
    const rc = std.c.mkdir(path, 0o755);
    if (rc != 0) {
        switch (std.c.errno(rc)) {
            .EXIST => {},
            else => return error.IoFailed,
        }
    }
    const fd = try openDirectoryNoFollow(path);
    defer _ = std.c.close(fd);
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

const OptionalHardlinkError = error{
    Unavailable,
    IoFailed,
    OutOfMemory,
};

fn classifyOptionalHardlinkErrno(value: std.c.E) OptionalHardlinkError {
    return switch (value) {
        .NOENT, .NOTDIR, .LOOP, .EXIST, .XDEV, .OPNOTSUPP, .PERM, .ACCES, .MLINK => error.Unavailable,
        .NOMEM => error.OutOfMemory,
        else => error.IoFailed,
    };
}

fn hardlinkOptionalPath(target: []const u8, link_path: []const u8) OptionalHardlinkError!void {
    const target_z = try std.heap.c_allocator.dupeZ(u8, target);
    defer std.heap.c_allocator.free(target_z);
    const link_z = try std.heap.c_allocator.dupeZ(u8, link_path);
    defer std.heap.c_allocator.free(link_z);
    const rc = std.c.link(target_z, link_z);
    if (rc != 0) return classifyOptionalHardlinkErrno(std.c.errno(rc));
}

fn openReadOnlyNoFollow(path: [:0]const u8) Error!std.c.fd_t {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.IoFailed;
    return fd;
}

const OptionalFileOpenError = error{
    Unavailable,
    IoFailed,
    OutOfMemory,
};

fn classifyOptionalPathErrno(value: std.c.E) OptionalFileOpenError {
    return switch (value) {
        .NOENT, .NOTDIR, .LOOP => error.Unavailable,
        .NOMEM => error.OutOfMemory,
        else => error.IoFailed,
    };
}

fn requireOptionalRegularPathNoFollow(path: [:0]const u8) OptionalFileOpenError!void {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var st: linux.Statx = undefined;
        const rc = linux.statx(std.c.AT.FDCWD, path, std.c.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true }, &st);
        const result = linux.errno(rc);
        if (result != .SUCCESS) return classifyOptionalPathErrno(result);
        if (!linux.S.ISREG(st.mode)) return error.Unavailable;
    } else {
        var st: std.c.Stat = undefined;
        const rc = std.c.fstatat(std.c.AT.FDCWD, path, &st, std.c.AT.SYMLINK_NOFOLLOW);
        if (rc != 0) return classifyOptionalPathErrno(std.c.errno(rc));
        if (!std.c.S.ISREG(st.mode)) return error.Unavailable;
    }
}

fn openOptionalReadOnlyNoFollow(path: [:0]const u8) OptionalFileOpenError!std.c.fd_t {
    try requireOptionalRegularPathNoFollow(path);
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(c_uint, 0));
    if (fd >= 0) return fd;
    return classifyOptionalPathErrno(std.c.errno(fd));
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

fn localBackingChunksPlan(reason: LocalBackingRestoreReason) LocalBackingPlan {
    return .{ .source = .chunks, .reason = reason };
}

fn memoryIndex(manifest: MemoryManifest) disk_index.DiskIndex {
    return .{
        .kind = manifest.kind,
        .logical_size = manifest.logical_size,
        .chunk_size = manifest.chunk_size,
        .hash_algorithm = manifest.hash_algorithm,
        .object_namespace = manifest.object_namespace,
        .chunks = manifest.chunks,
        .zero_chunks = manifest.zero_chunks,
    };
}

fn memoryIndexDescriptor(_: MemoryManifest, expected_size: u64) disk_index.Descriptor {
    return .{
        .logical_size = expected_size,
        .chunk_size = chunk_size,
        .hash_algorithm = rootfs_storage_hash_algorithm_blake3,
        .object_namespace = memory_object_namespace,
    };
}

fn memoryIndexIdentity(allocator: std.mem.Allocator, memory: MemoryManifest, expected_size: u64) Error![]const u8 {
    if (expected_size > std.math.maxInt(usize)) return error.BadManifest;
    _ = try validateMemoryForRam(memory, @intCast(expected_size));
    const encoded_index = disk_index.encodeCanonicalAlloc(allocator, memoryIndex(memory)) catch |err| return switch (err) {
        error.BadManifest => error.BadManifest,
        error.FormatTooOld => error.FormatTooOld,
        error.OutOfMemory => error.OutOfMemory,
    };
    allocator.free(encoded_index.bytes);
    return encoded_index.digest;
}

fn proofMac(
    key: *const [local_backing_key_len]u8,
    memory_fingerprint: []const u8,
    schema_version: u32,
    backing: LocalBackingProofBacking,
    file: LocalBackingFileIdentity,
    producer: []const u8,
    verity: ?LocalBackingVerity,
) Error![HmacSha256.mac_length]u8 {
    if (!proofVersionAcceptsVerity(schema_version, verity)) return error.BadManifest;
    var mac = HmacSha256.init(key);
    mac.update("sporevm-local-ram-backing-proof-v1");
    macU64(&mac, schema_version);
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
    if (verity) |v| {
        macBytes(&mac, v.algorithm);
        macBytes(&mac, v.digest);
    }
    var out: [HmacSha256.mac_length]u8 = undefined;
    mac.final(&out);
    return out;
}

fn proofVersionAcceptsVerity(schema_version: u32, verity: ?LocalBackingVerity) bool {
    return switch (schema_version) {
        local_backing_proof_version_v1 => verity == null,
        local_backing_proof_version_v2 => verity != null,
        else => false,
    };
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
    const root = local_paths.runtimeRootPath(allocator, environ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.IoFailed,
    };
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
    if (!create) {
        requireOptionalRegularPathNoFollow(path) catch |err| return switch (err) {
            error.Unavailable => null,
            error.IoFailed => error.IoFailed,
            error.OutOfMemory => error.OutOfMemory,
        };
    }
    var fd = std.c.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(c_uint, 0));
    if (fd < 0) {
        const open_errno = std.c.errno(fd);
        if (!create) return switch (classifyOptionalPathErrno(open_errno)) {
            error.Unavailable => null,
            error.IoFailed => error.IoFailed,
            error.OutOfMemory => error.OutOfMemory,
        };
        if (open_errno == .NOMEM) return error.OutOfMemory;
        if (open_errno != .NOENT) return error.IoFailed;
        fd = std.c.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(c_uint, 0o600));
        if (fd < 0) return if (std.c.errno(fd) == .NOMEM) error.OutOfMemory else error.IoFailed;
        defer _ = std.c.close(fd);
        var key: [local_backing_key_len]u8 = undefined;
        try fillRandom(&key);
        try writeFdAll(fd, &key);
        if (std.c.fchmod(fd, 0o600) != 0) return error.IoFailed;
        return key;
    }
    defer _ = std.c.close(fd);
    const st = fstatLocalFile(fd) catch |err| {
        if (!create and err == error.BadManifest) return null;
        return err;
    };
    if (st.owner_uid != std.c.getuid() or st.size != local_backing_key_len) {
        if (!create) return null;
        return error.BadManifest;
    }
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

const OptionalProofReadError = error{
    Unavailable,
    Invalid,
    IoFailed,
    OutOfMemory,
};

fn readOptionalProof(allocator: std.mem.Allocator, path: [:0]const u8, max: usize) OptionalProofReadError![]u8 {
    const fd = openOptionalReadOnlyNoFollow(path) catch |err| return switch (err) {
        error.Unavailable => error.Unavailable,
        error.IoFailed => error.IoFailed,
        error.OutOfMemory => error.OutOfMemory,
    };
    defer _ = std.c.close(fd);
    const st = fstatLocalFile(fd) catch |err| return switch (err) {
        error.BadManifest => error.Invalid,
        else => error.IoFailed,
    };
    if (st.size > std.math.maxInt(usize)) return error.Invalid;
    const size: usize = @intCast(st.size);
    if (size > max) return error.Invalid;
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    var done: usize = 0;
    while (done < buf.len) {
        const n = std.c.read(fd, buf.ptr + done, buf.len - done);
        if (n < 0) return error.IoFailed;
        if (n == 0) return error.Invalid;
        done += @intCast(n);
    }
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
    if (!proofVersionAcceptsVerity(proof.schema_version, proof.verity)) return false;
    if (proof.verity) |verity| {
        if (!proofVerityShapeValid(verity)) return false;
    }
    return std.mem.eql(u8, proof.memory_fingerprint, memory_fingerprint) and
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

fn proofVerityShapeValid(verity: LocalBackingVerity) bool {
    return std.mem.eql(u8, verity.algorithm, local_backing_verity_algorithm_sha256) and
        isLowerHexDigest(verity.digest, Sha256.digest_length);
}

fn isLowerHexDigest(value: []const u8, comptime digest_len: usize) bool {
    if (value.len != digest_len * 2) return false;
    for (value) |byte| {
        const is_digit = byte >= '0' and byte <= '9';
        const is_lower_hex = byte >= 'a' and byte <= 'f';
        if (!is_digit and !is_lower_hex) return false;
    }
    return true;
}

const FsVerityEnableArg = extern struct {
    version: u32,
    hash_algorithm: u32,
    block_size: u32,
    salt_size: u32,
    salt_ptr: u64,
    sig_size: u32,
    reserved1: u32,
    sig_ptr: u64,
    reserved2: [11]u64,
};

const FsVerityDigestHeader = extern struct {
    digest_algorithm: u16,
    digest_size: u16,
};

const FsVerityDigestSha256 = extern struct {
    header: FsVerityDigestHeader,
    digest: [Sha256.digest_length]u8,
};

fn proofVerityForRead(allocator: std.mem.Allocator, fd: std.c.fd_t) Error!?LocalBackingVerity {
    if (comptime builtin.os.tag != .linux) return null;
    return linuxMeasureFsVerity(allocator, fd);
}

const FsVerityEnableError = error{
    Unavailable,
    IoFailed,
};

fn linuxEnableFsVerity(fd: std.c.fd_t) FsVerityEnableError!void {
    const linux = std.os.linux;
    var arg = FsVerityEnableArg{
        .version = 1,
        .hash_algorithm = fs_verity_hash_alg_sha256,
        .block_size = @intCast(std.heap.pageSize()),
        .salt_size = 0,
        .salt_ptr = 0,
        .sig_size = 0,
        .reserved1 = 0,
        .sig_ptr = 0,
        .reserved2 = .{0} ** 11,
    };
    const request = linux.IOCTL.IOW('f', 133, FsVerityEnableArg);
    try fsVerityEnableResult(linux.errno(linux.ioctl(fd, request, @intFromPtr(&arg))));
}

fn fsVerityEnableResult(result: std.os.linux.E) FsVerityEnableError!void {
    switch (result) {
        .SUCCESS, .EXIST => {},
        .ACCES, .INVAL, .NOTTY, .OPNOTSUPP => return error.Unavailable,
        else => return error.IoFailed,
    }
}

fn linuxMeasureFsVerity(allocator: std.mem.Allocator, fd: std.c.fd_t) Error!?LocalBackingVerity {
    const linux = std.os.linux;
    var measured = FsVerityDigestSha256{
        .header = .{
            .digest_algorithm = fs_verity_hash_alg_sha256,
            .digest_size = Sha256.digest_length,
        },
        .digest = .{0} ** Sha256.digest_length,
    };
    const request = linux.IOCTL.IOWR('f', 134, FsVerityDigestHeader);
    if (!try fsVerityMeasureAvailable(linux.errno(linux.ioctl(fd, request, @intFromPtr(&measured))))) return null;
    if (measured.header.digest_algorithm != fs_verity_hash_alg_sha256) return error.IoFailed;
    if (measured.header.digest_size != Sha256.digest_length) return error.IoFailed;
    return .{
        .algorithm = local_backing_verity_algorithm_sha256,
        .digest = try hexAlloc(allocator, &measured.digest),
    };
}

fn fsVerityMeasureAvailable(result: std.os.linux.E) Error!bool {
    return switch (result) {
        .SUCCESS => true,
        .NODATA, .NOTTY, .OPNOTSUPP => false,
        else => error.IoFailed,
    };
}

const LocalBackingProofWriteOps = struct {
    fn proofForWrite(self: @This(), allocator: std.mem.Allocator, fd: std.c.fd_t) Error!ProofVerityWriteResult {
        if (comptime builtin.os.tag != .linux) return .{};
        return proofVerityForWriteWithOps(allocator, fd, self);
    }

    fn measure(_: @This(), allocator: std.mem.Allocator, fd: std.c.fd_t) Error!?LocalBackingVerity {
        return linuxMeasureFsVerity(allocator, fd);
    }

    fn enable(_: @This(), fd: std.c.fd_t) FsVerityEnableError!void {
        return linuxEnableFsVerity(fd);
    }

    fn chmod(_: @This(), fd: std.c.fd_t, mode: std.c.mode_t) Error!void {
        if (std.c.fchmod(fd, mode) != 0) return error.IoFailed;
    }

    fn stat(_: @This(), fd: std.c.fd_t) Error!LocalFileStat {
        return fstatLocalFile(fd);
    }
};

const ProofVerityWriteAttempt = union(enum) {
    success: ?LocalBackingVerity,
    failure: Error,
};

const ProofVerityWriteResult = struct {
    verity: ?LocalBackingVerity = null,
    accepts_mtime_transition: bool = false,
};

fn proofVerityForWriteWithOps(
    allocator: std.mem.Allocator,
    fd: std.c.fd_t,
    ops: anytype,
) Error!ProofVerityWriteResult {
    if (try ops.measure(allocator, fd)) |existing| return .{ .verity = existing };

    const initial_stat = try ops.stat(fd);
    const initial_file = initial_stat.identity();
    const original_mode: std.c.mode_t = @intCast(initial_stat.mode & 0o7777);
    if (initial_file.owner_uid != std.c.getuid() or original_mode & 0o222 != 0) return error.IoFailed;

    try ops.chmod(fd, original_mode | 0o200);
    // A crash can leave the optional backing owner-writable, but the proof is
    // published only after exact mode and identity restoration. Chunks remain
    // authoritative, so an unproved backing falls back instead of being trusted.
    const attempt: ProofVerityWriteAttempt = blk: {
        const writable_stat = ops.stat(fd) catch |err| break :blk .{ .failure = err };
        if (!localBackingFileIdentityEqual(initial_file, writable_stat.identity()) or
            writable_stat.owner_uid != initial_file.owner_uid)
        {
            break :blk .{ .failure = error.IoFailed };
        }
        ops.enable(fd) catch |err| break :blk switch (err) {
            error.Unavailable => .{ .success = null },
            error.IoFailed => .{ .failure = error.IoFailed },
        };
        const measured = ops.measure(allocator, fd) catch |err| break :blk .{ .failure = err };
        break :blk if (measured) |verity|
            .{ .success = verity }
        else
            .{ .failure = error.IoFailed };
    };
    var release_attempt = true;
    defer if (release_attempt) switch (attempt) {
        .success => |verity| if (verity) |value| allocator.free(value.digest),
        .failure => {},
    };

    ops.chmod(fd, original_mode) catch return error.IoFailed;
    const restored_stat = try ops.stat(fd);
    const enabled_new_verity = switch (attempt) {
        .success => |verity| verity != null,
        .failure => false,
    };
    const restored_file = restored_stat.identity();
    const identity_matches = if (enabled_new_verity)
        localBackingFileIdentityEqualWithoutMtime(initial_file, restored_file)
    else
        localBackingFileIdentityEqual(initial_file, restored_file);
    if ((restored_stat.mode & 0o7777) != original_mode or !identity_matches or
        restored_stat.owner_uid != initial_file.owner_uid)
    {
        return error.IoFailed;
    }

    return switch (attempt) {
        .success => |verity| blk: {
            release_attempt = false;
            break :blk .{
                .verity = verity,
                .accepts_mtime_transition = enabled_new_verity,
            };
        },
        .failure => |err| return err,
    };
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
    try writeLocalMemoryBackingProofForFd(allocator, environ, dir, memory, expected_size, fd, null);
}

fn formatLocalBackingProofWriteOk(buf: []u8, schema_version: u32, has_verity: bool, elapsed_us: u64) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "local RAM backing proof metrics: operation=write status=ok reason={s} schema={d} verity={s} elapsed_us={d}",
        .{
            if (has_verity) "verity_enabled" else "verity_unavailable",
            schema_version,
            if (has_verity) local_backing_verity_algorithm_sha256 else "none",
            elapsed_us,
        },
    ) catch "local RAM backing proof metrics: formatting_failed=1";
}

fn formatLocalBackingProofWriteError(buf: []u8, elapsed_us: u64, err: anyerror) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "local RAM backing proof metrics: operation=write status=error reason=error schema=0 verity=unknown elapsed_us={d} error={s}",
        .{ elapsed_us, @errorName(err) },
    ) catch "local RAM backing proof metrics: formatting_failed=1";
}

fn formatLocalBackingProofValidationOk(buf: []u8, opened: LocalBackingOpen, validation_us: u64, precharge_us: u64) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "local RAM backing proof metrics: operation=validate status=ok source={s} reason={s} schema={d} verity={s} validation_us={d} precharge_us={d}",
        .{
            @tagName(opened.plan.source),
            @tagName(opened.plan.reason),
            opened.proof_schema_version,
            if (opened.proof_has_verity) local_backing_verity_algorithm_sha256 else "none",
            validation_us,
            precharge_us,
        },
    ) catch "local RAM backing proof metrics: formatting_failed=1";
}

fn formatLocalBackingProofValidationError(buf: []u8, validation_us: u64, err: anyerror) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "local RAM backing proof metrics: operation=validate status=error source=error reason=error schema=0 verity=unknown validation_us={d} precharge_us=0 error={s}",
        .{ validation_us, @errorName(err) },
    ) catch "local RAM backing proof metrics: formatting_failed=1";
}

fn writeLocalMemoryBackingProofForFd(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    dir: []const u8,
    memory: MemoryManifest,
    expected_size: u64,
    fd: std.c.fd_t,
    expected_file: ?LocalBackingFileIdentity,
) Error!void {
    return writeLocalMemoryBackingProofForFdWithOps(
        allocator,
        environ,
        dir,
        memory,
        expected_size,
        fd,
        expected_file,
        LocalBackingProofWriteOps{},
    );
}

fn writeLocalMemoryBackingProofForFdWithOps(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    dir: []const u8,
    memory: MemoryManifest,
    expected_size: u64,
    fd: std.c.fd_t,
    expected_file: ?LocalBackingFileIdentity,
    verity_ops: anytype,
) Error!void {
    const backing = memory.backing orelse return;
    const start_ns = localBackingMonotonicNs();
    errdefer |err| {
        var metrics_buf: [256]u8 = undefined;
        std.log.debug("{s}", .{formatLocalBackingProofWriteError(&metrics_buf, localBackingElapsedUs(start_ns), err)});
    }
    try validateMemoryBacking(backing, expected_size);
    const initial_file = (try verity_ops.stat(fd)).identity();
    if (initial_file.size != expected_size) return error.BadManifest;
    if (expected_file) |expected| {
        if (!localBackingFileIdentityEqual(initial_file, expected)) return error.IoFailed;
    }
    const key = (try localBackingKey(allocator, environ, true)) orelse return error.IoFailed;
    const memory_fingerprint = try memoryIndexIdentity(allocator, memory, expected_size);
    defer allocator.free(memory_fingerprint);
    const proof_backing = proofBackingFromManifest(backing);
    const verity_result = try verity_ops.proofForWrite(allocator, fd);
    defer if (verity_result.verity) |value| allocator.free(value.digest);
    const file = (try verity_ops.stat(fd)).identity();
    if (file.size != expected_size) return error.BadManifest;
    const identity_matches = if (verity_result.accepts_mtime_transition)
        localBackingFileIdentityEqualWithoutMtime(initial_file, file)
    else
        localBackingFileIdentityEqual(initial_file, file);
    if (!identity_matches) return error.IoFailed;
    const schema_version: u32 = if (verity_result.verity == null) local_backing_proof_version_v1 else local_backing_proof_version_v2;
    const mac = try proofMac(&key, memory_fingerprint, schema_version, proof_backing, file, local_backing_producer, verity_result.verity);
    const mac_hex = try hexAlloc(allocator, &mac);
    defer allocator.free(mac_hex);
    const proof = LocalBackingProof{
        .schema_version = schema_version,
        .memory_fingerprint = memory_fingerprint,
        .backing = proof_backing,
        .file = file,
        .producer = local_backing_producer,
        .verity = verity_result.verity,
        .mac = mac_hex,
    };
    const json = std.json.Stringify.valueAlloc(allocator, proof, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    }) catch return error.OutOfMemory;
    defer allocator.free(json);
    const pre_publish_file = (try verity_ops.stat(fd)).identity();
    if (!localBackingFileIdentityEqual(file, pre_publish_file)) return error.IoFailed;
    const proof_path = try pathZ(allocator, "{s}/{s}", .{ dir, ram_backing_proof_path });
    try writeNewFileAll(proof_path, json);
    var metrics_buf: [256]u8 = undefined;
    std.log.debug("{s}", .{formatLocalBackingProofWriteOk(&metrics_buf, schema_version, verity_result.verity != null, localBackingElapsedUs(start_ns))});
}

const LocalBackingOpen = struct {
    plan: LocalBackingPlan,
    file: ?LocalBackingFileIdentity = null,
    proof_schema_version: u32 = 0,
    proof_has_verity: bool = false,
};

fn localBackingOpenChunks(reason: LocalBackingRestoreReason) LocalBackingOpen {
    return .{ .plan = localBackingChunksPlan(reason) };
}

pub fn openProvenLocalMemoryBacking(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    dir: []const u8,
    memory: MemoryManifest,
    expected_size: u64,
) Error!LocalBackingPlan {
    return (try openProvenLocalMemoryBackingDetailed(allocator, environ, dir, memory, expected_size)).plan;
}

fn openProvenLocalMemoryBackingDetailed(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    dir: []const u8,
    memory: MemoryManifest,
    expected_size: u64,
) Error!LocalBackingOpen {
    const start_ns = localBackingMonotonicNs();
    const opened = openProvenLocalMemoryBackingDetailedUnmeasured(
        allocator,
        environ,
        dir,
        memory,
        expected_size,
    ) catch |err| {
        var metrics_buf: [320]u8 = undefined;
        std.log.debug("{s}", .{formatLocalBackingProofValidationError(&metrics_buf, localBackingElapsedUs(start_ns), err)});
        return err;
    };
    const validation_us = localBackingElapsedUs(start_ns);
    var precharge_us: u64 = 0;
    if (opened.plan.fd) |fd| {
        const precharge_start_ns = localBackingMonotonicNs();
        prechargeBackingReadahead(fd);
        precharge_us = localBackingElapsedUs(precharge_start_ns);
    }
    var metrics_buf: [320]u8 = undefined;
    std.log.debug("{s}", .{formatLocalBackingProofValidationOk(&metrics_buf, opened, validation_us, precharge_us)});
    return opened;
}

fn openProvenLocalMemoryBackingDetailedUnmeasured(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    dir: []const u8,
    memory: MemoryManifest,
    expected_size: u64,
) Error!LocalBackingOpen {
    if (expected_size > std.math.maxInt(usize)) return error.BadManifest;
    _ = try validateMemoryForRam(memory, @intCast(expected_size));
    const backing = memory.backing orelse return localBackingOpenChunks(.no_backing);
    try validateMemoryBacking(backing, expected_size);
    const backing_path = try memoryBackingPath(allocator, dir, backing);
    const fd = openOptionalReadOnlyNoFollow(backing_path) catch |err| return switch (err) {
        error.Unavailable => localBackingOpenChunks(.backing_unavailable),
        error.IoFailed => error.IoFailed,
        error.OutOfMemory => error.OutOfMemory,
    };
    var handoff_fd = false;
    defer if (!handoff_fd) {
        _ = std.c.close(fd);
    };
    const file = (fstatLocalFile(fd) catch |err| return switch (err) {
        error.BadManifest => localBackingOpenChunks(.backing_not_regular),
        else => error.IoFailed,
    }).identity();
    if (file.size != expected_size) return localBackingOpenChunks(.backing_size_mismatch);

    const proof_path = try pathZ(allocator, "{s}/{s}", .{ dir, ram_backing_proof_path });
    const proof_bytes = readOptionalProof(allocator, proof_path, local_backing_proof_max_bytes) catch |err| return switch (err) {
        error.Unavailable => localBackingOpenChunks(.proof_unavailable),
        error.Invalid => localBackingOpenChunks(.proof_invalid),
        error.IoFailed => error.IoFailed,
        error.OutOfMemory => error.OutOfMemory,
    };
    defer allocator.free(proof_bytes);
    const parsed = std.json.parseFromSlice(LocalBackingProof, allocator, proof_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => localBackingOpenChunks(.proof_invalid),
    };
    defer parsed.deinit();

    const key = (try localBackingKey(allocator, environ, false)) orelse
        return localBackingOpenChunks(.key_unavailable);
    const memory_fingerprint = try memoryIndexIdentity(allocator, memory, expected_size);
    defer allocator.free(memory_fingerprint);
    const proof_backing = proofBackingFromManifest(backing);
    if (!proofFieldsMatch(parsed.value, memory_fingerprint, proof_backing, file)) return localBackingOpenChunks(.proof_mismatch);
    if (parsed.value.mac.len != HmacSha256.mac_length * 2) return localBackingOpenChunks(.proof_mac_invalid);
    var actual_mac: [HmacSha256.mac_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&actual_mac, parsed.value.mac) catch return localBackingOpenChunks(.proof_mac_invalid);
    const expected_mac = try proofMac(
        &key,
        memory_fingerprint,
        parsed.value.schema_version,
        proof_backing,
        file,
        local_backing_producer,
        parsed.value.verity,
    );
    if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, actual_mac, expected_mac)) return localBackingOpenChunks(.proof_mac_mismatch);
    if (parsed.value.verity) |proof_verity| {
        const measured_verity = (try proofVerityForRead(allocator, fd)) orelse return localBackingOpenChunks(.verity_unavailable);
        defer allocator.free(measured_verity.digest);
        if (!std.mem.eql(u8, measured_verity.algorithm, proof_verity.algorithm) or
            !std.mem.eql(u8, measured_verity.digest, proof_verity.digest))
        {
            return localBackingOpenChunks(.verity_mismatch);
        }
    }
    handoff_fd = true;
    return .{
        .plan = .{ .fd = fd, .source = .local_backing, .reason = .proof_valid },
        .file = file,
        .proof_schema_version = parsed.value.schema_version,
        .proof_has_verity = parsed.value.verity != null,
    };
}

fn localBackingMonotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn localBackingElapsedUs(start_ns: u64) u64 {
    const end_ns = localBackingMonotonicNs();
    return (end_ns -| start_ns) / std.time.ns_per_us;
}

/// Ask the kernel to read the backing file's data extents into the page cache
/// so first-touch guest RAM faults after restore hit memory instead of disk.
/// The first resume after the host evicts these pages otherwise pays scattered
/// synchronous reads (measured ~130ms extra on a 512MiB/32MiB-dense backing).
///
/// Only data extents are advised: readahead over holes materializes zero
/// pages in the page cache, which would bloat memory for large sparse
/// auto-memory backings. Purely advisory; every failure is ignored.
fn prechargeBackingReadahead(fd: std.c.fd_t) void {
    const seek_data: c_int = if (builtin.os.tag == .macos) 4 else 3;
    const seek_hole: c_int = if (builtin.os.tag == .macos) 3 else 4;
    const max_extents = 1024;

    const end = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (end <= 0) return;
    defer _ = std.c.lseek(fd, 0, std.c.SEEK.SET);

    var offset: std.c.off_t = 0;
    var extents: usize = 0;
    var advised_bytes: u64 = 0;
    while (offset < end and extents < max_extents) {
        const data_start = std.c.lseek(fd, offset, seek_data);
        if (data_start < 0) break; // ENXIO past last data, or unsupported.
        var data_end = std.c.lseek(fd, data_start, seek_hole);
        if (data_end < 0) data_end = end;
        if (data_end <= data_start) break;
        adviseRead(fd, data_start, data_end - data_start);
        advised_bytes += @intCast(data_end - data_start);
        extents += 1;
        offset = data_end;
    }
    if (extents > 0) {
        std.log.debug("backing readahead precharge: extents={d} bytes={d}", .{ extents, advised_bytes });
    }
}

fn adviseRead(fd: std.c.fd_t, offset: std.c.off_t, len: std.c.off_t) void {
    switch (builtin.os.tag) {
        .macos => {
            const Radvisory = extern struct {
                ra_offset: std.c.off_t,
                ra_count: c_int,
            };
            var remaining = len;
            var cursor = offset;
            while (remaining > 0) {
                const span: c_int = @intCast(@min(remaining, std.math.maxInt(c_int)));
                var ra = Radvisory{ .ra_offset = cursor, .ra_count = span };
                if (std.c.fcntl(fd, std.c.F.RDADVISE, @intFromPtr(&ra)) == -1) return;
                cursor += span;
                remaining -= span;
            }
        },
        .linux => {
            _ = std.os.linux.fadvise(fd, offset, len, std.os.linux.POSIX_FADV.WILLNEED);
        },
        else => {},
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
    try validateRootfsDevice(rootfs.device, devices);
    if (!std.mem.eql(u8, rootfs.artifact.format, rootfs_artifact_format_ext4)) return error.BadManifest;
    if (rootfs.artifact.size == 0 or rootfs.artifact.size > std.math.maxInt(usize)) return error.BadManifest;
    try validateRootfsDigest(rootfs.artifact.digest);
    if (rootfs.storage) |storage| try validateRootfsStorage(storage, rootfs, devices);
    if (rootfs.source) |source| try validateRootfsSource(source);
}

pub fn countBlockDevices(devices: []const TransportState) usize {
    var count: usize = 0;
    for (devices) |device| {
        if (device.device_id == rootfs_virtio_blk_device_id) count += 1;
    }
    return count;
}

fn validateRootfsDevice(device: RootfsDevice, devices: []const TransportState) Error!void {
    try validateRootfsDeviceShape(device);
    if (device.mmio_slot >= devices.len) return error.BadManifest;
    if (devices[device.mmio_slot].device_id != rootfs_virtio_blk_device_id) return error.BadManifest;
}

pub fn validateRootfsDeviceShape(device: RootfsDevice) Error!void {
    if (!std.mem.eql(u8, device.kind, rootfs_device_kind_virtio_mmio)) return error.BadManifest;
    if (!std.mem.eql(u8, device.role, rootfs_device_role)) return error.BadManifest;
    if (device.virtio_device_id != rootfs_virtio_blk_device_id) return error.BadManifest;
}

pub fn rootfsDeviceEql(a: RootfsDevice, b: RootfsDevice) bool {
    return std.mem.eql(u8, a.kind, b.kind) and
        std.mem.eql(u8, a.role, b.role) and
        a.virtio_device_id == b.virtio_device_id and
        a.mmio_slot == b.mmio_slot;
}

pub fn rootfsStorageEql(a: RootfsStorage, b: RootfsStorage) bool {
    return std.mem.eql(u8, a.kind, b.kind) and
        rootfsDeviceEql(a.device, b.device) and
        a.logical_size == b.logical_size and
        a.chunk_size == b.chunk_size and
        std.mem.eql(u8, a.hash_algorithm, b.hash_algorithm) and
        std.mem.eql(u8, a.index_digest, b.index_digest) and
        std.mem.eql(u8, a.base_identity, b.base_identity) and
        std.mem.eql(u8, a.object_namespace, b.object_namespace);
}

pub fn cloneRootfsDevice(allocator: std.mem.Allocator, device: RootfsDevice) !RootfsDevice {
    const kind = try allocator.dupe(u8, device.kind);
    errdefer allocator.free(kind);
    const role = try allocator.dupe(u8, device.role);
    errdefer allocator.free(role);
    return .{
        .kind = kind,
        .role = role,
        .virtio_device_id = device.virtio_device_id,
        .mmio_slot = device.mmio_slot,
    };
}

pub fn cloneRootfsStorage(allocator: std.mem.Allocator, storage: RootfsStorage) !RootfsStorage {
    const kind = try allocator.dupe(u8, storage.kind);
    errdefer allocator.free(kind);
    const device = try cloneRootfsDevice(allocator, storage.device);
    errdefer {
        allocator.free(device.kind);
        allocator.free(device.role);
    }
    const hash_algorithm = try allocator.dupe(u8, storage.hash_algorithm);
    errdefer allocator.free(hash_algorithm);
    const index_digest = try allocator.dupe(u8, storage.index_digest);
    errdefer allocator.free(index_digest);
    const base_identity = try allocator.dupe(u8, storage.base_identity);
    errdefer allocator.free(base_identity);
    const object_namespace = try allocator.dupe(u8, storage.object_namespace);
    errdefer allocator.free(object_namespace);

    return .{
        .kind = kind,
        .device = device,
        .logical_size = storage.logical_size,
        .chunk_size = storage.chunk_size,
        .hash_algorithm = hash_algorithm,
        .index_digest = index_digest,
        .base_identity = base_identity,
        .object_namespace = object_namespace,
    };
}

fn validateRootfsStorage(storage: RootfsStorage, rootfs: Rootfs, devices: []const TransportState) Error!void {
    try validateRootfsStorageDescriptor(storage);
    try validateRootfsDevice(storage.device, devices);
    if (!rootfsDeviceEql(storage.device, rootfs.device)) return error.BadManifest;
    if (storage.logical_size != rootfs.artifact.size) return error.BadManifest;
    if (!std.mem.eql(u8, storage.index_digest, rootfs.artifact.digest)) return error.BadManifest;
}

pub fn validateRootfsStorageDescriptor(storage: RootfsStorage) Error!void {
    if (!std.mem.eql(u8, storage.kind, rootfs_storage_kind_chunked_ext4)) return error.BadManifest;
    if (storage.logical_size == 0 or storage.logical_size > std.math.maxInt(usize)) return error.BadManifest;
    if (storage.chunk_size != disk_chunk_size) return error.BadManifest;
    if (!std.mem.eql(u8, storage.hash_algorithm, rootfs_storage_hash_algorithm_blake3)) return error.BadManifest;
    try validateRootfsDigest(storage.index_digest);
    try validateRootfsDigest(storage.base_identity);
    if (!std.mem.eql(u8, storage.base_identity, storage.index_digest)) return error.BadManifest;
    if (!std.mem.eql(u8, storage.object_namespace, rootfs_storage_object_namespace)) return error.BadManifest;
}

pub fn diskIndexDescriptorForStorage(storage: RootfsStorage) Error!disk_index.Descriptor {
    try validateRootfsStorageDescriptor(storage);
    return .{
        .logical_size = storage.logical_size,
        .chunk_size = storage.chunk_size,
        .hash_algorithm = storage.hash_algorithm,
        .object_namespace = storage.object_namespace,
        .index_digest = storage.index_digest,
    };
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
    try validateRootfsDevice(disk.device, devices);
    if (!rootfsDeviceEql(disk.device, rootfs.device)) return error.BadManifest;
    if (disk.size == 0 or disk.size != effectiveRootfsLogicalSize(rootfs)) return error.BadManifest;
    if (std.mem.eql(u8, disk.kind, disk_kind_chunk_index)) {
        try validateDiskDigest(disk.base);
        if (disk.chunk_size != disk_chunk_size) return error.BadManifest;
        if (!std.mem.eql(u8, disk.hash_algorithm, rootfs_storage_hash_algorithm_blake3)) return error.BadManifest;
        if (!std.mem.eql(u8, disk.object_namespace, rootfs_storage_object_namespace)) return error.BadManifest;
        if (disk.layers.len != 0) return error.BadManifest;
    } else if (std.mem.eql(u8, disk.kind, disk_kind_cow_block)) {
        return error.FormatTooOld;
    } else {
        return error.BadManifest;
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

pub fn validateNetwork(network: Network) Error!void {
    if (!std.mem.eql(u8, network.kind, network_kind_spore)) return error.BadManifest;
    if (network.default_action) |action| {
        if (!std.mem.eql(u8, action, network_default_deny)) return error.BadManifest;
    }
    if (network.allow_cidrs.len > spore_net_policy.max_allow_cidrs) return error.BadManifest;
    if (network.allow_hosts.len > spore_net_policy.max_allow_hosts) return error.BadManifest;
    if (network.allow_host_ports.len > spore_net_policy.max_exact_rules) return error.BadManifest;
    if (network.bound_services.len > spore_net_policy.max_bound_services) return error.BadManifest;
    for (network.allow_cidrs) |cidr| {
        _ = spore_net_policy.parseCidr(cidr) catch return error.BadManifest;
    }
    for (network.allow_hosts) |host| {
        spore_net_policy.validateHost(host) catch return error.BadManifest;
    }
    for (network.allow_host_ports) |rule| {
        spore_net_policy.validateHost(rule.host) catch return error.BadManifest;
        if (rule.ports.len == 0 or rule.ports.len > spore_net_policy.max_rule_ports) return error.BadManifest;
        for (rule.ports) |port| {
            if (port == 0) return error.BadManifest;
        }
    }
    for (network.bound_services) |service| {
        spore_net_policy.validateHost(service.guest_host) catch return error.BadManifest;
        spore_net_policy.validateServiceName(service.name) catch return error.BadManifest;
        if (service.guest_port == 0) return error.BadManifest;
    }
    const facts = spore_net_policy.capabilities();
    if (network.requirements.tcp_ipv4 and !facts.tcp_ipv4) return error.BadManifest;
    if (network.requirements.exact_host_port and !facts.exact_host_port) return error.BadManifest;
    if (network.requirements.bound_services and !facts.bound_services) return error.BadManifest;
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
    errdefer if (backing_tmp_path) |tmp_path| {
        _ = std.c.unlink(tmp_path.ptr);
    };
    if (with_backing) {
        const tmp_path = try pathZ(allocator, "{s}/{s}.tmp", .{ dir, ram_backing_path });
        backing_tmp_path = tmp_path;
        backing_fd = try createNewFile(tmp_path, 0o644);
        if (std.c.ftruncate(backing_fd, @intCast(ram.len)) != 0) return error.IoFailed;
    }
    defer {
        if (backing_fd >= 0) _ = std.c.close(backing_fd);
    }

    const count = (ram.len + chunk_size - 1) / chunk_size;
    var chunks = std.array_list.Managed(MemoryChunk).init(allocator);
    errdefer chunks.deinit();
    var zero_chunks = std.array_list.Managed(u64).init(allocator);
    errdefer zero_chunks.deinit();

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const start = i * chunk_size;
        const end = @min(start + chunk_size, ram.len);
        const data = ram[start..end];
        if (std.mem.allEqual(u8, data, 0)) {
            zero_chunks.append(@intCast(i)) catch return error.OutOfMemory;
            continue;
        }
        const id = chunklib.ChunkId.fromContents(data);
        const hex = id.toHex();
        const digest = try memoryDigestFromHex(allocator, hex[0..]);
        chunks.append(.{ .logical_chunk = @intCast(i), .digest = digest }) catch return error.OutOfMemory;
        const chunk_path = try pathZ(allocator, "{s}/chunks/{s}", .{ dir, hex[0..] });
        try writeFileAllIfMissing(chunk_path, data);
        if (backing_fd >= 0) {
            try pwriteFileAll(backing_fd, start, data);
        }
    }

    const backing = if (with_backing) blk: {
        if (std.c.fchmod(backing_fd, 0o444) != 0) return error.IoFailed;
        _ = std.c.close(backing_fd);
        backing_fd = -1;
        const final_path = try pathZ(allocator, "{s}/{s}", .{ dir, ram_backing_path });
        try publishFileNoOverwrite(backing_tmp_path.?, final_path);
        backing_tmp_path = null;
        break :blk MemoryBacking{ .path = ram_backing_path, .size = ram.len };
    } else null;

    const chunk_slice = chunks.toOwnedSlice() catch return error.OutOfMemory;
    errdefer allocator.free(chunk_slice);
    const zero_slice = zero_chunks.toOwnedSlice() catch return error.OutOfMemory;
    errdefer allocator.free(zero_slice);
    return .{
        .logical_size = @intCast(ram.len),
        .chunk_size = chunk_size,
        .chunks = chunk_slice,
        .zero_chunks = zero_slice,
        .backing = backing,
    };
}

/// Materialize guest memory from the chunk store. Verifies every chunk
/// against its id; fails closed on mismatch.
pub fn loadMemory(allocator: std.mem.Allocator, dir: []const u8, manifest: MemoryManifest, ram: []u8) Error!void {
    const plan = try validateMemoryForRam(manifest, ram.len);

    var nonzero_index: usize = 0;
    var i: usize = 0;
    while (i < plan.chunk_count) : (i += 1) {
        const range = memoryChunkRangeFromPlan(plan, ram.len, i) catch return error.BadManifest;
        const digest: ?[]const u8 = if (nonzero_index < manifest.chunks.len and manifest.chunks[nonzero_index].logical_chunk == i) blk: {
            const value = manifest.chunks[nonzero_index].digest;
            nonzero_index += 1;
            break :blk value;
        } else null;
        try loadMemoryChunkDigest(allocator, dir, digest, ram[range.start..range.end]);
    }
}

pub fn validateMemoryForRam(manifest: MemoryManifest, ram_len: usize) Error!MemoryPlan {
    const expected_size: u64 = @intCast(ram_len);
    disk_index.validateDiskIndex(memoryIndex(manifest), memoryIndexDescriptor(manifest, expected_size)) catch |err| switch (err) {
        error.BadManifest => return error.BadManifest,
        error.FormatTooOld => return error.FormatTooOld,
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (manifest.chunk_size != chunk_size) return error.BadManifest;
    const chunk_count = try diskClusterCount(expected_size, manifest.chunk_size);
    if (chunk_count > std.math.maxInt(usize)) return error.BadManifest;
    return .{
        .chunk_size = chunk_size,
        .chunk_count = @intCast(chunk_count),
        .nonzero_chunk_count = manifest.chunks.len,
    };
}

pub fn memoryChunkRange(manifest: MemoryManifest, ram_len: usize, index: usize) Error!MemoryChunkRange {
    const plan = try validateMemoryForRam(manifest, ram_len);
    return memoryChunkRangeFromPlan(plan, ram_len, index) catch return error.BadManifest;
}

pub fn loadMemoryChunk(allocator: std.mem.Allocator, dir: []const u8, manifest: MemoryManifest, ram_len: usize, index: usize, target: []u8) Error!void {
    const range = try memoryChunkRange(manifest, ram_len, index);
    if (target.len != range.end - range.start) return error.BadManifest;
    try loadMemoryChunkDigest(allocator, dir, memoryChunkDigestForIndex(manifest, index), target);
}

fn memoryChunkRangeFromPlan(plan: MemoryPlan, ram_len: usize, index: usize) !MemoryChunkRange {
    if (index >= plan.chunk_count) return error.BadManifest;
    const start = index * plan.chunk_size;
    const end = @min(start + plan.chunk_size, ram_len);
    return .{ .start = start, .end = end };
}

fn loadMemoryChunkDigest(allocator: std.mem.Allocator, dir: []const u8, maybe_digest: ?[]const u8, target: []u8) Error!void {
    if (maybe_digest) |digest| {
        const hex = try memoryChunkDigestHex(digest);
        const id = chunklib.ChunkId.fromHex(hex) catch return error.BadManifest;
        const chunk_path = try pathZ(allocator, "{s}/chunks/{s}", .{ dir, hex });
        const data = try readFileAll(allocator, chunk_path, target.len);
        defer allocator.free(data);
        if (data.len != target.len) return error.BadChunk;
        if (!id.matches(data)) return error.BadChunk;
        @memcpy(target, data);
    } else {
        @memset(target, 0);
    }
}

pub fn memoryChunkDigestForIndex(manifest: MemoryManifest, index: usize) ?[]const u8 {
    const target: u64 = @intCast(index);
    var lo: usize = 0;
    var hi: usize = manifest.chunks.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const logical_chunk = manifest.chunks[mid].logical_chunk;
        if (logical_chunk == target) return manifest.chunks[mid].digest;
        if (logical_chunk < target) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return null;
}

pub fn memoryChunkDigestHex(digest: []const u8) Error![]const u8 {
    return diskDigestHex(digest);
}

pub fn memoryDigestFromHex(allocator: std.mem.Allocator, hex: []const u8) Error![]const u8 {
    _ = chunklib.ChunkId.fromHex(hex) catch return error.BadManifest;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ disk_index.digest_prefix, hex }) catch return error.OutOfMemory;
}

pub fn saveManifest(allocator: std.mem.Allocator, dir: []const u8, manifest: Manifest) Error!void {
    const path = try pathZ(allocator, "{s}/manifest.json", .{dir});
    defer allocator.free(path);
    try saveManifestPath(allocator, path, manifest);
}

pub fn saveManifestPath(allocator: std.mem.Allocator, path: []const u8, manifest: Manifest) Error!void {
    try validateAnnotations(manifest.annotations);
    try validateSessions(manifest.sessions);
    if (manifest.exec_defaults) |defaults| try validateExecDefaults(defaults);
    const json = std.json.Stringify.valueAlloc(allocator, manifest, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
    defer allocator.free(json);
    const path_z = try pathZ(allocator, "{s}", .{path});
    defer allocator.free(path_z);
    try writeFileAll(path_z, json);
}

pub fn saveManifestV1(allocator: std.mem.Allocator, dir: []const u8, manifest: ManifestV1) Error!void {
    const path = try pathZ(allocator, "{s}/manifest.json", .{dir});
    defer allocator.free(path);
    try saveManifestV1Path(allocator, path, manifest);
}

pub fn saveManifestV1Path(allocator: std.mem.Allocator, path: []const u8, manifest: ManifestV1) Error!void {
    try validateManifestV1(manifest);
    const json = std.json.Stringify.valueAlloc(allocator, manifest, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
    defer allocator.free(json);
    const path_z = try pathZ(allocator, "{s}", .{path});
    defer allocator.free(path_z);
    try writeFileAll(path_z, json);
}

pub fn loadManifest(allocator: std.mem.Allocator, dir: []const u8) Error!std.json.Parsed(Manifest) {
    const path = try pathZ(allocator, "{s}/manifest.json", .{dir});
    defer allocator.free(path);
    return loadManifestPath(allocator, path);
}

pub fn loadManifestPath(allocator: std.mem.Allocator, path: []const u8) Error!std.json.Parsed(Manifest) {
    const path_z = try pathZ(allocator, "{s}", .{path});
    defer allocator.free(path_z);
    const bytes = try readFileAll(allocator, path_z, max_manifest_bytes);
    defer allocator.free(bytes);
    const parsed = std.json.parseFromSlice(Manifest, allocator, bytes, .{
        // The byte buffer is freed before the parse result is used.
        .allocate = .alloc_always,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadManifest,
    };
    errdefer parsed.deinit();
    validateManifest(parsed.value) catch |err| return switch (err) {
        error.FormatTooOld => error.FormatTooOld,
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadManifest,
    };
    return parsed;
}

pub fn loadManifestV1(allocator: std.mem.Allocator, dir: []const u8) Error!std.json.Parsed(ManifestV1) {
    const path = try pathZ(allocator, "{s}/manifest.json", .{dir});
    defer allocator.free(path);
    return loadManifestV1Path(allocator, path);
}

pub fn loadManifestV1Path(allocator: std.mem.Allocator, path: []const u8) Error!std.json.Parsed(ManifestV1) {
    const path_z = try pathZ(allocator, "{s}", .{path});
    defer allocator.free(path_z);
    const bytes = try readFileAll(allocator, path_z, max_manifest_bytes);
    defer allocator.free(bytes);
    const parsed = std.json.parseFromSlice(ManifestV1, allocator, bytes, .{
        // The byte buffer is freed before the parse result is used.
        .allocate = .alloc_always,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadManifest,
    };
    errdefer parsed.deinit();
    validateManifestV1(parsed.value) catch |err| return switch (err) {
        error.FormatTooOld => error.FormatTooOld,
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadManifest,
    };
    return parsed;
}

pub const ForkOptions = struct {
    parent_dir: []const u8,
    out_dir: []const u8,
    count: usize,
    environ_map: ?*const std.process.Environ.Map = null,
    disk_root: ?[]const u8 = null,
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

    const parsed = loadManifest(allocator, options.parent_dir) catch |err| switch (err) {
        error.BadManifest => {
            const parsed_v1 = loadManifestV1(allocator, options.parent_dir) catch return error.BadManifest;
            defer parsed_v1.deinit();
            return forkV1(allocator, options, parsed_v1.value);
        },
        else => |e| return e,
    };
    defer parsed.deinit();
    return forkV0(allocator, options, parsed.value);
}

fn forkV0(allocator: std.mem.Allocator, options: ForkOptions, parent: Manifest) Error!ForkResult {
    if (parent.generation.generation > std.math.maxInt(u64) - options.count) return error.BadForkCount;

    const shared = try prepareForkSharedStores(allocator, options.parent_dir, options.out_dir, parent.memory, parent.disk, options.disk_root);
    const shared_backing = try provenForkBacking(allocator, options.environ_map, options.parent_dir, parent.memory, parent.platform.ram_size, 1);
    defer if (shared_backing) |backing| backing.deinit();

    const fork_batch_id = try randomHex(allocator, 16);

    var i: usize = 0;
    while (i < options.count) : (i += 1) {
        const child_dir = try pathZ(allocator, "{s}/{d:0>6}", .{ options.out_dir, i });
        try ensureNewDir(child_dir);
        try linkForkSharedStores(allocator, child_dir, shared);
        var child = parent;
        try prepareForkChildBacking(allocator, child_dir, &child.memory, child.platform.ram_size, shared_backing, options.environ_map);

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

    return forkResult(allocator, options, parent.generation.generation);
}

fn forkV1(allocator: std.mem.Allocator, options: ForkOptions, parent: ManifestV1) Error!ForkResult {
    if (parent.generation.generation > std.math.maxInt(u64) - options.count) return error.BadForkCount;

    const child_gic = try forkGicStateV1(allocator, parent.machine.gic);
    const shared = try prepareForkSharedStores(allocator, options.parent_dir, options.out_dir, parent.memory, parent.disk, options.disk_root);
    const shared_backing = try provenForkBacking(allocator, options.environ_map, options.parent_dir, parent.memory, parent.platform.ram_size, parent.platform.vcpu_count);
    defer if (shared_backing) |backing| backing.deinit();
    const fork_batch_id = try randomHex(allocator, 16);

    var i: usize = 0;
    while (i < options.count) : (i += 1) {
        const child_dir = try pathZ(allocator, "{s}/{d:0>6}", .{ options.out_dir, i });
        try ensureNewDir(child_dir);
        try linkForkSharedStores(allocator, child_dir, shared);
        var child = parent;
        try prepareForkChildBacking(allocator, child_dir, &child.memory, child.platform.ram_size, shared_backing, options.environ_map);

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
        child.machine.gic = child_gic;
        try saveManifestV1(allocator, child_dir, child);
    }

    return forkResult(allocator, options, parent.generation.generation);
}

const ForkSharedStores = struct {
    chunks: []const u8,
    disk_cas: ?[]const u8 = null,
};

fn prepareForkSharedStores(allocator: std.mem.Allocator, parent_dir: []const u8, out_dir: []const u8, memory: MemoryManifest, disk: ?Disk, disk_root: ?[]const u8) Error!ForkSharedStores {
    const parent_chunks = try pathZ(allocator, "{s}/chunks", .{parent_dir});
    try ensureDir(try pathZ(allocator, "{s}", .{out_dir}));
    const shared_chunks_path = try pathZ(allocator, "{s}/shared-chunks", .{out_dir});
    try ensureNewDir(shared_chunks_path);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    for (memory.chunks) |entry| {
        const hex = try memoryChunkDigestHex(entry.digest);
        if (seen.contains(hex)) continue;
        try seen.put(hex, {});
        const source = try pathZ(allocator, "{s}/{s}", .{ parent_chunks, hex });
        const dest = try pathZ(allocator, "{s}/{s}", .{ shared_chunks_path, hex });
        try hardlinkOrCopyPath(source, dest);
    }
    try fsyncDirPath(shared_chunks_path);
    // Child links must survive the API's atomic rename of the hidden batch.
    var stores = ForkSharedStores{ .chunks = "../shared-chunks" };
    if (disk) |parent_disk| {
        if (std.mem.eql(u8, parent_disk.kind, disk_kind_chunk_index)) {
            // Pinned parents deliberately leave children without a local CAS
            // symlink. The product API publishes an independent child pin
            // bound to each rewritten child manifest before returning.
            if (disk_root == null) stores.disk_cas = try realpathAlloc(allocator, try pathZ(allocator, "{s}/cas", .{parent_dir}));
        }
    }
    return stores;
}

fn fsyncDirPath(path: [:0]const u8) Error!void {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true }, @as(c_uint, 0));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);
    if (std.c.fsync(fd) != 0) return error.IoFailed;
}

fn hardlinkOrCopyPath(source: [:0]const u8, dest: [:0]const u8) Error!void {
    if (std.c.link(source, dest) == 0) return;
    const in_fd = std.c.open(source, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (in_fd < 0) return error.IoFailed;
    defer _ = std.c.close(in_fd);
    const out_fd = std.c.open(dest, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0o444));
    if (out_fd < 0) return error.IoFailed;
    defer _ = std.c.close(out_fd);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(in_fd, &buf, buf.len);
        if (n < 0) return error.IoFailed;
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const wrote = std.c.write(out_fd, buf[off..].ptr, @as(usize, @intCast(n)) - off);
            if (wrote <= 0) return error.IoFailed;
            off += @intCast(wrote);
        }
    }
    if (std.c.fsync(out_fd) != 0) return error.IoFailed;
}

fn linkForkSharedStores(allocator: std.mem.Allocator, child_dir: []const u8, stores: ForkSharedStores) Error!void {
    try symlinkPath(stores.chunks, try pathZ(allocator, "{s}/chunks", .{child_dir}));
    if (stores.disk_cas) |cas| {
        try symlinkPath(cas, try pathZ(allocator, "{s}/cas", .{child_dir}));
    }
}

fn forkResult(allocator: std.mem.Allocator, options: ForkOptions, parent_generation: u64) Error!ForkResult {
    const first_child = try std.fmt.allocPrint(allocator, "{s}/{d:0>6}", .{ options.out_dir, 0 });
    const last_child = try std.fmt.allocPrint(allocator, "{s}/{d:0>6}", .{ options.out_dir, options.count - 1 });
    return .{
        .parent = options.parent_dir,
        .out_dir = options.out_dir,
        .count = options.count,
        .parent_generation = parent_generation,
        .first_generation = parent_generation + 1,
        .last_generation = parent_generation + options.count,
        .first_child = first_child,
        .last_child = last_child,
    };
}

const ProvenForkBacking = struct {
    source_path: [:0]const u8,
    fd: std.c.fd_t,
    file: LocalBackingFileIdentity,

    fn deinit(self: ProvenForkBacking) void {
        _ = std.c.close(self.fd);
    }
};

fn linkAndVerifyForkBacking(source: ProvenForkBacking, backing_link: [:0]const u8) Error!?std.c.fd_t {
    const source_before = (try fstatLocalFile(source.fd)).identity();
    if (!localBackingFileIdentityEqual(source.file, source_before)) return error.IoFailed;

    hardlinkOptionalPath(source.source_path, backing_link) catch |err| return switch (err) {
        error.Unavailable => null,
        error.IoFailed => error.IoFailed,
        error.OutOfMemory => error.OutOfMemory,
    };
    errdefer _ = std.c.unlink(backing_link.ptr);

    const child_fd = openOptionalReadOnlyNoFollow(backing_link) catch |err| return switch (err) {
        error.Unavailable, error.IoFailed => error.IoFailed,
        error.OutOfMemory => error.OutOfMemory,
    };
    errdefer _ = std.c.close(child_fd);

    const source_after = (try fstatLocalFile(source.fd)).identity();
    const child = (try fstatLocalFile(child_fd)).identity();
    if (!localBackingFileIdentityEqual(source.file, source_after) or
        !localBackingFileIdentityEqual(source.file, child))
    {
        return error.IoFailed;
    }
    return child_fd;
}

fn prepareForkChildBacking(
    allocator: std.mem.Allocator,
    child_dir: []const u8,
    memory: *MemoryManifest,
    ram_size: u64,
    shared_backing: ?ProvenForkBacking,
    maybe_environ: ?*const std.process.Environ.Map,
) Error!void {
    const backing = memory.backing orelse return;
    const source = shared_backing orelse {
        memory.backing = null;
        return;
    };
    const backing_link = try pathZ(allocator, "{s}/{s}", .{ child_dir, backing.path });
    const child_fd = (try linkAndVerifyForkBacking(source, backing_link)) orelse {
        memory.backing = null;
        return;
    };
    defer _ = std.c.close(child_fd);
    errdefer _ = std.c.unlink(backing_link.ptr);
    const environ = maybe_environ orelse {
        _ = std.c.unlink(backing_link.ptr);
        memory.backing = null;
        return;
    };
    writeLocalMemoryBackingProofForFd(allocator, environ, child_dir, memory.*, ram_size, child_fd, source.file) catch |err| switch (err) {
        error.AlreadyExists => {
            _ = std.c.unlink(backing_link.ptr);
            memory.backing = null;
            return;
        },
        else => |e| return e,
    };
}

fn provenForkBacking(
    allocator: std.mem.Allocator,
    maybe_environ: ?*const std.process.Environ.Map,
    parent_dir: []const u8,
    memory: MemoryManifest,
    ram_size: u64,
    vcpu_count: topology.VcpuCount,
) Error!?ProvenForkBacking {
    const backing = memory.backing orelse return null;
    const environ = maybe_environ orelse return null;
    try topology.validateVcpuCount(vcpu_count);
    const opened = try openProvenLocalMemoryBackingDetailed(allocator, environ, parent_dir, memory, ram_size);
    if (opened.plan.source != .local_backing) return null;
    const fd = opened.plan.fd orelse return error.IoFailed;
    errdefer _ = std.c.close(fd);
    return .{
        .source_path = try memoryBackingPath(allocator, parent_dir, backing),
        .fd = fd,
        .file = opened.file orelse return error.IoFailed,
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

fn forkGicStateV1(allocator: std.mem.Allocator, state: gicv3.State) Error!gicv3.State {
    if (state.kind == .backend_private) return state;
    if (state.kind != .gicv3_multi) return error.UnsupportedVcpuCount;

    const gic = state.gicv3_multi orelse return error.BadManifest;
    var has_generation_line = false;
    for (gic.line_levels) |line| {
        if (line.intid == board.generationIntid()) {
            has_generation_line = true;
            break;
        }
    }

    const next_len = gic.line_levels.len + @intFromBool(!has_generation_line);
    const line_levels = allocator.alloc(gicv3.MultiLineLevel, next_len) catch return error.OutOfMemory;
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
        .kind = .gicv3_multi,
        .gicv3_multi = .{
            .schema_version = gic.schema_version,
            .dist_regs = gic.dist_regs,
            .redistributors = gic.redistributors,
            .line_levels = line_levels,
        },
    };
}

pub fn validateManifest(manifest: Manifest) Error!void {
    try validateManifestVersion(manifest.version, format_version);
    try validateManifestCommon(
        manifest.annotations,
        manifest.platform.cpu_profile,
        manifest.platform.counter_frequency_hz,
        manifest.platform.ram_size,
        manifest.devices,
        manifest.rootfs,
        manifest.disk,
        manifest.network,
        manifest.sessions,
        manifest.exec_defaults,
        manifest.memory,
    );
    gicv3.validate(manifest.machine.gic) catch return error.BadManifest;
}

pub fn validateManifestV1(manifest: ManifestV1) Error!void {
    try validateManifestVersion(manifest.version, format_version_v1);
    try validateManifestCommon(
        manifest.annotations,
        manifest.platform.cpu_profile,
        manifest.platform.counter_frequency_hz,
        manifest.platform.ram_size,
        manifest.devices,
        manifest.rootfs,
        manifest.disk,
        manifest.network,
        manifest.sessions,
        manifest.exec_defaults,
        manifest.memory,
    );
    try validateMachineV1(manifest.platform, manifest.machine);
}

fn validateManifestVersion(actual: u32, expected: u32) Error!void {
    if (actual == expected) return;
    if (actual < expected) return error.FormatTooOld;
    return error.BadManifest;
}

fn validateManifestCommon(
    annotations: Annotations,
    cpu_profile: []const u8,
    counter_frequency_hz: u64,
    ram_size: u64,
    devices: []const TransportState,
    rootfs: ?Rootfs,
    disk: ?Disk,
    network: ?Network,
    sessions: []const Session,
    exec_defaults: ?ExecDefaults,
    memory: MemoryManifest,
) Error!void {
    try validateAnnotations(annotations);
    try validateSessions(sessions);
    if (exec_defaults) |defaults| try validateExecDefaults(defaults);
    if (cpu_profile.len == 0) return error.BadManifest;
    if (counter_frequency_hz == 0 or
        counter_frequency_hz > std.math.maxInt(u32))
    {
        return error.BadManifest;
    }
    if (ram_size > std.math.maxInt(usize)) return error.BadManifest;
    _ = try validateMemoryForRam(memory, @intCast(ram_size));
    if (memory.backing) |backing| {
        try validateMemoryBacking(backing, ram_size);
    }
    try validateTransportQueues(devices);
    if (rootfs) |r| {
        try validateRootfs(r, devices);
    }
    if (disk) |d| {
        try validateDisk(d, rootfs, devices);
    }
    if (network) |n| {
        try validateNetwork(n);
    }
}

pub fn validateExecDefaults(defaults: ExecDefaults) Error!void {
    if (defaults.env.len > max_exec_default_env) return error.BadManifest;
    for (defaults.env) |entry| {
        if (entry.len > max_exec_default_env_entry_len) return error.BadManifest;
    }
    if (defaults.working_dir) |working_dir| {
        if (working_dir.len == 0 or working_dir.len > max_exec_default_working_dir_len or !std.fs.path.isAbsolute(working_dir)) return error.BadManifest;
    }
}

pub fn processSession(id: []const u8, interactive: bool, tty: bool) Session {
    return .{
        .id = id,
        .streams = .{
            .stdin = interactive and !tty,
            .stdout = !tty,
            .stderr = !tty,
            .terminal = tty,
        },
    };
}

pub fn defaultAttachSessionId(sessions: []const Session) []const u8 {
    for (sessions) |session| {
        if (std.mem.eql(u8, session.id, default_session_id)) return default_session_id;
    }
    return if (sessions.len == 1) sessions[0].id else default_session_id;
}

pub fn validateSessionAttach(sessions: []const Session, request: SessionAttachRequest) !void {
    if (sessions.len == 0) return error.NoSavedSession;
    const session = findSession(sessions, request.id) orelse return error.SavedSessionUnavailable;
    if (request.stdin and !session.streams.stdin) return error.SavedSessionHasNoInteractiveStdin;
    if (request.terminal and !session.streams.terminal) return error.SavedSessionHasNoTerminal;
}

fn findSession(sessions: []const Session, id: []const u8) ?Session {
    for (sessions) |session| {
        if (std.mem.eql(u8, session.id, id)) return session;
    }
    return null;
}

fn validateSessions(sessions: []const Session) Error!void {
    if (sessions.len > max_sessions) return error.BadManifest;
    for (sessions, 0..) |session, i| {
        try validateSessionId(session.id);
        if (!std.mem.eql(u8, session.kind, session_kind_process)) return error.BadManifest;
        for (sessions[0..i]) |previous| {
            if (std.mem.eql(u8, previous.id, session.id)) return error.BadManifest;
        }
    }
}

fn validateTransportQueues(devices: []const TransportState) Error!void {
    for (devices) |device| {
        for (device.queues) |qs| {
            const q = virtqueue.VirtQueue{
                .size = qs.size,
                .ready = qs.ready,
                .desc_addr = qs.desc_addr,
                .avail_addr = qs.avail_addr,
                .used_addr = qs.used_addr,
                .last_avail = qs.last_avail,
                .used_idx = qs.used_idx,
            };
            q.validateLayout() catch return error.BadManifest;
        }
    }
}

fn validateSessionId(id: []const u8) Error!void {
    if (id.len == 0 or id.len > max_session_id_len) return error.BadManifest;
    for (id) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.';
        if (!ok) return error.BadManifest;
    }
}

fn validateMachineV1(platform: PlatformV1, machine: MachineStateV1) Error!void {
    if (machine.schema_version != machine_schema_version_v1) return error.BadManifest;
    topology.validateVcpuCount(platform.vcpu_count) catch return error.BadManifest;
    if (platform.gic_redist_stride == 0) return error.BadManifest;
    _ = board.redistributorRegionSize(platform.gic_redist_stride, platform.vcpu_count) catch return error.BadManifest;
    if (machine.vcpus.len != platform.vcpu_count) return error.BadManifest;
    gicv3.validate(machine.gic) catch return error.BadManifest;
    const gic = switch (machine.gic.kind) {
        .gicv3_multi => machine.gic.gicv3_multi orelse return error.BadManifest,
        .backend_private => null,
        .gicv3 => return error.BadManifest,
    };
    if (gic) |multi| {
        if (multi.redistributors.len != machine.vcpus.len) return error.BadManifest;
    }

    for (machine.vcpus, 0..) |vcpu, i| {
        if (vcpu.index != i) return error.BadManifest;
        if (vcpu.index >= platform.vcpu_count) return error.BadManifest;
        if (vcpu.mpidr != aarch64_topology.mpidrForIndex(vcpu.index)) return error.BadManifest;
        for (machine.vcpus[0..i]) |prev| {
            if (prev.index == vcpu.index or prev.mpidr == vcpu.mpidr) return error.BadManifest;
        }
        if (gic) |multi| {
            if (!gicHasRedistributor(multi, vcpu.mpidr)) return error.BadManifest;
        }
    }
}

fn gicHasRedistributor(gic: gicv3.GicV3MultiState, mpidr: aarch64_topology.Mpidr) bool {
    for (gic.redistributors) |redist| {
        if (redist.mpidr == mpidr) return true;
    }
    return false;
}

pub fn annotationsEmpty(annotations: Annotations) bool {
    return annotations.map.count() == 0;
}

pub fn mergeAnnotations(allocator: std.mem.Allocator, base: Annotations, overlay: Annotations) Error!Annotations {
    var out = Annotations{};
    errdefer out.deinit(allocator);

    var base_it = base.map.iterator();
    while (base_it.next()) |entry| {
        out.map.put(allocator, entry.key_ptr.*, entry.value_ptr.*) catch return error.OutOfMemory;
    }
    var overlay_it = overlay.map.iterator();
    while (overlay_it.next()) |entry| {
        out.map.put(allocator, entry.key_ptr.*, entry.value_ptr.*) catch return error.OutOfMemory;
    }
    try validateAnnotations(out);
    return out;
}

pub fn validateAnnotations(annotations: Annotations) Error!void {
    var serialized_len: usize = 2;
    var first = true;
    var it = annotations.map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (key.len == 0) return error.BadManifest;
        if (!std.unicode.utf8ValidateSlice(key)) return error.BadManifest;
        if (!std.unicode.utf8ValidateSlice(value)) return error.BadManifest;
        if (first) {
            first = false;
        } else {
            serialized_len = std.math.add(usize, serialized_len, 1) catch return error.BadManifest;
        }
        const key_size = try jsonStringLiteralSize(key);
        const value_size = try jsonStringLiteralSize(value);
        serialized_len = std.math.add(usize, serialized_len, key_size) catch return error.BadManifest;
        serialized_len = std.math.add(usize, serialized_len, 1) catch return error.BadManifest;
        serialized_len = std.math.add(usize, serialized_len, value_size) catch return error.BadManifest;
        if (serialized_len > max_annotations_json_bytes) return error.BadManifest;
    }
}

fn jsonStringLiteralSize(value: []const u8) Error!usize {
    var size: usize = 2;
    for (value) |byte| {
        const extra: usize = if (byte == '"' or byte == '\\' or byte == '\n' or byte == '\r' or byte == '\t' or byte == 0x08 or byte == 0x0c)
            2
        else if (byte < 0x20)
            6
        else
            1;
        size = std.math.add(usize, size, extra) catch return error.BadManifest;
    }
    return size;
}

// --- tests ------------------------------------------------------------------

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

fn testDirFromTemplate(allocator: std.mem.Allocator, template: []const u8) ![:0]const u8 {
    const buf = try allocator.dupeZ(u8, template);
    if (mkdtemp(buf) == null) return error.IoFailed;
    return buf;
}

fn testDir(allocator: std.mem.Allocator) ![:0]const u8 {
    return testDirFromTemplate(allocator, "/tmp/sporevm-test-XXXXXX");
}

fn testLinuxPathDevice(path: [:0]const u8) !u64 {
    const linux = std.os.linux;
    var st: linux.Statx = undefined;
    const rc = linux.statx(std.c.AT.FDCWD, path, std.c.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st);
    if (linux.errno(rc) != .SUCCESS) return error.IoFailed;
    return (@as(u64, st.dev_major) << 32) | st.dev_minor;
}

const OptionalNodeKind = enum { directory, fifo, socket, symlink };

fn createOptionalNode(path: [:0]const u8, kind: OptionalNodeKind) !void {
    switch (kind) {
        .directory => if (std.c.mkdir(path, 0o700) != 0) return error.IoFailed,
        .fifo => if (mkfifo(path, 0o600) != 0) return error.IoFailed,
        .socket => {
            const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
            if (fd < 0) return error.IoFailed;
            defer _ = std.c.close(fd);
            var address = std.mem.zeroInit(std.c.sockaddr.un, .{});
            address.family = std.c.AF.UNIX;
            if (path.len >= address.path.len) return error.NameTooLong;
            @memcpy(address.path[0..path.len], path);
            const address_len: std.c.socklen_t = @intCast(@offsetOf(std.c.sockaddr.un, "path") + path.len + 1);
            if (@hasField(std.c.sockaddr.un, "len")) address.len = @intCast(address_len);
            const rc = std.c.bind(fd, @ptrCast(&address), address_len);
            if (rc != 0) return if (std.c.errno(rc) == .PERM) error.SocketCreationDenied else error.IoFailed;
        },
        .symlink => try symlinkPath("missing-target", path),
    }
}

fn removeOptionalNode(path: [:0]const u8, kind: OptionalNodeKind) void {
    _ = if (kind == .directory) std.c.rmdir(path) else std.c.unlink(path);
}

fn expectOptionalNodeFallback(kind: OptionalNodeKind, replace_proof: bool) !void {
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

    const ram = try arena.alloc(u8, chunk_size);
    @memset(ram, 0x5A);
    const memory = try saveMemoryWithBacking(arena, dir, ram);
    try writeLocalMemoryBackingProof(arena, &env, dir, memory, ram.len);
    const path = if (replace_proof)
        try pathZ(arena, "{s}/{s}", .{ dir, ram_backing_proof_path })
    else
        try memoryBackingPath(arena, dir, memory.backing.?);
    if (std.c.unlink(path.ptr) != 0) return error.IoFailed;
    try createOptionalNode(path, kind);
    defer removeOptionalNode(path, kind);

    const plan = try openProvenLocalMemoryBacking(arena, &env, dir, memory, ram.len);
    defer if (plan.fd) |fd| {
        _ = std.c.close(fd);
    };
    try std.testing.expectEqual(LocalBackingRestoreSource.chunks, plan.source);
    try std.testing.expectEqual(
        if (replace_proof) LocalBackingRestoreReason.proof_unavailable else LocalBackingRestoreReason.backing_unavailable,
        plan.reason,
    );
}

test "snapshot root creation rejects existing and symlink paths" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const snapshot_dir = try pathZ(arena, "{s}/base.spore", .{root_dir});
    try createSnapshotRoot(arena, snapshot_dir);
    try std.testing.expectEqual(@as(c_int, 0), std.c.access(snapshot_dir, 0));
    try std.testing.expectError(error.AlreadyExists, createSnapshotRoot(arena, snapshot_dir));

    const target_dir = try pathZ(arena, "{s}/target", .{root_dir});
    try ensureDir(target_dir);
    const link_dir = try pathZ(arena, "{s}/link.spore", .{root_dir});
    try symlinkPath(target_dir, link_dir);
    try std.testing.expectError(error.AlreadyExists, createSnapshotRoot(arena, link_dir));
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
    try std.testing.expectEqualStrings(disk_index.disk_index_kind_v1, mm.kind);
    try std.testing.expectEqual(@as(u64, ram.len), mm.logical_size);
    try std.testing.expectEqual(@as(usize, 3), mm.chunks.len);
    try std.testing.expectEqual(@as(u64, 0), mm.chunks[0].logical_chunk);
    try std.testing.expectEqual(@as(u64, 3), mm.chunks[1].logical_chunk);
    try std.testing.expectEqual(@as(u64, 5), mm.chunks[2].logical_chunk);
    try std.testing.expectEqual(@as(usize, 3), mm.zero_chunks.len);
    try std.testing.expectEqual(@as(u64, 1), mm.zero_chunks[0]);
    try std.testing.expectEqual(@as(u64, 2), mm.zero_chunks[1]);
    try std.testing.expectEqual(@as(u64, 4), mm.zero_chunks[2]);
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

test "memory backing rejects preexisting symlink temp file" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const dir = try pathZ(arena, "{s}/spore", .{root_dir});
    try ensureDir(dir);
    const victim_path = try pathZ(arena, "{s}/victim", .{root_dir});
    try writeFileAll(victim_path, "untouched");
    const tmp_path = try pathZ(arena, "{s}/{s}.tmp", .{ dir, ram_backing_path });
    try symlinkPath(victim_path, tmp_path);

    const ram = try arena.alloc(u8, chunk_size);
    @memset(ram, 0x4A);
    if (saveMemoryWithBacking(arena, dir, ram)) |manifest| {
        _ = manifest;
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.AlreadyExists, error.IoFailed => {},
        else => return err,
    }

    const victim = try readFileAll(arena, victim_path, 1024);
    try std.testing.expectEqualStrings("untouched", victim);
}

test "manifest save rejects symlink target" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    const victim_path = try pathZ(arena, "{s}/victim", .{dir});
    try writeFileAll(victim_path, "untouched");
    const manifest_path = try pathZ(arena, "{s}/manifest.json", .{dir});
    try symlinkPath(victim_path, manifest_path);

    const manifest = testForkManifest(testZeroMemoryManifest(chunk_size), chunk_size, 1);
    if (saveManifest(arena, dir, manifest)) |_| {
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.IoFailed => {},
        else => return err,
    }

    const victim = try readFileAll(arena, victim_path, 1024);
    try std.testing.expectEqualStrings("untouched", victim);
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
    try std.testing.expectEqual(LocalBackingRestoreReason.proof_valid, plan.reason);

    const proof_path = try pathZ(arena, "{s}/{s}", .{ dir, ram_backing_proof_path });
    try writeFileAll(proof_path, "{}");
    const corrupt_plan = try openProvenLocalMemoryBacking(arena, &env, dir, mm, ram.len);
    defer if (corrupt_plan.fd) |fd| {
        _ = std.c.close(fd);
    };
    try std.testing.expectEqual(LocalBackingRestoreSource.chunks, corrupt_plan.source);
    try std.testing.expect(corrupt_plan.fd == null);
    try std.testing.expectEqual(LocalBackingRestoreReason.proof_invalid, corrupt_plan.reason);

    if (std.c.unlink(proof_path.ptr) != 0) return error.IoFailed;
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
    try std.testing.expectEqual(LocalBackingRestoreReason.proof_unavailable, symlink_plan.reason);
}

test "optional local RAM backing and proof non-socket nodes fall back to chunks" {
    const kinds = [_]OptionalNodeKind{ .directory, .fifo, .symlink };
    for (kinds) |kind| {
        try expectOptionalNodeFallback(kind, false);
        try expectOptionalNodeFallback(kind, true);
    }
}

test "optional local RAM backing and proof sockets fall back to chunks" {
    for ([_]bool{ false, true }) |replace_proof| {
        expectOptionalNodeFallback(.socket, replace_proof) catch |err| switch (err) {
            error.SocketCreationDenied => return error.SkipZigTest,
            else => return err,
        };
    }
}

test "local memory backing rejects malformed authoritative metadata" {
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

    const ram = try arena.alloc(u8, chunk_size);
    @memset(ram, 0x6D);
    const memory = try saveMemoryWithBacking(arena, dir, ram);

    var bad_backing = memory;
    bad_backing.backing = .{ .kind = "unknown", .path = ram_backing_path, .size = ram.len };
    try std.testing.expectError(error.BadManifest, openProvenLocalMemoryBacking(arena, &env, dir, bad_backing, ram.len));

    var bad_memory = memory;
    bad_memory.logical_size += 1;
    try std.testing.expectError(error.BadManifest, openProvenLocalMemoryBacking(arena, &env, dir, bad_memory, ram.len));
    try std.testing.expectError(error.BadManifest, openProvenLocalMemoryBacking(arena, &env, dir, memory, ram.len + 1));

    const missing_proof = try openProvenLocalMemoryBacking(arena, &env, dir, memory, ram.len);
    try std.testing.expectEqual(LocalBackingRestoreSource.chunks, missing_proof.source);
    try std.testing.expectEqual(LocalBackingRestoreReason.proof_unavailable, missing_proof.reason);

    const backing_path = try memoryBackingPath(arena, dir, memory.backing.?);
    if (std.c.unlink(backing_path.ptr) != 0) return error.IoFailed;
    const missing_backing = try openProvenLocalMemoryBacking(arena, &env, dir, memory, ram.len);
    try std.testing.expectEqual(LocalBackingRestoreSource.chunks, missing_backing.source);
    try std.testing.expectEqual(LocalBackingRestoreReason.backing_unavailable, missing_backing.reason);
}

fn checkProvenBackingAllocations(
    backing_allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    dir: []const u8,
    memory: MemoryManifest,
    ram_size: u64,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena_state.deinit();
    const plan = try openProvenLocalMemoryBacking(arena_state.allocator(), environ, dir, memory, ram_size);
    defer {
        if (plan.fd) |fd| _ = std.c.close(fd);
    }
    try std.testing.expectEqual(LocalBackingRestoreSource.local_backing, plan.source);
}

test "local memory backing proof propagates allocation failure" {
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

    const ram = try arena.alloc(u8, chunk_size);
    @memset(ram, 0x7A);
    const memory = try saveMemoryWithBacking(arena, dir, ram);
    try writeLocalMemoryBackingProof(arena, &env, dir, memory, ram.len);

    try std.testing.checkAllAllocationFailures(allocator, checkProvenBackingAllocations, .{ &env, dir, memory, ram.len });

    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, localBackingRuntimeRoot(failing_allocator.allocator(), &env));
}

test "local backing stat errors remain fatal" {
    try std.testing.expectError(error.IoFailed, fstatLocalFile(-1));
}

test "optional local RAM path and hardlink errno classifiers preserve fatal failures" {
    try std.testing.expect(classifyOptionalPathErrno(.NOENT) == error.Unavailable);
    try std.testing.expect(classifyOptionalPathErrno(.NOTDIR) == error.Unavailable);
    try std.testing.expect(classifyOptionalPathErrno(.LOOP) == error.Unavailable);
    try std.testing.expect(classifyOptionalPathErrno(.NOMEM) == error.OutOfMemory);
    try std.testing.expect(classifyOptionalPathErrno(.IO) == error.IoFailed);
    try std.testing.expect(classifyOptionalPathErrno(.OPNOTSUPP) == error.IoFailed);

    try std.testing.expect(classifyOptionalHardlinkErrno(.XDEV) == error.Unavailable);
    try std.testing.expect(classifyOptionalHardlinkErrno(.OPNOTSUPP) == error.Unavailable);
    try std.testing.expect(classifyOptionalHardlinkErrno(.NOMEM) == error.OutOfMemory);
    try std.testing.expect(classifyOptionalHardlinkErrno(.IO) == error.IoFailed);
}

test "fs-verity result classification preserves unexpected I/O" {
    try fsVerityEnableResult(.SUCCESS);
    try std.testing.expectError(error.Unavailable, fsVerityEnableResult(.ACCES));
    try std.testing.expectError(error.Unavailable, fsVerityEnableResult(.INVAL));
    try std.testing.expectError(error.Unavailable, fsVerityEnableResult(.NOTTY));
    try std.testing.expectError(error.IoFailed, fsVerityEnableResult(.IO));
    try std.testing.expect(try fsVerityMeasureAvailable(.SUCCESS));
    try std.testing.expect(!try fsVerityMeasureAvailable(.NODATA));
    try std.testing.expectError(error.IoFailed, fsVerityMeasureAvailable(.BADF));
}

const TestProofVerityBehavior = enum {
    existing,
    enable,
    unavailable,
    unexpected,
    identity_change,
    ownership_change,
    mtime_transition,
    unavailable_mtime_transition,
    unexpected_mtime_transition,
    restore_failure,
};

const TestProofVerityOps = struct {
    behavior: TestProofVerityBehavior,
    enabled: bool = false,
    enable_count: usize = 0,
    chmod_count: usize = 0,

    fn proofForWrite(self: *@This(), allocator: std.mem.Allocator, fd: std.c.fd_t) Error!ProofVerityWriteResult {
        return proofVerityForWriteWithOps(allocator, fd, self);
    }

    fn measure(self: *@This(), allocator: std.mem.Allocator, _: std.c.fd_t) Error!?LocalBackingVerity {
        if (self.behavior != .existing and !self.enabled) return null;
        return .{
            .algorithm = local_backing_verity_algorithm_sha256,
            .digest = try allocator.dupe(u8, "0000000000000000000000000000000000000000000000000000000000000000"),
        };
    }

    fn enable(self: *@This(), _: std.c.fd_t) FsVerityEnableError!void {
        self.enable_count += 1;
        switch (self.behavior) {
            .existing => return error.IoFailed,
            .enable, .mtime_transition, .restore_failure => self.enabled = true,
            .unavailable => return error.Unavailable,
            .unavailable_mtime_transition => {
                self.enabled = true;
                return error.Unavailable;
            },
            .unexpected, .unexpected_mtime_transition => return error.IoFailed,
            .identity_change, .ownership_change => return error.IoFailed,
        }
    }

    fn chmod(self: *@This(), fd: std.c.fd_t, mode: std.c.mode_t) Error!void {
        self.chmod_count += 1;
        if (self.behavior == .restore_failure and self.chmod_count == 2) return error.IoFailed;
        if (std.c.fchmod(fd, mode) != 0) return error.IoFailed;
    }

    fn stat(self: *@This(), fd: std.c.fd_t) Error!LocalFileStat {
        var file_stat = try fstatLocalFile(fd);
        if (self.chmod_count == 1) switch (self.behavior) {
            .identity_change => file_stat.inode +%= 1,
            .ownership_change => file_stat.owner_uid +%= 1,
            else => {},
        };
        if (self.chmod_count >= 2) switch (self.behavior) {
            .mtime_transition, .unavailable_mtime_transition, .unexpected_mtime_transition => file_stat.mtime_nsec +%= 1,
            else => {},
        };
        return file_stat;
    }
};

fn testProofVerityWriteCase(
    behavior: TestProofVerityBehavior,
    original_mode: std.c.mode_t,
    expected_schema: ?u32,
) !void {
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

    var ram: [4096]u8 = undefined;
    @memset(&ram, 0x5A);
    const memory = try saveMemoryWithBacking(arena, dir, &ram);
    const backing_path = try memoryBackingPath(arena, dir, memory.backing.?);
    const fd = try openReadOnlyNoFollow(backing_path);
    defer _ = std.c.close(fd);
    if (std.c.fchmod(fd, original_mode) != 0) return error.IoFailed;
    const initial_stat = try fstatLocalFile(fd);
    try std.testing.expectEqual(@as(u64, original_mode), initial_stat.mode & 0o7777);

    var ops = TestProofVerityOps{ .behavior = behavior };
    const proof_path = try pathZ(arena, "{s}/{s}", .{ dir, ram_backing_proof_path });
    if (expected_schema) |schema| {
        try writeLocalMemoryBackingProofForFdWithOps(
            arena,
            &env,
            dir,
            memory,
            ram.len,
            fd,
            null,
            &ops,
        );
        const proof_bytes = try readRegularFileAllNoFollow(arena, proof_path, local_backing_proof_max_bytes);
        const parsed = try std.json.parseFromSlice(LocalBackingProof, arena, proof_bytes, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        try std.testing.expectEqual(schema, parsed.value.schema_version);
        if (behavior == .mtime_transition) {
            try std.testing.expectEqual(initial_stat.mtime_nsec +% 1, parsed.value.file.mtime_nsec);
        }
    } else {
        try std.testing.expectError(error.IoFailed, writeLocalMemoryBackingProofForFdWithOps(
            arena,
            &env,
            dir,
            memory,
            ram.len,
            fd,
            null,
            &ops,
        ));
        try std.testing.expect(std.c.access(proof_path, 0) != 0);
    }

    const final_stat = try fstatLocalFile(fd);
    if (behavior == .restore_failure) {
        try std.testing.expect((initial_stat.mode & 0o7777) != (final_stat.mode & 0o7777));
    } else {
        try std.testing.expectEqual(initial_stat.mode & 0o7777, final_stat.mode & 0o7777);
    }
    try std.testing.expect(localBackingFileIdentityEqual(initial_stat.identity(), final_stat.identity()));
    const permission_cycle = original_mode & 0o222 == 0 and behavior != .existing;
    try std.testing.expectEqual(@as(usize, if (permission_cycle) 2 else 0), ops.chmod_count);
    const expected_enable_count: usize = if (!permission_cycle) 0 else switch (behavior) {
        .identity_change, .ownership_change => 0,
        else => 1,
    };
    try std.testing.expectEqual(expected_enable_count, ops.enable_count);
}

test "proof write restores backing mode across fs-verity outcomes" {
    try testProofVerityWriteCase(.existing, 0o444, 2);
    try testProofVerityWriteCase(.enable, 0o444, 2);
    try testProofVerityWriteCase(.enable, 0o440, 2);
    try testProofVerityWriteCase(.enable, 0o644, null);
    try testProofVerityWriteCase(.unavailable, 0o444, 1);
    try testProofVerityWriteCase(.unexpected, 0o444, null);
    try testProofVerityWriteCase(.identity_change, 0o444, null);
    try testProofVerityWriteCase(.ownership_change, 0o444, null);
    try testProofVerityWriteCase(.mtime_transition, 0o444, 2);
    try testProofVerityWriteCase(.unavailable_mtime_transition, 0o444, null);
    try testProofVerityWriteCase(.unexpected_mtime_transition, 0o444, null);
    try testProofVerityWriteCase(.restore_failure, 0o444, null);
}

test "local RAM backing proof metric lines are stable" {
    var buf: [320]u8 = undefined;
    try std.testing.expectEqualStrings(
        "local RAM backing proof metrics: operation=write status=ok reason=verity_enabled schema=2 verity=sha256 elapsed_us=41",
        formatLocalBackingProofWriteOk(&buf, 2, true, 41),
    );
    try std.testing.expectEqualStrings(
        "local RAM backing proof metrics: operation=write status=ok reason=verity_unavailable schema=1 verity=none elapsed_us=42",
        formatLocalBackingProofWriteOk(&buf, 1, false, 42),
    );
    try std.testing.expectEqualStrings(
        "local RAM backing proof metrics: operation=write status=error reason=error schema=0 verity=unknown elapsed_us=43 error=IoFailed",
        formatLocalBackingProofWriteError(&buf, 43, error.IoFailed),
    );

    const valid = LocalBackingOpen{
        .plan = .{ .source = .local_backing, .reason = .proof_valid },
        .proof_schema_version = 2,
        .proof_has_verity = true,
    };
    try std.testing.expectEqualStrings(
        "local RAM backing proof metrics: operation=validate status=ok source=local_backing reason=proof_valid schema=2 verity=sha256 validation_us=44 precharge_us=5",
        formatLocalBackingProofValidationOk(&buf, valid, 44, 5),
    );
    const fallback = LocalBackingOpen{
        .plan = localBackingChunksPlan(.key_unavailable),
    };
    try std.testing.expectEqualStrings(
        "local RAM backing proof metrics: operation=validate status=ok source=chunks reason=key_unavailable schema=0 verity=none validation_us=45 precharge_us=0",
        formatLocalBackingProofValidationOk(&buf, fallback, 45, 0),
    );
    try std.testing.expectEqualStrings(
        "local RAM backing proof metrics: operation=validate status=error source=error reason=error schema=0 verity=unknown validation_us=46 precharge_us=0 error=IoFailed",
        formatLocalBackingProofValidationError(&buf, 46, error.IoFailed),
    );
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
    try std.testing.expectEqual(LocalBackingRestoreReason.key_unavailable, missing_key_plan.reason);

    _ = try localBackingKey(arena, &env_b, true);
    const foreign_key_plan = try openProvenLocalMemoryBacking(arena, &env_b, dir, mm, ram.len);
    defer if (foreign_key_plan.fd) |fd| {
        _ = std.c.close(fd);
    };
    try std.testing.expectEqual(LocalBackingRestoreSource.chunks, foreign_key_plan.source);
    try std.testing.expectEqual(LocalBackingRestoreReason.proof_mac_mismatch, foreign_key_plan.reason);

    var refs = try arena.dupe(MemoryChunk, mm.chunks);
    refs[0].digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    var changed = mm;
    changed.chunks = refs;
    const mismatch_plan = try openProvenLocalMemoryBacking(arena, &env_a, dir, changed, ram.len);
    defer if (mismatch_plan.fd) |fd| {
        _ = std.c.close(fd);
    };
    try std.testing.expectEqual(LocalBackingRestoreSource.chunks, mismatch_plan.source);
    try std.testing.expectEqual(LocalBackingRestoreReason.proof_mismatch, mismatch_plan.reason);
}

test "local memory backing proof MAC covers verity digest" {
    const key = [_]u8{0xA5} ** local_backing_key_len;
    const memory_fingerprint = "memory-fingerprint";
    const backing = LocalBackingProofBacking{
        .kind = ram_backing_kind,
        .path = ram_backing_path,
        .size = 4096,
    };
    const file = LocalBackingFileIdentity{
        .device = 1,
        .inode = 2,
        .owner_uid = 501,
        .size = 4096,
        .mtime_sec = 3,
        .mtime_nsec = 4,
    };
    const verity_a = LocalBackingVerity{
        .algorithm = local_backing_verity_algorithm_sha256,
        .digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
    const verity_b = LocalBackingVerity{
        .algorithm = local_backing_verity_algorithm_sha256,
        .digest = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    };

    const mac_a = try proofMac(&key, memory_fingerprint, local_backing_proof_version_v2, backing, file, local_backing_producer, verity_a);
    const mac_b = try proofMac(&key, memory_fingerprint, local_backing_proof_version_v2, backing, file, local_backing_producer, verity_b);
    try std.testing.expect(!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, mac_a, mac_b));
    try std.testing.expectError(error.BadManifest, proofMac(&key, memory_fingerprint, local_backing_proof_version_v1, backing, file, local_backing_producer, verity_a));
    try std.testing.expectError(error.BadManifest, proofMac(&key, memory_fingerprint, local_backing_proof_version_v2, backing, file, local_backing_producer, null));

    const proof_v1 = LocalBackingProof{
        .schema_version = local_backing_proof_version_v1,
        .memory_fingerprint = memory_fingerprint,
        .backing = backing,
        .file = file,
        .producer = local_backing_producer,
        .mac = "",
    };
    try std.testing.expect(proofFieldsMatch(proof_v1, memory_fingerprint, backing, file));

    const proof_v2 = LocalBackingProof{
        .schema_version = local_backing_proof_version_v2,
        .memory_fingerprint = memory_fingerprint,
        .backing = backing,
        .file = file,
        .producer = local_backing_producer,
        .verity = verity_a,
        .mac = "",
    };
    try std.testing.expect(proofFieldsMatch(proof_v2, memory_fingerprint, backing, file));

    const bad_v2 = LocalBackingProof{
        .schema_version = local_backing_proof_version_v2,
        .memory_fingerprint = memory_fingerprint,
        .backing = backing,
        .file = file,
        .producer = local_backing_producer,
        .mac = "",
    };
    try std.testing.expect(!proofFieldsMatch(bad_v2, memory_fingerprint, backing, file));
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

    var wrong_algorithm = mm;
    wrong_algorithm.hash_algorithm = "sha256";
    try std.testing.expectError(error.BadManifest, validateMemoryForRam(wrong_algorithm, ram.len));

    var wrong_namespace = mm;
    wrong_namespace.object_namespace = rootfs_storage_object_namespace;
    try std.testing.expectError(error.BadManifest, validateMemoryForRam(wrong_namespace, ram.len));

    var malformed_refs = try arena.dupe(MemoryChunk, mm.chunks);
    malformed_refs[0].digest = "not-a-blake3-id";
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
    const chunk_path = try pathZ(arena, "{s}/chunks/{s}", .{ dir, try memoryChunkDigestHex(mm.chunks[0].digest) });
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
    defer parsed.deinit();
    validateManifest(parsed.value) catch return;
}

test "fuzz manifest parsing" {
    try std.testing.fuzz({}, fuzzManifestParse, .{});
}

fn fuzzManifestV1Parse(_: void, s: *std.testing.Smith) !void {
    // The multi-vCPU manifest adds per-vCPU and per-redistributor arrays at the
    // same trust boundary as the single-vCPU manifest; parse plus validation
    // must fail closed.
    var buf: [4096]u8 = undefined;
    const len = s.slice(&buf);
    const parsed = std.json.parseFromSlice(ManifestV1, std.testing.allocator, buf[0..len], .{
        .allocate = .alloc_always,
    }) catch return;
    defer parsed.deinit();
    validateManifestV1(parsed.value) catch return;
}

test "fuzz manifest v1 parsing" {
    try std.testing.fuzz({}, fuzzManifestV1Parse, .{});
}

fn fuzzMemoryManifest(_: void, s: *std.testing.Smith) !void {
    // Hostile memory manifests must fail closed, never read outside the
    // chunk store or write outside the target buffer.
    var ram: [4096]u8 = undefined;
    var ref_buf: [128]u8 = undefined;
    const ref_len = s.slice(&ref_buf);
    var refs = [_]MemoryChunk{.{ .logical_chunk = s.value(u64), .digest = ref_buf[0..ref_len] }};
    var zero_chunks = [_]u64{ 0, 1, 2 };
    const mm = MemoryManifest{
        .logical_size = s.value(u64),
        .chunk_size = s.value(u64),
        .chunks = &refs,
        .zero_chunks = &zero_chunks,
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
    var annotations = Annotations{};
    try annotations.map.put(arena, "dev.buildkite.cleanroom.policy_hash", "sha256:abc123");
    try annotations.map.put(arena, "org.opencontainers.image.ref.name", "worker");
    const manifest = Manifest{
        .annotations = annotations,
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
        .sessions = &.{processSession(default_session_id, true, false)},
        .network = .{
            .allow_cidrs = &.{"93.184.216.34/32"},
            .allow_hosts = &.{"example.com"},
        },
        .exec_defaults = .{
            .env = &.{ "IMAGE_VALUE=default", "CLEAR_ME=inherited" },
            .working_dir = "/workspace",
        },
        .memory = testZeroMemoryManifest(1 << 29),
    };
    try saveManifest(arena, dir, manifest);
    const parsed = try loadManifest(arena, dir);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, format_version), parsed.value.version);
    try std.testing.expectEqualStrings("sporevm-aarch64-v0", parsed.value.platform.cpu_profile);
    try std.testing.expectEqual(@as(u64, 0x8000_0000), parsed.value.platform.ram_base);
    try std.testing.expectEqual(@as(u64, 24_000_000), parsed.value.platform.counter_frequency_hz);
    try std.testing.expectEqual(@as(u64, 123), parsed.value.machine.vtimer.cntvct);
    try std.testing.expectEqualStrings("sctlr_el1", parsed.value.machine.sys_regs[0].name);
    try std.testing.expectEqual(gicv3.StateKind.gicv3, parsed.value.machine.gic.kind);
    try std.testing.expectEqual(@as(u32, gicv3.distRouterOffset(32)), parsed.value.machine.gic.gicv3.?.dist_regs[0].offset);
    try std.testing.expectEqual(@as(u16, 64), parsed.value.devices[0].queues[0].size);
    try std.testing.expectEqual(@as(u64, 7), parsed.value.generation.generation);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.sessions.len);
    try std.testing.expectEqualStrings(default_session_id, parsed.value.sessions[0].id);
    try std.testing.expect(parsed.value.sessions[0].streams.stdin);
    try std.testing.expect(!parsed.value.sessions[0].streams.terminal);
    try std.testing.expect(parsed.value.network != null);
    try std.testing.expectEqualStrings(network_kind_spore, parsed.value.network.?.kind);
    try std.testing.expectEqualStrings("93.184.216.34/32", parsed.value.network.?.allow_cidrs[0]);
    try std.testing.expectEqualStrings("example.com", parsed.value.network.?.allow_hosts[0]);
    try std.testing.expectEqualStrings("IMAGE_VALUE=default", parsed.value.exec_defaults.?.env[0]);
    try std.testing.expectEqualStrings("CLEAR_ME=inherited", parsed.value.exec_defaults.?.env[1]);
    try std.testing.expectEqualStrings("/workspace", parsed.value.exec_defaults.?.working_dir.?);
    try std.testing.expectEqualStrings("sha256:abc123", parsed.value.annotations.map.get("dev.buildkite.cleanroom.policy_hash").?);
    try std.testing.expectEqualStrings("worker", parsed.value.annotations.map.get("org.opencontainers.image.ref.name").?);
}

test "manifest omits absent exec defaults" {
    const allocator = std.testing.allocator;
    const manifest = testForkManifest(testZeroMemoryManifest(1 << 29), 1 << 29, 3);
    const json = try std.json.Stringify.valueAlloc(allocator, manifest, .{});
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"exec_defaults\"") == null);
}

test "manifest loaders preserve format-too-old errors" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const single_dir = try testDir(arena);
    var single = testForkManifest(testZeroMemoryManifest(1 << 29), 1 << 29, 3);
    single.version = format_version_legacy_v0;
    try saveManifest(arena, single_dir, single);
    try std.testing.expectError(error.FormatTooOld, loadManifest(arena, single_dir));

    const multi_dir = try testDir(arena);
    var vcpus = [_]VcpuState{ testVcpuState(0), testVcpuState(1) };
    const redists = [_]gicv3.RedistributorState{
        .{ .mpidr = aarch64_topology.mpidrForIndex(0), .regs = &.{} },
        .{ .mpidr = aarch64_topology.mpidrForIndex(1), .regs = &.{} },
    };
    var multi = testManifestV1(testZeroMemoryManifest(1 << 29), 1 << 29, &vcpus, &redists);
    multi.version = format_version_legacy_v1;
    const multi_json = std.json.Stringify.valueAlloc(arena, multi, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
    try writeFileAll(try pathZ(arena, "{s}/manifest.json", .{multi_dir}), multi_json);
    try std.testing.expectError(error.FormatTooOld, loadManifestV1(arena, multi_dir));
}

test "session attach validation rejects unavailable input streams" {
    const sessions = [_]Session{processSession(default_session_id, false, false)};

    try std.testing.expectError(error.NoSavedSession, validateSessionAttach(&.{}, .{ .id = default_session_id }));
    try validateSessionAttach(&sessions, .{ .id = default_session_id });
    try std.testing.expectError(error.SavedSessionHasNoInteractiveStdin, validateSessionAttach(&sessions, .{
        .id = default_session_id,
        .stdin = true,
    }));
    try std.testing.expectError(error.SavedSessionHasNoTerminal, validateSessionAttach(&sessions, .{
        .id = default_session_id,
        .terminal = true,
    }));
}

test "single non-default session becomes the attach handle" {
    const sessions = [_]Session{processSession("run-1234", true, false)};
    try std.testing.expectEqualStrings("run-1234", defaultAttachSessionId(&sessions));
}

test "manifest v1 validates and round-trips multi-vCPU topology" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    var vcpus = [_]VcpuState{ testVcpuState(0), testVcpuState(1) };
    var redist_regs = [_]gicv3.MmioReg{.{ .offset = 0x10080, .width_bits = 32, .value = 0 }};
    var redists = [_]gicv3.RedistributorState{
        .{ .mpidr = aarch64_topology.mpidrForIndex(0), .regs = &redist_regs },
        .{ .mpidr = aarch64_topology.mpidrForIndex(1), .regs = &redist_regs },
    };
    const manifest = testManifestV1(testZeroMemoryManifest(1 << 29), 1 << 29, &vcpus, &redists);

    try validateManifestV1(manifest);
    try saveManifestV1(arena, dir, manifest);
    try std.testing.expectError(error.BadManifest, loadManifest(arena, dir));
    const parsed = try loadManifestV1(arena, dir);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, format_version_v1), parsed.value.version);
    try std.testing.expectEqual(@as(topology.VcpuCount, 2), parsed.value.platform.vcpu_count);
    try std.testing.expectEqual(@as(u64, 0x2_0000), parsed.value.platform.gic_redist_stride);
    try std.testing.expectEqual(@as(aarch64_topology.Mpidr, 0x8000_0001), parsed.value.machine.vcpus[1].mpidr);
    try std.testing.expectEqual(gicv3.StateKind.gicv3_multi, parsed.value.machine.gic.kind);

    var private_manifest = manifest;
    private_manifest.machine.gic = .{
        .kind = .backend_private,
        .backend_private = .{
            .backend = .hvf,
            .format = gicv3.hvf_backend_private_format,
            .data_b64 = "AA==",
        },
    };
    try validateManifestV1(private_manifest);
}

test "manifest v1 rejects invalid vCPU topology" {
    var redists = [_]gicv3.RedistributorState{
        .{ .mpidr = aarch64_topology.mpidrForIndex(0), .regs = &.{} },
        .{ .mpidr = aarch64_topology.mpidrForIndex(1), .regs = &.{} },
    };

    var count_vcpus = [_]VcpuState{ testVcpuState(0), testVcpuState(1) };
    var manifest = testManifestV1(testZeroMemoryManifest(1 << 29), 1 << 29, &count_vcpus, &redists);
    manifest.platform.vcpu_count = 3;
    try std.testing.expectError(error.BadManifest, validateManifestV1(manifest));

    var duplicate_index_vcpus = [_]VcpuState{ testVcpuState(0), testVcpuState(1) };
    manifest = testManifestV1(testZeroMemoryManifest(1 << 29), 1 << 29, &duplicate_index_vcpus, &redists);
    manifest.machine.vcpus[1].index = 0;
    try std.testing.expectError(error.BadManifest, validateManifestV1(manifest));

    var duplicate_mpidr_vcpus = [_]VcpuState{ testVcpuState(0), testVcpuState(1) };
    manifest = testManifestV1(testZeroMemoryManifest(1 << 29), 1 << 29, &duplicate_mpidr_vcpus, &redists);
    manifest.machine.vcpus[1].mpidr = manifest.machine.vcpus[0].mpidr;
    try std.testing.expectError(error.BadManifest, validateManifestV1(manifest));

    var missing_redist_vcpus = [_]VcpuState{ testVcpuState(0), testVcpuState(1) };
    manifest = testManifestV1(testZeroMemoryManifest(1 << 29), 1 << 29, &missing_redist_vcpus, redists[0..1]);
    try std.testing.expectError(error.BadManifest, validateManifestV1(manifest));
}

test "manifest rejects oversized annotations" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var manifest = testForkManifest(testZeroMemoryManifest(1 << 29), 1 << 29, 3);
    var annotations = Annotations{};
    const value = try arena.alloc(u8, max_annotations_json_bytes);
    @memset(value, 'x');
    try annotations.map.put(arena, "dev.buildkite.cleanroom.policy_hash", value);
    manifest.annotations = annotations;
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
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

test "manifest rejects overflowing virtqueue base addresses" {
    var queues = [_]QueueState{.{
        .size = 8,
        .ready = true,
        .desc_addr = 0x1000,
        .avail_addr = 0x2000,
        .used_addr = 0x3000,
        .last_avail = 0,
        .used_idx = 0,
    }};
    var devices = [_]TransportState{testTransport(3)};
    devices[0].queues = &queues;
    var manifest = testForkManifest(testZeroMemoryManifest(1 << 29), 1 << 29, 3);
    manifest.devices = &devices;

    queues[0].desc_addr = std.math.maxInt(u64);
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    queues[0].desc_addr = 0x1000;

    queues[0].avail_addr = std.math.maxInt(u64);
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    queues[0].avail_addr = 0x2000;

    queues[0].used_addr = std.math.maxInt(u64);
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
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

const test_zero_memory_size: usize = 1 << 29;
const test_zero_memory_chunks = initTestZeroMemoryChunks();
const test_single_zero_memory_chunk = [_]u64{0};

fn initTestZeroMemoryChunks() [test_zero_memory_size / chunk_size]u64 {
    var out: [test_zero_memory_size / chunk_size]u64 = undefined;
    for (&out, 0..) |*entry, i| entry.* = i;
    return out;
}

fn testZeroMemoryManifest(ram_size: u64) MemoryManifest {
    const zero_chunks = if (ram_size == test_zero_memory_size)
        test_zero_memory_chunks[0..]
    else if (ram_size == chunk_size)
        test_single_zero_memory_chunk[0..]
    else
        &.{};
    return .{
        .logical_size = ram_size,
        .chunk_size = chunk_size,
        .chunks = &.{},
        .zero_chunks = zero_chunks,
    };
}

fn testDisk(mmio_slot: u32) Disk {
    return .{
        .device = .{ .mmio_slot = mmio_slot },
        .size = 4096,
        .base = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
}

fn testVcpuState(index: topology.VcpuIndex) VcpuState {
    return .{
        .index = index,
        .mpidr = aarch64_topology.mpidrForIndex(index),
        .gprs = [_]u64{0} ** 31,
        .pc = 0,
        .cpsr = 0,
        .fpcr = 0,
        .fpsr = 0,
        .simd = [_][2]u64{.{ 0, 0 }} ** 32,
        .sys_regs = &.{},
        .icc_regs = &.{},
        .vtimer = .{ .cntvct = 0, .cntv_ctl = 0, .cntv_cval = 0 },
    };
}

fn testManifestV1(memory: MemoryManifest, ram_size: u64, vcpus: []VcpuState, redists: []const gicv3.RedistributorState) ManifestV1 {
    return .{
        .platform = .{
            .cpu_profile = "sporevm-aarch64-v0",
            .device_model_version = 4,
            .vcpu_count = @intCast(vcpus.len),
            .ram_base = 0x8000_0000,
            .ram_size = ram_size,
            .gic_dist_base = 0x0800_0000,
            .gic_redist_base = 0x0802_0000,
            .gic_redist_stride = 0x2_0000,
            .counter_frequency_hz = 24_000_000,
        },
        .machine = .{
            .vcpus = vcpus,
            .gic = .{
                .kind = .gicv3_multi,
                .gicv3_multi = .{
                    .dist_regs = &.{},
                    .redistributors = redists,
                    .line_levels = &.{},
                },
            },
        },
        .devices = &.{},
        .generation = .{ .generation = 1, .interrupt_status = 0, .params_b64 = "" },
        .memory = memory,
    };
}

fn testRootfsStorage(mmio_slot: u32) RootfsStorage {
    return .{
        .kind = rootfs_storage_kind_chunked_ext4,
        .device = .{ .mmio_slot = mmio_slot },
        .logical_size = 4096,
        .chunk_size = disk_chunk_size,
        .hash_algorithm = rootfs_storage_hash_algorithm_blake3,
        .index_digest = "blake3:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        .base_identity = "blake3:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        .object_namespace = rootfs_storage_object_namespace,
    };
}

test "manifest counts block devices" {
    try std.testing.expectEqual(
        @as(usize, 1),
        countBlockDevices(&.{ testTransport(3), testTransport(rootfs_virtio_blk_device_id) }),
    );
    try std.testing.expectEqual(@as(usize, 0), countBlockDevices(&.{testTransport(3)}));
}

test "manifest rootfs artifact validates transport binding" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    var devices = [_]TransportState{
        testTransport(3),
        testTransport(rootfs_virtio_blk_device_id),
    };
    var manifest = testForkManifest(testZeroMemoryManifest(1 << 29), 1 << 29, 3);
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

test "manifest disk validates rootfs-bound chunk index disk" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    var devices = [_]TransportState{
        testTransport(3),
        testTransport(rootfs_virtio_blk_device_id),
    };
    var manifest = testForkManifest(testZeroMemoryManifest(1 << 29), 1 << 29, 3);
    manifest.devices = &devices;
    manifest.rootfs = testRootfs(1);
    manifest.disk = testDisk(1);

    try saveManifest(arena, dir, manifest);
    const parsed = try loadManifest(arena, dir);
    defer parsed.deinit();
    const disk = parsed.value.disk orelse return error.BadManifest;
    try std.testing.expectEqualStrings(disk_kind_chunk_index, disk.kind);
    try std.testing.expectEqual(@as(u64, 4096), disk.size);
    try std.testing.expect(try diskQueuesQuiescent(disk, parsed.value.devices));

    manifest.rootfs = null;
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    manifest.rootfs = testRootfs(1);
    manifest.disk.?.base = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    manifest.disk.?.base = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    manifest.disk.?.device.mmio_slot = 0;
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    manifest.disk.?.device.mmio_slot = 1;
    manifest.disk.?.size = 8192;
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    manifest.disk.?.size = 4096;
    manifest.disk.?.layers = &.{"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"};
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    manifest.disk.?.layers = &.{};
    manifest.disk.?.kind = disk_kind_cow_block;
    try std.testing.expectError(error.FormatTooOld, validateManifest(manifest));
}

test "manifest disk binds to chunked rootfs storage identity" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    var devices = [_]TransportState{
        testTransport(3),
        testTransport(rootfs_virtio_blk_device_id),
    };
    var manifest = testForkManifest(testZeroMemoryManifest(1 << 29), 1 << 29, 3);
    manifest.devices = &devices;
    manifest.rootfs = testRootfs(1);
    manifest.rootfs.?.storage = testRootfsStorage(1);
    manifest.rootfs.?.artifact.digest = manifest.rootfs.?.storage.?.index_digest;
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

    manifest.rootfs.?.artifact.digest = "blake3:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    manifest.rootfs.?.artifact.digest = manifest.rootfs.?.storage.?.index_digest;

    manifest.rootfs.?.storage.?.base_identity = "blake3:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    manifest.rootfs.?.storage = testRootfsStorage(1);
    manifest.rootfs.?.artifact.digest = manifest.rootfs.?.storage.?.index_digest;

    manifest.rootfs.?.storage.?.device.mmio_slot = 0;
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    manifest.rootfs.?.storage = testRootfsStorage(1);
    manifest.rootfs.?.artifact.digest = manifest.rootfs.?.storage.?.index_digest;

    manifest.rootfs.?.storage.?.object_namespace = "../rootfs";
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
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
    parent_manifest.exec_defaults = .{
        .env = &.{"IMAGE_VALUE=default"},
        .working_dir = "/workspace",
    };
    parent_manifest.network = .{
        .allow_cidrs = &.{"93.184.216.0/24"},
        .allow_hosts = &.{"example.com"},
    };
    try std.Io.Dir.cwd().createDirPath(std.testing.io, try pathZ(arena, "{s}/cas", .{parent_dir}));
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
    try std.testing.expectEqualStrings("IMAGE_VALUE=default", first.value.exec_defaults.?.env[0]);
    try std.testing.expectEqualStrings("/workspace", first.value.exec_defaults.?.working_dir.?);
    try std.testing.expect(first.value.generation.params_b64.len > 0);
    try std.testing.expect(first.value.machine.gic.gicv3.?.line_levels[0].asserted);
    try std.testing.expect(first.value.rootfs != null);
    try std.testing.expectEqualStrings(parent_manifest.rootfs.?.artifact.digest, first.value.rootfs.?.artifact.digest);
    try std.testing.expect(first.value.disk != null);
    try std.testing.expectEqualStrings(parent_manifest.disk.?.base, first.value.disk.?.base);
    try std.testing.expectEqual(@as(usize, 0), first.value.disk.?.layers.len);
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

    const second_backing_path = try memoryBackingPath(arena, second_child_dir, second.value.memory.backing.?);
    const second_backing_fd = try openReadOnlyNoFollow(second_backing_path);
    defer _ = std.c.close(second_backing_fd);
    const parent_map = try std.posix.mmap(null, ram.len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE }, parent_backing_fd, 0);
    defer std.posix.munmap(parent_map);
    const first_map = try std.posix.mmap(null, ram.len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE }, child_backing_fd, 0);
    defer std.posix.munmap(first_map);
    const second_map = try std.posix.mmap(null, ram.len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE }, second_backing_fd, 0);
    defer std.posix.munmap(second_map);
    parent_map[0] = 0x11;
    try std.testing.expectEqual(@as(u8, 0x42), first_map[0]);
    try std.testing.expectEqual(@as(u8, 0x42), second_map[0]);
    first_map[0] = 0x22;
    try std.testing.expectEqual(@as(u8, 0x11), parent_map[0]);
    try std.testing.expectEqual(@as(u8, 0x42), second_map[0]);
    second_map[0] = 0x33;
    try std.testing.expectEqual(@as(u8, 0x11), parent_map[0]);
    try std.testing.expectEqual(@as(u8, 0x22), first_map[0]);
    try std.testing.expectEqual(@as(u8, 0x33), second_map[0]);
    var backing_byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), std.c.pread(parent_backing_fd, &backing_byte, backing_byte.len, 0));
    try std.testing.expectEqual(@as(u8, 0x42), backing_byte[0]);

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

test "fork propagates unexpected child proof write I/O and cleans the backing link" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const child_dir = try pathZ(arena, "{s}/child", .{root_dir});
    const runtime_dir = try pathZ(arena, "{s}/runtime", .{root_dir});
    const bad_runtime_dir = try pathZ(arena, "{s}/runtime-file", .{root_dir});
    try ensureNewDir(child_dir);
    try writeFileAll(bad_runtime_dir, "not a directory");
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.runtime_dir_env, runtime_dir);
    var bad_env = std.process.Environ.Map.init(allocator);
    defer bad_env.deinit();
    try bad_env.put(local_paths.runtime_dir_env, bad_runtime_dir);

    const ram = try arena.alloc(u8, chunk_size);
    @memset(ram, 0x35);
    const memory = try saveMemoryWithBacking(arena, parent_dir, ram);
    try writeLocalMemoryBackingProof(arena, &env, parent_dir, memory, ram.len);
    var child = testForkManifest(memory, ram.len, 12);
    const shared_backing = (try provenForkBacking(arena, &env, parent_dir, memory, ram.len, 1)) orelse return error.TestUnexpectedResult;
    defer shared_backing.deinit();

    try std.testing.expectError(
        error.IoFailed,
        prepareForkChildBacking(arena, child_dir, &child.memory, child.platform.ram_size, shared_backing, &bad_env),
    );
    try std.testing.expectEqual(@as(c_int, -1), std.c.access(try pathZ(arena, "{s}/{s}", .{ child_dir, ram_backing_path }), 0));
}

test "fork backing link rejects a path swap after proof validation" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const child_dir = try pathZ(arena, "{s}/child", .{root_dir});
    const runtime_dir = try pathZ(arena, "{s}/runtime", .{root_dir});
    try ensureNewDir(child_dir);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.runtime_dir_env, runtime_dir);

    const ram = try arena.alloc(u8, chunk_size);
    @memset(ram, 0x41);
    const memory = try saveMemoryWithBacking(arena, parent_dir, ram);
    try writeLocalMemoryBackingProof(arena, &env, parent_dir, memory, ram.len);
    const source = (try provenForkBacking(arena, &env, parent_dir, memory, ram.len, 1)) orelse return error.TestUnexpectedResult;
    defer source.deinit();

    if (std.c.unlink(source.source_path.ptr) != 0) return error.IoFailed;
    const replacement_fd = try createNewFile(source.source_path, 0o600);
    if (std.c.ftruncate(replacement_fd, @intCast(ram.len)) != 0) {
        _ = std.c.close(replacement_fd);
        return error.IoFailed;
    }
    try pwriteFileAll(replacement_fd, 0, &.{0x42});
    _ = std.c.close(replacement_fd);

    const backing_link = try pathZ(arena, "{s}/{s}", .{ child_dir, ram_backing_path });
    const next_fd = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (next_fd < 0) return error.IoFailed;
    _ = std.c.close(next_fd);
    try std.testing.expectError(error.IoFailed, linkAndVerifyForkBacking(source, backing_link));
    const after_error_fd = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (after_error_fd < 0) return error.IoFailed;
    defer _ = std.c.close(after_error_fd);
    try std.testing.expectEqual(next_fd, after_error_fd);
    try std.testing.expectEqual(@as(c_int, -1), std.c.access(backing_link, 0));
    try std.testing.expectEqual(@as(c_int, -1), std.c.access(try pathZ(arena, "{s}/{s}", .{ child_dir, ram_backing_proof_path }), 0));
}

test "fork backing hardlink falls back across filesystems" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (std.c.access("/dev/shm", 0) != 0) return error.SkipZigTest;
    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const child_dir = try testDirFromTemplate(arena, "/dev/shm/sporevm-test-XXXXXX");
    const child_dir_z = try pathZ(arena, "{s}", .{child_dir});
    defer _ = std.c.rmdir(child_dir_z);
    const runtime_dir = try pathZ(arena, "{s}/runtime", .{root_dir});
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.runtime_dir_env, runtime_dir);

    const ram = try arena.alloc(u8, chunk_size);
    @memset(ram, 0x5C);
    const memory = try saveMemoryWithBacking(arena, parent_dir, ram);
    try writeLocalMemoryBackingProof(arena, &env, parent_dir, memory, ram.len);
    const source = (try provenForkBacking(arena, &env, parent_dir, memory, ram.len, 1)) orelse return error.TestUnexpectedResult;
    defer source.deinit();

    if (try testLinuxPathDevice(source.source_path) == try testLinuxPathDevice(child_dir)) return error.SkipZigTest;

    var child = testForkManifest(memory, ram.len, 13);
    try prepareForkChildBacking(arena, child_dir, &child.memory, child.platform.ram_size, source, &env);
    try std.testing.expect(child.memory.backing == null);
    try std.testing.expectEqual(@as(c_int, -1), std.c.access(try pathZ(arena, "{s}/{s}", .{ child_dir, ram_backing_path }), 0));
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

test "fork mints manifest v1 child manifests with shared chunks and pending generation" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const out_dir = try pathZ(arena, "{s}/children", .{root_dir});

    const ram = try arena.alloc(u8, chunk_size);
    @memset(ram, 0xA5);
    const memory = try saveMemoryWithBacking(arena, parent_dir, ram);
    const runtime_dir = try pathZ(arena, "{s}/runtime", .{root_dir});
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.runtime_dir_env, runtime_dir);
    try writeLocalMemoryBackingProof(arena, &env, parent_dir, memory, ram.len);
    var vcpus = [_]VcpuState{ testVcpuState(0), testVcpuState(1) };
    const redists = [_]gicv3.RedistributorState{
        .{ .mpidr = aarch64_topology.mpidrForIndex(0), .regs = &.{} },
        .{ .mpidr = aarch64_topology.mpidrForIndex(1), .regs = &.{} },
    };
    var parent_manifest = testManifestV1(memory, ram.len, &vcpus, &redists);
    var devices = [_]TransportState{
        testTransport(3),
        testTransport(rootfs_virtio_blk_device_id),
    };
    parent_manifest.devices = &devices;
    parent_manifest.rootfs = testRootfs(1);
    parent_manifest.disk = testDisk(1);
    parent_manifest.generation = .{ .generation = 51, .interrupt_status = 0, .params_b64 = "" };
    try std.Io.Dir.cwd().createDirPath(std.testing.io, try pathZ(arena, "{s}/cas", .{parent_dir}));
    try saveManifestV1(arena, parent_dir, parent_manifest);

    const result = try fork(arena, .{
        .parent_dir = parent_dir,
        .out_dir = out_dir,
        .count = 2,
        .environ_map = &env,
    });
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqual(@as(u64, 51), result.parent_generation);
    try std.testing.expectEqual(@as(u64, 52), result.first_generation);
    try std.testing.expectEqual(@as(u64, 53), result.last_generation);

    const first_child_dir = try pathZ(arena, "{s}/000000", .{out_dir});
    try std.testing.expectError(error.BadManifest, loadManifest(arena, first_child_dir));
    const first = try loadManifestV1(arena, first_child_dir);
    defer first.deinit();
    try std.testing.expectEqual(@as(u32, format_version_v1), first.value.version);
    try std.testing.expectEqual(@as(topology.VcpuCount, 2), first.value.platform.vcpu_count);
    try std.testing.expectEqual(@as(u64, 52), first.value.generation.generation);
    try std.testing.expectEqual(@as(u32, generation.irq_generation_changed), first.value.generation.interrupt_status);
    try std.testing.expect(first.value.generation.params_b64.len > 0);
    try std.testing.expectEqual(gicv3.StateKind.gicv3_multi, first.value.machine.gic.kind);
    const first_gic = first.value.machine.gic.gicv3_multi.?;
    try std.testing.expectEqual(@as(usize, 1), first_gic.line_levels.len);
    try std.testing.expectEqual(board.generationIntid(), first_gic.line_levels[0].intid);
    try std.testing.expect(first_gic.line_levels[0].asserted);
    try std.testing.expect(first_gic.line_levels[0].mpidr == null);
    const first_backing = first.value.memory.backing orelse return error.BadManifest;
    try std.testing.expectEqualStrings(ram_backing_path, first_backing.path);
    const first_backing_path = try memoryBackingPath(arena, first_child_dir, first_backing);
    try std.testing.expectEqual(@as(c_int, 0), std.c.access(first_backing_path, 0));
    const first_backing_plan = try openProvenLocalMemoryBacking(arena, &env, first_child_dir, first.value.memory, first.value.platform.ram_size);
    defer if (first_backing_plan.fd) |fd| {
        _ = std.c.close(fd);
    };
    try std.testing.expectEqual(LocalBackingRestoreSource.local_backing, first_backing_plan.source);
    try std.testing.expectEqual(@as(c_int, 0), std.c.access(try pathZ(arena, "{s}/chunks", .{first_child_dir}), 0));

    const dec = std.base64.standard.Decoder;
    const decoded_size = try dec.calcSizeForSlice(first.value.generation.params_b64);
    const decoded = try arena.alloc(u8, decoded_size);
    try dec.decode(decoded, first.value.generation.params_b64);
    const stable = try std.json.parseFromSlice(ForkStableParams, arena, decoded, .{ .allocate = .alloc_always });
    defer stable.deinit();
    try std.testing.expectEqual(@as(u64, 51), stable.value.parent_generation);
    try std.testing.expectEqual(@as(u64, 52), stable.value.generation);
    try std.testing.expectEqual(@as(usize, 0), stable.value.fork_index);
    try std.testing.expectEqual(@as(usize, 2), stable.value.fork_count);

    const out = try arena.alloc(u8, ram.len);
    @memset(out, 0);
    try loadMemory(arena, first_child_dir, first.value.memory, out);
    try std.testing.expectEqualSlices(u8, ram, out);

    const parent_backing_path = try memoryBackingPath(arena, parent_dir, memory.backing.?);
    const parent_backing_fd = try openReadOnlyNoFollow(parent_backing_path);
    defer _ = std.c.close(parent_backing_fd);
    const child_backing_fd = try openReadOnlyNoFollow(first_backing_path);
    defer _ = std.c.close(child_backing_fd);
    try std.testing.expectEqual((try fstatLocalFile(parent_backing_fd)).inode, (try fstatLocalFile(child_backing_fd)).inode);

    const second_child_dir = try pathZ(arena, "{s}/000001", .{out_dir});
    const second = try loadManifestV1(arena, second_child_dir);
    defer second.deinit();
    try std.testing.expectEqual(@as(u64, 53), second.value.generation.generation);
}

test "fork preserves backend-private manifest v1 gic state" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const out_dir = try pathZ(arena, "{s}/children", .{root_dir});

    const ram = try arena.alloc(u8, chunk_size);
    @memset(ram, 0);
    const memory = try saveMemory(arena, parent_dir, ram);
    var vcpus = [_]VcpuState{ testVcpuState(0), testVcpuState(1) };
    const redists = [_]gicv3.RedistributorState{
        .{ .mpidr = aarch64_topology.mpidrForIndex(0), .regs = &.{} },
        .{ .mpidr = aarch64_topology.mpidrForIndex(1), .regs = &.{} },
    };
    var manifest = testManifestV1(memory, ram.len, &vcpus, &redists);
    manifest.machine.gic = .{
        .kind = .backend_private,
        .backend_private = .{
            .backend = .hvf,
            .format = gicv3.hvf_backend_private_format,
            .data_b64 = "AA==",
        },
    };
    const backend_gic = manifest.machine.gic.backend_private.?;
    try saveManifestV1(arena, parent_dir, manifest);

    const result = try fork(arena, .{
        .parent_dir = parent_dir,
        .out_dir = out_dir,
        .count = 1,
    });
    try std.testing.expectEqual(@as(usize, 1), result.count);

    const child_dir = try pathZ(arena, "{s}/000000", .{out_dir});
    const child = try loadManifestV1(arena, child_dir);
    defer child.deinit();
    try std.testing.expectEqual(gicv3.StateKind.backend_private, child.value.machine.gic.kind);
    const child_gic = child.value.machine.gic.backend_private.?;
    try std.testing.expectEqual(backend_gic.backend, child_gic.backend);
    try std.testing.expectEqualStrings(backend_gic.format, child_gic.format);
    try std.testing.expectEqualStrings(backend_gic.data_b64, child_gic.data_b64);
    try std.testing.expectEqual(@as(u32, generation.irq_generation_changed), child.value.generation.interrupt_status);
}

test "backend-private GIC state json round-trip" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
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
        .memory = testZeroMemoryManifest(1 << 29),
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
        .memory = testZeroMemoryManifest(1 << 29),
    };
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    manifest.platform.counter_frequency_hz = @as(u64, std.math.maxInt(u32)) + 1;
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    manifest.platform.counter_frequency_hz = 24_000_000;
    manifest.platform.cpu_profile = "";
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
}

test "manifest rejects invalid network policy" {
    var manifest = testForkManifest(testZeroMemoryManifest(1 << 29), 1 << 29, 3);

    manifest.network = .{ .kind = "future-net-v0" };
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));

    manifest.network = .{ .allow_cidrs = &.{"not-cidr"} };
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));

    manifest.network = .{ .allow_hosts = &.{"bad host"} };
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
}

test "backing readahead precharge tolerates sparse and empty files and restores position" {
    const io = std.testing.io;
    const tmp = "zig-cache/test-spore-precharge";
    defer std.Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp);

    // Sparse file: 1MiB data, 8MiB hole, 1MiB data.
    const sparse_path = tmp ++ "/sparse.backing";
    {
        const pathz = sparse_path ++ "";
        const fd = std.c.open(pathz, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, @as(c_uint, 0o644));
        try std.testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        var chunk: [1024 * 1024]u8 = undefined;
        @memset(&chunk, 0xAB);
        try std.testing.expect(std.c.pwrite(fd, &chunk, chunk.len, 0) == chunk.len);
        try std.testing.expect(std.c.pwrite(fd, &chunk, chunk.len, 9 * 1024 * 1024) == chunk.len);
        prechargeBackingReadahead(fd);
        // Position must be restored so later fd users see a rewound file.
        try std.testing.expectEqual(@as(std.c.off_t, 0), std.c.lseek(fd, 0, std.c.SEEK.CUR));
    }

    // Empty file: must be a no-op.
    const empty_path = tmp ++ "/empty.backing";
    {
        const fd = std.c.open(empty_path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, @as(c_uint, 0o644));
        try std.testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        prechargeBackingReadahead(fd);
    }
}
