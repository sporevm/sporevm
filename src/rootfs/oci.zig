const std = @import("std");

const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Platform = struct {
    os: []const u8 = "linux",
    arch: []const u8 = "arm64",

    pub fn parse(raw: []const u8) !Platform {
        const slash = std.mem.indexOfScalar(u8, raw, '/') orelse return error.BadPlatform;
        const os = raw[0..slash];
        const arch = raw[slash + 1 ..];
        if (os.len == 0 or arch.len == 0) return error.BadPlatform;
        if (!std.mem.eql(u8, os, "linux") or !std.mem.eql(u8, arch, "arm64")) {
            return error.UnsupportedPlatform;
        }
        return .{ .os = os, .arch = arch };
    }
};

pub const ImageRef = struct {
    registry: []const u8,
    repository: []const u8,
    digest: []const u8,

    pub fn parse(raw: []const u8) !ImageRef {
        const at = std.mem.lastIndexOfScalar(u8, raw, '@') orelse return error.ImageRefMustBeDigestPinned;
        const name = raw[0..at];
        const digest = raw[at + 1 ..];
        if (!isSha256Digest(digest)) return error.UnsupportedDigest;
        const slash = std.mem.indexOfScalar(u8, name, '/') orelse return error.ImageRefNeedsRegistry;
        const registry = name[0..slash];
        const repository = name[slash + 1 ..];
        if (registry.len == 0 or repository.len == 0) return error.BadImageReference;
        validateRegistry(registry) catch return error.BadImageReference;
        validateRepository(repository) catch return error.BadImageReference;
        return .{ .registry = registry, .repository = repository, .digest = digest };
    }

    pub fn manifestUrl(self: ImageRef, allocator: std.mem.Allocator, digest: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "https://{s}/v2/{s}/manifests/{s}", .{ self.registry, self.repository, digest });
    }

    pub fn blobUrl(self: ImageRef, allocator: std.mem.Allocator, digest: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "https://{s}/v2/{s}/blobs/{s}", .{ self.registry, self.repository, digest });
    }
};

pub const Descriptor = struct {
    mediaType: []const u8,
    digest: []const u8,
    size: ?u64 = null,
    platform: ?DescriptorPlatform = null,
};

pub const DescriptorPlatform = struct {
    architecture: []const u8,
    os: []const u8,
    variant: ?[]const u8 = null,
};

pub const ImageIndex = struct {
    schemaVersion: u32,
    mediaType: ?[]const u8 = null,
    manifests: []Descriptor,
};

pub const ImageManifest = struct {
    schemaVersion: u32,
    mediaType: ?[]const u8 = null,
    config: Descriptor,
    layers: []Descriptor,
};

pub const ImageConfig = struct {
    architecture: ?[]const u8 = null,
    os: ?[]const u8 = null,
    config: ?RuntimeConfig = null,
};

pub const RuntimeConfig = struct {
    Env: ?[][]const u8 = null,
    Entrypoint: ?[][]const u8 = null,
    Cmd: ?[][]const u8 = null,
    WorkingDir: ?[]const u8 = null,
    User: ?[]const u8 = null,
};

pub const LayerMetadata = struct {
    media_type: []const u8,
    digest: []const u8,
};

pub fn selectedManifestDigest(allocator: std.mem.Allocator, bytes: []const u8, platform: Platform) !?[]const u8 {
    if (!try jsonIsIndexMediaType(allocator, bytes)) return null;

    var parsed = try std.json.parseFromSlice(ImageIndex, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.schemaVersion != 2) return error.UnsupportedManifestSchema;

    for (parsed.value.manifests) |desc| {
        if (!isManifestMediaType(desc.mediaType)) continue;
        const p = desc.platform orelse continue;
        if (std.mem.eql(u8, p.os, platform.os) and std.mem.eql(u8, p.architecture, platform.arch)) {
            if (!isSha256Digest(desc.digest)) return error.UnsupportedDigest;
            return desc.digest;
        }
    }
    return error.PlatformManifestNotFound;
}

pub fn jsonIsIndexMediaType(allocator: std.mem.Allocator, bytes: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.BadManifest,
    };
    const media = object.get("mediaType") orelse {
        const manifests = object.get("manifests") orelse return false;
        return switch (manifests) {
            .array => true,
            else => error.BadManifest,
        };
    };
    return switch (media) {
        .string => |s| isIndexMediaType(s),
        else => error.BadManifest,
    };
}

pub fn isIndexMediaType(media_type: []const u8) bool {
    return std.mem.eql(u8, media_type, "application/vnd.oci.image.index.v1+json") or
        std.mem.eql(u8, media_type, "application/vnd.docker.distribution.manifest.list.v2+json");
}

pub fn isManifestMediaType(media_type: []const u8) bool {
    return std.mem.eql(u8, media_type, "application/vnd.oci.image.manifest.v1+json") or
        std.mem.eql(u8, media_type, "application/vnd.docker.distribution.manifest.v2+json");
}

pub fn isSupportedLayerMediaType(media_type: []const u8) bool {
    return isGzipLayerMediaType(media_type) or isPlainTarLayerMediaType(media_type);
}

