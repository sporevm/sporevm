//! The named-VM registry under `$SPOREVM_RUNTIME_DIR/vms/<name>/`: paths,
//! the name claim and its lock, the spec, ready, pid and timing files, VM
//! state, control socket ownership, and private-directory checks.
//!
//! `vms/<name>/lock` decides liveness. A claimer creates the directory and the
//! lock and holds `flock(LOCK_EX)` on it; the monitor it starts inherits the
//! lock as stdin and holds it until it exits. A held lock means the entry is
//! live, a free or missing one means it is stale. The `pid` file is only used
//! to signal the monitor.

const std = @import("std");
const TestDir = @import("test_dir.zig").TestDir;
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;
const Sha256 = std.crypto.hash.sha2.Sha256;

const generation = @import("generation.zig");
const local_paths = @import("local_paths.zig");
const memory_config = @import("memory.zig");
const guest_request = @import("guest_request.zig");
const runtime_disk_claim = @import("runtime_disk_claim.zig");
const runtime_disk_lease = @import("runtime_disk_lease.zig");
const spore = @import("spore.zig");
const topology = @import("topology.zig");
const test_support = @import("test_support.zig");

pub const max_name_len = 128;
pub const max_metadata_bytes = 128 * 1024;
const lock_file = "lock";
const spec_file = "spec.json";
const disk_claim_file = "disk-claim.json";
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
    lock_path: []const u8,
    spec_path: []const u8,
    disk_claim_path: []const u8,
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
        allocator.free(self.lock_path);
        allocator.free(self.spec_path);
        allocator.free(self.disk_claim_path);
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
    network: ?spore.Network = null,
    /// The policy the monitor's network gateway enforces, in the encoding
    /// `spore netd --policy` takes. Set exactly when `network` is. Saved
    /// lifecycle metadata drops it; restore derives it again.
    network_policy: ?[]const u8 = null,
    annotations: spore.Annotations = .{},
    sessions: []const spore.Session = &.{},
    exec_defaults: ?spore.ExecDefaults = null,
    image_ref: ?[]const u8 = null,
    resume_dir: ?[]const u8 = null,
    resume_generation: ?generation.State = null,
    memory: memory_config.Config = .{},
    vcpus: topology.VcpuCount = 1,
    guest_port: u32 = 10700,
    startup_timeout_ms: u64 = 30_000,
    timeout_ms: u64 = 30_000,
    console_log_path: ?[]const u8 = null,
};

