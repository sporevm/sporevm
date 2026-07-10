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
    if (args.len < 2 or args.len > 3) {
        std.debug.print("usage: build-run-smoke <aarch64-linux-sh-helper> [--large-copy]\n", .{});
        return error.InvalidArguments;
    }
    const large_copy = args.len == 3 and std.mem.eql(u8, args[2], "--large-copy");
    if (args.len == 3 and !large_copy) return error.InvalidArguments;

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
    const base_image_size: u64 = if (large_copy) 6 * 1024 * 1024 * 1024 else 16 << 20;
    const emitted = try ext4_writer.emit(allocator, io, rootfs_path, &entries, .{
        .image_size = base_image_size,
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

    if (large_copy) {
        try runLargeCopySmoke(init, allocator, io, context_dir, dockerfile_path);
        return;
    }

    try writeDockerfile(io, dockerfile_path, "step2");
    var first_diag: build_mod.Diagnostic = .{};
    const first = try build_mod.build(init, allocator, .{
        .tag = "local/build-smoke:dev",
        .context_dir = context_dir,
        .dockerfile_path = dockerfile_path,
        .platform = .{},
        .network = .none,
        .diagnostic = &first_diag,
    });
    if (first_diag.executor.boot_count != 1) return error.ExpectedOneBuildVmBoot;
    if (first_diag.executor.executed_steps != 18) return error.ExpectedEighteenBuildSteps;
    if (first_diag.executor.resize_count != 1) return error.ExpectedOneBuildResize;
    if (first_diag.executor.max_checkpoint_control_ms >= 2000) return error.BuildCheckpointControlTooSlow;
    if (first.cache_hit) return error.ExpectedFirstBuildCacheMiss;
    if (!first_diag.context_disk.emitted) return error.ExpectedFirstContextDiskEmit;
    if (first_diag.context_disk.reused) return error.ExpectedFirstContextDiskNotReused;

    var cached_diag: build_mod.Diagnostic = .{};
    const cached = try build_mod.build(init, allocator, .{
        .tag = "local/build-smoke:dev",
        .context_dir = context_dir,
        .dockerfile_path = dockerfile_path,
        .platform = .{},
        .network = .none,
        .diagnostic = &cached_diag,
    });
    if (cached_diag.executor.boot_count != 0) return error.ExpectedCachedBuildWithoutBoot;
    if (cached_diag.executor.executed_steps != 0) return error.ExpectedCachedBuildWithoutSteps;
    if (cached_diag.executor.resize_count != 0) return error.ExpectedCachedBuildWithoutResize;
    if (!cached.cache_hit) return error.ExpectedCachedBuildHit;
    if (!std.mem.eql(u8, first.index_digest, cached.index_digest)) return error.ExpectedCachedRootfsIdentity;

    var override_diag: build_mod.Diagnostic = .{};
    const override = try build_mod.build(init, allocator, .{
        .tag = "local/build-smoke:dev",
        .context_dir = context_dir,
        .dockerfile_path = dockerfile_path,
        .platform = .{},
        .network = .none,
        .disk_grow_target_override = 64 << 20,
        .diagnostic = &override_diag,
    });
    if (override_diag.executor.boot_count != 1) return error.ExpectedOverrideBuildVmBoot;
    if (override_diag.executor.executed_steps != 18) return error.ExpectedOverrideBuildEighteenSteps;
    if (override_diag.executor.resize_count != 1) return error.ExpectedOverrideBuildOneResize;
    if (override_diag.executor.max_checkpoint_control_ms >= 2000) return error.OverrideBuildCheckpointControlTooSlow;
    if (override.cache_hit) return error.ExpectedOverrideBuildCacheMiss;
    if (std.mem.eql(u8, first.index_digest, override.index_digest)) return error.ExpectedOverrideRootfsIdentity;
    if (!override_diag.context_disk.reused) return error.ExpectedOverrideContextDiskReuse;
    if (!std.mem.eql(u8, first_diag.context_disk.digest, override_diag.context_disk.digest)) return error.ExpectedOverrideContextDiskIdentity;

    var default_after_override_diag: build_mod.Diagnostic = .{};
    const default_after_override = try build_mod.build(init, allocator, .{
        .tag = "local/build-smoke:dev",
        .context_dir = context_dir,
        .dockerfile_path = dockerfile_path,
        .platform = .{},
        .network = .none,
        .diagnostic = &default_after_override_diag,
    });
    if (default_after_override_diag.executor.boot_count != 0) return error.ExpectedDefaultAfterOverrideWithoutBoot;
    if (default_after_override_diag.executor.executed_steps != 0) return error.ExpectedDefaultAfterOverrideWithoutSteps;
    if (default_after_override_diag.executor.resize_count != 0) return error.ExpectedDefaultAfterOverrideWithoutResize;
    if (!default_after_override.cache_hit) return error.ExpectedDefaultAfterOverrideCacheHit;
    if (!std.mem.eql(u8, first.index_digest, default_after_override.index_digest)) return error.ExpectedDefaultAfterOverrideRootfsIdentity;

    try writeSmokeContext(allocator, io, context_dir, "beta-edited\n");
    var edited_diag: build_mod.Diagnostic = .{};
    const edited = build_mod.build(init, allocator, .{
        .tag = "local/build-smoke:dev",
        .context_dir = context_dir,
        .dockerfile_path = dockerfile_path,
        .platform = .{},
        .network = .none,
        .diagnostic = &edited_diag,
    }) catch |err| {
        std.debug.print(
            "edited build failed: err={s} instruction={?s} exit={?d} output={s}\n",
            .{ @errorName(err), edited_diag.executor.instruction, edited_diag.executor.exit_code, edited_diag.executor.output },
        );
        return err;
    };
    if (edited_diag.executor.boot_count != 1) return error.ExpectedEditedBuildVmBoot;
    if (edited_diag.executor.executed_steps != 4) return error.ExpectedEditedBuildFourSteps;
    if (edited_diag.executor.resize_count != 0) return error.ExpectedEditedBuildWithoutResize;
    if (edited_diag.executor.max_checkpoint_control_ms >= 2000) return error.EditedBuildCheckpointControlTooSlow;
    if (edited.cache_hit) return error.ExpectedEditedBuildCacheMiss;
    if (std.mem.eql(u8, first.index_digest, edited.index_digest)) return error.ExpectedEditedRootfsIdentity;
    if (!edited_diag.context_disk.emitted) return error.ExpectedEditedContextDiskEmit;
    if (std.mem.eql(u8, first_diag.context_disk.digest, edited_diag.context_disk.digest)) return error.ExpectedEditedContextDiskIdentity;

    std.debug.print(
        "spore-build-run-smoke ok: first={s} cached={s} override={s} default-after-override={s} edited={s} context-disk-first=emitted:{d}ms context-disk-override=reused:{d}ms context-disk-edited=emitted:{d}ms\n",
        .{
            first.index_digest,
            cached.index_digest,
            override.index_digest,
            default_after_override.index_digest,
            edited.index_digest,
            nsToMs(first_diag.context_disk.emit_ns),
            nsToMs(override_diag.context_disk.emit_ns),
            nsToMs(edited_diag.context_disk.emit_ns),
        },
    );
}

fn runLargeCopySmoke(init: std.process.Init, allocator: std.mem.Allocator, io: Io, context_dir: []const u8, dockerfile_path: []const u8) !void {
    try writeLargeCopyContext(allocator, io, context_dir);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = dockerfile_path,
        .data =
        \\FROM local/build-smoke-base:dev
        \\COPY deps /opt/deps/
        \\RUN verify-large-copy
        \\
        ,
    });

    var diagnostic: build_mod.Diagnostic = .{};
    const result = build_mod.build(init, allocator, .{
        .tag = "local/build-smoke-large-copy:dev",
        .context_dir = context_dir,
        .dockerfile_path = dockerfile_path,
        .platform = .{},
        .network = .none,
        .diagnostic = &diagnostic,
    }) catch |err| {
        std.debug.print(
            "large COPY build failed: err={s} line={d} instruction={?s} exit={?d} output={s}\n",
            .{ @errorName(err), diagnostic.executor.instruction_line, diagnostic.executor.instruction, diagnostic.executor.exit_code, diagnostic.executor.output },
        );
        return err;
    };
    if (diagnostic.executor.boot_count != 1) return error.ExpectedLargeCopyBuildVmBoot;
    if (diagnostic.executor.executed_steps != 2) return error.ExpectedLargeCopyTwoSteps;
    if (diagnostic.executor.resize_count != 1) return error.ExpectedLargeCopyOneResize;
    if (result.cache_hit) return error.ExpectedLargeCopyCacheMiss;
    if (!diagnostic.context_disk.emitted and !diagnostic.context_disk.reused) return error.ExpectedLargeCopyContextDisk;
    std.debug.print(
        "spore-build-large-copy-smoke ok: {s} context-disk={s} entries={d} bytes={d} image={d} emit={d}ms\n",
        .{
            result.index_digest,
            if (diagnostic.context_disk.emitted) "emitted" else "reused",
            diagnostic.context_disk.entries,
            diagnostic.context_disk.bytes,
            diagnostic.context_disk.image_size,
            nsToMs(diagnostic.context_disk.emit_ns),
        },
    );
}

