//! Host-side network fetch target policy.

const std = @import("std");

const Io = std.Io;
const HostName = Io.net.HostName;
const IpAddress = Io.net.IpAddress;
const Ip4Address = Io.net.Ip4Address;

pub const Options = struct {
    require_https: bool = false,
};

pub const ConnectionTarget = struct {
    connect_host: HostName,
    logical_host: HostName,
    port: u16,
    protocol: std.http.Client.Protocol,
};

pub const Error = error{
    UnsupportedRemoteFetchScheme,
    UnsafeRemoteFetchTarget,
} || HostName.LookupError;

/// Most validated addresses a fetch keeps from one resolution and tries in
/// turn, so a host with many dead frontends cannot stall a fetch indefinitely.
pub const max_addresses = 4;

/// The validated addresses of one resolution, in resolver order. Never empty.
pub const Addresses = struct {
    items: [max_addresses]IpAddress = undefined,
    len: usize = 0,

    pub fn slice(self: *const Addresses) []const IpAddress {
        return self.items[0..self.len];
    }

    fn append(self: *Addresses, address: IpAddress) void {
        if (self.len == max_addresses) return;
        self.items[self.len] = address;
        self.len += 1;
    }
};

pub fn validateUrl(io: Io, raw_url: []const u8, options: Options) !void {
    _ = try resolveUrlAddresses(io, raw_url, options);
}

pub fn resolveUrlAddresses(io: Io, raw_url: []const u8, options: Options) !Addresses {
    const uri = try std.Uri.parse(raw_url);
    return resolveUriAddresses(io, uri, options);
}

pub fn validateUri(io: Io, uri: std.Uri, options: Options) Error!void {
    _ = try resolveUriAddresses(io, uri, options);
}

pub fn resolveUriAddresses(io: Io, uri: std.Uri, options: Options) Error!Addresses {
    if (options.require_https) {
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.UnsupportedRemoteFetchScheme;
    } else if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        return error.UnsupportedRemoteFetchScheme;
    }

    const port = normalizedPort(uri) orelse return error.UnsupportedRemoteFetchScheme;
    var host_buffer: [HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_buffer) catch return error.UnsafeRemoteFetchTarget;
    return resolveHostAddresses(io, host.bytes, port);
}

pub fn validateHost(io: Io, raw_host: []const u8, port: u16) Error!void {
    _ = try resolveHostAddresses(io, raw_host, port);
}

/// Resolves `raw_host` and validates every answer: one unsafe address fails
/// the whole resolution, even past the `max_addresses` kept for connecting.
pub fn resolveHostAddresses(io: Io, raw_host: []const u8, port: u16) Error!Addresses {
    var addresses: Addresses = .{};
    if (parseIpLiteral(raw_host, port)) |addr| {
        try validateAddress(addr);
        addresses.append(addr);
        return addresses;
    }

    const host = HostName.init(raw_host) catch return error.UnsafeRemoteFetchTarget;
    var result_buffer: [32]HostName.LookupResult = undefined;
    var results: Io.Queue(HostName.LookupResult) = .init(&result_buffer);
    try HostName.lookup(host, io, &results, .{ .port = port });

    while (results.getOneUncancelable(io)) |result| {
        switch (result) {
            .address => |address| {
                try validateAddress(address);
                addresses.append(address);
            },
            .canonical_name => {},
        }
    } else |err| switch (err) {
        error.Closed => {},
    }
    if (addresses.len == 0) return error.UnsafeRemoteFetchTarget;
    return addresses;
}

pub fn connectionTarget(uri: std.Uri, address: IpAddress, address_buffer: *[HostName.max_len]u8, logical_host_buffer: *[HostName.max_len]u8) Error!ConnectionTarget {
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.UnsupportedRemoteFetchScheme;
    const port = normalizedPort(uri) orelse return error.UnsupportedRemoteFetchScheme;
    const logical_host = uri.getHost(logical_host_buffer) catch return error.UnsafeRemoteFetchTarget;
    const connect_host = HostName{ .bytes = formatAddressHost(address, address_buffer) catch return error.UnsafeRemoteFetchTarget };
    return .{
        .connect_host = connect_host,
        .logical_host = logical_host,
        .port = port,
        .protocol = protocol,
    };
}

