//! CLI adapters for `spore run` and `spore attach`.
//!
//! This module owns argv parsing glue and stdout/stderr serialization. Runtime
//! behavior flows through `api.zig`.

const std = @import("std");
const Io = std.Io;

const api = @import("api.zig");
const fd_util = @import("fd.zig");
const run_mod = @import("run.zig");

pub fn cli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help")) {
        try stdout.writeAll(run_mod.cli_usage);
        return;
    }

    const arena = init.arena.allocator();
    const parsed = try run_mod.parseCliArgs(args);
    try runParsedCli(init, arena, parsed, stdout);
}

const attach_usage =
    \\Usage:
    \\  spore attach [options] DIR
    \\
    \\Options:
    \\  -i, --interactive       Claim input for a captured stdin-capable session
    \\  -t, --tty               Attach to a captured terminal session
    \\  --backend auto|hvf|kvm  Backend to run (default: auto)
    \\  --timeout-ms N          Probe timeout in milliseconds (default: 30000)
    \\  --guest-port N          Guest vsock listen port (default: 10700)
    \\  --events=jsonl          Emit lifecycle and guest output events as JSONL on stdout
    \\  -h, --help              Show this help
    \\
;

pub fn attachCli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 1 and (std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help"))) {
        try stdout.writeAll(attach_usage);
        return;
    }

    const arena = init.arena.allocator();
    const run_args = attachRunArgs(arena, args) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => failRunSetup("spore attach: expected options followed by one spore directory\n\n{s}", .{attach_usage}),
    };

    const parsed = try run_mod.parseCliArgs(run_args);
    if (parsed.command.len != 0) {
        failRunSetup("spore attach: commands are not supported; use spore run --from DIR 'command'\n\n{s}", .{attach_usage});
    }
    try runParsedCli(init, arena, parsed, stdout);
}

const AttachArgError = std.mem.Allocator.Error || error{
    MissingSporeDir,
    MissingValue,
    UnexpectedArgument,
    UnexpectedSeparator,
};

fn attachRunArgs(allocator: std.mem.Allocator, args: []const []const u8) AttachArgError![]const []const u8 {
    if (args.len == 0) return error.MissingSporeDir;

    const spore_dir = args[args.len - 1];
    if (std.mem.startsWith(u8, spore_dir, "-")) return error.MissingSporeDir;

    var i: usize = 0;
    while (i < args.len - 1) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) return error.UnexpectedSeparator;
        if (isAttachBooleanOption(arg)) continue;
        if (isAttachEqualsOption(arg)) continue;
        if (isAttachValueOption(arg)) {
            i += 1;
            if (i >= args.len - 1) return error.MissingValue;
            continue;
        }
        return error.UnexpectedArgument;
    }

    const run_args = try allocator.alloc([]const u8, args.len + 1);
    run_args[0] = "--from";
    run_args[1] = spore_dir;
    @memcpy(run_args[2..], args[0 .. args.len - 1]);
    return run_args;
}

fn isAttachBooleanOption(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-i") or
        std.mem.eql(u8, arg, "--interactive") or
        std.mem.eql(u8, arg, "-t") or
        std.mem.eql(u8, arg, "--tty") or
        std.mem.eql(u8, arg, "-it") or
        std.mem.eql(u8, arg, "-ti");
}

fn isAttachValueOption(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--backend") or
        std.mem.eql(u8, arg, "--timeout-ms") or
        std.mem.eql(u8, arg, "--guest-port") or
        std.mem.eql(u8, arg, "--events");
}

fn isAttachEqualsOption(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "--backend=") or
        std.mem.startsWith(u8, arg, "--timeout-ms=") or
        std.mem.startsWith(u8, arg, "--guest-port=") or
        std.mem.startsWith(u8, arg, "--events=");
}

