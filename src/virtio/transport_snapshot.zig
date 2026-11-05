//! Backend-neutral validation for virtio device state entering a portable
//! machine snapshot.

const std = @import("std");
const blk = @import("blk.zig");
const mmio = @import("mmio.zig");
const vsock = @import("vsock.zig");

pub fn validateFullSnapshotDevices(transports: []const mmio.Transport, vsock_dev: *const vsock.Vsock) !void {
    // Rootfs-only checkpoints capture queue state transiently for quiescence,
    // but a portable machine manifest must never contain the growth profile.
    for (transports) |*transport| {
        try transport.validateSerializableFeatureState();
        if (transport.offeredFeatures() & blk.feature_write_zeroes != 0) {
            return error.NonResumableDeviceProfile;
        }
    }
    // Host-to-guest vsock packets queued outside the virtqueues are not part
    // of the manifest, so capturing now would silently drop them.
    if (vsock_dev.pending_len != 0) {
        std.log.warn("cannot snapshot while virtio-vsock has pending packets", .{});
        return error.DeviceStatePending;
    }
}

test "full snapshots reject growth-only transport features" {
    var vsock_dev = vsock.Vsock.init(.{ .guest_cid = vsock.default_guest_cid });

    var portable_storage: [blk.sector_size]u8 = undefined;
    var portable_blk = blk.Blk.initWithOptions(.{ .memory = &portable_storage }, .{});
    var portable_transports = [_]mmio.Transport{mmio.Transport.init(portable_blk.device())};
    try validateFullSnapshotDevices(&portable_transports, &vsock_dev);
    portable_transports[0].driver_features = 1 << 15;
    try std.testing.expectError(
        error.UnsupportedFeatures,
        validateFullSnapshotDevices(&portable_transports, &vsock_dev),
    );

    var growth_storage: [blk.sector_size]u8 = undefined;
    var growth_blk = blk.Blk.initWithOptions(.{ .memory = &growth_storage }, .{ .write_zeroes = true });
    var growth_transports = [_]mmio.Transport{mmio.Transport.init(growth_blk.device())};
    try std.testing.expectError(
        error.NonResumableDeviceProfile,
        validateFullSnapshotDevices(&growth_transports, &vsock_dev),
    );
}

test "full snapshots reject pending host vsock packets" {
    var vsock_dev = vsock.Vsock.init(.{ .guest_cid = vsock.default_guest_cid });
    const no_transports = [_]mmio.Transport{};
    try validateFullSnapshotDevices(&no_transports, &vsock_dev);

    // Attaching a host stream queues its connect request outside the
    // virtqueues until the guest posts receive buffers.
    var stream = try vsock.HostStream.init(10700, "{}\n");
    try vsock_dev.attachHostStream(&stream);
    try std.testing.expect(vsock_dev.pending_len != 0);
    try std.testing.expectError(
        error.DeviceStatePending,
        validateFullSnapshotDevices(&no_transports, &vsock_dev),
    );
}
