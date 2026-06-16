//! One-shot VM boot/exec support for `spore run`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Blake3 = std.crypto.hash.Blake3;
const Sha256 = std.crypto.hash.sha2.Sha256;

const capture = @import("capture.zig");
const hvf = @import("hvf/hvf.zig");
const kvm = if (builtin.os.tag == .linux and builtin.cpu.arch == .aarch64)
    @import("kvm/kvm.zig")
else
    struct {};
const local_paths = @import("local_paths.zig");
const rootfs_mod = @import("rootfs.zig");
const spore = @import("spore.zig");
const virtio_blk = @import("virtio/blk.zig");
const vsock = @import("virtio/vsock.zig");

const max_file_size = 256 * 1024 * 1024;
const max_kernel_asset_size = 256 * 1024 * 1024;
const managed_kernel_download_attempts = 3;
const max_guest_argc = 16;
const max_guest_arg_len = 255;
const max_guest_request_len = 2047;
const max_guest_port = 65535;
const default_run_initrd_name = "minimal-exec-initrd.cpio";
const default_kernel_repository = "buildkite/cleanroom-kernels";
const default_kernel_release = "v0.4.0";
const default_kernel_version = "6.1.155";
const direct_image_platform = rootfs_mod.Platform{};
const max_rootfs_metadata_bytes = 1024 * 1024;
const max_image_ref_cache_record_bytes = 64 * 1024;
const image_ref_cache_record_version: u32 = 1;
const mib: u64 = 1024 * 1024;

pub const Backend = enum {
    auto,
    hvf,
    kvm,

    pub fn parse(raw: []const u8) ?Backend {
        if (std.mem.eql(u8, raw, "auto")) return .auto;
        if (std.mem.eql(u8, raw, "hvf")) return .hvf;
        if (std.mem.eql(u8, raw, "kvm")) return .kvm;
        return null;
    }

    pub fn name(self: Backend) []const u8 {
        return switch (self) {
            .auto => "auto",
            .hvf => "hvf",
            .kvm => "kvm",
        };
    }
};

pub const Options = struct {
    backend: Backend = .auto,
    kernel_path: []const u8,
    initrd_path: []const u8,
    rootfs_path: ?[]const u8 = null,
    rootfs: ?spore.Rootfs = null,
    resume_dir: ?[]const u8 = null,
    command: []const []const u8,
    memory_mib: u64 = 1024,
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    console_log_path: ?[]const u8 = null,
    stream_output: bool = true,
    capture_path: ?[]const u8 = null,
    capture_trigger: capture.Trigger = .exit,
    continue_after_capture: bool = false,
};

pub const Result = struct {
    backend: Backend,
    start_ms: u64,
    vsock_connect_ms: u64,
    exec_response_ms: u64,
    probe_duration_ms: u64,
    exit_code: i32,
    vcpus: u32,
    memory_mib: u64,
    captured: bool = false,
    capture_path: ?[]const u8 = null,

    pub fn processExitCode(self: Result) u8 {
        std.debug.assert(self.exit_code >= 0 and self.exit_code <= 255);
        return @intCast(self.exit_code);
    }
};

pub const MonitorExit = enum {
    stopped,
    snapshotted,
};

pub const MonitorResult = struct {
    backend: Backend,
    exit: MonitorExit,
};

const SharedOptions = struct {
    kernel_path: ?[]const u8 = null,
    initrd_path: ?[]const u8 = null,
    memory_mib: u64 = 1024,
    memory_mib_set: bool = false,
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    console_log_path: ?[]const u8 = null,

    fn completeWithAssets(
        self: SharedOptions,
        backend: Backend,
        kernel_path: []const u8,
        initrd_path: []const u8,
        rootfs_path: ?[]const u8,
        rootfs: ?spore.Rootfs,
        command: []const []const u8,
        stream_output: bool,
    ) Options {
        return .{
            .backend = backend,
            .kernel_path = kernel_path,
            .initrd_path = initrd_path,
            .rootfs_path = rootfs_path,
            .rootfs = rootfs,
            .resume_dir = null,
            .command = command,
            .memory_mib = self.memory_mib,
            .vcpus = self.vcpus,
            .guest_port = self.guest_port,
            .timeout_ms = self.timeout_ms,
            .console_log_path = self.console_log_path,
            .stream_output = stream_output,
        };
    }
};

pub const CliOptions = struct {
    backend: Backend = .auto,
    shared: SharedOptions = .{},
    from_spore_dir: ?[]const u8 = null,
    rootfs_path: ?[]const u8 = null,
    image_ref: ?[]const u8 = null,
    capture_path: ?[]const u8 = null,
    capture_trigger: capture.Trigger = .exit,
    continue_after_capture: bool = false,
    command: []const []const u8,
};

const cli_usage =
    \\Usage:
    \\  spore run [--kernel Image] [--initrd root.cpio] [options] -- <argv...>
    \\
    \\Options:
    \\  --backend auto|hvf|kvm  Backend to run (default: auto)
    \\  --kernel Image          Kernel Image path (default: managed SporeVM run kernel)
    \\  --initrd root.cpio      Initrd path (default: installed minimal exec initrd)
    \\  --from DIR              Resume from an existing spore, then run argv
    \\  --rootfs rootfs.ext4    Attach rootfs image read-only as virtio-blk
    \\  --image REF             Build or reuse cached OCI rootfs, then run from it
    \\  --capture DIR           Snapshot to DIR; defaults to --capture-on EXIT
    \\  --capture-on WHEN       Capture trigger: EXIT, INT, TERM, HUP, USR1, or USR2
    \\  --continue-after-capture
    \\                          Keep running after a signal-triggered capture
    \\  --memory-mib N          Guest memory in MiB (default: 1024)
    \\  --vcpus N               Guest vCPU count; must be 1 today
    \\  --guest-port N          Guest vsock listen port (default: 10700)
    \\  --timeout-ms N          Probe timeout in milliseconds (default: 30000)
    \\  --console-log PATH      Write guest console output to PATH
    \\  -h, --help              Show this help
    \\
;

pub fn cli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help")) {
        try stdout.writeAll(cli_usage);
        return;
    }

    const arena = init.arena.allocator();
    const parsed = try parseCliArgs(args);
    const opts = try resolveCliOptions(init, arena, parsed);
    try openConsoleLog(opts.console_log_path);
    defer closeConsoleLog();

    const result = execute(init, arena, opts) catch |err| {
        if (isCaptureAborted(err)) std.process.exit(130);
        return err;
    };
    if (result.captured) {
        if (result.capture_path) |path| {
            const message = try std.fmt.allocPrint(arena, "spore run: captured snapshot at {s}\n", .{path});
            try writeSetupStderr(init, message);
        }
    }
    const code = result.processExitCode();
    if (code != 0) std.process.exit(code);
}

pub fn parseCliArgs(args: []const []const u8) !CliOptions {
    var backend: Backend = .auto;
    var shared = SharedOptions{};
    var from_spore_dir: ?[]const u8 = null;
    var rootfs_path: ?[]const u8 = null;
    var image_ref: ?[]const u8 = null;
    var capture_path: ?[]const u8 = null;
    var capture_trigger: capture.Trigger = .exit;
    var capture_trigger_set = false;
    var continue_after_capture = false;
    var command: ?[]const []const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            command = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, args[i], "--backend") and i + 1 < args.len) {
            i += 1;
            backend = Backend.parse(args[i]) orelse {
                std.debug.print("--backend must be auto, hvf, or kvm\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, args[i], "--rootfs")) {
            rootfs_path = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--image")) {
            image_ref = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--from")) {
            from_spore_dir = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--capture")) {
            capture_path = takeValue(args, &i, args[i]);
        } else if (std.mem.eql(u8, args[i], "--capture-on")) {
            const trigger_raw = takeValue(args, &i, args[i]);
            capture_trigger = capture.Trigger.parse(trigger_raw) orelse {
                std.debug.print("--capture-on must be EXIT, INT, TERM, HUP, USR1, or USR2\n", .{});
                std.process.exit(2);
            };
            capture_trigger_set = true;
        } else if (std.mem.eql(u8, args[i], "--continue-after-capture")) {
            continue_after_capture = true;
        } else if (try parseSharedOption(&shared, args, &i)) {
            continue;
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            std.debug.print("unknown run argument: {s}\n\n{s}", .{ args[i], cli_usage });
            std.process.exit(2);
        } else {
            command = args[i..];
            break;
        }
    }

    const argv = command orelse &.{};
    if (argv.len == 0) {
        std.debug.print("{s}", .{cli_usage});
        std.process.exit(2);
    }
    if (rootfs_path != null and image_ref != null) {
        std.debug.print("spore run: --rootfs and --image are mutually exclusive\n", .{});
        std.process.exit(2);
    }
    if (from_spore_dir != null) {
        if (rootfs_path != null or image_ref != null) {
            std.debug.print("spore run: --from is mutually exclusive with --rootfs and --image\n", .{});
            std.process.exit(2);
        }
        if (shared.kernel_path != null or shared.initrd_path != null) {
            std.debug.print("spore run: --from is mutually exclusive with --kernel and --initrd\n", .{});
            std.process.exit(2);
        }
        if (shared.memory_mib_set) {
            std.debug.print("spore run: --from uses the spore manifest memory size; omit --memory-mib\n", .{});
            std.process.exit(2);
        }
    }
    if (capture_trigger_set and capture_path == null) {
        std.debug.print("spore run: --capture-on requires --capture\n", .{});
        std.process.exit(2);
    }
    if (continue_after_capture and capture_path == null) {
        std.debug.print("spore run: --continue-after-capture requires --capture\n", .{});
        std.process.exit(2);
    }
    if (continue_after_capture and captureTriggerIsExit(capture_trigger)) {
        std.debug.print("spore run: --continue-after-capture requires a signal capture trigger\n", .{});
        std.process.exit(2);
    }

    return .{
        .backend = backend,
        .shared = shared,
        .from_spore_dir = from_spore_dir,
        .rootfs_path = rootfs_path,
        .image_ref = image_ref,
        .capture_path = capture_path,
        .capture_trigger = capture_trigger,
        .continue_after_capture = continue_after_capture,
        .command = argv,
    };
}

