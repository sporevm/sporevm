//! Named VM lifecycle commands: usage text, argument and options-file
//! parsing, terminal and copy streaming, and human and JSON output. The
//! orchestration they call is in lifecycle.zig.

const std = @import("std");
const Ctx = @import("cli.zig").Ctx;
const TestDir = @import("test_dir.zig").TestDir;
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;

const Context = @import("context.zig").Context;
const attach_stream = @import("attach_stream.zig");
const generation = @import("generation.zig");
const lifecycle = @import("lifecycle.zig");
const machine_output = @import("machine_output.zig");
const memory_config = @import("memory.zig");
const monitor_protocol = @import("monitor_protocol.zig");
const ExecNamedStream = monitor_protocol.ExecNamedStream;
const named_copy_archive = @import("named_copy_archive.zig");
const guest_request = @import("guest_request.zig");
const rootfs_input = @import("rootfs_input.zig");
const backend_mod = @import("backend.zig");
const cli_args = @import("cli_args.zig");
const events_mod = @import("events.zig");
const runtime_disk_claim = @import("runtime_disk_claim.zig");
const saved_spore_ownership = @import("saved_spore_ownership.zig");
const spore = @import("spore.zig");
const spore_net_policy = @import("spore_net_policy.zig");
const spore_stream = @import("spore_stream.zig");
const topology = @import("topology.zig");
const version = @import("version.zig");
const vm_registry = @import("vm_registry.zig");

const max_metadata_bytes = vm_registry.max_metadata_bytes;
const runtime_dir_env = lifecycle.runtime_dir_env;
const Spec = lifecycle.Spec;
const validateName = lifecycle.validateName;
const lastErrorMessage = lifecycle.lastErrorMessage;
const monotonicMs = lifecycle.monotonicMs;
const CopyDirection = lifecycle.CopyDirection;
const CopyNamedOptions = lifecycle.CopyNamedOptions;
const ExecNamedStreamOptions = lifecycle.ExecNamedStreamOptions;
const InitialOutputDisposition = lifecycle.InitialOutputDisposition;
const ListEntry = lifecycle.ListEntry;
const ListMemory = lifecycle.ListMemory;
const ListStats = lifecycle.ListStats;
const NamedForkResult = lifecycle.NamedForkResult;
const NamedLifecycleResult = lifecycle.NamedLifecycleResult;
const NamedListResult = lifecycle.NamedListResult;
const initial_output_limit_bytes_per_stream = lifecycle.initial_output_limit_bytes_per_stream;
const createNamedWithTiming = lifecycle.createNamedWithTiming;
const restoreNamed = lifecycle.restoreNamed;
const openExecNamedStream = lifecycle.openExecNamedStream;
const initialOutputNamed = lifecycle.initialOutputNamed;
const saveNamed = lifecycle.saveNamed;
const forkNamed = lifecycle.forkNamed;
const removeNamed = lifecycle.removeNamed;
const listNamed = lifecycle.listNamed;
const freeListEntries = lifecycle.freeListEntries;
const deinitNamedLifecycleResult = lifecycle.deinitNamedLifecycleResult;
const deinitNamedForkResult = lifecycle.deinitNamedForkResult;
const rejectX86NamedCopy = lifecycle.rejectX86NamedCopy;
const monitorRequestFailed = lifecycle.monitorRequestFailed;
const listMemoryFromConfig = lifecycle.listMemoryFromConfig;
const listStatsFromMemory = lifecycle.listStatsFromMemory;

pub const create_usage =
    \\Usage:
    \\  spore vm create NAME --image REF [options]
    \\  spore vm create NAME [options] --shell 'command'
    \\  spore vm create NAME [options] -- <argv...>
    \\
    \\Options:
    \\  --backend auto|hvf|kvm  Backend to run (default: auto)
    \\  --kernel Image          Kernel Image path
    \\  --initrd root.cpio      Initrd path (default: embedded minimal exec initrd)
    \\  --rootfs rootfs.ext4    Attach rootfs image read-only as virtio-blk
    \\  --image REF             Build or reuse cached OCI rootfs; default to Entrypoint + Cmd
    \\  --options @file.json    Read create options from a JSON file
    \\  --pull=missing|always|never
    \\                          Pull policy for mutable --image refs (default: missing)
    \\  --net                   Experimental SporeVM-managed networking
    \\  --allow-cidr CIDR       With --net, restrict public egress to this CIDR
    \\  --allow-host HOST       With --net, restrict public egress to DNS A answers for this host
    \\  --allow-host-port HOST:PORT
    \\                          With --net, restrict public egress to this exact host and port
    \\  --bind-service NAME[:PORT]=unix:/path.sock
    \\                          With --net, declare a guest-local Unix service
    \\  --forward 127.0.0.1:HOST_PORT:GUEST_PORT
    \\                          With --net, forward host loopback TCP to a guest port
    \\  --annotation KEY=VALUE  Add a create-time annotation to saved manifests
    \\  --memory SIZE           Initial guest memory (default: 512mb)
    \\  --max-memory SIZE       Elastic memory ceiling (default: same as --memory)
    \\  --vcpus N               Guest vCPU count (1-8; backend-dependent)
    \\  --guest-port N          Guest vsock listen port (default: 10700)
    \\  --timeout DURATION      Exec timeout (default: 30s; e.g. 500ms, 1m)
    \\  --console-log PATH      Write guest console output, and, in a VM this command boots, a copy of command output, to PATH
    \\  --initial-output MODE   retain or discard initial-command output (default: retain)
    \\  --shell STRING          Run /bin/sh -lc STRING instead of exact argv
    \\  -- <argv...>            Start exact argv instead of /bin/sh -lc
    \\  -h, --help              Show this help
    \\
;

pub const logs_usage =
    \\Usage:
    \\  spore vm logs NAME --initial
    \\
    \\Print an initial-command snapshot (16,381 bytes per stream, with truncation
    \\reported). This is not execution history or --follow; later exec output
    \\belongs to its caller.
    \\The named VM monitor must be idle while the snapshot is retrieved.
    \\
    \\Options:
    \\  -h, --help              Show this help
    \\
;

pub const exec_usage =
    \\Usage:
    \\  spore vm exec NAME [options] --shell 'command'
    \\  spore vm exec [options] NAME -- <argv...>
    \\
    \\Options:
    \\  --env KEY[=VALUE]       Override image environment; KEY copies the host value
    \\  --workdir PATH          Override the image working directory
    \\  --shell STRING          Run /bin/sh -lc STRING instead of exact argv
    \\  -i, --interactive       Keep stdin open and forward it to the guest process
    \\  -t, --tty               Allocate a guest terminal for the process
    \\  -- <argv...>            Run exact argv instead of /bin/sh -lc
    \\  -h, --help              Show this help
    \\
    \\Options may precede or follow NAME, but must precede --. Everything after
    \\-- is guest argv. The command inherits the VM's --timeout; there is no
    \\per-exec override. On timeout the exec stream fails; the named VM remains.
    \\
;

pub const copy_in_usage =
    \\Usage:
    \\  spore vm copy-in NAME HOST_PATH GUEST_PATH
    \\
    \\Copies one host file or directory into a running named VM. The guest path
    \\must be absolute and must not already exist.
    \\
;

pub const copy_out_usage =
    \\Usage:
    \\  spore vm copy-out NAME GUEST_PATH HOST_PATH
    \\
    \\Copies one guest file or directory out of a running named VM. The host path must
    \\not already exist.
    \\
;

pub const rm_usage =
    \\Usage:
    \\  spore vm rm NAME
    \\
    \\Stops the named VM's monitor and deletes only its runtime state.
    \\Checkpoints and images are kept.
    \\
    \\Options:
    \\  -h, --help              Show this help
    \\
;

pub const save_usage =
    \\Usage:
    \\  spore vm save NAME --output DIR [--stop]
    \\
    \\Options:
    \\  --output DIR              Write a spore to DIR
    \\  --stop                 Stop and remove the named VM after saving
    \\  --annotation KEY=VALUE Merge an annotation into the spore manifest
    \\  -h, --help             Show this help
    \\
    \\By default save is non-destructive: the named VM keeps running. Use
    \\--stop when you want a consuming save that removes the named VM.
    \\
;

pub const fork_usage =
    \\Usage:
    \\  spore vm fork NAME --count N --name-prefix PREFIX [--allow-slow-copy]
    \\
    \\Options:
    \\  --count N             Number of children to create
    \\  --name-prefix PREFIX  Child names PREFIX-0 through PREFIX-(N-1)
    \\  --allow-slow-copy     Permit a full overlay copy when native cloning is unavailable
    \\  -h, --help            Show this help
    \\
    \\Live VM fork supports one writable rootfs disk; networked VMs remain unsupported.
    \\
;

pub const restore_usage =
    \\Usage:
    \\  spore vm restore NAME --checkpoint DIR
    \\
    \\Options:
    \\  --backend auto|hvf|kvm  Backend to run (default: saved lifecycle metadata)
    \\  --generation FILE       Inject fan-out identity JSON before restore
    \\  --checkpoint DIR       Saved machine state; does not attach saved streams
    \\  --bind-service NAME=unix:/path.sock
    \\                         Bind a manifest-declared service to a host socket
    \\  -h, --help             Show this help
    \\
;

pub const ls_usage =
    \\Usage:
    \\  spore vm ls
    \\
    \\Options:
    \\  -h, --help              Show this help
    \\
    \\Machine output:
    \\  spore --json vm ls      Emit the VM list as JSON
    \\
;

const CreateOptions = struct {
    spec: Spec,
    options_path: ?[]const u8 = null,
    image_pull_policy: rootfs_input.PullPolicy = .missing,
    initial_output: InitialOutputDisposition = .retain,
    network: spore_net_policy.Network = .disabled,
    command_mode: cli_args.CommandMode = .shell,
    command: []const []const u8 = &.{},
};

const CreateOptionsFile = struct {
    schema_version: u32 = 1,
    name: ?[]const u8 = null,
    backend: ?[]const u8 = null,
    kernel: ?[]const u8 = null,
    initrd: ?[]const u8 = null,
    rootfs: ?[]const u8 = null,
    image: ?[]const u8 = null,
    pull: ?[]const u8 = null,
    memory: ?[]const u8 = null,
    max_memory: ?[]const u8 = null,
    vcpus: ?topology.VcpuCount = null,
    guest_port: ?u32 = null,
    timeout_ms: ?u64 = null,
    console_log_path: ?[]const u8 = null,
    initial_output: ?InitialOutputDisposition = null,
    network: ?CreateOptionsFileNetwork = null,
    annotations: spore.Annotations = .{},
};

const CreateOptionsFileNetwork = struct {
    enabled: bool = false,
    allow_cidrs: []const []const u8 = &.{},
    allow_hosts: []const []const u8 = &.{},
    allow_host_ports: []const CreateOptionsFileNetworkRule = &.{},
    network_rules: []const CreateOptionsFileNetworkRule = &.{},
    bound_services: []const CreateOptionsFileBoundService = &.{},
};

const CreateOptionsFileNetworkRule = struct {
    host: []const u8,
    ports: []const u16,
};

const CreateOptionsFileBoundService = struct {
    name: []const u8,
    guest_host: ?[]const u8 = null,
    guest_port: u16 = 80,
    unix_path: []const u8,
};

const ExecOptions = struct {
    name: []const u8,
    command_mode: cli_args.CommandMode = .shell,
    command: []const []const u8,
    guest_env_specs: guest_request.GuestEnvSpecList = .{},
    guest_working_dir: ?[]const u8 = null,
    interactive: bool = false,
    tty: bool = false,
};

var exec_cli_event_writer: ?*events_mod.EventWriter = null;

const SaveOptions = struct {
    name: []const u8,
    out_dir: []const u8,
    stop: bool = false,
    annotations: spore.Annotations = .{},
};

const ForkOptions = struct {
    source_name: []const u8,
    count: usize,
    name_pattern: []const u8,
    allow_slow_copy: bool = false,
};

const RestoreOptions = struct {
    spore_dir: []const u8,
    name: []const u8,
    backend: ?backend_mod.Backend = null,
    generation_path: ?[]const u8 = null,
    bound_services: spore_net_policy.BoundServiceBindingList = .{},
};

