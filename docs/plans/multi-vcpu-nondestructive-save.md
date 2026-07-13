---
status: landed
last_reviewed: 2026-07-13
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

## Completed Evidence

The opt-in named block in `test/smoke/fanout/multi-vcpu.sh` now covers both
image-created writable rootfs and explicit `--rootfs PATH` sources. Each case
writes `captured`, saves without `--stop`, writes `continued` in the still-live
source, removes that source, restores the saved spore, and requires the restored
disk to contain `captured`. The same run keeps the existing fresh boot, v3
capture, run-from, attach, live workload, fork, stopped-save, inspect, and
restore checks enabled.

One native engineering sample per source recorded the complete pause through
snapshot and durable named publication. These are smoke measurements, not a
latency distribution:

| Backend | Source | RAM | Snapshot total | Source pause |
| --- | --- | ---: | ---: | ---: |
| ARM64 KVM | image-created rootfs | 512 MiB | 2,535 ms | 2,603 ms |
| ARM64 KVM | explicit rootfs | 512 MiB | 4,759 ms | 4,827 ms |
| ARM64 KVM | default auto | 16 GiB | 69,878 ms | 69,894 ms |
| HVF | image-created rootfs | 512 MiB | 1,205 ms | 1,238 ms |
| HVF | explicit rootfs | 512 MiB | 2,087 ms | 2,118 ms |
| HVF | default auto | 16 GiB | 29,729 ms | 29,740 ms |

The KVM run used the full named lifecycle block on native ARM64. The HVF run
and the ordinary Linux/macOS test graph passed in
[Buildkite #1349](https://buildkite.com/buildkite/sporevm/builds/1349) against
the exact preflight snapshot. The job retains the raw output, parsed snapshot
and publication records, and source identity as artifacts.

## Done When

- `test/smoke/fanout/multi-vcpu.sh` covers disk-backed multi-vCPU
  non-destructive save point-in-time behavior.
- KVM and HVF pause numbers are recorded in the PR or a durable docs note.
- KVM named lifecycle smoke passes with the multi-vCPU non-destructive save
  block enabled.

All criteria are complete. The existing named-live block also proves that the
source and restored copy can run side by side, so no further concurrent-source
work is required for this follow-up.

## Key Learnings From Pressure-Testing

- macOS native jobs must keep `SPORE_SMOKE_RUNTIME_ROOT` short because named VM
  control sockets have a 103-byte path limit; evidence caches can remain under
  the job workspace.
- `source_pause_ms` is the user-visible save interruption because it includes
  snapshot work and durable publication. `snapshot_total_ms` alone understates
  the pause.
- The sparse default 16GiB guest avoids 16GiB of resident host memory, but its
  current full memory scan still dominates save pause. Dirty-tracking
  acceleration remains outside this correctness follow-up.

## Non-Goals

- No manifest format change.
- No new backend gate keyed on the lifecycle `backend` string; default named
  VMs record `"auto"`.
- No dirty-tracking-accelerated multi-vCPU capture in this follow-up.
