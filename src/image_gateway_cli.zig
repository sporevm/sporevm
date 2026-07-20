//! CLI adapter for explicit image-gateway pulls.

const std = @import("std");
const Io = std.Io;
const api = @import("api.zig");
const gateway_pull = @import("image_gateway_pull.zig");
const rootfs = @import("rootfs.zig");

pub fn run(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0 or wantsHelp(args)) {
        try stdout.writeAll(gateway_pull.usage);
        return;
    }
    if (std.mem.eql(u8, args[0], "pull")) {
        const options = try parsePullOptions(args[1..]);
        const result = try api.imageGatewayPull(init, init.arena.allocator(), options);
        try stdout.print(
            "ref: {s}\nresolved: {s}\nplatform: {s}/{s}\nobjects_fetched: {d}\nbytes_fetched: {d}\n",
            .{ options.ref, result.resolved_image_ref, options.platform.os, options.platform.arch.name(), result.objects_fetched, result.bytes_fetched },
        );
        return;
    }
    if (std.mem.eql(u8, args[0], "export-fixture")) {
        const options = try parseExportFixtureOptions(args[1..]);
        const result = try api.imageGatewayExportFixture(init, init.arena.allocator(), options);
        try stdout.print("fixture: {s}\nmanifest: {s}\nimage: {s}\nobjects: {d}\n", .{
            options.output_dir,
            result.manifest_digest,
            result.image_digest,
            result.object_count,
        });
        return;
    }
    return error.UnknownImageCommand;
}

pub fn parsePullOptions(args: []const []const u8) !api.ImageGatewayPullOptions {
    var source: ?[]const u8 = null;
    var gateway_url: ?[]const u8 = null;
    var repository: ?[]const u8 = null;
    var ref: ?[]const u8 = null;
    var platform = rootfs.Platform{
        .os = gateway_pull.default_platform.os,
        .arch = gateway_pull.default_platform.arch,
    };
    var allow_insecure_http = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--gateway")) {
            i += 1;
            if (i >= args.len) return error.MissingGatewayUrl;
            gateway_url = args[i];
        } else if (std.mem.eql(u8, arg, "--repository")) {
            i += 1;
            if (i >= args.len) return error.MissingGatewayRepository;
            repository = args[i];
        } else if (std.mem.eql(u8, arg, "--ref")) {
            i += 1;
            if (i >= args.len) return error.MissingImageReference;
            ref = args[i];
        } else if (std.mem.eql(u8, arg, "--platform")) {
            i += 1;
            if (i >= args.len) return error.MissingPlatform;
            platform = try rootfs.Platform.parse(args[i]);
        } else if (std.mem.eql(u8, arg, "--allow-insecure-http")) {
            allow_insecure_http = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownImageOption;
        } else if (source == null) {
            source = arg;
        } else {
            return error.TooManyImageArguments;
        }
    }
    return .{
        .source = source orelse return error.MissingImageSource,
        .gateway_url = gateway_url orelse return error.MissingGatewayUrl,
        .repository = repository orelse return error.MissingGatewayRepository,
        .ref = ref orelse return error.MissingImageReference,
        .platform = .{ .os = platform.os, .arch = platform.arch },
        .allow_insecure_http = allow_insecure_http,
    };
}

pub fn parseExportFixtureOptions(args: []const []const u8) !api.ImageGatewayExportFixtureOptions {
    var source: ?[]const u8 = null;
    var repository: ?[]const u8 = null;
    var metadata_path: ?[]const u8 = null;
    var output_dir: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--repository")) {
            i += 1;
            if (i >= args.len) return error.MissingGatewayRepository;
            repository = args[i];
        } else if (std.mem.eql(u8, arg, "--metadata")) {
            i += 1;
            if (i >= args.len) return error.MissingMetadataPath;
            metadata_path = args[i];
        } else if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= args.len) return error.MissingOutputPath;
            output_dir = args[i];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownImageOption;
        } else if (source == null) {
            source = arg;
        } else {
            return error.TooManyImageArguments;
        }
    }
    return .{
        .source = source orelse return error.MissingImageSource,
        .repository = repository orelse return error.MissingGatewayRepository,
        .metadata_path = metadata_path orelse return error.MissingMetadataPath,
        .output_dir = output_dir orelse return error.MissingOutputPath,
    };
}

fn wantsHelp(args: []const []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return true;
    return false;
}

test "image pull options require explicit gateway repository and local ref" {
    const parsed = try parsePullOptions(&.{
        "docker.io/library/alpine:3.20",
        "--gateway",
        "https://images.example.test",
        "--repository",
        "team/base-images",
        "--ref",
        "local/alpine:gateway",
        "--platform",
        "linux/amd64",
    });
    try std.testing.expectEqualStrings("docker.io/library/alpine:3.20", parsed.source);
    try std.testing.expectEqual(.amd64, parsed.platform.arch);
    try std.testing.expectError(error.MissingGatewayUrl, parsePullOptions(&.{
        "docker.io/library/alpine:3.20",
        "--repository",
        "team/base-images",
        "--ref",
        "local/alpine:gateway",
    }));
    const defaults = try parsePullOptions(&.{
        "docker.io/library/alpine:3.20",
        "--gateway",
        "https://images.example.test",
        "--repository",
        "team/base-images",
        "--ref",
        "local/alpine:gateway",
    });
    try std.testing.expectEqual(gateway_pull.default_platform.arch, defaults.platform.arch);
}

test "fixture export options require an existing metadata input and new output" {
    const parsed = try parseExportFixtureOptions(&.{
        "docker.io/library/alpine:3.20",
        "--repository",
        "fixture",
        "--metadata",
        "/tmp/alpine.json",
        "--out",
        "/tmp/gateway",
    });
    try std.testing.expectEqualStrings("fixture", parsed.repository);
    try std.testing.expectEqualStrings("/tmp/gateway", parsed.output_dir);
}
