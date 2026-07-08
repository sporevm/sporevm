---
status: active
last_reviewed: 2026-07-06
spec_refs:
  - docs/lifecycle.md
  - docs/state-portability.md
  - test/smoke/fanout/multi-vcpu.sh
  - test/smoke/rootfs/writable.sh
  - src/lifecycle.zig
---

# Multi-vCPU Non-Destructive Save Follow-Up

## Current Contract

The feature itself has landed. `spore save NAME --out DIR` keeps a named VM
running for single-vCPU and multi-vCPU guests on supported KVM and HVF hosts.
The durable user contract now lives in `docs/lifecycle.md`; backend portability
lives in `docs/state-portability.md`.

The implementation removed the lifecycle-level `vcpus != 1` guard in
`saveContinueNamed`, keeps the atomic temp-sibling publish path, and still
fails closed instead of silently falling back to `--stop`.

## Remaining Work

- Add a disk-backed non-destructive save smoke for image-created writable rootfs
  and explicit `--rootfs PATH`: save, write more data after the save, restore
  the saved spore, and assert restore sees the point-in-time disk contents.
- Record pause-duration measurements for a small explicit-memory guest and the
  default `--memory auto` 16GiB case on HVF and ARM64 KVM.
- Re-run the named multi-vCPU smoke on real ARM64 KVM with
  `SPORE_SMOKE_NAMED_LIFECYCLE=1 mise run smoke:multi-vcpu`.
- Investigate concurrent active-source restore only if a product workflow needs
  source and restored copies of the same live workload running side by side.

## Done When

- `test/smoke/rootfs/writable.sh` or a focused sibling covers disk-backed
  multi-vCPU non-destructive save point-in-time behavior.
- KVM and HVF pause numbers are recorded in the PR or a durable docs note.
- KVM named lifecycle smoke passes with the multi-vCPU non-destructive save
  block enabled.

## Non-Goals

- No manifest format change.
- No new backend gate keyed on the lifecycle `backend` string; default named
  VMs record `"auto"`.
- No dirty-tracking-accelerated multi-vCPU capture in this follow-up.
