const std = @import("std");
const Io = std.Io;

const dockerfile = @import("build/dockerfile.zig");
const build_context = @import("build/context.zig");
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

pub const NetworkMode = enum {
    spore,
    none,
};

pub const Options = struct {
    tag: []const u8,
    context_dir: []const u8,
    dockerfile_path: []const u8,
    platform: rootfs_mod.Platform = .{},
    build_contexts: []const BuildContextArg = &.{},
    build_args: []const BuildArg = &.{},
    network: NetworkMode = .spore,
    no_cache: bool = false,
    mkfs: ?[]const u8 = null,
    debugfs: ?[]const u8 = null,
    diagnostic: ?*Diagnostic = null,
};

pub const Diagnostic = struct {
    dockerfile: dockerfile.Diagnostic = .{},
    dockerignore: build_context.IgnoreDiagnostic = .{},
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

const ArgValue = struct {
    key: []const u8,
    value: ?[]const u8,
};

const CachedMetadata = struct {
    config: rootfs_mod.ImageConfig = .{},
    rootfs_storage: ?spore.RootfsStorage = null,
    rootfs_size: u64 = 0,
};

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

    var state: ?State = null;
    var pre_from_args = std.array_list.Managed(ArgValue).init(allocator);
    var saw_from = false;
    var any_exec_step = false;
    for (doc.instructions) |instruction| {
        switch (instruction.value) {
            .arg => |arg| {
                if (!saw_from) {
                    try declareArg(allocator, options.build_args, null, &pre_from_args, arg);
                    continue;
                }
                if (state) |*s| {
                    try declareArg(allocator, options.build_args, pre_from_args.items, &s.args, arg);
                } else unreachable;
            },
            .from => |from| {
                if (saw_from) return error.UnsupportedMultiStageDockerfile;
                const source = try substitute(allocator, from.source, pre_from_args.items, &.{});
                const base = try resolveBase(init, allocator, options, source);
                if (!try rootfs_cas.storageCompleteWithStampRepair(init.io, allocator, base.cache_root, base.storage)) return error.RootFSDigestCacheMiss;
                state = try stateFromBase(allocator, base.config, base.storage);
                saw_from = true;
            },
            else => {
                if (!saw_from) return error.MissingDockerfileFrom;
                if (state) |*s| {
                    switch (instruction.value) {
                        .env => |env| {
                            for (env.pairs) |pair| {
                                const key = try substitute(allocator, pair.key, s.args.items, s.env.items);
                                const value = try substitute(allocator, pair.value, s.args.items, s.env.items);
                                try putEnv(allocator, &s.env, key, value);
                            }
                        },
                        .workdir => |raw| {
                            const substituted = try substitute(allocator, raw, s.args.items, s.env.items);
                            s.workdir = try resolveWorkdir(allocator, s.workdir, substituted);
                        },
                        .cmd => |cmd| {
                            s.cmd = try resolveCmd(allocator, cmd, s.args.items, s.env.items);
                        },
                        .run => {
                            any_exec_step = true;
                            s.storage = try cachedExecStep(init, allocator, options, s.*, instruction, "");
                        },
                        .copy => |copy| {
                            any_exec_step = true;
                            const resolved_sources = try substituteList(allocator, copy.sources, s.args.items, s.env.items);
                            const input_digest = try build_context.hashCopySources(allocator, init.io, ctx, resolved_sources);
                            s.storage = try cachedExecStep(init, allocator, options, s.*, instruction, input_digest);
                        },
                        else => unreachable,
                    }
                } else unreachable;
            },
        }
    }
    const final_state = state orelse return error.MissingDockerfileFrom;
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
        .cache_hit = any_exec_step,
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
    const key = try execStepKey(allocator, options, state, instruction, input_digest);
    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    const env_digest = try effectiveEnvDigest(allocator, state);
    return (try step_cache.readHit(init.io, allocator, cache_root, .{
        .platform = options.platform,
        .parent_index_digest = state.storage.index_digest,
        .instruction_kind = instructionKind(instruction),
        .canonical_instruction = instruction.raw,
        .input_digest = input_digest,
        .env_digest = env_digest,
        .workdir = state.workdir,
    }, key)) orelse error.CacheMissRequiresBuildExecutor;
}

fn execStepKey(allocator: std.mem.Allocator, options: Options, state: State, instruction: dockerfile.Instruction, input_digest: []const u8) ![]const u8 {
    const env_digest = try effectiveEnvDigest(allocator, state);
    return step_cache.stepKey(allocator, .{
        .platform = options.platform,
        .parent_index_digest = state.storage.index_digest,
        .instruction_kind = instructionKind(instruction),
        .canonical_instruction = instruction.raw,
        .input_digest = input_digest,
        .env_digest = env_digest,
        .workdir = state.workdir,
    });
}

fn effectiveEnvDigest(allocator: std.mem.Allocator, state: State) ![]const u8 {
    var arg_entries = std.array_list.Managed([]const u8).init(allocator);
    for (state.args.items) |arg| {
        const value = arg.value orelse "";
        try arg_entries.append(try std.fmt.allocPrint(allocator, "{s}={s}", .{ arg.key, value }));
    }
    return step_cache.envDigest(allocator, state.env.items, arg_entries.items);
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

test "variable substitution uses env before args" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try substitute(arena, "${APP}/$MODE", &.{.{ .key = "MODE", .value = "arg" }}, &.{"APP=/srv"});
    try std.testing.expectEqualStrings("/srv/arg", got);
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
        .instruction_kind = "RUN",
        .canonical_instruction = "RUN echo cached",
        .env_digest = env_digest,
        .workdir = "/",
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
