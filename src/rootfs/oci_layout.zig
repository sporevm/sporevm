//! Local OCI image layout reader.
//!
//! Docker buildx can emit an OCI layout tar without pushing to a registry. This
//! module treats that tar or directory as attacker-influenced builder input:
//! paths are constrained, every blob file is SHA256-verified, and unsupported
//! manifest/layer media types fail closed.

const std = @import("std");
const oci = @import("oci.zig");
const tar = @import("tar.zig");

const Io = std.Io;

const max_layout_metadata_bytes: usize = 32 << 20;
const max_layout_config_bytes: usize = 64 << 20;
const max_layout_tar_entries: u64 = 1_000_000;
const max_layout_tar_payload_bytes: u64 = tar.max_content_bytes;

pub const LayerBlob = struct {
    media_type: []const u8,
    digest: []const u8,
    path: []const u8,
};

pub const SelectedImage = struct {
    manifest_digest: []const u8,
    manifest_bytes: []const u8,
    config_digest: []const u8,
    config_bytes: []const u8,
    layers: []LayerBlob,
};

const LayoutFile = struct {
    imageLayoutVersion: []const u8,
};

const SelectedDescriptor = struct {
    digest: []const u8,
    size: ?u64,
};

pub fn readSelectedImage(
    allocator: std.mem.Allocator,
    io: Io,
    layout_dir: []const u8,
    platform: oci.Platform,
) !SelectedImage {
    try validateLayoutFile(allocator, io, layout_dir);
    try verifyAllBlobs(allocator, io, layout_dir);

    const index_path = try std.fs.path.join(allocator, &.{ layout_dir, "index.json" });
    defer allocator.free(index_path);
    const index_bytes = try readRegularFileAlloc(io, allocator, index_path, max_layout_metadata_bytes);
    defer allocator.free(index_bytes);
    const descriptor = try selectManifestDescriptor(allocator, index_bytes, platform);

    const manifest_path = try blobPath(allocator, layout_dir, descriptor.digest);
    defer allocator.free(manifest_path);
    try verifyDescriptorFile(io, manifest_path, descriptor.digest, descriptor.size);
    const manifest_bytes = try readRegularFileAlloc(io, allocator, manifest_path, max_layout_metadata_bytes);
    try oci.verifyDigestBytes(descriptor.digest, manifest_bytes);

    var manifest_parsed = try std.json.parseFromSlice(oci.ImageManifest, allocator, manifest_bytes, .{ .ignore_unknown_fields = true });
    defer manifest_parsed.deinit();
    const manifest = manifest_parsed.value;
    if (manifest.schemaVersion != 2) return error.UnsupportedManifestSchema;
    if (manifest.mediaType) |media_type| {
        if (!oci.isManifestMediaType(media_type)) return error.UnsupportedManifestMediaType;
    }
    if (!oci.isConfigMediaType(manifest.config.mediaType)) return error.UnsupportedConfigMediaType;
    if (!oci.isSha256Digest(manifest.config.digest)) return error.UnsupportedDigest;

    const config_path = try blobPath(allocator, layout_dir, manifest.config.digest);
    defer allocator.free(config_path);
    try verifyDescriptorFile(io, config_path, manifest.config.digest, manifest.config.size);
    const config_bytes = try readRegularFileAlloc(io, allocator, config_path, max_layout_config_bytes);
    try oci.verifyDigestBytes(manifest.config.digest, config_bytes);

    const layers = try allocator.alloc(LayerBlob, manifest.layers.len);
    for (manifest.layers, 0..) |layer, i| {
        if (!oci.isSupportedLayerMediaType(layer.mediaType)) return error.UnsupportedLayerMediaType;
        if (!oci.isSha256Digest(layer.digest)) return error.UnsupportedDigest;
        const path = try blobPath(allocator, layout_dir, layer.digest);
        try verifyDescriptorFile(io, path, layer.digest, layer.size);
        layers[i] = .{
            .media_type = try allocator.dupe(u8, layer.mediaType),
            .digest = try allocator.dupe(u8, layer.digest),
            .path = path,
        };
    }

    return .{
        .manifest_digest = descriptor.digest,
        .manifest_bytes = manifest_bytes,
        .config_digest = try allocator.dupe(u8, manifest.config.digest),
        .config_bytes = config_bytes,
        .layers = layers,
    };
}

