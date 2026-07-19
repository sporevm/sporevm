//! Normalized, task-local state for the Stage 0b.3 x86 profile round-trip.
//!
//! This is deliberately not a Spore manifest and never serializes KVM extern
//! structs. Every architectural field is encoded explicitly in little-endian
//! order, followed by a SHA-256 digest over the complete payload.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const magic = "SPX86RT\x00".*;
pub const format_version: u32 = 3;
pub const vcpu_count: usize = 2;
pub const mailbox_size: usize = 4096;
pub const max_ram_bytes: usize = 64 * 1024 * 1024;
pub const max_cpuid_entries: usize = 256;
pub const max_xcrs: usize = 16;
pub const max_msrs: usize = 64;
pub const max_xsave_bytes: usize = 64 * 1024;
pub const xsave_legacy_and_header_bytes: usize = 512 + 64;
pub const xsave_avx_end: usize = xsave_legacy_and_header_bytes + 16 * 16;
pub const supported_xstate_mask: u64 = 0b111;
pub const max_encoded_bytes: usize = max_ram_bytes + vcpu_count * (max_xsave_bytes + max_cpuid_entries * 7 * 4 + max_xcrs * (4 + 8) + max_msrs * (4 + 8)) + mailbox_size + 64 * 1024;

const digest_len = Sha256.digest_length;
const vcpu_count_fields_len = 5 * 4;
const clock_encoded_len = 8 + 4 + 4 + 8 + 8;
const fixed_prefix_len = magic.len + 4 + 4 + 8 + 4 + 4 + vcpu_count * vcpu_count_fields_len + clock_encoded_len;
const segment_flag_fields = .{ "type", "present", "dpl", "db", "s", "l", "g", "avl", "unusable" };
const sreg_segment_fields = .{ "cs", "ds", "es", "fs", "gs", "ss", "tr", "ldt" };
const sreg_control_fields = .{ "cr0", "cr2", "cr3", "cr4", "cr8", "efer", "apic_base" };
const gpr_fields = .{ "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rsp", "rbp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "rip", "rflags" };
const gpr_encoded_len = gpr_fields.len * 8;
const segment_encoded_len = 8 + 4 + 2 + segment_flag_fields.len;
const dtable_encoded_len = 8 + 2;
const sregs_encoded_len = sreg_segment_fields.len * segment_encoded_len + 2 * dtable_encoded_len + sreg_control_fields.len * 8 + 4 * 8;
const cpuid_fields = .{ "function", "index", "flags", "eax", "ebx", "ecx", "edx" };
const cpuid_encoded_len = cpuid_fields.len * 4;
const xcr_encoded_len = 4 + 8;
const msr_encoded_len = 4 + 8;
const lapic_prefix_fields = .{ "id", "version", "tpr", "apr", "ppr", "eoi", "ldr", "dfr", "svr" };
const lapic_suffix_fields = .{ "esr", "lvt_cmci", "icr_low", "icr_high", "lvt_timer", "lvt_thermal", "lvt_performance", "lvt_lint0", "lvt_lint1", "lvt_error", "initial_count", "current_count", "divide_config" };
const lapic_encoded_len = (lapic_prefix_fields.len + 3 * 8 + lapic_suffix_fields.len) * 4;
const vcpu_event_u32_fields = .{
    "exception_injected", "exception_number", "exception_has_error_code", "exception_pending",    "exception_error_code",
    "interrupt_injected", "interrupt_number", "interrupt_is_soft",        "interrupt_shadow",     "nmi_injected",
    "nmi_pending",        "nmi_masked",       "sipi_vector",              "flags",                "smm",
    "pending_smi",        "smm_inside_nmi",   "latched_init",             "triple_fault_pending", "exception_has_payload",
};
const vcpu_events_encoded_len = vcpu_event_u32_fields.len * 4 + 8;
const debug_scalar_fields = .{ "dr6", "dr7", "flags" };
const debug_encoded_len = (4 + debug_scalar_fields.len) * 8;
const vcpu_machine_encoded_len = 4 + lapic_encoded_len + vcpu_events_encoded_len + debug_encoded_len;
const vcpu_arch_scalar_encoded_len = 4 * 8;
const vcpu_fixed_encoded_len = vcpu_arch_scalar_encoded_len + gpr_encoded_len + sregs_encoded_len + vcpu_machine_encoded_len;
const pic_fields = .{ "last_irr", "irr", "imr", "isr", "priority_add", "irq_base", "read_reg_select", "poll", "special_mask", "init_state", "auto_eoi", "rotate_on_auto_eoi", "special_fully_nested_mode", "init4", "elcr", "elcr_mask" };
const pic_encoded_len = pic_fields.len;
const ioapic_encoded_len = 8 + 3 * 4 + 24 * 8;
const pit_channel_u8_fields = .{ "count_latched", "status_latched", "status", "read_state", "write_state", "write_latch", "rw_mode", "mode", "bcd", "gate" };
const pit_channel_encoded_len = 4 + 2 + pit_channel_u8_fields.len + 8;
const pit2_encoded_len = 3 * pit_channel_encoded_len + 4;
const shared_machine_encoded_len = 2 * pic_encoded_len + ioapic_encoded_len + pit2_encoded_len;

pub const Error = error{
    BadChecksum,
    BadMagic,
    BadVersion,
    DuplicateOrUnorderedCpuid,
    DuplicateOrUnorderedMsr,
    DuplicateOrUnorderedXcr,
    InputTooLarge,
    InvalidClockFlags,
    InvalidBoolean,
    InvalidDebugFlags,
    InvalidEventFlags,
    InvalidEventValue,
    InvalidInterruptShadow,
    InvalidPitFlags,
    InvalidReservedField,
    InvalidTscFrequency,
    InvalidVcpuCount,
    InvalidXstate,
    NonCanonicalLength,
    Overflow,
    TooManyCpuidEntries,
    TooManyMsrs,
    TooManyXcrs,
    Truncated,
    UnsupportedRamSize,
    XsaveTooLarge,
    XsaveTooSmall,
};

pub const CpuidEntry = struct {
    function: u32,
    index: u32,
    flags: u32,
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

pub const Gprs = struct {
    rax: u64 = 0,
    rbx: u64 = 0,
    rcx: u64 = 0,
    rdx: u64 = 0,
    rsi: u64 = 0,
    rdi: u64 = 0,
    rsp: u64 = 0,
    rbp: u64 = 0,
    r8: u64 = 0,
    r9: u64 = 0,
    r10: u64 = 0,
    r11: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
    rip: u64 = 0,
    rflags: u64 = 0,
};

pub const Segment = struct {
    base: u64 = 0,
    limit: u32 = 0,
    selector: u16 = 0,
    type: u8 = 0,
    present: u8 = 0,
    dpl: u8 = 0,
    db: u8 = 0,
    s: u8 = 0,
    l: u8 = 0,
    g: u8 = 0,
    avl: u8 = 0,
    unusable: u8 = 0,
};

pub const Dtable = struct {
    base: u64 = 0,
    limit: u16 = 0,
};

pub const Sregs = struct {
    cs: Segment = .{},
    ds: Segment = .{},
    es: Segment = .{},
    fs: Segment = .{},
    gs: Segment = .{},
    ss: Segment = .{},
    tr: Segment = .{},
    ldt: Segment = .{},
    gdt: Dtable = .{},
    idt: Dtable = .{},
    cr0: u64 = 0,
    cr2: u64 = 0,
    cr3: u64 = 0,
    cr4: u64 = 0,
    cr8: u64 = 0,
    efer: u64 = 0,
    apic_base: u64 = 0,
    interrupt_bitmap: [4]u64 = @splat(0),
};

pub const Xcr = struct {
    index: u32,
    value: u64,
};

pub const Msr = struct {
    index: u32,
    value: u64,
};

pub const Clock = struct {
    clock: u64 = 0,
    flags: u32 = 0,
    realtime: u64 = 0,
    host_tsc: u64 = 0,
};

/// Architectural xAPIC register values. Array entries correspond to ISR/TMR/IRR
/// register banks in ascending architectural register order, not KVM byte
/// offsets. Reserved bytes in `struct kvm_lapic_state` never cross this boundary.
pub const Lapic = struct {
    id: u32 = 0,
    version: u32 = 0,
    tpr: u32 = 0,
    apr: u32 = 0,
    ppr: u32 = 0,
    eoi: u32 = 0,
    ldr: u32 = 0,
    dfr: u32 = 0,
    svr: u32 = 0,
    isr: [8]u32 = @splat(0),
    tmr: [8]u32 = @splat(0),
    irr: [8]u32 = @splat(0),
    esr: u32 = 0,
    lvt_cmci: u32 = 0,
    icr_low: u32 = 0,
    icr_high: u32 = 0,
    lvt_timer: u32 = 0,
    lvt_thermal: u32 = 0,
    lvt_performance: u32 = 0,
    lvt_lint0: u32 = 0,
    lvt_lint1: u32 = 0,
    lvt_error: u32 = 0,
    initial_count: u32 = 0,
    current_count: u32 = 0,
    divide_config: u32 = 0,
};

pub const VcpuEvents = struct {
    exception_injected: u32 = 0,
    exception_number: u32 = 0,
    exception_has_error_code: u32 = 0,
    exception_pending: u32 = 0,
    exception_error_code: u32 = 0,
    interrupt_injected: u32 = 0,
    interrupt_number: u32 = 0,
    interrupt_is_soft: u32 = 0,
    interrupt_shadow: u32 = 0,
    nmi_injected: u32 = 0,
    nmi_pending: u32 = 0,
    nmi_masked: u32 = 0,
    sipi_vector: u32 = 0,
    /// Canonical KVM_VCPUEVENT_VALID_* bitmap. The payload remains semantic,
    /// while this records which optional fields KVM considered authoritative.
    flags: u32 = 0,
    smm: u32 = 0,
    pending_smi: u32 = 0,
    smm_inside_nmi: u32 = 0,
    latched_init: u32 = 0,
    triple_fault_pending: u32 = 0,
    exception_has_payload: u32 = 0,
    exception_payload: u64 = 0,
};

pub const DebugState = struct {
    db: [4]u64 = @splat(0),
    dr6: u64 = 0,
    dr7: u64 = 0,
    /// KVM currently defines no portable debug-state flags; fail closed if it
    /// starts returning one rather than silently persisting host ABI state.
    flags: u64 = 0,
};

pub const VcpuMachineState = struct {
    cpuid: []CpuidEntry,
    gprs: Gprs,
    sregs: Sregs,
    xcrs: []Xcr,
    /// Exact architectural XSAVE area bytes. KVM transfer-buffer padding is
    /// excluded by capture and reconstructed as zeroes for KVM_SET_XSAVE.
    xsave: []u8,
    xstate_bv: u64,
    xcomp_bv: u64,
    msrs: []Msr,
    tsc_khz: u64,
    tsc_offset: i64,
    mp_state: u32 = 0,
    lapic: Lapic = .{},
    events: VcpuEvents = .{},
    debug: DebugState = .{},

    pub fn deinit(self: *VcpuMachineState, allocator: std.mem.Allocator) void {
        allocator.free(self.cpuid);
        allocator.free(self.xcrs);
        allocator.free(self.xsave);
        allocator.free(self.msrs);
        self.* = undefined;
    }
};

pub const Pic = struct {
    last_irr: u8 = 0,
    irr: u8 = 0,
    imr: u8 = 0,
    isr: u8 = 0,
    priority_add: u8 = 0,
    irq_base: u8 = 0,
    read_reg_select: u8 = 0,
    poll: u8 = 0,
    special_mask: u8 = 0,
    init_state: u8 = 0,
    auto_eoi: u8 = 0,
    rotate_on_auto_eoi: u8 = 0,
    special_fully_nested_mode: u8 = 0,
    init4: u8 = 0,
    elcr: u8 = 0,
    elcr_mask: u8 = 0,
};

pub const Ioapic = struct {
    base_address: u64 = 0,
    ioregsel: u32 = 0,
    id: u32 = 0,
    irr: u32 = 0,
    redirection_table: [24]u64 = @splat(0),
};

pub const PitChannel = struct {
    count: u32 = 0,
    latched_count: u16 = 0,
    count_latched: u8 = 0,
    status_latched: u8 = 0,
    status: u8 = 0,
    read_state: u8 = 0,
    write_state: u8 = 0,
    write_latch: u8 = 0,
    rw_mode: u8 = 0,
    mode: u8 = 0,
    bcd: u8 = 0,
    gate: u8 = 0,
    count_load_time: i64 = 0,
};

pub const Pit2 = struct {
    channels: [3]PitChannel = @splat(.{}),
    flags: u32 = 0,
};

pub const State = struct {
    clock: Clock,
    vcpus: [vcpu_count]VcpuMachineState,
    pic_master: Pic,
    pic_slave: Pic,
    ioapic: Ioapic,
    pit2: Pit2,
    mailbox: [mailbox_size]u8,
    ram: []u8,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (&self.vcpus) |*vcpu| vcpu.deinit(allocator);
        allocator.free(self.ram);
        self.* = undefined;
    }

    pub fn validate(self: *const State) Error!void {
        if (self.ram.len == 0 or self.ram.len > max_ram_bytes) return error.UnsupportedRamSize;
        if (self.clock.flags & ~@as(u32, 0x0e) != 0) return error.InvalidClockFlags;
        for (self.vcpus) |vcpu| try validateVcpuMachineState(vcpu);
        try validatePic(self.pic_master);
        try validatePic(self.pic_slave);
        for (self.pit2.channels) |channel| {
            try validateBool(channel.count_latched);
            try validateBool(channel.status_latched);
            try validateBool(channel.bcd);
            try validateBool(channel.gate);
        }
        if (self.pit2.flags & ~@as(u32, 1) != 0) return error.InvalidPitFlags;
    }
};

pub fn encode(allocator: std.mem.Allocator, state: *const State) (Error || std.mem.Allocator.Error)![]u8 {
    try state.validate();
    const payload_len = try encodedPayloadLen(state);
    const total_len = std.math.add(usize, payload_len, digest_len) catch return error.Overflow;
    if (total_len > max_encoded_bytes) return error.InputTooLarge;
    const bytes = try allocator.alloc(u8, total_len);
    errdefer allocator.free(bytes);

    var encoder = Encoder{ .bytes = bytes[0..payload_len] };
    encoder.bytesRaw(&magic);
    encoder.int(u32, format_version);
    encoder.int(u32, 0);
    encoder.int(u64, @intCast(total_len));
    encoder.int(u32, @intCast(state.ram.len));
    encoder.int(u32, vcpu_count);
    for (state.vcpus) |vcpu| encodeVcpuCounts(&encoder, countsFor(vcpu));
    encoder.int(u64, state.clock.clock);
    encoder.int(u32, state.clock.flags);
    encoder.int(u32, 0);
    encoder.int(u64, state.clock.realtime);
    encoder.int(u64, state.clock.host_tsc);
    for (state.vcpus) |vcpu| encodeVcpuState(&encoder, vcpu);
    encodePic(&encoder, state.pic_master);
    encodePic(&encoder, state.pic_slave);
    encodeIoapic(&encoder, state.ioapic);
    encodePit2(&encoder, state.pit2);
    encoder.bytesRaw(&state.mailbox);
    encoder.bytesRaw(state.ram);
    std.debug.assert(encoder.offset == payload_len);
    Sha256.hash(bytes[0..payload_len], bytes[payload_len..][0..digest_len], .{});
    return bytes;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) (Error || std.mem.Allocator.Error)!State {
    if (bytes.len > max_encoded_bytes) return error.InputTooLarge;
    if (bytes.len < fixed_prefix_len + vcpu_count * vcpu_fixed_encoded_len + shared_machine_encoded_len + mailbox_size + digest_len) {
        return error.Truncated;
    }
    const payload_len = bytes.len - digest_len;
    var actual_digest: [digest_len]u8 = undefined;
    Sha256.hash(bytes[0..payload_len], &actual_digest, .{});
    if (!std.crypto.timing_safe.eql([digest_len]u8, actual_digest, bytes[payload_len..][0..digest_len].*)) {
        return error.BadChecksum;
    }

    var decoder = Decoder{ .bytes = bytes[0..payload_len] };
    var observed_magic: [magic.len]u8 = undefined;
    decoder.bytesRaw(&observed_magic) catch return error.Truncated;
    if (!std.mem.eql(u8, &observed_magic, &magic)) return error.BadMagic;
    if ((decoder.int(u32) catch return error.Truncated) != format_version) return error.BadVersion;
    if ((decoder.int(u32) catch return error.Truncated) != 0) return error.InvalidReservedField;
    const declared_total = decoder.int(u64) catch return error.Truncated;
    if (declared_total != bytes.len) return error.NonCanonicalLength;
    const ram_len = decoder.int(u32) catch return error.Truncated;
    if ((decoder.int(u32) catch return error.Truncated) != vcpu_count) return error.InvalidVcpuCount;
    var counts: [vcpu_count]VcpuCounts = undefined;
    for (&counts) |*vcpu_counts| vcpu_counts.* = decodeVcpuCounts(&decoder) catch |err| return err;
    const clock_value = decoder.int(u64) catch return error.Truncated;
    const clock_flags = decoder.int(u32) catch return error.Truncated;
    if ((decoder.int(u32) catch return error.Truncated) != 0) return error.InvalidReservedField;
    const clock_realtime = decoder.int(u64) catch return error.Truncated;
    const clock_host_tsc = decoder.int(u64) catch return error.Truncated;

    if (ram_len == 0 or ram_len > max_ram_bytes) return error.UnsupportedRamSize;
    for (counts) |vcpu_counts| try validateVcpuCounts(vcpu_counts);
    const expected_payload_len = encodedPayloadLenFromCounts(ram_len, counts) catch return error.Overflow;
    if (expected_payload_len != payload_len) return error.NonCanonicalLength;

    var vcpus: [vcpu_count]VcpuMachineState = undefined;
    var decoded_vcpu_count: usize = 0;
    errdefer for (vcpus[0..decoded_vcpu_count]) |*vcpu| vcpu.deinit(allocator);
    for (&vcpus, counts) |*vcpu, vcpu_counts| {
        vcpu.* = try decodeVcpuState(&decoder, allocator, vcpu_counts);
        decoded_vcpu_count += 1;
    }
    const pic_master = decodePic(&decoder) catch return error.Truncated;
    const pic_slave = decodePic(&decoder) catch return error.Truncated;
    const ioapic = decodeIoapic(&decoder) catch return error.Truncated;
    const pit2 = decodePit2(&decoder) catch return error.Truncated;
    var mailbox: [mailbox_size]u8 = undefined;
    decoder.bytesRaw(&mailbox) catch return error.Truncated;
    const ram = try allocator.alloc(u8, ram_len);
    var ram_owned_by_state = false;
    errdefer if (!ram_owned_by_state) allocator.free(ram);
    decoder.bytesRaw(ram) catch return error.Truncated;
    if (decoder.offset != decoder.bytes.len) return error.NonCanonicalLength;

    var state = State{
        .clock = .{ .clock = clock_value, .flags = clock_flags, .realtime = clock_realtime, .host_tsc = clock_host_tsc },
        .vcpus = vcpus,
        .pic_master = pic_master,
        .pic_slave = pic_slave,
        .ioapic = ioapic,
        .pit2 = pit2,
        .mailbox = mailbox,
        .ram = ram,
    };
    decoded_vcpu_count = 0;
    ram_owned_by_state = true;
    errdefer state.deinit(allocator);
    try state.validate();
    return state;
}

const VcpuCounts = struct {
    cpuid: usize,
    xcrs: usize,
    xsave: usize,
    msrs: usize,
};

fn countsFor(vcpu: VcpuMachineState) VcpuCounts {
    return .{ .cpuid = vcpu.cpuid.len, .xcrs = vcpu.xcrs.len, .xsave = vcpu.xsave.len, .msrs = vcpu.msrs.len };
}

fn encodeVcpuCounts(encoder: *Encoder, counts: VcpuCounts) void {
    encoder.int(u32, @intCast(counts.cpuid));
    encoder.int(u32, @intCast(counts.xcrs));
    encoder.int(u32, @intCast(counts.xsave));
    encoder.int(u32, @intCast(counts.msrs));
    encoder.int(u32, 0);
}

fn decodeVcpuCounts(decoder: *Decoder) Error!VcpuCounts {
    const counts = VcpuCounts{
        .cpuid = decoder.int(u32) catch return error.Truncated,
        .xcrs = decoder.int(u32) catch return error.Truncated,
        .xsave = decoder.int(u32) catch return error.Truncated,
        .msrs = decoder.int(u32) catch return error.Truncated,
    };
    if ((decoder.int(u32) catch return error.Truncated) != 0) return error.InvalidReservedField;
    return counts;
}

fn validateVcpuCounts(counts: VcpuCounts) Error!void {
    if (counts.cpuid > max_cpuid_entries) return error.TooManyCpuidEntries;
    if (counts.xcrs > max_xcrs) return error.TooManyXcrs;
    if (counts.xsave < xsave_legacy_and_header_bytes) return error.XsaveTooSmall;
    if (counts.xsave > max_xsave_bytes) return error.XsaveTooLarge;
    if (counts.msrs > max_msrs) return error.TooManyMsrs;
}

pub fn validateXsaveBytes(xsave: []const u8, xstate_bv: u64, xcomp_bv: u64) Error!void {
    if (xsave.len != xsave_avx_end) return error.InvalidXstate;
    if (xstate_bv & ~supported_xstate_mask != 0 or xcomp_bv != 0) return error.InvalidXstate;
    if (xstate_bv & 0b010 != 0 and xstate_bv & 0b001 == 0) return error.InvalidXstate;
    if (xstate_bv & 0b100 != 0) {
        if (xstate_bv & 0b011 != 0b011) return error.InvalidXstate;
    }
    if (std.mem.readInt(u64, xsave[512..520], .little) != xstate_bv or
        std.mem.readInt(u64, xsave[520..528], .little) != xcomp_bv or
        !allZero(xsave[528..xsave_legacy_and_header_bytes])) return error.InvalidXstate;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn validateBool(value: anytype) Error!void {
    if (value > 1) return error.InvalidBoolean;
}

fn validateVcpuMachineState(value: VcpuMachineState) Error!void {
    try validateVcpuCounts(countsFor(value));
    if (value.tsc_khz == 0) return error.InvalidTscFrequency;
    try validateXsaveBytes(value.xsave, value.xstate_bv, value.xcomp_bv);
    for (value.cpuid, 0..) |entry, index| {
        if (index == 0) continue;
        const previous = value.cpuid[index - 1];
        if (entry.function < previous.function or
            (entry.function == previous.function and entry.index <= previous.index))
        {
            return error.DuplicateOrUnorderedCpuid;
        }
    }
    for (value.xcrs, 0..) |entry, index| {
        if (index > 0 and entry.index <= value.xcrs[index - 1].index) return error.DuplicateOrUnorderedXcr;
    }
    for (value.msrs, 0..) |entry, index| {
        if (index > 0 and entry.index <= value.msrs[index - 1].index) return error.DuplicateOrUnorderedMsr;
    }
    inline for (.{
        "exception_injected",
        "exception_has_error_code",
        "exception_pending",
        "interrupt_injected",
        "interrupt_is_soft",
        "nmi_injected",
        "nmi_pending",
        "nmi_masked",
        "smm",
        "pending_smi",
        "smm_inside_nmi",
        "latched_init",
        "triple_fault_pending",
        "exception_has_payload",
    }) |name| try validateBool(@field(value.events, name));
    if (value.events.interrupt_shadow & ~@as(u32, 3) != 0) return error.InvalidInterruptShadow;
    inline for (.{ "exception_number", "interrupt_number" }) |name| {
        if (@field(value.events, name) > std.math.maxInt(u8)) return error.InvalidEventValue;
    }
    if (value.events.flags & ~@as(u32, 0x3f) != 0) return error.InvalidEventFlags;
    if (value.events.nmi_pending != 0 and value.events.flags & 0x01 == 0 or
        value.events.sipi_vector != 0 and value.events.flags & 0x02 == 0 or
        value.events.interrupt_shadow != 0 and value.events.flags & 0x04 == 0 or
        (value.events.smm != 0 or value.events.pending_smi != 0 or value.events.smm_inside_nmi != 0 or value.events.latched_init != 0) and value.events.flags & 0x08 == 0 or
        (value.events.exception_has_payload != 0 or value.events.exception_payload != 0) and value.events.flags & 0x10 == 0 or
        value.events.triple_fault_pending != 0 and value.events.flags & 0x20 == 0)
    {
        return error.InvalidEventFlags;
    }
    if (value.debug.flags != 0) return error.InvalidDebugFlags;
}

fn validatePic(value: Pic) Error!void {
    inline for (.{
        "read_reg_select",
        "poll",
        "special_mask",
        "auto_eoi",
        "rotate_on_auto_eoi",
        "special_fully_nested_mode",
        "init4",
    }) |name| try validateBool(@field(value, name));
}

fn encodedPayloadLen(state: *const State) Error!usize {
    var counts: [vcpu_count]VcpuCounts = undefined;
    for (state.vcpus, 0..) |vcpu, index| counts[index] = countsFor(vcpu);
    return encodedPayloadLenFromCounts(state.ram.len, counts);
}

fn encodedPayloadLenFromCounts(ram_len: anytype, counts: [vcpu_count]VcpuCounts) Error!usize {
    var total: usize = fixed_prefix_len + vcpu_count * vcpu_fixed_encoded_len + shared_machine_encoded_len + mailbox_size;
    for (counts) |vcpu_counts| {
        total = checkedAddMul(total, vcpu_counts.cpuid, cpuid_encoded_len) catch return error.Overflow;
        total = checkedAddMul(total, vcpu_counts.xcrs, xcr_encoded_len) catch return error.Overflow;
        total = std.math.add(usize, total, vcpu_counts.xsave) catch return error.Overflow;
        total = checkedAddMul(total, vcpu_counts.msrs, msr_encoded_len) catch return error.Overflow;
    }
    total = std.math.add(usize, total, @intCast(ram_len)) catch return error.Overflow;
    return total;
}

fn checkedAddMul(base: usize, count: usize, item_len: usize) !usize {
    const bytes = try std.math.mul(usize, count, item_len);
    return std.math.add(usize, base, bytes);
}

const Encoder = struct {
    bytes: []u8,
    offset: usize = 0,

    fn int(self: *Encoder, comptime T: type, value: T) void {
        std.mem.writeInt(T, self.bytes[self.offset..][0..@sizeOf(T)], value, .little);
        self.offset += @sizeOf(T);
    }

    fn bytesRaw(self: *Encoder, value: []const u8) void {
        @memcpy(self.bytes[self.offset..][0..value.len], value);
        self.offset += value.len;
    }
};

const Decoder = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn int(self: *Decoder, comptime T: type) error{Truncated}!T {
        const end = std.math.add(usize, self.offset, @sizeOf(T)) catch return error.Truncated;
        if (end > self.bytes.len) return error.Truncated;
        defer self.offset = end;
        return std.mem.readInt(T, self.bytes[self.offset..][0..@sizeOf(T)], .little);
    }

    fn bytesRaw(self: *Decoder, out: []u8) error{Truncated}!void {
        const end = std.math.add(usize, self.offset, out.len) catch return error.Truncated;
        if (end > self.bytes.len) return error.Truncated;
        @memcpy(out, self.bytes[self.offset..end]);
        self.offset = end;
    }
};

fn encodeLapic(encoder: *Encoder, value: Lapic) void {
    inline for (lapic_prefix_fields) |name| encoder.int(u32, @field(value, name));
    for (value.isr) |word| encoder.int(u32, word);
    for (value.tmr) |word| encoder.int(u32, word);
    for (value.irr) |word| encoder.int(u32, word);
    inline for (lapic_suffix_fields) |name| encoder.int(u32, @field(value, name));
}

fn decodeLapic(decoder: *Decoder) error{Truncated}!Lapic {
    var value = Lapic{};
    inline for (lapic_prefix_fields) |name| @field(value, name) = try decoder.int(u32);
    for (&value.isr) |*word| word.* = try decoder.int(u32);
    for (&value.tmr) |*word| word.* = try decoder.int(u32);
    for (&value.irr) |*word| word.* = try decoder.int(u32);
    inline for (lapic_suffix_fields) |name| @field(value, name) = try decoder.int(u32);
    return value;
}

fn encodeVcpuEvents(encoder: *Encoder, value: VcpuEvents) void {
    inline for (vcpu_event_u32_fields) |name| encoder.int(u32, @field(value, name));
    encoder.int(u64, value.exception_payload);
}

fn decodeVcpuEvents(decoder: *Decoder) error{Truncated}!VcpuEvents {
    var value = VcpuEvents{};
    inline for (vcpu_event_u32_fields) |name| @field(value, name) = try decoder.int(u32);
    value.exception_payload = try decoder.int(u64);
    return value;
}

fn encodeDebug(encoder: *Encoder, value: DebugState) void {
    for (value.db) |register| encoder.int(u64, register);
    inline for (debug_scalar_fields) |name| encoder.int(u64, @field(value, name));
}

fn decodeDebug(decoder: *Decoder) error{Truncated}!DebugState {
    var value = DebugState{};
    for (&value.db) |*register| register.* = try decoder.int(u64);
    inline for (debug_scalar_fields) |name| @field(value, name) = try decoder.int(u64);
    return value;
}

fn encodeVcpuMachineState(encoder: *Encoder, value: VcpuMachineState) void {
    encoder.int(u32, value.mp_state);
    encodeLapic(encoder, value.lapic);
    encodeVcpuEvents(encoder, value.events);
    encodeDebug(encoder, value.debug);
}

fn encodeVcpuState(encoder: *Encoder, value: VcpuMachineState) void {
    encoder.int(u64, value.xstate_bv);
    encoder.int(u64, value.xcomp_bv);
    encoder.int(u64, value.tsc_khz);
    encoder.int(u64, @bitCast(value.tsc_offset));
    encodeVcpuMachineState(encoder, value);
    encodeGprs(encoder, value.gprs);
    encodeSregs(encoder, value.sregs);
    for (value.cpuid) |entry| encodeCpuid(encoder, entry);
    for (value.xcrs) |entry| {
        encoder.int(u32, entry.index);
        encoder.int(u64, entry.value);
    }
    encoder.bytesRaw(value.xsave);
    for (value.msrs) |entry| {
        encoder.int(u32, entry.index);
        encoder.int(u64, entry.value);
    }
}

fn decodeVcpuState(decoder: *Decoder, allocator: std.mem.Allocator, counts: VcpuCounts) (Error || std.mem.Allocator.Error)!VcpuMachineState {
    const xstate_bv = decoder.int(u64) catch return error.Truncated;
    const xcomp_bv = decoder.int(u64) catch return error.Truncated;
    const tsc_khz = decoder.int(u64) catch return error.Truncated;
    const tsc_offset: i64 = @bitCast(decoder.int(u64) catch return error.Truncated);
    const mp_state = decoder.int(u32) catch return error.Truncated;
    const lapic = decodeLapic(decoder) catch return error.Truncated;
    const events = decodeVcpuEvents(decoder) catch return error.Truncated;
    const debug = decodeDebug(decoder) catch return error.Truncated;
    const gprs = decodeGprs(decoder) catch return error.Truncated;
    const sregs = decodeSregs(decoder) catch return error.Truncated;
    const cpuid = try allocator.alloc(CpuidEntry, counts.cpuid);
    errdefer allocator.free(cpuid);
    for (cpuid) |*entry| entry.* = decodeCpuid(decoder) catch return error.Truncated;
    const xcrs = try allocator.alloc(Xcr, counts.xcrs);
    errdefer allocator.free(xcrs);
    for (xcrs) |*entry| entry.* = .{
        .index = decoder.int(u32) catch return error.Truncated,
        .value = decoder.int(u64) catch return error.Truncated,
    };
    const xsave = try allocator.alloc(u8, counts.xsave);
    errdefer allocator.free(xsave);
    decoder.bytesRaw(xsave) catch return error.Truncated;
    const msrs = try allocator.alloc(Msr, counts.msrs);
    errdefer allocator.free(msrs);
    for (msrs) |*entry| entry.* = .{
        .index = decoder.int(u32) catch return error.Truncated,
        .value = decoder.int(u64) catch return error.Truncated,
    };
    return .{
        .cpuid = cpuid,
        .gprs = gprs,
        .sregs = sregs,
        .xcrs = xcrs,
        .xsave = xsave,
        .xstate_bv = xstate_bv,
        .xcomp_bv = xcomp_bv,
        .msrs = msrs,
        .tsc_khz = tsc_khz,
        .tsc_offset = tsc_offset,
        .mp_state = mp_state,
        .lapic = lapic,
        .events = events,
        .debug = debug,
    };
}

fn encodePic(encoder: *Encoder, value: Pic) void {
    inline for (pic_fields) |name| encoder.int(u8, @field(value, name));
}

fn decodePic(decoder: *Decoder) error{Truncated}!Pic {
    var value = Pic{};
    inline for (pic_fields) |name| @field(value, name) = try decoder.int(u8);
    return value;
}

fn encodeIoapic(encoder: *Encoder, value: Ioapic) void {
    encoder.int(u64, value.base_address);
    encoder.int(u32, value.ioregsel);
    encoder.int(u32, value.id);
    encoder.int(u32, value.irr);
    for (value.redirection_table) |entry| encoder.int(u64, entry);
}

fn decodeIoapic(decoder: *Decoder) error{Truncated}!Ioapic {
    var value = Ioapic{
        .base_address = try decoder.int(u64),
        .ioregsel = try decoder.int(u32),
        .id = try decoder.int(u32),
        .irr = try decoder.int(u32),
    };
    for (&value.redirection_table) |*entry| entry.* = try decoder.int(u64);
    return value;
}

fn encodePitChannel(encoder: *Encoder, value: PitChannel) void {
    encoder.int(u32, value.count);
    encoder.int(u16, value.latched_count);
    inline for (pit_channel_u8_fields) |name| encoder.int(u8, @field(value, name));
    encoder.int(u64, @bitCast(value.count_load_time));
}

fn decodePitChannel(decoder: *Decoder) error{Truncated}!PitChannel {
    var value = PitChannel{
        .count = try decoder.int(u32),
        .latched_count = try decoder.int(u16),
    };
    inline for (pit_channel_u8_fields) |name| @field(value, name) = try decoder.int(u8);
    value.count_load_time = @bitCast(try decoder.int(u64));
    return value;
}

fn encodePit2(encoder: *Encoder, value: Pit2) void {
    for (value.channels) |channel| encodePitChannel(encoder, channel);
    encoder.int(u32, value.flags);
}

fn decodePit2(decoder: *Decoder) error{Truncated}!Pit2 {
    var value = Pit2{};
    for (&value.channels) |*channel| channel.* = try decodePitChannel(decoder);
    value.flags = try decoder.int(u32);
    return value;
}

fn encodeGprs(encoder: *Encoder, value: Gprs) void {
    inline for (gpr_fields) |name| encoder.int(u64, @field(value, name));
}

fn decodeGprs(decoder: *Decoder) error{Truncated}!Gprs {
    var value = Gprs{};
    inline for (gpr_fields) |name| @field(value, name) = try decoder.int(u64);
    return value;
}

fn encodeSegment(encoder: *Encoder, value: Segment) void {
    encoder.int(u64, value.base);
    encoder.int(u32, value.limit);
    encoder.int(u16, value.selector);
    inline for (segment_flag_fields) |name| {
        encoder.int(u8, @field(value, name));
    }
}

fn decodeSegment(decoder: *Decoder) error{Truncated}!Segment {
    var value = Segment{
        .base = try decoder.int(u64),
        .limit = try decoder.int(u32),
        .selector = try decoder.int(u16),
    };
    inline for (segment_flag_fields) |name| {
        @field(value, name) = try decoder.int(u8);
    }
    return value;
}

fn encodeDtable(encoder: *Encoder, value: Dtable) void {
    encoder.int(u64, value.base);
    encoder.int(u16, value.limit);
}

fn decodeDtable(decoder: *Decoder) error{Truncated}!Dtable {
    return .{ .base = try decoder.int(u64), .limit = try decoder.int(u16) };
}

fn encodeSregs(encoder: *Encoder, value: Sregs) void {
    inline for (sreg_segment_fields) |name| encodeSegment(encoder, @field(value, name));
    encodeDtable(encoder, value.gdt);
    encodeDtable(encoder, value.idt);
    inline for (sreg_control_fields) |name| encoder.int(u64, @field(value, name));
    for (value.interrupt_bitmap) |word| encoder.int(u64, word);
}

fn decodeSregs(decoder: *Decoder) error{Truncated}!Sregs {
    var value = Sregs{};
    inline for (sreg_segment_fields) |name| @field(value, name) = try decodeSegment(decoder);
    value.gdt = try decodeDtable(decoder);
    value.idt = try decodeDtable(decoder);
    inline for (sreg_control_fields) |name| @field(value, name) = try decoder.int(u64);
    for (&value.interrupt_bitmap) |*word| word.* = try decoder.int(u64);
    return value;
}

fn encodeCpuid(encoder: *Encoder, value: CpuidEntry) void {
    inline for (cpuid_fields) |name| encoder.int(u32, @field(value, name));
}

fn decodeCpuid(decoder: *Decoder) error{Truncated}!CpuidEntry {
    var value: CpuidEntry = undefined;
    inline for (cpuid_fields) |name| @field(value, name) = try decoder.int(u32);
    return value;
}
