const std = @import("std");
const builtin = @import("builtin");
const libspore = @import("libspore");

test "external import can inspect host info" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("XDG_CACHE_HOME", "/tmp/sporevm-cache");
    try env.put("XDG_RUNTIME_DIR", "/tmp/sporevm-runtime");

    if (comptime builtin.cpu.arch == .aarch64) {
        const info = try libspore.hostInfo(.{
            .io = std.testing.io,
            .environ_map = &env,
        }, allocator);
        defer libspore.deinitHostInfo(allocator, info);
        try std.testing.expect(info.backends.len > 0);
    }

    const info_v3 = try libspore.hostInfoV3(.{
        .io = std.testing.io,
        .environ_map = &env,
    }, allocator);
    defer libspore.deinitHostInfoV3(allocator, info_v3);
    try std.testing.expectEqualStrings("spore.host-info.v3", info_v3.schema);
    const expected_arch = switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "amd64",
        else => unreachable,
    };
    try std.testing.expectEqualStrings(expected_arch, info_v3.architecture);
}

test "external import can consume classified failure events" {
    const failure = libspore.classifyFailure(error.BadChunk);
    try std.testing.expectEqual(libspore.FailureCode.cache_integrity_failed, failure.code);
}

test "external import preserves named lifecycle defaults" {
    const create = libspore.CreateNamedOptions{ .name = "dev-vm" };
    try std.testing.expectEqual(libspore.InitialOutputDisposition.retain, create.initial_output);

    const save = libspore.SaveNamedOptions{
        .name = "dev-vm",
        .out_dir = "dev.spore",
    };
    try std.testing.expect(!save.stop);
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
    const pruned = try libspore.systemPrune(context, allocator, prune_options);
    defer libspore.deinitRootfsPruneResult(allocator, pruned);
    try std.testing.expect(pruned.dry_run);
    try std.testing.expectEqual(@as(usize, 0), pruned.entries.len);
}
