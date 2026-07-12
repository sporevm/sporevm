const std = @import("std");
const Io = std.Io;
const Blake3 = std.crypto.hash.Blake3;

const chunk_sealer = @import("../chunk_sealer.zig");
const path_pattern = @import("path_pattern.zig");

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
    has_negations: bool = false,
};

const IgnoreRule = struct {
    pattern: path_pattern.Pattern,
    negated: bool = false,
};

pub const CopyEntry = struct {
    rel: []const u8,
    /// Physical context path to capture when Docker dereferences a symlink
    /// selected as a top-level COPY source. Empty means `rel`.
    source_rel: []const u8 = "",
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
        const owned_path = try self.allocator.dupe(u8, record.path);
        errdefer self.allocator.free(owned_path);
        const owned_digest = try self.allocator.dupe(u8, record.digest);
        errdefer self.allocator.free(owned_digest);
        const record_index = self.records.items.len;
        try self.records.append(.{
            .path = owned_path,
            .size = record.size,
            .mtime_ns = record.mtime_ns,
            .ctime_ns = record.ctime_ns,
            .inode = record.inode,
            .digest = owned_digest,
            .last_seen_unix_ns = record.last_seen_unix_ns,
        });
        errdefer self.records.shrinkRetainingCapacity(record_index);
        try self.index.put(self.allocator, key, record_index);
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
        const record_index = self.records.items.len;
        self.records.append(.{
            .path = owned_path,
            .size = stat.size,
            .mtime_ns = stat.mtime.nanoseconds,
            .ctime_ns = stat.ctime.nanoseconds,
            .inode = stat.inode,
            .digest = owned_digest,
            .last_seen_unix_ns = self.now_ns,
        }) catch {
            self.allocator.free(owned_digest);
            self.allocator.free(owned_path);
            self.allocator.free(key);
            return;
        };
        self.index.put(self.allocator, key, record_index) catch {
            self.records.shrinkRetainingCapacity(record_index);
            self.allocator.free(owned_digest);
            self.allocator.free(owned_path);
            self.allocator.free(key);
            return;
        };
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
    var has_negations = false;
    for (rules) |rule| has_negations = has_negations or rule.negated;
    return .{ .root = root, .absolute_root = absolute_root, .rules = rules, .has_negations = has_negations };
}

