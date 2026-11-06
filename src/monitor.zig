//! Per-VM monitor process and local control protocol.

const std = @import("std");
const TestDir = @import("test_dir.zig").TestDir;
const builtin = @import("builtin");
const local_paths = @import("local_paths.zig");
const Context = @import("context.zig").Context;
const manifest_test_support = @import("manifest_test_support.zig");
const rootfs_mod = @import("rootfs.zig");
const rootfs_cache = @import("rootfs_cache.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const saved_spore_pin = @import("saved_spore_pin.zig");
const snapshot_publication = @import("snapshot_publication.zig");
const chunk_sealer = @import("chunk_sealer.zig");
const generation = @import("generation.zig");
const image_store_mod = @import("image_store.zig");
const Io = std.Io;
const net = std.Io.net;

const lifecycle = @import("lifecycle.zig");
const vm_registry = @import("vm_registry.zig");
const monitor_jail = @import("monitor_jail.zig");
const monitor_protocol = @import("monitor_protocol.zig");
const runtime_disk_claim = @import("runtime_disk_claim.zig");
const runtime_disk = @import("runtime_disk.zig");
const runtime_disk_fork = @import("runtime_disk_fork.zig");
const runtime_disk_fork_capture = @import("runtime_disk_fork_capture.zig");
const runtime_disk_fork_control = @import("runtime_disk_fork_control.zig");
const runtime_disk_lease = @import("runtime_disk_lease.zig");
const net_gateway = @import("net_gateway.zig");
const run = @import("run.zig");
const spore = @import("spore.zig");
const spore_net_policy = @import("spore_net_policy.zig");
const spore_stream = @import("spore_stream.zig");
const system = @import("system.zig");
const test_barrier = @import("test_barrier.zig");
const topology = @import("topology.zig");
const version = @import("version.zig");
const vsock = @import("virtio/vsock.zig");
const vsock_control = @import("virtio/vsock_control.zig");
const vsock_stream = @import("virtio/vsock_stream.zig");

const max_control_response = monitor_protocol.max_response_bytes;
const max_suspend_path = 4096;
const stats_write_interval_ms = 250;
const registry_check_interval_ms = 1_000;
/// Guest operations run on handler threads, at most the listen backlog.
const max_control_handlers = 8;
/// A client must send its whole request line this soon after connecting.
const control_request_timeout_ms = 1_000;
const control_accept_poll_ms = 100;
const control_queue_poll_ms = 10;
const removal_message = "named VM is being removed";
/// How a save refused for the root disk's image store is explained.
const save_refused_image_store = "the image store of the root disk could not supply every object";

const SnapshotLeaseHandoffTestFault = struct {
    fail_before_source_spec: bool = false,
    crash_after: enum { none, active_lease, source_spec } = .none,
};

pub const testing = if (builtin.is_test) struct {
    pub var snapshot_lease_handoff_fault: SnapshotLeaseHandoffTestFault = .{};
    var snapshot_lease_handoff_barrier: ?*test_barrier.Barrier = null;
    var disk_fork_cache_waits: std.atomic.Value(u32) = .init(0);

    pub fn persistSourceDiskLeaseHandoffForCrashProof(
        io: Io,
        allocator: std.mem.Allocator,
        runtime_root: []const u8,
        source_paths: lifecycle.Paths,
        disk: spore.Disk,
        lease: runtime_disk_lease.Lease,
        active_slot: *?runtime_disk_lease.Active,
    ) !void {
        var entry = try vm_registry.Entry.open(io, source_paths);
        defer entry.close(io);
        try persistSourceDiskLeaseHandoff(io, allocator, runtime_root, entry, disk, lease, active_slot);
    }
} else struct {};
const streaming_send_deadline_ms = 25;
const disk_claim_timeout_ns = 5 * 60 * std.time.ns_per_s;

const monitor_usage =
    \\Usage:
    \\  spore monitor NAME
    \\
    \\Internal helper for named VM lifecycle monitors. `spore create`,
    \\`spore restore --name` and `spore vm fork` start it after claiming NAME:
    \\the VM's spec is read from its registry entry, and stdin must be the
    \\entry's lock.
    \\
    \\Options:
    \\  -h, --help              Show this help
    \\
;

const Phase = enum { pending, active, done };

/// The guest operation that holds the slot. Its slices are borrowed from the
/// handler thread that submitted it, which waits until the operation is
/// done; the VM thread stops using them before it marks the operation done.
const Op = union(enum) {
    idle,
    /// The readiness request, attached at startup. The run fails unless the
    /// guest answers it.
    readiness,
    exec: Exec,
    /// Captures the VM, which then ends; the slot stays taken.
    @"suspend": Capture,
    snapshot: Capture,
    disk_fork: DiskFork,

    /// Whether the operation finished and left its response.
    fn done(op: Op) bool {
        return switch (op) {
            .idle, .readiness => false,
            .exec => |exec| exec.phase == .done,
            .@"suspend", .snapshot => |capture| capture.phase == .done,
            .disk_fork => |fork| fork.phase == .done,
        };
    }
};

const Exec = struct {
    phase: Phase = .pending,
    /// The guest request; attaching the stream copies it.
    request: []const u8,
    session_sequence: u64,
    submitted_ms: u64,
    output: union(enum) {
        /// Kept in `ExecServer.capture` and returned in the response.
        captured,
        streamed: Streamed,
    },
};

/// Output written to the client as SPIO frames while the guest runs.
const Streamed = struct {
    client_fd: std.c.fd_t,
    /// Whether a timing event precedes the exit frame.
    timing: bool,
    stdout_offset: u64 = 0,
    stderr_offset: u64 = 0,
    terminal_offset: u64 = 0,
    /// Set once a frame could not be written; nothing more is sent.
    write_failed: bool = false,
};

const Capture = struct {
    phase: Phase = .pending,
    dir: []const u8,
    publish_dir: ?[]const u8 = null,
};

const DiskFork = struct {
    /// `preparing` holds the slot while the handler names the baseline,
    /// before the VM loop sees the fork.
    phase: enum { preparing, pending, active, done } = .preparing,
    request: runtime_disk_fork_control.PrepareRequest,
    baseline: ?DiskBaseline = null,
};

/// The output of the readiness request or a captured exec. Only the VM
/// thread writes and reads it.
const OutputCapture = struct {
    stdout: [lifecycle.exec_named_capture_limit]u8 = undefined,
    stdout_len: usize = 0,
    stdout_truncated: bool = false,
    stderr: [lifecycle.exec_named_capture_limit]u8 = undefined,
    stderr_len: usize = 0,
    stderr_truncated: bool = false,

    fn reset(self: *OutputCapture) void {
        self.stdout_len = 0;
        self.stdout_truncated = false;
        self.stderr_len = 0;
        self.stderr_truncated = false;
    }

    fn append(self: *OutputCapture, output: vsock_stream.HostStreamOutput, bytes: []const u8) void {
        const stderr = output == .stderr;
        const buffer: []u8 = if (stderr) &self.stderr else &self.stdout;
        const len = if (stderr) &self.stderr_len else &self.stdout_len;
        const n = @min(bytes.len, buffer.len - len.*);
        @memcpy(buffer[len.*..][0..n], bytes[0..n]);
        len.* += n;
        if (n < bytes.len) {
            if (stderr) self.stderr_truncated = true else self.stdout_truncated = true;
        }
    }
};

const readiness_request = "{\"type\":\"ready\"}\n";

fn claimRuntimeDiskHead(io: Io, allocator: std.mem.Allocator, claim: vm_registry.DiskForkClaim) !runtime_disk_fork.Head {
    const address = try net.UnixAddress.init(claim.source_socket_path);
    const stream = address.connect(io) catch return error.MonitorUnavailable;
    defer stream.close(io);
    try runtime_disk_claim.writeClaimRequest(allocator, stream.socket.handle, claim.request);
    return runtime_disk_claim.receiveHead(allocator, stream.socket.handle);
}

pub fn cli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    const start_ms = lifecycle.monotonicMs();
    if (wantsHelp(args)) {
        try stdout.writeAll(monitor_usage);
        try stdout.flush();
        return;
    }

    const allocator = init.arena.allocator();
    const spore_executable = try std.process.executablePathAlloc(init.io, allocator);
    if (monitor_jail.wantsSmoke(init.environ_map)) {
        try monitor_jail.applyForMonitor(init.environ_map);
        try monitor_jail.smokeDeniedExec(init.io);
        try runtime_disk_claim.smokeRoundTrip(allocator);
        return;
    }

    if (args.len != 1) usageExit();
    const name = args[0];
    lifecycle.validateName(name) catch usageExit();
    const paths = try lifecycle.pathsFor(allocator, init.environ_map, name);
    // Every monitor write goes through the entry it was started for.
    var entry = vm_registry.Entry.open(init.io, paths) catch |err| {
        std.debug.print("spore monitor: cannot open the registry entry of {s}: {s}\n", .{ name, @errorName(err) });
        std.process.exit(2);
    };
    defer entry.close(init.io);
    // The claimer passes the entry's lock as stdin. Holding it for the
    // monitor's whole life is what makes the VM live.
    var registry_lock = vm_registry.adoptMonitorLock(init.io, entry) catch |err| {
        std.debug.print("spore monitor: stdin is not the registry lock of {s}: {s}\n", .{ name, @errorName(err) });
        std.process.exit(2);
    };
    defer registry_lock.close(init.io);
    try entry.writePid(allocator, init.io, currentPid());
    try lifecycle.validateControlSocketOwner(init.io, paths);
    const paths_ms = lifecycle.monotonicMs();

    var parsed_spec = try entry.readSpec(allocator, init.io);
    defer parsed_spec.deinit();
    const spec = parsed_spec.value;
    if (!std.mem.eql(u8, spec.name, name)) return error.BadManifest;
    const requested_backend = run.Backend.parse(spec.backend) orelse return error.UnsupportedBackend;
    // No host probe here: `create` probes before spawning its monitor, x86
    // rejects restore and fork monitors below, and opening the backend
    // reports an unusable arm64 KVM.
    const selected_backend = requested_backend.resolveForHost() catch |err| {
        std.debug.print("spore monitor: backend unavailable: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    run.validateFreshProductPolicy(selected_backend, .{
        .memory = spec.memory,
        .vcpus = spec.vcpus,
        .resuming = spec.resume_dir != null or spec.resume_generation != null or
            spec.sessions.len != 0 or spec.disk != null or spec.disk_baseline_lease != null,
        .rootfs = spec.rootfs_path != null or spec.rootfs != null or
            spec.image_ref != null or spec.disk != null,
        .network = spec.network != null,
    }) catch |err| {
        std.debug.print("spore monitor: x86 fresh profile rejected request: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    if (spec.resume_dir != null and spec.rootfs_path != null) {
        std.debug.print("spore monitor: direct resume with a rootfs path is not supported; use lifecycle metadata for disk-backed named resume\n", .{});
        std.process.exit(2);
    }
    try topology.validateVcpuCount(spec.vcpus);
    try spec.memory.validate();
    const network = try monitorNetwork(allocator, spec);
    const parsed_ms = lifecycle.monotonicMs();
    var gateway: net_gateway.Process = undefined;
    var gateway_active = false;
    if (network.mode == .spore) {
        try gateway.start(init.io, allocator, spore_executable, false, network.policy);
        gateway_active = true;
    }
    defer if (gateway_active) gateway.deinit();
    try monitor_jail.applyForMonitor(init.environ_map);
    const spec_resume_generation_params = if (spec.resume_generation) |state| blk: {
        var gen_dev = generation.Device{};
        try gen_dev.restore(allocator, state);
        break :blk try allocator.dupe(u8, gen_dev.paramsPayload());
    } else null;
    const spec_exec_defaults = spec.exec_defaults orelse lifecycle.ExecDefaults{};
    const managed_boot_descriptor = if (spec.kernel_path == null and spec.initrd_path == null and
        init.environ_map.get("SPOREVM_KERNEL_IMAGE") == null and init.environ_map.get("SPOREVM_RUN_INITRD") == null)
        run.resolveManagedMonitorBootDescriptor(init, allocator) catch |err| {
            std.debug.print("spore monitor: managed boot setup failed: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        }
    else
        null;
    const managed_boot_artifacts = if (managed_boot_descriptor) |descriptor|
        run.materializeManagedMonitorBootArtifacts(init.io, allocator, descriptor) catch |err| {
            std.debug.print("spore monitor: managed boot verification failed: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        }
    else
        null;
    const kernel_path = if (managed_boot_descriptor) |descriptor|
        descriptor.kernel_path
    else
        spec.kernel_path orelse run.resolveDefaultKernelPath(init, allocator) catch |err| {
            std.debug.print("spore monitor: kernel setup failed: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
    const initrd_path = if (managed_boot_descriptor != null) null else run.resolveConfiguredInitrdPath(init, spec.initrd_path) catch |err| {
        std.debug.print("spore monitor: initrd setup failed: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    const assets_ms = lifecycle.monotonicMs();

    var disk_claim = try entry.takeDiskForkClaim(allocator, init.io, spec);
    defer if (disk_claim) |*claim| claim.deinit();
    var runtime_disk_head: ?runtime_disk_fork.Head = if (disk_claim) |claim|
        try claimRuntimeDiskHead(init.io, allocator, claim.value)
    else
        null;
    defer if (runtime_disk_head) |*head| head.deinit();

    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    var server = try ExecServer.init(allocator, init.io, entry, paths.vm_dir, paths.runtime_root, paths.control_socket_path, cache_root, spec.guest_port, spec.timeout_ms, spec_resume_generation_params, spec_exec_defaults);
    defer server.disk_claims.deinit();
    defer if (server.disk_baseline_active) |*active| active.deinit();
    // Runs after the accept thread has joined every handler, any of which
    // may have been fetching for a save.
    defer if (server.image_store) |fetcher| fetcher.release();
    if (spec.disk_baseline_lease) |lease| {
        var cache_lock: ?rootfs_mod.RootfsCacheLock = if (lease.store == .rootfs_cache)
            try rootfs_mod.lockRootfsCacheExclusive(init.io, allocator, lease.root)
        else
            null;
        defer if (cache_lock) |*lock| lock.deinit();
        server.disk_baseline_active = try runtime_disk_lease.acquireActive(init.io, allocator, paths.runtime_root, lease);
    }
    const metadata_ms = lifecycle.monotonicMs();
    server.startup = .{
        .timing = .{
            .parse_ms = parsed_ms - paths_ms,
            .paths_ms = paths_ms - start_ms,
            .asset_resolve_ms = assets_ms - parsed_ms,
            .metadata_ms = metadata_ms - assets_ms,
            .ready_after_start_ms = 0,
        },
        .started_ms = start_ms,
        .ready = monitorReadyMetadata(currentPid(), paths, spec.console_log_path),
    };
    const readiness_probe = try server.startReadinessProbe();
    const thread = try std.Thread.spawn(.{}, controlThreadMain, .{&server});

    try run.openConsoleLog(spec.console_log_path);
    defer run.closeConsoleLog();

    const monitor_options = run.Options{
        .backend = requested_backend,
        .kernel_path = kernel_path,
        .initrd_path = initrd_path,
        .rootfs_path = spec.rootfs_path,
        .rootfs = spec.rootfs,
        .disk = spec.disk,
        .disk_root = if (spec.disk_baseline_lease) |lease| lease.root else null,
        .runtime_disk_head = if (runtime_disk_head) |*head| head else null,
        .resume_dir = spec.resume_dir,
        .resume_generation = spec.resume_generation,
        .resume_sessions = spec.sessions,
        .annotations = spec.annotations,
        .command = &.{"/bin/true"},
        .memory = spec.memory,
        .vcpus = spec.vcpus,
        .guest_port = spec.guest_port,
        .timeout_ms = spec.timeout_ms,
        .network = network.mode,
        .network_policy = network.policy,
        .network_runtime = if (gateway_active) gateway.runtime() else null,
        .spore_executable = spore_executable,
    };
    const result = if (managed_boot_artifacts) |artifacts|
        run.executeMonitorWithBootArtifacts(.{ .io = init.io, .environ_map = init.environ_map }, allocator, monitor_options, artifacts, server.control(), readiness_probe)
    else
        run.executeMonitor(.{ .io = init.io, .environ_map = init.environ_map }, allocator, monitor_options, server.control(), readiness_probe);
    const monitor_result = result catch |err| {
        server.stopControl(thread, "monitor backend stopped");
        return err;
    };
    if (monitor_result.exit == .snapshotted) server.completeSuspend() catch |err| {
        server.stopControl(thread, "monitor stopped");
        return err;
    };
    server.stopControl(thread, "monitor stopped");
}

fn monitorReadyMetadata(pid: i64, paths: lifecycle.Paths, console_log_path: ?[]const u8) lifecycle.Ready {
    return .{
        .pid = pid,
        .control_socket_path = paths.control_socket_path,
        .console_log_path = console_log_path,
    };
}

test "monitor console configuration matches opened and advertised path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var root_dir = try TestDir.init();
    defer root_dir.deinit();
    const root = root_dir.root;
    const paths = try lifecycle.pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);
    try Io.Dir.cwd().createDirPath(io, paths.vm_dir);

    const default_ready = monitorReadyMetadata(1, paths, null);
    try std.testing.expectEqual(@as(?[]const u8, null), default_ready.console_log_path);
    try run.openConsoleLog(null);
    run.closeConsoleLog();
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, paths.console_log_path, .{}));

    const explicit_ready = monitorReadyMetadata(2, paths, paths.console_log_path);
    try std.testing.expectEqualStrings(paths.console_log_path, explicit_ready.console_log_path.?);
    try run.openConsoleLog(paths.console_log_path);
    defer run.closeConsoleLog();
    run.consoleSink("console parity\n");
    run.closeConsoleLog();
    const bytes = try Io.Dir.cwd().readFileAlloc(io, paths.console_log_path, allocator, .limited(4096));
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("console parity\n", bytes);
}

const MonitorNetwork = struct {
    mode: run.NetworkMode = .disabled,
    policy: run.NetworkPolicy = .{},
};

/// The network the monitor runs, from the live policy the claimer encoded in
/// the spec next to its manifest form.
fn monitorNetwork(allocator: std.mem.Allocator, spec: lifecycle.Spec) !MonitorNetwork {
    const raw = spec.network_policy orelse {
        if (spec.network != null) return error.InvalidNetworkPolicy;
        return .{};
    };
    if (spec.network == null) return error.InvalidNetworkPolicy;
    return .{ .mode = .spore, .policy = try spore_net_policy.parseArg(allocator, raw) };
}

const StartupMetadata = struct {
    timing: lifecycle.MonitorTiming,
    started_ms: u64,
    ready: lifecycle.Ready,
};

const EffectiveExecContext = struct {
    env: []const []const u8,
    working_dir: ?[]const u8,
};

fn effectiveExecContext(
    env_buffer: *[run.max_guest_envc][]const u8,
    defaults: lifecycle.ExecDefaults,
    env_overrides: []const []const u8,
    working_dir_override: ?[]const u8,
) !EffectiveExecContext {
    const env = try run.mergeGuestEnvInto(env_buffer, defaults.env, env_overrides);
    const working_dir = working_dir_override orelse defaults.working_dir;
    try run.validateGuestExecContext(env, working_dir);
    return .{ .env = env, .working_dir = working_dir };
}

const ExecServer = struct {
    allocator: std.mem.Allocator,
    io: Io,
    /// The monitor's registry entry; its only writer while the VM runs.
    entry: vm_registry.Entry,
    vm_dir: []const u8,
    runtime_root: []const u8,
    socket_path: []const u8,
    cache_root: []const u8,
    guest_port: u32,
    timeout_ms: u64,
    server: net.Server,
    generation_params: ?[]const u8,
    exec_defaults: lifecycle.ExecDefaults,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    op: Op = .idle,
    /// Set once the monitor is stopping; queued and new guest operations fail
    /// with this message.
    stopping: ?[]const u8 = null,
    /// Ends blocking stdin delivery to an exec that was failed.
    stream_input_stop: std.atomic.Value(bool) = .init(false),
    handlers: [max_control_handlers]ControlHandler = @splat(.{}),
    /// The finished operation's response, which its submitter copies out
    /// before it frees the slot.
    response: [max_control_response]u8 = undefined,
    response_len: usize = 0,
    disk_claims: runtime_disk_claim.Registry,
    /// The stream of the readiness request or an exec. The vsock device
    /// holds it by pointer while it is attached.
    active_stream: vsock_stream.HostStream = undefined,
    capture: OutputCapture = .{},
    session_nonce: u64,
    next_session_id: u64 = 1,
    next_host_stream_sequence: u64,
    wake: ?vsock_control.Wake = null,
    stats_written: bool = false,
    stats_written_value: vsock_control.ControlStats = .{},
    stats_write_ms: u64 = 0,
    last_registry_check_ms: u64 = 0,
    closed: std.atomic.Value(bool) = .init(false),
    startup: ?StartupMetadata = null,
    disk_baseline_active: ?runtime_disk_lease.Active = null,
    snapshot_publication_wait: snapshot_publication.Wait = .{},
    /// Set once the root disk is open when it reads objects from an image
    /// store. Retained; released after every control handler has joined.
    image_store: ?*image_store_mod.Fetcher = null,

    fn init(allocator: std.mem.Allocator, io: Io, entry: vm_registry.Entry, vm_dir: []const u8, runtime_root: []const u8, socket_path: []const u8, cache_root: []const u8, guest_port: u32, timeout_ms: u64, generation_params: ?[]const u8, exec_defaults: lifecycle.ExecDefaults) !ExecServer {
        // Zig's UnixAddress accepts 108-byte paths everywhere, but macOS
        // sun_path holds only 104; enforce the real platform limit before
        // listen so an oversized path fails with a clear log line instead
        // of crashing in the socket address conversion.
        lifecycle.validateControlSocketPath(socket_path) catch |err| {
            const detail = lifecycle.lastErrorMessage();
            if (detail.len != 0) {
                std.debug.print("monitor: {s}\n", .{detail});
            } else {
                std.debug.print(
                    "monitor: internal control socket path {s} is {d} bytes but the platform limit is {d}\n",
                    .{ socket_path, socket_path.len, lifecycle.max_control_socket_path_len },
                );
            }
            return err;
        };
        Io.Dir.cwd().deleteFile(io, socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
        const address = try net.UnixAddress.init(socket_path);
        var session_nonce_bytes: [8]u8 = undefined;
        io.random(&session_nonce_bytes);
        const session_nonce = std.mem.readInt(u64, &session_nonce_bytes, .little);
        return .{
            .allocator = allocator,
            .io = io,
            .entry = entry,
            .vm_dir = vm_dir,
            .runtime_root = runtime_root,
            .socket_path = socket_path,
            .cache_root = cache_root,
            .guest_port = guest_port,
            .timeout_ms = timeout_ms,
            .server = try address.listen(io, .{ .kernel_backlog = max_control_handlers }),
            .generation_params = generation_params,
            .exec_defaults = exec_defaults,
            .disk_claims = runtime_disk_claim.Registry.init(allocator),
            .session_nonce = session_nonce,
            .next_host_stream_sequence = session_nonce,
        };
    }

    fn startReadinessProbe(self: *ExecServer) !*vsock_stream.HostStream {
        if (self.op != .idle) return error.ControlBusy;
        self.active_stream = try vsock_stream.HostStream.init(self.guest_port, readiness_request);
        self.capture.reset();
        self.active_stream.setOutputSink(self, captureOutputThunk);
        self.active_stream.host_port = self.nextHostStreamPort();
        std.log.debug(
            "monitor vsock stream start: kind=readiness session_id=ready host_port={d}",
            .{self.active_stream.host_port},
        );
        self.op = .readiness;
        return &self.active_stream;
    }

    fn publishReady(self: *ExecServer) !void {
        var startup = self.startup orelse return error.MissingMonitorStartupMetadata;
        startup.timing.ready_after_start_ms = lifecycle.monotonicMs() - startup.started_ms;
        startup.timing.readiness_attach_ms = self.active_stream.attach_ms;
        startup.timing.readiness_connect_request_delivered_ms = self.active_stream.connect_request_delivered_ms;
        startup.timing.readiness_connect_ms = self.active_stream.connect_ms;
        startup.timing.readiness_request_delivered_ms = self.active_stream.request_delivered_ms;
        startup.timing.readiness_guest_timing_ms = self.active_stream.guest_timing_ms;
        startup.timing.readiness_response_ms = self.active_stream.response_ms;
        startup.timing.backend_restore_memory_ms = self.active_stream.backend_restore_memory_ms;
        startup.timing.backend_restore_state_ms = self.active_stream.backend_restore_state_ms;
        startup.timing.backend_restore_pre_run_ms = self.active_stream.backend_restore_pre_run_ms;
        self.entry.writeMonitorTiming(self.allocator, self.io, startup.timing) catch {};
        try self.entry.writeReady(self.allocator, self.io, startup.ready);
    }

    /// Runs after the VM loop returns: fails what is left, waits for the
    /// accept thread, which joins every handler, then removes the socket.
    fn stopControl(self: *ExecServer, accept_thread: std.Thread, message: []const u8) void {
        self.failOutstanding(message);
        self.closed.store(true, .release);
        // A handler may be fetching a store image for a save; stop it so the
        // join does not wait for the download.
        self.cancelImageStoreFetch();
        accept_thread.join();
        self.server.deinit(self.io);
        Io.Dir.cwd().deleteFile(self.io, self.socket_path) catch {};
    }

    fn isClosed(self: *ExecServer) bool {
        return self.closed.load(.acquire);
    }

    fn control(self: *ExecServer) vsock_control.Control {
        return .{
            .context = self,
            .pollFn = pollThunk,
            .setWakeFn = setWakeThunk,
            .prepareSnapshotFn = prepareSnapshotThunk,
            .publishSnapshotFn = publishSnapshotThunk,
            .completeSnapshotFn = completeSnapshotThunk,
            .completeRootfsSnapshotFn = completeRootfsSnapshotThunk,
            .completeDiskForkFn = completeDiskForkThunk,
            .failDiskForkFn = failDiskForkThunk,
            .attachImageStoreFn = attachImageStoreThunk,
            .reportStatsFn = reportStatsThunk,
        };
    }

    fn attachImageStore(self: *ExecServer, fetcher: *image_store_mod.Fetcher) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.image_store == null) self.image_store = fetcher.retain();
    }

    /// Before a save pauses the guest, fetch the root disk's objects that are
    /// only in its image store. Returns the refusal of the save, or null.
    /// Refusing here keeps the VM running; a capture that fails while the
    /// guest is paused ends the run.
    fn imageStoreRefusal(self: *ExecServer, client: std.c.fd_t, buf: []u8) ?monitor_protocol.Error {
        const fetcher = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            break :blk self.image_store orelse return null;
        };
        // A failed read poisoned the disk, and no snapshot can capture it.
        // A read can also fail while the fill runs, so check again after it.
        const read_failed = "a guest read from it failed earlier";
        const cause = if (fetcher.readFailed())
            read_failed
        else if (fetcher.fetchAll()) |_|
            if (fetcher.readFailed())
                read_failed
            else if (clientGone(client))
                // The client gave up while the image downloaded.
                "the client went away"
            else
                return null
        else |err| switch (err) {
            // The monitor is stopping, so the store is not to blame and the
            // VM does not keep running.
            error.ImageStoreFetchCanceled => return .{ .message = self.refusalMessage(error.MonitorStopping) },
            else => @errorName(err),
        };
        return .{
            .message = std.fmt.bufPrint(buf, "{s}: {s}", .{ save_refused_image_store, cause }) catch save_refused_image_store,
            .code = .image_store_incomplete,
        };
    }

    /// Stop a save's fetch on a control handler thread, so the handlers can
    /// be joined without waiting for the image to download.
    fn cancelImageStoreFetch(self: *ExecServer) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.image_store) |fetcher| fetcher.cancel();
    }

    fn setWake(self: *ExecServer, wake: vsock_control.Wake) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.wake = wake;
    }

    fn prepareSnapshot(self: *ExecServer) !?snapshot_publication.SnapshotPreparation {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const snapshot = switch (self.op) {
            .snapshot => |*snapshot| snapshot,
            else => return error.ControlBusy,
        };
        if (snapshot.phase != .active) return error.ControlBusy;
        const preparation = try self.snapshot_publication_wait.tryPrepare(self.io, self.allocator, self.cache_root);
        if (preparation == null) snapshot.phase = .pending;
        return preparation;
    }

    fn poll(self: *ExecServer, dev: *vsock.Vsock) !vsock_control.ControlAction {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.registryDirGone()) {
            self.stopping = self.stopping orelse "monitor registry disappeared";
            self.failOutstandingLocked("monitor registry disappeared");
            return .stop;
        }
        if (self.stopping) |message| {
            // A capture runs inside the VM loop, so none is under way here.
            self.stopLocked(message);
            return .stop;
        }
        _ = self.disk_claims.expire(monotonicNs());

        switch (self.op) {
            .idle => return .keep_running,
            .@"suspend" => |*capture| {
                if (capture.phase != .pending) return .keep_running;
                capture.phase = .active;
                return .{ .snapshot = .{ .dir = capture.dir } };
            },
            .snapshot => |*capture| {
                if (capture.phase != .pending) return .keep_running;
                capture.phase = .active;
                return .{ .snapshot = .{ .dir = capture.dir, .publish_dir = capture.publish_dir, .continue_after = true } };
            },
            .disk_fork => |*fork| {
                if (fork.phase != .pending) return .keep_running;
                fork.phase = .active;
                return .{ .disk_fork = .{
                    .dir = fork.request.out_dir,
                    .count = @intCast(fork.request.children.len),
                    .allow_copy = fork.request.allow_copy,
                    .force_copy = fork.request.force_copy,
                } };
            },
            .readiness => return self.pollStreamLocked(dev, null),
            .exec => |*exec| switch (exec.phase) {
                .done => return .keep_running,
                .pending => {
                    try self.attachExecLocked(dev, exec);
                    return self.pollStreamLocked(dev, exec);
                },
                .active => return self.pollStreamLocked(dev, exec),
            },
        }
    }

    fn attachExecLocked(self: *ExecServer, dev: *vsock.Vsock, exec: *Exec) !void {
        self.active_stream = try vsock_stream.HostStream.init(self.guest_port, exec.request);
        switch (exec.output) {
            .captured => {
                self.capture.reset();
                self.active_stream.setOutputSink(self, captureOutputThunk);
            },
            .streamed => self.active_stream.setOutputSink(self, streamOutputThunk),
        }
        // Restored guests can carry the original default host port in
        // serialized vsock state. Start from a random dynamic offset,
        // then advance for readiness and every request so neither the
        // restored tuple nor an earlier monitor stream is reused.
        self.active_stream.host_port = self.nextHostStreamPort();
        var stream_log: [160]u8 = undefined;
        std.log.debug("{s}", .{formatExecHostStreamStart(
            &stream_log,
            self.session_nonce,
            exec.session_sequence,
            self.active_stream.host_port,
        )});
        try dev.attachHostStream(&self.active_stream);
        self.active_stream.markStarted();
        exec.phase = .active;
        self.cond.broadcast(self.io);
    }

    /// Advances the attached stream of `exec`, or of the readiness request
    /// when `exec` is null.
    fn pollStreamLocked(self: *ExecServer, dev: *vsock.Vsock, exec: ?*Exec) !vsock_control.ControlAction {
        const streamed: ?*Streamed = if (exec) |active| switch (active.output) {
            .streamed => |*streamed| streamed,
            .captured => null,
        } else null;
        if (streamed) |output| {
            if (output.write_failed) self.active_stream.fail();
        }
        _ = try dev.flushHostStreamOutbound();
        switch (self.active_stream.state) {
            .failed => {
                try self.failExecLocked(exec orelse return error.GuestReadinessProbeFailed, "guest vsock stream failed");
                dev.resetHostStream();
            },
            .complete => {
                const exit_code = self.active_stream.exit_code orelse {
                    try self.failExecLocked(exec orelse return error.GuestReadinessProbeFailed, "guest exec missing exit code");
                    dev.resetHostStream();
                    return .keep_running;
                };
                const active = exec orelse {
                    if (exit_code != 0) return error.GuestReadinessProbeFailed;
                    std.log.info(
                        "monitor readiness metrics: attach_ms={?d} connect_request_delivered_ms={?d} connect_ms={?d} request_delivered_ms={?d} guest_timing_ms={?d} response_ms={?d} ready_ms={d}",
                        .{
                            self.active_stream.attach_ms,
                            self.active_stream.connect_request_delivered_ms,
                            self.active_stream.connect_ms,
                            self.active_stream.request_delivered_ms,
                            self.active_stream.guest_timing_ms,
                            self.active_stream.response_ms,
                            self.active_stream.elapsedMs(),
                        },
                    );
                    dev.resetHostStream();
                    try self.publishReady();
                    self.op = .idle;
                    self.cond.broadcast(self.io);
                    return .keep_running;
                };
                dev.resetHostStream();
                const timing = namedExecTiming(&self.active_stream, active.submitted_ms, lifecycle.monotonicMs());
                if (streamed) |output| {
                    if (output.timing) self.sendStreamingTimingLocked(output, timing);
                    self.sendStreamingExitLocked(output, exit_code);
                } else {
                    try self.storeExecResultLocked(exit_code, timing);
                }
                active.phase = .done;
                self.cond.broadcast(self.io);
            },
            else => {
                if (self.active_stream.elapsedMs() > self.timeout_ms) {
                    try self.failExecLocked(exec orelse return error.GuestReadinessProbeFailed, "guest exec timed out");
                    dev.resetHostStream();
                }
            },
        }
        return .keep_running;
    }

    /// Ends `exec` with `message`: an error frame for a streamed exec, the
    /// response for a captured one.
    fn failExecLocked(self: *ExecServer, exec: *Exec, message: []const u8) !void {
        switch (exec.output) {
            .streamed => |*streamed| self.sendStreamingErrorLocked(streamed, message),
            .captured => try self.storeErrorLocked(message),
        }
        exec.phase = .done;
        self.cond.broadcast(self.io);
    }

    fn registryDirGone(self: *ExecServer) bool {
        const now = lifecycle.monotonicMs();
        if (now - self.last_registry_check_ms < registry_check_interval_ms) return false;
        self.last_registry_check_ms = now;
        // ponytail: one stat per second, kqueue/inotify only if cleanup latency matters.
        return self.entry.replaced(self.io, self.vm_dir);
    }

    /// Waits for the guest operation slot. A request queues behind the
    /// running operation for up to the VM's timeout.
    fn acquireOpLocked(self: *ExecServer) !void {
        const deadline = lifecycle.monotonicMs() +| self.timeout_ms;
        while (true) {
            if (self.stopping != null) return error.MonitorStopping;
            if (self.op == .idle) return;
            if (lifecycle.monotonicMs() >= deadline) return error.ControlBusy;
            self.mutex.unlock(self.io);
            var ts = std.c.timespec{ .sec = 0, .nsec = control_queue_poll_ms * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
            self.mutex.lockUncancelable(self.io);
        }
    }

    /// Copies the response out of the shared buffer before the slot is
    /// released; the caller frees it with the page allocator.
    fn takeResponseLocked(self: *ExecServer) ![]const u8 {
        return std.heap.page_allocator.dupe(u8, self.response[0..self.response_len]);
    }

    fn submitExec(self: *ExecServer, request: []const u8, session_sequence: u64) ![]const u8 {
        if (request.len > vsock.max_payload) return error.ControlRequestTooLarge;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.acquireOpLocked();
        self.response_len = 0;
        self.op = .{ .exec = .{
            .request = request,
            .session_sequence = session_sequence,
            .submitted_ms = lifecycle.monotonicMs(),
            .output = .captured,
        } };
        if (self.wake) |wake| wake.wake();
        self.cond.broadcast(self.io);
        while (!self.op.done()) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        defer self.op = .idle;
        return self.takeResponseLocked();
    }

    fn submitStreamingExec(self: *ExecServer, request: []const u8, session_sequence: u64, client_fd: std.c.fd_t, timing_enabled: bool) !void {
        if (request.len > vsock.max_payload) return error.ControlRequestTooLarge;
        try setStreamingSendDeadline(client_fd);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.acquireOpLocked();
        self.stream_input_stop.store(false, .release);
        self.response_len = 0;
        self.op = .{ .exec = .{
            .request = request,
            .session_sequence = session_sequence,
            .submitted_ms = lifecycle.monotonicMs(),
            .output = .{ .streamed = .{ .client_fd = client_fd, .timing = timing_enabled } },
        } };
        if (self.wake) |wake| wake.wake();
        self.cond.broadcast(self.io);
        while (self.op.exec.phase == .pending) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
    }

    /// Waits for the submitted streaming exec to end, then frees the slot.
    fn finishStreamingExec(self: *ExecServer) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (!self.op.done()) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        self.op = .idle;
        self.cond.broadcast(self.io);
    }

    fn streamingDone(self: *ExecServer) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.op.done();
    }

    /// The streamed exec whose stream is attached, if one is.
    fn activeStreamedLocked(self: *ExecServer) ?*Streamed {
        const exec = switch (self.op) {
            .exec => |*exec| exec,
            else => return null,
        };
        if (exec.phase != .active) return null;
        return switch (exec.output) {
            .streamed => |*streamed| streamed,
            .captured => null,
        };
    }

    /// Host wall clock carried on session starts so the guest agent can set
    /// CLOCK_REALTIME. Guests have no RTC in the device model and otherwise
    /// boot at the epoch, which breaks TLS certificate validation.
    fn wallClockUnixNs(self: *ExecServer) u64 {
        const ns = Io.Clock.real.now(self.io).nanoseconds;
        if (ns <= 0) return 0;
        return @intCast(ns);
    }

    fn interactiveExecRequest(self: *ExecServer, session_sequence: *u64, argv: []const []const u8, env: []const []const u8, working_dir: ?[]const u8, tty: bool, terminal_size: spore_stream.Resize) ![]const u8 {
        var id_buf: [64]u8 = undefined;
        const session_id = try self.nextSessionId(&id_buf, session_sequence);
        var merged_env: [run.max_guest_envc][]const u8 = undefined;
        const exec_context = try effectiveExecContext(&merged_env, self.exec_defaults, env, working_dir);
        return run.interactiveExecRequestWithSession(self.allocator, argv, session_id, .{
            .env = exec_context.env,
            .working_dir = exec_context.working_dir,
            .tty = tty,
            .terminal_size = terminal_size,
            .resume_time_unix_ns = self.wallClockUnixNs(),
            .generation_params = self.generation_params,
        });
    }

    fn detachedExecRequest(self: *ExecServer, session_sequence: *u64, argv: []const []const u8, env: []const []const u8, working_dir: ?[]const u8, retain_output: bool) ![]const u8 {
        var id_buf: [64]u8 = undefined;
        const session_id = try self.nextSessionId(&id_buf, session_sequence);
        var merged_env: [run.max_guest_envc][]const u8 = undefined;
        const exec_context = try effectiveExecContext(&merged_env, self.exec_defaults, env, working_dir);
        return run.detachedExecRequestWithSessionContext(self.allocator, argv, session_id, .{
            .env = exec_context.env,
            .working_dir = exec_context.working_dir,
            .resume_time_unix_ns = self.wallClockUnixNs(),
            .retain_output = retain_output,
        });
    }

    fn copyRequest(self: *ExecServer, session_sequence: *u64, request_type: []const u8, path: []const u8) ![]const u8 {
        var id_buf: [64]u8 = undefined;
        const session_id = try self.nextSessionId(&id_buf, session_sequence);
        const payload = struct {
            type: []const u8,
            session_id: []const u8,
            path: []const u8,
        }{
            .type = request_type,
            .session_id = session_id,
            .path = path,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, payload, .{});
        defer self.allocator.free(json);
        return std.fmt.allocPrint(self.allocator, "{s}\n", .{json});
    }

    /// Reserves the next session id. The submit functions record its
    /// sequence for stream logging once the request takes the guest.
    fn nextSessionId(self: *ExecServer, buffer: *[64]u8, sequence: *u64) ![]const u8 {
        // Handler threads build requests concurrently.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        sequence.* = self.next_session_id;
        const session_id = try formatSessionId(buffer, self.session_nonce, self.next_session_id);
        self.next_session_id +%= 1;
        if (self.next_session_id == 0) self.next_session_id = 1;
        return session_id;
    }

    fn nextHostStreamPort(self: *ExecServer) u32 {
        const port = vsock_stream.HostStream.hostPortForSequence(self.next_host_stream_sequence);
        self.next_host_stream_sequence +%= 1;
        return port;
    }

    fn streamOutput(self: *ExecServer, output: vsock_stream.HostStreamOutput, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const streamed = self.activeStreamedLocked() orelse return;
        if (streamed.write_failed) return;
        const stream_id: spore_stream.StreamId = switch (output) {
            .stdout => .stdout,
            .stderr => .stderr,
            .terminal => .terminal,
        };
        const offset = switch (output) {
            .stdout => &streamed.stdout_offset,
            .stderr => &streamed.stderr_offset,
            .terminal => &streamed.terminal_offset,
        };
        if (writeSpioDataFdBounded(streamed.client_fd, stream_id, offset.*, bytes) != 0) {
            streamed.write_failed = true;
            if (self.wake) |wake| wake.wake();
            return;
        }
        offset.* += bytes.len;
    }

    fn sendStreamingExitLocked(_: *ExecServer, streamed: *Streamed, exit_code: i32) void {
        if (streamed.write_failed) return;
        const code: u32 = if (exit_code < 0) 1 else @intCast(@min(exit_code, 255));
        var payload: [4]u8 = undefined;
        spore_stream.writeExitPayload(&payload, code);
        if (writeSpioFrameFdBounded(streamed.client_fd, .exit, .control, 0, &payload) != 0) {
            streamed.write_failed = true;
        }
    }

    fn sendStreamingTimingLocked(self: *ExecServer, streamed: *Streamed, timing: lifecycle.NamedExecTiming) void {
        if (streamed.write_failed) return;
        const json = std.json.Stringify.valueAlloc(self.allocator, monitor_protocol.TimingEvent{ .timing = timing }, .{}) catch return;
        defer self.allocator.free(json);
        if (json.len > spore_stream.max_payload_len or
            writeSpioFrameFdBounded(streamed.client_fd, .event, .control, 0, json) != 0)
        {
            streamed.write_failed = true;
        }
    }

    fn sendStreamingErrorLocked(_: *ExecServer, streamed: *Streamed, message: []const u8) void {
        if (streamed.write_failed) return;
        const payload = if (message.len > spore_stream.max_payload_len) message[0..spore_stream.max_payload_len] else message;
        if (writeSpioFrameFdBounded(streamed.client_fd, .err, .control, 0, payload) != 0) {
            streamed.write_failed = true;
        }
    }

    fn enqueueStreamingInput(self: *ExecServer, stream_id: spore_stream.StreamId, bytes: []const u8) !void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.activeStreamedLocked() == null) return error.ControlStreamClosed;
        }
        const queued = switch (stream_id) {
            .stdin => try self.active_stream.enqueueStdinDataBlocking(bytes, &self.stream_input_stop),
            .terminal => try self.active_stream.enqueueTerminalDataBlocking(bytes, &self.stream_input_stop),
            else => return error.InvalidControlStream,
        };
        if (!queued) return error.ControlStreamClosed;
        self.wakeRun();
    }

    fn enqueueStreamingClose(self: *ExecServer, stream_id: spore_stream.StreamId) !void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.activeStreamedLocked() == null) return error.ControlStreamClosed;
        }
        const queued = switch (stream_id) {
            .stdin => try self.active_stream.enqueueStdinCloseBlocking(&self.stream_input_stop),
            .terminal => try self.active_stream.enqueueTerminalCloseBlocking(&self.stream_input_stop),
            else => return error.InvalidControlStream,
        };
        if (!queued) return error.ControlStreamClosed;
        self.wakeRun();
    }

    fn enqueueStreamingResize(self: *ExecServer, resize: spore_stream.Resize) !void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.activeStreamedLocked() == null) return error.ControlStreamClosed;
        }
        if (!self.active_stream.enqueueResize(resize)) return error.ControlStreamClosed;
        self.wakeRun();
    }

    /// Wakes the VM run from a thread that does not hold `mutex`. The wake
    /// runs under `mutex`, which `setWake` also takes, so once the run has
    /// replaced its wake no call into it is still in flight.
    fn wakeRun(self: *ExecServer) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.wake) |wake| wake.wake();
    }

    fn submitSuspend(self: *ExecServer, out_dir: []const u8) ![]const u8 {
        if (out_dir.len == 0 or out_dir.len > max_suspend_path) return error.InvalidSuspendDir;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.acquireOpLocked();
        self.response_len = 0;
        self.op = .{ .@"suspend" = .{ .dir = out_dir } };
        if (self.wake) |wake| wake.wake();
        self.cond.broadcast(self.io);
        while (!self.op.done()) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        // The VM ends after a suspend, so the slot stays taken.
        return self.takeResponseLocked();
    }

    fn submitSnapshot(self: *ExecServer, out_dir: []const u8, publish_dir: ?[]const u8) ![]const u8 {
        if (out_dir.len == 0 or out_dir.len > max_suspend_path) return error.InvalidSuspendDir;
        if (publish_dir) |dir| {
            if (dir.len == 0 or dir.len > max_suspend_path) return error.InvalidSuspendDir;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.acquireOpLocked();
        self.response_len = 0;
        self.op = .{ .snapshot = .{ .dir = out_dir, .publish_dir = publish_dir } };
        if (self.wake) |wake| wake.wake();
        self.cond.broadcast(self.io);
        while (!self.op.done()) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        defer self.op = .idle;
        return self.takeResponseLocked();
    }

    fn submitDiskFork(self: *ExecServer, request: runtime_disk_fork_control.PrepareRequest) ![]const u8 {
        try runtime_disk_fork_control.validatePrepare(request);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const baseline = while (true) {
            try self.acquireOpLocked();
            if (self.disk_claims.hasBatch(request.batch)) return error.BatchAlreadyRegistered;
            // Naming the baseline reads and writes the spec, so it runs
            // unlocked. Holding the slot keeps a save from replacing the disk
            // meanwhile.
            self.op = .{ .disk_fork = .{ .request = request } };
            self.mutex.unlock(self.io);
            const step = ensureDiskBaselineLease(self.io, arena_state.allocator(), self.entry, self.runtime_root, self.cache_root);
            self.mutex.lockUncancelable(self.io);
            const busy_root = switch (step catch |err| {
                self.op = .idle;
                return err;
            }) {
                .named => |named| {
                    if (self.stopping == null) break named;
                    self.op = .idle;
                    return error.MonitorStopping;
                },
                .cache_busy => |root| root,
            };
            // A build, pull or GC holds the rootfs cache lock. Wait for it
            // without the slot, so the guest stays usable meanwhile, then
            // name the baseline again.
            self.op = .idle;
            self.mutex.unlock(self.io);
            const waited = self.awaitRootfsCacheLock(busy_root);
            self.mutex.lockUncancelable(self.io);
            try waited;
        };
        self.op.disk_fork.baseline = baseline;
        self.op.disk_fork.phase = .pending;
        self.response_len = 0;
        if (self.wake) |wake| wake.wake();
        self.cond.broadcast(self.io);
        while (!self.op.done()) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        defer self.op = .idle;
        return self.takeResponseLocked();
    }

    /// Polls until the rootfs cache lock at `root` is free, or the monitor
    /// is stopping.
    fn awaitRootfsCacheLock(self: *ExecServer, root: []const u8) !void {
        if (comptime builtin.is_test) _ = testing.disk_fork_cache_waits.fetchAdd(1, .monotonic);
        while (true) {
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                if (self.stopping != null) return error.MonitorStopping;
            }
            var lock = rootfs_mod.tryLockRootfsCacheExclusive(self.io, self.allocator, root) catch |err| switch (err) {
                error.LockBusy => {
                    var ts = std.c.timespec{ .sec = 0, .nsec = control_queue_poll_ms * std.time.ns_per_ms };
                    _ = std.c.nanosleep(&ts, null);
                    continue;
                },
                else => |e| return e,
            };
            lock.deinit();
            return;
        }
    }

    fn completeSuspend(self: *ExecServer) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const capture = switch (self.op) {
            .@"suspend" => |*capture| capture,
            else => return,
        };
        if (capture.phase == .done) return;
        try self.storeJsonLocked(monitor_protocol.Suspended{ .out_dir = capture.dir });
        capture.phase = .done;
        self.cond.broadcast(self.io);
    }

    fn completeSnapshot(self: *ExecServer, dir: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const capture = switch (self.op) {
            .snapshot => |*capture| capture,
            else => return,
        };
        if (capture.phase == .done) return;
        try self.storeJsonLocked(monitor_protocol.Snapshotted{ .out_dir = dir });
        capture.phase = .done;
        self.cond.broadcast(self.io);
    }

    fn publishSnapshot(self: *ExecServer, preparation: *const snapshot_publication.SnapshotPreparation, work_dir: []const u8, publish_dir: []const u8) !vsock_control.SnapshotPublishMetrics {
        var metrics = vsock_control.SnapshotPublishMetrics{ .cache_lock_wait_ns = preparation.wait_ns };
        const registry = try preparation.registry(self.allocator, self.cache_root);
        var lifecycle_spec = (try lifecycle.readSporeLifecycleSpec(self.allocator, self.io, work_dir)) orelse return error.BadManifest;
        defer lifecycle_spec.deinit();
        var manifest = try spore.loadManifest(self.allocator, work_dir);
        defer manifest.deinit();
        manifest.value.annotations = lifecycle_spec.value.annotations;
        manifest.value.exec_defaults = lifecycle_spec.value.exec_defaults;
        const manifest_started = runtime_disk_fork_capture.monotonicNs();
        const bytes = try spore.encodeManifestAlloc(self.allocator, manifest.value);
        defer self.allocator.free(bytes);
        const manifest_path = try std.fs.path.join(self.allocator, &.{ work_dir, "manifest.json" });
        defer self.allocator.free(manifest_path);
        try chunk_sealer.replaceFileAtomicDurable(self.allocator, manifest_path, bytes, 0o644);
        metrics.manifest_write_ns = runtime_disk_fork_capture.elapsedSince(manifest_started);
        if (manifest.value.disk) |disk| {
            const lease_started = runtime_disk_fork_capture.monotonicNs();
            try self.handoffSnapshotDiskLease(registry, work_dir, disk, &lifecycle_spec);
            metrics.active_lease_handoff_ns = runtime_disk_fork_capture.elapsedSince(lease_started);
        }
        const lifecycle_started = runtime_disk_fork_capture.monotonicNs();
        try lifecycle.writeSporeLifecycleSpec(self.allocator, self.io, work_dir, lifecycle_spec.value);
        metrics.lifecycle_spec_ns = runtime_disk_fork_capture.elapsedSince(lifecycle_started);
        const publication_started = runtime_disk_fork_capture.monotonicNs();
        try Io.Dir.renameAbsolute(work_dir, publish_dir, self.io);
        try chunk_sealer.fsyncDirPath(self.allocator, std.fs.path.dirname(publish_dir) orelse ".");
        metrics.final_publication_ns = runtime_disk_fork_capture.elapsedSince(publication_started);
        return metrics;
    }

    /// Caller holds the prepared snapshot publication authority.
    fn handoffSnapshotDiskLease(
        self: *ExecServer,
        registry: saved_spore_pin.LockedRegistry,
        work_dir: []const u8,
        disk: spore.Disk,
        lifecycle_spec: *std.json.Parsed(lifecycle.Spec),
    ) !void {
        const lease = runtime_disk_lease.Lease{
            .store = .rootfs_cache,
            .root = self.cache_root,
            .baseline_kind = .disk_index,
            .baseline_identity = disk.base,
            .rootfs_storage = try saved_spore_pin.storageForDisk(disk),
        };
        var pin = try saved_spore_pin.loadForSporeLocked(self.io, self.allocator, registry, work_dir, disk);
        pin.deinit();
        if (!std.mem.eql(u8, lifecycle_spec.value.name, std.fs.path.basename(self.vm_dir))) return error.BadManifest;
        try persistSourceDiskLeaseHandoff(
            self.io,
            self.allocator,
            self.runtime_root,
            self.entry,
            disk,
            lease,
            &self.disk_baseline_active,
        );
        lifecycle_spec.value.disk = disk;
        lifecycle_spec.value.disk_baseline_lease = lease;
    }

    fn completeRootfsSnapshot(_: *ExecServer, _: ?spore.Disk) !void {}

    fn completeDiskFork(self: *ExecServer, batch: *runtime_disk_fork_capture.Batch) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const fork = switch (self.op) {
            .disk_fork => |*fork| fork,
            else => return error.ControlBusy,
        };
        const children = fork.request.children;
        if (fork.phase != .active or batch.heads.len != children.len) return error.ControlBusy;
        const recorded = fork.baseline orelse return error.ControlBusy;

        var pending: [runtime_disk_claim.max_children_per_batch]runtime_disk_claim.PendingClaim = undefined;
        for (batch.heads, 0..) |head, index| {
            pending[index] = .{
                .child_name = children[index],
                .child_index = @intCast(index),
                .head = head,
            };
        }
        const now_ns = monotonicNs();
        const expires_at_ns = std.math.add(u64, now_ns, disk_claim_timeout_ns) catch std.math.maxInt(u64);
        const batch_name = fork.request.batch;
        const baseline = (batch.heads[0] orelse return error.BadBatch).descriptor.baseline;
        const registrations = try self.disk_claims.registerBatch(batch_name, pending[0..batch.heads.len], now_ns, expires_at_ns);
        defer self.allocator.free(registrations);
        for (batch.heads) |*head| head.* = null;
        errdefer _ = self.disk_claims.cancelBatch(batch_name);

        var token_buffers: [runtime_disk_claim.max_children_per_batch][runtime_disk_claim.token_hex_bytes]u8 = undefined;
        var claims: [runtime_disk_claim.max_children_per_batch]runtime_disk_fork_control.PreparedClaim = undefined;
        for (claims[0..registrations.len], registrations, 0..) |*claim, registration, index| {
            claim.* = .{
                .child = children[index],
                .child_index = @intCast(index),
                .token = runtime_disk_claim.formatTokenHex(registration.token, &token_buffers[index]),
                .baseline_kind = baseline.kind,
                .baseline_identity = baseline.identity,
            };
        }
        try self.storeJsonLocked(runtime_disk_fork_control.PreparedResponse{
            .type = runtime_disk_fork_control.prepared_type,
            .schema = runtime_disk_fork_control.prepared_schema,
            .batch = batch_name,
            .capture_dir = fork.request.out_dir,
            .claims = claims[0..registrations.len],
            .lease = recorded.lease,
            .disk = recorded.disk,
            .ram_capture_ns = batch.ram_capture_ns,
            .disk_fork_ns = batch.prepare_ns,
            .source_pause_ns = runtime_disk_fork_capture.elapsedSince(batch.pause_started_ns),
            .copied_bytes = batch.copied_bytes,
        });
        fork.phase = .done;
        self.cond.broadcast(self.io);
    }

    fn failDiskFork(self: *ExecServer, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const fork = switch (self.op) {
            .disk_fork => |*fork| fork,
            else => return,
        };
        if (fork.phase != .pending and fork.phase != .active) return;
        var message_buf: [192]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buf, "disk fork capture failed: {s}", .{@errorName(err)}) catch "disk fork capture failed";
        self.storeJsonLocked(monitor_protocol.Error{ .message = message, .code = .of(err) }) catch {
            self.response_len = 0;
        };
        fork.phase = .done;
        self.cond.broadcast(self.io);
    }

    fn claimDiskHead(self: *ExecServer, request: runtime_disk_claim.ClaimRequest) !runtime_disk_fork.Head {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const now_ns = monotonicNs();
        _ = self.disk_claims.expire(now_ns);
        return self.disk_claims.claim(request, now_ns);
    }

    fn cancelDiskFork(self: *ExecServer, batch: []const u8) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.disk_claims.cancelBatch(batch);
    }

    fn reportStats(self: *ExecServer, stats: vsock_control.ControlStats) void {
        if (self.stats_written and std.meta.eql(stats, self.stats_written_value)) return;
        const now = lifecycle.monotonicMs();
        const first_write = self.stats_write_ms == 0;
        const clean_tail = (stats.dirty_chunks_pending orelse 0) == 0;
        if (!first_write and !clean_tail and now -| self.stats_write_ms < stats_write_interval_ms) return;
        self.entry.writeMonitorStats(self.allocator, self.io, .{
            .chunks_nonzero = stats.chunks_nonzero,
            .dirty_chunks_pending = stats.dirty_chunks_pending,
        }) catch return;
        self.stats_written = true;
        self.stats_written_value = stats;
        self.stats_write_ms = now;
    }

    fn requestStop(self: *ExecServer) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.stopLocked(removal_message);
        if (self.wake) |wake| wake.wake();
    }

    /// Refuses new and queued guest operations with `message` and fails the
    /// active one, except a capture already under way, which finishes first.
    fn stopLocked(self: *ExecServer, message: []const u8) void {
        self.stopping = self.stopping orelse message;
        const capturing = switch (self.op) {
            .@"suspend", .snapshot => |capture| capture.phase == .active,
            .disk_fork => |fork| fork.phase == .active,
            else => false,
        };
        if (!capturing) self.failOutstandingLocked(message);
    }

    fn failOutstanding(self: *ExecServer, message: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.stopping = self.stopping orelse message;
        self.failOutstandingLocked(message);
    }

    /// The message for a guest operation the monitor did not run.
    fn refusalMessage(self: *ExecServer, err: anyerror) []const u8 {
        if (err != error.MonitorStopping) return "monitor busy";
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.stopping orelse removal_message;
    }

    /// Fails the operation holding the slot unless it is done or still
    /// preparing, which checks `stopping` itself.
    fn failOutstandingLocked(self: *ExecServer, message: []const u8) void {
        switch (self.op) {
            .idle => return,
            .readiness => {},
            .exec => |*exec| {
                if (exec.phase == .done) return;
                switch (exec.output) {
                    .streamed => |*streamed| {
                        self.sendStreamingErrorLocked(streamed, message);
                        // Nothing follows the error frame.
                        streamed.write_failed = true;
                    },
                    .captured => self.storeErrorLocked(message) catch {
                        self.response_len = 0;
                    },
                }
                exec.phase = .done;
            },
            .@"suspend", .snapshot => |*capture| {
                if (capture.phase == .done) return;
                self.storeErrorLocked(message) catch {
                    self.response_len = 0;
                };
                capture.phase = .done;
            },
            .disk_fork => |*fork| {
                if (fork.phase == .done or fork.phase == .preparing) return;
                self.storeErrorLocked(message) catch {
                    self.response_len = 0;
                };
                fork.phase = .done;
            },
        }
        self.stream_input_stop.store(true, .release);
        self.cond.broadcast(self.io);
    }

    fn storeExecResultLocked(self: *ExecServer, exit_code: i32, timing: lifecycle.NamedExecTiming) !void {
        const stdout_b64 = try base64Alloc(self.allocator, self.capture.stdout[0..self.capture.stdout_len]);
        defer self.allocator.free(stdout_b64);
        const stderr_b64 = try base64Alloc(self.allocator, self.capture.stderr[0..self.capture.stderr_len]);
        defer self.allocator.free(stderr_b64);
        try self.storeJsonLocked(monitor_protocol.ExecResult{
            .exit_code = exit_code,
            .stdout_b64 = stdout_b64,
            .stderr_b64 = stderr_b64,
            .stdout_truncated = self.capture.stdout_truncated,
            .stderr_truncated = self.capture.stderr_truncated,
            .timing = timing,
        });
    }

    fn storeErrorLocked(self: *ExecServer, message: []const u8) !void {
        try self.storeJsonLocked(monitor_protocol.Error{ .message = message });
    }

    fn storeJsonLocked(self: *ExecServer, payload: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(self.allocator, payload, .{});
        defer self.allocator.free(json);
        if (json.len + 1 > self.response.len) return error.ControlResponseTooLarge;
        @memcpy(self.response[0..json.len], json);
        self.response[json.len] = '\n';
        self.response_len = json.len + 1;
    }

    fn pollThunk(context: *anyopaque, dev: *vsock.Vsock) !vsock_control.ControlAction {
        const self: *ExecServer = @ptrCast(@alignCast(context));
        return self.poll(dev);
    }

    fn setWakeThunk(context: *anyopaque, wake: vsock_control.Wake) void {
        const self: *ExecServer = @ptrCast(@alignCast(context));
        self.setWake(wake);
    }

    fn prepareSnapshotThunk(context: *anyopaque) !?snapshot_publication.SnapshotPreparation {
        const self: *ExecServer = @ptrCast(@alignCast(context));
        return try self.prepareSnapshot();
    }

    fn publishSnapshotThunk(context: *anyopaque, preparation: *const snapshot_publication.SnapshotPreparation, work_dir: []const u8, publish_dir: []const u8) !vsock_control.SnapshotPublishMetrics {
        const self: *ExecServer = @ptrCast(@alignCast(context));
        return try self.publishSnapshot(preparation, work_dir, publish_dir);
    }

    fn completeSnapshotThunk(context: *anyopaque, dir: []const u8) !void {
        const self: *ExecServer = @ptrCast(@alignCast(context));
        try self.completeSnapshot(dir);
    }

    fn completeRootfsSnapshotThunk(context: *anyopaque, disk: ?spore.Disk) !void {
        const self: *ExecServer = @ptrCast(@alignCast(context));
        try self.completeRootfsSnapshot(disk);
    }

    fn completeDiskForkThunk(context: *anyopaque, batch: *runtime_disk_fork_capture.Batch) !void {
        const self: *ExecServer = @ptrCast(@alignCast(context));
        try self.completeDiskFork(batch);
    }

    fn failDiskForkThunk(context: *anyopaque, err: anyerror) void {
        const self: *ExecServer = @ptrCast(@alignCast(context));
        self.failDiskFork(err);
    }

    fn attachImageStoreThunk(context: *anyopaque, fetcher: *image_store_mod.Fetcher) void {
        const self: *ExecServer = @ptrCast(@alignCast(context));
        self.attachImageStore(fetcher);
    }

    fn reportStatsThunk(context: *anyopaque, stats: vsock_control.ControlStats) void {
        const self: *ExecServer = @ptrCast(@alignCast(context));
        self.reportStats(stats);
    }

    fn captureOutputThunk(context: ?*anyopaque, output: vsock_stream.HostStreamOutput, bytes: []const u8) void {
        const self: *ExecServer = @ptrCast(@alignCast(context.?));
        self.capture.append(output, bytes);
    }

    fn streamOutputThunk(context: ?*anyopaque, output: vsock_stream.HostStreamOutput, bytes: []const u8) void {
        const self: *ExecServer = @ptrCast(@alignCast(context.?));
        self.streamOutput(output, bytes);
    }
};

