const std = @import("std");

pub const Mode = enum {
    copy,
    dockerignore,
};

pub const max_pattern_bytes = 4096;
const max_pattern_tokens = max_pattern_bytes + 1;

const Range = struct {
    first: u21,
    last: u21,
};

const CharacterClass = struct {
    negated: bool,
    ranges: []const Range,

    fn matches(self: CharacterClass, codepoint: u21) bool {
        var found = false;
        for (self.ranges) |range| {
            if (codepoint >= range.first and codepoint <= range.last) {
                found = true;
                break;
            }
        }
        return if (self.negated) !found else found;
    }
};

const Token = union(enum) {
    literal: u21,
    any,
    star,
    globstar,
    split: usize,
    globstar_until_slash,
    character_class: CharacterClass,
};

pub const Pattern = struct {
    tokens: []const Token,
    literal_directory_prefix: []const u8 = "",

    pub fn compile(allocator: std.mem.Allocator, raw: []const u8, mode: Mode) !Pattern {
        if (raw.len > max_pattern_bytes) return error.PatternTooLong;

        var tokens = std.array_list.Managed(Token).init(allocator);
        var i: usize = 0;
        while (i < raw.len) {
            switch (raw[i]) {
                '*' => {
                    if (mode == .dockerignore and i + 1 < raw.len and raw[i + 1] == '*') {
                        i += 2;
                        if (i < raw.len and raw[i] == '/') {
                            // Docker's **/ is an optional prefix ending in a slash:
                            // it matches both foo and any/number/of/foo.
                            try appendToken(&tokens, .{ .split = tokens.items.len + 2 });
                            try appendToken(&tokens, .globstar_until_slash);
                            i += 1;
                        } else {
                            try appendToken(&tokens, .globstar);
                        }
                    } else {
                        while (i < raw.len and raw[i] == '*') i += 1;
                        try appendToken(&tokens, .star);
                    }
                },
                '?' => {
                    try appendToken(&tokens, .any);
                    i += 1;
                },
                '[' => {
                    const parsed = try parseCharacterClass(allocator, raw, i + 1);
                    try appendToken(&tokens, .{ .character_class = parsed.class });
                    i = parsed.end;
                },
                '\\' => {
                    i += 1;
                    if (i == raw.len) return error.BadPattern;
                    const decoded = decodeCodepoint(raw[i..]);
                    try appendToken(&tokens, .{ .literal = decoded.codepoint });
                    i += decoded.len;
                },
                else => {
                    const decoded = decodeCodepoint(raw[i..]);
                    try appendToken(&tokens, .{ .literal = decoded.codepoint });
                    i += decoded.len;
                },
            }
        }
        return .{
            .tokens = try tokens.toOwnedSlice(),
            .literal_directory_prefix = if (mode == .copy) try literalDirectoryPrefix(allocator, raw) else "",
        };
    }

    pub fn matches(self: Pattern, path: []const u8) bool {
        return self.matchPath(path, false, true);
    }

    pub fn matchesOrParent(self: Pattern, path: []const u8) bool {
        if (std.mem.eql(u8, path, ".")) return false;
        if (self.matches(path)) return true;
        var offset: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, offset, '/')) |slash| {
            if (slash != 0 and self.matches(path[0..slash])) return true;
            offset = slash + 1;
        }
        return false;
    }

    /// Whether this pattern's language can match a path below `directory`.
    /// This permits safe traversal pruning without interpreting literal prefix
    /// strings separately from the matcher.
    pub fn couldMatchDescendant(self: Pattern, directory: []const u8) bool {
        return self.matchPath(directory, true, false);
    }

    /// Whether the COPY expression names this path as an intermediate literal
    /// directory. Encountering a symlink here is an attempted traversal;
    /// symlinks reached only through wildcard components remain terminal.
    pub fn requiresLiteralDirectory(self: Pattern, path: []const u8) bool {
        const prefix = self.literal_directory_prefix;
        if (prefix.len == 0 or path.len > prefix.len) return false;
        if (!std.mem.startsWith(u8, prefix, path)) return false;
        return path.len == prefix.len or prefix[path.len] == '/';
    }

    fn matchPath(self: Pattern, path: []const u8, append_slash: bool, require_accept: bool) bool {
        if (self.tokens.len > max_pattern_tokens) return false;
        var active_storage = [_]bool{false} ** (max_pattern_tokens + 1);
        var next_storage = [_]bool{false} ** (max_pattern_tokens + 1);
        var active = active_storage[0 .. self.tokens.len + 1];
        var next = next_storage[0 .. self.tokens.len + 1];
        active[0] = true;
        epsilonClosure(self.tokens, active);

        var offset: usize = 0;
        while (offset < path.len) {
            const decoded = decodeCodepoint(path[offset..]);
            if (!advance(self.tokens, active, next, decoded.codepoint)) return false;
            std.mem.swap([]bool, &active, &next);
            offset += decoded.len;
        }
        if (append_slash) {
            if (!advance(self.tokens, active, next, '/')) return false;
            std.mem.swap([]bool, &active, &next);
        }
        if (require_accept) return active[self.tokens.len];
        return std.mem.indexOfScalar(bool, active, true) != null;
    }
};