fn runParsedCli(init: std.process.Init, arena: std.mem.Allocator, parsed: run_mod.CliOptions, stdout: *Io.Writer) !void {
    var event_writer = run_mod.EventWriter.init(std.heap.page_allocator, stdout, "run");
    var raw_output = RawOutputSink{};
    const events: ?api.EventSink = switch (parsed.event_mode) {
        .jsonl => event_writer.sink(),
        .none => raw_output.sink(),
    };

    try run_mod.openConsoleLog(parsed.shared.console_log_path);
    defer run_mod.closeConsoleLog();

    const full_args = try init.minimal.args.toSlice(arena);
    const spore_executable = full_args[0];
    const result = runParsed(init, arena, parsed, events, spore_executable, runtimeDebugEnabled(full_args)) catch |err| {
        if (parsed.event_mode == .jsonl) {
            std.process.exit(api.classifyFailure(err).exit_code);
        }
        if (run_mod.isCaptureAborted(err)) std.process.exit(130);
        if (run_mod.isNetworkGatewayError(err)) {
            run_mod.printNetworkGatewayError(err);
            std.process.exit(1);
        }
        if (err == error.InteractiveStreamProtocolFailed) {
            const classified = api.classifyFailure(err);
            writeStderr(classified.message);
            writeStderr("\n");
            std.process.exit(classified.exit_code);
        }
        return err;
    };
    if (result.captured and parsed.event_mode != .jsonl) {
        if (result.capture_path) |path| {
            const message = try std.fmt.allocPrint(arena, "spore run: captured snapshot at {s}\n", .{path});
            writeStderr(message);
        }
    }
    if (parsed.event_mode == .jsonl) {
        try stdout.flush();
    }
    const code = result.processExitCode();
    if (code != 0) std.process.exit(code);
}

fn runParsed(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    parsed: run_mod.CliOptions,
    events: ?api.EventSink,
    spore_executable: []const u8,
    debug: bool,
) !api.RunResult {
    if (parsed.from_spore_dir) |spore_dir| {
        if (parsed.network_requested or parsed.network_policy.hasRules() or parsed.network_policy.hasBoundServices()) {
            failRunSetup("spore run: --from uses the captured network policy; omit --net and network flags", .{});
        }
        const command = if (parsed.command.len == 0)
            &.{}
        else
            run_mod.cliGuestCommand(allocator, parsed) catch |err| switch (err) {
                error.ShellCommandArgumentCountUnsupported => failRunSetup("spore run: shell command form accepts one command string; quote it or use -- for argv", .{}),
                else => return err,
            };
        if (parsed.tty and command.len != 0) {
            failRunSetup("spore run: -t with --from command execution is not supported yet; omit the command to attach", .{});
        }
        validateTerminalPolicy(parsed);
        return api.runFromSpore(.{
            .io = init.io,
            .environ_map = init.environ_map,
        }, allocator, .{
            .backend = parsed.backend,
            .spore_dir = spore_dir,
            .command = command,
            .interactive = parsed.interactive,
            .tty = parsed.tty,
            .vcpus = parsed.shared.vcpus,
            .guest_port = parsed.shared.guest_port,
            .timeout_ms = parsed.shared.timeout_ms,
            .capture_path = parsed.capture_path,
            .capture_trigger = parsed.capture_trigger,
            .continue_after_capture = parsed.continue_after_capture,
            .spore_executable = spore_executable,
            .debug = debug,
            .events = events,
        });
    }

    validateTerminalPolicy(parsed);

    if (parsed.capture_path != null and parsed.rootfs_path != null and parsed.image_ref == null) {
        failRunSetup("spore run: --rootfs with --capture is not portable yet; use --image so capture can record immutable rootfs identity", .{});
    }
    if (parsed.network_policy.bound_service_count > 1) {
        failRunSetup("spore run: --bind-service supports exactly one service for now", .{});
    }
    if (parsed.capture_path != null and parsed.network_policy.hasBoundServices()) {
        failRunSetup("spore run: --bind-service with --capture needs manifest support first", .{});
    }

    const command = run_mod.cliGuestCommand(allocator, parsed) catch |err| switch (err) {
        error.ShellCommandArgumentCountUnsupported => failRunSetup("spore run: shell command form accepts one command string; quote it or use -- for argv", .{}),
        else => return err,
    };

    return api.runManaged(init, allocator, .{
        .backend = parsed.backend,
        .kernel_path = parsed.shared.kernel_path,
        .initrd_path = parsed.shared.initrd_path,
        .rootfs_path = parsed.rootfs_path,
        .image_ref = parsed.image_ref,
        .image_pull_policy = parsed.pull_policy,
        .command = command,
        .interactive = parsed.interactive,
        .tty = parsed.tty,
        .memory = parsed.shared.memory,
        .vcpus = parsed.shared.vcpus,
        .guest_port = parsed.shared.guest_port,
        .timeout_ms = parsed.shared.timeout_ms,
        .capture_path = parsed.capture_path,
        .capture_trigger = parsed.capture_trigger,
        .continue_after_capture = parsed.continue_after_capture,
        .network = parsed.network,
        .network_policy = parsed.network_policy,
        .spore_executable = spore_executable,
        .debug = debug,
        .events = events,
    });
}

