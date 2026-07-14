const std = @import("std");
const Io = std.Io;

const build_context = @import("context.zig");
const build_context_disk = @import("context_disk.zig");
const build_exec = @import("exec.zig");
const step_cache = @import("step_cache.zig");
const rootfs_mod = @import("../rootfs.zig");
const rootfs_cas = @import("../rootfs_cas.zig");
const spore = @import("../spore.zig");

pub const InstructionTransition = union(enum) {
    run: build_exec.RunStep,
    copy: Copy,
    workdir: build_exec.WorkdirStep,

    pub const Copy = union(enum) {
        context: ContextCopy,
        build_input: build_exec.CopyStep,
    };

    pub const ContextCopy = struct {
        line: usize,
        canonical_instruction: []const u8,
        resolved_sources: []const []const u8,
        resolved_dest: []const u8,
        env_digest: []const u8,
        workdir: []const u8,
    };
};

pub const CacheWalkResult = union(enum) {
    complete: spore.RootfsStorage,
    miss: Miss,

    pub const Miss = struct {
        transition_index: usize,
        storage: spore.RootfsStorage,
    };
};

pub const LoweredSuffix = struct {
    steps: []const build_exec.Step,
    context_disk_path: ?[]const u8,
};

pub const Diagnostics = struct {
    context_hash: *build_context.HashDiagnostic,
    context_disk: *build_context_disk.Diagnostic,
    instruction_line: *usize,
    copy: *build_context.CopyDiagnostic,
    limit: *u64,
    actual: *u64,
};

pub fn walkCache(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    platform: rootfs_mod.Platform,
    executor_identity: []const u8,
    resources: build_exec.RunResources,
    no_cache: bool,
    ctx: build_context.BuildContext,
    stat_cache: *build_context.StatCache,
    diagnostic: *Diagnostics,
    initial_storage: spore.RootfsStorage,
    transitions: []const InstructionTransition,
) !CacheWalkResult {
    var storage = initial_storage;
    for (transitions, 0..) |transition, index| {
        if (no_cache) return .{ .miss = .{ .transition_index = index, .storage = storage } };
        const step = try cacheStep(io, allocator, ctx, stat_cache, diagnostic, transition);
        const input = build_exec.cacheInputForStep(platform, storage.index_digest, executor_identity, step, resources);
        const key = try step_cache.stepKey(allocator, input);
        storage = (try step_cache.readHit(io, allocator, cache_root, input, key)) orelse
            return .{ .miss = .{ .transition_index = index, .storage = storage } };
    }
    return .{ .complete = storage };
}

pub fn lowerMissSuffix(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    ctx: build_context.BuildContext,
    stat_cache: ?*build_context.StatCache,
    diagnostic: *Diagnostics,
    transitions: []const InstructionTransition,
) !LoweredSuffix {
    var steps = std.array_list.Managed(build_exec.Step).init(allocator);
    var context_disk = build_context_disk.Builder.init(allocator);
    var context_snapshot: ?build_context.CopySnapshot = null;
    defer if (context_snapshot) |*snapshot| snapshot.deinit(io);

    for (transitions) |transition| switch (transition) {
        .run => |step| try steps.append(.{ .run = step }),
        .workdir => |step| try steps.append(.{ .workdir = step }),
        .copy => |copy| switch (copy) {
            .build_input => |step| try steps.append(.{ .copy = step }),
            .context => |context| {
                if (context_snapshot == null) context_snapshot = try build_context.CopySnapshot.init(allocator, io, cache_root);
                const snapshot = if (context_snapshot) |*value| value else unreachable;
                try steps.append(.{ .copy = try lowerContextCopy(
                    io,
                    allocator,
                    ctx,
                    stat_cache,
                    snapshot,
                    &context_disk,
                    diagnostic,
                    context,
                ) });
            },
        },
    };

    if (context_snapshot) |*snapshot| try snapshot.seal(io);
    const context_disk_path = try context_disk.emitOrReuse(io, cache_root, diagnostic.context_disk);
    if (context_snapshot) |*snapshot| snapshot.deinit(io);
    context_snapshot = null;
    return .{ .steps = try steps.toOwnedSlice(), .context_disk_path = context_disk_path };
}

