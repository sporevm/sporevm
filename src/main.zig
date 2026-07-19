//! The `spore` CLI.
//!
//! `spore run` is the one-shot path. Named VM lifecycle commands are backed by
//! local monitor processes; see docs/lifecycle.md.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const spore_internal = @import("spore_internal");
const spore_api = spore_internal.api;
const machine_output = spore_internal.machine_output;

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

var runtime_log_level: std.log.Level = .warn;

const usage =
    \\Usage: spore [--debug] [--json] <command>
    \\
    \\Global options:
    \\  --debug             Show verbose VMM and restore logs
    \\  --json              Emit one JSON result for supported state and bundle commands
    \\                      Use --events=jsonl for run/attach stream events
    \\
    \\Commands:
    \\  One-shot VMs:
    \\    run [options] 'shell command'
    \\                        Boot a throwaway VM and run one command
    \\    attach <spore-dir>
    \\                        Restore a spore and attach to a saved session
    \\
    \\  Named VMs:
    \\    create NAME [options] ['shell command']
    \\                        Create a named VM lifecycle target
    \\    exec NAME 'shell command'
    \\                        Execute a command in a named VM
    \\    copy-in NAME HOST_PATH GUEST_PATH
    \\                        Copy one host file or directory into a named VM
    \\    copy-out NAME GUEST_PATH HOST_PATH
    \\                        Copy one guest file or directory out of a named VM
    \\    save NAME --out DIR [--stop]
    \\                        Save a named VM into a spore; --stop removes the VM
    \\    restore <spore-dir> --name NAME
    \\                        Restore a spore as a named VM
    \\    fork --vm NAME --count N --name PATTERN
    \\                        Fork a running named VM into named children
    \\    ls, ps              List named VMs in the local runtime registry
    \\    rm NAME             Remove a named VM
    \\
    \\  Spore artifacts:
    \\    inspect <spore-dir> Print a spore manifest summary
    \\    fork <spore-dir> --count N --out DIR
    \\                        Mint child spores that share parent chunks
    \\    fanout <children-dir> [--for DURATION]
    \\                        Attach forked children concurrently with prefixed output
    \\    pack <spore-dir> [--children DIR] [--rootfs=exact|metadata-only] --out DIR
    \\                        Pack portable spore chunks into a local bundle
    \\    unpack <bundle-dir> [--child ID] [--allow-metadata-only-rootfs] --out DIR
    \\                        Unpack a local spore bundle into a spore dir
    \\    push <bundle-dir> s3://BUCKET/PREFIX [--region REGION]
    \\                        Push an indexed bundle to an object store
    \\    inspect-bundle <bundle-ref> [--child ID|--child-range START..END]
    \\                        Inspect bundle metadata without materializing it
    \\    pull file://BUNDLE|s3://BUNDLE@sha256:DIGEST|http(s)://BUNDLE@sha256:DIGEST [--child ID] [--allow-metadata-only-rootfs] --out DIR [--region REGION]
    \\                        Pull one child into a spore dir
    \\
    \\  Rootfs and local system:
    \\    build [options] CONTEXT
    \\                        Build a Spore image from a Dockerfile subset
    \\    rootfs              Build rootfs images from OCI images
    \\    cache               Inspect and collect local content-addressed caches
    \\    system              Inspect and prune local SporeVM system state
    \\    host-info           Print this host's platform facts
    \\    version             Print the spore version
    \\    help                Show this help
    \\
;

const pack_usage =
    \\Usage:
    \\  spore pack <spore-dir> [--children DIR] [--rootfs=exact|metadata-only] --out DIR
    \\
    \\Options:
    \\  --children DIR        Include forked child spores in the bundle
    \\  --rootfs POLICY       Rootfs bundle policy: exact or metadata-only
    \\                        metadata-only requires the same rootfs cache on unpack
    \\  --out DIR             Write the local bundle to DIR
    \\  -h, --help            Show this help
    \\
;

const unpack_usage =
    \\Usage:
    \\  spore unpack <bundle-dir> [--child ID] [--allow-metadata-only-rootfs] --out DIR
    \\
    \\Options:
    \\  --child ID                    Materialize one child from the bundle
    \\  --allow-metadata-only-rootfs  Allow metadata-only rootfs descriptors
    \\  --out DIR                     Write the unpacked spore to DIR
    \\  -h, --help                    Show this help
    \\
;

const push_usage =
    \\Usage:
    \\  spore push <bundle-dir> s3://BUCKET/PREFIX [--region REGION]
    \\
    \\Options:
    \\  --region REGION      AWS region for S3 destinations
    \\  -h, --help           Show this help
    \\
;

const inspect_bundle_usage =
    \\Usage:
    \\  spore inspect-bundle <bundle-ref> [--child ID|--child-range START..END]
    \\
    \\Options:
    \\  --child ID               Inspect one child entry
    \\  --child-range START..END Inspect an inclusive range of child entries
    \\  -h, --help               Show this help
    \\
;

