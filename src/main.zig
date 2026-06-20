//! The `spore` CLI.
//!
//! `spore run` is the one-shot path. Named VM lifecycle commands grow in
//! monitor-backed slices; see docs/plans/lifecycle-monitor.md.

const std = @import("std");
const Io = std.Io;
const sporevm = @import("sporevm");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

var runtime_log_level: std.log.Level = .warn;

const usage =
    \\Usage: spore [--debug] <command>
    \\
    \\Global options:
    \\  --debug             Show verbose VMM and restore logs
    \\
    \\Commands:
    \\  system             Inspect and prune local SporeVM system state
    \\  rootfs              Build rootfs images from OCI images
    \\  run [--kernel Image] [--initrd root.cpio] [--net] [--allow-cidr CIDR] [--allow-host HOST] -- <argv...>
    \\                      Boot a throwaway VM and run one command
    \\  resume <spore-dir> [--name NAME]
    \\                      Resume one spore, or resume it as a named VM
    \\  create NAME [options]
    \\                      Create a named VM lifecycle target
    \\  exec NAME -- <argv...>
    \\                      Execute a command in a named VM
    \\  rm NAME             Remove a named VM
    \\  suspend NAME --out DIR
    \\                      Checkpoint a diskless named VM into a spore
    \\  ls                  List named VMs in the local runtime registry
    \\  version             Print the sporevm version
    \\  host-info           Print this host's platform facts as JSON
    \\  inspect <spore-dir> Print a spore manifest summary as JSON
    \\  fork <spore-dir> --count N --out DIR
    \\                      Mint child spores that share parent chunks
    \\  fanout <children-dir> [--for DURATION]
    \\                      Resume forked children concurrently with prefixed output
    \\  pack <spore-dir> [--children DIR] [--rootfs=exact|metadata-only] --out DIR
    \\                      Pack portable spore chunks into a local bundle
    \\  unpack <bundle-dir> [--child ID] [--allow-metadata-only-rootfs] --out DIR
    \\                      Unpack a local spore bundle into a spore dir
    \\  push <bundle-dir> s3://BUCKET/PREFIX [--region REGION]
    \\                      Push an indexed bundle to an object store
    \\  pull file://BUNDLE|s3://BUNDLE@sha256:DIGEST|http(s)://BUNDLE@sha256:DIGEST [--child ID] [--allow-metadata-only-rootfs] --out DIR [--region REGION]
    \\                      Pull one child into a spore dir
    \\  help                Show this help
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const parsed = parseGlobalArgs(args);
    if (parsed.debug) runtime_log_level = .debug;

    if (parsed.help or parsed.command == null) {
        try stdout.writeAll(usage);
        try stdout.flush();
        std.process.exit(if (parsed.help) 0 else 2);
    }

    const command = parsed.command.?;
    const command_args = parsed.command_args;
    if (std.mem.eql(u8, command, "system")) {
        try sporevm.system.run(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "rootfs")) {
        try sporevm.rootfs.run(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "run")) {
        try sporevm.run.cli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "resume")) {
        if (wantsNamedResume(command_args)) {
            try sporevm.lifecycle.resumeCli(init, command_args, stdout);
        } else {
            try sporevm.resume_cmd.cli(init, command_args, stdout);
        }
    } else if (std.mem.eql(u8, command, "create")) {
        try sporevm.lifecycle.createCli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "exec")) {
        try sporevm.lifecycle.execCli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "rm")) {
        try sporevm.lifecycle.rmCli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "suspend")) {
        try sporevm.lifecycle.suspendCli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "ls")) {
        try sporevm.lifecycle.lsCli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "monitor")) {
        try sporevm.monitor.cli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "netd")) {
        try sporevm.spore_netd.cli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "version")) {
        try stdout.print("spore {s}\n", .{sporevm.version});
    } else if (std.mem.eql(u8, command, "host-info")) {
        try printJson(arena, stdout, try sporevm.platform.hostInfo());
    } else if (std.mem.eql(u8, command, "inspect")) {
        if (command_args.len != 1) {
            try stdout.writeAll("usage: spore inspect <spore-dir>\n");
            try stdout.flush();
            std.process.exit(2);
        }
        const manifest = try sporevm.spore.loadManifest(arena, command_args[0]);
        defer manifest.deinit();
        try printJson(arena, stdout, inspectSummary(manifest.value));
    } else if (std.mem.eql(u8, command, "fork")) {
        const result = try forkCommand(init, arena, command_args);
        try printJson(arena, stdout, result);
    } else if (std.mem.eql(u8, command, "fanout")) {
        try sporevm.fanout.cli(init, command_args, stdout);
    } else if (std.mem.eql(u8, command, "pack")) {
        const result = try packCommand(init, arena, command_args);
        try printJson(arena, stdout, result);
    } else if (std.mem.eql(u8, command, "unpack")) {
        const result = try unpackCommand(init, arena, command_args);
        try printJson(arena, stdout, result);
    } else if (std.mem.eql(u8, command, "push")) {
        const result = try pushCommand(init, arena, command_args);
        try printJson(arena, stdout, result);
    } else if (std.mem.eql(u8, command, "pull")) {
        const result = try pullCommand(init, arena, command_args);
        try printJson(arena, stdout, result);
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
    help: bool = false,
    command: ?[]const u8 = null,
    command_args: []const []const u8 = &.{},
};

