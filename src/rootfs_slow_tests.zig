const std = @import("std");
const TestDir = @import("test_dir.zig").TestDir;

const ext4 = @import("rootfs/ext4.zig");
const ext4_writer = @import("rootfs/ext4_writer.zig");
const local_image = @import("local_image.zig");
const local_paths = @import("local_paths.zig");
const rootfs = @import("rootfs.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const xattrs_mod = @import("rootfs/xattrs.zig");
const spore = @import("spore.zig");
const test_support = @import("test_support.zig");

const Io = std.Io;

const min_native_image_size: u64 = 16 << 20;
const resolver_placeholder_path = "etc/resolv.conf";
const resolver_placeholder_bytes =
    "# SporeVM generated placeholder; --net bind-mounts the guest resolver here.\n";
const debugfs_candidates = [_][]const u8{
    "/opt/homebrew/opt/e2fsprogs/sbin/debugfs",
    "debugfs",
    "/usr/sbin/debugfs",
};

test "native ext4 writer emits deterministic fsck-clean image" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const path_a = try tmp_dir.path("a.img");
    const path_b = try tmp_dir.path("b.img");

    var cap = [_]u8{ 1, 0, 0, 2 } ++ @as([16]u8, @splat(0));
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
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const path = try tmp_dir.path("multigroup.img");

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
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const path = try tmp_dir.path("symlink-boundary.img");

    const prefix = "/usr/share/ca-certificates/mozilla/";
    const target_59 = prefix ++ test_support.repeat("a", (59 - prefix.len));
    const target_60 = prefix ++ test_support.repeat("b", (60 - prefix.len));
    const target_61 = prefix ++ test_support.repeat("c", (61 - prefix.len));

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

test "native ext4 writer supports multi-megabyte regular files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const path = try tmp_dir.path("large-file.img");

    const data = try allocator.alloc(u8, 5 * 1024 * 1024);
    defer allocator.free(data);
    for (data, 0..) |*byte, i| byte.* = @truncate(i);

    const entries = [_]ext4_writer.Entry{
        .{ .path = "var/big.bin", .kind = .{ .file = data }, .mode = 0o644 },
    };
    _ = try ext4_writer.emit(allocator, io, path, &entries, .{
        .image_size = 32 << 20,
        .inode_count = 1024,
        .determinism = ext4.Determinism.fromDigest("sha256:test-native-ext4-large-file"),
    });
    try runE2fsck(allocator, io, path);
}

test "native ext4 writer maps extent files beyond four GiB" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const debugfs = try findTool(allocator, io, &debugfs_candidates);
    defer allocator.free(debugfs);

    // Cross both the 32-bit size boundary and enough block groups to need
    // an external extent leaf. Only marker blocks occupy source storage.
    const block_size = ext4.rootfs_ext4_block_size;
    const boundary: u64 = (@as(u64, 4) << 30) / block_size;
    const size: u64 = (boundary + 1) * block_size + 100;
    const markers = [_]struct { block: u64, bytes: []const u8 }{
        .{ .block = 0, .bytes = "first block" },
        .{ .block = boundary - 1, .bytes = "before four GiB" },
        .{ .block = boundary, .bytes = "after four GiB" },
        .{ .block = boundary + 1, .bytes = "partial tail" },
    };

    // Only the marker blocks of the source occupy disk.
    const source_path = try allocator.dupe(u8, try tmp_dir.path("source.bin"));
    defer allocator.free(source_path);
    {
        var source = try Io.Dir.cwd().createFile(io, source_path, .{});
        defer source.close(io);
        try source.setLength(io, size);
        for (markers) |marker| try source.writePositionalAll(io, marker.bytes, marker.block * block_size);
    }

    const image_path = try tmp_dir.path("image.ext4");
    const entries = [_]ext4_writer.Entry{.{
        .path = "big.bin",
        .kind = .{ .file_source = .{ .file = .{ .path = source_path, .offset = 0, .size = size } } },
    }};
    _ = try ext4_writer.emit(allocator, io, image_path, &entries, .{
        .image_size = ext4.computeImageSize(size),
        .inode_count = 1024,
        .determinism = ext4.Determinism.fromDigest("sha256:test-native-ext4-extent-large"),
    });
    try runE2fsck(allocator, io, image_path);

    const stat = try runDebugfs(allocator, io, debugfs, image_path, "stat /big.bin");
    defer allocator.free(stat);
    const expected_size = std.fmt.comptimePrint("Size: {d}\n", .{size});
    try std.testing.expect(std.mem.indexOf(u8, stat, expected_size) != null);
    try std.testing.expect(std.mem.indexOf(u8, stat, "EXTENTS:") != null);

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

