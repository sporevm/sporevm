//! Host-requested capture control for product `spore run`.

const std = @import("std");
const posix = std.posix;

pub const Signal = posix.SIG;

pub const Trigger = union(enum) {
    exit,
    signal: Signal,

    pub fn parse(raw: []const u8) ?Trigger {
        if (std.ascii.eqlIgnoreCase(raw, "EXIT")) return .exit;
        if (parseSignal(raw)) |signal| return .{ .signal = signal };
        return null;
    }

    pub fn isExit(self: Trigger) bool {
        return switch (self) {
            .exit => true,
            .signal => false,
        };
    }

    pub fn signalValue(self: Trigger) ?Signal {
        return switch (self) {
            .exit => null,
            .signal => |value| value,
        };
    }
};

pub const Plan = struct {
    snapshot_dir: ?[]const u8 = null,
    snapshot_on_probe_complete: bool = false,
    request: ?*Request = null,
    signal: ?Signal = null,
    continue_after_capture: bool = false,
    /// Fresh captures track dirty RAM and seal the dirty set at capture time.
    dirty_tracking: bool = false,

    pub const ProductRunOptions = struct {
        capture_path: ?[]const u8 = null,
        trigger: Trigger = .exit,
        resume_dir: ?[]const u8 = null,
        request: *Request,
        continue_after_capture: bool = false,
    };

    pub fn productRun(options: ProductRunOptions) Plan {
        const has_capture = options.capture_path != null;
        const signal = if (has_capture) options.trigger.signalValue() else null;

        return .{
            .snapshot_dir = options.capture_path,
            .snapshot_on_probe_complete = has_capture and options.trigger.isExit(),
            .request = if (signal != null) options.request else null,
            .signal = signal,
            .continue_after_capture = signal != null and options.continue_after_capture,
            .dirty_tracking = has_capture and options.resume_dir == null,
        };
    }

    pub fn isSignalCapture(self: Plan) bool {
        return self.signal != null;
    }

    pub fn isExitCapture(self: Plan) bool {
        return self.snapshot_dir != null and self.snapshot_on_probe_complete;
    }
};

pub const Error = error{CaptureAborted};
pub const WakeFn = *const fn (context: ?*anyopaque) callconv(.c) void;

pub const Request = struct {
    signal_count: std.atomic.Value(u32) = .init(0),
    completed: std.atomic.Value(bool) = .init(false),
    wake_fn_addr: std.atomic.Value(usize) = .init(0),
    wake_context_addr: std.atomic.Value(usize) = .init(0),

    pub fn request(self: *Request) void {
        self.signal_count.store(1, .release);
    }

    pub fn notifySignal(self: *Request) void {
        _ = self.signal_count.fetchAdd(1, .acq_rel);
        self.wake();
    }

    pub fn isRequested(self: *const Request) bool {
        return self.signal_count.load(.acquire) >= 1;
    }

    pub fn isAbortRequested(self: *const Request) bool {
        return self.signal_count.load(.acquire) >= 2;
    }

    pub fn markCompleted(self: *Request) void {
        self.completed.store(true, .release);
    }

    pub fn isCompleted(self: *const Request) bool {
        return self.completed.load(.acquire);
    }

    pub fn setWake(self: *Request, wake_fn: WakeFn, context: ?*anyopaque) void {
        self.wake_context_addr.store(if (context) |ptr| @intFromPtr(ptr) else 0, .release);
        self.wake_fn_addr.store(@intFromPtr(wake_fn), .release);
    }

    pub fn clearWake(self: *Request) void {
        self.wake_fn_addr.store(0, .release);
        self.wake_context_addr.store(0, .release);
    }

    fn wake(self: *Request) void {
        const wake_fn_addr = self.wake_fn_addr.load(.acquire);
        if (wake_fn_addr == 0) return;
        const wake_fn: WakeFn = @ptrFromInt(wake_fn_addr);
        const context_addr = self.wake_context_addr.load(.acquire);
        const context: ?*anyopaque = if (context_addr == 0) null else @ptrFromInt(context_addr);
        wake_fn(context);
    }
};

