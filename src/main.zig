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
    \\       spore --version
    \\
    \\Global options:
    \\  --debug             Show verbose VMM and restore logs
    \\  --json              Emit one JSON result for supported commands
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
    \\    vm rm NAME          Remove a live VM and its runtime state
    \\    vm fork NAME --count N --name PATTERN
    \\                        Fork a live VM into live VM children
    \\    create NAME [options] ['shell command']
    \\                        Create a named VM lifecycle target
    \\    exec NAME 'shell command'
    \\                        Execute a command in a named VM
    \\    logs NAME           Show retained initial-command stdout and stderr
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
    \\  Checkpoints:
    \\    checkpoint rm DIR   Remove a checkpoint directory
    \\    checkpoint fork DIR --count N --out DIR
    \\                        Fork a checkpoint into checkpoint children
    \\    inspect <spore-dir> Print a spore manifest summary
    \\    fork <spore-dir> --count N --out DIR
    \\                        Mint child spores that share parent chunks
    \\    fanout <children-dir> [--for DURATION]
    \\                        Attach forked children concurrently with prefixed output
    \\    push <spore-dir> STORE/TAG
    \\                        Push a saved spore to an image store
    \\    pull STORE/TAG --out DIR
    \\                        Pull a saved spore from an image store
    \\
    \\  Rootfs and local system:
    \\    build [options] CONTEXT
    \\                        Build a Spore image from a Dockerfile subset
    \\    rootfs              Build rootfs images from OCI images
    \\    image pack/unpack  Distribute an immutable native image archive
    \\    cache               Inspect and collect local content-addressed caches
    \\    system              Inspect and prune local SporeVM system state
    \\    host-info           Print this host's platform facts
    \\    help                Show this help
    \\
;

const push_usage =
    \\Usage:
    \\  spore push <spore-dir> STORE/TAG
    \\
    \\STORE is a directory, a file:// URL or s3://bucket/prefix (uploaded with
    \\the aws CLI); TAG may be blake3:<digest>. The spore's RAM chunks and disk
    \\objects share the store's objects with images.
    \\
    \\Options:
    \\  -h, --help           Show this help
    \\
;

const pull_usage =
    \\Usage:
    \\  spore pull STORE/TAG --out DIR
    \\
    \\STORE is a directory, a file://, http(s):// or s3://bucket/prefix URL; TAG
    \\may be blake3:<digest>. DIR must not exist and must be on the rootfs cache's
    \\filesystem. Run the pulled spore with `spore run --from DIR`.
    \\
    \\Options:
    \\  --out DIR            Write the pulled spore to DIR
    \\  -h, --help           Show this help
    \\
;

const vm_usage =
    \\Usage:
    \\  spore vm rm NAME
    \\  spore vm fork NAME --count N --name PATTERN [--allow-slow-copy]
    \\
    \\A live VM owns a running monitor and host-local runtime state. Removing it
    \\does not remove checkpoints or images.
    \\
;

