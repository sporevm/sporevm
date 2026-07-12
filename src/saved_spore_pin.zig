//! Host-private durable roots for machine-local saved-spore disk state.

const std = @import("std");
const builtin = @import("builtin");
const chunk_sealer = @import("chunk_sealer.zig");
const disk_index = @import("disk_index.zig");
const rootfs_mod = @import("rootfs.zig");
const rootfs_cas = @import("rootfs_cas.zig");
const spore = @import("spore.zig");

const Io = std.Io;
pub const schema = "spore.saved-disk-pin.v1";
pub const reference_schema = "spore.saved-disk-pin-ref.v1";
pub const dir_name = "pins";
pub const reference_file = "sporevm-disk-pin.json";
pub const max_record_bytes = 64 * 1024;
pub const max_manifest_bytes = spore.max_manifest_bytes;
pub const id_bytes = 32;

pub const Record = struct {
    schema: []const u8,
    id: []const u8,
    manifest_sha256: []const u8,
    pending_manifest_sha256: ?[]const u8 = null,
    storage: spore.RootfsStorage,

    pub fn validate(self: Record) !void {
        if (!std.mem.eql(u8, self.schema, schema) or !validId(self.id) or !validId(self.manifest_sha256)) return error.BadManifest;
        if (self.pending_manifest_sha256) |digest| if (!validId(digest)) return error.BadManifest;
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

pub const ListingState = enum { index_valid, corrupt, missing };
pub const Listing = struct { id: []const u8, state: ListingState, index_digest: ?[]const u8 = null };
pub const ListStats = struct { index_validation_count: usize = 0 };

pub const PublishTestFault = struct {
    fail_before_complete_stamp: bool = false,
};

pub var publish_test_fault: PublishTestFault = .{};

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
        if (validId(id)) {
            if (loadRecord(io, allocator, cache_root, id)) |parsed_value| {
                var parsed = parsed_value;
                defer parsed.deinit();
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
                errdefer allocator.free(listing.index_digest.?);
            } else |err| switch (err) {
                error.FileNotFound => listing.state = .missing,
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
    try Io.Dir.cwd().deleteFile(io, path);
    const pins_path = try std.fs.path.join(allocator, &.{ registry.cache_root, dir_name });
    defer allocator.free(pins_path);
    try chunk_sealer.fsyncDirPath(allocator, pins_path);
}

pub fn storageForDisk(disk: spore.Disk) !spore.RootfsStorage {
    if (!std.mem.eql(u8, disk.kind, spore.disk_kind_chunk_index) or disk.layers.len != 0) return error.BadManifest;
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

/// Publish the host-private pin/reference before making manifest.json visible.
/// The caller holds the rootfs cache lock and has already made the CAS root
/// durable. Failure may leave a safe orphan pin, never an unrooted manifest.
pub fn publishManifest(io: Io, allocator: std.mem.Allocator, registry: LockedRegistry, spore_dir: []const u8, disk: spore.Disk, manifest: anytype) !void {
    const stage = try std.fs.path.join(allocator, &.{ spore_dir, ".sporevm-pin-stage" });
    defer allocator.free(stage);
    try Io.Dir.cwd().createDirPath(io, stage);
    defer Io.Dir.cwd().deleteTree(io, stage) catch {};
    switch (@TypeOf(manifest)) {
        spore.Manifest => try spore.saveManifest(allocator, stage, manifest),
        spore.ManifestV1 => try spore.saveManifestV1(allocator, stage, manifest),
        else => @compileError("unsupported saved-spore manifest type"),
    }
    const staged_manifest = try std.fs.path.join(allocator, &.{ stage, "manifest.json" });
    defer allocator.free(staged_manifest);
    const manifest_bytes = try Io.Dir.cwd().readFileAlloc(io, staged_manifest, allocator, .limited(max_manifest_bytes + 1));
    defer allocator.free(manifest_bytes);
    if (manifest_bytes.len > max_manifest_bytes) return error.StreamTooLong;
    try chunk_sealer.replaceFileAtomicDurable(allocator, staged_manifest, manifest_bytes, 0o644);
    const storage = try storageForDisk(disk);
    try validateRoot(allocator, registry.cache_root, storage);
    // Snapshot sealing durably publishes every object before the canonical
    // index. Publish the derived completeness proof next, before the pin and
    // save path can become visible, so restore and named fast-fork agree on
    // the same bound global-CAS authority.
    if (builtin.is_test and publish_test_fault.fail_before_complete_stamp) return error.InjectedFailure;
    try rootfs_cas.markStorageComplete(io, allocator, registry.cache_root, storage.index_digest);
    _ = try createValidated(io, allocator, registry, stage, disk, storage);
    const staged_ref = try std.fs.path.join(allocator, &.{ stage, reference_file });
    defer allocator.free(staged_ref);
    const final_ref = try std.fs.path.join(allocator, &.{ spore_dir, reference_file });
    defer allocator.free(final_ref);
    try Io.Dir.renameAbsolute(staged_ref, final_ref, io);
    const final_manifest = try std.fs.path.join(allocator, &.{ spore_dir, "manifest.json" });
    defer allocator.free(final_manifest);
    try Io.Dir.renameAbsolute(staged_manifest, final_manifest, io);
    try chunk_sealer.fsyncDirPath(allocator, spore_dir);
}

/// The caller holds the rootfs cache lock. The manifest and every CAS value
/// it names must already be durable; the final save path is not visible yet.
pub fn create(io: Io, allocator: std.mem.Allocator, registry: LockedRegistry, spore_dir: []const u8, disk: spore.Disk) ![]const u8 {
    const storage = try storageForDisk(disk);
    try validateRoot(allocator, registry.cache_root, storage);
    return createValidated(io, allocator, registry, spore_dir, disk, storage);
}

/// Publish a pin after the caller validated this exact storage descriptor and
/// canonical index under the same cache lock. Batch fork uses this to avoid N
/// repeated index parses while minting child-manifest bindings.
pub fn createValidated(io: Io, allocator: std.mem.Allocator, registry: LockedRegistry, spore_dir: []const u8, disk: spore.Disk, storage: spore.RootfsStorage) ![]const u8 {
    if (!spore.rootfsStorageEql(storage, try storageForDisk(disk))) return error.BadManifest;
    const manifest_path = try std.fs.path.join(allocator, &.{ spore_dir, "manifest.json" });
    defer allocator.free(manifest_path);
    const manifest_sha256 = try sha256File(io, allocator, manifest_path);
    defer allocator.free(manifest_sha256);
    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        var random: [id_bytes]u8 = undefined;
        io.random(&random);
        const id_array = std.fmt.bytesToHex(random, .lower);
        const id = try allocator.dupe(u8, &id_array);
        if (createWithId(allocator, registry, spore_dir, storage, manifest_sha256, id)) |_| return id else |err| {
            allocator.free(id);
            if (err != error.PathAlreadyExists) return err;
        }
    }
    return error.PathAlreadyExists;
}

pub const PreparedPin = struct {
    id: []const u8,
    manifest_sha256: []const u8,
};

/// Prepare a hidden child's durable reference without holding the cache lock.
/// The child is not visible yet, so a crash can leave only an unreachable ref.
pub fn prepareValidatedReference(io: Io, allocator: std.mem.Allocator, spore_dir: []const u8, disk: spore.Disk, storage: spore.RootfsStorage) !PreparedPin {
    if (!spore.rootfsStorageEql(storage, try storageForDisk(disk))) return error.BadManifest;
    const manifest_path = try std.fs.path.join(allocator, &.{ spore_dir, "manifest.json" });
    defer allocator.free(manifest_path);
    const manifest_sha256 = try sha256File(io, allocator, manifest_path);
    errdefer allocator.free(manifest_sha256);
    var random: [id_bytes]u8 = undefined;
    io.random(&random);
    const id_array = std.fmt.bytesToHex(random, .lower);
    const id = try allocator.dupe(u8, &id_array);
    errdefer allocator.free(id);
    const ref_path = try std.fs.path.join(allocator, &.{ spore_dir, reference_file });
    defer allocator.free(ref_path);
    const ref_json = try std.json.Stringify.valueAlloc(allocator, Reference{ .schema = reference_schema, .id = id }, .{ .whitespace = .indent_2 });
    defer allocator.free(ref_json);
    try chunk_sealer.writeFileAtomicDurable(allocator, ref_path, ref_json, 0o600);
    return .{ .id = id, .manifest_sha256 = manifest_sha256 };
}

/// Ensure the registry directory itself is durable. Call once before a batch.
pub fn ensureRegistryDurable(allocator: std.mem.Allocator, registry: LockedRegistry) !void {
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

/// Publish one already-prepared record. The caller holds the cache lock and
/// syncs the registry once after the complete batch.
pub fn publishPreparedRecord(allocator: std.mem.Allocator, registry: LockedRegistry, storage: spore.RootfsStorage, prepared: PreparedPin) !void {
    const record = Record{ .schema = schema, .id = prepared.id, .manifest_sha256 = prepared.manifest_sha256, .storage = storage };
    try record.validate();
    const record_path = try recordPath(allocator, registry.cache_root, prepared.id);
    defer allocator.free(record_path);
    const record_json = try std.json.Stringify.valueAlloc(allocator, record, .{ .whitespace = .indent_2 });
    defer allocator.free(record_json);
    try createFileExclusiveDurable(allocator, record_path, record_json, 0o600, false);
}

pub fn syncPreparedRecords(allocator: std.mem.Allocator, registry: LockedRegistry) !void {
    const pins_dir = try std.fs.path.join(allocator, &.{ registry.cache_root, dir_name });
    defer allocator.free(pins_dir);
    try chunk_sealer.fsyncDirPath(allocator, pins_dir);
}

fn createWithId(allocator: std.mem.Allocator, registry: LockedRegistry, spore_dir: []const u8, storage: spore.RootfsStorage, manifest_sha256: []const u8, id: []const u8) !void {
    try ensureRegistryDurable(allocator, registry);
    const record_path = try recordPath(allocator, registry.cache_root, id);
    defer allocator.free(record_path);
    const record_json = try std.json.Stringify.valueAlloc(allocator, Record{ .schema = schema, .id = id, .manifest_sha256 = manifest_sha256, .storage = storage }, .{ .whitespace = .indent_2 });
    defer allocator.free(record_json);
    try createFileExclusiveDurable(allocator, record_path, record_json, 0o600, true);
    const ref_path = try std.fs.path.join(allocator, &.{ spore_dir, reference_file });
    defer allocator.free(ref_path);
    const ref_json = try std.json.Stringify.valueAlloc(allocator, Reference{ .schema = reference_schema, .id = id }, .{ .whitespace = .indent_2 });
    defer allocator.free(ref_json);
    try chunk_sealer.writeFileAtomicDurable(allocator, ref_path, ref_json, 0o600);
}

fn authorizeManifestBytes(io: Io, allocator: std.mem.Allocator, registry: LockedRegistry, spore_dir: []const u8, disk: spore.Disk, manifest_bytes: []const u8) !void {
    // Establish existing authority before mutating anything. This rejects a
    // copied/dangling reference, a changed disk descriptor, and a manifest
    // whose current bytes are not already authorized by this exact pin.
    var authority = try loadForSporeLocked(io, allocator, registry, spore_dir, disk);
    defer authority.deinit();
    const manifest_path = try std.fs.path.join(allocator, &.{ spore_dir, "manifest.json" });
    defer allocator.free(manifest_path);
    const current_digest = try sha256File(io, allocator, manifest_path);
    defer allocator.free(current_digest);
    const next_digest = try sha256Bytes(allocator, manifest_bytes);
    defer allocator.free(next_digest);
    const path = try recordPath(allocator, registry.cache_root, authority.value.id);
    defer allocator.free(path);
    const json = try std.json.Stringify.valueAlloc(allocator, Record{ .schema = schema, .id = authority.value.id, .manifest_sha256 = current_digest, .pending_manifest_sha256 = next_digest, .storage = authority.value.storage }, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try replaceRecord(allocator, path, json);
}

/// Atomically replace an already-pinned manifest after first extending its pin
/// authorization to cover both the old and new durable bytes. The caller holds
/// the rootfs cache lock for the full operation.
pub fn replaceAuthorizedManifest(io: Io, allocator: std.mem.Allocator, registry: LockedRegistry, spore_dir: []const u8, disk: spore.Disk, manifest_bytes: []const u8) !void {
    var existing = try loadForSporeLocked(io, allocator, registry, spore_dir, disk);
    defer existing.deinit();
    const manifest_path = try std.fs.path.join(allocator, &.{ spore_dir, "manifest.json" });
    defer allocator.free(manifest_path);
    const requested_digest = try sha256Bytes(allocator, manifest_bytes);
    defer allocator.free(requested_digest);
    if (std.mem.eql(u8, existing.value.manifest_sha256, requested_digest)) return;
    const record_path = try recordPath(allocator, registry.cache_root, existing.value.id);
    defer allocator.free(record_path);
    const pending = try std.json.Stringify.valueAlloc(allocator, Record{
        .schema = schema,
        .id = existing.value.id,
        .manifest_sha256 = existing.value.manifest_sha256,
        .pending_manifest_sha256 = requested_digest,
        .storage = existing.value.storage,
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(pending);
    try replaceRecord(allocator, record_path, pending);
    try chunk_sealer.replaceFileAtomicDurable(allocator, manifest_path, manifest_bytes, 0o644);
    const json = try std.json.Stringify.valueAlloc(allocator, Record{
        .schema = schema,
        .id = existing.value.id,
        .manifest_sha256 = requested_digest,
        .pending_manifest_sha256 = null,
        .storage = existing.value.storage,
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try replaceRecord(allocator, record_path, json);
}

/// Validate and reconcile a saved-spore pin. The caller must hold the rootfs
/// cache lock because crash recovery may durably rewrite the pin record.
pub fn loadForSporeLocked(io: Io, allocator: std.mem.Allocator, registry: LockedRegistry, spore_dir: []const u8, disk: spore.Disk) !std.json.Parsed(Record) {
    const ref_path = try std.fs.path.join(allocator, &.{ spore_dir, reference_file });
    defer allocator.free(ref_path);
    const ref_bytes = try Io.Dir.cwd().readFileAlloc(io, ref_path, allocator, .limited(max_record_bytes));
    defer allocator.free(ref_bytes);
    var ref = std.json.parseFromSlice(Reference, allocator, ref_bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = false }) catch return error.BadManifest;
    defer ref.deinit();
    try ref.value.validate();
    var record = try loadRecord(io, allocator, registry.cache_root, ref.value.id);
    errdefer record.deinit();
    const expected = try storageForDisk(disk);
    if (!spore.rootfsStorageEql(record.value.storage, expected)) return error.BadManifest;
    // Never change authorization state before proving the canonical root is
    // intact. Missing/corrupt roots leave the record byte-for-byte unchanged.
    try validateRoot(allocator, registry.cache_root, record.value.storage);
    const manifest_path = try std.fs.path.join(allocator, &.{ spore_dir, "manifest.json" });
    defer allocator.free(manifest_path);
    const digest = try sha256File(io, allocator, manifest_path);
    defer allocator.free(digest);
    if (record.value.pending_manifest_sha256) |pending| {
        const actual_is_current = std.mem.eql(u8, digest, record.value.manifest_sha256);
        const actual_is_pending = std.mem.eql(u8, digest, pending);
        if (!actual_is_current and !actual_is_pending) return error.BadManifest;
        const reconciled_digest = if (actual_is_pending) pending else record.value.manifest_sha256;
        const path = try recordPath(allocator, registry.cache_root, record.value.id);
        defer allocator.free(path);
        const json = try std.json.Stringify.valueAlloc(allocator, Record{
            .schema = schema,
            .id = record.value.id,
            .manifest_sha256 = reconciled_digest,
            .pending_manifest_sha256 = null,
            .storage = record.value.storage,
        }, .{ .whitespace = .indent_2 });
        defer allocator.free(json);
        try replaceRecord(allocator, path, json);
        record.value.manifest_sha256 = reconciled_digest;
        record.value.pending_manifest_sha256 = null;
    } else if (!std.mem.eql(u8, digest, record.value.manifest_sha256)) return error.BadManifest;
    return record;
}

pub fn loadRecord(io: Io, allocator: std.mem.Allocator, cache_root: []const u8, id: []const u8) !std.json.Parsed(Record) {
    if (!validId(id)) return error.BadManifest;
    const path = try recordPath(allocator, cache_root, id);
    defer allocator.free(path);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_record_bytes));
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(Record, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = false }) catch return error.BadManifest;
    errdefer parsed.deinit();
    try parsed.value.validate();
    if (!std.mem.eql(u8, parsed.value.id, id)) return error.BadManifest;
    return parsed;
}

pub fn validateRoot(allocator: std.mem.Allocator, cache_root: []const u8, storage: spore.RootfsStorage) !void {
    const index_path = try rootfs_cas.manifestIndexPath(allocator, cache_root, storage.index_digest);
    defer allocator.free(index_path);
    const bytes = try rootfs_cas.readVerifiedStorageIndexPath(allocator, index_path, storage);
    defer allocator.free(bytes);
    var parsed = try disk_index.parseDiskIndex(allocator, bytes, try spore.diskIndexDescriptorForStorage(storage));
    defer parsed.deinit();
}

pub fn recordPath(allocator: std.mem.Allocator, cache_root: []const u8, id: []const u8) ![]const u8 {
    if (!validId(id)) return error.BadManifest;
    const name = try std.fmt.allocPrint(allocator, "{s}.json", .{id});
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ cache_root, dir_name, name });
}

pub fn validId(value: []const u8) bool {
    if (value.len != id_bytes * 2) return false;
    for (value) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
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

fn sha256File(io: Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_manifest_bytes + 1));
    defer allocator.free(bytes);
    if (bytes.len > max_manifest_bytes) return error.StreamTooLong;
    return sha256Bytes(allocator, bytes);
}

fn replaceRecord(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    try chunk_sealer.replaceFileAtomicDurable(allocator, path, bytes, 0o600);
}

fn createFileExclusiveDurable(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8, mode: c_uint, sync_parent: bool) !void {
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
    if (sync_parent) try chunk_sealer.fsyncDirPath(allocator, std.fs.path.dirname(path) orelse ".");
}

fn sha256Bytes(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
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

test "saved spore pin schemas are required and exact" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(Reference, allocator,
        \\{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    , .{ .allocate = .alloc_always, .ignore_unknown_fields = false }));
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(Record, allocator,
        \\{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","manifest_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    , .{ .allocate = .alloc_always, .ignore_unknown_fields = false }));
    var unknown = try std.json.parseFromSlice(Reference, allocator,
        \\{"schema":"future","id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    , .{ .allocate = .alloc_always, .ignore_unknown_fields = false });
    defer unknown.deinit();
    try std.testing.expectError(error.BadManifest, unknown.value.validate());
}

test "saved spore manifest hashing preserves the 64 MiB loader contract" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(io, "manifest.json", .{});
    file.close(io);
    const path = try tmp.dir.realPathFileAlloc(io, "manifest.json", allocator);
    defer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return error.IoFailed;
    defer _ = std.c.close(fd);
    if (std.c.ftruncate(fd, max_manifest_bytes - 1) != 0) return error.IoFailed;
    const below_digest = try sha256File(io, allocator, path);
    allocator.free(below_digest);
    if (std.c.ftruncate(fd, max_manifest_bytes) != 0) return error.IoFailed;
    const digest = try sha256File(io, allocator, path);
    allocator.free(digest);
    if (std.c.ftruncate(fd, max_manifest_bytes + 1) != 0) return error.IoFailed;
    try std.testing.expectError(error.StreamTooLong, sha256File(io, allocator, path));
}

test "durable pin survives moves while raw copies share one removal identity" {
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
    const zero_chunks = [_]u64{0};
    const index = disk_index.DiskIndex{
        .kind = disk_index.disk_index_kind,
        .logical_size = spore.disk_chunk_size,
        .chunk_size = spore.disk_chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .object_namespace = spore.rootfs_storage_object_namespace,
        .chunks = &.{},
        .zero_chunks = &zero_chunks,
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
    try chunk_sealer.writeFileAtomicDurable(allocator, manifest_path, "old", 0o644);
    const disk = spore.Disk{
        .kind = spore.disk_kind_chunk_index,
        .device = .{ .mmio_slot = 1 },
        .size = spore.disk_chunk_size,
        .base = encoded.digest,
        .chunk_size = spore.disk_chunk_size,
        .hash_algorithm = spore.rootfs_storage_hash_algorithm_blake3,
        .object_namespace = spore.rootfs_storage_object_namespace,
        .layers = &.{},
    };
    var lock = try rootfs_mod.lockRootfsCacheExclusive(io, allocator, cache);
    defer lock.deinit();
    const registry = try LockedRegistry.init(allocator, cache, &lock);
    const id = try create(io, allocator, registry, save, disk);
    defer allocator.free(id);
    const manifest_digest = try sha256File(io, allocator, manifest_path);
    defer allocator.free(manifest_digest);
    try std.testing.expectError(error.PathAlreadyExists, createWithId(allocator, registry, save, try storageForDisk(disk), manifest_digest, id));
    var loaded = try loadForSporeLocked(io, allocator, registry, save, disk);
    loaded.deinit();
    // The parsed record owns independently allocated descriptor strings, but
    // byte-identical values remain authoritative. Any field mutation fails.
    var wrong_disk = disk;
    wrong_disk.device.mmio_slot += 1;
    try std.testing.expectError(error.BadManifest, loadForSporeLocked(io, allocator, registry, save, wrong_disk));
    var wrong_storage = try storageForDisk(disk);
    wrong_storage.logical_size += spore.disk_chunk_size;
    try std.testing.expectError(error.BadManifest, createValidated(io, allocator, registry, save, disk, wrong_storage));

    try authorizeManifestBytes(io, allocator, registry, save, disk, "new");
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
    // A crash on either side of the manifest rewrite remains valid.
    loaded = try loadForSporeLocked(io, allocator, registry, save, disk);
    loaded.deinit();
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = "new" });
    try std.testing.expectError(error.BadManifest, loadForSporeLocked(io, allocator, registry, save, disk));
    try chunk_sealer.replaceFileAtomicDurable(allocator, manifest_path, "old", 0o644);
    try authorizeManifestBytes(io, allocator, registry, save, disk, "new");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = "new" });
    loaded = try loadForSporeLocked(io, allocator, registry, save, disk);
    loaded.deinit();
    try replaceAuthorizedManifest(io, allocator, registry, save, disk, "new");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = "old" });
    try std.testing.expectError(error.BadManifest, loadForSporeLocked(io, allocator, registry, save, disk));
    try chunk_sealer.replaceFileAtomicDurable(allocator, manifest_path, "new", 0o644);

    const moved = try std.fs.path.join(allocator, &.{ root, "renamed.spore" });
    defer allocator.free(moved);
    try Io.Dir.renameAbsolute(save, moved, io);
    loaded = try loadForSporeLocked(io, allocator, registry, moved, disk);
    loaded.deinit();
    const moved_manifest = try std.fs.path.join(allocator, &.{ moved, "manifest.json" });
    defer allocator.free(moved_manifest);

    const copied = try std.fs.path.join(allocator, &.{ root, "copied.spore" });
    defer allocator.free(copied);
    try Io.Dir.cwd().createDirPath(io, copied);
    inline for (.{ "manifest.json", reference_file }) |name| {
        const source = try std.fs.path.join(allocator, &.{ moved, name });
        defer allocator.free(source);
        const destination = try std.fs.path.join(allocator, &.{ copied, name });
        defer allocator.free(destination);
        const bytes = try Io.Dir.cwd().readFileAlloc(io, source, allocator, .limited(max_manifest_bytes + 1));
        defer allocator.free(bytes);
        try chunk_sealer.writeFileAtomicDurable(allocator, destination, bytes, 0o600);
    }
    loaded = try loadForSporeLocked(io, allocator, registry, copied, disk);
    try std.testing.expectEqualStrings(id, loaded.value.id);
    loaded.deinit();

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = moved_manifest, .data = "tampered" });
    try std.testing.expectError(error.BadManifest, loadForSporeLocked(io, allocator, registry, moved, disk));
    try std.testing.expectError(error.BadManifest, authorizeManifestBytes(io, allocator, registry, moved, disk, "attacker-authorized"));

    // Raw deletion cannot unroot data. The leaked pin stays inspectable and
    // requires an explicit id-scoped unpin.
    try Io.Dir.cwd().deleteTree(io, moved);
    const listings = try list(io, allocator, cache);
    defer deinitListings(allocator, listings);
    try std.testing.expectEqual(@as(usize, 1), listings.len);
    try std.testing.expectEqualStrings(id, listings[0].id);
    try std.testing.expectEqual(ListingState.index_valid, listings[0].state);
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
    loaded = try loadForSporeLocked(io, allocator, registry, copied, disk);
    loaded.deinit();
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
            if (std.json.parseFromSlice(Record, allocator, input, .{ .allocate = .alloc_always, .ignore_unknown_fields = false })) |parsed_value| {
                var parsed = parsed_value;
                defer parsed.deinit();
                _ = parsed.value.validate() catch {};
            } else |_| {}
            if (std.json.parseFromSlice(Reference, allocator, input, .{ .allocate = .alloc_always, .ignore_unknown_fields = false })) |parsed_value| {
                var parsed = parsed_value;
                defer parsed.deinit();
                _ = parsed.value.validate() catch {};
            } else |_| {}
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
