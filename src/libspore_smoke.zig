const std = @import("std");
const builtin = @import("builtin");
const libspore = @import("libspore");

test "external import can inspect host info" {
    if (comptime builtin.cpu.arch != .aarch64) return;

    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("XDG_CACHE_HOME", "/tmp/sporevm-cache");
    try env.put("XDG_RUNTIME_DIR", "/tmp/sporevm-runtime");

    const info = try libspore.hostInfo(.{
        .io = std.testing.io,
        .environ_map = &env,
    }, allocator);
    defer libspore.deinitHostInfo(allocator, info);

    try std.testing.expect(info.backends.len > 0);
}

test "external import can consume classified failure events" {
    const failure = libspore.classifyFailure(error.BadChunk);
    try std.testing.expectEqual(libspore.FailureCode.cache_integrity_failed, failure.code);

    const event = libspore.RunEvent{
        .failure = .{
            .command = "run",
            .backend = null,
            .classified = failure,
        },
    };
    try std.testing.expectEqual(libspore.FailureCode.cache_integrity_failed, event.failure.classified.code);
}

test "external import can name managed run-from and named lifecycle APIs" {
    const managed = libspore.ManagedRunOptions{
        .kernel_path = "Image",
        .command = &.{"/bin/true"},
    };
    try std.testing.expectEqualStrings("Image", managed.kernel_path.?);

    const from = libspore.RunFromSporeOptions{
        .spore_dir = "base.spore",
        .command = &.{"/bin/true"},
    };
    try std.testing.expectEqualStrings("base.spore", from.spore_dir);
    _ = libspore.runManaged;
    _ = libspore.runFromSpore;

    const create = libspore.CreateNamedOptions{ .name = "dev-vm" };
    try std.testing.expectEqualStrings("dev-vm", create.name);

    const network_policy = libspore.NetworkPolicy{
        .allow = &.{.{
            .host = "github.com",
            .ports = &.{443},
        }},
    };
    const bound_service = libspore.BoundService{
        .name = "cleanroom-gateway",
        .guest_host = "gateway.cleanroom.internal",
        .guest_port = 8170,
        .target = .{ .unix = "/tmp/gateway.sock" },
    };
    const networked_create = libspore.CreateNamedOptions{
        .name = "networked-vm",
        .network = .{
            .enabled = true,
            .allow_cidrs = &.{"93.184.216.34/32"},
            .allow_hosts = &.{"example.com"},
            .policy = network_policy,
            .bound_services = &.{bound_service},
        },
    };
    try std.testing.expect(networked_create.network.enabled);
    try std.testing.expectEqual(@as(usize, 1), networked_create.network.allow_cidrs.len);
    try std.testing.expectEqual(@as(usize, 1), networked_create.network.allow_hosts.len);

    const resumed = libspore.ResumeNamedOptions{
        .spore_dir = "dev.spore",
        .name = "resumed-vm",
    };
    try std.testing.expectEqualStrings("resumed-vm", resumed.name);
    _ = libspore.resumeNamed;

    const forked = libspore.ForkNamedOptions{
        .source_name = "dev-vm",
        .count = 2,
        .name_pattern = "worker-%d",
    };
    try std.testing.expectEqual(@as(usize, 2), forked.count);
    _ = libspore.forkNamed;
    _ = libspore.deinitNamedForkResult;

    const exec = libspore.ExecNamedOptions{
        .name = "dev-vm",
        .command = &.{"/bin/true"},
    };
    try std.testing.expectEqual(@as(usize, 1), exec.command.len);

    const snapshot = libspore.SnapshotNamedOptions{
        .name = "dev-vm",
        .out_dir = "dev.spore",
        .continue_after = true,
    };
    try std.testing.expect(snapshot.continue_after);

    _ = libspore.createNamed;
    _ = libspore.execNamed;
    _ = libspore.networkCapabilities;
    _ = libspore.snapshotNamed;
    _ = libspore.suspendNamed;
    _ = libspore.removeNamed;
    _ = libspore.listNamed;

    const facts = libspore.networkCapabilities();
    try std.testing.expect(facts.supported and facts.exact_host_port);

    const rootfs_build = libspore.RootfsBuildOptions{
        .ref = "docker.io/library/alpine:3.20",
        .output = "rootfs.ext4",
        .metadata = "rootfs.ext4.json",
    };
    try std.testing.expectEqualStrings("rootfs.ext4", rootfs_build.output);
    const rootfs_resolve = libspore.RootfsResolveOptions{
        .ref = "docker.io/library/alpine:3.20",
    };
    try std.testing.expectEqualStrings("docker.io/library/alpine:3.20", rootfs_resolve.ref);
    _ = libspore.rootfsBuild;
    _ = libspore.rootfsImportOci;
    _ = libspore.rootfsResolve;
    _ = libspore.rootfsCasPreload;
    _ = libspore.deinitRootfsBuildResult;
    _ = libspore.deinitRootfsImportOciResult;
    _ = libspore.deinitRootfsResolveResult;
    _ = libspore.deinitRootfsCasPreloadResult;
}

test "external import can inspect and prune system cache" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const context = libspore.Context{
        .io = std.testing.io,
        .environ_map = &env,
    };
    const root = "zig-cache/libspore-system-smoke";

    const df_options = libspore.SystemDfOptions{ .rootfs_cache = .{ .path = root } };
    switch (df_options.rootfs_cache) {
        .path => |path| try std.testing.expectEqualStrings("zig-cache/libspore-system-smoke", path),
        else => return error.UnexpectedCacheRoot,
    }

    const summary = try libspore.systemDf(context, allocator, df_options);
    defer libspore.deinitRootfsSystemSummary(allocator, summary);
    try std.testing.expectEqualStrings(root, summary.cache_root);
    try std.testing.expectEqual(@as(u64, 0), summary.known_logical_bytes);

    const prune_options = libspore.SystemPruneOptions{
        .rootfs_cache = .{ .path = root },
        .dry_run = true,
        .max_bytes = 0,
        .rootfs_only = true,
    };
    try std.testing.expect(prune_options.dry_run);
    try std.testing.expect(prune_options.rootfs_only);

    const pruned = try libspore.systemPrune(context, allocator, prune_options);
    defer libspore.deinitRootfsPruneResult(allocator, pruned);
    try std.testing.expect(pruned.dry_run);
    try std.testing.expectEqual(@as(usize, 0), pruned.entries.len);

    _ = libspore.CacheStats;
    _ = libspore.RootfsSystemSummary;
    _ = libspore.RootfsPruneResult;
    _ = libspore.RuntimeForkPruneResult;
    _ = libspore.systemDf;
    _ = libspore.systemPrune;
    _ = libspore.deinitRootfsSystemSummary;
    _ = libspore.deinitRootfsPruneResult;
}
