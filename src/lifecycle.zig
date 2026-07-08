//! Named VM lifecycle registry and CLI shape.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;

const Context = @import("context.zig").Context;
const local_paths = @import("local_paths.zig");
const machine_output = @import("machine_output.zig");
const memory_config = @import("memory.zig");
const generation = @import("generation.zig");
const attach_mod = @import("attach.zig");
const run_mod = @import("run.zig");
const spore = @import("spore.zig");
const spore_net_policy = @import("spore_net_policy.zig");
const spore_stream = @import("spore_stream.zig");
const topology = @import("topology.zig");
const version = @import("version.zig");

pub const runtime_dir_env = local_paths.runtime_dir_env;
pub const max_name_len = 128;
pub const monitor_hello_schema = "spore.monitor.hello.v1";
pub const monitor_helper_contract: u32 = 1;
const reexec_role_env = "SPORE_REEXEC_ROLE";
const reexec_contract_env = "SPORE_REEXEC_CONTRACT";
const reexec_contract_value = "1";

const max_metadata_bytes = 128 * 1024;
const max_control_response = 128 * 1024;
const lifecycle_spore_metadata_file = "sporevm-lifecycle.json";
const diskless_resume_device_count = 4;
const spec_file = "spec.json";
const ready_file = "ready.json";
const create_timing_file = "create-timing.json";
const monitor_timing_file = "monitor-timing.json";
const monitor_stats_file = "monitor-stats.json";
const pid_file = "pid";
const control_socket_file = "control.sock";
const console_log_file = "console.log";
const monitor_log_file = "monitor.log";
const monitor_shutdown_grace_ms = 1_000;
const monitor_shutdown_term_ms = 1_000;
const monitor_shutdown_kill_ms = 1_000;
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

fn setLastError(comptime fmt: []const u8, args: anytype) void {
    last_lifecycle_error = std.fmt.bufPrint(&last_lifecycle_error_buf, fmt, args) catch "lifecycle error";
}

const darwin_process = if (builtin.os.tag.isDarwin()) struct {
    const proc_pid_task_info: c_int = 4;

    const TaskInfo = extern struct {
        virtual_size: u64,
        resident_size: u64,
        total_user: u64,
        total_system: u64,
        threads_user: u64,
        threads_system: u64,
        policy: i32,
        faults: i32,
        pageins: i32,
        cow_faults: i32,
        messages_sent: i32,
        messages_received: i32,
        syscalls_mach: i32,
        syscalls_unix: i32,
        csw: i32,
        threadnum: i32,
        numrunning: i32,
        priority: i32,
    };

    extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, buffersize: c_int) c_int;
} else struct {};

const create_usage =
    \\Usage:
    \\  spore create NAME [options] ['shell command']
    \\  spore create NAME [options] -- <argv...>
    \\
    \\Options:
    \\  --backend auto|hvf|kvm  Backend to run (default: auto)
    \\  --kernel Image          Kernel Image path
    \\  --initrd root.cpio      Initrd path (default: embedded minimal exec initrd)
    \\  --rootfs rootfs.ext4    Attach rootfs image read-only as virtio-blk
    \\  --image REF             Build or reuse cached OCI rootfs
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
    \\  --memory VALUE          Guest memory: auto, 512mb, 2gb, ... (default: auto = 16GiB)
    \\  --vcpus N               Guest vCPU count (1-8; backend-dependent)
    \\  --guest-port N          Guest vsock listen port (default: 10700)
    \\  --timeout DURATION      Exec timeout (default: 30s; e.g. 500ms, 1m)
    \\  --console-log PATH      Write guest console output to PATH
    \\  -- <argv...>            Start exact argv instead of /bin/sh -lc
    \\  -h, --help              Show this help
    \\
;

const exec_usage =
    \\Usage:
    \\  spore exec [options] NAME 'shell command'
    \\  spore exec [options] NAME -- <argv...>
    \\
    \\Options:
    \\  -i, --interactive       Keep stdin open and forward it to the guest process
    \\  -t, --tty               Allocate a guest terminal for the process
    \\  -- <argv...>            Run exact argv instead of /bin/sh -lc
    \\  -h, --help              Show this help
    \\
;

const copy_in_usage =
    \\Usage:
    \\  spore copy-in NAME HOST_PATH GUEST_PATH
    \\
    \\Copies one host file or directory into a running named VM. The guest path
    \\must be absolute and must not already exist.
    \\
;

const copy_out_usage =
    \\Usage:
    \\  spore copy-out NAME GUEST_PATH HOST_PATH
    \\
    \\Copies one guest file or directory out of a running named VM. The host path must
    \\not already exist.
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

const save_usage =
    \\Usage:
    \\  spore save NAME --out DIR [--stop]
    \\
    \\Options:
    \\  --out DIR              Write a spore to DIR
    \\  --stop                 Stop and remove the named VM after saving
    \\  --annotation KEY=VALUE Merge an annotation into the spore manifest
    \\  -h, --help             Show this help
    \\
    \\By default save is non-destructive: the named VM keeps running. Use
    \\--stop when you want a consuming save that removes the named VM.
    \\
;

const fork_usage =
    \\Usage:
    \\  spore fork <spore-dir> --count N --out DIR
    \\  spore fork --vm NAME --count N --name PATTERN
    \\
    \\Options:
    \\  --out DIR            Directory for forked spores
    \\  --vm NAME             Running named VM to fork from
    \\  --count N             Number of children to create
    \\  --name PATTERN        Child VM name or pattern, e.g. worker-%d
    \\  -h, --help            Show this help
    \\
    \\Notes:
    \\  Live --vm fork does not support disk-backed, --image, or --rootfs VMs yet.
    \\
    \\Workflow:
    \\  spore run --save base.spore --save-on TERM 'while true; do echo tick; sleep 1; done'
    \\  spore fork base.spore --count 2 --out children
    \\  spore fanout children --for 10s
    \\
;

const restore_usage =
    \\Usage:
    \\  spore restore DIR --name NAME
    \\
    \\Options:
    \\  --backend auto|hvf|kvm  Backend to run (default: saved lifecycle metadata)
    \\  --generation FILE       Inject fan-out identity JSON before restore
    \\  --name NAME            Name for the restored VM
    \\  --bind-service NAME=unix:/path.sock
    \\                         Bind a manifest-declared service to a host socket
    \\  --events=jsonl         Emit lifecycle events as JSONL on stdout
    \\  -h, --help             Show this help
    \\
;

const ls_usage =
    \\Usage:
    \\  spore ls
    \\  spore ps
    \\
    \\Options:
    \\  -h, --help              Show this help
    \\
    \\Machine output:
    \\  spore --json ls         Emit the VM list as JSON
    \\  spore --json ps         Same as ls
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
    monitor_stats_path: []const u8,
    pid_path: []const u8,
    control_socket_path: []const u8,
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
        allocator.free(self.control_socket_path);
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
    network: ?spore.Network = null,
    annotations: spore.Annotations = .{},
    sessions: []const spore.Session = &.{},
    image_ref: ?[]const u8 = null,
    resume_dir: ?[]const u8 = null,
    resume_generation: ?generation.State = null,
    memory: memory_config.Config = .{},
    vcpus: topology.VcpuCount = 1,
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
    memory: ?ListMemory = null,
    stats: ListStats = .{},
};

pub const ListMemory = struct {
    policy: []const u8,
    bytes: u64,
};

pub const ListStats = struct {
    resident_bytes: ?u64 = null,
    backing_logical_bytes: ?u64 = null,
    backing_allocated_bytes: ?u64 = null,
    chunk_size: ?u64 = null,
    chunks_total: ?u64 = null,
    chunks_nonzero: ?u64 = null,
    dirty_chunks_pending: ?u64 = null,
};

pub const MonitorStats = struct {
    chunks_nonzero: ?u64 = null,
    dirty_chunks_pending: ?u64 = null,
};

const ListMetadata = struct {
    memory: ListMemory,
    stats: ListStats,
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
    options_path: ?[]const u8 = null,
    image_pull_policy: run_mod.PullPolicy = .missing,
    network: run_mod.NetworkMode = .disabled,
    network_policy: run_mod.NetworkPolicy = .{},
    command_mode: run_mod.CommandMode = .shell,
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
    vcpus: ?topology.VcpuCount = null,
    guest_port: ?u32 = null,
    timeout_ms: ?u64 = null,
    console_log_path: ?[]const u8 = null,
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
    command_mode: run_mod.CommandMode = .shell,
    command: []const []const u8,
    interactive: bool = false,
    tty: bool = false,
};

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
};

const RestoreOptions = struct {
    spore_dir: []const u8,
    name: []const u8,
    backend: ?run_mod.Backend = null,
    generation_path: ?[]const u8 = null,
    event_mode: run_mod.EventMode = .none,
    bound_services: run_mod.BoundServiceBindingList = .{},
};

pub const NamedForkResult = struct {
    source: []const u8,
    count: usize,
    children: []const []const u8,
};

pub const ForkNamedOptions = struct {
    source_name: []const u8,
    count: usize,
    name_pattern: []const u8,
    spore_executable: []const u8 = "spore",
};

pub const NamedNetworkOptions = struct {
    enabled: bool = false,
    allow_cidrs: []const []const u8 = &.{},
    allow_hosts: []const []const u8 = &.{},
    policy: spore_net_policy.NetworkPolicy = .{},
    bound_services: []const spore_net_policy.BoundService = &.{},
    port_forwards: []const spore_net_policy.PortForwardConfig = &.{},
};

pub const CreateNamedOptions = struct {
    name: []const u8,
    backend: run_mod.Backend = .auto,
    kernel_path: ?[]const u8 = null,
    initrd_path: ?[]const u8 = null,
    rootfs_path: ?[]const u8 = null,
    image_ref: ?[]const u8 = null,
    image_pull_policy: run_mod.PullPolicy = .missing,
    network: NamedNetworkOptions = .{},
    memory: memory_config.Config = .{},
    vcpus: topology.VcpuCount = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    console_log_path: ?[]const u8 = null,
    spore_executable: []const u8 = "spore",
    annotations: spore.Annotations = .{},
};

pub const RestoreNamedOptions = struct {
    spore_dir: []const u8,
    name: []const u8,
    backend: ?run_mod.Backend = null,
    generation_path: ?[]const u8 = null,
    spore_executable: []const u8 = "spore",
    bound_services: []const spore_net_policy.BoundServiceBinding = &.{},
};

pub const ExecNamedOptions = struct {
    name: []const u8,
    command: []const []const u8,
    network_policy: ?spore_net_policy.NetworkPolicy = null,
    interactive: bool = false,
    tty: bool = false,
};

pub const CopyNamedOptions = struct {
    name: []const u8,
    host_path: []const u8,
    guest_path: []const u8,
};

const SaveContinueNamedOptions = struct {
    name: []const u8,
    out_dir: []const u8,
    annotations: spore.Annotations = .{},
};

pub const SaveNamedOptions = struct {
    name: []const u8,
    out_dir: []const u8,
    stop: bool = false,
    annotations: spore.Annotations = .{},
};

pub const RemoveNamedOptions = struct {
    name: []const u8,
};

pub const ListNamedOptions = struct {};

pub const NamedLifecycleResult = struct {
    schema: []const u8 = lifecycle_schema,
    schema_version: u32 = lifecycle_schema_version,
    action: []const u8,
    name: []const u8,
    state: []const u8,
    pid: ?i64 = null,
    console_log_path: ?[]const u8 = null,
    spore_dir: ?[]const u8 = null,
    saved_sessions: ?usize = null,
};

pub const ExecNamedResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
    network_events_jsonl: []u8 = &.{},
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
};

pub const TerminalSize = spore_stream.Resize;

pub const ExecNamedStreamOptions = struct {
    name: []const u8,
    command: []const []const u8,
    interactive: bool = false,
    tty: bool = false,
    terminal_name: []const u8 = "xterm",
    terminal_size: TerminalSize = .{ .rows = 24, .cols = 80 },
};

pub const ExecNamedStreamEvent = union(enum) {
    stdout: []const u8,
    stderr: []const u8,
    terminal: []const u8,
    exit: u8,
    err: []const u8,
};

pub const ExecNamedStream = struct {
    io: Io,
    stream: net.Stream,
    closed: bool = false,
    stdin_offset: u64 = 0,
    terminal_input_offset: u64 = 0,
    stdout_offset: u64 = 0,
    stderr_offset: u64 = 0,
    terminal_offset: u64 = 0,
    payload: [spore_stream.max_payload_len]u8 = undefined,

    pub fn deinit(self: *ExecNamedStream) void {
        if (self.closed) return;
        self.stream.close(self.io);
        self.closed = true;
    }

    /// Return the next output, terminal, exit, or monitor-error frame.
    ///
    /// Byte slices are borrowed from the stream and valid until the next call.
    pub fn next(self: *ExecNamedStream) !ExecNamedStreamEvent {
        while (true) {
            var header_buf: [spore_stream.header_len]u8 = undefined;
            try readFdExact(self.stream.socket.handle, &header_buf);
            const header = try spore_stream.readHeader(&header_buf);
            if (header.flags != 0 or header.payload_len > self.payload.len) return error.BadMonitorResponse;
            const payload = self.payload[0..header.payload_len];
            if (payload.len > 0) try readFdExact(self.stream.socket.handle, payload);
            switch (header.frame_type) {
                .data => {
                    const expected = switch (header.stream_id) {
                        .stdout => self.stdout_offset,
                        .stderr => self.stderr_offset,
                        .terminal => self.terminal_offset,
                        else => return error.BadMonitorResponse,
                    };
                    if (header.offset != expected) return error.BadMonitorResponse;
                    const len: u64 = @intCast(payload.len);
                    switch (header.stream_id) {
                        .stdout => {
                            self.stdout_offset += len;
                            return .{ .stdout = payload };
                        },
                        .stderr => {
                            self.stderr_offset += len;
                            return .{ .stderr = payload };
                        },
                        .terminal => {
                            self.terminal_offset += len;
                            return .{ .terminal = payload };
                        },
                        else => unreachable,
                    }
                },
                .exit => {
                    if (header.stream_id != .control or header.offset != 0) return error.BadMonitorResponse;
                    const code = try spore_stream.readExitPayload(payload);
                    if (code > 255) return error.BadMonitorResponse;
                    return .{ .exit = @intCast(code) };
                },
                .err => {
                    if (header.stream_id != .control) return error.BadMonitorResponse;
                    return .{ .err = payload };
                },
                .event => continue,
                else => return error.BadMonitorResponse,
            }
        }
    }

    pub fn writeStdin(self: *ExecNamedStream, bytes: []const u8) !void {
        try self.writeInputData(.stdin, bytes);
    }

    pub fn writeTerminal(self: *ExecNamedStream, bytes: []const u8) !void {
        try self.writeInputData(.terminal, bytes);
    }

    pub fn closeStdin(self: *ExecNamedStream) !void {
        try self.writeInputFrame(.close, .stdin, "");
    }

    pub fn closeTerminal(self: *ExecNamedStream) !void {
        try self.writeInputFrame(.close, .terminal, "");
    }

    pub fn resizeTerminal(self: *ExecNamedStream, size: TerminalSize) !void {
        var payload: [4]u8 = undefined;
        spore_stream.writeResizePayload(&payload, size);
        try self.writeInputFrame(.resize, .terminal, &payload);
    }

    fn writeInputData(self: *ExecNamedStream, stream_id: spore_stream.StreamId, bytes: []const u8) !void {
        var remaining = bytes;
        while (remaining.len > 0) {
            const take = @min(remaining.len, spore_stream.max_payload_len);
            try self.writeInputFrame(.data, stream_id, remaining[0..take]);
            remaining = remaining[take..];
        }
    }

    fn writeInputFrame(self: *ExecNamedStream, frame_type: spore_stream.FrameType, stream_id: spore_stream.StreamId, payload: []const u8) !void {
        const offset = switch (stream_id) {
            .stdin => self.stdin_offset,
            .terminal => self.terminal_input_offset,
            else => 0,
        };
        var frame_buf: [spore_stream.max_frame_len]u8 = undefined;
        const frame = try spore_stream.writeFrame(&frame_buf, .{
            .frame_type = frame_type,
            .stream_id = stream_id,
            .offset = if (frame_type == .resize) 0 else offset,
        }, payload);
        try writeFdAll(self.stream.socket.handle, frame);
        if (frame_type == .data) {
            const len: u64 = @intCast(payload.len);
            switch (stream_id) {
                .stdin => self.stdin_offset += len,
                .terminal => self.terminal_input_offset += len,
                else => {},
            }
        }
    }
};

const NamedNetworkConfig = struct {
    mode: run_mod.NetworkMode = .disabled,
    policy: run_mod.NetworkPolicy = .{},
};

fn namedNetworkConfig(options: NamedNetworkOptions) !NamedNetworkConfig {
    if (!options.enabled) {
        if (options.allow_cidrs.len != 0 or
            options.allow_hosts.len != 0 or
            options.policy.allow.len != 0 or
            options.bound_services.len != 0 or
            options.port_forwards.len != 0) return error.InvalidNetworkPolicy;
        return .{};
    }
    var config = run_mod.NetworkPolicy{};
    for (options.allow_cidrs) |cidr| {
        try config.addAllowCidr(cidr);
    }
    for (options.allow_hosts) |host| {
        try config.addAllowHost(host);
    }
    if (options.policy.allow.len != 0) {
        try config.addNetworkPolicy(options.policy);
    }
    for (options.bound_services) |service| {
        try config.addBoundService(service);
    }
    for (options.port_forwards) |forward| {
        if (forward.host_port == 0 or forward.guest_port == 0) return error.InvalidPortForward;
        if (config.port_forward_count >= spore_net_policy.max_port_forwards) return error.TooManyPortForwards;
        config.port_forwards[config.port_forward_count] = forward;
        config.port_forward_count += 1;
    }
    return .{ .mode = .spore, .policy = config };
}

pub fn createNamed(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: CreateNamedOptions,
) !NamedLifecycleResult {
    const start_ms = monotonicMs();
    return createNamedWithTiming(init, allocator, options, .{
        .start_ms = start_ms,
        .parsed_ms = start_ms,
    });
}

const CreateTimingAnchors = struct {
    start_ms: u64,
    parsed_ms: u64,
};

fn createNamedWithTiming(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: CreateNamedOptions,
    timing: CreateTimingAnchors,
) !NamedLifecycleResult {
    clearLastError();
    if (options.rootfs_path != null and options.image_ref != null) return error.InvalidRootfsInput;
    if (!monitorBackendSupported(options.backend.name())) return error.HostUnsupported;
    try topology.validateVcpuCount(options.vcpus);
    try spore.validateAnnotations(options.annotations);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const named_network = try namedNetworkConfig(options.network);

    var spec = Spec{
        .name = options.name,
        .backend = options.backend.name(),
        .kernel_path = options.kernel_path,
        .initrd_path = options.initrd_path,
        .rootfs_path = options.rootfs_path,
        .image_ref = options.image_ref,
        .network = try run_mod.manifestNetworkFromOptions(arena, named_network.mode, &named_network.policy),
        .memory = options.memory,
        .vcpus = options.vcpus,
        .guest_port = options.guest_port,
        .timeout_ms = options.timeout_ms,
        .console_log_path = options.console_log_path,
        .annotations = options.annotations,
    };
    const paths = try apiPaths(.{ .io = init.io, .environ_map = init.environ_map }, arena, spec.name);
    const paths_ms = monotonicMs();
    const state = try classifyVmState(arena, init.io, paths, pidAlive);
    if (state != .absent) return namedVmExists(arena, init.io, paths, "create", spec.name, state);
    const state_checked_ms = monotonicMs();

    const rootfs = try run_mod.resolveRootfsInputDetailed(init, arena, .{
        .rootfs_path = spec.rootfs_path,
        .image_ref = spec.image_ref,
        .pull_policy = options.image_pull_policy,
        .command_name = "create",
        .record_artifact = spec.rootfs_path != null or spec.image_ref != null,
        .require_storage_complete = spec.rootfs_path != null or spec.image_ref != null,
    });
    const rootfs_resolved_ms = monotonicMs();
    spec.rootfs_path = if (rootfs.path) |path| try std.fs.path.resolve(arena, &.{path}) else null;
    spec.rootfs = rootfs.rootfs;
    const rootfs_abspath_ms = monotonicMs();
    if (spec.rootfs != null or !spore.annotationsEmpty(spec.annotations)) try writeSpec(arena, init.io, paths, spec);

    const spawn_policy: ?*const run_mod.NetworkPolicy = if (named_network.mode == .spore) &named_network.policy else null;
    const spore_executable_path = try spawnMonitorExecutable(init, arena, paths, spec, options.spore_executable, spawn_policy);
    const monitor_spawned_ms = monotonicMs();
    try waitForReadyResult(arena, init.io, paths, spec.timeout_ms, spore_executable_path);
    const ready_ms = monotonicMs();
    writeCreateTiming(arena, init.io, paths, .{
        .parse_ms = timing.parsed_ms - timing.start_ms,
        .paths_ms = paths_ms - timing.parsed_ms,
        .state_check_ms = state_checked_ms - paths_ms,
        .rootfs_resolve_ms = rootfs_resolved_ms - state_checked_ms,
        .rootfs_abspath_ms = rootfs_abspath_ms - rootfs_resolved_ms,
        .spawn_monitor_ms = monitor_spawned_ms - rootfs_abspath_ms,
        .wait_ready_ms = ready_ms - monitor_spawned_ms,
        .total_ms = ready_ms - timing.start_ms,
    }) catch {};

    var ready = try readReady(arena, init.io, paths);
    defer ready.deinit();
    return ownedNamedLifecycleResult(allocator, .{
        .action = "created",
        .name = spec.name,
        .state = "ready",
        .pid = ready.value.pid,
        .console_log_path = ready.value.console_log_path,
    });
}

