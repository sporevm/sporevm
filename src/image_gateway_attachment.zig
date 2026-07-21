//! Canonical image-gateway attachment records and subject relations.
//!
//! Attachments describe provenance and policy material without entering native
//! image identity. This module is data-only; publication and authorization
//! remain gateway-service responsibilities.

const std = @import("std");
const gateway = @import("image_gateway.zig");

pub const attachment_record_kind = "spore-image-gateway-attachment-v1";
pub const attachment_list_kind = "spore-image-gateway-attachment-list-v1";
pub const max_attachment_record_bytes: usize = 64 * 1024;
pub const max_attachment_list_bytes: usize = 64 * 1024;
pub const max_attachments: usize = 256;
pub const max_artifact_bytes: u64 = 64 * 1024 * 1024;
pub const max_media_type_bytes: usize = 256;

pub const artifact_type_conversion_attestation = "conversion-attestation";
pub const artifact_type_signature = "signature";
pub const artifact_type_sbom = "sbom";
pub const artifact_type_vulnerability_report = "vulnerability-report";
pub const artifact_type_policy_result = "policy-result";

const supported_artifact_types = [_][]const u8{
    artifact_type_conversion_attestation,
    artifact_type_policy_result,
    artifact_type_sbom,
    artifact_type_signature,
    artifact_type_vulnerability_report,
};

pub const ArtifactDescriptor = struct {
    media_type: []const u8,
    bytes: u64,
    transport_digest: []const u8,
};

pub const AttachmentRecord = struct {
    kind: []const u8,
    subject_manifest_digest: []const u8,
    artifact_type: []const u8,
    artifact: ArtifactDescriptor,
};

pub const AttachmentListDescriptor = struct {
    artifact_type: []const u8,
    attachment_digest: []const u8,
};

pub const AttachmentList = struct {
    kind: []const u8,
    subject_manifest_digest: []const u8,
    attachments: []const AttachmentListDescriptor,
};

pub const EncodedAttachment = struct {
    bytes: []u8,
    transport_digest: []u8,

    pub fn deinit(self: EncodedAttachment, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.transport_digest);
    }
};

pub fn parseAttachmentRecord(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) gateway.Error!std.json.Parsed(AttachmentRecord) {
    if (bytes.len == 0 or bytes.len > max_attachment_record_bytes) return error.BadProtocol;
    const parsed = std.json.parseFromSlice(AttachmentRecord, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch |err| return mapParseError(err);
    errdefer parsed.deinit();
    try validateAttachmentRecord(parsed.value);
    const canonical = try canonicalAttachmentRecordAlloc(allocator, parsed.value);
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, bytes, canonical)) return error.BadProtocol;
    return parsed;
}

pub fn encodeAttachmentRecordAlloc(
    allocator: std.mem.Allocator,
    record: AttachmentRecord,
) gateway.Error!EncodedAttachment {
    const bytes = try canonicalAttachmentRecordAlloc(allocator, record);
    errdefer allocator.free(bytes);
    return .{
        .bytes = bytes,
        .transport_digest = try gateway.transportDigestAlloc(allocator, bytes),
    };
}

pub fn parseAttachmentList(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) gateway.Error!std.json.Parsed(AttachmentList) {
    if (bytes.len == 0 or bytes.len > max_attachment_list_bytes) return error.BadProtocol;
    const parsed = std.json.parseFromSlice(AttachmentList, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch |err| return mapParseError(err);
    errdefer parsed.deinit();
    try validateAttachmentList(parsed.value);
    const canonical = try canonicalAttachmentListAlloc(allocator, parsed.value);
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, bytes, canonical)) return error.BadProtocol;
    return parsed;
}

pub fn encodeAttachmentListAlloc(
    allocator: std.mem.Allocator,
    list: AttachmentList,
) gateway.Error!EncodedAttachment {
    const bytes = try canonicalAttachmentListAlloc(allocator, list);
    errdefer allocator.free(bytes);
    return .{
        .bytes = bytes,
        .transport_digest = try gateway.transportDigestAlloc(allocator, bytes),
    };
}

pub fn validateAttachmentRecord(record: AttachmentRecord) gateway.Error!void {
    if (!std.mem.eql(u8, record.kind, attachment_record_kind)) return error.BadProtocol;
    try gateway.validateDigest(record.subject_manifest_digest, "sha256:");
    try validateArtifactType(record.artifact_type);
    try validateMediaType(record.artifact.media_type);
    if (record.artifact.bytes == 0 or record.artifact.bytes > max_artifact_bytes) return error.BadProtocol;
    try gateway.validateDigest(record.artifact.transport_digest, "sha256:");
}