const pull_usage =
    \\Usage:
    \\  spore pull file://BUNDLE|s3://BUNDLE@sha256:DIGEST|http(s)://BUNDLE@sha256:DIGEST [--child ID] [--allow-metadata-only-rootfs] --out DIR [--region REGION]
    \\
    \\Options:
    \\  --child ID                    Pull one child from the bundle
    \\  --allow-metadata-only-rootfs  Allow metadata-only rootfs descriptors
    \\  --out DIR                     Write the materialized spore to DIR
    \\  --region REGION              AWS region for S3 sources
    \\  -h, --help                    Show this help
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    const parsed = parseGlobalArgs(args);
    if (parsed.debug) runtime_log_level = .debug;

    if (parsed.parse_error) |parse_error| {
        const message = allocMessage(arena, "unknown global option: {s}", .{parse_error.arg});
        exitWithCliError(arena, stderr, parsed.mode, machine_output.usageInvalidArgument(message, "GlobalArgs"), messageWithUsage(arena, message));
    }

    if (parsed.help or parsed.command == null) {
        if (parsed.command == null and parsed.mode == .json and !parsed.help) {
            const message = "missing command";
            exitWithCliError(arena, stderr, parsed.mode, machine_output.usageMissingArgument(message, "GlobalArgs"), message);
        }
        try stdout.writeAll(usage);
        try stdout.flush();
        std.process.exit(if (parsed.help) 0 else 2);
    }

    const command = parsed.command.?;
    const command_args = parsed.command_args;
    runCommand(init, arena, stdout, stderr, command, command_args, parsed.mode) catch |err| {
        if (parsed.mode == .json) {
            exitWithCliError(arena, stderr, parsed.mode, machine_output.fromZigError(err), machine_output.fromZigError(err).message);
        }
        return err;
    };
    try stdout.flush();
}

fn runCommand(
    init: std.process.Init,
    arena: std.mem.Allocator,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    command: []const u8,
    command_args: []const []const u8,
    mode: machine_output.Mode,
) !void {
    if (mode == .json and !supportsJson(command)) {
        const message = allocMessage(arena, "spore --json does not support command: {s}", .{command});
        exitWithCliError(arena, stderr, mode, machine_output.usageInvalidArgument(message, "GlobalJson"), message);
    }

    const context = spore_api.Context{
        .io = init.io,
        .environ_map = init.environ_map,
    };

    if (std.mem.eql(u8, command, "system")) {
        try spore_internal.system.run(init, command_args, stdout, stderr, mode);
    } else if (std.mem.eql(u8, command, "cache")) {
        try spore_internal.system.cacheRun(init, command_args, stdout, stderr, mode);
    } else if (std.mem.eql(u8, command, "rootfs")) {
        try spore_internal.rootfs_cli.run(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "build")) {
        try spore_internal.build_cli.run(init, command_args, stdout, stderr);
    } else if (std.mem.eql(u8, command, "run")) {
        try spore_internal.run_cli.cli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "attach")) {
        if (mode == .json) {
            const message = "spore --json attach is not supported; use --events=jsonl for attach stream events";
            exitWithCliError(arena, stderr, mode, machine_output.usageInvalidArgument(message, "attach"), message);
        }
        try spore_internal.attach_cli.cli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "create")) {
        try spore_internal.lifecycle.createCli(init, command_args, stdout, stderr, mode);
    } else if (std.mem.eql(u8, command, "exec")) {
        try spore_internal.lifecycle.execCli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "copy-in")) {
        try spore_internal.lifecycle.copyInCli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "copy-out")) {
        try spore_internal.lifecycle.copyOutCli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "rm")) {
        try spore_internal.lifecycle.rmCli(init, command_args, stdout, stderr, mode);
    } else if (std.mem.eql(u8, command, "save")) {
        try spore_internal.lifecycle.saveCli(init, command_args, stdout, stderr, mode);
    } else if (std.mem.eql(u8, command, "restore")) {
        try spore_internal.lifecycle.restoreCli(init, command_args, stdout, stderr, mode);
    } else if (std.mem.eql(u8, command, "ls") or std.mem.eql(u8, command, "ps")) {
        try spore_internal.lifecycle.lsCli(init, command_args, stdout, stderr, mode);
    } else if (std.mem.eql(u8, command, "monitor")) {
        try spore_internal.monitor.cli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "netd")) {
        try spore_internal.spore_netd.cli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "version")) {
        if (wantsCommandHelp(command_args)) {
            try stdout.writeAll("usage: spore version\n");
            return;
        }
        try stdout.print("spore {s} ({t})\n", .{ spore_internal.version, builtin.mode });
    } else if (std.mem.eql(u8, command, "host-info")) {
        if (wantsCommandHelp(command_args)) {
            try stdout.writeAll("usage: spore host-info\n");
            return;
        }
        if (command_args.len != 0) {
            if (std.mem.startsWith(u8, command_args[0], "--")) {
                exitUnknownArgument(arena, stderr, mode, "host-info", command_args[0]);
            }
            exitUnexpectedArgument(arena, stderr, mode, "host-info", command_args[0]);
        }
        const info = try spore_api.hostInfo(context, arena);
        if (mode == .json) {
            try machine_output.writeJson(arena, stdout, info);
        } else {
            try writeHostInfo(stdout, info);
        }
    } else if (std.mem.eql(u8, command, "inspect")) {
        if (wantsCommandHelp(command_args)) {
            try stdout.writeAll("usage: spore inspect <spore-dir>\n");
            return;
        }
        if (command_args.len != 1) {
            exitWithCliError(arena, stderr, mode, machine_output.usageMissingArgument("usage: spore inspect <spore-dir>", "inspect"), "usage: spore inspect <spore-dir>");
        }
        const summary = try spore_api.inspectSpore(arena, command_args[0]);
        if (mode == .json) {
            try machine_output.writeJson(arena, stdout, summary);
        } else {
            try writeInspectSummary(stdout, summary);
        }
    } else if (std.mem.eql(u8, command, "fork")) {
        if (spore_internal.lifecycle.wantsNamedFork(command_args)) {
            try spore_internal.lifecycle.forkCli(init, command_args, stdout, stderr, mode);
        } else {
            const result = try forkCommand(context, arena, stderr, mode, command_args);
            if (mode == .json) {
                try machine_output.writeJson(arena, stdout, result);
            } else {
                try writeForkResult(stdout, result);
            }
        }
    } else if (std.mem.eql(u8, command, "fanout")) {
        try spore_internal.fanout.cli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "pack")) {
        if (wantsCommandHelp(command_args)) {
            try stdout.writeAll(pack_usage);
            return;
        }
        const result = try packCommand(context, arena, stderr, mode, command_args);
        if (mode == .json) {
            try machine_output.writeJson(arena, stdout, result);
        } else {
            try writePackResult(stdout, result);
        }
    } else if (std.mem.eql(u8, command, "unpack")) {
        if (wantsCommandHelp(command_args)) {
            try stdout.writeAll(unpack_usage);
            return;
        }
        const result = try unpackCommand(context, arena, stderr, mode, command_args);
        if (mode == .json) {
            try machine_output.writeJson(arena, stdout, result);
        } else {
            try writeUnpackResult(stdout, result);
        }
    } else if (std.mem.eql(u8, command, "push")) {
        if (wantsCommandHelp(command_args)) {
            try stdout.writeAll(push_usage);
            return;
        }
        const result = try pushCommand(context, arena, stderr, mode, command_args);
        if (mode == .json) {
            try machine_output.writeJson(arena, stdout, result);
        } else {
            try writePushResult(stdout, result);
        }
    } else if (std.mem.eql(u8, command, "inspect-bundle")) {
        if (wantsCommandHelp(command_args)) {
            try stdout.writeAll(inspect_bundle_usage);
            return;
        }
        const result = try inspectBundleCommand(arena, stderr, mode, command_args);
        if (mode == .json) {
            try machine_output.writeJson(arena, stdout, result);
        } else {
            try writeInspectBundleResult(stdout, result);
        }
    } else if (std.mem.eql(u8, command, "pull")) {
        if (wantsCommandHelp(command_args)) {
            try stdout.writeAll(pull_usage);
            return;
        }
        const result = try pullCommand(context, arena, stderr, mode, command_args);
        if (mode == .json) {
            try machine_output.writeJson(arena, stdout, result);
        } else {
            try writePullResult(stdout, result);
        }
    } else if (std.mem.eql(u8, command, "help")) {
        try stdout.writeAll(usage);
    } else if (renamedCommandHint(command)) |hint| {
        const message = allocMessage(arena, "spore {s} was renamed; {s}", .{ command, hint });
        exitWithCliError(arena, stderr, mode, machine_output.usageInvalidArgument(message, "CommandDispatch"), message);
    } else {
        const message = allocMessage(arena, "unknown command: {s}", .{command});
        exitWithCliError(arena, stderr, mode, machine_output.usageInvalidArgument(message, "CommandDispatch"), messageWithUsage(arena, message));
    }
}

