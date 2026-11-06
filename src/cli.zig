//! The `spore` command table: every command, the global flags, finding the
//! command argv names, help, and global `--json`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const attach_cli = @import("attach_cli.zig");
const attach_mod = @import("attach.zig");
const build_cli = @import("build_cli.zig");
const checkpoint_cli = @import("checkpoint_cli.zig");
const events_mod = @import("events.zig");
const fanout = @import("fanout.zig");
const image_cli = @import("image_cli.zig");
const lifecycle_cli = @import("lifecycle_cli.zig");
const machine_output = @import("machine_output.zig");
const monitor = @import("monitor.zig");
const run_cli = @import("run_cli.zig");
const run_mod = @import("run.zig");
const spore_netd = @import("spore_netd.zig");
const system = @import("system.zig");
const version_value = @import("version.zig").value;

/// What a command prints under global `--json`.
pub const Output = enum {
    /// One result document on stdout, or `spore.error.v1` on stderr.
    result,
    /// `spore.automation.event.v1` lines on stdout ending in one `completion`,
    /// which also reports a failure.
    events,
    /// Nothing: `--json` is refused.
    text,
};

/// What every command handler gets besides its arguments.
pub const Ctx = struct {
    init: std.process.Init,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    /// Global `--debug`.
    debug: bool = false,

    /// How a streaming command prints: global `--json` selects the event stream.
    pub fn eventMode(ctx: *const Ctx) events_mod.EventMode {
        return if (ctx.mode == .json) .jsonl else .none;
    }
};

pub const Command = struct {
    /// A word, or a group word and a verb such as "vm rm".
    name: []const u8,
    /// The command's line in `spore --help`. Internal commands have none.
    summary: ?[]const u8,
    /// Printed by `spore <name> --help`.
    usage: []const u8,
    output: Output,
    run: *const fn (ctx: *const Ctx, args: []const []const u8) anyerror!void,
};

