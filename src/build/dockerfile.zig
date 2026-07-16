const std = @import("std");
const remote_add_policy = @import("remote_add_policy.zig");
const run_contract = @import("run_contract.zig");
const variable_expansion = @import("variables.zig");

pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

pub const Document = struct {
    directives: Directives = .{},
    global_args: []Instruction = &.{},
    stages: []Stage = &.{},
};

pub const Directives = struct {
    syntax: ?[]const u8 = null,
    escape: u8 = '\\',
};

pub const Span = struct {
    start_line: usize,
    end_line: usize,
};

pub const Stage = struct {
    index: usize,
    span: Span,
    from: Instruction,
    name: ?[]const u8,
    instructions: []Instruction,
};

pub const Instruction = struct {
    line: usize,
    span: Span,
    raw: []const u8,
    escape: u8 = '\\',
    value: Value,

    pub const Value = union(enum) {
        from: From,
        run: Run,
        copy: Copy,
        add: Add,
        env: Env,
        arg: Arg,
        workdir: []const u8,
        cmd: Cmd,
        entrypoint: Cmd,
    };
};

pub const From = struct {
    source: []const u8,
    platform: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

pub const Run = union(enum) {
    shell: []const u8,
    exec: []const []const u8,
};

pub const Copy = struct {
    from: ?[]const u8 = null,
    sources: []const []const u8,
    dest: []const u8,
};

pub const Add = struct {
    source: []const u8,
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
    end_line: usize,
    text: []const u8,
};

const max_dockerfile_bytes = 1024 * 1024;
const max_logical_line_bytes = 64 * 1024;
const max_stages = 256;
pub const max_run_exec_args = run_contract.max_exec_args;
pub const max_run_exec_args_bytes = run_contract.max_exec_args_bytes;

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, diagnostic: *Diagnostic) !Document {
    diagnostic.* = .{};
    if (bytes.len > max_dockerfile_bytes) return fail(diagnostic, 1, "Dockerfile is too large");
    const directives = try parseDirectives(allocator, bytes, diagnostic);
    var lines = std.array_list.Managed(LogicalLine).init(allocator);
    try logicalLines(allocator, bytes, directives.escape, &lines, diagnostic);

    var instructions = std.array_list.Managed(Instruction).init(allocator);
    for (lines.items) |line| {
        const trimmed = std.mem.trim(u8, line.text, " \t\r\n");
        if (trimmed.len == 0) continue;
        const space = firstSpace(trimmed) orelse trimmed.len;
        const op = trimmed[0..space];
        const rest = std.mem.trimStart(u8, trimmed[space..], " \t");
        const raw = try allocator.dupe(u8, trimmed);
        const value = parseInstruction(allocator, line.line, op, rest, directives.escape, diagnostic) catch return error.DockerfileParseFailed;
        try instructions.append(.{
            .line = line.line,
            .span = .{ .start_line = line.line, .end_line = line.end_line },
            .raw = raw,
            .escape = directives.escape,
            .value = value,
        });
    }
    const owned = try instructions.toOwnedSlice();
    var global_count: usize = 0;
    while (global_count < owned.len and owned[global_count].value == .arg) : (global_count += 1) {}

    var stages = std.array_list.Managed(Stage).init(allocator);
    var cursor = global_count;
    while (cursor < owned.len) {
        if (owned[cursor].value != .from) return fail(diagnostic, owned[cursor].line, "Dockerfile instruction must follow FROM");
        const start = cursor;
        cursor += 1;
        while (cursor < owned.len and owned[cursor].value != .from) : (cursor += 1) {}
        const from = owned[start];
        if (stages.items.len == max_stages) return fail(diagnostic, from.line, "Dockerfile has too many stages");
        try stages.append(.{
            .index = stages.items.len,
            .span = .{
                .start_line = from.span.start_line,
                .end_line = if (cursor == start + 1) from.span.end_line else owned[cursor - 1].span.end_line,
            },
            .from = from,
            .name = from.value.from.name,
            .instructions = owned[start + 1 .. cursor],
        });
    }
    if (stages.items.len == 0) return fail(diagnostic, 1, "Dockerfile requires at least one FROM instruction");
    return .{
        .directives = directives,
        .global_args = owned[0..global_count],
        .stages = try stages.toOwnedSlice(),
    };
}

