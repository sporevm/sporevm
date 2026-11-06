//! Fork: mint child spores from one saved parent.
//!
//! Children share the parent's memory chunks through links, keep the
//! parent's machine state with the generation interrupt pending, and carry a
//! fresh identity in the generation parameter page. A child keeps the local
//! RAM backing only when the parent's proof validates (see local_backing.zig).

const std = @import("std");
const board = @import("aarch64/board.zig");
const chunklib = @import("chunk.zig");
const generation = @import("generation.zig");
const gicv3 = @import("aarch64/gicv3.zig");
const local_backing = @import("local_backing.zig");
const spore = @import("spore.zig");
const Blake3 = std.crypto.hash.Blake3;

const Error = spore.Error;
const MemoryManifest = spore.MemoryManifest;
const loadManifest = spore.loadManifest;
const prepareForkChildBacking = local_backing.prepareForkChildBacking;
const provenForkBacking = local_backing.provenForkBacking;
const saveManifest = spore.saveManifest;

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

    var child_machine = parent.machine;
    switch (child_machine) {
        .single => |*machine| machine.gic = try forkGicState(allocator, machine.gic),
        .multi => |*machine| machine.gic = try forkGicState(allocator, machine.gic),
    }
    const shared = try prepareForkSharedStores(allocator, options.parent_dir, options.out_dir, parent.memory);
    const ram_size = parent.memory.logical_size;
    const shared_backing = try provenForkBacking(allocator, options.environ_map, options.parent_dir, parent.memory, ram_size);
    defer if (shared_backing) |backing| backing.deinit();
    const fork_batch_id = try randomHex(allocator, 16);

    var i: usize = 0;
    while (i < options.count) : (i += 1) {
        const child_dir = try pathZ(allocator, "{s}/{d:0>6}", .{ options.out_dir, i });
        try ensureNewDir(child_dir);
        try linkForkSharedStores(allocator, child_dir, shared);
        var child = parent;
        try prepareForkChildBacking(allocator, child_dir, &child.memory, ram_size, shared_backing, options.environ_map);

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
        child.machine = child_machine;
        try saveManifest(allocator, child_dir, child);
    }

    return forkResult(allocator, options, parent.generation.generation);
}

const ForkSharedStores = struct {
    chunks: []const u8,
};

