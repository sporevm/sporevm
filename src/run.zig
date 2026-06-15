//! One-shot VM boot/exec support for `spore run` and minimal benchmark tools.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const hvf = @import("hvf/hvf.zig");
const kvm = if (builtin.os.tag == .linux and builtin.cpu.arch == .aarch64)
    @import("kvm/kvm.zig")
else
    struct {};
const rootfs_mod = @import("rootfs.zig");
const vsock = @import("virtio/vsock.zig");

const default_command = [_][]const u8{"/bin/true"};
const max_file_size = 256 * 1024 * 1024;
const max_guest_argc = 16;
const max_guest_arg_len = 255;
const max_guest_request_len = 2047;
const max_guest_port = 65535;
const default_run_initrd_name = "minimal-exec-initrd.cpio";
const rootfs_cache_env = "SPOREVM_ROOTFS_CACHE_DIR";
const direct_image_platform = rootfs_mod.Platform{};
const max_rootfs_metadata_bytes = 1024 * 1024;

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
    command: []const []const u8,
    memory_mib: u64 = 1024,
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    console_log_path: ?[]const u8 = null,
    stream_output: bool = true,
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

    pub fn processExitCode(self: Result) u8 {
        std.debug.assert(self.exit_code >= 0 and self.exit_code <= 255);
        return @intCast(self.exit_code);
    }
};

const SharedOptions = struct {
    kernel_path: ?[]const u8 = null,
    initrd_path: ?[]const u8 = null,
    memory_mib: u64 = 1024,
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    console_log_path: ?[]const u8 = null,

    fn complete(self: SharedOptions, backend: Backend, command: []const []const u8, stream_output: bool) Options {
        return self.completeWithAssets(backend, self.kernel_path.?, self.initrd_path.?, null, command, stream_output);
    }

    fn completeWithAssets(
        self: SharedOptions,
        backend: Backend,
        kernel_path: []const u8,
        initrd_path: []const u8,
        rootfs_path: ?[]const u8,
        command: []const []const u8,
        stream_output: bool,
    ) Options {
        return .{
            .backend = backend,
            .kernel_path = kernel_path,
            .initrd_path = initrd_path,
            .rootfs_path = rootfs_path,
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
    rootfs_path: ?[]const u8 = null,
    image_ref: ?[]const u8 = null,
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
    \\  --rootfs rootfs.ext4    Attach rootfs image read-only as virtio-blk
    \\  --image REF             Build or reuse cached OCI rootfs, then run from it
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

    const result = try execute(init, arena, opts);
    const code = result.processExitCode();
    if (code != 0) std.process.exit(code);
}

pub fn parseCliArgs(args: []const []const u8) !CliOptions {
    var backend: Backend = .auto;
    var shared = SharedOptions{};
    var rootfs_path: ?[]const u8 = null;
    var image_ref: ?[]const u8 = null;
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

    return .{
        .backend = backend,
        .shared = shared,
        .rootfs_path = rootfs_path,
        .image_ref = image_ref,
        .command = argv,
    };
}

fn resolveCliOptions(init: std.process.Init, allocator: std.mem.Allocator, parsed: CliOptions) !Options {
    const rootfs_path = if (parsed.image_ref) |image_ref|
        try resolveImageRootfs(init, allocator, image_ref)
    else
        parsed.rootfs_path;
    if (rootfs_path) |path| {
        if (!try readablePath(init.io, path)) {
            failRunSetup("spore run: rootfs not found: {s}", .{path});
        }
    }
    const kernel_path = parsed.shared.kernel_path orelse try resolveDefaultKernelPath(init, allocator);
    const initrd_path = parsed.shared.initrd_path orelse try resolveDefaultInitrdPath(init, allocator);
    return parsed.shared.completeWithAssets(parsed.backend, kernel_path, initrd_path, rootfs_path, parsed.command, true);
}

fn resolveImageRootfs(init: std.process.Init, allocator: std.mem.Allocator, image_ref: []const u8) ![]const u8 {
    const cache_root = try rootfsCacheRootPath(init, allocator);
    try ensureDirPath(init.io, cache_root);

    if (try rootfs_mod.digestPinnedImageIdentity(allocator, image_ref, direct_image_platform)) |digest_pinned| {
        if (try cachedImageRootfsPath(init, allocator, cache_root, digest_pinned)) |path| return path;
    }

    const resolved = rootfs_mod.resolveImageRef(init, allocator, image_ref, direct_image_platform) catch |err| {
        failRunSetup("spore run: image resolve failed for {s}: {s}", .{ image_ref, @errorName(err) });
    };
    if (try cachedImageRootfsPath(init, allocator, cache_root, resolved)) |path| return path;
    return buildCachedImageRootfs(init, allocator, cache_root, resolved);
}

fn cachedImageRootfsPath(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    resolved: rootfs_mod.ResolvedImage,
) !?[]const u8 {
    const cache_key = try rootfsCacheKeyAlloc(allocator, resolved);
    const rootfs_path = try std.fmt.allocPrint(allocator, "{s}/{s}.ext4", .{ cache_root, cache_key });
    const metadata_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ cache_root, cache_key });
    const metadata_matches = cachedRootfsMetadataMatches(init.io, allocator, metadata_path, resolved) catch |err| {
        failRunSetup("spore run: cached rootfs metadata check failed: {s}", .{@errorName(err)});
    };
    if (metadata_matches and try readablePath(init.io, rootfs_path)) {
        const message = try std.fmt.allocPrint(allocator, "spore run: using cached rootfs {s} for {s}\n", .{ rootfs_path, resolved.ref });
        try writeSetupStderr(init, message);
        return rootfs_path;
    }
    return null;
}