fn parseInstruction(
    allocator: std.mem.Allocator,
    line: usize,
    op: []const u8,
    rest: []const u8,
    escape: u8,
    diagnostic: *Diagnostic,
) !Instruction.Value {
    if (asciiEql(op, "FROM")) {
        const args = try splitWords(allocator, rest, escape, line, diagnostic);
        if (args.len == 0) return fail(diagnostic, line, "FROM requires a source image");
        var index: usize = 0;
        var platform: ?[]const u8 = null;
        if (std.mem.startsWith(u8, args[index].value, "--")) {
            if (!std.mem.startsWith(u8, args[index].value, "--platform=") or args[index].value.len == "--platform=".len or
                !std.mem.startsWith(u8, args[index].raw, "--platform="))
            {
                return fail(diagnostic, line, "unsupported FROM flag");
            }
            platform = args[index].raw["--platform=".len..];
            try validateExpansion(allocator, platform.?, escape, line, diagnostic);
            index += 1;
        }
        if (index >= args.len) return fail(diagnostic, line, "FROM requires a source image");
        const source = args[index].raw;
        try validateExpansion(allocator, source, escape, line, diagnostic);
        index += 1;
        var name: ?[]const u8 = null;
        if (index < args.len) {
            if (!asciiEql(args[index].value, "AS") or index + 2 != args.len) {
                return fail(diagnostic, line, "unsupported FROM form; expected `FROM [--platform=<platform>] <name> [AS <stage>]`");
            }
            if (!validStageName(args[index + 1].value)) return fail(diagnostic, line, "FROM AS has an invalid stage name");
            name = args[index + 1].value;
            index += 2;
        }
        if (index != args.len) return fail(diagnostic, line, "unsupported FROM form");
        return .{ .from = .{ .source = source, .platform = platform, .name = name } };
    }
    if (asciiEql(op, "RUN")) {
        if (rest.len == 0) return fail(diagnostic, line, "RUN requires a shell command");
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, rest, " \t"), "--")) return fail(diagnostic, line, "unsupported RUN flag");
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, rest, " \t"), "[")) {
            return .{ .run = .{ .exec = try parseRunExec(allocator, rest, line, diagnostic) } };
        }
        if (std.mem.indexOf(u8, rest, "<<") != null) return fail(diagnostic, line, "unsupported RUN heredoc");
        return .{ .run = .{ .shell = try allocator.dupe(u8, rest) } };
    }
    if (asciiEql(op, "COPY")) {
        if (std.mem.indexOf(u8, rest, "<<") != null) return fail(diagnostic, line, "unsupported COPY heredoc");
        const args = try splitWords(allocator, rest, escape, line, diagnostic);
        var first_source: usize = 0;
        var from: ?[]const u8 = null;
        while (first_source < args.len and std.mem.startsWith(u8, args[first_source].value, "--")) : (first_source += 1) {
            const arg = args[first_source];
            if (std.mem.startsWith(u8, arg.value, "--from=") and arg.value.len > "--from=".len and from == null and
                std.mem.startsWith(u8, arg.raw, "--from="))
            {
                from = arg.raw["--from=".len..];
                const resolved = variable_expansion.expand(allocator, from.?, &.{}, .{ .escape = escape }) catch {
                    return fail(diagnostic, line, "COPY --from does not support variable expansion or quoting");
                };
                defer allocator.free(resolved);
                if (!std.mem.eql(u8, resolved, from.?)) return fail(diagnostic, line, "COPY --from does not support variable expansion or quoting");
                continue;
            }
            const flag = if (std.mem.indexOfScalar(u8, arg.value, '=')) |eq| arg.value[0..eq] else arg.value;
            const message = try std.fmt.allocPrint(allocator, "unsupported COPY flag: {s}", .{flag});
            return fail(diagnostic, line, message);
        }
        if (args.len - first_source < 2) return fail(diagnostic, line, "COPY requires at least one source and a destination");
        for (args[first_source..]) |arg| {
            if (std.mem.startsWith(u8, arg.value, "--")) {
                const flag = if (std.mem.indexOfScalar(u8, arg.value, '=')) |eq| arg.value[0..eq] else arg.value;
                const message = try std.fmt.allocPrint(allocator, "unsupported COPY flag: {s}", .{flag});
                return fail(diagnostic, line, message);
            }
            try validateExpansion(allocator, arg.raw, escape, line, diagnostic);
        }
        const sources = try allocator.alloc([]const u8, args.len - first_source - 1);
        for (args[first_source .. args.len - 1], sources) |arg, *source_arg| source_arg.* = arg.raw;
        return .{ .copy = .{ .from = from, .sources = sources, .dest = args[args.len - 1].raw } };
    }
    if (asciiEql(op, "ADD")) {
        if (std.mem.indexOf(u8, rest, "<<") != null) return fail(diagnostic, line, "unsupported ADD heredoc");
        const args = try splitWords(allocator, rest, escape, line, diagnostic);
        for (args) |arg| {
            if (std.mem.startsWith(u8, arg.value, "--")) {
                const message = try std.fmt.allocPrint(allocator, "unsupported ADD flag: {s}", .{arg.value});
                return fail(diagnostic, line, message);
            }
        }
        if (args.len != 2) return fail(diagnostic, line, "remote ADD requires exactly one source and one destination");
        if (!remote_add_policy.validateTemplate(args[0].value)) return fail(diagnostic, line, "remote ADD source must have a literal HTTPS authority");
        if (hasParentPathSegment(args[1].value)) return fail(diagnostic, line, "remote ADD destination must not contain a parent path segment");
        for (args) |arg| {
            try validateExpansion(allocator, arg.raw, escape, line, diagnostic);
        }
        return .{ .add = .{ .source = args[0].raw, .dest = args[1].raw } };
    }
    if (asciiEql(op, "ENV")) {
        const pairs = try parseEnv(allocator, rest, escape, line, diagnostic);
        return .{ .env = .{ .pairs = pairs } };
    }
    if (asciiEql(op, "ARG")) {
        const args = try splitWords(allocator, rest, escape, line, diagnostic);
        if (args.len != 1) return fail(diagnostic, line, "ARG requires exactly one name or name=default");
        const eq = std.mem.indexOfScalar(u8, args[0].value, '=');
        const key = if (eq) |idx| args[0].value[0..idx] else args[0].value;
        if (!validName(key)) return fail(diagnostic, line, "ARG has an invalid name");
        const default = if (eq != null) blk: {
            const raw_eq = std.mem.indexOfScalar(u8, args[0].raw, '=') orelse return fail(diagnostic, line, "ARG has an invalid default");
            const raw_default = args[0].raw[raw_eq + 1 ..];
            try validateExpansion(allocator, raw_default, escape, line, diagnostic);
            break :blk raw_default;
        } else null;
        return .{ .arg = .{ .key = key, .default = default } };
    }
    if (asciiEql(op, "WORKDIR")) {
        const args = try splitWords(allocator, rest, escape, line, diagnostic);
        if (args.len != 1) return fail(diagnostic, line, "WORKDIR requires exactly one path");
        try validateExpansion(allocator, args[0].raw, escape, line, diagnostic);
        return .{ .workdir = args[0].raw };
    }
    if (asciiEql(op, "CMD")) {
        if (rest.len == 0) return fail(diagnostic, line, "CMD requires a command");
        return .{ .cmd = try parseCmd(allocator, rest, line, diagnostic) };
    }
    if (asciiEql(op, "ENTRYPOINT")) {
        if (rest.len == 0) return fail(diagnostic, line, "ENTRYPOINT requires a command");
        return .{ .entrypoint = try parseCmd(allocator, rest, line, diagnostic) };
    }
    const message = try std.fmt.allocPrint(allocator, "unsupported Dockerfile instruction: {s}", .{op});
    diagnostic.* = .{ .line = line, .message = message };
    return error.DockerfileParseFailed;
}

