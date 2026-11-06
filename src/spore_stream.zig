//! Small binary session frame envelope for interactive guest streams.
//!
//! This module owns only the fixed wire header. Session policy such as allowed
//! stream/type combinations and monotonic offsets lives with the caller.

const std = @import("std");

pub const magic = "SPIO";
pub const version: u8 = 1;
pub const header_len: usize = 24;
pub const max_payload_len: usize = 4096;
pub const max_frame_len: usize = header_len + max_payload_len;

pub const FrameType = enum(u8) {
    data = 1,
    close = 2,
    exit = 3,
    resize = 4,
    signal = 5,
    err = 6,
    event = 7,

    pub fn parse(raw: u8) ?FrameType {
        return std.enums.fromInt(FrameType, raw);
    }
};

pub const StreamId = enum(u32) {
    control = 0,
    stdin = 1,
    stdout = 2,
    stderr = 3,
    terminal = 4,

    pub fn parse(raw: u32) ?StreamId {
        return std.enums.fromInt(StreamId, raw);
    }
};

pub const Header = struct {
    frame_type: FrameType,
    flags: u16 = 0,
    stream_id: StreamId,
    offset: u64 = 0,
    payload_len: u32 = 0,
};

pub const FrameError = error{
    BadMagic,
    UnsupportedVersion,
    UnknownFrameType,
    UnknownStreamId,
    PayloadTooLarge,
};

pub fn writeHeader(buf: *[header_len]u8, header: Header) void {
    @memcpy(buf[0..4], magic);
    buf[4] = version;
    buf[5] = @backingInt(header.frame_type);
    std.mem.writeInt(u16, buf[6..8], header.flags, .little);
    std.mem.writeInt(u32, buf[8..12], @backingInt(header.stream_id), .little);
    std.mem.writeInt(u64, buf[12..20], header.offset, .little);
    std.mem.writeInt(u32, buf[20..24], header.payload_len, .little);
}

pub fn readHeader(buf: *const [header_len]u8) FrameError!Header {
    if (!std.mem.eql(u8, buf[0..4], magic)) return error.BadMagic;
    if (buf[4] != version) return error.UnsupportedVersion;
    const frame_type = FrameType.parse(buf[5]) orelse return error.UnknownFrameType;
    const stream_id_raw = std.mem.readInt(u32, buf[8..12], .little);
    const stream_id = StreamId.parse(stream_id_raw) orelse return error.UnknownStreamId;
    const payload_len = std.mem.readInt(u32, buf[20..24], .little);
    if (payload_len > max_payload_len) return error.PayloadTooLarge;
    return .{
        .frame_type = frame_type,
        .flags = std.mem.readInt(u16, buf[6..8], .little),
        .stream_id = stream_id,
        .offset = std.mem.readInt(u64, buf[12..20], .little),
        .payload_len = payload_len,
    };
}

pub fn writeFrame(buf: []u8, header: Header, payload: []const u8) ![]const u8 {
    if (payload.len > max_payload_len) return error.PayloadTooLarge;
    if (buf.len < header_len + payload.len) return error.NoSpaceLeft;
    var out_header = header;
    out_header.payload_len = @intCast(payload.len);
    var header_buf: [header_len]u8 = undefined;
    writeHeader(&header_buf, out_header);
    @memcpy(buf[0..header_len], &header_buf);
    if (payload.len > 0) @memcpy(buf[header_len..][0..payload.len], payload);
    return buf[0 .. header_len + payload.len];
}

pub fn writeExitPayload(buf: *[4]u8, exit_code: u32) void {
    std.mem.writeInt(u32, buf, exit_code, .little);
}

pub fn readExitPayload(payload: []const u8) !u32 {
    if (payload.len != 4) return error.BadExitPayload;
    return std.mem.readInt(u32, payload[0..4], .little);
}

pub const Resize = struct {
    rows: u16,
    cols: u16,
};

pub fn writeResizePayload(buf: *[4]u8, resize: Resize) void {
    std.mem.writeInt(u16, buf[0..2], resize.rows, .little);
    std.mem.writeInt(u16, buf[2..4], resize.cols, .little);
}

pub fn readResizePayload(payload: []const u8) !Resize {
    if (payload.len != 4) return error.BadResizePayload;
    return .{
        .rows = std.mem.readInt(u16, payload[0..2], .little),
        .cols = std.mem.readInt(u16, payload[2..4], .little),
    };
}

test "round-trips frame headers" {
    var buf: [header_len]u8 = undefined;
    writeHeader(&buf, .{
        .frame_type = .data,
        .flags = 7,
        .stream_id = .stdout,
        .offset = 42,
        .payload_len = 12,
    });

    const parsed = try readHeader(&buf);
    try std.testing.expectEqual(FrameType.data, parsed.frame_type);
    try std.testing.expectEqual(@as(u16, 7), parsed.flags);
    try std.testing.expectEqual(StreamId.stdout, parsed.stream_id);
    try std.testing.expectEqual(@as(u64, 42), parsed.offset);
    try std.testing.expectEqual(@as(u32, 12), parsed.payload_len);
}

test "rejects malformed headers" {
    var buf: [header_len]u8 = @splat(0);
    try std.testing.expectError(error.BadMagic, readHeader(&buf));

    @memcpy(buf[0..4], magic);
    buf[4] = 99;
    try std.testing.expectError(error.UnsupportedVersion, readHeader(&buf));

    buf[4] = version;
    buf[5] = 99;
    try std.testing.expectError(error.UnknownFrameType, readHeader(&buf));

    buf[5] = @backingInt(FrameType.data);
    std.mem.writeInt(u32, buf[8..12], 99, .little);
    try std.testing.expectError(error.UnknownStreamId, readHeader(&buf));

    std.mem.writeInt(u32, buf[8..12], @backingInt(StreamId.stdout), .little);
    std.mem.writeInt(u32, buf[20..24], max_payload_len + 1, .little);
    try std.testing.expectError(error.PayloadTooLarge, readHeader(&buf));
}

test "writes complete frames" {
    var buf: [max_frame_len]u8 = undefined;
    const frame = try writeFrame(&buf, .{
        .frame_type = .close,
        .stream_id = .stdin,
        .offset = 3,
    }, "abc");
    try std.testing.expectEqual(@as(usize, header_len + 3), frame.len);
    var header_buf: [header_len]u8 = undefined;
    @memcpy(&header_buf, frame[0..header_len]);
    const header = try readHeader(&header_buf);
    try std.testing.expectEqual(FrameType.close, header.frame_type);
    try std.testing.expectEqual(StreamId.stdin, header.stream_id);
    try std.testing.expectEqual(@as(u64, 3), header.offset);
    try std.testing.expectEqual(@as(u32, 3), header.payload_len);
    try std.testing.expectEqualStrings("abc", frame[header_len..]);
}

test "round-trips resize payloads" {
    var buf: [4]u8 = undefined;
    writeResizePayload(&buf, .{ .rows = 40, .cols = 120 });
    const parsed = try readResizePayload(&buf);
    try std.testing.expectEqual(@as(u16, 40), parsed.rows);
    try std.testing.expectEqual(@as(u16, 120), parsed.cols);
}
