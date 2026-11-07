//! One-shot VM boot/exec support for `spore run`.

const std = @import("std");
const TestDir = @import("test_dir.zig").TestDir;
const builtin = @import("builtin");
const Io = std.Io;

const architecture = @import("architecture.zig");
const attach_stream = @import("attach_stream.zig");
const backend_mod = @import("backend.zig");
const boot_assets = @import("boot_assets.zig");
const capture = @import("capture.zig");
const cli_args = @import("cli_args.zig");
const Context = @import("context.zig").Context;
const events_mod = @import("events.zig");
const generation = @import("generation.zig");
const guest_request = @import("guest_request.zig");
const image = @import("image.zig");
const image_store = @import("image_store.zig");
const local_image = @import("local_image.zig");
const local_paths = @import("local_paths.zig");
const machine_output = @import("machine_output.zig");
const memory_config = @import("memory.zig");
const net_gateway = @import("net_gateway.zig");
const ram_restore = @import("ram_restore.zig");
const rootfs_input = @import("rootfs_input.zig");
const rootfs_cache = @import("rootfs_cache.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const rootfs_mod = @import("rootfs.zig");
const saved_spore_ownership = @import("saved_spore_ownership.zig");
const saved_spore_pin = @import("saved_spore_pin.zig");
const runtime_disk_mod = @import("runtime_disk.zig");
const run_contract = @import("build/run_contract.zig");
const spore = @import("spore.zig");
const spore_net_policy = @import("spore_net_policy.zig");
const spore_stream = @import("spore_stream.zig");
const topology = @import("topology.zig");
const vm_session = @import("vm_session.zig");
const virtio_net = @import("virtio/net.zig");
const vsock = @import("virtio/vsock.zig");
const vsock_control = @import("virtio/vsock_control.zig");
const vsock_stream = @import("virtio/vsock_stream.zig");
const test_support = @import("test_support.zig");

const max_guest_port = 65535;

pub const MemoryConfig = memory_config.Config;
pub const SaveTrigger = capture.Trigger;
pub const Rootfs = spore.Rootfs;
pub const Disk = spore.Disk;
const Backend = backend_mod.Backend;

/// One `spore run`: a command in a VM that boots fresh or restores a spore,
/// optionally saving the VM or committing its root disk as an image.
pub const Request = struct {
    /// As asked; `execute` resolves it for the host.
    backend: Backend = .auto,
    machine: Machine,
    command: []const []const u8,
    guest_env: []const []const u8 = &.{},
    interactive: bool = false,
    tty: bool = false,
    memory: memory_config.Config = .{},
    vcpus: topology.VcpuCount = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    save: ?Save = null,
    annotations: spore.Annotations = .{},
    network: spore_net_policy.Network = .disabled,
    events: ?events_mod.EventSink = null,
    spore_executable: []const u8 = "spore",
    debug: bool = false,

    pub const Machine = union(enum) {
        boot: Boot,
        /// `spore run --from DIR`.
        from: From,
    };

    pub const Boot = struct {
        assets: Assets,
        rootfs_path: ?[]const u8 = null,
        rootfs: ?spore.Rootfs = null,
        injected_files: []const boot_assets.InjectedFile = &.{},
        working_dir: ?[]const u8 = null,
        commit: ?Commit = null,
    };

    pub const Assets = union(enum) {
        /// The managed kernel and initrd, already verified. Only they
        /// support memory hotplug, so only they boot elastic memory.
        managed: boot_assets.MonitorBootArtifacts,
        files: struct {
            kernel: []const u8,
            initrd: ?[]const u8 = null,
        },
    };

    pub const From = struct {
        dir: []const u8,
        rootfs: ?spore.Rootfs = null,
        disk: ?spore.Disk = null,
        generation: ?generation.State = null,
        /// Fan-out identity for the command. The guest must apply it before
        /// the command starts.
        generation_params: ?[]const u8 = null,
    };

    pub const Save = struct {
        dir: []const u8,
        trigger: capture.Trigger = .exit,
        continue_after: bool = false,
    };

    /// On command success, publish the writable root disk as a local image.
    pub const Commit = struct {
        ref: []const u8,
        config: rootfs_mod.ImageConfig,
        platform: rootfs_mod.Platform = rootfs_input.direct_image_platform,
        /// Grow the root disk to this size before the command; 0 keeps it.
        grow_target: u64 = 0,
    };
};

pub const BoundServiceArgList = struct {
    items: [spore_net_policy.max_bound_services][]const u8 = undefined,
    len: usize = 0,

    pub fn append(self: *BoundServiceArgList, raw: []const u8) !void {
        if (self.len >= spore_net_policy.max_bound_services) return error.TooManyBoundServices;
        self.items[self.len] = raw;
        self.len += 1;
    }

    pub fn slice(self: *const BoundServiceArgList) []const []const u8 {
        return self.items[0..self.len];
    }
};

pub fn isX86ProductPolicyError(err: anyerror) bool {
    return err == error.X86ElasticMemoryUnsupported or
        err == error.X86ExperimentalMemorySizeUnsupported or
        err == error.X86VcpuCountUnsupported or
        err == error.X86ResumeUnsupported or
        err == error.X86CaptureUnsupported or
        err == error.X86DiskForkUnsupported;
}

pub const SharedOptions = struct {
    kernel_path: ?[]const u8 = null,
    initrd_path: ?[]const u8 = null,
    memory: memory_config.Config = .{},
    memory_set: bool = false,
    max_memory_set: bool = false,
    vcpus: topology.VcpuCount = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    console_log_path: ?[]const u8 = null,
};

pub const CliOptions = struct {
    backend: Backend = .auto,
    shared: SharedOptions = .{},
    from_spore_dir: ?[]const u8 = null,
    generation_path: ?[]const u8 = null,
    rootfs_path: ?[]const u8 = null,
    image_ref: ?[]const u8 = null,
    image_entrypoint: ?[]const u8 = null,
    pull_policy: rootfs_input.PullPolicy = .missing,
    commit_ref: ?[]const u8 = null,
    disk_size: ?u64 = null,
    save_path: ?[]const u8 = null,
    save_trigger: capture.Trigger = .exit,
    continue_after_save: bool = false,
    network: spore_net_policy.Network = .disabled,
    bound_services: spore_net_policy.BoundServiceBindingList = .{},
    interactive: bool = false,
    tty: bool = false,
    guest_env_specs: guest_request.GuestEnvSpecList = .{},
    injected_file_sources: boot_assets.InjectedFileSourceList = .{},
    command_mode: cli_args.CommandMode = .argv,
    command: []const []const u8,
};

pub const cli_usage =
    \\Usage:
    \\  spore run --image REF [options]
    \\  spore run [--kernel Image] [--initrd root.cpio] [options] 'shell command'
    \\  spore run [--kernel Image] [--initrd root.cpio] [options] -- <argv...>
    \\  spore run --from DIR [options] 'shell command'
    \\  spore run --from DIR [options] -- <argv...>
    \\
    \\Options:
    \\  --backend auto|hvf|kvm  Backend to run (default: auto)
    \\  --kernel Image          Kernel Image path (default: managed SporeVM kernel)
    \\  --initrd root.cpio      Initrd path (default: embedded minimal exec initrd)
    \\  --from DIR              Restore VM state from a spore and run a new command
    \\                          Uses spore memory/device sizing; omit --memory
    \\  --generation FILE       With --from, inject fan-out identity JSON before command
    \\  --rootfs rootfs.ext4    Attach local rootfs read-only; save unsupported
    \\  --image REF             Build or reuse cached OCI rootfs; default to Entrypoint + Cmd
    \\  --entrypoint PATH       Override the OCI Entrypoint for --image
    \\  --pull=missing|always|never
    \\                          Pull policy for mutable --image refs (default: missing)
    \\  --commit LOCAL_REF      On command success, publish the writable root disk as an image
    \\  --disk-size SIZE        Grow an image-backed commit disk before the command (e.g. 20gb)
    \\  --net                   Experimental SporeVM-managed networking
    \\  --allow-cidr CIDR       With --net, restrict public egress to this CIDR
    \\  --allow-host HOST       With --net, restrict public egress to DNS A answers for this host
    \\  --bind-service NAME[:PORT]=unix:/path.sock
    \\                          With --net, declare a guest-local Unix service
    \\  --bind-service NAME=unix:/path.sock
    \\                          With --from, bind a manifest-declared service
    \\  --forward 127.0.0.1:HOST_PORT:GUEST_PORT
    \\                          With --net, forward host loopback TCP to a guest port
    \\  --save DIR              Save a spore to DIR; defaults to --save-on EXIT
    \\  --save-on WHEN          Save trigger: EXIT, INT, TERM, HUP, USR1, or USR2
    \\  --continue-after-save   Keep running after a signal-triggered save
    \\  --memory SIZE           Initial guest memory (default: 512mb)
    \\  --max-memory SIZE       Elastic memory ceiling (default: same as --memory)
    \\  --vcpus N               Guest vCPU count (1-8; save/restore backend-dependent)
    \\  --guest-port N          Guest vsock listen port (default: 10700)
    \\  --timeout DURATION      Probe timeout (default: 30s; e.g. 500ms, 1m)
    \\  --console-log PATH      Write guest console output, and, in a VM this command boots, a copy of command output, to PATH
    \\  --env KEY[=VALUE]       Set or copy a host env var for the guest command
    \\  --inject ID=PATH        Inject PATH as /run/sporevm/injected/ID for this run
    \\  -i, --interactive       Keep stdin open and forward it to the guest process
    \\  -t, --tty               Allocate a guest terminal for the process
    \\  -- <argv...>            Run exact argv instead of /bin/sh -lc
    \\  -h, --help              Show this help
    \\
    \\Workflow:
    \\  spore run --save base.spore --save-on TERM 'while true; do echo tick; sleep 1; done'
    \\  spore checkpoint fork base.spore --count 2 --out children
    \\  spore fanout children --for 10s
    \\
;

/// Set by `spore --json run`: argv and setup errors become a failed
/// `completion` on this sink instead of a message on stderr.
pub var cli_setup_events: ?events_mod.EventSink = null;

pub fn failCliSetup(comptime fmt: []const u8, args: anytype) noreturn {
    if (cli_setup_events) |sink| {
        const message = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch "spore run: setup failed";
        sink.emit(.{ .failure = .{
            .command = "run",
            .backend = null,
            .classified = machine_output.CliError.init(.usage_invalid_argument, message, "run"),
        } }) catch {};
        std.process.exit(2);
    }
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(2);
}

/// Redirect hints for run flags removed in the spore/saved-session rename.
fn renamedRunFlagHint(arg: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, arg, "--capture")) return "--save DIR";
    if (std.mem.eql(u8, arg, "--capture-on")) return "--save-on WHEN";
    if (std.mem.eql(u8, arg, "--continue-after-capture")) return "--continue-after-save";
    return null;
}

