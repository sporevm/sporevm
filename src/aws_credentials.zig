//! AWS CLI credential-chain bridge for direct signed S3 reads. Never logs
//! provider output: it contains secrets, including on provider failure.
const std = @import("std");
const Io = std.Io;
const sigv4 = @import("s3_sigv4.zig");
const max_output = 32 * 1024;

pub const Provider = struct {
    allocator: std.mem.Allocator,
    io: Io,
    env: std.process.Environ.Map,
    aws: []const u8,
    mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    credentials: ?sigv4.Credentials = null,
    expiration: ?[sigv4.amz_date_len]u8 = null,
    from_cli: bool,

    pub fn init(allocator: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, aws: []const u8) !Provider {
        var self = Provider{
            .allocator = allocator,
            .io = io,
            .env = try env.clone(allocator),
            .aws = aws,
            .arena = .init(allocator),
            .from_cli = !hasEnvironmentCredentials(env),
        };
        errdefer self.deinit();
        try self.env.put("AWS_PAGER", "");
        try self.env.put("AWS_CLI_AUTO_PROMPT", "off");
        if (self.from_cli) {
            try self.refresh(nowSeconds(io));
        } else {
            // Partial/invalid explicit credentials must not fall through to a
            // different identity. Environment credentials are fixed, not renewable.
            self.credentials = try sigv4.Credentials.fromEnv(&self.env);
        }
        return self;
    }

    pub fn deinit(self: *Provider) void {
        if (self.from_cli) if (self.credentials) |credentials| erase(credentials);
        self.arena.deinit();
        // Map owns copies, including any explicit environment credentials.
        for ([_][]const u8{ "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN" }) |name| {
            if (self.env.get(name)) |value| std.crypto.secureZero(u8, @constCast(value));
        }
        self.env.deinit();
    }

    /// The returned token is request-owned: concurrent refresh cannot invalidate
    /// headers already being sent. Caller frees/erases it after the request.
    pub fn signGet(self: *Provider, allocator: std.mem.Allocator, region: []const u8, host: []const u8, path: []const u8, now: u64) !sigv4.SignedGet {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.expiration) |expiration| {
            const horizon = sigv4.formatAmzDate(now +| 60);
            if (std.mem.order(u8, &expiration, &horizon) != .gt) try self.refresh(now);
        }
        var signed = try sigv4.signGet(self.credentials.?, region, host, path, now);
        if (signed.session_token) |token| signed.session_token = try allocator.dupe(u8, token);
        return signed;
    }

    fn refresh(self: *Provider, now: u64) !void {
        const bytes = try run(self.allocator, self.io, &self.env, self.aws, &.{ "configure", "export-credentials", "--format", "process" });
        defer {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        }
        var next_arena: std.heap.ArenaAllocator = .init(self.allocator);
        errdefer next_arena.deinit();
        const next = try parse(next_arena.allocator(), bytes);
        if (next.expiration) |expiration| {
            const current = sigv4.formatAmzDate(now);
            if (std.mem.order(u8, &expiration, &current) != .gt) {
                erase(next.credentials);
                return error.AwsCredentialsExpired;
            }
        }
        if (self.credentials) |credentials| erase(credentials);
        self.arena.deinit();
        self.arena = next_arena;
        self.credentials = next.credentials;
        self.expiration = next.expiration;
    }
};

pub fn regionAlloc(allocator: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, aws: []const u8) ![]const u8 {
    if (sigv4.regionFromEnv(env)) |region| return allocator.dupe(u8, region) else |err| {
        if (err != error.AwsRegionMissing) return err;
    }
    const bytes = try run(allocator, io, env, aws, &.{ "configure", "get", "region" });
    defer allocator.free(bytes);
    const region = std.mem.trim(u8, bytes, " \r\n\t");
    if (region.len == 0) return error.AwsRegionMissing;
    try sigv4.validateRegion(region);
    return allocator.dupe(u8, region);
}

fn hasEnvironmentCredentials(env: *const std.process.Environ.Map) bool {
    for ([_][]const u8{ "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN" }) |name| {
        if (env.get(name)) |value| if (value.len != 0) return true;
    }
    return false;
}