/// Every `spore` command. `spore --help` lists them in this order.
pub const commands = [_]Command{
    .{ .name = "run", .summary = "Boot a throwaway VM and run one command", .usage = run_mod.cli_usage, .output = .events, .run = run_cli.cli },
    .{ .name = "attach", .summary = "Restore a checkpoint and attach to its saved session", .usage = attach_mod.cli_usage, .output = .events, .run = attach_cli.cli },
    .{ .name = "fanout", .summary = "Attach forked children concurrently with prefixed output", .usage = fanout.cli_usage, .output = .events, .run = fanout.cli },
    .{ .name = "build", .summary = "Build a Spore image from a Dockerfile subset", .usage = build_cli.usage, .output = .result, .run = build_cli.run },
    .{ .name = "vm create", .summary = "Create a named VM", .usage = lifecycle_cli.create_usage, .output = .result, .run = lifecycle_cli.createCli },
    .{ .name = "vm exec", .summary = "Execute a command in a named VM", .usage = lifecycle_cli.exec_usage, .output = .events, .run = lifecycle_cli.execCli },
    .{ .name = "vm logs", .summary = "Show retained initial-command stdout and stderr", .usage = lifecycle_cli.logs_usage, .output = .result, .run = lifecycle_cli.logsCli },
    .{ .name = "vm copy-in", .summary = "Copy one host file or directory into a named VM", .usage = lifecycle_cli.copy_in_usage, .output = .result, .run = lifecycle_cli.copyInCli },
    .{ .name = "vm copy-out", .summary = "Copy one guest file or directory out of a named VM", .usage = lifecycle_cli.copy_out_usage, .output = .result, .run = lifecycle_cli.copyOutCli },
    .{ .name = "vm save", .summary = "Save a named VM as a checkpoint; --stop removes the VM", .usage = lifecycle_cli.save_usage, .output = .result, .run = lifecycle_cli.saveCli },
    .{ .name = "vm restore", .summary = "Restore a checkpoint as a named VM", .usage = lifecycle_cli.restore_usage, .output = .result, .run = lifecycle_cli.restoreCli },
    .{ .name = "vm fork", .summary = "Fork a named VM into named VM children", .usage = lifecycle_cli.fork_usage, .output = .result, .run = lifecycle_cli.forkCli },
    .{ .name = "vm rm", .summary = "Stop a named VM and delete its runtime state", .usage = lifecycle_cli.rm_usage, .output = .result, .run = lifecycle_cli.rmCli },
    .{ .name = "vm ls", .summary = "List named VMs", .usage = lifecycle_cli.ls_usage, .output = .result, .run = lifecycle_cli.lsCli },
    .{ .name = "checkpoint inspect", .summary = "Print a checkpoint manifest summary", .usage = checkpoint_cli.inspect_usage, .output = .result, .run = checkpoint_cli.inspect },
    .{ .name = "checkpoint fork", .summary = "Fork a checkpoint into child checkpoints", .usage = checkpoint_cli.fork_usage, .output = .result, .run = checkpoint_cli.fork },
    .{ .name = "checkpoint rm", .summary = "Remove a checkpoint directory", .usage = checkpoint_cli.rm_usage, .output = .result, .run = checkpoint_cli.rm },
    .{ .name = "checkpoint push", .summary = "Push a checkpoint to an image store", .usage = checkpoint_cli.push_usage, .output = .result, .run = checkpoint_cli.push },
    .{ .name = "checkpoint pull", .summary = "Pull a checkpoint from an image store", .usage = checkpoint_cli.pull_usage, .output = .result, .run = checkpoint_cli.pull },
    .{ .name = "image import-oci", .summary = "Import an OCI image layout as a local image", .usage = image_cli.import_oci_usage, .output = .result, .run = image_cli.importOci },
    .{ .name = "image import-tar", .summary = "Import a rootfs tar as a local image", .usage = image_cli.import_tar_usage, .output = .result, .run = image_cli.importTar },
    .{ .name = "image resolve", .summary = "Resolve an image tag to a digest reference", .usage = image_cli.resolve_usage, .output = .result, .run = image_cli.resolve },
    .{ .name = "image export", .summary = "Write an image's root filesystem as an ext4 file", .usage = image_cli.export_usage, .output = .result, .run = image_cli.exportRootfs },
    .{ .name = "image push", .summary = "Push a local image to an image store", .usage = image_cli.usage, .output = .result, .run = image_cli.push },
    .{ .name = "image pack", .summary = "Pack a local image into an immutable archive", .usage = image_cli.usage, .output = .result, .run = image_cli.pack },
    .{ .name = "image unpack", .summary = "Unpack an image archive as a local image", .usage = image_cli.usage, .output = .result, .run = image_cli.unpack },
    .{ .name = "system info", .summary = "Print this host's platform facts", .usage = system.info_usage, .output = .result, .run = system.infoCli },
    .{ .name = "system df", .summary = "Show local cache usage", .usage = system.usage, .output = .result, .run = system.dfCli },
    .{ .name = "system prune", .summary = "Prune local caches and old runtime fork batches", .usage = system.usage, .output = .result, .run = system.pruneCli },
    .{ .name = "system gc", .summary = "Collect unreferenced content-addressed cache storage", .usage = system.gc_usage, .output = .result, .run = system.gcCli },
    .{ .name = "system pins", .summary = "List saved-spore pins", .usage = system.gc_usage, .output = .result, .run = system.pinsCli },
    .{ .name = "system unpin", .summary = "Drop one saved-spore pin (expert-only)", .usage = system.gc_usage, .output = .result, .run = system.unpinCli },
    .{ .name = "version", .summary = "Print the spore version", .usage = "usage: spore version\n", .output = .result, .run = version },
    .{ .name = "monitor", .summary = null, .usage = monitor.monitor_usage, .output = .text, .run = monitor.cli },
    .{ .name = "netd", .summary = null, .usage = spore_netd.netd_usage, .output = .text, .run = spore_netd.cli },
};

