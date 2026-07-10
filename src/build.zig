const std = @import("std");
const Io = std.Io;

const dockerfile = @import("build/dockerfile.zig");
const build_context = @import("build/context.zig");
const build_context_disk = @import("build/context_disk.zig");
const build_exec = @import("build/exec.zig");
const step_cache = @import("build/step_cache.zig");
const local_paths = @import("local_paths.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const rootfs_mod = @import("rootfs.zig");
const spore = @import("spore.zig");

pub const BuildContextArg = struct {
    name: []const u8,
    oci_layout_path: []const u8,
};

pub const BuildArg = struct {
    key: []const u8,
    value: []const u8,
};

pub const NetworkMode = step_cache.NetworkMode;

pub const Options = struct {
    tag: []const u8,
    context_dir: []const u8,
    dockerfile_path: []const u8,
    platform: rootfs_mod.Platform = .{},
    build_contexts: []const BuildContextArg = &.{},
    build_args: []const BuildArg = &.{},
    network: NetworkMode = .spore,
    no_cache: bool = false,
    disk_grow_target_override: u64 = 0,
    mkfs: ?[]const u8 = null,
    debugfs: ?[]const u8 = null,
    output: ?*Io.Writer = null,
    diagnostic: ?*Diagnostic = null,
};

pub const Diagnostic = struct {
    dockerfile: dockerfile.Diagnostic = .{},
    dockerignore: build_context.IgnoreDiagnostic = .{},
    copy: build_context.CopyDiagnostic = .{},
    context_hash: build_context.HashDiagnostic = .{},
    context_disk: build_context_disk.Diagnostic = .{},
    executor: build_exec.Diagnostic = .{},
    instruction_line: usize = 0,
    limit: u64 = 0,
    actual: u64 = 0,
};

pub const Result = struct {
    resolved_image_ref: []const u8,
    index_digest: []const u8,
    metadata_path: []const u8,
    local_ref_path: []const u8,
    cache_hit: bool,
};

const State = struct {
    storage: spore.RootfsStorage,
    env: std.array_list.Managed([]const u8),
    args: std.array_list.Managed(ArgValue),
    workdir: []const u8 = "/",
    cmd: ?[]const []const u8 = null,
};

const ArgValue = step_cache.ArgInput;

const CachedMetadata = struct {
    config: rootfs_mod.ImageConfig = .{},
    rootfs_storage: ?spore.RootfsStorage = null,
    rootfs_size: u64 = 0,
};

const default_disk_grow_extra_bytes: u64 = 8 * 1024 * 1024 * 1024;

pub fn build(init: std.process.Init, allocator: std.mem.Allocator, options: Options) !Result {
    var local_diagnostic: Diagnostic = .{};
    const diagnostic = options.diagnostic orelse &local_diagnostic;
    diagnostic.* = .{};

    const dockerfile_bytes = try Io.Dir.cwd().readFileAlloc(init.io, options.dockerfile_path, allocator, .limited(1024 * 1024));
    const doc = dockerfile.parse(allocator, dockerfile_bytes, &diagnostic.dockerfile) catch |err| switch (err) {
        error.DockerfileParseFailed => return error.DockerfileParseFailed,
        else => |e| return e,
    };

    const ctx = build_context.load(allocator, init.io, options.context_dir, &diagnostic.dockerignore) catch |err| switch (err) {
        error.UnsupportedDockerignorePattern => return error.UnsupportedDockerignorePattern,
        else => |e| return e,
    };
    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    var stat_cache = build_context.StatCache.load(allocator, init.io, cache_root, &diagnostic.context_hash);
    defer stat_cache.save(&diagnostic.context_hash);
    var cache_lock: ?rootfs_mod.RootfsCacheLock = null;
    defer if (cache_lock) |*lock| lock.deinit();

    var state: ?State = null;
    var pre_from_args = std.array_list.Managed(ArgValue).init(allocator);
    var saw_from = false;
    var any_exec_step = false;
    instructions: for (doc.instructions, 0..) |instruction, index| {
        switch (instruction.value) {
            .arg => |arg| {
                if (!saw_from) {
                    try declareArg(allocator, options.build_args, null, &pre_from_args, arg);
                    continue;
                }
                if (state) |*s| {
                    if (!try applyMetadataInstruction(allocator, options, pre_from_args.items, s, instruction)) unreachable;
                } else unreachable;
            },
            .from => |from| {
                if (saw_from) return error.UnsupportedMultiStageDockerfile;
                const source = try substitute(allocator, from.source, pre_from_args.items, &.{});
                const base = try resolveBase(init, allocator, options, source);
                if (!try rootfs_cas.storageCompleteWithStampRepair(init.io, allocator, base.cache_root, base.storage)) return error.RootFSDigestCacheMiss;
                state = try stateFromBase(allocator, base.config, base.storage);
                // FROM resolution may import and lock the cache itself. Once it
                // completes, serialize the remaining build against destructive
                // GC until every resulting storage value has a durable root.
                cache_lock = try rootfs_mod.lockRootfsCacheExclusive(init.io, allocator, cache_root);
                saw_from = true;
            },
            else => {
                if (!saw_from) return error.MissingDockerfileFrom;
                if (state) |*s| {
                    if (try applyMetadataInstruction(allocator, options, pre_from_args.items, s, instruction)) continue;
                    switch (instruction.value) {
                        .run => {
                            any_exec_step = true;
                            s.storage = cachedExecStep(init, allocator, options, s.*, instruction, "") catch |err| switch (err) {
                                error.CacheMissRequiresBuildExecutor => {
                                    state = try executeFromMiss(init, allocator, options, diagnostic, ctx, &stat_cache, pre_from_args.items, doc.instructions[index..], s.*);
                                    break :instructions;
                                },
                                else => |e| return e,
                            };
                        },
                        .copy => |copy| {
                            any_exec_step = true;
                            const resolved_sources = try substituteList(allocator, copy.sources, s.args.items, s.env.items);
                            const resolution = build_context.resolveCopySourcesWithDiagnostic(allocator, init.io, ctx, resolved_sources, &diagnostic.copy) catch |err| {
                                diagnostic.instruction_line = instruction.line;
                                return err;
                            };
                            const input_digest = try build_context.hashCopyResolutionWithOptions(allocator, init.io, ctx, resolution, .{
                                .stat_cache = &stat_cache,
                                .diagnostic = &diagnostic.context_hash,
                            });
                            s.storage = cachedExecStep(init, allocator, options, s.*, instruction, input_digest) catch |err| switch (err) {
                                error.CacheMissRequiresBuildExecutor => {
                                    state = try executeFromMiss(init, allocator, options, diagnostic, ctx, &stat_cache, pre_from_args.items, doc.instructions[index..], s.*);
                                    break :instructions;
                                },
                                else => |e| return e,
                            };
                        },
                        else => unreachable,
                    }
                } else unreachable;
            },
        }
    }
    const final_state = state orelse return error.MissingDockerfileFrom;
    // Executed states are rooted by step records; metadata-only builds still
    // reference their already-rooted base. Release before local-ref publication,
    // which takes the cache lock through its own writer path.
    cache_lock.?.deinit();
    cache_lock = null;
    const publish = try rootfs_mod.publishIndexedImage(init, allocator, .{
        .ref = options.tag,
        .platform = options.platform,
        .config = try imageConfig(allocator, options.platform, final_state.env.items, final_state.workdir, final_state.cmd),
        .rootfs_storage = final_state.storage,
    });
    return .{
        .resolved_image_ref = publish.resolved_image_ref,
        .index_digest = publish.rootfs_storage.index_digest,
        .metadata_path = publish.metadata_path,
        .local_ref_path = publish.local_ref_path,
        .cache_hit = any_exec_step and diagnostic.executor.executed_steps == 0,
    };
}

const Base = struct {
    cache_root: []const u8,
    storage: spore.RootfsStorage,
    config: rootfs_mod.ImageConfig,
};

fn resolveBase(init: std.process.Init, allocator: std.mem.Allocator, options: Options, source: []const u8) !Base {
    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    if (findBuildContext(options.build_contexts, source)) |ctx| {
        const imported = try rootfs_mod.importOciLayout(init, allocator, .{
            .input = ctx.oci_layout_path,
            .ref = "local/spore-build-base:cache",
            .platform = options.platform,
            .rootfs_storage = .chunked,
            .mkfs = options.mkfs,
            .debugfs = options.debugfs,
        });
        const metadata = try readCachedMetadata(allocator, init.io, imported.metadata_path);
        return .{ .cache_root = cache_root, .storage = imported.rootfs_storage, .config = metadata.config };
    }
    if (!rootfs_mod.isLocalImageRef(source)) return error.UnsupportedBuildFrom;
    const resolved = try rootfs_mod.resolveLocalCachedRef(init.io, allocator, cache_root, source, options.platform);
    const metadata_path = try rootfs_mod.cachedImageRootfsMetadataPath(allocator, cache_root, resolved);
    const metadata = try readCachedMetadata(allocator, init.io, metadata_path);
    const storage = metadata.rootfs_storage orelse return error.RootFSDigestCacheMiss;
    if (!try rootfs_cas.storageCompleteWithStampRepair(init.io, allocator, cache_root, storage)) return error.RootFSDigestCacheMiss;
    return .{ .cache_root = cache_root, .storage = storage, .config = metadata.config };
}

fn stateFromBase(allocator: std.mem.Allocator, config: rootfs_mod.ImageConfig, storage: spore.RootfsStorage) !State {
    var env = std.array_list.Managed([]const u8).init(allocator);
    const args = std.array_list.Managed(ArgValue).init(allocator);
    if (config.config) |runtime| {
        if (runtime.Env) |entries| for (entries) |entry| try env.append(try allocator.dupe(u8, entry));
        return .{
            .storage = try spore.cloneRootfsStorage(allocator, storage),
            .env = env,
            .args = args,
            .workdir = if (runtime.WorkingDir) |dir| if (dir.len == 0) "/" else try allocator.dupe(u8, dir) else "/",
            .cmd = if (runtime.Cmd) |cmd| try cloneStringList(allocator, cmd) else null,
        };
    }
    return .{ .storage = try spore.cloneRootfsStorage(allocator, storage), .env = env, .args = args };
}

fn applyMetadataInstruction(
    allocator: std.mem.Allocator,
    options: Options,
    pre_from_args: []const ArgValue,
    state: *State,
    instruction: dockerfile.Instruction,
) !bool {
    switch (instruction.value) {
        .env => |env| {
            for (env.pairs) |pair| {
                const key = try substitute(allocator, pair.key, state.args.items, state.env.items);
                const value = try substitute(allocator, pair.value, state.args.items, state.env.items);
                try putEnv(allocator, &state.env, key, value);
            }
        },
        .workdir => |raw| {
            const substituted = try substitute(allocator, raw, state.args.items, state.env.items);
            state.workdir = try resolveWorkdir(allocator, state.workdir, substituted);
        },
        .cmd => |cmd| {
            state.cmd = try resolveCmd(allocator, cmd, state.args.items, state.env.items);
        },
        .arg => |arg| try declareArg(allocator, options.build_args, pre_from_args, &state.args, arg),
        else => return false,
    }
    return true;
}

fn declareArg(
    allocator: std.mem.Allocator,
    cli_args: []const BuildArg,
    fallback_args: ?[]const ArgValue,
    args: *std.array_list.Managed(ArgValue),
    arg: dockerfile.Arg,
) !void {
    const value = if (findBuildArg(cli_args, arg.key)) |cli|
        cli.value
    else if (arg.default) |default|
        default
    else if (fallback_args) |fallback|
        lookupArg(arg.key, fallback)
    else
        null;
    try putArg(allocator, args, arg.key, value);
}

fn cachedExecStep(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: Options,
    state: State,
    instruction: dockerfile.Instruction,
    input_digest: []const u8,
) !spore.RootfsStorage {
    if (options.no_cache) return error.CacheMissRequiresBuildExecutor;
    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    const grow_target = try buildDiskGrowTarget(options, state.storage);
    const grown_input = try execStepInput(allocator, options, state, instruction, input_digest, grow_target);
    const grown_key = try step_cache.stepKey(allocator, grown_input);
    if (try step_cache.readHit(init.io, allocator, cache_root, grown_input, grown_key)) |hit| return hit;
    if (options.disk_grow_target_override != 0) return error.CacheMissRequiresBuildExecutor;

    const normal_input = try execStepInput(allocator, options, state, instruction, input_digest, 0);
    const normal_key = try step_cache.stepKey(allocator, normal_input);
    return (try step_cache.readHit(init.io, allocator, cache_root, normal_input, normal_key)) orelse error.CacheMissRequiresBuildExecutor;
}

fn executeFromMiss(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: Options,
    diagnostic: *Diagnostic,
    ctx: build_context.BuildContext,
    stat_cache: ?*build_context.StatCache,
    pre_from_args: []const ArgValue,
    instructions: []const dockerfile.Instruction,
    initial_state: State,
) !State {
    var state = initial_state;
    var steps = std.array_list.Managed(build_exec.Step).init(allocator);
    var context_disk = build_context_disk.Builder.init(allocator);
    for (instructions) |instruction| {
        if (try applyMetadataInstruction(allocator, options, pre_from_args, &state, instruction)) continue;
        switch (instruction.value) {
            .run => |run| try steps.append(.{ .run = try runStep(allocator, diagnostic, state, instruction, run, options.network) }),
            .copy => |copy| try steps.append(.{ .copy = try copyStep(allocator, init.io, ctx, stat_cache, &context_disk, diagnostic, state, instruction, copy) }),
            .from => return error.UnsupportedMultiStageDockerfile,
            else => unreachable,
        }
    }

    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    const context_disk_path = try context_disk.emitOrReuse(init.io, cache_root, &diagnostic.context_disk);
    state.storage = try build_exec.runSession(init, allocator, .{
        .platform = options.platform,
        .cache_root = cache_root,
        .base_storage = state.storage,
        .steps = steps.items,
        .disk_grow_target = try buildDiskGrowTarget(options, state.storage),
        .context_disk_path = context_disk_path,
        .output = options.output,
        .diagnostic = &diagnostic.executor,
    });
    return state;
}

fn runStep(
    allocator: std.mem.Allocator,
    diagnostic: *Diagnostic,
    state: State,
    instruction: dockerfile.Instruction,
    run: dockerfile.Run,
    network_mode: NetworkMode,
) !build_exec.RunStep {
    if (run.shell.len > build_exec.max_run_command_len) {
        diagnostic.instruction_line = instruction.line;
        diagnostic.limit = build_exec.max_run_command_len;
        diagnostic.actual = run.shell.len;
        return error.RunCommandTooLong;
    }
    return .{
        .line = instruction.line,
        .canonical_instruction = instruction.raw,
        .command = run.shell,
        .env = try runEnvironment(allocator, state),
        .env_digest = try effectiveEnvDigest(allocator, state),
        .workdir = state.workdir,
        .network_mode = network_mode,
    };
}

fn copyStep(
    allocator: std.mem.Allocator,
    io: Io,
    ctx: build_context.BuildContext,
    stat_cache: ?*build_context.StatCache,
    context_disk: *build_context_disk.Builder,
    diagnostic: *Diagnostic,
    state: State,
    instruction: dockerfile.Instruction,
    copy: dockerfile.Copy,
) !build_exec.CopyStep {
    const resolved_sources = try substituteList(allocator, copy.sources, state.args.items, state.env.items);
    const resolved_dest = try substitute(allocator, copy.dest, state.args.items, state.env.items);
    const resolution = build_context.resolveCopySourcesWithDiagnostic(allocator, io, ctx, resolved_sources, &diagnostic.copy) catch |err| {
        diagnostic.instruction_line = instruction.line;
        return err;
    };
    const resolved_entries = try build_context.describeCopyResolutionWithOptions(allocator, io, ctx, resolution, .{
        .stat_cache = stat_cache,
        .diagnostic = &diagnostic.context_hash,
    });
    const input_digest = try build_context.hashResolvedCopyEntries(allocator, resolved_entries);
    try context_disk.addResolvedEntries(resolved_entries);
    const dest_is_dir = copyDestIsDirectory(resolved_dest, resolution);
    if (resolution.roots.len > 1 and !copyDestEndsWithSlash(resolved_dest)) {
        diagnostic.instruction_line = instruction.line;
        return error.CopyDestinationMustBeDirectory;
    }
    const dest = try normalizeGuestPath(allocator, state.workdir, resolved_dest);
    const requests = try copyRequests(allocator, diagnostic, instruction.line, resolution, dest, dest_is_dir);
    return .{
        .line = instruction.line,
        .canonical_instruction = instruction.raw,
        .input_digest = input_digest,
        .env_digest = try effectiveEnvDigest(allocator, state),
        .workdir = state.workdir,
        .requests = requests,
    };
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
    diagnostic: *Diagnostic,
    instruction_line: usize,
    resolution: build_context.CopyResolution,
    dest: []const u8,
    dest_is_dir: bool,
) ![]const build_exec.CopyRequest {
    if (resolution.roots.len == 0) return error.CopySourceNotFound;
    var out = std.array_list.Managed(build_exec.CopyRequest).init(allocator);
    for (resolution.roots) |root| {
        const entry_count = copyRootEntryCount(resolution, root);
        if (entry_count == 0) return error.CopySourceNotFound;
        if (entry_count > build_exec.max_copy_entries) {
            diagnostic.instruction_line = instruction_line;
            diagnostic.copy.source = root.rel;
            diagnostic.limit = build_exec.max_copy_entries;
            diagnostic.actual = entry_count;
            return error.CopyEntryCountUnsupported;
        }
        try out.append(.{
            .source = root.rel,
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
        .directory => .directory,
        .file => .file,
        .sym_link => .sym_link,
        else => error.UnsupportedCopySourceType,
    };
}

fn normalizeGuestPath(allocator: std.mem.Allocator, workdir: []const u8, raw: []const u8) ![]const u8 {
    var parts = std.array_list.Managed([]const u8).init(allocator);
    if (!std.fs.path.isAbsolute(raw)) {
        try appendGuestPathParts(&parts, workdir);
    }
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

fn execStepInput(
    allocator: std.mem.Allocator,
    options: Options,
    state: State,
    instruction: dockerfile.Instruction,
    input_digest: []const u8,
    disk_grow_target: u64,
) !step_cache.StepInput {
    const env_digest = try effectiveEnvDigest(allocator, state);
    const operation: step_cache.StepInput.Operation = switch (instruction.value) {
        .run => .{ .run = .{
            .env_digest = env_digest,
            .workdir = state.workdir,
            .network_mode = options.network,
        } },
        .copy => .{ .copy = .{
            .input_digest = input_digest,
            .env_digest = env_digest,
            .workdir = state.workdir,
        } },
        else => unreachable,
    };
    return .{
        .platform = options.platform,
        .parent_index_digest = state.storage.index_digest,
        .canonical_instruction = instruction.raw,
        .disk_grow_target = disk_grow_target,
        .operation = operation,
    };
}

fn execStepKey(allocator: std.mem.Allocator, options: Options, state: State, instruction: dockerfile.Instruction, input_digest: []const u8) ![]const u8 {
    return step_cache.stepKey(allocator, try execStepInput(allocator, options, state, instruction, input_digest, try buildDiskGrowTarget(options, state.storage)));
}

fn buildDiskGrowTarget(options: Options, storage: spore.RootfsStorage) !u64 {
    if (storage.chunk_size == 0) return error.BadManifest;
    const raw = if (options.disk_grow_target_override != 0) options.disk_grow_target_override else blk: {
        const doubled = std.math.mul(u64, storage.logical_size, 2) catch return error.BadManifest;
        const plus_extra = std.math.add(u64, storage.logical_size, default_disk_grow_extra_bytes) catch return error.BadManifest;
        break :blk @max(doubled, plus_extra);
    };
    if (raw < storage.logical_size) return error.BadManifest;
    const remainder = raw % storage.chunk_size;
    if (remainder == 0) return raw;
    return std.math.add(u64, raw, storage.chunk_size - remainder) catch return error.BadManifest;
}

fn effectiveEnvDigest(allocator: std.mem.Allocator, state: State) ![]const u8 {
    return step_cache.envDigest(allocator, state.env.items, state.args.items);
}

fn runEnvironment(allocator: std.mem.Allocator, state: State) ![]const []const u8 {
    var entries = std.array_list.Managed([]const u8).init(allocator);
    for (state.env.items) |entry| try entries.append(entry);
    for (state.args.items) |arg| {
        const value = arg.value orelse continue;
        if (envContainsKey(state.env.items, arg.key)) continue;
        try entries.append(try std.fmt.allocPrint(allocator, "{s}={s}", .{ arg.key, value }));
    }
    return entries.toOwnedSlice();
}

fn envContainsKey(env: []const []const u8, key: []const u8) bool {
    for (env) |entry| {
        if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
            if (std.mem.eql(u8, entry[0..eq], key)) return true;
        }
    }
    return false;
}

fn imageConfig(
    allocator: std.mem.Allocator,
    platform: rootfs_mod.Platform,
    env: []const []const u8,
    workdir: []const u8,
    cmd: ?[]const []const u8,
) !rootfs_mod.ImageConfig {
    return .{
        .architecture = platform.arch,
        .os = platform.os,
        .config = .{
            .Env = try cloneStringList(allocator, env),
            .Cmd = if (cmd) |entries| try cloneStringList(allocator, entries) else null,
            .WorkingDir = workdir,
        },
    };
}

fn resolveCmd(allocator: std.mem.Allocator, cmd: dockerfile.Cmd, args: []const ArgValue, env: []const []const u8) ![]const []const u8 {
    switch (cmd) {
        .shell => |raw| return cloneStringList(allocator, &.{ "/bin/sh", "-c", try substitute(allocator, raw, args, env) }),
        .exec => |entries| return substituteList(allocator, entries, args, env),
    }
}

fn resolveWorkdir(allocator: std.mem.Allocator, current: []const u8, next: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(next)) return allocator.dupe(u8, next);
    return std.fs.path.join(allocator, &.{ current, next });
}

fn substituteList(allocator: std.mem.Allocator, raw: []const []const u8, args: []const ArgValue, env: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, raw.len);
    for (raw, 0..) |entry, i| out[i] = try substitute(allocator, entry, args, env);
    return out;
}

fn substitute(allocator: std.mem.Allocator, input: []const u8, args: []const ArgValue, env: []const []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '$') {
            try out.append(input[i]);
            i += 1;
            continue;
        }
        if (i + 1 >= input.len) {
            try out.append('$');
            i += 1;
            continue;
        }
        if (input[i + 1] == '$') {
            try out.append('$');
            i += 2;
            continue;
        }
        var name: []const u8 = undefined;
        if (input[i + 1] == '{') {
            const end = std.mem.indexOfScalarPos(u8, input, i + 2, '}') orelse return error.BadVariableSubstitution;
            name = input[i + 2 .. end];
            i = end + 1;
        } else {
            var end = i + 1;
            while (end < input.len and (std.ascii.isAlphanumeric(input[end]) or input[end] == '_')) end += 1;
            if (end == i + 1) {
                try out.append('$');
                i += 1;
                continue;
            }
            name = input[i + 1 .. end];
            i = end;
        }
        const value = lookupVar(name, args, env) orelse return error.UnsetBuildArg;
        try out.appendSlice(value);
    }
    return out.toOwnedSlice();
}