pub fn connectResolvedUri(client: *std.http.Client, uri: std.Uri, address: IpAddress) !*std.http.Client.Connection {
    var address_buffer: [HostName.max_len]u8 = undefined;
    var logical_host_buffer: [HostName.max_len]u8 = undefined;
    const target = try connectionTarget(uri, address, &address_buffer, &logical_host_buffer);
    try ensureTlsReady(client, target.protocol);
    return client.connectTcpOptions(.{
        .host = target.connect_host,
        .port = target.port,
        .protocol = target.protocol,
        .proxied_host = target.logical_host,
        .proxied_port = target.port,
    });
}

/// Sends a bodiless GET for `uri` to each of `addresses` in turn and returns
/// the first response head, leaving the request in `req` for the caller to
/// read and `deinit`. An address is skipped only when connecting to it fails
/// or the connection closes or resets before any response head arrives;
/// nothing has been answered and a GET is idempotent, so the next address may
/// serve it. Any response, whatever its status, and every other error end the
/// attempt. The last address's error is returned when none answers.
pub fn getHead(
    client: *std.http.Client,
    uri: std.Uri,
    addresses: []const IpAddress,
    options: std.http.Client.RequestOptions,
    req: *std.http.Client.Request,
    head_buffer: []u8,
) !std.http.Client.Response {
    for (addresses, 1..) |address, attempt| {
        const last = attempt == addresses.len;
        const connection = connectResolvedUri(client, uri, address) catch |err| {
            if (last or !addressFailed(err)) return err;
            continue;
        };
        var request_options = options;
        request_options.connection = connection;
        req.* = client.request(.GET, uri, request_options) catch |err| {
            client.connection_pool.release(connection, client.io);
            return err;
        };
        req.sendBodiless() catch |err| {
            req.deinit();
            if (last or !addressFailed(err)) return err;
            continue;
        };
        return req.receiveHead(head_buffer) catch |err| {
            req.deinit();
            if (last or !addressFailed(err)) return err;
            continue;
        };
    }
    return error.UnsafeRemoteFetchTarget;
}

/// Errors that mean an address did not answer: the connection or TLS
/// handshake failed, or the connection closed or reset before a response head.
fn addressFailed(err: anyerror) bool {
    return switch (err) {
        error.AddressUnavailable,
        error.AddressFamilyUnsupported,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.HostUnreachable,
        error.NetworkUnreachable,
        error.NetworkDown,
        error.Timeout,
        error.TlsInitializationFailed,
        error.HttpConnectionClosing,
        error.ReadFailed,
        error.WriteFailed,
        => true,
        else => false,
    };
}

fn ensureTlsReady(client: *std.http.Client, protocol: std.http.Client.Protocol) !void {
    if (protocol != .tls) return;
    if (std.http.Client.disable_tls) unreachable;

    // connectTcpOptions bypasses Client.request's lazy TLS setup. Initialize
    // the clock and CA bundle here before connecting to a resolved address.
    {
        try client.ca_bundle_lock.lockShared(client.io);
        defer client.ca_bundle_lock.unlockShared(client.io);
        if (client.now != null) return;
    }

    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(client.allocator);
    const now = Io.Clock.real.now(client.io);
    bundle.rescan(client.allocator, client.io, now) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return error.CertificateBundleLoadFailure,
    };

    try client.ca_bundle_lock.lock(client.io);
    defer client.ca_bundle_lock.unlock(client.io);
    if (client.now != null) return;
    client.now = now;
    std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
}

pub fn validateAddress(address: IpAddress) Error!void {
    const ok = switch (address) {
        .ip4 => |ip4| isPublicIpv4(ip4.bytes),
        .ip6 => |ip6| isPublicIpv6(ip6.bytes),
    };
    if (!ok) return error.UnsafeRemoteFetchTarget;
}