fn resolveCliOptions(init: std.process.Init, allocator: std.mem.Allocator, parsed: CliOptions) !Options {
    if (parsed.from_spore_dir) |spore_dir| {
        const manifest = spore.loadManifest(allocator, spore_dir) catch |err| {
            failRunSetup("spore run: --from could not load spore manifest: {s}", .{@errorName(err)});
        };
        defer manifest.deinit();

        const rootfs = try resumeRootfsForRun(allocator, manifest.value);
        var opts = parsed.shared.completeWithAssets(parsed.backend, "", "", null, rootfs, parsed.command, true);
        opts.resume_dir = spore_dir;
        opts.memory_mib = runMemoryMiBFromManifest(manifest.value);
        opts.capture_path = parsed.capture_path;
        opts.capture_trigger = parsed.capture_trigger;
        opts.continue_after_capture = parsed.continue_after_capture;
        return opts;
    }

    if (parsed.capture_path != null and parsed.rootfs_path != null and parsed.image_ref == null) {
        failRunSetup("spore run: --rootfs with --capture is not portable yet; use --image so capture can record immutable rootfs identity", .{});
    }
    const rootfs = try resolveRootfsInputDetailed(init, allocator, .{
        .rootfs_path = parsed.rootfs_path,
        .image_ref = parsed.image_ref,
        .command_name = "run",
        .record_artifact = parsed.capture_path != null,
    });
    const kernel_path = parsed.shared.kernel_path orelse try resolveDefaultKernelPath(init, allocator);
    const initrd_path = parsed.shared.initrd_path orelse try resolveDefaultInitrdPath(init, allocator);
    var opts = parsed.shared.completeWithAssets(parsed.backend, kernel_path, initrd_path, rootfs.path, rootfs.rootfs, parsed.command, true);
    opts.capture_path = parsed.capture_path;
    opts.capture_trigger = parsed.capture_trigger;
    opts.continue_after_capture = parsed.continue_after_capture;
    return opts;
}

fn runMemoryMiBFromManifest(manifest: spore.Manifest) u64 {
    if (manifest.platform.ram_size % mib != 0) {
        failRunSetup("spore run: --from manifest RAM size is not MiB-aligned: {d}", .{manifest.platform.ram_size});
    }
    return manifest.platform.ram_size / mib;
}

fn resumeRootfsForRun(allocator: std.mem.Allocator, manifest: spore.Manifest) !?spore.Rootfs {
    const disk_count = countBlockDevices(manifest.devices);
    if (disk_count == 0) return null;
    if (disk_count != 1) {
        failRunSetup("spore run: --from supports at most one immutable rootfs disk; found {d} block devices", .{disk_count});
    }
    const rootfs = manifest.rootfs orelse {
        failRunSetup("spore run: --from disk-backed spore has no immutable rootfs artifact; capture with spore run --image", .{});
    };
    spore.validateRootfs(rootfs, manifest.devices) catch {
        failRunSetup("spore run: --from manifest has invalid immutable rootfs metadata", .{});
    };
    return try cloneRootfs(allocator, rootfs);
}

fn countBlockDevices(devices: []const spore.TransportState) usize {
    var count: usize = 0;
    for (devices) |device| {
        if (device.device_id == virtio_blk.device_id) count += 1;
    }
    return count;
}

fn cloneRootfs(allocator: std.mem.Allocator, rootfs: spore.Rootfs) !spore.Rootfs {
    return .{
        .kind = try allocator.dupe(u8, rootfs.kind),
        .mode = try allocator.dupe(u8, rootfs.mode),
        .device = .{
            .kind = try allocator.dupe(u8, rootfs.device.kind),
            .role = try allocator.dupe(u8, rootfs.device.role),
            .virtio_device_id = rootfs.device.virtio_device_id,
            .mmio_slot = rootfs.device.mmio_slot,
        },
        .artifact = .{
            .digest = try allocator.dupe(u8, rootfs.artifact.digest),
            .size = rootfs.artifact.size,
            .format = try allocator.dupe(u8, rootfs.artifact.format),
        },
        .source = if (rootfs.source) |source| .{
            .kind = try allocator.dupe(u8, source.kind),
            .requested_ref = try allocator.dupe(u8, source.requested_ref),
            .resolved_image_ref = try allocator.dupe(u8, source.resolved_image_ref),
            .image_manifest_digest = try allocator.dupe(u8, source.image_manifest_digest),
            .platform = try allocator.dupe(u8, source.platform),
            .builder_version = try allocator.dupe(u8, source.builder_version),
        } else null,
    };
}

const RootfsInputOptions = struct {
    rootfs_path: ?[]const u8,
    image_ref: ?[]const u8,
    command_name: []const u8,
    record_artifact: bool = false,
};

const ResolvedRootfsInput = struct {
    path: ?[]const u8,
    rootfs: ?spore.Rootfs = null,
};

pub fn resolveRootfsInput(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    rootfs_path: ?[]const u8,
    image_ref: ?[]const u8,
    command_name: []const u8,
) !?[]const u8 {
    return (try resolveRootfsInputDetailed(init, allocator, .{
        .rootfs_path = rootfs_path,
        .image_ref = image_ref,
        .command_name = command_name,
    })).path;
}

fn resolveRootfsInputDetailed(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: RootfsInputOptions,
) !ResolvedRootfsInput {
    if (options.rootfs_path != null and options.image_ref != null) {
        failRunSetup("spore {s}: --rootfs and --image are mutually exclusive", .{options.command_name});
    }
    const resolved = if (options.image_ref) |ref|
        try resolveImageRootfs(init, allocator, ref, options.command_name, options.record_artifact)
    else
        ResolvedRootfsInput{ .path = options.rootfs_path };
    if (resolved.path) |path| {
        if (!try readablePath(init.io, path)) {
            failRunSetup("spore {s}: rootfs not found: {s}", .{ options.command_name, path });
        }
    }
    return resolved;
}

fn resolveImageRootfs(init: std.process.Init, allocator: std.mem.Allocator, image_ref: []const u8, command_name: []const u8, record_artifact: bool) !ResolvedRootfsInput {
    const cache_root = try rootfsCacheRootPath(init, allocator, command_name);
    try ensureDirPath(init.io, cache_root);

    const digest_pinned = try rootfs_mod.digestPinnedImageIdentity(allocator, image_ref, direct_image_platform);

    if (rootfs_mod.isLocalImageRef(image_ref)) {
        const resolved = rootfs_mod.resolveLocalCachedRef(init.io, allocator, cache_root, image_ref, direct_image_platform) catch |err| {
            failRunSetup("spore {s}: local image ref not imported for {s}: {s}", .{ command_name, image_ref, @errorName(err) });
        };
        if (try cachedImageRootfsPath(init.io, allocator, cache_root, resolved, command_name)) |path| {
            return try resolvedImageRootfsInput(init, allocator, cache_root, image_ref, resolved, path, record_artifact);
        }
        failRunSetup(
            "spore {s}: local image rootfs cache miss for {s}; import an OCI layout with 'spore rootfs import-oci <layout> --ref local/name:tag'",
            .{ command_name, image_ref },
        );
    }

    if (digest_pinned) |resolved| {
        if (try cachedImageRootfsPath(init.io, allocator, cache_root, resolved, command_name)) |path| {
            return try resolvedImageRootfsInput(init, allocator, cache_root, image_ref, resolved, path, record_artifact);
        }
    } else {
        rootfs_mod.validateTaggedImageRef(image_ref) catch |err| {
            failRunSetup("spore {s}: image resolve failed for {s}: {s}", .{ command_name, image_ref, @errorName(err) });
        };
        if (try cachedImageRefRootfsPath(init.io, allocator, cache_root, image_ref, command_name)) |hit| {
            return try resolvedImageRootfsInput(init, allocator, cache_root, image_ref, hit.resolved, hit.path, record_artifact);
        }
    }

    const resolved = rootfs_mod.resolveImageRef(init, allocator, image_ref, direct_image_platform) catch |err| {
        failRunSetup("spore {s}: image resolve failed for {s}: {s}", .{ command_name, image_ref, @errorName(err) });
    };
    if (try cachedImageRootfsPath(init.io, allocator, cache_root, resolved, command_name)) |path| {
        if (digest_pinned == null) try writeImageRefCacheRecord(init.io, allocator, cache_root, image_ref, resolved, command_name);
        return try resolvedImageRootfsInput(init, allocator, cache_root, image_ref, resolved, path, record_artifact);
    }
    const path = try buildCachedImageRootfs(init, allocator, cache_root, resolved, command_name);
    if (digest_pinned == null) try writeImageRefCacheRecord(init.io, allocator, cache_root, image_ref, resolved, command_name);
    return try resolvedImageRootfsInput(init, allocator, cache_root, image_ref, resolved, path, record_artifact);
}

fn resolvedImageRootfsInput(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    requested_ref: []const u8,
    resolved: rootfs_mod.ResolvedImage,
    rootfs_path: []const u8,
    record_artifact: bool,
) !ResolvedRootfsInput {
    if (!record_artifact) return .{ .path = rootfs_path };
    const artifact = try cacheRootfsByDigest(init, allocator, cache_root, rootfs_path);
    const platform = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ resolved.platform.os, resolved.platform.arch });
    const manifest_requested_ref = if (rootfs_mod.isLocalImageRef(requested_ref)) resolved.ref else requested_ref;
    return .{
        .path = rootfs_path,
        .rootfs = .{
            .device = .{ .mmio_slot = 1 },
            .artifact = artifact,
            .source = .{
                .requested_ref = manifest_requested_ref,
                .resolved_image_ref = resolved.ref,
                .image_manifest_digest = resolved.manifest_digest,
                .platform = platform,
                .builder_version = rootfs_mod.builder_version,
            },
        },
    };
}

fn cachedImageRootfsPath(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    resolved: rootfs_mod.ResolvedImage,
    command_name: []const u8,
) !?[]const u8 {
    const cache_key = try rootfs_mod.rootfsCacheKeyAlloc(allocator, resolved);
    const rootfs_path = try std.fmt.allocPrint(allocator, "{s}/{s}.ext4", .{ cache_root, cache_key });
    const metadata_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ cache_root, cache_key });
    const metadata_matches = cachedRootfsMetadataMatches(io, allocator, metadata_path, resolved) catch |err| {
        failRunSetup("spore {s}: cached rootfs metadata check failed: {s}", .{ command_name, @errorName(err) });
    };
    if (metadata_matches and try readablePath(io, rootfs_path)) {
        std.log.debug("spore {s}: using cached rootfs {s} for {s}", .{ command_name, rootfs_path, resolved.ref });
        return rootfs_path;
    }
    return null;
}

