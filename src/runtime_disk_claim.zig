//! One-shot same-host claim transport for runtime disk-fork heads.
//!
//! A child sends one bounded JSON claim request over a private Unix stream.
//! The source replies with a fixed binary header carrying exactly one
//! `SCM_RIGHTS` fd, followed by one exact-length runtime disk descriptor, then
//! closes its write side. Tokens are random, one-use, child-bound, expiring,
//! and owned by a registry that closes every unclaimed head on cancellation or
//! shutdown.

const std = @import("std");
const fd_util = @import("fd.zig");
const runtime_disk_fork = @import("runtime_disk_fork.zig");
const spore = @import("spore.zig");

extern "c" fn mkstemp(template: [*:0]u8) c_int;
extern "c" fn getentropy(buffer: [*]u8, size: usize) c_int;

pub const max_claim_request_bytes: usize = 8192;
pub const max_children_per_batch: usize = 32;
pub const max_child_name_bytes: usize = 128;
pub const max_batch_name_bytes: usize = 128;
pub const max_rendered_child_name_bytes: usize = 4096;
pub const max_aggregate_descriptor_bytes: usize = 64 * 1024 * 1024;
pub const token_bytes: usize = 32;
pub const token_hex_bytes: usize = token_bytes * 2;
pub const claim_schema = "spore.disk-fork-claim.v1";
pub const claim_type = "disk-fork-claim";

const frame_magic = "SPDFD001";
const frame_version: u16 = 1;
const frame_header_len: usize = 16;
const max_ancillary_fds: usize = 2;
const max_sent_fds: usize = 3;

pub const Token = [token_bytes]u8;

pub const Error = runtime_disk_fork.Error || std.mem.Allocator.Error || error{
    AncillaryTruncated,
    BadBatch,
    BadClaimRequest,
    BadFrame,
    BatchAlreadyRegistered,
    BatchTooLarge,
    ClaimExpired,
    ClaimMismatch,
    ControlRequestTooLarge,
    DescriptorAggregateTooLarge,
    DuplicateChild,
    IoFailed,
    MissingFd,
    MultipleFds,
    ShortRead,
    ShortWrite,
    TrailingData,
    UnexpectedAncillary,
    UnknownClaim,
};

pub const ClaimRequest = struct {
    type: []const u8,
    schema: []const u8,
    token: []const u8,
    batch: []const u8,
    child: []const u8,
    child_index: u32,
    baseline_kind: runtime_disk_fork.BaselineKind,
    baseline_identity: []const u8,
};

pub const PendingClaim = struct {
    child_name: []const u8,
    child_index: u32,
    head: ?runtime_disk_fork.Head,

    pub fn deinit(self: *PendingClaim) void {
        if (self.head) |*head| head.deinit();
        self.head = null;
    }
};

pub const Registration = struct {
    token: Token,
};

const Entry = struct {
    token: Token,
    batch: []const u8,
    child: []const u8,
    child_index: u32,
    expires_at_ns: u64,
    head: runtime_disk_fork.Head,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.batch);
        allocator.free(self.child);
        self.head.deinit();
        self.* = undefined;
    }

    fn freeMetadata(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.batch);
        allocator.free(self.child);
    }
};