fn version(ctx: *const Ctx, _: []const []const u8) !void {
    if (ctx.mode == .json) {
        try machine_output.writeJson(ctx.init.arena.allocator(), ctx.stdout, .{
            .schema = "spore.version.result.v1",
            .schema_version = @as(u32, 1),
            .version = version_value,
            .build_mode = @tagName(builtin.mode),
        });
    } else {
        try writeVersion(ctx.stdout, builtin.mode);
    }
}

/// `spore --version` and `spore version`.
pub fn writeVersion(writer: *Io.Writer, mode: std.builtin.OptimizeMode) !void {
    try writer.print("spore {s} ({t})\n", .{ version_value, mode });
}

/// The flags before the command word.
pub const GlobalArgs = struct {
    debug: bool = false,
    mode: machine_output.Mode = .human,
    help: bool = false,
    /// The command word and its arguments; empty when there is no command.
    argv: []const []const u8 = &.{},
    /// The first argument that is neither a global flag nor a command word.
    parse_error: ?[]const u8 = null,
};

/// Parses `args`, the program name first, up to the command word.
pub fn parseGlobalArgs(args: []const []const u8) GlobalArgs {
    var parsed = GlobalArgs{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--debug")) {
            parsed.debug = true;
        } else if (std.mem.eql(u8, args[i], "--json")) {
            parsed.mode = .json;
        } else if (isHelpFlag(args[i])) {
            parsed.help = true;
            return parsed;
        } else if (std.mem.startsWith(u8, args[i], "-")) {
            parsed.parse_error = args[i];
            return parsed;
        } else {
            parsed.argv = args[i..];
            return parsed;
        }
    }
    return parsed;
}

const Resolved = union(enum) {
    command: struct { command: *const Command, args: []const []const u8 },
    /// A group word alone or followed by `-h` or `--help`.
    group_help: []const u8,
    unknown_verb: struct { group: []const u8, verb: []const u8 },
    unknown,
};

/// Finds the command `argv` names; `argv[0]` is the command word.
fn resolve(table: []const Command, argv: []const []const u8) Resolved {
    std.debug.assert(argv.len != 0);
    const word = argv[0];
    if (!isGroup(table, word)) {
        for (table) |*command| {
            if (std.mem.eql(u8, command.name, word)) return .{ .command = .{ .command = command, .args = argv[1..] } };
        }
        return .unknown;
    }
    if (argv.len == 1 or isHelpFlag(argv[1])) return .{ .group_help = word };
    for (table) |*command| {
        const verb = verbOf(command.name, word) orelse continue;
        if (std.mem.eql(u8, verb, argv[1])) return .{ .command = .{ .command = command, .args = argv[2..] } };
    }
    return .{ .unknown_verb = .{ .group = word, .verb = argv[1] } };
}

/// Runs the command `argv` names, or prints help or a usage error for it.
pub fn run(table: []const Command, ctx: *const Ctx, argv: []const []const u8) !void {
    const allocator = ctx.init.arena.allocator();
    switch (resolve(table, argv)) {
        .command => |found| return invoke(found.command, ctx, found.args),
        .group_help => |group| {
            if (ctx.mode == .json and argv.len > 1) {
                const message = allocMessage(allocator, "spore --json {s} does not print help", .{group});
                exitWithCliError(allocator, ctx.stderr, ctx.mode, machine_output.usageInvalidArgument(message, group), message);
            }
            if (ctx.mode == .json) {
                const message = allocMessage(allocator, "usage: spore {s} <command>", .{group});
                exitUsage(allocator, ctx.stderr, ctx.mode, group, message);
            }
            return writeHelp(table, group, ctx.stdout);
        },
        .unknown_verb => |unknown| {
            const message = allocMessage(allocator, "unknown {s} command: {s}", .{ unknown.group, unknown.verb });
            exitWithCliError(allocator, ctx.stderr, ctx.mode, machine_output.usageInvalidArgument(message, unknown.group), withHelp(allocator, table, unknown.group, message));
        },
        .unknown => {
            const message = allocMessage(allocator, "unknown command: {s}", .{argv[0]});
            exitWithCliError(allocator, ctx.stderr, ctx.mode, machine_output.usageInvalidArgument(message, "CommandDispatch"), withHelp(allocator, table, null, message));
        },
    }
}

