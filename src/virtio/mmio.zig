//! Virtio-mmio transport, device side (virtio spec 1.2 §4.2, version 2).
//!
//! Register reads/writes arrive from trapped guest MMIO accesses, so every
//! offset and value is attacker controlled. The transport owns queue
//! configuration registers; device behavior is behind the `Device`
//! interface. See SECURITY.md.

const std = @import("std");
const guestmem = @import("../guestmem.zig");
const queue = @import("queue.zig");

pub const magic: u32 = 0x74726976; // "virt"
pub const mmio_version: u32 = 2;
pub const vendor_id: u32 = 0x53504f52; // "SPOR"

/// Register window size per device (matches the DTB `reg` size).
pub const window_size: u64 = 0x200;

pub const max_queues = 4;

pub const status_features_ok: u32 = 8;
pub const status_failed: u32 = 128;

/// What the transport asks of a concrete device.
pub const Device = struct {
    context: *anyopaque,
    /// Virtio device id (console=3, net=1, blk=2, vsock=19, rng=4).
    device_id: u32,
    /// Feature bits offered to the driver (VIRTIO_F_VERSION_1 added by the
    /// transport itself).
    device_features: u64,
    queue_count: u8,
    /// Called when the driver notifies a queue. The device drains/fills the
    /// queue and returns true if a used-buffer interrupt should be raised.
    notifyFn: *const fn (context: *anyopaque, queue_index: u8, queues: *[max_queues]queue.VirtQueue, ram: guestmem.GuestRam) bool,
    /// Device config space read (offset into config space, 1/2/4 byte widths
    /// arrive as u32). Return 0 for out-of-range reads.
    configReadFn: ?*const fn (context: *anyopaque, offset: u64) u32 = null,
    /// Called once the driver feature selection is accepted, and with zero
    /// when transport reset clears that selection.
    featuresAcceptedFn: ?*const fn (context: *anyopaque, accepted_features: u64) void = null,
    /// Optional device reset hook called after transport-owned state is reset.
    resetFn: ?*const fn (context: *anyopaque) void = null,
};

pub const f_version_1: u64 = 1 << 32;