fn parseIpLiteral(raw_host: []const u8, port: u16) ?IpAddress {
    if (raw_host.len >= 2 and raw_host[0] == '[' and raw_host[raw_host.len - 1] == ']') {
        return IpAddress.parse(raw_host[1 .. raw_host.len - 1], port) catch null;
    }
    return IpAddress.parse(raw_host, port) catch null;
}

fn formatAddressHost(address: IpAddress, buffer: *[HostName.max_len]u8) Io.Writer.Error![]const u8 {
    var writer: Io.Writer = .fixed(buffer);
    switch (address) {
        .ip4 => |ip4| {
            const bytes = ip4.bytes;
            try writer.print("{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
        },
        .ip6 => |ip6| {
            const unresolved: Io.net.Ip6Address.Unresolved = .{ .bytes = ip6.bytes, .interface_name = null };
            try unresolved.format(&writer);
        },
    }
    return writer.buffered();
}

fn normalizedPort(uri: std.Uri) ?u16 {
    if (uri.port) |port| return port;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return 443;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) return 80;
    return null;
}

fn isPublicIpv4(addr: [4]u8) bool {
    if (addr[0] == 0) return false;
    if (addr[0] == 10) return false;
    if (addr[0] == 100 and (addr[1] & 0xc0) == 64) return false;
    if (addr[0] == 127) return false;
    if (addr[0] == 169 and addr[1] == 254) return false;
    if (addr[0] == 172 and (addr[1] & 0xf0) == 16) return false;
    if (addr[0] == 192 and addr[1] == 0 and addr[2] == 0) return false;
    if (addr[0] == 192 and addr[1] == 0 and addr[2] == 2) return false;
    if (addr[0] == 192 and addr[1] == 31 and addr[2] == 196) return false;
    if (addr[0] == 192 and addr[1] == 52 and addr[2] == 193) return false;
    if (addr[0] == 192 and addr[1] == 88 and addr[2] == 99) return false;
    if (addr[0] == 192 and addr[1] == 175 and addr[2] == 48) return false;
    if (addr[0] == 192 and addr[1] == 168) return false;
    if (addr[0] == 198 and (addr[1] == 18 or addr[1] == 19)) return false;
    if (addr[0] == 198 and addr[1] == 51 and addr[2] == 100) return false;
    if (addr[0] == 203 and addr[1] == 0 and addr[2] == 113) return false;
    if (addr[0] >= 224) return false;
    return true;
}

fn isPublicIpv6(addr: [16]u8) bool {
    const ip6: Io.net.Ip6Address = .{ .bytes = addr, .port = 0 };
    if (Ip4Address.fromIp6(ip6)) |ip4| return isPublicIpv4(ip4.bytes);

    if (ip6.isLoopBack()) return false;
    if (ip6.isLinkLocal()) return false;
    if (ip6.isSiteLocal()) return false;
    if (ip6.isMultiCast()) return false;
    if ((addr[0] & 0xfe) == 0xfc) return false;
    if (std.mem.allEqual(u8, &addr, 0)) return false;
    if (addr[0] == 0x20 and addr[1] == 0x01 and (addr[2] & 0xfe) == 0x00) return false;
    if (addr[0] == 0x20 and addr[1] == 0x01 and addr[2] == 0x0d and addr[3] == 0xb8) return false;
    if (addr[0] == 0x20 and addr[1] == 0x02) return false;
    return (addr[0] & 0xe0) == 0x20;
}

test "fetch target policy rejects internal IPv4 literals" {
    try std.testing.expectError(error.UnsafeRemoteFetchTarget, validateUrl(std.testing.io, "https://127.0.0.1/resource", .{ .require_https = true }));
    try std.testing.expectError(error.UnsafeRemoteFetchTarget, validateUrl(std.testing.io, "https://169.254.169.254/latest/meta-data", .{ .require_https = true }));
    try std.testing.expectError(error.UnsafeRemoteFetchTarget, validateUrl(std.testing.io, "https://10.0.0.5/object", .{ .require_https = true }));
    try std.testing.expectError(error.UnsafeRemoteFetchTarget, validateUrl(std.testing.io, "https://192.168.1.10/object", .{ .require_https = true }));
}

