//! Kernel and initrd for fresh boots: the managed kernel download and cache,
//! the embedded minimal initrd, and files injected into it.

const std = @import("std");
const TestDir = @import("test_dir.zig").TestDir;
const builtin = @import("builtin");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const local_paths = @import("local_paths.zig");
const rootfs_cache = @import("rootfs_cache.zig");
const run_assets = @import("run_assets");

pub const max_file_size = 256 * 1024 * 1024;
const max_kernel_asset_size = 256 * 1024 * 1024;
const max_kernel_config_asset_size = 2 * 1024 * 1024;
const managed_kernel_download_attempts = 3;
const max_injected_files = 16;
const max_injected_file_id_len = 96;
const max_injected_file_total_bytes = 16 * 1024 * 1024;
const embedded_run_initrd = run_assets.minimal_exec_initrd;
const embedded_run_initrd_sha256 = blk: {
    var digest: [Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, run_assets.minimal_exec_initrd_sha256_hex) catch
        @compileError("generated minimal initrd SHA-256 is not canonical hex");
    break :blk digest;
};
const managed_kernel = parseManagedKernelPins(@embedFile("managed_kernel.env"));
// Some pins are only used on one architecture; check the file on every target.
comptime {
    _ = managed_kernel;
}
const default_kernel_repository = managed_kernel.repository;
const default_kernel_release = managed_kernel.release;
const default_kernel_version = managed_kernel.linux_version;

const managed_run_kernel_required_config_symbols = [_][]const u8{
    "CONFIG_CGROUPS",
    "CONFIG_FILE_LOCKING",
    "CONFIG_HW_RANDOM",
    "CONFIG_HW_RANDOM_VIRTIO",
    "CONFIG_VIRTIO_BLK",
    "CONFIG_EXT4_FS",
    "CONFIG_JBD2",
    "CONFIG_SHMEM",
    "CONFIG_TMPFS",
    "CONFIG_FSNOTIFY",
    "CONFIG_INOTIFY_USER",
    "CONFIG_BPF_SYSCALL",
    "CONFIG_CGROUP_BPF",
    "CONFIG_MEMCG",
    "CONFIG_CGROUP_PIDS",
    "CONFIG_CPUSETS",
    "CONFIG_CGROUP_DEVICE",
    "CONFIG_EXT4_FS_SECURITY",
    "CONFIG_MEMORY_HOTPLUG",
    "CONFIG_MEMORY_HOTPLUG_DEFAULT_ONLINE",
    "CONFIG_MEMORY_HOTREMOVE",
    "CONFIG_CONTIG_ALLOC",
    "CONFIG_EXCLUSIVE_SYSTEM_RAM",
    "CONFIG_VIRTIO_MEM",
};
const managed_x86_kernel_required_config_symbols = [_][]const u8{
    "CONFIG_X86_64",
    "CONFIG_SMP",
    "CONFIG_X86_LOCAL_APIC",
    "CONFIG_X86_IO_APIC",
    "CONFIG_X86_MPPARSE",
    "CONFIG_HYPERVISOR_GUEST",
    "CONFIG_PARAVIRT",
    "CONFIG_PARAVIRT_CLOCK",
    "CONFIG_KVM_GUEST",
    "CONFIG_RELOCATABLE",
    "CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES",
    "CONFIG_DEVMEM",
    "CONFIG_STRICT_DEVMEM",
};
const managed_x86_kernel_forbidden_config_symbols = [_][]const u8{
    "CONFIG_IO_STRICT_DEVMEM",
    "CONFIG_ACPI",
    "CONFIG_EFI",
    "CONFIG_PCI",
    "CONFIG_VIRTIO_PCI",
    "CONFIG_RTC_CLASS",
    "CONFIG_SERIAL_8250",
    "CONFIG_KEYBOARD_ATKBD",
    "CONFIG_MOUSE_PS2",
    "CONFIG_SERIO_I8042",
};
const approved_x86_kernel_sha256 = managed_kernel.x86_64_sha256;

const ManagedKernelPins = struct {
    repository: []const u8,
    release: []const u8,
    linux_version: []const u8,
    x86_64_sha256: [Sha256.digest_length]u8,
};

/// Shell scripts `source` the same file, so accept only comments and
/// unquoted, unrepeated `key=value` lines that both readers see alike.
fn parseManagedKernelPins(comptime text: []const u8) ManagedKernelPins {
    comptime {
        @setEvalBranchQuota(10_000);
        const keys = [_][]const u8{
            "managed_kernel_repository",
            "managed_kernel_release",
            "managed_kernel_linux_version",
            "managed_kernel_x86_64_sha256",
        };
        var values: [keys.len]?[]const u8 = @splat(null);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse
                @compileError("src/managed_kernel.env: expected key=value: " ++ line);
            const index = for (keys, 0..) |key, i| {
                if (std.mem.eql(u8, line[0..eq], key)) break i;
            } else @compileError("src/managed_kernel.env: unknown key: " ++ line);
            if (values[index] != null) @compileError("src/managed_kernel.env repeats " ++ keys[index]);
            const value = line[eq + 1 ..];
            if (value.len == 0) @compileError("src/managed_kernel.env: empty value: " ++ line);
            for (value) |c| {
                if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "._/-", c) == null) {
                    @compileError("src/managed_kernel.env: value must match [0-9A-Za-z._/-]+: " ++ line);
                }
            }
            values[index] = value;
        }
        for (keys, values) |key, value| {
            if (value == null) @compileError("src/managed_kernel.env is missing " ++ key);
        }

        const hex = values[3].?;
        var digest: [Sha256.digest_length]u8 = undefined;
        if (hex.len != 2 * digest.len) @compileError("managed_kernel_x86_64_sha256 is not a SHA-256 digest");
        for (hex) |c| {
            if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) {
                @compileError("managed_kernel_x86_64_sha256 must be lowercase hex");
            }
        }
        _ = std.fmt.hexToBytes(&digest, hex) catch unreachable;
        return .{
            .repository = values[0].?,
            .release = values[1].?,
            .linux_version = values[2].?,
            .x86_64_sha256 = digest,
        };
    }
}