pub fn restoreNamed(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: RestoreNamedOptions,
) !NamedLifecycleResult {
    clearLastError();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const spore_dir = try resolveExistingSporeDirApi(arena, init.io, options.spore_dir);
    var manifest = spore.loadManifest(arena, spore_dir) catch |err| switch (err) {
        error.BadManifest => null,
        error.FormatTooOld => return error.FormatTooOld,
        else => return error.InvalidSporeDir,
    };
    defer if (manifest) |*parsed| parsed.deinit();
    var manifest_v1: ?std.json.Parsed(spore.ManifestV1) = null;
    defer if (manifest_v1) |*parsed| parsed.deinit();
    if (manifest == null) {
        manifest_v1 = spore.loadManifestV1(arena, spore_dir) catch |err| switch (err) {
            error.FormatTooOld => return error.FormatTooOld,
            else => return error.InvalidSporeDir,
        };
    }
    const network_options = run_mod.networkOptionsFromManifestWithBindings(arena, if (manifest) |parsed| parsed.value.network else manifest_v1.?.value.network, options.bound_services) catch |err| switch (err) {
        error.MissingBoundServiceBinding,
        error.UnexpectedBoundServiceBinding,
        error.DuplicateBoundServiceBinding,
        error.InvalidBoundService,
        error.InvalidBoundServiceTarget,
        error.UnsupportedBoundServiceTarget,
        => return err,
        else => return error.InvalidNetworkPolicy,
    };
    const rootfs = if (manifest) |parsed|
        try run_mod.resumeRootfsForRun(arena, parsed.value)
    else
        try run_mod.resumeRootfsForRunV1(arena, manifest_v1.?.value);
    const disk = if (manifest) |parsed|
        try run_mod.resumeDiskForRun(arena, parsed.value)
    else
        try run_mod.resumeDiskForRunV1(arena, manifest_v1.?.value);
    const devices_len = if (manifest) |parsed| parsed.value.devices.len else manifest_v1.?.value.devices.len;
    if (rootfs == null and devices_len != diskless_resume_device_count) return error.UnsupportedLifecycleDeviceModel;
    const ram_size = if (manifest) |parsed| parsed.value.platform.ram_size else manifest_v1.?.value.platform.ram_size;
    const manifest_generation = if (manifest) |parsed| parsed.value.generation else manifest_v1.?.value.generation;
    const resume_generation = if (options.generation_path) |path| blk: {
        const params = attach_mod.loadGenerationParams(init.io, arena, path) catch |err| switch (err) {
            error.BadGenerationPayload => return error.BadGenerationPayload,
            error.StreamTooLong => return error.GenerationPayloadTooLarge,
            error.FileNotFound => return error.GenerationFileNotFound,
            else => return error.GenerationFileInvalid,
        };
        break :blk try attach_mod.prepareRestoreGenerationState(arena, manifest_generation, params);
    } else null;
    const sessions = if (manifest) |parsed| parsed.value.sessions else manifest_v1.?.value.sessions;
    const memory = memory_config.fromManifestBytes(ram_size) catch return error.InvalidMemorySize;
    const manifest_vcpus = if (manifest_v1) |parsed| parsed.value.platform.vcpu_count else @as(topology.VcpuCount, 1);

    var lifecycle_spec = readSporeLifecycleSpec(arena, init.io, spore_dir) catch return error.InvalidLifecycleMetadata;
    defer if (lifecycle_spec) |*spec| spec.deinit();
    if (lifecycle_spec) |spec| {
        if (spec.value.vcpus != manifest_vcpus) return error.UnsupportedLifecycleMetadata;
    }

    const base = if (lifecycle_spec) |spec| spec.value else Spec{ .name = options.name };
    const spec = Spec{
        .name = options.name,
        .backend = if (options.backend) |backend| backend.name() else base.backend,
        .kernel_path = base.kernel_path,
        .initrd_path = base.initrd_path,
        .resume_dir = spore_dir,
        .resume_generation = resume_generation,
        .rootfs = rootfs,
        .disk = disk,
        .network = try run_mod.manifestNetworkFromOptions(arena, network_options.network, &network_options.policy),
        .annotations = if (manifest) |parsed| parsed.value.annotations else manifest_v1.?.value.annotations,
        .sessions = sessions,
        .memory = memory,
        .vcpus = manifest_vcpus,
        .guest_port = base.guest_port,
        .timeout_ms = base.timeout_ms,
        .console_log_path = base.console_log_path,
    };
    if (!monitorBackendSupported(spec.backend)) return error.HostUnsupported;

    const paths = try apiPaths(.{ .io = init.io, .environ_map = init.environ_map }, arena, spec.name);
    const state = try classifyVmState(arena, init.io, paths, pidAlive);
    if (state != .absent) return namedVmExists(arena, init.io, paths, "restore", spec.name, state);
    if (spec.rootfs != null or spec.disk != null or spec.resume_generation != null or !spore.annotationsEmpty(spec.annotations) or spec.sessions.len != 0) try writeSpec(arena, init.io, paths, spec);

    const spawn_policy: ?*const run_mod.NetworkPolicy = if (network_options.network == .spore) &network_options.policy else null;
    const spore_executable_path = try spawnMonitorExecutable(init, arena, paths, spec, options.spore_executable, spawn_policy);
    try waitForReadyResult(arena, init.io, paths, spec.timeout_ms, spore_executable_path);

    var ready = try readReady(arena, init.io, paths);
    defer ready.deinit();
    return ownedNamedLifecycleResult(allocator, .{
        .action = "restored",
        .name = spec.name,
        .state = "ready",
        .pid = ready.value.pid,
        .console_log_path = ready.value.console_log_path,
        .spore_dir = spore_dir,
    });
}

pub fn execNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: ExecNamedOptions,
) !ExecNamedResult {
    clearLastError();
    if (options.command.len == 0) return error.InvalidGuestCommand;
    if (options.interactive or options.tty) return error.UnsupportedInteractiveExec;
    if (options.network_policy != null) return error.UnsupportedNetworkPolicyUpdate;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths = try apiPaths(context, arena, options.name);
    const state = try classifyVmState(arena, context.io, paths, pidAlive);
    if (state != .ready) return namedVmNotReady(arena, context.io, paths, "exec", options.name, state);
    var ready = try readReady(arena, context.io, paths);
    defer ready.deinit();
    const response = try sendExecRequest(arena, context.io, ready.value.control_socket_path, options.command);
    return parseExecNamedResponse(allocator, arena, response);
}

pub fn openExecNamedStream(
    context: Context,
    allocator: std.mem.Allocator,
    options: ExecNamedStreamOptions,
) !ExecNamedStream {
    clearLastError();
    if (options.command.len == 0) return error.InvalidGuestCommand;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths = try apiPaths(context, arena, options.name);
    const state = try classifyVmState(arena, context.io, paths, pidAlive);
    if (state != .ready) return namedVmNotReady(arena, context.io, paths, "exec-stream", options.name, state);
    var ready = try readReady(arena, context.io, paths);
    defer ready.deinit();
    return openExecNamedStreamAt(context, arena, ready.value.control_socket_path, options);
}

pub fn copyInNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: CopyNamedOptions,
) !void {
    clearLastError();
    var archive = try createCopyArchive(allocator, context.io, options.host_path);
    defer archive.deinit(context.io);

    const source_fd = try openHostFileRead(allocator, context.io, archive.path);
    defer _ = std.c.close(source_fd);

    const exit_code = try copyNamedStreaming(context, allocator, options, "copy-in-v1", .{
        .input_fd = source_fd,
        .stdout_fd = -1,
        .stderr_fd = -1,
    });
    if (exit_code != 0) return error.GuestCopyFailed;
}

pub fn copyOutNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: CopyNamedOptions,
) !void {
    clearLastError();
    var archive = try createEmptyCopyArchive(allocator, context.io);
    defer archive.deinit(context.io);

    const archive_fd = try openHostFileCreate(allocator, archive.path);
    var archive_fd_open = true;
    defer {
        if (archive_fd_open) _ = std.c.close(archive_fd);
    }

    const exit_code = try copyNamedStreaming(context, allocator, options, "copy-out-v1", .{
        .stdout_fd = archive_fd,
        .stderr_fd = -1,
    });
    _ = std.c.close(archive_fd);
    archive_fd_open = false;

    if (exit_code != 0) return error.GuestCopyFailed;
    try extractCopyArchive(allocator, context.io, archive.path, options.host_path);
}

fn execNamedStreaming(
    context: Context,
    allocator: std.mem.Allocator,
    options: ExecNamedOptions,
) !u8 {
    clearLastError();
    if (options.command.len == 0) return error.InvalidGuestCommand;
    if (!options.interactive and !options.tty) return error.InvalidGuestCommand;
    if (options.network_policy != null) return error.UnsupportedNetworkPolicyUpdate;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths = try apiPaths(context, arena, options.name);
    const state = try classifyVmState(arena, context.io, paths, pidAlive);
    if (state != .ready) return namedVmNotReady(arena, context.io, paths, "exec-stream", options.name, state);
    var ready = try readReady(arena, context.io, paths);
    defer ready.deinit();
    return execStreamControl(context, arena, ready.value.control_socket_path, .{
        .name = options.name,
        .command = options.command,
        .interactive = options.interactive,
        .tty = options.tty,
        .terminal_name = terminalName(context.environ_map),
        .terminal_size = terminalSizeOrDefault(terminalSizeFd()),
    });
}

fn copyNamedStreaming(
    context: Context,
    allocator: std.mem.Allocator,
    options: CopyNamedOptions,
    request_type: []const u8,
    fds: CopyStreamFds,
) !u8 {
    clearLastError();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths = try apiPaths(context, arena, options.name);
    const state = try classifyVmState(arena, context.io, paths, pidAlive);
    if (state != .ready) return namedVmNotReady(arena, context.io, paths, "copy", options.name, state);
    var ready = try readReady(arena, context.io, paths);
    defer ready.deinit();
    return copyStreamControl(context, arena, ready.value.control_socket_path, request_type, options.guest_path, fds);
}

fn startNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: ExecNamedOptions,
) !ExecNamedResult {
    clearLastError();
    if (options.command.len == 0) return error.InvalidGuestCommand;
    if (options.interactive or options.tty) return error.UnsupportedInteractiveExec;
    if (options.network_policy != null) return error.UnsupportedNetworkPolicyUpdate;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths = try apiPaths(context, arena, options.name);
    const state = try classifyVmState(arena, context.io, paths, pidAlive);
    if (state != .ready) return namedVmNotReady(arena, context.io, paths, "start", options.name, state);
    var ready = try readReady(arena, context.io, paths);
    defer ready.deinit();
    const response = try sendStartRequest(arena, context.io, ready.value.control_socket_path, options.command);
    return parseExecNamedResponse(allocator, arena, response);
}

fn saveContinueNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: SaveContinueNamedOptions,
) !NamedLifecycleResult {
    clearLastError();
    try spore.validateAnnotations(options.annotations);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out_dir = try resolveNewOutputDirApi(arena, context.io, options.out_dir);
    const paths = try apiPaths(context, arena, options.name);
    const state = try classifyVmState(arena, context.io, paths, pidAlive);
    if (state != .ready) return namedVmNotReady(arena, context.io, paths, "save", options.name, state);
    var spec = try readSpec(arena, context.io, paths);
    defer spec.deinit();
    // Non-destructive save supports multi-vCPU VMs: both KVM and HVF quiesce
    // every vCPU at one barrier, capture manifest-v1 state, and resume the
    // guest through the monitor snapshot-and-continue path (the same path
    // `spore fork --vm` uses). No vCPU-count gate is needed here.
    if ((spec.value.rootfs_path != null or spec.value.image_ref != null) and spec.value.rootfs == null) {
        return error.MissingRootfsIdentity;
    }
    var ready = try readReady(arena, context.io, paths);
    defer ready.deinit();
    const response = try sendSnapshotRequest(arena, context.io, ready.value.control_socket_path, out_dir);
    if (!try snapshotResponseOk(arena, response)) return error.MonitorRequestFailed;
    var snapshot_spec = spec.value;
    if (!spore.annotationsEmpty(options.annotations)) {
        var manifest = try spore.loadManifest(arena, out_dir);
        defer manifest.deinit();
        manifest.value.annotations = try spore.mergeAnnotations(arena, manifest.value.annotations, options.annotations);
        try spore.saveManifest(arena, out_dir, manifest.value);
        snapshot_spec.annotations = manifest.value.annotations;
    }
    try writeSporeLifecycleSpec(arena, context.io, out_dir, snapshot_spec);
    return ownedNamedLifecycleResult(allocator, .{
        .action = "saved",
        .name = options.name,
        .state = "ready",
        .pid = ready.value.pid,
        .spore_dir = out_dir,
    });
}

pub fn saveNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: SaveNamedOptions,
) !NamedLifecycleResult {
    clearLastError();
    if (options.stop) return saveStopNamed(context, allocator, options);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out_dir = try resolveNewOutputDirApi(arena, context.io, options.out_dir);
    const temp_dir = try temporarySiblingOutputDir(arena, context.io, out_dir);
    var cleanup_temp = true;
    defer if (cleanup_temp) Io.Dir.cwd().deleteTree(context.io, temp_dir) catch {};

    const saved = try saveContinueNamed(context, allocator, .{
        .name = options.name,
        .out_dir = temp_dir,
        .annotations = options.annotations,
    });
    defer deinitNamedLifecycleResult(allocator, saved);

    try Io.Dir.renameAbsolute(temp_dir, out_dir, context.io);
    cleanup_temp = false;
    return ownedNamedLifecycleResult(allocator, .{
        .action = "saved",
        .name = options.name,
        .state = "ready",
        .pid = saved.pid,
        .spore_dir = out_dir,
    });
}

fn saveStopNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: SaveNamedOptions,
) !NamedLifecycleResult {
    clearLastError();
    try spore.validateAnnotations(options.annotations);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out_dir = try resolveNewOutputDirApi(arena, context.io, options.out_dir);
    const paths = try apiPaths(context, arena, options.name);
    const state = try classifyVmState(arena, context.io, paths, pidAlive);
    if (state != .ready) return namedVmNotReady(arena, context.io, paths, "save", options.name, state);
    var spec = try readSpec(arena, context.io, paths);
    defer spec.deinit();
    if ((spec.value.rootfs_path != null or spec.value.image_ref != null) and spec.value.rootfs == null) {
        return error.MissingRootfsIdentity;
    }
    var ready = try readReady(arena, context.io, paths);
    defer ready.deinit();
    const response = try sendSuspendRequest(arena, context.io, ready.value.control_socket_path, out_dir);
    if (try suspendResponseFailureMessage(arena, response) != null) return error.MonitorRequestFailed;

    var cleanup_after_suspend = true;
    defer if (cleanup_after_suspend) {
        if (finishAcceptedMonitorStop(context.io, paths, ready.value.pid)) {
            Io.Dir.cwd().deleteTree(context.io, paths.vm_dir) catch {};
        } else |_| {}
    };
    var suspend_spec = spec.value;
    if (!spore.annotationsEmpty(options.annotations)) {
        var manifest = try spore.loadManifest(arena, out_dir);
        defer manifest.deinit();
        manifest.value.annotations = try spore.mergeAnnotations(arena, manifest.value.annotations, options.annotations);
        try spore.saveManifest(arena, out_dir, manifest.value);
        suspend_spec.annotations = manifest.value.annotations;
    }
    try writeSporeLifecycleSpec(arena, context.io, out_dir, suspend_spec);
    const saved_sessions: usize = blk: {
        var manifest = spore.loadManifest(arena, out_dir) catch break :blk 0;
        defer manifest.deinit();
        break :blk manifest.value.sessions.len;
    };
    cleanup_after_suspend = false;
    try finishAcceptedMonitorStop(context.io, paths, ready.value.pid);
    try Io.Dir.cwd().deleteTree(context.io, paths.vm_dir);
    return ownedNamedLifecycleResult(allocator, .{
        .action = "saved_stopped",
        .name = options.name,
        .state = "stopped",
        .pid = ready.value.pid,
        .spore_dir = out_dir,
        .saved_sessions = saved_sessions,
    });
}

pub fn forkNamed(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: ForkNamedOptions,
) !NamedForkResult {
    clearLastError();
    if (options.count == 0) return error.InvalidForkCount;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const context = Context{ .io = init.io, .environ_map = init.environ_map };

    const child_names = try renderForkNames(arena, options.name_pattern, options.count);
    const source_paths = try apiPaths(context, arena, options.source_name);
    const state = try classifyVmState(arena, init.io, source_paths, pidAlive);
    if (state != .ready) return namedVmNotReady(arena, init.io, source_paths, "fork", options.source_name, state);

    var source_spec = readSpec(arena, init.io, source_paths) catch return namedVmNotReady(arena, init.io, source_paths, "fork", options.source_name, .incomplete);
    defer source_spec.deinit();
    if (source_spec.value.rootfs_path != null or source_spec.value.image_ref != null or source_spec.value.rootfs != null or source_spec.value.disk != null) {
        return error.UnsupportedNamedForkDisk;
    }
    if (source_spec.value.network != null) return error.UnsupportedNamedForkNetwork;

    for (child_names) |child_name| {
        const child_paths = try apiPaths(context, arena, child_name);
        const child_state = try classifyVmState(arena, init.io, child_paths, pidAlive);
        if (child_state != .absent) return namedVmExists(arena, init.io, child_paths, "fork", child_name, child_state);
    }

    var ready = readReady(arena, init.io, source_paths) catch return namedVmNotReady(arena, init.io, source_paths, "fork", options.source_name, .incomplete);
    defer ready.deinit();

    const batch_dir = try hiddenForkBatchDir(arena, source_paths.runtime_root, options.source_name);
    const snapshot_dir = try std.fs.path.resolve(arena, &.{ batch_dir, "source.spore" });
    const children_dir = try std.fs.path.resolve(arena, &.{ batch_dir, "children" });
    try ensureDirPath(init.io, batch_dir);
    var cleanup_batch = true;
    defer if (cleanup_batch) Io.Dir.cwd().deleteTree(init.io, batch_dir) catch {};

    const response = try sendSnapshotRequest(arena, init.io, ready.value.control_socket_path, snapshot_dir);
    if (!(snapshotResponseOk(arena, response) catch return error.BadMonitorResponse)) return error.MonitorRequestFailed;
    try writeSporeLifecycleSpec(arena, init.io, snapshot_dir, source_spec.value);

    _ = try spore.fork(arena, .{
        .parent_dir = snapshot_dir,
        .out_dir = children_dir,
        .count = options.count,
        .environ_map = init.environ_map,
    });

    var started = std.array_list.Managed([]const u8).init(arena);
    for (child_names, 0..) |child_name, index| {
        const spore_dir = try childSporeDir(arena, children_dir, index);
        startForkChildExecutable(init, arena, child_name, spore_dir, source_spec.value, options.spore_executable) catch |err| {
            cleanupStartedChildren(init, arena, started.items);
            return err;
        };
        try started.append(child_name);
    }

    cleanup_batch = false;
    return ownedNamedForkResult(allocator, .{
        .source = options.source_name,
        .count = options.count,
        .children = child_names,
    });
}

pub fn removeNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: RemoveNamedOptions,
) !NamedLifecycleResult {
    clearLastError();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths = try apiPaths(context, arena, options.name);
    const state = try classifyVmState(arena, context.io, paths, pidAlive);
    var removed_pid: ?i64 = null;
    switch (state) {
        .absent => return error.NamedVmNotFound,
        .ready => {
            var ready = try readReady(arena, context.io, paths);
            defer ready.deinit();
            removed_pid = ready.value.pid;
            try stopReadyMonitor(arena, context.io, paths, ready.value);
            try Io.Dir.cwd().deleteTree(context.io, paths.vm_dir);
        },
        .incomplete, .stale => {
            removed_pid = readPid(arena, context.io, paths) catch null;
            try Io.Dir.cwd().deleteTree(context.io, paths.vm_dir);
        },
    }
    return ownedNamedLifecycleResult(allocator, .{
        .action = "removed",
        .name = options.name,
        .state = "absent",
        .pid = removed_pid,
    });
}

pub fn listNamed(
    context: Context,
    allocator: std.mem.Allocator,
    options: ListNamedOptions,
) ![]ListEntry {
    clearLastError();
    _ = options;
    const root = try runtimeRootPath(allocator, context.environ_map);
    defer allocator.free(root);
    return listEntries(allocator, context.io, root, pidAlive);
}

pub fn deinitNamedLifecycleResult(allocator: std.mem.Allocator, result: NamedLifecycleResult) void {
    allocator.free(result.name);
    if (result.console_log_path) |path| allocator.free(path);
    if (result.spore_dir) |path| allocator.free(path);
}

pub fn deinitExecNamedResult(allocator: std.mem.Allocator, result: ExecNamedResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    allocator.free(result.network_events_jsonl);
}

pub fn deinitNamedForkResult(allocator: std.mem.Allocator, result: NamedForkResult) void {
    allocator.free(result.source);
    for (result.children) |child| allocator.free(child);
    allocator.free(result.children);
}

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
    var parsed = try parseCreateArgs(args, allocator, stderr, mode);
    parsed = try applyCreateOptionsFileLifecycleCli(init.io, allocator, stderr, mode, parsed);
    const parsed_ms = monotonicMs();
    const spec = parsed.spec;
    const network_rules = try createNetworkRulesFromConfig(allocator, &parsed.network_policy);
    const bound_services = try createBoundServicesFromConfig(allocator, &parsed.network_policy);
    const start_command: ?[]const []const u8 = if (parsed.command.len == 0)
        null
    else
        run_mod.cliGuestCommandFromMode(allocator, parsed.command_mode, parsed.command) catch |err| switch (err) {
            error.ShellCommandArgumentCountUnsupported => {
                const message = "spore create: shell command form accepts one command string; quote it or use -- for argv";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            },
            else => |e| return e,
        };
    const full_args = try init.minimal.args.toSlice(allocator);
    const result = createNamedWithTiming(init, allocator, .{
        .name = spec.name,
        .backend = run_mod.Backend.parse(spec.backend) orelse unreachable,
        .kernel_path = spec.kernel_path,
        .initrd_path = spec.initrd_path,
        .rootfs_path = spec.rootfs_path,
        .image_ref = spec.image_ref,
        .image_pull_policy = parsed.image_pull_policy,
        .network = .{
            .enabled = parsed.network == .spore,
            .allow_cidrs = if (parsed.network == .spore) parsed.network_policy.allowCidrSlice() else &.{},
            .allow_hosts = if (parsed.network == .spore) parsed.network_policy.allowHostSlice() else &.{},
            .policy = if (parsed.network == .spore) .{ .allow = network_rules } else .{},
            .bound_services = if (parsed.network == .spore) bound_services else &.{},
            .port_forwards = if (parsed.network == .spore) parsed.network_policy.portForwardSlice() else &.{},
        },
        .memory = spec.memory,
        .vcpus = spec.vcpus,
        .guest_port = spec.guest_port,
        .timeout_ms = spec.timeout_ms,
        .console_log_path = spec.console_log_path,
        .spore_executable = full_args[0],
        .annotations = spec.annotations,
    }, .{
        .start_ms = start_ms,
        .parsed_ms = parsed_ms,
    }) catch |err| switch (err) {
        error.InvalidRuntimeDir, error.InsecureRuntimeDir, error.ControlSocketPathTooLong => exitLifecycleRuntimePathError(allocator, stderr, mode, "create", err),
        error.HostUnsupported => {
            const message = "spore create: monitor mode requires HVF on Apple Silicon or KVM on Linux/aarch64";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.host_unsupported, message, "create"), message);
        },
        error.NamedVmExists => {
            const fallback = allocLifecycleMessage(allocator, "spore create: VM already exists or has stale state: {s}", .{spec.name});
            const message = allocLifecycleLastErrorMessage(allocator, "create", fallback);
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
        },
        error.UnsupportedVcpuCount => {
            const message = "spore create: unsupported vCPU/backend combination";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
        },
        error.InvalidNetworkPolicy, error.InvalidRootfsInput => {
            const message = allocLifecycleMessage(allocator, "spore create: invalid configuration: {s}", .{@errorName(err)});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
        },
        error.FileNotFound => {
            const message = "spore create: required rootfs object was not found";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_not_found, message, "create"), message);
        },
        error.MonitorReadyTimeout, error.MonitorVersionMismatch, error.SporeExecutableVersionUnavailable => {
            const message = allocLifecycleLastErrorMessage(allocator, "create", "spore create: timed out waiting for monitor readiness");
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_start_failed, message, "create"), message);
        },
        else => |e| return e,
    };
    defer deinitNamedLifecycleResult(allocator, result);
    if (start_command) |command| {
        const initial = startNamed(.{
            .io = init.io,
            .environ_map = init.environ_map,
        }, allocator, .{
            .name = spec.name,
            .command = command,
        }) catch |err| switch (err) {
            error.InvalidRuntimeDir, error.InsecureRuntimeDir, error.ControlSocketPathTooLong => exitLifecycleRuntimePathError(allocator, stderr, mode, "create", err),
            error.NamedVmNotReady => {
                const fallback = allocLifecycleMessage(allocator, "spore create: VM is not ready after create: {s}", .{spec.name});
                const message = allocLifecycleLastErrorMessage(allocator, "create", fallback);
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "create"), message);
            },
            error.MonitorUnavailable, error.MonitorRequestFailed, error.BadMonitorResponse, error.MonitorVersionMismatch => {
                const fallback = allocLifecycleMessage(allocator, "spore create: initial command failed for VM {s}: {s}", .{ spec.name, @errorName(err) });
                const message = allocLifecycleLastErrorMessage(allocator, "create", fallback);
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_execution_failed, message, "create"), message);
            },
            else => |e| return e,
        };
        defer deinitExecNamedResult(allocator, initial);
        if (initial.exit_code != 0) {
            const message = allocLifecycleMessage(allocator, "spore create: initial command exited {d}", .{initial.exit_code});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_execution_failed, message, "create"), message);
        }
    }
    if (mode == .json) {
        try machine_output.writeJson(allocator, stdout, result);
    } else {
        try writeNamedLifecycleResult(stdout, result);
    }
}

