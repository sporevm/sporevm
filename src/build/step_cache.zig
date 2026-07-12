const std = @import("std");
const Io = std.Io;
const Blake3 = std.crypto.hash.Blake3;

const rootfs_cas = @import("../rootfs_cas.zig");
const spore = @import("../spore.zig");
const rootfs_mod = @import("../rootfs.zig");
const chunk_sealer = @import("../chunk_sealer.zig");

pub const builder_version = "sporevm-build-v7";
const legacy_builder_version = "sporevm-build-v6";
const record_kind = "sporevm-build-step-v1";
const stale_record_kind_v2 = "sporevm-build-step-v2";
const max_step_record_bytes = 256 * 1024;
const test_executor_identity = "blake3:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
// SCRATCH has no filesystem parent. This reserved identity occupies the
// parent-key domain without pretending that a user-visible image exists.
const internal_scratch_parent_identity = "blake3:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";

const RecordEnvelope = struct {
    kind: []const u8,
};

pub const GcRecordInspection = union(enum) {
    root: spore.RootfsStorage,
    legacy: spore.RootfsStorage,
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
    /// Exact kernel/initrd plus build-agent ABI for executor-backed steps.
    /// PREPARE carries its producer separately in the typed operation.
    executor_identity: []const u8 = "",
    operation: Operation,

    pub const Operation = union(enum) {
        scratch: Scratch,
        prepare: Prepare,
        run: Run,
        copy: Copy,
        workdir: Workdir,
    };

    pub const Scratch = struct {
        exact_target: u64,
        format_identity: []const u8,
    };

    pub const Prepare = struct {
        exact_target: u64,
        producer_identity: []const u8,
    };

    pub const Run = struct {
        env_digest: []const u8 = "",
        workdir: []const u8 = "/",
        network_mode: NetworkMode,
        memory_bytes: ?u64 = null,
        vcpus: ?u32 = null,
        nofile_soft: ?u64 = null,
        nofile_hard: ?u64 = null,
    };

    pub const Copy = struct {
        input_digest: []const u8,
        env_digest: []const u8 = "",
        workdir: []const u8 = "/",
    };

    pub const Workdir = struct {
        target: []const u8,
        env_digest: []const u8 = "",
        workdir: []const u8 = "/",
    };

    const FlatFields = struct {
        instruction_kind: []const u8,
        input_digest: []const u8,
        env_digest: []const u8,
        workdir: []const u8,
        network_mode: ?NetworkMode,
        memory_bytes: ?u64,
        vcpus: ?u32,
        nofile_soft: ?u64,
        nofile_hard: ?u64,
        exact_target: ?u64,
        producer_identity: ?[]const u8,
        executor_identity: []const u8,
    };

    fn flatFields(self: StepInput) FlatFields {
        return switch (self.operation) {
            .scratch => |scratch| .{
                .instruction_kind = "SCRATCH",
                .input_digest = scratch.format_identity,
                .env_digest = "",
                .workdir = "",
                .network_mode = null,
                .memory_bytes = null,
                .vcpus = null,
                .nofile_soft = null,
                .nofile_hard = null,
                .exact_target = scratch.exact_target,
                .producer_identity = null,
                .executor_identity = "",
            },
            .prepare => |prepare| .{
                .instruction_kind = "PREPARE",
                .input_digest = "",
                .env_digest = "",
                .workdir = "",
                .network_mode = null,
                .memory_bytes = null,
                .vcpus = null,
                .nofile_soft = null,
                .nofile_hard = null,
                .exact_target = prepare.exact_target,
                .producer_identity = prepare.producer_identity,
                .executor_identity = "",
            },
            .run => |run| .{
                .instruction_kind = "RUN",
                .input_digest = "",
                .env_digest = run.env_digest,
                .workdir = run.workdir,
                .network_mode = run.network_mode,
                .memory_bytes = run.memory_bytes,
                .vcpus = run.vcpus,
                .nofile_soft = run.nofile_soft,
                .nofile_hard = run.nofile_hard,
                .exact_target = null,
                .producer_identity = null,
                .executor_identity = self.executor_identity,
            },
            .copy => |copy| .{
                .instruction_kind = "COPY",
                .input_digest = copy.input_digest,
                .env_digest = copy.env_digest,
                .workdir = copy.workdir,
                .network_mode = null,
                .memory_bytes = null,
                .vcpus = null,
                .nofile_soft = null,
                .nofile_hard = null,
                .exact_target = null,
                .producer_identity = null,
                .executor_identity = self.executor_identity,
            },
            .workdir => |workdir| .{
                .instruction_kind = "WORKDIR",
                .input_digest = workdir.target,
                .env_digest = workdir.env_digest,
                .workdir = workdir.workdir,
                .network_mode = null,
                .memory_bytes = null,
                .vcpus = null,
                .nofile_soft = null,
                .nofile_hard = null,
                .exact_target = null,
                .producer_identity = null,
                .executor_identity = self.executor_identity,
            },
        };
    }
};