pub const InjectedFile = struct {
    id: []const u8,
    bytes: []const u8,
};

pub const InjectedFileSource = struct {
    id: []const u8,
    path: []const u8,
};

pub const InjectedFileSourceList = struct {
    items: [max_injected_files]InjectedFileSource = undefined,
    len: usize = 0,

    pub fn append(self: *InjectedFileSourceList, input: InjectedFileSource) !void {
        if (self.len >= max_injected_files) return error.TooManyInjectedFiles;
        try validateInjectedFileId(input.id);
        if (input.path.len == 0) return error.BadInjectedFilePath;
        for (self.items[0..self.len]) |existing| {
            if (std.mem.eql(u8, existing.id, input.id)) return error.DuplicateInjectedFile;
        }
        self.items[self.len] = input;
        self.len += 1;
    }

    pub fn slice(self: *const InjectedFileSourceList) []const InjectedFileSource {
        return self.items[0..self.len];
    }
};

pub fn parseInjectedFileSource(raw: []const u8) !InjectedFileSource {
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return error.BadInjectedFile;
    const id = raw[0..eq];
    const path = raw[eq + 1 ..];
    try validateInjectedFileId(id);
    if (path.len == 0) return error.BadInjectedFilePath;
    return .{ .id = id, .path = path };
}

pub fn resolveDefaultKernelPath(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    if (init.environ_map.get("SPOREVM_KERNEL_IMAGE")) |path| {
        if (!try local_paths.readablePath(init.io, path)) return error.FileNotFound;
        return path;
    }

    return (try resolveManagedRunKernel(init, allocator)).path;
}

pub fn resolveConfiguredInitrdPath(init: std.process.Init, cli_path: ?[]const u8) !?[]const u8 {
    if (cli_path) |path| return path;
    if (init.environ_map.get("SPOREVM_RUN_INITRD")) |path| {
        if (!try local_paths.readablePath(init.io, path)) return error.FileNotFound;
        return path;
    }
    return null;
}

const ManagedRunKernel = struct {
    path: []const u8,
    sha256: [Sha256.digest_length]u8,
};

fn resolveManagedRunKernel(init: std.process.Init, allocator: std.mem.Allocator) !ManagedRunKernel {
    const opts = managedKernelOptions(init);
    const asset = try managedRunKernelAssetName(allocator, opts.linux_version);
    const config_asset = try managedRunKernelConfigAssetName(allocator, asset);
    const cache_root = local_paths.kernelCacheRootPath(allocator, init.environ_map) catch |err| switch (err) {
        error.MissingHome => return error.MissingHome,
        else => |e| return e,
    };
    const repo_cache = try managedKernelRepositoryCacheName(allocator, opts.repository);
    const dest_dir = try std.fs.path.join(allocator, &.{ cache_root, repo_cache, opts.release });
    const dest = try std.fs.path.join(allocator, &.{ dest_dir, asset });
    const sha_dest = try std.fmt.allocPrint(allocator, "{s}.sha256", .{dest});
    const config_dest = try std.fmt.allocPrint(allocator, "{s}.config", .{dest});

    if (try managedKernelCacheDigest(init.io, allocator, dest, sha_dest, config_dest, asset)) |digest| {
        try validateManagedKernelArchitectureDigest(digest);
        return .{ .path = dest, .sha256 = digest };
    }

    try local_paths.ensureDirPath(init.io, dest_dir);
    const temp_dir_root = try std.fs.path.join(allocator, &.{ dest_dir, "download" });
    try local_paths.ensureDirPath(init.io, temp_dir_root);

    var nonce_bytes: [8]u8 = undefined;
    init.io.random(&nonce_bytes);
    const nonce = std.mem.readInt(u64, &nonce_bytes, .little);
    const temp_image = try std.fmt.allocPrint(allocator, "{s}/{s}.{x}.tmp", .{ temp_dir_root, asset, nonce });
    const temp_sha = try std.fmt.allocPrint(allocator, "{s}.sha256", .{temp_image});
    const temp_config = try std.fmt.allocPrint(allocator, "{s}.config", .{temp_image});
    defer Io.Dir.cwd().deleteFile(init.io, temp_image) catch {};
    defer Io.Dir.cwd().deleteFile(init.io, temp_sha) catch {};
    defer Io.Dir.cwd().deleteFile(init.io, temp_config) catch {};

    var client: std.http.Client = .{ .allocator = allocator, .io = init.io };
    defer client.deinit();
    try fetchManagedKernelAsset(allocator, init.io, &client, opts.repository, opts.release, asset, temp_image, max_kernel_asset_size);
    const sha_asset = try std.fmt.allocPrint(allocator, "{s}.sha256", .{asset});
    try fetchManagedKernelAsset(allocator, init.io, &client, opts.repository, opts.release, sha_asset, temp_sha, max_kernel_config_asset_size);
    try fetchManagedKernelAsset(allocator, init.io, &client, opts.repository, opts.release, config_asset, temp_config, max_kernel_config_asset_size);
    const expected_digest = (try verifiedManagedKernelDigest(init.io, allocator, temp_image, temp_sha, asset)) orelse
        return error.ManagedKernelChecksumMismatch;
    try validateManagedKernelArchitectureDigest(expected_digest);
    if (try missingManagedRunKernelConfigSymbolFromPath(init.io, allocator, temp_config)) |missing| {
        defer allocator.free(missing);
        return error.ManagedKernelConfigMissing;
    }

    try Io.Dir.renameAbsolute(temp_image, dest, init.io);
    try Io.Dir.renameAbsolute(temp_sha, sha_dest, init.io);
    try Io.Dir.renameAbsolute(temp_config, config_dest, init.io);
    chmodFileReadOnly(allocator, dest) catch {};
    chmodFileReadOnly(allocator, sha_dest) catch {};
    chmodFileReadOnly(allocator, config_dest) catch {};
    return .{ .path = dest, .sha256 = expected_digest };
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
    return managedRunKernelAssetNameFor(allocator, builtin.cpu.arch, linux_version);
}

