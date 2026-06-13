const std = @import("std");
const Io = std.Io;

pub const Options = struct {
    kernel_path: []const u8,
    initrd_path: []const u8,
    memory_mib: u64 = 1024,
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    console_log_path: ?[]const u8 = null,
};

pub var console_fd: std.c.fd_t = -1;

pub fn consoleSink(bytes: []const u8) void {
    if (console_fd < 0) return;
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(console_fd, remaining.ptr, remaining.len);
        if (n <= 0) return;
        remaining = remaining[@intCast(n)..];
    }
}

pub fn execRequest() []const u8 {
    return "{\"command\":[\"/bin/true\"],\"closed_env\":true}\n";
}

pub fn cmdline(allocator: std.mem.Allocator, guest_port: u32) ![]const u8 {
    return std.fmt.allocPrint(allocator, "console=hvc0 rdinit=/init cleanroom_guest_port={d} cleanroom_guest_boot_timing=1", .{guest_port});
}

pub fn parseArgs(backend: []const u8, args: []const []const u8) !Options {
    var kernel_path: ?[]const u8 = null;
    var initrd_path: ?[]const u8 = null;
    var memory_mib: u64 = 1024;
    var vcpus: u32 = 1;
    var guest_port: u32 = 10700;
    var timeout_ms: u64 = 30_000;
    var console_log_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--kernel") and i + 1 < args.len) {
            i += 1;
            kernel_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--initrd") and i + 1 < args.len) {
            i += 1;
            initrd_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--memory-mib") and i + 1 < args.len) {
            i += 1;
            memory_mib = try parsePositive(u64, "--memory-mib", args[i]);
        } else if (std.mem.eql(u8, args[i], "--vcpus") and i + 1 < args.len) {
            i += 1;
            vcpus = try parsePositive(u32, "--vcpus", args[i]);
        } else if (std.mem.eql(u8, args[i], "--guest-port") and i + 1 < args.len) {
            i += 1;
            guest_port = try parsePositive(u32, "--guest-port", args[i]);
        } else if (std.mem.eql(u8, args[i], "--timeout-ms") and i + 1 < args.len) {
            i += 1;
            timeout_ms = try parsePositive(u64, "--timeout-ms", args[i]);
        } else if (std.mem.eql(u8, args[i], "--console-log") and i + 1 < args.len) {
            i += 1;
            console_log_path = args[i];
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            printUsage(backend);
            std.process.exit(0);
        } else {
            std.debug.print("unknown argument: {s}\n\n", .{args[i]});
            printUsage(backend);
            std.process.exit(2);
        }
    }

    if (kernel_path == null or initrd_path == null) {
        printUsage(backend);
        std.process.exit(2);
    }
    if (vcpus != 1) {
        std.debug.print("{s}-minimal supports exactly one vCPU today\n", .{backend});
        std.process.exit(2);
    }

    return .{
        .kernel_path = kernel_path.?,
        .initrd_path = initrd_path.?,
        .memory_mib = memory_mib,
        .vcpus = vcpus,
        .guest_port = guest_port,
        .timeout_ms = timeout_ms,
        .console_log_path = console_log_path,
    };
}

fn parsePositive(comptime T: type, name: []const u8, raw: []const u8) !T {
    const parsed = std.fmt.parseInt(T, raw, 10) catch {
        std.debug.print("{s} must be a positive integer\n", .{name});
        std.process.exit(2);
    };
    if (parsed == 0) {
        std.debug.print("{s} must be a positive integer\n", .{name});
        std.process.exit(2);
    }
    return parsed;
}

