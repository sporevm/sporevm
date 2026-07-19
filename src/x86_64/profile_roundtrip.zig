//! Host-only Stage 0b.3 candidate profile process-boundary proof.

const std = @import("std");
const linux = std.os.linux;
const Sha256 = std.crypto.hash.sha2.Sha256;
const board = @import("board.zig");
const boot = @import("boot.zig");
const cpu = @import("cpu.zig");
const cpu_profile = @import("cpu_profile.zig");
const kvm = @import("../kvm/x86_64.zig");
const mailbox = @import("profile_mailbox.zig");
const pio = @import("pio.zig");
const state_file = @import("profile_roundtrip_state.zig");

const ram_size: usize = 64 * 1024 * 1024;
const board_vcpu_count: u8 = 2;
const max_boot_file = 256 * 1024 * 1024;
const msr_capacity = 256;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len == 5 and std.mem.eql(u8, args[1], "capture")) {
        return capture(allocator, init.io, args[2], args[3], args[4]);
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "restore")) {
        return restore(allocator, init.io, args[2]);
    }
    usageExit();
}

const Machine = struct {
    kvm_fd: std.c.fd_t,
    vm_fd: std.c.fd_t,
    vcpu_fds: [board_vcpu_count]std.c.fd_t,
    run: []align(std.heap.page_size_min) u8,
    ram: []align(std.heap.page_size_min) u8,
    mailbox_page: []align(std.heap.page_size_min) u8,
    cpuid: [board_vcpu_count]kvm.Cpuid,
    xsave_size: usize,

    fn deinit(self: *Machine) void {
        std.posix.munmap(self.run);
        for (self.vcpu_fds) |fd| _ = std.c.close(fd);
        std.posix.munmap(self.mailbox_page);
        std.posix.munmap(self.ram);
        _ = std.c.close(self.vm_fd);
        _ = std.c.close(self.kvm_fd);
    }
};

fn capture(allocator: std.mem.Allocator, io: std.Io, kernel_path: []const u8, initrd_path: []const u8, output_path: []const u8) !void {
    const kernel = try std.Io.Dir.cwd().readFileAlloc(io, kernel_path, allocator, .limited(max_boot_file));
    const initrd = try std.Io.Dir.cwd().readFileAlloc(io, initrd_path, allocator, .limited(max_boot_file));
    var nonce_bytes: [8]u8 = undefined;
    io.random(&nonce_bytes);
    const nonce = std.mem.readInt(u64, &nonce_bytes, .little);
    const cmdline = try std.fmt.allocPrint(allocator, "rdinit=/init maxcpus=1 nox2apic panic=-1 sporevm.profile_nonce={x:0>16}", .{nonce});

    var machine = try createFreshMachine(kernel, initrd, cmdline);
    defer machine.deinit();
    const result = try runUntilDoorbell(&machine, .capture_ready, nonce);
    _ = try kvm.ioctl(machine.vcpu_fds[0], kvm.KVM_KVMCLOCK_CTRL, 0, "KVM_KVMCLOCK_CTRL capture");
    try requireApReset(&machine);

    var state = try captureState(allocator, &machine);
    defer state.deinit(allocator);
    try validateCandidateState(&state);
    std.debug.print("sporevm kvm-profile-roundtrip: captured bsp_xstate_bv=0x{x} ap_xstate_bv=0x{x} bsp_xsave_bytes={d} ap_xsave_bytes={d}\n", .{ state.vcpus[0].xstate_bv, state.vcpus[1].xstate_bv, state.vcpus[0].xsave.len, state.vcpus[1].xsave.len });
    std.debug.print("sporevm kvm-profile-roundtrip: machine bsp_mp={d} ap_mp={d} bsp_event_flags=0x{x} ap_event_flags=0x{x} bsp_shadow={d} ap_shadow={d} bsp_lapic_svr=0x{x} ap_lapic_svr=0x{x} ioapic_base=0x{x} pit0_mode={d} pit0_count={d}\n", .{
        state.vcpus[0].mp_state,                state.vcpus[1].mp_state,                state.vcpus[0].events.flags,  state.vcpus[1].events.flags,
        state.vcpus[0].events.interrupt_shadow, state.vcpus[1].events.interrupt_shadow, state.vcpus[0].lapic.svr,     state.vcpus[1].lapic.svr,
        state.ioapic.base_address,              state.pit2.channels[0].mode,            state.pit2.channels[0].count,
    });
    const capture_message = try mailbox.decode(@ptrCast(machine.mailbox_page.ptr), .capture_ready, nonce);
    if (capture_message.capture_tsc != result.capture_tsc) return error.MailboxChangedAfterBarrier;
    const encoded = try state_file.encode(allocator, &state);
    try writePrivateExclusive(allocator, output_path, encoded);
    const digest = sha256(encoded);
    std.debug.print("sporevm kvm-profile-roundtrip: phase=capture pid={d} nonce={x:0>16} state_bytes={d} state_sha256={s} xsave_bytes={d} msrs={d} capture_tsc={d} monotonic_ns={d} boottime_ns={d} realtime_ns={d} complete=true\n", .{
        linux.getpid(),                             nonce,                                      encoded.len,                                &digest, state.vcpus[0].xsave.len, state.vcpus[0].msrs.len, capture_message.capture_tsc,
        clockNs(capture_message.capture_clocks[0]), clockNs(capture_message.capture_clocks[1]), clockNs(capture_message.capture_clocks[2]),
    });
}

fn restore(allocator: std.mem.Allocator, io: std.Io, input_path: []const u8) !void {
    _ = io;
    const encoded = try readPrivateState(allocator, input_path);
    var state = try state_file.decode(allocator, encoded);
    defer state.deinit(allocator);
    try validateCandidateState(&state);
    const capture_message = try mailbox.decode(&state.mailbox, .capture_ready, std.mem.readInt(u64, state.mailbox[24..32], .little));

    var machine = try createRestoredMachine(&state);
    defer machine.deinit();
    try requireApReset(&machine);
    try compareRestoredState(allocator, &machine, &state);
    const restored_message = try runUntilDoorbell(&machine, .restored_ready, capture_message.nonce);
    try mailbox.validateRestored(capture_message, restored_message);
    std.debug.print("sporevm kvm-profile-roundtrip: phase=restore pid={d} nonce={x:0>16} capture_tsc={d} restored_tsc={d} monotonic_ns={d} boottime_ns={d} realtime_ns={d} complete=true\n", .{
        linux.getpid(),                               capture_message.nonce,                        capture_message.capture_tsc,                  restored_message.restored_tsc,
        clockNs(restored_message.restored_clocks[0]), clockNs(restored_message.restored_clocks[1]), clockNs(restored_message.restored_clocks[2]),
    });
}

fn validateCandidateState(state: *const state_file.State) !void {
    if (state.ram.len != ram_size) return error.UnexpectedCandidateState;
    if (state.clock.flags != cpu_profile.capture_clock_flags) return error.UnexpectedClockFlags;
    for (state.vcpus, 0..) |vcpu, index| try validateCandidateVcpu(vcpu, @intCast(index));
    if (state.vcpus[0].mp_state != kvm.KVM_MP_STATE_RUNNABLE or state.vcpus[1].mp_state != kvm.KVM_MP_STATE_UNINITIALIZED) return error.UnexpectedMpState;
    for (state.vcpus) |vcpu| {
        if (vcpu.events.smm != 0 or vcpu.events.pending_smi != 0 or vcpu.events.smm_inside_nmi != 0 or vcpu.events.latched_init != 0 or vcpu.events.triple_fault_pending != 0) return error.UnsupportedVcpuEvent;
        if (vcpu.events.flags & kvm.KVM_VCPUEVENT_VALID_SHADOW == 0 or vcpu.events.flags & kvm.KVM_VCPUEVENT_VALID_PAYLOAD == 0) return error.IncompleteVcpuEventState;
    }
    if (state.ioapic.base_address == 0) return error.ResetDeviceState;
    for (state.vcpus) |vcpu| if (vcpu.lapic.version == 0 or vcpu.lapic.svr == 0) return error.ResetDeviceState;
}

