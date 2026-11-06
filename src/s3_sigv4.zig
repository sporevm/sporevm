//! AWS Signature Version 4 for S3 requests, sent in the Authorization header:
//! https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
//!
//! Credentials come from the environment and appear only in the signature
//! and, for a session token, its own header. Nothing here logs.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// The payload hash of a request whose body is not signed.
pub const unsigned_payload = "UNSIGNED-PAYLOAD";
/// `YYYYMMDDTHHMMSSZ`.
pub const amz_date_len = 16;
const max_key_len = 128;
const max_token_len = 8192;
const max_region_len = 32;
const max_authorization_len = 512;

pub const Credentials = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    session_token: ?[]const u8 = null,

    /// `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and the optional
    /// `AWS_SESSION_TOKEN`. The values are borrowed from `env`.
    pub fn fromEnv(env: *const std.process.Environ.Map) !Credentials {
        const credentials = Credentials{
            .access_key_id = nonEmpty(env, "AWS_ACCESS_KEY_ID") orelse return error.AwsCredentialsMissing,
            .secret_access_key = nonEmpty(env, "AWS_SECRET_ACCESS_KEY") orelse return error.AwsCredentialsMissing,
            .session_token = nonEmpty(env, "AWS_SESSION_TOKEN"),
        };
        try credentials.validate();
        return credentials;
    }

    /// The key id goes into the credential scope and the token into a
    /// header, so neither may carry separators or line breaks.
    fn validate(self: Credentials) !void {
        if (self.access_key_id.len > max_key_len or self.secret_access_key.len > max_key_len) return error.AwsCredentialsInvalid;
        for (self.access_key_id) |byte| if (!std.ascii.isAlphanumeric(byte)) return error.AwsCredentialsInvalid;
        if (!visible(self.secret_access_key)) return error.AwsCredentialsInvalid;
        if (self.session_token) |token| if (token.len > max_token_len or !visible(token)) return error.AwsCredentialsInvalid;
    }
};

/// `AWS_REGION`, else `AWS_DEFAULT_REGION`, borrowed from `env`.
pub fn regionFromEnv(env: *const std.process.Environ.Map) ![]const u8 {
    const region = nonEmpty(env, "AWS_REGION") orelse nonEmpty(env, "AWS_DEFAULT_REGION") orelse return error.AwsRegionMissing;
    if (region.len > max_region_len) return error.AwsRegionInvalid;
    for (region) |byte| if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-')) return error.AwsRegionInvalid;
    return region;
}

fn nonEmpty(env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const value = env.get(name) orelse return null;
    return if (value.len == 0) null else value;
}

fn visible(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| if (byte <= ' ' or byte >= 0x7f) return false;
    return true;
}

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: []const u8,
    /// The canonical URI: the absolute path exactly as sent, already encoded.
    path: []const u8,
    region: []const u8,
    amz_date: []const u8,
    payload_hash: []const u8,
    /// The signed headers, with lowercase names sorted by name and values
    /// without surrounding or repeated spaces. The query string is empty.
    headers: []const Header,
};

