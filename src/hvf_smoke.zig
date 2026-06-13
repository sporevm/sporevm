//! HVF bring-up smoke test.
//!
//! Proves the Hypervisor.framework path end to end on an Apple Silicon host:
//! create a VM, map guest memory, execute real aarch64 instructions on a
//! vCPU, and observe a controlled exit with the expected register state.
//!
//! Run via `zig build hvf-smoke` (handles entitlement signing).

const std = @import("std");
const hvf = @import("sporevm").hvf;

const guest_base: u64 = 0x8000_0000;
const mem_size: usize = 0x10000; // 64 KiB

// mov x0, #7 ; add x0, x0, #35 ; brk #0
const code = [_]u32{
    0xD28000E0, // movz x0, #7
    0x91008C00, // add  x0, x0, #35
    0xD4200000, // brk  #0
};

pub fn main(init: std.process.Init) !void {
    _ = init;

    try hvf.check(hvf.hv_vm_create(null), "hv_vm_create");
    defer _ = hvf.hv_vm_destroy();

    // Guest memory must be page-aligned host memory we own.
    const mem = try std.posix.mmap(
        null,
        mem_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(mem);

    @memcpy(mem[0 .. code.len * 4], std.mem.sliceAsBytes(&code));

    try hvf.check(
        hvf.hv_vm_map(mem.ptr, guest_base, mem_size, hvf.MemoryFlags.rwx),
        "hv_vm_map",
    );

    var vcpu: hvf.VcpuHandle = undefined;
    var exit: *hvf.VcpuExit = undefined;
    try hvf.check(hvf.hv_vcpu_create(&vcpu, &exit, null), "hv_vcpu_create");
    defer _ = hvf.hv_vcpu_destroy(vcpu);

    // EL1h, DAIF masked — same initial PSTATE a kernel entry expects.
    try hvf.check(hvf.hv_vcpu_set_reg(vcpu, .cpsr, 0x3c5), "set cpsr");
    try hvf.check(hvf.hv_vcpu_set_reg(vcpu, .pc, guest_base), "set pc");
    try hvf.check(hvf.hv_vcpu_set_trap_debug_exceptions(vcpu, true), "trap debug");

    try hvf.check(hvf.hv_vcpu_run(vcpu), "hv_vcpu_run");

    if (exit.reason != .exception) {
        std.log.err("unexpected exit reason: {}", .{exit.reason});
        return error.UnexpectedExit;
    }
    const ec = exit.exception.exceptionClass();
    if (ec != hvf.ec_brk) {
        std.log.err("unexpected exception class: 0x{x} (syndrome 0x{x})", .{ ec, exit.exception.syndrome });
        return error.UnexpectedExit;
    }

    var x0: u64 = undefined;
    try hvf.check(hvf.hv_vcpu_get_reg(vcpu, .x0, &x0), "get x0");
    if (x0 != 42) {
        std.log.err("expected x0=42, got {}", .{x0});
        return error.WrongResult;
    }

    std.debug.print("hvf-smoke ok: vCPU executed guest code, x0=42, clean BRK exit\n", .{});
}