fn hasParentPathSegment(path: []const u8) bool {
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| if (std.mem.eql(u8, segment, "..")) return true;
    return false;
}

fn logicalLines(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    escape: u8,
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
        if (trimmed_left.len == 0) continue;
        if (trimmed_left[0] == '#') continue;
        if (!continuing) current_line = line_no;
        const trimmed_right = std.mem.trimEnd(u8, line, " \t");
        const has_continuation = trimmed_right.len != 0 and trimmed_right[trimmed_right.len - 1] == escape;
        const part = if (has_continuation) trimmed_right[0 .. trimmed_right.len - 1] else line;
        if (continuing) try current.append(' ');
        try current.appendSlice(part);
        if (current.items.len > max_logical_line_bytes) return fail(diagnostic, current_line, "Dockerfile logical line is too long");
        continuing = has_continuation;
        if (!continuing) {
            try lines.append(.{ .line = current_line, .end_line = line_no, .text = try current.toOwnedSlice() });
            current = std.array_list.Managed(u8).init(allocator);
        }
    }
    if (continuing) return fail(diagnostic, current_line, "unterminated Dockerfile line continuation");
}

fn parseDirectives(allocator: std.mem.Allocator, bytes: []const u8, diagnostic: *Diagnostic) !Directives {
    var directives: Directives = .{};
    var saw_escape = false;
    var line_no: usize = 1;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw_line| : (line_no += 1) {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) break;
        if (line[0] != '#') break;
        const body = std.mem.trimStart(u8, line[1..], " \t");
        if (asciiStartsWith(body, "syntax=")) {
            if (directives.syntax != null) return fail(diagnostic, line_no, "duplicate syntax parser directive");
            const value = std.mem.trim(u8, body["syntax=".len..], " \t");
            if (value.len == 0) return fail(diagnostic, line_no, "syntax parser directive requires a value");
            if (!supportedSyntaxDirective(value)) return fail(diagnostic, line_no, "unsupported Dockerfile syntax frontend");
            directives.syntax = try allocator.dupe(u8, value);
        } else if (asciiStartsWith(body, "escape=")) {
            if (saw_escape) return fail(diagnostic, line_no, "duplicate escape parser directive");
            const value = std.mem.trim(u8, body["escape=".len..], " \t");
            if (value.len != 1 or (value[0] != '\\' and value[0] != '`')) {
                return fail(diagnostic, line_no, "escape parser directive must be `\\` or ```");
            }
            directives.escape = value[0];
            saw_escape = true;
        } else break;
    }
    return directives;
}

