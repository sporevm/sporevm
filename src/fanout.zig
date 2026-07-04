//! Local fan-out orchestration for forked spores.

const std = @import("std");
const Io = std.Io;

const fd_util = @import("fd.zig");
const run_mod = @import("run.zig");
const spore = @import("spore.zig");
const spore_net_policy = @import("spore_net_policy.zig");

pub const Backend = run_mod.Backend;
const max_pending_line_bytes = 64 * 1024;
const default_resume_timeout_ms: u64 = 30_000;

pub const Options = struct {
    backend: Backend = .auto,
    children_dir: []const u8,
    duration_ms: ?u64 = null,
    timeout_ms: u64 = default_resume_timeout_ms,
    bound_services: run_mod.BoundServiceBindingList = .{},
};

const cli_usage =
    \\Usage:
    \\  spore fanout [--backend auto|hvf|kvm] [--for DURATION] <children-dir>
    \\
    \\Options:
    \\  --backend auto|hvf|kvm  Backend to run (default: auto)
    \\  --for DURATION          Stop resumed children after DURATION, e.g. 10s, 500ms, 1m
    \\  --timeout DURATION      Per-child resume probe timeout (default: 30s)
    \\  --bind-service NAME=unix:/path.sock
    \\                          Bind a manifest-declared service in every child
    \\  -h, --help              Show this help
    \\
;

const ChildSpec = struct {
    name: []const u8,
    path: []const u8,
};

const RunningChild = struct {
    name: []const u8,
    child: std.process.Child,
    stdout_thread: std.Thread,
    stderr_thread: std.Thread,
};

const OutputLock = struct {
    mutex: std.atomic.Mutex = .unlocked,

    fn lock(self: *OutputLock) void {
        while (!self.mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *OutputLock) void {
        self.mutex.unlock();
    }
};

pub fn cli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0 or wantsHelp(args)) {
        try stdout.writeAll(cli_usage);
        return;
    }

    const opts = try parseCliArgs(args);
    try execute(init, init.arena.allocator(), opts);
}

