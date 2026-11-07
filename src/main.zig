//! The `spore` CLI entry point. The commands are in `cli.zig`.
//!
//! `spore run` is the one-shot path. Named VM lifecycle commands are backed by
//! local monitor processes; see docs/lifecycle.md.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const spore_internal = @import("spore_internal");
const machine_output = spore_internal.machine_output;
const cli = spore_internal.cli;

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

var runtime_log_level: std.log.Level = .warn;

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
        try cli.writeVersion(stdout, builtin.mode);
        try stdout.flush();
        return;
    }

    const parsed = cli.parseGlobalArgs(args);
    if (parsed.debug) runtime_log_level = .debug;

    if (parsed.parse_error) |arg| {
        const message = cli.allocMessage(arena, "unknown global option: {s}", .{arg});
        cli.exitWithCliError(arena, stderr, parsed.mode, machine_output.usageInvalidArgument(message, "GlobalArgs"), cli.withHelp(arena, &cli.commands, null, message));
    }

    if (parsed.help or parsed.argv.len == 0) {
        if (parsed.argv.len == 0 and parsed.mode == .json and !parsed.help) {
            const message = "missing command";
            cli.exitWithCliError(arena, stderr, parsed.mode, machine_output.usageMissingArgument(message, "GlobalArgs"), message);
        }
        try cli.writeHelp(&cli.commands, null, stdout);
        try stdout.flush();
        std.process.exit(if (parsed.help) 0 else 2);
    }

    const ctx = cli.Ctx{
        .init = init,
        .stdout = stdout,
        .stderr = stderr,
        .mode = parsed.mode,
        .debug = parsed.debug,
    };
    cli.run(&cli.commands, &ctx, parsed.argv) catch |err| {
        // Any command can meet an old local format; tell a person to
        // re-create it instead of printing an error trace.
        if (parsed.mode == .json or err == error.FormatTooOld) {
            cli.exitWithCliError(arena, stderr, parsed.mode, machine_output.fromZigError(err), machine_output.fromZigError(err).message);
        }
        return err;
    };
    try stdout.flush();
}

fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@backingInt(message_level) <= @backingInt(runtime_log_level)) {
        std.log.defaultLog(message_level, scope, format, args);
    }
}
