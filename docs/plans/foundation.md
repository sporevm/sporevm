---
status: active
last_reviewed: 2026-06-15
related_plans:
  - buildkite/cleanroom: docs/plans/sandbox-suspend-wake.md
  - docs/plans/run-bridge.md
  - docs/plans/lifecycle-monitor.md
  - docs/plans/local-image-ref-cache.md
---

# SporeVM Foundation Plan

## Summary

SporeVM is a virtual machine monitor for aarch64 Linux microVMs that treats a
suspended VM as a cheap, forkable object for fan-out across compatible hosts.
One codebase targets two hypervisors — KVM on Linux and Hypervisor.framework
(HVF) on macOS — with an identical minimal virtio-mmio device model on both.
Cross-backend restore is useful diagnostic portability, but the primary product
path is fork/fan-out on identical host classes. It is written in Zig.

The defining design property is that no lifecycle operation scales with RAM
size. A running VM is permanently checkpoint-ready: dirty pages stream
continuously into a content-addressed store, so suspend is a pause plus a small
tail flush, fork is a metadata write, and resume is bounded by the working set,
not by memory size. The sealed checkpoint artifact is called a **spore**: a
manifest of content-addressed memory chunks, guest machine state, and eventually
disk state. v0 does not capture disk bytes yet. Spores are the unit of suspend,
fork, fan-out, and cross-backend inspection.

The end state this plan drives toward:

```console
spore run --kernel ... --initrd ... -- /bin/true
spore run --image ruby-demo --capture-on-abort ruby.spore -- ruby /demo/counter.rb
spore create --kernel ... --disk ... my-vm
spore suspend my-vm                 # ~50ms regardless of RAM size
spore fork my-vm.spore --count 10000 --out forks/  # metadata-only
spore pull <spore-id> && spore resume <spore-id>   # on a compatible host
```

SporeVM is a standalone project with its own CLI and control API. Cleanroom is
the first expected consumer through a backend adapter, but nothing in this
repository depends on cleanroom.

## Problem

There is no VMM today that can fork suspended Linux VM state across thousands
of compatible hosts without copying memory images around, while still retaining
enough normalized machine state to inspect and debug failed runs across backend
boundaries:

- Firecracker snapshots are KVM-only and tied to its device model.
- Apple Virtualization.framework saved state is opaque, version-locked, and not
  portable even between Macs.
- QEMU runs on both but is heavyweight, and cross-accelerator (KVM→HVF)
  restore is unproven in production.
- All of them treat a snapshot as a monolithic file whose cost scales with RAM.

Cheap fan-out requires memory to be content-addressed and lazily materialized.
Owning the device model and vCPU state encoding also gives us cross-backend
inspection leverage, but that is not the release-critical path. Both point at
the same conclusion: a purpose-built VMM where the snapshot format is the
product.

The enabling platform facts are confirmed:

- macOS 15+ exposes `hv_gic_get_state` / `hv_gic_set_state`, so GIC state
  round-trips on HVF. KVM exposes vGICv3 state via `KVM_DEV_ARM_VGIC_GRP_*`.
- aarch64 architectural vCPU state (GPRs, sysregs, FP/SIMD, timers) is
  gettable/settable on both KVM (`KVM_GET_ONE_REG`) and HVF
  (`hv_vcpu_get_reg` / `hv_vcpu_get_sys_reg`).
- Both hypervisors let the VMM own guest memory mapping (memslots /
  `hv_vm_map`), which is what makes lazy paging possible.

## Goals

- Boot a pinned aarch64 Linux kernel under KVM and HVF from one codebase with
  an identical device model.
- Define a versioned spore manifest format whose machine state is
  architectural, not hypervisor-specific.
- O(1) fork with a guest-cooperative fixup protocol (identity, entropy, time).
- Fan-out spores across identical host classes without copying full RAM images
  to every destination.
- Content-addressed chunked memory and disk with lazy, fault-driven restore.
- Suspend/restore on the same host for both KVM and HVF, with cross-backend
  restore kept as a diagnostic portability track rather than a release gate.
- Elastic same-host fork and lazy restore on both supported same-backend paths:
  KVM→KVM for Linux CI hosts and HVF→HVF for Apple Silicon hosts. This is
  product parity, not the optional cross-backend diagnostic portability track.
- Always-on dirty tracking so suspend latency is independent of RAM size.
- Chunk distribution that survives 10,000 concurrent restores without 10,000
  origin fetches.
- A security posture proportionate to being an isolation boundary written in a
  non-memory-safe language: minimal device model, continuous fuzzing, process
  jailing, ReleaseSafe-only shipping builds.

## Non-Goals

- x86 hosts or guests on the portable path. Cross-platform portability is
  aarch64-only by physics; x86 support of any kind is out of scope for v0.
- Non-Linux guests, GUI, GPU, USB, or any device beyond the minimal set.
- virtio-pci. The device model is virtio-mmio only.
- Live migration of a running VM. Suspend/transfer/resume is the contract.
- Network egress policy, secret mediation, OCI runtime semantics, or workspace
  semantics. Those belong to consumers like cleanroom. SporeVM may provide
  offline developer utilities for materializing digest-pinned OCI root filesystems
  into block images, but the VMM does not own image policy.
- Preserving open TCP connections across cross-host resume.
- Multi-tenant public-cloud hardening claims. The v0 threat model is
  self-hosted CI/agent isolation: an untrusted guest must not escape the VMM,
  but we do not claim Lambda-grade multi-tenancy.
- Backwards compatibility before 1.0. The spore format is versioned and v0
  formats may be discarded.

## Target Model

### Process and API surface

Target-state `spore` is a single binary: CLI subcommands plus a long-running
per-VM monitor process. Consumers integrate over a newline-delimited JSON
control protocol on a per-VM unix socket (the cleanroom helper pattern), so the
Zig core is invisible at the integration seam.

```console
spore run --kernel ... --initrd ... -- <argv...>
spore create | resume | suspend | fork | rm | ls | inspect
spore push | pull        # spore artifacts to/from a registry
spore daemon             # chunk cache + peer exchange service (later phase)
```

### Device model v1 (frozen early, deliberately tiny)

