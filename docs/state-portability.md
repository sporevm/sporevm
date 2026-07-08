# Spore State Portability Contract

**Status:** current implementation for manifest format v0, plus manifest-v1
capture/restore for multi-vCPU state on KVM and same-backend HVF. This document
records what SporeVM can capture, map, translate, and reject when restoring an
aarch64 spore across the KVM and Hypervisor.framework backends.

The spore format describes bytes on disk. This document describes the portable
meaning of those bytes: which guest-visible state is part of the contract, how
each backend maps it to native APIs, and when restore must fail closed.

This is a diagnostic portability track. The release-critical path is
fork/fan-out on identical host classes; cross-backend restore helps inspect
failed runs and keep backend-private state out of the spore contract.

## Scope

Manifest-format-v0 portability is deliberately narrow:

- Guest ISA: aarch64 only.
- vCPU topology: one vCPU.
- Backends: Linux KVM and Apple Hypervisor.framework.
- Device model: the frozen SporeVM board contract — virtio-mmio console,
  optional blk, net, vsock, rng, and the generation MMIO device. Transient
  grow-only virtio-mem for fresh managed auto runs is outside manifest v0;
  capture/resume paths disable it rather than serializing hotplug state.
- Memory: portable restore is chunk-authoritative. Product same-host restore may
  use local proof-backed `ram.backing`, but that is acceleration metadata, not a
  portability authority.
- Disk: a captured `spore run --image` workload may reference one verified
  immutable ext4 rootfs artifact and, for image-created spores, manifest-bound
  chunked rootfs storage. It may also reference an optional sealed writable
  rootfs-bound COW layer chain. Bundles can carry rootfs CAS bytes, exact
  rootfs artifacts, layer indexes, and disk objects. General block devices are
  still outside the portable contract.

Cross-ISA restore, portable HVF multi-vCPU GIC production, persisted access
traces, general volumes, and broader disk/device fixups are later slices.

Manifest format v1 is now reserved for multi-vCPU machine state. It records a
bounded `vcpu_count`, per-vCPU normalized aarch64 state keyed by stable
`index`/`mpidr`, and either portable `gicv3_multi` state with global
distributor, per-MPIDR redistributors, and owner-tagged PPI line levels, or a
tagged same-HVF `backend_private` GIC blob. KVM produces and consumes the
portable shape; HVF produces and consumes the private same-backend shape.

## Platform contract

`manifest.platform` is the restore gate. The destination backend must satisfy
these fields exactly unless this document says a field is translatable:

| Field | Current policy | Why it matters |
| --- | --- | --- |
| `arch` | must be `aarch64` | Guest RAM and registers are ISA-specific. |
| `cpu_profile` | must match `sporevm-aarch64-v0` | Guest-visible feature IDs must match the saved execution environment. |
| `device_model_version` | must match | Virtio layout, interrupt lines, and generation MMIO are board contract. |
| `ram_base`, `ram_size` | must match | Guest physical addresses and page tables are already live. |
| `gic_dist_base`, `gic_redist_base` | must match | Linux has mapped the GIC MMIO windows. |
| `counter_frequency_hz` | must match | Timer state is stored in this tick domain. |
| device count/order | must match | Virtio transport state is positional and device IDs must line up. |

Current observed timer contracts:

- Apple Hypervisor.framework guest timer: `24_000_000` Hz.
- AWS `m7g.metal` KVM host: `1_050_000_000` Hz.
- AWS `a1.metal` KVM host: `83_333_333` Hz.

That mismatch is intentionally rejected. A positive KVM→HVF smoke needs a KVM
producer whose guest-visible counter frequency is 24MHz, or a later timer
design that makes frequency differences safely translatable. This does not
block identical-host fork/fan-out.

## State inventory

