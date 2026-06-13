---
status: proposed
last_reviewed: 2026-06-13
related_plans:
  - buildkite/cleanroom: docs/plans/sandbox-suspend-wake.md
---

# SporeVM Foundation Plan

## Summary

SporeVM is a virtual machine monitor for aarch64 Linux microVMs that treats a
suspended VM as a cheap, portable, forkable object. One codebase targets two
hypervisors — KVM on Linux and Hypervisor.framework (HVF) on macOS — with an
identical minimal virtio-mmio device model on both, so a VM suspended on one
host can resume on the other. It is written in Zig.

The defining design property is that no lifecycle operation scales with RAM
size. A running VM is permanently checkpoint-ready: dirty pages stream
continuously into a content-addressed store, so suspend is a pause plus a small
tail flush, fork is a metadata write, and resume is bounded by the working set,
not by memory size. The sealed checkpoint artifact is called a **spore**: a
manifest of content-addressed memory and disk chunks plus a small normalized
machine-state blob. Spores are the unit of suspend, fork, fan-out, and
cross-platform transfer.

The end state this plan drives toward:

```console
spore create --kernel ... --disk ... my-vm
spore suspend my-vm                 # ~50ms regardless of RAM size
spore fork my-vm --count 10000     # metadata-only, sub-second
spore pull <spore-id> && spore resume <spore-id>   # on a different OS
```

SporeVM is a standalone project with its own CLI and control API. Cleanroom is
the first expected consumer through a backend adapter, but nothing in this
repository depends on cleanroom.

## Problem

There is no VMM today that can suspend a Linux VM on a Linux host and resume it
on macOS, or fork suspended state across thousands of hosts without copying
memory images around:

- Firecracker snapshots are KVM-only and tied to its device model.
- Apple Virtualization.framework saved state is opaque, version-locked, and not
  portable even between Macs.
- QEMU runs on both but is heavyweight, and cross-accelerator (KVM→HVF)
  restore is unproven in production.
- All of them treat a snapshot as a monolithic file whose cost scales with RAM.

Cross-hypervisor portability requires owning the device model and the vCPU
state encoding on both sides. Cheap fan-out requires memory to be
content-addressed and lazily materialized. Both point at the same conclusion:
a purpose-built VMM where the snapshot format is the product.

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
- Suspend/restore on the same host, then restore across hypervisors in all
  four directions (KVM→KVM, HVF→HVF, KVM→HVF, HVF→KVM).
- Content-addressed chunked memory and disk with lazy, fault-driven restore.
- O(1) fork with a guest-cooperative fixup protocol (identity, entropy, time).
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
- Network egress policy, secret mediation, OCI image handling, or workspace
  semantics. Those belong to consumers like cleanroom.
- Preserving open TCP connections across cross-host resume.
- Multi-tenant public-cloud hardening claims. The v0 threat model is
  self-hosted CI/agent isolation: an untrusted guest must not escape the VMM,
  but we do not claim Lambda-grade multi-tenancy.
- Backwards compatibility before 1.0. The spore format is versioned and v0
  formats may be discarded.

## Target Model

### Process and API surface

`spore` is a single binary: CLI subcommands plus a long-running per-VM monitor
process. Consumers integrate over a newline-delimited JSON control protocol on
a per-VM unix socket (the cleanroom helper pattern), so the Zig core is
invisible at the integration seam.