fn validateCandidateVcpu(vcpu: state_file.VcpuMachineState, index: u8) !void {
    if (vcpu.cpuid.len == 0 or vcpu.xcomp_bv != 0 or
        vcpu.xcrs.len != 1 or vcpu.xcrs[0].index != 0 or vcpu.xcrs[0].value & 1 == 0 or
        vcpu.xcrs[0].value & ~cpu_profile.xcr0 != 0 or vcpu.xstate_bv & ~vcpu.xcrs[0].value != 0 or
        vcpu.tsc_khz != cpu_profile.guest_tsc_khz) return error.UnexpectedCandidateState;
    var saw_xsave_layout = false;
    var saw_ymm_layout = false;
    for (vcpu.cpuid) |entry| {
        if (entry.function == 7) {
            const ebx = if (entry.index == 0) @as(u32, 1) << 1 else 0;
            if (entry.eax != 0 or entry.ebx != ebx or entry.ecx != 0 or entry.edx != 0) return error.UnexpectedCandidateState;
        } else if (entry.function == 0x0d) switch (entry.index) {
            0 => {
                saw_xsave_layout = true;
                if (entry.eax != @as(u32, @intCast(cpu_profile.xcr0)) or entry.ebx != cpu_profile.architectural_xsave_bytes or entry.ecx != cpu_profile.architectural_xsave_bytes or entry.edx != 0) return error.UnexpectedCandidateState;
            },
            2 => {
                saw_ymm_layout = true;
                if (entry.eax != 256 or entry.ebx != 576 or entry.ecx != 0 or entry.edx != 0) return error.UnexpectedCandidateState;
            },
            else => if (entry.eax != 0 or entry.ebx != 0 or entry.ecx != 0 or entry.edx != 0) return error.UnexpectedCandidateState,
        };
    }
    if (!saw_xsave_layout or !saw_ymm_layout) return error.UnexpectedCandidateState;
    const expected_cpuid = try cpu_profile.candidateCpuid(board_vcpu_count, index);
    const observed_cpuid = try stateCpuidToKvm(vcpu.cpuid);
    if (!cpuidSetEqual(&expected_cpuid, &observed_cpuid)) return error.UnexpectedCandidateCpuid;
    for (vcpu.msrs) |value| {
        var allowed = false;
        for (cpu_profile.candidate_msrs) |descriptor| {
            if (descriptor.index == value.index) allowed = true;
        }
        if (!allowed) return error.UnexpectedCandidateState;
    }
    for (cpu_profile.candidate_msrs) |descriptor| {
        var present = false;
        for (vcpu.msrs) |value| if (value.index == descriptor.index) {
            present = true;
        };
        if (!present) return error.RequiredMsrMissing;
    }
}

fn createFreshMachine(kernel: []const u8, initrd: []const u8, cmdline: []const u8) !Machine {
    var machine = try createBaseMachine(null);
    errdefer machine.deinit();
    _ = try boot.load(machine.ram, kernel, initrd, cmdline, board_vcpu_count);
    try configureProtectedMode(machine.vcpu_fds[0], try boot.plan(kernel, initrd.len, cmdline, ram_size, board_vcpu_count));
    try requireApReset(&machine);
    return machine;
}

fn createRestoredMachine(state: *const state_file.State) !Machine {
    if (state.ram.len != ram_size) return error.UnexpectedRamSize;
    var machine = try createBaseMachine(state);
    errdefer machine.deinit();
    @memcpy(machine.ram, state.ram);
    @memcpy(machine.mailbox_page, &state.mailbox);
    try applyVmState(&machine, state);
    try applyCpuState(&machine, state);
    return machine;
}

fn createBaseMachine(saved: ?*const state_file.State) !Machine {
    const kvm_fd = try kvm.openDevKvm();
    errdefer _ = std.c.close(kvm_fd);
    try kvm.checkApiVersion(kvm_fd);
    for (cpu_profile.required_capabilities) |required| {
        const value = try kvm.checkExtension(kvm_fd, required.id);
        if (value < required.minimum or value & required.required_bits != required.required_bits) {
            std.debug.print("sporevm kvm-profile-roundtrip: required capability {s} ({d}) value={d} required_bits=0x{x}\n", .{ required.name, required.id, value, required.required_bits });
            return error.RequiredCapabilityMissing;
        }
    }
    const vm_fd: std.c.fd_t = @intCast(try kvm.ioctl(kvm_fd, kvm.KVM_CREATE_VM, 0, "KVM_CREATE_VM"));
    errdefer _ = std.c.close(vm_fd);
    var exception_payload = kvm.EnableCap{ .cap = kvm.KVM_CAP_EXCEPTION_PAYLOAD, .args = .{ 1, 0, 0, 0 } };
    _ = try kvm.ioctl(vm_fd, kvm.KVM_ENABLE_CAP, @intFromPtr(&exception_payload), "KVM_ENABLE_CAP exception payload");
    const tsc_khz = if (saved) |value| value.vcpus[0].tsc_khz else cpu_profile.guest_tsc_khz;
    if (tsc_khz != cpu_profile.guest_tsc_khz) return error.UnexpectedTscFrequency;
    _ = try kvm.ioctl(vm_fd, kvm.KVM_SET_TSC_KHZ, tsc_khz, "KVM_SET_TSC_KHZ VM before vCPUs");
    _ = try kvm.ioctl(vm_fd, kvm.KVM_SET_TSS_ADDR, board.tss_addr, "KVM_SET_TSS_ADDR");
    var identity = board.identity_map_addr;
    _ = try kvm.ioctl(vm_fd, kvm.KVM_SET_IDENTITY_MAP_ADDR, @intFromPtr(&identity), "KVM_SET_IDENTITY_MAP_ADDR");
    _ = try kvm.ioctl(vm_fd, kvm.KVM_CREATE_IRQCHIP, 0, "KVM_CREATE_IRQCHIP");
    var pit = kvm.PitConfig{};
    _ = try kvm.ioctl(vm_fd, kvm.KVM_CREATE_PIT2, @intFromPtr(&pit), "KVM_CREATE_PIT2");
    const xsave_size = blk: {
        const size = try kvm.checkExtension(vm_fd, kvm.KVM_CAP_XSAVE2);
        break :blk if (size == 0) @sizeOf(kvm.Xsave) else size;
    };
    if (xsave_size > state_file.max_xsave_bytes) return error.XsaveTooLarge;

    const ram = try mapAnonymous(ram_size);
    errdefer std.posix.munmap(ram);
    const mailbox_page = try mapAnonymous(mailbox.page_size);
    errdefer std.posix.munmap(mailbox_page);
    @memset(ram, 0);
    @memset(mailbox_page, 0);
    try installMemslot(vm_fd, 0, 0, ram);
    try installMemslot(vm_fd, 1, mailbox.mailbox_gpa, mailbox_page);

    var cpuid: [board_vcpu_count]kvm.Cpuid = undefined;
    var fds: [board_vcpu_count]std.c.fd_t = @splat(-1);
    var created: usize = 0;
    errdefer {
        for (fds[0..created]) |fd| _ = std.c.close(fd);
    }
    while (created < board_vcpu_count) : (created += 1) {
        fds[created] = @intCast(try kvm.ioctl(vm_fd, kvm.KVM_CREATE_VCPU, created, "KVM_CREATE_VCPU"));
        cpuid[created] = try cpu_profile.candidateCpuid(board_vcpu_count, @intCast(created));
        if (saved) |value| {
            const saved_cpuid = try stateCpuidToKvm(value.vcpus[created].cpuid);
            if (!cpuidSetEqual(&cpuid[created], &saved_cpuid)) return error.SavedCpuidMismatch;
        }
        _ = try kvm.ioctl(fds[created], kvm.KVM_SET_CPUID2, @intFromPtr(&cpuid[created]), "KVM_SET_CPUID2");
    }
    const run_size = try kvm.ioctl(kvm_fd, kvm.KVM_GET_VCPU_MMAP_SIZE, 0, "KVM_GET_VCPU_MMAP_SIZE");
    if (run_size < kvm.RunLayout.mmio_end) return error.KvmRunMappingTooSmall;
    const run = try std.posix.mmap(null, run_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fds[0], 0);
    errdefer std.posix.munmap(run);
    if (!try kvm.hasTscOffset(fds[0])) return error.TscOffsetUnavailable;
    return .{ .kvm_fd = kvm_fd, .vm_fd = vm_fd, .vcpu_fds = fds, .run = run, .ram = ram, .mailbox_page = mailbox_page, .cpuid = cpuid, .xsave_size = xsave_size };
}

