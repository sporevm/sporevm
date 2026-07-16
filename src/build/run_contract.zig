const std = @import("std");

pub const max_exec_args = 16;
pub const max_exec_args_bytes = 4096;
pub const max_shell_command_bytes = 64 * 1024;

pub const ExecArgvViolation = enum {
    empty,
    empty_executable,
    too_many_args,
    nul,
    decoded_too_large,
};

pub fn execArgvViolation(argv: []const []const u8) ?ExecArgvViolation {
    if (argv.len == 0) return .empty;
    if (argv[0].len == 0) return .empty_executable;
    if (argv.len > max_exec_args) return .too_many_args;
    var decoded_bytes: usize = 0;
    for (argv) |arg| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null) return .nul;
        decoded_bytes = std.math.add(usize, decoded_bytes, arg.len) catch return .decoded_too_large;
    }
    if (decoded_bytes > max_exec_args_bytes) return .decoded_too_large;
    return null;
}

test "exec argv contract covers argument count and decoded byte bounds" {
    const sixteen = [_][]const u8{"x"} ** max_exec_args;
    try std.testing.expect(execArgvViolation(&sixteen) == null);
    const seventeen = [_][]const u8{"x"} ** (max_exec_args + 1);
    try std.testing.expectEqual(.too_many_args, execArgvViolation(&seventeen).?);
    try std.testing.expect(execArgvViolation(&.{"x" ** max_exec_args_bytes}) == null);
    try std.testing.expectEqual(.decoded_too_large, execArgvViolation(&.{"x" ** (max_exec_args_bytes + 1)}).?);
}