pub fn parseDockerignore(allocator: std.mem.Allocator, bytes: []const u8, diagnostic: *IgnoreDiagnostic) ![]IgnoreRule {
    var rules = std.array_list.Managed(IgnoreRule).init(allocator);
    var line_no: usize = 1;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| : (line_no += 1) {
        var untrimmed = raw;
        if (line_no == 1 and std.mem.startsWith(u8, untrimmed, "\xef\xbb\xbf")) untrimmed = untrimmed[3..];
        // Docker recognizes comments before trimming whitespace. A leading
        // space therefore escapes a literal pattern beginning with '#'.
        if (untrimmed.len != 0 and untrimmed[0] == '#') continue;
        var line = path_pattern.trimSpace(untrimmed);
        if (line.len == 0) continue;
        var negated = false;
        if (line[0] == '!') {
            negated = true;
            line = path_pattern.trimSpace(line[1..]);
            if (line.len == 0) return ignoreFail(diagnostic, line_no, "empty .dockerignore negation");
        }
        const cleaned = path_pattern.cleanDockerignorePattern(allocator, line) catch {
            return ignoreFail(diagnostic, line_no, "unsupported .dockerignore pattern");
        };
        // Docker historically treats a cleaned single dot as a no-op.
        if (std.mem.eql(u8, cleaned, ".")) continue;
        const pattern = path_pattern.Pattern.compile(allocator, cleaned, .dockerignore) catch {
            return ignoreFail(diagnostic, line_no, "unsupported .dockerignore pattern");
        };
        try rules.append(.{
            .pattern = pattern,
            .negated = negated,
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
        const source_rel = if (entry.source_rel.len == 0) entry.rel else entry.source_rel;
        const parent_rel = std.fs.path.dirname(source_rel) orelse "";
        const basename = std.fs.path.basename(source_rel);
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
                    try contentDigestForFile(allocator, io, context, source_rel, file, stat, options);
                if (captured != null) try updateStatCache(allocator, context, source_rel, stat, digest, options.stat_cache);
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
            // Symlinks discovered inside a copied directory are preserved.
            // A symlink selected as the source root is dereferenced earlier.
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
    const source = try cleanCopySource(allocator, raw_source);
    if (path_pattern.hasCopyMeta(source)) {
        const pattern = path_pattern.Pattern.compile(allocator, source, .copy) catch return error.UnsupportedCopyGlob;
        var dir = try openContextDir(io, context_root, "");
        defer dir.close(io);
        if (!try appendWildcardMatches(allocator, io, context, dir, "", pattern, entries, roots)) return error.CopySourceNotFound;
        return;
    }
    const parent_rel = std.fs.path.dirname(source) orelse "";
    const basename = std.fs.path.basename(source);
    var parent = try openContextDir(io, context_root, parent_rel);
    defer parent.close(io);
    if (!try appendPathAt(allocator, io, context, parent, basename, source, source, entries, roots, true)) return error.CopySourceNotFound;
}

fn appendWildcardMatches(
    allocator: std.mem.Allocator,
    io: Io,
    context: BuildContext,
    dir: Io.Dir,
    parent_rel: []const u8,
    pattern: path_pattern.Pattern,
    entries: *std.array_list.Managed(CopyEntry),
    roots: *std.array_list.Managed(CopyRoot),
) !bool {
    var children = std.array_list.Managed([]const u8).init(allocator);
    var it = dir.iterate();
    while (try it.next(io)) |child| try children.append(try allocator.dupe(u8, child.name));
    std.mem.sort([]const u8, children.items, {}, stringLessThan);

    var matched = false;
    for (children.items) |child| {
        const rel = if (parent_rel.len == 0)
            try allocator.dupe(u8, child)
        else
            try std.fs.path.join(allocator, &.{ parent_rel, child });
        const stat = try dir.statFile(io, child, .{ .follow_symlinks = false });
        if (pattern.matches(rel)) {
            matched = (try appendPathAt(allocator, io, context, dir, child, rel, rel, entries, roots, true)) or matched;
            continue;
        }
        if (!pattern.couldMatchDescendant(rel)) continue;
        switch (stat.kind) {
            .directory => {
                if (ignored(context, rel) and !couldIncludeDescendant(context, rel)) continue;
                {
                    var child_dir = dir.openDir(io, child, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
                        error.SymLinkLoop => return error.CopySourceEscapesContext,
                        else => |e| return e,
                    };
                    defer child_dir.close(io);
                    matched = (try appendWildcardMatches(allocator, io, context, child_dir, rel, pattern, entries, roots)) or matched;
                }
            },
            .sym_link => if (pattern.requiresLiteralDirectory(rel)) return error.CopySourceEscapesContext,
            else => {},
        }
    }
    return matched;
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
    source_rel: []const u8,
    output_rel: []const u8,
    entries: *std.array_list.Managed(CopyEntry),
    roots: *std.array_list.Managed(CopyRoot),
    source_root: bool,
) anyerror!bool {
    const stat = try parent.statFile(io, basename, .{ .follow_symlinks = false });
    if (source_root and stat.kind == .sym_link) {
        if (ignored(context, output_rel)) return false;
        const included = try appendDereferencedSourceSymlink(allocator, io, context, source_rel, output_rel, entries, roots);
        const after = try parent.statFile(io, basename, .{ .follow_symlinks = false });
        if (!sameFileStat(stat, after)) return error.BuildContextChangedDuringSnapshot;
        return included;
    }
    const is_ignored = ignored(context, source_rel);
    const included = switch (stat.kind) {
        .file, .sym_link => blk: {
            if (is_ignored) break :blk false;
            try entries.append(.{
                .rel = try allocator.dupe(u8, output_rel),
                .source_rel = if (std.mem.eql(u8, source_rel, output_rel)) "" else try allocator.dupe(u8, source_rel),
                .kind = stat.kind,
            });
            break :blk true;
        },
        .directory => blk: {
            if (is_ignored and !couldIncludeDescendant(context, source_rel)) break :blk false;
            if (!is_ignored) try entries.append(.{
                .rel = try allocator.dupe(u8, output_rel),
                .source_rel = if (std.mem.eql(u8, source_rel, output_rel)) "" else try allocator.dupe(u8, source_rel),
                .kind = .directory,
            });
            var dir = parent.openDir(io, basename, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
                error.SymLinkLoop => return error.CopySourceEscapesContext,
                else => |e| return e,
            };
            defer dir.close(io);
            var children = std.array_list.Managed([]const u8).init(allocator);
            var it = dir.iterate();
            while (try it.next(io)) |child| try children.append(try allocator.dupe(u8, child.name));
            std.mem.sort([]const u8, children.items, {}, stringLessThan);
            var child_included = false;
            for (children.items) |child| {
                const child_source_rel = if (std.mem.eql(u8, source_rel, "."))
                    try allocator.dupe(u8, child)
                else
                    try std.fs.path.join(allocator, &.{ source_rel, child });
                const child_output_rel = if (std.mem.eql(u8, output_rel, "."))
                    try allocator.dupe(u8, child)
                else
                    try std.fs.path.join(allocator, &.{ output_rel, child });
                child_included = (try appendPathAt(allocator, io, context, dir, child, child_source_rel, child_output_rel, entries, roots, false)) or child_included;
            }
            if (is_ignored and child_included) try entries.append(.{
                .rel = try allocator.dupe(u8, output_rel),
                .source_rel = if (std.mem.eql(u8, source_rel, output_rel)) "" else try allocator.dupe(u8, source_rel),
                .kind = .directory,
            });
            break :blk !is_ignored or child_included;
        },
        else => return error.UnsupportedCopySourceType,
    };
    if (included and source_root) try roots.append(.{ .rel = try allocator.dupe(u8, output_rel), .kind = stat.kind });
    return included;
}

fn appendDereferencedSourceSymlink(
    allocator: std.mem.Allocator,
    io: Io,
    context: BuildContext,
    source_rel: []const u8,
    output_rel: []const u8,
    entries: *std.array_list.Managed(CopyEntry),
    roots: *std.array_list.Managed(CopyRoot),
) !bool {
    const target_rel = try resolveContextSymlinkTarget(allocator, context, source_rel);
    const parent_rel = std.fs.path.dirname(target_rel) orelse "";
    const basename = std.fs.path.basename(target_rel);
    var context_root = Io.Dir.cwd().openDir(io, context.absolute_root, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.SymLinkLoop => return error.CopySourceEscapesContext,
        else => |e| return e,
    };
    defer context_root.close(io);
    var parent = try openContextDir(io, context_root, parent_rel);
    defer parent.close(io);
    const target_stat = try parent.statFile(io, basename, .{ .follow_symlinks = false });
    const included = try appendPathAt(allocator, io, context, parent, basename, target_rel, output_rel, entries, roots, false);
    const target_after = try parent.statFile(io, basename, .{ .follow_symlinks = false });
    if (!sameFileStat(target_stat, target_after)) return error.BuildContextChangedDuringSnapshot;
    if (included) try roots.append(.{ .rel = try allocator.dupe(u8, output_rel), .kind = target_stat.kind });
    return included;
}

fn resolveContextSymlinkTarget(allocator: std.mem.Allocator, context: BuildContext, source_rel: []const u8) ![]const u8 {
    const source = try std.fs.path.join(allocator, &.{ context.absolute_root, source_rel });
    defer allocator.free(source);
    const resolved = realpathAlloc(allocator, source) catch return error.CopySourceEscapesContext;
    defer allocator.free(resolved);
    if (std.mem.eql(u8, resolved, context.absolute_root)) return allocator.dupe(u8, ".");
    if (!std.mem.startsWith(u8, resolved, context.absolute_root) or
        resolved.len <= context.absolute_root.len or
        resolved[context.absolute_root.len] != std.fs.path.sep)
    {
        return error.CopySourceEscapesContext;
    }
    return allocator.dupe(u8, resolved[context.absolute_root.len + 1 ..]);
}

fn ignored(context: BuildContext, rel: []const u8) bool {
    var result = false;
    for (context.rules) |rule| {
        if (rule.negated != result) continue;
        if (rule.pattern.matchesOrParent(rel)) result = !rule.negated;
    }
    return result;
}

fn couldIncludeDescendant(context: BuildContext, rel: []const u8) bool {
    if (!context.has_negations) return false;
    for (context.rules) |rule| {
        if (!rule.negated) continue;
        if (rule.pattern.matchesOrParent(rel) or rule.pattern.couldMatchDescendant(rel)) return true;
    }
    return false;
}

fn cleanCopySource(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len == 0) return error.BadCopySource;
    if (std.fs.path.isAbsolute(raw)) return error.CopySourceEscapesContext;
    var components = std.array_list.Managed([]const u8).init(allocator);
    var it = std.mem.splitScalar(u8, raw, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.CopySourceEscapesContext;
        try components.append(part);
    }
    if (components.items.len == 0) return allocator.dupe(u8, ".");
    return std.mem.join(allocator, "/", components.items);
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
    try Io.Dir.cwd().createDirPath(io, context_root ++ "/src");
    try Io.Dir.cwd().createDirPath(io, root ++ "/outside");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/outside/secret.txt", .data = "secret" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = context_root ++ "/safe/inside.txt", .data = "inside" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = context_root ++ "/src/visible.txt", .data = "visible" });
    try Io.Dir.cwd().symLink(io, "../../outside", context_root ++ "/safe/leak", .{});
    try Io.Dir.cwd().symLink(io, "../outside", context_root ++ "/packages", .{});
    try Io.Dir.cwd().symLink(io, "../outside", context_root ++ "/unrelated", .{});

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
    const broad = try resolveCopySources(arena, io, ctx, &.{"**/*.txt"});
    try std.testing.expect(copyResolutionContains(broad, "safe/inside.txt"));
    try std.testing.expect(copyResolutionContains(broad, "src/visible.txt"));
}

test "COPY source resolution rejects a selected symlink outside the context" {
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
    try std.testing.expectError(error.CopySourceEscapesContext, resolveCopySources(arena, io, ctx, &.{"payload"}));
}

test "COPY dereferences a selected symlink within the context" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = "zig-cache/test-build-context-selected-symlink";
    const context_root = root ++ "/context";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, context_root ++ "/files");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = context_root ++ "/files/plain.txt", .data = "plain\n" });
    try Io.Dir.cwd().setFilePermissions(io, context_root ++ "/files/plain.txt", @enumFromInt(0o640), .{ .follow_symlinks = false });
    try Io.Dir.cwd().symLink(io, "files/plain.txt", context_root ++ "/plain-link", .{});

    var diag: IgnoreDiagnostic = .{};
    const ctx = try load(arena, io, context_root, &diag);
    const resolution = try resolveCopySources(arena, io, ctx, &.{"plain-link"});
    try std.testing.expectEqual(@as(usize, 1), resolution.entries.len);
    try std.testing.expectEqualStrings("plain-link", resolution.entries[0].rel);
    try std.testing.expectEqualStrings("files/plain.txt", resolution.entries[0].source_rel);
    try std.testing.expectEqual(Io.File.Kind.file, resolution.entries[0].kind);
    try std.testing.expectEqual(Io.File.Kind.file, resolution.roots[0].kind);
    const entries = try describeCopyResolutionWithOptions(arena, io, ctx, resolution, .{});
    try std.testing.expectEqual(@as(u32, 0o640), entries[0].mode);
    try std.testing.expect(std.mem.startsWith(u8, entries[0].content_digest, "blake3:"));
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
    const link_path = context_root ++ "/tree/link";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, context_root);
    try Io.Dir.cwd().createDirPath(io, context_root ++ "/tree");
    try Io.Dir.cwd().createDirPath(io, cache_root);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = "alpha" });
    try Io.Dir.cwd().symLink(io, "target-a", link_path, .{});

    var diag: IgnoreDiagnostic = .{};
    const ctx = try load(arena, io, context_root, &diag);
    const resolution = try resolveCopySources(arena, io, ctx, &.{ "payload.txt", "tree" });
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
        if (std.mem.eql(u8, entry.rel, "tree/link")) captured_link = entry;
    }
    var snapshot_file = try Io.Dir.cwd().openFile(io, captured_file.?.snapshot_path, .{ .mode = .read_only });
    defer snapshot_file.close(io);
    var bytes: [5]u8 = undefined;
    try std.testing.expectEqual(bytes.len, try snapshot_file.readPositionalAll(io, &bytes, captured_file.?.snapshot_offset));
    try std.testing.expectEqualStrings("alpha", &bytes);
    try std.testing.expectEqualStrings("target-a", captured_link.?.symlink_target);

    const fresh_resolution = try resolveCopySources(arena, io, ctx, &.{ "payload.txt", "tree" });
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

