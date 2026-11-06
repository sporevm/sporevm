//! Command-line values shared by several `spore` commands.

const std = @import("std");

pub const CommandMode = enum {
    argv,
    shell,
};

pub fn cliGuestCommandFromMode(allocator: std.mem.Allocator, mode: CommandMode, command: []const []const u8) ![]const []const u8 {
    return switch (mode) {
        .argv => command,
        .shell => {
            if (command.len != 1) return error.ShellCommandArgumentCountUnsupported;
            return allocator.dupe([]const u8, &.{ "/bin/sh", "-lc", command[0] });
        },
    };
}

pub fn parseDurationMs(raw: []const u8) !u64 {
    if (raw.len == 0) return error.InvalidDuration;
    if (std.mem.endsWith(u8, raw, "ms")) {
        return parsePositiveDuration(raw[0 .. raw.len - 2], 1);
    }
    if (std.mem.endsWith(u8, raw, "s")) {
        return parsePositiveDuration(raw[0 .. raw.len - 1], std.time.ms_per_s);
    }
    if (std.mem.endsWith(u8, raw, "m")) {
        return parsePositiveDuration(raw[0 .. raw.len - 1], std.time.ms_per_min);
    }
    return parsePositiveDuration(raw, std.time.ms_per_s);
}

fn parsePositiveDuration(number: []const u8, multiplier: u64) !u64 {
    const value = try parsePositiveDurationInteger(number);
    return try std.math.mul(u64, value, multiplier);
}

fn parsePositiveDurationInteger(raw: []const u8) !u64 {
    if (raw.len == 0) return error.InvalidDuration;
    const value = try std.fmt.parseInt(u64, raw, 10);
    if (value == 0) return error.InvalidDuration;
    return value;
}

test "run duration parser accepts common suffixes" {
    try std.testing.expectEqual(@as(u64, 500), try parseDurationMs("500ms"));
    try std.testing.expectEqual(@as(u64, 10_000), try parseDurationMs("10s"));
    try std.testing.expectEqual(@as(u64, 60_000), try parseDurationMs("1m"));
    try std.testing.expectEqual(@as(u64, 5_000), try parseDurationMs("5"));
    try std.testing.expectError(error.InvalidDuration, parseDurationMs("0s"));
}
