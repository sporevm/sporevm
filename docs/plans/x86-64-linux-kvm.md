---
status: active
last_reviewed: 2026-07-20
spec_refs:
  - docs/spore-format.md
  - docs/state-portability.md
  - docs/memory.md
  - docs/lifecycle.md
  - docs/rootfs.md
  - docs/libspore.md
  - SECURITY.md
  - src/architecture.zig
  - src/x86_64/board.zig
  - src/x86_64/cpu_profile.zig
  - src/x86_64/vm.zig
  - src/kvm/common.zig
  - src/kvm/x86_64.zig
related_plans:
  - docs/plans/automatic-memory.md
  - docs/plans/multi-vcpu-nondestructive-save.md
  - docs/plans/spore-build.md
---

# x86-64 Linux/KVM Support

## Summary

Add x86-64 as a second SporeVM guest architecture on x86-64 Linux hosts using
KVM. The product keeps the existing command model, virtio-mmio device model,
rootfs and disk formats, generation semantics, lifecycle behaviour, and
fail-closed restore policy. Linux x86 hosts execute `linux/amd64`; ARM hosts
continue to execute `linux/arm64`.

This is an architecture port, not a new public backend. `--backend kvm` remains
the Linux hardware-virtualization backend, with the host architecture selecting
its machine implementation. SporeVM never translates between instruction sets:
offline tools may inspect and transfer either architecture, but execution
requires a matching architecture and compatible machine profile.

## Current State

| Area | Status | Durable owner or proof |
| --- | --- | --- |
| Board, boot, SMP, finite PIO/MMIO policy | Complete | `src/x86_64/`, `docs/spore-format.md`, `SECURITY.md` |
| Same-host CPU and clock profile | Complete | `src/x86_64/cpu_profile.zig`, `sporevm-x86_64-v0` |
| Shared and architecture-specific KVM UAPI | Complete | `src/kvm/common.zig`, `src/kvm/x86_64.zig` |
| Architecture, host-info, artifacts, runner | Complete | `src/architecture.zig`, `src/platform.zig`, `src/x86_64/vm.zig`, `build.zig` |
| Managed fresh product execution | Complete | `mise run smoke:x86-slice3a` on native x86 KVM |
| OCI/rootfs/network/image commit | Next: Slice 3b | Product gates remain closed |
| Native build and standalone libspore | Pending: Slice 3c | Product gates remain closed |
| Saved machine state and lifecycle parity | Pending: Slices 4–5 | No x86 manifest writer yet |
| High/automatic memory and performance | Pending: Slice 6 | Product requires one vCPU and explicit 512 MiB |
| Packaging and supported release | Pending: Slice 7 | No x86 support claim yet |

The current product path is experimental and fresh-only: Linux/x86-64 KVM, one
vCPU, and explicit 512 MiB memory. OCI/rootfs, networking, build, libspore,
capture, fork, automatic memory, and release paths remain fail closed.

## Scope

Deliver the complete existing fresh, build, save, restore, fork, bundle, named
lifecycle, networking, memory, CLI, and libspore contracts on x86-64 Linux/KVM.
Use native `linux/amd64` workloads, normalized x86 machine state, one frozen
virtio-mmio device model, and same-host-class portability. Preserve existing
ARM behaviour and byte-compatible aarch64 v2/v3 manifests.

This plan does not add x86 Hypervisor.framework, emulation, cross-ISA
conversion, Windows support, PCI/ACPI/firmware boot, nested virtualization,
cross-platform build emulation, arbitrary cross-vendor restore, persisted
virtio-mem state, or a speculative hypervisor/run-loop framework.

## Product Contract

### Canonical names

| Surface | ARM | x86 |
| --- | --- | --- |
| Spore/backend architecture | `aarch64` | `x86_64` |
| OCI and CLI platform | `linux/arm64` | `linux/amd64` |
| Zig target | `aarch64-linux-musl` | `x86_64-linux-musl` |
| Host class prefix | `linux-arm64-kvm` | `linux-amd64-kvm` |
| Candidate CLI release archive (Slice 7) | `spore_Linux_arm64` | `spore_Linux_x86_64` |

`src/architecture.zig` owns the vocabulary; `src/platform.zig` and release
scripts own derived host-class and asset names. Architecture remains part of
rootfs, cache, artifact, benchmark, and release identity.

### Compatibility

