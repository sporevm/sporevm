//! Bounded, canonical image-gateway protocol values.
//!
//! This module owns immutable platform indexes, platform normalization, and
//! transport digests shared by the gateway protocol. It deliberately has no
//! HTTP, registry, filesystem, CAS, or runtime dependency.

const std = @import("std");
const architecture = @import("architecture.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const platform_index_kind = "spore-image-gateway-index-v1";
pub const max_platform_index_bytes: usize = 64 * 1024;
pub const max_platform_manifests: usize = 2;

pub const Error = error{
    BadProtocol,
    AmbiguousPlatform,
    UnsupportedPlatform,
    PlatformNotFound,
    OutOfMemory,
};

/// OCI vocabulary used on the wire and throughout image-platform selection.
pub const Platform = struct {
    os: []const u8,
    arch: architecture.Architecture,

    pub fn eql(a: Platform, b: Platform) bool {
        return std.mem.eql(u8, a.os, b.os) and a.arch == b.arch;
    }
};

pub const OciPlatform = struct {
    os: []const u8,
    architecture: []const u8,
    variant: ?[]const u8 = null,
};

/// Allocation-free source-platform selection shared by gateway protocol code
/// and direct OCI imports. Callers decide which descriptor media types are
/// eligible before passing their platform metadata here.
pub const OciPlatformSelector = struct {
    requested: Platform,
    selected: ?usize = null,

    pub fn init(requested: Platform) Error!OciPlatformSelector {
        try validatePlatform(requested);
        return .{ .requested = requested };
    }

    pub fn consider(self: *OciPlatformSelector, candidate: OciPlatform, index: usize) Error!void {
        // Ignore unrelated OCI targets before normalization so multi-platform
        // indexes and same-media-type attestation descriptors remain usable.
        if (!std.mem.eql(u8, candidate.os, self.requested.os) or
            !std.mem.eql(u8, candidate.architecture, self.requested.arch.name())) return;
        _ = try normalizeOciPlatform(candidate);
        if (self.selected != null) return error.AmbiguousPlatform;
        self.selected = index;
    }

    pub fn finish(self: OciPlatformSelector) Error!usize {
        return self.selected orelse error.PlatformNotFound;
    }
};

pub const ManifestDescriptor = struct {
    platform: Platform,
    manifest_digest: []const u8,
    image_digest: []const u8,
};

pub const PlatformIndex = struct {
    kind: []const u8,
    source_index_digest: ?[]const u8 = null,
    manifests: []const ManifestDescriptor,
};

pub const EncodedPlatformIndex = struct {
    bytes: []u8,
    transport_digest: []u8,

    pub fn deinit(self: EncodedPlatformIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.transport_digest);
    }
};

/// Normalize the two OCI platforms supported by gateway protocol v1.
/// An arm64 descriptor may omit variant or use `v8`; amd64 must omit variant.
pub fn normalizeOciPlatform(platform: OciPlatform) Error!Platform {
    if (!std.mem.eql(u8, platform.os, "linux")) return error.UnsupportedPlatform;
    if (std.mem.eql(u8, platform.architecture, "arm64")) {
        if (platform.variant) |variant| {
            if (!std.mem.eql(u8, variant, "v8")) return error.UnsupportedPlatform;
        }
        return .{ .os = "linux", .arch = .arm64 };
    }
    if (std.mem.eql(u8, platform.architecture, "amd64")) {
        if (platform.variant != null) return error.UnsupportedPlatform;
        return .{ .os = "linux", .arch = .amd64 };
    }
    return error.UnsupportedPlatform;
}

/// Select one source descriptor after v1 normalization. Unrelated OCI
/// platforms are ignored, but two descriptors that normalize to the requested
/// platform are ambiguous and fail closed.
pub fn selectOciPlatformDescriptor(platforms: []const OciPlatform, requested: Platform) Error!usize {
    var selector = try OciPlatformSelector.init(requested);
    for (platforms, 0..) |candidate, index| {
        selector.consider(candidate, index) catch |err| return switch (err) {
            error.AmbiguousPlatform => error.BadProtocol,
            else => err,
        };
    }
    return selector.finish();
}