```console
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

A spore embeds a platform contract: aarch64, pinned kernel build ID, device
model version, and a CPU feature-ID profile (the common denominator of Apple
M-series and AWS Graviton, masked at VM creation). Restore fails closed when
the host cannot satisfy the contract. The guest kernel config starts from
cleanroom's managed-kernel config with virtio-mmio, vsock, and the generation
driver enabled.

### Spore manifest v0

```text
spore manifest
├── platform contract (arch, kernel build, device model ver, CPU profile)
├── machine state: architectural vCPU state per CPU, GICv3 state,
│   virtio queue state, timer offsets — normalized, hypervisor-neutral
├── memory manifest: ordered chunk refs (blake3, zstd), zero-elided
├── disk manifest: chunk refs over the block device
└── access trace: page-touch order from prior resumes (prefetch hint)
```

Chunks live in a local CAS directory; manifests are small JSON/CBOR documents.
Spores are exportable as OCI artifacts so existing registries (and cleanroom's
gateway/content-cache) can serve them.

### Memory and lifecycle model

Guest RAM is a VMM-owned file-backed mapping registered with the hypervisor.
Three mechanisms hang off that:

- **Dirty tracking**: KVM dirty ring on Linux; write-protection fault exits on
  HVF. A background thread seals dirty pages into CAS chunks on an epoch
  cadence. Suspend = pause vCPUs + flush current epoch + serialize machine
  state.
- **Lazy restore**: pages materialize on fault — userfaultfd on Linux,
  unmapped-memory vm-exits on HVF — backed by local CAS, then peers, then
  origin. The access trace drives readahead so the guest does useful work
  while the tail faults in.
- **Fork**: mint a new manifest referencing the parent's chunks (CoW), assign
  a new VM identity, resume with the generation counter incremented. The guest
  agent reacts: machine-id/hostname/MAC fixups, RNG reseed via virtio-rng,
  forced clock step, "generation changed" signal to userspace.

### Ownership boundaries

- SporeVM owns: hypervisor interaction, device model, spore format, CAS,
  lazy paging, fork mechanics, the generation device, and the in-guest fixup
  helper.
- Consumers own: rootfs/image preparation, network policy and egress
  enforcement, secrets, scheduling across hosts, and what workloads run.
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
- Chunks are verified against their blake3 id before being mapped into guest
  memory; a malicious peer can deny service but not inject state.
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
green (chunk-id module with BLAKE3 CAS identities and verification tests),
`spore` CLI stub with `version`/`help`, founding docs (`README.md`,
`SECURITY.md`, `AGENTS.md`, MIT `LICENSE`, `docs/spore-format.md`),
Buildkite pipeline targeting the `cleanroom` and `cleanroom-mac` queues, and
the QEMU cross-accelerator experiment designed in `docs/research.md`.

The planned QEMU KVM↔HVF proxy experiment has not run because direct SporeVM
HVF suspend/restore work landed first. `docs/research.md` records that result
as an explicit keep/adjust decision: keep architectural machine-state
normalization, but treat GICv3 CPU-interface state and virtual timer anchoring
as first-class normalized fields. The QEMU matrix remains useful once the KVM
side exists, but it no longer blocks the already-landed HVF foundation work.

Slice 2 (HVF boot) started ahead of slice 1 because the local dev machine is
an Apple Silicon Mac while the aarch64 KVM dev host is still being
provisioned. The HVF path boots the cleanroom 6.1.155 kernel to the expected
root-mount panic with working GICv3 interrupts, virtio-mmio console output,
and PSCI. HVF bring-up findings now encoded in `src/hvf/`:

- Apple's hv_gic emulates the redistributor/distributor *behavior* in-kernel
  but still traps GICD/GICR MMIO that misses its claimed ranges; the
  `hv_gic_{get,set}_*_reg` enums are architectural register offsets but the
  calls return HV_DENIED at runtime (they are save/restore APIs). Correct
  approach: set MPIDR_EL1 before querying `hv_gic_get_redistributor_base` and
  describe that exact frame in the DTB.
- The framework reserves a large redistributor region (32MB observed); the
  virtio-mmio window moved to 0x0c00_0000 to stay clear. This is a board
  contract value (`src/board.zig`).
- The cleanroom kernel has no PL011, so the first console is virtio-mmio
  virtio-console (hvc0) and early boot is blind until virtio probes.

Slice 2 has since reached an interactive shell on HVF: virtio-blk against a
cleanroom-built alpine ext4 rootfs, console input (rx queue plus idle-exit
stdin polling), minimal virtio-net (stable MAC, TX drain), a minimal
virtio-vsock closed endpoint, virtio-rng backed by host entropy, the frozen
generation MMIO device present/inert, and `init=/bin/sh` workloads run end to
end. Host networking remains a later backend attachment behind the shared net
transport.

Slice 3 has landed on the HVF side: spore manifest v0 (`docs/spore-format.md`,
`src/spore.zig`) with content-addressed zero-elided memory chunks, normalized
machine state (GPRs, SIMD, EL1 sysregs, ICC regs, virtual-timer re-anchoring),
hv_gic state blob capture/restore, virtio transport state, and generation
device state. Demonstrated: a shell counter loop snapshotted at tick 8 resumes
at tick 9 in a fresh process (`hvf-boot --snapshot-after-ms/--spore/--resume`).
A 512MiB idle guest spores to ~26MB. Key finding: GIC ICC (CPU-interface)
registers are not part of the hv_gic state blob and must be saved per-vCPU via
`hv_gic_{get,set}_icc_reg` —
without them the resumed guest hangs with all interrupts masked. v0 does not
capture disk state: resume requires the unmodified backing disk file
(documented in the format doc).

Slice 1 has now started on real aarch64 KVM hardware (`m7g.metal`): the
`kvm-boot` harness creates a KVM VM/vCPU, configures userspace VGICv3, maps the
same board DTB, and routes shared virtio-mmio/generation device exits. It boots
the cleanroom 6.1.155 kernel to the expected no-root VFS panic without a disk
and to an Alpine `/bin/sh` prompt with a mountless `mkfs.ext4 -d` minirootfs.

The KVM side now has same-host suspend/restore groundwork using the v0 spore
manifest: normalized KVM one-reg vCPU state, SIMD, EL1 sysregs, virtual-timer
re-anchoring via `KVM_ARM_SET_COUNTER_OFFSET`, virtio/generation state, eager
RAM chunks, and a backend-private VGICv3 JSON blob in `gic_state_b64`. A real
`m7g.metal` smoke test booted an Alpine BusyBox ticker, snapshotted after
`sporevm-tick 4`, and resumed in a fresh KVM process at `sporevm-tick 5`.
The four-way cross-hypervisor matrix (slice 4) remains next.

## Delivery Strategy

Each slice is a reviewable unit with a runnable result. KVM work needs an
aarch64 Linux host with KVM; HVF work needs an Apple Silicon Mac on macOS 15+.

### Slice 0: Repo scaffolding and de-risk experiment

Zig project skeleton (`build.zig`, pinned Zig toolchain via mise), CI that
builds and runs unit tests on both platforms, `SECURITY.md`, `AGENTS.md`,
`docs/spore-format.md`, MIT license, README stating the thesis.

In parallel, the cheapest possible validation of the riskiest claim, using no
SporeVM code: take a QEMU `virt` machine snapshot under KVM on aarch64 Linux
and attempt restore under HVF on macOS (QEMU upstream has in-flight HVF GIC
save/restore patches). Outcome is recorded in `docs/research.md` either way;
failure modes inform the machine-state normalization design.

Done when: CI is green on both platforms and the QEMU experiment writeup
exists with a clear keep/adjust decision for the normalization approach.

### Slice 1: Boot under KVM

Minimal KVM VMM on Linux aarch64: load the pinned kernel + initramfs, build
the device tree, virtio-mmio console only, serial output to stdout, clean
shutdown. `spore create --kernel ... --initrd ...` boots to a shell.

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
CAS. `spore suspend` / `spore resume` round-trips on the same host for both
KVM and HVF independently. Manifest decode gets a fuzz target.

Done when: a guest survives suspend/resume with running processes intact
(KVM→KVM and HVF→HVF), and `docs/spore-format.md` documents manifest v0.

### Slice 4: Cross-hypervisor restore

The headline result. Normalize the deltas the QEMU experiment and slice 3
surfaced: GIC state mapping, timer offset handling, CPU feature-ID profile
masking at creation, fail-closed contract checks.

Done when: the four-direction matrix (KVM→KVM, HVF→HVF, KVM→HVF, HVF→KVM)
passes a smoke test where the guest resumes mid-workload and the workload
completes correctly. This is the moment to announce the project.

### Slice 5: Lazy restore

Restore maps memory empty and materializes pages on fault: userfaultfd on
Linux, unmapped-memory exits on HVF. Record an access trace on first resume;
use it for readahead on later resumes. Benchmark resume time-to-first-
instruction and time-to-useful-work against slice 3's eager restore.

Done when: resume TTFI is independent of RAM size on both platforms and the
benchmark harness tracks it in CI (or a recorded manual run where CI hardware
does not exist).

### Slice 6: Fork and the generation protocol

`spore fork --count N` mints manifests CoW, resumes with incremented
generation. Generation device, in-guest fixup helper (machine-id, hostname,
MAC, RNG reseed, clock step, userspace signal). Same-host fork storm test.

Done when: 100 concurrent same-host forks of one spore run distinct workloads
with distinct identities, no entropy or clock anomalies, and fork latency is
measured in milliseconds.

### Slice 7: Always-on dirty tracking

Continuous epoch-based chunk sealing during normal execution; suspend becomes
pause + tail flush. Measure the steady-state overhead (KVM dirty ring vs HVF
write-protect exits) and make the epoch cadence tunable. If HVF overhead is
unacceptable, fall back to suspend-time scanning on macOS and record that as a
platform support boundary rather than blocking the release.

Done when: suspend latency is measured flat across 1/4/16GB guests on Linux,
and the HVF overhead decision is recorded with numbers.

### Slice 8: Distribution

`spore push`/`pull` against an OCI registry; `spore daemon` chunk cache with
peer chunk exchange; relay fan-out so N restores cost O(log N) origin work.
Scale tests at 10 → 100 → 1,000 hosts before claiming 10,000.

Done when: a multi-host fan-out demo restores one spore on every host in a
test fleet with origin egress measured at a small multiple of the unique
chunk set, and chunk verification rejects corrupted peer data.

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
  storm; lazy-restore TTFI. Scripts in `scripts/` so they run identically in
  CI and by hand. Hosts come from the `cleanroom-ops` fleet (aarch64 KVM dev
  boxes; Apple Silicon for the HVF side).
- Benchmarks: suspend latency vs RAM size, fork latency, resume TTFI and
  time-to-useful-work, dirty-tracking steady-state overhead. Tracked from the
  slice that introduces each mechanism, regressions visible in CI output.
- Security: jail profiles tested by attempting denied syscalls; chunk
  verification tested with corrupted inputs.

## Key Learnings From Pressure-Testing

- The riskiest claim is cross-hypervisor machine-state restore, and the
  cheapest test of it needs no SporeVM code. The QEMU KVM→HVF experiment was
  moved into slice 0 so a negative result reshapes the design before slices
  1–3 are built, not after.
- HVF dirty-tracking cost is unknown and could be materially worse than KVM's
  dirty ring. Slice 7 carries an explicit fallback (suspend-time scanning on
  macOS) and a measurement gate, so the always-checkpoint-ready property can
  land asymmetrically without blocking release.
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
- Spores are exportable as OCI artifacts rather than inventing a transport.
- Control integration is newline-delimited JSON over a unix socket, mirroring
  the proven cleanroom helper pattern.
- SporeVM is standalone; cleanroom integrates via an adapter in its own repo.
- The QEMU cross-accelerator experiment precedes VMM implementation.
- MIT licensed from the first commit, but the repository stays private for
  now. The slice 4 cross-hypervisor demo is the natural moment to revisit
  going public.
- Development and CI hosts come from the `cleanroom-ops` fleet rather than
  new infrastructure. Smoke and benchmark jobs are CI-enforced as soon as the
  fleet exposes an aarch64 KVM runner and an Apple Silicon macOS 15+ runner;
  until then results are recorded manually in the plan.
- Zig toolchain pinned via mise to the latest stable release at slice 0,
  upgraded deliberately per release.
- Guest kernels are built and published by the `cleanroom-kernels` repo via a
  SporeVM kernel profile (virtio-mmio, vsock, generation driver); the platform
  contract pins its build ID. Vendoring the config into this repo remains the
  recorded fallback if SporeVM must be self-contained when it goes public.
- With the aarch64 KVM dev host available, proceed with a direct KVM backend
  first. Keep the QEMU-assisted GICv3 cross-check as a diagnostic fallback,
  not as a blocker before KVM restore.

## Open Questions

None currently.