fn run(allocator: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, aws: []const u8, args: []const []const u8) ![]u8 {
    const argv = try std.mem.concat(allocator, []const u8, &.{ &.{aws}, args });
    defer allocator.free(argv);
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = env,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(5), .clock = .awake }) },
    }) catch |err| switch (err) {
        error.FileNotFound => return error.AwsCliUnavailable,
        error.Canceled => return error.Canceled,
        else => return error.AwsCredentialProviderFailed,
    };
    defer {
        std.crypto.secureZero(u8, result.stderr);
        allocator.free(result.stderr);
    }
    if (result.term != .exited or result.term.exited != 0) {
        std.crypto.secureZero(u8, result.stdout);
        allocator.free(result.stdout);
        return error.AwsCredentialProviderFailed;
    }
    return result.stdout;
}

const Parsed = struct {
    credentials: sigv4.Credentials,
    expiration: ?[sigv4.amz_date_len]u8,
};

fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Parsed {
    if (bytes.len > max_output) return error.AwsCredentialsInvalid;
    const Output = struct {
        Version: u32,
        AccessKeyId: []const u8,
        SecretAccessKey: []const u8,
        SessionToken: ?[]const u8 = null,
        Expiration: ?[]const u8 = null,
    };
    const value = std.json.parseFromSliceLeaky(Output, allocator, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.AwsCredentialsInvalid;
    if (value.Version != 1) return error.AwsCredentialsInvalid;
    const credentials = sigv4.Credentials{ .access_key_id = value.AccessKeyId, .secret_access_key = value.SecretAccessKey, .session_token = value.SessionToken };
    try credentials.validate();
    return .{ .credentials = credentials, .expiration = if (value.Expiration) |expiration| try parseExpiration(expiration) else null };
}

/// AWS CLI process credentials use UTC ISO 8601. Normalize to sortable SigV4
/// time instead of adding a separate civil-date-to-epoch implementation.
fn parseExpiration(value: []const u8) ![sigv4.amz_date_len]u8 {
    if (value.len != 20 and value.len != 25) return error.AwsCredentialsInvalid;
    if (value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':') return error.AwsCredentialsInvalid;
    if (!std.mem.eql(u8, value[19..], "Z") and !std.mem.eql(u8, value[19..], "+00:00")) return error.AwsCredentialsInvalid;
    var date: [sigv4.amz_date_len]u8 = undefined;
    @memcpy(date[0..4], value[0..4]);
    @memcpy(date[4..6], value[5..7]);
    @memcpy(date[6..8], value[8..10]);
    date[8] = 'T';
    @memcpy(date[9..11], value[11..13]);
    @memcpy(date[11..13], value[14..16]);
    @memcpy(date[13..15], value[17..19]);
    date[15] = 'Z';
    for (date, 0..) |byte, i| if (i != 8 and i != 15 and !std.ascii.isDigit(byte)) return error.AwsCredentialsInvalid;
    const year = try std.fmt.parseInt(u16, date[0..4], 10);
    const month = try std.fmt.parseInt(u8, date[4..6], 10);
    const day = try std.fmt.parseInt(u8, date[6..8], 10);
    if (year < 1970 or month < 1 or month > 12 or day < 1 or day > std.time.epoch.getDaysInMonth(year, @enumFromInt(month))) return error.AwsCredentialsInvalid;
    if (try std.fmt.parseInt(u8, date[9..11], 10) > 23 or try std.fmt.parseInt(u8, date[11..13], 10) > 59 or try std.fmt.parseInt(u8, date[13..15], 10) > 59) return error.AwsCredentialsInvalid;
    return date;
}

fn nowSeconds(io: Io) u64 {
    return @intCast(Io.Clock.real.now(io).toSeconds());
}

fn erase(credentials: sigv4.Credentials) void {
    std.crypto.secureZero(u8, @constCast(credentials.secret_access_key));
    if (credentials.session_token) |token| std.crypto.secureZero(u8, @constCast(token));
}

test "AWS reads honor environment precedence and reject partial credentials" {
    const allocator = std.testing.allocator;
    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    try env.put("AWS_ACCESS_KEY_ID", "ENVKEY");
    try std.testing.expectError(error.AwsCredentialsMissing, Provider.init(allocator, std.testing.io, &env, "/missing/aws"));
    try env.put("AWS_SECRET_ACCESS_KEY", "env-secret");
    try env.put("AWS_PROFILE", "must-not-override");
    try env.put("AWS_REGION", "eu-west-2");
    var provider = try Provider.init(allocator, std.testing.io, &env, "/missing/aws");
    defer provider.deinit();
    const signed = try provider.signGet(allocator, "eu-west-2", "bucket.s3.eu-west-2.amazonaws.com", "/key", 0);
    try std.testing.expect(std.mem.indexOf(u8, signed.authorization(), "Credential=ENVKEY/") != null);
    const region = try regionAlloc(allocator, std.testing.io, &env, "/missing/aws");
    defer allocator.free(region);
    try std.testing.expectEqualStrings("eu-west-2", region);
}

test "AWS profile reads refresh credentials and keep in-flight tokens alive" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = try @import("test_dir.zig").TestDir.init();
    defer tmp.deinit();
    const script = try tmp.path("aws");
    const output = try tmp.path("credentials");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = script, .data =
        \\#!/bin/sh
        \\[ "$AWS_PROFILE" = "role-profile" ] || exit 7
        \\if [ "$2" = "get" ]; then echo ap-southeast-2; else exec /bin/cat "$FIXTURE_CREDENTIALS"; fi
        \\
    , .flags = .{ .permissions = .fromMode(0o755) } });
    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    try env.put("AWS_PROFILE", "role-profile");
    try env.put("FIXTURE_CREDENTIALS", output);
    const region = try regionAlloc(allocator, io, &env, script);
    defer allocator.free(region);
    try std.testing.expectEqualStrings("ap-southeast-2", region);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = output, .data =
        \\{"Version":1,"AccessKeyId":"FIRSTKEY","SecretAccessKey":"first-secret","SessionToken":"first-token","Expiration":"2099-01-01T00:00:00Z"}
    });
    var provider = try Provider.init(allocator, io, &env, script);
    defer provider.deinit();
    const first = try provider.signGet(allocator, region, "bucket.s3.ap-southeast-2.amazonaws.com", "/key", 0);
    defer allocator.free(first.session_token.?);
    try std.testing.expectEqualStrings("first-token", first.session_token.?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = output, .data =
        \\{"Version":1,"AccessKeyId":"SECONDKEY","SecretAccessKey":"second-secret","SessionToken":"second-token","Expiration":"2099-01-02T00:00:00+00:00"}
    });
    // 2099-01-01T00:00:00Z: refresh is due; a stale signer would use FIRSTKEY.
    const second = try provider.signGet(allocator, region, "bucket.s3.ap-southeast-2.amazonaws.com", "/key", 4070908800);
    defer allocator.free(second.session_token.?);
    try std.testing.expect(std.mem.indexOf(u8, second.authorization(), "Credential=SECONDKEY/") != null);
    try std.testing.expectEqualStrings("first-token", first.session_token.?);
    try std.testing.expectEqualStrings("second-token", second.session_token.?);
    // Expired output is refused, never silently replaced with stale credentials.
    try std.testing.expectError(error.AwsCredentialsExpired, provider.signGet(allocator, region, "host", "/key", 4070995200));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = output, .data = "not credential JSON" });
    try std.testing.expectError(error.AwsCredentialsInvalid, provider.signGet(allocator, region, "host", "/key", 4070995200));
    try std.testing.expectError(error.AwsCliUnavailable, Provider.init(allocator, io, &env, "/missing/aws"));
}

fn fuzzCredentials(_: void, smith: *std.testing.Smith) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [4096]u8 = undefined;
    const bytes = buf[0..smith.slice(&buf)];
    _ = parse(arena.allocator(), bytes) catch return;
}

test "fuzz AWS process credentials" {
    try std.testing.fuzz({}, fuzzCredentials, .{ .corpus = &.{
        "",
        "{\"Version\":1,\"AccessKeyId\":\"KEY\",\"SecretAccessKey\":\"secret\"}",
        "{\"Version\":1,\"AccessKeyId\":\"KEY\",\"SecretAccessKey\":\"secret\",\"Expiration\":\"2028-02-29T23:59:59Z\"}",
        "{\"Version\":1,\"AccessKeyId\":\"KEY\",\"SecretAccessKey\":\"secret\",\"Expiration\":\"2027-02-29T00:00:00Z\"}",
    } });
}
