//! Canonical native image configuration and identity.
//!
//! Producers may obtain configuration from OCI, `spore build`, or a captured
//! rootfs, but native image identity is independent of that provenance. Keep
//! this module free of registry, filesystem, CAS, and hypervisor dependencies
//! so every producer can use the same canonical bytes and digest preimages.

const std = @import("std");
const architecture = @import("architecture.zig");
const Blake3 = std.crypto.hash.Blake3;

pub const config_identity_domain = "sporevm-indexed-image-config-v1";
pub const identity_domain = "sporevm-indexed-image-v1";
pub const digest_prefix = "blake3:";

/// Identity-bearing native image configuration. Field presence and declaration
/// order are durable: adding or reordering a field changes canonical bytes.
/// OCI readers also parse untrusted config JSON directly into this type while
/// ignoring unknown fields, so additions widen that projection deliberately.
pub const Config = struct {
    architecture: ?architecture.Architecture = null,
    os: ?[]const u8 = null,
    config: ?RuntimeConfig = null,
};

/// Identity-bearing runtime defaults parsed from an OCI `config` object.
pub const RuntimeConfig = struct {
    Env: ?[][]const u8 = null,
    Entrypoint: ?[][]const u8 = null,
    Cmd: ?[][]const u8 = null,
    WorkingDir: ?[]const u8 = null,
    User: ?[]const u8 = null,
    OnBuild: ?[][]const u8 = null,
};

/// Serialize the exact bytes that participate in native image identity.
/// Struct declaration order is therefore a durable format contract.
pub fn canonicalConfigJson(allocator: std.mem.Allocator, config: Config) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, config, .{
        .emit_null_optional_fields = false,
    });
}

/// Hash config bytes returned by `canonicalConfigJson`.
pub fn configDigestAlloc(allocator: std.mem.Allocator, canonical_config_json: []const u8) ![]u8 {
    var h = Blake3.init(.{});
    updateFramed(&h, config_identity_domain);
    updateFramed(&h, canonical_config_json);
    return digestAlloc(allocator, &h);
}

/// Hash a validated BLAKE3 rootfs-index digest and config bytes returned by
/// `canonicalConfigJson`.
pub fn imageDigestAlloc(allocator: std.mem.Allocator, index_digest: []const u8, canonical_config_json: []const u8) ![]u8 {
    var h = Blake3.init(.{});
    updateFramed(&h, identity_domain);
    updateFramed(&h, index_digest);
    updateFramed(&h, canonical_config_json);
    return digestAlloc(allocator, &h);
}

fn updateFramed(h: *Blake3, bytes: []const u8) void {
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, bytes.len, .little);
    h.update(&len_buf);
    h.update(bytes);
}

fn digestAlloc(allocator: std.mem.Allocator, h: *Blake3) ![]u8 {
    var digest: [Blake3.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ digest_prefix, &hex });
}

test "canonical config and native identities have stable golden bytes" {
    const allocator = std.testing.allocator;
    var env = [_][]const u8{ "PATH=/usr/bin", "EMPTY=" };
    var entrypoint = [_][]const u8{ "/bin/sh", "-c" };
    var cmd = [_][]const u8{ "echo", "hello" };
    var on_build = [_][]const u8{"RUN echo later"};
    const canonical = try canonicalConfigJson(allocator, .{
        .architecture = .arm64,
        .os = "linux",
        .config = .{
            .Env = &env,
            .Entrypoint = &entrypoint,
            .Cmd = &cmd,
            .WorkingDir = "/workspace",
            .User = "1000:1000",
            .OnBuild = &on_build,
        },
    });
    defer allocator.free(canonical);
    try std.testing.expectEqualStrings(
        "{\"architecture\":\"arm64\",\"os\":\"linux\",\"config\":{\"Env\":[\"PATH=/usr/bin\",\"EMPTY=\"],\"Entrypoint\":[\"/bin/sh\",\"-c\"],\"Cmd\":[\"echo\",\"hello\"],\"WorkingDir\":\"/workspace\",\"User\":\"1000:1000\",\"OnBuild\":[\"RUN echo later\"]}}",
        canonical,
    );

    const config_digest = try configDigestAlloc(allocator, canonical);
    defer allocator.free(config_digest);
    const image_digest = try imageDigestAlloc(
        allocator,
        "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        canonical,
    );
    defer allocator.free(image_digest);
    try std.testing.expectEqualStrings(
        "blake3:ea1d189f5ce29d0920cd8a785bd4859f62b78f256ac86b73483e3cfd58e460cf",
        config_digest,
    );
    try std.testing.expectEqualStrings(
        "blake3:565c3ea8fe3728910cc6e741c87c1f3757f963d34870c33c1d8326fd112c7b9a",
        image_digest,
    );
}