/// A fork child's one-use disk-head claim, written to `disk-claim.json` by
/// the fork CLI and deleted by the child's monitor once it has claimed.
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
    /// No entry directory.
    absent,
    /// The lock is held and the monitor has not written `ready.json`.
    starting,
    /// The lock is held and `ready.json` exists.
    ready,
    /// The entry exists and nobody holds its lock.
    stale,

    pub fn name(self: VmState) []const u8 {
        return switch (self) {
            .absent => "absent",
            .starting => "starting",
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
    const lock_path = try std.fs.path.resolve(allocator, &.{ vm_dir, lock_file });
    errdefer allocator.free(lock_path);
    const spec_path = try std.fs.path.resolve(allocator, &.{ vm_dir, spec_file });
    errdefer allocator.free(spec_path);
    const disk_claim_path = try std.fs.path.resolve(allocator, &.{ vm_dir, disk_claim_file });
    errdefer allocator.free(disk_claim_path);
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
        .lock_path = lock_path,
        .spec_path = spec_path,
        .disk_claim_path = disk_claim_path,
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

/// A registry entry directory, which the monitor holds open for its whole
/// life. Writes go through the directory fd, so once `rm` deletes the entry
/// they fail instead of landing in a new entry that reuses the name.
pub const Entry = struct {
    dir: Io.Dir,

    pub fn open(io: Io, paths: Paths) !Entry {
        // `iterate` opens a readable fd instead of an O_PATH one, so it can
        // be fsynced.
        return .{ .dir = try openDirPath(io, paths.vm_dir, .{ .follow_symlinks = false, .iterate = true }) };
    }

    pub fn close(self: *Entry, io: Io) void {
        self.dir.close(io);
        self.* = undefined;
    }

    /// Reports whether `vm_dir` no longer names this directory: the entry was
    /// removed, and perhaps created again under the same name. While this fd
    /// is open, its inode number cannot be reused on the same filesystem.
    pub fn replaced(self: Entry, io: Io, vm_dir: []const u8) bool {
        const held = self.dir.stat(io) catch return false;
        const current = Io.Dir.cwd().statFile(io, vm_dir, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return true,
            else => return false,
        };
        return current.kind != .directory or current.inode != held.inode;
    }

    pub fn readSpec(self: Entry, allocator: std.mem.Allocator, io: Io) !std.json.Parsed(Spec) {
        return readSpecIn(allocator, io, self.dir, spec_file);
    }

    /// Replaces the spec atomically and durably.
    pub fn writeSpec(self: Entry, allocator: std.mem.Allocator, io: Io, spec: Spec) !void {
        try validateSpec(spec);
        const json = try std.json.Stringify.valueAlloc(allocator, spec, .{ .whitespace = .indent_2 });
        defer allocator.free(json);
        // readSpecIn must read back every spec written here, and readFileAlloc
        // fails once its limit is reached.
        if (json.len >= max_metadata_bytes) return error.SpecTooLarge;
        var file = try self.dir.createFileAtomic(io, spec_file, .{ .permissions = @enumFromInt(0o600), .replace = true });
        defer file.deinit(io);
        try file.file.writeStreamingAll(io, json);
        try file.file.sync(io);
        try file.replace(io);
        if (std.c.fsync(self.dir.handle) != 0) return error.IoFailed;
    }

    pub fn writePid(self: Entry, allocator: std.mem.Allocator, io: Io, pid: i64) !void {
        if (pid <= 0) return error.InvalidPid;
        const data = try std.fmt.allocPrint(allocator, "{d}\n", .{pid});
        defer allocator.free(data);
        try self.dir.writeFile(io, .{ .sub_path = pid_file, .data = data });
    }

    pub fn writeReady(self: Entry, allocator: std.mem.Allocator, io: Io, ready: Ready) !void {
        try writeJson(allocator, io, self.dir, ready_file, ready);
    }

    pub fn writeMonitorTiming(self: Entry, allocator: std.mem.Allocator, io: Io, timing: MonitorTiming) !void {
        try writeJson(allocator, io, self.dir, monitor_timing_file, timing);
    }

    pub fn writeMonitorStats(self: Entry, allocator: std.mem.Allocator, io: Io, stats: MonitorStats) !void {
        try writeJson(allocator, io, self.dir, monitor_stats_file, stats);
    }

    /// Reads and deletes the entry's one-use fork claim. Returns null when
    /// the entry has none.
    pub fn takeDiskForkClaim(self: Entry, allocator: std.mem.Allocator, io: Io, spec: Spec) !?std.json.Parsed(DiskForkClaim) {
        const data = self.dir.readFileAlloc(io, disk_claim_file, allocator, .limited(max_metadata_bytes)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => |e| return e,
        };
        defer allocator.free(data);
        var parsed = try std.json.parseFromSlice(DiskForkClaim, allocator, data, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        try validateDiskForkClaim(spec, parsed.value);
        try self.dir.deleteFile(io, disk_claim_file);
        return parsed;
    }
};

/// Replaces the spec of an existing entry. It never creates the directory, so
/// a writer racing `rm` fails instead of bringing the entry back.
pub fn writeSpec(allocator: std.mem.Allocator, io: Io, paths: Paths, spec: Spec) !void {
    var entry = try Entry.open(io, paths);
    defer entry.close(io);
    try entry.writeSpec(allocator, io, spec);
}

pub fn readSpec(allocator: std.mem.Allocator, io: Io, paths: Paths) !std.json.Parsed(Spec) {
    return readSpecFile(allocator, io, paths.spec_path);
}

pub fn readSpecFile(allocator: std.mem.Allocator, io: Io, spec_path: []const u8) !std.json.Parsed(Spec) {
    return readSpecIn(allocator, io, Io.Dir.cwd(), spec_path);
}

fn readSpecIn(allocator: std.mem.Allocator, io: Io, dir: Io.Dir, sub_path: []const u8) !std.json.Parsed(Spec) {
    const data = try dir.readFileAlloc(io, sub_path, allocator, .limited(max_metadata_bytes));
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
    if (spec.exec_defaults) |defaults| try guest_request.validateGuestExecContext(defaults.env, defaults.working_dir);
    if (spec.disk_baseline_lease) |lease| try lease.validate();
}

pub fn writeDiskForkClaim(allocator: std.mem.Allocator, io: Io, paths: Paths, spec: Spec, claim_value: DiskForkClaim) !void {
    try validateDiskForkClaim(spec, claim_value);
    const json = try std.json.Stringify.valueAlloc(allocator, claim_value, .{});
    defer allocator.free(json);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = paths.disk_claim_path, .data = json, .flags = .{ .exclusive = true, .permissions = @enumFromInt(0o600) } });
}

fn validateDiskForkClaim(spec: Spec, claim_value: DiskForkClaim) !void {
    if (!std.fs.path.isAbsolute(claim_value.source_socket_path)) return error.BadManifest;
    try validateControlSocketPath(claim_value.source_socket_path);
    try runtime_disk_claim.validateClaimRequest(claim_value.request);
    const lease = spec.disk_baseline_lease orelse return error.BadManifest;
    if (!std.mem.eql(u8, claim_value.request.child, spec.name) or
        claim_value.request.baseline_kind != lease.baseline_kind or
        !std.mem.eql(u8, claim_value.request.baseline_identity, lease.baseline_identity)) return error.BadManifest;
}

pub fn writeReady(allocator: std.mem.Allocator, io: Io, paths: Paths, ready: Ready) !void {
    var entry = try Entry.open(io, paths);
    defer entry.close(io);
    try entry.writeReady(allocator, io, ready);
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

pub fn writeMonitorStats(allocator: std.mem.Allocator, io: Io, paths: Paths, stats: MonitorStats) !void {
    var entry = try Entry.open(io, paths);
    defer entry.close(io);
    try entry.writeMonitorStats(allocator, io, stats);
}

fn writeTimingJson(allocator: std.mem.Allocator, io: Io, path: []const u8, timing: anytype) !void {
    try writeJson(allocator, io, Io.Dir.cwd(), path, timing);
}

fn writeJson(allocator: std.mem.Allocator, io: Io, dir: Io.Dir, sub_path: []const u8, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = json });
}

