//! Runs one VM. This is the code that turns a resolved backend and a
//! description of the VM into a running guest: the x86 profile check, the
//! root disk, the kernel command line, the `vmm.Config`, the backend call and
//! the network check after it. Callers own what surrounds the VM: the network
//! gateway, the RAM restore plan and the events they report.

const std = @import("std");
const TestDir = @import("test_dir.zig").TestDir;
const builtin = @import("builtin");

const Backend = @import("backend.zig").Backend;
const capture = @import("capture.zig");
const Context = @import("context.zig").Context;
const deadline = @import("deadline.zig");
const hvf_binding = @import("hvf/hvf.zig");
const kvm_binding = @import("kvm/native.zig").binding;
const memory_config = @import("memory.zig");
const runtime_disk = @import("runtime_disk.zig");
const spore = @import("spore.zig");
const spore_net_policy = @import("spore_net_policy.zig");
const topology = @import("topology.zig");
const virtio_blk = @import("virtio/blk.zig");
const virtio_net = @import("virtio/net.zig");
const vmm = @import("aarch64/vmm.zig");
const vsock_control = @import("virtio/vsock_control.zig");
const vsock_stream = @import("virtio/vsock_stream.zig");
const x86_board = @import("x86_64/board.zig");
const x86_vm = if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64)
    @import("x86_64/vm.zig")
else
    struct {};

const rootfs_growth_experiments_env = "SPOREVM_ROOTFS_GROWTH_EXPERIMENTS";
const force_write_zeroes_unsupported_experiment_env = "SPOREVM_WRITE_ZEROES_FORCE_UNSUPPORTED_EXPERIMENT";
const force_write_zeroes_backend_failure_experiment_env = "SPOREVM_WRITE_ZEROES_FORCE_BACKEND_FAILURE_EXPERIMENT";
const lazy_init_negative_control_experiment_env = "SPOREVM_ROOTFS_LAZY_INIT_NEGATIVE_CONTROL";
pub const x86_experimental_memory_bytes: u64 = 512 * 1024 * 1024;

pub const Session = struct {
    /// Resolved by the caller; `.auto` is rejected.
    backend: Backend,
    machine: Machine,
    /// On restore, 1 means "use the manifest's count".
    vcpus: topology.VcpuCount = 1,
    disks: runtime_disk.Options = .{},
    network: Network = .{},
    record: Record = .{},
    console_sink: *const fn ([]const u8) void,
    mode: Mode,
};

pub const Machine = union(enum) {
    boot: Boot,
    /// The caller owns the RAM plan behind `ram`: results report its source
    /// and reason.
    restore: vmm.Start.Restore,

    pub const Boot = struct {
        kernel: []const u8,
        initrd: ?[]const u8,
        memory: memory_config.Config,
        /// The guest agent's vsock port.
        guest_port: u32,
        /// Whether a console log is open. The guest agent then copies
        /// command output to the console too.
        console_mirror: bool = false,
    };
};

pub const Network = struct {
    runtime: virtio_net.Runtime = .{},
    /// The network a capture records; null when the guest has none.
    manifest: ?spore.Network = null,
};

/// What a capture records besides the machine.
pub const Record = struct {
    annotations: spore.Annotations = .{},
    sessions: []const spore.Session = &.{},
};

pub const Mode = union(enum) {
    /// A command whose completion or capture ends the VM: `spore run`,
    /// `run --from` and `attach`.
    oneshot: struct {
        probe: vmm.Probe,
        capture: ?capture.Capture = null,
        control: ?vsock_control.Control = null,
    },
};

/// Runs the session's VM until it exits. A failed network gateway fails the
/// run whatever the exit.
pub fn run(context: Context, allocator: std.mem.Allocator, session: Session) !vmm.ExitCause {
    return runOn(Native, context, allocator, session);
}

/// The VM backends this build can run: `hvf` and `kvm` take a `vmm.Config`;
/// `x86` takes the x86 board's config.
const Native = if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)
    struct {
        pub const hvf = hvf_binding.vm.run;
    }
else if (builtin.os.tag == .linux and builtin.cpu.arch == .aarch64)
    struct {
        pub const kvm = kvm_binding.vm.run;
    }
