//! Backend-neutral authority for publishing a named snapshot into the shared CAS.

const std = @import("std");
const rootfs = @import("rootfs.zig");
const saved_spore_pin = @import("saved_spore_pin.zig");

const Io = std.Io;

pub const Wait = struct {
    started_ns: ?u64 = null,

    pub fn tryPrepare(self: *Wait, io: Io, allocator: std.mem.Allocator, cache_root: []const u8) !?SnapshotPreparation {
        const lock = rootfs.tryLockRootfsCacheExclusive(io, allocator, cache_root) catch |err| switch (err) {
            error.LockBusy => {
                if (self.started_ns == null) self.started_ns = monotonicNs();
                return null;
            },
            else => |e| {
                self.* = .{};
                return e;
            },
        };
        const wait_ns = if (self.started_ns) |started| monotonicNs() -| started else 0;
        self.* = .{};
        return .{ .lock = lock, .wait_ns = wait_ns };
    }
};

pub const SnapshotPreparation = struct {
    lock: rootfs.RootfsCacheLock,
    wait_ns: u64,

    pub fn cacheLock(self: *const SnapshotPreparation) *const rootfs.RootfsCacheLock {
        return &self.lock;
    }

    pub fn registry(self: *const SnapshotPreparation, allocator: std.mem.Allocator, cache_root: []const u8) !saved_spore_pin.LockedRegistry {
        return saved_spore_pin.LockedRegistry.init(allocator, cache_root, &self.lock);
    }

    pub fn deinit(self: *SnapshotPreparation) void {
        self.lock.deinit();
        self.wait_ns = 0;
    }
};

pub const Metrics = struct {
    cache_lock_wait_ns: u64 = 0,
    manifest_pin_authorization_ns: u64 = 0,
    active_lease_handoff_ns: u64 = 0,
    lifecycle_spec_ns: u64 = 0,
    final_publication_ns: u64 = 0,

    pub fn nsToMs(ns: u64) u64 {
        return ns / std.time.ns_per_ms;
    }
};

fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

test "snapshot preparation owns the exact cache lock and accumulated wait" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cache_root);

    var held = try rootfs.lockRootfsCacheExclusive(io, allocator, cache_root);
    var wait = Wait{};
    try std.testing.expect(try wait.tryPrepare(io, allocator, cache_root) == null);
    try std.testing.expect(wait.started_ns != null);

    held.deinit();
    var preparation = (try wait.tryPrepare(io, allocator, cache_root)) orelse return error.TestUnexpectedResult;
    defer preparation.deinit();
    _ = try preparation.registry(allocator, cache_root);
    try std.testing.expect(wait.started_ns == null);
}
