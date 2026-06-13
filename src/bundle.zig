//! Local spore chunkpack bundles.
//!
//! Bundles are the first distribution shape for spores: a portable manifest
//! plus an index that maps logical BLAKE3 chunks into larger pack blobs. The
//! normal spore manifest remains the machine-state contract; bundle indexes are
//! transport metadata and must be verified before chunks are written back to a
//! CAS directory.

const std = @import("std");
const chunklib = @import("chunk.zig");
const gicv3 = @import("gicv3.zig");
const spore = @import("spore.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

const Error = spore.Error;

pub const index_version: u32 = 0;
pub const index_path = "chunkpack.index.json";
pub const pack_path = "chunkpacks/000000.pack";

pub const PackOptions = struct {
    spore_dir: []const u8,
    out_dir: []const u8,
};

pub const PackResult = struct {
    source: []const u8,
    out_dir: []const u8,
    chunk_count: usize,
    packed_chunk_count: usize,
    pack_count: usize,
    payload_bytes: u64,
};

pub const UnpackOptions = struct {
    bundle_dir: []const u8,
    out_dir: []const u8,
};

pub const UnpackResult = struct {
    bundle: []const u8,
    out_dir: []const u8,
    chunk_count: usize,
    unpacked_chunk_count: usize,
    payload_bytes: u64,
};

pub const IndexChunk = struct {
    id: []const u8,
    pack: []const u8,
    offset: u64,
    size: u64,
    sha256: []const u8,
};

pub const Index = struct {
    version: u32 = index_version,
    chunk_size: u64 = spore.chunk_size,
    chunks: []IndexChunk,
};

pub fn pack(allocator: std.mem.Allocator, options: PackOptions) Error!PackResult {
    const parsed = try spore.loadManifest(allocator, options.spore_dir);
    defer parsed.deinit();
    var manifest = parsed.value;
    manifest.memory.backing = null;
    const plan = try spore.validateMemoryForRam(manifest.memory, @intCast(manifest.platform.ram_size));

    try ensureNewDir(try pathZ(allocator, "{s}", .{options.out_dir}));
    try ensureNewDir(try pathZ(allocator, "{s}/chunkpacks", .{options.out_dir}));

    const bundle_pack_path = try pathZ(allocator, "{s}/{s}", .{ options.out_dir, pack_path });
    const pack_fd = std.c.open(bundle_pack_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
    if (pack_fd < 0) return error.IoFailed;
    defer _ = std.c.close(pack_fd);

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    const entries = allocator.alloc(IndexChunk, plan.nonzero_chunk_count) catch return error.OutOfMemory;
    var entry_count: usize = 0;
    var payload_bytes: u64 = 0;

    var i: usize = 0;
    while (i < plan.chunk_count) : (i += 1) {
        const ref = manifest.memory.chunks[i] orelse continue;
        if (seen.contains(ref)) continue;
        seen.put(ref, {}) catch return error.OutOfMemory;

        const range = chunkRange(plan, @intCast(manifest.platform.ram_size), i) catch return error.BadManifest;
        const expected_size = range.end - range.start;
        const chunk_path = try pathZ(allocator, "{s}/chunks/{s}", .{ options.spore_dir, ref });
        const data = try readFileAll(allocator, chunk_path, expected_size);
        defer allocator.free(data);
        if (data.len != expected_size) return error.BadChunk;
        const id = chunklib.ChunkId.fromHex(ref) catch return error.BadManifest;
        if (!id.matches(data)) return error.BadChunk;
        if (payload_bytes > std.math.maxInt(usize)) return error.BadChunk;
        try pwriteFileAll(pack_fd, @intCast(payload_bytes), data);
        entries[entry_count] = .{
            .id = ref,
            .pack = pack_path,
            .offset = payload_bytes,
            .size = @intCast(data.len),
            .sha256 = try sha256HexAlloc(allocator, data),
        };
        entry_count += 1;
        payload_bytes += @intCast(data.len);
    }

    try spore.saveManifest(allocator, options.out_dir, manifest);
    try saveIndex(allocator, options.out_dir, .{
        .chunk_size = spore.chunk_size,
        .chunks = entries[0..entry_count],
    });

    return .{
        .source = options.spore_dir,
        .out_dir = options.out_dir,
        .chunk_count = plan.chunk_count,
        .packed_chunk_count = entry_count,
        .pack_count = 1,
        .payload_bytes = payload_bytes,
    };
}

pub fn unpack(allocator: std.mem.Allocator, options: UnpackOptions) Error!UnpackResult {
    const parsed_manifest = try spore.loadManifest(allocator, options.bundle_dir);
    defer parsed_manifest.deinit();
    var manifest = parsed_manifest.value;
    manifest.memory.backing = null;
    const plan = try spore.validateMemoryForRam(manifest.memory, @intCast(manifest.platform.ram_size));

    const parsed_index = try loadIndex(allocator, options.bundle_dir);
    defer parsed_index.deinit();
    try validateIndex(allocator, parsed_index.value);

    var by_id = std.StringHashMap(IndexChunk).init(allocator);
    defer by_id.deinit();
    for (parsed_index.value.chunks) |entry| {
        by_id.put(entry.id, entry) catch return error.OutOfMemory;
    }

    try ensureNewDir(try pathZ(allocator, "{s}", .{options.out_dir}));
    try ensureNewDir(try pathZ(allocator, "{s}/chunks", .{options.out_dir}));

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var unpacked_chunk_count: usize = 0;
    var payload_bytes: u64 = 0;

    var i: usize = 0;
    while (i < plan.chunk_count) : (i += 1) {
        const ref = manifest.memory.chunks[i] orelse continue;
        if (seen.contains(ref)) continue;
        seen.put(ref, {}) catch return error.OutOfMemory;
        const entry = by_id.get(ref) orelse return error.BadManifest;
        const range = chunkRange(plan, @intCast(manifest.platform.ram_size), i) catch return error.BadManifest;
        const expected_size = range.end - range.start;
        if (entry.size != @as(u64, @intCast(expected_size))) return error.BadManifest;
        const source_pack_path = try pathZ(allocator, "{s}/{s}", .{ options.bundle_dir, entry.pack });
        const data = try readFileRange(allocator, source_pack_path, entry.offset, entry.size);
        defer allocator.free(data);
        if (!sha256HexMatches(entry.sha256, data)) return error.BadChunk;
        const id = chunklib.ChunkId.fromHex(ref) catch return error.BadManifest;
        if (!id.matches(data)) return error.BadChunk;
        const chunk_path = try pathZ(allocator, "{s}/chunks/{s}", .{ options.out_dir, ref });
        try writeFileAll(chunk_path, data);
        unpacked_chunk_count += 1;
        payload_bytes += @intCast(data.len);
    }

    try spore.saveManifest(allocator, options.out_dir, manifest);

    return .{
        .bundle = options.bundle_dir,
        .out_dir = options.out_dir,
        .chunk_count = plan.chunk_count,
        .unpacked_chunk_count = unpacked_chunk_count,
        .payload_bytes = payload_bytes,
    };
}

fn saveIndex(allocator: std.mem.Allocator, dir: []const u8, index: Index) Error!void {
    const json = std.json.Stringify.valueAlloc(allocator, index, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
    defer allocator.free(json);
    const path = try pathZ(allocator, "{s}/{s}", .{ dir, index_path });
    try writeFileAll(path, json);
}

fn loadIndex(allocator: std.mem.Allocator, dir: []const u8) Error!std.json.Parsed(Index) {
    const path = try pathZ(allocator, "{s}/{s}", .{ dir, index_path });
    const bytes = try readFileAll(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(bytes);
    const parsed = std.json.parseFromSlice(Index, allocator, bytes, .{
        .allocate = .alloc_always,
    }) catch return error.BadManifest;
    errdefer parsed.deinit();
    try validateIndex(allocator, parsed.value);
    return parsed;
}

fn validateIndex(allocator: std.mem.Allocator, index: Index) Error!void {
    if (index.version != index_version) return error.BadManifest;
    if (index.chunk_size != spore.chunk_size) return error.BadManifest;
    var ids = std.StringHashMap(void).init(allocator);
    defer ids.deinit();
    for (index.chunks) |entry| {
        try validateChunk(entry);
        const existing = ids.getOrPut(entry.id) catch return error.OutOfMemory;
        if (existing.found_existing) return error.BadManifest;
    }
}

fn validateChunk(entry: IndexChunk) Error!void {
    _ = chunklib.ChunkId.fromHex(entry.id) catch return error.BadManifest;
    if (!std.mem.eql(u8, entry.pack, pack_path)) return error.BadManifest;
    if (entry.size == 0 or entry.size > spore.chunk_size) return error.BadManifest;
    if (entry.sha256.len != Sha256.digest_length * 2) return error.BadManifest;
    var digest: [Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, entry.sha256) catch return error.BadManifest;
}

fn chunkRange(plan: spore.MemoryPlan, ram_len: usize, index: usize) Error!spore.MemoryChunkRange {
    if (index >= plan.chunk_count) return error.BadManifest;
    const start = index * plan.chunk_size;
    const end = @min(start + plan.chunk_size, ram_len);
    return .{ .start = start, .end = end };
}

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

fn preadFileAll(fd: std.c.fd_t, offset: usize, target: []u8) Error!void {
    var done: usize = 0;
    while (done < target.len) {
        const n = std.c.pread(fd, target.ptr + done, target.len - done, @intCast(offset + done));
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
    const buf = allocator.alloc(u8, size) catch return error.OutOfMemory;
    errdefer allocator.free(buf);
    var done: usize = 0;
    while (done < size) {
        const n = std.c.read(fd, buf.ptr + done, size - done);
        if (n <= 0) return error.IoFailed;
        done += @intCast(n);
    }
    return buf;
}

fn readFileRange(allocator: std.mem.Allocator, path: [:0]const u8, offset: u64, size: u64) Error![]u8 {
    if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) return error.BadChunk;
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);
    const file_size = try seekFileSize(fd);
    const start: usize = @intCast(offset);
    const len: usize = @intCast(size);
    if (start > file_size or len > file_size - start) return error.BadChunk;
    const out = allocator.alloc(u8, len) catch return error.OutOfMemory;
    errdefer allocator.free(out);
    try preadFileAll(fd, start, out);
    return out;
}

fn seekFileSize(fd: std.c.fd_t) Error!usize {
    const cur = std.c.lseek(fd, 0, std.c.SEEK.CUR);
    if (cur < 0) return error.IoFailed;
    const end = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (end < 0) return error.IoFailed;
    if (std.c.lseek(fd, cur, std.c.SEEK.SET) < 0) return error.IoFailed;
    return @intCast(end);
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

fn sha256HexAlloc(allocator: std.mem.Allocator, data: []const u8) Error![]const u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex) catch return error.OutOfMemory;
}

fn sha256HexMatches(hex: []const u8, data: []const u8) bool {
    var expected: [Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, hex) catch return false;
    var actual: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &actual, .{});
    return std.mem.eql(u8, &expected, &actual);
}

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

fn testDir(allocator: std.mem.Allocator) ![]const u8 {
    const tmpl = "/tmp/sporevm-bundle-test-XXXXXX";
    const buf = try allocator.dupeZ(u8, tmpl);
    if (mkdtemp(buf) == null) return error.IoFailed;
    return buf;
}

const test_line_levels = [_]gicv3.LineLevel{.{ .intid = 56, .asserted = false }};

fn testManifest(memory: spore.MemoryManifest, ram_size: u64, initial_generation: u64) spore.Manifest {
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
                    .line_levels = &test_line_levels,
                },
            },
        },
        .devices = &.{},
        .generation = .{ .generation = initial_generation, .interrupt_status = 0, .params_b64 = "" },
        .memory = memory,
    };
}

