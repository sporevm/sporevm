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

pub const RunCommand = union(enum) {
    shell: []const u8,
    exec: []const []const u8,
};

pub const RunCacheMount = struct {
    target: []const u8,
    id: ?[]const u8 = null,
    sharing: ?[]const u8 = null,
};

pub const RunContextBindMount = struct {
    source: []const u8,
    target: []const u8,
};

pub const Run = struct {
    command: RunCommand,
    cache_mounts: []const RunCacheMount = &.{},
    context_bind_mounts: []const RunContextBindMount = &.{},
    ssh_declared_absent: bool = false,
};

pub const Copy = struct {
    from: ?[]const u8 = null,
    link: ?bool = null,
    parents: ?bool = null,
    sources: []const []const u8,
    dest: []const u8,
    heredoc: ?Heredoc = null,
};

pub const Heredoc = struct {
    name: []const u8,
    body: []const u8,
};

pub const Add = struct {
    chmod: ?[]const u8 = null,
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
    heredoc: ?Heredoc = null,
};

const max_dockerfile_bytes = 1024 * 1024;
const max_logical_line_bytes = 64 * 1024;
const max_stages = 256;
pub const max_run_exec_args = run_contract.max_exec_args;
pub const max_run_exec_args_bytes = run_contract.max_exec_args_bytes;
pub const max_run_cache_mounts = 8;
pub const max_run_context_bind_mounts = 8;

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
        const raw = if (line.heredoc) |heredoc|
            try std.fmt.allocPrint(allocator, "{s}\n{s}{s}", .{ trimmed, heredoc.body, heredoc.name })
        else
            try allocator.dupe(u8, trimmed);
        const value = parseInstruction(allocator, line.line, op, rest, line.heredoc, directives.escape, diagnostic) catch return error.DockerfileParseFailed;
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
    heredoc: ?Heredoc,
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
        var cache_mounts = std.array_list.Managed(RunCacheMount).init(allocator);
        var context_bind_mounts = std.array_list.Managed(RunContextBindMount).init(allocator);
        var ssh_declared_absent = false;
        var command_start: usize = 0;
        while (true) {
            while (command_start < rest.len and (rest[command_start] == ' ' or rest[command_start] == '\t')) command_start += 1;
            if (command_start == rest.len) return fail(diagnostic, line, "RUN requires a shell command");
            var token_end = command_start;
            while (token_end < rest.len and rest[token_end] != ' ' and rest[token_end] != '\t') token_end += 1;
            const token = rest[command_start..token_end];
            if (!std.mem.startsWith(u8, token, "--")) break;
            if (!std.mem.startsWith(u8, token, "--mount=") or
                std.mem.indexOfAny(u8, token, "\"'") != null or std.mem.indexOfScalar(u8, token, escape) != null)
            {
                return fail(diagnostic, line, "unsupported RUN flag");
            }
            const raw_mount = token["--mount=".len..];
            if (std.mem.eql(u8, raw_mount, "type=ssh")) {
                if (ssh_declared_absent) return fail(diagnostic, line, "multiple RUN SSH mounts are unsupported");
                ssh_declared_absent = true;
            } else {
                if (runMountType(raw_mount)) |mount_type| {
                    if (std.mem.eql(u8, mount_type, "ssh")) return fail(diagnostic, line, "unsupported RUN SSH mount form");
                    if (std.mem.eql(u8, mount_type, "bind")) {
                        if (context_bind_mounts.items.len == max_run_context_bind_mounts) return fail(diagnostic, line, "RUN has too many context bind mounts");
                        try context_bind_mounts.append(try parseRunContextBindMount(allocator, raw_mount, escape, line, diagnostic));
                        command_start = token_end;
                        continue;
                    }
                    if (!asciiEql(mount_type, "cache")) return fail(diagnostic, line, "unsupported RUN mount type");
                }
                if (cache_mounts.items.len == max_run_cache_mounts) return fail(diagnostic, line, "RUN has too many cache mounts");
                try cache_mounts.append(try parseRunCacheMount(allocator, raw_mount, escape, line, diagnostic));
            }
            command_start = token_end;
        }
        const command_raw = rest[command_start..];
        if (heredoc) |run_heredoc| {
            if (context_bind_mounts.items.len != 0) return fail(diagnostic, line, "RUN context bind mounts require ordinary shell form");
            if (command_raw.len != run_heredoc.name.len + 2 or
                !std.mem.startsWith(u8, command_raw, "<<") or
                !std.mem.eql(u8, command_raw[2..], run_heredoc.name) or
                !validHeredocDelimiter(run_heredoc.name) or
                run_heredoc.body.len == 0 or
                std.mem.startsWith(u8, run_heredoc.body, "#!") or
                std.mem.indexOfScalar(u8, run_heredoc.body, 0) != null)
            {
                return fail(diagnostic, line, "unsupported RUN heredoc form");
            }
            return .{ .run = .{
                .command = .{ .shell = try allocator.dupe(u8, run_heredoc.body) },
                .cache_mounts = try cache_mounts.toOwnedSlice(),
                .context_bind_mounts = try context_bind_mounts.toOwnedSlice(),
                .ssh_declared_absent = ssh_declared_absent,
            } };
        }
        if (std.mem.startsWith(u8, command_raw, "[")) {
            if (try parseRunExec(allocator, command_raw, line, diagnostic)) |argv| {
                if (context_bind_mounts.items.len != 0) return fail(diagnostic, line, "RUN context bind mounts require ordinary shell form");
                return .{ .run = .{
                    .command = .{ .exec = argv },
                    .cache_mounts = try cache_mounts.toOwnedSlice(),
                    .context_bind_mounts = try context_bind_mounts.toOwnedSlice(),
                    .ssh_declared_absent = ssh_declared_absent,
                } };
            }
        }
        if (std.mem.indexOf(u8, command_raw, "<<") != null) return fail(diagnostic, line, "unsupported RUN heredoc");
        return .{ .run = .{
            .command = .{ .shell = try allocator.dupe(u8, command_raw) },
            .cache_mounts = try cache_mounts.toOwnedSlice(),
            .context_bind_mounts = try context_bind_mounts.toOwnedSlice(),
            .ssh_declared_absent = ssh_declared_absent,
        } };
    }
    if (asciiEql(op, "COPY")) {
        const args = try splitWords(allocator, rest, escape, line, diagnostic);
        if (heredoc) |copy_heredoc| {
            if (args.len != 2 or args[0].raw.len != copy_heredoc.name.len + 2 or
                !std.mem.startsWith(u8, args[0].raw, "<<") or
                !std.mem.eql(u8, args[0].raw[2..], copy_heredoc.name) or
                !validHeredocDelimiter(copy_heredoc.name))
            {
                return fail(diagnostic, line, "unsupported COPY heredoc form");
            }
            try validateExpansion(allocator, args[1].raw, escape, line, diagnostic);
            try validateHeredocExpansion(allocator, copy_heredoc.body, escape, line, diagnostic);
            return .{ .copy = .{
                .sources = &.{},
                .dest = args[1].raw,
                .heredoc = copy_heredoc,
            } };
        }
        if (std.mem.indexOf(u8, rest, "<<") != null) return fail(diagnostic, line, "unsupported COPY heredoc");
        var first_source: usize = 0;
        var from: ?[]const u8 = null;
        var link: ?bool = null;
        var parents: ?bool = null;
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
            if ((std.mem.eql(u8, arg.value, "--link") or std.mem.startsWith(u8, arg.value, "--link=")) and
                std.mem.eql(u8, arg.raw, arg.value))
            {
                if (link != null) return fail(diagnostic, line, "duplicate COPY flag: --link");
                if (std.mem.eql(u8, arg.value, "--link")) {
                    link = true;
                } else {
                    const value = arg.value["--link=".len..];
                    if (asciiEql(value, "true")) {
                        link = true;
                    } else if (asciiEql(value, "false")) {
                        link = false;
                    } else {
                        return fail(diagnostic, line, "COPY --link requires true or false");
                    }
                }
                continue;
            }
            if ((std.mem.eql(u8, arg.value, "--parents") or std.mem.startsWith(u8, arg.value, "--parents=")) and
                std.mem.eql(u8, arg.raw, arg.value))
            {
                if (parents != null) return fail(diagnostic, line, "duplicate COPY flag: --parents");
                if (std.mem.eql(u8, arg.value, "--parents")) {
                    parents = true;
                } else {
                    const value = arg.value["--parents=".len..];
                    if (asciiEql(value, "true")) {
                        parents = true;
                    } else if (asciiEql(value, "false")) {
                        parents = false;
                    } else {
                        return fail(diagnostic, line, "COPY --parents requires true or false");
                    }
                }
                continue;
            }
            const flag = if (std.mem.indexOfScalar(u8, arg.value, '=')) |eq| arg.value[0..eq] else arg.value;
            const message = try std.fmt.allocPrint(allocator, "unsupported COPY flag: {s}", .{flag});
            return fail(diagnostic, line, message);
        }
        if (parents != null and (from != null or link != null)) return fail(diagnostic, line, "COPY --parents does not support other flags");
        if (link != null and from == null) return fail(diagnostic, line, "COPY --link requires --from");
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
        return .{ .copy = .{ .from = from, .link = link, .parents = parents, .sources = sources, .dest = args[args.len - 1].raw } };
    }
    if (asciiEql(op, "ADD")) {
        if (std.mem.indexOf(u8, rest, "<<") != null) return fail(diagnostic, line, "unsupported ADD heredoc");
        const args = try splitWords(allocator, rest, escape, line, diagnostic);
        var chmod: ?[]const u8 = null;
        var first_source: usize = 0;
        while (first_source < args.len and std.mem.startsWith(u8, args[first_source].value, "--")) : (first_source += 1) {
            const arg = args[first_source];
            if (std.mem.eql(u8, arg.value, "--chmod") and std.mem.eql(u8, arg.raw, arg.value)) {
                return fail(diagnostic, line, "ADD --chmod requires a value");
            }
            if (std.mem.startsWith(u8, arg.value, "--chmod=") and std.mem.startsWith(u8, arg.raw, "--chmod=")) {
                if (chmod != null) return fail(diagnostic, line, "duplicate ADD flag: --chmod");
                const value = arg.raw["--chmod=".len..];
                if (value.len == 0) return fail(diagnostic, line, "ADD --chmod requires a non-empty octal value");
                try validateExpansion(allocator, value, escape, line, diagnostic);
                chmod = value;
                continue;
            }
            const flag = if (std.mem.indexOfScalar(u8, arg.value, '=')) |eq| arg.value[0..eq] else arg.value;
            const message = try std.fmt.allocPrint(allocator, "unsupported ADD flag: {s}", .{flag});
            return fail(diagnostic, line, message);
        }
        for (args[first_source..]) |arg| {
            if (!std.mem.startsWith(u8, arg.value, "--")) continue;
            const flag = if (std.mem.indexOfScalar(u8, arg.value, '=')) |eq| arg.value[0..eq] else arg.value;
            const message = try std.fmt.allocPrint(allocator, "unsupported ADD flag: {s}", .{flag});
            return fail(diagnostic, line, message);
        }
        if (args.len - first_source != 2) return fail(diagnostic, line, "remote ADD requires exactly one source and one destination");
        const source = args[first_source];
        const dest = args[first_source + 1];
        if (!remote_add_policy.validateTemplate(source.value)) return fail(diagnostic, line, "remote ADD source must have a literal HTTPS authority");
        if (hasParentPathSegment(dest.value)) return fail(diagnostic, line, "remote ADD destination must not contain a parent path segment");
        for (args[first_source..]) |arg| {
            try validateExpansion(allocator, arg.raw, escape, line, diagnostic);
        }
        return .{ .add = .{ .chmod = chmod, .source = source.raw, .dest = dest.raw } };
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
        return .{ .cmd = try parseCmd(allocator, rest, line, diagnostic, .cmd) };
    }
    if (asciiEql(op, "ENTRYPOINT")) {
        if (rest.len == 0) return fail(diagnostic, line, "ENTRYPOINT requires a command");
        return .{ .entrypoint = try parseCmd(allocator, rest, line, diagnostic, .entrypoint) };
    }
    const message = try std.fmt.allocPrint(allocator, "unsupported Dockerfile instruction: {s}", .{op});
    diagnostic.* = .{ .line = line, .message = message };
    return error.DockerfileParseFailed;
}