const PreparedEntry = struct {
    token: Token,
    batch: []const u8,
    child: []const u8,

    fn deinit(self: *PreparedEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.batch);
        allocator.free(self.child);
        self.* = undefined;
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn count(self: Registry) usize {
        return self.entries.items.len;
    }

    pub fn hasBatch(self: Registry, batch: []const u8) bool {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.batch, batch)) return true;
        }
        return false;
    }

    /// Atomically registers a batch. Heads remain in `pending` on error; on
    /// success each `head` becomes null and the registry owns it.
    pub fn registerBatch(
        self: *Registry,
        batch: []const u8,
        pending: []PendingClaim,
        now_ns: u64,
        expires_at_ns: u64,
    ) Error![]Registration {
        if (!validBindingName(batch, max_batch_name_bytes) or pending.len == 0 or pending.len > max_children_per_batch or expires_at_ns <= now_ns) return error.BadBatch;
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.batch, batch)) return error.BatchAlreadyRegistered;
        }

        var rendered_name_bytes: usize = 0;
        var aggregate_descriptor_bytes: usize = 0;
        for (pending, 0..) |pending_claim, i| {
            if (!validBindingName(pending_claim.child_name, max_child_name_bytes)) return error.BadBatch;
            if (pending_claim.child_index >= max_children_per_batch or pending_claim.head == null) return error.BadBatch;
            rendered_name_bytes = std.math.add(usize, rendered_name_bytes, pending_claim.child_name.len) catch return error.BatchTooLarge;
            if (rendered_name_bytes > max_rendered_child_name_bytes) return error.BatchTooLarge;
            const descriptor_bytes = try pending_claim.head.?.descriptor.encodedLen();
            aggregate_descriptor_bytes = std.math.add(usize, aggregate_descriptor_bytes, descriptor_bytes) catch return error.DescriptorAggregateTooLarge;
            if (aggregate_descriptor_bytes > max_aggregate_descriptor_bytes) return error.DescriptorAggregateTooLarge;
            try runtime_disk_fork.validateOverlayFd(pending_claim.head.?.overlay_fd, pending_claim.head.?.descriptor.logical_size);
            if (i > 0) {
                const first = pending[0].head.?.descriptor.baseline;
                const current = pending_claim.head.?.descriptor.baseline;
                if (first.kind != current.kind or !std.mem.eql(u8, first.identity, current.identity)) return error.BadBatch;
            }
            for (pending[0..i]) |earlier| {
                if (earlier.child_index == pending_claim.child_index or std.mem.eql(u8, earlier.child_name, pending_claim.child_name)) return error.DuplicateChild;
            }
        }

        const registrations = try self.allocator.alloc(Registration, pending.len);
        errdefer self.allocator.free(registrations);
        const prepared = try self.allocator.alloc(PreparedEntry, pending.len);
        defer self.allocator.free(prepared);
        var prepared_count: usize = 0;
        errdefer {
            for (prepared[0..prepared_count]) |*entry| entry.deinit(self.allocator);
        }

        for (pending, 0..) |pending_claim, i| {
            const batch_owned = try self.allocator.dupe(u8, batch);
            errdefer self.allocator.free(batch_owned);
            const child_owned = try self.allocator.dupe(u8, pending_claim.child_name);
            errdefer self.allocator.free(child_owned);
            const token = try self.uniqueToken(prepared[0..prepared_count]);
            prepared[i] = .{
                .token = token,
                .batch = batch_owned,
                .child = child_owned,
            };
            registrations[i] = .{ .token = token };
            prepared_count += 1;
        }

        try self.entries.ensureUnusedCapacity(self.allocator, pending.len);
        for (pending, prepared) |*pending_claim, metadata| {
            self.entries.appendAssumeCapacity(.{
                .token = metadata.token,
                .batch = metadata.batch,
                .child = metadata.child,
                .child_index = pending_claim.child_index,
                .expires_at_ns = expires_at_ns,
                .head = pending_claim.head.?,
            });
            pending_claim.head = null;
        }
        return registrations;
    }

    pub fn claim(self: *Registry, request: ClaimRequest, now_ns: u64) Error!runtime_disk_fork.Head {
        try validateClaimRequest(request);
        const requested_token = try parseTokenHex(request.token);
        for (self.entries.items, 0..) |entry, index| {
            if (!tokenEql(entry.token, requested_token)) continue;
            if (entry.expires_at_ns <= now_ns) {
                var expired = self.entries.swapRemove(index);
                expired.deinit(self.allocator);
                return error.ClaimExpired;
            }
            if (!std.mem.eql(u8, entry.batch, request.batch) or
                !std.mem.eql(u8, entry.child, request.child) or
                entry.child_index != request.child_index or
                entry.head.descriptor.baseline.kind != request.baseline_kind or
                !std.mem.eql(u8, entry.head.descriptor.baseline.identity, request.baseline_identity)) return error.ClaimMismatch;

            var claimed = self.entries.swapRemove(index);
            const head = claimed.head;
            claimed.freeMetadata(self.allocator);
            return head;
        }
        return error.UnknownClaim;
    }

    pub fn cancelBatch(self: *Registry, batch: []const u8) usize {
        var cancelled: usize = 0;
        var index: usize = 0;
        while (index < self.entries.items.len) {
            if (!std.mem.eql(u8, self.entries.items[index].batch, batch)) {
                index += 1;
                continue;
            }
            var entry = self.entries.swapRemove(index);
            entry.deinit(self.allocator);
            cancelled += 1;
        }
        return cancelled;
    }

    pub fn expire(self: *Registry, now_ns: u64) usize {
        var expired_count: usize = 0;
        var index: usize = 0;
        while (index < self.entries.items.len) {
            if (self.entries.items[index].expires_at_ns > now_ns) {
                index += 1;
                continue;
            }
            var entry = self.entries.swapRemove(index);
            entry.deinit(self.allocator);
            expired_count += 1;
        }
        return expired_count;
    }

    fn uniqueToken(self: Registry, prepared: []const PreparedEntry) Error!Token {
        while (true) {
            const token = try randomToken();
            var duplicate = false;
            for (self.entries.items) |entry| duplicate = duplicate or tokenEql(entry.token, token);
            for (prepared) |entry| duplicate = duplicate or tokenEql(entry.token, token);
            if (!duplicate) return token;
        }
    }
};

pub fn randomToken() Error!Token {
    var token: Token = undefined;
    if (getentropy(&token, token.len) != 0) return error.IoFailed;
    return token;
}