| State area | Spore representation | KVM producer | KVM consumer | HVF producer | HVF consumer | Status |
| --- | --- | --- | --- | --- | --- | --- |
| RAM | BLAKE3-addressed fixed chunks, zero chunks elided | yes | yes | yes | yes | portable |
| GPRs `x0`–`x30` | fixed array | yes | yes | yes | yes | portable |
| `pc`, `cpsr` | scalar fields | yes | yes | yes | yes | portable |
| `fpcr`, `fpsr`, SIMD `q0`–`q31` | scalar fields plus 128-bit register pairs | yes | yes | yes | yes | portable |
| Selected EL1 system registers | architectural names and `u64` values | yes | yes | yes | yes | portable subset |
| `mpidr_el1` | captured but not applied | yes | skipped on set | yes | skipped on set | platform-owned |
| CPU feature ID registers | not serialized | masked/profiled at boot | profile check | profiled at boot | profile check | contract-only |
| RNDR feature | hidden from KVM guest | yes | n/a | absent | n/a | masked into profile |
| Virtual timer | `cntvct`, `cntv_ctl`, `cntv_cval` in `counter_frequency_hz` domain | yes | re-anchor | yes | re-anchor | same-frequency only |
| GIC distributor/register state | GICv3 MMIO offsets | yes | yes | no | partial apply | producer gap on HVF |
| GIC redistributor/register state | GICv3 MMIO offsets | yes | yes | no | partial apply | producer gap on HVF |
| GIC line levels | INTID plus asserted bit | PPI/SPI | yes | no | SPI only; asserted PPI rejected | asymmetric |
| GIC CPU interface | ICC register names and values | yes | yes | yes | yes | portable |
| Multi-vCPU machine state | manifest v1 per-vCPU arrays plus `gicv3_multi` or HVF-private GIC | yes | yes | same-HVF only | same-HVF only | HVF not portable |
| HVF GIC blob | tagged `backend_private` escape hatch | no | reject | same-HVF only | same-HVF only | not portable |
| Virtio-mmio transport | device ID, feature selectors, negotiated features, status, interrupt status, queue addresses/indices | yes | yes | yes | yes | portable |
| Virtqueue descriptors and buffers | guest RAM | yes | yes | yes | yes | portable through RAM |
| Generation device | counter, interrupt status, resume params | yes | yes | yes | yes | portable; fork path populates it |
| Immutable rootfs base | optional exact artifact plus optional `chunked-ext4-rootfs-v0` storage descriptor | yes via `spore run --image` | trusted flat-artifact open; chunks assemble the artifact when missing | yes via `spore run --image` | trusted flat-artifact open; chunks assemble the artifact when missing | product resume base; cache contract is verify-at-install, trust-at-open |
| Writable root disk layers | optional `cow-block-v0` chain over the effective immutable rootfs base | yes for local layer store | verifies layer indexes and disk objects | yes for local layer store | verifies layer indexes and disk objects | product resume; bundle materialization unit-covered |
| Network capability and policy | optional `spore-net-v0` plus allow CIDRs/hosts, exact host-port rules, and bound-service requirements; no live flows, host socket material, or host port forwards | yes | fresh gateway | yes | fresh gateway | policy portable; flows and port forwards dropped; bound services fail closed unless restored |
| Transient virtio-mem hotplug | not represented | fresh managed run only | n/a | fresh managed run only | n/a | outside manifest v0 |
| General writable disk contents | not represented | no | reject | no | reject | out of current format |
| Kernel identity | not yet represented | no | no | no | no | planned contract field |
| Access trace | not yet represented | no | no | no | no | local KVM/HVF lazy traces only; not a portability contract |

## Register classes

Each guest-visible register should be assigned one of these policies before it
enters the manifest.

### Portable

The value is guest architectural state and may be copied by name across
backends.

Current portable manifest-v0 set:

- GPRs: `x0`–`x30`.
- Control flow: `pc`, `cpsr`.
- FP/SIMD: `fpcr`, `fpsr`, `q0`–`q31`.
- EL1 context: `sctlr_el1`, `cpacr_el1`, `ttbr0_el1`, `ttbr1_el1`, `tcr_el1`,
  `spsr_el1`, `elr_el1`, `sp_el0`, `sp_el1`, `afsr0_el1`, `afsr1_el1`,
  `esr_el1`, `far_el1`, `par_el1`, `mair_el1`, `amair_el1`, `vbar_el1`,
  `contextidr_el1`, `tpidr_el1`, `cntkctl_el1`, `csselr_el1`, `tpidr_el0`,
  and `tpidrro_el0`.
- GIC CPU interface: `pmr_el1`, `bpr0_el1`, `ap0r0_el1`, `ap1r0_el1`,
  `bpr1_el1`, `ctlr_el1`, `sre_el1`, `igrpen0_el1`, and `igrpen1_el1`.