test "native ext4 writer emits deterministic fsck-clean multi-level htrees" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const path = try allocator.dupe(u8, try tmp_dir.path("indexed.img"));
    defer allocator.free(path);
    const second_path = try tmp_dir.path("indexed-again.img");
    const debugfs = try findTool(allocator, io, &debugfs_candidates);
    defer allocator.free(debugfs);

    // Long, non-ASCII names cross the 508-leaf root capacity without a
    // huge fixture. e2fsck independently checks every hash range and dirent.
    const entries = try a.alloc(ext4_writer.Entry, 9000);
    for (entries, 0..) |*entry, i| entry.* = .{
        .path = try std.fmt.allocPrint(a, "wide/{s}-{d:0>5}-é", .{ test_support.repeat("x", 230), i }),
        .kind = .{ .file = "indexed content\n" },
    };
    const opts: ext4_writer.Options = .{
        .image_size = 128 << 20,
        .inode_count = 12_000,
        .determinism = ext4.Determinism.fromDigest("sha256:htree-conformance"),
    };
    _ = try ext4_writer.emit(allocator, io, path, entries, opts);
    _ = try ext4_writer.emit(allocator, io, second_path, entries, opts);
    try std.testing.expectEqualSlices(u8, &(try ext4.blake3File(io, path)), &(try ext4.blake3File(io, second_path)));
    try runE2fsck(allocator, io, path);
    const index = try runDebugfs(allocator, io, debugfs, path, "htree_dump /wide");
    defer allocator.free(index);
    try std.testing.expect(std.mem.indexOf(u8, index, "Indirect levels: 1") != null);
    for ([_]usize{ 0, 4499, 8999 }) |i| {
        const request = try std.fmt.allocPrint(a, "cat /{s}", .{entries[i].path});
        const bytes = try runDebugfs(allocator, io, debugfs, path, request);
        defer allocator.free(bytes);
        try std.testing.expectEqualStrings("indexed content\n", bytes);
    }
}

test "native ext4 writer resolves hardlinks after sorted targets" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const path = try tmp_dir.path("hardlink-order.img");

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
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const tmp = tmp_dir.root;

    const layer_path = try tmp_dir.path("rootfs.tar");
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
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const tmp = tmp_dir.root;
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
    const slow_target = "../" ++ test_support.repeat("long-symlink-target/", 4) ++ "hostname";
    // VFS_CAP_REVISION_2, effective, permitted CAP_NET_RAW.
    const cap = [_]u8{ 1, 0, 0, 2, 0, 0x20, 0, 0 } ++ @as([12]u8, @splat(0));
    const pax = try testPaxRecord(allocator, "SCHILY.xattr." ++ xattrs_mod.security_capability_name, &cap);
    defer allocator.free(pax);

    const layer_path = try tmp_dir.path("rootfs.tar");
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

