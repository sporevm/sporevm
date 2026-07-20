//! Product attach support for `spore attach`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const attach_stream = @import("attach_stream.zig");
const backend_mod = @import("backend.zig");
const Context = @import("context.zig").Context;
const fd_util = @import("fd.zig");
const hvf = @import("hvf/hvf.zig");
const kvm_native = @import("kvm/native.zig");
const kvm = kvm_native.binding;
const net_gateway = @import("net_gateway.zig");
const ram_restore = @import("ram_restore.zig");
const generation = @import("generation.zig");
const run_mod = @import("run.zig");
const runtime_disk = @import("runtime_disk.zig");
const spore = @import("spore.zig");
const spore_net_policy = @import("spore_net_policy.zig");
const spore_stream = @import("spore_stream.zig");
const virtio_net = @import("virtio/net.zig");
const vsock = @import("virtio/vsock.zig");

pub const Backend = run_mod.Backend;
const default_attach_guest_port: u32 = 10700;
const default_attach_timeout_ms: u64 = 30_000;

pub const Options = struct {
    backend: Backend = .auto,
    spore_dir: []const u8,
    session_id: ?[]const u8 = null,
    generation_path: ?[]const u8 = null,
    event_mode: run_mod.EventMode = .none,
    events: ?run_mod.EventSink = null,
    spore_executable: []const u8 = "spore",
    debug: bool = false,
    timeout_ms: u64 = default_attach_timeout_ms,
    bound_services: run_mod.BoundServiceBindingList = .{},
    interactive: bool = false,
    tty: bool = false,
};

pub const cli_usage =
    \\Usage:
    \\  spore attach [options] <spore-dir>
    \\
    \\Options:
    \\  --backend auto|hvf|kvm  Backend to run (default: auto)
    \\  --session ID            Attach to a specific saved session
    \\  --generation FILE       Inject fan-out identity JSON before attach
    \\  --bind-service NAME=unix:/path.sock
    \\                          Bind a manifest-declared service to a host socket
    \\  --events=jsonl          Emit lifecycle and guest output events as JSONL on stdout
    \\  --timeout DURATION      Probe timeout (default: 30s; e.g. 500ms, 1m)
    \\  -i, --interactive       Forward stdin when the saved session supports it
    \\  -t, --tty               Attach as a terminal when the saved session has one
    \\  -h, --help              Show this help
    \\
    \\Requires a spore with saved sessions. Verify with:
    \\  spore inspect <spore-dir>
    \\  # Sessions: 1
    \\
;

