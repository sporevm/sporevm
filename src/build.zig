const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const dockerfile = @import("build/dockerfile.zig");
const build_context = @import("build/context.zig");
const build_context_disk = @import("build/context_disk.zig");
const build_exec = @import("build/exec.zig");
const build_plan = @import("build/plan.zig");
const variable_expansion = @import("build/variables.zig");
const step_cache = @import("build/step_cache.zig");
const disk_index = @import("disk_index.zig");
const local_paths = @import("local_paths.zig");
const memory_config = @import("memory.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const rootfs_mod = @import("rootfs.zig");
const ext4 = @import("rootfs/ext4.zig");
const ext4_writer = @import("rootfs/ext4_writer.zig");
const run_mod = @import("run.zig");
const spore = @import("spore.zig");
const system_mod = @import("system.zig");
const test_barrier = @import("test_barrier.zig");
const topology = @import("topology.zig");

const scratch_inode_count: u32 = 131_072;
const scratch_format_identity = "sporevm-empty-ext4-scratch-v2:image=16GiB:inodes=131072:writer=ext4-sparse-spans-v1";
const default_linux_path = "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
const default_root_run_home_value = "/root";
const default_root_run_home = "HOME=" ++ default_root_run_home_value;

pub const testing = if (builtin.is_test) struct {
    pub var before_final_publish_barrier: ?*test_barrier.Barrier = null;
} else struct {};

pub const BuildContextArg = struct {
    name: []const u8,
    oci_layout_path: []const u8,
};

pub const BuildArg = struct {
    key: []const u8,
    value: []const u8,
};

pub const NetworkMode = step_cache.NetworkMode;
pub const NofileLimit = build_exec.NofileLimit;
pub const default_build_memory = build_exec.default_build_memory;
pub const default_build_vcpus = build_exec.default_build_vcpus;
pub const default_step_timeout_ms = build_exec.default_step_timeout_ms;
pub const default_build_nofile = build_exec.default_build_nofile;
pub const max_build_nofile = build_exec.max_build_nofile;
pub const max_run_command_len = build_exec.max_run_command_len;
pub const max_guest_envc = build_exec.max_guest_envc;
pub const max_guest_env_len = build_exec.max_guest_env_len;
pub const max_guest_working_dir_len = build_exec.max_guest_working_dir_len;

pub const Options = struct {
    tag: []const u8,
    context_dir: []const u8,
    dockerfile_path: []const u8,
    platform: rootfs_mod.Platform = .{},
    target: ?[]const u8 = null,
    build_contexts: []const BuildContextArg = &.{},
    build_args: []const BuildArg = &.{},
    network: NetworkMode = .spore,
    no_cache: bool = false,
    memory: memory_config.Config = default_build_memory,
    vcpus: topology.VcpuCount = default_build_vcpus,
    nofile: NofileLimit = default_build_nofile,
    timeout_ms: u64 = default_step_timeout_ms,
    spore_executable: []const u8 = "spore",
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
    scratch: ScratchDiagnostic = .{},
    instruction_line: usize = 0,
    limit: u64 = 0,
    actual: u64 = 0,
    missing_input: ?MissingInput = null,
};

pub const MissingInput = struct {
    kind: Kind,
    path: []const u8,

    pub const Kind = enum { dockerfile, context, base };
};

pub const ScratchDiagnostic = struct {
    created: u64 = 0,
    reused: u64 = 0,
    resolve_ns: u64 = 0,
    logical_size: u64 = 0,
    first_emit_map_bytes: u64 = 0,
    first_counted_emitter_buffers_bytes: u64 = 0,
    first_temp_allocated_bytes: u64 = 0,
    first_object_bytes_written: u64 = 0,
    first_nonzero_chunks: u64 = 0,
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
    disk_grow_target: u64 = 0,
    producer: ?build_exec.Producer = null,
    env: std.array_list.Managed([]const u8),
    args: std.array_list.Managed(ArgValue),
    // BuildKit applies ARG values to effective LLB state without publishing
    // them in image Config.Env. PATH needs this provenance because every stage
    // also carries a published builder-default PATH.
    path_arg_override: ?[]const u8 = null,
    // BuildKit keeps ARG values in effective build state without publishing
    // them in image Config.Env. HOME needs the same instruction-order
    // provenance so root RUN can additionally normalize absent/empty values.
    home_arg_override: ?[]const u8 = null,
    workdir: []const u8 = "/",
    entrypoint: ?[]const []const u8 = null,
    cmd: ?[]const []const u8 = null,
    user: ?[]const u8 = null,
    cmd_set: bool = false,
};

const StageArtifact = struct {
    storage: spore.RootfsStorage,
    config: rootfs_mod.ImageConfig,
    args: []const ArgValue = &.{},
    path_arg_override: ?[]const u8 = null,
    home_arg_override: ?[]const u8 = null,
};

const StageCopyBinding = struct {
    instruction_index: usize,
    input_index: usize,
    storage: spore.RootfsStorage,
};

const StageInputs = struct {
    bindings: []const StageCopyBinding,
    rootfs: []const spore.Rootfs,
};

const ArgValue = step_cache.ArgInput;

const CachedMetadata = struct {
    config: rootfs_mod.ImageConfig = .{},
    rootfs_storage: ?spore.RootfsStorage = null,
    rootfs_size: u64 = 0,
};

const automatic_build_capacity_bytes: u64 = 16 * 1024 * 1024 * 1024;

pub fn build(init: std.process.Init, allocator: std.mem.Allocator, options: Options) !Result {
    var local_diagnostic: Diagnostic = .{};
    const diagnostic = options.diagnostic orelse &local_diagnostic;
    diagnostic.* = .{};

    const dockerfile_bytes = Io.Dir.cwd().readFileAlloc(init.io, options.dockerfile_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            diagnostic.missing_input = .{ .kind = .dockerfile, .path = options.dockerfile_path };
            return error.BuildInputNotFound;
        },
        else => |e| return e,
    };
    const doc = dockerfile.parse(allocator, dockerfile_bytes, &diagnostic.dockerfile) catch |err| switch (err) {
        error.DockerfileParseFailed => return error.DockerfileParseFailed,
        else => |e| return e,
    };
    const global_args = try globalBuildArgs(allocator, options, doc.global_args);
    const variables = try plannerVariables(allocator, global_args.items);
    const plan = build_plan.create(allocator, &doc, .{
        .target = options.target,
        .variables = variables,
    }, &diagnostic.dockerfile) catch |err| switch (err) {
        error.DockerfilePlanFailed => return error.DockerfilePlanFailed,
        else => |e| return e,
    };
    for (plan.order) |stage_index| {
        const stage = plan.stages[stage_index];
        if (stage.platform) |platform| {
            if (!std.mem.eql(u8, platform, "linux/arm64")) {
                diagnostic.dockerfile = .{ .line = stage.source.from.line, .message = "spore build currently supports only FROM --platform=linux/arm64" };
                return error.DockerfilePlanFailed;
            }
        }
    }

    var context_dir = Io.Dir.cwd().openDir(init.io, options.context_dir, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            diagnostic.missing_input = .{ .kind = .context, .path = options.context_dir };
            return error.BuildInputNotFound;
        },
        else => |e| return e,
    };
    context_dir.close(init.io);

    const ctx = build_context.load(allocator, init.io, options.context_dir, &diagnostic.dockerignore) catch |err| switch (err) {
        error.FileNotFound => {
            diagnostic.missing_input = .{ .kind = .context, .path = options.context_dir };
            return error.BuildInputNotFound;
        },
        error.UnsupportedDockerignorePattern => return error.UnsupportedDockerignorePattern,
        else => |e| return e,
    };
    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    var cache_lock: ?rootfs_mod.RootfsCacheLock = null;
    defer if (cache_lock) |*lock| lock.deinit();

    // Resolve reachable external inputs before taking the coarse cache lock;
    // imports may take the same lock internally.
    const resolved_bases = try allocator.alloc(?Base, plan.stages.len);
    @memset(resolved_bases, null);
    const resolved_copy_bases = try allocator.alloc([]?Base, plan.stages.len);
    for (plan.stages, 0..) |stage, stage_index| {
        resolved_copy_bases[stage_index] = try allocator.alloc(?Base, stage.copies.len);
        @memset(resolved_copy_bases[stage_index], null);
    }
    for (plan.order) |stage_index| switch (plan.stages[stage_index].base) {
        .external => |source| resolved_bases[stage_index] = resolveBase(init, allocator, options, source) catch |err| switch (err) {
            error.FileNotFound => {
                diagnostic.missing_input = .{ .kind = .base, .path = source };
                return error.BuildInputNotFound;
            },
            else => |e| return e,
        },
        else => {},
    };
    for (plan.order) |stage_index| {
        for (plan.stages[stage_index].copies, 0..) |copy, copy_index| switch (copy.source) {
            .external => |source| resolved_copy_bases[stage_index][copy_index] = resolveBase(init, allocator, options, source) catch |err| switch (err) {
                error.FileNotFound => {
                    diagnostic.missing_input = .{ .kind = .base, .path = source };
                    return error.BuildInputNotFound;
                },
                else => |e| return e,
            },
            else => {},
        };
    }
    cache_lock = try rootfs_mod.lockRootfsCacheExclusive(init.io, allocator, cache_root);
    const build_cache_lock = if (cache_lock) |*lock| lock else unreachable;
    // Register this defer after the lock defer: LIFO then guarantees every
    // stat-cache save completes before the shared cache authority is released.
    var stat_cache = build_context.StatCache.load(allocator, init.io, cache_root, &diagnostic.context_hash);
    defer stat_cache.save(&diagnostic.context_hash);

    // Imports and local-ref resolution happen before the coarse lock. Validate
    // every resulting authority once inside the lock epoch so GC cannot remove
    // an external base or COPY --from input before execution/publication.
    for (plan.order) |stage_index| {
        if (resolved_bases[stage_index]) |base| {
            if (!try rootfs_cas.storageCompleteWithStampRepair(init.io, allocator, base.cache_root, base.storage)) return error.RootFSDigestCacheMiss;
        }
        for (resolved_copy_bases[stage_index]) |maybe_base| if (maybe_base) |base| {
            if (!try rootfs_cas.storageCompleteWithStampRepair(init.io, allocator, base.cache_root, base.storage)) return error.RootFSDigestCacheMiss;
        };
    }

    const artifacts = try allocator.alloc(?StageArtifact, plan.stages.len);
    @memset(artifacts, null);
    var shared_producer: ?build_exec.Producer = null;
    var any_exec_step = false;
    for (plan.order) |stage_index| {
        const planned_stage = plan.stages[stage_index];
        const base_artifact: StageArtifact = switch (planned_stage.base) {
            .external => blk: {
                const base = resolved_bases[stage_index] orelse return error.BadManifest;
                break :blk .{ .storage = base.storage, .config = base.config };
            },
            .stage => |dependency| artifacts[dependency] orelse return error.BadManifest,
            .scratch => try scratchArtifact(init, allocator, cache_root, options.platform, &diagnostic.scratch),
        };
        var state = try stateFromBase(allocator, base_artifact.config, base_artifact.storage, base_artifact.args, try buildDiskGrowTarget(base_artifact.storage));
        state.path_arg_override = base_artifact.path_arg_override;
        state.home_arg_override = base_artifact.home_arg_override;
        state.producer = shared_producer;
        const stage_inputs = try prepareStageInputs(allocator, diagnostic, planned_stage, artifacts, resolved_copy_bases[stage_index]);
        const built = try buildStage(init, allocator, options, diagnostic, ctx, &stat_cache, global_args.items, planned_stage.source.instructions, stage_inputs, state, build_cache_lock);
        state = built.state;
        if (shared_producer == null) shared_producer = state.producer;
        any_exec_step = any_exec_step or built.has_exec_step;
        artifacts[stage_index] = .{
            .storage = try spore.cloneRootfsStorage(allocator, state.storage),
            .config = try imageConfig(allocator, options.platform, state),
            .args = try cloneArgs(allocator, state.args.items),
            .path_arg_override = state.path_arg_override,
            .home_arg_override = state.home_arg_override,
        };
    }
    const final_artifact = artifacts[plan.target_index] orelse return error.BadManifest;
    if (comptime builtin.is_test) if (testing.before_final_publish_barrier) |barrier| barrier.pause(init.io);
    // Keep the exclusive cache lock through local-ref publication so every
    // PREPARE/step root and its destination ref become reachable in one GC
    // exclusion window.
    const publish = try rootfs_mod.publishIndexedImageWithCacheLockHeld(init.io, allocator, cache_root, .{
        .ref = options.tag,
        .platform = options.platform,
        .config = final_artifact.config,
        .rootfs_storage = final_artifact.storage,
    });
    if (any_exec_step) {
        std.log.info(
            "build boot artifact metrics: file_reads={d} bytes_read={d}",
            .{ diagnostic.executor.boot_artifact_file_reads, diagnostic.executor.boot_artifact_bytes_read },
        );
    }
    return .{
        .resolved_image_ref = publish.resolved_image_ref,
        .index_digest = publish.rootfs_storage.index_digest,
        .metadata_path = publish.metadata_path,
        .local_ref_path = publish.local_ref_path,
        .cache_hit = any_exec_step and diagnostic.executor.executed_steps == 0,
    };
}