test "native ext4 writer trees match debugfs listings and contents" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = try TestDir.init();
    defer tmp_dir.deinit();
    const debugfs = try findTool(allocator, io, &debugfs_candidates);
    defer allocator.free(debugfs);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every entry kind, owners, special mode bits, an xattr, fast and slow
    // symlinks, an empty directory, and one inode with three names in two
    // directories.
    var cap = [_]u8{ 1, 0, 0, 2, 0, 0x20, 0, 0 } ++ @as([12]u8, @splat(0));
    const attrs = [_]xattrs_mod.Attribute{.{ .name = xattrs_mod.security_capability_name, .value = &cap }};
    const mixed = [_]ext4_writer.Entry{
        .{ .path = "bin", .kind = .directory, .mode = 0o755 },
        .{ .path = "bin/ping", .kind = .{ .file = "ping\n" }, .mode = 0o755, .xattrs = &attrs },
        .{ .path = "bin/su", .kind = .{ .file = "su\n" }, .mode = 0o4755 },
        .{ .path = "dev", .kind = .directory, .mode = 0o755 },
        .{ .path = "dev/null", .kind = .{ .device = .{ .kind = .char, .major = 1, .minor = 3 } }, .mode = 0o666 },
        .{ .path = "dev/vda", .kind = .{ .device = .{ .kind = .block, .major = 254, .minor = 0 } }, .mode = 0o660, .gid = 6 },
        .{ .path = "etc", .kind = .directory, .mode = 0o755 },
        .{ .path = "etc/empty", .kind = .{ .file = "" } },
        .{ .path = "etc/shared", .kind = .{ .file = "shared\n" }, .mode = 0o640, .uid = 1000, .gid = 1001 },
        .{ .path = "etc/shared-2", .kind = .{ .hardlink = "etc/shared" } },
        .{ .path = "home", .kind = .directory, .mode = 0o700, .uid = 1000, .gid = 1000 },
        .{ .path = "home/fast", .kind = .{ .symlink = "../etc/shared" }, .uid = 1000, .gid = 1000 },
        .{ .path = "home/shared-3", .kind = .{ .hardlink = "etc/shared" } },
        .{ .path = "home/slow", .kind = .{ .symlink = "../" ++ test_support.repeat("s", 70) } },
        .{ .path = "run", .kind = .directory, .mode = 0o755 },
        .{ .path = "run/fifo", .kind = .fifo, .mode = 0o600 },
        .{ .path = "run/socket", .kind = .socket, .mode = 0o755 },
        .{ .path = "srv", .kind = .directory, .mode = 0o1777 },
    };
    try expectDebugfsMatchesEntries(arena, io, debugfs, try tmp_dir.path("mixed"), &mixed, 1024, min_native_image_size);

    // A path 100 directories deep.
    var deep = std.ArrayList(ext4_writer.Entry).empty;
    var deep_path: []const u8 = "level-00";
    for (0..100) |depth| {
        if (depth != 0) deep_path = try std.fmt.allocPrint(arena, "{s}/level-{d:0>2}", .{ deep_path, depth });
        try deep.append(arena, .{ .path = deep_path, .kind = .directory, .mode = 0o755 });
    }
    try deep.append(arena, .{ .path = try std.fmt.allocPrint(arena, "{s}/bottom", .{deep_path}), .kind = .{ .file = "deep\n" } });
    try expectDebugfsMatchesEntries(arena, io, debugfs, try tmp_dir.path("deep"), deep.items, 1024, min_native_image_size);

    // One directory whose entries need more blocks than the 12 direct
    // pointers reach.
    var wide = std.ArrayList(ext4_writer.Entry).empty;
    try wide.append(arena, .{ .path = "wide", .kind = .directory, .mode = 0o755 });
    for (0..1200) |index| {
        const path = try std.fmt.allocPrint(arena, "wide/{d:0>4}{s}", .{ index, test_support.repeat("w", 196) });
        try wide.append(arena, .{ .path = path, .kind = .{ .file = path[path.len - 200 .. path.len - 196] } });
    }
    try expectDebugfsMatchesEntries(arena, io, debugfs, try tmp_dir.path("wide"), wide.items, 2048, min_native_image_size);

    // Source-backed files with holes: one past the direct and single
    // indirect blocks, and one slice at a tar-like payload offset.
    const source_path = try arena.dupe(u8, try tmp_dir.path("sparse-source.bin"));
    const source_size: u64 = 40 << 20;
    {
        var source = try Io.Dir.cwd().createFile(io, source_path, .{});
        defer source.close(io);
        try source.setLength(io, source_size);
        for ([_]u64{ 0, 512, 1036 * 4096, source_size - 7 }) |offset| try source.writePositionalAll(io, "marker!", offset);
    }
    const sparse = [_]ext4_writer.Entry{
        .{ .path = "var", .kind = .directory, .mode = 0o755 },
        .{ .path = "var/sparse.bin", .kind = .{ .file_source = .{ .file = .{ .path = source_path, .offset = 0, .size = source_size } } } },
        .{ .path = "var/slice.bin", .kind = .{ .file_source = .{ .file = .{ .path = source_path, .offset = 512, .size = 10_000 } } } },
    };
    try expectDebugfsMatchesEntries(arena, io, debugfs, try tmp_dir.path("sparse"), &sparse, 1024, 64 << 20);
}

