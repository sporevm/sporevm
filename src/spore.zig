//! Spore manifest and chunk store.
//!
//! A spore is a directory rooted at `manifest.json`. Guest memory is stored as
//! fixed-size `chunks/<blake3-hex>` files with all-zero chunks elided; optional
//! writable disks use verified chunk indexes and CAS objects. Machine state is
//! normalized architectural aarch64 state — never raw
//! hypervisor structures (see docs/spore-format.md).
//!
//! Manifests and chunks may come from untrusted storage: parsing is strict,
//! chunk contents are verified against their ids before use, and restore
//! fails closed on any mismatch. See SECURITY.md.

const std = @import("std");
const board = @import("aarch64/board.zig");
const aarch64_topology = @import("aarch64/topology.zig");
const chunklib = @import("chunk.zig");
const chunk_sealer = @import("chunk_sealer.zig");
const disk_index = @import("disk_index.zig");
const fuzz_support = @import("fuzz_support.zig");
const generation = @import("generation.zig");
const gicv3 = @import("aarch64/gicv3.zig");
const memory_config = @import("memory.zig");
const spore_net_policy = @import("spore_net_policy.zig");
const topology = @import("topology.zig");
const virtqueue = @import("virtio/queue.zig");

/// Version 7 marks saved RAM whose guest agent speaks only SPIO and parses
/// every request strictly. Version 6 has the same manifest shape, but its RAM
/// runs an agent with the old text exec protocol, so it is too old.
pub const format_version: u32 = 7;
pub const max_manifest_bytes: usize = 64 * 1024 * 1024;
pub const chunk_size: usize = 2 * 1024 * 1024;
pub const ram_backing_kind = "map-private-file-v0";
pub const ram_backing_path = "ram.backing";
pub const ram_backing_proof_path = "ram.backing.proof";
pub const memory_object_namespace = "memory/blake3";
pub const virtio_mem_device_id: u32 = 24;

