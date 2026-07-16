const std = @import("std");

pub fn validateTemplate(source: []const u8) bool {
    const prefix = "https://";
    if (!std.mem.startsWith(u8, source, prefix)) return false;
    const remainder = source[prefix.len..];
    const authority_end = std.mem.indexOfAny(u8, remainder, "/?#") orelse remainder.len;
    const authority = remainder[0..authority_end];
    if (authority.len == 0 or std.mem.indexOfAny(u8, authority, "$@") != null) return false;
    if (std.mem.indexOfScalar(u8, source, '#') != null) return false;
    const path_end = std.mem.indexOfScalarPos(u8, source, prefix.len + authority_end, '?') orelse source.len;
    return !gitPath(source[prefix.len + authority_end .. path_end]);
}

pub fn validateUrl(raw: []const u8) !std.Uri {
    if (raw.len == 0 or raw.len > 64 * 1024) return error.UnsupportedRemoteAddUrl;
    const uri = std.Uri.parse(raw) catch return error.UnsupportedRemoteAddUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") or uri.host == null) return error.UnsupportedRemoteAddUrl;
    if (uri.user != null or uri.password != null or uri.fragment != null) return error.UnsupportedRemoteAddUrl;
    if (gitPath(componentText(uri.path))) return error.UnsupportedRemoteAddUrl;
    return uri;
}

fn gitPath(path: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    var cursor = trimmed.len;
    inline for ("tig.") |expected| {
        const byte = previousDecodedByte(trimmed, &cursor) orelse return false;
        if (byte != expected) return false;
    }
    return true;
}

fn previousDecodedByte(path: []const u8, cursor: *usize) ?u8 {
    if (cursor.* == 0) return null;
    if (cursor.* >= 3 and path[cursor.* - 3] == '%') {
        const byte = std.fmt.parseInt(u8, path[cursor.* - 2 .. cursor.*], 16) catch return null;
        cursor.* -= 3;
        return byte;
    }
    cursor.* -= 1;
    return path[cursor.*];
}

fn componentText(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw => |text| text,
        .percent_encoded => |text| text,
    };
}

test "remote ADD template and resolved policy stay aligned" {
    try std.testing.expect(validateTemplate("https://example.com/${VERSION}/tool"));
    try std.testing.expect(!validateTemplate("http://example.com/tool"));
    try std.testing.expect(!validateTemplate("HTTPS://example.com/tool"));
    try std.testing.expect(!validateTemplate("https://${HOST}/tool"));
    try std.testing.expect(!validateTemplate("https://user@example.com/tool"));
    try std.testing.expect(!validateTemplate("https://example.com/repo.git"));
    try std.testing.expect(!validateTemplate("https://example.com/repo%2Egit"));
    try std.testing.expect(validateTemplate("https://example.com/repo.GIT"));
    try std.testing.expectError(error.UnsupportedRemoteAddUrl, validateUrl("https://user@example.com/tool"));
    try std.testing.expectError(error.UnsupportedRemoteAddUrl, validateUrl("https://example.com/repo%2Egit"));
    _ = try validateUrl("https://example.com/releases/tool?download=1");
}