pub fn parseCliArgs(args: []const []const u8) !Options {
    var backend: Backend = .auto;
    var spore_dir: ?[]const u8 = null;
    var session_id: ?[]const u8 = null;
    var generation_path: ?[]const u8 = null;
    var event_mode: run_mod.EventMode = .none;
    var timeout_ms: u64 = default_attach_timeout_ms;
    var bound_services = run_mod.BoundServiceBindingList{};
    var interactive = false;
    var tty = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--backend") and i + 1 < args.len) {
            i += 1;
            backend = Backend.parse(args[i]) orelse {
                std.debug.print("--backend must be auto, hvf, or kvm\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--session") and i + 1 < args.len) {
            i += 1;
            session_id = args[i];
        } else if (std.mem.startsWith(u8, args[i], "--session=")) {
            session_id = args[i]["--session=".len..];
        } else if (std.mem.eql(u8, args[i], "--generation") and i + 1 < args.len) {
            i += 1;
            generation_path = args[i];
        } else if (std.mem.startsWith(u8, args[i], "--generation=")) {
            generation_path = args[i]["--generation=".len..];
        } else if (std.mem.eql(u8, args[i], "--bind-service") and i + 1 < args.len) {
            i += 1;
            bound_services.append(spore_net_policy.parseBoundServiceBinding(args[i]) catch |err| {
                std.debug.print("spore attach: invalid --bind-service {s}: {s}\n", .{ args[i], @errorName(err) });
                std.process.exit(2);
            }) catch |err| {
                std.debug.print("spore attach: invalid --bind-service {s}: {s}\n", .{ args[i], @errorName(err) });
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--events") and i + 1 < args.len) {
            i += 1;
            event_mode = run_mod.EventMode.parse(args[i]) orelse {
                std.debug.print("--events must be jsonl\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, args[i], "--events=")) {
            const raw = args[i]["--events=".len..];
            event_mode = run_mod.EventMode.parse(raw) orelse {
                std.debug.print("--events must be jsonl\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--timeout") and i + 1 < args.len) {
            i += 1;
            timeout_ms = run_mod.parseDurationMs(args[i]) catch {
                std.debug.print("--timeout expects a duration like 30s, 500ms, or 1m\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--timeout-ms") and i + 1 < args.len) {
            i += 1;
            timeout_ms = parsePositive(u64, "--timeout-ms", args[i]);
        } else if (std.mem.eql(u8, args[i], "-i") or std.mem.eql(u8, args[i], "--interactive")) {
            interactive = true;
        } else if (std.mem.eql(u8, args[i], "-t") or std.mem.eql(u8, args[i], "--tty")) {
            tty = true;
        } else if (std.mem.eql(u8, args[i], "-it") or std.mem.eql(u8, args[i], "-ti")) {
            interactive = true;
            tty = true;
        } else if (std.mem.eql(u8, args[i], "--count")) {
            std.debug.print("spore attach attaches exactly one spore; use spore fork --count N --out DIR, then attach each child\n", .{});
            std.process.exit(2);
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            std.debug.print("unknown attach argument: {s}\n\n{s}", .{ args[i], cli_usage });
            std.process.exit(2);
        } else if (spore_dir == null) {
            spore_dir = args[i];
        } else {
            std.debug.print("unexpected attach argument: {s}\n\n{s}", .{ args[i], cli_usage });
            std.process.exit(2);
        }
    }

    return .{
        .backend = backend,
        .session_id = session_id,
        .generation_path = generation_path,
        .event_mode = event_mode,
        .spore_dir = spore_dir orelse {
            std.debug.print("{s}", .{cli_usage});
            std.process.exit(2);
        },
        .timeout_ms = timeout_ms,
        .bound_services = bound_services,
        .interactive = interactive,
        .tty = tty,
    };
}

pub fn execute(context: Context, allocator: std.mem.Allocator, opts: Options) !run_mod.Result {
    var events = run_mod.EventEmitter.init(opts.events, "attach");
    try events.emitStart(opts.backend);
    errdefer |err| events.emitFailure(err) catch {};

    const backend = try backend_mod.requireProductRunner(opts.backend);
    events.setBackend(backend);
    try run_mod.validateFreshProductPolicy(backend, .{
        .memory = .{},
        .vcpus = 1,
        .resuming = true,
    });

    var parsed: ?std.json.Parsed(spore.Manifest) = spore.loadManifest(allocator, opts.spore_dir) catch |err| blk: {
        if (err != error.BadManifest) return @errorCast(err);
        break :blk null;
    };
    defer if (parsed) |*manifest| manifest.deinit();
    var parsed_v1: ?std.json.Parsed(spore.ManifestV1) = null;
    defer if (parsed_v1) |*manifest| manifest.deinit();
    if (parsed == null) parsed_v1 = try spore.loadManifestV1(allocator, opts.spore_dir);

    const sessions = if (parsed) |manifest| manifest.value.sessions else parsed_v1.?.value.sessions;
    const session_id = opts.session_id orelse spore.defaultAttachSessionId(sessions);
    try spore.validateSessionAttach(sessions, .{
        .id = session_id,
        .stdin = opts.interactive and !opts.tty,
        .terminal = opts.tty,
    });

    var binding_diagnostic = run_mod.BoundServiceBindingDiagnostic{};
    const network_options = run_mod.networkOptionsFromManifestWithBindingDiagnostic(allocator, if (parsed) |manifest| manifest.value.network else parsed_v1.?.value.network, opts.bound_services.slice(), &binding_diagnostic) catch |err| switch (err) {
        error.MissingBoundServiceBinding => failAttachSetup("spore attach: manifest requires live bound Unix service binding '{s}'", .{binding_diagnostic.missing_name orelse "unknown"}),
        error.UnexpectedBoundServiceBinding => failAttachSetup("spore attach: live bound Unix service binding '{s}' does not match the manifest", .{binding_diagnostic.unexpected_name orelse "unknown"}),
        error.DuplicateBoundServiceBinding => failAttachSetup("spore attach: duplicate live bound Unix service binding '{s}'", .{binding_diagnostic.duplicate_name orelse "unknown"}),
        else => failAttachSetup("spore attach: invalid network policy in manifest", .{}),
    };
    var gateway: net_gateway.Process = undefined;
    var gateway_active = false;
    if (network_options.network == .spore) {
        try gateway.start(context.io, allocator, opts.spore_executable, opts.debug, network_options.policy);
        gateway_active = true;
    }
    defer if (gateway_active) gateway.deinit();
    const network: virtio_net.Runtime = if (gateway_active) gateway.runtime() else .{};
    errdefer run_mod.finishGatewayNetworkEvents(&gateway, &gateway_active, &events);

    const devices = if (parsed) |manifest| manifest.value.devices else parsed_v1.?.value.devices;
    const rootfs = if (parsed) |manifest| manifest.value.rootfs else parsed_v1.?.value.rootfs;
    const disk = if (parsed) |manifest| manifest.value.disk else parsed_v1.?.value.disk;
    validateAttachDiskManifestParts(devices, rootfs, disk);
    var runtime_disk_state = try runtime_disk.open(context, allocator, .{
        .rootfs = rootfs,
        .disk = disk,
        .spore_dir = opts.spore_dir,
    });
    defer runtime_disk_state.deinit();
    const generation_params = if (opts.generation_path) |path|
        loadGenerationParams(context.io, allocator, path) catch |err| switch (err) {
            error.BadGenerationPayload => failAttachSetup("spore attach: invalid --generation payload; required JSON fields: run_id, child_id, parallel_index, parallel_count, fork_index, fork_count, fork_batch_id, vm_id", .{}),
            error.StreamTooLong => failAttachSetup("spore attach: --generation payload exceeds {d} bytes", .{generation.params_size}),
            else => |e| failAttachSetup("spore attach: cannot read --generation {s}: {s}", .{ path, @errorName(e) }),
        }
    else
        null;
    const manifest_generation = if (parsed) |manifest| manifest.value.generation else parsed_v1.?.value.generation;
    const attach = try prepareAttach(allocator, manifest_generation, generation_params, .{
        .session_id = session_id,
        .interactive = opts.interactive,
        .tty = opts.tty,
        .terminal_name = attach_stream.terminalName(context.environ_map),
        .terminal_size = attach_stream.terminalSizeOrDefault(attach_stream.terminalSizeFd()),
    });
    defer attach.deinit(allocator);
    var identity_stream: ?vsock.HostStream = try vsock.HostStream.initWithProtocol(default_attach_guest_port, attach.request, if (opts.interactive or opts.tty) .spore_stream_v1 else .legacy_text);
    if (identity_stream) |*stream| {
        stream.host_port = vsock.HostStream.deriveHostPort(attach.request);
        if (opts.events != null) {
            stream.setLifecycleSink(&events, attachEventLifecycleSink);
            stream.setOutputSink(&events, attachEventOutputSink);
        } else {
            stream.setOutputSink(null, identityProbeOutputSink);
        }
    }
    const identity_probe: ?*vsock.HostStream = if (identity_stream) |*stream| stream else null;
    var stdin_control = if (identity_stream) |*stream|
        if (opts.interactive or opts.tty) attach_stream.RunStdinControl.init(stream, opts.tty, opts.interactive, attach_stream.terminalSizeFd()) else null
    else
        null;
    if (stdin_control) |*control| try control.start(opts.tty and opts.interactive);
    defer if (stdin_control) |*control| control.deinit();
    const exec_control = if (stdin_control) |*control| control.control() else null;

    if (gateway_active) try events.emitPortForwards(&network_options.policy);
    const ram_size = if (parsed) |manifest| manifest.value.platform.ram_size else parsed_v1.?.value.platform.ram_size;
    const vcpu_count = if (parsed) |_| @as(u32, 1) else parsed_v1.?.value.platform.vcpu_count;
    const memory = if (parsed) |manifest| manifest.value.memory else parsed_v1.?.value.memory;
    var ram_plan = try ram_restore.Plan.fromMemory(allocator, context.environ_map, opts.spore_dir, memory, ram_size, vcpu_count);
    defer ram_plan.deinit();
    std.log.info("attach memory restore source={s} reason={s}", .{ @tagName(ram_plan.restoreSource().?), @tagName(ram_plan.reason) });
    const cause = switch (backend) {
        .auto => unreachable,
        .hvf => blk: {
            if (comptime !(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) return error.UnsupportedBackend;
            break :blk try hvf.vm.run(allocator, .{
                .kernel = "",
                .ram_size = ram_size,
                .console_sink = if (opts.events == null) consoleSink else discardConsoleSink,
                .disk_backend = runtime_disk_state.backend(),
                .resume_dir = opts.spore_dir,
                .resume_generation = attach.generation_state,
                .vcpus = vcpu_count,
                .ram_restore = ram_plan.strategy,
                .network = network,
                .exec_probe = identity_probe,
                .exec_control = exec_control,
                .exec_probe_timeout_ms = opts.timeout_ms,
                .exec_probe_completes_run = true,
                .exec_probe_failure_fatal = true,
            });
        },
        .kvm => blk: {
            if (comptime !(builtin.os.tag == .linux and builtin.cpu.arch == .aarch64)) return error.UnsupportedBackend;
            break :blk try kvm.vm.run(allocator, .{
                .kernel = "",
                .ram_size = ram_size,
                .console_sink = if (opts.events == null) consoleSink else discardConsoleSink,
                .disk_backend = runtime_disk_state.backend(),
                .resume_dir = opts.spore_dir,
                .resume_generation = attach.generation_state,
                .vcpus = vcpu_count,
                .ram_restore = ram_plan.strategy,
                .network = network,
                .exec_probe = identity_probe,
                .exec_control = exec_control,
                .exec_probe_timeout_ms = opts.timeout_ms,
                .exec_probe_completes_run = true,
                .exec_probe_failure_fatal = true,
            });
        },
    };

    switch (cause) {
        .guest_off, .guest_reset => {},
        .probe_complete => {
            var result = try resultFromAttachStream(backend, ram_size, vcpu_count, identity_stream);
            result = result.withMemoryRestore(&ram_plan);
            run_mod.finishGatewayNetworkEvents(&gateway, &gateway_active, &events);
            try events.emitExit(result);
            if (events.write_failed) return error.EventSinkFailed;
            return result;
        },
        .snapshotted, .monitor_stopped => return error.UnexpectedAttachExit,
    }
    const gateway_failed = gateway_active and gateway.hasFailed();
    run_mod.finishGatewayNetworkEvents(&gateway, &gateway_active, &events);
    if (gateway_failed) return error.NetworkGatewayFailed;
    const connect_ms = if (identity_stream) |stream| stream.connect_ms orelse 0 else 0;
    const response_ms = if (identity_stream) |stream| stream.response_ms orelse 0 else 0;
    var result = run_mod.Result{
        .backend = backend,
        .start_ms = 0,
        .vsock_connect_ms = connect_ms,
        .exec_response_ms = response_ms,
        .probe_duration_ms = if (response_ms >= connect_ms) response_ms - connect_ms else 0,
        .exit_code = 0,
        .vcpus = vcpu_count,
        .memory_bytes = ram_size,
    };
    result = result.withMemoryRestore(&ram_plan);
    try events.emitExit(result);
    if (events.write_failed) return error.EventSinkFailed;
    return result;
}

fn consoleSink(bytes: []const u8) void {
    fd_util.writeAllBestEffort(1, bytes);
}

fn discardConsoleSink(_: []const u8) void {}

fn attachEventOutputSink(context: ?*anyopaque, output: vsock.HostStreamOutput, bytes: []const u8) void {
    const events: *run_mod.EventEmitter = @ptrCast(@alignCast(context.?));
    events.emitOutputBestEffort(output, bytes);
}

fn attachEventLifecycleSink(context: ?*anyopaque, event: vsock.HostStreamLifecycle) void {
    const events: *run_mod.EventEmitter = @ptrCast(@alignCast(context.?));
    switch (event) {
        .ready => events.emitReadyBestEffort(),
    }
}

fn identityProbeOutputSink(_: ?*anyopaque, output: vsock.HostStreamOutput, bytes: []const u8) void {
    if (output != .stderr) return;
    fd_util.writeAllBestEffort(2, bytes);
}

fn parsePositive(comptime T: type, name: []const u8, raw: []const u8) T {
    const parsed = std.fmt.parseInt(T, raw, 10) catch {
        std.debug.print("{s} must be a positive integer\n", .{name});
        std.process.exit(2);
    };
    if (parsed == 0) {
        std.debug.print("{s} must be a positive integer\n", .{name});
        std.process.exit(2);
    }
    return parsed;
}

fn resultFromAttachStream(backend: Backend, ram_size: u64, vcpu_count: u32, identity_stream: ?vsock.HostStream) !run_mod.Result {
    const stream = identity_stream orelse return error.UnexpectedAttachExit;
    const connect_ms = stream.connect_ms orelse stream.elapsedMs();
    const response_ms = stream.response_ms orelse stream.elapsedMs();
    return .{
        .backend = backend,
        .start_ms = stream.start_ms orelse 0,
        .vsock_connect_ms = connect_ms,
        .exec_response_ms = response_ms,
        .probe_duration_ms = if (response_ms >= connect_ms) response_ms - connect_ms else 0,
        .exit_code = stream.exit_code orelse return error.BadRunExitFrame,
        .vcpus = vcpu_count,
        .memory_bytes = ram_size,
    };
}

const PreparedAttach = struct {
    request: []const u8,
    generation_state: generation.State,

    fn deinit(self: PreparedAttach, allocator: std.mem.Allocator) void {
        allocator.free(self.request);
        allocator.free(self.generation_state.params_b64);
    }
};

const AttachRequestOptions = struct {
    session_id: []const u8,
    interactive: bool = false,
    tty: bool = false,
    terminal_name: []const u8 = "xterm",
    terminal_size: spore_stream.Resize = .{ .rows = 24, .cols = 80 },
};

pub fn loadGenerationParams(io: Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const params = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(generation.params_size));
    try generation.validateFanoutParams(allocator, params);
    return params;
}

pub fn prepareRestoreGenerationState(allocator: std.mem.Allocator, manifest_generation: spore.GenerationState, generation_params: []const u8) !generation.State {
    var gen_dev = generation.Device{};
    try gen_dev.restore(allocator, manifest_generation);
    _ = try gen_dev.setResume(manifest_generation.generation, generation_params);
    return gen_dev.capture(allocator);
}

fn prepareAttach(allocator: std.mem.Allocator, manifest_generation: spore.GenerationState, generation_params: ?[]const u8, options: AttachRequestOptions) !PreparedAttach {
    var gen_dev = generation.Device{};
    try gen_dev.restore(allocator, manifest_generation);
    if (generation_params) |params| {
        _ = try gen_dev.setResume(manifest_generation.generation, params);
    } else {
        try spore.refreshResumeParams(allocator, &gen_dev);
    }
    const generation_state = try gen_dev.capture(allocator);
    errdefer allocator.free(generation_state.params_b64);

    const params_payload = gen_dev.paramsPayload();
    if (options.interactive or options.tty) {
        return .{
            .request = try attach_stream.attachV1Request(allocator, .{
                .session_id = options.session_id,
                .interactive = options.interactive,
                .tty = options.tty,
                .terminal_name = options.terminal_name,
                .terminal_size = options.terminal_size,
                .generation_params = if (params_payload.len == 0) null else params_payload,
            }),
            .generation_state = generation_state,
        };
    }
    return .{
        .request = try attach_stream.attachRequestWithGeneration(allocator, options.session_id, if (params_payload.len == 0) null else params_payload),
        .generation_state = generation_state,
    };
}

fn validateAttachDiskManifestParts(devices: []const spore.TransportState, rootfs_opt: ?spore.Rootfs, disk_opt: ?spore.Disk) void {
    const disk_count = spore.countBlockDevices(devices);
    if (disk_count == 0) return;
    if (disk_count != 1) {
        failAttachSetup("spore attach: only one immutable rootfs disk is supported; found {d} block devices", .{disk_count});
    }
    const rootfs = rootfs_opt orelse {
        failAttachSetup("spore attach: disk-backed spore has no immutable rootfs artifact; save with spore run --image or use the backend harness with the original disk", .{});
    };
    spore.validateRootfs(rootfs, devices) catch {
        failAttachSetup("spore attach: invalid immutable rootfs metadata in manifest", .{});
    };
    if (disk_opt) |writable_disk| {
        spore.validateDisk(writable_disk, rootfs, devices) catch {
            failAttachSetup("spore attach: invalid writable disk metadata in manifest", .{});
        };
    }
}

fn failAttachSetup(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(2);
}

test "attach cli parser accepts one spore dir" {
    const opts = try parseCliArgs(&.{ "--backend", "hvf", "--timeout", "120s", "child.spore" });
    try std.testing.expectEqual(Backend.hvf, opts.backend);
    try std.testing.expectEqual(@as(u64, 120_000), opts.timeout_ms);
    try std.testing.expectEqualStrings("child.spore", opts.spore_dir);
}

test "attach cli parser accepts hidden timeout-ms compatibility spelling" {
    const opts = try parseCliArgs(&.{ "--timeout-ms", "120000", "child.spore" });
    try std.testing.expectEqual(@as(u64, 120_000), opts.timeout_ms);
    try std.testing.expectEqualStrings("child.spore", opts.spore_dir);
}

test "attach cli parser accepts jsonl events" {
    const opts = try parseCliArgs(&.{ "--events=jsonl", "child.spore" });
    try std.testing.expectEqual(run_mod.EventMode.jsonl, opts.event_mode);
    try std.testing.expectEqualStrings("child.spore", opts.spore_dir);
}

test "attach cli parser accepts generation file" {
    const opts = try parseCliArgs(&.{ "--generation", "generation.json", "--events=jsonl", "child.spore" });
    try std.testing.expectEqualStrings("generation.json", opts.generation_path.?);
    try std.testing.expectEqual(run_mod.EventMode.jsonl, opts.event_mode);
    try std.testing.expectEqualStrings("child.spore", opts.spore_dir);
}

test "attach cli parser accepts session and stream options" {
    const opts = try parseCliArgs(&.{ "--session", "run-1234", "-it", "child.spore" });
    try std.testing.expectEqualStrings("child.spore", opts.spore_dir);
    try std.testing.expectEqualStrings("run-1234", opts.session_id.?);
    try std.testing.expect(opts.interactive);
    try std.testing.expect(opts.tty);
}

test "attach cli parser accepts bound service bindings" {
    const opts = try parseCliArgs(&.{ "--bind-service", "metadata=unix:/tmp/metadata.sock", "child.spore" });
    try std.testing.expectEqualStrings("child.spore", opts.spore_dir);
    try std.testing.expectEqual(@as(usize, 1), opts.bound_services.len);
    try std.testing.expectEqualStrings("metadata", opts.bound_services.items[0].name);
    try std.testing.expectEqualStrings("/tmp/metadata.sock", opts.bound_services.items[0].target.unix);
}

test "x86 attach rejects resume before reading the spore" {
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectError(error.X86ResumeUnsupported, execute(.{
        .io = std.testing.io,
        .environ_map = &env,
    }, std.testing.allocator, .{
        .backend = .kvm,
        .spore_dir = "zig-cache/test-x86-attach-gate/definitely-missing.spore",
    }));
}

test "attach validates saved sessions before bound service bindings" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});

    var manifest = testDiskGuardManifest(&.{}, false);
    manifest.rootfs = null;
    manifest.network = .{
        .bound_services = &.{.{
            .name = "metadata",
            .guest_host = "metadata.spore.internal",
            .guest_port = 8170,
        }},
        .requirements = .{ .bound_services = true },
    };
    try spore.saveManifest(arena, dir, manifest);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const expected_error = if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .x86_64)
        error.X86ResumeUnsupported
    else
        error.NoSavedSession;
    try std.testing.expectError(expected_error, execute(.{
        .io = std.testing.io,
        .environ_map = &env,
    }, arena, .{
        .spore_dir = dir,
    }));
}

