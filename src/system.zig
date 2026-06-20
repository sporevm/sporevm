//! Local system inspection and cleanup commands.

const std = @import("std");
const Io = std.Io;

const local_paths = @import("local_paths.zig");
const default_prune_max_bytes = 0;

const usage =
    \\Usage:
    \\  spore system df [--rootfs] [--json]
    \\  spore system prune [--rootfs] [--dry-run|--force] [--older-than DURATION] [--max-bytes SIZE] [--include-digest-artifacts] [--json]
    \\
    \\Options:
    \\  --rootfs                    Inspect or prune the rootfs cache
    \\  --json                      Print stable machine-readable JSON
    \\  --dry-run                   Report prune candidates without deleting them (default)
    \\  --force                     Delete selected cache entries
    \\  --older-than DURATION       Select entries older than 7d, 24h, 30m, or seconds
    \\  --max-bytes SIZE            Prune oldest entries until the selected cache scope is under SIZE
    \\  --include-digest-artifacts  Also prune digest-addressed rootfs artifacts used by resume
    \\  -h, --help                  Show this help
    \\
    \\Defaults:
    \\  prune selects all default-prunable rootfs entries when no age or size limit is set
    \\
;

pub const CacheStats = struct {
    count: usize = 0,
    bytes: u64 = 0,
};

pub const RootfsSystemSummary = struct {
    cache_root: []const u8,
    image_rootfs: CacheStats = .{},
    linked_image_rootfs: CacheStats = .{},
    image_metadata: CacheStats = .{},
    digest_artifacts: CacheStats = .{},
    ref_records: CacheStats = .{},
    temp_entries: CacheStats = .{},
    known_logical_bytes: u64 = 0,
    default_prunable_bytes: u64 = 0,
};

const RootfsEntryKind = enum {
    image_rootfs,
    digest_artifact,

    fn label(self: RootfsEntryKind) []const u8 {
        return switch (self) {
            .image_rootfs => "image-rootfs",
            .digest_artifact => "digest-artifact",
        };
    }
};

pub const RootfsPruneEntry = struct {
    kind: []const u8,
    path: []const u8,
    metadata_path: ?[]const u8 = null,
    bytes: u64,
    metadata_bytes: u64 = 0,
    reclaimable_bytes: u64 = 0,
    link_count: u64 = 1,
    mtime_unix: i64,
};

pub const RootfsPruneResult = struct {
    cache_root: []const u8,
    dry_run: bool,
    include_digest_artifacts: bool,
    older_than_seconds: ?u64 = null,
    max_bytes: ?u64 = null,
    scope_bytes_before: u64 = 0,
    scope_bytes_after: u64 = 0,
    candidate_count: usize = 0,
    candidate_bytes: u64 = 0,
    candidate_reclaimable_bytes: u64 = 0,
    default_selection: bool = false,
    deleted_count: usize = 0,
    deleted_bytes: u64 = 0,
    deleted_reclaimable_bytes: u64 = 0,
    entries: []const RootfsPruneEntry = &.{},
};

const PruneOptions = struct {
    dry_run: bool = true,
    include_digest_artifacts: bool = false,
    older_than_ns: ?i96 = null,
    older_than_seconds: ?u64 = null,
    max_bytes: ?u64 = null,
    default_selection: bool = false,
};

const PrunePlanEntry = struct {
    kind: RootfsEntryKind,
    path: []const u8,
    metadata_path: ?[]const u8 = null,
    bytes: u64,
    metadata_bytes: u64 = 0,
    link_count: u64 = 1,
    mtime_ns: i96,
    selected: bool = false,

    fn logicalBytes(self: PrunePlanEntry) u64 {
        return self.bytes + self.metadata_bytes;
    }

    fn reclaimableBytes(self: PrunePlanEntry) u64 {
        return (if (self.link_count <= 1) self.bytes else 0) + self.metadata_bytes;
    }
};

pub fn run(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0 or wantsHelp(args[0])) {
        try stdout.writeAll(usage);
        return;
    }

    if (std.mem.eql(u8, args[0], "df")) {
        try dfCli(init, args[1..], stdout);
        return;
    }
    if (std.mem.eql(u8, args[0], "prune")) {
        try pruneCli(init, args[1..], stdout);
        return;
    }

    std.debug.print("unknown system command: {s}\n\n{s}", .{ args[0], usage });
    std.process.exit(2);
}

