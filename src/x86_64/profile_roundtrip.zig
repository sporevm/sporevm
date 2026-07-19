//! Host-only Stage 0b.2 dirty-xstate and clock process-boundary proof.

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
const stage0b2_xcr0: u64 = 0x7;
const stage0b2_xsave_layout_size: u32 = 832;

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
    try validateStage0b2State(&state);
    std.debug.print("sporevm kvm-profile-roundtrip: captured xstate_bv=0x{x} xcomp_bv=0x{x} xsave_bytes={d}\n", .{ state.xstate_bv, state.xcomp_bv, state.xsave.len });
    const capture_message = try mailbox.decode(@ptrCast(machine.mailbox_page.ptr), .capture_ready, nonce);
    if (capture_message.capture_tsc != result.capture_tsc) return error.MailboxChangedAfterBarrier;
    const encoded = try state_file.encode(allocator, &state);
    try writePrivateExclusive(allocator, output_path, encoded);
    const digest = sha256(encoded);
    std.debug.print("sporevm kvm-profile-roundtrip: phase=capture pid={d} nonce={x:0>16} state_bytes={d} state_sha256={s} xsave_bytes={d} msrs={d} capture_tsc={d} monotonic_ns={d} boottime_ns={d} realtime_ns={d} complete=true\n", .{
        linux.getpid(),                             nonce,                                      encoded.len,                                &digest, state.xsave.len, state.msrs.len, capture_message.capture_tsc,
        clockNs(capture_message.capture_clocks[0]), clockNs(capture_message.capture_clocks[1]), clockNs(capture_message.capture_clocks[2]),
    });
}