else if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64)
    struct {
        pub const x86 = x86_vm.run;
    }
else
    struct {};

fn runOn(comptime Vms: type, context: Context, allocator: std.mem.Allocator, session: Session) !vmm.ExitCause {
    const supported = switch (session.backend) {
        .auto => false,
        .hvf => @hasDecl(Vms, "hvf"),
        .kvm => @hasDecl(Vms, "kvm") or @hasDecl(Vms, "x86"),
    };
    if (!supported) return error.UnsupportedBackend;
    // Callers check the profile before they pull images or start gateways;
    // this is the backstop.
    if (@hasDecl(Vms, "x86")) try validateFreshProductPolicyFor(.x86_64, session.backend, policy(session));

    var disk = try runtime_disk.open(context, allocator, session.disks);
    defer disk.deinit();
    const growth = session.disks.rootfs_grow_target != 0;
    var root_blk_stats: virtio_blk.Stats = .{};
    defer if (growth) logRootBlkStats(&root_blk_stats);
    const oneshot = session.mode.oneshot;
    const config: vmm.Config = .{
        .io = context.io,
        .start = switch (session.machine) {
            .boot => |boot| .{ .boot = .{
                .kernel = boot.kernel,
                .cmdline = try productBootArgs(allocator, try cmdline(
                    allocator,
                    boot.guest_port,
                    session.disks.hasRootfs(),
                    session.disks.rootfsWritable(),
                    growth,
                    growth and rootfsGrowthNoInitItable(context.environ_map),
                    if (session.network.manifest != null) .spore else .disabled,
                    boot.console_mirror,
                    false,
                    false,
                    0,
                )),
                .initrd = boot.initrd,
                .ram_size = boot.memory.initial_bytes,
                .virtio_mem_region_size = boot.memory.maximum_bytes - boot.memory.initial_bytes,
            } },
            .restore => |restore| .{ .restore = restore },
        },
        .vcpus = session.vcpus,
        .console_sink = session.console_sink,
        .disk_backend = disk.backend(),
        .root_blk_options = rootBlkOptions(context.environ_map, growth, &root_blk_stats),
        .disk_snapshot = disk.snapshot(),
        .rootfs = session.disks.rootfs,
        .network_manifest = session.network.manifest,
        .annotations = session.record.annotations,
        .sessions = session.record.sessions,
        .environ_map = context.environ_map,
        .probe = oneshot.probe,
        .capture = trackedCapture(session),
        .network = session.network.runtime,
        .exec_control = oneshot.control,
    };

    const run_start_ms = deadline.system_clock.nowMs();
    const cause: vmm.ExitCause = switch (session.backend) {
        .auto => unreachable,
        .hvf => if (@hasDecl(Vms, "hvf")) try Vms.hvf(allocator, config) else unreachable,
        .kvm => if (@hasDecl(Vms, "kvm"))
            try Vms.kvm(allocator, config)
        else if (@hasDecl(Vms, "x86"))
            x86Exit(try Vms.x86(allocator, try x86Config(config, session.mode)))
        else
            unreachable,
    };
    const run_ms = deadline.system_clock.nowMs() -| run_start_ms;
    const stream = oneshot.probe.stream;
    const response_ms = stream.response_ms orelse stream.elapsedMs();
    // scripts/benchmark/suite.py reads this line.
    std.log.debug(
        "run backend timing: elapsed_ms={d} stream_response_ms={d} tail_ms={d} cause={s}",
        .{ run_ms, response_ms, run_ms -| response_ms, @tagName(cause) },
    );
    if (session.network.runtime.failed()) return error.NetworkGatewayFailed;
    return cause;
}

fn policy(session: Session) FreshProductPolicy {
    return .{
        .memory = switch (session.machine) {
            .boot => |boot| boot.memory,
            .restore => .{},
        },
        .vcpus = session.vcpus,
        .resuming = session.machine == .restore,
        .capture = session.mode.oneshot.capture != null,
    };
}

/// The capture with dirty tracking only where the backend can track: HVF
/// with one vCPU, and neither backend with elastic memory.
fn trackedCapture(session: Session) ?capture.Capture {
    var value = session.mode.oneshot.capture orelse return null;
    const elastic = switch (session.machine) {
        .boot => |boot| boot.memory.isElastic(),
        .restore => false,
    };
    value.dirty_tracking = value.dirty_tracking and !elastic and (session.backend == .kvm or session.vcpus == 1);
    return value;
}

