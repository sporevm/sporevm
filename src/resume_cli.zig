//! CLI adapter for `spore resume`.
//!
//! This module owns argv parsing glue and event serialization. Resume behavior
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
    var event_writer = run_mod.EventWriter.init(std.heap.page_allocator, stdout, "resume");
    const events: ?api.EventSink = if (opts.event_mode == .jsonl) event_writer.sink() else null;
    const arena = init.arena.allocator();
    const full_args = try init.minimal.args.toSlice(arena);
    const result = api.resumeSpore(.{
        .io = init.io,
        .environ_map = init.environ_map,
    }, arena, .{
        .backend = opts.backend,
        .spore_dir = opts.spore_dir,
        .generation_path = opts.generation_path,
        .timeout_ms = opts.timeout_ms,
        .spore_executable = full_args[0],
        .debug = runtimeDebugEnabled(full_args),
        .events = events,
    }) catch |err| {
        if (opts.event_mode == .jsonl) {
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

fn runtimeDebugEnabled(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--debug")) return true;
    }
    return false;
}

fn wantsHelp(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "help") or
            std.mem.eql(u8, arg, "-h") or
            std.mem.eql(u8, arg, "--help"))
        {
            return true;
        }
    }
    return false;
}

test "resume cli help accepts help after options" {
    try std.testing.expect(wantsHelp(&.{"--help"}));
    try std.testing.expect(wantsHelp(&.{ "--backend", "hvf", "--help" }));
    try std.testing.expect(!wantsHelp(&.{"base.spore"}));
}
