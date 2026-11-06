//! The `spore` CLI.
//!
//! `spore run` is the one-shot path. Named VM lifecycle commands are backed by
//! local monitor processes; see docs/lifecycle.md.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const spore_internal = @import("spore_internal");
const spore_api = spore_internal.api;
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
        try writeVersion(stdout, builtin.mode);
        try stdout.flush();
        return;
    }

    const parsed = parseGlobalArgs(args);
    if (parsed.debug) runtime_log_level = .debug;

    if (parsed.parse_error) |parse_error| {
        const message = cli.allocMessage(arena, "unknown global option: {s}", .{parse_error.arg});
        exitWithCliError(arena, stderr, parsed.mode, machine_output.usageInvalidArgument(message, "GlobalArgs"), cli.withHelp(arena, &commands, null, message));
    }

    if (parsed.help or parsed.argv.len == 0) {
        if (parsed.argv.len == 0 and parsed.mode == .json and !parsed.help) {
            const message = "missing command";
            exitWithCliError(arena, stderr, parsed.mode, machine_output.usageMissingArgument(message, "GlobalArgs"), message);
        }
        try cli.writeHelp(&commands, null, stdout);
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
    cli.run(&commands, &ctx, parsed.argv) catch |err| {
        // Any command can meet an old local format; tell a person to
        // re-create it instead of printing an error trace.
        if (parsed.mode == .json or err == error.FormatTooOld) {
            exitWithCliError(arena, stderr, parsed.mode, machine_output.fromZigError(err), machine_output.fromZigError(err).message);
        }
        return err;
    };
    try stdout.flush();
}

const checkpoint_cli = spore_internal.checkpoint_cli;
const lifecycle_cli = spore_internal.lifecycle_cli;
const rootfs_cli = spore_internal.rootfs_cli;
const image_cli = spore_internal.image_cli;
const system = spore_internal.system;

