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
const max_guest_argc = 16;
const max_guest_arg_len = 255;
const max_guest_request_len = 2047;
const max_guest_port = 65535;
const max_guest_output_bytes = 16 * 1024;

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
    guest_stdout: []const u8,
    guest_stderr: []const u8,
    stdout_truncated: bool,
    stderr_truncated: bool,
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
        try writeJsonResult(arena, stdout, result);
        try stdout.flush();
    } else {
        try writeGuestOutput(init, stdout, result);
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

pub fn writeJsonResult(allocator: std.mem.Allocator, writer: *Io.Writer, result: Result) !void {
    const stdout_b64 = try base64Alloc(allocator, result.guest_stdout);
    defer allocator.free(stdout_b64);
    const stderr_b64 = try base64Alloc(allocator, result.guest_stderr);
    defer allocator.free(stderr_b64);
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
        ",\"stdout_b64\":\"{s}\",\"stderr_b64\":\"{s}\",\"stdout_truncated\":{},\"stderr_truncated\":{},\"guest_timing_ms\":{s},\"vcpus\":{d},\"memory_mib\":{d}}}\n",
        .{
            stdout_b64,
            stderr_b64,
            result.stdout_truncated,
            result.stderr_truncated,
            result.guest_timing_json,
            result.vcpus,
            result.memory_mib,
        },
    );
}

fn writeGuestOutput(init: std.process.Init, stdout: *Io.Writer, result: Result) !void {
    try stdout.writeAll(result.guest_stdout);
    try stdout.flush();

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    try stderr.writeAll(result.guest_stderr);
    if (result.stdout_truncated) try writeTruncationNotice(stderr, result.guest_stderr.len > 0, "stdout");
    if (result.stderr_truncated) try writeTruncationNotice(stderr, result.guest_stderr.len > 0 or result.stdout_truncated, "stderr");
    try stderr.flush();
}

fn writeTruncationNotice(writer: *Io.Writer, already_wrote_stderr: bool, name: []const u8) !void {
    if (already_wrote_stderr) try writer.writeAll("\n");
    try writer.print("spore run: guest {s} truncated after {d} bytes\n", .{ name, max_guest_output_bytes });
}

fn base64Alloc(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(out, bytes);
    return out;
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
    try validateGuestArgv(argv);
    const payload = struct {
        argv: []const []const u8,
        closed_env: bool = true,
    }{ .argv = argv };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);
    if (json.len + 1 > max_guest_request_len) return error.RunRequestTooLarge;
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
    const frame = try parseExitFrame(allocator, output);
    const start_ms = stream.start_ms orelse 0;
    const connect_ms = stream.connect_ms orelse stream.elapsedMs();
    const response_ms = stream.response_ms orelse stream.elapsedMs();
    return .{
        .backend = backend,
        .start_ms = start_ms,
        .vsock_connect_ms = connect_ms,
        .exec_response_ms = response_ms,
        .probe_duration_ms = if (response_ms >= connect_ms) response_ms - connect_ms else 0,
        .exit_code = frame.exit_code,
        .error_json = frame.error_json,
        .guest_timing_json = frame.guest_timing_json,
        .guest_stdout = frame.guest_stdout,
        .guest_stderr = frame.guest_stderr,
        .stdout_truncated = frame.stdout_truncated,
        .stderr_truncated = frame.stderr_truncated,
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

fn parseGuestPort(name: []const u8, raw: []const u8) !u32 {
    const parsed = std.fmt.parseInt(u32, raw, 10) catch {
        std.debug.print("{s} must be an integer from 1 to {d}\n", .{ name, max_guest_port });
        std.process.exit(2);
    };
    if (parsed == 0 or parsed > max_guest_port) {
        std.debug.print("{s} must be an integer from 1 to {d}\n", .{ name, max_guest_port });
        std.process.exit(2);
    }
    return parsed;
}

fn validateGuestArgv(argv: []const []const u8) !void {
    if (argv.len == 0 or argv.len > max_guest_argc) return error.RunArgCountUnsupported;
    for (argv) |arg| {
        if (arg.len > max_guest_arg_len) return error.RunArgTooLong;
    }
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
        shared.guest_port = try parseGuestPort(name, takeValue(args, i, name));
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

const ExitFrame = struct {
    type: []const u8,
    exit_code: i64,
    @"error": ?[]const u8,
    stdout_b64: ?[]const u8 = null,
    stderr_b64: ?[]const u8 = null,
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
    guest_timing_ms: std.json.Value,
};

const ParsedExitFrame = struct {
    exit_code: i32,
    error_json: ?[]const u8,
    guest_timing_json: []const u8,
    guest_stdout: []const u8,
    guest_stderr: []const u8,
    stdout_truncated: bool,
    stderr_truncated: bool,

    fn deinit(self: ParsedExitFrame, allocator: std.mem.Allocator) void {
        if (self.error_json) |value| allocator.free(value);
        allocator.free(self.guest_timing_json);
        allocator.free(self.guest_stdout);
        allocator.free(self.guest_stderr);
    }
};

fn parseExitFrame(allocator: std.mem.Allocator, output: []const u8) !ParsedExitFrame {
    var parsed = std.json.parseFromSlice(ExitFrame, allocator, output, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.BadRunExitFrame;
    defer parsed.deinit();

    const frame = parsed.value;
    if (!std.mem.eql(u8, frame.type, "exit")) return error.BadRunExitFrame;
    if (frame.exit_code < 0 or frame.exit_code > 255) return error.BadRunExitFrame;
    switch (frame.guest_timing_ms) {
        .object => {},
        else => return error.BadRunExitFrame,
    }

    const timing_json = try std.json.Stringify.valueAlloc(allocator, frame.guest_timing_ms, .{});
    errdefer allocator.free(timing_json);
    const error_json = if (frame.@"error") |value| try std.json.Stringify.valueAlloc(allocator, value, .{}) else null;
    errdefer if (error_json) |value| allocator.free(value);
    const guest_stdout = try decodeGuestOutput(allocator, frame.stdout_b64 orelse "");
    errdefer allocator.free(guest_stdout);
    const guest_stderr = try decodeGuestOutput(allocator, frame.stderr_b64 orelse "");
    errdefer allocator.free(guest_stderr);

    return .{
        .exit_code = @intCast(frame.exit_code),
        .error_json = error_json,
        .guest_timing_json = timing_json,
        .guest_stdout = guest_stdout,
        .guest_stderr = guest_stderr,
        .stdout_truncated = frame.stdout_truncated,
        .stderr_truncated = frame.stderr_truncated,
    };
}

fn decodeGuestOutput(allocator: std.mem.Allocator, b64: []const u8) ![]const u8 {
    const dec = std.base64.standard.Decoder;
    const decoded_size = dec.calcSizeForSlice(b64) catch return error.BadRunExitFrame;
    if (decoded_size > max_guest_output_bytes) return error.BadRunExitFrame;
    const decoded = try allocator.alloc(u8, decoded_size);
    errdefer allocator.free(decoded);
    dec.decode(decoded, b64) catch return error.BadRunExitFrame;
    return decoded;
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

test "run request rejects encoded line overflow" {
    var arg = [_]u8{'a'} ** 240;
    var argv: [10][]const u8 = undefined;
    for (&argv) |*slot| slot.* = arg[0..];
    try std.testing.expectError(error.RunRequestTooLarge, execRequest(std.testing.allocator, &argv));
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
        "{\"type\":\"exit\",\"exit_code\":0,\"error\":null,\"stdout_b64\":\"aGVsbG8K\",\"stderr_b64\":\"ZXJyCg==\",\"stdout_truncated\":false,\"stderr_truncated\":true,\"guest_timing_ms\":{\"guest_init_start\":1,\"guest_command_exit\":9}}\n";
    const frame = try parseExitFrame(std.testing.allocator, output);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 0), frame.exit_code);
    try std.testing.expectEqualStrings("{\"guest_init_start\":1,\"guest_command_exit\":9}", frame.guest_timing_json);
    try std.testing.expect(frame.error_json == null);
    try std.testing.expectEqualStrings("hello\n", frame.guest_stdout);
    try std.testing.expectEqualStrings("err\n", frame.guest_stderr);
    try std.testing.expect(!frame.stdout_truncated);
    try std.testing.expect(frame.stderr_truncated);
}

test "run result parser reads top-level exit code" {
    const output =
        "{\"type\":\"exit\",\"metadata\":{\"exit_code\":0},\"exit_code\":1,\"error\":null,\"guest_timing_ms\":{\"guest_command_exit\":9}}\n";
    const frame = try parseExitFrame(std.testing.allocator, output);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 1), frame.exit_code);
}

