//! Named VM lifecycle registry and CLI shape.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;

const local_paths = @import("local_paths.zig");
const machine_output = @import("machine_output.zig");
const memory_config = @import("memory.zig");
const run_mod = @import("run.zig");
const spore = @import("spore.zig");

pub const runtime_dir_env = local_paths.runtime_dir_env;
pub const max_name_len = 128;

const max_metadata_bytes = 64 * 1024;
const max_control_response = 128 * 1024;
const lifecycle_spore_metadata_file = "sporevm-lifecycle.json";
const diskless_resume_device_count = 4;
const spec_file = "spec.json";
const ready_file = "ready.json";
const create_timing_file = "create-timing.json";
const monitor_timing_file = "monitor-timing.json";
const pid_file = "pid";
const control_socket_file = "control.sock";
const console_log_file = "console.log";
const private_dir_permissions: Io.File.Permissions = if (builtin.os.tag == .windows)
    .default_dir
else
    @enumFromInt(0o700);

const create_usage =
    \\Usage:
    \\  spore create NAME [options]
    \\
    \\Options:
    \\  --backend auto|hvf|kvm  Backend to run (default: auto)
    \\  --kernel Image          Kernel Image path
    \\  --initrd root.cpio      Initrd path (default: embedded minimal exec initrd)
    \\  --rootfs rootfs.ext4    Attach rootfs image read-only as virtio-blk
    \\  --image REF             Build or reuse cached OCI rootfs
    \\  --memory VALUE          Guest memory: auto, 512mb, 2gb, ... (default: auto = 16GiB)
    \\  --vcpus N               Guest vCPU count; must be 1 today
    \\  --guest-port N          Guest vsock listen port (default: 10700)
    \\  --timeout-ms N          Exec timeout in milliseconds (default: 30000)
    \\  --console-log PATH      Write guest console output to PATH
    \\  -h, --help              Show this help
    \\
;

const exec_usage =
    \\Usage:
    \\  spore exec NAME -- <argv...>
    \\
    \\Options:
    \\  -h, --help              Show this help
    \\
;

const rm_usage =
    \\Usage:
    \\  spore rm NAME
    \\
    \\Options:
    \\  -h, --help              Show this help
    \\
;

const suspend_usage =
    \\Usage:
    \\  spore suspend NAME --out DIR
    \\
    \\Options:
    \\  --out DIR              Write a spore checkpoint to DIR
    \\  -h, --help             Show this help
    \\
;

const resume_usage =
    \\Usage:
    \\  spore resume DIR --name NAME
    \\
    \\Options:
    \\  --name NAME            Name for the resumed VM
    \\  -h, --help             Show this help
    \\
;

const ls_usage =
    \\Usage:
    \\  spore ls
    \\
    \\Options:
    \\  -h, --help              Show this help
    \\
    \\Machine output:
    \\  spore --json ls         Emit the VM list as JSON
    \\
;

pub const Paths = struct {
    runtime_root: []const u8,
    vms_dir: []const u8,
    vm_dir: []const u8,
    spec_path: []const u8,
    ready_path: []const u8,
    create_timing_path: []const u8,
    monitor_timing_path: []const u8,
    pid_path: []const u8,
    control_socket_path: []const u8,
    console_log_path: []const u8,

    pub fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_root);
        allocator.free(self.vms_dir);
        allocator.free(self.vm_dir);
        allocator.free(self.spec_path);
        allocator.free(self.ready_path);
        allocator.free(self.create_timing_path);
        allocator.free(self.monitor_timing_path);
        allocator.free(self.pid_path);
        allocator.free(self.control_socket_path);
        allocator.free(self.console_log_path);
    }
};

pub const Spec = struct {
    name: []const u8,
    backend: []const u8 = "auto",
    kernel_path: ?[]const u8 = null,
    initrd_path: ?[]const u8 = null,
    rootfs_path: ?[]const u8 = null,
    rootfs: ?spore.Rootfs = null,
    disk: ?spore.Disk = null,
    image_ref: ?[]const u8 = null,
    resume_dir: ?[]const u8 = null,
    memory: memory_config.Config = .{},
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    console_log_path: ?[]const u8 = null,
};

pub const Ready = struct {
    pid: i64,
    control_socket_path: []const u8,
    console_log_path: []const u8,
};

pub const CreateTiming = struct {
    version: u32 = 1,
    parse_ms: u64,
    paths_ms: u64,
    state_check_ms: u64,
    rootfs_resolve_ms: u64,
    rootfs_abspath_ms: u64,
    spawn_monitor_ms: u64,
    wait_ready_ms: u64,
    total_ms: u64,
};

pub const MonitorTiming = struct {
    version: u32 = 1,
    parse_ms: u64,
    paths_ms: u64,
    asset_resolve_ms: u64,
    metadata_ms: u64,
    ready_after_start_ms: u64,
};

pub const VmState = enum {
    absent,
    incomplete,
    ready,
    stale,

    pub fn name(self: VmState) []const u8 {
        return switch (self) {
            .absent => "absent",
            .incomplete => "incomplete",
            .ready => "ready",
            .stale => "stale",
        };
    }
};

pub const ListEntry = struct {
    name: []const u8,
    state: []const u8,
    pid: ?i64 = null,
};

pub const lifecycle_schema = "spore.lifecycle.v1";
pub const lifecycle_schema_version: u32 = 1;

pub const LifecycleResult = struct {
    schema: []const u8 = lifecycle_schema,
    schema_version: u32 = lifecycle_schema_version,
    action: []const u8,
    name: []const u8,
    state: []const u8,
    pid: ?i64 = null,
    control_socket_path: ?[]const u8 = null,
    console_log_path: ?[]const u8 = null,
    spore_dir: ?[]const u8 = null,
};

const CreateOptions = struct {
    spec: Spec,
};

const ExecOptions = struct {
    name: []const u8,
    command: []const []const u8,
};

const SuspendOptions = struct {
    name: []const u8,
    out_dir: []const u8,
};

const ResumeOptions = struct {
    spore_dir: []const u8,
    name: []const u8,
};