pub fn createCli(ctx: *const Ctx, args: []const []const u8) !void {
    const init = ctx.init;
    const stdout = ctx.stdout;
    const stderr = ctx.stderr;
    const mode = ctx.mode;
    const start_ms = monotonicMs();
    if (args.len == 0) {
        exitLifecycleCliError(
            init.arena.allocator(),
            stderr,
            mode,
            machine_output.usageMissingArgument("usage: spore vm create NAME [options]", "create"),
            create_usage,
        );
    }

    const allocator = init.arena.allocator();
    var parsed = try parseCreateArgs(args, allocator, stderr, mode);
    parsed = try applyCreateOptionsFileLifecycleCli(init.io, allocator, stderr, mode, parsed);
    const parsed_ms = monotonicMs();
    const spec = parsed.spec;
    const caller_command: []const []const u8 = if (parsed.command.len == 0)
        &.{}
    else
        cli_args.cliGuestCommandFromMode(allocator, parsed.command_mode, parsed.command) catch |err| switch (err) {
            error.ShellCommandArgumentCountUnsupported => {
                const message = "spore vm create: shell command form accepts one command string; quote it or use -- for argv";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            },
            else => |e| return e,
        };
    const spore_executable = try std.process.executablePathAlloc(init.io, allocator);
    const result = createNamedWithTiming(init, allocator, .probe(), .{
        .name = spec.name,
        .backend = backend_mod.Backend.parse(spec.backend) orelse unreachable,
        .kernel_path = spec.kernel_path,
        .initrd_path = spec.initrd_path,
        .rootfs_path = spec.rootfs_path,
        .image_ref = spec.image_ref,
        .image_pull_policy = parsed.image_pull_policy,
        .initial_command = caller_command,
        .network = parsed.network,
        .memory = spec.memory,
        .vcpus = spec.vcpus,
        .guest_port = spec.guest_port,
        .timeout_ms = spec.timeout_ms,
        .console_log_path = spec.console_log_path,
        .initial_output = parsed.initial_output,
        .spore_executable = spore_executable,
        .debug = ctx.debug,
        .annotations = spec.annotations,
    }, .{
        .start_ms = start_ms,
        .parsed_ms = parsed_ms,
    }) catch |err| switch (err) {
        error.InvalidRuntimeDir, error.InsecureRuntimeDir, error.ControlSocketPathTooLong, error.ControlSocketPathCollision => exitLifecycleRuntimePathError(allocator, stderr, mode, "create", err),
        error.HostUnsupported => {
            const message = "spore vm create: monitor mode requires HVF on Apple Silicon or KVM on supported Linux hosts";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.host_unsupported, message, "create"), message);
        },
        error.NamedVmExists => {
            const fallback = allocLifecycleMessage(allocator, "spore vm create: VM already exists or has stale state: {s}", .{spec.name});
            const message = allocLifecycleLastErrorMessage(allocator, "create", fallback);
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
        },
        error.UnsupportedVcpuCount => {
            const message = "spore vm create: unsupported vCPU/backend combination";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
        },
        error.X86ExplicitMemoryRequired, error.X86ExperimentalMemorySizeUnsupported => {
            const message = "spore vm create: experimental x86-64 KVM supports only fixed 512 MiB memory";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, @errorName(err)), message);
        },
        error.X86VcpuCountUnsupported, error.X86DiskForkUnsupported => {
            const message = allocLifecycleMessage(allocator, "spore vm create: request is outside the fresh x86-64 KVM profile: {s}", .{@errorName(err)});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, @errorName(err)), message);
        },
        error.InvalidNetworkPolicy, error.InvalidRootfsInput, error.ImageCommandMissing, error.UnsupportedImageUser, error.RunArgCountUnsupported, error.RunArgTooLong, error.RunProgramEmpty => {
            const message = switch (err) {
                error.ImageCommandMissing => "spore vm create: image has no Entrypoint or Cmd; pass an initial command",
                error.UnsupportedImageUser => "spore vm create: image Config.User must select root (root, 0, root:root, or 0:0); guest credential switching is not supported yet",
                error.RunArgCountUnsupported => "spore vm create: effective image command has too many arguments (maximum 16)",
                error.RunArgTooLong => "spore vm create: effective image command contains an argument longer than 8191 bytes",
                error.RunProgramEmpty => "spore vm create: effective command has an empty program name",
                else => allocLifecycleMessage(allocator, "spore vm create: invalid configuration: {s}", .{@errorName(err)}),
            };
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
        },
        error.FileNotFound => {
            const message = "spore vm create: required rootfs object was not found";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_not_found, message, "create"), message);
        },
        error.MonitorReadyTimeout, error.MonitorExited => {
            const message = allocLifecycleLastErrorMessage(allocator, "create", "spore vm create: timed out waiting for monitor readiness");
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_start_failed, message, "create"), message);
        },
        error.MonitorVersionMismatch => {
            const message = allocLifecycleLastErrorMessage(allocator, "create", "spore vm create: monitor or helper version does not match this spore build");
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_start_failed, message, "create"), message);
        },
        error.NamedVmNotReady => {
            const fallback = allocLifecycleMessage(allocator, "spore vm create: VM is not ready after create: {s}", .{spec.name});
            const message = allocLifecycleLastErrorMessage(allocator, "create", fallback);
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "create"), message);
        },
        error.MonitorUnavailable, error.MonitorRequestFailed, error.BadMonitorResponse, error.InitialCommandFailed, error.InitialCommandRollbackFailed => {
            const fallback = allocLifecycleMessage(allocator, "spore vm create: initial command failed for VM {s}: {s}", .{ spec.name, @errorName(err) });
            const message = allocLifecycleLastErrorMessage(allocator, "create", fallback);
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_execution_failed, message, "create"), message);
        },
        else => |e| return e,
    };
    defer deinitNamedLifecycleResult(allocator, result);
    if (mode == .json) {
        try machine_output.writeJson(allocator, stdout, result);
    } else {
        try writeNamedLifecycleResult(stdout, result);
    }
}

pub fn logsCli(ctx: *const Ctx, args: []const []const u8) !void {
    const init = ctx.init;
    const stdout = ctx.stdout;
    const stderr = ctx.stderr;
    const mode = ctx.mode;
    const allocator = init.arena.allocator();
    if (args.len != 2 or (!std.mem.eql(u8, args[0], "--initial") and !std.mem.eql(u8, args[1], "--initial"))) {
        exitLifecycleCliError(
            allocator,
            stderr,
            mode,
            machine_output.usageMissingArgument("usage: spore vm logs NAME --initial (initial output only, not exec history)", "logs"),
            logs_usage,
        );
    }
    const name = args[if (std.mem.eql(u8, args[0], "--initial")) @as(usize, 1) else 0];
    validateNameLifecycleCli(allocator, stderr, mode, "logs", name);
    const result = initialOutputNamed(.{ .io = init.io, .environ_map = init.environ_map }, allocator, .{
        .name = name,
    }) catch |err| switch (err) {
        error.NamedVmNotFound => {
            const message = allocLifecycleMessage(allocator, "spore vm logs: VM not found: {s}", .{name});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_not_found, message, "logs"), message);
        },
        error.NamedVmNotReady => {
            const fallback = allocLifecycleMessage(allocator, "spore vm logs: VM is not ready: {s}", .{name});
            const message = allocLifecycleLastErrorMessage(allocator, "logs", fallback);
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "logs"), message);
        },
        error.InitialOutputUnavailable => {
            const fallback = allocLifecycleMessage(allocator, "spore vm logs: VM {s} has no retained initial-command output", .{name});
            const message = allocLifecycleLastErrorMessage(allocator, "logs", fallback);
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_not_found, message, "logs"), message);
        },
        error.MonitorUnavailable, error.MonitorRequestFailed, error.BadMonitorResponse => {
            const fallback = allocLifecycleMessage(allocator, "spore vm logs: could not retrieve initial-command output for VM {s}: {s}", .{ name, @errorName(err) });
            const message = allocLifecycleLastErrorMessage(allocator, "logs", fallback);
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_execution_failed, message, "logs"), message);
        },
        else => |e| return e,
    };
    defer deinitNamedLifecycleResult(allocator, result);
    if (mode == .json) {
        try machine_output.writeJson(allocator, stdout, result);
    } else {
        try writeInitialOutputResult(stdout, result);
    }
}

pub fn execCli(ctx: *const Ctx, args: []const []const u8) !void {
    const init = ctx.init;
    const stdout = ctx.stdout;
    const allocator = init.arena.allocator();
    var events = events_mod.EventWriter.init(std.heap.page_allocator, stdout, "exec");
    exec_cli_event_writer = if (ctx.mode == .json) &events else null;
    defer exec_cli_event_writer = null;
    const parsed = parseExecArgs(args);
    var env_diagnostic = guest_request.GuestEnvResolveDiagnostic{};
    const guest_env = guest_request.resolveCliGuestEnv(allocator, parsed.guest_env_specs.slice(), init.environ_map, &env_diagnostic) catch |err| switch (err) {
        error.MissingHostEnvironment => {
            const message = allocLifecycleMessage(allocator, "spore vm exec: --env {s} is not set in the host environment", .{env_diagnostic.missing_key orelse "unknown"});
            usageExit(message);
        },
        error.RunEnvTooLong => usageExit("spore vm exec: --env entry exceeds 255 bytes\n"),
        error.RunEnvCountUnsupported => usageExit("spore vm exec: too many --env entries\n"),
        else => return err,
    };
    const command = cli_args.cliGuestCommandFromMode(allocator, parsed.command_mode, parsed.command) catch |err| switch (err) {
        error.ShellCommandArgumentCountUnsupported => usageExit("spore vm exec: shell command form accepts one command string; quote it or use -- for argv\n"),
        else => return err,
    };
    if (ctx.mode == .json) return execCliEvents(init, allocator, parsed, command, guest_env, &events, stdout);
    const exit_code = execNamedStreaming(.{
        .io = init.io,
        .environ_map = init.environ_map,
    }, allocator, .{
        .name = parsed.name,
        .command = command,
        .guest_env = guest_env,
        .guest_working_dir = parsed.guest_working_dir,
        .interactive = parsed.interactive,
        .tty = parsed.tty,
        .terminal_size = attach_stream.terminalSizeOrDefault(attach_stream.terminalSizeFd()),
    }) catch |err| {
        const classified = events_mod.classifyFailure(err);
        const message = allocLifecycleLastErrorMessage(allocator, "exec", classified.message);
        exitLifecycleCliError(allocator, ctx.stderr, ctx.mode, machine_output.CliError.init(classified.code, message, classified.source), message);
    };
    if (exit_code != 0) std.process.exit(exit_code);
}

fn execCliEvents(init: std.process.Init, allocator: std.mem.Allocator, parsed: ExecOptions, command: []const []const u8, guest_env: []const []const u8, events: *events_mod.EventWriter, stdout: *Io.Writer) !void {
    try events.emitStart(.auto);
    if (parsed.interactive or parsed.tty) {
        const classified = machine_output.CliError.init(.usage_invalid_argument, "spore --json vm exec does not support interactive or TTY input", "exec");
        try events.emitFailure(classified);
        std.process.exit(classified.exit_code);
    }

    var stream = openExecNamedStream(.{
        .io = init.io,
        .environ_map = init.environ_map,
    }, allocator, .{
        .name = parsed.name,
        .command = command,
        .guest_env = guest_env,
        .guest_working_dir = parsed.guest_working_dir,
    }) catch |err| {
        const classified = events_mod.classifyFailure(err);
        const message = allocLifecycleLastErrorMessage(allocator, "exec", classified.message);
        try events.emitFailure(machine_output.CliError.init(classified.code, message, classified.source));
        std.process.exit(classified.exit_code);
    };
    defer stream.deinit();

    var exit_code: u8 = 0;
    while (true) {
        const event = stream.next() catch |err| {
            const classified = events_mod.classifyFailure(err);
            try events.emitFailure(classified);
            std.process.exit(classified.exit_code);
        };
        switch (event) {
            .stdout => |bytes| try events.emitOutput(.stdout, bytes),
            .stderr => |bytes| try events.emitOutput(.stderr, bytes),
            .terminal => |bytes| try events.emitOutput(.terminal, bytes),
            .exit => |code| {
                exit_code = code;
                try events.emitExecCompletion(code);
                break;
            },
            .err => |bytes| {
                const classified = machine_output.CliError.init(.runtime_execution_failed, bytes, "exec");
                try events.emitFailure(classified);
                std.process.exit(classified.exit_code);
            },
        }
    }
    try stdout.flush();
    if (exit_code != 0) std.process.exit(exit_code);
}

/// Guest diagnostics during a copy go to stderr, escaped. With --json they
/// are dropped so stderr carries at most the spore.error.v1 document.
fn copyGuestStderrFd(mode: machine_output.Mode) std.c.fd_t {
    return if (mode == .json) -1 else 2;
}

pub const CopyResult = struct {
    schema: []const u8 = "spore.copy.result.v1",
    schema_version: u32 = 1,
    direction: []const u8,
    name: []const u8,
    host_path: []const u8,
    guest_path: []const u8,
};

pub fn copyInCli(ctx: *const Ctx, args: []const []const u8) !void {
    const init = ctx.init;
    const stdout = ctx.stdout;
    const stderr = ctx.stderr;
    const mode = ctx.mode;
    const allocator = init.arena.allocator();
    if (args.len != 3) exitLifecycleCliError(allocator, stderr, mode, machine_output.usageMissingArgument(copy_in_usage, "copy-in"), copy_in_usage);
    validateNameLifecycleCli(allocator, stderr, mode, "copy-in", args[0]);
    const parsed = CopyNamedOptions{ .name = args[0], .host_path = args[1], .guest_path = args[2] };
    try rejectX86NamedCopy();

    var archive = named_copy_archive.createTempFromHostPath(allocator, init.io, parsed.host_path) catch |err| {
        const classified = machine_output.fromZigError(err);
        const message = allocLifecycleMessage(allocator, "spore vm copy-in: cannot archive host path {s}; check that it exists, is readable and contains supported file types", .{parsed.host_path});
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(classified.code, message, classified.source), message);
    };
    defer archive.deinit(init.io);

    const source_fd = try openHostFileRead(allocator, init.io, archive.path);
    defer _ = std.c.close(source_fd);

    const exit_code = copyNamedStreaming(.{
        .io = init.io,
        .environ_map = init.environ_map,
    }, allocator, parsed, .in, .{
        .input_fd = source_fd,
        // Guest stdout is dropped during copy-in, so there is no archive to cap.
        .archive_limit = std.math.maxInt(u64),
        .stderr_fd = copyGuestStderrFd(mode),
    }) catch |err| {
        archive.deinit(init.io);
        const classified = machine_output.fromZigError(err);
        const fallback = allocLifecycleMessage(allocator, "spore vm copy-in: VM {s}: {s}", .{ parsed.name, classified.message });
        const message = allocLifecycleLastErrorMessage(allocator, "copy-in", fallback);
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(classified.code, message, classified.source), message);
    };
    if (exit_code != 0) {
        archive.deinit(init.io);
        const message = "spore vm copy-in: guest copy operation failed";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_execution_failed, message, "copy-in"), message);
    }
    if (mode == .json) try machine_output.writeJson(allocator, stdout, CopyResult{
        .direction = "in",
        .name = parsed.name,
        .host_path = parsed.host_path,
        .guest_path = parsed.guest_path,
    });
}

