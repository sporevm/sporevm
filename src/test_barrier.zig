const std = @import("std");

/// Deterministic two-party test barrier. Production code references it only
/// behind `builtin.is_test`; there is no environment variable or public API
/// that can pause a shipping process at these boundaries.
pub const Barrier = struct {
    reached: std.Io.Semaphore = .{},
    proceed: std.Io.Semaphore = .{},

    pub fn pause(self: *Barrier, io: std.Io) void {
        self.reached.post(io);
        self.proceed.waitUncancelable(io);
    }

    pub fn waitReached(self: *Barrier, io: std.Io) void {
        self.reached.waitUncancelable(io);
    }

    pub fn release(self: *Barrier, io: std.Io) void {
        self.proceed.post(io);
    }
};

/// Owns a spawned test thread and every barrier that can block it. Error paths
/// release all permits before joining, so an assertion failure cannot strand a
/// background thread and hang the rest of the test suite.
pub const ThreadGuard = struct {
    io: std.Io,
    thread: ?std.Thread,
    barriers: []const *Barrier,

    pub fn deinit(self: *ThreadGuard) void {
        for (self.barriers) |barrier| barrier.release(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    pub fn join(self: *ThreadGuard) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }
};