pub fn writePid(allocator: std.mem.Allocator, io: Io, paths: Paths, pid: i64) !void {
    var entry = try Entry.open(io, paths);
    defer entry.close(io);
    try entry.writePid(allocator, io, pid);
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

/// Reports an entry's state from its lock. Probes never write; a shared lock
/// taken here is released before returning.
pub fn probe(io: Io, paths: Paths) !VmState {
    while (true) {
        const stat = Io.Dir.cwd().statFile(io, paths.vm_dir, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return .absent,
            else => |e| return e,
        };
        if (stat.kind != Io.File.Kind.directory) return error.InvalidVMState;
        const lock = Io.Dir.cwd().openFile(io, paths.lock_path, lock_open_options) catch |err| switch (err) {
            error.FileNotFound => return if (try pathExists(io, paths.vm_dir)) .stale else .absent,
            else => |e| return e,
        };
        defer lock.close(io);
        const free = try lock.tryLock(io, .shared);
        // `rm` deletes the lock file while holding it. A lock opened before
        // that is not the entry's lock any more; look again.
        if (!try lockIsCurrent(io, paths, lock)) continue;
        if (free) return .stale;
        return if (try pathExists(io, paths.ready_path)) .ready else .starting;
    }
}

const lock_open_options: Io.Dir.OpenFileOptions = .{ .follow_symlinks = false, .allow_directory = false };

fn lockIsCurrent(io: Io, paths: Paths, lock: Io.File) !bool {
    const held = try lock.stat(io);
    const current = Io.Dir.cwd().statFile(io, paths.lock_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return held.inode == current.inode;
}

/// A claimer's exclusive hold on a new entry. Every lock fd is close-on-exec;
/// only the monitor spawn passes it on, as the monitor's stdin.
pub const Claim = struct {
    lock: Io.File,

    /// Closes the claimer's copy once the monitor holds the lock.
    pub fn release(self: *Claim, io: Io) void {
        self.lock.close(io);
        self.* = undefined;
    }

    /// Gives up a claim whose monitor never started: deletes the entry while
    /// still holding its lock. The control socket is released only if this
    /// entry owns it.
    pub fn abandon(self: *Claim, io: Io, paths: Paths) void {
        releaseControlSocketPath(io, paths) catch {};
        Io.Dir.cwd().deleteTree(io, paths.vm_dir) catch {};
        self.release(io);
    }
};

/// Claims a name for create, restore or a fork child. Fails with
/// `NamedVmExists` when the entry exists in any state.
pub fn claim(io: Io, paths: Paths) !Claim {
    try ensureDirPath(io, paths.runtime_root);
    try requirePrivateDir(io, paths.runtime_root);
    try ensureDirPath(io, paths.vms_dir);
    try requirePrivateDir(io, paths.vms_dir);
    Io.Dir.cwd().createDir(io, paths.vm_dir, private_dir_permissions) catch |err| switch (err) {
        error.PathAlreadyExists => return error.NamedVmExists,
        else => |e| return e,
    };
    const lock = Io.Dir.cwd().createFile(io, paths.lock_path, .{
        .exclusive = true,
        .read = true,
        .permissions = @enumFromInt(0o600),
    }) catch |err| switch (err) {
        // A racing `rm` saw the directory without a lock and removed it.
        error.FileNotFound, error.PathAlreadyExists => return claimLost(paths),
        else => |e| {
            Io.Dir.cwd().deleteDir(io, paths.vm_dir) catch {};
            return e;
        },
    };
    errdefer lock.close(io);
    // Only a prober (briefly) or a racing `rm` can hold a lock file this
    // claim just created, so waiting is bounded. After an `rm` the file is
    // no longer the entry's lock.
    try lock.lock(io, .exclusive);
    if (!try lockIsCurrent(io, paths, lock)) return claimLost(paths);
    return .{ .lock = lock };
}

fn claimLost(paths: Paths) error{NamedVmBusy} {
    setLastError("named VM {s} was removed while it was being claimed", .{std.fs.path.basename(paths.vm_dir)});
    return error.NamedVmBusy;
}

/// Takes the entry's lock so the caller can delete the entry while holding
/// it. Returns null while a claimer or monitor holds the lock, and
/// `NamedVmNotFound` once the entry is gone.
pub fn tryLockForRemoval(io: Io, paths: Paths) !?Io.File {
    while (true) {
        const lock = Io.Dir.cwd().openFile(io, paths.lock_path, lock_open_options) catch |err| switch (err) {
            // An entry whose claimer died before creating the lock. Creating
            // it here makes a claimer that is still about to create it fail.
            error.FileNotFound => Io.Dir.cwd().createFile(io, paths.lock_path, .{
                .exclusive = true,
                .read = true,
                .permissions = @enumFromInt(0o600),
            }) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => continue,
                error.FileNotFound => return error.NamedVmNotFound,
                else => |e| return e,
            },
            else => |e| return e,
        };
        errdefer lock.close(io);
        const free = try lock.tryLock(io, .exclusive);
        if (try lockIsCurrent(io, paths, lock)) {
            if (free) return lock;
            lock.close(io);
            return null;
        }
        lock.close(io);
    }
}

/// Verifies that the monitor's stdin is the lock inside `entry` and takes it
/// over: the returned fd is close-on-exec, so no helper the monitor starts
/// can keep a dead VM looking live, and fd 0 becomes `/dev/null`.
pub fn adoptMonitorLock(io: Io, entry: Entry) !Io.File {
    return adoptLockFd(io, entry, 0);
}

fn adoptLockFd(io: Io, entry: Entry, inherited: std.c.fd_t) !Io.File {
    const stdin = Io.File{ .handle = inherited, .flags = .{ .nonblocking = false } };
    const held = stdin.stat(io) catch return error.MonitorLockMissing;
    const current = entry.dir.statFile(io, lock_file, .{ .follow_symlinks = false }) catch return error.MonitorLockMissing;
    if (held.kind != .file or current.kind != .file or held.inode != current.inode) return error.MonitorLockMissing;
    // The claimer's lock is on the open file description this fd shares, so
    // this succeeds exactly when the monitor inherited it.
    if (!try stdin.tryLock(io, .exclusive)) return error.MonitorLockMissing;
    const fd = std.c.fcntl(inherited, std.c.F.DUPFD_CLOEXEC, @as(c_int, 3));
    if (fd < 0) return error.MonitorLockMissing;
    errdefer _ = std.c.close(fd);
    const null_fd = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (null_fd < 0) return error.MonitorLockMissing;
    defer _ = std.c.close(null_fd);
    if (std.c.dup2(null_fd, inherited) < 0) return error.MonitorLockMissing;
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
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
    const deep_root = "/var/folders/ab/" ++ (test_support.repeat("r", 160)) ++ "/deep-runtime-dir";
    const long_name = test_support.repeat("n", max_name_len);
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
    const at_limit = "/" ++ (test_support.repeat("a", (max_control_socket_path_len - 1)));
    try validateControlSocketPath(at_limit);
    try std.testing.expectError(error.ControlSocketPathTooLong, validateControlSocketPath(at_limit ++ "b"));
}

test "named control socket ownership detects hash collisions and cleans up" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var root_dir = try TestDir.init();
    defer root_dir.deinit();
    const root = try root_dir.path("runtime");
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);
    defer {
        Io.Dir.cwd().deleteFile(io, paths.control_socket_owner_path) catch {};
        Io.Dir.cwd().deleteFile(io, paths.control_socket_path) catch {};
    }

    try Io.Dir.cwd().createDirPath(io, paths.vm_dir);
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
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1/lock", paths.lock_path);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1/spec.json", paths.spec_path);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1/disk-claim.json", paths.disk_claim_path);
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
    try ensureDirPath(io, paths.vm_dir);

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
    var root_dir = try TestDir.init();
    defer root_dir.deinit();
    const root = try root_dir.path("runtime");
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);
    try ensureDirPath(io, paths.vm_dir);

    try writeSpec(allocator, io, paths, .{
        .name = "bench-1",
        .backend = "hvf",
        .image_ref = "docker.io/library/alpine:3.20",
        .network = .{
            .allow_cidrs = &.{"93.184.216.34/32"},
            .allow_hosts = &.{"example.com"},
        },
        .disk_baseline_lease = .{
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

test "registry state comes from the lock, not the pid" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_root);
    const root = try std.fs.path.join(allocator, &.{ tmp_root, "runtime" });
    defer allocator.free(root);
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);

    try std.testing.expectEqual(VmState.absent, try probe(io, paths));
    var held = try claim(io, paths);
    try std.testing.expectEqual(VmState.starting, try probe(io, paths));
    try std.testing.expectError(error.NamedVmExists, claim(io, paths));
    try std.testing.expect((try tryLockForRemoval(io, paths)) == null);
    try writeReady(allocator, io, paths, .{ .pid = 1, .control_socket_path = paths.control_socket_path });
    // pid 1 is alive and not ours, so kill(1, 0) fails with EPERM. Only
    // the lock decides liveness.
    try writePid(allocator, io, paths, 1);
    try std.testing.expectEqual(VmState.ready, try probe(io, paths));
    // An unreadable spec does not make a live entry stale.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = paths.spec_path, .data = "not json" });
    try std.testing.expectEqual(VmState.ready, try probe(io, paths));

    held.release(io);
    try std.testing.expectEqual(VmState.stale, try probe(io, paths));
    try std.testing.expectError(error.NamedVmExists, claim(io, paths));
    const lock = (try tryLockForRemoval(io, paths)).?;
    try std.testing.expectEqual(VmState.ready, try probe(io, paths));
    try deleteVmState(io, paths);
    lock.close(io);
    try std.testing.expectEqual(VmState.absent, try probe(io, paths));

    // A claimer that died before creating the lock leaves a stale entry
    // that removal can still lock.
    try Io.Dir.cwd().createDir(io, paths.vm_dir, private_dir_permissions);
    try std.testing.expectEqual(VmState.stale, try probe(io, paths));
    const orphan_lock = (try tryLockForRemoval(io, paths)).?;
    try deleteVmState(io, paths);
    orphan_lock.close(io);

    var reclaimed = try claim(io, paths);
    reclaimed.abandon(io, paths);
    try std.testing.expectEqual(VmState.absent, try probe(io, paths));
}