/// The x86 board boots fresh machines only, without captures.
fn x86Config(config: vmm.Config, mode: Mode) !x86_vm.Config {
    const boot = switch (config.start) {
        .boot => |boot| boot,
        .restore => return error.UnsupportedBackend,
    };
    const probe, const watchdog_until_control = switch (mode) {
        // A detached one-shot probe (`run --commit`) leaves the end of the
        // run to its control, so the watchdog stays armed until the control
        // finishes.
        .oneshot => |oneshot| .{ oneshot.probe, oneshot.probe.on_complete == .detach },
    };
    return .{
        .kernel = boot.kernel,
        .initrd = boot.initrd,
        .cmdline = boot.cmdline,
        .ram_size = boot.ram_size,
        .vcpu_count = @intCast(config.vcpus),
        .console_sink = config.console_sink,
        .root_disk = config.disk_backend,
        .root_blk_options = config.root_blk_options,
        .disk_snapshot = config.disk_snapshot,
        .network = config.network,
        .exec_probe = probe.stream,
        .exec_probe_start = probe.start,
        .exec_probe_completes_run = probe.on_complete == .stop,
        .exec_probe_watchdog_until_control = watchdog_until_control,
        .exec_control = config.exec_control,
        .exec_probe_timeout_ms = probe.timeout_ms,
    };
}

fn x86Exit(cause: x86_vm.ExitCause) vmm.ExitCause {
    return switch (cause) {
        .terminal => |terminal| switch (terminal.cause.outcome()) {
            .guest_off => .guest_off,
            .guest_reset => .guest_reset,
        },
        .probe_complete => .probe_complete,
        .monitor_stopped => .monitor_stopped,
        .snapshotted => .snapshotted,
    };
}

pub const FreshProductPolicy = struct {
    memory: memory_config.Config,
    vcpus: topology.VcpuCount,
    resuming: bool = false,
    capture: bool = false,
    disk_fork: bool = false,
};

/// The experimental x86 product profile remains fixed-memory, single-vCPU,
/// and fresh-only. Keep this pure so API and lifecycle callers can reject
/// unsupported work before downloads, rootfs resolution, gateway startup, or
/// monitor state creation.
pub fn validateFreshProductPolicy(selected_backend: Backend, fresh_policy: FreshProductPolicy) !void {
    if (comptime builtin.os.tag != .linux) return;
    return validateFreshProductPolicyFor(builtin.cpu.arch, selected_backend, fresh_policy);
}

fn validateFreshProductPolicyFor(zig_arch: std.Target.Cpu.Arch, selected_backend: Backend, fresh_policy: FreshProductPolicy) !void {
    if (zig_arch != .x86_64) return;
    if (selected_backend != .kvm) return error.UnsupportedBackend;
    if (fresh_policy.resuming) return error.X86ResumeUnsupported;
    if (fresh_policy.capture) return error.X86CaptureUnsupported;
    if (fresh_policy.disk_fork) return error.X86DiskForkUnsupported;
    if (fresh_policy.memory.isElastic()) return error.X86ElasticMemoryUnsupported;
    if (fresh_policy.memory.initial_bytes != x86_experimental_memory_bytes) return error.X86ExperimentalMemorySizeUnsupported;
    if (fresh_policy.vcpus != 1) return error.X86VcpuCountUnsupported;
}

pub fn rootBlkOptions(environ: *const std.process.Environ.Map, growth_session: bool, stats: *virtio_blk.Stats) virtio_blk.Options {
    if (!growth_session) return .{};
    const experiments_enabled = rootfsGrowthExperimentsEnabled(environ);
    return .{
        .write_zeroes = true,
        .force_write_zeroes_unsupported = experiments_enabled and internalExperimentEnabled(environ.get(force_write_zeroes_unsupported_experiment_env)),
        .force_write_zeroes_backend_failure = experiments_enabled and internalExperimentEnabled(environ.get(force_write_zeroes_backend_failure_experiment_env)),
        .stats = stats,
    };
}

