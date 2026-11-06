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
};

/// What the VMM captures, where, and when.
pub const Capture = struct {
    dir: []const u8,
    trigger: When,
    /// Track dirty RAM from boot and seal only the dirty set at capture time.
    dirty_tracking: bool = false,

    pub const When = union(enum) {
        /// Capture when the probe command completes, then stop.
        probe_complete,
        /// Capture when the host request fires.
        request: struct { req: *Request, then: Then },
    };

    pub const Then = enum { stop, keep_running };
};

pub const Plan = struct {
    capture: ?Capture = null,
    /// Signal that fires the capture request; null for exit captures.
    signal: ?Signal = null,

    pub const ProductRunOptions = struct {
        capture_path: ?[]const u8 = null,
        trigger: Trigger = .exit,
        resume_dir: ?[]const u8 = null,
        request: *Request,
        continue_after_capture: bool = false,
    };

    pub fn productRun(options: ProductRunOptions) Plan {
        const dir = options.capture_path orelse return .{};
        // Fresh captures track dirty RAM and seal the dirty set at capture time.
        const dirty_tracking = options.resume_dir == null;
        return switch (options.trigger) {
            .exit => .{ .capture = .{ .dir = dir, .trigger = .probe_complete, .dirty_tracking = dirty_tracking } },
            .signal => |signal| .{
                .capture = .{
                    .dir = dir,
                    .trigger = .{ .request = .{
                        .req = options.request,
                        .then = if (options.continue_after_capture) .keep_running else .stop,
                    } },
                    .dirty_tracking = dirty_tracking,
                },
                .signal = signal,
            },
        };
    }

    pub fn isSignalCapture(self: Plan) bool {
        return self.signal != null;
    }

    pub fn isExitCapture(self: Plan) bool {
        const value = self.capture orelse return false;
        return value.trigger == .probe_complete;
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

    const value = plan.capture.?;
    try std.testing.expectEqualStrings("base.spore", value.dir);
    try std.testing.expectEqual(&request_value, value.trigger.request.req);
    try std.testing.expectEqual(Capture.Then.keep_running, value.trigger.request.then);
    try std.testing.expect(value.dirty_tracking);
    try std.testing.expectEqual(Signal.USR1, plan.signal.?);
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
        .continue_after_capture = true,
    });

    const value = plan.capture.?;
    try std.testing.expectEqualStrings("resume.spore", value.dir);
    try std.testing.expect(value.trigger == .probe_complete);
    try std.testing.expect(!value.dirty_tracking);
    try std.testing.expect(plan.signal == null);
    try std.testing.expect(!plan.isSignalCapture());
    try std.testing.expect(plan.isExitCapture());
}

test "product run without a capture path plans no capture" {
    var request_value = Request{};
    const plan = Plan.productRun(.{ .trigger = .{ .signal = Signal.USR1 }, .request = &request_value });
    try std.testing.expect(plan.capture == null);
    try std.testing.expect(plan.signal == null);
    try std.testing.expect(!plan.isSignalCapture());
    try std.testing.expect(!plan.isExitCapture());
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