pub fn lowerContextCopy(
    io: Io,
    allocator: std.mem.Allocator,
    ctx: build_context.BuildContext,
    stat_cache: ?*build_context.StatCache,
    context_snapshot: *build_context.CopySnapshot,
    context_disk: *build_context_disk.Builder,
    diagnostic: *Diagnostics,
    context: InstructionTransition.ContextCopy,
) !build_exec.CopyStep {
    const resolution = build_context.resolveCopySourcesWithDiagnostic(allocator, io, ctx, context.resolved_sources, diagnostic.copy) catch |err| {
        diagnostic.instruction_line.* = context.line;
        return err;
    };
    const captured = try build_context.captureCopyResolutionWithOptions(allocator, io, ctx, resolution, .{
        .stat_cache = stat_cache,
        .diagnostic = diagnostic.context_hash,
    }, context_snapshot);
    const input_digest = try build_context.hashResolvedCopyEntries(allocator, captured);
    const source_prefix = try context_disk.addCapturedCopy(captured);
    const dest_is_dir = copyDestIsDirectory(context.resolved_dest, resolution);
    if (resolution.roots.len > 1 and !copyDestEndsWithSlash(context.resolved_dest)) {
        diagnostic.instruction_line.* = context.line;
        return error.CopyDestinationMustBeDirectory;
    }
    const dest = try normalizeGuestPath(allocator, context.workdir, context.resolved_dest);
    const requests = try copyRequests(allocator, diagnostic, context.line, resolution, source_prefix, dest, dest_is_dir);
    return .{
        .line = context.line,
        .canonical_instruction = context.canonical_instruction,
        .input_digest = input_digest,
        .env_digest = context.env_digest,
        .workdir = context.workdir,
        .requests = requests,
    };
}

pub fn buildInputCopy(
    allocator: std.mem.Allocator,
    line: usize,
    canonical_instruction: []const u8,
    resolved_sources: []const []const u8,
    resolved_dest: []const u8,
    env_digest: []const u8,
    workdir: []const u8,
    input_index: usize,
    storage: spore.RootfsStorage,
) !InstructionTransition {
    if (resolved_sources.len > 1 and !copyDestEndsWithSlash(resolved_dest)) return error.CopyDestinationMustBeDirectory;
    const dest = try normalizeGuestPath(allocator, workdir, resolved_dest);
    const requests = try allocator.alloc(build_exec.CopyRequest, resolved_sources.len);
    for (resolved_sources, 0..) |source, index| {
        requests[index] = .{
            .source = try normalizeBuildInputCopySource(allocator, source),
            .dest = dest,
            .source_kind = .auto,
            .dest_is_dir = copyDestEndsWithSlash(resolved_dest) or resolved_sources.len > 1,
            .entry_count = 0,
            .source_disk = .build_input,
            .input_index = input_index,
        };
    }
    return .{ .copy = .{ .build_input = .{
        .line = line,
        .canonical_instruction = canonical_instruction,
        .input_digest = storage.index_digest,
        .env_digest = env_digest,
        .workdir = workdir,
        .requests = requests,
    } } };
}

fn cacheStep(
    io: Io,
    allocator: std.mem.Allocator,
    ctx: build_context.BuildContext,
    stat_cache: *build_context.StatCache,
    diagnostic: *Diagnostics,
    transition: InstructionTransition,
) !build_exec.Step {
    return switch (transition) {
        .run => |step| .{ .run = step },
        .workdir => |step| .{ .workdir = step },
        .copy => |copy| switch (copy) {
            .build_input => |step| .{ .copy = step },
            .context => |context| blk: {
                const resolution = build_context.resolveCopySourcesWithDiagnostic(allocator, io, ctx, context.resolved_sources, diagnostic.copy) catch |err| {
                    diagnostic.instruction_line.* = context.line;
                    return err;
                };
                break :blk .{ .copy = .{
                    .line = context.line,
                    .canonical_instruction = context.canonical_instruction,
                    .input_digest = try build_context.hashCopyResolutionWithOptions(allocator, io, ctx, resolution, .{
                        .stat_cache = stat_cache,
                        .diagnostic = diagnostic.context_hash,
                    }),
                    .env_digest = context.env_digest,
                    .workdir = context.workdir,
                    .requests = &.{},
                } };
            },
        },
    };
}