fn applyCpuState(machine: *Machine, state: *const state_file.State) !void {
    for (machine.vcpu_fds, state.vcpus) |fd, vcpu| {
        const sregs = stateSregsToKvm(vcpu.sregs);
        _ = try kvm.ioctl(fd, kvm.KVM_SET_SREGS, @intFromPtr(&sregs), "KVM_SET_SREGS restore");
        var xcrs = stateXcrsToKvm(vcpu.xcrs);
        _ = try kvm.ioctl(fd, kvm.KVM_SET_XCRS, @intFromPtr(&xcrs), "KVM_SET_XCRS restore");
        var xsave_transfer: [state_file.max_xsave_bytes]u8 = @splat(0);
        @memcpy(xsave_transfer[0..vcpu.xsave.len], vcpu.xsave);
        const xsave = try kvm.xsave2Buffer(&xsave_transfer, machine.xsave_size);
        _ = try kvm.ioctl(fd, kvm.KVM_SET_XSAVE, @intFromPtr(xsave.ptr), "KVM_SET_XSAVE restore");
        _ = try kvm.ioctl(fd, kvm.KVM_SET_TSC_KHZ, vcpu.tsc_khz, "KVM_SET_TSC_KHZ restore");
        try restoreMsrs(fd, vcpu.msrs);
        try kvm.setTscOffset(fd, @bitCast(vcpu.tsc_offset));
        var regs = stateGprsToKvm(vcpu.gprs);
        _ = try kvm.ioctl(fd, kvm.KVM_SET_REGS, @intFromPtr(&regs), "KVM_SET_REGS restore");
        var lapic = stateLapicToKvm(vcpu.lapic);
        _ = try kvm.ioctl(fd, kvm.KVM_SET_LAPIC, @intFromPtr(&lapic), "KVM_SET_LAPIC restore");
        var debug = stateDebugToKvm(vcpu.debug);
        _ = try kvm.ioctl(fd, kvm.KVM_SET_DEBUGREGS, @intFromPtr(&debug), "KVM_SET_DEBUGREGS restore");
        var events = try stateEventsToKvm(vcpu.events);
        _ = try kvm.ioctl(fd, kvm.KVM_SET_VCPU_EVENTS, @intFromPtr(&events), "KVM_SET_VCPU_EVENTS restore");
        var mp = kvm.MpState{ .mp_state = vcpu.mp_state };
        _ = try kvm.ioctl(fd, kvm.KVM_SET_MP_STATE, @intFromPtr(&mp), "KVM_SET_MP_STATE restore");
    }
    var clock = stateClockToKvm(state.clock);
    _ = try kvm.ioctl(machine.vm_fd, kvm.KVM_SET_CLOCK, @intFromPtr(&clock), "KVM_SET_CLOCK restore");
    _ = try kvm.ioctl(machine.vcpu_fds[0], kvm.KVM_KVMCLOCK_CTRL, 0, "KVM_KVMCLOCK_CTRL restore");
}

fn captureState(allocator: std.mem.Allocator, machine: *Machine) !state_file.State {
    var clock: kvm.ClockData = .{};
    _ = try kvm.ioctl(machine.vm_fd, kvm.KVM_GET_CLOCK, @intFromPtr(&clock), "KVM_GET_CLOCK capture");
    var vcpus: [board_vcpu_count]state_file.VcpuMachineState = undefined;
    var captured: usize = 0;
    errdefer for (&vcpus, 0..) |*vcpu, index| {
        if (index >= captured) break;
        vcpu.deinit(allocator);
    };
    while (captured < board_vcpu_count) : (captured += 1) {
        vcpus[captured] = try captureVcpuMachineState(allocator, machine, captured);
    }
    const pic_master = try capturePic(machine.vm_fd, kvm.KVM_IRQCHIP_PIC_MASTER);
    const pic_slave = try capturePic(machine.vm_fd, kvm.KVM_IRQCHIP_PIC_SLAVE);
    const ioapic = try captureIoapic(machine.vm_fd);
    var pit_raw = kvm.PitState2{};
    _ = try kvm.ioctl(machine.vm_fd, kvm.KVM_GET_PIT2, @intFromPtr(&pit_raw), "KVM_GET_PIT2 capture");
    for (pit_raw.reserved) |word| if (word != 0) return error.UnsupportedPitState;
    const ram = try allocator.dupe(u8, machine.ram);
    errdefer allocator.free(ram);
    return .{
        .clock = kvmClockToState(clock),
        .vcpus = vcpus,
        .pic_master = pic_master,
        .pic_slave = pic_slave,
        .ioapic = ioapic,
        .pit2 = kvmPitToState(pit_raw),
        .mailbox = machine.mailbox_page[0..mailbox.page_size].*,
        .ram = ram,
    };
}

fn applyVmState(machine: *Machine, state: *const state_file.State) !void {
    var master = statePicToKvm(kvm.KVM_IRQCHIP_PIC_MASTER, state.pic_master);
    _ = try kvm.ioctl(machine.vm_fd, kvm.KVM_SET_IRQCHIP, @intFromPtr(&master), "KVM_SET_IRQCHIP PIC master");
    var slave = statePicToKvm(kvm.KVM_IRQCHIP_PIC_SLAVE, state.pic_slave);
    _ = try kvm.ioctl(machine.vm_fd, kvm.KVM_SET_IRQCHIP, @intFromPtr(&slave), "KVM_SET_IRQCHIP PIC slave");
    var ioapic = stateIoapicToKvm(state.ioapic);
    _ = try kvm.ioctl(machine.vm_fd, kvm.KVM_SET_IRQCHIP, @intFromPtr(&ioapic), "KVM_SET_IRQCHIP IOAPIC");
    var pit = statePitToKvm(state.pit2);
    _ = try kvm.ioctl(machine.vm_fd, kvm.KVM_SET_PIT2, @intFromPtr(&pit), "KVM_SET_PIT2 restore");
}

