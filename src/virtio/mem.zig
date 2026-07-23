//! Virtio memory device (virtio spec 1.2 section 5.15), grow-only prototype.
//!
//! The guest controls request descriptors, requested block ranges, and queue
//! state. Keep all parsing bounded and fail closed; see SECURITY.md.

const std = @import("std");
const guestmem = @import("../guestmem.zig");
const memory = @import("../memory.zig");
const queue = @import("queue.zig");
const mmio = @import("mmio.zig");

pub const device_id: u32 = 24;
pub const default_block_size: u64 = 2 * 1024 * 1024;
const request_queue = 0;
const max_blocks = memory.max_elastic_blocks;
const pressure_growth_chunk: u64 = 1024 * 1024 * 1024;

const req_plug: u16 = 0;
const req_unplug: u16 = 1;
const req_unplug_all: u16 = 2;
const req_state: u16 = 3;

const resp_ack: u16 = 0;
const resp_nack: u16 = 1;
const resp_busy: u16 = 2;
const resp_error: u16 = 3;

const state_plugged: u16 = 0;
const state_unplugged: u16 = 1;
const state_mixed: u16 = 2;

pub const Config = struct {
    addr: u64,
    region_size: u64,
    requested_size: u64,
    block_size: u64 = default_block_size,
    plug_context: ?*anyopaque = null,
    plugFn: ?*const fn (*anyopaque, u64) bool = null,
};

pub fn requestedSizeAfterPressure(current: u64, capacity: u64, events: u32) u64 {
    var requested = @min(current, capacity);
    var i: u32 = 0;
    while (i < events and requested < capacity) : (i += 1) {
        requested = if (capacity - requested <= pressure_growth_chunk)
            capacity
        else
            requested + pressure_growth_chunk;
    }
    return requested;
}