pub fn execCli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (wantsHelp(args)) {
        try stdout.writeAll(exec_usage);
        return;
    }
    const parsed = parseExecArgs(args);
    const allocator = init.arena.allocator();
    const command = run_mod.cliGuestCommandFromMode(allocator, parsed.command_mode, parsed.command) catch |err| switch (err) {
        error.ShellCommandArgumentCountUnsupported => {
            std.debug.print("spore exec: shell command form accepts one command string; quote it or use -- for argv\n", .{});
            std.process.exit(2);
        },
        else => return err,
    };
    if (parsed.interactive or parsed.tty) {
        validateExecTerminalPolicy(parsed);
        const exit_code = execNamedStreaming(.{
            .io = init.io,
            .environ_map = init.environ_map,
        }, allocator, .{
            .name = parsed.name,
            .command = command,
            .interactive = parsed.interactive,
            .tty = parsed.tty,
        }) catch |err| switch (err) {
            error.InvalidRuntimeDir, error.InsecureRuntimeDir, error.ControlSocketPathTooLong => cliRuntimePathExit("exec", err),
            error.NamedVmNotReady => {
                const detail = lastErrorMessage();
                if (detail.len != 0) {
                    std.debug.print("spore exec: {s}\n", .{detail});
                } else {
                    std.debug.print("spore exec: VM is not ready: {s}\n", .{parsed.name});
                }
                std.process.exit(2);
            },
            error.MonitorUnavailable, error.MonitorRequestFailed, error.BadMonitorResponse, error.MonitorVersionMismatch => {
                const detail = lastErrorMessage();
                if (detail.len != 0) {
                    std.debug.print("spore exec: {s}\n", .{detail});
                } else switch (err) {
                    error.MonitorUnavailable => std.debug.print("spore exec: monitor is unavailable for VM: {s}\n", .{parsed.name}),
                    else => std.debug.print("spore exec: monitor request failed for VM {s}: {s}\n", .{ parsed.name, @errorName(err) }),
                }
                std.process.exit(1);
            },
            else => |e| return e,
        };
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }
    const result = execNamed(.{
        .io = init.io,
        .environ_map = init.environ_map,
    }, allocator, .{
        .name = parsed.name,
        .command = command,
    }) catch |err| switch (err) {
        error.InvalidRuntimeDir, error.InsecureRuntimeDir, error.ControlSocketPathTooLong => cliRuntimePathExit("exec", err),
        error.NamedVmNotReady => {
            const detail = lastErrorMessage();
            if (detail.len != 0) {
                std.debug.print("spore exec: {s}\n", .{detail});
            } else {
                std.debug.print("spore exec: VM is not ready: {s}\n", .{parsed.name});
            }
            std.process.exit(2);
        },
        error.MonitorUnavailable, error.MonitorRequestFailed, error.BadMonitorResponse, error.MonitorVersionMismatch => {
            const detail = lastErrorMessage();
            if (detail.len != 0) {
                std.debug.print("spore exec: {s}\n", .{detail});
            } else switch (err) {
                error.MonitorUnavailable => std.debug.print("spore exec: monitor is unavailable for VM: {s}\n", .{parsed.name}),
                else => std.debug.print("spore exec: monitor request failed for VM {s}: {s}\n", .{ parsed.name, @errorName(err) }),
            }
            std.process.exit(1);
        },
        else => |e| return e,
    };
    defer deinitExecNamedResult(allocator, result);
    try writeExecNamedResult(stdout, result);
    if (result.exit_code != 0) std.process.exit(result.exit_code);
}

pub fn copyInCli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (wantsHelp(args)) {
        try stdout.writeAll(copy_in_usage);
        return;
    }
    const parsed = parseCopyInArgs(args);
    const allocator = init.arena.allocator();

    var archive = createCopyArchive(allocator, init.io, parsed.host_path) catch |err| {
        std.debug.print("spore copy-in: cannot archive host path {s}: {s}\n", .{ parsed.host_path, @errorName(err) });
        std.process.exit(1);
    };
    defer archive.deinit(init.io);

    const source_fd = openHostFileRead(allocator, init.io, archive.path) catch |err| {
        std.debug.print("spore copy-in: cannot read transfer archive: {s}\n", .{@errorName(err)});
        exitAfterCopyArchiveCleanup(&archive, init.io, 1);
    };
    defer _ = std.c.close(source_fd);

    const exit_code = copyNamedStreaming(.{
        .io = init.io,
        .environ_map = init.environ_map,
    }, allocator, parsed, "copy-in-v1", .{ .input_fd = source_fd }) catch |err| switch (err) {
        error.InvalidRuntimeDir, error.InsecureRuntimeDir, error.ControlSocketPathTooLong => {
            archive.deinit(init.io);
            cliRuntimePathExit("copy-in", err);
        },
        error.NamedVmNotReady => {
            const detail = lastErrorMessage();
            if (detail.len != 0) {
                std.debug.print("spore copy-in: {s}\n", .{detail});
            } else {
                std.debug.print("spore copy-in: VM is not ready: {s}\n", .{parsed.name});
            }
            exitAfterCopyArchiveCleanup(&archive, init.io, 2);
        },
        error.MonitorUnavailable, error.MonitorRequestFailed, error.BadMonitorResponse, error.MonitorVersionMismatch => {
            const detail = lastErrorMessage();
            if (detail.len != 0) {
                std.debug.print("spore copy-in: {s}\n", .{detail});
            } else {
                std.debug.print("spore copy-in: monitor request failed for VM {s}: {s}\n", .{ parsed.name, @errorName(err) });
            }
            exitAfterCopyArchiveCleanup(&archive, init.io, 1);
        },
        else => |e| return e,
    };
    if (exit_code != 0) exitAfterCopyArchiveCleanup(&archive, init.io, exit_code);
}