pub fn parseCliArgs(args: []const []const u8) !Options {
    var backend: Backend = .auto;
    var children_dir: ?[]const u8 = null;
    var duration_ms: ?u64 = null;
    var timeout_ms: u64 = default_resume_timeout_ms;
    var bound_services = run_mod.BoundServiceBindingList{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--backend") and i + 1 < args.len) {
            i += 1;
            backend = Backend.parse(args[i]) orelse {
                failCli("--backend must be auto, hvf, or kvm", .{});
            };
        } else if (std.mem.eql(u8, args[i], "--parallel")) {
            // Fan-out is parallel by definition today. Accepting the flag keeps
            // the demo command self-describing without adding a second mode.
        } else if (std.mem.eql(u8, args[i], "--for") and i + 1 < args.len) {
            i += 1;
            duration_ms = run_mod.parseDurationMs(args[i]) catch {
                failCli("--for expects a duration like 10s, 500ms, or 1m", .{});
            };
        } else if (std.mem.eql(u8, args[i], "--timeout") and i + 1 < args.len) {
            i += 1;
            timeout_ms = run_mod.parseDurationMs(args[i]) catch {
                failCli("--timeout expects a duration like 30s, 500ms, or 1m", .{});
            };
        } else if (std.mem.eql(u8, args[i], "--timeout-ms") and i + 1 < args.len) {
            i += 1;
            timeout_ms = parsePositiveInteger(args[i]) catch {
                failCli("--timeout-ms must be a positive integer", .{});
            };
        } else if (std.mem.eql(u8, args[i], "--bind-service") and i + 1 < args.len) {
            i += 1;
            bound_services.append(spore_net_policy.parseBoundServiceBinding(args[i]) catch |err| {
                failCli("spore fanout: invalid --bind-service {s}: {s}", .{ args[i], @errorName(err) });
            }) catch |err| {
                failCli("spore fanout: invalid --bind-service {s}: {s}", .{ args[i], @errorName(err) });
            };
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            failCli("unknown fanout argument: {s}\n\n{s}", .{ args[i], cli_usage });
        } else if (children_dir == null) {
            children_dir = args[i];
        } else {
            failCli("unexpected fanout argument: {s}\n\n{s}", .{ args[i], cli_usage });
        }
    }

    return .{
        .backend = backend,
        .children_dir = children_dir orelse {
            failCli("{s}", .{cli_usage});
        },
        .duration_ms = duration_ms,
        .timeout_ms = timeout_ms,
        .bound_services = bound_services,
    };
}

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, opts: Options) !void {
    const children = try listChildren(allocator, init.io, opts.children_dir);
    if (children.len == 0) {
        failCli("spore fanout: no child spore directories found in {s}", .{opts.children_dir});
    }
    try requireCapturedSessions(allocator, children);

    const argv0 = blk: {
        const full_args = try init.minimal.args.toSlice(allocator);
        break :blk full_args[0];
    };

    var output_lock = OutputLock{};
    var running = std.array_list.Managed(RunningChild).init(allocator);
    errdefer cleanupRunning(init.io, running.items);

    for (children) |child| {
        const run = try startRunningChild(init, allocator, argv0, opts.backend, opts.timeout_ms, opts.bound_services.slice(), child, &output_lock);
        running.append(run) catch |err| {
            var single = [_]RunningChild{run};
            cleanupRunning(init.io, single[0..]);
            return err;
        };
    }

    var done = std.atomic.Value(bool).init(false);
    const terminator_thread: ?std.Thread = if (opts.duration_ms) |ms|
        try std.Thread.spawn(.{}, terminateAfter, .{ running.items, ms, &done })
    else
        null;

    for (running.items) |run| {
        run.stdout_thread.join();
        run.stderr_thread.join();
    }
    done.store(true, .release);
    if (terminator_thread) |thread| thread.join();

    var failed = false;
    for (running.items) |*run| {
        const term = run.child.wait(init.io) catch |err| {
            writeStderr("spore fanout: child {s} wait failed: {s}\n", .{ run.name, @errorName(err) });
            failed = true;
            continue;
        };
        if (!termOk(term, opts.duration_ms != null)) {
            writeStderr("spore fanout: child {s} exited {s}\n", .{ run.name, termName(term) });
            failed = true;
        }
    }

    if (failed) std.process.exit(1);
}