fn rootfsGrowthExperimentsEnabled(environ: *const std.process.Environ.Map) bool {
    return if (environ.get(rootfs_growth_experiments_env)) |value|
        std.mem.eql(u8, value, "1")
    else
        false;
}

fn internalExperimentEnabled(value: ?[]const u8) bool {
    const raw = value orelse return false;
    if (raw.len == 0 or std.mem.eql(u8, raw, "0")) return false;
    return !std.ascii.eqlIgnoreCase(raw, "false");
}

pub fn rootfsGrowthNoInitItable(environ: *const std.process.Environ.Map) bool {
    return !rootfsGrowthExperimentsEnabled(environ) or
        !internalExperimentEnabled(environ.get(lazy_init_negative_control_experiment_env));
}

pub fn logRootBlkStats(stats: *const virtio_blk.Stats) void {
    const snapshot = stats.snapshot();
    std.log.info(
        "rootfs growth blk metrics: accepted_features=0x{x} write_zeroes_requests={d} write_zeroes_bytes={d} write_zeroes_unmap={d} write_zeroes_ok={d} write_zeroes_errors={d} write_zeroes_backend_failures={d} write_zeroes_unsupported={d} out_requests={d} out_bytes={d} out_all_zero_requests={d} out_all_zero_bytes={d}",
        .{
            snapshot.accepted_features,
            snapshot.write_zeroes_requests,
            snapshot.write_zeroes_bytes,
            snapshot.write_zeroes_unmap_requests,
            snapshot.write_zeroes_ok,
            snapshot.write_zeroes_errors,
            snapshot.write_zeroes_backend_failures,
            snapshot.write_zeroes_unsupported,
            snapshot.out_requests,
            snapshot.out_bytes,
            snapshot.out_all_zero_requests,
            snapshot.out_all_zero_bytes,
        },
    );
}

pub fn cmdline(allocator: std.mem.Allocator, guest_port: u32, rootfs: bool, rootfs_writable: bool, rootfs_growth: bool, noinit_itable: bool, network: spore_net_policy.NetworkMode, console_mirror: bool, build_context: bool, build_mode: bool, build_input_count: usize) ![]const u8 {
    const rootfs_flag = if (rootfs) " spore_rootfs=1" else "";
    const rootfs_rw_flag = if (rootfs and rootfs_writable) " spore_rootfs_rw=1" else "";
    const rootfs_growth_flag = if (rootfs and rootfs_writable and rootfs_growth) " spore_rootfs_growth=1" else "";
    const noinit_itable_flag = if (rootfs and rootfs_writable and rootfs_growth and noinit_itable) " spore_rootfs_noinit_itable=1" else "";
    const network_flag = if (network == .spore) " spore_net=1" else "";
    // The agent copies command output to the console only when something
    // logs it: each console write is a synchronous guest exit.
    const console_mirror_flag = if (console_mirror) " spore_console_mirror=1" else "";
    const build_context_flag = if (build_context) " spore_build_context=1" else "";
    const build_mode_flag = if (build_mode) " spore_build=1" else "";
    const build_inputs_flag = if (build_input_count != 0)
        try std.fmt.allocPrint(allocator, " spore_build_inputs={d}", .{build_input_count})
    else
        null;
    defer if (build_inputs_flag) |flag| allocator.free(flag);
    return std.fmt.allocPrint(
        allocator,
        "console=hvc0 rdinit=/init cleanroom_guest_port={d} cleanroom_guest_boot_timing=1{s}{s}{s}{s}{s}{s}{s}{s}{s}",
        .{ guest_port, rootfs_flag, rootfs_rw_flag, rootfs_growth_flag, noinit_itable_flag, network_flag, console_mirror_flag, build_context_flag, build_mode_flag, build_inputs_flag orelse "" },
    );
}

pub fn productBootArgs(allocator: std.mem.Allocator, base: []const u8) ![]const u8 {
    if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
        var descriptors_buf: [x86_board.max_virtio_command_line_len]u8 = undefined;
        const descriptors = try x86_board.formatVirtioCommandLine(&descriptors_buf);
        return std.fmt.allocPrint(allocator, "{s} {s}", .{ base, descriptors });
    }
    return base;
}

