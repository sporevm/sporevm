const std = @import("std");

pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

pub const Document = struct {
    instructions: []Instruction,
};

pub const Instruction = struct {
    line: usize,
    raw: []const u8,
    value: Value,

    pub const Value = union(enum) {
        from: From,
        run: Run,
        copy: Copy,
        env: Env,
        arg: Arg,
        workdir: []const u8,
        cmd: Cmd,
    };
};

pub const From = struct {
    source: []const u8,
};

pub const Run = struct {
    shell: []const u8,
};

pub const Copy = struct {
    sources: []const []const u8,
    dest: []const u8,
};

pub const Env = struct {
    pairs: []const Pair,
};

pub const Pair = struct {
    key: []const u8,
    value: []const u8,
};

pub const Arg = struct {
    key: []const u8,
    default: ?[]const u8 = null,
};

pub const Cmd = union(enum) {
    shell: []const u8,
    exec: []const []const u8,
};

const LogicalLine = struct {
    line: usize,
    text: []const u8,
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, diagnostic: *Diagnostic) !Document {
    diagnostic.* = .{};
    var lines = std.array_list.Managed(LogicalLine).init(allocator);
    try logicalLines(allocator, bytes, &lines, diagnostic);

    var instructions = std.array_list.Managed(Instruction).init(allocator);
    for (lines.items) |line| {
        const trimmed = std.mem.trim(u8, line.text, " \t\r\n");
        if (trimmed.len == 0) continue;
        const space = firstSpace(trimmed) orelse trimmed.len;
        const op = trimmed[0..space];
        const rest = std.mem.trimStart(u8, trimmed[space..], " \t");
        const raw = try allocator.dupe(u8, trimmed);
        const value = parseInstruction(allocator, line.line, op, rest, diagnostic) catch return error.DockerfileParseFailed;
        try instructions.append(.{ .line = line.line, .raw = raw, .value = value });
    }
    return .{ .instructions = try instructions.toOwnedSlice() };
}

fn parseInstruction(
    allocator: std.mem.Allocator,
    line: usize,
    op: []const u8,
    rest: []const u8,
    diagnostic: *Diagnostic,
) !Instruction.Value {
    if (asciiEql(op, "FROM")) {
        const args = try splitWords(allocator, rest, line, diagnostic);
        if (args.len != 1) return fail(diagnostic, line, "unsupported FROM form; expected exactly `FROM <name>`");
        if (std.mem.startsWith(u8, args[0], "--")) return fail(diagnostic, line, "unsupported FROM flag");
        if (asciiEql(args[0], "AS")) return fail(diagnostic, line, "unsupported multi-stage FROM");
        return .{ .from = .{ .source = args[0] } };
    }
    if (asciiEql(op, "RUN")) {
        if (rest.len == 0) return fail(diagnostic, line, "RUN requires a shell command");
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, rest, " \t"), "--")) return fail(diagnostic, line, "unsupported RUN flag");
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, rest, " \t"), "[")) return fail(diagnostic, line, "unsupported exec-form RUN");
        if (std.mem.indexOf(u8, rest, "<<") != null) return fail(diagnostic, line, "unsupported RUN heredoc");
        return .{ .run = .{ .shell = try allocator.dupe(u8, rest) } };
    }
    if (asciiEql(op, "COPY")) {
        if (std.mem.indexOf(u8, rest, "<<") != null) return fail(diagnostic, line, "unsupported COPY heredoc");
        const args = try splitWords(allocator, rest, line, diagnostic);
        if (args.len < 2) return fail(diagnostic, line, "COPY requires at least one source and a destination");
        if (std.mem.startsWith(u8, args[0], "--")) return fail(diagnostic, line, "unsupported COPY flag");
        return .{ .copy = .{ .sources = args[0 .. args.len - 1], .dest = args[args.len - 1] } };
    }
    if (asciiEql(op, "ENV")) {
        const pairs = try parseEnv(allocator, rest, line, diagnostic);
        return .{ .env = .{ .pairs = pairs } };
    }
    if (asciiEql(op, "ARG")) {
        const args = try splitWords(allocator, rest, line, diagnostic);
        if (args.len != 1) return fail(diagnostic, line, "ARG requires exactly one name or name=default");
        const eq = std.mem.indexOfScalar(u8, args[0], '=');
        const key = if (eq) |idx| args[0][0..idx] else args[0];
        if (!validName(key)) return fail(diagnostic, line, "ARG has an invalid name");
        return .{ .arg = .{ .key = key, .default = if (eq) |idx| args[0][idx + 1 ..] else null } };
    }
    if (asciiEql(op, "WORKDIR")) {
        const args = try splitWords(allocator, rest, line, diagnostic);
        if (args.len != 1) return fail(diagnostic, line, "WORKDIR requires exactly one path");
        return .{ .workdir = args[0] };
    }
    if (asciiEql(op, "CMD")) {
        if (rest.len == 0) return fail(diagnostic, line, "CMD requires a command");
        return .{ .cmd = try parseCmd(allocator, rest, line, diagnostic) };
    }
    const message = try std.fmt.allocPrint(allocator, "unsupported Dockerfile instruction: {s}", .{op});
    diagnostic.* = .{ .line = line, .message = message };
    return error.DockerfileParseFailed;
}

