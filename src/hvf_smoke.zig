//! HVF bring-up smoke test.
//!
//! Proves the Hypervisor.framework path end to end on an Apple Silicon host:
//! create a VM, map guest memory, execute real aarch64 instructions on a
//! vCPU, and observe a controlled exit with the expected register state.
//!
//! Run via `zig build hvf-smoke` (handles entitlement signing).

const std = @import("std");
const sporevm = @import("sporevm");
const board = sporevm.board;
const gicv3 = sporevm.gicv3;
const hvf = sporevm.hvf;

const guest_base: u64 = 0x8000_0000;
const mem_size: usize = 0x10000; // 64 KiB

// mov x0, #7 ; add x0, x0, #35 ; brk #0
const code = [_]u32{
    0xD28000E0, // movz x0, #7
    0x91008C00, // add  x0, x0, #35
    0xD4200000, // brk  #0
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const run_gic_probe = if (args.len == 1)
        false
    else if (args.len == 2 and std.mem.eql(u8, args[1], "--gic-probe"))
        true
    else {
        std.debug.print("usage: hvf-smoke [--gic-probe]\n", .{});
        return error.InvalidArguments;
    };

    try hvf.check(hvf.hv_vm_create(null), "hv_vm_create");
    defer _ = hvf.hv_vm_destroy();

    if (run_gic_probe) try createGic();

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

    if (run_gic_probe) {
        try hvf.check(hvf.hv_vcpu_set_sys_reg(vcpu, .mpidr_el1, 0x8000_0000), "set mpidr");
        try probeGic(arena, vcpu);
    }

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

fn createGic() !void {
    var dist_size: usize = 0;
    var dist_align: usize = 0;
    var redist_size: usize = 0;
    var redist_align: usize = 0;
    try hvf.check(hvf.hv_gic_get_distributor_size(&dist_size), "gic dist size");
    try hvf.check(hvf.hv_gic_get_distributor_base_alignment(&dist_align), "gic dist align");
    try hvf.check(hvf.hv_gic_get_redistributor_region_size(&redist_size), "gic redist size");
    try hvf.check(hvf.hv_gic_get_redistributor_base_alignment(&redist_align), "gic redist align");

    const dist_base: u64 = std.mem.alignForward(u64, 0x0800_0000, dist_align);
    const redist_base: u64 = std.mem.alignForward(u64, dist_base + dist_size, redist_align);

    const gic_config = hvf.hv_gic_config_create();
    defer hvf.os_release(gic_config);
    try hvf.check(hvf.hv_gic_config_set_distributor_base(gic_config, dist_base), "gic set dist base");
    try hvf.check(hvf.hv_gic_config_set_redistributor_base(gic_config, redist_base), "gic set redist base");
    try hvf.check(hvf.hv_gic_create(gic_config), "hv_gic_create");

    std.debug.print(
        "hvf-gic-probe: created GIC dist=0x{x}+0x{x} redist-region=0x{x}+0x{x}\n",
        .{ dist_base, dist_size, redist_base, redist_size },
    );
}

const ProbeCounts = struct {
    reads_ok: usize = 0,
    reads_unsupported: usize = 0,
    writebacks_ok: usize = 0,
    writebacks_unsupported: usize = 0,
};

fn probeGic(allocator: std.mem.Allocator, vcpu: hvf.VcpuHandle) !void {
    var dist_specs: std.ArrayList(gicv3.RegSpec) = .empty;
    defer dist_specs.deinit(allocator);
    var redist_specs: std.ArrayList(gicv3.RegSpec) = .empty;
    defer redist_specs.deinit(allocator);
    try gicv3.appendDistRegSpecs(allocator, &dist_specs);
    try gicv3.appendRedistRegSpecs(allocator, &redist_specs);

    const dist = probeRegion(.distributor, vcpu, dist_specs.items);
    const redist = probeRegion(.redistributor, vcpu, redist_specs.items);

    var spi_base: u32 = 0;
    var spi_count: u32 = 0;
    try hvf.check(hvf.hv_gic_get_spi_interrupt_range(&spi_base, &spi_count), "gic spi range");
    const generation_intid = board.generationIntid();
    const generation_spi_supported = generation_intid >= spi_base and generation_intid < spi_base + spi_count;
    if (generation_spi_supported) {
        try hvf.check(hvf.hv_gic_set_spi(generation_intid, false), "gic lower generation spi");
        try hvf.check(hvf.hv_gic_set_spi(generation_intid, true), "gic raise generation spi");
        try hvf.check(hvf.hv_gic_set_spi(generation_intid, false), "gic lower generation spi");
    }

    std.debug.print(
        "hvf-gic-probe: dist reads ok={d} unsupported={d}; redist reads ok={d} unsupported={d}; safe writebacks ok={d} unsupported={d}; spi_range={d}..{d}; generation_spi_set={}; line_level_getter=false; portable_capture_supported=false\n",
        .{
            dist.reads_ok,
            dist.reads_unsupported,
            redist.reads_ok,
            redist.reads_unsupported,
            dist.writebacks_ok + redist.writebacks_ok,
            dist.writebacks_unsupported + redist.writebacks_unsupported,
            spi_base,
            spi_base + spi_count,
            generation_spi_supported,
        },
    );
}

fn probeRegion(region: hvf.gic.Region, vcpu: hvf.VcpuHandle, specs: []const gicv3.RegSpec) ProbeCounts {
    var counts: ProbeCounts = .{};
    for (specs) |spec| {
        const reg = hvf.gic.readRegStrict(region, vcpu, spec) catch {
            std.debug.print("hvf-gic-probe: unsupported read {s} offset=0x{x} width={d}\n", .{ @tagName(region), spec.offset, spec.width_bits });
            counts.reads_unsupported += 1;
            continue;
        };
        counts.reads_ok += 1;

        if (!safeWriteback(region, spec)) continue;
        hvf.gic.writeRegStrict(region, vcpu, reg) catch {
            std.debug.print("hvf-gic-probe: unsupported writeback {s} offset=0x{x} width={d}\n", .{ @tagName(region), spec.offset, spec.width_bits });
            counts.writebacks_unsupported += 1;
            continue;
        };
        counts.writebacks_ok += 1;
    }
    return counts;
}

fn safeWriteback(region: hvf.gic.Region, spec: gicv3.RegSpec) bool {
    return region == .distributor and spec.width_bits == 64 and spec.offset >= gicv3.distRouterOffset(32);
}