test "registry claims a name exactly once" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_root);
    const root = try std.fs.path.join(allocator, &.{ tmp_root, "runtime" });
    defer allocator.free(root);
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);

    const Claimer = struct {
        fn run(claim_io: Io, claim_paths: Paths, start: *std.atomic.Value(bool), result: *?Claim, failure: *?anyerror) void {
            while (!start.load(.acquire)) std.atomic.spinLoopHint();
            result.* = claim(claim_io, claim_paths) catch |err| {
                failure.* = err;
                return;
            };
        }
    };
    var start = std.atomic.Value(bool).init(false);
    var results = @as([8]?Claim, @splat(null));
    var failures = @as([8]?anyerror, @splat(null));
    var threads: [8]std.Thread = undefined;
    for (&threads, &results, &failures) |*thread, *result, *failure| {
        thread.* = try std.Thread.spawn(.{}, Claimer.run, .{ io, paths, &start, result, failure });
    }
    start.store(true, .release);
    for (threads) |thread| thread.join();

    var winners: usize = 0;
    for (&results, failures) |*result, failure| {
        if (result.*) |*won| {
            winners += 1;
            won.release(io);
        } else {
            try std.testing.expectEqual(@as(?anyerror, error.NamedVmExists), failure);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), winners);
}

test "registry writers never recreate a removed entry" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_root);
    const root = try std.fs.path.join(allocator, &.{ tmp_root, "runtime" });
    defer allocator.free(root);
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);

    // A monitor still running after `rm` deleted its entry.
    try ensureDirPath(io, paths.vm_dir);
    var entry = try Entry.open(io, paths);
    defer entry.close(io);
    try std.testing.expect(!entry.replaced(io, paths.vm_dir));
    try Io.Dir.cwd().deleteTree(io, paths.vm_dir);
    try std.testing.expect(entry.replaced(io, paths.vm_dir));
    try std.testing.expectError(error.FileNotFound, writePid(allocator, io, paths, 1));
    try std.testing.expectError(error.FileNotFound, writeReady(allocator, io, paths, .{ .pid = 1, .control_socket_path = paths.control_socket_path }));
    try std.testing.expectError(error.FileNotFound, writeSpec(allocator, io, paths, .{ .name = "bench-1" }));
    try std.testing.expect(!try pathExists(io, paths.vm_dir));

    // Nor do they write into a new entry that reuses the name.
    var reused = try claim(io, paths);
    defer reused.abandon(io, paths);
    try std.testing.expect(entry.replaced(io, paths.vm_dir));
    try std.testing.expectError(error.FileNotFound, entry.writePid(allocator, io, 1));
    try std.testing.expectError(error.FileNotFound, entry.writeReady(allocator, io, .{ .pid = 1, .control_socket_path = paths.control_socket_path }));
    try std.testing.expectError(error.FileNotFound, entry.writeMonitorStats(allocator, io, .{}));
    try std.testing.expectError(error.FileNotFound, entry.writeSpec(allocator, io, .{ .name = "bench-1" }));
    var names = try openDirPath(io, paths.vm_dir, .{ .iterate = true });
    defer names.close(io);
    var it = names.iterate();
    while (try it.next(io)) |file| try std.testing.expectEqualStrings(lock_file, file.name);
}