fn elapsedOptional(later: ?u64, earlier: ?u64) ?u64 {
    const end = later orelse return null;
    const start = earlier orelse return null;
    if (end < start) return null;
    return end - start;
}

fn namedExecTiming(stream: *const vsock_stream.HostStream, submitted_ms: u64, finished_ms: u64) lifecycle.NamedExecTiming {
    const total_ms = finished_ms -| submitted_ms;
    const guest_process_start_ms = elapsedOptional(stream.guest_spawn_ms, stream.guest_accept_ms);
    const guest_execution_ms = elapsedOptional(stream.guest_exit_ms, stream.guest_spawn_ms);
    const guest_result_ms = elapsedOptional(stream.guest_now_ms, stream.guest_exit_ms);
    const host_result_ms = elapsedOptional(stream.response_ms, stream.guest_timing_ms);
    const output_result_delivery_ms = if (guest_result_ms != null and host_result_ms != null)
        guest_result_ms.? +| host_result_ms.?
    else
        null;
    const response_elapsed_ms = stream.response_ms orelse (finished_ms -| stream.started_at_ms);
    const response_finished_ms = stream.started_at_ms +| response_elapsed_ms;
    const teardown_ms = finished_ms -| response_finished_ms;
    const dispatch_ms = if (guest_process_start_ms != null and guest_execution_ms != null and output_result_delivery_ms != null) dispatch: {
        const accounted = guest_process_start_ms.? +| guest_execution_ms.? +| output_result_delivery_ms.? +| teardown_ms;
        break :dispatch if (accounted <= total_ms) total_ms - accounted else null;
    } else null;
    return .{
        .dispatch_ms = dispatch_ms,
        .guest_process_start_ms = guest_process_start_ms,
        .guest_execution_ms = guest_execution_ms,
        .guest_user_cpu_us = stream.guest_user_cpu_us,
        .guest_system_cpu_us = stream.guest_system_cpu_us,
        .output_result_delivery_ms = output_result_delivery_ms,
        .teardown_ms = teardown_ms,
        .total_ms = total_ms,
    };
}

