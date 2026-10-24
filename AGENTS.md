# Agent Notes

- Durable contracts live in `docs/`. Active follow-up plans live in
  `docs/plans/`; update the relevant plan when scope, sequencing, or decisions
  change.
- SporeVM is still evolving, but post-1.0 user-facing and format changes should
  be deliberate, documented, and reflected in release notes.
- Zig toolchain is pinned in `mise.toml`. Build with `mise run build`, test
  with `mise run test`. Do not float the Zig version casually; upgrades are
  deliberate, one release at a time.
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

## Amp orbs

- `.agents/setup` prepares a fresh orb: system packages, the `mise`-pinned
  tools for this checkout and for every sibling checkout under
  `../repos/<name>`, and a warm Debug build. Keep it idempotent and under two
  minutes on a warm snapshot.
- Sibling checkouts (`zmoltcp`, `kernels`, `examples`, `k8s`) are independent
  Git repositories. Run Git, builds, and tests from the repository that owns a
  change, and keep cross-repository changes as separate branches and commits.
- Orbs have no `/dev/kvm` or Hypervisor.framework. Expect test steps that need
  a hypervisor (`libspore-c-smoke`, tests that reach `requireProductRunner`,
  all `test/smoke/`) to fail or skip there. When `ssm-sporevm` is on `PATH`,
  `ssm-sporevm arm64|x86_64|macos` opens a shell on a managed host with real
  hardware for those.