fn runMountType(raw: []const u8) ?[]const u8 {
    var fields = std.mem.splitScalar(u8, raw, ',');
    while (fields.next()) |field| {
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        if (std.mem.eql(u8, field[0..equals], "type")) return field[equals + 1 ..];
    }
    return null;
}

fn parseRunCacheMount(
    allocator: std.mem.Allocator,
    raw: []const u8,
    escape: u8,
    line: usize,
    diagnostic: *Diagnostic,
) !RunCacheMount {
    if (raw.len == 0) return fail(diagnostic, line, "RUN cache mount requires type=cache and target=<path>");
    var mount_type: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var id: ?[]const u8 = null;
    var sharing: ?[]const u8 = null;
    var fields = std.mem.splitScalar(u8, raw, ',');
    while (fields.next()) |field| {
        if (field.len == 0) return fail(diagnostic, line, "RUN cache mount has an empty option");
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse
            return fail(diagnostic, line, "RUN cache mount options must use key=value");
        const key = field[0..equals];
        const value = field[equals + 1 ..];
        if (key.len == 0 or value.len == 0) return fail(diagnostic, line, "RUN cache mount options require non-empty values");
        if (asciiEql(key, "type")) {
            if (mount_type != null) return fail(diagnostic, line, "duplicate RUN cache mount option: type");
            mount_type = value;
        } else if (asciiEql(key, "target")) {
            if (target != null) return fail(diagnostic, line, "duplicate RUN cache mount option: target");
            target = value;
        } else if (asciiEql(key, "id")) {
            if (id != null) return fail(diagnostic, line, "duplicate RUN cache mount option: id");
            id = value;
        } else if (asciiEql(key, "sharing")) {
            if (sharing != null) return fail(diagnostic, line, "duplicate RUN cache mount option: sharing");
            sharing = value;
        } else {
            return fail(diagnostic, line, "unsupported RUN cache mount option");
        }
    }
    const resolved_type = mount_type orelse return fail(diagnostic, line, "RUN cache mount requires type=cache");
    if (!asciiEql(resolved_type, "cache")) return fail(diagnostic, line, "unsupported RUN mount type");
    const resolved_target = target orelse return fail(diagnostic, line, "RUN cache mount requires target=<path>");
    try validateExpansion(allocator, resolved_target, escape, line, diagnostic);
    if (id) |value| try validateExpansion(allocator, value, escape, line, diagnostic);
    if (sharing) |value| {
        try validateExpansion(allocator, value, escape, line, diagnostic);
        if (std.mem.indexOfScalar(u8, value, '$') == null and
            !asciiEql(value, "shared") and !asciiEql(value, "locked"))
        {
            return fail(diagnostic, line, "unsupported RUN cache sharing mode");
        }
    }
    return .{
        .target = try allocator.dupe(u8, resolved_target),
        .id = if (id) |value| try allocator.dupe(u8, value) else null,
        .sharing = if (sharing) |value| try allocator.dupe(u8, value) else null,
    };
}