fn persistSourceDiskLeaseHandoff(
    io: Io,
    allocator: std.mem.Allocator,
    runtime_root: []const u8,
    entry: vm_registry.Entry,
    disk: spore.Disk,
    lease: runtime_disk_lease.Lease,
    active_slot: *?runtime_disk_lease.Active,
) !void {
    try lease.validate();
    if (lease.store != .rootfs_cache or
        lease.baseline_kind != .disk_index or
        !std.mem.eql(u8, lease.baseline_identity, disk.base) or
        !spore.rootfsStorageEql(lease.rootfs_storage orelse return error.BadManifest, try saved_spore_pin.storageForDisk(disk))) return error.BadManifest;

    var source_spec = try entry.readSpec(allocator, io);
    defer source_spec.deinit();
    var next_active = try runtime_disk_lease.acquireActive(io, allocator, runtime_root, lease);
    var committed = false;
    defer if (!committed) next_active.deinit();
    if (comptime builtin.is_test) if (testing.snapshot_lease_handoff_fault.crash_after == .active_lease) std.process.exit(88);
    if (comptime builtin.is_test) if (testing.snapshot_lease_handoff_barrier) |barrier| barrier.pause(io);
    if (comptime builtin.is_test) if (testing.snapshot_lease_handoff_fault.fail_before_source_spec) return error.InjectedFailure;

    source_spec.value.disk = disk;
    source_spec.value.disk_baseline_lease = lease;
    // Atomic durable replacement is the commit point. Everything afterward is
    // infallible: swap the in-memory owner, then release the old active root.
    try entry.writeSpec(allocator, io, source_spec.value);
    if (comptime builtin.is_test) if (testing.snapshot_lease_handoff_fault.crash_after == .source_spec) std.process.exit(88);
    var old_active = active_slot.*;
    active_slot.* = next_active;
    committed = true;
    if (old_active) |*old| old.deinit();
}

