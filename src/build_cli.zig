const std = @import("std");
const Io = std.Io;

const build_mod = @import("build.zig");
const rootfs_mod = @import("rootfs.zig");

pub const usage =
    \\Usage:
    \\  spore build [options] CONTEXT
    \\
    \\Options:
    \\  -t, --tag REF                  Local image ref to update, for example local/app:dev
    \\  -f, --file PATH                Dockerfile path, defaults to CONTEXT/Dockerfile
    \\  --platform OS/ARCH             Target platform, currently linux/arm64
    \\  --build-context NAME=oci-layout://PATH
    \\                                  Named OCI layout base available to FROM NAME
    \\  --build-arg KEY=VALUE          Build argument value
    \\  --network spore|none           Network mode for build RUN execution
    \\  --no-cache                     Require executor work instead of step-cache hits
    \\  --mkfs PATH                    mkfs helper for OCI layout imports
    \\  --debugfs PATH                 debugfs helper for OCI layout imports
    \\  --disk-headroom BYTES          Accepted for CLI stability; executor sizing lands in M2
    \\  -h, --help                     Show this help
    \\
    \\The M2 RUN slice executes RUN cache misses. COPY cache misses still fail
    \\closed until the COPY executor slice lands.
    \\
;

const ParsedOptions = struct {
    tag: ?[]const u8 = null,
    context_dir: ?[]const u8 = null,
    dockerfile_path: ?[]const u8 = null,
    platform: rootfs_mod.Platform = .{},
    build_contexts: std.array_list.Managed(build_mod.BuildContextArg),
    build_args: std.array_list.Managed(build_mod.BuildArg),
    network: build_mod.NetworkMode = .spore,
    no_cache: bool = false,
    mkfs: ?[]const u8 = null,
    debugfs: ?[]const u8 = null,
};

pub fn run(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    const allocator = init.arena.allocator();
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
        .build_contexts = parsed.build_contexts.items,
        .build_args = parsed.build_args.items,
        .network = parsed.network,
        .no_cache = parsed.no_cache,
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
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !ParsedOptions {
    var parsed = ParsedOptions{
        .build_contexts = std.array_list.Managed(build_mod.BuildContextArg).init(allocator),
        .build_args = std.array_list.Managed(build_mod.BuildArg).init(allocator),
    };
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
        } else if (std.mem.eql(u8, arg, "--mkfs")) {
            parsed.mkfs = try nextValue(args, &i, arg);
        } else if (std.mem.startsWith(u8, arg, "--mkfs=")) {
            parsed.mkfs = try nonEmptyValue(arg["--mkfs=".len..]);
        } else if (std.mem.eql(u8, arg, "--debugfs")) {
            parsed.debugfs = try nextValue(args, &i, arg);
        } else if (std.mem.startsWith(u8, arg, "--debugfs=")) {
            parsed.debugfs = try nonEmptyValue(arg["--debugfs=".len..]);
        } else if (std.mem.eql(u8, arg, "--disk-headroom")) {
            _ = try std.fmt.parseInt(u64, try nextValue(args, &i, arg), 10);
        } else if (std.mem.startsWith(u8, arg, "--disk-headroom=")) {
            _ = try std.fmt.parseInt(u64, try nonEmptyValue(arg["--disk-headroom=".len..]), 10);
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
        error.BadPlatform, error.UnsupportedPlatform => "spore build: --platform must be linux/arm64",
        error.InvalidCharacter, error.Overflow => "spore build: --disk-headroom must be a base-10 byte count",
        else => "spore build: invalid arguments",
    };
    try stderr.print("{s}\n", .{message});
}

fn writeBuildError(stderr: *Io.Writer, err: anyerror, diagnostic: build_mod.Diagnostic) !void {
    switch (err) {
        error.DockerfileParseFailed => {
            if (diagnostic.dockerfile.message.len != 0) {
                try stderr.print("spore build: Dockerfile line {d}: {s}\n", .{ diagnostic.dockerfile.line, diagnostic.dockerfile.message });
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
        error.BuildCopyExecutorPending => {
            try stderr.writeAll("spore build: COPY cache miss requires the M2 COPY executor slice; cached COPY steps before the first RUN miss are still supported\n");
        },
        error.BuildRunFailed => {
            if (diagnostic.executor.instruction) |instruction| {
                try stderr.print("spore build: RUN instruction failed: {s}\n", .{instruction});
            }
            if (diagnostic.executor.exit_code) |code| {
                try stderr.print("spore build: RUN failed with exit code {d}\n", .{code});
            } else {
                try stderr.writeAll("spore build: RUN failed\n");
            }
            if (diagnostic.executor.output.len != 0) {
                try stderr.writeAll(diagnostic.executor.output);
                if (!std.mem.endsWith(u8, diagnostic.executor.output, "\n")) try stderr.writeAll("\n");
            }
        },
        error.BuildGuestFreezeFailed => {
            try stderr.writeAll("spore build: guest fsfreeze failed before recording a step cache entry\n");
        },
        error.BuildGuestThawFailed => {
            try stderr.writeAll("spore build: guest fsthaw failed after the step snapshot was recorded\n");
        },
        error.BuildGuestProtocolFailed => {
            try stderr.writeAll("spore build: guest executor protocol failed\n");
        },
        error.BuildGuestTimedOut => {
            try stderr.writeAll("spore build: guest executor step timed out\n");
        },
        error.RunEnvCountUnsupported => {
            try stderr.writeAll("spore build: RUN environment has too many entries for the guest executor\n");
        },
        error.RunEnvTooLong => {
            try stderr.writeAll("spore build: RUN environment entry is too long for the guest executor\n");
        },
        error.RunRequestTooLarge => {
            try stderr.writeAll("spore build: RUN request is too large for the guest executor\n");
        },
        error.RunCommandTooLong => {
            try stderr.writeAll("spore build: RUN shell command is too long for the guest executor\n");
        },
        error.RunWorkingDirUnsupported => {
            try stderr.writeAll("spore build: WORKDIR is too long for the guest executor\n");
        },
        error.UnsupportedBuildFrom => {
            try stderr.writeAll("spore build: FROM must be a local image ref or a named --build-context OCI layout in M1\n");
        },
        error.UnsupportedMultiStageDockerfile => {
            try stderr.writeAll("spore build: multi-stage Dockerfiles are not supported in this subset\n");
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
            try stderr.writeAll("spore build: COPY source did not match any context path\n");
        },
        error.UnsupportedCopyGlob => {
            try stderr.writeAll("spore build: COPY only supports literal paths and single-component * globs\n");
        },
        error.UnsupportedCopySourceType => {
            try stderr.writeAll("spore build: COPY source must be a regular file, directory, or symlink\n");
        },
        error.RootFSDigestCacheMiss => {
            try stderr.writeAll("spore build: cached rootfs storage is missing its completeness stamp\n");
        },
        else => {
            try stderr.print("spore build: {s}\n", .{@errorName(err)});
        },
    }
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
}
