const std = @import("std");
const fetch_policy = @import("../host_fetch_policy.zig");
const oci = @import("oci.zig");

const Io = std.Io;

const max_registry_manifest_bytes: u64 = 32 << 20;
const max_registry_config_bytes: u64 = 64 << 20;
const max_registry_token_bytes: u64 = 1 << 20;

pub const FetchManifestResult = struct {
    bytes: []u8,
    content_digest: ?[]u8 = null,
};

pub fn fetchManifest(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    bearer_token: *?[]const u8,
    image_ref: oci.ImageRef,
    digest: []const u8,
) ![]u8 {
    const url = try image_ref.manifestUrl(allocator, digest);
    const accept =
        "application/vnd.oci.image.index.v1+json, " ++
        "application/vnd.docker.distribution.manifest.list.v2+json, " ++
        "application/vnd.oci.image.manifest.v1+json, " ++
        "application/vnd.docker.distribution.manifest.v2+json";
    return fetchBytes(allocator, client, bearer_token, url, accept, max_registry_manifest_bytes);
}

pub fn fetchManifestByTag(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    bearer_token: *?[]const u8,
    image_tag: oci.ImageTag,
) !FetchManifestResult {
    const url = try image_tag.manifestUrl(allocator);
    const accept =
        "application/vnd.oci.image.index.v1+json, " ++
        "application/vnd.docker.distribution.manifest.list.v2+json, " ++
        "application/vnd.oci.image.manifest.v1+json, " ++
        "application/vnd.docker.distribution.manifest.v2+json";
    return fetchBytesWithContentDigest(allocator, client, bearer_token, url, accept, max_registry_manifest_bytes);
}

pub fn fetchBlobBytes(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    bearer_token: *?[]const u8,
    image_ref: oci.ImageRef,
    digest: []const u8,
    expected_size: ?u64,
) ![]u8 {
    const url = try image_ref.blobUrl(allocator, digest);
    if (expected_size) |size| {
        if (size > max_registry_config_bytes) return error.RegistryBodyTooLarge;
        return fetchBytes(allocator, client, bearer_token, url, "application/octet-stream", size);
    }
    return fetchBytes(allocator, client, bearer_token, url, "application/octet-stream", max_registry_config_bytes);
}

pub fn fetchBlobToFile(
    allocator: std.mem.Allocator,
    io: Io,
    client: *std.http.Client,
    bearer_token: *?[]const u8,
    image_ref: oci.ImageRef,
    digest: []const u8,
    expected_size: ?u64,
    max_size: u64,
    path: []const u8,
) !void {
    const url = try image_ref.blobUrl(allocator, digest);
    const body_limit = if (expected_size) |size| limit: {
        if (size > max_size) return error.RegistryBodyTooLarge;
        break :limit size;
    } else max_size;

    var current_url = url;
    var current_token = bearer_token.*;
    var redirects: u8 = 0;
    var auth_retries: u8 = 0;
    while (true) {
        const result = try httpGetToFile(allocator, io, client, current_url, "application/octet-stream", current_token, path, body_limit);
        defer if (result.auth_header) |h| allocator.free(h);
        defer if (result.location) |l| allocator.free(l);
        defer if (result.content_digest) |d| allocator.free(d);

        if (result.status == .unauthorized and result.auth_header != null and try sameOrigin(url, current_url)) {
            if (auth_retries != 0) return error.RegistryAuthFailed;
            auth_retries += 1;
            Io.Dir.cwd().deleteFile(io, path) catch {};
            bearer_token.* = try fetchBearerToken(allocator, client, current_url, result.auth_header.?);
            current_token = bearer_token.*;
            continue;
        }

        if (isRedirectStatus(result.status)) {
            redirects += 1;
            if (redirects > 5) return error.TooManyHttpRedirects;
            Io.Dir.cwd().deleteFile(io, path) catch {};
            const location = result.location orelse return error.HttpRedirectLocationMissing;
            const next_url = try resolveRedirectUrl(allocator, current_url, location);
            current_token = if (try sameOrigin(current_url, next_url)) current_token else null;
            current_url = next_url;
            continue;
        }

        if (result.status != .ok) return error.RegistryHTTPStatus;
        return;
    }
}