fn restore(allocator: std.mem.Allocator, io: std.Io, input_path: []const u8) !void {
    _ = io;
    const encoded = try readPrivateState(allocator, input_path);
    var state = try state_file.decode(allocator, encoded);
    defer state.deinit(allocator);
    try validateStage0b2State(&state);
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

fn validateStage0b2State(state: *const state_file.State) !void {
    if (state.ram.len != ram_size or state.cpuid.len == 0 or state.xstate_bv != 0x7 or state.xcomp_bv != 0) {
        return error.UnexpectedStage0b2State;
    }
    if (state.xcrs.len != 1 or state.xcrs[0].index != 0 or state.xcrs[0].value != stage0b2_xcr0) {
        return error.UnexpectedStage0b2State;
    }
    var saw_xsave_layout = false;
    var saw_ymm_layout = false;
    for (state.cpuid) |entry| {
        if (entry.function == 7) {
            const ebx = if (entry.index == 0) @as(u32, 1) << 1 else 0;
            if (entry.eax != 0 or entry.ebx != ebx or entry.ecx != 0 or entry.edx != 0) return error.UnexpectedStage0b2State;
        } else if (entry.function == 0x0d) switch (entry.index) {
            0 => {
                saw_xsave_layout = true;
                if (entry.eax != @as(u32, @intCast(stage0b2_xcr0)) or entry.ebx != stage0b2_xsave_layout_size or entry.ecx != stage0b2_xsave_layout_size or entry.edx != 0) return error.UnexpectedStage0b2State;
            },
            2 => {
                saw_ymm_layout = true;
                if (entry.eax != 256 or entry.ebx != 576 or entry.ecx != 0 or entry.edx != 0) return error.UnexpectedStage0b2State;
            },
            else => if (entry.eax != 0 or entry.ebx != 0 or entry.ecx != 0 or entry.edx != 0) return error.UnexpectedStage0b2State,
        };
    }
    if (!saw_xsave_layout or !saw_ymm_layout) return error.UnexpectedStage0b2State;
    for (state.msrs) |value| {
        var allowed = false;
        for (cpu_profile.stage0b2_msr_inventory) |descriptor| {
            if (descriptor.index == value.index and descriptor.disposition != .excluded) allowed = true;
        }
        if (!allowed) return error.UnexpectedStage0b2State;
    }
    for (cpu_profile.stage0b2_msr_inventory) |descriptor| {
        if (descriptor.disposition != .required) continue;
        var present = false;
        for (state.msrs) |value| if (value.index == descriptor.index) {
            present = true;
        };
        if (!present) return error.RequiredMsrMissing;
    }
}

fn createFreshMachine(kernel: []const u8, initrd: []const u8, cmdline: []const u8) !Machine {
    var machine = try createBaseMachine(null, null);
    errdefer machine.deinit();
    _ = try boot.load(machine.ram, kernel, initrd, cmdline, board_vcpu_count);
    try configureProtectedMode(machine.vcpu_fds[0], try boot.plan(kernel, initrd.len, cmdline, ram_size, board_vcpu_count));
    try requireApReset(&machine);
    return machine;
}

fn createRestoredMachine(state: *const state_file.State) !Machine {
    if (state.ram.len != ram_size) return error.UnexpectedRamSize;
    var machine = try createBaseMachine(state.tsc_khz, state);
    errdefer machine.deinit();
    if (state.xsave.len != machine.xsave_size) return error.XsaveSizeMismatch;
    const xsave = try kvm.xsave2Buffer(state.xsave, machine.xsave_size);
    @memcpy(machine.ram, state.ram);
    @memcpy(machine.mailbox_page, &state.mailbox);
    try applyCpuState(&machine, state, xsave);
    return machine;
}

fn createBaseMachine(saved_tsc_khz: ?u64, saved: ?*const state_file.State) !Machine {
    const kvm_fd = try kvm.openDevKvm();
    errdefer _ = std.c.close(kvm_fd);
    try kvm.checkApiVersion(kvm_fd);
    inline for (.{ kvm.KVM_CAP_USER_MEMORY, kvm.KVM_CAP_IRQCHIP, kvm.KVM_CAP_PIT2, kvm.KVM_CAP_EXT_CPUID, kvm.KVM_CAP_XSAVE, kvm.KVM_CAP_XCRS, kvm.KVM_CAP_IMMEDIATE_EXIT, kvm.KVM_CAP_KVMCLOCK_CTRL }) |cap| {
        if (try kvm.checkExtension(kvm_fd, cap) == 0) return error.RequiredCapabilityMissing;
    }
    const vm_fd: std.c.fd_t = @intCast(try kvm.ioctl(kvm_fd, kvm.KVM_CREATE_VM, 0, "KVM_CREATE_VM"));
    errdefer _ = std.c.close(vm_fd);
    const tsc_khz = saved_tsc_khz orelse try positiveIoctl(vm_fd, kvm.KVM_GET_TSC_KHZ, "KVM_GET_TSC_KHZ fresh VM");
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

    const supported = try kvm.getSupportedCpuid(kvm_fd);
    var cpuid: [board_vcpu_count]kvm.Cpuid = undefined;
    var fds: [board_vcpu_count]std.c.fd_t = @splat(-1);
    var created: usize = 0;
    errdefer {
        for (fds[0..created]) |fd| _ = std.c.close(fd);
    }
    while (created < board_vcpu_count) : (created += 1) {
        fds[created] = @intCast(try kvm.ioctl(vm_fd, kvm.KVM_CREATE_VCPU, created, "KVM_CREATE_VCPU"));
        cpuid[created] = if (created == 0 and saved != null)
            try stateCpuidToKvm(saved.?.cpuid)
        else
            try kvm.normalizeSupportedCpuidTopology(supported, board_vcpu_count, @intCast(created));
        if (saved == null or created != 0) filterStage0b2Cpuid(&cpuid[created]);
        _ = try kvm.ioctl(fds[created], kvm.KVM_SET_CPUID2, @intFromPtr(&cpuid[created]), "KVM_SET_CPUID2");
    }
    const run_size = try kvm.ioctl(kvm_fd, kvm.KVM_GET_VCPU_MMAP_SIZE, 0, "KVM_GET_VCPU_MMAP_SIZE");
    if (run_size < kvm.RunLayout.mmio_end) return error.KvmRunMappingTooSmall;
    const run = try std.posix.mmap(null, run_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fds[0], 0);
    errdefer std.posix.munmap(run);
    if (!try kvm.hasTscOffset(fds[0])) return error.TscOffsetUnavailable;
    return .{ .kvm_fd = kvm_fd, .vm_fd = vm_fd, .vcpu_fds = fds, .run = run, .ram = ram, .mailbox_page = mailbox_page, .cpuid = cpuid, .xsave_size = xsave_size };
}

fn filterStage0b2Cpuid(cpuid: *kvm.Cpuid) void {
    for (cpuid.entries[0..cpuid.nent]) |*entry| {
        if (entry.function == 7) {
            // Keep only TSC_ADJUST. Structured extended features include
            // stateful families such as AVX-512, PKRU, CET, UINTR, LBR, and
            // AMX; the evidence-only 0b.2 contract does not expose them.
            entry.eax = 0;
            entry.ebx = if (entry.index == 0) @as(u32, 1) << 1 else 0;
            entry.ecx = 0;
            entry.edx = 0;
        } else if (entry.function == 0x0d and entry.index == 0) {
            entry.eax = @intCast(stage0b2_xcr0);
            entry.ebx = stage0b2_xsave_layout_size;
            entry.ecx = stage0b2_xsave_layout_size;
            entry.edx = 0;
        } else if (entry.function == 0x0d and entry.index == 2) {
            entry.eax = 256;
            entry.ebx = 576;
            entry.ecx = 0;
            entry.edx = 0;
        } else if (entry.function == 0x0d) {
            entry.eax = 0;
            entry.ebx = 0;
            entry.ecx = 0;
            entry.edx = 0;
        }
    }
}

fn applyCpuState(machine: *Machine, state: *const state_file.State, xsave: []const u8) !void {
    const sregs = stateSregsToKvm(state.sregs);
    _ = try kvm.ioctl(machine.vcpu_fds[0], kvm.KVM_SET_SREGS, @intFromPtr(&sregs), "KVM_SET_SREGS restore");
    var xcrs = stateXcrsToKvm(state.xcrs);
    _ = try kvm.ioctl(machine.vcpu_fds[0], kvm.KVM_SET_XCRS, @intFromPtr(&xcrs), "KVM_SET_XCRS restore");
    _ = try kvm.ioctl(machine.vcpu_fds[0], kvm.KVM_SET_XSAVE, @intFromPtr(xsave.ptr), "KVM_SET_XSAVE restore");
    _ = try kvm.ioctl(machine.vcpu_fds[0], kvm.KVM_SET_TSC_KHZ, state.tsc_khz, "KVM_SET_TSC_KHZ BSP");
    try restoreMsrs(machine.vcpu_fds[0], state.msrs);
    try kvm.setTscOffset(machine.vcpu_fds[0], @bitCast(state.tsc_offset));
    var regs = stateGprsToKvm(state.gprs);
    _ = try kvm.ioctl(machine.vcpu_fds[0], kvm.KVM_SET_REGS, @intFromPtr(&regs), "KVM_SET_REGS restore");
    var clock = stateClockToKvm(state.clock);
    _ = try kvm.ioctl(machine.vm_fd, kvm.KVM_SET_CLOCK, @intFromPtr(&clock), "KVM_SET_CLOCK restore");
    _ = try kvm.ioctl(machine.vcpu_fds[0], kvm.KVM_KVMCLOCK_CTRL, 0, "KVM_KVMCLOCK_CTRL restore");
}

fn captureState(allocator: std.mem.Allocator, machine: *Machine) !state_file.State {
    var regs: kvm.Regs = undefined;
    _ = try kvm.ioctl(machine.vcpu_fds[0], kvm.KVM_GET_REGS, @intFromPtr(&regs), "KVM_GET_REGS capture");
    var sregs: kvm.Sregs = undefined;
    _ = try kvm.ioctl(machine.vcpu_fds[0], kvm.KVM_GET_SREGS, @intFromPtr(&sregs), "KVM_GET_SREGS capture");
    var effective = kvm.Cpuid{};
    _ = try kvm.ioctl(machine.vcpu_fds[0], kvm.KVM_GET_CPUID2, @intFromPtr(&effective), "KVM_GET_CPUID2 capture");
    const cpuid = try kvmCpuidToState(allocator, &effective);
    errdefer allocator.free(cpuid);
    var xcrs_raw = kvm.Xcrs{};
    _ = try kvm.ioctl(machine.vcpu_fds[0], kvm.KVM_GET_XCRS, @intFromPtr(&xcrs_raw), "KVM_GET_XCRS capture");
    const xcrs = try kvmXcrsToState(allocator, &xcrs_raw);
    errdefer allocator.free(xcrs);
    const xsave_storage = try allocator.alloc(u8, machine.xsave_size);
    const xsave = try kvm.xsave2Buffer(xsave_storage, machine.xsave_size);
    errdefer allocator.free(xsave);
    const get_xsave = if (machine.xsave_size == @sizeOf(kvm.Xsave)) kvm.KVM_GET_XSAVE else kvm.KVM_GET_XSAVE2;
    _ = try kvm.ioctl(machine.vcpu_fds[0], get_xsave, @intFromPtr(xsave.ptr), "KVM_GET_XSAVE capture");
    const msrs = try captureMsrs(allocator, machine.kvm_fd, machine.vcpu_fds[0]);
    errdefer allocator.free(msrs);
    const tsc_khz = try positiveIoctl(machine.vcpu_fds[0], kvm.KVM_GET_TSC_KHZ, "KVM_GET_TSC_KHZ capture");
    const tsc_offset: i64 = @bitCast(try kvm.getTscOffset(machine.vcpu_fds[0]));
    var clock: kvm.ClockData = .{};
    _ = try kvm.ioctl(machine.vm_fd, kvm.KVM_GET_CLOCK, @intFromPtr(&clock), "KVM_GET_CLOCK capture");
    const ram = try allocator.dupe(u8, machine.ram);
    errdefer allocator.free(ram);
    return .{
        .cpuid = cpuid,
        .gprs = kvmGprsToState(regs),
        .sregs = kvmSregsToState(sregs),
        .xcrs = xcrs,
        .xsave = xsave,
        .xstate_bv = readInt(u64, xsave, 512),
        .xcomp_bv = readInt(u64, xsave, 520),
        .msrs = msrs,
        .tsc_khz = tsc_khz,
        .tsc_offset = tsc_offset,
        .clock = kvmClockToState(clock),
        .mailbox = machine.mailbox_page[0..mailbox.page_size].*,
        .ram = ram,
    };
}

fn runUntilDoorbell(machine: *Machine, phase: mailbox.Phase, nonce: u64) !mailbox.Message {
    while (true) {
        const result = try kvm.runVcpu(machine.vcpu_fds[0]);
        if (result != .completed) continue;
        switch (kvm.exitReason(machine.run)) {
            kvm.KVM_EXIT_IO => {
                const exit = try kvm.decodeIoExit(machine.run);
                const action = try pio.handle(.{
                    .direction = if (exit.direction == .read) .read else .write,
                    .width = exit.width,
                    .port = exit.port,
                    .count = exit.count,
                    .data = exit.data,
                });
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
    for (cpu_profile.stage0b2_msr_inventory) |descriptor| {
        if (descriptor.disposition == .excluded) continue;
        const present = std.mem.indexOfScalar(u32, advertised, descriptor.index) != null;
        if (!present and descriptor.disposition == .required) return error.RequiredMsrMissing;
        if (!present) continue;
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
    for ([_]cpu_profile.Stage0b2MsrOrder{ .kernel, .paravirtual, .tsc_adjust, .tsc }) |order| {
        var batch = kvm.MsrBatch(msr_capacity){};
        var count: usize = 0;
        for (cpu_profile.stage0b2_msr_inventory) |descriptor| {
            if (descriptor.order != order or descriptor.disposition == .excluded) continue;
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
    const gprs_equal = std.meta.eql(expected.gprs, actual.gprs);
    const sregs_equal = stage0b2SregsEqual(expected.sregs, actual.sregs);
    const cpuid_equal = structSlicesEqual(state_file.CpuidEntry, expected.cpuid, actual.cpuid);
    const xcrs_equal = structSlicesEqual(state_file.Xcr, expected.xcrs, actual.xcrs);
    const xsave_equal = std.mem.eql(u8, expected.xsave, actual.xsave);
    const msrs_equal = stage0b2MsrsEqual(expected.msrs, actual.msrs);
    const tsc_equal = expected.tsc_khz == actual.tsc_khz and expected.tsc_offset == actual.tsc_offset;
    const mailbox_equal = std.mem.eql(u8, &expected.mailbox, &actual.mailbox);
    // Restoring MSR_KVM_WALL_CLOCK_NEW synchronously rewrites its guest
    // pvclock page, so whole-RAM byte equality is not a valid pre-run
    // invariant after restoreMsrs. The state checksum protects the saved RAM;
    // the dedicated mailbox remains byte-exact here.
    // KVM consumes REALTIME/HOST_TSC as SET_CLOCK re-anchoring inputs and the
    // following GET_CLOCK reports flags=0 on this kernel. The comparable
    // invariant is the guest clock value; Stage 0b.3 owns the final flag policy.
    const clock_valid = actual.clock.clock >= expected.clock.clock;
    if (!gprs_equal or !sregs_equal or !cpuid_equal or !xcrs_equal or !xsave_equal or !msrs_equal or !tsc_equal or !mailbox_equal or !clock_valid) {
        std.debug.print("sporevm kvm-profile-roundtrip: restore-readback gprs={} sregs={} cpuid={} xcrs={} xsave={} msrs={} tsc={} mailbox={} clock={} expected_rip=0x{x} actual_rip=0x{x}\n", .{
            gprs_equal, sregs_equal, cpuid_equal, xcrs_equal, xsave_equal, msrs_equal, tsc_equal, mailbox_equal, clock_valid, expected.gprs.rip, actual.gprs.rip,
        });
        if (!sregs_equal) logSregsDifference(expected.sregs, actual.sregs);
        if (!clock_valid) std.debug.print("clock expected={any} actual={any}\n", .{ expected.clock, actual.clock });
        return error.RestoreReadbackMismatch;
    }
}

fn stage0b2MsrsEqual(expected: []const state_file.Msr, actual: []const state_file.Msr) bool {
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

fn stage0b2SregsEqual(expected_value: state_file.Sregs, actual_value: state_file.Sregs) bool {
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
    return .{ .clock = v.clock, .flags = v.flags, .realtime = v.realtime, .host_tsc = v.host_tsc };
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

test "Stage 0b.2 CPUID exposes only the proved extended-state layout" {
    var cpuid = kvm.Cpuid{ .nent = 6 };
    cpuid.entries[0] = .{ .function = 7, .index = 0, .eax = std.math.maxInt(u32), .ebx = std.math.maxInt(u32), .ecx = std.math.maxInt(u32), .edx = std.math.maxInt(u32) };
    cpuid.entries[1] = .{ .function = 7, .index = 1, .eax = std.math.maxInt(u32), .ebx = std.math.maxInt(u32), .ecx = std.math.maxInt(u32), .edx = std.math.maxInt(u32) };
    cpuid.entries[2] = .{ .function = 0x0d, .index = 0, .eax = std.math.maxInt(u32), .ebx = 4096, .ecx = 4096, .edx = std.math.maxInt(u32) };
    cpuid.entries[3] = .{ .function = 0x0d, .index = 1, .eax = std.math.maxInt(u32), .ebx = 4096, .ecx = std.math.maxInt(u32), .edx = std.math.maxInt(u32) };
    cpuid.entries[4] = .{ .function = 0x0d, .index = 2, .eax = 128, .ebx = 128, .ecx = std.math.maxInt(u32), .edx = std.math.maxInt(u32) };
    cpuid.entries[5] = .{ .function = 0x0d, .index = 9, .eax = 8, .ebx = 2688, .ecx = 0, .edx = 0 };
    filterStage0b2Cpuid(&cpuid);

    try std.testing.expectEqual(@as(u32, 1 << 1), cpuid.entries[0].ebx);
    inline for (.{ 0, 1, 2, 3 }) |field_index| {
        const field = std.meta.fields(kvm.CpuidEntry)[3 + field_index].name;
        if (!std.mem.eql(u8, field, "ebx")) try std.testing.expectEqual(@as(u32, 0), @field(cpuid.entries[0], field));
        try std.testing.expectEqual(@as(u32, 0), @field(cpuid.entries[1], field));
    }
    try std.testing.expectEqual(@as(u32, 7), cpuid.entries[2].eax);
    try std.testing.expectEqual(stage0b2_xsave_layout_size, cpuid.entries[2].ebx);
    try std.testing.expectEqual(stage0b2_xsave_layout_size, cpuid.entries[2].ecx);
    try std.testing.expectEqual(@as(u32, 0), cpuid.entries[2].edx);
    try std.testing.expectEqual(@as(u32, 256), cpuid.entries[4].eax);
    try std.testing.expectEqual(@as(u32, 576), cpuid.entries[4].ebx);
    inline for (.{ cpuid.entries[3].eax, cpuid.entries[3].ebx, cpuid.entries[3].ecx, cpuid.entries[3].edx }) |value| try std.testing.expectEqual(@as(u32, 0), value);
    inline for (.{ cpuid.entries[5].eax, cpuid.entries[5].ebx, cpuid.entries[5].ecx, cpuid.entries[5].edx }) |value| try std.testing.expectEqual(@as(u32, 0), value);
}