Offline tools are architecture-agnostic. Execution reads validated manifest or
OCI metadata and rejects mismatches. The first x86 portability level is
`approved_same_host`: restore requires the exact board/CPU profile, including
CPUID, MSRs, XSAVE/XCRS, interrupt state, TSC frequency, and clock controls.

## Invariants For Remaining Work

1. **KVM stays one backend.** Do not encode architecture in backend names.
2. **The board and device model are frozen.** The x86 board remains
   `sporevm-x86_64-board-v0`, device-model version 1, with its documented
   device, interrupt, MP, PIO, generation, and lifecycle-control contract.
3. **The CPU profile is explicit.** Guest CPUID is an allowlisted profile, not
   serialized host CPUID. Unsupported state and VMX/SVM remain hidden.
4. **Saved state is normalized and fail-closed.** Never serialize raw KVM
   structs or padding, publish partial capture, or run before complete restore.
5. **Guest memory has one checked boundary.** Slice 6 replaces the current one
   low region/slot with bounded regions over one linear backing VMA.
6. **ARM manifests do not migrate.** Existing aarch64 v2/v3 bytes retain their
   parser, writer, and implicit single-region meaning. The first v4 writer is
   x86-only.
7. **Share concrete mechanics, not run-loop shape.** Extract capture mechanics
   only when ARM and x86 are both real consumers.
8. **Native evidence gates claims.** Clock, snapshot, dirty-memory, multi-vCPU,
   performance, packaged, and release gates run on dedicated x86 hardware.
9. **Unsupported paths fail before effects.** Reject before downloads, cache,
   disk, network, runtime publication, or VM execution.

## Architecture Layout

ARM-owned board, boot, FDT, GIC, and MPIDR topology code lives under
`src/aarch64/`. Shared vCPU count validation remains in `src/topology.zig`, and
the backend-neutral KVM selector, common ABI, and lazy RAM implementation remain
under `src/kvm/` beside explicitly named architecture bindings and AArch64 VM
and snapshot modules. The architecture trees do not force false file parity:
FDT/GIC are ARM-specific while MP tables, PIO, and the CPU profile are
x86-specific.

## Remaining Delivery Strategy

Three tracks can now proceed independently:

```text
workload:  3b ───────────────┐
build/API: 3c ───────────────────────────────────────────┐
capture:   4a -> 4b ────────┤                            │
                              v                            │
                            4c -> 4d -> 5 -> 6 -> 7 <─────┘
```

Slice 4c waits for Slice 3b because saved product lifecycle must preserve OCI,
rootfs, network, and session state. Slice 3c does not block early capture work,
but it gates release. After Slice 4, the remaining order is strict because
multi-vCPU lifecycle builds on fixed-memory capture, segmented memory builds on
that lifecycle, and release requires the complete product contract.

### Slice 3b: OCI, rootfs, networking, and image commit

- Accept and preserve `linux/amd64` across registry selection, OCI layouts,
  refs, rootfs metadata, and caches; reject non-native execution.
- Route image run/commit through the existing writable/layered rootfs and
  immutable-input contracts.
- Enable the shared network policy graph and run DNS, HTTP, deny, bind, and
  forwarding smokes on native x86 KVM.
- Remove gates only with complete side-effect ordering and native coverage.

**Done when:** fresh amd64 image execution, rootfs mutation, image commit, and
the network policy matrix pass natively without enabling capture.

### Slice 3c: Native build and libspore fresh run

- Make `spore build` use the native platform, `TARGETARCH=amd64`, and
  architecture-scoped inputs, executor, caches, and OCI config; run the existing
  conformance suite without emulation.
- Route standalone libspore fresh-run APIs through the reviewed x86 product
  path while capture APIs remain explicitly unavailable.
- Cross-check Zig, C, and Go architecture surfaces needed by Slice 7.

**Done when:** Dockerfile builds and standalone development libspore fresh-run
smokes pass on x86, with unchanged ARM build behaviour.

### Slice 4: Manifest v4 and fixed-memory capture

Slice 4 uses one vCPU, one low RAM region, and one KVM slot. High RAM and
automatic memory remain Slice 6 work.

#### Stage 4a: Specify and parse x86 manifest v4

- Specify the exact v4 x86 platform, memory-region, vCPU, interrupt-controller,
  and clock schema in `docs/spore-format.md` and `docs/state-portability.md`.
