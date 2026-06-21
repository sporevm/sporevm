//! Product resume support for `spore resume`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const hvf = @import("hvf/hvf.zig");
const generation = @import("generation.zig");
const kvm = if (builtin.os.tag == .linux and builtin.cpu.arch == .aarch64)
    @import("kvm/kvm.zig")
else
    struct {};
const net_gateway = @import("net_gateway.zig");
const run_mod = @import("run.zig");
const spore = @import("spore.zig");
const virtio_blk = @import("virtio/blk.zig");
const virtio_net = @import("virtio/net.zig");
const vsock = @import("virtio/vsock.zig");

pub const Backend = run_mod.Backend;
const default_resume_guest_port: u32 = 10700;
const generation_probe_host_port: u32 = 49153;
const generation_probe_timeout_ms: u64 = 5_000;
const hvf_generation_probe_rx_delay_ms: u64 = 25;

pub const Options = struct {
    backend: Backend = .auto,
    spore_dir: []const u8,
    event_mode: run_mod.EventMode = .none,
    event_writer: ?*run_mod.EventWriter = null,
};

const cli_usage =
    \\Usage:
    \\  spore resume [--backend auto|hvf|kvm] <spore-dir>
    \\
    \\Options:
    \\  --backend auto|hvf|kvm  Backend to run (default: auto)
    \\  --events=jsonl          Emit lifecycle and console output events as JSONL on stdout
    \\  -h, --help              Show this help
    \\
;

pub fn cli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help")) {
        try stdout.writeAll(cli_usage);
        return;
    }

    var opts = try parseCliArgs(args);
    var event_writer = run_mod.EventWriter.init(std.heap.page_allocator, stdout, "resume");
    if (opts.event_mode == .jsonl) {
        opts.event_writer = &event_writer;
        try event_writer.emitStart(opts.backend);
    }
    const result = execute(init, init.arena.allocator(), opts) catch |err| {
        if (opts.event_mode == .jsonl) {
            try event_writer.emitFailure(err);
            std.process.exit(run_mod.machineErrorExitCode(err));
        }
        return err;
    };
    if (opts.event_mode == .jsonl) {
        try event_writer.emitExit(result);
    }
}