fn parseRunContextBindMount(
    allocator: std.mem.Allocator,
    raw: []const u8,
    escape: u8,
    line: usize,
    diagnostic: *Diagnostic,
) !RunContextBindMount {
    var mount_type: ?[]const u8 = null;
    var source: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var fields = std.mem.splitScalar(u8, raw, ',');
    while (fields.next()) |field| {
        if (field.len == 0) return fail(diagnostic, line, "RUN context bind mount has an empty option");
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse
            return fail(diagnostic, line, "RUN context bind mount options must use key=value");
        const key = field[0..equals];
        const value = field[equals + 1 ..];
        if (key.len == 0 or value.len == 0) return fail(diagnostic, line, "RUN context bind mount options require non-empty values");
        if (asciiEql(key, "type")) {
            if (mount_type != null) return fail(diagnostic, line, "duplicate RUN context bind mount option: type");
            mount_type = value;
        } else if (std.mem.eql(u8, key, "source")) {
            if (source != null) return fail(diagnostic, line, "duplicate RUN context bind mount option: source");
            source = value;
        } else if (std.mem.eql(u8, key, "target")) {
            if (target != null) return fail(diagnostic, line, "duplicate RUN context bind mount option: target");
            target = value;
        } else {
            return fail(diagnostic, line, "unsupported RUN context bind mount option");
        }
    }
    const resolved_type = mount_type orelse return fail(diagnostic, line, "RUN context bind mount requires type=bind");
    if (!std.mem.eql(u8, resolved_type, "bind")) return fail(diagnostic, line, "unsupported RUN mount type");
    const resolved_source = source orelse return fail(diagnostic, line, "RUN context bind mount requires source=<path>");
    const resolved_target = target orelse return fail(diagnostic, line, "RUN context bind mount requires target=<path>");
    try validateExpansion(allocator, resolved_source, escape, line, diagnostic);
    try validateExpansion(allocator, resolved_target, escape, line, diagnostic);
    return .{
        .source = try allocator.dupe(u8, resolved_source),
        .target = try allocator.dupe(u8, resolved_target),
    };
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
    while (it.next()) |raw_line| {
        defer line_no += 1;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const trimmed_left = std.mem.trimStart(u8, line, " \t");
        if (trimmed_left.len == 0) continue;
        if (trimmed_left[0] == '#') continue;
        if (!continuing) current_line = line_no;
        const trimmed_right = std.mem.trimEnd(u8, line, " \t");
        const has_continuation = trimmed_right.len != 0 and trimmed_right[trimmed_right.len - 1] == escape;
        const part = if (has_continuation) trimmed_right[0 .. trimmed_right.len - 1] else line;
        try current.appendSlice(part);
        if (current.items.len > max_logical_line_bytes) return fail(diagnostic, current_line, "Dockerfile logical line is too long");
        continuing = has_continuation;
        if (!continuing) {
            const text = try current.toOwnedSlice();
            if (instructionHeredoc(text)) |marker| {
                if (marker.count != 1 or marker.terminator.len == 0) {
                    return fail(diagnostic, current_line, marker.instruction.unsupportedMessage());
                }
                var body = std.array_list.Managed(u8).init(allocator);
                var terminated = false;
                while (it.next()) |raw_body_line| {
                    line_no += 1;
                    const body_line = std.mem.trimEnd(u8, raw_body_line, "\r");
                    const possible_terminator = if (marker.chomp) std.mem.trimStart(u8, body_line, "\t") else body_line;
                    if (std.mem.eql(u8, possible_terminator, marker.terminator)) {
                        terminated = true;
                        break;
                    }
                    try body.appendSlice(body_line);
                    try body.append('\n');
                    const body_limit: usize = switch (marker.instruction) {
                        .copy => max_dockerfile_bytes,
                        .run => run_contract.max_shell_command_bytes,
                    };
                    if (body.items.len > body_limit) {
                        return fail(diagnostic, current_line, marker.instruction.tooLargeMessage());
                    }
                }
                if (!terminated) return fail(diagnostic, current_line, marker.instruction.unterminatedMessage());
                try lines.append(.{
                    .line = current_line,
                    .end_line = line_no,
                    .text = text,
                    .heredoc = .{
                        .name = try allocator.dupe(u8, marker.terminator),
                        .body = try body.toOwnedSlice(),
                    },
                });
            } else {
                try lines.append(.{ .line = current_line, .end_line = line_no, .text = text });
            }
            current = std.array_list.Managed(u8).init(allocator);
        }
    }
    if (continuing) return fail(diagnostic, current_line, "unterminated Dockerfile line continuation");
}