/// Redirect hints for command spellings removed in the spore/saved-session
/// rename. The old commands stay non-functional so the new vocabulary is
/// unambiguous, but users get pointed at the replacement instead of a
/// generic unknown-command error.
fn renamedCommandHint(command: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, command, "resume")) {
        return "use `spore attach <spore-dir>` to attach a saved session, or `spore restore <spore-dir> --name NAME` to restore a named VM";
    }
    if (std.mem.eql(u8, command, "suspend")) {
        return "use `spore save NAME --out DIR --stop`";
    }
    return null;
}

fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(runtime_log_level)) {
        std.log.defaultLog(message_level, scope, format, args);
    }
}

const GlobalArgs = struct {
    debug: bool = false,
    mode: machine_output.Mode = .human,
    help: bool = false,
    command: ?[]const u8 = null,
    command_args: []const []const u8 = &.{},
    parse_error: ?GlobalParseError = null,
};

const GlobalParseError = struct {
    arg: []const u8,
};

fn parseGlobalArgs(args: []const []const u8) GlobalArgs {
    var parsed = GlobalArgs{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--debug")) {
            parsed.debug = true;
        } else if (std.mem.eql(u8, args[i], "--json")) {
            parsed.mode = .json;
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            parsed.help = true;
            return parsed;
        } else if (std.mem.startsWith(u8, args[i], "-")) {
            parsed.parse_error = .{ .arg = args[i] };
            return parsed;
        } else {
            parsed.command = args[i];
            parsed.command_args = args[i + 1 ..];
            return parsed;
        }
    }
    return parsed;
}