fn lookupVar(name: []const u8, args: []const ArgValue, env: []const []const u8) ?[]const u8 {
    for (env) |entry| {
        if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
            if (std.mem.eql(u8, entry[0..eq], name)) return entry[eq + 1 ..];
        }
    }
    for (args) |arg| {
        if (std.mem.eql(u8, arg.key, name)) return arg.value;
    }
    return null;
}

fn lookupArg(name: []const u8, args: []const ArgValue) ?[]const u8 {
    for (args) |arg| {
        if (std.mem.eql(u8, arg.key, name)) return arg.value;
    }
    return null;
}

fn putEnv(allocator: std.mem.Allocator, env: *std.array_list.Managed([]const u8), key: []const u8, value: []const u8) !void {
    const entry = try std.fmt.allocPrint(allocator, "{s}={s}", .{ key, value });
    for (env.items, 0..) |existing, i| {
        if (std.mem.startsWith(u8, existing, key) and existing.len > key.len and existing[key.len] == '=') {
            env.items[i] = entry;
            return;
        }
    }
    try env.append(entry);
}

fn putArg(allocator: std.mem.Allocator, args: *std.array_list.Managed(ArgValue), key: []const u8, value: ?[]const u8) !void {
    for (args.items, 0..) |existing, i| {
        if (std.mem.eql(u8, existing.key, key)) {
            args.items[i] = .{ .key = key, .value = if (value) |v| try allocator.dupe(u8, v) else null };
            return;
        }
    }
    try args.append(.{ .key = key, .value = if (value) |v| try allocator.dupe(u8, v) else null });
}

