//! Flattened Device Tree (FDT/DTB) builder.
//!
//! Builds the device tree blob handed to an AArch64 Linux guest at boot (the
//! kernel expects the DTB physical address in x0). Emits DTB format version
//! 17 per the devicetree specification v0.4: header, empty memory
//! reservation block, structure block, and a deduplicated strings block.
//!
//! Backend-neutral by design: the device model describes itself through this
//! builder regardless of which hypervisor runs the guest.

const std = @import("std");

const FDT_MAGIC: u32 = 0xd00dfeed;
const FDT_VERSION: u32 = 17;
const FDT_LAST_COMP_VERSION: u32 = 16;

const FDT_BEGIN_NODE: u32 = 0x1;
const FDT_END_NODE: u32 = 0x2;
const FDT_PROP: u32 = 0x3;
const FDT_END: u32 = 0x9;

const header_len = 40;
const rsvmap_len = 16; // single zero terminator entry

/// Incremental DTB builder. Call `beginNode`/`endNode`/`prop*` to describe
/// the tree, then `finish` to assemble the blob. Nodes must be balanced and
/// properties must be emitted inside an open node.
pub const Fdt = struct {
    allocator: std.mem.Allocator,
    structure: std.ArrayList(u8),
    strings: std.ArrayList(u8),
    depth: u32,
    next_phandle: u32,

    pub fn init(allocator: std.mem.Allocator) Fdt {
        return .{
            .allocator = allocator,
            .structure = .empty,
            .strings = .empty,
            .depth = 0,
            .next_phandle = 1,
        };
    }

    pub fn deinit(self: *Fdt) void {
        self.structure.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        self.* = undefined;
    }

    /// Open a node. The root node's name is the empty string "".
    pub fn beginNode(self: *Fdt, name: []const u8) !void {
        try self.appendToken(FDT_BEGIN_NODE);
        try self.structure.appendSlice(self.allocator, name);
        try self.structure.append(self.allocator, 0);
        try self.padStructure();
        self.depth += 1;
    }

    /// Close the most recently opened node.
    pub fn endNode(self: *Fdt) !void {
        if (self.depth == 0) return error.UnbalancedNodes;
        try self.appendToken(FDT_END_NODE);
        self.depth -= 1;
    }

    /// Emit a property with a raw byte value inside the open node.
    pub fn prop(self: *Fdt, name: []const u8, value: []const u8) !void {
        if (self.depth == 0) return error.NoOpenNode;
        const nameoff = try self.stringOffset(name);
        try self.appendToken(FDT_PROP);
        try self.appendU32(@intCast(value.len));
        try self.appendU32(nameoff);
        try self.structure.appendSlice(self.allocator, value);
        try self.padStructure();
    }

    /// Emit a zero-length (boolean presence) property.
    pub fn propEmpty(self: *Fdt, name: []const u8) !void {
        try self.prop(name, &.{});
    }

    /// Emit a big-endian u32 cell property.
    pub fn propU32(self: *Fdt, name: []const u8, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .big);
        try self.prop(name, &bytes);
    }

    /// Emit a big-endian u64 property (two cells).
    pub fn propU64(self: *Fdt, name: []const u8, value: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .big);
        try self.prop(name, &bytes);
    }

    /// Emit an array of big-endian u32 cells.
    pub fn propU32Array(self: *Fdt, name: []const u8, values: []const u32) !void {
        if (self.depth == 0) return error.NoOpenNode;
        const nameoff = try self.stringOffset(name);
        try self.appendToken(FDT_PROP);
        try self.appendU32(@intCast(values.len * 4));
        try self.appendU32(nameoff);
        for (values) |value| try self.appendU32(value);
    }

    /// Emit a string property, including the trailing NUL.
    pub fn propString(self: *Fdt, name: []const u8, value: []const u8) !void {
        if (self.depth == 0) return error.NoOpenNode;
        const nameoff = try self.stringOffset(name);
        try self.appendToken(FDT_PROP);
        try self.appendU32(@intCast(value.len + 1));
        try self.appendU32(nameoff);
        try self.structure.appendSlice(self.allocator, value);
        try self.structure.append(self.allocator, 0);
        try self.padStructure();
    }

    /// Emit a string list property: each string NUL-terminated, concatenated.
    pub fn propStringList(self: *Fdt, name: []const u8, values: []const []const u8) !void {
        if (self.depth == 0) return error.NoOpenNode;
        var len: usize = 0;
        for (values) |value| len += value.len + 1;
        const nameoff = try self.stringOffset(name);
        try self.appendToken(FDT_PROP);
        try self.appendU32(@intCast(len));
        try self.appendU32(nameoff);
        for (values) |value| {
            try self.structure.appendSlice(self.allocator, value);
            try self.structure.append(self.allocator, 0);
        }
        try self.padStructure();
    }

    /// Allocate the next phandle value (starting at 1). The caller adds the
    /// "phandle" property itself via `propU32`.
    pub fn allocPhandle(self: *Fdt) u32 {
        const handle = self.next_phandle;
        self.next_phandle += 1;
        return handle;
    }

    /// Finalize the tree: validates begin/end nesting balance, appends
    /// FDT_END, and assembles header + memory reservation block + structure
    /// block + strings block. Returns the complete blob; the caller owns it
    /// and frees it with the allocator passed to `init`.
    pub fn finish(self: *Fdt) ![]u8 {
        if (self.depth != 0) return error.UnbalancedNodes;
        try self.appendToken(FDT_END);

        const off_mem_rsvmap = header_len; // already 8-byte aligned
        const off_dt_struct = off_mem_rsvmap + rsvmap_len; // 4-byte aligned
        const size_dt_struct = self.structure.items.len;
        const off_dt_strings = off_dt_struct + size_dt_struct;
        const size_dt_strings = self.strings.items.len;
        const totalsize = off_dt_strings + size_dt_strings;

        const blob = try self.allocator.alloc(u8, totalsize);
        errdefer self.allocator.free(blob);

        const header = [10]u32{
            FDT_MAGIC,
            @intCast(totalsize),
            @intCast(off_dt_struct),
            @intCast(off_dt_strings),
            @intCast(off_mem_rsvmap),
            FDT_VERSION,
            FDT_LAST_COMP_VERSION,
            0, // boot_cpuid_phys
            @intCast(size_dt_strings),
            @intCast(size_dt_struct),
        };
        for (header, 0..) |field, i| {
            std.mem.writeInt(u32, blob[i * 4 ..][0..4], field, .big);
        }
        @memset(blob[off_mem_rsvmap..off_dt_struct], 0);
        @memcpy(blob[off_dt_struct..off_dt_strings], self.structure.items);
        @memcpy(blob[off_dt_strings..], self.strings.items);
        return blob;
    }

    /// Return the strings-block offset of `name`, appending it if new.
    /// Identical names share one offset (the spec's strings deduplication).
    fn stringOffset(self: *Fdt, name: []const u8) !u32 {
        var off: usize = 0;
        while (off < self.strings.items.len) {
            const end = std.mem.indexOfScalarPos(u8, self.strings.items, off, 0).?;
            if (std.mem.eql(u8, self.strings.items[off..end], name)) {
                return @intCast(off);
            }
            off = end + 1;
        }
        const new_off: u32 = @intCast(self.strings.items.len);
        try self.strings.appendSlice(self.allocator, name);
        try self.strings.append(self.allocator, 0);
        return new_off;
    }

    fn appendToken(self: *Fdt, token: u32) !void {
        try self.appendU32(token);
    }

    fn appendU32(self: *Fdt, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .big);
        try self.structure.appendSlice(self.allocator, &bytes);
    }

    /// Zero-pad the structure block to the next 4-byte boundary.
    fn padStructure(self: *Fdt) !void {
        while (self.structure.items.len % 4 != 0) {
            try self.structure.append(self.allocator, 0);
        }
    }
};