- virtio-mmio transport only, fixed MMIO/IRQ layout baked into the device tree
- devices: console, blk, net (fd-backed: TAP fd on Linux, socket/filehandle on
  macOS), vsock, rng
- a generation device: a tiny MMIO device exposing a fork-generation counter
  and resume-parameters page, with an interrupt on change
- no hotplug, no MSI/ITS (SPIs only), no PCI

The device model is the attack surface and the portability contract; every
addition must justify itself against both.

### Guest platform contract

A spore embeds a platform contract: aarch64, device model version, RAM/GIC
layout, guest-visible counter frequency, and a CPU feature-ID profile (the
common denominator of Apple M-series and AWS Graviton, masked at VM creation).
Restore fails closed when the host cannot satisfy the contract. Kernel image
identity is a planned contract field before claiming cross-host disk-backed
restore. The guest kernel config starts from cleanroom's managed-kernel config
with virtio-mmio, vsock, and the generation driver enabled.

### Spore manifest v0

```text
spore manifest
├── platform contract (arch, device model, CPU profile, RAM/GIC layout,
│   counter frequency)
├── machine state: architectural vCPU state, GICv3/ICC state, virtual timer,
│   virtio transport state, generation device state
└── memory manifest: ordered BLAKE3 chunk refs, zero-elided
```

Chunks live in a local CAS directory; v0 manifests are JSON documents. Disk
manifests land in later fork/fan-out slices. Access traces are local benchmark
artifacts today; persisted manifest hints land with later readahead work. The
distribution primitive is a SporeVM chunkpack bundle: logical BLAKE3 chunks are
packed into larger blobs with an index that preserves per-chunk verification.
OCI, S3, HTTP, Dragonfly/Nydus-style caches, or cleanroom's gateway/content
cache can wrap or serve those bundles later; the hot fan-out data plane is not
defined as direct registry pulls from every agent.

### Memory and lifecycle model

Guest RAM is a VMM-owned mapping registered with the hypervisor. The target
model has two materialization modes:

- **Same-host hot fork**: keep the paused parent's sealed RAM backing alive and
  map each child privately over it. Child reads share the parent's physical
  pages; child writes fault into private CoW pages. On Linux this should be a
  `memfd`/file-backed RAM object passed explicitly to child monitors over the
  unix control socket with `SCM_RIGHTS`, then mapped `MAP_PRIVATE` before
  `KVM_SET_USER_MEMORY_REGION`. HVF needs the backend-equivalent private
  remap/file-backed path; until it exists, it fails closed to the eager or
  lazy-CAS path rather than pretending to be elastic. This is the primary
  identical-host fan-out path.
- **Portable or cold restore**: materialize from the spore memory manifest and
  CAS. The eager v0 path copies every chunk up front; the lazy path below
  faults chunks in only when touched.

Three lifecycle mechanisms hang off those backing modes:

- **Dirty tracking**: Linux starts with `KVM_GET_DIRTY_LOG` as the simple
  measured baseline. KVM dirty ring remains an optimisation for very large RAM,
  many-vCPU, or many-VM cases where bitmap polling becomes visible; it is not
  the next bottleneck in the current 16GiB measurements. HVF uses
  write-protection fault exits if the measured overhead is acceptable, or an
  explicit suspend-time scan boundary if not. A background worker seals dirty
  pages into CAS chunks on an epoch cadence. Suspend = pause vCPUs + flush
  current epoch + serialize machine state.
- **Lazy restore**: pages materialize on fault — userfaultfd on Linux,
  unmapped-memory vm-exits on HVF — backed by local CAS, then peers, then
  origin. The access trace drives readahead so the guest does useful work
  while the tail faults in.
- **Fork**: mint a new manifest referencing the parent's chunks and, on the
  same host, optionally retain a private CoW RAM backing handle for immediate
  child resume. Assign a new VM identity and resume with the generation counter
  incremented. The guest agent reacts: machine-id/hostname/MAC fixups, RNG
  reseed via virtio-rng, forced clock step, "generation changed" signal to
  userspace.

### Ownership boundaries

- SporeVM owns: hypervisor interaction, device model, spore format, CAS,
  lazy paging, fork mechanics, the generation device, and the in-guest fixup
  helper.
- Consumers own: rootfs/image policy, network policy and egress enforcement,
  secrets, scheduling across hosts, and what workloads run. The `spore rootfs`
  utility is a convenience path for turning a digest-pinned OCI image into an
  ext4 disk; consumers may still bring their own rootfs.
- Runtime/host specifics (entitlements, signing, kernel asset paths, cache
  directories) live in host config, never in the spore format.

## Security Model

SporeVM is an isolation boundary written in Zig, which is not memory-safe.
That is a deliberate tradeoff and it is bought back structurally, not by hope:

- The attack surface is enumerated: virtqueue parsing, guest memory access
  during dirty scans, chunk/manifest decoding (including chunks from peers).
  Each is a named module with fuzz targets from the slice that introduces it.
- Shipping builds are ReleaseSafe only. ReleaseFast is for benchmarks.
- The monitor process is jailed: seccomp allowlist on Linux, sandbox profile
  and minimal entitlements on macOS. The jail lands before the first release,
  not after.
- Same-host RAM sharing uses explicit fd transfer between trusted monitor
  processes, not broad process introspection permissions. A forkable parent is
  a deliberately managed runtime state, not a reason to make VM processes
  generally dumpable or inspectable.
- Chunks loaded from CAS or peers are verified against their blake3 id before
  guest use; a malicious peer can deny service but not inject state. Trusted
  same-host RAM backing is a local acceleration capability, not a portable
  verification root.
- No secrets ever enter the VMM process or the spore format.
- `SECURITY.md` records this posture as a founding document and is updated
  when the attack surface changes.

## Design Principles

- The spore format is the product. Code churns; the format is versioned,
  documented, and fails closed on mismatch.
- Machine state is architectural. If a field is hypervisor-specific, normalize
  it at the boundary or reject the design.
- Nothing scales with RAM size: suspend, fork, and resume costs scale with
  working-set delta only.
- Identical device model on both hypervisors, enforced by shared code, not
  parallel implementations.
