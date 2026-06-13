//! aarch64 Linux boot protocol (Documentation/arch/arm64/booting.rst).
//!
//! Parses the kernel `Image` header, places kernel and DTB in guest RAM,
//! and computes the entry point. Kernel files are host-provided (trusted
//! relative to the guest), but headers are still validated rather than
//! assumed.

const std = @import("std");

pub const Error = error{
    BadImageMagic,
    ImageTooLarge,
    RamTooSmall,
};

const image_magic: u32 = 0x644d5241; // "ARM\x64"
const header_size = 64;

pub const ImageInfo = struct {
    /// Offset from 2MiB-aligned RAM base where the image must be placed.
    text_offset: u64,
    /// Effective image size including BSS (zero in very old kernels).
    image_size: u64,
    flags: u64,
};

/// Parse and validate an arm64 `Image` header.
pub fn parseImage(kernel: []const u8) Error!ImageInfo {
    if (kernel.len < header_size) return error.BadImageMagic;
    const magic = std.mem.readInt(u32, kernel[56..60], .little);
    if (magic != image_magic) return error.BadImageMagic;
    return .{
        .text_offset = std.mem.readInt(u64, kernel[8..16], .little),
        .image_size = std.mem.readInt(u64, kernel[16..24], .little),
        .flags = std.mem.readInt(u64, kernel[24..32], .little),
    };
}

pub const Layout = struct {
    /// Guest-physical entry point (kernel image start).
    entry: u64,
    /// Guest-physical DTB address (x0 at entry).
    dtb: u64,
};

/// Place kernel and DTB into guest RAM and return the boot layout.
///
/// The kernel goes at `ram_base + text_offset`. The DTB goes near the top of
/// RAM, 2MiB aligned, which keeps it clear of the kernel image, BSS, and
/// early allocations.
pub fn load(ram: []u8, ram_base: u64, kernel: []const u8, dtb: []const u8) Error!Layout {
    const info = try parseImage(kernel);

    if (info.text_offset >= ram.len) return error.RamTooSmall;
    const kernel_room = ram.len - info.text_offset;
    const effective_size = @max(info.image_size, kernel.len);
    if (kernel.len > kernel_room or effective_size > kernel_room) return error.ImageTooLarge;

    const dtb_offset = std.mem.alignBackward(u64, ram.len - @min(ram.len, dtb.len + 0x20_0000), 0x20_0000);
    if (dtb_offset < info.text_offset + effective_size) return error.RamTooSmall;
    if (dtb_offset + dtb.len > ram.len) return error.RamTooSmall;

    @memcpy(ram[@intCast(info.text_offset)..][0..kernel.len], kernel);
    @memcpy(ram[@intCast(dtb_offset)..][0..dtb.len], dtb);

    return .{
        .entry = ram_base + info.text_offset,
        .dtb = ram_base + dtb_offset,
    };
}

// --- tests ------------------------------------------------------------------

fn makeImage(allocator: std.mem.Allocator, text_offset: u64, image_size: u64, payload_len: usize) ![]u8 {
    const img = try allocator.alloc(u8, header_size + payload_len);
    @memset(img, 0xAA);
    std.mem.writeInt(u64, img[8..16], text_offset, .little);
    std.mem.writeInt(u64, img[16..24], image_size, .little);
    std.mem.writeInt(u64, img[24..32], 0, .little);
    std.mem.writeInt(u32, img[56..60], image_magic, .little);
    return img;
}

test "parse rejects bad magic and short files" {
    try std.testing.expectError(error.BadImageMagic, parseImage("short"));
    var junk = [_]u8{0} ** 128;
    try std.testing.expectError(error.BadImageMagic, parseImage(&junk));
}

test "load places kernel at text_offset and dtb high and aligned" {
    const allocator = std.testing.allocator;
    const img = try makeImage(allocator, 0x80000, 0x100000, 1024);
    defer allocator.free(img);

    const ram = try allocator.alloc(u8, 64 * 1024 * 1024);
    defer allocator.free(ram);
    @memset(ram, 0);

    const dtb = "not a real dtb";
    const layout = try load(ram, 0x8000_0000, img, dtb);

    try std.testing.expectEqual(@as(u64, 0x8000_0000 + 0x80000), layout.entry);
    try std.testing.expect(layout.dtb % 0x20_0000 == 0);
    try std.testing.expect(layout.dtb > layout.entry + 0x100000);
    try std.testing.expectEqualSlices(u8, img, ram[0x80000 .. 0x80000 + img.len]);
    const dtb_off: usize = @intCast(layout.dtb - 0x8000_0000);
    try std.testing.expectEqualStrings(dtb, ram[dtb_off .. dtb_off + dtb.len]);
}

test "load rejects kernels that do not fit" {
    const allocator = std.testing.allocator;
    const img = try makeImage(allocator, 0, 32 * 1024 * 1024, 1024);
    defer allocator.free(img);
    const ram = try allocator.alloc(u8, 16 * 1024 * 1024);
    defer allocator.free(ram);
    try std.testing.expectError(error.ImageTooLarge, load(ram, 0x8000_0000, img, "dtb"));
}
