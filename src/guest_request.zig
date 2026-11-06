//! Builds what the host sends the guest agent: parses `--env` specs, merges
//! and validates the guest env and working dir, encodes start requests (argv,
//! env and stdio) and simple control requests, and parses the guest's
//! rootfs-grow response.

const std = @import("std");

const run_contract = @import("build/run_contract.zig");
const spore_stream = @import("spore_stream.zig");

pub const max_guest_argc = run_contract.max_exec_args;
pub const max_guest_request_len = 8191;
pub const max_guest_arg_len = max_guest_request_len;
pub const max_guest_envc = 64;
pub const max_guest_env_len = 255;
pub const max_guest_working_dir_len = 255;

pub const GuestEnvSpec = union(enum) {
    literal: []const u8,
    copy: []const u8,
};

pub const GuestEnvSpecList = struct {
    items: [max_guest_envc]GuestEnvSpec = undefined,
    len: usize = 0,

    pub fn append(self: *GuestEnvSpecList, spec: GuestEnvSpec) !void {
        if (self.len >= max_guest_envc) return error.TooManyRunEnv;
        self.items[self.len] = spec;
        self.len += 1;
    }

    pub fn slice(self: *const GuestEnvSpecList) []const GuestEnvSpec {
        return self.items[0..self.len];
    }
};

pub fn parseGuestEnvSpec(raw: []const u8) !GuestEnvSpec {
    if (std.mem.indexOfScalar(u8, raw, '=')) |eq| {
        const key = raw[0..eq];
        try validateGuestEnvKey(key);
        return .{ .literal = raw };
    }
    try validateGuestEnvKey(raw);
    return .{ .copy = raw };
}

pub const GuestEnvResolveDiagnostic = struct {
    missing_key: ?[]const u8 = null,
};

pub fn resolveCliGuestEnv(
    allocator: std.mem.Allocator,
    specs: []const GuestEnvSpec,
    environ: *const std.process.Environ.Map,
    diagnostic: ?*GuestEnvResolveDiagnostic,
) ![]const []const u8 {
    if (diagnostic) |diag| diag.* = .{};
    var out = std.array_list.Managed([]const u8).init(allocator);
    for (specs) |spec| {
        const entry = switch (spec) {
            .literal => |entry| entry,
            .copy => |key| blk: {
                const value = environ.get(key) orelse {
                    if (diagnostic) |diag| diag.missing_key = key;
                    return error.MissingHostEnvironment;
                };
                break :blk try std.fmt.allocPrint(allocator, "{s}={s}", .{ key, value });
            },
        };
        if (entry.len > max_guest_env_len) return error.RunEnvTooLong;
        try upsertGuestEnvEntry(&out, entry);
    }
    return out.toOwnedSlice();
}

pub fn mergeGuestEnv(allocator: std.mem.Allocator, base: []const []const u8, overrides: []const []const u8) ![]const []const u8 {
    if (base.len == 0) return overrides;
    if (overrides.len == 0) return base;
    var out = std.array_list.Managed([]const u8).init(allocator);
    for (base) |entry| {
        if (!guestEnvHasKey(overrides, inheritedGuestEnvEntryKey(entry))) try out.append(entry);
    }
    for (overrides) |entry| try out.append(entry);
    if (out.items.len > max_guest_envc) return error.RunEnvCountUnsupported;
    return out.toOwnedSlice();
}

pub fn mergeGuestEnvInto(out: [][]const u8, base: []const []const u8, overrides: []const []const u8) ![]const []const u8 {
    var len: usize = 0;
    for (base) |entry| {
        if (!guestEnvHasKey(overrides, inheritedGuestEnvEntryKey(entry))) {
            if (len >= out.len or len >= max_guest_envc) return error.RunEnvCountUnsupported;
            out[len] = entry;
            len += 1;
        }
    }
    for (overrides) |entry| {
        if (len >= out.len or len >= max_guest_envc) return error.RunEnvCountUnsupported;
        out[len] = entry;
        len += 1;
    }
    return out[0..len];
}

fn upsertGuestEnvEntry(entries: *std.array_list.Managed([]const u8), entry: []const u8) !void {
    const key = guestEnvEntryKey(entry) orelse return error.BadGuestEnvKey;
    for (entries.items, 0..) |existing, i| {
        if (guestEnvKeyEql(guestEnvEntryKey(existing), key)) {
            entries.items[i] = entry;
            return;
        }
    }
    if (entries.items.len >= max_guest_envc) return error.RunEnvCountUnsupported;
    try entries.append(entry);
}