fn dfCli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    var json = false;
    for (args) |arg| {
        if (wantsHelp(arg)) {
            try stdout.writeAll(usage);
            return;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (!std.mem.eql(u8, arg, "--rootfs")) {
            std.debug.print("unknown system df argument: {s}\n\n{s}", .{ arg, usage });
            std.process.exit(2);
        }
    }

    const allocator = init.arena.allocator();
    const cache_root = try rootfsCacheRootPath(allocator, init.environ_map);
    const summary = try summarizeRootfsCache(allocator, init.io, cache_root);
    if (json) {
        try writeJson(allocator, stdout, summary);
    } else {
        try writeRootfsSummary(stdout, summary);
    }
}

fn pruneCli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    var opts = PruneOptions{};
    var json = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (wantsHelp(arg)) {
            try stdout.writeAll(usage);
            return;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--rootfs")) {
            continue;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            opts.dry_run = false;
        } else if (std.mem.eql(u8, arg, "--include-digest-artifacts")) {
            opts.include_digest_artifacts = true;
        } else if (std.mem.eql(u8, arg, "--older-than")) {
            i += 1;
            if (i >= args.len) return missingValue("--older-than");
            const seconds = parseDurationSeconds(args[i]) catch return invalidValue("--older-than", args[i]);
            opts.older_than_seconds = seconds;
            opts.older_than_ns = @as(i96, seconds) * std.time.ns_per_s;
        } else if (std.mem.eql(u8, arg, "--max-bytes")) {
            i += 1;
            if (i >= args.len) return missingValue("--max-bytes");
            opts.max_bytes = parseByteSize(args[i]) catch return invalidValue("--max-bytes", args[i]);
        } else {
            std.debug.print("unknown system prune argument: {s}\n\n{s}", .{ arg, usage });
            std.process.exit(2);
        }
    }

    if (opts.older_than_ns == null and opts.max_bytes == null) {
        if (opts.include_digest_artifacts) {
            std.debug.print("spore system prune: set --older-than or --max-bytes when using --include-digest-artifacts\n\n{s}", .{usage});
            std.process.exit(2);
        }
        opts.max_bytes = default_prune_max_bytes;
        opts.default_selection = true;
    }

    const allocator = init.arena.allocator();
    const cache_root = try rootfsCacheRootPath(allocator, init.environ_map);
    const now = Io.Clock.real.now(init.io).nanoseconds;
    const result = try pruneRootfsCache(allocator, init.io, cache_root, opts, now);
    if (json) {
        try writeJson(allocator, stdout, result);
    } else {
        try writeRootfsPruneResult(stdout, result);
    }
}

fn summarizeRootfsCache(allocator: std.mem.Allocator, io: Io, cache_root: []const u8) !RootfsSystemSummary {
    var summary = RootfsSystemSummary{ .cache_root = cache_root };
    var root = openDirPath(io, cache_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return summary,
        else => |e| return e,
    };
    defer root.close(io);

    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".ext4")) {
            const stat = try root.statFile(io, entry.name, .{ .follow_symlinks = false });
            summary.image_rootfs.count += 1;
            summary.image_rootfs.bytes += stat.size;
            if (stat.nlink > 1) {
                summary.linked_image_rootfs.count += 1;
                summary.linked_image_rootfs.bytes += stat.size;
            } else {
                const metadata_path = try metadataPathForExt4(allocator, cache_root, entry.name);
                const metadata_size = fileSizeNoSymlink(io, metadata_path) catch |err| switch (err) {
                    error.FileNotFound => 0,
                    else => |e| return e,
                };
                summary.default_prunable_bytes += stat.size + metadata_size;
            }
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
            const stat = try root.statFile(io, entry.name, .{ .follow_symlinks = false });
            summary.image_metadata.count += 1;
            summary.image_metadata.bytes += stat.size;
        } else if (entry.kind == .directory and std.mem.eql(u8, entry.name, "refs")) {
            summary.ref_records = try treeStats(allocator, io, cache_root, "refs");
        } else if (entry.kind == .directory and std.mem.eql(u8, entry.name, "tmp")) {
            summary.temp_entries = try treeStats(allocator, io, cache_root, "tmp");
        }
    }

    summary.digest_artifacts = try digestArtifactStats(allocator, io, cache_root);
    summary.known_logical_bytes = summary.image_rootfs.bytes + summary.image_metadata.bytes +
        summary.digest_artifacts.bytes + summary.ref_records.bytes + summary.temp_entries.bytes;
    return summary;
}