pub fn parseCliArgs(allocator: std.mem.Allocator, args: []const []const u8) !CliOptions {
    var backend: Backend = .auto;
    var shared = SharedOptions{};
    var from_spore_dir: ?[]const u8 = null;
    var generation_path: ?[]const u8 = null;
    var rootfs_path: ?[]const u8 = null;
    var image_ref: ?[]const u8 = null;
    var image_entrypoint: ?[]const u8 = null;
    var pull_policy: rootfs_input.PullPolicy = .missing;
    var commit_ref: ?[]const u8 = null;
    var disk_size: ?u64 = null;
    var save_path: ?[]const u8 = null;
    var save_trigger: capture.Trigger = .exit;
    var save_trigger_set = false;
    var continue_after_save = false;
    var network_requested = false;
    // Plain `--net` leaves egress unrestricted; allow flags narrow it.
    var network_policy = spore_net_policy.Config{ .egress = .unrestricted };
    var bind_service_args = BoundServiceArgList{};
    var bound_services = spore_net_policy.BoundServiceBindingList{};
    var interactive = false;
    var tty = false;
    var guest_env_specs = guest_request.GuestEnvSpecList{};
    var injected_file_sources = boot_assets.InjectedFileSourceList{};
    var command_mode: cli_args.CommandMode = .shell;
    var command_had_delimiter = false;
    var command: ?[]const []const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            command_mode = .argv;
            command_had_delimiter = true;
            command = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, args[i], "--backend") and i + 1 < args.len) {
            i += 1;
            backend = Backend.parse(args[i]) orelse {
                failCliSetup("--backend must be auto, hvf, or kvm", .{});
            };
        } else if (std.mem.eql(u8, args[i], "--rootfs")) {
            rootfs_path = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--image")) {
            image_ref = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--entrypoint")) {
            image_entrypoint = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--commit")) {
            commit_ref = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--disk-size")) {
            const raw = takeValue(args, &i, args[i]);
            const bytes = memory_config.parseBytes(raw) catch |err| {
                failCliSetup("spore run: invalid --disk-size {s}: {s}", .{ raw, @errorName(err) });
            };
            if (bytes % rootfs_cas.default_chunk_size != 0) {
                failCliSetup("spore run: --disk-size must be a positive 64KiB-aligned size like 20gb", .{});
            }
            disk_size = bytes;
        } else if (std.mem.eql(u8, args[i], "--pull")) {
            const raw = takeValue(args, &i, args[i]);
            pull_policy = rootfs_input.PullPolicy.parse(raw) orelse {
                failCliSetup("--pull must be missing, always, or never", .{});
            };
        } else if (std.mem.startsWith(u8, args[i], "--pull=")) {
            const raw = args[i]["--pull=".len..];
            pull_policy = rootfs_input.PullPolicy.parse(raw) orelse {
                failCliSetup("--pull must be missing, always, or never", .{});
            };
        } else if (std.mem.eql(u8, args[i], "--from")) {
            from_spore_dir = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--generation")) {
            generation_path = takeValue(args, &i, args[i]);
        } else if (std.mem.startsWith(u8, args[i], "--generation=")) {
            generation_path = args[i]["--generation=".len..];
        } else if (std.mem.eql(u8, args[i], "--save")) {
            save_path = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--save-on")) {
            const trigger_raw = takeValue(args, &i, args[i]);
            save_trigger = capture.Trigger.parse(trigger_raw) orelse {
                failCliSetup("--save-on must be EXIT, INT, TERM, HUP, USR1, or USR2", .{});
            };
            save_trigger_set = true;
        } else if (std.mem.eql(u8, args[i], "--continue-after-save")) {
            continue_after_save = true;
        } else if (std.mem.eql(u8, args[i], "--env")) {
            const raw = takeValue(args, &i, args[i]);
            guest_env_specs.append(guest_request.parseGuestEnvSpec(raw) catch |err| {
                failCliSetup("spore run: invalid --env {s}: {s}", .{ raw, @errorName(err) });
            }) catch |err| {
                failCliSetup("spore run: invalid --env {s}: {s}", .{ raw, @errorName(err) });
            };
        } else if (std.mem.eql(u8, args[i], "-i") or std.mem.eql(u8, args[i], "--interactive")) {
            interactive = true;
        } else if (std.mem.eql(u8, args[i], "-t") or std.mem.eql(u8, args[i], "--tty")) {
            tty = true;
        } else if (std.mem.eql(u8, args[i], "-it") or std.mem.eql(u8, args[i], "-ti")) {
            interactive = true;
            tty = true;
        } else if (std.mem.eql(u8, args[i], "--inject")) {
            const raw = takeValue(args, &i, args[i]);
            injected_file_sources.append(boot_assets.parseInjectedFileSource(raw) catch |err| {
                failCliSetup("spore run: invalid --inject {s}: {s}", .{ raw, @errorName(err) });
            }) catch |err| {
                failCliSetup("spore run: invalid --inject {s}: {s}", .{ raw, @errorName(err) });
            };
        } else if (std.mem.eql(u8, args[i], "--net")) {
            network_requested = true;
        } else if (std.mem.eql(u8, args[i], "--allow-cidr")) {
            const raw = takeValue(args, &i, args[i]);
            network_policy.addAllowCidr(raw) catch |err| {
                failCliSetup("spore run: invalid --allow-cidr {s}: {s}", .{ raw, @errorName(err) });
            };
        } else if (std.mem.eql(u8, args[i], "--allow-host")) {
            const raw = takeValue(args, &i, args[i]);
            network_policy.addAllowHost(raw) catch |err| {
                failCliSetup("spore run: invalid --allow-host {s}: {s}", .{ raw, @errorName(err) });
            };
        } else if (std.mem.eql(u8, args[i], "--bind-service")) {
            const raw = takeValue(args, &i, args[i]);
            bind_service_args.append(raw) catch |err| {
                failCliSetup("spore run: invalid --bind-service {s}: {s}", .{ raw, @errorName(err) });
            };
        } else if (std.mem.eql(u8, args[i], "--forward")) {
            const raw = takeValue(args, &i, args[i]);
            network_policy.addPortForward(raw) catch |err| {
                failCliSetup("spore run: invalid --forward {s}: {s}", .{ raw, @errorName(err) });
            };
        } else if (try parseSharedOption(&shared, args, &i)) {
            continue;
        } else if (renamedRunFlagHint(args[i])) |replacement| {
            failCliSetup("spore run: {s} was renamed; use {s}", .{ args[i], replacement });
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            failCliSetup("unknown run argument: {s}\n\n{s}", .{ args[i], cli_usage });
        } else {
            command = args[i..];
            break;
        }
    }

    const argv = command orelse &.{};
    if (argv.len == 0 and (command_had_delimiter or (from_spore_dir == null and image_ref == null))) {
        failCliSetup("{s}", .{cli_usage});
    }
    if (rootfs_path != null and image_ref != null) {
        failCliSetup("spore run: --rootfs and --image are mutually exclusive", .{});
    }
    if (image_ref == null and pull_policy != .missing) {
        failCliSetup("spore run: --pull requires --image", .{});
    }
    if (image_entrypoint != null and image_ref == null) {
        failCliSetup("spore run: --entrypoint requires --image", .{});
    }
    if (disk_size != null and commit_ref == null) {
        failCliSetup("spore run: --disk-size currently requires --commit", .{});
    }
    if (commit_ref) |ref| {
        rootfs_mod.validateLocalTagRef(ref) catch |err| {
            failCliSetup("spore run: invalid --commit ref {s}: {s}", .{ ref, @errorName(err) });
        };
        if (image_ref == null) {
            failCliSetup("spore run: --commit requires --image", .{});
        }
        if (from_spore_dir != null or rootfs_path != null) {
            failCliSetup("spore run: --commit supports fresh --image runs only", .{});
        }
        if (save_path != null or save_trigger_set or continue_after_save) {
            failCliSetup("spore run: --commit cannot be combined with --save, --save-on, or --continue-after-save", .{});
        }
        if (interactive or tty) {
            failCliSetup("spore run: --commit cannot be combined with -i or -t", .{});
        }
    }
    if (from_spore_dir != null) {
        for (bind_service_args.slice()) |raw| {
            bound_services.append(spore_net_policy.parseBoundServiceBinding(raw) catch |err| {
                failCliSetup("spore run: invalid --bind-service {s}: {s}", .{ raw, @errorName(err) });
            }) catch |err| {
                failCliSetup("spore run: invalid --bind-service {s}: {s}", .{ raw, @errorName(err) });
            };
        }
        if (injected_file_sources.len != 0) {
            failCliSetup("spore run: --inject is not supported with --from; injected files are fresh-run only", .{});
        }
        if (rootfs_path != null or image_ref != null) {
            failCliSetup("spore run: --from is mutually exclusive with --rootfs and --image", .{});
        }
        if (shared.kernel_path != null or shared.initrd_path != null) {
            failCliSetup("spore run: --from is mutually exclusive with --kernel and --initrd", .{});
        }
        if (shared.memory_set or shared.max_memory_set) {
            failCliSetup("spore run: --from uses the spore manifest memory sizes; omit --memory and --max-memory", .{});
        }
    } else {
        if (generation_path != null) {
            failCliSetup("spore run: --generation requires --from", .{});
        }
        for (bind_service_args.slice()) |raw| {
            network_policy.addBindService(allocator, raw) catch |err| {
                failCliSetup("spore run: invalid --bind-service {s}: {s}", .{ raw, @errorName(err) });
            };
        }
    }
    if (save_trigger_set and save_path == null) {
        failCliSetup("spore run: --save-on requires --save", .{});
    }
    if (continue_after_save and save_path == null) {
        failCliSetup("spore run: --continue-after-save requires --save", .{});
    }
    if (continue_after_save and save_trigger.isExit()) {
        failCliSetup("spore run: --continue-after-save requires a signal save trigger", .{});
    }
    if (save_path != null and injected_file_sources.len != 0) {
        failCliSetup("spore run: --inject with --save is not supported; injected files are intentionally not persisted", .{});
    }
    if (!network_requested and network_policy.hasRules()) {
        failCliSetup("spore run: network flags require --net", .{});
    }
    if (!network_requested and network_policy.hasBoundServices()) {
        failCliSetup("spore run: --bind-service requires --net", .{});
    }
    shared.memory.validate() catch |err| switch (err) {
        error.MaximumBelowInitial => failCliSetup("spore run: --max-memory must be greater than or equal to --memory", .{}),
        error.UnalignedElasticMemory => failCliSetup("spore run: elastic --memory and --max-memory values must be aligned to 2 MiB", .{}),
        error.ElasticRegionTooLarge => failCliSetup("spore run: --max-memory may exceed --memory by at most 16 GiB", .{}),
        else => failCliSetup("spore run: invalid memory configuration ({s})", .{memory_config.cliReason(err)}),
    };

    return .{
        .backend = backend,
        .shared = shared,
        .from_spore_dir = from_spore_dir,
        .generation_path = generation_path,
        .rootfs_path = rootfs_path,
        .image_ref = image_ref,
        .image_entrypoint = image_entrypoint,
        .pull_policy = pull_policy,
        .commit_ref = commit_ref,
        .disk_size = disk_size,
        .save_path = save_path,
        .save_trigger = save_trigger,
        .continue_after_save = continue_after_save,
        .network = if (network_requested) .{ .spore = network_policy } else .disabled,
        .bound_services = bound_services,
        .interactive = interactive,
        .tty = tty,
        .guest_env_specs = guest_env_specs,
        .injected_file_sources = injected_file_sources,
        .command_mode = command_mode,
        .command = argv,
    };
}

pub fn cliGuestCommand(allocator: std.mem.Allocator, opts: CliOptions) ![]const []const u8 {
    return cli_args.cliGuestCommandFromMode(allocator, opts.command_mode, opts.command);
}

fn monotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

