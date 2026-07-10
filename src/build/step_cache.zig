const std = @import("std");
const Io = std.Io;
const Blake3 = std.crypto.hash.Blake3;

const rootfs_cas = @import("../rootfs_cas.zig");
const spore = @import("../spore.zig");
const rootfs_mod = @import("../rootfs.zig");
const chunk_sealer = @import("../chunk_sealer.zig");

pub const builder_version = "sporevm-build-v3";
const record_kind = "sporevm-build-step-v1";
const max_step_record_bytes = 256 * 1024;

const RecordEnvelope = struct {
    kind: []const u8,
};

pub const GcRecordInspection = union(enum) {
    root: spore.RootfsStorage,
    stale,
    unknown,
};

pub const NetworkMode = enum {
    spore,
    none,
};

pub const ArgInput = struct {
    key: []const u8,
    value: ?[]const u8,
};

pub const StepInput = struct {
    platform: rootfs_mod.Platform,
    parent_index_digest: []const u8,
    canonical_instruction: []const u8,
    disk_grow_target: u64 = 0,
    operation: Operation,

    pub const Operation = union(enum) {
        run: Run,
        copy: Copy,
    };

    pub const Run = struct {
        env_digest: []const u8 = "",
        workdir: []const u8 = "/",
        network_mode: NetworkMode,
    };

    pub const Copy = struct {
        input_digest: []const u8,
        env_digest: []const u8 = "",
        workdir: []const u8 = "/",
    };

    const FlatFields = struct {
        instruction_kind: []const u8,
        input_digest: []const u8,
        env_digest: []const u8,
        workdir: []const u8,
        network_mode: ?NetworkMode,
    };

    fn flatFields(self: StepInput) FlatFields {
        return switch (self.operation) {
            .run => |run| .{
                .instruction_kind = "RUN",
                .input_digest = "",
                .env_digest = run.env_digest,
                .workdir = run.workdir,
                .network_mode = run.network_mode,
            },
            .copy => |copy| .{
                .instruction_kind = "COPY",
                .input_digest = copy.input_digest,
                .env_digest = copy.env_digest,
                .workdir = copy.workdir,
                .network_mode = null,
            },
        };
    }
};

pub const StepRecord = struct {
    kind: []const u8,
    builder_version: []const u8,
    platform: rootfs_mod.Platform,
    step_key: []const u8,
    parent_index_digest: []const u8,
    child_index_digest: []const u8,
    rootfs_storage: spore.RootfsStorage,
    instruction_kind: []const u8 = "",
    instruction: []const u8,
    disk_grow_target: u64 = 0,
    input_digest: []const u8 = "",
    env_digest: []const u8 = "",
    workdir: []const u8 = "/",
    network_mode: ?NetworkMode = null,
    created_unix: i64 = 0,
};

pub fn stepKey(allocator: std.mem.Allocator, input: StepInput) ![]const u8 {
    const fields = input.flatFields();
    var h = Blake3.init(.{});
    h.update(builder_version);
    h.update("\n");
    h.update(input.platform.os);
    h.update("/");
    h.update(input.platform.arch);
    h.update("\n");
    h.update(input.parent_index_digest);
    h.update("\n");
    h.update(fields.instruction_kind);
    h.update("\n");
    h.update(input.canonical_instruction);
    if (input.disk_grow_target != 0) {
        var grow_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &grow_buf, input.disk_grow_target, .little);
        h.update("\n");
        h.update(&grow_buf);
    }
    h.update("\n");
    h.update(fields.input_digest);
    h.update("\n");
    h.update(fields.env_digest);
    h.update("\n");
    h.update(fields.workdir);
    h.update("\n");
    if (fields.network_mode) |mode| h.update(@tagName(mode));
    return finishHex(allocator, &h);
}

pub fn envDigest(allocator: std.mem.Allocator, env: []const []const u8, args: []const ArgInput) ![]const u8 {
    var h = Blake3.init(.{});
    hashField(&h, "sporevm-build-env-v2");
    hashCount(&h, env.len);
    for (env) |entry| hashField(&h, entry);
    hashCount(&h, args.len);
    for (args) |arg| {
        hashField(&h, arg.key);
        if (arg.value) |value| {
            h.update("\x01");
            hashField(&h, value);
        } else {
            h.update("\x00");
        }
    }
    return finishDigest(allocator, &h);
}