/// One virtio-mmio register window plus its queues and interrupt line.
pub const Transport = struct {
    dev: Device,
    queues: [max_queues]queue.VirtQueue = @splat(.{}),

    status: u32 = 0,
    device_features_sel: u32 = 0,
    driver_features_sel: u32 = 0,
    driver_features: u64 = 0,
    /// The immutable selection accepted at FEATURES_OK. This is reconstructed
    /// from serialized transport state during restore rather than serialized
    /// independently.
    accepted_features: ?u64 = null,
    queue_sel: u32 = 0,
    config_generation: u32 = 0,
    /// Bit 0: used buffer notification pending. Guest acks via InterruptACK.
    interrupt_status: u32 = 0,

    pub fn init(dev: Device) Transport {
        std.debug.assert(dev.queue_count <= max_queues);
        return .{ .dev = dev };
    }

    fn selectedQueue(self: *Transport) ?*queue.VirtQueue {
        if (self.queue_sel >= self.dev.queue_count) return null;
        return &self.queues[@intCast(self.queue_sel)];
    }

    pub fn offeredFeatures(self: *const Transport) u64 {
        return self.dev.device_features | f_version_1;
    }

    fn supportsFeatures(self: *const Transport, features: u64) bool {
        return features & ~self.offeredFeatures() == 0;
    }

    fn acceptFeatures(self: *Transport, features: u64) void {
        self.accepted_features = features;
        if (self.dev.featuresAcceptedFn) |f| f(self.dev.context, features);
    }

    /// Validate and apply serialized feature-negotiation state. Restore paths
    /// must use this instead of assigning `status` and `driver_features`
    /// directly so attacker-controlled state cannot enable unoffered features.
    pub fn applyRestoredFeatureState(self: *Transport, status: u32, driver_features: u64) error{UnsupportedFeatures}!void {
        if (!self.supportsFeatures(driver_features)) return error.UnsupportedFeatures;

        self.status = status;
        self.driver_features = driver_features;
        if (status & status_features_ok != 0) {
            self.acceptFeatures(driver_features);
        } else {
            if (self.accepted_features != null) {
                if (self.dev.featuresAcceptedFn) |f| f(self.dev.context, 0);
            }
            self.accepted_features = null;
        }
    }

    pub fn reset(self: *Transport) void {
        for (&self.queues) |*q| q.reset();
        self.status = 0;
        self.interrupt_status = 0;
        self.driver_features = 0;
        if (self.accepted_features != null) {
            if (self.dev.featuresAcceptedFn) |f| f(self.dev.context, 0);
        }
        self.accepted_features = null;
        self.device_features_sel = 0;
        self.driver_features_sel = 0;
        self.queue_sel = 0;
        self.config_generation = 0;
        if (self.dev.resetFn) |f| f(self.dev.context);
    }

    /// MMIO read at `offset` within the register window.
    pub fn read(self: *Transport, offset: u64) u32 {
        return switch (offset) {
            0x000 => magic,
            0x004 => mmio_version,
            0x008 => self.dev.device_id,
            0x00c => vendor_id,
            0x010 => blk: {
                const shift: u6 = if (self.device_features_sel == 1) 32 else 0;
                if (self.device_features_sel > 1) break :blk 0;
                break :blk @truncate(self.offeredFeatures() >> shift);
            },
            0x034 => queue.max_queue_size,
            0x038 => if (self.selectedQueue()) |q| q.size else 0,
            0x044 => if (self.selectedQueue()) |q| @intFromBool(q.ready) else 0,
            0x060 => self.interrupt_status,
            0x070 => self.status,
            0x0fc => self.config_generation,
            else => blk: {
                if (offset >= 0x100) {
                    if (self.dev.configReadFn) |f| break :blk f(self.dev.context, offset - 0x100);
                }
                break :blk 0;
            },
        };
    }

    /// MMIO write at `offset`. Returns true if the device raised a
    /// used-buffer interrupt (caller forwards to the interrupt controller).
    pub fn write(self: *Transport, offset: u64, value: u32, ram: guestmem.GuestRam) bool {
        switch (offset) {
            0x014 => self.device_features_sel = value,
            0x020 => {
                const shift: u6 = if (self.driver_features_sel == 1) 32 else 0;
                if (self.accepted_features == null and self.driver_features_sel <= 1) {
                    const mask = @as(u64, 0xffff_ffff) << shift;
                    self.driver_features = (self.driver_features & ~mask) | (@as(u64, value) << shift);
                }
            },
            0x024 => self.driver_features_sel = value,
            0x030 => self.queue_sel = value,
            0x038 => if (self.selectedQueue()) |q| {
                q.size = @intCast(@min(value, queue.max_queue_size));
            },
            0x044 => if (self.selectedQueue()) |q| {
                q.ready = value & 1 != 0;
            },
            0x050 => {
                // QueueNotify: value is the queue index.
                if (value < self.dev.queue_count) {
                    const q = &self.queues[@intCast(value)];
                    if (q.ready) {
                        q.validateLayout() catch return false;
                        if (self.dev.notifyFn(self.dev.context, @intCast(value), &self.queues, ram)) {
                            self.interrupt_status |= 1;
                            return true;
                        }
                    }
                }
            },
            0x064 => self.interrupt_status &= ~value,
            0x070 => {
                if (value == 0) {
                    self.reset();
                } else {
                    var next_status = value;
                    if (self.accepted_features == null and value & status_features_ok != 0) {
                        if (self.supportsFeatures(self.driver_features)) {
                            self.acceptFeatures(self.driver_features);
                        } else {
                            next_status &= ~status_features_ok;
                        }
                    }
                    // Feature selection is immutable until reset. Preserve
                    // FEATURES_OK as well as the latched mask so a hostile
                    // later status write cannot serialize state that restores
                    // with different device behavior.
                    if (self.accepted_features != null) next_status |= status_features_ok;
                    self.status = next_status;
                }
            },
            0x080 => if (self.selectedQueue()) |q| setLow(&q.desc_addr, value),
            0x084 => if (self.selectedQueue()) |q| setHigh(&q.desc_addr, value),
            0x090 => if (self.selectedQueue()) |q| setLow(&q.avail_addr, value),
            0x094 => if (self.selectedQueue()) |q| setHigh(&q.avail_addr, value),
            0x0a0 => if (self.selectedQueue()) |q| setLow(&q.used_addr, value),
            0x0a4 => if (self.selectedQueue()) |q| setHigh(&q.used_addr, value),
            else => {},
        }
        return false;
    }

    pub fn raiseConfigChange(self: *Transport) bool {
        self.config_generation +%= 1;
        self.interrupt_status |= 2;
        return true;
    }

    /// Full-machine save must not serialize a feature proposal that this
    /// device cannot restore, nor an internally inconsistent accepted state.
    /// Rootfs-only checkpoints do not serialize transport state and need not
    /// call this validation.
    pub fn validateSerializableFeatureState(self: *const Transport) !void {
        if (!self.supportsFeatures(self.driver_features)) return error.UnsupportedFeatures;
        const features_ok = self.status & status_features_ok != 0;
        if (features_ok != (self.accepted_features != null)) return error.BadFeatureState;
        if (self.accepted_features) |accepted| {
            if (accepted != self.driver_features) return error.BadFeatureState;
        }
    }
};

