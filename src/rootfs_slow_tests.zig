const std = @import("std");

const ext4 = @import("rootfs/ext4.zig");
const ext4_writer = @import("rootfs/ext4_writer.zig");
const local_image = @import("local_image.zig");
const local_paths = @import("local_paths.zig");
const rootfs = @import("rootfs.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const xattrs_mod = @import("rootfs/xattrs.zig");
const spore = @import("spore.zig");

const Io = std.Io;

const min_native_image_size: u64 = 16 << 20;
const resolver_placeholder_path = "etc/resolv.conf";
const resolver_placeholder_bytes =
    "# SporeVM generated placeholder; --net bind-mounts the guest resolver here.\n";
const debugfs_candidates = [_][]const u8{
    "/opt/homebrew/opt/e2fsprogs/sbin/debugfs",
    "debugfs",
};

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
    const first_digest = try ext4.blake3File(io, path_a);
    const second_digest = try ext4.blake3File(io, path_b);
    try std.testing.expectEqualSlices(u8, &first_digest, &second_digest);
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
    _ = try ext4_writer.emit(allocator, io, path, &entries, .{
        .image_size = min_native_image_size,
        .inode_count = 1024,
        .determinism = ext4.Determinism.fromDigest("sha256:test-native-ext4-symlink-boundary"),
    });
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
    _ = try ext4_writer.emit(allocator, io, path, &entries, .{
        .image_size = 32 << 20,
        .inode_count = 1024,
        .determinism = ext4.Determinism.fromDigest("sha256:test-native-ext4-double-indirect"),
    });
    try runE2fsck(allocator, io, path);
}

test "native ext4 writer maps a file through triple-indirect blocks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-native-ext4-triple-indirect";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    const debugfs = try findTool(allocator, io, &debugfs_candidates);
    defer allocator.free(debugfs);

    // Direct, single, and double indirect pointers reach 12 + 1024 + 1024^2
    // blocks, just over 4 GiB. The last two blocks need the triple tree.
    const block_size = ext4.rootfs_ext4_block_size;
    const double_reach: u64 = 12 + 1024 + 1024 * 1024;
    const size: u64 = (double_reach + 1) * block_size + 100;
    const markers = [_]struct { block: u64, bytes: []const u8 }{
        .{ .block = 0, .bytes = "first block" },
        .{ .block = double_reach - 1, .bytes = "last double-indirect block" },
        .{ .block = double_reach, .bytes = "first triple-indirect block" },
        .{ .block = double_reach + 1, .bytes = "partial tail" },
    };

    // Only the marker blocks of the source occupy disk.
    const source_path = try allocator.dupe(u8, tmp ++ "/source.bin");
    defer allocator.free(source_path);
    {
        var source = try Io.Dir.cwd().createFile(io, source_path, .{});
        defer source.close(io);
        try source.setLength(io, size);
        for (markers) |marker| try source.writePositionalAll(io, marker.bytes, marker.block * block_size);
    }

    const image_path = tmp ++ "/image.ext4";
    const entries = [_]ext4_writer.Entry{.{
        .path = "big.bin",
        .kind = .{ .file_source = .{ .file = .{ .path = source_path, .offset = 0, .size = size } } },
    }};
    _ = try ext4_writer.emit(allocator, io, image_path, &entries, .{
        .image_size = ext4.computeImageSize(size),
        .inode_count = 1024,
        .determinism = ext4.Determinism.fromDigest("sha256:test-native-ext4-triple-indirect"),
    });
    try runE2fsck(allocator, io, image_path);

    const stat = try runDebugfs(allocator, io, debugfs, image_path, "stat /big.bin");
    defer allocator.free(stat);
    const expected_size = std.fmt.comptimePrint("Size: {d}\n", .{size});
    try std.testing.expect(std.mem.indexOf(u8, stat, expected_size) != null);

    var image = try Io.Dir.cwd().openFile(io, image_path, .{});
    defer image.close(io);
    for (markers) |marker| {
        const command = try std.fmt.allocPrint(allocator, "bmap /big.bin {d}", .{marker.block});
        defer allocator.free(command);
        const output = try runDebugfs(allocator, io, debugfs, image_path, command);
        defer allocator.free(output);
        const physical = try std.fmt.parseInt(u64, std.mem.trim(u8, output, " \n"), 10);
        var bytes: [64]u8 = undefined;
        const read = try image.readPositionalAll(io, bytes[0..marker.bytes.len], physical * block_size);
        try std.testing.expectEqualStrings(marker.bytes, bytes[0..read]);
    }
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
    _ = try ext4_writer.emit(allocator, io, path, &entries, .{
        .image_size = min_native_image_size,
        .inode_count = 1024,
        .determinism = ext4.Determinism.fromDigest("sha256:test-native-ext4-hardlink-order"),
    });
    try runE2fsck(allocator, io, path);
}