test "x86 fresh product policy is fixed and fail closed" {
    const accepted = FreshProductPolicy{
        .memory = memory_config.Config.fixed(x86_experimental_memory_bytes),
        .vcpus = 1,
    };
    try validateFreshProductPolicyFor(.x86_64, .kvm, accepted);
    try validateFreshProductPolicyFor(.aarch64, .kvm, .{ .memory = .{}, .vcpus = 8, .resuming = true, .capture = true });
    try std.testing.expectError(error.UnsupportedBackend, validateFreshProductPolicyFor(.x86_64, .hvf, accepted));
    try validateFreshProductPolicyFor(.x86_64, .kvm, .{ .memory = .{}, .vcpus = 1 });
    try std.testing.expectError(error.X86ExperimentalMemorySizeUnsupported, validateFreshProductPolicyFor(.x86_64, .kvm, .{
        .memory = memory_config.Config.fixed(1024 * 1024 * 1024),
        .vcpus = 1,
    }));
    try std.testing.expectError(error.X86ElasticMemoryUnsupported, validateFreshProductPolicyFor(.x86_64, .kvm, .{
        .memory = .{ .initial_bytes = 512 * 1024 * 1024, .maximum_bytes = 1024 * 1024 * 1024 },
        .vcpus = 1,
    }));
    try std.testing.expectError(error.X86VcpuCountUnsupported, validateFreshProductPolicyFor(.x86_64, .kvm, .{
        .memory = accepted.memory,
        .vcpus = 2,
    }));
    try std.testing.expectError(error.X86ResumeUnsupported, validateFreshProductPolicyFor(.x86_64, .kvm, .{ .memory = accepted.memory, .vcpus = 1, .resuming = true }));
    try std.testing.expectError(error.X86CaptureUnsupported, validateFreshProductPolicyFor(.x86_64, .kvm, .{ .memory = accepted.memory, .vcpus = 1, .capture = true }));
    try std.testing.expectError(error.X86DiskForkUnsupported, validateFreshProductPolicyFor(.x86_64, .kvm, .{ .memory = accepted.memory, .vcpus = 1, .disk_fork = true }));
}