/// Runs a capture wake on its own thread. A wake set with `Request.setWake`
/// runs inside the signal handler, which may only make async-signal-safe
/// calls; Hypervisor.framework's `hv_vcpus_exit` is not one. With this, the
/// handler only writes a byte to a pipe and the thread makes the wake call.
pub const WakeThread = struct {
    pipe: [2]posix.fd_t = .{ -1, -1 },
    thread: ?std.Thread = null,
    wake_fn: WakeFn = undefined,
    wake_context: ?*anyopaque = null,

    pub fn start(self: *WakeThread, request: *Request, wake_fn: WakeFn, context: ?*anyopaque) !void {
        self.* = .{ .wake_fn = wake_fn, .wake_context = context };
        if (std.c.pipe(&self.pipe) != 0) return error.CaptureWakeStartFailed;
        errdefer self.closePipe();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        request.setWake(notify, self);
    }

    pub fn stop(self: *WakeThread, request: *Request) void {
        request.clearWake();
        // Closing the write end ends the thread's read after any pending
        // wake byte.
        _ = std.c.close(self.pipe[1]);
        self.pipe[1] = -1;
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.closePipe();
    }

    fn closePipe(self: *WakeThread) void {
        for (&self.pipe) |*fd| {
            if (fd.* >= 0) _ = std.c.close(fd.*);
            fd.* = -1;
        }
    }

    fn notify(context: ?*anyopaque) callconv(.c) void {
        const self: *WakeThread = @ptrCast(@alignCast(context orelse return));
        const byte = [_]u8{1};
        _ = std.c.write(self.pipe[1], &byte, byte.len);
    }

    fn run(self: *WakeThread) void {
        var byte: [1]u8 = undefined;
        while (true) {
            const n = std.c.read(self.pipe[0], &byte, byte.len);
            if (n > 0) {
                self.wake_fn(self.wake_context);
            } else if (n == 0 or std.c.errno(n) != .INTR) {
                return;
            }
        }
    }
};

var active_request: ?*Request = null;

pub const SignalRegistration = struct {
    signal: Signal,
    old_action: posix.Sigaction,
    active: bool = true,

    pub fn install(signal: Signal, request: *Request) SignalRegistration {
        active_request = request;
        var old_action: posix.Sigaction = undefined;
        const action = posix.Sigaction{
            .handler = .{ .sigaction = handleSignal },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.SIGINFO,
        };
        posix.sigaction(signal, &action, &old_action);
        return .{
            .signal = signal,
            .old_action = old_action,
        };
    }

    pub fn deinit(self: *SignalRegistration) void {
        if (!self.active) return;
        posix.sigaction(self.signal, &self.old_action, null);
        if (active_request != null) active_request = null;
        self.active = false;
    }
};

fn handleSignal(_: Signal, _: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    if (active_request) |request| request.notifySignal();
}

pub fn parseSignal(raw: []const u8) ?Signal {
    const name = if (raw.len > 3 and std.ascii.eqlIgnoreCase(raw[0..3], "SIG"))
        raw[3..]
    else
        raw;
    if (std.ascii.eqlIgnoreCase(name, "INT")) return .INT;
    if (std.ascii.eqlIgnoreCase(name, "TERM")) return .TERM;
    if (std.ascii.eqlIgnoreCase(name, "HUP")) return .HUP;
    if (std.ascii.eqlIgnoreCase(name, "USR1")) return .USR1;
    if (std.ascii.eqlIgnoreCase(name, "USR2")) return .USR2;
    return null;
}

test "capture request records first signal as capture and second as abort" {
    var request_value = Request{};
    try std.testing.expect(!request_value.isRequested());
    try std.testing.expect(!request_value.isAbortRequested());

    request_value.notifySignal();
    try std.testing.expect(request_value.isRequested());
    try std.testing.expect(!request_value.isAbortRequested());
    try std.testing.expect(!request_value.isCompleted());

    request_value.notifySignal();
    try std.testing.expect(request_value.isRequested());
    try std.testing.expect(request_value.isAbortRequested());

    request_value.markCompleted();
    try std.testing.expect(request_value.isCompleted());
}

