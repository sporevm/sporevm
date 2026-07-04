//! Product resume support for `spore resume`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const Context = @import("context.zig").Context;
const fd_util = @import("fd.zig");
const hvf = @import("hvf/hvf.zig");
const kvm = if (builtin.os.tag == .linux and builtin.cpu.arch == .aarch64)
    @import("kvm/kvm.zig")
else
    struct {};
const net_gateway = @import("net_gateway.zig");
const generation = @import("generation.zig");
const run_mod = @import("run.zig");
const runtime_disk = @import("runtime_disk.zig");
const spore = @import("spore.zig");
const spore_net_policy = @import("spore_net_policy.zig");
const virtio_net = @import("virtio/net.zig");
const vsock = @import("virtio/vsock.zig");

pub const Backend = run_mod.Backend;
const default_resume_guest_port: u32 = 10700;
const default_resume_attach_timeout_ms: u64 = 30_000;

pub const Options = struct {
    backend: Backend = .auto,
    spore_dir: []const u8,
    generation_path: ?[]const u8 = null,
    event_mode: run_mod.EventMode = .none,
    events: ?run_mod.EventSink = null,
    spore_executable: []const u8 = "spore",
    debug: bool = false,
    timeout_ms: u64 = default_resume_attach_timeout_ms,
    bound_services: run_mod.BoundServiceBindingList = .{},
};

pub const cli_usage =
    \\Usage:
    \\  spore resume [--backend auto|hvf|kvm] <spore-dir>
    \\
    \\Options:
    \\  --backend auto|hvf|kvm  Backend to run (default: auto)
    \\  --generation FILE       Inject fan-out identity JSON before resume
    \\  --bind-service NAME=unix:/path.sock
    \\                          Bind a manifest-declared service to a host socket
    \\  --events=jsonl          Emit lifecycle and guest output events as JSONL on stdout
    \\  --timeout-ms N          Probe timeout in milliseconds (default: 30000)
    \\  -h, --help              Show this help
    \\
;

