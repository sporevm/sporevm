---
status: landed
last_reviewed: 2026-06-28
spec_refs:
  - docs/spore-format.md
  - docs/state-portability.md
  - docs/lifecycle.md
  - SECURITY.md
  - src/run.zig
  - src/lifecycle.zig
  - src/board.zig
  - src/spore.zig
  - src/kvm/vm.zig
  - src/hvf/vm.zig
  - src/kvm/snapshot.zig
  - src/hvf/snapshot.zig
related_plans:
  - docs/plans/automatic-memory.md
  - docs/plans/automatic-local-ram-backing.md
---

# Multi-vCPU Runtime and Capture/Resume

## Summary

At plan start, SporeVM exposed a `--vcpus N` option at the product boundary,
but the runtime rejected every value except `1`. The landed outcome is that
operators can boot, capture, restore, and fan out aarch64 guests with more than
one vCPU without weakening the existing isolation, portability, or fail-closed
manifest rules.

This is not just a run-loop change. Fresh multi-vCPU boot needs backend thread
coordination, guest CPU topology, GIC redistributor routing, and PSCI behavior.
Capture/resume needs a manifest format change because manifest v0 stores one
architectural CPU state and one single-vCPU GIC view. Multi-vCPU state must be
recorded explicitly per vCPU and restored only when the target backend can
recreate the same topology.

The plan keeps the first implementation boring: use one global VM/device lock,
run one host thread per vCPU, fail closed for unsupported capture/resume shapes,
and only widen the public promise when the runtime and manifest contract can
prove it.

## Problem

At the start of this plan the CLI help said `--vcpus N` existed, but
`run.execute` and `run.executeMonitor` rejected `opts.vcpus != 1`. The
lifecycle metadata carried a vCPU count, but named resume and named fork also
rejected multi-vCPU state.

The board builder could already describe multiple CPU nodes in the DTB, but
both backend VM implementations passed `cpu_count = 1` and created exactly one
vCPU. Every VM exit path, wake hook, interrupt flush, and snapshot call was
built around a single KVM vCPU fd or HVF vCPU handle.

Manifest v0 is a harder boundary. It has one `machine` object with one set of
general registers, system registers, SIMD registers, virtual timer state, ICC
registers, and one single-vCPU GIC state. Extending `--vcpus` without extending
the capture format would make fresh runs work while captures silently lose CPU
state. That would break the product contract.

## Goals

- Support fresh `spore run --vcpus N` and named monitor creation for bounded
  multi-vCPU guests on KVM and HVF.
- Support capture/resume for multi-vCPU guests through an explicit manifest
  format v1 contract.
- Preserve manifest v0 behavior for existing single-vCPU captures.
- Keep device emulation shared and serialized for the first implementation.
- Make unsupported backend, topology, and manifest combinations fail before a
  guest is resumed.
- Record enough topology in the manifest to reject mismatched vCPU count,
  MPIDR mapping, redistributor layout, device model, and timer frequency.
- Keep `spore run --from`, `spore resume`, named resume, and fork/fan-out
  semantics explicit rather than treating multi-vCPU as best effort.

## Non-Goals

- No x86, cross-ISA, or mixed-ISA topology work.
- No public scheduler or placement policy for CPU admission.
- No attempt to optimize device emulation with fine-grained locks in the first
  implementation.
- No live migration while vCPUs continue running. Snapshot is a stop-the-world
  operation until a later design proves otherwise.
- No transient virtio-mem capture/resume design in this plan. Current
  capture/resume paths disable transient virtio-mem and record fixed RAM; if the
  automatic-memory/device-model work adds virtio-mem serialization later,
  multi-vCPU manifest v1 should reuse that contract.
- No cross-frequency timer translation. The existing exact
  `counter_frequency_hz` restore gate remains.
- No compatibility shim that pretends a v0 single-CPU manifest can represent
  multi-vCPU state.

## Target Model

### User-Facing Behavior