test "dockerignore rejects an empty negation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: IgnoreDiagnostic = .{};
    try std.testing.expectError(error.UnsupportedDockerignorePattern, parseDockerignore(arena_state.allocator(), "!\n", &diag));
    try std.testing.expectEqualStrings("empty .dockerignore negation", diag.message);
    try std.testing.expectEqual(@as(usize, 1), diag.line);
}

test "COPY source resolution supports filepath globs across components" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = "zig-cache/test-build-context-copy-globs";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, root ++ "/src/one");
    try Io.Dir.cwd().createDirPath(io, root ++ "/src/two/deep");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/babel.config.js", .data = "js" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/relay.config.mjs", .data = "mjs" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/plain.js", .data = "plain" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/literal*star", .data = "escaped" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/src/one/main.c", .data = "c" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/src/two/main.h", .data = "h" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/src/two/deep/main.c", .data = "deep" });

    var diag: IgnoreDiagnostic = .{};
    const ctx = try load(arena, io, root, &diag);
    const configs = try resolveCopySources(arena, io, ctx, &.{"*.config.*"});
    try std.testing.expectEqual(@as(usize, 2), configs.roots.len);
    try std.testing.expect(copyResolutionContains(configs, "babel.config.js"));
    try std.testing.expect(copyResolutionContains(configs, "relay.config.mjs"));
    try std.testing.expect(!copyResolutionContains(configs, "plain.js"));

    const dot_prefixed = try resolveCopySources(arena, io, ctx, &.{ "./babel.config.js", "./*.config.*" });
    try std.testing.expectEqual(@as(usize, 2), dot_prefixed.roots.len);
    try std.testing.expect(copyResolutionContains(dot_prefixed, "babel.config.js"));
    try std.testing.expect(copyResolutionContains(dot_prefixed, "relay.config.mjs"));
    for (dot_prefixed.entries) |entry| try std.testing.expect(!std.mem.startsWith(u8, entry.rel, "./"));

    const nested = try resolveCopySources(arena, io, ctx, &.{"./src//*/./main.[ch]"});
    try std.testing.expectEqual(@as(usize, 2), nested.roots.len);
    try std.testing.expect(copyResolutionContains(nested, "src/one/main.c"));
    try std.testing.expect(copyResolutionContains(nested, "src/two/main.h"));
    try std.testing.expect(!copyResolutionContains(nested, "src/two/deep/main.c"));

    const class_separator = try resolveCopySources(arena, io, ctx, &.{"src[/]one/main.c"});
    try std.testing.expectEqual(@as(usize, 1), class_separator.roots.len);
    try std.testing.expect(copyResolutionContains(class_separator, "src/one/main.c"));

    const escaped = try resolveCopySources(arena, io, ctx, &.{"literal\\*star"});
    try std.testing.expectEqual(@as(usize, 1), escaped.roots.len);
    try std.testing.expect(copyResolutionContains(escaped, "literal*star"));
}