pub fn createCli(
    init: std.process.Init,
    args: []const []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) !void {
    const start_ms = monotonicMs();
    if (wantsHelp(args)) {
        if (mode == .json) {
            exitLifecycleCliError(
                init.arena.allocator(),
                stderr,
                mode,
                machine_output.usageInvalidArgument("spore --json create does not support help output", "create"),
                "spore --json create does not support help output",
            );
        }
        try stdout.writeAll(create_usage);
        return;
    }
    if (args.len == 0) {
        exitLifecycleCliError(
            init.arena.allocator(),
            stderr,
            mode,
            machine_output.usageMissingArgument("usage: spore create NAME [options]", "create"),
            create_usage,
        );
    }

    const allocator = init.arena.allocator();
    const parsed = try parseCreateArgs(args, allocator, stderr, mode);
    const parsed_ms = monotonicMs();
    var spec = parsed.spec;
    const paths = try cliPaths(init, allocator, "create", spec.name);
    const paths_ms = monotonicMs();
    if (!monitorBackendSupported(spec.backend)) {
        const message = "spore create: monitor mode requires HVF on Apple Silicon or KVM on Linux/aarch64";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.host_unsupported, message, "create"), message);
    }
    const state = try classifyVmState(allocator, init.io, paths, pidAlive);
    if (state != .absent) {
        const message = allocLifecycleMessage(allocator, "spore create: VM already exists or has stale state: {s}", .{spec.name});
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
    }
    const state_checked_ms = monotonicMs();
    const rootfs_resolution = try run_mod.resolveRootfsInputDetailedResult(init, allocator, .{
        .rootfs_path = spec.rootfs_path,
        .image_ref = spec.image_ref,
        .command_name = "create",
        .record_artifact = spec.image_ref != null,
    });
    const resolved_rootfs = switch (rootfs_resolution) {
        .resolved => |rootfs| rootfs,
        .failure => |failure| exitLifecycleCliError(allocator, stderr, mode, failure, failure.message),
    };
    const rootfs_resolved_ms = monotonicMs();
    spec.rootfs_path = if (resolved_rootfs.path) |path| try std.fs.path.resolve(allocator, &.{path}) else null;
    spec.rootfs = resolved_rootfs.rootfs;
    const rootfs_abspath_ms = monotonicMs();
    if (spec.rootfs != null) try writeSpec(allocator, init.io, paths, spec);
    try spawnMonitor(init, allocator, spec);
    const monitor_spawned_ms = monotonicMs();
    try waitForReady("create", allocator, init.io, paths, spec.timeout_ms);
    const ready_ms = monotonicMs();
    writeCreateTiming(allocator, init.io, paths, .{
        .parse_ms = parsed_ms - start_ms,
        .paths_ms = paths_ms - parsed_ms,
        .state_check_ms = state_checked_ms - paths_ms,
        .rootfs_resolve_ms = rootfs_resolved_ms - state_checked_ms,
        .rootfs_abspath_ms = rootfs_abspath_ms - rootfs_resolved_ms,
        .spawn_monitor_ms = monitor_spawned_ms - rootfs_abspath_ms,
        .wait_ready_ms = ready_ms - monitor_spawned_ms,
        .total_ms = ready_ms - start_ms,
    }) catch {};
    if (mode == .json) {
        var ready = try readReady(allocator, init.io, paths);
        defer ready.deinit();
        try machine_output.writeJson(allocator, stdout, LifecycleResult{
            .action = "created",
            .name = spec.name,
            .state = "ready",
            .pid = ready.value.pid,
            .control_socket_path = ready.value.control_socket_path,
            .console_log_path = ready.value.console_log_path,
        });
    }
}

pub fn execCli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (wantsHelp(args)) {
        try stdout.writeAll(exec_usage);
        return;
    }
    const parsed = parseExecArgs(args);
    const allocator = init.arena.allocator();
    const paths = try cliPaths(init, allocator, "exec", parsed.name);
    const state = try classifyVmState(allocator, init.io, paths, pidAlive);
    if (state != .ready) {
        std.debug.print("spore exec: VM is not ready: {s} ({s})\n", .{ parsed.name, state.name() });
        std.process.exit(2);
    }
    var ready = lifecycleReadyOrExit(allocator, init.io, "exec", paths);
    defer ready.deinit();
    const response = sendExecRequest(allocator, init.io, ready.value.control_socket_path, parsed.command) catch |err| {
        switch (err) {
            error.MonitorUnavailable => std.debug.print("spore exec: monitor is unavailable for VM: {s}\n", .{parsed.name}),
            else => std.debug.print("spore exec: monitor request failed for VM {s}: {s}\n", .{ parsed.name, @errorName(err) }),
        }
        std.process.exit(1);
    };
    const code = try handleExecResponse(init, allocator, stdout, response);
    if (code != 0) std.process.exit(code);
}

pub fn rmCli(
    init: std.process.Init,
    args: []const []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) !void {
    if (wantsHelp(args)) {
        if (mode == .json) {
            exitLifecycleCliError(
                init.arena.allocator(),
                stderr,
                mode,
                machine_output.usageInvalidArgument("spore --json rm does not support help output", "rm"),
                "spore --json rm does not support help output",
            );
        }
        try stdout.writeAll(rm_usage);
        return;
    }
    const allocator = init.arena.allocator();
    const name = parseRmArgs(args, allocator, stderr, mode);
    const paths = try cliPaths(init, allocator, "rm", name);
    const state = try classifyVmState(allocator, init.io, paths, pidAlive);
    var removed_pid: ?i64 = null;
    switch (state) {
        .absent => {
            const message = allocLifecycleMessage(allocator, "spore rm: VM not found: {s}", .{name});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_not_found, message, "rm"), message);
        },
        .ready => {
            var ready = lifecycleReadyOrExit(allocator, init.io, "rm", paths);
            defer ready.deinit();
            removed_pid = ready.value.pid;
            _ = sendShutdownRequest(allocator, init.io, ready.value.control_socket_path) catch {};
            waitForPidExit(ready.value.pid, 5_000);
            try Io.Dir.cwd().deleteTree(init.io, paths.vm_dir);
        },
        .incomplete, .stale => {
            removed_pid = readPid(allocator, init.io, paths) catch null;
            try Io.Dir.cwd().deleteTree(init.io, paths.vm_dir);
        },
    }
    if (mode == .json) {
        try machine_output.writeJson(allocator, stdout, LifecycleResult{
            .action = "removed",
            .name = name,
            .state = "absent",
            .pid = removed_pid,
        });
    }
}

pub fn suspendCli(
    init: std.process.Init,
    args: []const []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) !void {
    if (wantsHelp(args)) {
        if (mode == .json) {
            exitLifecycleCliError(
                init.arena.allocator(),
                stderr,
                mode,
                machine_output.usageInvalidArgument("spore --json suspend does not support help output", "suspend"),
                "spore --json suspend does not support help output",
            );
        }
        try stdout.writeAll(suspend_usage);
        return;
    }
    const allocator = init.arena.allocator();
    const parsed = parseSuspendArgs(args, allocator, stderr, mode);
    const out_dir = resolveNewOutputDir(allocator, init.io, stderr, mode, "suspend", parsed.out_dir);
    const paths = try cliPaths(init, allocator, "suspend", parsed.name);
    const state = try classifyVmState(allocator, init.io, paths, pidAlive);
    if (state != .ready) {
        const message = allocLifecycleMessage(allocator, "spore suspend: VM is not ready: {s} ({s})", .{ parsed.name, state.name() });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "suspend"), message);
    }
    var spec = readSpec(allocator, init.io, paths) catch {
        const message = "spore suspend: VM is not ready";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "suspend"), message);
    };
    defer spec.deinit();
    if ((spec.value.rootfs_path != null or spec.value.image_ref != null) and spec.value.rootfs == null) {
        const message = "spore suspend: disk-backed lifecycle suspend requires an image-created VM";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "suspend"), message);
    }
    var ready = readReady(allocator, init.io, paths) catch {
        const message = "spore suspend: VM is not ready";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "suspend"), message);
    };
    defer ready.deinit();
    const response = sendSuspendRequest(allocator, init.io, ready.value.control_socket_path, out_dir) catch |err| {
        const message = switch (err) {
            error.MonitorUnavailable => allocLifecycleMessage(allocator, "spore suspend: monitor is unavailable for VM: {s}", .{parsed.name}),
            else => allocLifecycleMessage(allocator, "spore suspend: monitor request failed for VM {s}: {s}", .{ parsed.name, @errorName(err) }),
        };
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_execution_failed, message, "suspend"), message);
    };
    if (try suspendResponseFailureMessage(allocator, response)) |response_message| {
        const message = allocLifecycleMessage(allocator, "spore suspend: {s}", .{response_message});
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_execution_failed, message, "suspend"), message);
    }
    var cleanup_after_suspend = true;
    defer if (cleanup_after_suspend) {
        waitForPidExit(ready.value.pid, 5_000);
        Io.Dir.cwd().deleteTree(init.io, paths.vm_dir) catch {};
    };
    try writeSporeLifecycleSpec(allocator, init.io, out_dir, spec.value);
    cleanup_after_suspend = false;
    waitForPidExit(ready.value.pid, 5_000);
    try Io.Dir.cwd().deleteTree(init.io, paths.vm_dir);
    if (mode == .json) {
        try machine_output.writeJson(allocator, stdout, LifecycleResult{
            .action = "suspended",
            .name = parsed.name,
            .state = "checkpointed",
            .pid = ready.value.pid,
            .spore_dir = out_dir,
        });
    }
}

