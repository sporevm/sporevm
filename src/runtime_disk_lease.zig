//! Durable and process-owned authority records for live runtime disk baselines.

const std = @import("std");
const builtin = @import("builtin");

const runtime_disk_fork = @import("runtime_disk_fork.zig");
const spore = @import("spore.zig");

const Io = std.Io;

pub const schema = "spore.disk-baseline-lease.v1";
pub const active_dir_name = "leases";
const active_file_prefix = "runtime-";
const active_file_suffix = ".json";
const active_nonce_bytes = 16;
const max_active_lease_bytes = 64 * 1024;
const private_dir_permissions: Io.File.Permissions = if (builtin.os.tag == .windows)
    .default_dir
else
    @enumFromInt(0o700);

pub const OwnerPid = if (builtin.os.tag == .windows) i32 else std.posix.pid_t;

pub const Store = enum {
    rootfs_cache,
    saved_spore,
};

pub const Lease = struct {
    schema: []const u8 = schema,
    store: Store,
    /// Absolute root that owns the immutable baseline named below.
    root: []const u8,
    baseline_kind: runtime_disk_fork.BaselineKind,
    baseline_identity: []const u8,
    /// CAS descriptor needed to keep a cache-backed disk index and all of its
    /// objects rooted even after the source monitor and fork batch disappear.
    rootfs_storage: ?spore.RootfsStorage = null,

    pub fn validate(self: Lease) !void {
        if (!std.mem.eql(u8, self.schema, schema)) return error.BadManifest;
        if (self.root.len == 0 or !std.fs.path.isAbsolute(self.root)) return error.BadManifest;
        try spore.validateDiskDigest(self.baseline_identity);
        switch (self.store) {
            .rootfs_cache => switch (self.baseline_kind) {
                .rootfs => if (self.rootfs_storage != null) return error.BadManifest,
                .disk_index => {
                    const storage = self.rootfs_storage orelse return error.BadManifest;
                    try spore.validateRootfsStorageDescriptor(storage);
                    if (!std.mem.eql(u8, storage.index_digest, self.baseline_identity)) return error.BadManifest;
                },
            },
            .saved_spore => {
                if (self.baseline_kind != .disk_index or self.rootfs_storage != null) return error.BadManifest;
            },
        }
    }
};

/// A process-owned runtime root for lazy cache reads. The JSON payload is the
/// existing Lease value; owner identity lives in the filename so dead process
/// records can be ignored without trusting or parsing a partial write.
pub const Active = struct {
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,

    pub fn deinit(self: *Active) void {
        Io.Dir.cwd().deleteFile(self.io, self.path) catch {};
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

pub const ActiveIterator = struct {
    allocator: std.mem.Allocator,
    io: Io,
    dir_path: []const u8,
    dir: ?Io.Dir = null,
    iterator: ?Io.Dir.Iterator = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        runtime_root: []const u8,
    ) !ActiveIterator {
        const dir_path = try std.fs.path.resolve(allocator, &.{ runtime_root, active_dir_name });
        errdefer allocator.free(dir_path);
        const dir = Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return .{ .allocator = allocator, .io = io, .dir_path = dir_path },
            else => |e| return e,
        };
        return .{
            .allocator = allocator,
            .io = io,
            .dir_path = dir_path,
            .dir = dir,
            .iterator = dir.iterate(),
        };
    }

    pub fn deinit(self: *ActiveIterator) void {
        if (self.dir) |*dir| dir.close(self.io);
        self.allocator.free(self.dir_path);
        self.* = undefined;
    }

    pub fn next(self: *ActiveIterator) !?std.json.Parsed(Lease) {
        const iterator = if (self.iterator) |*value| value else return null;
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, active_file_suffix)) continue;
            const pid = activeOwnerPid(entry.name) orelse return error.BadManifest;
            if (!ownerAlive(pid)) continue;
            const path = try std.fs.path.join(self.allocator, &.{ self.dir_path, entry.name });
            defer self.allocator.free(path);
            const data = Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(max_active_lease_bytes)) catch |err| switch (err) {
                error.FileNotFound => continue,
                error.StreamTooLong => return error.BadManifest,
                else => |e| return e,
            };
            defer self.allocator.free(data);
            var parsed = std.json.parseFromSlice(Lease, self.allocator, data, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            }) catch return error.BadManifest;
            errdefer parsed.deinit();
            try parsed.value.validate();
            return parsed;
        }
        return null;
    }
};

