//! CLI adapter for `spore attach`.
//!
//! This module owns argv parsing glue and event serialization. Attach behavior
//! flows through `api.zig`.

const std = @import("std");
const Io = std.Io;

const api = @import("api.zig");
const Ctx = @import("cli.zig").Ctx;
const attach_mod = @import("attach.zig");
const events_mod = @import("events.zig");

pub fn cli(ctx: *const Ctx, args: []const []const u8) !void {
    const init = ctx.init;
    const stdout = ctx.stdout;
    if (args.len == 0 and ctx.mode != .json) {
        try stdout.writeAll(attach_mod.cli_usage);
        return;
    }

    var event_writer = events_mod.EventWriter.init(std.heap.page_allocator, stdout, "attach");
    if (ctx.mode == .json) attach_mod.cli_setup_events = event_writer.sink();
    defer attach_mod.cli_setup_events = null;
    var opts = try attach_mod.parseCliArgs(args);
    opts.event_mode = ctx.eventMode();
    const events: ?api.EventSink = if (opts.event_mode == .jsonl) event_writer.sink() else null;
    const arena = init.arena.allocator();
    const result = api.attachSpore(.{
        .io = init.io,
        .environ_map = init.environ_map,
    }, arena, .{
        .backend = opts.backend,
        .spore_dir = opts.spore_dir,
        .session_id = opts.session_id,
        .generation_path = opts.generation_path,
        .timeout_ms = opts.timeout_ms,
        .spore_executable = try std.process.executablePathAlloc(init.io, arena),
        .debug = ctx.debug,
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
