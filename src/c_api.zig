//! C ABI shim for libspore.

const std = @import("std");
const builtin = @import("builtin");

const spore_internal = @import("spore_internal");
const libspore = spore_internal.api;

const result_success: c_int = 0;
const result_out_of_memory: c_int = -1;
const result_invalid_value: c_int = -2;
const result_error: c_int = -3;

const build_info_version_string: c_int = 1;
const build_info_abi_version: c_int = 2;
const c_abi_version: u32 = 15;
const reexec_contract_version: u32 = 1;
const reexec_role_env = "SPORE_REEXEC_ROLE";
const reexec_contract_env = "SPORE_REEXEC_CONTRACT";
const inspect_bundle_options_version: u32 = 1;
const inspect_spore_options_version: u32 = 1;
const pull_options_version: u32 = 1;
const system_df_options_version: u32 = 1;
const system_prune_options_version: u32 = 1;
const create_named_options_version: u32 = 4;
const restore_named_options_version: u32 = 1;
const fork_named_options_version: u32 = 1;
const exec_named_options_version: u32 = 2;
const exec_named_stream_options_version: u32 = 1;
const copy_named_options_version: u32 = 1;
const save_named_options_version: u32 = 1;
const remove_named_options_version: u32 = 1;
const remove_saved_options_version: u32 = 1;

const stream_event_stdout: c_int = 1;
const stream_event_stderr: c_int = 2;
const stream_event_terminal: c_int = 3;
const stream_event_exit: c_int = 4;
const stream_event_error: c_int = 5;

const ReexecOptions = struct {
    cleanup_fds: bool = true,
    unset_env: bool = true,
    discard_stdout: bool = false,
};

const ReexecRole = enum {
    monitor,
    netd,
};

const posix_env = if (builtin.os.tag == .windows) struct {} else struct {
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

const SporeString = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,
};

const SporeOwnedString = extern struct {
    ptr: ?[*]u8 = null,
    len: usize = 0,
};

const SporeNetworkRule = extern struct {
    host: SporeString,
    ports: ?[*]const u16,
    port_count: usize,
};

const SporeBoundUnixService = extern struct {
    name: SporeString,
    guest_host: SporeString,
    guest_port: u16,
    unix_path: SporeString,
};

const SporeBoundUnixServiceBinding = extern struct {
    name: SporeString,
    unix_path: SporeString,
};