pub const Error = error{
    BadManifest,
    FormatTooOld,
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
    vcpu_count: topology.VcpuCount,
    ram_base: u64,
    ram_size: u64,
    gic_dist_base: u64,
    gic_redist_base: u64,
    gic_redist_stride: u64,
    /// Architected counter frequency in Hz. vtimer values are in this tick
    /// domain; restore requires an exact match until cross-frequency timer
    /// virtualization has a real design.
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

pub const MachineStateMulti = struct {
    vcpus: []VcpuState,
    /// Interrupt controller state. Portable producers use the multi-vCPU GICv3
    /// shape; same-backend temporary producers must tag private blobs so other
    /// backends fail closed.
    gic: gicv3.State,
};

/// One vCPU uses `single`; two or more use `multi`.
pub const Machine = union(enum) {
    single: MachineState,
    multi: MachineStateMulti,
};

pub const MemoryBacking = struct {
    kind: []const u8 = ram_backing_kind,
    path: []const u8,
    size: u64,
};

pub const MemoryChunk = disk_index.DiskIndexChunk;

/// The memory index. In the manifest it is a `spore-disk-index-v2` object plus
/// the optional `backing`; in memory `chunks` holds one chunk id per nonzero
/// chunk.
pub const MemoryManifest = struct {
    kind: []const u8 = disk_index.disk_index_kind,
    logical_size: u64,
    chunk_size: u64,
    hash_algorithm: []const u8 = rootfs_storage_hash_algorithm_blake3,
    object_namespace: []const u8 = memory_object_namespace,
    chunks: []const MemoryChunk = &.{},
    zero_ranges: []const disk_index.DiskIndexZeroRange = &.{},
    /// Optional same-host acceleration hint. Chunks remain the portable,
    /// verified source of truth; backends may ignore this and materialize
    /// from chunks instead.
    backing: ?MemoryBacking = null,

    const Encoded = struct {
        kind: []const u8,
        logical_size: u64,
        chunk_size: u64,
        hash_algorithm: []const u8,
        object_namespace: []const u8,
        chunk_ranges: []const disk_index.DiskIndexChunkRangeV2,
        zero_ranges: []const disk_index.DiskIndexZeroRange,
        backing: ?MemoryBacking = null,
    };

    pub fn jsonStringify(self: MemoryManifest, jws: *std.json.Stringify) std.json.Stringify.Error!void {
        try jws.beginObject();
        try disk_index.writeFields(jws, memoryIndex(self));
        if (self.backing != null or jws.options.emit_null_optional_fields) {
            try jws.objectField("backing");
            try jws.write(self.backing);
        }
        try jws.endObject();
    }

    /// Parses the encoded fields straight from the token stream so hostile
    /// input fails at the first unexpected token. Memory indexes of earlier
    /// kinds have different fields and fail like any other malformed object.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!MemoryManifest {
        const encoded = try std.json.innerParse(Encoded, allocator, source, options);
        const chunks = disk_index.decodeChunkRanges(allocator, .{
            .kind = encoded.kind,
            .logical_size = encoded.logical_size,
            .chunk_size = encoded.chunk_size,
            .hash_algorithm = encoded.hash_algorithm,
            .object_namespace = encoded.object_namespace,
            .chunk_ranges = encoded.chunk_ranges,
            .zero_ranges = encoded.zero_ranges,
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.BadManifest, error.FormatTooOld => error.UnexpectedToken,
        };
        return .{
            .kind = encoded.kind,
            .logical_size = encoded.logical_size,
            .chunk_size = encoded.chunk_size,
            .hash_algorithm = encoded.hash_algorithm,
            .object_namespace = encoded.object_namespace,
            .chunks = chunks,
            .zero_ranges = encoded.zero_ranges,
            .backing = encoded.backing,
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

pub const MemoryState = memory_config.CapturedState;
pub const MemoryPluggedRange = memory_config.PluggedRange;

pub const GenerationState = generation.State;
pub const max_annotations_json_bytes = 64 * 1024;
pub const Annotations = std.json.ArrayHashMap([]const u8);

pub const Manifest = struct {
    version: u32 = format_version,
    annotations: Annotations = .{},
    platform: Platform,
    machine: Machine,
    devices: []TransportState,
    generation: GenerationState,
    rootfs: ?Rootfs = null,
    disk: ?Disk = null,
    network: ?Network = null,
    sessions: []const Session = &.{},
    exec_defaults: ?ExecDefaults = null,
    /// Present only for elastic memory, which requires one vCPU.
    memory_state: ?MemoryState = null,
    memory: MemoryManifest,

    pub fn jsonStringify(self: @This(), writer: anytype) !void {
        try writer.beginObject();
        inline for (std.meta.fields(Manifest)) |field| {
            if (comptime std.mem.eql(u8, field.name, "exec_defaults") or std.mem.eql(u8, field.name, "memory_state")) {
                if (@field(self, field.name)) |value| {
                    try writer.objectField(field.name);
                    try writer.write(value);
                }
            } else {
                try writer.objectField(field.name);
                try writer.write(@field(self, field.name));
            }
        }
        try writer.endObject();
    }
};

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
    chunk_sealer.fsyncParentDirPath(allocator, dir) catch |err| return sealerError(err);
}

fn openDirectoryNoFollow(path: [:0]const u8) Error!std.c.fd_t {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.IoFailed;
    return fd;
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

fn pathZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Error![:0]const u8 {
    return std.fmt.allocPrintSentinel(allocator, fmt, args, 0) catch error.OutOfMemory;
}

fn memoryIndex(manifest: MemoryManifest) disk_index.DiskIndex {
    return .{
        .kind = manifest.kind,
        .logical_size = manifest.logical_size,
        .chunk_size = manifest.chunk_size,
        .hash_algorithm = manifest.hash_algorithm,
        .object_namespace = manifest.object_namespace,
        .chunks = manifest.chunks,
        .zero_ranges = manifest.zero_ranges,
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

pub fn memoryIndexIdentity(allocator: std.mem.Allocator, memory: MemoryManifest, expected_size: u64) Error![]const u8 {
    if (expected_size > std.math.maxInt(usize)) return error.BadManifest;
    _ = try validateMemoryForRam(memory, @intCast(expected_size));
    const encoded_index = disk_index.encodeCanonicalAlloc(allocator, memoryIndex(memory)) catch |err| return switch (err) {
        error.BadManifest, error.FormatTooOld => error.BadManifest,
        error.OutOfMemory => error.OutOfMemory,
    };
    allocator.free(encoded_index.bytes);
    return encoded_index.digest;
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

pub fn diskQueuesQuiescent(disk_device: RootfsDevice, devices: []const TransportState) Error!bool {
    try validateRootfsDevice(disk_device, devices);
    const device = devices[disk_device.mmio_slot];
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
/// Chunks go through the same durable `chunk_sealer` write as the dirty RAM
/// sealer: each is fsynced with its directory entry before this returns.
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
    var zero_ranges: std.ArrayList(disk_index.DiskIndexZeroRange) = .empty;
    errdefer zero_ranges.deinit(allocator);

    var work_stats: chunk_sealer.WorkStats = .{};
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const start = i * chunk_size;
        const end = @min(start + chunk_size, ram.len);
        const data = ram[start..end];
        const id = switch (chunk_sealer.sealBytes(data, &work_stats) catch |err| return sealerError(err)) {
            .zero => {
                try disk_index.appendZeroChunk(allocator, &zero_ranges, @intCast(i));
                continue;
            },
            .data => |id| id,
        };
        const hex = id.toHex();
        chunks.append(.{ .logical_chunk = @intCast(i), .id = id }) catch return error.OutOfMemory;
        const chunk_path = try pathZ(allocator, "{s}/chunks/{s}", .{ dir, hex[0..] });
        chunk_sealer.writeFileAllIfMissing(allocator, chunk_path, data) catch |err| return sealerError(err);
        if (backing_fd >= 0) {
            chunk_sealer.pwriteFileAll(backing_fd, start, data) catch |err| return sealerError(err);
        }
    }

    const backing = if (with_backing) blk: {
        // Its proof binds the file, not the bytes: sync them before one exists.
        if (std.c.fsync(backing_fd) != 0) return error.IoFailed;
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
    const zero_slice = try zero_ranges.toOwnedSlice(allocator);
    errdefer allocator.free(zero_slice);
    return .{
        .logical_size = @intCast(ram.len),
        .chunk_size = chunk_size,
        .chunks = chunk_slice,
        .zero_ranges = zero_slice,
        .backing = backing,
    };
}

fn sealerError(err: chunk_sealer.Error) Error {
    return switch (err) {
        error.ClockFailed => error.IoFailed,
        else => |e| e,
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
        const id: ?chunklib.ChunkId = if (nonzero_index < manifest.chunks.len and manifest.chunks[nonzero_index].logical_chunk == i) blk: {
            const value = manifest.chunks[nonzero_index].id;
            nonzero_index += 1;
            break :blk value;
        } else null;
        try loadMemoryChunk(allocator, dir, id, ram[range.start..range.end]);
    }
}

pub fn validateMemoryForRam(manifest: MemoryManifest, ram_len: usize) Error!MemoryPlan {
    const expected_size: u64 = @intCast(ram_len);
    // The manifest version gate rejects old manifests as too old, so a retired
    // memory index kind inside a current manifest is just malformed.
    disk_index.validateDiskIndex(memoryIndex(manifest), memoryIndexDescriptor(manifest, expected_size)) catch |err| return switch (err) {
        error.BadManifest, error.FormatTooOld => error.BadManifest,
        error.OutOfMemory => error.OutOfMemory,
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

fn memoryChunkRangeFromPlan(plan: MemoryPlan, ram_len: usize, index: usize) !MemoryChunkRange {
    if (index >= plan.chunk_count) return error.BadManifest;
    const start = index * plan.chunk_size;
    const end = @min(start + plan.chunk_size, ram_len);
    return .{ .start = start, .end = end };
}

fn loadMemoryChunk(allocator: std.mem.Allocator, dir: []const u8, maybe_id: ?chunklib.ChunkId, target: []u8) Error!void {
    if (maybe_id) |id| {
        const hex = id.toHex();
        const chunk_path = try pathZ(allocator, "{s}/chunks/{s}", .{ dir, &hex });
        const data = try readFileAll(allocator, chunk_path, target.len);
        defer allocator.free(data);
        if (data.len != target.len) return error.BadChunk;
        if (!id.matches(data)) return error.BadChunk;
        @memcpy(target, data);
    } else {
        @memset(target, 0);
    }
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

/// Replaces the manifest atomically and durably: a crash leaves the old or the
/// new manifest, never a truncated one.
pub fn saveManifestPath(allocator: std.mem.Allocator, path: []const u8, manifest: Manifest) Error!void {
    const json = try encodeManifestAlloc(allocator, manifest);
    defer allocator.free(json);
    chunk_sealer.replaceFileAtomicDurable(allocator, path, json, 0o644) catch |err| return sealerError(err);
}

/// Validates and encodes manifest bytes for every writer, including those
/// that publish them through a pin.
pub fn encodeManifestAlloc(allocator: std.mem.Allocator, manifest: Manifest) Error![]u8 {
    try validateManifest(manifest);
    return std.json.Stringify.valueAlloc(allocator, manifest, .{ .whitespace = .indent_2 }) catch error.OutOfMemory;
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
    return parseManifest(allocator, bytes);
}

/// Parses and validates manifest bytes. The version is checked before the
/// shape, so manifests from older formats fail as FormatTooOld.
pub fn parseManifest(allocator: std.mem.Allocator, bytes: []const u8) Error!std.json.Parsed(Manifest) {
    // Every manifest version has had these objects. Requiring them keeps
    // another program's manifest.json with a small `version` from passing as
    // an old spore.
    const VersionProbe = struct { version: u32, platform: struct {}, machine: struct {}, memory: struct {} };
    const probe = std.json.parseFromSlice(VersionProbe, allocator, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadManifest,
    };
    const version = probe.value.version;
    probe.deinit();
    try validateManifestVersion(version);

    const parsed = std.json.parseFromSlice(Manifest, allocator, bytes, .{
        // Callers may free the byte buffer before using the parse result.
        .allocate = .alloc_always,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadManifest,
    };
    errdefer parsed.deinit();
    validateManifest(parsed.value) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadManifest,
    };
    return parsed;
}

pub fn validateManifest(manifest: Manifest) Error!void {
    try validateManifestVersion(manifest.version);
    try validateAnnotations(manifest.annotations);
    try validateSessions(manifest.sessions);
    if (manifest.exec_defaults) |defaults| try validateExecDefaults(defaults);
    if (manifest.platform.cpu_profile.len == 0) return error.BadManifest;
    if (manifest.platform.counter_frequency_hz == 0 or
        manifest.platform.counter_frequency_hz > std.math.maxInt(u32))
    {
        return error.BadManifest;
    }
    const memory_size = if (manifest.memory_state) |state| try validateMemoryState(state, manifest.platform.ram_size) else manifest.platform.ram_size;
    if (memory_size > std.math.maxInt(usize)) return error.BadManifest;
    _ = try validateMemoryForRam(manifest.memory, @intCast(memory_size));
    if (manifest.memory.backing) |backing| {
        try validateMemoryBacking(backing, memory_size);
    }
    try validateTransportQueues(manifest.devices);
    var virtio_mem_count: usize = 0;
    for (manifest.devices) |device| {
        if (device.device_id == virtio_mem_device_id) virtio_mem_count += 1;
    }
    if (virtio_mem_count != @intFromBool(manifest.memory_state != null)) return error.BadManifest;
    if (manifest.rootfs) |r| {
        try validateRootfs(r, manifest.devices);
    }
    if (manifest.disk) |d| {
        try validateDisk(d, manifest.rootfs, manifest.devices);
    }
    if (manifest.network) |n| {
        try validateNetwork(n);
    }
    try validateMachine(manifest.platform, manifest.machine);
    // Elastic memory restore supports one vCPU.
    if (manifest.memory_state != null and manifest.machine != .single) return error.BadManifest;
}

fn validateManifestVersion(version: u32) Error!void {
    if (version < format_version) return error.FormatTooOld;
    if (version > format_version) return error.BadManifest;
}

pub fn memoryConfig(ram_size: u64, state: ?MemoryState) Error!memory_config.Config {
    if (state) |elastic| {
        _ = try validateMemoryState(elastic, ram_size);
        return elastic.config();
    }
    return memory_config.fromManifestBytes(ram_size) catch return error.BadManifest;
}

fn validateMemoryState(state: MemoryState, ram_size: u64) Error!u64 {
    if (state.initial_size != ram_size or state.maximum_size <= state.initial_size) return error.BadManifest;
    state.config().validate() catch return error.BadManifest;
    if (state.block_size != memory_config.elastic_block_size) return error.BadManifest;
    if (state.requested_size < state.initial_size or state.requested_size > state.maximum_size) return error.BadManifest;
    if (state.captured_size < state.initial_size or state.captured_size > state.requested_size) return error.BadManifest;
    if ((state.requested_size - state.initial_size) % state.block_size != 0) return error.BadManifest;
    if ((state.captured_size - state.initial_size) % state.block_size != 0) return error.BadManifest;

    const region_blocks = (state.maximum_size - state.initial_size) / state.block_size;
    const requested_blocks = (state.requested_size - state.initial_size) / state.block_size;
    var next_block: u64 = 0;
    var plugged_blocks: u64 = 0;
    for (state.plugged_ranges) |range| {
        if (range.block_count == 0 or range.start_block < next_block) return error.BadManifest;
        const end = std.math.add(u64, range.start_block, range.block_count) catch return error.BadManifest;
        if (end > region_blocks or end > requested_blocks) return error.BadManifest;
        plugged_blocks = std.math.add(u64, plugged_blocks, range.block_count) catch return error.BadManifest;
        next_block = end;
    }
    const plugged_bytes = std.math.mul(u64, plugged_blocks, state.block_size) catch return error.BadManifest;
    if (state.captured_size != state.initial_size + plugged_bytes) return error.BadManifest;
    return state.maximum_size;
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

fn validateMachine(platform: Platform, machine: Machine) Error!void {
    topology.validateVcpuCount(platform.vcpu_count) catch return error.BadManifest;
    if (platform.gic_redist_stride == 0) return error.BadManifest;
    _ = board.redistributorRegionSize(platform.gic_redist_stride, platform.vcpu_count) catch return error.BadManifest;
    switch (machine) {
        .single => |single| {
            if (platform.vcpu_count != 1) return error.BadManifest;
            if (single.gic.kind == .gicv3_multi) return error.BadManifest;
            gicv3.validate(single.gic) catch return error.BadManifest;
        },
        .multi => |multi| try validateMachineMulti(platform, multi),
    }
}

fn validateMachineMulti(platform: Platform, machine: MachineStateMulti) Error!void {
    if (platform.vcpu_count < 2) return error.BadManifest;
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

fn writeFileAll(path: [:0]const u8, data: []const u8) Error!void {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0o644));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);
    try writeAllFd(fd, data);
}

fn writeAllFd(fd: std.c.fd_t, data: []const u8) Error!void {
    var done: usize = 0;
    while (done < data.len) {
        const n = std.c.write(fd, data.ptr + done, data.len - done);
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
}

const manifest_test_support = @import("manifest_test_support.zig");
const testDisk = manifest_test_support.testDisk;
const testForkManifest = manifest_test_support.testForkManifest;
const testManifestMulti = manifest_test_support.testManifestMulti;
const testRootfs = manifest_test_support.testRootfs;
const testTransport = manifest_test_support.testTransport;
const testVcpuState = manifest_test_support.testVcpuState;
fn testDirFromTemplate(allocator: std.mem.Allocator, template: []const u8) ![:0]const u8 {
    const buf = try allocator.dupeZ(u8, template);
    if (mkdtemp(buf) == null) return error.IoFailed;
    return buf;
}

fn testDir(allocator: std.mem.Allocator) ![:0]const u8 {
    return testDirFromTemplate(allocator, "/tmp/sporevm-test-XXXXXX");
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
    try std.Io.Dir.cwd().symLink(std.testing.io, target_dir, link_dir, .{});
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
    try std.testing.expectEqualStrings(disk_index.disk_index_kind, mm.kind);
    try std.testing.expectEqual(@as(u64, ram.len), mm.logical_size);
    try std.testing.expectEqual(@as(usize, 3), mm.chunks.len);
    try std.testing.expectEqual(@as(u64, 0), mm.chunks[0].logical_chunk);
    try std.testing.expectEqual(@as(u64, 3), mm.chunks[1].logical_chunk);
    try std.testing.expectEqual(@as(u64, 5), mm.chunks[2].logical_chunk);
    try std.testing.expectEqualSlices(disk_index.DiskIndexZeroRange, &.{
        .{ .start = 1, .count = 2 },
        .{ .start = 4, .count = 1 },
    }, mm.zero_ranges);
    const plan = try validateMemoryForRam(mm, ram.len);
    try std.testing.expectEqual(@as(usize, chunk_size), plan.chunk_size);
    try std.testing.expectEqual(@as(usize, 6), plan.chunk_count);
    try std.testing.expectEqual(@as(usize, 3), plan.nonzero_chunk_count);

    const out = try arena.alloc(u8, ram.len);
    @memset(out, 0xAA);
    try loadMemory(arena, dir, mm, out);
    try std.testing.expectEqualSlices(u8, ram, out);
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
    try std.Io.Dir.cwd().symLink(std.testing.io, victim_path, tmp_path, .{});

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

test "manifest save replaces a symlink instead of writing through it" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    const victim_path = try pathZ(arena, "{s}/victim", .{dir});
    try writeFileAll(victim_path, "untouched");
    const manifest_path = try pathZ(arena, "{s}/manifest.json", .{dir});
    try std.Io.Dir.cwd().symLink(std.testing.io, victim_path, manifest_path, .{});

    try saveManifest(arena, dir, testForkManifest(testZeroMemoryManifest(chunk_size), chunk_size, 1));

    const victim = try readFileAll(arena, victim_path, 1024);
    try std.testing.expectEqualStrings("untouched", victim);
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, manifest_path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.file, stat.kind);
    const loaded = try loadManifest(arena, dir);
    loaded.deinit();
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

    var wrong_kind = mm;
    wrong_kind.kind = "unknown-index-v0";
    try std.testing.expectError(error.BadManifest, validateMemoryForRam(wrong_kind, ram.len));

    var retired_kind = mm;
    retired_kind.kind = "spore-disk-index-v1";
    try std.testing.expectError(error.BadManifest, validateMemoryForRam(retired_kind, ram.len));
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
    const chunk_path = try pathZ(arena, "{s}/chunks/{s}", .{ dir, &mm.chunks[0].id.toHex() });
    const data = try readFileAll(arena, chunk_path, chunk_size);
    data[100] ^= 0xFF;
    try writeFileAll(chunk_path, data);

    const out = try arena.alloc(u8, ram.len);
    try std.testing.expectError(error.BadChunk, loadMemory(arena, dir, mm, out));
}

fn fuzzManifestParse(_: void, s: *std.testing.Smith) !void {
    // Manifests come from untrusted storage: parsing must never crash and
    // must either fail or produce a structurally valid manifest, including the
    // per-vCPU and per-redistributor arrays of multi-vCPU machine state.
    var buf: [4096]u8 = undefined;
    const len = s.slice(&buf);
    const parsed = parseManifest(std.testing.allocator, buf[0..len]) catch return;
    defer parsed.deinit();
}

test "fuzz manifest parsing" {
    // Valid single- and multi-vCPU manifests let the fuzzer reach the
    // machine union arms and validation.
    try std.testing.fuzz({}, fuzzManifestParse, .{ .corpus = &.{
        fuzz_support.sliceSeed(
            \\{"version":7,"platform":{"cpu_profile":"sporevm-aarch64-v0","device_model_version":4,"vcpu_count":1,"ram_base":2147483648,"ram_size":2097152,"gic_dist_base":134217728,"gic_redist_base":134283264,"gic_redist_stride":131072,"counter_frequency_hz":24000000},"machine":{"single":{"gprs":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"pc":0,"cpsr":0,"fpcr":0,"fpsr":0,"simd":[[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0]],"sys_regs":[],"icc_regs":[],"vtimer":{"cntvct":0,"cntv_ctl":0,"cntv_cval":0},"gic":{"kind":"gicv3","gicv3":{"dist_regs":[],"redist_regs":[],"line_levels":[{"intid":56,"asserted":false}]}}}},"devices":[],"generation":{"generation":1,"interrupt_status":0,"params_b64":""},"memory":{"kind":"spore-disk-index-v2","logical_size":2097152,"chunk_size":2097152,"hash_algorithm":"blake3","object_namespace":"memory/blake3","chunk_ranges":[],"zero_ranges":[{"start":0,"count":1}]}}
        ),
        fuzz_support.sliceSeed(
            \\{"version":7,"platform":{"cpu_profile":"sporevm-aarch64-v0","device_model_version":4,"vcpu_count":2,"ram_base":2147483648,"ram_size":2097152,"gic_dist_base":134217728,"gic_redist_base":134348800,"gic_redist_stride":131072,"counter_frequency_hz":24000000},"machine":{"multi":{"vcpus":[{"index":0,"mpidr":2147483648,"gprs":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"pc":0,"cpsr":0,"fpcr":0,"fpsr":0,"simd":[[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0]],"sys_regs":[],"icc_regs":[],"vtimer":{"cntvct":0,"cntv_ctl":0,"cntv_cval":0}},{"index":1,"mpidr":2147483649,"gprs":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"pc":0,"cpsr":0,"fpcr":0,"fpsr":0,"simd":[[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0]],"sys_regs":[],"icc_regs":[],"vtimer":{"cntvct":0,"cntv_ctl":0,"cntv_cval":0}}],"gic":{"kind":"gicv3_multi","gicv3_multi":{"schema_version":1,"dist_regs":[],"redistributors":[{"mpidr":2147483648,"regs":[]},{"mpidr":2147483649,"regs":[]}],"line_levels":[]}}}},"devices":[],"generation":{"generation":1,"interrupt_status":0,"params_b64":""},"memory":{"kind":"spore-disk-index-v2","logical_size":2097152,"chunk_size":2097152,"hash_algorithm":"blake3","object_namespace":"memory/blake3","chunk_ranges":[],"zero_ranges":[{"start":0,"count":1}]}}
        ),
    } });
}

fn fuzzElasticMemoryState(_: void, s: *std.testing.Smith) !void {
    // Elastic memory state is attacker-controlled manifest input. Exercise
    // range arithmetic independently so malformed block layouts cannot wrap,
    // overlap, or escape the declared maximum.
    var ranges: [16]MemoryPluggedRange = undefined;
    const range_count = @as(usize, s.value(u8)) % (ranges.len + 1);
    for (ranges[0..range_count]) |*range| {
        range.* = .{
            .start_block = s.value(u32),
            .block_count = s.value(u32),
        };
    }
    const state = MemoryState{
        .initial_size = s.value(u64),
        .maximum_size = s.value(u64),
        .requested_size = s.value(u64),
        .captured_size = s.value(u64),
        .block_size = s.value(u64),
        .plugged_ranges = ranges[0..range_count],
    };
    _ = validateMemoryState(state, s.value(u64)) catch return;
}

test "fuzz elastic memory state validation" {
    try std.testing.fuzz({}, fuzzElasticMemoryState, .{});
}

fn fuzzMemoryManifestParse(_: void, s: *std.testing.Smith) !void {
    // Memory indexes arrive in manifests from bundles and peers. Start near
    // a valid object so mutations reach range decoding and validation
    // instead of stopping at the JSON tokenizer.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ram_len = 6 * chunk_size;
    const seed = MemoryManifest{
        .logical_size = ram_len,
        .chunk_size = chunk_size,
        .chunks = &.{
            .{ .logical_chunk = 0, .id = .{ .bytes = @splat(0xaa) } },
            .{ .logical_chunk = 1, .id = .{ .bytes = @splat(0xbb) } },
            .{ .logical_chunk = 4, .id = .{ .bytes = @splat(0xcc) } },
        },
        .zero_ranges = &.{ .{ .start = 2, .count = 2 }, .{ .start = 5, .count = 1 } },
        .backing = .{ .path = ram_backing_path, .size = ram_len },
    };
    const bytes = try std.json.Stringify.valueAlloc(arena, seed, .{ .whitespace = .indent_2 });
    const mutation_count = s.valueRangeAtMost(u8, 0, 4);
    for (0..mutation_count) |_| bytes[s.index(bytes.len)] = s.value(u8);
    const input = bytes[0..s.valueRangeAtMost(u32, 1, @intCast(bytes.len))];

    const parsed = std.json.parseFromSliceLeaky(MemoryManifest, arena, input, .{}) catch return;
    const plan = validateMemoryForRam(parsed, ram_len) catch return;
    var zero_chunks: usize = 0;
    for (parsed.zero_ranges) |range| zero_chunks += @intCast(range.count);
    try std.testing.expectEqual(plan.chunk_count, parsed.chunks.len + zero_chunks);
    const encoded = try std.json.Stringify.valueAlloc(arena, parsed, .{ .whitespace = .indent_2 });
    const reparsed = try std.json.parseFromSliceLeaky(MemoryManifest, arena, encoded, .{});
    try std.testing.expectEqualStrings(encoded, try std.json.Stringify.valueAlloc(arena, reparsed, .{ .whitespace = .indent_2 }));
}

test "fuzz memory manifest decoder" {
    try std.testing.fuzz({}, fuzzMemoryManifestParse, .{});
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
            .vcpu_count = 1,
            .ram_base = 0x8000_0000,
            .ram_size = 1 << 29,
            .gic_dist_base = 0x0800_0000,
            .gic_redist_base = 0x0801_0000,
            .gic_redist_stride = 0x2_0000,
            .counter_frequency_hz = 24_000_000,
        },
        .machine = .{ .single = .{
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
        } },
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
    try std.testing.expectEqual(@as(topology.VcpuCount, 1), parsed.value.platform.vcpu_count);
    try std.testing.expectEqual(@as(u64, 0x2_0000), parsed.value.platform.gic_redist_stride);
    const machine = parsed.value.machine.single;
    try std.testing.expectEqual(@as(u64, 123), machine.vtimer.cntvct);
    try std.testing.expectEqualStrings("sctlr_el1", machine.sys_regs[0].name);
    try std.testing.expectEqual(gicv3.StateKind.gicv3, machine.gic.kind);
    try std.testing.expectEqual(@as(u32, gicv3.distRouterOffset(32)), machine.gic.gicv3.?.dist_regs[0].offset);
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

test "manifest memory index uses the canonical disk-index encoding" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    const ram = try arena.alloc(u8, 6 * chunk_size);
    @memset(ram, 0);
    ram[0] = 1;
    ram[chunk_size] = 2;
    ram[4 * chunk_size] = 3;
    var mm = try saveMemory(arena, dir, ram);
    mm.backing = .{ .path = ram_backing_path, .size = ram.len };

    // Without `backing`, the memory object is byte-for-byte the canonical
    // index whose digest fingerprints local RAM backing proofs.
    var bare = mm;
    bare.backing = null;
    const bare_json = try std.json.Stringify.valueAlloc(arena, bare, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    const encoded = try disk_index.encodeCanonicalAlloc(arena, memoryIndex(mm));
    try std.testing.expectEqualStrings(encoded.bytes, bare_json);
    try std.testing.expect(std.mem.indexOf(u8, bare_json, "\"start\": 4") != null);

    const json = try std.json.Stringify.valueAlloc(arena, mm, .{ .whitespace = .indent_2 });
    const parsed = try std.json.parseFromSliceLeaky(MemoryManifest, arena, json, .{});
    try std.testing.expectEqualStrings(disk_index.disk_index_kind, parsed.kind);
    try std.testing.expectEqual(mm.chunks.len, parsed.chunks.len);
    for (mm.chunks, parsed.chunks) |expected, actual| {
        try std.testing.expectEqual(expected.logical_chunk, actual.logical_chunk);
        try std.testing.expect(expected.id.eql(actual.id));
    }
    try std.testing.expectEqualSlices(disk_index.DiskIndexZeroRange, mm.zero_ranges, parsed.zero_ranges);
    try std.testing.expectEqualStrings(ram_backing_path, parsed.backing.?.path);
    try std.testing.expectEqualStrings(json, try std.json.Stringify.valueAlloc(arena, parsed, .{ .whitespace = .indent_2 }));
    _ = try validateMemoryForRam(parsed, ram.len);

    const duplicate = try std.mem.replaceOwned(u8, arena, json, "\"chunk_size\": ", "\"chunk_size\": 1,\n  \"chunk_size\": ");
    try std.testing.expectError(error.DuplicateField, std.json.parseFromSliceLeaky(MemoryManifest, arena, duplicate, .{}));
    const unknown = try std.mem.replaceOwned(u8, arena, json, "\"zero_ranges\": ", "\"chunks\": [],\n  \"zero_ranges\": ");
    try std.testing.expectError(error.UnknownField, std.json.parseFromSliceLeaky(MemoryManifest, arena, unknown, .{}));
    const split_hex = mm.chunks[1].id.toHex();
    const split = try std.mem.replaceOwned(u8, arena, json, &split_hex, try std.fmt.allocPrint(arena, "\"\n    }},\n    {{\n      \"start\": 1,\n      \"digests\": \"{s}", .{&split_hex}));
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSliceLeaky(MemoryManifest, arena, split, .{}));
    const not_hex = try std.mem.replaceOwned(u8, arena, json, split_hex[0..8], "zzzzzzzz");
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSliceLeaky(MemoryManifest, arena, not_hex, .{}));
}

test "manifest with a v1 memory index is rejected" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    try saveManifest(arena, dir, testForkManifest(testZeroMemoryManifest(1 << 29), 1 << 29, 3));
    _ = try loadManifest(arena, dir);
    const path = try pathZ(arena, "{s}/manifest.json", .{dir});
    var root = try std.json.parseFromSliceLeaky(std.json.Value, arena, try readFileAll(arena, path, max_manifest_bytes), .{});
    // Rewrite the memory index in the removed v1 shape.
    const memory = &root.object.getPtr("memory").?.object;
    try memory.put(arena, "kind", .{ .string = "spore-disk-index-v1" });
    _ = memory.orderedRemove("chunk_ranges");
    _ = memory.orderedRemove("zero_ranges");
    try memory.put(arena, "chunks", .{ .array = .init(arena) });
    var zero_chunks: std.json.Array = .init(arena);
    for (0..(1 << 29) / chunk_size) |i| try zero_chunks.append(.{ .integer = @intCast(i) });
    try memory.put(arena, "zero_chunks", .{ .array = zero_chunks });
    try writeFileAll(path, try std.json.Stringify.valueAlloc(arena, root, .{ .whitespace = .indent_2 }));
    try std.testing.expectError(error.BadManifest, loadManifest(arena, dir));
}

test "manifests from older formats fail as too old" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    const path = try pathZ(arena, "{s}/manifest.json", .{dir});
    try saveManifest(arena, dir, testForkManifest(testZeroMemoryManifest(1 << 29), 1 << 29, 3));
    const current = try std.json.parseFromSliceLeaky(std.json.Value, arena, try readFileAll(arena, path, max_manifest_bytes), .{});

    // Version 2 stored single-vCPU machine state unwrapped and had no
    // vcpu_count or redistributor stride; versions 3 and 5 wrapped vCPUs in a
    // schema-versioned object. Each older version fails before its shape is
    // parsed.
    var single = try cloneJsonValue(arena, current);
    const single_platform = &single.object.getPtr("platform").?.object;
    _ = single_platform.orderedRemove("vcpu_count");
    _ = single_platform.orderedRemove("gic_redist_stride");
    try single.object.put(arena, "machine", current.object.get("machine").?.object.get("single").?);
    for ([_]i64{ 0, 1, 2, 4 }) |version| {
        try single.object.put(arena, "version", .{ .integer = version });
        try writeFileAll(path, try std.json.Stringify.valueAlloc(arena, single, .{}));
        try std.testing.expectError(error.FormatTooOld, loadManifest(arena, dir));
    }
    var multi = try cloneJsonValue(arena, current);
    var multi_machine: std.json.ObjectMap = .empty;
    try multi_machine.put(arena, "schema_version", .{ .integer = 1 });
    try multi_machine.put(arena, "vcpus", .{ .array = .init(arena) });
    try multi.object.put(arena, "machine", .{ .object = multi_machine });
    for ([_]i64{ 3, 5 }) |version| {
        try multi.object.put(arena, "version", .{ .integer = version });
        try writeFileAll(path, try std.json.Stringify.valueAlloc(arena, multi, .{}));
        try std.testing.expectError(error.FormatTooOld, loadManifest(arena, dir));
    }
    // Version 6 has the current shape, but its saved RAM runs a guest agent
    // that speaks the removed text exec protocol.
    var v6 = try cloneJsonValue(arena, current);
    try v6.object.put(arena, "version", .{ .integer = 6 });
    try writeFileAll(path, try std.json.Stringify.valueAlloc(arena, v6, .{}));
    try std.testing.expectError(error.FormatTooOld, loadManifest(arena, dir));

    // Unknown newer versions and manifests without a version are malformed.
    var future = try cloneJsonValue(arena, current);
    try future.object.put(arena, "version", .{ .integer = format_version + 1 });
    try writeFileAll(path, try std.json.Stringify.valueAlloc(arena, future, .{}));
    try std.testing.expectError(error.BadManifest, loadManifest(arena, dir));
    _ = future.object.orderedRemove("version");
    try writeFileAll(path, try std.json.Stringify.valueAlloc(arena, future, .{}));
    try std.testing.expectError(error.BadManifest, loadManifest(arena, dir));

    // Other programs write manifest.json too, and std.json reads the string
    // "1.0" as the integer 1. Without spore members it is not an old spore.
    try writeFileAll(path, "{\"manifest_version\":3,\"name\":\"ext\",\"version\":\"1.0\"}");
    try std.testing.expectError(error.BadManifest, loadManifest(arena, dir));
}

test "manifest machine state is one tagged union" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    const path = try pathZ(arena, "{s}/manifest.json", .{dir});
    try saveManifest(arena, dir, testForkManifest(testZeroMemoryManifest(1 << 29), 1 << 29, 3));
    const json = try readFileAll(arena, path, max_manifest_bytes);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\": 7,") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"machine\": {\n    \"single\": {\n      \"gprs\"") != null);

    var vcpus = [_]VcpuState{ testVcpuState(0), testVcpuState(1) };
    const redists = [_]gicv3.RedistributorState{
        .{ .mpidr = aarch64_topology.mpidrForIndex(0), .regs = &.{} },
        .{ .mpidr = aarch64_topology.mpidrForIndex(1), .regs = &.{} },
    };
    const multi_json = try std.json.Stringify.valueAlloc(arena, testManifestMulti(testZeroMemoryManifest(1 << 29), 1 << 29, &vcpus, &redists), .{ .whitespace = .indent_2 });
    _ = try parseManifest(arena, multi_json);

    // Both complete arms under one machine object.
    var two_tags = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    const multi_value = try std.json.parseFromSliceLeaky(std.json.Value, arena, multi_json, .{});
    try two_tags.object.getPtr("machine").?.object.put(arena, "multi", multi_value.object.get("machine").?.object.get("multi").?);

    const malformed = [_][]const u8{
        // Two tags, an unknown tag, a duplicate field, and the removed
        // multi-vCPU schema_version field are all rejected.
        try std.json.Stringify.valueAlloc(arena, two_tags, .{}),
        try std.mem.replaceOwned(u8, arena, json, "\"single\": {", "\"single_v2\": {"),
        try std.mem.replaceOwned(u8, arena, json, "\"single\": {", "\"single\": {\"pc\": 0, "),
        try std.mem.replaceOwned(u8, arena, json, "\"vcpu_count\": 1,", "\"vcpu_count\": 1, \"vcpu_count\": 1,"),
        try std.mem.replaceOwned(u8, arena, multi_json, "\"multi\": {", "\"multi\": {\"schema_version\": 1, "),
    };
    for (malformed) |bytes| {
        try std.testing.expect(!std.mem.eql(u8, bytes, json) and !std.mem.eql(u8, bytes, multi_json));
        try std.testing.expectError(error.BadManifest, parseManifest(arena, bytes));
    }
}

test "manifest save validates the whole manifest" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    var manifest = testForkManifest(testZeroMemoryManifest(1 << 29), 1 << 29, 3);
    manifest.platform.counter_frequency_hz = 0;
    try std.testing.expectError(error.BadManifest, saveManifest(arena, dir, manifest));
    try std.testing.expectError(error.IoFailed, loadManifest(arena, dir));
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{});
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

