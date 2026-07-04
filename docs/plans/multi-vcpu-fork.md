---
status: proposed
last_reviewed: 2026-07-04
spec_refs:
  - docs/fanout.md
  - docs/lifecycle.md
  - docs/spore-format.md
  - docs/state-portability.md
  - SECURITY.md
  - src/spore.zig
  - src/lifecycle.zig
  - src/run.zig
  - src/resume.zig
related_plans:
  - docs/plans/multi-vcpu.md
  - docs/plans/automatic-local-ram-backing.md
---

# Multi-vCPU Fork and Fan-Out

## Summary

SporeVM can already boot, capture, inspect, run-from, and resume multi-vCPU
spores through manifest v1. Fork/fan-out is the remaining gap: `spore fork`
still mints only manifest v0 children, and named live fork rejects multi-vCPU
sources before snapshotting.

The target outcome is boring: a source captured with N vCPUs can produce N-vCPU
children with the same process, memory, device, and topology state, while fork
continues to rewrite only child identity and generation-device state. Until that
is true, users should bake fan-out sources with one vCPU.

## Problem

Cleanroom and Buildkite use warm spores as fan-out bases. The current guidance
is to leave `resources.vcpus` unset for fan-out bakes, which keeps fork working
but is surprising because dependency installation and build-time warmup are the
phase where extra CPUs help.

The implementation has an explicit v1 stop. `src/spore.zig` tries manifest v0
first, recognizes valid manifest v1 only to reject it, and returns
`UnsupportedVcpuCount` before child directories are written. Named live fork has
the same product limit in `src/lifecycle.zig`: it checks the source VM spec and
rejects `vcpus != 1`; the child monitor start path also hardcodes `.vcpus = 1`.

## Current State

Already handles N vCPUs:

- Fresh KVM and HVF runs create multi-vCPU guests.
- Suspend, `run --from`, and resume restore manifest v1 captures on compatible
  backends.
- Manifest v1 records `platform.vcpu_count`, stable per-vCPU `index`/`mpidr`
  state, per-vCPU timer/ICC/sysreg state, and multi-vCPU GIC state.
- `inspectSpore` accepts both v0 and v1 and reports the vCPU count.
- Bundle, pull, and local materialization preserve v1 manifests.
- Product restore can fall back to verified chunks for multi-vCPU spores.

Still fork-specific:

- `spore.fork` copies only the v0 `Manifest` shape.
- `forkGicState` only knows how to reassert the generation interrupt in v0
  `gicv3` state.
- HVF v1 can carry `backend_private` GIC state, which cannot be safely edited by
  the manifest-level fork helper today.
- Local `ram.backing` acceleration is intentionally single-vCPU until backend
  smoke coverage proves multi-vCPU mappings.
- Named fork starts child monitors with `.vcpus = 1`.

## Goals

- Support direct `spore fork <v1-spore> --count N --out DIR` for N-to-N
  children.
- Preserve source chunks and optional disk/rootfs metadata exactly as v0 fork
  does.
- Rewrite only child identity, generation counter, generation params, and the
  interrupt state needed for the guest agent to observe new identity.
- Keep unsupported GIC forms, backend combinations, and local backing shapes
  fail-closed before writing partial child state.
- Extend named live fork only after direct v1 child minting and resume/fan-out
  validation are solid.

## Non-Goals

- No mixed-topology fork in the first full slice.
- No public downshift option until restoring an N-vCPU Linux guest with fewer
  vCPUs is proven safe.
- No local `ram.backing` fast path for multi-vCPU children until KVM and HVF
  smoke cover it.
- No cross-backend portability expansion beyond the existing manifest v1 rules.

## Target Model

The main contract is N-to-N:

```bash
spore run --vcpus 4 --capture warm.spore -- ./warmup
spore fork warm.spore --count 20 --out children/
spore fanout children/ --parallel
```

Each child remains a manifest v1 spore with `platform.vcpu_count == 4` and the
same normalized vCPU topology as the source. Child memory chunks are shared by
reference just like v0. Child resume state differs only where fork already has
semantics: generation count, fork indexes, batch id, VM id, hostname, MAC seed,
MAC address, resume-time entropy, and the generation interrupt line.