- Replace nullable private v2/v3 loaded-manifest modes with a tagged ownership
  union, then add v4 as the x86 tag.
- Bound version dispatch, vCPU/MSR/XSAVE/controller counts, region count, and
  allocation; validate the future region schema while execution accepts one.
- Extend manifest fuzzing and prove byte-compatible v2/v3 parsing and writing.

**Done when:** offline inspect and round-trip accept valid v2/v3/v4 manifests
and reject malformed or cross-architecture state without executing KVM.

#### Stage 4b: Capture and restore one vCPU

- Extract shared capture mechanics without copying the mature loop or adding a
  generic runtime trait.
- Normalize general/segment/control state, configured CPUID, XCRS, approved
  XSAVE bytes, the approved MSR set, LAPIC, vCPU events, debug and MP state,
  VM clock, PIC, IOAPIC, PIT2, board/profile identities, transport/generation
  state, RAM, rootfs, and disks.
- Test complete restore ordering and required SET/GET readback before the first
  `KVM_RUN`, then prove process-boundary eager restore and monotonic clocks.

**Done when:** a fixed-memory single-vCPU x86 spore restores eagerly with no
pre-restore vCPU execution or backwards guest time.

#### Stage 4c: Wire public save, restore, and bundles

- Enable `run --save`, `run --from`, inspect, pack, unpack, push, and pull for
  x86 while preserving OCI/rootfs, network, annotation, generation, and
  session state.
- Route CLI/libspore through one compatibility boundary and prove bundle
  transfer/restore on a compatible destination.

**Done when:** a captured x86 spore survives public bundle round trips on the
same compatible host class.

#### Stage 4d: Add fixed-memory restore modes and offline fork

- Add local/lazy restore, dirty tracking, capture-on-signal, and offline fork
  while retaining one low region.
- Validate generation, dirty observations, restore-mode equivalence, disk
  authority, and fail-closed publication.

**Done when:** all fixed-memory single-vCPU restore modes and offline fork pass
on the same compatible host class.

### Slice 5: Multi-vCPU and named lifecycle parity

#### Stage 5a: Multi-vCPU capture and restore

- Add normalized per-vCPU topology and complete per-vCPU state under v4.
- Reuse the MP-table implementation; pause every vCPU without losing completed
  exits or wakes.
- Capture per-vCPU LAPIC plus shared IOAPIC/PIC/PIT/clock state.

**Done when:** multi-vCPU run, save, and process-boundary restore preserve CPU,
interrupt, device, and clock state.

#### Stage 5b: Fork and non-destructive save

- Add multi-vCPU offline fork, non-destructive save, and disk-backed live fork
  while keeping the source runnable beside restored children.
- Prove independent generation, disk authority, and pause-barrier behaviour
  under concurrent source and child execution.

**Done when:** source and restored/forked children run concurrently without
sharing mutable generation or disk authority.

#### Stage 5c: Named lifecycle

- Enable named create, exec, copy, save, remove, restore, and fork through the
  already-proven multi-vCPU state and disk layers.
- Run the current named lifecycle contracts unchanged on x86.

**Done when:** x86 passes the same fixed-memory named lifecycle graph as ARM,
including a running source beside restored or forked children.

### Slice 6: Segmented memory, automatic memory, and performance

#### Stage 6a: Introduce and use bounded memory regions

- Replace device-facing contiguous `GuestRam` with a small sorted region table
  mapping GPA ranges to offsets in one contiguous host backing VMA.
- Require page alignment, nonzero bounded sizes, checked ends, strictly sorted
  non-overlapping GPA ranges, gap-free backing ranges from offset zero, exact
  logical-size coverage, and no board-hole overlap.
- Reject device/virtqueue accesses crossing regions or holes; add bounds tests
  and fuzzing. Adapt aarch64 through one implicit region without changing v2/v3.
- Add x86 low/high KVM slots, generate E820 from the same validated regions,
  and translate each slot's dirty log back to backing offsets.
- Extend userfaultfd, local/lazy restore, chunking, and sealing across all slots
  while keeping one registration over the linear backing VMA.

**Done when:** high-RAM x86 boots, dirty observations select the right backing
chunks, single-region v4 still restores, and ARM memory/snapshot regressions
remain green.

#### Stage 6b: Restore automatic memory

- Place transient x86 virtio-mem above fixed high RAM without colliding with
  board holes or device MMIO.
