//! SporeVM-managed network egress policy.

const std = @import("std");

pub const max_allow_cidrs = 16;
pub const max_allow_hosts = 16;
pub const max_learned_host_ips = 64;

pub const ParseError = error{
    InvalidCidr,
    InvalidHost,
    TooManyAllowCidrs,
    TooManyAllowHosts,
};

pub const Decision = enum {
    allow,
    deny_hard_floor,
    deny_not_allowed,

    pub fn name(self: Decision) []const u8 {
        return switch (self) {
            .allow => "allow",
            .deny_hard_floor => "hard-floor",
            .deny_not_allowed => "not-allowed",
        };
    }
};

pub const Cidr = struct {
    network: [4]u8,
    prefix_len: u8,

    pub fn contains(self: Cidr, addr: [4]u8) bool {
        const mask = prefixMask(self.prefix_len);
        return (ipv4ToU32(addr) & mask) == (ipv4ToU32(self.network) & mask);
    }
};

pub const Config = struct {
    allow_cidrs: [max_allow_cidrs][]const u8 = [_][]const u8{""} ** max_allow_cidrs,
    allow_cidr_count: usize = 0,
    allow_hosts: [max_allow_hosts][]const u8 = [_][]const u8{""} ** max_allow_hosts,
    allow_host_count: usize = 0,

    pub fn addAllowCidr(self: *Config, raw: []const u8) ParseError!void {
        _ = try parseCidr(raw);
        if (self.allow_cidr_count >= max_allow_cidrs) return error.TooManyAllowCidrs;
        self.allow_cidrs[self.allow_cidr_count] = raw;
        self.allow_cidr_count += 1;
    }

    pub fn addAllowHost(self: *Config, raw: []const u8) ParseError!void {
        try validateHost(raw);
        if (self.allow_host_count >= max_allow_hosts) return error.TooManyAllowHosts;
        self.allow_hosts[self.allow_host_count] = raw;
        self.allow_host_count += 1;
    }

    pub fn hasRules(self: Config) bool {
        return self.allow_cidr_count != 0 or self.allow_host_count != 0;
    }

    pub fn allowCidrSlice(self: *const Config) []const []const u8 {
        return self.allow_cidrs[0..self.allow_cidr_count];
    }

    pub fn allowHostSlice(self: *const Config) []const []const u8 {
        return self.allow_hosts[0..self.allow_host_count];
    }
};

const LearnedHostIp = struct {
    host_index: usize,
    addr: [4]u8,
};

