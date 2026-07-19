const std = @import("std");
const architecture = @import("../architecture.zig");
const image = @import("../image.zig");
const image_gateway = @import("../image_gateway.zig");

const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Platform = struct {
    os: []const u8 = "linux",
    arch: architecture.Architecture = .arm64,

    pub fn parse(raw: []const u8) !Platform {
        const slash = std.mem.indexOfScalar(u8, raw, '/') orelse return error.BadPlatform;
        const os = raw[0..slash];
        const arch = raw[slash + 1 ..];
        if (os.len == 0 or arch.len == 0) return error.BadPlatform;
        if (!std.mem.eql(u8, os, "linux")) return error.UnsupportedPlatform;
        const parsed_arch = architecture.Architecture.parse(arch) catch return error.UnsupportedPlatform;
        return .{ .os = os, .arch = parsed_arch };
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
        const parsed = try parseImageName(name);
        return .{ .registry = parsed.registry, .repository = parsed.repository, .digest = digest };
    }

    pub fn manifestUrl(self: ImageRef, allocator: std.mem.Allocator, digest: []const u8) ![]u8 {
        return manifestUrlFor(allocator, self.registry, self.repository, digest);
    }

    pub fn blobUrl(self: ImageRef, allocator: std.mem.Allocator, digest: []const u8) ![]u8 {
        return blobUrlFor(allocator, self.registry, self.repository, digest);
    }
};

pub const ImageTag = struct {
    registry: []const u8,
    repository: []const u8,
    tag: []const u8,

    pub fn parse(raw: []const u8) !ImageTag {
        if (std.mem.indexOfScalar(u8, raw, '@') != null) return error.BadImageReference;
        const last_slash = std.mem.lastIndexOfScalar(u8, raw, '/') orelse return error.ImageRefNeedsRegistry;
        const tag_colon = std.mem.lastIndexOfScalar(u8, raw, ':') orelse return error.ImageTagRequired;
        if (tag_colon < last_slash) return error.ImageTagRequired;

        const parsed = try parseImageName(raw[0..tag_colon]);
        const tag = raw[tag_colon + 1 ..];
        validateTag(tag) catch return error.BadImageReference;
        return .{ .registry = parsed.registry, .repository = parsed.repository, .tag = tag };
    }

    pub fn manifestUrl(self: ImageTag, allocator: std.mem.Allocator) ![]u8 {
        return manifestUrlFor(allocator, self.registry, self.repository, self.tag);
    }

    pub fn digestRef(self: ImageTag, allocator: std.mem.Allocator, digest: []const u8) ![]u8 {
        if (!isSha256Digest(digest)) return error.UnsupportedDigest;
        return std.fmt.allocPrint(allocator, "{s}/{s}@{s}", .{ self.registry, self.repository, digest });
    }
};

const ImageName = struct {
    registry: []const u8,
    repository: []const u8,
};

fn parseImageName(name: []const u8) !ImageName {
    const slash = std.mem.indexOfScalar(u8, name, '/') orelse return error.ImageRefNeedsRegistry;
    const registry = name[0..slash];
    const repository = name[slash + 1 ..];
    if (registry.len == 0 or repository.len == 0) return error.BadImageReference;
    validateRegistry(registry) catch return error.BadImageReference;
    validateRepository(repository) catch return error.BadImageReference;
    return .{ .registry = registry, .repository = repository };
}

fn manifestUrlFor(allocator: std.mem.Allocator, registry: []const u8, repository: []const u8, reference: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "https://{s}/v2/{s}/manifests/{s}", .{ registryApiHost(registry), repository, reference });
}

fn blobUrlFor(allocator: std.mem.Allocator, registry: []const u8, repository: []const u8, digest: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "https://{s}/v2/{s}/blobs/{s}", .{ registryApiHost(registry), repository, digest });
}

fn registryApiHost(registry: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(registry, "docker.io")) return "registry-1.docker.io";
    return registry;
}

pub const Descriptor = struct {
    mediaType: []const u8,
    digest: []const u8,
    size: ?u64 = null,
    platform: ?DescriptorPlatform = null,
};

pub const DescriptorPlatform = image_gateway.OciPlatform;
const PlatformSelector = image_gateway.OciPlatformSelector;

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

pub const ImageConfig = image.Config;
pub const RuntimeConfig = image.RuntimeConfig;

pub const LayerMetadata = struct {
    media_type: []const u8,
    digest: []const u8,
};

