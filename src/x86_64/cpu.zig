//! Reusable initial x86 protected-mode CPU state for Linux direct boot.

const std = @import("std");
const kvm = @import("../kvm/x86_64.zig");
const board = @import("board.zig");
const boot = @import("boot.zig");

pub const ProtectedModeState = struct {
    regs: kvm.Regs,
    sregs: kvm.Sregs,
};

pub fn protectedModeState(initial_sregs: kvm.Sregs, entry: u64, boot_params: u64) ProtectedModeState {
    var sregs = initial_sregs;
    sregs.cs = flatSegment(boot.boot_code_selector, 0xb);
    const data = flatSegment(boot.boot_data_selector, 0x3);
    sregs.ds = data;
    sregs.es = data;
    sregs.fs = data;
    sregs.gs = data;
    sregs.ss = data;
    sregs.gdt = .{ .base = board.gdt_addr, .limit = boot.gdt.len - 1 };
    sregs.idt = .{};
    sregs.cr0 |= 1; // PE: Linux's 32-bit boot protocol enters protected mode.

    return .{
        .regs = .{
            .rsi = boot_params,
            .rip = entry,
            .rflags = 2,
        },
        .sregs = sregs,
    };
}

fn flatSegment(selector: u16, segment_type: u8) kvm.Segment {
    return .{
        .base = 0,
        .limit = std.math.maxInt(u32),
        .selector = selector,
        .type = segment_type,
        .present = 1,
        .dpl = 0,
        .db = 1,
        .s = 1,
        .l = 0,
        .g = 1,
        .avl = 0,
        .unusable = 0,
    };
}

test "protected-mode state matches the Linux 32-bit boot protocol" {
    var initial_sregs = std.mem.zeroes(kvm.Sregs);
    initial_sregs.apic_base = 0xfee0_0900;
    const state = protectedModeState(initial_sregs, 0x0010_0000, 0x0000_7000);

    try std.testing.expectEqual(@as(u16, boot.boot_code_selector), state.sregs.cs.selector);
    try std.testing.expectEqual(@as(u8, 0xb), state.sregs.cs.type);
    try std.testing.expectEqual(@as(u16, boot.boot_data_selector), state.sregs.ds.selector);
    try std.testing.expectEqual(@as(u8, 0x3), state.sregs.ds.type);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), state.sregs.cs.limit);
    try std.testing.expectEqual(board.gdt_addr, state.sregs.gdt.base);
    try std.testing.expectEqual(@as(u64, 0xfee0_0900), state.sregs.apic_base);
    try std.testing.expectEqual(@as(u64, 1), state.sregs.cr0 & 1);
    try std.testing.expectEqual(@as(u64, 0x0010_0000), state.regs.rip);
    try std.testing.expectEqual(@as(u64, 0x0000_7000), state.regs.rsi);
}
