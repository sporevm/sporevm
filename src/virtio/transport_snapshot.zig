//! Backend-neutral validation for virtio transport state entering a portable
//! machine snapshot.

const std = @import("std");
const blk = @import("blk.zig");
const mmio = @import("mmio.zig");

pub fn validateFullSnapshotTransports(transports: []const mmio.Transport) !void {
    // Rootfs-only checkpoints capture queue state transiently for quiescence,
    // but a portable machine manifest must never contain the growth profile.
    for (transports) |*transport| {
        try transport.validateSerializableFeatureState();
        if (transport.offeredFeatures() & blk.feature_write_zeroes != 0) {
            return error.NonResumableDeviceProfile;
        }
    }
}

test "full snapshots reject growth-only transport features" {
    var portable_storage: [blk.sector_size]u8 = undefined;
    var portable_blk = blk.Blk.initWithOptions(.{ .memory = &portable_storage }, .{});
    var portable_transports = [_]mmio.Transport{mmio.Transport.init(portable_blk.device())};
    try validateFullSnapshotTransports(&portable_transports);
    portable_transports[0].driver_features = 1 << 15;
    try std.testing.expectError(
        error.UnsupportedFeatures,
        validateFullSnapshotTransports(&portable_transports),
    );

    var growth_storage: [blk.sector_size]u8 = undefined;
    var growth_blk = blk.Blk.initWithOptions(.{ .memory = &growth_storage }, .{ .write_zeroes = true });
    var growth_transports = [_]mmio.Transport{mmio.Transport.init(growth_blk.device())};
    try std.testing.expectError(
        error.NonResumableDeviceProfile,
        validateFullSnapshotTransports(&growth_transports),
    );
}