fn spawnResume(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    argv0: []const u8,
    backend: Backend,
    timeout_ms: u64,
    bound_services: []const spore_net_policy.BoundServiceBinding,
    spore_dir: []const u8,
) !std.process.Child {
    const backend_arg = @tagName(backend);
    const timeout_arg = try std.fmt.allocPrint(allocator, "{d}ms", .{timeout_ms});
    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.appendSlice(&.{ argv0, "resume", "--backend", backend_arg, "--timeout", timeout_arg });
    for (bound_services) |binding| {
        const unix_path = switch (binding.target) {
            .unix => |path| path,
            .tcp => return error.UnsupportedBoundServiceTarget,
        };
        try argv.append("--bind-service");
        try argv.append(try std.fmt.allocPrint(allocator, "{s}=unix:{s}", .{ binding.name, unix_path }));
    }
    try argv.append(spore_dir);
    return std.process.spawn(init.io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
}

fn startRunningChild(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    argv0: []const u8,
    backend: Backend,
    timeout_ms: u64,
    bound_services: []const spore_net_policy.BoundServiceBinding,
    child: ChildSpec,
    output_lock: *OutputLock,
) !RunningChild {
    var proc = try spawnResume(init, allocator, argv0, backend, timeout_ms, bound_services, child.path);
    const stdout_fd = proc.stdout.?.handle;
    const stderr_fd = proc.stderr.?.handle;
    proc.stdout = null;
    proc.stderr = null;

    const stdout_thread = std.Thread.spawn(.{}, streamThread, .{ stdout_fd, child.name, output_lock }) catch |err| {
        proc.kill(init.io);
        _ = std.c.close(stdout_fd);
        _ = std.c.close(stderr_fd);
        return err;
    };

    const stderr_thread = std.Thread.spawn(.{}, streamThread, .{ stderr_fd, child.name, output_lock }) catch |err| {
        proc.kill(init.io);
        stdout_thread.join();
        _ = std.c.close(stderr_fd);
        return err;
    };

    return .{
        .name = child.name,
        .child = proc,
        .stdout_thread = stdout_thread,
        .stderr_thread = stderr_thread,
    };
}

fn cleanupRunning(io: Io, children: []RunningChild) void {
    terminateChildren(children, .TERM);
    sleepMs(500);
    terminateChildren(children, .KILL);
    for (children) |run| {
        run.stdout_thread.join();
        run.stderr_thread.join();
    }
    for (children) |*run| {
        if (run.child.id != null) run.child.kill(io);
    }
}

fn listChildren(allocator: std.mem.Allocator, io: Io, children_dir: []const u8) ![]ChildSpec {
    var dir = Io.Dir.cwd().openDir(io, children_dir, .{ .iterate = true }) catch |err| {
        writeStderr("spore fanout: cannot open {s}: {s}\n", .{ children_dir, @errorName(err) });
        std.process.exit(2);
    };
    defer dir.close(io);

    var children = std.array_list.Managed(ChildSpec).init(allocator);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{entry.name});
        dir.access(io, manifest_path, .{}) catch continue;
        try children.append(.{
            .name = try allocator.dupe(u8, entry.name),
            .path = try std.fs.path.join(allocator, &.{ children_dir, entry.name }),
        });
    }

    const out = try children.toOwnedSlice();
    std.mem.sort(ChildSpec, out, {}, lessChildSpec);
    return out;
}

fn requireCapturedSessions(allocator: std.mem.Allocator, children: []const ChildSpec) !void {
    for (children) |child| {
        const sessions = childSessionCount(allocator, child.path) catch |err| {
            failCli("spore fanout: child {s} has an invalid spore manifest: {s}", .{ child.name, @errorName(err) });
        };
        if (sessions == 0) {
            failCli(
                \\spore fanout: child {s} has no captured session.
                \\This checkpoint can still run new commands with:
                \\  spore run --from {s} '...'
                \\To fan out the original running command, create the checkpoint with:
                \\  spore run --capture checkpoint --capture-on TERM '...'
            , .{ child.name, child.path });
        }
    }
}

fn childSessionCount(allocator: std.mem.Allocator, spore_dir: []const u8) !usize {
    var manifest = spore.loadManifest(allocator, spore_dir) catch |err| switch (err) {
        error.BadManifest => null,
        else => return err,
    };
    defer if (manifest) |*parsed| parsed.deinit();
    if (manifest) |parsed| return parsed.value.sessions.len;

    var manifest_v1 = try spore.loadManifestV1(allocator, spore_dir);
    defer manifest_v1.deinit();
    return manifest_v1.value.sessions.len;
}

fn lessChildSpec(_: void, a: ChildSpec, b: ChildSpec) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn streamThread(fd: std.posix.fd_t, name: []const u8, output_lock: *OutputLock) void {
    defer _ = std.c.close(fd);

    var buf: [4096]u8 = undefined;
    var pending = std.array_list.Managed(u8).init(std.heap.page_allocator);
    defer pending.deinit();
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        writePrefixed(output_lock, name, &pending, buf[0..@intCast(n)]) catch break;
    }
    if (pending.items.len > 0) {
        writePrefixedLine(output_lock, name, pending.items, false);
    }
}

