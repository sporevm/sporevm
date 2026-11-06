//! The named-VM registry under `$SPOREVM_RUNTIME_DIR/vms/<name>/`: paths,
//! the spec, ready, pid and timing files, VM state, control socket ownership,
//! and private-directory checks.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;
const Sha256 = std.crypto.hash.sha2.Sha256;

const chunk_sealer = @import("chunk_sealer.zig");
const generation = @import("generation.zig");
const local_paths = @import("local_paths.zig");
const memory_config = @import("memory.zig");
const run_mod = @import("run.zig");
const runtime_disk_claim = @import("runtime_disk_claim.zig");
const runtime_disk_lease = @import("runtime_disk_lease.zig");
const spore = @import("spore.zig");
const topology = @import("topology.zig");

pub const max_name_len = 128;
pub const max_metadata_bytes = 128 * 1024;
const spec_file = "spec.json";
const ready_file = "ready.json";
const create_timing_file = "create-timing.json";
const monitor_timing_file = "monitor-timing.json";
const monitor_stats_file = "monitor-stats.json";
const pid_file = "pid";
const control_socket_hash_bytes = 16;
const control_socket_owner_suffix = ".owner";
const console_log_file = "console.log";
const monitor_log_file = "monitor.log";
const private_dir_permissions: Io.File.Permissions = if (builtin.os.tag == .windows)
    .default_dir
else
    @enumFromInt(0o700);

const last_lifecycle_error_max = 2048;
threadlocal var last_lifecycle_error_buf: [last_lifecycle_error_max]u8 = undefined;
threadlocal var last_lifecycle_error: []const u8 = &.{};

pub fn clearLastError() void {
    last_lifecycle_error = &.{};
}

pub fn lastErrorMessage() []const u8 {
    return last_lifecycle_error;
}

pub fn setLastError(comptime fmt: []const u8, args: anytype) void {
    last_lifecycle_error = std.fmt.bufPrint(&last_lifecycle_error_buf, fmt, args) catch "lifecycle error";
}

pub const Paths = struct {
    runtime_root: []const u8,
    vms_dir: []const u8,
    vm_dir: []const u8,
    spec_path: []const u8,
    ready_path: []const u8,
    create_timing_path: []const u8,
    monitor_timing_path: []const u8,
    monitor_stats_path: []const u8,
    pid_path: []const u8,
    control_socket_root: []const u8,
    control_socket_path: []const u8,
    control_socket_owner_path: []const u8,
    console_log_path: []const u8,
    monitor_log_path: []const u8,

    pub fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_root);
        allocator.free(self.vms_dir);
        allocator.free(self.vm_dir);
        allocator.free(self.spec_path);
        allocator.free(self.ready_path);
        allocator.free(self.create_timing_path);
        allocator.free(self.monitor_timing_path);
        allocator.free(self.monitor_stats_path);
        allocator.free(self.pid_path);
        allocator.free(self.control_socket_root);
        allocator.free(self.control_socket_path);
        allocator.free(self.control_socket_owner_path);
        allocator.free(self.console_log_path);
        allocator.free(self.monitor_log_path);
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
    disk_baseline_lease: ?runtime_disk_lease.Lease = null,
    disk_fork_claim: ?DiskForkClaim = null,
    network: ?spore.Network = null,
    annotations: spore.Annotations = .{},
    sessions: []const spore.Session = &.{},
    exec_defaults: ?spore.ExecDefaults = null,
    image_ref: ?[]const u8 = null,
    resume_dir: ?[]const u8 = null,
    resume_generation: ?generation.State = null,
    memory: memory_config.Config = .{},
    vcpus: topology.VcpuCount = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    console_log_path: ?[]const u8 = null,
};

pub const DiskForkClaim = struct {
    source_socket_path: []const u8,
    request: runtime_disk_claim.ClaimRequest,
};