const BuiltStage = struct {
    state: State,
    has_exec_step: bool,
};

fn prepareStageInputs(
    allocator: std.mem.Allocator,
    diagnostic: *Diagnostic,
    planned_stage: build_plan.Stage,
    artifacts: []const ?StageArtifact,
    resolved_copies: []const ?Base,
) !StageInputs {
    var bindings = std.array_list.Managed(StageCopyBinding).init(allocator);
    var storages = std.array_list.Managed(spore.RootfsStorage).init(allocator);
    for (planned_stage.copies, 0..) |copy, copy_index| {
        const storage = switch (copy.source) {
            .context => continue,
            .stage => |stage_index| (artifacts[stage_index] orelse return error.BadManifest).storage,
            .external => (resolved_copies[copy_index] orelse return error.BadManifest).storage,
        };
        var input_index: ?usize = null;
        for (storages.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing.index_digest, storage.index_digest)) {
                input_index = index;
                break;
            }
        }
        if (input_index == null) {
            if (storages.items.len >= build_exec.max_build_input_disks) {
                diagnostic.instruction_line = planned_stage.source.instructions[copy.instruction_index].line;
                diagnostic.limit = build_exec.max_build_input_disks;
                diagnostic.actual = storages.items.len + 1;
                return error.TooManyBuildInputDisks;
            }
            try storages.append(try spore.cloneRootfsStorage(allocator, storage));
            input_index = storages.items.len - 1;
        }
        try bindings.append(.{
            .instruction_index = copy.instruction_index,
            .input_index = input_index.?,
            .storage = try spore.cloneRootfsStorage(allocator, storage),
        });
    }
    const input_rootfs = try allocator.alloc(spore.Rootfs, storages.items.len);
    for (storages.items, 0..) |storage, index| input_rootfs[index] = try build_exec.rootfsFromStorage(allocator, storage);
    return .{ .bindings = try bindings.toOwnedSlice(), .rootfs = input_rootfs };
}

fn buildStage(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: Options,
    diagnostic: *Diagnostic,
    ctx: build_context.BuildContext,
    stat_cache: *build_context.StatCache,
    global_args: []const ArgValue,
    instructions: []const dockerfile.Instruction,
    stage_inputs: StageInputs,
    initial_state: State,
    rootfs_cache_lock: *const rootfs_mod.RootfsCacheLock,
) !BuiltStage {
    var state = initial_state;
    var has_exec_step = false;
    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    stage_instructions: for (instructions, 0..) |instruction, index| {
        if (try applyMetadataInstruction(allocator, options, global_args, &state, instruction)) continue;
        if (!rootUser(state.user)) {
            diagnostic.instruction_line = instruction.line;
            return error.UnsupportedBuildUser;
        }
        if (instruction.value == .copy) {
            const copy = instruction.value.copy;
            if (copy.from != null) {
                const binding = findStageCopyBinding(stage_inputs.bindings, index) orelse return error.BadManifest;
                _ = stageCopyStep(allocator, state, instruction, copy, binding) catch |err| {
                    diagnostic.instruction_line = instruction.line;
                    return err;
                };
            }
        }
        has_exec_step = true;
        if (try ensurePrepared(init, allocator, options.platform, cache_root, &state, &diagnostic.executor)) |preparation| {
            state = try executeFromMiss(init, allocator, options, diagnostic, ctx, stat_cache, global_args, instructions[index..], stage_inputs, index, state, rootfs_cache_lock, preparation);
            break :stage_instructions;
        }
        switch (instruction.value) {
            .run => {
                state.storage = cachedExecStep(init, allocator, options, state, instruction, "") catch |err| switch (err) {
                    error.CacheMissRequiresBuildExecutor => {
                        state = try executeFromMiss(init, allocator, options, diagnostic, ctx, stat_cache, global_args, instructions[index..], stage_inputs, index, state, rootfs_cache_lock, null);
                        break :stage_instructions;
                    },
                    else => |e| return e,
                };
            },
            .copy => |copy| {
                const input_digest = if (copy.from != null)
                    (findStageCopyBinding(stage_inputs.bindings, index) orelse return error.BadManifest).storage.index_digest
                else blk: {
                    const resolved_sources = try substituteStateList(allocator, copy.sources, state);
                    const resolution = build_context.resolveCopySourcesWithDiagnostic(allocator, init.io, ctx, resolved_sources, &diagnostic.copy) catch |err| {
                        diagnostic.instruction_line = instruction.line;
                        return err;
                    };
                    break :blk try build_context.hashCopyResolutionWithOptions(allocator, init.io, ctx, resolution, .{
                        .stat_cache = stat_cache,
                        .diagnostic = &diagnostic.context_hash,
                    });
                };
                state.storage = cachedExecStep(init, allocator, options, state, instruction, input_digest) catch |err| switch (err) {
                    error.CacheMissRequiresBuildExecutor => {
                        state = try executeFromMiss(init, allocator, options, diagnostic, ctx, stat_cache, global_args, instructions[index..], stage_inputs, index, state, rootfs_cache_lock, null);
                        break :stage_instructions;
                    },
                    else => |e| return e,
                };
            },
            .workdir => |raw| {
                const target = try resolvedWorkdir(allocator, state, raw);
                state.storage = cachedExecStep(init, allocator, options, state, instruction, "") catch |err| switch (err) {
                    error.CacheMissRequiresBuildExecutor => {
                        state = try executeFromMiss(init, allocator, options, diagnostic, ctx, stat_cache, global_args, instructions[index..], stage_inputs, index, state, rootfs_cache_lock, null);
                        break :stage_instructions;
                    },
                    else => |e| return e,
                };
                state.workdir = target;
            },
            .from => unreachable,
            else => unreachable,
        }
    }
    return .{ .state = state, .has_exec_step = has_exec_step };
}

fn findStageCopyBinding(bindings: []const StageCopyBinding, instruction_index: usize) ?StageCopyBinding {
    for (bindings) |binding| if (binding.instruction_index == instruction_index) return binding;
    return null;
}

fn globalBuildArgs(
    allocator: std.mem.Allocator,
    options: Options,
    instructions: []const dockerfile.Instruction,
) !std.array_list.Managed(ArgValue) {
    var args = std.array_list.Managed(ArgValue).init(allocator);
    const automatic = [_]ArgValue{
        .{ .key = "BUILDPLATFORM", .value = "linux/arm64" },
        .{ .key = "BUILDOS", .value = "linux" },
        .{ .key = "BUILDARCH", .value = "arm64" },
        .{ .key = "BUILDVARIANT", .value = "" },
        .{ .key = "TARGETPLATFORM", .value = "linux/arm64" },
        .{ .key = "TARGETOS", .value = "linux" },
        .{ .key = "TARGETARCH", .value = "arm64" },
        .{ .key = "TARGETVARIANT", .value = "" },
    };
    for (automatic) |arg| try putArg(allocator, &args, arg.key, arg.value);
    for (instructions) |instruction| {
        const arg = instruction.value.arg;
        const value = if (findBuildArg(options.build_args, arg.key)) |cli|
            cli.value
        else if (arg.default) |default|
            try substitute(allocator, default, args.items, &.{})
        else
            lookupArg(arg.key, args.items);
        try putArg(allocator, &args, arg.key, value);
    }
    return args;
}

fn plannerVariables(allocator: std.mem.Allocator, args: []const ArgValue) ![]const build_plan.Variable {
    var variables = std.array_list.Managed(build_plan.Variable).init(allocator);
    for (args) |arg| if (arg.value) |value| try variables.append(.{ .key = arg.key, .value = value });
    return variables.toOwnedSlice();
}

fn rootUser(user: ?[]const u8) bool {
    const value = user orelse return true;
    if (value.len == 0 or std.mem.eql(u8, value, "root") or std.mem.eql(u8, value, "0")) return true;
    return std.mem.startsWith(u8, value, "0:");
}

fn scratchArtifact(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    platform: rootfs_mod.Platform,
    diagnostic: *ScratchDiagnostic,
) !StageArtifact {
    const start_ns = monotonicNs() catch 0;
    defer diagnostic.resolve_ns +|= elapsedNs(start_ns);
    diagnostic.logical_size = automatic_build_capacity_bytes;
    const input = try step_cache.scratchInput(platform, automatic_build_capacity_bytes, scratch_format_identity);
    const key = try step_cache.stepKey(allocator, input);
    if (try step_cache.readHit(init.io, allocator, cache_root, input, key)) |storage| {
        diagnostic.reused += 1;
        return .{
            .storage = storage,
            .config = .{ .architecture = platform.arch, .os = platform.os, .config = .{} },
        };
    }

    var nonce_bytes: [8]u8 = undefined;
    init.io.random(&nonce_bytes);
    const nonce = std.mem.readInt(u64, &nonce_bytes, .little);
    const path = try std.fmt.allocPrint(allocator, "{s}/spore-build-scratch-{d}-{x}.ext4", .{ cache_root, std.c.getpid(), nonce });
    defer Io.Dir.cwd().deleteFile(init.io, path) catch {};
    const emitted = try ext4_writer.emit(allocator, init.io, path, &.{}, .{
        .image_size = automatic_build_capacity_bytes,
        // Covers the 65,536-entry COPY traversal envelope plus files and
        // directories created by subsequent Dockerfile operations.
        .inode_count = scratch_inode_count,
        .determinism = ext4.Determinism.fromDigest("sha256:spore-build-scratch-v2"),
        .cas_cache_root = cache_root,
        .cas_chunk_size = rootfs_cas.default_chunk_size,
        .cas_seal_workers = 1,
    });
    diagnostic.first_emit_map_bytes = emitted.profile.emit_map_bytes;
    diagnostic.first_counted_emitter_buffers_bytes = emitted.profile.counted_emitter_buffers_bytes;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const temp_fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (temp_fd < 0) return error.IoFailed;
    defer _ = std.c.close(temp_fd);
    diagnostic.first_temp_allocated_bytes = try allocatedFileBlocks512(temp_fd) * 512;
    const preload = emitted.preload_result orelse return error.BadManifest;
    diagnostic.first_object_bytes_written = preload.object_bytes_written;
    diagnostic.first_nonzero_chunks = preload.nonzero_chunks;
    std.log.info(
        "scratch artifact metrics: logical_bytes={d} emit_map_bytes={d} counted_emitter_buffers_bytes={d} temp_allocated_bytes={d} nonzero_chunks={d} object_bytes_written={d} resolve_ms={d}",
        .{
            automatic_build_capacity_bytes,
            diagnostic.first_emit_map_bytes,
            diagnostic.first_counted_emitter_buffers_bytes,
            diagnostic.first_temp_allocated_bytes,
            diagnostic.first_nonzero_chunks,
            diagnostic.first_object_bytes_written,
            elapsedNs(start_ns) / std.time.ns_per_ms,
        },
    );
    const storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload);
    try rootfs_cas.markStorageComplete(init.io, allocator, cache_root, storage.index_digest);
    _ = try step_cache.writeRecord(init.io, allocator, cache_root, input, key, storage);
    diagnostic.created += 1;
    return .{
        .storage = storage,
        .config = .{ .architecture = platform.arch, .os = platform.os, .config = .{} },
    };
}