fn supportedSyntaxDirective(value: []const u8) bool {
    const normalized = if (std.mem.startsWith(u8, value, "docker.io/")) value["docker.io/".len..] else value;
    const prefix = "docker/dockerfile:";
    if (!std.mem.startsWith(u8, normalized, prefix)) return false;
    const version = normalized[prefix.len..];
    if (version.len == 0 or version[0] != '1') return false;
    if (version.len == 1) return true;
    return version[1] == '.' or version[1] == '@';
}

fn validateExpansion(allocator: std.mem.Allocator, input: []const u8, escape: u8, line: usize, diagnostic: *Diagnostic) !void {
    variable_expansion.validate(allocator, input, .{ .escape = escape }) catch |err| switch (err) {
        error.BadVariableSubstitution, error.UnsupportedVariableModifier => return fail(diagnostic, line, "unsupported variable expansion"),
        error.VariableExpansionTooLarge => return fail(diagnostic, line, "expanded Dockerfile argument is too large"),
        else => |other| return other,
    };
}

fn parseEnv(
    allocator: std.mem.Allocator,
    rest: []const u8,
    escape: u8,
    line: usize,
    diagnostic: *Diagnostic,
) ![]const Pair {
    const words = try splitWords(allocator, rest, escape, line, diagnostic);
    if (words.len == 0) return fail(diagnostic, line, "ENV requires at least one key/value pair");
    var pairs = std.array_list.Managed(Pair).init(allocator);
    var all_equals = true;
    for (words) |word| {
        if (std.mem.indexOfScalar(u8, word.value, '=') == null) {
            all_equals = false;
            break;
        }
    }
    if (all_equals) {
        for (words) |word| {
            const eq = std.mem.indexOfScalar(u8, word.value, '=').?;
            const key = word.value[0..eq];
            if (!validName(key)) return fail(diagnostic, line, "ENV has an invalid name");
            const raw_eq = std.mem.indexOfScalar(u8, word.raw, '=') orelse return fail(diagnostic, line, "ENV has an invalid value");
            const value = word.raw[raw_eq + 1 ..];
            try validateExpansion(allocator, value, escape, line, diagnostic);
            try pairs.append(.{ .key = key, .value = value });
        }
        return pairs.toOwnedSlice();
    }
    if (words.len < 2) return fail(diagnostic, line, "ENV requires KEY VALUE or KEY=VALUE");
    if (!validName(words[0].value)) return fail(diagnostic, line, "ENV has an invalid name");
    const value = std.mem.trimStart(u8, rest[words[1].start..], " \t");
    try validateExpansion(allocator, value, escape, line, diagnostic);
    try pairs.append(.{ .key = words[0].value, .value = value });
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

fn parseRunExec(
    allocator: std.mem.Allocator,
    rest: []const u8,
    line: usize,
    diagnostic: *Diagnostic,
) ![]const []const u8 {
    const trimmed = std.mem.trimStart(u8, rest, " \t");
    var parsed = std.json.parseFromSlice([][]const u8, allocator, trimmed, .{ .allocate = .alloc_always }) catch {
        return fail(diagnostic, line, "RUN exec form must be a non-empty JSON string array");
    };
    defer parsed.deinit();
    if (run_contract.execArgvViolation(parsed.value)) |violation| switch (violation) {
        .empty => return fail(diagnostic, line, "RUN exec form must be a non-empty JSON string array"),
        .empty_executable => return fail(diagnostic, line, "RUN exec form requires a non-empty executable"),
        .too_many_args => return fail(diagnostic, line, "RUN exec form has too many arguments; limit is 16"),
        .nul => return fail(diagnostic, line, "RUN exec form arguments cannot contain NUL bytes"),
        .decoded_too_large => return fail(diagnostic, line, "RUN exec form arguments are too large; limit is 4096 decoded bytes"),
    };
    return cloneStringList(allocator, parsed.value);
}

const WordToken = struct {
    raw: []const u8,
    value: []const u8,
    start: usize,
};

fn splitWords(
    allocator: std.mem.Allocator,
    input: []const u8,
    escape: u8,
    line: usize,
    diagnostic: *Diagnostic,
) ![]const WordToken {
    var out = std.array_list.Managed(WordToken).init(allocator);
    var i: usize = 0;
    while (true) {
        while (i < input.len and std.ascii.isWhitespace(input[i])) i += 1;
        if (i >= input.len) break;
        const start = i;
        var word = std.array_list.Managed(u8).init(allocator);
        var quote: ?u8 = null;
        while (i < input.len) : (i += 1) {
            const c = input[i];
            if (quote) |q| {
                if (c == q) {
                    quote = null;
                    continue;
                }
                if (c == escape and q == '"' and i + 1 < input.len) {
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
            if (c == escape and i + 1 < input.len) {
                i += 1;
                try word.append(input[i]);
                continue;
            }
            try word.append(c);
        }
        if (quote != null) return fail(diagnostic, line, "unterminated quoted Dockerfile argument");
        try out.append(.{ .raw = input[start..i], .value = try word.toOwnedSlice(), .start = start });
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

fn asciiStartsWith(bytes: []const u8, prefix: []const u8) bool {
    return bytes.len >= prefix.len and std.ascii.eqlIgnoreCase(bytes[0..prefix.len], prefix);
}

fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, i| {
        if (i == 0 and !(std.ascii.isAlphabetic(c) or c == '_')) return false;
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

fn validStageName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return false;
    var all_digits = true;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-')) return false;
        all_digits = all_digits and std.ascii.isDigit(c);
    }
    return !all_digits;
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
    try std.testing.expectEqual(@as(usize, 1), doc.stages.len);
    try std.testing.expectEqual(@as(usize, 6), doc.stages[0].instructions.len);
    try std.testing.expectEqualStrings("base", doc.stages[0].from.value.from.source);
}

test "Dockerfile parser fails closed on unsupported features" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), "RUN --mount=type=cache true\n", &diag));
    try std.testing.expectEqualStrings("unsupported RUN flag", diag.message);
}

