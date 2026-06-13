//! The `spore` CLI.
//!
//! Temporary narrow surface. Lifecycle commands land with their slices; see
//! docs/plans/foundation.md.

const std = @import("std");
const Io = std.Io;
const sporevm = @import("sporevm");

const usage =
    \\Usage: spore <command>
    \\
    \\Commands:
    \\  version             Print the sporevm version
    \\  host-info           Print this host's platform facts as JSON
    \\  inspect <spore-dir> Print a spore manifest summary as JSON
    \\  help                Show this help
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
    } else if (std.mem.eql(u8, command, "host-info")) {
        try printJson(arena, stdout, try sporevm.platform.hostInfo());
    } else if (std.mem.eql(u8, command, "inspect")) {
        if (args.len != 3) {
            try stdout.writeAll("usage: spore inspect <spore-dir>\n");
            try stdout.flush();
            std.process.exit(2);
        }
        const parsed = try sporevm.spore.loadManifest(arena, args[2]);
        defer parsed.deinit();
        try printJson(arena, stdout, inspectSummary(parsed.value));
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

fn printJson(allocator: std.mem.Allocator, writer: *Io.Writer, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    try writer.writeAll(json);
    try writer.writeByte('\n');
}

const InspectSummary = struct {
    version: u32,
    platform: sporevm.spore.Platform,
    device_count: usize,
    memory_chunk_count: usize,
    present_memory_chunk_count: usize,
    gic_kind: []const u8,
};

fn inspectSummary(manifest: sporevm.spore.Manifest) InspectSummary {
    var present_chunks: usize = 0;
    for (manifest.memory.chunks) |maybe_chunk| {
        if (maybe_chunk != null) present_chunks += 1;
    }
    return .{
        .version = manifest.version,
        .platform = manifest.platform,
        .device_count = manifest.devices.len,
        .memory_chunk_count = manifest.memory.chunks.len,
        .present_memory_chunk_count = present_chunks,
        .gic_kind = @tagName(manifest.machine.gic.kind),
    };
}

test "usage names every command" {
    try std.testing.expect(std.mem.indexOf(u8, usage, "version") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "host-info") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "inspect") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "help") != null);
}