pub fn resumeCli(
    init: std.process.Init,
    args: []const []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) !void {
    if (wantsHelp(args)) {
        if (mode == .json) {
            exitLifecycleCliError(
                init.arena.allocator(),
                stderr,
                mode,
                machine_output.usageInvalidArgument("spore --json resume does not support help output", "resume"),
                "spore --json resume does not support help output",
            );
        }
        try stdout.writeAll(resume_usage);
        return;
    }
    const allocator = init.arena.allocator();
    const parsed = parseResumeArgs(args, allocator, stderr, mode);
    const spore_dir = resolveExistingSporeDir(allocator, init.io, stderr, mode, "resume", parsed.spore_dir);
    var manifest = spore.loadManifest(allocator, spore_dir) catch |err| {
        const message = allocLifecycleMessage(allocator, "spore resume: invalid spore directory {s}: {s}", .{ spore_dir, @errorName(err) });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "resume"), message);
    };
    defer manifest.deinit();
    if (manifest.value.network != null) {
        const message = "spore resume: named lifecycle networking is not supported yet; use spore run --from for one-shot network resumes";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "resume"), message);
    }
    const rootfs = try run_mod.resumeRootfsForRun(allocator, manifest.value);
    const disk = try run_mod.resumeDiskForRun(allocator, manifest.value);
    if (rootfs == null and manifest.value.devices.len != diskless_resume_device_count) {
        const message = "spore resume: unsupported lifecycle device model";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "resume"), message);
    }
    const memory = memoryFromManifest(manifest.value) catch {
        const message = "spore resume: invalid spore memory size";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "resume"), message);
    };

    var lifecycle_spec = readSporeLifecycleSpec(allocator, init.io, spore_dir) catch |err| {
        const message = allocLifecycleMessage(allocator, "spore resume: invalid lifecycle metadata: {s}", .{@errorName(err)});
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "resume"), message);
    };
    defer if (lifecycle_spec) |*spec| spec.deinit();
    if (lifecycle_spec) |spec| {
        if (spec.value.vcpus != 1) {
            const message = "spore resume: multi-vCPU lifecycle metadata is not supported yet";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "resume"), message);
        }
    }

    const base = if (lifecycle_spec) |spec| spec.value else Spec{ .name = parsed.name };
    const spec = Spec{
        .name = parsed.name,
        .backend = base.backend,
        .kernel_path = base.kernel_path,
        .initrd_path = base.initrd_path,
        .resume_dir = spore_dir,
        .rootfs = rootfs,
        .disk = disk,
        .memory = memory,
        .vcpus = 1,
        .guest_port = base.guest_port,
        .timeout_ms = base.timeout_ms,
        .console_log_path = base.console_log_path,
    };
    if (!monitorBackendSupported(spec.backend)) {
        const message = "spore resume: monitor mode requires HVF on Apple Silicon or KVM on Linux/aarch64";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.host_unsupported, message, "resume"), message);
    }
    const paths = try cliPaths(init, allocator, "resume", spec.name);
    const state = try classifyVmState(allocator, init.io, paths, pidAlive);
    if (state != .absent) {
        const message = allocLifecycleMessage(allocator, "spore resume: VM already exists or has stale state: {s}", .{spec.name});
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "resume"), message);
    }
    if (spec.rootfs != null or spec.disk != null) try writeSpec(allocator, init.io, paths, spec);
    try spawnMonitor(init, allocator, spec);
    try waitForReady("resume", allocator, init.io, paths, spec.timeout_ms);
    if (mode == .json) {
        var ready = try readReady(allocator, init.io, paths);
        defer ready.deinit();
        try machine_output.writeJson(allocator, stdout, LifecycleResult{
            .action = "resumed",
            .name = spec.name,
            .state = "ready",
            .pid = ready.value.pid,
            .control_socket_path = ready.value.control_socket_path,
            .console_log_path = ready.value.console_log_path,
            .spore_dir = spore_dir,
        });
    }
}

pub fn lsCli(
    init: std.process.Init,
    args: []const []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) !void {
    if (wantsHelp(args)) {
        if (mode == .json) {
            exitLifecycleCliError(
                init.arena.allocator(),
                stderr,
                mode,
                machine_output.usageInvalidArgument("spore --json ls does not support help output", "ls"),
                "spore --json ls does not support help output",
            );
        }
        try stdout.writeAll(ls_usage);
        return;
    }
    if (args.len != 0) {
        if (args.len == 1 and std.mem.eql(u8, args[0], "--json")) {
            exitLifecycleCliError(
                init.arena.allocator(),
                stderr,
                mode,
                machine_output.usageInvalidArgument("spore ls: use global --json before the command", "ls"),
                "spore ls: use global --json before the command",
            );
        }
        const message = "usage: spore ls";
        exitLifecycleCliError(
            init.arena.allocator(),
            stderr,
            mode,
            machine_output.usageInvalidArgument(message, "ls"),
            ls_usage,
        );
    }

    const allocator = init.arena.allocator();
    const root = runtimeRootPath(allocator, init.environ_map) catch |err| switch (err) {
        error.InvalidRuntimeDir => {
            const message = allocLifecycleMessage(allocator, "spore ls: invalid runtime directory; set {s} or XDG_RUNTIME_DIR to an absolute path", .{runtime_dir_env});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "ls"), message);
        },
        else => |e| return e,
    };
    const entries = listEntries(allocator, init.io, root, pidAlive) catch |err| switch (err) {
        error.InvalidRuntimeDir => {
            const message = "spore ls: invalid runtime directory";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "ls"), message);
        },
        error.InsecureRuntimeDir => {
            const message = "spore ls: insecure runtime directory; registry directories must be private to the current user";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "ls"), message);
        },
        else => |e| return e,
    };
    if (mode == .json) {
        try machine_output.writeJson(allocator, stdout, entries);
    } else {
        try writeListEntries(stdout, entries);
    }
}

fn writeListEntries(writer: *Io.Writer, entries: []const ListEntry) !void {
    if (entries.len == 0) {
        try writer.writeAll("No VMs\n");
        return;
    }

    try writer.writeAll("NAME\tSTATE\tPID\n");
    for (entries) |entry| {
        try writer.print("{s}\t{s}\t", .{ entry.name, entry.state });
        if (entry.pid) |pid| {
            try writer.print("{d}", .{pid});
        } else {
            try writer.writeByte('-');
        }
        try writer.writeByte('\n');
    }
}

pub fn validateName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidVMName;
    if (name.len > max_name_len) return error.InvalidVMName;
    if (!std.ascii.isAlphanumeric(name[0])) return error.InvalidVMName;
    for (name[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return error.InvalidVMName;
    }
}

pub fn runtimeRootPath(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    return local_paths.runtimeRootPath(allocator, environ);
}

pub fn pathsFor(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, name: []const u8) !Paths {
    const root = try runtimeRootPath(allocator, environ);
    defer allocator.free(root);
    return pathsFromRoot(allocator, root, name);
}

