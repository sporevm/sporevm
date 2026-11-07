//! CLI adapters for `spore checkpoint`: inspect, fork, rm, push and pull of
//! saved machine state. The operations are in `api.zig` and `lifecycle.zig`.

const std = @import("std");
const Io = std.Io;

const api = @import("api.zig");
const cli = @import("cli.zig");
const Ctx = cli.Ctx;
const lifecycle = @import("lifecycle.zig");
const machine_output = @import("machine_output.zig");

const allocMessage = cli.allocMessage;
const exitWithCliError = cli.exitWithCliError;
const exitUnknownArgument = cli.exitUnknownArgument;
const exitUnexpectedArgument = cli.exitUnexpectedArgument;
const exitInvalidValue = cli.exitInvalidValue;
const exitUsage = cli.exitUsage;

pub const inspect_usage = "usage: spore checkpoint inspect DIR\n";

pub const fork_usage =
    \\Usage:
    \\  spore checkpoint fork DIR --count N --out DIR
    \\
    \\Options:
    \\  --count N   Number of children to create
    \\  --out DIR   Directory for the child checkpoints
    \\  -h, --help  Show this help
    \\
    \\Workflow:
    \\  spore run --save base.spore --save-on TERM 'while true; do echo tick; sleep 1; done'
    \\  spore checkpoint fork base.spore --count 2 --out children
    \\  spore fanout children --for 10s
    \\
;

pub const rm_usage =
    \\Usage:
    \\  spore checkpoint rm DIR
    \\
    \\Deletes the checkpoint directory. A VM restored from it keeps its storage
    \\through its runtime lease; `spore system gc --force` then reclaims storage
    \\nothing else references.
    \\
    \\Options:
    \\  -h, --help  Show this help
    \\
;

pub const push_usage =
    \\Usage:
    \\  spore checkpoint push DIR STORE/TAG
    \\
    \\STORE is a directory, a file:// URL or s3://bucket/prefix (uploaded with
    \\the aws CLI); TAG may be blake3:<digest>. The checkpoint's RAM chunks and
    \\disk objects share the store's objects with images.
    \\
    \\Options:
    \\  -h, --help           Show this help
    \\
;

pub const pull_usage =
    \\Usage:
    \\  spore checkpoint pull STORE/TAG --out DIR
    \\
    \\STORE is a directory, a file://, http(s):// or s3://bucket/prefix URL; TAG
    \\may be blake3:<digest>. DIR must not exist and must be on the rootfs cache's
    \\filesystem. Run the pulled checkpoint with `spore run --from DIR`.
    \\
    \\Options:
    \\  --out DIR            Write the pulled checkpoint to DIR
    \\  -h, --help           Show this help
    \\
;

fn apiContext(ctx: *const Ctx) api.Context {
    return .{ .io = ctx.init.io, .environ_map = ctx.init.environ_map };
}

pub fn inspect(ctx: *const Ctx, args: []const []const u8) !void {
    const arena = ctx.init.arena.allocator();
    if (args.len != 1) exitUsage(arena, ctx.stderr, ctx.mode, "checkpoint inspect", "usage: spore checkpoint inspect DIR");
    const summary = try api.inspectSpore(arena, args[0]);
    if (ctx.mode == .json) {
        try machine_output.writeJson(arena, ctx.stdout, summary);
    } else {
        try writeInspectSummary(ctx.stdout, summary);
    }
}

pub fn fork(ctx: *const Ctx, args: []const []const u8) !void {
    const arena = ctx.init.arena.allocator();
    const result = try forkCommand(apiContext(ctx), arena, ctx.stderr, ctx.mode, args);
    if (ctx.mode == .json) {
        try machine_output.writeJson(arena, ctx.stdout, result);
    } else {
        try writeForkResult(ctx.stdout, result);
    }
}

pub fn rm(ctx: *const Ctx, args: []const []const u8) !void {
    const allocator = ctx.init.arena.allocator();
    const command = "checkpoint rm";
    if (args.len != 1) exitUsage(allocator, ctx.stderr, ctx.mode, command, "usage: spore checkpoint rm DIR");
    // An empty path resolves to the working directory.
    if (args[0].len == 0) {
        const message = "spore checkpoint rm: DIR must not be empty";
        exitWithCliError(allocator, ctx.stderr, ctx.mode, machine_output.usageInvalidArgument(message, "rm"), message);
    }
    const removed = lifecycle.removeSavedSpore(apiContext(ctx), allocator, args[0]) catch |err| switch (err) {
        error.FileNotFound => {
            const message = allocMessage(allocator, "spore checkpoint rm: checkpoint not found: {s}", .{args[0]});
            exitWithCliError(allocator, ctx.stderr, ctx.mode, machine_output.CliError.init(.object_not_found, message, "rm"), message);
        },
        error.InvalidSporeDir, error.BadManifest => {
            const message = allocMessage(allocator, "spore checkpoint rm: refusing to remove {s}: not a checkpoint (no readable spore manifest.json)", .{args[0]});
            exitWithCliError(allocator, ctx.stderr, ctx.mode, machine_output.CliError.init(.object_invalid, message, @errorName(err)), message);
        },
        else => |e| return e,
    };
    if (ctx.mode == .json) try machine_output.writeJson(allocator, ctx.stdout, removed) else try writeRemovedSavedSpore(ctx.stdout, removed);
}

