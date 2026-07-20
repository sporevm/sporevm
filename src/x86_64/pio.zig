//! Finite x86 board-v0 port-I/O policy.
//!
//! The accepted tuples are exactly the ordinary boot and keyboard-reset
//! accesses observed against the pinned Stage 0a.3 kernel. Every other access
//! fails closed before the harness completes its KVM_EXIT_IO.

const std = @import("std");

pub const Direction = enum { read, write };

pub const Access = struct {
    direction: Direction,
    width: u8,
    port: u16,
    count: u32,
    data: []u8,
};

pub const Action = enum { continue_guest, guest_reset };

pub const Error = error{UnsupportedPio};

pub fn handle(access: Access) Error!Action {
    if (access.width != 1 or access.count != 1 or access.data.len != 1) {
        return error.UnsupportedPio;
    }

    return switch (access.direction) {
        .read => switch (access.port) {
            0x64 => blk: {
                access.data[0] = 0;
                break :blk .continue_guest;
            },
            else => error.UnsupportedPio,
        },
        .write => switch (access.port) {
            0x64 => if (access.data[0] == 0xfe) .guest_reset else error.UnsupportedPio,
            0x70 => if (access.data[0] == 0x0f) .continue_guest else error.UnsupportedPio,
            0x71 => if (access.data[0] == 0x0a or access.data[0] == 0x00) .continue_guest else error.UnsupportedPio,
            // Linux uses a zero write to the legacy POST port as an I/O delay
            // while programming the in-kernel PIC under the narrow v0 CPUID.
            0x80 => if (access.data[0] == 0x00) .continue_guest else error.UnsupportedPio,
            else => error.UnsupportedPio,
        },
    };
}

test "finite policy accepts only the native boot and reset tuples" {
    const Case = struct { direction: Direction, port: u16, value: u8, action: Action };
    const cases = [_]Case{
        .{ .direction = .write, .port = 0x70, .value = 0x0f, .action = .continue_guest },
        .{ .direction = .write, .port = 0x71, .value = 0x0a, .action = .continue_guest },
        .{ .direction = .write, .port = 0x71, .value = 0x00, .action = .continue_guest },
        .{ .direction = .write, .port = 0x64, .value = 0xfe, .action = .guest_reset },
        .{ .direction = .write, .port = 0x80, .value = 0x00, .action = .continue_guest },
    };
    for (cases) |case| {
        var data = [1]u8{case.value};
        try std.testing.expectEqual(case.action, try handle(.{
            .direction = case.direction,
            .width = 1,
            .port = case.port,
            .count = 1,
            .data = &data,
        }));
    }

    var read_data = [1]u8{0xa5};
    try std.testing.expectEqual(Action.continue_guest, try handle(.{
        .direction = .read,
        .width = 1,
        .port = 0x64,
        .count = 1,
        .data = &read_data,
    }));
    try std.testing.expectEqual(@as(u8, 0), read_data[0]);
}

test "finite policy rejects nearby ports shapes directions and values" {
    const Case = struct { direction: Direction = .write, width: u8 = 1, port: u16 = 0x64, count: u32 = 1, value: u8 = 0xfe, data_len: usize = 1 };
    const cases = [_]Case{
        .{ .port = 0x63 },
        .{ .port = 0x65 },
        .{ .width = 2 },
        .{ .width = 4 },
        .{ .count = 2 },
        .{ .value = 0xff },
        .{ .direction = .read, .port = 0x70, .value = 0 },
        .{ .direction = .read, .port = 0x71, .value = 0 },
        .{ .port = 0x70, .value = 0x8f },
        .{ .port = 0x71, .value = 0x01 },
        .{ .port = 0x80, .value = 0x01 },
        .{ .data_len = 0 },
    };
    for (cases) |case| {
        var storage = [4]u8{ case.value, 0, 0, 0 };
        try std.testing.expectError(error.UnsupportedPio, handle(.{
            .direction = case.direction,
            .width = case.width,
            .port = case.port,
            .count = case.count,
            .data = storage[0..case.data_len],
        }));
    }
}

fn fuzzFinitePolicy(_: void, smith: *std.testing.Smith) !void {
    var storage: [8]u8 = undefined;
    const data = storage[0..smith.slice(&storage)];
    const direction: Direction = if (smith.value(bool)) .read else .write;
    const width = smith.value(u8);
    const port = smith.value(u16);
    const count = smith.value(u32);
    const action = handle(.{
        .direction = direction,
        .width = width,
        .port = port,
        .count = count,
        .data = data,
    }) catch return;

    try std.testing.expectEqual(@as(u8, 1), width);
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectEqual(@as(usize, 1), data.len);
    switch (direction) {
        .read => {
            try std.testing.expectEqual(@as(u16, 0x64), port);
            try std.testing.expectEqual(Action.continue_guest, action);
            try std.testing.expectEqual(@as(u8, 0), data[0]);
        },
        .write => switch (port) {
            0x64 => {
                try std.testing.expectEqual(@as(u8, 0xfe), data[0]);
                try std.testing.expectEqual(Action.guest_reset, action);
            },
            0x70 => try std.testing.expectEqual(@as(u8, 0x0f), data[0]),
            0x71 => try std.testing.expect(data[0] == 0x0a or data[0] == 0x00),
            0x80 => try std.testing.expectEqual(@as(u8, 0), data[0]),
            else => return error.TestUnexpectedResult,
        },
    }
}

test "fuzz finite x86 PIO policy" {
    try std.testing.fuzz({}, fuzzFinitePolicy, .{});
}
