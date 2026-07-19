//! Normalized, task-local state for the Stage 0b.2 x86 profile round-trip.
//!
//! This is deliberately not a Spore manifest and never serializes KVM extern
//! structs. Every architectural field is encoded explicitly in little-endian
//! order, followed by a SHA-256 digest over the complete payload.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const magic = "SPX86RT\x00".*;
pub const format_version: u32 = 1;
pub const mailbox_size: usize = 4096;
pub const max_ram_bytes: usize = 64 * 1024 * 1024;
pub const max_cpuid_entries: usize = 256;
pub const max_xcrs: usize = 16;
pub const max_msrs: usize = 64;
pub const max_xsave_bytes: usize = 64 * 1024;
pub const xsave_legacy_and_header_bytes: usize = 512 + 64;
pub const xsave_avx_end: usize = xsave_legacy_and_header_bytes + 16 * 16;
pub const supported_xstate_mask: u64 = 0b111;
pub const max_encoded_bytes: usize = max_ram_bytes + max_xsave_bytes + mailbox_size + 64 * 1024;

const digest_len = Sha256.digest_length;
const fixed_prefix_len = magic.len + 4 + 4 + 8 + 5 * 4 + 4 * 8 + 8 + 4 + 4 + 8 + 8;
const gpr_encoded_len = 18 * 8;
const segment_encoded_len = 8 + 4 + 2 + 9;
const dtable_encoded_len = 8 + 2;
const sregs_encoded_len = 8 * segment_encoded_len + 2 * dtable_encoded_len + 7 * 8 + 4 * 8;
const cpuid_encoded_len = 7 * 4;
const xcr_encoded_len = 4 + 8;
const msr_encoded_len = 4 + 8;

