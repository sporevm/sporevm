//! Host-private durable roots for machine-local saved-spore disk state.

const std = @import("std");
const builtin = @import("builtin");
const chunk_sealer = @import("chunk_sealer.zig");
const disk_index = @import("disk_index.zig");
const rootfs_mod = @import("rootfs.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const spore = @import("spore.zig");
const test_barrier = @import("test_barrier.zig");

const Io = std.Io;
pub const schema = "spore.saved-disk-pin.v3";
/// Pins written by earlier builds. Their saves no longer restore, so GC
/// deletes them.
const old_schemas = [_][]const u8{ "spore.saved-disk-pin.v1", "spore.saved-disk-pin.v2" };
pub const reference_schema = "spore.saved-disk-pin-ref.v3";
/// A save keeps its reference after GC deletes the old record it named, so
/// the reference alone shows that the save is too old.
const old_reference_schemas = [_][]const u8{ "spore.saved-disk-pin-ref.v1", "spore.saved-disk-pin-ref.v2" };
pub const dir_name = "pins";
pub const reference_file = "sporevm-disk-pin.json";
pub const owner_suffix = ".owner";
pub const max_record_bytes = 64 * 1024;
pub const id_bytes = 32;

pub const PendingPublication = struct {
    spore_dir: []const u8,
    reference_path: []const u8,
    cleanup_root: ?[]const u8 = null,

    fn validate(self: PendingPublication) !void {
        if (!isAbsoluteSafePath(self.spore_dir) or
            !isAbsoluteSafePath(self.reference_path) or
            !std.mem.eql(u8, std.fs.path.basename(self.reference_path), reference_file)) return error.BadManifest;
        if (self.cleanup_root) |cleanup_root| {
            if (!validGeneratedStageRoot(cleanup_root) or !pathIsWithin(self.reference_path, cleanup_root)) return error.BadManifest;
        }
    }
};

pub const Record = struct {
    schema: []const u8,
    id: []const u8,
    storage: spore.RootfsStorage,
    /// Set until the save holding the reference is durably visible.
    pending: ?PendingPublication = null,

    pub fn validate(self: Record) !void {
        if (!std.mem.eql(u8, self.schema, schema) or !validId(self.id)) return error.BadManifest;
        if (self.pending) |pending| try pending.validate();
        try spore.validateRootfsStorageDescriptor(self.storage);
    }
};

pub const Reference = struct {
    schema: []const u8,
    id: []const u8,

    pub fn validate(self: Reference) !void {
        if (!std.mem.eql(u8, self.schema, reference_schema) or !validId(self.id)) return error.BadManifest;
    }
};

pub const ListingState = enum { index_valid, corrupt, missing, stale };
pub const Listing = struct { id: []const u8, state: ListingState, owner_state: OwnerState = .invalid, index_digest: ?[]const u8 = null };
pub const ListStats = struct { index_validation_count: usize = 0 };

const PublishCrashBoundary = enum {
    none,
    staged_manifest,
    complete_stamp,
    pin_record,
    reference_rename,
    manifest_rename,
    directory_sync,
};

const PublishTestFault = struct {
    fail_before_complete_stamp: bool = false,
    crash_after: PublishCrashBoundary = .none,
};
pub const testing = if (builtin.is_test) struct {
    pub var publish_fault: PublishTestFault = .{};
    pub var remove_mutation_barrier: ?*test_barrier.Barrier = null;
    pub var publish_authority_barrier: ?*test_barrier.Barrier = null;

    /// Pins an existing save directory as a committed save would be.
    pub fn pinSave(io: Io, allocator: std.mem.Allocator, registry: LockedRegistry, spore_dir: []const u8, disk: spore.Disk) ![]const u8 {
        const storage = try storageForDisk(disk);
        try validateRoot(allocator, registry.cache_root, storage);
        const dir = try Io.Dir.cwd().realPathFileAlloc(io, spore_dir, allocator);
        defer allocator.free(dir);
        const reference_path = try std.fs.path.join(allocator, &.{ dir, reference_file });
        defer allocator.free(reference_path);
        const id = try acquire(io, allocator, registry, storage, .{ .spore_dir = dir, .reference_path = reference_path });
        errdefer allocator.free(id);
        try syncRegistry(allocator, registry);
        try clearPendingPublication(io, allocator, registry, id);
        return id;
    }
} else struct {};

fn crashAfterPublishBoundary(boundary: PublishCrashBoundary) void {
    if (comptime builtin.is_test) if (testing.publish_fault.crash_after == boundary) std.process.exit(86);
}

/// Proof that the caller owns the lock serializing pin mutation and GC for
/// this exact cache root. Construct once per critical section and pass the
/// capability to every mutating or crash-reconciling operation.
pub const LockedRegistry = struct {
    cache_root: []const u8,

    pub fn init(allocator: std.mem.Allocator, cache_root: []const u8, lock: *const rootfs_mod.RootfsCacheLock) !LockedRegistry {
        if (!try lock.ensureHeldFor(allocator, cache_root)) return error.RootfsCacheLockNotHeld;
        return .{ .cache_root = cache_root };
    }
};

pub fn list(io: Io, allocator: std.mem.Allocator, cache_root: []const u8) ![]Listing {
    return listWithStats(io, allocator, cache_root, null);
}

pub fn listWithStats(io: Io, allocator: std.mem.Allocator, cache_root: []const u8, stats: ?*ListStats) ![]Listing {
    const CachedRoot = struct { storage: spore.RootfsStorage, state: ListingState };
    var out = std.array_list.Managed(Listing).init(allocator);
    errdefer {
        for (out.items) |entry| {
            allocator.free(entry.id);
            if (entry.index_digest) |digest| allocator.free(digest);
        }
        out.deinit();
    }
    var roots = std.StringHashMap(CachedRoot).init(allocator);
    defer {
        var values = roots.valueIterator();
        while (values.next()) |value| deinitClonedStorage(allocator, value.storage);
        roots.deinit();
    }
    const pins_path = try std.fs.path.join(allocator, &.{ cache_root, dir_name });
    defer allocator.free(pins_path);
    var dir = Io.Dir.cwd().openDir(io, pins_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return out.toOwnedSlice(),
        else => |e| return e,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const raw_id = entry.name[0 .. entry.name.len - 5];
        const id = try allocator.dupe(u8, raw_id);
        errdefer allocator.free(id);
        var listing = Listing{ .id = id, .state = .corrupt };
        errdefer if (listing.index_digest) |digest| allocator.free(digest);
        if (validId(id)) {
            if (loadRecord(io, allocator, cache_root, id)) |parsed_value| {
                var parsed = parsed_value;
                defer parsed.deinit();
                listing.owner_state = ownerState(allocator, cache_root, id, parsed.value) catch |err| switch (err) {
                    error.BadManifest => .invalid,
                    else => |e| return e,
                };
                if (roots.get(parsed.value.storage.index_digest)) |cached| {
                    listing.state = if (spore.rootfsStorageEql(cached.storage, parsed.value.storage)) cached.state else .corrupt;
                } else {
                    if (stats) |value| value.index_validation_count += 1;
                    const state: ListingState = if (validateRoot(allocator, cache_root, parsed.value.storage))
                        .index_valid
                    else |err| switch (err) {
                        error.MissingChunk => .missing,
                        else => .corrupt,
                    };
                    const cloned = try spore.cloneRootfsStorage(allocator, parsed.value.storage);
                    errdefer deinitClonedStorage(allocator, cloned);
                    try roots.put(cloned.index_digest, .{ .storage = cloned, .state = state });
                    listing.state = state;
                }
                listing.index_digest = try allocator.dupe(u8, parsed.value.storage.index_digest);
            } else |err| switch (err) {
                error.FileNotFound => listing.state = .missing,
                error.FormatTooOld => listing.state = .stale,
                else => {},
            }
        }
        try out.append(listing);
    }
    std.mem.sort(Listing, out.items, {}, struct {
        fn less(_: void, a: Listing, b: Listing) bool {
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.less);
    return out.toOwnedSlice();
}

fn deinitClonedStorage(allocator: std.mem.Allocator, storage: spore.RootfsStorage) void {
    allocator.free(storage.kind);
    allocator.free(storage.device.kind);
    allocator.free(storage.device.role);
    allocator.free(storage.hash_algorithm);
    allocator.free(storage.index_digest);
    allocator.free(storage.base_identity);
    allocator.free(storage.object_namespace);
}

pub fn deinitListings(allocator: std.mem.Allocator, listings: []Listing) void {
    for (listings) |entry| {
        allocator.free(entry.id);
        if (entry.index_digest) |digest| allocator.free(digest);
    }
    allocator.free(listings);
}

/// Caller holds the rootfs cache lock and has made any associated save path
/// unreachable first. This also supports reclaiming pins orphaned by raw rm.
pub fn remove(io: Io, allocator: std.mem.Allocator, registry: LockedRegistry, id: []const u8) !void {
    const path = try recordPath(allocator, registry.cache_root, id);
    defer allocator.free(path);
    if (comptime builtin.is_test) if (testing.remove_mutation_barrier) |barrier| barrier.pause(io);
    const owner = try ownerPath(allocator, registry.cache_root, id);
    defer allocator.free(owner);
    Io.Dir.cwd().deleteFile(io, owner) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    const pins_path = try std.fs.path.join(allocator, &.{ registry.cache_root, dir_name });
    defer allocator.free(pins_path);
    try chunk_sealer.fsyncDirPath(allocator, pins_path);
    try Io.Dir.cwd().deleteFile(io, path);
    try chunk_sealer.fsyncDirPath(allocator, pins_path);
}

pub fn storageForDisk(disk: spore.Disk) !spore.RootfsStorage {
    if (!std.mem.eql(u8, disk.kind, spore.disk_kind_chunk_index)) return error.BadManifest;
    const storage = spore.RootfsStorage{
        .kind = spore.rootfs_storage_kind_chunked_ext4,
        .device = disk.device,
        .logical_size = disk.size,
        .chunk_size = disk.chunk_size,
        .hash_algorithm = disk.hash_algorithm,
        .index_digest = disk.base,
        .base_identity = disk.base,
        .object_namespace = disk.object_namespace,
    };
    try spore.validateRootfsStorageDescriptor(storage);
    return storage;
}

/// Returns whether the saved spore carries its authoritative disk index
/// locally. Portable/local-CAS spores remain self-contained even if a copied
/// or stale host-private pin reference is present.
pub fn hasLocalIndex(io: Io, allocator: std.mem.Allocator, spore_dir: []const u8, disk: spore.Disk) !bool {
    const storage = try storageForDisk(disk);
    const index_path = try rootfs_cas.manifestIndexPath(allocator, spore_dir, storage.index_digest);
    defer allocator.free(index_path);
    if (Io.Dir.cwd().statFile(io, index_path, .{ .follow_symlinks = false })) |stat| {
        if (stat.kind != .file) return error.BadManifest;
        return true;
    } else |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    }
}

/// Refuse a machine-local save before guest execution when its reference
/// cannot be hard-linked to the cache-side owner anchor.
pub fn ensureOwnershipLinkCompatible(allocator: std.mem.Allocator, cache_root: []const u8, spore_dir: []const u8) !void {
    const cache_identity = try statDirectoryNoFollow(allocator, cache_root);
    const spore_identity = statDirectoryNoFollow(allocator, spore_dir) catch |err| switch (err) {
        error.FileNotFound => try statDirectoryNoFollow(allocator, std.fs.path.dirname(spore_dir) orelse "."),
        else => |e| return e,
    };
    if (cache_identity.device != spore_identity.device) return error.CrossDeviceOwnershipLink;
}

/// Publish the host-private pin/reference before making manifest.json visible.
/// The caller holds the rootfs cache lock and has already made the CAS root
/// durable. Failure may leave a safe orphan pin, never an unrooted manifest.
pub fn publishManifest(io: Io, allocator: std.mem.Allocator, registry: LockedRegistry, spore_dir: []const u8, disk: spore.Disk, manifest: spore.Manifest) !void {
    const stage = try std.fs.path.join(allocator, &.{ spore_dir, ".sporevm-pin-stage" });
    defer allocator.free(stage);
    try createDirectoryExclusive(allocator, stage);
    var cleanup_stage = true;
    defer if (cleanup_stage) Io.Dir.cwd().deleteTree(io, stage) catch {};
    const final_ref = try std.fs.path.join(allocator, &.{ spore_dir, reference_file });
    defer allocator.free(final_ref);
    const final_manifest = try std.fs.path.join(allocator, &.{ spore_dir, "manifest.json" });
    defer allocator.free(final_manifest);
    try requireAbsent(io, final_ref);
    try requireAbsent(io, final_manifest);
    // From this point a failed publication leaves recovery material in the
    // stage directory. The preflight above cleans its empty stage on refusal.
    cleanup_stage = false;
    const manifest_bytes = try spore.encodeManifestAlloc(allocator, manifest);
    defer allocator.free(manifest_bytes);
    if (manifest_bytes.len > spore.max_manifest_bytes) return error.StreamTooLong;
    const staged_manifest = try std.fs.path.join(allocator, &.{ stage, "manifest.json" });
    defer allocator.free(staged_manifest);
    try chunk_sealer.replaceFileAtomicDurable(allocator, staged_manifest, manifest_bytes, 0o644);
    crashAfterPublishBoundary(.staged_manifest);
    const storage = try storageForDisk(disk);
    try validateRoot(allocator, registry.cache_root, storage);
    if (comptime builtin.is_test) if (testing.publish_authority_barrier) |barrier| barrier.pause(io);
    // Snapshot sealing durably publishes every object before the canonical
    // index. Publish the derived completeness proof next, before the pin and
    // save path can become visible, so restore and named fast-fork agree on
    // the same bound global-CAS authority.
    if (comptime builtin.is_test) if (testing.publish_fault.fail_before_complete_stamp) return error.InjectedFailure;
    try rootfs_cas.markStorageComplete(io, allocator, registry.cache_root, storage.index_digest);
    crashAfterPublishBoundary(.complete_stamp);
    const staged_ref = try std.fs.path.join(allocator, &.{ stage, reference_file });
    defer allocator.free(staged_ref);
    const id = try acquire(io, allocator, registry, storage, .{ .spore_dir = spore_dir, .reference_path = staged_ref });
    defer allocator.free(id);
    try syncRegistry(allocator, registry);
    crashAfterPublishBoundary(.pin_record);
    try Io.Dir.renameAbsolute(staged_ref, final_ref, io);
    crashAfterPublishBoundary(.reference_rename);
    try Io.Dir.renameAbsolute(staged_manifest, final_manifest, io);
    crashAfterPublishBoundary(.manifest_rename);
    try chunk_sealer.fsyncDirPath(allocator, spore_dir);
    crashAfterPublishBoundary(.directory_sync);
    try clearPendingPublication(io, allocator, registry, id);
    cleanup_stage = true;
}

fn requireAbsent(io: Io, path: []const u8) !void {
    _ = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    return error.SavedSporeOwnershipConflict;
}

/// Creates a pending pin rooting `storage` and hard-links its reference at
/// `pending.reference_path`, in a save that is not visible yet. The caller
/// holds the cache lock and has validated the storage root. It calls
/// `syncRegistry` before making the save visible and
/// `clearPendingPublication` once the save is durable.
pub fn acquire(io: Io, allocator: std.mem.Allocator, registry: LockedRegistry, storage: spore.RootfsStorage, pending: PendingPublication) ![]const u8 {
    var random: [id_bytes]u8 = undefined;
    io.random(&random);
    const id_array = std.fmt.bytesToHex(random, .lower);
    const id = try allocator.dupe(u8, &id_array);
    errdefer allocator.free(id);
    const record_json = try encodeRecord(allocator, .{ .schema = schema, .id = id, .storage = storage, .pending = pending });
    defer allocator.free(record_json);
    try ensureRegistryDurable(allocator, registry);
    const record_path = try recordPath(allocator, registry.cache_root, id);
    defer allocator.free(record_path);
    try createFileExclusiveDurable(allocator, record_path, record_json, 0o600);
    errdefer unlinkPath(allocator, record_path);
    const owner_path = try ownerPath(allocator, registry.cache_root, id);
    defer allocator.free(owner_path);
    const ref_json = try std.json.Stringify.valueAlloc(allocator, Reference{ .schema = reference_schema, .id = id }, .{ .whitespace = .indent_2 });
    defer allocator.free(ref_json);
    try createFileExclusiveDurable(allocator, owner_path, ref_json, 0o600);
    errdefer unlinkPath(allocator, owner_path);
    hardLink(allocator, owner_path, pending.reference_path) catch |err| return switch (err) {
        error.PathAlreadyExists => error.SavedSporeOwnershipConflict,
        else => |e| e,
    };
    try chunk_sealer.fsyncDirPath(allocator, std.fs.path.dirname(pending.reference_path).?);
    return id;
}

/// Makes the records created by `acquire` durable. Call once per batch.
pub fn syncRegistry(allocator: std.mem.Allocator, registry: LockedRegistry) !void {
    const pins_dir = try std.fs.path.join(allocator, &.{ registry.cache_root, dir_name });
    defer allocator.free(pins_dir);
    try chunk_sealer.fsyncDirPath(allocator, pins_dir);
}

fn ensureRegistryDurable(allocator: std.mem.Allocator, registry: LockedRegistry) !void {
    const pins_dir = try std.fs.path.join(allocator, &.{ registry.cache_root, dir_name });
    defer allocator.free(pins_dir);
    const pins_dir_z = try allocator.dupeZ(u8, pins_dir);
    defer allocator.free(pins_dir_z);
    const created_registry = if (std.c.mkdir(pins_dir_z.ptr, 0o700) == 0)
        true
    else switch (std.c.errno(-1)) {
        .EXIST => blk: {
            try chunk_sealer.ensureDirPath(allocator, pins_dir);
            break :blk false;
        },
        else => return error.IoFailed,
    };
    if (created_registry) try chunk_sealer.fsyncDirPath(allocator, registry.cache_root);
}

/// Mark a staged pin publication committed after the final artifact path and
/// its parent-directory entry are durable.
pub fn clearPendingPublication(io: Io, allocator: std.mem.Allocator, registry: LockedRegistry, id: []const u8) !void {
    var record = try loadRecord(io, allocator, registry.cache_root, id);
    defer record.deinit();
    if (record.value.pending == null) return;
    record.value.pending = null;
    try replaceRecord(allocator, registry, record.value);
}

/// Validate a saved-spore pin. The caller must hold the rootfs cache lock
/// because a load commits a pin left pending by a crash.
pub fn loadForSporeLocked(io: Io, allocator: std.mem.Allocator, registry: LockedRegistry, spore_dir: []const u8, disk: spore.Disk) !std.json.Parsed(Record) {
    const ref_path = try std.fs.path.join(allocator, &.{ spore_dir, reference_file });
    defer allocator.free(ref_path);
    const ref_bytes = try Io.Dir.cwd().readFileAlloc(io, ref_path, allocator, .limited(max_record_bytes));
    defer allocator.free(ref_bytes);
    var ref = std.json.parseFromSlice(Reference, allocator, ref_bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = false }) catch return error.BadManifest;
    defer ref.deinit();
    if (isOneOf(&old_reference_schemas, ref.value.schema)) return error.FormatTooOld;
    try ref.value.validate();
    var record = try loadRecord(io, allocator, registry.cache_root, ref.value.id);
    errdefer record.deinit();
    try validateExclusiveOwner(allocator, registry.cache_root, spore_dir, ref.value.id);
    const expected = try storageForDisk(disk);
    if (!spore.rootfsStorageEql(record.value.storage, expected)) return error.BadManifest;
    // Never change the record before proving the canonical root is intact.
    // Missing/corrupt roots leave the record byte-for-byte unchanged.
    try validateRoot(allocator, registry.cache_root, record.value.storage);
    if (record.value.pending != null) {
        record.value.pending = null;
        try replaceRecord(allocator, registry, record.value);
    }
    return record;
}

pub const OwnerState = enum { exclusive, pending, orphaned, duplicated, invalid };

pub fn ownerState(allocator: std.mem.Allocator, cache_root: []const u8, id: []const u8, record: Record) !OwnerState {
    if (record.pending != null) return .pending;
    const owner = try ownerPath(allocator, cache_root, id);
    defer allocator.free(owner);
    const stat = statRegularNoFollow(allocator, owner) catch |err| return switch (err) {
        error.FileNotFound => .orphaned,
        else => |e| e,
    };
    return switch (stat.nlink) {
        1 => .orphaned,
        2 => .exclusive,
        else => .duplicated,
    };
}

pub const PendingPublicationState = enum { none, committed, abandoned, unresolved };

/// Diagnose a pin whose reference was published before the artifact's final
/// directory rename. The cache lock makes a still-pending record evidence of
/// a crashed publisher rather than an in-flight one.
pub fn pendingPublicationState(io: Io, allocator: std.mem.Allocator, cache_root: []const u8, id: []const u8, record: Record) !PendingPublicationState {
    const pending = record.pending orelse return .none;
    const final_dir = pending.spore_dir;
    const pending_ref = pending.reference_path;
    const owner = try ownerPath(allocator, cache_root, id);
    defer allocator.free(owner);
    const owner_identity = statRegularNoFollow(allocator, owner) catch |err| return switch (err) {
        error.FileNotFound => .abandoned,
        else => |e| e,
    };
    const final_ref = try std.fs.path.join(allocator, &.{ final_dir, reference_file });
    defer allocator.free(final_ref);
    switch (try pathIdentityMatch(allocator, final_ref, owner_identity)) {
        .matches => {
            const manifest_path = try std.fs.path.join(allocator, &.{ final_dir, "manifest.json" });
            defer allocator.free(manifest_path);
            // The manifest rename follows the reference rename, and
            // publication refuses to start over an existing manifest.
            const stat = Io.Dir.cwd().statFile(io, manifest_path, .{ .follow_symlinks = false }) catch |err| return switch (err) {
                error.FileNotFound => .abandoned,
                else => .unresolved,
            };
            return if (stat.kind == .file) .committed else .unresolved;
        },
        .other => return .unresolved,
        .missing => {},
    }
    return switch (try pathIdentityMatch(allocator, pending_ref, owner_identity)) {
        .matches => .abandoned,
        .other => .unresolved,
        .missing => if (owner_identity.nlink == 1) .abandoned else .unresolved,
    };
}

/// Drop only reference paths proven to be links to this pending pin. The
/// caller may then remove the owner and record with `remove`.
pub fn abandonPendingPublication(io: Io, allocator: std.mem.Allocator, cache_root: []const u8, id: []const u8, record: Record) !void {
    if (try pendingPublicationState(io, allocator, cache_root, id, record) != .abandoned) return error.SavedSporeOwnershipConflict;
    const pending = record.pending orelse return error.BadManifest;
    if (pending.cleanup_root) |cleanup_root| {
        try Io.Dir.cwd().deleteTree(io, cleanup_root);
        try chunk_sealer.fsyncDirPath(allocator, std.fs.path.dirname(cleanup_root) orelse ".");
    }
    const owner = try ownerPath(allocator, cache_root, id);
    defer allocator.free(owner);
    const owner_identity = statRegularNoFollow(allocator, owner) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    const final_ref = try std.fs.path.join(allocator, &.{ pending.spore_dir, reference_file });
    defer allocator.free(final_ref);
    for ([_][]const u8{ pending.reference_path, final_ref }) |path| {
        if (try pathIdentityMatch(allocator, path, owner_identity) != .matches) continue;
        try Io.Dir.cwd().deleteFile(io, path);
        try chunk_sealer.fsyncDirPath(allocator, std.fs.path.dirname(path) orelse ".");
    }
}

const PathIdentityMatch = enum { missing, matches, other };

fn pathIdentityMatch(allocator: std.mem.Allocator, path: []const u8, expected: FileIdentity) !PathIdentityMatch {
    const actual = statRegularNoFollow(allocator, path) catch |err| return switch (err) {
        error.FileNotFound => .missing,
        error.BadManifest => .other,
        else => |e| e,
    };
    return if (actual.device == expected.device and actual.inode == expected.inode) .matches else .other;
}

fn validateExclusiveOwner(allocator: std.mem.Allocator, cache_root: []const u8, spore_dir: []const u8, id: []const u8) !void {
    const owner = try ownerPath(allocator, cache_root, id);
    defer allocator.free(owner);
    const reference = try std.fs.path.join(allocator, &.{ spore_dir, reference_file });
    defer allocator.free(reference);
    const owner_stat = try statRegularNoFollow(allocator, owner);
    const ref_stat = try statRegularNoFollow(allocator, reference);
    if (owner_stat.device != ref_stat.device or owner_stat.inode != ref_stat.inode or owner_stat.nlink != 2 or ref_stat.nlink != 2) {
        return error.SavedSporeOwnershipConflict;
    }
}

const FileIdentity = struct { device: u64, inode: u64, nlink: u64 };

fn statDirectoryNoFollow(allocator: std.mem.Allocator, path: []const u8) !FileIdentity {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    return statPathNoFollow(path_z, .directory);
}

fn statRegularNoFollow(allocator: std.mem.Allocator, path: []const u8) !FileIdentity {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    return statPathNoFollow(path_z, .file);
}

fn statPathNoFollow(path: [:0]const u8, expected: std.Io.File.Kind) !FileIdentity {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var stat: linux.Statx = undefined;
        const rc = linux.statx(std.c.AT.FDCWD, path, std.c.AT.SYMLINK_NOFOLLOW, .{
            .TYPE = true,
            .MODE = true,
            .INO = true,
            .NLINK = true,
        }, &stat);
        const result = linux.errno(rc);
        if (result != .SUCCESS) return switch (result) {
            .NOENT, .NOTDIR => error.FileNotFound,
            else => error.IoFailed,
        };
        if (!stat.mask.TYPE or !stat.mask.MODE or !stat.mask.INO or !stat.mask.NLINK) return error.IoFailed;
        const matches = switch (expected) {
            .directory => linux.S.ISDIR(stat.mode),
            .file => linux.S.ISREG(stat.mode),
            else => unreachable,
        };
        if (!matches) return error.BadManifest;
        return .{
            .device = (@as(u64, stat.dev_major) << 32) | stat.dev_minor,
            .inode = stat.ino,
            .nlink = stat.nlink,
        };
    } else {
        var stat: std.c.Stat = undefined;
        const rc = std.c.fstatat(std.c.AT.FDCWD, path, &stat, std.c.AT.SYMLINK_NOFOLLOW);
        if (rc != 0) return switch (std.c.errno(rc)) {
            .NOENT, .NOTDIR => error.FileNotFound,
            else => error.IoFailed,
        };
        const matches = switch (expected) {
            .directory => std.c.S.ISDIR(stat.mode),
            .file => std.c.S.ISREG(stat.mode),
            else => unreachable,
        };
        if (!matches) return error.BadManifest;
        return .{ .device = @intCast(stat.dev), .inode = @intCast(stat.ino), .nlink = @intCast(stat.nlink) };
    }
}

