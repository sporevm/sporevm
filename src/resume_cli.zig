//! CLI adapter for `spore attach`.
//!
//! This module owns argv parsing glue and event serialization. Attach behavior
//! flows through `api.zig`.

const std = @import("std");
const Io = std.Io;

const api = @import("api.zig");
const resume_mod = @import("resume.zig");
const run_mod = @import("run.zig");

pub fn cli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0 or wantsHelp(args)) {
        try stdout.writeAll(resume_mod.cli_usage);
        return;
    }

    const opts = try resume_mod.parseCliArgs(args);
    var event_writer = run_mod.EventWriter.init(std.heap.page_allocator, stdout, "attach");
    const events: ?api.EventSink = if (opts.event_mode == .jsonl) event_writer.sink() else null;
    const arena = init.arena.allocator();
    const full_args = try init.minimal.args.toSlice(arena);
    const result = api.resumeSpore(.{
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
        if (err == error.NoCapturedSession) {
            std.debug.print(
                "spore attach: spore has no saved session; run new commands with `spore run --from {s} ...`, or create one with `spore run --save <spore> --save-on TERM ...`; verify with `spore inspect {s}` and `Sessions: 1`\n",
                .{ opts.spore_dir, opts.spore_dir },
            );
            std.process.exit(2);
        }
        if (err == error.CapturedSessionUnavailable) {
            std.debug.print("spore attach: saved session is not available: {s}\n", .{opts.session_id orelse "default"});
            std.process.exit(2);
        }
        if (err == error.CapturedSessionHasNoInteractiveStdin) {
            std.debug.print("spore attach: saved session has no interactive stdin: {s}\n", .{opts.session_id orelse "default"});
            std.process.exit(2);
        }
        if (err == error.CapturedSessionHasNoTerminal) {
            std.debug.print("spore attach: saved session has no terminal: {s}\n", .{opts.session_id orelse "default"});
            std.process.exit(2);
        }
        return err;
    };
    if (opts.event_mode == .jsonl) {
        try stdout.flush();
    }
    const code = result.processExitCode();
    if (code != 0) std.process.exit(code);
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