fn writePrefixed(output_lock: *OutputLock, name: []const u8, pending: *std.array_list.Managed(u8), bytes: []const u8) !void {
    var start: usize = 0;
    while (start < bytes.len) {
        var end = start;
        while (end < bytes.len and bytes[end] != '\n') : (end += 1) {}

        if (end < bytes.len and bytes[end] == '\n') {
            if (pending.items.len == 0) {
                writePrefixedLine(output_lock, name, bytes[start..end], true);
            } else {
                try pending.appendSlice(bytes[start..end]);
                writePrefixedLine(output_lock, name, pending.items, true);
                pending.clearRetainingCapacity();
            }
            start = end + 1;
        } else {
            try pending.appendSlice(bytes[start..end]);
            flushLongPendingLine(output_lock, name, pending);
            start = end;
        }
    }
}

fn flushLongPendingLine(output_lock: *OutputLock, name: []const u8, pending: *std.array_list.Managed(u8)) void {
    if (pending.items.len < max_pending_line_bytes) return;
    writePrefixedLine(output_lock, name, pending.items, true);
    pending.clearRetainingCapacity();
}

fn writePrefixedLine(output_lock: *OutputLock, name: []const u8, line: []const u8, newline: bool) void {
    output_lock.lock();
    fd_util.writeAllBestEffort(1, "[");
    fd_util.writeAllBestEffort(1, name);
    fd_util.writeAllBestEffort(1, "] ");
    fd_util.writeAllBestEffort(1, line);
    if (newline) fd_util.writeAllBestEffort(1, "\n");
    output_lock.unlock();
}

fn terminateChildren(children: []RunningChild, signal: std.posix.SIG) void {
    for (children) |child| {
        const pid = child.child.id orelse continue;
        std.posix.kill(-pid, signal) catch {
            std.posix.kill(pid, signal) catch {};
        };
    }
}

fn terminateAfter(children: []RunningChild, duration_ms: u64, done: *std.atomic.Value(bool)) void {
    if (sleepUntilDone(duration_ms, done)) return;
    terminateChildren(children, .TERM);
    if (sleepUntilDone(2 * std.time.ms_per_s, done)) return;
    terminateChildren(children, .KILL);
}

fn sleepUntilDone(duration_ms: u64, done: *std.atomic.Value(bool)) bool {
    var remaining = duration_ms;
    while (remaining > 0) {
        if (done.load(.acquire)) return true;
        const step = @min(remaining, 100);
        sleepMs(step);
        remaining -= step;
    }
    return done.load(.acquire);
}

fn termOk(term: std.process.Child.Term, duration_limited: bool) bool {
    return switch (term) {
        .exited => |code| code == 0,
        .signal => |signal| duration_limited and (signal == .TERM or signal == .KILL),
        .stopped, .unknown => false,
    };
}

fn termName(term: std.process.Child.Term) []const u8 {
    return switch (term) {
        .exited => "non-zero",
        .signal => "by signal",
        .stopped => "stopped",
        .unknown => "unknown",
    };
}

fn parsePositiveInteger(raw: []const u8) !u64 {
    if (raw.len == 0) return error.InvalidDuration;
    const value = try std.fmt.parseInt(u64, raw, 10);
    if (value == 0) return error.InvalidDuration;
    return value;
}

fn sleepMs(ms: u64) void {
    var ts = std.c.timespec{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast((ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);
}

fn writeStderr(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    fd_util.writeAllBestEffort(2, msg);
}

fn failCli(comptime fmt: []const u8, args: anytype) noreturn {
    writeStderr(fmt ++ "\n", args);
    std.process.exit(2);
}

fn wantsHelp(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "help") or
            std.mem.eql(u8, arg, "-h") or
            std.mem.eql(u8, arg, "--help"))
        {
            return true;
        }
    }
    return false;
}

test "fanout cli parser accepts requested demo shape" {
    const opts = try parseCliArgs(&.{ "children", "--parallel", "--for", "10s", "--backend", "hvf", "--timeout", "120s" });
    try std.testing.expectEqual(Backend.hvf, opts.backend);
    try std.testing.expectEqualStrings("children", opts.children_dir);
    try std.testing.expectEqual(@as(?u64, 10_000), opts.duration_ms);
    try std.testing.expectEqual(@as(u64, 120_000), opts.timeout_ms);
}

