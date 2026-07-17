const std = @import("std");
const Io = std.Io;

const build_mod = @import("build.zig");
const memory_config = @import("memory.zig");
const rootfs_mod = @import("rootfs.zig");
const run_mod = @import("run.zig");
const topology = @import("topology.zig");

pub const usage =
    \\Usage:
    \\  spore build [options] CONTEXT
    \\
    \\Options:
    \\  -t, --tag REF                  Local image ref to update, for example local/app:dev
    \\  -f, --file PATH                Dockerfile path, defaults to CONTEXT/Dockerfile
    \\  --platform OS/ARCH             Target platform, currently linux/arm64
    \\  --target STAGE                 Build and publish the named stage
    \\  --build-context NAME=oci-layout://PATH
    \\                                  Named OCI layout base available to FROM NAME
    \\  --build-arg KEY=VALUE          Build argument value
    \\  --network spore|none           Network mode for build RUN execution
    \\  --no-cache                     Bypass Dockerfile step-cache reads; PREPARE is still reused
    \\  --memory SIZE                  Build VM memory, for example 512mb or 16gb
    \\  --vcpus COUNT                  Build VM vCPUs, from 1 through 8
    \\  --timeout DURATION             Per-step timeout, for example 30s or 5m
    \\  --ulimit nofile=SOFT[:HARD]    RUN open-file limit, up to 1048576
    \\  --mkfs PATH                    mkfs helper for OCI layout imports
    \\  --debugfs PATH                 debugfs helper for OCI layout imports
    \\  -h, --help                     Show this help
    \\
    \\Executor-backed RUN, COPY, and WORKDIR misses run in Dockerfile order.
    \\
;

const ParsedOptions = struct {
    tag: ?[]const u8 = null,
    context_dir: ?[]const u8 = null,
    dockerfile_path: ?[]const u8 = null,
    platform: rootfs_mod.Platform = .{},
    target: ?[]const u8 = null,
    build_contexts: std.array_list.Managed(build_mod.BuildContextArg),
    build_args: std.array_list.Managed(build_mod.BuildArg),
    network: build_mod.NetworkMode = .spore,
    no_cache: bool = false,
    memory: memory_config.Config = build_mod.default_build_memory,
    vcpus: topology.VcpuCount = build_mod.default_build_vcpus,
    timeout_ms: u64 = build_mod.default_step_timeout_ms,
    nofile: build_mod.NofileLimit = build_mod.default_build_nofile,
    mkfs: ?[]const u8 = null,
    debugfs: ?[]const u8 = null,
};

