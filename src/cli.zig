//! The `spore` command table. `main.zig` lists the commands; this module
//! finds the one argv names, prints help from the table, and applies global
//! `--json`.

const std = @import("std");
const Io = std.Io;
const events_mod = @import("events.zig");
const machine_output = @import("machine_output.zig");

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

const Resolved = union(enum) {
    command: struct { command: *const Command, args: []const []const u8 },
    /// A group word alone or followed by `-h` or `--help`.
    group_help: []const u8,
    unknown_verb: struct { group: []const u8, verb: []const u8 },
    unknown,
};

/// Finds the command `argv` names; `argv[0]` is the command word.
fn resolve(commands: []const Command, argv: []const []const u8) Resolved {
    std.debug.assert(argv.len != 0);
    const word = argv[0];
    if (!isGroup(commands, word)) {
        for (commands) |*command| {
            if (std.mem.eql(u8, command.name, word)) return .{ .command = .{ .command = command, .args = argv[1..] } };
        }
        return .unknown;
    }
    if (argv.len == 1 or isHelpFlag(argv[1])) return .{ .group_help = word };
    for (commands) |*command| {
        const verb = verbOf(command.name, word) orelse continue;
        if (std.mem.eql(u8, verb, argv[1])) return .{ .command = .{ .command = command, .args = argv[2..] } };
    }
    return .{ .unknown_verb = .{ .group = word, .verb = argv[1] } };
}

/// Runs the command `argv` names, or prints help or a usage error for it.
pub fn run(commands: []const Command, ctx: *const Ctx, argv: []const []const u8) !void {
    const allocator = ctx.init.arena.allocator();
    switch (resolve(commands, argv)) {
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
            return writeHelp(commands, group, ctx.stdout);
        },
        .unknown_verb => |unknown| {
            const message = allocMessage(allocator, "unknown {s} command: {s}", .{ unknown.group, unknown.verb });
            exitWithCliError(allocator, ctx.stderr, ctx.mode, machine_output.usageInvalidArgument(message, unknown.group), withHelp(allocator, commands, unknown.group, message));
        },
        .unknown => {
            const message = allocMessage(allocator, "unknown command: {s}", .{argv[0]});
            exitWithCliError(allocator, ctx.stderr, ctx.mode, machine_output.usageInvalidArgument(message, "CommandDispatch"), withHelp(allocator, commands, null, message));
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

fn isGroup(commands: []const Command, word: []const u8) bool {
    for (commands) |command| {
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
pub fn writeHelp(commands: []const Command, group: ?[]const u8, writer: *Io.Writer) !void {
    if (group) |word| {
        try writer.print("Usage: spore {s} <command> [args...]\n       spore {s} <command> --help\n\nCommands:\n", .{ word, word });
    } else {
        try writer.writeAll(help_header);
    }
    var width: usize = 0;
    for (commands) |command| {
        if (helpName(command, group)) |name| width = @max(width, name.len);
    }
    for (commands) |command| {
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
pub fn withHelp(allocator: std.mem.Allocator, commands: []const Command, group: ?[]const u8, message: []const u8) []const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    out.writer.print("{s}\n\n", .{message}) catch return message;
    writeHelp(commands, group, &out.writer) catch return message;
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