fn readCachedMetadata(allocator: std.mem.Allocator, io: Io, path: []const u8) !CachedMetadata {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    var parsed = try std.json.parseFromSlice(CachedMetadata, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    const value = parsed.value;
    return .{
        .config = try cloneImageConfig(allocator, value.config),
        .rootfs_storage = if (value.rootfs_storage) |storage| try spore.cloneRootfsStorage(allocator, storage) else null,
        .rootfs_size = value.rootfs_size,
    };
}

fn cloneImageConfig(allocator: std.mem.Allocator, config: rootfs_mod.ImageConfig) !rootfs_mod.ImageConfig {
    const runtime = config.config;
    return .{
        .architecture = if (config.architecture) |arch| try allocator.dupe(u8, arch) else null,
        .os = if (config.os) |os| try allocator.dupe(u8, os) else null,
        .config = if (runtime) |rt| .{
            .Env = if (rt.Env) |entries| try cloneStringList(allocator, entries) else null,
            .Entrypoint = if (rt.Entrypoint) |entries| try cloneStringList(allocator, entries) else null,
            .Cmd = if (rt.Cmd) |entries| try cloneStringList(allocator, entries) else null,
            .WorkingDir = if (rt.WorkingDir) |dir| try allocator.dupe(u8, dir) else null,
            .User = if (rt.User) |user| try allocator.dupe(u8, user) else null,
        } else null,
    };
}

fn findBuildContext(contexts: []const BuildContextArg, name: []const u8) ?BuildContextArg {
    for (contexts) |ctx| if (std.mem.eql(u8, ctx.name, name)) return ctx;
    return null;
}

fn findBuildArg(args: []const BuildArg, key: []const u8) ?BuildArg {
    for (args) |arg| if (std.mem.eql(u8, arg.key, key)) return arg;
    return null;
}

fn instructionKind(instruction: dockerfile.Instruction) []const u8 {
    return switch (instruction.value) {
        .from => "FROM",
        .run => "RUN",
        .copy => "COPY",
        .env => "ENV",
        .arg => "ARG",
        .workdir => "WORKDIR",
        .cmd => "CMD",
    };
}

fn cloneStringList(allocator: std.mem.Allocator, entries: []const []const u8) ![][]const u8 {
    const out = try allocator.alloc([]const u8, entries.len);
    for (entries, 0..) |entry, i| out[i] = try allocator.dupe(u8, entry);
    return out;
}

fn testStorage() spore.RootfsStorage {
    return .{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = .{ .mmio_slot = 1 },
        .logical_size = 4096,
        .chunk_size = 4096,
        .hash_algorithm = "blake3",
        .index_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .base_identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .object_namespace = "rootfs/blake3",
    };
}

test "variable substitution uses env before args" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try substitute(arena, "${APP}/$MODE", &.{.{ .key = "MODE", .value = "arg" }}, &.{"APP=/srv"});
    try std.testing.expectEqualStrings("/srv/arg", got);
}

