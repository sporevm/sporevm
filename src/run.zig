//! One-shot VM boot/exec support for `spore run` and minimal benchmark tools.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const hvf = @import("hvf/hvf.zig");
const kvm = if (builtin.os.tag == .linux and builtin.cpu.arch == .aarch64)
    @import("kvm/kvm.zig")
else
    struct {};
const vsock = @import("virtio/vsock.zig");

const default_command = [_][]const u8{"/bin/true"};
const max_file_size = 256 * 1024 * 1024;

pub const Backend = enum {
    auto,
    hvf,
    kvm,

    pub fn parse(raw: []const u8) ?Backend {
        if (std.mem.eql(u8, raw, "auto")) return .auto;
        if (std.mem.eql(u8, raw, "hvf")) return .hvf;
        if (std.mem.eql(u8, raw, "kvm")) return .kvm;
        return null;
    }

    pub fn name(self: Backend) []const u8 {
        return switch (self) {
            .auto => "auto",
            .hvf => "hvf",
            .kvm => "kvm",
        };
    }
};

pub const Options = struct {
    backend: Backend = .auto,
    kernel_path: []const u8,
    initrd_path: []const u8,
    command: []const []const u8,
    memory_mib: u64 = 1024,
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    console_log_path: ?[]const u8 = null,
    emit_json: bool = false,
};

pub const Result = struct {
    backend: Backend,
    start_ms: u64,
    vsock_connect_ms: u64,
    exec_response_ms: u64,
    probe_duration_ms: u64,
    exit_code: i32,
    error_json: ?[]const u8,
    guest_timing_json: []const u8,
    vcpus: u32,
    memory_mib: u64,

    pub fn processExitCode(self: Result) u8 {
        std.debug.assert(self.exit_code >= 0 and self.exit_code <= 255);
        return @intCast(self.exit_code);
    }
};

const SharedOptions = struct {
    kernel_path: ?[]const u8 = null,
    initrd_path: ?[]const u8 = null,
    memory_mib: u64 = 1024,
    vcpus: u32 = 1,
    guest_port: u32 = 10700,
    timeout_ms: u64 = 30_000,
    console_log_path: ?[]const u8 = null,

    fn complete(self: SharedOptions, backend: Backend, command: []const []const u8, emit_json: bool) Options {
        return .{
            .backend = backend,
            .kernel_path = self.kernel_path.?,
            .initrd_path = self.initrd_path.?,
            .command = command,
            .memory_mib = self.memory_mib,
            .vcpus = self.vcpus,
            .guest_port = self.guest_port,
            .timeout_ms = self.timeout_ms,
            .console_log_path = self.console_log_path,
            .emit_json = emit_json,
        };
    }
};

const cli_usage =
    \\Usage:
    \\  spore run --kernel Image --initrd root.cpio [options] -- <argv...>
    \\
    \\Options:
    \\  --backend auto|hvf|kvm  Backend to run (default: auto)
    \\  --memory-mib N          Guest memory in MiB (default: 1024)
    \\  --vcpus N               Guest vCPU count; must be 1 today
    \\  --guest-port N          Guest vsock listen port (default: 10700)
    \\  --timeout-ms N          Probe timeout in milliseconds (default: 30000)
    \\  --console-log PATH      Write guest console output to PATH
    \\  --json                  Print the exit frame summary as JSON
    \\  -h, --help              Show this help
    \\
;

pub fn cli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help")) {
        try stdout.writeAll(cli_usage);
        return;
    }

    const arena = init.arena.allocator();
    const opts = try parseCliArgs(args);
    try openConsoleLog(opts.console_log_path);
    defer closeConsoleLog();

    const result = try execute(init, arena, opts);
    if (opts.emit_json) {
        try writeJsonResult(stdout, result);
        try stdout.flush();
    }
    const code = result.processExitCode();
    if (code != 0) std.process.exit(code);
}

pub fn parseCliArgs(args: []const []const u8) !Options {
    var backend: Backend = .auto;
    var shared = SharedOptions{};
    var emit_json = false;
    var command: ?[]const []const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            command = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, args[i], "--backend") and i + 1 < args.len) {
            i += 1;
            backend = Backend.parse(args[i]) orelse {
                std.debug.print("--backend must be auto, hvf, or kvm\n", .{});
                std.process.exit(2);
            };
        } else if (try parseSharedOption(&shared, args, &i)) {
            continue;
        } else if (std.mem.eql(u8, args[i], "--json")) {
            emit_json = true;
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            std.debug.print("unknown run argument: {s}\n\n{s}", .{ args[i], cli_usage });
            std.process.exit(2);
        } else {
            command = args[i..];
            break;
        }
    }

    const argv = command orelse &.{};
    if (shared.kernel_path == null or shared.initrd_path == null or argv.len == 0) {
        std.debug.print("{s}", .{cli_usage});
        std.process.exit(2);
    }

    return shared.complete(backend, argv, emit_json);
}

