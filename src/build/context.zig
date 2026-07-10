const std = @import("std");
const Io = std.Io;
const Blake3 = std.crypto.hash.Blake3;

const chunk_sealer = @import("../chunk_sealer.zig");

pub const IgnoreDiagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

pub const CopyDiagnostic = struct {
    source: []const u8 = "",
};

pub const HashDiagnostic = struct {
    entries: u64 = 0,
    files: u64 = 0,
    directories: u64 = 0,
    symlinks: u64 = 0,
    bytes_hashed: u64 = 0,
    stat_cache_hits: u64 = 0,
    stat_cache_misses: u64 = 0,
    stat_cache_entries_loaded: u64 = 0,
    stat_cache_entries_saved: u64 = 0,
    stat_cache_entries_evicted: u64 = 0,
    stat_cache_load_failed: bool = false,
    stat_cache_save_failed: bool = false,
    stat_ns: u64 = 0,
    content_hash_ns: u64 = 0,
    cache_load_ns: u64 = 0,
    cache_save_ns: u64 = 0,

    pub fn add(self: *HashDiagnostic, other: HashDiagnostic) void {
        self.entries +|= other.entries;
        self.files +|= other.files;
        self.directories +|= other.directories;
        self.symlinks +|= other.symlinks;
        self.bytes_hashed +|= other.bytes_hashed;
        self.stat_cache_hits +|= other.stat_cache_hits;
        self.stat_cache_misses +|= other.stat_cache_misses;
        self.stat_cache_entries_loaded +|= other.stat_cache_entries_loaded;
        self.stat_cache_entries_saved = other.stat_cache_entries_saved;
        self.stat_cache_entries_evicted = other.stat_cache_entries_evicted;
        self.stat_cache_load_failed = self.stat_cache_load_failed or other.stat_cache_load_failed;
        self.stat_cache_save_failed = self.stat_cache_save_failed or other.stat_cache_save_failed;
        self.stat_ns +|= other.stat_ns;
        self.content_hash_ns +|= other.content_hash_ns;
        self.cache_load_ns +|= other.cache_load_ns;
        self.cache_save_ns +|= other.cache_save_ns;
    }
};

pub const BuildContext = struct {
    root: []const u8,
    absolute_root: []const u8,
    rules: []IgnoreRule = &.{},
};

const IgnoreRule = struct {
    pattern: []const u8,
    negated: bool = false,
    directory_only: bool = false,
    anchored: bool = false,
};

pub const CopyEntry = struct {
    rel: []const u8,
    kind: Io.File.Kind,
};

pub const CopyRoot = struct {
    rel: []const u8,
    kind: Io.File.Kind,
};

pub const CopyResolution = struct {
    entries: []const CopyEntry,
    roots: []const CopyRoot,
};

pub const CopyResolvedEntry = struct {
    rel: []const u8,
    kind: Io.File.Kind,
    mode: u32,
    size: u64 = 0,
    content_digest: []const u8 = "",
    symlink_target: []const u8 = "",
    snapshot_path: []const u8 = "",
    snapshot_offset: u64 = 0,
};

const snapshot_dir = "build/context-snapshots";

pub const CopySnapshot = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    file: ?Io.File,
    next_offset: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: Io, cache_root: []const u8) !CopySnapshot {
        const dir = try std.fs.path.join(allocator, &.{ cache_root, snapshot_dir });
        defer allocator.free(dir);
        try chunk_sealer.ensureDirPath(allocator, dir);
        const nonce = monotonicNs() catch 0;
        for (0..100) |attempt| {
            const path = try std.fmt.allocPrint(allocator, "{s}/snapshot-{d}-{d}-{d}.tmp", .{ dir, std.c.getpid(), nonce, attempt });
            const file = Io.Dir.cwd().createFile(io, path, .{
                .read = true,
                .exclusive = true,
                .permissions = @enumFromInt(0o600),
            }) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    allocator.free(path);
                    continue;
                },
                else => |e| {
                    allocator.free(path);
                    return e;
                },
            };
            return .{ .allocator = allocator, .path = path, .file = file };
        }
        return error.ContextSnapshotCreateFailed;
    }

    pub fn deinit(self: *CopySnapshot, io: Io) void {
        if (self.file) |file| {
            file.close(io);
            self.file = null;
        }
        Io.Dir.cwd().deleteFile(io, self.path) catch {};
    }

    pub fn seal(self: *CopySnapshot, io: Io) !void {
        const file = self.file orelse return;
        file.close(io);
        self.file = null;
        try Io.Dir.cwd().setFilePermissions(io, self.path, @enumFromInt(0o400), .{ .follow_symlinks = false });
    }

    fn captureFile(
        self: *CopySnapshot,
        io: Io,
        source: Io.File,
        stat: Io.File.Stat,
        diagnostic: ?*HashDiagnostic,
    ) !CapturedFile {
        const snapshot = self.file orelse return error.ContextSnapshotSealed;
        const start = monotonicNs() catch 0;
        const snapshot_offset = self.next_offset;
        const end_offset = std.math.add(u64, snapshot_offset, stat.size) catch return error.ContextSnapshotTooLarge;
        var h = Blake3.init(.{});
        var buf: [file_read_chunk_len]u8 = undefined;
        var source_offset: u64 = 0;
        while (source_offset < stat.size) {
            const want: usize = @intCast(@min(stat.size - source_offset, buf.len));
            const n = try source.readPositionalAll(io, buf[0..want], source_offset);
            if (n != want) return error.BuildContextChangedDuringSnapshot;
            const bytes = buf[0..n];
            h.update(bytes);
            if (!std.mem.allEqual(u8, bytes, 0)) try snapshot.writePositionalAll(io, bytes, snapshot_offset + source_offset);
            source_offset += n;
        }
        try snapshot.setLength(io, end_offset);
        const after = try source.stat(io);
        if (!sameFileStat(stat, after)) return error.BuildContextChangedDuringSnapshot;
        self.next_offset = end_offset;
        if (diagnostic) |diag| {
            diag.bytes_hashed +|= stat.size;
            diag.content_hash_ns +|= elapsedNs(start);
        }
        return .{
            .offset = snapshot_offset,
            .digest = try finishDigest(self.allocator, &h),
        };
    }
};