fn supportsJson(command: []const u8) bool {
    return std.mem.eql(u8, command, "system") or
        std.mem.eql(u8, command, "cache") or
        std.mem.eql(u8, command, "create") or
        std.mem.eql(u8, command, "rm") or
        std.mem.eql(u8, command, "restore") or
        std.mem.eql(u8, command, "save") or
        std.mem.eql(u8, command, "host-info") or
        std.mem.eql(u8, command, "inspect") or
        std.mem.eql(u8, command, "ls") or
        std.mem.eql(u8, command, "ps") or
        std.mem.eql(u8, command, "fork") or
        std.mem.eql(u8, command, "pack") or
        std.mem.eql(u8, command, "unpack") or
        std.mem.eql(u8, command, "push") or
        std.mem.eql(u8, command, "inspect-bundle") or
        std.mem.eql(u8, command, "pull");
}

fn allocMessage(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(allocator, fmt, args) catch "CLI argument error";
}

fn messageWithUsage(allocator: std.mem.Allocator, message: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ message, usage }) catch message;
}

fn exitWithCliError(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    err: machine_output.CliError,
    human_text: []const u8,
) noreturn {
    if (mode == .json) {
        machine_output.writeError(allocator, stderr, err) catch {};
    } else {
        stderr.writeAll(human_text) catch {};
        if (!std.mem.endsWith(u8, human_text, "\n")) stderr.writeByte('\n') catch {};
    }
    stderr.flush() catch {};
    std.process.exit(err.exit_code);
}

fn exitUnknownArgument(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    arg: []const u8,
) noreturn {
    const message = allocMessage(allocator, "unknown {s} argument: {s}", .{ command, arg });
    exitWithCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
}

fn exitUnexpectedArgument(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    arg: []const u8,
) noreturn {
    const message = allocMessage(allocator, "unexpected {s} argument: {s}", .{ command, arg });
    exitWithCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
}

fn exitInvalidValue(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    flag: []const u8,
    value: []const u8,
) noreturn {
    const message = allocMessage(allocator, "spore {s}: invalid {s}: {s}", .{ command, flag, value });
    exitWithCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
}

fn exitUsage(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    usage_line: []const u8,
) noreturn {
    exitWithCliError(allocator, stderr, mode, machine_output.usageMissingArgument(usage_line, command), usage_line);
}

fn wantsCommandHelp(args: []const []const u8) bool {
    if (args.len == 1 and std.mem.eql(u8, args[0], "help")) return true;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) return false;
        if (isHelpFlag(arg)) return true;
    }
    return false;
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or
        std.mem.eql(u8, arg, "--help");
}

fn forkCommand(
    context: spore_api.Context,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    args: []const []const u8,
) !spore_api.ForkResult {
    var parent_dir: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var count: ?usize = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--count") and i + 1 < args.len) {
            i += 1;
            count = std.fmt.parseInt(usize, args[i], 10) catch {
                exitInvalidValue(allocator, stderr, mode, "fork", "--count", args[i]);
            };
        } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            exitUnknownArgument(allocator, stderr, mode, "fork", args[i]);
        } else if (parent_dir == null) {
            parent_dir = args[i];
        } else {
            exitUnexpectedArgument(allocator, stderr, mode, "fork", args[i]);
        }
    }

    if (parent_dir == null or out_dir == null or count == null) {
        exitUsage(allocator, stderr, mode, "fork", "usage: spore fork <spore-dir> --count N --out DIR");
    }

    return spore_api.fork(context, allocator, .{
        .parent_dir = parent_dir.?,
        .out_dir = out_dir.?,
        .count = count.?,
    }) catch |err| switch (err) {
        error.UnsupportedVcpuCount => {
            const inspected = spore_api.inspectSpore(allocator, parent_dir.?) catch return err;
            const vcpu_count = inspected.vcpu_count;
            spore_api.deinitSporeInspectResult(allocator, inspected);
            const message = machine_output.forkUnsupportedVcpuMessage(allocator, vcpu_count);
            exitWithCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        else => |e| return e,
    };
}

fn packCommand(
    context: spore_api.Context,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    args: []const []const u8,
) !spore_api.PackResult {
    var spore_dir: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var children_dir: ?[]const u8 = null;
    var rootfs_policy: spore_api.RootfsBundlePolicy = .exact_bytes;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--children") and i + 1 < args.len) {
            i += 1;
            children_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--rootfs") and i + 1 < args.len) {
            i += 1;
            rootfs_policy = parseRootfsBundlePolicy(args[i]) orelse {
                exitInvalidValue(allocator, stderr, mode, "pack", "--rootfs", args[i]);
            };
        } else if (std.mem.startsWith(u8, args[i], "--rootfs=")) {
            const value = args[i]["--rootfs=".len..];
            rootfs_policy = parseRootfsBundlePolicy(value) orelse {
                exitInvalidValue(allocator, stderr, mode, "pack", "--rootfs", value);
            };
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            exitUnknownArgument(allocator, stderr, mode, "pack", args[i]);
        } else if (spore_dir == null) {
            spore_dir = args[i];
        } else {
            exitUnexpectedArgument(allocator, stderr, mode, "pack", args[i]);
        }
    }

    if (spore_dir == null or out_dir == null) {
        exitUsage(allocator, stderr, mode, "pack", "usage: spore pack <spore-dir> [--children DIR] [--rootfs=exact|metadata-only] --out DIR");
    }

    return spore_api.pack(context, allocator, .{
        .spore_dir = spore_dir.?,
        .out_dir = out_dir.?,
        .children_dir = children_dir,
        .rootfs_policy = rootfs_policy,
    }) catch |err| switch (err) {
        error.UnsupportedMetadataOnlyRootfsStorage => {
            const message = "spore pack: --rootfs=metadata-only cannot pack chunked image/rootfs storage yet; use --rootfs=exact";
            exitWithCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "pack"), message);
        },
        else => |e| return e,
    };
}