const HeredocInstruction = enum {
    copy,
    run,

    fn unsupportedMessage(value: HeredocInstruction) []const u8 {
        return switch (value) {
            .copy => "unsupported COPY heredoc form",
            .run => "unsupported RUN heredoc form",
        };
    }

    fn tooLargeMessage(value: HeredocInstruction) []const u8 {
        return switch (value) {
            .copy => "COPY heredoc is too large",
            .run => "RUN heredoc is too large",
        };
    }

    fn unterminatedMessage(value: HeredocInstruction) []const u8 {
        return switch (value) {
            .copy => "unterminated COPY heredoc",
            .run => "unterminated RUN heredoc",
        };
    }
};

const HeredocMarker = struct {
    instruction: HeredocInstruction,
    terminator: []const u8,
    count: usize,
    chomp: bool,
};

fn instructionHeredoc(text: []const u8) ?HeredocMarker {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const space = firstSpace(trimmed) orelse return null;
    const instruction: HeredocInstruction = if (asciiEql(trimmed[0..space], "COPY"))
        .copy
    else if (asciiEql(trimmed[0..space], "RUN"))
        .run
    else
        return null;
    const rest = std.mem.trimStart(u8, trimmed[space..], " \t");
    var marker_start: ?usize = null;
    var marker_end: usize = 0;
    var count: usize = 0;
    var token_start: usize = 0;
    while (token_start < rest.len) {
        while (token_start < rest.len and (rest[token_start] == ' ' or rest[token_start] == '\t')) token_start += 1;
        if (token_start == rest.len) break;
        var token_end = token_start;
        while (token_end < rest.len and rest[token_end] != ' ' and rest[token_end] != '\t') token_end += 1;
        var prefix_end = token_start;
        while (prefix_end < token_end and std.ascii.isDigit(rest[prefix_end])) prefix_end += 1;
        if (prefix_end + 2 <= token_end and std.mem.eql(u8, rest[prefix_end .. prefix_end + 2], "<<")) {
            count += 1;
            if (marker_start == null) {
                marker_start = prefix_end;
                marker_end = token_end;
            }
        }
        token_start = token_end;
    }
    const marker = marker_start orelse return null;
    var token = rest[marker + 2 .. marker_end];
    const chomp = token.len != 0 and token[0] == '-';
    if (chomp) token = token[1..];
    if (token.len >= 2 and ((token[0] == '\'' and token[token.len - 1] == '\'') or
        (token[0] == '"' and token[token.len - 1] == '"')))
    {
        token = token[1 .. token.len - 1];
    }
    return .{ .instruction = instruction, .terminator = token, .count = count, .chomp = chomp };
}

fn validHeredocDelimiter(value: []const u8) bool {
    if (value.len == 0 or !(std.ascii.isAlphabetic(value[0]) or value[0] == '_')) return false;
    for (value[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
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

fn validateHeredocExpansion(allocator: std.mem.Allocator, input: []const u8, escape: u8, line: usize, diagnostic: *Diagnostic) !void {
    variable_expansion.validate(allocator, input, .{ .escape = escape, .preserve_quotes = true }) catch |err| switch (err) {
        error.BadVariableSubstitution, error.UnsupportedVariableModifier => return fail(diagnostic, line, "unsupported variable expansion"),
        error.VariableExpansionTooLarge => return fail(diagnostic, line, "expanded COPY heredoc is too large"),
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
    instruction: enum { cmd, entrypoint },
) !Cmd {
    const trimmed = std.mem.trimStart(u8, rest, " \t");
    if (!std.mem.startsWith(u8, trimmed, "[")) return .{ .shell = try allocator.dupe(u8, rest) };
    const entries = parseMaybeJsonStringArray(allocator, trimmed) catch |err| switch (err) {
        error.JsonNotStringArray => return fail(diagnostic, line, switch (instruction) {
            .cmd => "CMD exec form must be a JSON string array",
            .entrypoint => "ENTRYPOINT exec form must be a JSON string array",
        }),
        else => |other| return other,
    };
    return if (entries) |value| .{ .exec = value } else .{ .shell = try allocator.dupe(u8, rest) };
}

fn parseRunExec(
    allocator: std.mem.Allocator,
    rest: []const u8,
    line: usize,
    diagnostic: *Diagnostic,
) !?[]const []const u8 {
    const trimmed = std.mem.trimStart(u8, rest, " \t");
    const entries = parseMaybeJsonStringArray(allocator, trimmed) catch |err| switch (err) {
        error.JsonNotStringArray => return fail(diagnostic, line, "RUN exec form must be a non-empty JSON string array"),
        else => |other| return other,
    };
    const argv = entries orelse return null;
    if (run_contract.execArgvViolation(argv)) |violation| switch (violation) {
        .empty => return fail(diagnostic, line, "RUN exec form must be a non-empty JSON string array"),
        .empty_executable => return fail(diagnostic, line, "RUN exec form requires a non-empty executable"),
        .too_many_args => return fail(diagnostic, line, "RUN exec form has too many arguments; limit is 16"),
        .nul => return fail(diagnostic, line, "RUN exec form arguments cannot contain NUL bytes"),
        .decoded_too_large => return fail(diagnostic, line, "RUN exec form arguments are too large; limit is 4096 decoded bytes"),
    };
    return argv;
}

fn parseMaybeJsonStringArray(allocator: std.mem.Allocator, input: []const u8) !?[]const []const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    defer parsed.deinit();
    const values = switch (parsed.value) {
        .array => |array| array.items,
        else => return error.JsonNotStringArray,
    };
    for (values) |value| switch (value) {
        .string => {},
        else => return error.JsonNotStringArray,
    };
    const out = try allocator.alloc([]const u8, values.len);
    for (values, out) |value, *entry| entry.* = switch (value) {
        .string => |string| try allocator.dupe(u8, string),
        else => unreachable,
    };
    return out;
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

test "Dockerfile parser preserves a narrow COPY heredoc with its source span" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const doc = try parse(arena_state.allocator(),
        \\FROM scratch
        \\ARG VERSION=24
        \\COPY <<EOF /etc/example
        \\value=${VERSION}
        \\quoted='${VERSION}'
        \\# body comment is data
        \\EOF
        \\CMD ["true"]
        \\
    , &diag);
    const instruction = doc.stages[0].instructions[1];
    const copy = instruction.value.copy;
    try std.testing.expectEqual(@as(usize, 3), instruction.span.start_line);
    try std.testing.expectEqual(@as(usize, 7), instruction.span.end_line);
    try std.testing.expectEqual(@as(usize, 0), copy.sources.len);
    try std.testing.expectEqualStrings("/etc/example", copy.dest);
    try std.testing.expectEqualStrings("EOF", copy.heredoc.?.name);
    try std.testing.expectEqualStrings("value=${VERSION}\nquoted='${VERSION}'\n# body comment is data\n", copy.heredoc.?.body);
    try std.testing.expectEqualStrings(
        "COPY <<EOF /etc/example\nvalue=${VERSION}\nquoted='${VERSION}'\n# body comment is data\nEOF",
        instruction.raw,
    );
}

test "Dockerfile parser rejects unsupported and malformed COPY heredocs before later instructions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const invalid = [_]struct { dockerfile: []const u8, message: []const u8 }{
        .{ .dockerfile = "FROM scratch\nCOPY <<'EOF' /out\n$VALUE\nEOF\n", .message = "unsupported COPY heredoc form" },
        .{ .dockerfile = "FROM scratch\nCOPY <<-EOF /out\nvalue\nEOF\n", .message = "unsupported COPY heredoc form" },
        .{ .dockerfile = "FROM scratch\nCOPY <<EOF extra /out\nvalue\nEOF\n", .message = "unsupported COPY heredoc form" },
        .{ .dockerfile = "FROM scratch\nCOPY --chmod=0644 <<EOF /out\nvalue\nEOF\n", .message = "unsupported COPY heredoc form" },
        .{ .dockerfile = "FROM scratch\nCOPY <<EOF /out\nvalue\n", .message = "unterminated COPY heredoc" },
        .{ .dockerfile = "FROM scratch\nCOPY <<EOF /out\n${VALUE:?no}\nEOF\nRUN should-not-parse\n", .message = "unsupported variable expansion" },
    };
    for (invalid) |case| {
        try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), case.dockerfile, &diag));
        try std.testing.expectEqual(@as(usize, 2), diag.line);
        try std.testing.expectEqualStrings(case.message, diag.message);
    }
}