fn guestEnvHasKey(entries: []const []const u8, key: ?[]const u8) bool {
    for (entries) |entry| {
        if (guestEnvKeyEql(guestEnvEntryKey(entry), key)) return true;
    }
    return false;
}

fn guestEnvKeyEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn guestEnvEntryKey(entry: []const u8) ?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return null;
    if (eq == 0) return null;
    return entry[0..eq];
}

fn inheritedGuestEnvEntryKey(entry: []const u8) ?[]const u8 {
    return guestEnvEntryKey(entry) orelse if (entry.len != 0) entry else null;
}

fn validateGuestEnvKey(key: []const u8) !void {
    if (key.len == 0) return error.BadGuestEnvKey;
    for (key, 0..) |c, i| {
        if (std.ascii.isAlphabetic(c) or c == '_' or (i != 0 and std.ascii.isDigit(c))) continue;
        return error.BadGuestEnvKey;
    }
}

pub fn simpleControlRequest(allocator: std.mem.Allocator, request_type: []const u8, session_id: []const u8) ![]const u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .type = request_type,
        .session_id = session_id,
    }, .{});
    defer allocator.free(json);
    if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

pub fn execRequest(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    return execRequestWithSession(allocator, argv, "default", 0);
}

pub fn execRequestWithSession(allocator: std.mem.Allocator, argv: []const []const u8, session_id: []const u8, resume_time_unix_ns: u64) ![]const u8 {
    return execRequestWithSessionOptions(allocator, argv, session_id, .{
        .resume_time_unix_ns = resume_time_unix_ns,
    });
}

pub const ExecRequestContextOptions = struct {
    env: []const []const u8 = &.{},
    working_dir: ?[]const u8 = null,
    resume_time_unix_ns: u64 = 0,
    retain_output: bool = false,
};

pub const InteractiveExecRequestOptions = struct {
    env: []const []const u8 = &.{},
    working_dir: ?[]const u8 = null,
    tty: bool = false,
    terminal_size: spore_stream.Resize = .{ .rows = 24, .cols = 80 },
    resume_time_unix_ns: u64 = 0,
    generation_params: ?[]const u8 = null,
};

/// Encodes a streamed exec. Stdin is always a pipe (or the terminal): the
/// caller forwards input and closes the stream when it has none.
pub fn interactiveExecRequestWithSession(allocator: std.mem.Allocator, argv: []const []const u8, session_id: []const u8, options: InteractiveExecRequestOptions) ![]const u8 {
    return execRequestWithSessionOptions(allocator, argv, session_id, .{
        .env = options.env,
        .working_dir = options.working_dir,
        .stdio = if (options.tty) .tty else .pipe,
        .terminal_size = options.terminal_size,
        .resume_time_unix_ns = options.resume_time_unix_ns,
        .generation_params = options.generation_params,
    });
}

pub fn detachedExecRequestWithSessionContext(allocator: std.mem.Allocator, argv: []const []const u8, session_id: []const u8, options: ExecRequestContextOptions) ![]const u8 {
    return execRequestWithSessionOptions(allocator, argv, session_id, .{
        .env = options.env,
        .working_dir = options.working_dir,
        .resume_time_unix_ns = options.resume_time_unix_ns,
        .detached = true,
        .retain_output = options.retain_output,
    });
}

/// The guest command's stdio: `null` gives it /dev/null stdin and piped
/// output, `pipe` also pipes stdin, and `tty` gives it a terminal.
pub const GuestStdio = enum { null, pipe, tty };

const GuestExecOptions = struct {
    env: []const []const u8 = &.{},
    working_dir: ?[]const u8 = null,
    resume_time_unix_ns: u64 = 0,
    memory_pressure: bool = false,
    stdio: GuestStdio = .null,
    terminal_size: spore_stream.Resize = .{ .rows = 24, .cols = 80 },
    generation_params: ?[]const u8 = null,
    require_generation_ready: bool = false,
    detached: bool = false,
    retain_output: bool = false,
};