pub fn copyOutCli(ctx: *const Ctx, args: []const []const u8) !void {
    const init = ctx.init;
    const stdout = ctx.stdout;
    const stderr = ctx.stderr;
    const mode = ctx.mode;
    const allocator = init.arena.allocator();
    if (args.len != 3) exitLifecycleCliError(allocator, stderr, mode, machine_output.usageMissingArgument(copy_out_usage, "copy-out"), copy_out_usage);
    validateNameLifecycleCli(allocator, stderr, mode, "copy-out", args[0]);
    const parsed = CopyNamedOptions{ .name = args[0], .guest_path = args[1], .host_path = args[2] };
    try rejectX86NamedCopy();

    var archive = try named_copy_archive.createTemp(allocator);
    defer archive.deinit(init.io);

    const archive_fd = try named_copy_archive.openHostFileCreate(allocator, archive.path);
    var archive_fd_open = true;
    defer {
        if (archive_fd_open) _ = std.c.close(archive_fd);
    }

    const exit_code = copyNamedStreaming(.{
        .io = init.io,
        .environ_map = init.environ_map,
    }, allocator, parsed, .out, .{
        .archive_fd = archive_fd,
        .stderr_fd = copyGuestStderrFd(mode),
    }) catch |err| {
        archive.deinit(init.io);
        const classified = machine_output.fromZigError(err);
        const fallback = if (err == error.CopyArchiveTooLarge)
            allocLifecycleMessage(allocator, "spore vm copy-out: guest archive exceeds the {d} GiB copy-out limit", .{named_copy_archive.max_archive_bytes >> 30})
        else
            allocLifecycleMessage(allocator, "spore vm copy-out: VM {s}: {s}", .{ parsed.name, classified.message });
        const message = allocLifecycleLastErrorMessage(allocator, "copy-out", fallback);
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(classified.code, message, classified.source), message);
    };
    _ = std.c.close(archive_fd);
    archive_fd_open = false;

    if (exit_code != 0) {
        archive.deinit(init.io);
        const message = "spore vm copy-out: guest copy operation failed";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_execution_failed, message, "copy-out"), message);
    }
    named_copy_archive.extractFile(allocator, init.io, archive.path, parsed.host_path) catch |err| {
        archive.deinit(init.io);
        const classified = machine_output.fromZigError(err);
        const message = allocLifecycleMessage(allocator, "spore vm copy-out: cannot write host path {s}; choose a new destination in a writable directory", .{parsed.host_path});
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(classified.code, message, classified.source), message);
    };
    if (mode == .json) try machine_output.writeJson(allocator, stdout, CopyResult{
        .direction = "out",
        .name = parsed.name,
        .host_path = parsed.host_path,
        .guest_path = parsed.guest_path,
    });
}

pub fn rmCli(ctx: *const Ctx, args: []const []const u8) !void {
    const init = ctx.init;
    const stdout = ctx.stdout;
    const stderr = ctx.stderr;
    const mode = ctx.mode;
    const allocator = init.arena.allocator();
    const name = parseRmArgs(args, allocator, stderr, mode);
    const result = removeNamed(.{
        .io = init.io,
        .environ_map = init.environ_map,
    }, allocator, .{ .name = name }) catch |err| switch (err) {
        error.InvalidRuntimeDir, error.InsecureRuntimeDir => exitLifecycleRuntimePathError(allocator, stderr, mode, "rm", err),
        error.NamedVmNotFound => {
            const message = allocLifecycleMessage(allocator, "spore vm rm: live VM not found: {s}", .{name});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_not_found, message, "rm"), message);
        },
        error.NamedVmBusy => {
            const fallback = allocLifecycleMessage(allocator, "spore vm rm: live VM is still starting: {s}", .{name});
            const message = allocLifecycleLastErrorMessage(allocator, "rm", fallback);
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "rm"), message);
        },
        error.MonitorShutdownTimedOut => {
            const fallback = allocLifecycleMessage(allocator, "spore vm rm: timed out stopping live VM monitor before deleting runtime state: {s}", .{name});
            const message = allocLifecycleLastErrorMessage(allocator, "rm", fallback);
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_execution_failed, message, "rm"), message);
        },
        else => |e| return e,
    };
    defer deinitNamedLifecycleResult(allocator, result);
    if (mode == .json) {
        try machine_output.writeJson(allocator, stdout, result);
    } else {
        try writeNamedLifecycleResult(stdout, result);
    }
}

pub fn saveCli(ctx: *const Ctx, args: []const []const u8) !void {
    const init = ctx.init;
    const stdout = ctx.stdout;
    const stderr = ctx.stderr;
    const mode = ctx.mode;
    const allocator = init.arena.allocator();
    const parsed = parseSaveArgs(args, allocator, stderr, mode);
    const context = Context{ .io = init.io, .environ_map = init.environ_map };
    const result = saveNamed(context, allocator, .{
        .name = parsed.name,
        .out_dir = parsed.out_dir,
        .stop = parsed.stop,
        .annotations = parsed.annotations,
    }) catch |err| switch (err) {
        error.InvalidRuntimeDir, error.InsecureRuntimeDir, error.ControlSocketPathTooLong => exitLifecycleRuntimePathError(allocator, stderr, mode, "save", err),
        error.NamedVmNotReady => {
            const fallback = allocLifecycleMessage(allocator, "spore vm save: VM is not ready: {s}", .{parsed.name});
            const message = allocLifecycleLastErrorMessage(allocator, "save", fallback);
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "save"), message);
        },
        error.UnsupportedSnapshotMode => {
            const message = "spore vm save: this save mode is not supported; use `spore vm save NAME --output DIR --stop` for a consuming save";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "save"), message);
        },
        error.X86CaptureUnsupported => {
            const message = "spore vm save: x86-64 KVM capture is unavailable; the named VM remains running";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, @errorName(err)), message);
        },
        error.OutputDirExists => {
            const message = allocLifecycleMessage(allocator, "spore vm save: output directory already exists: {s}; choose a new --output DIR", .{parsed.out_dir});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "save"), message);
        },
        error.CrossDeviceOwnershipLink => {
            const message = "spore vm save: a machine-local pinned save must be on the rootfs cache's filesystem; choose --output DIR there";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, @errorName(err)), message);
        },
        error.InvalidOutputDir => {
            const message = allocLifecycleMessage(allocator, "spore vm save: invalid --output directory: {s}; the parent directory must exist", .{parsed.out_dir});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "save"), message);
        },
        error.MissingRootfsIdentity => {
            const message = "spore vm save: disk-backed lifecycle save requires recorded immutable rootfs identity";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "save"), message);
        },
        error.ImageStoreIncomplete => {
            const fallback = allocLifecycleMessage(allocator, "spore vm save: VM {s} was not saved: its image store could not supply every object; the VM keeps running", .{parsed.name});
            const message = allocLifecycleLastErrorMessage(allocator, "save", fallback);
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_execution_failed, message, @errorName(err)), message);
        },
        error.MonitorUnavailable, error.MonitorRequestFailed, error.MonitorVersionMismatch, error.MonitorShutdownTimedOut => {
            const fallback = switch (err) {
                error.MonitorUnavailable => allocLifecycleMessage(allocator, "spore vm save: monitor is unavailable for VM: {s}", .{parsed.name}),
                error.MonitorShutdownTimedOut => allocLifecycleMessage(allocator, "spore vm save: timed out waiting for monitor cleanup: {s}", .{parsed.name}),
                else => allocLifecycleMessage(allocator, "spore vm save: monitor request failed for VM {s}: {s}", .{ parsed.name, @errorName(err) }),
            };
            const message = allocLifecycleLastErrorMessage(allocator, "save", fallback);
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_execution_failed, message, "save"), message);
        },
        else => |e| return e,
    };
    defer deinitNamedLifecycleResult(allocator, result);
    if (mode == .json) {
        try machine_output.writeJson(allocator, stdout, result);
    } else {
        try writeNamedLifecycleResult(stdout, result);
    }
}

pub fn forkCli(ctx: *const Ctx, args: []const []const u8) !void {
    const init = ctx.init;
    const stdout = ctx.stdout;
    const stderr = ctx.stderr;
    const mode = ctx.mode;

    const allocator = init.arena.allocator();
    const parsed = parseForkArgs(args, allocator, stderr, mode);
    const spore_executable = try std.process.executablePathAlloc(init.io, allocator);
    const result = forkNamed(init, allocator, .{
        .source_name = parsed.source_name,
        .count = parsed.count,
        .name_pattern = parsed.name_pattern,
        .allow_slow_copy = parsed.allow_slow_copy,
        .spore_executable = spore_executable,
        .debug = ctx.debug,
    }) catch |err| switch (err) {
        error.InvalidRuntimeDir, error.InsecureRuntimeDir, error.ControlSocketPathTooLong, error.ControlSocketPathCollision => exitLifecycleRuntimePathError(allocator, stderr, mode, "fork", err),
        error.InvalidForkNamePattern => {
            const message = "spore vm fork: --name must contain at most one %d or %0Nd placeholder";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.MissingForkNamePlaceholder => {
            const message = "spore vm fork: --name must contain %d when --count is greater than 1";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.InvalidVMName => {
            const message = "spore vm fork: rendered VM name is invalid";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.DuplicateForkName => {
            const message = "spore vm fork: duplicate rendered VM name";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.NamedVmNotReady => {
            const fallback = allocLifecycleMessage(allocator, "spore vm fork: VM is not ready: {s}", .{parsed.source_name});
            const message = allocLifecycleLastErrorMessage(allocator, "fork", fallback);
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "fork"), message);
        },
        error.UnsupportedNamedForkDisk => {
            const message = "spore vm fork: source does not have the supported single writable rootfs disk shape";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.UnsupportedNamedForkNetwork => {
            const message = "spore vm fork: networked named live fork is not supported yet";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.UnsupportedNamedForkVcpu => {
            const message = allocLifecycleLastErrorMessage(allocator, "fork", "spore vm fork: source uses a fork topology or GIC state this backend cannot mint safely yet");
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.X86CaptureUnsupported => {
            const message = "spore vm fork: capture is unavailable for the experimental x86-64 KVM fresh profile";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "X86CaptureUnsupported"), message);
        },
        error.NamedVmExists => {
            const message = allocLifecycleLastErrorMessage(allocator, "fork", "spore vm fork: VM already exists or has stale state");
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.MonitorUnavailable, error.MonitorRequestFailed, error.BadMonitorResponse => {
            // A refused request carries the monitor's reason.
            const detail = lastErrorMessage();
            const reason = if (err == error.MonitorRequestFailed and detail.len != 0) detail else @errorName(err);
            const message = allocLifecycleMessage(allocator, "spore vm fork: monitor request failed for VM {s}: {s}", .{ parsed.source_name, reason });
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_execution_failed, message, "fork"), message);
        },
        error.FastForkUnavailable => {
            const message = "spore vm fork: native disk cloning is unavailable; retry with --allow-slow-copy to permit a full overlay copy";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_execution_failed, message, "fork"), message);
        },
        error.DiskForkBaselineUnavailable => {
            const message = "spore vm fork: the source disk baseline is no longer complete in its bound store";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "fork"), message);
        },
        error.MonitorReadyTimeout, error.MonitorExited, error.MonitorVersionMismatch => {
            const message = allocLifecycleLastErrorMessage(allocator, "fork", "spore vm fork: timed out waiting for monitor readiness");
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_start_failed, message, "fork"), message);
        },
        else => |e| return e,
    };
    defer deinitNamedForkResult(allocator, result);
    if (mode == .json) {
        try machine_output.writeJson(allocator, stdout, result);
    } else {
        try writeNamedForkResult(stdout, result);
    }
}