pub fn copyOutCli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (wantsHelp(args)) {
        try stdout.writeAll(copy_out_usage);
        return;
    }
    const parsed = parseCopyOutArgs(args);
    const allocator = init.arena.allocator();

    var archive = createEmptyCopyArchive(allocator, init.io) catch |err| {
        std.debug.print("spore copy-out: cannot create transfer archive: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer archive.deinit(init.io);

    const archive_fd = openHostFileCreate(allocator, archive.path) catch |err| {
        std.debug.print("spore copy-out: cannot open transfer archive: {s}\n", .{@errorName(err)});
        exitAfterCopyArchiveCleanup(&archive, init.io, 1);
    };
    var archive_fd_open = true;
    defer {
        if (archive_fd_open) _ = std.c.close(archive_fd);
    }

    const exit_code = copyNamedStreaming(.{
        .io = init.io,
        .environ_map = init.environ_map,
    }, allocator, parsed, "copy-out-v1", .{ .stdout_fd = archive_fd }) catch |err| switch (err) {
        error.InvalidRuntimeDir, error.InsecureRuntimeDir, error.ControlSocketPathTooLong => {
            archive.deinit(init.io);
            cliRuntimePathExit("copy-out", err);
        },
        error.NamedVmNotReady => {
            const detail = lastErrorMessage();
            if (detail.len != 0) {
                std.debug.print("spore copy-out: {s}\n", .{detail});
            } else {
                std.debug.print("spore copy-out: VM is not ready: {s}\n", .{parsed.name});
            }
            exitAfterCopyArchiveCleanup(&archive, init.io, 2);
        },
        error.MonitorUnavailable, error.MonitorRequestFailed, error.BadMonitorResponse, error.MonitorVersionMismatch => {
            const detail = lastErrorMessage();
            if (detail.len != 0) {
                std.debug.print("spore copy-out: {s}\n", .{detail});
            } else {
                std.debug.print("spore copy-out: monitor request failed for VM {s}: {s}\n", .{ parsed.name, @errorName(err) });
            }
            exitAfterCopyArchiveCleanup(&archive, init.io, 1);
        },
        else => |e| return e,
    };
    _ = std.c.close(archive_fd);
    archive_fd_open = false;

    if (exit_code != 0) exitAfterCopyArchiveCleanup(&archive, init.io, exit_code);
    extractCopyArchive(allocator, init.io, archive.path, parsed.host_path) catch |err| {
        std.debug.print("spore copy-out: cannot write host path {s}: {s}\n", .{ parsed.host_path, @errorName(err) });
        exitAfterCopyArchiveCleanup(&archive, init.io, 1);
    };
}

fn validateExecTerminalPolicy(parsed: ExecOptions) void {
    if (!parsed.tty) return;
    if (std.c.isatty(1) == 0) {
        std.debug.print("spore exec: -t requires stdout to be a terminal\n", .{});
        std.process.exit(2);
    }
    if (parsed.interactive and std.c.isatty(0) == 0) {
        std.debug.print("spore exec: -it requires stdin to be a terminal\n", .{});
        std.process.exit(2);
    }
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
    const result = removeNamed(.{
        .io = init.io,
        .environ_map = init.environ_map,
    }, allocator, .{ .name = name }) catch |err| switch (err) {
        error.InvalidRuntimeDir, error.InsecureRuntimeDir => exitLifecycleRuntimePathError(allocator, stderr, mode, "rm", err),
        error.NamedVmNotFound => {
            const message = allocLifecycleMessage(allocator, "spore rm: VM not found: {s}", .{name});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_not_found, message, "rm"), message);
        },
        error.MonitorShutdownTimedOut => {
            const fallback = allocLifecycleMessage(allocator, "spore rm: timed out waiting for monitor cleanup: {s}", .{name});
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

pub fn saveCli(
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
                machine_output.usageInvalidArgument("spore --json save does not support help output", "save"),
                "spore --json save does not support help output",
            );
        }
        try stdout.writeAll(save_usage);
        return;
    }
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
            const fallback = allocLifecycleMessage(allocator, "spore save: VM is not ready: {s}", .{parsed.name});
            const message = allocLifecycleLastErrorMessage(allocator, "save", fallback);
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "save"), message);
        },
        error.UnsupportedSnapshotMode => {
            const message = "spore save: this save mode is not supported; use `spore save NAME --out DIR --stop` for a consuming save";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "save"), message);
        },
        error.OutputDirExists => {
            const message = allocLifecycleMessage(allocator, "spore save: output directory already exists: {s}; choose a new --out DIR", .{parsed.out_dir});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "save"), message);
        },
        error.InvalidOutputDir => {
            const message = allocLifecycleMessage(allocator, "spore save: invalid --out directory: {s}; the parent directory must exist", .{parsed.out_dir});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "save"), message);
        },
        error.MissingRootfsIdentity => {
            const message = "spore save: disk-backed lifecycle save requires recorded immutable rootfs identity";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "save"), message);
        },
        error.MonitorUnavailable, error.MonitorRequestFailed, error.MonitorVersionMismatch, error.MonitorShutdownTimedOut => {
            const fallback = switch (err) {
                error.MonitorUnavailable => allocLifecycleMessage(allocator, "spore save: monitor is unavailable for VM: {s}", .{parsed.name}),
                error.MonitorShutdownTimedOut => allocLifecycleMessage(allocator, "spore save: timed out waiting for monitor cleanup: {s}", .{parsed.name}),
                else => allocLifecycleMessage(allocator, "spore save: monitor request failed for VM {s}: {s}", .{ parsed.name, @errorName(err) }),
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

pub fn forkCli(
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
                machine_output.usageInvalidArgument("spore --json fork does not support help output", "fork"),
                "spore --json fork does not support help output",
            );
        }
        try stdout.writeAll(fork_usage);
        return;
    }

    const allocator = init.arena.allocator();
    const parsed = parseForkArgs(args, allocator, stderr, mode);
    const full_args = try init.minimal.args.toSlice(allocator);
    const result = forkNamed(init, allocator, .{
        .source_name = parsed.source_name,
        .count = parsed.count,
        .name_pattern = parsed.name_pattern,
        .spore_executable = full_args[0],
    }) catch |err| switch (err) {
        error.InvalidRuntimeDir, error.InsecureRuntimeDir, error.ControlSocketPathTooLong => exitLifecycleRuntimePathError(allocator, stderr, mode, "fork", err),
        error.InvalidForkNamePattern => {
            const message = "spore fork: --name must contain at most one %d or %0Nd placeholder";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.MissingForkNamePlaceholder => {
            const message = "spore fork: --name must contain %d when --count is greater than 1";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.InvalidVMName => {
            const message = "spore fork: rendered VM name is invalid";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.DuplicateForkName => {
            const message = "spore fork: duplicate rendered VM name";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.NamedVmNotReady => {
            const fallback = allocLifecycleMessage(allocator, "spore fork: VM is not ready: {s}", .{parsed.source_name});
            const message = allocLifecycleLastErrorMessage(allocator, "fork", fallback);
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "fork"), message);
        },
        error.UnsupportedNamedForkDisk => {
            const message = "spore fork: disk-backed named live fork is not supported yet";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.UnsupportedNamedForkNetwork => {
            const message = "spore fork: networked named live fork is not supported yet";
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.UnsupportedNamedForkVcpu => {
            const message = allocLifecycleLastErrorMessage(allocator, "fork", "spore fork: source uses a fork topology or GIC state this backend cannot mint safely yet");
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.NamedVmExists => {
            const message = allocLifecycleLastErrorMessage(allocator, "fork", "spore fork: VM already exists or has stale state");
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        },
        error.MonitorUnavailable, error.MonitorRequestFailed, error.BadMonitorResponse => {
            const message = allocLifecycleMessage(allocator, "spore fork: monitor request failed for VM {s}: {s}", .{ parsed.source_name, @errorName(err) });
            exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_execution_failed, message, "fork"), message);
        },
        error.MonitorReadyTimeout, error.MonitorVersionMismatch, error.SporeExecutableVersionUnavailable => {
            const message = allocLifecycleLastErrorMessage(allocator, "fork", "spore fork: timed out waiting for monitor readiness");
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

pub fn restoreCli(
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
                machine_output.usageInvalidArgument("spore --json restore does not support help output", "restore"),
                "spore --json restore does not support help output",
            );
        }
        try stdout.writeAll(restore_usage);
        return;
    }
    const allocator = init.arena.allocator();
    const parsed = parseRestoreArgs(args, allocator, stderr, mode);
    const full_args = try init.minimal.args.toSlice(allocator);
    var event_writer = run_mod.EventWriter.init(std.heap.page_allocator, stdout, "restore");
    if (parsed.event_mode == .jsonl) try event_writer.emitStart(parsed.backend orelse .auto);
    const result = restoreNamed(init, allocator, .{
        .spore_dir = parsed.spore_dir,
        .name = parsed.name,
        .backend = parsed.backend,
        .generation_path = parsed.generation_path,
        .spore_executable = full_args[0],
        .bound_services = parsed.bound_services.slice(),
    }) catch |err| {
        emitRestoreFailureEvent(&event_writer, parsed.event_mode, err);
        switch (err) {
            error.BadGenerationPayload => {
                const message = "spore restore: invalid --generation payload; required JSON fields: run_id, child_id, parallel_index, parallel_count, fork_index, fork_count, fork_batch_id, vm_id";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "restore"), message);
            },
            error.GenerationPayloadTooLarge => {
                const message = allocLifecycleMessage(allocator, "spore restore: --generation payload exceeds {d} bytes", .{generation.params_size});
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "restore"), message);
            },
            error.GenerationFileNotFound, error.GenerationFileInvalid => {
                const message = allocLifecycleMessage(allocator, "spore restore: cannot read --generation {s}: {s}", .{ parsed.generation_path orelse "", @errorName(err) });
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "restore"), message);
            },
            error.InvalidRuntimeDir, error.InsecureRuntimeDir, error.ControlSocketPathTooLong => exitLifecycleRuntimePathError(allocator, stderr, mode, "restore", err),
            error.FileNotFound => {
                const message = "spore restore: spore directory is not available";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_not_found, message, "restore"), message);
            },
            error.InvalidSporeDir => {
                const message = allocLifecycleMessage(allocator, "spore restore: invalid spore directory: {s}", .{parsed.spore_dir});
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.FormatTooOld => {
                const message = machine_output.format_too_old_message;
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.InvalidNetworkPolicy => {
                const message = "spore restore: invalid network policy in manifest";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.MissingBoundServiceBinding => {
                const message = "spore restore: manifest requires live bound Unix service bindings";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.UnexpectedBoundServiceBinding => {
                const message = "spore restore: live bound Unix service bindings do not match the manifest";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.DuplicateBoundServiceBinding => {
                const message = "spore restore: duplicate live bound Unix service binding";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.InvalidBoundService, error.InvalidBoundServiceTarget, error.UnsupportedBoundServiceTarget => {
                const message = "spore restore: invalid live bound Unix service binding";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.UnsupportedLifecycleDeviceModel => {
                const message = "spore restore: unsupported lifecycle device model";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.InvalidMemorySize => {
                const message = "spore restore: invalid spore memory size";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.InvalidLifecycleMetadata => {
                const message = "spore restore: invalid lifecycle metadata";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.UnsupportedLifecycleMetadata => {
                const message = "spore restore: lifecycle metadata does not match the spore topology";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.object_invalid, message, "restore"), message);
            },
            error.HostUnsupported => {
                const message = "spore restore: monitor mode requires HVF on Apple Silicon or KVM on Linux/aarch64";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.host_unsupported, message, "restore"), message);
            },
            error.NamedVmExists => {
                const fallback = allocLifecycleMessage(allocator, "spore restore: VM already exists or has stale state: {s}", .{parsed.name});
                const message = allocLifecycleLastErrorMessage(allocator, "restore", fallback);
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "restore"), message);
            },
            error.MonitorReadyTimeout, error.MonitorVersionMismatch, error.SporeExecutableVersionUnavailable => {
                const message = allocLifecycleLastErrorMessage(allocator, "restore", "spore restore: timed out waiting for monitor readiness");
                exitLifecycleCliError(allocator, stderr, mode, machine_output.CliError.init(.runtime_start_failed, message, "restore"), message);
            },
            else => |e| return e,
        }
    };
    defer deinitNamedLifecycleResult(allocator, result);
    if (parsed.event_mode == .jsonl) {
        const requested_backend: run_mod.Backend = parsed.backend orelse .auto;
        const backend = requested_backend.resolveForHost() catch requested_backend;
        try emitNamedRestoreExit(&event_writer, backend);
    } else if (mode == .json) {
        try machine_output.writeJson(allocator, stdout, result);
    } else {
        try writeNamedLifecycleResult(stdout, result);
    }
}

fn emitNamedRestoreExit(event_writer: *run_mod.EventWriter, backend: run_mod.Backend) !void {
    try event_writer.emitExit(.{
        .backend = backend,
        .start_ms = 0,
        .vsock_connect_ms = 0,
        .exec_response_ms = 0,
        .probe_duration_ms = 0,
        .exit_code = 0,
        .vcpus = 1,
        .memory_bytes = 0,
    });
}

fn emitRestoreFailureEvent(event_writer: *run_mod.EventWriter, event_mode: run_mod.EventMode, err: anyerror) void {
    if (event_mode == .jsonl) event_writer.emitFailure(run_mod.classifyFailure(err)) catch {};
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
    const entries = listNamed(.{
        .io = init.io,
        .environ_map = init.environ_map,
    }, allocator, .{}) catch |err| switch (err) {
        error.InvalidRuntimeDir, error.InsecureRuntimeDir => exitLifecycleRuntimePathError(allocator, stderr, mode, "ls", err),
        else => |e| return e,
    };
    defer freeListEntries(allocator, entries);
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

/// Fail closed, with an actionable message, when the control socket path
/// cannot fit a sockaddr_un. Validated before the monitor is spawned so the
/// caller sees the real problem instead of a readiness timeout. Stale
/// registry entries with oversized paths stay listable and removable:
/// only spawn and connect enforce the limit, not path construction.
pub fn validateControlSocketPath(path: []const u8) error{ControlSocketPathTooLong}!void {
    if (path.len <= max_control_socket_path_len) return;
    if (maxVmNameBytesForControlSocketPath(path)) |max_vm_name_bytes| {
        setLastError(
            "control socket path {s} is {d} bytes but the platform limit is {d}; this runtime dir allows VM names up to {d} bytes; shorten the VM name or set {s} to a shorter path",
            .{ path, path.len, max_control_socket_path_len, max_vm_name_bytes, runtime_dir_env },
        );
    } else {
        setLastError(
            "control socket path {s} is {d} bytes but the platform limit is {d}; shorten the VM name or set {s} to a shorter path",
            .{ path, path.len, max_control_socket_path_len, runtime_dir_env },
        );
    }
    return error.ControlSocketPathTooLong;
}

fn maxVmNameBytesForControlSocketPath(path: []const u8) ?usize {
    const suffix = "/" ++ control_socket_file;
    if (!std.mem.endsWith(u8, path, suffix)) return null;
    const vm_dir = path[0 .. path.len - suffix.len];
    const slash = std.mem.lastIndexOfScalar(u8, vm_dir, '/') orelse return null;
    const name_len = vm_dir.len - slash - 1;
    const fixed_len = path.len - name_len;
    if (fixed_len > max_control_socket_path_len) return 0;
    return @min(max_name_len, max_control_socket_path_len - fixed_len);
}

/// Build a validated control socket address for connecting to a monitor.
fn controlSocketAddress(socket_path: []const u8) !net.UnixAddress {
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
    const control_socket_path = try std.fs.path.resolve(allocator, &.{ vm_dir, control_socket_file });
    errdefer allocator.free(control_socket_path);
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
        .control_socket_path = control_socket_path,
        .console_log_path = console_log_path,
        .monitor_log_path = monitor_log_path,
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

pub fn writeMonitorStatsPath(allocator: std.mem.Allocator, io: Io, path: []const u8, stats: MonitorStats) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, stats, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
}

pub fn writeMonitorStats(allocator: std.mem.Allocator, io: Io, paths: Paths, stats: MonitorStats) !void {
    try writeMonitorStatsPath(allocator, io, paths.monitor_stats_path, stats);
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
        const metadata = readListMetadata(allocator, io, paths) catch null;
        var stats = if (metadata) |value| value.stats else ListStats{};
        if (state == .ready) {
            if (pid) |value| stats.resident_bytes = readProcessResidentBytes(allocator, io, value);
            if (readMonitorStats(allocator, io, paths)) |monitor_stats| {
                stats.chunks_nonzero = monitor_stats.chunks_nonzero;
                stats.dirty_chunks_pending = monitor_stats.dirty_chunks_pending;
            } else |_| {}
        }
        try entries.append(.{
            .name = try allocator.dupe(u8, entry.name),
            .state = state.name(),
            .pid = pid,
            .memory = if (metadata) |value| value.memory else null,
            .stats = stats,
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

fn readListMetadata(allocator: std.mem.Allocator, io: Io, paths: Paths) !ListMetadata {
    var spec = try readSpec(allocator, io, paths);
    defer spec.deinit();
    const memory = listMemoryFromConfig(spec.value.memory);
    var stats = listStatsFromMemory(memory);
    if (spec.value.resume_dir) |dir| {
        const backing_stats = readBackingFileStats(allocator, dir) catch null;
        if (backing_stats) |value| {
            stats.backing_logical_bytes = value.backing_logical_bytes;
            stats.backing_allocated_bytes = value.backing_allocated_bytes;
        }
    }
    return .{ .memory = memory, .stats = stats };
}

fn listMemoryFromConfig(memory: memory_config.Config) ListMemory {
    return .{
        .policy = @tagName(memory.policy),
        .bytes = memory.bytes,
    };
}

fn listStatsFromMemory(memory: ListMemory) ListStats {
    const chunk_size: u64 = spore.chunk_size;
    return .{
        .chunk_size = chunk_size,
        .chunks_total = std.math.divCeil(u64, memory.bytes, chunk_size) catch unreachable,
    };
}

fn readBackingFileStats(allocator: std.mem.Allocator, dir: []const u8) !ListStats {
    const backing_path = try std.fs.path.resolve(allocator, &.{ dir, spore.ram_backing_path });
    defer allocator.free(backing_path);
    const backing_path_z = try allocator.dupeZ(u8, backing_path);
    defer allocator.free(backing_path_z);

    const fd = std.c.open(backing_path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);

    return fstatBackingFileStats(fd);
}

fn fstatBackingFileStats(fd: std.c.fd_t) !ListStats {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var statx_buf: linux.Statx = undefined;
        const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{
            .TYPE = true,
            .MODE = true,
            .SIZE = true,
            .BLOCKS = true,
        }, &statx_buf);
        if (linux.errno(rc) != .SUCCESS) return error.IoFailed;
        if (!linux.S.ISREG(statx_buf.mode)) return error.FileNotFound;
        return .{
            .backing_logical_bytes = statx_buf.size,
            .backing_allocated_bytes = if (statx_buf.mask.BLOCKS)
                std.math.mul(u64, statx_buf.blocks, 512) catch null
            else
                null,
        };
    } else if (comptime builtin.os.tag.isDarwin()) {
        var stat: std.c.Stat = undefined;
        if (std.c.fstat(fd, &stat) != 0) return error.IoFailed;
        if (!std.c.S.ISREG(stat.mode)) return error.FileNotFound;
        if (stat.size < 0) return error.IoFailed;
        return .{
            .backing_logical_bytes = @intCast(stat.size),
            .backing_allocated_bytes = if (stat.blocks >= 0)
                std.math.mul(u64, @intCast(stat.blocks), 512) catch null
            else
                null,
        };
    } else {
        return error.UnsupportedPlatform;
    }
}

fn readProcessResidentBytes(allocator: std.mem.Allocator, io: Io, pid: i64) ?u64 {
    if (pid <= 0) return null;
    return if (comptime builtin.os.tag == .linux)
        readLinuxProcessResidentBytes(allocator, io, pid) catch null
    else if (comptime builtin.os.tag.isDarwin())
        readDarwinProcessResidentBytes(pid)
    else
        null;
}

fn readLinuxProcessResidentBytes(allocator: std.mem.Allocator, io: Io, pid: i64) !u64 {
    const statm_path = try std.fmt.allocPrint(allocator, "/proc/{d}/statm", .{pid});
    defer allocator.free(statm_path);
    const data = try Io.Dir.cwd().readFileAlloc(io, statm_path, allocator, .limited(256));
    defer allocator.free(data);
    return linuxStatmResidentBytes(data, @intCast(std.heap.pageSize()));
}

fn linuxStatmResidentBytes(data: []const u8, page_size: u64) !u64 {
    var fields = std.mem.tokenizeAny(u8, data, " \t\r\n");
    _ = fields.next() orelse return error.InvalidProcessStat;
    const resident_raw = fields.next() orelse return error.InvalidProcessStat;
    const resident_pages = try std.fmt.parseUnsigned(u64, resident_raw, 10);
    return std.math.mul(u64, resident_pages, page_size) catch error.InvalidProcessStat;
}

fn readDarwinProcessResidentBytes(pid: i64) ?u64 {
    const pid_c = std.math.cast(c_int, pid) orelse return null;
    var info: darwin_process.TaskInfo = undefined;
    const expected: c_int = @intCast(@sizeOf(darwin_process.TaskInfo));
    const rc = darwin_process.proc_pidinfo(pid_c, darwin_process.proc_pid_task_info, 0, @ptrCast(&info), expected);
    if (rc != expected) return null;
    return info.resident_size;
}

fn writeMemoryValue(writer: *Io.Writer, memory: ListMemory) !void {
    if (std.mem.eql(u8, memory.policy, "auto")) {
        try writer.writeAll("auto/");
    }
    try writeBytesHuman(writer, memory.bytes);
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

fn createNetworkRulesFromConfig(
    allocator: std.mem.Allocator,
    policy: *const run_mod.NetworkPolicy,
) ![]const spore_net_policy.NetworkRule {
    const exact_rules = policy.exactRuleSlice();
    if (exact_rules.len == 0) return &.{};
    const rules = try allocator.alloc(spore_net_policy.NetworkRule, exact_rules.len);
    for (exact_rules, rules) |rule, *out| {
        out.* = .{
            .host = rule.host,
            .ports = try allocator.dupe(u16, rule.portSlice()),
        };
    }
    return rules;
}

fn createBoundServicesFromConfig(
    allocator: std.mem.Allocator,
    policy: *const run_mod.NetworkPolicy,
) ![]const spore_net_policy.BoundService {
    const cli_services = policy.boundServiceSlice();
    if (cli_services.len == 0) return &.{};
    const services = try allocator.alloc(spore_net_policy.BoundService, cli_services.len);
    for (cli_services, services) |service, *out| {
        const guest_host = if (service.guest_host.len != 0)
            service.guest_host
        else
            try std.fmt.allocPrint(allocator, "{s}.spore.internal", .{service.name});
        out.* = .{
            .name = service.name,
            .guest_host = guest_host,
            .guest_port = service.guest_port,
            .target = .{ .unix = service.unix_path },
        };
    }
    return services;
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
        const message = allocLifecycleMessage(allocator, "spore {s}: invalid --annotation {s}", .{ command, raw });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
    };
    annotations.map.put(allocator, raw[0..eq], raw[eq + 1 ..]) catch |err| {
        const message = allocLifecycleMessage(allocator, "spore {s}: invalid --annotation {s}: {s}", .{ command, raw, @errorName(err) });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
    };
    spore.validateAnnotations(annotations.*) catch {
        const message = allocLifecycleMessage(allocator, "spore {s}: invalid --annotation {s}", .{ command, raw });
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
        const message = allocLifecycleMessage(allocator, "spore create: cannot read --options {s}: {s}", .{ raw_path, @errorName(err) });
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
    };
    return parseCreateOptionsFile(allocator, parsed, data) catch |err| {
        const message = allocLifecycleMessage(allocator, "spore create: invalid --options {s}: {s}", .{ raw_path, @errorName(err) });
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
        if (run_mod.Backend.parse(backend) == null) return error.InvalidBackend;
        out.spec.backend = backend;
    }
    out.spec.kernel_path = file.kernel;
    out.spec.initrd_path = file.initrd;
    out.spec.rootfs_path = file.rootfs;
    out.spec.image_ref = file.image;
    if (file.pull) |pull| {
        out.image_pull_policy = run_mod.PullPolicy.parse(pull) orelse return error.InvalidPullPolicy;
    }
    if (file.memory) |memory| {
        out.spec.memory = try memory_config.parse(memory);
    }
    if (file.vcpus) |vcpus| out.spec.vcpus = vcpus;
    if (file.guest_port) |port| out.spec.guest_port = port;
    if (file.timeout_ms) |timeout| out.spec.timeout_ms = timeout;
    out.spec.console_log_path = file.console_log_path;
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
            out.network = .spore;
            for (network.allow_cidrs) |cidr| try out.network_policy.addAllowCidr(cidr);
            for (network.allow_hosts) |host| try out.network_policy.addAllowHost(host);
            for (network.allow_host_ports) |rule| try out.network_policy.addExactHostPorts(rule.host, rule.ports);
            for (network.network_rules) |rule| try out.network_policy.addExactHostPorts(rule.host, rule.ports);
            for (network.bound_services) |service| {
                const guest_host = service.guest_host orelse try std.fmt.allocPrint(allocator, "{s}.spore.internal", .{service.name});
                try out.network_policy.addBoundUnixService(service.name, guest_host, service.guest_port, service.unix_path);
            }
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
    var image_pull_policy: run_mod.PullPolicy = .missing;
    var network: run_mod.NetworkMode = .disabled;
    var network_policy = run_mod.NetworkPolicy{};
    var command_mode: run_mod.CommandMode = .shell;
    var command: ?[]const []const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            command_mode = .argv;
            command = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, args[i], "--backend")) {
            field_flag_seen = true;
            spec.backend = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            if (run_mod.Backend.parse(spec.backend) == null) {
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
                const message = "spore create: --options may be supplied once";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            }
            options_path = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--pull")) {
            field_flag_seen = true;
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            image_pull_policy = run_mod.PullPolicy.parse(raw) orelse {
                const message = "spore create: --pull must be missing, always, or never";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
        } else if (std.mem.startsWith(u8, args[i], "--pull=")) {
            field_flag_seen = true;
            const raw = args[i]["--pull=".len..];
            image_pull_policy = run_mod.PullPolicy.parse(raw) orelse {
                const message = "spore create: --pull must be missing, always, or never";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
        } else if (std.mem.eql(u8, args[i], "--net")) {
            field_flag_seen = true;
            network = .spore;
        } else if (std.mem.eql(u8, args[i], "--allow-cidr")) {
            field_flag_seen = true;
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            network_policy.addAllowCidr(raw) catch |err| {
                const message = allocLifecycleMessage(allocator, "spore create: invalid --allow-cidr {s}: {s}", .{ raw, @errorName(err) });
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
        } else if (std.mem.eql(u8, args[i], "--allow-host")) {
            field_flag_seen = true;
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            network_policy.addAllowHost(raw) catch |err| {
                const message = allocLifecycleMessage(allocator, "spore create: invalid --allow-host {s}: {s}", .{ raw, @errorName(err) });
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
        } else if (std.mem.eql(u8, args[i], "--allow-host-port")) {
            field_flag_seen = true;
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            const parsed = spore_net_policy.parseHostPort(raw) catch |err| {
                const message = allocLifecycleMessage(allocator, "spore create: invalid --allow-host-port {s}: {s}", .{ raw, @errorName(err) });
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
            network_policy.addExactHostPorts(parsed.host, &.{parsed.port}) catch |err| {
                const message = allocLifecycleMessage(allocator, "spore create: invalid --allow-host-port {s}: {s}", .{ raw, @errorName(err) });
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
        } else if (std.mem.eql(u8, args[i], "--bind-service")) {
            field_flag_seen = true;
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            network_policy.addBindService(raw) catch |err| {
                const message = allocLifecycleMessage(allocator, "spore create: invalid --bind-service {s}: {s}", .{ raw, @errorName(err) });
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
        } else if (std.mem.eql(u8, args[i], "--forward")) {
            field_flag_seen = true;
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "create", args, &i, args[i]);
            network_policy.addPortForward(raw) catch |err| {
                const message = allocLifecycleMessage(allocator, "spore create: invalid --forward {s}: {s}", .{ raw, @errorName(err) });
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
            };
        } else if (std.mem.eql(u8, args[i], "--memory")) {
            field_flag_seen = true;
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
            command = args[i..];
            break;
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
    if (command) |argv| {
        if (argv.len == 0) {
            exitLifecycleCliError(
                allocator,
                stderr,
                mode,
                machine_output.usageMissingArgument("usage: spore create NAME [options] -- <argv...>", "create"),
                create_usage,
            );
        }
    }
    if (options_path != null and field_flag_seen) {
        const message = "spore create: --options cannot be combined with create option flags";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
    }
    if (spec.rootfs_path != null and spec.image_ref != null) {
        const message = "spore create: --rootfs and --image are mutually exclusive";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
    }
    if (spec.image_ref == null and image_pull_policy != .missing) {
        const message = "spore create: --pull requires --image";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
    }
    if (network == .disabled and network_policy.hasRules()) {
        const message = "spore create: network flags require --net";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "create"), message);
    }
    return .{
        .spec = spec,
        .options_path = options_path,
        .image_pull_policy = image_pull_policy,
        .network = network,
        .network_policy = network_policy,
        .command_mode = command_mode,
        .command = command orelse &.{},
    };
}

fn parseExecArgs(args: []const []const u8) ExecOptions {
    if (args.len < 2) usageExit(exec_usage);
    var name: ?[]const u8 = null;
    var command_mode: run_mod.CommandMode = .shell;
    var command: []const []const u8 = &.{};
    var interactive = false;
    var tty = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            command_mode = .argv;
            command = args[i + 1 ..];
            break;
        } else if (name != null) {
            command = args[i..];
            break;
        } else if (std.mem.eql(u8, args[i], "-i") or std.mem.eql(u8, args[i], "--interactive")) {
            interactive = true;
        } else if (std.mem.eql(u8, args[i], "-t") or std.mem.eql(u8, args[i], "--tty")) {
            tty = true;
        } else if (std.mem.eql(u8, args[i], "-it") or std.mem.eql(u8, args[i], "-ti")) {
            interactive = true;
            tty = true;
        } else if (std.mem.startsWith(u8, args[i], "-")) {
            usageExit(exec_usage);
        } else {
            validateNameOrExit("exec", args[i]) catch unreachable;
            name = args[i];
        }
    }
    const vm_name = name orelse usageExit(exec_usage);
    if (command.len == 0) usageExit(exec_usage);
    return .{
        .name = vm_name,
        .command_mode = command_mode,
        .command = command,
        .interactive = interactive,
        .tty = tty,
    };
}

fn parseCopyInArgs(args: []const []const u8) CopyNamedOptions {
    if (args.len != 3) usageExit(copy_in_usage);
    validateNameOrExit("copy-in", args[0]) catch unreachable;
    return .{
        .name = args[0],
        .host_path = args[1],
        .guest_path = args[2],
    };
}

fn parseCopyOutArgs(args: []const []const u8) CopyNamedOptions {
    if (args.len != 3) usageExit(copy_out_usage);
    validateNameOrExit("copy-out", args[0]) catch unreachable;
    return .{
        .name = args[0],
        .guest_path = args[1],
        .host_path = args[2],
    };
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
        if (std.mem.eql(u8, args[i], "--out")) {
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
            machine_output.usageMissingArgument("usage: spore save NAME --out DIR [--stop]", "save"),
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

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--vm")) {
            source_name = takeValueLifecycleCli(allocator, stderr, mode, "fork", args, &i, args[i]);
            validateNameLifecycleCli(allocator, stderr, mode, "fork", source_name.?);
        } else if (std.mem.eql(u8, args[i], "--count")) {
            const flag = args[i];
            count = parseIntArgLifecycleCli(usize, allocator, stderr, mode, "fork", takeValueLifecycleCli(allocator, stderr, mode, "fork", args, &i, flag), flag);
        } else if (std.mem.eql(u8, args[i], "--name")) {
            name_pattern = takeValueLifecycleCli(allocator, stderr, mode, "fork", args, &i, args[i]);
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            const message = allocLifecycleMessage(allocator, "unknown fork argument: {s}", .{args[i]});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        } else {
            const message = allocLifecycleMessage(allocator, "unexpected fork argument: {s}", .{args[i]});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
        }
    }

    if (source_name == null or count == null or name_pattern == null) {
        exitLifecycleCliError(
            allocator,
            stderr,
            mode,
            machine_output.usageMissingArgument("usage: spore fork --vm NAME --count N --name PATTERN", "fork"),
            fork_usage,
        );
    }
    if (count.? == 0) {
        const message = "spore fork: --count must be a positive integer";
        exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "fork"), message);
    }
    return .{
        .source_name = source_name.?,
        .count = count.?,
        .name_pattern = name_pattern.?,
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
    var backend: ?run_mod.Backend = null;
    var generation_path: ?[]const u8 = null;
    var event_mode: run_mod.EventMode = .none;
    var bound_services = run_mod.BoundServiceBindingList{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--backend")) {
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "restore", args, &i, arg);
            backend = run_mod.Backend.parse(raw) orelse {
                const message = "--backend must be auto, hvf, or kvm";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "restore"), message);
            };
        } else if (std.mem.startsWith(u8, arg, "--backend=")) {
            const raw = arg["--backend=".len..];
            backend = run_mod.Backend.parse(raw) orelse {
                const message = "--backend must be auto, hvf, or kvm";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "restore"), message);
            };
        } else if (std.mem.eql(u8, arg, "--generation")) {
            generation_path = takeValueLifecycleCli(allocator, stderr, mode, "restore", args, &i, arg);
        } else if (std.mem.startsWith(u8, arg, "--generation=")) {
            generation_path = arg["--generation=".len..];
        } else if (std.mem.eql(u8, arg, "--events")) {
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "restore", args, &i, arg);
            event_mode = run_mod.EventMode.parse(raw) orelse {
                const message = "--events must be jsonl";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "restore"), message);
            };
        } else if (std.mem.startsWith(u8, arg, "--events=")) {
            const raw = arg["--events=".len..];
            event_mode = run_mod.EventMode.parse(raw) orelse {
                const message = "--events must be jsonl";
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "restore"), message);
            };
        } else if (std.mem.eql(u8, arg, "--name")) {
            name = takeValueLifecycleCli(allocator, stderr, mode, "restore", args, &i, arg);
            validateNameLifecycleCli(allocator, stderr, mode, "restore", name.?);
        } else if (std.mem.startsWith(u8, arg, "--name=")) {
            name = arg["--name=".len..];
            validateNameLifecycleCli(allocator, stderr, mode, "restore", name.?);
        } else if (std.mem.eql(u8, arg, "--bind-service")) {
            const raw = takeValueLifecycleCli(allocator, stderr, mode, "restore", args, &i, arg);
            bound_services.append(spore_net_policy.parseBoundServiceBinding(raw) catch |err| {
                const message = allocLifecycleMessage(allocator, "spore restore: invalid --bind-service {s}: {s}", .{ raw, @errorName(err) });
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "restore"), message);
            }) catch |err| {
                const message = allocLifecycleMessage(allocator, "spore restore: invalid --bind-service {s}: {s}", .{ raw, @errorName(err) });
                exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "restore"), message);
            };
        } else if (std.mem.startsWith(u8, arg, "--")) {
            const message = allocLifecycleMessage(allocator, "unknown restore argument: {s}", .{arg});
            exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, "restore"), message);
        } else if (spore_dir == null) {
            spore_dir = arg;
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
            machine_output.usageMissingArgument("usage: spore restore DIR --name NAME", "restore"),
            restore_usage,
        );
    }
    return .{
        .spore_dir = spore_dir.?,
        .name = name.?,
        .backend = backend,
        .generation_path = generation_path,
        .event_mode = event_mode,
        .bound_services = bound_services,
    };
}

fn apiPaths(context: Context, allocator: std.mem.Allocator, name: []const u8) !Paths {
    const paths = try pathsFor(allocator, context.environ_map, name);
    try validateExistingRuntimeDirs(context.io, paths);
    return paths;
}

fn resolveNewOutputDirApi(allocator: std.mem.Allocator, io: Io, raw: []const u8) ![]const u8 {
    const path = try std.fs.path.resolve(allocator, &.{raw});
    if (try pathExists(io, path)) return error.OutputDirExists;
    const parent = std.fs.path.dirname(path) orelse ".";
    const stat = Io.Dir.cwd().statFile(io, parent, .{ .follow_symlinks = true }) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidOutputDir,
        else => |e| return e,
    };
    if (stat.kind != Io.File.Kind.directory) return error.InvalidOutputDir;
    if (std.fs.path.isAbsolute(path)) return path;
    // Output directories cross process boundaries (the monitor receives them
    // over the control socket and resolves them against its own cwd), so a
    // relative --out must become absolute before it leaves this process.
    const abs_parent = try absoluteExistingDirPath(allocator, parent);
    return std.fs.path.join(allocator, &.{ abs_parent, std.fs.path.basename(path) });
}

fn absoluteExistingDirPath(allocator: std.mem.Allocator, path: []const u8) error{ OutOfMemory, InvalidOutputDir }![]const u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    var buf: [std.c.PATH_MAX]u8 = undefined;
    const resolved = std.c.realpath(path_z, &buf) orelse return error.InvalidOutputDir;
    return allocator.dupe(u8, std.mem.span(resolved));
}

fn temporarySiblingOutputDir(allocator: std.mem.Allocator, io: Io, out_dir: []const u8) ![]const u8 {
    const parent = std.fs.path.dirname(out_dir) orelse return error.InvalidOutputDir;
    const base = std.fs.path.basename(out_dir);
    const now: u64 = @intCast(Io.Clock.real.now(io).nanoseconds);
    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        const name = try std.fmt.allocPrint(allocator, ".{s}.tmp-{x}-{d}", .{ base, now, attempt });
        const path = try std.fs.path.resolve(allocator, &.{ parent, name });
        if (!try pathExists(io, path)) return path;
    }
    return error.OutputDirExists;
}