pub const Ready = struct {
    pid: i64,
    control_socket_path: []const u8,
    console_log_path: ?[]const u8 = null,
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
    readiness_attach_ms: ?u64 = null,
    readiness_connect_request_delivered_ms: ?u64 = null,
    readiness_connect_ms: ?u64 = null,
    readiness_request_delivered_ms: ?u64 = null,
    readiness_guest_timing_ms: ?u64 = null,
    readiness_response_ms: ?u64 = null,
    backend_restore_memory_ms: ?u64 = null,
    backend_restore_state_ms: ?u64 = null,
    backend_restore_pre_run_ms: ?u64 = null,
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

pub const MonitorStats = struct {
    chunks_nonzero: ?u64 = null,
    dirty_chunks_pending: ?u64 = null,
};

pub fn validateName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidVMName;
    if (name.len > max_name_len) return error.InvalidVMName;
    if (!std.ascii.isAlphanumeric(name[0])) return error.InvalidVMName;
    for (name[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return error.InvalidVMName;
    }
}

/// Maximum control socket path length the platform's sockaddr_un can hold.
/// macOS sun_path is 104 bytes and Linux is 108, minus one for the
/// terminating NUL. Zig's UnixAddress accepts up to 108 bytes on every
/// POSIX target, so paths in the 104-108 range crash inside the socket
/// address conversion on macOS instead of failing cleanly; SporeVM must
/// enforce the real platform limit itself.
pub const max_control_socket_path_len: usize = if (builtin.os.tag.isDarwin()) 103 else 107;

/// Fail closed, with an actionable message, when a control socket path cannot
/// fit a sockaddr_un. Public VM names do not participate in this bound: named
/// lifecycle sockets use a fixed-size digest in a short per-user namespace.
pub fn validateControlSocketPath(path: []const u8) error{ControlSocketPathTooLong}!void {
    if (path.len <= max_control_socket_path_len) return;
    setLastError(
        "control socket path {s} is {d} bytes but the platform limit is {d}",
        .{ path, path.len, max_control_socket_path_len },
    );
    return error.ControlSocketPathTooLong;
}

fn controlSocketRootPath(allocator: std.mem.Allocator) ![]const u8 {
    const uid: u32 = if (comptime builtin.os.tag == .windows) 0 else @intCast(std.c.getuid());
    return std.fmt.allocPrint(allocator, "/tmp/sporevm-control-{d}", .{uid});
}

fn controlSocketKey(vm_dir: []const u8) [control_socket_hash_bytes * 2]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(vm_dir, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return hex[0 .. control_socket_hash_bytes * 2].*;
}

/// Build a validated control socket address for connecting to a monitor.
pub fn controlSocketAddress(socket_path: []const u8) !net.UnixAddress {
    try validateControlSocketPath(socket_path);
    return net.UnixAddress.init(socket_path);
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
    const monitor_stats_path = try std.fs.path.resolve(allocator, &.{ vm_dir, monitor_stats_file });
    errdefer allocator.free(monitor_stats_path);
    const pid_path = try std.fs.path.resolve(allocator, &.{ vm_dir, pid_file });
    errdefer allocator.free(pid_path);
    const control_socket_root = try controlSocketRootPath(allocator);
    errdefer allocator.free(control_socket_root);
    const socket_key = controlSocketKey(vm_dir);
    const control_socket_name = try std.fmt.allocPrint(allocator, "{s}.sock", .{&socket_key});
    defer allocator.free(control_socket_name);
    const control_socket_path = try std.fs.path.resolve(allocator, &.{ control_socket_root, control_socket_name });
    errdefer allocator.free(control_socket_path);
    const control_socket_owner_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ &socket_key, control_socket_owner_suffix });
    defer allocator.free(control_socket_owner_name);
    const control_socket_owner_path = try std.fs.path.resolve(allocator, &.{ control_socket_root, control_socket_owner_name });
    errdefer allocator.free(control_socket_owner_path);
    const console_log_path = try std.fs.path.resolve(allocator, &.{ vm_dir, console_log_file });
    errdefer allocator.free(console_log_path);
    const monitor_log_path = try std.fs.path.resolve(allocator, &.{ vm_dir, monitor_log_file });
    errdefer allocator.free(monitor_log_path);
    return .{
        .runtime_root = runtime_root_owned,
        .vms_dir = vms_dir,
        .vm_dir = vm_dir,
        .spec_path = spec_path,
        .ready_path = ready_path,
        .create_timing_path = create_timing_path,
        .monitor_timing_path = monitor_timing_path,
        .monitor_stats_path = monitor_stats_path,
        .pid_path = pid_path,
        .control_socket_root = control_socket_root,
        .control_socket_path = control_socket_path,
        .control_socket_owner_path = control_socket_owner_path,
        .console_log_path = console_log_path,
        .monitor_log_path = monitor_log_path,
    };
}

