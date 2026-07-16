const std = @import("std");

const Io = std.Io;
const Blake3 = std.crypto.hash.Blake3;

const fetch_policy = @import("../host_fetch_policy.zig");
const policy = @import("remote_add_policy.zig");

pub const max_body_bytes: u64 = 1024 * 1024 * 1024;
pub const max_redirects: u8 = 5;
pub const default_mode: u32 = 0o600;
pub const max_inputs: u64 = 64;
pub const max_aggregate_bytes: u64 = max_body_bytes;
pub const max_timeout_ms: u64 = 10 * 60 * 1000;
pub const max_filename_bytes: usize = 255;

const staging_dir = "build/remote-add-staging";

pub const StagedFile = struct {
    path: []const u8,
    source_name: []const u8,
    content_digest: []const u8,
    size: u64,
    mtime_unix_seconds: ?i64,

    pub fn deinit(self: StagedFile, io: Io) void {
        Io.Dir.cwd().deleteFile(io, self.path) catch {};
    }
};

pub const Input = struct {
    stage_index: usize,
    instruction_index: usize,
    line: usize,
    canonical_instruction: []const u8,
    resolved_url: []const u8,
    resolved_dest: []const u8,
    env_digest: []const u8,
    workdir: []const u8,
};

pub const Prepared = struct {
    input: Input,
    staged: StagedFile,
};

pub const Budget = struct {
    total_bytes: u64 = 0,
};

pub const Diagnostics = struct {
    instruction_line: *usize,
    limit: *u64,
    actual: *u64,
};

pub const Batch = struct {
    io: Io,
    allocator: std.mem.Allocator,
    lock: Io.File,
    items: []const Prepared,

    pub fn deinit(self: *Batch) void {
        for (self.items) |item| item.staged.deinit(self.io);
        self.allocator.free(self.items);
        self.lock.unlock(self.io);
        self.lock.close(self.io);
        self.* = undefined;
    }
};

pub fn find(items: []const Prepared, stage_index: usize, instruction_index: usize) ?Prepared {
    for (items) |item| {
        if (item.input.stage_index == stage_index and item.input.instruction_index == instruction_index) return item;
    }
    return null;
}

pub fn prepare(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    inputs: []const Input,
    timeout_ms: u64,
    diagnostic: Diagnostics,
) !?Batch {
    if (inputs.len == 0) return null;
    const lock = try openStagingSession(io, allocator, cache_root);
    errdefer {
        lock.unlock(io);
        lock.close(io);
    }

    var output = std.array_list.Managed(Prepared).init(allocator);
    defer output.deinit();
    errdefer for (output.items) |item| item.staged.deinit(io);
    var budget: Budget = .{};
    const bounded_timeout_ms = @min(timeout_ms, max_timeout_ms);
    if (bounded_timeout_ms == 0) return error.RemoteAddTimeout;
    const deadline = Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(@intCast(bounded_timeout_ms)), .clock = .awake });

    const Context = struct {
        io: Io,
        allocator: std.mem.Allocator,
        cache_root: []const u8,
        inputs: []const Input,
        budget: *Budget,
        diagnostic: Diagnostics,
        output: *std.array_list.Managed(Prepared),
        done: Io.Event = .unset,
        completed: bool = false,
        failure: ?anyerror = null,

        fn run(context: *@This()) Io.Cancelable!void {
            defer context.done.set(context.io);
            prepareInner(
                context.io,
                context.allocator,
                context.cache_root,
                context.inputs,
                context.budget,
                context.diagnostic,
                context.output,
            ) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                context.failure = err;
                return;
            };
            context.completed = true;
        }
    };
    var context = Context{
        .io = io,
        .allocator = allocator,
        .cache_root = cache_root,
        .inputs = inputs,
        .budget = &budget,
        .diagnostic = diagnostic,
        .output = &output,
    };
    var future = io.concurrent(Context.run, .{&context}) catch return error.RemoteAddConcurrencyUnavailable;
    while (!context.done.isSet()) {
        context.done.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout => {
                if (Io.Clock.awake.now(io).nanoseconds < deadline.raw.nanoseconds) continue;
                _ = future.cancel(io) catch {};
                if (context.completed) break;
                return error.RemoteAddTimeout;
            },
            else => {
                _ = future.cancel(io) catch {};
                return err;
            },
        };
    }
    try future.await(io);
    if (context.failure) |err| return err;
    return .{ .io = io, .allocator = allocator, .lock = lock, .items = try output.toOwnedSlice() };
}

