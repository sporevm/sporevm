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
const Blake3 = std.crypto.hash.Blake3;
const ext4_superblock_offset: u64 = 1024;
const ext4_feature_incompat_offset: u64 = ext4_superblock_offset + 0x60;
const ext4_feature_incompat_extents: u32 = 0x40;

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

const Mode = enum {
    normal,
    large_copy,
    large_run,
    block_enospc,
    inode_enospc,

    fn tempLabel(self: Mode) []const u8 {
        return switch (self) {
            .normal => "run-smoke",
            .large_copy => "large-copy-smoke",
            .large_run => "large-run-smoke",
            .block_enospc => "block-enospc",
            .inode_enospc => "inode-enospc",
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2 or args.len > 4) {
        printUsage();
        return error.InvalidArguments;
    }
    const mode = parseMode(args) catch {
        printUsage();
        return error.InvalidArguments;
    };

    const io = init.io;
    const provided_tmp = if (args.len == 4) args[3] else null;
    if (provided_tmp != null and mode != .block_enospc and mode != .inode_enospc) {
        printUsage();
        return error.InvalidArguments;
    }
    const tmp = if (provided_tmp) |path| blk: {
        try validateProvidedSmokeRoot(allocator, io, path, mode);
        break :blk path;
    } else try createSmokeRoot(allocator, init.environ_map, mode);
    const owns_tmp = provided_tmp == null;
    defer if (owns_tmp) Io.Dir.cwd().deleteTree(io, tmp) catch {};

    const context_dir = try std.fs.path.join(allocator, &.{ tmp, "context" });
    const cache_dir = try std.fs.path.join(allocator, &.{ tmp, "rootfs-cache" });
    const runtime_dir = try std.fs.path.join(allocator, &.{ tmp, "runtime" });
    const rootfs_path = try std.fs.path.join(allocator, &.{ tmp, "base.ext4" });
    const dockerfile_path = try std.fs.path.join(allocator, &.{ context_dir, "Dockerfile" });
    try Io.Dir.cwd().createDirPath(io, context_dir);
    try Io.Dir.cwd().createDirPath(io, cache_dir);
    try Io.Dir.cwd().createDirPath(io, runtime_dir);
    const runtime_dir_z = try allocator.dupeZ(u8, runtime_dir);
    if (std.c.chmod(runtime_dir_z, 0o700) != 0) return error.IoFailed;
    try writeSmokeContext(allocator, io, context_dir, "beta\n");

    try init.environ_map.put(local_paths.rootfs_cache_env, cache_dir);
    try init.environ_map.put(local_paths.runtime_dir_env, runtime_dir);
    try init.environ_map.put("TMPDIR", tmp);

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
    const base_image_size: u64 = if (mode == .large_copy) 6 * 1024 * 1024 * 1024 else 16 << 20;
    const emitted = try ext4_writer.emit(allocator, io, rootfs_path, &entries, .{
        .image_size = base_image_size,
        .inode_count = if (mode == .inode_enospc) 32 else 1024,
        .determinism = ext4.Determinism.fromDigest("sha256:spore-build-run-smoke-base"),
        // The native test writer intentionally emits block-mapped filesystems.
        // The block-ENOSPC case enables the compatible extents feature below so
        // a newly created guest file can reserve blocks without writing 16 GiB.
        .cas_cache_root = if (mode == .block_enospc) null else cache_root,
        .cas_chunk_size = rootfs_cas.default_chunk_size,
        .cas_seal_workers = 1,
    });
    const preload = if (mode == .block_enospc) blk: {
        try enableExtentsFeature(allocator, rootfs_path);
        break :blk try rootfs_cas.preloadPath(io, allocator, cache_root, rootfs_path, rootfs_cas.default_chunk_size);
    } else emitted.preload_result orelse return error.BadManifest;
    const base_storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload);
    _ = try rootfs.publishIndexedImage(init, allocator, .{
        .ref = "local/build-smoke-base:dev",
        .platform = .{},
        .config = .{ .architecture = "arm64", .os = "linux" },
        .rootfs_storage = base_storage,
    });

    switch (mode) {
        .normal => {},
        .large_copy => return runLargeCopySmoke(init, allocator, io, context_dir, dockerfile_path),
        .large_run => return runLargeRunSmoke(init, allocator, io, dockerfile_path),
        .block_enospc, .inode_enospc => return runEnospcSmoke(init, allocator, io, cache_root, dockerfile_path, base_storage, mode),
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

    var uncached_diag: build_mod.Diagnostic = .{};
    const uncached = try build_mod.build(init, allocator, .{
        .tag = "local/build-smoke:dev",
        .context_dir = context_dir,
        .dockerfile_path = dockerfile_path,
        .platform = .{},
        .network = .none,
        .no_cache = true,
        .diagnostic = &uncached_diag,
    });
    if (uncached_diag.executor.boot_count != 1) return error.ExpectedUncachedBuildVmBoot;
    if (uncached_diag.executor.executed_steps != 18) return error.ExpectedUncachedBuildEighteenSteps;
    if (uncached_diag.executor.resize_count != 0) return error.ExpectedUncachedBuildWithoutResize;
    if (uncached_diag.executor.max_checkpoint_control_ms >= 2000) return error.UncachedBuildCheckpointControlTooSlow;
    if (uncached.cache_hit) return error.ExpectedUncachedBuildCacheMiss;
    if (!uncached_diag.context_disk.reused) return error.ExpectedUncachedContextDiskReuse;
    if (!std.mem.eql(u8, first_diag.context_disk.digest, uncached_diag.context_disk.digest)) return error.ExpectedUncachedContextDiskIdentity;

    var default_after_uncached_diag: build_mod.Diagnostic = .{};
    const default_after_uncached = try build_mod.build(init, allocator, .{
        .tag = "local/build-smoke:dev",
        .context_dir = context_dir,
        .dockerfile_path = dockerfile_path,
        .platform = .{},
        .network = .none,
        .diagnostic = &default_after_uncached_diag,
    });
    if (default_after_uncached_diag.executor.boot_count != 0) return error.ExpectedDefaultAfterUncachedWithoutBoot;
    if (default_after_uncached_diag.executor.executed_steps != 0) return error.ExpectedDefaultAfterUncachedWithoutSteps;
    if (default_after_uncached_diag.executor.resize_count != 0) return error.ExpectedDefaultAfterUncachedWithoutResize;
    if (!default_after_uncached.cache_hit) return error.ExpectedDefaultAfterUncachedCacheHit;
    if (!std.mem.eql(u8, uncached.index_digest, default_after_uncached.index_digest)) return error.ExpectedDefaultAfterUncachedRootfsIdentity;

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
        "spore-build-run-smoke ok: first={s} cached={s} uncached={s} default-after-uncached={s} edited={s} context-disk-first=emitted:{d}ms context-disk-uncached=reused:{d}ms context-disk-edited=emitted:{d}ms\n",
        .{
            first.index_digest,
            cached.index_digest,
            uncached.index_digest,
            default_after_uncached.index_digest,
            edited.index_digest,
            nsToMs(first_diag.context_disk.emit_ns),
            nsToMs(uncached_diag.context_disk.emit_ns),
            nsToMs(edited_diag.context_disk.emit_ns),
        },
    );
}

