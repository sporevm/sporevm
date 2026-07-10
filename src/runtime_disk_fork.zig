//! Private same-version runtime disk-head descriptor.
//!
//! The descriptor is never a spore manifest value. It binds one transferred
//! writable overlay fd to the immutable baseline recorded by a child monitor's
//! lifecycle spec, then carries only the physical-overlay and logical-zero
//! overrides needed to reconstruct the live one-level chunk map.

const std = @import("std");
const builtin = @import("builtin");
const fd_util = @import("fd.zig");
const spore = @import("spore.zig");

pub const max_descriptor_bytes: usize = 2 * 1024 * 1024;
pub const max_baseline_identity_bytes: usize = 128;
pub const header_len: usize = 48;
pub const magic = "SPDFORK1";
pub const version: u16 = 1;

pub const Error = error{
    BadDescriptor,
    BadOverlay,
    DescriptorTooLarge,
    IoFailed,
    OutOfMemory,
};

pub const BaselineKind = enum(u8) {
    rootfs = 1,
    disk_index = 2,

    fn parse(raw: u8) ?BaselineKind {
        return std.enums.fromInt(BaselineKind, raw);
    }
};

pub const CloneMethod = enum(u8) {
    reflink = 1,
    copy = 2,

    fn parse(raw: u8) ?CloneMethod {
        return std.enums.fromInt(CloneMethod, raw);
    }
};

pub const Baseline = struct {
    kind: BaselineKind,
    identity: []const u8,
};

pub const Descriptor = struct {
    allocator: std.mem.Allocator,
    baseline: Baseline,
    clone_method: CloneMethod,
    logical_size: u64,
    chunk_size: u64,
    chunk_count: u64,
    overlay_chunks: []u8,
    zero_chunks: []u8,

    pub fn deinit(self: *Descriptor) void {
        self.allocator.free(self.baseline.identity);
        self.allocator.free(self.overlay_chunks);
        self.allocator.free(self.zero_chunks);
        self.* = undefined;
    }

    pub fn encodeAlloc(self: Descriptor, allocator: std.mem.Allocator) Error![]u8 {
        const total_len = try self.encodedLen();
        const out = try allocator.alloc(u8, total_len);
        @memset(out, 0);
        @memcpy(out[0..magic.len], magic);
        std.mem.writeInt(u16, out[8..10], version, .little);
        out[10] = @intFromEnum(self.baseline.kind);
        out[11] = @intFromEnum(self.clone_method);
        std.mem.writeInt(u64, out[16..24], self.logical_size, .little);
        std.mem.writeInt(u64, out[24..32], self.chunk_size, .little);
        std.mem.writeInt(u64, out[32..40], self.chunk_count, .little);
        std.mem.writeInt(u16, out[40..42], @intCast(self.baseline.identity.len), .little);
        std.mem.writeInt(u32, out[44..48], @intCast(self.overlay_chunks.len), .little);

        var offset = header_len;
        @memcpy(out[offset..][0..self.baseline.identity.len], self.baseline.identity);
        offset += self.baseline.identity.len;
        @memcpy(out[offset..][0..self.overlay_chunks.len], self.overlay_chunks);
        offset += self.overlay_chunks.len;
        @memcpy(out[offset..][0..self.zero_chunks.len], self.zero_chunks);
        return out;
    }

    pub fn encodedLen(self: Descriptor) Error!usize {
        try validateFields(self);
        const bitmap_bytes = std.math.mul(usize, self.overlay_chunks.len, 2) catch return error.DescriptorTooLarge;
        const payload_len = std.math.add(usize, self.baseline.identity.len, bitmap_bytes) catch return error.DescriptorTooLarge;
        const total_len = std.math.add(usize, header_len, payload_len) catch return error.DescriptorTooLarge;
        if (total_len > max_descriptor_bytes) return error.DescriptorTooLarge;
        return total_len;
    }

    pub fn validate(self: Descriptor) Error!void {
        try validateFields(self);
    }

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) Error!Descriptor {
        if (bytes.len < header_len) return error.BadDescriptor;
        if (bytes.len > max_descriptor_bytes) return error.DescriptorTooLarge;
        if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.BadDescriptor;
        if (std.mem.readInt(u16, bytes[8..10], .little) != version) return error.BadDescriptor;
        if (!std.mem.allEqual(u8, bytes[12..16], 0) or !std.mem.allEqual(u8, bytes[42..44], 0)) return error.BadDescriptor;

        const kind = BaselineKind.parse(bytes[10]) orelse return error.BadDescriptor;
        const clone_method = CloneMethod.parse(bytes[11]) orelse return error.BadDescriptor;
        const logical_size = std.mem.readInt(u64, bytes[16..24], .little);
        const chunk_size = std.mem.readInt(u64, bytes[24..32], .little);
        const chunk_count = std.mem.readInt(u64, bytes[32..40], .little);
        const identity_len: usize = std.mem.readInt(u16, bytes[40..42], .little);
        const bitmap_len: usize = std.mem.readInt(u32, bytes[44..48], .little);
        if (identity_len == 0 or identity_len > max_baseline_identity_bytes) return error.BadDescriptor;
        const bitmap_bytes = std.math.mul(usize, bitmap_len, 2) catch return error.DescriptorTooLarge;
        const payload_len = std.math.add(usize, identity_len, bitmap_bytes) catch return error.DescriptorTooLarge;
        const expected_len = std.math.add(usize, header_len, payload_len) catch return error.DescriptorTooLarge;
        if (expected_len != bytes.len) return error.BadDescriptor;

        var offset = header_len;
        const identity_bytes = bytes[offset..][0..identity_len];
        offset += identity_len;
        const overlay_bytes = bytes[offset..][0..bitmap_len];
        offset += bitmap_len;
        const zero_bytes = bytes[offset..][0..bitmap_len];

        const identity = try allocator.dupe(u8, identity_bytes);
        errdefer allocator.free(identity);
        const overlay_map = try allocator.dupe(u8, overlay_bytes);
        errdefer allocator.free(overlay_map);
        const zero_map = try allocator.dupe(u8, zero_bytes);
        errdefer allocator.free(zero_map);
        var descriptor = Descriptor{
            .allocator = allocator,
            .baseline = .{ .kind = kind, .identity = identity },
            .clone_method = clone_method,
            .logical_size = logical_size,
            .chunk_size = chunk_size,
            .chunk_count = chunk_count,
            .overlay_chunks = overlay_map,
            .zero_chunks = zero_map,
        };
        errdefer descriptor.deinit();
        try validateFields(descriptor);
        return descriptor;
    }

    pub fn overlay(self: Descriptor, chunk_index: usize) bool {
        return bitmapContains(self.overlay_chunks, chunk_index);
    }

    pub fn zero(self: Descriptor, chunk_index: usize) bool {
        return bitmapContains(self.zero_chunks, chunk_index);
    }
};