fn unpackCommand(
    context: spore_api.Context,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    args: []const []const u8,
) !spore_api.UnpackResult {
    var bundle_dir: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var child_id: ?[]const u8 = null;
    var allow_metadata_only_rootfs = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--child") and i + 1 < args.len) {
            i += 1;
            child_id = args[i];
        } else if (std.mem.eql(u8, args[i], "--allow-metadata-only-rootfs")) {
            allow_metadata_only_rootfs = true;
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            exitUnknownArgument(allocator, stderr, mode, "unpack", args[i]);
        } else if (bundle_dir == null) {
            bundle_dir = args[i];
        } else {
            exitUnexpectedArgument(allocator, stderr, mode, "unpack", args[i]);
        }
    }

    if (bundle_dir == null or out_dir == null) {
        exitUsage(allocator, stderr, mode, "unpack", "usage: spore unpack <bundle-dir> [--child ID] [--allow-metadata-only-rootfs] --out DIR");
    }

    return spore_api.unpack(context, allocator, .{
        .bundle_dir = bundle_dir.?,
        .out_dir = out_dir.?,
        .child_id = child_id,
        .allow_metadata_only_rootfs = allow_metadata_only_rootfs,
    });
}

fn pushCommand(
    context: spore_api.Context,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    args: []const []const u8,
) !spore_api.PushResult {
    var bundle_dir: ?[]const u8 = null;
    var destination: ?[]const u8 = null;
    var aws_region: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--region") and i + 1 < args.len) {
            i += 1;
            aws_region = args[i];
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            exitUnknownArgument(allocator, stderr, mode, "push", args[i]);
        } else if (bundle_dir == null) {
            bundle_dir = args[i];
        } else if (destination == null) {
            destination = args[i];
        } else {
            exitUnexpectedArgument(allocator, stderr, mode, "push", args[i]);
        }
    }

    if (bundle_dir == null or destination == null) {
        exitUsage(allocator, stderr, mode, "push", "usage: spore push <bundle-dir> s3://BUCKET/PREFIX [--region REGION]");
    }

    return spore_api.push(context, allocator, .{
        .bundle_dir = bundle_dir.?,
        .destination = destination.?,
        .aws_region = aws_region,
    });
}

fn inspectBundleCommand(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    args: []const []const u8,
) !spore_api.InspectBundleResult {
    var source: ?[]const u8 = null;
    var child_id: ?[]const u8 = null;
    var child_range: ?spore_api.ChildRange = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--child")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                exitUsage(allocator, stderr, mode, "inspect-bundle", "usage: spore inspect-bundle <bundle-ref> [--child ID|--child-range START..END]");
            }
            i += 1;
            if (child_range != null) {
                exitWithInvalidCombination(allocator, stderr, mode, "inspect-bundle", "--child", "--child-range");
            }
            child_id = args[i];
        } else if (std.mem.eql(u8, args[i], "--child-range")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                exitUsage(allocator, stderr, mode, "inspect-bundle", "usage: spore inspect-bundle <bundle-ref> [--child ID|--child-range START..END]");
            }
            i += 1;
            if (child_id != null) {
                exitWithInvalidCombination(allocator, stderr, mode, "inspect-bundle", "--child", "--child-range");
            }
            child_range = parseChildRange(args[i]) orelse {
                exitInvalidValue(allocator, stderr, mode, "inspect-bundle", "--child-range", args[i]);
            };
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            exitUnknownArgument(allocator, stderr, mode, "inspect-bundle", args[i]);
        } else if (source == null) {
            source = args[i];
        } else {
            exitUnexpectedArgument(allocator, stderr, mode, "inspect-bundle", args[i]);
        }
    }

    if (source == null) {
        exitUsage(allocator, stderr, mode, "inspect-bundle", "usage: spore inspect-bundle <bundle-ref> [--child ID|--child-range START..END]");
    }

    return spore_api.inspectBundle(allocator, .{
        .source = source.?,
        .child_id = child_id,
        .child_range = child_range,
    });
}

