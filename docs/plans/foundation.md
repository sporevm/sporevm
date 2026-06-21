---
status: active
last_reviewed: 2026-06-21
related_plans:
  - buildkite/cleanroom: docs/plans/sandbox-suspend-wake.md
  - docs/plans/run-bridge.md
  - docs/plans/lifecycle-monitor.md
  - docs/plans/local-image-ref-cache.md
  - docs/plans/immutable-rootfs-resume.md
  - docs/plans/distribution.md
  - docs/plans/writable-disk-layers.md
  - docs/plans/automatic-memory.md
  - docs/plans/automatic-local-ram-backing.md
---

# SporeVM Foundation Plan

## Summary

SporeVM is a virtual machine monitor for aarch64 Linux microVMs that treats a
suspended VM as a cheap, forkable object for fan-out across compatible hosts.
One codebase targets KVM on Linux and Hypervisor.framework (HVF) on macOS with
the same minimal virtio-mmio device model.

The release-critical path is identical-host-class fork/fan-out. Cross-backend
restore is useful diagnostic portability, but it must not distract from the
product claim: suspend, fork, distribute, and resume VM state without a
suspend-time full-RAM scan in the caught-up path. Active write pressure still
creates a dirty tail; the release bar is to measure and bound that tail rather
than implying arbitrary write-heavy guests can suspend in constant time.

The target lifecycle property is:

- suspend: pause vCPUs, flush the current dirty epoch, serialize machine state;
- fork: write metadata and assign child identity;
- resume: materialize only the working set, then fault or prefetch the tail;
- fan-out: distribute content-addressed artifacts through caches or peers rather
  than asking every destination to fetch the same bytes from origin.

SporeVM is standalone. Cleanroom is the first expected consumer through a backend
adapter, but this repository owns the VMM, spore format, local rootfs utility,
chunk/cache mechanics, and CLI.

## Goals

- Boot a pinned aarch64 Linux kernel under KVM and HVF from one codebase.
- Keep the device model small and backend-neutral: virtio-mmio console, blk, net,
  vsock, rng, plus the generation MMIO device.
- Define a versioned spore manifest whose machine state is architectural, not
  raw KVM or HVF structs.
- Prove same-backend suspend/restore, fork, lazy restore, and same-host RAM
  sharing on KVM and HVF.
- Prove identical-host fan-out distribution with content verification and bounded
  origin egress.
- Make dirty tracking continuous enough that caught-up suspend latency is
  independent of configured RAM size, while active-write suspend latency is
  measured against dirty working set and unsealed chunks.
- Keep failure modes explicit and fail closed when the platform contract, disk
  artifact, memory chunks, or backend support are insufficient.

## Non-Goals

- x86 hosts or guests on the portable path.
- Non-Linux guests, GUI, GPU, USB, PCI, hotplug, or device expansion beyond the
  frozen model.
- Live migration of a running VM.
- Network policy, secrets, workspace semantics, or OCI runtime policy. Consumers
  own those layers.
- Preserving open TCP connections across cross-host resume.
- Public-cloud multi-tenant hardening claims before there is a jail and release
  posture that justifies them.
- Backwards compatibility before 1.0.

## Target Model

Target-state `spore` is one binary with CLI subcommands and a local monitor
protocol:

```console
spore run --image ruby-demo --capture ruby-base.spore -- /bin/true
spore run --from ruby-base.spore -- ruby /demo/counter.rb
spore run --image ruby-demo --capture ruby-counter.spore --capture-on USR1 -- ruby /demo/counter.rb
spore fork ruby-counter.spore --count 10000 --out forks/
spore fanout forks/ --parallel --for 20s

spore create bench-1 --image docker.io/library/node:22-alpine
spore exec bench-1 -- /bin/sh -lc 'node -v'
spore suspend bench-1 --out bench-1.spore
spore resume bench-1.spore --name bench-2
```

The spore manifest contains:

```text
spore manifest
|-- platform contract: arch, CPU profile, device model, RAM/GIC layout,
|   counter frequency
|-- machine state: vCPU, timer, GIC/ICC, virtio transport, generation device
|-- memory: ordered BLAKE3 chunk refs, zero-elided, optional same-host backing
|-- optional immutable rootfs artifact: digest, size, virtio-blk binding,
|   OCI provenance
`-- optional writable root disk chain: immutable rootfs base plus sealed
    content-addressed disk layers
