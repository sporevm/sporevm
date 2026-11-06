//! Same-host RAM backing for local restores and forks.
//!
//! `ram.backing` is an optional sparse copy of guest RAM next to a spore's
//! chunks. Restore and fork map it MAP_PRIVATE only when a v1 proof, MACed
//! with a key under the user's runtime directory, binds it to the memory
//! index and the file's identity. Anything else falls back to the chunks,
//! which stay the portable, verified source of truth.

const std = @import("std");
const builtin = @import("builtin");
const local_paths = @import("local_paths.zig");
const spore = @import("spore.zig");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

const Error = spore.Error;
const MemoryBacking = spore.MemoryBacking;
const MemoryManifest = spore.MemoryManifest;
const memoryBackingPath = spore.memoryBackingPath;
const memoryIndexIdentity = spore.memoryIndexIdentity;
const ram_backing_proof_path = spore.ram_backing_proof_path;
const validateMemoryBacking = spore.validateMemoryBacking;
const validateMemoryForRam = spore.validateMemoryForRam;

const local_backing_proof_version_v1: u32 = 1;
const local_backing_producer = "sporevm-local-ram-backing-v0";
const local_backing_key_path = "local-ram-backing.key";
const local_backing_key_len = HmacSha256.key_length;
const local_backing_proof_max_bytes = 16 * 1024;

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

fn localBackingFileIdentityEqual(a: LocalBackingFileIdentity, b: LocalBackingFileIdentity) bool {
    return std.mem.eql(u8, a.file_type, b.file_type) and
        a.device == b.device and
        a.inode == b.inode and
        a.owner_uid == b.owner_uid and
        a.size == b.size and
        a.mtime_sec == b.mtime_sec and
        a.mtime_nsec == b.mtime_nsec;
}

fn localBackingChunksPlan(reason: LocalBackingRestoreReason) LocalBackingPlan {
    return .{ .source = .chunks, .reason = reason };
}

fn proofMac(
    key: *const [local_backing_key_len]u8,
    memory_fingerprint: []const u8,
    backing: LocalBackingProofBacking,
    file: LocalBackingFileIdentity,
    producer: []const u8,
) [HmacSha256.mac_length]u8 {
    var mac = HmacSha256.init(key);
    mac.update("sporevm-local-ram-backing-proof-v1");
    macU64(&mac, local_backing_proof_version_v1);
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
    return proof.schema_version == local_backing_proof_version_v1 and
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
    try writeLocalMemoryBackingProofForFd(allocator, environ, dir, memory, expected_size, fd, null);
}

fn formatLocalBackingProofWriteOk(buf: []u8, elapsed_us: u64) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "local RAM backing proof metrics: operation=write status=ok elapsed_us={d}",
        .{elapsed_us},
    ) catch "local RAM backing proof metrics: formatting_failed=1";
}

fn formatLocalBackingProofWriteError(buf: []u8, elapsed_us: u64, err: anyerror) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "local RAM backing proof metrics: operation=write status=error elapsed_us={d} error={s}",
        .{ elapsed_us, @errorName(err) },
    ) catch "local RAM backing proof metrics: formatting_failed=1";
}

fn formatLocalBackingProofValidationOk(buf: []u8, opened: LocalBackingOpen, validation_us: u64, precharge_us: u64) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "local RAM backing proof metrics: operation=validate status=ok source={s} reason={s} validation_us={d} precharge_us={d}",
        .{
            @tagName(opened.plan.source),
            @tagName(opened.plan.reason),
            validation_us,
            precharge_us,
        },
    ) catch "local RAM backing proof metrics: formatting_failed=1";
}

