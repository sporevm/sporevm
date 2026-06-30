//! SporeVM-managed network egress policy.

const std = @import("std");

const spore = @import("spore.zig");
const spore_net = @import("spore_net.zig");

pub const max_allow_cidrs = 16;
pub const max_allow_hosts = 16;
pub const max_exact_rules = 32;
pub const max_rule_ports = 16;
pub const max_bound_services = 16;
pub const max_learned_host_ips = 64;
pub const max_bound_service_name_len = 63;
pub const max_unix_socket_path_len = 103;

pub const ParseError = error{
    InvalidCidr,
    InvalidHost,
    InvalidPort,
    InvalidNetworkPolicy,
    InvalidBoundService,
    InvalidBoundServiceName,
    InvalidBoundServiceTarget,
    UnsupportedBoundServiceTarget,
    MissingBoundServiceBinding,
    UnexpectedBoundServiceBinding,
    DuplicateBoundServiceBinding,
    TooManyAllowCidrs,
    TooManyAllowHosts,
    TooManyExactRules,
    TooManyRulePorts,
    TooManyBoundServices,
    DuplicateBoundService,
};

pub const NetworkCapabilities = struct {
    supported: bool,
    tcp_ipv4: bool,
    tcp_ipv6: bool,
    udp_dns: bool,
    exact_host_port: bool,
    stage_policy_update: bool,
    bound_services: bool,
    decision_events: bool,
};

pub fn capabilities() NetworkCapabilities {
    return .{
        .supported = true,
        .tcp_ipv4 = true,
        .tcp_ipv6 = false,
        .udp_dns = true,
        .exact_host_port = true,
        .stage_policy_update = false,
        .bound_services = true,
        .decision_events = true,
    };
}

pub const NetworkDefault = enum { deny };

pub const NetworkRule = struct {
    host: []const u8,
    ports: []const u16,
};

pub const NetworkPolicy = struct {
    default: NetworkDefault = .deny,
    allow: []const NetworkRule = &.{},
};

pub const BoundServiceTarget = union(enum) {
    unix: []const u8,
    tcp: struct { host: []const u8, port: u16 },
};

pub const BoundService = struct {
    name: []const u8,
    guest_host: []const u8,
    guest_port: u16,
    target: BoundServiceTarget,
};