- Keep transient state unsavable and normalize capture to fixed RAM, matching
  the existing product contract.
- Run sparse 16 GiB fresh and lifecycle accounting smokes.

**Done when:** omitted `--memory` exposes the documented sparse 16 GiB x86
contract and saved state contains only fixed RAM.

#### Stage 6c: Establish performance evidence

- Validate dirty logging, VMM dirty observations, lazy faults, and O(dirty)
  disk snapshots across segmented regions.
- Establish architecture-separated startup, restore, fork, save-pause, disk,
  network, and build baselines.

**Done when:** architecture-specific history can detect regressions and the
ordinary x86 memory contract is ready to advertise.

### Slice 7: Package and release

- Build a fixture release and run supported mise/ubi selectors before freezing
  CLI and libspore asset names. Preserve the existing ARM libspore compatibility
  asset until supported clients can select unambiguous architecture names.
- Add native x86 Buildkite unit, smoke, packaged-smoke, and benchmark steps on
  the repository-owned queue.
- Publish x86 CLI/libspore archives with complete checksum, selector,
  installer, release dependency, and standalone C/Go smoke coverage.
- Repeat the CPU/clock profile and packaged correctness proof on a replacement
  or second machine of the same declared host class.
- Require exact-head ARM64 KVM, ARM64 HVF, and x86-64 KVM proofs before the
  first release claiming x86 support.
- Update durable docs, README, release notes, and support statements in the
  release change.

**Done when:** a tagged release installs and passes packaged native smokes on
all three supported host/backend combinations.

## Development Host Contract

Native validation requires an x86-64 Linux host with `/dev/kvm`, KVM API 12,
the approved profile capabilities, hardware virtualization, sufficient sparse
RAM for the 16 GiB smoke, and local storage suitable for overlays and chunk
stores. Nested KVM may cover fresh-run work, but later native gates require
dedicated hardware. Ops owns provisioning and queue registration; this repo
owns the probe, profile predicate, acceptance commands, and `host-info` report.

## Validation

Every slice keeps ARM64 KVM/HVF green and uses narrow local checks before these
cumulative native gates:

| Capability | Local/cross-build proof | Native x86 proof |
| --- | --- | --- |
| Build and fresh execution | unit tests, x86 musl build | managed fresh/exec smoke |
| OCI/rootfs/network/build | parser and conformance tests | workload and policy matrices |
| Manifest and machine state | codec, bounds, fuzz, restore-order tests | process-boundary capture/restore |
| Multi-vCPU lifecycle | topology and state tests | save/fork/named lifecycle matrix |
| Segmented/automatic memory | region, boundary, dirty-map fuzz/tests | high-RAM, lazy/local, sparse 16 GiB |
| Packaging | archive, selector, installer tests | packaged CLI plus C/Go libspore |
| Performance | benchmark parser/comparison tests | separate x86 baseline |

Native evidence uses the exact candidate commit and managed artifacts.
Cross-compilation never substitutes for `/dev/kvm`; release evidence retains
host-info, artifact identity, capability output, checksums, and smoke logs.

## Security And Failure Rules

- Treat guest registers, exits, virtqueues, memory regions, and manifests as
  attacker-influenced; bound KVM inventories before allocation or replay.
- Fuzz every new attacker-controlled parser, decoder, or memory translator.
- Complete pending exits, preserve wakes, and join vCPUs before unmapping
  `kvm_run` pages.
- Hide CPU features without complete save/restore; reject unknown state.
- Preserve the monitor jail, test x86 seccomp natively, and ship ReleaseSafe.

## Documentation Work

Update each durable owner in the slice that changes it: format and portability
in Slice 4, lifecycle in Slices 4–5, memory in Slice 6, rootfs/libspore with
Slices 3b–3c, and security alongside every new boundary. Update README and
release notes only when packaged support is proven.

## Deferred Decisions

- Libspore archive names wait for the Slice 7 mise/ubi fixture.
- Broader host compatibility waits for a new named profile and proof.
- A common machine/run abstraction waits for two concrete consumers.

## Done When

All remaining slices and their native gates pass: the complete x86 product
contract works, strict v4 preserves aarch64 v2/v3 compatibility, segmented and
automatic memory do not regress ARM, and Slice 7 ships reproducible packages,
performance history, exact host reporting, and current durable docs.