/// Writes `entries` with the native ext4 writer and checks the image with
/// e2fsprogs: e2fsck must pass, `ls -p` must list exactly the entry paths
/// with their type, mode, owner, size, and hard-link inode, and `dump`,
/// `stat`, and `ea_get` must return each file's data, symlink target, device
/// number, and xattr. Parent directories must be listed as entries.
fn expectDebugfsMatchesEntries(
    arena: std.mem.Allocator,
    io: Io,
    debugfs: []const u8,
    dir: []const u8,
    entries: []const ext4_writer.Entry,
    inode_count: u32,
    image_size: u64,
) !void {
    try Io.Dir.cwd().createDirPath(io, dir);
    const image = try std.fmt.allocPrint(arena, "{s}/image.ext4", .{dir});
    _ = try ext4_writer.emit(arena, io, image, entries, .{
        .image_size = image_size,
        .inode_count = inode_count,
        .determinism = ext4.Determinism.fromDigest("sha256:test-native-ext4-debugfs-trees"),
    });
    try runE2fsck(arena, io, image);

    var by_path = std.StringHashMap(ext4_writer.Entry).init(arena);
    var ls_commands = std.ArrayList([]const u8).empty;
    try ls_commands.append(arena, "ls -p /");
    for (entries) |entry| {
        try by_path.put(try std.fmt.allocPrint(arena, "/{s}", .{entry.path}), entry);
        if (entry.kind == .directory) try ls_commands.append(arena, try std.fmt.allocPrint(arena, "ls -p /{s}", .{entry.path}));
    }

    var inodes = std.StringHashMap(u64).init(arena);
    const listings = try runDebugfsScript(arena, io, debugfs, image, dir, ls_commands.items);
    for (ls_commands.items, listings) |command, listing| {
        const parent = command["ls -p ".len..];
        var lines = std.mem.tokenizeScalar(u8, listing, '\n');
        while (lines.next()) |line| {
            // /inode/mode/uid/gid/name/size/
            var fields = std.mem.splitScalar(u8, line, '/');
            _ = fields.next();
            const inode = try std.fmt.parseInt(u64, fields.next() orelse return error.TestUnexpectedResult, 10);
            const mode = try std.fmt.parseInt(u32, fields.next() orelse return error.TestUnexpectedResult, 8);
            const uid = try std.fmt.parseInt(u32, fields.next() orelse return error.TestUnexpectedResult, 10);
            const gid = try std.fmt.parseInt(u32, fields.next() orelse return error.TestUnexpectedResult, 10);
            const name = fields.next() orelse return error.TestUnexpectedResult;
            const size = fields.next() orelse return error.TestUnexpectedResult;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ if (parent.len == 1) "" else parent, name });
            if (std.mem.eql(u8, path, "/lost+found")) continue;

            var entry = by_path.get(path) orelse {
                std.debug.print("unexpected path {s} in {s}\n", .{ path, image });
                return error.TestUnexpectedResult;
            };
            if (entry.kind == .hardlink) entry = by_path.get(try std.fmt.allocPrint(arena, "/{s}", .{entry.kind.hardlink})).?;
            const expected_type: u32, const expected_size: u64 = switch (entry.kind) {
                .directory => .{ 0o040000, 0 },
                .file => |data| .{ 0o100000, data.len },
                .file_source => |source| .{ 0o100000, source.size() },
                .symlink => |target| .{ 0o120000, target.len },
                .device => |device| .{ if (device.kind == .char) 0o020000 else 0o060000, 0 },
                .fifo => .{ 0o010000, 0 },
                .socket => .{ 0o140000, 0 },
                .hardlink => unreachable,
            };
            const expected_mode = expected_type | if (entry.kind == .symlink) 0o777 else entry.mode;
            std.testing.expectEqual(expected_mode, mode) catch |err| {
                std.debug.print("{s}: mode {o}\n", .{ path, mode });
                return err;
            };
            try std.testing.expectEqual(entry.uid, uid);
            try std.testing.expectEqual(entry.gid, gid);
            if (entry.kind != .directory) try std.testing.expectEqual(expected_size, try std.fmt.parseInt(u64, size, 10));
            try inodes.put(path, inode);
        }
    }
    try std.testing.expectEqual(by_path.count(), inodes.count());

    var commands = std.ArrayList([]const u8).empty;
    var expected = std.ArrayList(struct { command: []const u8, dump: ?[]const u8 = null, needle: ?[]const u8 = null, data: []const u8 }).empty;
    for (entries, 0..) |entry, index| {
        if (entry.kind == .hardlink) {
            const target = try std.fmt.allocPrint(arena, "/{s}", .{entry.kind.hardlink});
            try std.testing.expectEqual(inodes.get(target).?, inodes.get(try std.fmt.allocPrint(arena, "/{s}", .{entry.path})).?);
            continue;
        }
        const dump = try std.fmt.allocPrint(arena, "{s}/dump-{d}", .{ dir, index });
        const dump_command = try std.fmt.allocPrint(arena, "dump /{s} {s}", .{ entry.path, dump });
        const stat_command = try std.fmt.allocPrint(arena, "stat /{s}", .{entry.path});
        switch (entry.kind) {
            .file => |data| if (data.len != 0) try expected.append(arena, .{ .command = dump_command, .dump = dump, .data = data }),
            .file_source => |source| {
                const data = try arena.alloc(u8, @intCast(source.size()));
                var file = try Io.Dir.cwd().openFile(io, source.file.path, .{});
                defer file.close(io);
                try std.testing.expectEqual(data.len, try file.readPositionalAll(io, data, source.file.offset));
                try expected.append(arena, .{ .command = dump_command, .dump = dump, .data = data });
            },
            .symlink => |target| if (target.len < 60)
                try expected.append(arena, .{ .command = stat_command, .needle = try std.fmt.allocPrint(arena, "Fast link dest: \"{s}\"", .{target}), .data = "" })
            else
                try expected.append(arena, .{ .command = dump_command, .dump = dump, .data = target }),
            .device => |device| try expected.append(arena, .{
                .command = stat_command,
                .needle = try std.fmt.allocPrint(arena, "Device major/minor number: {d:0>2}:{d:0>2}", .{ device.major, device.minor }),
                .data = "",
            }),
            else => {},
        }
        for (entry.xattrs) |attr| {
            const out = try std.fmt.allocPrint(arena, "{s}/xattr-{d}", .{ dir, index });
            try expected.append(arena, .{
                .command = try std.fmt.allocPrint(arena, "ea_get -f {s} /{s} {s}", .{ out, entry.path, attr.name }),
                .dump = out,
                .data = attr.value,
            });
        }
    }
    for (expected.items) |item| try commands.append(arena, item.command);
    const outputs = try runDebugfsScript(arena, io, debugfs, image, dir, commands.items);
    for (expected.items, outputs) |item, output| {
        if (item.needle) |needle| {
            if (std.mem.indexOf(u8, output, needle) == null) {
                std.debug.print("{s}: missing {s} in:\n{s}\n", .{ item.command, needle, output });
                return error.TestUnexpectedResult;
            }
        }
        if (item.dump) |path| {
            const data = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(item.data.len + 1));
            std.testing.expectEqualSlices(u8, item.data, data) catch |err| {
                std.debug.print("{s}: contents differ\n", .{item.command});
                return err;
            };
        }
    }
}

