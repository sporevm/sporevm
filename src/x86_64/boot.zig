//! Linux x86-64 bzImage direct-boot planner.
//!
//! The planner implements the Linux 32-bit boot protocol: the protected-mode
//! payload starts at 1MiB, RSI points at a clean zero page, and the vCPU enters
//! with flat BOOT_CS/BOOT_DS segments. Kernel and initrd bytes are host-selected,
//! but all header-derived offsets and lengths remain bounded before RAM writes.

const std = @import("std");
const board = @import("board.zig");
const mp = @import("mp.zig");

const boot_params_size: usize = 4096;
const setup_header_start: usize = 0x1f1;
const setup_sects_offset: usize = 0x1f1;
const boot_flag_offset: usize = 0x1fe;
const header_length_offset: usize = 0x201;
const header_magic_offset: usize = 0x202;
const protocol_version_offset: usize = 0x206;
const type_of_loader_offset: usize = 0x210;
const loadflags_offset: usize = 0x211;
const code32_start_offset: usize = 0x214;
const ramdisk_image_offset: usize = 0x218;
const ramdisk_size_offset: usize = 0x21c;
const heap_end_ptr_offset: usize = 0x224;
const cmdline_ptr_offset: usize = 0x228;
const initrd_addr_max_offset: usize = 0x22c;
const kernel_alignment_offset: usize = 0x230;
const relocatable_kernel_offset: usize = 0x234;
const cmdline_size_offset: usize = 0x238;
const pref_address_offset: usize = 0x258;
const init_size_offset: usize = 0x260;
const required_header_end: usize = init_size_offset + @sizeOf(u32);
const e820_count_offset: usize = 0x1e8;
const e820_table_offset: usize = 0x2d0;
const e820_entry_size: usize = 20;

const boot_flag: u16 = 0xaa55;
const header_magic: u32 = 0x5372_6448; // "HdrS"
// init_size first became part of the boot header in protocol 2.10. Requiring it
// avoids interpreting payload bytes as newer header fields.
const minimum_protocol: u16 = 0x020a;
const load_high: u8 = 1 << 0;
const can_use_heap: u8 = 1 << 7;
const e820_ram: u32 = 1;
const e820_reserved: u32 = 2;
const max_command_line: usize = 4096;

pub const boot_code_selector: u16 = 0x10;
pub const boot_data_selector: u16 = 0x18;

pub const gdt = blk: {
    var bytes: [32]u8 = @splat(0);
    std.mem.writeInt(u64, bytes[16..24], 0x00cf_9b00_0000_ffff, .little);
    std.mem.writeInt(u64, bytes[24..32], 0x00cf_9300_0000_ffff, .little);
    break :blk bytes;
};

pub const Error = board.Error || mp.Error || error{
    BadBootFlag,
    BadHeaderMagic,
    UnsupportedBootProtocol,
    NotBzImage,
    TruncatedKernel,
    KernelTooLarge,
    InvalidInitSize,
    InvalidKernelAlignment,
    InvalidRuntimeAddress,
    CommandLineTooLarge,
    CommandLineContainsNul,
    InitrdTooLarge,
    RamTooSmall,
    AddressOverflow,
};

pub const ImageInfo = struct {
    setup_bytes: usize,
    header_end: usize,
    payload_len: usize,
    kernel_alignment: u64,
    relocatable_kernel: bool,
    pref_address: u64,
    init_size: u64,
    initrd_addr_max: u64,
    cmdline_size: usize,
};

pub const E820Entry = struct {
    addr: u64,
    size: u64,
    kind: u32,
};

pub const Range = struct {
    start: u64,
    end: u64,
};

pub const Plan = struct {
    image: ImageInfo,
    ram_size: u64,
    cpu_count: u8,
    mp_table: Range,
    kernel_load: Range,
    kernel_runtime: Range,
    zero_page: Range,
    command_line: Range,
    gdt: Range,
    initrd: ?Range,
    e820: [4]E820Entry,
};