pub fn writeSpec(allocator: std.mem.Allocator, io: Io, paths: Paths, spec: Spec) !void {
    try validateSpec(spec);
    const json = try std.json.Stringify.valueAlloc(allocator, spec, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    // readSpecFile must read back every spec written here, and readFileAlloc
    // fails once its limit is reached.
    if (json.len >= max_metadata_bytes) return error.SpecTooLarge;
    try ensureVmDir(io, paths);
    try chunk_sealer.replaceFileAtomicDurable(allocator, paths.spec_path, json, 0o600);
}

pub fn readSpec(allocator: std.mem.Allocator, io: Io, paths: Paths) !std.json.Parsed(Spec) {
    return readSpecFile(allocator, io, paths.spec_path);
}

pub fn readSpecFile(allocator: std.mem.Allocator, io: Io, spec_path: []const u8) !std.json.Parsed(Spec) {
    const data = try Io.Dir.cwd().readFileAlloc(io, spec_path, allocator, .limited(max_metadata_bytes));
    defer allocator.free(data);
    // An unknown field means an older spec shape, such as the removed memory
    // `policy`/`bytes` pair, and fails closed instead of silently defaulting.
    var parsed = try std.json.parseFromSlice(Spec, allocator, data, .{
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();
    try validateSpec(parsed.value);
    return parsed;
}

pub fn validateSpec(spec: Spec) !void {
    if (spec.exec_defaults) |defaults| try run_mod.validateGuestExecContext(defaults.env, defaults.working_dir);
    if (spec.disk_baseline_lease) |lease| try lease.validate();
    if (spec.disk_fork_claim) |claim| {
        if (!std.fs.path.isAbsolute(claim.source_socket_path)) return error.BadManifest;
        try validateControlSocketPath(claim.source_socket_path);
        try runtime_disk_claim.validateClaimRequest(claim.request);
        const lease = spec.disk_baseline_lease orelse return error.BadManifest;
        if (!std.mem.eql(u8, claim.request.child, spec.name) or
            claim.request.baseline_kind != lease.baseline_kind or
            !std.mem.eql(u8, claim.request.baseline_identity, lease.baseline_identity)) return error.BadManifest;
    }
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

pub fn writeMonitorStatsPath(allocator: std.mem.Allocator, io: Io, path: []const u8, stats: MonitorStats) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, stats, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
}

pub fn writeMonitorStats(allocator: std.mem.Allocator, io: Io, paths: Paths, stats: MonitorStats) !void {
    try writeMonitorStatsPath(allocator, io, paths.monitor_stats_path, stats);
}

pub fn writeTimingJson(allocator: std.mem.Allocator, io: Io, path: []const u8, timing: anytype) !void {
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

pub fn readMonitorStats(allocator: std.mem.Allocator, io: Io, paths: Paths) !MonitorStats {
    const data = try Io.Dir.cwd().readFileAlloc(io, paths.monitor_stats_path, allocator, .limited(max_metadata_bytes));
    defer allocator.free(data);
    var parsed = try std.json.parseFromSlice(MonitorStats, allocator, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    return parsed.value;
}

pub fn pathExists(io: Io, path: []const u8) !bool {
    _ = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

pub fn openDirPath(io: Io, path: []const u8, flags: Io.Dir.OpenOptions) !Io.Dir {
    if (Io.Dir.path.isAbsolute(path)) return Io.Dir.openDirAbsolute(io, path, flags);
    return Io.Dir.cwd().openDir(io, path, flags);
}

pub fn ensureVmDir(io: Io, paths: Paths) !void {
    try ensureDirPath(io, paths.runtime_root);
    try requirePrivateDir(io, paths.runtime_root);
    try ensureDirPath(io, paths.vms_dir);
    try requirePrivateDir(io, paths.vms_dir);
    try ensureDirPath(io, paths.vm_dir);
    try requirePrivateDir(io, paths.vm_dir);
}

pub fn claimControlSocketPath(io: Io, paths: Paths) !void {
    try ensureDirPath(io, paths.control_socket_root);
    try requirePrivateDir(io, paths.control_socket_root);

    Io.Dir.cwd().symLink(io, paths.vm_dir, paths.control_socket_owner_path, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {
            if (try controlSocketOwnerMatches(io, paths)) {
                setLastError(
                    "control socket path is already claimed by VM registry {s}: {s}",
                    .{ paths.vm_dir, paths.control_socket_path },
                );
            } else {
                setLastError(
                    "control socket hash collision: {s} is not owned by VM registry {s}",
                    .{ paths.control_socket_path, paths.vm_dir },
                );
            }
            return error.ControlSocketPathCollision;
        },
        else => |e| return e,
    };

    // A socket without a pre-existing matching owner cannot safely be
    // unlinked: it may be the only evidence of a digest collision.
    if (try pathExists(io, paths.control_socket_path)) {
        Io.Dir.cwd().deleteFile(io, paths.control_socket_owner_path) catch {};
        setLastError(
            "control socket hash collision: unowned socket already exists at {s}",
            .{paths.control_socket_path},
        );
        return error.ControlSocketPathCollision;
    }
}

pub fn validateControlSocketOwner(io: Io, paths: Paths) !void {
    if (try controlSocketOwnerMatches(io, paths)) return;
    setLastError(
        "control socket ownership mismatch: {s} is not owned by VM registry {s}",
        .{ paths.control_socket_path, paths.vm_dir },
    );
    return error.ControlSocketPathCollision;
}

fn controlSocketOwnerMatches(io: Io, paths: Paths) !bool {
    const stat = Io.Dir.cwd().statFile(io, paths.control_socket_owner_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    if (stat.kind != .sym_link) return false;
    var target: [std.fs.max_path_bytes]u8 = undefined;
    const len = try Io.Dir.cwd().readLink(io, paths.control_socket_owner_path, &target);
    return std.mem.eql(u8, paths.vm_dir, target[0..len]);
}

pub fn releaseControlSocketPath(io: Io, paths: Paths) !void {
    _ = Io.Dir.cwd().statFile(io, paths.control_socket_owner_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => {
            if (!try pathExists(io, paths.control_socket_path)) return;
            setLastError(
                "control socket ownership is missing for VM registry {s}: {s}",
                .{ paths.vm_dir, paths.control_socket_path },
            );
            return error.ControlSocketPathCollision;
        },
        else => |e| return e,
    };
    try validateControlSocketOwner(io, paths);
    Io.Dir.cwd().deleteFile(io, paths.control_socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    try Io.Dir.cwd().deleteFile(io, paths.control_socket_owner_path);
}

pub fn deleteVmState(io: Io, paths: Paths) !void {
    try releaseControlSocketPath(io, paths);
    try Io.Dir.cwd().deleteTree(io, paths.vm_dir);
}

pub fn ensureDirPath(io: Io, path: []const u8) !void {
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

pub fn requirePrivateDir(io: Io, path: []const u8) !void {
    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != Io.File.Kind.directory) return error.InvalidRuntimeDir;
    if (comptime builtin.os.tag != .windows) {
        const mode = @intFromEnum(stat.permissions);
        if (mode & 0o077 != 0) return error.InsecureRuntimeDir;
    }
}

pub fn validateExistingRuntimeDirs(io: Io, paths: Paths) !void {
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
    const owner_pid = std.math.cast(runtime_disk_lease.OwnerPid, pid) orelse return false;
    return runtime_disk_lease.ownerAlive(owner_pid);
}

/// Walks `vms/` and yields the spec of each VM directory that has one. A spec
/// that cannot be read fails closed with `error.BadManifest`.
pub const Iterator = struct {
    allocator: std.mem.Allocator,
    io: Io,
    vms_dir_path: []const u8,
    dir: ?Io.Dir = null,
    iterator: ?Io.Dir.Iterator = null,

    pub fn init(allocator: std.mem.Allocator, io: Io, runtime_root: []const u8) !Iterator {
        const vms_dir_path = try std.fs.path.join(allocator, &.{ runtime_root, "vms" });
        errdefer allocator.free(vms_dir_path);
        const dir = openDirPath(io, vms_dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return .{ .allocator = allocator, .io = io, .vms_dir_path = vms_dir_path },
            else => |e| return e,
        };
        return .{
            .allocator = allocator,
            .io = io,
            .vms_dir_path = vms_dir_path,
            .dir = dir,
            .iterator = dir.iterate(),
        };
    }

    pub fn deinit(self: *Iterator) void {
        if (self.dir) |*dir| dir.close(self.io);
        self.allocator.free(self.vms_dir_path);
        self.* = undefined;
    }

    pub fn next(self: *Iterator) !?std.json.Parsed(Spec) {
        const iterator = if (self.iterator) |*value| value else return null;
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;
            const spec_path = try std.fs.path.join(self.allocator, &.{ self.vms_dir_path, entry.name, spec_file });
            defer self.allocator.free(spec_path);
            return readSpecFile(self.allocator, self.io, spec_path) catch |err| switch (err) {
                error.FileNotFound => continue,
                error.OutOfMemory => error.OutOfMemory,
                else => error.BadManifest,
            };
        }
        return null;
    }
};

test "named control socket paths ignore long runtime roots and maximum VM names" {
    const allocator = std.testing.allocator;
    const deep_root = "/var/folders/ab/" ++ ("r" ** 160) ++ "/deep-runtime-dir";
    const long_name = "n" ** max_name_len;
    const long_paths = try pathsFromRoot(allocator, deep_root, long_name);
    defer long_paths.deinit(allocator);
    const short_paths = try pathsFromRoot(allocator, "/tmp/sporevm-runtime", long_name);
    defer short_paths.deinit(allocator);

    try std.testing.expect(std.mem.endsWith(u8, long_paths.vm_dir, long_name));
    try std.testing.expect(long_paths.control_socket_path.len <= max_control_socket_path_len);
    try std.testing.expectEqual(long_paths.control_socket_path.len, short_paths.control_socket_path.len);
    try std.testing.expect(!std.mem.eql(u8, long_paths.control_socket_path, short_paths.control_socket_path));
    try validateControlSocketPath(long_paths.control_socket_path);

    try validateControlSocketPath("/tmp/ok.sock");
    const at_limit = "/" ++ ("a" ** (max_control_socket_path_len - 1));
    try validateControlSocketPath(at_limit);
    try std.testing.expectError(error.ControlSocketPathTooLong, validateControlSocketPath(at_limit ++ "b"));
}

test "named control socket ownership detects hash collisions and cleans up" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fs.path.resolve(allocator, &.{"zig-cache/test-lifecycle-socket-owner"});
    defer allocator.free(root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);
    defer {
        Io.Dir.cwd().deleteFile(io, paths.control_socket_owner_path) catch {};
        Io.Dir.cwd().deleteFile(io, paths.control_socket_path) catch {};
    }

    try ensureVmDir(io, paths);
    try claimControlSocketPath(io, paths);
    try validateControlSocketOwner(io, paths);

    Io.Dir.cwd().deleteFile(io, paths.control_socket_owner_path) catch unreachable;
    try Io.Dir.cwd().symLink(io, "/tmp/a-different-vm-registry", paths.control_socket_owner_path, .{});
    clearLastError();
    try std.testing.expectError(error.ControlSocketPathCollision, claimControlSocketPath(io, paths));
    try std.testing.expect(std.mem.indexOf(u8, lastErrorMessage(), "hash collision") != null);
    try std.testing.expectError(error.ControlSocketPathCollision, deleteVmState(io, paths));
    try std.testing.expect(try pathExists(io, paths.vm_dir));

    Io.Dir.cwd().deleteFile(io, paths.control_socket_owner_path) catch unreachable;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = paths.control_socket_path, .data = "" });
    clearLastError();
    try std.testing.expectError(error.ControlSocketPathCollision, deleteVmState(io, paths));
    try std.testing.expect(std.mem.indexOf(u8, lastErrorMessage(), "ownership is missing") != null);
    try std.testing.expect(try pathExists(io, paths.vm_dir));
    try Io.Dir.cwd().deleteFile(io, paths.control_socket_path);

    try claimControlSocketPath(io, paths);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = paths.control_socket_path, .data = "" });
    try deleteVmState(io, paths);
    try std.testing.expect(!try pathExists(io, paths.vm_dir));
    try std.testing.expect(!try pathExists(io, paths.control_socket_path));
    try std.testing.expect(!try pathExists(io, paths.control_socket_owner_path));
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
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1/monitor-stats.json", paths.monitor_stats_path);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1/pid", paths.pid_path);
    try std.testing.expect(std.mem.startsWith(u8, paths.control_socket_path, "/tmp/sporevm-control-"));
    try std.testing.expect(std.mem.endsWith(u8, paths.control_socket_path, ".sock"));
    try std.testing.expect(std.mem.endsWith(u8, paths.control_socket_owner_path, control_socket_owner_suffix));
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1/console.log", paths.console_log_path);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1/monitor.log", paths.monitor_log_path);
}