test "Dockerfile parser accepts standard parser directives" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const syntax = try parse(arena_state.allocator(), "# syntax=docker/dockerfile:1\nFROM base\n", &diag);
    try std.testing.expectEqualStrings("docker/dockerfile:1", syntax.directives.syntax.?);
    try std.testing.expectEqual(@as(u8, '\\'), syntax.directives.escape);

    const escaped = try parse(arena_state.allocator(), "# escape=`\nFROM base`\n  AS final\n", &diag);
    try std.testing.expectEqual(@as(u8, '`'), escaped.directives.escape);
    try std.testing.expectEqualStrings("final", escaped.stages[0].name.?);
    try std.testing.expectEqual(@as(usize, 2), escaped.stages[0].from.span.start_line);
    try std.testing.expectEqual(@as(usize, 3), escaped.stages[0].from.span.end_line);

    const literal_backslash = try parse(arena_state.allocator(), "# escape=`\nFROM base\nARG VALUE=left\\right\n", &diag);
    try std.testing.expectEqualStrings("left\\right", literal_backslash.stages[0].instructions[0].value.arg.default.?);

    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), "# syntax=docker/dockerfile:labs\nFROM base\n", &diag));
    try std.testing.expectEqualStrings("unsupported Dockerfile syntax frontend", diag.message);

    const outside_window = try parse(arena_state.allocator(), "# ordinary comment\n# syntax=example/custom:latest\nFROM base\n", &diag);
    try std.testing.expect(outside_window.directives.syntax == null);

    const blank_closes_window = try parse(arena_state.allocator(), "# syntax=docker/dockerfile:1\n\n# escape=`\nFROM scratch\n", &diag);
    try std.testing.expectEqual(@as(u8, '\\'), blank_closes_window.directives.escape);
}