const ImageRefCacheHit = struct {
    path: []const u8,
    resolved: rootfs_mod.ResolvedImage,
};

const ImageRefCacheRecord = struct {
    version: u32,
    requested_ref: []const u8,
    platform: []const u8,
    builder_version: []const u8,
    resolved_image_ref: []const u8,
    image_manifest_digest: []const u8,
    rootfs_cache_key: []const u8,
    resolved_at_unix: i64,
};

fn cachedImageRefRootfsPath(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    requested_ref: []const u8,
    command_name: []const u8,
) !?ImageRefCacheHit {
    const record_path = try imageRefCacheRecordPath(allocator, cache_root, requested_ref, direct_image_platform);
    if (!try regularFileNoSymlink(io, record_path)) return null;

    const data = Io.Dir.cwd().readFileAlloc(io, record_path, allocator, .limited(max_image_ref_cache_record_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return null,
        else => |e| return e,
    };
    defer allocator.free(data);

    var parsed = std.json.parseFromSlice(ImageRefCacheRecord, allocator, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    const record = parsed.value;
    const platform = try platformTextAlloc(allocator, direct_image_platform);
    if (record.version != image_ref_cache_record_version) return null;
    if (!std.mem.eql(u8, record.requested_ref, requested_ref)) return null;
    if (!std.mem.eql(u8, record.platform, platform)) return null;
    if (!std.mem.eql(u8, record.builder_version, rootfs_mod.builder_version)) return null;

    const resolved = (rootfs_mod.digestPinnedImageIdentity(allocator, record.resolved_image_ref, direct_image_platform) catch return null) orelse return null;
    if (!std.mem.eql(u8, resolved.manifest_digest, record.image_manifest_digest)) return null;
    const expected_cache_key = try rootfs_mod.rootfsCacheKeyAlloc(allocator, resolved);
    if (!std.mem.eql(u8, record.rootfs_cache_key, expected_cache_key)) return null;

    const rootfs_path = (try cachedImageRootfsPath(io, allocator, cache_root, resolved, command_name)) orelse return null;
    std.log.debug("spore {s}: using cached image ref {s} -> {s}", .{ command_name, requested_ref, resolved.ref });
    return .{ .path = rootfs_path, .resolved = resolved };
}

fn writeImageRefCacheRecord(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    requested_ref: []const u8,
    resolved: rootfs_mod.ResolvedImage,
    command_name: []const u8,
) !void {
    const refs_dir = try std.fs.path.join(allocator, &.{ cache_root, "refs" });
    try ensureDirPath(io, refs_dir);

    const rootfs_cache_key = try rootfs_mod.rootfsCacheKeyAlloc(allocator, resolved);
    const platform = try platformTextAlloc(allocator, resolved.platform);
    const record_path = try imageRefCacheRecordPath(allocator, cache_root, requested_ref, resolved.platform);
    const now = Io.Clock.real.now(io).nanoseconds;
    const record = ImageRefCacheRecord{
        .version = image_ref_cache_record_version,
        .requested_ref = requested_ref,
        .platform = platform,
        .builder_version = rootfs_mod.builder_version,
        .resolved_image_ref = resolved.ref,
        .image_manifest_digest = resolved.manifest_digest,
        .rootfs_cache_key = rootfs_cache_key,
        .resolved_at_unix = @intCast(@divFloor(now, std.time.ns_per_s)),
    };
    const json = try std.json.Stringify.valueAlloc(allocator, record, .{ .whitespace = .indent_2 });
    const temp_id = now;
    var temp_nonce_bytes: [8]u8 = undefined;
    io.random(&temp_nonce_bytes);
    const temp_nonce = std.mem.readInt(u64, &temp_nonce_bytes, .little);
    const temp_path = try std.fmt.allocPrint(allocator, "{s}/.{d}.{x}.json.tmp", .{ refs_dir, temp_id, temp_nonce });
    defer Io.Dir.cwd().deleteFile(io, temp_path) catch {};
    Io.Dir.cwd().writeFile(io, .{ .sub_path = temp_path, .data = json }) catch |err| {
        failRunSetup("spore {s}: image ref cache write failed: {s}", .{ command_name, @errorName(err) });
    };
    renamePath(io, temp_path, record_path) catch |err| {
        failRunSetup("spore {s}: image ref cache update failed: {s}", .{ command_name, @errorName(err) });
    };
    std.log.debug("spore {s}: cached image ref {s} -> {s}", .{ command_name, requested_ref, resolved.ref });
}

fn renamePath(io: Io, old_path: []const u8, new_path: []const u8) !void {
    const old_absolute = Io.Dir.path.isAbsolute(old_path);
    const new_absolute = Io.Dir.path.isAbsolute(new_path);
    if (old_absolute != new_absolute) return error.BadPathName;
    if (old_absolute) {
        try Io.Dir.renameAbsolute(old_path, new_path, io);
    } else {
        try Io.Dir.rename(Io.Dir.cwd(), old_path, Io.Dir.cwd(), new_path, io);
    }
}

fn imageRefCacheRecordPath(
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    requested_ref: []const u8,
    platform: rootfs_mod.Platform,
) ![]const u8 {
    const key = try imageRefCacheKeyAlloc(allocator, requested_ref, platform);
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{key});
    return std.fs.path.join(allocator, &.{ cache_root, "refs", filename });
}

fn imageRefCacheKeyAlloc(allocator: std.mem.Allocator, requested_ref: []const u8, platform: rootfs_mod.Platform) ![]u8 {
    var h = Sha256.init(.{});
    h.update("sporevm-rootfs-ref-v1\n");
    h.update(rootfs_mod.builder_version);
    h.update("\n");
    h.update(platform.os);
    h.update("/");
    h.update(platform.arch);
    h.update("\n");
    h.update(requested_ref);
    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

fn platformTextAlloc(allocator: std.mem.Allocator, platform: rootfs_mod.Platform) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ platform.os, platform.arch });
}

fn buildCachedImageRootfs(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    resolved: rootfs_mod.ResolvedImage,
    command_name: []const u8,
) ![]const u8 {
    const cache_key = try rootfs_mod.rootfsCacheKeyAlloc(allocator, resolved);
    const rootfs_path = try std.fmt.allocPrint(allocator, "{s}/{s}.ext4", .{ cache_root, cache_key });
    const metadata_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ cache_root, cache_key });
    const temp_dir_root = try std.fmt.allocPrint(allocator, "{s}/tmp", .{cache_root});
    try ensureDirPath(init.io, temp_dir_root);
    const temp_id = Io.Clock.real.now(init.io).nanoseconds;
    var temp_nonce_bytes: [8]u8 = undefined;
    init.io.random(&temp_nonce_bytes);
    const temp_nonce = std.mem.readInt(u64, &temp_nonce_bytes, .little);
    const temp_rootfs_path = try std.fmt.allocPrint(allocator, "{s}/.{s}.{d}.{x}.ext4.tmp", .{ cache_root, cache_key, temp_id, temp_nonce });
    const temp_metadata_path = try std.fmt.allocPrint(allocator, "{s}/.{s}.{d}.{x}.json.tmp", .{ cache_root, cache_key, temp_id, temp_nonce });
    defer Io.Dir.cwd().deleteFile(init.io, temp_rootfs_path) catch {};
    defer Io.Dir.cwd().deleteFile(init.io, temp_metadata_path) catch {};

    std.log.debug("spore {s}: building cached rootfs for {s}", .{ command_name, resolved.ref });
    _ = rootfs_mod.build(init, allocator, .{
        .ref = resolved.ref,
        .output = temp_rootfs_path,
        .metadata = temp_metadata_path,
        .platform = direct_image_platform,
        .metadata_rootfs_path = rootfs_path,
        .temp_dir_root = temp_dir_root,
    }) catch |err| {
        failRunSetup("spore {s}: image rootfs build failed for {s}: {s}", .{ command_name, resolved.ref, @errorName(err) });
    };
    try Io.Dir.renameAbsolute(temp_rootfs_path, rootfs_path, init.io);
    try Io.Dir.renameAbsolute(temp_metadata_path, metadata_path, init.io);

    std.log.debug("spore {s}: cached rootfs {s}", .{ command_name, rootfs_path });
    return rootfs_path;
}

fn ensureDirPath(io: Io, path: []const u8) !void {
    if (!Io.Dir.path.isAbsolute(path)) {
        try Io.Dir.cwd().createDirPath(io, path);
        return;
    }
    var existing = Io.Dir.openDirAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (std.fs.path.dirname(path)) |parent| {
                if (parent.len > 0 and !std.mem.eql(u8, parent, path)) try ensureDirPath(io, parent);
            }
            Io.Dir.createDirAbsolute(io, path, .default_dir) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => {},
                else => |e| return e,
            };
            return;
        },
        else => |e| return e,
    };
    existing.close(io);
}

pub fn rootfsCacheRootPath(init: std.process.Init, allocator: std.mem.Allocator, command_name: []const u8) ![]const u8 {
    return local_paths.rootfsCacheRootPath(allocator, init.environ_map) catch |err| switch (err) {
        error.MissingHome => failRunSetup(
            "spore {s}: cannot resolve rootfs cache directory; set {s} or HOME",
            .{ command_name, local_paths.rootfs_cache_env },
        ),
        else => |e| return e,
    };
}

pub fn openVerifiedRootfs(init: std.process.Init, allocator: std.mem.Allocator, rootfs: spore.Rootfs, command_name: []const u8) !std.c.fd_t {
    const cache_root = try rootfsCacheRootPath(init, allocator, command_name);
    return openVerifiedRootfsFromCache(init.io, allocator, cache_root, rootfs);
}