pub fn run(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    const allocator = init.arena.allocator();
    const full_args = try init.minimal.args.toSlice(allocator);
    const spore_executable = full_args[0];
    if (wantsHelp(args)) {
        try stdout.writeAll(usage);
        return;
    }

    const parsed = parseArgs(allocator, args) catch |err| {
        try writeParseError(stderr, err);
        try stderr.writeAll("\n");
        try stderr.writeAll(usage);
        try stderr.flush();
        std.process.exit(2);
    };

    const tag = parsed.tag orelse {
        try stderr.writeAll("spore build: missing required -t/--tag local image ref\n\n");
        try stderr.writeAll(usage);
        try stderr.flush();
        std.process.exit(2);
    };
    const context_dir = parsed.context_dir orelse {
        try stderr.writeAll("spore build: missing build context directory\n\n");
        try stderr.writeAll(usage);
        try stderr.flush();
        std.process.exit(2);
    };
    const dockerfile_path = parsed.dockerfile_path orelse try std.fs.path.join(allocator, &.{ context_dir, "Dockerfile" });

    var diagnostic: build_mod.Diagnostic = .{};
    const result = build_mod.build(init, allocator, .{
        .tag = tag,
        .context_dir = context_dir,
        .dockerfile_path = dockerfile_path,
        .platform = parsed.platform,
        .target = parsed.target,
        .build_contexts = parsed.build_contexts.items,
        .build_args = parsed.build_args.items,
        .network = parsed.network,
        .no_cache = parsed.no_cache,
        .memory = parsed.memory,
        .vcpus = parsed.vcpus,
        .timeout_ms = parsed.timeout_ms,
        .nofile = parsed.nofile,
        .spore_executable = spore_executable,
        .mkfs = parsed.mkfs,
        .debugfs = parsed.debugfs,
        .output = stdout,
        .diagnostic = &diagnostic,
    }) catch |err| {
        try writeBuildError(stderr, err, diagnostic);
        try stderr.flush();
        std.process.exit(2);
    };

    try stdout.writeAll("Image built\n");
    try stdout.print("  Ref: {s}\n", .{tag});
    try stdout.print("  Resolved: {s}\n", .{result.resolved_image_ref});
    try stdout.print("  Rootfs index: {s}\n", .{result.index_digest});
    try stdout.print("  Metadata: {s}\n", .{result.metadata_path});
    try stdout.print("  Ref cache: {s}\n", .{result.local_ref_path});
    const cache_status = if (result.cache_hit)
        "hit"
    else if (diagnostic.executor.executed_steps != 0)
        "miss"
    else
        "metadata-only";
    try stdout.print("  Cache: {s}\n", .{cache_status});
    try stdout.print(
        "  Executor: executed_steps={d} boot_count={d} resize_count={d}\n",
        .{
            diagnostic.executor.executed_steps,
            diagnostic.executor.boot_count,
            diagnostic.executor.resize_count,
        },
    );
    if (diagnostic.executor.session_ms != 0) {
        const accounted_ms = diagnostic.executor.instruction_ms +|
            diagnostic.executor.checkpoint_control_ms +|
            diagnostic.executor.snapshot_ms;
        try stdout.print(
            "  Executor timing: session={d}ms instructions={d}ms snapshots={d}ms checkpoint-control={d}ms other={d}ms\n",
            .{
                diagnostic.executor.session_ms,
                diagnostic.executor.instruction_ms,
                diagnostic.executor.snapshot_ms,
                diagnostic.executor.checkpoint_control_ms,
                diagnostic.executor.session_ms -| accounted_ms,
            },
        );
    }
    if (diagnostic.context_hash.entries != 0) {
        try stdout.print(
            "  Context: entries={d} files={d} hashed={d} bytes stat-cache={d} hits/{d} misses stat={d}ms hash={d}ms cache-load={d}ms cache-save={d}ms\n",
            .{
                diagnostic.context_hash.entries,
                diagnostic.context_hash.files,
                diagnostic.context_hash.bytes_hashed,
                diagnostic.context_hash.stat_cache_hits,
                diagnostic.context_hash.stat_cache_misses,
                nsToMs(diagnostic.context_hash.stat_ns),
                nsToMs(diagnostic.context_hash.content_hash_ns),
                nsToMs(diagnostic.context_hash.cache_load_ns),
                nsToMs(diagnostic.context_hash.cache_save_ns),
            },
        );
    }
    if (diagnostic.context_disk.entries != 0) {
        const disk_status = if (diagnostic.context_disk.emitted)
            "emitted"
        else if (diagnostic.context_disk.reused)
            "reused"
        else
            "prepared";
        try stdout.print(
            "  Context disk: {s} entries={d} bytes={d} image={d} digest={s} emit={d}ms\n",
            .{
                disk_status,
                diagnostic.context_disk.entries,
                diagnostic.context_disk.bytes,
                diagnostic.context_disk.image_size,
                diagnostic.context_disk.digest,
                nsToMs(diagnostic.context_disk.emit_ns),
            },
        );
    }
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !ParsedOptions {
    var parsed = ParsedOptions{
        .build_contexts = std.array_list.Managed(build_mod.BuildContextArg).init(allocator),
        .build_args = std.array_list.Managed(build_mod.BuildArg).init(allocator),
    };
    errdefer parsed.build_contexts.deinit();
    errdefer parsed.build_args.deinit();
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--tag")) {
            parsed.tag = try nextValue(args, &i, arg);
        } else if (std.mem.startsWith(u8, arg, "--tag=")) {
            parsed.tag = try nonEmptyValue(arg["--tag=".len..]);
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            parsed.dockerfile_path = try nextValue(args, &i, arg);
        } else if (std.mem.startsWith(u8, arg, "--file=")) {
            parsed.dockerfile_path = try nonEmptyValue(arg["--file=".len..]);
        } else if (std.mem.eql(u8, arg, "--platform")) {
            parsed.platform = try rootfs_mod.Platform.parse(try nextValue(args, &i, arg));
        } else if (std.mem.startsWith(u8, arg, "--platform=")) {
            parsed.platform = try rootfs_mod.Platform.parse(try nonEmptyValue(arg["--platform=".len..]));
        } else if (std.mem.eql(u8, arg, "--target")) {
            parsed.target = try nextValue(args, &i, arg);
        } else if (std.mem.startsWith(u8, arg, "--target=")) {
            parsed.target = try nonEmptyValue(arg["--target=".len..]);
        } else if (std.mem.eql(u8, arg, "--build-context")) {
            try parsed.build_contexts.append(try parseBuildContext(try nextValue(args, &i, arg)));
        } else if (std.mem.startsWith(u8, arg, "--build-context=")) {
            try parsed.build_contexts.append(try parseBuildContext(try nonEmptyValue(arg["--build-context=".len..])));
        } else if (std.mem.eql(u8, arg, "--build-arg")) {
            try parsed.build_args.append(try parseBuildArg(try nextValue(args, &i, arg)));
        } else if (std.mem.startsWith(u8, arg, "--build-arg=")) {
            try parsed.build_args.append(try parseBuildArg(try nonEmptyValue(arg["--build-arg=".len..])));
        } else if (std.mem.eql(u8, arg, "--network")) {
            parsed.network = try parseNetwork(try nextValue(args, &i, arg));
        } else if (std.mem.startsWith(u8, arg, "--network=")) {
            parsed.network = try parseNetwork(try nonEmptyValue(arg["--network=".len..]));
        } else if (std.mem.eql(u8, arg, "--no-cache")) {
            parsed.no_cache = true;
        } else if (std.mem.eql(u8, arg, "--memory")) {
            parsed.memory = parseMemory(try nextValue(args, &i, arg)) catch return error.BadMemory;
        } else if (std.mem.startsWith(u8, arg, "--memory=")) {
            parsed.memory = parseMemory(try nonEmptyValue(arg["--memory=".len..])) catch return error.BadMemory;
        } else if (std.mem.eql(u8, arg, "--vcpus")) {
            parsed.vcpus = topology.parseVcpuCount(try nextValue(args, &i, arg)) catch return error.BadVcpus;
        } else if (std.mem.startsWith(u8, arg, "--vcpus=")) {
            parsed.vcpus = topology.parseVcpuCount(try nonEmptyValue(arg["--vcpus=".len..])) catch return error.BadVcpus;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            parsed.timeout_ms = run_mod.parseDurationMs(try nextValue(args, &i, arg)) catch return error.BadTimeout;
        } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
            parsed.timeout_ms = run_mod.parseDurationMs(try nonEmptyValue(arg["--timeout=".len..])) catch return error.BadTimeout;
        } else if (std.mem.eql(u8, arg, "--ulimit")) {
            parsed.nofile = try parseUlimit(try nextValue(args, &i, arg));
        } else if (std.mem.startsWith(u8, arg, "--ulimit=")) {
            parsed.nofile = try parseUlimit(try nonEmptyValue(arg["--ulimit=".len..]));
        } else if (std.mem.eql(u8, arg, "--mkfs")) {
            parsed.mkfs = try nextValue(args, &i, arg);
        } else if (std.mem.startsWith(u8, arg, "--mkfs=")) {
            parsed.mkfs = try nonEmptyValue(arg["--mkfs=".len..]);
        } else if (std.mem.eql(u8, arg, "--debugfs")) {
            parsed.debugfs = try nextValue(args, &i, arg);
        } else if (std.mem.startsWith(u8, arg, "--debugfs=")) {
            parsed.debugfs = try nonEmptyValue(arg["--debugfs=".len..]);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownArgument;
        } else if (parsed.context_dir == null) {
            parsed.context_dir = arg;
        } else {
            return error.UnexpectedArgument;
        }
        i += 1;
    }
    return parsed;
}

