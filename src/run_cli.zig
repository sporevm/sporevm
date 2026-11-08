//! CLI adapters for `spore run`.
//!
//! This module owns argv parsing glue and stdout/stderr serialization. Runtime
//! behavior flows through `api.zig`.

const std = @import("std");
const Io = std.Io;

const api = @import("api.zig");
const Ctx = @import("cli.zig").Ctx;
const boot_assets = @import("boot_assets.zig");
const fd_util = @import("fd.zig");
const generation = @import("generation.zig");
const local_paths = @import("local_paths.zig");
const guest_request = @import("guest_request.zig");
const events_mod = @import("events.zig");
const machine_output = @import("machine_output.zig");
const run_mod = @import("run.zig");
const spore = @import("spore.zig");
const vm_session = @import("vm_session.zig");

pub fn cli(ctx: *const Ctx, args: []const []const u8) !void {
    const init = ctx.init;
    const stdout = ctx.stdout;
    const arena = init.arena.allocator();
    var event_writer = events_mod.EventWriter.init(std.heap.page_allocator, stdout, "run");
    if (ctx.mode == .json) run_mod.cli_setup_events = event_writer.sink();
    defer run_mod.cli_setup_events = null;
    const parsed = try run_mod.parseCliArgs(arena, args);
    if (ctx.mode == .human) if (parsed.save_path) |path| switch (parsed.save_trigger) {
        .signal => |signal| if (signal == .INT) {
            try ctx.stderr.print("Ctrl-C saves to {s} and {s}; it does not cancel. Send SIGTERM to cancel.\n", .{ path, if (parsed.continue_after_save) "keeps running" else "stops" });
            try ctx.stderr.flush();
        },
        .exit => {},
    };
    try runParsedCli(init, arena, parsed, stdout, if (ctx.mode == .json) &event_writer else null, ctx.debug);
}

/// `json_events` is set under global `--json`: the run prints events there
/// instead of the guest's raw output.
fn runParsedCli(init: std.process.Init, arena: std.mem.Allocator, parsed: run_mod.CliOptions, stdout: *Io.Writer, json_events: ?*events_mod.EventWriter, debug: bool) !void {
    if (parsed.from_spore_dir) |spore_dir| {
        if (parsed.command.len == 0) {
            failRunSetup("spore run: --checkpoint runs a new command from a spore; use `spore checkpoint resume {s}` to connect to a saved session", .{spore_dir});
        }
    }

    var raw_output = RawOutputSink{};
    const events: api.EventSink = if (json_events) |writer| writer.sink() else raw_output.sink();

    try vm_session.openConsoleLog(parsed.shared.console_log_path);
    defer vm_session.closeConsoleLog();

    const spore_executable = try std.process.executablePathAlloc(init.io, arena);
    const result = runParsed(init, arena, parsed, events, json_events != null, spore_executable, debug) catch |err| {
        const classified = api.classifyFailure(err);
        if (json_events) |writer| {
            writer.emitFailure(classified) catch {};
            std.process.exit(classified.exit_code);
        }
        return err;
    };
    if (result.saved and json_events == null) {
        if (result.save_path) |path| {
            const message = try std.fmt.allocPrint(arena, "spore run: saved checkpoint at {s} ({s})\n", .{ path, result.save_ownership orelse "unknown ownership" });
            writeStderr(message);
            if (std.mem.eql(u8, result.save_ownership orelse "", "machine-local-pinned"))
                writeStderr("Cache-pinned directory; do not copy standalone. Transfer with checkpoint push/pull.\n");
        }
    }
    if (json_events != null) {
        try stdout.flush();
    }
    const code = result.processExitCode();
    if (code != 0) std.process.exit(code);
}

fn runParsed(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    parsed: run_mod.CliOptions,
    events: api.EventSink,
    json: bool,
    spore_executable: []const u8,
    debug: bool,
) !api.RunResult {
    const injected_files = boot_assets.readInjectedFileSources(init.io, allocator, parsed.injected_file_sources.slice()) catch |err| switch (err) {
        error.InjectedFileOpenFailed => failRunSetup("spore run: injected file setup failed", .{}),
        error.InjectedFileTooLarge => failRunSetup("spore run: injected files exceed 16MiB total", .{}),
        else => return err,
    };
    const save_path = if (parsed.save_path) |path| try local_paths.absolutePathAlloc(init.io, allocator, path) else null;
    var env_diagnostic = guest_request.GuestEnvResolveDiagnostic{};
    const guest_env = guest_request.resolveCliGuestEnv(allocator, parsed.guest_env_specs.slice(), init.environ_map, &env_diagnostic) catch |err| switch (err) {
        error.MissingHostEnvironment => failRunSetup("spore run: --env {s} is not set in the host environment", .{env_diagnostic.missing_key orelse "unknown"}),
        error.RunEnvTooLong => failRunSetup("spore run: --env entry exceeds 255 bytes", .{}),
        error.RunEnvCountUnsupported => failRunSetup("spore run: too many --env entries", .{}),
        else => return err,
    };
    if (parsed.from_spore_dir) |spore_dir| {
        if (parsed.network != .disabled) {
            failRunSetup("spore run: --checkpoint uses the saved network policy; omit --net and network flags", .{});
        }
        const command = if (parsed.command.len == 0)
            &.{}
        else
            run_mod.cliGuestCommand(allocator, parsed) catch |err| switch (err) {
                error.ShellCommandArgumentCountUnsupported => failRunSetup("spore run: shell command form accepts one command string; quote it or use -- for argv", .{}),
                else => return err,
            };
        if (parsed.tty and command.len != 0) {
            failRunSetup("spore run: -t with --checkpoint command execution is not supported yet; use `spore checkpoint resume -t {s}` to connect to a saved terminal session", .{spore_dir});
        }
        validateTerminalPolicy(parsed, json);
        var binding_diagnostic = api.BoundServiceBindingDiagnostic{};
        return api.runFromSpore(.{
            .io = init.io,
            .environ_map = init.environ_map,
        }, allocator, .{
            .backend = parsed.backend,
            .spore_dir = spore_dir,
            .command = command,
            .interactive = parsed.interactive,
            .tty = parsed.tty,
            .guest_env = guest_env,
            .vcpus = parsed.shared.vcpus,
            .guest_port = parsed.shared.guest_port,
            .timeout_ms = parsed.shared.timeout_ms,
            .save_path = save_path,
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

    validateTerminalPolicy(parsed, json);

    if (parsed.save_path != null and parsed.rootfs_path != null and parsed.image_ref == null) {
        failRunSetup("spore run: --rootfs with --save-checkpoint is not portable yet; use --image so save can record immutable rootfs identity", .{});
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
        .save_path = save_path,
        .save_trigger = parsed.save_trigger,
        .continue_after_save = parsed.continue_after_save,
        .commit_ref = parsed.commit_ref,
        .disk_size = parsed.disk_size,
        .network = parsed.network,
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

fn validateTerminalPolicy(parsed: run_mod.CliOptions, json: bool) void {
    if (!parsed.tty) return;
    if (!json and std.c.isatty(1) == 0) {
        failRunSetup("spore run: -t requires stdout to be a terminal unless --json is used", .{});
    }
    if (parsed.interactive and std.c.isatty(0) == 0) {
        failRunSetup("spore run: -it requires stdin to be a terminal", .{});
    }
}

fn writeStderr(bytes: []const u8) void {
    fd_util.writeAllBestEffort(2, bytes);
}

const failRunSetup = run_mod.failCliSetup;