fn invoke(command: *const Command, ctx: *const Ctx, args: []const []const u8) !void {
    const allocator = ctx.init.arena.allocator();
    if (ctx.mode == .json and command.output == .text) {
        const message = allocMessage(allocator, "spore --json does not support command: {s}", .{command.name});
        exitWithCliError(allocator, ctx.stderr, ctx.mode, machine_output.usageInvalidArgument(message, "GlobalJson"), message);
    }
    if (wantsHelp(args)) {
        if (ctx.mode == .json) {
            const message = allocMessage(allocator, "spore --json {s} does not print help", .{command.name});
            const source = if (command.output == .events) streamCommand(command.name) else command.name;
            exitCommandError(command, ctx, machine_output.usageInvalidArgument(message, source));
        }
        return ctx.stdout.writeAll(command.usage);
    }
    command.run(ctx, args) catch |err| {
        if (ctx.mode == .json and command.output == .events) exitCommandError(command, ctx, events_mod.classifyFailure(err));
        return err;
    };
}

/// Reports `err` under `--json` where `command`'s consumer reads it: a failed
/// `completion` on stdout for a stream, else `spore.error.v1` on stderr.
fn exitCommandError(command: *const Command, ctx: *const Ctx, err: machine_output.CliError) noreturn {
    if (command.output == .events) {
        var events = events_mod.EventWriter.init(ctx.init.arena.allocator(), ctx.stdout, streamCommand(command.name));
        events.emitFailure(err) catch {};
        std.process.exit(err.exit_code);
    }
    exitWithCliError(ctx.init.arena.allocator(), ctx.stderr, ctx.mode, err, err.message);
}

/// The `command` a stream reports: the verb alone, so `vm exec` says "exec".
fn streamCommand(name: []const u8) []const u8 {
    const space = std.mem.lastIndexOfScalar(u8, name, ' ') orelse return name;
    return name[space + 1 ..];
}

/// Whether `args` asks for a command's help: `-h` or `--help` anywhere
/// before `--`.
fn wantsHelp(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) return false;
        if (isHelpFlag(arg)) return true;
    }
    return false;
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

/// The verb of a "group verb" command name in `group`.
fn verbOf(name: []const u8, group: []const u8) ?[]const u8 {
    if (name.len <= group.len + 1 or !std.mem.startsWith(u8, name, group) or name[group.len] != ' ') return null;
    return name[group.len + 1 ..];
}

fn isGroup(table: []const Command, word: []const u8) bool {
    for (table) |command| {
        if (verbOf(command.name, word) != null) return true;
    }
    return false;
}

const help_header =
    \\Usage: spore [--debug] [--json] <command> [args...]
    \\       spore <command> --help
    \\       spore --version
    \\
    \\Global options:
    \\  --debug   Show verbose VMM and restore logs
    \\  --json    Print one JSON result document, or for run, attach, fanout and
    \\            vm exec a stream of JSON events
    \\
    \\Commands:
    \\
;

/// Writes `spore --help`, or with `group` the commands of that group.
pub fn writeHelp(table: []const Command, group: ?[]const u8, writer: *Io.Writer) !void {
    if (group) |word| {
        try writer.print("Usage: spore {s} <command> [args...]\n       spore {s} <command> --help\n\nCommands:\n", .{ word, word });
    } else {
        try writer.writeAll(help_header);
    }
    var width: usize = 0;
    for (table) |command| {
        if (helpName(command, group)) |name| width = @max(width, name.len);
    }
    for (table) |command| {
        const name = helpName(command, group) orelse continue;
        try writer.print("  {s}", .{name});
        try writer.splatByteAll(' ', width - name.len + 2);
        try writer.print("{s}\n", .{command.summary.?});
    }
}

