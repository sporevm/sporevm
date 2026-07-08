const std = @import("std");

const ext4 = @import("rootfs/ext4.zig");
const ext4_writer = @import("rootfs/ext4_writer.zig");
const local_paths = @import("local_paths.zig");
const rootfs = @import("rootfs.zig");
const xattrs_mod = @import("rootfs/xattrs.zig");

const Io = std.Io;

const ext4_writer_env = "SPOREVM_EXT4_WRITER";
const max_rootfs_metadata_bytes = 1024 * 1024;
const min_native_image_size: u64 = 16 << 20;
const resolver_placeholder_path = "etc/resolv.conf";
const resolver_placeholder_bytes =
    "# SporeVM generated placeholder; --net bind-mounts the guest resolver here.\n";

test "native ext4 writer emits deterministic fsck-clean image" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path_a = "zig-cache/test-native-ext4-a.img";
    const path_b = "zig-cache/test-native-ext4-b.img";
    defer Io.Dir.cwd().deleteFile(io, path_a) catch {};
    defer Io.Dir.cwd().deleteFile(io, path_b) catch {};

    var cap = [_]u8{ 1, 0, 0, 2 } ++ [_]u8{0} ** 16;
    const attrs = [_]xattrs_mod.Attribute{.{ .name = xattrs_mod.security_capability_name, .value = &cap }};
    const entries = [_]ext4_writer.Entry{
        .{ .path = "etc", .kind = .directory, .mode = 0o755 },
        .{ .path = "etc/hello", .kind = .{ .file = "hello\n" }, .mode = 0o644, .uid = 1000, .gid = 1000, .xattrs = &attrs },
        .{ .path = "etc/hello-hard", .kind = .{ .hardlink = "etc/hello" } },
        .{ .path = "bin", .kind = .directory, .mode = 0o755 },
        .{ .path = "bin/hello-link", .kind = .{ .symlink = "../etc/hello" } },
        .{ .path = "dev/nullish", .kind = .{ .device = .{ .kind = .char, .major = 1, .minor = 3 } }, .mode = 0o666 },
        .{ .path = "run/socket", .kind = .socket, .mode = 0o755 },
    };
    const opts = ext4_writer.Options{
        .image_size = min_native_image_size,
        .inode_count = 1024,
        .determinism = ext4.Determinism.fromDigest("sha256:test-native-ext4"),
    };

    const first = try ext4_writer.emit(allocator, io, path_a, &entries, opts);
    const second = try ext4_writer.emit(allocator, io, path_b, &entries, opts);
    try std.testing.expectEqual(first.size, second.size);
    try std.testing.expectEqualSlices(u8, &first.blake3, &second.blake3);
    try std.testing.expectEqualSlices(u8, &first.blake3, &(try ext4.blake3File(io, path_a)));
    try runE2fsck(allocator, io, path_a);
}

test "native ext4 writer emits fsck-clean multi-group image" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "zig-cache/test-native-ext4-multigroup.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const entries = [_]ext4_writer.Entry{
        .{ .path = "etc/hostname", .kind = .{ .file = "sporevm\n" }, .mode = 0o644 },
    };
    const result = try ext4_writer.emit(allocator, io, path, &entries, .{
        .image_size = 512 << 20,
        .inode_count = 65_536,
        .determinism = ext4.Determinism.fromDigest("sha256:test-native-ext4-multigroup"),
    });
    try std.testing.expectEqual(@as(u64, 512 << 20), result.size);
    try std.testing.expectEqualSlices(u8, &result.blake3, &(try ext4.blake3File(io, path)));
    try runE2fsck(allocator, io, path);
}

