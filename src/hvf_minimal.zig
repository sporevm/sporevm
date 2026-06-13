//! Minimal HVF boot/exec benchmark harness.

const std = @import("std");
const Io = std.Io;
const sporevm = @import("sporevm");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const opts = try sporevm.run.parseHarnessArgs(.hvf, args);

    try sporevm.run.openConsoleLog(opts.console_log_path);
    defer sporevm.run.closeConsoleLog();

    const result = try sporevm.run.execute(init, arena, opts);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try sporevm.run.writeJsonResult(stdout, result);
    try stdout.flush();
    const exit_code = result.processExitCode();
    if (exit_code != 0) std.process.exit(exit_code);
}