const CommitControl = struct {
    io: Io,
    allocator: std.mem.Allocator,
    command_stream: *vsock_stream.HostStream,
    guest_port: u32,
    timeout_ms: u64,
    cache_root: []const u8,
    rootfs_grow_target: u64,
    phase: Phase,
    resize_stream: vsock_stream.HostStream = undefined,
    resize_stdout: std.array_list.Managed(u8),
    resize_stdout_overflow: bool = false,
    freeze_stream: vsock_stream.HostStream = undefined,
    storage: ?spore.RootfsStorage = null,
    cache_lock: ?rootfs_mod.RootfsCacheLock = null,
    wake: ?vsock_control.Wake = null,

    const Phase = enum {
        start_resize,
        active_resize,
        start_command,
        wait_command,
        start_freeze,
        active_freeze,
        snapshot,
        done,
    };

    fn deinit(self: *CommitControl) void {
        self.resize_stdout.deinit();
        if (self.cache_lock) |*lock| lock.deinit();
    }

    fn control(self: *CommitControl) vsock_control.Control {
        return .{
            .context = self,
            .pollFn = pollThunk,
            .setWakeFn = setWakeThunk,
            .completeSnapshotFn = completeSnapshotThunk,
            .completeRootfsSnapshotFn = completeRootfsSnapshotThunk,
            .reportStatsFn = reportStatsThunk,
        };
    }

    fn poll(self: *CommitControl, dev: *vsock.Vsock) !vsock_control.ControlAction {
        switch (self.phase) {
            .start_resize => {
                const request = try guest_request.simpleControlRequest(self.allocator, "spore-rootfs-grow-v1", "spore-run-commit-resize");
                self.resize_stream = try vsock_stream.HostStream.init(self.guest_port, request);
                self.resize_stream.host_port = vsock_stream.HostStream.deriveHostPort(request);
                self.resize_stream.setOutputSink(self, resizeOutputSink);
                try self.startStream(dev, &self.resize_stream);
                self.phase = .active_resize;
                return .keep_running;
            },
            .active_resize => {
                _ = try dev.flushHostStreamOutbound();
                switch (self.resize_stream.state) {
                    .complete => {
                        const exit_code = self.resize_stream.exit_code orelse return error.BadRunExitFrame;
                        dev.resetHostStream();
                        if (exit_code != 0) return error.RunCommitGuestResizeFailed;
                        if (self.resize_stdout_overflow) return error.RunCommitGuestResizeFailed;
                        const result = guest_request.parseRootfsGrowResponse(self.resize_stdout.items) catch return error.RunCommitGuestResizeFailed;
                        if (result.device_bytes != self.rootfs_grow_target) return error.RunCommitGuestResizeFailed;
                        self.phase = .start_command;
                        self.requestPoll();
                    },
                    .failed => {
                        dev.resetHostStream();
                        return error.RunCommitGuestResizeFailed;
                    },
                    else => if (self.resize_stream.elapsedMs() > self.timeout_ms) {
                        dev.resetHostStream();
                        return error.RunCommitGuestResizeTimedOut;
                    },
                }
                return .keep_running;
            },
            .start_command => {
                try self.startStream(dev, self.command_stream);
                self.phase = .wait_command;
                return .keep_running;
            },
            .wait_command => {
                if (self.command_stream.state != .complete) return .keep_running;
                const exit_code = self.command_stream.exit_code orelse return error.BadRunExitFrame;
                self.phase = if (exit_code == 0) .start_freeze else .done;
                // The command stream is the run's exec probe; the backend
                // leaves the finished stream attached for this control to
                // drop. The freeze stream starts on the following poll.
                dev.resetHostStream();
                self.requestPoll();
                return .keep_running;
            },
            .start_freeze => {
                const request = try guest_request.simpleControlRequest(self.allocator, "fsfreeze-v1", "spore-run-commit-freeze");
                self.freeze_stream = try vsock_stream.HostStream.init(self.guest_port, request);
                self.freeze_stream.host_port = vsock_stream.HostStream.deriveHostPort(request);
                try dev.attachHostStream(&self.freeze_stream);
                self.freeze_stream.markStarted();
                _ = try dev.flushHostStreamOutbound();
                self.phase = .active_freeze;
                return .keep_running;
            },
            .active_freeze => {
                _ = try dev.flushHostStreamOutbound();
                switch (self.freeze_stream.state) {
                    .complete => {
                        const exit_code = self.freeze_stream.exit_code orelse return error.BadRunExitFrame;
                        dev.resetHostStream();
                        if (exit_code != 0) return error.RunCommitGuestFreezeFailed;
                        self.cache_lock = try rootfs_mod.lockRootfsCacheExclusive(self.io, self.allocator, self.cache_root);
                        self.phase = .snapshot;
                        self.requestPoll();
                    },
                    .failed => {
                        dev.resetHostStream();
                        return error.RunCommitGuestFreezeFailed;
                    },
                    else => if (self.freeze_stream.elapsedMs() > self.timeout_ms) {
                        dev.resetHostStream();
                        return error.RunCommitGuestFreezeTimedOut;
                    },
                }
                return .keep_running;
            },
            .snapshot => return .{ .rootfs_snapshot = .{ .dir = self.cache_root } },
            .done => return .stop,
        }
    }

    fn startStream(_: *CommitControl, dev: *vsock.Vsock, stream: *vsock_stream.HostStream) !void {
        stream.markStarted();
        try dev.attachHostStream(stream);
        _ = try dev.flushHostStreamOutbound();
    }

    fn requestPoll(self: *CommitControl) void {
        if (self.wake) |wake| wake.wake();
    }

    fn resizeOutputSink(context: ?*anyopaque, output: vsock_stream.HostStreamOutput, bytes: []const u8) void {
        if (output != .stdout) return;
        const self: *CommitControl = @ptrCast(@alignCast(context.?));
        const remaining = guest_request.max_rootfs_grow_response -| self.resize_stdout.items.len;
        if (bytes.len > remaining) self.resize_stdout_overflow = true;
        const take = @min(remaining, bytes.len);
        if (take != 0) self.resize_stdout.appendSlice(bytes[0..take]) catch {
            self.resize_stdout_overflow = true;
        };
    }

    fn completeRootfsSnapshot(self: *CommitControl, maybe_disk: ?spore.Disk) !void {
        if (self.phase != .snapshot or self.cache_lock == null) return error.BadManifest;
        const disk = maybe_disk orelse return error.BadManifest;
        const storage = try runtime_disk_mod.storageFromSnapshotDisk(self.allocator, disk);
        try rootfs_cas.markStorageComplete(self.io, self.allocator, self.cache_root, storage.index_digest);
        self.storage = storage;
        self.phase = .done;
        self.requestPoll();
    }

    fn pollThunk(context: *anyopaque, dev: *vsock.Vsock) !vsock_control.ControlAction {
        const self: *CommitControl = @ptrCast(@alignCast(context));
        return self.poll(dev);
    }

    fn setWakeThunk(context: *anyopaque, wake: vsock_control.Wake) void {
        const self: *CommitControl = @ptrCast(@alignCast(context));
        self.wake = wake;
    }
    fn completeSnapshotThunk(_: *anyopaque, _: []const u8) !void {}

    fn completeRootfsSnapshotThunk(context: *anyopaque, disk: ?spore.Disk) !void {
        const self: *CommitControl = @ptrCast(@alignCast(context));
        try self.completeRootfsSnapshot(disk);
    }

    fn reportStatsThunk(_: *anyopaque, _: vsock_control.ControlStats) void {}
};

pub fn execute(context: Context, allocator: std.mem.Allocator, request: Request) !events_mod.Result {
    var events = events_mod.EventEmitter.init(request.events, "run");
    try events.emitStart(request.backend);
    var created_save_dir = false;
    return executeWithEvents(context, allocator, request, &events, &created_save_dir) catch |err| {
        // A store that cannot supply the image fails the save before it
        // publishes anything, so remove the directory this run created
        // (dirty-RAM tracking may already have written memory into it).
        // Other failures remove it only while it is empty, as when the root
        // disk does not open, so a published spore or an interrupted publish
        // stays.
        if (created_save_dir) {
            if (err == error.ImageStoreIncomplete)
                Io.Dir.cwd().deleteTree(context.io, request.save.?.dir) catch {}
            else
                Io.Dir.cwd().deleteDir(context.io, request.save.?.dir) catch {};
        }
        events.emitFailure(err) catch {};
        return err;
    };
}

