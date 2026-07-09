//! Gated VM smoke for the `spore build` RUN executor.
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
        .diagnostic = &first_diag,
    });
    if (first_diag.executor.boot_count != 1) return error.ExpectedOneBuildVmBoot;
    if (first_diag.executor.executed_steps != 2) return error.ExpectedTwoRunSteps;
    if (first.cache_hit) return error.ExpectedFirstBuildCacheMiss;

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
    if (!cached.cache_hit) return error.ExpectedCachedBuildHit;
    if (!std.mem.eql(u8, first.index_digest, cached.index_digest)) return error.ExpectedCachedRootfsIdentity;

    try writeDockerfile(io, dockerfile_path, "step2b");
    var edited_diag: build_mod.Diagnostic = .{};
    const edited = try build_mod.build(init, allocator, .{
        .tag = "local/build-smoke:dev",
        .context_dir = context_dir,
        .dockerfile_path = dockerfile_path,
        .platform = .{},
        .network = .none,
        .diagnostic = &edited_diag,
    });
    if (edited_diag.executor.boot_count != 1) return error.ExpectedEditedBuildVmBoot;
    if (edited_diag.executor.executed_steps != 1) return error.ExpectedEditedBuildOneStep;
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
        \\RUN {s}
        \\CMD ["/bin/sh","-c","step2"]
        \\
    , .{second_step});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = dockerfile });
}