fn logicalLines(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    lines: *std.array_list.Managed(LogicalLine),
    diagnostic: *Diagnostic,
) !void {
    var current = std.array_list.Managed(u8).init(allocator);
    var current_line: usize = 1;
    var continuing = false;
    var line_no: usize = 1;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw_line| : (line_no += 1) {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const trimmed_left = std.mem.trimStart(u8, line, " \t");
        if (!continuing and (trimmed_left.len == 0 or trimmed_left[0] == '#')) continue;
        if (!continuing) current_line = line_no;
        const trimmed_right = std.mem.trimEnd(u8, line, " \t");
        const has_continuation = trimmed_right.len != 0 and trimmed_right[trimmed_right.len - 1] == '\\';
        const part = if (has_continuation) trimmed_right[0 .. trimmed_right.len - 1] else line;
        if (continuing) try current.append(' ');
        try current.appendSlice(part);
        continuing = has_continuation;
        if (!continuing) {
            try lines.append(.{ .line = current_line, .text = try current.toOwnedSlice() });
            current = std.array_list.Managed(u8).init(allocator);
        }
    }
    if (continuing) return fail(diagnostic, current_line, "unterminated Dockerfile line continuation");
}

fn parseEnv(
    allocator: std.mem.Allocator,
    rest: []const u8,
    line: usize,
    diagnostic: *Diagnostic,
) ![]const Pair {
    const words = try splitWords(allocator, rest, line, diagnostic);
    if (words.len == 0) return fail(diagnostic, line, "ENV requires at least one key/value pair");
    var pairs = std.array_list.Managed(Pair).init(allocator);
    var all_equals = true;
    for (words) |word| {
        if (std.mem.indexOfScalar(u8, word, '=') == null) {
            all_equals = false;
            break;
        }
    }
    if (all_equals) {
        for (words) |word| {
            const eq = std.mem.indexOfScalar(u8, word, '=').?;
            const key = word[0..eq];
            if (!validName(key)) return fail(diagnostic, line, "ENV has an invalid name");
            try pairs.append(.{ .key = key, .value = word[eq + 1 ..] });
        }
        return pairs.toOwnedSlice();
    }
    if (words.len < 2) return fail(diagnostic, line, "ENV requires KEY VALUE or KEY=VALUE");
    if (!validName(words[0])) return fail(diagnostic, line, "ENV has an invalid name");
    const value_start = std.mem.indexOf(u8, rest, words[1]) orelse return fail(diagnostic, line, "ENV requires KEY VALUE");
    try pairs.append(.{ .key = words[0], .value = std.mem.trimStart(u8, rest[value_start..], " \t") });
    return pairs.toOwnedSlice();
}