pub fn pathsFromRoot(allocator: std.mem.Allocator, runtime_root: []const u8, name: []const u8) !Paths {
    try validateName(name);
    const runtime_root_owned = try allocator.dupe(u8, runtime_root);
    errdefer allocator.free(runtime_root_owned);
    const vms_dir = try std.fs.path.resolve(allocator, &.{ runtime_root, "vms" });
    errdefer allocator.free(vms_dir);
    const vm_dir = try std.fs.path.resolve(allocator, &.{ vms_dir, name });
    errdefer allocator.free(vm_dir);
    const spec_path = try std.fs.path.resolve(allocator, &.{ vm_dir, spec_file });
    errdefer allocator.free(spec_path);
    const ready_path = try std.fs.path.resolve(allocator, &.{ vm_dir, ready_file });
    errdefer allocator.free(ready_path);
    const create_timing_path = try std.fs.path.resolve(allocator, &.{ vm_dir, create_timing_file });
    errdefer allocator.free(create_timing_path);
    const monitor_timing_path = try std.fs.path.resolve(allocator, &.{ vm_dir, monitor_timing_file });
    errdefer allocator.free(monitor_timing_path);
    const pid_path = try std.fs.path.resolve(allocator, &.{ vm_dir, pid_file });
    errdefer allocator.free(pid_path);
    const control_socket_path = try std.fs.path.resolve(allocator, &.{ vm_dir, control_socket_file });
    errdefer allocator.free(control_socket_path);
    const console_log_path = try std.fs.path.resolve(allocator, &.{ vm_dir, console_log_file });
    return .{
        .runtime_root = runtime_root_owned,
        .vms_dir = vms_dir,
        .vm_dir = vm_dir,
        .spec_path = spec_path,
        .ready_path = ready_path,
        .create_timing_path = create_timing_path,
        .monitor_timing_path = monitor_timing_path,
        .pid_path = pid_path,
        .control_socket_path = control_socket_path,
        .console_log_path = console_log_path,
    };
}

pub fn writeSpec(allocator: std.mem.Allocator, io: Io, paths: Paths, spec: Spec) !void {
    try ensureVmDir(io, paths);
    const json = try std.json.Stringify.valueAlloc(allocator, spec, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = paths.spec_path, .data = json });
}

pub fn readSpec(allocator: std.mem.Allocator, io: Io, paths: Paths) !std.json.Parsed(Spec) {
    const data = try Io.Dir.cwd().readFileAlloc(io, paths.spec_path, allocator, .limited(max_metadata_bytes));
    defer allocator.free(data);
    const parsed = try std.json.parseFromSlice(Spec, allocator, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    return parsed;
}

pub fn writeReady(allocator: std.mem.Allocator, io: Io, paths: Paths, ready: Ready) !void {
    try ensureVmDir(io, paths);
    const json = try std.json.Stringify.valueAlloc(allocator, ready, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = paths.ready_path, .data = json });
}

pub fn readReady(allocator: std.mem.Allocator, io: Io, paths: Paths) !std.json.Parsed(Ready) {
    const data = try Io.Dir.cwd().readFileAlloc(io, paths.ready_path, allocator, .limited(max_metadata_bytes));
    defer allocator.free(data);
    return std.json.parseFromSlice(Ready, allocator, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

pub fn writeCreateTiming(allocator: std.mem.Allocator, io: Io, paths: Paths, timing: CreateTiming) !void {
    try writeTimingJson(allocator, io, paths.create_timing_path, timing);
}

pub fn writeMonitorTiming(allocator: std.mem.Allocator, io: Io, paths: Paths, timing: MonitorTiming) !void {
    try writeTimingJson(allocator, io, paths.monitor_timing_path, timing);
}

fn writeTimingJson(allocator: std.mem.Allocator, io: Io, path: []const u8, timing: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, timing, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
}

pub fn writePid(allocator: std.mem.Allocator, io: Io, paths: Paths, pid: i64) !void {
    if (pid <= 0) return error.InvalidPid;
    try ensureVmDir(io, paths);
    const data = try std.fmt.allocPrint(allocator, "{d}\n", .{pid});
    defer allocator.free(data);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = paths.pid_path, .data = data });
}

pub fn readPid(allocator: std.mem.Allocator, io: Io, paths: Paths) !i64 {
    const data = try Io.Dir.cwd().readFileAlloc(io, paths.pid_path, allocator, .limited(64));
    defer allocator.free(data);
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidPid;
    const pid = try std.fmt.parseInt(i64, trimmed, 10);
    if (pid <= 0) return error.InvalidPid;
    return pid;
}

pub const PidAliveFn = *const fn (pid: i64) bool;

pub fn classifyVmState(allocator: std.mem.Allocator, io: Io, paths: Paths, pid_alive: PidAliveFn) !VmState {
    const stat = Io.Dir.cwd().statFile(io, paths.vm_dir, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => |e| return e,
    };
    if (stat.kind != Io.File.Kind.directory) return error.InvalidVMState;

    var spec = readSpec(allocator, io, paths) catch |err| switch (err) {
        error.FileNotFound => return .stale,
        else => return .stale,
    };
    defer spec.deinit();
    if (!std.mem.eql(u8, spec.value.name, std.fs.path.basename(paths.vm_dir))) return .stale;
    var ready = readReady(allocator, io, paths) catch |err| switch (err) {
        error.FileNotFound => return .incomplete,
        else => return .stale,
    };
    defer ready.deinit();

    const pid = readPid(allocator, io, paths) catch return .stale;
    if (ready.value.pid != pid) return .stale;
    return if (pid_alive(pid)) .ready else .stale;
}

pub fn listEntries(allocator: std.mem.Allocator, io: Io, runtime_root: []const u8, pid_alive: PidAliveFn) ![]ListEntry {
    requirePrivateDir(io, runtime_root) catch |err| switch (err) {
        error.FileNotFound => return emptyListEntries(allocator),
        else => |e| return e,
    };
    const vms_dir = try std.fs.path.resolve(allocator, &.{ runtime_root, "vms" });
    defer allocator.free(vms_dir);
    requirePrivateDir(io, vms_dir) catch |err| switch (err) {
        error.FileNotFound => return emptyListEntries(allocator),
        else => |e| return e,
    };
    var dir = openDirPath(io, vms_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return emptyListEntries(allocator),
        else => |e| return e,
    };
    defer dir.close(io);

    var entries = std.array_list.Managed(ListEntry).init(allocator);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        validateName(entry.name) catch continue;
        const paths = try pathsFromRoot(allocator, runtime_root, entry.name);
        defer paths.deinit(allocator);
        const state = try classifyVmState(allocator, io, paths, pid_alive);
        if (state == .absent) continue;
        const pid = if (state == .ready or state == .stale) readPid(allocator, io, paths) catch null else null;
        try entries.append(.{
            .name = try allocator.dupe(u8, entry.name),
            .state = state.name(),
            .pid = pid,
        });
    }
    const out = try entries.toOwnedSlice();
    std.mem.sort(ListEntry, out, {}, lessListEntry);
    return out;
}

pub fn freeListEntries(allocator: std.mem.Allocator, entries: []ListEntry) void {
    for (entries) |entry| allocator.free(entry.name);
    allocator.free(entries);
}

fn emptyListEntries(allocator: std.mem.Allocator) ![]ListEntry {
    return allocator.alloc(ListEntry, 0);
}