test "manifest validates and round-trips multi-vCPU topology" {
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
    const manifest = testManifestMulti(testZeroMemoryManifest(1 << 29), 1 << 29, &vcpus, &redists);

    try validateManifest(manifest);
    try saveManifest(arena, dir, manifest);
    const parsed = try loadManifest(arena, dir);
    defer parsed.deinit();
    try std.testing.expectEqual(format_version, parsed.value.version);
    try std.testing.expectEqual(@as(topology.VcpuCount, 2), parsed.value.platform.vcpu_count);
    try std.testing.expectEqual(@as(u64, 0x2_0000), parsed.value.platform.gic_redist_stride);
    const machine = parsed.value.machine.multi;
    try std.testing.expectEqual(@as(aarch64_topology.Mpidr, 0x8000_0001), machine.vcpus[1].mpidr);
    try std.testing.expectEqual(gicv3.StateKind.gicv3_multi, machine.gic.kind);

    var private_manifest = manifest;
    private_manifest.machine.multi.gic = .{
        .kind = .backend_private,
        .backend_private = .{
            .backend = .hvf,
            .format = gicv3.hvf_backend_private_format,
            .data_b64 = "AA==",
        },
    };
    try validateManifest(private_manifest);
}

test "manifest rejects invalid vCPU topology" {
    var redists = [_]gicv3.RedistributorState{
        .{ .mpidr = aarch64_topology.mpidrForIndex(0), .regs = &.{} },
        .{ .mpidr = aarch64_topology.mpidrForIndex(1), .regs = &.{} },
    };

    var count_vcpus = [_]VcpuState{ testVcpuState(0), testVcpuState(1) };
    var manifest = testManifestMulti(testZeroMemoryManifest(1 << 29), 1 << 29, &count_vcpus, &redists);
    manifest.platform.vcpu_count = 3;
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));

    var duplicate_index_vcpus = [_]VcpuState{ testVcpuState(0), testVcpuState(1) };
    manifest = testManifestMulti(testZeroMemoryManifest(1 << 29), 1 << 29, &duplicate_index_vcpus, &redists);
    manifest.machine.multi.vcpus[1].index = 0;
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));

    var duplicate_mpidr_vcpus = [_]VcpuState{ testVcpuState(0), testVcpuState(1) };
    manifest = testManifestMulti(testZeroMemoryManifest(1 << 29), 1 << 29, &duplicate_mpidr_vcpus, &redists);
    manifest.machine.multi.vcpus[1].mpidr = manifest.machine.multi.vcpus[0].mpidr;
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));

    var missing_redist_vcpus = [_]VcpuState{ testVcpuState(0), testVcpuState(1) };
    manifest = testManifestMulti(testZeroMemoryManifest(1 << 29), 1 << 29, &missing_redist_vcpus, redists[0..1]);
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));

    var one_vcpu = [_]VcpuState{testVcpuState(0)};
    manifest = testManifestMulti(testZeroMemoryManifest(1 << 29), 1 << 29, &one_vcpu, redists[0..1]);
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));

    var single = testForkManifest(testZeroMemoryManifest(1 << 29), 1 << 29, 3);
    try validateManifest(single);
    single.platform.vcpu_count = 2;
    try std.testing.expectError(error.BadManifest, validateManifest(single));
    single.platform.vcpu_count = 1;
    single.platform.gic_redist_stride = 0;
    try std.testing.expectError(error.BadManifest, validateManifest(single));
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