test "native ext4 writer emits fsck-clean symlinks at the fast/slow boundary" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "zig-cache/test-native-ext4-symlink-boundary.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const prefix = "/usr/share/ca-certificates/mozilla/";
    const target_59 = prefix ++ "a" ** (59 - prefix.len);
    const target_60 = prefix ++ "b" ** (60 - prefix.len);
    const target_61 = prefix ++ "c" ** (61 - prefix.len);

    const entries = [_]ext4_writer.Entry{
        .{ .path = "etc/link-59", .kind = .{ .symlink = target_59 } },
        .{ .path = "etc/link-60", .kind = .{ .symlink = target_60 } },
        .{ .path = "etc/link-61", .kind = .{ .symlink = target_61 } },
    };
    const result = try ext4_writer.emit(allocator, io, path, &entries, .{
        .image_size = min_native_image_size,
        .inode_count = 1024,
        .determinism = ext4.Determinism.fromDigest("sha256:test-native-ext4-symlink-boundary"),
    });
    try std.testing.expectEqualSlices(u8, &result.blake3, &(try ext4.blake3File(io, path)));
    try runE2fsck(allocator, io, path);
}

test "native ext4 writer supports double indirect regular files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "zig-cache/test-native-ext4-double-indirect.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const data = try allocator.alloc(u8, 5 * 1024 * 1024);
    defer allocator.free(data);
    for (data, 0..) |*byte, i| byte.* = @truncate(i);

    const entries = [_]ext4_writer.Entry{
        .{ .path = "var/big.bin", .kind = .{ .file = data }, .mode = 0o644 },
    };
    const result = try ext4_writer.emit(allocator, io, path, &entries, .{
        .image_size = 32 << 20,
        .inode_count = 1024,
        .determinism = ext4.Determinism.fromDigest("sha256:test-native-ext4-double-indirect"),
    });
    try std.testing.expectEqualSlices(u8, &result.blake3, &(try ext4.blake3File(io, path)));
    try runE2fsck(allocator, io, path);
}

test "native ext4 writer resolves hardlinks after sorted targets" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "zig-cache/test-native-ext4-hardlink-order.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const entries = [_]ext4_writer.Entry{
        .{ .path = "z-target", .kind = .{ .file = "shared\n" }, .mode = 0o644 },
        .{ .path = "a-alias", .kind = .{ .hardlink = "z-target" } },
    };
    const result = try ext4_writer.emit(allocator, io, path, &entries, .{
        .image_size = min_native_image_size,
        .inode_count = 1024,
        .determinism = ext4.Determinism.fromDigest("sha256:test-native-ext4-hardlink-order"),
    });
    try std.testing.expectEqualSlices(u8, &result.blake3, &(try ext4.blake3File(io, path)));
    try runE2fsck(allocator, io, path);
}

test "imported tar rootfs uses native ext4 writer by default" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-native-import-tar";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);

    const layer_path = tmp ++ "/rootfs.tar";
    try writeTestTar(allocator, io, layer_path, "etc/native-writer", "native\n");

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const cache_root = try absoluteTestPath(allocator, io, tmp, "rootfs-cache");
    defer allocator.free(cache_root);
    try env.put(local_paths.rootfs_cache_env, cache_root);
    var process_arena = std.heap.ArenaAllocator.init(allocator);
    defer process_arena.deinit();
    const init = testInit(allocator, io, &process_arena, &env);

    var import_arena = std.heap.ArenaAllocator.init(allocator);
    defer import_arena.deinit();
    const import_allocator = import_arena.allocator();

    const result = try rootfs.importTar(init, import_allocator, .{
        .input = layer_path,
        .ref = "local/native-default:latest",
        .rootfs_storage = .flat,
    });
    defer rootfs.deinitImportTarResult(import_allocator, result);

    try std.testing.expectEqualSlices(u8, &result.rootfs_blake3, &(try ext4.blake3File(io, result.rootfs_path)));
    const metadata_bytes = try Io.Dir.cwd().readFileAlloc(io, result.metadata_path, allocator, .limited(max_rootfs_metadata_bytes));
    defer allocator.free(metadata_bytes);
    try std.testing.expect(std.mem.indexOf(u8, metadata_bytes, "\"ext4_writer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, metadata_bytes, "\"native\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, metadata_bytes, "\"rootfs_storage\"") == null);
}