Restore rejects unknown `sys_regs` or `icc_regs` names. New registers require a
spec update and backend mapping in the same slice.

### Platform-owned

The value is guest-visible but chosen by the board/backend contract rather than
by the suspended workload.

- `mpidr_el1` is captured for inspection but skipped on apply. The board owns
  CPU identity: manifest v0 is single-vCPU, and manifest v1 validates stable
  `index`/`mpidr` topology while each backend sets MPIDR during vCPU bring-up.
- GIC base addresses are not translated. They are platform fields and must
  match because the guest has already observed and mapped them.

### Profiled or masked

The value is controlled by the CPU profile at guest creation, not by saving raw
backend feature registers.

- ID registers such as `ID_AA64*` are not serialized in manifest v0.
- KVM masks `ID_AA64ISAR0_EL1.RNDR` so Linux does not patch in RNDR/RNDRRS
  instructions unavailable on Apple Hypervisor.framework guests.
- Restore checks `cpu_profile` instead of trying to reconcile raw host feature
  registers.

### Translated

The value is meaningful only after backend-specific re-anchoring.

- Virtual timer state stores the guest virtual counter value plus
  `cntv_ctl`/`cntv_cval`.
- KVM restores by setting `KVM_ARM_SET_COUNTER_OFFSET` to align host counter
  time with the saved guest counter.
- Hypervisor.framework restores by setting the vtimer offset to align host
  counter time with the saved guest counter.
- This translation is only valid when `counter_frequency_hz` matches exactly.

### Backend-private

Backend-private state is allowed only as an explicit, fail-closed temporary
escape hatch.

- HVF same-host/same-backend GIC restore may use `backend_private` with
  `backend: "hvf"` and `format: "hv_gic_state_v0"`.
- Other backends must reject it.
- Portable cross-backend restore must use `kind: "gicv3"` for manifest v0 or
  `kind: "gicv3_multi"` for manifest v1.
- Manifest v1 also accepts tagged HVF `backend_private` GIC state for
  same-HVF multi-vCPU restore; other backends must reject it.

### Outside the spore

These are intentionally not captured in manifest v0:

- General disk contents and external host files. Rootfs-bound `cow-block-v0`
  layers are captured as described above.
- Network connections and host-side sockets.
- Transient virtio-mem plug state and guest hotplug policy.
- Host paths, credentials, secrets, and runtime policy.
- Kernel image identity and DTB identity, until the platform contract grows
  pinned kernel fields.

## GICv3 portability

Portable GIC state is the most backend-sensitive part of the current manifest
format. The manifest form is architectural: distributor and redistributor MMIO
offsets plus ICC register names. Backend handles, object references, and raw
kernel/HVF structs must not cross the format boundary.

For manifest v1, `gicv3_multi` keeps distributor state global, stores one
redistributor register set per MPIDR, and requires per-vCPU PPIs to name their
owning MPIDR. SPIs remain global and must not name an owner.

### KVM

KVM can currently:

- produce portable distributor register values;
- produce portable redistributor register values;
- produce PPI/SPI line levels for the current INTID range;
- consume portable distributor/redistributor values;
- consume line levels;
- produce and consume ICC registers through the VGIC CPU-system-register API.

### Hypervisor.framework

Hypervisor.framework can currently:

- consume the portable GIC subset needed by the KVM→HVF smoke path;
- consume ICC registers by architectural name;
- produce and consume an HVF-only `backend_private` GIC blob for same-backend
  restore;
- set SPI line levels.

Current HVF gaps:

- it does not yet produce a portable distributor/redistributor offset list;
- it does not expose a line-level getter;
- asserted PPI line levels from a portable producer are rejected on HVF because
  there is no safe destination API for them;
- a few unsupported zero/reset registers are skipped only when their value is
  known to be harmless for the current single-vCPU board.

## Restore direction matrix

