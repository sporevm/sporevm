//! Versioned local control messages for runtime disk-fork batch capture.

const std = @import("std");

const runtime_disk_claim = @import("runtime_disk_claim.zig");
const runtime_disk_fork = @import("runtime_disk_fork.zig");

pub const prepare_type = "disk-fork-prepare";
pub const prepare_schema = "spore.disk-fork-prepare.v1";
pub const prepared_type = "disk-fork-prepared";
pub const prepared_schema = "spore.disk-fork-prepared.v1";
pub const cancel_type = "disk-fork-cancel";
pub const cancel_schema = "spore.disk-fork-cancel.v1";
pub const max_capture_dir_bytes = 4096;

pub const PrepareRequest = struct {
    type: []const u8,
    schema: []const u8,
    out_dir: []const u8,
    batch: []const u8,
    children: []const []const u8,
    allow_copy: bool = false,
    force_copy: bool = false,
};

pub const CancelRequest = struct {
    type: []const u8,
    schema: []const u8,
    batch: []const u8,
};

pub const PreparedClaim = struct {
    child: []const u8,
    child_index: u32,
    token: []const u8,
    baseline_kind: runtime_disk_fork.BaselineKind,
    baseline_identity: []const u8,
};

pub const PreparedResponse = struct {
    type: []const u8 = prepared_type,
    schema: []const u8 = prepared_schema,
    batch: []const u8,
    capture_dir: []const u8,
    claims: []const PreparedClaim,
    ram_capture_ns: u64,
    disk_fork_ns: u64,
    source_pause_ns: u64,
    copied_bytes: u64,
};

pub fn parsePrepareBytes(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(PrepareRequest) {
    if (bytes.len == 0 or bytes.len >= runtime_disk_claim.max_claim_request_bytes) return error.BadControlRequest;
    var parsed = std.json.parseFromSlice(PrepareRequest, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch return error.BadControlRequest;
    errdefer parsed.deinit();
    try validatePrepare(parsed.value);
    return parsed;
}

pub fn parseCancelBytes(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(CancelRequest) {
    if (bytes.len == 0 or bytes.len >= runtime_disk_claim.max_claim_request_bytes) return error.BadControlRequest;
    var parsed = std.json.parseFromSlice(CancelRequest, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch return error.BadControlRequest;
    errdefer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.type, cancel_type) or
        !std.mem.eql(u8, parsed.value.schema, cancel_schema) or
        !runtime_disk_claim.validBindingName(parsed.value.batch, runtime_disk_claim.max_batch_name_bytes)) return error.BadControlRequest;
    return parsed;
}

pub fn validatePrepare(request: PrepareRequest) !void {
    if (!std.mem.eql(u8, request.type, prepare_type) or !std.mem.eql(u8, request.schema, prepare_schema)) return error.BadControlRequest;
    if (request.out_dir.len == 0 or request.out_dir.len > max_capture_dir_bytes) return error.BadControlRequest;
    try validateBindings(request.batch, request.children, request.allow_copy, request.force_copy);
}

pub fn validateBindings(batch: []const u8, children: []const []const u8, allow_copy: bool, force_copy: bool) !void {
    if (!runtime_disk_claim.validBindingName(batch, runtime_disk_claim.max_batch_name_bytes)) return error.BadBatch;
    if (children.len == 0 or children.len > runtime_disk_claim.max_children_per_batch) return error.InvalidForkCount;
    if (force_copy and !allow_copy) return error.SlowCopyNotAllowed;
    var rendered_name_bytes: usize = 0;
    for (children, 0..) |child, index| {
        if (!runtime_disk_claim.validBindingName(child, runtime_disk_claim.max_child_name_bytes)) return error.BadBatch;
        rendered_name_bytes = std.math.add(usize, rendered_name_bytes, child.len) catch return error.BadBatch;
        if (rendered_name_bytes > runtime_disk_claim.max_rendered_child_name_bytes) return error.BadBatch;
        for (children[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier, child)) return error.DuplicateChild;
        }
    }
}

test "prepare and cancel requests are strict and versioned" {
    const allocator = std.testing.allocator;
    var prepare = try parsePrepareBytes(allocator,
        \\{"type":"disk-fork-prepare","schema":"spore.disk-fork-prepare.v1","out_dir":"/tmp/capture","batch":"batch-1","children":["child-0","child-1"]}
    );
    defer prepare.deinit();
    try std.testing.expectEqual(@as(usize, 2), prepare.value.children.len);
    try std.testing.expectError(error.BadControlRequest, parsePrepareBytes(allocator,
        \\{"type":"disk-fork-prepare","schema":"spore.disk-fork-prepare.v1","out_dir":"/tmp/capture","batch":"batch-1","children":["child-0"],"extra":true}
    ));
    var cancel = try parseCancelBytes(allocator,
        \\{"type":"disk-fork-cancel","schema":"spore.disk-fork-cancel.v1","batch":"batch-1"}
    );
    defer cancel.deinit();
}

fn fuzzPrepare(_: void, smith: *std.testing.Smith) anyerror!void {
    var bytes: [runtime_disk_claim.max_claim_request_bytes]u8 = undefined;
    const len = smith.slice(&bytes);
    var parsed = parsePrepareBytes(std.testing.allocator, bytes[0..len]) catch return;
    defer parsed.deinit();
}

test "fuzz runtime disk fork prepare parser" {
    try std.testing.fuzz({}, fuzzPrepare, .{});
}
