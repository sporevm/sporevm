//! CLI adapters for the `spore rootfs` commands.
//!
//! This module owns rootfs argv parsing and human output. Rootfs behavior flows
//! through `api.zig`.

const std = @import("std");
const Io = std.Io;

const api = @import("api.zig");
const Ctx = @import("cli.zig").Ctx;
const machine_output = @import("machine_output.zig");
const rootfs_mod = @import("rootfs.zig");

pub const build_usage =
    \\Usage:
    \\  spore rootfs build <image@sha256:...|image:tag> --output <rootfs.ext4>
    \\
    \\Options:
    \\  --output <path>        Rootfs ext4 output path
    \\  --metadata <path>      Metadata sidecar path (default: <output>.json)
    \\  --platform <os/arch>   linux/arm64 or linux/amd64 (default: linux/arm64)
    \\  -h, --help             Show this help
    \\
;

pub const import_oci_usage =
    \\Usage:
    \\  spore rootfs import-oci <layout-dir|layout.tar> --ref local/name:tag
    \\
    \\Options:
    \\  --ref <name:tag>       Local mutable image ref to record
    \\  --platform <os/arch>   linux/arm64 or linux/amd64 (default: linux/arm64)
    \\  --rootfs-storage <policy>
    \\                       Rootfs storage: chunked (default: chunked)
    \\  -h, --help             Show this help
    \\
;

pub const import_tar_usage =
    \\Usage:
    \\  spore rootfs import-tar <rootfs.tar> --ref local/name:tag
    \\
    \\Options:
    \\  --ref <name:tag>       Local mutable image ref to record
    \\  --platform <os/arch>   linux/arm64 or linux/amd64 (default: linux/arm64)
    \\  --rootfs-storage <policy>
    \\                       Rootfs storage: chunked (default: chunked)
    \\  -h, --help             Show this help
    \\
;

pub const resolve_usage =
    \\Usage:
    \\  spore rootfs resolve <image:tag>
    \\
    \\Options:
    \\  --platform <os/arch>   linux/arm64 or linux/amd64 (default: linux/arm64)
    \\  -h, --help             Show this help
    \\
;

pub const cas_preload_usage =
    \\Usage:
    \\  spore rootfs cas-preload <blake3:digest> [--chunk-size BYTES] [--attach-spore DIR]
    \\
    \\Repair/debug path for existing exact-rootfs spores.
    \\
    \\Options:
    \\  --chunk-size BYTES     Rootfs CAS chunk size
    \\  --attach-spore DIR     Attach the CAS descriptor to an existing spore
    \\  -h, --help             Show this help
    \\
;

pub fn build(ctx: *const Ctx, args: []const []const u8) !void {
    const init = ctx.init;
    const stdout = ctx.stdout;
    const mode = ctx.mode;
    const arena = init.arena.allocator();
    const parsed = try rootfs_mod.parseBuildOptions(arena, args, stdout);
    const result = try api.rootfsBuild(init, arena, .{
        .ref = parsed.ref,
        .output = parsed.output,
        .metadata = parsed.metadata,
        .platform = parsed.platform,
    });
    if (mode == .json) return machine_output.writeJson(arena, stdout, result);
    try stdout.print("rootfs: {s}\nmetadata: {s}\nsource: {s}\nrootfs_identity: {s}\nrootfs_storage: {s}\n", .{
        parsed.output,
        parsed.metadata,
        parsed.ref,
        result.rootfs_storage.index_digest,
        result.rootfs_storage.index_digest,
    });
}

pub fn importOci(ctx: *const Ctx, args: []const []const u8) !void {
    const init = ctx.init;
    const stdout = ctx.stdout;
    const mode = ctx.mode;
    const arena = init.arena.allocator();
    const parsed = try rootfs_mod.parseImportOciOptions(args, stdout);
    const result = try api.rootfsImportOci(init, arena, .{
        .input = parsed.input,
        .ref = parsed.ref,
        .platform = parsed.platform,
        .rootfs_storage = parsed.rootfs_storage,
    });
    if (mode == .json) return machine_output.writeJson(arena, stdout, result);
    try stdout.print(
        "metadata: {s}\nref: {s}\nresolved: {s}\nrootfs_identity: {s}\n",
        .{
            result.metadata_path,
            parsed.ref,
            result.resolved_image_ref,
            result.rootfs_storage.index_digest,
        },
    );
}

pub fn importTar(ctx: *const Ctx, args: []const []const u8) !void {
    const init = ctx.init;
    const stdout = ctx.stdout;
    const mode = ctx.mode;
    const arena = init.arena.allocator();
    const parsed = try rootfs_mod.parseImportTarOptions(args, stdout);
    const result = try api.rootfsImportTar(init, arena, .{
        .input = parsed.input,
        .ref = parsed.ref,
        .platform = parsed.platform,
        .rootfs_storage = parsed.rootfs_storage,
    });
    if (mode == .json) return machine_output.writeJson(arena, stdout, result);
    try stdout.print(
        "metadata: {s}\nref: {s}\nresolved: {s}\nrootfs_identity: {s}\n",
        .{
            result.metadata_path,
            parsed.ref,
            result.resolved_image_ref,
            result.rootfs_storage.index_digest,
        },
    );
}

pub fn resolve(ctx: *const Ctx, args: []const []const u8) !void {
    const init = ctx.init;
    const stdout = ctx.stdout;
    const mode = ctx.mode;
    const arena = init.arena.allocator();
    const parsed = try rootfs_mod.parseResolveOptions(args, stdout);
    const resolved = try api.rootfsResolve(init, arena, .{
        .ref = parsed.ref,
        .platform = parsed.platform,
    });
    if (mode == .json) return machine_output.writeJson(arena, stdout, .{
        .schema = "spore.rootfs.resolve.result.v1",
        .schema_version = @as(u32, 1),
        .ref = parsed.ref,
        .resolved_image_ref = resolved,
    });
    try stdout.print("{s}\n", .{resolved});
}

pub fn casPreload(ctx: *const Ctx, args: []const []const u8) !void {
    const init = ctx.init;
    const stdout = ctx.stdout;
    const mode = ctx.mode;
    const arena = init.arena.allocator();
    const parsed = try rootfs_mod.parseCasPreloadOptions(args, stdout);
    const result = try api.rootfsCasPreload(init, arena, .{
        .digest = parsed.digest,
        .chunk_size = parsed.chunk_size,
        .attach_spore = parsed.attach_spore,
    });
    if (mode == .json) return machine_output.writeJson(arena, stdout, result);
    try stdout.print(
        "index: {s}\nindex_digest: {s}\nrootfs: {s}\nrootfs_size: {d}\nchunk_size: {d}\nchunks: {d}\nzero_chunks: {d}\nnonzero_chunks: {d}\nobjects_written: {d}\nobject_bytes_written: {d}\nindex_bytes: {d}\n",
        .{
            result.index_path,
            result.index_digest,
            result.rootfs_digest,
            result.rootfs_size,
            result.chunk_size,
            result.chunk_count,
            result.zero_chunks,
            result.nonzero_chunks,
            result.objects_written,
            result.object_bytes_written,
            result.index_bytes,
        },
    );
    if (parsed.attach_spore) |spore_dir| {
        try stdout.print("attached_spore: {s}\n", .{spore_dir});
    }
}