fn fetchBytes(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    bearer_token: *?[]const u8,
    url: []const u8,
    accept: []const u8,
    max_body_bytes: u64,
) ![]u8 {
    const result = try fetchBytesWithContentDigest(allocator, client, bearer_token, url, accept, max_body_bytes);
    if (result.content_digest) |digest| allocator.free(digest);
    return result.bytes;
}

fn fetchBytesWithContentDigest(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    bearer_token: *?[]const u8,
    url: []const u8,
    accept: []const u8,
    max_body_bytes: u64,
) !FetchManifestResult {
    var writer: Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();

    var current_url = url;
    var current_token = bearer_token.*;
    var redirects: u8 = 0;
    var auth_retries: u8 = 0;
    while (true) {
        var result = try httpGetToWriter(allocator, client, current_url, accept, current_token, &writer.writer, max_body_bytes);
        defer if (result.auth_header) |h| allocator.free(h);
        defer if (result.location) |l| allocator.free(l);
        defer if (result.content_digest) |d| allocator.free(d);

        if (result.status == .unauthorized and result.auth_header != null and try sameOrigin(url, current_url)) {
            if (auth_retries != 0) return error.RegistryAuthFailed;
            auth_retries += 1;
            bearer_token.* = try fetchBearerToken(allocator, client, current_url, result.auth_header.?);
            current_token = bearer_token.*;
            writer.clearRetainingCapacity();
            continue;
        }

        if (isRedirectStatus(result.status)) {
            redirects += 1;
            if (redirects > 5) return error.TooManyHttpRedirects;
            const location = result.location orelse return error.HttpRedirectLocationMissing;
            const next_url = try resolveRedirectUrl(allocator, current_url, location);
            current_token = if (try sameOrigin(current_url, next_url)) current_token else null;
            current_url = next_url;
            writer.clearRetainingCapacity();
            continue;
        }

        if (result.status != .ok) return error.RegistryHTTPStatus;
        const bytes = try writer.toOwnedSlice();
        const content_digest = result.content_digest;
        result.content_digest = null;
        return .{ .bytes = bytes, .content_digest = content_digest };
    }
}

const HTTPGetResult = struct {
    status: std.http.Status,
    auth_header: ?[]u8 = null,
    location: ?[]u8 = null,
    content_digest: ?[]u8 = null,
};

fn httpGetToFile(
    allocator: std.mem.Allocator,
    io: Io,
    client: *std.http.Client,
    url: []const u8,
    accept: []const u8,
    bearer_token: ?[]const u8,
    path: []const u8,
    max_body_bytes: u64,
) !HTTPGetResult {
    try validateRegistryFetchUrl(client.io, url);
    var file = try Io.Dir.cwd().createFile(io, path, .{});
    errdefer Io.Dir.cwd().deleteFile(io, path) catch {};
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var file_writer: Io.File.Writer = .initStreaming(file, io, &buffer);
    const result = try httpGetToWriterAfterPolicy(allocator, client, url, accept, bearer_token, &file_writer.interface, max_body_bytes);
    try file_writer.interface.flush();
    return result;
}

fn httpGetToWriter(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    accept: []const u8,
    bearer_token: ?[]const u8,
    writer: *Io.Writer,
    max_body_bytes: u64,
) !HTTPGetResult {
    try validateRegistryFetchUrl(client.io, url);
    return httpGetToWriterAfterPolicy(allocator, client, url, accept, bearer_token, writer, max_body_bytes);
}

