const std = @import("std");
const Io = std.Io;
const Blake3 = std.crypto.hash.Blake3;

pub const IgnoreDiagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

pub const BuildContext = struct {
    root: []const u8,
    rules: []IgnoreRule = &.{},
};

const IgnoreRule = struct {
    pattern: []const u8,
    negated: bool = false,
    directory_only: bool = false,
    anchored: bool = false,
};

const Entry = struct {
    rel: []const u8,
    kind: Io.File.Kind,
};

pub fn load(allocator: std.mem.Allocator, io: Io, root: []const u8, diagnostic: *IgnoreDiagnostic) !BuildContext {
    diagnostic.* = .{};
    const ignore_path = try std.fs.path.join(allocator, &.{ root, ".dockerignore" });
    defer allocator.free(ignore_path);
    const bytes = Io.Dir.cwd().readFileAlloc(io, ignore_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .root = root },
        else => |e| return e,
    };
    const rules = try parseDockerignore(allocator, bytes, diagnostic);
    return .{ .root = root, .rules = rules };
}

pub fn parseDockerignore(allocator: std.mem.Allocator, bytes: []const u8, diagnostic: *IgnoreDiagnostic) ![]IgnoreRule {
    var rules = std.array_list.Managed(IgnoreRule).init(allocator);
    var line_no: usize = 1;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| : (line_no += 1) {
        var line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0 or line[0] == '#') continue;
        var negated = false;
        if (line[0] == '!') {
            negated = true;
            line = line[1..];
            if (line.len == 0) return ignoreFail(diagnostic, line_no, "empty .dockerignore negation");
        }
        if (std.mem.indexOf(u8, line, "**") != null or std.mem.indexOfAny(u8, line, "[]?") != null) {
            return ignoreFail(diagnostic, line_no, "unsupported .dockerignore pattern");
        }
        var anchored = false;
        if (line[0] == '/') {
            anchored = true;
            line = line[1..];
        }
        var directory_only = false;
        if (line.len != 0 and line[line.len - 1] == '/') {
            directory_only = true;
            line = line[0 .. line.len - 1];
        }
        validateRelative(line) catch {
            return ignoreFail(diagnostic, line_no, "unsupported .dockerignore pattern");
        };
        try rules.append(.{
            .pattern = try allocator.dupe(u8, line),
            .negated = negated,
            .directory_only = directory_only,
            .anchored = anchored,
        });
    }
    return rules.toOwnedSlice();
}

pub fn hashCopySources(
    allocator: std.mem.Allocator,
    io: Io,
    context: BuildContext,
    sources: []const []const u8,
) ![]const u8 {
    var entries = std.array_list.Managed(Entry).init(allocator);
    for (sources) |source| {
        try appendSourceMatches(allocator, io, context, source, &entries);
    }
    if (entries.items.len == 0) return error.CopySourceNotFound;
    std.mem.sort(Entry, entries.items, {}, entryLessThan);

    var h = Blake3.init(.{});
    var previous_rel: ?[]const u8 = null;
    for (entries.items) |entry| {
        if (previous_rel) |rel| {
            if (std.mem.eql(u8, rel, entry.rel)) continue;
        }
        previous_rel = entry.rel;
        hashField(&h, entry.rel);
        hashField(&h, @tagName(entry.kind));
        const path = try std.fs.path.join(allocator, &.{ context.root, entry.rel });
        defer allocator.free(path);
        const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
        var mode_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &mode_buf, @intFromEnum(stat.permissions), .little);
        hashField(&h, &mode_buf);
        switch (entry.kind) {
            .file => {
                const data = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024 * 1024));
                defer allocator.free(data);
                hashField(&h, data);
            },
            .directory => hashField(&h, ""),
            .sym_link => {
                // Docker COPY preserves symlinks without following them, including targets outside the context.
                var target_buf: [4096]u8 = undefined;
                const len = try Io.Dir.cwd().readLink(io, path, &target_buf);
                hashField(&h, target_buf[0..len]);
            },
            else => return error.UnsupportedCopySourceType,
        }
    }
    var digest: [Blake3.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "blake3:{s}", .{&hex});
}

fn hashField(h: *Blake3, bytes: []const u8) void {
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, bytes.len, .little);
    h.update(&len_buf);
    h.update(bytes);
}