test "monitor lock adoption leaves no inheritable copy" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_root);
    const root = try std.fs.path.join(allocator, &.{ tmp_root, "runtime" });
    defer allocator.free(root);
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);

    // fd 0 belongs to the test runner, so another inheritable fd stands in
    // for the monitor's stdin.
    var held = try claim(io, paths);
    const inherited = std.c.dup(held.lock.handle);
    try std.testing.expect(inherited >= 0);
    held.release(io);
    var entry = try Entry.open(io, paths);
    defer entry.close(io);
    var adopted = try adoptLockFd(io, entry, inherited);
    defer _ = std.c.close(inherited);
    try std.testing.expect(std.c.fcntl(adopted.handle, std.c.F.GETFD) & std.c.FD_CLOEXEC != 0);
    const replaced = try (Io.File{ .handle = inherited, .flags = .{ .nonblocking = false } }).stat(io);
    try std.testing.expectEqual(Io.File.Kind.character_device, replaced.kind);
    try std.testing.expectEqual(VmState.starting, try probe(io, paths));

    // A helper started after adoption, like netd, must not keep the entry
    // live once the monitor is gone.
    var helper = try std.process.spawn(io, .{ .argv = &.{ "/bin/sleep", "5" }, .stdin = .ignore });
    defer helper.kill(io);
    adopted.close(io);
    try std.testing.expectEqual(VmState.stale, try probe(io, paths));

    // A stdin that is not the entry's lock is refused.
    const other = try Io.Dir.cwd().createFile(io, paths.spec_path, .{ .read = true });
    defer other.close(io);
    try std.testing.expectError(error.MonitorLockMissing, adoptLockFd(io, entry, other.handle));
}