fn allocatedFileBlocks512(fd: std.c.fd_t) !u64 {
    return switch (builtin.os.tag) {
        .linux => blk: {
            var stat: std.os.linux.Statx = undefined;
            const requested: std.os.linux.STATX = .{ .BLOCKS = true };
            if (std.c.statx(fd, "", std.c.AT.EMPTY_PATH, requested, &stat) != 0) return error.IoFailed;
            if (!stat.mask.BLOCKS) return error.IoFailed;
            break :blk stat.blocks;
        },
        .macos => blk: {
            var stat: std.c.Stat = undefined;
            if (std.c.fstat(fd, &stat) != 0 or stat.blocks < 0) return error.IoFailed;
            break :blk @intCast(stat.blocks);
        },
        else => @compileError("spore build scratch allocation accounting requires Linux statx or Darwin fstat"),
    };
}

fn monotonicNs() !u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return error.ClockUnavailable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn elapsedNs(start: u64) u64 {
    if (start == 0) return 0;
    const now = monotonicNs() catch return 0;
    return now -| start;
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
    const image_ref = try normalizeBuildImageRef(allocator, source);
    const resolved = try run_mod.resolveRootfsInputDetailed(init, allocator, .{
        .rootfs_path = null,
        .image_ref = image_ref,
        .command_name = "build",
        .record_artifact = true,
    });
    const rootfs = resolved.rootfs orelse return error.RootFSDigestCacheMiss;
    const storage = rootfs.storage orelse return error.RootFSDigestCacheMiss;
    if (!try rootfs_cas.storageCompleteWithStampRepair(init.io, allocator, cache_root, storage)) return error.RootFSDigestCacheMiss;
    return .{
        .cache_root = cache_root,
        .storage = storage,
        .config = resolved.image_config orelse .{ .architecture = options.platform.arch, .os = options.platform.os },
    };
}

fn normalizeBuildImageRef(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    if (rootfs_mod.isLocalImageRef(source)) return source;
    const first_slash = std.mem.indexOfScalar(u8, source, '/');
    const first_component = if (first_slash) |slash| source[0..slash] else source;
    const explicit_registry = first_slash != null and (std.mem.indexOfScalar(u8, first_component, '.') != null or
        std.mem.indexOfScalar(u8, first_component, ':') != null or
        std.mem.eql(u8, first_component, "localhost"));
    const source_last_slash = std.mem.lastIndexOfScalar(u8, source, '/') orelse 0;
    const has_reference = std.mem.indexOfScalar(u8, source, '@') != null or
        std.mem.indexOfScalarPos(u8, source, source_last_slash, ':') != null;
    const suffix: []const u8 = if (has_reference) "" else ":latest";
    if (explicit_registry) return std.fmt.allocPrint(allocator, "{s}{s}", .{ source, suffix });
    if (first_slash == null) return std.fmt.allocPrint(allocator, "docker.io/library/{s}{s}", .{ source, suffix });
    return std.fmt.allocPrint(allocator, "docker.io/{s}{s}", .{ source, suffix });
}

fn stateFromBase(allocator: std.mem.Allocator, config: rootfs_mod.ImageConfig, storage: spore.RootfsStorage, inherited_args: []const ArgValue, disk_grow_target: u64) !State {
    var env = std.array_list.Managed([]const u8).init(allocator);
    var args = std.array_list.Managed(ArgValue).init(allocator);
    for (inherited_args) |arg| try args.append(.{
        .key = try allocator.dupe(u8, arg.key),
        .value = if (arg.value) |value| try allocator.dupe(u8, value) else null,
    });
    if (config.config) |runtime| {
        if (runtime.OnBuild) |triggers| if (triggers.len != 0) return error.UnsupportedOnBuild;
        if (runtime.Env) |entries| for (entries) |entry| try env.append(try allocator.dupe(u8, entry));
        if (!envContainsKey(env.items, "PATH")) try env.append(default_linux_path);
        return .{
            .storage = try spore.cloneRootfsStorage(allocator, storage),
            .disk_grow_target = disk_grow_target,
            .env = env,
            .args = args,
            .workdir = if (runtime.WorkingDir) |dir| if (dir.len == 0) "/" else try allocator.dupe(u8, dir) else "/",
            .entrypoint = if (runtime.Entrypoint) |entrypoint| try cloneStringList(allocator, entrypoint) else null,
            .cmd = if (runtime.Cmd) |cmd| try cloneStringList(allocator, cmd) else null,
            .user = if (runtime.User) |user| try allocator.dupe(u8, user) else null,
        };
    }
    try env.append(default_linux_path);
    return .{ .storage = try spore.cloneRootfsStorage(allocator, storage), .disk_grow_target = disk_grow_target, .env = env, .args = args };
}

fn cloneArgs(allocator: std.mem.Allocator, args: []const ArgValue) ![]const ArgValue {
    const cloned = try allocator.alloc(ArgValue, args.len);
    for (args, cloned) |arg, *dest| dest.* = .{
        .key = try allocator.dupe(u8, arg.key),
        .value = if (arg.value) |value| try allocator.dupe(u8, value) else null,
    };
    return cloned;
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
                const key = try substituteState(allocator, pair.key, state.*);
                const value = try substituteState(allocator, pair.value, state.*);
                try putEnv(allocator, &state.env, key, value);
                if (std.mem.eql(u8, key, "PATH")) state.path_arg_override = null;
                if (std.mem.eql(u8, key, "HOME")) state.home_arg_override = null;
            }
        },
        .cmd => |cmd| {
            state.cmd = try resolveCmd(allocator, cmd);
            state.cmd_set = true;
        },
        .entrypoint => |entrypoint| {
            state.entrypoint = try resolveCmd(allocator, entrypoint);
            // Docker clears an inherited CMD when ENTRYPOINT changes unless
            // this stage has already supplied its own CMD.
            if (!state.cmd_set) state.cmd = null;
        },
        .arg => |arg| {
            try declareArg(allocator, options.build_args, pre_from_args, &state.args, arg);
            if (std.mem.eql(u8, arg.key, "PATH")) state.path_arg_override = lookupArg("PATH", state.args.items);
            if (std.mem.eql(u8, arg.key, "HOME")) state.home_arg_override = lookupArg("HOME", state.args.items);
        },
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
    else if (lookupArg(arg.key, args.items)) |inherited|
        inherited
    else if (fallback_args) |fallback|
        lookupArg(arg.key, fallback)
    else
        null;
    try putArg(allocator, args, arg.key, value);
}

fn ensurePrepared(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    platform: rootfs_mod.Platform,
    cache_root: []const u8,
    state: *State,
    diagnostic: *build_exec.Diagnostic,
) !?build_exec.Preparation {
    if (state.producer == null) {
        state.producer = try build_exec.resolveProducer(init, allocator);
        diagnostic.boot_artifact_file_reads += state.producer.?.eager_artifact_file_reads;
        diagnostic.boot_artifact_bytes_read += state.producer.?.eager_artifact_bytes_read;
    }
    const producer = state.producer.?;
    if (state.storage.logical_size >= state.disk_grow_target) return null;
    const input = try step_cache.prepareInput(
        platform,
        state.storage.index_digest,
        state.disk_grow_target,
        producer.identity,
    );
    const key = try step_cache.stepKey(allocator, input);
    if (try step_cache.readHit(init.io, allocator, cache_root, input, key)) |prepared| {
        try build_exec.validatePreparedStorage(state.storage, prepared, state.disk_grow_target);
        state.storage = prepared;
        return null;
    }
    return .{
        .input = input,
        .step_key = key,
        .exact_target = state.disk_grow_target,
    };
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
    const producer = state.producer orelse return error.BadManifest;
    const input = try execStepInput(allocator, options, state, instruction, input_digest, producer.identity);
    const key = try step_cache.stepKey(allocator, input);
    return (try step_cache.readHit(init.io, allocator, cache_root, input, key)) orelse error.CacheMissRequiresBuildExecutor;
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
    stage_inputs: StageInputs,
    instruction_offset: usize,
    initial_state: State,
    rootfs_cache_lock: *const rootfs_mod.RootfsCacheLock,
    pending_preparation: ?build_exec.Preparation,
) !State {
    var state = initial_state;
    var steps = std.array_list.Managed(build_exec.Step).init(allocator);
    var context_disk = build_context_disk.Builder.init(allocator);
    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    var context_snapshot: ?build_context.CopySnapshot = null;
    defer if (context_snapshot) |*snapshot| snapshot.deinit(init.io);
    for (instructions, 0..) |instruction, suffix_index| {
        if (try applyMetadataInstruction(allocator, options, pre_from_args, &state, instruction)) continue;
        switch (instruction.value) {
            .run => |run| try steps.append(.{ .run = try runStep(allocator, diagnostic, state, instruction, run, options) }),
            .copy => |copy| {
                if (copy.from != null) {
                    const binding = findStageCopyBinding(stage_inputs.bindings, instruction_offset + suffix_index) orelse return error.BadManifest;
                    const step = stageCopyStep(allocator, state, instruction, copy, binding) catch |err| {
                        diagnostic.instruction_line = instruction.line;
                        return err;
                    };
                    try steps.append(.{ .copy = step });
                } else {
                    if (context_snapshot == null) context_snapshot = try build_context.CopySnapshot.init(allocator, init.io, cache_root);
                    if (context_snapshot) |*snapshot| {
                        try steps.append(.{ .copy = try copyStep(allocator, init.io, ctx, stat_cache, snapshot, &context_disk, diagnostic, state, instruction, copy) });
                    } else unreachable;
                }
            },
            .workdir => |raw| {
                const step = try workdirStep(allocator, state, instruction, raw);
                try steps.append(.{ .workdir = step });
                state.workdir = step.target;
            },
            .from => return error.UnsupportedMultiStageDockerfile,
            else => unreachable,
        }
    }

    if (context_snapshot) |*snapshot| try snapshot.seal(init.io);
    const context_disk_path = try context_disk.emitOrReuse(init.io, cache_root, &diagnostic.context_disk);
    if (context_snapshot) |*snapshot| snapshot.deinit(init.io);
    context_snapshot = null;
    const previous_executor = diagnostic.executor;
    state.storage = build_exec.runSession(init, allocator, .{
        .platform = options.platform,
        .cache_root = cache_root,
        .base_storage = state.storage,
        .steps = steps.items,
        .rootfs_cache_lock = rootfs_cache_lock,
        .preparation = pending_preparation,
        .producer = state.producer orelse return error.BadManifest,
        .context_disk_path = context_disk_path,
        .build_input_rootfs = stage_inputs.rootfs,
        .resources = runResources(options),
        .timeout_ms = options.timeout_ms,
        .spore_executable = options.spore_executable,
        .output = options.output,
        .diagnostic = &diagnostic.executor,
    }) catch |err| {
        accumulateExecutorDiagnostic(&diagnostic.executor, previous_executor);
        return err;
    };
    accumulateExecutorDiagnostic(&diagnostic.executor, previous_executor);
    return state;
}

fn accumulateExecutorDiagnostic(current: *build_exec.Diagnostic, previous: build_exec.Diagnostic) void {
    current.executed_steps += previous.executed_steps;
    current.boot_count += previous.boot_count;
    current.resize_count += previous.resize_count;
    current.boot_artifact_file_reads += previous.boot_artifact_file_reads;
    current.boot_artifact_bytes_read += previous.boot_artifact_bytes_read;
    current.max_checkpoint_control_ms = @max(current.max_checkpoint_control_ms, previous.max_checkpoint_control_ms);
}