/// The Authorization header value for `request`, written into `buf`.
pub fn authorization(buf: []u8, credentials: Credentials, request: Request) ![]const u8 {
    if (request.amz_date.len != amz_date_len) return error.InvalidAmzDate;
    const date = request.amz_date[0..8];

    var canonical = Sha256.init(.{});
    canonical.update(request.method);
    canonical.update("\n");
    canonical.update(request.path);
    canonical.update("\n\n");
    for (request.headers) |header| {
        canonical.update(header.name);
        canonical.update(":");
        canonical.update(header.value);
        canonical.update("\n");
    }
    canonical.update("\n");
    for (request.headers, 0..) |header, index| {
        if (index != 0) canonical.update(";");
        canonical.update(header.name);
    }
    canonical.update("\n");
    canonical.update(request.payload_hash);
    var canonical_hash: [Sha256.digest_length]u8 = undefined;
    canonical.final(&canonical_hash);

    var key_buf: [4 + max_key_len]u8 = undefined;
    if (credentials.secret_access_key.len > max_key_len) return error.AwsCredentialsInvalid;
    const secret_key = key_buf[0 .. 4 + credentials.secret_access_key.len];
    @memcpy(secret_key[0..4], "AWS4");
    @memcpy(secret_key[4..], credentials.secret_access_key);
    defer std.crypto.secureZero(u8, secret_key);
    var key: [HmacSha256.mac_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    HmacSha256.create(&key, date, secret_key);
    HmacSha256.create(&key, request.region, &key);
    HmacSha256.create(&key, "s3", &key);
    HmacSha256.create(&key, "aws4_request", &key);

    var mac = HmacSha256.init(&key);
    mac.update("AWS4-HMAC-SHA256\n");
    mac.update(request.amz_date);
    mac.update("\n");
    mac.update(date);
    mac.update("/");
    mac.update(request.region);
    mac.update("/s3/aws4_request\n");
    mac.update(&std.fmt.bytesToHex(canonical_hash, .lower));
    var signature: [HmacSha256.mac_length]u8 = undefined;
    mac.final(&signature);

    var writer: std.Io.Writer = .fixed(buf);
    writer.print("AWS4-HMAC-SHA256 Credential={s}/{s}/{s}/s3/aws4_request,SignedHeaders=", .{ credentials.access_key_id, date, request.region }) catch return error.NoSpaceLeft;
    for (request.headers, 0..) |header, index| {
        if (index != 0) writer.writeByte(';') catch return error.NoSpaceLeft;
        writer.writeAll(header.name) catch return error.NoSpaceLeft;
    }
    writer.print(",Signature={s}", .{&std.fmt.bytesToHex(signature, .lower)}) catch return error.NoSpaceLeft;
    return writer.buffered();
}

/// `YYYYMMDDTHHMMSSZ` for `unix_seconds`, in UTC.
pub fn formatAmzDate(unix_seconds: u64) [amz_date_len]u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = unix_seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    var out: [amz_date_len]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch unreachable;
    return out;
}

/// A GET signed at one moment. Send `headers()` and `authorization()`.
pub const SignedGet = struct {
    host: []const u8,
    session_token: ?[]const u8,
    amz_date: [amz_date_len]u8,
    authorization_buf: [max_authorization_len]u8,
    authorization_len: usize,

    pub fn authorization(self: *const SignedGet) []const u8 {
        return self.authorization_buf[0..self.authorization_len];
    }

    /// The signed headers in canonical order: host, x-amz-content-sha256,
    /// x-amz-date and, with a session token, x-amz-security-token.
    pub fn headers(self: *const SignedGet, buf: *[4]Header) []const Header {
        buf[0] = .{ .name = "host", .value = self.host };
        buf[1] = .{ .name = "x-amz-content-sha256", .value = unsigned_payload };
        buf[2] = .{ .name = "x-amz-date", .value = &self.amz_date };
        const token = self.session_token orelse return buf[0..3];
        buf[3] = .{ .name = "x-amz-security-token", .value = token };
        return buf[0..4];
    }
};

/// Sign a GET of `path` on `host` at `unix_seconds`. The result borrows
/// `host` and the session token.
pub fn signGet(credentials: Credentials, region: []const u8, host: []const u8, path: []const u8, unix_seconds: u64) !SignedGet {
    var signed = SignedGet{
        .host = host,
        .session_token = credentials.session_token,
        .amz_date = formatAmzDate(unix_seconds),
        .authorization_buf = undefined,
        .authorization_len = 0,
    };
    var header_buf: [4]Header = undefined;
    const value = try authorization(&signed.authorization_buf, credentials, .{
        .method = "GET",
        .path = path,
        .region = region,
        .amz_date = &signed.amz_date,
        .payload_hash = unsigned_payload,
        .headers = signed.headers(&header_buf),
    });
    signed.authorization_len = value.len;
    return signed;
}

const example_credentials = Credentials{
    .access_key_id = "AKIAIOSFODNN7EXAMPLE",
    .secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
};