pub fn push(ctx: *const Ctx, args: []const []const u8) !void {
    const arena = ctx.init.arena.allocator();
    const result = try pushCommand(apiContext(ctx), arena, ctx.stderr, ctx.mode, args);
    if (ctx.mode == .json) try machine_output.writeJson(arena, ctx.stdout, result) else try writePushResult(ctx.stdout, result);
}

pub fn pull(ctx: *const Ctx, args: []const []const u8) !void {
    const arena = ctx.init.arena.allocator();
    const result = try pullCommand(apiContext(ctx), arena, ctx.stderr, ctx.mode, args);
    if (ctx.mode == .json) try machine_output.writeJson(arena, ctx.stdout, result) else try writePullResult(ctx.stdout, result);
}

fn forkCommand(
    context: api.Context,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    args: []const []const u8,
) !api.ForkResult {
    const command_label = "checkpoint fork";
    var parent_dir: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var count: ?usize = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--count") and i + 1 < args.len) {
            i += 1;
            count = std.fmt.parseInt(usize, args[i], 10) catch {
                exitInvalidValue(allocator, stderr, mode, command_label, "--count", args[i]);
            };
        } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            exitUnknownArgument(allocator, stderr, mode, command_label, args[i]);
        } else if (parent_dir == null) {
            parent_dir = args[i];
        } else {
            exitUnexpectedArgument(allocator, stderr, mode, command_label, args[i]);
        }
    }

    if (parent_dir == null or out_dir == null or count == null) {
        exitUsage(allocator, stderr, mode, command_label, "usage: spore checkpoint fork DIR --count N --out DIR");
    }

    return api.fork(context, allocator, .{
        .parent_dir = parent_dir.?,
        .out_dir = out_dir.?,
        .count = count.?,
    }) catch |err| switch (err) {
        error.CrossDeviceOwnershipLink => {
            const message = allocMessage(allocator, "spore {s}: {s} must be on the rootfs cache's filesystem", .{ command_label, out_dir.? });
            exitWithCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command_label), message);
        },
        else => |e| return e,
    };
}

fn pushCommand(
    context: api.Context,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    args: []const []const u8,
) !api.PushResult {
    var spore_dir: ?[]const u8 = null;
    var destination: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--")) {
            exitUnknownArgument(allocator, stderr, mode, "checkpoint push", arg);
        } else if (spore_dir == null) {
            spore_dir = arg;
        } else if (destination == null) {
            destination = arg;
        } else {
            exitUnexpectedArgument(allocator, stderr, mode, "checkpoint push", arg);
        }
    }
    if (spore_dir == null or destination == null) {
        exitUsage(allocator, stderr, mode, "checkpoint push", "usage: spore checkpoint push DIR STORE/TAG");
    }
    return api.push(context, allocator, .{ .spore_dir = spore_dir.?, .destination = destination.? });
}

fn pullCommand(
    context: api.Context,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    args: []const []const u8,
) !api.PullResult {
    var source: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            exitUnknownArgument(allocator, stderr, mode, "checkpoint pull", args[i]);
        } else if (source == null) {
            source = args[i];
        } else {
            exitUnexpectedArgument(allocator, stderr, mode, "checkpoint pull", args[i]);
        }
    }
    if (source == null or out_dir == null) {
        exitUsage(allocator, stderr, mode, "checkpoint pull", "usage: spore checkpoint pull STORE/TAG --out DIR");
    }
    return api.pull(context, allocator, .{ .source = source.?, .out_dir = out_dir.? }) catch |err| switch (err) {
        error.CrossDeviceOwnershipLink => {
            const message = allocMessage(allocator, "spore checkpoint pull: {s} must be on the rootfs cache's filesystem", .{out_dir.?});
            exitWithCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "checkpoint pull"), message);
        },
        else => |e| return e,
    };
}

fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