fn readBe32(blob: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, blob[off..][0..4], .big);
}

test "empty tree produces a minimal valid blob" {
    var fdt = Fdt.init(std.testing.allocator);
    defer fdt.deinit();
    try fdt.beginNode("");
    try fdt.endNode();
    const blob = try fdt.finish();
    defer std.testing.allocator.free(blob);

    try std.testing.expectEqual(FDT_MAGIC, readBe32(blob, 0));
    try std.testing.expectEqual(@as(u32, @intCast(blob.len)), readBe32(blob, 4));
    try std.testing.expectEqual(FDT_VERSION, readBe32(blob, 20));
    try std.testing.expectEqual(FDT_LAST_COMP_VERSION, readBe32(blob, 24));
    try std.testing.expectEqual(@as(u32, 0), readBe32(blob, 28)); // boot_cpuid_phys

    // Reservation block: 16 zero bytes at off_mem_rsvmap.
    const off_rsvmap = readBe32(blob, 16);
    try std.testing.expectEqual(@as(u32, header_len), off_rsvmap);
    for (blob[off_rsvmap..][0..rsvmap_len]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }

    // Structure block: BEGIN_NODE, "" name padded to 4 zero bytes,
    // END_NODE, END.
    const off_struct = readBe32(blob, 8);
    const size_struct = readBe32(blob, 36);
    try std.testing.expectEqual(@as(u32, 16), size_struct);
    const s = blob[off_struct..][0..16];
    try std.testing.expectEqual(FDT_BEGIN_NODE, readBe32(s, 0));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, s[4..8]);
    try std.testing.expectEqual(FDT_END_NODE, readBe32(s, 8));
    try std.testing.expectEqual(FDT_END, readBe32(s, 12));
}

