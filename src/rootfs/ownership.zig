const std = @import("std");

pub const Ownership = struct {
    uid: u32,
    gid: u32,
};

pub const Map = std.StringHashMap(Ownership);

pub fn record(
    allocator: std.mem.Allocator,
    ownership: *Map,
    rel: []const u8,
    owner: Ownership,
) !void {
    const key = try allocator.dupe(u8, rel);
    const entry = try ownership.getOrPut(key);
    if (entry.found_existing) {
        allocator.free(key);
    }
    entry.value_ptr.* = owner;
}

pub fn deinit(allocator: std.mem.Allocator, ownership: *Map) void {
    var it = ownership.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
    }
    ownership.deinit();
}

pub fn removeSubtree(allocator: std.mem.Allocator, ownership: *Map, rel: []const u8) !void {
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(allocator);
    const prefix = try std.fmt.allocPrint(allocator, "{s}/", .{rel});
    defer allocator.free(prefix);

    var it = ownership.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, rel) or std.mem.startsWith(u8, key, prefix)) {
            try keys.append(allocator, key);
        }
    }
    for (keys.items) |key| {
        _ = ownership.remove(key);
        allocator.free(key);
    }
}

pub fn removeChildren(allocator: std.mem.Allocator, ownership: *Map, rel: []const u8) !void {
    if (rel.len == 0) {
        var it = ownership.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        ownership.clearRetainingCapacity();
        return;
    }

    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(allocator);
    const prefix = try std.fmt.allocPrint(allocator, "{s}/", .{rel});
    defer allocator.free(prefix);

    var it = ownership.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.startsWith(u8, key, prefix)) {
            try keys.append(allocator, key);
        }
    }
    for (keys.items) |key| {
        _ = ownership.remove(key);
        allocator.free(key);
    }
}