const checkpoint_usage =
    \\Usage:
    \\  spore checkpoint rm DIR
    \\  spore checkpoint fork DIR --count N --out DIR
    \\
    \\A checkpoint (also called a spore) is saved machine state. Removing it
    \\deletes the checkpoint directory; `spore cache gc --force` then reclaims
    \\storage nothing else references.
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

    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        try writeVersion(stdout, builtin.mode);
        try stdout.flush();
        return;
    }

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
        // Any command can meet an old local format; tell a person to
        // re-create it instead of printing an error trace.
        if (parsed.mode == .json or err == error.FormatTooOld) {
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
        const message = if (std.mem.eql(u8, command, "run") or std.mem.eql(u8, command, "attach") or std.mem.eql(u8, command, "exec") or std.mem.eql(u8, command, "fanout"))
            allocMessage(arena, "spore --json {s} is not supported; use --events=jsonl for stream events", .{command})
        else
            allocMessage(arena, "spore --json does not support command: {s}", .{command});
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
        try spore_internal.rootfs_cli.run(init, command_args, stdout, mode);
    } else if (std.mem.eql(u8, command, "image")) {
        try spore_internal.image_cli.run(init, command_args, stdout, mode);
    } else if (std.mem.eql(u8, command, "vm")) {
        try vmCommand(init, command_args, stdout, stderr, mode);
    } else if (std.mem.eql(u8, command, "checkpoint")) {
        try checkpointCommand(init, context, command_args, stdout, stderr, mode);
    } else if (std.mem.eql(u8, command, "build")) {
        try spore_internal.build_cli.run(init, command_args, stdout, stderr, mode);
    } else if (std.mem.eql(u8, command, "run")) {
        try spore_internal.run_cli.cli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "attach")) {
        try spore_internal.attach_cli.cli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "create")) {
        try spore_internal.lifecycle_cli.createCli(init, command_args, stdout, stderr, mode);
    } else if (std.mem.eql(u8, command, "logs")) {
        try spore_internal.lifecycle_cli.logsCli(init, command_args, stdout, stderr, mode);
    } else if (std.mem.eql(u8, command, "exec")) {
        try spore_internal.lifecycle_cli.execCli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "copy-in")) {
        try spore_internal.lifecycle_cli.copyInCli(init, command_args, stdout, stderr, mode);
    } else if (std.mem.eql(u8, command, "copy-out")) {
        try spore_internal.lifecycle_cli.copyOutCli(init, command_args, stdout, stderr, mode);
    } else if (std.mem.eql(u8, command, "rm")) {
        try spore_internal.lifecycle_cli.rmCli(init, command_args, stdout, stderr, mode);
    } else if (std.mem.eql(u8, command, "save")) {
        try spore_internal.lifecycle_cli.saveCli(init, command_args, stdout, stderr, mode);
    } else if (std.mem.eql(u8, command, "restore")) {
        try spore_internal.lifecycle_cli.restoreCli(init, command_args, stdout, stderr, mode);
    } else if (std.mem.eql(u8, command, "ls") or std.mem.eql(u8, command, "ps")) {
        try spore_internal.lifecycle_cli.lsCli(init, command_args, stdout, stderr, mode);
    } else if (std.mem.eql(u8, command, "monitor")) {
        try spore_internal.monitor.cli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "netd")) {
        try spore_internal.spore_netd.cli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "version")) {
        if (wantsCommandHelp(command_args)) {
            try stdout.writeAll("usage: spore version\n");
            return;
        }
        if (mode == .json) {
            try machine_output.writeJson(arena, stdout, .{
                .schema = "spore.version.result.v1",
                .schema_version = @as(u32, 1),
                .version = spore_internal.version,
                .build_mode = @tagName(builtin.mode),
            });
        } else {
            try writeVersion(stdout, builtin.mode);
        }
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
        if (spore_internal.lifecycle_cli.wantsNamedFork(command_args)) {
            try spore_internal.lifecycle_cli.forkCli(init, command_args, stdout, stderr, mode);
        } else {
            const result = try forkCommand(context, arena, stderr, mode, "fork", command_args);
            if (mode == .json) {
                try machine_output.writeJson(arena, stdout, result);
            } else {
                try writeForkResult(stdout, result);
            }
        }
    } else if (std.mem.eql(u8, command, "fanout")) {
        try spore_internal.fanout.cli(init, command_args, stdout);
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
        std.mem.eql(u8, command, "rootfs") or
        std.mem.eql(u8, command, "image") or
        std.mem.eql(u8, command, "vm") or
        std.mem.eql(u8, command, "checkpoint") or
        std.mem.eql(u8, command, "build") or
        std.mem.eql(u8, command, "version") or
        std.mem.eql(u8, command, "copy-in") or
        std.mem.eql(u8, command, "copy-out") or
        std.mem.eql(u8, command, "create") or
        std.mem.eql(u8, command, "logs") or
        std.mem.eql(u8, command, "rm") or
        std.mem.eql(u8, command, "restore") or
        std.mem.eql(u8, command, "save") or
        std.mem.eql(u8, command, "host-info") or
        std.mem.eql(u8, command, "inspect") or
        std.mem.eql(u8, command, "ls") or
        std.mem.eql(u8, command, "ps") or
        std.mem.eql(u8, command, "fork") or
        std.mem.eql(u8, command, "push") or
        std.mem.eql(u8, command, "pull");
}