pub const BoundServiceBinding = struct {
    name: []const u8,
    target: BoundServiceTarget,
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

pub const ExactRuleConfig = struct {
    host: []const u8 = "",
    ports: [max_rule_ports]u16 = [_]u16{0} ** max_rule_ports,
    port_count: usize = 0,

    pub fn portSlice(self: *const ExactRuleConfig) []const u16 {
        return self.ports[0..self.port_count];
    }

    fn containsPort(self: *const ExactRuleConfig, port: u16) bool {
        for (self.portSlice()) |allowed| {
            if (allowed == port) return true;
        }
        return false;
    }
};

pub const BoundServiceConfig = struct {
    declaration: []const u8 = "",
    name: []const u8 = "",
    guest_host: []const u8 = "",
    guest_port: u16 = 0,
    unix_path: []const u8 = "",
};

pub const Config = struct {
    default_deny: bool = false,
    allow_cidrs: [max_allow_cidrs][]const u8 = [_][]const u8{""} ** max_allow_cidrs,
    allow_cidr_count: usize = 0,
    allow_hosts: [max_allow_hosts][]const u8 = [_][]const u8{""} ** max_allow_hosts,
    allow_host_count: usize = 0,
    exact_rules: [max_exact_rules]ExactRuleConfig = [_]ExactRuleConfig{.{}} ** max_exact_rules,
    exact_rule_count: usize = 0,
    bound_services: [max_bound_services]BoundServiceConfig = [_]BoundServiceConfig{.{}} ** max_bound_services,
    bound_service_count: usize = 0,

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

    pub fn addBindService(self: *Config, raw: []const u8) ParseError!void {
        const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return error.InvalidBoundService;
        if (std.mem.indexOfScalar(u8, raw[eq + 1 ..], '=') != null) return error.InvalidBoundService;
        const name = raw[0..eq];
        const target = raw[eq + 1 ..];
        try validateBoundServiceName(name);

        const unix_prefix = "unix:";
        if (!std.mem.startsWith(u8, target, unix_prefix)) return error.UnsupportedBoundServiceTarget;
        const path = target[unix_prefix.len..];
        try validateUnixSocketPath(path);

        if (self.bound_service_count >= max_bound_services) return error.TooManyBoundServices;
        self.bound_services[self.bound_service_count] = .{
            .declaration = raw,
            .name = name,
            .guest_port = 80,
            .unix_path = path,
        };
        self.bound_service_count += 1;
    }

    pub fn addNetworkPolicy(self: *Config, policy: NetworkPolicy) ParseError!void {
        if (policy.default != .deny) return error.InvalidNetworkPolicy;
        self.default_deny = true;
        for (policy.allow) |rule| {
            try self.addExactHostPorts(rule.host, rule.ports);
        }
    }

    pub fn addExactHostPorts(self: *Config, host: []const u8, ports: []const u16) ParseError!void {
        try validateHost(host);
        if (ports.len == 0) return error.InvalidPort;
        if (ports.len > max_rule_ports) return error.TooManyRulePorts;
        if (self.exact_rule_count >= max_exact_rules) return error.TooManyExactRules;
        var rule = ExactRuleConfig{ .host = host };
        for (ports) |port| {
            if (port == 0) return error.InvalidPort;
            if (!rule.containsPort(port)) {
                rule.ports[rule.port_count] = port;
                rule.port_count += 1;
            }
        }
        self.exact_rules[self.exact_rule_count] = rule;
        self.exact_rule_count += 1;
    }

    pub fn addBoundService(self: *Config, service: BoundService) ParseError!void {
        switch (service.target) {
            .unix => |path| try self.addBoundUnixService(service.name, service.guest_host, service.guest_port, path),
            .tcp => return error.UnsupportedBoundServiceTarget,
        }
    }

    pub fn addBoundUnixService(self: *Config, name: []const u8, guest_host: []const u8, guest_port: u16, unix_path: []const u8) ParseError!void {
        try validateServiceName(name);
        try validateHost(guest_host);
        if (guest_port == 0) return error.InvalidPort;
        try validateUnixSocketPath(unix_path);
        if (self.bound_service_count >= max_bound_services) return error.TooManyBoundServices;
        for (self.boundServiceSlice()) |existing| {
            if (std.mem.eql(u8, existing.name, name)) return error.DuplicateBoundService;
            if (existing.guest_host.len != 0 and std.mem.eql(u8, existing.guest_host, guest_host)) return error.DuplicateBoundService;
            if (existing.guest_port != 0 and existing.guest_port == guest_port) return error.DuplicateBoundService;
        }
        self.bound_services[self.bound_service_count] = .{
            .name = name,
            .guest_host = guest_host,
            .guest_port = guest_port,
            .unix_path = unix_path,
        };
        self.bound_service_count += 1;
    }

    pub fn hasRules(self: Config) bool {
        return self.default_deny or
            self.allow_cidr_count != 0 or
            self.allow_host_count != 0 or
            self.exact_rule_count != 0 or
            self.bound_service_count != 0;
    }

    pub fn hasBoundServices(self: Config) bool {
        return self.bound_service_count != 0;
    }

    pub fn allowCidrSlice(self: *const Config) []const []const u8 {
        return self.allow_cidrs[0..self.allow_cidr_count];
    }

    pub fn allowHostSlice(self: *const Config) []const []const u8 {
        return self.allow_hosts[0..self.allow_host_count];
    }

    pub fn exactRuleSlice(self: *const Config) []const ExactRuleConfig {
        return self.exact_rules[0..self.exact_rule_count];
    }

    pub fn boundServiceSlice(self: *const Config) []const BoundServiceConfig {
        return self.bound_services[0..self.bound_service_count];
    }
};

pub fn configFromManifestNetwork(allocator: std.mem.Allocator, network: spore.Network) !Config {
    return configFromManifestNetworkWithBindings(allocator, network, &.{});
}

pub fn configFromManifestNetworkWithBindings(
    allocator: std.mem.Allocator,
    network: spore.Network,
    bindings: []const BoundServiceBinding,
) !Config {
    try spore.validateNetwork(network);
    var policy = Config{};
    if (network.default_action) |action| {
        if (!std.mem.eql(u8, action, spore.network_default_deny)) return error.InvalidNetworkPolicy;
        policy.default_deny = true;
    }
    for (network.allow_cidrs) |cidr| {
        try policy.addAllowCidr(try allocator.dupe(u8, cidr));
    }
    for (network.allow_hosts) |host| {
        try policy.addAllowHost(try allocator.dupe(u8, host));
    }
    for (network.allow_host_ports) |rule| {
        const host = try allocator.dupe(u8, rule.host);
        const ports = try allocator.dupe(u16, rule.ports);
        try policy.addExactHostPorts(host, ports);
    }
    try addManifestBoundServices(allocator, &policy, network.bound_services, bindings);
    return policy;
}

fn addManifestBoundServices(
    allocator: std.mem.Allocator,
    policy: *Config,
    requirements: []const spore.NetworkBoundServiceRequirement,
    bindings: []const BoundServiceBinding,
) !void {
    if (bindings.len > max_bound_services) return error.TooManyBoundServices;
    for (bindings, 0..) |binding, index| {
        try validateServiceName(binding.name);
        switch (binding.target) {
            .unix => |path| try validateUnixSocketPath(path),
            .tcp => return error.UnsupportedBoundServiceTarget,
        }
        for (bindings[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, binding.name)) return error.DuplicateBoundServiceBinding;
        }
    }
    if (requirements.len == 0) {
        if (bindings.len != 0) return error.UnexpectedBoundServiceBinding;
        return;
    }
    if (bindings.len == 0) return error.MissingBoundServiceBinding;

    var matched = [_]bool{false} ** max_bound_services;
    for (requirements) |requirement| {
        const binding_index = findBoundServiceBinding(bindings, requirement.name) orelse return error.MissingBoundServiceBinding;
        matched[binding_index] = true;
        const binding = bindings[binding_index];
        const unix_path = switch (binding.target) {
            .unix => |path| path,
            .tcp => unreachable,
        };
        try policy.addBoundUnixService(
            try allocator.dupe(u8, requirement.name),
            try allocator.dupe(u8, requirement.guest_host),
            requirement.guest_port,
            try allocator.dupe(u8, unix_path),
        );
    }
    for (bindings, 0..) |_, index| {
        if (!matched[index]) return error.UnexpectedBoundServiceBinding;
    }
}