pub fn parseBzImage(kernel: []const u8) Error!ImageInfo {
    if (kernel.len < required_header_end) return error.TruncatedKernel;
    if (readInt(u16, kernel, boot_flag_offset) != boot_flag) return error.BadBootFlag;
    if (readInt(u32, kernel, header_magic_offset) != header_magic) return error.BadHeaderMagic;

    const protocol = readInt(u16, kernel, protocol_version_offset);
    if (protocol < minimum_protocol) return error.UnsupportedBootProtocol;
    if (kernel[loadflags_offset] & load_high == 0) return error.NotBzImage;

    const setup_sects: usize = if (kernel[setup_sects_offset] == 0) 4 else kernel[setup_sects_offset];
    const setup_bytes = std.math.mul(usize, setup_sects + 1, 512) catch return error.AddressOverflow;
    if (setup_bytes >= kernel.len) return error.TruncatedKernel;

    const header_end = std.math.add(usize, 0x202, kernel[header_length_offset]) catch return error.AddressOverflow;
    if (header_end < required_header_end or header_end > kernel.len or header_end > boot_params_size) {
        return error.TruncatedKernel;
    }

    const payload_len = kernel.len - setup_bytes;
    const init_size: u64 = readInt(u32, kernel, init_size_offset);
    if (init_size == 0 or init_size < @as(u64, @intCast(payload_len))) return error.InvalidInitSize;
    const relocatable_kernel = kernel[relocatable_kernel_offset] != 0;
    const kernel_alignment: u64 = readInt(u32, kernel, kernel_alignment_offset);
    if (relocatable_kernel and
        (kernel_alignment == 0 or !std.math.isPowerOfTwo(kernel_alignment) or kernel_alignment > board.max_ram_size))
    {
        return error.InvalidKernelAlignment;
    }
    const declared_cmdline_size = readInt(u32, kernel, cmdline_size_offset);

    return .{
        .setup_bytes = setup_bytes,
        .header_end = header_end,
        .payload_len = payload_len,
        .kernel_alignment = kernel_alignment,
        .relocatable_kernel = relocatable_kernel,
        .pref_address = readInt(u64, kernel, pref_address_offset),
        .init_size = init_size,
        .initrd_addr_max = readInt(u32, kernel, initrd_addr_max_offset),
        .cmdline_size = if (declared_cmdline_size == 0) 255 else @min(declared_cmdline_size, max_command_line),
    };
}

pub fn plan(kernel: []const u8, initrd_len: usize, command_line: []const u8, ram_size: u64, cpu_count: u8) Error!Plan {
    try board.validateLayout(ram_size);
    const mp_table_end = try mp.tableEnd(cpu_count);
    const image = try parseBzImage(kernel);
    if (std.mem.indexOfScalar(u8, command_line, 0) != null) return error.CommandLineContainsNul;
    if (command_line.len > image.cmdline_size or command_line.len > max_command_line) {
        return error.CommandLineTooLarge;
    }
    const command_line_storage_len = std.math.add(usize, command_line.len, 1) catch return error.AddressOverflow;

    const kernel_load_end = add(board.kernel_addr, image.payload_len) catch return error.AddressOverflow;
    if (kernel_load_end > ram_size) return error.KernelTooLarge;
    const kernel_load = Range{ .start = board.kernel_addr, .end = kernel_load_end };

    const runtime_start = try kernelRuntimeStart(image, board.kernel_addr);
    const runtime_end = add(runtime_start, image.init_size) catch return error.AddressOverflow;
    if (runtime_start >= runtime_end or runtime_end > ram_size) return error.KernelTooLarge;
    const kernel_runtime = Range{ .start = runtime_start, .end = runtime_end };

    const initrd = if (initrd_len == 0) null else blk: {
        if (initrd_len > std.math.maxInt(u32)) return error.InitrdTooLarge;
        const protocol_ceiling = image.initrd_addr_max + 1;
        const ceiling = @min(ram_size, protocol_ceiling);
        if (initrd_len > ceiling) return error.InitrdTooLarge;
        break :blk try placeInitrd(initrd_len, ceiling, .{ kernel_load, kernel_runtime });
    };

    const e820 = [_]E820Entry{
        .{ .addr = 0, .size = board.mp_scan_window_size, .kind = e820_reserved },
        .{ .addr = board.mp_scan_window_size, .size = board.legacy_hole_start - board.mp_scan_window_size, .kind = e820_ram },
        .{ .addr = board.legacy_hole_start, .size = board.legacy_hole_end - board.legacy_hole_start, .kind = e820_reserved },
        .{ .addr = board.legacy_hole_end, .size = ram_size - board.legacy_hole_end, .kind = e820_ram },
    };

    const result = Plan{
        .image = image,
        .ram_size = ram_size,
        .cpu_count = cpu_count,
        .mp_table = .{
            .start = board.mp_floating_pointer_addr,
            .end = @intCast(mp_table_end),
        },
        .kernel_load = kernel_load,
        .kernel_runtime = kernel_runtime,
        .zero_page = .{ .start = board.zero_page_addr, .end = board.zero_page_addr + boot_params_size },
        .command_line = .{
            .start = board.cmdline_addr,
            .end = add(board.cmdline_addr, command_line_storage_len) catch return error.AddressOverflow,
        },
        .gdt = .{
            .start = board.gdt_addr,
            .end = add(board.gdt_addr, gdt.len) catch return error.AddressOverflow,
        },
        .initrd = initrd,
        .e820 = e820,
    };
    try validatePopulatedRanges(result);
    return result;
}