test "fork disk claims are read once and must name the child" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_root);
    const paths = try pathsFromRoot(allocator, tmp_root, "child");
    defer paths.deinit(allocator);
    try Io.Dir.cwd().createDirPath(io, paths.vm_dir);

    const digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const spec = Spec{
        .name = "child",
        .disk_baseline_lease = .{ .root = "/cache", .baseline_kind = .rootfs, .baseline_identity = digest },
    };
    var fork_claim = DiskForkClaim{
        .source_socket_path = "/tmp/source.sock",
        .request = .{
            .type = runtime_disk_claim.claim_type,
            .schema = runtime_disk_claim.claim_schema,
            .token = test_support.repeat("b", 64),
            .batch = "batch",
            .child = "other",
            .child_index = 0,
            .baseline_kind = .rootfs,
            .baseline_identity = digest,
        },
    };
    try std.testing.expectError(error.BadManifest, writeDiskForkClaim(allocator, io, paths, spec, fork_claim));
    fork_claim.request.child = "child";
    try writeDiskForkClaim(allocator, io, paths, spec, fork_claim);
    var entry = try Entry.open(io, paths);
    defer entry.close(io);
    var taken = (try entry.takeDiskForkClaim(allocator, io, spec)).?;
    defer taken.deinit();
    try std.testing.expectEqualStrings(fork_claim.request.token, taken.value.request.token);
    try std.testing.expect((try entry.takeDiskForkClaim(allocator, io, spec)) == null);
}

test "lifecycle rejects insecure existing runtime directories" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var root_dir = try TestDir.init();
    defer root_dir.deinit();
    const root = root_dir.root;
    _ = try Io.Dir.cwd().createDirPathStatus(io, root, @enumFromInt(0o755));
    try Io.Dir.cwd().setFilePermissions(io, root, @enumFromInt(0o755), .{});

    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);
    try std.testing.expectError(error.InsecureRuntimeDir, validateExistingRuntimeDirs(io, paths));
}