pub fn validateAttachmentList(list: AttachmentList) gateway.Error!void {
    if (!std.mem.eql(u8, list.kind, attachment_list_kind)) return error.BadProtocol;
    try gateway.validateDigest(list.subject_manifest_digest, "sha256:");
    if (list.attachments.len > max_attachments) return error.BadProtocol;
    var previous: ?AttachmentListDescriptor = null;
    for (list.attachments) |descriptor| {
        try validateArtifactType(descriptor.artifact_type);
        try gateway.validateDigest(descriptor.attachment_digest, "sha256:");
        if (previous) |value| {
            if (!attachmentDescriptorLessThan(value, descriptor)) return error.BadProtocol;
        }
        previous = descriptor;
    }
}

/// Verify that canonical attachment bytes are exactly the immutable record
/// selected by a subject relation descriptor.
pub fn verifyListedAttachment(
    allocator: std.mem.Allocator,
    expected_subject_manifest_digest: []const u8,
    descriptor: AttachmentListDescriptor,
    record_bytes: []const u8,
) gateway.Error!std.json.Parsed(AttachmentRecord) {
    try gateway.validateDigest(expected_subject_manifest_digest, "sha256:");
    try validateArtifactType(descriptor.artifact_type);
    try gateway.validateDigest(descriptor.attachment_digest, "sha256:");
    var parsed = try parseAttachmentRecord(allocator, record_bytes);
    errdefer parsed.deinit();
    const record_digest = try gateway.transportDigestAlloc(allocator, record_bytes);
    defer allocator.free(record_digest);
    if (!std.mem.eql(u8, expected_subject_manifest_digest, parsed.value.subject_manifest_digest) or
        !std.mem.eql(u8, descriptor.artifact_type, parsed.value.artifact_type) or
        !std.mem.eql(u8, descriptor.attachment_digest, record_digest)) return error.BadProtocol;
    return parsed;
}

fn canonicalAttachmentRecordAlloc(
    allocator: std.mem.Allocator,
    record: AttachmentRecord,
) gateway.Error![]u8 {
    try validateAttachmentRecord(record);
    const bytes = std.json.Stringify.valueAlloc(allocator, record, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
    errdefer allocator.free(bytes);
    if (bytes.len == 0 or bytes.len > max_attachment_record_bytes) return error.BadProtocol;
    return bytes;
}

fn canonicalAttachmentListAlloc(
    allocator: std.mem.Allocator,
    list: AttachmentList,
) gateway.Error![]u8 {
    try validateAttachmentList(list);
    const bytes = std.json.Stringify.valueAlloc(allocator, list, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
    errdefer allocator.free(bytes);
    if (bytes.len == 0 or bytes.len > max_attachment_list_bytes) return error.BadProtocol;
    return bytes;
}

fn validateArtifactType(value: []const u8) gateway.Error!void {
    for (supported_artifact_types) |supported| {
        if (std.mem.eql(u8, value, supported)) return;
    }
    return error.BadProtocol;
}

fn validateMediaType(value: []const u8) gateway.Error!void {
    if (value.len == 0 or value.len > max_media_type_bytes) return error.BadProtocol;
    var slash: ?usize = null;
    for (value, 0..) |byte, index| {
        if (byte == '/') {
            if (slash != null) return error.BadProtocol;
            slash = index;
            continue;
        }
        if ((byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            std.mem.indexOfScalar(u8, "!#$&^_.+-", byte) != null) continue;
        return error.BadProtocol;
    }
    const separator = slash orelse return error.BadProtocol;
    if (separator == 0 or separator + 1 == value.len) return error.BadProtocol;
}

fn attachmentDescriptorLessThan(a: AttachmentListDescriptor, b: AttachmentListDescriptor) bool {
    const type_order = std.mem.order(u8, a.artifact_type, b.artifact_type);
    if (type_order != .eq) return type_order == .lt;
    return std.mem.order(u8, a.attachment_digest, b.attachment_digest) == .lt;
}

fn mapParseError(err: anyerror) gateway.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadProtocol,
    };
}

fn readFixtureAlloc(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit));
}