pub fn isGzipLayerMediaType(media_type: []const u8) bool {
    return std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.v1.tar+gzip") or
        std.mem.eql(u8, media_type, "application/vnd.docker.image.rootfs.diff.tar.gzip") or
        std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.nondistributable.v1.tar+gzip") or
        std.mem.eql(u8, media_type, "application/vnd.docker.image.rootfs.foreign.diff.tar.gzip");
}

pub fn isPlainTarLayerMediaType(media_type: []const u8) bool {
    return std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.v1.tar") or
        std.mem.eql(u8, media_type, "application/vnd.docker.image.rootfs.diff.tar") or
        std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.nondistributable.v1.tar") or
        std.mem.eql(u8, media_type, "application/vnd.docker.image.rootfs.foreign.diff.tar");
}

pub fn verifyDigestBytes(digest: []const u8, bytes: []const u8) !void {
    if (!isSha256Digest(digest)) return error.UnsupportedDigest;
    var h = Sha256.init(.{});
    h.update(bytes);
    var out: [Sha256.digest_length]u8 = undefined;
    h.final(&out);
    const hex = std.fmt.bytesToHex(out, .lower);
    if (!std.ascii.eqlIgnoreCase(digest["sha256:".len..], &hex)) return error.DigestMismatch;
}

pub fn verifyDigestFile(io: Io, digest: []const u8, path: []const u8) !void {
    if (!isSha256Digest(digest)) return error.UnsupportedDigest;
    const hex = try sha256File(io, path);
    if (!std.ascii.eqlIgnoreCase(digest["sha256:".len..], &hex)) return error.DigestMismatch;
}

pub fn isSha256Digest(digest: []const u8) bool {
    if (!std.mem.startsWith(u8, digest, "sha256:")) return false;
    const hex = digest["sha256:".len..];
    if (hex.len != 64) return false;
    for (hex) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn validateRegistry(registry: []const u8) !void {
    for (registry) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == ':')) return error.BadImageReference;
    }
}

fn validateRepository(repository: []const u8) !void {
    for (repository) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-' or c == '/')) return error.BadImageReference;
    }
}

fn sha256File(io: Io, path: []const u8) ![64]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader_buf: [64 * 1024]u8 = undefined;
    var reader: Io.File.Reader = .initStreaming(file, io, &reader_buf);
    var h = Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try reader.interface.readSliceShort(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var out: [Sha256.digest_length]u8 = undefined;
    h.final(&out);
    return std.fmt.bytesToHex(out, .lower);
}

test "digest ref parsing requires explicit registry and sha256 digest" {
    const parsed = try ImageRef.parse("ghcr.io/buildkite/cleanroom-base/alpine@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
    try std.testing.expectEqualStrings("ghcr.io", parsed.registry);
    try std.testing.expectEqualStrings("buildkite/cleanroom-base/alpine", parsed.repository);
    try std.testing.expectError(error.ImageRefMustBeDigestPinned, ImageRef.parse("ghcr.io/buildkite/alpine:latest"));
    try std.testing.expectError(error.ImageRefNeedsRegistry, ImageRef.parse("alpine@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));
}

test "pinned manifest bytes must match requested digest" {
    const index =
        \\{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}
    ;
    try std.testing.expectError(
        error.DigestMismatch,
        verifyDigestBytes("sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", index),
    );
}

test "file digest verification validates digest before slicing" {
    const io = std.testing.io;
    const path = "zig-cache/test-rootfs-oci-digest-file";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "data" });
    try std.testing.expectError(error.UnsupportedDigest, verifyDigestFile(io, "sha256:short", path));
}

test "OCI index detection accepts manifest arrays without mediaType" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try jsonIsIndexMediaType(allocator,
        \\{"schemaVersion":2,"manifests":[]}
    ));
    try std.testing.expect(!try jsonIsIndexMediaType(allocator,
        \\{"schemaVersion":2,"config":{},"layers":[]}
    ));
    try std.testing.expectError(
        error.BadManifest,
        jsonIsIndexMediaType(allocator,
            \\{"schemaVersion":2,"manifests":{}}
        ),
    );
}

test "supported layer media types include gzip and plain tar variants" {
    try std.testing.expect(isSupportedLayerMediaType("application/vnd.oci.image.layer.v1.tar+gzip"));
    try std.testing.expect(isSupportedLayerMediaType("application/vnd.oci.image.layer.v1.tar"));
    try std.testing.expect(isSupportedLayerMediaType("application/vnd.docker.image.rootfs.diff.tar"));
    try std.testing.expect(!isSupportedLayerMediaType("application/vnd.oci.image.layer.v1.tar+zstd"));
}

fn fuzzOCIManifestJson(_: void, s: *std.testing.Smith) !void {
    // OCI manifest/index JSON is registry-controlled input. It must fail
    // closed or parse into the typed structures without panicking.
    var buf: [4096]u8 = undefined;
    const len = s.slice(&buf);
    _ = jsonIsIndexMediaType(std.testing.allocator, buf[0..len]) catch {};
    const parsed = std.json.parseFromSlice(ImageManifest, std.testing.allocator, buf[0..len], .{
        .ignore_unknown_fields = true,
    }) catch return;
    parsed.deinit();
}

test "fuzz OCI manifest parsing" {
    try std.testing.fuzz({}, fuzzOCIManifestJson, .{});
}