pub fn acquireActive(
    io: Io,
    allocator: std.mem.Allocator,
    runtime_root: []const u8,
    lease: Lease,
) !Active {
    try lease.validate();
    try ensurePrivateDir(io, runtime_root);
    const active_dir = try std.fs.path.resolve(allocator, &.{ runtime_root, active_dir_name });
    defer allocator.free(active_dir);
    try ensurePrivateDir(io, active_dir);

    var nonce: [active_nonce_bytes]u8 = undefined;
    io.random(&nonce);
    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
    const file_name = try std.fmt.allocPrint(allocator, "{s}{d}-{s}{s}", .{
        active_file_prefix,
        std.c.getpid(),
        nonce_hex,
        active_file_suffix,
    });
    defer allocator.free(file_name);
    const path = try std.fs.path.resolve(allocator, &.{ active_dir, file_name });
    errdefer allocator.free(path);

    const json = try std.json.Stringify.valueAlloc(allocator, lease, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    var file = try Io.Dir.createFileAbsolute(io, path, .{
        .exclusive = true,
        .permissions = if (builtin.os.tag == .windows) .default_file else @enumFromInt(0o600),
    });
    errdefer Io.Dir.cwd().deleteFile(io, path) catch {};
    defer file.close(io);
    try file.writeStreamingAll(io, json);
    return .{ .allocator = allocator, .io = io, .path = path };
}

pub fn activeOwnerPid(file_name: []const u8) ?OwnerPid {
    if (!std.mem.startsWith(u8, file_name, active_file_prefix) or
        !std.mem.endsWith(u8, file_name, active_file_suffix)) return null;
    const body = file_name[active_file_prefix.len .. file_name.len - active_file_suffix.len];
    const separator = std.mem.lastIndexOfScalar(u8, body, '-') orelse return null;
    const pid_text = body[0..separator];
    const nonce = body[separator + 1 ..];
    if (nonce.len != active_nonce_bytes * 2) return null;
    for (nonce) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return null;
    }
    const pid = std.fmt.parseInt(OwnerPid, pid_text, 10) catch return null;
    return if (pid > 0) pid else null;
}

pub fn ownerAlive(pid: OwnerPid) bool {
    if (pid <= 0 or comptime builtin.os.tag == .windows) return false;
    std.posix.kill(pid, @enumFromInt(0)) catch |err| return err == error.PermissionDenied;
    return true;
}

fn ensurePrivateDir(io: Io, path: []const u8) !void {
    try ensureDirPath(io, path);
    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .directory) return error.InvalidRuntimeDir;
    if (comptime builtin.os.tag != .windows) {
        const mode = @intFromEnum(stat.permissions);
        if (mode & 0o077 != 0) return error.InsecureRuntimeDir;
    }
}

fn ensureDirPath(io: Io, path: []const u8) !void {
    if (!Io.Dir.path.isAbsolute(path)) {
        _ = try Io.Dir.cwd().createDirPathStatus(io, path, private_dir_permissions);
        return;
    }
    var existing = Io.Dir.openDirAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (std.fs.path.dirname(path)) |parent| {
                if (parent.len > 0 and !std.mem.eql(u8, parent, path)) try ensureDirPath(io, parent);
            }
            Io.Dir.createDirAbsolute(io, path, private_dir_permissions) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => {},
                else => |e| return e,
            };
            return;
        },
        else => |e| return e,
    };
    existing.close(io);
}

pub fn fromSavedDisk(root: []const u8, disk: spore.Disk) !Lease {
    if (!std.mem.eql(u8, disk.kind, spore.disk_kind_chunk_index) or disk.layers.len != 0) return error.BadManifest;
    const lease = Lease{
        .store = .saved_spore,
        .root = root,
        .baseline_kind = .disk_index,
        .baseline_identity = disk.base,
    };
    try lease.validate();
    return lease;
}

test "disk baseline lease binds its authority and storage descriptor" {
    const storage = spore.RootfsStorage{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = .{ .mmio_slot = 1 },
        .logical_size = spore.disk_chunk_size,
        .chunk_size = spore.disk_chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .index_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .base_identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .object_namespace = spore.rootfs_storage_object_namespace,
    };
    try (Lease{
        .store = .rootfs_cache,
        .root = "/cache",
        .baseline_kind = .disk_index,
        .baseline_identity = storage.index_digest,
        .rootfs_storage = storage,
    }).validate();
    try std.testing.expectError(error.BadManifest, (Lease{
        .store = .rootfs_cache,
        .root = "relative",
        .baseline_kind = .rootfs,
        .baseline_identity = storage.index_digest,
    }).validate());
}

test "active lease records reuse Lease JSON and release on teardown" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_root);
    const runtime_root = try std.fs.path.join(allocator, &.{ tmp_root, "runtime" });
    defer allocator.free(runtime_root);
    const lease = Lease{
        .store = .rootfs_cache,
        .root = "/cache",
        .baseline_kind = .rootfs,
        .baseline_identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };

    var active = try acquireActive(io, allocator, runtime_root, lease);
    const active_path = try allocator.dupe(u8, active.path);
    defer allocator.free(active_path);
    try std.testing.expectEqual(@as(OwnerPid, std.c.getpid()), activeOwnerPid(std.fs.path.basename(active.path)).?);
    try std.testing.expect(ownerAlive(activeOwnerPid(std.fs.path.basename(active.path)).?));
    const data = try Io.Dir.cwd().readFileAlloc(io, active.path, allocator, .limited(4096));
    defer allocator.free(data);
    var parsed = try std.json.parseFromSlice(Lease, allocator, data, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try parsed.value.validate();
    try std.testing.expectEqualStrings(lease.baseline_identity, parsed.value.baseline_identity);

    active.deinit();
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, active_path, .{ .follow_symlinks = false }));
}

test "active lease owner parsing rejects out-of-range pids" {
    try std.testing.expect(activeOwnerPid("runtime-999999999999999999999999-0123456789abcdef0123456789abcdef.json") == null);
}
