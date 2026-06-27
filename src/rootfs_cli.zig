//! CLI adapter for `spore rootfs`.
//!
//! This module owns rootfs argv parsing and human output. Rootfs behavior flows
//! through `api.zig`.

const std = @import("std");
const Io = std.Io;

const api = @import("api.zig");
const rootfs_mod = @import("rootfs.zig");

pub fn run(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "help")) {
        try stdout.writeAll(rootfs_mod.usage);
        return;
    }
    if (std.mem.eql(u8, args[0], "build")) {
        try build(init, args[1..], stdout);
        return;
    }
    if (std.mem.eql(u8, args[0], "import-oci")) {
        try importOci(init, args[1..], stdout);
        return;
    }
    if (std.mem.eql(u8, args[0], "resolve")) {
        try resolve(init, args[1..], stdout);
        return;
    }
    if (std.mem.eql(u8, args[0], "cas-preload")) {
        try casPreload(init, args[1..], stdout);
        return;
    }
    try stdout.print("unknown rootfs command: {s}\n\n", .{args[0]});
    try stdout.writeAll(rootfs_mod.usage);
    try stdout.flush();
    std.process.exit(2);
}

fn build(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    const arena = init.arena.allocator();
    const parsed = try rootfs_mod.parseBuildOptions(arena, args, stdout);
    const result = try api.rootfsBuild(init, arena, .{
        .ref = parsed.ref,
        .output = parsed.output,
        .metadata = parsed.metadata,
        .platform = parsed.platform,
        .mkfs = parsed.mkfs,
        .debugfs = parsed.debugfs,
    });
    try stdout.print("rootfs: {s}\nmetadata: {s}\nsource: {s}\nrootfs_blake3: {s}\nrootfs_storage: {s}\n", .{
        parsed.output,
        parsed.metadata,
        parsed.ref,
        result.rootfs_blake3,
        result.rootfs_storage.index_digest,
    });
}

fn importOci(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    const arena = init.arena.allocator();
    const parsed = try rootfs_mod.parseImportOciOptions(args, stdout);
    const result = try api.rootfsImportOci(init, arena, .{
        .input = parsed.input,
        .ref = parsed.ref,
        .platform = parsed.platform,
        .mkfs = parsed.mkfs,
        .debugfs = parsed.debugfs,
    });
    try stdout.print(
        "rootfs: {s}\nmetadata: {s}\nref: {s}\nresolved: {s}\nrootfs_blake3: {s}\n",
        .{
            result.rootfs_path,
            result.metadata_path,
            parsed.ref,
            result.resolved_image_ref,
            result.rootfs_blake3,
        },
    );
}

fn resolve(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    const arena = init.arena.allocator();
    const parsed = try rootfs_mod.parseResolveOptions(args, stdout);
    const resolved = try api.rootfsResolve(init, arena, .{
        .ref = parsed.ref,
        .platform = parsed.platform,
    });
    try stdout.print("{s}\n", .{resolved});
}

fn casPreload(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    const arena = init.arena.allocator();
    const parsed = try rootfs_mod.parseCasPreloadOptions(args, stdout);
    const result = try api.rootfsCasPreload(init, arena, .{
        .digest = parsed.digest,
        .chunk_size = parsed.chunk_size,
        .attach_spore = parsed.attach_spore,
    });
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