fn parseCreateArgs(
    args: []const []const u8,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) !CreateOptions {
    var name: ?[]const u8 = null;
    var spec = Spec{ .name = "" };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--backend")) {
            spec.backend = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            if (!validBackend(spec.backend)) {
                const message = "--backend must be auto, hvf, or kvm";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            }
        } else if (std.mem.eql(u8, args[i], "--kernel")) {
            spec.kernel_path = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--initrd")) {
            spec.initrd_path = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--rootfs")) {
            spec.rootfs_path = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--image")) {
            spec.image_ref = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--memory")) {
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            spec.memory = memory_config.parse(raw) catch |err| {
                const message = allocLifecycleMessage(
                    allocator,
                    "spore create: --memory must be auto or a positive page-aligned size like 512mb or 16gb ({s})",
                    .{@errorName(err)},
                );
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
        } else if (std.mem.eql(u8, args[i], "--memory-mib")) {
            const message = "spore create: --memory-mib has been replaced by --memory";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
        } else if (std.mem.eql(u8, args[i], "--vcpus")) {
            const flag = args[i];
            spec.vcpus = parseIntArgLifecycleCli(u32, allocator, stderr, mode, "create", takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, flag), flag);
        } else if (std.mem.eql(u8, args[i], "--guest-port")) {
            const flag = args[i];
            spec.guest_port = parseIntArgLifecycleCli(u32, allocator, stderr, mode, "create", takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, flag), flag);
        } else if (std.mem.eql(u8, args[i], "--timeout-ms")) {
            const flag = args[i];
            spec.timeout_ms = parseIntArgLifecycleCli(u64, allocator, stderr, mode, "create", takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, flag), flag);
        } else if (std.mem.eql(u8, args[i], "--console-log")) {
            spec.console_log_path = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            const message = allocLifecycleMessage(allocator, "unknown create argument: {s}", .{args[i]});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
        } else if (name == null) {
            validateNameLifecycleCli(allocator, stderr, mode, "create", args[i]);
            name = args[i];
            spec.name = args[i];
        } else {
            const message = allocLifecycleMessage(allocator, "unexpected create argument: {s}", .{args[i]});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
        }
    }

    if (name == null) {
        exitLifecycleCliError(
            allocator,
            stderr,
            mode,
            machine_output.usageMissingArgument("usage: spore create NAME [options]", "create"),
            create_usage,
        );
    }
    if (spec.rootfs_path != null and spec.image_ref != null) {
        const message = "spore create: --rootfs and --image are mutually exclusive";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
    }
    return .{ .spec = spec };
}

fn parseExecArgs(args: []const []const u8) ExecOptions {
    if (args.len < 3 or !std.mem.eql(u8, args[1], "--")) usageExit(exec_usage);
    validateNameOrExit("exec", args[0]) catch unreachable;
    const command = args[2..];
    if (command.len == 0) usageExit(exec_usage);
    return .{ .name = args[0], .command = command };
}

fn parseRmArgs(args: []const []const u8, allocator: std.mem.Allocator, stderr: *Io.Writer, mode: machine_output.Mode) []const u8 {
    if (args.len != 1) {
        exitLifecycleCliError(
            allocator,
            stderr,
            mode,
            machine_output.usageMissingArgument("usage: spore rm NAME", "rm"),
            rm_usage,
        );
    }
    validateNameLifecycleCli(allocator, stderr, mode, "rm", args[0]);
    return args[0];
}

fn parseSuspendArgs(
    args: []const []const u8,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) SuspendOptions {
    var name: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out")) {
            out_dir = takeValueLifecycleCli(allocator, stderr, mode, "suspend", args, &i, args[i]);
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            const message = allocLifecycleMessage(allocator, "unknown suspend argument: {s}", .{args[i]});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "suspend"), message);
        } else if (name == null) {
            validateNameLifecycleCli(allocator, stderr, mode, "suspend", args[i]);
            name = args[i];
        } else {
            const message = allocLifecycleMessage(allocator, "unexpected suspend argument: {s}", .{args[i]});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "suspend"), message);
        }
    }

    if (name == null or out_dir == null) {
        exitLifecycleCliError(
            allocator,
            stderr,
            mode,
            machine_output.usageMissingArgument("usage: spore suspend NAME --out DIR", "suspend"),
            suspend_usage,
        );
    }
    return .{ .name = name.?, .out_dir = out_dir.? };
}

fn parseResumeArgs(
    args: []const []const u8,
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
) ResumeOptions {
    var spore_dir: ?[]const u8 = null;
    var name: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--name")) {
            name = takeValueLifecycleCli(allocator, stderr, mode, "resume", args, &i, args[i]);
            validateNameLifecycleCli(allocator, stderr, mode, "resume", name.?);
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            const message = allocLifecycleMessage(allocator, "unknown resume argument: {s}", .{args[i]});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "resume"), message);
        } else if (spore_dir == null) {
            spore_dir = args[i];
        } else {
            const message = allocLifecycleMessage(allocator, "unexpected resume argument: {s}", .{args[i]});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "resume"), message);
        }
    }

    if (spore_dir == null or name == null) {
        exitLifecycleCliError(
            allocator,
            stderr,
            mode,
            machine_output.usageMissingArgument("usage: spore resume DIR --name NAME", "resume"),
            resume_usage,
        );
    }
    return .{ .spore_dir = spore_dir.?, .name = name.? };
}

fn cliPaths(init: std.process.Init, allocator: std.mem.Allocator, command: []const u8, name: []const u8) !Paths {
    const paths = pathsFor(allocator, init.environ_map, name) catch |err| {
        cliRuntimePathExit(command, err);
    };
    validateExistingRuntimeDirs(init.io, paths) catch |err| {
        cliRuntimePathExit(command, err);
    };
    return paths;
}

fn resolveNewOutputDir(
    allocator: std.mem.Allocator,
    io: Io,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    raw: []const u8,
) []const u8 {
    const path = std.fs.path.resolve(allocator, &.{raw}) catch |err| {
        const message = allocLifecycleMessage(allocator, "spore {s}: invalid output directory: {s}", .{ command, @errorName(err) });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
    };
    if (pathExists(io, path) catch |err| {
        const message = allocLifecycleMessage(allocator, "spore {s}: output directory check failed: {s}", .{ command, @errorName(err) });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, command), message);
    }) {
        const message = allocLifecycleMessage(allocator, "spore {s}: output directory already exists: {s}", .{ command, path });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
    }
    const parent = std.fs.path.dirname(path) orelse {
        const message = allocLifecycleMessage(allocator, "spore {s}: output directory has no parent: {s}", .{ command, path });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
    };
    const stat = Io.Dir.cwd().statFile(io, parent, .{ .follow_symlinks = true }) catch |err| {
        const message = allocLifecycleMessage(allocator, "spore {s}: output parent is not available: {s}", .{ command, @errorName(err) });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_not_found, message, command), message);
    };
    if (stat.kind != Io.File.Kind.directory) {
        const message = allocLifecycleMessage(allocator, "spore {s}: output parent is not a directory: {s}", .{ command, parent });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, command), message);
    }
    return path;
}

fn resolveExistingSporeDir(
    allocator: std.mem.Allocator,
    io: Io,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    raw: []const u8,
) []const u8 {
    const path = std.fs.path.resolve(allocator, &.{raw}) catch |err| {
        const message = allocLifecycleMessage(allocator, "spore {s}: invalid spore directory: {s}", .{ command, @errorName(err) });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
    };
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| {
        const message = allocLifecycleMessage(allocator, "spore {s}: spore directory is not available: {s}", .{ command, @errorName(err) });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_not_found, message, command), message);
    };
    if (stat.kind != Io.File.Kind.directory) {
        const message = allocLifecycleMessage(allocator, "spore {s}: spore path is not a directory: {s}", .{ command, path });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, command), message);
    }
    return path;
}