pub fn restoreCli(ctx: *const Ctx, args: []const []const u8) !void {
    const init = ctx.init;
    const stdout = ctx.stdout;
    const stderr = ctx.stderr;
    const mode = ctx.mode;
    const allocator = init.arena.allocator();
    const parsed = parseRestoreArgs(args, allocator, stderr, mode);
    const spore_executable = try std.process.executablePathAlloc(init.io, allocator);
    const result = restoreNamed(init, allocator, .{
        .spore_dir = parsed.spore_dir,
        .name = parsed.name,
        .backend = parsed.backend,
        .generation_path = parsed.generation_path,
        .spore_executable = spore_executable,
        .debug = ctx.debug,
        .bound_services = parsed.bound_services.slice(),
    }) catch |err| {
        switch (err) {
            error.BadGenerationPayload => {
                const message = "spore vm restore: invalid --generation payload; required JSON fields: run_id, child_id, parallel_index, parallel_count, fork_index, fork_count, fork_batch_id, vm_id";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "restore"), message);
            },
            error.GenerationPayloadTooLarge => {
                const message = allocLifecycleMessage(allocator, "spore vm restore: --generation payload exceeds {d} bytes", .{generation.params_size});
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "restore"), message);
            },
            error.GenerationFileNotFound, error.GenerationFileInvalid => {
                const message = allocLifecycleMessage(allocator, "spore vm restore: cannot read --generation {s}: {s}", .{ parsed.generation_path orelse "", @errorName(err) });
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "restore"), message);
            },
            error.InvalidRuntimeDir, error.InsecureRuntimeDir, error.ControlSocketPathTooLong, error.ControlSocketPathCollision => exitLifecycleRuntimePathError(allocator, stderr, mode, "restore", err),
            error.X86ResumeUnsupported => {
                const message = "spore vm restore: x86-64 KVM resume is unavailable; only fresh execution is supported";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, @errorName(err)), message);
            },
            error.FileNotFound => {
                const message = "spore vm restore: spore directory is not available";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_not_found, message, "restore"), message);
            },
            error.InvalidSporeDir => {
                const message = allocLifecycleMessage(allocator, "spore vm restore: invalid spore directory: {s}", .{parsed.spore_dir});
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.FormatTooOld => {
                const message = machine_output.format_too_old_message;
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.InvalidNetworkPolicy => {
                const message = "spore vm restore: invalid network policy in manifest";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.MissingBoundServiceBinding => {
                const message = "spore vm restore: manifest requires live bound Unix service bindings";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.UnexpectedBoundServiceBinding => {
                const message = "spore vm restore: live bound Unix service bindings do not match the manifest";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.DuplicateBoundServiceBinding => {
                const message = "spore vm restore: duplicate live bound Unix service binding";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.InvalidBoundService, error.InvalidBoundServiceTarget, error.UnsupportedBoundServiceTarget => {
                const message = "spore vm restore: invalid live bound Unix service binding";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.UnsupportedLifecycleDeviceModel => {
                const message = "spore vm restore: unsupported lifecycle device model";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.InvalidMemorySize => {
                const message = "spore vm restore: invalid spore memory size";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.InvalidLifecycleMetadata => {
                const message = "spore vm restore: invalid lifecycle metadata";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.UnsupportedLifecycleMetadata => {
                const message = "spore vm restore: lifecycle metadata does not match the spore topology";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.HostUnsupported => {
                const message = "spore vm restore: this host or restore profile is unavailable; x86-64 KVM currently supports fresh execution only";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.host_unsupported, message, "restore"), message);
            },
            error.NamedVmExists => {
                const fallback = allocLifecycleMessage(allocator, "spore vm restore: VM already exists or has stale state: {s}", .{parsed.name});
                const message = allocLifecycleLastErrorMessage(allocator, "restore", fallback);
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "restore"), message);
            },
            error.MonitorReadyTimeout, error.MonitorExited, error.MonitorVersionMismatch => {
                const message = allocLifecycleLastErrorMessage(allocator, "restore", "spore vm restore: timed out waiting for monitor readiness");
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_start_failed, message, "restore"), message);
            },
            else => |e| return e,
        }
    };
    defer deinitNamedLifecycleResult(allocator, result);
    if (mode == .json) {
        try machine_output.writeJson(allocator, stdout, result);
    } else {
        try writeNamedLifecycleResult(stdout, result);
    }
}

pub fn lsCli(ctx: *const Ctx, args: []const []const u8) !void {
    const init = ctx.init;
    const stdout = ctx.stdout;
    const stderr = ctx.stderr;
    const mode = ctx.mode;
    if (args.len != 0) {
        if (args.len == 1 and std.mem.eql(u8, args[0], "--json")) {
            exitLifecycleCliError(
                init.arena.allocator(),
                stderr,
                mode,
                machine_output.usageInvalidArgument("spore vm ls: use global --json before the command", "ls"),
                "spore vm ls: use global --json before the command",
            );
        }
        const message = "usage: spore vm ls";
        exitLifecycleCliError(
            init.arena.allocator(),
            stderr,
            mode,
            machine_output.usageInvalidArgument(message, "ls"),
            ls_usage,
        );
    }

    const allocator = init.arena.allocator();
    const entries = listNamed(.{
        .io = init.io,
        .environ_map = init.environ_map,
    }, allocator, .{}) catch |err| switch (err) {
        error.InvalidRuntimeDir, error.InsecureRuntimeDir => exitLifecycleRuntimePathError(allocator, stderr, mode, "ls", err),
        else => |e| return e,
    };
    defer freeListEntries(allocator, entries);
    if (mode == .json) {
        try machine_output.writeJson(allocator, stdout, NamedListResult{ .entries = entries });
    } else {
        try writeListEntries(stdout, entries);
    }
}

fn writeListEntries(writer: *Io.Writer, entries: []const ListEntry) !void {
    if (entries.len == 0) {
        try writer.writeAll("No VMs\n");
        return;
    }

    try writer.writeAll("NAME\tSTATE\tPID\tMEMORY\tRESIDENT\tBACKING\tCHUNKS\tDIRTY\n");
    for (entries) |entry| {
        try writer.print("{s}\t{s}\t", .{ entry.name, entry.state });
        if (entry.pid) |pid| {
            try writer.print("{d}", .{pid});
        } else {
            try writer.writeByte('-');
        }
        try writer.writeByte('\t');
        if (entry.memory) |memory| {
            try writeMemoryValue(writer, memory);
        } else {
            try writer.writeByte('?');
        }
        try writer.writeByte('\t');
        try writeOptionalBytesHuman(writer, entry.stats.resident_bytes);
        try writer.writeByte('\t');
        try writeBackingStats(writer, entry.stats);
        try writer.writeByte('\t');
        try writeChunkStats(writer, entry.stats);
        try writer.writeByte('\t');
        try writeOptionalCount(writer, entry.stats.dirty_chunks_pending);
        try writer.writeByte('\n');
    }
}

fn writeMemoryValue(writer: *Io.Writer, memory: ListMemory) !void {
    try writeBytesHuman(writer, memory.initial_bytes);
    if (memory.maximum_bytes > memory.initial_bytes) {
        try writer.writeAll("→");
        try writeBytesHuman(writer, memory.maximum_bytes);
    }
}

fn writeBytesHuman(writer: *Io.Writer, bytes: u64) !void {
    const gib: u64 = 1024 * 1024 * 1024;
    const mib: u64 = 1024 * 1024;
    if (bytes % gib == 0) {
        try writer.print("{d}GiB", .{bytes / gib});
    } else if (bytes % mib == 0) {
        try writer.print("{d}MiB", .{bytes / mib});
    } else {
        try writer.print("{d}B", .{bytes});
    }
}

fn writeOptionalBytesHuman(writer: *Io.Writer, value: ?u64) !void {
    if (value) |bytes| {
        try writeBytesHuman(writer, bytes);
    } else {
        try writer.writeByte('?');
    }
}

fn writeBackingStats(writer: *Io.Writer, stats: ListStats) !void {
    if (stats.backing_logical_bytes == null and stats.backing_allocated_bytes == null) {
        try writer.writeByte('?');
        return;
    }
    try writeOptionalBytesHuman(writer, stats.backing_allocated_bytes);
    try writer.writeByte('/');
    try writeOptionalBytesHuman(writer, stats.backing_logical_bytes);
}

fn writeChunkStats(writer: *Io.Writer, stats: ListStats) !void {
    if (stats.chunks_total == null and stats.chunks_nonzero == null) {
        try writer.writeByte('?');
        return;
    }
    try writeOptionalCount(writer, stats.chunks_nonzero);
    try writer.writeByte('/');
    try writeOptionalCount(writer, stats.chunks_total);
}

fn writeOptionalCount(writer: *Io.Writer, value: ?u64) !void {
    if (value) |count| {
        try writer.print("{d}", .{count});
    } else {
        try writer.writeByte('?');
    }
}

fn addAnnotationArgLifecycleCli(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    annotations: *spore.Annotations,
    raw: []const u8,
) void {
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse {
        const message = allocLifecycleMessage(allocator, "spore vm {s}: invalid --annotation {s}", .{ command, raw });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
    };
    annotations.map.put(allocator, raw[0..eq], raw[eq + 1 ..]) catch |err| {
        const message = allocLifecycleMessage(allocator, "spore vm {s}: invalid --annotation {s}: {s}", .{ command, raw, @errorName(err) });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
    };
    spore.validateAnnotations(annotations.*) catch {
        const message = allocLifecycleMessage(allocator, "spore vm {s}: invalid --annotation {s}", .{ command, raw });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
    };
}

fn readCreateOptionsFile(io: Io, allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len < 2 or raw[0] != '@') return error.InvalidOptionsFile;
    const path = raw[1..];
    if (path.len == 0) return error.InvalidOptionsFile;
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_metadata_bytes));
}

fn applyCreateOptionsFileLifecycleCli(
    io: Io,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    parsed: CreateOptions,
) !CreateOptions {
    const raw_path = parsed.options_path orelse return parsed;
    const data = readCreateOptionsFile(io, allocator, raw_path) catch |err| {
        const message = allocLifecycleMessage(allocator, "spore vm create: cannot read --options {s}: {s}", .{ raw_path, @errorName(err) });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
    };
    return parseCreateOptionsFile(allocator, parsed, data) catch |err| {
        const message = if (err == error.RemovedAuto)
            allocLifecycleMessage(allocator, "spore vm create: --options memory \"auto\" was removed; use memory \"512mb\" with max_memory \"16gb\" for elastic memory", .{})
        else
            allocLifecycleMessage(allocator, "spore vm create: invalid --options {s}: {s}", .{ raw_path, @errorName(err) });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
    };
}

fn parseCreateOptionsFile(
    allocator: std.mem.Allocator,
    base: CreateOptions,
    data: []const u8,
) !CreateOptions {
    const parsed = try std.json.parseFromSlice(CreateOptionsFile, allocator, data, .{
        .allocate = .alloc_always,
    });
    const file = parsed.value;
    if (file.schema_version != 1) return error.UnsupportedOptionsFile;
    if (file.name) |name| {
        if (!std.mem.eql(u8, name, base.spec.name)) return error.ConflictingOptions;
    }

    var out = base;
    out.options_path = null;
    out.spec = .{ .name = base.spec.name };
    if (file.backend) |backend| {
        if (backend_mod.Backend.parse(backend) == null) return error.InvalidBackend;
        out.spec.backend = backend;
    }
    out.spec.kernel_path = file.kernel;
    out.spec.initrd_path = file.initrd;
    out.spec.rootfs_path = file.rootfs;
    out.spec.image_ref = file.image;
    if (file.pull) |pull| {
        out.image_pull_policy = rootfs_input.PullPolicy.parse(pull) orelse return error.InvalidPullPolicy;
    }
    if (file.memory) |memory| {
        out.spec.memory = try memory_config.parse(memory);
    }
    if (file.max_memory) |maximum| {
        out.spec.memory.maximum_bytes = try memory_config.parseBytes(maximum);
    }
    try out.spec.memory.validate();
    if (file.vcpus) |vcpus| out.spec.vcpus = vcpus;
    if (file.guest_port) |port| out.spec.guest_port = port;
    if (file.timeout_ms) |timeout| out.spec.timeout_ms = timeout;
    out.spec.console_log_path = file.console_log_path;
    out.initial_output = file.initial_output orelse out.initial_output;
    out.spec.annotations = file.annotations;
    try spore.validateAnnotations(out.spec.annotations);

    if (file.network) |network| {
        const has_network_fields = network.allow_cidrs.len != 0 or
            network.allow_hosts.len != 0 or
            network.allow_host_ports.len != 0 or
            network.network_rules.len != 0 or
            network.bound_services.len != 0;
        if (!network.enabled and has_network_fields) return error.InvalidNetworkPolicy;
        if (network.enabled) {
            // Like plain `--net`, egress stays unrestricted unless a rule
            // restricts it.
            var policy = spore_net_policy.Config{ .egress = .unrestricted };
            for (network.allow_cidrs) |cidr| try policy.addAllowCidr(cidr);
            for (network.allow_hosts) |host| try policy.addAllowHost(host);
            for (network.allow_host_ports) |rule| try policy.addExactHostPorts(rule.host, rule.ports);
            for (network.network_rules) |rule| try policy.addExactHostPorts(rule.host, rule.ports);
            for (network.bound_services) |service| {
                const guest_host = service.guest_host orelse try std.fmt.allocPrint(allocator, "{s}.spore.internal", .{service.name});
                try policy.addBoundUnixService(service.name, guest_host, service.guest_port, service.unix_path);
            }
            out.network = .{ .spore = policy };
        }
    }
    if (out.spec.rootfs_path != null and out.spec.image_ref != null) return error.InvalidRootfsInput;
    if (out.spec.image_ref == null and out.image_pull_policy != .missing) return error.InvalidPullPolicy;
    return out;
}