/// Sets `created_save_dir` once the save directory exists, for `execute` to
/// clean up.
fn executeWithEvents(context: Context, allocator: std.mem.Allocator, request: Request, events: *events_mod.EventEmitter, created_save_dir: *bool) !events_mod.Result {
    const setup_start = monotonicMs();
    try topology.validateVcpuCount(request.vcpus);
    try spore.validateAnnotations(request.annotations);
    const commit: ?Request.Commit = switch (request.machine) {
        .boot => |fresh| fresh.commit,
        .from => null,
    };
    if (commit != null and (request.save != null or request.interactive or request.tty or request.command.len == 0)) return error.InvalidRunCommitOptions;
    if (request.tty and request.machine == .from) return error.TtyRunFromSporeUnsupported;
    const grow_target = if (commit) |value| value.grow_target else 0;

    const backend = try request.backend.resolveForHost();
    events.setBackend(backend);
    var gateway: net_gateway.Process = undefined;
    var gateway_active = false;
    if (request.network == .spore) {
        try gateway.start(context.io, allocator, request.spore_executable, request.debug, request.network.spore);
        gateway_active = true;
    }
    defer if (gateway_active) gateway.deinit();
    if (gateway_active) try events.emitPortForwards(&request.network.spore);
    const network: virtio_net.Runtime = if (gateway_active) gateway.runtime() else .{};
    errdefer events_mod.finishGatewayNetworkEvents(&gateway, &gateway_active, events);
    const network_manifest = try spore_net_policy.manifestNetworkFromOptions(allocator, &request.network);

    const resume_dir: ?[]const u8 = switch (request.machine) {
        .boot => null,
        .from => |from| from.dir,
    };
    // Only the managed kernel boots with memory hotplug.
    const boot_without_hotplug = request.machine == .boot and request.machine.boot.assets != .managed;
    if (request.memory.isElastic() and (boot_without_hotplug or request.vcpus != 1)) return error.ElasticMemoryUnsupported;
    const local_backing_start = monotonicMs();
    var ram_plan = try ram_restore.Plan.fromSporeDir(allocator, context.environ_map, resume_dir, request.memory.maximum_bytes);
    const local_backing_ms = monotonicMs() -| local_backing_start;
    defer ram_plan.deinit();
    if (resume_dir != null) std.log.info("run --from memory restore source={s} reason={s}", .{ @tagName(ram_plan.restoreSource().?), @tagName(ram_plan.reason) });
    const boot_start = monotonicMs();
    const machine: vm_session.Machine = switch (request.machine) {
        .from => |from| .{ .restore = .{
            .dir = from.dir,
            .ram = ram_plan.strategy,
            .generation = from.generation,
        } },
        .boot => |fresh| boot: {
            if (request.save != null and fresh.injected_files.len != 0) return error.InjectedFileCaptureUnsupported;
            break :boot .{ .boot = .{
                .kernel = switch (fresh.assets) {
                    .managed => |managed| managed.kernel,
                    .files => |files| try std.Io.Dir.cwd().readFileAlloc(context.io, files.kernel, allocator, .limited(boot_assets.max_file_size)),
                },
                .initrd = switch (fresh.assets) {
                    .managed => |managed| if (fresh.injected_files.len == 0) managed.initrd else try boot_assets.loadRunInitrd(context.io, allocator, null, fresh.injected_files),
                    .files => |files| try boot_assets.loadRunInitrd(context.io, allocator, files.initrd, fresh.injected_files),
                },
                .memory = request.memory,
                .guest_port = request.guest_port,
                .console_mirror = vm_session.console_fd >= 0,
            } };
        },
    };
    const boot_ms = monotonicMs() -| boot_start;
    const disks: runtime_disk_mod.Options = switch (request.machine) {
        .boot => |fresh| .{
            .rootfs_path = fresh.rootfs_path,
            .rootfs = fresh.rootfs,
            .rootfs_grow_target = grow_target,
        },
        .from => |from| .{
            .rootfs = from.rootfs,
            .disk = from.disk,
            .spore_dir = from.dir,
        },
    };
    const request_start = monotonicMs();
    const guest_request_info = try execRequestForRun(context, allocator, request, request.memory.isElastic());
    var stream = try vsock_stream.HostStream.init(request.guest_port, guest_request_info.bytes);
    const request_ms = monotonicMs() -| request_start;
    if (resume_dir != null) stream.host_port = vsock_stream.HostStream.deriveHostPort(guest_request_info.bytes);
    if (request.events != null) {
        stream.setLifecycleSink(events, runEventLifecycleSink);
        stream.setOutputSink(events, runEventOutputSink);
    }
    var stdin_control = if (request.interactive or request.tty) attach_stream.RunStdinControl.init(&stream, request.tty, request.interactive, attach_stream.terminalSizeFd()) else null;
    if (stdin_control) |*control| try control.start(request.tty and request.interactive);
    defer if (stdin_control) |*control| control.deinit();
    const commit_cache_root = if (commit != null)
        try local_paths.rootfsCacheRootPath(allocator, context.environ_map)
    else
        null;
    var commit_control: ?CommitControl = if (commit_cache_root) |cache_root| .{
        .io = context.io,
        .allocator = allocator,
        .command_stream = &stream,
        .guest_port = request.guest_port,
        .timeout_ms = request.timeout_ms,
        .cache_root = cache_root,
        .rootfs_grow_target = grow_target,
        .phase = if (grow_target != 0) .start_resize else .wait_command,
        .resize_stdout = std.array_list.Managed(u8).init(allocator),
    } else null;
    defer if (commit_control) |*control| control.deinit();
    const exec_control = if (commit_control) |*control|
        control.control()
    else if (stdin_control) |*control|
        control.control()
    else
        null;
    var capture_request = capture.Request{};
    var signal_registration: ?capture.SignalRegistration = null;
    defer if (signal_registration) |*registration| registration.deinit();
    const capture_plan = if (request.save) |save| capture.Plan.productRun(.{
        .capture_path = save.dir,
        .trigger = save.trigger,
        .resume_dir = resume_dir,
        .request = &capture_request,
        .continue_after_capture = save.continue_after,
    }) else capture.Plan{};
    if (capture_plan.capture) |vm_capture| {
        try spore.createSnapshotRoot(allocator, vm_capture.dir);
        created_save_dir.* = true;
        if (disks.hasRootfs()) {
            const cache_root = try local_paths.rootfsCacheRootPath(allocator, context.environ_map);
            defer allocator.free(cache_root);
            try saved_spore_pin.ensureOwnershipLinkCompatible(allocator, cache_root, vm_capture.dir);
        }
    }
    const saved_sessions = [_]spore.Session{spore.processSession(guest_request_info.session_id, request.interactive, request.tty)};
    if (capture_plan.signal) |signal| {
        signal_registration = capture.SignalRegistration.install(signal, &capture_request);
    }
    std.log.debug(
        "run host setup timing: total_ms={d} local_backing_ms={d} boot_ms={d} request_ms={d} ram_mib={d} virtio_mem_mib={d}",
        .{
            monotonicMs() -| setup_start,
            local_backing_ms,
            boot_ms,
            request_ms,
            request.memory.initial_bytes / 1024 / 1024,
            (request.memory.maximum_bytes - request.memory.initial_bytes) / 1024 / 1024,
        },
    );

    const cause = vm_session.run(context, allocator, .{
        .backend = backend,
        .machine = machine,
        .vcpus = request.vcpus,
        .disks = disks,
        .network = .{ .runtime = network, .manifest = network_manifest },
        .record = .{ .annotations = request.annotations, .sessions = &saved_sessions },
        .console_sink = vm_session.consoleSink,
        .mode = .{ .oneshot = .{
            .probe = .{
                .stream = &stream,
                .timeout_ms = request.timeout_ms,
                .start = if (grow_target != 0) .control else .immediate,
                .on_complete = if (commit == null) .stop else .detach,
                .session_output = true,
            },
            .capture = capture_plan.capture,
            .control = exec_control,
        } },
    }) catch |err| {
        if (capture_plan.isSignalCapture() and capture_request.isCompleted() and isCaptureAborted(err)) {
            var result = resultFromAbortedSignalCapture(backend, request, &stream);
            if (resume_dir != null) result = result.withMemoryRestore(&ram_plan);
            events_mod.finishGatewayNetworkEvents(&gateway, &gateway_active, events);
            try events.emitExit(result);
            if (events.write_failed) return error.EventSinkFailed;
            return result;
        }
        return err;
    };
    const signal_capture_observed = capture_plan.isSignalCapture() and capture_request.isCompleted();
    var result = try switch (cause) {
        .probe_complete => resultFromStream(backend, request, &stream, signal_capture_observed),
        .monitor_stopped => if (commit != null)
            resultFromStream(backend, request, &stream, false)
        else
            error.ProbeDidNotComplete,
        .snapshotted => if (capture_plan.isExitCapture())
            resultFromExitCapture(backend, request, &stream)
        else
            resultFromSignalCapture(backend, request, &stream),
        else => error.ProbeDidNotComplete,
    };
    if (commit) |commit_request| {
        if (result.exit_code == 0) {
            const control = if (commit_control) |*value| value else return error.RunCommitDidNotComplete;
            const storage = control.storage orelse return error.RunCommitDidNotComplete;
            const cache_lock = if (control.cache_lock) |*lock| lock else return error.RunCommitDidNotComplete;
            const published = try local_image.publish(context.io, allocator, control.cache_root, cache_lock, .{
                .platform = commit_request.platform,
                .config = commit_request.config,
                .storage = storage,
                .name = commit_request.ref,
            });
            events.emitImageCommitBestEffort(.{
                .command = "run",
                .backend = backend,
                .ref = commit_request.ref,
                .resolved_image_ref = published.resolved_ref,
                .rootfs_index_digest = storage.index_digest,
            });
            result.committed = true;
        }
    }
    if (resume_dir != null) result = result.withMemoryRestore(&ram_plan);
    events_mod.finishGatewayNetworkEvents(&gateway, &gateway_active, events);
    try events.emitExit(result);
    if (events.write_failed) return error.EventSinkFailed;
    return result;
}

fn runEventOutputSink(context: ?*anyopaque, output: vsock_stream.HostStreamOutput, bytes: []const u8) void {
    const events: *events_mod.EventEmitter = @ptrCast(@alignCast(context.?));
    events.emitOutputBestEffort(output, bytes);
}

fn runEventLifecycleSink(context: ?*anyopaque, event: vsock_stream.HostStreamLifecycle) void {
    const events: *events_mod.EventEmitter = @ptrCast(@alignCast(context.?));
    switch (event) {
        .ready => events.emitReadyBestEffort(),
    }
}

const RunRequestInfo = struct {
    bytes: []const u8,
    session_id: []const u8,
};

fn execRequestForRun(context: Context, allocator: std.mem.Allocator, request: Request, memory_pressure: bool) !RunRequestInfo {
    const resume_time_unix_ns: u64 = @intCast(Io.Clock.real.now(context.io).nanoseconds);
    switch (request.machine) {
        .boot => |boot| return .{
            .bytes = try guest_request.execRequestWithSessionOptions(allocator, request.command, spore.default_session_id, .{
                .env = request.guest_env,
                .working_dir = boot.working_dir,
                .resume_time_unix_ns = resume_time_unix_ns,
                .memory_pressure = memory_pressure,
                .stdio = runStdio(request),
                .terminal_size = attach_stream.terminalSizeOrDefault(attach_stream.terminalSizeFd()),
            }),
            .session_id = spore.default_session_id,
        },
        .from => |from| {
            const session_id = try randomRunSessionId(context, allocator);
            return .{
                .bytes = try guest_request.execRequestWithSessionOptions(allocator, request.command, session_id, .{
                    .env = request.guest_env,
                    .resume_time_unix_ns = resume_time_unix_ns,
                    .memory_pressure = memory_pressure,
                    .stdio = runStdio(request),
                    .terminal_size = attach_stream.terminalSizeOrDefault(attach_stream.terminalSizeFd()),
                    .generation_params = from.generation_params,
                    .require_generation_ready = from.generation_params != null,
                }),
                .session_id = session_id,
            };
        },
    }
}

// `spore run` forwards host stdin only with -i; without it the command
// reads /dev/null, as it did before the guest agent spoke only SPIO.
fn runStdio(request: Request) guest_request.GuestStdio {
    if (request.tty) return .tty;
    if (request.interactive) return .pipe;
    return .null;
}

fn randomRunSessionId(context: Context, allocator: std.mem.Allocator) ![]const u8 {
    const now = Io.Clock.real.now(context.io).nanoseconds;
    var nonce_bytes: [8]u8 = undefined;
    context.io.random(&nonce_bytes);
    const nonce = std.mem.readInt(u64, &nonce_bytes, .little);
    return std.fmt.allocPrint(allocator, "run-{x}-{x}", .{ now, nonce });
}

pub fn rootfsGrowTarget(current_size: u64, requested_size: u64) !u64 {
    if (requested_size < current_size) return error.RunDiskSizeWouldShrink;
    return if (requested_size == current_size) 0 else requested_size;
}

fn resultFromStream(backend: Backend, request: Request, stream: *const vsock_stream.HostStream, saved: bool) !events_mod.Result {
    const start_ms = stream.start_ms orelse 0;
    const connect_ms = stream.connect_ms orelse stream.elapsedMs();
    const response_ms = stream.response_ms orelse stream.elapsedMs();
    std.log.debug(
        "run exec probe timing: attach_ms={?} connect_request_delivered_ms={?} connect_ms={?} request_delivered_ms={?} first_output_ms={?} guest_timing_ms={?} response_ms={?}",
        .{
            stream.attach_ms,
            stream.connect_request_delivered_ms,
            stream.connect_ms,
            stream.request_delivered_ms,
            stream.first_output_ms,
            stream.guest_timing_ms,
            stream.response_ms,
        },
    );
    return .{
        .backend = backend,
        .start_ms = start_ms,
        .vsock_connect_ms = connect_ms,
        .exec_response_ms = response_ms,
        .probe_duration_ms = if (response_ms >= connect_ms) response_ms - connect_ms else 0,
        .exit_code = stream.exit_code orelse return error.BadRunExitFrame,
        .vcpus = request.vcpus,
        .memory_bytes = request.memory.initial_bytes,
        .max_memory_bytes = request.memory.maximum_bytes,
        .saved = saved,
        .save_path = if (saved) request.save.?.dir else null,
        .save_ownership = if (saved) saveOwnership(request) else null,
    };
}