pub fn hasCopyMeta(raw: []const u8) bool {
    return std.mem.indexOfAny(u8, raw, "*?[\\") != null;
}

fn literalDirectoryPrefix(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var literal = std.array_list.Managed(u8).init(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        switch (raw[i]) {
            '*', '?', '[' => break,
            '\\' => {
                i += 1;
                if (i == raw.len) return error.BadPattern;
                const decoded = decodeCodepoint(raw[i..]);
                try literal.appendSlice(raw[i .. i + decoded.len]);
                i += decoded.len;
            },
            else => {
                const decoded = decodeCodepoint(raw[i..]);
                try literal.appendSlice(raw[i .. i + decoded.len]);
                i += decoded.len;
            },
        }
    }
    while (literal.items.len != 0 and literal.items[literal.items.len - 1] == '/') _ = literal.pop();
    if (literal.items.len == 0) return "";
    if (i < raw.len and i != 0 and raw[i - 1] == '/') return literal.toOwnedSlice();
    const slash = std.mem.lastIndexOfScalar(u8, literal.items, '/') orelse return "";
    return allocator.dupe(u8, literal.items[0..slash]);
}

/// Equivalent to Go's strings.TrimSpace for the Unicode White_Space set used
/// by Docker's ignore-file reader.
pub fn trimSpace(raw: []const u8) []const u8 {
    var first_non_space: ?usize = null;
    var end_non_space: usize = 0;
    var offset: usize = 0;
    while (offset < raw.len) {
        const decoded = decodeCodepoint(raw[offset..]);
        if (!isSpace(decoded.codepoint)) {
            if (first_non_space == null) first_non_space = offset;
            end_non_space = offset + decoded.len;
        }
        offset += decoded.len;
    }
    const start = first_non_space orelse return raw[0..0];
    return raw[start..end_non_space];
}

/// filepath.Clean-compatible normalization for slash-delimited ignore
/// patterns. The caller handles comments, whitespace, and negation before
/// calling this function.
pub fn cleanDockerignorePattern(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var components = std.array_list.Managed([]const u8).init(allocator);
    var it = std.mem.splitScalar(u8, raw, '/');
    while (it.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (components.items.len != 0 and !std.mem.eql(u8, components.items[components.items.len - 1], "..")) {
                _ = components.pop();
            } else if (raw.len == 0 or raw[0] != '/') {
                try components.append(component);
            }
            continue;
        }
        try components.append(component);
    }
    if (components.items.len == 0) return allocator.dupe(u8, ".");
    return std.mem.join(allocator, "/", components.items);
}

fn appendToken(tokens: *std.array_list.Managed(Token), token: Token) !void {
    if (tokens.items.len >= max_pattern_tokens) return error.PatternTooLong;
    try tokens.append(token);
}