fn pullCommand(
    context: spore_api.Context,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    args: []const []const u8,
) !spore_api.PullResult {
    var source: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var child_id: ?[]const u8 = null;
    var aws_region: ?[]const u8 = null;
    var allow_metadata_only_rootfs = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--child") and i + 1 < args.len) {
            i += 1;
            child_id = args[i];
        } else if (std.mem.eql(u8, args[i], "--region") and i + 1 < args.len) {
            i += 1;
            aws_region = args[i];
        } else if (std.mem.eql(u8, args[i], "--allow-metadata-only-rootfs")) {
            allow_metadata_only_rootfs = true;
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            exitUnknownArgument(allocator, stderr, mode, "pull", args[i]);
        } else if (source == null) {
            source = args[i];
        } else {
            exitUnexpectedArgument(allocator, stderr, mode, "pull", args[i]);
        }
    }

    if (source == null or out_dir == null) {
        exitUsage(allocator, stderr, mode, "pull", "usage: spore pull file://BUNDLE|s3://BUNDLE@sha256:DIGEST|http(s)://BUNDLE@sha256:DIGEST [--child ID] [--allow-metadata-only-rootfs] --out DIR [--region REGION]");
    }

    return spore_api.pull(context, allocator, .{
        .source = source.?,
        .out_dir = out_dir.?,
        .child_id = child_id,
        .allow_metadata_only_rootfs = allow_metadata_only_rootfs,
        .aws_region = aws_region,
    });
}

fn exitWithInvalidCombination(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    first: []const u8,
    second: []const u8,
) noreturn {
    const message = allocMessage(allocator, "spore {s}: cannot combine {s} and {s}", .{ command, first, second });
    exitWithCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
}

fn parseChildRange(value: []const u8) ?spore_api.ChildRange {
    const sep = std.mem.indexOf(u8, value, "..") orelse return null;
    if (sep == 0 or sep + 2 >= value.len) return null;
    const start = std.fmt.parseInt(u32, value[0..sep], 10) catch return null;
    const end = std.fmt.parseInt(u32, value[sep + 2 ..], 10) catch return null;
    if (start > end) return null;
    return .{ .start = start, .end = end };
}

fn parseRootfsBundlePolicy(value: []const u8) ?spore_api.RootfsBundlePolicy {
    if (std.mem.eql(u8, value, "exact") or std.mem.eql(u8, value, "exact-bytes")) return .exact_bytes;
    if (std.mem.eql(u8, value, "metadata-only")) return .metadata_only;
    return null;
}

fn writeHostInfo(writer: *Io.Writer, info: spore_api.HostInfo) !void {
    try writer.writeAll("Host info\n");
    try writer.print("  Class: {s}\n", .{info.host_class});
    try writer.print("  Platform: {s}/{s}\n", .{ info.platform.os, info.platform.arch.name() });
    try writer.print("  CPU profile: {s}\n", .{info.platform.cpu_profile});
    try writer.print("  Device model version: {d}\n", .{info.platform.device_model_version});
    try writer.print("  Counter frequency: {d} Hz ({s})\n", .{ info.platform.counter_frequency_hz, info.platform.counter_frequency_source });
    try writer.writeAll("  Backends:\n");
    for (info.backends) |backend| {
        try writer.print("    {s}: supported={s} available={s} reason={s}\n", .{
            backend.name,
            yesNo(backend.supported),
            yesNo(backend.available),
            backend.reason,
        });
    }
    try writer.writeAll("  Cache roots:\n");
    try writePathFact(writer, "kernels", info.cache_roots.kernels);
    try writePathFact(writer, "rootfs", info.cache_roots.rootfs);
    try writePathFact(writer, "bundles", info.cache_roots.bundles);
    try writePathFact(writer, "runtime", info.cache_roots.runtime);
}

fn writePathFact(writer: *Io.Writer, label: []const u8, fact: spore_api.PathFact) !void {
    if (fact.path) |path| {
        try writer.print("    {s}: {s}\n", .{ label, path });
    } else {
        try writer.print("    {s}: unresolved ({s})\n", .{ label, fact.source });
    }
}

fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