/// Every `spore` command. `spore --help` lists them in this order.
const commands = [_]cli.Command{
    .{ .name = "run", .summary = "Boot a throwaway VM and run one command", .usage = spore_internal.run.cli_usage, .output = .events, .run = spore_internal.run_cli.cli },
    .{ .name = "attach", .summary = "Restore a checkpoint and attach to its saved session", .usage = spore_internal.attach_cmd.cli_usage, .output = .events, .run = spore_internal.attach_cli.cli },
    .{ .name = "fanout", .summary = "Attach forked children concurrently with prefixed output", .usage = spore_internal.fanout.cli_usage, .output = .events, .run = spore_internal.fanout.cli },
    .{ .name = "build", .summary = "Build a Spore image from a Dockerfile subset", .usage = spore_internal.build_cli.usage, .output = .result, .run = spore_internal.build_cli.run },
    .{ .name = "vm create", .summary = "Create a named VM", .usage = lifecycle_cli.create_usage, .output = .result, .run = lifecycle_cli.createCli },
    .{ .name = "vm exec", .summary = "Execute a command in a named VM", .usage = lifecycle_cli.exec_usage, .output = .events, .run = lifecycle_cli.execCli },
    .{ .name = "vm logs", .summary = "Show retained initial-command stdout and stderr", .usage = lifecycle_cli.logs_usage, .output = .result, .run = lifecycle_cli.logsCli },
    .{ .name = "vm copy-in", .summary = "Copy one host file or directory into a named VM", .usage = lifecycle_cli.copy_in_usage, .output = .result, .run = lifecycle_cli.copyInCli },
    .{ .name = "vm copy-out", .summary = "Copy one guest file or directory out of a named VM", .usage = lifecycle_cli.copy_out_usage, .output = .result, .run = lifecycle_cli.copyOutCli },
    .{ .name = "vm save", .summary = "Save a named VM as a checkpoint; --stop removes the VM", .usage = lifecycle_cli.save_usage, .output = .result, .run = lifecycle_cli.saveCli },
    .{ .name = "vm restore", .summary = "Restore a checkpoint as a named VM", .usage = lifecycle_cli.restore_usage, .output = .result, .run = lifecycle_cli.restoreCli },
    .{ .name = "vm fork", .summary = "Fork a named VM into named VM children", .usage = lifecycle_cli.fork_usage, .output = .result, .run = lifecycle_cli.forkCli },
    .{ .name = "vm rm", .summary = "Stop a named VM and delete its runtime state", .usage = lifecycle_cli.rm_usage, .output = .result, .run = lifecycle_cli.rmCli },
    .{ .name = "vm ls", .summary = "List named VMs", .usage = lifecycle_cli.ls_usage, .output = .result, .run = lifecycle_cli.lsCli },
    .{ .name = "checkpoint inspect", .summary = "Print a checkpoint manifest summary", .usage = checkpoint_cli.inspect_usage, .output = .result, .run = checkpoint_cli.inspect },
    .{ .name = "checkpoint fork", .summary = "Fork a checkpoint into child checkpoints", .usage = checkpoint_cli.fork_usage, .output = .result, .run = checkpoint_cli.fork },
    .{ .name = "checkpoint rm", .summary = "Remove a checkpoint directory", .usage = checkpoint_cli.rm_usage, .output = .result, .run = checkpoint_cli.rm },
    .{ .name = "checkpoint push", .summary = "Push a checkpoint to an image store", .usage = checkpoint_cli.push_usage, .output = .result, .run = checkpoint_cli.push },
    .{ .name = "checkpoint pull", .summary = "Pull a checkpoint from an image store", .usage = checkpoint_cli.pull_usage, .output = .result, .run = checkpoint_cli.pull },
    .{ .name = "rootfs build", .summary = "Build an ext4 rootfs from an OCI image", .usage = rootfs_cli.build_usage, .output = .result, .run = rootfs_cli.build },
    .{ .name = "rootfs import-oci", .summary = "Import an OCI image layout as a local image", .usage = rootfs_cli.import_oci_usage, .output = .result, .run = rootfs_cli.importOci },
    .{ .name = "rootfs import-tar", .summary = "Import a rootfs tar as a local image", .usage = rootfs_cli.import_tar_usage, .output = .result, .run = rootfs_cli.importTar },
    .{ .name = "rootfs resolve", .summary = "Resolve an image tag to a digest reference", .usage = rootfs_cli.resolve_usage, .output = .result, .run = rootfs_cli.resolve },
    .{ .name = "rootfs cas-preload", .summary = "Chunk an exact rootfs into the rootfs CAS (repair)", .usage = rootfs_cli.cas_preload_usage, .output = .result, .run = rootfs_cli.casPreload },
    .{ .name = "image push", .summary = "Push a local image to an image store", .usage = image_cli.usage, .output = .result, .run = image_cli.push },
    .{ .name = "image pack", .summary = "Pack a local image into an immutable archive", .usage = image_cli.usage, .output = .result, .run = image_cli.pack },
    .{ .name = "image unpack", .summary = "Unpack an image archive as a local image", .usage = image_cli.usage, .output = .result, .run = image_cli.unpack },
    .{ .name = "cache gc", .summary = "Collect unreferenced content-addressed cache storage", .usage = system.cache_usage, .output = .result, .run = system.cacheGcCli },
    .{ .name = "cache pins", .summary = "List saved-spore pins", .usage = system.cache_usage, .output = .result, .run = system.pinsCli },
    .{ .name = "cache unpin", .summary = "Drop one saved-spore pin (expert-only)", .usage = system.cache_usage, .output = .result, .run = system.unpinCli },
    .{ .name = "system df", .summary = "Show local cache usage", .usage = system.usage, .output = .result, .run = system.dfCli },
    .{ .name = "system prune", .summary = "Prune local caches and old runtime fork batches", .usage = system.usage, .output = .result, .run = system.pruneCli },
    .{ .name = "host-info", .summary = "Print this host's platform facts", .usage = "usage: spore host-info\n", .output = .result, .run = hostInfo },
    .{ .name = "version", .summary = "Print the spore version", .usage = "usage: spore version\n", .output = .result, .run = version },
    .{ .name = "monitor", .summary = null, .usage = spore_internal.monitor.monitor_usage, .output = .text, .run = spore_internal.monitor.cli },
    .{ .name = "netd", .summary = null, .usage = spore_internal.spore_netd.netd_usage, .output = .text, .run = spore_internal.spore_netd.cli },
};