fn createSmokeRoot(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, mode: Mode) ![]const u8 {
    const temp_parent = env.get("TMPDIR") orelse "/tmp";
    if (!std.fs.path.isAbsolute(temp_parent)) return error.InvalidTemporaryDirectory;
    const template = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/sporevm-build-{s}.XXXXXX",
        .{ std.mem.trimEnd(u8, temp_parent, "/"), mode.tempLabel() },
        0,
    );
    const dir_ptr = mkdtemp(template.ptr) orelse return error.IoFailed;
    return std.mem.span(dir_ptr);
}

fn validateProvidedSmokeRoot(allocator: std.mem.Allocator, io: Io, path: []const u8, mode: Mode) !void {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidSmokeWorkspace;
    const expected_prefix = try std.fmt.allocPrint(allocator, "sporevm-build-{s}.", .{mode.tempLabel()});
    if (!std.mem.startsWith(u8, std.fs.path.basename(path), expected_prefix)) return error.InvalidSmokeWorkspace;

    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .directory) return error.InvalidSmokeWorkspace;
    if (@intFromEnum(stat.permissions) & 0o077 != 0) return error.InsecureSmokeWorkspace;

    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    var it = dir.iterate();
    if (try it.next(io) != null) return error.NonEmptySmokeWorkspace;
}