test "dockerignore supports normalization globstars and excluded-parent reinclusion" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = "zig-cache/test-build-context-dockerignore-modern";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, root ++ "/build/keep");
    try Io.Dir.cwd().createDirPath(io, root ++ "/vendor");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/build/drop.txt", .data = "drop" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/build/keep/ok.txt", .data = "keep" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/vendor/dependency", .data = "ignored" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/a.tmp", .data = "ignored" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/aa.tmp", .data = "kept" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/a.log", .data = "ignored" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/c.log", .data = "kept" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/#literal", .data = "ignored" });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = root ++ "/.dockerignore",
        .data = "\xef\xbb\xbf# BOM comment\nbuild\n!build/keep/**\n?.tmp\n[ab].log\n/vendor/./\n #literal\n",
    });

    var diag: IgnoreDiagnostic = .{};
    const ctx = try load(arena, io, root, &diag);
    const resolution = try resolveCopySources(arena, io, ctx, &.{"."});
    try std.testing.expect(copyResolutionContains(resolution, "build"));
    try std.testing.expect(copyResolutionContains(resolution, "build/keep"));
    try std.testing.expect(copyResolutionContains(resolution, "build/keep/ok.txt"));
    try std.testing.expect(!copyResolutionContains(resolution, "build/drop.txt"));
    try std.testing.expect(!copyResolutionContains(resolution, "vendor"));
    try std.testing.expect(!copyResolutionContains(resolution, "a.tmp"));
    try std.testing.expect(copyResolutionContains(resolution, "aa.tmp"));
    try std.testing.expect(!copyResolutionContains(resolution, "a.log"));
    try std.testing.expect(copyResolutionContains(resolution, "c.log"));
    try std.testing.expect(!copyResolutionContains(resolution, "#literal"));
}