/// Encodes the guest agent's `start-v1` request. Every member is always
/// present; detached commands require `null` stdio.
pub fn execRequestWithSessionOptions(allocator: std.mem.Allocator, argv: []const []const u8, session_id: []const u8, options: GuestExecOptions) ![]const u8 {
    try validateGuestArgv(argv);
    try validateGuestExecOptions(options);
    const payload = struct {
        type: []const u8 = "start-v1",
        session_id: []const u8,
        resume_time_unix_ns: u64,
        argv: []const []const u8,
        env: []const []const u8,
        working_dir: []const u8,
        stdio: []const u8,
        terminal_rows: u16,
        terminal_cols: u16,
        memory_pressure: bool,
        params_json: []const u8,
        require_generation_ready: bool,
        detached: bool,
        retain_output: bool,
        closed_env: bool = true,
    }{
        .session_id = session_id,
        .resume_time_unix_ns = options.resume_time_unix_ns,
        .argv = argv,
        .env = options.env,
        .working_dir = options.working_dir orelse "",
        .stdio = @tagName(options.stdio),
        .terminal_rows = options.terminal_size.rows,
        .terminal_cols = options.terminal_size.cols,
        .memory_pressure = options.memory_pressure,
        .params_json = options.generation_params orelse "",
        .require_generation_ready = options.require_generation_ready,
        .detached = options.detached,
        .retain_output = options.retain_output,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

pub fn validateGuestArgv(argv: []const []const u8) !void {
    if (argv.len == 0 or argv.len > max_guest_argc) return error.RunArgCountUnsupported;
    if (argv[0].len == 0) return error.RunProgramEmpty;
    for (argv) |arg| {
        if (arg.len > max_guest_arg_len) return error.RunArgTooLong;
    }
}

fn validateGuestExecOptions(options: GuestExecOptions) !void {
    try validateGuestExecContext(options.env, options.working_dir);
}

pub fn validateGuestExecContext(env: []const []const u8, working_dir: ?[]const u8) !void {
    if (env.len > max_guest_envc) return error.RunEnvCountUnsupported;
    for (env) |entry| {
        if (entry.len > max_guest_env_len) return error.RunEnvTooLong;
    }
    if (working_dir) |dir| {
        if (dir.len == 0 or dir.len > max_guest_working_dir_len or !std.fs.path.isAbsolute(dir)) return error.RunWorkingDirUnsupported;
    }
}

pub const max_rootfs_grow_response: usize = 1024;

pub const RootfsGrowResult = struct {
    device_bytes: u64,
    block_size: u64,
    target_blocks: u64,
    before_blocks: u64,
    filesystem_blocks: u64,
    blocks_per_group: u32,
    usable_blocks: u64,
    free_bytes: u64,
    inodes: u64,
    free_inodes: u64,
};

pub fn parseRootfsGrowResponse(bytes: []const u8) !RootfsGrowResult {
    if (bytes.len == 0 or bytes.len > max_rootfs_grow_response) return error.BadRootfsGrowResponse;
    if (!std.mem.endsWith(u8, bytes, "\n") or std.mem.count(u8, bytes, "\n") != 1) return error.BadRootfsGrowResponse;
    const line = bytes[0 .. bytes.len - 1];
    if (std.mem.indexOfScalar(u8, line, '\r') != null) return error.BadRootfsGrowResponse;

    var tokens = std.mem.splitScalar(u8, line, ' ');
    if (!std.mem.eql(u8, tokens.next() orelse return error.BadRootfsGrowResponse, "spore-rootfs-grow-v1")) return error.BadRootfsGrowResponse;
    const device_bytes = try parseRootfsGrowField(tokens.next(), "device_bytes");
    const block_size = try parseRootfsGrowField(tokens.next(), "block_size");
    const target_blocks = try parseRootfsGrowField(tokens.next(), "target_blocks");
    const before_blocks = try parseRootfsGrowField(tokens.next(), "before_blocks");
    const filesystem_blocks = try parseRootfsGrowField(tokens.next(), "filesystem_blocks");
    const blocks_per_group_raw = try parseRootfsGrowField(tokens.next(), "blocks_per_group");
    const usable_blocks = try parseRootfsGrowField(tokens.next(), "usable_blocks");
    const free_bytes = try parseRootfsGrowField(tokens.next(), "free_bytes");
    const inodes = try parseRootfsGrowField(tokens.next(), "inodes");
    const free_inodes = try parseRootfsGrowField(tokens.next(), "free_inodes");
    if (tokens.next() != null) return error.BadRootfsGrowResponse;

    if (device_bytes == 0 or block_size == 0 or device_bytes % block_size != 0) return error.BadRootfsGrowResponse;
    if (target_blocks != device_bytes / block_size) return error.BadRootfsGrowResponse;
    const blocks_per_group = std.math.cast(u32, blocks_per_group_raw) orelse return error.BadRootfsGrowResponse;
    if (before_blocks == 0 or before_blocks >= filesystem_blocks or filesystem_blocks > target_blocks or blocks_per_group == 0) return error.BadRootfsGrowResponse;
    if (target_blocks - filesystem_blocks >= blocks_per_group) return error.BadRootfsGrowResponse;
    if (usable_blocks == 0 or usable_blocks > filesystem_blocks or inodes == 0) return error.BadRootfsGrowResponse;
    const usable_bytes = std.math.mul(u64, usable_blocks, block_size) catch return error.BadRootfsGrowResponse;
    if (free_bytes > usable_bytes or free_bytes % block_size != 0 or free_inodes > inodes) return error.BadRootfsGrowResponse;
    return .{
        .device_bytes = device_bytes,
        .block_size = block_size,
        .target_blocks = target_blocks,
        .before_blocks = before_blocks,
        .filesystem_blocks = filesystem_blocks,
        .blocks_per_group = blocks_per_group,
        .usable_blocks = usable_blocks,
        .free_bytes = free_bytes,
        .inodes = inodes,
        .free_inodes = free_inodes,
    };
}

fn parseRootfsGrowField(maybe_token: ?[]const u8, expected_name: []const u8) !u64 {
    const token = maybe_token orelse return error.BadRootfsGrowResponse;
    if (token.len <= expected_name.len + 1 or !std.mem.startsWith(u8, token, expected_name) or token[expected_name.len] != '=') {
        return error.BadRootfsGrowResponse;
    }
    return std.fmt.parseUnsigned(u64, token[expected_name.len + 1 ..], 10) catch error.BadRootfsGrowResponse;
}

test "run request encodes argv" {
    const request = try execRequest(std.testing.allocator, &.{ "/bin/echo", "hello world" });
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings("{\"type\":\"start-v1\",\"session_id\":\"default\",\"resume_time_unix_ns\":0,\"argv\":[\"/bin/echo\",\"hello world\"],\"env\":[],\"working_dir\":\"\",\"stdio\":\"null\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"params_json\":\"\",\"require_generation_ready\":false,\"detached\":false,\"retain_output\":false,\"closed_env\":true}\n", request);
}

test "run request can encode explicit session id" {
    const request = try execRequestWithSession(std.testing.allocator, &.{"/bin/true"}, "lifecycle-42", 1_700_000_000_000_000_000);
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings("{\"type\":\"start-v1\",\"session_id\":\"lifecycle-42\",\"resume_time_unix_ns\":1700000000000000000,\"argv\":[\"/bin/true\"],\"env\":[],\"working_dir\":\"\",\"stdio\":\"null\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"params_json\":\"\",\"require_generation_ready\":false,\"detached\":false,\"retain_output\":false,\"closed_env\":true}\n", request);
}

test "run detached exec request asks guest to start without waiting" {
    const request = try detachedExecRequestWithSessionContext(std.testing.allocator, &.{"/bin/true"}, "lifecycle-1", .{
        .env = &.{"SPORE_CONTEXT=detached"},
        .working_dir = "/work",
        .resume_time_unix_ns = 1_700_000_000_000_000_000,
        .retain_output = true,
    });
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings("{\"type\":\"start-v1\",\"session_id\":\"lifecycle-1\",\"resume_time_unix_ns\":1700000000000000000,\"argv\":[\"/bin/true\"],\"env\":[\"SPORE_CONTEXT=detached\"],\"working_dir\":\"/work\",\"stdio\":\"null\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":false,\"params_json\":\"\",\"require_generation_ready\":false,\"detached\":true,\"retain_output\":true,\"closed_env\":true}\n", request);
}

test "run request encodes image env and working directory" {
    const request = try execRequestWithSessionOptions(std.testing.allocator, &.{ "/bin/sh", "-lc", "env && pwd" }, "default", .{
        .env = &.{ "GEM_HOME=/usr/local/bundle", "RUBYOPT=--yjit" },
        .working_dir = "/app",
        .resume_time_unix_ns = 123,
        .memory_pressure = true,
        .generation_params = "{\"resume_entropy_seed\":\"abcd\"}",
        .require_generation_ready = true,
    });
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings("{\"type\":\"start-v1\",\"session_id\":\"default\",\"resume_time_unix_ns\":123,\"argv\":[\"/bin/sh\",\"-lc\",\"env && pwd\"],\"env\":[\"GEM_HOME=/usr/local/bundle\",\"RUBYOPT=--yjit\"],\"working_dir\":\"/app\",\"stdio\":\"null\",\"terminal_rows\":24,\"terminal_cols\":80,\"memory_pressure\":true,\"params_json\":\"{\\\"resume_entropy_seed\\\":\\\"abcd\\\"}\",\"require_generation_ready\":true,\"detached\":false,\"retain_output\":false,\"closed_env\":true}\n", request);
}

test "cli env specs resolve host copies and last override wins" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("SPORE_TEST_ENV", "from-host");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const literal = try parseGuestEnvSpec("SPORE_TEST_ENV=literal=with-equals");
    const copy = try parseGuestEnvSpec("SPORE_TEST_ENV");
    const resolved = try resolveCliGuestEnv(arena, &.{ literal, copy }, &env, null);

    try std.testing.expectEqual(@as(usize, 1), resolved.len);
    try std.testing.expectEqualStrings("SPORE_TEST_ENV=from-host", resolved[0]);
}

test "cli env specs reject empty keys and missing host values" {
    try std.testing.expectError(error.BadGuestEnvKey, parseGuestEnvSpec("=bad"));
    try std.testing.expectError(error.BadGuestEnvKey, parseGuestEnvSpec("1BAD=value"));
    try std.testing.expectError(error.BadGuestEnvKey, parseGuestEnvSpec("BAD-KEY=value"));

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var diagnostic = GuestEnvResolveDiagnostic{};
    const spec = try parseGuestEnvSpec("MISSING_ENV");
    try std.testing.expectError(error.MissingHostEnvironment, resolveCliGuestEnv(std.testing.allocator, &.{spec}, &env, &diagnostic));
    try std.testing.expectEqualStrings("MISSING_ENV", diagnostic.missing_key.?);
}

test "cli env overrides image env by key" {
    const merged = try mergeGuestEnv(std.testing.allocator, &.{ "PATH", "KEEP=1" }, &.{ "PATH=/usr/bin", "NEW=2" });
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try std.testing.expectEqualStrings("KEEP=1", merged[0]);
    try std.testing.expectEqualStrings("PATH=/usr/bin", merged[1]);
    try std.testing.expectEqualStrings("NEW=2", merged[2]);

    var buffer: [max_guest_envc][]const u8 = undefined;
    const cleared = try mergeGuestEnvInto(&buffer, &.{ "CLEAR_ME", "KEEP=1" }, &.{"CLEAR_ME="});
    try std.testing.expectEqual(@as(usize, 2), cleared.len);
    try std.testing.expectEqualStrings("KEEP=1", cleared[0]);
    try std.testing.expectEqualStrings("CLEAR_ME=", cleared[1]);
}

test "run request rejects guest argv count overflow" {
    const argv = [_][]const u8{
        "/bin/true", "1",  "2",  "3",
        "4",         "5",  "6",  "7",
        "8",         "9",  "10", "11",
        "12",        "13", "14", "15",
        "16",
    };
    try std.testing.expectError(error.RunArgCountUnsupported, execRequest(std.testing.allocator, &argv));
}

test "run request rejects guest argv length overflow" {
    var arg = [_]u8{'a'} ** (max_guest_arg_len + 1);
    try std.testing.expectError(error.RunArgTooLong, execRequest(std.testing.allocator, &.{arg[0..]}));
}

test "run request accepts 4096 byte argv within total request limit" {
    var arg = [_]u8{'a'} ** 4096;
    const request = try execRequest(std.testing.allocator, &.{arg[0..]});
    defer std.testing.allocator.free(request);
    try std.testing.expect(request.len > arg.len);
}

test "run request rejects encoded line overflow" {
    var env_entry = [_]u8{'A'} ** max_guest_env_len;
    var env: [max_guest_envc][]const u8 = undefined;
    for (&env) |*slot| slot.* = env_entry[0..];
    try std.testing.expectError(error.RunRequestTooLarge, execRequestWithSessionOptions(std.testing.allocator, &.{"/bin/true"}, "default", .{ .env = &env }));
}

test "interactive run request uses start v1 pipe stdio" {
    const request = try execRequestWithSessionOptions(std.testing.allocator, &.{"/bin/cat"}, "default", .{ .stdio = .pipe });
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"type\":\"start-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"stdio\":\"pipe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"argv\":[\"/bin/cat\"]") != null);
}

test "streaming exec request uses start v1 with closed pipe stdin" {
    const request = try interactiveExecRequestWithSession(std.testing.allocator, &.{"/bin/true"}, "default", .{
        .env = &.{"SPORE_CONTEXT=stream"},
        .working_dir = "/workspace",
    });
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"type\":\"start-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"stdio\":\"pipe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"env\":[\"SPORE_CONTEXT=stream\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"working_dir\":\"/workspace\"") != null);
}

test "tty run request uses start v1 terminal metadata" {
    const request = try execRequestWithSessionOptions(std.testing.allocator, &.{"/bin/sh"}, "default", .{
        .stdio = .tty,
        .terminal_size = .{ .rows = 40, .cols = 120 },
    });
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"type\":\"start-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"stdio\":\"tty\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"terminal_rows\":40") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"terminal_cols\":120") != null);
}