fn pathExists(io: Io, path: []const u8) !bool {
    _ = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

fn writeSporeLifecycleSpec(allocator: std.mem.Allocator, io: Io, dir: []const u8, spec: Spec) !void {
    const path = try std.fs.path.resolve(allocator, &.{ dir, lifecycle_spore_metadata_file });
    var metadata = spec;
    metadata.resume_dir = null;
    const json = try std.json.Stringify.valueAlloc(allocator, metadata, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
}

fn readSporeLifecycleSpec(allocator: std.mem.Allocator, io: Io, dir: []const u8) !?std.json.Parsed(Spec) {
    const path = try std.fs.path.resolve(allocator, &.{ dir, lifecycle_spore_metadata_file });
    const data = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_metadata_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer allocator.free(data);
    const parsed = try std.json.parseFromSlice(Spec, allocator, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    return parsed;
}

fn memoryFromManifest(manifest: spore.Manifest) !memory_config.Config {
    return memory_config.fromManifestBytes(manifest.platform.ram_size);
}

fn spawnMonitor(init: std.process.Init, allocator: std.mem.Allocator, spec: Spec) !void {
    const full_args = try init.minimal.args.toSlice(allocator);
    const exe = full_args[0];
    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.append(exe);
    try argv.append("monitor");
    try argv.append(spec.name);
    try argv.append("--backend");
    try argv.append(spec.backend);
    if (spec.kernel_path) |path| {
        try argv.append("--kernel");
        try argv.append(path);
    }
    if (spec.initrd_path) |path| {
        try argv.append("--initrd");
        try argv.append(path);
    }
    if (spec.rootfs_path) |path| {
        try argv.append("--rootfs");
        try argv.append(path);
    }
    if (spec.image_ref) |image| {
        try argv.append("--image");
        try argv.append(image);
    }
    if (spec.resume_dir) |path| {
        try argv.append("--resume");
        try argv.append(path);
    }
    try appendMemoryArg(allocator, &argv, spec.memory);
    try appendIntArg(allocator, &argv, "--vcpus", spec.vcpus);
    try appendIntArg(allocator, &argv, "--guest-port", spec.guest_port);
    try appendIntArg(allocator, &argv, "--timeout-ms", spec.timeout_ms);
    if (spec.console_log_path) |path| {
        try argv.append("--console-log");
        try argv.append(path);
    }
    _ = try std.process.spawn(init.io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = if (builtin.os.tag == .windows) null else 0,
    });
}

fn appendIntArg(allocator: std.mem.Allocator, argv: *std.array_list.Managed([]const u8), flag: []const u8, value: anytype) !void {
    try argv.append(flag);
    try argv.append(try std.fmt.allocPrint(allocator, "{d}", .{value}));
}

fn appendMemoryArg(allocator: std.mem.Allocator, argv: *std.array_list.Managed([]const u8), memory: memory_config.Config) !void {
    try argv.append("--memory");
    try argv.append(try memory.cliValueAlloc(allocator));
}

fn waitForReady(command: []const u8, allocator: std.mem.Allocator, io: Io, paths: Paths, timeout_ms: u64) !void {
    const start = monotonicMs();
    while (monotonicMs() - start < timeout_ms) {
        var ready = readReady(allocator, io, paths) catch {
            sleepMs(20);
            continue;
        };
        if (!pidAlive(ready.value.pid)) {
            ready.deinit();
            sleepMs(20);
            continue;
        }
        ready.deinit();
        return;
    }
    std.debug.print("spore {s}: timed out waiting for monitor readiness\n", .{command});
    std.process.exit(1);
}

fn lifecycleReadyOrExit(allocator: std.mem.Allocator, io: Io, command: []const u8, paths: Paths) std.json.Parsed(Ready) {
    return readReady(allocator, io, paths) catch {
        std.debug.print("spore {s}: VM is not ready\n", .{command});
        std.process.exit(2);
    };
}

fn sendExecRequest(allocator: std.mem.Allocator, io: Io, socket_path: []const u8, argv: []const []const u8) ![]const u8 {
    const payload = struct {
        type: []const u8 = "exec",
        argv: []const []const u8,
    }{ .argv = argv };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    return sendControlJson(allocator, io, socket_path, json);
}

fn sendShutdownRequest(allocator: std.mem.Allocator, io: Io, socket_path: []const u8) ![]const u8 {
    return sendControlJson(allocator, io, socket_path, "{\"type\":\"shutdown\"}");
}

fn sendSuspendRequest(allocator: std.mem.Allocator, io: Io, socket_path: []const u8, out_dir: []const u8) ![]const u8 {
    const payload = struct {
        type: []const u8 = "suspend",
        out_dir: []const u8,
    }{ .out_dir = out_dir };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    return sendControlJson(allocator, io, socket_path, json);
}

fn sendControlJson(allocator: std.mem.Allocator, io: Io, socket_path: []const u8, json: []const u8) ![]const u8 {
    const address = try net.UnixAddress.init(socket_path);
    const stream = address.connect(io) catch return error.MonitorUnavailable;
    defer stream.close(io);
    writeAll(io, stream, json) catch return error.MonitorUnavailable;
    writeAll(io, stream, "\n") catch return error.MonitorUnavailable;

    var read_buffer: [max_control_response]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const line = reader.interface.takeDelimiterExclusive('\n') catch return error.MonitorUnavailable;
    return allocator.dupe(u8, line);
}

const ControlResponse = struct {
    type: []const u8,
    exit_code: ?i32 = null,
    stdout_b64: ?[]const u8 = null,
    stderr_b64: ?[]const u8 = null,
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
    out_dir: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

fn handleExecResponse(init: std.process.Init, allocator: std.mem.Allocator, stdout: *Io.Writer, response: []const u8) !u8 {
    _ = init;
    var parsed = try std.json.parseFromSlice(ControlResponse, allocator, response, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (std.mem.eql(u8, parsed.value.type, "exec_result")) {
        const exit_code = parsed.value.exit_code orelse return error.BadMonitorResponse;
        if (exit_code < 0 or exit_code > 255) return error.BadMonitorResponse;

        const stdout_bytes = try decodeControlOutput(allocator, parsed.value.stdout_b64 orelse return error.BadMonitorResponse);
        defer allocator.free(stdout_bytes);
        const stderr_bytes = try decodeControlOutput(allocator, parsed.value.stderr_b64 orelse return error.BadMonitorResponse);
        defer allocator.free(stderr_bytes);

        try stdout.writeAll(stdout_bytes);
        try stdout.flush();
        try writeRawStderr(stderr_bytes);
        if (parsed.value.stdout_truncated) try writeRawStderr("spore exec: stdout truncated after 16384 bytes\n");
        if (parsed.value.stderr_truncated) try writeRawStderr("spore exec: stderr truncated after 16384 bytes\n");
        return @intCast(exit_code);
    }
    const message = parsed.value.message orelse "monitor request failed";
    std.debug.print("spore exec: {s}\n", .{message});
    return 1;
}

fn suspendResponseFailureMessage(allocator: std.mem.Allocator, response: []const u8) !?[]const u8 {
    var parsed = try std.json.parseFromSlice(ControlResponse, allocator, response, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (std.mem.eql(u8, parsed.value.type, "suspended")) return null;
    const message = parsed.value.message orelse "monitor request failed";
    return try allocator.dupe(u8, message);
}

fn writeAll(io: Io, stream: net.Stream, bytes: []const u8) !void {
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn decodeControlOutput(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const dec = std.base64.standard.Decoder;
    const decoded_size = dec.calcSizeForSlice(encoded) catch return error.BadMonitorResponse;
    if (decoded_size > max_control_response) return error.BadMonitorResponse;
    const decoded = try allocator.alloc(u8, decoded_size);
    errdefer allocator.free(decoded);
    dec.decode(decoded, encoded) catch return error.BadMonitorResponse;
    return decoded;
}

fn writeRawStderr(bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(2, remaining.ptr, remaining.len);
        if (n <= 0) return error.StderrWriteFailed;
        remaining = remaining[@intCast(n)..];
    }
}

fn waitForPidExit(pid: i64, timeout_ms: u64) void {
    const start = monotonicMs();
    while (monotonicMs() - start < timeout_ms) {
        if (!pidAlive(pid)) return;
        sleepMs(20);
    }
}

fn sleepMs(ms: u64) void {
    var ts = std.c.timespec{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast((ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);
}

pub fn monotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn wantsHelp(args: []const []const u8) bool {
    return args.len == 1 and
        (std.mem.eql(u8, args[0], "help") or
            std.mem.eql(u8, args[0], "-h") or
            std.mem.eql(u8, args[0], "--help"));
}

fn usageExit(comptime text: []const u8) noreturn {
    std.debug.print("{s}", .{text});
    std.process.exit(2);
}

fn allocLifecycleMessage(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(allocator, fmt, args) catch "CLI argument error";
}

fn exitLifecycleCliError(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    err: machine_output.CliError,
    human_text: []const u8,
) noreturn {
    if (mode == .json) {
        machine_output.writeError(allocator, stderr, err) catch {};
    } else {
        stderr.writeAll(human_text) catch {};
        if (!std.mem.endsWith(u8, human_text, "\n")) stderr.writeByte('\n') catch {};
    }
    stderr.flush() catch {};
    std.process.exit(err.exit_code);
}

fn validateNameOrExit(command: []const u8, name: []const u8) !void {
    validateName(name) catch {
        std.debug.print("spore {s}: invalid VM name: {s}\n", .{ command, name });
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
        const message = allocLifecycleMessage(allocator, "spore {s}: invalid VM name: {s}", .{ command, name });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
    };
}

fn cliRuntimePathExit(command: []const u8, err: anyerror) noreturn {
    switch (err) {
        error.InvalidRuntimeDir => std.debug.print(
            "spore {s}: invalid runtime directory; set {s} or XDG_RUNTIME_DIR to an absolute path\n",
            .{ command, runtime_dir_env },
        ),
        error.InsecureRuntimeDir => std.debug.print(
            "spore {s}: insecure runtime directory; registry directories must be private to the current user\n",
            .{command},
        ),
        else => std.debug.print("spore {s}: runtime directory error: {s}\n", .{ command, @errorName(err) }),
    }
    std.process.exit(2);
}

fn takeValue(args: []const []const u8, i: *usize, flag: []const u8) []const u8 {
    if (i.* + 1 >= args.len) {
        std.debug.print("{s} requires a value\n", .{flag});
        std.process.exit(2);
    }
    i.* += 1;
    return args[i.*];
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

fn parseIntArg(comptime T: type, raw: []const u8, flag: []const u8) T {
    return std.fmt.parseInt(T, raw, 10) catch {
        std.debug.print("{s} must be an integer\n", .{flag});
        std.process.exit(2);
    };
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

fn validBackend(raw: []const u8) bool {
    return std.mem.eql(u8, raw, "auto") or std.mem.eql(u8, raw, "hvf") or std.mem.eql(u8, raw, "kvm");
}

pub fn monitorBackendSupported(raw: []const u8) bool {
    const hvf_supported = comptime builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;
    const kvm_supported = comptime builtin.os.tag == .linux and builtin.cpu.arch == .aarch64;
    if (std.mem.eql(u8, raw, "auto")) return hvf_supported or kvm_supported;
    if (std.mem.eql(u8, raw, "hvf")) return hvf_supported;
    if (std.mem.eql(u8, raw, "kvm")) return kvm_supported;
    return false;
}

fn openDirPath(io: Io, path: []const u8, flags: Io.Dir.OpenOptions) !Io.Dir {
    if (Io.Dir.path.isAbsolute(path)) return Io.Dir.openDirAbsolute(io, path, flags);
    return Io.Dir.cwd().openDir(io, path, flags);
}

fn ensureVmDir(io: Io, paths: Paths) !void {
    try ensureDirPath(io, paths.runtime_root);
    try requirePrivateDir(io, paths.runtime_root);
    try ensureDirPath(io, paths.vms_dir);
    try requirePrivateDir(io, paths.vms_dir);
    try ensureDirPath(io, paths.vm_dir);
    try requirePrivateDir(io, paths.vm_dir);
}

fn ensureDirPath(io: Io, path: []const u8) !void {
    if (!Io.Dir.path.isAbsolute(path)) {
        _ = try Io.Dir.cwd().createDirPathStatus(io, path, private_dir_permissions);
        return;
    }
    var existing = Io.Dir.openDirAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (std.fs.path.dirname(path)) |parent| {
                if (parent.len > 0 and !std.mem.eql(u8, parent, path)) try ensureDirPath(io, parent);
            }
            Io.Dir.createDirAbsolute(io, path, private_dir_permissions) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => {},
                else => |e| return e,
            };
            return;
        },
        else => |e| return e,
    };
    existing.close(io);
}

fn requirePrivateDir(io: Io, path: []const u8) !void {
    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != Io.File.Kind.directory) return error.InvalidRuntimeDir;
    if (comptime builtin.os.tag != .windows) {
        const mode = @intFromEnum(stat.permissions);
        if (mode & 0o077 != 0) return error.InsecureRuntimeDir;
    }
}

fn validateExistingRuntimeDirs(io: Io, paths: Paths) !void {
    try validateExistingPrivateDir(io, paths.runtime_root);
    try validateExistingPrivateDir(io, paths.vms_dir);
    try validateExistingPrivateDir(io, paths.vm_dir);
}

fn validateExistingPrivateDir(io: Io, path: []const u8) !void {
    requirePrivateDir(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
}

pub fn pidAlive(pid: i64) bool {
    if (pid <= 0) return false;
    if (comptime builtin.os.tag == .windows) return false;
    std.posix.kill(@intCast(pid), @enumFromInt(0)) catch |err| return err == error.PermissionDenied;
    return true;
}

fn lessListEntry(_: void, a: ListEntry, b: ListEntry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

test "lifecycle validates VM names" {
    try validateName("bench-1");
    try validateName("a.b_c9");
    try std.testing.expectError(error.InvalidVMName, validateName(""));
    try std.testing.expectError(error.InvalidVMName, validateName("-flag"));
    try std.testing.expectError(error.InvalidVMName, validateName("."));
    try std.testing.expectError(error.InvalidVMName, validateName("bad/name"));
    try std.testing.expectError(error.InvalidVMName, validateName("bad name"));
}

test "lifecycle result carries stable schema" {
    const result = LifecycleResult{
        .action = "created",
        .name = "bench-1",
        .state = "ready",
        .pid = 42,
    };
    try std.testing.expectEqualStrings(lifecycle_schema, result.schema);
    try std.testing.expectEqual(lifecycle_schema_version, result.schema_version);
    try std.testing.expectEqualStrings("created", result.action);
    try std.testing.expectEqualStrings("bench-1", result.name);
    try std.testing.expectEqualStrings("ready", result.state);
    try std.testing.expectEqual(@as(?i64, 42), result.pid);
}

test "lifecycle monitor backend support is explicit" {
    const hvf_supported = comptime builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;
    const kvm_supported = comptime builtin.os.tag == .linux and builtin.cpu.arch == .aarch64;
    try std.testing.expectEqual(hvf_supported or kvm_supported, monitorBackendSupported("auto"));
    try std.testing.expectEqual(hvf_supported, monitorBackendSupported("hvf"));
    try std.testing.expectEqual(kvm_supported, monitorBackendSupported("kvm"));
    try std.testing.expect(!monitorBackendSupported("bogus"));
}

test "lifecycle runtime root prefers explicit and xdg absolute paths" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    try env.put(runtime_dir_env, "/tmp/sporevm-runtime");
    const explicit = try runtimeRootPath(allocator, &env);
    defer allocator.free(explicit);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime", explicit);

    _ = env.swapRemove(runtime_dir_env);
    try env.put("XDG_RUNTIME_DIR", "/tmp/xdg-runtime");
    const xdg = try runtimeRootPath(allocator, &env);
    defer allocator.free(xdg);
    try std.testing.expectEqualStrings("/tmp/xdg-runtime/sporevm", xdg);
}

test "lifecycle runtime root rejects relative environment paths" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    try env.put(runtime_dir_env, "relative");
    try std.testing.expectError(error.InvalidRuntimeDir, runtimeRootPath(allocator, &env));

    _ = env.swapRemove(runtime_dir_env);
    try env.put("XDG_RUNTIME_DIR", "");
    try std.testing.expectError(error.InvalidRuntimeDir, runtimeRootPath(allocator, &env));
}

test "lifecycle paths are rooted under vms by name" {
    const allocator = std.testing.allocator;
    const paths = try pathsFromRoot(allocator, "/tmp/sporevm-runtime", "bench-1");
    defer paths.deinit(allocator);

    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms", paths.vms_dir);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1", paths.vm_dir);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1/spec.json", paths.spec_path);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1/ready.json", paths.ready_path);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1/create-timing.json", paths.create_timing_path);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1/monitor-timing.json", paths.monitor_timing_path);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1/pid", paths.pid_path);
}

test "lifecycle metadata helpers round trip spec ready and pid" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fs.path.resolve(allocator, &.{"zig-cache/test-lifecycle-metadata"});
    defer allocator.free(root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);

    try writeSpec(allocator, io, paths, .{
        .name = "bench-1",
        .backend = "hvf",
        .image_ref = "docker.io/library/alpine:3.20",
        .memory = .{ .policy = .explicit, .bytes = 512 * 1024 * 1024 },
    });
    var spec = try readSpec(allocator, io, paths);
    defer spec.deinit();
    try std.testing.expectEqualStrings("bench-1", spec.value.name);
    try std.testing.expectEqualStrings("hvf", spec.value.backend);
    try std.testing.expectEqualStrings("docker.io/library/alpine:3.20", spec.value.image_ref.?);
    try std.testing.expectEqual(memory_config.Policy.explicit, spec.value.memory.policy);
    try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), spec.value.memory.bytes);

    try writeReady(allocator, io, paths, .{
        .pid = 1234,
        .control_socket_path = paths.control_socket_path,
        .console_log_path = paths.console_log_path,
    });
    var ready = try readReady(allocator, io, paths);
    defer ready.deinit();
    try std.testing.expectEqual(@as(i64, 1234), ready.value.pid);
    try std.testing.expectEqualStrings(paths.control_socket_path, ready.value.control_socket_path);

    try writePid(allocator, io, paths, 1234);
    try std.testing.expectEqual(@as(i64, 1234), try readPid(allocator, io, paths));
}