fn managedRunKernelAssetNameFor(allocator: std.mem.Allocator, zig_arch: std.Target.Cpu.Arch, linux_version: []const u8) ![]const u8 {
    try validateManagedKernelVersion(linux_version);
    if (zig_arch == .x86_64) {
        return std.fmt.allocPrint(allocator, "sporevm-x86_64-linux-{s}-bzImage", .{linux_version});
    }
    return std.fmt.allocPrint(allocator, "sporevm-arm64-linux-{s}-Image", .{linux_version});
}

fn validateManagedKernelArchitectureDigest(digest: [Sha256.digest_length]u8) !void {
    if (comptime builtin.cpu.arch == .x86_64) {
        if (!std.mem.eql(u8, &digest, &approved_x86_kernel_sha256)) return error.ManagedKernelArchitectureDigestMismatch;
    }
}

fn managedRunKernelConfigAssetName(allocator: std.mem.Allocator, image_asset: []const u8) ![]const u8 {
    try validateManagedKernelAsset(image_asset);
    return std.fmt.allocPrint(allocator, "{s}.config", .{image_asset});
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

fn verifiedManagedKernelDigest(
    io: Io,
    allocator: std.mem.Allocator,
    image_path: []const u8,
    sha_path: []const u8,
    asset_name: []const u8,
) !?[Sha256.digest_length]u8 {
    if (!try rootfs_cache.regularFileNoSymlink(io, image_path)) return null;
    if (!try rootfs_cache.regularFileNoSymlink(io, sha_path)) return null;
    const expected = readExpectedSha256Digest(io, allocator, sha_path, asset_name, false) catch |err| switch (err) {
        error.BadManagedKernelChecksum => return null,
        else => |e| return e,
    };
    const actual = try sha256FileDigest(io, image_path);
    if (!std.mem.eql(u8, &expected, &actual)) return null;
    return expected;
}

fn managedKernelCacheDigest(
    io: Io,
    allocator: std.mem.Allocator,
    image_path: []const u8,
    sha_path: []const u8,
    config_path: []const u8,
    asset_name: []const u8,
) !?[Sha256.digest_length]u8 {
    if (!try readOnlyRegularFileNoSymlink(io, image_path)) return null;
    if (!try readOnlyRegularFileNoSymlink(io, sha_path)) return null;
    if (!try readOnlyRegularFileNoSymlink(io, config_path)) return null;

    const expected = readExpectedSha256Digest(io, allocator, sha_path, asset_name, true) catch |err| switch (err) {
        error.BadManagedKernelChecksum => return null,
        else => |e| return e,
    };

    // Managed kernel assets are verified against the release checksum before
    // being atomically installed read-only. Cache lookup reads only the small,
    // canonical checksum sidecar and config; an executor miss separately opens
    // the Image once, verifies those exact bytes, and boots the same allocation.
    // The config-symbol check stays because the required symbol list belongs to
    // the running binary, which may demand more than the installer did.
    if (!try managedRunKernelConfigHasRequiredSymbols(io, allocator, config_path)) return null;
    return expected;
}

fn managedKernelCacheHit(
    io: Io,
    allocator: std.mem.Allocator,
    image_path: []const u8,
    sha_path: []const u8,
    config_path: []const u8,
    asset_name: []const u8,
) !bool {
    return (try managedKernelCacheDigest(io, allocator, image_path, sha_path, config_path, asset_name)) != null;
}

fn managedRunKernelConfigHasRequiredSymbols(io: Io, allocator: std.mem.Allocator, config_path: []const u8) !bool {
    const missing = try missingManagedRunKernelConfigSymbolFromPath(io, allocator, config_path);
    if (missing) |symbol| {
        allocator.free(symbol);
        return false;
    }
    return true;
}

fn missingManagedRunKernelConfigSymbolFromPath(io: Io, allocator: std.mem.Allocator, config_path: []const u8) !?[]const u8 {
    if (!try rootfs_cache.regularFileNoSymlink(io, config_path)) return error.ManagedKernelConfigMissing;
    const config = try Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(max_kernel_config_asset_size));
    defer allocator.free(config);
    return missingManagedRunKernelConfigSymbol(allocator, config);
}

fn missingManagedRunKernelConfigSymbol(allocator: std.mem.Allocator, config: []const u8) !?[]const u8 {
    return missingManagedRunKernelConfigSymbolFor(allocator, builtin.cpu.arch, config);
}

fn missingManagedRunKernelConfigSymbolFor(allocator: std.mem.Allocator, zig_arch: std.Target.Cpu.Arch, config: []const u8) !?[]const u8 {
    for (&managed_run_kernel_required_config_symbols) |symbol| {
        if (!kernelConfigHasBuiltin(config, symbol)) return try allocator.dupe(u8, symbol);
    }
    if (zig_arch == .x86_64) {
        for (&managed_x86_kernel_required_config_symbols) |symbol| {
            if (!kernelConfigHasBuiltin(config, symbol)) return try allocator.dupe(u8, symbol);
        }
        for (&managed_x86_kernel_forbidden_config_symbols) |symbol| {
            if (kernelConfigEnabled(config, symbol)) return try allocator.dupe(u8, symbol);
        }
    }
    return null;
}

