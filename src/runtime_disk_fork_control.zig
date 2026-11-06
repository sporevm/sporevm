//! Versioned local control messages for runtime disk-fork batch capture.

const std = @import("std");

const runtime_disk_claim = @import("runtime_disk_claim.zig");
const runtime_disk_fork = @import("runtime_disk_fork.zig");
const runtime_disk_lease = @import("runtime_disk_lease.zig");
const spore = @import("spore.zig");

pub const prepare_type = "disk-fork-prepare";
pub const prepare_schema = "spore.disk-fork-prepare.v1";
pub const prepared_type = "disk-fork-prepared";
pub const prepared_schema = "spore.disk-fork-prepared.v1";
pub const cancel_type = "disk-fork-cancel";
pub const cancel_schema = "spore.disk-fork-cancel.v1";
pub const max_capture_dir_bytes = 4096;

pub const PrepareRequest = struct {
    pub const wire_type = prepare_type;

    type: []const u8,
    schema: []const u8,
    out_dir: []const u8,
    batch: []const u8,
    children: []const []const u8,
    allow_copy: bool = false,
    force_copy: bool = false,
};

pub const CancelRequest = struct {
    pub const wire_type = cancel_type;

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
    pub const wire_type = prepared_type;

    type: []const u8,
    schema: []const u8,
    batch: []const u8,
    capture_dir: []const u8,
    claims: []const PreparedClaim,
    /// The baseline every claim shares, as the source recorded it in its
    /// spec, and the source disk it belongs to. Children run on both.
    lease: runtime_disk_lease.Lease,
    disk: ?spore.Disk,
    ram_capture_ns: u64,
    disk_fork_ns: u64,
    source_pause_ns: u64,
    copied_bytes: u64,
};

pub fn validateCancel(request: CancelRequest) !void {
    if (!std.mem.eql(u8, request.type, cancel_type) or
        !std.mem.eql(u8, request.schema, cancel_schema) or
        !runtime_disk_claim.validBindingName(request.batch, runtime_disk_claim.max_batch_name_bytes)) return error.BadControlRequest;
}

pub fn validatePrepare(request: PrepareRequest) !void {
    if (!std.mem.eql(u8, request.type, prepare_type) or !std.mem.eql(u8, request.schema, prepare_schema)) return error.BadControlRequest;
    if (request.out_dir.len == 0 or request.out_dir.len > max_capture_dir_bytes) return error.BadControlRequest;
    try validateBindings(request.batch, request.children, request.allow_copy, request.force_copy);
}

pub fn validatePrepared(response: PreparedResponse) !void {
    if (!std.mem.eql(u8, response.type, prepared_type) or !std.mem.eql(u8, response.schema, prepared_schema)) return error.BadControlResponse;
    if (response.capture_dir.len == 0 or response.capture_dir.len > max_capture_dir_bytes) return error.BadControlResponse;
    if (response.claims.len == 0 or response.claims.len > runtime_disk_claim.max_children_per_batch) return error.BadControlResponse;
    response.lease.validate() catch return error.BadControlResponse;
    if (response.disk) |disk| {
        if (response.lease.baseline_kind != .disk_index or !std.mem.eql(u8, disk.base, response.lease.baseline_identity)) return error.BadControlResponse;
    }
    var child_names: [runtime_disk_claim.max_children_per_batch][]const u8 = undefined;
    for (response.claims, 0..) |claim, index| {
        if (claim.child_index != index) return error.BadControlResponse;
        child_names[index] = claim.child;
        runtime_disk_claim.validateClaimRequest(.{
            .type = runtime_disk_claim.claim_type,
            .schema = runtime_disk_claim.claim_schema,
            .token = claim.token,
            .batch = response.batch,
            .child = claim.child,
            .child_index = claim.child_index,
            .baseline_kind = claim.baseline_kind,
            .baseline_identity = claim.baseline_identity,
        }) catch return error.BadControlResponse;
        if (claim.baseline_kind != response.lease.baseline_kind or !std.mem.eql(u8, claim.baseline_identity, response.lease.baseline_identity)) return error.BadControlResponse;
    }
    validateBindings(response.batch, child_names[0..response.claims.len], false, false) catch return error.BadControlResponse;
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