pub fn scratchInput(platform: rootfs_mod.Platform, exact_target: u64, format_identity: []const u8) !StepInput {
    const input = StepInput{
        .platform = platform,
        .parent_index_digest = internal_scratch_parent_identity,
        .canonical_instruction = "SCRATCH",
        .operation = .{ .scratch = .{ .exact_target = exact_target, .format_identity = format_identity } },
    };
    try validateInput(input, input.flatFields());
    return input;
}

pub fn prepareInput(
    platform: rootfs_mod.Platform,
    parent_index_digest: []const u8,
    exact_target: u64,
    producer_identity: []const u8,
) !StepInput {
    const input = StepInput{
        .platform = platform,
        .parent_index_digest = parent_index_digest,
        .canonical_instruction = "PREPARE",
        .operation = .{ .prepare = .{
            .exact_target = exact_target,
            .producer_identity = producer_identity,
        } },
    };
    try validateInput(input, input.flatFields());
    return input;
}

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
    network_mode: ?NetworkMode = null,
    memory_bytes: ?u64 = null,
    vcpus: ?u32 = null,
    nofile_soft: ?u64 = null,
    nofile_hard: ?u64 = null,
    exact_target: ?u64 = null,
    producer_identity: ?[]const u8 = null,
    executor_identity: []const u8 = "",
    created_unix: i64 = 0,
};