const CapturedFile = struct {
    offset: u64,
    digest: []const u8,
};

pub const HashOptions = struct {
    stat_cache: ?*StatCache = null,
    diagnostic: ?*HashDiagnostic = null,
};

const stat_cache_kind = "sporevm-build-context-stat-cache-v1";
const max_stat_cache_records = 131_072;
const max_stat_cache_bytes = 32 * 1024 * 1024;
const stat_cache_digest_len = "blake3:".len + Blake3.digest_length * 2;
const file_read_chunk_len = 256 * 1024;

const StatCacheFile = struct {
    kind: []const u8,
    max_records: usize = max_stat_cache_records,
    eviction: []const u8 = "least-recently-seen stat tuple",
    records: []StatCacheRecord,
};

const StatCacheRecord = struct {
    path: []const u8,
    size: u64,
    mtime_ns: i128,
    ctime_ns: i128,
    inode: u64,
    digest: []const u8,
    last_seen_unix_ns: i128 = 0,
};

pub const StatCache = struct {
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
    records: std.array_list.Managed(StatCacheRecord),
    index: std.StringHashMapUnmanaged(usize) = .empty,
    now_ns: i128,
    enabled: bool = true,

    pub fn load(allocator: std.mem.Allocator, io: Io, cache_root: []const u8, diagnostic: *HashDiagnostic) StatCache {
        const start = monotonicNs() catch 0;
        var cache = StatCache{
            .allocator = allocator,
            .io = io,
            .path = "",
            .records = std.array_list.Managed(StatCacheRecord).init(allocator),
            .now_ns = Io.Clock.real.now(io).nanoseconds,
        };
        cache.path = statCachePath(allocator, cache_root) catch {
            diagnostic.stat_cache_load_failed = true;
            diagnostic.cache_load_ns +|= elapsedNs(start);
            cache.enabled = false;
            return cache;
        };
        const bytes = Io.Dir.cwd().readFileAlloc(io, cache.path, allocator, .limited(max_stat_cache_bytes)) catch |err| switch (err) {
            error.FileNotFound, error.StreamTooLong => {
                if (err == error.StreamTooLong) diagnostic.stat_cache_load_failed = true;
                diagnostic.cache_load_ns +|= elapsedNs(start);
                return cache;
            },
            else => {
                diagnostic.stat_cache_load_failed = true;
                diagnostic.cache_load_ns +|= elapsedNs(start);
                return cache;
            },
        };
        defer allocator.free(bytes);
        var parsed = std.json.parseFromSlice(StatCacheFile, allocator, bytes, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch {
            diagnostic.stat_cache_load_failed = true;
            diagnostic.cache_load_ns +|= elapsedNs(start);
            return cache;
        };
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.kind, stat_cache_kind)) {
            diagnostic.stat_cache_load_failed = true;
            diagnostic.cache_load_ns +|= elapsedNs(start);
            return cache;
        }
        for (parsed.value.records) |record| {
            if (!validContentDigest(record.digest)) continue;
            cache.putLoaded(record) catch {
                diagnostic.stat_cache_load_failed = true;
                break;
            };
        }
        diagnostic.stat_cache_entries_loaded = cache.records.items.len;
        diagnostic.cache_load_ns +|= elapsedNs(start);
        return cache;
    }

    pub fn save(self: *StatCache, diagnostic: *HashDiagnostic) void {
        if (!self.enabled or self.path.len == 0) return;
        const start = monotonicNs() catch 0;
        self.saveInner(diagnostic) catch {
            diagnostic.stat_cache_save_failed = true;
        };
        diagnostic.cache_save_ns +|= elapsedNs(start);
    }

    fn saveInner(self: *StatCache, diagnostic: *HashDiagnostic) !void {
        if (self.records.items.len == 0) return;
        var records = try self.allocator.dupe(StatCacheRecord, self.records.items);
        defer self.allocator.free(records);
        std.mem.sort(StatCacheRecord, records, {}, recordMoreRecent);
        const keep = @min(records.len, max_stat_cache_records);
        const persisted = StatCacheFile{
            .kind = stat_cache_kind,
            .records = records[0..keep],
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, persisted, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = false,
        });
        defer self.allocator.free(json);
        if (json.len > max_stat_cache_bytes) return error.StreamTooLong;
        Io.Dir.cwd().deleteFile(self.io, self.path) catch {};
        try chunk_sealer.writeFileAtomicDurable(self.allocator, self.path, json, 0o644);
        diagnostic.stat_cache_entries_saved = keep;
        diagnostic.stat_cache_entries_evicted = records.len - keep;
    }

    fn putLoaded(self: *StatCache, record: StatCacheRecord) !void {
        const key = try statCacheKey(self.allocator, record.path, record.size, record.mtime_ns, record.ctime_ns, record.inode);
        errdefer self.allocator.free(key);
        if (self.index.contains(key)) {
            self.allocator.free(key);
            return;
        }
        try self.index.put(self.allocator, key, self.records.items.len);
        try self.records.append(.{
            .path = try self.allocator.dupe(u8, record.path),
            .size = record.size,
            .mtime_ns = record.mtime_ns,
            .ctime_ns = record.ctime_ns,
            .inode = record.inode,
            .digest = try self.allocator.dupe(u8, record.digest),
            .last_seen_unix_ns = record.last_seen_unix_ns,
        });
    }

    fn get(self: *StatCache, path: []const u8, stat: Io.File.Stat) ?[]const u8 {
        if (!self.enabled) return null;
        const key = statCacheKey(self.allocator, path, stat.size, stat.mtime.nanoseconds, stat.ctime.nanoseconds, stat.inode) catch return null;
        defer self.allocator.free(key);
        const i = self.index.get(key) orelse return null;
        const record = &self.records.items[i];
        if (!validContentDigest(record.digest)) return null;
        record.last_seen_unix_ns = self.now_ns;
        return record.digest;
    }

    fn put(self: *StatCache, path: []const u8, stat: Io.File.Stat, digest: []const u8) void {
        if (!self.enabled or !validContentDigest(digest)) return;
        const key = statCacheKey(self.allocator, path, stat.size, stat.mtime.nanoseconds, stat.ctime.nanoseconds, stat.inode) catch return;
        if (self.index.get(key)) |i| {
            self.records.items[i].last_seen_unix_ns = self.now_ns;
            self.allocator.free(key);
            return;
        }
        const owned_path = self.allocator.dupe(u8, path) catch {
            self.allocator.free(key);
            return;
        };
        const owned_digest = self.allocator.dupe(u8, digest) catch {
            self.allocator.free(owned_path);
            self.allocator.free(key);
            return;
        };
        self.index.put(self.allocator, key, self.records.items.len) catch {
            self.allocator.free(owned_digest);
            self.allocator.free(owned_path);
            self.allocator.free(key);
            return;
        };
        self.records.append(.{
            .path = owned_path,
            .size = stat.size,
            .mtime_ns = stat.mtime.nanoseconds,
            .ctime_ns = stat.ctime.nanoseconds,
            .inode = stat.inode,
            .digest = owned_digest,
            .last_seen_unix_ns = self.now_ns,
        }) catch {};
    }
};