test "create parser accepts memory policy" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    const default_opts = try parseCreateArgs(&.{"bench-1"}, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(memory_config.Policy.auto, default_opts.spec.memory.policy);
    try std.testing.expectEqual(memory_config.auto_bytes, default_opts.spec.memory.bytes);

    const explicit_opts = try parseCreateArgs(&.{ "bench-1", "--memory", "16gb" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(memory_config.Policy.explicit, explicit_opts.spec.memory.policy);
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024 * 1024), explicit_opts.spec.memory.bytes);
}

test "lifecycle detects incomplete ready and stale pid state" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fs.path.resolve(allocator, &.{"zig-cache/test-lifecycle-state"});
    defer allocator.free(root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);

    try std.testing.expectEqual(VmState.absent, try classifyVmState(allocator, io, paths, alwaysDead));

    try writeSpec(allocator, io, paths, .{ .name = "bench-1" });
    try std.testing.expectEqual(VmState.incomplete, try classifyVmState(allocator, io, paths, alwaysDead));

    try writeReady(allocator, io, paths, .{
        .pid = 7777,
        .control_socket_path = paths.control_socket_path,
        .console_log_path = paths.console_log_path,
    });
    try writePid(allocator, io, paths, 7777);
    try std.testing.expectEqual(VmState.stale, try classifyVmState(allocator, io, paths, alwaysDead));
    try std.testing.expectEqual(VmState.ready, try classifyVmState(allocator, io, paths, alwaysAlive));

    try writePid(allocator, io, paths, 8888);
    try std.testing.expectEqual(VmState.stale, try classifyVmState(allocator, io, paths, alwaysAlive));

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = paths.spec_path, .data = "not json" });
    try std.testing.expectEqual(VmState.stale, try classifyVmState(allocator, io, paths, alwaysAlive));

    try writeSpec(allocator, io, paths, .{ .name = "wrong-name" });
    try std.testing.expectEqual(VmState.stale, try classifyVmState(allocator, io, paths, alwaysAlive));
}