Named live fork should eventually preserve the same source vCPU count:

```bash
spore create warm --vcpus 4 --image docker.io/library/alpine:3.20 ./warmup
spore fork --vm warm --count 20 --name worker-%02d
```

## Memory Sharing Implications

Chunks are already topology-neutral. A v1 child can share the parent's chunk
directory exactly as v0 children do because chunk refs describe RAM bytes, not
which vCPU dirtied them.

Local `ram.backing` is different. The current product docs restrict automatic
local backing restore to single-vCPU manifests; multi-vCPU restore uses verified
chunks. The first v1 fork slice should therefore omit backing metadata from
multi-vCPU children and rely on chunks. Reintroduce local backing only after
`openProvenLocalMemoryBackingForVcpuCount` and backend mapping have explicit
KVM and HVF fork/fan-out smoke coverage.

## Candidate Downshift Slice

Cleanroom's narrow need is "bake with N vCPUs, run one-vCPU children." That is
tempting but not obviously cheaper. A suspended Linux guest has already observed
an N-vCPU topology through DTB, MPIDRs, scheduler state, interrupts, and per-CPU
kernel data. Dropping secondary vCPU state or resuming the same guest with a
different topology can hang or corrupt the restored workload unless the guest
cooperates.

Keep N-to-1 as a candidate only if a later proof shows a safe warm-base
contract, such as an explicit guest offlining/quiesce step before capture. That
would be a separate mode with its own validation, not a shortcut inside normal
process-state fork.

## Delivery Strategy

### Slice 1: Direct v1 N-to-N fork for portable GIC

Teach `spore.fork` to mint manifest v1 children when the source uses portable
`gicv3_multi` state. Share chunks, drop local backing metadata, copy all vCPU
states, rewrite generation identity, and update the generation interrupt as a
global SPI. Keep HVF `backend_private` GIC rejected with the current clean CLI
message.

Done when:

- a KVM v1 source forks into v1 children with matching `vcpu_count`;
- `spore run --from children/000000 -- /bin/true` works;
- `spore fanout children/ --parallel` works for a small count;
- malformed or unsupported v1 GIC state fails before child directories are
  written.

### Slice 2: HVF backend-private GIC fork support or portable HVF GIC

Either produce portable `gicv3_multi` state for HVF captures or add a narrow
backend-owned helper that can update the tagged HVF GIC blob for the generation
interrupt without exposing raw HVF structs in the manifest contract.

Done when HVF v1 sources can fork and resume children on the same host, and KVM
continues to reject HVF-private state before VM mutation.

### Slice 3: Named live fork

Remove the named fork vCPU guard after direct v1 fork is proven. Start child
monitors with the source spec's vCPU count instead of hardcoded `1`, and keep
disk/network restrictions unchanged unless separate plans lift them.

Done when `spore fork --vm` works for a diskless multi-vCPU named source and
every child reaches monitor readiness with the same vCPU count.

### Slice 4: Local backing acceleration

Re-enable local `ram.backing` metadata for multi-vCPU fork children only after
the backing proof and backend map-private restore path have direct fan-out smoke
coverage on KVM and HVF.

Done when multi-vCPU children can choose `local_backing` with proof validation
and fall back to chunks on missing, stale, or foreign proofs.

## Verification

- Unit tests for v1 child manifest minting, generation params, GIC interrupt
  mutation, rejection before partial writes, and backing metadata omission.
- `scripts/smoke-multi-vcpu.sh` extended to fork and fan out a v1 source.
- KVM smoke on the ARM64 CI host for direct fork, `run --from`, `resume`, and
  fan-out.
- HVF smoke on Apple Silicon for the same cases once HVF GIC support lands.
- Negative smoke for unsupported HVF-private or malformed v1 GIC state until
  that slice lands.

## Key Learnings From Pressure-Testing

- The first useful implementation should be N-to-N, not N-to-1. Downshift looks
  smaller but changes guest-visible topology after the guest has booted.
- Local backing is an optimization, not the fork contract. Chunks are the
  smallest safe first path for multi-vCPU children.
- HVF `backend_private` GIC state is the risky part. The plan keeps it out of
  Slice 1 so portable KVM v1 fork can land without smuggling raw backend state
  into the manifest layer.
