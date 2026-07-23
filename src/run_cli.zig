//! CLI adapters for `spore run`.
//!
//! This module owns argv parsing glue and stdout/stderr serialization. Runtime
//! behavior flows through `api.zig`.

const std = @import("std");
const Io = std.Io;

const api = @import("api.zig");
const fd_util = @import("fd.zig");
const generation = @import("generation.zig");
const run_mod = @import("run.zig");
const spore = @import("spore.zig");

var setup_event_writer: ?*run_mod.EventWriter = null;

pub fn cli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0 or wantsHelp(args)) {
        try stdout.writeAll(run_mod.cli_usage);
        return;
    }

    const arena = init.arena.allocator();
    var event_writer = run_mod.EventWriter.init(std.heap.page_allocator, stdout, "run");
    if (requestsJsonl(args)) setup_event_writer = &event_writer;
    defer setup_event_writer = null;
    const parsed = run_mod.parseCliArgs(args) catch |err| {
        if (setup_event_writer) |events| {
            const classified = api.classifyFailure(err);
            events.emitFailure(classified) catch {};
            std.process.exit(classified.exit_code);
        }
        return err;
    };
    try runParsedCli(init, arena, parsed, stdout);
}

fn runParsedCli(init: std.process.Init, arena: std.mem.Allocator, parsed: run_mod.CliOptions, stdout: *Io.Writer) !void {
    if (parsed.from_spore_dir) |spore_dir| {
        if (parsed.command.len == 0) {
            failRunSetup("spore run: --from runs a new command from a spore; use `spore attach {s}` to connect to a saved session", .{spore_dir});
        }
    }

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
            const classified = api.classifyFailure(err);
            event_writer.emitFailure(classified) catch {};
            std.process.exit(classified.exit_code);
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
        if (run_mod.isX86ProductPolicyError(err)) {
            const classified = api.classifyFailure(err);
            writeStderr(classified.message);
            writeStderr("\n");
            std.process.exit(classified.exit_code);
        }
        if (err == error.ImageCommandMissing or err == error.UnsupportedImageUser or err == error.RunArgCountUnsupported or err == error.RunArgTooLong) {
            const classified = api.classifyFailure(err);
            writeStderr(classified.message);
            writeStderr("\n");
            std.process.exit(classified.exit_code);
        }
        if (parsed.commit_ref != null) {
            const classified = api.classifyFailure(err);
            writeStderr(classified.message);
            writeStderr("\n");
            std.process.exit(classified.exit_code);
        }
        return err;
    };
    if (result.saved and parsed.event_mode != .jsonl) {
        if (result.save_path) |path| {
            const message = try std.fmt.allocPrint(arena, "spore run: saved spore at {s}\n", .{path});
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
    const injected_files = run_mod.readInjectedFileSources(init.io, allocator, parsed.injected_file_sources.slice()) catch |err| switch (err) {
        error.InjectedFileOpenFailed => failRunSetup("spore run: injected file setup failed", .{}),
        error.InjectedFileTooLarge => failRunSetup("spore run: injected files exceed 16MiB total", .{}),
        else => return err,
    };
    var env_diagnostic = run_mod.GuestEnvResolveDiagnostic{};
    const guest_env = run_mod.resolveCliGuestEnv(allocator, parsed.guest_env_specs.slice(), init.environ_map, &env_diagnostic) catch |err| switch (err) {
        error.MissingHostEnvironment => failRunSetup("spore run: --env {s} is not set in the host environment", .{env_diagnostic.missing_key orelse "unknown"}),
        error.RunEnvTooLong => failRunSetup("spore run: --env entry exceeds 255 bytes", .{}),
        error.RunEnvCountUnsupported => failRunSetup("spore run: too many --env entries", .{}),
        else => return err,
    };
    if (parsed.from_spore_dir) |spore_dir| {
        if (parsed.network_requested or parsed.network_policy.hasRules()) {
            failRunSetup("spore run: --from uses the saved network policy; omit --net and network flags", .{});
        }
        const command = if (parsed.command.len == 0)
            &.{}
        else
            run_mod.cliGuestCommand(allocator, parsed) catch |err| switch (err) {
                error.ShellCommandArgumentCountUnsupported => failRunSetup("spore run: shell command form accepts one command string; quote it or use -- for argv", .{}),
                else => return err,
            };
        if (parsed.tty and command.len != 0) {
            failRunSetup("spore run: -t with --from command execution is not supported yet; use `spore attach -t {s}` to connect to a saved terminal session", .{spore_dir});
        }
        validateTerminalPolicy(parsed);
        var binding_diagnostic = api.BoundServiceBindingDiagnostic{};
        return api.runFromSpore(.{
            .io = init.io,
            .environ_map = init.environ_map,
        }, allocator, .{
            .backend = parsed.backend,
            .spore_dir = spore_dir,
            .command = command,
            .attach_session_id = spore.default_session_id,
            .interactive = parsed.interactive,
            .tty = parsed.tty,
            .guest_env = guest_env,
            .vcpus = parsed.shared.vcpus,
            .guest_port = parsed.shared.guest_port,
            .timeout_ms = parsed.shared.timeout_ms,
            .save_path = parsed.save_path,
            .save_trigger = parsed.save_trigger,
            .continue_after_save = parsed.continue_after_save,
            .generation_path = parsed.generation_path,
            .spore_executable = spore_executable,
            .debug = debug,
            .bound_services = parsed.bound_services.slice(),
            .bound_service_diagnostic = &binding_diagnostic,
            .events = events,
        }) catch |err| switch (err) {
            error.MissingBoundServiceBinding => failRunSetup("spore run: manifest requires live bound Unix service binding '{s}'", .{binding_diagnostic.missing_name orelse "unknown"}),
            error.UnexpectedBoundServiceBinding => failRunSetup("spore run: live bound Unix service binding '{s}' does not match the manifest", .{binding_diagnostic.unexpected_name orelse "unknown"}),
            error.DuplicateBoundServiceBinding => failRunSetup("spore run: duplicate live bound Unix service binding '{s}'", .{binding_diagnostic.duplicate_name orelse "unknown"}),
            error.BadGenerationPayload => failRunSetup("spore run: invalid --generation payload; required JSON fields: run_id, child_id, parallel_index, parallel_count, fork_index, fork_count, fork_batch_id, vm_id", .{}),
            error.StreamTooLong => failRunSetup("spore run: --generation payload exceeds {d} bytes", .{generation.params_size}),
            error.GenerationReadFailed => failRunSetup("spore run: cannot read --generation {s}", .{parsed.generation_path orelse ""}),
            else => return err,
        };
    }

    validateTerminalPolicy(parsed);

    if (parsed.save_path != null and parsed.rootfs_path != null and parsed.image_ref == null) {
        failRunSetup("spore run: --rootfs with --save is not portable yet; use --image so save can record immutable rootfs identity", .{});
    }
    if (parsed.save_path != null and parsed.network_policy.hasBoundServices()) {
        failRunSetup("spore run: --bind-service with --save needs manifest support first", .{});
    }

    const command: []const []const u8 = if (parsed.command.len == 0)
        &.{}
    else
        run_mod.cliGuestCommand(allocator, parsed) catch |err| switch (err) {
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
        .image_entrypoint = if (parsed.image_entrypoint) |entrypoint| &.{entrypoint} else null,
        .command = command,
        .guest_env = guest_env,
        .injected_files = injected_files,
        .interactive = parsed.interactive,
        .tty = parsed.tty,
        .memory = parsed.shared.memory,
        .vcpus = parsed.shared.vcpus,
        .guest_port = parsed.shared.guest_port,
        .timeout_ms = parsed.shared.timeout_ms,
        .save_path = parsed.save_path,
        .save_trigger = parsed.save_trigger,
        .continue_after_save = parsed.continue_after_save,
        .commit_ref = parsed.commit_ref,
        .disk_size = parsed.disk_size,
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
            .image_commit => |commit| std.debug.print(
                "spore run: committed image {s}\n  resolved: {s}\n  rootfs index: {s}\n",
                .{ commit.ref, commit.resolved_image_ref, commit.rootfs_index_digest },
            ),
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
    if (setup_event_writer) |events| {
        const message = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch "spore run: setup failed";
        const classified = run_mod.ClassifiedFailure.init(.usage_invalid_argument, message, "run");
        events.emitFailure(classified) catch {};
        events.writer.flush() catch {};
        std.process.exit(classified.exit_code);
    }
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(2);
}

fn requestsJsonl(args: []const []const u8) bool {
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--events=jsonl")) return true;
        if (std.mem.eql(u8, arg, "--events") and i + 1 < args.len and std.mem.eql(u8, args[i + 1], "jsonl")) return true;
    }
    return false;
}

fn runtimeDebugEnabled(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--debug")) return true;
    }
    return false;
}

fn wantsHelp(args: []const []const u8) bool {
    if (args.len == 1 and std.mem.eql(u8, args[0], "help")) return true;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) return false;
        if (std.mem.eql(u8, arg, "-h") or
            std.mem.eql(u8, arg, "--help"))
        {
            return true;
        }
    }
    return false;
}

test "run cli help accepts help before argv delimiter only" {
    try std.testing.expect(wantsHelp(&.{"--help"}));
    try std.testing.expect(wantsHelp(&.{ "--image", "alpine", "--help" }));
    try std.testing.expect(!wantsHelp(&.{ "help", "--image", "alpine" }));
    try std.testing.expect(!wantsHelp(&.{ "--", "/bin/true", "--help" }));
    try std.testing.expect(std.mem.indexOf(u8, run_mod.cli_usage, "spore run --save base.spore --save-on TERM") != null);
    try std.testing.expect(std.mem.indexOf(u8, run_mod.cli_usage, "Uses spore memory/device sizing; omit --memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, run_mod.cli_usage, "--generation FILE") != null);
}