fn parseMode(args: []const []const u8) !Mode {
    if (args.len == 2) return .normal;
    if (std.mem.eql(u8, args[2], "--large-copy")) return .large_copy;
    if (std.mem.eql(u8, args[2], "--large-run")) return .large_run;
    if (std.mem.eql(u8, args[2], "--block-enospc")) return .block_enospc;
    if (std.mem.eql(u8, args[2], "--inode-enospc")) return .inode_enospc;
    return error.InvalidArguments;
}

fn printUsage() void {
    std.debug.print(
        "usage: build-run-smoke <aarch64-linux-sh-helper> [--large-copy|--large-run|--block-enospc|--inode-enospc] [absolute-enospc-workspace]\n",
        .{},
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

fn runLargeRunSmoke(init: std.process.Init, allocator: std.mem.Allocator, io: Io, dockerfile_path: []const u8) !void {
    try writeLargeRunDockerfile(io, dockerfile_path);
    const context_dir = std.fs.path.dirname(dockerfile_path) orelse return error.BadManifest;

    var diagnostic: build_mod.Diagnostic = .{};
    const first = build_mod.build(init, allocator, .{
        .tag = "local/build-smoke-large-run:dev",
        .context_dir = context_dir,
        .dockerfile_path = dockerfile_path,
        .platform = .{},
        .network = .none,
        .diagnostic = &diagnostic,
    }) catch |err| {
        std.debug.print(
            "large RUN build failed: err={s} line={d} instruction={?s} exit={?d} output={s}\n",
            .{ @errorName(err), diagnostic.executor.instruction_line, diagnostic.executor.instruction, diagnostic.executor.exit_code, diagnostic.executor.output },
        );
        return err;
    };
    if (diagnostic.executor.boot_count != 1) return error.ExpectedLargeRunBuildVmBoot;
    if (diagnostic.executor.executed_steps != 2) return error.ExpectedLargeRunTwoSteps;
    if (diagnostic.executor.resize_count != 1) return error.ExpectedLargeRunOneResize;
    if (first.cache_hit) return error.ExpectedLargeRunCacheMiss;

    // Reopen the published image through a fresh no-cache build. This proves
    // the 512 MiB payload is durable in CAS rather than merely readable from
    // the live ChunkMappedDisk that produced it.
    try writeSingleRunFromDockerfile(io, dockerfile_path, "local/build-smoke-large-run:dev", "verify-large-run");
    var reopen_diagnostic: build_mod.Diagnostic = .{};
    const reopened = try build_mod.build(init, allocator, .{
        .tag = "local/build-smoke-large-run-reopen:dev",
        .context_dir = context_dir,
        .dockerfile_path = dockerfile_path,
        .platform = .{},
        .network = .none,
        .no_cache = true,
        .diagnostic = &reopen_diagnostic,
    });
    if (reopen_diagnostic.executor.boot_count != 1) return error.ExpectedReopenedLargeRunVmBoot;
    if (reopen_diagnostic.executor.executed_steps != 1) return error.ExpectedReopenedLargeRunStep;
    if (reopen_diagnostic.executor.resize_count != 0) return error.ExpectedReopenedLargeRunWithoutResize;
    if (reopened.cache_hit) return error.ExpectedReopenedLargeRunCacheMiss;

    // Keep the ordinary warm zero-boot assertion separate from the CAS reopen
    // proof above: it exercises the original two-step build on an exact hit.
    try writeLargeRunDockerfile(io, dockerfile_path);
    var cached_diagnostic: build_mod.Diagnostic = .{};
    const cached = try build_mod.build(init, allocator, .{
        .tag = "local/build-smoke-large-run:dev",
        .context_dir = context_dir,
        .dockerfile_path = dockerfile_path,
        .platform = .{},
        .network = .none,
        .diagnostic = &cached_diagnostic,
    });
    if (cached_diagnostic.executor.boot_count != 0) return error.ExpectedCachedLargeRunWithoutBoot;
    if (cached_diagnostic.executor.executed_steps != 0) return error.ExpectedCachedLargeRunWithoutSteps;
    if (cached_diagnostic.executor.resize_count != 0) return error.ExpectedCachedLargeRunWithoutResize;
    if (!cached.cache_hit) return error.ExpectedCachedLargeRunHit;
    if (!std.mem.eql(u8, first.index_digest, cached.index_digest)) return error.ExpectedCachedLargeRunIdentity;

    std.debug.print(
        "spore-build-large-run-smoke ok: bytes=536870912 first={s} reopened={s} cached={s}\n",
        .{ first.index_digest, reopened.index_digest, cached.index_digest },
    );
}

fn writeLargeRunDockerfile(io: Io, dockerfile_path: []const u8) !void {
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = dockerfile_path,
        .data =
        \\FROM local/build-smoke-base:dev
        \\RUN generate-large-run
        \\RUN verify-large-run
        \\
        ,
    });
}