fn vmCommand(
    init: std.process.Init,
    args: []const []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) !void {
    if (wantsCommandHelp(args)) {
        try stdout.writeAll(vm_usage);
        return;
    }
    if (args.len == 0) exitUsage(init.arena.allocator(), stderr, mode, "vm", "usage: spore vm rm NAME | spore vm fork NAME --count N --name PATTERN");
    if (std.mem.eql(u8, args[0], "rm")) {
        if (args.len != 2) exitUsage(init.arena.allocator(), stderr, mode, "vm rm", "usage: spore vm rm NAME");
        return spore_internal.lifecycle_cli.rmCli(init, args[1..], stdout, stderr, mode);
    }
    if (std.mem.eql(u8, args[0], "fork")) {
        if (args.len < 2 or std.mem.startsWith(u8, args[1], "--")) exitUsage(init.arena.allocator(), stderr, mode, "vm fork", "usage: spore vm fork NAME --count N --name PATTERN");
        const legacy_args = try init.arena.allocator().alloc([]const u8, args.len);
        legacy_args[0] = "--vm";
        @memcpy(legacy_args[1..], args[1..]);
        return spore_internal.lifecycle_cli.forkCli(init, legacy_args, stdout, stderr, mode);
    }
    exitUnknownArgument(init.arena.allocator(), stderr, mode, "vm", args[0]);
}

fn checkpointCommand(
    init: std.process.Init,
    context: spore_api.Context,
    args: []const []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) !void {
    if (wantsCommandHelp(args)) {
        try stdout.writeAll(checkpoint_usage);
        return;
    }
    if (args.len == 0) exitUsage(init.arena.allocator(), stderr, mode, "checkpoint", "usage: spore checkpoint rm DIR | spore checkpoint fork DIR --count N --out DIR");
    if (std.mem.eql(u8, args[0], "rm")) {
        if (args.len != 2) exitUsage(init.arena.allocator(), stderr, mode, "checkpoint rm", "usage: spore checkpoint rm DIR");
        return spore_internal.lifecycle_cli.rmCli(init, &.{ "--spore", args[1] }, stdout, stderr, mode);
    }
    if (std.mem.eql(u8, args[0], "fork")) {
        if (args.len < 2) exitUsage(init.arena.allocator(), stderr, mode, "checkpoint fork", "usage: spore checkpoint fork DIR --count N --out DIR");
        const result = try forkCommand(context, init.arena.allocator(), stderr, mode, "checkpoint fork", args[1..]);
        if (mode == .json) {
            try machine_output.writeJson(init.arena.allocator(), stdout, result);
        } else {
            try writeForkResult(stdout, result);
        }
        return;
    }
    exitUnknownArgument(init.arena.allocator(), stderr, mode, "checkpoint", args[0]);
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

fn writeVersion(writer: *Io.Writer, mode: std.builtin.OptimizeMode) !void {
    try writer.print("spore {s} ({t})\n", .{ spore_internal.version, mode });
}

fn forkCommand(
    context: spore_api.Context,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command_label: []const u8,
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
                exitInvalidValue(allocator, stderr, mode, command_label, "--count", args[i]);
            };
        } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            exitUnknownArgument(allocator, stderr, mode, command_label, args[i]);
        } else if (parent_dir == null) {
            parent_dir = args[i];
        } else {
            exitUnexpectedArgument(allocator, stderr, mode, command_label, args[i]);
        }
    }

    if (parent_dir == null or out_dir == null or count == null) {
        const usage_line = if (std.mem.eql(u8, command_label, "checkpoint fork"))
            "usage: spore checkpoint fork DIR --count N --out DIR"
        else
            "usage: spore fork <spore-dir> --count N --out DIR";
        exitUsage(allocator, stderr, mode, command_label, usage_line);
    }

    return spore_api.fork(context, allocator, .{
        .parent_dir = parent_dir.?,
        .out_dir = out_dir.?,
        .count = count.?,
    }) catch |err| switch (err) {
        error.CrossDeviceOwnershipLink => {
            const message = allocMessage(allocator, "spore {s}: {s} must be on the rootfs cache's filesystem", .{ command_label, out_dir.? });
            exitWithCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command_label), message);
        },
        else => |e| return e,
    };
}

