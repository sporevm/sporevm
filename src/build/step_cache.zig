const std = @import("std");
const Io = std.Io;
const Blake3 = std.crypto.hash.Blake3;

const rootfs_cas = @import("../rootfs_cas.zig");
const spore = @import("../spore.zig");
const rootfs_mod = @import("../rootfs.zig");
const chunk_sealer = @import("../chunk_sealer.zig");

pub const builder_version = "sporevm-build-v1";
const record_kind = "sporevm-build-step-v1";
const max_step_record_bytes = 256 * 1024;

pub const StepInput = struct {
    platform: rootfs_mod.Platform,
    parent_index_digest: []const u8,
    instruction_kind: []const u8,
    canonical_instruction: []const u8,
    input_digest: []const u8 = "",
    env_digest: []const u8 = "",
    workdir: []const u8 = "/",
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
    input_digest: []const u8 = "",
    env_digest: []const u8 = "",
    workdir: []const u8 = "/",
    created_unix: i64 = 0,
};

pub fn stepKey(allocator: std.mem.Allocator, input: StepInput) ![]const u8 {
    var h = Blake3.init(.{});
    h.update(builder_version);
    h.update("\n");
    h.update(input.platform.os);
    h.update("/");
    h.update(input.platform.arch);
    h.update("\n");
    h.update(input.parent_index_digest);
    h.update("\n");
    h.update(input.instruction_kind);
    h.update("\n");
    h.update(input.canonical_instruction);
    h.update("\n");
    h.update(input.input_digest);
    h.update("\n");
    h.update(input.env_digest);
    h.update("\n");
    h.update(input.workdir);
    return finishHex(allocator, &h);
}

pub fn envDigest(allocator: std.mem.Allocator, env: []const []const u8, args: []const []const u8) ![]const u8 {
    const total = env.len + args.len;
    const entries = try allocator.alloc([]const u8, total);
    defer allocator.free(entries);
    for (env, 0..) |entry, i| entries[i] = entry;
    for (args, 0..) |entry, i| entries[env.len + i] = entry;
    std.mem.sort([]const u8, entries, {}, stringLessThan);
    var h = Blake3.init(.{});
    for (entries) |entry| {
        h.update(entry);
        h.update("\n");
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
        .instruction_kind = input.instruction_kind,
        .instruction = input.canonical_instruction,
        .input_digest = input.input_digest,
        .env_digest = input.env_digest,
        .workdir = input.workdir,
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
    if (!std.mem.eql(u8, record.kind, record_kind)) return null;
    if (!std.mem.eql(u8, record.builder_version, builder_version)) return null;
    if (!std.mem.eql(u8, record.platform.os, input.platform.os) or !std.mem.eql(u8, record.platform.arch, input.platform.arch)) return null;
    if (!std.mem.eql(u8, record.step_key, expected_key)) return null;
    if (!std.mem.eql(u8, record.parent_index_digest, input.parent_index_digest)) return null;
    if (!std.mem.eql(u8, record.instruction_kind, input.instruction_kind)) return null;
    if (!std.mem.eql(u8, record.instruction, input.canonical_instruction)) return null;
    if (!std.mem.eql(u8, record.input_digest, input.input_digest)) return null;
    if (!std.mem.eql(u8, record.env_digest, input.env_digest)) return null;
    if (!std.mem.eql(u8, record.workdir, input.workdir)) return null;
    if (!std.mem.eql(u8, record.rootfs_storage.index_digest, record.child_index_digest)) return null;
    if (!std.mem.eql(u8, record.rootfs_storage.base_identity, record.child_index_digest)) return null;
    spore.validateRootfsStorageDescriptor(record.rootfs_storage) catch return null;
    if (!try rootfs_cas.storageCompleteWithStampRepair(io, allocator, cache_root, record.rootfs_storage)) return null;
    return try spore.cloneRootfsStorage(allocator, record.rootfs_storage);
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

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "step key changes with parent index" {
    const allocator = std.testing.allocator;
    const a = try stepKey(allocator, .{
        .platform = .{},
        .parent_index_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .instruction_kind = "RUN",
        .canonical_instruction = "RUN true",
    });
    defer allocator.free(a);
    const b = try stepKey(allocator, .{
        .platform = .{},
        .parent_index_digest = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .instruction_kind = "RUN",
        .canonical_instruction = "RUN true",
    });
    defer allocator.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}