const PublicationState = struct {
    root_metadata_files: usize,
    root_metadata_digest: [Blake3.digest_length]u8,
    local_refs: usize,
    step_records: usize,
    indexes: usize,
    complete_stamps: usize,
    objects: usize,
};

fn runEnospcSmoke(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    io: Io,
    cache_root: []const u8,
    dockerfile_path: []const u8,
    base_storage: spore.RootfsStorage,
    mode: Mode,
) !void {
    const command = switch (mode) {
        .block_enospc => "exhaust-blocks",
        .inode_enospc => "exhaust-inodes",
        else => return error.InvalidArguments,
    };
    const destination = switch (mode) {
        .block_enospc => "local/build-smoke-block-enospc:dev",
        .inode_enospc => "local/build-smoke-inode-enospc:dev",
        else => unreachable,
    };
    const prepared_tag = switch (mode) {
        .block_enospc => "local/build-smoke-block-enospc-prepare:dev",
        .inode_enospc => "local/build-smoke-inode-enospc-prepare:dev",
        else => unreachable,
    };
    const context_dir = std.fs.path.dirname(dockerfile_path) orelse return error.BadManifest;

    // Prepare the exact parent once through an unrelated successful build.
    // The failing --no-cache build below must reuse this synthetic PREPARE
    // record while still executing its RUN instruction.
    try writeSingleRunDockerfile(io, dockerfile_path, "step1");
    var prepare_diagnostic: build_mod.Diagnostic = .{};
    const prepared = try build_mod.build(init, allocator, .{
        .tag = prepared_tag,
        .context_dir = context_dir,
        .dockerfile_path = dockerfile_path,
        .platform = .{},
        .network = .none,
        .diagnostic = &prepare_diagnostic,
    });
    if (prepared.cache_hit) return error.ExpectedPreparationCacheMiss;
    if (prepare_diagnostic.executor.boot_count != 1) return error.ExpectedPreparationVmBoot;
    if (prepare_diagnostic.executor.executed_steps != 1) return error.ExpectedOnePreparationRun;
    if (prepare_diagnostic.executor.resize_count != 1) return error.ExpectedOnePreparationResize;

    // Seed the destination so failure can prove byte-for-byte ref stability.
    _ = try rootfs.publishIndexedImage(init, allocator, .{
        .ref = destination,
        .platform = .{},
        .config = .{ .architecture = "arm64", .os = "linux" },
        .rootfs_storage = base_storage,
    });
    const destination_ref_path = try rootfs.localRefCachePath(allocator, cache_root, destination, .{});
    const ref_before = try Io.Dir.cwd().readFileAlloc(io, destination_ref_path, allocator, .limited(64 * 1024));
    const resolved_before = try rootfs.resolveLocalCachedRef(io, allocator, cache_root, destination, .{});
    const publication_before = try publicationState(io, allocator, cache_root);

    try writeSingleRunDockerfile(io, dockerfile_path, command);
    var diagnostic: build_mod.Diagnostic = .{};
    if (build_mod.build(init, allocator, .{
        .tag = destination,
        .context_dir = context_dir,
        .dockerfile_path = dockerfile_path,
        .platform = .{},
        .network = .none,
        .no_cache = true,
        .diagnostic = &diagnostic,
    })) |_| {
        return error.ExpectedEnospcBuildFailure;
    } else |err| {
        if (err != error.BuildRunFailed) {
            std.debug.print(
                "ENOSPC build failed unexpectedly: mode={s} err={s} line={d} instruction={?s} exit={?d} output={s}\n",
                .{ @tagName(mode), @errorName(err), diagnostic.executor.instruction_line, diagnostic.executor.instruction, diagnostic.executor.exit_code, diagnostic.executor.output },
            );
            return err;
        }
    }

    if (diagnostic.executor.boot_count != 1) return error.ExpectedEnospcBuildVmBoot;
    if (diagnostic.executor.executed_steps != 1) return error.ExpectedOneEnospcRunWithoutRetry;
    if (diagnostic.executor.resize_count != 0) return error.ExpectedPreparedBaseReuse;
    if (!diagnostic.executor.enospc) return error.ExpectedEnospcDiagnostic;
    if (diagnostic.executor.exit_code != 28) return error.ExpectedEnospcExitCode;
    const expected_instruction = try std.fmt.allocPrint(allocator, "RUN {s}", .{command});
    if (diagnostic.executor.instruction == null or
        !std.mem.eql(u8, diagnostic.executor.instruction.?, expected_instruction)) return error.ExpectedEnospcInstruction;
    const marker = try std.fmt.allocPrint(allocator, "SPORE_BUILD_ENOSPC {s}", .{if (mode == .block_enospc) "block" else "inode"});
    if (std.mem.count(u8, diagnostic.executor.output, marker) != 1) return error.ExpectedSingleEnospcExecutionMarker;

    const ref_after = try Io.Dir.cwd().readFileAlloc(io, destination_ref_path, allocator, .limited(64 * 1024));
    if (!std.mem.eql(u8, ref_before, ref_after)) return error.EnospcBuildChangedDestinationRef;
    const resolved_after = try rootfs.resolveLocalCachedRef(io, allocator, cache_root, destination, .{});
    if (!std.mem.eql(u8, resolved_before.ref, resolved_after.ref) or
        !std.mem.eql(u8, resolved_before.manifest_digest, resolved_after.manifest_digest)) return error.EnospcBuildChangedDestinationIdentity;

    const publication_after = try publicationState(io, allocator, cache_root);
    if (!std.meta.eql(publication_before, publication_after)) {
        std.debug.print(
            "ENOSPC build published authoritative state: mode={s} before={any} after={any}\n",
            .{ @tagName(mode), publication_before, publication_after },
        );
        return error.EnospcBuildPublishedState;
    }
    if (try stepRecordsContain(io, allocator, cache_root, command)) return error.EnospcBuildPublishedStepRecord;

    std.debug.print(
        "spore-build-{s}-smoke ok: exit=28 executed_steps=1 resize_count=0 ref={s}\n",
        .{ @tagName(mode), resolved_after.ref },
    );
}