fn openVerifiedRootfsFromCache(io: Io, allocator: std.mem.Allocator, cache_root: []const u8, rootfs: spore.Rootfs) !std.c.fd_t {
    const path = try digestRootfsPath(allocator, cache_root, rootfs.artifact.digest);
    if (!try regularFileNoSymlink(io, path)) return error.RootFSDigestCacheMiss;
    const pathz = try allocator.dupeZ(u8, path);
    const fd = std.c.open(pathz, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return error.RootFSDigestCacheMiss;
    errdefer _ = std.c.close(fd);
    if (!try fdIsRegularFile(io, fd)) return error.RootFSDigestCacheMiss;

    const actual = try hashFd(io, allocator, fd);
    if (actual.size != rootfs.artifact.size) return error.RootFSDigestMismatch;
    if (!std.mem.eql(u8, actual.digest, rootfs.artifact.digest)) return error.RootFSDigestMismatch;
    if (std.c.lseek(fd, 0, std.c.SEEK.SET) < 0) return error.RootFSOpenFailed;
    return fd;
}

fn cacheRootfsByDigest(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    rootfs_path: []const u8,
) !spore.RootfsArtifactRef {
    return cacheRootfsByDigestPath(init.io, allocator, cache_root, rootfs_path);
}

fn cacheRootfsByDigestPath(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    rootfs_path: []const u8,
) !spore.RootfsArtifactRef {
    const source = try hashPath(io, allocator, rootfs_path);
    const digest_path = try digestRootfsPath(allocator, cache_root, source.digest);
    const digest_dir = std.fs.path.dirname(digest_path) orelse return error.RootFSOpenFailed;
    try ensureDirPath(io, digest_dir);

    if (try pathExistsNoSymlink(io, digest_path)) {
        if (!try regularFileNoSymlink(io, digest_path)) return error.RootFSDigestMismatch;
        try chmodRootfsReadOnly(allocator, digest_path);
    } else {
        try copyRootfsIntoDigestCache(io, allocator, rootfs_path, digest_path);
    }
    const cached = try hashPath(io, allocator, digest_path);
    if (cached.size != source.size or !std.mem.eql(u8, cached.digest, source.digest)) return error.RootFSDigestMismatch;

    return .{
        .digest = source.digest,
        .size = source.size,
    };
}

fn regularFileNoSymlink(io: Io, path: []const u8) !bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return false,
        else => |e| return e,
    };
    return stat.kind == .file;
}

fn pathExistsNoSymlink(io: Io, path: []const u8) !bool {
    _ = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return false,
        else => |e| return e,
    };
    return true;
}

const RootfsHash = struct {
    digest: []const u8,
    size: u64,
};

fn hashPath(io: Io, allocator: std.mem.Allocator, path: []const u8) !RootfsHash {
    const pathz = try allocator.dupeZ(u8, path);
    const fd = std.c.open(pathz, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return error.RootFSOpenFailed;
    defer _ = std.c.close(fd);
    return hashFd(io, allocator, fd);
}

fn hashFd(io: Io, allocator: std.mem.Allocator, fd: std.c.fd_t) !RootfsHash {
    if (!try fdIsRegularFile(io, fd)) return error.RootFSOpenFailed;
    if (std.c.lseek(fd, 0, std.c.SEEK.SET) < 0) return error.RootFSOpenFailed;
    var h = Blake3.init(.{});
    var size: u64 = 0;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) return error.RootFSOpenFailed;
        if (n == 0) break;
        const read_len: usize = @intCast(n);
        h.update(buf[0..read_len]);
        size += @intCast(read_len);
    }
    var digest: [Blake3.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const digest_text = try std.fmt.allocPrint(allocator, "{s}{s}", .{ spore.rootfs_digest_prefix, &hex });
    return .{ .digest = digest_text, .size = size };
}

fn fdIsRegularFile(io: Io, fd: std.c.fd_t) !bool {
    const file = Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    const stat = file.stat(io) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.Streaming => return false,
        else => |e| return e,
    };
    return stat.kind == .file;
}

fn digestRootfsPath(allocator: std.mem.Allocator, cache_root: []const u8, digest: []const u8) ![]const u8 {
    try spore.validateRootfsDigest(digest);
    const hex = digest[spore.rootfs_digest_prefix.len..];
    return std.fs.path.join(allocator, &.{ cache_root, "by-digest", "blake3", try std.fmt.allocPrint(allocator, "{s}.ext4", .{hex}) });
}

fn chmodRootfsReadOnly(allocator: std.mem.Allocator, path: []const u8) !void {
    const pathz = try allocator.dupeZ(u8, path);
    if (std.c.chmod(pathz, 0o444) != 0) return error.RootFSOpenFailed;
}

fn copyRootfsIntoDigestCache(io: Io, allocator: std.mem.Allocator, source_path: []const u8, digest_path: []const u8) !void {
    const source_z = try allocator.dupeZ(u8, source_path);
    const dest_z = try allocator.dupeZ(u8, digest_path);
    if (std.c.link(source_z, dest_z) == 0) {
        if (std.c.chmod(dest_z, 0o444) != 0) return error.RootFSOpenFailed;
        return;
    }

    var temp_nonce_bytes: [8]u8 = undefined;
    io.random(&temp_nonce_bytes);
    const temp_nonce = std.mem.readInt(u64, &temp_nonce_bytes, .little);
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.{x}.tmp", .{ digest_path, temp_nonce });
    defer Io.Dir.cwd().deleteFile(io, temp_path) catch {};
    const temp_z = try allocator.dupeZ(u8, temp_path);
    const source_fd = std.c.open(source_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (source_fd < 0) return error.RootFSOpenFailed;
    defer _ = std.c.close(source_fd);
    const dest_fd = std.c.open(temp_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(c_uint, 0o444));
    if (dest_fd < 0) return error.RootFSOpenFailed;
    defer _ = std.c.close(dest_fd);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(source_fd, &buf, buf.len);
        if (n < 0) return error.RootFSOpenFailed;
        if (n == 0) break;
        var done: usize = 0;
        const read_len: usize = @intCast(n);
        while (done < read_len) {
            const written = std.c.write(dest_fd, buf[done..].ptr, read_len - done);
            if (written <= 0) return error.RootFSOpenFailed;
            done += @intCast(written);
        }
    }
    if (std.c.fchmod(dest_fd, 0o444) != 0) return error.RootFSOpenFailed;
    try Io.Dir.renameAbsolute(temp_path, digest_path, io);
}

fn cachedRootfsMetadataMatches(io: Io, allocator: std.mem.Allocator, metadata_path: []const u8, resolved: rootfs_mod.ResolvedImage) !bool {
    const metadata = Io.Dir.cwd().readFileAlloc(io, metadata_path, allocator, .limited(max_rootfs_metadata_bytes)) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.StreamTooLong => return false,
        else => |e| return e,
    };
    defer allocator.free(metadata);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, metadata, .{}) catch return false;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    if (!jsonStringEquals(object.get("builder_version"), rootfs_mod.builder_version)) return false;
    if (!jsonStringEquals(object.get("resolved_image_ref"), resolved.ref)) return false;
    if (!jsonStringEquals(object.get("image_manifest_digest"), resolved.manifest_digest)) return false;
    const platform_value = object.get("platform") orelse return false;
    const platform_object = switch (platform_value) {
        .object => |platform_object| platform_object,
        else => return false,
    };
    return jsonStringEquals(platform_object.get("os"), resolved.platform.os) and
        jsonStringEquals(platform_object.get("arch"), resolved.platform.arch);
}

fn jsonStringEquals(value: ?std.json.Value, expected: []const u8) bool {
    const actual = switch (value orelse return false) {
        .string => |string| string,
        else => return false,
    };
    return std.mem.eql(u8, actual, expected);
}

pub fn resolveDefaultKernelPath(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    if (init.environ_map.get("SPOREVM_KERNEL_IMAGE")) |path| {
        if (!try readablePath(init.io, path)) {
            failRunSetup("spore run: SPOREVM_KERNEL_IMAGE not found: {s}", .{path});
        }
        return path;
    }

    return resolveManagedRunKernelPath(init, allocator) catch |err| {
        failRunSetup(
            "spore run: managed run kernel resolution failed: {s}; pass --kernel or set SPOREVM_KERNEL_IMAGE",
            .{@errorName(err)},
        );
    };
}

pub fn resolveDefaultInitrdPath(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    if (init.environ_map.get("SPOREVM_RUN_INITRD")) |path| {
        if (!try readablePath(init.io, path)) {
            failRunSetup("spore run: SPOREVM_RUN_INITRD not found: {s}", .{path});
        }
        return path;
    }

    const prefix = try installPrefixPath(init, allocator);
    const path = try defaultInitrdPathFromPrefix(allocator, prefix);
    if (!try readablePath(init.io, path)) {
        failRunSetup(
            "spore run: default initrd not found at {s}; run 'mise run build', pass --initrd, or set SPOREVM_RUN_INITRD",
            .{path},
        );
    }
    return path;
}

fn resolveManagedRunKernelPath(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    const opts = managedKernelOptions(init);
    const asset = try managedRunKernelAssetName(allocator, opts.linux_version);
    const cache_root = local_paths.kernelCacheRootPath(allocator, init.environ_map) catch |err| switch (err) {
        error.MissingHome => failRunSetup(
            "spore run: cannot resolve kernel cache directory; set {s} or HOME",
            .{local_paths.kernel_cache_env},
        ),
        else => |e| return e,
    };
    const repo_cache = try managedKernelRepositoryCacheName(allocator, opts.repository);
    const dest_dir = try std.fs.path.join(allocator, &.{ cache_root, repo_cache, opts.release });
    const dest = try std.fs.path.join(allocator, &.{ dest_dir, asset });
    const sha_dest = try std.fmt.allocPrint(allocator, "{s}.sha256", .{dest});

    if (try verifiedManagedKernelPath(init.io, allocator, dest, sha_dest)) {
        return dest;
    }

    try ensureDirPath(init.io, dest_dir);
    const temp_dir_root = try std.fs.path.join(allocator, &.{ dest_dir, "download" });
    try ensureDirPath(init.io, temp_dir_root);

    var nonce_bytes: [8]u8 = undefined;
    init.io.random(&nonce_bytes);
    const nonce = std.mem.readInt(u64, &nonce_bytes, .little);
    const temp_image = try std.fmt.allocPrint(allocator, "{s}/{s}.{x}.tmp", .{ temp_dir_root, asset, nonce });
    const temp_sha = try std.fmt.allocPrint(allocator, "{s}.sha256", .{temp_image});
    defer Io.Dir.cwd().deleteFile(init.io, temp_image) catch {};
    defer Io.Dir.cwd().deleteFile(init.io, temp_sha) catch {};

    const message = try std.fmt.allocPrint(allocator, "spore run: downloading managed kernel {s}@{s}:{s}\n", .{ opts.repository, opts.release, asset });
    try writeSetupStderr(init, message);

    var client: std.http.Client = .{ .allocator = allocator, .io = init.io };
    defer client.deinit();
    try fetchManagedKernelAsset(allocator, init.io, &client, opts.repository, opts.release, asset, temp_image);
    const sha_asset = try std.fmt.allocPrint(allocator, "{s}.sha256", .{asset});
    try fetchManagedKernelAsset(allocator, init.io, &client, opts.repository, opts.release, sha_asset, temp_sha);
    if (!try verifiedManagedKernelPath(init.io, allocator, temp_image, temp_sha)) return error.ManagedKernelChecksumMismatch;

    try Io.Dir.renameAbsolute(temp_image, dest, init.io);
    try Io.Dir.renameAbsolute(temp_sha, sha_dest, init.io);
    chmodFileReadOnly(allocator, dest) catch {};
    chmodFileReadOnly(allocator, sha_dest) catch {};
    return dest;
}

