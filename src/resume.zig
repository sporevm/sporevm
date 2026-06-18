//! Product resume support for `spore resume`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const hvf = @import("hvf/hvf.zig");
const kvm = if (builtin.os.tag == .linux and builtin.cpu.arch == .aarch64)
    @import("kvm/kvm.zig")
else
    struct {};
const run_mod = @import("run.zig");
const spore = @import("spore.zig");
const virtio_blk = @import("virtio/blk.zig");
const vsock = @import("virtio/vsock.zig");

pub const Backend = run_mod.Backend;
const default_resume_guest_port: u32 = 10700;
const generation_probe_host_port: u32 = 49153;
const generation_probe_timeout_ms: u64 = 5_000;
const hvf_generation_probe_rx_delay_ms: u64 = 25;

pub const Options = struct {
    backend: Backend = .auto,
    spore_dir: []const u8,
};

const cli_usage =
    \\Usage:
    \\  spore resume [--backend auto|hvf|kvm] <spore-dir>
    \\
    \\Options:
    \\  --backend auto|hvf|kvm  Backend to run (default: auto)
    \\  -h, --help              Show this help
    \\
;

pub fn cli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help")) {
        try stdout.writeAll(cli_usage);
        return;
    }

    const opts = try parseCliArgs(args);
    try execute(init, init.arena.allocator(), opts);
}

pub fn parseCliArgs(args: []const []const u8) !Options {
    var backend: Backend = .auto;
    var spore_dir: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--backend") and i + 1 < args.len) {
            i += 1;
            backend = Backend.parse(args[i]) orelse {
                std.debug.print("--backend must be auto, hvf, or kvm\n", .{});
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
        .spore_dir = spore_dir orelse {
            std.debug.print("{s}", .{cli_usage});
            std.process.exit(2);
        },
    };
}

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, opts: Options) !void {
    const parsed = try spore.loadManifest(allocator, opts.spore_dir);
    defer parsed.deinit();

    const rootfs_fd = try openResumeRootfs(init, allocator, parsed.value);
    defer {
        if (rootfs_fd) |fd| _ = std.c.close(fd);
    }
    const identity_request = resumeIdentityRequest(allocator, parsed.value.generation) catch |err| switch (err) {
        error.RunRequestTooLarge => null,
        else => |e| return e,
    };
    defer if (identity_request) |request| allocator.free(request);
    var identity_stream: ?vsock.HostStream = if (identity_request) |request|
        try vsock.HostStream.init(default_resume_guest_port, request)
    else
        null;
    if (identity_stream) |*stream| stream.host_port = generation_probe_host_port;
    const identity_probe: ?*vsock.HostStream = if (identity_stream) |*stream| stream else null;

    const backend = try resolveBackend(opts.backend);
    const ram_size = resumeRamSize(parsed.value.platform);
    const cause = switch (backend) {
        .auto => unreachable,
        .hvf => blk: {
            if (comptime !(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) return error.UnsupportedBackend;
            break :blk try hvf.vm.run(allocator, .{
                .kernel = "",
                .ram_size = ram_size,
                .console_sink = consoleSink,
                .disk_fd = rootfs_fd,
                .resume_dir = opts.spore_dir,
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
                .console_sink = consoleSink,
                .disk_fd = rootfs_fd,
                .resume_dir = opts.spore_dir,
                .exec_probe = identity_probe,
                .exec_probe_timeout_ms = generation_probe_timeout_ms,
                .exec_probe_completes_run = false,
                .exec_probe_failure_fatal = false,
            });
        },
    };

    switch (cause) {
        .guest_off, .guest_reset => {},
        .snapshotted, .probe_complete, .monitor_stopped => return error.UnexpectedResumeExit,
    }
}

fn consoleSink(bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(1, remaining.ptr, remaining.len);
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

fn openResumeRootfs(init: std.process.Init, allocator: std.mem.Allocator, manifest: spore.Manifest) !?std.c.fd_t {
    const disk_count = countBlockDevices(manifest.devices);
    if (disk_count == 0) return null;
    if (disk_count != 1) {
        failResumeSetup("spore resume: only one immutable rootfs disk is supported; found {d} block devices", .{disk_count});
    }
    const rootfs = manifest.rootfs orelse {
        failResumeSetup("spore resume: disk-backed spore has no immutable rootfs artifact; capture with spore run --image or use the backend harness with the original disk", .{});
    };
    spore.validateRootfs(rootfs, manifest.devices) catch {
        failResumeSetup("spore resume: invalid immutable rootfs metadata in manifest", .{});
    };
    return run_mod.openVerifiedRootfs(init, allocator, rootfs, "resume") catch |err| {
        failResumeSetup("spore resume: immutable rootfs artifact unavailable or unverifiable: {s}", .{@errorName(err)});
    };
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
    const dec = std.base64.standard.Decoder;
    const decoded_size = dec.calcSizeForSlice(state.params_b64) catch return error.BadManifest;
    if (decoded_size == 0) return null;
    const decoded = try allocator.alloc(u8, decoded_size);
    defer allocator.free(decoded);
    dec.decode(decoded, state.params_b64) catch return error.BadManifest;

    var end = decoded.len;
    while (end > 0 and decoded[end - 1] == 0) : (end -= 1) {}
    if (end == 0) return null;
    return try run_mod.generationRequest(allocator, decoded[0..end]);
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