fn writeSingleRunDockerfile(io: Io, path: []const u8, command: []const u8) !void {
    return writeSingleRunFromDockerfile(io, path, "local/build-smoke-base:dev", command);
}

fn writeSingleRunFromDockerfile(io: Io, path: []const u8, from: []const u8, command: []const u8) !void {
    var buf: [384]u8 = undefined;
    const dockerfile = try std.fmt.bufPrint(&buf,
        \\FROM {s}
        \\RUN {s}
        \\
    , .{ from, command });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = dockerfile });
}

fn publicationState(io: Io, allocator: std.mem.Allocator, cache_root: []const u8) !PublicationState {
    const root_metadata = try rootMetadataState(io, allocator, cache_root);
    return .{
        .root_metadata_files = root_metadata.files,
        .root_metadata_digest = root_metadata.digest,
        .local_refs = try countFiles(io, try std.fs.path.join(allocator, &.{ cache_root, "refs", "local" })),
        .step_records = try countFiles(io, try std.fs.path.join(allocator, &.{ cache_root, "build", "steps" })),
        .indexes = try countFiles(io, try std.fs.path.join(allocator, &.{ cache_root, "cas", "rootfs", "blake3", "indexes" })),
        .complete_stamps = try countFiles(io, try std.fs.path.join(allocator, &.{ cache_root, "cas", "rootfs", "blake3", "complete" })),
        .objects = try countFiles(io, try std.fs.path.join(allocator, &.{ cache_root, "cas", "rootfs", "blake3", "objects" })),
    };
}