pub fn extractTarToDir(
    allocator: std.mem.Allocator,
    io: Io,
    tar_path: []const u8,
    dest_dir_path: []const u8,
) !void {
    var dest = try Io.Dir.cwd().createDirPathOpen(io, dest_dir_path, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    });
    defer dest.close(io);

    var file = try Io.Dir.cwd().openFile(io, tar_path, .{});
    defer file.close(io);
    var file_buf: [64 * 1024]u8 = undefined;
    var reader: Io.File.Reader = .initStreaming(file, io, &file_buf);
    try extractTarReaderToDir(allocator, io, dest, &reader.interface);
}

fn extractTarReaderToDir(
    allocator: std.mem.Allocator,
    io: Io,
    dest: Io.Dir,
    reader: *Io.Reader,
) !void {
    var limits: LayoutTarLimits = .{};

    while (true) {
        var header: [512]u8 = undefined;
        if (!try readTarHeader(reader, &header)) break;
        if (isZeroBlock(&header)) break;
        try verifyTarHeader(&header);

        const size = try tarSize(&header);
        try accountLayoutTarEntry(&limits, size);
        const kind = header[156];
        const raw_name = try tarFullName(allocator, &header);
        defer allocator.free(raw_name);
        const maybe_rel = try safeLayoutPath(allocator, raw_name);
        defer if (maybe_rel) |rel| allocator.free(rel);

        switch (kind) {
            0, '0' => {
                const rel = maybe_rel orelse return error.UnsafeOciLayoutTarPath;
                try extractRegularFile(allocator, io, dest, rel, reader, size);
            },
            '5' => {
                if (maybe_rel) |rel| try dest.createDirPath(io, rel);
                try discardTarPayload(reader, size);
            },
            else => {
                try discardTarPayload(reader, size);
                return error.UnsupportedOciLayoutTarEntry;
            },
        }
    }
}

const LayoutTarLimits = struct {
    entries: u64 = 0,
    payload_bytes: u64 = 0,
};

fn accountLayoutTarEntry(limits: *LayoutTarLimits, payload_size: u64) !void {
    if (limits.entries >= max_layout_tar_entries) return error.OciLayoutTarTooManyEntries;
    if (payload_size > max_layout_tar_payload_bytes - limits.payload_bytes) return error.RootFSArchiveTooLarge;

    limits.entries += 1;
    limits.payload_bytes += payload_size;
}

fn validateLayoutFile(allocator: std.mem.Allocator, io: Io, layout_dir: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ layout_dir, "oci-layout" });
    defer allocator.free(path);
    const bytes = try readRegularFileAlloc(io, allocator, path, 4096);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(LayoutFile, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.imageLayoutVersion, "1.0.0")) return error.UnsupportedOciLayoutVersion;
}

fn selectManifestDescriptor(allocator: std.mem.Allocator, index_bytes: []const u8, platform: oci.Platform) !SelectedDescriptor {
    var parsed = try std.json.parseFromSlice(oci.ImageIndex, allocator, index_bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.schemaVersion != 2) return error.UnsupportedManifestSchema;

    for (parsed.value.manifests) |desc| {
        const p = desc.platform orelse continue;
        if (!std.mem.eql(u8, p.os, platform.os) or !std.mem.eql(u8, p.architecture, platform.arch)) continue;
        if (!oci.isManifestMediaType(desc.mediaType)) return error.UnsupportedManifestMediaType;
        if (!oci.isSha256Digest(desc.digest)) return error.UnsupportedDigest;
        return .{
            .digest = try allocator.dupe(u8, desc.digest),
            .size = desc.size,
        };
    }
    return error.PlatformManifestNotFound;
}

fn verifyAllBlobs(allocator: std.mem.Allocator, io: Io, layout_dir: []const u8) !void {
    const blob_dir_path = try std.fs.path.join(allocator, &.{ layout_dir, "blobs", "sha256" });
    defer allocator.free(blob_dir_path);
    const stat = try Io.Dir.cwd().statFile(io, blob_dir_path, .{ .follow_symlinks = false });
    if (stat.kind != .directory) return error.UnsupportedOciLayoutBlob;
    var blob_dir = try Io.Dir.cwd().openDir(io, blob_dir_path, .{ .iterate = true });
    defer blob_dir.close(io);

    var it = blob_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) return error.UnsupportedOciLayoutBlob;
        if (!isSha256Hex(entry.name)) return error.UnsupportedDigest;
        const digest = try std.fmt.allocPrint(allocator, "sha256:{s}", .{entry.name});
        defer allocator.free(digest);
        const path = try std.fs.path.join(allocator, &.{ blob_dir_path, entry.name });
        defer allocator.free(path);
        try oci.verifyDigestFile(io, digest, path);
    }
}