fn nsToMs(ns: u64) u64 {
    return ns / std.time.ns_per_ms;
}

fn writeDockerfile(io: Io, path: []const u8, second_step: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const dockerfile = try std.fmt.bufPrint(&buf,
        \\FROM local/build-smoke-base:dev
        \\RUN verify-clock
        \\RUN verify-dev
        \\RUN spawn-background
        \\RUN verify-background-reaped
        \\RUN step1
        \\WORKDIR /work
        \\RUN setup-symlink-targets
        \\COPY symlink-internal.txt symlinked-dir/internal.txt
        \\COPY absolute-link.txt abs-link/absolute.txt
        \\COPY escape.txt evil/escape.txt
        \\COPY through-file.txt write-file
        \\COPY dir-source dir-link
        \\COPY dangling.txt dangling-file
        \\COPY app app/
        \\COPY merge app/
        \\COPY loose.txt multi
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
    const dir_source = try std.fs.path.join(allocator, &.{ context_dir, "dir-source" });
    defer allocator.free(dir_source);
    const dir_source_empty = try std.fs.path.join(allocator, &.{ context_dir, "dir-source/empty" });
    defer allocator.free(dir_source_empty);
    try Io.Dir.cwd().createDirPath(io, app_dir);
    try Io.Dir.cwd().createDirPath(io, merge_dir);
    try Io.Dir.cwd().createDirPath(io, dir_source_empty);

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
    const symlink_internal_txt = try std.fs.path.join(allocator, &.{ context_dir, "symlink-internal.txt" });
    defer allocator.free(symlink_internal_txt);
    const absolute_link_txt = try std.fs.path.join(allocator, &.{ context_dir, "absolute-link.txt" });
    defer allocator.free(absolute_link_txt);
    const escape_txt = try std.fs.path.join(allocator, &.{ context_dir, "escape.txt" });
    defer allocator.free(escape_txt);
    const through_file_txt = try std.fs.path.join(allocator, &.{ context_dir, "through-file.txt" });
    defer allocator.free(through_file_txt);
    const dir_source_file = try std.fs.path.join(allocator, &.{ context_dir, "dir-source/dir-file.txt" });
    defer allocator.free(dir_source_file);
    const dangling_txt = try std.fs.path.join(allocator, &.{ context_dir, "dangling.txt" });
    defer allocator.free(dangling_txt);
    const one_wild = try std.fs.path.join(allocator, &.{ context_dir, "one.wild" });
    defer allocator.free(one_wild);
    const two_wild = try std.fs.path.join(allocator, &.{ context_dir, "two.wild" });
    defer allocator.free(two_wild);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = app_a_txt, .data = "alpha\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = app_mode_txt, .data = "mode\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = merge_a_txt, .data = "merged\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = merge_b_txt, .data = beta });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = loose_txt, .data = "loose\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = symlink_internal_txt, .data = "internal\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = absolute_link_txt, .data = "absolute\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = escape_txt, .data = "escape\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = through_file_txt, .data = "through\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dir_source_file, .data = "dir\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dangling_txt, .data = "dangling\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = one_wild, .data = "one\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = two_wild, .data = "two\n" });
    const app_a = try std.fs.path.joinZ(allocator, &.{ context_dir, "app/a.txt" });
    defer allocator.free(app_a);
    if (std.c.chmod(app_a, 0o640) != 0) return error.IoFailed;
    const mode_file = try std.fs.path.joinZ(allocator, &.{ context_dir, "app/mode.txt" });
    defer allocator.free(mode_file);
    if (std.c.chmod(mode_file, 0o640) != 0) return error.IoFailed;
    const through_file = try std.fs.path.joinZ(allocator, &.{ context_dir, "through-file.txt" });
    defer allocator.free(through_file);
    if (std.c.chmod(through_file, 0o600) != 0) return error.IoFailed;
    Io.Dir.cwd().deleteFile(io, app_link) catch {};
    try Io.Dir.cwd().symLink(io, "a.txt", app_link, .{});
}

fn writeLargeCopyContext(allocator: std.mem.Allocator, io: Io, context_dir: []const u8) !void {
    Io.Dir.cwd().deleteTree(io, context_dir) catch {};
    const deps_dir = try std.fs.path.join(allocator, &.{ context_dir, "deps" });
    defer allocator.free(deps_dir);
    const dockerfile_path = try std.fs.path.join(allocator, &.{ context_dir, "Dockerfile" });
    defer allocator.free(dockerfile_path);
    try Io.Dir.cwd().createDirPath(io, deps_dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dockerfile_path, .data = "" });
    const size = 768 * 1024 * 1024;
    inline for (&.{ "one.bin", "two.bin", "three.bin" }) |name| {
        const path = try std.fs.path.joinZ(allocator, &.{ context_dir, "deps", name });
        defer allocator.free(path);
        try createSparseFile(path, size);
    }
}

fn createSparseFile(path: [:0]const u8, size: u64) !void {
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c_uint, 0o644));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);
    if (std.c.ftruncate(fd, @intCast(size)) != 0) return error.IoFailed;
}