fn writeInspectSummary(writer: *Io.Writer, summary: api.SporeInspectResult) !void {
    try writer.writeAll("Checkpoint manifest\n");
    try writer.print("  Resource type: {t}\n", .{summary.resource_type});
    try writer.print("  Portability: {t}\n", .{summary.portability});
    try writer.print("  Can attach: {s}\n", .{yesNo(summary.can_attach)});
    try writer.print("  Can run from: {s}\n", .{yesNo(summary.can_run_from)});
    try writer.print("  Version: {d}\n", .{summary.version});
    try writer.print("  Platform: {s}/{s}\n", .{ summary.platform.arch, summary.platform.cpu_profile });
    try writer.print("  vCPUs: {d}\n", .{summary.vcpu_count});
    try writer.print("  Devices: {d}\n", .{summary.device_count});
    try writer.print("  Ownership: {s}\n", .{summary.ownership});
    try writer.print(
        "  Memory: initial={d}, maximum={d}, requested={d}, captured={d} bytes\n",
        .{
            summary.initial_memory_bytes,
            summary.max_memory_bytes,
            summary.requested_memory_bytes,
            summary.captured_memory_bytes,
        },
    );
    try writer.print("  Memory chunks: {d} present of {d}\n", .{ summary.present_memory_chunk_count, summary.memory_chunk_count });
    if (summary.memory_backing_kind) |kind| {
        try writer.print("  Memory backing: {s}", .{kind});
        if (summary.memory_backing_size) |size| try writer.print(", {d} bytes", .{size});
        try writer.writeByte('\n');
    } else {
        try writer.writeAll("  Memory backing: none\n");
    }
    try writer.print("  GIC: {s}\n", .{summary.gic_kind});
    if (summary.sessions.len == 0) {
        try writer.writeAll("  Sessions: none\n");
    } else {
        try writer.print("  Sessions: {d}\n", .{summary.sessions.len});
        for (summary.sessions) |session| {
            try writer.print("    - {s}: stdin={s} stdout={s} stderr={s} terminal={s}\n", .{
                session.id,
                yesNo(session.streams.stdin),
                yesNo(session.streams.stdout),
                yesNo(session.streams.stderr),
                yesNo(session.streams.terminal),
            });
        }
    }
    if (summary.annotations.map.count() == 0) {
        try writer.writeAll("  Annotations: none\n");
    } else {
        try writer.print("  Annotations: {d}\n", .{summary.annotations.map.count()});
        var annotation_it = summary.annotations.map.iterator();
        while (annotation_it.next()) |entry| {
            try writer.print("    - {s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }
}

fn writeForkResult(writer: *Io.Writer, result: api.ForkResult) !void {
    try writer.writeAll("Checkpoint fork complete\n");
    try writer.print("  Parent: {s}\n", .{result.parent});
    try writer.print("  Children: {d}\n", .{result.count});
    try writer.print("  Output: {s}\n", .{result.out_dir});
    try writer.print("  Generation range: {d}..{d}\n", .{ result.first_generation, result.last_generation });
    if (result.pin_publish_ms) |ms| try writer.print("  Pin publish: {d}ms\n", .{ms});
    if (result.pin_lock_wait_ms) |ms| try writer.print("  Pin lock wait: {d}ms\n", .{ms});
}

fn writeRemovedSavedSpore(writer: *Io.Writer, result: lifecycle.RemovedSavedSpore) !void {
    try writer.print("removed checkpoint {s}; run `spore system gc --force` to reclaim storage nothing else references\n", .{result.spore_dir});
    try writer.flush();
}

fn writePushResult(writer: *Io.Writer, result: api.PushResult) !void {
    try writer.print(
        "ref: {s}\nspore_digest: {s}\nobjects: {d}\nobjects_written: {d}\nbytes_written: {d}\n",
        .{ result.ref, result.spore_digest, result.objects_total, result.objects_written, result.bytes_written },
    );
}

fn writePullResult(writer: *Io.Writer, result: api.PullResult) !void {
    try writer.print(
        "ref: {s}\nspore_digest: {s}\nout_dir: {s}\nram: {d} objects, {d} fetched, {d} bytes\ndisk: {d} objects, {d} fetched, {d} bytes\n",
        .{
            result.ref,          result.spore_digest,         result.out_dir,
            result.ram.objects,  result.ram.objects_fetched,  result.ram.bytes_fetched,
            result.disk.objects, result.disk.objects_fetched, result.disk.bytes_fetched,
        },
    );
}

test "checkpoint rm names the follow-up storage collection" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeRemovedSavedSpore(&out.writer, .{ .spore_dir = "disk.spore" });
    try std.testing.expectEqualStrings("removed checkpoint disk.spore; run `spore system gc --force` to reclaim storage nothing else references\n", out.written());
}