fn captureVcpuMachineState(allocator: std.mem.Allocator, machine: *Machine, index: usize) !state_file.VcpuMachineState {
    const fd = machine.vcpu_fds[index];
    var regs: kvm.Regs = undefined;
    _ = try kvm.ioctl(fd, kvm.KVM_GET_REGS, @intFromPtr(&regs), "KVM_GET_REGS capture");
    var sregs: kvm.Sregs = undefined;
    _ = try kvm.ioctl(fd, kvm.KVM_GET_SREGS, @intFromPtr(&sregs), "KVM_GET_SREGS capture");
    var xcrs_raw = kvm.Xcrs{};
    _ = try kvm.ioctl(fd, kvm.KVM_GET_XCRS, @intFromPtr(&xcrs_raw), "KVM_GET_XCRS capture");
    const xcrs = try kvmXcrsToState(allocator, &xcrs_raw);
    errdefer allocator.free(xcrs);
    var effective = kvm.Cpuid{};
    _ = try kvm.ioctl(fd, kvm.KVM_GET_CPUID2, @intFromPtr(&effective), "KVM_GET_CPUID2 capture");
    if (!effectiveCpuidMatches(&machine.cpuid[index], &effective, sregs, xcrs)) {
        logCpuidDifference(index, &machine.cpuid[index], &effective);
        return error.EffectiveCpuidMismatch;
    }
    const cpuid = try kvmCpuidToState(allocator, &machine.cpuid[index]);
    errdefer allocator.free(cpuid);
    const xsave_transfer_storage = try allocator.alloc(u8, machine.xsave_size);
    defer allocator.free(xsave_transfer_storage);
    @memset(xsave_transfer_storage, 0);
    const xsave_transfer = try kvm.xsave2Buffer(xsave_transfer_storage, machine.xsave_size);
    const get_xsave = if (machine.xsave_size == @sizeOf(kvm.Xsave)) kvm.KVM_GET_XSAVE else kvm.KVM_GET_XSAVE2;
    _ = try kvm.ioctl(fd, get_xsave, @intFromPtr(xsave_transfer.ptr), "KVM_GET_XSAVE capture");
    const xstate_bv = readInt(u64, xsave_transfer, 512);
    const xcomp_bv = readInt(u64, xsave_transfer, 520);
    try state_file.validateXsaveBytes(xsave_transfer[0..state_file.xsave_avx_end], xstate_bv, xcomp_bv);
    for (xsave_transfer[state_file.xsave_avx_end..]) |byte| if (byte != 0) return error.NonzeroXsavePadding;
    const xsave = try allocator.dupe(u8, xsave_transfer[0..state_file.xsave_avx_end]);
    errdefer allocator.free(xsave);
    const msrs = try captureMsrs(allocator, machine.kvm_fd, fd);
    errdefer allocator.free(msrs);
    var lapic = kvm.LapicState{};
    _ = try kvm.ioctl(fd, kvm.KVM_GET_LAPIC, @intFromPtr(&lapic), "KVM_GET_LAPIC capture");
    var events = kvm.VcpuEvents{};
    _ = try kvm.ioctl(fd, kvm.KVM_GET_VCPU_EVENTS, @intFromPtr(&events), "KVM_GET_VCPU_EVENTS capture");
    var debug = kvm.DebugRegs{};
    _ = try kvm.ioctl(fd, kvm.KVM_GET_DEBUGREGS, @intFromPtr(&debug), "KVM_GET_DEBUGREGS capture");
    return .{
        .cpuid = cpuid,
        .gprs = kvmGprsToState(regs),
        .sregs = kvmSregsToState(sregs),
        .xcrs = xcrs,
        .xsave = xsave,
        .xstate_bv = xstate_bv,
        .xcomp_bv = xcomp_bv,
        .msrs = msrs,
        .tsc_khz = try positiveIoctl(fd, kvm.KVM_GET_TSC_KHZ, "KVM_GET_TSC_KHZ capture"),
        .tsc_offset = @bitCast(try kvm.getTscOffset(fd)),
        .mp_state = (try kvm.getMpState(fd)).mp_state,
        .lapic = kvmLapicToState(lapic),
        .events = try kvmEventsToState(events),
        .debug = try kvmDebugToState(debug),
    };
}

fn capturePic(vm_fd: std.c.fd_t, chip_id: u32) !state_file.Pic {
    var chip = kvm.Irqchip{ .chip_id = chip_id };
    _ = try kvm.ioctl(vm_fd, kvm.KVM_GET_IRQCHIP, @intFromPtr(&chip), "KVM_GET_IRQCHIP PIC capture");
    if (chip.padding != 0) return error.UnsupportedIrqchipState;
    return kvmPicToState(chip.chip.pic);
}

fn captureIoapic(vm_fd: std.c.fd_t) !state_file.Ioapic {
    var chip = kvm.Irqchip{ .chip_id = kvm.KVM_IRQCHIP_IOAPIC };
    _ = try kvm.ioctl(vm_fd, kvm.KVM_GET_IRQCHIP, @intFromPtr(&chip), "KVM_GET_IRQCHIP IOAPIC capture");
    if (chip.padding != 0 or chip.chip.ioapic.padding != 0) return error.UnsupportedIrqchipState;
    return kvmIoapicToState(chip.chip.ioapic);
}

fn runUntilDoorbell(machine: *Machine, phase: mailbox.Phase, nonce: u64) !mailbox.Message {
    while (true) {
        const result = try kvm.runVcpu(machine.vcpu_fds[0]);
        if (result != .completed) continue;
        switch (kvm.exitReason(machine.run)) {
            kvm.KVM_EXIT_IO => {
                const exit = try kvm.decodeIoExit(machine.run);
                const action = pio.handle(.{
                    .direction = if (exit.direction == .read) .read else .write,
                    .width = exit.width,
                    .port = exit.port,
                    .count = exit.count,
                    .data = exit.data,
                }) catch |err| {
                    std.debug.print("sporevm kvm-profile-roundtrip: rejected PIO direction={s} width={d} port=0x{x} count={d} data={any}\n", .{ @tagName(exit.direction), exit.width, exit.port, exit.count, exit.data });
                    return err;
                };
                if (action != .continue_guest) return error.UnexpectedGuestReset;
            },
            kvm.KVM_EXIT_MMIO => {
                const address = readInt(u64, machine.run, kvm.RunLayout.mmio_phys_addr);
                const len = readInt(u32, machine.run, kvm.RunLayout.mmio_len);
                const is_write = machine.run[kvm.RunLayout.mmio_is_write];
                const value = readInt(u32, machine.run, kvm.RunLayout.mmio_data);
                const expected_address = mailbox.generation_gpa + switch (phase) {
                    .capture_ready => mailbox.capture_doorbell_offset,
                    .restored_ready => mailbox.restored_doorbell_offset,
                };
                const expected_value = switch (phase) {
                    .capture_ready => mailbox.capture_command,
                    .restored_ready => mailbox.restored_command,
                };
                if (address != expected_address or len != 4 or is_write != 1 or value != expected_value) return error.UnexpectedMmio;
                const message = try mailbox.decode(@ptrCast(machine.mailbox_page.ptr), phase, nonce);
                if (phase == .capture_ready) try kvm.completePendingExit(machine.vcpu_fds[0], machine.run);
                return message;
            },
            kvm.KVM_EXIT_HLT => return error.UnexpectedKvmExit,
            else => return error.UnexpectedKvmExit,
        }
    }
}