test "Dockerfile parser removes comments inside continuations" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var diagnostic: Diagnostic = .{};

    const default_escape = try parse(allocator,
        \\FROM scratch
        \\RUN echo one \
        \\    # explain the next command
        \\
        \\    && echo two
        \\
    , &diagnostic);
    const default_shell = default_escape.stages[0].instructions[0].value.run.shell;
    try std.testing.expect(std.mem.indexOfScalar(u8, default_shell, '#') == null);
    try std.testing.expect(std.mem.indexOf(u8, default_shell, "&& echo two") != null);

    const backtick_crlf = "# escape=`\r\nFROM scratch\r\nRUN echo one `\r\n  # comment\r\n  && echo two\r\n";
    const backtick_escape = try parse(allocator, backtick_crlf, &diagnostic);
    const backtick_shell = backtick_escape.stages[0].instructions[0].value.run.shell;
    try std.testing.expect(std.mem.indexOfScalar(u8, backtick_shell, '#') == null);
    try std.testing.expect(std.mem.indexOf(u8, backtick_shell, "&& echo two") != null);
}

test "Dockerfile parser leaves command variables for runtime expansion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const document = try parse(arena_state.allocator(),
        \\FROM scratch
        \\ENTRYPOINT ["app", "$TOKEN"]
        \\CMD echo "${VALUE:-default}"
        \\
    , &diagnostic);
    try std.testing.expectEqualStrings("$TOKEN", document.stages[0].instructions[0].value.entrypoint.exec[1]);
    try std.testing.expectEqualStrings("echo \"${VALUE:-default}\"", document.stages[0].instructions[1].value.cmd.shell);
}

test "Dockerfile parser rejects duplicate escape directives" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(),
        \\# escape=\
        \\# escape=`
        \\FROM scratch
        \\
    , &diagnostic));
    try std.testing.expectEqualStrings("duplicate escape parser directive", diagnostic.message);
}