fn resultFromSignalCapture(backend: Backend, request: Request, stream: *const vsock_stream.HostStream) events_mod.Result {
    return resultFromSignalCaptureExitCode(backend, request, stream, 0);
}

fn resultFromAbortedSignalCapture(backend: Backend, request: Request, stream: *const vsock_stream.HostStream) events_mod.Result {
    return resultFromSignalCaptureExitCode(backend, request, stream, 130);
}

fn resultFromSignalCaptureExitCode(backend: Backend, request: Request, stream: *const vsock_stream.HostStream, exit_code: u8) events_mod.Result {
    const start_ms = stream.start_ms orelse 0;
    const connect_ms = stream.connect_ms orelse stream.elapsedMs();
    const response_ms = stream.response_ms orelse stream.elapsedMs();
    return .{
        .backend = backend,
        .start_ms = start_ms,
        .vsock_connect_ms = connect_ms,
        .exec_response_ms = response_ms,
        .probe_duration_ms = if (response_ms >= connect_ms) response_ms - connect_ms else 0,
        .exit_code = exit_code,
        .vcpus = request.vcpus,
        .memory_bytes = request.memory.initial_bytes,
        .max_memory_bytes = request.memory.maximum_bytes,
        .saved = true,
        .save_path = request.save.?.dir,
        .save_ownership = saveOwnership(request),
    };
}

fn resultFromExitCapture(backend: Backend, request: Request, stream: *const vsock_stream.HostStream) !events_mod.Result {
    const start_ms = stream.start_ms orelse 0;
    const connect_ms = stream.connect_ms orelse stream.elapsedMs();
    const response_ms = stream.response_ms orelse stream.elapsedMs();
    return .{
        .backend = backend,
        .start_ms = start_ms,
        .vsock_connect_ms = connect_ms,
        .exec_response_ms = response_ms,
        .probe_duration_ms = if (response_ms >= connect_ms) response_ms - connect_ms else 0,
        .exit_code = stream.exit_code orelse return error.BadRunExitFrame,
        .vcpus = request.vcpus,
        .memory_bytes = request.memory.initial_bytes,
        .max_memory_bytes = request.memory.maximum_bytes,
        .saved = true,
        .save_path = request.save.?.dir,
        .save_ownership = saveOwnership(request),
    };
}

fn saveOwnership(request: Request) []const u8 {
    const disk_backed = switch (request.machine) {
        .boot => |boot| boot.rootfs != null or boot.rootfs_path != null,
        .from => |from| from.disk != null or from.rootfs != null,
    };
    return if (disk_backed)
        saved_spore_ownership.machine_local_pinned
    else
        saved_spore_ownership.portable_self_contained;
}

pub fn isCaptureAborted(err: anyerror) bool {
    return std.mem.eql(u8, @errorName(err), "CaptureAborted");
}

pub fn isNetworkGatewayError(err: anyerror) bool {
    return std.mem.eql(u8, @errorName(err), "NetdSpawnFailed") or
        std.mem.eql(u8, @errorName(err), "NetdReadyTimedOut") or
        std.mem.eql(u8, @errorName(err), "NetdReadyFailed") or
        std.mem.eql(u8, @errorName(err), "NetdThreadFailed") or
        std.mem.eql(u8, @errorName(err), "NetworkGatewayFailed");
}

pub fn printNetworkGatewayError(err: anyerror) void {
    const message = if (std.mem.eql(u8, @errorName(err), "NetdSpawnFailed"))
        "spore run: failed to start spore-netd"
    else if (std.mem.eql(u8, @errorName(err), "NetdReadyTimedOut"))
        "spore run: spore-netd did not become ready"
    else if (std.mem.eql(u8, @errorName(err), "NetdReadyFailed"))
        "spore run: spore-netd failed before ready"
    else if (std.mem.eql(u8, @errorName(err), "NetdThreadFailed"))
        "spore run: failed to monitor spore-netd"
    else
        "spore run: spore-netd exited during run";
    std.debug.print("{s}\n", .{message});
}

fn parsePositive(comptime T: type, name: []const u8, raw: []const u8) !T {
    const parsed = std.fmt.parseInt(T, raw, 10) catch {
        failCliSetup("{s} must be a positive integer", .{name});
    };
    if (parsed == 0) {
        failCliSetup("{s} must be a positive integer", .{name});
    }
    return parsed;
}

fn parseMemoryBytes(name: []const u8, raw: []const u8) u64 {
    return memory_config.parseBytes(raw) catch |err| switch (err) {
        error.RemovedAuto => failCliSetup("spore run: {s} auto was removed; use --memory 512mb for fixed memory, or --memory 512mb --max-memory 16gb for elastic memory", .{name}),
        else => failCliSetup("spore run: {s} must be a positive page-aligned size like 512mb or 16gb ({s})", .{ name, memory_config.cliReason(err) }),
    };
}

fn parseDurationMsOrExit(name: []const u8, raw: []const u8) u64 {
    return cli_args.parseDurationMs(raw) catch {
        failCliSetup("{s} expects a duration like 30s, 500ms, or 1m", .{name});
    };
}

pub fn parseVcpuCountOrExit(name: []const u8, raw: []const u8) topology.VcpuCount {
    return topology.parseVcpuCount(raw) catch {
        failCliSetup("{s} must be an integer from 1 to {d}", .{ name, topology.max_vcpus });
    };
}

fn parseGuestPort(name: []const u8, raw: []const u8) !u32 {
    const parsed = std.fmt.parseInt(u32, raw, 10) catch {
        failCliSetup("{s} must be an integer from 1 to {d}", .{ name, max_guest_port });
    };
    if (parsed == 0 or parsed > max_guest_port) {
        failCliSetup("{s} must be an integer from 1 to {d}", .{ name, max_guest_port });
    }
    return parsed;
}

fn parseSharedOption(shared: *SharedOptions, args: []const []const u8, i: *usize) !bool {
    const name = args[i.*];
    if (std.mem.eql(u8, name, "--kernel")) {
        shared.kernel_path = takeValue(args, i, name);
    } else if (std.mem.eql(u8, name, "--initrd")) {
        shared.initrd_path = takeValue(args, i, name);
    } else if (std.mem.eql(u8, name, "--memory")) {
        shared.memory.initial_bytes = parseMemoryBytes(name, takeValue(args, i, name));
        if (!shared.max_memory_set) shared.memory.maximum_bytes = shared.memory.initial_bytes;
        shared.memory_set = true;
    } else if (std.mem.eql(u8, name, "--max-memory")) {
        shared.memory.maximum_bytes = parseMemoryBytes(name, takeValue(args, i, name));
        shared.max_memory_set = true;
    } else if (std.mem.eql(u8, name, "--memory-mib")) {
        failCliSetup("spore run: --memory-mib has been replaced by --memory", .{});
    } else if (std.mem.eql(u8, name, "--vcpus")) {
        shared.vcpus = parseVcpuCountOrExit(name, takeValue(args, i, name));
    } else if (std.mem.eql(u8, name, "--guest-port")) {
        shared.guest_port = try parseGuestPort(name, takeValue(args, i, name));
    } else if (std.mem.eql(u8, name, "--timeout")) {
        shared.timeout_ms = parseDurationMsOrExit(name, takeValue(args, i, name));
    } else if (std.mem.eql(u8, name, "--timeout-ms")) {
        shared.timeout_ms = try parsePositive(u64, name, takeValue(args, i, name));
    } else if (std.mem.eql(u8, name, "--console-log")) {
        shared.console_log_path = takeValue(args, i, name);
    } else {
        return false;
    }
    return true;
}

fn takeValue(args: []const []const u8, i: *usize, name: []const u8) []const u8 {
    if (i.* + 1 >= args.len) {
        failCliSetup("{s} requires a value", .{name});
    }
    i.* += 1;
    return args[i.*];
}

test "run request encodes env for run from spore command" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const request = try execRequestForRun(.{ .io = std.testing.io, .environ_map = &env }, std.testing.allocator, .{
        .machine = .{ .from = .{ .dir = "base.spore" } },
        .command = &.{"/usr/bin/env"},
        .guest_env = &.{"SPORE_TEST_ENV=ok"},
    }, false);
    defer std.testing.allocator.free(request.bytes);
    defer std.testing.allocator.free(request.session_id);
    try std.testing.expect(std.mem.indexOf(u8, request.bytes, "\"env\":[\"SPORE_TEST_ENV=ok\"]") != null);
}

test "local image supplies run env, working directory and rootfs identity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const cache_root = try tmp_dir.path("cache");
    try Io.Dir.cwd().createDirPath(io, cache_root);

    const rootfs_path = try tmp_dir.path("rootfs.ext4");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = (test_support.repeat("abcd", 1024)) ++ (test_support.repeat("efgh", 1024)) });
    const preload = try rootfs_cas.preloadPath(io, arena, cache_root, rootfs_path, rootfs_cas.default_chunk_size);
    const storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload);
    var image_env = [_][]const u8{ "GEM_HOME=/usr/local/bundle", "BUNDLE_APP_CONFIG=/usr/local/bundle" };
    var entrypoint = [_][]const u8{"/usr/bin/env"};
    var cmd = [_][]const u8{ "bundle", "exec" };
    const published = try local_image.lockAndPublish(io, arena, cache_root, .{
        .platform = rootfs_input.direct_image_platform,
        .config = .{ .config = .{ .Env = &image_env, .Entrypoint = &entrypoint, .Cmd = &cmd, .WorkingDir = "/app", .User = "1000:1000" } },
        .storage = storage,
        .name = "local/buildkite-spore:ci",
    });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_root);
    var process_arena = std.heap.ArenaAllocator.init(allocator);
    defer process_arena.deinit();
    const init = std.process.Init{
        .minimal = undefined,
        .arena = &process_arena,
        .gpa = allocator,
        .io = io,
        .environ_map = &env,
        .preopens = .empty,
    };

    const result = try rootfs_input.resolveRootfsInputDetailedResult(init, arena, .{
        .rootfs_path = null,
        .image_ref = "local/buildkite-spore:ci",
        .command_name = "run",
        .record_artifact = true,
    });
    const input = switch (result) {
        .resolved => |resolved| resolved,
        .failure => return error.ExpectedLocalImage,
    };
    try std.testing.expectEqual(@as(usize, 2), input.guest_env.len);
    try std.testing.expectEqualStrings("GEM_HOME=/usr/local/bundle", input.guest_env[0]);
    try std.testing.expectEqualStrings("BUNDLE_APP_CONFIG=/usr/local/bundle", input.guest_env[1]);
    try std.testing.expectEqualStrings("/app", input.guest_working_dir.?);
    try std.testing.expectEqual(rootfs_input.direct_image_platform.arch, input.image_config.?.architecture.?);
    try std.testing.expectEqualStrings("/usr/bin/env", input.image_config.?.config.?.Entrypoint.?[0]);
    try std.testing.expectEqualStrings("1000:1000", input.image_config.?.config.?.User.?);

    // A save records what the mutable local tag resolved to.
    const rootfs = input.rootfs.?;
    try std.testing.expectEqualStrings(published.resolved_ref, rootfs.source.?.requested_ref);
    try std.testing.expectEqualStrings(published.resolved_ref, rootfs.source.?.resolved_image_ref);
    try std.testing.expectEqualStrings(published.identity, rootfs.source.?.image_manifest_digest);
    try std.testing.expectEqualStrings(storage.index_digest, rootfs.artifact.digest);
    try std.testing.expectEqualStrings(storage.index_digest, rootfs.storage.?.index_digest);
    try std.testing.expect((runtime_disk_mod.Options{ .rootfs_path = input.path, .rootfs = input.rootfs }).rootfsWritable());
}