fn parseCreateArgs(
    args: []const []const u8,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) !CreateOptions {
    var name: ?[]const u8 = null;
    var spec = Spec{ .name = "" };
    var options_path: ?[]const u8 = null;
    var field_flag_seen = false;
    var max_memory_set = false;
    var image_pull_policy: rootfs_input.PullPolicy = .missing;
    var initial_output: InitialOutputDisposition = .retain;
    var network_requested = false;
    // Plain `--net` leaves egress unrestricted; allow flags narrow it.
    var network_policy = spore_net_policy.Config{ .egress = .unrestricted };
    var command_mode: cli_args.CommandMode = .shell;
    var command: ?[]const []const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            if (command != null) return error.InvalidGuestCommand;
            command_mode = .argv;
            command = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, args[i], "--shell")) {
            if (command != null) return error.InvalidGuestCommand;
            _ = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            command = args[i .. i + 1];
        } else if (std.mem.eql(u8, args[i], "--backend")) {
            field_flag_seen = true;
            spec.backend = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            if (backend_mod.Backend.parse(spec.backend) == null) {
                const message = "--backend must be auto, hvf, or kvm";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            }
        } else if (std.mem.eql(u8, args[i], "--kernel")) {
            field_flag_seen = true;
            spec.kernel_path = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--initrd")) {
            field_flag_seen = true;
            spec.initrd_path = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--rootfs")) {
            field_flag_seen = true;
            spec.rootfs_path = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--image")) {
            field_flag_seen = true;
            spec.image_ref = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--options")) {
            if (options_path != null) {
                const message = "spore vm create: --options may be supplied once";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            }
            options_path = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--pull")) {
            field_flag_seen = true;
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            image_pull_policy = rootfs_input.PullPolicy.parse(raw) orelse {
                const message = "spore vm create: --pull must be missing, always, or never";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
        } else if (std.mem.startsWith(u8, args[i], "--pull=")) {
            field_flag_seen = true;
            const raw = args[i]["--pull=".len..];
            image_pull_policy = rootfs_input.PullPolicy.parse(raw) orelse {
                const message = "spore vm create: --pull must be missing, always, or never";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
        } else if (std.mem.eql(u8, args[i], "--net")) {
            field_flag_seen = true;
            network_requested = true;
        } else if (std.mem.eql(u8, args[i], "--allow-cidr")) {
            field_flag_seen = true;
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            network_policy.addAllowCidr(raw) catch |err| {
                const message = allocLifecycleMessage(allocator, "spore vm create: invalid --allow-cidr {s}: {s}", .{ raw, @errorName(err) });
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
        } else if (std.mem.eql(u8, args[i], "--allow-host")) {
            field_flag_seen = true;
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            network_policy.addAllowHost(raw) catch |err| {
                const message = allocLifecycleMessage(allocator, "spore vm create: invalid --allow-host {s}: {s}", .{ raw, @errorName(err) });
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
        } else if (std.mem.eql(u8, args[i], "--allow-host-port")) {
            field_flag_seen = true;
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            const parsed = spore_net_policy.parseHostPort(raw) catch |err| {
                const message = allocLifecycleMessage(allocator, "spore vm create: invalid --allow-host-port {s}: {s}", .{ raw, @errorName(err) });
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
            network_policy.addExactHostPorts(parsed.host, &.{parsed.port}) catch |err| {
                const message = allocLifecycleMessage(allocator, "spore vm create: invalid --allow-host-port {s}: {s}", .{ raw, @errorName(err) });
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
        } else if (std.mem.eql(u8, args[i], "--bind-service")) {
            field_flag_seen = true;
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            network_policy.addBindService(allocator, raw) catch |err| {
                const message = allocLifecycleMessage(allocator, "spore vm create: invalid --bind-service {s}: {s}", .{ raw, @errorName(err) });
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
        } else if (std.mem.eql(u8, args[i], "--forward")) {
            field_flag_seen = true;
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            network_policy.addPortForward(raw) catch |err| {
                const message = allocLifecycleMessage(allocator, "spore vm create: invalid --forward {s}: {s}", .{ raw, @errorName(err) });
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
        } else if (std.mem.eql(u8, args[i], "--memory")) {
            field_flag_seen = true;
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            spec.memory.initial_bytes = memory_config.parseBytes(raw) catch |err| {
                const message = if (err == error.RemovedAuto)
                    "spore vm create: --memory auto was removed; use --memory 512mb for fixed memory, or --memory 512mb --max-memory 16gb for elastic memory"
                else
                    allocLifecycleMessage(allocator, "spore vm create: --memory must be a positive page-aligned size like 512mb or 16gb ({s})", .{@errorName(err)});
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
            if (!max_memory_set) spec.memory.maximum_bytes = spec.memory.initial_bytes;
        } else if (std.mem.eql(u8, args[i], "--max-memory")) {
            field_flag_seen = true;
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            spec.memory.maximum_bytes = memory_config.parseBytes(raw) catch |err| {
                const message = allocLifecycleMessage(allocator, "spore vm create: --max-memory must be a positive page-aligned size like 512mb or 16gb ({s})", .{@errorName(err)});
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
            max_memory_set = true;
        } else if (std.mem.eql(u8, args[i], "--memory-mib")) {
            const message = "spore vm create: --memory-mib has been replaced by --memory";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
        } else if (std.mem.eql(u8, args[i], "--vcpus")) {
            field_flag_seen = true;
            const flag = args[i];
            spec.vcpus = parseVcpuCountLifecycleCli(allocator, stderr, mode, "create", takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, flag), flag);
        } else if (std.mem.eql(u8, args[i], "--guest-port")) {
            field_flag_seen = true;
            const flag = args[i];
            spec.guest_port = parseIntArgLifecycleCli(u32, allocator, stderr, mode, "create", takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, flag), flag);
        } else if (std.mem.eql(u8, args[i], "--timeout")) {
            field_flag_seen = true;
            const flag = args[i];
            spec.timeout_ms = parseDurationArgLifecycleCli(allocator, stderr, mode, "create", takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, flag), flag);
        } else if (std.mem.eql(u8, args[i], "--timeout-ms")) {
            field_flag_seen = true;
            const flag = args[i];
            spec.timeout_ms = parseIntArgLifecycleCli(u64, allocator, stderr, mode, "create", takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, flag), flag);
        } else if (std.mem.eql(u8, args[i], "--console-log")) {
            field_flag_seen = true;
            spec.console_log_path = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--initial-output")) {
            field_flag_seen = true;
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            initial_output = InitialOutputDisposition.parse(raw) orelse {
                const message = "spore vm create: --initial-output must be retain or discard";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
        } else if (std.mem.eql(u8, args[i], "--annotation")) {
            field_flag_seen = true;
            addAnnotationArgLifecycleCli(allocator, stderr, mode, "create", &spec.annotations, takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]));
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            const message = allocLifecycleMessage(allocator, "unknown create argument: {s}", .{args[i]});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
        } else if (name == null) {
            validateNameLifecycleCli(allocator, stderr, mode, "create", args[i]);
            name = args[i];
            spec.name = args[i];
        } else {
            const message = "spore vm create: put guest argv after --, or use --shell STRING";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
        }
    }

    if (name == null) {
        exitLifecycleCliError(
            allocator,
            stderr,
            mode,
            machine_output.usageMissingArgument("usage: spore vm create NAME [options]", "create"),
            create_usage,
        );
    }
    if (command) |argv| {
        if (argv.len == 0) {
            exitLifecycleCliError(
                allocator,
                stderr,
                mode,
                machine_output.usageMissingArgument("usage: spore vm create NAME [options] -- <argv...>", "create"),
                create_usage,
            );
        }
    }
    if (options_path != null and field_flag_seen) {
        const message = "spore vm create: --options cannot be combined with create option flags";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
    }
    if (spec.rootfs_path != null and spec.image_ref != null) {
        const message = "spore vm create: --rootfs and --image are mutually exclusive";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
    }
    if (spec.image_ref == null and image_pull_policy != .missing) {
        const message = "spore vm create: --pull requires --image";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
    }
    if (!network_requested and network_policy.hasRules()) {
        const message = "spore vm create: network flags require --net";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
    }
    spec.memory.validate() catch |err| {
        const message = allocLifecycleMessage(allocator, "spore vm create: --max-memory must be greater than or equal to --memory ({s})", .{@errorName(err)});
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
    };
    return .{
        .spec = spec,
        .options_path = options_path,
        .image_pull_policy = image_pull_policy,
        .initial_output = initial_output,
        .network = if (network_requested) .{ .spore = network_policy } else .disabled,
        .command_mode = command_mode,
        .command = command orelse &.{},
    };
}

fn parseExecArgs(args: []const []const u8) ExecOptions {
    if (args.len < 2) usageExit(exec_usage);
    var name: ?[]const u8 = null;
    var command_mode: cli_args.CommandMode = .shell;
    var command: []const []const u8 = &.{};
    var guest_env_specs = guest_request.GuestEnvSpecList{};
    var guest_working_dir: ?[]const u8 = null;
    var interactive = false;
    var tty = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            if (command.len != 0) usageExit("spore vm exec: --shell and trailing argv are mutually exclusive\n");
            command_mode = .argv;
            command = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, args[i], "--shell")) {
            if (command.len != 0) usageExit("spore vm exec: --shell may be supplied once\n");
            if (i + 1 >= args.len) usageExit("spore vm exec: --shell requires a command string\n");
            i += 1;
            command = args[i .. i + 1];
        } else if (std.mem.eql(u8, args[i], "--env")) {
            if (i + 1 >= args.len) usageExit(exec_usage);
            i += 1;
            guest_env_specs.append(guest_request.parseGuestEnvSpec(args[i]) catch usageExit(exec_usage)) catch usageExit(exec_usage);
        } else if (std.mem.eql(u8, args[i], "--workdir")) {
            if (i + 1 >= args.len) usageExit(exec_usage);
            i += 1;
            guest_request.validateGuestExecContext(&.{}, args[i]) catch usageExit("spore vm exec: --workdir must be an absolute guest path\n");
            guest_working_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "-i") or std.mem.eql(u8, args[i], "--interactive")) {
            interactive = true;
        } else if (std.mem.eql(u8, args[i], "-t") or std.mem.eql(u8, args[i], "--tty")) {
            tty = true;
        } else if (std.mem.eql(u8, args[i], "-it") or std.mem.eql(u8, args[i], "-ti")) {
            interactive = true;
            tty = true;
        } else if (std.mem.startsWith(u8, args[i], "-")) {
            usageExit("spore vm exec: unknown option; see `spore vm exec --help`\n");
        } else if (name == null) {
            validateNameOrExit("exec", args[i]) catch unreachable;
            name = args[i];
        } else {
            usageExit("spore vm exec: put guest argv after --, or use --shell STRING\n");
        }
    }
    const vm_name = name orelse usageExit(exec_usage);
    if (command.len == 0) usageExit(exec_usage);
    return .{
        .name = vm_name,
        .command_mode = command_mode,
        .command = command,
        .guest_env_specs = guest_env_specs,
        .guest_working_dir = guest_working_dir,
        .interactive = interactive,
        .tty = tty,
    };
}

fn parseRmArgs(args: []const []const u8, allocator: std.mem.Allocator, stderr: *Io.Writer, mode: machine_output.Mode) []const u8 {
    if (args.len != 1) {
        exitLifecycleCliError(
            allocator,
            stderr,
            mode,
            machine_output.usageMissingArgument("usage: spore vm rm NAME", "rm"),
            rm_usage,
        );
    }
    validateNameLifecycleCli(allocator, stderr, mode, "rm", args[0]);
    return args[0];
}

fn parseSaveArgs(
    args: []const []const u8,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) SaveOptions {
    var name: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var stop = false;
    var annotations = spore.Annotations{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--output")) {
            out_dir = takeValueLifecycleCli(allocator, stderr, mode, "save", args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--stop")) {
            stop = true;
        } else if (std.mem.eql(u8, args[i], "--annotation")) {
            addAnnotationArgLifecycleCli(allocator, stderr, mode, "save", &annotations, takeValueLifecycleCli(allocator, stderr, mode, "save", args, &i, args[i]));
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            const message = allocLifecycleMessage(allocator, "unknown save argument: {s}", .{args[i]});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "save"), message);
        } else if (name == null) {
            validateNameLifecycleCli(allocator, stderr, mode, "save", args[i]);
            name = args[i];
        } else {
            const message = allocLifecycleMessage(allocator, "unexpected save argument: {s}", .{args[i]});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "save"), message);
        }
    }

    if (name == null or out_dir == null) {
        exitLifecycleCliError(
            allocator,
            stderr,
            mode,
            machine_output.usageMissingArgument("usage: spore vm save NAME --output DIR [--stop]", "save"),
            save_usage,
        );
    }
    return .{ .name = name.?, .out_dir = out_dir.?, .stop = stop, .annotations = annotations };
}

fn parseForkArgs(
    args: []const []const u8,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) ForkOptions {
    var source_name: ?[]const u8 = null;
    var count: ?usize = null;
    var name_pattern: ?[]const u8 = null;
    var allow_slow_copy = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--count")) {
            const flag = args[i];
            count = parseIntArgLifecycleCli(usize, allocator, stderr, mode, "fork", takeValueLifecycleCli(allocator, stderr, mode, "fork", args, &i, flag), flag);
        } else if (std.mem.eql(u8, args[i], "--name-prefix")) {
            const prefix = takeValueLifecycleCli(allocator, stderr, mode, "fork", args, &i, args[i]);
            validateNameLifecycleCli(allocator, stderr, mode, "fork", prefix);
            name_pattern = allocLifecycleMessage(allocator, "{s}-%d", .{prefix});
        } else if (std.mem.eql(u8, args[i], "--allow-slow-copy")) {
            allow_slow_copy = true;
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            const message = allocLifecycleMessage(allocator, "unknown vm fork argument: {s}", .{args[i]});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        } else if (source_name == null) {
            validateNameLifecycleCli(allocator, stderr, mode, "fork", args[i]);
            source_name = args[i];
        } else {
            const message = allocLifecycleMessage(allocator, "unexpected vm fork argument: {s}", .{args[i]});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        }
    }

    if (source_name == null or count == null or name_pattern == null) {
        exitLifecycleCliError(
            allocator,
            stderr,
            mode,
            machine_output.usageMissingArgument("usage: spore vm fork NAME --count N --name-prefix PREFIX", "fork"),
            fork_usage,
        );
    }
    if (count.? == 0) {
        const message = "spore vm fork: --count must be a positive integer";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
    }
    if (count.? > runtime_disk_claim.max_children_per_batch) {
        const message = "spore vm fork: --count cannot exceed 32";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
    }
    return .{
        .source_name = source_name.?,
        .count = count.?,
        .name_pattern = name_pattern.?,
        .allow_slow_copy = allow_slow_copy,
    };
}

fn parseRestoreArgs(
    args: []const []const u8,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) RestoreOptions {
    var spore_dir: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var backend: ?backend_mod.Backend = null;
    var generation_path: ?[]const u8 = null;
    var bound_services = spore_net_policy.BoundServiceBindingList{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--backend")) {
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "restore", args, &i, arg);
            backend = backend_mod.Backend.parse(raw) orelse {
                const message = "--backend must be auto, hvf, or kvm";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "restore"), message);
            };
        } else if (std.mem.startsWith(u8, arg, "--backend=")) {
            const raw = arg["--backend=".len..];
            backend = backend_mod.Backend.parse(raw) orelse {
                const message = "--backend must be auto, hvf, or kvm";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "restore"), message);
            };
        } else if (std.mem.eql(u8, arg, "--generation")) {
            generation_path = takeValueLifecycleCli(allocator, stderr, mode, "restore", args, &i, arg);
        } else if (std.mem.startsWith(u8, arg, "--generation=")) {
            generation_path = arg["--generation=".len..];
        } else if (std.mem.eql(u8, arg, "--checkpoint")) {
            spore_dir = takeValueLifecycleCli(allocator, stderr, mode, "restore", args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--bind-service")) {
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "restore", args, &i, arg);
            bound_services.append(spore_net_policy.parseBoundServiceBinding(raw) catch |err| {
                const message = allocLifecycleMessage(allocator, "spore vm restore: invalid --bind-service {s}: {s}", .{ raw, @errorName(err) });
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "restore"), message);
            }) catch |err| {
                const message = allocLifecycleMessage(allocator, "spore vm restore: invalid --bind-service {s}: {s}", .{ raw, @errorName(err) });
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "restore"), message);
            };
        } else if (std.mem.startsWith(u8, arg, "--")) {
            const message = allocLifecycleMessage(allocator, "unknown restore argument: {s}", .{arg});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "restore"), message);
        } else if (name == null) {
            validateNameLifecycleCli(allocator, stderr, mode, "restore", arg);
            name = arg;
        } else {
            const message = allocLifecycleMessage(allocator, "unexpected restore argument: {s}", .{arg});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "restore"), message);
        }
    }

    if (spore_dir == null or name == null) {
        exitLifecycleCliError(
            allocator,
            stderr,
            mode,
            machine_output.usageMissingArgument("usage: spore vm restore DIR --name NAME", "restore"),
            restore_usage,
        );
    }
    return .{
        .spore_dir = spore_dir.?,
        .name = name.?,
        .backend = backend,
        .generation_path = generation_path,
        .bound_services = bound_services,
    };
}