const ManagedKernelOptions = struct {
    repository: []const u8,
    release: []const u8,
    linux_version: []const u8,
};

fn managedKernelOptions(init: std.process.Init) ManagedKernelOptions {
    return .{
        .repository = init.environ_map.get("SPOREVM_KERNEL_REPOSITORY") orelse default_kernel_repository,
        .release = init.environ_map.get("SPOREVM_KERNEL_RELEASE") orelse default_kernel_release,
        .linux_version = init.environ_map.get("SPOREVM_KERNEL_VERSION") orelse default_kernel_version,
    };
}

fn managedRunKernelAssetName(allocator: std.mem.Allocator, linux_version: []const u8) ![]const u8 {
    try validateManagedKernelVersion(linux_version);
    return std.fmt.allocPrint(allocator, "sporevm-run-arm64-linux-{s}-Image", .{linux_version});
}

fn validateManagedKernelVersion(version: []const u8) !void {
    if (version.len == 0) return error.BadManagedKernelVersion;
    for (version) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_')) return error.BadManagedKernelVersion;
    }
}

fn managedKernelRepositoryCacheName(allocator: std.mem.Allocator, repository: []const u8) ![]const u8 {
    try validateManagedKernelRepository(repository);
    const cache = try allocator.dupe(u8, repository);
    std.mem.replaceScalar(u8, cache, '/', '-');
    return cache;
}

fn validateManagedKernelRepository(repository: []const u8) !void {
    if (repository.len == 0) return error.BadManagedKernelRepository;
    var slash_count: u8 = 0;
    var segments = std.mem.splitScalar(u8, repository, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.BadManagedKernelRepository;
    }
    for (repository) |c| {
        if (c == '/') {
            slash_count += 1;
        } else if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_')) {
            return error.BadManagedKernelRepository;
        }
    }
    if (slash_count != 1) return error.BadManagedKernelRepository;
}

fn verifiedManagedKernelPath(io: Io, allocator: std.mem.Allocator, image_path: []const u8, sha_path: []const u8) !bool {
    if (!try regularFileNoSymlink(io, image_path)) return false;
    if (!try regularFileNoSymlink(io, sha_path)) return false;
    const expected = readExpectedSha256(io, allocator, sha_path) catch |err| switch (err) {
        error.BadManagedKernelChecksum => return false,
        else => |e| return e,
    };
    defer allocator.free(expected);
    const actual = try sha256FileHex(io, image_path);
    return std.ascii.eqlIgnoreCase(expected, &actual);
}

fn readExpectedSha256(io: Io, allocator: std.mem.Allocator, sha_path: []const u8) ![]const u8 {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, sha_path, allocator, .limited(4096));
    defer allocator.free(bytes);
    var fields = std.mem.tokenizeAny(u8, bytes, " \t\r\n");
    const first = fields.next() orelse return error.BadManagedKernelChecksum;
    if (!isSha256Hex(first)) return error.BadManagedKernelChecksum;
    return allocator.dupe(u8, first);
}

fn isSha256Hex(value: []const u8) bool {
    if (value.len != Sha256.digest_length * 2) return false;
    for (value) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn sha256FileHex(io: Io, path: []const u8) ![Sha256.digest_length * 2]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader_buf: [64 * 1024]u8 = undefined;
    var reader: Io.File.Reader = .initStreaming(file, io, &reader_buf);
    var h = Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try reader.interface.readSliceShort(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var out: [Sha256.digest_length]u8 = undefined;
    h.final(&out);
    return std.fmt.bytesToHex(out, .lower);
}

fn fetchManagedKernelAsset(
    allocator: std.mem.Allocator,
    io: Io,
    client: *std.http.Client,
    repository: []const u8,
    release: []const u8,
    asset: []const u8,
    output_path: []const u8,
) !void {
    try validateManagedKernelRepository(repository);
    try validateManagedKernelVersion(release);
    try validateManagedKernelAsset(asset);
    const url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/releases/download/{s}/{s}", .{ repository, release, asset });
    var attempt: u8 = 0;
    while (attempt < managed_kernel_download_attempts) : (attempt += 1) {
        Io.Dir.cwd().deleteFile(io, output_path) catch {};
        httpGetToFile(io, client, url, output_path, max_kernel_asset_size) catch |err| {
            if (attempt + 1 == managed_kernel_download_attempts) return err;
            continue;
        };
        return;
    }
    unreachable;
}

fn validateManagedKernelAsset(asset: []const u8) !void {
    if (asset.len == 0) return error.BadManagedKernelAsset;
    for (asset) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_')) return error.BadManagedKernelAsset;
    }
}

fn httpGetToFile(
    io: Io,
    client: *std.http.Client,
    url: []const u8,
    output_path: []const u8,
    max_body_bytes: u64,
) !void {
    var file = try Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var file_writer: Io.File.Writer = .initStreaming(file, io, &buffer);
    try httpGetToWriter(client, url, &file_writer.interface, max_body_bytes);
    try file_writer.interface.flush();
}

fn httpGetToWriter(client: *std.http.Client, url: []const u8, writer: *Io.Writer, max_body_bytes: u64) !void {
    const uri = try std.Uri.parse(url);
    const accept_header = std.http.Header{ .name = "accept", .value = "application/octet-stream" };
    var req = try client.request(.GET, uri, .{
        .extra_headers = &.{accept_header},
    });
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) return error.ManagedKernelHTTPStatus;

    var transfer_buffer: [64 * 1024]u8 = undefined;
    var body = response.reader(&transfer_buffer);
    var copied: u64 = 0;
    var copy_buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = body.readSliceShort(&copy_buffer) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse err,
            else => |e| return e,
        };
        if (n == 0) return;
        if (n > max_body_bytes - copied) return error.ManagedKernelBodyTooLarge;
        copied += @intCast(n);
        try writer.writeAll(copy_buffer[0..n]);
    }
}

fn chmodFileReadOnly(allocator: std.mem.Allocator, path: []const u8) !void {
    const pathz = try allocator.dupeZ(u8, path);
    defer allocator.free(pathz);
    if (std.c.chmod(pathz, 0o444) != 0) return error.ChmodFailed;
}

fn defaultInitrdPathFromPrefix(allocator: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ prefix, "share", "sporevm", default_run_initrd_name });
}

fn installPrefixPath(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    const exe_dir = try std.process.executableDirPathAlloc(init.io, allocator);
    return std.fs.path.dirname(exe_dir) orelse {
        failRunSetup("spore run: cannot resolve install prefix from executable directory {s}", .{exe_dir});
    };
}

fn readablePath(io: Io, path: []const u8) !bool {
    return accessPath(io, path, .{ .read = true });
}

fn executablePath(io: Io, path: []const u8) !bool {
    return accessPath(io, path, .{ .execute = true });
}

fn accessPath(io: Io, path: []const u8, options: Io.Dir.AccessOptions) !bool {
    if (Io.Dir.path.isAbsolute(path)) {
        Io.Dir.accessAbsolute(io, path, options) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return false,
            else => |e| return e,
        };
        return true;
    }
    Io.Dir.cwd().access(io, path, options) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return false,
        else => |e| return e,
    };
    return true;
}

fn writeSetupStderr(_: std.process.Init, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(2, remaining.ptr, remaining.len);
        if (n <= 0) return error.StderrWriteFailed;
        remaining = remaining[@intCast(n)..];
    }
}