fn prepareInner(
    io: Io,
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    inputs: []const Input,
    budget: *Budget,
    diagnostic: Diagnostics,
    output: *std.array_list.Managed(Prepared),
) !void {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    errdefer {
        for (output.items) |item| item.staged.deinit(io);
        output.clearRetainingCapacity();
    }
    for (inputs) |input| {
        diagnostic.instruction_line.* = input.line;
        const remaining = max_aggregate_bytes - budget.total_bytes;
        const staged = fetch(allocator, io, &client, cache_root, input.resolved_url, remaining) catch |err| {
            if (err == error.RemoteAddBodyTooLarge) {
                diagnostic.limit.* = max_aggregate_bytes;
                diagnostic.actual.* = max_aggregate_bytes + 1;
                if (remaining < max_aggregate_bytes) return error.RemoteAddAggregateTooLarge;
            }
            return err;
        };
        errdefer staged.deinit(io);
        try output.append(.{ .input = input, .staged = staged });
        budget.total_bytes += staged.size;
    }
    diagnostic.instruction_line.* = 0;
}

fn openStagingSession(io: Io, allocator: std.mem.Allocator, cache_root: []const u8) !Io.File {
    const dir_path = try std.fs.path.join(allocator, &.{ cache_root, staging_dir });
    defer allocator.free(dir_path);
    try Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    const lock = try dir.createFile(io, ".lock", .{
        .read = true,
        .truncate = false,
        .permissions = @enumFromInt(0o600),
    });
    errdefer lock.close(io);
    if (try lock.tryLock(io, .exclusive)) {
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (std.mem.eql(u8, entry.name, ".lock")) continue;
            switch (entry.kind) {
                .file, .sym_link, .unknown => dir.deleteFile(io, entry.name) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => |other| return other,
                },
                else => return error.RemoteAddStagingInvalid,
            }
        }
        lock.unlock(io);
    }
    try lock.lock(io, .shared);
    return lock;
}

pub fn fetch(
    allocator: std.mem.Allocator,
    io: Io,
    client: *std.http.Client,
    cache_root: []const u8,
    requested_url: []const u8,
    body_limit: u64,
) !StagedFile {
    if (body_limit == 0 or body_limit > max_body_bytes) return error.RemoteAddBodyTooLarge;
    const requested = try validateUrl(requested_url);
    const dir = try std.fs.path.join(allocator, &.{ cache_root, staging_dir });
    try Io.Dir.cwd().createDirPath(io, dir);
    const path, var file = try createStagingFile(allocator, io, dir);
    errdefer Io.Dir.cwd().deleteFile(io, path) catch {};
    defer file.close(io);

    var current_url = requested_url;
    var redirects: u8 = 0;
    while (true) {
        const uri = try validateUrl(current_url);
        const target = try fetch_policy.resolveUriAddress(io, uri, .{ .require_https = true });
        const connection = try fetch_policy.connectResolvedUri(client, uri, target);
        var req = client.request(.GET, uri, .{
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
            .extra_headers = &.{std.http.Header{ .name = "accept", .value = "application/octet-stream" }},
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .connection = connection,
        }) catch |err| {
            client.connection_pool.release(connection, client.io);
            return err;
        };
        defer req.deinit();
        try req.sendBodiless();
        var header_buffer: [16 * 1024]u8 = undefined;
        var response = try req.receiveHead(&header_buffer);

        if (response.head.status.class() == .redirect) {
            redirects += 1;
            if (redirects > max_redirects) return error.RemoteAddTooManyRedirects;
            const location = try headerValueAlloc(allocator, response.head.bytes, "location") orelse
                return error.RemoteAddRedirectLocationMissing;
            current_url = try resolveRedirectUrl(allocator, current_url, location);
            _ = try validateUrl(current_url);
            continue;
        }
        if (response.head.status != .ok) return error.RemoteAddHttpStatus;
        if (response.head.content_encoding != .identity) return error.RemoteAddUnsupportedContentEncoding;
        const last_modified = try headerValueAlloc(allocator, response.head.bytes, "last-modified");
        const mtime_unix_seconds = if (last_modified) |value| parseHttpDate(value) else null;
        const source_name = try responseSourceName(allocator, requested, response.head.content_disposition);
        if (response.head.content_length) |length| {
            if (length > body_limit) return error.RemoteAddBodyTooLarge;
        }

        var writer_buffer: [64 * 1024]u8 = undefined;
        var writer: Io.File.Writer = .initStreaming(file, io, &writer_buffer);
        var body_buffer: [64 * 1024]u8 = undefined;
        const reader = response.reader(&body_buffer);
        var hash = Blake3.init(.{});
        const copied = streamBodyLimited(reader, &writer.interface, &hash, body_limit) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse err,
            else => |other| return other,
        };
        try writer.interface.flush();
        try file.sync(io);
        try Io.Dir.cwd().setFilePermissions(io, path, @enumFromInt(0o400), .{ .follow_symlinks = false });
        return .{
            .path = path,
            .source_name = source_name,
            .content_digest = try finishDigest(allocator, &hash),
            .size = copied,
            .mtime_unix_seconds = mtime_unix_seconds,
        };
    }
}