fn resolveExistingSporeDirApi(allocator: std.mem.Allocator, io: Io, raw: []const u8) ![]const u8 {
    const path = try std.fs.path.resolve(allocator, &.{raw});
    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != Io.File.Kind.directory) return error.InvalidSporeDir;
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
    metadata.resume_generation = null;
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

const ForkNamePlaceholder = struct {
    start: usize,
    end: usize,
    width: usize = 0,
};

fn renderForkNames(allocator: std.mem.Allocator, pattern: []const u8, count: usize) ![]const []const u8 {
    const placeholder = try findForkNamePlaceholder(pattern);
    if (count > 1 and placeholder == null) return error.MissingForkNamePlaceholder;
    const names = try allocator.alloc([]const u8, count);
    var name_count: usize = 0;
    errdefer {
        for (names[0..name_count]) |name| allocator.free(name);
        allocator.free(names);
    }
    for (names, 0..) |*slot, index| {
        slot.* = try renderForkName(allocator, pattern, placeholder, index);
        name_count += 1;
        try validateName(slot.*);
        for (names[0..index]) |previous| {
            if (std.mem.eql(u8, previous, slot.*)) return error.DuplicateForkName;
        }
    }
    return names;
}

fn findForkNamePlaceholder(pattern: []const u8) !?ForkNamePlaceholder {
    var found: ?ForkNamePlaceholder = null;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, pattern, i, '%')) |start| {
        if (found != null) return error.InvalidForkNamePattern;
        if (start + 1 >= pattern.len) return error.InvalidForkNamePattern;

        var cursor = start + 1;
        var width: usize = 0;
        if (pattern[cursor] == '0') {
            cursor += 1;
            if (cursor >= pattern.len or !std.ascii.isDigit(pattern[cursor])) return error.InvalidForkNamePattern;
            while (cursor < pattern.len and std.ascii.isDigit(pattern[cursor])) : (cursor += 1) {
                width = std.math.mul(usize, width, 10) catch return error.InvalidForkNamePattern;
                width = std.math.add(usize, width, pattern[cursor] - '0') catch return error.InvalidForkNamePattern;
                if (width > max_name_len) return error.InvalidForkNamePattern;
            }
            if (cursor >= pattern.len or pattern[cursor] != 'd') return error.InvalidForkNamePattern;
        } else if (pattern[cursor] != 'd') {
            return error.InvalidForkNamePattern;
        }
        found = .{ .start = start, .end = cursor + 1, .width = width };
        i = cursor + 1;
    }
    return found;
}

fn renderForkName(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    placeholder: ?ForkNamePlaceholder,
    index: usize,
) ![]const u8 {
    const marker = placeholder orelse return allocator.dupe(u8, pattern);
    const digits = try std.fmt.allocPrint(allocator, "{d}", .{index});
    defer allocator.free(digits);
    const prefix = pattern[0..marker.start];
    const suffix = pattern[marker.end..];
    const padding = if (marker.width > digits.len) marker.width - digits.len else 0;
    const out = try allocator.alloc(u8, prefix.len + padding + digits.len + suffix.len);
    var offset: usize = 0;
    @memcpy(out[offset..][0..prefix.len], prefix);
    offset += prefix.len;
    @memset(out[offset..][0..padding], '0');
    offset += padding;
    @memcpy(out[offset..][0..digits.len], digits);
    offset += digits.len;
    @memcpy(out[offset..][0..suffix.len], suffix);
    return out;
}

fn hiddenForkBatchDir(allocator: std.mem.Allocator, runtime_root: []const u8, source_name: []const u8) ![]const u8 {
    const pid: i64 = if (comptime builtin.os.tag == .windows) 1 else @intCast(std.c.getpid());
    const leaf = try std.fmt.allocPrint(allocator, "{s}-{d}-{d}", .{ source_name, pid, monotonicMs() });
    return std.fs.path.resolve(allocator, &.{ runtime_root, "forks", leaf });
}

fn childSporeDir(allocator: std.mem.Allocator, children_dir: []const u8, index: usize) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{d:0>6}", .{ children_dir, index });
}

fn startForkChildExecutable(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    child_name: []const u8,
    spore_dir: []const u8,
    base: Spec,
    spore_executable: []const u8,
) !void {
    var manifest = spore.loadManifest(allocator, spore_dir) catch |err| switch (err) {
        error.BadManifest => null,
        else => return error.InvalidSporeDir,
    };
    defer if (manifest) |*parsed| parsed.deinit();
    var manifest_v1: ?std.json.Parsed(spore.ManifestV1) = null;
    defer if (manifest_v1) |*parsed| parsed.deinit();
    if (manifest == null) {
        manifest_v1 = spore.loadManifestV1(allocator, spore_dir) catch return error.InvalidSporeDir;
    }

    const network = if (manifest) |parsed| parsed.value.network else manifest_v1.?.value.network;
    if (network != null) return error.UnsupportedNamedForkNetwork;
    const devices_len = if (manifest) |parsed| parsed.value.devices.len else manifest_v1.?.value.devices.len;
    if (devices_len != diskless_resume_device_count) return error.UnsupportedNamedForkDisk;
    const ram_size = if (manifest) |parsed| parsed.value.platform.ram_size else manifest_v1.?.value.platform.ram_size;
    const memory = try memory_config.fromManifestBytes(ram_size);
    const manifest_vcpus = if (manifest_v1) |parsed| parsed.value.platform.vcpu_count else @as(topology.VcpuCount, 1);
    const spec = Spec{
        .name = child_name,
        .backend = base.backend,
        .kernel_path = base.kernel_path,
        .initrd_path = base.initrd_path,
        .resume_dir = spore_dir,
        .annotations = if (manifest) |parsed| parsed.value.annotations else manifest_v1.?.value.annotations,
        .sessions = if (manifest) |parsed| parsed.value.sessions else manifest_v1.?.value.sessions,
        .memory = memory,
        .vcpus = manifest_vcpus,
        .guest_port = base.guest_port,
        .timeout_ms = base.timeout_ms,
        .console_log_path = null,
    };
    const paths = try apiPaths(.{ .io = init.io, .environ_map = init.environ_map }, allocator, child_name);
    const spore_executable_path = try spawnMonitorExecutable(init, allocator, paths, spec, spore_executable, null);
    try waitForReadyResult(allocator, init.io, paths, spec.timeout_ms, spore_executable_path);
}

fn cleanupStartedChildren(init: std.process.Init, allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |name| {
        const paths = pathsFor(allocator, init.environ_map, name) catch continue;
        var ready = readReady(allocator, init.io, paths) catch {
            Io.Dir.cwd().deleteTree(init.io, paths.vm_dir) catch {};
            continue;
        };
        stopReadyMonitor(allocator, init.io, paths, ready.value) catch {
            ready.deinit();
            continue;
        };
        ready.deinit();
        Io.Dir.cwd().deleteTree(init.io, paths.vm_dir) catch {};
    }
}

fn writeNamedForkResult(writer: *Io.Writer, result: NamedForkResult) !void {
    try writer.writeAll("forked");
    for (result.children) |name| try writer.print(" {s}", .{name});
    try writer.writeByte('\n');
}

fn writeNamedLifecycleResult(writer: *Io.Writer, result: NamedLifecycleResult) !void {
    if (std.mem.eql(u8, result.action, "created")) {
        try writer.print("created vm {s}\n", .{result.name});
    } else if (std.mem.eql(u8, result.action, "restored")) {
        try writer.print("restored vm {s}\n", .{result.name});
    } else if (std.mem.eql(u8, result.action, "saved")) {
        try writer.print("saved {s}; vm {s} is still running\n", .{ result.spore_dir orelse result.name, result.name });
    } else if (std.mem.eql(u8, result.action, "saved_stopped")) {
        try writer.print("saved {s} and stopped vm {s}\n", .{ result.spore_dir orelse result.name, result.name });
        if ((result.saved_sessions orelse 0) > 0) {
            try writer.writeAll("spore has a saved session; use `spore attach <spore>` to reconnect, or `spore run --from <spore> ...` to run new commands.\n");
        } else {
            try writer.writeAll("spore has no saved session; use `spore run --from <spore> ...` to run new commands, or `spore run --save <spore> --save-on TERM ...` if you want fanout to attach to the original command.\n");
        }
    } else if (std.mem.eql(u8, result.action, "removed")) {
        try writer.print("removed vm {s}\n", .{result.name});
    } else {
        try writer.print("{s} vm {s}\n", .{ result.action, result.name });
    }
}

fn spawnMonitorExecutable(init: std.process.Init, allocator: std.mem.Allocator, paths: Paths, spec: Spec, exe: []const u8, network_policy: ?*const run_mod.NetworkPolicy) ![]const u8 {
    // Fail before spawning: an oversized socket path would otherwise only
    // surface as a monitor readiness timeout.
    try validateControlSocketPath(paths.control_socket_path);
    try ensureVmDir(init.io, paths);
    const resolved_exe = try resolveSpawnExecutable(allocator, init.io, init.environ_map, exe);
    errdefer allocator.free(resolved_exe);
    // Skip the pre-spawn version probe when re-exec'ing the current process:
    // self-exec cannot skew, and running an embedder binary with a bare
    // "version" argv (without the re-exec environment) would invoke the
    // embedder's own CLI.
    if (!isSelfExecutable(init.io, allocator, resolved_exe)) {
        const executable_version = querySporeExecutableVersion(init, allocator, resolved_exe) catch {
            setStartupError(allocator, init.io, paths, spec.name, resolved_exe, "could not read spore executable version");
            return error.SporeExecutableVersionUnavailable;
        };
        defer allocator.free(executable_version);
        if (!std.mem.eql(u8, executable_version, version.value)) {
            const reason = try std.fmt.allocPrint(allocator, "libspore {s} cannot use spore executable {s} at {s}", .{ version.value, executable_version, resolved_exe });
            defer allocator.free(reason);
            setStartupError(
                allocator,
                init.io,
                paths,
                spec.name,
                resolved_exe,
                reason,
            );
            return error.MonitorVersionMismatch;
        }
    }

    var monitor_log = try createFileAtPath(init.io, paths.monitor_log_path);
    defer monitor_log.close(init.io);

    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.append(resolved_exe);
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
    if (network_policy) |policy| {
        if (spec.network != null) try appendMonitorNetworkPolicyArgs(allocator, &argv, policy);
    } else if (spec.network) |network| {
        try appendMonitorNetworkManifestArgs(allocator, &argv, network);
    }
    try appendMemoryArg(allocator, &argv, spec.memory);
    try appendIntArg(allocator, &argv, "--vcpus", spec.vcpus);
    try appendIntArg(allocator, &argv, "--guest-port", spec.guest_port);
    try argv.append("--timeout");
    try argv.append(try std.fmt.allocPrint(allocator, "{d}ms", .{spec.timeout_ms}));
    if (spec.console_log_path) |path| {
        try argv.append("--console-log");
        try argv.append(path);
    }
    var child_env = try init.environ_map.clone(allocator);
    try child_env.put(reexec_role_env, "monitor");
    try child_env.put(reexec_contract_env, reexec_contract_value);
    _ = try std.process.spawn(init.io, .{
        .argv = argv.items,
        .environ_map = &child_env,
        .stdin = .ignore,
        .stdout = .{ .file = monitor_log },
        .stderr = .{ .file = monitor_log },
        .pgid = if (builtin.os.tag == .windows) null else 0,
    });
    return resolved_exe;
}

test "lifecycle monitor spawn receives context environment" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fs.path.resolve(allocator, &.{"zig-cache/test-monitor-env"});
    defer allocator.free(root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try ensureDirPath(io, root);

    const script_path = try std.fs.path.resolve(allocator, &.{ root, "monitor-env.sh" });
    defer allocator.free(script_path);
    const out_path = try std.fs.path.resolve(allocator, &.{ root, "home.txt" });
    defer allocator.free(out_path);
    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\nif [ \"$1\" = version ]; then printf 'spore {s} (test)\\n'; exit 0; fi\nprintf '%s\\n%s\\n%s\\n' \"$HOME\" \"$SPORE_REEXEC_ROLE\" \"$SPORE_REEXEC_CONTRACT\" > \"$SPOREVM_TEST_ENV_OUT\"\n",
        .{version.value},
    );
    defer allocator.free(script);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = script_path,
        .data = script,
    });
    try Io.Dir.cwd().setFilePermissions(io, script_path, @enumFromInt(0o755), .{});

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/sporevm-context-home");
    try env.put("SPOREVM_TEST_ENV_OUT", out_path);

    var spawn_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer spawn_arena_state.deinit();
    const spawn_arena = spawn_arena_state.allocator();
    const paths = try pathsFromRoot(spawn_arena, root, "env-probe");

    _ = try spawnMonitorExecutable(.{
        .minimal = undefined,
        .arena = undefined,
        .gpa = allocator,
        .io = io,
        .environ_map = &env,
        .preopens = .empty,
    }, spawn_arena, paths, .{
        .name = "env-probe",
        .backend = "auto",
    }, script_path, null);

    var observed: ?[]u8 = null;
    defer if (observed) |bytes| allocator.free(bytes);
    const start = monotonicMs();
    while (monotonicMs() - start < 2_000) {
        observed = Io.Dir.cwd().readFileAlloc(io, out_path, allocator, .limited(4096)) catch |err| switch (err) {
            error.FileNotFound => {
                sleepMs(20);
                continue;
            },
            else => |e| return e,
        };
        break;
    }
    try std.testing.expect(observed != null);
    try std.testing.expectEqualStrings("/tmp/sporevm-context-home\nmonitor\n1\n", observed.?);
}

fn appendMonitorNetworkPolicyArgs(allocator: std.mem.Allocator, argv: *std.array_list.Managed([]const u8), policy: *const run_mod.NetworkPolicy) !void {
    try argv.append("--net");
    if (policy.default_deny) {
        try argv.append("--default-action");
        try argv.append(spore.network_default_deny);
    }
    for (policy.allowCidrSlice()) |cidr| {
        try argv.append("--allow-cidr");
        try argv.append(cidr);
    }
    for (policy.allowHostSlice()) |host| {
        try argv.append("--allow-host");
        try argv.append(host);
    }
    for (policy.exactRuleSlice()) |rule| {
        for (rule.portSlice()) |port| {
            try argv.append("--allow-host-port");
            try argv.append(try std.fmt.allocPrint(allocator, "{s}:{d}", .{ rule.host, port }));
        }
    }
    for (policy.boundServiceSlice()) |service| {
        try argv.append("--bound-unix-service");
        try argv.append(service.name);
        try argv.append(service.guest_host);
        try argv.append(try std.fmt.allocPrint(allocator, "{d}", .{service.guest_port}));
        try argv.append(service.unix_path);
    }
    for (policy.portForwardSlice()) |forward| {
        try argv.append("--forward");
        try argv.append(try std.fmt.allocPrint(allocator, "127.0.0.1:{d}:{d}", .{ forward.host_port, forward.guest_port }));
    }
}

fn appendMonitorNetworkManifestArgs(allocator: std.mem.Allocator, argv: *std.array_list.Managed([]const u8), network: spore.Network) !void {
    if (network.bound_services.len != 0) return error.UnsupportedBoundServiceRestore;
    try argv.append("--net");
    if (network.default_action) |action| {
        if (!std.mem.eql(u8, action, spore.network_default_deny)) return error.InvalidNetworkPolicy;
        try argv.append("--default-action");
        try argv.append(action);
    }
    for (network.allow_cidrs) |cidr| {
        try argv.append("--allow-cidr");
        try argv.append(cidr);
    }
    for (network.allow_hosts) |host| {
        try argv.append("--allow-host");
        try argv.append(host);
    }
    for (network.allow_host_ports) |rule| {
        for (rule.ports) |port| {
            try argv.append("--allow-host-port");
            try argv.append(try std.fmt.allocPrint(allocator, "{s}:{d}", .{ rule.host, port }));
        }
    }
}

fn appendIntArg(allocator: std.mem.Allocator, argv: *std.array_list.Managed([]const u8), flag: []const u8, value: anytype) !void {
    try argv.append(flag);
    try argv.append(try std.fmt.allocPrint(allocator, "{d}", .{value}));
}

fn appendMemoryArg(allocator: std.mem.Allocator, argv: *std.array_list.Managed([]const u8), memory: memory_config.Config) !void {
    try argv.append("--memory");
    try argv.append(try memory.cliValueAlloc(allocator));
}

fn resolveSpawnExecutable(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, exe: []const u8) ![]const u8 {
    if (exe.len == 0) return error.InvalidSporeExecutable;
    if (Io.Dir.path.isAbsolute(exe) or std.mem.indexOfScalar(u8, exe, std.fs.path.sep) != null) {
        return std.fs.path.resolve(allocator, &.{exe});
    }
    const path = environ.get("PATH") orelse return allocator.dupe(u8, exe);
    var parts = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
    while (parts.next()) |part| {
        const dir = if (part.len == 0) "." else part;
        const candidate = try std.fs.path.resolve(allocator, &.{ dir, exe });
        const stat = Io.Dir.cwd().statFile(io, candidate, .{ .follow_symlinks = true }) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(candidate);
                continue;
            },
            else => {
                allocator.free(candidate);
                return err;
            },
        };
        if (stat.kind == Io.File.Kind.file) return candidate;
        allocator.free(candidate);
    }
    return allocator.dupe(u8, exe);
}

fn isSelfExecutable(io: Io, allocator: std.mem.Allocator, resolved_exe: []const u8) bool {
    const self_path = std.process.executablePathAlloc(io, allocator) catch return false;
    defer allocator.free(self_path);
    if (std.mem.eql(u8, self_path, resolved_exe)) return true;
    // resolveSpawnExecutable is lexical, so compare through symlinks too:
    // an embedder may hand us its own path via a symlink.
    const real_exe = Io.Dir.cwd().realPathFileAlloc(io, resolved_exe, allocator) catch return false;
    defer allocator.free(real_exe);
    return std.mem.eql(u8, self_path, real_exe);
}

fn querySporeExecutableVersion(init: std.process.Init, allocator: std.mem.Allocator, exe: []const u8) ![]const u8 {
    var child = try std.process.spawn(init.io, .{
        .argv = &.{ exe, "version" },
        .environ_map = init.environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(init.io);
    const stdout_fd = child.stdout.?.handle;
    child.stdout = null;
    defer _ = std.c.close(stdout_fd);

    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();
    var buf: [256]u8 = undefined;
    while (output.items.len < 1024) {
        const n = std.c.read(stdout_fd, &buf, buf.len);
        if (n < 0) {
            switch (std.c.errno(n)) {
                .INTR => continue,
                else => return error.SporeExecutableVersionUnavailable,
            }
        }
        if (n == 0) break;
        try output.appendSlice(buf[0..@intCast(n)]);
    }
    const term = try child.wait(init.io);
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return error.SporeExecutableVersionUnavailable;
    return parseSporeVersionOutput(allocator, output.items);
}

fn parseSporeVersionOutput(allocator: std.mem.Allocator, output: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "spore ")) return error.SporeExecutableVersionUnavailable;
    var rest = trimmed["spore ".len..];
    const end = std.mem.indexOfAny(u8, rest, " \t\r\n") orelse rest.len;
    rest = rest[0..end];
    if (rest.len == 0) return error.SporeExecutableVersionUnavailable;
    return allocator.dupe(u8, rest);
}

test "lifecycle parses spore executable version output" {
    const allocator = std.testing.allocator;

    const plain = try parseSporeVersionOutput(allocator, "spore 1.5.0\n");
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("1.5.0", plain);

    const decorated = try parseSporeVersionOutput(allocator, "spore 1.5.0 (test build)\n");
    defer allocator.free(decorated);
    try std.testing.expectEqualStrings("1.5.0", decorated);

    try std.testing.expectError(error.SporeExecutableVersionUnavailable, parseSporeVersionOutput(allocator, "spore\n"));
    try std.testing.expectError(error.SporeExecutableVersionUnavailable, parseSporeVersionOutput(allocator, "other 1.5.0\n"));
}

const FakeHelloServer = struct {
    io: Io,
    server: net.Server,
    response: []const u8,
};

fn fakeHelloServerMain(fake: *FakeHelloServer) void {
    var stream = fake.server.accept(fake.io) catch return;
    defer stream.close(fake.io);

    var read_buffer: [256]u8 = undefined;
    var reader = stream.reader(fake.io, &read_buffer);
    _ = reader.interface.takeDelimiterExclusive('\n') catch return;
    writeAll(fake.io, stream, fake.response) catch return;
    writeAll(fake.io, stream, "\n") catch return;
}

fn readyPollSleep(attempt: *u32) void {
    const delay_ms: u64 = if (attempt.* < 10) 1 else 20;
    attempt.* +|= 1;
    sleepMs(delay_ms);
}

fn waitForReadyResult(allocator: std.mem.Allocator, io: Io, paths: Paths, timeout_ms: u64, spore_executable_path: []const u8) !void {
    const start = monotonicMs();
    var sleep_attempt: u32 = 0;
    while (monotonicMs() - start < timeout_ms) {
        var ready = readReady(allocator, io, paths) catch {
            readyPollSleep(&sleep_attempt);
            continue;
        };
        if (!pidAlive(ready.value.pid)) {
            ready.deinit();
            readyPollSleep(&sleep_attempt);
            continue;
        }
        verifyMonitorHelloWithPath(allocator, io, ready.value.control_socket_path, spore_executable_path) catch |err| switch (err) {
            error.MonitorVersionMismatch => {
                ready.deinit();
                return err;
            },
            // Transient failures (socket races, monitor mid-start, garbage
            // responders) retry until the diagnosed readiness timeout.
            else => {
                ready.deinit();
                readyPollSleep(&sleep_attempt);
                continue;
            },
        };
        ready.deinit();
        return;
    }
    setStartupError(allocator, io, paths, std.fs.path.basename(paths.vm_dir), spore_executable_path, "timed out waiting for monitor readiness");
    return error.MonitorReadyTimeout;
}

fn createFileAtPath(io: Io, path: []const u8) !Io.File {
    if (Io.Dir.path.isAbsolute(path)) return Io.Dir.createFileAbsolute(io, path, .{});
    return Io.Dir.cwd().createFile(io, path, .{});
}

fn setStartupError(allocator: std.mem.Allocator, io: Io, paths: Paths, name: []const u8, spore_executable_path: []const u8, reason: []const u8) void {
    const state = classifyVmState(allocator, io, paths, pidAlive) catch VmState.incomplete;
    const pid = readPid(allocator, io, paths) catch null;
    setLastError(
        "named VM {s} startup failed: {s}; state={s} pid={?d} console_log={s} monitor_log={s} control_socket={s} spore_executable={s}",
        .{ name, reason, state.name(), pid, paths.console_log_path, paths.monitor_log_path, paths.control_socket_path, spore_executable_path },
    );
}