- Fail closed: unsupported host, unsatisfiable platform contract, unverifiable
  chunk, or unknown manifest version is an error, never a degraded resume.
- Every slice ends with something that boots, restores, or measures on real
  hardware.

## Current Progress

Slice 0 scaffolding has landed: Zig 0.16.0 pinned via mise, `zig build test`
green, `spore` CLI basics (`version`, `host-info`, `inspect`, `help`), founding
docs (`README.md`, `SECURITY.md`, `AGENTS.md`, MIT `LICENSE`,
`docs/spore-format.md`), Buildkite pipeline targeting the `cleanroom` and
`cleanroom-mac` queues, and the QEMU cross-accelerator experiment decision
recorded in `docs/research.md`. The QEMU proxy experiment was not run because
direct SporeVM HVF and KVM state work answered the useful normalization
questions first; it remains a diagnostic fallback, not a blocker.

Slice 1 (KVM boot) is complete for the foundation target. On the real aarch64
KVM `m7g.metal` dev host, `kvm-boot` creates the VM/vCPU, configures userspace
VGICv3, maps the shared board DTB, and routes the shared virtio-mmio plus
generation device exits. It boots the cleanroom 6.1.155 kernel to the expected
no-root VFS panic without storage, to an Alpine `/bin/sh` with an ext4 rootfs,
and through diskless initrd smoke workloads. DTB generation, virtqueue parsing,
and hostile queue/device inputs are covered by unit and fuzz-style tests in the
Zig test suite.

Slice 2 (HVF boot) is complete for the foundation target. The HVF backend uses
the same board/device code paths, creates `hv_vm`/vCPU/GIC state behind the
backend boundary, and boots the same cleanroom kernel/initrd/rootfs combinations
to an interactive shell on Apple Silicon. The shared virtio-mmio console, blk,
net, vsock, rng, and generation devices are present on both backends. Host
network attachment remains a later transport concern, not a slice-2 blocker.

A first product `spore run` bridge has landed on top of the minimal vsock exec
probe. It boots a throwaway VM from explicit local kernel/initrd paths, sends
one bounded argv request to the guest agent, and exits with the guest command's
status. This is intentionally not the long-running monitor/control socket, not
rootfs policy, and not a bundle distribution path; it is the smallest product
CLI primitive that proves boot + command + status propagation through the real
VMM path.

The first named VM lifecycle monitor has landed for local HVF. `spore create`,
`spore exec`, `spore rm`, and `spore ls` use a private runtime registry and one
per-VM monitor process with a newline-delimited JSON control socket.
`spore create --rootfs` and `spore create --image` reuse the same read-only
rootfs materialization path as `spore run`, and the guest agent uses per-command
session ids so multiple `spore exec` calls can run inside one guest boot without
turning reconnects into duplicate execution. Diskless `spore suspend NAME --out
DIR` and `spore resume DIR --name NAME` also work locally on HVF. KVM monitor
wake support and disk-backed lifecycle suspend/resume remain follow-ups.
Lifecycle benchmark instrumentation now writes create and monitor phase timing
into each JSONL row. The first local measurements show tag-based
`spore create --image docker.io/library/node:22-alpine` spends most of its
warm-cache time resolving the OCI tag, while a digest-pinned cached rootfs drops
fresh create-to-`node -v` to the few-hundred-millisecond range. The benchmark
script therefore resolves mutable tags once before the timed loop by default
and records both the requested tag and effective digest. The next speed work
should start with the direct-addressed local image ref cache in
`docs/plans/local-image-ref-cache.md` and rootfs-path isolation before pursuing
deeper VM boot or snapshot optimizations.

Slice 3 (same-hypervisor eager suspend/restore and manifest v0) is complete for
both backends. `src/spore.zig` and `docs/spore-format.md` define v0: eager,
content-addressed, zero-elided RAM chunks; normalized one-vCPU architectural
state; virtual timer re-anchoring; GIC/ICC state; virtio transport state; and
generation device state. KVM emits/consumes portable GICv3 distributor and
redistributor state; HVF same-backend restore still uses a tagged
`backend_private` `hv_gic` blob until HVF portable GIC capture is complete. v0
does not capture disk contents, so disk-backed resume still requires unchanged
external disk bytes.

Same-host diskless restore smokes now pass on both available sides using the
`cleanroom-kernels` v0.2.0 `initrd` profile: KVM on the `m7g.metal` host and
HVF locally each resume the ticker through `sporevm-initrd-tick 7` via
`scripts/make-smoke-initrd.sh` and `scripts/smoke-restore-leg.sh`. Platform
compatibility checks are shared, and `spore host-info` / `spore inspect` expose
the host and spore contract fields needed to pick compatible smoke hosts.

Slice 4 is complete for the foundation correctness and measurement target.
`spore fork <spore-dir> --count N --out DIR` writes
child spore manifests named `000000`, `000001`, and so on, sharing the parent's
chunk store with a `chunks` symlink. Each child gets a unique incremented
generation, a pending generation-change interrupt, and JSON resume parameters
with stable fork identity (`fork_batch_id`, `vm_id`, hostname, MAC seed/address).
KVM and HVF restore reassert the generation SPI when the restored generation
state is pending and inject volatile resume-time fields (host timestamp and
fresh entropy seed) into the generation params page at actual resume time. The
fork-aware smoke initrd polls the generation device, applies/logs hostname,
machine-id, entropy and clock fixups, then acks the generation interrupt last;
`scripts/smoke-fork-fanout.sh` exercises parent capture plus same-host child
fan-out. The smoke supports bounded child-resume batches with `--parallel N`
and writes `metrics.json` with capture latency, `spore fork` latency, child
resume wall/sum/min/max latency, and total smoke time. HVF and KVM pass
same-host fan-out smokes; the representative KVM run on the `m7g.metal` host
used the `cleanroom-kernels` v0.3.0 `sporevm-arm64-linux-6.1.155-Image` asset
with `--count 32 --parallel 4`, reporting capture_ms=5323, fork_ms=47,
children_resume_wall_ms=6663, child_resume_min_ms=811,
child_resume_max_ms=813, and total_smoke_ms=12695. The high-concurrency memory
efficiency proof belongs to Slice 5 so Slice 4 does not mistake eager-restore
host capacity for fork architecture.