test "fanout cli parser accepts hidden timeout-ms compatibility spelling" {
    const opts = try parseCliArgs(&.{ "children", "--timeout-ms", "120000" });
    try std.testing.expectEqual(@as(u64, 120_000), opts.timeout_ms);
}

test "fanout cli help accepts help after options" {
    try std.testing.expect(wantsHelp(&.{"--help"}));
    try std.testing.expect(wantsHelp(&.{ "children", "--for", "10s", "--help" }));
    try std.testing.expect(!wantsHelp(&.{"children"}));
}

test "fanout cli parser accepts bound service bindings" {
    const opts = try parseCliArgs(&.{ "children", "--bind-service", "metadata=unix:/tmp/metadata.sock" });
    try std.testing.expectEqualStrings("children", opts.children_dir);
    try std.testing.expectEqual(@as(usize, 1), opts.bound_services.len);
    try std.testing.expectEqualStrings("metadata", opts.bound_services.items[0].name);
    try std.testing.expectEqualStrings("/tmp/metadata.sock", opts.bound_services.items[0].target.unix);
}

test "fanout duration parser accepts common suffixes" {
    try std.testing.expectEqual(@as(u64, 500), try run_mod.parseDurationMs("500ms"));
    try std.testing.expectEqual(@as(u64, 10_000), try run_mod.parseDurationMs("10s"));
    try std.testing.expectEqual(@as(u64, 60_000), try run_mod.parseDurationMs("1m"));
    try std.testing.expectEqual(@as(u64, 5_000), try run_mod.parseDurationMs("5"));
    try std.testing.expectError(error.InvalidDuration, run_mod.parseDurationMs("0s"));
}

fn testManifest(sessions: []const spore.Session) spore.Manifest {
    return .{
        .platform = .{
            .cpu_profile = "sporevm-aarch64-v0",
            .device_model_version = 4,
            .ram_base = 0x8000_0000,
            .ram_size = 0,
            .gic_dist_base = 0x0800_0000,
            .gic_redist_base = 0x0801_0000,
            .counter_frequency_hz = 24_000_000,
        },
        .machine = .{
            .gprs = [_]u64{0} ** 31,
            .pc = 0,
            .cpsr = 0,
            .fpcr = 0,
            .fpsr = 0,
            .simd = [_][2]u64{.{ 0, 0 }} ** 32,
            .sys_regs = &.{},
            .icc_regs = &.{},
            .vtimer = .{ .cntvct = 0, .cntv_ctl = 0, .cntv_cval = 0 },
            .gic = .{
                .kind = .gicv3,
                .gicv3 = .{ .dist_regs = &.{}, .redist_regs = &.{}, .line_levels = &.{} },
            },
        },
        .devices = &.{},
        .generation = .{ .generation = 0, .interrupt_status = 0, .params_b64 = "" },
        .sessions = sessions,
        .memory = .{ .chunk_size = spore.chunk_size, .chunks = &.{} },
    };
}

test "fanout preflight reads captured session presence" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const no_session_dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/no-session", .{tmp.sub_path[0..]});
    const session_dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/session", .{tmp.sub_path[0..]});
    try Io.Dir.cwd().createDirPath(io, no_session_dir);
    try Io.Dir.cwd().createDirPath(io, session_dir);

    try spore.saveManifest(arena, no_session_dir, testManifest(&.{}));
    try std.testing.expectEqual(@as(usize, 0), try childSessionCount(arena, no_session_dir));

    const sessions = [_]spore.Session{spore.processSession(spore.default_session_id, false, false)};
    try spore.saveManifest(arena, session_dir, testManifest(&sessions));
    try std.testing.expectEqual(@as(usize, 1), try childSessionCount(arena, session_dir));
}