Product commands accept bounded positive vCPU counts:

```console
spore run --vcpus 2 --image docker.io/library/alpine:latest -- nproc
spore run --vcpus 4 --capture base.spore -- ./parallel-test
spore run --from base.spore -- ./next-command
spore resume base.spore resumed-vm
```

Single-vCPU captures continue to write manifest v0 unless another incompatible
format feature is requested. Multi-vCPU captures write manifest v1. Older
consumers reject v1 through the existing unknown-version path.

If a backend does not yet support multi-vCPU, the error remains
`UnsupportedVcpuCount` or a more specific setup error before VM creation. If a
capture path has not yet landed for a backend, fresh multi-vCPU boot may be
enabled only when `--capture`, `--from`, `resume`, and lifecycle restore remain
fail-closed for `vcpus != 1`.

### Manifest v1 Shape

The minimal incompatible format change is to split CPU state from global machine
state:

```json
{
  "version": 1,
  "platform": {
    "arch": "aarch64",
    "cpu_profile": "sporevm-aarch64-v0",
    "device_model_version": 5,
    "vcpu_count": 2,
    "ram_base": 2147483648,
    "ram_size": 536870912,
    "gic_dist_base": 134217728,
    "gic_redist_base": 134348800,
    "gic_redist_stride": 131072,
    "counter_frequency_hz": 24000000
  },
  "machine": {
    "vcpus": [
      {
        "index": 0,
        "mpidr": 2147483648,
        "gprs": [],
        "pc": 0,
        "cpsr": 0,
        "fpcr": 0,
        "fpsr": 0,
        "simd": [],
        "sys_regs": [],
        "icc_regs": [],
        "vtimer": {}
      }
    ],
    "gic": {
      "kind": "gicv3",
      "distributor_regs": [],
      "redistributors": [
        { "mpidr": 2147483648, "regs": [] }
      ],
      "line_levels": []
    }
  }
}
```

The exact Zig structs can be simpler than this sketch, but the contract needs
these facts:

- vCPU count is platform state and must match exactly on restore.
- vCPU array order is stable and uses explicit `index` plus `mpidr`.
- `mpidr_el1` remains platform-owned on apply; saved values validate topology
  but are not blindly restored.
- Virtual timer, ICC registers, and EL1 CPU state are per-vCPU.
- GIC distributor state is global.
- GIC redistributor state is per-vCPU and keyed by MPIDR or vCPU index.
- Line-level state must distinguish global SPIs from per-vCPU PPIs.

## Safety Model and Invariants

- All guest-controlled MMIO, virtqueue, manifest, and GIC state remains
  attacker-influenced input. New v1 parsers and validators need tests and fuzz
  coverage in the same change.
- A snapshot must capture a quiesced VM. Every vCPU is stopped, any pending MMIO
  completion is resolved or rejected, and no device queue is mutated while the
  manifest is being written.
- Device state is shared. The first implementation uses one VM/device lock
  around virtio transports, generation device state, vsock/net host streams,
  snapshot state, and interrupt injection.
- Capture must fail rather than serialize a VM with pending vsock packets,
  non-quiescent rootfs/disk queues, unsupported GIC state, or partially stopped
  vCPUs.
- Restore must create the full topology before applying CPU and interrupt state.
  Restoring fewer vCPUs, different MPIDRs, or a different redistributor stride is
  a platform mismatch.
- Backend-private GIC blobs stay tagged and fail closed on the wrong backend.
  Portable multi-vCPU restore should not depend on an untyped HVF blob.

## Backend Notes

### KVM

KVM is the lower-risk first backend because PSCI 0.2 is already provided by the
kernel. The runtime should create and initialize N vCPU fds, mmap one `kvm_run`
area per vCPU, and run each vCPU on its own host thread.

The global VM/device lock serializes userspace MMIO handling and interrupt
injection. Wake paths need to target all vCPU run loops, not one
`immediate_exit` byte. Snapshot must request every vCPU to exit, join or park at
a capture barrier, complete any pending MMIO exit, then capture all vCPU states.