const DiskBaseline = struct {
    lease: runtime_disk_lease.Lease,
    disk: ?spore.Disk,
};

const BaselineStep = union(enum) {
    named: DiskBaseline,
    /// Another process holds the rootfs cache lock at this root.
    cache_busy: []const u8,
};

/// Names the baseline a disk fork's children share and records it in the
/// spec, where GC finds it. The caller holds the operation slot, so no save
/// replaces the disk between reading and writing the spec, and so it never
/// waits for the rootfs cache lock. The result lives in `arena`.
fn ensureDiskBaselineLease(
    io: Io,
    arena: std.mem.Allocator,
    entry: vm_registry.Entry,
    runtime_root: []const u8,
    cache_root: []const u8,
) !BaselineStep {
    var spec = (try entry.readSpec(arena, io)).value;
    const rootfs = spec.rootfs orelse return error.UnsupportedNamedForkDisk;
    const recorded = spec.disk_baseline_lease;
    const lease: runtime_disk_lease.Lease = recorded orelse if (spec.disk) |disk| blk: {
        if (!std.mem.eql(u8, disk.kind, spore.disk_kind_chunk_index)) return error.UnsupportedNamedForkDisk;
        try spore.validateDiskDigest(disk.base);
        const resume_dir = spec.resume_dir orelse return error.UnsupportedNamedForkDisk;
        const root = try std.fs.path.resolve(arena, &.{resume_dir});
        const forks_root = try std.fs.path.resolve(arena, &.{ runtime_root, "forks" });
        if (pathWithin(forks_root, root)) return error.UnsupportedNamedForkDisk;
        break :blk .{
            .store = .saved_spore,
            .root = root,
            .baseline_kind = .disk_index,
            .baseline_identity = disk.base,
        };
    } else if (rootfs.storage) |storage| blk: {
        try spore.validateRootfsStorageDescriptor(storage);
        break :blk .{
            .store = .rootfs_cache,
            .root = cache_root,
            .baseline_kind = .disk_index,
            .baseline_identity = storage.index_digest,
            .rootfs_storage = storage,
        };
    } else blk: {
        try spore.validateRootfsDigest(rootfs.artifact.digest);
        break :blk .{
            .store = .rootfs_cache,
            .root = cache_root,
            .baseline_kind = .rootfs,
            .baseline_identity = rootfs.artifact.digest,
        };
    };
    try lease.validate();
    spec.disk_baseline_lease = lease;
    if (lease.store == .rootfs_cache) {
        var cache_lock = rootfs_mod.tryLockRootfsCacheExclusive(io, arena, lease.root) catch |err| switch (err) {
            error.LockBusy => return .{ .cache_busy = lease.root },
            else => |e| return e,
        };
        defer cache_lock.deinit();
        switch (lease.baseline_kind) {
            .rootfs => {
                const fd = rootfs_cache.openTrustedFromCache(io, arena, lease.root, rootfs) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.DiskForkBaselineUnavailable,
                };
                _ = std.c.close(fd);
            },
            .disk_index => {
                const storage = lease.rootfs_storage orelse return error.BadManifest;
                if (!try rootfs_cas.storageMarkedComplete(io, arena, lease.root, storage)) return error.DiskForkBaselineUnavailable;
            },
        }
        // Publish the root while holding the same lock used by GC/prune. A
        // collector that started first wins and is verified above; every
        // collector that starts later observes the lease.
        if (recorded == null) try entry.writeSpec(arena, io, spec);
    } else if (recorded == null) {
        try entry.writeSpec(arena, io, spec);
    }
    return .{ .named = .{ .lease = lease, .disk = spec.disk } };
}

fn pathWithin(parent: []const u8, child: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    if (parent.len != 0 and parent[parent.len - 1] == std.fs.path.sep) return true;
    return child[parent.len] == std.fs.path.sep;
}

fn formatSessionId(buffer: *[64]u8, nonce: u64, sequence: u64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "lifecycle-{x}-{d}", .{ nonce, sequence });
}

fn formatExecHostStreamStart(buffer: *[160]u8, nonce: u64, sequence: u64, host_port: u32) []const u8 {
    return std.fmt.bufPrint(
        buffer,
        "monitor vsock stream start: kind=exec session_id=lifecycle-{x}-{d} host_port={d}",
        .{ nonce, sequence, host_port },
    ) catch unreachable;
}

fn base64Alloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(out, bytes);
    return out;
}

fn encodeSpioFrame(frame_buf: *[spore_stream.max_frame_len]u8, frame_type: spore_stream.FrameType, stream_id: spore_stream.StreamId, offset: u64, payload: []const u8) ?[]const u8 {
    return spore_stream.writeFrame(frame_buf, .{
        .frame_type = frame_type,
        .stream_id = stream_id,
        .offset = offset,
    }, payload) catch null;
}

/// Streaming control sockets use fail-fast backpressure: a frame that cannot
/// be accepted within the socket send deadline aborts the exec.
fn writeSpioDataFdBounded(fd: std.c.fd_t, stream_id: spore_stream.StreamId, offset: u64, bytes: []const u8) c_int {
    var remaining = bytes;
    var frame_offset = offset;
    while (remaining.len > 0) {
        const take = @min(remaining.len, spore_stream.max_payload_len);
        if (writeSpioFrameFdBounded(fd, .data, stream_id, frame_offset, remaining[0..take]) != 0) return -1;
        frame_offset += @intCast(take);
        remaining = remaining[take..];
    }
    return 0;
}

fn writeSpioFrameFdBounded(fd: std.c.fd_t, frame_type: spore_stream.FrameType, stream_id: spore_stream.StreamId, offset: u64, payload: []const u8) c_int {
    var frame_buf: [spore_stream.max_frame_len]u8 = undefined;
    const frame = encodeSpioFrame(&frame_buf, frame_type, stream_id, offset, payload) orelse return -1;
    while (true) {
        const sent = std.c.send(fd, frame.ptr, frame.len, std.c.MSG.NOSIGNAL);
        // A signal interrupting the send before any bytes moved says nothing
        // about consumer progress; retry with a fresh deadline. Partial sends
        // and deadline expiry are consumer backpressure and abort the exec.
        if (sent < 0 and std.c.errno(sent) == .INTR) continue;
        if (sent < 0 or sent != frame.len) return -1;
        return 0;
    }
}

fn setStreamingSendDeadline(fd: std.c.fd_t) !void {
    const timeout = std.c.timeval{
        .sec = 0,
        .usec = streaming_send_deadline_ms * std.time.us_per_ms,
    };
    if (std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.SNDTIMEO, &timeout, @sizeOf(std.c.timeval)) != 0) {
        return error.MonitorUnavailable;
    }
}

fn writeSpioFrameFd(fd: std.c.fd_t, frame_type: spore_stream.FrameType, stream_id: spore_stream.StreamId, offset: u64, payload: []const u8) c_int {
    var frame_buf: [spore_stream.max_frame_len]u8 = undefined;
    const frame = encodeSpioFrame(&frame_buf, frame_type, stream_id, offset, payload) orelse return -1;
    return writeFdAll(fd, frame);
}

fn writeFdAll(fd: std.c.fd_t, bytes: []const u8) c_int {
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.write(fd, rest.ptr, rest.len);
        if (n < 0) {
            switch (std.c.errno(n)) {
                .INTR => continue,
                else => return -1,
            }
        }
        if (n == 0) return -1;
        rest = rest[@intCast(n)..];
    }
    return 0;
}

/// One guest operation handed off by the accept thread.
const ControlHandler = struct {
    thread: ?std.Thread = null,
    /// Set by the handler, under the server mutex, as it exits.
    finished: bool = false,
    stream: net.Stream = undefined,
    /// Holds `request`.
    arena: std.heap.ArenaAllocator = undefined,
    request: monitor_protocol.Request = undefined,
};

/// Whether the client of a control connection closed it. It has sent its
/// whole request, so any readable byte is an end of stream.
fn clientGone(fd: std.c.fd_t) bool {
    var byte: [1]u8 = undefined;
    const n = std.c.recv(fd, &byte, byte.len, std.c.MSG.PEEK | std.c.MSG.DONTWAIT);
    if (n == 0) return true;
    if (n > 0) return false;
    return switch (std.c.errno(n)) {
        .AGAIN, .INTR => false,
        else => true,
    };
}