Slice 5's same-host RAM backing proof has landed for KVM and HVF. Snapshots
write an optional local `ram.backing` file next to the canonical chunk store;
`spore fork` propagates that backing to children only when the local file is
still available, otherwise it drops the optional metadata and leaves children
restorable from chunks. The boot harnesses require an explicit trusted
same-host opt-in before opening `ram.backing`, then pass the already-open fd
into the backend for `MAP_PRIVATE` mapping. That trusted fd path checks the
manifest shape but does not re-hash the backing contents; imported or untrusted
spores still materialize through verified chunks and the backend no longer
resolves manifest paths. This remains an interim path/symlink harness adapter
that proves the CoW resume path; the sealed-fd / `SCM_RIGHTS` monitor shape
remains the robust target before we claim the final trust boundary. The
memory-sampled KVM run on the `m7g.metal` host used
`--count 100 --parallel 100 --mem-mib 512 --memory-sample-seconds 2`, reported
file_backed_children=100, host_memory_sampled_children=100,
host_pss_kib=778524, host_rss_kib=1699988, child_resume_min_ms=138, and
child_resume_max_ms=196. That is roughly 760MiB aggregate child PSS for 50GiB
of declared child RAM, with the 512MiB `ram.backing` stored as a sparse 28MiB
file for that smoke workload. The Linux `SCM_RIGHTS` fd-passing primitive has
landed with a round-trip test, and `kvm-boot --fdpass-ram-backing` now exercises
that monitor-shaped handoff while keeping the original `kvm-boot` PID as the VM
process for smoke sampling and cleanup. A 100-child fdpass-mode KVM run reported
file_backed_children=100, host_memory_sampled_children=100, host_pss_kib=782723,
child_resume_min_ms=137, and child_resume_max_ms=195. This is still a harness
bridge, not the long-running product monitor/control socket. On HVF, the local
Apple Silicon fork smoke now runs with trusted file-backed children too; a
representative `--count 8 --parallel 4 --mem-mib 512` run reported
file_backed_children=8, child_resume_min_ms=376, child_resume_max_ms=395, and
children_resume_wall_ms=846.

Slice 5 is complete for the primary same-backend lazy-restore proof on KVM and
HVF. KVM has an explicit `kvm-boot --lazy-ram` harness path that keeps eager
restore as the default, registers anonymous guest RAM with `userfaultfd`, and
materializes verified 2MiB CAS chunks on first fault. HVF has the equivalent
`hvf-boot --lazy-ram` path: resume starts with guest RAM unmapped in
Hypervisor.framework, then instruction/data-abort exits inside the RAM window
load verified CAS chunks into the VMM-owned host mapping and `hv_vm_map` only
that chunk. Both paths write a local lazy trace with one line per faulted chunk
and the smoke reports `ttfi_ms` (time to first VM entry), `ttuw_ms` (time to
first guest ticker), `lazy_faults`, and `lazy_unique_chunks`. On `m7g.metal`,
512MiB eager restore reported ttfi_ms=512 and ttuw_ms=1565; 512MiB lazy restore
reported ttfi_ms=2, ttuw_ms=1226, lazy_faults=9, and lazy_unique_chunks=9; 4GiB
lazy restore reported ttfi_ms=3, ttuw_ms=1228, lazy_faults=10, and
lazy_unique_chunks=10. On local HVF, 512MiB eager restore reported ttfi_ms=229
and ttuw_ms=1697; 512MiB lazy restore reported ttfi_ms=50, ttuw_ms=1398,
lazy_faults=6, and lazy_unique_chunks=6; 4GiB lazy restore reported ttfi_ms=65,
ttuw_ms=1411, lazy_faults=5, and lazy_unique_chunks=5. Product monitor wiring,
readahead, clean cross-thread KVM pager error propagation, and larger macOS CI
scale runs remain follow-up hardening work.