```

General block-device state is still outside v0. A verified immutable rootfs
artifact can be recorded and reattached for product resume, and rootfs-bound
writable state can now be represented as sealed disk layers. Bundle/pull
materialization carries those rootfs-bound disk layers by content digest.

## Current Status

| Area | Status | Next work |
| --- | --- | --- |
| Slice 0: scaffolding | Landed | None. |
| Slice 1: KVM boot | Complete for the foundation target | Continue using KVM hardware smokes for regressions. |
| Slice 2: HVF boot | Complete for the foundation target | Continue using Apple Silicon smokes for regressions. |
| Product run bridge | Landed | See `docs/plans/run-bridge.md`; future OCI/writable policy is out of this plan. |
| Named lifecycle | Local HVF landed; KVM create/exec/ls/rm parity landed | Speed work including local image ref caching, KVM suspend/resume evidence, and disk-backed lifecycle resume; see `docs/plans/lifecycle-monitor.md`. |
| Slice 3: same-backend suspend/restore | Complete for KVM and HVF | Keep writable disk product smoke coverage as regression evidence. |
| Slice 4: fork and generation protocol | Complete for correctness | `/run/sporevm` is the live metadata contract; keep fan-out identity smokes as regression coverage. |
| Slice 5: same-host RAM and lazy restore | Complete for primary KVM/HVF proofs | Product monitor wiring, readahead, KVM pager hardening, larger macOS scale runs. |
| Slice 6: identical-host distribution | Active | Remote push/pull materialization, remote cache reuse metrics, and measured origin-egress efficiency beyond explicit relay trees. |
| Writable disk layers | Complete for the first product target | See `docs/plans/writable-disk-layers.md`; local layered COW restore, fork divergence, bundle/pull materialization, same-class remote KVM proof, corrupt disk-object rejection, warm remote cache reuse, and first KVM benchmark guardrails are implemented. |
| Slice 7: always-on dirty tracking | Complete for the foundation target | Keep dirty-tail and worker-stop benchmarks as release regressions; tune worker preemption only if the product SLO tightens. |
| Automatic memory | Active | Product CLI memory contract is moving through `docs/plans/automatic-memory.md`; automatic local backing provenance is tracked in `docs/plans/automatic-local-ram-backing.md`; next user-visible work is `spore ls` memory stats. |
| Slice 8: cross-backend diagnostic restore | Later diagnostic | HVF portable GIC producer and timer-frequency strategy. |

## Landed Foundation Capabilities

- Zig 0.16.0 is pinned through `mise`; `mise run check` runs unit tests, build,
  and diff hygiene.
- KVM and HVF boot the same board/device model, including virtio-mmio console,
  blk, net, vsock, rng, and generation devices.
- `src/spore.zig` and `docs/spore-format.md` define manifest v0 with
  content-addressed RAM chunks, normalized one-vCPU machine state, timer state,
  GIC/ICC state, virtio transport state, generation state, optional same-host RAM
  backing, and optional immutable rootfs artifact identity.
- Same-host diskless restore passes on KVM and HVF through the backend smokes.
- `spore fork` mints metadata-only child spores, increments generation, injects
  child identity and volatile resume fields, and preserves shared chunks.
- Same-host file-backed RAM sharing and lazy restore have proof paths on KVM and
  HVF. Trusted backing remains a same-host acceleration hint; chunks remain the
  portable verified source of truth.
- `spore pack`, `spore unpack`, local `spore pull file://...`, S3
  `spore push`/digest-pinned `spore pull`, and digest-pinned HTTP(S) peer
  `spore pull` provide the first distribution bundle shape with rootfs artifact
  inclusion, rootfs-bound writable disk layer inclusion, multi-child indexes,
  `bundle_digest` for cache identity, origin/peer/cache byte reporting, and
  per-chunk/per-artifact verification for trust.
- `spore run`, product `spore resume`, and `spore fanout` provide the first
  user-facing run/capture/fork/resume/fan-out path.
- `spore system df` and `spore system prune` provide local rootfs cache
  inspection and explicit cleanup, with human output by default and `--json`
  for automation.

Historical benchmark numbers are intentionally kept out of this plan now that
the mechanisms have landed. Regenerate current evidence with the scripts in
`scripts/` when making a performance or release claim.

## Active Slice 6: Identical-Host Fan-Out Distribution

Slice 6 starts from chunkpack bundles and remote restore smokes. Current
implementation and evidence include:

- local pack/unpack and `file://` pull materialization with canonical
  `bundle_digest`;
- S3 `spore push` and digest-pinned `spore pull` for indexed bundles;
- two-host S3/SSM restore;
- host-local cache reuse with repeated destination restores;
- direct-S3 repeated-child pulls with remote bundle, chunk, rootfs, and origin
  byte metrics;
- remote smoke harness support for source-peer HTTP pulls that keep destination
  S3-origin bytes at zero while preserving digest-pinned product materialization;