fn controlThreadMain(server: *ExecServer) void {
    while (!server.isClosed()) {
        var fds = [_]std.posix.pollfd{.{ .fd = server.server.socket.handle, .events = std.c.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, control_accept_poll_ms) catch continue;
        if (ready == 0) continue;
        const stream = server.server.accept(server.io) catch continue;
        const handed_off = acceptControlClient(server, stream) catch false;
        if (!handed_off) stream.close(server.io);
    }
    for (&server.handlers) |*handler| {
        if (handler.thread) |thread| thread.join();
        handler.* = .{};
    }
}

/// Answers the requests that need no guest as soon as the connection is
/// accepted, so `hello`, `shutdown`, and disk-fork claims and cancels never
/// wait behind a guest operation. Returns true when a handler thread took the
/// stream.
fn acceptControlClient(server: *ExecServer, stream: net.Stream) !bool {
    const fd = stream.socket.handle;
    var read_buffer: [monitor_protocol.max_request_bytes]u8 = undefined;
    const deadline_ms = lifecycle.monotonicMs() +| control_request_timeout_ms;
    const line = readControlLineFd(fd, &read_buffer, deadline_ms) catch |err| {
        const message = if (err == error.ControlRequestTooLarge)
            "control request exceeds 8191 bytes; shorten the guest command"
        else
            "bad control request";
        try writeControlError(server.io, stream, message);
        return false;
    };
    var arena = std.heap.ArenaAllocator.init(server.allocator);
    var handed_off = false;
    defer if (!handed_off) arena.deinit();
    const request = monitor_protocol.decodeRequest(arena.allocator(), line) catch {
        try writeControlError(server.io, stream, "bad control request");
        return false;
    };
    switch (request) {
        .hello => try writeResponse(server.io, stream, monitor_protocol.HelloReply{}),
        .shutdown => {
            server.requestStop();
            try writeResponse(server.io, stream, monitor_protocol.Ok{});
        },
        .disk_claim => |claim| {
            var head = server.claimDiskHead(claim) catch |err| {
                try writeControlError(server.io, stream, @errorName(err));
                return false;
            };
            defer head.deinit();
            runtime_disk_claim.sendHead(fd, server.allocator, &head) catch {};
        },
        .disk_fork_cancel => |cancel| {
            _ = server.cancelDiskFork(cancel.batch);
            try writeResponse(server.io, stream, monitor_protocol.Ok{});
        },
        else => handed_off = try startControlHandler(server, stream, arena, request),
    }
    return handed_off;
}

/// Hands a guest operation to a handler thread, or tells the client the
/// monitor is busy when every handler is taken.
fn startControlHandler(server: *ExecServer, stream: net.Stream, arena: std.heap.ArenaAllocator, request: monitor_protocol.Request) !bool {
    var finished: [max_control_handlers]?std.Thread = @splat(null);
    var free: ?*ControlHandler = null;
    {
        server.mutex.lockUncancelable(server.io);
        defer server.mutex.unlock(server.io);
        for (&server.handlers, &finished) |*handler, *thread| {
            if (handler.thread != null and handler.finished) {
                thread.* = handler.thread;
                handler.* = .{};
            }
            if (handler.thread == null and free == null) free = handler;
        }
    }
    for (finished) |thread| if (thread) |value| value.join();

    const handler = free orelse {
        try writeRequestError(server, stream, request, "monitor busy");
        return false;
    };
    handler.stream = stream;
    handler.arena = arena;
    handler.request = request;
    handler.thread = std.Thread.spawn(.{}, controlHandlerMain, .{ server, handler }) catch {
        try writeRequestError(server, stream, request, "monitor busy");
        return false;
    };
    return true;
}

fn controlHandlerMain(server: *ExecServer, handler: *ControlHandler) void {
    handleControlClient(server, handler.stream, handler.request) catch {};
    handler.arena.deinit();
    handler.stream.close(server.io);
    server.mutex.lockUncancelable(server.io);
    defer server.mutex.unlock(server.io);
    handler.finished = true;
}

fn writeRequestError(server: *ExecServer, stream: net.Stream, request: monitor_protocol.Request, message: []const u8) !void {
    if (request.streams()) return writeStreamingControlError(stream.socket.handle, message);
    return writeControlError(server.io, stream, message);
}

const capture_unavailable_x86 = "capture is unavailable for the experimental x86-64 KVM fresh profile";

/// Runs one guest operation on a handler thread. Operations take turns on
/// the guest; each waits for the slot up to the VM's timeout.
fn handleControlClient(server: *ExecServer, stream: net.Stream, request: monitor_protocol.Request) !void {
    const fd = stream.socket.handle;
    switch (request) {
        .hello, .shutdown, .disk_claim, .disk_fork_cancel => unreachable,
        .disk_fork_prepare => |prepare| {
            if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
                return writeControlError(server.io, stream, capture_unavailable_x86);
            }
            const response = server.submitDiskFork(prepare) catch |err| {
                if (err == error.MonitorStopping) return writeControlError(server.io, stream, server.refusalMessage(err));
                return writeResponse(server.io, stream, monitor_protocol.Error{ .message = @errorName(err), .code = .of(err) });
            };
            defer std.heap.page_allocator.free(response);
            try writeAll(server.io, stream, response);
        },
        .@"suspend" => |capture| {
            if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
                return writeControlError(server.io, stream, capture_unavailable_x86);
            }
            var refusal_buf: [256]u8 = undefined;
            if (server.imageStoreRefusal(fd, &refusal_buf)) |refusal| return writeResponse(server.io, stream, refusal);
            const response = server.submitSuspend(capture.out_dir) catch |err| {
                return writeControlError(server.io, stream, server.refusalMessage(err));
            };
            defer std.heap.page_allocator.free(response);
            try writeAll(server.io, stream, response);
        },
        .snapshot => |snapshot| {
            if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
                return writeControlError(server.io, stream, capture_unavailable_x86);
            }
            var refusal_buf: [256]u8 = undefined;
            if (server.imageStoreRefusal(fd, &refusal_buf)) |refusal| return writeResponse(server.io, stream, refusal);
            const response = server.submitSnapshot(snapshot.out_dir, snapshot.publish_dir) catch |err| {
                return writeControlError(server.io, stream, server.refusalMessage(err));
            };
            defer std.heap.page_allocator.free(response);
            try writeAll(server.io, stream, response);
        },
        .exec_stream => |exec| {
            const tty = exec.stdio == .tty;
            const terminal_size = spore_stream.Resize{ .rows = exec.terminal_rows, .cols = exec.terminal_cols };
            var session_sequence: u64 = 0;
            const guest_request = server.interactiveExecRequest(&session_sequence, exec.argv, exec.env, exec.working_dir, tty, terminal_size) catch |err| {
                return writeStreamingControlError(fd, guestCommandErrorMessage(err));
            };
            defer server.allocator.free(guest_request);
            server.submitStreamingExec(guest_request, session_sequence, fd, true) catch |err| {
                return writeStreamingControlError(fd, server.refusalMessage(err));
            };
            defer server.finishStreamingExec();
            proxyStreamingInput(server, fd, if (tty) .terminal else .stdin) catch {};
        },
        .copy_in, .copy_out => {
            const copy_in = request == .copy_in;
            const path = if (copy_in) request.copy_in.path else request.copy_out.path;
            var session_sequence: u64 = 0;
            const guest_request = server.copyRequest(&session_sequence, if (copy_in) "copy-in-v1" else "copy-out-v1", path) catch {
                return writeStreamingControlError(fd, "invalid copy request");
            };
            defer server.allocator.free(guest_request);
            server.submitStreamingExec(guest_request, session_sequence, fd, false) catch |err| {
                return writeStreamingControlError(fd, server.refusalMessage(err));
            };
            defer server.finishStreamingExec();
            if (copy_in) proxyStreamingInput(server, fd, .stdin) catch {};
        },
        .initial_output => {
            // The initial-output request carries no session id.
            const response = server.submitExec("{\"type\":\"initial-output\"}\n", 0) catch |err| {
                return writeControlError(server.io, stream, server.refusalMessage(err));
            };
            defer std.heap.page_allocator.free(response);
            try writeAll(server.io, stream, response);
        },
        .start => |start| {
            var session_sequence: u64 = 0;
            const guest_request = server.detachedExecRequest(&session_sequence, start.argv, start.env, start.working_dir, start.retain_output) catch |err| {
                return writeControlError(server.io, stream, guestCommandErrorMessage(err));
            };
            defer server.allocator.free(guest_request);
            const response = server.submitExec(guest_request, session_sequence) catch |err| {
                return writeControlError(server.io, stream, server.refusalMessage(err));
            };
            defer std.heap.page_allocator.free(response);
            try writeAll(server.io, stream, response);
        },
    }
}

fn guestCommandErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.RunArgCountUnsupported => "guest command must contain between 1 and 16 arguments",
        error.RunProgramEmpty => "guest command has an empty program name",
        error.RunArgTooLong, error.RunRequestTooLarge => "guest command exceeds the 8191-byte request limit; shorten it or run a script in the guest",
        error.RunEnvCountUnsupported => "guest environment contains more than 64 entries",
        error.RunEnvTooLong => "guest environment entry exceeds 255 bytes",
        error.RunWorkingDirUnsupported => "guest working directory must be an absolute path of at most 255 bytes",
        else => "invalid guest command",
    };
}

/// Reads one request line a byte at a time, so the stream frames that follow
/// it stay unread. The whole line must arrive by `deadline_ms`.
fn readControlLineFd(fd: std.c.fd_t, buffer: []u8, deadline_ms: u64) ![]const u8 {
    var len: usize = 0;
    while (len < buffer.len) {
        const now = lifecycle.monotonicMs();
        if (now >= deadline_ms) return error.ControlRequestTimedOut;
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
        const wait_ms: i32 = @intCast(@min(deadline_ms - now, std.math.maxInt(i32)));
        if (try std.posix.poll(&fds, wait_ms) == 0) return error.ControlRequestTimedOut;
        var byte: [1]u8 = undefined;
        const n = std.c.read(fd, &byte, 1);
        if (n < 0) {
            switch (std.c.errno(n)) {
                .INTR => continue,
                else => return error.ControlStreamClosed,
            }
        }
        if (n == 0) return error.ControlStreamClosed;
        if (byte[0] == '\n') return buffer[0..len];
        buffer[len] = byte[0];
        len += 1;
    }
    return error.ControlRequestTooLarge;
}

fn monotonicNs() u64 {
    return std.math.mul(u64, lifecycle.monotonicMs(), std.time.ns_per_ms) catch std.math.maxInt(u64);
}

fn writeStreamingControlError(fd: std.c.fd_t, message: []const u8) !void {
    const payload = if (message.len > spore_stream.max_payload_len) message[0..spore_stream.max_payload_len] else message;
    if (writeSpioFrameFd(fd, .err, .control, 0, payload) != 0) return error.MonitorUnavailable;
}

fn proxyStreamingInput(server: *ExecServer, fd: std.c.fd_t, input_stream: spore_stream.StreamId) !void {
    var parser = LocalSpioInputParser{};
    var input_closed = false;
    while (true) {
        if (server.streamingDone()) return;
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.c.POLL.IN | std.c.POLL.HUP | std.c.POLL.ERR, .revents = 0 }};
        const ready = std.posix.poll(&fds, 50) catch return;
        if (ready == 0) continue;
        if ((fds[0].revents & std.c.POLL.IN) != 0) {
            const action = parser.read(fd) catch {
                if (!input_closed) {
                    _ = server.enqueueStreamingClose(input_stream) catch {};
                    input_closed = true;
                }
                return;
            };
            switch (action) {
                .none => {},
                .data => |data| {
                    if (data.stream_id != input_stream) {
                        _ = server.enqueueStreamingClose(input_stream) catch {};
                        return error.BadControlStreamFrame;
                    }
                    try server.enqueueStreamingInput(data.stream_id, data.bytes);
                },
                .close => |stream_id| {
                    if (stream_id != input_stream) {
                        _ = server.enqueueStreamingClose(input_stream) catch {};
                        return error.BadControlStreamFrame;
                    }
                    try server.enqueueStreamingClose(stream_id);
                    input_closed = true;
                },
                .resize => |resize| {
                    if (input_stream != .terminal) {
                        _ = server.enqueueStreamingClose(input_stream) catch {};
                        return error.BadControlStreamFrame;
                    }
                    try server.enqueueStreamingResize(resize);
                },
            }
        }
        if ((fds[0].revents & (std.c.POLL.HUP | std.c.POLL.ERR | std.c.POLL.NVAL)) != 0) {
            if (!input_closed) {
                _ = server.enqueueStreamingClose(input_stream) catch {};
                input_closed = true;
            }
        }
    }
}

const LocalSpioInputAction = union(enum) {
    none,
    data: struct {
        stream_id: spore_stream.StreamId,
        bytes: []const u8,
    },
    close: spore_stream.StreamId,
    resize: spore_stream.Resize,
};

const LocalSpioInputParser = struct {
    stdin_offset: u64 = 0,
    terminal_offset: u64 = 0,
    payload: [spore_stream.max_payload_len]u8 = undefined,

    fn read(self: *LocalSpioInputParser, fd: std.c.fd_t) !LocalSpioInputAction {
        var header_buf: [spore_stream.header_len]u8 = undefined;
        try readFdExact(fd, &header_buf);
        const header = try spore_stream.readHeader(&header_buf);
        if (header.flags != 0) return error.BadControlStreamFrame;
        if (header.payload_len > self.payload.len) return error.BadControlStreamFrame;
        const payload = self.payload[0..header.payload_len];
        if (payload.len > 0) try readFdExact(fd, payload);
        switch (header.frame_type) {
            .data => {
                if (header.stream_id != .stdin and header.stream_id != .terminal) return error.BadControlStreamFrame;
                const expected = switch (header.stream_id) {
                    .stdin => self.stdin_offset,
                    .terminal => self.terminal_offset,
                    else => unreachable,
                };
                if (header.offset != expected) return error.BadControlStreamFrame;
                const len: u64 = @intCast(payload.len);
                switch (header.stream_id) {
                    .stdin => self.stdin_offset += len,
                    .terminal => self.terminal_offset += len,
                    else => unreachable,
                }
                return .{ .data = .{ .stream_id = header.stream_id, .bytes = payload } };
            },
            .close => {
                if ((header.stream_id != .stdin and header.stream_id != .terminal) or payload.len != 0) return error.BadControlStreamFrame;
                const expected = switch (header.stream_id) {
                    .stdin => self.stdin_offset,
                    .terminal => self.terminal_offset,
                    else => unreachable,
                };
                if (header.offset != expected) return error.BadControlStreamFrame;
                return .{ .close = header.stream_id };
            },
            .resize => {
                if (header.stream_id != .terminal or header.offset != 0) return error.BadControlStreamFrame;
                const resize = try spore_stream.readResizePayload(payload);
                if (resize.rows == 0 or resize.cols == 0) return error.BadControlStreamFrame;
                return .{ .resize = resize };
            },
            else => return error.BadControlStreamFrame,
        }
    }
};

fn readFdExact(fd: std.c.fd_t, buf: []u8) !void {
    var rest = buf;
    while (rest.len > 0) {
        const n = std.c.read(fd, rest.ptr, rest.len);
        if (n < 0) {
            switch (std.c.errno(n)) {
                .INTR => continue,
                else => return error.ControlStreamClosed,
            }
        }
        if (n == 0) return error.ControlStreamClosed;
        rest = rest[@intCast(n)..];
    }
}

/// Writes one response line. `response` is a variant of
/// `monitor_protocol.Response`, or the hello reply.
fn writeResponse(io: Io, stream: net.Stream, response: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const json = try std.json.Stringify.valueAlloc(fixed.allocator(), response, .{});
    try writeAll(io, stream, json);
    try writeAll(io, stream, "\n");
}

fn writeControlError(io: Io, stream: net.Stream, message: []const u8) !void {
    try writeResponse(io, stream, monitor_protocol.Error{ .message = message });
}

fn writeAll(io: Io, stream: net.Stream, bytes: []const u8) !void {
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn usageExit() noreturn {
    std.debug.print("{s}", .{monitor_usage});
    std.process.exit(2);
}

fn wantsHelp(args: []const []const u8) bool {
    if (args.len == 1 and std.mem.eql(u8, args[0], "help")) return true;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or
            std.mem.eql(u8, arg, "--help"))
        {
            return true;
        }
    }
    return false;
}

fn currentPid() i64 {
    if (comptime @import("builtin").os.tag == .windows) return 1;
    return @intCast(std.c.getpid());
}

test "monitor cli help accepts help after name" {
    try std.testing.expect(wantsHelp(&.{"--help"}));
    try std.testing.expect(wantsHelp(&.{ "bench-1", "--help" }));
    try std.testing.expect(!wantsHelp(&.{"bench-1"}));
    try std.testing.expect(!wantsHelp(&.{ "help", "--backend", "auto" }));
}

test "named exec context applies image defaults and ephemeral overrides" {
    var env_buffer: [run.max_guest_envc][]const u8 = undefined;
    const context = try effectiveExecContext(&env_buffer, .{
        .env = &.{ "IMAGE_VALUE=default", "CLEAR_ME", "KEEP=1" },
        .working_dir = "/app",
    }, &.{ "IMAGE_VALUE=override", "CLEAR_ME=" }, "/work");

    try std.testing.expectEqual(@as(usize, 3), context.env.len);
    try std.testing.expectEqualStrings("KEEP=1", context.env[0]);
    try std.testing.expectEqualStrings("IMAGE_VALUE=override", context.env[1]);
    try std.testing.expectEqualStrings("CLEAR_ME=", context.env[2]);
    try std.testing.expectEqualStrings("/work", context.working_dir.?);

    const inherited = try effectiveExecContext(&env_buffer, .{
        .env = &.{"IMAGE_VALUE=default"},
        .working_dir = "/app",
    }, &.{}, null);
    try std.testing.expectEqualStrings("IMAGE_VALUE=default", inherited.env[0]);
    try std.testing.expectEqualStrings("/app", inherited.working_dir.?);
}

test "monitor network comes from the spec's encoded live policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var policy = run.NetworkPolicy{};
    try policy.addNetworkPolicy(.{});
    try policy.addAllowCidr("93.184.216.34/32");
    try policy.addPortForward("127.0.0.1:8080:80");
    const network = (try run.manifestNetworkFromOptions(allocator, .spore, &policy)).?;
    const encoded = try spore_net_policy.encodeArgAlloc(allocator, &policy);

    const enabled = try monitorNetwork(allocator, .{ .name = "bench-1", .network = network, .network_policy = encoded });
    try std.testing.expectEqual(run.NetworkMode.spore, enabled.mode);
    try std.testing.expectEqualDeep(policy, enabled.policy);
    try std.testing.expectEqual(run.NetworkMode.disabled, (try monitorNetwork(allocator, .{ .name = "bench-1" })).mode);
    try std.testing.expectError(error.InvalidNetworkPolicy, monitorNetwork(allocator, .{ .name = "bench-1", .network = network }));
    try std.testing.expectError(error.InvalidNetworkPolicy, monitorNetwork(allocator, .{ .name = "bench-1", .network_policy = encoded }));
}

test "monitor session ids cannot replay across restored monitors" {
    var first: [64]u8 = undefined;
    var restored: [64]u8 = undefined;
    const first_id = try formatSessionId(&first, 0x0123456789abcdef, 1);
    const restored_id = try formatSessionId(&restored, 0xfedcba9876543210, 1);
    try std.testing.expectEqualStrings("lifecycle-123456789abcdef-1", first_id);
    try std.testing.expect(!std.mem.eql(u8, first_id, restored_id));
}

test "monitor records the exact generated request sequence for stream logging" {
    var server: ExecServer = undefined;
    server.io = std.testing.io;
    server.mutex = .init;
    server.session_nonce = 0x0123_4567_89ab_cdef;
    server.next_session_id = 41;
    var buffer: [64]u8 = undefined;
    var sequence: u64 = 0;

    const session_id = try server.nextSessionId(&buffer, &sequence);

    try std.testing.expectEqualStrings("lifecycle-123456789abcdef-41", session_id);
    try std.testing.expectEqual(@as(u64, 41), sequence);
    try std.testing.expectEqual(@as(u64, 42), server.next_session_id);
    var log_buffer: [160]u8 = undefined;
    try std.testing.expectEqualStrings(
        "monitor vsock stream start: kind=exec session_id=lifecycle-123456789abcdef-41 host_port=54321",
        formatExecHostStreamStart(&log_buffer, server.session_nonce, sequence, 54321),
    );
}