fn buildCachedImageRootfs(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    resolved: rootfs_mod.ResolvedImage,
) ![]const u8 {
    const cache_key = try rootfsCacheKeyAlloc(allocator, resolved);
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

    const build_message = try std.fmt.allocPrint(allocator, "spore run: building cached rootfs for {s}\n", .{resolved.ref});
    try writeSetupStderr(init, build_message);
    _ = rootfs_mod.build(init, allocator, .{
        .ref = resolved.ref,
        .output = temp_rootfs_path,
        .metadata = temp_metadata_path,
        .platform = direct_image_platform,
        .metadata_rootfs_path = rootfs_path,
        .temp_dir_root = temp_dir_root,
    }) catch |err| {
        failRunSetup("spore run: image rootfs build failed for {s}: {s}", .{ resolved.ref, @errorName(err) });
    };
    try Io.Dir.renameAbsolute(temp_rootfs_path, rootfs_path, init.io);
    try Io.Dir.renameAbsolute(temp_metadata_path, metadata_path, init.io);

    const cached_message = try std.fmt.allocPrint(allocator, "spore run: cached rootfs {s}\n", .{rootfs_path});
    try writeSetupStderr(init, cached_message);
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

fn rootfsCacheRootPath(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    if (init.environ_map.get(rootfs_cache_env)) |path| {
        return std.fs.path.resolve(allocator, &.{path});
    }
    if (init.environ_map.get("XDG_CACHE_HOME")) |path| {
        return std.fs.path.resolve(allocator, &.{ path, "sporevm", "rootfs" });
    }
    const home = init.environ_map.get("HOME") orelse {
        failRunSetup("spore run: cannot resolve rootfs cache directory; set {s} or HOME", .{rootfs_cache_env});
    };
    if (comptime builtin.os.tag == .macos) {
        return std.fs.path.resolve(allocator, &.{ home, "Library", "Caches", "sporevm", "rootfs" });
    }
    return std.fs.path.resolve(allocator, &.{ home, ".cache", "sporevm", "rootfs" });
}

fn rootfsCacheKeyAlloc(allocator: std.mem.Allocator, resolved: rootfs_mod.ResolvedImage) ![]u8 {
    var h = Sha256.init(.{});
    h.update(rootfs_mod.builder_version);
    h.update("\n");
    h.update(resolved.platform.os);
    h.update("/");
    h.update(resolved.platform.arch);
    h.update("\n");
    h.update(resolved.manifest_digest);
    h.update("\n");
    h.update(resolved.ref);
    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
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

fn resolveDefaultKernelPath(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    if (init.environ_map.get("SPOREVM_KERNEL_IMAGE")) |path| {
        if (!try readablePath(init.io, path)) {
            failRunSetup("spore run: SPOREVM_KERNEL_IMAGE not found: {s}", .{path});
        }
        return path;
    }

    const helper = try sourceTreeKernelHelperPath(init, allocator);
    if (!try executablePath(init.io, helper)) {
        failRunSetup(
            "spore run: default kernel resolver not found at {s}; pass --kernel or set SPOREVM_KERNEL_IMAGE",
            .{helper},
        );
    }

    const result = std.process.run(allocator, init.io, .{
        .argv = &.{ helper, "run" },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| {
        failRunSetup("spore run: default kernel resolver failed before exec: {s}", .{@errorName(err)});
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try writeSetupStderr(init, result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) {
            const trimmed = std.mem.trimEnd(u8, result.stdout, "\r\n");
            if (trimmed.len == 0) {
                failRunSetup("spore run: default kernel resolver returned an empty path", .{});
            }
            return allocator.dupe(u8, trimmed);
        },
        else => {},
    }
    failRunSetup(
        "spore run: default kernel resolver failed; pass --kernel or set SPOREVM_KERNEL_IMAGE",
        .{},
    );
}

fn resolveDefaultInitrdPath(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
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

fn sourceTreeKernelHelperPath(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    const prefix = try installPrefixPath(init, allocator);
    return sourceTreeKernelHelperPathFromPrefix(allocator, prefix);
}

fn defaultInitrdPathFromPrefix(allocator: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ prefix, "share", "sporevm", default_run_initrd_name });
}

fn sourceTreeKernelHelperPathFromPrefix(allocator: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    const repo_root = std.fs.path.dirname(prefix) orelse {
        failRunSetup("spore run: cannot resolve source tree from install prefix {s}", .{prefix});
    };
    return std.fs.path.join(allocator, &.{ repo_root, "scripts", "ensure-managed-kernel.sh" });
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

pub fn parseHarnessArgs(backend: Backend, args: []const []const u8) !Options {
    var shared = SharedOptions{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (try parseSharedOption(&shared, args, &i)) {
            continue;
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            printHarnessUsage(backend);
            std.process.exit(0);
        } else {
            std.debug.print("unknown argument: {s}\n\n", .{args[i]});
            printHarnessUsage(backend);
            std.process.exit(2);
        }
    }

    if (shared.kernel_path == null or shared.initrd_path == null) {
        printHarnessUsage(backend);
        std.process.exit(2);
    }

    return shared.complete(backend, default_command[0..], false);
}

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, opts: Options) !Result {
    if (opts.vcpus != 1) return error.UnsupportedVcpuCount;

    const backend = try resolveBackend(opts.backend);
    const kernel = try std.Io.Dir.cwd().readFileAlloc(init.io, opts.kernel_path, allocator, .limited(max_file_size));
    const initrd = try std.Io.Dir.cwd().readFileAlloc(init.io, opts.initrd_path, allocator, .limited(max_file_size));
    const rootfs_fd = try openRootfsDisk(allocator, opts.rootfs_path);
    defer {
        if (rootfs_fd) |fd| _ = std.c.close(fd);
    }
    const boot_args = try cmdline(allocator, opts.guest_port, opts.rootfs_path != null);
    const request = try execRequest(allocator, opts.command);
    var stream = try vsock.HostStream.init(opts.guest_port, request);
    if (opts.stream_output) stream.setOutputSink(null, runOutputSink);

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
                .exec_probe = &stream,
                .exec_probe_timeout_ms = opts.timeout_ms,
            });
        },
        .kvm => blk: {
            if (comptime !(builtin.os.tag == .linux and builtin.cpu.arch == .aarch64)) return error.UnsupportedBackend;
            break :blk try kvm.vm.run(allocator, .{
                .kernel = kernel,
                .ram_size = opts.memory_mib * 1024 * 1024,
                .cmdline = boot_args,
                .initrd = initrd,
                .console_sink = consoleSink,
                .disk_fd = rootfs_fd,
                .exec_probe = &stream,
                .exec_probe_timeout_ms = opts.timeout_ms,
            });
        },
    };
    if (cause != .probe_complete) return error.ProbeDidNotComplete;

    return resultFromStream(backend, opts, &stream);
}