fn nextValue(args: []const []const u8, index: *usize, option: []const u8) ![]const u8 {
    _ = option;
    index.* += 1;
    if (index.* >= args.len) return error.MissingOptionValue;
    return nonEmptyValue(args[index.*]);
}

fn nonEmptyValue(value: []const u8) ![]const u8 {
    if (value.len == 0) return error.MissingOptionValue;
    return value;
}

fn parseBuildContext(raw: []const u8) !build_mod.BuildContextArg {
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return error.BadBuildContext;
    const name = raw[0..eq];
    const uri = raw[eq + 1 ..];
    if (!validName(name)) return error.BadBuildContext;
    const prefix = "oci-layout://";
    if (!std.mem.startsWith(u8, uri, prefix) or uri.len == prefix.len) return error.BadBuildContext;
    return .{ .name = name, .oci_layout_path = uri[prefix.len..] };
}

fn parseBuildArg(raw: []const u8) !build_mod.BuildArg {
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return error.BadBuildArg;
    const key = raw[0..eq];
    if (!validName(key)) return error.BadBuildArg;
    return .{ .key = key, .value = raw[eq + 1 ..] };
}

fn parseNetwork(raw: []const u8) !build_mod.NetworkMode {
    if (std.mem.eql(u8, raw, "spore")) return .spore;
    if (std.mem.eql(u8, raw, "none")) return .none;
    return error.BadNetworkMode;
}

fn parseMemory(raw: []const u8) !memory_config.Config {
    return memory_config.parse(raw);
}

fn parseUlimit(raw: []const u8) !build_mod.NofileLimit {
    const prefix = "nofile=";
    if (!std.mem.startsWith(u8, raw, prefix)) return error.BadUlimit;
    const value = raw[prefix.len..];
    if (value.len == 0) return error.BadUlimit;
    const colon = std.mem.indexOfScalar(u8, value, ':');
    const soft_raw = if (colon) |index| value[0..index] else value;
    const hard_raw = if (colon) |index| value[index + 1 ..] else value;
    if (soft_raw.len == 0 or hard_raw.len == 0 or (colon != null and std.mem.indexOfScalar(u8, hard_raw, ':') != null)) return error.BadUlimit;
    const limit = build_mod.NofileLimit{
        .soft = std.fmt.parseInt(u64, soft_raw, 10) catch return error.BadUlimit,
        .hard = std.fmt.parseInt(u64, hard_raw, 10) catch return error.BadUlimit,
    };
    limit.validate() catch return error.BadUlimit;
    return limit;
}

fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, i| {
        if (i == 0 and !(std.ascii.isAlphabetic(c) or c == '_')) return false;
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-')) return false;
    }
    return true;
}

fn wantsHelp(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "help")) return true;
    }
    return false;
}

fn writeParseError(stderr: *Io.Writer, err: anyerror) !void {
    const message = switch (err) {
        error.MissingOptionValue => "spore build: option requires a value",
        error.UnknownArgument => "spore build: unknown option",
        error.UnexpectedArgument => "spore build: expected exactly one build context",
        error.BadBuildContext => "spore build: --build-context must be NAME=oci-layout://PATH",
        error.BadBuildArg => "spore build: --build-arg must be KEY=VALUE",
        error.BadNetworkMode => "spore build: --network must be spore or none",
        error.BadMemory => "spore build: --memory must be a positive page-aligned size like 512mb or 16gb",
        error.BadVcpus => "spore build: --vcpus must be an integer from 1 through 8",
        error.BadTimeout => "spore build: --timeout must be a positive duration like 30s, 5m, or 500ms",
        error.BadUlimit => "spore build: --ulimit currently accepts only nofile=SOFT:HARD up to 1048576",
        error.BadPlatform, error.UnsupportedPlatform => "spore build: --platform must be linux/arm64",
        else => "spore build: invalid arguments",
    };
    try stderr.print("{s}\n", .{message});
}