pub fn load(allocator: std.mem.Allocator, io: Io, root: []const u8, diagnostic: *IgnoreDiagnostic) !BuildContext {
    diagnostic.* = .{};
    const absolute_root = realpathAlloc(allocator, root) catch try absoluteFallback(allocator, root);
    const ignore_path = try std.fs.path.join(allocator, &.{ root, ".dockerignore" });
    defer allocator.free(ignore_path);
    const bytes = Io.Dir.cwd().readFileAlloc(io, ignore_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .root = root, .absolute_root = absolute_root },
        else => |e| return e,
    };
    const rules = try parseDockerignore(allocator, bytes, diagnostic);
    return .{ .root = root, .absolute_root = absolute_root, .rules = rules };
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
    const resolution = try resolveCopySources(allocator, io, context, sources);
    return hashCopyResolution(allocator, io, context, resolution);
}

pub fn resolveCopySources(
    allocator: std.mem.Allocator,
    io: Io,
    context: BuildContext,
    sources: []const []const u8,
) !CopyResolution {
    return resolveCopySourcesWithDiagnostic(allocator, io, context, sources, null);
}

pub fn resolveCopySourcesWithDiagnostic(
    allocator: std.mem.Allocator,
    io: Io,
    context: BuildContext,
    sources: []const []const u8,
    diagnostic: ?*CopyDiagnostic,
) !CopyResolution {
    var entries = std.array_list.Managed(CopyEntry).init(allocator);
    var roots = std.array_list.Managed(CopyRoot).init(allocator);
    var context_root = Io.Dir.cwd().openDir(io, context.absolute_root, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.SymLinkLoop => return error.CopySourceEscapesContext,
        else => |e| return e,
    };
    defer context_root.close(io);
    for (sources) |source| {
        appendSourceMatches(allocator, io, context, context_root, source, &entries, &roots) catch |err| {
            if (err == error.CopySourceNotFound) {
                if (diagnostic) |diag| diag.source = source;
            }
            return err;
        };
    }
    if (entries.items.len == 0) return error.CopySourceNotFound;
    std.mem.sort(CopyEntry, entries.items, {}, entryLessThan);
    std.mem.sort(CopyRoot, roots.items, {}, rootLessThan);

    var deduped_entries = std.array_list.Managed(CopyEntry).init(allocator);
    var previous_entry: ?[]const u8 = null;
    for (entries.items) |entry| {
        if (previous_entry) |rel| {
            if (std.mem.eql(u8, rel, entry.rel)) continue;
        }
        previous_entry = entry.rel;
        try deduped_entries.append(entry);
    }

    var deduped_roots = std.array_list.Managed(CopyRoot).init(allocator);
    var previous_root: ?[]const u8 = null;
    for (roots.items) |root| {
        if (previous_root) |rel| {
            if (std.mem.eql(u8, rel, root.rel)) continue;
        }
        previous_root = root.rel;
        try deduped_roots.append(root);
    }

    return .{
        .entries = try deduped_entries.toOwnedSlice(),
        .roots = try deduped_roots.toOwnedSlice(),
    };
}