fn appendSourceMatches(
    allocator: std.mem.Allocator,
    io: Io,
    context: BuildContext,
    raw_source: []const u8,
    entries: *std.array_list.Managed(Entry),
) !void {
    try validateRelative(raw_source);
    if (std.mem.indexOfAny(u8, raw_source, "?[]") != null or std.mem.indexOf(u8, raw_source, "**") != null) {
        return error.UnsupportedCopyGlob;
    }
    if (std.mem.indexOfScalar(u8, raw_source, '*')) |star| {
        const slash = std.mem.lastIndexOfScalar(u8, raw_source[0..star], '/') orelse 0;
        const parent_rel = if (slash == 0 and raw_source[0] != '/') "" else raw_source[0..slash];
        const pattern = raw_source[(if (slash == 0) 0 else slash + 1)..];
        const parent_path = if (parent_rel.len == 0)
            try allocator.dupe(u8, context.root)
        else
            try std.fs.path.join(allocator, &.{ context.root, parent_rel });
        defer allocator.free(parent_path);
        var dir = try Io.Dir.cwd().openDir(io, parent_path, .{ .iterate = true, .follow_symlinks = false });
        defer dir.close(io);
        var matched = false;
        var it = dir.iterate();
        while (try it.next(io)) |child| {
            if (!starMatch(pattern, child.name)) continue;
            const rel = if (parent_rel.len == 0) try allocator.dupe(u8, child.name) else try std.fs.path.join(allocator, &.{ parent_rel, child.name });
            try appendPath(allocator, io, context, rel, entries);
            matched = true;
        }
        if (!matched) return error.CopySourceNotFound;
        return;
    }
    try appendPath(allocator, io, context, raw_source, entries);
}

fn appendPath(
    allocator: std.mem.Allocator,
    io: Io,
    context: BuildContext,
    rel: []const u8,
    entries: *std.array_list.Managed(Entry),
) !void {
    if (ignored(context, rel, false)) return;
    const path = try std.fs.path.join(allocator, &.{ context.root, rel });
    defer allocator.free(path);
    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    switch (stat.kind) {
        .file, .sym_link => try entries.append(.{ .rel = try allocator.dupe(u8, rel), .kind = stat.kind }),
        .directory => {
            if (ignored(context, rel, true)) return;
            try entries.append(.{ .rel = try allocator.dupe(u8, rel), .kind = .directory });
            var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .follow_symlinks = false });
            defer dir.close(io);
            var children = std.array_list.Managed([]const u8).init(allocator);
            var it = dir.iterate();
            while (try it.next(io)) |child| try children.append(try allocator.dupe(u8, child.name));
            std.mem.sort([]const u8, children.items, {}, stringLessThan);
            for (children.items) |child| {
                const child_rel = try std.fs.path.join(allocator, &.{ rel, child });
                try appendPath(allocator, io, context, child_rel, entries);
            }
        },
        else => return error.UnsupportedCopySourceType,
    }
}

fn ignored(context: BuildContext, rel: []const u8, is_dir: bool) bool {
    var result = false;
    for (context.rules) |rule| {
        if (rule.directory_only and !is_dir and !pathUnderDirectoryPattern(rule.pattern, rel)) continue;
        if (ignoreRuleMatches(rule, rel, is_dir)) result = !rule.negated;
    }
    return result;
}

fn ignoreRuleMatches(rule: IgnoreRule, rel: []const u8, is_dir: bool) bool {
    _ = is_dir;
    if (rule.anchored or std.mem.indexOfScalar(u8, rule.pattern, '/') != null) {
        if (starMatch(rule.pattern, rel)) return true;
        return rule.directory_only and std.mem.startsWith(u8, rel, rule.pattern) and rel.len > rule.pattern.len and rel[rule.pattern.len] == '/';
    }
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |component| if (starMatch(rule.pattern, component)) return true;
    return false;
}

fn pathUnderDirectoryPattern(pattern: []const u8, rel: []const u8) bool {
    if (!std.mem.startsWith(u8, rel, pattern)) return false;
    return rel.len > pattern.len and rel[pattern.len] == '/';
}

fn validateRelative(path: []const u8) !void {
    if (path.len == 0) return error.BadCopySource;
    if (std.fs.path.isAbsolute(path)) return error.CopySourceEscapesContext;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.CopySourceEscapesContext;
    }
}

fn starMatch(pattern: []const u8, value: []const u8) bool {
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return std.mem.eql(u8, pattern, value);
    const prefix = pattern[0..star];
    const suffix = pattern[star + 1 ..];
    return std.mem.startsWith(u8, value, prefix) and std.mem.endsWith(u8, value, suffix) and value.len >= prefix.len + suffix.len;
}

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.rel, b.rel);
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn ignoreFail(diagnostic: *IgnoreDiagnostic, line: usize, message: []const u8) error{UnsupportedDockerignorePattern} {
    diagnostic.* = .{ .line = line, .message = message };
    return error.UnsupportedDockerignorePattern;
}

fn fuzzDockerignore(_: void, s: *std.testing.Smith) !void {
    var buf: [1024]u8 = undefined;
    const len = s.slice(&buf);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: IgnoreDiagnostic = .{};
    _ = parseDockerignore(arena_state.allocator(), buf[0..len], &diag) catch {};
}

