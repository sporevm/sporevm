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

pub const format_version: u32 = 0;
pub const chunk_size: usize = 2 * 1024 * 1024;

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

pub const MemoryManifest = struct {
    chunk_size: u64,
    /// One entry per chunk; null means all zeroes.
    chunks: []?[]const u8,
};

pub const GenerationState = generation.State;

pub const Manifest = struct {
    version: u32 = format_version,
    platform: Platform,
    machine: MachineState,
    devices: []TransportState,
    generation: GenerationState,
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

// --- save / load -------------------------------------------------------------

/// Write guest memory into the chunk store, returning the memory manifest.
pub fn saveMemory(allocator: std.mem.Allocator, dir: []const u8, ram: []const u8) Error!MemoryManifest {
    const chunks_dir = try pathZ(allocator, "{s}/chunks", .{dir});
    try ensureDir(try pathZ(allocator, "{s}", .{dir}));
    try ensureDir(chunks_dir);

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
    }
    return .{ .chunk_size = chunk_size, .chunks = refs };
}

/// Materialize guest memory from the chunk store. Verifies every chunk
/// against its id; fails closed on mismatch.
pub fn loadMemory(allocator: std.mem.Allocator, dir: []const u8, manifest: MemoryManifest, ram: []u8) Error!void {
    if (manifest.chunk_size == 0 or manifest.chunk_size > 64 * 1024 * 1024) return error.BadManifest;
    const csize: usize = @intCast(manifest.chunk_size);
    const expected = (ram.len + csize - 1) / csize;
    if (manifest.chunks.len != expected) return error.BadManifest;

    for (manifest.chunks, 0..) |maybe_ref, i| {
        const start = i * csize;
        const end = @min(start + csize, ram.len);
        const target = ram[start..end];
        if (maybe_ref) |ref| {
            const id = chunklib.ChunkId.fromHex(ref) catch return error.BadManifest;
            const chunk_path = try pathZ(allocator, "{s}/chunks/{s}", .{ dir, ref });
            const data = try readFileAll(allocator, chunk_path, csize);
            defer allocator.free(data);
            if (data.len != target.len) return error.BadChunk;
            if (!id.matches(data)) return error.BadChunk;
            @memcpy(target, data);
        } else {
            @memset(target, 0);
        }
    }
}

pub fn saveManifest(allocator: std.mem.Allocator, dir: []const u8, manifest: Manifest) Error!void {
    const json = std.json.Stringify.valueAlloc(allocator, manifest, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
    defer allocator.free(json);
    const path = try pathZ(allocator, "{s}/manifest.json", .{dir});
    try writeFileAll(path, json);
}

pub fn loadManifest(allocator: std.mem.Allocator, dir: []const u8) Error!std.json.Parsed(Manifest) {
    const path = try pathZ(allocator, "{s}/manifest.json", .{dir});
    const bytes = try readFileAll(allocator, path, 64 * 1024 * 1024);
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
    try ensureDir(try pathZ(allocator, "{s}", .{options.out_dir}));

    var i: usize = 0;
    while (i < options.count) : (i += 1) {
        const child_dir = try pathZ(allocator, "{s}/{d:0>6}", .{ options.out_dir, i });
        try ensureNewDir(child_dir);
        const chunks_link = try pathZ(allocator, "{s}/chunks", .{child_dir});
        try symlinkPath(shared_chunks, chunks_link);

        var child = parent;
        const child_generation = parent.generation.generation + i + 1;
        const params_b64 = try forkParamsB64(allocator, parent.generation.generation, child_generation, i, options.count);
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

fn forkParamsB64(
    allocator: std.mem.Allocator,
    parent_generation: u64,
    child_generation: u64,
    fork_index: usize,
    fork_count: usize,
) Error![]const u8 {
    const payload = .{
        .schema_version = @as(u32, 0),
        .parent_generation = parent_generation,
        .generation = child_generation,
        .fork_index = fork_index,
        .fork_count = fork_count,
    };
    const json = std.json.Stringify.valueAlloc(allocator, payload, .{}) catch return error.OutOfMemory;
    defer allocator.free(json);
    if (json.len > generation.params_size) return error.BadManifest;

    const enc = std.base64.standard.Encoder;
    const out = allocator.alloc(u8, enc.calcSize(json.len)) catch return error.OutOfMemory;
    _ = enc.encode(out, json);
    return out;
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

    const out = try arena.alloc(u8, ram.len);
    @memset(out, 0xAA);
    try loadMemory(arena, dir, mm, out);
    try std.testing.expectEqualSlices(u8, ram, out);
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
        .memory = .{ .chunk_size = chunk_size, .chunks = &.{} },
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
    const memory = try saveMemory(arena, parent_dir, ram);

    const manifest = Manifest{
        .platform = .{
            .cpu_profile = "sporevm-aarch64-v0",
            .device_model_version = 4,
            .ram_base = 0x8000_0000,
            .ram_size = ram.len,
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
                    .line_levels = &.{.{ .intid = board.generationIntid(), .asserted = false }},
                },
            },
        },
        .devices = &.{},
        .generation = .{ .generation = 41, .interrupt_status = 0, .params_b64 = "" },
        .memory = memory,
    };
    try saveManifest(arena, parent_dir, manifest);

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

    const out = try arena.alloc(u8, ram.len);
    @memset(out, 0);
    try loadMemory(arena, second_child_dir, second.value.memory, out);
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
        .memory = .{ .chunk_size = chunk_size, .chunks = &.{} },
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