fn streamBodyLimited(reader: *Io.Reader, writer: *Io.Writer, hash: *Blake3, limit: u64) !u64 {
    var copied: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try reader.readSliceShort(&buffer);
        if (n == 0) return copied;
        if (n > limit - copied) return error.RemoteAddBodyTooLarge;
        copied += n;
        hash.update(buffer[0..n]);
        try writer.writeAll(buffer[0..n]);
    }
}

pub fn validateUrl(raw: []const u8) !std.Uri {
    return policy.validateUrl(raw);
}

pub fn sourceName(allocator: std.mem.Allocator, uri: std.Uri) ![]const u8 {
    const raw_path = try uri.path.toRawMaybeAlloc(allocator);
    return safeFileName(allocator, raw_path);
}

fn responseSourceName(allocator: std.mem.Allocator, requested: std.Uri, content_disposition: ?[]const u8) ![]const u8 {
    if (content_disposition) |value| if (try contentDispositionFilename(allocator, value)) |filename| {
        defer allocator.free(filename);
        if (filename.len != 0 and !std.mem.endsWith(u8, filename, "/")) return safeFileName(allocator, filename);
    };
    return sourceName(allocator, requested);
}

fn safeFileName(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    const without_slash = std.mem.trimEnd(u8, trimmed, "/");
    const name = if (without_slash.len == 0) "" else std.fs.path.basename(without_slash);
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return allocator.dupe(u8, "download");
    if (name.len > max_filename_bytes) return error.RemoteAddFilenameUnsupported;
    if (!std.unicode.utf8ValidateSlice(name)) return error.RemoteAddFilenameUnsupported;
    var view = try std.unicode.Utf8View.init(name);
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) return error.RemoteAddFilenameUnsupported;
    }
    return allocator.dupe(u8, name);
}