pub fn stepKey(allocator: std.mem.Allocator, input: StepInput) ![]const u8 {
    const fields = input.flatFields();
    try validateInput(input, fields);
    var h = Blake3.init(.{});
    hashField(&h, builder_version);
    hashField(&h, input.platform.os);
    hashField(&h, input.platform.arch);
    hashField(&h, input.parent_index_digest);
    hashField(&h, fields.instruction_kind);
    hashField(&h, input.canonical_instruction);
    hashField(&h, fields.input_digest);
    hashField(&h, fields.env_digest);
    hashField(&h, fields.workdir);
    hashOptionalField(&h, if (fields.network_mode) |mode| @tagName(mode) else null);
    hashOptionalU64(&h, fields.memory_bytes);
    hashOptionalU32(&h, fields.vcpus);
    hashOptionalU64(&h, fields.nofile_soft);
    hashOptionalU64(&h, fields.nofile_hard);
    hashOptionalU64(&h, fields.exact_target);
    hashOptionalField(&h, fields.producer_identity);
    hashField(&h, fields.executor_identity);
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
    try validateInput(input, fields);
    try spore.validateRootfsStorageDescriptor(child_storage);
    if (!std.mem.eql(u8, child_storage.index_digest, child_storage.base_identity)) return error.BadManifest;
    try validateChildForInput(input, child_storage);
    if (!try rootfs_cas.storageMarkedComplete(io, allocator, cache_root, child_storage)) return error.RootFSDigestCacheMiss;
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
        .input_digest = fields.input_digest,
        .env_digest = fields.env_digest,
        .workdir = fields.workdir,
        .network_mode = fields.network_mode,
        .memory_bytes = fields.memory_bytes,
        .vcpus = fields.vcpus,
        .nofile_soft = fields.nofile_soft,
        .nofile_hard = fields.nofile_hard,
        .exact_target = fields.exact_target,
        .producer_identity = fields.producer_identity,
        .executor_identity = fields.executor_identity,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, record, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
    // Step keys identify inputs, not immutable outputs. In particular,
    // `--no-cache` may rerun a networked RUN and produce a different valid
    // child snapshot for the same key, so atomically replace this derived map.
    try chunk_sealer.replaceFileAtomicDurable(allocator, path, json, 0o444);
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
    try validateInput(input, fields);
    const computed_key = try stepKey(allocator, input);
    defer allocator.free(computed_key);
    if (!std.mem.eql(u8, computed_key, expected_key)) return error.BuildCacheKeyMismatch;
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
    if (!std.mem.eql(u8, record.builder_version, builder_version)) return null;
    const storage = validChildStorage(record, expected_key) orelse return null;
    if (!std.mem.eql(u8, record.platform.os, input.platform.os) or !std.mem.eql(u8, record.platform.arch, input.platform.arch)) return null;
    if (!std.mem.eql(u8, record.parent_index_digest, input.parent_index_digest)) return null;
    if (!std.mem.eql(u8, record.instruction_kind, fields.instruction_kind)) return null;
    if (!std.mem.eql(u8, record.instruction, input.canonical_instruction)) return null;
    if (!std.mem.eql(u8, record.input_digest, fields.input_digest)) return null;
    if (!std.mem.eql(u8, record.env_digest, fields.env_digest)) return null;
    if (!std.mem.eql(u8, record.workdir, fields.workdir)) return null;
    if (record.network_mode != fields.network_mode) return null;
    if (record.memory_bytes != fields.memory_bytes or record.vcpus != fields.vcpus or
        record.nofile_soft != fields.nofile_soft or record.nofile_hard != fields.nofile_hard) return null;
    if (!recordPreparationFieldsMatch(record, fields)) return null;
    if (!std.mem.eql(u8, record.executor_identity, fields.executor_identity)) return null;
    validateChildForInput(input, storage) catch return null;
    if (!try rootfs_cas.storageMarkedComplete(io, allocator, cache_root, storage)) return null;
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
    if (std.mem.eql(u8, envelope.value.kind, stale_record_kind_v2)) return .stale;
    if (!std.mem.eql(u8, envelope.value.kind, record_kind)) return .unknown;

    var parsed = std.json.parseFromSlice(StepRecord, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return .stale;
    defer parsed.deinit();
    const storage = validChildStorage(parsed.value, expected_key) orelse return .stale;
    if (std.mem.eql(u8, parsed.value.builder_version, legacy_builder_version)) {
        if (!try rootfs_cas.storageMarkedComplete(io, allocator, cache_root, storage) and
            !try rootfs_cas.storageContentComplete(io, allocator, cache_root, storage)) return .stale;
        return .{ .legacy = try spore.cloneRootfsStorage(allocator, storage) };
    }
    if (!std.mem.eql(u8, parsed.value.builder_version, builder_version)) return .unknown;
    const input = currentRecordInput(parsed.value) catch |err| switch (err) {
        error.UnknownBuildOperation => return .unknown,
        else => return .stale,
    };
    const semantic_key = stepKey(allocator, input) catch return .stale;
    defer allocator.free(semantic_key);
    if (!std.mem.eql(u8, semantic_key, expected_key)) return .stale;
    validateChildForInput(input, storage) catch return .stale;
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

fn currentRecordInput(record: StepRecord) !StepInput {
    const no_prepare_fields = record.exact_target == null and record.producer_identity == null;
    const no_resource_fields = record.memory_bytes == null and record.vcpus == null and record.nofile_soft == null and record.nofile_hard == null;
    if (std.mem.eql(u8, record.instruction_kind, "SCRATCH")) {
        const target = record.exact_target orelse return error.MalformedBuildRecord;
        if (!std.mem.eql(u8, record.instruction, "SCRATCH") or record.input_digest.len == 0 or
            record.env_digest.len != 0 or record.workdir.len != 0 or record.network_mode != null or
            !no_resource_fields or record.producer_identity != null or record.executor_identity.len != 0)
        {
            return error.MalformedBuildRecord;
        }
        return scratchInput(record.platform, target, record.input_digest);
    }
    if (std.mem.eql(u8, record.instruction_kind, "PREPARE")) {
        const target = record.exact_target orelse return error.MalformedBuildRecord;
        const producer = record.producer_identity orelse return error.MalformedBuildRecord;
        if (!std.mem.eql(u8, record.instruction, "PREPARE") or record.input_digest.len != 0 or
            record.env_digest.len != 0 or record.workdir.len != 0 or record.network_mode != null or
            !no_resource_fields or record.executor_identity.len != 0) return error.MalformedBuildRecord;
        const input = try prepareInput(record.platform, record.parent_index_digest, target, producer);
        return input;
    }
    if (!no_prepare_fields) return error.MalformedBuildRecord;
    if (std.mem.eql(u8, record.instruction_kind, "RUN")) {
        if (!std.mem.startsWith(u8, record.instruction, "RUN ") or record.input_digest.len != 0 or
            record.network_mode == null or record.memory_bytes == null or record.vcpus == null or
            record.nofile_soft == null or record.nofile_hard == null) return error.MalformedBuildRecord;
        return .{
            .platform = record.platform,
            .parent_index_digest = record.parent_index_digest,
            .canonical_instruction = record.instruction,
            .executor_identity = record.executor_identity,
            .operation = .{ .run = .{
                .env_digest = record.env_digest,
                .workdir = record.workdir,
                .network_mode = record.network_mode.?,
                .memory_bytes = record.memory_bytes,
                .vcpus = record.vcpus,
                .nofile_soft = record.nofile_soft,
                .nofile_hard = record.nofile_hard,
            } },
        };
    }
    if (std.mem.eql(u8, record.instruction_kind, "COPY")) {
        if (!std.mem.startsWith(u8, record.instruction, "COPY ") or record.input_digest.len == 0 or
            record.network_mode != null or !no_resource_fields) return error.MalformedBuildRecord;
        return .{
            .platform = record.platform,
            .parent_index_digest = record.parent_index_digest,
            .canonical_instruction = record.instruction,
            .executor_identity = record.executor_identity,
            .operation = .{ .copy = .{
                .input_digest = record.input_digest,
                .env_digest = record.env_digest,
                .workdir = record.workdir,
            } },
        };
    }
    if (std.mem.eql(u8, record.instruction_kind, "WORKDIR")) {
        if (!std.mem.startsWith(u8, record.instruction, "WORKDIR ") or record.input_digest.len == 0 or
            record.network_mode != null or !no_resource_fields) return error.MalformedBuildRecord;
        return .{
            .platform = record.platform,
            .parent_index_digest = record.parent_index_digest,
            .canonical_instruction = record.instruction,
            .executor_identity = record.executor_identity,
            .operation = .{ .workdir = .{
                .target = record.input_digest,
                .env_digest = record.env_digest,
                .workdir = record.workdir,
            } },
        };
    }
    return error.UnknownBuildOperation;
}

fn validateInput(input: StepInput, fields: StepInput.FlatFields) !void {
    if (!std.mem.eql(u8, input.platform.os, "linux") or !std.mem.eql(u8, input.platform.arch, "arm64")) {
        return error.BadBuildCacheInput;
    }
    validateBlake3Identity(input.parent_index_digest) catch return error.BadBuildCacheInput;
    if (input.canonical_instruction.len == 0) return error.BadBuildCacheInput;

    switch (input.operation) {
        .scratch => |scratch| {
            if (!std.mem.eql(u8, input.canonical_instruction, "SCRATCH")) return error.BadBuildCacheInput;
            if (input.executor_identity.len != 0 or scratch.exact_target == 0 or scratch.format_identity.len == 0) return error.BadBuildCacheInput;
            if (fields.exact_target != scratch.exact_target or fields.producer_identity != null) return error.BadBuildCacheInput;
        },
        .prepare => |prepare| {
            if (!std.mem.eql(u8, input.canonical_instruction, "PREPARE")) return error.BadBuildCacheInput;
            if (input.executor_identity.len != 0) return error.BadBuildCacheInput;
            if (prepare.exact_target == 0) return error.BadBuildCacheInput;
            validateBlake3Identity(prepare.producer_identity) catch return error.BadBuildCacheInput;
            if (fields.exact_target != prepare.exact_target) return error.BadBuildCacheInput;
            const producer_identity = fields.producer_identity orelse return error.BadBuildCacheInput;
            if (!std.mem.eql(u8, producer_identity, prepare.producer_identity)) return error.BadBuildCacheInput;
        },
        .run => |run| {
            validateBlake3Identity(input.executor_identity) catch return error.BadBuildCacheInput;
            if (!std.fs.path.isAbsolute(run.workdir)) return error.BadBuildCacheInput;
        },
        .copy => |copy| {
            validateBlake3Identity(input.executor_identity) catch return error.BadBuildCacheInput;
            if (copy.input_digest.len == 0 or !std.fs.path.isAbsolute(copy.workdir)) return error.BadBuildCacheInput;
        },
        .workdir => |workdir| {
            validateBlake3Identity(input.executor_identity) catch return error.BadBuildCacheInput;
            if (!std.fs.path.isAbsolute(workdir.target) or !std.fs.path.isAbsolute(workdir.workdir)) return error.BadBuildCacheInput;
        },
    }
}

fn validateChildForInput(input: StepInput, storage: spore.RootfsStorage) !void {
    switch (input.operation) {
        .scratch => |scratch| if (storage.logical_size != scratch.exact_target) return error.BadManifest,
        .prepare => |prepare| if (storage.logical_size != prepare.exact_target) return error.BadManifest,
        .run, .copy, .workdir => {},
    }
}

fn recordPreparationFieldsMatch(record: StepRecord, fields: StepInput.FlatFields) bool {
    if (record.exact_target != fields.exact_target) return false;
    if (fields.producer_identity) |expected| {
        const actual = record.producer_identity orelse return false;
        return std.mem.eql(u8, actual, expected);
    }
    return record.producer_identity == null;
}

fn validateBlake3Identity(identity: []const u8) !void {
    const prefix = spore.rootfs_digest_prefix;
    if (identity.len != prefix.len + Blake3.digest_length * 2 or !std.mem.startsWith(u8, identity, prefix)) {
        return error.BadBuildCacheInput;
    }
    for (identity[prefix.len..]) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return error.BadBuildCacheInput;
    }
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

fn hashOptionalField(h: *Blake3, maybe_bytes: ?[]const u8) void {
    if (maybe_bytes) |bytes| {
        h.update("\x01");
        hashField(h, bytes);
    } else {
        h.update("\x00");
    }
}

fn hashOptionalU64(h: *Blake3, maybe_value: ?u64) void {
    if (maybe_value) |value| {
        h.update("\x01");
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, value, .little);
        h.update(&buf);
    } else {
        h.update("\x00");
    }
}

fn hashOptionalU32(h: *Blake3, maybe_value: ?u32) void {
    if (maybe_value) |value| {
        h.update("\x01");
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .little);
        h.update(&buf);
    } else {
        h.update("\x00");
    }
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
        .executor_identity = test_executor_identity,
        .operation = .{ .run = .{ .network_mode = .spore } },
    });
    defer allocator.free(a);
    const b = try stepKey(allocator, .{
        .platform = .{},
        .parent_index_digest = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .canonical_instruction = "RUN true",
        .executor_identity = test_executor_identity,
        .operation = .{ .run = .{ .network_mode = .spore } },
    });
    defer allocator.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));

    const c = try stepKey(allocator, .{
        .platform = .{},
        .parent_index_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .canonical_instruction = "RUN true",
        .executor_identity = "blake3:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        .operation = .{ .run = .{ .network_mode = .spore } },
    });
    defer allocator.free(c);
    try std.testing.expect(!std.mem.eql(u8, a, c));
}