pub fn parseHarnessArgs(backend: Backend, args: []const []const u8) !Options {
    var shared = SharedOptions{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (try parseSharedOption(&shared, args, &i)) {
            continue;
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            printHarnessUsage(backend);
            std.process.exit(0);
        } else {
            std.debug.print("unknown argument: {s}\n\n", .{args[i]});
            printHarnessUsage(backend);
            std.process.exit(2);
        }
    }

    if (shared.kernel_path == null or shared.initrd_path == null) {
        printHarnessUsage(backend);
        std.process.exit(2);
    }

    return shared.complete(backend, default_command[0..], true);
}

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, opts: Options) !Result {
    if (opts.vcpus != 1) return error.UnsupportedVcpuCount;

    const backend = try resolveBackend(opts.backend);
    const kernel = try std.Io.Dir.cwd().readFileAlloc(init.io, opts.kernel_path, allocator, .limited(max_file_size));
    const initrd = try std.Io.Dir.cwd().readFileAlloc(init.io, opts.initrd_path, allocator, .limited(max_file_size));
    const boot_args = try cmdline(allocator, opts.guest_port);
    const request = try execRequest(allocator, opts.command);
    var stream = try vsock.HostStream.init(opts.guest_port, request);

    const cause = switch (backend) {
        .auto => unreachable,
        .hvf => blk: {
            if (comptime !(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) return error.UnsupportedBackend;
            break :blk try hvf.vm.run(allocator, .{
                .kernel = kernel,
                .ram_size = opts.memory_mib * 1024 * 1024,
                .cmdline = boot_args,
                .initrd = initrd,
                .console_sink = consoleSink,
                .exec_probe = &stream,
                .exec_probe_timeout_ms = opts.timeout_ms,
            });
        },
        .kvm => blk: {
            if (comptime !(builtin.os.tag == .linux and builtin.cpu.arch == .aarch64)) return error.UnsupportedBackend;
            break :blk try kvm.vm.run(allocator, .{
                .kernel = kernel,
                .ram_size = opts.memory_mib * 1024 * 1024,
                .cmdline = boot_args,
                .initrd = initrd,
                .console_sink = consoleSink,
                .exec_probe = &stream,
                .exec_probe_timeout_ms = opts.timeout_ms,
            });
        },
    };
    if (cause != .probe_complete) return error.ProbeDidNotComplete;

    return resultFromStream(allocator, backend, opts, &stream);
}

pub fn writeJsonResult(writer: *Io.Writer, result: Result) !void {
    try writer.print(
        "{{\"backend\":\"{s}\",\"probe\":\"exec\",\"start_ms\":{d},\"vsock_connect_ms\":{d},\"exec_response_ms\":{d},\"probe_duration_ms\":{d},\"exit_code\":{d},\"error\":",
        .{ result.backend.name(), result.start_ms, result.vsock_connect_ms, result.exec_response_ms, result.probe_duration_ms, result.exit_code },
    );
    if (result.error_json) |value| {
        try writer.writeAll(value);
    } else {
        try writer.writeAll("null");
    }
    try writer.print(
        ",\"guest_timing_ms\":{s},\"vcpus\":{d},\"memory_mib\":{d}}}\n",
        .{ result.guest_timing_json, result.vcpus, result.memory_mib },
    );
}

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

pub fn execRequest(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    const payload = struct {
        argv: []const []const u8,
        closed_env: bool = true,
    }{ .argv = argv };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

pub fn cmdline(allocator: std.mem.Allocator, guest_port: u32) ![]const u8 {
    return std.fmt.allocPrint(allocator, "console=hvc0 rdinit=/init cleanroom_guest_port={d} cleanroom_guest_boot_timing=1", .{guest_port});
}

fn resolveBackend(backend: Backend) !Backend {
    if (backend != .auto) return backend;
    if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) return .hvf;
    if (builtin.os.tag == .linux and builtin.cpu.arch == .aarch64) return .kvm;
    return error.UnsupportedBackend;
}

fn resultFromStream(allocator: std.mem.Allocator, backend: Backend, opts: Options, stream: *const vsock.HostStream) !Result {
    const output = stream.outputSlice();
    const exit_code = parseExitCode(output) orelse return error.BadRunExitFrame;
    if (exit_code < 0 or exit_code > 255) return error.BadRunExitFrame;
    const timing_src = guestTimingObject(output) orelse return error.BadRunExitFrame;
    const error_src = guestErrorValue(output);
    const start_ms = stream.start_ms orelse 0;
    const connect_ms = stream.connect_ms orelse stream.elapsedMs();
    const response_ms = stream.response_ms orelse stream.elapsedMs();
    return .{
        .backend = backend,
        .start_ms = start_ms,
        .vsock_connect_ms = connect_ms,
        .exec_response_ms = response_ms,
        .probe_duration_ms = if (response_ms >= connect_ms) response_ms - connect_ms else 0,
        .exit_code = exit_code,
        .error_json = if (error_src) |value| try allocator.dupe(u8, value) else null,
        .guest_timing_json = try allocator.dupe(u8, timing_src),
        .vcpus = opts.vcpus,
        .memory_mib = opts.memory_mib,
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

fn parseSharedOption(shared: *SharedOptions, args: []const []const u8, i: *usize) !bool {
    const name = args[i.*];
    if (std.mem.eql(u8, name, "--kernel")) {
        shared.kernel_path = takeValue(args, i, name);
    } else if (std.mem.eql(u8, name, "--initrd")) {
        shared.initrd_path = takeValue(args, i, name);
    } else if (std.mem.eql(u8, name, "--memory-mib")) {
        shared.memory_mib = try parsePositive(u64, name, takeValue(args, i, name));
    } else if (std.mem.eql(u8, name, "--vcpus")) {
        shared.vcpus = try parsePositive(u32, name, takeValue(args, i, name));
    } else if (std.mem.eql(u8, name, "--guest-port")) {
        shared.guest_port = try parsePositive(u32, name, takeValue(args, i, name));
    } else if (std.mem.eql(u8, name, "--timeout-ms")) {
        shared.timeout_ms = try parsePositive(u64, name, takeValue(args, i, name));
    } else if (std.mem.eql(u8, name, "--console-log")) {
        shared.console_log_path = takeValue(args, i, name);
    } else {
        return false;
    }
    return true;
}

fn takeValue(args: []const []const u8, i: *usize, name: []const u8) []const u8 {
    if (i.* + 1 >= args.len) {
        std.debug.print("{s} requires a value\n", .{name});
        std.process.exit(2);
    }
    i.* += 1;
    return args[i.*];
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
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return output[start .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

fn printHarnessUsage(backend: Backend) void {
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
    , .{backend.name()});
}

test "run request encodes argv" {
    const request = try execRequest(std.testing.allocator, &.{ "/bin/echo", "hello world" });
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings("{\"argv\":[\"/bin/echo\",\"hello world\"],\"closed_env\":true}\n", request);
}

test "run cli parser accepts command after separator" {
    const opts = try parseCliArgs(&.{ "--backend", "hvf", "--kernel", "Image", "--initrd", "root.cpio", "--", "/bin/true" });
    try std.testing.expectEqual(Backend.hvf, opts.backend);
    try std.testing.expectEqualStrings("Image", opts.kernel_path);
    try std.testing.expectEqualStrings("root.cpio", opts.initrd_path);
    try std.testing.expectEqual(@as(usize, 1), opts.command.len);
    try std.testing.expectEqualStrings("/bin/true", opts.command[0]);
}

test "run harness parser shares common options" {
    const opts = try parseHarnessArgs(.kvm, &.{ "kvm-minimal", "--kernel", "Image", "--initrd", "root.cpio", "--memory-mib", "512", "--guest-port", "12000" });
    try std.testing.expectEqual(Backend.kvm, opts.backend);
    try std.testing.expectEqualStrings("Image", opts.kernel_path);
    try std.testing.expectEqualStrings("root.cpio", opts.initrd_path);
    try std.testing.expectEqual(@as(u64, 512), opts.memory_mib);
    try std.testing.expectEqual(@as(u32, 12000), opts.guest_port);
    try std.testing.expectEqualStrings("/bin/true", opts.command[0]);
}

test "run result parser extracts exit and timing" {
    const output =
        "{\"type\":\"exit\",\"exit_code\":0,\"error\":null,\"guest_timing_ms\":{\"guest_init_start\":1,\"guest_command_exit\":9}}\n";
    try std.testing.expectEqual(@as(?i32, 0), parseExitCode(output));
    try std.testing.expectEqualStrings("{\"guest_init_start\":1,\"guest_command_exit\":9}", guestTimingObject(output).?);
    try std.testing.expect(guestErrorValue(output) == null);
}

fn fuzzRunResultParsing(_: void, s: *std.testing.Smith) !void {
    var buf: [4096]u8 = undefined;
    const len = s.slice(&buf);
    _ = parseExitCode(buf[0..len]);
    _ = guestErrorValue(buf[0..len]);
    _ = guestTimingObject(buf[0..len]);
}

test "fuzz run result parsing" {
    try std.testing.fuzz({}, fuzzRunResultParsing, .{});
}