fn contentDispositionFilename(allocator: std.mem.Allocator, value: []const u8) !?[]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const scratch = arena_state.allocator();
    const first_semicolon = std.mem.indexOfScalar(u8, value, ';') orelse return null;
    const disposition = std.mem.trim(u8, value[0..first_semicolon], " \t");
    if (!validMimeToken(disposition)) return null;

    const Param = struct { key: []const u8, value: []const u8 };
    var params = std.array_list.Managed(Param).init(scratch);
    var cursor = first_semicolon;
    while (cursor < value.len) {
        while (cursor < value.len and (value[cursor] == ' ' or value[cursor] == '\t')) cursor += 1;
        if (cursor == value.len) break;
        if (value[cursor] != ';') return null;
        cursor += 1;
        while (cursor < value.len and (value[cursor] == ' ' or value[cursor] == '\t')) cursor += 1;
        if (cursor == value.len) break;
        const key_start = cursor;
        while (cursor < value.len and value[cursor] != '=' and value[cursor] != ';') cursor += 1;
        if (cursor == value.len or value[cursor] != '=') return null;
        const key = std.mem.trim(u8, value[key_start..cursor], " \t");
        if (!validMimeToken(key)) return null;
        cursor += 1;
        while (cursor < value.len and (value[cursor] == ' ' or value[cursor] == '\t')) cursor += 1;

        var parameter: []const u8 = undefined;
        if (cursor < value.len and value[cursor] == '"') {
            cursor += 1;
            var decoded: Io.Writer.Allocating = .init(scratch);
            while (cursor < value.len and value[cursor] != '"') {
                if (value[cursor] == '\\') {
                    cursor += 1;
                    if (cursor == value.len) return null;
                }
                if (value[cursor] == '\r' or value[cursor] == '\n') return null;
                try decoded.writer.writeByte(value[cursor]);
                cursor += 1;
            }
            if (cursor == value.len) return null;
            cursor += 1;
            parameter = try decoded.toOwnedSlice();
            while (cursor < value.len and (value[cursor] == ' ' or value[cursor] == '\t')) cursor += 1;
            if (cursor < value.len and value[cursor] != ';') return null;
        } else {
            const parameter_start = cursor;
            while (cursor < value.len and value[cursor] != ';') cursor += 1;
            parameter = std.mem.trim(u8, value[parameter_start..cursor], " \t");
            if (!validMimeToken(parameter)) return null;
        }
        for (params.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing.key, key)) {
                if (!std.mem.eql(u8, existing.value, parameter)) return null;
                break;
            }
        } else {
            try params.append(.{ .key = key, .value = parameter });
        }
    }

    const regular = mimeParam(params.items, "filename");
    if (mimeParam(params.items, "filename*")) |encoded| {
        const decoded = try decode2231(allocator, encoded) orelse return if (regular) |name| try allocator.dupe(u8, name) else null;
        return decoded;
    }

    var joined: Io.Writer.Allocating = .init(scratch);
    var continuation = false;
    var index: usize = 0;
    while (index < params.items.len) : (index += 1) {
        const simple_key = try std.fmt.allocPrint(scratch, "filename*{d}", .{index});
        if (mimeParam(params.items, simple_key)) |part| {
            continuation = true;
            try joined.writer.writeAll(part);
            continue;
        }
        const encoded_key = try std.fmt.allocPrint(scratch, "filename*{d}*", .{index});
        const part = mimeParam(params.items, encoded_key) orelse break;
        continuation = true;
        if (index == 0) {
            if (try decode2231(scratch, part)) |decoded| try joined.writer.writeAll(decoded);
        } else if (try percentDecode(scratch, part)) |decoded| {
            try joined.writer.writeAll(decoded);
        }
    }
    if (continuation) return try allocator.dupe(u8, try joined.toOwnedSlice());
    return if (regular) |name| try allocator.dupe(u8, name) else null;
}

fn mimeParam(params: anytype, key: []const u8) ?[]const u8 {
    for (params) |param| if (std.ascii.eqlIgnoreCase(param.key, key)) return param.value;
    return null;
}

fn validMimeToken(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (byte <= 0x20 or byte >= 0x7f or std.mem.indexOfScalar(u8, "()<>@,;:\\\"/[]?=", byte) != null) return false;
    }
    return true;
}

fn decode2231(allocator: std.mem.Allocator, value: []const u8) !?[]const u8 {
    const first = std.mem.indexOfScalar(u8, value, '\'') orelse return null;
    const second = std.mem.indexOfScalarPos(u8, value, first + 1, '\'') orelse return null;
    const charset = value[0..first];
    if (!std.ascii.eqlIgnoreCase(charset, "utf-8") and !std.ascii.eqlIgnoreCase(charset, "us-ascii")) return null;
    const decoded = try percentDecode(allocator, value[second + 1 ..]) orelse return null;
    if (!std.unicode.utf8ValidateSlice(decoded)) return null;
    if (std.ascii.eqlIgnoreCase(charset, "us-ascii")) for (decoded) |byte| if (byte >= 0x80) return null;
    return decoded;
}

fn percentDecode(allocator: std.mem.Allocator, value: []const u8) !?[]const u8 {
    var decoded: Io.Writer.Allocating = .init(allocator);
    defer decoded.deinit();
    var cursor: usize = 0;
    while (cursor < value.len) {
        if (value[cursor] != '%') {
            try decoded.writer.writeByte(value[cursor]);
            cursor += 1;
            continue;
        }
        if (value.len - cursor < 3) return null;
        const byte = std.fmt.parseInt(u8, value[cursor + 1 .. cursor + 3], 16) catch return null;
        try decoded.writer.writeByte(byte);
        cursor += 3;
    }
    return try decoded.toOwnedSlice();
}