fn captureMsrs(allocator: std.mem.Allocator, kvm_fd: std.c.fd_t, vcpu_fd: std.c.fd_t) ![]state_file.Msr {
    var list = kvm.MsrList(msr_capacity){};
    const advertised = try kvm.getMsrIndexList(kvm_fd, kvm.KVM_GET_MSR_INDEX_LIST, msr_capacity, &list, "KVM_GET_MSR_INDEX_LIST roundtrip");
    var batch = kvm.MsrBatch(msr_capacity){};
    var count: usize = 0;
    for (cpu_profile.candidate_msrs) |descriptor| {
        const present = std.mem.indexOfScalar(u32, advertised, descriptor.index) != null;
        if (!present) return error.RequiredMsrMissing;
        batch.entries[count].index = descriptor.index;
        count += 1;
    }
    batch.nmsrs = @intCast(count);
    const completed = try kvm.ioctl(vcpu_fd, kvm.KVM_GET_MSRS, @intFromPtr(&batch), "KVM_GET_MSRS roundtrip");
    const entries = try kvm.completedMsrEntries(msr_capacity, &batch, completed);
    const result = try allocator.alloc(state_file.Msr, entries.len);
    for (entries, result) |entry, *out| out.* = .{ .index = entry.index, .value = entry.data };
    std.mem.sort(state_file.Msr, result, {}, struct {
        fn less(_: void, a: state_file.Msr, b: state_file.Msr) bool {
            return a.index < b.index;
        }
    }.less);
    return result;
}

fn restoreMsrs(vcpu_fd: std.c.fd_t, values: []const state_file.Msr) !void {
    for ([_]cpu_profile.MsrRestoreOrder{ .kernel, .paravirtual, .tsc_adjust, .tsc }) |order| {
        var batch = kvm.MsrBatch(msr_capacity){};
        var count: usize = 0;
        for (cpu_profile.candidate_msrs) |descriptor| {
            if (descriptor.order != order) continue;
            for (values) |value| if (value.index == descriptor.index) {
                batch.entries[count] = .{ .index = value.index, .data = value.value };
                count += 1;
            };
        }
        if (count == 0) continue;
        batch.nmsrs = @intCast(count);
        const completed = try kvm.ioctl(vcpu_fd, kvm.KVM_SET_MSRS, @intFromPtr(&batch), "KVM_SET_MSRS roundtrip");
        _ = try kvm.completedMsrEntries(msr_capacity, &batch, completed);
    }
}

fn compareRestoredState(allocator: std.mem.Allocator, machine: *Machine, expected: *const state_file.State) !void {
    var actual = try captureState(allocator, machine);
    defer actual.deinit(allocator);
    const mailbox_equal = std.mem.eql(u8, &expected.mailbox, &actual.mailbox);
    var vcpus_equal = true;
    for (expected.vcpus, actual.vcpus, 0..) |left, right, index| {
        if (!vcpuStateEqual(left, right)) {
            vcpus_equal = false;
            std.debug.print("sporevm kvm-profile-roundtrip: vcpu={d} restore-readback mismatch expected_rip=0x{x} actual_rip=0x{x}\n", .{ index, left.gprs.rip, right.gprs.rip });
            if (!candidateSregsEqual(left.sregs, right.sregs)) logSregsDifference(left.sregs, right.sregs);
        }
    }
    const irqchip_equal = std.meta.eql(expected.pic_master, actual.pic_master) and std.meta.eql(expected.pic_slave, actual.pic_slave) and std.meta.eql(expected.ioapic, actual.ioapic);
    const pit_equal = pitStateEqual(expected.pit2, actual.pit2);
    // Restoring MSR_KVM_WALL_CLOCK_NEW synchronously rewrites its guest
    // pvclock page, so whole-RAM byte equality is not a valid pre-run
    // invariant after restoreMsrs. The state checksum protects the saved RAM;
    // the dedicated mailbox remains byte-exact here.
    // KVM consumes REALTIME/HOST_TSC as SET_CLOCK re-anchoring inputs and the
    // following GET_CLOCK reports flags=0 on this kernel. The comparable
    // invariant is the guest clock value; Stage 0b.3 owns the final flag policy.
    const clock_valid = actual.clock.clock >= expected.clock.clock;
    if (!mailbox_equal or !vcpus_equal or !irqchip_equal or !pit_equal or !clock_valid) {
        std.debug.print("sporevm kvm-profile-roundtrip: restore-readback mailbox={} vcpus={} irqchip={} pit={} clock={}\n", .{ mailbox_equal, vcpus_equal, irqchip_equal, pit_equal, clock_valid });
        if (!clock_valid) std.debug.print("clock expected={any} actual={any}\n", .{ expected.clock, actual.clock });
        return error.RestoreReadbackMismatch;
    }
}

fn vcpuStateEqual(expected_value: state_file.VcpuMachineState, actual_value: state_file.VcpuMachineState) bool {
    if (!std.meta.eql(expected_value.gprs, actual_value.gprs) or
        !candidateSregsEqual(expected_value.sregs, actual_value.sregs) or
        !structSlicesEqual(state_file.CpuidEntry, expected_value.cpuid, actual_value.cpuid) or
        !structSlicesEqual(state_file.Xcr, expected_value.xcrs, actual_value.xcrs) or
        !std.mem.eql(u8, expected_value.xsave, actual_value.xsave) or
        !candidateMsrsEqual(expected_value.msrs, actual_value.msrs) or
        expected_value.tsc_khz != actual_value.tsc_khz or
        expected_value.tsc_offset != actual_value.tsc_offset) return false;
    var left = expected_value;
    var right = actual_value;
    // Dynamic slices were compared above and are not part of the semantic
    // scalar/device comparison below.
    left.cpuid = &.{};
    right.cpuid = &.{};
    left.xcrs = &.{};
    right.xcrs = &.{};
    left.xsave = &.{};
    right.xsave = &.{};
    left.msrs = &.{};
    right.msrs = &.{};
    // The running LAPIC timer advances between SET_LAPIC and GET_LAPIC;
    // its programmed mode and initial count remain exact.
    left.lapic.current_count = 0;
    right.lapic.current_count = 0;
    // APR/PPR are derived by KVM from TPR and the in-service bitmap.
    left.lapic.apr = 0;
    right.lapic.apr = 0;
    left.lapic.ppr = 0;
    right.lapic.ppr = 0;
    return std.meta.eql(left, right);
}

fn pitStateEqual(expected_value: state_file.Pit2, actual_value: state_file.Pit2) bool {
    var expected = expected_value;
    var actual = actual_value;
    // KVM re-anchors the host monotonic timestamp used to advance each PIT
    // channel while preserving the guest-visible counter and mode.
    for (&expected.channels, &actual.channels) |*left, *right| {
        left.count_load_time = 0;
        right.count_load_time = 0;
    }
    return std.meta.eql(expected, actual);
}

fn candidateMsrsEqual(expected: []const state_file.Msr, actual: []const state_file.Msr) bool {
    if (expected.len != actual.len) return false;
    for (expected, actual) |left, right| {
        if (left.index != right.index) return false;
        if (left.index == 0x10) {
            if (right.value < left.value) return false;
        } else if (left.value != right.value) return false;
    }
    return true;
}