fn fuzzIndexParse(_: void, s: *std.testing.Smith) !void {
    // Bundle indexes are distribution metadata from disk/peers/registries. They
    // must either fail to parse or validate to canonical, path-safe chunkpack
    // entries.
    var buf: [4096]u8 = undefined;
    const len = s.slice(&buf);
    const parsed = std.json.parseFromSlice(Index, std.testing.allocator, buf[0..len], .{
        .allocate = .alloc_always,
    }) catch return;
    defer parsed.deinit();
    validateIndex(std.testing.allocator, parsed.value) catch return;
}

test "fuzz bundle index parsing" {
    try std.testing.fuzz({}, fuzzIndexParse, .{});
}

test "pack and unpack chunkpack bundle strips local backing" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const out_dir = try pathZ(arena, "{s}/unpacked", .{root_dir});

    const ram = try arena.alloc(u8, 2 * spore.chunk_size + 17);
    @memset(ram, 0);
    ram[9] = 0xA1;
    ram[2 * spore.chunk_size + 3] = 0xB2;
    const memory = try spore.saveMemoryWithBacking(arena, parent_dir, ram);
    try spore.saveManifest(arena, parent_dir, testManifest(memory, ram.len, 7));

    const pack_result = try pack(arena, .{ .spore_dir = parent_dir, .out_dir = bundle_dir });
    try std.testing.expectEqual(@as(usize, 3), pack_result.chunk_count);
    try std.testing.expectEqual(@as(usize, 2), pack_result.packed_chunk_count);
    try std.testing.expectEqual(@as(usize, 1), pack_result.pack_count);
    try std.testing.expectEqual(@as(u64, spore.chunk_size + 17), pack_result.payload_bytes);

    const bundle_manifest = try spore.loadManifest(arena, bundle_dir);
    defer bundle_manifest.deinit();
    try std.testing.expect(bundle_manifest.value.memory.backing == null);
    const backing_path = try pathZ(arena, "{s}/{s}", .{ bundle_dir, spore.ram_backing_path });
    try std.testing.expect(std.c.access(backing_path, 0) != 0);

    const index = try loadIndex(arena, bundle_dir);
    defer index.deinit();
    try std.testing.expectEqual(@as(u32, index_version), index.value.version);
    try std.testing.expectEqual(@as(usize, 2), index.value.chunks.len);
    try std.testing.expectEqualStrings(pack_path, index.value.chunks[0].pack);
    try std.testing.expectEqual(@as(u64, 0), index.value.chunks[0].offset);
    try std.testing.expectEqual(@as(u64, spore.chunk_size), index.value.chunks[0].size);
    try std.testing.expectEqual(@as(u64, spore.chunk_size), index.value.chunks[1].offset);
    try std.testing.expectEqual(@as(u64, 17), index.value.chunks[1].size);

    const unpacked = try unpack(arena, .{ .bundle_dir = bundle_dir, .out_dir = out_dir });
    try std.testing.expectEqual(@as(usize, 3), unpacked.chunk_count);
    try std.testing.expectEqual(@as(usize, 2), unpacked.unpacked_chunk_count);
    try std.testing.expectEqual(@as(u64, spore.chunk_size + 17), unpacked.payload_bytes);

    const restored_manifest = try spore.loadManifest(arena, out_dir);
    defer restored_manifest.deinit();
    try std.testing.expect(restored_manifest.value.memory.backing == null);
    const out = try arena.alloc(u8, ram.len);
    @memset(out, 0xCC);
    try spore.loadMemory(arena, out_dir, restored_manifest.value.memory, out);
    try std.testing.expectEqualSlices(u8, ram, out);
}