fn kernelConfigHasBuiltin(config: []const u8, symbol: []const u8) bool {
    var lines = std.mem.splitScalar(u8, config, '\n');
    while (lines.next()) |raw_line| {
        const line = if (std.mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
        if (line.len != symbol.len + 2) continue;
        if (!std.mem.startsWith(u8, line, symbol)) continue;
        if (line[symbol.len] != '=') continue;
        if (line[symbol.len + 1] != 'y') continue;
        return true;
    }
    return false;
}

fn kernelConfigEnabled(config: []const u8, symbol: []const u8) bool {
    var lines = std.mem.splitScalar(u8, config, '\n');
    while (lines.next()) |raw_line| {
        const line = if (std.mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
        if (line.len != symbol.len + 2 or !std.mem.startsWith(u8, line, symbol) or line[symbol.len] != '=') continue;
        return line[symbol.len + 1] == 'y' or line[symbol.len + 1] == 'm';
    }
    return false;
}

fn readOnlyRegularFileNoSymlink(io: Io, path: []const u8) !bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return false,
        else => |e| return e,
    };
    return stat.kind == .file and @intFromEnum(stat.permissions) & 0o222 == 0;
}

fn readExpectedSha256Digest(
    io: Io,
    allocator: std.mem.Allocator,
    sha_path: []const u8,
    asset_name: []const u8,
    require_read_only: bool,
) ![Sha256.digest_length]u8 {
    const bytes = try readRegularFileNoSymlinkAlloc(io, allocator, sha_path, 4096, require_read_only);
    defer allocator.free(bytes);
    var fields = std.mem.tokenizeAny(u8, bytes, " \t\r\n");
    const first = fields.next() orelse return error.BadManagedKernelChecksum;
    if (!isCanonicalSha256Hex(first)) return error.BadManagedKernelChecksum;
    if (fields.next()) |named_asset| {
        const normalized_name = if (std.mem.startsWith(u8, named_asset, "*")) named_asset[1..] else named_asset;
        if (!std.mem.eql(u8, normalized_name, asset_name)) return error.BadManagedKernelChecksum;
    }
    if (fields.next() != null) return error.BadManagedKernelChecksum;
    var digest: [Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, first) catch return error.BadManagedKernelChecksum;
    return digest;
}

fn readRegularFileNoSymlinkAlloc(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_size: usize,
    require_read_only: bool,
) ![]u8 {
    const pathz = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(pathz);
    const fd = std.c.open(pathz, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.ManagedKernelAssetOpenFailed;
    defer _ = std.c.close(fd);

    const file = Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    const stat = file.stat(io) catch return error.ManagedKernelAssetOpenFailed;
    if (stat.kind != .file) return error.ManagedKernelAssetOpenFailed;
    if (require_read_only and @intFromEnum(stat.permissions) & 0o222 != 0)
        return error.ManagedKernelCacheEntryWritable;
    if (stat.size > max_size) return error.ManagedKernelAssetTooLarge;
    const len: usize = @intCast(stat.size);
    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < len) {
        const n = std.c.read(fd, bytes[offset..].ptr, len - offset);
        if (n <= 0) return error.ManagedKernelAssetReadFailed;
        offset += @intCast(n);
    }
    var extra: [1]u8 = undefined;
    const trailing = std.c.read(fd, extra[0..].ptr, extra.len);
    if (trailing < 0) return error.ManagedKernelAssetReadFailed;
    if (trailing != 0) return error.ManagedKernelAssetChanged;
    return bytes;
}