The current KVM GIC helpers encode redistributor, ICC, and PPI line state for
vCPU0. Multi-vCPU support needs attribute helpers that include the saved MPIDR
affinity for each vCPU.

### HVF

HVF needs more runtime work because PSCI is currently emulated in userspace and
`CPU_ON`, `CPU_OFF`, and affinity queries return unsupported. The first design
should create all vCPUs up front, run vCPU0 initially, and keep secondary vCPUs
parked until guest PSCI `CPU_ON` provides an entry address and context id.

Each HVF vCPU gets a stable MPIDR and a run-thread state machine:

- `off`: parked, not executing guest code;
- `starting`: CPU_ON accepted, entry/context being installed;
- `running`: the vCPU may enter `hv_vcpu_run`;
- `stopping`: snapshot or shutdown barrier requested;
- `exited`: vCPU has returned through CPU_OFF or VM shutdown.

HVF GIC redistributor MMIO is keyed by vCPU handle. The trapped IPA must be
decoded to the target redistributor frame and forwarded with that frame's vCPU
handle, not necessarily the vCPU that took the trap. The first slice can require
contiguous redistributor frames and fail closed if HVF reports a layout the DTB
builder cannot describe.

### Shared Devices

The first implementation deliberately keeps one instance of each existing
virtio/generation device. Multi-vCPU guests share those devices through the same
MMIO windows. This avoids new queue ownership rules and keeps the first
concurrency boundary obvious.

The global lock is acceptable for correctness and small vCPU counts. Replace it
only if real smoke or benchmark data shows device-lock contention is the next
limit.

## Current State

- `--vcpus` is parsed through shared topology validation with an initial cap of
  8, while public C/Go boundary surfaces still carry `u32` fields.
- `run.execute` and `run.executeMonitor` validate the cap and pass `vcpus` into
  backend configs.
- KVM backend configs carry `vcpus`, feed it into DTB construction, and can run
  fresh multi-vCPU guests with one host thread per vCPU. KVM multi-vCPU
  capture/resume now uses manifest v1 for fixed-RAM run paths. Monitor
  exec-control is wired for named create/resume/suspend; continue-after capture
  and transient virtio-mem still fail closed for `vcpus != 1`.
- HVF backend configs carry `vcpus`, feed it into DTB construction, and can run
  fresh and fixed-RAM capture/resume multi-vCPU guests with one owner thread per
  vCPU. HVF monitor exec-control is wired for named create/resume/suspend;
  dirty-tracked capture, `--continue-after-capture`, and transient virtio-mem
  still fail closed for `vcpus != 1`.
- Lifecycle metadata records `vcpus`; named create and named resume support
  manifest v1 multi-vCPU captures on supported backends, continue-after named
  snapshots fail before monitor mutation, and named fork rejects multi-vCPU
  live fork before child state is written.
- `board.buildDtb` emits one CPU node per `cpu_count`, and DTB tests cover
  multi-node CPU topology plus redistributor region sizing.
- HVF single-vCPU capture/resume still creates one main-thread-owned vCPU; the
  multi-vCPU path creates vCPUs on their owning host threads and uses
  owner-thread commands for PSCI starts, cross-redistributor MMIO, and v1
  capture/restore register access.
- KVM snapshot code keeps manifest v0 for single-vCPU captures and captures or
  restores manifest v1 per-vCPU CPU, ICC/timer, redistributor, and line-level
  state for multi-vCPU captures.
- HVF snapshot code captures and restores manifest v1 per-vCPU CPU,
  ICC/timer state, and a tagged same-HVF private GIC blob for multi-vCPU
  captures.
- Manifest v0 and the state portability docs explicitly define one-vCPU
  topology. Manifest v1 now has KVM portable producers/consumers and HVF
  same-backend producers/consumers for multi-vCPU machine state. Bundle
  production, pull, and local materialization preserve v1 manifests. Portable
  HVF GIC output remains a later slice.