test "executor diagnostics aggregate artifact reads across sessions" {
    var current = build_exec.Diagnostic{
        .executed_steps = 3,
        .boot_count = 2,
        .resize_count = 1,
        .boot_artifact_file_reads = 4,
        .boot_artifact_bytes_read = 400,
        .max_checkpoint_control_ms = 7,
    };
    accumulateExecutorDiagnostic(&current, .{
        .executed_steps = 5,
        .boot_count = 6,
        .resize_count = 2,
        .boot_artifact_file_reads = 8,
        .boot_artifact_bytes_read = 800,
        .max_checkpoint_control_ms = 11,
    });
    try std.testing.expectEqual(@as(usize, 8), current.executed_steps);
    try std.testing.expectEqual(@as(usize, 8), current.boot_count);
    try std.testing.expectEqual(@as(usize, 3), current.resize_count);
    try std.testing.expectEqual(@as(usize, 12), current.boot_artifact_file_reads);
    try std.testing.expectEqual(@as(usize, 1200), current.boot_artifact_bytes_read);
    try std.testing.expectEqual(@as(u64, 11), current.max_checkpoint_control_ms);
}

fn runStep(
    allocator: std.mem.Allocator,
    diagnostic: *Diagnostic,
    state: State,
    instruction: dockerfile.Instruction,
    run: dockerfile.Run,
    options: Options,
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
        .env_digest = try effectiveRunEnvDigest(allocator, state),
        .workdir = state.workdir,
        .network_mode = options.network,
    };
}

fn workdirStep(
    allocator: std.mem.Allocator,
    state: State,
    instruction: dockerfile.Instruction,
    raw: []const u8,
) !build_exec.WorkdirStep {
    return .{
        .line = instruction.line,
        .canonical_instruction = instruction.raw,
        .target = try resolvedWorkdir(allocator, state, raw),
        .env_digest = try effectiveEnvDigest(allocator, state),
        .workdir = state.workdir,
    };
}

fn resolvedWorkdir(allocator: std.mem.Allocator, state: State, raw: []const u8) ![]const u8 {
    const substituted = try substituteState(allocator, raw, state);
    return resolveWorkdir(allocator, state.workdir, substituted);
}

fn copyStep(
    allocator: std.mem.Allocator,
    io: Io,
    ctx: build_context.BuildContext,
    stat_cache: ?*build_context.StatCache,
    context_snapshot: *build_context.CopySnapshot,
    context_disk: *build_context_disk.Builder,
    diagnostic: *Diagnostic,
    state: State,
    instruction: dockerfile.Instruction,
    copy: dockerfile.Copy,
) !build_exec.CopyStep {
    const resolved_sources = try substituteStateList(allocator, copy.sources, state);
    const resolved_dest = try substituteState(allocator, copy.dest, state);
    const resolution = build_context.resolveCopySourcesWithDiagnostic(allocator, io, ctx, resolved_sources, &diagnostic.copy) catch |err| {
        diagnostic.instruction_line = instruction.line;
        return err;
    };
    const resolved_entries = try build_context.captureCopyResolutionWithOptions(allocator, io, ctx, resolution, .{
        .stat_cache = stat_cache,
        .diagnostic = &diagnostic.context_hash,
    }, context_snapshot);
    const input_digest = try build_context.hashResolvedCopyEntries(allocator, resolved_entries);
    const source_prefix = try context_disk.addCapturedCopy(resolved_entries);
    const dest_is_dir = copyDestIsDirectory(resolved_dest, resolution);
    if (resolution.roots.len > 1 and !copyDestEndsWithSlash(resolved_dest)) {
        diagnostic.instruction_line = instruction.line;
        return error.CopyDestinationMustBeDirectory;
    }
    const dest = try normalizeGuestPath(allocator, state.workdir, resolved_dest);
    const requests = try copyRequests(allocator, diagnostic, instruction.line, resolution, source_prefix, dest, dest_is_dir);
    return .{
        .line = instruction.line,
        .canonical_instruction = instruction.raw,
        .input_digest = input_digest,
        .env_digest = try effectiveEnvDigest(allocator, state),
        .workdir = state.workdir,
        .requests = requests,
    };
}

fn stageCopyStep(
    allocator: std.mem.Allocator,
    state: State,
    instruction: dockerfile.Instruction,
    copy: dockerfile.Copy,
    binding: StageCopyBinding,
) !build_exec.CopyStep {
    const resolved_sources = try substituteStateList(allocator, copy.sources, state);
    const resolved_dest = try substituteState(allocator, copy.dest, state);
    if (resolved_sources.len > 1 and !copyDestEndsWithSlash(resolved_dest)) return error.CopyDestinationMustBeDirectory;
    const dest = try normalizeGuestPath(allocator, state.workdir, resolved_dest);
    const requests = try allocator.alloc(build_exec.CopyRequest, resolved_sources.len);
    for (resolved_sources, 0..) |source, index| {
        requests[index] = .{
            .source = try normalizeStageCopySource(allocator, source),
            .dest = dest,
            .source_kind = .auto,
            .dest_is_dir = copyDestEndsWithSlash(resolved_dest) or resolved_sources.len > 1,
            .entry_count = 0,
            .source_disk = .build_input,
            .input_index = binding.input_index,
        };
    }
    return .{
        .line = instruction.line,
        .canonical_instruction = instruction.raw,
        .input_digest = binding.storage.index_digest,
        .env_digest = try effectiveEnvDigest(allocator, state),
        .workdir = state.workdir,
        .requests = requests,
    };
}

fn normalizeStageCopySource(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
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
    diagnostic: *Diagnostic,
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
            diagnostic.instruction_line = instruction_line;
            diagnostic.copy.source = root.rel;
            diagnostic.limit = build_exec.max_copy_entries;
            diagnostic.actual = entry_count;
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
    executor_identity: []const u8,
) !step_cache.StepInput {
    const env_digest = try effectiveEnvDigest(allocator, state);
    const step: build_exec.Step = switch (instruction.value) {
        .run => |run| .{ .run = .{
            .line = instruction.line,
            .canonical_instruction = instruction.raw,
            .command = run.shell,
            .env = &.{},
            .env_digest = try effectiveRunEnvDigest(allocator, state),
            .workdir = state.workdir,
            .network_mode = options.network,
        } },
        .copy => .{ .copy = .{
            .line = instruction.line,
            .canonical_instruction = instruction.raw,
            .input_digest = input_digest,
            .env_digest = env_digest,
            .workdir = state.workdir,
            .requests = &.{},
        } },
        .workdir => |raw| .{ .workdir = .{
            .line = instruction.line,
            .canonical_instruction = instruction.raw,
            .target = try resolvedWorkdir(allocator, state, raw),
            .env_digest = env_digest,
            .workdir = state.workdir,
        } },
        else => unreachable,
    };
    return build_exec.cacheInputForStep(
        options.platform,
        state.storage.index_digest,
        executor_identity,
        step,
        runResources(options),
    );
}

fn runResources(options: Options) build_exec.RunResources {
    return .{
        .memory = options.memory,
        .vcpus = options.vcpus,
        .nofile = options.nofile,
    };
}

fn buildDiskGrowTarget(storage: spore.RootfsStorage) !u64 {
    try spore.validateRootfsStorageDescriptor(storage);
    comptime std.debug.assert(automatic_build_capacity_bytes % spore.disk_chunk_size == 0);
    return @max(storage.logical_size, automatic_build_capacity_bytes);
}

fn effectiveEnvDigest(allocator: std.mem.Allocator, state: State) ![]const u8 {
    return step_cache.envDigest(allocator, try effectiveStateEnv(allocator, state), state.args.items);
}

fn effectiveRunEnvDigest(allocator: std.mem.Allocator, state: State) ![]const u8 {
    var env = std.array_list.Managed([]const u8).init(allocator);
    defer env.deinit();
    try env.appendSlice(try effectiveStateEnv(allocator, state));
    if (rootRunHomeUsesDefault(state)) try putEnv(allocator, &env, "HOME", default_root_run_home_value);
    return step_cache.envDigest(allocator, env.items, state.args.items);
}

fn runEnvironment(allocator: std.mem.Allocator, state: State) ![]const []const u8 {
    var entries = std.array_list.Managed([]const u8).init(allocator);
    try entries.appendSlice(try effectiveStateEnv(allocator, state));
    for (state.args.items) |arg| {
        const value = arg.value orelse continue;
        if (std.mem.eql(u8, arg.key, "HOME")) continue;
        if (envContainsKey(entries.items, arg.key)) continue;
        try entries.append(try std.fmt.allocPrint(allocator, "{s}={s}", .{ arg.key, value }));
    }
    try putEnv(allocator, &entries, "HOME", effectiveRootRunHome(state));
    return entries.toOwnedSlice();
}

fn effectiveStateEnv(allocator: std.mem.Allocator, state: State) ![]const []const u8 {
    var entries = std.array_list.Managed([]const u8).init(allocator);
    try entries.appendSlice(state.env.items);
    if (state.path_arg_override) |value| try putEnv(allocator, &entries, "PATH", value);
    if (state.home_arg_override) |value| try putEnv(allocator, &entries, "HOME", value);
    return entries.toOwnedSlice();
}

fn effectiveRootRunHome(state: State) []const u8 {
    if (state.home_arg_override) |value| return if (value.len == 0) default_root_run_home_value else value;
    if (envValue(state.env.items, "HOME")) |value| return if (value.len == 0) default_root_run_home_value else value;
    if (lookupArg("HOME", state.args.items)) |value| return if (value.len == 0) default_root_run_home_value else value;
    return default_root_run_home_value;
}

fn rootRunHomeUsesDefault(state: State) bool {
    if (state.home_arg_override) |value| return value.len == 0;
    if (envValue(state.env.items, "HOME")) |value| return value.len == 0;
    if (lookupArg("HOME", state.args.items)) |value| return value.len == 0;
    return true;
}

fn envValue(env: []const []const u8, key: []const u8) ?[]const u8 {
    for (env) |entry| {
        if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
            if (std.mem.eql(u8, entry[0..eq], key)) return entry[eq + 1 ..];
        }
    }
    return null;
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
    state: State,
) !rootfs_mod.ImageConfig {
    return .{
        .architecture = platform.arch,
        .os = platform.os,
        .config = .{
            .Env = try cloneStringList(allocator, state.env.items),
            .Entrypoint = if (state.entrypoint) |entries| try cloneStringList(allocator, entries) else null,
            .Cmd = if (state.cmd) |entries| try cloneStringList(allocator, entries) else null,
            .WorkingDir = state.workdir,
            .User = if (state.user) |user| try allocator.dupe(u8, user) else null,
        },
    };
}

fn resolveCmd(allocator: std.mem.Allocator, cmd: dockerfile.Cmd) ![]const []const u8 {
    switch (cmd) {
        .shell => |raw| return cloneStringList(allocator, &.{ "/bin/sh", "-c", raw }),
        .exec => |entries| return cloneStringList(allocator, entries),
    }
}

fn resolveWorkdir(allocator: std.mem.Allocator, current: []const u8, next: []const u8) ![]const u8 {
    return normalizeGuestPath(allocator, current, next);
}

fn substituteStateList(allocator: std.mem.Allocator, raw: []const []const u8, state: State) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, raw.len);
    for (raw, 0..) |entry, i| out[i] = try substituteState(allocator, entry, state);
    return out;
}

fn substituteState(allocator: std.mem.Allocator, input: []const u8, state: State) ![]const u8 {
    return substitute(allocator, input, state.args.items, try effectiveStateEnv(allocator, state));
}

fn substitute(allocator: std.mem.Allocator, input: []const u8, args: []const ArgValue, env: []const []const u8) ![]const u8 {
    var variables = std.array_list.Managed(variable_expansion.Variable).init(allocator);
    for (env) |entry| {
        if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
            try variables.append(.{ .key = entry[0..eq], .value = entry[eq + 1 ..] });
        }
    }
    for (args) |arg| {
        try variables.append(.{ .key = arg.key, .value = arg.value });
    }
    return variable_expansion.expand(allocator, input, variables.items, .fail);
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
            .OnBuild = if (rt.OnBuild) |entries| try cloneStringList(allocator, entries) else null,
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