test "prepare input is canonical and key changes with target and producer" {
    const allocator = std.testing.allocator;
    const parent = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const producer_a = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const producer_b = "blake3:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    const input = try prepareInput(.{}, parent, 16 * 1024 * 1024 * 1024, producer_a);
    try std.testing.expectEqualStrings("PREPARE", input.canonical_instruction);

    const base_key = try stepKey(allocator, input);
    defer allocator.free(base_key);
    const target_key = try stepKey(allocator, try prepareInput(.{}, parent, 15 * 1024 * 1024 * 1024, producer_a));
    defer allocator.free(target_key);
    const producer_key = try stepKey(allocator, try prepareInput(.{}, parent, 16 * 1024 * 1024 * 1024, producer_b));
    defer allocator.free(producer_key);
    try std.testing.expect(!std.mem.eql(u8, base_key, target_key));
    try std.testing.expect(!std.mem.eql(u8, base_key, producer_key));
}

test "step key frames variable length fields" {
    const allocator = std.testing.allocator;
    const parent = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const embedded_env = try stepKey(allocator, .{
        .platform = .{},
        .parent_index_digest = parent,
        .canonical_instruction = "RUN true",
        .executor_identity = test_executor_identity,
        .operation = .{ .run = .{
            .env_digest = "A\n/B",
            .workdir = "/C",
            .network_mode = .none,
        } },
    });
    defer allocator.free(embedded_env);
    const embedded_workdir = try stepKey(allocator, .{
        .platform = .{},
        .parent_index_digest = parent,
        .canonical_instruction = "RUN true",
        .executor_identity = test_executor_identity,
        .operation = .{ .run = .{
            .env_digest = "A",
            .workdir = "/B\n/C",
            .network_mode = .none,
        } },
    });
    defer allocator.free(embedded_workdir);
    try std.testing.expect(!std.mem.eql(u8, embedded_env, embedded_workdir));
}