const SporeAnnotation = extern struct {
    key: SporeString,
    value: SporeString,
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

const SporeInspectSporeOptions = extern struct {
    size: u32,
    version: u32,
    spore_dir: SporeString,
};

const cache_root_env: u32 = 0;
const cache_root_none: u32 = 1;
const cache_root_path: u32 = 2;

const SporeCacheRoot = extern struct {
    kind: u32,
    path: SporeString,
};

const SporePullOptions = extern struct {
    size: u32,
    version: u32,
    source: SporeString,
    out_dir: SporeString,
    rootfs_cache: SporeCacheRoot,
    bundle_cache: SporeCacheRoot,
    child_id: SporeString,
    allow_metadata_only_rootfs: u8,
    aws_region: SporeString,
    aws_executable: SporeString,
};

const SporeSystemDfOptions = extern struct {
    size: u32,
    version: u32,
    rootfs_cache: SporeString,
};

const SporeSystemPruneOptions = extern struct {
    size: u32,
    version: u32,
    rootfs_cache: SporeString,
    dry_run: u8,
    include_digest_artifacts: u8,
    has_older_than_seconds: u8,
    older_than_seconds: u64,
    has_max_bytes: u8,
    max_bytes: u64,
    rootfs_only: u8,
};

const SporeCreateNamedOptions = extern struct {
    size: u32,
    version: u32,
    name: SporeString,
    backend: SporeString,
    kernel_path: SporeString,
    initrd_path: SporeString,
    rootfs_path: SporeString,
    image_ref: SporeString,
    spore_executable: SporeString,
    memory_bytes: u64,
    vcpus: u32,
    guest_port: u32,
    timeout_ms: u64,
    console_log_path: SporeString,
    network_enabled: u8,
    allow_cidrs: ?[*]const SporeString,
    allow_cidr_count: usize,
    allow_hosts: ?[*]const SporeString,
    allow_host_count: usize,
    network_rules: ?[*]const SporeNetworkRule,
    network_rule_count: usize,
    bound_unix_services: ?[*]const SporeBoundUnixService,
    bound_unix_service_count: usize,
    annotations: ?[*]const SporeAnnotation,
    annotation_count: usize,
};

const SporeExecNamedOptions = extern struct {
    size: u32,
    version: u32,
    name: SporeString,
    argv: ?[*]const SporeString,
    argc: usize,
    has_network_policy: u8,
    network_rules: ?[*]const SporeNetworkRule,
    network_rule_count: usize,
};

const SporeExecNamedStreamOptions = extern struct {
    size: u32,
    version: u32,
    name: SporeString,
    argv: ?[*]const SporeString,
    argc: usize,
    interactive: u8,
    tty: u8,
    terminal_name: SporeString,
    terminal_rows: u16,
    terminal_cols: u16,
};

const SporeExecNamedStreamEvent = extern struct {
    type: c_int,
    bytes: SporeString,
    exit_code: u8,
};

const SporeCopyNamedOptions = extern struct {
    size: u32,
    version: u32,
    name: SporeString,
    host_path: SporeString,
    guest_path: SporeString,
};

const SporeRestoreNamedOptions = extern struct {
    size: u32,
    version: u32,
    spore_dir: SporeString,
    name: SporeString,
    spore_executable: SporeString,
    bound_unix_services: ?[*]const SporeBoundUnixServiceBinding,
    bound_unix_service_count: usize,
};

const SporeForkNamedOptions = extern struct {
    size: u32,
    version: u32,
    source_name: SporeString,
    count: usize,
    name_pattern: SporeString,
    spore_executable: SporeString,
};

const SporeSaveNamedOptions = extern struct {
    size: u32,
    version: u32,
    name: SporeString,
    out_dir: SporeString,
    stop: u8,
    annotations: ?[*]const SporeAnnotation,
    annotation_count: usize,
};

const SporeRemoveNamedOptions = extern struct {
    size: u32,
    version: u32,
    name: SporeString,
};

const SporeRemoveSavedOptions = extern struct {
    size: u32,
    version: u32,
    spore_dir: SporeString,
};

const SporeExecNamedStreamImpl = struct {
    stream: libspore.ExecNamedStream,
};

const SporeContextImpl = struct {
    allocator: std.mem.Allocator,
    env: std.process.Environ.Map,
    threaded: std.Io.Threaded,
    last_error: []u8 = &.{},

    fn productContext(self: *SporeContextImpl) libspore.Context {
        return .{
            .io = self.io(),
            .environ_map = &self.env,
        };
    }

    fn io(self: *SporeContextImpl) std.Io {
        return self.threaded.io();
    }

    fn clearLastError(self: *SporeContextImpl) void {
        if (self.last_error.len != 0) self.allocator.free(self.last_error);
        self.last_error = &.{};
        libspore.clearLastLifecycleError();
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

pub export fn spore_inspect_spore_options_init(options: ?*SporeInspectSporeOptions) void {
    const out = options orelse return;
    out.* = .{
        .size = @sizeOf(SporeInspectSporeOptions),
        .version = inspect_spore_options_version,
        .spore_dir = .{},
    };
}

pub export fn spore_pull_options_init(options: ?*SporePullOptions) void {
    const out = options orelse return;
    out.* = .{
        .size = @sizeOf(SporePullOptions),
        .version = pull_options_version,
        .source = .{},
        .out_dir = .{},
        .rootfs_cache = .{ .kind = cache_root_env, .path = .{} },
        .bundle_cache = .{ .kind = cache_root_env, .path = .{} },
        .child_id = .{},
        .allow_metadata_only_rootfs = 0,
        .aws_region = .{},
        .aws_executable = .{},
    };
}

pub export fn spore_system_df_options_init(options: ?*SporeSystemDfOptions) void {
    const out = options orelse return;
    out.* = .{
        .size = @sizeOf(SporeSystemDfOptions),
        .version = system_df_options_version,
        .rootfs_cache = .{},
    };
}

pub export fn spore_system_prune_options_init(options: ?*SporeSystemPruneOptions) void {
    const out = options orelse return;
    out.* = .{
        .size = @sizeOf(SporeSystemPruneOptions),
        .version = system_prune_options_version,
        .rootfs_cache = .{},
        .dry_run = 1,
        .include_digest_artifacts = 0,
        .has_older_than_seconds = 0,
        .older_than_seconds = 0,
        .has_max_bytes = 0,
        .max_bytes = 0,
        .rootfs_only = 0,
    };
}

pub export fn spore_create_named_options_init(options: ?*SporeCreateNamedOptions) void {
    const out = options orelse return;
    out.* = .{
        .size = @sizeOf(SporeCreateNamedOptions),
        .version = create_named_options_version,
        .name = .{},
        .backend = .{},
        .kernel_path = .{},
        .initrd_path = .{},
        .rootfs_path = .{},
        .image_ref = .{},
        .spore_executable = .{},
        .memory_bytes = 0,
        .vcpus = 1,
        .guest_port = 10700,
        .timeout_ms = 30_000,
        .console_log_path = .{},
        .network_enabled = 0,
        .allow_cidrs = null,
        .allow_cidr_count = 0,
        .allow_hosts = null,
        .allow_host_count = 0,
        .network_rules = null,
        .network_rule_count = 0,
        .bound_unix_services = null,
        .bound_unix_service_count = 0,
        .annotations = null,
        .annotation_count = 0,
    };
}

pub export fn spore_exec_named_options_init(options: ?*SporeExecNamedOptions) void {
    const out = options orelse return;
    out.* = .{
        .size = @sizeOf(SporeExecNamedOptions),
        .version = exec_named_options_version,
        .name = .{},
        .argv = null,
        .argc = 0,
        .has_network_policy = 0,
        .network_rules = null,
        .network_rule_count = 0,
    };
}

pub export fn spore_exec_named_stream_options_init(options: ?*SporeExecNamedStreamOptions) void {
    const out = options orelse return;
    out.* = .{
        .size = @sizeOf(SporeExecNamedStreamOptions),
        .version = exec_named_stream_options_version,
        .name = .{},
        .argv = null,
        .argc = 0,
        .interactive = 0,
        .tty = 0,
        .terminal_name = .{},
        .terminal_rows = 24,
        .terminal_cols = 80,
    };
}

pub export fn spore_copy_named_options_init(options: ?*SporeCopyNamedOptions) void {
    const out = options orelse return;
    out.* = .{
        .size = @sizeOf(SporeCopyNamedOptions),
        .version = copy_named_options_version,
        .name = .{},
        .host_path = .{},
        .guest_path = .{},
    };
}

pub export fn spore_restore_named_options_init(options: ?*SporeRestoreNamedOptions) void {
    const out = options orelse return;
    out.* = .{
        .size = @sizeOf(SporeRestoreNamedOptions),
        .version = restore_named_options_version,
        .spore_dir = .{},
        .name = .{},
        .spore_executable = .{},
        .bound_unix_services = null,
        .bound_unix_service_count = 0,
    };
}

pub export fn spore_fork_named_options_init(options: ?*SporeForkNamedOptions) void {
    const out = options orelse return;
    out.* = .{
        .size = @sizeOf(SporeForkNamedOptions),
        .version = fork_named_options_version,
        .source_name = .{},
        .count = 0,
        .name_pattern = .{},
        .spore_executable = .{},
    };
}

pub export fn spore_save_named_options_init(options: ?*SporeSaveNamedOptions) void {
    const out = options orelse return;
    out.* = .{
        .size = @sizeOf(SporeSaveNamedOptions),
        .version = save_named_options_version,
        .name = .{},
        .out_dir = .{},
        .stop = 0,
        .annotations = null,
        .annotation_count = 0,
    };
}

pub export fn spore_remove_named_options_init(options: ?*SporeRemoveNamedOptions) void {
    const out = options orelse return;
    out.* = .{
        .size = @sizeOf(SporeRemoveNamedOptions),
        .version = remove_named_options_version,
        .name = .{},
    };
}

pub export fn spore_remove_saved_options_init(options: ?*SporeRemoveSavedOptions) void {
    if (options) |out| out.* = .{ .size = @sizeOf(SporeRemoveSavedOptions), .version = remove_saved_options_version, .spore_dir = .{} };
}

pub export fn spore_build_info(field: c_int, out: ?*anyopaque) c_int {
    const raw_out = out orelse return result_invalid_value;
    switch (field) {
        build_info_version_string => {
            const typed: *SporeString = @ptrCast(@alignCast(raw_out));
            typed.* = borrowString(spore_internal.version);
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

pub export fn spore_reexec_main(
    argc: c_int,
    raw_argv: ?[*]const ?[*:0]const u8,
    out_exit_code: ?*c_int,
) c_int {
    const out = out_exit_code orelse return result_invalid_value;
    out.* = 1;

    const role = getenvSlice(reexec_role_env) orelse return result_invalid_value;
    const contract = getenvSlice(reexec_contract_env) orelse return result_invalid_value;
    const argv = cArgvToSlices(std.heap.c_allocator, argc, raw_argv) catch |err| return resultFromError(err);
    defer std.heap.c_allocator.free(argv);

    out.* = runReexecRole(std.heap.c_allocator, role, contract, argv, .{}) catch |err| return resultFromError(err);
    return result_success;
}

pub export fn spore_context_new(out_context: ?*?*SporeContextImpl) c_int {
    const out = out_context orelse return result_invalid_value;
    out.* = null;

    const allocator = std.heap.c_allocator;
    const context = allocator.create(SporeContextImpl) catch return result_out_of_memory;
    context.* = .{
        .allocator = allocator,
        .env = std.process.Environ.Map.init(allocator),
        .threaded = std.Io.Threaded.init(allocator, .{}),
    };
    out.* = context;
    return result_success;
}

pub export fn spore_context_free(context: ?*SporeContextImpl) void {
    const ctx = context orelse return;
    const allocator = ctx.allocator;
    ctx.clearLastError();
    ctx.threaded.deinit();
    ctx.env.deinit();
    allocator.destroy(ctx);
}

pub export fn spore_context_last_error(context: ?*SporeContextImpl) SporeString {
    const ctx = context orelse return .{};
    return borrowString(ctx.last_error);
}

pub export fn spore_context_set_env(context: ?*SporeContextImpl, name: SporeString, value: SporeString) c_int {
    const ctx = context orelse return result_invalid_value;
    ctx.clearLastError();
    const name_slice = toSlice(name) catch |err| return fail(ctx, err);
    const value_slice = toSlice(value) catch |err| return fail(ctx, err);
    if (name_slice.len == 0) return fail(ctx, error.InvalidValue);
    ctx.env.put(name_slice, value_slice) catch |err| return fail(ctx, err);
    return result_success;
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

pub export fn spore_network_capabilities_json(context: ?*SporeContextImpl, out_json: ?*SporeOwnedString) c_int {
    const ctx = context orelse return result_invalid_value;
    const out = out_json orelse return fail(ctx, error.InvalidValue);
    out.* = .{};
    ctx.clearLastError();

    out.* = jsonOwned(ctx, libspore.networkCapabilities()) catch |err| return fail(ctx, err);
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

pub export fn spore_inspect_spore_json(
    context: ?*SporeContextImpl,
    options: ?*const SporeInspectSporeOptions,
    out_json: ?*SporeOwnedString,
) c_int {
    const ctx = context orelse return result_invalid_value;
    const opts = options orelse return fail(ctx, error.InvalidValue);
    const out = out_json orelse return fail(ctx, error.InvalidValue);
    out.* = .{};
    ctx.clearLastError();

    if (opts.version != inspect_spore_options_version or opts.size < @sizeOf(SporeInspectSporeOptions)) {
        return fail(ctx, error.InvalidValue);
    }

    const spore_dir = toSlice(opts.spore_dir) catch |err| return fail(ctx, err);
    if (spore_dir.len == 0) return fail(ctx, error.InvalidValue);

    const result = libspore.inspectSpore(ctx.allocator, spore_dir) catch |err| return fail(ctx, err);
    defer libspore.deinitSporeInspectResult(ctx.allocator, result);

    out.* = jsonOwned(ctx, result) catch |err| return fail(ctx, err);
    return result_success;
}

pub export fn spore_pull_json(
    context: ?*SporeContextImpl,
    options: ?*const SporePullOptions,
    out_json: ?*SporeOwnedString,
) c_int {
    const ctx = context orelse return result_invalid_value;
    const opts = options orelse return fail(ctx, error.InvalidValue);
    const out = out_json orelse return fail(ctx, error.InvalidValue);
    out.* = .{};
    ctx.clearLastError();

    if (opts.version != pull_options_version or opts.size < @sizeOf(SporePullOptions)) {
        return fail(ctx, error.InvalidValue);
    }

    const source = toSlice(opts.source) catch |err| return fail(ctx, err);
    const out_dir = toSlice(opts.out_dir) catch |err| return fail(ctx, err);
    if (source.len == 0 or out_dir.len == 0) return fail(ctx, error.InvalidValue);

    const result = libspore.pull(ctx.productContext(), ctx.allocator, .{
        .source = source,
        .out_dir = out_dir,
        .rootfs_cache = parseCacheRoot(opts.rootfs_cache) catch |err| return fail(ctx, err),
        .bundle_cache = parseCacheRoot(opts.bundle_cache) catch |err| return fail(ctx, err),
        .child_id = optionalSlice(opts.child_id) catch |err| return fail(ctx, err),
        .allow_metadata_only_rootfs = opts.allow_metadata_only_rootfs != 0,
        .aws_region = optionalSlice(opts.aws_region) catch |err| return fail(ctx, err),
        .aws_executable = (optionalSlice(opts.aws_executable) catch |err| return fail(ctx, err)) orelse "aws",
    }) catch |err| return fail(ctx, err);
    defer libspore.deinitPullResult(ctx.allocator, result);

    out.* = jsonOwned(ctx, result) catch |err| return fail(ctx, err);
    return result_success;
}

pub export fn spore_system_df_json(
    context: ?*SporeContextImpl,
    options: ?*const SporeSystemDfOptions,
    out_json: ?*SporeOwnedString,
) c_int {
    const ctx = context orelse return result_invalid_value;
    const opts = options orelse return fail(ctx, error.InvalidValue);
    const out = out_json orelse return fail(ctx, error.InvalidValue);
    out.* = .{};
    ctx.clearLastError();
    if (opts.version != system_df_options_version or opts.size < @sizeOf(SporeSystemDfOptions)) {
        return fail(ctx, error.InvalidValue);
    }

    const result = libspore.systemDf(ctx.productContext(), ctx.allocator, .{
        .rootfs_cache = cacheRootFromPath(optionalSlice(opts.rootfs_cache) catch |err| return fail(ctx, err)),
    }) catch |err| return fail(ctx, err);
    defer libspore.deinitRootfsSystemSummary(ctx.allocator, result);

    out.* = jsonOwned(ctx, result) catch |err| return fail(ctx, err);
    return result_success;
}

pub export fn spore_system_prune_json(
    context: ?*SporeContextImpl,
    options: ?*const SporeSystemPruneOptions,
    out_json: ?*SporeOwnedString,
) c_int {
    const ctx = context orelse return result_invalid_value;
    const opts = options orelse return fail(ctx, error.InvalidValue);
    const out = out_json orelse return fail(ctx, error.InvalidValue);
    out.* = .{};
    ctx.clearLastError();
    if (opts.version != system_prune_options_version or opts.size < @sizeOf(SporeSystemPruneOptions)) {
        return fail(ctx, error.InvalidValue);
    }

    const result = libspore.systemPrune(ctx.productContext(), ctx.allocator, .{
        .rootfs_cache = cacheRootFromPath(optionalSlice(opts.rootfs_cache) catch |err| return fail(ctx, err)),
        .dry_run = opts.dry_run != 0,
        .include_digest_artifacts = opts.include_digest_artifacts != 0,
        .older_than_seconds = if (opts.has_older_than_seconds != 0) opts.older_than_seconds else null,
        .max_bytes = if (opts.has_max_bytes != 0) opts.max_bytes else null,
        .rootfs_only = opts.rootfs_only != 0,
    }) catch |err| return fail(ctx, err);
    defer libspore.deinitRootfsPruneResult(ctx.allocator, result);

    out.* = jsonOwned(ctx, result) catch |err| return fail(ctx, err);
    return result_success;
}

pub export fn spore_create_named_json(
    context: ?*SporeContextImpl,
    options: ?*const SporeCreateNamedOptions,
    out_json: ?*SporeOwnedString,
) c_int {
    const ctx = context orelse return result_invalid_value;
    const opts = options orelse return fail(ctx, error.InvalidValue);
    const out = out_json orelse return fail(ctx, error.InvalidValue);
    out.* = .{};
    ctx.clearLastError();
    if (opts.version != create_named_options_version or opts.size < @sizeOf(SporeCreateNamedOptions)) {
        return fail(ctx, error.InvalidValue);
    }

    var process_arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer process_arena.deinit();
    const arena = process_arena.allocator();
    const init = cInit(ctx, &process_arena);
    const allow_cidrs = parseStringList(arena, opts.allow_cidrs, opts.allow_cidr_count) catch |err| return fail(ctx, err);
    const allow_hosts = parseStringList(arena, opts.allow_hosts, opts.allow_host_count) catch |err| return fail(ctx, err);
    const network_policy = parseNetworkPolicy(arena, opts.network_rules, opts.network_rule_count) catch |err| return fail(ctx, err);
    const bound_services = parseBoundUnixServices(arena, opts.bound_unix_services, opts.bound_unix_service_count) catch |err| return fail(ctx, err);
    const annotations = parseAnnotations(arena, opts.annotations, opts.annotation_count) catch |err| return fail(ctx, err);
    const result = libspore.createNamed(init, ctx.allocator, .{
        .name = toSlice(opts.name) catch |err| return fail(ctx, err),
        .backend = parseBackend(optionalSlice(opts.backend) catch |err| return fail(ctx, err)) catch |err| return fail(ctx, err),
        .kernel_path = optionalSlice(opts.kernel_path) catch |err| return fail(ctx, err),
        .initrd_path = optionalSlice(opts.initrd_path) catch |err| return fail(ctx, err),
        .rootfs_path = optionalSlice(opts.rootfs_path) catch |err| return fail(ctx, err),
        .image_ref = optionalSlice(opts.image_ref) catch |err| return fail(ctx, err),
        .network = .{
            .enabled = opts.network_enabled != 0,
            .allow_cidrs = allow_cidrs,
            .allow_hosts = allow_hosts,
            .policy = network_policy,
            .bound_services = bound_services,
        },
        .memory = memoryFromBytes(opts.memory_bytes) catch |err| return fail(ctx, err),
        .vcpus = opts.vcpus,
        .guest_port = opts.guest_port,
        .timeout_ms = opts.timeout_ms,
        .console_log_path = optionalSlice(opts.console_log_path) catch |err| return fail(ctx, err),
        .spore_executable = (optionalSlice(opts.spore_executable) catch |err| return fail(ctx, err)) orelse "spore",
        .annotations = annotations,
    }) catch |err| return fail(ctx, err);
    defer libspore.deinitNamedLifecycleResult(ctx.allocator, result);

    out.* = jsonOwned(ctx, result) catch |err| return fail(ctx, err);
    return result_success;
}

pub export fn spore_exec_named_json(
    context: ?*SporeContextImpl,
    options: ?*const SporeExecNamedOptions,
    out_json: ?*SporeOwnedString,
) c_int {
    const ctx = context orelse return result_invalid_value;
    const opts = options orelse return fail(ctx, error.InvalidValue);
    const out = out_json orelse return fail(ctx, error.InvalidValue);
    out.* = .{};
    ctx.clearLastError();
    if (opts.version != exec_named_options_version or opts.size < @sizeOf(SporeExecNamedOptions)) {
        return fail(ctx, error.InvalidValue);
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = parseArgv(arena, opts.argv, opts.argc) catch |err| return fail(ctx, err);
    const network_policy: ?libspore.NetworkPolicy = if (opts.has_network_policy != 0)
        parseNetworkPolicy(arena, opts.network_rules, opts.network_rule_count) catch |err| return fail(ctx, err)
    else
        null;
    const result = libspore.execNamed(ctx.productContext(), ctx.allocator, .{
        .name = toSlice(opts.name) catch |err| return fail(ctx, err),
        .command = argv,
        .network_policy = network_policy,
    }) catch |err| return fail(ctx, err);
    defer libspore.deinitExecNamedResult(ctx.allocator, result);

    out.* = jsonOwned(ctx, result) catch |err| return fail(ctx, err);
    return result_success;
}

pub export fn spore_exec_named_stream_open(
    context: ?*SporeContextImpl,
    options: ?*const SporeExecNamedStreamOptions,
    out_stream: ?*?*SporeExecNamedStreamImpl,
) c_int {
    const ctx = context orelse return result_invalid_value;
    const opts = options orelse return fail(ctx, error.InvalidValue);
    const out = out_stream orelse return fail(ctx, error.InvalidValue);
    out.* = null;
    ctx.clearLastError();
    if (opts.version != exec_named_stream_options_version or opts.size < @sizeOf(SporeExecNamedStreamOptions)) {
        return fail(ctx, error.InvalidValue);
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = parseArgv(arena, opts.argv, opts.argc) catch |err| return fail(ctx, err);
    const stream = libspore.openExecNamedStream(ctx.productContext(), ctx.allocator, .{
        .name = toSlice(opts.name) catch |err| return fail(ctx, err),
        .command = argv,
        .interactive = opts.interactive != 0,
        .tty = opts.tty != 0,
        .terminal_name = (optionalSlice(opts.terminal_name) catch |err| return fail(ctx, err)) orelse "xterm",
        .terminal_size = .{
            .rows = if (opts.terminal_rows == 0) 24 else opts.terminal_rows,
            .cols = if (opts.terminal_cols == 0) 80 else opts.terminal_cols,
        },
    }) catch |err| return fail(ctx, err);
    errdefer {
        var cleanup = stream;
        cleanup.deinit();
    }
    const handle = ctx.allocator.create(SporeExecNamedStreamImpl) catch |err| return fail(ctx, err);
    handle.* = .{ .stream = stream };
    out.* = handle;
    return result_success;
}

pub export fn spore_exec_named_stream_next(
    context: ?*SporeContextImpl,
    stream: ?*SporeExecNamedStreamImpl,
    out_event: ?*SporeExecNamedStreamEvent,
) c_int {
    const ctx = context orelse return result_invalid_value;
    const handle = stream orelse return fail(ctx, error.InvalidValue);
    const out = out_event orelse return fail(ctx, error.InvalidValue);
    out.* = .{ .type = 0, .bytes = .{}, .exit_code = 0 };
    ctx.clearLastError();

    const event = handle.stream.next() catch |err| return fail(ctx, err);
    switch (event) {
        .stdout => |bytes| out.* = .{ .type = stream_event_stdout, .bytes = borrowString(bytes), .exit_code = 0 },
        .stderr => |bytes| out.* = .{ .type = stream_event_stderr, .bytes = borrowString(bytes), .exit_code = 0 },
        .terminal => |bytes| out.* = .{ .type = stream_event_terminal, .bytes = borrowString(bytes), .exit_code = 0 },
        .exit => |code| out.* = .{ .type = stream_event_exit, .bytes = .{}, .exit_code = code },
        .err => |bytes| out.* = .{ .type = stream_event_error, .bytes = borrowString(bytes), .exit_code = 0 },
    }
    return result_success;
}

pub export fn spore_exec_named_stream_write_stdin(
    context: ?*SporeContextImpl,
    stream: ?*SporeExecNamedStreamImpl,
    bytes: SporeString,
) c_int {
    const ctx = context orelse return result_invalid_value;
    const handle = stream orelse return fail(ctx, error.InvalidValue);
    ctx.clearLastError();
    handle.stream.writeStdin(toSlice(bytes) catch |err| return fail(ctx, err)) catch |err| return fail(ctx, err);
    return result_success;
}

pub export fn spore_exec_named_stream_write_terminal(
    context: ?*SporeContextImpl,
    stream: ?*SporeExecNamedStreamImpl,
    bytes: SporeString,
) c_int {
    const ctx = context orelse return result_invalid_value;
    const handle = stream orelse return fail(ctx, error.InvalidValue);
    ctx.clearLastError();
    handle.stream.writeTerminal(toSlice(bytes) catch |err| return fail(ctx, err)) catch |err| return fail(ctx, err);
    return result_success;
}

pub export fn spore_exec_named_stream_close_stdin(
    context: ?*SporeContextImpl,
    stream: ?*SporeExecNamedStreamImpl,
) c_int {
    const ctx = context orelse return result_invalid_value;
    const handle = stream orelse return fail(ctx, error.InvalidValue);
    ctx.clearLastError();
    handle.stream.closeStdin() catch |err| return fail(ctx, err);
    return result_success;
}

pub export fn spore_exec_named_stream_close_terminal(
    context: ?*SporeContextImpl,
    stream: ?*SporeExecNamedStreamImpl,
) c_int {
    const ctx = context orelse return result_invalid_value;
    const handle = stream orelse return fail(ctx, error.InvalidValue);
    ctx.clearLastError();
    handle.stream.closeTerminal() catch |err| return fail(ctx, err);
    return result_success;
}

pub export fn spore_exec_named_stream_resize_terminal(
    context: ?*SporeContextImpl,
    stream: ?*SporeExecNamedStreamImpl,
    rows: u16,
    cols: u16,
) c_int {
    const ctx = context orelse return result_invalid_value;
    const handle = stream orelse return fail(ctx, error.InvalidValue);
    ctx.clearLastError();
    handle.stream.resizeTerminal(.{
        .rows = if (rows == 0) 24 else rows,
        .cols = if (cols == 0) 80 else cols,
    }) catch |err| return fail(ctx, err);
    return result_success;
}

pub export fn spore_exec_named_stream_free(
    context: ?*SporeContextImpl,
    stream: ?*SporeExecNamedStreamImpl,
) void {
    const ctx = context orelse return;
    const handle = stream orelse return;
    handle.stream.deinit();
    ctx.allocator.destroy(handle);
}

pub export fn spore_copy_in_named(
    context: ?*SporeContextImpl,
    options: ?*const SporeCopyNamedOptions,
) c_int {
    const ctx = context orelse return result_invalid_value;
    const opts = options orelse return fail(ctx, error.InvalidValue);
    ctx.clearLastError();
    if (opts.version != copy_named_options_version or opts.size < @sizeOf(SporeCopyNamedOptions)) {
        return fail(ctx, error.InvalidValue);
    }

    libspore.copyInNamed(ctx.productContext(), ctx.allocator, .{
        .name = toSlice(opts.name) catch |err| return fail(ctx, err),
        .host_path = toSlice(opts.host_path) catch |err| return fail(ctx, err),
        .guest_path = toSlice(opts.guest_path) catch |err| return fail(ctx, err),
    }) catch |err| return fail(ctx, err);
    return result_success;
}

pub export fn spore_copy_out_named(
    context: ?*SporeContextImpl,
    options: ?*const SporeCopyNamedOptions,
) c_int {
    const ctx = context orelse return result_invalid_value;
    const opts = options orelse return fail(ctx, error.InvalidValue);
    ctx.clearLastError();
    if (opts.version != copy_named_options_version or opts.size < @sizeOf(SporeCopyNamedOptions)) {
        return fail(ctx, error.InvalidValue);
    }

    libspore.copyOutNamed(ctx.productContext(), ctx.allocator, .{
        .name = toSlice(opts.name) catch |err| return fail(ctx, err),
        .host_path = toSlice(opts.host_path) catch |err| return fail(ctx, err),
        .guest_path = toSlice(opts.guest_path) catch |err| return fail(ctx, err),
    }) catch |err| return fail(ctx, err);
    return result_success;
}

pub export fn spore_restore_named_json(
    context: ?*SporeContextImpl,
    options: ?*const SporeRestoreNamedOptions,
    out_json: ?*SporeOwnedString,
) c_int {
    const ctx = context orelse return result_invalid_value;
    const opts = options orelse return fail(ctx, error.InvalidValue);
    const out = out_json orelse return fail(ctx, error.InvalidValue);
    out.* = .{};
    ctx.clearLastError();
    if (opts.version != restore_named_options_version or opts.size < @sizeOf(SporeRestoreNamedOptions)) {
        return fail(ctx, error.InvalidValue);
    }

    var process_arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer process_arena.deinit();
    const arena = process_arena.allocator();
    const init = cInit(ctx, &process_arena);
    const bound_services = parseBoundUnixServiceBindings(arena, opts.bound_unix_services, opts.bound_unix_service_count) catch |err| return fail(ctx, err);
    const result = libspore.restoreNamed(init, ctx.allocator, .{
        .spore_dir = toSlice(opts.spore_dir) catch |err| return fail(ctx, err),
        .name = toSlice(opts.name) catch |err| return fail(ctx, err),
        .spore_executable = (optionalSlice(opts.spore_executable) catch |err| return fail(ctx, err)) orelse "spore",
        .bound_services = bound_services,
    }) catch |err| return fail(ctx, err);
    defer libspore.deinitNamedLifecycleResult(ctx.allocator, result);

    out.* = jsonOwned(ctx, result) catch |err| return fail(ctx, err);
    return result_success;
}

pub export fn spore_fork_named_json(
    context: ?*SporeContextImpl,
    options: ?*const SporeForkNamedOptions,
    out_json: ?*SporeOwnedString,
) c_int {
    const ctx = context orelse return result_invalid_value;
    const opts = options orelse return fail(ctx, error.InvalidValue);
    const out = out_json orelse return fail(ctx, error.InvalidValue);
    out.* = .{};
    ctx.clearLastError();
    if (opts.version != fork_named_options_version or opts.size < @sizeOf(SporeForkNamedOptions)) {
        return fail(ctx, error.InvalidValue);
    }

    var process_arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer process_arena.deinit();
    const init = cInit(ctx, &process_arena);
    const result = libspore.forkNamed(init, ctx.allocator, .{
        .source_name = toSlice(opts.source_name) catch |err| return fail(ctx, err),
        .count = opts.count,
        .name_pattern = toSlice(opts.name_pattern) catch |err| return fail(ctx, err),
        .spore_executable = (optionalSlice(opts.spore_executable) catch |err| return fail(ctx, err)) orelse "spore",
    }) catch |err| return fail(ctx, err);
    defer libspore.deinitNamedForkResult(ctx.allocator, result);

    out.* = jsonOwned(ctx, result) catch |err| return fail(ctx, err);
    return result_success;
}

pub export fn spore_save_named_json(
    context: ?*SporeContextImpl,
    options: ?*const SporeSaveNamedOptions,
    out_json: ?*SporeOwnedString,
) c_int {
    const ctx = context orelse return result_invalid_value;
    const opts = options orelse return fail(ctx, error.InvalidValue);
    const out = out_json orelse return fail(ctx, error.InvalidValue);
    out.* = .{};
    ctx.clearLastError();
    if (opts.version != save_named_options_version or opts.size < @sizeOf(SporeSaveNamedOptions)) {
        return fail(ctx, error.InvalidValue);
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const annotations = parseAnnotations(arena, opts.annotations, opts.annotation_count) catch |err| return fail(ctx, err);
    const result = libspore.saveNamed(ctx.productContext(), ctx.allocator, .{
        .name = toSlice(opts.name) catch |err| return fail(ctx, err),
        .out_dir = toSlice(opts.out_dir) catch |err| return fail(ctx, err),
        .stop = opts.stop != 0,
        .annotations = annotations,
    }) catch |err| return fail(ctx, err);
    defer libspore.deinitNamedLifecycleResult(ctx.allocator, result);

    out.* = jsonOwned(ctx, result) catch |err| return fail(ctx, err);
    return result_success;
}

pub export fn spore_remove_named_json(
    context: ?*SporeContextImpl,
    options: ?*const SporeRemoveNamedOptions,
    out_json: ?*SporeOwnedString,
) c_int {
    const ctx = context orelse return result_invalid_value;
    const opts = options orelse return fail(ctx, error.InvalidValue);
    const out = out_json orelse return fail(ctx, error.InvalidValue);
    out.* = .{};
    ctx.clearLastError();
    if (opts.version != remove_named_options_version or opts.size < @sizeOf(SporeRemoveNamedOptions)) {
        return fail(ctx, error.InvalidValue);
    }

    const result = libspore.removeNamed(ctx.productContext(), ctx.allocator, .{
        .name = toSlice(opts.name) catch |err| return fail(ctx, err),
    }) catch |err| return fail(ctx, err);
    defer libspore.deinitNamedLifecycleResult(ctx.allocator, result);

    out.* = jsonOwned(ctx, result) catch |err| return fail(ctx, err);
    return result_success;
}

pub export fn spore_remove_saved_json(context: ?*SporeContextImpl, options: ?*const SporeRemoveSavedOptions, out_json: ?*SporeOwnedString) c_int {
    const ctx = context orelse return result_invalid_value;
    const opts = options orelse return fail(ctx, error.InvalidValue);
    const out = out_json orelse return fail(ctx, error.InvalidValue);
    out.* = .{};
    ctx.clearLastError();
    if (opts.version != remove_saved_options_version or opts.size < @sizeOf(SporeRemoveSavedOptions)) return fail(ctx, error.InvalidValue);
    const result = libspore.removeSavedSpore(ctx.productContext(), ctx.allocator, toSlice(opts.spore_dir) catch |err| return fail(ctx, err)) catch |err| return fail(ctx, err);
    defer libspore.deinitRemovedSavedSpore(ctx.allocator, result);
    out.* = jsonOwned(ctx, result) catch |err| return fail(ctx, err);
    return result_success;
}

pub export fn spore_list_named_json(context: ?*SporeContextImpl, out_json: ?*SporeOwnedString) c_int {
    const ctx = context orelse return result_invalid_value;
    const out = out_json orelse return fail(ctx, error.InvalidValue);
    out.* = .{};
    ctx.clearLastError();

    const entries = libspore.listNamed(ctx.productContext(), ctx.allocator, .{}) catch |err| return fail(ctx, err);
    defer libspore.deinitNamedList(ctx.allocator, entries);

    out.* = jsonOwned(ctx, entries) catch |err| return fail(ctx, err);
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

fn cacheRootFromPath(path: ?[]const u8) libspore.CacheRoot {
    return if (path) |value| .{ .path = value } else .env;
}

fn parseCacheRoot(value: SporeCacheRoot) !libspore.CacheRoot {
    return switch (value.kind) {
        cache_root_env => .env,
        cache_root_none => .none,
        cache_root_path => {
            const path = try toSlice(value.path);
            if (path.len == 0) return error.InvalidValue;
            return .{ .path = path };
        },
        else => error.InvalidValue,
    };
}

fn cInit(ctx: *SporeContextImpl, arena: *std.heap.ArenaAllocator) std.process.Init {
    return .{
        .minimal = undefined,
        .arena = arena,
        .gpa = ctx.allocator,
        .io = ctx.io(),
        .environ_map = &ctx.env,
        .preopens = .empty,
    };
}

fn parseBackend(raw: ?[]const u8) !libspore.Backend {
    const value = raw orelse return .auto;
    return libspore.Backend.parse(value) orelse error.InvalidValue;
}

fn memoryFromBytes(bytes: u64) !libspore.MemoryConfig {
    if (bytes == 0) return .{};
    if (bytes % std.heap.page_size_min != 0) return error.InvalidValue;
    return .{ .policy = .explicit, .bytes = bytes };
}

fn parseNetworkPolicy(allocator: std.mem.Allocator, raw: ?[*]const SporeNetworkRule, len: usize) !libspore.NetworkPolicy {
    if (len == 0) return .{};
    const values = raw orelse return error.InvalidValue;
    const allow = try allocator.alloc(libspore.NetworkRule, len);
    for (allow, values[0..len]) |*out, value| {
        const ports_ptr = value.ports orelse return error.InvalidValue;
        if (value.port_count == 0) return error.InvalidValue;
        out.* = .{
            .host = try toSlice(value.host),
            .ports = ports_ptr[0..value.port_count],
        };
    }
    return .{ .allow = allow };
}

fn parseStringList(allocator: std.mem.Allocator, raw: ?[*]const SporeString, len: usize) ![]const []const u8 {
    if (len == 0) return &.{};
    const values = raw orelse return error.InvalidValue;
    const out = try allocator.alloc([]const u8, len);
    for (out, values[0..len]) |*item, value| {
        item.* = try toSlice(value);
    }
    return out;
}

fn parseBoundUnixServices(allocator: std.mem.Allocator, raw: ?[*]const SporeBoundUnixService, len: usize) ![]const libspore.BoundService {
    if (len == 0) return &.{};
    const values = raw orelse return error.InvalidValue;
    const services = try allocator.alloc(libspore.BoundService, len);
    for (services, values[0..len]) |*out, value| {
        out.* = .{
            .name = try toSlice(value.name),
            .guest_host = try toSlice(value.guest_host),
            .guest_port = value.guest_port,
            .target = .{ .unix = try toSlice(value.unix_path) },
        };
    }
    return services;
}

fn parseBoundUnixServiceBindings(allocator: std.mem.Allocator, raw: ?[*]const SporeBoundUnixServiceBinding, len: usize) ![]const libspore.BoundServiceBinding {
    if (len == 0) return &.{};
    const values = raw orelse return error.InvalidValue;
    const services = try allocator.alloc(libspore.BoundServiceBinding, len);
    for (services, values[0..len]) |*out, value| {
        out.* = .{
            .name = try toSlice(value.name),
            .target = .{ .unix = try toSlice(value.unix_path) },
        };
    }
    return services;
}

fn parseAnnotations(allocator: std.mem.Allocator, raw: ?[*]const SporeAnnotation, len: usize) !libspore.Annotations {
    var annotations = libspore.Annotations{};
    if (len == 0) return annotations;
    const values = raw orelse return error.InvalidValue;
    for (values[0..len]) |value| {
        annotations.map.put(allocator, try toSlice(value.key), try toSlice(value.value)) catch return error.OutOfMemory;
    }
    libspore.validateAnnotations(annotations) catch return error.InvalidValue;
    return annotations;
}

fn parseArgv(allocator: std.mem.Allocator, raw: ?[*]const SporeString, len: usize) ![]const []const u8 {
    if (len == 0) return error.InvalidValue;
    const values = raw orelse return error.InvalidValue;
    const out = try allocator.alloc([]const u8, len);
    for (out, values[0..len]) |*slot, value| slot.* = try toSlice(value);
    return out;
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

fn getenvSlice(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

fn cArgvToSlices(allocator: std.mem.Allocator, argc: c_int, raw_argv: ?[*]const ?[*:0]const u8) ![][]const u8 {
    if (argc <= 0) return error.InvalidValue;
    const raw = raw_argv orelse return error.InvalidValue;
    const count: usize = @intCast(argc);
    const argv = try allocator.alloc([]const u8, count);
    errdefer allocator.free(argv);
    for (argv, raw[0..count]) |*out, maybe_arg| {
        const arg = maybe_arg orelse return error.InvalidValue;
        out.* = std.mem.span(arg);
    }
    return argv;
}

fn runReexecRole(
    allocator: std.mem.Allocator,
    role: []const u8,
    contract: []const u8,
    argv: []const []const u8,
    options: ReexecOptions,
) !c_int {
    if (argv.len < 2 or argv[0].len == 0) return error.InvalidValue;
    const parsed_role = parseReexecRole(role) orelse return error.InvalidValue;
    const role_index: usize = if (std.mem.eql(u8, argv[1], "--debug")) 2 else 1;
    if (argv.len <= role_index or !std.mem.eql(u8, role, argv[role_index])) return error.InvalidValue;
    const parsed_contract = std.fmt.parseUnsigned(u32, contract, 10) catch return error.InvalidValue;
    if (parsed_contract != reexec_contract_version) return error.InvalidValue;

    if (options.unset_env) unsetReexecEnv();
    if (options.cleanup_fds) closeUnexpectedFds();

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .{ .block = currentEnvironBlock() } });
    defer threaded.deinit();
    var environ_map = try std.process.Environ.createMap(.{ .block = currentEnvironBlock() }, allocator);
    defer environ_map.deinit();
    _ = environ_map.swapRemove(reexec_role_env);
    _ = environ_map.swapRemove(reexec_contract_env);

    const init = std.process.Init{
        .minimal = undefined,
        .arena = &arena_state,
        .gpa = allocator,
        .io = threaded.io(),
        .environ_map = &environ_map,
        .preopens = .empty,
    };

    if (options.discard_stdout) {
        var stdout_buffer: [1024]u8 = undefined;
        var stdout_discarding: std.Io.Writer.Discarding = .init(&stdout_buffer);
        try runReexecRoleWithWriter(init, parsed_role, argv[role_index + 1 ..], argv[0], &stdout_discarding.writer);
        try stdout_discarding.writer.flush();
        return 0;
    }

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    try runReexecRoleWithWriter(init, parsed_role, argv[role_index + 1 ..], argv[0], &stdout_file_writer.interface);
    try stdout_file_writer.interface.flush();
    return 0;
}

fn parseReexecRole(role: []const u8) ?ReexecRole {
    if (std.mem.eql(u8, role, "monitor")) return .monitor;
    if (std.mem.eql(u8, role, "netd")) return .netd;
    return null;
}

fn runReexecRoleWithWriter(
    init: std.process.Init,
    role: ReexecRole,
    role_args: []const []const u8,
    spore_executable: []const u8,
    stdout: *std.Io.Writer,
) !void {
    switch (role) {
        .monitor => try spore_internal.monitor.runRole(init, role_args, stdout, spore_executable),
        .netd => try spore_internal.spore_netd.runRole(init, role_args, stdout),
    }
}

fn currentEnvironBlock() std.process.Environ.Block {
    if (comptime builtin.os.tag == .windows) return .global;

    var count: usize = 0;
    while (std.c.environ[count] != null) : (count += 1) {}
    return .{ .slice = std.c.environ[0..count :null] };
}

fn unsetReexecEnv() void {
    if (comptime builtin.os.tag == .windows) return;
    _ = posix_env.unsetenv(reexec_role_env);
    _ = posix_env.unsetenv(reexec_contract_env);
}

fn closeUnexpectedFds() void {
    if (comptime builtin.os.tag == .linux) {
        const rc = std.os.linux.close_range(
            @as(std.os.linux.fd_t, 3),
            std.math.maxInt(std.os.linux.fd_t),
            .{ .UNSHARE = false, .CLOEXEC = false },
        );
        if (std.os.linux.errno(rc) == .SUCCESS) return;
    }
    closeFdLoop(3, maxFdToClose());
}

fn closeFdLoop(first: std.posix.fd_t, last: std.posix.fd_t) void {
    if (last < first) return;
    var fd = first;
    while (true) {
        _ = std.c.close(fd);
        if (fd == last) break;
        fd += 1;
    }
}

fn maxFdToClose() std.posix.fd_t {
    const fallback: std.posix.fd_t = 1024;
    const hard_cap: u64 = 65_536;
    const lim = std.posix.getrlimit(.NOFILE) catch return fallback;
    const raw_cur: u64 = if (lim.cur == std.posix.RLIM.INFINITY) hard_cap else @intCast(lim.cur);
    const bounded = @min(raw_cur, hard_cap);
    if (bounded <= 3) return 2;
    return @intCast(@min(bounded - 1, @as(u64, @intCast(std.math.maxInt(std.posix.fd_t)))));
}

fn resultFromError(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => result_out_of_memory,
        error.InvalidValue => result_invalid_value,
        else => result_error,
    };
}

fn fail(ctx: *SporeContextImpl, err: anyerror) c_int {
    const detail = libspore.lastLifecycleErrorMessage();
    ctx.setLastError(if (detail.len == 0) @errorName(err) else detail);
    return switch (err) {
        error.OutOfMemory => result_out_of_memory,
        error.InvalidPruneSelection, error.InvalidValue => result_invalid_value,
        else => result_error,
    };
}

test "build info exposes version" {
    var version: SporeString = .{};
    try std.testing.expectEqual(result_success, spore_build_info(build_info_version_string, &version));
    try std.testing.expectEqualStrings(spore_internal.version, version.ptr.?[0..version.len]);

    var abi: u32 = 0;
    try std.testing.expectEqual(result_success, spore_build_info(build_info_abi_version, &abi));
    try std.testing.expectEqual(c_abi_version, abi);
}

test "reexec role validation fails closed" {
    const allocator = std.testing.allocator;
    const options = ReexecOptions{ .cleanup_fds = false, .unset_env = false };

    try std.testing.expectError(error.InvalidValue, runReexecRole(allocator, "netd", "1", &.{ "embedder", "monitor", "--help" }, options));
    try std.testing.expectError(error.InvalidValue, runReexecRole(allocator, "netd", "2", &.{ "embedder", "netd", "--help" }, options));
    try std.testing.expectError(error.InvalidValue, runReexecRole(allocator, "unknown", "1", &.{ "embedder", "unknown" }, options));
    try std.testing.expectError(error.InvalidValue, runReexecRole(allocator, "netd", "1", &.{ "embedder", "--debug" }, options));
}

test "reexec dispatcher reaches hidden role parsers" {
    const allocator = std.testing.allocator;
    const options = ReexecOptions{ .cleanup_fds = false, .unset_env = false, .discard_stdout = true };

    try std.testing.expectEqual(@as(c_int, 0), try runReexecRole(allocator, "netd", "1", &.{ "embedder", "netd", "--help" }, options));
    try std.testing.expectEqual(@as(c_int, 0), try runReexecRole(allocator, "netd", "1", &.{ "embedder", "--debug", "netd", "--help" }, options));
    try std.testing.expectEqual(@as(c_int, 0), try runReexecRole(allocator, "monitor", "1", &.{ "embedder", "monitor", "--help" }, options));
}

test "reexec fd cleanup closes a bounded range" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const fd = std.c.open("/dev/null", .{});
    try std.testing.expect(fd >= 3);
    closeFdLoop(fd, fd);
    try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(fd, std.c.F.GETFD));
}

test "inspect bundle options initialize size and version" {
    var options: SporeInspectBundleOptions = undefined;
    spore_inspect_bundle_options_init(&options);
    try std.testing.expectEqual(@as(u32, @intCast(@sizeOf(SporeInspectBundleOptions))), options.size);
    try std.testing.expectEqual(inspect_bundle_options_version, options.version);

    var inspect_spore_options: SporeInspectSporeOptions = undefined;
    spore_inspect_spore_options_init(&inspect_spore_options);
    try std.testing.expectEqual(@as(u32, @intCast(@sizeOf(SporeInspectSporeOptions))), inspect_spore_options.size);
    try std.testing.expectEqual(inspect_spore_options_version, inspect_spore_options.version);

    var pull_options: SporePullOptions = undefined;
    spore_pull_options_init(&pull_options);
    try std.testing.expectEqual(@as(u32, @intCast(@sizeOf(SporePullOptions))), pull_options.size);
    try std.testing.expectEqual(pull_options_version, pull_options.version);
    try std.testing.expectEqual(cache_root_env, pull_options.rootfs_cache.kind);
    try std.testing.expectEqual(cache_root_env, pull_options.bundle_cache.kind);
    try std.testing.expectEqual(@as(u8, 0), pull_options.allow_metadata_only_rootfs);

    var df_options: SporeSystemDfOptions = undefined;
    spore_system_df_options_init(&df_options);
    try std.testing.expectEqual(@as(u32, @intCast(@sizeOf(SporeSystemDfOptions))), df_options.size);
    try std.testing.expectEqual(system_df_options_version, df_options.version);

    var prune_options: SporeSystemPruneOptions = undefined;
    spore_system_prune_options_init(&prune_options);
    try std.testing.expectEqual(@as(u32, @intCast(@sizeOf(SporeSystemPruneOptions))), prune_options.size);
    try std.testing.expectEqual(system_prune_options_version, prune_options.version);
    try std.testing.expectEqual(@as(u8, 1), prune_options.dry_run);
    try std.testing.expectEqual(@as(u8, 0), prune_options.include_digest_artifacts);
}

test "named lifecycle options initialize defaults" {
    var create: SporeCreateNamedOptions = undefined;
    spore_create_named_options_init(&create);
    try std.testing.expectEqual(@as(u32, @intCast(@sizeOf(SporeCreateNamedOptions))), create.size);
    try std.testing.expectEqual(create_named_options_version, create.version);
    try std.testing.expectEqual(@as(u32, 1), create.vcpus);
    try std.testing.expectEqual(@as(u32, 10700), create.guest_port);
    try std.testing.expectEqual(@as(u64, 30_000), create.timeout_ms);
    try std.testing.expectEqual(@as(u8, 0), create.network_enabled);
    try std.testing.expectEqual(@as(usize, 0), create.allow_cidr_count);
    try std.testing.expectEqual(@as(usize, 0), create.allow_host_count);
    try std.testing.expectEqual(@as(usize, 0), create.network_rule_count);
    try std.testing.expectEqual(@as(usize, 0), create.bound_unix_service_count);
    try std.testing.expectEqual(@as(usize, 0), create.annotation_count);

    var exec: SporeExecNamedOptions = undefined;
    spore_exec_named_options_init(&exec);
    try std.testing.expectEqual(exec_named_options_version, exec.version);
    try std.testing.expectEqual(@as(u8, 0), exec.has_network_policy);

    var stream: SporeExecNamedStreamOptions = undefined;
    spore_exec_named_stream_options_init(&stream);
    try std.testing.expectEqual(exec_named_stream_options_version, stream.version);
    try std.testing.expectEqual(@as(u16, 24), stream.terminal_rows);
    try std.testing.expectEqual(@as(u16, 80), stream.terminal_cols);

    var copy: SporeCopyNamedOptions = undefined;
    spore_copy_named_options_init(&copy);
    try std.testing.expectEqual(@as(u32, @intCast(@sizeOf(SporeCopyNamedOptions))), copy.size);
    try std.testing.expectEqual(copy_named_options_version, copy.version);

    var restore_options: SporeRestoreNamedOptions = undefined;
    spore_restore_named_options_init(&restore_options);
    try std.testing.expectEqual(restore_named_options_version, restore_options.version);
    try std.testing.expectEqual(@as(usize, 0), restore_options.bound_unix_service_count);

    var fork_options: SporeForkNamedOptions = undefined;
    spore_fork_named_options_init(&fork_options);
    try std.testing.expectEqual(fork_named_options_version, fork_options.version);

    var save: SporeSaveNamedOptions = undefined;
    spore_save_named_options_init(&save);
    try std.testing.expectEqual(save_named_options_version, save.version);
    try std.testing.expectEqual(@as(u8, 0), save.stop);
    try std.testing.expectEqual(@as(usize, 0), save.annotation_count);

    var remove_saved: SporeRemoveSavedOptions = undefined;
    spore_remove_saved_options_init(&remove_saved);
    try std.testing.expectEqual(@as(u32, @intCast(@sizeOf(SporeRemoveSavedOptions))), remove_saved.size);
    try std.testing.expectEqual(remove_saved_options_version, remove_saved.version);
    try std.testing.expectEqual(@as(usize, 0), remove_saved.spore_dir.len);
}

test "C ABI exposes network capabilities JSON" {
    var context: ?*SporeContextImpl = null;
    try std.testing.expectEqual(result_success, spore_context_new(&context));
    defer spore_context_free(context);

    var json: SporeOwnedString = .{};
    try std.testing.expectEqual(result_success, spore_network_capabilities_json(context, &json));
    defer spore_free_string(context, json);
    try std.testing.expect(std.mem.indexOf(u8, json.ptr.?[0..json.len], "\"exact_host_port\": true") != null);
}

test "C ABI inspect spore JSON includes annotation values" {
    var context: ?*SporeContextImpl = null;
    try std.testing.expectEqual(result_success, spore_context_new(&context));
    defer spore_context_free(context);

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer std.testing.allocator.free(dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "manifest.json", .data = inspect_spore_manifest_json });

    var options: SporeInspectSporeOptions = undefined;
    spore_inspect_spore_options_init(&options);
    options.spore_dir = borrowString(dir);

    var json: SporeOwnedString = .{};
    try std.testing.expectEqual(result_success, spore_inspect_spore_json(context, &options, &json));
    defer spore_free_string(context, json);
    const data = json.ptr.?[0..json.len];
    try std.testing.expect(std.mem.indexOf(u8, data, "\"vm_state_present\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"storage_mode\": \"memory-only\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"annotations\": {") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"cleanroom.workspace\": \"/workspaces/app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"cleanroom.provenance\": \"sha256:abc123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"network\": {") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"bound_services\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"name\": \"cleanroom-gateway\"") != null);
}

test "pull rejects missing required options at ABI boundary" {
    var context: ?*SporeContextImpl = null;
    try std.testing.expectEqual(result_success, spore_context_new(&context));
    defer spore_context_free(context);

    var options: SporePullOptions = undefined;
    spore_pull_options_init(&options);
    var json: SporeOwnedString = .{};
    try std.testing.expectEqual(result_invalid_value, spore_pull_json(context, &options, &json));
    try std.testing.expectEqual(@as(?[*]u8, null), json.ptr);
}

test "C ABI can list named VMs from context runtime env" {
    var context: ?*SporeContextImpl = null;
    try std.testing.expectEqual(result_success, spore_context_new(&context));
    defer spore_context_free(context);

    const runtime = "/tmp/sporevm-c-api-test-empty";
    _ = std.Io.Dir.cwd().deleteTree(std.testing.io, runtime) catch {};
    try std.testing.expectEqual(result_success, spore_context_set_env(context, borrowString("SPOREVM_RUNTIME_DIR"), borrowString(runtime)));

    var json: SporeOwnedString = .{};
    try std.testing.expectEqual(result_success, spore_list_named_json(context, &json));
    defer spore_free_string(context, json);
    try std.testing.expectEqualStrings("[]\n", json.ptr.?[0..json.len]);
}

test "C ABI named lifecycle last error carries state and truthful log paths" {
    var context: ?*SporeContextImpl = null;
    try std.testing.expectEqual(result_success, spore_context_new(&context));
    defer spore_context_free(context);

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const runtime = try std.fs.path.resolve(allocator, &.{"/tmp/sporevm-c-api-lifecycle-error"});
    defer allocator.free(runtime);
    defer std.Io.Dir.cwd().deleteTree(io, runtime) catch {};
    try std.testing.expectEqual(result_success, spore_context_set_env(context, borrowString("SPOREVM_RUNTIME_DIR"), borrowString(runtime)));
    const monitor_log_path = try std.fs.path.resolve(allocator, &.{ runtime, "vms", "bench-1", "monitor.log" });
    defer allocator.free(monitor_log_path);
    const control_socket_path = try std.fs.path.resolve(allocator, &.{ runtime, "vms", "bench-1", "control.sock" });
    defer allocator.free(control_socket_path);

    var argv = [_]SporeString{borrowString("/bin/true")};
    var options: SporeExecNamedOptions = undefined;
    spore_exec_named_options_init(&options);
    options.name = borrowString("bench-1");
    options.argv = &argv;
    options.argc = argv.len;

    var json: SporeOwnedString = .{};
    try std.testing.expectEqual(result_error, spore_exec_named_json(context, &options, &json));
    try std.testing.expectEqual(@as(?[*]u8, null), json.ptr);

    const last = spore_context_last_error(context);
    const detail = last.ptr.?[0..last.len];
    try std.testing.expect(std.mem.indexOf(u8, detail, "state=absent") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "console_log=none") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, monitor_log_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, control_socket_path) != null);
}

const inspect_spore_manifest_json =
    \\{
    \\  "version": 2,
    \\  "annotations": {
    \\    "cleanroom.workspace": "/workspaces/app",
    \\    "cleanroom.provenance": "sha256:abc123"
    \\  },
    \\  "platform": {
    \\    "arch": "aarch64",
    \\    "cpu_profile": "sporevm-aarch64-v0",
    \\    "device_model_version": 4,
    \\    "ram_base": 2147483648,
    \\    "ram_size": 1,
    \\    "gic_dist_base": 134217728,
    \\    "gic_redist_base": 134283264,
    \\    "counter_frequency_hz": 24000000
    \\  },
    \\  "machine": {
    \\    "gprs": [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
    \\    "pc": 0,
    \\    "cpsr": 0,
    \\    "fpcr": 0,
    \\    "fpsr": 0,
    \\    "simd": [[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0]],
    \\    "sys_regs": [],
    \\    "icc_regs": [],
    \\    "vtimer": {"cntvct":0,"cntv_ctl":0,"cntv_cval":0},
    \\    "gic": {"kind":"gicv3","gicv3":{"schema_version":0,"dist_regs":[{"offset":24832,"width_bits":64,"value":0}],"redist_regs":[{"offset":65664,"width_bits":32,"value":0}],"line_levels":[{"intid":16,"asserted":false}]}}
    \\  },
    \\  "devices": [],
    \\  "generation": {"generation":0,"interrupt_status":0,"params_b64":""},
    \\  "rootfs": null,
    \\  "disk": null,
    \\  "network": {
    \\    "bound_services": [{
    \\      "name": "cleanroom-gateway",
    \\      "guest_host": "gateway.cleanroom.internal",
    \\      "guest_port": 8170
    \\    }],
    \\    "requirements": {"tcp_ipv4":true,"exact_host_port":false,"bound_services":true}
    \\  },
    \\  "memory": {"kind":"spore-disk-index-v1","logical_size":1,"chunk_size":2097152,"hash_algorithm":"blake3","object_namespace":"memory/blake3","chunks":[],"zero_chunks":[0],"backing":null}
    \\}
;