fn logSregsDifference(expected: state_file.Sregs, actual: state_file.Sregs) void {
    std.debug.print("sregs expected cr0={x} cr2={x} cr3={x} cr4={x} cr8={x} efer={x} apic={x}\n", .{ expected.cr0, expected.cr2, expected.cr3, expected.cr4, expected.cr8, expected.efer, expected.apic_base });
    std.debug.print("sregs actual   cr0={x} cr2={x} cr3={x} cr4={x} cr8={x} efer={x} apic={x}\n", .{ actual.cr0, actual.cr2, actual.cr3, actual.cr4, actual.cr8, actual.efer, actual.apic_base });
    inline for (.{ "cs", "ds", "es", "fs", "gs", "ss", "tr", "ldt" }) |name| {
        const a = @field(expected, name);
        const b = @field(actual, name);
        if (!std.meta.eql(a, b)) std.debug.print("sregs segment {s} expected={any} actual={any}\n", .{ name, a, b });
    }
    if (!std.meta.eql(expected.gdt, actual.gdt)) std.debug.print("sregs gdt expected={any} actual={any}\n", .{ expected.gdt, actual.gdt });
    if (!std.meta.eql(expected.idt, actual.idt)) std.debug.print("sregs idt expected={any} actual={any}\n", .{ expected.idt, actual.idt });
}

fn candidateSregsEqual(expected_value: state_file.Sregs, actual_value: state_file.Sregs) bool {
    var expected = expected_value;
    var actual = actual_value;
    // Pending interrupts belong to the LAPIC/event inventory deferred to
    // Stage 0b.3 and are deliberately neither restored nor compared here.
    expected.interrupt_bitmap = @splat(0);
    actual.interrupt_bitmap = @splat(0);
    return std.meta.eql(expected, actual);
}

fn requireApReset(machine: *const Machine) !void {
    if ((try kvm.getMpState(machine.vcpu_fds[0])).mp_state != kvm.KVM_MP_STATE_RUNNABLE) return error.BspNotRunnable;
    if ((try kvm.getMpState(machine.vcpu_fds[1])).mp_state != kvm.KVM_MP_STATE_UNINITIALIZED) return error.ApNotReset;
}

fn configureProtectedMode(fd: std.c.fd_t, layout: boot.Plan) !void {
    var sregs: kvm.Sregs = undefined;
    _ = try kvm.ioctl(fd, kvm.KVM_GET_SREGS, @intFromPtr(&sregs), "KVM_GET_SREGS fresh");
    var initial = cpu.protectedModeState(sregs, layout.kernel_load.start, layout.zero_page.start);
    _ = try kvm.ioctl(fd, kvm.KVM_SET_SREGS, @intFromPtr(&initial.sregs), "KVM_SET_SREGS fresh");
    _ = try kvm.ioctl(fd, kvm.KVM_SET_REGS, @intFromPtr(&initial.regs), "KVM_SET_REGS fresh");
}

fn installMemslot(vm_fd: std.c.fd_t, slot: u32, gpa: u64, bytes: []u8) !void {
    var region = kvm.UserspaceMemoryRegion{ .slot = slot, .flags = 0, .guest_phys_addr = gpa, .memory_size = bytes.len, .userspace_addr = @intFromPtr(bytes.ptr) };
    _ = try kvm.ioctl(vm_fd, kvm.KVM_SET_USER_MEMORY_REGION, @intFromPtr(&region), "KVM_SET_USER_MEMORY_REGION roundtrip");
}

fn mapAnonymous(len: usize) ![]align(std.heap.page_size_min) u8 {
    return std.posix.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
}

fn positiveIoctl(fd: std.c.fd_t, request: u32, op: []const u8) !u64 {
    const value = try kvm.ioctl(fd, request, 0, op);
    if (value == 0) return error.UnexpectedZeroValue;
    return value;
}

fn writePrivateExclusive(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const pathz = try allocator.dupeZ(u8, path);
    const fd = std.c.open(pathz, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0o600));
    if (fd < 0) return error.StateCreateFailed;
    defer _ = std.c.close(fd);
    var remaining = bytes;
    while (remaining.len != 0) {
        const written = std.c.write(fd, remaining.ptr, remaining.len);
        if (written <= 0) return error.StateWriteFailed;
        remaining = remaining[@intCast(written)..];
    }
    if (std.c.fsync(fd) != 0) return error.StateSyncFailed;
}

fn readPrivateState(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const pathz = try allocator.dupeZ(u8, path);
    const fd = std.c.open(pathz, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.StateOpenFailed;
    defer _ = std.c.close(fd);
    var stat: linux.Statx = undefined;
    const stat_rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .UID = true, .NLINK = true, .SIZE = true }, &stat);
    if (linux.errno(stat_rc) != .SUCCESS or !linux.S.ISREG(stat.mode) or stat.nlink != 1 or
        stat.uid != linux.getuid() or stat.mode & 0o077 != 0 or stat.size == 0 or stat.size > state_file.max_encoded_bytes)
    {
        return error.UnsafeStateFile;
    }
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    var offset: usize = 0;
    while (offset != bytes.len) {
        const amount = std.c.read(fd, bytes[offset..].ptr, bytes.len - offset);
        if (amount <= 0) return error.StateReadFailed;
        offset += @intCast(amount);
    }
    return bytes;
}

fn kvmCpuidToState(allocator: std.mem.Allocator, raw: *const kvm.Cpuid) ![]state_file.CpuidEntry {
    const count: usize = @intCast(raw.nent);
    if (count > raw.entries.len) return error.CpuidTooLarge;
    const result = try allocator.alloc(state_file.CpuidEntry, count);
    for (raw.entries[0..count], result) |entry, *out| out.* = .{ .function = entry.function, .index = entry.index, .flags = entry.flags, .eax = entry.eax, .ebx = entry.ebx, .ecx = entry.ecx, .edx = entry.edx };
    std.mem.sort(state_file.CpuidEntry, result, {}, struct {
        fn less(_: void, a: state_file.CpuidEntry, b: state_file.CpuidEntry) bool {
            return a.function < b.function or (a.function == b.function and a.index < b.index);
        }
    }.less);
    return result;
}

fn stateCpuidToKvm(entries: []const state_file.CpuidEntry) !kvm.Cpuid {
    if (entries.len > kvm.max_cpuid_entries) return error.CpuidTooLarge;
    var result = kvm.Cpuid{ .nent = @intCast(entries.len) };
    for (entries, result.entries[0..entries.len]) |entry, *out| out.* = .{ .function = entry.function, .index = entry.index, .flags = entry.flags, .eax = entry.eax, .ebx = entry.ebx, .ecx = entry.ecx, .edx = entry.edx };
    return result;
}

fn cpuidEqual(left: *const kvm.Cpuid, right: *const kvm.Cpuid) bool {
    if (left.nent != right.nent) return false;
    for (left.entries[0..left.nent], right.entries[0..right.nent]) |a, b| {
        inline for (.{ "function", "index", "flags", "eax", "ebx", "ecx", "edx" }) |name| {
            if (@field(a, name) != @field(b, name)) return false;
        }
    }
    return true;
}