pub const Runtime = struct {
    allow_cidrs: [max_allow_cidrs]Cidr = undefined,
    allow_cidr_count: usize = 0,
    allow_hosts: [max_allow_hosts][]const u8 = [_][]const u8{""} ** max_allow_hosts,
    allow_host_count: usize = 0,
    learned_host_ips: [max_learned_host_ips]LearnedHostIp = undefined,
    learned_host_ip_count: usize = 0,

    pub fn init(config: Config) ParseError!Runtime {
        var runtime = Runtime{};
        for (config.allowCidrSlice()) |raw| {
            runtime.allow_cidrs[runtime.allow_cidr_count] = try parseCidr(raw);
            runtime.allow_cidr_count += 1;
        }
        for (config.allowHostSlice()) |raw| {
            try validateHost(raw);
            runtime.allow_hosts[runtime.allow_host_count] = raw;
            runtime.allow_host_count += 1;
        }
        return runtime;
    }

    pub fn decideIpv4(self: *const Runtime, addr: [4]u8) Decision {
        if (isHardFloorBlocked(addr)) return .deny_hard_floor;
        if (!self.hasAllowRules()) return .allow;
        for (self.allow_cidrs[0..self.allow_cidr_count]) |cidr| {
            if (cidr.contains(addr)) return .allow;
        }
        for (self.learned_host_ips[0..self.learned_host_ip_count]) |learned| {
            if (std.mem.eql(u8, &learned.addr, &addr)) return .allow;
        }
        return .deny_not_allowed;
    }

    pub fn noteDnsResponse(self: *Runtime, query: []const u8, response: []const u8) usize {
        if (self.allow_host_count == 0) return 0;
        if (query.len < dns_header_len or response.len < dns_header_len) return 0;
        if (!std.mem.eql(u8, query[0..2], response[0..2])) return 0;
        const flags = std.mem.readInt(u16, response[2..4], .big);
        if ((flags & 0x8000) == 0) return 0;
        if (std.mem.readInt(u16, query[4..6], .big) != 1) return 0;
        if (std.mem.readInt(u16, response[4..6], .big) != 1) return 0;

        const query_name_end = skipDnsName(query, dns_header_len) orelse return 0;
        if (query_name_end + 4 > query.len) return 0;
        const qtype = std.mem.readInt(u16, query[query_name_end..][0..2], .big);
        const qclass = std.mem.readInt(u16, query[query_name_end + 2 ..][0..2], .big);
        if (qtype != dns_type_a or qclass != dns_class_in) return 0;

        const host_index = self.allowedHostIndexForDnsName(query, dns_header_len) orelse return 0;
        const host = self.allow_hosts[host_index];

        var offset = skipDnsName(response, dns_header_len) orelse return 0;
        if (offset + 4 > response.len) return 0;
        offset += 4;

        var learned: usize = 0;
        const answer_count = std.mem.readInt(u16, response[6..8], .big);
        var i: usize = 0;
        while (i < answer_count) : (i += 1) {
            const name_start = offset;
            const name_end = skipDnsName(response, offset) orelse return learned;
            if (name_end + 10 > response.len) return learned;
            const answer_type = std.mem.readInt(u16, response[name_end..][0..2], .big);
            const answer_class = std.mem.readInt(u16, response[name_end + 2 ..][0..2], .big);
            const data_len = std.mem.readInt(u16, response[name_end + 8 ..][0..2], .big);
            const data_start = name_end + 10;
            const data_end = data_start + @as(usize, data_len);
            if (data_end > response.len) return learned;

            if (answer_type == dns_type_a and answer_class == dns_class_in and data_len == 4 and
                dnsNameMatchesHost(response, name_start, host))
            {
                var addr: [4]u8 = undefined;
                @memcpy(&addr, response[data_start..data_end]);
                if (self.recordLearnedHostIp(host_index, addr)) learned += 1;
            }
            offset = data_end;
        }
        return learned;
    }

    fn hasAllowRules(self: *const Runtime) bool {
        return self.allow_cidr_count != 0 or self.allow_host_count != 0;
    }

    fn allowedHostIndexForDnsName(self: *const Runtime, packet: []const u8, offset: usize) ?usize {
        for (self.allow_hosts[0..self.allow_host_count], 0..) |host, i| {
            if (dnsNameMatchesHost(packet, offset, host)) return i;
        }
        return null;
    }

    fn recordLearnedHostIp(self: *Runtime, host_index: usize, addr: [4]u8) bool {
        for (self.learned_host_ips[0..self.learned_host_ip_count]) |learned| {
            if (learned.host_index == host_index and std.mem.eql(u8, &learned.addr, &addr)) return false;
        }
        if (self.learned_host_ip_count >= max_learned_host_ips) return false;
        self.learned_host_ips[self.learned_host_ip_count] = .{ .host_index = host_index, .addr = addr };
        self.learned_host_ip_count += 1;
        return true;
    }
};

const dns_header_len = 12;
const dns_type_a = 1;
const dns_class_in = 1;

pub fn parseCidr(raw: []const u8) ParseError!Cidr {
    const slash = std.mem.indexOfScalar(u8, raw, '/') orelse return error.InvalidCidr;
    if (std.mem.indexOfScalar(u8, raw[slash + 1 ..], '/') != null) return error.InvalidCidr;
    const addr = parseIpv4(raw[0..slash]) orelse return error.InvalidCidr;
    const prefix = std.fmt.parseUnsigned(u8, raw[slash + 1 ..], 10) catch return error.InvalidCidr;
    if (prefix > 32) return error.InvalidCidr;
    return .{ .network = addr, .prefix_len = prefix };
}

pub fn validateHost(raw: []const u8) ParseError!void {
    if (raw.len == 0 or raw.len > 253) return error.InvalidHost;
    var label_len: usize = 0;
    var prev: u8 = 0;
    for (raw, 0..) |c, i| {
        if (c == '.') {
            if (label_len == 0 or prev == '-') return error.InvalidHost;
            label_len = 0;
            prev = c;
            continue;
        }
        if (!(std.ascii.isAlphanumeric(c) or c == '-')) return error.InvalidHost;
        if (label_len == 0 and c == '-') return error.InvalidHost;
        label_len += 1;
        if (label_len > 63) return error.InvalidHost;
        prev = c;
        _ = i;
    }
    if (label_len == 0 or prev == '-') return error.InvalidHost;
}

