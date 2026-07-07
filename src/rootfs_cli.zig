//! CLI adapter for `spore rootfs`.
//!
//! This module owns rootfs argv parsing and human output. Rootfs behavior flows
//! through `api.zig`.

const std = @import("std");
const Io = std.Io;

const api = @import("api.zig");
const rootfs_mod = @import("rootfs.zig");

const build_usage =
    \\Usage:
    \\  spore rootfs build <image@sha256:...|image:tag> --output <rootfs.ext4>
    \\
    \\Options:
    \\  --output <path>        Rootfs ext4 output path
    \\  --metadata <path>      Metadata sidecar path (default: <output>.json)
    \\  --platform <os/arch>   Target platform (default: linux/arm64)
    \\  --mkfs <path>          external writer mkfs.ext4 binary (auto-detect)
    \\  --debugfs <path>       external writer debugfs binary (auto-detect)
    \\  -h, --help             Show this help
    \\
;

const import_oci_usage =
    \\Usage:
    \\  spore rootfs import-oci <layout-dir|layout.tar> --ref local/name:tag
    \\
    \\Options:
    \\  --ref <name:tag>       Local mutable image ref to record
    \\  --platform <os/arch>   Target platform (default: linux/arm64)
    \\  --rootfs-storage <policy>
    \\                       Rootfs storage: chunked or flat (default: chunked)
    \\  --mkfs <path>          external writer mkfs.ext4 binary (auto-detect)
    \\  --debugfs <path>       external writer debugfs binary (auto-detect)
    \\  -h, --help             Show this help
    \\
;

const import_tar_usage =
    \\Usage:
    \\  spore rootfs import-tar <rootfs.tar> --ref local/name:tag
    \\
    \\Options:
    \\  --ref <name:tag>       Local mutable image ref to record
    \\  --platform <os/arch>   Target platform (default: linux/arm64)
    \\  --rootfs-storage <policy>
    \\                       Rootfs storage: chunked or flat (default: chunked)
    \\  --mkfs <path>          external writer mkfs.ext4 binary (auto-detect)
    \\  --debugfs <path>       external writer debugfs binary (auto-detect)
    \\  -h, --help             Show this help
    \\
;

const resolve_usage =
    \\Usage:
    \\  spore rootfs resolve <image:tag>
    \\
    \\Options:
    \\  --platform <os/arch>   Target platform (default: linux/arm64)
    \\  -h, --help             Show this help
    \\
;

const cas_preload_usage =
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

pub fn run(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0 or wantsTopLevelHelp(args)) {
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
    if (std.mem.eql(u8, args[0], "import-tar")) {
        try importTar(init, args[1..], stdout);
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
    if (wantsHelp(args)) {
        try stdout.writeAll(build_usage);
        return;
    }
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
    if (wantsHelp(args)) {
        try stdout.writeAll(import_oci_usage);
        return;
    }
    const arena = init.arena.allocator();
    const parsed = try rootfs_mod.parseImportOciOptions(args, stdout);
    const result = try api.rootfsImportOci(init, arena, .{
        .input = parsed.input,
        .ref = parsed.ref,
        .platform = parsed.platform,
        .rootfs_storage = parsed.rootfs_storage,
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

fn importTar(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (wantsHelp(args)) {
        try stdout.writeAll(import_tar_usage);
        return;
    }
    const arena = init.arena.allocator();
    const parsed = try rootfs_mod.parseImportTarOptions(args, stdout);
    const result = try api.rootfsImportTar(init, arena, .{
        .input = parsed.input,
        .ref = parsed.ref,
        .platform = parsed.platform,
        .rootfs_storage = parsed.rootfs_storage,
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
    if (wantsHelp(args)) {
        try stdout.writeAll(resolve_usage);
        return;
    }
    const arena = init.arena.allocator();
    const parsed = try rootfs_mod.parseResolveOptions(args, stdout);
    const resolved = try api.rootfsResolve(init, arena, .{
        .ref = parsed.ref,
        .platform = parsed.platform,
    });
    try stdout.print("{s}\n", .{resolved});
}

fn casPreload(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    if (wantsHelp(args)) {
        try stdout.writeAll(cas_preload_usage);
        return;
    }
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

fn wantsHelp(args: []const []const u8) bool {
    if (args.len == 1 and std.mem.eql(u8, args[0], "help")) return true;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or
            std.mem.eql(u8, arg, "--help"))
        {
            return true;
        }
    }
    return false;
}

fn wantsTopLevelHelp(args: []const []const u8) bool {
    return args.len == 1 and wantsHelp(args);
}

test "rootfs cli help accepts standard help spellings" {
    try std.testing.expect(wantsHelp(&.{"--help"}));
    try std.testing.expect(wantsHelp(&.{"-h"}));
    try std.testing.expect(wantsHelp(&.{"help"}));
    try std.testing.expect(!wantsHelp(&.{}));
    try std.testing.expect(wantsHelp(&.{ "registry.example/repo:latest", "--help" }));
    try std.testing.expect(!wantsHelp(&.{ "help", "--output", "rootfs.ext4" }));
    try std.testing.expect(wantsTopLevelHelp(&.{"--help"}));
    try std.testing.expect(!wantsTopLevelHelp(&.{ "build", "--help" }));
    try std.testing.expect(std.mem.indexOf(u8, rootfs_mod.usage, "cas-preload") == null);
    try std.testing.expect(std.mem.indexOf(u8, rootfs_mod.usage, "import-tar") != null);
    try std.testing.expect(std.mem.indexOf(u8, cas_preload_usage, "cas-preload") != null);
}