pub const Head = struct {
    descriptor: Descriptor,
    overlay_fd: std.c.fd_t,
    stats: HeadStats = .{},

    pub fn deinit(self: *Head) void {
        if (self.overlay_fd >= 0) _ = std.c.close(self.overlay_fd);
        self.descriptor.deinit();
        self.* = undefined;
    }

};

pub const HeadStats = struct {
    prepare_ns: u64 = 0,
    copied_bytes: u64 = 0,
};

/// Validates an already-open overlay before transferring it into a runtime.
/// `FD_CLOEXEC` is set before inspecting any other property so a rejected fd
/// cannot leak through a concurrent exec.
pub fn validateOverlayFd(fd: std.c.fd_t, logical_size: u64) Error!void {
    if (fd < 0) return error.BadOverlay;
    try fd_util.setCloseOnExec(fd);

    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var stat: linux.Statx = undefined;
        const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{
            .TYPE = true,
            .MODE = true,
            .NLINK = true,
            .SIZE = true,
        }, &stat);
        if (linux.errno(rc) != .SUCCESS) return error.IoFailed;
        if (!linux.S.ISREG(stat.mode) or stat.nlink != 0 or stat.size != logical_size) return error.BadOverlay;
    } else {
        var stat: std.c.Stat = undefined;
        if (std.c.fstat(fd, &stat) != 0) return error.IoFailed;
        if (!std.c.S.ISREG(stat.mode) or stat.nlink != 0 or stat.size < 0 or @as(u64, @intCast(stat.size)) != logical_size) return error.BadOverlay;
    }

    const raw_status_flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    if (raw_status_flags < 0) return error.IoFailed;
    const status_flags: std.c.O = @bitCast(@as(u32, @intCast(raw_status_flags)));
    if (status_flags.ACCMODE != .RDWR or status_flags.APPEND) return error.BadOverlay;
}