test "SigV4 signs the AWS GET Object example" {
    // https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
    const empty_payload = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    var buf: [max_authorization_len]u8 = undefined;
    const value = try authorization(&buf, example_credentials, .{
        .method = "GET",
        .path = "/test.txt",
        .region = "us-east-1",
        .amz_date = "20130524T000000Z",
        .payload_hash = empty_payload,
        .headers = &.{
            .{ .name = "host", .value = "examplebucket.s3.amazonaws.com" },
            .{ .name = "range", .value = "bytes=0-9" },
            .{ .name = "x-amz-content-sha256", .value = empty_payload },
            .{ .name = "x-amz-date", .value = "20130524T000000Z" },
        },
    });
    try std.testing.expectEqualStrings(
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request," ++
            "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date," ++
            "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
        value,
    );
    try std.testing.expectEqualStrings("20130524T000000Z", &formatAmzDate(1369353600));
}

test "a signed GET signs the session token header only when there is one" {
    const at = 1369353600 + 13 * 3600 + 7 * 60 + 9;
    var buf: [4]Header = undefined;

    const plain = try signGet(example_credentials, "eu-west-1", "bucket.s3.eu-west-1.amazonaws.com", "/team/tags/1", at);
    const plain_headers = plain.headers(&buf);
    try std.testing.expectEqual(@as(usize, 3), plain_headers.len);
    try std.testing.expectEqualStrings("20130524T130709Z", plain_headers[2].value);
    try std.testing.expect(std.mem.startsWith(u8, plain.authorization(), "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/eu-west-1/s3/aws4_request,SignedHeaders=host;x-amz-content-sha256;x-amz-date,Signature="));

    var with_token = example_credentials;
    with_token.session_token = "FQoGZXIvYXdzEXAMPLETOKEN+/=";
    const session = try signGet(with_token, "eu-west-1", "bucket.s3.eu-west-1.amazonaws.com", "/team/tags/1", at);
    const session_headers = session.headers(&buf);
    try std.testing.expectEqual(@as(usize, 4), session_headers.len);
    try std.testing.expectEqualStrings("x-amz-security-token", session_headers[3].name);
    try std.testing.expectEqualStrings(with_token.session_token.?, session_headers[3].value);
    try std.testing.expect(std.mem.startsWith(u8, session.authorization(), "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/eu-west-1/s3/aws4_request,SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token,Signature="));
    // The token is signed, so it changes the signature.
    try std.testing.expect(!std.mem.eql(u8, plain.authorization(), session.authorization()));
    // The secret never appears in what is sent.
    for ([_][]const u8{ plain.authorization(), session.authorization() }) |value| {
        try std.testing.expect(std.mem.indexOf(u8, value, example_credentials.secret_access_key) == null);
    }
}

test "credentials and region come from the standard environment variables" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectError(error.AwsCredentialsMissing, Credentials.fromEnv(&env));
    try std.testing.expectError(error.AwsRegionMissing, regionFromEnv(&env));

    try env.put("AWS_ACCESS_KEY_ID", example_credentials.access_key_id);
    try env.put("AWS_SECRET_ACCESS_KEY", example_credentials.secret_access_key);
    try env.put("AWS_SESSION_TOKEN", "");
    try env.put("AWS_DEFAULT_REGION", "us-west-2");
    var credentials = try Credentials.fromEnv(&env);
    try std.testing.expectEqual(@as(?[]const u8, null), credentials.session_token);
    try std.testing.expectEqualStrings("us-west-2", try regionFromEnv(&env));
    try env.put("AWS_REGION", "ap-southeast-2");
    try std.testing.expectEqualStrings("ap-southeast-2", try regionFromEnv(&env));
    try env.put("AWS_SESSION_TOKEN", "token");
    credentials = try Credentials.fromEnv(&env);
    try std.testing.expectEqualStrings("token", credentials.session_token.?);

    try env.put("AWS_SESSION_TOKEN", "token\r\nx-injected: 1");
    try std.testing.expectError(error.AwsCredentialsInvalid, Credentials.fromEnv(&env));
    try env.put("AWS_SESSION_TOKEN", "token");
    try env.put("AWS_ACCESS_KEY_ID", "AKID/other");
    try std.testing.expectError(error.AwsCredentialsInvalid, Credentials.fromEnv(&env));
    try env.put("AWS_REGION", "us-east-1.evil.example");
    try std.testing.expectError(error.AwsRegionInvalid, regionFromEnv(&env));
}