fn pruneRootfsCache(
    allocator: std.mem.Allocator,
    io: Io,
    cache_root: []const u8,
    opts: PruneOptions,
    now_ns: i96,
) !RootfsPruneResult {
    const plan = try collectPruneEntries(allocator, io, cache_root, opts.include_digest_artifacts);
    std.mem.sort(PrunePlanEntry, plan, {}, lessPrunePlanEntry);

    var scope_bytes_before: u64 = 0;
    for (plan) |entry| scope_bytes_before += entry.logicalBytes();

    var remaining = scope_bytes_before;
    if (opts.older_than_ns) |age_ns| {
        const cutoff = now_ns - age_ns;
        for (plan) |*entry| {
            if (entry.mtime_ns < cutoff) {
                entry.selected = true;
                remaining -= entry.logicalBytes();
            }
        }
    }

    if (opts.max_bytes) |max_bytes| {
        for (plan) |*entry| {
            if (remaining <= max_bytes) break;
            if (entry.selected) continue;
            entry.selected = true;
            remaining -= entry.logicalBytes();
        }
    }

    var result_entries = std.array_list.Managed(RootfsPruneEntry).init(allocator);
    var candidate_bytes: u64 = 0;
    var candidate_reclaimable_bytes: u64 = 0;
    var deleted_count: usize = 0;
    var deleted_bytes: u64 = 0;
    var deleted_reclaimable_bytes: u64 = 0;

    for (plan) |entry| {
        if (!entry.selected) continue;
        const logical = entry.logicalBytes();
        const reclaimable = entry.reclaimableBytes();
        candidate_bytes += logical;
        candidate_reclaimable_bytes += reclaimable;
        try result_entries.append(.{
            .kind = entry.kind.label(),
            .path = entry.path,
            .metadata_path = entry.metadata_path,
            .bytes = entry.bytes,
            .metadata_bytes = entry.metadata_bytes,
            .reclaimable_bytes = reclaimable,
            .link_count = entry.link_count,
            .mtime_unix = @intCast(@divFloor(entry.mtime_ns, std.time.ns_per_s)),
        });
        if (!opts.dry_run) {
            try Io.Dir.cwd().deleteFile(io, entry.path);
            if (entry.metadata_path) |metadata_path| {
                Io.Dir.cwd().deleteFile(io, metadata_path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => |e| return e,
                };
            }
            deleted_count += 1;
            deleted_bytes += logical;
            deleted_reclaimable_bytes += reclaimable;
        }
    }

    const entries = try result_entries.toOwnedSlice();
    return .{
        .cache_root = cache_root,
        .dry_run = opts.dry_run,
        .include_digest_artifacts = opts.include_digest_artifacts,
        .older_than_seconds = opts.older_than_seconds,
        .max_bytes = opts.max_bytes,
        .scope_bytes_before = scope_bytes_before,
        .scope_bytes_after = scope_bytes_before - candidate_bytes,
        .candidate_count = entries.len,
        .candidate_bytes = candidate_bytes,
        .candidate_reclaimable_bytes = candidate_reclaimable_bytes,
        .default_selection = opts.default_selection,
        .deleted_count = deleted_count,
        .deleted_bytes = deleted_bytes,
        .deleted_reclaimable_bytes = deleted_reclaimable_bytes,
        .entries = entries,
    };
}