pub fn bitmapLen(chunk_count: u64) Error!usize {
    const bytes = std.math.divCeil(u64, chunk_count, 8) catch return error.BadDescriptor;
    return std.math.cast(usize, bytes) orelse error.DescriptorTooLarge;
}

pub fn bitmapSet(bitmap: []u8, chunk_index: usize) void {
    bitmap[chunk_index / 8] |= @as(u8, 1) << @intCast(chunk_index % 8);
}

pub fn bitmapContains(bitmap: []const u8, chunk_index: usize) bool {
    return (bitmap[chunk_index / 8] & (@as(u8, 1) << @intCast(chunk_index % 8))) != 0;
}

fn validateFields(descriptor: Descriptor) Error!void {
    if (descriptor.logical_size == 0 or descriptor.chunk_size != spore.disk_chunk_size) return error.BadDescriptor;
    const expected_chunks = std.math.divCeil(u64, descriptor.logical_size, descriptor.chunk_size) catch return error.BadDescriptor;
    if (descriptor.chunk_count != expected_chunks) return error.BadDescriptor;
    const expected_bitmap_len = try bitmapLen(descriptor.chunk_count);
    if (descriptor.overlay_chunks.len != expected_bitmap_len or descriptor.zero_chunks.len != expected_bitmap_len) return error.BadDescriptor;
    if (descriptor.baseline.identity.len == 0 or descriptor.baseline.identity.len > max_baseline_identity_bytes) return error.BadDescriptor;
    spore.validateDiskDigest(descriptor.baseline.identity) catch return error.BadDescriptor;
    for (descriptor.overlay_chunks, descriptor.zero_chunks) |overlay, zero| {
        if ((overlay & zero) != 0) return error.BadDescriptor;
    }
    if (descriptor.chunk_count % 8 != 0) {
        const used: u3 = @intCast(descriptor.chunk_count % 8);
        const padding_mask: u8 = ~((@as(u8, 1) << used) - 1);
        if ((descriptor.overlay_chunks[expected_bitmap_len - 1] & padding_mask) != 0) return error.BadDescriptor;
        if ((descriptor.zero_chunks[expected_bitmap_len - 1] & padding_mask) != 0) return error.BadDescriptor;
    }
}

const test_identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn testDescriptor(allocator: std.mem.Allocator) !Descriptor {
    const overlay = try allocator.alloc(u8, 1);
    errdefer allocator.free(overlay);
    const zero = try allocator.alloc(u8, 1);
    errdefer allocator.free(zero);
    @memset(overlay, 0);
    @memset(zero, 0);
    bitmapSet(overlay, 0);
    bitmapSet(zero, 1);
    return .{
        .allocator = allocator,
        .baseline = .{ .kind = .rootfs, .identity = try allocator.dupe(u8, test_identity) },
        .clone_method = .reflink,
        .logical_size = 2 * spore.disk_chunk_size,
        .chunk_size = spore.disk_chunk_size,
        .chunk_count = 2,
        .overlay_chunks = overlay,
        .zero_chunks = zero,
    };
}