fn apiContext(ctx: *const cli.Ctx) spore_api.Context {
    return .{ .io = ctx.init.io, .environ_map = ctx.init.environ_map };
}

fn version(ctx: *const cli.Ctx, _: []const []const u8) !void {
    if (ctx.mode == .json) {
        try machine_output.writeJson(ctx.init.arena.allocator(), ctx.stdout, .{
            .schema = "spore.version.result.v1",
            .schema_version = @as(u32, 1),
            .version = spore_internal.version,
            .build_mode = @tagName(builtin.mode),
        });
    } else {
        try writeVersion(ctx.stdout, builtin.mode);
    }
}

fn hostInfo(ctx: *const cli.Ctx, args: []const []const u8) !void {
    const arena = ctx.init.arena.allocator();
    if (args.len != 0) {
        if (std.mem.startsWith(u8, args[0], "--")) {
            exitUnknownArgument(arena, ctx.stderr, ctx.mode, "host-info", args[0]);
        }
        exitUnexpectedArgument(arena, ctx.stderr, ctx.mode, "host-info", args[0]);
    }
    const info = try spore_api.hostInfo(apiContext(ctx), arena);
    if (ctx.mode == .json) {
        try machine_output.writeJson(arena, ctx.stdout, info);
    } else {
        try writeHostInfo(ctx.stdout, info);
    }
}

fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(runtime_log_level)) {
        std.log.defaultLog(message_level, scope, format, args);
    }
}

const GlobalArgs = struct {
    debug: bool = false,
    mode: machine_output.Mode = .human,
    help: bool = false,
    /// The command word and its arguments; empty when there is no command.
    argv: []const []const u8 = &.{},
    parse_error: ?GlobalParseError = null,
};

const GlobalParseError = struct {
    arg: []const u8,
};

fn parseGlobalArgs(args: []const []const u8) GlobalArgs {
    var parsed = GlobalArgs{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--debug")) {
            parsed.debug = true;
        } else if (std.mem.eql(u8, args[i], "--json")) {
            parsed.mode = .json;
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            parsed.help = true;
            return parsed;
        } else if (std.mem.startsWith(u8, args[i], "-")) {
            parsed.parse_error = .{ .arg = args[i] };
            return parsed;
        } else {
            parsed.argv = args[i..];
            return parsed;
        }
    }
    return parsed;
}

const exitWithCliError = cli.exitWithCliError;
const exitUnknownArgument = cli.exitUnknownArgument;
const exitUnexpectedArgument = cli.exitUnexpectedArgument;

fn writeVersion(writer: *Io.Writer, mode: std.builtin.OptimizeMode) !void {
    try writer.print("spore {s} ({t})\n", .{ spore_internal.version, mode });
}

fn writeHostInfo(writer: *Io.Writer, info: spore_api.HostInfo) !void {
    try writer.writeAll("Host info\n");
    try writer.print("  Class: {s}\n", .{info.host_class});
    try writer.print("  Architecture: {s}\n", .{info.architecture});
    switch (info.platform) {
        .arm64 => |platform| {
            try writer.print("  Platform: {s}/arm64\n", .{platform.os});
            try writer.print("  CPU profile: {s}\n", .{platform.cpu_profile});
            try writer.print("  Device model version: {d}\n", .{platform.device_model_version});
            try writer.print("  Counter frequency: {d} Hz ({s})\n", .{ platform.counter.frequency_hz, platform.counter.source });
        },
        .amd64 => |platform| {
            try writer.print("  Platform: {s}/amd64\n", .{platform.os});
            try writer.print("  Board profile: {s}\n", .{platform.board_profile});
            try writer.print("  CPU profile: {s} ({s})\n", .{ platform.cpu_profile, platform.cpu_profile_status });
            try writer.print("  Device model version: {d}\n", .{platform.device_model_version});
            try writer.writeAll("  KVM capabilities:\n");
            for (platform.kvm_capabilities) |capability| {
                if (capability.value) |value| {
                    try writer.print("    {s}: value={d} minimum={d} satisfied={s}\n", .{
                        capability.name,
                        value,
                        capability.minimum,
                        yesNo(capability.satisfied),
                    });
                } else {
                    try writer.print("    {s}: unavailable satisfied=no\n", .{capability.name});
                }
            }
        },
    }
    try writer.writeAll("  Backends:\n");
    for (info.backends) |backend| {
        try writer.print("    {s}: supported={s} available={s} reason={s}\n", .{
            backend.name,
            yesNo(backend.supported),
            yesNo(backend.available),
            backend.reason,
        });
    }
    try writer.writeAll("  Cache roots:\n");
    try writePathFact(writer, "kernels", info.cache_roots.kernels);
    try writePathFact(writer, "rootfs", info.cache_roots.rootfs);
    try writePathFact(writer, "runtime", info.cache_roots.runtime);
}