test "run environment includes declared args after env" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = std.array_list.Managed([]const u8).init(arena);
    try env.append("MODE=env");
    try env.append("APP=/srv/app");
    var args = std.array_list.Managed(ArgValue).init(arena);
    try args.append(.{ .key = "MODE", .value = "arg" });
    try args.append(.{ .key = "TARGET", .value = "prod" });
    try args.append(.{ .key = "UNSET", .value = null });
    const entries = try runEnvironment(arena, .{
        .storage = .{
            .kind = spore.rootfs_storage_kind_chunked_ext4,
            .device = .{ .mmio_slot = 1 },
            .logical_size = 4096,
            .chunk_size = 4096,
            .hash_algorithm = "blake3",
            .index_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .base_identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .object_namespace = "rootfs/blake3",
        },
        .env = env,
        .args = args,
    });
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("MODE=env", entries[0]);
    try std.testing.expectEqualStrings("APP=/srv/app", entries[1]);
    try std.testing.expectEqualStrings("TARGET=prod", entries[2]);
}

test "RUN executor preserves shell text for guest expansion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = std.array_list.Managed([]const u8).init(arena);
    try env.append("APP_ENV=test");
    var args = std.array_list.Managed(ArgValue).init(arena);
    try args.append(.{ .key = "BUILD_ARG", .value = "from-arg" });
    const shell = "echo '$BUILD_ARG' $? $(dpkg --print-architecture) ${VERSION_CODENAME}";
    const instruction = dockerfile.Instruction{
        .line = 2,
        .raw = "RUN " ++ shell,
        .value = .{ .run = .{ .shell = shell } },
    };
    var diagnostic: Diagnostic = .{};
    const step = try runStep(arena, &diagnostic, .{
        .storage = testStorage(),
        .env = env,
        .args = args,
    }, instruction, instruction.value.run, .spore);
    try std.testing.expectEqualStrings(shell, step.command);
    try std.testing.expectEqualStrings("APP_ENV=test", step.env[0]);
    try std.testing.expectEqualStrings("BUILD_ARG=from-arg", step.env[1]);
}

