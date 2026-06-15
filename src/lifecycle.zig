//! Named VM lifecycle registry and CLI shape.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;

const run_mod = @import("run.zig");

pub const runtime_dir_env = "SPOREVM_RUNTIME_DIR";
pub const max_name_len = 128;

const max_metadata_bytes = 64 * 1024;
const max_control_response = 128 * 1024;
const spec_file = "spec.json";
const ready_file = "ready.json";
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
    \\  --initrd root.cpio      Initrd path
    \\  --rootfs rootfs.ext4    Attach rootfs image read-only as virtio-blk
    \\  --image REF             Build or reuse cached OCI rootfs
    \\  --memory-mib N          Guest memory in MiB (default: 1024)
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

const ls_usage =
    \\Usage:
    \\  spore ls
    \\
    \\Options:
    \\  -h, --help              Show this help
    \\
;

pub const Paths = struct {
    runtime_root: []const u8,
    vms_dir: []const u8,
    vm_dir: []const u8,
    spec_path: []const u8,
    ready_path: []const u8,
    pid_path: []const u8,
    control_socket_path: []const u8,
    console_log_path: []const u8,

    pub fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_root);
        allocator.free(self.vms_dir);
        allocator.free(self.vm_dir);
        allocator.free(self.spec_path);
        allocator.free(self.ready_path);
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
    image_ref: ?[]const u8 = null,
    memory_mib: u64 = 1024,
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

const CreateOptions = struct {
    spec: Spec,
};

const ExecOptions = struct {
    name: []const u8,
    command: []const []const u8,
};

pub fn createCli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (wantsHelp(args)) {
        try stdout.writeAll(create_usage);
        return;
    }
    if (args.len == 0) usageExit(create_usage);

    const allocator = init.arena.allocator();
    const parsed = try parseCreateArgs(args);
    const paths = try cliPaths(init, allocator, "create", parsed.spec.name);
    if (parsed.spec.rootfs_path != null or parsed.spec.image_ref != null) {
        std.debug.print("spore create: --rootfs and --image land in the rootfs lifecycle slice\n", .{});
        std.process.exit(2);
    }
    if (!monitorBackendSupported(parsed.spec.backend)) {
        std.debug.print("spore create: monitor mode currently supports only HVF on Apple Silicon\n", .{});
        std.process.exit(2);
    }
    const state = try classifyVmState(allocator, init.io, paths, pidAlive);
    if (state != .absent) {
        std.debug.print("spore create: VM already exists or has stale state: {s}\n", .{parsed.spec.name});
        std.process.exit(2);
    }
    try spawnMonitor(init, allocator, parsed.spec);
    try waitForReady(allocator, init.io, paths, parsed.spec.timeout_ms);
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

pub fn rmCli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (wantsHelp(args)) {
        try stdout.writeAll(rm_usage);
        return;
    }
    const name = parseRmArgs(args);
    const allocator = init.arena.allocator();
    const paths = try cliPaths(init, allocator, "rm", name);
    const state = try classifyVmState(allocator, init.io, paths, pidAlive);
    switch (state) {
        .absent => {
            std.debug.print("spore rm: VM not found: {s}\n", .{name});
            std.process.exit(2);
        },
        .ready => {
            var ready = lifecycleReadyOrExit(allocator, init.io, "rm", paths);
            defer ready.deinit();
            _ = sendShutdownRequest(allocator, init.io, ready.value.control_socket_path) catch {};
            waitForPidExit(ready.value.pid, 5_000);
            try Io.Dir.cwd().deleteTree(init.io, paths.vm_dir);
        },
        .incomplete, .stale => try Io.Dir.cwd().deleteTree(init.io, paths.vm_dir),
    }
}