test "run cmdline marks rootfs mode" {
    const without_rootfs = try cmdline(std.testing.allocator, 10700, false, true, true, true, .disabled, false, false, false, 0);
    defer std.testing.allocator.free(without_rootfs);
    try std.testing.expect(std.mem.indexOf(u8, without_rootfs, "spore_rootfs=1") == null);
    try std.testing.expect(std.mem.indexOf(u8, without_rootfs, "spore_rootfs_rw=1") == null);
    try std.testing.expect(std.mem.indexOf(u8, without_rootfs, "spore_rootfs_growth=1") == null);
    try std.testing.expect(std.mem.indexOf(u8, without_rootfs, "spore_rootfs_noinit_itable=1") == null);

    const with_rootfs = try cmdline(std.testing.allocator, 10700, true, false, true, true, .disabled, false, false, false, 0);
    defer std.testing.allocator.free(with_rootfs);
    try std.testing.expect(std.mem.indexOf(u8, with_rootfs, "spore_rootfs=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_rootfs, "spore_rootfs_rw=1") == null);
    try std.testing.expect(std.mem.indexOf(u8, with_rootfs, "spore_rootfs_growth=1") == null);
    try std.testing.expect(std.mem.indexOf(u8, with_rootfs, "spore_rootfs_noinit_itable=1") == null);

    const with_writable_rootfs = try cmdline(std.testing.allocator, 10700, true, true, false, true, .disabled, false, false, false, 0);
    defer std.testing.allocator.free(with_writable_rootfs);
    try std.testing.expect(std.mem.indexOf(u8, with_writable_rootfs, "spore_rootfs=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_writable_rootfs, "spore_rootfs_rw=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_writable_rootfs, "spore_rootfs_growth=1") == null);

    const with_growth = try cmdline(std.testing.allocator, 10700, true, true, true, true, .disabled, false, false, false, 0);
    defer std.testing.allocator.free(with_growth);
    try std.testing.expect(std.mem.indexOf(u8, with_growth, "spore_rootfs_growth=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_growth, "spore_rootfs_noinit_itable=1") != null);

    const lazy_init_control = try cmdline(std.testing.allocator, 10700, true, true, true, false, .disabled, false, false, false, 0);
    defer std.testing.allocator.free(lazy_init_control);
    try std.testing.expect(std.mem.indexOf(u8, lazy_init_control, "spore_rootfs_growth=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazy_init_control, "spore_rootfs_noinit_itable=1") == null);
}

test "rootfs growth block profile is internal and opt in" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var stats: virtio_blk.Stats = .{};

    const ordinary = rootBlkOptions(&env, false, &stats);
    try std.testing.expect(!ordinary.write_zeroes);
    try std.testing.expect(ordinary.stats == null);

    const growth = rootBlkOptions(&env, true, &stats);
    try std.testing.expect(growth.write_zeroes);
    try std.testing.expect(!growth.force_write_zeroes_unsupported);
    try std.testing.expect(!growth.force_write_zeroes_backend_failure);
    try std.testing.expect(growth.stats == &stats);

    try env.put(force_write_zeroes_unsupported_experiment_env, "1");
    try std.testing.expect(!rootBlkOptions(&env, true, &stats).force_write_zeroes_unsupported);
    try env.put(force_write_zeroes_backend_failure_experiment_env, "1");
    try std.testing.expect(!rootBlkOptions(&env, true, &stats).force_write_zeroes_backend_failure);
    try env.put(lazy_init_negative_control_experiment_env, "1");
    try std.testing.expect(rootfsGrowthNoInitItable(&env));

    try env.put(rootfs_growth_experiments_env, "1");
    try std.testing.expect(rootBlkOptions(&env, true, &stats).force_write_zeroes_unsupported);
    try std.testing.expect(rootBlkOptions(&env, true, &stats).force_write_zeroes_backend_failure);
    try std.testing.expect(!rootfsGrowthNoInitItable(&env));
}

test "run cmdline marks network mode" {
    const without_network = try cmdline(std.testing.allocator, 10700, false, false, false, false, .disabled, false, false, false, 0);
    defer std.testing.allocator.free(without_network);
    try std.testing.expect(std.mem.indexOf(u8, without_network, "spore_net=1") == null);

    const with_network = try cmdline(std.testing.allocator, 10700, false, false, false, false, .spore, false, false, false, 0);
    defer std.testing.allocator.free(with_network);
    try std.testing.expect(std.mem.indexOf(u8, with_network, "spore_net=1") != null);
}

test "run cmdline asks for the console mirror only with a console log" {
    const without_mirror = try cmdline(std.testing.allocator, 10700, false, false, false, false, .disabled, false, false, false, 0);
    defer std.testing.allocator.free(without_mirror);
    try std.testing.expect(std.mem.indexOf(u8, without_mirror, "spore_console_mirror=1") == null);

    const with_mirror = try cmdline(std.testing.allocator, 10700, false, false, false, false, .disabled, true, false, false, 0);
    defer std.testing.allocator.free(with_mirror);
    try std.testing.expect(std.mem.indexOf(u8, with_mirror, "spore_console_mirror=1") != null);
}

test "run cmdline marks build mode and immutable input disks only when requested" {
    const without_context = try cmdline(std.testing.allocator, 10700, true, true, false, false, .disabled, false, false, true, 0);
    defer std.testing.allocator.free(without_context);
    try std.testing.expect(std.mem.indexOf(u8, without_context, "spore_build_context=1") == null);
    try std.testing.expect(std.mem.indexOf(u8, without_context, "spore_build=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, without_context, "spore_build_inputs=") == null);

    const with_context = try cmdline(std.testing.allocator, 10700, true, true, false, false, .disabled, false, true, true, 2);
    defer std.testing.allocator.free(with_context);
    try std.testing.expect(std.mem.indexOf(u8, with_context, "spore_build_context=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_context, "spore_build=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_context, "spore_build_inputs=2") != null);
}

const FakeVm = struct {
    var seen: ?vmm.Config = null;
    var exit: vmm.ExitCause = .probe_complete;

    fn run(_: std.mem.Allocator, config: vmm.Config) !vmm.ExitCause {
        seen = config;
        return exit;
    }

    fn reset(cause: vmm.ExitCause) void {
        seen = null;
        exit = cause;
    }
};

/// Both arm64 backends, whatever the host.
const FakeArm = struct {
    pub const hvf = FakeVm.run;
    pub const kvm = FakeVm.run;
};

fn ignoreConsole(_: []const u8) void {}

const test_boot: Machine = .{ .boot = .{ .kernel = "kernel", .initrd = null, .memory = .{}, .guest_port = 10700 } };

fn testSession(stream: *vsock_stream.HostStream, machine: Machine) Session {
    return .{
        .backend = .kvm,
        .machine = machine,
        .console_sink = ignoreConsole,
        .mode = .{ .oneshot = .{ .probe = .{ .stream = stream } } },
    };
}

test "a fresh boot takes its kernel command line and RAM from the session" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var dir = try TestDir.init();
    defer dir.deinit();
    const rootfs_path = try dir.path("rootfs.ext4");
    const rootfs_bytes: [4096]u8 = @splat(0);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = rootfs_path, .data = &rootfs_bytes });

    var stream = try vsock_stream.HostStream.init(10700, "request\n");
    var session = testSession(&stream, .{ .boot = .{
        .kernel = "kernel",
        .initrd = "initrd",
        .memory = .{ .initial_bytes = 512 * 1024 * 1024, .maximum_bytes = 1024 * 1024 * 1024 },
        .guest_port = 10701,
        .console_mirror = true,
    } });
    session.disks = .{ .rootfs_path = rootfs_path };
    session.network = .{ .manifest = .{} };
    FakeVm.reset(.probe_complete);
    try std.testing.expectEqual(vmm.ExitCause.probe_complete, try runOn(FakeArm, .{ .io = std.testing.io, .environ_map = &env }, arena_state.allocator(), session));

    const config = FakeVm.seen.?;
    const boot = config.start.boot;
    for ([_][]const u8{ "cleanroom_guest_port=10701", "spore_rootfs=1", "spore_net=1", "spore_console_mirror=1" }) |flag| {
        try std.testing.expect(std.mem.indexOf(u8, boot.cmdline, flag) != null);
    }
    // A plain rootfs path has no manifest to seal a writable head into.
    try std.testing.expect(std.mem.indexOf(u8, boot.cmdline, "spore_rootfs_rw=1") == null);
    try std.testing.expect(config.disk_backend != null);
    try std.testing.expectEqualStrings("initrd", boot.initrd.?);
    try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), boot.ram_size);
    try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), boot.virtio_mem_region_size);
}