test "RUN cache identity includes network mode and matches executor" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: dockerfile.Diagnostic = .{};
    const doc = try dockerfile.parse(arena,
        \\FROM base
        \\RUN fetch-dependency
        \\
    , &diag);
    const instruction = doc.instructions[1];
    const state = State{
        .storage = testStorage(),
        .env = std.array_list.Managed([]const u8).init(arena),
        .args = std.array_list.Managed(ArgValue).init(arena),
    };
    const spore_options = Options{
        .tag = "local/app:dev",
        .context_dir = "unused",
        .dockerfile_path = "unused",
        .network = .spore,
    };
    var none_options = spore_options;
    none_options.network = .none;
    var diagnostic: Diagnostic = .{};
    const step = try runStep(arena, &diagnostic, state, instruction, instruction.value.run, .spore);
    const grow_target = try buildDiskGrowTarget(spore_options, state.storage);

    const spore_read = try execStepInput(arena, spore_options, state, instruction, "", grow_target);
    const spore_write = build_exec.cacheInputForStep(spore_options.platform, state.storage.index_digest, .{ .run = step }, grow_target);
    const spore_read_key = try step_cache.stepKey(arena, spore_read);
    const spore_write_key = try step_cache.stepKey(arena, spore_write);
    try std.testing.expectEqualStrings(spore_read_key, spore_write_key);

    const none_read = try execStepInput(arena, none_options, state, instruction, "", grow_target);
    var none_step = step;
    none_step.network_mode = .none;
    const none_write = build_exec.cacheInputForStep(none_options.platform, state.storage.index_digest, .{ .run = none_step }, grow_target);
    const none_read_key = try step_cache.stepKey(arena, none_read);
    const none_write_key = try step_cache.stepKey(arena, none_write);
    try std.testing.expectEqualStrings(none_read_key, none_write_key);
    try std.testing.expect(!std.mem.eql(u8, spore_read_key, none_read_key));
}