fn findBoundServiceBinding(bindings: []const BoundServiceBinding, name: []const u8) ?usize {
    for (bindings, 0..) |binding, index| {
        if (std.mem.eql(u8, binding.name, name)) return index;
    }
    return null;
}

pub fn manifestNetworkFromConfig(allocator: std.mem.Allocator, policy: *const Config) !spore.Network {
    const exact_rules = try allocator.alloc(spore.NetworkHostPortRule, policy.exact_rule_count);
    for (policy.exactRuleSlice(), exact_rules) |*rule, *out| {
        out.* = .{
            .host = rule.host,
            .ports = rule.portSlice(),
        };
    }
    const bound_services = try allocator.alloc(spore.NetworkBoundServiceRequirement, policy.bound_service_count);
    for (policy.boundServiceSlice(), bound_services) |service, *out| {
        out.* = .{
            .name = service.name,
            .guest_host = service.guest_host,
            .guest_port = service.guest_port,
        };
    }
    return .{
        .default_action = if (policy.default_deny) spore.network_default_deny else null,
        .allow_cidrs = policy.allowCidrSlice(),
        .allow_hosts = policy.allowHostSlice(),
        .allow_host_ports = exact_rules,
        .bound_services = bound_services,
        .requirements = .{
            .exact_host_port = policy.default_deny or policy.exact_rule_count != 0,
            .bound_services = policy.bound_service_count != 0,
        },
    };
}

const LearnedHostIp = struct {
    host_index: usize,
    addr: [4]u8,
};

const LearnedExactHostIp = struct {
    rule_index: usize,
    addr: [4]u8,
};