test "imported tar rootfs is a complete local image" {
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
    });

    try expectCompleteRootfsStorage(import_allocator, io, cache_root, result.rootfs_storage);
    const local = (try local_image.load(io, import_allocator, cache_root, result.image_manifest_digest)).?;
    try std.testing.expectEqualStrings(result.rootfs_storage.index_digest, local.storage.index_digest);
    try std.testing.expectEqualStrings(rootfs.builder_version, local.oci.?.builder_version);
}

test "native ext4 image from a representative tar passes e2fsck and reads back" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/test-rootfs-native-differential";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    const debugfs = try findTool(allocator, io, &debugfs_candidates);
    defer allocator.free(debugfs);

    // Tar import rejects device, fifo, and sparse entries, so the zero-run
    // file stands in for sparse content.
    const big = try allocator.alloc(u8, 5 * 1024 * 1024 + 123);
    defer allocator.free(big);
    for (big, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% (i >> 12));
    const zeros = try allocator.alloc(u8, 2 * 1024 * 1024);
    defer allocator.free(zeros);
    @memset(zeros, 0);
    const slow_target = "../" ++ "long-symlink-target/" ** 4 ++ "hostname";
    // VFS_CAP_REVISION_2, effective, permitted CAP_NET_RAW.
    const cap = [_]u8{ 1, 0, 0, 2, 0, 0x20, 0, 0 } ++ [_]u8{0} ** 12;
    const pax = try testPaxRecord(allocator, "SCHILY.xattr." ++ xattrs_mod.security_capability_name, &cap);
    defer allocator.free(pax);

    const layer_path = tmp ++ "/rootfs.tar";
    {
        var tar_bytes = std.ArrayList(u8).empty;
        defer tar_bytes.deinit(allocator);
        const entries = [_]TestTarEntry{
            .{ .name = "etc", .kind = '5', .mode = 0o755 },
            .{ .name = "etc/hostname", .data = "spore\n", .mode = 0o640, .uid = 1000, .gid = 1001 },
            .{ .name = "etc/hostname-hard", .kind = '1', .link = "etc/hostname", .uid = 1000, .gid = 1001 },
            .{ .name = "bin", .kind = '5', .mode = 0o750 },
            .{ .name = "bin/fast-link", .kind = '2', .link = "../etc/hostname" },
            .{ .name = "bin/slow-link", .kind = '2', .link = slow_target },
            .{ .name = "usr/bin/ping", .kind = 'x', .data = pax },
            .{ .name = "usr/bin/ping", .data = "#!/bin/true\n", .mode = 0o755 },
            .{ .name = "var/big.bin", .data = big },
            .{ .name = "var/zeros.bin", .data = zeros },
        };
        for (entries) |entry| try appendTestTarEntry(allocator, &tar_bytes, entry);
        try tar_bytes.appendNTimes(allocator, 0, 1024);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = layer_path, .data = tar_bytes.items });
    }

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
        .ref = "local/native-differential:latest",
    });
    const image = try local_image.flatPath(import_allocator, cache_root, result.image_manifest_digest);
    try runE2fsck(allocator, io, image);

    const stats = [_]struct { path: []const u8, needles: []const []const u8 }{
        .{ .path = "/etc/hostname", .needles = &.{ "Type: regular    Mode:  0640", "User:  1000   Group:  1001", "Size: 6\n", "Links: 2" } },
        .{ .path = "/bin", .needles = &.{"Type: directory    Mode:  0750"} },
        .{ .path = "/bin/fast-link", .needles = &.{ "Type: symlink", "Fast link dest: \"../etc/hostname\"" } },
        .{ .path = "/bin/slow-link", .needles = &.{ "Type: symlink", std.fmt.comptimePrint("Size: {d}\n", .{slow_target.len}) } },
        .{ .path = "/usr/bin/ping", .needles = &.{"Type: regular    Mode:  0755"} },
        .{ .path = "/tmp", .needles = &.{"Type: directory    Mode:  01777"} },
        .{ .path = "/var/big.bin", .needles = &.{std.fmt.comptimePrint("Size: {d}\n", .{5 * 1024 * 1024 + 123})} },
    };
    for (stats) |expected| {
        const command = try std.fmt.allocPrint(allocator, "stat {s}", .{expected.path});
        defer allocator.free(command);
        const output = try runDebugfs(allocator, io, debugfs, image, command);
        defer allocator.free(output);
        for (expected.needles) |needle| {
            if (std.mem.indexOf(u8, output, needle) == null) {
                std.debug.print("{s}: missing {s} in:\n{s}\n", .{ expected.path, needle, output });
                return error.TestUnexpectedResult;
            }
        }
    }

    const target_stat = try runDebugfs(allocator, io, debugfs, image, "stat /etc/hostname");
    defer allocator.free(target_stat);
    const hard_stat = try runDebugfs(allocator, io, debugfs, image, "stat /etc/hostname-hard");
    defer allocator.free(hard_stat);
    try std.testing.expectEqualStrings(try debugfsStatInode(target_stat), try debugfsStatInode(hard_stat));

    const cats = [_]struct { path: []const u8, data: []const u8 }{
        .{ .path = "/etc/hostname", .data = "spore\n" },
        .{ .path = "/bin/slow-link", .data = slow_target },
        .{ .path = "/" ++ resolver_placeholder_path, .data = resolver_placeholder_bytes },
        .{ .path = "/var/big.bin", .data = big },
        .{ .path = "/var/zeros.bin", .data = zeros },
    };
    const dump_path = try absoluteTestPath(allocator, io, tmp, "dump.out");
    defer allocator.free(dump_path);
    for (cats) |expected| {
        Io.Dir.cwd().deleteFile(io, dump_path) catch {};
        const command = try std.fmt.allocPrint(allocator, "dump {s} {s}", .{ expected.path, dump_path });
        defer allocator.free(command);
        allocator.free(try runDebugfs(allocator, io, debugfs, image, command));
        const dumped = try Io.Dir.cwd().readFileAlloc(io, dump_path, allocator, .limited(big.len + 1));
        defer allocator.free(dumped);
        try std.testing.expectEqualSlices(u8, expected.data, dumped);
    }

    const xattr_path = try absoluteTestPath(allocator, io, tmp, "xattr.out");
    defer allocator.free(xattr_path);
    const xattr_command = try std.fmt.allocPrint(allocator, "ea_get -f {s} /usr/bin/ping " ++ xattrs_mod.security_capability_name, .{xattr_path});
    defer allocator.free(xattr_command);
    allocator.free(try runDebugfs(allocator, io, debugfs, image, xattr_command));
    const xattr = try Io.Dir.cwd().readFileAlloc(io, xattr_path, allocator, .limited(64));
    defer allocator.free(xattr);
    try std.testing.expectEqualSlices(u8, &cap, xattr);
}