fn prepareForkSharedStores(allocator: std.mem.Allocator, parent_dir: []const u8, out_dir: []const u8, memory: MemoryManifest) Error!ForkSharedStores {
    const parent_chunks = try pathZ(allocator, "{s}/chunks", .{parent_dir});
    try ensureDir(try pathZ(allocator, "{s}", .{out_dir}));
    const shared_chunks_path = try pathZ(allocator, "{s}/shared-chunks", .{out_dir});
    try ensureNewDir(shared_chunks_path);
    var seen = std.AutoHashMap(chunklib.ChunkId, void).init(allocator);
    defer seen.deinit();
    for (memory.chunks) |entry| {
        if ((try seen.getOrPut(entry.id)).found_existing) continue;
        const hex = entry.id.toHex();
        const source = try pathZ(allocator, "{s}/{s}", .{ parent_chunks, &hex });
        const dest = try pathZ(allocator, "{s}/{s}", .{ shared_chunks_path, &hex });
        try hardlinkOrCopyPath(source, dest);
    }
    try fsyncDirPath(shared_chunks_path);
    // Child links must survive the API's atomic rename of the hidden batch.
    // A disk-backed child needs no link: the saved-spore fork publishes a pin
    // for each child's disk in the rootfs cache.
    return .{ .chunks = "../shared-chunks" };
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

    const vm_id = std.fmt.allocPrint(allocator, "spore-{x}", .{digest[0..16]}) catch return error.OutOfMemory;
    const hostname = std.fmt.allocPrint(allocator, "spore-{s}-{d:0>6}", .{ fork_batch_id[0..8], fork_index }) catch return error.OutOfMemory;
    const mac_seed = std.fmt.allocPrint(allocator, "{x}", .{digest[16..32]}) catch return error.OutOfMemory;
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
    return std.fmt.allocPrint(allocator, "{x}", .{&bytes}) catch error.OutOfMemory;
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

fn macString(allocator: std.mem.Allocator, mac: [6]u8) Error![]const u8 {
    const hex = std.fmt.allocPrint(allocator, "{x}", .{&mac}) catch return error.OutOfMemory;
    return std.fmt.allocPrint(allocator, "{s}:{s}:{s}:{s}:{s}:{s}", .{
        hex[0..2],
        hex[2..4],
        hex[4..6],
        hex[6..8],
        hex[8..10],
        hex[10..12],
    }) catch return error.OutOfMemory;
}

/// Marks the generation interrupt line asserted so forked children observe
/// their new generation on first entry. Backend-private blobs pass through.
fn forkGicState(allocator: std.mem.Allocator, state: gicv3.State) Error!gicv3.State {
    switch (state.kind) {
        .backend_private => return state,
        .gicv3 => {
            const gic = state.gicv3 orelse return error.BadManifest;
            var next = gic;
            next.line_levels = try assertGenerationLine(gicv3.LineLevel, allocator, gic.line_levels);
            return .{ .kind = .gicv3, .gicv3 = next };
        },
        .gicv3_multi => {
            const gic = state.gicv3_multi orelse return error.BadManifest;
            var next = gic;
            next.line_levels = try assertGenerationLine(gicv3.MultiLineLevel, allocator, gic.line_levels);
            return .{ .kind = .gicv3_multi, .gicv3_multi = next };
        },
    }
}

fn assertGenerationLine(comptime Line: type, allocator: std.mem.Allocator, lines: []const Line) Error![]Line {
    var has_generation_line = false;
    for (lines) |line| {
        if (line.intid == board.generationIntid()) {
            has_generation_line = true;
            break;
        }
    }

    const next = allocator.alloc(Line, lines.len + @intFromBool(!has_generation_line)) catch return error.OutOfMemory;
    for (lines, 0..) |line, i| {
        next[i] = line;
        if (line.intid == board.generationIntid()) next[i].asserted = true;
    }
    if (!has_generation_line) {
        next[lines.len] = .{ .intid = board.generationIntid(), .asserted = true };
    }
    return next;
}

// --- file helpers (libc-based) ----------------------------------------------

fn openDirectoryNoFollow(path: [:0]const u8) Error!std.c.fd_t {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.IoFailed;
    return fd;
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

fn symlinkPath(target: []const u8, link_path: []const u8) Error!void {
    const target_z = try std.heap.c_allocator.dupeSentinel(u8, target, 0);
    defer std.heap.c_allocator.free(target_z);
    const link_z = try std.heap.c_allocator.dupeSentinel(u8, link_path, 0);
    defer std.heap.c_allocator.free(link_z);
    if (std.c.symlink(target_z, link_z) != 0) {
        if (std.c.access(link_z, 0) == 0) return error.AlreadyExists;
        return error.IoFailed;
    }
}

// --- tests ------------------------------------------------------------------

const aarch64_topology = @import("aarch64/topology.zig");
const local_paths = @import("local_paths.zig");
const manifest_test_support = @import("manifest_test_support.zig");
const topology = @import("topology.zig");
const LocalBackingRestoreSource = local_backing.LocalBackingRestoreSource;
const TransportState = spore.TransportState;
const VcpuState = spore.VcpuState;
const chunk_size = spore.chunk_size;
const fstatLocalFile = local_backing.fstatLocalFile;
const loadMemory = spore.loadMemory;
const memoryBackingPath = spore.memoryBackingPath;
const network_kind_spore = spore.network_kind_spore;
const openProvenLocalMemoryBacking = local_backing.openProvenLocalMemoryBacking;
const openReadOnlyNoFollow = local_backing.openReadOnlyNoFollow;
const ram_backing_path = spore.ram_backing_path;
const rootfs_virtio_blk_device_id = spore.rootfs_virtio_blk_device_id;
const saveMemory = spore.saveMemory;
const saveMemoryWithBacking = spore.saveMemoryWithBacking;
const testDisk = manifest_test_support.testDisk;
const testForkManifest = manifest_test_support.testForkManifest;
const testManifestMulti = manifest_test_support.testManifestMulti;
const testRootfs = manifest_test_support.testRootfs;
const testTransport = manifest_test_support.testTransport;
const testVcpuState = manifest_test_support.testVcpuState;
const writeLocalMemoryBackingProof = local_backing.writeLocalMemoryBackingProof;

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

fn testDirFromTemplate(allocator: std.mem.Allocator, template: []const u8) ![:0]const u8 {
    const buf = try allocator.dupeSentinel(u8, template, 0);
    if (mkdtemp(buf) == null) return error.IoFailed;
    return buf;
}

fn testDir(allocator: std.mem.Allocator) ![:0]const u8 {
    return testDirFromTemplate(allocator, "/tmp/sporevm-test-XXXXXX");
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
    try std.testing.expect(first.value.machine.single.gic.gicv3.?.line_levels[0].asserted);
    try std.testing.expect(first.value.rootfs != null);
    try std.testing.expectEqualStrings(parent_manifest.rootfs.?.artifact.digest, first.value.rootfs.?.artifact.digest);
    try std.testing.expect(first.value.disk != null);
    try std.testing.expectEqualStrings(parent_manifest.disk.?.base, first.value.disk.?.base);
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

test "fork mints multi-vCPU child manifests with shared chunks and pending generation" {
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
    var parent_manifest = testManifestMulti(memory, ram.len, &vcpus, &redists);
    var devices = [_]TransportState{
        testTransport(3),
        testTransport(rootfs_virtio_blk_device_id),
    };
    parent_manifest.devices = &devices;
    parent_manifest.rootfs = testRootfs(1);
    parent_manifest.disk = testDisk(1);
    parent_manifest.generation = .{ .generation = 51, .interrupt_status = 0, .params_b64 = "" };
    try saveManifest(arena, parent_dir, parent_manifest);

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
    const first = try loadManifest(arena, first_child_dir);
    defer first.deinit();
    try std.testing.expectEqual(@as(topology.VcpuCount, 2), first.value.platform.vcpu_count);
    try std.testing.expectEqual(@as(u64, 52), first.value.generation.generation);
    try std.testing.expectEqual(@as(u32, generation.irq_generation_changed), first.value.generation.interrupt_status);
    try std.testing.expect(first.value.generation.params_b64.len > 0);
    try std.testing.expectEqual(gicv3.StateKind.gicv3_multi, first.value.machine.multi.gic.kind);
    const first_gic = first.value.machine.multi.gic.gicv3_multi.?;
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
    const second = try loadManifest(arena, second_child_dir);
    defer second.deinit();
    try std.testing.expectEqual(@as(u64, 53), second.value.generation.generation);
}

test "fork preserves backend-private multi-vCPU gic state" {
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
    var manifest = testManifestMulti(memory, ram.len, &vcpus, &redists);
    manifest.machine.multi.gic = .{
        .kind = .backend_private,
        .backend_private = .{
            .backend = .hvf,
            .format = gicv3.hvf_backend_private_format,
            .data_b64 = "AA==",
        },
    };
    const backend_gic = manifest.machine.multi.gic.backend_private.?;
    try saveManifest(arena, parent_dir, manifest);

    const result = try fork(arena, .{
        .parent_dir = parent_dir,
        .out_dir = out_dir,
        .count = 1,
    });
    try std.testing.expectEqual(@as(usize, 1), result.count);

    const child_dir = try pathZ(arena, "{s}/000000", .{out_dir});
    const child = try loadManifest(arena, child_dir);
    defer child.deinit();
    try std.testing.expectEqual(gicv3.StateKind.backend_private, child.value.machine.multi.gic.kind);
    const child_gic = child.value.machine.multi.gic.backend_private.?;
    try std.testing.expectEqual(backend_gic.backend, child_gic.backend);
    try std.testing.expectEqualStrings(backend_gic.format, child_gic.format);
    try std.testing.expectEqualStrings(backend_gic.data_b64, child_gic.data_b64);
    try std.testing.expectEqual(@as(u32, generation.irq_generation_changed), child.value.generation.interrupt_status);
}