test "capture signal parser accepts common names" {
    try std.testing.expectEqual(Signal.INT, parseSignal("INT").?);
    try std.testing.expectEqual(Signal.INT, parseSignal("SIGINT").?);
    try std.testing.expectEqual(Signal.TERM, parseSignal("term").?);
    try std.testing.expectEqual(Signal.USR1, parseSignal("USR1").?);
    try std.testing.expectEqual(Signal.USR2, parseSignal("sigusr2").?);
    try std.testing.expect(parseSignal("KILL") == null);
}

test "capture trigger parser accepts exit and signals" {
    switch (Trigger.parse("EXIT").?) {
        .exit => {},
        .signal => return error.ExpectedExitTrigger,
    }
    switch (Trigger.parse("SIGUSR1").?) {
        .exit => return error.ExpectedSignalTrigger,
        .signal => |signal| try std.testing.expectEqual(Signal.USR1, signal),
    }
    try std.testing.expect(Trigger.parse("KILL") == null);
}

test "product run capture plan enables dirty tracking for fresh captures" {
    var request_value = Request{};
    const plan = Plan.productRun(.{
        .capture_path = "base.spore",
        .trigger = .{ .signal = Signal.USR1 },
        .resume_dir = null,
        .request = &request_value,
        .continue_after_capture = true,
    });

    try std.testing.expectEqualStrings("base.spore", plan.snapshot_dir.?);
    try std.testing.expect(!plan.snapshot_on_probe_complete);
    try std.testing.expectEqual(Signal.USR1, plan.signal.?);
    try std.testing.expectEqual(&request_value, plan.request.?);
    try std.testing.expect(plan.continue_after_capture);
    try std.testing.expect(plan.dirty_tracking);
    try std.testing.expect(plan.isSignalCapture());
    try std.testing.expect(!plan.isExitCapture());
}

test "product run capture plan keeps resume captures on full snapshot path" {
    var request_value = Request{};
    const plan = Plan.productRun(.{
        .capture_path = "resume.spore",
        .trigger = .exit,
        .resume_dir = "parent.spore",
        .request = &request_value,
    });

    try std.testing.expectEqualStrings("resume.spore", plan.snapshot_dir.?);
    try std.testing.expect(plan.snapshot_on_probe_complete);
    try std.testing.expect(plan.request == null);
    try std.testing.expect(plan.signal == null);
    try std.testing.expect(!plan.continue_after_capture);
    try std.testing.expect(!plan.dirty_tracking);
    try std.testing.expect(!plan.isSignalCapture());
    try std.testing.expect(plan.isExitCapture());
}

var test_wake_count: u32 = 0;

fn testWake(_: ?*anyopaque) callconv(.c) void {
    test_wake_count += 1;
}

test "capture request invokes optional wake hook" {
    test_wake_count = 0;
    var request_value = Request{};
    request_value.setWake(testWake, null);
    request_value.notifySignal();
    try std.testing.expectEqual(@as(u32, 1), test_wake_count);
    request_value.clearWake();
    request_value.notifySignal();
    try std.testing.expectEqual(@as(u32, 1), test_wake_count);
}

test "capture signal runs a thread wake outside the signal handler" {
    const Probe = struct {
        var woke = std.atomic.Value(bool).init(false);
        var woke_on: std.Thread.Id = 0;

        fn wake(_: ?*anyopaque) callconv(.c) void {
            woke_on = std.Thread.getCurrentId();
            woke.store(true, .release);
        }
    };
    var request_value = Request{};
    var wake_thread = WakeThread{};
    try wake_thread.start(&request_value, Probe.wake, null);
    var registration = SignalRegistration.install(.USR2, &request_value);
    // raise() returns after the handler has run on this thread; stop() then
    // joins the wake thread after it has handled any pending wake.
    const raised = posix.raise(.USR2);
    registration.deinit();
    wake_thread.stop(&request_value);
    try raised;

    try std.testing.expect(request_value.isRequested());
    try std.testing.expect(Probe.woke.load(.acquire));
    try std.testing.expect(Probe.woke_on != std.Thread.getCurrentId());
}