fn failRunSetup(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(2);
}

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, opts: Options) !Result {
    if (opts.vcpus != 1) return error.UnsupportedVcpuCount;

    const backend = try resolveBackend(opts.backend);
    const resuming = opts.resume_dir != null;
    const kernel = if (resuming) "" else try std.Io.Dir.cwd().readFileAlloc(init.io, opts.kernel_path, allocator, .limited(max_file_size));
    const initrd: ?[]const u8 = if (resuming) null else try std.Io.Dir.cwd().readFileAlloc(init.io, opts.initrd_path, allocator, .limited(max_file_size));
    const rootfs_fd = try openRootfsForRun(init, allocator, opts.rootfs_path, opts.rootfs);
    defer {
        if (rootfs_fd) |fd| _ = std.c.close(fd);
    }
    const boot_args = if (resuming) "" else try cmdline(allocator, opts.guest_port, opts.rootfs_path != null);
    const request = try execRequestForRun(init, allocator, opts);
    var stream = try vsock.HostStream.init(opts.guest_port, request);
    if (opts.stream_output) stream.setOutputSink(null, runOutputSink);
    var capture_request = capture.Request{};
    var signal_registration: ?capture.SignalRegistration = null;
    defer if (signal_registration) |*registration| registration.deinit();
    const signal_capture = opts.capture_path != null and captureTriggerSignal(opts.capture_trigger) != null;
    const exit_capture = opts.capture_path != null and captureTriggerIsExit(opts.capture_trigger);
    const capture_request_ptr: ?*capture.Request = if (signal_capture) &capture_request else null;
    if (capture_request_ptr) |request_capture| {
        signal_registration = capture.SignalRegistration.install(captureTriggerSignal(opts.capture_trigger).?, request_capture);
    }

    const cause = (switch (backend) {
        .auto => unreachable,
        .hvf => blk: {
            if (comptime !(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) return error.UnsupportedBackend;
            break :blk hvf.vm.run(allocator, .{
                .kernel = kernel,
                .ram_size = opts.memory_mib * 1024 * 1024,
                .cmdline = boot_args,
                .initrd = initrd,
                .console_sink = consoleSink,
                .disk_fd = rootfs_fd,
                .rootfs = opts.rootfs,
                .resume_dir = opts.resume_dir,
                .exec_probe = &stream,
                .exec_probe_timeout_ms = opts.timeout_ms,
                .snapshot_dir = opts.capture_path,
                .snapshot_on_probe_complete = exit_capture,
                .capture_request = capture_request_ptr,
                .continue_after_capture = opts.continue_after_capture,
            });
        },
        .kvm => blk: {
            if (comptime !(builtin.os.tag == .linux and builtin.cpu.arch == .aarch64)) return error.UnsupportedBackend;
            break :blk kvm.vm.run(allocator, .{
                .kernel = kernel,
                .ram_size = opts.memory_mib * 1024 * 1024,
                .cmdline = boot_args,
                .initrd = initrd,
                .console_sink = consoleSink,
                .disk_fd = rootfs_fd,
                .rootfs = opts.rootfs,
                .resume_dir = opts.resume_dir,
                .exec_probe = &stream,
                .exec_probe_timeout_ms = opts.timeout_ms,
                .snapshot_dir = opts.capture_path,
                .snapshot_on_probe_complete = exit_capture,
                .capture_request = capture_request_ptr,
                .continue_after_capture = opts.continue_after_capture,
            });
        },
    }) catch |err| {
        if (signal_capture and capture_request.isCompleted() and isCaptureAborted(err)) {
            return resultFromAbortedSignalCapture(backend, opts, &stream);
        }
        return err;
    };
    const signal_capture_observed = signal_capture and capture_request.isCompleted();
    return switch (cause) {
        .probe_complete => resultFromStream(backend, opts, &stream, signal_capture_observed),
        .snapshotted => if (exit_capture)
            resultFromExitCapture(backend, opts, &stream)
        else
            resultFromSignalCapture(backend, opts, &stream),
        else => error.ProbeDidNotComplete,
    };
}

pub fn executeMonitor(init: std.process.Init, allocator: std.mem.Allocator, opts: Options, control: vsock.Control) !MonitorResult {
    if (opts.vcpus != 1) return error.UnsupportedVcpuCount;

    const backend = try resolveBackend(opts.backend);
    const kernel = try std.Io.Dir.cwd().readFileAlloc(init.io, opts.kernel_path, allocator, .limited(max_file_size));
    const initrd = try std.Io.Dir.cwd().readFileAlloc(init.io, opts.initrd_path, allocator, .limited(max_file_size));
    const rootfs_fd = try openRootfsForRun(init, allocator, opts.rootfs_path, opts.rootfs);
    defer {
        if (rootfs_fd) |fd| _ = std.c.close(fd);
    }
    const boot_args = try cmdline(allocator, opts.guest_port, opts.rootfs_path != null);

    const cause = switch (backend) {
        .auto => unreachable,
        .hvf => blk: {
            if (comptime !(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) return error.UnsupportedBackend;
            break :blk try hvf.vm.run(allocator, .{
                .kernel = kernel,
                .ram_size = opts.memory_mib * 1024 * 1024,
                .cmdline = boot_args,
                .initrd = initrd,
                .console_sink = consoleSink,
                .disk_fd = rootfs_fd,
                .rootfs = opts.rootfs,
                .resume_dir = opts.resume_dir,
                .ram_restore_mode = .eager_chunks,
                .exec_control = control,
            });
        },
        .kvm => {
            if (comptime !(builtin.os.tag == .linux and builtin.cpu.arch == .aarch64)) return error.UnsupportedBackend;
            return error.UnsupportedMonitorBackend;
        },
    };
    return switch (cause) {
        .monitor_stopped => .{ .backend = backend, .exit = .stopped },
        .snapshotted => .{ .backend = backend, .exit = .snapshotted },
        else => error.MonitorDidNotStopCleanly,
    };
}

fn openRootfsDisk(allocator: std.mem.Allocator, rootfs_path: ?[]const u8) !?std.c.fd_t {
    const path = rootfs_path orelse return null;
    const pathz = try allocator.dupeZ(u8, path);
    const fd = std.c.open(pathz, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return error.RootFSOpenFailed;
    return fd;
}

fn openRootfsForRun(init: std.process.Init, allocator: std.mem.Allocator, rootfs_path: ?[]const u8, rootfs: ?spore.Rootfs) !?std.c.fd_t {
    if (rootfs) |artifact| return try openVerifiedRootfs(init, allocator, artifact, "run");
    return openRootfsDisk(allocator, rootfs_path);
}

pub var console_fd: std.c.fd_t = -1;

fn runOutputSink(_: ?*anyopaque, output: vsock.HostStreamOutput, bytes: []const u8) void {
    const fd: std.c.fd_t = switch (output) {
        .stdout => 1,
        .stderr => 2,
    };
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(fd, remaining.ptr, remaining.len);
        if (n <= 0) return;
        remaining = remaining[@intCast(n)..];
    }
}

pub fn consoleSink(bytes: []const u8) void {
    if (console_fd < 0) return;
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(console_fd, remaining.ptr, remaining.len);
        if (n <= 0) return;
        remaining = remaining[@intCast(n)..];
    }
}

pub fn openConsoleLog(path: ?[]const u8) !void {
    if (path == null) return;
    const pathz = try std.heap.page_allocator.dupeZ(u8, path.?);
    defer std.heap.page_allocator.free(pathz);
    const fd = std.c.open(pathz, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
    if (fd < 0) return error.ConsoleLogOpenFailed;
    console_fd = fd;
}

pub fn closeConsoleLog() void {
    if (console_fd >= 0) {
        _ = std.c.close(console_fd);
        console_fd = -1;
    }
}

pub fn execRequest(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    return execRequestWithSession(allocator, argv, "default");
}

fn execRequestForRun(init: std.process.Init, allocator: std.mem.Allocator, opts: Options) ![]const u8 {
    if (opts.resume_dir == null) return execRequest(allocator, opts.command);

    const now = Io.Clock.real.now(init.io).nanoseconds;
    var nonce_bytes: [8]u8 = undefined;
    init.io.random(&nonce_bytes);
    const nonce = std.mem.readInt(u64, &nonce_bytes, .little);
    const session_id = try std.fmt.allocPrint(allocator, "run-{x}-{x}", .{ now, nonce });
    return execRequestWithSession(allocator, opts.command, session_id);
}

pub fn execRequestWithSession(allocator: std.mem.Allocator, argv: []const []const u8, session_id: []const u8) ![]const u8 {
    try validateGuestArgv(argv);
    const payload = struct {
        type: []const u8 = "start",
        session_id: []const u8,
        argv: []const []const u8,
        closed_env: bool = true,
    }{ .session_id = session_id, .argv = argv };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

pub fn generationRequest(allocator: std.mem.Allocator, params_json: []const u8) ![]const u8 {
    const payload = struct {
        type: []const u8 = "generation",
        session_id: []const u8 = "default",
        params_json: []const u8,
    }{ .params_json = params_json };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

pub fn cmdline(allocator: std.mem.Allocator, guest_port: u32, rootfs: bool) ![]const u8 {
    return if (rootfs)
        std.fmt.allocPrint(allocator, "console=hvc0 rdinit=/init cleanroom_guest_port={d} cleanroom_guest_boot_timing=1 spore_rootfs=1", .{guest_port})
    else
        std.fmt.allocPrint(allocator, "console=hvc0 rdinit=/init cleanroom_guest_port={d} cleanroom_guest_boot_timing=1", .{guest_port});
}

fn resolveBackend(backend: Backend) !Backend {
    if (backend != .auto) return backend;
    if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) return .hvf;
    if (builtin.os.tag == .linux and builtin.cpu.arch == .aarch64) return .kvm;
    return error.UnsupportedBackend;
}

fn resultFromStream(backend: Backend, opts: Options, stream: *const vsock.HostStream, captured: bool) !Result {
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
        .vcpus = opts.vcpus,
        .memory_mib = opts.memory_mib,
        .captured = captured,
        .capture_path = if (captured) opts.capture_path else null,
    };
}

fn resultFromSignalCapture(backend: Backend, opts: Options, stream: *const vsock.HostStream) Result {
    return resultFromSignalCaptureExitCode(backend, opts, stream, 0);
}

fn resultFromAbortedSignalCapture(backend: Backend, opts: Options, stream: *const vsock.HostStream) Result {
    return resultFromSignalCaptureExitCode(backend, opts, stream, 130);
}

fn resultFromSignalCaptureExitCode(backend: Backend, opts: Options, stream: *const vsock.HostStream, exit_code: u8) Result {
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
        .vcpus = opts.vcpus,
        .memory_mib = opts.memory_mib,
        .captured = true,
        .capture_path = opts.capture_path,
    };
}

fn resultFromExitCapture(backend: Backend, opts: Options, stream: *const vsock.HostStream) !Result {
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
        .vcpus = opts.vcpus,
        .memory_mib = opts.memory_mib,
        .captured = true,
        .capture_path = opts.capture_path,
    };
}

fn captureTriggerSignal(trigger: capture.Trigger) ?capture.Signal {
    return switch (trigger) {
        .exit => null,
        .signal => |signal| signal,
    };
}

fn captureTriggerIsExit(trigger: capture.Trigger) bool {
    return switch (trigger) {
        .exit => true,
        .signal => false,
    };
}

fn isCaptureAborted(err: anyerror) bool {
    return std.mem.eql(u8, @errorName(err), "CaptureAborted");
}

