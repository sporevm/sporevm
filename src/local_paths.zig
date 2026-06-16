//! Local host paths for SporeVM-managed cache and runtime roots.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const app_dir = "sporevm";
const xdg_cache_home_env = "XDG_CACHE_HOME";
const xdg_runtime_dir_env = "XDG_RUNTIME_DIR";

pub const kernel_cache_env = "SPOREVM_KERNEL_CACHE_DIR";
pub const rootfs_cache_env = "SPOREVM_ROOTFS_CACHE_DIR";
pub const runtime_dir_env = "SPOREVM_RUNTIME_DIR";

pub const CacheKind = enum {
    kernels,
    rootfs,

    fn overrideEnvName(self: CacheKind) []const u8 {
        return switch (self) {
            .kernels => kernel_cache_env,
            .rootfs => rootfs_cache_env,
        };
    }

    fn leafName(self: CacheKind) []const u8 {
        return switch (self) {
            .kernels => "kernels",
            .rootfs => "rootfs",
        };
    }
};

pub fn cacheRootPath(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    kind: CacheKind,
) ![]const u8 {
    if (nonEmptyEnv(environ, kind.overrideEnvName())) |path| {
        return std.fs.path.resolve(allocator, &.{path});
    }
    if (nonEmptyEnv(environ, xdg_cache_home_env)) |path| {
        return std.fs.path.resolve(allocator, &.{ path, app_dir, kind.leafName() });
    }
    const home = nonEmptyEnv(environ, "HOME") orelse return error.MissingHome;
    if (comptime builtin.os.tag == .macos) {
        return std.fs.path.resolve(allocator, &.{ home, "Library", "Caches", app_dir, kind.leafName() });
    }
    return std.fs.path.resolve(allocator, &.{ home, ".cache", app_dir, kind.leafName() });
}

fn nonEmptyEnv(environ: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const value = environ.get(name) orelse return null;
    if (value.len == 0) return null;
    return value;
}

pub fn kernelCacheRootPath(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    return cacheRootPath(allocator, environ, .kernels);
}

pub fn rootfsCacheRootPath(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    return cacheRootPath(allocator, environ, .rootfs);
}

pub fn runtimeRootPath(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get(runtime_dir_env)) |path| return resolveRequiredAbsolute(allocator, path);
    if (environ.get(xdg_runtime_dir_env)) |path| {
        try validateAbsoluteRuntimePath(path);
        return std.fs.path.resolve(allocator, &.{ path, app_dir });
    }
    const tmp = environ.get("TMPDIR") orelse "/tmp";
    try validateAbsoluteRuntimePath(tmp);
    const leaf = try fallbackRuntimeLeaf(allocator);
    defer allocator.free(leaf);
    return std.fs.path.resolve(allocator, &.{ tmp, leaf });
}

fn resolveRequiredAbsolute(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    try validateAbsoluteRuntimePath(path);
    return std.fs.path.resolve(allocator, &.{path});
}

fn validateAbsoluteRuntimePath(path: []const u8) !void {
    if (path.len == 0 or !Io.Dir.path.isAbsolute(path)) return error.InvalidRuntimeDir;
}

fn fallbackRuntimeLeaf(allocator: std.mem.Allocator) ![]const u8 {
    if (comptime builtin.os.tag == .windows) return allocator.dupe(u8, app_dir);
    return std.fmt.allocPrint(allocator, "{s}-{d}", .{ app_dir, std.c.getuid() });
}

test "cache roots prefer explicit and xdg paths" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    try env.put(kernel_cache_env, "/tmp/sporevm-kernels");
    const explicit = try kernelCacheRootPath(allocator, &env);
    defer allocator.free(explicit);
    try std.testing.expectEqualStrings("/tmp/sporevm-kernels", explicit);

    _ = env.swapRemove(kernel_cache_env);
    try env.put(xdg_cache_home_env, "/tmp/xdg-cache");
    const kernels = try kernelCacheRootPath(allocator, &env);
    defer allocator.free(kernels);
    try std.testing.expectEqualStrings("/tmp/xdg-cache/sporevm/kernels", kernels);

    const rootfs = try rootfsCacheRootPath(allocator, &env);
    defer allocator.free(rootfs);
    try std.testing.expectEqualStrings("/tmp/xdg-cache/sporevm/rootfs", rootfs);
}

test "cache roots ignore empty optional environment values" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    try env.put(kernel_cache_env, "");
    try env.put(xdg_cache_home_env, "/tmp/xdg-cache");
    const kernels = try kernelCacheRootPath(allocator, &env);
    defer allocator.free(kernels);
    try std.testing.expectEqualStrings("/tmp/xdg-cache/sporevm/kernels", kernels);

    _ = env.swapRemove(xdg_cache_home_env);
    try env.put("HOME", "/home/spore");
    const home_fallback = try kernelCacheRootPath(allocator, &env);
    defer allocator.free(home_fallback);
    const expected = if (comptime builtin.os.tag == .macos)
        "/home/spore/Library/Caches/sporevm/kernels"
    else
        "/home/spore/.cache/sporevm/kernels";
    try std.testing.expectEqualStrings(expected, home_fallback);

    try env.put("HOME", "");
    try std.testing.expectError(error.MissingHome, kernelCacheRootPath(allocator, &env));
}

test "cache roots use platform home fallback" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/spore");

    const kernels = try kernelCacheRootPath(allocator, &env);
    defer allocator.free(kernels);
    const expected = if (comptime builtin.os.tag == .macos)
        "/home/spore/Library/Caches/sporevm/kernels"
    else
        "/home/spore/.cache/sporevm/kernels";
    try std.testing.expectEqualStrings(expected, kernels);
}

test "runtime root prefers explicit and xdg absolute paths" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    try env.put(runtime_dir_env, "/tmp/sporevm-runtime");
    const explicit = try runtimeRootPath(allocator, &env);
    defer allocator.free(explicit);
    try std.testing.expectEqualStrings("/tmp/sporevm-runtime", explicit);

    _ = env.swapRemove(runtime_dir_env);
    try env.put(xdg_runtime_dir_env, "/tmp/xdg-runtime");
    const xdg = try runtimeRootPath(allocator, &env);
    defer allocator.free(xdg);
    try std.testing.expectEqualStrings("/tmp/xdg-runtime/sporevm", xdg);
}

test "runtime root rejects relative environment paths" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    try env.put(runtime_dir_env, "relative");
    try std.testing.expectError(error.InvalidRuntimeDir, runtimeRootPath(allocator, &env));

    _ = env.swapRemove(runtime_dir_env);
    try env.put(xdg_runtime_dir_env, "");
    try std.testing.expectError(error.InvalidRuntimeDir, runtimeRootPath(allocator, &env));
}