fn resolveStoreRefForTest(init: std.process.Init, allocator: std.mem.Allocator, options: rootfs_input.RootfsInputOptions) !rootfs_input.ResolvedRootfsInput {
    return switch (try rootfs_input.resolveRootfsInputDetailedResult(init, allocator, options)) {
        .resolved => |resolved| resolved,
        .failure => |failure| {
            std.debug.print("store ref failed: {s}\n", .{failure.message});
            return error.ExpectedStoreImage;
        },
    };
}

test "a store image runs lazily from an empty cache and fails closed without its objects" {
    var fixture: image_store.TestImage = undefined;
    try fixture.init(rootfs_input.direct_image_platform);
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const store = try fixture.path("store");
    _ = try fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/1", .{store}));
    try fixture.env.put(local_paths.rootfs_cache_env, try fixture.path("consumer-cache"));
    const consumer = fixture.env.get(local_paths.rootfs_cache_env).?;
    const ref = try std.fmt.allocPrint(allocator, "file://{s}/1", .{store});

    const resolved = try resolveStoreRefForTest(fixture.processInit(), allocator, .{
        .rootfs_path = null,
        .image_ref = ref,
        .command_name = "run",
        .record_artifact = true,
    });
    try std.testing.expectEqualStrings(fixture.identity, resolved.rootfs.?.source.?.image_manifest_digest);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "file://{s}/{s}", .{ store, fixture.identity }), resolved.rootfs.?.source.?.resolved_image_ref);

    const context = Context{ .io = io, .environ_map = &fixture.env };
    var runtime = try runtime_disk_mod.open(context, std.testing.allocator, .{ .rootfs = resolved.rootfs });
    {
        defer runtime.deinit();
        const disk = &runtime.chunk_mapped.?;
        // A read of chunk 0 also fetches the objects of the chunks after it;
        // chunk 1 is zero.
        var block: [512]u8 = undefined;
        try disk.readAt(&block, 0);
        try image_store.awaitWindows(runtime.fetcher.?);
        var stats = runtime.fetcher.?.currentStats();
        try std.testing.expectEqual(@as(u64, 3), stats.fetches);
        try std.testing.expectEqual(@as(u64, 2), stats.window_fetches);
        try std.testing.expectEqual(@as(u64, 2), stats.window_unused);
        const readback = try allocator.alloc(u8, fixture.rootfs_bytes.len);
        try disk.readAt(readback, 0);
        try std.testing.expectEqualSlices(u8, fixture.rootfs_bytes, readback);
        stats = runtime.fetcher.?.currentStats();
        try std.testing.expectEqual(@as(u64, 3), stats.fetches);
        try std.testing.expectEqual(@as(u64, 0), stats.window_unused);
        try std.testing.expectEqual(@as(u64, 0), stats.install_errors);
    }
    // Every object is local now, so the next run fetches nothing.
    try std.testing.expect(try rootfs_cas.storageContentComplete(io, allocator, consumer, resolved.rootfs.?.storage.?));
    var warm = try runtime_disk_mod.open(context, std.testing.allocator, .{ .rootfs = resolved.rootfs });
    {
        defer warm.deinit();
        const readback = try allocator.alloc(u8, fixture.rootfs_bytes.len);
        try warm.chunk_mapped.?.readAt(readback, 0);
        try std.testing.expectEqualSlices(u8, fixture.rootfs_bytes, readback);
        try std.testing.expectEqual(@as(u64, 0), warm.fetcher.?.stats.fetches);
    }

    // A store object with other bytes, or none, fails the read and poisons
    // the head; nothing reaches the local CAS.
    for ([_]bool{ true, false }) |corrupt| {
        const cache = try fixture.path(if (corrupt) "corrupt-cache" else "missing-cache");
        try fixture.env.put(local_paths.rootfs_cache_env, cache);
        const cold = try resolveStoreRefForTest(fixture.processInit(), allocator, .{
            .rootfs_path = null,
            .image_ref = ref,
            .command_name = "run",
        });
        for (try fixture.listStore(store)) |file| {
            if (!std.mem.startsWith(u8, file, "objects/")) continue;
            const object_path = try std.fs.path.join(allocator, &.{ store, file });
            if (corrupt) {
                const bytes = try std.Io.Dir.cwd().readFileAlloc(io, object_path, allocator, .limited(rootfs_cas.default_chunk_size + 1));
                bytes[0] ^= 1;
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = object_path, .data = bytes });
            } else {
                try std.Io.Dir.cwd().deleteFile(io, object_path);
            }
        }
        var failing = try runtime_disk_mod.open(context, std.testing.allocator, .{ .rootfs = cold.rootfs });
        defer failing.deinit();
        var block: [512]u8 = undefined;
        try std.testing.expectError(if (corrupt) error.BadChunk else error.MissingChunk, failing.chunk_mapped.?.readAt(&block, 0));
        try std.testing.expect(failing.chunk_mapped.?.isPoisoned());
        try image_store.awaitWindows(failing.fetcher.?);
        const errors = failing.fetcher.?.currentStats().errors;
        try std.testing.expect(errors >= 1);
        // A poisoned disk does not ask the store again for another object.
        try std.testing.expectError(error.Poisoned, failing.chunk_mapped.?.readAt(&block, 2 * rootfs_cas.default_chunk_size));
        try std.testing.expectEqual(errors, failing.fetcher.?.currentStats().errors);
        try std.testing.expect(!try rootfs_cas.storageContentComplete(io, allocator, cache, cold.rootfs.?.storage.?));
        const objects_dir = try std.fs.path.join(allocator, &.{ cache, "cas", "rootfs", "blake3", "objects" });
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, objects_dir, .{}));
    }
}

test "a snapshot of a store image's disk first fetches every missing object, and fails cleanly without one" {
    var fixture: image_store.TestImage = undefined;
    try fixture.init(rootfs_input.direct_image_platform);
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const store = try fixture.path("store");
    _ = try fixture.pushTo(try std.fmt.allocPrint(allocator, "{s}/1", .{store}));
    const cache = try fixture.path("consumer-cache");
    try fixture.env.put(local_paths.rootfs_cache_env, cache);
    const resolved = try resolveStoreRefForTest(fixture.processInit(), allocator, .{
        .rootfs_path = null,
        .image_ref = try std.fmt.allocPrint(allocator, "file://{s}/1", .{store}),
        .command_name = "run",
    });
    const storage = resolved.rootfs.?.storage.?;

    var runtime = try runtime_disk_mod.open(.{ .io = io, .environ_map = &fixture.env }, std.testing.allocator, .{ .rootfs = resolved.rootfs });
    defer runtime.deinit();
    const disk = &runtime.chunk_mapped.?;

    // The store lost an object. The snapshot fails before it writes anything
    // and does not poison the disk.
    var lost: ?[]const u8 = null;
    for (try fixture.listStore(store)) |file| {
        if (std.mem.startsWith(u8, file, "objects/blake3/")) lost = try std.fs.path.join(allocator, &.{ store, file });
    }
    const hidden = try fixture.path("hidden");
    try std.Io.Dir.renameAbsolute(lost.?, hidden, io);
    const failed_dir = try fixture.path("failed-snapshot");
    try std.testing.expectError(error.ImageStoreIncomplete, disk.snapshotIndex(failed_dir, .{ .mmio_slot = 1 }, true));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, failed_dir, .{}));
    try std.testing.expect(!disk.isPoisoned());

    // With the object back, the snapshot fetches the rest and names only
    // local objects, and the disk reads on.
    try std.Io.Dir.renameAbsolute(hidden, lost.?, io);
    const snapshot = try disk.snapshotIndex(try fixture.path("snapshot"), .{ .mmio_slot = 1 }, true);
    defer {
        std.testing.allocator.free(snapshot.kind);
        std.testing.allocator.free(snapshot.device.kind);
        std.testing.allocator.free(snapshot.device.role);
        std.testing.allocator.free(snapshot.base);
        std.testing.allocator.free(snapshot.hash_algorithm);
        std.testing.allocator.free(snapshot.object_namespace);
    }
    try std.testing.expectEqual(@as(u64, 3), runtime.fetcher.?.stats.fetches);
    try std.testing.expect(try rootfs_cas.storageContentComplete(io, allocator, cache, storage));
    const snapshot_storage = try runtime_disk_mod.storageFromSnapshotDisk(allocator, snapshot);
    try std.testing.expect(try rootfs_cas.storageContentComplete(io, allocator, try fixture.path("snapshot"), snapshot_storage));
    const readback = try allocator.alloc(u8, fixture.rootfs_bytes.len);
    try disk.readAt(readback, 0);
    try std.testing.expectEqualSlices(u8, fixture.rootfs_bytes, readback);
}

test "guest requests reject an empty program name before the guest sees them" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.RunProgramEmpty, rootfs_input.resolveImageRuntimeCommand(allocator, null, &.{ "", "arg" }));
    try std.testing.expectError(error.RunProgramEmpty, guest_request.execRequestWithSession(allocator, &.{""}, "default", 0));
    try std.testing.expectError(error.RunProgramEmpty, guest_request.interactiveExecRequestWithSession(allocator, &.{""}, "lifecycle-1", .{}));
    try std.testing.expectError(error.RunProgramEmpty, guest_request.detachedExecRequestWithSessionContext(allocator, &.{""}, "lifecycle-1", .{}));
    const later_empty = try guest_request.execRequestWithSession(allocator, &.{ "/bin/echo", "" }, "default", 0);
    allocator.free(later_empty);
    try std.testing.expectEqual(machine_output.ErrorCode.usage_invalid_argument, events_mod.classifyFailure(error.RunProgramEmpty).code);
}

fn testDiskGuardManifest(with_disk: bool) spore.Manifest {
    return .{
        .platform = .{
            .cpu_profile = "test",
            .device_model_version = 1,
            .vcpu_count = 1,
            .ram_base = 0x8000_0000,
            .ram_size = 4096,
            .gic_dist_base = 0x0800_0000,
            .gic_redist_base = 0x0801_0000,
            .gic_redist_stride = 0x2_0000,
            .counter_frequency_hz = 24_000_000,
        },
        .machine = .{ .single = .{
            .gprs = @splat(0),
            .pc = 0,
            .cpsr = 0,
            .fpcr = 0,
            .fpsr = 0,
            .simd = @splat(.{ 0, 0 }),
            .sys_regs = &.{},
            .icc_regs = &.{},
            .vtimer = .{ .cntvct = 0, .cntv_ctl = 0, .cntv_cval = 0 },
            .gic = .{
                .kind = .gicv3,
                .gicv3 = .{
                    .dist_regs = &.{},
                    .redist_regs = &.{},
                    .line_levels = &.{},
                },
            },
        } },
        .devices = &.{},
        .generation = .{ .generation = 0, .interrupt_status = 0, .params_b64 = "" },
        .disk = if (with_disk) .{
            .device = .{ .mmio_slot = 0 },
            .size = 4096,
            .base = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        } else null,
        .memory = .{ .logical_size = 4096, .chunk_size = spore.chunk_size, .zero_ranges = &.{.{ .start = 0, .count = 1 }} },
    };
}