test "native and external imported rootfs expose matching files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-native-external-import-tar";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);

    const mkfs = try findTool(allocator, io, &.{
        "/opt/homebrew/opt/e2fsprogs/sbin/mkfs.ext4",
        "mkfs.ext4",
    });
    defer allocator.free(mkfs);
    const debugfs = try findTool(allocator, io, &.{
        "/opt/homebrew/opt/e2fsprogs/sbin/debugfs",
        "debugfs",
    });
    defer allocator.free(debugfs);

    const layer_path = tmp ++ "/rootfs.tar";
    try writeTestTar(allocator, io, layer_path, "etc/native-writer", "native\n");

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const cache_root = try absoluteTestPath(allocator, io, tmp, "rootfs-cache");
    defer allocator.free(cache_root);
    try env.put(local_paths.rootfs_cache_env, cache_root);
    var process_arena = std.heap.ArenaAllocator.init(allocator);
    defer process_arena.deinit();
    const init = testInit(allocator, io, &process_arena, &env);

    var import_arena = std.heap.ArenaAllocator.init(allocator);
    defer import_arena.deinit();
    const import_allocator = import_arena.allocator();

    try env.put(ext4_writer_env, "external");
    const external_result = try rootfs.importTar(init, import_allocator, .{
        .input = layer_path,
        .ref = "local/native-external:external",
        .rootfs_storage = .flat,
        .mkfs = mkfs,
        .debugfs = debugfs,
    });
    defer rootfs.deinitImportTarResult(import_allocator, external_result);
    try std.testing.expectEqualSlices(u8, &external_result.rootfs_blake3, &(try ext4.blake3File(io, external_result.rootfs_path)));

    try env.put(ext4_writer_env, "native");
    const native_result = try rootfs.importTar(init, import_allocator, .{
        .input = layer_path,
        .ref = "local/native-external:native",
        .rootfs_storage = .flat,
        .mkfs = mkfs,
        .debugfs = debugfs,
    });
    defer rootfs.deinitImportTarResult(import_allocator, native_result);
    try std.testing.expectEqualSlices(u8, &native_result.rootfs_blake3, &(try ext4.blake3File(io, native_result.rootfs_path)));

    const native_repeat_result = try rootfs.importTar(init, import_allocator, .{
        .input = layer_path,
        .ref = "local/native-external:native-repeat",
        .rootfs_storage = .flat,
        .mkfs = mkfs,
        .debugfs = debugfs,
    });
    defer rootfs.deinitImportTarResult(import_allocator, native_repeat_result);
    try std.testing.expectEqualSlices(u8, &native_result.rootfs_blake3, &native_repeat_result.rootfs_blake3);
    try std.testing.expectEqualSlices(u8, &native_repeat_result.rootfs_blake3, &(try ext4.blake3File(io, native_repeat_result.rootfs_path)));

    const paths = [_]struct {
        path: []const u8,
        expected: []const u8,
    }{
        .{ .path = "/etc/native-writer", .expected = "native\n" },
        .{ .path = "/" ++ resolver_placeholder_path, .expected = resolver_placeholder_bytes },
    };
    for (paths) |entry| {
        const external = try debugfsCat(allocator, io, debugfs, external_result.rootfs_path, entry.path);
        defer allocator.free(external);
        const native = try debugfsCat(allocator, io, debugfs, native_result.rootfs_path, entry.path);
        defer allocator.free(native);
        try std.testing.expectEqualStrings(entry.expected, external);
        try std.testing.expectEqualStrings(external, native);
    }
}

fn testInit(
    allocator: std.mem.Allocator,
    io: Io,
    arena: *std.heap.ArenaAllocator,
    env: *std.process.Environ.Map,
) std.process.Init {
    return .{
        .minimal = undefined,
        .arena = arena,
        .gpa = allocator,
        .io = io,
        .environ_map = env,
        .preopens = .empty,
    };
}