fn setLow(target: *u64, value: u32) void {
    target.* = (target.* & 0xffff_ffff_0000_0000) | value;
}

fn setHigh(target: *u64, value: u32) void {
    target.* = (target.* & 0x0000_0000_ffff_ffff) | (@as(u64, value) << 32);
}

// --- tests ------------------------------------------------------------------

const TestDev = struct {
    notified: ?u8 = null,

    fn notify(ctx: *anyopaque, qi: u8, queues: *[max_queues]queue.VirtQueue, ram: guestmem.GuestRam) bool {
        _ = queues;
        _ = ram;
        const self: *TestDev = @ptrCast(@alignCast(ctx));
        self.notified = qi;
        return true;
    }

    fn dev(self: *TestDev) Device {
        return .{
            .context = self,
            .device_id = 3,
            .device_features = 0,
            .queue_count = 2,
            .notifyFn = notify,
        };
    }
};

const test_device_feature: u64 = 1 << 14;

const FeatureDev = struct {
    accepted_features: ?u64 = null,
    acceptance_count: u32 = 0,

    fn notify(_: *anyopaque, _: u8, _: *[max_queues]queue.VirtQueue, _: guestmem.GuestRam) bool {
        return false;
    }

    fn featuresAccepted(ctx: *anyopaque, features: u64) void {
        const self: *FeatureDev = @ptrCast(@alignCast(ctx));
        self.accepted_features = features;
        self.acceptance_count += 1;
    }

    fn dev(self: *FeatureDev) Device {
        return .{
            .context = self,
            .device_id = 2,
            .device_features = test_device_feature,
            .queue_count = 1,
            .notifyFn = notify,
            .featuresAcceptedFn = featuresAccepted,
        };
    }
};

fn testRam(buf: []u8) guestmem.GuestRam {
    return .{ .bytes = buf, .base = 0 };
}

test "identity registers" {
    var td = TestDev{};
    var t = Transport.init(td.dev());
    try std.testing.expectEqual(magic, t.read(0x000));
    try std.testing.expectEqual(mmio_version, t.read(0x004));
    try std.testing.expectEqual(@as(u32, 3), t.read(0x008));
}

test "feature negotiation exposes VERSION_1 in the high word" {
    var td = TestDev{};
    var t = Transport.init(td.dev());
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 0), t.read(0x010));
    _ = t.write(0x014, 1, testRam(&buf));
    try std.testing.expectEqual(@as(u32, 1), t.read(0x010)); // bit 32 -> bit 0 of word 1
    // Hostile selector value reads as zero features.
    _ = t.write(0x014, 7, testRam(&buf));
    try std.testing.expectEqual(@as(u32, 0), t.read(0x010));
}

