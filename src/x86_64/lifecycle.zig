//! Classified x86 guest lifecycle causes with their raw exit evidence.

const std = @import("std");
const kvm = @import("../kvm/x86_64.zig");

pub const Outcome = enum { guest_reset, guest_off };

pub const Cause = union(enum) {
    pio_reset: struct {
        exit_reason: u32,
        width: u8,
        port: u16,
        count: u32,
        value: u8,
    },
    board_poweroff: struct {
        exit_reason: u32,
        gpa: u64,
        offset: u64,
        len: u32,
        value: u64,
    },
    system_event_reset: struct { exit_reason: u32 },
    system_event_shutdown: struct { exit_reason: u32 },

    pub fn outcome(self: Cause) Outcome {
        return switch (self) {
            .pio_reset, .system_event_reset => .guest_reset,
            .board_poweroff, .system_event_shutdown => .guest_off,
        };
    }
};

pub const Terminal = struct {
    vcpu_index: u8,
    cause: Cause,
};

pub fn formatEvidence(buffer: []u8, terminal: Terminal) ![]const u8 {
    return switch (terminal.cause) {
        .pio_reset => |raw| std.fmt.bufPrint(
            buffer,
            "outcome={s} vcpu={d} raw=pio exit_reason={d} direction=write width={d} port=0x{x} count={d} value=0x{x}",
            .{ @tagName(terminal.cause.outcome()), terminal.vcpu_index, raw.exit_reason, raw.width, raw.port, raw.count, raw.value },
        ),
        .board_poweroff => |raw| std.fmt.bufPrint(
            buffer,
            "outcome={s} vcpu={d} raw=board_control exit_reason={d} gpa=0x{x} offset=0x{x} len={d} value=0x{x}",
            .{ @tagName(terminal.cause.outcome()), terminal.vcpu_index, raw.exit_reason, raw.gpa, raw.offset, raw.len, raw.value },
        ),
        .system_event_reset => |raw| std.fmt.bufPrint(
            buffer,
            "outcome={s} vcpu={d} raw=system_event exit_reason={d} event_type={d}",
            .{ @tagName(terminal.cause.outcome()), terminal.vcpu_index, raw.exit_reason, kvm.KVM_SYSTEM_EVENT_RESET },
        ),
        .system_event_shutdown => |raw| std.fmt.bufPrint(
            buffer,
            "outcome={s} vcpu={d} raw=system_event exit_reason={d} event_type={d}",
            .{ @tagName(terminal.cause.outcome()), terminal.vcpu_index, raw.exit_reason, kvm.KVM_SYSTEM_EVENT_SHUTDOWN },
        ),
    };
}

test "classified lifecycle causes determine their only possible outcome" {
    try std.testing.expectEqual(Outcome.guest_reset, (Cause{ .pio_reset = .{
        .exit_reason = kvm.KVM_EXIT_IO,
        .width = 1,
        .port = 0x64,
        .count = 1,
        .value = 0xfe,
    } }).outcome());
    try std.testing.expectEqual(Outcome.guest_off, (Cause{ .board_poweroff = .{
        .exit_reason = kvm.KVM_EXIT_MMIO,
        .gpa = 0xd000_1020,
        .offset = 0x20,
        .len = 4,
        .value = 0x4646_4f50,
    } }).outcome());
    try std.testing.expectEqual(Outcome.guest_reset, (Cause{ .system_event_reset = .{
        .exit_reason = kvm.KVM_EXIT_SYSTEM_EVENT,
    } }).outcome());
    try std.testing.expectEqual(Outcome.guest_off, (Cause{ .system_event_shutdown = .{
        .exit_reason = kvm.KVM_EXIT_SYSTEM_EVENT,
    } }).outcome());
}

test "lifecycle evidence retains the stable normalized and raw strings" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "outcome=guest_reset vcpu=1 raw=pio exit_reason=2 direction=write width=1 port=0x64 count=1 value=0xfe",
        try formatEvidence(&buffer, .{ .vcpu_index = 1, .cause = .{ .pio_reset = .{
            .exit_reason = kvm.KVM_EXIT_IO,
            .width = 1,
            .port = 0x64,
            .count = 1,
            .value = 0xfe,
        } } }),
    );
    try std.testing.expectEqualStrings(
        "outcome=guest_off vcpu=0 raw=board_control exit_reason=6 gpa=0xd0001020 offset=0x20 len=4 value=0x46464f50",
        try formatEvidence(&buffer, .{ .vcpu_index = 0, .cause = .{ .board_poweroff = .{
            .exit_reason = kvm.KVM_EXIT_MMIO,
            .gpa = 0xd000_1020,
            .offset = 0x20,
            .len = 4,
            .value = 0x4646_4f50,
        } } }),
    );
    try std.testing.expectEqualStrings(
        "outcome=guest_reset vcpu=0 raw=system_event exit_reason=24 event_type=2",
        try formatEvidence(&buffer, .{ .vcpu_index = 0, .cause = .{ .system_event_reset = .{
            .exit_reason = kvm.KVM_EXIT_SYSTEM_EVENT,
        } } }),
    );
    try std.testing.expectEqualStrings(
        "outcome=guest_off vcpu=0 raw=system_event exit_reason=24 event_type=1",
        try formatEvidence(&buffer, .{ .vcpu_index = 0, .cause = .{ .system_event_shutdown = .{
            .exit_reason = kvm.KVM_EXIT_SYSTEM_EVENT,
        } } }),
    );
}