test "streaming named exec carries the restored generation" {
    var server: ExecServer = undefined;
    server.allocator = std.testing.allocator;
    server.io = std.testing.io;
    server.mutex = .init;
    server.exec_defaults = .{};
    server.generation_params = "{\"generation\":2,\"vm_id\":\"child-0\"}";
    server.session_nonce = 1;
    server.next_session_id = 1;

    var sequence: u64 = 0;
    const request = try server.interactiveExecRequest(&sequence, &.{"/bin/gencheck"}, &.{}, null, false, .{ .rows = 24, .cols = 80 });
    defer std.testing.allocator.free(request);
    const parsed = try std.json.parseFromSlice(struct { params_json: []const u8 }, std.testing.allocator, request, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(server.generation_params.?, parsed.value.params_json);
}

test "monitor host streams use nonce-seeded ports without early reuse" {
    var server: ExecServer = undefined;
    server.next_host_stream_sequence = 0x1234_5678_9abc_def0;

    const readiness = server.nextHostStreamPort();
    const first_exec = server.nextHostStreamPort();
    const repeated_exec = server.nextHostStreamPort();

    try std.testing.expectEqual(vsock_stream.HostStream.hostPortForSequence(0x1234_5678_9abc_def0), readiness);
    try std.testing.expectEqual(vsock_stream.HostStream.hostPortForSequence(0x1234_5678_9abc_def1), first_exec);
    try std.testing.expectEqual(vsock_stream.HostStream.hostPortForSequence(0x1234_5678_9abc_def2), repeated_exec);
    try std.testing.expect(readiness != first_exec);
    try std.testing.expect(first_exec != repeated_exec);
}

test "named snapshot cache contention returns pending before the pause authority is borrowed" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const cache_root = try std.fs.path.join(allocator, &.{ root, "cache" });
    defer allocator.free(cache_root);
    var server: ExecServer = undefined;
    server.allocator = allocator;
    server.io = io;
    server.cache_root = cache_root;
    server.mutex = .init;
    server.op = .{ .snapshot = .{ .phase = .active, .dir = "/tmp/save.tmp", .publish_dir = "/tmp/save.spore" } };
    server.snapshot_publication_wait = .{};
    var held = try rootfs_mod.lockRootfsCacheExclusive(io, allocator, cache_root);
    defer held.deinit();
    try std.testing.expect(try server.prepareSnapshot() == null);
    try std.testing.expectEqual(Phase.pending, server.op.snapshot.phase);
    try std.testing.expect(server.snapshot_publication_wait.started_ns != null);

    // This is the state in which each backend falls through to one normal
    // guest-run opportunity instead of retrying the lock in a tight loop.
    server.op.snapshot.phase = .active;
    held.deinit();
    var preparation = (try server.prepareSnapshot()) orelse return error.TestUnexpectedResult;
    const borrowed = preparation.cacheLock();
    try std.testing.expect(try borrowed.ensureHeldFor(allocator, cache_root));
    const wrong_root = try std.fs.path.join(allocator, &.{ root, "wrong-cache" });
    defer allocator.free(wrong_root);
    try Io.Dir.cwd().createDirPath(io, wrong_root);
    try std.testing.expect(!try borrowed.ensureHeldFor(allocator, wrong_root));

    preparation.deinit();
    try std.testing.expect(server.snapshot_publication_wait.started_ns == null);
}

test "snapshot publication preserves create annotations and applies save overlay" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const cache_root = try std.fs.path.join(arena, &.{ root, "cache" });
    const work_dir = try std.fs.path.join(arena, &.{ root, "snapshot.tmp" });
    const publish_dir = try std.fs.path.join(arena, &.{ root, "snapshot.spore" });
    try Io.Dir.cwd().createDirPath(io, work_dir);

    var create_annotations = spore.Annotations{};
    try create_annotations.map.put(arena, "create-only", "create");
    try create_annotations.map.put(arena, "shared", "create");
    var save_annotations = spore.Annotations{};
    try save_annotations.map.put(arena, "save-only", "save");
    try save_annotations.map.put(arena, "shared", "save");
    const merged = try spore.mergeAnnotations(arena, create_annotations, save_annotations);

    try spore.saveManifest(arena, work_dir, manifest_test_support.manifest(create_annotations));
    try lifecycle.writeSporeLifecycleSpec(arena, io, work_dir, .{
        .name = "source",
        .annotations = merged,
        .exec_defaults = .{
            .env = &.{"IMAGE_VALUE=default"},
            .working_dir = "/workspace",
        },
    });

    var wait = snapshot_publication.Wait{};
    var preparation = (try wait.tryPrepare(io, arena, cache_root)) orelse return error.TestUnexpectedResult;
    defer preparation.deinit();
    var server: ExecServer = undefined;
    server.allocator = arena;
    server.io = io;
    server.cache_root = cache_root;
    _ = try server.publishSnapshot(&preparation, work_dir, publish_dir);

    var published = try spore.loadManifest(arena, publish_dir);
    defer published.deinit();
    try std.testing.expectEqual(@as(usize, 3), published.value.annotations.map.count());
    try std.testing.expectEqualStrings("create", published.value.annotations.map.get("create-only").?);
    try std.testing.expectEqualStrings("save", published.value.annotations.map.get("save-only").?);
    try std.testing.expectEqualStrings("save", published.value.annotations.map.get("shared").?);
    try std.testing.expectEqualStrings("IMAGE_VALUE=default", published.value.exec_defaults.?.env[0]);
    try std.testing.expectEqualStrings("/workspace", published.value.exec_defaults.?.working_dir.?);
}

test "snapshot disk lease handoff preserves old authority on failure and commits new authority transactionally" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const runtime_root = try std.fs.path.join(allocator, &.{ root, "runtime" });
    defer allocator.free(runtime_root);
    const cache_root = try std.fs.path.join(allocator, &.{ root, "cache" });
    defer allocator.free(cache_root);
    const paths = try lifecycle.pathsFromRoot(allocator, runtime_root, "source");
    defer paths.deinit(allocator);

    const old_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const new_digest = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const device = spore.RootfsDevice{ .mmio_slot = 1 };
    const old_storage = spore.RootfsStorage{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = device,
        .logical_size = spore.disk_chunk_size,
        .chunk_size = spore.disk_chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .index_digest = old_digest,
        .base_identity = old_digest,
        .object_namespace = spore.rootfs_storage_object_namespace,
    };
    const new_storage = spore.RootfsStorage{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = device,
        .logical_size = spore.disk_chunk_size,
        .chunk_size = spore.disk_chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .index_digest = new_digest,
        .base_identity = new_digest,
        .object_namespace = spore.rootfs_storage_object_namespace,
    };
    const old_disk = spore.Disk{
        .kind = spore.disk_kind_chunk_index,
        .device = device,
        .size = spore.disk_chunk_size,
        .base = old_digest,
        .chunk_size = spore.disk_chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .object_namespace = spore.rootfs_storage_object_namespace,
    };
    const new_disk = spore.Disk{
        .kind = spore.disk_kind_chunk_index,
        .device = device,
        .size = spore.disk_chunk_size,
        .base = new_digest,
        .chunk_size = spore.disk_chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .object_namespace = spore.rootfs_storage_object_namespace,
    };
    const old_lease = runtime_disk_lease.Lease{
        .store = .rootfs_cache,
        .root = cache_root,
        .baseline_kind = .disk_index,
        .baseline_identity = old_digest,
        .rootfs_storage = old_storage,
    };
    const new_lease = runtime_disk_lease.Lease{
        .store = .rootfs_cache,
        .root = cache_root,
        .baseline_kind = .disk_index,
        .baseline_identity = new_digest,
        .rootfs_storage = new_storage,
    };
    try vm_registry.ensureDirPath(io, paths.vm_dir);
    var entry = try vm_registry.Entry.open(io, paths);
    defer entry.close(io);
    try entry.writeSpec(allocator, io, .{
        .name = "source",
        .disk = old_disk,
        .disk_baseline_lease = old_lease,
    });
    var active_slot: ?runtime_disk_lease.Active = try runtime_disk_lease.acquireActive(io, allocator, runtime_root, old_lease);
    defer if (active_slot) |*active| active.deinit();
    const old_active_path = try allocator.dupe(u8, active_slot.?.path);
    defer allocator.free(old_active_path);

    testing.snapshot_lease_handoff_fault = .{ .fail_before_source_spec = true };
    defer testing.snapshot_lease_handoff_fault = .{};
    try std.testing.expectError(error.InjectedFailure, persistSourceDiskLeaseHandoff(
        io,
        allocator,
        runtime_root,
        entry,
        new_disk,
        new_lease,
        &active_slot,
    ));
    testing.snapshot_lease_handoff_fault = .{};
    var after_failure = try lifecycle.readSpec(allocator, io, paths);
    defer after_failure.deinit();
    try std.testing.expectEqualStrings(old_digest, after_failure.value.disk.?.base);
    try std.testing.expectEqualStrings(old_digest, after_failure.value.disk_baseline_lease.?.baseline_identity);
    _ = try Io.Dir.cwd().statFile(io, old_active_path, .{ .follow_symlinks = false });
    var failed_active_it = try runtime_disk_lease.ActiveIterator.init(allocator, io, runtime_root);
    defer failed_active_it.deinit();
    var failed_active_count: usize = 0;
    while (try failed_active_it.next()) |parsed_value| {
        var parsed = parsed_value;
        defer parsed.deinit();
        failed_active_count += 1;
        try std.testing.expectEqualStrings(old_digest, parsed.value.baseline_identity);
    }
    try std.testing.expectEqual(@as(usize, 1), failed_active_count);

    try persistSourceDiskLeaseHandoff(io, allocator, runtime_root, entry, new_disk, new_lease, &active_slot);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, old_active_path, .{ .follow_symlinks = false }));
    var after_success = try lifecycle.readSpec(allocator, io, paths);
    defer after_success.deinit();
    try std.testing.expectEqualStrings(new_digest, after_success.value.disk.?.base);
    try std.testing.expectEqualStrings(new_digest, after_success.value.disk_baseline_lease.?.baseline_identity);
    try std.testing.expect(spore.rootfsStorageEql(new_storage, after_success.value.disk_baseline_lease.?.rootfs_storage.?));
    _ = try Io.Dir.cwd().statFile(io, active_slot.?.path, .{ .follow_symlinks = false });
    var success_active_it = try runtime_disk_lease.ActiveIterator.init(allocator, io, runtime_root);
    defer success_active_it.deinit();
    var success_active_count: usize = 0;
    while (try success_active_it.next()) |parsed_value| {
        var parsed = parsed_value;
        defer parsed.deinit();
        success_active_count += 1;
        try std.testing.expectEqualStrings(new_digest, parsed.value.baseline_identity);
        try std.testing.expect(spore.rootfsStorageEql(new_storage, parsed.value.rootfs_storage.?));
    }
    try std.testing.expectEqual(@as(usize, 1), success_active_count);
}

test "snapshot manifest publication serializes destructive collection until pin visibility" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const cache_root = try std.fs.path.join(arena, &.{ root, "cache" });
    const runtime_root = try std.fs.path.join(arena, &.{ root, "runtime" });
    const save_dir = try std.fs.path.join(arena, &.{ root, "saved.spore" });
    const fixture = try manifest_test_support.diskFixture(arena, io, cache_root, save_dir, 0x75, false);

    var publication_boundary = test_barrier.Barrier{};
    saved_spore_pin.testing.publish_authority_barrier = &publication_boundary;
    defer saved_spore_pin.testing.publish_authority_barrier = null;
    const PublishContext = struct {
        allocator: std.mem.Allocator,
        io: Io,
        cache_root: []const u8,
        save_dir: []const u8,
        fixture: manifest_test_support.DiskFixture,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            defer if (saved_spore_pin.testing.publish_authority_barrier) |barrier| barrier.reached.post(self.io);
            var lock = rootfs_mod.lockRootfsCacheExclusive(self.io, self.allocator, self.cache_root) catch |err| {
                self.err = err;
                return;
            };
            defer lock.deinit();
            const registry = saved_spore_pin.LockedRegistry.init(self.allocator, self.cache_root, &lock) catch |err| {
                self.err = err;
                return;
            };
            saved_spore_pin.publishManifest(self.io, self.allocator, registry, self.save_dir, self.fixture.disk, self.fixture.manifest) catch |err| {
                self.err = err;
                return;
            };
        }
    };
    var publish_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer publish_arena_state.deinit();
    var publish_context = PublishContext{
        .allocator = publish_arena_state.allocator(),
        .io = io,
        .cache_root = cache_root,
        .save_dir = save_dir,
        .fixture = fixture,
    };
    var publish_thread = test_barrier.ThreadGuard{
        .io = io,
        .thread = try std.Thread.spawn(.{}, PublishContext.run, .{&publish_context}),
        .barriers = &.{&publication_boundary},
    };
    defer publish_thread.deinit();
    publication_boundary.waitReached(io);
    if (publish_context.err) |err| return err;

    const CollectionContext = struct {
        allocator: std.mem.Allocator,
        io: Io,
        cache_root: []const u8,
        runtime_root: []const u8,
        attempting: *Io.Semaphore,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            defer {
                if (system.testing.gc_mutation_barrier) |barrier| barrier.reached.post(self.io);
            }
            self.attempting.post(self.io);
            const result = system.gc(self.allocator, self.io, .{ .cache_root = self.cache_root, .runtime_root = self.runtime_root, .dry_run = false }) catch |err| {
                self.err = err;
                return;
            };
            system.deinitRootfsGcResult(self.allocator, result);
        }
    };
    var gc_boundary = test_barrier.Barrier{};
    var gc_attempting = Io.Semaphore{};
    system.testing.gc_mutation_barrier = &gc_boundary;
    defer system.testing.gc_mutation_barrier = null;
    var gc_context = CollectionContext{ .allocator = allocator, .io = io, .cache_root = cache_root, .runtime_root = runtime_root, .attempting = &gc_attempting };
    var gc_thread = test_barrier.ThreadGuard{
        .io = io,
        .thread = try std.Thread.spawn(.{}, CollectionContext.run, .{&gc_context}),
        .barriers = &.{&gc_boundary},
    };
    defer gc_thread.deinit();
    gc_attempting.waitUncancelable(io);
    publication_boundary.release(io);
    publish_thread.join();
    if (publish_context.err) |err| return err;
    gc_boundary.waitReached(io);
    if (gc_context.err) |err| return err;
    gc_boundary.release(io);
    gc_thread.join();
    if (gc_context.err) |err| return err;

    var validation_lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, cache_root);
    defer validation_lock.deinit();
    const registry = try saved_spore_pin.LockedRegistry.init(arena, cache_root, &validation_lock);
    var record = try saved_spore_pin.loadForSporeLocked(io, arena, registry, save_dir, fixture.disk);
    defer record.deinit();
    const object_path = try rootfs_cas.manifestObjectPath(arena, cache_root, fixture.object_digest);
    const bytes = try rootfs_cas.readVerifiedChunkPath(allocator, object_path, fixture.object_digest, fixture.object_bytes.len);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, fixture.object_bytes, bytes);
}

test "snapshot publication handoff retains the new baseline across concurrent save removal and collection" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const runtime_root = try std.fs.path.join(arena, &.{ root, "runtime" });
    const cache_root = try std.fs.path.join(arena, &.{ root, "cache" });
    const old_dir = try std.fs.path.join(arena, &.{ root, "old.spore" });
    const new_dir = try std.fs.path.join(arena, &.{ root, "new.spore" });
    const old_fixture = try manifest_test_support.diskFixture(arena, io, cache_root, old_dir, 0x73, false);
    const new_fixture = try manifest_test_support.diskFixture(arena, io, cache_root, new_dir, 0x74, false);
    try spore.saveManifest(arena, old_dir, old_fixture.manifest);
    try rootfs_cas.markStorageComplete(io, arena, cache_root, old_fixture.storage.index_digest);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_root);
    try env.put(local_paths.runtime_dir_env, runtime_root);
    const source_paths = try lifecycle.pathsFromRoot(arena, runtime_root, "source");
    try vm_registry.ensureDirPath(io, source_paths.vm_dir);
    var source_entry = try vm_registry.Entry.open(io, source_paths);
    defer source_entry.close(io);
    try lifecycle.writeSpec(arena, io, source_paths, .{
        .name = "source",
        .disk = old_fixture.disk,
        .disk_baseline_lease = .{
            .store = .rootfs_cache,
            .root = cache_root,
            .baseline_kind = .disk_index,
            .baseline_identity = old_fixture.storage.index_digest,
            .rootfs_storage = old_fixture.storage,
        },
    });
    const old_lease = runtime_disk_lease.Lease{
        .store = .rootfs_cache,
        .root = cache_root,
        .baseline_kind = .disk_index,
        .baseline_identity = old_fixture.storage.index_digest,
        .rootfs_storage = old_fixture.storage,
    };
    const new_lease = runtime_disk_lease.Lease{
        .store = .rootfs_cache,
        .root = cache_root,
        .baseline_kind = .disk_index,
        .baseline_identity = new_fixture.storage.index_digest,
        .rootfs_storage = new_fixture.storage,
    };
    // The successful handoff replaces active_slot with an Active allocated by
    // this worker arena. Keep that owner alive until active_slot is released.
    var handoff_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer handoff_arena_state.deinit();
    var active_slot: ?runtime_disk_lease.Active = try runtime_disk_lease.acquireActive(io, allocator, runtime_root, old_lease);
    defer if (active_slot) |*active| active.deinit();
    {
        var pin_lock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, cache_root);
        defer pin_lock.deinit();
        const pin_registry = try saved_spore_pin.LockedRegistry.init(arena, cache_root, &pin_lock);
        try saved_spore_pin.publishManifest(io, arena, pin_registry, new_dir, new_fixture.disk, new_fixture.manifest);
    }

    var handoff_boundary = test_barrier.Barrier{};
    testing.snapshot_lease_handoff_barrier = &handoff_boundary;
    defer testing.snapshot_lease_handoff_barrier = null;
    var handoff_done = Io.Semaphore{};
    var handoff_finish = Io.Semaphore{};
    const HandoffContext = struct {
        allocator: std.mem.Allocator,
        io: Io,
        cache_root: []const u8,
        runtime_root: []const u8,
        entry: vm_registry.Entry,
        disk: spore.Disk,
        lease: runtime_disk_lease.Lease,
        active_slot: *?runtime_disk_lease.Active,
        done: *Io.Semaphore,
        finish: *Io.Semaphore,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            defer if (testing.snapshot_lease_handoff_barrier) |barrier| barrier.reached.post(self.io);
            var lock = rootfs_mod.lockRootfsCacheExclusive(self.io, self.allocator, self.cache_root) catch |err| {
                self.err = err;
                self.done.post(self.io);
                return;
            };
            persistSourceDiskLeaseHandoff(self.io, self.allocator, self.runtime_root, self.entry, self.disk, self.lease, self.active_slot) catch |err| {
                lock.deinit();
                self.err = err;
                self.done.post(self.io);
                return;
            };
            lock.deinit();
            self.done.post(self.io);
            self.finish.waitUncancelable(self.io);
        }
    };
    var handoff_context = HandoffContext{
        .allocator = handoff_arena_state.allocator(),
        .io = io,
        .cache_root = cache_root,
        .runtime_root = runtime_root,
        .entry = source_entry,
        .disk = new_fixture.disk,
        .lease = new_lease,
        .active_slot = &active_slot,
        .done = &handoff_done,
        .finish = &handoff_finish,
    };
    var handoff_thread = test_barrier.ThreadGuard{
        .io = io,
        .thread = try std.Thread.spawn(.{}, HandoffContext.run, .{&handoff_context}),
        .barriers = &.{&handoff_boundary},
    };
    defer handoff_thread.deinit();
    handoff_boundary.waitReached(io);
    if (handoff_context.err) |err| return err;

    var remove_boundary = test_barrier.Barrier{};
    var gc_boundary = test_barrier.Barrier{};
    var prune_boundary = test_barrier.Barrier{};
    saved_spore_pin.testing.remove_mutation_barrier = &remove_boundary;
    defer saved_spore_pin.testing.remove_mutation_barrier = null;
    system.testing.gc_mutation_barrier = &gc_boundary;
    defer system.testing.gc_mutation_barrier = null;
    system.testing.prune_mutation_barrier = &prune_boundary;
    defer system.testing.prune_mutation_barrier = null;
    const DestructiveContext = struct {
        allocator: std.mem.Allocator,
        io: Io,
        cache_root: []const u8,
        runtime_root: []const u8,
        save_dir: []const u8,
        env: *const std.process.Environ.Map,
        attempting: *Io.Semaphore,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            defer {
                if (saved_spore_pin.testing.remove_mutation_barrier) |barrier| barrier.reached.post(self.io);
                if (system.testing.gc_mutation_barrier) |barrier| barrier.reached.post(self.io);
                if (system.testing.prune_mutation_barrier) |barrier| barrier.reached.post(self.io);
            }
            self.attempting.post(self.io);
            const removed = lifecycle.removeSavedSpore(Context{ .io = self.io, .environ_map = self.env }, self.allocator, self.save_dir) catch |err| {
                self.err = err;
                return;
            };
            lifecycle.deinitRemovedSavedSpore(self.allocator, removed);
            const gc_result = system.gc(self.allocator, self.io, .{ .cache_root = self.cache_root, .runtime_root = self.runtime_root, .dry_run = false }) catch |err| {
                self.err = err;
                return;
            };
            system.deinitRootfsGcResult(self.allocator, gc_result);
            const prune_result = system.prune(self.allocator, self.io, .{
                .cache_root = self.cache_root,
                .runtime_root = self.runtime_root,
                .dry_run = false,
                .include_rootfs_chunks = true,
                .max_bytes = 0,
                .rootfs_only = true,
            }, Io.Clock.real.now(self.io).nanoseconds) catch |err| {
                self.err = err;
                return;
            };
            system.deinitRootfsPruneResult(self.allocator, prune_result);
        }
    };
    var destructive_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer destructive_arena_state.deinit();
    var destructive_attempting = Io.Semaphore{};
    var destructive_context = DestructiveContext{
        .allocator = destructive_arena_state.allocator(),
        .io = io,
        .cache_root = cache_root,
        .runtime_root = runtime_root,
        .save_dir = new_dir,
        .env = &env,
        .attempting = &destructive_attempting,
    };
    var destructive_thread = test_barrier.ThreadGuard{
        .io = io,
        .thread = try std.Thread.spawn(.{}, DestructiveContext.run, .{&destructive_context}),
        .barriers = &.{ &remove_boundary, &gc_boundary, &prune_boundary },
    };
    defer destructive_thread.deinit();
    destructive_attempting.waitUncancelable(io);
    handoff_boundary.release(io);
    handoff_done.waitUncancelable(io);
    if (handoff_context.err) |err| return err;
    remove_boundary.waitReached(io);
    if (destructive_context.err) |err| return err;
    remove_boundary.release(io);
    gc_boundary.waitReached(io);
    if (destructive_context.err) |err| return err;
    gc_boundary.release(io);
    prune_boundary.waitReached(io);
    if (destructive_context.err) |err| return err;
    prune_boundary.release(io);
    destructive_thread.join();
    if (destructive_context.err) |err| return err;
    const new_object_path = try rootfs_cas.manifestObjectPath(arena, cache_root, new_fixture.object_digest);
    const bytes = try rootfs_cas.readVerifiedChunkPath(allocator, new_object_path, new_fixture.object_digest, new_fixture.object_bytes.len);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, new_fixture.object_bytes, bytes);
    var source_spec = try lifecycle.readSpec(arena, io, source_paths);
    defer source_spec.deinit();
    try std.testing.expectEqualStrings(new_fixture.storage.index_digest, source_spec.value.disk_baseline_lease.?.baseline_identity);
    handoff_finish.post(io);
    handoff_thread.join();
}