test "Dockerfile parser preserves a narrow cache-mounted RUN heredoc with its source span" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const doc = try parse(arena_state.allocator(),
        \\FROM scratch
        \\ARG VALUE=one
        \\RUN --mount=type=cache,target=/var/cache/a \
        \\    --mount=type=cache,target=/var/cache/b <<EOF
        \\set -eu
        \\printf '%s\n' "$VALUE" > /result
        \\# body comment is shell input
        \\EOF
        \\CMD ["true"]
        \\
    , &diag);
    const instruction = doc.stages[0].instructions[1];
    const run = instruction.value.run;
    try std.testing.expectEqual(@as(usize, 3), instruction.span.start_line);
    try std.testing.expectEqual(@as(usize, 8), instruction.span.end_line);
    try std.testing.expectEqual(@as(usize, 2), run.cache_mounts.len);
    try std.testing.expectEqualStrings("/var/cache/a", run.cache_mounts[0].target);
    try std.testing.expectEqualStrings("/var/cache/b", run.cache_mounts[1].target);
    try std.testing.expectEqualStrings(
        "set -eu\nprintf '%s\\n' \"$VALUE\" > /result\n# body comment is shell input\n",
        run.command.shell,
    );
    try std.testing.expectEqualStrings(
        "RUN --mount=type=cache,target=/var/cache/a     --mount=type=cache,target=/var/cache/b <<EOF\n" ++
            "set -eu\nprintf '%s\\n' \"$VALUE\" > /result\n# body comment is shell input\nEOF",
        instruction.raw,
    );
}

test "Dockerfile parser rejects neighboring RUN heredoc forms before later instructions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const invalid = [_]struct { dockerfile: []const u8, message: []const u8 }{
        .{ .dockerfile = "FROM scratch\nRUN <<'EOF'\nprintf quoted\nEOF\n", .message = "unsupported RUN heredoc form" },
        .{ .dockerfile = "FROM scratch\nRUN <<-EOF\n\tprintf chomp\n\tEOF\n", .message = "unsupported RUN heredoc form" },
        .{ .dockerfile = "FROM scratch\nRUN cat <<EOF\nvalue\nEOF\n", .message = "unsupported RUN heredoc form" },
        .{ .dockerfile = "FROM scratch\nRUN <<ONE <<TWO\none\nONE\ntwo\nTWO\n", .message = "unsupported RUN heredoc form" },
        .{ .dockerfile = "FROM scratch\nRUN <<EOF\n#!/bin/sh\nprintf direct\nEOF\n", .message = "unsupported RUN heredoc form" },
        .{ .dockerfile = "FROM scratch\nRUN --mount=type=cache,target=/cache <<EOF\nEOF\n", .message = "unsupported RUN heredoc form" },
        .{ .dockerfile = "FROM scratch\nRUN <<EOF\nprintf unterminated\n", .message = "unterminated RUN heredoc" },
        .{ .dockerfile = "FROM scratch\nRUN <<EOF\nprintf before\x00printf after\nEOF\n", .message = "unsupported RUN heredoc form" },
    };
    for (invalid) |case| {
        try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), case.dockerfile, &diag));
        try std.testing.expectEqual(@as(usize, 2), diag.line);
        try std.testing.expectEqualStrings(case.message, diag.message);
    }
}

test "Dockerfile parser applies the RUN command bound while scanning heredocs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const bounded_body = try allocator.alloc(u8, run_contract.max_shell_command_bytes - 1);
    @memset(bounded_body, 'x');
    const bounded_source = try std.fmt.allocPrint(
        allocator,
        "FROM scratch\nRUN <<EOF\n{s}\nEOF\n",
        .{bounded_body},
    );
    var diag: Diagnostic = .{};
    const bounded = try parse(allocator, bounded_source, &diag);
    try std.testing.expectEqual(run_contract.max_shell_command_bytes, bounded.stages[0].instructions[0].value.run.command.shell.len);

    const oversized_body = try allocator.alloc(u8, run_contract.max_shell_command_bytes);
    @memset(oversized_body, 'x');
    const oversized_source = try std.fmt.allocPrint(
        allocator,
        "FROM scratch\nRUN <<EOF\n{s}\nEOF\n",
        .{oversized_body},
    );
    try std.testing.expectError(error.DockerfileParseFailed, parse(allocator, oversized_source, &diag));
    try std.testing.expectEqual(@as(usize, 2), diag.line);
    try std.testing.expectEqualStrings("RUN heredoc is too large", diag.message);
}