fn namedVmNotReady(allocator: std.mem.Allocator, io: Io, paths: Paths, operation: []const u8, name: []const u8, state: VmState) anyerror {
    const pid = readPid(allocator, io, paths) catch null;
    setLastError(
        "named VM {s} is not ready for {s}: state={s} pid={?d} console_log={s} monitor_log={s} control_socket={s}",
        .{ name, operation, state.name(), pid, paths.console_log_path, paths.monitor_log_path, paths.control_socket_path },
    );
    return error.NamedVmNotReady;
}

fn namedVmExists(allocator: std.mem.Allocator, io: Io, paths: Paths, operation: []const u8, name: []const u8, state: VmState) anyerror {
    const pid = readPid(allocator, io, paths) catch null;
    setLastError(
        "named VM {s} already exists for {s}: state={s} pid={?d} console_log={s} monitor_log={s} control_socket={s}",
        .{ name, operation, state.name(), pid, paths.console_log_path, paths.monitor_log_path, paths.control_socket_path },
    );
    return error.NamedVmExists;
}

test "lifecycle readiness requires monitor control socket hello" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fs.path.resolve(allocator, &.{"zig-cache/test-lifecycle-ready-hello"});
    defer allocator.free(root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);

    const pid = currentTestPid();
    try writeSpec(allocator, io, paths, .{ .name = "bench-1", .timeout_ms = 40 });
    try writeReady(allocator, io, paths, .{
        .pid = pid,
        .control_socket_path = paths.control_socket_path,
        .console_log_path = paths.console_log_path,
    });
    try writePid(allocator, io, paths, pid);

    clearLastError();
    try std.testing.expectError(error.MonitorReadyTimeout, waitForReadyResult(allocator, io, paths, 40, "/tmp/spore-1.5.0"));
    const detail = lastErrorMessage();
    try std.testing.expect(std.mem.indexOf(u8, detail, "timed out waiting for monitor readiness") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "state=ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, paths.console_log_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, paths.monitor_log_path) != null);
}

test "lifecycle readiness fails on monitor version mismatch" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fs.path.resolve(allocator, &.{"zig-cache/test-lifecycle-ready-version"});
    defer allocator.free(root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);

    const pid = currentTestPid();
    try writeSpec(allocator, io, paths, .{ .name = "bench-1" });
    try writeReady(allocator, io, paths, .{
        .pid = pid,
        .control_socket_path = paths.control_socket_path,
        .console_log_path = paths.console_log_path,
    });
    try writePid(allocator, io, paths, pid);

    Io.Dir.cwd().deleteFile(io, paths.control_socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    const address = try net.UnixAddress.init(paths.control_socket_path);
    var fake = FakeHelloServer{
        .io = io,
        .server = try address.listen(io, .{ .kernel_backlog = 1 }),
        .response = "{\"type\":\"hello\",\"schema\":\"spore.monitor.hello.v1\",\"spore_version\":\"1.3.0\",\"helper_contract\":1}",
    };
    const thread = try std.Thread.spawn(.{}, fakeHelloServerMain, .{&fake});
    defer thread.join();
    defer fake.server.deinit(io);

    clearLastError();
    try std.testing.expectError(error.MonitorVersionMismatch, waitForReadyResult(allocator, io, paths, 1_000, "/tmp/spore-1.3.0"));
    const expected = try std.fmt.allocPrint(allocator, "libspore {s} cannot use spore executable 1.3.0 at /tmp/spore-1.3.0", .{version.value});
    defer allocator.free(expected);
    const detail = lastErrorMessage();
    try std.testing.expect(std.mem.indexOf(u8, detail, expected) != null);
}

test "lifecycle named not ready diagnostics include state pid and logs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fs.path.resolve(allocator, &.{"/tmp/sporevm-test-lifecycle-not-ready-detail"});
    defer allocator.free(root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);

    const dead_pid: i64 = 999_999_999;
    try writeSpec(allocator, io, paths, .{ .name = "bench-1" });
    try writeReady(allocator, io, paths, .{
        .pid = dead_pid,
        .control_socket_path = paths.control_socket_path,
        .console_log_path = paths.console_log_path,
    });
    try writePid(allocator, io, paths, dead_pid);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(runtime_dir_env, root);

    clearLastError();
    try std.testing.expectError(error.NamedVmNotReady, execNamed(.{
        .io = io,
        .environ_map = &env,
    }, allocator, .{
        .name = "bench-1",
        .command = &.{"/bin/true"},
    }));

    const detail = lastErrorMessage();
    try std.testing.expect(std.mem.indexOf(u8, detail, "state=stale") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "pid=999999999") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, paths.console_log_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, paths.monitor_log_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, paths.control_socket_path) != null);
}

test "lifecycle named exists diagnostics include stale state and logs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fs.path.resolve(allocator, &.{"/tmp/sporevm-test-lifecycle-exists-detail"});
    defer allocator.free(root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);

    const dead_pid: i64 = 999_999_998;
    try writeSpec(allocator, io, paths, .{ .name = "bench-1" });
    try writeReady(allocator, io, paths, .{
        .pid = dead_pid,
        .control_socket_path = paths.control_socket_path,
        .console_log_path = paths.console_log_path,
    });
    try writePid(allocator, io, paths, dead_pid);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(runtime_dir_env, root);

    clearLastError();
    try std.testing.expectError(error.NamedVmExists, createNamed(.{
        .minimal = undefined,
        .arena = undefined,
        .gpa = allocator,
        .io = io,
        .environ_map = &env,
        .preopens = .empty,
    }, allocator, .{
        .name = "bench-1",
    }));

    const detail = lastErrorMessage();
    try std.testing.expect(std.mem.indexOf(u8, detail, "state=stale") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "pid=999999998") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, paths.console_log_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, paths.monitor_log_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, paths.control_socket_path) != null);
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

fn openExecNamedStreamAt(context: Context, allocator: std.mem.Allocator, socket_path: []const u8, options: ExecNamedStreamOptions) !ExecNamedStream {
    const payload = struct {
        type: []const u8 = "exec-stream-v1",
        argv: []const []const u8,
        stdio: []const u8,
        interactive: bool,
        term: []const u8,
        terminal_rows: u16,
        terminal_cols: u16,
    }{
        .argv = options.command,
        .stdio = if (options.tty) "tty" else "pipe",
        .interactive = options.interactive,
        .term = options.terminal_name,
        .terminal_rows = options.terminal_size.rows,
        .terminal_cols = options.terminal_size.cols,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);

    try verifyMonitorHello(allocator, context.io, socket_path);
    const address = try controlSocketAddress(socket_path);
    const stream = address.connect(context.io) catch return error.MonitorUnavailable;
    errdefer stream.close(context.io);
    writeAll(context.io, stream, json) catch return error.MonitorUnavailable;
    writeAll(context.io, stream, "\n") catch return error.MonitorUnavailable;
    return .{ .io = context.io, .stream = stream };
}

fn execStreamControl(context: Context, allocator: std.mem.Allocator, socket_path: []const u8, options: ExecNamedStreamOptions) !u8 {
    var stream = try openExecNamedStreamAt(context, allocator, socket_path, options);
    defer stream.deinit();
    var raw_terminal: ?ExecRawTerminal = null;
    if (options.tty and options.interactive) raw_terminal = try ExecRawTerminal.enable();
    defer if (raw_terminal) |*raw| raw.deinit();

    var resize_registration: ?ExecResizeRegistration = null;
    if (options.tty) {
        resize_registration = ExecResizeRegistration.install();
        execResizeNotify();
    }
    defer if (resize_registration) |*registration| registration.deinit();

    var pump = ExecStreamPump{
        .stream = &stream,
        .interactive = options.interactive,
        .tty = options.tty,
    };
    return pump.run();
}

fn copyStreamControl(
    context: Context,
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    request_type: []const u8,
    guest_path: []const u8,
    fds: CopyStreamFds,
) !u8 {
    var stream = try openCopyNamedStreamAt(context, allocator, socket_path, request_type, guest_path);
    defer stream.deinit();

    var pump = ExecStreamPump{
        .stream = &stream,
        .interactive = std.mem.eql(u8, request_type, "copy-in-v1"),
        .tty = false,
        .input_fd = fds.input_fd,
        .stdout_fd = fds.stdout_fd,
        .stderr_fd = fds.stderr_fd,
    };
    return pump.run();
}

fn openCopyNamedStreamAt(
    context: Context,
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    request_type: []const u8,
    guest_path: []const u8,
) !ExecNamedStream {
    const payload = struct {
        type: []const u8,
        path: []const u8,
    }{
        .type = request_type,
        .path = guest_path,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);

    try verifyMonitorHello(allocator, context.io, socket_path);
    const address = try controlSocketAddress(socket_path);
    const stream = address.connect(context.io) catch return error.MonitorUnavailable;
    errdefer stream.close(context.io);
    writeAll(context.io, stream, json) catch return error.MonitorUnavailable;
    writeAll(context.io, stream, "\n") catch return error.MonitorUnavailable;
    return .{ .io = context.io, .stream = stream };
}

fn sendStartRequest(allocator: std.mem.Allocator, io: Io, socket_path: []const u8, argv: []const []const u8) ![]const u8 {
    const payload = struct {
        type: []const u8 = "start",
        argv: []const []const u8,
    }{ .argv = argv };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    return sendControlJson(allocator, io, socket_path, json);
}

fn sendShutdownRequest(allocator: std.mem.Allocator, io: Io, socket_path: []const u8) ![]const u8 {
    return sendControlJsonRaw(allocator, io, socket_path, "{\"type\":\"shutdown\"}");
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

fn sendSnapshotRequest(allocator: std.mem.Allocator, io: Io, socket_path: []const u8, out_dir: []const u8) ![]const u8 {
    const payload = struct {
        type: []const u8 = "snapshot",
        out_dir: []const u8,
        @"continue": bool = true,
    }{ .out_dir = out_dir };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    return sendControlJson(allocator, io, socket_path, json);
}

fn sendControlJson(allocator: std.mem.Allocator, io: Io, socket_path: []const u8, json: []const u8) ![]const u8 {
    try verifyMonitorHello(allocator, io, socket_path);
    return sendControlJsonRaw(allocator, io, socket_path, json);
}

fn sendControlJsonRaw(allocator: std.mem.Allocator, io: Io, socket_path: []const u8, json: []const u8) ![]const u8 {
    const address = try controlSocketAddress(socket_path);
    const stream = address.connect(io) catch return error.MonitorUnavailable;
    defer stream.close(io);
    writeAll(io, stream, json) catch return error.MonitorUnavailable;
    writeAll(io, stream, "\n") catch return error.MonitorUnavailable;

    var read_buffer: [max_control_response]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const line = reader.interface.takeDelimiterExclusive('\n') catch return error.MonitorUnavailable;
    return allocator.dupe(u8, line);
}

const MonitorHelloResponse = struct {
    type: []const u8,
    schema: ?[]const u8 = null,
    spore_version: ?[]const u8 = null,
    helper_contract: ?u32 = null,
};

fn verifyMonitorHello(allocator: std.mem.Allocator, io: Io, socket_path: []const u8) !void {
    try verifyMonitorHelloWithPath(allocator, io, socket_path, null);
}

fn verifyMonitorHelloWithPath(allocator: std.mem.Allocator, io: Io, socket_path: []const u8, spore_executable_path: ?[]const u8) !void {
    const response = try sendControlJsonRaw(allocator, io, socket_path, "{\"type\":\"hello\"}");
    defer allocator.free(response);
    try validateMonitorHello(allocator, response, spore_executable_path);
}

fn validateMonitorHello(allocator: std.mem.Allocator, response: []const u8, spore_executable_path: ?[]const u8) !void {
    var parsed = std.json.parseFromSlice(MonitorHelloResponse, allocator, response, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.BadMonitorResponse;
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.type, "hello")) return monitorHelloMismatch(parsed.value, spore_executable_path);
    if (!std.mem.eql(u8, parsed.value.schema orelse "", monitor_hello_schema)) return monitorHelloMismatch(parsed.value, spore_executable_path);
    if (!std.mem.eql(u8, parsed.value.spore_version orelse "", version.value)) return monitorHelloMismatch(parsed.value, spore_executable_path);
    if ((parsed.value.helper_contract orelse 0) != monitor_helper_contract) return monitorHelloMismatch(parsed.value, spore_executable_path);
}

fn monitorHelloMismatch(hello: MonitorHelloResponse, spore_executable_path: ?[]const u8) error{MonitorVersionMismatch} {
    const reported = hello.spore_version orelse "unknown";
    if (spore_executable_path) |path| {
        setLastError("libspore {s} cannot use spore executable {s} at {s}", .{ version.value, reported, path });
    } else {
        setLastError("libspore {s} cannot use monitor helper reporting version {s}", .{ version.value, reported });
    }
    return error.MonitorVersionMismatch;
}

const CopyStreamFds = struct {
    input_fd: std.c.fd_t = 0,
    stdout_fd: std.c.fd_t = 1,
    stderr_fd: std.c.fd_t = 2,
};

const ExecStreamPump = struct {
    stream: *ExecNamedStream,
    interactive: bool,
    tty: bool,
    input_fd: std.c.fd_t = 0,
    stdout_fd: std.c.fd_t = 1,
    stderr_fd: std.c.fd_t = 2,
    stdin_closed: bool = false,
    resize_seen: u32 = 0,

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
                if (self.stdout_fd >= 0) try writeFdAll(self.stdout_fd, bytes);
                return null;
            },
            .stderr => |bytes| {
                if (self.stderr_fd >= 0) try writeFdAll(self.stderr_fd, bytes);
                return null;
            },
            .exit => |code| return code,
            .err => |bytes| {
                if (self.stderr_fd >= 0) {
                    try writeFdAll(self.stderr_fd, bytes);
                    if (bytes.len != 0 and bytes[bytes.len - 1] != '\n') try writeFdAll(self.stderr_fd, "\n");
                }
                return error.MonitorRequestFailed;
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
        const count = exec_resize_count.load(.acquire);
        if (count == self.resize_seen) return;
        self.resize_seen = count;
        try self.stream.resizeTerminal(terminalSizeOrDefault(terminalSizeFd()));
    }
};

const ExecRawTerminal = struct {
    saved: std.c.termios,
    active: bool = true,

    fn enable() !ExecRawTerminal {
        var current: std.c.termios = undefined;
        if (std.c.tcgetattr(0, &current) != 0) return error.TerminalRawModeFailed;
        var raw = current;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.oflag.OPOST = false;
        if (std.c.tcsetattr(0, .NOW, &raw) != 0) return error.TerminalRawModeFailed;
        return .{ .saved = current };
    }

    fn deinit(self: *ExecRawTerminal) void {
        if (!self.active) return;
        var saved = self.saved;
        _ = std.c.tcsetattr(0, .NOW, &saved);
        self.active = false;
    }
};

var exec_resize_count: std.atomic.Value(u32) = .init(0);

const ExecResizeRegistration = struct {
    old_action: std.posix.Sigaction,
    active: bool = true,

    fn install() ExecResizeRegistration {
        var old_action: std.posix.Sigaction = undefined;
        const action = std.posix.Sigaction{
            .handler = .{ .sigaction = handleExecResize },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.SIGINFO,
        };
        std.posix.sigaction(.WINCH, &action, &old_action);
        return .{ .old_action = old_action };
    }

    fn deinit(self: *ExecResizeRegistration) void {
        if (!self.active) return;
        std.posix.sigaction(.WINCH, &self.old_action, null);
        self.active = false;
    }
};

fn handleExecResize(_: std.posix.SIG, _: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    execResizeNotify();
}

fn execResizeNotify() void {
    _ = exec_resize_count.fetchAdd(1, .acq_rel);
}

fn terminalName(environ: *const std.process.Environ.Map) []const u8 {
    return environ.get("TERM") orelse "xterm";
}

fn ioctlRequest(comptime request: anytype) c_int {
    const raw: u32 = @truncate(@as(usize, request));
    return @bitCast(raw);
}

fn terminalSizeOrDefault(fd: std.c.fd_t) spore_stream.Resize {
    var size: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    if (std.c.ioctl(fd, ioctlRequest(std.posix.T.IOCGWINSZ), &size) == 0 and size.row > 0 and size.col > 0) {
        return .{ .rows = size.row, .cols = size.col };
    }
    return .{ .rows = 24, .cols = 80 };
}

fn terminalSizeFd() std.c.fd_t {
    return if (std.c.isatty(1) != 0) 1 else if (std.c.isatty(0) != 0) 0 else 1;
}

const ControlResponse = struct {
    type: []const u8,
    exit_code: ?i32 = null,
    stdout_b64: ?[]const u8 = null,
    stderr_b64: ?[]const u8 = null,
    network_events_jsonl_b64: ?[]const u8 = null,
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
    out_dir: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

fn writeExecNamedResult(stdout: *Io.Writer, result: ExecNamedResult) !void {
    try stdout.writeAll(result.stdout);
    try stdout.flush();
    try writeRawStderr(result.stderr);
    if (result.stdout_truncated) try writeRawStderr("spore exec: stdout truncated after 16384 bytes\n");
    if (result.stderr_truncated) try writeRawStderr("spore exec: stderr truncated after 16384 bytes\n");
}

fn parseExecNamedResponse(
    allocator: std.mem.Allocator,
    parse_allocator: std.mem.Allocator,
    response: []const u8,
) !ExecNamedResult {
    var parsed = try std.json.parseFromSlice(ControlResponse, parse_allocator, response, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.type, "exec_result")) return error.MonitorRequestFailed;
    const exit_code = parsed.value.exit_code orelse return error.BadMonitorResponse;
    if (exit_code < 0 or exit_code > 255) return error.BadMonitorResponse;

    const stdout = try decodeControlOutput(allocator, parsed.value.stdout_b64 orelse return error.BadMonitorResponse);
    errdefer allocator.free(stdout);
    const stderr = try decodeControlOutput(allocator, parsed.value.stderr_b64 orelse return error.BadMonitorResponse);
    errdefer allocator.free(stderr);
    const network_events_jsonl = if (parsed.value.network_events_jsonl_b64) |encoded|
        try decodeControlOutput(allocator, encoded)
    else
        try allocator.dupe(u8, "");
    errdefer allocator.free(network_events_jsonl);
    return .{
        .exit_code = @intCast(exit_code),
        .stdout = stdout,
        .stderr = stderr,
        .network_events_jsonl = network_events_jsonl,
        .stdout_truncated = parsed.value.stdout_truncated,
        .stderr_truncated = parsed.value.stderr_truncated,
    };
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

fn snapshotResponseOk(allocator: std.mem.Allocator, response: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(ControlResponse, allocator, response, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    return std.mem.eql(u8, parsed.value.type, "snapshotted");
}

fn readMonitorStats(allocator: std.mem.Allocator, io: Io, paths: Paths) !MonitorStats {
    const data = try Io.Dir.cwd().readFileAlloc(io, paths.monitor_stats_path, allocator, .limited(max_metadata_bytes));
    defer allocator.free(data);
    var parsed = try std.json.parseFromSlice(MonitorStats, allocator, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    return parsed.value;
}

fn ownedNamedLifecycleResult(allocator: std.mem.Allocator, result: NamedLifecycleResult) !NamedLifecycleResult {
    const name = try allocator.dupe(u8, result.name);
    errdefer allocator.free(name);
    const console_log_path = if (result.console_log_path) |path| try allocator.dupe(u8, path) else null;
    errdefer if (console_log_path) |path| allocator.free(path);
    const spore_dir = if (result.spore_dir) |path| try allocator.dupe(u8, path) else null;
    return .{
        .action = result.action,
        .name = name,
        .state = result.state,
        .pid = result.pid,
        .console_log_path = console_log_path,
        .spore_dir = spore_dir,
        .saved_sessions = result.saved_sessions,
    };
}

fn ownedNamedForkResult(allocator: std.mem.Allocator, result: NamedForkResult) !NamedForkResult {
    const source = try allocator.dupe(u8, result.source);
    errdefer allocator.free(source);
    const children = try allocator.alloc([]const u8, result.children.len);
    errdefer allocator.free(children);
    var child_count: usize = 0;
    errdefer {
        for (children[0..child_count]) |owned| allocator.free(owned);
    }
    for (result.children, children) |child, *out| {
        out.* = try allocator.dupe(u8, child);
        child_count += 1;
    }
    return .{
        .source = source,
        .count = result.count,
        .children = children,
    };
}

fn writeAll(io: Io, stream: net.Stream, bytes: []const u8) !void {
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn readFdExact(fd: std.c.fd_t, buf: []u8) !void {
    var remaining = buf;
    while (remaining.len > 0) {
        const n = std.c.read(fd, remaining.ptr, remaining.len);
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

fn decodeControlOutput(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const dec = std.base64.standard.Decoder;
    const decoded_size = dec.calcSizeForSlice(encoded) catch return error.BadMonitorResponse;
    if (decoded_size > max_control_response) return error.BadMonitorResponse;
    const decoded = try allocator.alloc(u8, decoded_size);
    errdefer allocator.free(decoded);
    dec.decode(decoded, encoded) catch return error.BadMonitorResponse;
    return decoded;
}

const copy_archive_magic = "SPCP1\n\x00\n";
const copy_record_header_len = 16;
const max_copy_archive_path = 512;

const CopyArchiveKind = enum(u8) {
    file = 'F',
    directory = 'D',
    end = 'E',
};

const CopyArchive = struct {
    allocator: std.mem.Allocator,
    dir: [:0]u8,
    path: []const u8,

    fn deinit(self: *CopyArchive, io: Io) void {
        Io.Dir.cwd().deleteTree(io, self.dir) catch {};
        self.allocator.free(self.path);
        self.allocator.free(self.dir);
    }
};

fn exitAfterCopyArchiveCleanup(archive: *CopyArchive, io: Io, code: u8) noreturn {
    archive.deinit(io);
    std.process.exit(code);
}

const CopyRecord = struct {
    kind: CopyArchiveKind,
    path: []const u8,
    mode: u32,
    size: u64,
};

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

fn createCopyArchive(allocator: std.mem.Allocator, io: Io, host_path: []const u8) !CopyArchive {
    var archive = try createEmptyCopyArchive(allocator, io);
    errdefer archive.deinit(io);

    var file = try Io.Dir.createFileAbsolute(io, archive.path, .{
        .exclusive = true,
        .permissions = @enumFromInt(0o600),
    });
    defer file.close(io);

    try file.writeStreamingAll(io, copy_archive_magic);
    try writeHostPathArchive(allocator, io, file, host_path);
    try writeCopyRecordHeader(file, io, .end, "", 0, 0);
    return archive;
}

fn createEmptyCopyArchive(allocator: std.mem.Allocator, io: Io) !CopyArchive {
    _ = io;
    const tmpl = "/tmp/sporevm-copy-XXXXXX";
    const dir = try allocator.dupeZ(u8, tmpl);
    errdefer allocator.free(dir);
    if (mkdtemp(dir) == null) return error.IoFailed;
    const path = try std.fmt.allocPrint(allocator, "{s}/payload.spcp", .{std.mem.sliceTo(dir, 0)});
    errdefer allocator.free(path);
    return .{ .allocator = allocator, .dir = dir, .path = path };
}

fn writeHostPathArchive(allocator: std.mem.Allocator, io: Io, archive: Io.File, host_path: []const u8) !void {
    const stat = try Io.Dir.cwd().statFile(io, host_path, .{ .follow_symlinks = false });
    switch (stat.kind) {
        .file => try writeHostFileRecord(io, archive, Io.Dir.cwd(), host_path, "", stat),
        .directory => {
            try writeCopyRecordHeader(archive, io, .directory, "", modeFromStat(stat), 0);
            var dir = try openDirPath(io, host_path, .{ .iterate = true, .follow_symlinks = false });
            defer dir.close(io);
            var walker = try dir.walk(allocator);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                try validateCopyArchivePath(entry.path, false);
                const entry_stat = try entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false });
                switch (entry.kind) {
                    .file => try writeHostFileRecord(io, archive, entry.dir, entry.basename, entry.path, entry_stat),
                    .directory => try writeCopyRecordHeader(archive, io, .directory, entry.path, modeFromStat(entry_stat), 0),
                    else => return error.UnsupportedCopyEntry,
                }
            }
        },
        else => return error.UnsupportedCopyEntry,
    }
}

fn writeHostFileRecord(
    io: Io,
    archive: Io.File,
    source_dir: Io.Dir,
    source_path: []const u8,
    archive_path: []const u8,
    stat: Io.File.Stat,
) !void {
    if (stat.kind != .file) return error.UnsupportedCopyEntry;
    try writeCopyRecordHeader(archive, io, .file, archive_path, modeFromStat(stat), stat.size);
    const open_options: Io.Dir.OpenFileOptions = .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    };
    var source = if (Io.Dir.path.isAbsolute(source_path))
        try Io.Dir.openFileAbsolute(io, source_path, open_options)
    else
        try source_dir.openFile(io, source_path, open_options);
    defer source.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var remaining = stat.size;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, buf.len));
        const n = source.readStreaming(io, &.{buf[0..want]}) catch |err| switch (err) {
            error.EndOfStream => return error.ShortRead,
            else => |e| return e,
        };
        if (n == 0) return error.ShortRead;
        try archive.writeStreamingAll(io, buf[0..n]);
        remaining -= n;
    }
}

