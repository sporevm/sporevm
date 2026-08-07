const std = @import("std");
const libspore = @import("libspore");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const command = [_][]const u8{"/bin/true"};
    const result = try libspore.runManaged(init, allocator, .{
        .backend = .kvm,
        .memory = libspore.MemoryConfig.fixed(512 * 1024 * 1024),
        .vcpus = 1,
        .command = &command,
    });
    if (result.exit_code != 0) return error.GuestCommandFailed;
    std.debug.print("standalone-libspore-zig ok\n", .{});
}