fn collectPruneEntries(
    allocator: std.mem.Allocator,
    io: Io,
    cache_root: []const u8,
    include_digest_artifacts: bool,
) ![]PrunePlanEntry {
    var entries = std.array_list.Managed(PrunePlanEntry).init(allocator);

    var root = openDirPath(io, cache_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return entries.toOwnedSlice(),
        else => |e| return e,
    };
    defer root.close(io);

    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".ext4")) continue;
        const stat = try root.statFile(io, entry.name, .{ .follow_symlinks = false });
        if (stat.kind != .file) continue;
        if (stat.nlink > 1 and !include_digest_artifacts) continue;
        const path = try std.fs.path.join(allocator, &.{ cache_root, entry.name });
        const metadata_path = try metadataPathForExt4(allocator, cache_root, entry.name);
        const metadata_size = fileSizeNoSymlink(io, metadata_path) catch |err| switch (err) {
            error.FileNotFound => 0,
            else => |e| return e,
        };
        try entries.append(.{
            .kind = .image_rootfs,
            .path = path,
            .metadata_path = if (metadata_size == 0) null else metadata_path,
            .bytes = stat.size,
            .metadata_bytes = metadata_size,
            .link_count = @intCast(stat.nlink),
            .mtime_ns = stat.mtime.nanoseconds,
        });
    }

    if (include_digest_artifacts) {
        try collectDigestArtifacts(allocator, io, cache_root, &entries);
    }

    return entries.toOwnedSlice();
}

fn collectDigestArtifacts(
    allocator: std.mem.Allocator,
    io: Io,
    cache_root: []const u8,
    entries: *std.array_list.Managed(PrunePlanEntry),
) !void {
    const digest_dir_path = try std.fs.path.join(allocator, &.{ cache_root, "by-digest", "blake3" });
    var dir = openDirPath(io, digest_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".ext4")) continue;
        const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
        if (stat.kind != .file) continue;
        const path = try std.fs.path.join(allocator, &.{ digest_dir_path, entry.name });
        try entries.append(.{
            .kind = .digest_artifact,
            .path = path,
            .bytes = stat.size,
            .link_count = @intCast(stat.nlink),
            .mtime_ns = stat.mtime.nanoseconds,
        });
    }
}

fn digestArtifactStats(allocator: std.mem.Allocator, io: Io, cache_root: []const u8) !CacheStats {
    const digest_dir_path = try std.fs.path.join(allocator, &.{ cache_root, "by-digest", "blake3" });
    var dir = openDirPath(io, digest_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => |e| return e,
    };
    defer dir.close(io);

    var stats = CacheStats{};
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".ext4")) continue;
        const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
        if (stat.kind != .file) continue;
        stats.count += 1;
        stats.bytes += stat.size;
    }
    return stats;
}

fn treeStats(allocator: std.mem.Allocator, io: Io, root: []const u8, sub_path: []const u8) !CacheStats {
    const path = try std.fs.path.join(allocator, &.{ root, sub_path });
    var dir = openDirPath(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => |e| return e,
    };
    defer dir.close(io);
    return treeStatsDir(allocator, io, dir, path);
}

fn treeStatsDir(allocator: std.mem.Allocator, io: Io, dir: Io.Dir, dir_path: []const u8) !CacheStats {
    var stats = CacheStats{};
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file) {
            const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
            if (stat.kind != .file) continue;
            stats.count += 1;
            stats.bytes += stat.size;
        } else if (entry.kind == .directory) {
            const child_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            var child = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
            defer child.close(io);
            const child_stats = try treeStatsDir(allocator, io, child, child_path);
            stats.count += child_stats.count;
            stats.bytes += child_stats.bytes;
        }
    }
    return stats;
}

fn metadataPathForExt4(allocator: std.mem.Allocator, cache_root: []const u8, ext4_name: []const u8) ![]const u8 {
    const stem = ext4_name[0 .. ext4_name.len - ".ext4".len];
    const metadata_name = try std.fmt.allocPrint(allocator, "{s}.json", .{stem});
    return std.fs.path.join(allocator, &.{ cache_root, metadata_name });
}

fn fileSizeNoSymlink(io: Io, path: []const u8) !u64 {
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => return error.FileNotFound,
        else => |e| return e,
    };
    if (stat.kind != .file) return error.FileNotFound;
    return stat.size;
}