| Direction | Current status | Gate before declaring green |
| --- | --- | --- |
| KVM→KVM | Manifest v0 passes same-host smoke on the `m7g.metal` KVM host. Manifest v1 multi-vCPU capture, `run --from`, and `resume` pass on the `sporevm-ops` ARM64 KVM CI host. | Keep v0 and v1 as regression coverage. |
| HVF→HVF | Passes same-host v0 smoke locally, including HVF lazy RAM and file-backed fork smokes. Manifest v1 multi-vCPU same-backend capture, `run --from`, and `resume` pass on Apple Silicon with private GIC state. | Keep v0 and v1 as regression coverage. |
| KVM→HVF | Portable vCPU, virtio, generation, GIC apply, and CPU profile machinery exist. `m7g.metal` and `a1.metal` spores fail closed on counter-frequency mismatch. | Need a KVM producer whose guest counter frequency matches HVF's 24MHz, or a designed cross-frequency timer contract. |
| HVF→KVM | Blocked because HVF still produces backend-private GIC state. Timer compatibility still applies. | Make HVF produce portable GICv3 state, then run with compatible counter frequency. |

## Failure policy

Restore must fail closed for any state the destination cannot satisfy. Do not
best-effort unknown machine state.

Current hard failures include:

- unknown manifest version;
- platform field mismatch;
- device count or device ID mismatch;
- chunk hash mismatch or malformed memory manifest;
- unknown EL1 system register name;
- unknown ICC register name;
- backend-private GIC state on the wrong backend;
- unsupported portable GIC state that is not explicitly documented as a safe
  zero/reset skip;
- counter-frequency mismatch;
- missing rootfs cache bytes, missing disk layer objects, corrupt disk objects,
  or general disk devices outside the rootfs-bound COW contract.

## Smoke contract

State portability checks should use product-created spores wherever possible:

- `spore run --save ...` to create diskless, immutable-rootfs, or locally
  layered writable-rootfs spores;
- `spore attach` to validate session restore;
- `spore fork` and `spore fanout` to validate child identity and parallel
  resume behavior.

Current evidence:

- Product smokes cover same-host diskless capture/resume, diskless fork/fan-out,
  and OCI-rootfs child execution through `mise run smoke`,
  `mise run smoke:counter-fanout`, and `mise run smoke:rootfs-fanout`.
- Local writable rootfs layer persistence, fork divergence, and local
  bundle-carried disk layer replay are covered by `mise run smoke:writable-rootfs`.
- Same-class KVM writable-rootfs bundle materialization previously passed with
  `test/remote/bundle.sh --writable-rootfs` on two `a1.metal` hosts
  in run `writable-rootfs-20260619T212758Z`. The repo keeps
  `test/remote/bundle.sh` for host-level remote diagnostics; release validation
  should target the deployed Kubernetes stack when that harness exists.
- KVM→HVF with an `m7g.metal` producer is a negative test: the spore records
  `counter_frequency_hz = 1_050_000_000` and HVF exposes 24MHz, so restore must
  reject it before running guest code.
- A historical ten-host `a1.metal` probe reported `CNTFRQ_EL0 = 83_333_333` on
  every host. That remains evidence for same-class KVM behavior, but A1 is not
  the current remote validation target and is not a timer-compatible producer
  for current Apple HVF hosts.
- HVF v1 multi-vCPU same-backend capture, `run --from`, and `resume` passed
  locally with `--backend hvf --vcpus 2` on Apple Silicon.
- KVM v1 multi-vCPU fresh boot, capture, `run --from`, and `resume` passed on
  the `sporevm-ops` ARM64 Linux CI host
  `i-08fa4a14319c9c1b5` (`sporevm-ci-apse2-linux-arm64`, `c7gd.metal`) via SSM
  command `595ad080-f9ba-4b48-a3d4-49b4dc46df24`, which ran
  `test/smoke/fanout/multi-vcpu.sh` with `SPORE_BACKEND=kvm` and reported
  `smoke:multi-vcpu ok backend=kvm vcpus=2`.

## Next contract work

1. Add kernel image identity to the platform contract.
2. Broaden disk-backed portability evidence beyond same-class KVM while keeping
   the product disk contract rootfs-bound; add general volumes only for a
   concrete workflow that cannot live in the rootfs.
3. Decide the timer portability design: fixed guest timer profile at VM
   creation, frequency-neutral timer state plus guest-visible constraints, or
   host-class matching only.
4. Make HVF emit portable GICv3 state instead of only the backend-private blob.
5. Extend the matrix when persisted access traces/readahead hints or additional
   fork generation semantics land.