test "monitor reports actionable guest command request errors" {
    try std.testing.expectEqualStrings(
        "guest command must contain between 1 and 16 arguments",
        guestCommandErrorMessage(error.RunArgCountUnsupported),
    );
    try std.testing.expectEqualStrings(
        "guest command exceeds the 8191-byte request limit; shorten it or run a script in the guest",
        guestCommandErrorMessage(error.RunRequestTooLarge),
    );
}

test "streaming output backpressure fails instead of blocking" {
    var pair: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair) != 0) return error.IoFailed;
    defer _ = std.c.close(pair[0]);
    defer _ = std.c.close(pair[1]);
    try setStreamingSendDeadline(pair[0]);

    var payload: [spore_stream.max_payload_len]u8 = @splat('x');
    var offset: u64 = 0;
    var rejected = false;
    for (0..1024) |_| {
        if (writeSpioFrameFdBounded(pair[0], .data, .stdout, offset, &payload) != 0) {
            rejected = true;
            break;
        }
        offset += payload.len;
    }
    try std.testing.expect(rejected);
}

test "named exec timing partitions monitor and guest phases" {
    var stream = try vsock_stream.HostStream.init(10700, "{}\n");
    stream.started_at_ms = 110;
    stream.response_ms = 80;
    stream.guest_timing_ms = 70;
    stream.guest_accept_ms = 10;
    stream.guest_spawn_ms = 20;
    stream.guest_exit_ms = 60;
    stream.guest_now_ms = 63;
    stream.guest_user_cpu_us = 31_000;
    stream.guest_system_cpu_us = 7_000;

    const timing = namedExecTiming(&stream, 100, 200);
    try std.testing.expectEqual(@as(?u64, 27), timing.dispatch_ms);
    try std.testing.expectEqual(@as(?u64, 10), timing.guest_process_start_ms);
    try std.testing.expectEqual(@as(?u64, 40), timing.guest_execution_ms);
    try std.testing.expectEqual(@as(?u64, 31_000), timing.guest_user_cpu_us);
    try std.testing.expectEqual(@as(?u64, 7_000), timing.guest_system_cpu_us);
    try std.testing.expectEqual(@as(?u64, 13), timing.output_result_delivery_ms);
    try std.testing.expectEqual(@as(u64, 10), timing.teardown_ms);
    try std.testing.expectEqual(@as(u64, 100), timing.total_ms);
}

test "a monitor fetches a store-backed root disk before a save pauses the guest, or refuses the save" {
    var fixture: image_store_mod.TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const store = try fixture.path("store");
    _ = try fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/1", .{store}));
    const ref = try std.fmt.allocPrint(allocator, "file://{s}/1", .{store});
    var object: ?[]const u8 = null;
    for (try fixture.listStore(store)) |file| {
        if (std.mem.startsWith(u8, file, "objects/")) object = try std.fs.path.join(allocator, &.{ store, file });
    }
    const hidden = try fixture.path("hidden");
    const digest = try std.fmt.allocPrint(allocator, "blake3:{s}", .{std.fs.path.basename(object.?)});
    const len: usize = @intCast((try std.Io.Dir.cwd().statFile(io, object.?, .{})).size);
    var buf: [256]u8 = undefined;
    // The save request's client end, which stays connected.
    var client: StoreSaveClient = try .init();
    defer client.deinit();

    // The store lost an object: the save is refused and nothing paused.
    var monitor: StoreMonitor = undefined;
    try monitor.init(try fixture.path("cache"), ref, allocator, &fixture.env);
    defer monitor.deinit();
    try std.Io.Dir.renameAbsolute(object.?, hidden, io);
    const refusal = monitor.server.imageStoreRefusal(client.monitor_end, &buf) orelse return error.TestExpectedRefusal;
    try std.testing.expectEqualStrings(save_refused_image_store ++ ": ImageStoreNotFound", refusal.message);
    try std.testing.expectEqual(monitor_protocol.ErrorCode.image_store_incomplete, refusal.code.?);
    try std.testing.expectEqual(Op.idle, monitor.server.op);
    // Once the store has it again, the save goes ahead with every object local.
    try std.Io.Dir.renameAbsolute(hidden, object.?, io);
    try std.testing.expectEqual(null, monitor.server.imageStoreRefusal(client.monitor_end, &buf));
    try std.testing.expect(try rootfs_cas.storageContentComplete(io, allocator, try fixture.path("cache"), monitor.storage));

    // A guest read that could not fetch its object poisoned the disk, so its
    // saves stay refused even when the store recovers.
    var poisoned: StoreMonitor = undefined;
    try poisoned.init(try fixture.path("poisoned-cache"), ref, allocator, &fixture.env);
    defer poisoned.deinit();
    try std.Io.Dir.renameAbsolute(object.?, hidden, io);
    try std.testing.expectError(error.ImageStoreNotFound, poisoned.fetcher.fetchObject(digest, try allocator.alloc(u8, len), &.{}));
    try std.Io.Dir.renameAbsolute(hidden, object.?, io);
    try std.testing.expectEqualStrings(save_refused_image_store ++ ": a guest read from it failed earlier", poisoned.server.imageStoreRefusal(client.monitor_end, &buf).?.message);

    // A stopping monitor cancels the fetch and says it is stopping, not that
    // the store failed; a client that left during the fetch gets no save.
    var canceled: StoreMonitor = undefined;
    try canceled.init(try fixture.path("canceled-cache"), ref, allocator, &fixture.env);
    defer canceled.deinit();
    canceled.server.cancelImageStoreFetch();
    const stopping = canceled.server.imageStoreRefusal(client.monitor_end, &buf).?;
    try std.testing.expectEqualStrings(removal_message, stopping.message);
    try std.testing.expectEqual(null, stopping.code);
    var gone: StoreMonitor = undefined;
    try gone.init(try fixture.path("gone-cache"), ref, allocator, &fixture.env);
    defer gone.deinit();
    var left: StoreSaveClient = try .init();
    defer left.deinit();
    left.hangUp();
    try std.testing.expectEqualStrings(save_refused_image_store ++ ": the client went away", gone.server.imageStoreRefusal(left.monitor_end, &buf).?.message);
}

test "a save is refused when a guest read fails while the monitor fetches the image" {
    var fixture: image_store_mod.TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const store = try fixture.path("store");
    _ = try fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/1", .{store}));
    var object: ?[]const u8 = null;
    for (try fixture.listStore(store)) |file| {
        if (std.mem.startsWith(u8, file, "objects/")) object = try std.fs.path.join(allocator, &.{ store, file });
    }
    const digest = try std.fmt.allocPrint(allocator, "blake3:{s}", .{std.fs.path.basename(object.?)});
    const len: usize = @intCast((try std.Io.Dir.cwd().statFile(io, object.?, .{})).size);
    var monitor: StoreMonitor = undefined;
    try monitor.init(try fixture.path("cache"), try std.fmt.allocPrint(allocator, "file://{s}/1", .{store}), allocator, &fixture.env);
    defer monitor.deinit();
    var client: StoreSaveClient = try .init();
    defer client.deinit();

    // The save checks for failed reads, then waits to start its fetch.
    const fill_mutex = &monitor.fetcher.fill_mutex;
    try std.testing.expect(fill_mutex.tryLock());
    var refusal_buf: [256]u8 = undefined;
    const Save = struct {
        refusal: ?monitor_protocol.Error = null,
        fn run(save: *@This(), server: *ExecServer, fd: std.c.fd_t, buf: []u8) void {
            save.refusal = server.imageStoreRefusal(fd, buf);
        }
    };
    var save: Save = .{};
    const thread = std.Thread.spawn(.{}, Save.run, .{ &save, &monitor.server, client.monitor_end, &refusal_buf }) catch |err| {
        fill_mutex.unlock(io);
        return err;
    };
    var waiting = true;
    errdefer if (waiting) {
        fill_mutex.unlock(io);
        thread.join();
    };
    while (fill_mutex.state.load(.monotonic) != .contended) try std.Io.sleep(io, .fromMilliseconds(1), .awake);

    // Meanwhile a guest read finds the object missing from the store, which
    // has it again by the time the fetch asks for it, so only the check
    // after the fetch can refuse the save.
    const hidden = try fixture.path("hidden");
    try std.Io.Dir.renameAbsolute(object.?, hidden, io);
    try std.testing.expectError(error.ImageStoreNotFound, monitor.fetcher.fetchObject(digest, try allocator.alloc(u8, len), &.{}));
    try std.Io.Dir.renameAbsolute(hidden, object.?, io);
    waiting = false;
    fill_mutex.unlock(io);
    thread.join();

    try std.testing.expect(monitor.fetcher.complete.load(.acquire));
    try std.testing.expectEqualStrings(save_refused_image_store ++ ": a guest read from it failed earlier", (save.refusal orelse return error.TestExpectedRefusal).message);
    try std.testing.expectEqual(Op.idle, monitor.server.op);
}

test "stopping the control plane cancels a save's pending image fetch" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture: image_store_mod.TestImage = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const store = try fixture.path("store");
    _ = try fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/1", .{store}));
    const cache = try fixture.path("cache");
    const local = try image_store_mod.resolve(io, allocator, cache, try std.fmt.allocPrint(allocator, "file://{s}/1", .{store}), .{}, &fixture.env);
    const fetcher = try image_store_mod.Fetcher.create(std.testing.allocator, io, cache, local.origin.?, local.storage, &fixture.env);
    defer fetcher.release();

    var path_buf: [64]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&path_buf, "/tmp/sporevm-test-fetch-stop-{d}.sock", .{std.c.getpid()});
    var entry_dir = std.testing.tmpDir(.{});
    defer entry_dir.cleanup();
    var server = try ExecServer.init(std.testing.allocator, io, .{ .dir = entry_dir.dir }, "/nonexistent", "/nonexistent", socket_path, "/nonexistent", 10700, 1_000, null, .{});
    defer server.disk_claims.deinit();
    server.control().attachImageStore(fetcher);
    defer server.image_store.?.release();
    const accept_thread = try std.Thread.spawn(.{}, controlThreadMain, .{&server});
    var stopped = false;
    defer if (!stopped) server.stopControl(accept_thread, "test finished");

    // A handler's save waits to start its fetch.
    const fill_mutex = &fetcher.fill_mutex;
    try std.testing.expect(fill_mutex.tryLock());
    var client: StoreSaveClient = try .init();
    defer client.deinit();
    var refusal_buf: [256]u8 = undefined;
    const Save = struct {
        refusal: ?monitor_protocol.Error = null,
        fn run(save: *@This(), exec_server: *ExecServer, fd: std.c.fd_t, buf: []u8) void {
            save.refusal = exec_server.imageStoreRefusal(fd, buf);
        }
    };
    var save: Save = .{};
    const thread = std.Thread.spawn(.{}, Save.run, .{ &save, &server, client.monitor_end, &refusal_buf }) catch |err| {
        fill_mutex.unlock(io);
        return err;
    };
    var waiting = true;
    errdefer if (waiting) {
        fill_mutex.unlock(io);
        thread.join();
    };
    while (fill_mutex.state.load(.monotonic) != .contended) try std.Io.sleep(io, .fromMilliseconds(1), .awake);

    // The VM loop has returned; stopping the control plane cancels the
    // fetch, which then downloads nothing. (That stopControl cancels before
    // it joins the handlers is not checked here: this save is not on one.)
    stopped = true;
    server.stopControl(accept_thread, "monitor stopped");
    waiting = false;
    fill_mutex.unlock(io);
    thread.join();
    try std.testing.expectEqualStrings("monitor stopped", (save.refusal orelse return error.TestExpectedRefusal).message);
    try std.testing.expectEqual(@as(u64, 0), fetcher.currentStats().fetches);
}

/// Test support: an ExecServer whose root disk runs a store image.
const StoreMonitor = struct {
    server: ExecServer,
    fetcher: *image_store_mod.Fetcher,
    storage: spore.RootfsStorage,

    fn init(self: *StoreMonitor, cache: []const u8, image_ref: []const u8, arena: std.mem.Allocator, env: *const std.process.Environ.Map) !void {
        const local = try image_store_mod.resolve(std.testing.io, arena, cache, image_ref, .{}, env);
        self.storage = local.storage;
        self.fetcher = try image_store_mod.Fetcher.create(std.testing.allocator, std.testing.io, cache, local.origin.?, local.storage, env);
        self.server = undefined;
        self.server.io = std.testing.io;
        self.server.mutex = .init;
        self.server.op = .idle;
        self.server.stopping = null;
        self.server.image_store = null;
        // The run loop hands over the fetcher of the disk it opened.
        self.server.control().attachImageStore(self.fetcher);
    }

    fn deinit(self: *StoreMonitor) void {
        self.server.image_store.?.release();
        self.fetcher.release();
    }
};

/// Test support: both ends of a control connection.
const StoreSaveClient = struct {
    monitor_end: std.c.fd_t,
    client_end: std.c.fd_t,

    fn init() !StoreSaveClient {
        var fds: [2]std.c.fd_t = undefined;
        if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
        return .{ .monitor_end = fds[0], .client_end = fds[1] };
    }

    fn hangUp(self: *StoreSaveClient) void {
        _ = std.c.close(self.client_end);
        self.client_end = -1;
    }

    fn deinit(self: *StoreSaveClient) void {
        _ = std.c.close(self.monitor_end);
        if (self.client_end >= 0) _ = std.c.close(self.client_end);
    }
};

test "a streaming input wake finishes before the run replaces its wake" {
    const Run = struct {
        started: std.atomic.Value(bool) = .init(false),
        retired: std.atomic.Value(bool) = .init(false),
        woken_after_retire: std.atomic.Value(bool) = .init(false),

        fn wake(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.started.store(true, .release);
            // Leave the run time to retire the wake while this call is in
            // flight.
            const ts = std.c.timespec{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
            if (self.retired.load(.acquire)) self.woken_after_retire.store(true, .release);
        }

        fn ignore(_: *anyopaque) void {}

        fn resize(server: *ExecServer, result: *?anyerror) void {
            server.enqueueStreamingResize(.{ .rows = 24, .cols = 80 }) catch |err| {
                result.* = err;
            };
        }
    };

    var server: ExecServer = undefined;
    server.io = std.testing.io;
    server.mutex = .init;
    server.op = .{ .exec = .{
        .phase = .active,
        .request = "{}\n",
        .session_sequence = 1,
        .submitted_ms = 0,
        .output = .{ .streamed = .{ .client_fd = -1, .timing = false } },
    } };
    server.active_stream = try vsock_stream.HostStream.init(10700, "{}\n");
    var target: Run = .{};
    server.wake = .{ .context = &target, .wakeFn = Run.wake };

    var result: ?anyerror = null;
    const thread = try std.Thread.spawn(.{}, Run.resize, .{ &server, &result });
    while (!target.started.load(.acquire)) std.Thread.yield() catch {};
    // A finished run replaces its wake before its frame goes away.
    server.setWake(.{ .context = &target, .wakeFn = Run.ignore });
    target.retired.store(true, .release);
    thread.join();

    try std.testing.expectEqual(@as(?anyerror, null), result);
    try std.testing.expect(!target.woken_after_retire.load(.acquire));
}

/// A local control client with read deadlines, so a monitor that blocks
/// fails the test instead of hanging it.
fn expectErrorResponse(message: []const u8, line: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response = try monitor_protocol.decodeResponse(arena.allocator(), line);
    try std.testing.expectEqualStrings(message, response.err.message);
}

const TestControlClient = struct {
    stream: net.Stream,
    fd: std.c.fd_t,

    fn connect(socket_path: []const u8) !TestControlClient {
        const address = try net.UnixAddress.init(socket_path);
        const stream = try address.connect(std.testing.io);
        return .{ .stream = stream, .fd = stream.socket.handle };
    }

    fn close(self: TestControlClient) void {
        self.stream.close(std.testing.io);
    }

    fn send(self: TestControlClient, line: []const u8) !void {
        if (writeFdAll(self.fd, line) != 0) return error.IoFailed;
    }

    fn readExact(self: TestControlClient, buffer: []u8, timeout_ms: i32) !void {
        var len: usize = 0;
        while (len < buffer.len) {
            var fds = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.c.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&fds, timeout_ms) == 0) return error.Timeout;
            const n = std.c.read(self.fd, buffer[len..].ptr, buffer.len - len);
            if (n <= 0) return error.ControlStreamClosed;
            len += @intCast(n);
        }
    }

    fn readLine(self: TestControlClient, buffer: []u8, timeout_ms: i32) ![]const u8 {
        for (0..buffer.len) |len| {
            try self.readExact(buffer[len..][0..1], timeout_ms);
            if (buffer[len] == '\n') return buffer[0..len];
        }
        return error.ControlRequestTooLarge;
    }

    fn call(socket_path: []const u8, line: []const u8, buffer: []u8, timeout_ms: i32) ![]const u8 {
        const client = try connect(socket_path);
        defer client.close();
        try client.send(line);
        return client.readLine(buffer, timeout_ms);
    }
};