pub fn isHardFloorBlocked(addr: [4]u8) bool {
    if (addr[0] == 0) return true;
    if (addr[0] == 10) return true;
    if (addr[0] == 127) return true;
    if (addr[0] == 169 and addr[1] == 254) return true;
    if (addr[0] == 172 and (addr[1] & 0xf0) == 16) return true;
    if (addr[0] == 192 and addr[1] == 168) return true;
    if (addr[0] == 100 and (addr[1] & 0xc0) == 64) return true;
    if (addr[0] == 192 and addr[1] == 0 and addr[2] == 0) return true;
    if (addr[0] == 198 and (addr[1] == 18 or addr[1] == 19)) return true;
    if (addr[0] >= 224) return true;
    return false;
}

fn parseIpv4(raw: []const u8) ?[4]u8 {
    var ip: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, raw, '.');
    var i: usize = 0;
    while (parts.next()) |part| {
        if (i >= ip.len or part.len == 0) return null;
        ip[i] = std.fmt.parseUnsigned(u8, part, 10) catch return null;
        i += 1;
    }
    if (i != ip.len) return null;
    return ip;
}

fn ipv4ToU32(addr: [4]u8) u32 {
    return (@as(u32, addr[0]) << 24) |
        (@as(u32, addr[1]) << 16) |
        (@as(u32, addr[2]) << 8) |
        @as(u32, addr[3]);
}

fn prefixMask(prefix_len: u8) u32 {
    if (prefix_len == 0) return 0;
    const shift: u5 = @intCast(32 - prefix_len);
    return @as(u32, std.math.maxInt(u32)) << shift;
}

fn skipDnsName(packet: []const u8, start: usize) ?usize {
    var offset = start;
    var end: ?usize = null;
    var jumps: usize = 0;
    while (true) {
        if (offset >= packet.len) return null;
        const len = packet[offset];
        if ((len & 0xc0) == 0xc0) {
            if (offset + 1 >= packet.len) return null;
            const pointer = (@as(usize, len & 0x3f) << 8) | packet[offset + 1];
            if (pointer >= packet.len) return null;
            if (end == null) end = offset + 2;
            jumps += 1;
            if (jumps > 16) return null;
            offset = pointer;
            continue;
        }
        if ((len & 0xc0) != 0) return null;
        offset += 1;
        if (len == 0) return end orelse offset;
        if (len > 63 or offset + len > packet.len) return null;
        offset += len;
    }
}

fn dnsNameMatchesHost(packet: []const u8, start: usize, host: []const u8) bool {
    var offset = start;
    var host_i: usize = 0;
    var jumps: usize = 0;
    var first_label = true;
    while (true) {
        if (offset >= packet.len) return false;
        const len = packet[offset];
        if ((len & 0xc0) == 0xc0) {
            if (offset + 1 >= packet.len) return false;
            const pointer = (@as(usize, len & 0x3f) << 8) | packet[offset + 1];
            if (pointer >= packet.len) return false;
            jumps += 1;
            if (jumps > 16) return false;
            offset = pointer;
            continue;
        }
        if ((len & 0xc0) != 0 or len > 63) return false;
        offset += 1;
        if (len == 0) return host_i == host.len;
        if (!first_label) {
            if (host_i >= host.len or host[host_i] != '.') return false;
            host_i += 1;
        }
        first_label = false;
        if (host_i + len > host.len or offset + len > packet.len) return false;
        for (packet[offset..][0..len]) |c| {
            if (lowerAscii(c) != lowerAscii(host[host_i])) return false;
            host_i += 1;
        }
        offset += len;
    }
}

fn lowerAscii(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + ('a' - 'A');
    return c;
}

fn testDnsQuery(id: u16, qname: []const u8, out: *[512]u8) []const u8 {
    std.mem.writeInt(u16, out[0..2], id, .big);
    std.mem.writeInt(u16, out[2..4], 0x0100, .big);
    std.mem.writeInt(u16, out[4..6], 1, .big);
    std.mem.writeInt(u16, out[6..8], 0, .big);
    std.mem.writeInt(u16, out[8..10], 0, .big);
    std.mem.writeInt(u16, out[10..12], 0, .big);
    var len: usize = dns_header_len;
    var labels = std.mem.splitScalar(u8, qname, '.');
    while (labels.next()) |label| {
        out[len] = @intCast(label.len);
        len += 1;
        @memcpy(out[len..][0..label.len], label);
        len += label.len;
    }
    out[len] = 0;
    len += 1;
    std.mem.writeInt(u16, out[len..][0..2], dns_type_a, .big);
    len += 2;
    std.mem.writeInt(u16, out[len..][0..2], dns_class_in, .big);
    len += 2;
    return out[0..len];
}

