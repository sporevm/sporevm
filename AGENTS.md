# Agent Notes

- Durable contracts live in `docs/`. Active follow-up plans live in
  `docs/plans/`; update the relevant plan when scope, sequencing, or decisions
  change.
- SporeVM is still evolving, but post-1.0 user-facing and format changes should
  be deliberate, documented, and reflected in release notes.
- Zig toolchain is pinned in `mise.toml`. Build with `mise run build`, test
  with `mise run test`. Do not float the Zig version casually; upgrades are
  deliberate, one release at a time.
- Amp Orbs can open a development shell on the managed Linux ARM64, Linux
  x86_64, or macOS host with `.agents/ssm-sporevm arm64|x86_64|macos`.
- SporeVM is an isolation boundary. Read `SECURITY.md` before changing
  virtqueue parsing, manifest/chunk decoding, or guest memory access. New
  parsers of attacker-influenced data require fuzz targets in the same change.
- Machine state in spore manifests is normalized architectural aarch64 state.
  Never serialize raw KVM or Hypervisor.framework structs into the format.
- Keep the device model frozen: virtio-mmio console, blk, net, vsock, rng,
  plus the generation device. Additions require updating `docs/spore-format.md`,
  `SECURITY.md`, and the relevant durable design doc.
- Hypervisor-specific code lives behind the hypervisor interface; device
  model, DTB generation, and manifest code must stay backend-neutral and
  shared.
- Real-hardware smoke scripts live in `scripts/` and must run identically in
  CI and by hand.