fn isCanonicalSha256Hex(value: []const u8) bool {
    if (value.len != Sha256.digest_length * 2) return false;
    for (value) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

fn sha256FileDigest(io: Io, path: []const u8) ![Sha256.digest_length]u8 {
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
    return out;
}

fn fetchManagedKernelAsset(
    allocator: std.mem.Allocator,
    io: Io,
    client: *std.http.Client,
    repository: []const u8,
    release: []const u8,
    asset: []const u8,
    output_path: []const u8,
    max_body_bytes: u64,
) !void {
    try validateManagedKernelRepository(repository);
    try validateManagedKernelVersion(release);
    try validateManagedKernelAsset(asset);
    const url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/releases/download/{s}/{s}", .{ repository, release, asset });
    var attempt: u8 = 0;
    while (attempt < managed_kernel_download_attempts) : (attempt += 1) {
        Io.Dir.cwd().deleteFile(io, output_path) catch {};
        httpGetToFile(io, client, url, output_path, max_body_bytes) catch |err| {
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
    const pathz = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(pathz);
    if (std.c.chmod(pathz, 0o444) != 0) return error.ChmodFailed;
}

fn chmodFileWritable(allocator: std.mem.Allocator, path: []const u8) !void {
    const pathz = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(pathz);
    if (std.c.chmod(pathz, 0o644) != 0) return error.ChmodFailed;
}

pub fn loadRunInitrd(io: Io, allocator: std.mem.Allocator, path: ?[]const u8, injected_files: []const InjectedFile) ![]const u8 {
    try validateInjectedFiles(injected_files);
    if (path) |initrd_path| {
        const base = try std.Io.Dir.cwd().readFileAlloc(io, initrd_path, allocator, .limited(max_file_size));
        return try initrdWithInjectedFiles(allocator, base, injected_files);
    }
    return try initrdWithInjectedFiles(allocator, embedded_run_initrd, injected_files);
}

pub fn readInjectedFileSources(io: Io, allocator: std.mem.Allocator, files: []const InjectedFileSource) ![]const InjectedFile {
    if (files.len == 0) return &.{};
    const injected = try allocator.alloc(InjectedFile, files.len);
    var total: usize = 0;
    for (files, injected) |file, *out| {
        try validateInjectedFileId(file.id);
        if (file.path.len == 0) return error.BadInjectedFilePath;
        const remaining = max_injected_file_total_bytes -| total;
        const bytes = try readInjectedFileSource(allocator, io, file.path, remaining);
        total += bytes.len;
        if (total > max_injected_file_total_bytes) return error.InjectedFileTooLarge;
        out.* = .{ .id = file.id, .bytes = bytes };
    }
    try validateInjectedFiles(injected);
    return injected;
}

fn readInjectedFileSource(allocator: std.mem.Allocator, io: Io, path: []const u8, max_bytes: usize) ![]const u8 {
    const pathz = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(pathz);
    const fd = std.c.open(pathz, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.InjectedFileOpenFailed;
    defer _ = std.c.close(fd);

    const file = Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    const stat = file.stat(io) catch return error.InjectedFileOpenFailed;
    if (stat.kind != .file) return error.InjectedFileOpenFailed;
    if (stat.size > max_bytes) return error.InjectedFileTooLarge;
    const len: usize = @intCast(stat.size);
    const bytes = try allocator.alloc(u8, len);
    var off: usize = 0;
    while (off < len) {
        const n = std.c.read(fd, bytes[off..].ptr, len - off);
        if (n < 0) return error.InjectedFileOpenFailed;
        if (n == 0) return error.InjectedFileOpenFailed;
        off += @intCast(n);
    }
    return bytes;
}

fn initrdWithInjectedFiles(allocator: std.mem.Allocator, base: []const u8, injected_files: []const InjectedFile) ![]const u8 {
    if (injected_files.len == 0) return base;
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(base);
    try padCpio(&out);
    var ino: u32 = 0x5000;
    try appendCpioDir(&out, &ino, "run/sporevm");
    try appendCpioDir(&out, &ino, "run/sporevm/injected");
    for (injected_files) |file| {
        const path = try std.fmt.allocPrint(allocator, "run/sporevm/injected/{s}", .{file.id});
        defer allocator.free(path);
        try appendCpioFile(&out, &ino, path, file.bytes);
    }
    try appendCpioEntry(&out, &ino, "TRAILER!!!", 0, 1, "");
    return try out.toOwnedSlice();
}

fn appendCpioDir(out: *Io.Writer.Allocating, ino: *u32, name: []const u8) !void {
    try appendCpioEntry(out, ino, name, 0o040700, 2, "");
}

fn appendCpioFile(out: *Io.Writer.Allocating, ino: *u32, name: []const u8, bytes: []const u8) !void {
    try appendCpioEntry(out, ino, name, 0o100400, 1, bytes);
}

fn appendCpioEntry(out: *Io.Writer.Allocating, ino: *u32, name: []const u8, mode: u32, nlink: u32, bytes: []const u8) !void {
    ino.* += 1;
    try out.writer.print(
        "070701{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}",
        .{
            ino.*,
            mode,
            @as(u32, 0),
            @as(u32, 0),
            nlink,
            @as(u32, 0),
            @as(u32, @intCast(bytes.len)),
            @as(u32, 0),
            @as(u32, 0),
            @as(u32, 0),
            @as(u32, 0),
            @as(u32, @intCast(name.len + 1)),
            @as(u32, 0),
        },
    );
    try out.writer.writeAll(name);
    try out.writer.writeByte(0);
    try padCpio(out);
    try out.writer.writeAll(bytes);
    try padCpio(out);
}

fn padCpio(out: *Io.Writer.Allocating) !void {
    while (out.written().len % 4 != 0) try out.writer.writeByte(0);
}

fn validateInjectedFiles(injected_files: []const InjectedFile) !void {
    if (injected_files.len > max_injected_files) return error.TooManyInjectedFiles;
    var total: usize = 0;
    for (injected_files, 0..) |file, i| {
        try validateInjectedFileId(file.id);
        if (file.bytes.len > max_injected_file_total_bytes -| total) return error.InjectedFileTooLarge;
        total += file.bytes.len;
        for (injected_files[0..i]) |existing| {
            if (std.mem.eql(u8, existing.id, file.id)) return error.DuplicateInjectedFile;
        }
    }
}

fn validateInjectedFileId(id: []const u8) !void {
    if (id.len == 0 or id.len > max_injected_file_id_len) return error.BadInjectedFileId;
    if (std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return error.BadInjectedFileId;
    for (id) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-') continue;
        return error.BadInjectedFileId;
    }
}

pub const MonitorBootArtifacts = struct {
    kernel: []const u8,
    initrd: []const u8,
};

/// Identity-only view of the managed default boot producer. Resolving it reads
/// the bounded checksum/config metadata but deliberately does not read the
/// kernel Image. The Image is opened exactly once if an executor miss needs to
/// boot, then the same verified allocation is passed to the VMM.
pub const ManagedMonitorBootDescriptor = struct {
    kernel_path: []const u8,
    kernel_sha256: [Sha256.digest_length]u8,
    initrd_sha256: [Sha256.digest_length]u8,
};

pub fn resolveManagedMonitorBootDescriptor(
    init: std.process.Init,
    allocator: std.mem.Allocator,
) !ManagedMonitorBootDescriptor {
    if (init.environ_map.get("SPOREVM_KERNEL_IMAGE") != null or
        init.environ_map.get("SPOREVM_RUN_INITRD") != null)
    {
        return error.CustomBootArtifactsConfigured;
    }
    const kernel = try resolveManagedRunKernel(init, allocator);
    return .{
        .kernel_path = kernel.path,
        .kernel_sha256 = kernel.sha256,
        .initrd_sha256 = embedded_run_initrd_sha256,
    };
}

pub fn materializeManagedMonitorBootArtifacts(
    io: Io,
    allocator: std.mem.Allocator,
    descriptor: ManagedMonitorBootDescriptor,
) !MonitorBootArtifacts {
    if (!std.mem.eql(u8, &descriptor.initrd_sha256, &embedded_run_initrd_sha256))
        return error.ManagedInitrdIdentityMismatch;
    const kernel = try readRegularFileNoSymlinkAlloc(io, allocator, descriptor.kernel_path, max_file_size, true);
    errdefer allocator.free(kernel);
    var actual: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(kernel, &actual, .{});
    if (!std.mem.eql(u8, &descriptor.kernel_sha256, &actual))
        return error.ManagedKernelChecksumMismatch;
    return .{ .kernel = kernel, .initrd = embedded_run_initrd };
}

pub fn loadMonitorBootArtifacts(
    io: Io,
    allocator: std.mem.Allocator,
    kernel_path: []const u8,
    initrd_path: ?[]const u8,
) !MonitorBootArtifacts {
    return .{
        .kernel = try std.Io.Dir.cwd().readFileAlloc(io, kernel_path, allocator, .limited(max_file_size)),
        .initrd = try loadRunInitrd(io, allocator, initrd_path, &.{}),
    };
}

test "injected file initrd overlay contains the file" {
    const initrd = try initrdWithInjectedFiles(std.testing.allocator, "base-cpio", &.{
        .{ .id = "config.json", .bytes = "{\"ok\":true}\n" },
    });
    defer std.testing.allocator.free(initrd);
    try std.testing.expect(std.mem.indexOf(u8, initrd, "base-cpio") != null);
    try std.testing.expect(std.mem.indexOf(u8, initrd, "run/sporevm/injected/config.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, initrd, "{\"ok\":true}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, initrd, "TRAILER!!!") != null);
}

test "injected file ids reject paths" {
    try std.testing.expectError(error.BadInjectedFileId, validateInjectedFileId("../secret"));
    try std.testing.expectError(error.BadInjectedFileId, validateInjectedFileId("nested/path"));
}

test "run embeds default initrd with its generated canonical digest" {
    try std.testing.expect(embedded_run_initrd.len > 0);
    var actual: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(embedded_run_initrd, &actual, .{});
    try std.testing.expectEqualSlices(u8, &embedded_run_initrd_sha256, &actual);
}

test "managed run kernel asset names validate input" {
    const x86 = try managedRunKernelAssetNameFor(std.testing.allocator, .x86_64, "6.1.155");
    defer std.testing.allocator.free(x86);
    try std.testing.expectEqualStrings("sporevm-x86_64-linux-6.1.155-bzImage", x86);
    const arm = try managedRunKernelAssetNameFor(std.testing.allocator, .aarch64, "6.1.155");
    defer std.testing.allocator.free(arm);
    try std.testing.expectEqualStrings("sporevm-arm64-linux-6.1.155-Image", arm);
    const allocator = std.testing.allocator;
    const asset = try managedRunKernelAssetName(allocator, "6.1.155");
    defer allocator.free(asset);
    const native_expected = if (builtin.cpu.arch == .x86_64)
        "sporevm-x86_64-linux-6.1.155-bzImage"
    else
        "sporevm-arm64-linux-6.1.155-Image";
    try std.testing.expectEqualStrings(native_expected, asset);

    const config_asset = try managedRunKernelConfigAssetName(allocator, asset);
    defer allocator.free(config_asset);
    const native_config_expected = if (builtin.cpu.arch == .x86_64)
        "sporevm-x86_64-linux-6.1.155-bzImage.config"
    else
        "sporevm-arm64-linux-6.1.155-Image.config";
    try std.testing.expectEqualStrings(native_config_expected, config_asset);

    try std.testing.expectError(error.BadManagedKernelVersion, managedRunKernelAssetName(allocator, "../bad"));
}

test "managed kernel repository cache name validates owner and repo" {
    const allocator = std.testing.allocator;
    const cache = try managedKernelRepositoryCacheName(allocator, "sporevm/kernels");
    defer allocator.free(cache);
    try std.testing.expectEqualStrings("sporevm-kernels", cache);

    try std.testing.expectError(error.BadManagedKernelRepository, managedKernelRepositoryCacheName(allocator, "buildkite"));
    try std.testing.expectError(error.BadManagedKernelRepository, managedKernelRepositoryCacheName(allocator, "../sporevm-kernels"));
}

test "managed kernel checksum parser reads sha256 sidecar" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const tmp = tmp_dir.root;
    try local_paths.ensureDirPath(io, tmp);

    const sha_path = try tmp_dir.path("Image.sha256");
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = sha_path,
        .data = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  Image\n",
    });

    const expected = try readExpectedSha256Digest(io, allocator, sha_path, "Image", false);
    const expected_hex = std.fmt.bytesToHex(expected, .lower);
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &expected_hex);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = sha_path, .data = "not-a-sha\n" });
    try std.testing.expectError(error.BadManagedKernelChecksum, readExpectedSha256Digest(io, allocator, sha_path, "Image", false));
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = sha_path,
        .data = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA  Image\n",
    });
    try std.testing.expectError(error.BadManagedKernelChecksum, readExpectedSha256Digest(io, allocator, sha_path, "Image", false));
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = sha_path,
        .data = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  Other\n",
    });
    try std.testing.expectError(error.BadManagedKernelChecksum, readExpectedSha256Digest(io, allocator, sha_path, "Image", false));
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = sha_path,
        .data = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  Image extra\n",
    });
    try std.testing.expectError(error.BadManagedKernelChecksum, readExpectedSha256Digest(io, allocator, sha_path, "Image", false));
}