test "a session runs only the backend it names, and a restore keeps the caller's RAM plan" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const context: Context = .{ .io = std.testing.io, .environ_map = &env };
    var stream = try vsock_stream.HostStream.init(10700, "request\n");

    var session = testSession(&stream, .{ .restore = .{ .dir = "saved.spore", .ram = .eager_chunks } });
    session.backend = .hvf;
    FakeVm.reset(.probe_complete);
    _ = try runOn(FakeArm, context, arena_state.allocator(), session);
    const restore = FakeVm.seen.?.start.restore;
    try std.testing.expectEqualStrings("saved.spore", restore.dir);
    try std.testing.expect(restore.ram == .eager_chunks);

    const KvmOnly = struct {
        pub const kvm = FakeVm.run;
    };
    FakeVm.reset(.probe_complete);
    try std.testing.expectError(error.UnsupportedBackend, runOn(KvmOnly, context, arena_state.allocator(), session));
    session.backend = .auto;
    try std.testing.expectError(error.UnsupportedBackend, runOn(KvmOnly, context, arena_state.allocator(), session));
    try std.testing.expect(FakeVm.seen == null);
}

test "a failed network gateway fails the run whatever the guest did" {
    const FailedGateway = struct {
        fn failed(_: ?*anyopaque) bool {
            return true;
        }
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var stream = try vsock_stream.HostStream.init(10700, "request\n");

    // `spore attach` used to report a completed command as a success here.
    for ([_]vmm.ExitCause{ .probe_complete, .guest_off }) |exit| {
        var session = testSession(&stream, test_boot);
        session.network = .{ .runtime = .{ .failedFn = FailedGateway.failed } };
        FakeVm.reset(exit);
        try std.testing.expectError(error.NetworkGatewayFailed, runOn(FakeArm, .{ .io = std.testing.io, .environ_map = &env }, arena_state.allocator(), session));
    }
}

test "dirty tracking stays off where the backend cannot track it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var stream = try vsock_stream.HostStream.init(10700, "request\n");

    const elastic = memory_config.Config{ .initial_bytes = 512 * 1024 * 1024, .maximum_bytes = 1024 * 1024 * 1024 };
    const Case = struct { backend: Backend, vcpus: topology.VcpuCount, memory: memory_config.Config = .{}, tracked: bool };
    const cases = [_]Case{
        .{ .backend = .hvf, .vcpus = 1, .tracked = true },
        .{ .backend = .hvf, .vcpus = 2, .tracked = false },
        .{ .backend = .kvm, .vcpus = 2, .tracked = true },
        .{ .backend = .kvm, .vcpus = 1, .memory = elastic, .tracked = false },
    };
    for (cases) |case| {
        var session = testSession(&stream, .{ .boot = .{ .kernel = "kernel", .initrd = null, .memory = case.memory, .guest_port = 10700 } });
        session.backend = case.backend;
        session.vcpus = case.vcpus;
        session.mode.oneshot.capture = .{ .dir = "out.spore", .trigger = .probe_complete, .dirty_tracking = true };
        FakeVm.reset(.probe_complete);
        _ = try runOn(FakeArm, .{ .io = std.testing.io, .environ_map = &env }, arena_state.allocator(), session);
        try std.testing.expectEqual(case.tracked, FakeVm.seen.?.capture.?.dirty_tracking);
    }
}

