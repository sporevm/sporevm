//! Compile-time selection for the native Linux KVM binding.

const builtin = @import("builtin");

pub const binding = if (builtin.os.tag == .linux and builtin.cpu.arch == .aarch64)
    @import("kvm.zig")
else if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64)
    @import("x86_64.zig")
else
    struct {};