test "COPY executor step key matches cached read key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: dockerfile.Diagnostic = .{};
    const doc = try dockerfile.parse(arena,
        \\FROM base
        \\WORKDIR /app
        \\COPY src/ ./
        \\
    , &diag);
    const instruction = doc.instructions[2];
    const storage = spore.RootfsStorage{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = .{ .mmio_slot = 1 },
        .logical_size = 4096,
        .chunk_size = 4096,
        .hash_algorithm = "blake3",
        .index_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .base_identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .object_namespace = "rootfs/blake3",
    };
    const state = State{
        .storage = storage,
        .env = std.array_list.Managed([]const u8).init(arena),
        .args = std.array_list.Managed(ArgValue).init(arena),
        .workdir = "/app",
    };
    const options = Options{
        .tag = "local/app:dev",
        .context_dir = "unused",
        .dockerfile_path = "unused",
    };
    const input_digest = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const grow_target = try buildDiskGrowTarget(options, storage);
    const read_input = try execStepInput(arena, options, state, instruction, input_digest, grow_target);
    const read_key = try step_cache.stepKey(arena, read_input);
    const env_digest = try effectiveEnvDigest(arena, state);
    const copy_step = build_exec.Step{ .copy = .{
        .canonical_instruction = instruction.raw,
        .input_digest = input_digest,
        .env_digest = env_digest,
        .workdir = state.workdir,
        .requests = &.{},
    } };
    const write_input = build_exec.cacheInputForStep(options.platform, storage.index_digest, copy_step, grow_target);
    const write_key = try step_cache.stepKey(arena, write_input);
    try std.testing.expectEqual(grow_target, write_input.disk_grow_target);
    try std.testing.expectEqualStrings(read_key, write_key);

    var none_options = options;
    none_options.network = .none;
    const none_read_input = try execStepInput(arena, none_options, state, instruction, input_digest, grow_target);
    const none_write_input = build_exec.cacheInputForStep(none_options.platform, storage.index_digest, copy_step, grow_target);
    try std.testing.expectEqualStrings(read_key, try step_cache.stepKey(arena, none_read_input));
    try std.testing.expectEqualStrings(write_key, try step_cache.stepKey(arena, none_write_input));
}

test "build disk grow target uses deterministic sparse policy" {
    const storage = spore.RootfsStorage{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = .{ .mmio_slot = 1 },
        .logical_size = 16 * 1024 * 1024,
        .chunk_size = rootfs_cas.default_chunk_size,
        .hash_algorithm = "blake3",
        .index_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .base_identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .object_namespace = "rootfs/blake3",
    };
    const options = Options{
        .tag = "local/app:dev",
        .context_dir = "unused",
        .dockerfile_path = "unused",
    };
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024 + default_disk_grow_extra_bytes), try buildDiskGrowTarget(options, storage));
    const override = Options{
        .tag = "local/app:dev",
        .context_dir = "unused",
        .dockerfile_path = "unused",
        .disk_grow_target_override = 20 * 1024 * 1024 + 1,
    };
    try std.testing.expectEqual(@as(u64, 20 * 1024 * 1024 + rootfs_cas.default_chunk_size), try buildDiskGrowTarget(override, storage));
}

test "hidden disk grow override misses without poisoning default cache" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-spore-build-disk-grow-cache";
    const cache_dir = tmp ++ "/cache";
    const base_rootfs = tmp ++ "/base.ext4";
    const default_child_rootfs = tmp ++ "/default-child.ext4";
    const override_child_rootfs = tmp ++ "/override-child.ext4";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = base_rootfs, .data = "base rootfs bytes" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = default_child_rootfs, .data = "default child rootfs bytes" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = override_child_rootfs, .data = "override child rootfs bytes" });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_dir);
    const init = testInit(allocator, io, &arena_state, &env);
    const cache_root = try local_paths.rootfsCacheRootPath(arena, &env);

    const base_preload = try rootfs_cas.preloadPath(io, arena, cache_root, base_rootfs, rootfs_cas.default_chunk_size);
    const base_storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, base_preload);
    const default_child_preload = try rootfs_cas.preloadPath(io, arena, cache_root, default_child_rootfs, rootfs_cas.default_chunk_size);
    const default_child_storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, default_child_preload);
    const override_child_preload = try rootfs_cas.preloadPath(io, arena, cache_root, override_child_rootfs, rootfs_cas.default_chunk_size);
    const override_child_storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, override_child_preload);

    var diag: dockerfile.Diagnostic = .{};
    const doc = try dockerfile.parse(arena,
        \\FROM base
        \\RUN echo cached
        \\
    , &diag);
    const instruction = doc.instructions[1];
    const state = State{
        .storage = base_storage,
        .env = std.array_list.Managed([]const u8).init(arena),
        .args = std.array_list.Managed(ArgValue).init(arena),
    };
    const options = Options{
        .tag = "local/app:dev",
        .context_dir = "unused",
        .dockerfile_path = "unused",
    };
    const default_input = try execStepInput(arena, options, state, instruction, "", try buildDiskGrowTarget(options, base_storage));
    const default_key = try step_cache.stepKey(arena, default_input);
    _ = try step_cache.writeRecord(io, arena, cache_root, default_input, default_key, default_child_storage);

    const default_hit = try cachedExecStep(init, arena, options, state, instruction, "");
    try std.testing.expectEqualStrings(default_child_storage.index_digest, default_hit.index_digest);

    const override_options = Options{
        .tag = "local/app:dev",
        .context_dir = "unused",
        .dockerfile_path = "unused",
        .disk_grow_target_override = try buildDiskGrowTarget(options, base_storage) + rootfs_cas.default_chunk_size,
    };
    try std.testing.expectError(error.CacheMissRequiresBuildExecutor, cachedExecStep(init, arena, override_options, state, instruction, ""));

    const override_input = try execStepInput(arena, override_options, state, instruction, "", try buildDiskGrowTarget(override_options, base_storage));
    const override_key = try step_cache.stepKey(arena, override_input);
    _ = try step_cache.writeRecord(io, arena, cache_root, override_input, override_key, override_child_storage);
    const override_hit = try cachedExecStep(init, arena, override_options, state, instruction, "");
    try std.testing.expectEqualStrings(override_child_storage.index_digest, override_hit.index_digest);

    const default_hit_again = try cachedExecStep(init, arena, options, state, instruction, "");
    try std.testing.expectEqualStrings(default_child_storage.index_digest, default_hit_again.index_digest);
}

