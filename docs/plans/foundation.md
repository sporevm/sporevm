---
status: active
last_reviewed: 2026-06-17
related_plans:
  - buildkite/cleanroom: docs/plans/sandbox-suspend-wake.md
  - docs/plans/run-bridge.md
  - docs/plans/lifecycle-monitor.md
  - docs/plans/local-image-ref-cache.md
  - docs/plans/immutable-rootfs-resume.md
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
`-- optional immutable rootfs artifact: digest, size, virtio-blk binding,
    OCI provenance
```

Arbitrary writable disk contents are not captured in v0. A verified immutable
rootfs artifact can be recorded and reattached for product resume; writable disk
state and broader disk manifests remain later work.

## Current Status

| Area | Status | Next work |
| --- | --- | --- |
| Slice 0: scaffolding | Landed | None. |
| Slice 1: KVM boot | Complete for the foundation target | Continue using KVM hardware smokes for regressions. |
| Slice 2: HVF boot | Complete for the foundation target | Continue using Apple Silicon smokes for regressions. |
| Product run bridge | Landed | See `docs/plans/run-bridge.md`; future OCI/writable policy is out of this plan. |
| Named lifecycle | Local HVF landed | Speed work including local image ref caching, KVM monitor wake, disk-backed lifecycle resume; see `docs/plans/lifecycle-monitor.md`. |
| Slice 3: same-backend suspend/restore | Complete for KVM and HVF | Disk manifests remain future work. |
| Slice 4: fork and generation protocol | Complete for correctness | Keep fan-out identity smokes as regression coverage. |
| Slice 5: same-host RAM and lazy restore | Complete for primary KVM/HVF proofs | Product monitor wiring, readahead, KVM pager hardening, larger macOS scale runs. |
| Slice 6: identical-host distribution | Active | Multi-peer/cache hierarchy and measured origin-egress efficiency beyond explicit relay trees. |
| Slice 7: always-on dirty tracking | Active | KVM dirty-tail backlog under active writes, many-VM/larger-RAM measurement, HVF scale decision. |
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
- `spore pack` and `spore unpack` provide the first local chunkpack bundle shape
  with `bundle_digest` for cache identity and per-chunk verification for trust.
- `spore run`, product `spore resume`, and `spore fanout` provide the first
  user-facing run/capture/fork/resume/fan-out path.

Historical benchmark numbers are intentionally kept out of this plan now that
the mechanisms have landed. Regenerate current evidence with the scripts in
`scripts/` when making a performance or release claim.

## Active Slice 6: Identical-Host Fan-Out Distribution

Slice 6 starts from chunkpack bundles and remote restore smokes. Current evidence
includes:

- local pack/unpack with canonical `bundle_digest`;
- two-host S3/SSM restore;
- host-local cache reuse with repeated destination restores;
- source-peer HTTP seeding that keeps destination S3-origin bytes at zero;
- corrupt-bundle rejection on destinations;
- ten-instance star and source-to-relay-to-leaf smoke runs.

What remains:

1. Convert explicit smoke topology into a product-shaped cache or peer hierarchy.
2. Measure origin egress as a small multiple of unique chunk bytes across larger
   identical-host fleets.
3. Keep corrupt peer/origin data rejected by chunk verification.
4. Decide how immutable rootfs artifacts join the distribution path without
   blurring memory chunks and rootfs bytes.

Done when a multi-host fan-out demo restores one spore on every host in a test
fleet, measures origin egress at a small multiple of unique chunk bytes, and
rejects corrupted peer data.

## Active Slice 7: Always-On Dirty Tracking

KVM dirty tracking has a harness path using `KVM_GET_DIRTY_LOG`, explicit
VMM-originated dirty marking, epoch sealing, and tail flush. HVF has a
write-protect proof path behind `hvf-boot --dirty-track`. Both paths can seed
chunks and `ram.backing` during execution and write snapshot manifests without a
full suspend-time RAM scan in the happy path.

The KVM and HVF trackers now share the RAM sealing path: chunk refs, zero
elision, content-addressed chunk writes, `ram.backing` lifecycle, dirty-tail
counts, and backing finalization live behind a backend-neutral sealer. Backends
remain responsible only for detecting dirty memory: KVM via dirty-log bitmaps
plus host-initiated write marking, and HVF via write-protect faults plus
host-initiated write marking. This keeps future tail optimizations focused on
the shared serial sealing path instead of letting KVM and HVF drift.

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

Current benchmark evidence separates boot/seal backlog from suspend tail. On
HVF, the dirty workload is bounded in the tested cases: 1GiB repeated snapshots
pause in 16-18ms, and a concurrent 2x4GiB run pauses in 20-22ms per VM with no
tail chunks. On KVM, 4GiB and 16GiB dirty-workload snapshots remain around
87-90ms, and concurrent 2x4GiB remains 87ms per VM with no tail chunks. The KVM
1GiB dirty workload is still not product-ready: the worker no longer turns
backlog into a 2.1s join, but the same pressure leaves roughly 115 dirty chunks
for tail flush, with post-refactor runs observed at 114-117 dirty tail chunks
and suspend around 2.1-2.2s. The next KVM step is to reduce or parallelize
dirty-tail sealing, or change the backing strategy so active dirty writers
cannot accumulate a serial tail that large.

Current focus:

1. Reduce KVM dirty-tail backlog under active write pressure; the 1GiB dirty
   workload currently proves this is real suspend tail, not just worker cadence
   lag.
2. Compare one VM, many VMs, and larger RAM using worker metrics without
   changing APIs again.
3. Separate steady-state idle snapshots from active boot or workload dirty
   bursts.
4. Expand HVF write-protect measurements on macOS CI hardware before declaring a
   product support boundary.
5. Revisit KVM dirty ring only if bitmap polling becomes material after larger
   RAM, many-vCPU, or many-VM measurements.

Done when caught-up suspend latency is measured flat across 1/4/16GiB guests on
Linux and HVF, active-write dirty-tail behavior is bounded or documented as a
support limit, the KVM 1GiB active-write tail regression is fixed or explicitly
excluded from the Slice 7 support boundary, and the HVF overhead decision is
recorded with numbers.

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
  `mise run smoke:rootfs-fanout`.
- Backend smoke: KVM/HVF boot, suspend/resume, fork storm, lazy restore, dirty
  tracking.
- Remote smoke: chunkpack bundle distribution, peer/cache hierarchy, corrupt
  bundle rejection.
- Benchmark: suspend latency vs RAM size, fork latency, resume time to first
  instruction/useful work, dirty-tracking overhead, lifecycle create-to-workload
  timing.

## Resolved Decisions

- Language is Zig; shipping builds are ReleaseSafe.
- aarch64-only for v0; virtio-mmio-only; device list frozen.
- Machine state is normalized architectural state, never raw KVM or HVF structs.
- The checkpoint artifact is a spore; v0 formats carry no compatibility promise.
- Distribution starts with SporeVM chunkpack bundles.
- `spore run` is one-shot; named lifecycle uses `create`/`exec`/`rm`/`ls` plus
  monitor-backed suspend/resume.
- Product capture is `spore run --capture`, not a separate capture verb.
- Same-host fan-out uses explicit RAM-backing transfer and private mappings
  before claiming high-concurrency memory efficiency.
- KVM dirty tracking stays on `KVM_GET_DIRTY_LOG` until evidence shows bitmap
  polling is material.
- Cross-backend restore is diagnostic, not the fork/fan-out release gate.
- Cleanroom integrates through its own adapter; SporeVM remains standalone.

## Open Questions

None blocking the current active slices.