fn parseGlobalArgs(args: []const []const u8) GlobalArgs {
    var parsed = GlobalArgs{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--debug")) {
            parsed.debug = true;
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            parsed.help = true;
            return parsed;
        } else {
            parsed.command = args[i];
            parsed.command_args = args[i + 1 ..];
            return parsed;
        }
    }
    return parsed;
}

fn printJson(allocator: std.mem.Allocator, writer: *Io.Writer, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    try writer.writeAll(json);
    try writer.writeByte('\n');
}

fn wantsNamedResume(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--name")) return true;
    }
    return false;
}

fn forkCommand(init: std.process.Init, allocator: std.mem.Allocator, args: []const []const u8) !sporevm.spore.ForkResult {
    var parent_dir: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var count: ?usize = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--count") and i + 1 < args.len) {
            i += 1;
            count = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            std.debug.print("unknown fork argument: {s}\n", .{args[i]});
            std.process.exit(2);
        } else if (parent_dir == null) {
            parent_dir = args[i];
        } else {
            std.debug.print("unexpected fork argument: {s}\n", .{args[i]});
            std.process.exit(2);
        }
    }

    if (parent_dir == null or out_dir == null or count == null) {
        std.debug.print("usage: spore fork <spore-dir> --count N --out DIR\n", .{});
        std.process.exit(2);
    }

    return sporevm.spore.fork(allocator, .{
        .parent_dir = parent_dir.?,
        .out_dir = out_dir.?,
        .count = count.?,
        .environ_map = init.environ_map,
    });
}

fn packCommand(init: std.process.Init, allocator: std.mem.Allocator, args: []const []const u8) !sporevm.bundle.PackResult {
    var spore_dir: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var children_dir: ?[]const u8 = null;
    var rootfs_policy: sporevm.bundle.RootfsBundlePolicy = .exact_bytes;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--children") and i + 1 < args.len) {
            i += 1;
            children_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--rootfs") and i + 1 < args.len) {
            i += 1;
            rootfs_policy = try parseRootfsBundlePolicy(args[i]);
        } else if (std.mem.startsWith(u8, args[i], "--rootfs=")) {
            rootfs_policy = try parseRootfsBundlePolicy(args[i]["--rootfs=".len..]);
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            std.debug.print("unknown pack argument: {s}\n", .{args[i]});
            std.process.exit(2);
        } else if (spore_dir == null) {
            spore_dir = args[i];
        } else {
            std.debug.print("unexpected pack argument: {s}\n", .{args[i]});
            std.process.exit(2);
        }
    }

    if (spore_dir == null or out_dir == null) {
        std.debug.print("usage: spore pack <spore-dir> [--children DIR] [--rootfs=exact|metadata-only] --out DIR\n", .{});
        std.process.exit(2);
    }

    return sporevm.bundle.pack(allocator, .{
        .io = init.io,
        .spore_dir = spore_dir.?,
        .out_dir = out_dir.?,
        .rootfs_cache_dir = optionalRootfsCacheRoot(allocator, init),
        .children_dir = children_dir,
        .rootfs_policy = rootfs_policy,
    });
}