test "step input validation rejects malformed prepare identity and instruction" {
    const allocator = std.testing.allocator;
    const parent = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const producer = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    try std.testing.expectError(error.BadBuildCacheInput, prepareInput(.{}, parent, 0, producer));
    try std.testing.expectError(error.BadBuildCacheInput, prepareInput(.{}, parent, 4096, "blake3:short"));
    try std.testing.expectError(error.BadBuildCacheInput, stepKey(allocator, .{
        .platform = .{},
        .parent_index_digest = parent,
        .canonical_instruction = "not-prepare",
        .operation = .{ .prepare = .{
            .exact_target = 4096,
            .producer_identity = producer,
        } },
    }));
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

test "rewriting a step record replaces a prior child snapshot" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-build-step-cache-replace";
    const cache_root = tmp ++ "/cache";
    const first_rootfs = tmp ++ "/first.ext4";
    const second_rootfs = tmp ++ "/second.ext4";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = first_rootfs, .data = "first snapshot" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = second_rootfs, .data = "second snapshot" });

    const first_preload = try rootfs_cas.preloadPath(io, arena, cache_root, first_rootfs, rootfs_cas.default_chunk_size);
    const first_storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, first_preload);
    const second_preload = try rootfs_cas.preloadPath(io, arena, cache_root, second_rootfs, rootfs_cas.default_chunk_size);
    const second_storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, second_preload);
    const input = StepInput{
        .platform = .{},
        .parent_index_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .canonical_instruction = "RUN fetch-current-packages",
        .executor_identity = test_executor_identity,
        .operation = .{ .run = .{ .network_mode = .spore } },
    };
    const key = try stepKey(arena, input);

    _ = try writeRecord(io, arena, cache_root, input, key, first_storage);
    _ = try writeRecord(io, arena, cache_root, input, key, second_storage);
    const hit = (try readHit(io, arena, cache_root, input, key)) orelse return error.MissingBuildCacheRecord;
    try std.testing.expectEqualStrings(second_storage.index_digest, hit.index_digest);
}