fn readRegularFileAlloc(io: Io, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.UnsupportedOciLayoutBlob;
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
}

fn verifyDescriptorFile(io: Io, path: []const u8, digest: []const u8, expected_size: ?u64) !void {
    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.UnsupportedOciLayoutBlob;
    if (expected_size) |size| {
        if (stat.size != size) return error.OciLayoutBlobSizeMismatch;
    }
    try oci.verifyDigestFile(io, digest, path);
}

fn blobPath(allocator: std.mem.Allocator, layout_dir: []const u8, digest: []const u8) ![]u8 {
    if (!oci.isSha256Digest(digest)) return error.UnsupportedDigest;
    return std.fs.path.join(allocator, &.{ layout_dir, "blobs", "sha256", digest["sha256:".len..] });
}

fn isSha256Hex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn extractRegularFile(
    allocator: std.mem.Allocator,
    io: Io,
    dest: Io.Dir,
    rel: []const u8,
    reader: *Io.Reader,
    size: u64,
) !void {
    if (size > tar.max_content_bytes) return error.RootFSArchiveTooLarge;
    if (dest.statFile(io, rel, .{ .follow_symlinks = false })) |_| {
        return error.DuplicateOciLayoutTarPath;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }
    try ensureParent(allocator, io, dest, rel);
    var file = try dest.createFile(io, rel, .{});
    defer file.close(io);
    var file_buf: [64 * 1024]u8 = undefined;
    var writer: Io.File.Writer = .initStreaming(file, io, &file_buf);
    try copyTarPayload(reader, &writer.interface, size);
    try writer.interface.flush();
    try discardTarPadding(reader, size);
}

fn ensureParent(allocator: std.mem.Allocator, io: Io, dir: Io.Dir, rel: []const u8) !void {
    _ = allocator;
    const parent = parentPath(rel);
    if (parent.len == 0) return;
    try dir.createDirPath(io, parent);
}

fn safeLayoutPath(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    if (raw.len == 0 or std.mem.startsWith(u8, raw, "/")) return error.UnsafeOciLayoutTarPath;
    if (std.mem.indexOfScalar(u8, raw, 0) != null) return error.UnsafeOciLayoutTarPath;

    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);
    var iter = std.mem.splitScalar(u8, raw, '/');
    while (iter.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.UnsafeOciLayoutTarPath;
        try parts.append(allocator, part);
    }
    if (parts.items.len == 0) return null;

    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (parts.items, 0..) |part, i| {
        if (i != 0) try out.writer.writeByte('/');
        try out.writer.writeAll(part);
    }
    return try out.toOwnedSlice();
}

fn parentPath(rel: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, rel, '/') orelse return "";
    return rel[0..slash];
}

fn readTarHeader(reader: *Io.Reader, header: *[512]u8) !bool {
    var filled: usize = 0;
    while (filled < header.len) {
        const n = try reader.readSliceShort(header[filled..]);
        if (n == 0) {
            if (filled == 0) return false;
            return error.TruncatedTarHeader;
        }
        filled += n;
    }
    return true;
}

fn copyTarPayload(reader: *Io.Reader, writer: *Io.Writer, size: u64) !void {
    var remaining = size;
    var buf: [64 * 1024]u8 = undefined;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, buf.len));
        const n = try reader.readSliceShort(buf[0..want]);
        if (n == 0) return error.UnexpectedEndOfStream;
        try writer.writeAll(buf[0..n]);
        remaining -= n;
    }
}

fn discardTarPayload(reader: *Io.Reader, size: u64) !void {
    try reader.discardAll64(size);
    try discardTarPadding(reader, size);
}

fn discardTarPadding(reader: *Io.Reader, size: u64) !void {
    const padding = (512 - (size % 512)) % 512;
    if (padding != 0) try reader.discardAll(@intCast(padding));
}