test "elastic manifest round trips normalized memory state" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try testDir(arena);
    const initial_size = chunk_size;
    const maximum_size = test_zero_memory_size;
    var devices = [_]TransportState{testTransport(virtio_mem_device_id)};
    const ranges = [_]MemoryPluggedRange{
        .{ .start_block = 0, .block_count = 2 },
        .{ .start_block = 4, .block_count = 1 },
    };
    var manifest = testForkManifest(testZeroMemoryManifest(maximum_size), initial_size, 3);
    manifest.devices = &devices;
    manifest.memory_state = .{
        .initial_size = initial_size,
        .maximum_size = maximum_size,
        .requested_size = maximum_size,
        .captured_size = initial_size + 3 * memory_config.elastic_block_size,
        .plugged_ranges = &ranges,
    };

    try saveManifest(arena, dir, manifest);
    const parsed = try loadManifest(arena, dir);
    defer parsed.deinit();
    try std.testing.expectEqual(initial_size, parsed.value.platform.ram_size);
    try std.testing.expectEqual(maximum_size, parsed.value.memory.logical_size);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.memory_state.?.plugged_ranges.len);
    try std.testing.expectEqual(maximum_size, (try memoryConfig(parsed.value.platform.ram_size, parsed.value.memory_state)).maximum_bytes);

    var fixed = manifest;
    fixed.memory_state = null;
    fixed.devices = &.{};
    fixed.platform.ram_size = maximum_size;
    try validateManifest(fixed);
    try std.testing.expectEqual(maximum_size, (try memoryConfig(fixed.platform.ram_size, fixed.memory_state)).initial_bytes);

    // Elastic memory restore supports one vCPU.
    var vcpus = [_]VcpuState{ testVcpuState(0), testVcpuState(1) };
    const redists = [_]gicv3.RedistributorState{
        .{ .mpidr = aarch64_topology.mpidrForIndex(0), .regs = &.{} },
        .{ .mpidr = aarch64_topology.mpidrForIndex(1), .regs = &.{} },
    };
    var multi = testManifestMulti(manifest.memory, initial_size, &vcpus, &redists);
    multi.devices = manifest.devices;
    multi.memory_state = manifest.memory_state;
    try std.testing.expectError(error.BadManifest, validateManifest(multi));
    multi.devices = &.{};
    multi.memory_state = null;
    multi.platform.ram_size = maximum_size;
    try validateManifest(multi);
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

