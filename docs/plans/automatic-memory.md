---
status: active
last_reviewed: 2026-07-06
spec_refs:
  - docs/memory.md
  - docs/lifecycle.md
  - docs/spore-format.md
  - src/run.zig
  - src/lifecycle.zig
---

# Automatic Memory Follow-Up

## Current Contract

The implementation has landed. Product commands use `--memory VALUE`; omitted
memory is `--memory auto`, currently a 16GiB guest-visible contract. Fresh
managed auto runs boot with a smaller fixed RAM floor and grow through a
transient virtio-mem region. Capture, resume, named lifecycle, custom-kernel,
custom-initrd, and explicit-memory paths still serialize fixed RAM.

The durable contract now lives in `docs/memory.md`, `docs/lifecycle.md`, and
`docs/spore-format.md`. `spore ls` exposes configured memory, cheap resident
stats, backing allocation, chunk counts, and dirty counters when a cheap source
exists.

## Remaining Work

- Keep KVM/HVF 16GiB auto-memory measurements current when changing capture,
  dirty tracking, virtio-mem, or lifecycle accounting.
- Design persisted virtio-mem plug/unplug capture semantics before serializing
  transient virtio-mem state into any manifest format.
- Revisit worker/tail dirty sealing only with benchmark evidence that suspend
  pause is a real limit for active-write guests.
- Raise `auto` beyond 16GiB only after fresh-run, named lifecycle, suspend, and
  fan-out evidence shows host cost stays sparse.

## Done When

- Any change to the memory contract updates `docs/memory.md` with the measured
  KVM/HVF evidence or explicitly keeps the existing 16GiB contract.
- Persisted virtio-mem state has a manifest/device-model design before code
  starts writing it.

## Non-Goals

- No host admission controller in this plan.
- No low-level harness flag rename unless a real caller needs it.
- No public virtio-mem or hotplug API.