pub const Mem = struct {
    block_size: u64,
    addr: u64,
    region_size: u64,
    requested_size: u64,
    plugged_size: u64 = 0,
    plugged: std.StaticBitSet(max_blocks) = .initEmpty(),
    plug_context: ?*anyopaque = null,
    plugFn: ?*const fn (*anyopaque, u64) bool = null,

    pub fn init(config: Config) Mem {
        std.debug.assert(config.block_size != 0);
        std.debug.assert(config.region_size % config.block_size == 0);
        std.debug.assert(config.requested_size <= config.region_size);
        std.debug.assert(config.requested_size % config.block_size == 0);
        std.debug.assert(config.region_size / config.block_size <= max_blocks);
        return .{
            .block_size = config.block_size,
            .addr = config.addr,
            .region_size = config.region_size,
            .requested_size = config.requested_size,
            .plug_context = config.plug_context,
            .plugFn = config.plugFn,
        };
    }

    pub fn setRequestedSize(self: *Mem, bytes: u64) !void {
        if (bytes > self.region_size or bytes % self.block_size != 0) return error.InvalidVirtioMemRequest;
        self.requested_size = bytes;
    }

    pub fn captureState(self: *const Mem, allocator: std.mem.Allocator, initial_size: u64) !memory.CapturedState {
        var ranges = std.array_list.Managed(memory.PluggedRange).init(allocator);
        errdefer ranges.deinit();

        const block_count: usize = @intCast(self.region_size / self.block_size);
        var index: usize = 0;
        while (index < block_count) {
            if (!self.plugged.isSet(index)) {
                index += 1;
                continue;
            }
            const start = index;
            while (index < block_count and self.plugged.isSet(index)) : (index += 1) {}
            try ranges.append(.{
                .start_block = @intCast(start),
                .block_count = @intCast(index - start),
            });
        }

        return .{
            .initial_size = initial_size,
            .maximum_size = initial_size + self.region_size,
            .requested_size = initial_size + self.requested_size,
            .captured_size = initial_size + self.plugged_size,
            .block_size = self.block_size,
            .plugged_ranges = try ranges.toOwnedSlice(),
        };
    }

    pub fn restoreState(self: *Mem, captured: memory.CapturedState) !void {
        if (captured.block_size != self.block_size or
            captured.maximum_size < captured.initial_size or
            captured.maximum_size - captured.initial_size != self.region_size or
            captured.requested_size < captured.initial_size or
            captured.requested_size > captured.maximum_size)
        {
            return error.InvalidVirtioMemState;
        }
        const requested_region_size = captured.requested_size - captured.initial_size;
        if (requested_region_size % self.block_size != 0) return error.InvalidVirtioMemState;
        if (requested_region_size > 0) {
            if (self.plugFn) |plug_fn| {
                const ctx = self.plug_context orelse return error.InvalidVirtioMemState;
                if (!plug_fn(ctx, requested_region_size)) return error.InvalidVirtioMemState;
            }
        }

        self.requested_size = requested_region_size;
        self.plugged = .initEmpty();
        self.plugged_size = 0;
        for (captured.plugged_ranges) |range| {
            if (range.block_count == 0) return error.InvalidVirtioMemState;
            const start: usize = range.start_block;
            const end = std.math.add(usize, start, range.block_count) catch return error.InvalidVirtioMemState;
            if (end > self.region_size / self.block_size or end > requested_region_size / self.block_size) {
                return error.InvalidVirtioMemState;
            }
            var index = start;
            while (index < end) : (index += 1) {
                if (self.plugged.isSet(index)) return error.InvalidVirtioMemState;
                self.plugged.set(index);
            }
            self.plugged_size += @as(u64, range.block_count) * self.block_size;
        }
        if (captured.captured_size != captured.initial_size + self.plugged_size) return error.InvalidVirtioMemState;
    }

    pub fn device(self: *Mem) mmio.Device {
        return .{
            .context = self,
            .device_id = device_id,
            .device_features = 0,
            .queue_count = 1,
            .notifyFn = notify,
            .configReadFn = configRead,
        };
    }

    fn configRead(ctx: *anyopaque, offset: u64) u32 {
        const self: *Mem = @ptrCast(@alignCast(ctx));
        return switch (offset) {
            0 => @truncate(self.block_size),
            4 => @truncate(self.block_size >> 32),
            8 => 0, // node_id without VIRTIO_MEM_F_ACPI_PXM
            16 => @truncate(self.addr),
            20 => @truncate(self.addr >> 32),
            24 => @truncate(self.region_size),
            28 => @truncate(self.region_size >> 32),
            32 => @truncate(self.region_size),
            36 => @truncate(self.region_size >> 32),
            40 => @truncate(self.plugged_size),
            44 => @truncate(self.plugged_size >> 32),
            48 => @truncate(self.requested_size),
            52 => @truncate(self.requested_size >> 32),
            else => 0,
        };
    }

    fn notify(ctx: *anyopaque, queue_index: u8, queues: *[mmio.max_queues]queue.VirtQueue, ram: guestmem.GuestRam) bool {
        const self: *Mem = @ptrCast(@alignCast(ctx));
        if (queue_index != request_queue) return false;
        const q = &queues[request_queue];

        var did_work = false;
        var budget: queue.NotifyBudget = .{};
        while (budget.hasRemaining()) {
            const maybe_chain = q.popAvail(ram) catch return did_work;
            const chain = maybe_chain orelse break;
            budget.consume();
            const written = self.handleRequest(&chain);
            chain.markWritableDirty(ram);
            q.pushUsed(ram, chain.head, written) catch return did_work;
            did_work = true;
        }
        return did_work;
    }

    fn handleRequest(self: *Mem, chain: *const queue.Chain) u32 {
        const response = firstWritable(chain) orelse return 0;
        if (response.len < 10) return 0;

        var request: [24]u8 = undefined;
        if (!chain.copyReadableRange(0, &request)) return 0;
        const kind = std.mem.readInt(u16, request[0..2], .little);
        const addr = std.mem.readInt(u64, request[8..16], .little);
        const nb_blocks = std.mem.readInt(u16, request[16..18], .little);
        const status = switch (kind) {
            req_plug => self.plug(addr, nb_blocks),
            req_state => self.state(addr, nb_blocks, response),
            req_unplug, req_unplug_all => resp_nack, // ponytail: grow-only prototype; add unplug with reclamation.
            else => resp_error,
        };
        std.mem.writeInt(u16, response[0..2], status, .little);
        return 10;
    }

    fn plug(self: *Mem, addr: u64, nb_blocks: u16) u16 {
        const range = self.blockRange(addr, nb_blocks) orelse return resp_error;
        if (range.end_bytes > self.requested_size) return resp_error;
        var i = range.start;
        while (i < range.end) : (i += 1) {
            if (self.plugged.isSet(i)) return resp_error;
        }
        if (self.plugFn) |f| {
            const ctx = self.plug_context orelse return resp_busy;
            if (!f(ctx, self.requested_size)) return resp_busy;
        }
        i = range.start;
        while (i < range.end) : (i += 1) self.plugged.set(i);
        self.plugged_size += range.end_bytes - range.start_bytes;
        return resp_ack;
    }

    fn state(self: *Mem, addr: u64, nb_blocks: u16, response: []u8) u16 {
        const range = self.blockRange(addr, nb_blocks) orelse return resp_error;
        var seen_plugged = false;
        var seen_unplugged = false;
        var i = range.start;
        while (i < range.end) : (i += 1) {
            if (self.plugged.isSet(i)) {
                seen_plugged = true;
            } else {
                seen_unplugged = true;
            }
        }
        const value: u16 = if (seen_plugged and seen_unplugged)
            state_mixed
        else if (seen_plugged)
            state_plugged
        else
            state_unplugged;
        std.mem.writeInt(u16, response[8..10], value, .little);
        return resp_ack;
    }

    fn blockRange(self: *const Mem, addr: u64, nb_blocks: u16) ?struct {
        start: usize,
        end: usize,
        start_bytes: u64,
        end_bytes: u64,
    } {
        if (nb_blocks == 0 or addr < self.addr) return null;
        const start_bytes = addr - self.addr;
        if (start_bytes % self.block_size != 0) return null;
        const len_bytes = std.math.mul(u64, nb_blocks, self.block_size) catch return null;
        const end_bytes = std.math.add(u64, start_bytes, len_bytes) catch return null;
        if (end_bytes > self.region_size) return null;
        const start = start_bytes / self.block_size;
        const end = end_bytes / self.block_size;
        if (end > max_blocks) return null;
        return .{ .start = @intCast(start), .end = @intCast(end), .start_bytes = start_bytes, .end_bytes = end_bytes };
    }
};