fn parseCharacterClass(allocator: std.mem.Allocator, raw: []const u8, start: usize) !struct {
    class: CharacterClass,
    end: usize,
} {
    var i = start;
    var negated = false;
    if (i < raw.len and raw[i] == '^') {
        negated = true;
        i += 1;
    }
    var ranges = std.array_list.Managed(Range).init(allocator);
    var saw_range = false;
    while (i < raw.len and raw[i] != ']') {
        const first = try decodeClassCodepoint(raw, &i);
        var last = first;
        if (i < raw.len and raw[i] == '-') {
            i += 1;
            last = try decodeClassCodepoint(raw, &i);
            if (last < first) return error.BadPattern;
        }
        try ranges.append(.{ .first = first, .last = last });
        saw_range = true;
    }
    if (!saw_range or i == raw.len or raw[i] != ']') return error.BadPattern;
    return .{
        .class = .{ .negated = negated, .ranges = try ranges.toOwnedSlice() },
        .end = i + 1,
    };
}

fn decodeClassCodepoint(raw: []const u8, offset: *usize) !u21 {
    if (offset.* == raw.len) return error.BadPattern;
    if (raw[offset.*] == '-' or raw[offset.*] == ']') return error.BadPattern;
    if (raw[offset.*] == '\\') {
        offset.* += 1;
        if (offset.* == raw.len) return error.BadPattern;
    }
    const decoded = decodeCodepoint(raw[offset.*..]);
    if (decoded.codepoint > 0x10ffff) return error.BadPattern;
    offset.* += decoded.len;
    return decoded.codepoint;
}

const Decoded = struct {
    codepoint: u21,
    len: usize,
};

fn decodeCodepoint(bytes: []const u8) Decoded {
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch 1;
    if (len > bytes.len) return .{ .codepoint = @as(u21, 0x110000) + bytes[0], .len = 1 };
    const codepoint = std.unicode.utf8Decode(bytes[0..len]) catch return .{
        .codepoint = @as(u21, 0x110000) + bytes[0],
        .len = 1,
    };
    return .{ .codepoint = codepoint, .len = len };
}

fn isSpace(codepoint: u21) bool {
    return switch (codepoint) {
        0x0009...0x000d,
        0x0020,
        0x0085,
        0x00a0,
        0x1680,
        0x2000...0x200a,
        0x2028,
        0x2029,
        0x202f,
        0x205f,
        0x3000,
        => true,
        else => false,
    };
}

fn epsilonClosure(tokens: []const Token, states: []bool) void {
    for (tokens, 0..) |token, i| {
        if (!states[i]) continue;
        switch (token) {
            .star, .globstar => states[i + 1] = true,
            .split => |target| {
                states[i + 1] = true;
                states[target] = true;
            },
            else => {},
        }
    }
}

fn advance(tokens: []const Token, active: []const bool, next: []bool, codepoint: u21) bool {
    @memset(next, false);
    var any = false;
    for (tokens, 0..) |token, i| {
        if (!active[i]) continue;
        const destination: ?usize = switch (token) {
            .literal => |literal| if (literal == codepoint) i + 1 else null,
            .any => if (codepoint != '/') i + 1 else null,
            .character_class => |class| if (class.matches(codepoint)) i + 1 else null,
            .star => if (codepoint != '/') i else null,
            .globstar => i,
            .globstar_until_slash => i,
            .split => null,
        };
        if (destination) |dest| {
            next[dest] = true;
            any = true;
        }
        switch (token) {
            .globstar_until_slash => if (codepoint == '/') {
                next[i + 1] = true;
                any = true;
            },
            else => {},
        }
    }
    if (!any) return false;
    epsilonClosure(tokens, next);
    return true;
}

fn fuzzPattern(_: void, smith: *std.testing.Smith) !void {
    var pattern_buf: [256]u8 = undefined;
    var path_buf: [256]u8 = undefined;
    const pattern_len = smith.slice(&pattern_buf);
    const path_len = smith.slice(&path_buf);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    for ([_]Mode{ .dockerignore, .copy }) |mode| {
        const pattern = Pattern.compile(arena_state.allocator(), pattern_buf[0..pattern_len], mode) catch continue;
        _ = pattern.matches(path_buf[0..path_len]);
        _ = pattern.matchesOrParent(path_buf[0..path_len]);
        _ = pattern.couldMatchDescendant(path_buf[0..path_len]);
        _ = pattern.requiresLiteralDirectory(path_buf[0..path_len]);
    }
}