fn unpackCommand(init: std.process.Init, allocator: std.mem.Allocator, args: []const []const u8) !sporevm.bundle.UnpackResult {
    var bundle_dir: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var child_id: ?[]const u8 = null;
    var allow_metadata_only_rootfs = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--child") and i + 1 < args.len) {
            i += 1;
            child_id = args[i];
        } else if (std.mem.eql(u8, args[i], "--allow-metadata-only-rootfs")) {
            allow_metadata_only_rootfs = true;
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            std.debug.print("unknown unpack argument: {s}\n", .{args[i]});
            std.process.exit(2);
        } else if (bundle_dir == null) {
            bundle_dir = args[i];
        } else {
            std.debug.print("unexpected unpack argument: {s}\n", .{args[i]});
            std.process.exit(2);
        }
    }

    if (bundle_dir == null or out_dir == null) {
        std.debug.print("usage: spore unpack <bundle-dir> [--child ID] [--allow-metadata-only-rootfs] --out DIR\n", .{});
        std.process.exit(2);
    }

    return sporevm.bundle.unpack(allocator, .{
        .io = init.io,
        .bundle_dir = bundle_dir.?,
        .out_dir = out_dir.?,
        .rootfs_cache_dir = optionalRootfsCacheRoot(allocator, init),
        .child_id = child_id,
        .allow_metadata_only_rootfs = allow_metadata_only_rootfs,
    });
}

fn pushCommand(init: std.process.Init, allocator: std.mem.Allocator, args: []const []const u8) !sporevm.bundle.PushResult {
    var bundle_dir: ?[]const u8 = null;
    var destination: ?[]const u8 = null;
    var aws_region: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--region") and i + 1 < args.len) {
            i += 1;
            aws_region = args[i];
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            std.debug.print("unknown push argument: {s}\n", .{args[i]});
            std.process.exit(2);
        } else if (bundle_dir == null) {
            bundle_dir = args[i];
        } else if (destination == null) {
            destination = args[i];
        } else {
            std.debug.print("unexpected push argument: {s}\n", .{args[i]});
            std.process.exit(2);
        }
    }

    if (bundle_dir == null or destination == null) {
        std.debug.print("usage: spore push <bundle-dir> s3://BUCKET/PREFIX [--region REGION]\n", .{});
        std.process.exit(2);
    }

    return sporevm.bundle.push(allocator, .{
        .io = init.io,
        .bundle_dir = bundle_dir.?,
        .destination = destination.?,
        .aws_region = aws_region,
    });
}

fn pullCommand(init: std.process.Init, allocator: std.mem.Allocator, args: []const []const u8) !sporevm.bundle.PullResult {
    var source: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var child_id: ?[]const u8 = null;
    var aws_region: ?[]const u8 = null;
    var allow_metadata_only_rootfs = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--child") and i + 1 < args.len) {
            i += 1;
            child_id = args[i];
        } else if (std.mem.eql(u8, args[i], "--region") and i + 1 < args.len) {
            i += 1;
            aws_region = args[i];
        } else if (std.mem.eql(u8, args[i], "--allow-metadata-only-rootfs")) {
            allow_metadata_only_rootfs = true;
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            std.debug.print("unknown pull argument: {s}\n", .{args[i]});
            std.process.exit(2);
        } else if (source == null) {
            source = args[i];
        } else {
            std.debug.print("unexpected pull argument: {s}\n", .{args[i]});
            std.process.exit(2);
        }
    }

    if (source == null or out_dir == null) {
        std.debug.print("usage: spore pull file://BUNDLE|s3://BUNDLE@sha256:DIGEST|http(s)://BUNDLE@sha256:DIGEST [--child ID] [--allow-metadata-only-rootfs] --out DIR [--region REGION]\n", .{});
        std.process.exit(2);
    }

    return sporevm.bundle.pull(allocator, .{
        .io = init.io,
        .source = source.?,
        .out_dir = out_dir.?,
        .rootfs_cache_dir = optionalRootfsCacheRoot(allocator, init),
        .bundle_cache_dir = optionalBundleCacheRoot(allocator, init),
        .child_id = child_id,
        .allow_metadata_only_rootfs = allow_metadata_only_rootfs,
        .aws_region = aws_region,
    });
}

