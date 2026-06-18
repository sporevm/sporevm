//! Product memory policy parsing.

const std = @import("std");

pub const auto_bytes: u64 = 16 * 1024 * 1024 * 1024;
pub const page_alignment: u64 = std.heap.page_size_min;

pub const Policy = enum {
    auto,
    explicit,
};

pub const Config = struct {
    policy: Policy = .auto,
    bytes: u64 = auto_bytes,

    pub fn cliValueAlloc(self: Config, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self.policy) {
            .auto => allocator.dupe(u8, "auto"),
            .explicit => std.fmt.allocPrint(allocator, "{d}b", .{self.bytes}),
        };
    }
};

pub const ParseError = error{
    EmptyMemory,
    InvalidMemory,
    MemoryOverflow,
    ZeroMemory,
    UnalignedMemory,
};

pub fn parse(raw: []const u8) ParseError!Config {
    if (raw.len == 0) return error.EmptyMemory;
    if (std.mem.eql(u8, raw, "auto")) return .{};
    if (hasWhitespace(raw)) return error.InvalidMemory;

    var suffix_start: usize = 0;
    while (suffix_start < raw.len and std.ascii.isDigit(raw[suffix_start])) : (suffix_start += 1) {}
    if (suffix_start == 0 or suffix_start == raw.len) return error.InvalidMemory;

    const value = std.fmt.parseInt(u64, raw[0..suffix_start], 10) catch return error.InvalidMemory;
    if (value == 0) return error.ZeroMemory;
    const multiplier = unitMultiplier(raw[suffix_start..]) orelse return error.InvalidMemory;
    const bytes = std.math.mul(u64, value, multiplier) catch return error.MemoryOverflow;
    try validateBytes(bytes);
    return .{ .policy = .explicit, .bytes = bytes };
}

pub fn fromManifestBytes(bytes: u64) ParseError!Config {
    try validateBytes(bytes);
    return .{ .policy = .explicit, .bytes = bytes };
}

pub fn parseCliOrExit(command: []const u8, raw: []const u8) Config {
    return parse(raw) catch |err| {
        std.debug.print(
            "{s}: --memory must be auto or a positive page-aligned size like 512mb or 16gb ({s})\n",
            .{ command, cliReason(err) },
        );
        std.process.exit(2);
    };
}

pub fn rejectMemoryMiBFlag(command: []const u8) noreturn {
    std.debug.print("{s}: --memory-mib has been replaced by --memory\n", .{command});
    std.process.exit(2);
}

fn validateBytes(bytes: u64) ParseError!void {
    if (bytes == 0) return error.ZeroMemory;
    if (bytes % page_alignment != 0) return error.UnalignedMemory;
}

fn hasWhitespace(raw: []const u8) bool {
    for (raw) |c| {
        if (std.ascii.isWhitespace(c)) return true;
    }
    return false;
}

fn unitMultiplier(raw: []const u8) ?u64 {
    if (std.mem.eql(u8, raw, "b")) return 1;
    if (std.mem.eql(u8, raw, "kb") or std.mem.eql(u8, raw, "kib")) return 1024;
    if (std.mem.eql(u8, raw, "mb") or std.mem.eql(u8, raw, "mib")) return 1024 * 1024;
    if (std.mem.eql(u8, raw, "gb") or std.mem.eql(u8, raw, "gib")) return 1024 * 1024 * 1024;
    return null;
}

fn cliReason(err: ParseError) []const u8 {
    return switch (err) {
        error.EmptyMemory => "empty value",
        error.InvalidMemory => "invalid value",
        error.MemoryOverflow => "value is too large",
        error.ZeroMemory => "value must be greater than zero",
        error.UnalignedMemory => "value is not page-aligned",
    };
}

test "memory parser defaults auto to 16GiB" {
    const parsed = try parse("auto");
    try std.testing.expectEqual(Policy.auto, parsed.policy);
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024 * 1024), parsed.bytes);
}

test "memory parser accepts binary product units" {
    const allocator = std.testing.allocator;
    const aligned_bytes = try std.fmt.allocPrint(allocator, "{d}b", .{page_alignment});
    defer allocator.free(aligned_bytes);
    const aligned_kb = try std.fmt.allocPrint(allocator, "{d}kb", .{page_alignment / 1024});
    defer allocator.free(aligned_kb);
    const aligned_kib = try std.fmt.allocPrint(allocator, "{d}kib", .{page_alignment / 1024});
    defer allocator.free(aligned_kib);

    try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), (try parse("512mb")).bytes);
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024 * 1024), (try parse("2gb")).bytes);
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024), (try parse("1024mib")).bytes);
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024 * 1024), (try parse("16gib")).bytes);
    try std.testing.expectEqual(page_alignment, (try parse(aligned_bytes)).bytes);
    try std.testing.expectEqual(page_alignment, (try parse(aligned_kb)).bytes);
    try std.testing.expectEqual(page_alignment, (try parse(aligned_kib)).bytes);
}

test "memory parser rejects invalid values" {
    try std.testing.expectError(error.EmptyMemory, parse(""));
    try std.testing.expectError(error.InvalidMemory, parse("Auto"));
    try std.testing.expectError(error.InvalidMemory, parse("1tb"));
    try std.testing.expectError(error.InvalidMemory, parse("1.5gb"));
    try std.testing.expectError(error.InvalidMemory, parse("16 gb"));
    try std.testing.expectError(error.InvalidMemory, parse(" 16gb"));
    try std.testing.expectError(error.InvalidMemory, parse("17179869184"));
    try std.testing.expectError(error.ZeroMemory, parse("0gb"));
    try std.testing.expectError(error.UnalignedMemory, parse("1b"));
}

test "memory parser rejects overflow" {
    try std.testing.expectError(error.MemoryOverflow, parse("18446744073709551615gb"));
}

test "manifest memory must be positive and page-aligned" {
    try std.testing.expectEqual(page_alignment, (try fromManifestBytes(page_alignment)).bytes);
    try std.testing.expectError(error.ZeroMemory, fromManifestBytes(0));
    try std.testing.expectError(error.UnalignedMemory, fromManifestBytes(1));
}

test "memory config formats a monitor CLI value" {
    const allocator = std.testing.allocator;
    const auto_value = try (Config{}).cliValueAlloc(allocator);
    defer allocator.free(auto_value);
    try std.testing.expectEqualStrings("auto", auto_value);

    const explicit_value = try (Config{ .policy = .explicit, .bytes = 4096 }).cliValueAlloc(allocator);
    defer allocator.free(explicit_value);
    try std.testing.expectEqualStrings("4096b", explicit_value);
}
