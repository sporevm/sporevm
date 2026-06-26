//! C ABI shim for libspore.

const std = @import("std");

const libspore = @import("libspore");

const result_success: c_int = 0;
const result_out_of_memory: c_int = -1;
const result_invalid_value: c_int = -2;
const result_error: c_int = -3;

const build_info_version_string: c_int = 1;
const build_info_abi_version: c_int = 2;
const c_abi_version: u32 = 1;
const inspect_bundle_options_version: u32 = 1;

const SporeString = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,
};

const SporeOwnedString = extern struct {
    ptr: ?[*]u8 = null,
    len: usize = 0,
};

const SporeInspectBundleOptions = extern struct {
    size: u32,
    version: u32,
    source: SporeString,
    child_id: SporeString,
    has_child_range: u8,
    child_range_start: u32,
    child_range_end: u32,
};

const SporeContextImpl = struct {
    allocator: std.mem.Allocator,
    env: std.process.Environ.Map,
    last_error: []u8 = &.{},

    fn productContext(self: *SporeContextImpl) libspore.Context {
        return .{
            .io = std.Io.failing,
            .environ_map = &self.env,
        };
    }

    fn clearLastError(self: *SporeContextImpl) void {
        if (self.last_error.len != 0) self.allocator.free(self.last_error);
        self.last_error = &.{};
    }

    fn setLastError(self: *SporeContextImpl, message: []const u8) void {
        self.clearLastError();
        self.last_error = self.allocator.dupe(u8, message) catch &.{};
    }
};

pub export fn spore_inspect_bundle_options_init(options: ?*SporeInspectBundleOptions) void {
    const out = options orelse return;
    out.* = .{
        .size = @sizeOf(SporeInspectBundleOptions),
        .version = inspect_bundle_options_version,
        .source = .{},
        .child_id = .{},
        .has_child_range = 0,
        .child_range_start = 0,
        .child_range_end = 0,
    };
}

pub export fn spore_build_info(field: c_int, out: ?*anyopaque) c_int {
    const raw_out = out orelse return result_invalid_value;
    switch (field) {
        build_info_version_string => {
            const typed: *SporeString = @ptrCast(@alignCast(raw_out));
            typed.* = borrowString(libspore.version);
            return result_success;
        },
        build_info_abi_version => {
            const typed: *u32 = @ptrCast(@alignCast(raw_out));
            typed.* = c_abi_version;
            return result_success;
        },
        else => return result_invalid_value,
    }
}

pub export fn spore_context_new(out_context: ?*?*SporeContextImpl) c_int {
    const out = out_context orelse return result_invalid_value;
    out.* = null;

    const allocator = std.heap.c_allocator;
    const context = allocator.create(SporeContextImpl) catch return result_out_of_memory;
    context.* = .{
        .allocator = allocator,
        .env = std.process.Environ.Map.init(allocator),
    };
    out.* = context;
    return result_success;
}

pub export fn spore_context_free(context: ?*SporeContextImpl) void {
    const ctx = context orelse return;
    const allocator = ctx.allocator;
    ctx.clearLastError();
    ctx.env.deinit();
    allocator.destroy(ctx);
}

pub export fn spore_context_last_error(context: ?*SporeContextImpl) SporeString {
    const ctx = context orelse return .{};
    return borrowString(ctx.last_error);
}

pub export fn spore_free_string(context: ?*SporeContextImpl, string: SporeOwnedString) void {
    const ctx = context orelse return;
    const ptr = string.ptr orelse return;
    ctx.allocator.free(ptr[0 .. string.len + 1]);
}

pub export fn spore_host_info_json(context: ?*SporeContextImpl, out_json: ?*SporeOwnedString) c_int {
    const ctx = context orelse return result_invalid_value;
    const out = out_json orelse return fail(ctx, error.InvalidValue);
    out.* = .{};
    ctx.clearLastError();

    const info = libspore.hostInfo(ctx.productContext(), ctx.allocator) catch |err| return fail(ctx, err);
    defer libspore.deinitHostInfo(ctx.allocator, info);

    out.* = jsonOwned(ctx, info) catch |err| return fail(ctx, err);
    return result_success;
}

pub export fn spore_inspect_bundle_json(
    context: ?*SporeContextImpl,
    options: ?*const SporeInspectBundleOptions,
    out_json: ?*SporeOwnedString,
) c_int {
    const ctx = context orelse return result_invalid_value;
    const opts = options orelse return fail(ctx, error.InvalidValue);
    const out = out_json orelse return fail(ctx, error.InvalidValue);
    out.* = .{};
    ctx.clearLastError();

    if (opts.version != inspect_bundle_options_version or opts.size < @sizeOf(SporeInspectBundleOptions)) {
        return fail(ctx, error.InvalidValue);
    }

    const source = toSlice(opts.source) catch |err| return fail(ctx, err);
    const child_id = optionalSlice(opts.child_id) catch |err| return fail(ctx, err);
    const child_range: ?libspore.ChildRange = if (opts.has_child_range != 0) .{
        .start = opts.child_range_start,
        .end = opts.child_range_end,
    } else null;

    const result = libspore.inspectBundle(ctx.allocator, .{
        .source = source,
        .child_id = child_id,
        .child_range = child_range,
    }) catch |err| return fail(ctx, err);
    defer libspore.deinitInspectBundleResult(ctx.allocator, result);

    out.* = jsonOwned(ctx, result) catch |err| return fail(ctx, err);
    return result_success;
}

fn borrowString(value: []const u8) SporeString {
    return .{
        .ptr = if (value.len == 0) null else value.ptr,
        .len = value.len,
    };
}

fn toSlice(value: SporeString) ![]const u8 {
    if (value.len == 0) return "";
    const ptr = value.ptr orelse return error.InvalidValue;
    return ptr[0..value.len];
}

fn optionalSlice(value: SporeString) !?[]const u8 {
    if (value.len == 0) return null;
    return try toSlice(value);
}

fn jsonOwned(ctx: *SporeContextImpl, value: anytype) !SporeOwnedString {
    const json = try std.json.Stringify.valueAlloc(ctx.allocator, value, .{ .whitespace = .indent_2 });
    defer ctx.allocator.free(json);

    const len = json.len + 1;
    const out = try ctx.allocator.alloc(u8, len + 1);
    @memcpy(out[0..json.len], json);
    out[json.len] = '\n';
    out[len] = 0;
    return .{ .ptr = out.ptr, .len = len };
}

fn fail(ctx: *SporeContextImpl, err: anyerror) c_int {
    ctx.setLastError(@errorName(err));
    return switch (err) {
        error.OutOfMemory => result_out_of_memory,
        error.InvalidValue => result_invalid_value,
        else => result_error,
    };
}

test "build info exposes version" {
    var version: SporeString = .{};
    try std.testing.expectEqual(result_success, spore_build_info(build_info_version_string, &version));
    try std.testing.expectEqualStrings(libspore.version, version.ptr.?[0..version.len]);
}

test "inspect bundle options initialize size and version" {
    var options: SporeInspectBundleOptions = undefined;
    spore_inspect_bundle_options_init(&options);
    try std.testing.expectEqual(@as(u32, @intCast(@sizeOf(SporeInspectBundleOptions))), options.size);
    try std.testing.expectEqual(inspect_bundle_options_version, options.version);
}