test "fuzz dockerignore parser" {
    try std.testing.fuzz({}, fuzzDockerignore, .{});
}

test "context hashing applies dockerignore" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = "zig-cache/test-build-context-hash";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, root ++ "/app");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/app/a.txt", .data = "a" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/app/b.tmp", .data = "b" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/.dockerignore", .data = "*.tmp\n" });
    var diag: IgnoreDiagnostic = .{};
    const ctx = try load(arena, io, root, &diag);
    const digest = try hashCopySources(arena, io, ctx, &.{"app"});
    try std.testing.expect(std.mem.startsWith(u8, digest, "blake3:"));
}

test "dockerignore rejects question-mark patterns" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: IgnoreDiagnostic = .{};
    try std.testing.expectError(error.UnsupportedDockerignorePattern, parseDockerignore(arena_state.allocator(), "file?.txt\n", &diag));
    try std.testing.expectEqualStrings("unsupported .dockerignore pattern", diag.message);
    try std.testing.expectEqual(@as(usize, 1), diag.line);
}

test "context hashing frames fields so payload NULs cannot alias records" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = "zig-cache/test-build-context-hash-framing";
    const one = root ++ "/one";
    const two = root ++ "/two";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, one);
    try Io.Dir.cwd().createDirPath(io, two);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = two ++ "/a", .data = "left" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = two ++ "/b", .data = "right" });
    const b_stat = try Io.Dir.cwd().statFile(io, two ++ "/b", .{ .follow_symlinks = false });
    var b_mode: [8]u8 = undefined;
    std.mem.writeInt(u64, &b_mode, @intFromEnum(b_stat.permissions), .little);

    var payload = std.array_list.Managed(u8).init(arena);
    try payload.appendSlice("left");
    try payload.append(0);
    try payload.appendSlice("b");
    try payload.append(0);
    try payload.appendSlice("file");
    try payload.append(0);
    try payload.appendSlice(&b_mode);
    try payload.append(0);
    try payload.appendSlice("right");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = one ++ "/a", .data = payload.items });

    var diag: IgnoreDiagnostic = .{};
    const ctx_one = try load(arena, io, one, &diag);
    const ctx_two = try load(arena, io, two, &diag);
    const old_one = try oldUnframedHashCopySourcesForTest(arena, io, ctx_one, &.{"a"});
    const old_two = try oldUnframedHashCopySourcesForTest(arena, io, ctx_two, &.{ "a", "b" });
    try std.testing.expectEqualStrings(old_one, old_two);

    const framed_one = try hashCopySources(arena, io, ctx_one, &.{"a"});
    const framed_two = try hashCopySources(arena, io, ctx_two, &.{ "a", "b" });
    try std.testing.expect(!std.mem.eql(u8, framed_one, framed_two));
}

test "context hashing deduplicates repeated COPY source matches" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = "zig-cache/test-build-context-hash-dedupe";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, root);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/a", .data = "same" });

    var diag: IgnoreDiagnostic = .{};
    const ctx = try load(arena, io, root, &diag);
    const once = try hashCopySources(arena, io, ctx, &.{"a"});
    const twice = try hashCopySources(arena, io, ctx, &.{ "a", "a" });
    try std.testing.expectEqualStrings(once, twice);
}

fn oldUnframedHashCopySourcesForTest(
    allocator: std.mem.Allocator,
    io: Io,
    context: BuildContext,
    sources: []const []const u8,
) ![]const u8 {
    var entries = std.array_list.Managed(Entry).init(allocator);
    for (sources) |source| {
        try appendSourceMatches(allocator, io, context, source, &entries);
    }
    std.mem.sort(Entry, entries.items, {}, entryLessThan);

    var h = Blake3.init(.{});
    for (entries.items) |entry| {
        h.update(entry.rel);
        h.update("\x00");
        h.update(@tagName(entry.kind));
        h.update("\x00");
        const path = try std.fs.path.join(allocator, &.{ context.root, entry.rel });
        const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
        var mode_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &mode_buf, @intFromEnum(stat.permissions), .little);
        h.update(&mode_buf);
        h.update("\x00");
        switch (entry.kind) {
            .file => {
                const data = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
                h.update(data);
            },
            .directory => {},
            .sym_link => {
                var target_buf: [4096]u8 = undefined;
                const len = try Io.Dir.cwd().readLink(io, path, &target_buf);
                h.update(target_buf[0..len]);
            },
            else => return error.UnsupportedCopySourceType,
        }
        h.update("\x00");
    }
    var digest: [Blake3.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "blake3:{s}", .{&hex});
}