test "property values encode big-endian with NUL handling" {
    var fdt = Fdt.init(std.testing.allocator);
    defer fdt.deinit();
    try fdt.beginNode("");
    try fdt.propU32("test", 0x11223344);
    try fdt.propU64("wide", 0x0102030405060708);
    try fdt.propString("compatible", "arm,gic-v3");
    try fdt.propStringList("names", &.{ "tx", "rx" });
    try fdt.propU32Array("cells", &.{ 0xaabbccdd, 0x00112233 });
    try fdt.propEmpty("dma-coherent");
    try fdt.endNode();
    const blob = try fdt.finish();
    defer std.testing.allocator.free(blob);

    const off_struct = readBe32(blob, 8);
    const size_struct = readBe32(blob, 36);
    const off_strings = readBe32(blob, 12);
    const s = blob[off_struct..][0..size_struct];

    // Walk tokens, collecting properties by name.
    var cursor: usize = 8; // skip BEGIN_NODE + empty root name
    var found_u32 = false;
    var found_u64 = false;
    var found_string = false;
    var found_list = false;
    var found_array = false;
    var found_empty = false;
    while (cursor < s.len) {
        const token = readBe32(s, cursor);
        cursor += 4;
        switch (token) {
            FDT_PROP => {
                const len = readBe32(s, cursor);
                const nameoff = readBe32(s, cursor + 4);
                cursor += 8;
                const value = s[cursor .. cursor + len];
                cursor = std.mem.alignForward(usize, cursor + len, 4);
                const name_bytes = blob[off_strings + nameoff ..];
                const name = name_bytes[0..std.mem.indexOfScalar(u8, name_bytes, 0).?];
                if (std.mem.eql(u8, name, "test")) {
                    try std.testing.expectEqual(@as(u32, 4), len);
                    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33, 0x44 }, value);
                    found_u32 = true;
                } else if (std.mem.eql(u8, name, "wide")) {
                    try std.testing.expectEqualSlices(
                        u8,
                        &.{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 },
                        value,
                    );
                    found_u64 = true;
                } else if (std.mem.eql(u8, name, "compatible")) {
                    try std.testing.expectEqualSlices(u8, "arm,gic-v3\x00", value);
                    found_string = true;
                } else if (std.mem.eql(u8, name, "names")) {
                    try std.testing.expectEqualSlices(u8, "tx\x00rx\x00", value);
                    found_list = true;
                } else if (std.mem.eql(u8, name, "cells")) {
                    try std.testing.expectEqualSlices(
                        u8,
                        &.{ 0xaa, 0xbb, 0xcc, 0xdd, 0x00, 0x11, 0x22, 0x33 },
                        value,
                    );
                    found_array = true;
                } else if (std.mem.eql(u8, name, "dma-coherent")) {
                    try std.testing.expectEqual(@as(u32, 0), len);
                    found_empty = true;
                }
            },
            FDT_END_NODE, FDT_END => {},
            else => return error.UnexpectedToken,
        }
    }
    try std.testing.expect(found_u32);
    try std.testing.expect(found_u64);
    try std.testing.expect(found_string);
    try std.testing.expect(found_list);
    try std.testing.expect(found_array);
    try std.testing.expect(found_empty);
}

