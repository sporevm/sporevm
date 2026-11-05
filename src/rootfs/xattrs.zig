const std = @import("std");

pub const security_capability_name = "security.capability";
pub const max_per_entry: usize = 4;
pub const max_value_bytes: usize = 256;
pub const max_layer_xattrs: u64 = 1_000_000;
pub const max_layer_value_bytes: u64 = 64 << 20;

pub const Attribute = struct {
    name: []const u8,
    value: []u8,
};

pub fn cloneAttributes(allocator: std.mem.Allocator, attrs: []const Attribute) ![]Attribute {
    const out = try allocator.alloc(Attribute, attrs.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |attr| allocator.free(attr.value);
        allocator.free(out);
    }
    for (attrs, 0..) |attr, i| {
        out[i] = .{
            .name = attr.name,
            .value = try allocator.dupe(u8, attr.value),
        };
        initialized += 1;
    }
    return out;
}

pub fn freeAttributes(allocator: std.mem.Allocator, attrs: []Attribute) void {
    for (attrs) |attr| allocator.free(attr.value);
    allocator.free(attrs);
}

pub fn validateSecurityCapability(value: []const u8) !void {
    if (value.len > max_value_bytes) return error.TarXattrTooLarge;
    if (value.len != 12 and value.len != 20 and value.len != 24) return error.BadTarXattr;
    const magic = std.mem.readInt(u32, value[0..4], .little);
    const revision = magic & 0xff000000;
    switch (revision) {
        0x01000000 => if (value.len != 12) return error.BadTarXattr,
        0x02000000 => if (value.len != 20) return error.BadTarXattr,
        0x03000000 => if (value.len != 24) return error.BadTarXattr,
        else => return error.BadTarXattr,
    }
}