pub fn hashCopyResolution(
    allocator: std.mem.Allocator,
    io: Io,
    context: BuildContext,
    resolution: CopyResolution,
) ![]const u8 {
    return hashCopyResolutionWithOptions(allocator, io, context, resolution, .{});
}

pub fn hashCopyResolutionWithOptions(
    allocator: std.mem.Allocator,
    io: Io,
    context: BuildContext,
    resolution: CopyResolution,
    options: HashOptions,
) ![]const u8 {
    const entries = try describeCopyResolutionWithOptions(allocator, io, context, resolution, options);
    return hashResolvedCopyEntries(allocator, entries);
}

pub fn describeCopyResolutionWithOptions(
    allocator: std.mem.Allocator,
    io: Io,
    context: BuildContext,
    resolution: CopyResolution,
    options: HashOptions,
) ![]const CopyResolvedEntry {
    return resolveCopyEntries(allocator, io, context, resolution, options, null);
}

pub fn captureCopyResolutionWithOptions(
    allocator: std.mem.Allocator,
    io: Io,
    context: BuildContext,
    resolution: CopyResolution,
    options: HashOptions,
    snapshot: *CopySnapshot,
) ![]const CopyResolvedEntry {
    return resolveCopyEntries(allocator, io, context, resolution, options, snapshot);
}

fn resolveCopyEntries(
    allocator: std.mem.Allocator,
    io: Io,
    context: BuildContext,
    resolution: CopyResolution,
    options: HashOptions,
    snapshot: ?*CopySnapshot,
) ![]const CopyResolvedEntry {
    var out = std.array_list.Managed(CopyResolvedEntry).init(allocator);
    var context_root = Io.Dir.cwd().openDir(io, context.absolute_root, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.SymLinkLoop => return error.CopySourceEscapesContext,
        else => |e| return e,
    };
    defer context_root.close(io);
    for (resolution.entries) |entry| {
        if (options.diagnostic) |diag| diag.entries +|= 1;
        const parent_rel = std.fs.path.dirname(entry.rel) orelse "";
        const basename = std.fs.path.basename(entry.rel);
        var parent = openContextDir(io, context_root, parent_rel) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.SymLinkLoop => return error.BuildContextChangedDuringSnapshot,
            else => |e| return e,
        };
        defer parent.close(io);
        const stat_start = monotonicNs() catch 0;
        switch (entry.kind) {
            .file => {
                var file = parent.openFile(io, basename, .{
                    .mode = .read_only,
                    .allow_directory = false,
                    .follow_symlinks = false,
                }) catch |err| switch (err) {
                    error.FileNotFound, error.NotDir, error.SymLinkLoop, error.IsDir => return error.BuildContextChangedDuringSnapshot,
                    else => |e| return e,
                };
                defer file.close(io);
                const stat = try file.stat(io);
                if (stat.kind != .file) return error.BuildContextChangedDuringSnapshot;
                if (options.diagnostic) |diag| diag.stat_ns +|= elapsedNs(stat_start);
                if (options.diagnostic) |diag| diag.files +|= 1;
                const captured = if (snapshot) |capture| try capture.captureFile(io, file, stat, options.diagnostic) else null;
                const digest = if (captured) |value|
                    value.digest
                else
                    try contentDigestForFile(allocator, io, context, entry.rel, file, stat, options);
                if (captured != null) try updateStatCache(allocator, context, entry.rel, stat, digest, options.stat_cache);
                try out.append(.{
                    .rel = entry.rel,
                    .kind = entry.kind,
                    .mode = @intCast(@intFromEnum(stat.permissions) & 0o7777),
                    .size = stat.size,
                    .content_digest = digest,
                    .snapshot_path = if (captured != null) snapshot.?.path else "",
                    .snapshot_offset = if (captured) |value| value.offset else 0,
                });
            },
            .directory => {
                var dir = parent.openDir(io, basename, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
                    error.FileNotFound, error.NotDir, error.SymLinkLoop => return error.BuildContextChangedDuringSnapshot,
                    else => |e| return e,
                };
                defer dir.close(io);
                const stat = try dir.statFile(io, ".", .{ .follow_symlinks = false });
                if (stat.kind != .directory) return error.BuildContextChangedDuringSnapshot;
                if (options.diagnostic) |diag| diag.stat_ns +|= elapsedNs(stat_start);
                if (options.diagnostic) |diag| diag.directories +|= 1;
                try out.append(.{
                    .rel = entry.rel,
                    .kind = entry.kind,
                    .mode = @intCast(@intFromEnum(stat.permissions) & 0o7777),
                });
            },
            .sym_link => {
                const stat = parent.statFile(io, basename, .{ .follow_symlinks = false }) catch |err| switch (err) {
                    error.FileNotFound, error.NotDir, error.SymLinkLoop => return error.BuildContextChangedDuringSnapshot,
                    else => |e| return e,
                };
                if (stat.kind != .sym_link) return error.BuildContextChangedDuringSnapshot;
                if (options.diagnostic) |diag| diag.symlinks +|= 1;
                var target_buf: [4096]u8 = undefined;
                const len = parent.readLink(io, basename, &target_buf) catch |err| switch (err) {
                    error.FileNotFound, error.NotLink => return error.BuildContextChangedDuringSnapshot,
                    else => |e| return e,
                };
                const after = try parent.statFile(io, basename, .{ .follow_symlinks = false });
                if (!sameFileStat(stat, after)) return error.BuildContextChangedDuringSnapshot;
                if (options.diagnostic) |diag| diag.stat_ns +|= elapsedNs(stat_start);
                try out.append(.{
                    .rel = entry.rel,
                    .kind = entry.kind,
                    .mode = @intCast(@intFromEnum(stat.permissions) & 0o7777),
                    .symlink_target = try allocator.dupe(u8, target_buf[0..len]),
                });
            },
            else => return error.UnsupportedCopySourceType,
        }
    }
    return out.toOwnedSlice();
}