fn writePathFact(writer: *Io.Writer, label: []const u8, fact: anytype) !void {
    if (fact.path) |path| {
        try writer.print("    {s}: {s}\n", .{ label, path });
    } else {
        try writer.print("    {s}: unresolved ({s})\n", .{ label, fact.source });
    }
}

fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

test "version output distinguishes development and release builds" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeVersion(&out.writer, .Debug);
    try std.testing.expectEqualStrings("spore " ++ spore_internal.version ++ " (Debug)\n", out.written());

    out.clearRetainingCapacity();
    try writeVersion(&out.writer, .ReleaseSafe);
    try std.testing.expectEqualStrings("spore " ++ spore_internal.version ++ " (ReleaseSafe)\n", out.written());
}

test "command table names each command once and fits the dispatcher" {
    for (commands, 0..) |command, i| {
        for (commands[i + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, command.name, other.name));
        // A word is either a command or a group of verbs, never both.
        if (std.mem.indexOfScalar(u8, command.name, ' ')) |space| {
            for (commands) |other| try std.testing.expect(!std.mem.eql(u8, other.name, command.name[0..space]));
        }
        const spelled = try std.fmt.allocPrint(std.testing.allocator, "spore {s}", .{command.name});
        defer std.testing.allocator.free(spelled);
        try std.testing.expect(std.mem.indexOf(u8, command.usage, spelled) != null);
    }
}

test "only internal commands refuse global json, and only four commands stream" {
    for (commands) |command| {
        const streams = std.mem.eql(u8, command.name, "run") or std.mem.eql(u8, command.name, "attach") or
            std.mem.eql(u8, command.name, "vm exec") or std.mem.eql(u8, command.name, "fanout");
        const text = std.mem.eql(u8, command.name, "monitor") or std.mem.eql(u8, command.name, "netd");
        const expected: cli.Output = if (streams) .events else if (text) .text else .result;
        try std.testing.expectEqual(expected, command.output);
    }
}

test "help lists every public command" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try cli.writeHelp(&commands, null, &out.writer);
    for (commands) |command| {
        const listed = try std.fmt.allocPrint(std.testing.allocator, "\n  {s}  ", .{command.name});
        defer std.testing.allocator.free(listed);
        try std.testing.expectEqual(command.summary != null, std.mem.indexOf(u8, out.written(), listed) != null);
    }
}

test "global args parse debug before command" {
    const parsed = parseGlobalArgs(&.{ "spore", "--debug", "--json", "run", "--", "/bin/true" });
    try std.testing.expect(parsed.debug);
    try std.testing.expectEqual(machine_output.Mode.json, parsed.mode);
    try std.testing.expect(!parsed.help);
    try std.testing.expectEqual(@as(usize, 3), parsed.argv.len);
    try std.testing.expectEqualStrings("run", parsed.argv[0]);
    try std.testing.expectEqualStrings("--", parsed.argv[1]);
    try std.testing.expectEqualStrings("/bin/true", parsed.argv[2]);
}

test "global args parse help without command" {
    const parsed = parseGlobalArgs(&.{ "spore", "--help" });
    try std.testing.expect(parsed.help);
    try std.testing.expectEqual(@as(usize, 0), parsed.argv.len);
}