test "managed kernel cache hit trusts read-only image with checksum sidecar" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const tmp = tmp_dir.root;
    try local_paths.ensureDirPath(io, tmp);

    const image_path = try tmp_dir.path("Image");
    const sha_path = try tmp_dir.path("Image.sha256");
    const config_path = try tmp_dir.path("Image.config");
    const bad_sha_path = try tmp_dir.path("Image.bad.sha256");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = image_path, .data = "kernel bytes" });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = sha_path,
        .data = "8daf3e4f39d310222b89e05b97f1aa56319811c728a147e8c6c86448f534194f  Image\n",
    });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = config_path,
        .data = "CONFIG_FILE_LOCKING=y\n" ++
            "CONFIG_CGROUPS=y\n" ++
            "CONFIG_HW_RANDOM=y\n" ++
            "CONFIG_HW_RANDOM_VIRTIO=y\n" ++
            "CONFIG_VIRTIO_BLK=y\n" ++
            "CONFIG_EXT4_FS=y\n" ++
            "CONFIG_JBD2=y\n" ++
            "CONFIG_SHMEM=y\n" ++
            "CONFIG_TMPFS=y\n" ++
            "CONFIG_FSNOTIFY=y\n" ++
            "CONFIG_INOTIFY_USER=y\n" ++
            "CONFIG_BPF_SYSCALL=y\n" ++
            "CONFIG_CGROUP_BPF=y\n" ++
            "CONFIG_MEMCG=y\n" ++
            "CONFIG_CGROUP_PIDS=y\n" ++
            "CONFIG_CPUSETS=y\n" ++
            "CONFIG_CGROUP_DEVICE=y\n" ++
            "CONFIG_EXT4_FS_SECURITY=y\n" ++
            "CONFIG_MEMORY_HOTPLUG=y\n" ++
            "CONFIG_MEMORY_HOTPLUG_DEFAULT_ONLINE=y\n" ++
            "CONFIG_MEMORY_HOTREMOVE=y\n" ++
            "CONFIG_CONTIG_ALLOC=y\n" ++
            "CONFIG_EXCLUSIVE_SYSTEM_RAM=y\n" ++
            "CONFIG_VIRTIO_MEM=y\n" ++
            "CONFIG_X86_64=y\n" ++
            "CONFIG_SMP=y\n" ++
            "CONFIG_X86_LOCAL_APIC=y\n" ++
            "CONFIG_X86_IO_APIC=y\n" ++
            "CONFIG_X86_MPPARSE=y\n" ++
            "CONFIG_HYPERVISOR_GUEST=y\n" ++
            "CONFIG_PARAVIRT=y\n" ++
            "CONFIG_PARAVIRT_CLOCK=y\n" ++
            "CONFIG_KVM_GUEST=y\n" ++
            "CONFIG_RELOCATABLE=y\n" ++
            "CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES=y\n" ++
            "CONFIG_DEVMEM=y\n" ++
            "CONFIG_STRICT_DEVMEM=y\n",
    });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = bad_sha_path, .data = "not-a-sha\n" });

    try std.testing.expect(!try managedKernelCacheHit(io, allocator, image_path, sha_path, config_path, "Image"));
    try chmodFileReadOnly(allocator, image_path);
    try std.testing.expect(!try managedKernelCacheHit(io, allocator, image_path, sha_path, config_path, "Image"));
    try chmodFileReadOnly(allocator, sha_path);
    try std.testing.expect(!try managedKernelCacheHit(io, allocator, image_path, sha_path, config_path, "Image"));
    try chmodFileReadOnly(allocator, config_path);
    try std.testing.expect(try managedKernelCacheHit(io, allocator, image_path, sha_path, config_path, "Image"));

    // Identity-only cache hits do not read the large Image. An executor miss
    // verifies the exact opened bytes before boot; see the materialization test.
    try chmodFileWritable(allocator, image_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = image_path, .data = "tampered kernel bytes" });
    try chmodFileReadOnly(allocator, image_path);
    try std.testing.expect(try managedKernelCacheHit(io, allocator, image_path, sha_path, config_path, "Image"));

    try chmodFileReadOnly(allocator, bad_sha_path);
    try std.testing.expect(!try managedKernelCacheHit(io, allocator, image_path, bad_sha_path, config_path, "Image"));

    // A writable image is not trusted, and missing required config symbols
    // still miss so a newer binary re-fetches a suitable kernel.
    try chmodFileWritable(allocator, image_path);
    try std.testing.expect(!try managedKernelCacheHit(io, allocator, image_path, sha_path, config_path, "Image"));
    try chmodFileReadOnly(allocator, image_path);
    const sparse_config_path = try tmp_dir.path("Image.sparse.config");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = sparse_config_path, .data = "CONFIG_FILE_LOCKING=y\n" });
    try chmodFileReadOnly(allocator, sparse_config_path);
    try std.testing.expect(!try managedKernelCacheHit(io, allocator, image_path, sha_path, sparse_config_path, "Image"));
}