test "fuzz path pattern" {
    try std.testing.fuzz({}, fuzzPattern, .{});
}

test "COPY patterns implement filepath match forms" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const cases = [_]struct {
        pattern: []const u8,
        path: []const u8,
        matches: bool,
    }{
        .{ .pattern = "*.config.*", .path = "babel.config.js", .matches = true },
        .{ .pattern = "file?.txt", .path = "file1.txt", .matches = true },
        .{ .pattern = "file?.txt", .path = "file10.txt", .matches = false },
        .{ .pattern = "src/*/main.[ch]", .path = "src/app/main.c", .matches = true },
        .{ .pattern = "src/*/main.[ch]", .path = "src/app/deep/main.c", .matches = false },
        .{ .pattern = "arr[[]0].txt", .path = "arr[0].txt", .matches = true },
        .{ .pattern = "a[^b-d]e", .path = "aze", .matches = true },
        .{ .pattern = "a[^b-d]e", .path = "ace", .matches = false },
        .{ .pattern = "literal\\*star", .path = "literal*star", .matches = true },
        .{ .pattern = "?.txt", .path = "λ.txt", .matches = true },
        .{ .pattern = "*", .path = ".hidden", .matches = true },
        .{ .pattern = "src[/]main.c", .path = "src/main.c", .matches = true },
        .{ .pattern = "**/*.txt", .path = "deep/file.txt", .matches = true },
        .{ .pattern = "**/*.txt", .path = "deep/nested/file.txt", .matches = false },
    };
    for (cases) |case| {
        const pattern = try Pattern.compile(allocator, case.pattern, .copy);
        try std.testing.expectEqual(case.matches, pattern.matches(case.path));
    }
    try std.testing.expectError(error.BadPattern, Pattern.compile(allocator, "[a-]", .copy));
    try std.testing.expectError(error.BadPattern, Pattern.compile(allocator, "[-a]", .copy));
}

test "dockerignore globstars match zero or many directories" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const pattern = try Pattern.compile(allocator, "**/generated/**", .dockerignore);
    try std.testing.expect(pattern.matches("generated/file"));
    try std.testing.expect(pattern.matches("src/generated/deep/file"));
    try std.testing.expect(!pattern.matches("src/generator/file"));
}

test "descendant reachability is conservative and prefix aware" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const literal = try Pattern.compile(allocator, "vendor/keep.txt", .dockerignore);
    try std.testing.expect(literal.couldMatchDescendant("vendor"));
    try std.testing.expect(!literal.couldMatchDescendant("build"));
    const wildcard = try Pattern.compile(allocator, "**/keep.txt", .dockerignore);
    try std.testing.expect(wildcard.couldMatchDescendant("build"));

    const copy_literal = try Pattern.compile(allocator, "packages/*.txt", .copy);
    try std.testing.expect(copy_literal.requiresLiteralDirectory("packages"));
    const copy_broad = try Pattern.compile(allocator, "**/*.txt", .copy);
    try std.testing.expect(!copy_broad.requiresLiteralDirectory("packages"));
    const explicit_separator = try Pattern.compile(allocator, "files[/]plain.txt", .copy);
    try std.testing.expect(explicit_separator.couldMatchDescendant("files"));
}

test "dockerignore cleaning follows slash path clean semantics" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    try std.testing.expectEqualStrings("foo/bar", try cleanDockerignorePattern(allocator, "/foo/./tmp/../bar/"));
    try std.testing.expectEqualStrings("../foo", try cleanDockerignorePattern(allocator, "../foo"));
    try std.testing.expectEqualStrings(".", try cleanDockerignorePattern(allocator, "./"));
    try std.testing.expectEqualStrings("pattern", trimSpace("\u{2003}pattern\u{00a0}"));
}
