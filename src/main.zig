//! The `spore` CLI.
//!
//! Slice 0 scaffold: `version` and `help` only. Lifecycle commands land with
//! their slices; see docs/plans/foundation.md.

const std = @import("std");
const Io = std.Io;
const sporevm = @import("sporevm");

const usage =
    \\Usage: spore <command>
    \\
    \\Commands:
    \\  version   Print the sporevm version
    \\  help      Show this help
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    if (args.len < 2) {
        try stdout.writeAll(usage);
        try stdout.flush();
        std.process.exit(2);
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "version")) {
        try stdout.print("spore {s}\n", .{sporevm.version});
    } else if (std.mem.eql(u8, command, "help")) {
        try stdout.writeAll(usage);
    } else {
        try stdout.print("unknown command: {s}\n\n", .{command});
        try stdout.writeAll(usage);
        try stdout.flush();
        std.process.exit(2);
    }
    try stdout.flush();
}

test "usage names every command" {
    try std.testing.expect(std.mem.indexOf(u8, usage, "version") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "help") != null);
}
