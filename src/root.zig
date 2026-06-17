//! SporeVM library root.
//!
//! A spore is a sealed, content-addressed checkpoint of a VM: a manifest of
//! memory chunks, guest machine state, and eventually disk state. This module
//! exposes the building blocks; the `spore` CLI in `main.zig` is a thin shell
//! over them.

const builtin = @import("builtin");

pub const board = @import("board.zig");
pub const boot = @import("boot.zig");
pub const bundle = @import("bundle.zig");
pub const capture = @import("capture.zig");
pub const chunk = @import("chunk.zig");
pub const generation = @import("generation.zig");
pub const gicv3 = @import("gicv3.zig");
pub const fdt = @import("fdt.zig");
pub const fdpass = if (builtin.os.tag == .linux)
    @import("fdpass.zig")
else
    struct {};
pub const fanout = @import("fanout.zig");
pub const guestmem = @import("guestmem.zig");
pub const lifecycle = @import("lifecycle.zig");
pub const local_paths = @import("local_paths.zig");
pub const monitor = @import("monitor.zig");
pub const platform = @import("platform.zig");
const dirty_ram = @import("dirty_ram.zig");
pub const hvf = @import("hvf/hvf.zig");
pub const resume_cmd = @import("resume.zig");
pub const rootfs = @import("rootfs.zig");
pub const run = @import("run.zig");
pub const spore = @import("spore.zig");
pub const kvm = if (builtin.os.tag == .linux and builtin.cpu.arch == .aarch64)
    @import("kvm/kvm.zig")
else
    struct {};
pub const virtio = struct {
    pub const queue = @import("virtio/queue.zig");
    pub const mmio = @import("virtio/mmio.zig");
    pub const console = @import("virtio/console.zig");
    pub const blk = @import("virtio/blk.zig");
    pub const net = @import("virtio/net.zig");
    pub const rng = @import("virtio/rng.zig");
    pub const vsock = @import("virtio/vsock.zig");
};

pub const version = "0.0.0";

test {
    // Ensure all referenced modules' tests are discovered.
    const testing = @import("std").testing;
    testing.refAllDecls(@This());
    testing.refAllDecls(bundle);
    testing.refAllDecls(capture);
    testing.refAllDecls(fdpass);
    testing.refAllDecls(fanout);
    testing.refAllDecls(generation);
    testing.refAllDecls(gicv3);
    testing.refAllDecls(lifecycle);
    testing.refAllDecls(local_paths);
    testing.refAllDecls(monitor);
    testing.refAllDecls(platform);
    testing.refAllDecls(dirty_ram);
    testing.refAllDecls(resume_cmd);
    testing.refAllDecls(run);
    testing.refAllDecls(virtio.queue);
    testing.refAllDecls(virtio.mmio);
    testing.refAllDecls(virtio.console);
    testing.refAllDecls(virtio.blk);
    testing.refAllDecls(virtio.net);
    testing.refAllDecls(virtio.rng);
    testing.refAllDecls(virtio.vsock);
}