pub const Error = error{
    BadChecksum,
    BadMagic,
    BadVersion,
    DuplicateOrUnorderedCpuid,
    DuplicateOrUnorderedMsr,
    DuplicateOrUnorderedXcr,
    InputTooLarge,
    InvalidClockFlags,
    InvalidReservedField,
    InvalidTscFrequency,
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

pub const State = struct {
    cpuid: []CpuidEntry,
    gprs: Gprs,
    sregs: Sregs,
    xcrs: []Xcr,
    /// Architectural XSAVE area bytes only. KVM wrapper padding is excluded.
    xsave: []u8,
    xstate_bv: u64,
    xcomp_bv: u64,
    msrs: []Msr,
    tsc_khz: u64,
    tsc_offset: i64,
    clock: Clock,
    mailbox: [mailbox_size]u8,
    ram: []u8,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        allocator.free(self.cpuid);
        allocator.free(self.xcrs);
        allocator.free(self.xsave);
        allocator.free(self.msrs);
        allocator.free(self.ram);
        self.* = undefined;
    }

    pub fn validate(self: *const State) Error!void {
        if (self.ram.len == 0 or self.ram.len > max_ram_bytes) return error.UnsupportedRamSize;
        if (self.cpuid.len > max_cpuid_entries) return error.TooManyCpuidEntries;
        if (self.xcrs.len > max_xcrs) return error.TooManyXcrs;
        if (self.msrs.len > max_msrs) return error.TooManyMsrs;
        if (self.xsave.len < xsave_legacy_and_header_bytes) return error.XsaveTooSmall;
        if (self.xsave.len > max_xsave_bytes) return error.XsaveTooLarge;
        if (self.tsc_khz == 0) return error.InvalidTscFrequency;
        if (self.clock.flags & ~@as(u32, 0x0e) != 0) return error.InvalidClockFlags;
        try validateXstate(self.xstate_bv, self.xcomp_bv, self.xsave.len);

        for (self.cpuid, 0..) |entry, index| {
            if (index == 0) continue;
            const previous = self.cpuid[index - 1];
            if (entry.function < previous.function or
                (entry.function == previous.function and entry.index <= previous.index))
            {
                return error.DuplicateOrUnorderedCpuid;
            }
        }
        for (self.xcrs, 0..) |entry, index| {
            if (index > 0 and entry.index <= self.xcrs[index - 1].index) {
                return error.DuplicateOrUnorderedXcr;
            }
        }
        for (self.msrs, 0..) |entry, index| {
            if (index > 0 and entry.index <= self.msrs[index - 1].index) {
                return error.DuplicateOrUnorderedMsr;
            }
        }
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
    encoder.int(u32, @intCast(state.cpuid.len));
    encoder.int(u32, @intCast(state.xcrs.len));
    encoder.int(u32, @intCast(state.xsave.len));
    encoder.int(u32, @intCast(state.msrs.len));
    encoder.int(u64, state.xstate_bv);
    encoder.int(u64, state.xcomp_bv);
    encoder.int(u64, state.tsc_khz);
    encoder.int(u64, @bitCast(state.tsc_offset));
    encoder.int(u64, state.clock.clock);
    encoder.int(u32, state.clock.flags);
    encoder.int(u32, 0);
    encoder.int(u64, state.clock.realtime);
    encoder.int(u64, state.clock.host_tsc);
    encodeGprs(&encoder, state.gprs);
    encodeSregs(&encoder, state.sregs);
    for (state.cpuid) |entry| encodeCpuid(&encoder, entry);
    for (state.xcrs) |entry| {
        encoder.int(u32, entry.index);
        encoder.int(u64, entry.value);
    }
    encoder.bytesRaw(state.xsave);
    for (state.msrs) |entry| {
        encoder.int(u32, entry.index);
        encoder.int(u64, entry.value);
    }
    encoder.bytesRaw(&state.mailbox);
    encoder.bytesRaw(state.ram);
    std.debug.assert(encoder.offset == payload_len);
    Sha256.hash(bytes[0..payload_len], bytes[payload_len..][0..digest_len], .{});
    return bytes;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) (Error || std.mem.Allocator.Error)!State {
    if (bytes.len > max_encoded_bytes) return error.InputTooLarge;
    if (bytes.len < fixed_prefix_len + gpr_encoded_len + sregs_encoded_len + mailbox_size + digest_len) {
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
    const cpuid_count = decoder.int(u32) catch return error.Truncated;
    const xcr_count = decoder.int(u32) catch return error.Truncated;
    const xsave_len = decoder.int(u32) catch return error.Truncated;
    const msr_count = decoder.int(u32) catch return error.Truncated;
    const xstate_bv = decoder.int(u64) catch return error.Truncated;
    const xcomp_bv = decoder.int(u64) catch return error.Truncated;
    const tsc_khz = decoder.int(u64) catch return error.Truncated;
    const tsc_offset: i64 = @bitCast(decoder.int(u64) catch return error.Truncated);
    const clock_value = decoder.int(u64) catch return error.Truncated;
    const clock_flags = decoder.int(u32) catch return error.Truncated;
    if ((decoder.int(u32) catch return error.Truncated) != 0) return error.InvalidReservedField;
    const clock_realtime = decoder.int(u64) catch return error.Truncated;
    const clock_host_tsc = decoder.int(u64) catch return error.Truncated;

    if (ram_len == 0 or ram_len > max_ram_bytes) return error.UnsupportedRamSize;
    if (cpuid_count > max_cpuid_entries) return error.TooManyCpuidEntries;
    if (xcr_count > max_xcrs) return error.TooManyXcrs;
    if (xsave_len < xsave_legacy_and_header_bytes) return error.XsaveTooSmall;
    if (xsave_len > max_xsave_bytes) return error.XsaveTooLarge;
    if (msr_count > max_msrs) return error.TooManyMsrs;

    const expected_payload_len = encodedPayloadLenFromCounts(ram_len, cpuid_count, xcr_count, xsave_len, msr_count) catch return error.Overflow;
    if (expected_payload_len != payload_len) return error.NonCanonicalLength;

    const gprs = decodeGprs(&decoder) catch return error.Truncated;
    const sregs = decodeSregs(&decoder) catch return error.Truncated;
    const cpuid = try allocator.alloc(CpuidEntry, cpuid_count);
    errdefer allocator.free(cpuid);
    for (cpuid) |*entry| entry.* = decodeCpuid(&decoder) catch return error.Truncated;
    const xcrs = try allocator.alloc(Xcr, xcr_count);
    errdefer allocator.free(xcrs);
    for (xcrs) |*entry| entry.* = .{
        .index = decoder.int(u32) catch return error.Truncated,
        .value = decoder.int(u64) catch return error.Truncated,
    };
    const xsave = try allocator.alloc(u8, xsave_len);
    errdefer allocator.free(xsave);
    decoder.bytesRaw(xsave) catch return error.Truncated;
    const msrs = try allocator.alloc(Msr, msr_count);
    errdefer allocator.free(msrs);
    for (msrs) |*entry| entry.* = .{
        .index = decoder.int(u32) catch return error.Truncated,
        .value = decoder.int(u64) catch return error.Truncated,
    };
    var mailbox: [mailbox_size]u8 = undefined;
    decoder.bytesRaw(&mailbox) catch return error.Truncated;
    const ram = try allocator.alloc(u8, ram_len);
    errdefer allocator.free(ram);
    decoder.bytesRaw(ram) catch return error.Truncated;
    if (decoder.offset != decoder.bytes.len) return error.NonCanonicalLength;

    var state = State{
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
        .clock = .{ .clock = clock_value, .flags = clock_flags, .realtime = clock_realtime, .host_tsc = clock_host_tsc },
        .mailbox = mailbox,
        .ram = ram,
    };
    errdefer state.deinit(allocator);
    try state.validate();
    return state;
}

fn validateXstate(xstate_bv: u64, xcomp_bv: u64, xsave_len: usize) Error!void {
    if (xstate_bv & ~supported_xstate_mask != 0 or xcomp_bv != 0) return error.InvalidXstate;
    if (xstate_bv & 0b010 != 0 and xstate_bv & 0b001 == 0) return error.InvalidXstate;
    if (xstate_bv & 0b100 != 0) {
        if (xstate_bv & 0b011 != 0b011 or xsave_len < xsave_avx_end) return error.InvalidXstate;
    }
}

fn encodedPayloadLen(state: *const State) Error!usize {
    return encodedPayloadLenFromCounts(state.ram.len, state.cpuid.len, state.xcrs.len, state.xsave.len, state.msrs.len);
}

fn encodedPayloadLenFromCounts(ram_len: anytype, cpuid_count: anytype, xcr_count: anytype, xsave_len: anytype, msr_count: anytype) Error!usize {
    var total: usize = fixed_prefix_len + gpr_encoded_len + sregs_encoded_len + mailbox_size;
    total = checkedAddMul(total, @intCast(cpuid_count), cpuid_encoded_len) catch return error.Overflow;
    total = checkedAddMul(total, @intCast(xcr_count), xcr_encoded_len) catch return error.Overflow;
    total = std.math.add(usize, total, @intCast(xsave_len)) catch return error.Overflow;
    total = checkedAddMul(total, @intCast(msr_count), msr_encoded_len) catch return error.Overflow;
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

fn encodeGprs(encoder: *Encoder, value: Gprs) void {
    inline for (std.meta.fields(Gprs)) |field| encoder.int(u64, @field(value, field.name));
}

fn decodeGprs(decoder: *Decoder) error{Truncated}!Gprs {
    var value = Gprs{};
    inline for (std.meta.fields(Gprs)) |field| @field(value, field.name) = try decoder.int(u64);
    return value;
}

fn encodeSegment(encoder: *Encoder, value: Segment) void {
    encoder.int(u64, value.base);
    encoder.int(u32, value.limit);
    encoder.int(u16, value.selector);
    inline for (.{ "type", "present", "dpl", "db", "s", "l", "g", "avl", "unusable" }) |name| {
        encoder.int(u8, @field(value, name));
    }
}

fn decodeSegment(decoder: *Decoder) error{Truncated}!Segment {
    var value = Segment{
        .base = try decoder.int(u64),
        .limit = try decoder.int(u32),
        .selector = try decoder.int(u16),
    };
    inline for (.{ "type", "present", "dpl", "db", "s", "l", "g", "avl", "unusable" }) |name| {
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
    inline for (.{ "cs", "ds", "es", "fs", "gs", "ss", "tr", "ldt" }) |name| encodeSegment(encoder, @field(value, name));
    encodeDtable(encoder, value.gdt);
    encodeDtable(encoder, value.idt);
    inline for (.{ "cr0", "cr2", "cr3", "cr4", "cr8", "efer", "apic_base" }) |name| encoder.int(u64, @field(value, name));
    for (value.interrupt_bitmap) |word| encoder.int(u64, word);
}

fn decodeSregs(decoder: *Decoder) error{Truncated}!Sregs {
    var value = Sregs{};
    inline for (.{ "cs", "ds", "es", "fs", "gs", "ss", "tr", "ldt" }) |name| @field(value, name) = try decodeSegment(decoder);
    value.gdt = try decodeDtable(decoder);
    value.idt = try decodeDtable(decoder);
    inline for (.{ "cr0", "cr2", "cr3", "cr4", "cr8", "efer", "apic_base" }) |name| @field(value, name) = try decoder.int(u64);
    for (&value.interrupt_bitmap) |*word| word.* = try decoder.int(u64);
    return value;
}

fn encodeCpuid(encoder: *Encoder, value: CpuidEntry) void {
    inline for (std.meta.fields(CpuidEntry)) |field| encoder.int(u32, @field(value, field.name));
}

fn decodeCpuid(decoder: *Decoder) error{Truncated}!CpuidEntry {
    var value: CpuidEntry = undefined;
    inline for (std.meta.fields(CpuidEntry)) |field| @field(value, field.name) = try decoder.int(u32);
    return value;
}

fn testState(allocator: std.mem.Allocator) !State {
    const cpuid = try allocator.dupe(CpuidEntry, &.{
        .{ .function = 0, .index = 0, .flags = 0, .eax = 0xd, .ebx = 1, .ecx = 2, .edx = 3 },
        .{ .function = 0xd, .index = 0, .flags = 1, .eax = 7, .ebx = 832, .ecx = 832, .edx = 0 },
    });
    errdefer allocator.free(cpuid);
    const xcrs = try allocator.dupe(Xcr, &.{.{ .index = 0, .value = 7 }});
    errdefer allocator.free(xcrs);
    const xsave = try allocator.alloc(u8, xsave_avx_end);
    errdefer allocator.free(xsave);
    for (xsave, 0..) |*byte, index| byte.* = @truncate(index);
    const msrs = try allocator.dupe(Msr, &.{
        .{ .index = 0x10, .value = 100 },
        .{ .index = 0x3b, .value = 2 },
    });
    errdefer allocator.free(msrs);
    const ram = try allocator.alloc(u8, 8192);
    errdefer allocator.free(ram);
    @memset(ram, 0xa5);
    var mailbox: [mailbox_size]u8 = @splat(0);
    @memcpy(mailbox[0..8], "mailbox!");
    return .{
        .cpuid = cpuid,
        .gprs = .{ .rax = 1, .rip = 0x1234, .rflags = 2 },
        .sregs = .{ .cs = .{ .base = 3, .limit = 0xffff, .selector = 8, .type = 11, .present = 1 }, .cr0 = 1, .efer = 0x500 },
        .xcrs = xcrs,
        .xsave = xsave,
        .xstate_bv = 7,
        .xcomp_bv = 0,
        .msrs = msrs,
        .tsc_khz = 3_000_000,
        .tsc_offset = -123,
        .clock = .{ .clock = 44, .flags = 0x0e, .realtime = 55, .host_tsc = 66 },
        .mailbox = mailbox,
        .ram = ram,
    };
}

test "normalized profile state has a stable little-endian round trip" {
    const allocator = std.testing.allocator;
    var original = try testState(allocator);
    defer original.deinit(allocator);
    const encoded = try encode(allocator, &original);
    defer allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &magic, encoded[0..magic.len]);
    try std.testing.expectEqual(format_version, std.mem.readInt(u32, encoded[magic.len..][0..4], .little));
    var decoded = try decode(allocator, encoded);
    defer decoded.deinit(allocator);
    try std.testing.expectEqualDeep(original.gprs, decoded.gprs);
    try std.testing.expectEqualDeep(original.sregs, decoded.sregs);
    try std.testing.expectEqualSlices(CpuidEntry, original.cpuid, decoded.cpuid);
    try std.testing.expectEqualSlices(Xcr, original.xcrs, decoded.xcrs);
    try std.testing.expectEqualSlices(u8, original.xsave, decoded.xsave);
    try std.testing.expectEqualSlices(Msr, original.msrs, decoded.msrs);
    try std.testing.expectEqual(original.tsc_offset, decoded.tsc_offset);
    try std.testing.expectEqualDeep(original.clock, decoded.clock);
    try std.testing.expectEqualSlices(u8, &original.mailbox, &decoded.mailbox);
    try std.testing.expectEqualSlices(u8, original.ram, decoded.ram);
}

test "state validation rejects noncanonical inventories and xstate" {
    const allocator = std.testing.allocator;
    var state = try testState(allocator);
    defer state.deinit(allocator);
    state.cpuid[1] = state.cpuid[0];
    try std.testing.expectError(error.DuplicateOrUnorderedCpuid, state.validate());
    state.cpuid[1].function = 0xd;
    state.xcrs[0].index = 0;
    state.xstate_bv = 1 << 9;
    try std.testing.expectError(error.InvalidXstate, state.validate());
    state.xstate_bv = 7;
    state.xcomp_bv = 1 << 63;
    try std.testing.expectError(error.InvalidXstate, state.validate());
}

test "decoder rejects corruption truncation trailing bytes and declared length mismatch" {
    const allocator = std.testing.allocator;
    var state = try testState(allocator);
    defer state.deinit(allocator);
    const good = try encode(allocator, &state);
    defer allocator.free(good);

    var corrupt = try allocator.dupe(u8, good);
    defer allocator.free(corrupt);
    corrupt[fixed_prefix_len] ^= 1;
    try std.testing.expectError(error.BadChecksum, decode(allocator, corrupt));
    try std.testing.expectError(error.Truncated, decode(allocator, good[0 .. digest_len - 1]));

    const trailing = try allocator.alloc(u8, good.len + 1);
    defer allocator.free(trailing);
    @memcpy(trailing[0..good.len], good);
    trailing[good.len] = 0;
    try std.testing.expectError(error.BadChecksum, decode(allocator, trailing));

    var wrong_length = try allocator.dupe(u8, good);
    defer allocator.free(wrong_length);
    std.mem.writeInt(u64, wrong_length[magic.len + 8 ..][0..8], wrong_length.len + 1, .little);
    Sha256.hash(wrong_length[0 .. wrong_length.len - digest_len], wrong_length[wrong_length.len - digest_len ..][0..digest_len], .{});
    try std.testing.expectError(error.NonCanonicalLength, decode(allocator, wrong_length));
}

fn fuzzStateDecoder(_: void, smith: *std.testing.Smith) !void {
    var arbitrary: [16 * 1024]u8 = undefined;
    const arbitrary_len = smith.slice(&arbitrary);
    consumeFuzzState(arbitrary[0..arbitrary_len]);

    var seed = try testState(std.testing.allocator);
    defer seed.deinit(std.testing.allocator);
    const encoded = try encode(std.testing.allocator, &seed);
    defer std.testing.allocator.free(encoded);
    var mutations: [64]u8 = undefined;
    const mutation_count = smith.slice(&mutations);
    const payload_len = encoded.len - digest_len;
    for (mutations[0..mutation_count]) |byte| {
        const offset = @as(usize, smith.value(u16)) % payload_len;
        encoded[offset] ^= byte;
    }
    Sha256.hash(encoded[0..payload_len], encoded[payload_len..][0..digest_len], .{});
    consumeFuzzState(encoded);
}

fn consumeFuzzState(bytes: []const u8) void {
    if (decode(std.testing.allocator, bytes)) |decoded_value| {
        var decoded = decoded_value;
        decoded.deinit(std.testing.allocator);
    } else |_| {}
}

test "fuzz normalized profile state decoder" {
    try std.testing.fuzz({}, fuzzStateDecoder, .{});
}