fn tarFullName(allocator: std.mem.Allocator, header: *const [512]u8) ![]u8 {
    const name = trimTarField(header[0..100]);
    const prefix = trimTarField(header[345..500]);
    if (prefix.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
}

fn tarSize(header: *const [512]u8) !u64 {
    return parseTarNumber(header[124..136]);
}

fn parseTarNumber(raw: []const u8) !u64 {
    const trimmed = std.mem.trim(u8, raw, " \x00");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(u64, trimmed, 8) catch return error.BadTarHeader;
}

fn trimTarField(raw: []const u8) []const u8 {
    const nul = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
    return std.mem.trim(u8, raw[0..nul], " ");
}

fn verifyTarHeader(header: *const [512]u8) !void {
    const stored = try parseTarNumber(header[148..156]);
    var unsigned_sum: u64 = 0;
    for (header, 0..) |b, i| {
        const value: u8 = if (i >= 148 and i < 156) ' ' else b;
        unsigned_sum += value;
    }
    if (stored != unsigned_sum) return error.BadTarChecksum;
}

fn isZeroBlock(block: *const [512]u8) bool {
    for (block) |b| if (b != 0) return false;
    return true;
}

fn makeTarHeader(header: []u8, name: []const u8, kind: u8, size: u64) void {
    std.debug.assert(header.len == 512);
    std.debug.assert(name.len <= 100);
    @memset(header, 0);
    @memcpy(header[0..name.len], name);
    writeTarOctal(header[100..108], if (kind == '5') 0o755 else 0o644);
    writeTarOctal(header[108..116], 0);
    writeTarOctal(header[116..124], 0);
    writeTarOctal(header[124..136], size);
    writeTarOctal(header[136..148], 0);
    @memset(header[148..156], ' ');
    header[156] = kind;
    @memcpy(header[257..263], "ustar\x00");
    @memcpy(header[263..265], "00");
    var sum: u64 = 0;
    for (header[0..512]) |b| sum += b;
    writeTarOctal(header[148..156], sum);
}

fn writeTarOctal(field: []u8, value: u64) void {
    @memset(field, 0);
    var remaining = value;
    var index = field.len - 2;
    while (true) {
        field[index] = @intCast('0' + (remaining & 7));
        remaining >>= 3;
        if (remaining == 0 or index == 0) break;
        index -= 1;
    }
}

test "OCI layout reader selects platform manifest and verifies blobs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    const root = "zig-cache/test-oci-layout-reader";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, root ++ "/blobs/sha256");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/oci-layout", .data = "{\"imageLayoutVersion\":\"1.0.0\"}" });

    const config = "{\"architecture\":\"arm64\",\"os\":\"linux\"}";
    const config_digest = try oci.digestBytesAlloc(allocator, config);
    const config_path = try blobPath(allocator, root, config_digest);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = config });

    const layer = "layer bytes";
    const layer_digest = try oci.digestBytesAlloc(allocator, layer);
    const layer_path = try blobPath(allocator, root, layer_digest);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = layer_path, .data = layer });

    const manifest = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"config\":{{\"mediaType\":\"application/vnd.oci.image.config.v1+json\",\"digest\":\"{s}\",\"size\":{d}}},\"layers\":[{{\"mediaType\":\"application/vnd.oci.image.layer.v1.tar\",\"digest\":\"{s}\",\"size\":{d}}}]}}",
        .{ config_digest, config.len, layer_digest, layer.len },
    );
    const manifest_digest = try oci.digestBytesAlloc(allocator, manifest);
    const manifest_path = try blobPath(allocator, root, manifest_digest);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = manifest });

    const index = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.index.v1+json\",\"manifests\":[{{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"{s}\",\"size\":{d},\"platform\":{{\"os\":\"linux\",\"architecture\":\"arm64\"}}}}]}}",
        .{ manifest_digest, manifest.len },
    );
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/index.json", .data = index });

    const selected = try readSelectedImage(allocator, io, root, .{});
    try std.testing.expectEqualStrings(manifest_digest, selected.manifest_digest);
    try std.testing.expectEqualStrings(config_digest, selected.config_digest);
    try std.testing.expectEqual(@as(usize, 1), selected.layers.len);
    try std.testing.expectEqualStrings(layer_digest, selected.layers[0].digest);
}