fn parseRootfsBundlePolicy(value: []const u8) !sporevm.bundle.RootfsBundlePolicy {
    if (std.mem.eql(u8, value, "exact") or std.mem.eql(u8, value, "exact-bytes")) return .exact_bytes;
    if (std.mem.eql(u8, value, "metadata-only")) return .metadata_only;
    std.debug.print("unknown rootfs bundle policy: {s}\n", .{value});
    std.process.exit(2);
}

fn optionalRootfsCacheRoot(allocator: std.mem.Allocator, init: std.process.Init) ?[]const u8 {
    return sporevm.local_paths.rootfsCacheRootPath(allocator, init.environ_map) catch null;
}

fn optionalBundleCacheRoot(allocator: std.mem.Allocator, init: std.process.Init) ?[]const u8 {
    return sporevm.local_paths.bundleCacheRootPath(allocator, init.environ_map) catch null;
}

const InspectSummary = struct {
    version: u32,
    platform: sporevm.spore.Platform,
    device_count: usize,
    memory_chunk_count: usize,
    present_memory_chunk_count: usize,
    memory_backing_kind: ?[]const u8,
    memory_backing_size: ?u64,
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
        .memory_backing_kind = if (manifest.memory.backing) |backing| backing.kind else null,
        .memory_backing_size = if (manifest.memory.backing) |backing| backing.size else null,
        .gic_kind = @tagName(manifest.machine.gic.kind),
    };
}

test "usage names every command" {
    try std.testing.expect(std.mem.indexOf(u8, usage, "--debug") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "rootfs") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "run") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "resume") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "create") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "rm") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "suspend") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "resume") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "ls") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "version") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "host-info") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "inspect") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "fork") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "fanout") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "pack") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "unpack") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "push") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "pull") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "help") != null);
}

test "rootfs bundle policy parser accepts exact and metadata-only spellings" {
    try std.testing.expectEqual(sporevm.bundle.RootfsBundlePolicy.exact_bytes, try parseRootfsBundlePolicy("exact"));
    try std.testing.expectEqual(sporevm.bundle.RootfsBundlePolicy.exact_bytes, try parseRootfsBundlePolicy("exact-bytes"));
    try std.testing.expectEqual(sporevm.bundle.RootfsBundlePolicy.metadata_only, try parseRootfsBundlePolicy("metadata-only"));
}

test "resume dispatch can distinguish product and named lifecycle modes" {
    try std.testing.expect(!wantsNamedResume(&.{"spore-dir"}));
    try std.testing.expect(wantsNamedResume(&.{ "spore-dir", "--name", "bench-1" }));
}

test "global args parse debug before command" {
    const parsed = parseGlobalArgs(&.{ "spore", "--debug", "run", "--", "/bin/true" });
    try std.testing.expect(parsed.debug);
    try std.testing.expect(!parsed.help);
    try std.testing.expectEqualStrings("run", parsed.command.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.command_args.len);
    try std.testing.expectEqualStrings("--", parsed.command_args[0]);
    try std.testing.expectEqualStrings("/bin/true", parsed.command_args[1]);
}

test "global args parse help without command" {
    const parsed = parseGlobalArgs(&.{ "spore", "--help" });
    try std.testing.expect(parsed.help);
    try std.testing.expect(parsed.command == null);
}