fn normalizeBuildInputCopySource(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    if (source.len == 0) return error.CopySourceNotFound;
    if (std.mem.indexOfAny(u8, source, "*?[") != null) return error.UnsupportedCopyFromPattern;
    var parts = std.array_list.Managed([]const u8).init(allocator);
    var it = std.mem.splitScalar(u8, source, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.CopySourceEscapesContext;
        try parts.append(part);
    }
    if (parts.items.len == 0) return allocator.dupe(u8, ".");
    return std.mem.join(allocator, "/", parts.items);
}

fn copyDestIsDirectory(dest: []const u8, resolution: build_context.CopyResolution) bool {
    if (copyDestEndsWithSlash(dest)) return true;
    if (resolution.roots.len != 1) return false;
    return resolution.roots[0].kind == .directory;
}

fn copyDestEndsWithSlash(dest: []const u8) bool {
    return dest.len != 0 and dest[dest.len - 1] == '/';
}

fn copyRequests(
    allocator: std.mem.Allocator,
    diagnostic: *Diagnostics,
    instruction_line: usize,
    resolution: build_context.CopyResolution,
    source_prefix: []const u8,
    dest: []const u8,
    dest_is_dir: bool,
) ![]const build_exec.CopyRequest {
    if (resolution.roots.len == 0) return error.CopySourceNotFound;
    var out = std.array_list.Managed(build_exec.CopyRequest).init(allocator);
    for (resolution.roots) |root| {
        const entry_count = copyRootEntryCount(resolution, root);
        if (entry_count == 0) return error.CopySourceNotFound;
        if (entry_count > build_exec.max_copy_entries) {
            diagnostic.instruction_line.* = instruction_line;
            diagnostic.copy.source = root.rel;
            diagnostic.limit.* = build_exec.max_copy_entries;
            diagnostic.actual.* = entry_count;
            return error.CopyEntryCountUnsupported;
        }
        const source = if (std.mem.eql(u8, root.rel, "."))
            source_prefix
        else
            try std.fs.path.join(allocator, &.{ source_prefix, root.rel });
        try out.append(.{
            .source = source,
            .dest = dest,
            .source_kind = try copySourceKind(root.kind),
            .dest_is_dir = dest_is_dir,
            .entry_count = entry_count,
        });
    }
    return out.toOwnedSlice();
}

fn copyRootEntryCount(resolution: build_context.CopyResolution, root: build_context.CopyRoot) usize {
    if (std.mem.eql(u8, root.rel, ".")) return resolution.entries.len;
    var count: usize = 0;
    for (resolution.entries) |entry| {
        if (std.mem.eql(u8, entry.rel, root.rel) or
            (entry.rel.len > root.rel.len and std.mem.startsWith(u8, entry.rel, root.rel) and entry.rel[root.rel.len] == '/'))
        {
            count += 1;
        }
    }
    return count;
}

fn copySourceKind(kind: Io.File.Kind) !build_exec.CopySourceKind {
    return switch (kind) {
        .file => .file,
        .directory => .directory,
        .sym_link => .sym_link,
        else => error.UnsupportedCopySourceType,
    };
}

pub fn normalizeGuestPath(allocator: std.mem.Allocator, workdir: []const u8, raw: []const u8) ![]const u8 {
    var parts = std.array_list.Managed([]const u8).init(allocator);
    if (!std.fs.path.isAbsolute(raw)) try appendGuestPathParts(&parts, workdir);
    try appendGuestPathParts(&parts, raw);
    return guestPathFromParts(allocator, parts.items);
}

