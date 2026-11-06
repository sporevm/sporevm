//! Helpers shared by unit tests.

/// `pattern` repeated `count` times, a comptime string like the
/// `pattern ** count` that Zig 0.17 removed.
pub fn repeat(comptime pattern: []const u8, comptime count: usize) *const [pattern.len * count]u8 {
    return comptime blk: {
        const parts: [count][pattern.len]u8 = @splat(pattern[0..pattern.len].*);
        const flat: [pattern.len * count]u8 = @bitCast(parts);
        break :blk &flat;
    };
}
