//! SporeVM library root.
//!
//! A spore is a sealed, content-addressed checkpoint of a VM: a manifest of
//! memory and disk chunks plus a small normalized machine-state blob. This
//! module exposes the building blocks; the `spore` CLI in `main.zig` is a
//! thin shell over them.

pub const board = @import("board.zig");
pub const boot = @import("boot.zig");
pub const chunk = @import("chunk.zig");
pub const generation = @import("generation.zig");
pub const spore = @import("spore.zig");
pub const fdt = @import("fdt.zig");
pub const guestmem = @import("guestmem.zig");
pub const hvf = @import("hvf/hvf.zig");
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
    testing.refAllDecls(generation);
    testing.refAllDecls(virtio.queue);
    testing.refAllDecls(virtio.mmio);
    testing.refAllDecls(virtio.console);
    testing.refAllDecls(virtio.blk);
    testing.refAllDecls(virtio.net);
    testing.refAllDecls(virtio.rng);
    testing.refAllDecls(virtio.vsock);
}