const RootMetadataState = struct {
    files: usize,
    digest: [Blake3.digest_length]u8,
};

fn rootMetadataState(io: Io, allocator: std.mem.Allocator, cache_root: []const u8) !RootMetadataState {
    var dir = try Io.Dir.cwd().openDir(io, cache_root, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);

    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(allocator);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, stringLessThan);

    var h = Blake3.init(.{});
    for (names.items) |name| {
        const path = try std.fs.path.join(allocator, &.{ cache_root, name });
        const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        hashSmokeField(&h, name);
        hashSmokeField(&h, bytes);
    }
    var digest: [Blake3.digest_length]u8 = undefined;
    h.final(&digest);
    return .{ .files = names.items.len, .digest = digest };
}

fn hashSmokeField(h: *Blake3, bytes: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, bytes.len, .little);
    h.update(&len);
    h.update(bytes);
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn countFiles(io: Io, path: []const u8) !usize {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => |e| return e,
    };
    defer dir.close(io);
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| if (entry.kind == .file) {
        count += 1;
    };
    return count;
}

fn stepRecordsContain(io: Io, allocator: std.mem.Allocator, cache_root: []const u8, needle: []const u8) !bool {
    const steps_path = try std.fs.path.join(allocator, &.{ cache_root, "build", "steps" });
    var dir = Io.Dir.cwd().openDir(io, steps_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(allocator, &.{ steps_path, entry.name });
        const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 * 1024));
        if (std.mem.indexOf(u8, bytes, needle) != null) return true;
    }
    return false;
}

fn enableExtentsFeature(allocator: std.mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);

    var feature_bytes: [4]u8 = undefined;
    const feature_len: isize = @intCast(feature_bytes.len);
    if (std.c.pread(fd, &feature_bytes, feature_bytes.len, @intCast(ext4_feature_incompat_offset)) != feature_len) return error.IoFailed;
    const features = std.mem.readInt(u32, &feature_bytes, .little) | ext4_feature_incompat_extents;
    std.mem.writeInt(u32, &feature_bytes, features, .little);
    if (std.c.pwrite(fd, &feature_bytes, feature_bytes.len, @intCast(ext4_feature_incompat_offset)) != feature_len) return error.IoFailed;
    if (std.c.fsync(fd) != 0) return error.IoFailed;
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