test "x86 boots only, and keeps the probe watchdog armed while a detached probe's control runs" {
    if (comptime !(builtin.os.tag == .linux and builtin.cpu.arch == .x86_64)) return error.SkipZigTest;
    const FakeX86 = struct {
        var seen: ?x86_vm.Config = null;
        var exit: x86_vm.ExitCause = .probe_complete;

        pub fn x86(_: std.mem.Allocator, config: x86_vm.Config) !x86_vm.ExitCause {
            seen = config;
            return exit;
        }
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const context: Context = .{ .io = std.testing.io, .environ_map = &env };
    var stream = try vsock_stream.HostStream.init(10700, "request\n");
    var session = testSession(&stream, .{ .boot = .{
        .kernel = "kernel",
        .initrd = null,
        .memory = memory_config.Config.fixed(x86_experimental_memory_bytes),
        .guest_port = 10700,
    } });

    // `run --commit`: the probe detaches and the commit control ends the run.
    session.mode.oneshot.probe = .{ .stream = &stream, .start = .control, .on_complete = .detach };
    _ = try runOn(FakeX86, context, arena_state.allocator(), session);
    try std.testing.expectEqual(vsock_stream.HostStreamStart.control, FakeX86.seen.?.exec_probe_start);
    try std.testing.expect(!FakeX86.seen.?.exec_probe_completes_run);
    try std.testing.expect(FakeX86.seen.?.exec_probe_watchdog_until_control);

    session.mode.oneshot.probe = .{ .stream = &stream };
    _ = try runOn(FakeX86, context, arena_state.allocator(), session);
    try std.testing.expect(FakeX86.seen.?.exec_probe_completes_run);
    try std.testing.expect(!FakeX86.seen.?.exec_probe_watchdog_until_control);

    FakeX86.exit = .{ .terminal = .{ .vcpu_index = 0, .cause = .{ .system_event_shutdown = .{ .exit_reason = 0 } } } };
    try std.testing.expectEqual(vmm.ExitCause.guest_off, try runOn(FakeX86, context, arena_state.allocator(), session));
    FakeX86.exit = .{ .terminal = .{ .vcpu_index = 0, .cause = .{ .system_event_reset = .{ .exit_reason = 0 } } } };
    try std.testing.expectEqual(vmm.ExitCause.guest_reset, try runOn(FakeX86, context, arena_state.allocator(), session));

    FakeX86.seen = null;
    session.machine = .{ .restore = .{ .dir = "saved.spore", .ram = .eager_chunks } };
    try std.testing.expectError(error.X86ResumeUnsupported, runOn(FakeX86, context, arena_state.allocator(), session));
    try std.testing.expect(FakeX86.seen == null);
}
