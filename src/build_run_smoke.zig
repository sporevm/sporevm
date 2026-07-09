//! Gated VM smoke for the `spore build` RUN/COPY executor.
//!
//! Run with `zig build spore-build-run-smoke`. This is intentionally outside
//! plain `zig build test` because it boots a real VM.

const std = @import("std");
const spore_internal = @import("spore_internal");

const build_mod = spore_internal.build;
const ext4 = spore_internal.rootfs_ext4;
const ext4_writer = spore_internal.rootfs.ext4_writer;
const local_paths = spore_internal.local_paths;
const rootfs = spore_internal.rootfs;
const rootfs_cas = spore_internal.rootfs_cas;
const spore = spore_internal.spore;

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) {
        std.debug.print("usage: build-run-smoke <aarch64-linux-sh-helper>\n", .{});
        return error.InvalidArguments;
    }

    const tmp = "zig-cache/spore-build-run-smoke";
    const context_dir = tmp ++ "/context";
    const cache_dir = tmp ++ "/rootfs-cache";
    const runtime_dir = tmp ++ "/runtime";
    const rootfs_path = tmp ++ "/base.ext4";
    const dockerfile_path = context_dir ++ "/Dockerfile";
    const io = init.io;

    Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, context_dir);
    try Io.Dir.cwd().createDirPath(io, cache_dir);
    try Io.Dir.cwd().createDirPath(io, runtime_dir);
    try writeSmokeContext(allocator, io, context_dir, "beta\n");

    try init.environ_map.put(local_paths.rootfs_cache_env, cache_dir);
    try init.environ_map.put(local_paths.runtime_dir_env, runtime_dir);

    const cache_root = try local_paths.rootfsCacheRootPath(allocator, init.environ_map);
    const shell_bytes = try Io.Dir.cwd().readFileAlloc(io, args[1], allocator, .limited(4 * 1024 * 1024));
    const entries = [_]ext4_writer.Entry{
        .{ .path = "bin", .kind = .directory, .mode = 0o755 },
        .{ .path = "bin/sh", .kind = .{ .file = shell_bytes }, .mode = 0o755 },
        .{ .path = "dev", .kind = .directory, .mode = 0o755 },
        .{ .path = "etc", .kind = .directory, .mode = 0o755 },
        .{ .path = "proc", .kind = .directory, .mode = 0o755 },
        .{ .path = "run", .kind = .directory, .mode = 0o755 },
        .{ .path = "sys", .kind = .directory, .mode = 0o755 },
        .{ .path = "tmp", .kind = .directory, .mode = 0o1777 },
    };
    const emitted = try ext4_writer.emit(allocator, io, rootfs_path, &entries, .{
        .image_size = 16 << 20,
        .inode_count = 1024,
        .determinism = ext4.Determinism.fromDigest("sha256:spore-build-run-smoke-base"),
        .cas_cache_root = cache_root,
        .cas_chunk_size = rootfs_cas.default_chunk_size,
        .cas_seal_workers = 1,
    });
    const preload = emitted.preload_result orelse return error.BadManifest;
    const base_storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload);
    _ = try rootfs.publishIndexedImage(init, allocator, .{
        .ref = "local/build-smoke-base:dev",
        .platform = .{},
        .config = .{ .architecture = "arm64", .os = "linux" },
        .rootfs_storage = base_storage,
    });

    try writeDockerfile(io, dockerfile_path, "step2");
    var first_diag: build_mod.Diagnostic = .{};
    const first = try build_mod.build(init, allocator, .{
        .tag = "local/build-smoke:dev",
        .context_dir = context_dir,
        .dockerfile_path = dockerfile_path,
        .platform = .{},
        .network = .none,
        .disk_headroom = 1 << 20,
        .diagnostic = &first_diag,
    });
    if (first_diag.executor.boot_count != 1) return error.ExpectedOneBuildVmBoot;
    if (first_diag.executor.executed_steps != 6) return error.ExpectedSixBuildSteps;
    if (first.cache_hit) return error.ExpectedFirstBuildCacheMiss;

    var cached_diag: build_mod.Diagnostic = .{};
    const cached = try build_mod.build(init, allocator, .{
        .tag = "local/build-smoke:dev",
        .context_dir = context_dir,
        .dockerfile_path = dockerfile_path,
        .platform = .{},
        .network = .none,
        .disk_headroom = 1 << 20,
        .diagnostic = &cached_diag,
    });
    if (cached_diag.executor.boot_count != 0) return error.ExpectedCachedBuildWithoutBoot;
    if (cached_diag.executor.executed_steps != 0) return error.ExpectedCachedBuildWithoutSteps;
    if (!cached.cache_hit) return error.ExpectedCachedBuildHit;
    if (!std.mem.eql(u8, first.index_digest, cached.index_digest)) return error.ExpectedCachedRootfsIdentity;

    try writeSmokeContext(allocator, io, context_dir, "beta-edited\n");
    var edited_diag: build_mod.Diagnostic = .{};
    const edited = try build_mod.build(init, allocator, .{
        .tag = "local/build-smoke:dev",
        .context_dir = context_dir,
        .dockerfile_path = dockerfile_path,
        .platform = .{},
        .network = .none,
        .disk_headroom = 1 << 20,
        .diagnostic = &edited_diag,
    });
    if (edited_diag.executor.boot_count != 1) return error.ExpectedEditedBuildVmBoot;
    if (edited_diag.executor.executed_steps != 4) return error.ExpectedEditedBuildFourSteps;
    if (edited.cache_hit) return error.ExpectedEditedBuildCacheMiss;
    if (std.mem.eql(u8, first.index_digest, edited.index_digest)) return error.ExpectedEditedRootfsIdentity;

    std.debug.print(
        "spore-build-run-smoke ok: first={s} cached={s} edited={s}\n",
        .{ first.index_digest, cached.index_digest, edited.index_digest },
    );
}