fn absoluteTestPath(allocator: std.mem.Allocator, io: Io, parent: []const u8, child: []const u8) ![]u8 {
    const parent_abs = try Io.Dir.realPathFileAlloc(Io.Dir.cwd(), io, parent, allocator);
    defer allocator.free(parent_abs);
    return std.fs.path.join(allocator, &.{ parent_abs, child });
}

fn findTool(allocator: std.mem.Allocator, io: Io, candidates: []const []const u8) ![]const u8 {
    for (candidates) |candidate| {
        const result = std.process.run(allocator, io, .{
            .argv = &.{ candidate, "-V" },
            .stdout_limit = .limited(256 * 1024),
            .stderr_limit = .limited(256 * 1024),
        }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) return allocator.dupe(u8, candidate),
            else => {},
        }
    }
    return error.SkipZigTest;
}

fn debugfsCat(
    allocator: std.mem.Allocator,
    io: Io,
    debugfs: []const u8,
    image: []const u8,
    path: []const u8,
) ![]u8 {
    const command = try std.fmt.allocPrint(allocator, "cat {s}", .{path});
    defer allocator.free(command);
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ debugfs, "-R", command, image },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        allocator.free(result.stdout);
        return error.DebugfsFailed;
    }
    return result.stdout;
}

fn runE2fsck(allocator: std.mem.Allocator, io: Io, path: []const u8) !void {
    const candidates = [_][]const u8{
        "/opt/homebrew/opt/e2fsprogs/sbin/e2fsck",
        "e2fsck",
    };
    for (candidates) |candidate| {
        const result = std.process.run(allocator, io, .{
            .argv = &.{ candidate, "-f", "-n", path },
            .stdout_limit = .limited(256 * 1024),
            .stderr_limit = .limited(256 * 1024),
        }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) return,
            else => {},
        }
        if (result.stdout.len != 0) std.debug.print("{s}\n", .{result.stdout});
        if (result.stderr.len != 0) std.debug.print("{s}\n", .{result.stderr});
        return error.E2fsckFailed;
    }
    return error.E2fsckMissing;
}

fn writeTestTar(allocator: std.mem.Allocator, io: Io, path: []const u8, name: []const u8, data: []const u8) !void {
    var tar_bytes = std.ArrayList(u8).empty;
    defer tar_bytes.deinit(allocator);
    try tar_bytes.appendNTimes(allocator, 0, 512);
    writeTestTarHeader(tar_bytes.items[0..512], name, '0', data.len);
    try tar_bytes.appendSlice(allocator, data);
    const padding = (512 - (data.len % 512)) % 512;
    try tar_bytes.appendNTimes(allocator, 0, padding + 1024);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = tar_bytes.items });
}

fn writeTestTarHeader(header: []u8, name: []const u8, kind: u8, size: u64) void {
    std.debug.assert(header.len == 512);
    std.debug.assert(name.len <= 100);
    @memset(header, 0);
    @memcpy(header[0..name.len], name);
    writeTestTarOctal(header[100..108], if (kind == '5') 0o755 else 0o644);
    writeTestTarOctal(header[108..116], 0);
    writeTestTarOctal(header[116..124], 0);
    writeTestTarOctal(header[124..136], size);
    writeTestTarOctal(header[136..148], 0);
    @memset(header[148..156], ' ');
    header[156] = kind;
    @memcpy(header[257..263], "ustar\x00");
    @memcpy(header[263..265], "00");
    var sum: u64 = 0;
    for (header[0..512]) |b| sum += b;
    writeTestTarOctal(header[148..156], sum);
}

fn writeTestTarOctal(field: []u8, value: u64) void {
    @memset(field, 0);
    var remaining = value;
    var index = field.len - 2;
    while (true) {
        field[index] = @intCast('0' + (remaining & 7));
        remaining >>= 3;
        if (remaining == 0 or index == 0) break;
        index -= 1;
    }
}