test "Dockerfile parser emits source-spanned stages and typed cross-stage copies" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const doc = try parse(arena_state.allocator(),
        \\ARG BASE=base
        \\FROM --platform=$BUILDPLATFORM ${BASE} AS build
        \\RUN make /out/app
        \\FROM scratch AS final
        \\COPY --from=build /out/app /app
        \\ENTRYPOINT ["/app"]
        \\CMD ["serve"]
        \\
    , &diag);
    try std.testing.expectEqual(@as(usize, 1), doc.global_args.len);
    try std.testing.expectEqual(@as(usize, 2), doc.stages.len);
    try std.testing.expectEqualStrings("build", doc.stages[0].name.?);
    try std.testing.expectEqualStrings("$BUILDPLATFORM", doc.stages[0].from.value.from.platform.?);
    try std.testing.expectEqualStrings("final", doc.stages[1].name.?);
    try std.testing.expectEqualStrings("build", doc.stages[1].instructions[0].value.copy.from.?);
    try std.testing.expect(doc.stages[1].instructions[1].value == .entrypoint);
    try std.testing.expectEqual(@as(usize, 4), doc.stages[1].span.start_line);
    try std.testing.expectEqual(@as(usize, 7), doc.stages[1].span.end_line);
}

test "Dockerfile parser leaves RUN shell expansion untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const doc = try parse(arena_state.allocator(),
        \\FROM base
        \\RUN echo $? $(dpkg --print-architecture) "${VERSION_CODENAME}" '$BUILD_ARG' $$
        \\
    , &diag);
    try std.testing.expectEqualStrings(
        "echo $? $(dpkg --print-architecture) \"${VERSION_CODENAME}\" '$BUILD_ARG' $$",
        doc.stages[0].instructions[0].value.run.shell,
    );
}

test "Dockerfile parser preserves bounded exec-form RUN argv" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const doc = try parse(arena_state.allocator(),
        \\FROM base
        \\RUN ["printf","%s|%s|%s","two words","","$VALUE"]
        \\
    , &diag);
    const argv = doc.stages[0].instructions[0].value.run.exec;
    try std.testing.expectEqual(@as(usize, 5), argv.len);
    try std.testing.expectEqualStrings("two words", argv[2]);
    try std.testing.expectEqualStrings("", argv[3]);
    try std.testing.expectEqualStrings("$VALUE", argv[4]);

    const invalid = [_]struct { dockerfile: []const u8, message: []const u8 }{
        .{ .dockerfile = "FROM base\nRUN []\n", .message = "RUN exec form must be a non-empty JSON string array" },
        .{ .dockerfile = "FROM base\nRUN [\"\"]\n", .message = "RUN exec form requires a non-empty executable" },
        .{ .dockerfile = "FROM base\nRUN [\"true\",1]\n", .message = "RUN exec form must be a non-empty JSON string array" },
        .{ .dockerfile = "FROM base\nRUN [\"true\",\"\\u0000\"]\n", .message = "RUN exec form arguments cannot contain NUL bytes" },
    };
    for (invalid) |case| {
        try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), case.dockerfile, &diag));
        try std.testing.expectEqual(@as(usize, 2), diag.line);
        try std.testing.expectEqualStrings(case.message, diag.message);
    }
}

test "Dockerfile parser validates later exec-form RUN before returning a document" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(),
        \\FROM base
        \\RUN ["true"]
        \\RUN ["false",{}]
        \\
    , &diag));
    try std.testing.expectEqual(@as(usize, 3), diag.line);
    try std.testing.expectEqualStrings("RUN exec form must be a non-empty JSON string array", diag.message);
}

test "Dockerfile parser accepts stable and rejects unstable variable expansion operators" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const doc = try parse(arena_state.allocator(), "FROM base\nENV A=${VAR:-default} B=${VAR+alternate}\n", &diag);
    try std.testing.expectEqualStrings("${VAR:-default}", doc.stages[0].instructions[0].value.env.pairs[0].value);
    try std.testing.expectEqualStrings("${VAR+alternate}", doc.stages[0].instructions[0].value.env.pairs[1].value);

    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), "FROM base\nWORKDIR ${VAR#prefix}\n", &diag));
    try std.testing.expectEqualStrings("unsupported variable expansion", diag.message);
}