fn writeBuildError(stderr: *Io.Writer, err: anyerror, diagnostic: build_mod.Diagnostic) !void {
    switch (err) {
        error.DockerfileParseFailed, error.DockerfilePlanFailed => {
            if (diagnostic.dockerfile.message.len != 0) {
                if (diagnostic.dockerfile.line != 0) {
                    try stderr.print("spore build: Dockerfile line {d}: {s}\n", .{ diagnostic.dockerfile.line, diagnostic.dockerfile.message });
                } else {
                    try stderr.print("spore build: {s}\n", .{diagnostic.dockerfile.message});
                }
            } else {
                try stderr.writeAll("spore build: unsupported Dockerfile syntax\n");
            }
        },
        error.UnsupportedDockerignorePattern => {
            if (diagnostic.dockerignore.message.len != 0) {
                try stderr.print("spore build: .dockerignore line {d}: {s}\n", .{ diagnostic.dockerignore.line, diagnostic.dockerignore.message });
            } else {
                try stderr.writeAll("spore build: unsupported .dockerignore pattern\n");
            }
        },
        error.CacheMissRequiresBuildExecutor => {
            try stderr.writeAll("spore build: cache miss requires an executor path that is not implemented yet\n");
        },
        error.BuildRunFailed => {
            if (diagnostic.executor.instruction) |instruction| {
                if (diagnostic.executor.instruction_line != 0) {
                    try stderr.print("spore build: Dockerfile line {d}: instruction failed: {s}\n", .{ diagnostic.executor.instruction_line, instruction });
                } else {
                    try stderr.print("spore build: instruction failed: {s}\n", .{instruction});
                }
            }
            if (diagnostic.executor.exit_code) |code| {
                try stderr.print("spore build: executor step failed with exit code {d}\n", .{code});
            } else {
                try stderr.writeAll("spore build: executor step failed\n");
            }
            if (diagnostic.executor.output.len != 0) {
                try stderr.writeAll(diagnostic.executor.output);
                if (!std.mem.endsWith(u8, diagnostic.executor.output, "\n")) try stderr.writeAll("\n");
            }
            if (diagnostic.executor.enospc or outputLooksLikeEnospc(diagnostic.executor.output)) {
                try stderr.writeAll("spore build: build rootfs ran out of block or inode space\n");
                try stderr.writeAll("spore build: reduce the build footprint or use an already-larger base image; failed steps are not retried\n");
            }
        },
        error.BuildGuestFreezeFailed => {
            try stderr.writeAll("spore build: guest fsfreeze failed before recording a step cache entry\n");
        },
        error.BuildGuestThawFailed => {
            try stderr.writeAll("spore build: guest fsthaw failed after the step snapshot was recorded\n");
        },
        error.BuildGuestResizeFailed => {
            try stderr.writeAll("spore build: guest rootfs growth failed before executing build steps\n");
        },
        error.Poisoned => {
            try stderr.writeAll("spore build: rootfs storage failed after a validated write; unpublished state was discarded\n");
        },
        error.BuildGuestProtocolFailed => {
            try stderr.writeAll("spore build: guest executor protocol failed\n");
        },
        error.BuildGuestTimedOut => {
            try stderr.writeAll("spore build: guest executor step timed out\n");
        },
        error.RunEnvCountUnsupported => {
            if (diagnostic.instruction_line != 0) {
                try stderr.print("spore build: Dockerfile line {d}: RUN environment has too many entries for the guest executor\n", .{diagnostic.instruction_line});
            } else try stderr.writeAll("spore build: RUN environment has too many entries for the guest executor\n");
        },
        error.RunEnvTooLong => {
            if (diagnostic.instruction_line != 0) {
                try stderr.print("spore build: Dockerfile line {d}: RUN environment entry is too long for the guest executor\n", .{diagnostic.instruction_line});
            } else try stderr.writeAll("spore build: RUN environment entry is too long for the guest executor\n");
        },
        error.InvalidRunEnvironment => {
            if (diagnostic.instruction_line != 0) {
                try stderr.print("spore build: Dockerfile line {d}: RUN environment contains an invalid entry\n", .{diagnostic.instruction_line});
            } else try stderr.writeAll("spore build: RUN environment contains an invalid entry\n");
        },
        error.RunRequestTooLarge => {
            if (diagnostic.instruction_line != 0) {
                try stderr.print("spore build: Dockerfile line {d}: resolved RUN request is too large for the guest executor\n", .{diagnostic.instruction_line});
            } else try stderr.writeAll("spore build: RUN request is too large for the guest executor\n");
        },
        error.RunCommandTooLong => {
            if (diagnostic.instruction_line != 0 and diagnostic.limit != 0) {
                try stderr.print(
                    "spore build: Dockerfile line {d}: RUN shell command is too long for the guest executor: limit={d} bytes actual={d} bytes\n",
                    .{ diagnostic.instruction_line, diagnostic.limit, diagnostic.actual },
                );
            } else {
                try stderr.writeAll("spore build: RUN shell command is too long for the guest executor\n");
            }
        },
        error.RunArgCountUnsupported => {
            if (diagnostic.instruction_line != 0 and diagnostic.limit != 0) {
                try stderr.print(
                    "spore build: Dockerfile line {d}: RUN exec form has too many arguments for the guest executor: limit={d} arguments actual={d} arguments\n",
                    .{ diagnostic.instruction_line, diagnostic.limit, diagnostic.actual },
                );
            } else {
                try stderr.writeAll("spore build: RUN exec form has an unsupported argument count\n");
            }
        },
        error.RunArgUnsupported => {
            try stderr.writeAll("spore build: RUN exec form contains an unsupported argument\n");
        },
        error.RunWorkingDirUnsupported => {
            try stderr.writeAll("spore build: WORKDIR is too long for the guest executor\n");
        },
        error.RunCacheMountDeviceBudgetUnsupported => {
            const instruction_line = if (diagnostic.instruction_line != 0)
                diagnostic.instruction_line
            else
                diagnostic.executor.instruction_line;
            if (instruction_line != 0) {
                try stderr.print("spore build: Dockerfile line {d}: RUN cache mounts cannot be combined with a context disk and two stage input disks\n", .{instruction_line});
            } else {
                try stderr.writeAll("spore build: RUN cache mounts exceed the frozen build device budget\n");
            }
        },
        error.RunCacheMountTargetUnsupported => {
            if (diagnostic.instruction_line != 0) {
                try stderr.print("spore build: Dockerfile line {d}: RUN cache mount target must resolve to a non-root path within executor bounds\n", .{diagnostic.instruction_line});
            } else {
                try stderr.writeAll("spore build: RUN cache mount target must resolve to a non-root path within executor bounds\n");
            }
        },
        error.RunCacheMountTargetConflict => {
            if (diagnostic.instruction_line != 0) {
                try stderr.print("spore build: Dockerfile line {d}: RUN cache mount targets overlap after resolution\n", .{diagnostic.instruction_line});
            } else {
                try stderr.writeAll("spore build: RUN cache mount targets overlap after resolution\n");
            }
        },
        error.TooManyRunCacheMounts => {
            if (diagnostic.instruction_line != 0) {
                try stderr.print("spore build: Dockerfile line {d}: RUN has too many cache mounts\n", .{diagnostic.instruction_line});
            } else {
                try stderr.writeAll("spore build: RUN has too many cache mounts\n");
            }
        },
        error.TooManyRunContextBindMounts => {
            try stderr.print("spore build: Dockerfile line {d}: RUN has too many context bind mounts\n", .{diagnostic.instruction_line});
        },
        error.RunContextBindSourceNotFound => {
            try stderr.print(
                "spore build: Dockerfile line {d}: RUN context bind source did not match a context file: {s}\n",
                .{ diagnostic.instruction_line, diagnostic.copy.source },
            );
        },
        error.RunContextBindSourceUnsupported => {
            try stderr.print("spore build: Dockerfile line {d}: RUN context bind source must be one literal regular file inside the build context\n", .{diagnostic.instruction_line});
        },
        error.ContextSourceMtimeOutOfRange => {
            try stderr.print(
                "spore build: Dockerfile line {d}: RUN context bind source mtime is outside the supported ext4 range: {s}\n",
                .{ diagnostic.instruction_line, diagnostic.copy.source },
            );
        },
        error.RunContextBindTargetUnsupported, error.RunContextBindPathUnsupported => {
            try stderr.print("spore build: Dockerfile line {d}: RUN context bind target must resolve to a non-root regular-file path within executor bounds\n", .{diagnostic.instruction_line});
        },
        error.RunMountTargetsOverlap => {
            try stderr.print("spore build: Dockerfile line {d}: RUN mount targets overlap after resolution\n", .{diagnostic.instruction_line});
        },
        error.RunContextBindCommandUnsupported => {
            try stderr.print("spore build: Dockerfile line {d}: RUN context bind mounts require ordinary shell form\n", .{diagnostic.instruction_line});
        },
        error.UnsupportedBuildFrom => {
            try stderr.writeAll("spore build: FROM image reference is not supported\n");
        },
        error.UnsupportedMultiStageDockerfile => {
            try stderr.writeAll("spore build: the planned multi-stage operation is not supported\n");
        },
        error.MissingDockerfileFrom => {
            try stderr.writeAll("spore build: Dockerfile must start from a supported FROM instruction\n");
        },
        error.UnsetBuildArg => {
            try stderr.writeAll("spore build: variable substitution referenced an unset ARG or ENV value\n");
        },
        error.CopySourceEscapesContext => {
            try stderr.writeAll("spore build: COPY source escapes the build context\n");
        },
        error.CopySourceNotFound => {
            if (diagnostic.instruction_line != 0 and diagnostic.copy.source.len != 0) {
                try stderr.print(
                    "spore build: Dockerfile line {d}: COPY source did not match any context path: {s}\n",
                    .{ diagnostic.instruction_line, diagnostic.copy.source },
                );
            } else {
                try stderr.writeAll("spore build: COPY source did not match any context path\n");
            }
        },
        error.BuildContextChangedDuringSnapshot => {
            try stderr.writeAll("spore build: COPY source changed while the build context was being read; retry the build\n");
        },
        error.UnsupportedCopyGlob => {
            try stderr.writeAll("spore build: COPY source pattern is malformed or exceeds the supported pattern bound\n");
        },
        error.UnsupportedCopyFromPattern => {
            try stderr.writeAll("spore build: COPY --from currently requires literal source paths\n");
        },
        error.UnsupportedCopySourceType => {
            try stderr.writeAll("spore build: COPY source must be a regular file, directory, or symlink\n");
        },
        error.CopyDestinationMustBeDirectory => {
            try stderr.writeAll("spore build: COPY with multiple sources requires a directory destination ending in /\n");
        },
        error.CopyDestinationUnsupported => {
            try stderr.writeAll("spore build: COPY destination must stay inside the guest rootfs and fit executor bounds\n");
        },
        error.RemoteAddDestinationUnsupported => {
            try stderr.print("spore build: Dockerfile line {d}: ADD destination must stay inside the guest rootfs and fit executor bounds\n", .{diagnostic.instruction_line});
        },
        error.RemoteAddFilenameUnsupported => {
            try stderr.print("spore build: Dockerfile line {d}: ADD response filename is unsafe or exceeds executor path bounds\n", .{diagnostic.instruction_line});
        },
        error.UnsupportedRemoteAddMode => {
            try stderr.print("spore build: Dockerfile line {d}: ADD --chmod must resolve to an octal value between 0 and 07777\n", .{diagnostic.instruction_line});
        },
        error.UnsupportedRemoteAddUrl, error.UnsupportedRemoteFetchScheme, error.UnsafeRemoteFetchTarget => {
            if (diagnostic.instruction_line != 0) {
                try stderr.print("spore build: Dockerfile line {d}: ADD source must be a public HTTPS URL without credentials, fragments, or Git transport\n", .{diagnostic.instruction_line});
            } else try stderr.writeAll("spore build: ADD source must be a public HTTPS URL without credentials, fragments, or Git transport\n");
        },
        error.RemoteAddBodyTooLarge => {
            try stderr.print(
                "spore build: Dockerfile line {d}: ADD response exceeds the {d}-byte limit\n",
                .{ diagnostic.instruction_line, diagnostic.limit },
            );
        },
        error.RemoteAddAggregateTooLarge => {
            try stderr.print(
                "spore build: Dockerfile line {d}: total ADD responses exceed the {d}-byte build limit\n",
                .{ diagnostic.instruction_line, diagnostic.limit },
            );
        },
        error.RemoteAddCountExceeded => {
            try stderr.print(
                "spore build: Dockerfile line {d}: build has more than {d} remote ADD inputs\n",
                .{ diagnostic.instruction_line, diagnostic.limit },
            );
        },
        error.RemoteAddTimeout => {
            try stderr.print("spore build: Dockerfile line {d}: remote ADD fetch exceeded the build timeout\n", .{diagnostic.instruction_line});
        },
        error.RemoteAddConcurrencyUnavailable => {
            try stderr.print("spore build: Dockerfile line {d}: remote ADD fetch requires cancellable host I/O\n", .{diagnostic.instruction_line});
        },
        error.RemoteAddTooManyRedirects, error.RemoteAddRedirectLocationMissing, error.RemoteAddMalformedResponse, error.RemoteAddUnsupportedContentEncoding => {
            try stderr.print("spore build: Dockerfile line {d}: ADD received an invalid or excessive HTTPS redirect/response chain\n", .{diagnostic.instruction_line});
        },
        error.RemoteAddHttpStatus => {
            try stderr.print("spore build: Dockerfile line {d}: ADD HTTPS request returned a non-success status\n", .{diagnostic.instruction_line});
        },
        error.CopyEntryCountUnsupported => {
            if (diagnostic.instruction_line != 0 and diagnostic.limit != 0) {
                try stderr.print(
                    "spore build: Dockerfile line {d}: COPY has too many entries for the guest executor: path={s} limit={d} entries actual={d} entries\n",
                    .{ diagnostic.instruction_line, if (diagnostic.copy.source.len == 0) "<unknown>" else diagnostic.copy.source, diagnostic.limit, diagnostic.actual },
                );
            } else {
                try stderr.writeAll("spore build: COPY has too many entries for the guest executor\n");
            }
        },
        error.RootFSDigestCacheMiss => {
            try stderr.writeAll("spore build: cached rootfs storage is missing its completeness stamp\n");
        },
        error.BuildInputNotFound => {
            if (diagnostic.missing_input) |missing| switch (missing.kind) {
                .dockerfile => try stderr.print("spore build: Dockerfile not found: {s}\n", .{missing.path}),
                .context => try stderr.print("spore build: build context not found: {s}\n", .{missing.path}),
                .base => try stderr.print("spore build: base image or named build context not found: {s}\n", .{missing.path}),
            } else try stderr.writeAll("spore build: required build input was not found\n");
        },
        error.TooManyBuildInputDisks => {
            if (diagnostic.instruction_line != 0) {
                try stderr.print(
                    "spore build: Dockerfile line {d}: a stage may copy from at most {d} distinct stage, named-context, or image inputs; this instruction requires input {d}\n",
                    .{ diagnostic.instruction_line, diagnostic.limit, diagnostic.actual },
                );
            } else {
                try stderr.writeAll("spore build: a stage may copy from at most two distinct stage, named-context, or image inputs\n");
            }
        },
        error.UnsupportedBuildUser => {
            try stderr.writeAll("spore build: executing RUN, COPY, ADD, or WORKDIR from a non-root inherited USER is not supported yet\n");
        },
        error.UnsupportedOnBuild => {
            try stderr.writeAll("spore build: reachable base image contains unsupported ONBUILD triggers\n");
        },
        else => {
            if (diagnostic.instruction_line != 0) {
                try stderr.print("spore build: Dockerfile line {d}: {s}\n", .{ diagnostic.instruction_line, @errorName(err) });
            } else {
                try stderr.print("spore build: {s}\n", .{@errorName(err)});
            }
        },
    }
}