## Delivery Strategy

### Slice 1: Shared Topology Contract and Fail-Closed Gates

Add internal topology types for `vcpu_count`, `vcpu index`, and `mpidr`. Thread
the count through `run`, monitor, backend config, and DTB construction, but keep
backend support disabled until each backend lands. Add explicit error messages
for unsupported combinations such as multi-vCPU capture on a backend without v1
snapshot support.

Status: implemented in this branch slice on 2026-06-28. Validation: `mise run
test`, `mise run build`, and `git diff --check`.

Done when:

- `--vcpus` validation has a single shared helper and a documented first cap;
- backend configs carry `vcpus`;
- DTB tests cover multiple CPU nodes and redistributor region sizing;
- capture/resume/lifecycle paths still fail before boot for unsupported
  multi-vCPU combinations.

### Slice 2: KVM Fresh Multi-vCPU Boot

Implement KVM vCPU arrays, per-vCPU run threads, all-vCPU wake handling, and
serialized MMIO/device handling. Keep capture disabled for `vcpus != 1` in this
slice.

Status: implemented in this branch slice on 2026-06-28. Validation: `mise run
test`, `mise run build`, `git diff --check`, and final KVM smoke via
`scripts/smoke-multi-vcpu.sh` on the `sporevm-ops` ARM64 Linux CI host.

Done when:

- `spore run --backend kvm --vcpus 2 -- nproc` reports at least 2 inside the
  guest on an aarch64 KVM host;
- system-off/reset exits stop every vCPU thread cleanly;
- network, vsock exec, rootfs, and rng still pass existing KVM smoke coverage;
- `--capture` with `--vcpus 2` fails with the planned unsupported-capture error.

### Slice 3: HVF Fresh Multi-vCPU Boot

Implement HVF vCPU arrays, PSCI `CPU_ON`/`CPU_OFF`/affinity behavior,
all-vCPU wake handling, redistributor-frame routing, and serialized device
handling. Keep capture disabled for `vcpus != 1` in this slice.

Done when:

- `spore run --backend hvf --vcpus 2 --image docker.io/library/alpine:3.20 --
  /bin/sh -lc "grep -c '^processor' /proc/cpuinfo"` reports `2` on Apple
  Silicon;
- secondary vCPUs start only through PSCI and shut down cleanly;
- redistributor MMIO for every exposed CPU frame is routed to the matching HVF
  vCPU owner thread;
- `--capture` with `--vcpus 2` fails with `UnsupportedVcpuCount`.

Status: implemented for fresh HVF runs. Validation on Apple Silicon:
`zig-out/bin/spore run --backend hvf --vcpus 2 -- /bin/true`,
`zig-out/bin/spore run --backend hvf --vcpus 2 --image
docker.io/library/alpine:3.20 -- /bin/sh -lc "grep -c '^processor'
/proc/cpuinfo"` returned `2`, and `zig-out/bin/spore run --backend hvf
--vcpus 2 --capture <dir>/base.spore -- /bin/true` failed before guest boot
with `UnsupportedVcpuCount`.

### Slice 4: Manifest v1 Data Model and Validators

Introduce manifest format v1 for multi-vCPU state. Keep manifest v0 structs and
loaders intact for existing one-vCPU spores. Add v1 JSON parse, validation,
fork-copy helpers, bundle materialization rules, and docs.

Done when:

- v1 can represent N per-vCPU CPU states plus global/per-vCPU GIC state;
- v0 consumers continue to reject unknown v1 manifests;
- validators reject duplicate vCPU indexes, duplicate MPIDRs, mismatched
  `vcpu_count`, unsupported redistributor state, bad PPI ownership, and unknown
  GIC register offsets;
- manifest and GIC validation fuzz targets cover v1 attacker-controlled inputs.

