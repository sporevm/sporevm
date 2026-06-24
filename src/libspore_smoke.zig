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
