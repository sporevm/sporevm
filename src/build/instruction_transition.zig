const std = @import("std");
const Io = std.Io;

const build_context = @import("context.zig");
const build_context_disk = @import("context_disk.zig");
const build_exec = @import("exec.zig");
const remote_add = @import("remote_add.zig");
const step_cache = @import("step_cache.zig");
const rootfs_mod = @import("../rootfs.zig");
const rootfs_cas = @import("../rootfs_cas.zig");
const spore = @import("../spore.zig");

const preflight_context_source_prefix = std.fmt.comptimePrint("s{d}", .{std.math.maxInt(usize)});

pub const InstructionTransition = union(enum) {
    run: build_exec.RunStep,
    copy: Copy,
    add: remote_add.Prepared,
    workdir: build_exec.WorkdirStep,

    pub const Copy = union(enum) {
        context: ContextCopy,
        heredoc: HeredocCopy,
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

    pub const HeredocCopy = struct {
        line: usize,
        canonical_instruction: []const u8,
        source_name: []const u8,
        resolved_body: []const u8,
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
        .add => |add| try steps.append(.{ .copy = try lowerRemoteAdd(allocator, &context_disk, add) }),
        .copy => |copy| switch (copy) {
            .build_input => |step| try steps.append(.{ .copy = step }),
            .heredoc => |heredoc| try steps.append(.{ .copy = try lowerHeredocCopy(allocator, &context_disk, heredoc) }),
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

fn lowerRemoteAdd(
    allocator: std.mem.Allocator,
    context_disk: *build_context_disk.Builder,
    add: remote_add.Prepared,
) !build_exec.CopyStep {
    const source_prefix = try context_disk.addCapturedCopy(&.{.{
        .rel = add.staged.source_name,
        .kind = .file,
        .mode = add.input.mode,
        .size = add.staged.size,
        .content_digest = add.staged.content_digest,
        .snapshot_path = add.staged.path,
    }});
    const source = try std.fs.path.join(allocator, &.{ source_prefix, add.staged.source_name });
    const input_digest = try remoteAddInputDigest(allocator, add);
    const requests = try allocator.alloc(build_exec.CopyRequest, 1);
    requests[0] = try remoteAddCopyRequest(allocator, add, source);
    return .{
        .instruction_kind = .add,
        .line = add.input.line,
        .canonical_instruction = add.input.canonical_instruction,
        .input_digest = input_digest,
        .env_digest = add.input.env_digest,
        .workdir = add.input.workdir,
        .requests = requests,
    };
}

fn lowerHeredocCopy(
    allocator: std.mem.Allocator,
    context_disk: *build_context_disk.Builder,
    heredoc: InstructionTransition.HeredocCopy,
) !build_exec.CopyStep {
    const entry = try heredocCopyEntry(allocator, heredoc);
    const source_prefix = try context_disk.addCapturedCopy(&.{entry});
    const request = try heredocCopyRequest(allocator, heredoc, source_prefix);
    return .{
        .line = heredoc.line,
        .canonical_instruction = heredoc.canonical_instruction,
        .input_digest = try build_context.hashResolvedCopyEntries(allocator, &.{entry}),
        .env_digest = heredoc.env_digest,
        .workdir = heredoc.workdir,
        .requests = try allocator.dupe(build_exec.CopyRequest, &.{request}),
    };
}

pub fn preflightHeredocCopy(allocator: std.mem.Allocator, heredoc: InstructionTransition.HeredocCopy) !void {
    _ = try heredocCopyRequest(allocator, heredoc, "spore-copy-heredoc-prefix-00000000");
}

fn heredocCopyRequest(
    allocator: std.mem.Allocator,
    heredoc: InstructionTransition.HeredocCopy,
    source_prefix: []const u8,
) !build_exec.CopyRequest {
    const source = try std.fs.path.join(allocator, &.{ source_prefix, heredoc.source_name });
    const request = build_exec.CopyRequest{
        .source = source,
        .dest = try normalizeGuestPath(allocator, heredoc.workdir, heredoc.resolved_dest),
        .source_kind = .file,
        .dest_is_dir = copyDestEndsWithSlash(heredoc.resolved_dest),
        .entry_count = 1,
    };
    try build_exec.validateCopyRequest(request);
    try build_exec.validateCopyDestinationJoin(request);
    return request;
}

fn heredocCopyEntry(allocator: std.mem.Allocator, heredoc: InstructionTransition.HeredocCopy) !build_context.CopyResolvedEntry {
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update(heredoc.resolved_body);
    var raw: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
    hash.final(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    return .{
        .rel = heredoc.source_name,
        .kind = .file,
        .mode = 0o644,
        .size = heredoc.resolved_body.len,
        .content_digest = try std.fmt.allocPrint(allocator, "blake3:{s}", .{&hex}),
        .inline_data = heredoc.resolved_body,
    };
}

pub fn preflightRemoteAdd(allocator: std.mem.Allocator, add: remote_add.Prepared) !void {
    const conservative_prefix = "spore-remote-add-prefix-00000000";
    const source = try std.fs.path.join(allocator, &.{ conservative_prefix, add.staged.source_name });
    _ = try remoteAddCopyRequest(allocator, add, source);
}

fn remoteAddCopyRequest(
    allocator: std.mem.Allocator,
    add: remote_add.Prepared,
    source: []const u8,
) !build_exec.CopyRequest {
    const request = build_exec.CopyRequest{
        .source = source,
        .dest = try normalizeGuestPath(allocator, add.input.workdir, add.input.resolved_dest),
        .source_kind = .file,
        .dest_is_dir = copyDestEndsWithSlash(add.input.resolved_dest),
        .entry_count = 1,
        .mtime_unix_seconds = add.staged.mtime_unix_seconds orelse 0,
    };
    try build_exec.validateCopyRequest(request);
    try build_exec.validateCopyDestinationJoin(request);
    return request;
}

fn remoteAddInputDigest(
    allocator: std.mem.Allocator,
    add: remote_add.Prepared,
) ![]const u8 {
    var hash = std.crypto.hash.Blake3.init(.{});
    hashField(&hash, "spore-build-remote-add-v1");
    hashField(&hash, add.input.resolved_url);
    hashField(&hash, add.input.resolved_dest);
    hashField(&hash, add.staged.source_name);
    hashField(&hash, add.staged.content_digest);
    if (add.staged.mtime_unix_seconds) |mtime| {
        hash.update("\x01");
        var mtime_bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &mtime_bytes, mtime, .little);
        hash.update(&mtime_bytes);
    } else {
        hash.update("\x00");
    }
    var mode: [4]u8 = undefined;
    std.mem.writeInt(u32, &mode, add.input.mode, .little);
    hashField(&hash, &mode);
    var raw: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
    hash.final(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    return std.fmt.allocPrint(allocator, "blake3:{s}", .{&hex});
}

fn hashField(hash: *std.crypto.hash.Blake3, value: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, value.len, .little);
    hash.update(&len);
    hash.update(value);
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
    const requests = try validatedContextCopyRequests(
        allocator,
        diagnostic,
        context.line,
        resolution,
        source_prefix,
        context.resolved_dest,
        context.workdir,
    );
    return .{
        .line = context.line,
        .canonical_instruction = context.canonical_instruction,
        .input_digest = input_digest,
        .env_digest = context.env_digest,
        .workdir = context.workdir,
        .requests = requests,
    };
}

pub fn preflightContextCopy(
    io: Io,
    allocator: std.mem.Allocator,
    ctx: build_context.BuildContext,
    diagnostic: *Diagnostics,
    line: usize,
    resolved_sources: []const []const u8,
    resolved_dest: []const u8,
    workdir: []const u8,
) !void {
    const resolution = build_context.resolveCopySourcesWithDiagnostic(allocator, io, ctx, resolved_sources, diagnostic.copy) catch |err| {
        diagnostic.instruction_line.* = line;
        if (err == error.FileNotFound) {
            if (resolved_sources.len != 0) diagnostic.copy.source = resolved_sources[0];
            return error.CopySourceNotFound;
        }
        return err;
    };
    _ = try validatedContextCopyRequests(
        allocator,
        diagnostic,
        line,
        resolution,
        preflight_context_source_prefix,
        resolved_dest,
        workdir,
    );
}

fn validatedContextCopyRequests(
    allocator: std.mem.Allocator,
    diagnostic: *Diagnostics,
    line: usize,
    resolution: build_context.CopyResolution,
    source_prefix: []const u8,
    resolved_dest: []const u8,
    workdir: []const u8,
) ![]const build_exec.CopyRequest {
    if (resolution.roots.len > 1 and !copyDestEndsWithSlash(resolved_dest)) {
        diagnostic.instruction_line.* = line;
        return error.CopyDestinationMustBeDirectory;
    }
    for (resolution.entries) |entry| _ = copySourceKind(entry.kind) catch |err| {
        diagnostic.instruction_line.* = line;
        return err;
    };
    const dest = normalizeGuestPath(allocator, workdir, resolved_dest) catch |err| {
        diagnostic.instruction_line.* = line;
        return err;
    };
    return copyRequests(
        allocator,
        diagnostic,
        line,
        resolution,
        source_prefix,
        dest,
        copyDestIsDirectory(resolved_dest, resolution),
    );
}

pub fn buildInputCopy(
    allocator: std.mem.Allocator,
    line: usize,
    canonical_instruction: []const u8,
    resolved_sources: []const []const u8,
    resolved_dest: []const u8,
    env_digest: []const u8,
    workdir: []const u8,
    link: bool,
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
            .destination_policy = if (link) .link else .follow,
        };
        try build_exec.validateCopyRequest(requests[index]);
    }
    return .{ .copy = .{ .build_input = .{
        .line = line,
        .canonical_instruction = canonical_instruction,
        .input_digest = storage.index_digest,
        .env_digest = env_digest,
        .workdir = workdir,
        .destination_policy = if (link) .link else .follow,
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
        .add => |add| .{ .copy = try lowerRemoteAddForCache(allocator, add) },
        .copy => |copy| switch (copy) {
            .build_input => |step| .{ .copy = step },
            .heredoc => |heredoc| .{ .copy = .{
                .line = heredoc.line,
                .canonical_instruction = heredoc.canonical_instruction,
                .input_digest = try build_context.hashResolvedCopyEntries(allocator, &.{try heredocCopyEntry(allocator, heredoc)}),
                .env_digest = heredoc.env_digest,
                .workdir = heredoc.workdir,
                .requests = &.{},
            } },
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

fn lowerRemoteAddForCache(allocator: std.mem.Allocator, add: remote_add.Prepared) !build_exec.CopyStep {
    return .{
        .instruction_kind = .add,
        .line = add.input.line,
        .canonical_instruction = add.input.canonical_instruction,
        .input_digest = try remoteAddInputDigest(allocator, add),
        .env_digest = add.input.env_digest,
        .workdir = add.input.workdir,
        .requests = &.{},
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

test "COPY heredoc lowering keys resolved bytes and reuses ordinary file destination semantics" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = InstructionTransition.HeredocCopy{
        .line = 2,
        .canonical_instruction = "COPY <<EOF /out/\nvalue\nEOF",
        .source_name = "EOF",
        .resolved_body = "value\n",
        .resolved_dest = "/out/",
        .env_digest = "blake3:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        .workdir = "/",
    };
    var disk = build_context_disk.Builder.init(arena);
    const lowered = try lowerHeredocCopy(arena, &disk, base);
    try std.testing.expectEqual(@as(usize, 1), lowered.requests.len);
    try std.testing.expectEqualStrings("/out", lowered.requests[0].dest);
    try std.testing.expect(lowered.requests[0].dest_is_dir);
    try std.testing.expect(std.mem.endsWith(u8, lowered.requests[0].source, "/EOF"));
    try std.testing.expectEqual(@as(build_exec.CopySourceKind, .file), lowered.requests[0].source_kind);

    var changed = base;
    changed.resolved_body = "changed\n";
    var changed_disk = build_context_disk.Builder.init(arena);
    const changed_lowered = try lowerHeredocCopy(arena, &changed_disk, changed);
    try std.testing.expect(!std.mem.eql(u8, lowered.input_digest, changed_lowered.input_digest));

    changed = base;
    changed.source_name = "DOCUMENT";
    var renamed_disk = build_context_disk.Builder.init(arena);
    const renamed = try lowerHeredocCopy(arena, &renamed_disk, changed);
    try std.testing.expect(!std.mem.eql(u8, lowered.input_digest, renamed.input_digest));
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
        const request = build_exec.CopyRequest{
            .source = source,
            .dest = dest,
            .source_kind = try copySourceKind(root.kind),
            .dest_is_dir = dest_is_dir,
            .entry_count = entry_count,
        };
        build_exec.validateCopyRequest(request) catch |err| {
            diagnostic.instruction_line.* = instruction_line;
            diagnostic.copy.source = root.rel;
            return err;
        };
        try out.append(request);
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

test "context COPY preflight reserves the longest generated source prefix" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-build-copy-prefix-preflight";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    const first = try arena.alloc(u8, 250);
    const second = try arena.alloc(u8, 250);
    @memset(first, 'a');
    @memset(second, 'b');
    const directory = try std.fs.path.join(arena, &.{ tmp, first });
    const source = try std.fs.path.join(arena, &.{ first, second });
    const source_path = try std.fs.path.join(arena, &.{ tmp, source });
    try Io.Dir.cwd().createDirPath(io, directory);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = "x" });

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
    try std.testing.expectError(error.CopySourceNotFound, preflightContextCopy(
        io,
        arena,
        ctx,
        &diagnostic,
        7,
        &.{source},
        "/dest/",
        "/",
    ));
    try std.testing.expectEqual(@as(usize, 7), instruction_line);
    try std.testing.expectEqualStrings(source, copy.source);
}

test "cross-stage COPY link policy and source snapshot are cache identity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source_a = spore.RootfsStorage{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = .{ .mmio_slot = 1 },
        .logical_size = rootfs_cas.default_chunk_size,
        .chunk_size = rootfs_cas.default_chunk_size,
        .hash_algorithm = "blake3",
        .index_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .base_identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .object_namespace = "rootfs/blake3",
    };
    var source_b = source_a;
    source_b.index_digest = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    source_b.base_identity = source_b.index_digest;

    const linked = try buildInputCopy(
        allocator,
        7,
        "COPY --link --from=source /out/app /app",
        &.{"/out/app"},
        "/app",
        "blake3:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        "/",
        true,
        0,
        source_a,
    );
    const linked_step = linked.copy.build_input;
    try std.testing.expectEqual(build_exec.CopyDestinationPolicy.link, linked_step.destination_policy);
    try std.testing.expectEqual(build_exec.CopyDestinationPolicy.link, linked_step.requests[0].destination_policy);

    const changed_source = try buildInputCopy(
        allocator,
        7,
        "COPY --link --from=source /out/app /app",
        &.{"/out/app"},
        "/app",
        "blake3:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        "/",
        true,
        0,
        source_b,
    );
    const parent = "blake3:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    const executor = "blake3:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    const first_key = try step_cache.stepKey(allocator, build_exec.cacheInputForStep(.{}, parent, executor, .{ .copy = linked_step }, .{}));
    const changed_key = try step_cache.stepKey(allocator, build_exec.cacheInputForStep(.{}, parent, executor, .{ .copy = changed_source.copy.build_input }, .{}));
    try std.testing.expect(!std.mem.eql(u8, first_key, changed_key));
}

test "remote ADD cache identity binds resolved URL destination and downloaded bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const staged = remote_add.StagedFile{
        .path = "/tmp/staged",
        .source_name = "tool",
        .content_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .size = 7,
        .mtime_unix_seconds = 1_700_000_000,
    };
    const add = remote_add.Prepared{
        .input = .{
            .stage_index = 0,
            .instruction_index = 0,
            .line = 2,
            .canonical_instruction = "ADD https://example.com/tool /usr/bin/tool",
            .resolved_url = "https://example.com/tool",
            .resolved_dest = "/usr/bin/tool",
            .mode = remote_add.default_mode,
            .env_digest = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            .workdir = "/",
        },
        .staged = staged,
    };
    const base = try remoteAddInputDigest(allocator, add);
    var changed_add = add;
    changed_add.input.resolved_dest = "/opt/tool";
    const changed_dest = try remoteAddInputDigest(allocator, changed_add);
    try std.testing.expect(!std.mem.eql(u8, base, changed_dest));
    changed_add = add;
    changed_add.input.resolved_url = "https://example.com/other";
    const changed_url = try remoteAddInputDigest(allocator, changed_add);
    try std.testing.expect(!std.mem.eql(u8, base, changed_url));
    changed_add = add;
    changed_add.staged.content_digest = "blake3:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    const changed_bytes = try remoteAddInputDigest(allocator, changed_add);
    try std.testing.expect(!std.mem.eql(u8, base, changed_bytes));
    changed_add = add;
    changed_add.staged.mtime_unix_seconds = null;
    const changed_mtime = try remoteAddInputDigest(allocator, changed_add);
    try std.testing.expect(!std.mem.eql(u8, base, changed_mtime));
    changed_add = add;
    changed_add.input.mode = 0o644;
    const changed_mode = try remoteAddInputDigest(allocator, changed_add);
    try std.testing.expect(!std.mem.eql(u8, base, changed_mode));
}

test "remote ADD lowers through the shared COPY apply protocol" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var context_disk = build_context_disk.Builder.init(allocator);
    const step = try lowerRemoteAdd(allocator, &context_disk, .{
        .input = .{
            .stage_index = 0,
            .instruction_index = 0,
            .line = 4,
            .canonical_instruction = "ADD https://example.com/tool /usr/local/bin/",
            .resolved_url = "https://example.com/tool",
            .resolved_dest = "/usr/local/bin/",
            .mode = 0o413,
            .env_digest = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            .workdir = "/work",
        },
        .staged = .{
            .path = "/tmp/staged",
            .source_name = "tool",
            .content_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .size = 7,
            .mtime_unix_seconds = 1_700_000_000,
        },
    });
    try std.testing.expectEqual(@as(usize, 1), step.requests.len);
    try std.testing.expectEqualStrings("s0/tool", step.requests[0].source);
    try std.testing.expectEqualStrings("/usr/local/bin", step.requests[0].dest);
    try std.testing.expect(step.requests[0].dest_is_dir);
    try std.testing.expectEqual(@as(?i64, 1_700_000_000), step.requests[0].mtime_unix_seconds);
    try std.testing.expectEqual(@as(u32, 0o413), context_disk.entries.items[1].mode);

    const epoch_step = try lowerRemoteAdd(allocator, &context_disk, .{
        .input = .{
            .stage_index = 0,
            .instruction_index = 1,
            .line = 5,
            .canonical_instruction = "ADD https://example.com/plain /plain",
            .resolved_url = "https://example.com/plain",
            .resolved_dest = "/plain",
            .mode = 0,
            .env_digest = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            .workdir = "/",
        },
        .staged = .{
            .path = "/tmp/plain",
            .source_name = "plain",
            .content_digest = "blake3:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            .size = 5,
            .mtime_unix_seconds = null,
        },
    });
    try std.testing.expectEqual(@as(?i64, 0), epoch_step.requests[0].mtime_unix_seconds);
    try std.testing.expectEqual(@as(u32, 0), context_disk.entries.items[3].mode);
}

test "remote ADD preflight bounds filename joins for runtime directories" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source_name = try allocator.alloc(u8, 250);
    @memset(source_name, 's');
    const destination = try allocator.alloc(u8, 301);
    destination[0] = '/';
    @memset(destination[1..300], 'd');
    destination[300] = 'd';
    try std.testing.expectError(error.CopyDestinationUnsupported, preflightRemoteAdd(allocator, .{
        .input = .{
            .stage_index = 0,
            .instruction_index = 1,
            .line = 3,
            .canonical_instruction = "ADD https://example.com/file /long/",
            .resolved_url = "https://example.com/file",
            .resolved_dest = destination,
            .mode = remote_add.default_mode,
            .env_digest = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            .workdir = "/",
        },
        .staged = .{
            .path = "/tmp/staged",
            .source_name = source_name,
            .content_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .size = 1,
            .mtime_unix_seconds = null,
        },
    }));
}