fn createStagingFile(allocator: std.mem.Allocator, io: Io, dir: []const u8) !struct { []const u8, Io.File } {
    const nonce = Io.Clock.real.now(io).nanoseconds;
    for (0..100) |attempt| {
        const path = try std.fmt.allocPrint(allocator, "{s}/add-{d}-{d}-{d}.tmp", .{ dir, std.c.getpid(), nonce, attempt });
        const file = Io.Dir.cwd().createFile(io, path, .{
            .read = true,
            .exclusive = true,
            .permissions = @enumFromInt(0o600),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |other| return other,
        };
        return .{ path, file };
    }
    return error.RemoteAddStagingCreateFailed;
}

fn headerValueAlloc(allocator: std.mem.Allocator, head: []const u8, name: []const u8) !?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.first();
    var found: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        if (found != null) return error.RemoteAddMalformedResponse;
        found = try allocator.dupe(u8, std.mem.trim(u8, line[colon + 1 ..], " \t"));
    }
    return found;
}

fn resolveRedirectUrl(allocator: std.mem.Allocator, base_url: []const u8, location: []const u8) ![]const u8 {
    if (location.len == 0 or location.len > 64 * 1024) return error.UnsupportedRemoteAddUrl;
    const base = try validateUrl(base_url);
    var aux = try allocator.alloc(u8, location.len + base_url.len + 1024);
    defer allocator.free(aux);
    @memcpy(aux[0..location.len], location);
    var remaining = aux;
    const resolved = base.resolveInPlace(location.len, &remaining) catch return error.UnsupportedRemoteAddUrl;
    if (!std.ascii.eqlIgnoreCase(resolved.scheme, "https")) return error.UnsupportedRemoteAddUrl;
    var out: Io.Writer.Allocating = .init(allocator);
    try resolved.writeToStream(&out.writer, .{
        .scheme = true,
        .authentication = true,
        .authority = true,
        .path = true,
        .query = true,
        .fragment = true,
    });
    return out.toOwnedSlice();
}

fn parseHttpDate(value: []const u8) ?i64 {
    if (value.len == 29 and parseShortWeekday(value[0..3]) and value[3] == ',' and value[4] == ' ' and value[7] == ' ' and
        value[11] == ' ' and value[16] == ' ' and value[19] == ':' and value[22] == ':' and
        value[25] == ' ' and std.mem.eql(u8, value[26..29], "GMT"))
    {
        return parsedDate(
            parseDigits(value[5..7]) orelse return null,
            parseMonth(value[8..11]) orelse return null,
            parseDigits(value[12..16]) orelse return null,
            parseDigits(value[17..19]) orelse return null,
            parseDigits(value[20..22]) orelse return null,
            parseDigits(value[23..25]) orelse return null,
        );
    }
    if (value.len >= 30 and value.len <= 33) {
        const comma = std.mem.indexOfScalar(u8, value, ',') orelse return null;
        if (comma < 6 or comma > 9 or !parseLongWeekday(value[0..comma]) or comma + 24 != value.len or value[comma + 1] != ' ' or
            value[comma + 4] != '-' or value[comma + 8] != '-' or value[comma + 11] != ' ' or
            value[comma + 14] != ':' or value[comma + 17] != ':' or value[comma + 20] != ' ' or
            !std.mem.eql(u8, value[comma + 21 ..], "GMT")) return null;
        const short_year = parseDigits(value[comma + 9 .. comma + 11]) orelse return null;
        const year: u64 = if (short_year >= 69) 1900 + short_year else 2000 + short_year;
        return parsedDate(
            parseDigits(value[comma + 2 .. comma + 4]) orelse return null,
            parseMonth(value[comma + 5 .. comma + 8]) orelse return null,
            year,
            parseDigits(value[comma + 12 .. comma + 14]) orelse return null,
            parseDigits(value[comma + 15 .. comma + 17]) orelse return null,
            parseDigits(value[comma + 18 .. comma + 20]) orelse return null,
        );
    }
    if (value.len == 24 and parseShortWeekday(value[0..3]) and value[3] == ' ' and value[7] == ' ' and value[10] == ' ' and
        value[13] == ':' and value[16] == ':' and value[19] == ' ')
    {
        const day_text = value[8..10];
        const day = if (day_text[0] == ' ') parseDigits(day_text[1..2]) else parseDigits(day_text);
        return parsedDate(
            day orelse return null,
            parseMonth(value[4..7]) orelse return null,
            parseDigits(value[20..24]) orelse return null,
            parseDigits(value[11..13]) orelse return null,
            parseDigits(value[14..16]) orelse return null,
            parseDigits(value[17..19]) orelse return null,
        );
    }
    return null;
}

fn parseDigits(value: []const u8) ?u64 {
    if (value.len == 0) return null;
    var result: u64 = 0;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
        result = result * 10 + byte - '0';
    }
    return result;
}