test "prepare record round trips typed identity and exact target" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-build-step-cache-prepare";
    const cache_root = tmp ++ "/cache";
    const child_rootfs = tmp ++ "/prepared.ext4";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = child_rootfs, .data = "prepared rootfs bytes" });

    const preload = try rootfs_cas.preloadPath(io, arena, cache_root, child_rootfs, rootfs_cas.default_chunk_size);
    const storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload);
    const producer = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const input = try prepareInput(
        .{},
        "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        storage.logical_size,
        producer,
    );
    const key = try stepKey(arena, input);
    const path = try writeRecord(io, arena, cache_root, input, key, storage);

    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_step_record_bytes));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"instruction_kind\": \"PREPARE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"instruction\": \"PREPARE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"exact_target\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, producer) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "disk_grow_target") == null);

    const hit = (try readHit(io, arena, cache_root, input, key)) orelse return error.MissingBuildCacheRecord;
    try std.testing.expectEqual(storage.logical_size, hit.logical_size);
    try std.testing.expectEqualStrings(storage.index_digest, hit.index_digest);

    try std.testing.expectError(error.BuildCacheKeyMismatch, readHit(
        io,
        arena,
        cache_root,
        input,
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    ));
}

test "prepare record rejects target mismatch and missing completeness stamp" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-build-step-cache-prepare-validation";
    const cache_root = tmp ++ "/cache";
    const child_rootfs = tmp ++ "/prepared.ext4";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = child_rootfs, .data = "prepared rootfs bytes" });

    const preload = try rootfs_cas.preloadPath(io, arena, cache_root, child_rootfs, rootfs_cas.default_chunk_size);
    const storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload);
    const producer = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const parent = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const wrong_size_input = try prepareInput(.{}, parent, storage.logical_size + 1, producer);
    const wrong_size_key = try stepKey(arena, wrong_size_input);
    try std.testing.expectError(error.BadManifest, writeRecord(io, arena, cache_root, wrong_size_input, wrong_size_key, storage));

    const input = try prepareInput(.{}, parent, storage.logical_size, producer);
    const key = try stepKey(arena, input);
    const path = try writeRecord(io, arena, cache_root, input, key, storage);
    const mismatched_record = StepRecord{
        .kind = record_kind,
        .builder_version = builder_version,
        .platform = .{},
        .step_key = key,
        .parent_index_digest = parent,
        .child_index_digest = storage.index_digest,
        .rootfs_storage = storage,
        .instruction_kind = "PREPARE",
        .instruction = "PREPARE",
        .workdir = "",
        .exact_target = storage.logical_size + 1,
        .producer_identity = producer,
    };
    const mismatched_json = try std.json.Stringify.valueAlloc(arena, mismatched_record, .{
        .emit_null_optional_fields = false,
    });
    try chunk_sealer.replaceFileAtomicDurable(arena, path, mismatched_json, 0o444);
    try std.testing.expect((try readHit(io, arena, cache_root, input, key)) == null);

    _ = try writeRecord(io, arena, cache_root, input, key, storage);
    try rootfs_cas.removeStorageCompleteStamp(io, arena, cache_root, storage.index_digest);
    try std.testing.expect((try readHit(io, arena, cache_root, input, key)) == null);
    try std.testing.expect(!try rootfs_cas.storageMarkedComplete(io, arena, cache_root, storage));
}