fn cpuidSetEqual(left: *const kvm.Cpuid, right: *const kvm.Cpuid) bool {
    if (left.nent != right.nent) return false;
    for (left.entries[0..left.nent]) |a| {
        var found = false;
        for (right.entries[0..right.nent]) |b| {
            if (a.function != b.function or a.index != b.index) continue;
            found = true;
            inline for (.{ "flags", "eax", "ebx", "ecx", "edx" }) |name| {
                if (@field(a, name) != @field(b, name)) return false;
            }
            break;
        }
        if (!found) return false;
    }
    return true;
}

fn effectiveCpuidMatches(configured: *const kvm.Cpuid, effective: *const kvm.Cpuid, sregs: kvm.Sregs, xcrs: []const state_file.Xcr) bool {
    var expected = configured.*;
    var xcr0: u64 = 1;
    for (xcrs) |entry| {
        if (entry.index == 0) xcr0 = entry.value;
    }
    for (expected.entries[0..expected.nent]) |*entry| {
        if (entry.function == 1 and entry.index == 0) {
            const osxsave = @as(u32, 1) << 27;
            if (sregs.cr4 & (@as(u64, 1) << 18) == 0) entry.ecx &= ~osxsave else entry.ecx |= osxsave;
        } else if (entry.function == 0x0d and entry.index == 0) {
            entry.ebx = @as(u32, state_file.xsave_legacy_and_header_bytes) + if (xcr0 & 0b100 != 0) @as(u32, 256) else 0;
        }
    }
    return cpuidSetEqual(&expected, effective);
}

fn logCpuidDifference(index: usize, expected: *const kvm.Cpuid, actual: *const kvm.Cpuid) void {
    std.debug.print("sporevm kvm-profile-roundtrip: vcpu={d} effective CPUID mismatch expected_entries={d} actual_entries={d}\n", .{ index, expected.nent, actual.nent });
    for (expected.entries[0..expected.nent]) |entry| {
        var found: ?kvm.CpuidEntry = null;
        for (actual.entries[0..actual.nent]) |candidate| {
            if (candidate.function == entry.function and candidate.index == entry.index) {
                found = candidate;
                break;
            }
        }
        if (found == null or !std.meta.eql(entry, found.?)) {
            std.debug.print("expected cpuid fn=0x{x} index={d} value={any} actual={any}\n", .{ entry.function, entry.index, entry, found });
        }
    }
}

fn kvmXcrsToState(allocator: std.mem.Allocator, raw: *const kvm.Xcrs) ![]state_file.Xcr {
    const count: usize = @intCast(raw.nr_xcrs);
    if (count > raw.xcrs.len) return error.XcrsTooLarge;
    const result = try allocator.alloc(state_file.Xcr, count);
    for (raw.xcrs[0..count], result) |entry, *out| out.* = .{ .index = entry.xcr, .value = entry.value };
    return result;
}

fn stateXcrsToKvm(entries: []const state_file.Xcr) kvm.Xcrs {
    var result = kvm.Xcrs{ .nr_xcrs = @intCast(entries.len) };
    for (entries, result.xcrs[0..entries.len]) |entry, *out| out.* = .{ .xcr = entry.index, .value = entry.value };
    return result;
}

fn kvmGprsToState(v: kvm.Regs) state_file.Gprs {
    var out: state_file.Gprs = undefined;
    inline for (std.meta.fields(state_file.Gprs)) |field| @field(out, field.name) = @field(v, field.name);
    return out;
}
fn stateGprsToKvm(v: state_file.Gprs) kvm.Regs {
    var out = kvm.Regs{};
    inline for (std.meta.fields(state_file.Gprs)) |field| @field(out, field.name) = @field(v, field.name);
    return out;
}
fn kvmSegmentToState(v: kvm.Segment) state_file.Segment {
    var out = state_file.Segment{};
    inline for (std.meta.fields(state_file.Segment)) |field| @field(out, field.name) = @field(v, field.name);
    // KVM canonicalizes an unusable segment's ignored type field to 1 on
    // SET/GET. Normalize that don't-care value before persisting evidence.
    if (out.unusable != 0) out.type = 1;
    return out;
}
fn stateSegmentToKvm(v: state_file.Segment) kvm.Segment {
    var out = kvm.Segment{};
    inline for (std.meta.fields(state_file.Segment)) |field| @field(out, field.name) = @field(v, field.name);
    return out;
}

fn kvmSregsToState(v: kvm.Sregs) state_file.Sregs {
    var out = state_file.Sregs{};
    inline for (.{ "cs", "ds", "es", "fs", "gs", "ss", "tr", "ldt" }) |name| @field(out, name) = kvmSegmentToState(@field(v, name));
    out.gdt = .{ .base = v.gdt.base, .limit = v.gdt.limit };
    out.idt = .{ .base = v.idt.base, .limit = v.idt.limit };
    inline for (.{ "cr0", "cr2", "cr3", "cr4", "cr8", "efer", "apic_base", "interrupt_bitmap" }) |name| @field(out, name) = @field(v, name);
    return out;
}

fn stateSregsToKvm(v: state_file.Sregs) kvm.Sregs {
    var out: kvm.Sregs = undefined;
    inline for (.{ "cs", "ds", "es", "fs", "gs", "ss", "tr", "ldt" }) |name| @field(out, name) = stateSegmentToKvm(@field(v, name));
    out.gdt = .{ .base = v.gdt.base, .limit = v.gdt.limit };
    out.idt = .{ .base = v.idt.base, .limit = v.idt.limit };
    inline for (.{ "cr0", "cr2", "cr3", "cr4", "cr8", "efer", "apic_base", "interrupt_bitmap" }) |name| @field(out, name) = @field(v, name);
    out.interrupt_bitmap = @splat(0);
    return out;
}

fn kvmClockToState(v: kvm.ClockData) state_file.Clock {
    return .{ .clock = v.clock, .flags = v.flags, .realtime = v.realtime, .host_tsc = v.host_tsc };
}
fn stateClockToKvm(v: state_file.Clock) kvm.ClockData {
    return .{ .clock = v.clock, .flags = cpu_profile.restore_clock_flags, .realtime = v.realtime };
}

fn lapicRead(raw: *const kvm.LapicState, offset: usize) u32 {
    return std.mem.readInt(u32, raw.regs[offset..][0..4], .little);
}

fn lapicWrite(raw: *kvm.LapicState, offset: usize, value: u32) void {
    std.mem.writeInt(u32, raw.regs[offset..][0..4], value, .little);
}

const lapic_scalar_mappings = .{
    .{ 0x20, "id" },         .{ 0x30, "version" },        .{ 0x80, "tpr" },            .{ 0x90, "apr" },              .{ 0xa0, "ppr" },        .{ 0xb0, "eoi" },
    .{ 0xd0, "ldr" },        .{ 0xe0, "dfr" },            .{ 0xf0, "svr" },            .{ 0x280, "esr" },             .{ 0x2f0, "lvt_cmci" },  .{ 0x300, "icr_low" },
    .{ 0x310, "icr_high" },  .{ 0x320, "lvt_timer" },     .{ 0x330, "lvt_thermal" },   .{ 0x340, "lvt_performance" }, .{ 0x350, "lvt_lint0" }, .{ 0x360, "lvt_lint1" },
    .{ 0x370, "lvt_error" }, .{ 0x380, "initial_count" }, .{ 0x390, "current_count" }, .{ 0x3e0, "divide_config" },
};

const lapic_bank_mappings = .{ .{ 0x100, "isr" }, .{ 0x180, "tmr" }, .{ 0x200, "irr" } };