test "FEATURES_OK accepts offered features and freezes the selection until reset" {
    var fd = FeatureDev{};
    var t = Transport.init(fd.dev());
    var buf: [16]u8 = undefined;
    const ram = testRam(&buf);
    const selected = test_device_feature | f_version_1;

    try std.testing.expectEqual(selected, t.offeredFeatures());
    _ = t.write(0x024, 0, ram);
    _ = t.write(0x020, @truncate(test_device_feature), ram);
    _ = t.write(0x024, 1, ram);
    _ = t.write(0x020, @truncate(f_version_1 >> 32), ram);
    _ = t.write(0x070, 1 | 2 | status_features_ok, ram);

    try std.testing.expectEqual(@as(u32, 1 | 2 | status_features_ok), t.read(0x070));
    try std.testing.expectEqual(selected, t.driver_features);
    try std.testing.expectEqual(selected, t.accepted_features.?);
    try std.testing.expectEqual(selected, fd.accepted_features.?);
    try std.testing.expectEqual(@as(u32, 1), fd.acceptance_count);

    // Even a hostile status rewrite cannot unfreeze the accepted selection.
    _ = t.write(0x070, 1 | 2, ram);
    try std.testing.expectEqual(@as(u32, 1 | 2 | status_features_ok), t.read(0x070));
    _ = t.write(0x024, 0, ram);
    _ = t.write(0x020, 0, ram);
    try std.testing.expectEqual(selected, t.driver_features);
    try std.testing.expectEqual(selected, t.accepted_features.?);
    try std.testing.expectEqual(@as(u32, 1), fd.acceptance_count);

    _ = t.write(0x070, 0, ram);
    try std.testing.expectEqual(@as(?u64, null), t.accepted_features);
    try std.testing.expectEqual(@as(u64, 0), t.driver_features);
    try std.testing.expectEqual(@as(u64, 0), fd.accepted_features.?);
    try std.testing.expectEqual(@as(u32, 2), fd.acceptance_count);

    // Reset re-enables feature register writes.
    _ = t.write(0x020, @truncate(test_device_feature), ram);
    try std.testing.expectEqual(test_device_feature, t.driver_features);
}

test "FEATURES_OK rejects an unoffered selection and permits renegotiation" {
    var fd = FeatureDev{};
    var t = Transport.init(fd.dev());
    var buf: [16]u8 = undefined;
    const ram = testRam(&buf);
    const unsupported_feature: u64 = 1 << 15;

    _ = t.write(0x024, 0, ram);
    _ = t.write(0x020, @truncate(unsupported_feature), ram);
    _ = t.write(0x024, 1, ram);
    _ = t.write(0x020, @truncate(f_version_1 >> 32), ram);
    _ = t.write(0x070, 1 | 2 | status_features_ok, ram);

    try std.testing.expectEqual(@as(u32, 1 | 2), t.read(0x070));
    try std.testing.expectEqual(unsupported_feature | f_version_1, t.driver_features);
    try std.testing.expectEqual(@as(?u64, null), t.accepted_features);
    try std.testing.expectEqual(@as(u32, 0), fd.acceptance_count);
    try std.testing.expectError(error.UnsupportedFeatures, t.validateSerializableFeatureState());

    _ = t.write(0x024, 0, ram);
    _ = t.write(0x020, @truncate(test_device_feature), ram);
    _ = t.write(0x070, 1 | 2 | status_features_ok, ram);
    try std.testing.expectEqual(test_device_feature | f_version_1, t.accepted_features.?);
    try std.testing.expectEqual(@as(u32, 1), fd.acceptance_count);
    try t.validateSerializableFeatureState();
}

test "restored feature state validates before applying and notifies the device" {
    var fd = FeatureDev{};
    var t = Transport.init(fd.dev());
    const unsupported_feature: u64 = 1 << 15;

    try std.testing.expectError(
        error.UnsupportedFeatures,
        t.applyRestoredFeatureState(1 | 2, unsupported_feature),
    );
    try std.testing.expectEqual(@as(u32, 0), t.status);
    try std.testing.expectEqual(@as(u64, 0), t.driver_features);
    try std.testing.expectEqual(@as(?u64, null), t.accepted_features);
    try std.testing.expectEqual(@as(u32, 0), fd.acceptance_count);

    const selected = test_device_feature | f_version_1;
    try t.applyRestoredFeatureState(1 | 2 | status_features_ok, selected);
    try std.testing.expectEqual(@as(u32, 1 | 2 | status_features_ok), t.status);
    try std.testing.expectEqual(selected, t.driver_features);
    try std.testing.expectEqual(selected, t.accepted_features.?);
    try std.testing.expectEqual(selected, fd.accepted_features.?);
    try std.testing.expectEqual(@as(u32, 1), fd.acceptance_count);
}