test "fetch target policy rejects reserved IPv4 literals" {
    try std.testing.expectError(error.UnsafeRemoteFetchTarget, validateUrl(std.testing.io, "https://0.0.0.0/resource", .{ .require_https = true }));
    try std.testing.expectError(error.UnsafeRemoteFetchTarget, validateUrl(std.testing.io, "https://100.64.0.1/resource", .{ .require_https = true }));
    try std.testing.expectError(error.UnsafeRemoteFetchTarget, validateUrl(std.testing.io, "https://192.0.2.1/resource", .{ .require_https = true }));
    try std.testing.expectError(error.UnsafeRemoteFetchTarget, validateUrl(std.testing.io, "https://198.18.0.1/resource", .{ .require_https = true }));
    try std.testing.expectError(error.UnsafeRemoteFetchTarget, validateUrl(std.testing.io, "https://203.0.113.1/resource", .{ .require_https = true }));
    try std.testing.expectError(error.UnsafeRemoteFetchTarget, validateUrl(std.testing.io, "https://224.0.0.1/resource", .{ .require_https = true }));
}

test "fetch target policy rejects internal IPv6 literals" {
    try std.testing.expectError(error.UnsafeRemoteFetchTarget, validateUrl(std.testing.io, "https://[::1]/resource", .{ .require_https = true }));
    try std.testing.expectError(error.UnsafeRemoteFetchTarget, validateUrl(std.testing.io, "https://[fe80::1]/resource", .{ .require_https = true }));
    try std.testing.expectError(error.UnsafeRemoteFetchTarget, validateUrl(std.testing.io, "https://[fc00::1]/resource", .{ .require_https = true }));
    try std.testing.expectError(error.UnsafeRemoteFetchTarget, validateUrl(std.testing.io, "https://[::ffff:127.0.0.1]/resource", .{ .require_https = true }));
}

test "fetch target policy rejects reserved IPv6 literals" {
    try std.testing.expectError(error.UnsafeRemoteFetchTarget, validateUrl(std.testing.io, "https://[2001:db8::1]/resource", .{ .require_https = true }));
    try std.testing.expectError(error.UnsafeRemoteFetchTarget, validateUrl(std.testing.io, "https://[2001:2::1]/resource", .{ .require_https = true }));
    try std.testing.expectError(error.UnsafeRemoteFetchTarget, validateUrl(std.testing.io, "https://[2002::1]/resource", .{ .require_https = true }));
    try std.testing.expectError(error.UnsafeRemoteFetchTarget, validateUrl(std.testing.io, "https://[ff00::1]/resource", .{ .require_https = true }));
}

test "fetch target policy accepts public literals and enforces https when required" {
    try validateUrl(std.testing.io, "https://1.1.1.1/resource", .{ .require_https = true });
    try validateUrl(std.testing.io, "https://[2606:4700:4700::1111]/resource", .{ .require_https = true });
    try validateUrl(std.testing.io, "http://1.1.1.1/resource", .{});
    try std.testing.expectError(error.UnsupportedRemoteFetchScheme, validateUrl(std.testing.io, "http://1.1.1.1/resource", .{ .require_https = true }));
}

test "fetch target policy connects to checked address while preserving logical host" {
    const uri = try std.Uri.parse("https://rebind.example/path");
    const address4 = try IpAddress.parse("93.184.216.34", 443);

    var address_buffer: [HostName.max_len]u8 = undefined;
    var logical_host_buffer: [HostName.max_len]u8 = undefined;
    const target = try connectionTarget(uri, address4, &address_buffer, &logical_host_buffer);

    try std.testing.expectEqualStrings("93.184.216.34", target.connect_host.bytes);
    try std.testing.expectEqualStrings("rebind.example", target.logical_host.bytes);
    try std.testing.expectEqual(@as(u16, 443), target.port);
    try std.testing.expectEqual(std.http.Client.Protocol.tls, target.protocol);

    const address6 = try IpAddress.parse("2606:4700:4700::1111", 443);
    const target6 = try connectionTarget(uri, address6, &address_buffer, &logical_host_buffer);
    try std.testing.expectEqualStrings("2606:4700:4700::1111", target6.connect_host.bytes);
    try std.testing.expectEqualStrings("rebind.example", target6.logical_host.bytes);
}