/// The name `command` is listed under in the help for `group`, if listed.
fn helpName(command: Command, group: ?[]const u8) ?[]const u8 {
    if (command.summary == null) return null;
    const word = group orelse return command.name;
    return verbOf(command.name, word);
}

/// `message`, a blank line and the help for `group`.
pub fn withHelp(allocator: std.mem.Allocator, table: []const Command, group: ?[]const u8, message: []const u8) []const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    out.writer.print("{s}\n\n", .{message}) catch return message;
    writeHelp(table, group, &out.writer) catch return message;
    return out.written();
}

pub fn allocMessage(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(allocator, fmt, args) catch "CLI argument error";
}

/// Prints `err` as `spore.error.v1` under `--json`, else `human_text`, and
/// exits with its status.
pub fn exitWithCliError(
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

pub fn exitUnknownArgument(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    arg: []const u8,
) noreturn {
    const message = allocMessage(allocator, "unknown {s} argument: {s}", .{ command, arg });
    exitWithCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
}

pub fn exitUnexpectedArgument(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    arg: []const u8,
) noreturn {
    const message = allocMessage(allocator, "unexpected {s} argument: {s}", .{ command, arg });
    exitWithCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
}

pub fn exitInvalidValue(
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

pub fn exitUsage(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    usage_line: []const u8,
) noreturn {
    exitWithCliError(allocator, stderr, mode, machine_output.usageMissingArgument(usage_line, command), usage_line);
}

fn testRun(_: *const Ctx, _: []const []const u8) anyerror!void {}

const test_commands = [_]Command{
    .{ .name = "run", .summary = "Run a VM", .usage = "", .output = .events, .run = testRun },
    .{ .name = "ls", .summary = "List VMs", .usage = "", .output = .result, .run = testRun },
    .{ .name = "vm rm", .summary = "Remove a VM", .usage = "", .output = .result, .run = testRun },
    .{ .name = "vm fork", .summary = "Fork a VM", .usage = "", .output = .result, .run = testRun },
    .{ .name = "monitor", .summary = null, .usage = "", .output = .text, .run = testRun },
};

test "resolve finds commands, group verbs and their arguments" {
    const run_found = resolve(&test_commands, &.{ "run", "--", "/bin/true" }).command;
    try std.testing.expectEqualStrings("run", run_found.command.name);
    try std.testing.expectEqual(@as(usize, 2), run_found.args.len);

    const verb = resolve(&test_commands, &.{ "vm", "rm", "box" }).command;
    try std.testing.expectEqualStrings("vm rm", verb.command.name);
    try std.testing.expectEqualStrings("box", verb.args[0]);

    // A command's argument is never read as a verb.
    try std.testing.expectEqualStrings("ls", resolve(&test_commands, &.{ "ls", "rm" }).command.command.name);
    try std.testing.expectEqualStrings("monitor", resolve(&test_commands, &.{ "monitor", "box" }).command.command.name);
}

test "resolve reports group help, unknown verbs and unknown commands" {
    try std.testing.expectEqualStrings("vm", resolve(&test_commands, &.{"vm"}).group_help);
    try std.testing.expectEqualStrings("vm", resolve(&test_commands, &.{ "vm", "--help" }).group_help);
    try std.testing.expectEqualStrings("help", resolve(&test_commands, &.{ "vm", "help" }).unknown_verb.verb);
    const unknown_verb = resolve(&test_commands, &.{ "vm", "ls" }).unknown_verb;
    try std.testing.expectEqualStrings("vm", unknown_verb.group);
    try std.testing.expectEqualStrings("ls", unknown_verb.verb);
    try std.testing.expect(resolve(&test_commands, &.{"vmm"}) == .unknown);
    try std.testing.expect(resolve(&test_commands, &.{"rm"}) == .unknown);
}

test "help lists public commands and a group's verbs" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeHelp(&test_commands, null, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "  vm fork  Fork a VM\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "  run      Run a VM\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "monitor") == null);

    out.clearRetainingCapacity();
    try writeHelp(&test_commands, "vm", &out.writer);
    try std.testing.expectEqualStrings(
        \\Usage: spore vm <command> [args...]
        \\       spore vm <command> --help
        \\
        \\Commands:
        \\  rm    Remove a VM
        \\  fork  Fork a VM
        \\
    , out.written());
}