pub fn openConsoleLog(path: ?[]const u8) !void {
    if (path == null) return;
    const pathz = try std.heap.page_allocator.dupeZ(u8, path.?);
    defer std.heap.page_allocator.free(pathz);
    const fd = std.c.open(pathz, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
    if (fd < 0) return error.ConsoleLogOpenFailed;
    console_fd = fd;
}

pub fn closeConsoleLog() void {
    if (console_fd >= 0) {
        _ = std.c.close(console_fd);
        console_fd = -1;
    }
}

pub fn writeResult(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    backend: []const u8,
    opts: Options,
    stream: anytype,
) !u8 {
    const output = stream.outputSlice();
    const exit_code = parseExitCode(output) orelse 1;
    const timing = guestTimingObject(output) orelse "{}";
    const error_value = guestErrorValue(output);
    const start_ms = stream.start_ms orelse 0;
    const connect_ms = stream.connect_ms orelse stream.elapsedMs();
    const response_ms = stream.response_ms orelse stream.elapsedMs();
    const probe_duration_ms = if (response_ms >= connect_ms) response_ms - connect_ms else 0;

    try writer.print(
        "{{\"backend\":\"{s}\",\"probe\":\"exec\",\"start_ms\":{d},\"vsock_connect_ms\":{d},\"exec_response_ms\":{d},\"probe_duration_ms\":{d},\"exit_code\":{d},\"error\":",
        .{ backend, start_ms, connect_ms, response_ms, probe_duration_ms, exit_code },
    );
    if (error_value) |value| {
        try writer.writeAll(value);
    } else {
        try writer.writeAll("null");
    }
    try writer.print(
        ",\"guest_timing_ms\":{s},\"vcpus\":{d},\"memory_mib\":{d}}}\n",
        .{ timing, opts.vcpus, opts.memory_mib },
    );
    _ = allocator;
    return @intCast(@max(exit_code, 0));
}

fn parseExitCode(output: []const u8) ?i32 {
    const key = "\"exit_code\":";
    const pos = std.mem.indexOf(u8, output, key) orelse return null;
    var i = pos + key.len;
    var sign: i32 = 1;
    if (i < output.len and output[i] == '-') {
        sign = -1;
        i += 1;
    }
    const start = i;
    while (i < output.len and output[i] >= '0' and output[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    const parsed = std.fmt.parseInt(i32, output[start..i], 10) catch return null;
    return parsed * sign;
}

fn guestErrorValue(output: []const u8) ?[]const u8 {
    const key = "\"error\":";
    const pos = std.mem.indexOf(u8, output, key) orelse return null;
    var i = pos + key.len;
    if (std.mem.startsWith(u8, output[i..], "null")) return null;
    if (i >= output.len or output[i] != '"') return null;
    i += 1;
    var escaped = false;
    while (i < output.len) : (i += 1) {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (output[i] == '\\') {
            escaped = true;
            continue;
        }
        if (output[i] == '"') return output[pos + key.len .. i + 1];
    }
    return null;
}

fn guestTimingObject(output: []const u8) ?[]const u8 {
    const key = "\"guest_timing_ms\":";
    const pos = std.mem.indexOf(u8, output, key) orelse return null;
    var i = pos + key.len;
    if (i >= output.len or output[i] != '{') return null;
    const start = i;
    var depth: usize = 0;
    while (i < output.len) : (i += 1) {
        switch (output[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return output[start .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

fn printUsage(backend: []const u8) void {
    std.debug.print(
        \\Usage:
        \\  {s}-minimal --kernel Image --initrd root.cpio [options]
        \\
        \\Options:
        \\  --memory-mib N      Guest memory in MiB (default: 1024)
        \\  --vcpus N           Guest vCPU count; must be 1 today
        \\  --guest-port N      Guest vsock listen port (default: 10700)
        \\  --timeout-ms N      Probe timeout in milliseconds (default: 30000)
        \\  --console-log PATH  Write guest console output to PATH
        \\  -h, --help          Show this help
        \\
    , .{backend});
}

test "minimal result parser extracts exit and timing" {
    const output =
        "{\"type\":\"exit\",\"exit_code\":0,\"error\":null,\"guest_timing_ms\":{\"guest_init_start\":1,\"guest_command_exit\":9}}\n";
    try std.testing.expectEqual(@as(?i32, 0), parseExitCode(output));
    try std.testing.expectEqualStrings("{\"guest_init_start\":1,\"guest_command_exit\":9}", guestTimingObject(output).?);
    try std.testing.expect(guestErrorValue(output) == null);
}