pub fn formatTokenHex(token: Token, out: *[token_hex_bytes]u8) []const u8 {
    const alphabet = "0123456789abcdef";
    for (token, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

pub fn writeClaimRequest(allocator: std.mem.Allocator, socket_fd: std.c.fd_t, request: ClaimRequest) Error!void {
    try validateClaimRequest(request);
    const json = std.json.Stringify.valueAlloc(allocator, request, .{}) catch return error.OutOfMemory;
    defer allocator.free(json);
    const framed_len = std.math.add(usize, json.len, 1) catch return error.ControlRequestTooLarge;
    if (framed_len > max_claim_request_bytes) return error.ControlRequestTooLarge;
    try writeAll(socket_fd, json);
    try writeAll(socket_fd, "\n");
}

pub fn readClaimRequest(allocator: std.mem.Allocator, socket_fd: std.c.fd_t) Error!std.json.Parsed(ClaimRequest) {
    var bytes: [max_claim_request_bytes]u8 = undefined;
    var len: usize = 0;
    while (len < bytes.len) {
        const n = try recvNoAncillary(socket_fd, bytes[len .. len + 1]);
        if (n == 0) return error.ShortRead;
        if (bytes[len] == '\n') return parseClaimBytes(allocator, bytes[0..len]);
        len += 1;
    }
    return error.ControlRequestTooLarge;
}

pub fn parseClaimBytes(allocator: std.mem.Allocator, bytes: []const u8) Error!std.json.Parsed(ClaimRequest) {
    if (bytes.len == 0 or bytes.len >= max_claim_request_bytes) return error.BadClaimRequest;
    var parsed = std.json.parseFromSlice(ClaimRequest, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch return error.BadClaimRequest;
    errdefer parsed.deinit();
    try validateClaimRequest(parsed.value);
    return parsed;
}

pub fn serveClaim(registry: *Registry, allocator: std.mem.Allocator, socket_fd: std.c.fd_t, now_ns: u64) Error!void {
    var parsed = try readClaimRequest(allocator, socket_fd);
    defer parsed.deinit();
    var head = try registry.claim(parsed.value, now_ns);
    defer head.deinit();
    try sendHead(socket_fd, allocator, &head);
}

pub fn sendHead(socket_fd: std.c.fd_t, allocator: std.mem.Allocator, head: *const runtime_disk_fork.Head) Error!void {
    try runtime_disk_fork.validateOverlayFd(head.overlay_fd, head.descriptor.logical_size);
    const descriptor = try head.descriptor.encodeAlloc(allocator);
    defer allocator.free(descriptor);
    const header = encodeFrameHeader(descriptor.len);
    defer _ = std.c.shutdown(socket_fd, std.c.SHUT.WR);
    try sendWithFds(socket_fd, &header, &.{head.overlay_fd});
    try writeAll(socket_fd, descriptor);
}

pub fn receiveHead(allocator: std.mem.Allocator, socket_fd: std.c.fd_t) Error!runtime_disk_fork.Head {
    var header: [frame_header_len]u8 = undefined;
    const first = try recvWithFds(socket_fd, &header);
    var received_fd: ?std.c.fd_t = null;
    errdefer {
        if (received_fd) |fd| _ = std.c.close(fd);
    }
    if (first.fd_count == 0) return error.MissingFd;
    if (first.fd_count != 1) {
        closeReceivedFds(first.fds[0..first.fd_count]);
        return error.MultipleFds;
    }
    received_fd = first.fds[0];
    if (first.byte_count < header.len) try recvExactNoAncillary(socket_fd, header[first.byte_count..]);
    const descriptor_len = try parseFrameHeader(header);
    const descriptor_bytes = try allocator.alloc(u8, descriptor_len);
    defer allocator.free(descriptor_bytes);
    try recvExactNoAncillary(socket_fd, descriptor_bytes);
    var trailing: [1]u8 = undefined;
    if (try recvNoAncillary(socket_fd, &trailing) != 0) return error.TrailingData;

    var descriptor = try runtime_disk_fork.Descriptor.parse(allocator, descriptor_bytes);
    errdefer descriptor.deinit();
    try runtime_disk_fork.validateOverlayFd(received_fd.?, descriptor.logical_size);
    const fd = received_fd.?;
    received_fd = null;
    return .{ .descriptor = descriptor, .overlay_fd = fd };
}

const ReceivedFds = struct {
    byte_count: usize,
    fds: [max_ancillary_fds]std.c.fd_t,
    fd_count: usize,
};

fn sendWithFds(socket_fd: std.c.fd_t, bytes: []const u8, fds: []const std.c.fd_t) Error!void {
    if (bytes.len == 0 or fds.len > max_sent_fds) return error.IoFailed;
    const control_capacity = comptime cmsgSpace(max_sent_fds * @sizeOf(std.c.fd_t));
    var control: [control_capacity]u8 align(@alignOf(std.c.cmsghdr)) = undefined;
    var control_len: usize = 0;
    if (fds.len != 0) {
        @memset(&control, 0);
        control_len = cmsgSpace(fds.len * @sizeOf(std.c.fd_t));
        const cmsg: *std.c.cmsghdr = @ptrCast(&control);
        cmsg.len = @intCast(cmsgLen(fds.len * @sizeOf(std.c.fd_t)));
        cmsg.level = std.c.SOL.SOCKET;
        cmsg.type = std.c.SCM.RIGHTS;
        const data = control[cmsgDataOffset()..][0 .. fds.len * @sizeOf(std.c.fd_t)];
        @memcpy(data, std.mem.sliceAsBytes(fds));
    }

    var iov: std.c.iovec_const = .{ .base = @constCast(bytes.ptr), .len = bytes.len };
    const message: std.c.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = (&iov)[0..1],
        .iovlen = 1,
        .control = if (control_len == 0) null else &control,
        .controllen = @intCast(control_len),
        .flags = 0,
    };
    while (true) {
        const rc = std.c.sendmsg(socket_fd, &message, std.c.MSG.NOSIGNAL);
        if (rc > 0) {
            const sent: usize = @intCast(rc);
            if (sent < bytes.len) try writeAll(socket_fd, bytes[sent..]);
            return;
        }
        if (rc == 0) return error.ShortWrite;
        if (std.c.errno(rc) == .INTR) continue;
        return error.IoFailed;
    }
}

fn recvWithFds(socket_fd: std.c.fd_t, bytes: []u8) Error!ReceivedFds {
    const control_capacity = comptime cmsgSpace(max_ancillary_fds * @sizeOf(std.c.fd_t));
    var control: [control_capacity]u8 align(@alignOf(std.c.cmsghdr)) = undefined;
    var iov: std.c.iovec = .{ .base = bytes.ptr, .len = bytes.len };
    var message: std.c.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = (&iov)[0..1],
        .iovlen = 1,
        .control = &control,
        .controllen = @intCast(control.len),
        .flags = 0,
    };
    while (true) {
        const rc = std.c.recvmsg(socket_fd, &message, 0);
        if (rc >= 0) {
            const actual_control_len: usize = @intCast(message.controllen);
            if (actual_control_len > control.len) {
                closeTruncatedRights(&control);
                return error.AncillaryTruncated;
            }
            if ((message.flags & std.c.MSG.CTRUNC) != 0) {
                closeTruncatedRights(control[0..actual_control_len]);
                return error.AncillaryTruncated;
            }
            var result = try parseAncillary(control[0..actual_control_len]);
            errdefer closeReceivedFds(result.fds[0..result.fd_count]);
            result.byte_count = @intCast(rc);
            return result;
        }
        if (std.c.errno(rc) == .INTR) continue;
        return error.IoFailed;
    }
}

fn parseAncillary(control: []const u8) Error!ReceivedFds {
    var result = ReceivedFds{ .byte_count = 0, .fds = undefined, .fd_count = 0 };
    errdefer closeReceivedFds(result.fds[0..result.fd_count]);
    var offset: usize = 0;
    while (offset + @sizeOf(std.c.cmsghdr) <= control.len) {
        const cmsg: *align(1) const std.c.cmsghdr = @ptrCast(control[offset..].ptr);
        const message_len: usize = @intCast(cmsg.len);
        if (message_len < cmsgDataOffset() or message_len > control.len - offset) return error.UnexpectedAncillary;
        if (cmsg.level != std.c.SOL.SOCKET or cmsg.type != std.c.SCM.RIGHTS) return error.UnexpectedAncillary;
        const data_len = message_len - cmsgDataOffset();
        if (data_len == 0 or data_len % @sizeOf(std.c.fd_t) != 0) return error.UnexpectedAncillary;
        const data = control[offset + cmsgDataOffset() ..][0..data_len];
        var data_offset: usize = 0;
        while (data_offset < data.len) : (data_offset += @sizeOf(std.c.fd_t)) {
            var fd: std.c.fd_t = undefined;
            @memcpy(std.mem.asBytes(&fd), data[data_offset..][0..@sizeOf(std.c.fd_t)]);
            fd_util.setCloseOnExec(fd) catch {
                _ = std.c.close(fd);
                return error.IoFailed;
            };
            if (result.fd_count == result.fds.len) {
                _ = std.c.close(fd);
                return error.MultipleFds;
            }
            result.fds[result.fd_count] = fd;
            result.fd_count += 1;
        }
        const next = std.mem.alignForward(usize, message_len, @alignOf(std.c.cmsghdr));
        if (next > control.len - offset) break;
        offset += next;
    }
    return result;
}

fn recvNoAncillary(socket_fd: std.c.fd_t, bytes: []u8) Error!usize {
    const result = try recvWithFds(socket_fd, bytes);
    if (result.fd_count != 0) {
        closeReceivedFds(result.fds[0..result.fd_count]);
        return error.UnexpectedAncillary;
    }
    return result.byte_count;
}

fn recvExactNoAncillary(socket_fd: std.c.fd_t, bytes: []u8) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = try recvNoAncillary(socket_fd, bytes[offset..]);
        if (n == 0) return error.ShortRead;
        offset += n;
    }
}