test "Dockerfile parser rejects COPY flags in any position" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), "FROM base\nCOPY a --from=other /dest\n", &diag));
    try std.testing.expectEqualStrings("unsupported COPY flag: --from", diag.message);

    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), "FROM base\nCOPY --chown=1000:1000 a /dest\n", &diag));
    try std.testing.expectEqualStrings("unsupported COPY flag: --chown", diag.message);

    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), "FROM base\nCOPY --chmod=0644 a /dest\n", &diag));
    try std.testing.expectEqualStrings("unsupported COPY flag: --chmod", diag.message);

    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), "FROM base\nCOPY --link a /dest\n", &diag));
    try std.testing.expectEqualStrings("unsupported COPY flag: --link", diag.message);

    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), "FROM base\nCOPY --from=$STAGE /a /dest\n", &diag));
    try std.testing.expectEqualStrings("COPY --from does not support variable expansion or quoting", diag.message);
}

test "Dockerfile parser accepts narrow remote ADD and rejects unsupported forms" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const doc = try parse(arena_state.allocator(), "FROM base\nADD https://example.com/${TARGETARCH}/tool /usr/bin/tool\n", &diag);
    const add = doc.stages[0].instructions[0].value.add;
    try std.testing.expectEqualStrings("https://example.com/${TARGETARCH}/tool", add.source);
    try std.testing.expectEqualStrings("/usr/bin/tool", add.dest);

    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), "FROM base\nADD --chmod=0755 https://example.com/tool /tool\n", &diag));
    try std.testing.expectEqualStrings("unsupported ADD flag: --chmod=0755", diag.message);
    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), "FROM base\nADD a b /dest\n", &diag));
    try std.testing.expectEqualStrings("remote ADD requires exactly one source and one destination", diag.message);
    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), "FROM base\nADD <<EOF /dest\n", &diag));
    try std.testing.expectEqualStrings("unsupported ADD heredoc", diag.message);
    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), "FROM base\nADD local.tar /dest\n", &diag));
    try std.testing.expectEqualStrings("remote ADD source must have a literal HTTPS authority", diag.message);
    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), "FROM base\nADD https://user@example.com/file /dest\n", &diag));
    try std.testing.expectEqualStrings("remote ADD source must have a literal HTTPS authority", diag.message);
    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), "FROM base\nADD https://example.com/file ../dest\n", &diag));
    try std.testing.expectEqualStrings("remote ADD destination must not contain a parent path segment", diag.message);
    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), "FROM base\nADD https://example.com/file /dest\nLABEL later=unsupported\n", &diag));
    try std.testing.expectEqual(@as(usize, 3), diag.line);
    try std.testing.expectEqualStrings("unsupported Dockerfile instruction: LABEL", diag.message);
}

test "unsupported later-stage ADD semantics win before earlier-stage execution" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(),
        \\FROM base AS build
        \\RUN echo would-execute
        \\FROM build
        \\ADD http://example.com/file /dest
        \\
    , &diag));
    try std.testing.expectEqual(@as(usize, 4), diag.line);
    try std.testing.expectEqualStrings("remote ADD source must have a literal HTTPS authority", diag.message);
}

test "unsupported instructions win over expansion diagnostics" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), "FROM scratch\nLABEL x=${A:-b}\n", &diagnostic));
    try std.testing.expectEqualStrings("unsupported Dockerfile instruction: LABEL", diagnostic.message);
}

test "stage aliases must begin with an ASCII letter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    inline for (.{ ".bad", "-bad", "_bad", "1bad" }) |name| {
        const source = try std.fmt.allocPrint(arena_state.allocator(), "FROM scratch AS {s}\n", .{name});
        try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), source, &diagnostic));
        try std.testing.expectEqualStrings("FROM AS has an invalid stage name", diagnostic.message);
    }
}

test "Dockerfile parser enforces production input bounds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var diag: Diagnostic = .{};
    const large = try allocator.alloc(u8, max_dockerfile_bytes + 1);
    @memset(large, 'A');
    try std.testing.expectError(error.DockerfileParseFailed, parse(allocator, large, &diag));
    try std.testing.expectEqualStrings("Dockerfile is too large", diag.message);

    const long_line = try std.fmt.allocPrint(allocator, "FROM base\nRUN {s}\n", .{"x" ** (max_logical_line_bytes + 1)});
    try std.testing.expectError(error.DockerfileParseFailed, parse(allocator, long_line, &diag));
    try std.testing.expectEqualStrings("Dockerfile logical line is too long", diag.message);
}