pub fn parseCliArgs(args: []const []const u8) !Options {
    var backend: Backend = .auto;
    var spore_dir: ?[]const u8 = null;
    var generation_path: ?[]const u8 = null;
    var event_mode: run_mod.EventMode = .none;
    var timeout_ms: u64 = default_resume_attach_timeout_ms;
    var bound_services = run_mod.BoundServiceBindingList{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--backend") and i + 1 < args.len) {
            i += 1;
            backend = Backend.parse(args[i]) orelse {
                std.debug.print("--backend must be auto, hvf, or kvm\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--generation") and i + 1 < args.len) {
            i += 1;
            generation_path = args[i];
        } else if (std.mem.startsWith(u8, args[i], "--generation=")) {
            generation_path = args[i]["--generation=".len..];
        } else if (std.mem.eql(u8, args[i], "--bind-service") and i + 1 < args.len) {
            i += 1;
            bound_services.append(spore_net_policy.parseBoundServiceBinding(args[i]) catch |err| {
                std.debug.print("spore resume: invalid --bind-service {s}: {s}\n", .{ args[i], @errorName(err) });
                std.process.exit(2);
            }) catch |err| {
                std.debug.print("spore resume: invalid --bind-service {s}: {s}\n", .{ args[i], @errorName(err) });
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
        } else if (std.mem.eql(u8, args[i], "--timeout-ms") and i + 1 < args.len) {
            i += 1;
            timeout_ms = parsePositive(u64, "--timeout-ms", args[i]);
        } else if (std.mem.eql(u8, args[i], "--count")) {
            std.debug.print("spore resume resumes exactly one spore; use spore fork --count N --out DIR, then resume each child\n", .{});
            std.process.exit(2);
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            std.debug.print("unknown resume argument: {s}\n\n{s}", .{ args[i], cli_usage });
            std.process.exit(2);
        } else if (spore_dir == null) {
            spore_dir = args[i];
        } else {
            std.debug.print("unexpected resume argument: {s}\n\n{s}", .{ args[i], cli_usage });
            std.process.exit(2);
        }
    }

    return .{
        .backend = backend,
        .generation_path = generation_path,
        .event_mode = event_mode,
        .spore_dir = spore_dir orelse {
            std.debug.print("{s}", .{cli_usage});
            std.process.exit(2);
        },
        .timeout_ms = timeout_ms,
        .bound_services = bound_services,
    };
}

pub fn execute(context: Context, allocator: std.mem.Allocator, opts: Options) !run_mod.Result {
    var events = run_mod.EventEmitter.init(opts.events, "resume");
    try events.emitStart(opts.backend);
    errdefer |err| events.emitFailure(err) catch {};

    var parsed: ?std.json.Parsed(spore.Manifest) = spore.loadManifest(allocator, opts.spore_dir) catch |err| blk: {
        if (err != error.BadManifest) return @errorCast(err);
        break :blk null;
    };
    defer if (parsed) |*manifest| manifest.deinit();
    var parsed_v1: ?std.json.Parsed(spore.ManifestV1) = null;
    defer if (parsed_v1) |*manifest| manifest.deinit();
    if (parsed == null) parsed_v1 = try spore.loadManifestV1(allocator, opts.spore_dir);

    var binding_diagnostic = run_mod.BoundServiceBindingDiagnostic{};
    const network_options = run_mod.networkOptionsFromManifestWithBindingDiagnostic(allocator, if (parsed) |manifest| manifest.value.network else parsed_v1.?.value.network, opts.bound_services.slice(), &binding_diagnostic) catch |err| switch (err) {
        error.MissingBoundServiceBinding => failResumeSetup("spore resume: manifest requires live bound Unix service binding '{s}'", .{binding_diagnostic.missing_name orelse "unknown"}),
        error.UnexpectedBoundServiceBinding => failResumeSetup("spore resume: live bound Unix service binding '{s}' does not match the manifest", .{binding_diagnostic.unexpected_name orelse "unknown"}),
        error.DuplicateBoundServiceBinding => failResumeSetup("spore resume: duplicate live bound Unix service binding '{s}'", .{binding_diagnostic.duplicate_name orelse "unknown"}),
        else => failResumeSetup("spore resume: invalid network policy in manifest", .{}),
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
    validateResumeDiskManifestParts(devices, rootfs, disk);
    var runtime_disk_state = try runtime_disk.open(context, allocator, .{
        .rootfs = rootfs,
        .disk = disk,
        .spore_dir = opts.spore_dir,
    });
    defer runtime_disk_state.deinit();
    const generation_params = if (opts.generation_path) |path|
        loadGenerationParams(context.io, allocator, path) catch |err| switch (err) {
            error.BadGenerationPayload => failResumeSetup("spore resume: invalid --generation payload; required JSON fields: run_id, child_id, parallel_index, parallel_count, fork_index, fork_count, fork_batch_id, vm_id", .{}),
            error.StreamTooLong => failResumeSetup("spore resume: --generation payload exceeds {d} bytes", .{generation.params_size}),
            else => |e| failResumeSetup("spore resume: cannot read --generation {s}: {s}", .{ path, @errorName(e) }),
        }
    else
        null;
    const manifest_generation = if (parsed) |manifest| manifest.value.generation else parsed_v1.?.value.generation;
    const attach = try prepareResumeAttach(allocator, manifest_generation, generation_params);
    defer attach.deinit(allocator);
    var identity_stream: ?vsock.HostStream = try vsock.HostStream.init(default_resume_guest_port, attach.request);
    if (identity_stream) |*stream| {
        stream.host_port = vsock.HostStream.deriveHostPort(attach.request);
        if (opts.events != null) {
            stream.setLifecycleSink(&events, resumeEventLifecycleSink);
            stream.setOutputSink(&events, resumeEventOutputSink);
        } else {
            stream.setOutputSink(null, identityProbeOutputSink);
        }
    }
    const identity_probe: ?*vsock.HostStream = if (identity_stream) |*stream| stream else null;

    const backend = try opts.backend.resolveForHost();
    events.setBackend(backend);
    if (gateway_active) try events.emitPortForwards(&network_options.policy);
    const ram_size = if (parsed) |manifest| manifest.value.platform.ram_size else parsed_v1.?.value.platform.ram_size;
    const vcpu_count = if (parsed) |_| @as(u32, 1) else parsed_v1.?.value.platform.vcpu_count;
    const memory = if (parsed) |manifest| manifest.value.memory else parsed_v1.?.value.memory;
    const local_backing = try spore.openProvenLocalMemoryBackingForVcpuCount(allocator, context.environ_map, opts.spore_dir, memory, ram_size, vcpu_count);
    defer if (local_backing.fd) |fd| {
        _ = std.c.close(fd);
    };
    std.log.info("resume memory restore source={s} reason={s}", .{ @tagName(local_backing.source), @tagName(local_backing.reason) });
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
                .ram_backing_fd = local_backing.fd,
                .network = network,
                .exec_probe = identity_probe,
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
                .ram_backing_fd = local_backing.fd,
                .network = network,
                .exec_probe = identity_probe,
                .exec_probe_timeout_ms = opts.timeout_ms,
                .exec_probe_completes_run = true,
                .exec_probe_failure_fatal = true,
            });
        },
    };

    switch (cause) {
        .guest_off, .guest_reset => {},
        .probe_complete => {
            var result = try resultFromResumeStream(backend, ram_size, vcpu_count, identity_stream);
            result = result.withMemoryRestore(local_backing);
            run_mod.finishGatewayNetworkEvents(&gateway, &gateway_active, &events);
            try events.emitExit(result);
            if (events.write_failed) return error.EventSinkFailed;
            return result;
        },
        .snapshotted, .monitor_stopped => return error.UnexpectedResumeExit,
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
    result = result.withMemoryRestore(local_backing);
    try events.emitExit(result);
    if (events.write_failed) return error.EventSinkFailed;
    return result;
}