test "runtime disk fork descriptor round trips canonically" {
    var descriptor = try testDescriptor(std.testing.allocator);
    defer descriptor.deinit();
    const encoded = try descriptor.encodeAlloc(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    var parsed = try Descriptor.parse(std.testing.allocator, encoded);
    defer parsed.deinit();
    try std.testing.expectEqual(descriptor.baseline.kind, parsed.baseline.kind);
    try std.testing.expectEqual(descriptor.clone_method, parsed.clone_method);
    try std.testing.expectEqualStrings(descriptor.baseline.identity, parsed.baseline.identity);
    try std.testing.expect(parsed.overlay(0));
    try std.testing.expect(parsed.zero(1));

    const reencoded = try parsed.encodeAlloc(std.testing.allocator);
    defer std.testing.allocator.free(reencoded);
    try std.testing.expectEqualSlices(u8, encoded, reencoded);
}

test "runtime disk fork descriptor rejects overlapping and padded maps" {
    var descriptor = try testDescriptor(std.testing.allocator);
    defer descriptor.deinit();
    descriptor.zero_chunks[0] |= 1;
    try std.testing.expectError(error.BadDescriptor, descriptor.encodeAlloc(std.testing.allocator));
    descriptor.zero_chunks[0] &= ~@as(u8, 1);
    descriptor.overlay_chunks[0] |= 0x80;
    try std.testing.expectError(error.BadDescriptor, descriptor.encodeAlloc(std.testing.allocator));
}

test "runtime disk fork descriptor rejects truncation and trailing bytes" {
    var descriptor = try testDescriptor(std.testing.allocator);
    defer descriptor.deinit();
    const encoded = try descriptor.encodeAlloc(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(error.BadDescriptor, Descriptor.parse(std.testing.allocator, encoded[0 .. encoded.len - 1]));
    const extended = try std.testing.allocator.alloc(u8, encoded.len + 1);
    defer std.testing.allocator.free(extended);
    @memcpy(extended[0..encoded.len], encoded);
    extended[encoded.len] = 0;
    try std.testing.expectError(error.BadDescriptor, Descriptor.parse(std.testing.allocator, extended));
}

test "runtime disk fork descriptor rejects unknown header values and oversize input" {
    var descriptor = try testDescriptor(std.testing.allocator);
    defer descriptor.deinit();
    const encoded = try descriptor.encodeAlloc(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    const mutated = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(mutated);

    mutated[8] = 2;
    try std.testing.expectError(error.BadDescriptor, Descriptor.parse(std.testing.allocator, mutated));
    mutated[8] = encoded[8];
    mutated[10] = 0xff;
    try std.testing.expectError(error.BadDescriptor, Descriptor.parse(std.testing.allocator, mutated));
    mutated[10] = encoded[10];
    mutated[11] = 0xff;
    try std.testing.expectError(error.BadDescriptor, Descriptor.parse(std.testing.allocator, mutated));
    mutated[11] = encoded[11];
    mutated[12] = 1;
    try std.testing.expectError(error.BadDescriptor, Descriptor.parse(std.testing.allocator, mutated));

    const oversized = try std.testing.allocator.alloc(u8, max_descriptor_bytes + 1);
    defer std.testing.allocator.free(oversized);
    try std.testing.expectError(error.DescriptorTooLarge, Descriptor.parse(std.testing.allocator, oversized));
}

test "runtime disk fork validates overlay fd shape and flags" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var writable = try tmp.dir.createFile(io, "overlay", .{ .read = true });
    defer writable.close(io);
    try std.testing.expectError(error.BadOverlay, validateOverlayFd(writable.handle, spore.disk_chunk_size));
    if (std.c.ftruncate(writable.handle, spore.disk_chunk_size) != 0) return error.IoFailed;
    try std.testing.expectError(error.BadOverlay, validateOverlayFd(writable.handle, spore.disk_chunk_size));
    try tmp.dir.deleteFile(io, "overlay");
    try validateOverlayFd(writable.handle, spore.disk_chunk_size);
    const descriptor_flags = std.c.fcntl(writable.handle, std.c.F.GETFD, @as(c_int, 0));
    try std.testing.expect(descriptor_flags >= 0);
    try std.testing.expect((descriptor_flags & std.c.FD_CLOEXEC) != 0);

    const status_flags = std.c.fcntl(writable.handle, std.c.F.GETFL, @as(c_int, 0));
    try std.testing.expect(status_flags >= 0);
    if (std.c.fcntl(writable.handle, std.c.F.SETFL, status_flags | (@as(c_int, 1) << @bitOffsetOf(std.c.O, "APPEND"))) != 0) return error.IoFailed;
    try std.testing.expectError(error.BadOverlay, validateOverlayFd(writable.handle, spore.disk_chunk_size));

    var read_only_source = try tmp.dir.createFile(io, "read-only", .{ .read = true });
    if (std.c.ftruncate(read_only_source.handle, spore.disk_chunk_size) != 0) return error.IoFailed;
    read_only_source.close(io);
    var read_only = try tmp.dir.openFile(io, "read-only", .{});
    defer read_only.close(io);
    try tmp.dir.deleteFile(io, "read-only");
    try std.testing.expectError(error.BadOverlay, validateOverlayFd(read_only.handle, spore.disk_chunk_size));
}

fn fuzzDescriptor(_: void, smith: *std.testing.Smith) anyerror!void {
    var bytes: [64 * 1024]u8 = undefined;
    const len = smith.slice(&bytes);
    var descriptor = Descriptor.parse(std.testing.allocator, bytes[0..len]) catch return;
    defer descriptor.deinit();
    const encoded = try descriptor.encodeAlloc(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    var reparsed = try Descriptor.parse(std.testing.allocator, encoded);
    defer reparsed.deinit();
}

test "fuzz runtime disk fork descriptor parser" {
    try std.testing.fuzz({}, fuzzDescriptor, .{});
}
