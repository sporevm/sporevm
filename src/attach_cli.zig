//! CLI adapter for `spore attach`.
//!
//! This module owns argv parsing glue and event serialization. Attach behavior
//! flows through `api.zig`.

const std = @import("std");
const Io = std.Io;

const api = @import("api.zig");
const attach_mod = @import("attach.zig");
const run_mod = @import("run.zig");

pub fn cli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0 or wantsHelp(args)) {
        try stdout.writeAll(attach_mod.cli_usage);
        return;
    }

    var event_writer = run_mod.EventWriter.init(std.heap.page_allocator, stdout, "attach");
    if (requestsJsonl(args)) attach_mod.cli_setup_events = event_writer.sink();
    defer attach_mod.cli_setup_events = null;
    const opts = try attach_mod.parseCliArgs(args);
    const events: ?api.EventSink = if (opts.event_mode == .jsonl) event_writer.sink() else null;
    const arena = init.arena.allocator();
    const full_args = try init.minimal.args.toSlice(arena);
    const result = api.attachSpore(.{
        .io = init.io,
        .environ_map = init.environ_map,
    }, arena, .{
        .backend = opts.backend,
        .spore_dir = opts.spore_dir,
        .session_id = opts.session_id,
        .generation_path = opts.generation_path,
        .timeout_ms = opts.timeout_ms,
        .spore_executable = full_args[0],
        .debug = runtimeDebugEnabled(full_args),
        .interactive = opts.interactive,
        .tty = opts.tty,
        .bound_services = opts.bound_services.slice(),
        .events = events,
    }) catch |err| {
        if (opts.event_mode == .jsonl) {
            std.process.exit(api.classifyFailure(err).exit_code);
        }
        if (err == error.NoSavedSession) {
            std.debug.print(
                "spore attach: spore has no saved session; run new commands with `spore run --from {s} ...`, or create one with `spore run --save <spore> --save-on TERM ...`; verify with `spore inspect {s}` and `Sessions: 1`\n",
                .{ opts.spore_dir, opts.spore_dir },
            );
            std.process.exit(api.classifyFailure(err).exit_code);
        }
        if (err == error.SavedSessionUnavailable) {
            std.debug.print("spore attach: saved session is not available: {s}\n", .{opts.session_id orelse "default"});
            std.process.exit(api.classifyFailure(err).exit_code);
        }
        if (err == error.SavedSessionHasNoInteractiveStdin) {
            std.debug.print("spore attach: saved session has no interactive stdin: {s}\n", .{opts.session_id orelse "default"});
            std.process.exit(api.classifyFailure(err).exit_code);
        }
        if (err == error.SavedSessionHasNoTerminal) {
            std.debug.print("spore attach: saved session has no terminal: {s}\n", .{opts.session_id orelse "default"});
            std.process.exit(api.classifyFailure(err).exit_code);
        }
        return err;
    };
    if (opts.event_mode == .jsonl) {
        try stdout.flush();
    }
    const code = result.processExitCode();
    if (code != 0) std.process.exit(code);
}

fn requestsJsonl(args: []const []const u8) bool {
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--events=jsonl")) return true;
        if (std.mem.eql(u8, arg, "--events") and i + 1 < args.len and std.mem.eql(u8, args[i + 1], "jsonl")) return true;
    }
    return false;
}

fn runtimeDebugEnabled(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--debug")) return true;
    }
    return false;
}

fn wantsHelp(args: []const []const u8) bool {
    if (args.len == 1 and std.mem.eql(u8, args[0], "help")) return true;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or
            std.mem.eql(u8, arg, "--help"))
        {
            return true;
        }
    }
    return false;
}

test "attach cli help accepts help after options" {
    try std.testing.expect(wantsHelp(&.{"--help"}));
    try std.testing.expect(wantsHelp(&.{ "--backend", "hvf", "--help" }));
    try std.testing.expect(!wantsHelp(&.{"base.spore"}));
    try std.testing.expect(!wantsHelp(&.{ "help", "--backend", "hvf" }));
}