fn copyResolutionContains(resolution: CopyResolution, rel: []const u8) bool {
    for (resolution.entries) |entry| {
        if (std.mem.eql(u8, entry.rel, rel)) return true;
    }
    return false;
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

test "stat cache allocation failures never publish a dangling index" {
    const digest = "blake3:0000000000000000000000000000000000000000000000000000000000000000";
    const loaded = StatCacheRecord{
        .path = "input.txt",
        .size = 7,
        .mtime_ns = 11,
        .ctime_ns = 13,
        .inode = 17,
        .digest = digest,
    };
    const stat = std.mem.zeroes(Io.File.Stat);

    for (0..16) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        var cache = StatCache{
            .allocator = allocator,
            .io = std.testing.io,
            .path = "",
            .records = std.array_list.Managed(StatCacheRecord).init(allocator),
            .now_ns = 19,
        };
        defer deinitTestStatCache(&cache);
        _ = cache.putLoaded(loaded) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        };
        try std.testing.expectEqual(cache.records.items.len, cache.index.count());
    }

    for (0..16) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        var cache = StatCache{
            .allocator = allocator,
            .io = std.testing.io,
            .path = "",
            .records = std.array_list.Managed(StatCacheRecord).init(allocator),
            .now_ns = 19,
        };
        defer deinitTestStatCache(&cache);
        cache.put("input.txt", stat, digest);
        try std.testing.expectEqual(cache.records.items.len, cache.index.count());
    }
}

fn deinitTestStatCache(cache: *StatCache) void {
    var keys = cache.index.keyIterator();
    while (keys.next()) |key| cache.allocator.free(key.*);
    cache.index.deinit(cache.allocator);
    for (cache.records.items) |record| {
        cache.allocator.free(record.path);
        cache.allocator.free(record.digest);
    }
    cache.records.deinit();
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