fn cloneStringList(allocator: std.mem.Allocator, entries: []const []const u8) ![][]const u8 {
    const out = try allocator.alloc([]const u8, entries.len);
    for (entries, 0..) |entry, i| out[i] = try allocator.dupe(u8, entry);
    return out;
}

fn testStorage() spore.RootfsStorage {
    return .{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = .{ .mmio_slot = 1 },
        .logical_size = spore.disk_chunk_size,
        .chunk_size = spore.disk_chunk_size,
        .hash_algorithm = "blake3",
        .index_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .base_identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .object_namespace = "rootfs/blake3",
    };
}

const test_executor_identity = "blake3:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";

test "variable substitution uses env before args" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try substitute(arena, "${APP}/$MODE", &.{.{ .key = "MODE", .value = "arg" }}, &.{"APP=/srv"});
    try std.testing.expectEqualStrings("/srv/arg", got);
}

test "CMD and ENTRYPOINT retain variables for runtime expansion" {
    const allocator = std.testing.allocator;
    const entrypoint = try resolveCmd(allocator, .{ .exec = &.{ "app", "$TOKEN" } });
    defer {
        for (entrypoint) |entry| allocator.free(entry);
        allocator.free(entrypoint);
    }
    try std.testing.expectEqualStrings("$TOKEN", entrypoint[1]);

    const cmd = try resolveCmd(allocator, .{ .shell = "echo ${VALUE:-default}" });
    defer {
        for (cmd) |entry| allocator.free(entry);
        allocator.free(cmd);
    }
    try std.testing.expectEqualStrings("/bin/sh", cmd[0]);
    try std.testing.expectEqualStrings("-c", cmd[1]);
    try std.testing.expectEqualStrings("echo ${VALUE:-default}", cmd[2]);
}

test "run environment includes declared args after env" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = [_]ArgValue{
        .{ .key = "MODE", .value = "arg" },
        .{ .key = "TARGET", .value = "prod" },
        .{ .key = "UNSET", .value = null },
    };
    const state = try stateFromBase(arena, .{ .config = .{ .Env = @constCast(&[_][]const u8{ "MODE=env", "APP=/srv/app" }) } }, testStorage(), &args, 0);
    const entries = try runEnvironment(arena, state);
    try std.testing.expectEqual(@as(usize, 5), entries.len);
    try std.testing.expectEqualStrings("MODE=env", entries[0]);
    try std.testing.expectEqualStrings("APP=/srv/app", entries[1]);
    try std.testing.expectEqualStrings(default_linux_path, entries[2]);
    try std.testing.expectEqualStrings("TARGET=prod", entries[3]);
    try std.testing.expectEqualStrings(default_root_run_home, entries[4]);
}

test "build stage defaults PATH and root RUN HOME when absent or empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const default_state = try stateFromBase(arena, .{}, testStorage(), &.{}, 0);
    const defaulted = try runEnvironment(arena, default_state);
    try std.testing.expectEqual(@as(usize, 2), defaulted.len);
    try std.testing.expectEqualStrings(default_linux_path, defaulted[0]);
    try std.testing.expectEqualStrings(default_root_run_home, defaulted[1]);
    const default_config = try imageConfig(arena, .{}, default_state);
    try std.testing.expectEqual(@as(usize, 1), default_config.config.?.Env.?.len);
    try std.testing.expectEqualStrings(default_linux_path, default_config.config.?.Env.?[0]);

    const explicit_home_state = try stateFromBase(arena, .{ .config = .{ .Env = @constCast(&[_][]const u8{"HOME=/workspace"}) } }, testStorage(), &.{}, 0);
    const from_env = try runEnvironment(arena, explicit_home_state);
    try std.testing.expectEqual(@as(usize, 2), from_env.len);
    try std.testing.expectEqualStrings("HOME=/workspace", from_env[0]);
    try std.testing.expectEqualStrings(default_linux_path, from_env[1]);

    const empty_home_state = try stateFromBase(arena, .{ .config = .{ .Env = @constCast(&[_][]const u8{"HOME="}) } }, testStorage(), &.{}, 0);
    const empty_home = try runEnvironment(arena, empty_home_state);
    try std.testing.expectEqual(@as(usize, 2), empty_home.len);
    try std.testing.expectEqualStrings(default_root_run_home, empty_home[0]);
    try std.testing.expectEqualStrings(default_linux_path, empty_home[1]);
    const empty_home_config = try imageConfig(arena, .{}, empty_home_state);
    try std.testing.expectEqualStrings("HOME=", empty_home_config.config.?.Env.?[0]);

    const home_arg = [_]ArgValue{.{ .key = "HOME", .value = "/arg-home" }};
    const home_arg_state = try stateFromBase(arena, .{}, testStorage(), &home_arg, 0);
    const from_arg = try runEnvironment(arena, home_arg_state);
    try std.testing.expectEqual(@as(usize, 2), from_arg.len);
    try std.testing.expectEqualStrings(default_linux_path, from_arg[0]);
    try std.testing.expectEqualStrings("HOME=/arg-home", from_arg[1]);

    const explicit_path_state = try stateFromBase(arena, .{ .config = .{ .Env = @constCast(&[_][]const u8{"PATH=/custom/bin"}) } }, testStorage(), &.{}, 0);
    const explicit_path = try runEnvironment(arena, explicit_path_state);
    try std.testing.expectEqual(@as(usize, 2), explicit_path.len);
    try std.testing.expectEqualStrings("PATH=/custom/bin", explicit_path[0]);
    try std.testing.expectEqualStrings(default_root_run_home, explicit_path[1]);
    const explicit_path_config = try imageConfig(arena, .{}, explicit_path_state);
    try std.testing.expectEqual(@as(usize, 1), explicit_path_config.config.?.Env.?.len);
    try std.testing.expectEqualStrings("PATH=/custom/bin", explicit_path_config.config.?.Env.?[0]);

    const empty_path_state = try stateFromBase(arena, .{ .config = .{ .Env = @constCast(&[_][]const u8{"PATH="}) } }, testStorage(), &.{}, 0);
    try std.testing.expectEqual(@as(usize, 1), empty_path_state.env.items.len);
    try std.testing.expectEqualStrings("PATH=", empty_path_state.env.items[0]);
}

test "stage PATH participates in expansion while ARG overrides only effective state" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: dockerfile.Diagnostic = .{};
    const document = try dockerfile.parse(arena,
        \\FROM scratch
        \\ARG PATH=/toolchain/bin
        \\ENV SNAPSHOT=$PATH
        \\ENV PATH=/explicit/bin
        \\ENV AFTER=$PATH
        \\
    , &diagnostic);
    var state = try stateFromBase(arena, .{}, testStorage(), &.{}, 0);
    const instructions = document.stages[0].instructions;
    const options = Options{ .tag = "local/test:dev", .context_dir = ".", .dockerfile_path = "Dockerfile" };

    try std.testing.expect(try applyMetadataInstruction(arena, options, &.{}, &state, instructions[0]));
    try std.testing.expectEqualStrings("/toolchain/bin", state.path_arg_override.?);
    const arg_effective_env = try effectiveStateEnv(arena, state);
    try std.testing.expectEqualStrings("PATH=/toolchain/bin", arg_effective_env[0]);
    const arg_config = try imageConfig(arena, .{}, state);
    try std.testing.expectEqualStrings(default_linux_path, arg_config.config.?.Env.?[0]);

    for (instructions[1..]) |instruction| {
        try std.testing.expect(try applyMetadataInstruction(arena, options, &.{}, &state, instruction));
    }
    try std.testing.expect(state.path_arg_override == null);
    try std.testing.expectEqualStrings("PATH=/explicit/bin", state.env.items[0]);
    try std.testing.expectEqualStrings("SNAPSHOT=/toolchain/bin", state.env.items[1]);
    try std.testing.expectEqualStrings("AFTER=/explicit/bin", state.env.items[2]);

    var env_first_diagnostic: dockerfile.Diagnostic = .{};
    const env_first_document = try dockerfile.parse(arena,
        \\FROM scratch
        \\ENV PATH=/published/bin
        \\ARG PATH=/effective/bin
        \\ENV SNAPSHOT=$PATH
        \\
    , &env_first_diagnostic);
    var env_first_state = try stateFromBase(arena, .{}, testStorage(), &.{}, 0);
    for (env_first_document.stages[0].instructions) |instruction| {
        try std.testing.expect(try applyMetadataInstruction(arena, options, &.{}, &env_first_state, instruction));
    }
    try std.testing.expectEqualStrings("/effective/bin", env_first_state.path_arg_override.?);
    try std.testing.expectEqualStrings("PATH=/published/bin", env_first_state.env.items[0]);
    try std.testing.expectEqualStrings("SNAPSHOT=/effective/bin", env_first_state.env.items[1]);
    const env_first_effective = try effectiveStateEnv(arena, env_first_state);
    try std.testing.expectEqualStrings("PATH=/effective/bin", env_first_effective[0]);
}

test "root RUN HOME follows ENV and ARG instruction order without changing image config" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const options = Options{ .tag = "local/test:dev", .context_dir = ".", .dockerfile_path = "Dockerfile" };

    var diagnostic: dockerfile.Diagnostic = .{};
    const document = try dockerfile.parse(arena,
        \\FROM scratch
        \\ENV HOME=/published-home
        \\ARG HOME=/arg-home
        \\ENV SNAPSHOT=$HOME
        \\
    , &diagnostic);
    var state = try stateFromBase(arena, .{}, testStorage(), &.{}, 0);
    for (document.stages[0].instructions) |instruction| {
        try std.testing.expect(try applyMetadataInstruction(arena, options, &.{}, &state, instruction));
    }
    try std.testing.expectEqualStrings("/arg-home", state.home_arg_override.?);
    const env_then_arg = try runEnvironment(arena, state);
    try std.testing.expectEqualStrings("/arg-home", envValue(env_then_arg, "HOME").?);
    const env_then_arg_config = try imageConfig(arena, .{}, state);
    try std.testing.expectEqualStrings("HOME=/published-home", env_then_arg_config.config.?.Env.?[1]);
    try std.testing.expectEqualStrings("SNAPSHOT=/arg-home", env_then_arg_config.config.?.Env.?[2]);

    var later_env_diagnostic: dockerfile.Diagnostic = .{};
    const later_env_document = try dockerfile.parse(arena,
        \\FROM scratch
        \\ARG HOME=/arg-home
        \\ENV HOME=
        \\
    , &later_env_diagnostic);
    var later_env_state = try stateFromBase(arena, .{}, testStorage(), &.{}, 0);
    for (later_env_document.stages[0].instructions) |instruction| {
        try std.testing.expect(try applyMetadataInstruction(arena, options, &.{}, &later_env_state, instruction));
    }
    try std.testing.expect(later_env_state.home_arg_override == null);
    const arg_then_empty_env = try runEnvironment(arena, later_env_state);
    try std.testing.expectEqualStrings(default_root_run_home_value, envValue(arg_then_empty_env, "HOME").?);
    const arg_then_empty_config = try imageConfig(arena, .{}, later_env_state);
    try std.testing.expectEqualStrings("HOME=", arg_then_empty_config.config.?.Env.?[1]);
}