test "Dockerfile parser rejects an oversized RUN heredoc in an unselected stage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const oversized_body = try allocator.alloc(u8, run_contract.max_shell_command_bytes);
    @memset(oversized_body, 'x');
    const source = try std.fmt.allocPrint(
        allocator,
        "FROM scratch AS unused\nRUN <<EOF\n{s}\nEOF\nFROM scratch AS selected\nCMD [\"true\"]\n",
        .{oversized_body},
    );
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.DockerfileParseFailed, parse(allocator, source, &diag));
    try std.testing.expectEqual(@as(usize, 2), diag.line);
    try std.testing.expectEqualStrings("RUN heredoc is too large", diag.message);
}

test "Dockerfile parser fails closed on unsupported features" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), "RUN --mount=type=cache true\n", &diag));
    try std.testing.expectEqualStrings("RUN cache mount requires target=<path>", diag.message);
}

test "Dockerfile parser accepts bounded cache identity and sharing options" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const doc = try parse(arena_state.allocator(),
        \\FROM scratch
        \\RUN --mount=target=/var/cache/apt,Type=cache,id=frontend-$TARGET,sharing=locked --mount=type=cache,target=$CACHE_DIR,sharing=$CACHE_SHARING ["true"]
        \\
    , &diag);
    const run = doc.stages[0].instructions[0].value.run;
    try std.testing.expectEqual(@as(usize, 2), run.cache_mounts.len);
    try std.testing.expectEqualStrings("/var/cache/apt", run.cache_mounts[0].target);
    try std.testing.expectEqualStrings("frontend-$TARGET", run.cache_mounts[0].id.?);
    try std.testing.expectEqualStrings("locked", run.cache_mounts[0].sharing.?);
    try std.testing.expectEqualStrings("$CACHE_DIR", run.cache_mounts[1].target);
    try std.testing.expect(run.cache_mounts[1].id == null);
    try std.testing.expectEqualStrings("$CACHE_SHARING", run.cache_mounts[1].sharing.?);
    try std.testing.expectEqualStrings("true", run.command.exec[0]);

    const invalid = [_][]const u8{
        "FROM scratch\nRUN --mount=type=cache,target=/a,id=one,id=two true\n",
        "FROM scratch\nRUN --mount=type=cache,target=/a,sharing=shared,sharing=locked true\n",
        "FROM scratch\nRUN --mount=type=cache,target=/a,sharing=private true\n",
        "FROM scratch\nRUN --mount=type=cache,target=/a,sharing=bogus true\n",
        "FROM scratch\nRUN --mount=type=bind,target=/a true\n",
        "FROM scratch\nRUN --mount=type=cache,type=cache,target=/a true\n",
        "FROM scratch\nRUN --mount=type=cache,target=/a,target=/b true\n",
        "FROM scratch\nRUN --mount=type=cache,target=\"/a\" true\n",
    };
    for (invalid) |bytes| {
        try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), bytes, &diag));
    }
}

test "Dockerfile parser accepts one exact optional-absent SSH declaration" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var diag: Diagnostic = .{};
    const doc = try parse(allocator,
        \\FROM scratch
        \\RUN --mount=type=ssh --mount=type=cache,target=/cache true
        \\
    , &diag);
    const run = doc.stages[0].instructions[0].value.run;
    try std.testing.expect(run.ssh_declared_absent);
    try std.testing.expectEqual(@as(usize, 1), run.cache_mounts.len);
    try std.testing.expectEqualStrings("/cache", run.cache_mounts[0].target);
    try std.testing.expectEqualStrings("true", run.command.shell);

    const invalid = [_]struct { dockerfile: []const u8, message: []const u8 }{
        .{ .dockerfile = "FROM scratch\nRUN --mount=type=ssh --mount=type=ssh true\n", .message = "multiple RUN SSH mounts are unsupported" },
        .{ .dockerfile = "FROM scratch\nRUN --mount=type=ssh,required=true true\n", .message = "unsupported RUN SSH mount form" },
        .{ .dockerfile = "FROM scratch\nRUN --mount=type=ssh,required=false true\n", .message = "unsupported RUN SSH mount form" },
        .{ .dockerfile = "FROM scratch\nRUN --mount=type=ssh,id=default true\n", .message = "unsupported RUN SSH mount form" },
        .{ .dockerfile = "FROM scratch\nRUN --mount=type=ssh,target=/tmp/agent true\n", .message = "unsupported RUN SSH mount form" },
        .{ .dockerfile = "FROM scratch\nRUN --mount=type=ssh,mode=0600 true\n", .message = "unsupported RUN SSH mount form" },
        .{ .dockerfile = "FROM scratch\nRUN --mount=type=ssh,uid=0 true\n", .message = "unsupported RUN SSH mount form" },
        .{ .dockerfile = "FROM scratch\nRUN --mount=type=ssh,gid=0 true\n", .message = "unsupported RUN SSH mount form" },
        .{ .dockerfile = "FROM scratch\nRUN --mount=target=/tmp/agent,type=ssh true\n", .message = "unsupported RUN SSH mount form" },
    };
    for (invalid) |case| {
        try std.testing.expectError(error.DockerfileParseFailed, parse(allocator, case.dockerfile, &diag));
        try std.testing.expectEqualStrings(case.message, diag.message);
    }
}

