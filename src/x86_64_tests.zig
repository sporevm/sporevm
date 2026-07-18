const board = @import("x86_64/board.zig");
const boot = @import("x86_64/boot.zig");
const cpu = @import("x86_64/cpu.zig");
const kvm_boot = @import("x86_64/kvm_boot.zig");
const kvm = @import("kvm/x86_64.zig");

test {
    _ = board;
    _ = boot;
    _ = cpu;
    _ = kvm_boot;
    _ = kvm;
}