- corrupt-bundle rejection on destinations;
- rootfs-backed remote bundle smokes that build exact OCI rootfs bytes, pack
  them into indexed bundles, prove destination rootfs fetch/cache reuse across
  A1 hosts, reject corrupt rootfs artifacts, and verify materialization into the
  destination rootfs digest cache;
- a repo-local `mise run validate:release-a1-kvm -- ...` gate that composes the
  direct-S3, HTTP-peer, destination cache reuse, corrupt rejection, rootfs, and
  KVM networking release checks;
- ten-instance star and source-to-relay-to-leaf smoke runs.

What remains:

1. Measure origin egress as a small multiple of unique chunk bytes across larger
   identical-host fleets.
2. Keep corrupt peer/origin data rejected by chunk and rootfs verification as a
   release regression.

Done when a multi-host fan-out demo restores one spore on every host in a test
fleet, measures origin egress at a small multiple of unique chunk bytes, and
rejects corrupted peer data.

## Slice 7: Always-On Dirty Tracking

KVM dirty tracking uses `KVM_GET_DIRTY_LOG`, explicit VMM-originated dirty
marking, epoch sealing, and tail flush. HVF has backend write-protect tracking.
Both paths can seed chunks and `ram.backing` during execution and write snapshot
manifests without a full suspend-time RAM scan in the happy path.

The old direct restore/fan-out smoke scripts have been removed now that product
run/resume/fan-out paths are the source of truth. The backend boot harnesses
remain as measurement adapters for `scripts/benchmark-kvm-dirty-tracking.sh`
until dirty-tracking metrics are exposed through product or lifecycle capture
paths.

The KVM and HVF trackers now share the RAM sealing path: chunk refs, zero
elision, content-addressed chunk writes, `ram.backing` lifecycle, dirty-tail
counts, and backing finalization live behind a backend-neutral sealer. Backends
remain responsible only for detecting dirty memory: KVM via dirty-log bitmaps
plus host-initiated write marking, and HVF via write-protect faults plus
host-initiated write marking. This keeps tail optimizations focused on the
shared path instead of letting KVM and HVF drift.

Both backend dirty workers now report cadence lag and epoch overrun metrics, so
benchmark output can distinguish a quiet tail from a worker that is falling
behind. HVF successful dirty-tracked snapshot finalization no longer
re-protects every guest RAM chunk before exit; unfinished teardown still
restores writable mappings during cleanup. Dirty-tracked snapshot metrics also
break down finalization into worker stop, tail flush, RAM-backing chmod, close,
and rename timings so suspend pauses can be tied to dirty tail or backing-file
handoff. Successful dirty-tracked finalization now renames the read-only
`ram.backing` into place before handing its fd to a detached close path, with a
synchronous close fallback if that handoff cannot start. Non-tail worker flushes
also stop between chunks once snapshot finalization begins, so shutdown can hand
remaining dirty chunks to the final tail flush instead of waiting for a whole
worker epoch to drain. The manifest continues to treat `ram.backing` as optional
same-host acceleration; verified chunks remain the portable source of truth.

Closeout evidence separates true idle snapshots from boot/ticker backlog and
active write pressure. The benchmark initrd now has an `idle` mode that prints
readiness once, then uses read-only generation-device MMIO to give the harness a
periodic exit without intentional RAM writes. That keeps the caught-up benchmark
from measuring console spam.

On KVM, the true-idle 30s dirty-log runs on an aarch64 A1 host paused in
218ms, 99ms, and 317ms at 1/4/16GiB. The dirty tail stayed tiny at 4, 5, and 4
chunks. The remaining spread came from worker-stop timing, not a configured-RAM
scan: the final snapshot waited for the current sealing chunk or epoch boundary
for 127ms, 1ms, and 217ms. Shorter 8s idle/ticker runs are useful backlog tests
but not caught-up latency claims; they can still show hundreds of milliseconds
of worker-stop time while boot dirties are being sealed.

KVM active-write behavior is now bounded by dirty tail size rather than total
RAM. Three repeated 1GiB dirty-workload runs paused in 677-678ms with 57-58
tail chunks after the previous multi-second tail regression. A 4GiB active run
paused in 474ms with 226 tail chunks, and a 16GiB run paused in 91ms with one
tail chunk. A concurrent 2x4GiB active run paused in 86-87ms per VM with no
tail chunks. `KVM_GET_DIRTY_LOG` remained cheap in these runs, so dirty ring is
not justified for the foundation target; hashing/sealing and active tails are
the limiting costs.

On HVF, write-protect dirty tracking is acceptable for the foundation support
boundary. True-idle write-protect runs paused in 28-29ms at 1GiB, 61-62ms at
4GiB, and 25-30ms at 16GiB after rerunning the local 16GiB case with enough disk
headroom. The dirty workload paused in 14ms at 1GiB and 15-17ms at 4GiB with no
tail chunks, and a concurrent 2x4GiB ticker run paused in 27ms and 70ms.