test "repeated property names share one strings-block entry" {
    var fdt = Fdt.init(std.testing.allocator);
    defer fdt.deinit();
    try fdt.beginNode("");
    try fdt.beginNode("a");
    try fdt.propU32("reg", 1);
    try fdt.endNode();
    try fdt.beginNode("b");
    try fdt.propU32("reg", 2);
    try fdt.endNode();
    try fdt.endNode();
    const blob = try fdt.finish();
    defer std.testing.allocator.free(blob);

    const size_strings = readBe32(blob, 32);
    try std.testing.expectEqual(@as(u32, "reg".len + 1), size_strings);
    const off_strings = readBe32(blob, 12);
    try std.testing.expectEqualSlices(u8, "reg\x00", blob[off_strings..][0..4]);
}

test "names and values pad to 4-byte token alignment" {
    var fdt = Fdt.init(std.testing.allocator);
    defer fdt.deinit();
    try fdt.beginNode("");
    try fdt.beginNode("cpu"); // 3 chars: NUL then no further padding needed
    try fdt.prop("five", "12345"); // 5 bytes: padded to 8
    try fdt.endNode();
    try fdt.endNode();
    const blob = try fdt.finish();
    defer std.testing.allocator.free(blob);

    const off_struct = readBe32(blob, 8);
    const size_struct = readBe32(blob, 36);
    const s = blob[off_struct..][0..size_struct];
    try std.testing.expectEqual(@as(usize, 0), s.len % 4);

    // Walk every token; each read must land on a valid token value.
    var cursor: usize = 0;
    var depth: usize = 0;
    var saw_end = false;
    var saw_five = false;
    while (cursor < s.len) {
        try std.testing.expectEqual(@as(usize, 0), cursor % 4);
        const token = readBe32(s, cursor);
        cursor += 4;
        switch (token) {
            FDT_BEGIN_NODE => {
                const end = std.mem.indexOfScalarPos(u8, s, cursor, 0).?;
                cursor = std.mem.alignForward(usize, end + 1, 4);
                depth += 1;
            },
            FDT_END_NODE => depth -= 1,
            FDT_PROP => {
                const len = readBe32(s, cursor);
                cursor += 8; // len + nameoff
                if (len == 5) {
                    try std.testing.expectEqualSlices(u8, "12345", s[cursor..][0..5]);
                    saw_five = true;
                }
                cursor = std.mem.alignForward(usize, cursor + len, 4);
            },
            FDT_END => {
                try std.testing.expectEqual(s.len, cursor);
                saw_end = true;
            },
            else => return error.UnexpectedToken,
        }
    }
    try std.testing.expectEqual(@as(usize, 0), depth);
    try std.testing.expect(saw_end);
    try std.testing.expect(saw_five);
}

test "unbalanced nesting is rejected" {
    var open = Fdt.init(std.testing.allocator);
    defer open.deinit();
    try open.beginNode("");
    try std.testing.expectError(error.UnbalancedNodes, open.finish());

    var closed = Fdt.init(std.testing.allocator);
    defer closed.deinit();
    try std.testing.expectError(error.UnbalancedNodes, closed.endNode());

    var rootless = Fdt.init(std.testing.allocator);
    defer rootless.deinit();
    try std.testing.expectError(error.NoOpenNode, rootless.propU32("reg", 1));
}

test "dtc accepts a generated blob" {
    const allocator = std.testing.allocator;

    var fdt = Fdt.init(allocator);
    defer fdt.deinit();
    try fdt.beginNode("");
    try fdt.propU32("#address-cells", 2);
    try fdt.propU32("#size-cells", 2);
    try fdt.beginNode("memory@40000000");
    try fdt.propString("device_type", "memory");
    try fdt.propU32Array("reg", &.{ 0, 0x40000000, 0, 0x10000000 });
    try fdt.endNode();
    try fdt.endNode();
    const blob = try fdt.finish();
    defer allocator.free(blob);

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "test.dtb", .data = blob });

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "dtc", "-I", "dtb", "-O", "dts", "test.dtb" },
        .cwd = .{ .dir = tmp.dir },
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest, // dtc not installed
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}