pub fn hashResolvedCopyEntries(
    allocator: std.mem.Allocator,
    entries: []const CopyResolvedEntry,
) ![]const u8 {
    var h = Blake3.init(.{});
    for (entries) |entry| {
        hashField(&h, entry.rel);
        hashField(&h, @tagName(entry.kind));
        var mode_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &mode_buf, entry.mode, .little);
        hashField(&h, &mode_buf);
        switch (entry.kind) {
            .file => hashField(&h, entry.content_digest),
            .directory => hashField(&h, ""),
            // Docker COPY preserves symlinks without following them, including targets outside the context.
            .sym_link => hashField(&h, entry.symlink_target),
            else => return error.UnsupportedCopySourceType,
        }
    }
    var digest: [Blake3.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "blake3:{s}", .{&hex});
}

fn contentDigestForFile(
    allocator: std.mem.Allocator,
    io: Io,
    context: BuildContext,
    rel: []const u8,
    file: Io.File,
    stat: Io.File.Stat,
    options: HashOptions,
) ![]const u8 {
    const absolute_path = try std.fs.path.join(allocator, &.{ context.absolute_root, rel });
    defer allocator.free(absolute_path);
    if (options.stat_cache) |cache| {
        if (cache.get(absolute_path, stat)) |digest| {
            const after = try file.stat(io);
            if (!sameFileStat(stat, after)) return error.BuildContextChangedDuringSnapshot;
            if (options.diagnostic) |diag| diag.stat_cache_hits +|= 1;
            return digest;
        }
        if (options.diagnostic) |diag| diag.stat_cache_misses +|= 1;
    }
    const digest = try hashFileDigest(allocator, io, file, stat, options.diagnostic);
    if (options.stat_cache) |cache| cache.put(absolute_path, stat, digest);
    return digest;
}

fn updateStatCache(
    allocator: std.mem.Allocator,
    context: BuildContext,
    rel: []const u8,
    stat: Io.File.Stat,
    digest: []const u8,
    maybe_cache: ?*StatCache,
) !void {
    const cache = maybe_cache orelse return;
    const absolute_path = try std.fs.path.join(allocator, &.{ context.absolute_root, rel });
    defer allocator.free(absolute_path);
    cache.put(absolute_path, stat, digest);
}

fn hashFileDigest(
    allocator: std.mem.Allocator,
    io: Io,
    file: Io.File,
    stat: Io.File.Stat,
    diagnostic: ?*HashDiagnostic,
) ![]const u8 {
    const start = monotonicNs() catch 0;
    var h = Blake3.init(.{});
    var buf: [file_read_chunk_len]u8 = undefined;
    var offset: u64 = 0;
    while (offset < stat.size) {
        const want: usize = @intCast(@min(stat.size - offset, buf.len));
        const n = try file.readPositionalAll(io, buf[0..want], offset);
        if (n != want) return error.BuildContextChangedDuringSnapshot;
        h.update(buf[0..n]);
        offset += n;
    }
    const after = try file.stat(io);
    if (!sameFileStat(stat, after)) return error.BuildContextChangedDuringSnapshot;
    if (diagnostic) |diag| {
        diag.bytes_hashed +|= stat.size;
        diag.content_hash_ns +|= elapsedNs(start);
    }
    return finishDigest(allocator, &h);
}

fn sameFileStat(a: Io.File.Stat, b: Io.File.Stat) bool {
    return a.kind == b.kind and
        a.size == b.size and
        a.permissions == b.permissions and
        a.inode == b.inode and
        a.mtime.nanoseconds == b.mtime.nanoseconds and
        a.ctime.nanoseconds == b.ctime.nanoseconds;
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
    context_root: Io.Dir,
    raw_source: []const u8,
    entries: *std.array_list.Managed(CopyEntry),
    roots: *std.array_list.Managed(CopyRoot),
) !void {
    try validateRelative(raw_source);
    const source = trimTrailingSlashes(raw_source);
    if (std.mem.indexOfAny(u8, source, "?[]") != null or std.mem.indexOf(u8, source, "**") != null) {
        return error.UnsupportedCopyGlob;
    }
    if (std.mem.indexOfScalar(u8, source, '*')) |star| {
        const slash = std.mem.lastIndexOfScalar(u8, source[0..star], '/') orelse 0;
        const parent_rel = if (slash == 0 and source[0] != '/') "" else source[0..slash];
        const pattern = source[(if (slash == 0) 0 else slash + 1)..];
        var dir = try openContextDir(io, context_root, parent_rel);
        defer dir.close(io);
        var matched = false;
        var it = dir.iterate();
        while (try it.next(io)) |child| {
            if (!starMatch(pattern, child.name)) continue;
            const rel = if (parent_rel.len == 0) try allocator.dupe(u8, child.name) else try std.fs.path.join(allocator, &.{ parent_rel, child.name });
            try appendPathAt(allocator, io, context, dir, child.name, rel, entries, roots, true);
            matched = true;
        }
        if (!matched) return error.CopySourceNotFound;
        return;
    }
    const parent_rel = std.fs.path.dirname(source) orelse "";
    const basename = std.fs.path.basename(source);
    var parent = try openContextDir(io, context_root, parent_rel);
    defer parent.close(io);
    try appendPathAt(allocator, io, context, parent, basename, source, entries, roots, true);
}

