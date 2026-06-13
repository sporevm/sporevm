# Agent Notes

- The plan of record is `docs/plans/foundation.md`. Work in slices; keep the
  plan updated when scope, sequencing, or decisions change.
- This project is in early development: breaking changes are acceptable, and
  the spore format carries no compatibility promise before 1.0.
- Zig toolchain is pinned in `mise.toml`. Build with `mise run build`, test
  with `mise run test`. Do not float the Zig version casually; upgrades are
  deliberate, one release at a time.
- SporeVM is an isolation boundary. Read `SECURITY.md` before changing
  virtqueue parsing, manifest/chunk decoding, or guest memory access. New
  parsers of attacker-influenced data require fuzz targets in the same change.
- Machine state in spore manifests is normalized architectural aarch64 state.
  Never serialize raw KVM or Hypervisor.framework structs into the format.
- Keep the device model frozen: virtio-mmio console, blk, net, vsock, rng,
  plus the generation device. Additions require editing the foundation plan.
- Hypervisor-specific code lives behind the hypervisor interface; device
  model, DTB generation, and manifest code must stay backend-neutral and
  shared.
- Real-hardware smoke scripts live in `scripts/` and must run identically in
  CI and by hand.