test "unpack rejects corrupted chunkpack payload" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root_dir = try testDir(arena);
    const parent_dir = try pathZ(arena, "{s}/parent", .{root_dir});
    const bundle_dir = try pathZ(arena, "{s}/bundle", .{root_dir});
    const out_dir = try pathZ(arena, "{s}/unpacked", .{root_dir});

    const ram = try arena.alloc(u8, spore.chunk_size);
    @memset(ram, 0x5D);
    const memory = try spore.saveMemory(arena, parent_dir, ram);
    try spore.saveManifest(arena, parent_dir, testManifest(memory, ram.len, 3));
    _ = try pack(arena, .{ .spore_dir = parent_dir, .out_dir = bundle_dir });

    const source_pack_path = try pathZ(arena, "{s}/{s}", .{ bundle_dir, pack_path });
    const data = try readFileAll(arena, source_pack_path, spore.chunk_size);
    data[100] ^= 0xFF;
    try writeFileAll(source_pack_path, data);

    try std.testing.expectError(error.BadChunk, unpack(arena, .{ .bundle_dir = bundle_dir, .out_dir = out_dir }));
}

test "bundle index rejects duplicate chunk ids" {
    const id = chunklib.ChunkId.fromContents("duplicate");
    const id_hex = id.toHex();
    const sha_hex = try sha256HexAlloc(std.testing.allocator, "duplicate");
    defer std.testing.allocator.free(sha_hex);
    var chunks = [_]IndexChunk{
        .{ .id = &id_hex, .pack = pack_path, .offset = 0, .size = 9, .sha256 = sha_hex },
        .{ .id = &id_hex, .pack = pack_path, .offset = 9, .size = 9, .sha256 = sha_hex },
    };
    try std.testing.expectError(error.BadManifest, validateIndex(std.testing.allocator, .{
        .chunk_size = spore.chunk_size,
        .chunks = &chunks,
    }));
}