fn expectCompleteRootfsStorage(
    allocator: std.mem.Allocator,
    io: Io,
    cache_root: []const u8,
    storage: spore.RootfsStorage,
) !void {
    try spore.validateRootfsStorageDescriptor(storage);
    try std.testing.expect(try rootfs_cas.storageContentComplete(io, allocator, cache_root, storage));
    try std.testing.expect(try rootfs_cas.storageMarkedComplete(io, allocator, cache_root, storage));
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

fn runDebugfs(
    allocator: std.mem.Allocator,
    io: Io,
    debugfs: []const u8,
    image: []const u8,
    request: []const u8,
) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ debugfs, "-R", request, image },
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
    try appendTestTarEntry(allocator, &tar_bytes, .{ .name = name, .data = data });
    try tar_bytes.appendNTimes(allocator, 0, 1024);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = tar_bytes.items });
}

const TestTarEntry = struct {
    name: []const u8,
    kind: u8 = '0',
    data: []const u8 = "",
    link: []const u8 = "",
    mode: u32 = 0o644,
    uid: u32 = 0,
    gid: u32 = 0,
};

fn appendTestTarEntry(allocator: std.mem.Allocator, tar_bytes: *std.ArrayList(u8), entry: TestTarEntry) !void {
    std.debug.assert(entry.name.len <= 100 and entry.link.len <= 100);
    var header = [_]u8{0} ** 512;
    @memcpy(header[0..entry.name.len], entry.name);
    writeTestTarOctal(header[100..108], entry.mode);
    writeTestTarOctal(header[108..116], entry.uid);
    writeTestTarOctal(header[116..124], entry.gid);
    writeTestTarOctal(header[124..136], entry.data.len);
    writeTestTarOctal(header[136..148], 0);
    @memset(header[148..156], ' ');
    header[156] = entry.kind;
    @memcpy(header[157 .. 157 + entry.link.len], entry.link);
    @memcpy(header[257..263], "ustar\x00");
    @memcpy(header[263..265], "00");
    var sum: u64 = 0;
    for (header) |b| sum += b;
    writeTestTarOctal(header[148..156], sum);
    try tar_bytes.appendSlice(allocator, &header);
    try tar_bytes.appendSlice(allocator, entry.data);
    try tar_bytes.appendNTimes(allocator, 0, (512 - (entry.data.len % 512)) % 512);
}

fn testPaxRecord(allocator: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
    const body_len = 1 + key.len + 1 + value.len + 1;
    var total = body_len + 1;
    while (body_len + std.fmt.count("{d}", .{total}) != total) total = body_len + std.fmt.count("{d}", .{total});
    return std.fmt.allocPrint(allocator, "{d} {s}={s}\n", .{ total, key, value });
}

fn debugfsStatInode(output: []const u8) ![]const u8 {
    const prefix = "Inode: ";
    if (!std.mem.startsWith(u8, output, prefix)) return error.TestUnexpectedResult;
    const rest = output[prefix.len..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len];
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