test "arm64 and amd64 have distinct golden native image identities" {
    const allocator = std.testing.allocator;
    const arm64 = try canonicalConfigJson(allocator, .{ .architecture = .arm64, .os = "linux" });
    defer allocator.free(arm64);
    const amd64 = try canonicalConfigJson(allocator, .{ .architecture = .amd64, .os = "linux" });
    defer allocator.free(amd64);

    const index_digest = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const arm64_digest = try imageDigestAlloc(allocator, index_digest, arm64);
    defer allocator.free(arm64_digest);
    const amd64_digest = try imageDigestAlloc(allocator, index_digest, amd64);
    defer allocator.free(amd64_digest);
    try std.testing.expectEqualStrings("{\"architecture\":\"arm64\",\"os\":\"linux\"}", arm64);
    try std.testing.expectEqualStrings("{\"architecture\":\"amd64\",\"os\":\"linux\"}", amd64);
    try std.testing.expectEqualStrings(
        "blake3:26e9cac46a9b237cc817f0fbd93cc2cf3533a9a69bb830d9ab303a550b783763",
        arm64_digest,
    );
    try std.testing.expectEqualStrings(
        "blake3:dc61952bc6d6b5c09d69b13be688620273ccb7d3bdd5302505408f4735c305f9",
        amd64_digest,
    );
}

test "canonical config pins escaping and empty object semantics" {
    const allocator = std.testing.allocator;
    var env = [_][]const u8{"QUOTE=\" BACKSLASH=\\ NEWLINE=\n UTF8=☃"};
    const escaped = try canonicalConfigJson(allocator, .{
        .architecture = .arm64,
        .os = "linux",
        .config = .{ .Env = &env },
    });
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings(
        "{\"architecture\":\"arm64\",\"os\":\"linux\",\"config\":{\"Env\":[\"QUOTE=\\\" BACKSLASH=\\\\ NEWLINE=\\n UTF8=☃\"]}}",
        escaped,
    );

    const absent = try canonicalConfigJson(allocator, .{});
    defer allocator.free(absent);
    const present = try canonicalConfigJson(allocator, .{ .config = .{} });
    defer allocator.free(present);
    try std.testing.expectEqualStrings("{}", absent);
    try std.testing.expectEqualStrings("{\"config\":{}}", present);
}

test "OCI config projection is canonical and drops unknown fields" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"rootfs":{"type":"layers"},"config":{"Labels":{"x":"y"},"Cmd":["say \"hi\""],"Env":["A=☃"]},"os":"linux","history":[],"architecture":"amd64"}
    ;
    var parsed = try std.json.parseFromSlice(Config, allocator, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const canonical = try canonicalConfigJson(allocator, parsed.value);
    defer allocator.free(canonical);
    try std.testing.expectEqualStrings(
        "{\"architecture\":\"amd64\",\"os\":\"linux\",\"config\":{\"Env\":[\"A=☃\"],\"Cmd\":[\"say \\\"hi\\\"\"]}}",
        canonical,
    );
}