test "OCI layout reader fails on digest mismatch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    const root = "zig-cache/test-oci-layout-digest-mismatch";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, root ++ "/blobs/sha256");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/oci-layout", .data = "{\"imageLayoutVersion\":\"1.0.0\"}" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/index.json", .data = "{\"schemaVersion\":2,\"manifests\":[]}" });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = root ++ "/blobs/sha256/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .data = "not matching",
    });

    try std.testing.expectError(error.DigestMismatch, readSelectedImage(allocator, io, root, .{}));
}

test "OCI layout tar extraction accepts buildx-shaped paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    const root = "zig-cache/test-oci-layout-tar-extract";
    const tar_path = root ++ "/layout.tar";
    const out_dir = root ++ "/out";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, root);

    var archive = [_]u8{0} ** (512 * 7);
    makeTarHeader(archive[0..512], "blobs", '5', 0);
    makeTarHeader(archive[512..1024], "blobs/sha256", '5', 0);
    makeTarHeader(archive[1024..1536], "oci-layout", '0', 4);
    @memcpy(archive[1536..1540], "json");
    makeTarHeader(archive[2048..2560], "index.json", '0', 2);
    @memcpy(archive[2560..2562], "{}");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tar_path, .data = &archive });

    try extractTarToDir(allocator, io, tar_path, out_dir);
    const layout = try Io.Dir.cwd().readFileAlloc(io, out_dir ++ "/oci-layout", allocator, .limited(8));
    try std.testing.expectEqualStrings("json", layout);
}

test "OCI layout tar extraction rejects unsafe paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();

    var archive = [_]u8{0} ** (512 * 3);
    makeTarHeader(archive[0..512], "../oci-layout", '0', 4);
    @memcpy(archive[512..516], "json");

    var reader: Io.Reader = .fixed(&archive);
    try std.testing.expectError(
        error.UnsafeOciLayoutTarPath,
        extractTarReaderToDir(arena_state.allocator(), std.testing.io, tmp.dir, &reader),
    );
}

test "OCI layout tar extraction rejects duplicate paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();

    var archive = [_]u8{0} ** (512 * 5);
    makeTarHeader(archive[0..512], "oci-layout", '0', 4);
    @memcpy(archive[512..516], "json");
    makeTarHeader(archive[1024..1536], "oci-layout", '0', 2);
    @memcpy(archive[1536..1538], "{}");

    var reader: Io.Reader = .fixed(&archive);
    try std.testing.expectError(
        error.DuplicateOciLayoutTarPath,
        extractTarReaderToDir(arena_state.allocator(), std.testing.io, tmp.dir, &reader),
    );
}

test "OCI layout tar extraction counts aggregate payload bytes" {
    var limits: LayoutTarLimits = .{};

    try accountLayoutTarEntry(&limits, 5);
    try std.testing.expectEqual(@as(u64, 1), limits.entries);
    try std.testing.expectEqual(@as(u64, 5), limits.payload_bytes);

    limits = .{ .entries = max_layout_tar_entries };
    try std.testing.expectError(error.OciLayoutTarTooManyEntries, accountLayoutTarEntry(&limits, 0));

    limits = .{ .payload_bytes = max_layout_tar_payload_bytes - 1 };
    try std.testing.expectError(error.RootFSArchiveTooLarge, accountLayoutTarEntry(&limits, 2));
}

fn fuzzOciLayoutIndexJson(_: void, s: *std.testing.Smith) !void {
    var buf: [4096]u8 = undefined;
    const len = s.slice(&buf);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    _ = selectManifestDescriptor(arena_state.allocator(), buf[0..len], .{}) catch return;
}

test "fuzz OCI layout index selection" {
    try std.testing.fuzz({}, fuzzOciLayoutIndexJson, .{});
}

fn fuzzOciLayoutTarExtraction(_: void, s: *std.testing.Smith) !void {
    var buf: [8192]u8 = undefined;
    const len = s.slice(&buf);

    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var reader: Io.Reader = .fixed(buf[0..len]);
    extractTarReaderToDir(arena_state.allocator(), std.testing.io, tmp.dir, &reader) catch return;
}

test "fuzz OCI layout tar extraction" {
    try std.testing.fuzz({}, fuzzOciLayoutTarExtraction, .{});
}