test "gc inspection retains complete v6 records with removed fields" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = "zig-cache/test-build-step-cache-v6-gc";
    const cache_root = tmp ++ "/cache";
    const child_rootfs = tmp ++ "/child.ext4";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = child_rootfs, .data = "legacy child rootfs bytes" });

    const preload = try rootfs_cas.preloadPath(io, arena, cache_root, child_rootfs, rootfs_cas.default_chunk_size);
    const storage = rootfs_cas.storageDescriptor(.{ .mmio_slot = 1 }, preload);
    const legacy_key = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    const path = try recordPath(arena, cache_root, legacy_key);
    const parent = std.fs.path.dirname(path) orelse return error.BadManifest;
    try Io.Dir.cwd().createDirPath(io, parent);
    const legacy_json = try std.json.Stringify.valueAlloc(arena, .{
        .kind = record_kind,
        .builder_version = "sporevm-build-v6",
        .platform = rootfs_mod.Platform{},
        .step_key = legacy_key,
        .parent_index_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .child_index_digest = storage.index_digest,
        .rootfs_storage = storage,
        .instruction_kind = "RUN",
        .instruction = "RUN true",
        .disk_grow_target = @as(u64, 9 * 1024 * 1024 * 1024),
    }, .{});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = legacy_json });

    switch (try inspectRecordForGc(io, arena, cache_root, path, legacy_key)) {
        .legacy => |legacy_storage| try std.testing.expectEqualStrings(storage.index_digest, legacy_storage.index_digest),
        .root, .stale, .unknown => return error.MissingBuildCacheRecord,
    }
}
