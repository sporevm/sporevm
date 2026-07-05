---
status: active
last_reviewed: 2026-07-04
spec_refs:
  - docs/fanout.md
  - docs/lifecycle.md
  - docs/spore-format.md
  - docs/state-portability.md
  - SECURITY.md
  - src/spore.zig
  - src/lifecycle.zig
  - src/hvf/vm.zig
  - src/kvm/vm.zig
  - src/run.zig
  - src/attach.zig
related_plans:
  - docs/plans/multi-vcpu.md
  - docs/plans/automatic-local-ram-backing.md
---

# Multi-vCPU Fork and Fan-Out

## Summary

SporeVM can boot, capture, inspect, run-from, resume, fork, and named-fork
multi-vCPU spores through manifest v1. Fork remains N-to-N: a source captured
with N vCPUs mints children with the same vCPU count and topology.

Fork rewrites only child identity, generation counters, generation params, and
the generation interrupt state needed for the guest agent to observe the child
identity. It does not downshift an already-booted guest to a different CPU
topology.

## Problem

Cleanroom and Buildkite use warm spores as fan-out bases. The old guidance was
to leave `resources.vcpus` unset for fan-out bakes, which kept fork working but
was surprising because dependency installation and build-time warmup are where
extra CPUs help.

The former implementation had an explicit v1 stop: `src/spore.zig` parsed v0
first, recognized valid manifest v1 only to reject it, and returned
`UnsupportedVcpuCount`. Named live fork had the same product limit in
`src/lifecycle.zig`: it rejected `vcpus != 1`, and child monitor startup
hardcoded `.vcpus = 1`.

## Current State

Already handles N vCPUs outside fork:

- Fresh KVM and HVF runs create multi-vCPU guests.
- Suspend, `run --from`, and resume restore manifest v1 captures on compatible
  backends.
- Manifest v1 records `platform.vcpu_count`, stable per-vCPU `index`/`mpidr`
  state, per-vCPU timer/ICC/sysreg state, and multi-vCPU GIC state.
- `inspectSpore` accepts both v0 and v1 and reports the vCPU count.
- Bundle, pull, and local materialization preserve v1 manifests.
- Product restore can use proof-validated local backing for valid vCPU counts
  and falls back to verified chunks when proofs are missing or stale.

Fork-specific support now in place:

- `spore.fork` dispatches to a v0 or v1 child minting path based on the source
  manifest.
- v1 fork preserves all vCPU state, `platform.vcpu_count`, chunks, optional
  disk/rootfs metadata, annotations, network metadata, and sessions.
- Portable `gicv3_multi` state gets a child generation SPI line asserted as a
  global line.
- HVF `backend_private` GIC state is preserved unchanged; HVF resume already
  raises the generation SPI from generation-device state after applying the
  backend-private GIC blob.
- Named live fork snapshots multi-vCPU diskless sources with
  snapshot-and-continue, mints v1 children, and starts child monitors with the
  child manifest's vCPU count.
- v1 fork children keep proof-validated local `ram.backing` acceleration and
  fall back to chunks if the parent proof cannot be trusted.

Still out of scope:

- Disk-backed or networked named live fork.
- Cross-backend portability beyond the existing manifest v1 rules.
- N-to-1 fork/downshift of an already-booted guest.

## Target Model

Direct fan-out is N-to-N:

```bash
spore run --vcpus 4 --save warm.spore -- ./warmup
spore fork warm.spore --count 20 --out children/
spore fanout children/
```

Each child is a manifest v1 spore with `platform.vcpu_count == 4` and the same
normalized vCPU topology as the source. Child memory chunks are shared by
reference just like v0. Child resume state differs only where fork already has
semantics: generation count, fork indexes, batch id, VM id, hostname, MAC seed,
MAC address, resume-time entropy, and the generation interrupt signal.

Named live fork preserves the same count:

```bash
spore create warm --vcpus 4 --image docker.io/library/alpine:3.20 ./warmup
spore fork --vm warm --count 20 --name worker-%02d
```