fn parsePositive(comptime T: type, name: []const u8, raw: []const u8) !T {
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

fn parseGuestPort(name: []const u8, raw: []const u8) !u32 {
    const parsed = std.fmt.parseInt(u32, raw, 10) catch {
        std.debug.print("{s} must be an integer from 1 to {d}\n", .{ name, max_guest_port });
        std.process.exit(2);
    };
    if (parsed == 0 or parsed > max_guest_port) {
        std.debug.print("{s} must be an integer from 1 to {d}\n", .{ name, max_guest_port });
        std.process.exit(2);
    }
    return parsed;
}

fn validateGuestArgv(argv: []const []const u8) !void {
    if (argv.len == 0 or argv.len > max_guest_argc) return error.RunArgCountUnsupported;
    for (argv) |arg| {
        if (arg.len > max_guest_arg_len) return error.RunArgTooLong;
    }
}

fn parseSharedOption(shared: *SharedOptions, args: []const []const u8, i: *usize) !bool {
    const name = args[i.*];
    if (std.mem.eql(u8, name, "--kernel")) {
        shared.kernel_path = takeValue(args, i, name);
    } else if (std.mem.eql(u8, name, "--initrd")) {
        shared.initrd_path = takeValue(args, i, name);
    } else if (std.mem.eql(u8, name, "--memory-mib")) {
        shared.memory_mib = try parsePositive(u64, name, takeValue(args, i, name));
        shared.memory_mib_set = true;
    } else if (std.mem.eql(u8, name, "--vcpus")) {
        shared.vcpus = try parsePositive(u32, name, takeValue(args, i, name));
    } else if (std.mem.eql(u8, name, "--guest-port")) {
        shared.guest_port = try parseGuestPort(name, takeValue(args, i, name));
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
        std.debug.print("{s} requires a value\n", .{name});
        std.process.exit(2);
    }
    i.* += 1;
    return args[i.*];
}

test "run request encodes argv" {
    const request = try execRequest(std.testing.allocator, &.{ "/bin/echo", "hello world" });
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings("{\"type\":\"start\",\"session_id\":\"default\",\"argv\":[\"/bin/echo\",\"hello world\"],\"closed_env\":true}\n", request);
}

test "run request can encode explicit session id" {
    const request = try execRequestWithSession(std.testing.allocator, &.{"/bin/true"}, "lifecycle-42");
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings("{\"type\":\"start\",\"session_id\":\"lifecycle-42\",\"argv\":[\"/bin/true\"],\"closed_env\":true}\n", request);
}

test "generation request encodes params json as a string" {
    const request = try generationRequest(std.testing.allocator, "{\"parallel_index\":2,\"parallel_count\":5}");
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings("{\"type\":\"generation\",\"session_id\":\"default\",\"params_json\":\"{\\\"parallel_index\\\":2,\\\"parallel_count\\\":5}\"}\n", request);
}

test "run request rejects guest argv count overflow" {
    const argv = [_][]const u8{
        "/bin/true", "1",  "2",  "3",
        "4",         "5",  "6",  "7",
        "8",         "9",  "10", "11",
        "12",        "13", "14", "15",
        "16",
    };
    try std.testing.expectError(error.RunArgCountUnsupported, execRequest(std.testing.allocator, &argv));
}

test "run request rejects guest argv length overflow" {
    var arg = [_]u8{'a'} ** (max_guest_arg_len + 1);
    try std.testing.expectError(error.RunArgTooLong, execRequest(std.testing.allocator, &.{arg[0..]}));
}

test "run request rejects encoded line overflow" {
    var arg = [_]u8{'a'} ** 240;
    var argv: [10][]const u8 = undefined;
    for (&argv) |*slot| slot.* = arg[0..];
    try std.testing.expectError(error.RunRequestTooLarge, execRequest(std.testing.allocator, &argv));
}

test "run cli parser accepts command after separator" {
    const opts = try parseCliArgs(&.{ "--backend", "hvf", "--kernel", "Image", "--initrd", "root.cpio", "--", "/bin/true" });
    try std.testing.expectEqual(Backend.hvf, opts.backend);
    try std.testing.expectEqualStrings("Image", opts.shared.kernel_path.?);
    try std.testing.expectEqualStrings("root.cpio", opts.shared.initrd_path.?);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("/bin/true", opts.command[0]);
}

test "run cli parser allows default boot assets" {
    const opts = try parseCliArgs(&.{ "--", "/bin/writeout" });
    try std.testing.expectEqual(Backend.auto, opts.backend);
    try std.testing.expect(opts.shared.kernel_path == null);
    try std.testing.expect(opts.shared.initrd_path == null);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("/bin/writeout", opts.command[0]);
}

test "run cli parser accepts rootfs path" {
    const opts = try parseCliArgs(&.{ "--rootfs", "rootfs.ext4", "--", "/bin/echo", "hi" });
    try std.testing.expectEqualStrings("rootfs.ext4", opts.rootfs_path.?);
    try std.testing.expectEqual(@as(usize, 2), opts.command.len);
    try std.testing.expectEqualStrings("/bin/echo", opts.command[0]);
    try std.testing.expectEqualStrings("hi", opts.command[1]);
}

test "run cli parser accepts image ref" {
    const opts = try parseCliArgs(&.{ "--image", "docker.io/library/alpine:3.20", "--", "/bin/echo", "hi" });
    try std.testing.expect(opts.rootfs_path == null);
    try std.testing.expectEqualStrings("docker.io/library/alpine:3.20", opts.image_ref.?);
    try std.testing.expectEqual(@as(usize, 2), opts.command.len);
    try std.testing.expectEqualStrings("/bin/echo", opts.command[0]);
    try std.testing.expectEqualStrings("hi", opts.command[1]);
}

test "run cli parser accepts source spore" {
    const opts = try parseCliArgs(&.{ "--from", "base.spore", "--", "/bin/writeout" });
    try std.testing.expectEqualStrings("base.spore", opts.from_spore_dir.?);
    try std.testing.expect(opts.rootfs_path == null);
    try std.testing.expect(opts.image_ref == null);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("/bin/writeout", opts.command[0]);
}

test "run cli parser accepts capture flags" {
    const opts = try parseCliArgs(&.{ "--capture", "out.spore", "--capture-on", "USR1", "--continue-after-capture", "--", "/bin/sleeper" });
    try std.testing.expectEqualStrings("out.spore", opts.capture_path.?);
    try std.testing.expectEqual(capture.Signal.USR1, captureTriggerSignal(opts.capture_trigger).?);
    try std.testing.expect(opts.continue_after_capture);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("/bin/sleeper", opts.command[0]);
}

test "run cli parser defaults capture trigger to exit" {
    const opts = try parseCliArgs(&.{ "--capture", "out.spore", "--", "/bin/true" });
    try std.testing.expectEqualStrings("out.spore", opts.capture_path.?);
    try std.testing.expect(captureTriggerIsExit(opts.capture_trigger));
    try std.testing.expect(!opts.continue_after_capture);
}

test "captured run result exits zero" {
    const result = Result{
        .backend = .hvf,
        .start_ms = 1,
        .vsock_connect_ms = 2,
        .exec_response_ms = 3,
        .probe_duration_ms = 1,
        .exit_code = 0,
        .vcpus = 1,
        .memory_mib = 1024,
        .captured = true,
        .capture_path = "out.spore",
    };
    try std.testing.expectEqual(@as(u8, 0), result.processExitCode());
}

test "captured run result preserves stored exit code" {
    const result = Result{
        .backend = .hvf,
        .start_ms = 1,
        .vsock_connect_ms = 2,
        .exec_response_ms = 3,
        .probe_duration_ms = 1,
        .exit_code = 7,
        .vcpus = 1,
        .memory_mib = 1024,
        .captured = true,
        .capture_path = "out.spore",
    };
    try std.testing.expectEqual(@as(u8, 7), result.processExitCode());
}

test "run image cache key is deterministic and scoped to resolved image identity" {
    const allocator = std.testing.allocator;
    const resolved = rootfs_mod.ResolvedImage{
        .ref = "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .manifest_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = .{},
    };
    const same = try rootfs_mod.rootfsCacheKeyAlloc(allocator, resolved);
    defer allocator.free(same);
    const again = try rootfs_mod.rootfsCacheKeyAlloc(allocator, resolved);
    defer allocator.free(again);
    try std.testing.expectEqual(@as(usize, Sha256.digest_length * 2), same.len);
    try std.testing.expectEqualStrings(same, again);

    const changed_ref = try rootfs_mod.rootfsCacheKeyAlloc(allocator, .{
        .ref = "docker.io/library/alpine@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .manifest_digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .platform = .{},
    });
    defer allocator.free(changed_ref);
    try std.testing.expect(!std.mem.eql(u8, same, changed_ref));

    const changed_platform = try rootfs_mod.rootfsCacheKeyAlloc(allocator, .{
        .ref = resolved.ref,
        .manifest_digest = resolved.manifest_digest,
        .platform = .{ .os = "linux", .arch = "amd64" },
    });
    defer allocator.free(changed_platform);
    try std.testing.expect(!std.mem.eql(u8, same, changed_platform));
}

test "run image cache can identify digest-pinned refs without network" {
    const allocator = std.testing.allocator;
    const resolved = (try rootfs_mod.digestPinnedImageIdentity(
        allocator,
        "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .{},
    )).?;
    defer allocator.free(resolved.ref);

    try std.testing.expectEqualStrings(
        "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        resolved.ref,
    );
    try std.testing.expectEqualStrings(
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        resolved.manifest_digest,
    );
    try std.testing.expect((try rootfs_mod.digestPinnedImageIdentity(allocator, "docker.io/library/alpine:3.20", .{})) == null);
    try rootfs_mod.validateTaggedImageRef("docker.io/library/alpine:3.20");
    try std.testing.expectError(error.ImageRefNeedsRegistry, rootfs_mod.validateTaggedImageRef("alpine:3.20"));
}

test "run image cache metadata matches resolved image identity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-run-image-cache-metadata";
    const metadata_path = tmp ++ "/metadata.json";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);

    const resolved = rootfs_mod.ResolvedImage{
        .ref = "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .manifest_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = .{},
    };
    try std.testing.expect(!try cachedRootfsMetadataMatches(io, allocator, metadata_path, resolved));
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = metadata_path,
        .data =
        \\{
        \\  "builder_version": "sporevm-rootfs-v1",
        \\  "resolved_image_ref": "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "image_manifest_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "platform": {"os": "linux", "arch": "arm64"}
        \\}
        ,
    });
    try std.testing.expect(try cachedRootfsMetadataMatches(io, allocator, metadata_path, resolved));

    try std.testing.expect(!try cachedRootfsMetadataMatches(io, allocator, metadata_path, .{
        .ref = "docker.io/library/alpine@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .manifest_digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .platform = .{},
    }));

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = "not json" });
    try std.testing.expect(!try cachedRootfsMetadataMatches(io, allocator, metadata_path, resolved));
}