fn httpGetToWriterAfterPolicy(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    accept: []const u8,
    bearer_token: ?[]const u8,
    writer: *Io.Writer,
    max_body_bytes: u64,
) !HTTPGetResult {
    const uri = try std.Uri.parse(url);
    const accept_header = std.http.Header{ .name = "accept", .value = accept };
    var auth_value: ?[]u8 = null;
    defer if (auth_value) |v| allocator.free(v);

    const extra_headers: []const std.http.Header = &.{accept_header};
    var request_headers: std.http.Client.Request.Headers = .{ .accept_encoding = .omit };
    if (bearer_token) |token| {
        auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
        request_headers.authorization = .{ .override = auth_value.? };
    }

    var req = try client.request(.GET, uri, .{
        .headers = request_headers,
        .extra_headers = extra_headers,
        .redirect_behavior = .unhandled,
        .keep_alive = false,
    });
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    const auth = try findHeaderAlloc(allocator, response.head.bytes, "www-authenticate");
    errdefer if (auth) |h| allocator.free(h);
    const location = try findHeaderAlloc(allocator, response.head.bytes, "location");
    errdefer if (location) |l| allocator.free(l);
    const content_digest = try findHeaderAlloc(allocator, response.head.bytes, "docker-content-digest");
    errdefer if (content_digest) |d| allocator.free(d);

    if (response.head.status == .ok) {
        var transfer_buffer: [64 * 1024]u8 = undefined;
        const body = response.reader(&transfer_buffer);
        try streamRemainingLimited(body, writer, max_body_bytes, &response);
    }
    return .{ .status = response.head.status, .auth_header = auth, .location = location, .content_digest = content_digest };
}

fn validateRegistryFetchUrl(io: Io, url: []const u8) !void {
    try fetch_policy.validateUrl(io, url, .{ .require_https = true });
}

fn fetchBearerToken(allocator: std.mem.Allocator, client: *std.http.Client, resource_url: []const u8, auth_header: []const u8) ![]const u8 {
    const challenge = try parseBearerChallenge(auth_header);
    try validateTokenRealm(resource_url, challenge.realm);
    const url = try challenge.tokenUrl(allocator);
    var body: Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    const result = try httpGetToWriter(allocator, client, url, "application/json", null, &body.writer, max_registry_token_bytes);
    defer if (result.auth_header) |h| allocator.free(h);
    defer if (result.location) |l| allocator.free(l);
    defer if (result.content_digest) |d| allocator.free(d);
    if (result.status != .ok) return error.RegistryAuthFailed;
    var parsed = try std.json.parseFromSlice(TokenResponse, allocator, body.written(), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.token) |token| return allocator.dupe(u8, token);
    if (parsed.value.access_token) |token| return allocator.dupe(u8, token);
    return error.RegistryAuthFailed;
}

fn validateTokenRealm(resource_url: []const u8, realm: []const u8) !void {
    const resource = try std.Uri.parse(resource_url);
    const token = try std.Uri.parse(realm);
    if (!std.ascii.eqlIgnoreCase(token.scheme, "https")) return error.UnsupportedRegistryAuthRealm;
    if (try sameOrigin(resource_url, realm)) return;

    const resource_host = resource.host orelse return error.UnsupportedRegistryAuthRealm;
    const token_host = token.host orelse return error.UnsupportedRegistryAuthRealm;
    if (std.ascii.eqlIgnoreCase(uriComponentText(resource_host), "registry-1.docker.io") and
        std.ascii.eqlIgnoreCase(uriComponentText(token_host), "auth.docker.io") and
        normalizedPort(token) == 443)
    {
        return;
    }
    return error.UnsupportedRegistryAuthRealm;
}

fn streamRemainingLimited(
    reader: *Io.Reader,
    writer: *Io.Writer,
    max_body_bytes: u64,
    response: *std.http.Client.Response,
) !void {
    var copied: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&buffer) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse err,
            else => |e| return e,
        };
        if (n == 0) return;
        if (n > max_body_bytes - copied) return error.RegistryBodyTooLarge;
        copied += n;
        try writer.writeAll(buffer[0..n]);
    }
}

fn isRedirectStatus(status: std.http.Status) bool {
    return status.class() == .redirect;
}

