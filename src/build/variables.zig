const std = @import("std");

pub const Variable = struct {
    key: []const u8,
    value: ?[]const u8,
};

pub const UnsetPolicy = enum { empty, fail };

/// Expand the stable Dockerfile `$NAME` and `${NAME}` subset. Callers choose
/// whether an unset name expands to empty (FROM/COPY --from planning) or is an
/// error (instructions whose result must not silently lose input).
pub fn expand(
    allocator: std.mem.Allocator,
    input: []const u8,
    variables: []const Variable,
    unset_policy: UnsetPolicy,
) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    var index: usize = 0;
    while (index < input.len) {
        if (input[index] != '$') {
            try out.append(input[index]);
            index += 1;
            continue;
        }
        if (index + 1 == input.len) {
            try out.append('$');
            index += 1;
            continue;
        }
        if (input[index + 1] == '$') {
            try out.append('$');
            index += 2;
            continue;
        }

        var end = index + 1;
        const braced = input[end] == '{';
        if (braced) end += 1;
        const start = end;
        while (end < input.len and (std.ascii.isAlphanumeric(input[end]) or input[end] == '_')) end += 1;
        if (start == end) {
            if (braced) return error.BadVariableSubstitution;
            try out.append('$');
            index += 1;
            continue;
        }
        if (braced and (end == input.len or input[end] != '}')) return error.BadVariableSubstitution;

        if (lookup(variables, input[start..end])) |value| {
            try out.appendSlice(value);
        } else if (unset_policy == .fail) {
            return error.UnsetBuildArg;
        }
        index = end + @intFromBool(braced);
    }
    return out.toOwnedSlice();
}

fn lookup(variables: []const Variable, key: []const u8) ?[]const u8 {
    for (variables) |variable| {
        if (std.mem.eql(u8, variable.key, key)) return variable.value;
    }
    return null;
}

test "Dockerfile variable expansion has explicit unset and malformed policies" {
    const allocator = std.testing.allocator;
    const table = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "$A/${B}", .expected = "one/two" },
        .{ .input = "$$A", .expected = "$A" },
        .{ .input = "$MISSING", .expected = "" },
        .{ .input = "plain$", .expected = "plain$" },
    };
    const values = &.{
        Variable{ .key = "A", .value = "one" },
        Variable{ .key = "B", .value = "two" },
    };
    for (table) |case| {
        const got = try expand(allocator, case.input, values, .empty);
        defer allocator.free(got);
        try std.testing.expectEqualStrings(case.expected, got);
    }
    try std.testing.expectError(error.UnsetBuildArg, expand(allocator, "$MISSING", values, .fail));
    try std.testing.expectError(error.BadVariableSubstitution, expand(allocator, "${A", values, .empty));
    try std.testing.expectError(error.BadVariableSubstitution, expand(allocator, "${:-bad}", values, .empty));
}