## Memory Sharing

Chunks are topology-neutral. A v1 child can share the parent's chunk directory
exactly as v0 children do because chunk refs describe RAM bytes, not which vCPU
dirtied them.

Local `ram.backing` is an optimization, not the portable contract. Fork keeps it
only when the parent backing proof validates under the current runtime trust
key. Each child receives a hardlink to the parent backing plus a child-local
proof; any missing, stale, foreign, or unprovable backing drops to verified
chunks before the child manifest is written.

The first implementation briefly treated multi-vCPU local backing as a later
slice, because an older HVF note warned that map-private backing restore could
stall without smoke coverage. That restriction is lifted here after exercising
multi-vCPU fork, `run --from`, named fork, suspend, inspect, and resume on HVF.

## Downshift Decision

Cleanroom's narrow need could be phrased as "bake with N vCPUs, run one-vCPU
children", but that is not the smallest safe first slice. A suspended Linux
guest has already observed an N-vCPU topology through DTB, MPIDRs, scheduler
state, interrupts, and per-CPU kernel data. Dropping secondary vCPU state or
resuming with a different topology can hang or corrupt the restored workload
unless the guest cooperates.

N-to-1 remains a separate candidate only if a later proof defines a safe warm
base contract, such as an explicit guest offlining/quiesce step before capture.

## Delivery Record

### Slice 1: Clean Failure and Documentation

Implemented a clean one-line CLI error for unsupported multi-vCPU fork paths
while the restriction existed, suppressed misleading manifest parse fallback
noise, documented the temporary limitation, and added an exact smoke assertion.

That slice has been superseded by the full implementation, but the CLI still
keeps the cleaner error handling for any future unsupported fork state.

### Slice 2: Direct v1 N-to-N Fork

Implemented direct v1 child minting for portable `gicv3_multi` state. The child
manifest preserves vCPU state and topology, shares chunks and disk stores,
rewrites generation identity, and asserts the generation SPI as a global line.

### Slice 3: HVF Backend-Private GIC

Implemented same-host HVF support by preserving `backend_private` GIC state and
relying on the existing HVF resume hook that raises the generation SPI after
generation-device restore. This avoids parsing or mutating raw HVF GIC blobs in
the manifest layer.

### Slice 4: Named Live Fork

Removed the named source vCPU guard, taught child startup to read v0 or v1
children, and started child monitors with the child manifest's vCPU count.
Multi-vCPU HVF and KVM run loops now support live snapshot-and-continue by
pausing all vCPUs, writing the v1 snapshot, publishing the monitor response,
and resuming the source VM.

### Slice 5: Local Backing Acceleration

Lifted the local backing proof opener to validated vCPU counts and reused the
existing fork backing hardlink/proof flow for v1 children. Children still fail
closed to chunks when proof validation or proof writing fails.

## Validation

- Unit tests cover v1 child manifest minting, generation params, portable GIC
  interrupt mutation, HVF backend-private preservation, multi-vCPU local backing
  proof opening, and v1 child backing hardlinks/proofs.
- `scripts/smoke-multi-vcpu.sh` covers direct v1 fork, child `run --from`,
  v1 inspect, resume, and optional named lifecycle.
- `SPORE_SMOKE_NAMED_LIFECYCLE=1 scripts/smoke-multi-vcpu.sh` covers
  multi-vCPU `spore fork --vm`, child readiness, child exec, named suspend,
  inspect, named resume, and post-resume exec on HVF.
- KVM should run the same smoke on the ARM64 CI host before landing if CI
  capacity is available.

## Key Learnings

- N-to-N was smaller and safer than N-to-1 because it preserves guest-visible
  topology after boot.
- HVF did not need manifest-layer mutation of backend-private GIC state; the
  existing post-restore generation interrupt raise is the right backend-owned
  boundary.
- Local backing remains an optimization. Keeping the chunk fallback path as the
  source of truth makes backing proof failure safe for fork children.