fn writeAll(fd: std.c.fd_t, bytes: []const u8) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = std.c.send(fd, bytes.ptr + offset, bytes.len - offset, std.c.MSG.NOSIGNAL);
        if (rc > 0) {
            offset += @intCast(rc);
            continue;
        }
        if (rc == 0) return error.ShortWrite;
        if (std.c.errno(rc) == .INTR) continue;
        return error.IoFailed;
    }
}

fn closeReceivedFds(fds: []const std.c.fd_t) void {
    for (fds) |fd| _ = std.c.close(fd);
}

fn closeTruncatedRights(control: []const u8) void {
    var message_offset: usize = 0;
    while (message_offset + @sizeOf(std.c.cmsghdr) <= control.len) {
        const cmsg: *align(1) const std.c.cmsghdr = @ptrCast(control[message_offset..].ptr);
        const declared_len: usize = @intCast(cmsg.len);
        if (declared_len < cmsgDataOffset()) return;
        const available_len = @min(declared_len, control.len - message_offset);
        if (cmsg.level == std.c.SOL.SOCKET and cmsg.type == std.c.SCM.RIGHTS) {
            const available = available_len - cmsgDataOffset();
            const complete_fd_bytes = available - (available % @sizeOf(std.c.fd_t));
            const data = control[message_offset + cmsgDataOffset() ..][0..complete_fd_bytes];
            var fd_offset: usize = 0;
            while (fd_offset < data.len) : (fd_offset += @sizeOf(std.c.fd_t)) {
                var fd: std.c.fd_t = undefined;
                @memcpy(std.mem.asBytes(&fd), data[fd_offset..][0..@sizeOf(std.c.fd_t)]);
                _ = std.c.close(fd);
            }
        }
        if (declared_len > control.len - message_offset) return;
        const next = std.mem.alignForward(usize, declared_len, @alignOf(std.c.cmsghdr));
        if (next > control.len - message_offset) return;
        message_offset += next;
    }
}