pub fn recordPath(allocator: std.mem.Allocator, cache_root: []const u8, key: []const u8) ![]const u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{key});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ cache_root, "build", "steps", file_name });
}

pub fn writeRecord(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    input: StepInput,
    step_key: []const u8,
    child_storage: spore.RootfsStorage,
) ![]const u8 {
    const fields = input.flatFields();
    try spore.validateRootfsStorageDescriptor(child_storage);
    if (!std.mem.eql(u8, child_storage.index_digest, child_storage.base_identity)) return error.BadManifest;
    if (!try rootfs_cas.storageCompleteWithStampRepair(io, allocator, cache_root, child_storage)) return error.RootFSDigestCacheMiss;
    const computed_key = try stepKey(allocator, input);
    defer allocator.free(computed_key);
    if (!std.mem.eql(u8, computed_key, step_key)) return error.BuildCacheKeyMismatch;
    const path = try recordPath(allocator, cache_root, step_key);
    const parent = std.fs.path.dirname(path) orelse return error.BadManifest;
    try Io.Dir.cwd().createDirPath(io, parent);
    const record = StepRecord{
        .kind = record_kind,
        .builder_version = builder_version,
        .platform = input.platform,
        .step_key = step_key,
        .parent_index_digest = input.parent_index_digest,
        .child_index_digest = child_storage.index_digest,
        .rootfs_storage = child_storage,
        .instruction_kind = fields.instruction_kind,
        .instruction = input.canonical_instruction,
        .disk_grow_target = input.disk_grow_target,
        .input_digest = fields.input_digest,
        .env_digest = fields.env_digest,
        .workdir = fields.workdir,
        .network_mode = fields.network_mode,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, record, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
    try chunk_sealer.writeFileAtomicDurable(allocator, path, json, 0o444);
    return path;
}

pub fn readHit(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    input: StepInput,
    expected_key: []const u8,
) !?spore.RootfsStorage {
    const fields = input.flatFields();
    const path = try recordPath(allocator, cache_root, expected_key);
    defer allocator.free(path);
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_step_record_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return null,
        else => |e| return e,
    };
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(StepRecord, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    const record = parsed.value;
    const storage = validChildStorage(record, expected_key) orelse return null;
    if (!std.mem.eql(u8, record.builder_version, builder_version)) return null;
    if (!std.mem.eql(u8, record.platform.os, input.platform.os) or !std.mem.eql(u8, record.platform.arch, input.platform.arch)) return null;
    if (!std.mem.eql(u8, record.parent_index_digest, input.parent_index_digest)) return null;
    if (!std.mem.eql(u8, record.instruction_kind, fields.instruction_kind)) return null;
    if (!std.mem.eql(u8, record.instruction, input.canonical_instruction)) return null;
    if (record.disk_grow_target != input.disk_grow_target) return null;
    if (!std.mem.eql(u8, record.input_digest, fields.input_digest)) return null;
    if (!std.mem.eql(u8, record.env_digest, fields.env_digest)) return null;
    if (!std.mem.eql(u8, record.workdir, fields.workdir)) return null;
    if (record.network_mode != fields.network_mode) return null;
    if (!try rootfs_cas.storageCompleteWithStampRepair(io, allocator, cache_root, storage)) return null;
    return try spore.cloneRootfsStorage(allocator, storage);
}

pub fn inspectRecordForGc(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    path: []const u8,
    expected_key: []const u8,
) !GcRecordInspection {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_step_record_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .stale,
        error.StreamTooLong => return .unknown,
        else => |e| return e,
    };
    defer allocator.free(bytes);
    var envelope = std.json.parseFromSlice(RecordEnvelope, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return .unknown;
    defer envelope.deinit();
    if (!std.mem.eql(u8, envelope.value.kind, record_kind)) return .unknown;

    var parsed = std.json.parseFromSlice(StepRecord, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return .stale;
    defer parsed.deinit();
    // Builder-version mismatches are cache misses for this binary, but the
    // schema-valid child may still be live for another version. Root it until
    // explicit step-record retention policy removes the record.
    const storage = validChildStorage(parsed.value, expected_key) orelse return .stale;
    // Complete stamps are invalidated before normal CAS deletion, so retain the
    // O(1) fast path when possible and scan every object only to repair legacy
    // or interrupted publication.
    if (!try rootfs_cas.storageMarkedComplete(io, allocator, cache_root, storage) and
        !try rootfs_cas.storageContentComplete(io, allocator, cache_root, storage)) return .stale;
    return .{ .root = try spore.cloneRootfsStorage(allocator, storage) };
}

fn validChildStorage(record: StepRecord, expected_key: []const u8) ?spore.RootfsStorage {
    if (!std.mem.eql(u8, record.kind, record_kind)) return null;
    if (!std.mem.eql(u8, record.step_key, expected_key)) return null;
    if (!std.mem.eql(u8, record.rootfs_storage.index_digest, record.child_index_digest)) return null;
    if (!std.mem.eql(u8, record.rootfs_storage.base_identity, record.child_index_digest)) return null;
    spore.validateRootfsStorageDescriptor(record.rootfs_storage) catch return null;
    return record.rootfs_storage;
}

fn finishHex(allocator: std.mem.Allocator, h: *Blake3) ![]const u8 {
    var digest: [Blake3.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

fn finishDigest(allocator: std.mem.Allocator, h: *Blake3) ![]const u8 {
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

fn hashCount(h: *Blake3, count: usize) void {
    var count_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &count_buf, count, .little);
    h.update(&count_buf);
}

test "step key changes with parent index" {
    const allocator = std.testing.allocator;
    const a = try stepKey(allocator, .{
        .platform = .{},
        .parent_index_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .canonical_instruction = "RUN true",
        .operation = .{ .run = .{ .network_mode = .spore } },
    });
    defer allocator.free(a);
    const b = try stepKey(allocator, .{
        .platform = .{},
        .parent_index_digest = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .canonical_instruction = "RUN true",
        .operation = .{ .run = .{ .network_mode = .spore } },
    });
    defer allocator.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "step key changes with disk grow target" {
    const allocator = std.testing.allocator;
    const normal = try stepKey(allocator, .{
        .platform = .{},
        .parent_index_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .canonical_instruction = "RUN true",
        .operation = .{ .run = .{ .network_mode = .spore } },
    });
    defer allocator.free(normal);
    const grown = try stepKey(allocator, .{
        .platform = .{},
        .parent_index_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .canonical_instruction = "RUN true",
        .disk_grow_target = 9 * 1024 * 1024 * 1024,
        .operation = .{ .run = .{ .network_mode = .spore } },
    });
    defer allocator.free(grown);
    try std.testing.expect(!std.mem.eql(u8, normal, grown));
}

test "environment digest distinguishes unset and empty ARG values" {
    const allocator = std.testing.allocator;
    const unset = try envDigest(allocator, &.{}, &.{.{ .key = "MODE", .value = null }});
    defer allocator.free(unset);
    const empty = try envDigest(allocator, &.{}, &.{.{ .key = "MODE", .value = "" }});
    defer allocator.free(empty);
    try std.testing.expect(!std.mem.eql(u8, unset, empty));
}

test "environment digest distinguishes ENV and ARG state" {
    const allocator = std.testing.allocator;
    const env_wins = try envDigest(allocator, &.{"MODE=env"}, &.{.{ .key = "MODE", .value = "arg" }});
    defer allocator.free(env_wins);
    const arg_wins = try envDigest(allocator, &.{"MODE=arg"}, &.{.{ .key = "MODE", .value = "env" }});
    defer allocator.free(arg_wins);
    try std.testing.expect(!std.mem.eql(u8, env_wins, arg_wins));
}

test "environment digest frames entries and preserves order" {
    const allocator = std.testing.allocator;
    const embedded = try envDigest(allocator, &.{"A=one\nB=two"}, &.{});
    defer allocator.free(embedded);
    const separate = try envDigest(allocator, &.{ "A=one", "B=two" }, &.{});
    defer allocator.free(separate);
    try std.testing.expect(!std.mem.eql(u8, embedded, separate));

    const forward = try envDigest(allocator, &.{ "MODE=first", "MODE=second" }, &.{});
    defer allocator.free(forward);
    const reverse = try envDigest(allocator, &.{ "MODE=second", "MODE=first" }, &.{});
    defer allocator.free(reverse);
    try std.testing.expect(!std.mem.eql(u8, forward, reverse));
}