fn canonicalFixtureBytes(bytes: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, bytes, "\n")) bytes[0 .. bytes.len - 1] else bytes;
}

test "attachment record golden encoding" {
    const allocator = std.testing.allocator;
    const storage = try readFixtureAlloc(allocator, "test/image-gateway/attachment-record.json", max_attachment_record_bytes);
    defer allocator.free(storage);
    const fixture = canonicalFixtureBytes(storage);
    var parsed = try parseAttachmentRecord(allocator, fixture);
    defer parsed.deinit();
    const encoded = try encodeAttachmentRecordAlloc(allocator, parsed.value);
    defer encoded.deinit(allocator);
    try std.testing.expectEqualStrings(fixture, encoded.bytes);
    try std.testing.expectEqualStrings("sha256:eeec4cf7ace5bb3052c2cce9c554080c57103c785fb1f151f8225eb1c036cffb", encoded.transport_digest);
}

test "attachment list golden encoding and subject binding" {
    const allocator = std.testing.allocator;
    const list_storage = try readFixtureAlloc(allocator, "test/image-gateway/attachment-list.json", max_attachment_list_bytes);
    defer allocator.free(list_storage);
    const list_fixture = canonicalFixtureBytes(list_storage);
    var list = try parseAttachmentList(allocator, list_fixture);
    defer list.deinit();
    const encoded = try encodeAttachmentListAlloc(allocator, list.value);
    defer encoded.deinit(allocator);
    try std.testing.expectEqualStrings(list_fixture, encoded.bytes);
    try std.testing.expectEqualStrings("sha256:d7940e55fceac005a4b189b6cae672a325eb65582e841e58487de243d9b448e4", encoded.transport_digest);

    const record_storage = try readFixtureAlloc(allocator, "test/image-gateway/attachment-record.json", max_attachment_record_bytes);
    defer allocator.free(record_storage);
    var record = try verifyListedAttachment(
        allocator,
        list.value.subject_manifest_digest,
        list.value.attachments[0],
        canonicalFixtureBytes(record_storage),
    );
    defer record.deinit();
    try std.testing.expectEqualStrings(artifact_type_conversion_attestation, record.value.artifact_type);

    try std.testing.expectError(error.BadProtocol, verifyListedAttachment(
        allocator,
        "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        list.value.attachments[0],
        canonicalFixtureBytes(record_storage),
    ));
}

test "attachment parsers reject malformed and oversized inputs" {
    const allocator = std.testing.allocator;
    const malformed = [_]struct { path: []const u8, list: bool }{
        .{ .path = "test/image-gateway/malformed/attachment-duplicate-field.json", .list = false },
        .{ .path = "test/image-gateway/malformed/attachment-unknown-type.json", .list = false },
        .{ .path = "test/image-gateway/malformed/attachment-list-unsorted.json", .list = true },
    };
    for (malformed) |fixture| {
        const storage = try readFixtureAlloc(allocator, fixture.path, max_attachment_list_bytes);
        defer allocator.free(storage);
        if (fixture.list) {
            try std.testing.expectError(error.BadProtocol, parseAttachmentList(allocator, canonicalFixtureBytes(storage)));
        } else {
            try std.testing.expectError(error.BadProtocol, parseAttachmentRecord(allocator, canonicalFixtureBytes(storage)));
        }
    }

    const oversized = try allocator.alloc(u8, max_attachment_record_bytes + 1);
    defer allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.BadProtocol, parseAttachmentRecord(allocator, oversized));
}

fn fuzzAttachmentRecordParse(_: void, smith: *std.testing.Smith) !void {
    var buf: [max_attachment_record_bytes + 1]u8 = undefined;
    const bytes = buf[0..smith.slice(&buf)];
    const parsed = parseAttachmentRecord(std.testing.allocator, bytes) catch return;
    parsed.deinit();
}

test "fuzz gateway attachment-record parser" {
    try std.testing.fuzz({}, fuzzAttachmentRecordParse, .{});
}

fn fuzzAttachmentListParse(_: void, smith: *std.testing.Smith) !void {
    var buf: [max_attachment_list_bytes + 1]u8 = undefined;
    const bytes = buf[0..smith.slice(&buf)];
    const parsed = parseAttachmentList(std.testing.allocator, bytes) catch return;
    parsed.deinit();
}

test "fuzz gateway attachment-list parser" {
    try std.testing.fuzz({}, fuzzAttachmentListParse, .{});
}