test "run from carries writable disk manifests into runtime options" {
    try std.testing.expect((try rootfs_input.resumeDiskForRun(std.testing.allocator, testDiskGuardManifest(false))) == null);
    const disk = (try rootfs_input.resumeDiskForRun(std.testing.allocator, testDiskGuardManifest(true))).?;
    defer {
        std.testing.allocator.free(disk.kind);
        std.testing.allocator.free(disk.device.kind);
        std.testing.allocator.free(disk.device.role);
        std.testing.allocator.free(disk.base);
        std.testing.allocator.free(disk.hash_algorithm);
        std.testing.allocator.free(disk.object_namespace);
    }
    try std.testing.expectEqualStrings("blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", disk.base);
}

test "a run that fails before its VM starts leaves no save directory behind" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const cache_root = try tmp_dir.path("cache");
    try Io.Dir.cwd().createDirPath(io, cache_root);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put(local_paths.rootfs_cache_env, cache_root);
    const save_path = try tmp_dir.path("out.spore");

    // arm64 fails to open the root disk; x86 refuses the capture first. Both
    // fail after the save directory exists.
    const expected = if (builtin.cpu.arch == .x86_64) error.X86CaptureUnsupported else error.RootFSOpenFailed;
    try std.testing.expectError(expected, execute(.{ .io = io, .environ_map = &env }, arena_state.allocator(), .{
        .machine = .{ .boot = .{
            .assets = .{ .managed = .{ .kernel = "kernel", .initrd = "initrd" } },
            .rootfs_path = try tmp_dir.path("missing.ext4"),
        } },
        .command = &.{"true"},
        .memory = memory_config.Config.fixed(vm_session.x86_experimental_memory_bytes),
        .save = .{ .dir = save_path },
    }));
    // A second `--save` to the same path would otherwise fail AlreadyExists.
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, save_path, .{}));
}

test "run cli parser accepts command after separator" {
    const opts = try parseCliArgs(std.testing.allocator, &.{ "--backend", "hvf", "--kernel", "Image", "--initrd", "root.cpio", "--", "/bin/true" });
    try std.testing.expectEqual(Backend.hvf, opts.backend);
    try std.testing.expectEqualStrings("Image", opts.shared.kernel_path.?);
    try std.testing.expectEqualStrings("root.cpio", opts.shared.initrd_path.?);
    try std.testing.expectEqual(cli_args.CommandMode.argv, opts.command_mode);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("/bin/true", opts.command[0]);
}

test "run cli parser accepts flexible timeout duration" {
    const opts = try parseCliArgs(std.testing.allocator, &.{ "--timeout", "120s", "--", "/bin/true" });
    try std.testing.expectEqual(@as(u64, 120_000), opts.shared.timeout_ms);
}

test "run cli parser accepts hidden timeout-ms compatibility spelling" {
    const opts = try parseCliArgs(std.testing.allocator, &.{ "--timeout-ms", "120000", "--", "/bin/true" });
    try std.testing.expectEqual(@as(u64, 120_000), opts.shared.timeout_ms);
}

test "run cli parser accepts injected files" {
    const opts = try parseCliArgs(std.testing.allocator, &.{ "--inject", "config=host-config.json", "--", "/bin/true" });
    try std.testing.expectEqual(@as(usize, 1), opts.injected_file_sources.len);
    try std.testing.expectEqualStrings("config", opts.injected_file_sources.items[0].id);
    try std.testing.expectEqualStrings("host-config.json", opts.injected_file_sources.items[0].path);
}

test "run cli parser accepts repeatable env specs" {
    const opts = try parseCliArgs(std.testing.allocator, &.{ "--env", "SPORE_TEST_ENV=ok", "--env", "HOST_ENV", "--", "/usr/bin/env" });
    try std.testing.expectEqual(@as(usize, 2), opts.guest_env_specs.len);
    try std.testing.expectEqualStrings("SPORE_TEST_ENV=ok", opts.guest_env_specs.items[0].literal);
    try std.testing.expectEqualStrings("HOST_ENV", opts.guest_env_specs.items[1].copy);
}

test "run cli parser accepts interactive stdin" {
    const opts = try parseCliArgs(std.testing.allocator, &.{ "-i", "--image", "docker.io/library/alpine:3.20", "--", "/bin/cat" });
    try std.testing.expect(opts.interactive);
    try std.testing.expect(!opts.tty);
    try std.testing.expectEqual(cli_args.CommandMode.argv, opts.command_mode);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("/bin/cat", opts.command[0]);
}

test "run cli parser accepts tty and combined interactive tty" {
    const tty_opts = try parseCliArgs(std.testing.allocator, &.{ "-t", "--image", "docker.io/library/alpine:3.20", "--", "/bin/sh" });
    try std.testing.expect(!tty_opts.interactive);
    try std.testing.expect(tty_opts.tty);
    try std.testing.expectEqual(cli_args.CommandMode.argv, tty_opts.command_mode);
    try std.testing.expectEqualStrings("/bin/sh", tty_opts.command[0]);

    const it_opts = try parseCliArgs(std.testing.allocator, &.{ "-it", "--image", "docker.io/library/alpine:3.20", "--", "/bin/sh" });
    try std.testing.expect(it_opts.interactive);
    try std.testing.expect(it_opts.tty);
    try std.testing.expectEqual(cli_args.CommandMode.argv, it_opts.command_mode);
    try std.testing.expectEqualStrings("/bin/sh", it_opts.command[0]);
}

test "run cli parser accepts shell command with source spore" {
    const opts = try parseCliArgs(std.testing.allocator, &.{ "--from", "base.spore", "cat /work-ready" });
    try std.testing.expectEqualStrings("base.spore", opts.from_spore_dir.?);
    try std.testing.expectEqual(cli_args.CommandMode.shell, opts.command_mode);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("cat /work-ready", opts.command[0]);
}

test "run cli parser accepts commandless source spore" {
    const opts = try parseCliArgs(std.testing.allocator, &.{ "--from", "live.spore" });
    try std.testing.expectEqualStrings("live.spore", opts.from_spore_dir.?);
    try std.testing.expectEqual(cli_args.CommandMode.shell, opts.command_mode);
    try std.testing.expectEqual(@as(usize, 0), opts.command.len);
}

test "run cli guest command wraps shell command" {
    const opts = try parseCliArgs(std.testing.allocator, &.{ "--image", "docker.io/library/alpine:3.20", "echo hi" });
    const argv = try cliGuestCommand(std.testing.allocator, opts);
    defer std.testing.allocator.free(argv);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("/bin/sh", argv[0]);
    try std.testing.expectEqualStrings("-lc", argv[1]);
    try std.testing.expectEqualStrings("echo hi", argv[2]);
}

test "run cli guest command keeps exact argv" {
    const opts = try parseCliArgs(std.testing.allocator, &.{ "--image", "docker.io/library/alpine:3.20", "--", "/bin/echo", "hi" });
    const argv = try cliGuestCommand(std.testing.allocator, opts);
    try std.testing.expectEqual(@as(usize, 2), argv.len);
    try std.testing.expectEqualStrings("/bin/echo", argv[0]);
    try std.testing.expectEqualStrings("hi", argv[1]);
}

test "run cli guest command rejects unquoted shell words" {
    const opts = try parseCliArgs(std.testing.allocator, &.{ "--image", "docker.io/library/alpine:3.20", "echo", "hi" });
    try std.testing.expectError(error.ShellCommandArgumentCountUnsupported, cliGuestCommand(std.testing.allocator, opts));
}

test "run cli parser defaults to fixed 512MiB" {
    const opts = try parseCliArgs(std.testing.allocator, &.{ "--", "/bin/writeout" });
    try std.testing.expectEqual(Backend.auto, opts.backend);
    try std.testing.expect(opts.shared.kernel_path == null);
    try std.testing.expect(opts.shared.initrd_path == null);
    try std.testing.expectEqual(memory_config.default_bytes, opts.shared.memory.initial_bytes);
    try std.testing.expectEqual(memory_config.default_bytes, opts.shared.memory.maximum_bytes);
    try std.testing.expectEqual(cli_args.CommandMode.argv, opts.command_mode);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("/bin/writeout", opts.command[0]);
}

test "run cli parser separates initial and maximum memory" {
    const fixed = try parseCliArgs(std.testing.allocator, &.{ "--memory", "2gb", "--", "/bin/true" });
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024 * 1024), fixed.shared.memory.initial_bytes);
    try std.testing.expectEqual(fixed.shared.memory.initial_bytes, fixed.shared.memory.maximum_bytes);

    const elastic = try parseCliArgs(std.testing.allocator, &.{ "--memory", "512mb", "--max-memory", "16gb", "--", "/bin/true" });
    try std.testing.expectEqual(memory_config.default_bytes, elastic.shared.memory.initial_bytes);
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024 * 1024), elastic.shared.memory.maximum_bytes);

    const default_initial = try parseCliArgs(std.testing.allocator, &.{ "--max-memory", "16gb", "--", "/bin/true" });
    try std.testing.expectEqual(memory_config.default_bytes, default_initial.shared.memory.initial_bytes);
    try std.testing.expectEqual(elastic.shared.memory.maximum_bytes, default_initial.shared.memory.maximum_bytes);
}

test "run cli parser accepts rootfs path" {
    const opts = try parseCliArgs(std.testing.allocator, &.{ "--rootfs", "rootfs.ext4", "--", "/bin/echo", "hi" });
    try std.testing.expectEqualStrings("rootfs.ext4", opts.rootfs_path.?);
    try std.testing.expectEqual(@as(usize, 2), opts.command.len);
    try std.testing.expectEqualStrings("/bin/echo", opts.command[0]);
    try std.testing.expectEqualStrings("hi", opts.command[1]);
}

test "run cli parser accepts image ref" {
    const opts = try parseCliArgs(std.testing.allocator, &.{ "--image", "docker.io/library/alpine:3.20", "--", "/bin/echo", "hi" });
    try std.testing.expect(opts.rootfs_path == null);
    try std.testing.expectEqualStrings("docker.io/library/alpine:3.20", opts.image_ref.?);
    try std.testing.expectEqual(rootfs_input.PullPolicy.missing, opts.pull_policy);
    try std.testing.expectEqual(cli_args.CommandMode.argv, opts.command_mode);
    try std.testing.expectEqual(@as(usize, 2), opts.command.len);
    try std.testing.expectEqualStrings("/bin/echo", opts.command[0]);
    try std.testing.expectEqualStrings("hi", opts.command[1]);
}

test "run cli parser accepts image entrypoint override" {
    const opts = try parseCliArgs(std.testing.allocator, &.{ "--image", "local/example:dev", "--entrypoint", "/scanner", "--", "/runtime" });
    try std.testing.expectEqualStrings("/scanner", opts.image_entrypoint.?);
    try std.testing.expectEqualSlices([]const u8, &.{"/runtime"}, opts.command);
}

test "run cli parser permits omitted command only for images" {
    const opts = try parseCliArgs(std.testing.allocator, &.{ "--image", "docker.io/library/alpine:3.20" });
    try std.testing.expectEqual(@as(usize, 0), opts.command.len);
}