fn outputLooksLikeEnospc(output: []const u8) bool {
    return std.mem.indexOf(u8, output, "SPORE_BUILD_ENOSPC") != null or
        std.mem.indexOf(u8, output, "No space left on device") != null or
        std.mem.indexOf(u8, output, "ENOSPC") != null;
}

test "build CLI recognizes stable and shell ENOSPC diagnostics" {
    try std.testing.expect(outputLooksLikeEnospc("spore build: SPORE_BUILD_ENOSPC COPY apply failed\n"));
    try std.testing.expect(outputLooksLikeEnospc("mkdir: No space left on device\n"));
    try std.testing.expect(outputLooksLikeEnospc("write failed: ENOSPC\n"));
    try std.testing.expect(!outputLooksLikeEnospc("executor step failed\n"));
}

fn nsToMs(ns: u64) u64 {
    return ns / std.time.ns_per_ms;
}

test "build CLI parses M1 options" {
    const allocator = std.testing.allocator;
    var parsed = try parseArgs(allocator, &.{
        "-t",
        "local/app:dev",
        "--build-context",
        "base=oci-layout://zig-cache/base",
        "--build-arg",
        "MODE=test",
        ".",
    });
    defer parsed.build_contexts.deinit();
    defer parsed.build_args.deinit();
    try std.testing.expectEqualStrings("local/app:dev", parsed.tag.?);
    try std.testing.expectEqualStrings(".", parsed.context_dir.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.build_contexts.items.len);
    try std.testing.expectEqualStrings("base", parsed.build_contexts.items[0].name);
    try std.testing.expectEqualStrings("zig-cache/base", parsed.build_contexts.items[0].oci_layout_path);
    try std.testing.expectEqual(@as(usize, 1), parsed.build_args.items.len);
    try std.testing.expectEqualStrings("MODE", parsed.build_args.items[0].key);
    try std.testing.expectEqualStrings("test", parsed.build_args.items[0].value);
    try std.testing.expect(std.mem.indexOf(u8, usage, "--disk-grow-target") == null);
    for ([_][]const u8{ "--memory", "--vcpus", "--timeout", "--ulimit" }) |option| {
        try std.testing.expect(std.mem.indexOf(u8, usage, option) != null);
    }

    try std.testing.expectError(error.UnknownArgument, parseArgs(allocator, &.{ "--disk-grow-target", "67108864", "." }));
    try std.testing.expectError(error.UnknownArgument, parseArgs(allocator, &.{ "--disk-grow-target=67108864", "." }));
}

