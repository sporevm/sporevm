//! The SporeVM board: memory map and device tree.
//!
//! One fixed, versioned guest platform shared by every hypervisor backend.
//! The DTB generated here is part of the portability contract: KVM and HVF
//! guests must see the same topology or spores cannot move between them.
//! Changes here are platform contract changes (see docs/spore-format.md).

const std = @import("std");
const fdt = @import("fdt.zig");

/// Device model version recorded in spore manifests.
pub const device_model_version = 1;

pub const ram_base: u64 = 0x8000_0000;
/// Outside the GIC's reserved redistributor region (which can span tens of
/// MB above the distributor at 0x0800_0000 on HVF).
pub const virtio_base: u64 = 0x0c00_0000;
pub const virtio_stride: u64 = 0x200;
/// First SPI number used for virtio devices (GIC intid = 32 + SPI).
pub const virtio_first_spi: u32 = 16;
pub const max_virtio_devices = 8;

pub const spi_base_intid: u32 = 32;

pub const GicLayout = struct {
    distributor_base: u64,
    distributor_size: u64,
    redistributor_base: u64,
    redistributor_size: u64,
};

pub const Config = struct {
    ram_size: u64,
    cpu_count: u32,
    gic: GicLayout,
    virtio_count: u32,
    bootargs: []const u8,
};

pub fn virtioDeviceBase(index: u32) u64 {
    return virtio_base + virtio_stride * @as(u64, index);
}

pub fn virtioDeviceSpi(index: u32) u32 {
    return virtio_first_spi + index;
}

pub fn virtioDeviceIntid(index: u32) u32 {
    return spi_base_intid + virtioDeviceSpi(index);
}

/// Build the boot DTB. Caller owns the returned blob.
pub fn buildDtb(allocator: std.mem.Allocator, config: Config) ![]u8 {
    std.debug.assert(config.virtio_count <= max_virtio_devices);

    var f = fdt.Fdt.init(allocator);
    defer f.deinit();

    const gic_phandle = f.allocPhandle();

    try f.beginNode("");
    try f.propU32("#address-cells", 2);
    try f.propU32("#size-cells", 2);
    try f.propString("compatible", "sporevm,board-v0");
    try f.propU32("interrupt-parent", gic_phandle);

    {
        try f.beginNode("cpus");
        try f.propU32("#address-cells", 1);
        try f.propU32("#size-cells", 0);
        var i: u32 = 0;
        while (i < config.cpu_count) : (i += 1) {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "cpu@{d}", .{i});
            try f.beginNode(name);
            try f.propString("device_type", "cpu");
            try f.propString("compatible", "arm,armv8");
            try f.propU32("reg", i);
            try f.propString("enable-method", "psci");
            try f.endNode();
        }
        try f.endNode();
    }

    {
        try f.beginNode("psci");
        try f.propStringList("compatible", &.{ "arm,psci-1.0", "arm,psci-0.2" });
        try f.propString("method", "hvc");
        try f.endNode();
    }

    {
        var name_buf: [48]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "memory@{x}", .{ram_base});
        try f.beginNode(name);
        try f.propString("device_type", "memory");
        try f.propU32Array("reg", &.{
            @truncate(ram_base >> 32),        @truncate(ram_base),
            @truncate(config.ram_size >> 32), @truncate(config.ram_size),
        });
        try f.endNode();
    }

    {
        var name_buf: [48]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "intc@{x}", .{config.gic.distributor_base});
        try f.beginNode(name);
        try f.propString("compatible", "arm,gic-v3");
        try f.propU32("#interrupt-cells", 3);
        try f.propEmpty("interrupt-controller");
        try f.propU32Array("reg", &.{
            @truncate(config.gic.distributor_base >> 32),   @truncate(config.gic.distributor_base),
            @truncate(config.gic.distributor_size >> 32),   @truncate(config.gic.distributor_size),
            @truncate(config.gic.redistributor_base >> 32), @truncate(config.gic.redistributor_base),
            @truncate(config.gic.redistributor_size >> 32), @truncate(config.gic.redistributor_size),
        });
        try f.propU32("phandle", gic_phandle);
        try f.endNode();
    }

    {
        try f.beginNode("timer");
        try f.propString("compatible", "arm,armv8-timer");
        // Secure phys, non-secure phys, virt, hyp PPIs; level triggered.
        try f.propU32Array("interrupts", &.{
            1, 13, 4,
            1, 14, 4,
            1, 11, 4,
            1, 10, 4,
        });
        try f.endNode();
    }

    {
        var i: u32 = 0;
        while (i < config.virtio_count) : (i += 1) {
            const base = virtioDeviceBase(i);
            var name_buf: [48]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "virtio_mmio@{x}", .{base});
            try f.beginNode(name);
            try f.propString("compatible", "virtio,mmio");
            try f.propU32Array("reg", &.{
                @truncate(base >> 32),          @truncate(base),
                @truncate(virtio_stride >> 32), @truncate(virtio_stride),
            });
            // SPI, edge rising.
            try f.propU32Array("interrupts", &.{ 0, virtioDeviceSpi(i), 1 });
            try f.propEmpty("dma-coherent");
            try f.endNode();
        }
    }

    {
        try f.beginNode("chosen");
        try f.propString("bootargs", config.bootargs);
        try f.endNode();
    }

    try f.endNode();
    return f.finish();
}

test "dtb builds and addresses are consistent" {
    const blob = try buildDtb(std.testing.allocator, .{
        .ram_size = 512 * 1024 * 1024,
        .cpu_count = 1,
        .gic = .{
            .distributor_base = 0x0800_0000,
            .distributor_size = 0x1_0000,
            .redistributor_base = 0x0802_0000,
            .redistributor_size = 0x2_0000,
        },
        .virtio_count = 1,
        .bootargs = "console=hvc0",
    });
    defer std.testing.allocator.free(blob);
    try std.testing.expect(blob.len > 256);
    // Spot-check: bootargs string and compatible strings made it in.
    try std.testing.expect(std.mem.indexOf(u8, blob, "console=hvc0") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob, "arm,gic-v3") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob, "virtio,mmio") != null);
}

test "virtio addressing helpers" {
    try std.testing.expectEqual(virtio_base, virtioDeviceBase(0));
    try std.testing.expectEqual(virtio_base + virtio_stride, virtioDeviceBase(1));
    try std.testing.expectEqual(@as(u32, 48), virtioDeviceIntid(0));
}