test "run image cache treats oversized metadata as a miss" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-run-image-cache-oversized-metadata";
    const metadata_path = tmp ++ "/metadata.json";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);

    const oversized = try allocator.alloc(u8, max_rootfs_metadata_bytes);
    defer allocator.free(oversized);
    @memset(oversized, ' ');
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = oversized });

    try std.testing.expect(!try cachedRootfsMetadataMatches(io, allocator, metadata_path, .{
        .ref = "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .manifest_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = .{},
    }));
}

test "run image ref cache key is deterministic and scoped to requested tag" {
    const allocator = std.testing.allocator;
    const key = try imageRefCacheKeyAlloc(allocator, "docker.io/library/alpine:3.20", .{});
    defer allocator.free(key);
    const again = try imageRefCacheKeyAlloc(allocator, "docker.io/library/alpine:3.20", .{});
    defer allocator.free(again);
    try std.testing.expectEqual(@as(usize, Sha256.digest_length * 2), key.len);
    try std.testing.expectEqualStrings(key, again);

    const changed_tag = try imageRefCacheKeyAlloc(allocator, "docker.io/library/alpine:3.21", .{});
    defer allocator.free(changed_tag);
    try std.testing.expect(!std.mem.eql(u8, key, changed_tag));

    const changed_platform = try imageRefCacheKeyAlloc(allocator, "docker.io/library/alpine:3.20", .{ .os = "linux", .arch = "amd64" });
    defer allocator.free(changed_platform);
    try std.testing.expect(!std.mem.eql(u8, key, changed_platform));
}

test "run image ref cache maps tag to verified rootfs path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-image-ref-cache-hit";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try ensureDirPath(io, cache_root);

    const resolved = rootfs_mod.ResolvedImage{
        .ref = "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .manifest_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = .{},
    };
    const cache_key = try rootfs_mod.rootfsCacheKeyAlloc(arena, resolved);
    const rootfs_path = try std.fmt.allocPrint(arena, "{s}/{s}.ext4", .{ cache_root, cache_key });
    const metadata_path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ cache_root, cache_key });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = metadata_path,
        .data =
        \\{
        \\  "builder_version": "sporevm-rootfs-v1",
        \\  "resolved_image_ref": "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "image_manifest_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "platform": {"os": "linux", "arch": "arm64"}
        \\}
        ,
    });

    try writeImageRefCacheRecord(io, arena, cache_root, "docker.io/library/alpine:3.20", resolved, "run");
    const hit = (try cachedImageRefRootfsPath(io, arena, cache_root, "docker.io/library/alpine:3.20", "run")).?;
    try std.testing.expectEqualStrings(rootfs_path, hit.path);
    try std.testing.expectEqualStrings(resolved.ref, hit.resolved.ref);
    try std.testing.expectEqualStrings(resolved.manifest_digest, hit.resolved.manifest_digest);
}

test "run image ref cache treats mismatched records and missing rootfs as misses" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-image-ref-cache-miss";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try ensureDirPath(io, cache_root);
    try ensureDirPath(io, try std.fs.path.join(arena, &.{ cache_root, "refs" }));

    const resolved = rootfs_mod.ResolvedImage{
        .ref = "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .manifest_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = .{},
    };
    const cache_key = try rootfs_mod.rootfsCacheKeyAlloc(arena, resolved);
    const record_path = try imageRefCacheRecordPath(arena, cache_root, "docker.io/library/alpine:3.20", .{});
    const bad_record = try std.fmt.allocPrint(arena,
        \\{{
        \\  "version": 1,
        \\  "requested_ref": "docker.io/library/alpine:other",
        \\  "platform": "linux/arm64",
        \\  "builder_version": "sporevm-rootfs-v1",
        \\  "resolved_image_ref": "{s}",
        \\  "image_manifest_digest": "{s}",
        \\  "rootfs_cache_key": "{s}",
        \\  "resolved_at_unix": 123
        \\}}
    , .{ resolved.ref, resolved.manifest_digest, cache_key });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = record_path, .data = bad_record });
    try std.testing.expect((try cachedImageRefRootfsPath(io, arena, cache_root, "docker.io/library/alpine:3.20", "run")) == null);

    const bad_resolved_ref_record = try std.fmt.allocPrint(arena,
        \\{{
        \\  "version": 1,
        \\  "requested_ref": "docker.io/library/alpine:3.20",
        \\  "platform": "linux/arm64",
        \\  "builder_version": "sporevm-rootfs-v1",
        \\  "resolved_image_ref": "docker.io/library/alpine:not-a-digest",
        \\  "image_manifest_digest": "{s}",
        \\  "rootfs_cache_key": "{s}",
        \\  "resolved_at_unix": 123
        \\}}
    , .{ resolved.manifest_digest, cache_key });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = record_path, .data = bad_resolved_ref_record });
    try std.testing.expect((try cachedImageRefRootfsPath(io, arena, cache_root, "docker.io/library/alpine:3.20", "run")) == null);

    try writeImageRefCacheRecord(io, arena, cache_root, "docker.io/library/alpine:3.20", resolved, "run");
    try std.testing.expect((try cachedImageRefRootfsPath(io, arena, cache_root, "docker.io/library/alpine:3.20", "run")) == null);
}

test "rootfs digest cache verifies exact bytes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-rootfs-digest-cache";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });

    const artifact = try cacheRootfsByDigestPath(io, arena, cache_root, rootfs_path);
    try std.testing.expect(std.mem.startsWith(u8, artifact.digest, spore.rootfs_digest_prefix));
    try std.testing.expectEqual(@as(u64, "rootfs bytes".len), artifact.size);

    const rootfs = spore.Rootfs{ .device = .{ .mmio_slot = 1 }, .artifact = artifact };
    const fd = try openVerifiedRootfsFromCache(io, arena, cache_root, rootfs);
    _ = std.c.close(fd);

    const digest_path = try digestRootfsPath(arena, cache_root, artifact.digest);
    const digest_z = try arena.dupeZ(u8, digest_path);
    const write_fd = std.c.open(digest_z, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (write_fd >= 0) {
        _ = std.c.close(write_fd);
        return error.TestExpectedError;
    }

    try Io.Dir.cwd().deleteFile(io, digest_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = digest_path, .data = "tampered" });
    try std.testing.expectError(error.RootFSDigestMismatch, openVerifiedRootfsFromCache(io, arena, cache_root, rootfs));
}

test "rootfs digest cache rejects unsafe existing paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-run-rootfs-digest-cache-symlink";
    const rootfs_path = tmp ++ "/source.ext4";
    const cache_root = tmp ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rootfs_path, .data = "rootfs bytes" });

    const artifact = try cacheRootfsByDigestPath(io, arena, cache_root, rootfs_path);
    const digest_path = try digestRootfsPath(arena, cache_root, artifact.digest);
    try Io.Dir.cwd().deleteFile(io, digest_path);
    const digest_z = try arena.dupeZ(u8, digest_path);
    const rootfs_z = try arena.dupeZ(u8, rootfs_path);
    if (std.c.symlink(rootfs_z, digest_z) != 0) return error.SkipZigTest;

    try std.testing.expectError(error.RootFSDigestMismatch, cacheRootfsByDigestPath(io, arena, cache_root, rootfs_path));
}

test "rootfs hashing rejects non-file descriptors" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-run-rootfs-fd-regular";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);

    const tmp_z = try allocator.dupeZ(u8, tmp);
    defer allocator.free(tmp_z);
    const fd = std.c.open(tmp_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return error.SkipZigTest;
    defer _ = std.c.close(fd);
    try std.testing.expect(!try fdIsRegularFile(io, fd));
    try std.testing.expectError(error.RootFSOpenFailed, hashFd(io, allocator, fd));
}

test "run image cache creates absolute cache directories" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = "zig-cache/test-run-image-cache-dir";
    const nested = root ++ "/a/b";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};

    const absolute_nested = try std.fs.path.resolve(allocator, &.{nested});
    defer allocator.free(absolute_nested);
    try ensureDirPath(io, absolute_nested);
    try Io.Dir.cwd().access(io, nested, .{});
}

test "run cmdline marks rootfs mode" {
    const without_rootfs = try cmdline(std.testing.allocator, 10700, false);
    defer std.testing.allocator.free(without_rootfs);
    try std.testing.expect(std.mem.indexOf(u8, without_rootfs, "spore_rootfs=1") == null);

    const with_rootfs = try cmdline(std.testing.allocator, 10700, true);
    defer std.testing.allocator.free(with_rootfs);
    try std.testing.expect(std.mem.indexOf(u8, with_rootfs, "spore_rootfs=1") != null);
}

test "run default asset paths derive from install prefix" {
    const allocator = std.testing.allocator;
    const initrd = try defaultInitrdPathFromPrefix(allocator, "/repo/zig-out");
    defer allocator.free(initrd);
    try std.testing.expectEqualStrings("/repo/zig-out/share/sporevm/minimal-exec-initrd.cpio", initrd);
}

test "managed run kernel asset names validate input" {
    const allocator = std.testing.allocator;
    const asset = try managedRunKernelAssetName(allocator, "6.1.155");
    defer allocator.free(asset);
    try std.testing.expectEqualStrings("sporevm-run-arm64-linux-6.1.155-Image", asset);

    try std.testing.expectError(error.BadManagedKernelVersion, managedRunKernelAssetName(allocator, "../bad"));
}

test "managed kernel repository cache name validates owner and repo" {
    const allocator = std.testing.allocator;
    const cache = try managedKernelRepositoryCacheName(allocator, "buildkite/cleanroom-kernels");
    defer allocator.free(cache);
    try std.testing.expectEqualStrings("buildkite-cleanroom-kernels", cache);

    try std.testing.expectError(error.BadManagedKernelRepository, managedKernelRepositoryCacheName(allocator, "buildkite"));
    try std.testing.expectError(error.BadManagedKernelRepository, managedKernelRepositoryCacheName(allocator, "../cleanroom-kernels"));
}

test "managed kernel checksum parser reads sha256 sidecar" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-run-kernel-checksum";
    Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try ensureDirPath(io, tmp);
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};

    const sha_path = tmp ++ "/Image.sha256";
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = sha_path,
        .data = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  Image\n",
    });

    const expected = try readExpectedSha256(io, allocator, sha_path);
    defer allocator.free(expected);
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", expected);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = sha_path, .data = "not-a-sha\n" });
    try std.testing.expectError(error.BadManagedKernelChecksum, readExpectedSha256(io, allocator, sha_path));
}
