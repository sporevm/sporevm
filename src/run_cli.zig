//! CLI adapter for `spore run`.
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