fn firstWritable(chain: *const queue.Chain) ?[]u8 {
    for (chain.segments.slice()) |seg| {
        if (seg.writable) return seg.data;
    }
    return null;
}

fn makeChain(request: []u8, response: []u8) queue.Chain {
    var chain = queue.Chain{ .head = 0, .segments = .{} };
    chain.segments.append(.{ .data = request, .writable = false }) catch unreachable;
    chain.segments.append(.{ .data = response, .writable = true }) catch unreachable;
    return chain;
}

test "config exposes grow-only region" {
    var mem = Mem.init(.{
        .addr = 0x1_0000_0000,
        .region_size = 512 * 1024 * 1024,
        .requested_size = 512 * 1024 * 1024,
    });

    try std.testing.expectEqual(device_id, mem.device().device_id);
    try std.testing.expectEqual(default_block_size, @as(u64, Mem.configRead(&mem, 0)) | (@as(u64, Mem.configRead(&mem, 4)) << 32));
    try std.testing.expectEqual(@as(u32, 0), Mem.configRead(&mem, 8));
    try std.testing.expectEqual(@as(u32, 0), Mem.configRead(&mem, 16));
    try std.testing.expectEqual(@as(u32, 1), Mem.configRead(&mem, 20));
    try std.testing.expectEqual(mem.region_size, @as(u64, Mem.configRead(&mem, 24)) | (@as(u64, Mem.configRead(&mem, 28)) << 32));
    try std.testing.expectEqual(mem.region_size, @as(u64, Mem.configRead(&mem, 32)) | (@as(u64, Mem.configRead(&mem, 36)) << 32));
}

test "plug and state requests update plugged size" {
    var mem = Mem.init(.{ .addr = 0x1000_0000, .region_size = default_block_size * 4, .requested_size = default_block_size * 4 });
    var req: [24]u8 = @splat(0);
    var resp: [10]u8 = @splat(0);

    std.mem.writeInt(u16, req[0..2], req_plug, .little);
    std.mem.writeInt(u64, req[8..16], 0x1000_0000, .little);
    std.mem.writeInt(u16, req[16..18], 2, .little);
    var chain = makeChain(&req, &resp);
    try std.testing.expectEqual(@as(u32, 10), mem.handleRequest(&chain));
    try std.testing.expectEqual(resp_ack, std.mem.readInt(u16, resp[0..2], .little));
    try std.testing.expectEqual(default_block_size * 2, mem.plugged_size);

    @memset(&resp, 0);
    std.mem.writeInt(u16, req[0..2], req_state, .little);
    std.mem.writeInt(u16, req[16..18], 3, .little);
    try std.testing.expectEqual(@as(u32, 10), mem.handleRequest(&chain));
    try std.testing.expectEqual(resp_ack, std.mem.readInt(u16, resp[0..2], .little));
    try std.testing.expectEqual(state_mixed, std.mem.readInt(u16, resp[8..10], .little));
}