fn hardLink(allocator: std.mem.Allocator, source: []const u8, destination: []const u8) !void {
    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);
    const destination_z = try allocator.dupeZ(u8, destination);
    defer allocator.free(destination_z);
    if (std.c.link(source_z.ptr, destination_z.ptr) != 0) return switch (std.c.errno(-1)) {
        .EXIST => error.PathAlreadyExists,
        .XDEV => error.CrossDeviceOwnershipLink,
        else => error.IoFailed,
    };
}

fn unlinkPath(allocator: std.mem.Allocator, path: []const u8) void {
    const path_z = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(path_z);
    _ = std.c.unlink(path_z.ptr);
}

pub fn loadRecord(io: Io, allocator: std.mem.Allocator, cache_root: []const u8, id: []const u8) !std.json.Parsed(Record) {
    if (!validId(id)) return error.BadManifest;
    const path = try recordPath(allocator, cache_root, id);
    defer allocator.free(path);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_record_bytes));
    defer allocator.free(bytes);
    return parseRecord(allocator, bytes, id);
}

/// Checks the schema before the shape, so an older record fails as too old
/// whatever fields it carries.
fn parseRecord(allocator: std.mem.Allocator, bytes: []const u8, id: []const u8) !std.json.Parsed(Record) {
    const SchemaProbe = struct { schema: []const u8 };
    const probe = std.json.parseFromSlice(SchemaProbe, allocator, bytes, .{ .ignore_unknown_fields = true }) catch return error.BadManifest;
    const too_old = isOneOf(&old_schemas, probe.value.schema);
    probe.deinit();
    if (too_old) return error.FormatTooOld;
    var parsed = std.json.parseFromSlice(Record, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = false }) catch return error.BadManifest;
    errdefer parsed.deinit();
    try parsed.value.validate();
    if (!std.mem.eql(u8, parsed.value.id, id)) return error.BadManifest;
    return parsed;
}