fn trimTrailingSlashes(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

fn openContextDir(io: Io, context_root: Io.Dir, rel: []const u8) !Io.Dir {
    var current = try context_root.openDir(io, ".", .{ .iterate = true, .follow_symlinks = false });
    errdefer current.close(io);
    var components = std.mem.splitScalar(u8, rel, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        const stat = try current.statFile(io, component, .{ .follow_symlinks = false });
        if (stat.kind == .sym_link) return error.CopySourceEscapesContext;
        const next = current.openDir(io, component, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
            error.SymLinkLoop => return error.CopySourceEscapesContext,
            else => |e| return e,
        };
        current.close(io);
        current = next;
    }
    return current;
}

fn appendPathAt(
    allocator: std.mem.Allocator,
    io: Io,
    context: BuildContext,
    parent: Io.Dir,
    basename: []const u8,
    rel: []const u8,
    entries: *std.array_list.Managed(CopyEntry),
    roots: *std.array_list.Managed(CopyRoot),
    source_root: bool,
) !void {
    if (ignored(context, rel, false)) return;
    const stat = try parent.statFile(io, basename, .{ .follow_symlinks = false });
    if (source_root) try roots.append(.{ .rel = try allocator.dupe(u8, rel), .kind = stat.kind });
    switch (stat.kind) {
        .file, .sym_link => try entries.append(.{ .rel = try allocator.dupe(u8, rel), .kind = stat.kind }),
        .directory => {
            if (ignored(context, rel, true)) return;
            try entries.append(.{ .rel = try allocator.dupe(u8, rel), .kind = .directory });
            var dir = parent.openDir(io, basename, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
                error.SymLinkLoop => return error.CopySourceEscapesContext,
                else => |e| return e,
            };
            defer dir.close(io);
            var children = std.array_list.Managed([]const u8).init(allocator);
            var it = dir.iterate();
            while (try it.next(io)) |child| try children.append(try allocator.dupe(u8, child.name));
            std.mem.sort([]const u8, children.items, {}, stringLessThan);
            for (children.items) |child| {
                const child_rel = if (std.mem.eql(u8, rel, "."))
                    try allocator.dupe(u8, child)
                else
                    try std.fs.path.join(allocator, &.{ rel, child });
                try appendPathAt(allocator, io, context, dir, child, child_rel, entries, roots, false);
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

fn entryLessThan(_: void, a: CopyEntry, b: CopyEntry) bool {
    return std.mem.lessThan(u8, a.rel, b.rel);
}

fn rootLessThan(_: void, a: CopyRoot, b: CopyRoot) bool {
    return std.mem.lessThan(u8, a.rel, b.rel);
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn ignoreFail(diagnostic: *IgnoreDiagnostic, line: usize, message: []const u8) error{UnsupportedDockerignorePattern} {
    diagnostic.* = .{ .line = line, .message = message };
    return error.UnsupportedDockerignorePattern;
}

fn statCachePath(allocator: std.mem.Allocator, cache_root: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ cache_root, "build", "context-stat-cache-v1.json" });
}

fn statCacheKey(allocator: std.mem.Allocator, path: []const u8, size: u64, mtime_ns: anytype, ctime_ns: anytype, inode: u64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\n{d}\n{d}\n{d}\n{d}", .{ path, size, mtime_ns, ctime_ns, inode });
}

fn validContentDigest(digest: []const u8) bool {
    if (digest.len != stat_cache_digest_len) return false;
    if (!std.mem.startsWith(u8, digest, "blake3:")) return false;
    for (digest["blake3:".len..]) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn finishDigest(allocator: std.mem.Allocator, h: *Blake3) ![]const u8 {
    var digest: [Blake3.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "blake3:{s}", .{&hex});
}

fn recordMoreRecent(_: void, a: StatCacheRecord, b: StatCacheRecord) bool {
    if (a.last_seen_unix_ns != b.last_seen_unix_ns) return a.last_seen_unix_ns > b.last_seen_unix_ns;
    return std.mem.lessThan(u8, a.path, b.path);
}

fn absoluteFallback(allocator: std.mem.Allocator, root: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(root)) return allocator.dupe(u8, root);
    const cwd = try realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, root });
}

fn realpathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = std.c.realpath(path_z, &buf) orelse return error.FileNotFound;
    return allocator.dupe(u8, std.mem.sliceTo(resolved, 0));
}

fn monotonicNs() !u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return error.ClockFailed;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn elapsedNs(start_ns: u64) u64 {
    if (start_ns == 0) return 0;
    const end_ns = monotonicNs() catch return 0;
    if (end_ns <= start_ns) return 0;
    return end_ns - start_ns;
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

test "COPY source resolution rejects intermediate symlinks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = "zig-cache/test-build-context-intermediate-symlink";
    const context_root = root ++ "/context";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, context_root ++ "/safe");
    try Io.Dir.cwd().createDirPath(io, root ++ "/outside");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/outside/secret.txt", .data = "secret" });
    try Io.Dir.cwd().symLink(io, "../../outside", context_root ++ "/safe/leak", .{});
    try Io.Dir.cwd().symLink(io, "../outside", context_root ++ "/packages", .{});

    var diag: IgnoreDiagnostic = .{};
    const ctx = try load(arena, io, context_root, &diag);
    try std.testing.expectError(
        error.CopySourceEscapesContext,
        resolveCopySources(arena, io, ctx, &.{"safe/leak/secret.txt"}),
    );
    try std.testing.expectError(
        error.CopySourceEscapesContext,
        resolveCopySources(arena, io, ctx, &.{"packages/secret.txt"}),
    );
    try std.testing.expectError(
        error.CopySourceEscapesContext,
        resolveCopySources(arena, io, ctx, &.{"packages/*.txt"}),
    );
}