test "Dockerfile parser accepts only default context bind mounts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var diag: Diagnostic = .{};
    const doc = try parse(allocator,
        \\FROM scratch
        \\RUN --mount=type=ssh --mount=type=cache,target=/cache --mount=target=$TARGET,source=$SOURCE,type=bind true
        \\
    , &diag);
    const run = doc.stages[0].instructions[0].value.run;
    try std.testing.expect(run.ssh_declared_absent);
    try std.testing.expectEqual(@as(usize, 1), run.cache_mounts.len);
    try std.testing.expectEqual(@as(usize, 1), run.context_bind_mounts.len);
    try std.testing.expectEqualStrings("$SOURCE", run.context_bind_mounts[0].source);
    try std.testing.expectEqualStrings("$TARGET", run.context_bind_mounts[0].target);

    const invalid = [_][]const u8{
        "FROM scratch\nRUN --mount=type=bind,target=/input true\n",
        "FROM scratch\nRUN --mount=type=bind,source=input true\n",
        "FROM scratch\nRUN --mount=type=bind,source=input,target=/input,readonly=true true\n",
        "FROM scratch\nRUN --mount=type=bind,source=input,target=/input,rw=true true\n",
        "FROM scratch\nRUN --mount=type=bind,source=input,target=/input,from=stage true\n",
        "FROM scratch\nRUN --mount=type=bind,source=input,source=other,target=/input true\n",
        "FROM scratch\nRUN --mount=type=bind,source=input,target=/input,target=/other true\n",
        "FROM scratch\nRUN --mount=type=bind,source=input,target=/input, true\n",
        "FROM scratch\nRUN --mount=type=bind,source=input,target=/input [\"true\"]\n",
        "FROM scratch\nRUN --mount=type=Bind,source=input,target=/input true\n",
        "FROM scratch\nRUN --mount=type=bind,Source=input,target=/input true\n",
    };
    for (invalid) |bytes| try std.testing.expectError(error.DockerfileParseFailed, parse(allocator, bytes, &diag));

    var too_many = std.array_list.Managed(u8).init(allocator);
    try too_many.appendSlice("FROM scratch\nRUN ");
    for (0..max_run_context_bind_mounts + 1) |index| {
        try too_many.appendSlice(try std.fmt.allocPrint(allocator, "--mount=type=bind,source=f{d},target=/f{d} ", .{ index, index }));
    }
    try too_many.appendSlice("true\n");
    try std.testing.expectError(error.DockerfileParseFailed, parse(allocator, too_many.items, &diag));
    try std.testing.expectEqualStrings("RUN has too many context bind mounts", diag.message);
}

test "Dockerfile parser leaves shell RUN quoting and comments opaque" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const parsed = try parse(arena_state.allocator(), "FROM scratch\nRUN --mount=type=cache,target=/cache true # \"\n", &diag);
    const run = parsed.stages[0].instructions[0].value.run;
    try std.testing.expectEqualStrings("true # \"", run.command.shell);
    try std.testing.expectEqual(@as(usize, 1), run.cache_mounts.len);
}

test "Dockerfile parser scans only literal leading RUN flags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};

    const plain = try parse(arena_state.allocator(), "FROM scratch\nRUN printf '  exact  '  # tail\n", &diag);
    try std.testing.expectEqualStrings("printf '  exact  '  # tail", plain.stages[0].instructions[0].value.run.command.shell);

    const mounted = try parse(arena_state.allocator(), "FROM scratch\nRUN --mount=type=cache,target=/cache printf '  exact  '  # tail\n", &diag);
    const run = mounted.stages[0].instructions[0].value.run;
    try std.testing.expectEqualStrings("printf '  exact  '  # tail", run.command.shell);
    try std.testing.expectEqual(@as(usize, 1), run.cache_mounts.len);

    try std.testing.expectError(error.DockerfileParseFailed, parse(
        arena_state.allocator(),
        "FROM scratch\nRUN --network=none printf exact\n",
        &diag,
    ));
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
    const default_shell = default_escape.stages[0].instructions[0].value.run.command.shell;
    try std.testing.expect(std.mem.indexOfScalar(u8, default_shell, '#') == null);
    try std.testing.expect(std.mem.indexOf(u8, default_shell, "&& echo two") != null);

    const backtick_crlf = "# escape=`\r\nFROM scratch\r\nRUN echo one `\r\n  # comment\r\n  && echo two\r\n";
    const backtick_escape = try parse(allocator, backtick_crlf, &diagnostic);
    const backtick_shell = backtick_escape.stages[0].instructions[0].value.run.command.shell;
    try std.testing.expect(std.mem.indexOfScalar(u8, backtick_shell, '#') == null);
    try std.testing.expect(std.mem.indexOf(u8, backtick_shell, "&& echo two") != null);
}

test "Dockerfile parser joins continued lines without inserting bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const document = try parse(
        arena_state.allocator(),
        "FROM scratch\n" ++
            "RUN ech\\\n" ++
            "o ok\n" ++
            "COPY file\\\n" ++
            "name.txt /dst/\n" ++
            "ENV NAME=long\\\n" ++
            "value\n",
        &diagnostic,
    );
    const instructions = document.stages[0].instructions;
    try std.testing.expectEqualStrings("echo ok", instructions[0].value.run.command.shell);
    try std.testing.expectEqual(@as(usize, 1), instructions[1].value.copy.sources.len);
    try std.testing.expectEqualStrings("filename.txt", instructions[1].value.copy.sources[0]);
    try std.testing.expectEqualStrings("longvalue", instructions[2].value.env.pairs[0].value);
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

test "Dockerfile parser treats invalid bracket JSON as shell form" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const document = try parse(arena_state.allocator(),
        \\FROM scratch
        \\RUN [ -f /x ] || true
        \\CMD [ -f /x ] && echo ready
        \\ENTRYPOINT [ -x /bin/sh ] && exec /bin/sh
        \\
    , &diagnostic);
    const instructions = document.stages[0].instructions;
    try std.testing.expectEqualStrings("[ -f /x ] || true", instructions[0].value.run.command.shell);
    try std.testing.expectEqualStrings("[ -f /x ] && echo ready", instructions[1].value.cmd.shell);
    try std.testing.expectEqualStrings("[ -x /bin/sh ] && exec /bin/sh", instructions[2].value.entrypoint.shell);
}

test "Dockerfile parser rejects valid non-string command arrays" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const invalid = [_]struct { dockerfile: []const u8, message: []const u8 }{
        .{ .dockerfile = "FROM scratch\nCMD [\"true\",1]\n", .message = "CMD exec form must be a JSON string array" },
        .{ .dockerfile = "FROM scratch\nENTRYPOINT [\"true\",1]\n", .message = "ENTRYPOINT exec form must be a JSON string array" },
    };
    for (invalid) |case| {
        try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), case.dockerfile, &diagnostic));
        try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
        try std.testing.expectEqualStrings(case.message, diagnostic.message);
    }
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
    try std.testing.expectEqual(@as(?bool, null), doc.stages[1].instructions[0].value.copy.link);
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
        doc.stages[0].instructions[0].value.run.command.shell,
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
    const argv = doc.stages[0].instructions[0].value.run.command.exec;
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
    try std.testing.expectEqualStrings("COPY --link requires --from", diag.message);

    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), "FROM base\nCOPY --from=$STAGE /a /dest\n", &diag));
    try std.testing.expectEqualStrings("COPY --from does not support variable expansion or quoting", diag.message);
}