fn encodeFrameHeader(descriptor_len: usize) [frame_header_len]u8 {
    var header = [_]u8{0} ** frame_header_len;
    @memcpy(header[0..frame_magic.len], frame_magic);
    std.mem.writeInt(u16, header[8..10], frame_version, .little);
    std.mem.writeInt(u32, header[12..16], @intCast(descriptor_len), .little);
    return header;
}

fn parseFrameHeader(header: [frame_header_len]u8) Error!usize {
    if (!std.mem.eql(u8, header[0..frame_magic.len], frame_magic)) return error.BadFrame;
    if (std.mem.readInt(u16, header[8..10], .little) != frame_version) return error.BadFrame;
    if (!std.mem.allEqual(u8, header[10..12], 0)) return error.BadFrame;
    const descriptor_len: usize = std.mem.readInt(u32, header[12..16], .little);
    if (descriptor_len < runtime_disk_fork.header_len or descriptor_len > runtime_disk_fork.max_descriptor_bytes) return error.BadFrame;
    return descriptor_len;
}

fn cmsgDataOffset() usize {
    return std.mem.alignForward(usize, @sizeOf(std.c.cmsghdr), @alignOf(std.c.cmsghdr));
}

fn cmsgLen(data_len: usize) usize {
    return cmsgDataOffset() + data_len;
}

fn cmsgSpace(data_len: usize) usize {
    return cmsgDataOffset() + std.mem.alignForward(usize, data_len, @alignOf(std.c.cmsghdr));
}

fn parseTokenHex(hex: []const u8) Error!Token {
    if (hex.len != token_hex_bytes) return error.BadClaimRequest;
    var token: Token = undefined;
    for (&token, 0..) |*byte, i| {
        const high = hexNibble(hex[i * 2]) orelse return error.BadClaimRequest;
        const low = hexNibble(hex[i * 2 + 1]) orelse return error.BadClaimRequest;
        byte.* = (high << 4) | low;
    }
    return token;
}

fn hexNibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        else => null,
    };
}

fn tokenEql(a: Token, b: Token) bool {
    return std.crypto.timing_safe.eql(Token, a, b);
}

fn validateClaimRequest(request: ClaimRequest) Error!void {
    if (!std.mem.eql(u8, request.type, claim_type)) return error.BadClaimRequest;
    if (!std.mem.eql(u8, request.schema, claim_schema)) return error.BadClaimRequest;
    _ = try parseTokenHex(request.token);
    if (!validBindingName(request.batch, max_batch_name_bytes) or !validBindingName(request.child, max_child_name_bytes)) return error.BadClaimRequest;
    if (request.child_index >= max_children_per_batch) return error.BadClaimRequest;
    spore.validateDiskDigest(request.baseline_identity) catch return error.BadClaimRequest;
}

pub fn validBindingName(value: []const u8, max_len: usize) bool {
    if (value.len == 0 or value.len > max_len or !std.ascii.isAlphanumeric(value[0])) return false;
    for (value[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-')) return false;
    }
    return true;
}

fn socketPair() Error![2]std.c.fd_t {
    var pair: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair) != 0) return error.IoFailed;
    errdefer {
        _ = std.c.close(pair[0]);
        _ = std.c.close(pair[1]);
    }
    try fd_util.setCloseOnExec(pair[0]);
    try fd_util.setCloseOnExec(pair[1]);
    return pair;
}

fn createUnlinkedSizedFd(allocator: std.mem.Allocator, logical_size: u64) Error!std.c.fd_t {
    const template = try allocator.dupeZ(u8, "/tmp/sporevm-disk-claim-XXXXXX");
    defer allocator.free(template);
    const fd = mkstemp(template.ptr);
    if (fd < 0) return error.IoFailed;
    errdefer _ = std.c.close(fd);
    if (std.c.unlink(template.ptr) != 0) return error.IoFailed;
    try fd_util.setCloseOnExec(fd);
    const size = std.math.cast(std.c.off_t, logical_size) orelse return error.BadOverlay;
    if (std.c.ftruncate(fd, size) != 0) return error.IoFailed;
    return fd;
}

