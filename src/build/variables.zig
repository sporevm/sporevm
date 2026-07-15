const std = @import("std");

pub const Variable = struct {
    key: []const u8,
    value: ?[]const u8,
};

pub const Options = struct {
    escape: u8 = '\\',
};

pub const max_expanded_word_bytes = 1024 * 1024;

/// Resolve one Dockerfile word using the stable frontend expansion grammar.
/// Quotes are removed here rather than by the Dockerfile parser so expansion
/// sees the exact instruction spelling. Unset names expand to an empty string.
pub fn expand(
    allocator: std.mem.Allocator,
    input: []const u8,
    variables: []const Variable,
    options: Options,
) ![]const u8 {
    var parser = Parser{
        .allocator = allocator,
        .input = input,
        .variables = variables,
        .escape = options.escape,
    };
    return parser.process(null);
}

/// Parse an expansion-capable word without executing an instruction. This is
/// used during the full-file parse pass to reject malformed or unsupported
/// substitutions before any base fetch or guest boot can occur.
pub fn validate(allocator: std.mem.Allocator, input: []const u8, options: Options) !void {
    const resolved = try expand(allocator, input, &.{}, options);
    allocator.free(resolved);
}

const Parser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    variables: []const Variable,
    escape: u8,
    index: usize = 0,
    depth: u8 = 0,

    fn process(self: *Parser, stop: ?u8) ExpansionError![]const u8 {
        var out = std.array_list.Managed(u8).init(self.allocator);
        errdefer out.deinit();
        while (self.index < self.input.len) {
            const c = self.input[self.index];
            if (stop != null and c == stop.?) {
                self.index += 1;
                return out.toOwnedSlice();
            }
            switch (c) {
                '\'' => try self.singleQuoted(&out),
                '"' => try self.doubleQuoted(&out),
                '$' => try self.dollar(&out),
                else => {
                    if (c == self.escape) {
                        self.index += 1;
                        if (self.index == self.input.len) break;
                        try appendByte(&out, self.input[self.index]);
                        self.index += 1;
                    } else {
                        try appendByte(&out, c);
                        self.index += 1;
                    }
                },
            }
        }
        if (stop != null) return error.BadVariableSubstitution;
        return out.toOwnedSlice();
    }

    fn singleQuoted(self: *Parser, out: *std.array_list.Managed(u8)) ExpansionError!void {
        self.index += 1;
        while (self.index < self.input.len) : (self.index += 1) {
            if (self.input[self.index] == '\'') {
                self.index += 1;
                return;
            }
            try appendByte(out, self.input[self.index]);
        }
        return error.BadVariableSubstitution;
    }

    fn doubleQuoted(self: *Parser, out: *std.array_list.Managed(u8)) ExpansionError!void {
        self.index += 1;
        while (self.index < self.input.len) {
            const c = self.input[self.index];
            if (c == '"') {
                self.index += 1;
                return;
            }
            if (c == '$') {
                try self.dollar(out);
                continue;
            }
            if (c == self.escape) {
                self.index += 1;
                if (self.index == self.input.len) return error.BadVariableSubstitution;
                const escaped = self.input[self.index];
                if (escaped == '"' or escaped == '$' or escaped == self.escape) {
                    try appendByte(out, escaped);
                    self.index += 1;
                } else {
                    try appendByte(out, self.escape);
                }
                continue;
            }
            try appendByte(out, c);
            self.index += 1;
        }
        return error.BadVariableSubstitution;
    }

    fn dollar(self: *Parser, out: *std.array_list.Managed(u8)) ExpansionError!void {
        self.index += 1;
        if (self.index == self.input.len) {
            try appendByte(out, '$');
            return;
        }
        if (self.input[self.index] != '{') {
            if (!std.ascii.isAscii(self.input[self.index])) return error.BadVariableSubstitution;
            const start = self.index;
            if (std.ascii.isDigit(self.input[self.index])) {
                while (self.index < self.input.len and std.ascii.isDigit(self.input[self.index])) self.index += 1;
            } else if (specialParameter(self.input[self.index])) {
                self.index += 1;
            } else {
                while (self.index < self.input.len and nameChar(self.input[self.index])) self.index += 1;
            }
            if (start == self.index) {
                try appendByte(out, '$');
                return;
            }
            const found = lookup(self.variables, self.input[start..self.index]);
            if (found.value) |value| try appendSlice(out, value);
            return;
        }

        self.index += 1;
        const start = self.index;
        while (self.index < self.input.len and nameChar(self.input[self.index])) self.index += 1;
        if (start == self.index or self.index == self.input.len) return error.BadVariableSubstitution;
        const name = self.input[start..self.index];
        const found = lookup(self.variables, name);

        if (self.input[self.index] == '}') {
            self.index += 1;
            if (found.value) |value| try appendSlice(out, value);
            return;
        }

        var null_is_unset = false;
        if (self.input[self.index] == ':') {
            null_is_unset = true;
            self.index += 1;
            if (self.index == self.input.len) return error.BadVariableSubstitution;
        }
        const operator = self.input[self.index];
        if (operator != '-' and operator != '+') return error.UnsupportedVariableModifier;
        self.index += 1;
        if (self.depth == max_expansion_depth) return error.BadVariableSubstitution;
        self.depth += 1;
        defer self.depth -= 1;
        const word = try self.process('}');
        defer self.allocator.free(word);

        const value: []const u8 = found.value orelse "";
        const usable = found.set and (!null_is_unset or value.len != 0);
        if (operator == '-') {
            if (usable) {
                try appendSlice(out, value);
            } else {
                try appendSlice(out, word);
            }
        } else if (usable) {
            try appendSlice(out, word);
        }
    }
};