fn writeNamedForkResult(writer: *Io.Writer, result: NamedForkResult) !void {
    try writer.writeAll("forked live VM children:");
    for (result.children) |name| try writer.print(" {s}", .{name});
    try writer.writeByte('\n');
}

fn writeNamedLifecycleResult(writer: *Io.Writer, result: NamedLifecycleResult) !void {
    if (std.mem.eql(u8, result.action, "created")) {
        try writer.print("created live VM {s}\n", .{result.name});
        if (result.initial_command) |initial| {
            if (initial.output_destination == .named_logs) {
                try writer.print(
                    "initial command started; output retained up to {d} bytes per stream; retrieve with `spore vm logs {s} --initial`\n",
                    .{ initial.output_limit_bytes_per_stream orelse 0, result.name },
                );
            } else {
                try writer.writeAll("initial command started; output discarded\n");
            }
        }
    } else if (std.mem.eql(u8, result.action, "restored")) {
        try writer.print("restored checkpoint as live VM {s}\n", .{result.name});
    } else if (std.mem.eql(u8, result.action, "saved")) {
        try writer.print("saved checkpoint {s} ({s}); live VM {s} is still running\n", .{ result.spore_dir orelse result.name, result.ownership orelse saved_spore_ownership.portable_self_contained, result.name });
    } else if (std.mem.eql(u8, result.action, "saved_stopped")) {
        try writer.print("saved checkpoint {s} ({s}) and stopped live VM {s}\n", .{ result.spore_dir orelse result.name, result.ownership orelse saved_spore_ownership.portable_self_contained, result.name });
        if ((result.saved_sessions orelse 0) > 0) {
            try writer.writeAll("checkpoint has a saved session; use `spore checkpoint resume <checkpoint>` to reconnect, or `spore run --checkpoint <checkpoint> ...` to run new commands.\n");
        } else {
            try writer.writeAll("checkpoint has no saved session; use `spore run --checkpoint <checkpoint> ...` to run new commands, or `spore run --save-checkpoint <checkpoint> --save-on TERM ...` if you want fanout to attach to the original command.\n");
        }
    } else if (std.mem.eql(u8, result.action, "removed")) {
        try writer.print("removed live VM {s}; monitor stopped and runtime state deleted, checkpoints and images unchanged\n", .{result.name});
    } else {
        try writer.print("{s} vm {s}\n", .{ result.action, result.name });
    }
    if (std.mem.eql(u8, result.ownership orelse "", saved_spore_ownership.machine_local_pinned))
        try writer.writeAll("Cache-pinned directory; do not copy standalone. Transfer with checkpoint push/pull.\n");
}

fn writeInitialOutputResult(writer: *Io.Writer, result: NamedLifecycleResult) !void {
    const initial = result.initial_command orelse return error.InitialOutputUnavailable;
    switch (initial.process_status orelse .running) {
        .running => try writer.writeAll("initial command: running\n"),
        .exited => try writer.print("initial command: exited ({d})\n", .{initial.exit_code orelse 255}),
    }
    try writer.print(
        "stdout ({d} bytes{s}):\n",
        .{ if (initial.stdout) |bytes| bytes.len else 0, if (initial.stdout_truncated) ", truncated" else "" },
    );
    if (initial.stdout) |bytes| {
        try writer.writeAll(bytes);
        if (bytes.len != 0 and bytes[bytes.len - 1] != '\n') try writer.writeByte('\n');
    }
    try writer.print(
        "stderr ({d} bytes{s}):\n",
        .{ if (initial.stderr) |bytes| bytes.len else 0, if (initial.stderr_truncated) ", truncated" else "" },
    );
    if (initial.stderr) |bytes| {
        try writer.writeAll(bytes);
        if (bytes.len != 0 and bytes[bytes.len - 1] != '\n') try writer.writeByte('\n');
    }
}

/// Runs a named exec against this process's stdio: stdin is forwarded when
/// interactive, an interactive TTY puts the terminal in raw mode, and window
/// size changes reach the guest.
fn execNamedStreaming(context: Context, allocator: std.mem.Allocator, options: ExecNamedStreamOptions) !u8 {
    var stream = try openExecNamedStream(context, allocator, options);
    defer stream.deinit();
    var raw_terminal: ?attach_stream.RawTerminal = null;
    if (options.tty and options.interactive and std.c.isatty(0) != 0) raw_terminal = try attach_stream.RawTerminal.enable();
    defer if (raw_terminal) |*raw| raw.deinit();

    var resize_registration: ?attach_stream.TerminalResizeRegistration = null;
    if (options.tty) resize_registration = attach_stream.TerminalResizeRegistration.install(null);
    defer if (resize_registration) |*registration| registration.deinit();

    var pump = ExecStreamPump{
        .stream = &stream,
        .interactive = options.interactive,
        .tty = options.tty,
    };
    return pump.run();
}

fn copyNamedStreaming(
    context: Context,
    allocator: std.mem.Allocator,
    options: CopyNamedOptions,
    direction: CopyDirection,
    fds: CopyStreamFds,
) !u8 {
    var stream = try lifecycle.openCopyNamedStream(context, allocator, options, direction);
    defer stream.deinit();
    return copyStreamControl(&stream, direction, fds);
}

fn copyStreamControl(stream: *ExecNamedStream, direction: CopyDirection, fds: CopyStreamFds) !u8 {
    var pump = ExecStreamPump{
        .stream = stream,
        .interactive = direction == .in,
        .tty = false,
        .input_fd = fds.input_fd,
        .stdout_fd = fds.archive_fd,
        .stdout_limit = fds.archive_limit,
        .stderr_fd = fds.stderr_fd,
        .escape_stderr = true,
    };
    return pump.run();
}

/// Where a copy stream's bytes go. Guest stdout is the copy-out archive and
/// is dropped during copy-in, so guest bytes never reach the CLI's stdout.
const CopyStreamFds = struct {
    /// The copy-in archive sent to the guest.
    input_fd: std.c.fd_t = -1,
    /// Receives the copy-out archive.
    archive_fd: std.c.fd_t = -1,
    archive_limit: u64 = named_copy_archive.max_archive_bytes,
    /// Receives guest diagnostics with control bytes escaped; -1 drops them.
    stderr_fd: std.c.fd_t = -1,
};

const ExecStreamPump = struct {
    stream: *ExecNamedStream,
    interactive: bool,
    tty: bool,
    input_fd: std.c.fd_t = 0,
    stdout_fd: std.c.fd_t = 1,
    stderr_fd: std.c.fd_t = 2,
    stdout_limit: u64 = std.math.maxInt(u64),
    stdout_bytes: u64 = 0,
    escape_stderr: bool = false,
    stdin_closed: bool = false,
    /// The resize count last sent; null sends the size on the first poll.
    resize_seen: ?u32 = null,

    fn run(self: *ExecStreamPump) !u8 {
        while (true) {
            try self.maybeSendResize();
            const poll_stdin = self.interactive and !self.stdin_closed;
            var fds = [_]std.posix.pollfd{
                .{ .fd = self.stream.stream.socket.handle, .events = std.c.POLL.IN | std.c.POLL.HUP | std.c.POLL.ERR, .revents = 0 },
                .{ .fd = if (poll_stdin) self.input_fd else -1, .events = std.c.POLL.IN | std.c.POLL.HUP | std.c.POLL.ERR, .revents = 0 },
            };
            const ready = std.posix.poll(&fds, 100) catch return error.MonitorUnavailable;
            if (ready == 0) continue;
            var read_control_frame = false;
            if ((fds[0].revents & std.c.POLL.IN) != 0) {
                read_control_frame = true;
                if (try self.readOutputFrame()) |exit_code| return exit_code;
            }
            if (!read_control_frame and (fds[0].revents & (std.c.POLL.HUP | std.c.POLL.ERR | std.c.POLL.NVAL)) != 0) {
                return error.MonitorUnavailable;
            }
            if (poll_stdin and (fds[1].revents & (std.c.POLL.IN | std.c.POLL.HUP)) != 0) {
                try self.forwardStdin();
            }
            if (poll_stdin and !self.stdin_closed and (fds[1].revents & (std.c.POLL.ERR | std.c.POLL.NVAL)) != 0) {
                // macOS poll() reports POLLNVAL for some device files such as
                // /dev/null. An unpollable or errored stdin means no more
                // input will arrive; close the input stream and keep pumping
                // output instead of failing the exec.
                try self.closeInput();
            }
        }
    }

    fn readOutputFrame(self: *ExecStreamPump) !?u8 {
        switch (try self.stream.next()) {
            .stdout, .terminal => |bytes| {
                self.stdout_bytes += bytes.len;
                if (self.stdout_bytes > self.stdout_limit) return error.CopyArchiveTooLarge;
                if (self.stdout_fd >= 0) try writeFdAll(self.stdout_fd, bytes);
                return null;
            },
            .stderr => |bytes| {
                if (self.stderr_fd < 0) return null;
                if (self.escape_stderr) {
                    try writeEscapedFd(self.stderr_fd, bytes);
                } else {
                    try writeFdAll(self.stderr_fd, bytes);
                }
                return null;
            },
            .exit => |code| return code,
            .err => |bytes| {
                return monitorRequestFailed(bytes);
            },
        }
    }

    fn closeInput(self: *ExecStreamPump) !void {
        if (self.stdin_closed) return;
        if (self.tty) {
            try self.stream.closeTerminal();
        } else {
            try self.stream.closeStdin();
        }
        self.stdin_closed = true;
    }

    fn forwardStdin(self: *ExecStreamPump) !void {
        if (self.stdin_closed) return;
        var buf: [4096]u8 = undefined;
        const n = std.c.read(self.input_fd, &buf, buf.len);
        if (n < 0) {
            switch (std.c.errno(n)) {
                .INTR => return,
                else => return try self.closeInput(),
            }
        }
        if (n == 0) {
            try self.closeInput();
            return;
        }
        const input_stream: spore_stream.StreamId = if (self.tty) .terminal else .stdin;
        switch (input_stream) {
            .stdin => try self.stream.writeStdin(buf[0..@intCast(n)]),
            .terminal => try self.stream.writeTerminal(buf[0..@intCast(n)]),
            else => unreachable,
        }
    }

    fn maybeSendResize(self: *ExecStreamPump) !void {
        if (!self.tty) return;
        const count = attach_stream.terminal_resizes.load(.acquire);
        if (count == self.resize_seen) return;
        self.resize_seen = count;
        try self.stream.resizeTerminal(attach_stream.terminalSizeOrDefault(attach_stream.terminalSizeFd()));
    }
};