pub fn validateRoot(allocator: std.mem.Allocator, cache_root: []const u8, storage: spore.RootfsStorage) !void {
    const index_path = try rootfs_cas.manifestIndexPath(allocator, cache_root, storage.index_digest);
    defer allocator.free(index_path);
    try rootfs_cas.verifyStorageIndexPath(allocator, index_path, storage);
}

pub fn recordPath(allocator: std.mem.Allocator, cache_root: []const u8, id: []const u8) ![]const u8 {
    if (!validId(id)) return error.BadManifest;
    const name = try std.fmt.allocPrint(allocator, "{s}.json", .{id});
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ cache_root, dir_name, name });
}

pub fn ownerPath(allocator: std.mem.Allocator, cache_root: []const u8, id: []const u8) ![]const u8 {
    if (!validId(id)) return error.BadManifest;
    const name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ id, owner_suffix });
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ cache_root, dir_name, name });
}

pub fn validId(value: []const u8) bool {
    if (value.len != id_bytes * 2) return false;
    for (value) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

fn isAbsoluteSafePath(path: []const u8) bool {
    return path.len != 0 and std.fs.path.isAbsolute(path) and std.mem.indexOfScalar(u8, path, 0) == null;
}

fn validGeneratedStageRoot(path: []const u8) bool {
    if (!isAbsoluteSafePath(path)) return false;
    const marker = ".pin-stage-";
    const base = std.fs.path.basename(path);
    const marker_index = std.mem.lastIndexOf(u8, base, marker) orelse return false;
    const nonce = base[marker_index + marker.len ..];
    if (nonce.len == 0 or nonce.len > 16) return false;
    for (nonce) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

fn pathIsWithin(path: []const u8, root: []const u8) bool {
    return path.len > root.len and std.mem.startsWith(u8, path, root) and std.fs.path.isSep(path[root.len]);
}

pub fn validRecordTempName(name: []const u8) bool {
    const marker = ".json.";
    const suffix = ".tmp";
    if (name.len <= id_bytes * 2 + marker.len + suffix.len) return false;
    if (!validId(name[0 .. id_bytes * 2])) return false;
    if (!std.mem.eql(u8, name[id_bytes * 2 ..][0..marker.len], marker) or !std.mem.endsWith(u8, name, suffix)) return false;
    const nonce = name[id_bytes * 2 + marker.len .. name.len - suffix.len];
    if (nonce.len == 0 or nonce.len > 16) return false;
    for (nonce) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

pub fn validOwnerName(name: []const u8) bool {
    return name.len == id_bytes * 2 + owner_suffix.len and
        std.mem.endsWith(u8, name, owner_suffix) and
        validId(name[0 .. id_bytes * 2]);
}

fn isOneOf(values: []const []const u8, value: []const u8) bool {
    for (values) |candidate| if (std.mem.eql(u8, candidate, value)) return true;
    return false;
}

fn encodeRecord(allocator: std.mem.Allocator, record: Record) ![]u8 {
    try record.validate();
    return std.json.Stringify.valueAlloc(allocator, record, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
}

fn replaceRecord(allocator: std.mem.Allocator, registry: LockedRegistry, record: Record) !void {
    const json = try encodeRecord(allocator, record);
    defer allocator.free(json);
    const path = try recordPath(allocator, registry.cache_root, record.id);
    defer allocator.free(path);
    try chunk_sealer.replaceFileAtomicDurable(allocator, path, json, 0o600);
}

/// Creates and fsyncs `path`; the caller syncs its directory.
fn createFileExclusiveDurable(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8, mode: c_uint) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, mode);
    if (fd < 0) return switch (std.c.errno(fd)) {
        .EXIST => error.PathAlreadyExists,
        else => error.IoFailed,
    };
    errdefer _ = std.c.unlink(path_z.ptr);
    defer _ = std.c.close(fd);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const wrote = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (wrote <= 0) return error.IoFailed;
        offset += @intCast(wrote);
    }
    if (std.c.fsync(fd) != 0) return error.IoFailed;
}

fn createDirectoryExclusive(allocator: std.mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (std.c.mkdir(path_z.ptr, 0o700) == 0) return;
    return switch (std.c.errno(-1)) {
        .EXIST => error.SavedSporePublicationRecoveryRequired,
        else => error.IoFailed,
    };
}

test "locked pin registry binds the exact held cache lock" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const other = try std.fs.path.join(allocator, &.{ root, "other" });
    defer allocator.free(other);
    try Io.Dir.cwd().createDirPath(io, other);
    var lock = try rootfs_mod.lockRootfsCacheExclusive(io, allocator, root);
    _ = try LockedRegistry.init(allocator, root, &lock);
    try std.testing.expectError(error.RootfsCacheLockNotHeld, LockedRegistry.init(allocator, other, &lock));
    lock.deinit();
    try std.testing.expectError(error.RootfsCacheLockNotHeld, LockedRegistry.init(allocator, root, &lock));
}