test "COPY source resolution preserves a final symlink outside the context" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = "zig-cache/test-build-context-final-symlink";
    const context_root = root ++ "/context";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, context_root);
    try Io.Dir.cwd().createDirPath(io, root ++ "/outside");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/outside/secret.txt", .data = "secret" });
    try Io.Dir.cwd().symLink(io, "../outside/secret.txt", context_root ++ "/payload", .{});

    var diag: IgnoreDiagnostic = .{};
    const ctx = try load(arena, io, context_root, &diag);
    const resolution = try resolveCopySources(arena, io, ctx, &.{"payload"});
    try std.testing.expectEqual(@as(usize, 1), resolution.entries.len);
    try std.testing.expectEqual(Io.File.Kind.sym_link, resolution.entries[0].kind);
    try std.testing.expectEqual(@as(usize, 1), resolution.roots.len);
    try std.testing.expectEqual(Io.File.Kind.sym_link, resolution.roots[0].kind);
    const entries = try describeCopyResolutionWithOptions(arena, io, ctx, resolution, .{});
    try std.testing.expectEqualStrings("../outside/secret.txt", entries[0].symlink_target);
}

test "COPY snapshot pins file bytes and symlink targets" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = "zig-cache/test-build-context-snapshot-payload";
    const context_root = root ++ "/context";
    const cache_root = root ++ "/cache";
    const file_path = context_root ++ "/payload.txt";
    const link_path = context_root ++ "/link";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, context_root);
    try Io.Dir.cwd().createDirPath(io, cache_root);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = "alpha" });
    try Io.Dir.cwd().symLink(io, "target-a", link_path, .{});

    var diag: IgnoreDiagnostic = .{};
    const ctx = try load(arena, io, context_root, &diag);
    const resolution = try resolveCopySources(arena, io, ctx, &.{ "payload.txt", "link" });
    var snapshot = try CopySnapshot.init(arena, io, cache_root);
    defer snapshot.deinit(io);
    const captured = try captureCopyResolutionWithOptions(arena, io, ctx, resolution, .{}, &snapshot);
    const captured_digest = try hashResolvedCopyEntries(arena, captured);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = "bravo" });
    try Io.Dir.cwd().deleteFile(io, link_path);
    try Io.Dir.cwd().symLink(io, "target-b", link_path, .{});

    var captured_file: ?CopyResolvedEntry = null;
    var captured_link: ?CopyResolvedEntry = null;
    for (captured) |entry| {
        if (std.mem.eql(u8, entry.rel, "payload.txt")) captured_file = entry;
        if (std.mem.eql(u8, entry.rel, "link")) captured_link = entry;
    }
    var snapshot_file = try Io.Dir.cwd().openFile(io, captured_file.?.snapshot_path, .{ .mode = .read_only });
    defer snapshot_file.close(io);
    var bytes: [5]u8 = undefined;
    try std.testing.expectEqual(bytes.len, try snapshot_file.readPositionalAll(io, &bytes, captured_file.?.snapshot_offset));
    try std.testing.expectEqualStrings("alpha", &bytes);
    try std.testing.expectEqualStrings("target-a", captured_link.?.symlink_target);

    const fresh_resolution = try resolveCopySources(arena, io, ctx, &.{ "payload.txt", "link" });
    var fresh_snapshot = try CopySnapshot.init(arena, io, cache_root);
    defer fresh_snapshot.deinit(io);
    const fresh = try captureCopyResolutionWithOptions(arena, io, ctx, fresh_resolution, .{}, &fresh_snapshot);
    const fresh_digest = try hashResolvedCopyEntries(arena, fresh);
    try std.testing.expect(!std.mem.eql(u8, captured_digest, fresh_digest));

    try Io.Dir.cwd().deleteFile(io, file_path);
    try Io.Dir.cwd().deleteFile(io, link_path);
    try std.testing.expectEqual(bytes.len, try snapshot_file.readPositionalAll(io, &bytes, captured_file.?.snapshot_offset));
    try std.testing.expectEqualStrings("alpha", &bytes);
}

test "COPY snapshot rejects an intermediate symlink swap" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = "zig-cache/test-build-context-snapshot-symlink-swap";
    const context_root = root ++ "/context";
    const cache_root = root ++ "/cache";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, context_root ++ "/safe");
    try Io.Dir.cwd().createDirPath(io, root ++ "/outside");
    try Io.Dir.cwd().createDirPath(io, cache_root);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = context_root ++ "/safe/secret.txt", .data = "inside" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/outside/secret.txt", .data = "outside" });

    var diag: IgnoreDiagnostic = .{};
    const ctx = try load(arena, io, context_root, &diag);
    const resolution = try resolveCopySources(arena, io, ctx, &.{"safe/secret.txt"});
    try Io.Dir.cwd().deleteTree(io, context_root ++ "/safe");
    try Io.Dir.cwd().symLink(io, "../outside", context_root ++ "/safe", .{});
    var snapshot = try CopySnapshot.init(arena, io, cache_root);
    defer snapshot.deinit(io);
    try std.testing.expectError(
        error.CopySourceEscapesContext,
        captureCopyResolutionWithOptions(arena, io, ctx, resolution, .{}, &snapshot),
    );
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

