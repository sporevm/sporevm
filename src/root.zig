//! Internal SporeVM implementation module root.
//!
//! A spore is sealed VM state: a manifest of memory chunks, guest machine
//! state, and storage identity or data. This module
//! exposes backend, device, storage, daemon, and CLI implementation modules for
//! in-repo tools. Product callers should import `libspore`, not this module.

const builtin = @import("builtin");

pub const api = @import("api.zig");
pub const board = @import("board.zig");
pub const block_source = @import("block_source.zig");
pub const boot = @import("boot.zig");
pub const boot_harness = @import("boot_harness.zig");
pub const bundle = @import("bundle.zig");
pub const capture = @import("capture.zig");
pub const chunk = @import("chunk.zig");
pub const chunk_mapped_disk = @import("chunk_mapped_disk.zig");
pub const chunk_sealer = @import("chunk_sealer.zig");
pub const contracts = @import("contracts.zig");
pub const cow_disk = @import("cow_disk.zig");
pub const disk_layer = @import("disk_layer.zig");
pub const fd = @import("fd.zig");
pub const generation = @import("generation.zig");
pub const gicv3 = @import("gicv3.zig");
pub const fdt = @import("fdt.zig");
pub const fanout = @import("fanout.zig");
pub const guestmem = @import("guestmem.zig");
pub const host_fetch_policy = @import("host_fetch_policy.zig");
pub const lifecycle = @import("lifecycle.zig");
pub const local_paths = @import("local_paths.zig");
pub const memory = @import("memory.zig");
pub const machine_output = @import("machine_output.zig");
pub const monitor = @import("monitor.zig");
pub const monitor_jail = @import("monitor_jail.zig");
pub const net_gateway = @import("net_gateway.zig");
pub const platform = @import("platform.zig");
const dirty_ram = @import("dirty_ram.zig");
pub const hvf = @import("hvf/hvf.zig");
pub const attach_stream = @import("attach_stream.zig");
pub const attach_cli = @import("attach_cli.zig");
pub const attach_cmd = @import("attach.zig");
pub const rootfs = @import("rootfs.zig");
pub const rootfs_cache = @import("rootfs_cache.zig");
pub const rootfs_cas = @import("rootfs_cas.zig");
pub const rootfs_cli = @import("rootfs_cli.zig");
pub const disk_index = @import("disk_index.zig");
pub const run = @import("run.zig");
pub const run_cli = @import("run_cli.zig");
pub const runtime_disk = @import("runtime_disk.zig");
pub const spore_net = @import("spore_net.zig");
pub const spore_net_policy = @import("spore_net_policy.zig");
pub const spore_netd = @import("spore_netd.zig");
pub const spore_netd_tcp = @import("spore_netd_tcp.zig");
pub const spore_stream = @import("spore_stream.zig");
pub const spore = @import("spore.zig");
pub const system = @import("system.zig");
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
    pub const mem = @import("virtio/mem.zig");
    pub const vsock = @import("virtio/vsock.zig");
};

pub const version = @import("version.zig").value;

test {
    // Ensure all referenced modules' tests are discovered.
    const testing = @import("std").testing;
    testing.refAllDecls(@This());
    testing.refAllDecls(api);
    testing.refAllDecls(block_source);
    testing.refAllDecls(bundle);
    testing.refAllDecls(capture);
    testing.refAllDecls(chunk_mapped_disk);
    testing.refAllDecls(chunk_sealer);
    testing.refAllDecls(contracts);
    testing.refAllDecls(cow_disk);
    testing.refAllDecls(disk_layer);
    testing.refAllDecls(fd);
    testing.refAllDecls(fanout);
    testing.refAllDecls(generation);
    testing.refAllDecls(gicv3);
    testing.refAllDecls(host_fetch_policy);
    testing.refAllDecls(lifecycle);
    testing.refAllDecls(local_paths);
    testing.refAllDecls(memory);
    testing.refAllDecls(machine_output);
    testing.refAllDecls(monitor);
    testing.refAllDecls(monitor_jail);
    testing.refAllDecls(net_gateway);
    testing.refAllDecls(platform);
    testing.refAllDecls(dirty_ram);
    testing.refAllDecls(attach_stream);
    testing.refAllDecls(attach_cli);
    testing.refAllDecls(attach_cmd);
    testing.refAllDecls(rootfs_cache);
    testing.refAllDecls(rootfs_cas);
    testing.refAllDecls(rootfs_cli);
    testing.refAllDecls(disk_index);
    testing.refAllDecls(run);
    testing.refAllDecls(run_cli);
    testing.refAllDecls(runtime_disk);
    testing.refAllDecls(spore_net);
    testing.refAllDecls(spore_net_policy);
    testing.refAllDecls(spore_netd);
    testing.refAllDecls(spore_netd_tcp);
    testing.refAllDecls(spore_stream);
    testing.refAllDecls(system);
    testing.refAllDecls(virtio.queue);
    testing.refAllDecls(virtio.mmio);
    testing.refAllDecls(virtio.console);
    testing.refAllDecls(virtio.blk);
    testing.refAllDecls(virtio.net);
    testing.refAllDecls(virtio.rng);
    testing.refAllDecls(virtio.mem);
    testing.refAllDecls(virtio.vsock);
}