test "run cli parser accepts image commit" {
    const opts = try parseCliArgs(std.testing.allocator, &.{
        "--image",
        "docker.io/library/alpine:3.20",
        "--commit",
        "local/example:prepared",
        "--inject",
        "setup=prepare.sh",
        "--",
        "/bin/sh",
        "/run/sporevm/injected/setup",
    });
    try std.testing.expectEqualStrings("local/example:prepared", opts.commit_ref.?);
    try std.testing.expectEqual(@as(usize, 1), opts.injected_file_sources.len);
    try std.testing.expectEqualStrings("/bin/sh", opts.command[0]);
}

test "run cli parser accepts commit disk size" {
    const opts = try parseCliArgs(std.testing.allocator, &.{
        "--image",
        "docker.io/library/alpine:3.20",
        "--commit",
        "local/example:prepared",
        "--disk-size",
        "20gb",
        "--",
        "/bin/true",
    });
    try std.testing.expectEqual(@as(?u64, 20 * 1024 * 1024 * 1024), opts.disk_size);
}

test "run disk size is absolute and cannot shrink" {
    try std.testing.expectEqual(@as(u64, 0), try rootfsGrowTarget(4 * 1024 * 1024, 4 * 1024 * 1024));
    try std.testing.expectEqual(@as(u64, 8 * 1024 * 1024), try rootfsGrowTarget(4 * 1024 * 1024, 8 * 1024 * 1024));
    try std.testing.expectError(error.RunDiskSizeWouldShrink, rootfsGrowTarget(8 * 1024 * 1024, 4 * 1024 * 1024));
}

test "run cli parser accepts image pull policy" {
    const equals_opts = try parseCliArgs(std.testing.allocator, &.{ "--pull=always", "--image", "docker.io/library/alpine:3.20", "--", "/bin/true" });
    try std.testing.expectEqual(rootfs_input.PullPolicy.always, equals_opts.pull_policy);

    const value_opts = try parseCliArgs(std.testing.allocator, &.{ "--image", "docker.io/library/alpine:3.20", "--pull", "never", "--", "/bin/true" });
    try std.testing.expectEqual(rootfs_input.PullPolicy.never, value_opts.pull_policy);
}

test "run cli parser accepts source spore generation file" {
    const opts = try parseCliArgs(std.testing.allocator, &.{ "--from", "base.spore", "--generation", "generation.json", "--", "/bin/writeout" });
    try std.testing.expectEqualStrings("base.spore", opts.from_spore_dir.?);
    try std.testing.expectEqualStrings("generation.json", opts.generation_path.?);
    try std.testing.expectEqual(cli_args.CommandMode.argv, opts.command_mode);
    try std.testing.expectEqualStrings("/bin/writeout", opts.command[0]);

    const equals_opts = try parseCliArgs(std.testing.allocator, &.{ "--from", "base.spore", "--generation=generation.json", "--", "/bin/writeout" });
    try std.testing.expectEqualStrings("generation.json", equals_opts.generation_path.?);
}

test "run cli parser accepts source spore bound service bindings" {
    const opts = try parseCliArgs(std.testing.allocator, &.{
        "--from",
        "base.spore",
        "--bind-service",
        "metadata=unix:/tmp/metadata.sock",
    });
    try std.testing.expectEqualStrings("base.spore", opts.from_spore_dir.?);
    try std.testing.expectEqual(@as(usize, 1), opts.bound_services.len);
    try std.testing.expectEqualStrings("metadata", opts.bound_services.items[0].name);
    try std.testing.expectEqualStrings("/tmp/metadata.sock", opts.bound_services.items[0].target.unix);
    try std.testing.expectEqual(spore_net_policy.NetworkMode.disabled, opts.network);
}

test "run cli parser keeps plain --net unrestricted and allow rules restrict it" {
    const plain = try parseCliArgs(std.testing.allocator, &.{ "--net", "--", "/bin/true" });
    try std.testing.expect(plain.network.spore.egress == .unrestricted);
    try std.testing.expect(!plain.network.spore.hasRules());

    const restricted = try parseCliArgs(std.testing.allocator, &.{ "--net", "--allow-cidr", "93.184.216.34/32", "--", "/bin/true" });
    try std.testing.expect(restricted.network.spore.egress == .allowlist);
    try std.testing.expectEqualStrings("93.184.216.34/32", restricted.network.spore.allowCidrSlice()[0]);

    const disabled = try parseCliArgs(std.testing.allocator, &.{ "--", "/bin/true" });
    try std.testing.expectEqual(spore_net_policy.NetworkMode.disabled, disabled.network);
}

test "run cli parser accepts network allow rules" {
    const opts = try parseCliArgs(std.testing.allocator, &.{
        "--net",
        "--allow-cidr",
        "93.184.216.34/32",
        "--allow-host",
        "example.com",
        "--",
        "/bin/true",
    });
    const policy = &opts.network.spore;
    try std.testing.expect(policy.egress == .allowlist);
    try std.testing.expectEqual(@as(usize, 1), policy.allowCidrSlice().len);
    try std.testing.expectEqualStrings("93.184.216.34/32", policy.allowCidrSlice()[0]);
    try std.testing.expectEqual(@as(usize, 1), policy.allowHostSlice().len);
    try std.testing.expectEqualStrings("example.com", policy.allowHostSlice()[0]);
    try std.testing.expectEqualStrings("/bin/true", opts.command[0]);
}

test "run cli parser accepts network bind services" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const opts = try parseCliArgs(arena.allocator(), &.{
        "--net",
        "--bind-service",
        "metadata=unix:/tmp/metadata.sock",
        "--bind-service",
        "cache:8080=unix:/tmp/cache.sock",
        "--",
        "/bin/true",
    });
    const policy = &opts.network.spore;
    try std.testing.expect(policy.egress == .unrestricted);
    const services = policy.boundServiceSlice();
    try std.testing.expectEqual(@as(usize, 2), services.len);
    try std.testing.expectEqualStrings("metadata", services[0].name);
    try std.testing.expectEqualStrings("metadata.spore.internal", services[0].guest_host);
    try std.testing.expectEqualStrings("/tmp/metadata.sock", services[0].unix_path);
    try std.testing.expectEqualStrings("cache", services[1].name);
    try std.testing.expectEqual(@as(u16, 8080), services[1].guest_port);
    try std.testing.expectEqualStrings("/tmp/cache.sock", services[1].unix_path);
}

test "run cli parser accepts network port forwards" {
    const opts = try parseCliArgs(std.testing.allocator, &.{
        "--net",
        "--forward",
        "127.0.0.1:8080:80",
        "--",
        "/bin/true",
    });
    const forwards = opts.network.spore.portForwardSlice();
    try std.testing.expectEqual(@as(usize, 1), forwards.len);
    try std.testing.expectEqual(@as(u16, 8080), forwards[0].host_port);
    try std.testing.expectEqual(@as(u16, 80), forwards[0].guest_port);
}

test "run network gateway errors are reported clearly" {
    try std.testing.expect(isNetworkGatewayError(error.NetdSpawnFailed));
    try std.testing.expect(isNetworkGatewayError(error.NetdReadyTimedOut));
    try std.testing.expect(isNetworkGatewayError(error.NetdReadyFailed));
    try std.testing.expect(isNetworkGatewayError(error.NetdThreadFailed));
    try std.testing.expect(isNetworkGatewayError(error.NetworkGatewayFailed));
    try std.testing.expect(!isNetworkGatewayError(error.UnsupportedBackend));
}

test "removed capture flags map to save rename hints" {
    try std.testing.expectEqualStrings("--save DIR", renamedRunFlagHint("--capture").?);
    try std.testing.expectEqualStrings("--save-on WHEN", renamedRunFlagHint("--capture-on").?);
    try std.testing.expectEqualStrings("--continue-after-save", renamedRunFlagHint("--continue-after-capture").?);
    try std.testing.expect(renamedRunFlagHint("--save") == null);
    try std.testing.expect(renamedRunFlagHint("--unknown") == null);
}

test "run cli parser accepts save flags" {
    const opts = try parseCliArgs(std.testing.allocator, &.{ "--save", "out.spore", "--save-on", "USR1", "--continue-after-save", "--", "/bin/sleeper" });
    try std.testing.expectEqualStrings("out.spore", opts.save_path.?);
    switch (opts.save_trigger) {
        .signal => |signal| try std.testing.expectEqual(capture.Signal.USR1, signal),
        .exit => return error.TestUnexpectedResult,
    }
    try std.testing.expect(opts.continue_after_save);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("/bin/sleeper", opts.command[0]);
}

test "run cli parser accepts bounded vcpu count" {
    const opts = try parseCliArgs(std.testing.allocator, &.{ "--vcpus", "2", "--", "/bin/true" });
    try std.testing.expectEqual(@as(topology.VcpuCount, 2), opts.shared.vcpus);
}

test "run cli parser defaults save trigger to exit" {
    const opts = try parseCliArgs(std.testing.allocator, &.{ "--save", "out.spore", "--", "/bin/true" });
    try std.testing.expectEqualStrings("out.spore", opts.save_path.?);
    try std.testing.expect(opts.save_trigger.isExit());
    try std.testing.expect(!opts.continue_after_save);
}

test "a fresh run's guest request carries the image's working directory, and a --from request its fan-out identity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const context: Context = .{ .io = std.testing.io, .environ_map = &env };

    var request = Request{
        .machine = .{ .boot = .{ .assets = .{ .files = .{ .kernel = "Image" } }, .working_dir = "/app" } },
        .command = &.{"/bin/true"},
    };
    const fresh = try execRequestForRun(context, arena, request, false);
    try std.testing.expectEqualStrings(spore.default_session_id, fresh.session_id);
    try std.testing.expect(std.mem.indexOf(u8, fresh.bytes, "\"working_dir\":\"/app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fresh.bytes, "\"require_generation_ready\":false") != null);

    request.machine = .{ .from = .{ .dir = "saved.spore", .generation_params = "{\"resume_entropy_seed\":\"abcd\"}" } };
    const from = try execRequestForRun(context, arena, request, false);
    try std.testing.expect(std.mem.startsWith(u8, from.session_id, "run-"));
    try std.testing.expect(std.mem.indexOf(u8, from.bytes, "\"working_dir\":\"\"") != null);
    // The guest applies the identity before the command starts.
    try std.testing.expect(std.mem.indexOf(u8, from.bytes, "\"params_json\":\"{\\\"resume_entropy_seed\\\":\\\"abcd\\\"}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, from.bytes, "\"require_generation_ready\":true") != null);
}

test "save ownership distinguishes disk-backed and diskless captures" {
    const base = Request{ .machine = .{ .boot = .{ .assets = .{ .files = .{ .kernel = "Image" } } } }, .command = &.{} };
    try std.testing.expectEqualStrings(saved_spore_ownership.portable_self_contained, saveOwnership(base));
    var disk_backed = base;
    disk_backed.machine.boot.rootfs_path = "rootfs.ext4";
    try std.testing.expectEqualStrings(saved_spore_ownership.machine_local_pinned, saveOwnership(disk_backed));
}

test "run image cache creates absolute cache directories" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var root_dir = try TestDir.init();
    defer root_dir.deinit();
    const nested = try root_dir.path("a/b");

    const absolute_nested = try std.fs.path.resolve(allocator, &.{nested});
    defer allocator.free(absolute_nested);
    try local_paths.ensureDirPath(io, absolute_nested);
    try Io.Dir.cwd().access(io, nested, .{});
}