test "attach request omits empty generation params" {
    const allocator = std.testing.allocator;
    const manifest = testDiskGuardManifest(&.{}, false);
    const attach = try prepareAttach(allocator, manifest.generation, null, .{ .session_id = spore.default_session_id });
    defer attach.deinit(allocator);
    try std.testing.expectEqualStrings("{\"type\":\"attach\",\"session_id\":\"default\",\"stdout_offset\":0,\"stderr_offset\":0}\n", attach.request);
    try std.testing.expectEqualStrings("", attach.generation_state.params_b64);
}

test "attach request carries refreshed generation params" {
    const allocator = std.testing.allocator;
    var manifest = testDiskGuardManifest(&.{}, false);
    var gen_dev = generation.Device{};
    const stable_params =
        \\{"schema_version":0,"parent_generation":1,"generation":2,"fork_index":0,"fork_count":2,"parallel_index":0,"parallel_count":2,"fork_batch_id":"0123456789abcdef0123456789abcdef","vm_id":"spore-0123456789abcdef0123456789abcdef","hostname":"spore-01234567-000000","mac_seed":"0123456789abcdef0123456789abcdef","mac_address":"02:00:00:00:00:01"}
    ;
    try std.testing.expect(try gen_dev.setResume(2, stable_params));
    manifest.generation = try gen_dev.capture(allocator);
    defer allocator.free(manifest.generation.params_b64);

    const attach = try prepareAttach(allocator, manifest.generation, null, .{ .session_id = spore.default_session_id });
    defer attach.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, attach.request, "\"type\":\"attach\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, attach.request, "\"params_json\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, attach.request, "\\\"parallel_index\\\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, attach.request, "\\\"parallel_count\\\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, attach.request, "\\\"resume_time_unix_ns\\\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, attach.request, "\\\"resume_entropy_seed\\\":") != null);

    var restored = generation.Device{};
    try restored.restore(allocator, attach.generation_state);
    const params_payload = restored.paramsPayload();
    try std.testing.expect(std.mem.indexOf(u8, params_payload, "\"resume_time_unix_ns\":") != null);

    const AttachPayload = struct {
        params_json: []const u8,
    };
    const parsed = try std.json.parseFromSlice(AttachPayload, allocator, attach.request, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(params_payload, parsed.value.params_json);
}