fn parseCmd(
    allocator: std.mem.Allocator,
    rest: []const u8,
    line: usize,
    diagnostic: *Diagnostic,
) !Cmd {
    const trimmed = std.mem.trimStart(u8, rest, " \t");
    if (!std.mem.startsWith(u8, trimmed, "[")) return .{ .shell = try allocator.dupe(u8, rest) };
    var parsed = std.json.parseFromSlice([][]const u8, allocator, trimmed, .{ .allocate = .alloc_always }) catch {
        return fail(diagnostic, line, "CMD exec form must be a JSON string array");
    };
    defer parsed.deinit();
    return .{ .exec = try cloneStringList(allocator, parsed.value) };
}

fn splitWords(
    allocator: std.mem.Allocator,
    input: []const u8,
    line: usize,
    diagnostic: *Diagnostic,
) ![]const []const u8 {
    var out = std.array_list.Managed([]const u8).init(allocator);
    var i: usize = 0;
    while (true) {
        while (i < input.len and std.ascii.isWhitespace(input[i])) i += 1;
        if (i >= input.len) break;
        var word = std.array_list.Managed(u8).init(allocator);
        var quote: ?u8 = null;
        while (i < input.len) : (i += 1) {
            const c = input[i];
            if (quote) |q| {
                if (c == q) {
                    quote = null;
                    continue;
                }
                if (c == '\\' and q == '"' and i + 1 < input.len) {
                    i += 1;
                    try word.append(input[i]);
                    continue;
                }
                try word.append(c);
                continue;
            }
            if (std.ascii.isWhitespace(c)) break;
            if (c == '\'' or c == '"') {
                quote = c;
                continue;
            }
            if (c == '\\' and i + 1 < input.len) {
                i += 1;
                try word.append(input[i]);
                continue;
            }
            try word.append(c);
        }
        if (quote != null) return fail(diagnostic, line, "unterminated quoted Dockerfile argument");
        try out.append(try word.toOwnedSlice());
    }
    return out.toOwnedSlice();
}

fn cloneStringList(allocator: std.mem.Allocator, entries: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, entries.len);
    for (entries, 0..) |entry, i| out[i] = try allocator.dupe(u8, entry);
    return out;
}

fn firstSpace(bytes: []const u8) ?usize {
    for (bytes, 0..) |c, i| if (std.ascii.isWhitespace(c)) return i;
    return null;
}

fn asciiEql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, i| {
        if (i == 0 and !(std.ascii.isAlphabetic(c) or c == '_')) return false;
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

fn fail(diagnostic: *Diagnostic, line: usize, message: []const u8) error{DockerfileParseFailed} {
    diagnostic.* = .{ .line = line, .message = message };
    return error.DockerfileParseFailed;
}

fn fuzzDockerfile(_: void, s: *std.testing.Smith) !void {
    var buf: [2048]u8 = undefined;
    const len = s.slice(&buf);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    _ = parse(arena_state.allocator(), buf[0..len], &diag) catch {};
}

test "fuzz Dockerfile subset parser" {
    try std.testing.fuzz({}, fuzzDockerfile, .{});
}

test "Dockerfile parser accepts supported subset" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const doc = try parse(arena_state.allocator(),
        \\# syntax is a comment for this subset
        \\FROM base
        \\ARG RAILS_ENV=test
        \\ENV PATH=/usr/bin FOO=bar
        \\WORKDIR /app
        \\COPY Gemfile* ./
        \\RUN bundle install
        \\CMD ["/bin/sh","-c","echo ok"]
        \\
    , &diag);
    try std.testing.expectEqual(@as(usize, 7), doc.instructions.len);
    try std.testing.expectEqualStrings("base", doc.instructions[0].value.from.source);
}

test "Dockerfile parser fails closed on unsupported features" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), "RUN --mount=type=cache true\n", &diag));
    try std.testing.expectEqualStrings("unsupported RUN flag", diag.message);
}