fn makeSmokeHead(allocator: std.mem.Allocator) Error!runtime_disk_fork.Head {
    const logical_size = 2 * spore.disk_chunk_size;
    const identity = try allocator.dupe(u8, "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    errdefer allocator.free(identity);
    const overlay_chunks = try allocator.alloc(u8, 1);
    errdefer allocator.free(overlay_chunks);
    const zero_chunks = try allocator.alloc(u8, 1);
    errdefer allocator.free(zero_chunks);
    overlay_chunks[0] = 0b00000001;
    zero_chunks[0] = 0b00000010;
    const overlay_fd = try createUnlinkedSizedFd(allocator, logical_size);
    errdefer _ = std.c.close(overlay_fd);
    return .{
        .descriptor = .{
            .allocator = allocator,
            .baseline = .{ .kind = .rootfs, .identity = identity },
            .clone_method = .reflink,
            .logical_size = logical_size,
            .chunk_size = spore.disk_chunk_size,
            .chunk_count = 2,
            .overlay_chunks = overlay_chunks,
            .zero_chunks = zero_chunks,
        },
        .overlay_fd = overlay_fd,
    };
}

/// Exercises the actual descriptor and fd transport after the monitor jail is
/// active. The jail smoke invokes this without changing either sandbox policy.
pub fn smokeRoundTrip(allocator: std.mem.Allocator) Error!void {
    const pair = try socketPair();
    defer _ = std.c.close(pair[0]);
    defer _ = std.c.close(pair[1]);
    var sent = try makeSmokeHead(allocator);
    defer sent.deinit();
    try sendHead(pair[0], allocator, &sent);
    var received = try receiveHead(allocator, pair[1]);
    defer received.deinit();
    if (!std.mem.eql(u8, sent.descriptor.baseline.identity, received.descriptor.baseline.identity)) return error.BadFrame;
}

test "claim request is bounded, canonical, and strict" {
    const allocator = std.testing.allocator;
    const pair = try socketPair();
    defer _ = std.c.close(pair[0]);
    defer _ = std.c.close(pair[1]);

    const token = [_]u8{0xAB} ** token_bytes;
    var token_hex: [token_hex_bytes]u8 = undefined;
    const request = ClaimRequest{
        .type = claim_type,
        .schema = claim_schema,
        .token = formatTokenHex(token, &token_hex),
        .batch = "parent-42-100",
        .child = "child-1",
        .child_index = 1,
        .baseline_kind = .rootfs,
        .baseline_identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
    try writeClaimRequest(allocator, pair[0], request);
    var parsed = try readClaimRequest(allocator, pair[1]);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(claim_schema, parsed.value.schema);
    try std.testing.expectEqualStrings(request.token, parsed.value.token);
    try std.testing.expectEqualStrings(request.batch, parsed.value.batch);
    try std.testing.expectEqualStrings(request.child, parsed.value.child);
    try std.testing.expectEqual(request.child_index, parsed.value.child_index);
    try std.testing.expectEqual(request.baseline_kind, parsed.value.baseline_kind);
    try std.testing.expectEqualStrings(request.baseline_identity, parsed.value.baseline_identity);

    try std.testing.expectError(error.BadClaimRequest, parseClaimBytes(allocator,
        \\{"schema":"spore.disk-fork-claim.v1","token":"abababababababababababababababababababababababababababababababab","batch":"parent","child":"child","child_index":0,"baseline_kind":"rootfs","baseline_identity":"blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    ));
    try std.testing.expectError(error.BadClaimRequest, parseClaimBytes(allocator,
        \\{"type":"disk-fork-claim","schema":"spore.disk-fork-claim.v1","token":"ABABABABABABABABABABABABABABABABABABABABABABABABABABABABABAB","batch":"parent","child":"child","child_index":0,"baseline_kind":"rootfs","baseline_identity":"blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    ));
    try std.testing.expectError(error.BadClaimRequest, parseClaimBytes(allocator,
        \\{"type":"disk-fork-claim","schema":"spore.disk-fork-claim.v1","token":"abababababababababababababababababababababababababababababababab","batch":"parent","child":"child","child_index":0,"baseline_kind":"rootfs","baseline_identity":"blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","extra":true}
    ));
}

test "claim request rejects an unterminated 8192-byte control line" {
    const pair = try socketPair();
    defer _ = std.c.close(pair[0]);
    defer _ = std.c.close(pair[1]);
    const oversized = [_]u8{'a'} ** max_claim_request_bytes;
    try writeAll(pair[0], &oversized);
    try std.testing.expectError(error.ControlRequestTooLarge, readClaimRequest(std.testing.allocator, pair[1]));
}

test "SCM_RIGHTS head frame round trips one unlinked overlay" {
    const allocator = std.testing.allocator;
    const pair = try socketPair();
    defer _ = std.c.close(pair[0]);
    defer _ = std.c.close(pair[1]);
    var sent = try makeSmokeHead(allocator);
    defer sent.deinit();
    const sent_fd = sent.overlay_fd;
    try sendHead(pair[0], allocator, &sent);
    var received = try receiveHead(allocator, pair[1]);
    defer received.deinit();
    try std.testing.expect(received.overlay_fd != sent_fd);
    try std.testing.expectEqualStrings(sent.descriptor.baseline.identity, received.descriptor.baseline.identity);
    try std.testing.expect(received.descriptor.overlay(0));
    try std.testing.expect(received.descriptor.zero(1));
    try runtime_disk_fork.validateOverlayFd(received.overlay_fd, received.descriptor.logical_size);
    try std.testing.expect(std.c.fcntl(sent_fd, std.c.F.GETFD, @as(c_int, 0)) >= 0);
}

test "claim registry binds tokens once and closes cancelled or expired heads" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    var pending = [_]PendingClaim{
        .{ .child_name = "child-0", .child_index = 0, .head = try makeSmokeHead(allocator) },
        .{ .child_name = "child-1", .child_index = 1, .head = try makeSmokeHead(allocator) },
    };
    defer for (&pending) |*item| item.deinit();
    const cancelled_fd = pending[1].head.?.overlay_fd;
    const registrations = try registry.registerBatch("batch-1", &pending, 100, 200);
    defer allocator.free(registrations);
    try std.testing.expect(pending[0].head == null and pending[1].head == null);
    try std.testing.expectEqual(@as(usize, 2), registry.count());

    var token_hex: [token_hex_bytes]u8 = undefined;
    var request = ClaimRequest{
        .type = claim_type,
        .schema = claim_schema,
        .token = formatTokenHex(registrations[0].token, &token_hex),
        .batch = "batch-1",
        .child = "child-1",
        .child_index = 0,
        .baseline_kind = .rootfs,
        .baseline_identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
    try std.testing.expectError(error.ClaimMismatch, registry.claim(request, 150));
    try std.testing.expectEqual(@as(usize, 2), registry.count());
    request.child = "child-0";
    request.baseline_identity = "blake3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    try std.testing.expectError(error.ClaimMismatch, registry.claim(request, 150));
    request.baseline_identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    var claimed = try registry.claim(request, 150);
    defer claimed.deinit();
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expectError(error.UnknownClaim, registry.claim(request, 150));

    try std.testing.expectEqual(@as(usize, 1), registry.cancelBatch("batch-1"));
    try std.testing.expectEqual(@as(usize, 0), registry.count());
    try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(cancelled_fd, std.c.F.GETFD, @as(c_int, 0)));

    var expiring = [_]PendingClaim{.{ .child_name = "child-2", .child_index = 2, .head = try makeSmokeHead(allocator) }};
    defer expiring[0].deinit();
    const expired_fd = expiring[0].head.?.overlay_fd;
    const expiring_registration = try registry.registerBatch("batch-2", &expiring, 200, 300);
    defer allocator.free(expiring_registration);
    var expired_hex: [token_hex_bytes]u8 = undefined;
    const expired_request = ClaimRequest{
        .type = claim_type,
        .schema = claim_schema,
        .token = formatTokenHex(expiring_registration[0].token, &expired_hex),
        .batch = "batch-2",
        .child = "child-2",
        .child_index = 2,
        .baseline_kind = .rootfs,
        .baseline_identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
    try std.testing.expectError(error.ClaimExpired, registry.claim(expired_request, 300));
    try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(expired_fd, std.c.F.GETFD, @as(c_int, 0)));
}

test "claim registry shutdown closes every unclaimed head" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    var pending = [_]PendingClaim{.{ .child_name = "child", .child_index = 0, .head = try makeSmokeHead(allocator) }};
    defer pending[0].deinit();
    const unclaimed_fd = pending[0].head.?.overlay_fd;
    const registrations = try registry.registerBatch("batch", &pending, 1, 2);
    allocator.free(registrations);
    registry.deinit();
    try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(unclaimed_fd, std.c.F.GETFD, @as(c_int, 0)));
}

test "claim batch validation is atomic" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    var pending = [_]PendingClaim{
        .{ .child_name = "same", .child_index = 0, .head = try makeSmokeHead(allocator) },
        .{ .child_name = "same", .child_index = 1, .head = try makeSmokeHead(allocator) },
    };
    defer for (&pending) |*item| item.deinit();
    try std.testing.expectError(error.DuplicateChild, registry.registerBatch("batch", &pending, 1, 2));
    try std.testing.expect(pending[0].head != null and pending[1].head != null);
    try std.testing.expectEqual(@as(usize, 0), registry.count());

    var too_many: [max_children_per_batch + 1]PendingClaim = undefined;
    @memset(&too_many, .{ .child_name = "x", .child_index = 0, .head = null });
    try std.testing.expectError(error.BadBatch, registry.registerBatch("batch", &too_many, 1, 2));
}

test "registered claim serves one descriptor and fd end to end" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    var pending = [_]PendingClaim{.{ .child_name = "child-0", .child_index = 0, .head = try makeSmokeHead(allocator) }};
    defer pending[0].deinit();
    const registrations = try registry.registerBatch("batch", &pending, 10, 20);
    defer allocator.free(registrations);
    var token_hex: [token_hex_bytes]u8 = undefined;
    const request = ClaimRequest{
        .type = claim_type,
        .schema = claim_schema,
        .token = formatTokenHex(registrations[0].token, &token_hex),
        .batch = "batch",
        .child = "child-0",
        .child_index = 0,
        .baseline_kind = .rootfs,
        .baseline_identity = "blake3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
    const pair = try socketPair();
    defer _ = std.c.close(pair[0]);
    defer _ = std.c.close(pair[1]);
    try writeClaimRequest(allocator, pair[1], request);
    try serveClaim(&registry, allocator, pair[0], 15);
    var received = try receiveHead(allocator, pair[1]);
    defer received.deinit();
    try std.testing.expectEqual(@as(usize, 0), registry.count());
    try std.testing.expectEqualStrings(request.baseline_identity, received.descriptor.baseline.identity);
}

test "head receiver rejects missing multiple truncated and second ancillary fds" {
    const allocator = std.testing.allocator;
    var head = try makeSmokeHead(allocator);
    defer head.deinit();
    const descriptor = try head.descriptor.encodeAlloc(allocator);
    defer allocator.free(descriptor);
    const header = encodeFrameHeader(descriptor.len);

    {
        const pair = try socketPair();
        defer _ = std.c.close(pair[0]);
        defer _ = std.c.close(pair[1]);
        try sendWithFds(pair[0], &header, &.{});
        try writeAll(pair[0], descriptor);
        _ = std.c.shutdown(pair[0], std.c.SHUT.WR);
        try std.testing.expectError(error.MissingFd, receiveHead(allocator, pair[1]));
    }
    {
        const pair = try socketPair();
        defer _ = std.c.close(pair[0]);
        defer _ = std.c.close(pair[1]);
        const fds = [_]std.c.fd_t{ head.overlay_fd, head.overlay_fd };
        try sendWithFds(pair[0], &header, &fds);
        try writeAll(pair[0], descriptor);
        _ = std.c.shutdown(pair[0], std.c.SHUT.WR);
        try std.testing.expectError(error.MultipleFds, receiveHead(allocator, pair[1]));
    }
    {
        const pair = try socketPair();
        defer _ = std.c.close(pair[0]);
        defer _ = std.c.close(pair[1]);
        const fds = [_]std.c.fd_t{ head.overlay_fd, head.overlay_fd, head.overlay_fd };
        try sendWithFds(pair[0], &header, &fds);
        try writeAll(pair[0], descriptor);
        _ = std.c.shutdown(pair[0], std.c.SHUT.WR);
        try std.testing.expectError(error.AncillaryTruncated, receiveHead(allocator, pair[1]));
    }
    {
        const pair = try socketPair();
        defer _ = std.c.close(pair[0]);
        defer _ = std.c.close(pair[1]);
        try sendWithFds(pair[0], &header, &.{head.overlay_fd});
        try sendWithFds(pair[0], descriptor, &.{head.overlay_fd});
        _ = std.c.shutdown(pair[0], std.c.SHUT.WR);
        try std.testing.expectError(error.UnexpectedAncillary, receiveHead(allocator, pair[1]));
    }
}

test "head receiver rejects short malformed trailing and wrongly sized frames" {
    const allocator = std.testing.allocator;
    var head = try makeSmokeHead(allocator);
    defer head.deinit();
    const descriptor = try head.descriptor.encodeAlloc(allocator);
    defer allocator.free(descriptor);
    const header = encodeFrameHeader(descriptor.len);

    {
        const pair = try socketPair();
        defer _ = std.c.close(pair[0]);
        defer _ = std.c.close(pair[1]);
        try sendWithFds(pair[0], header[0..8], &.{head.overlay_fd});
        _ = std.c.shutdown(pair[0], std.c.SHUT.WR);
        try std.testing.expectError(error.ShortRead, receiveHead(allocator, pair[1]));
    }
    {
        const pair = try socketPair();
        defer _ = std.c.close(pair[0]);
        defer _ = std.c.close(pair[1]);
        var bad_header = header;
        bad_header[10] = 1;
        try sendWithFds(pair[0], &bad_header, &.{head.overlay_fd});
        try writeAll(pair[0], descriptor);
        _ = std.c.shutdown(pair[0], std.c.SHUT.WR);
        try std.testing.expectError(error.BadFrame, receiveHead(allocator, pair[1]));
    }
    {
        const pair = try socketPair();
        defer _ = std.c.close(pair[0]);
        defer _ = std.c.close(pair[1]);
        try sendWithFds(pair[0], &header, &.{head.overlay_fd});
        try writeAll(pair[0], descriptor);
        try writeAll(pair[0], "x");
        _ = std.c.shutdown(pair[0], std.c.SHUT.WR);
        try std.testing.expectError(error.TrailingData, receiveHead(allocator, pair[1]));
    }
    {
        const pair = try socketPair();
        defer _ = std.c.close(pair[0]);
        defer _ = std.c.close(pair[1]);
        const wrong_size_fd = try createUnlinkedSizedFd(allocator, 1);
        defer _ = std.c.close(wrong_size_fd);
        try sendWithFds(pair[0], &header, &.{wrong_size_fd});
        try writeAll(pair[0], descriptor);
        _ = std.c.shutdown(pair[0], std.c.SHUT.WR);
        try std.testing.expectError(error.BadOverlay, receiveHead(allocator, pair[1]));
    }
    {
        const pair = try socketPair();
        defer _ = std.c.close(pair[0]);
        defer _ = std.c.close(pair[1]);
        const invalid_descriptor = [_]u8{0} ** runtime_disk_fork.header_len;
        const invalid_header = encodeFrameHeader(invalid_descriptor.len);
        try sendWithFds(pair[0], &invalid_header, &.{head.overlay_fd});
        try writeAll(pair[0], &invalid_descriptor);
        _ = std.c.shutdown(pair[0], std.c.SHUT.WR);
        try std.testing.expectError(error.BadDescriptor, receiveHead(allocator, pair[1]));
    }
}

test "ancillary parser rejects unknown control messages" {
    const control_len = comptime cmsgSpace(@sizeOf(std.c.fd_t));
    var control: [control_len]u8 align(@alignOf(std.c.cmsghdr)) = [_]u8{0} ** control_len;
    const cmsg: *std.c.cmsghdr = @ptrCast(&control);
    cmsg.len = @intCast(cmsgLen(@sizeOf(std.c.fd_t)));
    cmsg.level = std.c.SOL.SOCKET;
    cmsg.type = std.c.SCM.RIGHTS + 1;
    try std.testing.expectError(error.UnexpectedAncillary, parseAncillary(&control));

    var bad_version = encodeFrameHeader(runtime_disk_fork.header_len);
    bad_version[8] = 2;
    try std.testing.expectError(error.BadFrame, parseFrameHeader(bad_version));
}

fn fuzzClaimRequest(_: void, smith: *std.testing.Smith) anyerror!void {
    var bytes: [max_claim_request_bytes]u8 = undefined;
    const len = smith.slice(&bytes);
    var parsed = parseClaimBytes(std.testing.allocator, bytes[0..len]) catch return;
    defer parsed.deinit();
}

test "fuzz runtime disk claim request parser" {
    try std.testing.fuzz({}, fuzzClaimRequest, .{});
}

fn fuzzFrameHeader(_: void, smith: *std.testing.Smith) anyerror!void {
    var header: [frame_header_len]u8 = undefined;
    smith.bytes(&header);
    _ = parseFrameHeader(header) catch return;
}

test "fuzz runtime disk claim frame header" {
    try std.testing.fuzz({}, fuzzFrameHeader, .{});
}