pub const Runtime = struct {
    default_deny: bool = false,
    allow_cidrs: [max_allow_cidrs]Cidr = undefined,
    allow_cidr_count: usize = 0,
    allow_hosts: [max_allow_hosts][]const u8 = [_][]const u8{""} ** max_allow_hosts,
    allow_host_count: usize = 0,
    exact_rules: [max_exact_rules]ExactRuleConfig = [_]ExactRuleConfig{.{}} ** max_exact_rules,
    exact_rule_count: usize = 0,
    bound_services: [max_bound_services]BoundServiceConfig = [_]BoundServiceConfig{.{}} ** max_bound_services,
    bound_service_count: usize = 0,
    learned_host_ips: [max_learned_host_ips]LearnedHostIp = undefined,
    learned_host_ip_count: usize = 0,
    learned_exact_host_ips: [max_learned_host_ips]LearnedExactHostIp = undefined,
    learned_exact_host_ip_count: usize = 0,

    pub fn init(config: Config) ParseError!Runtime {
        var runtime = Runtime{};
        runtime.default_deny = config.default_deny;
        for (config.allowCidrSlice()) |raw| {
            runtime.allow_cidrs[runtime.allow_cidr_count] = try parseCidr(raw);
            runtime.allow_cidr_count += 1;
        }
        for (config.allowHostSlice()) |raw| {
            try validateHost(raw);
            runtime.allow_hosts[runtime.allow_host_count] = raw;
            runtime.allow_host_count += 1;
        }
        for (config.exactRuleSlice()) |rule| {
            try validateHost(rule.host);
            runtime.exact_rules[runtime.exact_rule_count] = rule;
            runtime.exact_rule_count += 1;
        }
        for (config.boundServiceSlice()) |service| {
            try validateServiceName(service.name);
            if (service.guest_host.len != 0) try validateHost(service.guest_host);
            runtime.bound_services[runtime.bound_service_count] = service;
            runtime.bound_service_count += 1;
        }
        return runtime;
    }

    pub fn decideIpv4(self: *const Runtime, addr: [4]u8) Decision {
        return self.decideIpv4Port(addr, 0);
    }

    pub fn decideIpv4Port(self: *const Runtime, addr: [4]u8, port: u16) Decision {
        if (isHardFloorBlocked(addr)) return .deny_hard_floor;
        for (self.allow_cidrs[0..self.allow_cidr_count]) |cidr| {
            if (cidr.contains(addr)) return .allow;
        }
        for (self.learned_host_ips[0..self.learned_host_ip_count]) |learned| {
            if (std.mem.eql(u8, &learned.addr, &addr)) return .allow;
        }
        if (port != 0) {
            for (self.learned_exact_host_ips[0..self.learned_exact_host_ip_count]) |learned| {
                if (!std.mem.eql(u8, &learned.addr, &addr)) continue;
                if (self.exact_rules[learned.rule_index].containsPort(port)) return .allow;
            }
        }
        if (!self.default_deny and !self.hasAllowRules()) return .allow;
        return .deny_not_allowed;
    }

    pub fn noteDnsResponse(self: *Runtime, query: []const u8, response: []const u8) usize {
        if (self.allow_host_count == 0 and self.exact_rule_count == 0) return 0;
        if (query.len < dns_header_len or response.len < dns_header_len) return 0;
        if (!std.mem.eql(u8, query[0..2], response[0..2])) return 0;
        const flags = std.mem.readInt(u16, response[2..4], .big);
        if ((flags & 0x8000) == 0) return 0;
        if (std.mem.readInt(u16, query[4..6], .big) != 1) return 0;
        if (std.mem.readInt(u16, response[4..6], .big) != 1) return 0;

        const query_name_end = spore_net.skipDnsName(query, dns_header_len) orelse return 0;
        if (query_name_end + 4 > query.len) return 0;
        const qtype = std.mem.readInt(u16, query[query_name_end..][0..2], .big);
        const qclass = std.mem.readInt(u16, query[query_name_end + 2 ..][0..2], .big);
        if (qtype != dns_type_a or qclass != dns_class_in) return 0;

        const legacy_host_index = self.allowedHostIndexForDnsName(query, dns_header_len);
        var exact_matches: [max_exact_rules]usize = undefined;
        const exact_match_count = self.exactRuleIndicesForDnsName(query, dns_header_len, &exact_matches);
        if (legacy_host_index == null and exact_match_count == 0) return 0;

        var offset = spore_net.skipDnsName(response, dns_header_len) orelse return 0;
        if (offset + 4 > response.len) return 0;
        offset += 4;

        var learned: usize = 0;
        const answer_count = std.mem.readInt(u16, response[6..8], .big);
        var i: usize = 0;
        while (i < answer_count) : (i += 1) {
            const name_start = offset;
            const name_end = spore_net.skipDnsName(response, offset) orelse return learned;
            if (name_end + 10 > response.len) return learned;
            const answer_type = std.mem.readInt(u16, response[name_end..][0..2], .big);
            const answer_class = std.mem.readInt(u16, response[name_end + 2 ..][0..2], .big);
            const data_len = std.mem.readInt(u16, response[name_end + 8 ..][0..2], .big);
            const data_start = name_end + 10;
            const data_end = data_start + @as(usize, data_len);
            if (data_end > response.len) return learned;

            if (answer_type == dns_type_a and answer_class == dns_class_in and data_len == 4) {
                var addr: [4]u8 = undefined;
                @memcpy(&addr, response[data_start..data_end]);
                if (legacy_host_index) |host_index| {
                    const host = self.allow_hosts[host_index];
                    if (dnsNameMatchesHost(response, name_start, host) and self.recordLearnedHostIp(host_index, addr)) learned += 1;
                }
                for (exact_matches[0..exact_match_count]) |rule_index| {
                    const host = self.exact_rules[rule_index].host;
                    if (dnsNameMatchesHost(response, name_start, host) and self.recordLearnedExactHostIp(rule_index, addr)) learned += 1;
                }
            }
            offset = data_end;
        }
        return learned;
    }

    pub fn boundServiceForDnsQuery(self: *const Runtime, packet: []const u8, name_offset: usize) ?*const BoundServiceConfig {
        for (self.bound_services[0..self.bound_service_count]) |*service| {
            if (dnsNameMatchesHost(packet, name_offset, service.guest_host)) return service;
        }
        return null;
    }

    pub fn boundServiceForPort(self: *const Runtime, port: u16) ?*const BoundServiceConfig {
        for (self.bound_services[0..self.bound_service_count]) |*service| {
            if (service.guest_port == port) return service;
        }
        return null;
    }

    pub fn hostForIpv4Port(self: *const Runtime, addr: [4]u8, port: u16) ?[]const u8 {
        for (self.learned_exact_host_ips[0..self.learned_exact_host_ip_count]) |learned| {
            if (!std.mem.eql(u8, &learned.addr, &addr)) continue;
            const rule = self.exact_rules[learned.rule_index];
            if (rule.containsPort(port)) return rule.host;
        }
        for (self.learned_host_ips[0..self.learned_host_ip_count]) |learned| {
            if (std.mem.eql(u8, &learned.addr, &addr)) return self.allow_hosts[learned.host_index];
        }
        return null;
    }

    fn hasAllowRules(self: *const Runtime) bool {
        return self.allow_cidr_count != 0 or self.allow_host_count != 0 or self.exact_rule_count != 0;
    }

    fn allowedHostIndexForDnsName(self: *const Runtime, packet: []const u8, offset: usize) ?usize {
        for (self.allow_hosts[0..self.allow_host_count], 0..) |host, i| {
            if (dnsNameMatchesHost(packet, offset, host)) return i;
        }
        return null;
    }

    fn exactRuleIndicesForDnsName(self: *const Runtime, packet: []const u8, offset: usize, out: *[max_exact_rules]usize) usize {
        var count: usize = 0;
        for (self.exact_rules[0..self.exact_rule_count], 0..) |rule, i| {
            if (!dnsNameMatchesHost(packet, offset, rule.host)) continue;
            out[count] = i;
            count += 1;
        }
        return count;
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

    fn recordLearnedExactHostIp(self: *Runtime, rule_index: usize, addr: [4]u8) bool {
        for (self.learned_exact_host_ips[0..self.learned_exact_host_ip_count]) |learned| {
            if (learned.rule_index == rule_index and std.mem.eql(u8, &learned.addr, &addr)) return false;
        }
        if (self.learned_exact_host_ip_count >= max_learned_host_ips) return false;
        self.learned_exact_host_ips[self.learned_exact_host_ip_count] = .{ .rule_index = rule_index, .addr = addr };
        self.learned_exact_host_ip_count += 1;
        return true;
    }
};

const dns_header_len = 12;
const dns_type_a = 1;
const dns_class_in = 1;

pub fn parseCidr(raw: []const u8) ParseError!Cidr {
    const slash = std.mem.indexOfScalar(u8, raw, '/') orelse return error.InvalidCidr;
    if (std.mem.indexOfScalar(u8, raw[slash + 1 ..], '/') != null) return error.InvalidCidr;
    const addr = spore_net.parseIpv4(raw[0..slash]) orelse return error.InvalidCidr;
    const prefix = std.fmt.parseUnsigned(u8, raw[slash + 1 ..], 10) catch return error.InvalidCidr;
    if (prefix > 32) return error.InvalidCidr;
    return .{ .network = addr, .prefix_len = prefix };
}

pub const HostPort = struct {
    host: []const u8,
    port: u16,
};

pub fn parseHostPort(raw: []const u8) ParseError!HostPort {
    const colon = std.mem.lastIndexOfScalar(u8, raw, ':') orelse return error.InvalidPort;
    const host = raw[0..colon];
    const port_raw = raw[colon + 1 ..];
    const port = std.fmt.parseUnsigned(u16, port_raw, 10) catch return error.InvalidPort;
    if (port == 0) return error.InvalidPort;
    try validateHost(host);
    return .{ .host = host, .port = port };
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

pub fn validateBoundServiceName(raw: []const u8) ParseError!void {
    if (raw.len == 0 or raw.len > max_bound_service_name_len) return error.InvalidBoundServiceName;
    if (raw[0] == '-' or raw[raw.len - 1] == '-') return error.InvalidBoundServiceName;
    for (raw) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-') continue;
        return error.InvalidBoundServiceName;
    }
}

fn validateUnixSocketPath(raw: []const u8) ParseError!void {
    if (raw.len == 0 or raw[0] != '/') return error.InvalidBoundServiceTarget;
    if (raw.len > max_unix_socket_path_len) return error.InvalidBoundServiceTarget;
    if (std.mem.indexOfScalar(u8, raw, 0) != null) return error.InvalidBoundServiceTarget;
}

pub fn validateServiceName(raw: []const u8) ParseError!void {
    validateBoundServiceName(raw) catch return error.InvalidBoundService;
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
        if (!std.ascii.eqlIgnoreCase(packet[offset..][0..len], host[host_i..][0..len])) return false;
        host_i += len;
        offset += len;
    }
}