fn writeAll(io: Io, stream: net.Stream, bytes: []const u8) !void {
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

/// Answers one hello, then one copy request with `frames`, then drains the
/// client until it hangs up.
const FakeCopyMonitor = struct {
    io: Io,
    server: net.Server,
    frames: []const u8,

    fn main(fake: *FakeCopyMonitor) void {
        fake.serve() catch {};
    }

    fn serve(fake: *FakeCopyMonitor) !void {
        const io = fake.io;
        var line_buffer: [512]u8 = undefined;
        {
            var hello = try fake.server.accept(io);
            defer hello.close(io);
            var reader = hello.reader(io, &line_buffer);
            _ = try reader.interface.takeDelimiterExclusive('\n');
            try writeAll(io, hello, std.fmt.comptimePrint(
                "{{\"type\":\"hello\",\"schema\":\"{s}\",\"spore_version\":\"{s}\",\"helper_contract\":{d}}}\n",
                .{ monitor_protocol.hello_schema, version.value, monitor_protocol.helper_contract },
            ));
        }
        var copy = try fake.server.accept(io);
        defer copy.close(io);
        var reader = copy.reader(io, &line_buffer);
        _ = try reader.interface.takeDelimiterExclusive('\n');
        try writeAll(io, copy, fake.frames);
        _ = reader.interface.discardRemaining() catch {};
    }
};

fn appendTestFrame(w: *Io.Writer, frame_type: spore_stream.FrameType, stream_id: spore_stream.StreamId, offset: u64, payload: []const u8) !void {
    var buf: [spore_stream.max_frame_len]u8 = undefined;
    try w.writeAll(try spore_stream.writeFrame(&buf, .{ .frame_type = frame_type, .stream_id = stream_id, .offset = offset }, payload));
}

/// Runs one copy stream against a fake monitor that sends `frames`.
fn copyStreamAgainstFrames(direction: CopyDirection, frames: []const u8, fds: CopyStreamFds) !u8 {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = try TestDir.init();
    defer tmp.deinit();
    const socket_path = try tmp.path("m.sock");
    const address = try net.UnixAddress.init(socket_path);
    var fake = FakeCopyMonitor{ .io = io, .server = try address.listen(io, .{ .kernel_backlog = 2 }), .frames = frames };
    defer fake.server.deinit(io);
    const thread = try std.Thread.spawn(.{}, FakeCopyMonitor.main, .{&fake});
    defer thread.join();

    var stream = try monitor_protocol.openStream(allocator, io, socket_path, switch (direction) {
        .in => .{ .copy_in = .{ .path = "/tmp/guest" } },
        .out => .{ .copy_out = .{ .path = "/tmp/guest" } },
    });
    defer stream.deinit();
    return copyStreamControl(&stream, direction, fds);
}

fn readPipeToEnd(fd: std.c.fd_t, buf: []u8) ![]const u8 {
    var len: usize = 0;
    while (true) {
        if (len == buf.len) return error.NoSpaceLeft;
        const n = std.c.read(fd, buf[len..].ptr, buf.len - len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) return buf[0..len];
        len += @intCast(n);
    }
}

test "copy-in drops guest stdout and escapes guest stderr" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    var frames_buf: [256]u8 = undefined;
    var frames: Io.Writer = .fixed(&frames_buf);
    // A hostile guest tries to print a result before the CLI's own JSON and
    // to retitle the terminal.
    try appendTestFrame(&frames, .data, .stdout, 0, "{\"schema\":\"spore.copy.result.v1\"}\n");
    try appendTestFrame(&frames, .data, .stderr, 0, "\x1b]0;owned\x07denied\r\n");
    try appendTestFrame(&frames, .exit, .control, 0, &.{ 0, 0, 0, 0 });

    var input: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(0, std.c.pipe(&input));
    defer _ = std.c.close(input[0]);
    _ = std.c.close(input[1]);
    var stdout_pipe: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(0, std.c.pipe(&stdout_pipe));
    defer _ = std.c.close(stdout_pipe[0]);
    var stderr_pipe: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(0, std.c.pipe(&stderr_pipe));
    defer _ = std.c.close(stderr_pipe[0]);

    // Capture this process's stdout for the length of the copy.
    const saved_stdout = std.c.dup(1);
    try std.testing.expect(saved_stdout >= 0);
    try std.testing.expect(std.c.dup2(stdout_pipe[1], 1) == 1);
    const result = copyStreamAgainstFrames(.in, frames.buffered(), .{
        .input_fd = input[0],
        .stderr_fd = stderr_pipe[1],
    });
    _ = std.c.dup2(saved_stdout, 1);
    _ = std.c.close(saved_stdout);
    _ = std.c.close(stdout_pipe[1]);
    _ = std.c.close(stderr_pipe[1]);
    try std.testing.expectEqual(0, try result);

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("", try readPipeToEnd(stdout_pipe[0], &buf));
    try std.testing.expectEqualStrings("\\x1b]0;owned\\x07denied\\x0d\n", try readPipeToEnd(stderr_pipe[0], &buf));
}

test "copy-out refuses an archive over its limit" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;

    var frames_buf: [256]u8 = undefined;
    var frames: Io.Writer = .fixed(&frames_buf);
    try appendTestFrame(&frames, .data, .stdout, 0, "12345678");
    try appendTestFrame(&frames, .data, .stdout, 8, "9");
    try appendTestFrame(&frames, .exit, .control, 0, &.{ 0, 0, 0, 0 });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var archive = try tmp.dir.createFile(io, "payload.spcp", .{});
    defer archive.close(io);
    try std.testing.expectError(error.CopyArchiveTooLarge, copyStreamAgainstFrames(.out, frames.buffered(), .{
        .archive_fd = archive.handle,
        .archive_limit = 8,
    }));
    try std.testing.expectEqual(8, (try archive.stat(io)).size);
}

/// Writes guest text with every byte other than printable ASCII, tab, and
/// newline shown as `\xNN`, so the guest cannot send terminal escapes.
fn writeEscapedFd(fd: std.c.fd_t, bytes: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    for (bytes) |byte| {
        if (len + 4 > buf.len) {
            try writeFdAll(fd, buf[0..len]);
            len = 0;
        }
        if ((byte >= 0x20 and byte < 0x7f) or byte == '\n' or byte == '\t') {
            buf[len] = byte;
            len += 1;
        } else {
            _ = std.fmt.bufPrint(buf[len..][0..4], "\\x{x:0>2}", .{byte}) catch unreachable;
            len += 4;
        }
    }
    try writeFdAll(fd, buf[0..len]);
}

fn writeFdAll(fd: std.c.fd_t, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(fd, remaining.ptr, remaining.len);
        if (n < 0) {
            switch (std.c.errno(n)) {
                .INTR => continue,
                else => return error.MonitorUnavailable,
            }
        }
        if (n == 0) return error.MonitorUnavailable;
        remaining = remaining[@intCast(n)..];
    }
}

fn openHostFileRead(allocator: std.mem.Allocator, io: Io, path: []const u8) !std.c.fd_t {
    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.NotRegularFile;
    const pathz = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(pathz);
    const fd = std.c.open(pathz, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.OpenFailed;
    return fd;
}

fn usageExit(text: []const u8) noreturn {
    if (exec_cli_event_writer) |events| {
        const classified = machine_output.usageInvalidArgument(text, "exec");
        events.emitFailure(classified) catch {};
        std.process.exit(classified.exit_code);
    }
    std.debug.print("{s} [usage.invalid_argument]\n", .{std.mem.trimEnd(u8, text, "\n")});
    std.process.exit(2);
}

fn allocLifecycleMessage(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(allocator, fmt, args) catch "CLI argument error";
}

fn allocLifecycleLastErrorMessage(allocator: std.mem.Allocator, command: []const u8, fallback: []const u8) []const u8 {
    const detail = lastErrorMessage();
    if (detail.len == 0) return fallback;
    return std.fmt.allocPrint(allocator, "spore vm {s}: {s}", .{ command, detail }) catch fallback;
}

fn exitLifecycleCliError(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    err: machine_output.CliError,
    human_text: []const u8,
) noreturn {
    @import("cli.zig").exitWithCliError(allocator, stderr, mode, err, human_text);
}

fn exitLifecycleRuntimePathError(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    err: anyerror,
) noreturn {
    const message = switch (err) {
        error.InvalidRuntimeDir => allocLifecycleMessage(allocator, "spore vm {s}: invalid runtime directory; set {s} or XDG_RUNTIME_DIR to an absolute path", .{ command, runtime_dir_env }),
        error.InsecureRuntimeDir => allocLifecycleMessage(allocator, "spore vm {s}: insecure runtime directory; registry directories must be private to the current user", .{command}),
        error.ControlSocketPathTooLong => allocLifecycleLastErrorMessage(
            allocator,
            command,
            allocLifecycleMessage(allocator, "spore vm {s}: internal control socket path exceeds the platform limit", .{command}),
        ),
        error.ControlSocketPathCollision => allocLifecycleLastErrorMessage(
            allocator,
            command,
            allocLifecycleMessage(allocator, "spore vm {s}: internal control socket path collision", .{command}),
        ),
        else => allocLifecycleMessage(allocator, "spore vm {s}: runtime directory error: {s}", .{ command, @errorName(err) }),
    };
    exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
}

fn validateNameOrExit(command: []const u8, name: []const u8) !void {
    validateName(name) catch {
        if (exec_cli_event_writer) |events| {
            var buf: [512]u8 = undefined;
            const message = std.fmt.bufPrint(&buf, "spore vm {s}: invalid VM name: {s}", .{ command, name }) catch "spore vm exec: invalid VM name";
            const classified = machine_output.usageInvalidArgument(message, command);
            events.emitFailure(classified) catch {};
            std.process.exit(classified.exit_code);
        }
        std.debug.print("spore vm {s}: invalid VM name: {s}\n", .{ command, name });
        std.process.exit(2);
    };
}

fn validateNameLifecycleCli(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    name: []const u8,
) void {
    validateName(name) catch {
        const message = allocLifecycleMessage(allocator, "spore vm {s}: invalid VM name: {s}", .{ command, name });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
    };
}

fn takeValueLifecycleCli(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    args: []const []const u8,
    i: *usize,
    flag: []const u8,
) []const u8 {
    if (i.* + 1 >= args.len) {
        const message = allocLifecycleMessage(allocator, "{s} requires a value", .{flag});
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageMissingArgument(message, command), message);
    }
    i.* += 1;
    return args[i.*];
}

fn parseIntArgLifecycleCli(
    comptime T: type,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    raw: []const u8,
    flag: []const u8,
) T {
    return std.fmt.parseInt(T, raw, 10) catch {
        const message = allocLifecycleMessage(allocator, "{s} must be an integer", .{flag});
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
    };
}

fn parseDurationArgLifecycleCli(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    raw: []const u8,
    flag: []const u8,
) u64 {
    return cli_args.parseDurationMs(raw) catch {
        const message = allocLifecycleMessage(allocator, "{s} expects a duration like 30s, 500ms, or 1m", .{flag});
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
    };
}

fn parseVcpuCountLifecycleCli(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    raw: []const u8,
    flag: []const u8,
) topology.VcpuCount {
    return topology.parseVcpuCount(raw) catch {
        const message = allocLifecycleMessage(allocator, "{s} must be an integer from 1 to {d}", .{ flag, topology.max_vcpus });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
    };
}

test "create parser separates initial and maximum memory" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    const default_opts = try parseCreateArgs(&.{"bench-1"}, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(memory_config.default_bytes, default_opts.spec.memory.initial_bytes);
    try std.testing.expectEqual(memory_config.default_bytes, default_opts.spec.memory.maximum_bytes);

    const fixed_opts = try parseCreateArgs(&.{ "bench-1", "--memory", "2gb" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024 * 1024), fixed_opts.spec.memory.initial_bytes);
    try std.testing.expectEqual(fixed_opts.spec.memory.initial_bytes, fixed_opts.spec.memory.maximum_bytes);

    const elastic_opts = try parseCreateArgs(&.{ "bench-1", "--max-memory", "16gb" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(memory_config.default_bytes, elastic_opts.spec.memory.initial_bytes);
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024 * 1024), elastic_opts.spec.memory.maximum_bytes);
}