pub fn lsCli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (wantsHelp(args)) {
        try stdout.writeAll(ls_usage);
        return;
    }
    if (args.len != 0) usageExit(ls_usage);

    const allocator = init.arena.allocator();
    const root = runtimeRootPath(allocator, init.environ_map) catch |err| {
        cliRuntimePathExit("ls", err);
    };
    const entries = try listEntries(allocator, init.io, root, pidAlive);
    const json = try std.json.Stringify.valueAlloc(allocator, entries, .{ .whitespace = .indent_2 });
    try stdout.writeAll(json);
    try stdout.writeByte('\n');
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
    if (environ.get(runtime_dir_env)) |path| return resolveRequiredAbsolute(allocator, path);
    if (environ.get("XDG_RUNTIME_DIR")) |path| {
        try validateAbsolutePath(path);
        return std.fs.path.resolve(allocator, &.{ path, "sporevm" });
    }
    const tmp = environ.get("TMPDIR") orelse "/tmp";
    try validateAbsolutePath(tmp);
    const leaf = try fallbackRuntimeLeaf(allocator);
    defer allocator.free(leaf);
    return std.fs.path.resolve(allocator, &.{ tmp, leaf });
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
    return std.json.parseFromSlice(Spec, allocator, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
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

fn parseCreateArgs(args: []const []const u8) !CreateOptions {
    var name: ?[]const u8 = null;
    var spec = Spec{ .name = "" };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--backend")) {
            spec.backend = takeValue(args, &i, args[i]);
            if (!validBackend(spec.backend)) {
                std.debug.print("--backend must be auto, hvf, or kvm\n", .{});
                std.process.exit(2);
            }
        } else if (std.mem.eql(u8, args[i], "--kernel")) {
            spec.kernel_path = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--initrd")) {
            spec.initrd_path = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--rootfs")) {
            spec.rootfs_path = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--image")) {
            spec.image_ref = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--memory-mib")) {
            const flag = args[i];
            spec.memory_mib = parseIntArg(u64, takeValue(args, &i, flag), flag);
        } else if (std.mem.eql(u8, args[i], "--vcpus")) {
            const flag = args[i];
            spec.vcpus = parseIntArg(u32, takeValue(args, &i, flag), flag);
        } else if (std.mem.eql(u8, args[i], "--guest-port")) {
            const flag = args[i];
            spec.guest_port = parseIntArg(u32, takeValue(args, &i, flag), flag);
        } else if (std.mem.eql(u8, args[i], "--timeout-ms")) {
            const flag = args[i];
            spec.timeout_ms = parseIntArg(u64, takeValue(args, &i, flag), flag);
        } else if (std.mem.eql(u8, args[i], "--console-log")) {
            spec.console_log_path = takeValue(args, &i, args[i]);
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            std.debug.print("unknown create argument: {s}\n\n{s}", .{ args[i], create_usage });
            std.process.exit(2);
        } else if (name == null) {
            try validateNameOrExit("create", args[i]);
            name = args[i];
            spec.name = args[i];
        } else {
            std.debug.print("unexpected create argument: {s}\n\n{s}", .{ args[i], create_usage });
            std.process.exit(2);
        }
    }

    if (name == null) usageExit(create_usage);
    if (spec.rootfs_path != null and spec.image_ref != null) {
        std.debug.print("spore create: --rootfs and --image are mutually exclusive\n", .{});
        std.process.exit(2);
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

fn parseRmArgs(args: []const []const u8) []const u8 {
    if (args.len != 1) usageExit(rm_usage);
    validateNameOrExit("rm", args[0]) catch unreachable;
    return args[0];
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
    try appendIntArg(allocator, &argv, "--memory-mib", spec.memory_mib);
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

fn waitForReady(allocator: std.mem.Allocator, io: Io, paths: Paths, timeout_ms: u64) !void {
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
    std.debug.print("spore create: timed out waiting for monitor readiness\n", .{});
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
    exit_frame: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

fn handleExecResponse(init: std.process.Init, allocator: std.mem.Allocator, stdout: *Io.Writer, response: []const u8) !u8 {
    var parsed = try std.json.parseFromSlice(ControlResponse, allocator, response, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (std.mem.eql(u8, parsed.value.type, "exec_result")) {
        const frame = parsed.value.exit_frame orelse return error.BadMonitorResponse;
        return run_mod.writeExitFrameOutput(init, allocator, stdout, frame);
    }
    const message = parsed.value.message orelse "monitor request failed";
    std.debug.print("spore exec: {s}\n", .{message});
    return 1;
}

fn writeAll(io: Io, stream: net.Stream, bytes: []const u8) !void {
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
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

fn monotonicMs() u64 {
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

fn validateNameOrExit(command: []const u8, name: []const u8) !void {
    validateName(name) catch {
        std.debug.print("spore {s}: invalid VM name: {s}\n", .{ command, name });
        std.process.exit(2);
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

fn parseIntArg(comptime T: type, raw: []const u8, flag: []const u8) T {
    return std.fmt.parseInt(T, raw, 10) catch {
        std.debug.print("{s} must be an integer\n", .{flag});
        std.process.exit(2);
    };
}

fn validBackend(raw: []const u8) bool {
    return std.mem.eql(u8, raw, "auto") or std.mem.eql(u8, raw, "hvf") or std.mem.eql(u8, raw, "kvm");
}

pub fn monitorBackendSupported(raw: []const u8) bool {
    if (!std.mem.eql(u8, raw, "auto") and !std.mem.eql(u8, raw, "hvf")) return false;
    return comptime builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;
}

fn resolveRequiredAbsolute(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    try validateAbsolutePath(path);
    return std.fs.path.resolve(allocator, &.{path});
}

fn validateAbsolutePath(path: []const u8) !void {
    if (path.len == 0 or !Io.Dir.path.isAbsolute(path)) return error.InvalidRuntimeDir;
}

fn openDirPath(io: Io, path: []const u8, flags: Io.Dir.OpenOptions) !Io.Dir {
    if (Io.Dir.path.isAbsolute(path)) return Io.Dir.openDirAbsolute(io, path, flags);
    return Io.Dir.cwd().openDir(io, path, flags);
}

fn fallbackRuntimeLeaf(allocator: std.mem.Allocator) ![]const u8 {
    if (comptime builtin.os.tag == .windows) return allocator.dupe(u8, "sporevm");
    return std.fmt.allocPrint(allocator, "sporevm-{d}", .{std.c.getuid()});
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

test "lifecycle monitor backend support is explicit" {
    const hvf_supported = comptime builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;
    try std.testing.expectEqual(hvf_supported, monitorBackendSupported("auto"));
    try std.testing.expectEqual(hvf_supported, monitorBackendSupported("hvf"));
    try std.testing.expect(!monitorBackendSupported("kvm"));
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
    });
    var spec = try readSpec(allocator, io, paths);
    defer spec.deinit();
    try std.testing.expectEqualStrings("bench-1", spec.value.name);
    try std.testing.expectEqualStrings("hvf", spec.value.backend);
    try std.testing.expectEqualStrings("docker.io/library/alpine:3.20", spec.value.image_ref.?);

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

fn alwaysDead(_: i64) bool {
    return false;
}

fn alwaysAlive(_: i64) bool {
    return true;
}

fn aliveOnly42(pid: i64) bool {
    return pid == 42;
}