pub fn load(ram: []u8, kernel: []const u8, initrd: ?[]const u8, command_line: []const u8, cpu_count: u8) Error!Plan {
    const normalized_initrd = if (initrd) |bytes| if (bytes.len == 0) null else bytes else null;
    const layout = try plan(kernel, if (normalized_initrd) |bytes| bytes.len else 0, command_line, ram.len, cpu_count);
    @memset(ram, 0);

    const mp_table_end = try mp.write(ram, cpu_count);
    if (mp_table_end != layout.mp_table.end) return error.InvalidConfigurationTable;
    const payload = kernel[layout.image.setup_bytes..];
    @memcpy(ramSlice(ram, board.kernel_addr, payload.len), payload);
    @memcpy(ramSlice(ram, board.gdt_addr, gdt.len), &gdt);
    @memcpy(ramSlice(ram, board.cmdline_addr, command_line.len), command_line);
    ram[@intCast(board.cmdline_addr + command_line.len)] = 0;

    const zero_page = ramSlice(ram, board.zero_page_addr, boot_params_size);
    @memcpy(zero_page[setup_header_start..layout.image.header_end], kernel[setup_header_start..layout.image.header_end]);
    zero_page[type_of_loader_offset] = 0xff;
    zero_page[loadflags_offset] |= can_use_heap;
    writeInt(u32, zero_page, code32_start_offset, @intCast(board.kernel_addr));
    writeInt(u16, zero_page, heap_end_ptr_offset, 0xfe00);
    writeInt(u32, zero_page, cmdline_ptr_offset, @intCast(board.cmdline_addr));
    writeInt(u32, zero_page, ramdisk_image_offset, 0);
    writeInt(u32, zero_page, ramdisk_size_offset, 0);

    if (normalized_initrd) |bytes| {
        const range = layout.initrd.?;
        @memcpy(ramSlice(ram, range.start, bytes.len), bytes);
        writeInt(u32, zero_page, ramdisk_image_offset, @intCast(range.start));
        writeInt(u32, zero_page, ramdisk_size_offset, @intCast(bytes.len));
    }

    zero_page[e820_count_offset] = layout.e820.len;
    for (layout.e820, 0..) |entry, index| {
        const offset = e820_table_offset + index * e820_entry_size;
        writeInt(u64, zero_page, offset, entry.addr);
        writeInt(u64, zero_page, offset + 8, entry.size);
        writeInt(u32, zero_page, offset + 16, entry.kind);
    }
    return layout;
}

fn add(a: u64, b: anytype) !u64 {
    return std.math.add(u64, a, @intCast(b));
}

fn kernelRuntimeStart(image: ImageInfo, load_address: u64) Error!u64 {
    if (!image.relocatable_kernel) {
        if (image.pref_address == 0) return error.InvalidRuntimeAddress;
        return image.pref_address;
    }

    const start = @max(load_address, image.pref_address);
    const alignment_mask = image.kernel_alignment - 1;
    const rounded = add(start, alignment_mask) catch return error.AddressOverflow;
    return rounded & ~alignment_mask;
}