fn openRootfsDisk(allocator: std.mem.Allocator, rootfs_path: ?[]const u8) !?std.c.fd_t {
    const path = rootfs_path orelse return null;
    const pathz = try allocator.dupeZ(u8, path);
    const fd = std.c.open(pathz, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return error.RootFSOpenFailed;
    return fd;
}

pub fn writeJsonResult(writer: *Io.Writer, result: Result) !void {
    try writer.print(
        "{{\"backend\":\"{s}\",\"probe\":\"exec\",\"start_ms\":{d},\"vsock_connect_ms\":{d},\"exec_response_ms\":{d},\"probe_duration_ms\":{d},\"exit_code\":{d},\"vcpus\":{d},\"memory_mib\":{d}}}\n",
        .{
            result.backend.name(),
            result.start_ms,
            result.vsock_connect_ms,
            result.exec_response_ms,
            result.probe_duration_ms,
            result.exit_code,
            result.vcpus,
            result.memory_mib,
        },
    );
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
    try validateGuestArgv(argv);
    const payload = struct {
        type: []const u8 = "start",
        session_id: []const u8 = "default",
        argv: []const []const u8,
        closed_env: bool = true,
    }{ .argv = argv };
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

fn resultFromStream(backend: Backend, opts: Options, stream: *const vsock.HostStream) !Result {
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
    };
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

fn printHarnessUsage(backend: Backend) void {
    std.debug.print(
        \\Usage:
        \\  {s}-minimal --kernel Image --initrd root.cpio [options]
        \\
        \\Options:
        \\  --memory-mib N      Guest memory in MiB (default: 1024)
        \\  --vcpus N           Guest vCPU count; must be 1 today
        \\  --guest-port N      Guest vsock listen port (default: 10700)
        \\  --timeout-ms N      Probe timeout in milliseconds (default: 30000)
        \\  --console-log PATH  Write guest console output to PATH
        \\  -h, --help          Show this help
        \\
    , .{backend.name()});
}

test "run request encodes argv" {
    const request = try execRequest(std.testing.allocator, &.{ "/bin/echo", "hello world" });
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings("{\"type\":\"start\",\"session_id\":\"default\",\"argv\":[\"/bin/echo\",\"hello world\"],\"closed_env\":true}\n", request);
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

test "run image cache key is deterministic and scoped to resolved image identity" {
    const allocator = std.testing.allocator;
    const resolved = rootfs_mod.ResolvedImage{
        .ref = "docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .manifest_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = .{},
    };
    const same = try rootfsCacheKeyAlloc(allocator, resolved);
    defer allocator.free(same);
    const again = try rootfsCacheKeyAlloc(allocator, resolved);
    defer allocator.free(again);
    try std.testing.expectEqual(@as(usize, Sha256.digest_length * 2), same.len);
    try std.testing.expectEqualStrings(same, again);

    const changed_ref = try rootfsCacheKeyAlloc(allocator, .{
        .ref = "docker.io/library/alpine@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .manifest_digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .platform = .{},
    });
    defer allocator.free(changed_ref);
    try std.testing.expect(!std.mem.eql(u8, same, changed_ref));

    const changed_platform = try rootfsCacheKeyAlloc(allocator, .{
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

    const helper = try sourceTreeKernelHelperPathFromPrefix(allocator, "/repo/zig-out");
    defer allocator.free(helper);
    try std.testing.expectEqualStrings("/repo/scripts/ensure-managed-kernel.sh", helper);
}

test "run harness parser shares common options" {
    const opts = try parseHarnessArgs(.kvm, &.{ "kvm-minimal", "--kernel", "Image", "--initrd", "root.cpio", "--memory-mib", "512", "--guest-port", "12000" });
    try std.testing.expectEqual(Backend.kvm, opts.backend);
    try std.testing.expectEqualStrings("Image", opts.kernel_path);
    try std.testing.expectEqualStrings("root.cpio", opts.initrd_path);
    try std.testing.expectEqual(@as(u64, 512), opts.memory_mib);
    try std.testing.expectEqual(@as(u32, 12000), opts.guest_port);
    try std.testing.expectEqualStrings("/bin/true", opts.command[0]);
}

test "run json result includes benchmark timings" {
    var stdout: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();

    try writeJsonResult(&stdout.writer, .{
        .backend = .hvf,
        .start_ms = 1,
        .vsock_connect_ms = 2,
        .exec_response_ms = 3,
        .probe_duration_ms = 1,
        .exit_code = 0,
        .vcpus = 1,
        .memory_mib = 1024,
    });

    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "\"exec_response_ms\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "\"exit_code\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "\"memory_mib\":1024") != null);
}