fn appendGuestPathParts(parts: *std.array_list.Managed([]const u8), path: []const u8) !void {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.CopyDestinationUnsupported;
        try parts.append(part);
    }
}

fn guestPathFromParts(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    if (parts.len == 0) return allocator.dupe(u8, "/");
    var out = std.array_list.Managed(u8).init(allocator);
    for (parts) |part| {
        try out.append('/');
        try out.appendSlice(part);
    }
    return out.toOwnedSlice();
}

test "cache walk advances the parent and reports only the miss suffix" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-build-instruction-transition";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp ++ "/base.ext4", .data = "base" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp ++ "/first.ext4", .data = "first" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp ++ "/second.ext4", .data = "second" });
    const base = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, try rootfs_cas.preloadPath(io, arena, cache_root, tmp ++ "/base.ext4", rootfs_cas.default_chunk_size));
    const first = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, try rootfs_cas.preloadPath(io, arena, cache_root, tmp ++ "/first.ext4", rootfs_cas.default_chunk_size));
    const second = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, try rootfs_cas.preloadPath(io, arena, cache_root, tmp ++ "/second.ext4", rootfs_cas.default_chunk_size));
    const executor_identity = "blake3:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    const resources = build_exec.RunResources{};
    const transitions = [_]InstructionTransition{
        .{ .run = .{
            .line = 1,
            .canonical_instruction = "RUN true",
            .command = .{ .shell = "true" },
            .env = &.{},
            .env_digest = "",
            .workdir = "/",
            .network_mode = .spore,
        } },
        .{ .workdir = .{
            .line = 2,
            .canonical_instruction = "WORKDIR /app",
            .target = "/app",
            .env_digest = "",
            .workdir = "/",
        } },
    };
    const first_input = build_exec.cacheInputForStep(.{}, base.index_digest, executor_identity, .{ .run = transitions[0].run }, resources);
    const first_key = try step_cache.stepKey(arena, first_input);
    _ = try step_cache.writeRecord(io, arena, cache_root, first_input, first_key, first);

    var context_hash: build_context.HashDiagnostic = .{};
    var context_disk: build_context_disk.Diagnostic = .{};
    var instruction_line: usize = 0;
    var copy: build_context.CopyDiagnostic = .{};
    var limit: u64 = 0;
    var actual: u64 = 0;
    var diagnostic = Diagnostics{
        .context_hash = &context_hash,
        .context_disk = &context_disk,
        .instruction_line = &instruction_line,
        .copy = &copy,
        .limit = &limit,
        .actual = &actual,
    };
    const ctx = build_context.BuildContext{ .root = tmp, .absolute_root = tmp };
    var stat_cache = build_context.StatCache.load(arena, io, cache_root, &context_hash);
    switch (try walkCache(io, arena, cache_root, .{}, executor_identity, resources, false, ctx, &stat_cache, &diagnostic, base, &transitions)) {
        .miss => |miss| {
            try std.testing.expectEqual(@as(usize, 1), miss.transition_index);
            try std.testing.expectEqualStrings(first.index_digest, miss.storage.index_digest);
        },
        .complete => return error.ExpectedBuildCacheMiss,
    }

    const second_input = build_exec.cacheInputForStep(.{}, first.index_digest, executor_identity, .{ .workdir = transitions[1].workdir }, resources);
    const second_key = try step_cache.stepKey(arena, second_input);
    _ = try step_cache.writeRecord(io, arena, cache_root, second_input, second_key, second);
    switch (try walkCache(io, arena, cache_root, .{}, executor_identity, resources, false, ctx, &stat_cache, &diagnostic, base, &transitions)) {
        .complete => |storage| try std.testing.expectEqualStrings(second.index_digest, storage.index_digest),
        .miss => return error.UnexpectedBuildCacheMiss,
    }
}