test "implicit root HOME transitions only affected RUN cache identities" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const state = State{
        .storage = testStorage(),
        .env = std.array_list.Managed([]const u8).init(arena),
        .args = std.array_list.Managed(ArgValue).init(arena),
    };
    const old_digest = try effectiveEnvDigest(arena, state);
    const run_digest = try effectiveRunEnvDigest(arena, state);
    try std.testing.expect(!std.mem.eql(u8, old_digest, run_digest));

    var empty_env = std.array_list.Managed([]const u8).init(arena);
    try empty_env.append("HOME=");
    const empty_state = State{
        .storage = testStorage(),
        .env = empty_env,
        .args = std.array_list.Managed(ArgValue).init(arena),
    };
    const empty_state_digest = try effectiveEnvDigest(arena, empty_state);
    const empty_run_digest = try effectiveRunEnvDigest(arena, empty_state);
    try std.testing.expect(!std.mem.eql(u8, empty_state_digest, empty_run_digest));

    var explicit_env = std.array_list.Managed([]const u8).init(arena);
    try explicit_env.append("HOME=/workspace");
    const explicit_state = State{
        .storage = testStorage(),
        .env = explicit_env,
        .args = std.array_list.Managed(ArgValue).init(arena),
    };
    try std.testing.expectEqualStrings(
        try effectiveEnvDigest(arena, explicit_state),
        try effectiveRunEnvDigest(arena, explicit_state),
    );

    const instruction = dockerfile.Instruction{
        .line = 4,
        .span = .{ .start_line = 4, .end_line = 4 },
        .raw = "RUN go build ./...",
        .value = .{ .run = .{ .shell = "go build ./..." } },
    };
    var diagnostic: Diagnostic = .{};
    const step = try runStep(arena, &diagnostic, state, instruction, instruction.value.run, .{
        .tag = "local/test:dev",
        .context_dir = ".",
        .dockerfile_path = "Dockerfile",
    });
    try std.testing.expectEqualStrings(run_digest, step.env_digest);
}

test "realistic pinned Go multi-stage scratch Dockerfile parses and plans" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: dockerfile.Diagnostic = .{};
    const document = try dockerfile.parse(arena,
        \\FROM --platform=linux/arm64 golang@sha256:8bee1901f1e530bfb4a7850aa7a479d17ae3a18beb6e09064ed54cfd245b7191 AS build
        \\WORKDIR /src
        \\COPY . .
        \\RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o /out/app .
        \\FROM scratch
        \\COPY --from=build /out/app /app
        \\ENTRYPOINT ["/app"]
        \\
    , &diagnostic);
    const plan = try build_plan.create(arena, &document, .{}, &diagnostic);
    try std.testing.expectEqual(@as(usize, 2), plan.stages.len);
    try std.testing.expectEqual(@as(usize, 2), plan.order.len);
    try std.testing.expectEqual(@as(usize, 1), plan.stages[1].copies.len);
    try std.testing.expectEqual(@as(usize, 1), plan.target_index);
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
        .span = .{ .start_line = 2, .end_line = 2 },
        .raw = "RUN " ++ shell,
        .value = .{ .run = .{ .shell = shell } },
    };
    var diagnostic: Diagnostic = .{};
    const step = try runStep(arena, &diagnostic, .{
        .storage = testStorage(),
        .env = env,
        .args = args,
    }, instruction, instruction.value.run, .{
        .tag = "local/test:dev",
        .context_dir = "unused",
        .dockerfile_path = "unused",
    });
    try std.testing.expectEqualStrings(shell, step.command);
    try std.testing.expectEqualStrings("APP_ENV=test", step.env[0]);
    try std.testing.expectEqualStrings("BUILD_ARG=from-arg", step.env[1]);
}

test "stage config inheritance preserves entrypoint cmd user env and workdir" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var state = try stateFromBase(allocator, .{
        .architecture = "arm64",
        .os = "linux",
        .config = .{
            .Env = @constCast(&[_][]const u8{"A=one"}),
            .Entrypoint = @constCast(&[_][]const u8{"/entry"}),
            .Cmd = @constCast(&[_][]const u8{"serve"}),
            .WorkingDir = "/srv",
            .User = "root",
        },
    }, testStorage(), &.{.{ .key = "INHERITED", .value = "yes" }}, 0);
    try std.testing.expectEqualStrings("A=one", state.env.items[0]);
    try std.testing.expectEqualStrings("/entry", state.entrypoint.?[0]);
    try std.testing.expectEqualStrings("serve", state.cmd.?[0]);
    try std.testing.expectEqualStrings("/srv", state.workdir);
    try std.testing.expectEqualStrings("root", state.user.?);
    try std.testing.expectEqualStrings("yes", lookupArg("INHERITED", state.args.items).?);

    var parse_diagnostic: dockerfile.Diagnostic = .{};
    const document = try dockerfile.parse(allocator, "FROM base\nENTRYPOINT [\"/new-entry\"]\n", &parse_diagnostic);
    try std.testing.expect(try applyMetadataInstruction(allocator, .{
        .tag = "local/test:dev",
        .context_dir = "unused",
        .dockerfile_path = "unused",
    }, &.{}, &state, document.stages[0].instructions[0]));
    try std.testing.expectEqualStrings("/new-entry", state.entrypoint.?[0]);
    try std.testing.expect(state.cmd == null);

    const config = try imageConfig(allocator, .{}, state);
    try std.testing.expectEqualStrings("/new-entry", config.config.?.Entrypoint.?[0]);
    try std.testing.expect(config.config.?.Cmd == null);
    try std.testing.expectEqualStrings("root", config.config.?.User.?);
}

test "stage ARG redeclaration retains an inherited value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var args = std.array_list.Managed(ArgValue).init(allocator);
    defer args.deinit();
    try args.append(.{
        .key = try allocator.dupe(u8, "CHOICE"),
        .value = try allocator.dupe(u8, "parent"),
    });
    try declareArg(allocator, &.{}, null, &args, .{ .key = "CHOICE" });
    try std.testing.expectEqualStrings("parent", lookupArg("CHOICE", args.items).?);
}

test "build image references use Docker Hub defaults" {
    const allocator = std.testing.allocator;
    const alpine = try normalizeBuildImageRef(allocator, "alpine");
    defer allocator.free(alpine);
    try std.testing.expectEqualStrings("docker.io/library/alpine:latest", alpine);
    const tagged = try normalizeBuildImageRef(allocator, "alpine:3.22");
    defer allocator.free(tagged);
    try std.testing.expectEqualStrings("docker.io/library/alpine:3.22", tagged);
    const user_image = try normalizeBuildImageRef(allocator, "example/app:v1");
    defer allocator.free(user_image);
    try std.testing.expectEqualStrings("docker.io/example/app:v1", user_image);
    const explicit = try normalizeBuildImageRef(allocator, "ghcr.io/example/app:v1");
    defer allocator.free(explicit);
    try std.testing.expectEqualStrings("ghcr.io/example/app:v1", explicit);
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
    const instruction = doc.stages[0].instructions[0];
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
    const step = try runStep(arena, &diagnostic, state, instruction, instruction.value.run, spore_options);
    const spore_read = try execStepInput(arena, spore_options, state, instruction, "", test_executor_identity);
    const spore_write = build_exec.cacheInputForStep(spore_options.platform, state.storage.index_digest, test_executor_identity, .{ .run = step }, runResources(spore_options));
    const spore_read_key = try step_cache.stepKey(arena, spore_read);
    const spore_write_key = try step_cache.stepKey(arena, spore_write);
    try std.testing.expectEqualStrings(spore_read_key, spore_write_key);

    const none_read = try execStepInput(arena, none_options, state, instruction, "", test_executor_identity);
    var none_step = step;
    none_step.network_mode = .none;
    const none_write = build_exec.cacheInputForStep(none_options.platform, state.storage.index_digest, test_executor_identity, .{ .run = none_step }, runResources(none_options));
    const none_read_key = try step_cache.stepKey(arena, none_read);
    const none_write_key = try step_cache.stepKey(arena, none_write);
    try std.testing.expectEqualStrings(none_read_key, none_write_key);
    try std.testing.expect(!std.mem.eql(u8, spore_read_key, none_read_key));

    var resource_options = spore_options;
    resource_options.memory.bytes += memory_config.page_alignment;
    resource_options.vcpus = 2;
    resource_options.nofile = .{ .soft = 32_768, .hard = 65_536 };
    const resource_read = try execStepInput(arena, resource_options, state, instruction, "", test_executor_identity);
    const resource_write = build_exec.cacheInputForStep(
        resource_options.platform,
        state.storage.index_digest,
        test_executor_identity,
        .{ .run = step },
        runResources(resource_options),
    );
    const resource_read_key = try step_cache.stepKey(arena, resource_read);
    try std.testing.expectEqualStrings(resource_read_key, try step_cache.stepKey(arena, resource_write));
    try std.testing.expect(!std.mem.eql(u8, spore_read_key, resource_read_key));
}

test "WORKDIR executor step key matches cached read key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: dockerfile.Diagnostic = .{};
    const doc = try dockerfile.parse(arena,
        \\FROM base
        \\ENV APP_ROOT=/srv
        \\WORKDIR ${APP_ROOT}/app
        \\
    , &diag);
    var env = std.array_list.Managed([]const u8).init(arena);
    try env.append("APP_ROOT=/srv");
    const state = State{
        .storage = testStorage(),
        .env = env,
        .args = std.array_list.Managed(ArgValue).init(arena),
        .workdir = "/previous",
    };
    const instruction = doc.stages[0].instructions[1];
    const options = Options{
        .tag = "local/app:dev",
        .context_dir = "unused",
        .dockerfile_path = "unused",
    };
    const step = try workdirStep(arena, state, instruction, instruction.value.workdir);
    try std.testing.expectEqualStrings("/srv/app", step.target);
    const read_input = try execStepInput(arena, options, state, instruction, "", test_executor_identity);
    const write_input = build_exec.cacheInputForStep(options.platform, state.storage.index_digest, test_executor_identity, .{ .workdir = step }, runResources(options));
    try std.testing.expectEqualStrings(try step_cache.stepKey(arena, read_input), try step_cache.stepKey(arena, write_input));
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
    const instruction = doc.stages[0].instructions[1];
    const storage = spore.RootfsStorage{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = .{ .mmio_slot = 1 },
        .logical_size = spore.disk_chunk_size,
        .chunk_size = spore.disk_chunk_size,
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
    const read_input = try execStepInput(arena, options, state, instruction, input_digest, test_executor_identity);
    const read_key = try step_cache.stepKey(arena, read_input);
    const env_digest = try effectiveEnvDigest(arena, state);
    const copy_step = build_exec.Step{ .copy = .{
        .canonical_instruction = instruction.raw,
        .input_digest = input_digest,
        .env_digest = env_digest,
        .workdir = state.workdir,
        .requests = &.{},
    } };
    const write_input = build_exec.cacheInputForStep(options.platform, storage.index_digest, test_executor_identity, copy_step, runResources(options));
    const write_key = try step_cache.stepKey(arena, write_input);
    try std.testing.expectEqualStrings(read_key, write_key);

    var none_options = options;
    none_options.network = .none;
    const none_read_input = try execStepInput(arena, none_options, state, instruction, input_digest, test_executor_identity);
    const none_write_input = build_exec.cacheInputForStep(none_options.platform, storage.index_digest, test_executor_identity, copy_step, runResources(none_options));
    try std.testing.expectEqualStrings(read_key, try step_cache.stepKey(arena, none_read_input));
    try std.testing.expectEqualStrings(write_key, try step_cache.stepKey(arena, none_write_input));
}