Status: implemented for the manifest data model and fail-closed validators in
this branch slice on 2026-06-28. Validation: `git diff --check`, `mise run
test`, and `mise run build`. Runtime v1 producers/consumers and v1
fork/fan-out and bundle preservation landed in later slices.

### Slice 5: KVM Multi-vCPU Capture and Resume

Add a stop-the-world KVM snapshot barrier. Capture every vCPU state, per-vCPU
ICC/timer state, per-vCPU redistributor state, global distributor state, SPI/PPI
line state, devices, generation, disk/rootfs, and memory. Restore creates all
vCPUs, applies topology and GIC state, then releases vCPU threads.

Done when:

- a KVM `--vcpus 2 --capture` writes manifest v1;
- `spore run --from` can execute a new command from the captured base;
- `spore resume` can resume an active multi-vCPU capture on a compatible KVM
  host;
- stale or incompatible vCPU topology fails at manifest/platform validation.

Status: implemented in this branch slice on 2026-06-28. Validation: `git diff
--check`, `mise run test`, `mise run build`, and final KVM smoke via
`scripts/smoke-multi-vcpu.sh` on the `sporevm-ops` ARM64 Linux CI host.

### Slice 6: HVF Multi-vCPU Capture and Resume

Add the same stop-the-world capture barrier for HVF. Prefer portable GICv3
multi-vCPU state. If HVF cannot produce the full portable shape yet, allow only
a clearly tagged same-HVF backend-private v1 GIC state and keep cross-backend
restore rejected.

Done when:

- a HVF `--vcpus 2 --capture` writes manifest v1;
- same-host HVF `spore run --from` and `spore resume` work for multi-vCPU
  captures;
- KVM rejects any HVF-private multi-vCPU GIC state before VM mutation;
- portable HVF GIC production gaps are documented in `docs/state-portability.md`.

Status: implemented in this branch slice on 2026-06-28 with same-HVF
`backend_private` GIC state and full-RAM capture. Validation: `git diff
--check`, `mise run test`, `mise run build`,
`zig-out/bin/spore run --backend hvf --vcpus 2 --capture <dir>/base.spore --
/bin/true`, `zig-out/bin/spore run --backend hvf --from <dir>/base.spore --
/bin/true`, and `zig-out/bin/spore resume --backend hvf <dir>/base.spore`.

### Slice 7: Lifecycle, Fork, Fan-Out, and Distribution

Remove named lifecycle guards once both fresh boot and restore support the
manifest shapes they can encounter. Extend fork/fan-out helpers to preserve
multi-vCPU topology, rewrite only generation/device identity fields, and keep
local RAM backing proof behavior unchanged.

Done when:

- named create can start multi-vCPU monitors on supported backends;
- named resume accepts manifest v1 multi-vCPU captures;
- named fork/fan-out either works for v1 captures or fails with a product-level
  reason before child state is written;
- bundles, pulls, and local materialization preserve v1 manifests and reject
  incomplete v1 object sets.

Status: implemented in this branch slice on 2026-06-28. Validation: `mise run
test`, `mise run build`, `git diff --check`, and live Apple Silicon smoke with
`spore create --backend hvf --vcpus 2`, `spore exec`, `spore suspend`,
manifest v1 inspection, named `spore resume --name`, and post-resume `spore
exec`. Named live fork keeps the product-level multi-vCPU rejection before
child state is written; direct `spore.fork` now rejects manifest v1 before
creating the output directory.

### Slice 8: Documentation, Release Notes, and Runtime Evidence

Update durable docs and release notes after behavior lands. Include backend
support matrix, capture/resume limits, and examples that are validated against
the actual CLI.

Done when:

- [x] `docs/spore-format.md`, `docs/state-portability.md`,
  `docs/lifecycle.md`, and `SECURITY.md` describe the new contract;
- [x] release notes call out backend support and any remaining fail-closed
  limits;
- [x] real KVM and HVF smoke evidence exists for fresh boot and capture/resume.