fn kvmLapicToState(raw: kvm.LapicState) state_file.Lapic {
    var out = state_file.Lapic{};
    inline for (lapic_scalar_mappings) |mapping| @field(out, mapping[1]) = lapicRead(&raw, mapping[0]);
    inline for (lapic_bank_mappings) |mapping| {
        for (0..8) |index| @field(out, mapping[1])[index] = lapicRead(&raw, mapping[0] + index * 0x10);
    }
    return out;
}

fn stateLapicToKvm(value: state_file.Lapic) kvm.LapicState {
    var raw = kvm.LapicState{};
    inline for (lapic_scalar_mappings) |mapping| lapicWrite(&raw, mapping[0], @field(value, mapping[1]));
    inline for (lapic_bank_mappings) |mapping| {
        for (0..8) |index| lapicWrite(&raw, mapping[0] + index * 0x10, @field(value, mapping[1])[index]);
    }
    return raw;
}

fn kvmEventsToState(v: kvm.VcpuEvents) !state_file.VcpuEvents {
    if (v.smi.smm != 0 or v.smi.pending != 0 or v.smi.smm_inside_nmi != 0 or v.smi.latched_init != 0 or v.triple_fault.pending != 0) return error.UnsupportedVcpuEvent;
    if (v.flags & ~kvm.KVM_VCPUEVENT_VALID_MASK != 0) return error.UnsupportedVcpuEvent;
    if (v.nmi.padding != 0) return error.UnsupportedVcpuEvent;
    for (v.reserved) |byte| if (byte != 0) return error.UnsupportedVcpuEvent;
    return .{
        .exception_injected = v.exception.injected,
        .exception_number = v.exception.nr,
        .exception_has_error_code = v.exception.has_error_code,
        .exception_pending = v.exception.pending,
        .exception_error_code = v.exception.error_code,
        .interrupt_injected = v.interrupt.injected,
        .interrupt_number = v.interrupt.nr,
        .interrupt_is_soft = v.interrupt.soft,
        .interrupt_shadow = v.interrupt.shadow,
        .nmi_injected = v.nmi.injected,
        .nmi_pending = v.nmi.pending,
        .nmi_masked = v.nmi.masked,
        .sipi_vector = v.sipi_vector,
        .flags = v.flags,
        .exception_has_payload = v.exception_has_payload,
        .exception_payload = v.exception_payload,
    };
}

fn stateEventsToKvm(v: state_file.VcpuEvents) !kvm.VcpuEvents {
    if (v.flags & ~kvm.KVM_VCPUEVENT_VALID_MASK != 0) return error.UnsupportedVcpuEvent;
    if (v.smm != 0 or v.pending_smi != 0 or v.smm_inside_nmi != 0 or v.latched_init != 0 or v.triple_fault_pending != 0) return error.UnsupportedVcpuEvent;
    return .{
        .exception = .{ .injected = @intCast(v.exception_injected), .nr = @intCast(v.exception_number), .has_error_code = @intCast(v.exception_has_error_code), .pending = @intCast(v.exception_pending), .error_code = v.exception_error_code },
        .interrupt = .{ .injected = @intCast(v.interrupt_injected), .nr = @intCast(v.interrupt_number), .soft = @intCast(v.interrupt_is_soft), .shadow = @intCast(v.interrupt_shadow) },
        .nmi = .{ .injected = @intCast(v.nmi_injected), .pending = @intCast(v.nmi_pending), .masked = @intCast(v.nmi_masked) },
        .sipi_vector = v.sipi_vector,
        .flags = v.flags,
        .exception_has_payload = @intCast(v.exception_has_payload),
        .exception_payload = v.exception_payload,
    };
}

fn kvmDebugToState(v: kvm.DebugRegs) !state_file.DebugState {
    if (v.flags != 0) return error.UnsupportedDebugState;
    for (v.reserved) |word| if (word != 0) return error.UnsupportedDebugState;
    return .{ .db = v.db, .dr6 = v.dr6, .dr7 = v.dr7 };
}

fn stateDebugToKvm(v: state_file.DebugState) kvm.DebugRegs {
    return .{ .db = v.db, .dr6 = v.dr6, .dr7 = v.dr7, .flags = v.flags };
}

fn kvmPicToState(v: kvm.PicState) state_file.Pic {
    var out = state_file.Pic{};
    inline for (std.meta.fields(state_file.Pic)) |field| @field(out, field.name) = @field(v, field.name);
    return out;
}

fn statePicToKvm(chip_id: u32, v: state_file.Pic) kvm.Irqchip {
    var pic = kvm.PicState{};
    inline for (std.meta.fields(state_file.Pic)) |field| @field(pic, field.name) = @field(v, field.name);
    return .{ .chip_id = chip_id, .chip = .{ .pic = pic } };
}

fn kvmIoapicToState(v: kvm.IoapicState) state_file.Ioapic {
    return .{ .base_address = v.base_address, .ioregsel = v.ioregsel, .id = v.id, .irr = v.irr, .redirection_table = v.redirection_table };
}

fn stateIoapicToKvm(v: state_file.Ioapic) kvm.Irqchip {
    return .{ .chip_id = kvm.KVM_IRQCHIP_IOAPIC, .chip = .{ .ioapic = .{ .base_address = v.base_address, .ioregsel = v.ioregsel, .id = v.id, .irr = v.irr, .redirection_table = v.redirection_table } } };
}

fn kvmPitToState(v: kvm.PitState2) state_file.Pit2 {
    var out = state_file.Pit2{ .flags = v.flags };
    for (v.channels, &out.channels) |channel, *dest| {
        inline for (std.meta.fields(state_file.PitChannel)) |field| @field(dest, field.name) = @bitCast(@field(channel, field.name));
    }
    return out;
}

fn statePitToKvm(v: state_file.Pit2) kvm.PitState2 {
    var out = kvm.PitState2{ .flags = v.flags };
    for (v.channels, &out.channels) |channel, *dest| {
        inline for (std.meta.fields(state_file.PitChannel)) |field| @field(dest, field.name) = @bitCast(@field(channel, field.name));
    }
    return out;
}
fn sha256(bytes: []const u8) [Sha256.digest_length * 2]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
fn clockNs(value: mailbox.Clock) i128 {
    return @as(i128, value.seconds) * std.time.ns_per_s + value.nanoseconds;
}
fn readInt(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .native);
}

fn structSlicesEqual(comptime T: type, left: []const T, right: []const T) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (!std.meta.eql(a, b)) return false;
    return true;
}

fn usageExit() noreturn {
    std.debug.print("usage: kvm-profile-roundtrip capture <kernel-bzImage> <initrd.cpio> <state-file>\n       kvm-profile-roundtrip restore <state-file>\n", .{});
    std.process.exit(2);
}

test "profile roundtrip constants stay inside the frozen board holes" {
    try std.testing.expectEqual(@as(usize, 64 * 1024 * 1024), ram_size);
    try std.testing.expect(mailbox.mailbox_gpa >= ram_size);
    try std.testing.expect(mailbox.mailbox_gpa + mailbox.page_size <= board.virtio_base);
}

test "candidate restore rejects SMM and triple-fault events" {
    try std.testing.expectError(error.UnsupportedVcpuEvent, stateEventsToKvm(.{ .smm = 1, .flags = kvm.KVM_VCPUEVENT_VALID_SMM }));
    try std.testing.expectError(error.UnsupportedVcpuEvent, stateEventsToKvm(.{ .triple_fault_pending = 1, .flags = kvm.KVM_VCPUEVENT_VALID_TRIPLE_FAULT }));
}