fn lessPrunePlanEntry(_: void, a: PrunePlanEntry, b: PrunePlanEntry) bool {
    if (a.mtime_ns != b.mtime_ns) return a.mtime_ns < b.mtime_ns;
    return std.mem.lessThan(u8, a.path, b.path);
}

fn rootfsCacheRootPath(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    return local_paths.rootfsCacheRootPath(allocator, environ) catch |err| switch (err) {
        error.MissingHome => {
            std.debug.print("spore system: cannot resolve rootfs cache directory; set {s} or HOME\n", .{local_paths.rootfs_cache_env});
            std.process.exit(2);
        },
        else => |e| return e,
    };
}

fn parseDurationSeconds(raw: []const u8) !u64 {
    if (raw.len == 0) return error.InvalidDuration;
    const suffix = raw[raw.len - 1];
    const multiplier: u64 = switch (suffix) {
        's', 'S' => 1,
        'm', 'M' => 60,
        'h', 'H' => 60 * 60,
        'd', 'D' => 24 * 60 * 60,
        else => 1,
    };
    const digits = if (multiplier == 1 and std.ascii.isDigit(suffix)) raw else raw[0 .. raw.len - 1];
    if (digits.len == 0) return error.InvalidDuration;
    const value = try std.fmt.parseInt(u64, digits, 10);
    return std.math.mul(u64, value, multiplier) catch error.InvalidDuration;
}