/// Runs `commands` in one debugfs process and returns each command's output.
fn runDebugfsScript(
    arena: std.mem.Allocator,
    io: Io,
    debugfs: []const u8,
    image: []const u8,
    dir: []const u8,
    commands: []const []const u8,
) ![]const []const u8 {
    const script_path = try std.fmt.allocPrint(arena, "{s}/debugfs.commands", .{dir});
    var script: Io.Writer.Allocating = .init(arena);
    for (commands) |command| {
        try script.writer.writeAll(command);
        try script.writer.writeByte('\n');
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = script.written() });
    const result = try std.process.run(arena, io, .{
        .argv = &.{ debugfs, "-f", script_path, image },
        .stdout_limit = .limited(16 << 20),
        .stderr_limit = .limited(16 << 20),
    });
    switch (result.term) {
        .exited => |code| if (code != 0) return error.DebugfsFailed,
        else => return error.DebugfsFailed,
    }

    // debugfs echoes each command as "debugfs: COMMAND" before its output.
    const outputs = try arena.alloc([]const u8, commands.len);
    var rest = result.stdout;
    for (commands, outputs) |command, *output| {
        const echo = try std.fmt.allocPrint(arena, "debugfs: {s}\n", .{command});
        if (!std.mem.startsWith(u8, rest, echo)) return error.TestUnexpectedResult;
        rest = rest[echo.len..];
        const end = std.mem.indexOf(u8, rest, "debugfs: ") orelse rest.len;
        output.* = rest[0..end];
        rest = rest[end..];
    }
    return outputs;
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
        .stdout_limit = .limited(4 * 1024 * 1024),
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
        "/usr/sbin/e2fsck",
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
    var header = @as([512]u8, @splat(0));
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