fn writeInspectSummary(writer: *Io.Writer, summary: spore_api.SporeInspectResult) !void {
    try writer.writeAll("Spore manifest\n");
    try writer.print("  Version: {d}\n", .{summary.version});
    try writer.print("  Platform: {s}/{s}, {d} bytes RAM\n", .{ summary.platform.arch, summary.platform.cpu_profile, summary.platform.ram_size });
    try writer.print("  vCPUs: {d}\n", .{summary.vcpu_count});
    try writer.print("  Devices: {d}\n", .{summary.device_count});
    try writer.print("  Memory chunks: {d} present of {d}\n", .{ summary.present_memory_chunk_count, summary.memory_chunk_count });
    if (summary.memory_backing_kind) |kind| {
        try writer.print("  Memory backing: {s}", .{kind});
        if (summary.memory_backing_size) |size| try writer.print(", {d} bytes", .{size});
        try writer.writeByte('\n');
    } else {
        try writer.writeAll("  Memory backing: none\n");
    }
    try writer.print("  GIC: {s}\n", .{summary.gic_kind});
    if (summary.sessions.len == 0) {
        try writer.writeAll("  Sessions: none\n");
    } else {
        try writer.print("  Sessions: {d}\n", .{summary.sessions.len});
        for (summary.sessions) |session| {
            try writer.print("    - {s}: stdin={s} stdout={s} stderr={s} terminal={s}\n", .{
                session.id,
                yesNo(session.streams.stdin),
                yesNo(session.streams.stdout),
                yesNo(session.streams.stderr),
                yesNo(session.streams.terminal),
            });
        }
    }
    if (summary.annotations.map.count() == 0) {
        try writer.writeAll("  Annotations: none\n");
    } else {
        try writer.print("  Annotations: {d}\n", .{summary.annotations.map.count()});
        var annotation_it = summary.annotations.map.iterator();
        while (annotation_it.next()) |entry| {
            try writer.print("    - {s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }
}

fn writeForkResult(writer: *Io.Writer, result: spore_api.ForkResult) !void {
    try writer.writeAll("Fork complete\n");
    try writer.print("  Parent: {s}\n", .{result.parent});
    try writer.print("  Children: {d}\n", .{result.count});
    try writer.print("  Output: {s}\n", .{result.out_dir});
    try writer.print("  Generation range: {d}..{d}\n", .{ result.first_generation, result.last_generation });
    if (result.pin_publish_ms) |ms| try writer.print("  Pin publish: {d}ms\n", .{ms});
    if (result.pin_lock_wait_ms) |ms| try writer.print("  Pin lock wait: {d}ms\n", .{ms});
}

fn writePackResult(writer: *Io.Writer, result: spore_api.PackResult) !void {
    try writer.writeAll("Bundle packed\n");
    try writer.print("  Source: {s}\n", .{result.source});
    try writer.print("  Output: {s}\n", .{result.out_dir});
    try writer.print("  Bundle digest: sha256:{s}\n", .{result.bundle_digest});
    try writer.print("  Chunks: {d} packed of {d}\n", .{ result.packed_chunk_count, result.chunk_count });
    try writer.print("  Payload bytes: {d}\n", .{result.payload_bytes});
    try writer.print("  Children: {d}\n", .{result.child_count});
    if (result.rootfs_artifact_count > 0) {
        try writer.print("  Rootfs artifacts: {d}, {d} bytes\n", .{ result.rootfs_artifact_count, result.rootfs_payload_bytes });
    }
}

fn writeUnpackResult(writer: *Io.Writer, result: spore_api.UnpackResult) !void {
    try writer.writeAll("Bundle unpacked\n");
    try writer.print("  Bundle: {s}\n", .{result.bundle});
    try writer.print("  Output: {s}\n", .{result.out_dir});
    try writer.print("  Bundle digest: sha256:{s}\n", .{result.bundle_digest});
    try writer.print("  Chunks: {d} unpacked of {d}\n", .{ result.unpacked_chunk_count, result.chunk_count });
    try writer.print("  Payload bytes: {d}\n", .{result.payload_bytes});
    try writer.print("  Children: {d}\n", .{result.child_count});
    if (result.selected_child) |child| try writer.print("  Selected child: {s}\n", .{child});
}

fn writePushResult(writer: *Io.Writer, result: spore_api.PushResult) !void {
    try writer.writeAll("Bundle pushed\n");
    try writer.print("  Source: {s}\n", .{result.source});
    try writer.print("  Destination: {s}\n", .{result.destination});
    try writer.print("  Store: {s}\n", .{result.store});
    try writer.print("  Bundle digest: sha256:{s}\n", .{result.bundle_digest});
    try writer.print("  Uploaded: {d} files, {d} bytes\n", .{ result.uploaded_file_count, result.uploaded_bytes });
}

fn writeInspectBundleResult(writer: *Io.Writer, result: spore_api.InspectBundleResult) !void {
    try writer.writeAll("Bundle\n");
    try writer.print("  Source: {s}\n", .{result.source});
    try writer.print("  Bundle: {s}\n", .{result.bundle_dir});
    try writer.print("  Bundle digest: {s}:{s}\n", .{ result.bundle_digest.algorithm, result.bundle_digest.hex });
    try writer.print("  Indexed: {}\n", .{result.indexed});
    try writer.print("  Chunks: {d} chunks across {d} packs, {d} bytes\n", .{ result.chunkpack.chunk_count, result.chunkpack.pack_count, result.chunkpack.payload_bytes });
    try writer.print("  Children: {d}\n", .{result.child_count});
    if (result.selection.selected_count > 0) {
        try writer.print("  Selection: {s}, {d} children\n", .{ result.selection.kind, result.selection.selected_count });
        try writer.writeAll("  Selected children:");
        for (result.selection.children) |child| try writer.print(" {s}", .{child.id});
        try writer.writeByte('\n');
    }
    if (result.rootfs.artifact_count > 0) {
        try writer.print("  Rootfs artifacts: {d}, {d} exact-byte artifacts, {d} metadata-only artifacts\n", .{ result.rootfs.artifact_count, result.rootfs.exact_bytes_count, result.rootfs.metadata_only_count });
    }
}

fn writePullResult(writer: *Io.Writer, result: spore_api.PullResult) !void {
    try writer.writeAll("Bundle pulled\n");
    try writer.print("  Source: {s}\n", .{result.source});
    try writer.print("  Output: {s}\n", .{result.out_dir});
    try writer.print("  Bundle digest: {s}:{s}\n", .{ result.bundle_digest.algorithm, result.bundle_digest.hex });
    try writer.print("  Chunks: {d} materialized of {d}\n", .{ result.materialization.materialized_chunk_count, result.materialization.chunk_count });
    try writer.print("  Payload bytes: {d}\n", .{result.materialization.payload_bytes});
    try writer.print("  Chunk cache: {d} hits, {d} misses, {d} fetched bytes, {d} reused bytes\n", .{ result.materialization.cache.hit_count, result.materialization.cache.miss_count, result.materialization.cache.bytes_fetched, result.materialization.cache.bytes_reused });
    try writer.print("  Rootfs cache: {d} hits, {d} misses, {d} fetched bytes, {d} reused bytes\n", .{ result.rootfs.cache.hit_count, result.rootfs.cache.miss_count, result.rootfs.cache.bytes_fetched, result.rootfs.cache.bytes_reused });
    if (result.children.selected_child) |child| try writer.print("  Selected child: {s}\n", .{child});
}

test "usage names every command" {
    try std.testing.expect(std.mem.indexOf(u8, usage, "--debug") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "build") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "rootfs") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "run") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "attach") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "create") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "rm") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "save") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "restore") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "ls") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "version") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "host-info") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "inspect") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "inspect-bundle") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "fork") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "fanout") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "pack") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "unpack") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "push") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "pull") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "help") != null);
}