test "command help accepts standard help spellings before the argv delimiter" {
    try std.testing.expect(wantsHelp(&.{"--help"}));
    try std.testing.expect(wantsHelp(&.{"-h"}));
    try std.testing.expect(!wantsHelp(&.{"help"}));
    try std.testing.expect(wantsHelp(&.{ "base.spore", "--help" }));
    try std.testing.expect(!wantsHelp(&.{}));
    try std.testing.expect(!wantsHelp(&.{ "help", "--out", "bundle" }));
    try std.testing.expect(!wantsHelp(&.{ "--", "--help" }));
    try std.testing.expect(!wantsHelp(&.{ "box", "--", "/bin/true", "-h" }));
}

test "version output distinguishes development and release builds" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeVersion(&out.writer, .Debug);
    try std.testing.expectEqualStrings("spore " ++ version_value ++ " (Debug)\n", out.written());

    out.clearRetainingCapacity();
    try writeVersion(&out.writer, .ReleaseSafe);
    try std.testing.expectEqualStrings("spore " ++ version_value ++ " (ReleaseSafe)\n", out.written());
}

test "command table names each command once and fits the dispatcher" {
    for (commands, 0..) |command, i| {
        for (commands[i + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, command.name, other.name));
        // A word is either a command or a group of verbs, never both.
        if (std.mem.indexOfScalar(u8, command.name, ' ')) |space| {
            for (commands) |other| try std.testing.expect(!std.mem.eql(u8, other.name, command.name[0..space]));
        }
        const spelled = try std.fmt.allocPrint(std.testing.allocator, "spore {s}", .{command.name});
        defer std.testing.allocator.free(spelled);
        try std.testing.expect(std.mem.indexOf(u8, command.usage, spelled) != null);
    }
}

test "only internal commands refuse global json, and only four commands stream" {
    for (commands) |command| {
        const streams = std.mem.eql(u8, command.name, "run") or std.mem.eql(u8, command.name, "attach") or
            std.mem.eql(u8, command.name, "vm exec") or std.mem.eql(u8, command.name, "fanout");
        const text = std.mem.eql(u8, command.name, "monitor") or std.mem.eql(u8, command.name, "netd");
        const expected: Output = if (streams) .events else if (text) .text else .result;
        try std.testing.expectEqual(expected, command.output);
    }
}

test "help lists every public command" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeHelp(&commands, null, &out.writer);
    for (commands) |command| {
        const listed = try std.fmt.allocPrint(std.testing.allocator, "\n  {s}  ", .{command.name});
        defer std.testing.allocator.free(listed);
        try std.testing.expectEqual(command.summary != null, std.mem.indexOf(u8, out.written(), listed) != null);
    }
}

test "global args parse debug before command" {
    const parsed = parseGlobalArgs(&.{ "spore", "--debug", "--json", "run", "--", "/bin/true" });
    try std.testing.expect(parsed.debug);
    try std.testing.expectEqual(machine_output.Mode.json, parsed.mode);
    try std.testing.expect(!parsed.help);
    try std.testing.expectEqual(@as(usize, 3), parsed.argv.len);
    try std.testing.expectEqualStrings("run", parsed.argv[0]);
    try std.testing.expectEqualStrings("--", parsed.argv[1]);
    try std.testing.expectEqualStrings("/bin/true", parsed.argv[2]);
}

test "global args parse help without command" {
    const parsed = parseGlobalArgs(&.{ "spore", "--help" });
    try std.testing.expect(parsed.help);
    try std.testing.expectEqual(@as(usize, 0), parsed.argv.len);
}