test "create parser accepts shell and exact commands" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    const shell_opts = try parseCreateArgs(&.{ "counter", "--image", "alpine:3.20", "--shell", "echo hi" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(cli_args.CommandMode.shell, shell_opts.command_mode);
    try std.testing.expectEqual(@as(usize, 1), shell_opts.command.len);
    try std.testing.expectEqualStrings("echo hi", shell_opts.command[0]);

    const argv_opts = try parseCreateArgs(&.{ "counter", "--", "/bin/echo", "hi" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(cli_args.CommandMode.argv, argv_opts.command_mode);
    try std.testing.expectEqual(@as(usize, 2), argv_opts.command.len);
    try std.testing.expectEqualStrings("/bin/echo", argv_opts.command[0]);
    try std.testing.expectEqualStrings("hi", argv_opts.command[1]);
}

test "create parser defaults to retained initial output and accepts discard" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    const retained = try parseCreateArgs(&.{ "counter", "--", "/bin/true" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(InitialOutputDisposition.retain, retained.initial_output);

    const discarded = try parseCreateArgs(&.{ "counter", "--initial-output", "discard", "--", "/bin/true" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(InitialOutputDisposition.discard, discarded.initial_output);
}

test "create parser keeps image and plain creates commandless" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    const image = try parseCreateArgs(&.{ "counter", "--image", "alpine:3.20" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(@as(usize, 0), image.command.len);
    const idle = try parseCreateArgs(&.{"counter"}, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(@as(usize, 0), idle.command.len);
}

test "exec parser accepts shell and exact commands" {
    const shell_opts = parseExecArgs(&.{ "counter", "--shell", "cat /tick" });
    try std.testing.expectEqualStrings("counter", shell_opts.name);
    try std.testing.expectEqual(cli_args.CommandMode.shell, shell_opts.command_mode);
    try std.testing.expectEqual(@as(usize, 1), shell_opts.command.len);
    try std.testing.expectEqualStrings("cat /tick", shell_opts.command[0]);
    try std.testing.expect(!shell_opts.interactive);
    try std.testing.expect(!shell_opts.tty);

    const argv_opts = parseExecArgs(&.{ "counter", "--", "/bin/cat", "/tick" });
    try std.testing.expectEqual(cli_args.CommandMode.argv, argv_opts.command_mode);
    try std.testing.expectEqual(@as(usize, 2), argv_opts.command.len);
    try std.testing.expectEqualStrings("/bin/cat", argv_opts.command[0]);
    try std.testing.expectEqualStrings("/tick", argv_opts.command[1]);

    const hyphen_shell_opts = parseExecArgs(&.{ "counter", "--shell", "-c test" });
    try std.testing.expectEqual(cli_args.CommandMode.shell, hyphen_shell_opts.command_mode);
    try std.testing.expectEqualStrings("-c test", hyphen_shell_opts.command[0]);
}

test "exec parser accepts interactive and tty flags" {
    const combined_opts = parseExecArgs(&.{ "--env", "CLEAR_ME=", "--env", "HOST_VALUE", "--workdir", "/app", "-it", "box", "--", "/bin/sh" });
    try std.testing.expectEqualStrings("box", combined_opts.name);
    try std.testing.expectEqual(cli_args.CommandMode.argv, combined_opts.command_mode);
    try std.testing.expect(combined_opts.interactive);
    try std.testing.expect(combined_opts.tty);
    try std.testing.expectEqualStrings("/bin/sh", combined_opts.command[0]);
    try std.testing.expectEqual(@as(usize, 2), combined_opts.guest_env_specs.len);
    try std.testing.expectEqualStrings("CLEAR_ME=", combined_opts.guest_env_specs.items[0].literal);
    try std.testing.expectEqualStrings("HOST_VALUE", combined_opts.guest_env_specs.items[1].copy);
    try std.testing.expectEqualStrings("/app", combined_opts.guest_working_dir.?);

    const long_opts = parseExecArgs(&.{ "box", "--interactive", "--tty", "--shell", "cat" });
    try std.testing.expectEqualStrings("box", long_opts.name);
    try std.testing.expectEqual(cli_args.CommandMode.shell, long_opts.command_mode);
    try std.testing.expect(long_opts.interactive);
    try std.testing.expect(long_opts.tty);
    try std.testing.expectEqualStrings("cat", long_opts.command[0]);
}

test "create parser accepts bounded vcpu count" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    const opts = try parseCreateArgs(&.{ "bench-1", "--vcpus", "2" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(@as(topology.VcpuCount, 2), opts.spec.vcpus);
}

test "create parser accepts flexible timeout duration" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    const opts = try parseCreateArgs(&.{ "bench-1", "--timeout", "120s" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(@as(u64, 120_000), opts.spec.timeout_ms);
}

test "create parser accepts hidden timeout-ms compatibility spelling" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    const opts = try parseCreateArgs(&.{ "bench-1", "--timeout-ms", "120000" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(@as(u64, 120_000), opts.spec.timeout_ms);
}

test "create parser accepts image pull policy" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    const default_opts = try parseCreateArgs(&.{ "bench-1", "--image", "docker.io/library/alpine:3.20" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(rootfs_input.PullPolicy.missing, default_opts.image_pull_policy);

    const equals_opts = try parseCreateArgs(&.{ "bench-1", "--pull=always", "--image", "docker.io/library/alpine:3.20" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(rootfs_input.PullPolicy.always, equals_opts.image_pull_policy);

    const value_opts = try parseCreateArgs(&.{ "bench-1", "--image", "docker.io/library/alpine:3.20", "--pull", "never" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(rootfs_input.PullPolicy.never, value_opts.image_pull_policy);
}

test "create parser accepts network allow policy" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    const opts = try parseCreateArgs(&.{
        "bench-1",
        "--net",
        "--allow-cidr",
        "93.184.216.34/32",
        "--allow-host",
        "example.com",
        "--forward",
        "127.0.0.1:8080:80",
    }, allocator, &stderr.writer, .human);

    const policy = &opts.network.spore;
    try std.testing.expect(policy.egress == .allowlist);
    try std.testing.expectEqual(@as(usize, 1), policy.allowCidrSlice().len);
    try std.testing.expectEqualStrings("93.184.216.34/32", policy.allowCidrSlice()[0]);
    try std.testing.expectEqual(@as(usize, 1), policy.allowHostSlice().len);
    try std.testing.expectEqualStrings("example.com", policy.allowHostSlice()[0]);
    try std.testing.expectEqual(@as(usize, 1), policy.portForwardSlice().len);
    try std.testing.expectEqual(@as(u16, 8080), policy.portForwardSlice()[0].host_port);
    try std.testing.expectEqual(@as(u16, 80), policy.portForwardSlice()[0].guest_port);
}

test "create parser accepts annotations exact host ports and bound services" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    var opts = try parseCreateArgs(&.{
        "bench-1",
        "--net",
        "--annotation",
        "cleanroom.stage=compile=fast",
        "--allow-host-port",
        "github.com:443",
        "--bind-service",
        "metadata:8170=unix:/tmp/metadata.sock",
    }, allocator, &stderr.writer, .human);
    defer opts.spec.annotations.deinit(allocator);

    try std.testing.expectEqualStrings("compile=fast", opts.spec.annotations.map.get("cleanroom.stage").?);
    const policy = &opts.network.spore;
    try std.testing.expectEqual(@as(usize, 1), policy.exactRuleSlice().len);
    try std.testing.expectEqualStrings("github.com", policy.exactRuleSlice()[0].host);
    try std.testing.expectEqual(@as(u16, 443), policy.exactRuleSlice()[0].ports[0]);
    const services = policy.boundServiceSlice();
    try std.testing.expectEqual(@as(usize, 1), services.len);
    try std.testing.expectEqualStrings("metadata", services[0].name);
    try std.testing.expectEqualStrings("metadata.spore.internal", services[0].guest_host);
    try std.testing.expectEqual(@as(u16, 8170), services[0].guest_port);
    try std.testing.expectEqualStrings("/tmp/metadata.sock", services[0].unix_path);
}

test "create options file maps to create options" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = CreateOptions{ .spec = .{ .name = "bench-1" } };
    const opts = try parseCreateOptionsFile(arena, base,
        \\{
        \\  "schema_version": 1,
        \\  "image": "docker.io/library/alpine:3.20",
        \\  "memory": "512mb",
        \\  "vcpus": 2,
        \\  "timeout_ms": 120000,
        \\  "network": {
        \\    "enabled": true,
        \\    "allow_cidrs": ["93.184.216.34/32"],
        \\    "allow_hosts": ["example.com"],
        \\    "network_rules": [{"host": "github.com", "ports": [443]}],
        \\    "bound_services": [{"name": "metadata", "guest_host": "metadata.cleanroom.internal", "guest_port": 8170, "unix_path": "/tmp/metadata.sock"}]
        \\  },
        \\  "annotations": {"cleanroom.stage": "compile"}
        \\}
    );

    try std.testing.expectEqualStrings("docker.io/library/alpine:3.20", opts.spec.image_ref.?);
    try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), opts.spec.memory.initial_bytes);
    try std.testing.expectEqual(opts.spec.memory.initial_bytes, opts.spec.memory.maximum_bytes);
    try std.testing.expectEqual(@as(topology.VcpuCount, 2), opts.spec.vcpus);
    try std.testing.expectEqual(@as(u64, 120_000), opts.spec.timeout_ms);
    const policy = &opts.network.spore;
    try std.testing.expect(policy.egress == .allowlist);
    try std.testing.expectEqualStrings("93.184.216.34/32", policy.allowCidrSlice()[0]);
    try std.testing.expectEqualStrings("example.com", policy.allowHostSlice()[0]);
    try std.testing.expectEqualStrings("github.com", policy.exactRuleSlice()[0].host);
    try std.testing.expectEqual(@as(u16, 443), policy.exactRuleSlice()[0].ports[0]);
    const services = policy.boundServiceSlice();
    try std.testing.expectEqualStrings("metadata", services[0].name);
    try std.testing.expectEqualStrings("metadata.cleanroom.internal", services[0].guest_host);
    try std.testing.expectEqual(@as(u16, 8170), services[0].guest_port);
    try std.testing.expectEqualStrings("/tmp/metadata.sock", services[0].unix_path);
    try std.testing.expectEqualStrings("compile", opts.spec.annotations.map.get("cleanroom.stage").?);
}

test "create options file rejects invalid contract inputs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = CreateOptions{ .spec = .{ .name = "bench-1" } };
    try std.testing.expectError(error.UnknownField, parseCreateOptionsFile(arena, base, "{\"schema_version\":1,\"image_ref\":\"alpine\"}"));
    try std.testing.expectError(error.UnsupportedOptionsFile, parseCreateOptionsFile(arena, base, "{\"schema_version\":2}"));
    try std.testing.expectError(error.ConflictingOptions, parseCreateOptionsFile(arena, base, "{\"schema_version\":1,\"name\":\"other\"}"));
    try std.testing.expectError(error.InvalidPullPolicy, parseCreateOptionsFile(arena, base, "{\"schema_version\":1,\"pull\":\"always\"}"));
}

fn fuzzCreateOptionsFile(_: void, s: *std.testing.Smith) !void {
    var buf: [4096]u8 = undefined;
    const len = s.slice(&buf);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const base = CreateOptions{ .spec = .{ .name = "bench-1" } };
    _ = parseCreateOptionsFile(arena_state.allocator(), base, buf[0..len]) catch return;
}

test "fuzz create options file parsing" {
    try std.testing.fuzz({}, fuzzCreateOptionsFile, .{});
}

test "create cli keeps plain --net unrestricted and allow rules restrict egress" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stderr: Io.Writer.Allocating = .init(arena);

    const plain = try parseCreateArgs(&.{ "bench-1", "--net" }, arena, &stderr.writer, .human);
    try std.testing.expect(plain.network.spore.egress == .unrestricted);
    try std.testing.expect(!plain.network.spore.hasRules());

    const exact = try parseCreateArgs(&.{ "bench-1", "--net", "--allow-host-port", "github.com:443" }, arena, &stderr.writer, .human);
    try std.testing.expect(exact.network.spore.egress == .allowlist);
    try std.testing.expectEqualStrings("github.com", exact.network.spore.exactRuleSlice()[0].host);

    const disabled = try parseCreateArgs(&.{"bench-1"}, arena, &stderr.writer, .human);
    try std.testing.expectEqual(spore_net_policy.NetworkMode.disabled, disabled.network);
}

test "save parser accepts annotations and stop" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    var opts = parseSaveArgs(&.{ "bench-1", "--output", "bench-1.spore", "--stop", "--annotation", "saved=true=1" }, allocator, &stderr.writer, .human);
    defer opts.annotations.deinit(allocator);
    try std.testing.expectEqualStrings("bench-1", opts.name);
    try std.testing.expectEqualStrings("bench-1.spore", opts.out_dir);
    try std.testing.expect(opts.stop);
    try std.testing.expectEqualStrings("true=1", opts.annotations.map.get("saved").?);
}

test "named restore parser accepts bound service bindings" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    const opts = parseRestoreArgs(&.{ "bench-2", "--checkpoint", "bench-1.spore", "--bind-service", "metadata=unix:/tmp/metadata.sock" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqualStrings("bench-1.spore", opts.spore_dir);
    try std.testing.expectEqualStrings("bench-2", opts.name);
    try std.testing.expectEqual(@as(usize, 1), opts.bound_services.len);
    try std.testing.expectEqualStrings("metadata", opts.bound_services.items[0].name);
    try std.testing.expectEqualStrings("/tmp/metadata.sock", opts.bound_services.items[0].target.unix);
}

test "named restore parser accepts k8s child command product flags" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    const opts = parseRestoreArgs(&.{ "--backend", "kvm", "--generation", "generation.json", "--checkpoint", "child.spore", "sporevm-child-42" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(backend_mod.Backend.kvm, opts.backend.?);
    try std.testing.expectEqualStrings("generation.json", opts.generation_path.?);
    try std.testing.expectEqualStrings("child.spore", opts.spore_dir);
    try std.testing.expectEqualStrings("sporevm-child-42", opts.name);
}

test "lifecycle list entries render human table" {
    const allocator = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const stale_memory = listMemoryFromConfig(memory_config.Config.fixed(512 * 1024 * 1024));
    try writeListEntries(&out.writer, &.{
        .{
            .name = "a-ready",
            .state = "ready",
            .pid = 42,
            .memory = listMemoryFromConfig(.{ .initial_bytes = 512 * 1024 * 1024, .maximum_bytes = 16 * 1024 * 1024 * 1024 }),
            .stats = .{
                .resident_bytes = 184 * 1024 * 1024,
                .backing_logical_bytes = 16 * 1024 * 1024 * 1024,
                .backing_allocated_bytes = 34 * 1024 * 1024,
                .chunks_total = 8192,
                .chunks_nonzero = 17,
                .dirty_chunks_pending = 2,
            },
        },
        .{
            .name = "b-stale",
            .state = "stale",
            .pid = null,
            .memory = stale_memory,
            .stats = listStatsFromMemory(stale_memory),
        },
    });
    try std.testing.expectEqualStrings(
        "NAME\tSTATE\tPID\tMEMORY\tRESIDENT\tBACKING\tCHUNKS\tDIRTY\n" ++
            "a-ready\tready\t42\t512MiB→16GiB\t184MiB\t34MiB/16GiB\t17/8192\t2\n" ++
            "b-stale\tstale\t-\t512MiB\t?\t?\t?/256\t?\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    try writeListEntries(&out.writer, &.{});
    try std.testing.expectEqualStrings("No VMs\n", out.written());
}

test "lifecycle human results render terse status lines" {
    const allocator = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeNamedLifecycleResult(&out.writer, .{
        .action = "created",
        .name = "counter",
        .state = "ready",
    });
    try std.testing.expectEqualStrings("created live VM counter\n", out.written());

    out.clearRetainingCapacity();
    try writeNamedLifecycleResult(&out.writer, .{
        .action = "created",
        .name = "counter",
        .state = "ready",
        .initial_command = .{
            .output_disposition = .retain,
            .output_destination = .named_logs,
            .output_limit_bytes_per_stream = initial_output_limit_bytes_per_stream,
        },
    });
    try std.testing.expectEqualStrings(
        "created live VM counter\n" ++
            "initial command started; output retained up to 16381 bytes per stream; retrieve with `spore vm logs counter --initial`\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    try writeNamedLifecycleResult(&out.writer, .{
        .action = "saved",
        .name = "counter",
        .state = "ready",
        .spore_dir = "counter.spore",
    });
    try std.testing.expectEqualStrings("saved checkpoint counter.spore (portable-self-contained); live VM counter is still running\n", out.written());

    out.clearRetainingCapacity();
    try writeNamedLifecycleResult(&out.writer, .{
        .action = "saved_stopped",
        .name = "counter",
        .state = "stopped",
        .spore_dir = "counter.spore",
    });
    try std.testing.expectEqualStrings(
        "saved checkpoint counter.spore (portable-self-contained) and stopped live VM counter\n" ++
            "checkpoint has no saved session; use `spore run --checkpoint <checkpoint> ...` to run new commands, or `spore run --save-checkpoint <checkpoint> --save-on TERM ...` if you want fanout to attach to the original command.\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    try writeNamedLifecycleResult(&out.writer, .{
        .action = "saved_stopped",
        .name = "counter",
        .state = "stopped",
        .spore_dir = "counter.spore",
        .saved_sessions = 1,
    });
    try std.testing.expectEqualStrings(
        "saved checkpoint counter.spore (portable-self-contained) and stopped live VM counter\n" ++
            "checkpoint has a saved session; use `spore checkpoint resume <checkpoint>` to reconnect, or `spore run --checkpoint <checkpoint> ...` to run new commands.\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    try writeNamedForkResult(&out.writer, .{
        .source = "counter",
        .count = 2,
        .children = &.{ "child-0", "child-1" },
    });
    try std.testing.expectEqualStrings("forked live VM children: child-0 child-1\n", out.written());
}