test "queue configuration and clamping" {
    var td = TestDev{};
    var t = Transport.init(td.dev());
    var buf: [16]u8 = undefined;
    const ram = testRam(&buf);
    _ = t.write(0x030, 0, ram); // QueueSel 0
    _ = t.write(0x038, 0x10000, ram); // hostile QueueNum
    try std.testing.expectEqual(@as(u32, queue.max_queue_size), t.read(0x038));
    _ = t.write(0x080, 0xdead0000, ram);
    _ = t.write(0x084, 0x1, ram);
    try std.testing.expectEqual(@as(u64, 0x1_dead_0000), t.queues[0].desc_addr);
    // Selecting a queue out of range is inert.
    _ = t.write(0x030, 9, ram);
    _ = t.write(0x038, 4, ram);
    try std.testing.expectEqual(@as(u32, 0), t.read(0x038));
}

test "notify routes to device and latches interrupt until ack" {
    var td = TestDev{};
    var t = Transport.init(td.dev());
    var buf: [16]u8 = undefined;
    const ram = testRam(&buf);
    _ = t.write(0x030, 1, ram);
    _ = t.write(0x038, 8, ram);
    _ = t.write(0x044, 1, ram); // ready
    const raised = t.write(0x050, 1, ram);
    try std.testing.expect(raised);
    try std.testing.expectEqual(@as(u8, 1), td.notified.?);
    try std.testing.expectEqual(@as(u32, 1), t.read(0x060));
    _ = t.write(0x064, 1, ram); // ack
    try std.testing.expectEqual(@as(u32, 0), t.read(0x060));
    // Notify for a non-ready or out-of-range queue is inert.
    td.notified = null;
    try std.testing.expect(!t.write(0x050, 0, ram));
    try std.testing.expect(!t.write(0x050, 99, ram));
    try std.testing.expectEqual(@as(?u8, null), td.notified);
}

test "notify ignores queues with overflowing ring addresses" {
    var td = TestDev{};
    var t = Transport.init(td.dev());
    var buf: [16]u8 = undefined;
    const ram = testRam(&buf);

    _ = t.write(0x030, 1, ram);
    _ = t.write(0x038, 8, ram);
    _ = t.write(0x080, std.math.maxInt(u32), ram);
    _ = t.write(0x084, std.math.maxInt(u32), ram);
    _ = t.write(0x044, 1, ram);
    try std.testing.expect(!t.write(0x050, 1, ram));
    try std.testing.expectEqual(@as(?u8, null), td.notified);
}

test "config change latches interrupt and bumps generation" {
    var td = TestDev{};
    var t = Transport.init(td.dev());
    try std.testing.expect(t.raiseConfigChange());
    try std.testing.expectEqual(@as(u32, 1), t.read(0x0fc));
    try std.testing.expectEqual(@as(u32, 2), t.read(0x060));
    var buf: [16]u8 = undefined;
    _ = t.write(0x064, 2, testRam(&buf));
    try std.testing.expectEqual(@as(u32, 0), t.read(0x060));
}

test "status write of zero resets transport state" {
    var td = TestDev{};
    var t = Transport.init(td.dev());
    var buf: [16]u8 = undefined;
    const ram = testRam(&buf);
    _ = t.write(0x070, 0xf, ram);
    _ = t.write(0x030, 0, ram);
    _ = t.write(0x038, 8, ram);
    _ = t.write(0x044, 1, ram);
    _ = t.write(0x070, 0, ram);
    try std.testing.expectEqual(@as(u32, 0), t.read(0x070));
    try std.testing.expect(!t.queues[0].ready);
    try std.testing.expectEqual(@as(u16, 0), t.queues[0].size);
}

fn fuzzMmio(_: void, s: *std.testing.Smith) !void {
    // Random register program. Must never crash regardless of order or
    // content of register accesses.
    var td = TestDev{};
    var t = Transport.init(td.dev());
    var buf: [4096]u8 = [_]u8{0} ** 4096;
    const ram = testRam(&buf);
    var ops: usize = 64;
    while (ops > 0 and !s.eos()) : (ops -= 1) {
        const off = s.valueRangeLessThan(u32, 0, 0x240);
        const val = s.value(u32);
        if (s.boolWeighted(1, 1)) {
            _ = t.write(off, val, ram);
        } else {
            _ = t.read(off);
        }
    }
}

test "fuzz mmio register interface" {
    try std.testing.fuzz({}, fuzzMmio, .{});
}
