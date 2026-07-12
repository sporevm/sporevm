const spore = @import("spore.zig");

pub fn manifest(annotations: spore.Annotations) spore.Manifest {
    return .{
        .annotations = annotations,
        .platform = .{
            .cpu_profile = "sporevm-aarch64-v0",
            .device_model_version = 4,
            .ram_base = 0x8000_0000,
            .ram_size = 1,
            .gic_dist_base = 0x0800_0000,
            .gic_redist_base = 0x0801_0000,
            .counter_frequency_hz = 24_000_000,
        },
        .machine = .{
            .gprs = [_]u64{0} ** 31,
            .pc = 0,
            .cpsr = 0,
            .fpcr = 0,
            .fpsr = 0,
            .simd = [_][2]u64{.{ 0, 0 }} ** 32,
            .sys_regs = &.{},
            .icc_regs = &.{},
            .vtimer = .{ .cntvct = 0, .cntv_ctl = 0, .cntv_cval = 0 },
            .gic = .{
                .kind = .gicv3,
                .gicv3 = .{
                    .dist_regs = &.{},
                    .redist_regs = &.{},
                    .line_levels = &.{},
                },
            },
        },
        .devices = &.{},
        .generation = .{ .generation = 0, .interrupt_status = 0, .params_b64 = "" },
        .sessions = &sessions,
        .memory = .{ .logical_size = 1, .chunk_size = spore.chunk_size, .zero_chunks = &.{0} },
    };
}

const sessions = [_]spore.Session{.{
    .id = spore.default_session_id,
    .streams = .{
        .stdout = false,
        .stderr = false,
        .terminal = true,
    },
}};
