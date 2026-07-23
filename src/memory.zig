//! Product memory sizing.

const std = @import("std");

pub const default_bytes: u64 = 512 * 1024 * 1024;
pub const page_alignment: u64 = std.heap.page_size_min;
pub const elastic_block_size: u64 = 2 * 1024 * 1024;
pub const max_elastic_blocks: u64 = 8192;
pub const max_elastic_region_bytes: u64 = elastic_block_size * max_elastic_blocks;

pub const PluggedRange = struct {
    start_block: u32,
    block_count: u32,
};

/// Backend-neutral virtio-mem state persisted in an elastic spore manifest.
/// Sizes include the initial RAM region, while plugged ranges are relative to
/// the elastic region immediately following it.
pub const CapturedState = struct {
    initial_size: u64,
    maximum_size: u64,
    requested_size: u64,
    captured_size: u64,
    block_size: u64 = elastic_block_size,
    plugged_ranges: []const PluggedRange,

    pub fn config(self: CapturedState) Config {
        return .{
            .initial_bytes = self.initial_size,
            .maximum_bytes = self.maximum_size,
        };
    }
};

pub const Config = struct {
    initial_bytes: u64 = default_bytes,
    maximum_bytes: u64 = default_bytes,

    pub fn fixed(bytes: u64) Config {
        return .{ .initial_bytes = bytes, .maximum_bytes = bytes };
    }

    pub fn isElastic(self: Config) bool {
        return self.maximum_bytes > self.initial_bytes;
    }

    pub fn validate(self: Config) ParseError!void {
        try validateBytes(self.initial_bytes);
        try validateBytes(self.maximum_bytes);
        if (self.maximum_bytes < self.initial_bytes) return error.MaximumBelowInitial;
        if (self.isElastic()) {
            if (self.initial_bytes % elastic_block_size != 0 or self.maximum_bytes % elastic_block_size != 0) {
                return error.UnalignedElasticMemory;
            }
            if (self.maximum_bytes - self.initial_bytes > max_elastic_region_bytes) {
                return error.ElasticRegionTooLarge;
            }
        }
    }

    pub fn initialCliValueAlloc(self: Config, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{d}b", .{self.initial_bytes});
    }

    pub fn maximumCliValueAlloc(self: Config, allocator: std.mem.Allocator) !?[]const u8 {
        if (!self.isElastic()) return null;
        const value = try std.fmt.allocPrint(allocator, "{d}b", .{self.maximum_bytes});
        return value;
    }
};

pub const ParseError = error{
    EmptyMemory,
    InvalidMemory,
    MemoryOverflow,
    ZeroMemory,
    UnalignedMemory,
    RemovedAuto,
    MaximumBelowInitial,
    UnalignedElasticMemory,
    ElasticRegionTooLarge,
};

/// Parse a fixed-memory value. Callers add an explicit maximum separately.
pub fn parse(raw: []const u8) ParseError!Config {
    return Config.fixed(try parseBytes(raw));
}

pub fn parseBytes(raw: []const u8) ParseError!u64 {
    if (raw.len == 0) return error.EmptyMemory;
    if (std.mem.eql(u8, raw, "auto")) return error.RemovedAuto;
    if (hasWhitespace(raw)) return error.InvalidMemory;

    var suffix_start: usize = 0;
    while (suffix_start < raw.len and std.ascii.isDigit(raw[suffix_start])) : (suffix_start += 1) {}
    if (suffix_start == 0 or suffix_start == raw.len) return error.InvalidMemory;

    const value = std.fmt.parseInt(u64, raw[0..suffix_start], 10) catch return error.InvalidMemory;
    if (value == 0) return error.ZeroMemory;
    const multiplier = unitMultiplier(raw[suffix_start..]) orelse return error.InvalidMemory;
    const bytes = std.math.mul(u64, value, multiplier) catch return error.MemoryOverflow;
    try validateBytes(bytes);
    return bytes;
}

pub fn fromManifestBytes(bytes: u64) ParseError!Config {
    try validateBytes(bytes);
    return Config.fixed(bytes);
}

pub fn parseCliBytesOrExit(command: []const u8, flag: []const u8, raw: []const u8) u64 {
    return parseBytes(raw) catch |err| {
        if (err == error.RemovedAuto) {
            std.debug.print(
                "{s}: {s} auto was removed; use --memory 512mb for fixed memory, or --memory 512mb --max-memory 16gb for elastic memory\n",
                .{ command, flag },
            );
        } else {
            std.debug.print(
                "{s}: {s} must be a positive page-aligned size like 512mb or 16gb ({s})\n",
                .{ command, flag, cliReason(err) },
            );
        }
        std.process.exit(2);
    };
}