fn consoleSink(bytes: []const u8) void {
    fd_util.writeAllBestEffort(1, bytes);
}

fn discardConsoleSink(_: []const u8) void {}

fn resumeEventOutputSink(context: ?*anyopaque, output: vsock.HostStreamOutput, bytes: []const u8) void {
    const events: *run_mod.EventEmitter = @ptrCast(@alignCast(context.?));
    events.emitOutputBestEffort(output, bytes);
}

fn resumeEventLifecycleSink(context: ?*anyopaque, event: vsock.HostStreamLifecycle) void {
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

fn resultFromResumeStream(backend: Backend, ram_size: u64, vcpu_count: u32, identity_stream: ?vsock.HostStream) !run_mod.Result {
    const stream = identity_stream orelse return error.UnexpectedResumeExit;
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

const PreparedResumeAttach = struct {
    request: []const u8,
    generation_state: generation.State,

    fn deinit(self: PreparedResumeAttach, allocator: std.mem.Allocator) void {
        allocator.free(self.request);
        allocator.free(self.generation_state.params_b64);
    }
};

fn loadGenerationParams(io: Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const params = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(generation.params_size));
    try generation.validateFanoutParams(allocator, params);
    return params;
}

fn prepareResumeAttach(allocator: std.mem.Allocator, manifest_generation: spore.GenerationState, generation_params: ?[]const u8) !PreparedResumeAttach {
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
    if (params_payload.len == 0) {
        const payload = struct {
            type: []const u8 = "attach",
            session_id: []const u8 = "default",
            stdout_offset: u64 = 0,
            stderr_offset: u64 = 0,
        }{};
        const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
        defer allocator.free(json);
        return .{
            .request = try std.fmt.allocPrint(allocator, "{s}\n", .{json}),
            .generation_state = generation_state,
        };
    }

    const payload = struct {
        type: []const u8 = "attach",
        session_id: []const u8 = "default",
        stdout_offset: u64 = 0,
        stderr_offset: u64 = 0,
        params_json: []const u8,
    }{
        .params_json = params_payload,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    return .{
        .request = try std.fmt.allocPrint(allocator, "{s}\n", .{json}),
        .generation_state = generation_state,
    };
}

fn validateResumeDiskManifestParts(devices: []const spore.TransportState, rootfs_opt: ?spore.Rootfs, disk_opt: ?spore.Disk) void {
    const disk_count = spore.countBlockDevices(devices);
    if (disk_count == 0) return;
    if (disk_count != 1) {
        failResumeSetup("spore resume: only one immutable rootfs disk is supported; found {d} block devices", .{disk_count});
    }
    const rootfs = rootfs_opt orelse {
        failResumeSetup("spore resume: disk-backed spore has no immutable rootfs artifact; capture with spore run --image or use the backend harness with the original disk", .{});
    };
    spore.validateRootfs(rootfs, devices) catch {
        failResumeSetup("spore resume: invalid immutable rootfs metadata in manifest", .{});
    };
    if (disk_opt) |writable_disk| {
        spore.validateDisk(writable_disk, rootfs, devices) catch {
            failResumeSetup("spore resume: invalid writable disk metadata in manifest", .{});
        };
    }
}

fn failResumeSetup(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(2);
}

test "resume cli parser accepts one spore dir" {
    const opts = try parseCliArgs(&.{ "--backend", "hvf", "--timeout-ms", "120000", "child.spore" });
    try std.testing.expectEqual(Backend.hvf, opts.backend);
    try std.testing.expectEqual(@as(u64, 120_000), opts.timeout_ms);
    try std.testing.expectEqualStrings("child.spore", opts.spore_dir);
}

test "resume cli parser accepts jsonl events" {
    const opts = try parseCliArgs(&.{ "--events=jsonl", "child.spore" });
    try std.testing.expectEqual(run_mod.EventMode.jsonl, opts.event_mode);
    try std.testing.expectEqualStrings("child.spore", opts.spore_dir);
}

test "resume cli parser accepts generation file" {
    const opts = try parseCliArgs(&.{ "--generation", "generation.json", "--events=jsonl", "child.spore" });
    try std.testing.expectEqualStrings("generation.json", opts.generation_path.?);
    try std.testing.expectEqual(run_mod.EventMode.jsonl, opts.event_mode);
    try std.testing.expectEqualStrings("child.spore", opts.spore_dir);
}

test "resume cli parser accepts bound service bindings" {
    const opts = try parseCliArgs(&.{ "--bind-service", "metadata=unix:/tmp/metadata.sock", "child.spore" });
    try std.testing.expectEqualStrings("child.spore", opts.spore_dir);
    try std.testing.expectEqual(@as(usize, 1), opts.bound_services.len);
    try std.testing.expectEqualStrings("metadata", opts.bound_services.items[0].name);
    try std.testing.expectEqualStrings("/tmp/metadata.sock", opts.bound_services.items[0].target.unix);
}

test "resume attach request omits empty generation params" {
    const allocator = std.testing.allocator;
    const manifest = testDiskGuardManifest(&.{}, false);
    const attach = try prepareResumeAttach(allocator, manifest.generation, null);
    defer attach.deinit(allocator);
    try std.testing.expectEqualStrings("{\"type\":\"attach\",\"session_id\":\"default\",\"stdout_offset\":0,\"stderr_offset\":0}\n", attach.request);
    try std.testing.expectEqualStrings("", attach.generation_state.params_b64);
}

test "resume attach request carries refreshed generation params" {
    const allocator = std.testing.allocator;
    var manifest = testDiskGuardManifest(&.{}, false);
    var gen_dev = generation.Device{};
    const stable_params =
        \\{"schema_version":0,"parent_generation":1,"generation":2,"fork_index":0,"fork_count":2,"parallel_index":0,"parallel_count":2,"fork_batch_id":"0123456789abcdef0123456789abcdef","vm_id":"spore-0123456789abcdef0123456789abcdef","hostname":"spore-01234567-000000","mac_seed":"0123456789abcdef0123456789abcdef","mac_address":"02:00:00:00:00:01"}
    ;
    try std.testing.expect(try gen_dev.setResume(2, stable_params));
    manifest.generation = try gen_dev.capture(allocator);
    defer allocator.free(manifest.generation.params_b64);

    const attach = try prepareResumeAttach(allocator, manifest.generation, null);
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

test "resume attach request accepts explicit generation params" {
    const allocator = std.testing.allocator;
    const params =
        \\{"run_id":"rails-rspec-1","child_id":7,"parallel_index":7,"parallel_count":1000,"fork_index":7,"fork_count":1000,"fork_batch_id":"batch-1","vm_id":"spore-child-7"}
    ;
    try generation.validateFanoutParams(allocator, params);

    const manifest = testDiskGuardManifest(&.{}, false);
    const attach = try prepareResumeAttach(allocator, manifest.generation, params);
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
            .ram_size = 0,
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
        .memory = .{ .chunk_size = spore.chunk_size, .chunks = &.{} },
    };
}

test "resume accepts writable disk manifests for layered runtime setup" {
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
    validateResumeDiskManifestParts(without_disk.devices, without_disk.rootfs, without_disk.disk);
    const with_disk = testDiskGuardManifest(&devices, true);
    validateResumeDiskManifestParts(with_disk.devices, with_disk.rootfs, with_disk.disk);
}