test "COPY destination rejects guest path escape" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.CopyDestinationUnsupported, normalizeGuestPath(arena, "/app", "../secret"));
    try std.testing.expectError(error.CopyDestinationUnsupported, normalizeGuestPath(arena, "/app", "/tmp/../secret"));
    const resolved = try normalizeGuestPath(arena, "/app", "subdir/.");
    try std.testing.expectEqualStrings("/app/subdir", resolved);
}

test "COPY file source can target non-slash file destination" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = "zig-cache/test-spore-build-copy-file-dest";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, root);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/source.txt", .data = "file\n" });

    var ctx_diag: build_context.IgnoreDiagnostic = .{};
    const ctx = try build_context.load(arena, io, root, &ctx_diag);
    var df_diag: dockerfile.Diagnostic = .{};
    const doc = try dockerfile.parse(arena,
        \\FROM base
        \\WORKDIR /app
        \\COPY source.txt renamed.txt
        \\
    , &df_diag);
    const state = State{
        .storage = testStorage(),
        .env = std.array_list.Managed([]const u8).init(arena),
        .args = std.array_list.Managed(ArgValue).init(arena),
        .workdir = "/app",
    };
    var diagnostic: Diagnostic = .{};
    var context_disk = build_context_disk.Builder.init(arena);
    const step = try copyStep(arena, io, ctx, null, &context_disk, &diagnostic, state, doc.instructions[2], doc.instructions[2].value.copy);
    try std.testing.expectEqual(@as(usize, 1), step.requests.len);
    try std.testing.expectEqual(.file, step.requests[0].source_kind);
    try std.testing.expectEqualStrings("source.txt", step.requests[0].source);
    try std.testing.expectEqualStrings("/app/renamed.txt", step.requests[0].dest);
    try std.testing.expect(!step.requests[0].dest_is_dir);
    try std.testing.expect(context_disk.hasEntries());
}

test "COPY multiple sources require trailing slash destination" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = "zig-cache/test-spore-build-copy-multi-dest";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, root);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/a.txt", .data = "a" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/b.txt", .data = "b" });

    var ctx_diag: build_context.IgnoreDiagnostic = .{};
    const ctx = try build_context.load(arena, io, root, &ctx_diag);
    var df_diag: dockerfile.Diagnostic = .{};
    const doc = try dockerfile.parse(arena,
        \\FROM base
        \\WORKDIR /app
        \\COPY a.txt b.txt dest
        \\
    , &df_diag);
    const state = State{
        .storage = testStorage(),
        .env = std.array_list.Managed([]const u8).init(arena),
        .args = std.array_list.Managed(ArgValue).init(arena),
        .workdir = "/app",
    };
    var diagnostic: Diagnostic = .{};
    var context_disk = build_context_disk.Builder.init(arena);
    try std.testing.expectError(error.CopyDestinationMustBeDirectory, copyStep(arena, io, ctx, null, &context_disk, &diagnostic, state, doc.instructions[2], doc.instructions[2].value.copy));
}

test "COPY directory source preserves empty subdirectory entry" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = "zig-cache/test-spore-build-copy-empty-dir";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, root ++ "/src/empty");

    var ctx_diag: build_context.IgnoreDiagnostic = .{};
    const ctx = try build_context.load(arena, io, root, &ctx_diag);
    var df_diag: dockerfile.Diagnostic = .{};
    const doc = try dockerfile.parse(arena,
        \\FROM base
        \\COPY src/ /dest/
        \\
    , &df_diag);
    const state = State{
        .storage = testStorage(),
        .env = std.array_list.Managed([]const u8).init(arena),
        .args = std.array_list.Managed(ArgValue).init(arena),
    };
    var diagnostic: Diagnostic = .{};
    var context_disk = build_context_disk.Builder.init(arena);
    const step = try copyStep(arena, io, ctx, null, &context_disk, &diagnostic, state, doc.instructions[1], doc.instructions[1].value.copy);
    try std.testing.expectEqual(@as(usize, 1), step.requests.len);
    try std.testing.expectEqual(.directory, step.requests[0].source_kind);
    try std.testing.expectEqualStrings("src", step.requests[0].source);
    try std.testing.expectEqualStrings("/dest", step.requests[0].dest);
    try std.testing.expectEqual(@as(usize, 2), step.requests[0].entry_count);
}