Cross-backend restore is intentionally secondary. KVM→HVF can map portable
vCPU, virtio, generation, CPU-profile, and GIC apply state, but `m7g.metal`
spores now fail closed on the expected counter-frequency mismatch
(`1_050_000_000` Hz vs Apple HVF's 24MHz). A ten-host `a1.metal` probe found
that Graviton 1 exposes `CNTFRQ_EL0=83_333_333` on every host, so that cheaper
host class is useful for KVM↔KVM distribution work but does not remove the
KVM↔HVF timer mismatch. HVF→KVM remains gated on HVF emitting portable GICv3
state. These are tracked in `docs/state-portability.md` and do not block the
next release-critical fork/fan-out slices.

Slice 6 has its first remote distribution proof. `scripts/smoke-remote-bundle.sh`
orchestrates two SSM-managed aarch64 KVM hosts and an S3 staging prefix: it
uploads tracked `HEAD` plus the current tracked/staged diff, captures and packs
a spore on the source host, publishes the chunkpack bundle to S3, then
downloads, unpacks, and resumes on the destination host. The first two-host run
in `ap-southeast-2` packed 14 non-zero chunks from a 512MiB ticker spore into a
29,382,174-byte bundle, then resumed on the second host with KVM lazy RAM
reporting `ttfi_ms=5`, `ttuw_ms=1222`, `lazy_faults=9`, and
`lazy_unique_chunks=9`. This proves the bundle can leave a source host and boot
on a compatible destination. The follow-up cache-backed run restored the same
bundle twice on each of two hosts with `--cache-dir` and `--dest-repeat 2`:
each host fetched the 29,382,174-byte bundle from S3 once, hit its local cache
for the second restore, and reported `total_cache_hits=2`,
`total_cache_misses=2`, and `origin_multiplier_vs_resume_bundle=0.5` across
four resumes. That proves host-local cache reuse for repeated same-host
restores; peer/fleet distribution is still required before the final fan-out
data plane can claim low origin egress at large scale. The bundle identity used
for that cache path is now a product-level `bundle_digest` reported by both
`spore pack` and `spore unpack`, so future daemons and cache layers do not need
to reinvent script-local tree hashes. After east-west TCP was opened between
the two dev hosts, the smoke gained a source-peer HTTP seed mode on the allowed
20000-20100 port range. A two-host run with `--source-peer-ip`, `--cache-dir`,
and `--dest-repeat 2` completed four restores with `total_destination_origin_bytes=0`,
`total_destination_peer_bytes=58,777,600`, `total_cache_hits=2`,
`total_cache_misses=2`, and `origin_multiplier_vs_resume_bundle=0.0`. The
bundle is still published to S3 as the durable staging boundary, but
destinations no longer need to fetch bundle bytes directly from it in this
mode. The remote smoke now also hardens the negative path: each destination
bit-flips a fetched chunkpack copy, asserts `spore unpack` rejects it, and
records `corrupt_bundle_rejections` in the destination and aggregate metrics
before the clean bundle is allowed to resume. A validation run over the two dev
hosts with source-peer HTTP, `--cache-dir`, and `--dest-repeat 2` reported
`total_destination_origin_bytes=0`, `total_cache_hits=1`,
`total_cache_misses=1`, `total_corrupt_bundle_rejections=1`, and lazy KVM
resume `ttfi_ms=1..2` on the destination. With ten live `m7g.metal` instances,
the same smoke then ran a cost-bounded 1-source + 9-destination star topology:
the source published the 29,382,174-byte bundle to S3, destinations fetched from
the source peer over HTTP, all nine resumed with lazy KVM RAM, and aggregate
metrics reported `destination_count=9`, `total_destination_origin_bytes=0`,
`total_destination_peer_bytes=264,499,200`,
`total_corrupt_bundle_rejections=9`, and
`origin_multiplier_vs_resume_bundle=0.0`. The smoke now also supports an
explicit source→relay→leaf tree topology. A ten-instance `a1.metal` run used
one source, three relays, and six leaves; all nine non-source hosts resumed and
rejected corrupted bundle copies, destination S3-origin bytes stayed at zero,
and peer egress split as `source_peer_egress_bytes=88,166,400` plus
`relay_peer_egress_bytes=176,332,800`. The heaviest peer served
`max_peer_egress_bytes=88,166,400`, about three bundle archives instead of the
nine bundle archives served by the previous star source.

Slice 7 has started with a KVM-only measurement path. `kvm-boot --dirty-track`
sets `KVM_MEM_LOG_DIRTY_PAGES` on the RAM memslot, seeds chunk refs and the
local `ram.backing` file after the host loads the kernel/initrd/DTB, collects
guest dirties with `KVM_GET_DIRTY_LOG` on a tunable `--dirty-epoch-ms` cadence,
tracks VMM-originated guest RAM writes from virtio used rings and
device-writable descriptor buffers, and finalizes a snapshot with a last
dirty-log tail flush instead of a full RAM scan.
`scripts/benchmark-kvm-dirty-tracking.sh` runs paired full-scan and dirty-log
captures across memory sizes and emits JSONL metrics including
`snapshot_pause_ms`, `memory_ms`, epoch count, dirty pages/chunks,
host-dirty ranges/chunks, seed time, and tail flush time. On `a1.metal`, the
first 512MiB paired run reported
full-scan `snapshot_pause_ms=4047` / `memory_ms=4047` versus dirty-log
`snapshot_pause_ms=2` / `memory_ms=0` after `seed_ms=3374`, epoch sealing
`seal_ms=2904`, and VMM-side dirty marking of `host_dirty_ranges_total=15` /
`host_dirty_chunks_total=3`; eager resume from the dirty-log spore passed, and
trusted `ram.backing` resume reported `mode=trusted_file_backed` with
`pre_run_ms=3`.
The 4GiB paired run reported full-scan `snapshot_pause_ms=27097` /
`memory_ms=27095` versus dirty-log `snapshot_pause_ms=2` / `memory_ms=1` after
`seed_ms=24432` and epoch sealing `seal_ms=3340`. A 16GiB run reported
full-scan `snapshot_pause_ms=106069` / `memory_ms=106065` versus dirty-log
`snapshot_pause_ms=5` / `memory_ms=1` after `seed_ms=96912` and epoch sealing
`seal_ms=11103`; eager cold resume from that spore passed with
`memory_ms=28843` / `pre_run_ms=28853`, so large imported resumes remain a
separate optimisation target from same-host trusted `ram.backing` forks. The
macOS proof path now has an HVF write-protect tracker: `hvf-boot --dirty-track`
seeds chunks and `ram.backing`, protects guest RAM read/execute, handles guest
write faults by dirtying and reopening the touched chunk, re-seals/re-protects
chunks in the background, and uses the same VMM-originated dirty-write hook as
KVM. A local 512MiB HVF fork smoke with parent dirty tracking reported
`snapshot_pause_ms=109`, `tail_flush_ms=87`, `seed_ms=928`,
`worker_epoch_max_ms=220`, `write_fault_count=41`, and two children resumed
from trusted `ram.backing` in 372-383ms. Larger macOS CI runs still need to
confirm scale, but macOS no longer looks forced onto a suspend-time full scan
for the primary HVF→HVF fork path.

## Delivery Strategy

Each slice is a reviewable unit with a runnable result. KVM work needs an
aarch64 Linux host with KVM; HVF work needs an Apple Silicon Mac on macOS 15+.

### Slice 0: Repo scaffolding and de-risk experiment

Zig project skeleton (`build.zig`, pinned Zig toolchain via mise), CI that
builds and runs unit tests on both platforms, `SECURITY.md`, `AGENTS.md`,
`docs/spore-format.md`, MIT license, README stating the thesis.

In parallel, the cheapest possible validation of the cross-backend portability
hypothesis, using no SporeVM code: take a QEMU `virt` machine snapshot under
KVM on aarch64 Linux and attempt restore under HVF on macOS (QEMU upstream has
in-flight HVF GIC save/restore patches). Outcome is recorded in
`docs/research.md` either way; failure modes inform the machine-state
normalization design.

Done when: CI is green on both platforms and the QEMU experiment writeup
exists with a clear keep/adjust decision for the normalization approach.

### Slice 1: Boot under KVM

Minimal KVM VMM on Linux aarch64: load the pinned kernel + initramfs, build
the device tree, virtio-mmio console, shared virtio device model, serial output
to stdout, clean shutdown. `kvm-boot --initrd ...` boots to a smoke workload;
`kvm-boot --disk ...` boots to a shell.

Done when: a real aarch64 KVM host boots to an interactive console in under a
second and `zig build test` covers DTB generation and virtqueue parsing, with
a fuzz target for the virtqueue path.

### Slice 2: Boot under HVF with the same device model

HVF backend behind a hypervisor interface: `hv_vm_create`, vCPU threads,
`hv_gic_create`, the same DTB/device code paths. Entitlement and signing
handling documented for local dev.

Done when: the same kernel/initramfs pair boots to a console on an Apple
Silicon Mac with no divergence in the device model code, and virtio-blk +
net + vsock + rng land on both backends (this slice or a small follow-up).

### Slice 3: Same-hypervisor suspend/restore and spore manifest v0

Pause vCPUs, extract architectural vCPU state + GIC state + virtio state,
write a spore manifest with full (not yet lazy) memory chunks into a local
CAS. The backend harnesses (`kvm-boot` and `hvf-boot`) round-trip on the same
host with `--snapshot-after-ms ... --spore ...` and `--resume ...`; product
`spore suspend` / `spore resume` commands land with the lifecycle CLI. Manifest
decode gets a fuzz target.

Done when: a guest survives suspend/resume with running processes intact
(KVM→KVM and HVF→HVF), and `docs/spore-format.md` documents manifest v0.

### Slice 4: Fork and the generation protocol

The release-critical result. `spore fork --count N` mints manifests CoW for an
already-captured spore and resumes each child on an identical host class with an
incremented generation. Generation device, in-guest fixup helper (machine-id,
hostname, MAC, RNG reseed, clock step, userspace signal). Same-host fork storm
correctness first; identical-host fleet fan-out follows once elastic RAM
backing and distribution land.

Done when: a same-host fan-out smoke runs a representative batch of children
with distinct identities, no entropy or clock anomalies, and fork/resume latency
is recorded. The high-concurrency memory-efficiency gate moves to Slice 5 so we
do not mistake eager restore host capacity for fork architecture.

### Slice 5: Elastic same-host RAM and lazy restore

Status: complete for the primary same-backend KVM and HVF proof. Product
monitor wiring, readahead, clean KVM pager error propagation, and larger macOS
CI scale runs remain. HVF→HVF elastic RAM/lazy restore is Apple Silicon product
parity, not the optional KVM↔HVF diagnostic portability track.

First land the identical-host hot fork path in incremental steps. The interim
KVM step uses a local `ram.backing` file and trusted same-host opt-in to open a
backing fd, then the KVM backend maps that fd privately CoW without resolving
manifest paths. HVF uses the same trusted file-backed private mapping shape with
`hv_vm_map`. The fdpass harness mode proves the same `SCM_RIGHTS` handoff shape
the monitor will use, but the robust monitor wiring still has to replace the
harness path opener with a sealed `memfd`/file-backed mapping owned by the
monitor. For cold lazy restore, first keep eager behaviour but expose validated
per-chunk CAS loading plus restore metrics; then map memory empty and
materialize chunks on fault with an explicit userfaultfd KVM mode on Linux and
unmapped-memory exits on HVF. Record an access trace on first resume; use it for
readahead on later resumes. Benchmark resume time-to-first-instruction and
time-to-useful-work against slice 3's eager restore.

Done when: 100 concurrent same-host forks of one 512MiB spore run distinct
workloads with aggregate child PSS proportional to the resident parent backing
plus dirty child working sets, not N × RAM; summed RSS is reported only as a
diagnostic because it double-counts shared pages. Resume TTFI is independent of
RAM size on the primary KVM host class and on HVF→HVF, and the benchmark
harness tracks both where CI hardware exists (or records manual runs where it
does not). KVM proves the Linux CI economics first; HVF→HVF has the same-backend
parity proof, while KVM↔HVF cross-restore remains a
separate diagnostic goal.

### Slice 6: Identical-host fan-out distribution

Status: in progress. Local chunkpack bundles with canonical `bundle_digest`
output, the first two-host S3/SSM remote restore smoke, a host-local
cache-backed repeat restore smoke, a source-peer HTTP seed proof, and corrupted
distributed-bundle rejection checks have landed. A ten-instance single-source
peer fan-out smoke and a ten-instance source→relay→leaf tree smoke have also
passed with zero destination S3-origin bytes. Multi-peer/cache-hierarchy fan-out
and measured origin-egress efficiency beyond an explicit relay tree remain.

Start with a local bundle/chunkpack format, then add distribution adapters.
`spore pack` writes a portable bundle containing a manifest with local RAM
backing stripped plus a `chunkpack.index.json` mapping BLAKE3 chunk ids to
offsets inside larger pack blobs. `spore unpack` reconstructs a normal spore
directory and re-verifies every logical chunk before it can be restored. This
first slice deliberately avoids registry auth, tag semantics, upload sessions,
and direct-registry fan-out assumptions while the pack shape is still changing.

Later Slice 6 work adds storage and fan-out backends around the same bundle
primitive: OCI or object storage as a durable publication boundary, a
`spore daemon` local CAS/cache, and peer or cache-hierarchy distribution so N
restores cost a small multiple of the unique chunks rather than N full origin
downloads. The current script can prove per-host cache reuse with
`--cache-dir` and `--dest-repeat`, and it can prove first-fetch reduction from
the durable origin with source-peer HTTP seeding via `--source-peer-ip`; it also
corrupts one fetched bundle copy per destination to keep peer/origin trust tied
to chunk verification. Tree mode (`--tree-relay INSTANCE_ID:IP`) proves a small
fleet can bound source peer egress by relay count, but it is still an explicit
test topology rather than the final daemon-selected peer graph or cache
hierarchy. Scale tests at 100 → 1,000 identical hosts happen before claiming
10,000.

Done when: a multi-host fan-out demo restores one spore on every host in a
test fleet with origin egress measured at a small multiple of the unique chunk
set, and chunk verification rejects corrupted peer data.

### Slice 7: Always-on dirty tracking

Status: started on KVM and HVF. The first Linux harness path uses KVM dirty
logging rather than dirty ring: it keeps the spore chunk refs and trusted same-host
`ram.backing` up to date during execution, explicitly marks VMM-side guest RAM
writes that KVM dirty logging cannot see, and records paired full-scan vs
dirty-log metrics. The first A1 numbers show suspend pause dropping from
~4.0s→2ms at 512MiB, ~27.1s→2ms at 4GiB, and ~106s→5ms at 16GiB, with chunk
sealing paid before suspend. `KVM_GET_DIRTY_LOG` overhead was negligible in the
16GiB run (`get_dirty_log_ms=3` total), so dirty ring is deferred until polling
shows up in larger RAM, many-vCPU, or many-VM measurements. Product monitor
background threading has started with a KVM worker that removes periodic
sealing from the vCPU loop and reports worker/jitter/CPU rates. The first 512MiB
worker run validated resume and trusted backing, but an active-boot snapshot at
3s still had `tail_flush_ms=510` / `snapshot_pause_ms=512` because the worker
had not fully caught up with the boot dirty burst (`worker_epoch_max_ms=1111`,
`sealed_chunks_per_sec=8`). The benchmark harness now supports concurrent
captures with `--parallel-vms`; the first two-VM 512MiB dirty-log run produced
two JSONL rows with the same ~512ms active-boot tail profile, giving us a
repeatable local many-VM shape before asking for more metal. HVF
write-protect tracking has also landed behind `hvf-boot --dirty-track` and the
fan-out smoke's `--dirty-track` capture option. The first 512MiB local HVF run
validated same-host forks from trusted `ram.backing` with
`snapshot_pause_ms=109` / `tail_flush_ms=87`. The dirty benchmark harness now
also accepts `--backend hvf`; its first 512MiB write-protect JSONL row reported
`snapshot_pause_ms=80` / `tail_flush_ms=71`, confirming the measurement path is
not tied to ad hoc fork-smoke log scraping. Larger single-VM local HVF runs then
reported `snapshot_pause_ms=95` / `tail_flush_ms=72` at 1GiB and
`snapshot_pause_ms=126` / `tail_flush_ms=92` at 4GiB; a two-concurrent-VM
512MiB run reported `snapshot_pause_ms=124` and `127`, both with
`tail_flush_ms=88`. This keeps the first macOS write-protect curve roughly flat
with RAM size for the active-boot smoke, but 16GiB and higher-concurrency macOS
CI scale runs remain before treating it as a product boundary. A later 512MiB
HVF run at an 8s snapshot delay dropped to `snapshot_pause_ms=29` /
`tail_flush_ms=15`, so active-boot dirty backlog is measurable; KVM and HVF now
also report `dirty_chunks_tail` to make that backlog explicit.

Continuous epoch-based chunk sealing during normal execution; suspend becomes
pause + tail flush. First move epoch collection/sealing out of the vCPU loop
and record steady-state jitter/CPU overhead for the existing KVM dirty-log path.
Then measure HVF write-protect exits. If HVF overhead is unacceptable, fall
back to suspend-time scanning on macOS and record that as a platform support
boundary rather than blocking the release. Implement KVM dirty ring only if the
baseline dirty-log collector becomes material after backgrounding, larger RAM,
many-vCPU, or fleet-scale measurements.

Next execution order:

1. Use the worker metrics to compare one VM, many VMs, and larger RAM without
   changing APIs again; separate steady-state idle snapshots from active boot or
   workload dirty bursts.
2. Reduce dirty-tail lag where it matters: tune epoch cadence, consider
   immediate drain-on-snapshot before machine-state capture, and measure whether
   chunk hashing or backing writes dominate.
3. Expand HVF write-protect measurements on the macOS CI host across larger RAM
   and concurrent fork captures before treating the 512MiB local result as the
   product support boundary.
4. Revisit KVM dirty ring only if bitmap polling, not hashing/sealing or cold
   eager restore, shows up as a limiting cost.

Done when: suspend latency is measured flat across 1/4/16GB guests on Linux,
and the HVF overhead decision is recorded with numbers.

### Slice 8: Cross-backend diagnostic restore

Cross-backend restore is valuable for inspecting failed runs on a different
developer machine and proving the state contract is not accidentally backend
private. It is not the fork/fan-out release gate. Continue normalizing the
deltas surfaced by slice 3: GIC state mapping, timer offset handling, CPU
feature-ID profile masking at creation, and fail-closed contract checks.

Done when: the four-direction matrix (KVM→KVM, HVF→HVF, KVM→HVF, HVF→KVM) is
documented with passing or intentionally rejected smoke outcomes, and at least
one positive cross-backend direction works on compatible timer-profile hosts.

### Follow-up (separate plans)

- Cleanroom backend adapter (lives in the cleanroom repo).
- Fleet coordinator / scheduling, WAN distribution profiles.
- Memory ballooning and free-page reporting to shrink manifests.
- libkrun-style TSI or alternative network backends.

## Verification

- Unit: DTB generation, virtqueue handling, manifest encode/decode, chunk CAS,
  feature-ID masking. `zig build test` on every commit, both platforms.
- Fuzzing: virtqueue descriptors, manifest/chunk decode, generation device
  inputs. Fuzz targets are added in the same slice as the parsing code and run
  continuously in CI.
- Smoke (real hardware): boot on KVM and HVF; suspend/resume matrix; fork
  storm; lazy-restore TTFI; one-shot `spore run` true/false exit propagation.
  Fork-storm smokes must report child count,
  fork/resume latency, aggregate child PSS, RSS as a diagnostic, and
  private/dirty-child working-set estimates so we distinguish real CoW sharing
  from simply provisioning more RAM. Scripts in `scripts/` run identically in
  CI and by hand. Hosts come from the
  `cleanroom-ops` fleet (aarch64 KVM dev boxes; Apple Silicon for the HVF
  side).
- Benchmarks: suspend latency vs RAM size, fork latency, resume TTFI and
  time-to-useful-work, dirty-tracking steady-state overhead. Tracked from the
  slice that introduces each mechanism, regressions visible in CI output.
- Security: jail profiles tested by attempting denied syscalls; chunk
  verification tested with corrupted inputs.

## Key Learnings From Pressure-Testing

- The riskiest product claim is cheap fork/fan-out, not cross-backend restore.
  Cross-backend portability remains useful for inspecting failed runs and
  detecting backend-private leaks in the state contract, but it must not pull
  effort away from identical-host fork, lazy restore, and distribution.
- HVF→HVF elastic RAM is not part of the cross-backend portability nice-to-have.
  It is same-backend product parity for Apple Silicon hosts. KVM can lead the
  implementation because it is the CI release-critical host class, but the plan
  should not describe HVF same-host memory mechanics as optional portability.
- A 100-child eager-restore smoke mostly measures host RAM capacity. The
  architecture gate for high-concurrency same-host fan-out is elastic RAM:
  children must CoW-share the paused parent's backing and pay only for dirty
  child pages. Slice 4 therefore proves generation correctness; Slice 5 proves
  memory economics.
- Dirty collection is not currently the limiting KVM cost: at 16GiB,
  `KVM_GET_DIRTY_LOG` took only milliseconds while initial seeding, chunk
  sealing, and cold eager resume took seconds. Keep dirty ring as a scale
  optimisation, not the next implementation step.
- HVF dirty-tracking cost has a passing 512MiB local write-protect result, but
  larger RAM and concurrency are still unmeasured. Slice 7 carries an explicit
  fallback (suspend-time scanning on macOS) and a measurement gate, so the
  always-checkpoint-ready property can land asymmetrically without blocking
  release.
- Fork without guest cooperation silently produces duplicate entropy, machine
  ids, and stale clocks — bugs that look like flaky tests months later. The
  generation device and fixup protocol are therefore part of the fork slice
  itself, not a hardening follow-up, and the fork storm test asserts identity
  and entropy divergence explicitly.
- Zig at the trust boundary is only defensible if fuzzing and jailing are
  founding constraints. Fuzz targets are required in the same slice as each
  parser, and the jail lands before the first release.
- 10,000-host fan-out claims are easy to write and expensive to validate. The
  distribution slice gates public claims behind measured 1,000-host runs.
- Scope creep in the device model is the main long-term threat to both
  security and portability. The device list is frozen in this plan; additions
  require editing this document.

## Resolved Decisions

- Language is Zig; shipping builds are ReleaseSafe only.
- aarch64-only; virtio-mmio-only; device list frozen as specified above.
- Machine state is stored as normalized architectural state, never raw
  hypervisor structs.
- The checkpoint artifact is called a spore; the manifest is versioned; v0
  formats carry no compatibility promise.
- Spore distribution starts with a SporeVM chunkpack bundle. OCI remains a
  likely publication adapter, but not the hot 10,000-host fan-out data plane by
  itself.
- The first `spore run` primitive is a local one-shot boot/exec/status command
  over virtio-vsock with default run assets and explicit kernel/initrd
  overrides. It streams stdout/stderr, exits with the guest status, supports
  explicit read-only rootfs images, and can build or reuse cached OCI-derived
  rootfs images for explicit argv execution. The named lifecycle surface is a
  separate top-level `create`/`exec`/`rm`/`ls` plus diskless
  `suspend`/`resume --name` flow over one per-VM monitor process. Stdin, TTY,
  broader OCI runtime semantics, KVM monitor mode, disk-backed lifecycle
  suspend/resume, and bundle-aware run semantics remain later work.
- Product capture starts as `spore run --capture-on-abort`: running a new
  workload can optionally write a spore snapshot when the host run process is
  interrupted, then exit. Resuming from an existing spore is a distinct
  `spore resume` operation. Do not add a separate `spore capture` verb before
  the run/resume surface proves out.
- Control integration is newline-delimited JSON over a unix socket, mirroring
  the proven cleanroom helper pattern.
- SporeVM is standalone; cleanroom integrates via an adapter in its own repo.
- Cross-backend restore is a diagnostic portability track, not the release
  gate for fork/fan-out on identical hosts.
- Same-host fan-out uses explicit RAM-backing transfer and private CoW mappings
  before claiming high-concurrency memory efficiency. Linux starts with
  `memfd`/file-backed RAM plus `SCM_RIGHTS`; HVF uses same-host private
  file-backed mappings plus abort-exit lazy chunk mapping for Apple Silicon
  parity. KVM proves the release-critical Linux CI economics first, but HVF
  same-backend elasticity is not classified as cross-backend portability.
- KVM dirty tracking stays on the `KVM_GET_DIRTY_LOG` baseline until benchmark
  evidence shows bitmap polling is material. Dirty ring is an optimisation path,
  not required for the next Slice 7 milestone.
- MIT licensed from the first commit, but the repository stays private for
  now. The identical-host fork/fan-out demo is the natural moment to revisit
  going public.
- Development and CI hosts come from the `cleanroom-ops` fleet rather than
  new infrastructure. Smoke and benchmark jobs are CI-enforced as soon as the
  fleet exposes an aarch64 KVM runner and an Apple Silicon macOS 15+ runner;
  until then results are recorded manually in the plan.
- Zig toolchain pinned via mise to the latest stable release at slice 0,
  upgraded deliberately per release.
- Guest kernels are built and published by the `cleanroom-kernels` repo.
  Cleanroom-owned `rootfs` and `initrd` profiles cover normal boot/restore
  smokes; `sporevm-run-arm64-linux-<version>` covers `spore run` initrd and
  rootfs execution. Legacy `sporevm-arm64-linux-<version>` assets cover fork
  smokes that need userspace access to SporeVM's fixed generation MMIO window.
  Kernel build ID is not yet in the platform contract; adding it is required
  before claiming cross-host disk-backed restore. Vendoring the config into
  this repo remains the recorded fallback if SporeVM must be self-contained
  when it goes public.
- With the aarch64 KVM dev host available, proceed with a direct KVM backend
  first. Keep the QEMU-assisted GICv3 cross-check as a diagnostic fallback,
  not as a blocker before KVM restore.

## Open Questions

None currently.