fn formatLocalBackingProofValidationError(buf: []u8, validation_us: u64, err: anyerror) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "local RAM backing proof metrics: operation=validate status=error validation_us={d} precharge_us=0 error={s}",
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
    const backing = memory.backing orelse return;
    const start_ns = localBackingMonotonicNs();
    errdefer |err| {
        var metrics_buf: [256]u8 = undefined;
        std.log.debug("{s}", .{formatLocalBackingProofWriteError(&metrics_buf, localBackingElapsedUs(start_ns), err)});
    }
    try validateMemoryBacking(backing, expected_size);
    const file = (try fstatLocalFile(fd)).identity();
    if (file.size != expected_size) return error.BadManifest;
    if (expected_file) |expected| {
        if (!localBackingFileIdentityEqual(file, expected)) return error.IoFailed;
    }
    const key = (try localBackingKey(allocator, environ, true)) orelse return error.IoFailed;
    const memory_fingerprint = try memoryIndexIdentity(allocator, memory, expected_size);
    defer allocator.free(memory_fingerprint);
    const proof_backing = proofBackingFromManifest(backing);
    const mac = proofMac(&key, memory_fingerprint, proof_backing, file, local_backing_producer);
    const mac_hex = std.fmt.allocPrint(allocator, "{x}", .{&mac}) catch return error.OutOfMemory;
    defer allocator.free(mac_hex);
    const proof = LocalBackingProof{
        .schema_version = local_backing_proof_version_v1,
        .memory_fingerprint = memory_fingerprint,
        .backing = proof_backing,
        .file = file,
        .producer = local_backing_producer,
        .mac = mac_hex,
    };
    const json = std.json.Stringify.valueAlloc(allocator, proof, .{
        .whitespace = .indent_2,
    }) catch return error.OutOfMemory;
    defer allocator.free(json);
    const pre_publish_file = (try fstatLocalFile(fd)).identity();
    if (!localBackingFileIdentityEqual(file, pre_publish_file)) return error.IoFailed;
    const proof_path = try pathZ(allocator, "{s}/{s}", .{ dir, ram_backing_proof_path });
    try writeNewFileAll(proof_path, json);
    var metrics_buf: [256]u8 = undefined;
    std.log.debug("{s}", .{formatLocalBackingProofWriteOk(&metrics_buf, localBackingElapsedUs(start_ns))});
}