pub fn parseCliArgs(args: []const []const u8) !Options {
    var backend: Backend = .auto;
    var spore_dir: ?[]const u8 = null;
    var event_mode: run_mod.EventMode = .none;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--backend") and i + 1 < args.len) {
            i += 1;
            backend = Backend.parse(args[i]) orelse {
                std.debug.print("--backend must be auto, hvf, or kvm\n", .{});
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
        .event_mode = event_mode,
        .spore_dir = spore_dir orelse {
            std.debug.print("{s}", .{cli_usage});
            std.process.exit(2);
        },
    };
}

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, opts: Options) !run_mod.Result {
    resume_event_writer = opts.event_writer;
    defer resume_event_writer = null;

    const parsed = try spore.loadManifest(allocator, opts.spore_dir);
    defer parsed.deinit();

    const network_options = run_mod.networkOptionsFromManifest(allocator, parsed.value.network) catch {
        failResumeSetup("spore resume: invalid network policy in manifest", .{});
    };
    var gateway: net_gateway.Process = undefined;
    var gateway_active = false;
    if (network_options.network == .spore) {
        try gateway.start(init, allocator, network_options.policy);
        gateway_active = true;
    }
    defer if (gateway_active) gateway.deinit();
    const network: virtio_net.Runtime = if (gateway_active) gateway.runtime() else .{};

    validateResumeDiskManifest(parsed.value);
    var runtime_disk = try run_mod.openRuntimeDisk(init, allocator, .{
        .rootfs = parsed.value.rootfs,
        .disk = parsed.value.disk,
        .spore_dir = opts.spore_dir,
        .command_name = "resume",
    });
    defer runtime_disk.deinit();
    const identity_request = resumeIdentityRequest(allocator, parsed.value.generation) catch |err| switch (err) {
        error.RunRequestTooLarge => null,
        else => |e| return e,
    };
    defer if (identity_request) |request| allocator.free(request);
    var identity_stream: ?vsock.HostStream = if (identity_request) |request|
        try vsock.HostStream.init(default_resume_guest_port, request)
    else
        null;
    if (identity_stream) |*stream| {
        stream.host_port = generation_probe_host_port;
        if (opts.event_writer) |writer| stream.setLifecycleSink(writer, resumeEventLifecycleSink);
        stream.setOutputSink(null, identityProbeOutputSink);
    }
    const identity_probe: ?*vsock.HostStream = if (identity_stream) |*stream| stream else null;

    const backend = try resolveBackend(opts.backend);
    if (opts.event_writer) |writer| writer.setBackend(backend);
    const ram_size = resumeRamSize(parsed.value.platform);
    const local_backing = try spore.openProvenLocalMemoryBacking(allocator, init.environ_map, opts.spore_dir, parsed.value.memory, ram_size);
    defer if (local_backing.fd) |fd| {
        _ = std.c.close(fd);
    };
    std.log.info("resume memory restore source={s} reason={s}", .{ @tagName(local_backing.source), local_backing.reason });
    const cause = switch (backend) {
        .auto => unreachable,
        .hvf => blk: {
            if (comptime !(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) return error.UnsupportedBackend;
            break :blk try hvf.vm.run(allocator, .{
                .kernel = "",
                .ram_size = ram_size,
                .console_sink = if (opts.event_writer == null) consoleSink else eventConsoleSink,
                .disk_backend = runtime_disk.backend(),
                .resume_dir = opts.spore_dir,
                .ram_backing_fd = local_backing.fd,
                .network = network,
                .exec_probe = identity_probe,
                .exec_probe_timeout_ms = generation_probe_timeout_ms,
                .exec_probe_initial_rx_delay_ms = hvf_generation_probe_rx_delay_ms,
                .exec_probe_completes_run = false,
                .exec_probe_failure_fatal = false,
            });
        },
        .kvm => blk: {
            if (comptime !(builtin.os.tag == .linux and builtin.cpu.arch == .aarch64)) return error.UnsupportedBackend;
            break :blk try kvm.vm.run(allocator, .{
                .kernel = "",
                .ram_size = ram_size,
                .console_sink = if (opts.event_writer == null) consoleSink else eventConsoleSink,
                .disk_backend = runtime_disk.backend(),
                .resume_dir = opts.spore_dir,
                .ram_backing_fd = local_backing.fd,
                .network = network,
                .exec_probe = identity_probe,
                .exec_probe_timeout_ms = generation_probe_timeout_ms,
                .exec_probe_completes_run = false,
                .exec_probe_failure_fatal = false,
            });
        },
    };

    if (comptime @hasField(@TypeOf(cause), "monitor_stopped")) {
        switch (cause) {
            .guest_off, .guest_reset => {},
            .snapshotted, .probe_complete, .monitor_stopped => return error.UnexpectedResumeExit,
        }
    } else {
        switch (cause) {
            .guest_off, .guest_reset => {},
            .snapshotted, .probe_complete => return error.UnexpectedResumeExit,
        }
    }
    if (gateway_active and gateway.hasFailed()) return error.NetworkGatewayFailed;
    const connect_ms = if (identity_stream) |stream| stream.connect_ms orelse 0 else 0;
    const response_ms = if (identity_stream) |stream| stream.response_ms orelse 0 else 0;
    return .{
        .backend = backend,
        .start_ms = 0,
        .vsock_connect_ms = connect_ms,
        .exec_response_ms = response_ms,
        .probe_duration_ms = if (response_ms >= connect_ms) response_ms - connect_ms else 0,
        .exit_code = 0,
        .vcpus = 1,
        .memory_bytes = ram_size,
    };
}

fn consoleSink(bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(1, remaining.ptr, remaining.len);
        if (n <= 0) return;
        remaining = remaining[@intCast(n)..];
    }
}

var resume_event_writer: ?*run_mod.EventWriter = null;

fn eventConsoleSink(bytes: []const u8) void {
    if (resume_event_writer) |writer| {
        writer.emitOutputBestEffort(.stdout, bytes);
    }
}

fn resumeEventLifecycleSink(context: ?*anyopaque, event: vsock.HostStreamLifecycle) void {
    const writer: *run_mod.EventWriter = @ptrCast(@alignCast(context.?));
    switch (event) {
        .ready => writer.emitReadyBestEffort(),
    }
}

fn identityProbeOutputSink(_: ?*anyopaque, output: vsock.HostStreamOutput, bytes: []const u8) void {
    if (output != .stderr) return;
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(2, remaining.ptr, remaining.len);
        if (n <= 0) return;
        remaining = remaining[@intCast(n)..];
    }
}

fn resolveBackend(backend: Backend) !Backend {
    if (backend != .auto) return backend;
    if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) return .hvf;
    if (builtin.os.tag == .linux and builtin.cpu.arch == .aarch64) return .kvm;
    return error.UnsupportedBackend;
}

fn resumeRamSize(platform: spore.Platform) u64 {
    return platform.ram_size;
}

fn validateResumeDiskManifest(manifest: spore.Manifest) void {
    const disk_count = countBlockDevices(manifest.devices);
    if (disk_count == 0) return;
    if (disk_count != 1) {
        failResumeSetup("spore resume: only one immutable rootfs disk is supported; found {d} block devices", .{disk_count});
    }
    const rootfs = manifest.rootfs orelse {
        failResumeSetup("spore resume: disk-backed spore has no immutable rootfs artifact; capture with spore run --image or use the backend harness with the original disk", .{});
    };
    spore.validateRootfs(rootfs, manifest.devices) catch {
        failResumeSetup("spore resume: invalid immutable rootfs metadata in manifest", .{});
    };
    if (manifest.disk) |disk| {
        spore.validateDisk(disk, rootfs, manifest.devices) catch {
            failResumeSetup("spore resume: invalid writable disk metadata in manifest", .{});
        };
    }
}