/// Select one eligible image manifest using the gateway's platform
/// normalization and ambiguity rules. Non-image descriptors and descriptors
/// without platform metadata are not runtime image candidates.
pub fn selectImageManifestIndex(manifests: []const Descriptor, platform: Platform) !usize {
    var selector = try PlatformSelector.init(.{ .os = platform.os, .arch = platform.arch });
    for (manifests, 0..) |desc, index| {
        if (!isManifestMediaType(desc.mediaType)) continue;
        const candidate = desc.platform orelse continue;
        selector.consider(candidate, index) catch |err| return switch (err) {
            error.AmbiguousPlatform => error.AmbiguousPlatformManifest,
            else => err,
        };
    }
    const index = selector.finish() catch |err| return switch (err) {
        error.PlatformNotFound => error.PlatformManifestNotFound,
        else => err,
    };
    if (!isSha256Digest(manifests[index].digest)) return error.UnsupportedDigest;
    return index;
}

pub fn selectedManifestDigest(allocator: std.mem.Allocator, bytes: []const u8, platform: Platform) !?[]const u8 {
    if (!try jsonIsIndexMediaType(allocator, bytes)) return null;

    var parsed = try std.json.parseFromSlice(ImageIndex, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.schemaVersion != 2) return error.UnsupportedManifestSchema;

    const desc = parsed.value.manifests[try selectImageManifestIndex(parsed.value.manifests, platform)];
    return try allocator.dupe(u8, desc.digest);
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

pub fn isConfigMediaType(media_type: []const u8) bool {
    return std.mem.eql(u8, media_type, "application/vnd.oci.image.config.v1+json") or
        std.mem.eql(u8, media_type, "application/vnd.docker.container.image.v1+json");
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

pub fn digestBytesAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var h = Sha256.init(.{});
    h.update(bytes);
    var out: [Sha256.digest_length]u8 = undefined;
    h.final(&out);
    const hex = std.fmt.bytesToHex(out, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{&hex});
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

fn validateTag(tag: []const u8) !void {
    if (tag.len == 0 or tag.len > 128) return error.BadImageReference;
    if (!(std.ascii.isAlphanumeric(tag[0]) or tag[0] == '_')) return error.BadImageReference;
    for (tag[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return error.BadImageReference;
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

test "tag ref parsing supports registry ports and validates docker tags" {
    const parsed = try ImageTag.parse("registry.example:5000/team/repo:v1.2_3");
    try std.testing.expectEqualStrings("registry.example:5000", parsed.registry);
    try std.testing.expectEqualStrings("team/repo", parsed.repository);
    try std.testing.expectEqualStrings("v1.2_3", parsed.tag);

    const url = try parsed.manifestUrl(std.testing.allocator);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://registry.example:5000/v2/team/repo/manifests/v1.2_3", url);

    try std.testing.expectError(error.ImageRefNeedsRegistry, ImageTag.parse("alpine:latest"));
    try std.testing.expectError(error.ImageTagRequired, ImageTag.parse("registry.example:5000/team/repo"));
    try std.testing.expectError(error.BadImageReference, ImageTag.parse("registry.example/team/repo:bad+tag"));
}

test "docker.io references fetch from Docker Hub registry API" {
    const tag = try ImageTag.parse("docker.io/library/alpine:3.20");
    const tag_url = try tag.manifestUrl(std.testing.allocator);
    defer std.testing.allocator.free(tag_url);
    try std.testing.expectEqualStrings("https://registry-1.docker.io/v2/library/alpine/manifests/3.20", tag_url);

    const image_ref = try ImageRef.parse("docker.io/library/alpine@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
    const manifest_url = try image_ref.manifestUrl(
        std.testing.allocator,
        "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    );
    defer std.testing.allocator.free(manifest_url);
    try std.testing.expectEqualStrings(
        "https://registry-1.docker.io/v2/library/alpine/manifests/sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        manifest_url,
    );
}

test "platform parsing accepts OCI names and rejects backend aliases" {
    try std.testing.expectEqual(architecture.Architecture.arm64, (try Platform.parse("linux/arm64")).arch);
    try std.testing.expectEqual(architecture.Architecture.amd64, (try Platform.parse("linux/amd64")).arch);
    try std.testing.expectError(error.UnsupportedPlatform, Platform.parse("linux/aarch64"));
    try std.testing.expectError(error.UnsupportedPlatform, Platform.parse("linux/x86_64"));
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

test "manifest digest allocation returns sha256 digest ref" {
    const digest = try digestBytesAlloc(std.testing.allocator, "data");
    defer std.testing.allocator.free(digest);
    try std.testing.expectEqualStrings(
        "sha256:3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7",
        digest,
    );
}

test "file digest verification validates digest before slicing" {
    const io = std.testing.io;
    const path = "zig-cache/test-rootfs-oci-digest-file";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "data" });
    try std.testing.expectError(error.UnsupportedDigest, verifyDigestFile(io, "sha256:short", path));
}

test "selected manifest digest is caller-owned" {
    const allocator = std.testing.allocator;
    const selected = try selectedManifestDigest(
        allocator,
        "{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.index.v1+json\",\"manifests\":[{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"sha256:\\u0030aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"platform\":{\"os\":\"linux\",\"architecture\":\"arm64\"}}]}",
        .{},
    ) orelse return error.TestExpectedEqual;
    defer allocator.free(selected);
    try std.testing.expectEqualStrings("sha256:0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", selected);
}

test "manifest selection distinguishes both OCI architectures" {
    const allocator = std.testing.allocator;
    const index =
        \\{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","platform":{"os":"linux","architecture":"arm64"}},{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","platform":{"os":"linux","architecture":"amd64"}}]}
    ;
    const arm64 = (try selectedManifestDigest(allocator, index, .{ .arch = .arm64 })).?;
    defer allocator.free(arm64);
    const amd64 = (try selectedManifestDigest(allocator, index, .{ .arch = .amd64 })).?;
    defer allocator.free(amd64);
    try std.testing.expectEqualStrings("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", arm64);
    try std.testing.expectEqualStrings("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", amd64);
}

test "manifest selection normalizes variants and rejects ambiguity" {
    const allocator = std.testing.allocator;
    const arm64_v8 =
        \\{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","platform":{"os":"linux","architecture":"arm64","variant":"v8"}}]}
    ;
    const selected = (try selectedManifestDigest(allocator, arm64_v8, .{})).?;
    defer allocator.free(selected);
    try std.testing.expectEqualStrings("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", selected);

    const ambiguous =
        \\{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","platform":{"os":"linux","architecture":"arm64"}},{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","platform":{"os":"linux","architecture":"arm64","variant":"v8"}}]}
    ;
    try std.testing.expectError(error.AmbiguousPlatformManifest, selectedManifestDigest(allocator, ambiguous, .{}));

    const unsupported =
        \\{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","platform":{"os":"linux","architecture":"arm64","variant":"v9"}}]}
    ;
    try std.testing.expectError(error.UnsupportedPlatform, selectedManifestDigest(allocator, unsupported, .{}));
}

test "manifest selection ignores non-runtime descriptors in a multi-platform index" {
    const allocator = std.testing.allocator;
    const index =
        \\{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","platform":{"os":"unknown","architecture":"unknown"}},{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","platform":{"os":"linux","architecture":"arm64"}},{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222"},{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:3333333333333333333333333333333333333333333333333333333333333333","platform":{"os":"linux","architecture":"arm","variant":"v7"}},{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","platform":{"os":"linux","architecture":"amd64"}},{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","platform":{"os":"linux","architecture":"arm64","variant":"v8"}}]}
    ;
    const amd64 = (try selectedManifestDigest(allocator, index, .{ .arch = .amd64 })).?;
    defer allocator.free(amd64);
    const arm64 = (try selectedManifestDigest(allocator, index, .{ .arch = .arm64 })).?;
    defer allocator.free(arm64);
    try std.testing.expectEqualStrings("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", amd64);
    try std.testing.expectEqualStrings("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", arm64);
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
    try std.testing.expect(isConfigMediaType("application/vnd.oci.image.config.v1+json"));
    try std.testing.expect(isConfigMediaType("application/vnd.docker.container.image.v1+json"));
    try std.testing.expect(!isConfigMediaType("application/octet-stream"));
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
    if (selectedManifestDigest(std.testing.allocator, buf[0..len], .{})) |selected| {
        if (selected) |digest| std.testing.allocator.free(digest);
    } else |_| {}
    const parsed = std.json.parseFromSlice(ImageManifest, std.testing.allocator, buf[0..len], .{
        .ignore_unknown_fields = true,
    }) catch return;
    parsed.deinit();
}

test "fuzz OCI manifest parsing" {
    try std.testing.fuzz({}, fuzzOCIManifestJson, .{});
}