The Slice 7 support claim is therefore: caught-up suspend avoids a suspend-time
full-RAM scan on KVM and HVF, and measured pause time is not proportional to
configured RAM size in the 1/4/16GiB foundation matrix. Active-write guests are
not promised constant suspend latency. They are supported when the dirty tail is
small enough for the product SLO; otherwise suspend latency remains proportional
to unsealed dirty chunks. Worker cadence lag is observable and can contribute a
few hundred milliseconds of worker-stop tail even with a tiny dirty tail, but it
is not currently a foundation blocker.

Follow-up release hardening:

1. Add a CI or nightly dirty-tracking benchmark guard once the release SLO is
   chosen.
2. Tune worker preemption or chunk scheduling if the few-hundred-millisecond
   worker-stop spread becomes user-visible.
3. Revisit KVM dirty ring only if larger many-vCPU or many-VM runs show bitmap
   polling, not hashing/sealing, is material.

## Slice 8: Cross-Backend Diagnostic Restore

Cross-backend restore is not a release gate for fork/fan-out. It remains useful
for inspecting failed runs and catching backend-private state in the manifest.

Known gates:

- KVM->HVF currently rejects real `m7g.metal` spores on architected counter
  frequency mismatch.
- HVF->KVM remains gated on HVF emitting portable GICv3 distributor and
  redistributor state instead of only the tagged same-HVF blob.
- Kernel build identity still needs to become part of the platform contract
  before claiming cross-host disk-backed restore.

Done when the four-direction matrix (KVM->KVM, HVF->HVF, KVM->HVF, HVF->KVM) is
documented with passing or intentionally rejected outcomes, and at least one
positive cross-backend direction works on compatible timer-profile hosts.

## Security Model

SporeVM is an isolation boundary written in Zig. The defensive posture is:

- small frozen device model;
- strict manifest and chunk validation;
- BLAKE3 verification before mapping chunks;
- fail-closed platform and artifact checks;
- fuzz targets with new attacker-influenced parsers;
- ReleaseSafe shipping builds;
- monitor jailing before public release.

`SECURITY.md` is the attack-surface inventory and must be updated in the same
change that widens parsing, device, manifest, rootfs, bundle, or control-socket
inputs.

## Verification

- Unit: DTB generation, virtqueue handling, manifest encode/decode, chunk CAS,
  rootfs artifact validation, bundle index handling, lifecycle metadata, control
  protocol parsing.
- Fuzzing: virtqueue descriptors, manifest/chunk decode, generation inputs,
  bundle indexes, rootfs/OCI parsers.
- Product smoke: `mise run smoke`, `mise run smoke:counter-fanout`,
  `mise run smoke:rootfs-fanout`, `mise run smoke:live-rootfs-fanout`.
- Remote smoke: chunkpack bundle distribution, pull/cache hierarchy, corrupt
  bundle rejection.
- Benchmark: suspend latency vs RAM size, fork latency, resume time to first
  instruction/useful work, lifecycle create-to-workload timing, and
  dirty-tracking overhead via `scripts/benchmark-kvm-dirty-tracking.sh` until
  product-path metrics exist.

## Resolved Decisions

- Language is Zig; shipping builds are ReleaseSafe.
- aarch64-only for v0; virtio-mmio-only; device list frozen.
- Machine state is normalized architectural state, never raw KVM or HVF structs.
- The checkpoint artifact is a spore; v0 formats carry no compatibility promise.
- Distribution starts with SporeVM chunkpack bundles and moves toward the
  pull-based artifact model in `docs/plans/distribution.md`.
- Rootfs-backed distribution bundles include exact immutable rootfs bytes by
  default; metadata-only rootfs bundles require an explicit opt-out and bundle
  metadata, plus an explicit prepared-cache materialization flag.
- Local `spore pull file://...` fully materializes a selected child before
  product resume; remote and lazy pull sources must keep the same verified
  content-source boundary.
- `spore run` is one-shot; named lifecycle uses `create`/`exec`/`rm`/`ls` plus
  monitor-backed suspend/resume.
- Product capture is `spore run --capture`, not a separate capture verb.
- Same-host fan-out must use explicit RAM-backing transfer and private mappings
  before claiming high-concurrency memory efficiency.
- KVM dirty tracking stays on `KVM_GET_DIRTY_LOG` until evidence shows bitmap
  polling is material.
- Cross-backend restore is diagnostic, not the fork/fan-out release gate.
- Cleanroom integrates through its own adapter; SporeVM remains standalone.

## Open Questions

None blocking the current active slices.