fn countBlockDevices(devices: []const spore.TransportState) usize {
    var count: usize = 0;
    for (devices) |device| {
        if (device.device_id == virtio_blk.device_id) count += 1;
    }
    return count;
}

fn resumeIdentityRequest(allocator: std.mem.Allocator, state: spore.GenerationState) !?[]const u8 {
    if (state.params_b64.len == 0) return null;

    var gen_dev = generation.Device{};
    gen_dev.restore(allocator, state) catch |err| switch (err) {
        error.BadState => return error.BadManifest,
        else => |e| return e,
    };
    try spore.refreshResumeParams(allocator, &gen_dev);

    var end = gen_dev.params.len;
    while (end > 0 and gen_dev.params[end - 1] == 0) : (end -= 1) {}
    if (end == 0) return null;
    return try run_mod.generationRequest(allocator, gen_dev.params[0..end]);
}

fn failResumeSetup(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(2);
}

test "resume cli parser accepts one spore dir" {
    const opts = try parseCliArgs(&.{ "--backend", "hvf", "child.spore" });
    try std.testing.expectEqual(Backend.hvf, opts.backend);
    try std.testing.expectEqualStrings("child.spore", opts.spore_dir);
}

test "resume cli parser accepts jsonl events" {
    const opts = try parseCliArgs(&.{ "--events=jsonl", "child.spore" });
    try std.testing.expectEqual(run_mod.EventMode.jsonl, opts.event_mode);
    try std.testing.expectEqualStrings("child.spore", opts.spore_dir);
}

test "resume memory defaults to manifest ram size" {
    const platform = spore.Platform{
        .cpu_profile = "test",
        .device_model_version = 1,
        .ram_base = 0x40000000,
        .ram_size = 384 * 1024 * 1024,
        .gic_dist_base = 0x08000000,
        .gic_redist_base = 0x08010000,
        .counter_frequency_hz = 24_000_000,
    };
    try std.testing.expectEqual(@as(u64, 384 * 1024 * 1024), resumeRamSize(platform));
}

test "resume identity request carries resume-time fields" {
    const allocator = std.testing.allocator;
    const params =
        \\{"schema_version":0,"parent_generation":7,"generation":8,"fork_index":2,"fork_count":4,"parallel_index":2,"parallel_count":4,"fork_batch_id":"0123456789abcdef0123456789abcdef","vm_id":"spore-test","hostname":"spore-test","mac_seed":"0123456789abcdef0123456789abcdef","mac_address":"02:00:00:00:00:02"}
    ;
    const enc = std.base64.standard.Encoder;
    const params_b64 = try allocator.alloc(u8, enc.calcSize(params.len));
    defer allocator.free(params_b64);
    _ = enc.encode(params_b64, params);

    const request = (try resumeIdentityRequest(allocator, .{
        .generation = 8,
        .interrupt_status = generation.irq_generation_changed,
        .params_b64 = params_b64,
    })).?;
    defer allocator.free(request);

    try std.testing.expect(std.mem.indexOf(u8, request, "\"type\":\"generation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "resume_time_unix_ns") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "resume_entropy_seed") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "parallel_index\\\":2") != null);
}

test "resume counts block devices for disk dependency classification" {
    const disk_device = spore.TransportState{
        .device_id = virtio_blk.device_id,
        .status = 0,
        .device_features_sel = 0,
        .driver_features_sel = 0,
        .driver_features = 0,
        .queue_sel = 0,
        .interrupt_status = 0,
        .queues = &.{},
    };
    const console_device = spore.TransportState{
        .device_id = 3,
        .status = 0,
        .device_features_sel = 0,
        .driver_features_sel = 0,
        .driver_features = 0,
        .queue_sel = 0,
        .interrupt_status = 0,
        .queues = &.{},
    };

    try std.testing.expectEqual(@as(usize, 1), countBlockDevices(&.{ console_device, disk_device }));
    try std.testing.expectEqual(@as(usize, 0), countBlockDevices(&.{console_device}));
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
        .device_id = virtio_blk.device_id,
        .status = 0,
        .device_features_sel = 0,
        .driver_features_sel = 0,
        .driver_features = 0,
        .queue_sel = 0,
        .interrupt_status = 0,
        .queues = &.{},
    }};
    validateResumeDiskManifest(testDiskGuardManifest(&devices, false));
    validateResumeDiskManifest(testDiskGuardManifest(&devices, true));
}