/// Parse one exact canonical platform-index representation. Unknown or
/// duplicate fields, trailing bytes, reordered descriptors, and alternate JSON
/// formatting fail closed.
pub fn parsePlatformIndex(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) Error!std.json.Parsed(PlatformIndex) {
    if (bytes.len == 0 or bytes.len > max_platform_index_bytes) return error.BadProtocol;
    const parsed = std.json.parseFromSlice(PlatformIndex, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadProtocol,
    };
    errdefer parsed.deinit();
    validatePlatformIndex(parsed.value) catch |err| return switch (err) {
        error.UnsupportedPlatform => error.BadProtocol,
        else => err,
    };
    const canonical = try canonicalPlatformIndexAlloc(allocator, parsed.value);
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, bytes, canonical)) return error.BadProtocol;
    return parsed;
}

pub fn encodePlatformIndexAlloc(
    allocator: std.mem.Allocator,
    index: PlatformIndex,
) Error!EncodedPlatformIndex {
    const bytes = try canonicalPlatformIndexAlloc(allocator, index);
    errdefer allocator.free(bytes);
    return .{
        .bytes = bytes,
        .transport_digest = try transportDigestAlloc(allocator, bytes),
    };
}

pub fn validatePlatformIndex(index: PlatformIndex) Error!void {
    if (!std.mem.eql(u8, index.kind, platform_index_kind)) return error.BadProtocol;
    if (index.source_index_digest) |digest| try validateDigest(digest, "sha256:");
    if (index.manifests.len == 0 or index.manifests.len > max_platform_manifests) return error.BadProtocol;

    var previous: ?Platform = null;
    for (index.manifests) |descriptor| {
        try validatePlatform(descriptor.platform);
        try validateDigest(descriptor.manifest_digest, "sha256:");
        try validateDigest(descriptor.image_digest, "blake3:");
        if (previous) |value| {
            if (!platformLessThan(value, descriptor.platform)) return error.BadProtocol;
        }
        previous = descriptor.platform;
    }
}

pub fn selectManifest(index: PlatformIndex, platform: Platform) Error!ManifestDescriptor {
    try validatePlatformIndex(index);
    try validatePlatform(platform);
    for (index.manifests) |descriptor| {
        if (descriptor.platform.eql(platform)) return descriptor;
    }
    return error.PlatformNotFound;
}

fn canonicalPlatformIndexAlloc(allocator: std.mem.Allocator, index: PlatformIndex) Error![]u8 {
    try validatePlatformIndex(index);
    const bytes = std.json.Stringify.valueAlloc(allocator, index, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    }) catch return error.OutOfMemory;
    errdefer allocator.free(bytes);
    if (bytes.len == 0 or bytes.len > max_platform_index_bytes) return error.BadProtocol;
    return bytes;
}

fn validatePlatform(platform: Platform) Error!void {
    if (!std.mem.eql(u8, platform.os, "linux")) return error.UnsupportedPlatform;
}

fn platformLessThan(a: Platform, b: Platform) bool {
    const os_order = std.mem.order(u8, a.os, b.os);
    if (os_order != .eq) return os_order == .lt;
    return std.mem.order(u8, a.arch.name(), b.arch.name()) == .lt;
}

pub fn validateDigest(digest: []const u8, prefix: []const u8) Error!void {
    if (!std.mem.startsWith(u8, digest, prefix)) return error.BadProtocol;
    const hex = digest[prefix.len..];
    if (hex.len != 64) return error.BadProtocol;
    for (hex) |byte| {
        if ((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f')) continue;
        return error.BadProtocol;
    }
}

/// Name exact protocol bytes by their lowercase SHA-256 transport digest.
pub fn transportDigestAlloc(allocator: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex}) catch return error.OutOfMemory;
}