test "build disk grow target uses deterministic sparse policy" {
    const Case = struct { parent: u64, expected: u64 };
    const cases = [_]Case{
        .{ .parent = 1, .expected = automatic_build_capacity_bytes },
        .{ .parent = 512 * 1024 * 1024, .expected = automatic_build_capacity_bytes },
        .{ .parent = 10 * 1024 * 1024 * 1024, .expected = automatic_build_capacity_bytes },
        .{ .parent = automatic_build_capacity_bytes - 1, .expected = automatic_build_capacity_bytes },
        .{ .parent = automatic_build_capacity_bytes, .expected = automatic_build_capacity_bytes },
        .{ .parent = automatic_build_capacity_bytes + 1, .expected = automatic_build_capacity_bytes + 1 },
        .{ .parent = 17 * 1024 * 1024 * 1024, .expected = 17 * 1024 * 1024 * 1024 },
        .{ .parent = 32 * 1024 * 1024 * 1024, .expected = 32 * 1024 * 1024 * 1024 },
        .{ .parent = std.math.maxInt(usize), .expected = std.math.maxInt(usize) },
    };
    try std.testing.expectEqual(@as(u64, 0), automatic_build_capacity_bytes % spore.disk_chunk_size);
    for (cases) |case| {
        var storage = testStorage();
        storage.logical_size = case.parent;
        const target = try buildDiskGrowTarget(storage);
        try std.testing.expectEqual(case.expected, target);
        storage.logical_size = target;
        try std.testing.expectEqual(target, try buildDiskGrowTarget(storage));
    }

    var malformed = testStorage();
    malformed.logical_size = 0;
    try std.testing.expectError(error.BadManifest, buildDiskGrowTarget(malformed));
    malformed = testStorage();
    malformed.chunk_size = 4096;
    try std.testing.expectError(error.BadManifest, buildDiskGrowTarget(malformed));
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
    var snapshot = try build_context.CopySnapshot.init(arena, io, root);
    defer snapshot.deinit(io);
    var context_disk = build_context_disk.Builder.init(arena);
    const step = try copyStep(arena, io, ctx, null, &snapshot, &context_disk, &diagnostic, state, doc.stages[0].instructions[1], doc.stages[0].instructions[1].value.copy);
    try std.testing.expectEqual(@as(usize, 1), step.requests.len);
    try std.testing.expectEqual(.file, step.requests[0].source_kind);
    try std.testing.expectEqualStrings("s0/source.txt", step.requests[0].source);
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
    var snapshot = try build_context.CopySnapshot.init(arena, io, root);
    defer snapshot.deinit(io);
    var context_disk = build_context_disk.Builder.init(arena);
    try std.testing.expectError(error.CopyDestinationMustBeDirectory, copyStep(arena, io, ctx, null, &snapshot, &context_disk, &diagnostic, state, doc.stages[0].instructions[1], doc.stages[0].instructions[1].value.copy));
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
    var snapshot = try build_context.CopySnapshot.init(arena, io, root);
    defer snapshot.deinit(io);
    var context_disk = build_context_disk.Builder.init(arena);
    const step = try copyStep(arena, io, ctx, null, &snapshot, &context_disk, &diagnostic, state, doc.stages[0].instructions[0], doc.stages[0].instructions[0].value.copy);
    try std.testing.expectEqual(@as(usize, 1), step.requests.len);
    try std.testing.expectEqual(.directory, step.requests[0].source_kind);
    try std.testing.expectEqualStrings("s0/src", step.requests[0].source);
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
    const kernel_path = tmp ++ "/Image";
    const initrd_path = tmp ++ "/root.cpio";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, context_dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = base_rootfs, .data = "base rootfs bytes" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = kernel_path, .data = "test kernel bytes" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = initrd_path, .data = "test initrd bytes" });
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
    try env.put("SPOREVM_KERNEL_IMAGE", kernel_path);
    try env.put("SPOREVM_RUN_INITRD", initrd_path);
    const init = testInit(allocator, io, &arena_state, &env);
    const cache_root = try local_paths.rootfsCacheRootPath(arena, &env);

    const base_preload = try rootfs_cas.preloadPath(io, arena, cache_root, base_rootfs, rootfs_cas.default_chunk_size);
    const base_storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, base_preload);
    _ = try rootfs_mod.publishIndexedImage(init, arena, .{
        .ref = "local/base:dev",
        .platform = .{},
        .rootfs_storage = base_storage,
    });

    const producer = try build_exec.resolveProducer(init, arena);
    const prepared_size = try buildDiskGrowTarget(base_storage);
    const prepared_chunk_count: usize = @intCast(prepared_size / rootfs_cas.default_chunk_size);
    const zero_chunks = try arena.alloc(u64, prepared_chunk_count);
    for (zero_chunks, 0..) |*logical_chunk, i| logical_chunk.* = @intCast(i);
    const encoded_prepared = try disk_index.encodeCanonicalAlloc(arena, .{
        .kind = disk_index.disk_index_kind,
        .logical_size = prepared_size,
        .chunk_size = rootfs_cas.default_chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .object_namespace = spore.rootfs_storage_object_namespace,
        .zero_chunks = zero_chunks,
    });
    const prepared_index_path = try rootfs_cas.manifestIndexPath(arena, cache_root, encoded_prepared.digest);
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(prepared_index_path) orelse return error.BadManifest);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = prepared_index_path, .data = encoded_prepared.bytes });
    const prepared_storage = spore.RootfsStorage{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = .{ .mmio_slot = 1 },
        .logical_size = prepared_size,
        .chunk_size = rootfs_cas.default_chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .index_digest = encoded_prepared.digest,
        .base_identity = encoded_prepared.digest,
        .object_namespace = spore.rootfs_storage_object_namespace,
    };
    try std.testing.expect(try rootfs_cas.storageComplete(io, arena, cache_root, prepared_storage));

    const prepare_input = try step_cache.prepareInput(
        .{},
        base_storage.index_digest,
        prepared_size,
        producer.identity,
    );
    const prepare_key = try step_cache.stepKey(arena, prepare_input);
    _ = try step_cache.writeRecord(io, arena, cache_root, prepare_input, prepare_key, prepared_storage);

    const cached_state = try stateFromBase(arena, .{}, prepared_storage, &.{}, prepared_size);
    const env_digest = try effectiveRunEnvDigest(arena, cached_state);
    const run_input = step_cache.StepInput{
        .platform = .{},
        .parent_index_digest = prepared_storage.index_digest,
        .canonical_instruction = "RUN echo cached",
        .executor_identity = producer.identity,
        .operation = .{ .run = .{
            .env_digest = env_digest,
            .workdir = "/",
            .network_mode = .spore,
            .memory_bytes = default_build_memory.bytes,
            .vcpus = default_build_vcpus,
            .nofile_soft = default_build_nofile.soft,
            .nofile_hard = default_build_nofile.hard,
        } },
    };
    const run_key = try step_cache.stepKey(arena, run_input);
    _ = try step_cache.writeRecord(io, arena, cache_root, run_input, run_key, prepared_storage);

    var diagnostic: Diagnostic = .{};
    const result = try build(init, arena, .{
        .tag = "local/app:dev",
        .context_dir = context_dir,
        .dockerfile_path = dockerfile_path,
        .platform = .{},
        .diagnostic = &diagnostic,
    });

    try std.testing.expect(result.cache_hit);
    try std.testing.expectEqual(@as(usize, 0), diagnostic.executor.boot_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostic.executor.executed_steps);
    try std.testing.expectEqualStrings(prepared_storage.index_digest, result.index_digest);
    const resolved = try rootfs_mod.resolveLocalCachedRef(io, arena, cache_root, "local/app:dev", .{});
    try std.testing.expect(!std.mem.eql(u8, prepared_storage.index_digest, resolved.manifest_digest));
    const indexed = (try rootfs_mod.cachedImageIndexedRootfs(io, arena, cache_root, resolved)) orelse return error.MissingIndexedRootfs;
    defer rootfs_mod.deinitCachedIndexedRootfs(arena, indexed);
    try std.testing.expectEqualStrings(prepared_storage.index_digest, indexed.storage.index_digest);

    const resolved_direct = try rootfs_mod.resolveLocalCachedRef(io, arena, cache_root, result.resolved_image_ref, .{});
    try std.testing.expectEqualStrings(resolved.manifest_digest, resolved_direct.manifest_digest);
    const indexed_direct = (try rootfs_mod.cachedImageIndexedRootfs(io, arena, cache_root, resolved_direct)) orelse return error.MissingIndexedRootfs;
    defer rootfs_mod.deinitCachedIndexedRootfs(arena, indexed_direct);
    try std.testing.expectEqualStrings(prepared_storage.index_digest, indexed_direct.storage.index_digest);
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
    try env.put("SPOREVM_KERNEL_IMAGE", "/missing-metadata-only-kernel");
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

test "multi-stage target inherits config and prunes unreachable bases" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-spore-build-multistage-target";
    const context_dir = tmp ++ "/context";
    const cache_dir = tmp ++ "/cache";
    const base_rootfs = tmp ++ "/base.ext4";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, context_dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = base_rootfs, .data = "base rootfs bytes" });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = context_dir ++ "/Dockerfile",
        .data =
        \\ARG BASE=local/base:dev
        \\FROM --platform=$BUILDPLATFORM ${BASE} AS build
        \\ENV SNAPSHOT=$PATH
        \\ENV BUILD=yes
        \\ENV HOME=/published-home
        \\ARG HOME=/effective-home
        \\ENTRYPOINT ["/build-entry"]
        \\CMD ["build"]
        \\FROM build AS runtime
        \\ENV RUNTIME=yes
        \\ENV HOME_SNAPSHOT=$HOME
        \\ENTRYPOINT ["/runtime-entry"]
        \\CMD ["serve"]
        \\FROM local/does-not-exist:dev AS debug
        \\CMD ["debug"]
        \\
        ,
    });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_dir);
    const init = testInit(allocator, io, &arena_state, &env);
    const cache_root = try local_paths.rootfsCacheRootPath(arena, &env);
    const preload = try rootfs_cas.preloadPath(io, arena, cache_root, base_rootfs, rootfs_cas.default_chunk_size);
    const storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload);
    _ = try rootfs_mod.publishIndexedImage(init, arena, .{
        .ref = "local/base:dev",
        .platform = .{},
        .config = .{ .architecture = "arm64", .os = "linux", .config = .{ .WorkingDir = "/build" } },
        .rootfs_storage = storage,
    });

    var diagnostic: Diagnostic = .{};
    const result = try build(init, arena, .{
        .tag = "local/app:runtime",
        .target = "runtime",
        .context_dir = context_dir,
        .dockerfile_path = context_dir ++ "/Dockerfile",
        .diagnostic = &diagnostic,
    });
    try std.testing.expectEqualStrings(storage.index_digest, result.index_digest);
    const metadata = try readCachedMetadata(arena, io, result.metadata_path);
    const config = metadata.config.config.?;
    try std.testing.expectEqualStrings(default_linux_path, config.Env.?[0]);
    try std.testing.expectEqualStrings("SNAPSHOT=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", config.Env.?[1]);
    try std.testing.expectEqualStrings("BUILD=yes", config.Env.?[2]);
    try std.testing.expectEqualStrings("HOME=/published-home", config.Env.?[3]);
    try std.testing.expectEqualStrings("RUNTIME=yes", config.Env.?[4]);
    try std.testing.expectEqualStrings("HOME_SNAPSHOT=/effective-home", config.Env.?[5]);
    try std.testing.expectEqualStrings("/build", config.WorkingDir.?);
    try std.testing.expectEqualStrings("/runtime-entry", config.Entrypoint.?[0]);
    try std.testing.expectEqualStrings("serve", config.Cmd.?[0]);
    try std.testing.expectEqual(@as(usize, 0), diagnostic.executor.boot_count);
}