test "fully cached build publishes final indexed image" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-spore-build-cached";
    const context_dir = tmp ++ "/context";
    const cache_dir = tmp ++ "/cache";
    const dockerfile_path = context_dir ++ "/Dockerfile";
    const base_rootfs = tmp ++ "/base.ext4";
    const child_rootfs = tmp ++ "/child.ext4";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, context_dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = base_rootfs, .data = "base rootfs bytes" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = child_rootfs, .data = "child rootfs bytes" });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = dockerfile_path,
        .data =
        \\FROM local/base:dev
        \\RUN echo cached
        \\CMD ["/bin/true"]
        \\
        ,
    });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_dir);
    const init = testInit(allocator, io, &arena_state, &env);
    const cache_root = try local_paths.rootfsCacheRootPath(arena, &env);

    const base_preload = try rootfs_cas.preloadPath(io, arena, cache_root, base_rootfs, rootfs_cas.default_chunk_size);
    const base_storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, base_preload);
    _ = try rootfs_mod.publishIndexedImage(init, arena, .{
        .ref = "local/base:dev",
        .platform = .{},
        .rootfs_storage = base_storage,
    });

    const child_preload = try rootfs_cas.preloadPath(io, arena, cache_root, child_rootfs, rootfs_cas.default_chunk_size);
    const child_storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, child_preload);
    const env_digest = try step_cache.envDigest(arena, &.{}, &.{});
    const run_input = step_cache.StepInput{
        .platform = .{},
        .parent_index_digest = base_storage.index_digest,
        .canonical_instruction = "RUN echo cached",
        .disk_grow_target = try buildDiskGrowTarget(.{
            .tag = "local/app:dev",
            .context_dir = context_dir,
            .dockerfile_path = dockerfile_path,
            .platform = .{},
        }, base_storage),
        .operation = .{ .run = .{
            .env_digest = env_digest,
            .workdir = "/",
            .network_mode = .spore,
        } },
    };
    const run_key = try step_cache.stepKey(arena, run_input);
    _ = try step_cache.writeRecord(io, arena, cache_root, run_input, run_key, child_storage);

    var diagnostic: Diagnostic = .{};
    const result = try build(init, arena, .{
        .tag = "local/app:dev",
        .context_dir = context_dir,
        .dockerfile_path = dockerfile_path,
        .platform = .{},
        .diagnostic = &diagnostic,
    });

    try std.testing.expect(result.cache_hit);
    try std.testing.expectEqualStrings(child_storage.index_digest, result.index_digest);
    const resolved = try rootfs_mod.resolveLocalCachedRef(io, arena, cache_root, "local/app:dev", .{});
    try std.testing.expect(!std.mem.eql(u8, child_storage.index_digest, resolved.manifest_digest));
    const indexed = (try rootfs_mod.cachedImageIndexedRootfs(io, arena, cache_root, resolved)) orelse return error.MissingIndexedRootfs;
    defer rootfs_mod.deinitCachedIndexedRootfs(arena, indexed);
    try std.testing.expectEqualStrings(child_storage.index_digest, indexed.storage.index_digest);

    const resolved_direct = try rootfs_mod.resolveLocalCachedRef(io, arena, cache_root, result.resolved_image_ref, .{});
    try std.testing.expectEqualStrings(resolved.manifest_digest, resolved_direct.manifest_digest);
    const indexed_direct = (try rootfs_mod.cachedImageIndexedRootfs(io, arena, cache_root, resolved_direct)) orelse return error.MissingIndexedRootfs;
    defer rootfs_mod.deinitCachedIndexedRootfs(arena, indexed_direct);
    try std.testing.expectEqualStrings(child_storage.index_digest, indexed_direct.storage.index_digest);
}

test "metadata-only builds with different CMD publish distinct image identities" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-spore-build-config-identity";
    const true_context = tmp ++ "/true-context";
    const false_context = tmp ++ "/false-context";
    const cache_dir = tmp ++ "/cache";
    const base_rootfs = tmp ++ "/base.ext4";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, true_context);
    try Io.Dir.cwd().createDirPath(io, false_context);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = base_rootfs, .data = "same rootfs bytes" });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = true_context ++ "/Dockerfile",
        .data =
        \\FROM local/base:dev
        \\CMD ["/bin/true"]
        \\
        ,
    });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = false_context ++ "/Dockerfile",
        .data =
        \\FROM local/base:dev
        \\CMD ["/bin/false"]
        \\
        ,
    });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_dir);
    const init = testInit(allocator, io, &arena_state, &env);
    const cache_root = try local_paths.rootfsCacheRootPath(arena, &env);

    const base_preload = try rootfs_cas.preloadPath(io, arena, cache_root, base_rootfs, rootfs_cas.default_chunk_size);
    const base_storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, base_preload);
    _ = try rootfs_mod.publishIndexedImage(init, arena, .{
        .ref = "local/base:dev",
        .platform = .{},
        .rootfs_storage = base_storage,
    });

    var diagnostic: Diagnostic = .{};
    const true_result = try build(init, arena, .{
        .tag = "local/app:true",
        .context_dir = true_context,
        .dockerfile_path = true_context ++ "/Dockerfile",
        .platform = .{},
        .diagnostic = &diagnostic,
    });
    const false_result = try build(init, arena, .{
        .tag = "local/app:false",
        .context_dir = false_context,
        .dockerfile_path = false_context ++ "/Dockerfile",
        .platform = .{},
        .diagnostic = &diagnostic,
    });

    try std.testing.expectEqualStrings(base_storage.index_digest, true_result.index_digest);
    try std.testing.expectEqualStrings(base_storage.index_digest, false_result.index_digest);
    try std.testing.expect(!true_result.cache_hit);
    try std.testing.expect(!false_result.cache_hit);
    try std.testing.expect(!std.mem.eql(u8, true_result.resolved_image_ref, false_result.resolved_image_ref));

    const true_resolved = try rootfs_mod.resolveLocalCachedRef(io, arena, cache_root, true_result.resolved_image_ref, .{});
    const false_resolved = try rootfs_mod.resolveLocalCachedRef(io, arena, cache_root, false_result.resolved_image_ref, .{});
    const true_indexed = (try rootfs_mod.cachedImageIndexedRootfs(io, arena, cache_root, true_resolved)) orelse return error.MissingIndexedRootfs;
    defer rootfs_mod.deinitCachedIndexedRootfs(arena, true_indexed);
    const false_indexed = (try rootfs_mod.cachedImageIndexedRootfs(io, arena, cache_root, false_resolved)) orelse return error.MissingIndexedRootfs;
    defer rootfs_mod.deinitCachedIndexedRootfs(arena, false_indexed);
    try std.testing.expectEqualStrings(base_storage.index_digest, true_indexed.storage.index_digest);
    try std.testing.expectEqualStrings(base_storage.index_digest, false_indexed.storage.index_digest);

    const true_metadata = try readCachedMetadata(arena, io, true_result.metadata_path);
    const false_metadata = try readCachedMetadata(arena, io, false_result.metadata_path);
    try std.testing.expectEqualStrings("/bin/true", true_metadata.config.config.?.Cmd.?[0]);
    try std.testing.expectEqualStrings("/bin/false", false_metadata.config.config.?.Cmd.?[0]);
}

fn testInit(
    allocator: std.mem.Allocator,
    io: Io,
    arena: *std.heap.ArenaAllocator,
    env: *std.process.Environ.Map,
) std.process.Init {
    return .{
        .minimal = undefined,
        .arena = arena,
        .gpa = allocator,
        .io = io,
        .environ_map = env,
        .preopens = .empty,
    };
}