fn parseByteSize(raw: []const u8) !u64 {
    if (raw.len == 0) return error.InvalidSize;
    var digit_len: usize = 0;
    while (digit_len < raw.len and std.ascii.isDigit(raw[digit_len])) : (digit_len += 1) {}
    if (digit_len == 0) return error.InvalidSize;
    const value = try std.fmt.parseInt(u64, raw[0..digit_len], 10);
    const suffix = raw[digit_len..];
    const multiplier: u64 = if (suffix.len == 0 or equalsIgnoreCase(suffix, "b"))
        1
    else if (equalsIgnoreCase(suffix, "k") or equalsIgnoreCase(suffix, "kb") or equalsIgnoreCase(suffix, "kib"))
        1024
    else if (equalsIgnoreCase(suffix, "m") or equalsIgnoreCase(suffix, "mb") or equalsIgnoreCase(suffix, "mib"))
        1024 * 1024
    else if (equalsIgnoreCase(suffix, "g") or equalsIgnoreCase(suffix, "gb") or equalsIgnoreCase(suffix, "gib"))
        1024 * 1024 * 1024
    else if (equalsIgnoreCase(suffix, "t") or equalsIgnoreCase(suffix, "tb") or equalsIgnoreCase(suffix, "tib"))
        1024 * 1024 * 1024 * 1024
    else
        return error.InvalidSize;
    return std.math.mul(u64, value, multiplier) catch error.InvalidSize;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

fn wantsHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

fn missingValue(flag: []const u8) noreturn {
    std.debug.print("{s} requires a value\n", .{flag});
    std.process.exit(2);
}

fn invalidValue(flag: []const u8, value: []const u8) noreturn {
    std.debug.print("invalid {s}: {s}\n", .{ flag, value });
    std.process.exit(2);
}

fn openDirPath(io: Io, path: []const u8, flags: Io.Dir.OpenOptions) !Io.Dir {
    if (Io.Dir.path.isAbsolute(path)) return Io.Dir.openDirAbsolute(io, path, flags);
    return Io.Dir.cwd().openDir(io, path, flags);
}

fn writeJson(allocator: std.mem.Allocator, writer: *Io.Writer, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    try writer.writeAll(json);
    try writer.writeByte('\n');
}

fn writeRootfsSummary(writer: *Io.Writer, summary: RootfsSystemSummary) !void {
    try writer.print("Rootfs cache: {s}\n\n", .{summary.cache_root});

    try writer.writeAll("Cleanup\n");
    try writer.writeAll("  Reclaimable by default: ");
    try writeHumanBytes(writer, summary.default_prunable_bytes);
    try writer.writeByte('\n');
    try writer.writeAll("  Normal prune skips digest artifacts and hardlinked image rootfs files.\n\n");

    try writer.writeAll("Usage\n");
    try writeStatsLine(writer, "Image rootfs files", summary.image_rootfs);
    try writeStatsLine(writer, "Linked image rootfs files", summary.linked_image_rootfs);
    try writeStatsLine(writer, "Digest artifacts", summary.digest_artifacts);
    try writeStatsLine(writer, "Image metadata", summary.image_metadata);
    try writeStatsLine(writer, "Ref records", summary.ref_records);
    try writeStatsLine(writer, "Temporary entries", summary.temp_entries);
    try writer.writeAll("  Known logical data: ");
    try writeHumanBytes(writer, summary.known_logical_bytes);
    try writer.writeAll(" (categories can overlap through hardlinks)\n\n");
    try writer.writeAll("Use --json for exact byte counts.\n");
}

fn writeStatsLine(writer: *Io.Writer, label: []const u8, stats: CacheStats) !void {
    try writer.print("  {s}: {d} entries, ", .{ label, stats.count });
    try writeHumanBytes(writer, stats.bytes);
    try writer.writeByte('\n');
}

fn writeRootfsPruneResult(writer: *Io.Writer, result: RootfsPruneResult) !void {
    if (result.dry_run) {
        try writer.writeAll("Rootfs prune dry run\n");
    } else {
        try writer.writeAll("Rootfs prune\n");
    }
    try writer.print("  Cache: {s}\n", .{result.cache_root});
    try writer.writeAll("  Selection: ");
    try writePruneSelection(writer, result);
    try writer.writeByte('\n');
    try writer.print("  Digest artifacts included: {s}\n", .{yesNo(result.include_digest_artifacts)});
    if (result.dry_run) {
        try writer.print("  Would delete: {d} entries\n", .{result.candidate_count});
        try writer.writeAll("  Would remove from cache scope: ");
        try writeHumanBytes(writer, result.candidate_bytes);
        try writer.writeByte('\n');
        try writer.writeAll("  Would reclaim: ");
        try writeHumanBytes(writer, result.candidate_reclaimable_bytes);
        try writer.writeByte('\n');
    } else {
        try writer.print("  Deleted: {d} entries\n", .{result.deleted_count});
        try writer.writeAll("  Removed from cache scope: ");
        try writeHumanBytes(writer, result.deleted_bytes);
        try writer.writeByte('\n');
        try writer.writeAll("  Reclaimed: ");
        try writeHumanBytes(writer, result.deleted_reclaimable_bytes);
        try writer.writeByte('\n');
    }
    try writer.writeAll("  Scope before: ");
    try writeHumanBytes(writer, result.scope_bytes_before);
    try writer.writeByte('\n');
    try writer.writeAll("  Scope after: ");
    try writeHumanBytes(writer, result.scope_bytes_after);
    try writer.writeByte('\n');

    if (result.entries.len == 0) {
        try writer.writeAll("\nNo entries selected.\n");
    } else {
        try writer.writeByte('\n');
        try writer.writeAll(if (result.dry_run) "Candidates\n" else "Deleted\n");
        const visible_count = @min(result.entries.len, 20);
        for (result.entries[0..visible_count]) |entry| {
            try writer.print("  - {s} ", .{entry.kind});
            try writeDisplayPath(writer, entry.path);
            try writer.writeAll(": ");
            try writeHumanBytes(writer, entry.bytes + entry.metadata_bytes);
            if (entry.reclaimable_bytes != entry.bytes + entry.metadata_bytes) {
                try writer.writeAll(" (reclaimable ");
                try writeHumanBytes(writer, entry.reclaimable_bytes);
                try writer.writeByte(')');
            }
            if (entry.link_count > 1) {
                try writer.print(" ({d} links)", .{entry.link_count});
            }
            try writer.writeByte('\n');
        }
        if (result.entries.len > visible_count) {
            try writer.print("  ... {d} more entries omitted; use --json for the full list.\n", .{result.entries.len - visible_count});
        }
    }

    if (result.dry_run and result.candidate_count > 0) {
        try writer.writeAll("\nRun again with --force to delete the selected entries.\n");
    }
    try writer.writeAll("Use --json for exact paths and byte counts.\n");
}

fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

fn writePruneSelection(writer: *Io.Writer, result: RootfsPruneResult) !void {
    if (result.default_selection) {
        try writer.writeAll("all default-prunable rootfs entries");
        return;
    }

    var wrote = false;
    if (result.older_than_seconds) |seconds| {
        try writer.writeAll("entries older than ");
        try writeHumanDuration(writer, seconds);
        wrote = true;
    }
    if (result.max_bytes) |max_bytes| {
        if (wrote) try writer.writeAll(", then ");
        try writer.writeAll("oldest entries until cache scope is under ");
        try writeHumanBytes(writer, max_bytes);
        wrote = true;
    }
    if (!wrote) try writer.writeAll("none");
}

fn writeHumanDuration(writer: *Io.Writer, seconds: u64) !void {
    const day = 24 * 60 * 60;
    const hour = 60 * 60;
    const minute = 60;
    if (seconds != 0 and seconds % day == 0) {
        try writer.print("{d}d", .{seconds / day});
    } else if (seconds != 0 and seconds % hour == 0) {
        try writer.print("{d}h", .{seconds / hour});
    } else if (seconds != 0 and seconds % minute == 0) {
        try writer.print("{d}m", .{seconds / minute});
    } else {
        try writer.print("{d}s", .{seconds});
    }
}

fn writeDisplayPath(writer: *Io.Writer, path: []const u8) !void {
    const name = std.fs.path.basename(path);
    if (name.len <= 48) {
        try writer.writeAll(name);
        return;
    }

    try writer.writeAll(name[0..12]);
    try writer.writeAll("...");
    try writer.writeAll(name[name.len - 16 ..]);
}

fn writeHumanBytes(writer: *Io.Writer, bytes: u64) !void {
    const Unit = struct {
        bytes: u64,
        label: []const u8,
    };
    const units = [_]Unit{
        .{ .bytes = 1024 * 1024 * 1024 * 1024, .label = "TiB" },
        .{ .bytes = 1024 * 1024 * 1024, .label = "GiB" },
        .{ .bytes = 1024 * 1024, .label = "MiB" },
        .{ .bytes = 1024, .label = "KiB" },
    };

    for (units) |unit| {
        if (bytes < unit.bytes) continue;
        const rounded_tenths = (@as(u128, bytes) * 10 + @as(u128, unit.bytes / 2)) / @as(u128, unit.bytes);
        const whole: u64 = @intCast(rounded_tenths / 10);
        const fractional: u8 = @intCast(rounded_tenths % 10);
        if (fractional == 0) {
            try writer.print("{d} {s}", .{ whole, unit.label });
        } else {
            try writer.print("{d}.{d} {s}", .{ whole, fractional, unit.label });
        }
        return;
    }

    try writer.print("{d} B", .{bytes});
}

test "system parses durations and byte sizes" {
    try std.testing.expectEqual(@as(u64, 7), try parseDurationSeconds("7"));
    try std.testing.expectEqual(@as(u64, 7), try parseDurationSeconds("7s"));
    try std.testing.expectEqual(@as(u64, 420), try parseDurationSeconds("7m"));
    try std.testing.expectEqual(@as(u64, 25_200), try parseDurationSeconds("7h"));
    try std.testing.expectEqual(@as(u64, 604_800), try parseDurationSeconds("7d"));

    try std.testing.expectEqual(@as(u64, 42), try parseByteSize("42"));
    try std.testing.expectEqual(@as(u64, 42), try parseByteSize("42b"));
    try std.testing.expectEqual(@as(u64, 42 * 1024), try parseByteSize("42kb"));
    try std.testing.expectEqual(@as(u64, 42 * 1024 * 1024), try parseByteSize("42MiB"));
    try std.testing.expectEqual(@as(u64, 42 * 1024 * 1024 * 1024), try parseByteSize("42g"));
}

test "system formats byte sizes for human output" {
    const allocator = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeHumanBytes(&out.writer, 0);
    try std.testing.expectEqualStrings("0 B", out.written());
    out.clearRetainingCapacity();

    try writeHumanBytes(&out.writer, 1536);
    try std.testing.expectEqualStrings("1.5 KiB", out.written());
    out.clearRetainingCapacity();

    try writeHumanBytes(&out.writer, 1024 * 1024 * 1024);
    try std.testing.expectEqualStrings("1 GiB", out.written());
}

test "system summarizes rootfs cache and dry-run prunes oldest image entries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    const root = "zig-cache/test-system-prune";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, root);
    try Io.Dir.cwd().createDirPath(io, root ++ "/by-digest/blake3");
    try Io.Dir.cwd().createDirPath(io, root ++ "/refs");
    try Io.Dir.cwd().createDirPath(io, root ++ "/tmp");

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/a.ext4", .data = "aaaa" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/a.json", .data = "{}" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/b.ext4", .data = "bbbbbb" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/b.json", .data = "{}" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/by-digest/blake3/c.ext4", .data = "cccccccc" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/refs/ref.json", .data = "{}" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/tmp/tmpfile", .data = "tmp" });

    const summary = try summarizeRootfsCache(allocator, io, root);
    try std.testing.expectEqual(@as(usize, 2), summary.image_rootfs.count);
    try std.testing.expectEqual(@as(u64, 10), summary.image_rootfs.bytes);
    try std.testing.expectEqual(@as(usize, 2), summary.image_metadata.count);
    try std.testing.expectEqual(@as(u64, 4), summary.image_metadata.bytes);
    try std.testing.expectEqual(@as(usize, 1), summary.digest_artifacts.count);
    try std.testing.expectEqual(@as(u64, 8), summary.digest_artifacts.bytes);
    try std.testing.expectEqual(@as(u64, 14), summary.default_prunable_bytes);

    const dry_run = try pruneRootfsCache(allocator, io, root, .{ .max_bytes = 8 }, std.time.ns_per_s);
    try std.testing.expect(dry_run.dry_run);
    try std.testing.expectEqual(@as(usize, 1), dry_run.candidate_count);
    try std.testing.expectEqual(@as(u64, 6), dry_run.candidate_bytes);
    try std.testing.expectEqual(@as(u64, 6), dry_run.candidate_reclaimable_bytes);
    try std.testing.expectEqual(@as(u64, 14), dry_run.scope_bytes_before);
    try std.testing.expectEqual(@as(u64, 8), dry_run.scope_bytes_after);
    try std.testing.expect(try fileExists(io, root ++ "/a.ext4"));
    try std.testing.expect(try fileExists(io, root ++ "/by-digest/blake3/c.ext4"));

    const default_dry_run = try pruneRootfsCache(
        allocator,
        io,
        root,
        .{ .max_bytes = default_prune_max_bytes, .default_selection = true },
        std.time.ns_per_s,
    );
    try std.testing.expect(default_dry_run.default_selection);
    try std.testing.expectEqual(@as(usize, 2), default_dry_run.candidate_count);
    try std.testing.expectEqual(@as(u64, 14), default_dry_run.candidate_bytes);
    try std.testing.expectEqual(@as(u64, 14), default_dry_run.candidate_reclaimable_bytes);
    try std.testing.expectEqual(@as(u64, 0), default_dry_run.scope_bytes_after);
    try std.testing.expect(try fileExists(io, root ++ "/a.ext4"));
    try std.testing.expect(try fileExists(io, root ++ "/b.ext4"));
    try std.testing.expect(try fileExists(io, root ++ "/by-digest/blake3/c.ext4"));

    const forced = try pruneRootfsCache(allocator, io, root, .{ .dry_run = false, .max_bytes = 8 }, std.time.ns_per_s);
    try std.testing.expect(!forced.dry_run);
    try std.testing.expectEqual(@as(usize, 1), forced.deleted_count);
    try std.testing.expectEqual(@as(u64, 6), forced.deleted_bytes);
    try std.testing.expectEqual(@as(u64, 6), forced.deleted_reclaimable_bytes);
    try std.testing.expect(!try fileExists(io, root ++ "/a.ext4"));
    try std.testing.expect(!try fileExists(io, root ++ "/a.json"));
    try std.testing.expect(try fileExists(io, root ++ "/b.ext4"));
    try std.testing.expect(try fileExists(io, root ++ "/by-digest/blake3/c.ext4"));
}

fn fileExists(io: Io, path: []const u8) !bool {
    _ = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}