test "manifest rejects ready virtqueues the device could not have accepted" {
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
    try validateManifest(manifest);

    queues[0].size = 6;
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    queues[0].size = 8;

    queues[0].desc_addr = 0x1008;
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    queues[0].desc_addr = 0x1000;

    queues[0].avail_addr = 0x2001;
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    queues[0].avail_addr = 0x2000;

    queues[0].used_addr = 0x3002;
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
    queues[0].used_addr = 0x3000;

    // A queue that is not ready carries no ring layout yet.
    queues[0].ready = false;
    queues[0].size = 6;
    queues[0].used_addr = 0x3002;
    try validateManifest(manifest);
}

const test_zero_memory_size: usize = 1 << 29;
const test_zero_memory_ranges = [_]disk_index.DiskIndexZeroRange{.{ .start = 0, .count = test_zero_memory_size / chunk_size }};
const test_single_zero_memory_range = [_]disk_index.DiskIndexZeroRange{.{ .start = 0, .count = 1 }};

fn testZeroMemoryManifest(ram_size: u64) MemoryManifest {
    const zero_ranges = if (ram_size == test_zero_memory_size)
        test_zero_memory_ranges[0..]
    else if (ram_size == chunk_size)
        test_single_zero_memory_range[0..]
    else
        &.{};
    return .{
        .logical_size = ram_size,
        .chunk_size = chunk_size,
        .chunks = &.{},
        .zero_ranges = zero_ranges,
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
    try std.testing.expect(try diskQueuesQuiescent(disk.device, parsed.value.devices));

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
    manifest.disk.?.kind = "cow-block-v0";
    try std.testing.expectError(error.BadManifest, validateManifest(manifest));
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
            .vcpu_count = 1,
            .ram_base = 0x8000_0000,
            .ram_size = 1 << 29,
            .gic_dist_base = 0x0800_0000,
            .gic_redist_base = 0x0801_0000,
            .gic_redist_stride = 0x2_0000,
            .counter_frequency_hz = 24_000_000,
        },
        .machine = .{ .single = .{
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
        } },
        .devices = &.{},
        .generation = .{ .generation = 0, .interrupt_status = 0, .params_b64 = "" },
        .memory = testZeroMemoryManifest(1 << 29),
    };
    try saveManifest(arena, dir, manifest);
    const parsed = try loadManifest(arena, dir);
    defer parsed.deinit();
    try std.testing.expectEqual(gicv3.StateKind.backend_private, parsed.value.machine.single.gic.kind);
    try std.testing.expectEqual(gicv3.BackendKind.hvf, parsed.value.machine.single.gic.backend_private.?.backend);
    try std.testing.expectEqualStrings(gicv3.hvf_backend_private_format, parsed.value.machine.single.gic.backend_private.?.format);
}

test "manifest rejects invalid counter frequency" {
    var manifest = Manifest{
        .platform = .{
            .cpu_profile = "sporevm-aarch64-v0",
            .device_model_version = 4,
            .vcpu_count = 1,
            .ram_base = 0x8000_0000,
            .ram_size = 1 << 29,
            .gic_dist_base = 0x0800_0000,
            .gic_redist_base = 0x0801_0000,
            .gic_redist_stride = 0x2_0000,
            .counter_frequency_hz = 0,
        },
        .machine = .{ .single = .{
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
        } },
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