fn writeCopyRecordHeader(
    archive: Io.File,
    io: Io,
    kind: CopyArchiveKind,
    archive_path: []const u8,
    mode: u32,
    size: u64,
) !void {
    if (kind != .end) try validateCopyArchivePath(archive_path, true);
    if (archive_path.len > max_copy_archive_path) return error.NameTooLong;
    var header: [copy_record_header_len]u8 = undefined;
    header[0] = @intFromEnum(kind);
    std.mem.writeInt(u16, header[1..3], @intCast(archive_path.len), .little);
    std.mem.writeInt(u32, header[3..7], mode & 0o777, .little);
    std.mem.writeInt(u64, header[7..15], size, .little);
    header[15] = 0;
    try archive.writeStreamingAll(io, &header);
    if (archive_path.len != 0) try archive.writeStreamingAll(io, archive_path);
}

fn extractCopyArchive(allocator: std.mem.Allocator, io: Io, archive_path: []const u8, host_path: []const u8) !void {
    var archive = try Io.Dir.openFileAbsolute(io, archive_path, .{ .mode = .read_only, .allow_directory = false });
    defer archive.close(io);

    var magic: [copy_archive_magic.len]u8 = undefined;
    try readArchiveExact(archive, io, &magic);
    if (!std.mem.eql(u8, &magic, copy_archive_magic)) return error.BadCopyArchive;

    var path_buf: [max_copy_archive_path]u8 = undefined;
    const root = try readCopyRecord(archive, io, &path_buf);
    if (root.path.len != 0) return error.BadCopyArchive;
    switch (root.kind) {
        .file => {
            const fd = try createHostOutputFile(allocator, host_path, root.mode);
            var keep = false;
            defer {
                _ = std.c.close(fd);
                if (!keep) Io.Dir.cwd().deleteFile(io, host_path) catch {};
            }
            try copyArchiveFileToFd(archive, io, fd, root.size);
            try expectCopyArchiveEnd(archive, io, &path_buf);
            try expectCopyArchiveEof(archive, io);
            keep = true;
        },
        .directory => {
            try createHostOutputDir(allocator, host_path, root.mode);
            var keep = false;
            defer if (!keep) Io.Dir.cwd().deleteTree(io, host_path) catch {};
            while (true) {
                const record = try readCopyRecord(archive, io, &path_buf);
                if (record.kind == .end) break;
                if (record.path.len == 0) return error.BadCopyArchive;
                const target = try std.fs.path.join(allocator, &.{ host_path, record.path });
                defer allocator.free(target);
                switch (record.kind) {
                    .file => {
                        const fd = try createHostOutputFile(allocator, target, record.mode);
                        defer _ = std.c.close(fd);
                        try copyArchiveFileToFd(archive, io, fd, record.size);
                    },
                    .directory => try createHostOutputDir(allocator, target, record.mode),
                    .end => unreachable,
                }
            }
            try expectCopyArchiveEof(archive, io);
            keep = true;
        },
        .end => return error.BadCopyArchive,
    }
}

fn readCopyRecord(archive: Io.File, io: Io, path_buf: *[max_copy_archive_path]u8) !CopyRecord {
    var header: [copy_record_header_len]u8 = undefined;
    try readArchiveExact(archive, io, &header);
    const kind: CopyArchiveKind = switch (header[0]) {
        @intFromEnum(CopyArchiveKind.file) => .file,
        @intFromEnum(CopyArchiveKind.directory) => .directory,
        @intFromEnum(CopyArchiveKind.end) => .end,
        else => return error.BadCopyArchive,
    };
    const path_len = std.mem.readInt(u16, header[1..3], .little);
    const mode = std.mem.readInt(u32, header[3..7], .little);
    const size = std.mem.readInt(u64, header[7..15], .little);
    if (header[15] != 0 or path_len > path_buf.len or (mode & ~@as(u32, 0o777)) != 0) return error.BadCopyArchive;
    const path = path_buf[0..path_len];
    if (path.len != 0) try readArchiveExact(archive, io, path);
    if (kind == .end) {
        if (path.len != 0 or mode != 0 or size != 0) return error.BadCopyArchive;
    } else {
        try validateCopyArchivePath(path, true);
        if (kind == .directory and size != 0) return error.BadCopyArchive;
    }
    return .{ .kind = kind, .path = path, .mode = mode & 0o777, .size = size };
}

fn expectCopyArchiveEnd(archive: Io.File, io: Io, path_buf: *[max_copy_archive_path]u8) !void {
    const record = try readCopyRecord(archive, io, path_buf);
    if (record.kind != .end) return error.BadCopyArchive;
}

fn expectCopyArchiveEof(archive: Io.File, io: Io) !void {
    var byte: [1]u8 = undefined;
    const n = archive.readStreaming(io, &.{byte[0..]}) catch |err| switch (err) {
        error.EndOfStream => return,
        else => |e| return e,
    };
    if (n == 0) return;
    return error.BadCopyArchive;
}

fn readArchiveExact(archive: Io.File, io: Io, buf: []u8) !void {
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = archive.readStreaming(io, &.{buf[filled..]}) catch |err| switch (err) {
            error.EndOfStream => return error.BadCopyArchive,
            else => |e| return e,
        };
        if (n == 0) return error.BadCopyArchive;
        filled += n;
    }
}

fn copyArchiveFileToFd(archive: Io.File, io: Io, fd: std.c.fd_t, size: u64) !void {
    var remaining = size;
    var buf: [64 * 1024]u8 = undefined;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, buf.len));
        try readArchiveExact(archive, io, buf[0..want]);
        try writeFdAll(fd, buf[0..want]);
        remaining -= want;
    }
}

fn validateCopyArchivePath(path: []const u8, allow_root: bool) !void {
    if (path.len == 0) {
        if (allow_root) return;
        return error.BadCopyArchivePath;
    }
    if (path.len > max_copy_archive_path or path[0] == '/' or path[path.len - 1] == '/') return error.BadCopyArchivePath;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0) return error.BadCopyArchivePath;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.BadCopyArchivePath;
        if (std.mem.indexOfScalar(u8, part, 0) != null) return error.BadCopyArchivePath;
    }
}

fn createHostOutputFile(allocator: std.mem.Allocator, path: []const u8, mode: u32) !std.c.fd_t {
    const fd = try openHostFileCreate(allocator, path);
    if (std.c.fchmod(fd, @intCast(mode & 0o777)) != 0) {
        _ = std.c.close(fd);
        return error.ChmodFailed;
    }
    return fd;
}

fn createHostOutputDir(allocator: std.mem.Allocator, path: []const u8, mode: u32) !void {
    const pathz = try allocator.dupeZ(u8, path);
    defer allocator.free(pathz);
    if (std.c.mkdir(pathz, @intCast((mode & 0o777) | 0o700)) != 0) return error.CreateDirFailed;
}

fn modeFromStat(stat: Io.File.Stat) u32 {
    return @intCast(@intFromEnum(stat.permissions) & 0o777);
}

fn openHostFileRead(allocator: std.mem.Allocator, io: Io, path: []const u8) !std.c.fd_t {
    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.NotRegularFile;
    const pathz = try allocator.dupeZ(u8, path);
    defer allocator.free(pathz);
    const fd = std.c.open(pathz, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.OpenFailed;
    return fd;
}

fn openHostFileCreate(allocator: std.mem.Allocator, path: []const u8) !std.c.fd_t {
    const pathz = try allocator.dupeZ(u8, path);
    defer allocator.free(pathz);
    const fd = std.c.open(pathz, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0o600));
    if (fd < 0) return error.OpenFailed;
    return fd;
}

fn writeRawStderr(bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(2, remaining.ptr, remaining.len);
        if (n <= 0) return error.StderrWriteFailed;
        remaining = remaining[@intCast(n)..];
    }
}

const MonitorStopResult = enum {
    stopped,
    timed_out,
};

fn stopReadyMonitor(allocator: std.mem.Allocator, io: Io, paths: Paths, ready: Ready) !void {
    const shutdown_requested = if (sendShutdownRequest(allocator, io, ready.control_socket_path)) |_| true else |_| false;
    if (shutdown_requested) return finishAcceptedMonitorStop(io, paths, ready.pid);
    return finishMonitorPidExit(paths, ready.pid);
}

fn finishAcceptedMonitorStop(io: Io, paths: Paths, pid: i64) !void {
    if (waitForAcceptedMonitorStop(io, paths, pid, monitor_shutdown_grace_ms, pidAlive) == .stopped) return;

    signalMonitorProcessGroup(pid, .TERM);
    if (waitForAcceptedMonitorStop(io, paths, pid, monitor_shutdown_term_ms, pidAlive) == .stopped) return;

    signalMonitorProcessGroup(pid, .KILL);
    if (waitForAcceptedMonitorStop(io, paths, pid, monitor_shutdown_kill_ms, pidAlive) == .stopped) return;

    setMonitorShutdownError(paths, pid);
    return error.MonitorShutdownTimedOut;
}

fn finishMonitorPidExit(paths: Paths, pid: i64) !void {
    if (waitForPidExit(pid, monitor_shutdown_grace_ms, pidAlive) == .stopped) return;

    signalMonitorProcessGroup(pid, .TERM);
    if (waitForPidExit(pid, monitor_shutdown_term_ms, pidAlive) == .stopped) return;

    signalMonitorProcessGroup(pid, .KILL);
    if (waitForPidExit(pid, monitor_shutdown_kill_ms, pidAlive) == .stopped) return;

    setMonitorShutdownError(paths, pid);
    return error.MonitorShutdownTimedOut;
}

fn setMonitorShutdownError(paths: Paths, pid: i64) void {
    setLastError(
        "timed out waiting for named VM monitor shutdown: name={s} pid={d} monitor_log={s} control_socket={s}",
        .{ std.fs.path.basename(paths.vm_dir), pid, paths.monitor_log_path, paths.control_socket_path },
    );
}

fn waitForAcceptedMonitorStop(io: Io, paths: Paths, pid: i64, timeout_ms: u64, pid_alive: PidAliveFn) MonitorStopResult {
    const start = monotonicMs();
    while (monotonicMs() - start < timeout_ms) {
        if (!pid_alive(pid)) return .stopped;
        if (!controlSocketExists(io, paths.control_socket_path)) return .stopped;
        sleepMs(20);
    }
    if (!pid_alive(pid)) return .stopped;
    if (!controlSocketExists(io, paths.control_socket_path)) return .stopped;
    return .timed_out;
}

fn waitForPidExit(pid: i64, timeout_ms: u64, pid_alive: PidAliveFn) MonitorStopResult {
    const start = monotonicMs();
    while (monotonicMs() - start < timeout_ms) {
        if (!pid_alive(pid)) return .stopped;
        sleepMs(20);
    }
    if (!pid_alive(pid)) return .stopped;
    return .timed_out;
}

fn controlSocketExists(io: Io, path: []const u8) bool {
    _ = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return true,
    };
    return true;
}

fn signalMonitorProcessGroup(pid: i64, signal: std.posix.SIG) void {
    if (pid <= 0) return;
    if (comptime builtin.os.tag == .windows) return;

    const target: std.posix.pid_t = @intCast(pid);
    std.posix.kill(-target, signal) catch {
        std.posix.kill(target, signal) catch {};
    };
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

fn usageExit(comptime text: []const u8) noreturn {
    std.debug.print("{s}", .{text});
    std.process.exit(2);
}

fn allocLifecycleMessage(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(allocator, fmt, args) catch "CLI argument error";
}

fn allocLifecycleLastErrorMessage(allocator: std.mem.Allocator, command: []const u8, fallback: []const u8) []const u8 {
    const detail = lastErrorMessage();
    if (detail.len == 0) return fallback;
    return std.fmt.allocPrint(allocator, "spore {s}: {s}", .{ command, detail }) catch fallback;
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

fn exitLifecycleRuntimePathError(
    allocator: std.mem.Allocator,
    stderr: *Io.Writer,
    mode: machine_output.Mode,
    command: []const u8,
    err: anyerror,
) noreturn {
    const message = switch (err) {
        error.InvalidRuntimeDir => allocLifecycleMessage(allocator, "spore {s}: invalid runtime directory; set {s} or XDG_RUNTIME_DIR to an absolute path", .{ command, runtime_dir_env }),
        error.InsecureRuntimeDir => allocLifecycleMessage(allocator, "spore {s}: insecure runtime directory; registry directories must be private to the current user", .{command}),
        error.ControlSocketPathTooLong => allocLifecycleLastErrorMessage(
            allocator,
            command,
            allocLifecycleMessage(allocator, "spore {s}: control socket path exceeds the platform limit; shorten the VM name or set {s} to a shorter path", .{ command, runtime_dir_env }),
        ),
        else => allocLifecycleMessage(allocator, "spore {s}: runtime directory error: {s}", .{ command, @errorName(err) }),
    };
    exitLifecycleCliError(allocator, stderr, mode, machine_output.usageInvalidArgument(message, command), message);
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
        error.ControlSocketPathTooLong => {
            const detail = lastErrorMessage();
            if (detail.len != 0) {
                std.debug.print("spore {s}: {s}\n", .{ command, detail });
            } else {
                std.debug.print(
                    "spore {s}: control socket path exceeds the platform limit; shorten the VM name or set {s} to a shorter path\n",
                    .{ command, runtime_dir_env },
                );
            }
        },
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
    return run_mod.parseDurationMs(raw) catch {
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

pub fn monitorBackendSupported(raw: []const u8) bool {
    return (run_mod.Backend.parse(raw) orelse return false).supportedOnHost();
}

pub fn wantsNamedFork(args: []const []const u8) bool {
    if (wantsHelp(args)) return true;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--vm") or std.mem.eql(u8, arg, "--name")) return true;
    }
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

test "lifecycle rejects control socket paths that overflow sockaddr_un" {
    const allocator = std.testing.allocator;

    // A deep runtime root plus a long VM name overflows the platform's
    // sun_path limit. Path construction still succeeds so stale registry
    // entries stay listable and removable, but the spawn/connect validation
    // must fail closed with an actionable message instead of timing out or
    // crashing in the monitor.
    const deep_root = "/var/folders/ab/c012345678901234567890123456789/T/deep-runtime-dir";
    const long_name = "a-very-long-vm-name-that-overflows-sun-path";
    var long_paths = try pathsFromRoot(allocator, deep_root, long_name);
    defer long_paths.deinit(allocator);
    try std.testing.expect(long_paths.control_socket_path.len > max_control_socket_path_len);

    clearLastError();
    try std.testing.expectError(
        error.ControlSocketPathTooLong,
        validateControlSocketPath(long_paths.control_socket_path),
    );
    const message = lastErrorMessage();
    try std.testing.expect(std.mem.indexOf(u8, message, "control socket path") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "allows VM names up to") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "shorten the VM name") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, runtime_dir_env) != null);

    try validateControlSocketPath("/tmp/ok.sock");
    const at_limit = "/" ++ ("a" ** (max_control_socket_path_len - 1));
    try validateControlSocketPath(at_limit);
    try std.testing.expectError(error.ControlSocketPathTooLong, validateControlSocketPath(at_limit ++ "b"));
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

test "copy archive paths reject traversal" {
    try validateCopyArchivePath("", true);
    try validateCopyArchivePath("dir/file.txt", false);
    try validateCopyArchivePath("one-two/three_four", false);

    try std.testing.expectError(error.BadCopyArchivePath, validateCopyArchivePath("", false));
    try std.testing.expectError(error.BadCopyArchivePath, validateCopyArchivePath("/absolute", true));
    try std.testing.expectError(error.BadCopyArchivePath, validateCopyArchivePath("dir/", true));
    try std.testing.expectError(error.BadCopyArchivePath, validateCopyArchivePath("dir//file", true));
    try std.testing.expectError(error.BadCopyArchivePath, validateCopyArchivePath(".", true));
    try std.testing.expectError(error.BadCopyArchivePath, validateCopyArchivePath("dir/..", true));
    try std.testing.expectError(error.BadCopyArchivePath, validateCopyArchivePath("dir/./file", true));
    try std.testing.expectError(error.BadCopyArchivePath, validateCopyArchivePath("dir\x00/file", true));
}

test "copy archive extraction writes children under read-only directories" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const pid = if (comptime builtin.os.tag == .windows) 1 else std.c.getpid();
    const root = try std.fmt.allocPrint(allocator, "/tmp/sporevm-test-copy-archive-readonly-{d}", .{pid});
    defer allocator.free(root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = try Io.Dir.cwd().createDirPathStatus(io, root, @enumFromInt(0o755));

    const archive_path = try std.fs.path.join(allocator, &.{ root, "payload.spcp" });
    defer allocator.free(archive_path);
    const out_path = try std.fs.path.join(allocator, &.{ root, "out" });
    defer allocator.free(out_path);
    const child_path = try std.fs.path.join(allocator, &.{ out_path, "child.txt" });
    defer allocator.free(child_path);

    {
        var archive = try Io.Dir.createFileAbsolute(io, archive_path, .{
            .exclusive = true,
            .permissions = @enumFromInt(0o600),
        });
        defer archive.close(io);
        try archive.writeStreamingAll(io, copy_archive_magic);
        try writeCopyRecordHeader(archive, io, .directory, "", 0o555, 0);
        try writeCopyRecordHeader(archive, io, .file, "child.txt", 0o644, 8);
        try archive.writeStreamingAll(io, "readonly");
        try writeCopyRecordHeader(archive, io, .end, "", 0, 0);
    }

    try extractCopyArchive(allocator, io, archive_path, out_path);
    const data = try Io.Dir.cwd().readFileAlloc(io, child_path, allocator, .limited(32));
    defer allocator.free(data);
    try std.testing.expectEqualStrings("readonly", data);
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

test "named exec response decodes owned output" {
    const allocator = std.testing.allocator;
    const response =
        \\{"type":"exec_result","exit_code":7,"stdout_b64":"b2s=","stderr_b64":"ZXJy","network_events_jsonl_b64":"eyJldmVudCI6Im5ldHdvcmtfZGVjaXNpb24ifQo=","stdout_truncated":false,"stderr_truncated":true}
    ;
    const result = try parseExecNamedResponse(allocator, allocator, response);
    defer deinitExecNamedResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 7), result.exit_code);
    try std.testing.expectEqualStrings("ok", result.stdout);
    try std.testing.expectEqualStrings("err", result.stderr);
    try std.testing.expectEqualStrings("{\"event\":\"network_decision\"}\n", result.network_events_jsonl);
    try std.testing.expect(!result.stdout_truncated);
    try std.testing.expect(result.stderr_truncated);
}

test "monitor hello response validates helper version" {
    const allocator = std.testing.allocator;
    const ok = try std.fmt.allocPrint(allocator, "{{\"type\":\"hello\",\"schema\":\"{s}\",\"spore_version\":\"{s}\",\"helper_contract\":{d}}}", .{
        monitor_hello_schema,
        version.value,
        monitor_helper_contract,
    });
    defer allocator.free(ok);
    try validateMonitorHello(allocator, ok, null);

    try std.testing.expectError(error.MonitorVersionMismatch, validateMonitorHello(allocator,
        \\{"type":"error","message":"unknown control request"}
    , null));
    try std.testing.expectError(error.MonitorVersionMismatch, validateMonitorHello(allocator,
        \\{"type":"hello","schema":"spore.monitor.hello.v1","spore_version":"1.3.0","helper_contract":1}
    , null));
    try std.testing.expectError(error.MonitorVersionMismatch, validateMonitorHello(allocator,
        \\{"type":"hello","schema":"spore.monitor.hello.v1","spore_version":"1.5.0","helper_contract":2}
    , null));
}

test "lifecycle renders fork name patterns" {
    const allocator = std.testing.allocator;
    const placeholder = (try findForkNamePlaceholder("worker-%06d")).?;
    const first = try renderForkName(allocator, "worker-%06d", placeholder, 7);
    defer allocator.free(first);
    try std.testing.expectEqualStrings("worker-000007", first);

    const literal = try renderForkName(allocator, "worker", null, 0);
    defer allocator.free(literal);
    try std.testing.expectEqualStrings("worker", literal);

    const names = try renderForkNames(allocator, "worker-%d", 2);
    defer {
        for (names) |name| allocator.free(name);
        allocator.free(names);
    }
    try std.testing.expectEqualStrings("worker-0", names[0]);
    try std.testing.expectEqualStrings("worker-1", names[1]);

    try std.testing.expect(try findForkNamePlaceholder("worker") == null);
    try std.testing.expectError(error.InvalidForkNamePattern, findForkNamePlaceholder("worker-%d-%d"));
    try std.testing.expectError(error.MissingForkNamePlaceholder, renderForkNames(allocator, "worker", 2));
    try std.testing.expectError(error.InvalidVMName, renderForkNames(allocator, "-worker", 1));
}

test "lifecycle fork help routes through named fork cli" {
    try std.testing.expect(wantsNamedFork(&.{"--help"}));
    try std.testing.expect(wantsNamedFork(&.{"-h"}));
    try std.testing.expect(wantsNamedFork(&.{"help"}));
    try std.testing.expect(wantsHelp(&.{ "bench-1", "--help" }));
    try std.testing.expect(!wantsHelp(&.{ "help", "--image", "alpine" }));
    try std.testing.expect(!wantsHelp(&.{ "bench-1", "--", "/bin/true", "--help" }));
    try std.testing.expect(std.mem.indexOf(u8, fork_usage, "spore fork <spore-dir> --count N --out DIR") != null);
    try std.testing.expect(std.mem.indexOf(u8, fork_usage, "spore fork --vm NAME --count N --name PATTERN") != null);
    try std.testing.expect(std.mem.indexOf(u8, fork_usage, "Live --vm fork does not support disk-backed") != null);
    try std.testing.expect(std.mem.indexOf(u8, fork_usage, "spore fanout children --for 10s") != null);
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

test "save validates annotations before touching runtime state" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(runtime_dir_env, "/tmp/sporevm-runtime");

    var annotations = spore.Annotations{};
    defer annotations.deinit(allocator);
    try annotations.map.put(allocator, "", "bad");

    try std.testing.expectError(error.BadManifest, saveContinueNamed(.{
        .io = std.testing.io,
        .environ_map = &env,
    }, allocator, .{
        .name = "bench-1",
        .out_dir = "zig-cache/missing-parent/save.spore",
        .annotations = annotations,
    }));
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
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1/control.sock", paths.control_socket_path);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1/console.log", paths.console_log_path);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime/vms/bench-1/monitor.log", paths.monitor_log_path);
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
        .memory = .{ .policy = .explicit, .bytes = 512 * 1024 * 1024 },
    });
    var spec = try readSpec(allocator, io, paths);
    defer spec.deinit();
    try std.testing.expectEqualStrings("bench-1", spec.value.name);
    try std.testing.expectEqualStrings("hvf", spec.value.backend);
    try std.testing.expectEqualStrings("docker.io/library/alpine:3.20", spec.value.image_ref.?);
    try std.testing.expectEqualStrings("93.184.216.34/32", spec.value.network.?.allow_cidrs[0]);
    try std.testing.expectEqualStrings("example.com", spec.value.network.?.allow_hosts[0]);
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