fn readFixtureAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_platform_index_bytes));
}

fn canonicalFixtureBytes(bytes: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, bytes, "\n")) bytes[0 .. bytes.len - 1] else bytes;
}

test "multi-platform index golden encoding and selection" {
    const allocator = std.testing.allocator;
    const fixture_storage = try readFixtureAlloc(allocator, "test/image-gateway/platform-index.json");
    defer allocator.free(fixture_storage);
    const fixture = canonicalFixtureBytes(fixture_storage);
    var parsed = try parsePlatformIndex(allocator, fixture);
    defer parsed.deinit();

    const encoded = try encodePlatformIndexAlloc(allocator, parsed.value);
    defer encoded.deinit(allocator);
    try std.testing.expectEqualStrings(fixture, encoded.bytes);
    try std.testing.expectEqualStrings(
        "sha256:63e18a7caa38e6c0b7b0d3688bfb44e602c02c9ee869c7f176f0146d362297d8",
        encoded.transport_digest,
    );

    const amd64 = try selectManifest(parsed.value, .{ .os = "linux", .arch = .amd64 });
    const arm64 = try selectManifest(parsed.value, .{ .os = "linux", .arch = .arm64 });
    try std.testing.expectEqualStrings("blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", amd64.image_digest);
    try std.testing.expectEqualStrings("blake3:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", arm64.image_digest);
    try std.testing.expectError(error.UnsupportedPlatform, selectManifest(parsed.value, .{ .os = "windows", .arch = .arm64 }));
    const arm64_only = PlatformIndex{
        .kind = platform_index_kind,
        .manifests = parsed.value.manifests[1..],
    };
    try std.testing.expectError(error.PlatformNotFound, selectManifest(arm64_only, .{ .os = "linux", .arch = .amd64 }));
}

test "native single-platform index golden omits source provenance" {
    const allocator = std.testing.allocator;
    const fixture_storage = try readFixtureAlloc(allocator, "test/image-gateway/platform-index-native.json");
    defer allocator.free(fixture_storage);
    const fixture = canonicalFixtureBytes(fixture_storage);
    var parsed = try parsePlatformIndex(allocator, fixture);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.value.source_index_digest);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.manifests.len);

    const encoded = try encodePlatformIndexAlloc(allocator, parsed.value);
    defer encoded.deinit(allocator);
    try std.testing.expectEqualStrings(fixture, encoded.bytes);
    try std.testing.expectEqualStrings(
        "sha256:1dc55b21130fcb035cbc963298f1bb369a8b5065b3694d65b69c2cda126933dd",
        encoded.transport_digest,
    );
}

test "OCI platform normalization freezes amd64 and arm64 variants" {
    const arm64 = try normalizeOciPlatform(.{ .os = "linux", .architecture = "arm64" });
    const arm64_v8 = try normalizeOciPlatform(.{ .os = "linux", .architecture = "arm64", .variant = "v8" });
    const amd64 = try normalizeOciPlatform(.{ .os = "linux", .architecture = "amd64" });
    try std.testing.expect(arm64.eql(arm64_v8));
    try std.testing.expectEqual(architecture.Architecture.amd64, amd64.arch);
    try std.testing.expectError(error.UnsupportedPlatform, normalizeOciPlatform(.{ .os = "linux", .architecture = "arm64", .variant = "v9" }));
    try std.testing.expectError(error.UnsupportedPlatform, normalizeOciPlatform(.{ .os = "linux", .architecture = "amd64", .variant = "v1" }));
    try std.testing.expectError(error.UnsupportedPlatform, normalizeOciPlatform(.{ .os = "windows", .architecture = "amd64" }));

    const requested = Platform{ .os = "linux", .arch = .arm64 };
    const one = [_]OciPlatform{
        .{ .os = "windows", .architecture = "arm64" },
        .{ .os = "linux", .architecture = "arm64", .variant = "v8" },
    };
    try std.testing.expectEqual(@as(usize, 1), try selectOciPlatformDescriptor(&one, requested));
    const ambiguous = [_]OciPlatform{
        .{ .os = "linux", .architecture = "arm64" },
        .{ .os = "linux", .architecture = "arm64", .variant = "v8" },
    };
    try std.testing.expectError(error.BadProtocol, selectOciPlatformDescriptor(&ambiguous, requested));
    const unsupported = [_]OciPlatform{
        .{ .os = "linux", .architecture = "arm64", .variant = "v9" },
    };
    try std.testing.expectError(error.UnsupportedPlatform, selectOciPlatformDescriptor(&unsupported, requested));
}