const LocalBackingOpen = struct {
    plan: LocalBackingPlan,
    file: ?LocalBackingFileIdentity = null,
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
    const expected_mac = proofMac(&key, memory_fingerprint, proof_backing, file, local_backing_producer);
    if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, actual_mac, expected_mac)) return localBackingOpenChunks(.proof_mac_mismatch);
    handoff_fd = true;
    return .{
        .plan = .{ .fd = fd, .source = .local_backing, .reason = .proof_valid },
        .file = file,
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

pub const ProvenForkBacking = struct {
    source_path: [:0]const u8,
    fd: std.c.fd_t,
    file: LocalBackingFileIdentity,

    pub fn deinit(self: ProvenForkBacking) void {
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

pub fn prepareForkChildBacking(
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

pub fn provenForkBacking(
    allocator: std.mem.Allocator,
    maybe_environ: ?*const std.process.Environ.Map,
    parent_dir: []const u8,
    memory: MemoryManifest,
    ram_size: u64,
) Error!?ProvenForkBacking {
    const backing = memory.backing orelse return null;
    const environ = maybe_environ orelse return null;
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

// --- file helpers (libc-based) ----------------------------------------------

fn writeNewFileAll(path: [:0]const u8, data: []const u8) Error!void {
    const fd = try createNewFile(path, 0o644);
    defer _ = std.c.close(fd);
    try writeFdAll(fd, data);
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

pub fn openReadOnlyNoFollow(path: [:0]const u8) Error!std.c.fd_t {
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

pub fn fstatLocalFile(fd: std.c.fd_t) Error!LocalFileStat {
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

fn pathZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Error![:0]const u8 {
    return std.fmt.allocPrintSentinel(allocator, fmt, args, 0) catch error.OutOfMemory;
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

// --- tests ------------------------------------------------------------------

const chunk_sealer = @import("chunk_sealer.zig");
const manifest_test_support = @import("manifest_test_support.zig");
const MemoryChunk = spore.MemoryChunk;
const chunk_size = spore.chunk_size;
const ram_backing_path = spore.ram_backing_path;
const saveMemoryWithBacking = spore.saveMemoryWithBacking;
const testForkManifest = manifest_test_support.testForkManifest;

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
        .symlink => try std.Io.Dir.cwd().symLink(std.testing.io, "missing-target", path, .{}),
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
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = proof_path, .data = "{}" });
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
    try std.Io.Dir.cwd().symLink(std.testing.io, proof_real_path, proof_path, .{});
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

test "local RAM backing proof metric lines are stable" {
    var buf: [320]u8 = undefined;
    try std.testing.expectEqualStrings(
        "local RAM backing proof metrics: operation=write status=ok elapsed_us=41",
        formatLocalBackingProofWriteOk(&buf, 41),
    );
    try std.testing.expectEqualStrings(
        "local RAM backing proof metrics: operation=write status=error elapsed_us=43 error=IoFailed",
        formatLocalBackingProofWriteError(&buf, 43, error.IoFailed),
    );

    const valid = LocalBackingOpen{
        .plan = .{ .source = .local_backing, .reason = .proof_valid },
    };
    try std.testing.expectEqualStrings(
        "local RAM backing proof metrics: operation=validate status=ok source=local_backing reason=proof_valid validation_us=44 precharge_us=5",
        formatLocalBackingProofValidationOk(&buf, valid, 44, 5),
    );
    const fallback = LocalBackingOpen{
        .plan = localBackingChunksPlan(.key_unavailable),
    };
    try std.testing.expectEqualStrings(
        "local RAM backing proof metrics: operation=validate status=ok source=chunks reason=key_unavailable validation_us=45 precharge_us=0",
        formatLocalBackingProofValidationOk(&buf, fallback, 45, 0),
    );
    try std.testing.expectEqualStrings(
        "local RAM backing proof metrics: operation=validate status=error validation_us=46 precharge_us=0 error=IoFailed",
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
    refs[0].id = .{ .bytes = @splat(0xaa) };
    var changed = mm;
    changed.chunks = refs;
    const mismatch_plan = try openProvenLocalMemoryBacking(arena, &env_a, dir, changed, ram.len);
    defer if (mismatch_plan.fd) |fd| {
        _ = std.c.close(fd);
    };
    try std.testing.expectEqual(LocalBackingRestoreSource.chunks, mismatch_plan.source);
    try std.testing.expectEqual(LocalBackingRestoreReason.proof_mismatch, mismatch_plan.reason);
}

test "local memory backing proof written by the removed fs-verity schema falls back to chunks" {
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
    @memset(ram, 0x3C);
    const mm = try saveMemoryWithBacking(arena, dir, ram);
    try writeLocalMemoryBackingProof(arena, &env, dir, mm, ram.len);
    const proof_path = try pathZ(arena, "{s}/{s}", .{ dir, ram_backing_proof_path });
    const v1_proof = try readRegularFileAllNoFollow(arena, proof_path, local_backing_proof_max_bytes);

    // Schema v2 proofs carried a `verity` object next to the MAC.
    const v2_schema = try std.mem.replaceOwned(u8, arena, v1_proof, "\"schema_version\": 1,", "\"schema_version\": 2,");
    try std.testing.expect(!std.mem.eql(u8, v1_proof, v2_schema));
    const v2_proof = try std.mem.replaceOwned(
        u8,
        arena,
        v2_schema,
        "\"mac\":",
        "\"verity\": {\"algorithm\": \"sha256\", \"digest\": \"0000000000000000000000000000000000000000000000000000000000000000\"},\n  \"mac\":",
    );
    try std.testing.expect(!std.mem.eql(u8, v2_schema, v2_proof));

    const cases = [_]struct { bytes: []const u8, reason: LocalBackingRestoreReason }{
        .{ .bytes = v2_proof, .reason = .proof_invalid },
        .{ .bytes = v2_schema, .reason = .proof_mismatch },
    };
    for (cases) |case| {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = proof_path, .data = case.bytes });
        const plan = try openProvenLocalMemoryBacking(arena, &env, dir, mm, ram.len);
        defer if (plan.fd) |fd| {
            _ = std.c.close(fd);
        };
        try std.testing.expectEqual(LocalBackingRestoreSource.chunks, plan.source);
        try std.testing.expect(plan.fd == null);
        try std.testing.expectEqual(case.reason, plan.reason);
    }
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
    try std.Io.Dir.cwd().createDirPath(std.testing.io, child_dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = bad_runtime_dir, .data = "not a directory" });
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
    const shared_backing = (try provenForkBacking(arena, &env, parent_dir, memory, ram.len)) orelse return error.TestUnexpectedResult;
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
    try std.Io.Dir.cwd().createDirPath(std.testing.io, child_dir);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.runtime_dir_env, runtime_dir);

    const ram = try arena.alloc(u8, chunk_size);
    @memset(ram, 0x41);
    const memory = try saveMemoryWithBacking(arena, parent_dir, ram);
    try writeLocalMemoryBackingProof(arena, &env, parent_dir, memory, ram.len);
    const source = (try provenForkBacking(arena, &env, parent_dir, memory, ram.len)) orelse return error.TestUnexpectedResult;
    defer source.deinit();

    if (std.c.unlink(source.source_path.ptr) != 0) return error.IoFailed;
    const replacement_fd = try createNewFile(source.source_path, 0o600);
    if (std.c.ftruncate(replacement_fd, @intCast(ram.len)) != 0) {
        _ = std.c.close(replacement_fd);
        return error.IoFailed;
    }
    try chunk_sealer.pwriteFileAll(replacement_fd, 0, &.{0x42});
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
    const source = (try provenForkBacking(arena, &env, parent_dir, memory, ram.len)) orelse return error.TestUnexpectedResult;
    defer source.deinit();

    if (try testLinuxPathDevice(source.source_path) == try testLinuxPathDevice(child_dir)) return error.SkipZigTest;

    var child = testForkManifest(memory, ram.len, 13);
    try prepareForkChildBacking(arena, child_dir, &child.memory, child.platform.ram_size, source, &env);
    try std.testing.expect(child.memory.backing == null);
    try std.testing.expectEqual(@as(c_int, -1), std.c.access(try pathZ(arena, "{s}/{s}", .{ child_dir, ram_backing_path }), 0));
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
