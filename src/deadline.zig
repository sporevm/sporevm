//! Waits that end on time. A sleep can return late (macOS coalesces timers),
//! so a wait rechecks a monotonic clock instead of adding up the sleeps it
//! asked for.

const std = @import("std");

pub const Clock = struct {
    nowMs: *const fn () u64,
    sleepMs: *const fn (u64) void,
};

pub const system_clock = Clock{ .nowMs = monotonicMs, .sleepMs = sleepMs };

/// Sleeps in slices of at most `slice_ms` until `duration_ms` has passed on
/// `clock` or `stop` is set. Returns whether `stop` was set.
pub fn sleepFor(clock: Clock, duration_ms: u64, slice_ms: u64, stop: *const std.atomic.Value(bool)) bool {
    const deadline_ms = clock.nowMs() +| duration_ms;
    while (!stop.load(.acquire)) {
        const now_ms = clock.nowMs();
        if (now_ms >= deadline_ms) return false;
        clock.sleepMs(@min(deadline_ms - now_ms, slice_ms));
    }
    return true;
}

fn monotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn sleepMs(ms: u64) void {
    var ts = std.c.timespec{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast((ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);
}

test "sleepFor ends at the deadline when every sleep overruns" {
    const OverrunningClock = struct {
        var now_ms: u64 = 0;

        fn nowMs() u64 {
            return now_ms;
        }

        fn sleepMs(ms: u64) void {
            now_ms += 3 * ms;
        }
    };
    const clock = Clock{ .nowMs = OverrunningClock.nowMs, .sleepMs = OverrunningClock.sleepMs };
    var stop = std.atomic.Value(bool).init(false);

    try std.testing.expect(!sleepFor(clock, 20 * std.time.ms_per_s, 100, &stop));
    // One overrun slice past 20s at most, not the 60s that 200 tripled
    // 100ms sleeps take.
    try std.testing.expect(OverrunningClock.now_ms >= 20_000);
    try std.testing.expect(OverrunningClock.now_ms <= 20_300);
}
