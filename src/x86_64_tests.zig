const board = @import("x86_64/board.zig");
const boot = @import("x86_64/boot.zig");
const cpu = @import("x86_64/cpu.zig");
const cpu_profile = @import("x86_64/cpu_profile.zig");
const host_evidence = @import("x86_64/host_evidence.zig");
const kvm_boot = @import("x86_64/kvm_boot.zig");
const lifecycle = @import("x86_64/lifecycle.zig");
const mp = @import("x86_64/mp.zig");
const pio = @import("x86_64/pio.zig");
const kvm = @import("kvm/x86_64.zig");

test {
    _ = board;
    _ = boot;
    _ = cpu;
    _ = cpu_profile;
    _ = host_evidence;
    _ = kvm_boot;
    _ = lifecycle;
    _ = mp;
    _ = pio;
    _ = kvm;
}