fn parseMonth(value: []const u8) ?u64 {
    const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    for (names, 1..) |name, month| if (std.mem.eql(u8, value, name)) return month;
    return null;
}

fn parseShortWeekday(value: []const u8) bool {
    const names = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
    for (names) |name| if (std.mem.eql(u8, value, name)) return true;
    return false;
}

fn parseLongWeekday(value: []const u8) bool {
    const names = [_][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };
    for (names) |name| if (std.mem.eql(u8, value, name)) return true;
    return false;
}

fn parsedDate(day: u64, month: u64, year: u64, hour: u64, minute: u64, second: u64) ?i64 {
    if (year > std.math.maxInt(std.time.epoch.Year) or month < 1 or month > 12 or day < 1 or
        hour > 23 or minute > 59 or second > 59) return null;
    const typed_year: std.time.epoch.Year = @intCast(year);
    const typed_month: std.time.epoch.Month = @enumFromInt(month);
    if (day > std.time.epoch.getDaysInMonth(typed_year, typed_month)) return null;
    var y: i64 = @intCast(year);
    const m: i64 = @intCast(month);
    const d: i64 = @intCast(day);
    y -= @intFromBool(m <= 2);
    const era = @divFloor(y, 400);
    const year_of_era = y - era * 400;
    const month_prime = m + (if (m > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * month_prime + 2, 5) + d - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    const days = era * 146097 + day_of_era - 719468;
    return days * std.time.epoch.secs_per_day + @as(i64, @intCast(hour * 3600 + minute * 60 + second));
}

fn finishDigest(allocator: std.mem.Allocator, hash: *Blake3) ![]const u8 {
    var raw: [Blake3.digest_length]u8 = undefined;
    hash.final(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    return std.fmt.allocPrint(allocator, "blake3:{s}", .{&hex});
}

test "remote ADD URL validation rejects unsupported transports and credentials" {
    try std.testing.expectError(error.UnsupportedRemoteAddUrl, validateUrl("http://example.com/file"));
    try std.testing.expectError(error.UnsupportedRemoteAddUrl, validateUrl("https://user:pass@example.com/file"));
    try std.testing.expectError(error.UnsupportedRemoteAddUrl, validateUrl("https://example.com/repo.git"));
    try std.testing.expectError(error.UnsupportedRemoteAddUrl, validateUrl("https://example.com/file#fragment"));
    _ = try validateUrl("https://example.com/releases/file.tar.gz?download=1");
}

test "remote ADD source name follows the original URL path" {
    const allocator = std.testing.allocator;
    const name = try sourceName(allocator, try validateUrl("https://example.com/releases/tool.gz?download=1"));
    defer allocator.free(name);
    try std.testing.expectEqualStrings("tool.gz", name);
    const fallback = try sourceName(allocator, try validateUrl("https://example.com/"));
    defer allocator.free(fallback);
    try std.testing.expectEqualStrings("download", fallback);
    const disposition = try responseSourceName(allocator, try validateUrl("https://example.com/tool"), "attachment; filename=release.bin");
    defer allocator.free(disposition);
    try std.testing.expectEqualStrings("release.bin", disposition);
    const quoted = try responseSourceName(allocator, try validateUrl("https://example.com/tool"), "attachment; filename=\"nested/asset \\\"one\\\".bin\"");
    defer allocator.free(quoted);
    try std.testing.expectEqualStrings("asset \"one\".bin", quoted);
}

test "remote ADD source name follows MIME extended filename semantics" {
    const allocator = std.testing.allocator;
    const requested = try validateUrl("https://example.com/fallback.bin");

    const extended = try responseSourceName(
        allocator,
        requested,
        "attachment; filename=plain.bin; filename*=UTF-8''%E2%82%AC.bin",
    );
    defer allocator.free(extended);
    try std.testing.expectEqualStrings("€.bin", extended);

    const continued = try responseSourceName(
        allocator,
        requested,
        "attachment; filename*0*=UTF-8''part%20; filename*1=two.bin",
    );
    defer allocator.free(continued);
    try std.testing.expectEqualStrings("part two.bin", continued);

    const malformed = try responseSourceName(
        allocator,
        requested,
        "attachment; filename=plain.bin; filename*=UTF-8''%GG",
    );
    defer allocator.free(malformed);
    try std.testing.expectEqualStrings("plain.bin", malformed);

    try std.testing.expectError(
        error.RemoteAddFilenameUnsupported,
        responseSourceName(allocator, requested, "attachment; filename*=UTF-8''unsafe%C2%85.bin"),
    );

    const max_name = try allocator.alloc(u8, max_filename_bytes);
    defer allocator.free(max_name);
    @memset(max_name, 'n');
    const accepted_max = try safeFileName(allocator, max_name);
    defer allocator.free(accepted_max);
    try std.testing.expectEqual(@as(usize, max_filename_bytes), accepted_max.len);
    const overlong = try allocator.alloc(u8, max_filename_bytes + 1);
    defer allocator.free(overlong);
    @memset(overlong, 'n');
    try std.testing.expectError(error.RemoteAddFilenameUnsupported, safeFileName(allocator, overlong));
}

test "remote ADD staging session scavenges abandoned files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const cache_root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cache_root);
    const dir_path = try std.fs.path.join(allocator, &.{ cache_root, staging_dir });
    defer allocator.free(dir_path);
    try Io.Dir.cwd().createDirPath(io, dir_path);
    const orphan_path = try std.fs.path.join(allocator, &.{ dir_path, "orphan.tmp" });
    defer allocator.free(orphan_path);
    var orphan = try Io.Dir.cwd().createFile(io, orphan_path, .{});
    orphan.close(io);

    const lock = try openStagingSession(io, allocator, cache_root);
    defer {
        lock.unlock(io);
        lock.close(io);
    }
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, orphan_path, .{}));
}