test "run result parser preserves timing strings with braces" {
    const output =
        "{\"type\":\"exit\",\"exit_code\":0,\"error\":null,\"guest_timing_ms\":{\"note\":\"}\",\"guest_command_exit\":9}}\n";
    const frame = try parseExitFrame(std.testing.allocator, output);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{\"note\":\"}\",\"guest_command_exit\":9}", frame.guest_timing_json);
}

test "run result parser rejects malformed timing value" {
    try std.testing.expectError(error.BadRunExitFrame, parseExitFrame(
        std.testing.allocator,
        "{\"type\":\"exit\",\"exit_code\":0,\"error\":null,\"guest_timing_ms\":\"not an object\"}\n",
    ));
}

test "run result parser rejects malformed output encoding" {
    try std.testing.expectError(error.BadRunExitFrame, parseExitFrame(
        std.testing.allocator,
        "{\"type\":\"exit\",\"exit_code\":0,\"error\":null,\"stdout_b64\":\"not base64!\",\"stderr_b64\":\"\",\"guest_timing_ms\":{}}\n",
    ));
}

test "run json result includes encoded output metadata" {
    const allocator = std.testing.allocator;
    var stdout: Io.Writer.Allocating = .init(allocator);
    defer stdout.deinit();

    try writeJsonResult(allocator, &stdout.writer, .{
        .backend = .hvf,
        .start_ms = 1,
        .vsock_connect_ms = 2,
        .exec_response_ms = 3,
        .probe_duration_ms = 1,
        .exit_code = 0,
        .error_json = null,
        .guest_timing_json = "{}",
        .guest_stdout = "hello\n",
        .guest_stderr = "err\n",
        .stdout_truncated = false,
        .stderr_truncated = true,
        .vcpus = 1,
        .memory_mib = 1024,
    });

    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "\"stdout_b64\":\"aGVsbG8K\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "\"stderr_b64\":\"ZXJyCg==\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "\"stdout_truncated\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "\"stderr_truncated\":true") != null);
}

fn fuzzRunResultParsing(_: void, s: *std.testing.Smith) !void {
    var buf: [4096]u8 = undefined;
    const len = s.slice(&buf);
    if (parseExitFrame(std.testing.allocator, buf[0..len])) |frame| {
        frame.deinit(std.testing.allocator);
    } else |_| {}
}

test "fuzz run result parsing" {
    try std.testing.fuzz({}, fuzzRunResultParsing, .{});
}