fn pushCommand(
    context: spore_api.Context,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    args: []const []const u8,
) !spore_api.PushResult {
    var spore_dir: ?[]const u8 = null;
    var destination: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--")) {
            exitUnknownArgument(allocator, stderr, mode, "push", arg);
        } else if (spore_dir == null) {
            spore_dir = arg;
        } else if (destination == null) {
            destination = arg;
        } else {
            exitUnexpectedArgument(allocator, stderr, mode, "push", arg);
        }
    }
    if (spore_dir == null or destination == null) {
        exitUsage(allocator, stderr, mode, "push", "usage: spore push <spore-dir> STORE/TAG");
    }
    return spore_api.push(context, allocator, .{ .spore_dir = spore_dir.?, .destination = destination.? });
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
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            exitUnknownArgument(allocator, stderr, mode, "pull", args[i]);
        } else if (source == null) {
            source = args[i];
        } else {
            exitUnexpectedArgument(allocator, stderr, mode, "pull", args[i]);
        }
    }
    if (source == null or out_dir == null) {
        exitUsage(allocator, stderr, mode, "pull", "usage: spore pull STORE/TAG --out DIR");
    }
    return spore_api.pull(context, allocator, .{ .source = source.?, .out_dir = out_dir.? }) catch |err| switch (err) {
        error.CrossDeviceOwnershipLink => {
            const message = allocMessage(allocator, "spore pull: {s} must be on the rootfs cache's filesystem", .{out_dir.?});
            exitWithCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "pull"), message);
        },
        else => |e| return e,
    };
}

fn writeHostInfo(writer: *Io.Writer, info: spore_api.HostInfo) !void {
    try writer.writeAll("Host info\n");
    try writer.print("  Class: {s}\n", .{info.host_class});
    try writer.print("  Architecture: {s}\n", .{info.architecture});
    switch (info.platform) {
        .arm64 => |platform| {
            try writer.print("  Platform: {s}/arm64\n", .{platform.os});
            try writer.print("  CPU profile: {s}\n", .{platform.cpu_profile});
            try writer.print("  Device model version: {d}\n", .{platform.device_model_version});
            try writer.print("  Counter frequency: {d} Hz ({s})\n", .{ platform.counter.frequency_hz, platform.counter.source });
        },
        .amd64 => |platform| {
            try writer.print("  Platform: {s}/amd64\n", .{platform.os});
            try writer.print("  Board profile: {s}\n", .{platform.board_profile});
            try writer.print("  CPU profile: {s} ({s})\n", .{ platform.cpu_profile, platform.cpu_profile_status });
            try writer.print("  Device model version: {d}\n", .{platform.device_model_version});
            try writer.writeAll("  KVM capabilities:\n");
            for (platform.kvm_capabilities) |capability| {
                if (capability.value) |value| {
                    try writer.print("    {s}: value={d} minimum={d} satisfied={s}\n", .{
                        capability.name,
                        value,
                        capability.minimum,
                        yesNo(capability.satisfied),
                    });
                } else {
                    try writer.print("    {s}: unavailable satisfied=no\n", .{capability.name});
                }
            }
        },
    }
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
    try writePathFact(writer, "runtime", info.cache_roots.runtime);
}