fn placeInitrd(initrd_len: usize, initial_ceiling: u64, blockers: [2]Range) Error!Range {
    var ceiling = initial_ceiling;
    var attempt: usize = 0;
    while (attempt < blockers.len + 1) : (attempt += 1) {
        if (initrd_len > ceiling) return error.RamTooSmall;
        const start = std.mem.alignBackward(u64, ceiling - initrd_len, board.page_size);
        const candidate = Range{
            .start = start,
            .end = add(start, initrd_len) catch return error.AddressOverflow,
        };

        var next_ceiling: ?u64 = null;
        for (blockers) |blocker| {
            if (overlaps(candidate, blocker)) {
                next_ceiling = @min(next_ceiling orelse blocker.start, blocker.start);
            }
        }
        ceiling = next_ceiling orelse return candidate;
    }
    return error.RamTooSmall;
}

fn overlaps(a: Range, b: Range) bool {
    return a.start < b.end and b.start < a.end;
}

fn validatePopulatedRanges(layout: Plan) Error!void {
    var ranges: [6]Range = undefined;
    ranges[0] = layout.mp_table;
    ranges[1] = layout.gdt;
    ranges[2] = layout.zero_page;
    ranges[3] = layout.command_line;
    ranges[4] = layout.kernel_load;
    var count: usize = 5;
    if (layout.initrd) |initrd| {
        ranges[count] = initrd;
        count += 1;
    }

    for (ranges[0..count], 0..) |range, index| {
        if (range.start >= range.end or range.end > layout.ram_size) return error.RamTooSmall;
        for (ranges[index + 1 .. count]) |other| {
            if (overlaps(range, other)) return error.RamTooSmall;
        }
    }

    if (layout.kernel_runtime.start >= layout.kernel_runtime.end or layout.kernel_runtime.end > layout.ram_size) {
        return error.RamTooSmall;
    }
    for (ranges[0..4]) |range| {
        if (overlaps(range, layout.kernel_runtime)) return error.RamTooSmall;
    }
    if (layout.initrd) |initrd| {
        if (overlaps(initrd, layout.kernel_runtime)) return error.RamTooSmall;
    }
}

fn ramSlice(ram: []u8, address: u64, len: usize) []u8 {
    const start: usize = @intCast(address);
    return ram[start..][0..len];
}

fn readInt(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

fn writeInt(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

fn makeTestImage(buffer: []u8, setup_sects: u8) []u8 {
    @memset(buffer, 0xa5);
    buffer[setup_sects_offset] = setup_sects;
    writeInt(u16, buffer, boot_flag_offset, boot_flag);
    buffer[0x200] = 0xeb;
    buffer[header_length_offset] = 0x66;
    writeInt(u32, buffer, header_magic_offset, header_magic);
    writeInt(u16, buffer, protocol_version_offset, 0x020f);
    buffer[loadflags_offset] = load_high;
    writeInt(u32, buffer, initrd_addr_max_offset, 0x7fff_ffff);
    writeInt(u32, buffer, kernel_alignment_offset, 2 * 1024 * 1024);
    buffer[relocatable_kernel_offset] = 1;
    writeInt(u32, buffer, cmdline_size_offset, max_command_line);
    writeInt(u64, buffer, pref_address_offset, 16 * 1024 * 1024);
    writeInt(u32, buffer, init_size_offset, 8 * 1024 * 1024);
    return buffer;
}

test "bzImage planner builds a bounded low-memory boot layout" {
    var image_buf: [8192]u8 = undefined;
    const image = makeTestImage(&image_buf, 4);
    const layout = try plan(image, 1024, "console=hvc0", 64 * 1024 * 1024, 2);
    try std.testing.expectEqual(@as(usize, 5 * 512), layout.image.setup_bytes);
    try std.testing.expectEqual(@as(u8, 2), layout.cpu_count);
    try std.testing.expectEqual(board.mp_floating_pointer_addr, layout.mp_table.start);
    try std.testing.expectEqual(@as(u64, @intCast(try mp.tableEnd(2))), layout.mp_table.end);
    try std.testing.expectEqual(board.kernel_addr, layout.kernel_load.start);
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024), layout.kernel_runtime.start);
    try std.testing.expect(!overlaps(layout.initrd.?, layout.kernel_load));
    try std.testing.expect(!overlaps(layout.initrd.?, layout.kernel_runtime));
    try std.testing.expectEqual(@as(u32, e820_reserved), layout.e820[0].kind);
    try std.testing.expectEqual(@as(u64, board.mp_scan_window_size), layout.e820[0].size);
    try std.testing.expectEqual(@as(u32, e820_reserved), layout.e820[2].kind);

    const populated = [_]Range{ layout.mp_table, layout.gdt, layout.zero_page, layout.command_line, layout.kernel_load, layout.initrd.? };
    for (populated, 0..) |range, index| {
        try std.testing.expect(range.start < range.end);
        try std.testing.expect(range.end <= layout.ram_size);
        for (populated[index + 1 ..]) |other| {
            try std.testing.expect(!overlaps(range, other));
        }
    }
    for (populated[0..4]) |range| try std.testing.expect(!overlaps(range, layout.kernel_runtime));

    const maximum = try plan(image, 0, "console=hvc0", 64 * 1024 * 1024, mp.max_cpu_count);
    try std.testing.expectEqual(@as(u64, @intCast(try mp.tableEnd(mp.max_cpu_count))), maximum.mp_table.end);
    try std.testing.expect(maximum.mp_table.end <= maximum.gdt.start);
}

