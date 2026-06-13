# 🍄 SporeVM

SporeVM is a virtual machine monitor for aarch64 Linux microVMs that treats a
suspended VM as a cheap, forkable object for fan-out across compatible hosts.
One Zig codebase targets two hypervisors — KVM on Linux and
Hypervisor.framework on macOS — with an identical minimal device model on both.
Cross-backend restore is useful diagnostic portability, but the primary product
path is fork/fan-out on identical host classes.

The sealed checkpoint artifact is called a **spore**: a manifest of
content-addressed memory chunks, guest machine state, and eventually disk
state. v0 spores do not capture disk bytes yet; disk-backed resume still
requires the same backing disk out of band. Spores are the unit of suspend,
fork, fan-out, and cross-backend inspection.

The target lifecycle property: no operation scales with RAM size.

- **Suspend** is a pause plus a small tail flush (~tens of ms at any RAM size)
- **Fork** is a metadata write — `spore fork --count 10000` is sub-second
- **Resume** is bounded by the working set, not memory size, on either OS

The product CLI shape is still landing. Today `spore fork` can mint child
spores from an existing spore; create, suspend, and resume are still exercised
through the backend smoke harnesses. The end-state interface is:

```console
spore create --kernel ... --disk ... my-vm
spore suspend my-vm
spore fork my-vm.spore --count 10000 --out forks/
spore pull <spore-id> && spore resume <spore-id>   # on a compatible host
```

## Status

Early development, pre-release. The plan of record is
[docs/plans/foundation.md](docs/plans/foundation.md). Current `main` boots a
pinned aarch64 Linux kernel on Hypervisor.framework to an interactive shell and
on KVM/aarch64 to an Alpine shell prompt, with the shared virtio-mmio console,
block, net, vsock, rng, and generation devices. The HVF and KVM paths can also
write/resume a v0 spore on the same host. The CLI can report current host
platform facts with `spore host-info`, summarise a spore manifest with
`spore inspect <spore-dir>`, and mint metadata-only child spores with
`spore fork <spore-dir> --count N --out DIR`.

Identical-host fork/fan-out is the priority path. The cross-hypervisor restore
matrix remains a secondary diagnostic portability track.

## Development

Tooling is pinned with [mise](https://mise.jdx.dev):

```bash
mise install
mise run build    # zig build
mise run test     # zig build test
mise exec -- zig build hvf-boot   # build/sign the HVF kernel boot harness
mise exec -- zig build hvf-gic-probe # probe HVF GICv3 portable-state support
mise exec -- zig build kvm-boot   # build the KVM kernel boot harness on Linux/aarch64
```

The `hvf-boot` and `kvm-boot` harnesses accept `--initrd root.cpio` for
diskless smoke workloads (`rdinit=/init` by default when no disk is supplied).
The smoke scripts auto-download pinned `cleanroom-kernels` assets and cache
them under the platform cache directory; pass `--kernel` or set
`SPOREVM_KERNEL_IMAGE` for local kernel experiments.
Build the tiny ticker initrd used by smoke tests with
`scripts/make-smoke-initrd.sh /tmp/sporevm-smoke.cpio`.
Run same-host restore smokes, or split cross-host capture/resume legs, with
`scripts/smoke-restore-leg.sh`.
Fork fan-out smokes use the separate SporeVM kernel asset because the
fork-aware initrd needs `/dev/mem` access to the fixed generation MMIO window:
`CC="zig cc -target aarch64-linux-musl" scripts/smoke-fork-fanout.sh --backend hvf`.
Fork an already-captured spore with
`zig-out/bin/spore fork /tmp/spore --count 100 --out /tmp/forks`; children are
named `000000`, `000001`, and so on, and share the parent's chunk store.

KVM work needs an aarch64 Linux host with KVM; Hypervisor.framework work needs
an Apple Silicon Mac on macOS 15+.

## Rootfs Images

`spore rootfs build` materializes an OCI image into a deterministic ext4 rootfs
image. Inputs may be digest-pinned refs or registry tags.

```bash
spore rootfs build ghcr.io/org/image:latest \
  --platform linux/arm64 \
  --output rootfs.ext4
```

See [docs/rootfs.md](docs/rootfs.md) for tag resolution, metadata, and ext4
tooling details.

## Security

SporeVM is an isolation boundary. Read [SECURITY.md](SECURITY.md) before
touching virtqueue parsing, manifest decoding, or guest memory access.

## License

[MIT](LICENSE)