fn testDnsResponse(query: []const u8, answer_owner: []const u8, answers: []const [4]u8, out: *[512]u8) []const u8 {
    @memcpy(out[0..query.len], query);
    std.mem.writeInt(u16, out[2..4], 0x8180, .big);
    std.mem.writeInt(u16, out[6..8], @intCast(answers.len), .big);
    var len = query.len;
    for (answers) |addr| {
        if (std.mem.eql(u8, answer_owner, "*")) {
            out[len] = 0xc0;
            out[len + 1] = dns_header_len;
            len += 2;
        } else {
            var labels = std.mem.splitScalar(u8, answer_owner, '.');
            while (labels.next()) |label| {
                out[len] = @intCast(label.len);
                len += 1;
                @memcpy(out[len..][0..label.len], label);
                len += label.len;
            }
            out[len] = 0;
            len += 1;
        }
        std.mem.writeInt(u16, out[len..][0..2], dns_type_a, .big);
        len += 2;
        std.mem.writeInt(u16, out[len..][0..2], dns_class_in, .big);
        len += 2;
        std.mem.writeInt(u32, out[len..][0..4], 60, .big);
        len += 4;
        std.mem.writeInt(u16, out[len..][0..2], 4, .big);
        len += 2;
        @memcpy(out[len..][0..4], &addr);
        len += 4;
    }
    return out[0..len];
}

test "spore-net policy default allows public and blocks hard floor" {
    const policy = try Runtime.init(.{});
    try std.testing.expectEqual(Decision.allow, policy.decideIpv4(.{ 93, 184, 216, 34 }));
    try std.testing.expectEqual(Decision.deny_hard_floor, policy.decideIpv4(.{ 169, 254, 169, 254 }));
}

test "spore-net policy allow CIDR uses exact prefix matches" {
    var config = Config{};
    try config.addAllowCidr("93.184.216.0/24");
    const policy = try Runtime.init(config);
    try std.testing.expectEqual(Decision.allow, policy.decideIpv4(.{ 93, 184, 216, 34 }));
    try std.testing.expectEqual(Decision.deny_not_allowed, policy.decideIpv4(.{ 93, 184, 217, 1 }));
}

test "spore-net policy hard floor wins over allow CIDR" {
    var config = Config{};
    try config.addAllowCidr("169.254.0.0/16");
    const policy = try Runtime.init(config);
    try std.testing.expectEqual(Decision.deny_hard_floor, policy.decideIpv4(.{ 169, 254, 169, 254 }));
}

test "spore-net policy allow host learns matching public DNS answers" {
    var config = Config{};
    try config.addAllowHost("example.com");
    var policy = try Runtime.init(config);

    try std.testing.expectEqual(Decision.deny_not_allowed, policy.decideIpv4(.{ 93, 184, 216, 34 }));

    var query_buf: [512]u8 = undefined;
    const query = testDnsQuery(0x1234, "example.com", &query_buf);
    var response_buf: [512]u8 = undefined;
    const response = testDnsResponse(query, "*", &.{.{ 93, 184, 216, 34 }}, &response_buf);
    try std.testing.expectEqual(@as(usize, 1), policy.noteDnsResponse(query, response));
    try std.testing.expectEqual(Decision.allow, policy.decideIpv4(.{ 93, 184, 216, 34 }));
}

test "spore-net policy ignores unrelated additional DNS answer owners" {
    var config = Config{};
    try config.addAllowHost("example.com");
    var policy = try Runtime.init(config);

    var query_buf: [512]u8 = undefined;
    const query = testDnsQuery(0x1234, "example.com", &query_buf);
    var response_buf: [512]u8 = undefined;
    const response = testDnsResponse(query, "other.example", &.{.{ 93, 184, 216, 34 }}, &response_buf);
    try std.testing.expectEqual(@as(usize, 0), policy.noteDnsResponse(query, response));
    try std.testing.expectEqual(Decision.deny_not_allowed, policy.decideIpv4(.{ 93, 184, 216, 34 }));
}

test "spore-net policy DNS rebinding answers cannot override hard floor" {
    var config = Config{};
    try config.addAllowHost("example.com");
    var policy = try Runtime.init(config);

    var query_buf: [512]u8 = undefined;
    const query = testDnsQuery(0x1234, "example.com", &query_buf);
    var response_buf: [512]u8 = undefined;
    const response = testDnsResponse(query, "*", &.{.{ 169, 254, 169, 254 }, .{ 93, 184, 216, 34 }}, &response_buf);
    try std.testing.expectEqual(@as(usize, 2), policy.noteDnsResponse(query, response));
    try std.testing.expectEqual(Decision.deny_hard_floor, policy.decideIpv4(.{ 169, 254, 169, 254 }));
    try std.testing.expectEqual(Decision.allow, policy.decideIpv4(.{ 93, 184, 216, 34 }));
}