test "managed monitor boot materialization verifies and retains opened kernel bytes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const tmp = tmp_dir.root;
    try local_paths.ensureDirPath(io, tmp);

    const image_path = try tmp_dir.path("Image");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = image_path, .data = "kernel bytes" });
    try chmodFileReadOnly(allocator, image_path);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash("kernel bytes", &digest, .{});
    const descriptor = ManagedMonitorBootDescriptor{
        .kernel_path = image_path,
        .kernel_sha256 = digest,
        .initrd_sha256 = embedded_run_initrd_sha256,
    };
    const boot = try materializeManagedMonitorBootArtifacts(io, allocator, descriptor);
    defer allocator.free(boot.kernel);
    try std.testing.expectEqualStrings("kernel bytes", boot.kernel);
    try std.testing.expect(boot.initrd.ptr == embedded_run_initrd.ptr);

    try chmodFileWritable(allocator, image_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = image_path, .data = "changed kernel bytes" });
    try chmodFileReadOnly(allocator, image_path);
    try std.testing.expectError(
        error.ManagedKernelChecksumMismatch,
        materializeManagedMonitorBootArtifacts(io, allocator, descriptor),
    );
}

test "managed run kernel config requires rootfs, Docker, and virtio-mem runtime symbols" {
    const allocator = std.testing.allocator;
    const good_config =
        "# CONFIG_DEVMEM is not set\n" ++
        "CONFIG_FILE_LOCKING=y\n" ++
        "CONFIG_CGROUPS=y\n" ++
        "CONFIG_HW_RANDOM=y\n" ++
        "CONFIG_HW_RANDOM_VIRTIO=y\n" ++
        "CONFIG_VIRTIO_BLK=y\n" ++
        "CONFIG_EXT4_FS=y\n" ++
        "CONFIG_JBD2=y\n" ++
        "CONFIG_SHMEM=y\n" ++
        "CONFIG_TMPFS=y\n" ++
        "CONFIG_FSNOTIFY=y\n" ++
        "CONFIG_INOTIFY_USER=y\n" ++
        "CONFIG_BPF_SYSCALL=y\n" ++
        "CONFIG_CGROUP_BPF=y\n" ++
        "CONFIG_MEMCG=y\n" ++
        "CONFIG_CGROUP_PIDS=y\n" ++
        "CONFIG_CPUSETS=y\n" ++
        "CONFIG_CGROUP_DEVICE=y\n" ++
        "CONFIG_EXT4_FS_SECURITY=y\n" ++
        "CONFIG_MEMORY_HOTPLUG=y\n" ++
        "CONFIG_MEMORY_HOTPLUG_DEFAULT_ONLINE=y\n" ++
        "CONFIG_MEMORY_HOTREMOVE=y\n" ++
        "CONFIG_CONTIG_ALLOC=y\n" ++
        "CONFIG_EXCLUSIVE_SYSTEM_RAM=y\n" ++
        "CONFIG_VIRTIO_MEM=y\n";

    try std.testing.expect(try missingManagedRunKernelConfigSymbolFor(allocator, .aarch64, good_config) == null);

    const missing_virtio_blk = try std.mem.replaceOwned(
        u8,
        allocator,
        good_config,
        "CONFIG_VIRTIO_BLK=y",
        "# CONFIG_VIRTIO_BLK is not set",
    );
    defer allocator.free(missing_virtio_blk);
    const missing_rootfs_symbol = (try missingManagedRunKernelConfigSymbolFor(allocator, .aarch64, missing_virtio_blk)).?;
    defer allocator.free(missing_rootfs_symbol);
    try std.testing.expectEqualStrings("CONFIG_VIRTIO_BLK", missing_rootfs_symbol);

    const missing_file_locking =
        "# CONFIG_FILE_LOCKING is not set\n" ++
        "CONFIG_CGROUPS=y\n" ++
        "CONFIG_HW_RANDOM=y\n" ++
        "CONFIG_HW_RANDOM_VIRTIO=y\n" ++
        "CONFIG_SHMEM=y\n" ++
        "CONFIG_TMPFS=y\n" ++
        "CONFIG_FSNOTIFY=y\n" ++
        "CONFIG_INOTIFY_USER=y\n" ++
        "CONFIG_BPF_SYSCALL=y\n" ++
        "CONFIG_CGROUP_BPF=y\n" ++
        "CONFIG_MEMCG=y\n" ++
        "CONFIG_CGROUP_PIDS=y\n" ++
        "CONFIG_CPUSETS=y\n" ++
        "CONFIG_CGROUP_DEVICE=y\n" ++
        "CONFIG_EXT4_FS_SECURITY=y\n" ++
        "CONFIG_MEMORY_HOTPLUG=y\n" ++
        "CONFIG_MEMORY_HOTPLUG_DEFAULT_ONLINE=y\n" ++
        "CONFIG_MEMORY_HOTREMOVE=y\n" ++
        "CONFIG_CONTIG_ALLOC=y\n" ++
        "CONFIG_EXCLUSIVE_SYSTEM_RAM=y\n" ++
        "CONFIG_VIRTIO_MEM=y\n";
    const missing = (try missingManagedRunKernelConfigSymbolFor(allocator, .aarch64, missing_file_locking)).?;
    defer allocator.free(missing);
    try std.testing.expectEqualStrings("CONFIG_FILE_LOCKING", missing);

    const module_value =
        "CONFIG_FILE_LOCKING=m\n" ++
        "CONFIG_CGROUPS=y\n" ++
        "CONFIG_SHMEM=y\n" ++
        "CONFIG_TMPFS=y\n" ++
        "CONFIG_FSNOTIFY=y\n" ++
        "CONFIG_INOTIFY_USER=y\n" ++
        "CONFIG_BPF_SYSCALL=y\n" ++
        "CONFIG_CGROUP_BPF=y\n" ++
        "CONFIG_MEMCG=y\n" ++
        "CONFIG_CGROUP_PIDS=y\n" ++
        "CONFIG_CPUSETS=y\n" ++
        "CONFIG_CGROUP_DEVICE=y\n" ++
        "CONFIG_EXT4_FS_SECURITY=y\n" ++
        "CONFIG_MEMORY_HOTPLUG=y\n" ++
        "CONFIG_MEMORY_HOTPLUG_DEFAULT_ONLINE=y\n" ++
        "CONFIG_MEMORY_HOTREMOVE=y\n" ++
        "CONFIG_CONTIG_ALLOC=y\n" ++
        "CONFIG_EXCLUSIVE_SYSTEM_RAM=y\n" ++
        "CONFIG_VIRTIO_MEM=y\n";
    const module_missing = (try missingManagedRunKernelConfigSymbolFor(allocator, .aarch64, module_value)).?;
    defer allocator.free(module_missing);
    try std.testing.expectEqualStrings("CONFIG_FILE_LOCKING", module_missing);
}

test "managed x86 kernel config enforces the frozen direct boot profile" {
    var buffer: [8192]u8 = undefined;
    var used: usize = 0;
    for (managed_run_kernel_required_config_symbols ++ managed_x86_kernel_required_config_symbols) |symbol| {
        const line = try std.fmt.bufPrint(buffer[used..], "{s}=y\n", .{symbol});
        used += line.len;
    }
    for (managed_x86_kernel_forbidden_config_symbols) |symbol| {
        const line = try std.fmt.bufPrint(buffer[used..], "# {s} is not set\n", .{symbol});
        used += line.len;
    }
    try std.testing.expect(try missingManagedRunKernelConfigSymbolFor(std.testing.allocator, .x86_64, buffer[0..used]) == null);

    const enabled = try std.fmt.bufPrint(buffer[used..], "CONFIG_ACPI=y\n", .{});
    used += enabled.len;
    const forbidden = (try missingManagedRunKernelConfigSymbolFor(std.testing.allocator, .x86_64, buffer[0..used])).?;
    defer std.testing.allocator.free(forbidden);
    try std.testing.expectEqualStrings("CONFIG_ACPI", forbidden);
}