fn resolveRedirectUrl(allocator: std.mem.Allocator, base_url: []const u8, location: []const u8) ![]u8 {
    const base = try std.Uri.parse(base_url);
    var aux = try allocator.alloc(u8, location.len + base_url.len + 1024);
    defer allocator.free(aux);
    @memcpy(aux[0..location.len], location);
    var remaining = aux;
    const resolved = try base.resolveInPlace(location.len, &remaining);
    return uriToString(allocator, resolved);
}

fn sameOrigin(a_url: []const u8, b_url: []const u8) !bool {
    const a = try std.Uri.parse(a_url);
    const b = try std.Uri.parse(b_url);
    if (!std.ascii.eqlIgnoreCase(a.scheme, b.scheme)) return false;
    if (normalizedPort(a) != normalizedPort(b)) return false;
    const a_host = a.host orelse return false;
    const b_host = b.host orelse return false;
    return std.ascii.eqlIgnoreCase(uriComponentText(a_host), uriComponentText(b_host));
}

fn normalizedPort(uri: std.Uri) u16 {
    if (uri.port) |port| return port;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return 443;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) return 80;
    return 0;
}

fn uriComponentText(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw => |s| s,
        .percent_encoded => |s| s,
    };
}

fn uriToString(allocator: std.mem.Allocator, uri: std.Uri) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try uri.writeToStream(&out.writer, .{
        .scheme = true,
        .authentication = true,
        .authority = true,
        .path = true,
        .query = true,
        .fragment = true,
    });
    return out.toOwnedSlice();
}

const TokenResponse = struct {
    token: ?[]const u8 = null,
    access_token: ?[]const u8 = null,
};

const BearerChallenge = struct {
    realm: []const u8,
    service: ?[]const u8 = null,
    scope: ?[]const u8 = null,

    fn tokenUrl(self: BearerChallenge, allocator: std.mem.Allocator) ![]u8 {
        var out: Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.writeAll(self.realm);
        var has_query = std.mem.indexOfScalar(u8, self.realm, '?') != null;
        if (self.service) |service| {
            try out.writer.writeAll(if (has_query) "&service=" else "?service=");
            try writeQueryEscaped(&out.writer, service);
            has_query = true;
        }
        if (self.scope) |scope| {
            try out.writer.writeAll(if (has_query) "&scope=" else "?scope=");
            try writeQueryEscaped(&out.writer, scope);
        }
        return out.toOwnedSlice();
    }
};

fn parseBearerChallenge(header: []const u8) !BearerChallenge {
    var rest = std.mem.trim(u8, header, " \t");
    if (!std.ascii.startsWithIgnoreCase(rest, "Bearer")) return error.UnsupportedRegistryAuth;
    rest = std.mem.trim(u8, rest["Bearer".len..], " \t");
    var challenge = BearerChallenge{ .realm = "" };
    var iter = std.mem.splitScalar(u8, rest, ',');
    while (iter.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t");
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const key = std.mem.trim(u8, part[0..eq], " \t");
        const raw_value = std.mem.trim(u8, part[eq + 1 ..], " \t");
        const value = trimChallengeQuotes(raw_value);
        if (std.ascii.eqlIgnoreCase(key, "realm")) {
            challenge.realm = value;
        } else if (std.ascii.eqlIgnoreCase(key, "service")) {
            challenge.service = value;
        } else if (std.ascii.eqlIgnoreCase(key, "scope")) {
            challenge.scope = value;
        }
    }
    if (challenge.realm.len == 0) return error.BadRegistryAuthChallenge;
    return challenge;
}

fn trimChallengeQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn findHeaderAlloc(allocator: std.mem.Allocator, head: []const u8, name: []const u8) !?[]u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.first();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const header_name = line[0..colon];
        if (!std.ascii.eqlIgnoreCase(header_name, name)) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return try allocator.dupe(u8, value);
    }
    return null;
}