test "context stat cache preserves cold hash identity and warms hits" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = "zig-cache/test-build-context-stat-cache";
    const cache_root = root ++ "/cache";
    const context_root = root ++ "/context";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, context_root ++ "/src");
    try Io.Dir.cwd().createDirPath(io, cache_root);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = context_root ++ "/src/a.txt", .data = "alpha" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = context_root ++ "/src/b.txt", .data = "beta" });

    var ignore_diag: IgnoreDiagnostic = .{};
    const ctx = try load(arena, io, context_root, &ignore_diag);
    const resolution = try resolveCopySources(arena, io, ctx, &.{"src"});

    var cold_diag: HashDiagnostic = .{};
    var cold_cache = StatCache.load(arena, io, cache_root, &cold_diag);
    const cold = try hashCopyResolutionWithOptions(arena, io, ctx, resolution, .{
        .stat_cache = &cold_cache,
        .diagnostic = &cold_diag,
    });
    cold_cache.save(&cold_diag);
    try std.testing.expectEqual(@as(u64, 0), cold_diag.stat_cache_hits);
    try std.testing.expect(cold_diag.stat_cache_misses >= 2);
    try std.testing.expect(cold_diag.bytes_hashed >= "alphabeta".len);

    var warm_diag: HashDiagnostic = .{};
    var warm_cache = StatCache.load(arena, io, cache_root, &warm_diag);
    const warm = try hashCopyResolutionWithOptions(arena, io, ctx, resolution, .{
        .stat_cache = &warm_cache,
        .diagnostic = &warm_diag,
    });
    try std.testing.expectEqualStrings(cold, warm);
    try std.testing.expect(warm_diag.stat_cache_hits >= 2);
    try std.testing.expectEqual(@as(u64, 0), warm_diag.bytes_hashed);
}

test "context stat cache invalidates same-size rewrites with restored mtime" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = "zig-cache/test-build-context-stat-cache-ctime";
    const cache_root = root ++ "/cache";
    const context_root = root ++ "/context";
    const source_path = context_root ++ "/input.txt";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, context_root);
    try Io.Dir.cwd().createDirPath(io, cache_root);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = "alpha" });

    var ignore_diag: IgnoreDiagnostic = .{};
    const ctx = try load(arena, io, context_root, &ignore_diag);
    const resolution = try resolveCopySources(arena, io, ctx, &.{"input.txt"});

    var cold_diag: HashDiagnostic = .{};
    var cold_cache = StatCache.load(arena, io, cache_root, &cold_diag);
    const cold = try hashCopyResolutionWithOptions(arena, io, ctx, resolution, .{
        .stat_cache = &cold_cache,
        .diagnostic = &cold_diag,
    });
    cold_cache.save(&cold_diag);
    const original_stat = try Io.Dir.cwd().statFile(io, source_path, .{ .follow_symlinks = false });

    var rewritten_stat = original_stat;
    for (0..200) |_| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = "bravo" });
        try Io.Dir.cwd().setTimestamps(io, source_path, .{
            .modify_timestamp = .{ .new = original_stat.mtime },
        });
        rewritten_stat = try Io.Dir.cwd().statFile(io, source_path, .{ .follow_symlinks = false });
        if (original_stat.ctime.nanoseconds != rewritten_stat.ctime.nanoseconds) break;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    try std.testing.expectEqual(original_stat.size, rewritten_stat.size);
    try std.testing.expectEqual(original_stat.mtime.nanoseconds, rewritten_stat.mtime.nanoseconds);
    try std.testing.expect(original_stat.ctime.nanoseconds != rewritten_stat.ctime.nanoseconds);

    var rewritten_diag: HashDiagnostic = .{};
    var rewritten_cache = StatCache.load(arena, io, cache_root, &rewritten_diag);
    const rewritten = try hashCopyResolutionWithOptions(arena, io, ctx, resolution, .{
        .stat_cache = &rewritten_cache,
        .diagnostic = &rewritten_diag,
    });
    try std.testing.expect(!std.mem.eql(u8, cold, rewritten));
    try std.testing.expectEqual(@as(u64, 0), rewritten_diag.stat_cache_hits);
    try std.testing.expectEqual(@as(u64, 1), rewritten_diag.stat_cache_misses);
    try std.testing.expectEqual(@as(u64, "bravo".len), rewritten_diag.bytes_hashed);
}

fn oldUnframedHashCopySourcesForTest(
    allocator: std.mem.Allocator,
    io: Io,
    context: BuildContext,
    sources: []const []const u8,
) ![]const u8 {
    var entries = std.array_list.Managed(CopyEntry).init(allocator);
    var roots = std.array_list.Managed(CopyRoot).init(allocator);
    var context_root = try Io.Dir.cwd().openDir(io, context.absolute_root, .{ .iterate = true, .follow_symlinks = false });
    defer context_root.close(io);
    for (sources) |source| {
        try appendSourceMatches(allocator, io, context, context_root, source, &entries, &roots);
    }
    std.mem.sort(CopyEntry, entries.items, {}, entryLessThan);

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