test "unsupported reachable platform fails before context or base resolution" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-spore-build-platform-order";
    const dockerfile_path = tmp ++ "/Dockerfile";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = dockerfile_path,
        .data = "FROM --platform=linux/amd64 example.invalid/does-not-exist:latest\n",
    });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const init = testInit(allocator, io, &arena_state, &env);
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.DockerfilePlanFailed, build(init, arena, .{
        .tag = "local/app:invalid-platform",
        .context_dir = tmp ++ "/missing-context",
        .dockerfile_path = dockerfile_path,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("spore build currently supports only FROM --platform=linux/arm64", diagnostic.dockerfile.message);
}

test "a stage with three distinct COPY inputs fails before boot with the third instruction line" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-spore-build-input-limit";
    const context_dir = tmp ++ "/context";
    const cache_dir = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, context_dir);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = context_dir ++ "/Dockerfile",
        .data =
        \\FROM local/input-one:dev AS one
        \\FROM local/input-two:dev AS two
        \\FROM local/input-three:dev AS three
        \\FROM scratch AS runtime
        \\COPY --from=one /a /a
        \\COPY --from=two /b /b
        \\COPY --from=three /c /c
        \\
        ,
    });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_dir);
    const init = testInit(allocator, io, &arena_state, &env);
    const cache_root = try local_paths.rootfsCacheRootPath(arena, &env);
    const refs = [_][]const u8{ "local/input-one:dev", "local/input-two:dev", "local/input-three:dev" };
    for (refs, 0..) |ref, index| {
        const rootfs_path = try std.fmt.allocPrint(arena, "{s}/input-{d}.ext4", .{ tmp, index });
        const bytes = try std.fmt.allocPrint(arena, "distinct rootfs {d}", .{index});
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = bytes });
        const preload = try rootfs_cas.preloadPath(io, arena, cache_root, rootfs_path, rootfs_cas.default_chunk_size);
        _ = try rootfs_mod.publishIndexedImage(init, arena, .{
            .ref = ref,
            .platform = .{},
            .rootfs_storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload),
        });
    }

    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.TooManyBuildInputDisks, build(init, arena, .{
        .tag = "local/app:input-limit",
        .context_dir = context_dir,
        .dockerfile_path = context_dir ++ "/Dockerfile",
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqual(@as(usize, 7), diagnostic.instruction_line);
    try std.testing.expectEqual(@as(u64, 2), diagnostic.limit);
    try std.testing.expectEqual(@as(u64, 3), diagnostic.actual);
    try std.testing.expectEqual(@as(usize, 0), diagnostic.executor.boot_count);
}

test "literal COPY --from source restrictions fail before boot" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-spore-build-copy-from-literals";
    const context_dir = tmp ++ "/context";
    const cache_dir = tmp ++ "/cache";
    const source_rootfs = tmp ++ "/source.ext4";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, context_dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = source_rootfs, .data = "source rootfs" });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_dir);
    const init = testInit(allocator, io, &arena_state, &env);
    const cache_root = try local_paths.rootfsCacheRootPath(arena, &env);
    const preload = try rootfs_cas.preloadPath(io, arena, cache_root, source_rootfs, rootfs_cas.default_chunk_size);
    _ = try rootfs_mod.publishIndexedImage(init, arena, .{
        .ref = "local/source:dev",
        .platform = .{},
        .rootfs_storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload),
    });

    const cases = [_]struct { source: []const u8, expected: anyerror }{
        .{ .source = "/a*", .expected = error.UnsupportedCopyFromPattern },
        .{ .source = "/a?", .expected = error.UnsupportedCopyFromPattern },
        .{ .source = "/[a]", .expected = error.UnsupportedCopyFromPattern },
        .{ .source = "../escape", .expected = error.CopySourceEscapesContext },
    };
    for (cases, 0..) |case, index| {
        const dockerfile_source = try std.fmt.allocPrint(
            arena,
            "FROM local/source:dev AS source\nFROM scratch\nCOPY --from=source {s} /dest\n",
            .{case.source},
        );
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = context_dir ++ "/Dockerfile", .data = dockerfile_source });
        var diagnostic: Diagnostic = .{};
        const tag = try std.fmt.allocPrint(arena, "local/app:literal-{d}", .{index});
        try std.testing.expectError(case.expected, build(init, arena, .{
            .tag = tag,
            .context_dir = context_dir,
            .dockerfile_path = context_dir ++ "/Dockerfile",
            .diagnostic = &diagnostic,
        }));
        try std.testing.expectEqual(@as(usize, 3), diagnostic.instruction_line);
        try std.testing.expectEqual(@as(usize, 0), diagnostic.executor.boot_count);
    }
}

test "scratch stage publishes an empty native rootfs without guest execution" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tmp = "zig-cache/test-spore-build-scratch";
    const context_dir = tmp ++ "/context";
    const cache_dir = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, context_dir);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = context_dir ++ "/Dockerfile",
        .data = "FROM scratch\nENTRYPOINT [\"/app\"]\n",
    });
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_dir);
    const init = testInit(allocator, io, &arena_state, &env);
    var diagnostic: Diagnostic = .{};
    const result = try build(init, arena, .{
        .tag = "local/app:scratch",
        .context_dir = context_dir,
        .dockerfile_path = context_dir ++ "/Dockerfile",
        .diagnostic = &diagnostic,
    });
    try std.testing.expectEqual(@as(usize, 0), diagnostic.executor.boot_count);
    try std.testing.expectEqual(@as(u64, 1), diagnostic.scratch.created);
    try std.testing.expectEqual(@as(u64, 0), diagnostic.scratch.reused);
    try std.testing.expectEqual(automatic_build_capacity_bytes, diagnostic.scratch.logical_size);
    // The 131,072-inode v2 scratch format measured 677,760 bytes of span
    // planning, 52,221,824 counted emitter-buffer bytes, 35,684,352 allocated
    // temp-file bytes, and 851,968 CAS object bytes on first creation. Keep
    // tight regression bounds around that format instead of hiding inode-table
    // growth behind the old 1,024-inode compactness thresholds.
    try std.testing.expect(diagnostic.scratch.first_emit_map_bytes <= 700 * 1024);
    try std.testing.expect(diagnostic.scratch.first_counted_emitter_buffers_bytes <= 52 * 1024 * 1024);
    try std.testing.expect(diagnostic.scratch.first_temp_allocated_bytes <= 36 * 1024 * 1024);
    try std.testing.expect(diagnostic.scratch.first_object_bytes_written <= 896 * 1024);
    try std.testing.expectEqual(@as(u64, 129), diagnostic.scratch.first_nonzero_chunks);
    const metadata = try readCachedMetadata(arena, io, result.metadata_path);
    try std.testing.expectEqualStrings("/app", metadata.config.config.?.Entrypoint.?[0]);
    try std.testing.expect(metadata.rootfs_storage != null);
    const storage = metadata.rootfs_storage.?;
    try std.testing.expectEqual(automatic_build_capacity_bytes, storage.logical_size);
    const index_path = try rootfs_cas.manifestIndexPath(arena, cache_dir, storage.index_digest);
    const index_bytes = try Io.Dir.cwd().readFileAlloc(io, index_path, arena, .limited(disk_index.max_index_bytes));
    var parsed_index = try disk_index.parseDiskIndex(arena, index_bytes, try spore.diskIndexDescriptorForStorage(storage));
    defer parsed_index.deinit();
    // The empty 16 GiB filesystem remains physically compact: only metadata
    // chunks are materialized and the zero tail is represented in the index.
    try std.testing.expect(parsed_index.value.chunks.len <= 256);
    try std.testing.expect(parsed_index.value.zero_chunks.len > parsed_index.value.chunks.len);

    var warm_diagnostic: Diagnostic = .{};
    const warm = try build(init, arena, .{
        .tag = "local/app:scratch",
        .context_dir = context_dir,
        .dockerfile_path = context_dir ++ "/Dockerfile",
        .diagnostic = &warm_diagnostic,
    });
    try std.testing.expectEqualStrings(result.index_digest, warm.index_digest);
    try std.testing.expectEqual(@as(u64, 0), warm_diagnostic.scratch.created);
    try std.testing.expectEqual(@as(u64, 1), warm_diagnostic.scratch.reused);
    try std.testing.expectEqual(@as(u64, 0), warm_diagnostic.scratch.first_emit_map_bytes);
    try std.testing.expectEqual(@as(u64, 0), warm_diagnostic.scratch.first_object_bytes_written);
    try std.testing.expectEqual(@as(usize, 0), warm_diagnostic.executor.boot_count);
    try std.testing.expectEqual(@as(usize, 0), warm_diagnostic.executor.resize_count);
}

test "metadata-only scratch publication serializes destructive GC until ref visibility" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tmp = "zig-cache/test-spore-build-scratch-gc";
    const context_dir = tmp ++ "/context";
    const cache_dir = tmp ++ "/cache";
    const runtime_dir = tmp ++ "/runtime";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, context_dir);
    try Io.Dir.cwd().createDirPath(io, runtime_dir);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = context_dir ++ "/Dockerfile",
        .data = "FROM scratch\nENTRYPOINT [\"/app\"]\n",
    });
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_dir);
    const cwd = try std.process.currentPathAlloc(io, arena);
    const absolute_runtime_dir = try std.fs.path.resolve(arena, &.{ cwd, runtime_dir });

    const BuildContext = struct {
        allocator: std.mem.Allocator,
        io: Io,
        env: *const std.process.Environ.Map,
        context_dir: []const u8,
        arena: *std.heap.ArenaAllocator,
        result: ?Result = null,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            defer if (testing.before_final_publish_barrier) |barrier| barrier.reached.post(self.io);
            const init = testInit(self.allocator, self.io, self.arena, @constCast(self.env));
            self.result = build(init, self.arena.allocator(), .{
                .tag = "local/app:scratch-gc",
                .context_dir = self.context_dir,
                .dockerfile_path = "zig-cache/test-spore-build-scratch-gc/context/Dockerfile",
            }) catch |err| {
                self.err = err;
                return;
            };
        }
    };
    var publish_boundary = test_barrier.Barrier{};
    testing.before_final_publish_barrier = &publish_boundary;
    defer testing.before_final_publish_barrier = null;
    var build_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer build_arena_state.deinit();
    var build_thread_context = BuildContext{
        .allocator = allocator,
        .io = io,
        .env = &env,
        .context_dir = context_dir,
        .arena = &build_arena_state,
    };
    var build_thread = test_barrier.ThreadGuard{
        .io = io,
        .thread = try std.Thread.spawn(.{}, BuildContext.run, .{&build_thread_context}),
        .barriers = &.{&publish_boundary},
    };
    defer build_thread.deinit();
    publish_boundary.waitReached(io);
    if (build_thread_context.err) |err| return err;
    try std.testing.expectError(error.LockBusy, rootfs_mod.tryLockRootfsCacheExclusive(io, arena, cache_dir));

    const GcContext = struct {
        allocator: std.mem.Allocator,
        io: Io,
        cache_root: []const u8,
        runtime_root: []const u8,
        attempting: *Io.Semaphore,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.attempting.post(self.io);
            const result = system_mod.gc(self.allocator, self.io, .{
                .cache_root = self.cache_root,
                .runtime_root = self.runtime_root,
                .dry_run = false,
            }) catch |err| {
                self.err = err;
                return;
            };
            system_mod.deinitRootfsGcResult(self.allocator, result);
        }
    };
    var gc_attempting = Io.Semaphore{};
    var gc_context = GcContext{
        .allocator = allocator,
        .io = io,
        .cache_root = cache_dir,
        .runtime_root = absolute_runtime_dir,
        .attempting = &gc_attempting,
    };
    var gc_thread = test_barrier.ThreadGuard{
        .io = io,
        .thread = try std.Thread.spawn(.{}, GcContext.run, .{&gc_context}),
        .barriers = &.{},
    };
    defer gc_thread.deinit();
    gc_attempting.waitUncancelable(io);
    publish_boundary.release(io);
    build_thread.join();
    if (build_thread_context.err) |err| return err;
    gc_thread.join();
    if (gc_context.err) |err| return err;

    const result = build_thread_context.result orelse return error.BadManifest;
    const resolved = try rootfs_mod.resolveLocalCachedRef(io, arena, cache_dir, "local/app:scratch-gc", .{});
    try std.testing.expectEqualStrings(result.resolved_image_ref, resolved.ref);
    const indexed = (try rootfs_mod.cachedImageIndexedRootfs(io, arena, cache_dir, resolved)) orelse return error.MissingIndexedRootfs;
    defer rootfs_mod.deinitCachedIndexedRootfs(arena, indexed);
    try std.testing.expect(try rootfs_cas.storageMarkedComplete(io, arena, cache_dir, indexed.storage));
}

test "scratch allocation accounting is bound to the opened inode" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(io, "allocated", .{ .read = true });
    defer file.close(io);
    try file.writeStreamingAll(io, &([_]u8{0x5a} ** 4096));
    try std.testing.expect(try allocatedFileBlocks512(file.handle) > 0);
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