test "attach request accepts explicit generation params" {
    const allocator = std.testing.allocator;
    const params =
        \\{"run_id":"rails-rspec-1","child_id":7,"parallel_index":7,"parallel_count":1000,"fork_index":7,"fork_count":1000,"fork_batch_id":"batch-1","vm_id":"spore-child-7"}
    ;
    try generation.validateFanoutParams(allocator, params);

    const manifest = testDiskGuardManifest(&.{}, false);
    const attach = try prepareAttach(allocator, manifest.generation, params, .{ .session_id = spore.default_session_id });
    defer attach.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, attach.request, "\\\"run_id\\\":\\\"rails-rspec-1\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, attach.request, "\\\"parallel_index\\\":7") != null);

    var restored = generation.Device{};
    try restored.restore(allocator, attach.generation_state);
    try std.testing.expectEqualStrings(params, restored.paramsPayload());
}

fn testDiskGuardManifest(devices: []spore.TransportState, with_disk: bool) spore.Manifest {
    return .{
        .platform = .{
            .cpu_profile = "test",
            .device_model_version = 1,
            .ram_base = 0x8000_0000,
            .ram_size = 4096,
            .gic_dist_base = 0x0800_0000,
            .gic_redist_base = 0x0801_0000,
            .counter_frequency_hz = 24_000_000,
        },
        .machine = .{
            .gprs = [_]u64{0} ** 31,
            .pc = 0,
            .cpsr = 0,
            .fpcr = 0,
            .fpsr = 0,
            .simd = [_][2]u64{.{ 0, 0 }} ** 32,
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
        },
        .devices = devices,
        .generation = .{ .generation = 0, .interrupt_status = 0, .params_b64 = "" },
        .rootfs = .{
            .device = .{ .mmio_slot = 0 },
            .artifact = .{
                .digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                .size = 4096,
            },
        },
        .disk = if (with_disk) .{
            .device = .{ .mmio_slot = 0 },
            .size = 4096,
            .base = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        } else null,
        .memory = .{ .logical_size = 4096, .chunk_size = spore.chunk_size, .zero_chunks = &.{0} },
    };
}

test "attach accepts writable disk manifests for layered runtime setup" {
    var devices = [_]spore.TransportState{.{
        .device_id = spore.rootfs_virtio_blk_device_id,
        .status = 0,
        .device_features_sel = 0,
        .driver_features_sel = 0,
        .driver_features = 0,
        .queue_sel = 0,
        .interrupt_status = 0,
        .queues = &.{},
    }};
    const without_disk = testDiskGuardManifest(&devices, false);
    validateAttachDiskManifestParts(without_disk.devices, without_disk.rootfs, without_disk.disk);
    const with_disk = testDiskGuardManifest(&devices, true);
    validateAttachDiskManifestParts(with_disk.devices, with_disk.rootfs, with_disk.disk);
}