test "remote ADD parses every HTTP-date form used by BuildKit" {
    const expected: i64 = 784111777;
    try std.testing.expectEqual(expected, parseHttpDate("Sun, 06 Nov 1994 08:49:37 GMT").?);
    try std.testing.expectEqual(expected, parseHttpDate("Sunday, 06-Nov-94 08:49:37 GMT").?);
    try std.testing.expectEqual(expected, parseHttpDate("Sun Nov  6 08:49:37 1994").?);
    try std.testing.expectEqual(@as(i64, -31_536_000), parseHttpDate("Wednesday, 01-Jan-69 00:00:00 GMT").?);
    try std.testing.expect(parseHttpDate("Sun, 31 Feb 1994 08:49:37 GMT") == null);
    try std.testing.expect(parseHttpDate("xxx, 06 Nov 1994 08:49:37 GMT") == null);
    try std.testing.expect(parseHttpDate("Noday, 06-Nov-94 08:49:37 GMT") == null);
    try std.testing.expect(parseHttpDate("xxx Nov  6 08:49:37 1994") == null);
}

test "remote ADD redirects stay on HTTPS" {
    const allocator = std.testing.allocator;
    const relative = try resolveRedirectUrl(allocator, "https://example.com/a/start", "../file");
    defer allocator.free(relative);
    try std.testing.expectEqualStrings("https://example.com/file", relative);
    try std.testing.expectError(error.UnsupportedRemoteAddUrl, resolveRedirectUrl(allocator, "https://example.com/a", "http://example.com/file"));
}

test "remote ADD streaming enforces the response bound before publication" {
    var reader: Io.Reader = .fixed("payload");
    var output_buffer: [16]u8 = undefined;
    var writer: Io.Writer = .fixed(&output_buffer);
    var hash = Blake3.init(.{});
    try std.testing.expectError(error.RemoteAddBodyTooLarge, streamBodyLimited(&reader, &writer, &hash, 6));

    reader = .fixed("payload");
    writer = .fixed(&output_buffer);
    hash = Blake3.init(.{});
    try std.testing.expectEqual(@as(u64, 7), try streamBodyLimited(&reader, &writer, &hash, 7));
    try std.testing.expectEqualStrings("payload", writer.buffered());
}

fn fuzzRemoteAddScalars(_: void, smith: *std.testing.Smith) !void {
    var bytes: [2048]u8 = undefined;
    const len = smith.slice(&bytes);
    const input = bytes[0..len];
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    if (validateUrl(input)) |uri| {
        _ = sourceName(allocator, uri) catch {};
    } else |_| {}
    _ = parseHttpDate(input);
    _ = contentDispositionFilename(allocator, input) catch {};
    _ = resolveRedirectUrl(allocator, "https://example.com/base", input) catch {};
}

test "fuzz remote ADD URL redirect and response scalar parsing" {
    try std.testing.fuzz({}, fuzzRemoteAddScalars, .{});
}