test "fetch target policy initializes tls state for resolved-address connects" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();

    try ensureTlsReady(&client, .plain);
    try std.testing.expect(client.now == null);

    if (std.http.Client.disable_tls) return error.SkipZigTest;
    try ensureTlsReady(&client, .tls);
    try std.testing.expect(client.now != null);
}

/// Loopback HTTP server that answers its nth connection with `replies[n]`
/// after reading the request head, and closes without replying when that
/// entry is null or past the end.
const TestServer = struct {
    io: Io,
    server: Io.net.Server,
    replies: []const ?[]const u8,
    thread: std.Thread = undefined,
    closed: std.atomic.Value(bool) = .init(false),
    accepted: usize = 0,

    fn start(self: *TestServer, replies: []const ?[]const u8) !void {
        var address = try IpAddress.parseIp4("127.0.0.1", 0);
        self.* = .{
            .io = std.testing.io,
            .server = try address.listen(std.testing.io, .{ .kernel_backlog = 8, .reuse_address = true }),
            .replies = replies,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    /// Stops the server and returns how many connections it accepted.
    fn stop(self: *TestServer) usize {
        self.closed.store(true, .release);
        if (self.server.socket.address.connect(self.io, .{ .mode = .stream })) |stream| stream.close(self.io) else |_| {}
        self.thread.join();
        self.server.deinit(self.io);
        return self.accepted;
    }

    fn serve(self: *TestServer) void {
        while (true) {
            const stream = self.server.accept(self.io) catch return;
            defer stream.close(self.io);
            if (self.closed.load(.acquire)) return;
            const reply = if (self.accepted < self.replies.len) self.replies[self.accepted] else null;
            self.accepted += 1;

            var read_buffer: [1024]u8 = undefined;
            var reader = stream.reader(self.io, &read_buffer);
            while (reader.interface.takeDelimiter('\n') catch return) |line| {
                if (std.mem.trimEnd(u8, line, "\r").len == 0) break;
            }
            var write_buffer: [256]u8 = undefined;
            var writer = stream.writer(self.io, &write_buffer);
            writer.interface.writeAll(reply orelse continue) catch return;
            writer.interface.flush() catch return;
        }
    }

    /// GETs from the server through `address_count` copies of its address.
    fn getStatus(self: *TestServer, address_count: usize) !std.http.Status {
        var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = self.io };
        defer client.deinit();
        var url_buffer: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/file", .{self.server.socket.address.getPort()});
        var addresses: Addresses = .{};
        for (0..address_count) |_| addresses.append(self.server.socket.address);

        var req: std.http.Client.Request = undefined;
        var head_buffer: [1024]u8 = undefined;
        const response = try getHead(&client, try std.Uri.parse(url), addresses.slice(), .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
        }, &req, &head_buffer);
        defer req.deinit();
        return response.head.status;
    }
};

const test_ok_reply = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

test "fetch GET moves to the next address when one closes before a response head" {
    var server: TestServer = undefined;
    try server.start(&.{ null, test_ok_reply });
    const status = server.getStatus(2);
    try std.testing.expectEqual(@as(usize, 2), server.stop());
    try std.testing.expectEqual(std.http.Status.ok, try status);
}

test "fetch GET returns the last address's error when none answers" {
    var server: TestServer = undefined;
    try server.start(&.{ null, null });
    const status = server.getStatus(2);
    try std.testing.expectEqual(@as(usize, 2), server.stop());
    try std.testing.expectError(error.HttpConnectionClosing, status);
}

test "fetch GET does not retry another address after a response head" {
    var server: TestServer = undefined;
    try server.start(&.{ "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", test_ok_reply });
    const status = server.getStatus(2);
    try std.testing.expectEqual(@as(usize, 1), server.stop());
    try std.testing.expectEqual(std.http.Status.service_unavailable, try status);
}