fn writeDockerfile(io: Io, path: []const u8, second_step: []const u8) !void {
    var buf: [256]u8 = undefined;
    const dockerfile = try std.fmt.bufPrint(&buf,
        \\FROM local/build-smoke-base:dev
        \\RUN step1
        \\WORKDIR /work
        \\COPY app app/
        \\COPY merge app/
        \\COPY loose.txt multi/
        \\COPY *.wild wild/
        \\RUN verify-copy
        \\CMD ["/bin/sh","-c","{s}"]
        \\
    , .{second_step});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = dockerfile });
}

fn writeSmokeContext(allocator: std.mem.Allocator, io: Io, context_dir: []const u8, beta: []const u8) !void {
    const app_dir = try std.fs.path.join(allocator, &.{ context_dir, "app" });
    defer allocator.free(app_dir);
    const merge_dir = try std.fs.path.join(allocator, &.{ context_dir, "merge" });
    defer allocator.free(merge_dir);
    try Io.Dir.cwd().createDirPath(io, app_dir);
    try Io.Dir.cwd().createDirPath(io, merge_dir);

    const app_a_txt = try std.fs.path.join(allocator, &.{ context_dir, "app/a.txt" });
    defer allocator.free(app_a_txt);
    const app_mode_txt = try std.fs.path.join(allocator, &.{ context_dir, "app/mode.txt" });
    defer allocator.free(app_mode_txt);
    const app_link = try std.fs.path.join(allocator, &.{ context_dir, "app/link" });
    defer allocator.free(app_link);
    const merge_a_txt = try std.fs.path.join(allocator, &.{ context_dir, "merge/a.txt" });
    defer allocator.free(merge_a_txt);
    const merge_b_txt = try std.fs.path.join(allocator, &.{ context_dir, "merge/b.txt" });
    defer allocator.free(merge_b_txt);
    const loose_txt = try std.fs.path.join(allocator, &.{ context_dir, "loose.txt" });
    defer allocator.free(loose_txt);
    const one_wild = try std.fs.path.join(allocator, &.{ context_dir, "one.wild" });
    defer allocator.free(one_wild);
    const two_wild = try std.fs.path.join(allocator, &.{ context_dir, "two.wild" });
    defer allocator.free(two_wild);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = app_a_txt, .data = "alpha\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = app_mode_txt, .data = "mode\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = merge_a_txt, .data = "merged\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = merge_b_txt, .data = beta });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = loose_txt, .data = "loose\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = one_wild, .data = "one\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = two_wild, .data = "two\n" });
    const app_a = try std.fs.path.joinZ(allocator, &.{ context_dir, "app/a.txt" });
    defer allocator.free(app_a);
    if (std.c.chmod(app_a, 0o640) != 0) return error.IoFailed;
    const mode_file = try std.fs.path.joinZ(allocator, &.{ context_dir, "app/mode.txt" });
    defer allocator.free(mode_file);
    if (std.c.chmod(mode_file, 0o640) != 0) return error.IoFailed;
    Io.Dir.cwd().deleteFile(io, app_link) catch {};
    try Io.Dir.cwd().symLink(io, "a.txt", app_link, .{});
}