test "parse inspect bundle child range" {
    const range = parseChildRange("7..42") orelse return error.BadManifest;
    try std.testing.expectEqual(@as(u32, 7), range.start);
    try std.testing.expectEqual(@as(u32, 42), range.end);
    try std.testing.expect(std.mem.indexOf(u8, inspect_bundle_usage, "inclusive range") != null);
    try std.testing.expect(parseChildRange("42..7") == null);
    try std.testing.expect(parseChildRange("7.") == null);
    try std.testing.expect(parseChildRange("7..") == null);
    try std.testing.expect(parseChildRange("..42") == null);
}

test "inspect bundle output lists selected child ids" {
    const allocator = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const selected = [_]spore_api.BundleChildSummary{
        .{ .id = "000001", .manifest = "manifests/children/000001.json" },
    };
    try writeInspectBundleResult(&out.writer, .{
        .source = "bundle",
        .bundle_dir = "/tmp/bundle",
        .bundle_digest = .{ .hex = "abc" },
        .indexed = true,
        .parent_manifest = "manifests/parent.json",
        .chunkpack_index = "chunkpack.index.json",
        .chunkpack = .{ .chunk_count = 1, .pack_count = 1, .payload_bytes = 4096 },
        .child_count = 2,
        .selection = .{ .kind = "child_range", .selected_count = selected.len, .children = &selected },
    });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Selected children: 000001") != null);
}

test "rootfs bundle policy parser accepts exact and metadata-only spellings" {
    try std.testing.expectEqual(spore_api.RootfsBundlePolicy.exact_bytes, parseRootfsBundlePolicy("exact").?);
    try std.testing.expectEqual(spore_api.RootfsBundlePolicy.exact_bytes, parseRootfsBundlePolicy("exact-bytes").?);
    try std.testing.expectEqual(spore_api.RootfsBundlePolicy.metadata_only, parseRootfsBundlePolicy("metadata-only").?);
    try std.testing.expect(parseRootfsBundlePolicy("bad") == null);
}

test "removed commands map to rename hints" {
    try std.testing.expect(std.mem.indexOf(u8, renamedCommandHint("resume").?, "spore attach") != null);
    try std.testing.expect(std.mem.indexOf(u8, renamedCommandHint("resume").?, "spore restore") != null);
    try std.testing.expect(std.mem.indexOf(u8, renamedCommandHint("suspend").?, "spore save NAME --out DIR --stop") != null);
    try std.testing.expect(renamedCommandHint("attach") == null);
    try std.testing.expect(renamedCommandHint("bogus") == null);
}

test "command help accepts standard help spellings" {
    try std.testing.expect(wantsCommandHelp(&.{"--help"}));
    try std.testing.expect(wantsCommandHelp(&.{"-h"}));
    try std.testing.expect(wantsCommandHelp(&.{"help"}));
    try std.testing.expect(wantsCommandHelp(&.{ "base.spore", "--help" }));
    try std.testing.expect(!wantsCommandHelp(&.{}));
    try std.testing.expect(!wantsCommandHelp(&.{ "help", "--out", "bundle" }));
    try std.testing.expect(!wantsCommandHelp(&.{ "--", "--help" }));
}

test "stable lifecycle commands support global json where output is one document" {
    try std.testing.expect(supportsJson("create"));
    try std.testing.expect(supportsJson("fork"));
    try std.testing.expect(supportsJson("ls"));
    try std.testing.expect(supportsJson("ps"));
    try std.testing.expect(supportsJson("rm"));
    try std.testing.expect(supportsJson("restore"));
    try std.testing.expect(supportsJson("save"));
    try std.testing.expect(!supportsJson("attach"));
    try std.testing.expect(!supportsJson("exec"));
}

test "global args parse debug before command" {
    const parsed = parseGlobalArgs(&.{ "spore", "--debug", "--json", "run", "--", "/bin/true" });
    try std.testing.expect(parsed.debug);
    try std.testing.expectEqual(machine_output.Mode.json, parsed.mode);
    try std.testing.expect(!parsed.help);
    try std.testing.expectEqualStrings("run", parsed.command.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.command_args.len);
    try std.testing.expectEqualStrings("--", parsed.command_args[0]);
    try std.testing.expectEqualStrings("/bin/true", parsed.command_args[1]);
}

test "global args parse help without command" {
    const parsed = parseGlobalArgs(&.{ "spore", "--help" });
    try std.testing.expect(parsed.help);
    try std.testing.expect(parsed.command == null);
}