test "Dockerfile parser accepts bounded cross-stage COPY link booleans" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const doc = try parse(arena_state.allocator(),
        \\FROM base AS source
        \\FROM base
        \\COPY --link --from=source /true /true
        \\COPY --from=source --link=FALSE /false /false
        \\
    , &diag);
    try std.testing.expectEqual(@as(?bool, true), doc.stages[1].instructions[0].value.copy.link);
    try std.testing.expectEqual(@as(?bool, false), doc.stages[1].instructions[1].value.copy.link);

    const invalid = [_]struct { dockerfile: []const u8, message: []const u8 }{
        .{ .dockerfile = "FROM base AS source\nFROM base\nCOPY --link= --from=source /a /b\n", .message = "COPY --link requires true or false" },
        .{ .dockerfile = "FROM base AS source\nFROM base\nCOPY --link=yes --from=source /a /b\n", .message = "COPY --link requires true or false" },
        .{ .dockerfile = "FROM base AS source\nFROM base\nCOPY --link --link=false --from=source /a /b\n", .message = "duplicate COPY flag: --link" },
        .{ .dockerfile = "FROM base AS source\nFROM base\nCOPY --link=\"true\" --from=source /a /b\n", .message = "unsupported COPY flag: --link" },
        .{ .dockerfile = "FROM base\nCOPY --link=false /a /b\n", .message = "COPY --link requires --from" },
    };
    for (invalid) |case| {
        try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), case.dockerfile, &diag));
        try std.testing.expectEqualStrings(case.message, diag.message);
    }

    try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(),
        \\FROM base AS source
        \\FROM base
        \\COPY --link --from=source /a /b
        \\COPY --chmod=0755 --from=source /c /d
        \\
    , &diag));
    try std.testing.expectEqual(@as(usize, 4), diag.line);
    try std.testing.expectEqualStrings("unsupported COPY flag: --chmod", diag.message);
}

test "Dockerfile parser accepts strict context COPY parents booleans and rejects compositions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostic = .{};
    const doc = try parse(arena,
        \\FROM base
        \\COPY --parents one two /out/
        \\COPY --parents=FALSE nested/file /flat/
        \\
    , &diag);
    try std.testing.expectEqual(@as(?bool, true), doc.stages[0].instructions[0].value.copy.parents);
    try std.testing.expectEqual(@as(?bool, false), doc.stages[0].instructions[1].value.copy.parents);

    const invalid = [_]struct { dockerfile: []const u8, message: []const u8 }{
        .{ .dockerfile = "FROM base\nCOPY --parents= one /out/\n", .message = "COPY --parents requires true or false" },
        .{ .dockerfile = "FROM base\nCOPY --parents=yes one /out/\n", .message = "COPY --parents requires true or false" },
        .{ .dockerfile = "FROM base\nCOPY --parents --parents=false one /out/\n", .message = "duplicate COPY flag: --parents" },
        .{ .dockerfile = "FROM base\nCOPY --parents=\"true\" one /out/\n", .message = "unsupported COPY flag: --parents" },
        .{ .dockerfile = "FROM base AS source\nFROM base\nCOPY --parents --from=source /one /out/\n", .message = "COPY --parents does not support other flags" },
        .{ .dockerfile = "FROM base AS source\nFROM base\nCOPY --from=source --link --parents /one /out/\n", .message = "COPY --parents does not support other flags" },
        .{ .dockerfile = "FROM base\nCOPY --parents --chmod=0644 one /out/\n", .message = "unsupported COPY flag: --chmod" },
        .{ .dockerfile = "FROM base\nCOPY --parents <<EOF /out\nvalue\nEOF\n", .message = "unsupported COPY heredoc form" },
    };
    for (invalid) |case| {
        try std.testing.expectError(error.DockerfileParseFailed, parse(arena, case.dockerfile, &diag));
        try std.testing.expectEqualStrings(case.message, diag.message);
    }
}

test "Dockerfile parser accepts narrow remote ADD and rejects unsupported forms" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const doc = try parse(arena_state.allocator(), "FROM base\nADD https://example.com/${TARGETARCH}/tool /usr/bin/tool\n", &diag);
    const add = doc.stages[0].instructions[0].value.add;
    try std.testing.expect(add.chmod == null);
    try std.testing.expectEqualStrings("https://example.com/${TARGETARCH}/tool", add.source);
    try std.testing.expectEqualStrings("/usr/bin/tool", add.dest);

    const chmod_doc = try parse(arena_state.allocator(), "FROM base\nARG MODE=0644\nADD --chmod=${MODE} https://example.com/tool /tool\n", &diag);
    try std.testing.expectEqualStrings("${MODE}", chmod_doc.stages[0].instructions[1].value.add.chmod.?);
    const quoted_chmod_doc = try parse(arena_state.allocator(), "FROM base\nADD --chmod=\"0000644\" https://example.com/tool /tool\n", &diag);
    try std.testing.expectEqualStrings("\"0000644\"", quoted_chmod_doc.stages[0].instructions[0].value.add.chmod.?);

    const invalid_flags = [_]struct { dockerfile: []const u8, message: []const u8 }{
        .{ .dockerfile = "FROM base\nADD --chmod https://example.com/tool /tool\n", .message = "ADD --chmod requires a value" },
        .{ .dockerfile = "FROM base\nADD --chmod= https://example.com/tool /tool\n", .message = "ADD --chmod requires a non-empty octal value" },
        .{ .dockerfile = "FROM base\nADD --chmod=0644 --chmod=0600 https://example.com/tool /tool\n", .message = "duplicate ADD flag: --chmod" },
        .{ .dockerfile = "FROM base\nADD --chown=0:0 https://example.com/tool /tool\n", .message = "unsupported ADD flag: --chown" },
        .{ .dockerfile = "FROM base\nADD --chmod=0644 https://example.com/tool --link /tool\n", .message = "unsupported ADD flag: --link" },
    };
    for (invalid_flags) |case| {
        try std.testing.expectError(error.DockerfileParseFailed, parse(arena_state.allocator(), case.dockerfile, &diag));
        try std.testing.expectEqualStrings(case.message, diag.message);
    }
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