const RawOutputSink = struct {
    fn sink(self: *RawOutputSink) api.EventSink {
        return .{ .context = self, .emitFn = emit };
    }

    fn emit(context: ?*anyopaque, event: api.RunEvent) !void {
        _ = context;
        switch (event) {
            .stdout => |output| fd_util.writeAllBestEffort(1, output.bytes),
            .stderr => |output| fd_util.writeAllBestEffort(2, output.bytes),
            .terminal => |output| fd_util.writeAllBestEffort(1, output.bytes),
            else => {},
        }
    }
};

fn validateTerminalPolicy(parsed: run_mod.CliOptions) void {
    if (!parsed.tty) return;
    if (parsed.event_mode == .none and std.c.isatty(1) == 0) {
        failRunSetup("spore run: -t requires stdout to be a terminal unless --events=jsonl is used", .{});
    }
    if (parsed.interactive and std.c.isatty(0) == 0) {
        failRunSetup("spore run: -it requires stdin to be a terminal", .{});
    }
}

fn writeStderr(bytes: []const u8) void {
    fd_util.writeAllBestEffort(2, bytes);
}

fn failRunSetup(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(2);
}

fn runtimeDebugEnabled(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--debug")) return true;
    }
    return false;
}

test "attach args adapt to commandless run from" {
    const args = try attachRunArgs(std.testing.allocator, &.{ "--backend", "hvf", "-it", "--events=jsonl", "live.spore" });
    defer std.testing.allocator.free(args);

    try std.testing.expectEqual(@as(usize, 6), args.len);
    try std.testing.expectEqualStrings("--from", args[0]);
    try std.testing.expectEqualStrings("live.spore", args[1]);
    try std.testing.expectEqualStrings("--backend", args[2]);
    try std.testing.expectEqualStrings("hvf", args[3]);
    try std.testing.expectEqualStrings("-it", args[4]);
    try std.testing.expectEqualStrings("--events=jsonl", args[5]);

    const parsed = try run_mod.parseCliArgs(args);
    try std.testing.expectEqualStrings("live.spore", parsed.from_spore_dir.?);
    try std.testing.expect(parsed.interactive);
    try std.testing.expect(parsed.tty);
    try std.testing.expectEqual(run_mod.EventMode.jsonl, parsed.event_mode);
    try std.testing.expectEqual(@as(usize, 0), parsed.command.len);
}

test "attach args reject commands and separators" {
    try std.testing.expectError(error.UnexpectedArgument, attachRunArgs(std.testing.allocator, &.{ "live.spore", "echo hi" }));
    try std.testing.expectError(error.UnexpectedSeparator, attachRunArgs(std.testing.allocator, &.{ "--", "live.spore" }));
    try std.testing.expectError(error.MissingSporeDir, attachRunArgs(std.testing.allocator, &.{}));
}