Validation:

- Local HVF: `scripts/smoke-multi-vcpu.sh` passed on Apple Silicon with
  `backend=hvf vcpus=2`, covering guest CPU visibility, manifest v1 capture,
  `run --from`, and `resume`.
- KVM: `sporevm-ops` Terraform output selected ARM64 Linux CI host
  `i-08fa4a14319c9c1b5` (`sporevm-ci-apse2-linux-arm64`, `c7gd.metal`).
  SSM command `595ad080-f9ba-4b48-a3d4-49b4dc46df24` ran
  `scripts/smoke-multi-vcpu.sh` with `SPORE_BACKEND=kvm` and reported
  `smoke:multi-vcpu ok backend=kvm vcpus=2`.

## Verification

- Unit tests:
  - vCPU count parser and cap validation;
  - DTB multiple CPU nodes and redistributor sizing;
  - MPIDR/index mapping helpers;
  - KVM VGIC attr encoding for nonzero vCPU affinities;
  - HVF redistributor IPA-to-vCPU routing;
  - manifest v1 validation and v0/v1 round trips.
- Fuzz tests:
  - manifest v1 parser and validator;
  - GICv3 multi-redistributor state validator;
  - any new attacker-influenced topology parser.
- Integration tests:
  - KVM fresh `--vcpus 2` exec;
  - HVF fresh `--vcpus 2` exec;
  - capture rejection before snapshot slices land;
  - KVM v1 capture, `run --from`, and `resume`;
  - HVF v1 capture, `run --from`, and `resume`;
  - wrong backend/private-GIC restore rejection.
- Smoke scripts:
  - add real-host KVM and HVF scripts under `scripts/`;
  - use commands that prove parallel CPU visibility, not just boot success;
  - preserve existing single-vCPU smoke scripts as regression coverage.
- Performance checks:
  - snapshot pause time by vCPU count;
  - device-lock contention under parallel guest I/O;
  - local RAM backing reuse for multi-vCPU fork/fan-out.

## Resolved Decisions

- Manifest v1 is required for multi-vCPU capture/resume. Do not stretch
  manifest v0 to carry arrays hidden behind optional fields.
- Fresh multi-vCPU boot may land before capture/resume only while capture and
  restore paths fail closed for `vcpus != 1`.
- The first concurrency model is one global VM/device lock.
- Single-vCPU captures should continue to use manifest v0 unless another
  incompatible format feature is requested.
- KVM can land before HVF internally, but the product surface must describe
  backend support explicitly and reject unsupported backends before guest start.
- The first product cap is `1..8`, centralized in the shared topology helper.

## Deferred Work

- Fine-grained per-device or per-queue locking.
- Live migration or non-stop snapshots.
- Cross-frequency timer translation.
- Transient virtio-mem capture/resume; this needs a separate automatic-memory
  device-model migration before multi-vCPU should depend on it.
- Portable HVF `gicv3_multi` production; this plan ships same-HVF restore with
  tagged `backend_private` GIC state.
- CPU hotplug after boot.
- Scheduler admission based on host CPU capacity.

## Open Questions

None.

## Key Learnings From Pressure-Testing

- The tempting small change is to lift the `opts.vcpus != 1` gates and wire DTB
  CPU count. That would boot some guests but leave capture/resume lying about
  saved state. The plan keeps capture fail-closed until manifest v1 lands.
- Device concurrency is the highest regression risk. A global VM/device lock is
  slower than ideal but much smaller and easier to prove than making every
  virtio device thread-safe at once.
- HVF is not symmetric with KVM. KVM owns PSCI and VGIC behavior; HVF requires
  user-space PSCI and redistributor routing. The delivery order reflects that
  without exposing a permanent backend-specific public API.
- Portable multi-vCPU GIC state is the format hotspot. The plan makes
  backend-private HVF state an explicit temporary escape hatch, not a hidden
  portability claim.
