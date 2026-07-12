//! Shared product RAM restore planning.
//!
//! Portable chunks remain authoritative. This module owns selection and
//! lifetime for the optional proof-validated same-host backing acceleration,
//! then hands backends one resolved strategy instead of independent fd/mode
//! knobs.

const std = @import("std");

const local_paths = @import("local_paths.zig");
const spore = @import("spore.zig");
const topology = @import("topology.zig");

pub const Strategy = union(enum) {
    fresh,
    /// Borrowed from an owning Plan and valid for its lifetime.
    local_backing: std.c.fd_t,
    eager_chunks,
    lazy_chunks,
};

pub const Plan = struct {
    strategy: Strategy = .fresh,
    reason: spore.LocalBackingRestoreReason = .not_attempted,

    pub fn fromMemory(
        allocator: std.mem.Allocator,
        environ: *const std.process.Environ.Map,
        dir: []const u8,
        memory: spore.MemoryManifest,
        ram_size: u64,
        vcpu_count: topology.VcpuCount,
    ) !Plan {
        try topology.validateVcpuCount(vcpu_count);
        const local = try spore.openProvenLocalMemoryBacking(allocator, environ, dir, memory, ram_size);
        return fromLocalBacking(local);
    }

    pub fn fromSporeDir(
        allocator: std.mem.Allocator,
        environ: *const std.process.Environ.Map,
        resume_dir: ?[]const u8,
        ram_size: u64,
    ) !Plan {
        const dir = resume_dir orelse return .{};
        var parsed = spore.loadManifest(allocator, dir) catch |err| switch (err) {
            error.BadManifest => null,
            else => |e| return e,
        };
        if (parsed) |*manifest| {
            defer manifest.deinit();
            return fromMemory(allocator, environ, dir, manifest.value.memory, ram_size, 1);
        }
        var manifest = try spore.loadManifestV1(allocator, dir);
        defer manifest.deinit();
        return fromMemory(allocator, environ, dir, manifest.value.memory, ram_size, manifest.value.platform.vcpu_count);
    }

    pub fn restoreSource(self: *const Plan) ?spore.LocalBackingRestoreSource {
        return switch (self.strategy) {
            .fresh => null,
            .local_backing => .local_backing,
            .eager_chunks, .lazy_chunks => .chunks,
        };
    }

    pub fn deinit(self: *Plan) void {
        if (self.strategy == .local_backing) {
            _ = std.c.close(self.strategy.local_backing);
        }
        self.* = .{};
    }

    fn fromLocalBacking(local: spore.LocalBackingPlan) Plan {
        if (local.fd) |fd| {
            std.debug.assert(local.source == .local_backing);
            return .{ .strategy = .{ .local_backing = fd }, .reason = local.reason };
        }
        std.debug.assert(local.source == .chunks);
        return .{ .strategy = .eager_chunks, .reason = local.reason };
    }
};

test "RAM restore plan resolves local and chunk strategies" {
    const fd = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    try std.testing.expect(fd >= 0);
    var local = Plan.fromLocalBacking(.{
        .fd = fd,
        .source = .local_backing,
        .reason = .proof_valid,
    });
    try std.testing.expect(local.strategy == .local_backing);
    try std.testing.expectEqual(spore.LocalBackingRestoreSource.local_backing, local.restoreSource().?);
    try std.testing.expectEqual(spore.LocalBackingRestoreReason.proof_valid, local.reason);
    try std.testing.expect(std.c.fcntl(fd, std.c.F.GETFD, @as(c_int, 0)) >= 0);
    local.deinit();
    try std.testing.expect(local.strategy == .fresh);
    try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(fd, std.c.F.GETFD, @as(c_int, 0)));
    local.deinit();
    try std.testing.expect(local.strategy == .fresh);

    const chunks_plan = Plan.fromLocalBacking(.{
        .source = .chunks,
        .reason = .proof_unavailable,
    });
    try std.testing.expect(chunks_plan.strategy == .eager_chunks);
    try std.testing.expectEqual(spore.LocalBackingRestoreSource.chunks, chunks_plan.restoreSource().?);
    try std.testing.expectEqual(spore.LocalBackingRestoreReason.proof_unavailable, chunks_plan.reason);
}

test "RAM restore plan validates one and multi-vCPU chunk restore" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const memory = spore.MemoryManifest{
        .logical_size = spore.chunk_size,
        .chunk_size = spore.chunk_size,
        .zero_chunks = &.{0},
    };
    const one_vcpu = try Plan.fromMemory(allocator, &env, "/unused", memory, spore.chunk_size, 1);
    try std.testing.expect(one_vcpu.strategy == .eager_chunks);
    try std.testing.expectEqual(spore.LocalBackingRestoreReason.no_backing, one_vcpu.reason);
    const multi_vcpu = try Plan.fromMemory(allocator, &env, "/unused", memory, spore.chunk_size, 2);
    try std.testing.expect(multi_vcpu.strategy == .eager_chunks);
    try std.testing.expectEqual(spore.LocalBackingRestoreReason.no_backing, multi_vcpu.reason);
    try std.testing.expectError(error.UnsupportedVcpuCount, Plan.fromMemory(allocator, &env, "/unused", memory, spore.chunk_size, 0));
    try std.testing.expectError(error.UnsupportedVcpuCount, Plan.fromMemory(allocator, &env, "/unused", memory, spore.chunk_size, topology.max_vcpus + 1));
}

test "RAM restore plan preserves proven backing for one and multi-vCPU restore" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_root = try std.fmt.allocPrintSentinel(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]}, 0);
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_root = std.c.realpath(relative_root, &root_buf) orelse return error.IoFailed;
    const root = try arena.dupe(u8, std.mem.span(resolved_root));
    const dir = try std.fmt.allocPrint(arena, "{s}/spore", .{root});
    const runtime_dir = try std.fmt.allocPrint(arena, "{s}/runtime", .{root});
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.runtime_dir_env, runtime_dir);

    const ram = try arena.alloc(u8, spore.chunk_size);
    @memset(ram, 0x5A);
    const memory = try spore.saveMemoryWithBacking(arena, dir, ram);
    try spore.writeLocalMemoryBackingProof(arena, &env, dir, memory, ram.len);

    var one = try Plan.fromMemory(arena, &env, dir, memory, ram.len, 1);
    try std.testing.expect(one.strategy == .local_backing);
    try std.testing.expectEqual(spore.LocalBackingRestoreReason.proof_valid, one.reason);
    one.deinit();

    var multi = try Plan.fromMemory(arena, &env, dir, memory, ram.len, 2);
    defer multi.deinit();
    try std.testing.expect(multi.strategy == .local_backing);
    try std.testing.expectEqual(spore.LocalBackingRestoreReason.proof_valid, multi.reason);
}