test "request header may span readable descriptors" {
    var mem = Mem.init(.{ .addr = 0x1000_0000, .region_size = default_block_size * 4, .requested_size = default_block_size * 4 });
    var req: [24]u8 = @splat(0);
    var resp: [10]u8 = @splat(0);
    std.mem.writeInt(u16, req[0..2], req_plug, .little);
    std.mem.writeInt(u64, req[8..16], 0x1000_0000, .little);
    std.mem.writeInt(u16, req[16..18], 1, .little);

    var chain = queue.Chain{ .head = 0, .segments = .{} };
    try chain.segments.append(.{ .data = req[0..8], .writable = false });
    try chain.segments.append(.{ .data = req[8..], .writable = false });
    try chain.segments.append(.{ .data = &resp, .writable = true });

    try std.testing.expectEqual(@as(u32, 10), mem.handleRequest(&chain));
    try std.testing.expectEqual(resp_ack, std.mem.readInt(u16, resp[0..2], .little));
}

test "pressure events grow requested size in bounded chunks" {
    try std.testing.expectEqual(@as(u64, 0), requestedSizeAfterPressure(0, 0, 3));
    try std.testing.expectEqual(pressure_growth_chunk, requestedSizeAfterPressure(0, pressure_growth_chunk * 4, 1));
    try std.testing.expectEqual(pressure_growth_chunk * 3, requestedSizeAfterPressure(pressure_growth_chunk, pressure_growth_chunk * 4, 2));
    try std.testing.expectEqual(pressure_growth_chunk * 4, requestedSizeAfterPressure(pressure_growth_chunk * 3, pressure_growth_chunk * 4, 3));
}

test "plug callback receives requested size" {
    const Context = struct {
        requested_size: u64 = 0,

        fn plug(ctx: *anyopaque, requested_size: u64) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.requested_size = requested_size;
            return true;
        }
    };

    var context = Context{};
    var mem = Mem.init(.{
        .addr = 0x1000_0000,
        .region_size = default_block_size * 4,
        .requested_size = default_block_size * 3,
        .plug_context = &context,
        .plugFn = Context.plug,
    });
    var req: [24]u8 = @splat(0);
    var resp: [10]u8 = @splat(0);

    std.mem.writeInt(u16, req[0..2], req_plug, .little);
    std.mem.writeInt(u64, req[8..16], 0x1000_0000, .little);
    std.mem.writeInt(u16, req[16..18], 1, .little);
    var chain = makeChain(&req, &resp);

    try std.testing.expectEqual(@as(u32, 10), mem.handleRequest(&chain));
    try std.testing.expectEqual(default_block_size * 3, context.requested_size);
}

test "captured state restores requested size and exact plugged ranges" {
    const allocator = std.testing.allocator;
    var original = Mem.init(.{
        .addr = 0x1000_0000,
        .region_size = default_block_size * 4,
        .requested_size = default_block_size * 4,
    });
    original.plugged.set(0);
    original.plugged.set(1);
    original.plugged.set(3);
    original.plugged_size = default_block_size * 3;

    const state = try original.captureState(allocator, 512 * 1024 * 1024);
    defer allocator.free(state.plugged_ranges);
    try std.testing.expectEqual(@as(usize, 2), state.plugged_ranges.len);
    try std.testing.expectEqual(@as(u32, 0), state.plugged_ranges[0].start_block);
    try std.testing.expectEqual(@as(u32, 2), state.plugged_ranges[0].block_count);
    try std.testing.expectEqual(@as(u32, 3), state.plugged_ranges[1].start_block);

    var restored = Mem.init(.{
        .addr = original.addr,
        .region_size = original.region_size,
        .requested_size = 0,
    });
    try restored.restoreState(state);
    try std.testing.expectEqual(original.requested_size, restored.requested_size);
    try std.testing.expectEqual(original.plugged_size, restored.plugged_size);
    try std.testing.expect(restored.plugged.eql(original.plugged));
}

fn fuzzMemQueue(_: void, s: *std.testing.Smith) !void {
    var mem = Mem.init(.{ .addr = 0x1000_0000, .region_size = default_block_size * 4, .requested_size = default_block_size * 4 });
    var t = mmio.Transport.init(mem.device());
    var buf: [4096]u8 = [_]u8{0} ** 4096;
    _ = s.slice(&buf);
    const ram = guestmem.GuestRam{ .bytes = &buf, .base = 0 };

    t.queues[request_queue] = .{ .size = 8, .ready = true, .desc_addr = 0x000, .avail_addr = 0x400, .used_addr = 0x800 };
    ram.write(u16, 0x400 + 2, s.value(u8) % 4) catch {};

    _ = t.write(0x050, request_queue, ram);
}

test "fuzz virtio-mem queue handling" {
    try std.testing.fuzz({}, fuzzMemQueue, .{});
}
