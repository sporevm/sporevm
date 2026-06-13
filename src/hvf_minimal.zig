//! Minimal HVF boot/exec benchmark harness.

const std = @import("std");
const Io = std.Io;
const sporevm = @import("sporevm");
const minimal = @import("minimal_boot.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const opts = try minimal.parseArgs("hvf", args);

    try minimal.openConsoleLog(opts.console_log_path);
    defer minimal.closeConsoleLog();

    const kernel = try std.Io.Dir.cwd().readFileAlloc(init.io, opts.kernel_path, arena, .limited(256 * 1024 * 1024));
    const initrd = try std.Io.Dir.cwd().readFileAlloc(init.io, opts.initrd_path, arena, .limited(256 * 1024 * 1024));
    const boot_args = try minimal.cmdline(arena, opts.guest_port);
    var stream = try sporevm.virtio.vsock.HostStream.init(opts.guest_port, minimal.execRequest());

    const cause = try sporevm.hvf.vm.run(arena, .{
        .kernel = kernel,
        .ram_size = opts.memory_mib * 1024 * 1024,
        .cmdline = boot_args,
        .initrd = initrd,
        .console_sink = minimal.consoleSink,
        .exec_probe = &stream,
        .exec_probe_timeout_ms = opts.timeout_ms,
    });
    if (cause != .probe_complete) return error.ProbeDidNotComplete;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    const exit_code = try minimal.writeResult(arena, stdout, "hvf", opts, &stream);
    try stdout.flush();
    if (exit_code != 0) std.process.exit(exit_code);
}
