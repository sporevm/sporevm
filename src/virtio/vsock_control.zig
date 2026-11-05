//! Interface between the VMM run loop and the host-side controller of the
//! guest (named monitor, `spore run`, `spore build`). The loop polls the
//! controller for the next action, such as a snapshot or a stop, and reports
//! completion and runtime stats back.

const std = @import("std");
const image_store = @import("../image_store.zig");
const runtime_disk_fork_capture = @import("../runtime_disk_fork_capture.zig");
const snapshot_publication = @import("../snapshot_publication.zig");
const spore = @import("../spore.zig");
const vsock = @import("vsock.zig");

pub const ControlAction = union(enum) {
    keep_running,
    stop,
    snapshot: SnapshotAction,
    rootfs_snapshot: RootfsSnapshotAction,
    disk_fork: DiskForkAction,
};

pub const SnapshotAction = struct {
    dir: []const u8,
    publish_dir: ?[]const u8 = null,
    continue_after: bool = false,
};

pub const RootfsSnapshotAction = struct {
    dir: []const u8,
};

pub const DiskForkAction = struct {
    dir: []const u8,
    count: u8,
    allow_copy: bool = false,
    force_copy: bool = false,
};

pub const ControlStats = struct {
    chunks_nonzero: ?u64 = null,
    dirty_chunks_pending: ?u64 = null,
};

pub const Wake = struct {
    context: *anyopaque,
    wakeFn: *const fn (context: *anyopaque) void,

    pub fn wake(self: Wake) void {
        self.wakeFn(self.context);
    }
};

pub const Control = struct {
    context: *anyopaque,
    pollFn: *const fn (context: *anyopaque, dev: *vsock.Vsock) anyerror!ControlAction,
    setWakeFn: *const fn (context: *anyopaque, wake: Wake) void,
    prepareSnapshotFn: ?*const fn (context: *anyopaque) anyerror!?snapshot_publication.SnapshotPreparation = null,
    publishSnapshotFn: ?*const fn (context: *anyopaque, preparation: *const snapshot_publication.SnapshotPreparation, work_dir: []const u8, publish_dir: []const u8) anyerror!SnapshotPublishMetrics = null,
    completeSnapshotFn: *const fn (context: *anyopaque, dir: []const u8) anyerror!void,
    completeRootfsSnapshotFn: *const fn (context: *anyopaque, disk: ?spore.Disk) anyerror!void,
    completeDiskForkFn: ?*const fn (context: *anyopaque, batch: *runtime_disk_fork_capture.Batch) anyerror!void = null,
    failDiskForkFn: ?*const fn (context: *anyopaque, err: anyerror) void = null,
    attachImageStoreFn: ?*const fn (context: *anyopaque, fetcher: *image_store.Fetcher) void = null,
    reportStatsFn: *const fn (context: *anyopaque, stats: ControlStats) void,

    pub fn poll(self: Control, dev: *vsock.Vsock) !ControlAction {
        return self.pollFn(self.context, dev);
    }

    pub fn setWake(self: Control, wake: Wake) void {
        self.setWakeFn(self.context, wake);
    }

    /// Attempts to acquire named-snapshot publication authority without
    /// blocking. A false result returns the request to pending so the VMM can
    /// run the guest before polling again.
    pub fn prepareSnapshot(self: Control) !?snapshot_publication.SnapshotPreparation {
        const prepare = self.prepareSnapshotFn orelse return error.UnsupportedSnapshot;
        return try prepare(self.context);
    }

    pub fn publishSnapshot(self: Control, preparation: *const snapshot_publication.SnapshotPreparation, work_dir: []const u8, publish_dir: []const u8) !SnapshotPublishMetrics {
        const publish = self.publishSnapshotFn orelse return error.UnsupportedSnapshot;
        return try publish(self.context, preparation, work_dir, publish_dir);
    }

    pub fn completeSnapshot(self: Control, dir: []const u8) !void {
        try self.completeSnapshotFn(self.context, dir);
    }

    pub fn completeRootfsSnapshot(self: Control, disk: ?spore.Disk) !void {
        try self.completeRootfsSnapshotFn(self.context, disk);
    }

    pub fn completeDiskFork(self: Control, batch: *runtime_disk_fork_capture.Batch) !void {
        const complete = self.completeDiskForkFn orelse return error.UnsupportedDiskFork;
        try complete(self.context, batch);
    }

    pub fn failDiskFork(self: Control, err: anyerror) void {
        const fail = self.failDiskForkFn orelse return;
        fail(self.context, err);
    }

    /// The run's root disk reads missing objects through `fetcher`. Before a
    /// snapshot request pauses the guest, the controller fetches the rest, so
    /// a store failure fails the request instead of the paused capture, which
    /// would end the run.
    pub fn attachImageStore(self: Control, fetcher: *image_store.Fetcher) void {
        const attach = self.attachImageStoreFn orelse return;
        attach(self.context, fetcher);
    }

    pub fn reportStats(self: Control, stats: ControlStats) void {
        self.reportStatsFn(self.context, stats);
    }
};

pub const SnapshotPublishMetrics = snapshot_publication.Metrics;

test "snapshot publish metrics use monotonic nanosecond units" {
    const metrics = SnapshotPublishMetrics{};
    try std.testing.expectEqual(@as(u64, 0), metrics.cache_lock_wait_ns);
    try std.testing.expectEqual(@as(u64, 17), SnapshotPublishMetrics.nsToMs(17 * std.time.ns_per_ms + 999));
}