test "build CLI bounds nofile ulimit" {
    const one = try parseUlimit("nofile=4096");
    try std.testing.expectEqual(@as(u64, 4096), one.soft);
    try std.testing.expectEqual(@as(u64, 4096), one.hard);
    try std.testing.expectError(error.BadUlimit, parseUlimit("core=1:1"));
    try std.testing.expectError(error.BadUlimit, parseUlimit("nofile=2:1"));
    try std.testing.expectError(error.BadUlimit, parseUlimit("nofile=1:1048577"));
}

test "build CLI reports the instruction that exceeds the stage input limit" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();
    var diagnostic: build_mod.Diagnostic = .{};
    diagnostic.instruction_line = 7;
    diagnostic.limit = 2;
    diagnostic.actual = 3;
    try writeBuildError(&stderr.writer, error.TooManyBuildInputDisks, diagnostic);
    try std.testing.expectEqualStrings(
        "spore build: Dockerfile line 7: a stage may copy from at most 2 distinct stage, named-context, or image inputs; this instruction requires input 3\n",
        stderr.written(),
    );
}

test "build CLI reports an invalid inherited RUN environment at its instruction" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();
    var diagnostic: build_mod.Diagnostic = .{};
    diagnostic.instruction_line = 2;
    try writeBuildError(&stderr.writer, error.InvalidRunEnvironment, diagnostic);
    try std.testing.expectEqualStrings(
        "spore build: Dockerfile line 2: RUN environment contains an invalid entry\n",
        stderr.written(),
    );
}