test "lifecycle monitor stop distinguishes accepted socket close from pid exit" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fs.path.resolve(allocator, &.{"zig-cache/test-lifecycle-monitor-stop"});
    defer allocator.free(root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);

    try ensureVmDir(io, paths);
    const start = monotonicMs();
    try std.testing.expectEqual(
        MonitorStopResult.stopped,
        waitForAcceptedMonitorStop(io, paths, 1234, 5_000, alwaysAlive),
    );
    try std.testing.expect(monotonicMs() -| start < 100);
    try std.testing.expectEqual(
        MonitorStopResult.timed_out,
        waitForPidExit(1234, 15, alwaysAlive),
    );

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = paths.control_socket_path, .data = "" });
    try std.testing.expectEqual(
        MonitorStopResult.timed_out,
        waitForAcceptedMonitorStop(io, paths, 1234, 15, alwaysAlive),
    );
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

test "create parser accepts shell and exact commands" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    const shell_opts = try parseCreateArgs(&.{ "counter", "--image", "alpine:3.20", "echo hi" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(run_mod.CommandMode.shell, shell_opts.command_mode);
    try std.testing.expectEqual(@as(usize, 1), shell_opts.command.len);
    try std.testing.expectEqualStrings("echo hi", shell_opts.command[0]);

    const argv_opts = try parseCreateArgs(&.{ "counter", "--", "/bin/echo", "hi" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(run_mod.CommandMode.argv, argv_opts.command_mode);
    try std.testing.expectEqual(@as(usize, 2), argv_opts.command.len);
    try std.testing.expectEqualStrings("/bin/echo", argv_opts.command[0]);
    try std.testing.expectEqualStrings("hi", argv_opts.command[1]);
}

test "exec parser accepts shell and exact commands" {
    const shell_opts = parseExecArgs(&.{ "counter", "cat /tick" });
    try std.testing.expectEqualStrings("counter", shell_opts.name);
    try std.testing.expectEqual(run_mod.CommandMode.shell, shell_opts.command_mode);
    try std.testing.expectEqual(@as(usize, 1), shell_opts.command.len);
    try std.testing.expectEqualStrings("cat /tick", shell_opts.command[0]);
    try std.testing.expect(!shell_opts.interactive);
    try std.testing.expect(!shell_opts.tty);

    const argv_opts = parseExecArgs(&.{ "counter", "--", "/bin/cat", "/tick" });
    try std.testing.expectEqual(run_mod.CommandMode.argv, argv_opts.command_mode);
    try std.testing.expectEqual(@as(usize, 2), argv_opts.command.len);
    try std.testing.expectEqualStrings("/bin/cat", argv_opts.command[0]);
    try std.testing.expectEqualStrings("/tick", argv_opts.command[1]);

    const hyphen_shell_opts = parseExecArgs(&.{ "counter", "-c test" });
    try std.testing.expectEqual(run_mod.CommandMode.shell, hyphen_shell_opts.command_mode);
    try std.testing.expectEqualStrings("-c test", hyphen_shell_opts.command[0]);
}

test "exec parser accepts interactive and tty flags" {
    const combined_opts = parseExecArgs(&.{ "-it", "box", "--", "/bin/sh" });
    try std.testing.expectEqualStrings("box", combined_opts.name);
    try std.testing.expectEqual(run_mod.CommandMode.argv, combined_opts.command_mode);
    try std.testing.expect(combined_opts.interactive);
    try std.testing.expect(combined_opts.tty);
    try std.testing.expectEqualStrings("/bin/sh", combined_opts.command[0]);

    const long_opts = parseExecArgs(&.{ "--interactive", "--tty", "box", "cat" });
    try std.testing.expectEqualStrings("box", long_opts.name);
    try std.testing.expectEqual(run_mod.CommandMode.shell, long_opts.command_mode);
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
    try std.testing.expectEqual(run_mod.PullPolicy.missing, default_opts.image_pull_policy);

    const equals_opts = try parseCreateArgs(&.{ "bench-1", "--pull=always", "--image", "docker.io/library/alpine:3.20" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(run_mod.PullPolicy.always, equals_opts.image_pull_policy);

    const value_opts = try parseCreateArgs(&.{ "bench-1", "--image", "docker.io/library/alpine:3.20", "--pull", "never" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(run_mod.PullPolicy.never, value_opts.image_pull_policy);
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

    try std.testing.expectEqual(run_mod.NetworkMode.spore, opts.network);
    try std.testing.expectEqual(@as(usize, 1), opts.network_policy.allow_cidr_count);
    try std.testing.expectEqualStrings("93.184.216.34/32", opts.network_policy.allow_cidrs[0]);
    try std.testing.expectEqual(@as(usize, 1), opts.network_policy.allow_host_count);
    try std.testing.expectEqualStrings("example.com", opts.network_policy.allow_hosts[0]);
    try std.testing.expectEqual(@as(usize, 1), opts.network_policy.port_forward_count);
    try std.testing.expectEqual(@as(u16, 8080), opts.network_policy.port_forwards[0].host_port);
    try std.testing.expectEqual(@as(u16, 80), opts.network_policy.port_forwards[0].guest_port);
}

test "create parser accepts annotations exact host ports and bound services" {
    const allocator = std.testing.allocator;
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
    try std.testing.expectEqual(@as(usize, 1), opts.network_policy.exact_rule_count);
    try std.testing.expectEqualStrings("github.com", opts.network_policy.exact_rules[0].host);
    try std.testing.expectEqual(@as(u16, 443), opts.network_policy.exact_rules[0].ports[0]);
    try std.testing.expectEqual(@as(usize, 1), opts.network_policy.bound_service_count);
    try std.testing.expectEqualStrings("metadata", opts.network_policy.bound_services[0].name);
    try std.testing.expectEqual(@as(u16, 8170), opts.network_policy.bound_services[0].guest_port);
    try std.testing.expectEqualStrings("/tmp/metadata.sock", opts.network_policy.bound_services[0].unix_path);
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
    try std.testing.expectEqual(memory_config.Policy.explicit, opts.spec.memory.policy);
    try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), opts.spec.memory.bytes);
    try std.testing.expectEqual(@as(topology.VcpuCount, 2), opts.spec.vcpus);
    try std.testing.expectEqual(@as(u64, 120_000), opts.spec.timeout_ms);
    try std.testing.expectEqual(run_mod.NetworkMode.spore, opts.network);
    try std.testing.expectEqualStrings("93.184.216.34/32", opts.network_policy.allow_cidrs[0]);
    try std.testing.expectEqualStrings("example.com", opts.network_policy.allow_hosts[0]);
    try std.testing.expectEqualStrings("github.com", opts.network_policy.exact_rules[0].host);
    try std.testing.expectEqual(@as(u16, 443), opts.network_policy.exact_rules[0].ports[0]);
    try std.testing.expectEqualStrings("metadata", opts.network_policy.bound_services[0].name);
    try std.testing.expectEqualStrings("metadata.cleanroom.internal", opts.network_policy.bound_services[0].guest_host);
    try std.testing.expectEqual(@as(u16, 8170), opts.network_policy.bound_services[0].guest_port);
    try std.testing.expectEqualStrings("/tmp/metadata.sock", opts.network_policy.bound_services[0].unix_path);
    const services = try createBoundServicesFromConfig(arena, &opts.network_policy);
    try std.testing.expectEqualStrings("metadata.cleanroom.internal", services[0].guest_host);
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

test "create cli network rule conversion owns port slices" {
    var policy = run_mod.NetworkPolicy{};
    try policy.addExactHostPorts("github.com", &.{443});
    try policy.addExactHostPorts("example.com", &.{8443});

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rules = try createNetworkRulesFromConfig(arena, &policy);

    try std.testing.expectEqual(@as(usize, 2), rules.len);
    try std.testing.expectEqualStrings("github.com", rules[0].host);
    try std.testing.expectEqual(@as(u16, 443), rules[0].ports[0]);
    try std.testing.expectEqualStrings("example.com", rules[1].host);
    try std.testing.expectEqual(@as(u16, 8443), rules[1].ports[0]);
    try std.testing.expect(rules[0].ports.ptr != policy.exact_rules[0].portSlice().ptr);
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

test "named network config accepts create cli policy" {
    const config = try namedNetworkConfig(.{
        .enabled = true,
        .allow_cidrs = &.{"93.184.216.34/32"},
        .allow_hosts = &.{"example.com"},
        .policy = .{ .allow = &.{.{
            .host = "github.com",
            .ports = &.{443},
        }} },
        .bound_services = &.{.{
            .name = "metadata",
            .guest_host = "metadata.spore.internal",
            .guest_port = 8170,
            .target = .{ .unix = "/tmp/metadata.sock" },
        }},
        .port_forwards = &.{.{ .host_port = 8080, .guest_port = 80 }},
    });

    try std.testing.expectEqual(run_mod.NetworkMode.spore, config.mode);
    try std.testing.expectEqual(@as(usize, 1), config.policy.allow_cidr_count);
    try std.testing.expectEqualStrings("93.184.216.34/32", config.policy.allow_cidrs[0]);
    try std.testing.expectEqual(@as(usize, 1), config.policy.allow_host_count);
    try std.testing.expectEqualStrings("example.com", config.policy.allow_hosts[0]);
    try std.testing.expectEqual(@as(usize, 1), config.policy.exact_rule_count);
    try std.testing.expectEqualStrings("github.com", config.policy.exact_rules[0].host);
    try std.testing.expectEqual(@as(u16, 443), config.policy.exact_rules[0].ports[0]);
    try std.testing.expectEqual(@as(usize, 1), config.policy.bound_service_count);
    try std.testing.expectEqualStrings("metadata", config.policy.bound_services[0].name);
    try std.testing.expectEqualStrings("metadata.spore.internal", config.policy.bound_services[0].guest_host);
    try std.testing.expectEqual(@as(u16, 8170), config.policy.bound_services[0].guest_port);
    try std.testing.expectEqualStrings("/tmp/metadata.sock", config.policy.bound_services[0].unix_path);
    try std.testing.expectEqual(@as(usize, 1), config.policy.port_forward_count);
    try std.testing.expectEqual(@as(u16, 8080), config.policy.port_forwards[0].host_port);
    try std.testing.expectEqual(@as(u16, 80), config.policy.port_forwards[0].guest_port);
}

test "named network config keeps bare network unrestricted" {
    const config = try namedNetworkConfig(.{ .enabled = true });

    try std.testing.expectEqual(run_mod.NetworkMode.spore, config.mode);
    try std.testing.expect(!config.policy.default_deny);
    try std.testing.expect(!config.policy.hasRules());
}

test "lifecycle monitor policy args preserve default deny" {
    var argv = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer argv.deinit();
    const policy = run_mod.NetworkPolicy{ .default_deny = true };

    try appendMonitorNetworkPolicyArgs(std.testing.allocator, &argv, &policy);

    try std.testing.expectEqual(@as(usize, 3), argv.items.len);
    try std.testing.expectEqualStrings("--net", argv.items[0]);
    try std.testing.expectEqualStrings("--default-action", argv.items[1]);
    try std.testing.expectEqualStrings(spore.network_default_deny, argv.items[2]);
}

test "lifecycle monitor manifest args preserve default action" {
    var argv = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer argv.deinit();

    try appendMonitorNetworkManifestArgs(std.testing.allocator, &argv, .{
        .default_action = spore.network_default_deny,
    });

    try std.testing.expectEqual(@as(usize, 3), argv.items.len);
    try std.testing.expectEqualStrings("--net", argv.items[0]);
    try std.testing.expectEqualStrings("--default-action", argv.items[1]);
    try std.testing.expectEqualStrings(spore.network_default_deny, argv.items[2]);
}

test "new output dirs resolve to absolute paths" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    const resolved = try resolveNewOutputDirApi(arena, io, "lifecycle-test-does-not-exist.spore");
    try std.testing.expect(std.fs.path.isAbsolute(resolved));
    try std.testing.expect(std.mem.endsWith(u8, resolved, "/lifecycle-test-does-not-exist.spore"));

    try std.testing.expectError(error.OutputDirExists, resolveNewOutputDirApi(arena, io, "."));
    try std.testing.expectError(error.InvalidOutputDir, resolveNewOutputDirApi(arena, io, "lifecycle-test-missing-parent/child.spore"));
}

test "save parser accepts annotations and stop" {
    const allocator = std.testing.allocator;
    var stderr: Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();

    var opts = parseSaveArgs(&.{ "bench-1", "--out", "bench-1.spore", "--stop", "--annotation", "saved=true=1" }, allocator, &stderr.writer, .human);
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

    const opts = parseRestoreArgs(&.{ "bench-1.spore", "--name", "bench-2", "--bind-service", "metadata=unix:/tmp/metadata.sock" }, allocator, &stderr.writer, .human);
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

    const opts = parseRestoreArgs(&.{ "--events=jsonl", "--backend", "kvm", "--generation", "generation.json", "child.spore", "--name=sporevm-child-42" }, allocator, &stderr.writer, .human);
    try std.testing.expectEqual(run_mod.EventMode.jsonl, opts.event_mode);
    try std.testing.expectEqual(run_mod.Backend.kvm, opts.backend.?);
    try std.testing.expectEqualStrings("generation.json", opts.generation_path.?);
    try std.testing.expectEqualStrings("child.spore", opts.spore_dir);
    try std.testing.expectEqualStrings("sporevm-child-42", opts.name);
}

test "named restore event mode emits terminal run event" {
    const allocator = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var events = run_mod.EventWriter.init(allocator, &out.writer, "restore");
    try events.emitStart(.kvm);
    try emitNamedRestoreExit(&events, .kvm);

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"event\":\"exit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"command\":\"restore\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"exit_code\":0") != null);
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
    const stale_spore_dir = try std.fs.path.resolve(allocator, &.{ root, "b-stale.spore" });
    defer allocator.free(stale_spore_dir);
    try ensureDirPath(io, stale_spore_dir);
    const stale_backing_path = try std.fs.path.resolve(allocator, &.{ stale_spore_dir, spore.ram_backing_path });
    defer allocator.free(stale_backing_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = stale_backing_path, .data = "backing-bytes" });
    try writeSpec(allocator, io, stale, .{
        .name = "b-stale",
        .resume_dir = stale_spore_dir,
        .memory = .{ .policy = .explicit, .bytes = 512 * 1024 * 1024 },
    });
    try writeReady(allocator, io, stale, .{
        .pid = 9001,
        .control_socket_path = stale.control_socket_path,
        .console_log_path = stale.console_log_path,
    });
    try writePid(allocator, io, stale, 9001);

    const ready = try pathsFromRoot(allocator, root, "a-ready");
    defer ready.deinit(allocator);
    const ready_pid = currentTestPid();
    try writeSpec(allocator, io, ready, .{ .name = "a-ready" });
    try writeReady(allocator, io, ready, .{
        .pid = ready_pid,
        .control_socket_path = ready.control_socket_path,
        .console_log_path = ready.console_log_path,
    });
    try writePid(allocator, io, ready, ready_pid);
    try writeMonitorStats(allocator, io, ready, .{
        .chunks_nonzero = 17,
        .dirty_chunks_pending = 2,
    });

    const entries = try listEntries(allocator, io, root, aliveOnlyCurrentProcess);
    defer freeListEntries(allocator, entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("a-ready", entries[0].name);
    try std.testing.expectEqualStrings("ready", entries[0].state);
    try std.testing.expectEqual(@as(?i64, ready_pid), entries[0].pid);
    try std.testing.expectEqualStrings("auto", entries[0].memory.?.policy);
    try std.testing.expectEqual(memory_config.auto_bytes, entries[0].memory.?.bytes);
    if (readProcessResidentBytes(allocator, io, ready_pid) != null) {
        try std.testing.expect(entries[0].stats.resident_bytes != null);
    } else if (!(comptime builtin.os.tag == .linux or builtin.os.tag.isDarwin())) {
        try std.testing.expectEqual(@as(?u64, null), entries[0].stats.resident_bytes);
    }
    const chunk_size: u64 = spore.chunk_size;
    try std.testing.expectEqual(@as(?u64, chunk_size), entries[0].stats.chunk_size);
    try std.testing.expectEqual(@as(?u64, memory_config.auto_bytes / chunk_size), entries[0].stats.chunks_total);
    try std.testing.expectEqual(@as(?u64, 17), entries[0].stats.chunks_nonzero);
    try std.testing.expectEqual(@as(?u64, 2), entries[0].stats.dirty_chunks_pending);
    try std.testing.expectEqualStrings("b-stale", entries[1].name);
    try std.testing.expectEqualStrings("stale", entries[1].state);
    try std.testing.expectEqual(@as(?i64, 9001), entries[1].pid);
    try std.testing.expectEqualStrings("explicit", entries[1].memory.?.policy);
    try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), entries[1].memory.?.bytes);
    try std.testing.expectEqual(@as(?u64, 13), entries[1].stats.backing_logical_bytes);
    try std.testing.expect(entries[1].stats.backing_allocated_bytes != null);
    try std.testing.expectEqual(@as(?u64, 256), entries[1].stats.chunks_total);
}

test "lifecycle list entries render human table" {
    const allocator = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const stale_memory = listMemoryFromConfig(.{ .policy = .explicit, .bytes = 512 * 1024 * 1024 });
    try writeListEntries(&out.writer, &.{
        .{
            .name = "a-ready",
            .state = "ready",
            .pid = 42,
            .memory = listMemoryFromConfig(.{}),
            .stats = .{
                .resident_bytes = 184 * 1024 * 1024,
                .backing_logical_bytes = memory_config.auto_bytes,
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
            "a-ready\tready\t42\tauto/16GiB\t184MiB\t34MiB/16GiB\t17/8192\t2\n" ++
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
    try std.testing.expectEqualStrings("created vm counter\n", out.written());

    out.clearRetainingCapacity();
    try writeNamedLifecycleResult(&out.writer, .{
        .action = "saved",
        .name = "counter",
        .state = "ready",
        .spore_dir = "counter.spore",
    });
    try std.testing.expectEqualStrings("saved counter.spore; vm counter is still running\n", out.written());

    out.clearRetainingCapacity();
    try writeNamedLifecycleResult(&out.writer, .{
        .action = "saved_stopped",
        .name = "counter",
        .state = "stopped",
        .spore_dir = "counter.spore",
    });
    try std.testing.expectEqualStrings(
        "saved counter.spore and stopped vm counter\n" ++
            "spore has no saved session; use `spore run --from <spore> ...` to run new commands, or `spore run --save <spore> --save-on TERM ...` if you want fanout to attach to the original command.\n",
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
        "saved counter.spore and stopped vm counter\n" ++
            "spore has a saved session; use `spore attach <spore>` to reconnect, or `spore run --from <spore> ...` to run new commands.\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    try writeNamedForkResult(&out.writer, .{
        .source = "counter",
        .count = 2,
        .children = &.{ "child-0", "child-1" },
    });
    try std.testing.expectEqualStrings("forked child-0 child-1\n", out.written());
}

test "lifecycle list JSON exposes memory and nullable stats" {
    const allocator = std.testing.allocator;
    const json = try std.json.Stringify.valueAlloc(allocator, ListEntry{
        .name = "a-ready",
        .state = "ready",
        .pid = 42,
        .memory = listMemoryFromConfig(.{}),
    }, .{});
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"memory\":{\"policy\":\"auto\",\"bytes\":17179869184}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stats\":{\"resident_bytes\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dirty_chunks_pending\":null") != null);
}

test "lifecycle reads monitor stats metadata" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fs.path.resolve(allocator, &.{"zig-cache/test-monitor-stats"});
    defer allocator.free(root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    const paths = try pathsFromRoot(allocator, root, "bench-1");
    defer paths.deinit(allocator);
    try ensureVmDir(io, paths);
    try writeMonitorStats(allocator, io, paths, .{
        .chunks_nonzero = 17,
        .dirty_chunks_pending = 2,
    });

    const stats = try readMonitorStats(allocator, io, paths);
    try std.testing.expectEqual(@as(?u64, 17), stats.chunks_nonzero);
    try std.testing.expectEqual(@as(?u64, 2), stats.dirty_chunks_pending);
}

test "linux statm resident parser reads resident pages" {
    try std.testing.expectEqual(@as(u64, 12 * 4096), try linuxStatmResidentBytes("99 12 3 4 5 6 7\n", 4096));
    try std.testing.expectError(error.InvalidProcessStat, linuxStatmResidentBytes("99\n", 4096));
}

fn alwaysDead(_: i64) bool {
    return false;
}

fn alwaysAlive(_: i64) bool {
    return true;
}

fn currentTestPid() i64 {
    return if (comptime builtin.os.tag == .windows) 1 else @intCast(std.c.getpid());
}

fn aliveOnlyCurrentProcess(pid: i64) bool {
    return pid == currentTestPid();
}