test "bzImage planner reserves the official runtime window and moves initrd around it" {
    var image_buf: [8192]u8 = undefined;
    var image = makeTestImage(&image_buf, 4);
    writeInt(u64, image, pref_address_offset, 0x0300_0001);

    const layout = try plan(image, 12 * 1024 * 1024, "console=hvc0", board.min_ram_size, 2);
    try std.testing.expectEqual(@as(u64, 0x0320_0000), layout.kernel_runtime.start);
    try std.testing.expectEqual(layout.kernel_runtime.start, layout.initrd.?.end);
    try std.testing.expect(!overlaps(layout.initrd.?, layout.kernel_load));
    try std.testing.expect(!overlaps(layout.initrd.?, layout.kernel_runtime));

    image[relocatable_kernel_offset] = 0;
    writeInt(u64, image, pref_address_offset, 0x0140_0000);
    const fixed = try plan(image, 0, "console=hvc0", board.min_ram_size, 2);
    try std.testing.expectEqual(@as(u64, 0x0140_0000), fixed.kernel_runtime.start);

    image = makeTestImage(&image_buf, 4);
    writeInt(u32, image, kernel_alignment_offset, board.page_size);
    writeInt(u64, image, pref_address_offset, 0);
    const overlapping = try plan(image, 1024, "console=hvc0", board.min_ram_size, 2);
    try std.testing.expect(overlaps(overlapping.kernel_load, overlapping.kernel_runtime));
    try std.testing.expect(!overlaps(overlapping.initrd.?, overlapping.kernel_load));
    try std.testing.expect(!overlaps(overlapping.initrd.?, overlapping.kernel_runtime));
}

test "load writes the zero page, payload, command line, initrd, GDT, and E820" {
    const allocator = std.testing.allocator;
    var image_buf: [8192]u8 = undefined;
    const image = makeTestImage(&image_buf, 4);
    const ram = try allocator.alloc(u8, 64 * 1024 * 1024);
    defer allocator.free(ram);
    const layout = try load(ram, image, "initrd", "console=hvc0", 2);
    const zero_page = ram[@intCast(board.zero_page_addr)..][0..boot_params_size];

    try std.testing.expectEqualSlices(u8, image[layout.image.setup_bytes..], ram[@intCast(board.kernel_addr)..][0..layout.image.payload_len]);
    try std.testing.expectEqualStrings("console=hvc0", ram[@intCast(board.cmdline_addr)..][0.."console=hvc0".len]);
    try std.testing.expectEqual(@as(u32, board.kernel_addr), readInt(u32, zero_page, code32_start_offset));
    try std.testing.expectEqual(@as(u8, 4), zero_page[e820_count_offset]);
    try std.testing.expectEqualSlices(u8, &gdt, ram[@intCast(board.gdt_addr)..][0..gdt.len]);
    try std.testing.expectEqualStrings("initrd", ram[@intCast(layout.initrd.?.start)..][0.."initrd".len]);
    try mp.validate(ram, 2);

    writeInt(u32, image, ramdisk_image_offset, 0xdead_beef);
    writeInt(u32, image, ramdisk_size_offset, 0xfeed_face);
    const empty_layout = try load(ram, image, "", "console=hvc0", 2);
    try std.testing.expectEqual(@as(?Range, null), empty_layout.initrd);
    try std.testing.expectEqual(@as(u32, 0), readInt(u32, zero_page, ramdisk_image_offset));
    try std.testing.expectEqual(@as(u32, 0), readInt(u32, zero_page, ramdisk_size_offset));
}