pub fn validateCliOrExit(command: []const u8, config: Config) void {
    config.validate() catch |err| {
        switch (err) {
            error.MaximumBelowInitial => std.debug.print(
                "{s}: --max-memory must be greater than or equal to --memory\n",
                .{command},
            ),
            error.UnalignedElasticMemory => std.debug.print(
                "{s}: elastic --memory and --max-memory values must be aligned to 2 MiB\n",
                .{command},
            ),
            error.ElasticRegionTooLarge => std.debug.print(
                "{s}: --max-memory may exceed --memory by at most 16 GiB\n",
                .{command},
            ),
            else => std.debug.print("{s}: invalid memory configuration ({s})\n", .{ command, cliReason(err) }),
        }
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
        error.RemovedAuto => "auto was removed",
        error.MaximumBelowInitial => "maximum is below initial memory",
        error.UnalignedElasticMemory => "elastic memory must be aligned to 2 MiB virtio-mem blocks",
        error.ElasticRegionTooLarge => "elastic memory may grow by at most 16 GiB",
    };
}

test "memory defaults to fixed 512MiB" {
    const config = Config{};
    try std.testing.expectEqual(default_bytes, config.initial_bytes);
    try std.testing.expectEqual(default_bytes, config.maximum_bytes);
    try std.testing.expect(!config.isElastic());
}

test "memory parser accepts binary product units" {
    const allocator = std.testing.allocator;
    const aligned_bytes = try std.fmt.allocPrint(allocator, "{d}b", .{page_alignment});
    defer allocator.free(aligned_bytes);
    const aligned_kb = try std.fmt.allocPrint(allocator, "{d}kb", .{page_alignment / 1024});
    defer allocator.free(aligned_kb);
    const aligned_kib = try std.fmt.allocPrint(allocator, "{d}kib", .{page_alignment / 1024});
    defer allocator.free(aligned_kib);

    try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), try parseBytes("512mb"));
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024 * 1024), try parseBytes("2gb"));
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024), try parseBytes("1024mib"));
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024 * 1024), try parseBytes("16gib"));
    try std.testing.expectEqual(page_alignment, try parseBytes(aligned_bytes));
    try std.testing.expectEqual(page_alignment, try parseBytes(aligned_kb));
    try std.testing.expectEqual(page_alignment, try parseBytes(aligned_kib));
}

test "memory parser rejects auto and invalid values" {
    try std.testing.expectError(error.RemovedAuto, parseBytes("auto"));
    try std.testing.expectError(error.EmptyMemory, parseBytes(""));
    try std.testing.expectError(error.InvalidMemory, parseBytes("Auto"));
    try std.testing.expectError(error.InvalidMemory, parseBytes("1tb"));
    try std.testing.expectError(error.InvalidMemory, parseBytes("1.5gb"));
    try std.testing.expectError(error.InvalidMemory, parseBytes("16 gb"));
    try std.testing.expectError(error.InvalidMemory, parseBytes(" 16gb"));
    try std.testing.expectError(error.InvalidMemory, parseBytes("17179869184"));
    try std.testing.expectError(error.ZeroMemory, parseBytes("0gb"));
    try std.testing.expectError(error.UnalignedMemory, parseBytes("1b"));
}

test "memory config validates maximum" {
    const elastic = Config{ .initial_bytes = 512 * 1024 * 1024, .maximum_bytes = 16 * 1024 * 1024 * 1024 };
    try elastic.validate();
    try std.testing.expect(elastic.isElastic());
    try std.testing.expectError(error.MaximumBelowInitial, (Config{
        .initial_bytes = 1024 * 1024 * 1024,
        .maximum_bytes = 512 * 1024 * 1024,
    }).validate());
    try std.testing.expectError(error.UnalignedElasticMemory, (Config{
        .initial_bytes = 512 * 1024 * 1024,
        .maximum_bytes = 512 * 1024 * 1024 + page_alignment,
    }).validate());
    try std.testing.expectError(error.ElasticRegionTooLarge, (Config{
        .initial_bytes = 512 * 1024 * 1024,
        .maximum_bytes = 512 * 1024 * 1024 + max_elastic_region_bytes + elastic_block_size,
    }).validate());
}

test "memory parser rejects overflow" {
    try std.testing.expectError(error.MemoryOverflow, parseBytes("18446744073709551615gb"));
}

test "manifest memory must be positive and page-aligned" {
    try std.testing.expectEqual(page_alignment, (try fromManifestBytes(page_alignment)).initial_bytes);
    try std.testing.expectError(error.ZeroMemory, fromManifestBytes(0));
    try std.testing.expectError(error.UnalignedMemory, fromManifestBytes(1));
}

test "memory config formats monitor CLI values" {
    const allocator = std.testing.allocator;
    const fixed_value = try (Config.fixed(4096)).initialCliValueAlloc(allocator);
    defer allocator.free(fixed_value);
    try std.testing.expectEqualStrings("4096b", fixed_value);
    try std.testing.expectEqual(@as(?[]const u8, null), try (Config.fixed(4096)).maximumCliValueAlloc(allocator));

    const max_value = (try (Config{ .initial_bytes = 4096, .maximum_bytes = 8192 }).maximumCliValueAlloc(allocator)).?;
    defer allocator.free(max_value);
    try std.testing.expectEqualStrings("8192b", max_value);
}