test "lifecycle refuses to write a spec it cannot read back" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_root);
    const root = try std.fs.path.join(allocator, &.{ tmp_root, "runtime" });
    defer allocator.free(root);
    const paths = try pathsFromRoot(allocator, root, "large");
    defer paths.deinit(allocator);

    // Size `kernel_path` so the spec lands exactly on the reader's limit.
    try writeSpec(allocator, io, paths, .{ .name = "large", .kernel_path = "" });
    const base_len = (try Io.Dir.cwd().statFile(io, paths.spec_path, .{})).size;
    try Io.Dir.cwd().deleteFile(io, paths.spec_path);
    const kernel_path = try allocator.alloc(u8, max_metadata_bytes - base_len);
    defer allocator.free(kernel_path);
    @memset(kernel_path, 'k');

    try std.testing.expectError(error.SpecTooLarge, writeSpec(allocator, io, paths, .{ .name = "large", .kernel_path = kernel_path }));
    try std.testing.expectError(error.FileNotFound, readSpec(allocator, io, paths));

    try writeSpec(allocator, io, paths, .{ .name = "large", .kernel_path = kernel_path[1..] });
    try std.testing.expectEqual(max_metadata_bytes - 1, (try Io.Dir.cwd().statFile(io, paths.spec_path, .{})).size);
    var spec = try readSpec(allocator, io, paths);
    defer spec.deinit();
    try std.testing.expectEqual(kernel_path.len - 1, spec.value.kernel_path.?.len);
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
        .network = .{
            .allow_cidrs = &.{"93.184.216.34/32"},
            .allow_hosts = &.{"example.com"},
        },
        .disk_baseline_lease = .{
            .store = .rootfs_cache,
            .root = "/cache",
            .baseline_kind = .rootfs,
            .baseline_identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        },
        .exec_defaults = .{
            .env = &.{ "IMAGE_VALUE=default", "CLEAR_ME=inherited" },
            .working_dir = "/app",
        },
        .memory = memory_config.Config.fixed(512 * 1024 * 1024),
    });
    var spec = try readSpec(allocator, io, paths);
    defer spec.deinit();
    try std.testing.expectEqualStrings("bench-1", spec.value.name);
    try std.testing.expectEqualStrings("hvf", spec.value.backend);
    try std.testing.expectEqualStrings("docker.io/library/alpine:3.20", spec.value.image_ref.?);
    try std.testing.expectEqualStrings("93.184.216.34/32", spec.value.network.?.allow_cidrs[0]);
    try std.testing.expectEqualStrings("example.com", spec.value.network.?.allow_hosts[0]);
    try std.testing.expectEqual(runtime_disk_lease.Store.rootfs_cache, spec.value.disk_baseline_lease.?.store);
    try std.testing.expectEqualStrings("/cache", spec.value.disk_baseline_lease.?.root);
    try std.testing.expectEqualStrings("IMAGE_VALUE=default", spec.value.exec_defaults.?.env[0]);
    try std.testing.expectEqualStrings("CLEAR_ME=inherited", spec.value.exec_defaults.?.env[1]);
    try std.testing.expectEqualStrings("/app", spec.value.exec_defaults.?.working_dir.?);
    try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), spec.value.memory.initial_bytes);
    try std.testing.expectEqual(spec.value.memory.initial_bytes, spec.value.memory.maximum_bytes);

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

fn alwaysDead(_: i64) bool {
    return false;
}

fn alwaysAlive(_: i64) bool {
    return true;
}