test "bzImage parser and planner fail closed on malformed fields" {
    var image_buf: [8192]u8 = undefined;
    var image = makeTestImage(&image_buf, 4);
    image[header_magic_offset] = 0;
    try std.testing.expectError(error.BadHeaderMagic, parseBzImage(image));

    image = makeTestImage(&image_buf, 4);
    image[loadflags_offset] = 0;
    try std.testing.expectError(error.NotBzImage, parseBzImage(image));

    image = makeTestImage(&image_buf, 4);
    image[header_length_offset] = 0x61;
    try std.testing.expectError(error.TruncatedKernel, parseBzImage(image));

    image = makeTestImage(&image_buf, 4);
    writeInt(u32, image, kernel_alignment_offset, 3);
    try std.testing.expectError(error.InvalidKernelAlignment, parseBzImage(image));

    image = makeTestImage(&image_buf, 4);
    writeInt(u32, image, init_size_offset, 1);
    try std.testing.expectError(error.InvalidInitSize, parseBzImage(image));

    image = makeTestImage(&image_buf, 4);
    writeInt(u64, image, pref_address_offset, std.math.maxInt(u64));
    try std.testing.expectError(error.AddressOverflow, plan(image, 0, "ok", board.min_ram_size, 2));

    image = makeTestImage(&image_buf, 4);
    image[relocatable_kernel_offset] = 0;
    writeInt(u64, image, pref_address_offset, 0);
    try std.testing.expectError(error.InvalidRuntimeAddress, plan(image, 0, "ok", board.min_ram_size, 2));

    image = makeTestImage(&image_buf, 4);
    writeInt(u32, image, cmdline_size_offset, 4);
    _ = try plan(image, 0, "four", board.min_ram_size, 2);
    try std.testing.expectError(error.CommandLineTooLarge, plan(image, 0, "fives", board.min_ram_size, 2));

    image = makeTestImage(&image_buf, 4);
    try std.testing.expectError(error.CommandLineContainsNul, plan(image, 0, "bad\x00line", board.min_ram_size, 2));
    try std.testing.expectError(error.InvalidRamSize, plan(image, 0, "ok", board.max_ram_size + board.page_size, 2));
    _ = try plan(image, 0, "ok", board.min_ram_size, 1);
    try std.testing.expectError(error.InvalidCpuCount, plan(image, 0, "ok", board.min_ram_size, 0));
    try std.testing.expectError(error.InvalidCpuCount, plan(image, 0, "ok", board.min_ram_size, mp.max_cpu_count + 1));
}

fn fuzzBzImagePlanner(_: void, smith: *std.testing.Smith) !void {
    var raw_kernel: [8192]u8 = undefined;
    const raw_kernel_len = smith.slice(&raw_kernel);
    var command_line: [max_command_line + 1]u8 = undefined;
    const command_line_len = smith.slice(&command_line);
    const ram_mib = 64 + @as(u64, smith.value(u16)) % (2048 - 64 + 1);
    const ram_size = ram_mib * 1024 * 1024;
    const initrd_len: usize = smith.value(u32);
    const cpu_count = 1 + smith.value(u8) % (mp.max_cpu_count + 1);

    _ = parseBzImage(raw_kernel[0..raw_kernel_len]) catch {};
    _ = plan(raw_kernel[0..raw_kernel_len], initrd_len, command_line[0..command_line_len], ram_size, cpu_count) catch {};

    var structured_buf: [8192]u8 = undefined;
    const structured = makeTestImage(&structured_buf, smith.value(u8));
    writeInt(u32, structured, kernel_alignment_offset, smith.value(u32));
    structured[relocatable_kernel_offset] = smith.value(u8);
    writeInt(u64, structured, pref_address_offset, smith.value(u64));
    writeInt(u32, structured, init_size_offset, smith.value(u32));
    writeInt(u32, structured, initrd_addr_max_offset, smith.value(u32));
    writeInt(u32, structured, cmdline_size_offset, smith.value(u32));
    _ = plan(structured, initrd_len, command_line[0..command_line_len], ram_size, cpu_count) catch {};
}

test "fuzz x86 bzImage parser and placement planner" {
    try std.testing.fuzz({}, fuzzBzImagePlanner, .{});
}