const max_expansion_depth = 64;

const ExpansionError = std.mem.Allocator.Error || error{
    BadVariableSubstitution,
    UnsupportedVariableModifier,
    VariableExpansionTooLarge,
};

fn appendByte(out: *std.array_list.Managed(u8), value: u8) ExpansionError!void {
    if (out.items.len == max_expanded_word_bytes) return error.VariableExpansionTooLarge;
    try out.append(value);
}

fn appendSlice(out: *std.array_list.Managed(u8), value: []const u8) ExpansionError!void {
    if (value.len > max_expanded_word_bytes - out.items.len) return error.VariableExpansionTooLarge;
    try out.appendSlice(value);
}

const Lookup = struct {
    set: bool = false,
    value: ?[]const u8 = null,
};

fn lookup(variables: []const Variable, key: []const u8) Lookup {
    for (variables) |variable| {
        if (std.mem.eql(u8, variable.key, key)) return .{
            .set = variable.value != null,
            .value = variable.value,
        };
    }
    return .{};
}

fn nameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn specialParameter(c: u8) bool {
    return switch (c) {
        '@', '*', '#', '?', '-', '$', '!' => true,
        else => false,
    };
}

fn fuzzExpansion(_: void, s: *std.testing.Smith) !void {
    var buf: [2048]u8 = undefined;
    const len = s.slice(&buf);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    _ = expand(arena_state.allocator(), buf[0..len], &.{
        .{ .key = "SET", .value = "value" },
        .{ .key = "EMPTY", .value = "" },
        .{ .key = "NOVALUE", .value = null },
    }, .{}) catch {};
}

test "Dockerfile variable expansion handles stable operators and unset values" {
    const allocator = std.testing.allocator;
    const values = &.{
        Variable{ .key = "SET", .value = "value" },
        Variable{ .key = "EMPTY", .value = "" },
        Variable{ .key = "NOVALUE", .value = null },
        Variable{ .key = "WORD", .value = "fallback" },
    };
    const table = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "$SET/${SET}", .expected = "value/value" },
        .{ .input = "$MISSING", .expected = "" },
        .{ .input = "${MISSING:-$WORD}", .expected = "fallback" },
        .{ .input = "${EMPTY:-fallback}", .expected = "fallback" },
        .{ .input = "${EMPTY-fallback}", .expected = "" },
        .{ .input = "${SET:+alternate}", .expected = "alternate" },
        .{ .input = "${EMPTY:+alternate}", .expected = "" },
        .{ .input = "${EMPTY+alternate}", .expected = "alternate" },
        .{ .input = "${NOVALUE-default}", .expected = "default" },
        .{ .input = "$$suffix", .expected = "suffix" },
        .{ .input = "$12suffix", .expected = "suffix" },
        .{ .input = "plain$", .expected = "plain$" },
    };
    for (table) |case| {
        const got = try expand(allocator, case.input, values, .{});
        defer allocator.free(got);
        try std.testing.expectEqualStrings(case.expected, got);
    }
}

test "Dockerfile variable expansion preserves quote and escape semantics" {
    const allocator = std.testing.allocator;
    const values = &.{Variable{ .key = "VALUE", .value = "expanded" }};
    const table = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "'$VALUE'", .expected = "$VALUE" },
        .{ .input = "\"$VALUE\"", .expected = "expanded" },
        .{ .input = "\\$VALUE", .expected = "$VALUE" },
        .{ .input = "\"\\$VALUE\"", .expected = "$VALUE" },
        .{ .input = "\"left\\qright\"", .expected = "left\\qright" },
        .{ .input = "`$VALUE", .expected = "$VALUE" },
    };
    for (table, 0..) |case, index| {
        const options: Options = if (index == table.len - 1) .{ .escape = '`' } else .{};
        const got = try expand(allocator, case.input, values, options);
        defer allocator.free(got);
        try std.testing.expectEqualStrings(case.expected, got);
    }
}

test "Dockerfile variable expansion rejects malformed and unstable modifiers" {
    const allocator = std.testing.allocator;
    const invalid = [_][]const u8{
        "${SET",
        "${:-bad}",
        "${SET:?bad}",
        "${SET#prefix}",
        "${SET/value/replacement}",
        "$\xc3\xa9",
        "\"unterminated",
        "'unterminated",
    };
    for (invalid) |input| {
        try std.testing.expectError(
            if (std.mem.indexOfAny(u8, input, "?#/") != null) error.UnsupportedVariableModifier else error.BadVariableSubstitution,
            expand(allocator, input, &.{.{ .key = "SET", .value = "value" }}, .{}),
        );
    }

    var nested = std.array_list.Managed(u8).init(allocator);
    defer nested.deinit();
    for (0..max_expansion_depth + 1) |_| try nested.appendSlice("${MISSING:-");
    try nested.append('x');
    for (0..max_expansion_depth + 1) |_| try nested.append('}');
    try std.testing.expectError(error.BadVariableSubstitution, expand(allocator, nested.items, &.{}, .{}));

    const oversized = try allocator.alloc(u8, max_expanded_word_bytes + 1);
    defer allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.VariableExpansionTooLarge, expand(allocator, "$VALUE", &.{.{ .key = "VALUE", .value = oversized }}, .{}));
}

test "fuzz Dockerfile variable expansion" {
    try std.testing.fuzz({}, fuzzExpansion, .{});
}
