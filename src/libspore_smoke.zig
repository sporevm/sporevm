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
            .policy = network_policy,
            .bound_services = &.{bound_service},
        },
    };
    try std.testing.expect(networked_create.network.enabled);

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
}