test "malformed platform-index fixtures fail closed" {
    const allocator = std.testing.allocator;
    inline for (.{
        "test/image-gateway/malformed/duplicate-platform.json",
        "test/image-gateway/malformed/duplicate-field.json",
        "test/image-gateway/malformed/noncanonical.json",
        "test/image-gateway/malformed/uppercase-digest.json",
    }) |path| {
        const fixture_storage = try readFixtureAlloc(allocator, path);
        defer allocator.free(fixture_storage);
        try std.testing.expectError(error.BadProtocol, parsePlatformIndex(allocator, canonicalFixtureBytes(fixture_storage)));
    }
}

test "platform-index byte and descriptor bounds fail closed" {
    const allocator = std.testing.allocator;
    const oversized = try allocator.alloc(u8, max_platform_index_bytes + 1);
    defer allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.BadProtocol, parsePlatformIndex(allocator, oversized));

    const descriptor = ManifestDescriptor{
        .platform = .{ .os = "linux", .arch = .arm64 },
        .manifest_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .image_digest = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    };
    const too_many = [_]ManifestDescriptor{ descriptor, descriptor, descriptor };
    try std.testing.expectError(error.BadProtocol, validatePlatformIndex(.{
        .kind = platform_index_kind,
        .manifests = &too_many,
    }));
}

test "wire parser rejects trailing bytes and unsupported platform fields" {
    const allocator = std.testing.allocator;
    const fixture_storage = try readFixtureAlloc(allocator, "test/image-gateway/platform-index.json");
    defer allocator.free(fixture_storage);
    const fixture = canonicalFixtureBytes(fixture_storage);
    inline for (.{ "\n", " ", "{}" }) |suffix| {
        const trailing = try std.mem.concat(allocator, u8, &.{ fixture, suffix });
        defer allocator.free(trailing);
        try std.testing.expectError(error.BadProtocol, parsePlatformIndex(allocator, trailing));
    }

    const unsupported =
        \\{"kind":"spore-image-gateway-index-v1","manifests":[{"platform":{"os":"linux","arch":"riscv64"},"manifest_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","image_digest":"blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}
    ;
    try std.testing.expectError(error.BadProtocol, parsePlatformIndex(allocator, unsupported));
    const variant =
        \\{"kind":"spore-image-gateway-index-v1","manifests":[{"platform":{"os":"linux","arch":"arm64","variant":"v8"},"manifest_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","image_digest":"blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}
    ;
    try std.testing.expectError(error.BadProtocol, parsePlatformIndex(allocator, variant));

    const invalid_utf8 = try allocator.dupe(u8, fixture);
    defer allocator.free(invalid_utf8);
    const linux = std.mem.indexOf(u8, invalid_utf8, "linux") orelse unreachable;
    invalid_utf8[linux] = 0xff;
    try std.testing.expectError(error.BadProtocol, parsePlatformIndex(allocator, invalid_utf8));
}

fn fuzzPlatformIndexParse(_: void, smith: *std.testing.Smith) !void {
    var buf: [max_platform_index_bytes + 1]u8 = undefined;
    const bytes = buf[0..smith.slice(&buf)];
    const parsed = parsePlatformIndex(std.testing.allocator, bytes) catch return;
    parsed.deinit();
}

test "fuzz gateway platform-index parser" {
    try std.testing.fuzz({}, fuzzPlatformIndexParse, .{});
}