test "saved spore pin ids are strict lowercase hex" {
    try std.testing.expect(validId("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try std.testing.expect(!validId("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"));
    try std.testing.expect(!validId("aa"));
    try std.testing.expect(validRecordTempName("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json.1af.tmp"));
    try std.testing.expect(!validRecordTempName("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json.tmp"));
    try std.testing.expect(!validRecordTempName("../../pin.json.1.tmp"));
}

const test_record =
    \\{"schema":"spore.saved-disk-pin.v3","id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","storage":{"kind":"chunked-ext4-rootfs-v0","device":{"kind":"virtio-mmio","role":"rootfs","virtio_device_id":2,"mmio_slot":1},"logical_size":65536,"chunk_size":65536,"hash_algorithm":"blake3","index_digest":"blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","base_identity":"blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","object_namespace":"rootfs/blake3"}}
;
const test_pending_record =
    \\{"schema":"spore.saved-disk-pin.v3","id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","storage":{"kind":"chunked-ext4-rootfs-v0","device":{"kind":"virtio-mmio","role":"rootfs","virtio_device_id":2,"mmio_slot":1},"logical_size":65536,"chunk_size":65536,"hash_algorithm":"blake3","index_digest":"blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","base_identity":"blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","object_namespace":"rootfs/blake3"},"pending":{"spore_dir":"/saves/a.spore","reference_path":"/saves/a.spore.pin-stage-1f/000000/sporevm-disk-pin.json","cleanup_root":"/saves/a.spore.pin-stage-1f"}}
;

test "saved spore pin schemas are required and exact" {
    const allocator = std.testing.allocator;
    const id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(Reference, allocator,
        \\{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    , .{ .allocate = .alloc_always, .ignore_unknown_fields = false }));
    var unknown = try std.json.parseFromSlice(Reference, allocator,
        \\{"schema":"future","id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    , .{ .allocate = .alloc_always, .ignore_unknown_fields = false });
    defer unknown.deinit();
    try std.testing.expectError(error.BadManifest, unknown.value.validate());

    inline for (.{ test_record, test_pending_record }) |bytes| {
        var parsed = try parseRecord(allocator, bytes, id);
        parsed.deinit();
    }
    try std.testing.expectError(error.BadManifest, parseRecord(allocator, "{\"id\":\"" ++ id ++ "\"}", id));
    try std.testing.expectError(error.BadManifest, parseRecord(allocator, test_record, "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"));
    // Older pins fail as too old so GC can delete them; other schemas, and a
    // current schema carrying the removed manifest hash, are corrupt.
    for (old_schemas ++ [_][]const u8{"spore.saved-disk-pin.v4"}, 0..) |other, index| {
        const bytes = try std.mem.replaceOwned(u8, allocator, test_record, schema, other);
        defer allocator.free(bytes);
        const expected: anyerror = if (index < old_schemas.len) error.FormatTooOld else error.BadManifest;
        try std.testing.expectError(expected, parseRecord(allocator, bytes, id));
    }
    const with_hash = try std.mem.replaceOwned(u8, allocator, test_record, "\"storage\"", "\"manifest_sha256\":\"" ++ id ++ "\",\"storage\"");
    defer allocator.free(with_hash);
    try std.testing.expectError(error.BadManifest, parseRecord(allocator, with_hash, id));
}

test "exclusive pin survives moves and rejects copied or duplicate references" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const cache = try std.fs.path.join(allocator, &.{ root, "cache" });
    defer allocator.free(cache);
    const save = try std.fs.path.join(allocator, &.{ root, "staged.spore" });
    defer allocator.free(save);
    try Io.Dir.cwd().createDirPath(io, save);
    const zero_ranges = [_]disk_index.DiskIndexZeroRange{.{ .start = 0, .count = 1 }};
    const index = disk_index.DiskIndex{
        .kind = disk_index.disk_index_kind,
        .logical_size = spore.disk_chunk_size,
        .chunk_size = spore.disk_chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .object_namespace = spore.rootfs_storage_object_namespace,
        .chunks = &.{},
        .zero_ranges = &zero_ranges,
    };
    const encoded = try disk_index.encodeCanonicalAlloc(allocator, index);
    defer allocator.free(encoded.bytes);
    defer allocator.free(encoded.digest);
    const index_path = try rootfs_cas.manifestIndexPath(allocator, cache, encoded.digest);
    defer allocator.free(index_path);
    try chunk_sealer.ensureDirPath(allocator, std.fs.path.dirname(index_path).?);
    try chunk_sealer.writeFileAtomicDurable(allocator, index_path, encoded.bytes, 0o444);
    const manifest_path = try std.fs.path.join(allocator, &.{ save, "manifest.json" });
    defer allocator.free(manifest_path);
    try chunk_sealer.writeFileAtomicDurable(allocator, manifest_path, "manifest", 0o644);
    const disk = spore.Disk{
        .kind = spore.disk_kind_chunk_index,
        .device = .{ .mmio_slot = 1 },
        .size = spore.disk_chunk_size,
        .base = encoded.digest,
        .chunk_size = spore.disk_chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .object_namespace = spore.rootfs_storage_object_namespace,
    };
    var lock = try rootfs_mod.lockRootfsCacheExclusive(io, allocator, cache);
    defer lock.deinit();
    const registry = try LockedRegistry.init(allocator, cache, &lock);
    // Leave the pin pending, as a crash before the save's commit would.
    const save_ref = try std.fs.path.join(allocator, &.{ save, reference_file });
    defer allocator.free(save_ref);
    const id = try acquire(io, allocator, registry, try storageForDisk(disk), .{ .spore_dir = save, .reference_path = save_ref });
    defer allocator.free(id);
    try syncRegistry(allocator, registry);
    try std.testing.expectError(error.SavedSporeOwnershipConflict, testing.pinSave(io, allocator, registry, save, disk));
    // The parsed record owns independently allocated descriptor strings, but
    // byte-identical values remain authoritative. Any field mutation fails.
    var wrong_disk = disk;
    wrong_disk.device.mmio_slot += 1;
    try std.testing.expectError(error.BadManifest, loadForSporeLocked(io, allocator, registry, save, wrong_disk));

    const record_path = try recordPath(allocator, cache, id);
    defer allocator.free(record_path);
    const pending_record = try Io.Dir.cwd().readFileAlloc(io, record_path, allocator, .limited(max_record_bytes));
    defer allocator.free(pending_record);
    try Io.Dir.cwd().deleteFile(io, index_path);
    try std.testing.expectError(error.MissingChunk, loadForSporeLocked(io, allocator, registry, save, disk));
    const after_missing = try Io.Dir.cwd().readFileAlloc(io, record_path, allocator, .limited(max_record_bytes));
    defer allocator.free(after_missing);
    try std.testing.expectEqualSlices(u8, pending_record, after_missing);
    try chunk_sealer.replaceFileAtomicDurable(allocator, index_path, "corrupt", 0o444);
    if (loadForSporeLocked(io, allocator, registry, save, disk)) |unexpected| {
        var value = unexpected;
        value.deinit();
        return error.TestExpectedError;
    } else |_| {}
    const after_corrupt = try Io.Dir.cwd().readFileAlloc(io, record_path, allocator, .limited(max_record_bytes));
    defer allocator.free(after_corrupt);
    try std.testing.expectEqualSlices(u8, pending_record, after_corrupt);
    try chunk_sealer.replaceFileAtomicDurable(allocator, index_path, encoded.bytes, 0o444);
    // Loading through the save's own reference commits the pending pin.
    var loaded = try loadForSporeLocked(io, allocator, registry, save, disk);
    try std.testing.expect(loaded.value.pending == null);
    loaded.deinit();
    var committed = try loadRecord(io, allocator, cache, id);
    try std.testing.expect(committed.value.pending == null);
    committed.deinit();

    const moved = try std.fs.path.join(allocator, &.{ root, "renamed.spore" });
    defer allocator.free(moved);
    try Io.Dir.renameAbsolute(save, moved, io);
    loaded = try loadForSporeLocked(io, allocator, registry, moved, disk);
    loaded.deinit();

    const copied = try std.fs.path.join(allocator, &.{ root, "copied.spore" });
    defer allocator.free(copied);
    try Io.Dir.cwd().createDirPath(io, copied);
    inline for (.{ "manifest.json", reference_file }) |name| {
        const source = try std.fs.path.join(allocator, &.{ moved, name });
        defer allocator.free(source);
        const destination = try std.fs.path.join(allocator, &.{ copied, name });
        defer allocator.free(destination);
        const bytes = try Io.Dir.cwd().readFileAlloc(io, source, allocator, .limited(max_record_bytes));
        defer allocator.free(bytes);
        try chunk_sealer.writeFileAtomicDurable(allocator, destination, bytes, 0o600);
    }
    try std.testing.expectError(error.SavedSporeOwnershipConflict, loadForSporeLocked(io, allocator, registry, copied, disk));

    const duplicate_ref = try std.fs.path.join(allocator, &.{ root, "duplicate-ref" });
    defer allocator.free(duplicate_ref);
    const moved_ref = try std.fs.path.join(allocator, &.{ moved, reference_file });
    defer allocator.free(moved_ref);
    try hardLink(allocator, moved_ref, duplicate_ref);
    try std.testing.expectError(error.SavedSporeOwnershipConflict, loadForSporeLocked(io, allocator, registry, moved, disk));
    try Io.Dir.cwd().deleteFile(io, duplicate_ref);
    loaded = try loadForSporeLocked(io, allocator, registry, moved, disk);
    loaded.deinit();

    // Raw deletion leaves the cache-side anchor with one link, which makes
    // the orphan diagnosable without scanning arbitrary filesystem paths.
    try Io.Dir.cwd().deleteTree(io, moved);
    const listings = try list(io, allocator, cache);
    defer deinitListings(allocator, listings);
    try std.testing.expectEqual(@as(usize, 1), listings.len);
    try std.testing.expectEqualStrings(id, listings[0].id);
    try std.testing.expectEqual(ListingState.index_valid, listings[0].state);
    try std.testing.expectEqual(OwnerState.orphaned, listings[0].owner_state);
    try Io.Dir.cwd().deleteFile(io, index_path);
    {
        const missing_listings = try list(io, allocator, cache);
        defer deinitListings(allocator, missing_listings);
        try std.testing.expectEqual(ListingState.missing, missing_listings[0].state);
    }
    try chunk_sealer.replaceFileAtomicDurable(allocator, index_path, "corrupt", 0o444);
    {
        const corrupt_listings = try list(io, allocator, cache);
        defer deinitListings(allocator, corrupt_listings);
        try std.testing.expectEqual(ListingState.corrupt, corrupt_listings[0].state);
    }
    try chunk_sealer.replaceFileAtomicDurable(allocator, index_path, encoded.bytes, 0o444);
    try remove(io, allocator, registry, id);
    try std.testing.expectError(error.FileNotFound, loadForSporeLocked(io, allocator, registry, copied, disk));
    const after = try list(io, allocator, cache);
    defer deinitListings(allocator, after);
    try std.testing.expectEqual(@as(usize, 0), after.len);
}

test "fuzz saved spore pin parsers" {
    const Context = struct {
        fn testOne(_: @This(), smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];
            const allocator = std.testing.allocator;
            if (parseRecord(allocator, input, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")) |parsed| parsed.deinit() else |_| {}
            if (std.json.parseFromSlice(Reference, allocator, input, .{ .allocate = .alloc_always, .ignore_unknown_fields = false })) |parsed_value| {
                var parsed = parsed_value;
                defer parsed.deinit();
                _ = parsed.value.validate() catch {};
            } else |_| {}
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{ .corpus = &.{ test_record, test_pending_record } });
}