fn writePathFact(writer: *Io.Writer, label: []const u8, fact: anytype) !void {
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
    try writer.writeAll("Checkpoint manifest\n");
    try writer.print("  Resource type: {t}\n", .{summary.resource_type});
    try writer.print("  Portability: {t}\n", .{summary.portability});
    try writer.print("  Can attach: {s}\n", .{yesNo(summary.can_attach)});
    try writer.print("  Can run from: {s}\n", .{yesNo(summary.can_run_from)});
    try writer.print("  Version: {d}\n", .{summary.version});
    try writer.print("  Platform: {s}/{s}\n", .{ summary.platform.arch, summary.platform.cpu_profile });
    try writer.print("  vCPUs: {d}\n", .{summary.vcpu_count});
    try writer.print("  Devices: {d}\n", .{summary.device_count});
    try writer.print("  Ownership: {s}\n", .{summary.ownership});
    try writer.print(
        "  Memory: initial={d}, maximum={d}, requested={d}, captured={d} bytes\n",
        .{
            summary.initial_memory_bytes,
            summary.max_memory_bytes,
            summary.requested_memory_bytes,
            summary.captured_memory_bytes,
        },
    );
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
    try writer.writeAll("Checkpoint fork complete\n");
    try writer.print("  Parent: {s}\n", .{result.parent});
    try writer.print("  Children: {d}\n", .{result.count});
    try writer.print("  Output: {s}\n", .{result.out_dir});
    try writer.print("  Generation range: {d}..{d}\n", .{ result.first_generation, result.last_generation });
    if (result.pin_publish_ms) |ms| try writer.print("  Pin publish: {d}ms\n", .{ms});
    if (result.pin_lock_wait_ms) |ms| try writer.print("  Pin lock wait: {d}ms\n", .{ms});
}

fn writePushResult(writer: *Io.Writer, result: spore_api.PushResult) !void {
    try writer.print(
        "ref: {s}\nspore_digest: {s}\nobjects: {d}\nobjects_written: {d}\nbytes_written: {d}\n",
        .{ result.ref, result.spore_digest, result.objects_total, result.objects_written, result.bytes_written },
    );
}

fn writePullResult(writer: *Io.Writer, result: spore_api.PullResult) !void {
    try writer.print(
        "ref: {s}\nspore_digest: {s}\nout_dir: {s}\nram: {d} objects, {d} fetched, {d} bytes\ndisk: {d} objects, {d} fetched, {d} bytes\n",
        .{
            result.ref,          result.spore_digest,         result.out_dir,
            result.ram.objects,  result.ram.objects_fetched,  result.ram.bytes_fetched,
            result.disk.objects, result.disk.objects_fetched, result.disk.bytes_fetched,
        },
    );
}

test "usage names every command" {
    try std.testing.expect(std.mem.indexOf(u8, usage, "--debug") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "--version") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "build") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "rootfs") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "run") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "attach") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "create") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "rm") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "vm rm") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "checkpoint rm") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "save") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "restore") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "ls") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "version") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "host-info") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "inspect") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "fork") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "fanout") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "push") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "pull") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "help") != null);
}

test "version output distinguishes development and release builds" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeVersion(&out.writer, .Debug);
    try std.testing.expectEqualStrings("spore " ++ spore_internal.version ++ " (Debug)\n", out.written());

    out.clearRetainingCapacity();
    try writeVersion(&out.writer, .ReleaseSafe);
    try std.testing.expectEqualStrings("spore " ++ spore_internal.version ++ " (ReleaseSafe)\n", out.written());
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
    try std.testing.expect(!wantsCommandHelp(&.{ "help", "--out", "base.spore" }));
    try std.testing.expect(!wantsCommandHelp(&.{ "--", "--help" }));
}

test "stable lifecycle commands support global json where output is one document" {
    try std.testing.expect(supportsJson("build"));
    try std.testing.expect(supportsJson("rootfs"));
    try std.testing.expect(supportsJson("image"));
    try std.testing.expect(supportsJson("vm"));
    try std.testing.expect(supportsJson("checkpoint"));
    try std.testing.expect(supportsJson("version"));
    try std.testing.expect(supportsJson("copy-in"));
    try std.testing.expect(supportsJson("copy-out"));
    try std.testing.expect(supportsJson("create"));
    try std.testing.expect(supportsJson("fork"));
    try std.testing.expect(supportsJson("logs"));
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