test "monitor records the fork baseline while it holds the guest" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const runtime_root = try std.fs.path.join(allocator, &.{ root, "runtime" });
    defer allocator.free(runtime_root);
    const saved_dir = try std.fs.path.join(allocator, &.{ root, "saved.spore" });
    defer allocator.free(saved_dir);
    const paths = try lifecycle.pathsFromRoot(allocator, runtime_root, "source");
    defer paths.deinit(allocator);
    try vm_registry.ensureDirPath(io, paths.vm_dir);
    var entry = try vm_registry.Entry.open(io, paths);
    defer entry.close(io);

    // The capture the test hands back in place of the VM loop.
    var batch = runtime_disk_fork_capture.Batch{
        .allocator = allocator,
        .heads = try allocator.alloc(?runtime_disk_fork.Head, 1),
        .pause_started_ns = monotonicNs(),
        .ram_capture_ns = 1,
        .prepare_ns = 2,
        .copied_bytes = 0,
    };
    batch.heads[0] = null;
    defer batch.deinit();
    batch.heads[0] = try runtime_disk_claim.makeSmokeHead(allocator);
    batch.heads[0].?.descriptor.baseline.kind = .disk_index;
    const digest = batch.heads[0].?.descriptor.baseline.identity;

    // A source restored from a saved disk has no recorded baseline yet.
    try entry.writeSpec(allocator, io, .{
        .name = "source",
        .rootfs = .{ .device = .{ .mmio_slot = 1 }, .artifact = .{ .digest = digest, .size = spore.disk_chunk_size } },
        .disk = .{ .device = .{ .mmio_slot = 1 }, .size = spore.disk_chunk_size, .base = digest },
        .resume_dir = saved_dir,
    });
    var path_buf: [64]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&path_buf, "/tmp/sporevm-test-fork-{d}.sock", .{std.c.getpid()});
    var server = try ExecServer.init(allocator, io, entry, paths.vm_dir, runtime_root, socket_path, "/nonexistent", 10700, 5_000, null, .{});
    defer server.disk_claims.deinit();
    defer {
        server.server.deinit(io);
        Io.Dir.cwd().deleteFile(io, socket_path) catch {};
    }

    const Prepare = struct {
        server: *ExecServer,
        response: ?[]const u8 = null,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.response = self.server.submitDiskFork(.{
                .type = runtime_disk_fork_control.prepare_type,
                .schema = runtime_disk_fork_control.prepare_schema,
                .out_dir = "/tmp/capture",
                .batch = "batch-1",
                .children = &.{"child-0"},
            }) catch |err| {
                self.err = err;
                return;
            };
        }
    };
    var prepare = Prepare{ .server = &server };
    const thread = try std.Thread.spawn(.{}, Prepare.run, .{&prepare});
    var joined = false;
    defer if (!joined) {
        server.failDiskFork(error.TestFailed);
        thread.join();
        if (prepare.response) |response| std.heap.page_allocator.free(response);
    };

    // The baseline is in the spec, where GC finds it, before the capture
    // starts.
    const started_ms = lifecycle.monotonicMs();
    while (true) {
        {
            server.mutex.lockUncancelable(io);
            defer server.mutex.unlock(io);
            if (server.op == .disk_fork and server.op.disk_fork.phase == .pending) {
                server.op.disk_fork.phase = .active;
                break;
            }
        }
        if (prepare.err) |err| return err;
        if (lifecycle.monotonicMs() - started_ms > 5_000) return error.Timeout;
        var ts = std.c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    var recorded = try entry.readSpec(allocator, io);
    defer recorded.deinit();
    const lease = recorded.value.disk_baseline_lease.?;
    try std.testing.expectEqual(runtime_disk_lease.Store.saved_spore, lease.store);
    try std.testing.expectEqualStrings(saved_dir, lease.root);
    try std.testing.expectEqualStrings(digest, lease.baseline_identity);

    // The fork CLI gets the same baseline and disk in the response.
    try server.completeDiskFork(&batch);
    thread.join();
    joined = true;
    if (prepare.err) |err| return err;
    const response = prepare.response.?;
    defer std.heap.page_allocator.free(response);
    var prepared_arena = std.heap.ArenaAllocator.init(allocator);
    defer prepared_arena.deinit();
    const prepared = (try monitor_protocol.decodeResponse(prepared_arena.allocator(), response)).disk_fork_prepared;
    try std.testing.expectEqualStrings(saved_dir, prepared.lease.root);
    try std.testing.expectEqualStrings(lease.baseline_identity, prepared.lease.baseline_identity);
    try std.testing.expectEqualStrings(lease.baseline_identity, prepared.disk.?.base);
    try std.testing.expectEqual(Op.idle, server.op);
}

test "a fork waiting for the rootfs cache lock leaves the guest free" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const runtime_root = try std.fs.path.join(arena, &.{ root, "runtime" });
    const cache_root = try std.fs.path.join(arena, &.{ root, "cache" });
    const image = try manifest_test_support.diskFixture(arena, io, cache_root, try std.fs.path.join(arena, &.{ root, "image.spore" }), 0x75, false);
    try rootfs_cas.markStorageComplete(io, arena, cache_root, image.storage.index_digest);
    const paths = try lifecycle.pathsFromRoot(arena, runtime_root, "source");
    try vm_registry.ensureDirPath(io, paths.vm_dir);
    var entry = try vm_registry.Entry.open(io, paths);
    defer entry.close(io);
    // A VM created from an image, whose baseline is the image's cached index.
    try entry.writeSpec(arena, io, .{
        .name = "source",
        .rootfs = .{
            .device = .{ .mmio_slot = 1 },
            .artifact = .{ .digest = image.storage.index_digest, .size = image.storage.logical_size },
            .storage = image.storage,
        },
    });

    // The capture the test hands back in place of the VM loop.
    var batch = runtime_disk_fork_capture.Batch{
        .allocator = allocator,
        .heads = try allocator.alloc(?runtime_disk_fork.Head, 1),
        .pause_started_ns = monotonicNs(),
        .ram_capture_ns = 1,
        .prepare_ns = 2,
        .copied_bytes = 0,
    };
    batch.heads[0] = null;
    defer batch.deinit();
    batch.heads[0] = try runtime_disk_claim.makeSmokeHead(allocator);
    const identity = try allocator.dupe(u8, image.storage.index_digest);
    allocator.free(batch.heads[0].?.descriptor.baseline.identity);
    batch.heads[0].?.descriptor.baseline = .{ .kind = .disk_index, .identity = identity };

    var path_buf: [64]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&path_buf, "/tmp/sporevm-test-fork-wait-{d}.sock", .{std.c.getpid()});
    // A guest operation gives up on a held slot after this long.
    const timeout_ms = 300;
    var server = try ExecServer.init(allocator, io, entry, paths.vm_dir, runtime_root, socket_path, cache_root, 10700, timeout_ms, null, .{});
    defer server.disk_claims.deinit();
    defer {
        server.server.deinit(io);
        Io.Dir.cwd().deleteFile(io, socket_path) catch {};
    }

    // A build holds the cache lock while the fork starts.
    var build_lock: ?rootfs_mod.RootfsCacheLock = try rootfs_mod.lockRootfsCacheExclusive(io, arena, cache_root);
    defer if (build_lock) |*lock| lock.deinit();
    const waits_before = testing.disk_fork_cache_waits.load(.monotonic);
    const Prepare = struct {
        server: *ExecServer,
        response: ?[]const u8 = null,
        err: ?anyerror = null,
        finished: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            defer self.finished.store(true, .release);
            self.response = self.server.submitDiskFork(.{
                .type = runtime_disk_fork_control.prepare_type,
                .schema = runtime_disk_fork_control.prepare_schema,
                .out_dir = "/tmp/capture",
                .batch = "batch-1",
                .children = &.{"child-0"},
            }) catch |err| {
                self.err = err;
                return;
            };
        }
    };
    var prepare = Prepare{ .server = &server };
    const thread = try std.Thread.spawn(.{}, Prepare.run, .{&prepare});
    var joined = false;
    defer if (!joined) {
        if (build_lock) |*lock| lock.deinit();
        build_lock = null;
        while (!prepare.finished.load(.acquire)) {
            server.failDiskFork(error.TestFailed);
            var ts = std.c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
        }
        thread.join();
        if (prepare.response) |response| std.heap.page_allocator.free(response);
    };

    // The fork finds the lock held and waits for it without the guest slot,
    // so a guest operation still gets the slot at once.
    const started_ms = lifecycle.monotonicMs();
    while (testing.disk_fork_cache_waits.load(.monotonic) == waits_before) {
        if (prepare.finished.load(.acquire)) return prepare.err orelse error.TestUnexpectedResult;
        if (lifecycle.monotonicMs() - started_ms > 5_000) return error.Timeout;
        var ts = std.c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    {
        server.mutex.lockUncancelable(io);
        defer server.mutex.unlock(io);
        try server.acquireOpLocked();
    }

    // Once the build finishes, the fork records the baseline and goes on.
    build_lock.?.deinit();
    build_lock = null;
    while (true) {
        {
            server.mutex.lockUncancelable(io);
            defer server.mutex.unlock(io);
            if (server.op == .disk_fork and server.op.disk_fork.phase == .pending) {
                server.op.disk_fork.phase = .active;
                break;
            }
        }
        if (prepare.finished.load(.acquire)) return prepare.err orelse error.TestUnexpectedResult;
        if (lifecycle.monotonicMs() - started_ms > 10_000) return error.Timeout;
        var ts = std.c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    var recorded = try entry.readSpec(allocator, io);
    defer recorded.deinit();
    try std.testing.expectEqual(runtime_disk_lease.Store.rootfs_cache, recorded.value.disk_baseline_lease.?.store);
    try std.testing.expectEqualStrings(image.storage.index_digest, recorded.value.disk_baseline_lease.?.baseline_identity);
    try server.completeDiskFork(&batch);
    thread.join();
    joined = true;
    if (prepare.err) |err| return err;
    const response = prepare.response.?;
    defer std.heap.page_allocator.free(response);
    var prepared_arena = std.heap.ArenaAllocator.init(allocator);
    defer prepared_arena.deinit();
    const prepared = (try monitor_protocol.decodeResponse(prepared_arena.allocator(), response)).disk_fork_prepared;
    try std.testing.expectEqualStrings(cache_root, prepared.lease.root);
    try std.testing.expect(prepared.disk == null);
}

test "monitor answers hello and shutdown while a guest operation runs" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var path_buf: [64]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&path_buf, "/tmp/sporevm-test-control-{d}.sock", .{std.c.getpid()});
    // Guest operations queue for at most the VM timeout.
    const timeout_ms = 300;
    var entry_dir = std.testing.tmpDir(.{});
    defer entry_dir.cleanup();
    var server = try ExecServer.init(allocator, io, .{ .dir = entry_dir.dir }, "/nonexistent", "/nonexistent", socket_path, "/nonexistent", 10700, timeout_ms, null, .{});
    defer server.disk_claims.deinit();
    const accept_thread = try std.Thread.spawn(.{}, controlThreadMain, .{&server});
    var stopped = false;
    defer if (!stopped) server.stopControl(accept_thread, "test finished");

    // A streaming exec takes the guest. The test plays the VM loop, which
    // starts the exec and never finishes it.
    const exec = try TestControlClient.connect(socket_path);
    defer exec.close();
    try exec.send("{\"type\":\"exec-stream-v1\",\"argv\":[\"/bin/sleep\",\"300\"],\"stdio\":\"pipe\"}\n");
    const started_ms = lifecycle.monotonicMs();
    while (true) {
        {
            server.mutex.lockUncancelable(io);
            defer server.mutex.unlock(io);
            if (server.op == .exec and server.op.exec.phase == .pending) {
                server.op.exec.phase = .active;
                server.cond.broadcast(io);
                break;
            }
        }
        if (lifecycle.monotonicMs() - started_ms > 5_000) return error.Timeout;
        var ts = std.c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }

    var buffer: [512]u8 = undefined;
    const hello = try TestControlClient.call(socket_path, "{\"type\":\"hello\"}\n", &buffer, 1_000);
    try std.testing.expect(std.mem.startsWith(u8, hello, "{\"type\":\"hello\""));

    // Another guest operation waits for the running one, then gives up.
    const queued_ms = lifecycle.monotonicMs();
    const busy = try TestControlClient.call(socket_path, "{\"type\":\"start\",\"argv\":[\"/bin/true\"]}\n", &buffer, 5_000);
    try expectErrorResponse("monitor busy", busy);
    try std.testing.expect(lifecycle.monotonicMs() - queued_ms >= timeout_ms);

    const ok = try TestControlClient.call(socket_path, "{\"type\":\"shutdown\"}\n", &buffer, 1_000);
    try std.testing.expectEqualStrings("{\"type\":\"ok\"}", ok);

    // The running exec fails with the removal message.
    var header_buf: [spore_stream.header_len]u8 = undefined;
    try exec.readExact(&header_buf, 1_000);
    const header = try spore_stream.readHeader(&header_buf);
    try std.testing.expectEqual(spore_stream.FrameType.err, header.frame_type);
    const message = buffer[0..header.payload_len];
    try exec.readExact(message, 1_000);
    try std.testing.expectEqualStrings(removal_message, message);

    // New guest operations are refused once the monitor is stopping.
    const refused = try TestControlClient.call(socket_path, "{\"type\":\"start\",\"argv\":[\"/bin/true\"]}\n", &buffer, 1_000);
    try expectErrorResponse(removal_message, refused);

    stopped = true;
    server.stopControl(accept_thread, "test finished");
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, socket_path, .{}));
}

test "shutdown fails an exec still waiting for the guest and refuses the rest" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var path_buf: [64]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&path_buf, "/tmp/sporevm-test-pending-{d}.sock", .{std.c.getpid()});
    var entry_dir = std.testing.tmpDir(.{});
    defer entry_dir.cleanup();
    var server = try ExecServer.init(allocator, io, .{ .dir = entry_dir.dir }, "/nonexistent", "/nonexistent", socket_path, "/nonexistent", 10700, 1_000, null, .{});
    defer server.disk_claims.deinit();
    const accept_thread = try std.Thread.spawn(.{}, controlThreadMain, .{&server});
    defer server.stopControl(accept_thread, "test finished");

    // No VM loop runs, so the exec takes the slot and never reaches the guest.
    const exec = try TestControlClient.connect(socket_path);
    defer exec.close();
    try exec.send("{\"type\":\"start\",\"argv\":[\"/bin/true\"]}\n");
    const started_ms = lifecycle.monotonicMs();
    while (true) {
        {
            server.mutex.lockUncancelable(io);
            defer server.mutex.unlock(io);
            if (server.op == .exec) break;
        }
        if (lifecycle.monotonicMs() - started_ms > 5_000) return error.Timeout;
        var ts = std.c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }

    var buffer: [512]u8 = undefined;
    const ok = try TestControlClient.call(socket_path, "{\"type\":\"shutdown\"}\n", &buffer, 1_000);
    try std.testing.expect(std.mem.startsWith(u8, ok, "{\"type\":\"ok\""));
    try expectErrorResponse(removal_message, try exec.readLine(&buffer, 1_000));
    const refused = try TestControlClient.call(socket_path, "{\"type\":\"suspend\",\"out_dir\":\"/tmp/save.spore\"}\n", &buffer, 1_000);
    try expectErrorResponse(if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) capture_unavailable_x86 else removal_message, refused);
}

test "monitor refuses a request with an unknown field before it takes the guest" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var path_buf: [64]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&path_buf, "/tmp/sporevm-test-strict-{d}.sock", .{std.c.getpid()});
    var entry_dir = std.testing.tmpDir(.{});
    defer entry_dir.cleanup();
    var server = try ExecServer.init(allocator, io, .{ .dir = entry_dir.dir }, "/nonexistent", "/nonexistent", socket_path, "/nonexistent", 10700, 1_000, null, .{});
    defer server.disk_claims.deinit();
    const accept_thread = try std.Thread.spawn(.{}, controlThreadMain, .{&server});
    defer server.stopControl(accept_thread, "test finished");

    var buffer: [512]u8 = undefined;
    const refused = try TestControlClient.call(socket_path, "{\"type\":\"start\",\"argv\":[\"/bin/true\"],\"retain\":true}\n", &buffer, 1_000);
    try expectErrorResponse("bad control request", refused);
    server.mutex.lockUncancelable(io);
    defer server.mutex.unlock(io);
    try std.testing.expectEqual(Op.idle, server.op);
}

test "monitor gives a slow client one deadline for its whole request line" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var path_buf: [64]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&path_buf, "/tmp/sporevm-test-trickle-{d}.sock", .{std.c.getpid()});
    var entry_dir = std.testing.tmpDir(.{});
    defer entry_dir.cleanup();
    var server = try ExecServer.init(allocator, io, .{ .dir = entry_dir.dir }, "/nonexistent", "/nonexistent", socket_path, "/nonexistent", 10700, 1_000, null, .{});
    defer server.disk_claims.deinit();
    const accept_thread = try std.Thread.spawn(.{}, controlThreadMain, .{&server});
    defer server.stopControl(accept_thread, "test finished");

    // The client sends one byte of its request line every 200 ms, so each
    // read is quick but the line would take seconds.
    const Trickler = struct {
        fn run(fd: std.c.fd_t) void {
            for (0..25) |_| {
                if (std.c.send(fd, "{", 1, std.c.MSG.NOSIGNAL) != 1) return;
                var ts = std.c.timespec{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
                _ = std.c.nanosleep(&ts, null);
            }
        }
    };
    const slow = try TestControlClient.connect(socket_path);
    defer slow.close();
    const trickler = try std.Thread.spawn(.{}, Trickler.run, .{slow.fd});
    defer trickler.join();
    // Let the accept thread take the slow client first.
    var ts = std.c.timespec{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);

    const started_ms = lifecycle.monotonicMs();
    var buffer: [512]u8 = undefined;
    const hello = try TestControlClient.call(socket_path, "{\"type\":\"hello\"}\n", &buffer, 3_000);
    try std.testing.expect(std.mem.startsWith(u8, hello, "{\"type\":\"hello\""));
    try std.testing.expect(lifecycle.monotonicMs() - started_ms < 2 * control_request_timeout_ms);

    const refused = try slow.readLine(&buffer, 1_000);
    try expectErrorResponse("bad control request", refused);
}