pub fn testDnsQuery(id: u16, qname: []const u8, out: *[512]u8) []const u8 {
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

pub fn testDnsResponse(query: []const u8, answer_owner: []const u8, answers: []const [4]u8, out: *[512]u8) []const u8 {
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
    const response = testDnsResponse(query, "*", &.{ .{ 169, 254, 169, 254 }, .{ 93, 184, 216, 34 } }, &response_buf);
    try std.testing.expectEqual(@as(usize, 2), policy.noteDnsResponse(query, response));
    try std.testing.expectEqual(Decision.deny_hard_floor, policy.decideIpv4(.{ 169, 254, 169, 254 }));
    try std.testing.expectEqual(Decision.allow, policy.decideIpv4(.{ 93, 184, 216, 34 }));
}

test "spore-net policy parses bound unix service declarations" {
    var config = Config{};
    try config.addBindService("metadata=unix:/tmp/metadata.sock");

    try std.testing.expect(config.hasBoundServices());
    try std.testing.expectEqual(@as(usize, 1), config.bound_service_count);
    try std.testing.expectEqualStrings("metadata=unix:/tmp/metadata.sock", config.bound_services[0].declaration);
    try std.testing.expectEqualStrings("metadata", config.bound_services[0].name);
    try std.testing.expectEqual(@as(u16, 80), config.bound_services[0].guest_port);
    try std.testing.expectEqualStrings("/tmp/metadata.sock", config.bound_services[0].unix_path);
}

test "spore-net policy rejects invalid bound service declarations" {
    var config = Config{};
    try std.testing.expectError(error.InvalidBoundService, config.addBindService("metadata"));
    try std.testing.expectError(error.InvalidBoundServiceName, config.addBindService("MetaData=unix:/tmp/metadata.sock"));
    try std.testing.expectError(error.UnsupportedBoundServiceTarget, config.addBindService("metadata=tcp:127.0.0.1:8080"));
    try std.testing.expectError(error.InvalidBoundServiceTarget, config.addBindService("metadata=unix:relative.sock"));
}

test "spore-net policy exposes first-slice capability facts" {
    const facts = capabilities();
    try std.testing.expect(facts.supported);
    try std.testing.expect(facts.tcp_ipv4);
    try std.testing.expect(facts.udp_dns);
    try std.testing.expect(facts.exact_host_port);
    try std.testing.expect(facts.bound_services);
    try std.testing.expect(!facts.tcp_ipv6);
    try std.testing.expect(!facts.stage_policy_update);
}

test "spore-net policy parses host port values" {
    const parsed = try parseHostPort("github.com:443");
    try std.testing.expectEqualStrings("github.com", parsed.host);
    try std.testing.expectEqual(@as(u16, 443), parsed.port);
    try std.testing.expectError(error.InvalidPort, parseHostPort("github.com"));
    try std.testing.expectError(error.InvalidPort, parseHostPort("github.com:0"));
    try std.testing.expectError(error.InvalidHost, parseHostPort("-github.com:443"));
}

test "spore-net exact policy learns A records and enforces host plus port" {
    var config = Config{};
    try config.addNetworkPolicy(.{
        .allow = &.{.{
            .host = "github.com",
            .ports = &.{443},
        }},
    });
    var policy = try Runtime.init(config);

    try std.testing.expectEqual(Decision.deny_not_allowed, policy.decideIpv4Port(.{ 140, 82, 112, 4 }, 443));

    var query_buf: [512]u8 = undefined;
    const query = testDnsQuery(0x1234, "github.com", &query_buf);
    var response_buf: [512]u8 = undefined;
    const response = testDnsResponse(query, "*", &.{.{ 140, 82, 112, 4 }}, &response_buf);
    try std.testing.expectEqual(@as(usize, 1), policy.noteDnsResponse(query, response));
    try std.testing.expectEqual(Decision.allow, policy.decideIpv4Port(.{ 140, 82, 112, 4 }, 443));
    try std.testing.expectEqual(Decision.deny_not_allowed, policy.decideIpv4Port(.{ 140, 82, 112, 4 }, 80));
    try std.testing.expectEqual(Decision.deny_not_allowed, policy.decideIpv4Port(.{ 140, 82, 112, 5 }, 443));
    try std.testing.expectEqualStrings("github.com", policy.hostForIpv4Port(.{ 140, 82, 112, 4 }, 443).?);
    try std.testing.expect(policy.hostForIpv4Port(.{ 140, 82, 112, 4 }, 80) == null);
}

test "spore-net exact policy ignores different DNS answer owner" {
    var config = Config{};
    try config.addExactHostPorts("github.com", &.{443});
    var policy = try Runtime.init(config);

    var query_buf: [512]u8 = undefined;
    const query = testDnsQuery(0x1234, "github.com", &query_buf);
    var response_buf: [512]u8 = undefined;
    const response = testDnsResponse(query, "other.example", &.{.{ 140, 82, 112, 4 }}, &response_buf);
    try std.testing.expectEqual(@as(usize, 0), policy.noteDnsResponse(query, response));
    try std.testing.expectEqual(Decision.deny_not_allowed, policy.decideIpv4Port(.{ 140, 82, 112, 4 }, 443));
}

test "spore-net exact default deny with no allow rules blocks public egress" {
    var config = Config{};
    try config.addNetworkPolicy(.{});
    const policy = try Runtime.init(config);
    try std.testing.expectEqual(Decision.deny_not_allowed, policy.decideIpv4Port(.{ 93, 184, 216, 34 }, 443));
}

test "spore-net bound Unix services validate and lookup by DNS name and guest port" {
    var config = Config{};
    try config.addBoundService(.{
        .name = "cleanroom-gateway",
        .guest_host = "gateway.cleanroom.internal",
        .guest_port = 8170,
        .target = .{ .unix = "/tmp/cleanroom-gateway.sock" },
    });
    const policy = try Runtime.init(config);

    var query_buf: [512]u8 = undefined;
    const query = testDnsQuery(0x1234, "gateway.cleanroom.internal", &query_buf);
    const by_dns = policy.boundServiceForDnsQuery(query, dns_header_len) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("cleanroom-gateway", by_dns.name);
    const by_port = policy.boundServiceForPort(8170) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/tmp/cleanroom-gateway.sock", by_port.unix_path);
    try std.testing.expect(policy.boundServiceForPort(8171) == null);
}