test "build CLI reports an invalid remote ADD chmod at its instruction" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();
    var diagnostic: build_mod.Diagnostic = .{};
    diagnostic.instruction_line = 9;
    try writeBuildError(&stderr.writer, error.UnsupportedRemoteAddMode, diagnostic);
    try std.testing.expectEqualStrings(
        "spore build: Dockerfile line 9: ADD --chmod must resolve to an octal value between 0 and 07777\n",
        stderr.written(),
    );
}

test "build CLI reports an unknown target without a fake Dockerfile line" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();
    var diagnostic: build_mod.Diagnostic = .{};
    diagnostic.dockerfile.message = "unknown build target: missing";
    try writeBuildError(&stderr.writer, error.DockerfilePlanFailed, diagnostic);
    try std.testing.expectEqualStrings("spore build: unknown build target: missing\n", stderr.written());
}

test "build CLI reports missing inputs without a bare FileNotFound" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        missing: build_mod.MissingInput,
        expected: []const u8,
    }{
        .{ .missing = .{ .kind = .dockerfile, .path = "/tmp/missing/Dockerfile" }, .expected = "spore build: Dockerfile not found: /tmp/missing/Dockerfile\n" },
        .{ .missing = .{ .kind = .context, .path = "/tmp/missing/context" }, .expected = "spore build: build context not found: /tmp/missing/context\n" },
        .{ .missing = .{ .kind = .base, .path = "local/missing:dev" }, .expected = "spore build: base image or named build context not found: local/missing:dev\n" },
    };
    for (cases) |case| {
        var stderr: Io.Writer.Allocating = .init(allocator);
        defer stderr.deinit();
        var diagnostic: build_mod.Diagnostic = .{};
        diagnostic.missing_input = case.missing;
        try writeBuildError(&stderr.writer, error.BuildInputNotFound, diagnostic);
        try std.testing.expectEqualStrings(case.expected, stderr.written());
    }
}