fn writeQueryEscaped(writer: *Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try writer.writeByte(c);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[c >> 4]);
            try writer.writeByte(hex[c & 0x0f]);
        }
    }
}

test "redirect resolution tracks cross-origin hops" {
    const allocator = std.testing.allocator;
    const next = try resolveRedirectUrl(
        allocator,
        "https://ghcr.io/v2/buildkite/base/blobs/sha256:abc",
        "https://objects.githubusercontent.com/blob",
    );
    defer allocator.free(next);
    try std.testing.expectEqualStrings("https://objects.githubusercontent.com/blob", next);
    try std.testing.expect(!try sameOrigin("https://ghcr.io/v2/a", next));

    const relative = try resolveRedirectUrl(
        allocator,
        "https://ghcr.io/v2/buildkite/base/blobs/sha256:abc",
        "../manifests/sha256:def",
    );
    defer allocator.free(relative);
    try std.testing.expect(try sameOrigin("https://ghcr.io/v2/a", relative));
}

test "registry redirect target policy rejects internal egress" {
    const allocator = std.testing.allocator;

    const loopback = try resolveRedirectUrl(
        allocator,
        "https://ghcr.io/v2/buildkite/base/blobs/sha256:abc",
        "https://127.0.0.1/blob",
    );
    defer allocator.free(loopback);
    try std.testing.expectError(error.UnsafeRemoteFetchTarget, validateRegistryFetchUrl(std.testing.io, loopback));

    const link_local = try resolveRedirectUrl(
        allocator,
        "https://ghcr.io/v2/buildkite/base/blobs/sha256:abc",
        "https://169.254.169.254/latest/meta-data/",
    );
    defer allocator.free(link_local);
    try std.testing.expectError(error.UnsafeRemoteFetchTarget, validateRegistryFetchUrl(std.testing.io, link_local));

    const private = try resolveRedirectUrl(
        allocator,
        "https://ghcr.io/v2/buildkite/base/blobs/sha256:abc",
        "https://10.0.0.10/blob",
    );
    defer allocator.free(private);
    try std.testing.expectError(error.UnsafeRemoteFetchTarget, validateRegistryFetchUrl(std.testing.io, private));
}

test "registry redirect target policy requires https" {
    const allocator = std.testing.allocator;
    const downgraded = try resolveRedirectUrl(
        allocator,
        "https://ghcr.io/v2/buildkite/base/blobs/sha256:abc",
        "http://1.1.1.1/blob",
    );
    defer allocator.free(downgraded);
    try std.testing.expectError(error.UnsupportedRemoteFetchScheme, validateRegistryFetchUrl(std.testing.io, downgraded));
}

test "token realm validation rejects cross-origin realms" {
    try validateTokenRealm("https://ghcr.io/v2/buildkite/base/manifests/sha256:abc", "https://ghcr.io/token");
    try validateTokenRealm("https://registry-1.docker.io/v2/library/alpine/manifests/latest", "https://auth.docker.io/token");
    try std.testing.expectError(
        error.UnsupportedRegistryAuthRealm,
        validateTokenRealm("https://ghcr.io/v2/buildkite/base/manifests/sha256:abc", "http://ghcr.io/token"),
    );
    try std.testing.expectError(
        error.UnsupportedRegistryAuthRealm,
        validateTokenRealm("https://ghcr.io/v2/buildkite/base/manifests/sha256:abc", "https://169.254.169.254/token"),
    );
    try std.testing.expectError(
        error.UnsupportedRegistryAuthRealm,
        validateTokenRealm("https://ghcr.io/v2/buildkite/base/manifests/sha256:abc", "https://auth.example/token"),
    );
}

test "header lookup finds docker content digest case insensitively" {
    const head =
        "HTTP/1.1 200 OK\r\n" ++
        "Docker-Content-Digest: sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\r\n" ++
        "\r\n";
    const digest = try findHeaderAlloc(std.testing.allocator, head, "docker-content-digest") orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(digest);
    try std.testing.expectEqualStrings("sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", digest);
}
