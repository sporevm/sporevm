# 🍄 SporeVM

SporeVM is a virtual machine monitor for aarch64 Linux microVMs that treats a
suspended VM as a cheap, portable, forkable object. One Zig codebase targets
two hypervisors — KVM on Linux and Hypervisor.framework on macOS — with an
identical minimal device model on both, so a VM suspended on one host can
resume on the other.

The sealed checkpoint artifact is called a **spore**: a manifest of
content-addressed memory and disk chunks plus a small normalized machine-state
blob. Spores are the unit of suspend, fork, fan-out, and cross-platform
transfer.

The defining design property: no lifecycle operation scales with RAM size.

- **Suspend** is a pause plus a small tail flush (~tens of ms at any RAM size)
- **Fork** is a metadata write — `spore fork --count 10000` is sub-second
- **Resume** is bounded by the working set, not memory size, on either OS

```console
spore create --kernel ... --disk ... my-vm
spore suspend my-vm
spore fork my-vm --count 10000
spore pull <spore-id> && spore resume <spore-id>   # on a different OS
```

## Status

Early development, pre-release. The plan of record is
[docs/plans/foundation.md](docs/plans/foundation.md). Current `main` boots a
pinned aarch64 Linux kernel on Hypervisor.framework to an interactive shell and
on KVM/aarch64 to an Alpine shell prompt, with the shared virtio-mmio console,
block, net, vsock, rng, and generation devices. The HVF and KVM paths can also
write/resume a v0 spore on the same host.

The cross-hypervisor restore matrix is still pending.

## Development

Tooling is pinned with [mise](https://mise.jdx.dev):

```bash
mise install
mise run build    # zig build
mise run test     # zig build test
mise exec -- zig build hvf-boot   # build/sign the HVF kernel boot harness
mise exec -- zig build kvm-boot   # build the KVM kernel boot harness on Linux/aarch64
```

KVM work needs an aarch64 Linux host with KVM; Hypervisor.framework work needs
an Apple Silicon Mac on macOS 15+.

## Security

SporeVM is an isolation boundary. Read [SECURITY.md](SECURITY.md) before
touching virtqueue parsing, manifest decoding, or guest memory access.

## License

[MIT](LICENSE)