test "lifecycle rejects insecure existing runtime directories" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fs.path.resolve(allocator, &.{"zig-cache/test-lifecycle-insecure"});
    defer allocator.free(root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = try Io.Dir.cwd().createDirPathStatus(io, root, @enumFromInt(0o755));
    try Io.Dir.cwd().setFilePermissions(io, root, @enumFromInt(0o755), .{});

    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);
    try std.testing.expectError(error.InsecureRuntimeDir, validateExistingRuntimeDirs(io, paths));
}

test "lifecycle list entries sorts and classifies VM directories" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fs.path.resolve(allocator, &.{"zig-cache/test-lifecycle-list"});
    defer allocator.free(root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};

    const empty = try listEntries(allocator, io, root, alwaysDead);
    defer freeListEntries(allocator, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const stale = try pathsFromRoot(allocator, root, "b-stale");
    defer stale.deinit(allocator);
    try writeSpec(allocator, io, stale, .{ .name = "b-stale" });
    try writeReady(allocator, io, stale, .{
        .pid = 9001,
        .control_socket_path = stale.control_socket_path,
        .console_log_path = stale.console_log_path,
    });
    try writePid(allocator, io, stale, 9001);

    const ready = try pathsFromRoot(allocator, root, "a-ready");
    defer ready.deinit(allocator);
    try writeSpec(allocator, io, ready, .{ .name = "a-ready" });
    try writeReady(allocator, io, ready, .{
        .pid = 42,
        .control_socket_path = ready.control_socket_path,
        .console_log_path = ready.console_log_path,
    });
    try writePid(allocator, io, ready, 42);

    const entries = try listEntries(allocator, io, root, aliveOnly42);
    defer freeListEntries(allocator, entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("a-ready", entries[0].name);
    try std.testing.expectEqualStrings("ready", entries[0].state);
    try std.testing.expectEqual(@as(?i64, 42), entries[0].pid);
    try std.testing.expectEqualStrings("b-stale", entries[1].name);
    try std.testing.expectEqualStrings("stale", entries[1].state);
    try std.testing.expectEqual(@as(?i64, 9001), entries[1].pid);
}

test "lifecycle list entries render human table" {
    const allocator = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeListEntries(&out.writer, &.{
        .{ .name = "a-ready", .state = "ready", .pid = 42 },
        .{ .name = "b-stale", .state = "stale", .pid = null },
    });
    try std.testing.expectEqualStrings(
        "NAME\tSTATE\tPID\n" ++
            "a-ready\tready\t42\n" ++
            "b-stale\tstale\t-\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    try writeListEntries(&out.writer, &.{});
    try std.testing.expectEqualStrings("No VMs\n", out.written());
}

fn alwaysDead(_: i64) bool {
    return false;
}

fn alwaysAlive(_: i64) bool {
    return true;
}

fn aliveOnly42(pid: i64) bool {
    return pid == 42;
}
